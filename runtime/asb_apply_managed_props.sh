#!/system/bin/sh
# Apply ASB property policy only after feature and device-pack validation.
#
# `system.prop` is intentionally not used for optional vendor properties: Magisk
# loads it before service.sh can evaluate feature toggles. The payload lives in
# runtime/asb_managed.props and is applied here only when the exact build
# fingerprint has an explicit `domain=properties` validation record.
MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done
PROPS="$MODDIR/runtime/asb_managed.props"
STATE_DIR="${ASB_CONFIG_STATE:-/data/adb/asb}"
STATE="$STATE_DIR/managed_props.state"

_feature_enabled() {
  _f="$1"
  _line="$(grep -E "^[[:space:]]*${_f}=" "$MODDIR/features.conf" 2>/dev/null | tail -1)"
  [ -n "$_line" ] || return 1
  _v="${_line#*=}"
  _v="${_v%%#*}"
  _v="$(printf '%s' "$_v" | tr -d '[:space:]\r')"
  [ "$_v" = "1" ]
}
_write_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  _tmp="$STATE.tmp.$$"
  {
    printf 'status=%s\n' "$1"
    printf 'reason=%s\n' "$2"
    printf 'applied=%s\n' "${3:-0}"
    printf 'skipped=%s\n' "${4:-0}"
    printf 'timestamp=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATE" 2>/dev/null
}

[ -r "$PROPS" ] || { _write_state missing "managed_payload_unavailable"; exit 0; }
command -v resetprop >/dev/null 2>&1 || { _write_state blocked "resetprop_unavailable"; exit 0; }
[ -r "$MODDIR/runtime/asb_device_tier.sh" ] && . "$MODDIR/runtime/asb_device_tier.sh"
command -v asb_device_pack_allows >/dev/null 2>&1 || {
  _write_state blocked "device_tier_helper_unavailable"; exit 0;
}
asb_device_pack_allows properties || {
  _write_state blocked "unvalidated_fingerprint_or_properties_domain"; exit 0;
}

_block=""
_apply=0
_applied=0
_skipped=0
_bt_policy_state="disabled_default"
_BT_OPTIN="$STATE_DIR/enable_bt_policy"

# Bluetooth is intentionally opt-in.  BT=1 means the device pack supports the domain; it must
# not mean that ASB silently overrides OxygenOS codec/offload/sniff policy on every boot.  Create
# /data/adb/asb/enable_bt_policy only for an explicit experiment and remove it to return to stock.
[ -f "$_BT_OPTIN" ] && _bt_policy_state="enabled_optin"
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in
    '# ASB:'*:BEGIN)
      _block="${_line#\# ASB:}"
      _block="${_block%:BEGIN}"
      # UI blur and effects are dynamic DISPLAY properties written by the WebUI.
      case "$_block" in
        BLUR|UIFX) _feature="DISPLAY" ;;
        BT)
          _feature="BT"
          if [ "$_bt_policy_state" != "enabled_optin" ]; then
            _apply=0
            _skipped=$((_skipped + 1))
            continue
          fi
          ;;
        *) _feature="$_block" ;;
      esac
      if _feature_enabled "$_feature"; then _apply=1; else _apply=0; fi
      continue
      ;;
    '# ASB:'*:END)
      _block=""
      _apply=0
      continue
      ;;
    ''|'#'*) continue ;;
  esac
  _key="${_line%%=*}"
  _val="${_line#*=}"
  [ "$_key" != "$_line" ] || continue
  case "$_key" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
  if [ "$_block" = "BT" ] && [ "$_bt_policy_state" = "disabled_default" ]; then
    # Remove only persistent properties previously written by ASB's BT block.  This makes the
    # test an actual stock A/B experiment after upgrading from an older build; non-persistent
    # ro/vendor defaults and unrelated Android settings are never touched here.
    case "$_key" in
      persist.*) resetprop --delete "$_key" >/dev/null 2>&1 || true ;;
    esac
    _skipped=$((_skipped + 1))
    continue
  fi
  if [ "$_apply" = "1" ]; then
    if resetprop -n "$_key" "$_val" >/dev/null 2>&1; then
      _applied=$((_applied + 1))
    else
      _skipped=$((_skipped + 1))
    fi
  else
    _skipped=$((_skipped + 1))
  fi
done < "$PROPS"
_write_state applied "validated_properties_domain;bt_policy=$_bt_policy_state" "$_applied" "$_skipped"
exit 0
