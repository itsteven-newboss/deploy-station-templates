#!/usr/bin/env bash
# Deploy Station deploy engine for Ubuntu 22.04 / 24.04 (docs/DESIGN.md section 11.3).
#
#   deploy.sh <version> <package-dir>
#
# Runs on a target server inside the tpl-deploy job, after the gatekeeper allowed it, as the
# ds-runner user (full sudo, D18). The same steps as deploy.ps1 on Windows:
#   0. install missing packages listed in ds.json "prerequisites" (Ubuntu only, D21)
#   1. copy the package to <appRoot>/releases/<version> (reused if already there, e.g. a rollback)
#   2. overlay server-held configuration from <appRoot>/config (secrets never leave the server)
#   3. stop the app, point <appRoot>/current at the new release (atomic symlink swap), start it
#   4. check health; on failure switch back to the previous release and fail the job
#   5. keep the newest releases (ds.json keepReleases, default 5)
# Database migrations and other server changes are manual (docs/DESIGN.md D13).
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: deploy.sh <version> <package-dir>" >&2
  exit 2
fi
DS_VERSION=$1
DS_PACKAGE_DIR=$(cd "$2" && pwd)
DS_ENGINE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for lib in common systemd nginx script; do
  # shellcheck source=/dev/null
  source "$DS_ENGINE_DIR/lib/ds-$lib.sh"
done

ds_require_tools jq curl
ds_load_manifest "$DS_PACKAGE_DIR/_ds/ds.json"

APP_NAME=$(ds_m .name)
STRATEGY=$(ds_m .strategy)
APP_ROOT=$(ds_m .appRoot)
APP_ROOT=${APP_ROOT:-/opt/apps/$APP_NAME}
RELEASES_DIR=$APP_ROOT/releases
RELEASE_DIR=$RELEASES_DIR/$DS_VERSION
CURRENT_LINK=$APP_ROOT/current
CONFIG_DIR=$APP_ROOT/config
HEALTH_URL=$(ds_m .health.url)
HEALTH_TIMEOUT=$(ds_m .health.timeoutSeconds)
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-60}
KEEP_RELEASES=$(ds_m .keepReleases)
KEEP_RELEASES=${KEEP_RELEASES:-5}

ds_stop_app() {
  case $STRATEGY in
    systemd-service) ds_systemd_stop ;;
    nginx-site) : ;;
    script) ds_script_run stop ;;
  esac
}

ds_start_app() {
  case $STRATEGY in
    systemd-service) ds_systemd_start ;;
    nginx-site) ds_nginx_start ;;
    script) ds_script_run start ;;
  esac
}

ds_app_healthy() {
  if [[ -n $HEALTH_URL ]]; then
    ds_log "Checking $HEALTH_URL (up to $HEALTH_TIMEOUT seconds)"
    ds_http_health "$HEALTH_URL" "$HEALTH_TIMEOUT"
  elif [[ $STRATEGY == systemd-service ]]; then
    ds_log "No health.url in ds.json; checking the service stays active for 10 seconds"
    ds_systemd_stays_active 10
  else
    ds_log "WARNING: no health.url in ds.json; health is not verified"
  fi
}

# Runs a step so that its first failed command stops it, and puts its status in DS_STATUS.
# Must be called as a plain command: inside "if" or "||", bash ignores errexit for the whole
# step, even in a subshell that sets it again, and the step would carry on after a failure.
ds_try() {
  set +e
  (
    set -e
    "$@"
  )
  DS_STATUS=$?
  set -e
}

ds_log "Deploying $APP_NAME $DS_VERSION ($STRATEGY) to $APP_ROOT"
ds_install_prerequisites
ds_ensure_dir "$APP_ROOT"
mkdir -p "$RELEASES_DIR" "$CONFIG_DIR"

if [[ -d $RELEASE_DIR ]]; then
  ds_log "Release $DS_VERSION is already on this server; reusing it"
else
  rm -rf "$RELEASE_DIR.partial"
  ds_copy_tree "$DS_PACKAGE_DIR" "$RELEASE_DIR.partial"
  mv -T "$RELEASE_DIR.partial" "$RELEASE_DIR"
  ds_python_setup "$RELEASE_DIR"
fi
ds_overlay_config "$CONFIG_DIR" "$RELEASE_DIR"
# The folder's time records when this release was last deployed; pruning keeps the newest.
touch "$RELEASE_DIR"

PREVIOUS_DIR=$(ds_link_target "$CURRENT_LINK")
if [[ -n $PREVIOUS_DIR && $(ds_realpath "$PREVIOUS_DIR") == "$(ds_realpath "$RELEASE_DIR")" ]]; then
  ds_log "Release $DS_VERSION is already current; restarting it"
  PREVIOUS_DIR=""
fi

ds_try ds_stop_app
[[ $DS_STATUS -eq 0 ]] || ds_fail "Stopping the running release failed"
ds_switch_link "$CURRENT_LINK" "$RELEASE_DIR"

healthy=false
ds_try ds_start_app
if [[ $DS_STATUS -ne 0 ]]; then
  ds_log "Start failed"
else
  ds_try ds_app_healthy
  [[ $DS_STATUS -ne 0 ]] || healthy=true
fi

if [[ $healthy != true ]]; then
  if [[ -n $PREVIOUS_DIR && -d $PREVIOUS_DIR ]]; then
    previous_version=$(basename "$PREVIOUS_DIR")
    ds_log "Health check failed; switching back to $previous_version"
    ds_try ds_stop_app
    [[ $DS_STATUS -eq 0 ]] || ds_log "Stopping the failed release failed"
    ds_switch_link "$CURRENT_LINK" "$PREVIOUS_DIR"
    ds_try ds_start_app
    [[ $DS_STATUS -eq 0 ]] || ds_log "Restarting $previous_version failed"
    ds_save_state "$APP_ROOT" "$previous_version" "" "$DS_VERSION" true
    ds_fail "$APP_NAME $DS_VERSION failed its health check; this server was rolled back to $previous_version"
  fi
  ds_save_state "$APP_ROOT" "$DS_VERSION" "" "$DS_VERSION" false
  ds_fail "$APP_NAME $DS_VERSION failed its health check and there is no previous release to switch back to"
fi

previous_version=""
if [[ -n $PREVIOUS_DIR ]]; then
  previous_version=$(basename "$PREVIOUS_DIR")
fi
ds_save_state "$APP_ROOT" "$DS_VERSION" "$previous_version" "" false
ds_prune_releases "$RELEASES_DIR" "$KEEP_RELEASES" "$RELEASE_DIR" "$PREVIOUS_DIR"
ds_log "Deployed $APP_NAME $DS_VERSION"
