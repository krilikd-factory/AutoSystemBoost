#!/system/bin/sh
# asb_boot_timeline.sh — debug-only, passive boot lifecycle evidence.
#
# It records short marker rows only. No property, service, package or policy is modified.
# The script is called from post-fs-data/service and embedded in asbdiag so a tester need only
# press the existing debug asbdiag button after a reboot; no terminal command is required.
set -u

MODID="AutoSystemBoost"
resolve_moddir() {
  for _d in \
    "${ASB_BOOT_TIMELINE_MODDIR:-}" \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID" \
    "/data/adb/ap/modules/$MODID"; do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] || continue
    grep -qx "id=$MODID" "$_d/module.prop" 2>/dev/null && { printf '%s' "$_d"; return 0; }
  done
  return 1
}

MODDIR="$(resolve_moddir 2>/dev/null || true)"
[ -n "$MODDIR" ] || { echo 'status=module_not_found'; exit 2; }
VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
_debug_seq="${VERSION##*-debug}"
case "$VERSION:$_debug_seq" in
  *-debug[1-9]*:[1-9]* ) case "$_debug_seq" in *[!0-9]*) echo 'status=debug_only'; exit 3 ;; esac ;;
  *) echo 'status=debug_only'; exit 3 ;;
esac

STATE_DIR="${ASB_BOOT_TIMELINE_STATE_DIR:-/data/adb/asb}"
OUT="$STATE_DIR/boot_timeline.tsv"

_uptime_ms() {
  _u="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
  printf '%s000' "$_u"
}
_prop() { getprop "$1" 2>/dev/null | tr -d '\r\n'; }
_safe_label() {
  case "${1:-}" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
  return 0
}
_row() {
  _label="$1"
  _safe_label "$_label" || { echo 'status=invalid_label'; exit 64; }
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'status=state_unavailable'; exit 1; }
  printf '%s\t%s\tboot_completed=%s\taudioserver=%s\tsurfaceflinger=%s\tzygote=%s\n' \
    "$(_uptime_ms)" "$_label" \
    "$(_prop sys.boot_completed)" "$(_prop init.svc.audioserver)" \
    "$(_prop init.svc.surfaceflinger)" "$(_prop init.svc.zygote)" >> "$OUT" 2>/dev/null || {
      echo 'status=write_failed'; exit 1;
    }
  echo "status=marked label=$_label"
}

case "${1:-}" in
  begin)
    mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'status=state_unavailable'; exit 1; }
    {
      printf '# ASB debug boot timeline v1\n'
      printf '# version=%s\n' "$VERSION"
      printf '# bootreason=%s\n' "$(_prop ro.boot.bootreason)"
      printf '# columns=uptime_ms\tmarker\tboot_completed\taudioserver\tsurfaceflinger\tzygote\n'
    } > "$OUT" 2>/dev/null || { echo 'status=write_failed'; exit 1; }
    _row "${2:-postfs_begin}"
    ;;
  mark) _row "${2:-}" ;;
  path) [ -r "$OUT" ] && printf 'status=ready path=%s\n' "$OUT" || printf 'status=absent path=%s\n' "$OUT" ;;
  *) echo 'usage=asb_boot_timeline {begin [marker]|mark MARKER|path}'; exit 64 ;;
esac
