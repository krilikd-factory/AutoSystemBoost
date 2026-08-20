#!/usr/bin/env sh
# Keep debug and release builds equally strict about public update metadata.
# A debug build can run perfectly while a release is unpublishable if update.json
# still names a prior module version; validate the shared contract before compiling.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_module_ver=$(sed -n 's/^version=//p' module.prop | head -1)
_module_code=$(sed -n 's/^versionCode=//p' module.prop | head -1)
_update_ver=$(awk -F'"' '/"version"[[:space:]]*:/{print $4; exit}' update.json)
_update_code=$(grep -m1 '"versionCode"' update.json | tr -cd '0-9')

[ -n "$_module_ver" ] && [ -n "$_module_code" ] || {
  echo 'ERROR: module.prop version missing' >&2
  exit 1
}
[ "$_module_ver" = "$_update_ver" ] || {
  echo "ERROR: update.json version $_update_ver != module.prop $_module_ver" >&2
  exit 1
}
[ "$_module_code" = "$_update_code" ] || {
  echo "ERROR: update.json versionCode $_update_code != module.prop $_module_code" >&2
  exit 1
}

_release_id=${_module_ver#V}
_want_path="/releases/download/${_release_id}/ASB-${_module_ver}.zip"
grep -q "$_want_path" update.json || {
  echo "ERROR: update.json zipUrl does not target $_want_path" >&2
  exit 1
}

echo "Update metadata: $_module_ver / $_module_code"
