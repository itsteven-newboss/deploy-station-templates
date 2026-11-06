# Shared helpers for the Ubuntu deploy engine (docs/DESIGN.md section 11.3). Sourced by deploy.sh.
# Tests can redirect privileged commands and system paths with DS_SUDO, DS_SYSTEMD_DIR, DS_NGINX_DIR.

# Privileged commands go through sudo; empty when already root or when tests set DS_SUDO="".
if [[ -z ${DS_SUDO+set} ]]; then
  if [[ $EUID -eq 0 ]]; then DS_SUDO=""; else DS_SUDO="sudo"; fi
fi

ds_log() { echo "[ds] $*"; }

ds_fail() {
  echo "::error::$*"
  echo "[ds] FAILED: $*" >&2
  exit 1
}

ds_require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 || ds_fail "$tool is not installed; run install-runner.sh on this server"
  done
}

# The manifest as seen on Ubuntu: shared settings with the "linux" section laid over them (D17).
ds_load_manifest() {
  [[ -f $1 ]] || ds_fail "ds.json not found at $1"
  DS_MANIFEST=$(jq -c '(. + (.linux // {})) | del(.windows, .linux)' "$1" | tr -d '\r') ||
    ds_fail "ds.json is not valid JSON"
  local name strategy
  name=$(ds_m .name)
  strategy=$(ds_m .strategy)
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ds_fail "ds.json: 'name' is required (letters, digits, '.', '_' or '-')"
  case $strategy in
    systemd-service) ds_require_field service.serviceName service.executable ;;
    nginx-site) ds_require_field nginx.listen ;;
    script) ds_require_field script.path ;;
    *) ds_fail "ds.json: strategy '$strategy' cannot run on linux (use systemd-service, nginx-site or script, or set it in a \"linux\" section)" ;;
  esac
}

# One manifest value as text; empty when absent (false stays "false").
ds_m() { jq -r "($1) | select(. != null) | if type == \"object\" or type == \"array\" then tojson else tostring end" <<< "$DS_MANIFEST" | tr -d '\r'; }

# The strings in a manifest array, one per line; nothing when absent.
ds_list() { jq -r "($1 // [])[]" <<< "$DS_MANIFEST" | tr -d '\r'; }

# Packages the app needs on the server (ds.json "prerequisites", D21), installed with apt before the
# release is copied. Installed packages are skipped, so later deployments cost nothing.
# aptRepositories (Launchpad PPAs) are added only when a package is not in the server's sources, e.g.
# ppa:dotnet/backports for .NET 10 on Ubuntu 22.04 (24.04 has it built in).
ds_install_prerequisites() {
  local package repository missing=() unavailable=()
  while IFS= read -r package; do
    [[ -n $package ]] || continue
    [[ $package =~ ^[a-z0-9][a-z0-9.+-]+$ ]] || ds_fail "ds.json: '$package' is not an apt package name"
    dpkg-query -W -f='${Status}' "$package" 2> /dev/null | grep -q 'ok installed' || missing+=("$package")
  done < <(ds_list .prerequisites.aptPackages)
  ((${#missing[@]} > 0)) || return 0

  ds_log "Installing prerequisites: ${missing[*]}"
  $DS_SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || ds_fail "apt-get update failed"
  for package in "${missing[@]}"; do
    apt-cache show "$package" > /dev/null 2>&1 || unavailable+=("$package")
  done
  if ((${#unavailable[@]} > 0)); then
    while IFS= read -r repository; do
      [[ -n $repository ]] || continue
      [[ $repository =~ ^ppa:[a-z0-9.+-]+/[a-z0-9.+-]+$ ]] ||
        ds_fail "ds.json: aptRepositories takes Launchpad PPAs such as ppa:dotnet/backports, not '$repository'"
      ds_log "Adding $repository (${unavailable[*]} not in this server's package sources)"
      command -v add-apt-repository > /dev/null ||
        $DS_SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common > /dev/null
      $DS_SUDO add-apt-repository -y "$repository" > /dev/null || ds_fail "Adding $repository failed"
    done < <(ds_list .prerequisites.aptRepositories)
    $DS_SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || ds_fail "apt-get update failed"
  fi
  $DS_SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" > /dev/null ||
    ds_fail "Installing ${missing[*]} failed"
}

ds_require_field() {
  local field
  for field in "$@"; do
    [[ -n $(ds_m ".$field") ]] || ds_fail "ds.json: $field is required for the $(ds_m .strategy) strategy on linux"
  done
}

# Creates a directory the engine (ds-runner) can write to, using sudo for locations like /opt.
ds_ensure_dir() {
  [[ -d $1 ]] && [[ -w $1 ]] && return 0
  $DS_SUDO mkdir -p "$1"
  [[ -z $DS_SUDO ]] || $DS_SUDO chown "$(id -un):$(id -gn)" "$1"
}

ds_copy_tree() {
  mkdir -p "$2"
  cp -a "$1/." "$2/"
}

# Server-held configuration overrides package files. sudo keeps the owner, group and mode set on
# <appRoot>/config, so secrets can stay readable only by the app's service user. Entries are copied
# one by one: copying "config/." would also stamp config's own owner, mode and timestamp onto the
# release folder.
ds_overlay_config() {
  local from=$1 to=$2 entry
  [[ -d $from ]] || return 0
  for entry in "$from"/* "$from"/.[!.]* "$from"/..?*; do
    [[ -e $entry ]] || continue
    $DS_SUDO cp -a "$entry" "$to/"
  done
}

ds_realpath() { readlink -f "$1" 2> /dev/null || echo "$1"; }

# Where <appRoot>/current points, or empty if it does not exist yet.
ds_link_target() {
  if [[ -L $1 ]]; then
    readlink -f "$1"
  elif [[ -e $1 ]]; then
    ds_fail "$1 exists but is not a symlink"
  fi
}

# Points the link at the target atomically: a new link is renamed over the old one.
ds_switch_link() {
  local link=$1 target=$2
  ln -sfn "$target" "$link.next"
  mv -Tf "$link.next" "$link"
}

ds_http_health() {
  local url=$1 timeout=$2 deadline
  deadline=$((SECONDS + timeout))
  while true; do
    if curl -fsS -o /dev/null --max-time 10 "$url" 2> /dev/null; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 3
  done
}

ds_python_setup() {
  local release=$1 python interpreter requirements wheelhouse
  python=$(ds_m .python)
  [[ -n $python ]] || return 0
  interpreter=$(ds_m .python.interpreter)
  requirements=$(ds_m .python.requirements)
  wheelhouse=$(ds_m .python.wheelhouse)
  ds_log "Creating virtualenv with ${interpreter:-python3}"
  "${interpreter:-python3}" -m venv "$release/.venv" || ds_fail "Creating the virtualenv failed (on Ubuntu install python3-venv)"
  ds_log "Installing Python packages offline from the package wheelhouse"
  "$release/.venv/bin/python" -m pip install --no-index --find-links "$release/${wheelhouse:-wheels}" \
    -r "$release/${requirements:-requirements.txt}" || ds_fail "pip install failed"
}

# Keeps the newest $2 releases plus the current and previous ones.
ds_prune_releases() {
  local dir=$1 keep=$2 current=$3 previous=$4 kept=0 release
  while IFS= read -r release; do
    [[ -n $release ]] || continue
    release=${release%/}
    if [[ $(ds_realpath "$release") == "$(ds_realpath "$current")" ]] ||
      [[ -n $previous && $(ds_realpath "$release") == "$(ds_realpath "$previous")" ]] ||
      ((kept < keep)); then
      kept=$((kept + 1))
      continue
    fi
    ds_log "Removing old release $(basename "$release")"
    $DS_SUDO rm -rf "$release"
  done < <(ls -1dt "$dir"/*/ 2> /dev/null)
}

ds_save_state() {
  local file=$1/ds-state.json version=$2 previous=$3 failed=$4 rolled_back=$5
  jq -n --arg version "$version" --arg previousVersion "$previous" --arg failedVersion "$failed" \
    --argjson autoRolledBack "$rolled_back" --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'def opt: if . == "" then null else . end;
     {version: $version, previousVersion: ($previousVersion | opt), failedVersion: ($failedVersion | opt), autoRolledBack: $autoRolledBack, updatedAt: $updatedAt}' \
    > "$file"
}
