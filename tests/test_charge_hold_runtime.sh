#!/bin/sh
# Runtime (fix148): a charger online at "Not charging" is the charger, not the battery.
#
# CPH2769 capture 13290: OnePlus battery protection parked the level at 80% with the cable
# in for 161 + 48 minutes. The battery status read "Not charging", so the recorder filed both
# stretches as "sleep" - 99% awake, 0 %/h - the kernel's "wired wakelock" held throughout,
# and the report printed "night verdict: valid (226 min)" with no night row to back it. The
# governor read the same status as "on battery". The REAL functions run here on a fake
# power_supply tree, a fake ledger and fake holder blocks.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL charge hold: $*" >&2; fail=1; }

# --- 1. power state -----------------------------------------------------------------------
P="$T/psy"; mkdir -p "$P/battery" "$P/usb" "$P/wireless"
st() {   # status usb wireless
  printf '%s\n' "$1" > "$P/battery/status"; echo "$2" > "$P/usb/online"; echo "$3" > "$P/wireless/online"
  ASB_LK_PSY="$P" sh -c '. "$0" >/dev/null 2>&1; lk_power_state' "$C"
}
[ "$(st Charging 1 0)" = charging ] || f "Charging"
[ "$(st Full 1 0)" = full ] || f "Full"
[ "$(st Discharging 1 0)" = battery ] || f "Discharging wins over an online flag"
[ "$(st 'Not charging' 1 0)" = held ] || f "Not charging with the cable in: '$(st 'Not charging' 1 0)' (want held)"
[ "$(st 'Not charging' 0 1)" = held ] || f "Not charging on a wireless pad"
[ "$(st 'Not charging' 0 0)" = battery ] || f "Not charging with no supply online"
[ "$(st Unknown 1 0)" = charging ] || f "Unknown status with a supply online (OxygenOS 16)"
[ "$(st Unknown 0 0)" = battery ] || f "Unknown status, nothing online"
[ "$(ASB_LK_PSY="$P" sh -c '. "$0" >/dev/null 2>&1; lk_power_state Charging' "$C")" = charging ] || f "status passed in"

# --- 2. the recorder files it as a charging phase, the battery trace as charging -----------
grep -q 'case "$(lk_power_state "$_cs")" in' "$F" && grep -q '    charging|full|held)' "$F" || f "phase classifier ignores the hold"
sed -n '/^lk_capture_battery_trace_row\|^lk_battery_trace_row/,/^}/p' "$C" | grep -q 'case "$(lk_power_state)" in' \
  || grep -q '  case "$(lk_power_state)" in' "$C" || f "battery trace reads the hold as discharging"

# --- 3. night verdict from the battery phases -----------------------------------------------
awk '/^lk_emit_capture_validity\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$F" > "$T/v.sh"
[ -s "$T/v.sh" ] || f "lk_emit_capture_validity not found"
mkdir -p "$T/o"
printf 'charging_idle\t1000\t13000\t28\t80\nsleep\t13000\t22660\t80\t80\nidle\t22660\t23800\t80\t79\n' > "$T/o/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/o" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=13560 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: unavailable on battery (screen off up to 226 min, but the longest stretch off the charger was 161 min; need >=180 min).$' \
  || f "night on the charger read as valid: $out"
printf 'sleep\t1000\t13000\t90\t86\n' >> "$T/o/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/o" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=13560 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: valid (longest screen-off stretch on battery 200 min >=180 min).$' || f "a real night not valid: $out"

# --- 4. charging-idle verdict names the kernel holder ---------------------------------------
awk '/^lk_emit_charging_idle_anomaly\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$F" > "$T/a.sh"
mkdir -p "$T/q"
printf 'charging_idle\t1000\t13000\t28\t80\t33\t31\t418\t0\t0\t0\t100\t0\t0\t0\t0\n' > "$T/q/phase_ledger.tsv"
cat > "$T/q/phase_wakeholders.txt" <<'X'
phase=idle awake=60% dur=900s  (time gained inside this phase)
  kernel: +5m 00s  hal_bluetooth_lock
phase=charging_idle awake=100% dur=9000s  (time gained inside this phase; kernel only - batterystats counts no app wakelock on the charger)
  kernel: +149m 30s  wired wakelock
  kernel: +12m 05s  rmnet_ipa%d
phase=charging_idle awake=100% dur=3000s  (time gained inside this phase; kernel only - batterystats counts no app wakelock on the charger)
  kernel: +50m 00s  wired wakelock
X
out="$(LK_OUT_DIR="$T/q" LK_CHG_IDLE_SAMPLES=10 LK_CHG_IDLE_AUDIO_SAMPLES=0 LK_CHG_IDLE_COALESCED=0 sh -c '. "$1"; lk_emit_charging_idle_anomaly' x "$T/a.sh")"
printf '%s\n' "$out" | grep -q '^  kernel holder on the charger: wired wakelock 199 min$' || f "charger wakelock not summed over the charging phases: $out"
printf '%s\n' "$out" | grep -q 'hal_bluetooth_lock' && f "an idle-phase holder counted as a charging one: $out"
printf '%s\n' "$out" | grep -q 'the phone.s own design, nothing an app or ASB holds' || f "charger wakelock not explained: $out"
grep -q 'gap|idle|sleep|charging_idle) lk_wh_kernel_snap' "$F" || f "no kernel snapshot at a charging-idle phase open"

# --- 5. report line, governor, action screen -------------------------------------------------
grep -q 'held, not charging       : %d samples at %s%%' "$F" || f "charging block does not count the hold"
grep -q "else if (st\[0\] == 'D')                 b->charging = 0;" "$ROOT/src/asb_metrics.h" || f "governor still reads Not charging as on battery"
grep -q 'Held)     _bst_l="  ·  $T_HELD" ;;' "$ROOT/action.sh" || f "action screen does not say the charge is paused"
for l in "$ROOT"/runtime/i18n/action_*.sh; do grep -q '^T_HELD=' "$l" || f "T_HELD missing in ${l##*/}"; done

[ "$fail" = 0 ] && echo "PASS charge hold: a paused charge is the charger in the recorder, the night verdict, the governor and the action screen"
exit "$fail"
