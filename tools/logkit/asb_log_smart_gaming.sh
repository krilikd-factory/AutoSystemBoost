#!/system/bin/sh
#
# ASB V47 Smart Mode — GAMING SESSION capture
#
# Usage (SAFE — survives Termux closure / screen lock during gaming):
#   su
#   export MODDIR=/data/adb/modules/AutoSystemBoost
#   nohup sh $MODDIR/tools/logkit/asb_log_smart_gaming.sh [MINUTES] >/data/local/tmp/smart_game.out 2>&1 &
#   # Then open the game; can close Termux freely
#   # to stop early:  killall asb_log_smart_gaming.sh
#
# Default: 90 minutes. Typical long COD-Mobile / Genshin session.
# What it captures:
#   - Smart Mode runtime state every 15s (fine resolution for thermal events)
#   - Thermal veto firing rate (should rise during prolonged heat)
#   - alpha_battery trajectory (should NOT increase during gaming if app_hint=gaming)
#   - CPU temp curve, vendor clamps, FSM state transitions
#   - Compare avg CPU temp by alpha range to verify cooler-than-balanced claim
#
# How to run:
#   1. Run the nohup command above BEFORE opening the game
#   2. Then open COD-Mobile (or your game) and play
#   3. Don't worry about Termux being closed — capture is detached
#   4. After session, retrieve logs from /data/local/tmp/asb_log_smart_gaming_*/

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

# Auto-detach via setsid so capture survives terminal closure
if [ -t 0 ]; then
  if command -v setsid >/dev/null 2>&1; then
    if [ -z "${ASB_LOGKIT_DETACHED:-}" ]; then
      export ASB_LOGKIT_DETACHED=1
      echo "[autodetach] Re-launching detached so capture survives Termux closure"
      exec setsid sh "$0" "$@" </dev/null
    fi
  fi
fi

LK_SCENARIO="smart_gaming"
LK_OUT_DIR="${TMPDIR:-/data/local/tmp}/asb_log_${LK_SCENARIO}_$$"
LK_POLL_S=15
LK_SNAPSHOT_S=600
LK_MINUTES="${1:-90}"
LK_MAX_SEC=$(( LK_MINUTES * 60 ))

LK_WAKELOCK_NAME="asb_logkit_$$"
LK_HAVE_WAKELOCK=0
if [ -w /sys/power/wake_lock ]; then
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null && LK_HAVE_WAKELOCK=1
fi

trap 'lk_finalize_smart_gaming; exit 0' INT TERM HUP EXIT

lk_finalize_smart_gaming() {
  if [ "$LK_HAVE_WAKELOCK" = "1" ]; then
    echo "$LK_WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null
  fi
  lk_capture_smart_sessions_window
  lk_snapshot_smart_store "after"
  lk_emit_smart_summary
  lk_emit_gaming_thermal_correlation
  lk_finalize
}

lk_emit_gaming_thermal_correlation() {
  _trace="$LK_OUT_DIR/smart_trace.tsv"
  _out="$LK_OUT_DIR/_thermal_correlation.txt"
  [ -r "$_trace" ] || return 0
  {
    echo "===== Gaming thermal correlation ====="
    echo ""
    echo "── Peak CPU temp during capture ──"
    awk 'NR>1 && $14 != "-" { v=$14+0; if (v>m) m=v } END { print "  max CPU = " m "°C" }' "$_trace"
    echo ""
    echo "── Ticks above 70°C ──"
    awk 'NR>1 && $14 != "-" { n++; if ($14+0 >= 70) hot++ }
         END { if (n>0) printf "  %d/%d ticks (%.1f%%)\n", hot+0, n, (hot+0)*100.0/n }' "$_trace"
    echo ""
    echo "── Ticks above 80°C ──"
    awk 'NR>1 && $14 != "-" { n++; if ($14+0 >= 80) hot++ }
         END { if (n>0) printf "  %d/%d ticks (%.1f%%)\n", hot+0, n, (hot+0)*100.0/n }' "$_trace"
    echo ""
    echo "── Thermal veto correlation with alpha ──"
    echo "  If Smart works, when CPU≥65°C → thermal_veto=1 → alpha forced ≥700"
    awk 'NR>1 && $14 != "-" && $8 != "-" && $11 != "-" {
      t=$14+0; a=$8+0; v=$11+0
      if (t >= 65) {
        n++
        if (v == 1) veto++
        if (a >= 700) high_alpha++
      }
    } END {
      if (n>0) {
        printf "  ticks at CPU≥65: %d\n", n
        printf "    of those, thermal_veto fired: %d (%.1f%%)\n", veto+0, (veto+0)*100.0/n
        printf "    of those, alpha forced ≥700: %d (%.1f%%)\n", high_alpha+0, (high_alpha+0)*100.0/n
      } else {
        print "  (no ticks ≥65°C in capture — Smart Mode wasnt thermally stressed)"
      }
    }' "$_trace"
    echo ""
    echo "── Alpha trend over capture (every 60s sample) ──"
    awk 'NR>1 && $8 != "-" {
      n++; if (n%4==1) printf "  %s  alpha=%s  cpu=%s°C  veto=%s  app=%s  state=%s\n", $2, $8, $14, $11, $12, $19
    }' "$_trace" | head -40
  } > "$_out"
  cat "$_out"
}

lk_init
lk_check_smart_mode_active || exit 1
lk_smart_trace_header
lk_snapshot_smart_store "before"

echo "[$(date '+%H:%M:%S')] Smart Mode GAMING capture running for up to ${LK_MINUTES}m."
echo "                     Start the game NOW. Press Ctrl-C to stop early."
echo "                     Poll: ${LK_POLL_S}s (high resolution for thermal events)."

_last_snapshot=$(date +%s)
_last_state=""
_state_transitions=0
_max_cpu=0

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  {
    lk_status_watch_header
    lk_status_json
  } >> "$LK_OUT_DIR/status_watch.txt"
  lk_capture_battery_trace_row
  lk_capture_smart_trace_row
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # Track FSM state transitions
  _cur_state=$(lk_state_kv state)
  if [ -n "$_cur_state" ] && [ -n "$_last_state" ] && [ "$_cur_state" != "$_last_state" ]; then
    _state_transitions=$((_state_transitions + 1))
    _cpu=$(lk_state_kv cap_temp)
    _alpha=$(lk_state_kv smart_alpha_battery)
    _veto=$(lk_state_kv smart_thermal_veto)
    {
      echo "$(date '+%Y-%m-%d %H:%M:%S') state $_last_state -> $_cur_state  cpu=${_cpu:-?}°C alpha=${_alpha:-?} veto=${_veto:-?}"
    } >> "$LK_OUT_DIR/state_transitions.txt"
  fi
  [ -n "$_cur_state" ] && _last_state="$_cur_state"

  # Track peak CPU
  _cpu=$(lk_state_kv cap_temp)
  case "$_cpu" in
    ''|*[!0-9]*) : ;;
    *)
      if [ "$_cpu" -gt "$_max_cpu" ] 2>/dev/null; then
        _max_cpu=$_cpu
        # On new peak, log full smart state
        {
          echo "$(date '+%Y-%m-%d %H:%M:%S') NEW PEAK cpu=${_cpu}°C  elapsed=${_elapsed}s"
          grep '^smart_' /dev/.asb/state 2>/dev/null | sed 's/^/  /'
        } >> "$LK_OUT_DIR/cpu_peaks.txt"
      fi
      ;;
  esac

  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps
    _last_snapshot=$_now
  fi

  sleep "$LK_POLL_S"
done
