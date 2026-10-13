#!/bin/sh
# Runtime (fix140): a capture says so when batterystats did not update, instead of "no app
# held a partial wakelock".
#
# Capture 2830 (OP15, 9.5 h): "TOP APPS BY HELD WAKELOCK TIME ... (no app held a partial
# wakelock for 5 s or more in this window)" while the live power-manager samples saw
# YouTube's AudioMix held for 20 minutes at a stretch. Every uid's batterystats total was the
# one recorded at the start (AudioMix 1m 52s at 22:45 and at 08:03), the kernel wakelock
# totals too: Android's accounting did not move. The REAL report functions run on fixtures
# with a fake dumpsys.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
fail() { echo "FAIL logkit batterystats stall: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
O="$T/out"; B="$T/bin"; mkdir -p "$O" "$B"
cat > "$B/dumpsys" <<'S'
#!/bin/sh
[ "$1" = batterystats ] || exit 0
cat "$BS_FILE"
S
chmod +x "$B/dumpsys"
cat > "$T/bs_frozen.txt" <<'X'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 24s 17ms (4 times) max=79609 actual=339376 realtime
  Wake lock u0a658 AudioMix: 1m 52s 686ms (0 times) max=139335 actual=148655 realtime

X
printf '10493 264 PedometerLib:tag\n10658 112 AudioMix\n' > "$O/.wl_uid_base"
echo $(( $(date +%s) - 3 * 3600 - 60 )) > "$O/.bstats_base_epoch"
echo "epoch|datetime|status" > "$O/charge_trace.txt"
printf '10658|com.google.android.youtube\n10493|com.sec.android.app.shealth\n' > "$O/.uid_package_map.tsv"
# On battery: 52 % -> 35 % over the night (the OP15's status node reads "Unknown" throughout).
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|52|1124\n2|d|DEEP_IDLE|smart|0|35|83\n' > "$O/battery_trace.txt"

run_dump() {
  BS_FILE="$1" PATH="$B:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_wakelock_batterystats_dump' "$C" "$O" >/dev/null 2>&1
}

# The screen was off for most of it (fix142: batterystats charges partial wakelocks only with
# the screen off, so the stall claim needs real screen-off time). Rows 30 min apart at night.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|sleep|0|0|4094|0||-60||" >> "$O/display_trace.txt"; done
cp "$O/display_trace.txt" "$T/dt.night"

# 0. Screen on the whole time and nothing moved: batterystats had nothing to charge - no claim.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed for a capture with the screen on throughout"
cp "$T/dt.night" "$O/display_trace.txt"

# 1. Nothing moved in 3 h, no charging: the stall is named, "no app" is not printed.
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved in 3 h of capture" "$O/_wakelock_report.txt" || fail "stall not named: $(sed -n '/TOP APPS/,/^$/p' "$O/_wakelock_report.txt")"
grep -q 'no app held a partial wakelock' "$O/_wakelock_report.txt" && fail "still says no app held one"
grep -qx '10658 0' "$O/.wl_uid_delta" || fail "per-uid deltas not kept for the report"

# 2. The live samples saw AudioMix (YouTube's worksource) held 20 min at a stretch.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
# Screen off since 800: the 20-minute hold sampled at 2020 lies entirely in the dark.
for e in 800 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
cat > "$O/wake_live.txt" <<'X'
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-5m1s2ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-20m3s9ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2040|kactive=0|ktop=|plocks=
X
printf '10658 com.google.android.youtube\n' > "$O/uid_map.txt"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q '^batterystats disagrees with these samples:$' || fail "no disagreement line: $live"
printf '%s\n' "$live" | grep -q 'com.google.android.youtube (AudioMix): held 20 min at a stretch with the screen off here, batterystats added 0 s' \
  || fail "holder not compared: $live"

# 2b. fix142: the same 20-minute hold, but the screen went off 20 s before the sample - the
# hold ran with the screen on, which batterystats does not charge. No disagreement.
cp "$O/display_trace.txt" "$T/dt.keep"
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 1950; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
for e in 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "a hold that ran with the screen on compared against batterystats: $live"
cp "$T/dt.keep" "$O/display_trace.txt"

# 3. On the charger batterystats counts nothing by design: no stall claim, no disagreement.
echo "1|d|Charging" >> "$O/charge_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed during a charging capture"
grep -q 'no app held a partial wakelock for 5 s' "$O/_wakelock_report.txt" || fail "charging capture lost the plain line"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement printed while charging: $live"
echo "epoch|datetime|status" > "$O/charge_trace.txt"

# 3b. No charge row but the level held (a phone kept at a charge limit): no claim either.
cp "$O/battery_trace.txt" "$T/bt.keep"
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|80|-5\n2|d|DEEP_IDLE|smart|0|80|3\n' > "$O/battery_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with the level held"
cp "$T/bt.keep" "$O/battery_trace.txt"

# 4. Accounting that moves: the ranking as before, and no disagreement once it covers the hold.
sed 's/AudioMix: 1m 52s 686ms/AudioMix: 26m 2s 1ms/' "$T/bs_frozen.txt" > "$T/bs_live.txt"
run_dump "$T/bs_live.txt"
grep -q 'com.google.android.youtube' "$O/_wakelock_report.txt" || fail "moving totals not ranked"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with moving totals"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement with totals that cover the hold: $live"

# 5. A short capture with nothing moved is just a quiet window.
echo $(( $(date +%s) - 1800 )) > "$O/.bstats_base_epoch"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed after 30 minutes"
echo "PASS logkit batterystats stall: a stalled batterystats is named and checked against the live samples"
