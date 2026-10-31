#!/usr/bin/env bash
# Android-like PackageManager fixtures for the independent HeyTap MCS and DocumentsUI tweaks.
# No device identifiers, accounts, network identifiers or real package state are accessed.

_fixture() {
  ROOT="$1"
  T="$2"
  mkdir -p "$T/mod/config" "$T/mod/runtime" "$T/bin" "$T/db" \
    "$T/state/heytap" "$T/state/documentsui"
  cp "$ROOT/runtime/asb_package_state.sh" "$ROOT/runtime/asb_heytap_mcs.sh" \
    "$ROOT/runtime/asb_art_compile.sh" "$ROOT/runtime/asb_documentsui_fix.sh" \
    "$T/mod/runtime/"
  printf 'heytap_mcs=off\ndocumentsui_fix=1\n' > "$T/mod/config/governor.conf"

  PATH="$T/bin:$PATH"; export PATH
  PKG_DB="$T/db"; export PKG_DB
  PM_LOG="$T/pm.log"; export PM_LOG
  AM_LOG="$T/am.log"; export AM_LOG
  BOOT_FILE="$T/boot_completed"; export BOOT_FILE
  FAIL_ACTION=""; export FAIL_ACTION
  PM_COMPILE_RC=0; export PM_COMPILE_RC
  : > "$PM_LOG"; : > "$AM_LOG"; echo 1 > "$BOOT_FILE"
  for _p in mcs doc fm; do echo 1 > "$PKG_DB/$_p.present"; done
  echo 1 > "$PKG_DB/mcs.enabled"
  echo 0 > "$PKG_DB/doc.enabled"; echo 1 > "$PKG_DB/doc.hidden"
  echo 2 > "$PKG_DB/pick.enabled"; echo 1 > "$PKG_DB/files.enabled"
  echo 1 > "$PKG_DB/fm.enabled"

  ASB_HEYTAP_STATE_DIR="$T/state/heytap"; export ASB_HEYTAP_STATE_DIR
  ASB_DOCUMENTSUI_STATE_DIR="$T/state/documentsui"; export ASB_DOCUMENTSUI_STATE_DIR
  ASB_ART_COMPILE_STATE="$T/state/art.conf"; export ASB_ART_COMPILE_STATE
  ASB_ART_COMPILE_LOCK="$T/state/art.lock"; export ASB_ART_COMPILE_LOCK
  ASB_ART_COMPILE_DELAY=0; export ASB_ART_COMPILE_DELAY
  ASB_ART_COMPILE_TIMEOUT=30; export ASB_ART_COMPILE_TIMEOUT

  cat > "$T/bin/pm" <<'STUB'
#!/bin/sh
_action="${1:-}"
_pkg_name() {
  case "$1" in
    mcs) echo com.heytap.mcs ;;
    doc) echo com.android.documentsui ;;
    fm)  echo com.coloros.filemanager ;;
  esac
}
if [ "$_action" = list ]; then
  for _p in mcs doc fm; do
    [ "$(cat "$PKG_DB/$_p.present" 2>/dev/null)" = 1 ] && echo "package:$(_pkg_name "$_p")"
  done
  exit 0
fi
if [ "$_action" = compile ]; then
  echo "compile $*" >> "$PM_LOG"
  exit "${PM_COMPILE_RC:-0}"
fi
_target=""
for _target in "$@"; do :; done
echo "$_action $_target" >> "$PM_LOG"
if [ -n "${FAIL_ACTION:-}" ] && [ "$_action" = "$FAIL_ACTION" ] && [ ! -f "$PKG_DB/fail_consumed" ]; then
  : > "$PKG_DB/fail_consumed"
  exit 1
fi
case "$_target" in
  com.heytap.mcs) _key=mcs ;;
  com.android.documentsui) _key=doc ;;
  com.coloros.filemanager) _key=fm ;;
  com.android.documentsui/com.android.documentsui.picker.PickActivity) _key=pick ;;
  com.android.documentsui/com.android.documentsui.files.FilesActivity) _key=files ;;
  *) exit 1 ;;
esac
case "$_key" in mcs|doc|fm) [ "$(cat "$PKG_DB/$_key.present" 2>/dev/null)" = 1 ] || exit 1 ;; esac
case "$_action" in
  enable) _value=1 ;;
  disable) _value=2 ;;
  disable-user) _value=3 ;;
  disable-until-used) _value=4 ;;
  default-state) _value=0 ;;
  hide) [ "$_key" = doc ] || exit 1; echo 1 > "$PKG_DB/doc.hidden"; exit 0 ;;
  unhide) [ "$_key" = doc ] || exit 1; echo 0 > "$PKG_DB/doc.hidden"; exit 0 ;;
  *) exit 1 ;;
esac
echo "$_value" > "$PKG_DB/$_key.enabled"
STUB

  cat > "$T/bin/dumpsys" <<'STUB'
#!/bin/sh
[ "${1:-}" = package ] || exit 1
case "${2:-}" in
  com.heytap.mcs) _key=mcs ;;
  com.android.documentsui) _key=doc ;;
  com.coloros.filemanager) _key=fm ;;
  *) exit 1 ;;
esac
[ "$(cat "$PKG_DB/$_key.present" 2>/dev/null)" = 1 ] || exit 1
echo "Package [$2]"
[ ! -f "$PKG_DB/$_key.dump_unknown" ] || exit 0
_enabled="$(cat "$PKG_DB/$_key.enabled" 2>/dev/null)"
[ ! -f "$PKG_DB/$_key.dump_override" ] || _enabled="$(cat "$PKG_DB/$_key.dump_override")"
_hidden=false
if [ "$_key" = doc ] && [ "$(cat "$PKG_DB/doc.hidden")" = 1 ]; then _hidden=true; fi
echo "  User 0: installed=true hidden=$_hidden enabled=$_enabled"
if [ "$_key" = doc ] && [ ! -f "$PKG_DB/doc.component_unknown" ]; then
  echo '    disabledComponents:'
  for _c in pick files; do
    _s="$(cat "$PKG_DB/$_c.enabled")"
    case "$_s" in
      2|3|4)
        [ "$_c" = pick ] && echo '      com.android.documentsui/.picker.PickActivity'
        [ "$_c" = files ] && echo '      com.android.documentsui/com.android.documentsui.files.FilesActivity'
        ;;
    esac
  done
  echo '    enabledComponents:'
  for _c in pick files; do
    _s="$(cat "$PKG_DB/$_c.enabled")"
    [ "$_s" = 1 ] || continue
    [ "$_c" = pick ] && echo '      com.android.documentsui.picker.PickActivity'
    [ "$_c" = files ] && echo '      com.android.documentsui/.files.FilesActivity'
  done
  echo '    queries:'
fi
echo '  User 10: installed=true hidden=false enabled=1'
STUB

  cat > "$T/bin/am" <<'STUB'
#!/bin/sh
echo "$*" >> "$AM_LOG"
exit 0
STUB
  cat > "$T/bin/getprop" <<'STUB'
#!/bin/sh
[ "${1:-}" = sys.boot_completed ] && cat "$BOOT_FILE"
STUB
  chmod 755 "$T/bin"/*
}

_run() {
  _script="$1"; shift
  MODDIR="$T/mod" PATH="$T/bin:$PATH" sh "$T/mod/runtime/$_script" "$@"
}
_state() { cat "$PKG_DB/$1.enabled"; }
_conf() { printf 'heytap_mcs=%s\ndocumentsui_fix=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
_clear_requests() {
  rm -rf "$ASB_HEYTAP_STATE_DIR" "$ASB_DOCUMENTSUI_STATE_DIR" \
    "$ASB_ART_COMPILE_STATE" "$ASB_ART_COMPILE_LOCK"
  mkdir -p "$ASB_HEYTAP_STATE_DIR" "$ASB_DOCUMENTSUI_STATE_DIR"
  rm -f "$PKG_DB"/*.dump_unknown "$PKG_DB"/*.dump_override "$PKG_DB"/*.component_unknown \
    "$PKG_DB/fail_consumed"
}
_compile_count() { grep -c '^compile ' "$PM_LOG" 2>/dev/null || true; }

t_package_state_parsers() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL package state parsers: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  . "$ROOT/runtime/asb_package_state.sh"
  dumpsys package com.android.documentsui > "$T/doc.dump"
  [ "$(asb_pkg_enabled "$T/doc.dump")" = 0 ] || fail 'user 0 enabled state'
  [ "$(asb_pkg_hidden "$T/doc.dump")" = 1 ] || fail 'user 0 hidden state'
  [ "$(asb_component_enabled "$T/doc.dump" com.android.documentsui com.android.documentsui.picker.PickActivity)" = 2 ] \
    || fail 'short disabled component form'
  [ "$(asb_component_enabled "$T/doc.dump" com.android.documentsui com.android.documentsui.files.FilesActivity)" = 1 ] \
    || fail 'full enabled component form'
  echo 0 > "$PKG_DB/pick.enabled"; echo 0 > "$PKG_DB/files.enabled"
  dumpsys package com.android.documentsui > "$T/doc.dump"
  [ "$(asb_component_enabled "$T/doc.dump" com.android.documentsui com.android.documentsui.picker.PickActivity)" = 0 ] \
    || fail 'default component state'
  : > "$PKG_DB/doc.dump_unknown"
  dumpsys package com.android.documentsui > "$T/unknown.dump"
  if asb_pkg_enabled "$T/unknown.dump" >/dev/null; then fail 'missing User 0 became a known state'; fi
  rm -f "$PKG_DB/doc.dump_unknown"; : > "$PKG_DB/doc.component_unknown"
  dumpsys package com.android.documentsui > "$T/unknown.dump"
  if asb_component_enabled "$T/unknown.dump" com.android.documentsui com.android.documentsui.picker.PickActivity >/dev/null; then
    fail 'unexposed component sections became default'
  fi
  echo 1 > "$PKG_DB/mcs.enabled"
  for _s in 0 1 2 3 4; do
    asb_pkg_restore_enabled "$_s" com.heytap.mcs 0 || fail "restore state $_s rejected"
    [ "$(_state mcs)" = "$_s" ] || fail "restore mapping $_s"
  done
  echo 'PASS package state parsers: user-0 states, component forms, unknown gates and exact 0-4 restore'
)

t_heytap_mcs_lifecycle() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL HeyTap lifecycle: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=disabled compile=pending' || fail "apply: $_out"
  [ "$(_state mcs)" = 2 ] || fail 'MCS was not disabled'
  grep -qx 'previous_enabled=1' "$ASB_HEYTAP_STATE_DIR/baseline.conf" || fail 'baseline not saved'
  grep -qx 'state=pending' "$ASB_ART_COMPILE_STATE" || fail 'ART not pending'
  _before="$(cksum < "$ASB_HEYTAP_STATE_DIR/baseline.conf")"
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=already_disabled compile=pending' || fail "repeat apply: $_out"
  [ "$(cksum < "$ASB_HEYTAP_STATE_DIR/baseline.conf")" = "$_before" ] || fail 'repeat apply overwrote baseline'
  _out="$(_run asb_art_compile.sh run-pending)"
  printf '%s\n' "$_out" | grep -q 'result=done exit_code=0' || fail "compile: $_out"
  [ "$(_compile_count)" = 1 ] || fail 'compile did not run exactly once'
  _out="$(_run asb_art_compile.sh run-pending)"
  printf '%s\n' "$_out" | grep -q 'result=not_pending' || fail 'second boot attempted a retry'
  [ "$(_compile_count)" = 1 ] || fail 'second run-pending compiled again'
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=already_disabled compile=done' || fail 'repeat apply resurrected completed ART'
  [ "$(_compile_count)" = 1 ] || fail 'repeat apply compiled again'
  _conf stock 0
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=restored previous_enabled=1' || fail "restore: $_out"
  [ "$(_state mcs)" = 1 ] || fail 'MCS baseline was not restored'
  [ ! -e "$ASB_ART_COMPILE_STATE" ] || fail 'done ART state was not cleared on Stock'
  grep -q 'force-stop com.heytap.mcs' "$AM_LOG" || fail 'MCS was not stopped'
  echo 'PASS HeyTap lifecycle: disable, stable baseline, exactly-once ART and Stock handback'
)

t_heytap_mcs_safety() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL HeyTap safety: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  for _before in 0 1 4; do
    _clear_requests; _conf off 0; echo "$_before" > "$PKG_DB/mcs.enabled"
    _run asb_heytap_mcs.sh apply >/dev/null
    [ "$(_state mcs)" = 2 ] || fail "not disabled from $_before"
    _conf stock 0
    _run asb_heytap_mcs.sh apply >/dev/null
    [ "$(_state mcs)" = "$_before" ] || fail "state $_before not restored"
  done
  for _before in 2 3; do
    _clear_requests; _conf off 0; echo "$_before" > "$PKG_DB/mcs.enabled"
    _out="$(_run asb_heytap_mcs.sh apply)"
    printf '%s\n' "$_out" | grep -q 'result=already_disabled' || fail 'pre-disabled state was rewritten'
    [ ! -f "$ASB_HEYTAP_STATE_DIR/baseline.conf" ] || fail 'ASB claimed a pre-disabled package'
    _conf stock 0; _run asb_heytap_mcs.sh apply >/dev/null
    [ "$(_state mcs)" = "$_before" ] || fail 'pre-disabled package was enabled on Stock'
  done
  _clear_requests; _conf off 0; echo 1 > "$PKG_DB/mcs.enabled"; : > "$PKG_DB/mcs.dump_unknown"
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=state_unknown' || fail 'unknown state did not fail closed'
  [ "$(_state mcs)" = 1 ] || fail 'unknown state caused a write'
  [ ! -e "$ASB_ART_COMPILE_STATE" ] || fail 'unknown state requested ART'
  rm -f "$PKG_DB/mcs.dump_unknown"; FAIL_ACTION=disable
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=write_failed' || fail 'rejected disable not reported'
  [ "$(_state mcs)" = 1 ] || fail 'rejected disable changed state'
  FAIL_ACTION=; : > "$PKG_DB/mcs.dump_override"
  echo 1 > "$PKG_DB/mcs.dump_override"
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=readback_mismatch' || fail 'silent readback mismatch not reported'
  [ "$(_state mcs)" = 1 ] || fail 'readback mismatch did not roll back'
  [ ! -e "$ASB_ART_COMPILE_STATE" ] || fail 'failed apply left ART pending'
  echo 0 > "$PKG_DB/mcs.present"; rm -f "$PKG_DB/mcs.dump_override"
  _out="$(_run asb_heytap_mcs.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=absent' || fail 'absent package not handled'
  echo 'PASS HeyTap safety: pre-disabled ownership, 0/1/4 restore, unknown/rejected/readback failures'
)

t_art_compile_cancel_and_failure() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL ART cancellation/failure: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  echo 2 > "$PKG_DB/mcs.enabled"
  _run asb_art_compile.sh request >/dev/null
  _out="$(_run asb_art_compile.sh cancel)"
  printf '%s\n' "$_out" | grep -q 'result=cancelled' || fail 'pending request not cancelled'
  _out="$(_run asb_art_compile.sh run-pending)"
  printf '%s\n' "$_out" | grep -q 'result=not_pending' || fail 'cancelled request ran at boot'
  [ "$(_compile_count)" = 0 ] || fail 'cancelled request compiled'

  _run asb_art_compile.sh request >/dev/null
  PM_COMPILE_RC=1
  _out="$(_run asb_art_compile.sh run-pending)"
  printf '%s\n' "$_out" | grep -q 'result=failed reason=pm_compile_failed exit_code=1' || fail "failure not recorded: $_out"
  [ "$(_compile_count)" = 1 ] || fail 'failed compile count'
  _run asb_art_compile.sh run-pending >/dev/null
  _out="$(_run asb_art_compile.sh request)"
  printf '%s\n' "$_out" | grep -q 'result=failed' || fail 'failed request was silently re-armed'
  [ "$(_compile_count)" = 1 ] || fail 'failed compile retried automatically'

  _run asb_art_compile.sh cancel >/dev/null
  echo 1 > "$PKG_DB/mcs.enabled"
  _run asb_art_compile.sh request >/dev/null
  _out="$(_run asb_art_compile.sh run-pending)"
  printf '%s\n' "$_out" | grep -q 'result=failed reason=mcs_not_disabled' || fail 'MCS ownership gate missing'
  [ "$(_compile_count)" = 1 ] || fail 'compile ran while MCS was enabled'
  echo 'PASS ART lifecycle: cancel before boot, failed means no retry, MCS state gate'
)

t_documentsui_lifecycle() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL DocumentsUI lifecycle: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=applied' || fail "apply: $_out"
  [ "$(_state doc)" = 1 ] || fail 'DocumentsUI not enabled'
  [ "$(cat "$PKG_DB/doc.hidden")" = 0 ] || fail 'DocumentsUI not unhidden'
  [ "$(_state pick)" = 0 ] || fail 'PickActivity not reset'
  [ "$(_state files)" = 0 ] || fail 'FilesActivity not reset'
  [ "$(_state fm)" = 3 ] || fail 'ColorOS File Manager not disabled for user 0'
  [ "$(_compile_count)" = 0 ] || fail 'DocumentsUI unexpectedly requested ART'
  _before="$(cksum < "$ASB_DOCUMENTSUI_STATE_DIR/baseline.conf")"
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=already_applied' || fail 'repeat apply not idempotent'
  [ "$(cksum < "$ASB_DOCUMENTSUI_STATE_DIR/baseline.conf")" = "$_before" ] || fail 'repeat apply overwrote baseline'
  _conf stock 0
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=restored' || fail "restore: $_out"
  [ "$(_state doc)" = 0 ] || fail 'DocumentsUI enabled state not restored'
  [ "$(cat "$PKG_DB/doc.hidden")" = 1 ] || fail 'DocumentsUI hidden state not restored'
  [ "$(_state pick)" = 2 ] || fail 'PickActivity state not restored'
  [ "$(_state files)" = 1 ] || fail 'FilesActivity state not restored'
  [ "$(_state fm)" = 1 ] || fail 'File Manager state not restored'
  [ ! -e "$ASB_ART_COMPILE_STATE" ] || fail 'DocumentsUI created ART state'
  echo 'PASS DocumentsUI lifecycle: apply/readback, idempotence, exact restore and no ART'
)

t_documentsui_safety() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail() { echo "FAIL DocumentsUI safety: $*" >&2; exit 1; }
  _fixture "$ROOT" "$T"
  # Only PickActivity needs a write. Off must not touch the other already-target states.
  echo 1 > "$PKG_DB/doc.enabled"; echo 0 > "$PKG_DB/doc.hidden"
  echo 2 > "$PKG_DB/pick.enabled"; echo 0 > "$PKG_DB/files.enabled"; echo 3 > "$PKG_DB/fm.enabled"
  _run asb_documentsui_fix.sh apply >/dev/null
  : > "$PM_LOG"; _conf stock 0; _run asb_documentsui_fix.sh apply >/dev/null
  [ "$(wc -l < "$PM_LOG")" = 1 ] || fail "restore touched unchanged fields: $(tr '\n' ' ' < "$PM_LOG")"
  grep -qx 'disable com.android.documentsui/com.android.documentsui.picker.PickActivity' "$PM_LOG" \
    || fail 'wrong component restore'
  [ "$(_state doc)" = 1 ] && [ "$(_state files)" = 0 ] && [ "$(_state fm)" = 3 ] \
    || fail 'unchanged fields were not preserved'

  _clear_requests; _conf off 1
  echo 1 > "$PKG_DB/doc.enabled"; echo 0 > "$PKG_DB/doc.hidden"
  echo 0 > "$PKG_DB/pick.enabled"; echo 0 > "$PKG_DB/files.enabled"; echo 3 > "$PKG_DB/fm.enabled"
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=already_fixed' || fail 'already-fixed state not detected'
  [ ! -f "$ASB_DOCUMENTSUI_STATE_DIR/baseline.conf" ] || fail 'already-fixed state gained a baseline'

  _clear_requests
  echo 0 > "$PKG_DB/doc.enabled"; echo 1 > "$PKG_DB/doc.hidden"
  echo 2 > "$PKG_DB/pick.enabled"; echo 1 > "$PKG_DB/files.enabled"; echo 1 > "$PKG_DB/fm.enabled"
  : > "$PKG_DB/doc.component_unknown"
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=state_unknown field=pick_enabled' || fail 'unknown component did not fail closed'
  [ "$(_state doc)" = 0 ] && [ "$(_state fm)" = 1 ] || fail 'unknown component caused writes'
  rm -f "$PKG_DB/doc.component_unknown"; FAIL_ACTION=enable
  _out="$(_run asb_documentsui_fix.sh apply)"
  printf '%s\n' "$_out" | grep -q 'result=write_failed_rolled_back' || fail "rollback result: $_out"
  [ "$(_state doc)" = 0 ] || fail 'rollback did not restore DocumentsUI'
  [ "$(cat "$PKG_DB/doc.hidden")" = 1 ] || fail 'rollback did not rehide DocumentsUI'
  [ "$(_state pick)" = 2 ] && [ "$(_state files)" = 1 ] || fail 'rollback did not restore components'
  [ "$(_state fm)" = 1 ] || fail 'rollback did not restore File Manager'
  [ ! -f "$ASB_DOCUMENTSUI_STATE_DIR/baseline.conf" ] || fail 'successful rollback left a baseline'
  [ "$(_compile_count)" = 0 ] || fail 'failure path invoked ART'
  echo 'PASS DocumentsUI safety: changed-fields-only restore, unknown gate and rejected-write rollback'
)

t_package_tweaks_contract() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL package tweaks contract: $*" >&2; exit 1; }
  for _f in asb_package_state.sh asb_heytap_mcs.sh asb_art_compile.sh asb_documentsui_fix.sh; do
    sh -n "$ROOT/runtime/$_f" || fail "$_f syntax"
    [ -x "$ROOT/runtime/$_f" ] || fail "$_f is not executable"
  done
  # A ZIP retains these modes, but a browser upload to git may not. Both CI entry points must
  # restore all four before this contract runs; checking only the first failure hides the rest.
  for _wf in "$ROOT/.github/workflows/build-test.yml" "$ROOT/.github/workflows/build-release.yml"; do
    for _f in asb_package_state.sh asb_heytap_mcs.sh asb_art_compile.sh asb_documentsui_fix.sh; do
      sed -n '/- name: Normalize executable source script modes/,/- name: Validate required source files/p' "$_wf" \
        | grep -Fq "runtime/$_f" || fail "$_wf does not restore the executable mode of $_f"
    done
  done
  ! grep -q '\.replace/' "$ROOT/runtime/asb_heytap_mcs.sh" || fail 'HeyTap uses a .replace overlay'
  grep -q 'timeout "$TIMEOUT_S" pm compile -m speed-profile -a' "$ROOT/runtime/asb_art_compile.sh" \
    || fail 'exact one-shot compile command missing'
  ! grep -q 'pm compile\|asb_art_compile' "$ROOT/runtime/asb_documentsui_fix.sh" \
    || fail 'DocumentsUI is coupled to ART compilation'
  grep -q 'asb_art_compile.sh" run-pending' "$ROOT/service.sh" || fail 'boot does not consume pending ART'
  ! grep -q 'asb_documentsui_fix.sh" apply\|asb_heytap_mcs.sh" apply' "$ROOT/service.sh" \
    || fail 'package states are re-applied at every boot'
  grep -q 'asb_heytap_mcs.sh" restore' "$ROOT/uninstall.sh" || fail 'uninstall does not restore MCS'
  grep -q 'asb_documentsui_fix.sh" restore' "$ROOT/uninstall.sh" || fail 'uninstall does not restore DocumentsUI'
  ! grep -q 'pm compile --reset\|pm compile -m speed-profile' "$ROOT/uninstall.sh" \
    || fail 'uninstall performs a mass ART reset/compile'
  grep -q 'HeyTap MCS / ART (read-only)' "$ROOT/tools/asb_diag.sh" || fail 'asbdiag lacks HeyTap status'
  grep -q 'DocumentsUI / DSU picker (read-only)' "$ROOT/tools/asb_diag.sh" || fail 'asbdiag lacks DocumentsUI status'
  cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail 'asbdiag copies differ'
  echo 'PASS package tweak contracts: no overlay, one boot consumer, no DocumentsUI ART, restore/uninstall'
)

t_webui_package_tweaks_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL WebUI package tweaks: $*" >&2; exit 1; }
  command -v node >/dev/null 2>&1 || { echo 'SKIP WebUI package tweaks: no node'; exit 0; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  {
    cat <<'JS'
function T(k, d) { return d; }
let _heyTweak = null, _docTweak = null;
JS
    sed -n '/^function packageTweakParse(/,/^}/p; /^function packageTweakBadge(/,/^}/p' "$ROOT/webroot/index.html"
    cat <<'JS'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
const p = packageTweakParse('present=1\nsetting=off\nstate=pending\nreason=not exposed');
chk(p.present === '1' && p.state === 'pending' && p.reason === 'not exposed', 'status parser');
for (const s of ['pending','running','done','failed']) {
  _heyTweak = {present:'1', state:s};
  chk(packageTweakBadge('heytap_mcs', 'off').text.length > 0, 'MCS badge ' + s);
}
_heyTweak = {present:'0', state:'idle'};
chk(packageTweakBadge('heytap_mcs', 'off').text === 'MCS not installed', 'MCS absent badge');
chk(packageTweakBadge('heytap_mcs', 'stock').text === 'Disabled', 'MCS Stock badge');
_docTweak = {present:'1', asb_changed:'1'};
chk(packageTweakBadge('documentsui_fix', '1').cls === 'good', 'DocumentsUI applied badge');
_docTweak = {present:'1', asb_changed:'0'};
chk(packageTweakBadge('documentsui_fix', '1').text === 'already repaired', 'DocumentsUI pre-fixed badge');
_docTweak = {present:'0', asb_changed:'0'};
chk(packageTweakBadge('documentsui_fix', '1').text === 'DocumentsUI absent', 'DocumentsUI absent badge');
chk(packageTweakBadge('documentsui_fix', '0').text === 'Disabled', 'DocumentsUI Off badge');
if (bad) process.exit(1); console.log('ok');
JS
  } > "$T/test.js"
  _out="$(node "$T/test.js" 2>&1)" || fail "$_out"
  [ "$_out" = ok ] || fail "$_out"
  grep -q 'await loadPackageTweakStatus();' "$ROOT/webroot/index.html" || fail 'status refresh missing'
  grep -q 'loadPackageTweakStatus();' "$ROOT/webroot/index.html" || fail 'initial status load missing'
  echo 'PASS WebUI package tweaks: parser, absent/pending/running/done/failed and DocumentsUI badges'
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac
