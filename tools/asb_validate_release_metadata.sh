#!/usr/bin/env sh
# Keep debug and release builds equally strict about public update metadata.
# This validates metadata identity and URL shape only. A release asset does not
# exist until after the first successful release build, so it must never be
# required as a pre-build condition.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_module_ver=$(sed -n 's/^version=//p' module.prop | head -1)
_module_code=$(sed -n 's/^versionCode=//p' module.prop | head -1)
_update_ver=$(awk -F'"' '/"version"[[:space:]]*:/{print $4; exit}' update.json)
_update_code=$(grep -m1 '"versionCode"' update.json | tr -cd '0-9')
_zip_url=$(awk -F'"' '/"zipUrl"[[:space:]]*:/{print $4; exit}' update.json)
_changelog_url=$(awk -F'"' '/"changelog"[[:space:]]*:/{print $4; exit}' update.json)

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

case "$_zip_url" in
  https://github.com/*/releases/download/*/*.zip) ;;
  *)
    echo 'ERROR: update.json zipUrl must be an HTTPS GitHub release ZIP URL' >&2
    exit 1
    ;;
esac
case "$_changelog_url" in
  https://*) ;;
  *)
    echo 'ERROR: update.json changelog must be an HTTPS URL' >&2
    exit 1
    ;;
esac

echo "Update metadata: $_module_ver / $_module_code (future release asset allowed)"
