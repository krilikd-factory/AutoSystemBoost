#!/usr/bin/env bash
# Contract: ASB never pretends to accelerate a full reboot. Quick restart must choose only
# a ROM-supported userspace reboot; it must not kill processes directly, persist boot
# properties, restart Zygote as an unsupported shortcut, or turn a refused request into a generic reboot.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_quick_restart.sh"
UI="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL quick restart contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { ! grep -Fq "$2" "$1" || fail "unexpected [$2] in $1"; }
[ -f "$HELPER" ] || fail 'quick restart helper missing'

need "$HELPER" 'init.userspace_reboot.is_supported'
need "$HELPER" 'svc power reboot userspace'
need "$HELPER" 'sys.boot_completed'
absent "$HELPER" 'killall'
absent "$HELPER" 'ctl.restart zygote'
absent "$HELPER" 'sys.powerctl'
absent "$HELPER" 'persist.'
need "$UI" "const ASB_QUICK_RESTART = MD + '/runtime/asb_quick_restart.sh';"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' status'"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' restart'"
absent "$UI" 'setprop ctl.restart zygote 2>/dev/null || killall zygote'
need "$UI" 't_quick_explain'
need "$UI" 't_quick_unavailable'
need "$INSTALL" 'asb_quick_restart.sh'

python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
keys = {'t_quick_explain','t_quick_confirm','t_quick_going','t_quick_unavailable'}
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for path in files:
    data = json.loads(path.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{path.name}: missing {missing}'
print('PASS quick restart locale keys: 13 locales')
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"
cat > "$TMP/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  sys.boot_completed) printf '%s\n' "${ASB_TEST_BOOT:-1}" ;;
  init.userspace_reboot.is_supported) printf '%s\n' "${ASB_TEST_USERSPACE:-0}" ;;
  *) printf '\n' ;;
esac
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf 'svc:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SVC_RC:-0}"
EOF
cat > "$TMP/bin/setprop" <<'EOF'
#!/bin/sh
printf 'setprop:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SETPROP_RC:-0}"
EOF
chmod 0755 "$TMP/bin/getprop" "$TMP/bin/svc" "$TMP/bin/setprop"

run_helper() {
  PATH="$TMP/bin:$PATH" \
  ASB_TEST_LOG="$TMP/calls.log" \
  ASB_TEST_BOOT="${1:-1}" \
  ASB_TEST_USERSPACE="${2:-0}" \
  sh "$HELPER" "${3:-status}"
}

out="$(run_helper 1 1 status)"
[ "$out" = 'mode=userspace reason=init_supported' ] || fail "userspace status: $out"
: > "$TMP/calls.log"
out="$(run_helper 1 1 restart)"
[ "$out" = $'mode=userspace reason=init_supported\nrequested=userspace' ] || fail "userspace restart: $out"
grep -qx 'svc:power reboot userspace' "$TMP/calls.log" || fail 'userspace request not issued exactly once'
! grep -q '^setprop:' "$TMP/calls.log" || fail 'userspace path must not restart zygote'

: > "$TMP/calls.log"
if run_helper 1 0 status >/tmp/asb_quick_restart_nosupport.out 2>&1; then
  fail 'quick restart accepted without init userspace capability'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "userspace-not-supported exit=$rc"
fi
grep -qx 'mode=unavailable reason=userspace_not_supported' /tmp/asb_quick_restart_nosupport.out || fail 'userspace-not-supported verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unsupported path issued a restart command'

: > "$TMP/calls.log"
if run_helper 0 1 status >/tmp/asb_quick_restart_unavailable.out 2>&1; then
  fail 'quick restart accepted before boot complete'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "boot-not-complete exit=$rc"
fi
grep -qx 'mode=unavailable reason=boot_not_completed' /tmp/asb_quick_restart_unavailable.out || fail 'boot-not-complete verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unavailable path issued a restart command'

rm -f /tmp/asb_quick_restart_unavailable.out /tmp/asb_quick_restart_nosupport.out

echo 'PASS quick restart capability and no-destructive-fallback contract'
