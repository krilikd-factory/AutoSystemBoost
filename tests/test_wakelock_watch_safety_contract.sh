#!/bin/sh
# Contract: screen-off wake mitigation must remain conservative and must never silently
# restrict notification-bearing messaging packages observed in real wake-source context.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
fail() { echo "FAIL wakelock watcher safety: $*" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "missing [$2]"; }
absent() { ! grep -Eq -- "$2" "$1" || fail "unsafe pattern [$2]"; }

[ -f "$SRC" ] || fail 'missing runtime watcher'
sh -n "$SRC" || fail 'shell syntax'

# Measurement may run, but state-changing action remains opt-in and only after a truly long,
# demonstrably awake screen-off window; this excludes ordinary foreground/wake transients.
need "$SRC" 'case "$(_cfg wakelock_action)" in'
need "$SRC" '[ "${_win:-0}" -ge 45 ]'
need "$SRC" '[ "${_awake:-0}" -ge 25 ]'
need "$SRC" 'pm list packages -3'
need "$SRC" 'am set-standby-bucket "$_p" restricted'
absent "$SRC" 'am[[:space:]]+(force-stop|kill|crash)'

# A comment promises messaging protection. Match packages that do not literally contain
# "messaging" as well, including WhatsApp observed in Debug 6 and major common messengers.
for protected in '*whatsapp*' '*telegram*' '*signal*' '*viber*' '*discord*' '*wechat*'; do
  need "$SRC" "$protected"
done
need "$SRC" 'never auto-restrict them here'

# Kernel/system wake sources and multicast remain report-only; no attempt is made to release
# another component's wakelock directly.
need "$SRC" 'Never a kernel source, never a'
need "$SRC" 'asb_wl_relax_multicast'
absent "$SRC" 'wake_unlock'

echo 'PASS wakelock watcher safety contract'
