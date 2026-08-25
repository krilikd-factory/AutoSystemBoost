#!/bin/sh
# Contract for the explicit Wi-Fi -> mobile handover opt-in.
# This does not emulate Android ConnectivityService; it locks the safety boundary that ASB
# owns: LPM is the only writer of mobile_data_always_on, and save/night always win.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

for f in "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped"; do
  need "$f" 'net_handover_fast=0'
done

LPM="$ROOT/runtime/asb_lpm.sh"
need "$LPM" 'if [ "$MODE" = "refresh" ]; then'
need "$LPM" 'case "$_saved_mode" in fast|normal|save|night)'
need "$LPM" 'case "$(_cfg net_handover_fast)" in'
need "$LPM" 'STATE_TAG="${MODE}|handover=${HANDOVER_FAST}"'
need "$LPM" 'echo "${MODE}|handover=${HANDOVER_FAST}" > "$STATE"'
need "$LPM" '_sset mobile_data_always_on 0'
need "$LPM" 'if [ "$HANDOVER_FAST" = "1" ]; then'
need "$LPM" '_sset mobile_data_always_on 1'

# No second helper may write the handover setting directly. The only intended mobile_data
# owner is LPM; its normal/fast/save/night policy already captures/restores a single baseline.
writers="$(grep -RIl 'mobile_data_always_on' "$ROOT/runtime" --include='*.sh' | sort)"
printf '%s\n' "$writers" | grep -qx "$LPM" || fail 'mobile_data_always_on has a writer outside asb_lpm.sh'

WEB="$ROOT/webroot/index.html"
need "$WEB" "key:'net_handover_fast'"
need "$WEB" "'net_handover_fast',"
need "$WEB" 'net_handover_fast:APPLY_LIVE'
need "$WEB" "key === 'net_handover_fast'"
need "$WEB" '/runtime/asb_lpm.sh refresh'
need "$WEB" "raw.split('|')[0]"
need "$WEB" 'Vendor caps · 1h / total'
need "$WEB" 'protective bias · vendor cap pressure'

need "$ROOT/common/install.sh" 'wifi_scan_throttle net_handover_fast haptic_touch_strength'
need "$ROOT/action.sh" 'Wi-Fi → mobile handover: fast'
need "$ROOT/tools/asb_diag.sh" 'Wi-Fi → mobile handover: fast requested'

# This is a user-facing card, so every shipped language must carry a full native card,
# both stored-value labels and the battery-cost warning. English fallback is not enough.
_locale_n=0
for _locale in "$ROOT"/webroot/i18n/*.json; do
  _locale_n=$((_locale_n + 1))
  need "$_locale" '"wb_handover"'
  _handover_n="$(grep -c '"net_handover_fast"' "$_locale" || true)"
  [ "$_handover_n" -ge 2 ] || fail "incomplete handover card/options in ${_locale#$ROOT/}"
  need "$_locale" '"name"'
  need "$_locale" '"desc"'
done
[ "$_locale_n" -eq 13 ] || fail "expected 13 locale files, got $_locale_n"

# Run the helper against a small private module tree. Replace its fixed Android state root so
# the fixture proves settings ownership and state transitions without touching host /data/adb.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/mod/profiles" "$TMP/bin" "$TMP/state"
sed -e "s#/data/adb/asb#$TMP/state#g" -e "s#/dev/.asb#$TMP/state#g" \
  "$LPM" > "$TMP/mod/runtime/asb_lpm.sh"
cat > "$TMP/mod/features.conf" <<'EOF'
LPM=1
EOF
cat > "$TMP/mod/config/governor.conf" <<'EOF'
net_handover_fast=0
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
# Stock baseline is 0, so normal/stock preserves it.
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'normal stock mode did not restore baseline'
printf 'net_handover_fast=1\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" refresh
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 1' || fail 'fast handover did not warm mobile context in normal mode'
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" save
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'save mode did not override fast handover'
printf 'net_handover_fast=0\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" refresh
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'refresh woke modem during save mode'
grep -qx 'save|handover=0' "$TMP/state/lpm_mode" || fail 'refresh did not preserve save state tag'

echo 'PASS: network handover contract'
