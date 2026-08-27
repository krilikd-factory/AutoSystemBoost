#!/bin/sh
# Contract: user-visible framework settings written by ASB must retain their original namespace/value.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE="$ROOT/runtime/asb_baseline.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
BLUR="$ROOT/runtime/asb_blur_apply.sh"
HAPTICS="$ROOT/runtime/asb_haptics_apply.sh"
NET="$ROOT/runtime/asb_net_apply.sh"
INSTALL="$ROOT/common/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL reversible settings: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/settings" <<'EOF_SETTINGS'
#!/bin/sh
DB="${ASB_FAKE_SETTINGS_DB:?}"
case "${1:-}" in
  get)
    awk -F'|' -v ns="$2" -v key="$3" '$1==ns && $2==key {print $3; found=1; exit} END{if(!found) print "null"}' "$DB"
    ;;
  put)
    tmp="$DB.tmp.$$"
    awk -F'|' -v ns="$2" -v key="$3" '!($1==ns && $2==key)' "$DB" > "$tmp"
    printf '%s|%s|%s\n' "$2" "$3" "$4" >> "$tmp"
    mv -f "$tmp" "$DB"
    ;;
  delete)
    tmp="$DB.tmp.$$"
    awk -F'|' -v ns="$2" -v key="$3" '!($1==ns && $2==key)' "$DB" > "$tmp"
    mv -f "$tmp" "$DB"
    ;;
  *) exit 2 ;;
esac
EOF_SETTINGS
chmod 0755 "$TMP/bin/settings"
cat > "$TMP/settings.db" <<'EOF_DB'
global|bluetooth_a2dp_offload_enabled|before-offload
global|bluetooth_disable_absolute_volume|before-absvol-global
secure|bluetooth_disable_absolute_volume|before-absvol-secure
global|disable_window_blurs|before-blur
system|haptic_feedback_enabled|before-haptic-enabled
system|haptic_feedback_intensity|before-haptic-intensity
global|wifi_scan_throttle_enabled|before-scan
EOF_DB
cp "$TMP/settings.db" "$TMP/original-settings.db"

PATH="$TMP/bin:$PATH"
export PATH ASB_FAKE_SETTINGS_DB="$TMP/settings.db" ASB_BASELINE="$TMP/baseline.txt" MODDIR="$ROOT"
. "$BASE"

# These are the seven audit keys and namespaces. A later ASB write must not replace the first
# captured original, then targeted and complete restore must replay that original exactly.
while IFS='|' read -r ns key before; do
  asb_settings_put "$ns" "$key" "asb-${key}"
  grep -Fqx "settings|$ns|$key|$before" "$ASB_BASELINE" || fail "baseline did not capture $ns/$key"
  asb_settings_put "$ns" "$key" "asb-second-${key}"
  [ "$(grep -Fxc "settings|$ns|$key|$before" "$ASB_BASELINE")" = 1 ] || fail "baseline duplicated $ns/$key"
done < "$TMP/original-settings.db"

asb_baseline_restore_setting global disable_window_blurs || fail 'targeted blur baseline restore failed'
[ "$(settings get global disable_window_blurs)" = before-blur ] || fail 'targeted blur baseline restored wrong value'
asb_baseline_replay
while IFS='|' read -r ns key before; do
  [ "$(settings get "$ns" "$key")" = "$before" ] || fail "full baseline replay restored wrong $ns/$key"
done <<'EOF_EXPECTED'
global|bluetooth_a2dp_offload_enabled|before-offload
global|bluetooth_disable_absolute_volume|before-absvol-global
secure|bluetooth_disable_absolute_volume|before-absvol-secure
global|disable_window_blurs|before-blur
system|haptic_feedback_enabled|before-haptic-enabled
system|haptic_feedback_intensity|before-haptic-intensity
global|wifi_scan_throttle_enabled|before-scan
EOF_EXPECTED

need "$AUDIO" 'runtime/asb_baseline.sh'
need "$AUDIO" '_asb_setting_put global bluetooth_a2dp_offload_enabled'
need "$AUDIO" '_asb_setting_put global bluetooth_disable_absolute_volume'
need "$AUDIO" '_asb_setting_put secure bluetooth_disable_absolute_volume'
need "$BLUR" 'runtime/asb_baseline.sh'
need "$BLUR" 'asb_baseline_restore_setting global disable_window_blurs'
need "$NET" 'runtime/asb_baseline.sh'
need "$NET" '_asb_setting_put global wifi_scan_throttle_enabled "$_wt"'
need "$HAPTICS" 'runtime/asb_baseline.sh'
need "$HAPTICS" '_asb_setting_put system haptic_feedback_enabled 1'
need "$HAPTICS" '_asb_setting_put system haptic_feedback_intensity'
need "$INSTALL" '_asb_install_setting_put global disable_window_blurs 1'
! grep -Fq 'settings put global disable_window_blurs' "$INSTALL" || fail 'installer still writes blur stock without baseline-aware helper'
need "$UNINSTALL" '*/haptics_baseline.conf) _restore_ns=system'

echo 'PASS reversible settings baseline contract (7 audited keys and haptics namespace)'
