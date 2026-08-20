#!/usr/bin/env sh
# Regression contract: release metadata must validate before the future release
# asset exists. The validator checks identity and URL shape, never URL existence
# or a path derived from the currently compiled version.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb-meta.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/tools"
cp "$ROOT/tools/asb_validate_release_metadata.sh" "$TMP/tools/"

cat >"$TMP/module.prop" <<'EOF'
version=V63
versionCode=630
EOF
cat >"$TMP/update.json" <<'EOF'
{
  "version": "V63",
  "versionCode": 630,
  "zipUrl": "https://github.com/example/AutoSystemBoost/releases/download/next-public-release/ASB-V63.zip",
  "changelog": "https://raw.githubusercontent.com/example/AutoSystemBoost/main/CHANGELOG.md"
}
EOF

# A valid future release URL must pass before any asset has been uploaded.
(
  cd "$TMP"
  sh tools/asb_validate_release_metadata.sh
)

# Version identity remains strict.
sed -i 's/"version": "V63"/"version": "V62"/' "$TMP/update.json"
if (cd "$TMP" && sh tools/asb_validate_release_metadata.sh >/dev/null 2>&1); then
  echo 'FAIL: stale update.json version was accepted' >&2
  exit 1
fi
sed -i 's/"version": "V62"/"version": "V63"/' "$TMP/update.json"

# URL shape remains strict; this must not become a blind allow-all check.
sed -i 's#https://github.com/example/AutoSystemBoost/releases/download/next-public-release/ASB-V63.zip#http://example.invalid/not-a-release.txt#' "$TMP/update.json"
if (cd "$TMP" && sh tools/asb_validate_release_metadata.sh >/dev/null 2>&1); then
  echo 'FAIL: malformed zipUrl was accepted' >&2
  exit 1
fi

echo 'PASS: release metadata validator accepts future asset URL and rejects stale/malformed metadata'
