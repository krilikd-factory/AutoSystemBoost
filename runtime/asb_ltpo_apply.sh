#!/system/bin/sh
# Force-LTPO runtime bind owner.
#
# install.sh (asb_prepare_ltpo_patch) clones THIS device's oplus_vrr_config.json, flips
# the idle frame-drop switches the OEM shipped off, and registers the pair in
# ltpo_bind_manifest.txt. This script is the only consumer: it binds the patched table
# over the stock one when ltpo_force=1, and removes its own binds when the toggle is
# off, the feature is uninstalled, or the bootloop fuse is set.
#
# The stock file is never modified - a bind mount only shadows it, so stock is always
# one umount (or one reboot) away.
#
# The display stack reads this config when it starts, so a live bind changes what the
# NEXT boot (or display service restart) sees, not the running one. The WebUI says so.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done

# Injectable for host-side fixtures, same pattern as the Wi-Fi fallback watcher.
STATE_DIR="${ASB_LTPO_STATE_DIR:-/data/adb/asb}"
MAN="$STATE_DIR/ltpo_bind_manifest.txt"
ACTIVE="$STATE_DIR/ltpo_bind.active"
BLOCK="$STATE_DIR/vendor_overlay_blocked"
MOUNTS_LOG="$STATE_DIR/vendor_mounts.log"
CONF="$MODDIR/config/governor.conf"

_cfg() {
  [ -f "$CONF" ] || return 0
  _v="$(grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r')"
  printf '%s' "$_v"
}

_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "ts=$(date +%s 2>/dev/null || echo 0) $*" >> "$MOUNTS_LOG" 2>/dev/null
}

# Where the patched table may be bound. Only the real partition paths are allowed in
# production; ASB_LTPO_LIVE_ROOT exists for host fixtures, which relocate the live tree,
# and is never set on a device - so on a device this list is the whole story.
_ltpo_target_allowed() {
  case "$1" in
    /my_product/etc/oplus_vrr_config.json|/odm/etc/oplus_vrr_config.json|\
    /vendor/etc/oplus_vrr_config.json|/system_ext/etc/oplus_vrr_config.json|\
    /product/etc/oplus_vrr_config.json) return 0 ;;
  esac
  [ -n "${ASB_LTPO_LIVE_ROOT:-}" ] || return 1
  case "$1" in
    "${ASB_LTPO_LIVE_ROOT%/}"/*/etc/oplus_vrr_config.json|"${ASB_LTPO_LIVE_ROOT%/}"/etc/oplus_vrr_config.json) return 0 ;;
  esac
  return 1
}

# Fail-closed manifest validation, mirroring asb_overlay_guard.sh: a malformed or
# out-of-bounds entry must never become a mount in front of the display service.
_ltpo_guard() {
  [ -f "$MAN" ] || return 1
  _g_n=0
  while IFS='|' read -r _g_t _g_p _g_x; do
    case "$_g_t$_g_p$_g_x" in ''|'#'*) continue ;; esac
    [ -n "$_g_t" ] && [ -n "$_g_p" ] && [ -z "$_g_x" ] || return 1
    _ltpo_target_allowed "$_g_t" || return 1
    case "$_g_p" in "$STATE_DIR/ltpo_patched/"*) ;; *) return 1 ;; esac
    [ -s "$_g_p" ] || return 1
    [ -e "$_g_t" ] || return 1
    _g_open="$(tr -cd '{' < "$_g_p" 2>/dev/null | wc -c)"
    _g_close="$(tr -cd '}' < "$_g_p" 2>/dev/null | wc -c)"
    [ "${_g_open:-0}" = "${_g_close:-1}" ] && [ "${_g_open:-0}" -gt 0 ] 2>/dev/null || return 1
    _g_n=$((_g_n + 1))
  done < "$MAN"
  [ "$_g_n" -gt 0 ]
}

_is_bound() {
  # A bind-mounted file appears as its own mountpoint; the stock file on the partition
  # does not. This is what "we own a bind here" means. The mounts table is injectable
  # for host fixtures, the same portability pattern as the Wi-Fi fallback's PROC_ROOT.
  grep -q " $1 " "${ASB_LTPO_PROC_MOUNTS:-/proc/mounts}" 2>/dev/null
}

_bind_one() {
  _b_t="$1"; _b_p="$2"
  _is_bound "$_b_t" && { cmp -s "$_b_t" "$_b_p" 2>/dev/null && return 0; }
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- mount --bind "$_b_p" "$_b_t" 2>/dev/null; then
    return 0
  fi
  mount --bind "$_b_p" "$_b_t" 2>/dev/null
}

_unbind_one() {
  _u_t="$1"
  _is_bound "$_u_t" || return 0
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- umount "$_u_t" 2>/dev/null; then
    return 0
  fi
  umount "$_u_t" 2>/dev/null
}

_ltpo_bind_all() {
  _a_any=0
  while IFS='|' read -r _a_t _a_p; do
    case "$_a_t" in ''|'#'*) continue ;; esac
    if _bind_one "$_a_t" "$_a_p"; then
      _a_any=1
      : > "$ACTIVE" 2>/dev/null
    fi
  done < "$MAN"
  [ "$_a_any" = "1" ]
}

_ltpo_unbind_all() {
  _r_any=0
  [ -f "$MAN" ] || { rm -f "$ACTIVE" 2>/dev/null; return 1; }
  while IFS='|' read -r _r_t _r_p; do
    case "$_r_t" in ''|'#'*) continue ;; esac
    _unbind_one "$_r_t" && _r_any=1
  done < "$MAN"
  rm -f "$ACTIVE" 2>/dev/null
  [ "$_r_any" = "1" ]
}

case "${1:-apply}" in
  apply)
    if [ "$(_cfg ltpo_force)" = "1" ] && [ ! -f "$BLOCK" ] && _ltpo_guard; then
      if _ltpo_bind_all; then
        _log 'action=ltpo_bind result=applied'
      fi
    else
      # Toggle off (or fuse set): a bind of ours must not survive the choice that
      # removed it. Stock content is what the file shows again from this umount on.
      if [ -f "$ACTIVE" ]; then
        _ltpo_unbind_all && _log 'action=ltpo_bind result=removed'
      fi
    fi
    ;;
  remove)
    # Uninstall path: drop whatever we own regardless of the toggle state.
    _ltpo_unbind_all && _log 'action=ltpo_bind result=removed reason=uninstall'
    ;;
  status)
    if [ ! -f "$MAN" ]; then
      echo 'ltpo_patch_absent'
    elif [ "$(_cfg ltpo_force)" != "1" ]; then
      echo 'ltpo_off'
    elif [ -f "$ACTIVE" ]; then
      echo 'ltpo_active'
    else
      echo 'ltpo_pending_boot'
    fi
    ;;
esac
exit 0
