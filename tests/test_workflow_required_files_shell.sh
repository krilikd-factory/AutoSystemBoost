#!/bin/sh
# Contract: the required-source-files blocks are executable shell, not merely YAML text.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL workflow required-files shell: $*" >&2; exit 1; }
extract_step() {
  _wf="$1" _out="$2"
  awk '
    /- name: Validate required source files/ { capture=1; next }
    capture && /^      - name:/ { exit }
    capture && /^          / {
      line=$0; sub(/^          /, "", line)
      if (line != "run: |") print line
    }
  ' "$_wf" > "$_out"
  [ -s "$_out" ] || fail "could not extract required-files step from $(basename "$_wf")"
}

for name in build-debug.yml build-release.yml; do
  wf="$ROOT/.github/workflows/$name"
  out="$TMP/${name%.yml}.sh"
  [ -f "$wf" ] || fail "missing $wf"
  extract_step "$wf" "$out"
  sh -n "$out" || fail "$name extracted shell has syntax error"
  (cd "$ROOT" && sh "$out") || fail "$name required-files step fails"
done

echo "PASS workflow required-files shell contract"
