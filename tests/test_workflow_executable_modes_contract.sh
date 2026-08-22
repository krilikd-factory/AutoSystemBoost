#!/bin/sh
# Contract: uploaded source archives may lose executable bits, but CI must restore modes before
# contracts execute runtime helpers. This prevents a GitHub-only failure after a valid host run.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL workflow executable modes: missing [$2] in $1" >&2; exit 1; }; }
for WF in "$ROOT/.github/workflows/build-debug.yml" "$ROOT/.github/workflows/build-release.yml"; do
  [ -f "$WF" ] || { echo "FAIL workflow executable modes: missing $WF" >&2; exit 1; }
  _norm=$(grep -n 'name: Normalize executable diagnostic script modes' "$WF" | head -1 | cut -d: -f1)
  _tests=$(grep -n 'name: Run canonical host regression' "$WF" | head -1 | cut -d: -f1)
  case "$_norm:$_tests" in *[!0-9:]*|:) echo "FAIL workflow executable modes: expected steps missing in $WF" >&2; exit 1 ;; esac
  [ "$_norm" -lt "$_tests" ] || { echo "FAIL workflow executable modes: normalize step must precede tests in $WF" >&2; exit 1; }
  grep -Fq 'for tool in zip unzip curl file rsync jq; do' "$WF" || {
    echo "FAIL workflow executable modes: jq must be a verified runner dependency in $WF" >&2; exit 1;
  }
  sed -n "${_norm},$(( _norm + 6 ))p" "$WF" | grep -Fq 'chmod 0755 runtime/asb_active_efficiency_envelope.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh tools/asb_kernel_uv_coexist.sh' || {
    echo "FAIL workflow executable modes: required chmod command missing in $WF" >&2; exit 1;
  }
done

# Simulate browser/ZIP mode loss. The exact chmod used in CI must restore every helper.
for p in runtime/asb_active_efficiency_envelope.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh tools/asb_kernel_uv_coexist.sh; do
  mkdir -p "$TMP/$(dirname "$p")"
  cp "$ROOT/$p" "$TMP/$p"
  chmod 0644 "$TMP/$p"
done
(
  cd "$TMP"
  chmod 0755 runtime/asb_active_efficiency_envelope.sh runtime/asb_debug_support.sh runtime/asb_stock_policy.sh tools/asb_kernel_uv_coexist.sh
)
[ -x "$TMP/runtime/asb_active_efficiency_envelope.sh" ] || { echo 'FAIL workflow executable modes: generator mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_debug_support.sh" ] || { echo 'FAIL workflow executable modes: debug support mode not restored' >&2; exit 1; }
[ -x "$TMP/runtime/asb_stock_policy.sh" ] || { echo 'FAIL workflow executable modes: Stock policy mode not restored' >&2; exit 1; }
[ -x "$TMP/tools/asb_kernel_uv_coexist.sh" ] || { echo 'FAIL workflow executable modes: probe mode not restored' >&2; exit 1; }

echo 'PASS workflow executable-mode contract'
