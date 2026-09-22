#!/system/bin/sh
# Multimedia-telemetry-off runtime bind owner.
#
# install.sh (asb_prepare_mmfeed_patch) clones THIS device's Multimedia_Feedback_List.xml,
# flips <isOpen>true</isOpen> to false - which closes the OPlus multimedia feedback
# collector (audio/video/display diag events, dumps and uploads) - and registers the
# pair in mmfeed_bind_manifest.txt. This script is the only consumer: it binds the
# patched copy over the stock one when mmfeed_off=1, and removes its own binds when the
# toggle is off, the feature is uninstalled, or the bootloop fuse is set.
#
# The stock file is never modified - a bind mount only shadows it, so stock is always
# one umount (or one reboot) away. Same fail-closed contract as the LTPO bind owner.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done

# Injectable for host-side fixtures, same pattern as the LTPO bind owner.
STATE_DIR="${ASB_MMFEED_STATE_DIR:-/data/adb/asb}"
MAN="$STATE_DIR/mmfeed_bind_manifest.txt"
ACTIVE="$STATE_DIR/mmfeed_bind.active"
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

# Where the patched config may be bound. Only the real partition paths are allowed in
# production; ASB_MMFEED_LIVE_ROOT exists for host fixtures, which relocate the live
# tree, and is never set on a device - so on a device this list is the whole story.
_mmfeed_target_allowed() {
  case "$1" in
    /my_product/etc/Multimedia_Feedback_List.xml|/odm/etc/Multimedia_Feedback_List.xml|\
    /vendor/etc/Multimedia_Feedback_List.xml|/system_ext/etc/Multimedia_Feedback_List.xml|\
    /product/etc/Multimedia_Feedback_List.xml) return 0 ;;
  esac
  [ -n "${ASB_MMFEED_LIVE_ROOT:-}" ] || return 1
  case "$1" in
    "${ASB_MMFEED_LIVE_ROOT%/}"/*/etc/Multimedia_Feedback_List.xml|"${ASB_MMFEED_LIVE_ROOT%/}"/etc/Multimedia_Feedback_List.xml) return 0 ;;
  esac
  return 1
}

# Fail-closed manifest validation, mirroring asb_ltpo_apply.sh: a malformed or
# out-of-bounds entry must never become a mount in front of the feedback service.
# The payload is XML, so the sanity check is structural: exactly one isOpen tag and
# the filter-conf root element must survive intact.
_mmfeed_guard() {
  [ -f "$MAN" ] || return 1
  _g_n=0
  while IFS='|' read -r _g_t _g_p _g_x; do
    case "$_g_t$_g_p$_g_x" in ''|'#'*) continue ;; esac
    [ -n "$_g_t" ] && [ -n "$_g_p" ] && [ -z "$_g_x" ] || return 1
    _mmfeed_target_allowed "$_g_t" || return 1
    case "$_g_p" in "$STATE_DIR/mmfeed_patched/"*) ;; *) return 1 ;; esac
    [ -s "$_g_p" ] || return 1
    [ -e "$_g_t" ] || return 1
    [ "$(grep -c '<isOpen>' "$_g_p" 2>/dev/null)" = "1" ] || return 1
    grep -q '<isOpen>false</isOpen>' "$_g_p" 2>/dev/null || return 1
    grep -q '<filter-conf>' "$_g_p" 2>/dev/null || return 1
    grep -q '</filter-conf>' "$_g_p" 2>/dev/null || return 1
    _g_n=$((_g_n + 1))
  done < "$MAN"
  [ "$_g_n" -gt 0 ]
}

_is_bound() {
  # A bind-mounted file appears as its own mountpoint; the stock file on the partition
  # does not. This is what "we own a bind here" means. The mounts table is injectable
  # for host fixtures, the same portability pattern as the Wi-Fi fallback's PROC_ROOT.
  grep -q " $1 " "${ASB_MMFEED_PROC_MOUNTS:-/proc/mounts}" 2>/dev/null
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

_mmfeed_bind_all() {
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

_mmfeed_unbind_all() {
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
    if [ "$(_cfg mmfeed_off)" = "1" ] && [ ! -f "$BLOCK" ] && _mmfeed_guard; then
      if _mmfeed_bind_all; then
        _log 'action=mmfeed_bind result=applied'
      fi
    else
      # Toggle off (or fuse set): a bind of ours must not survive the choice that
      # removed it. Stock content is what the file shows again from this umount on.
      if [ -f "$ACTIVE" ]; then
        _mmfeed_unbind_all && _log 'action=mmfeed_bind result=removed'
      fi
    fi
    ;;
  remove)
    # Uninstall path: drop whatever we own regardless of the toggle state.
    _mmfeed_unbind_all && _log 'action=mmfeed_bind result=removed reason=uninstall'
    ;;
  status)
    if [ ! -f "$MAN" ]; then
      echo 'mmfeed_patch_absent'
    elif [ "$(_cfg mmfeed_off)" != "1" ]; then
      echo 'mmfeed_off'
    elif [ -f "$ACTIVE" ]; then
      echo 'mmfeed_active'
    else
      echo 'mmfeed_pending_boot'
    fi
    ;;
esac
exit 0
