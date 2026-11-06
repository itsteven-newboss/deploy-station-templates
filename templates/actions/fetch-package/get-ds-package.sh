#!/usr/bin/env bash
# Downloads the package for this server from the release v<version> of the current repository:
# package-linux.zip when the release has one, otherwise the portable package.zip. Verifies its
# SHA-256, extracts it and writes the folder to the step output "package-dir". Runs on Ubuntu
# target servers; the Windows counterpart is Get-DsPackage.ps1.
#
#   get-ds-package.sh <version> <out-dir>     (needs DS_GITHUB_TOKEN, GITHUB_API_URL, GITHUB_REPOSITORY)
set -euo pipefail

version=$1
out=$2
: "${DS_GITHUB_TOKEN:?DS_GITHUB_TOKEN is not set}"
api="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY"
auth=(-H "Authorization: Bearer $DS_GITHUB_TOKEN" -H 'X-GitHub-Api-Version: 2022-11-28')

release=$(curl -fsS "${auth[@]}" -H 'Accept: application/vnd.github+json' "$api/releases/tags/v$version")
name="" asset_id="" sum_id=""
for candidate in package-linux.zip package.zip; do
  asset_id=$(jq -r --arg n "$candidate" '.assets[] | select(.name == $n) | .id' <<< "$release")
  sum_id=$(jq -r --arg n "$candidate.sha256" '.assets[] | select(.name == $n) | .id' <<< "$release")
  if [[ -n $asset_id && -n $sum_id ]]; then
    name=$candidate
    break
  fi
done
[[ -n $name ]] || { echo "Release v$version has no package-linux.zip or package.zip (with its .sha256)" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
# curl drops the Authorization header when it follows the redirect to GitHub's storage, as required.
for id_file in "$asset_id:$name" "$sum_id:$name.sha256"; do
  curl -fsSL "${auth[@]}" -H 'Accept: application/octet-stream' "$api/releases/assets/${id_file%%:*}" -o "$out/${id_file#*:}"
done

expected=$(awk '{print tolower($1)}' "$out/$name.sha256")
actual=$(sha256sum "$out/$name" | awk '{print $1}')
if [[ $expected != "$actual" ]]; then
  echo "$name checksum mismatch: release says $expected, downloaded file is $actual" >&2
  exit 1
fi
echo "$name v$version verified ($actual)"

unzip -q "$out/$name" -d "$out/package"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "package-dir=$out/package" >> "$GITHUB_OUTPUT"
fi
