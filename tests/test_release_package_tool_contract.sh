#!/bin/sh
# Release ZIP contract: tools/ is intentionally excluded from the module package,
# then selected runtime/support tools are copied back by name. Every tool required by
# the ZIP validator must therefore occur in that copy-back section.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/build-release.yml"

[ -f "$WF" ] || { echo "FAIL: release workflow missing: $WF" >&2; exit 1; }
grep -Fq -- "--exclude 'tools'" "$WF" || {
  echo "FAIL: test assumes wholesale tools exclusion is present" >&2
  exit 1
}

# Package RELEASE zip spans through the generated manifest; its selected tool
# copy-back declarations must cover every tools/... entry in Validate RELEASE zip.
COPYBACK="$(sed -n '/# V48: ship the Smart Mode user-facing CLI tool/,/ASB_VER=$(grep/p' "$WF")"
REQUIRED_TOOLS="$(sed -n '/for required in \\/,/webroot\/index.html"; do/p' "$WF" \
  | grep -oE '"tools/[A-Za-z0-9_./-]+"' \
  | tr -d '"' \
  | sort -u)"

[ -n "$REQUIRED_TOOLS" ] || {
  echo "FAIL: no tools paths found in release ZIP required-file contract" >&2
  exit 1
}

for path in $REQUIRED_TOOLS; do
  name="${path#tools/}"
  if ! printf '%s\n' "$COPYBACK" | grep -Fq -- "$name"; then
    echo "FAIL: release ZIP requires $path but Package RELEASE zip does not copy it back" >&2
    exit 1
  fi
  [ -f "$ROOT/$path" ] || {
    echo "FAIL: release ZIP requires missing source file: $path" >&2
    exit 1
  }
done

printf 'PASS: %s release-required tools are covered by package copy-back\n' \
  "$(printf '%s\n' "$REQUIRED_TOOLS" | wc -l | tr -d ' ')"
