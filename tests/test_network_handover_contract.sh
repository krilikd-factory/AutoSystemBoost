#!/usr/bin/env bash
# Contract for explicit Wi-Fi -> mobile handover and the independent cellular/radio master.
# It locks the safety boundary ASB owns: profiles never imply a modem policy, LPM is the sole
# mobile_data_always_on writer, and save/night always outrank fast handover.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

for f in "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped"; do
  need "$f" 'radio_policy_enable=0'
  need "$f" 'net_handover_fast=0'
  need "$f" 'net_handover_active=0'
done

LPM="$ROOT/runtime/asb_lpm.sh"
FALLBACK="$ROOT/runtime/asb_wifi_fallback.sh"
GOV="$ROOT/src/asb_governor.c"
need "$LPM" '_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = "1" ]; }'
need "$LPM" 'if ! _feat_on LPM || ! _radio_policy_enabled; then'
need "$LPM" 'if [ "$MODE" = "refresh" ]; then'
need "$LPM" 'case "$_saved_mode" in fast|normal|save|night)'
need "$LPM" 'case "$(_cfg net_handover_fast)" in'
need "$LPM" 'case "$(_cfg net_handover_active)" in'
need "$LPM" 'HANDOVER_ACTIVE=1; HANDOVER_FAST=1'
need "$LPM" 'STATE_TAG="${MODE}|handover=${HANDOVER_FAST}|active=${HANDOVER_ACTIVE}"'
need "$LPM" '_sset mobile_data_always_on 0'
need "$LPM" '_sset mobile_data_always_on 1'
need "$FALLBACK" '_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = 1 ]; }'
need "$FALLBACK" '_enabled() { _radio_policy_enabled && [ "$(_cfg net_handover_active)" = 1 ]; }'
need "$FALLBACK" '_screen_on || return 0'
need "$FALLBACK" '_mobile_allowed || return 0'
need "$FALLBACK" '_wifi_default || return 0'
need "$FALLBACK" '_wifi_unvalidated || return 0'
need "$FALLBACK" 'RELEASE_S=28'
need "$FALLBACK" 'COOLDOWN_S=150'
need "$FALLBACK" '_valid_seconds "$_raw_interval" 1 120'
need "$FALLBACK" '_valid_seconds "$_raw_release" 1 120'
need "$FALLBACK" '_valid_seconds "$_raw_cooldown" 1 3600'

# Smart's economy bias must not re-enable a radio policy by itself. Confirmed games/camera can
# request fast only after the explicit master authorises LPM.
need "$GOV" 'int smart_battery_lean ='
need "$GOV" 'g_asb_cfg.smart_battery_bias >= 400'
need "$GOV" '!metrics.misc.camera_active && !metrics.bat.charging'
need "$GOV" 'g_smart_rt.app_hint < ASB_APP_GAMING'
need "$GOV" 'fsm.state == ASB_STATE_GAMING ||'
need "$GOV" '(fsm.state == ASB_STATE_HEAVY && !smart_battery_lean)'
need "$GOV" 'honours net_handover_fast inside asb_lpm.sh'

# No second helper may write mobile_data_always_on. The only intended owner is LPM; normal/fast/
# save/night capture and restore a single Android baseline.
writers="$(grep -RIl 'mobile_data_always_on' "$ROOT/runtime" --include='*.sh' | sort)"
printf '%s\n' "$writers" | grep -qx "$LPM" || fail 'mobile_data_always_on has a writer outside asb_lpm.sh'

WEB="$ROOT/webroot/index.html"
need "$WEB" "key:'radio_policy_enable'"
need "$WEB" "key:'net_handover_fast'"
need "$WEB" "key:'net_handover_active'"
need "$WEB" "radio_policy_enable:'cellular_controls'"
need "$WEB" "net_handover_active:'wifi_escape'"
need "$WEB" "key === 'radio_policy_enable' || key === 'net_handover_fast' || key === 'net_handover_active'"
need "$WEB" "'radio_policy_enable',"
need "$WEB" 'radio_policy_enable:APPLY_LIVE'
need "$WEB" '/runtime/asb_lpm.sh refresh'
need "$WEB" "raw.split('|')[0]"
need "$ROOT/common/install.sh" 'wifi_scan_throttle radio_policy_enable net_handover_fast net_handover_active haptic_touch_strength'
need "$ROOT/runtime/asb_net_apply.sh" 'wifi_fallback=master_off'
need "$ROOT/action.sh" 'cellular/radio controls: off · profiles leave Android radio policy untouched'
need "$ROOT/tools/asb_diag.sh" 'profiles leave Android mobile-data context and TCP keepalives untouched'

# Every user-facing card/warning must be present in all 13 shipped languages; English fallback is
# not an acceptable substitute for a radio policy that may cost mobile data or battery.
_locale_n=0
for _locale in "$ROOT"/webroot/i18n/*.json; do
  _locale_n=$((_locale_n + 1))
  need "$_locale" '"radio_policy_enable"'
  need "$_locale" '"wb_radio_policy"'
  need "$_locale" '"net_handover_active"'
  need "$_locale" '"theme_dark"'
  need "$_locale" '"theme_light"'
  need "$_locale" '"name"'
  need "$_locale" '"desc"'
done
[ "$_locale_n" -eq 13 ] || fail "expected 13 locale files, got $_locale_n"

# Run LPM in a private module/state tree. The no-SIM/master-off case must not even establish a
# baseline or write a radio/global TCP setting when a profile changes.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/mod/profiles" "$TMP/bin" "$TMP/state"
sed -e "s#/data/adb/asb#$TMP/state#g" -e "s#/dev/.asb#$TMP/state#g" \
  "$LPM" > "$TMP/mod/runtime/asb_lpm.sh"
cat > "$TMP/mod/features.conf" <<'EOF'
LPM=1
EOF
cat > "$TMP/mod/config/governor.conf" <<'EOF'
radio_policy_enable=0
net_handover_fast=0
net_handover_active=0
EOF
cat > "$TMP/mod/profiles/balanced.sh" <<'EOF'
NET_TCP_KEEPIDLE=300
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1" in
  get) echo 0 ;;
  put) printf '%s %s %s\n' "$1" "$3" "$4" >> "$ASB_HANDOVER_LOG" ;;
esac
EOF
chmod 0755 "$TMP/bin/settings"
export PATH="$TMP/bin:$PATH" ASB_HANDOVER_LOG="$TMP/settings.log"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
[ ! -e "$TMP/settings.log" ] || fail 'radio master OFF wrote mobile_data_always_on after profile transition'
[ ! -e "$TMP/state/lpm_base" ] || fail 'radio master OFF captured a modem baseline'

# Explicit master ON permits current LPM policy. Fast may warm context while awake; save wins.
printf 'radio_policy_enable=1\nnet_handover_fast=1\nnet_handover_active=0\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 1' || fail 'explicit radio master + fast handover did not warm mobile context'
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" save
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'save mode did not override fast handover'

# Turning the independent master OFF restores original Android baseline (mocked 0), removes LPM
# state and makes a later profile transition a no-op rather than a new implicit radio write.
printf 'radio_policy_enable=0\nnet_handover_fast=1\nnet_handover_active=1\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" refresh
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'radio master OFF did not restore captured Android baseline'
[ ! -e "$TMP/state/lpm_base" ] || fail 'radio master OFF retained LPM baseline state'
[ ! -e "$TMP/state/lpm_mode" ] || fail 'radio master OFF retained LPM mode state'
lines_before="$(wc -l < "$TMP/settings.log")"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
[ "$(wc -l < "$TMP/settings.log")" -eq "$lines_before" ] || fail 'profile transition wrote radio setting with master OFF'

echo 'PASS: network handover and independent radio policy contract'
