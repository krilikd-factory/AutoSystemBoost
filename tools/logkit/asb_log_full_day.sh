#!/system/bin/sh
#

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

# Auto-detach so the day-long capture survives Termux closure / phone sleep.
if [ -t 0 ]; then
  if command -v setsid >/dev/null 2>&1; then
    if [ -z "${ASB_LOGKIT_DETACHED:-}" ]; then
      export ASB_LOGKIT_DETACHED=1
      echo "[autodetach] Re-launching detached for full-day capture"
      exec setsid sh "$0" "$@" </dev/null
    fi
  fi
fi

LK_SCENARIO="full_day"
LK_OUT_DIR="$(lk_resolve_outbase)/asb_log_${LK_SCENARIO}_$$"
LK_HOURS="${1:-24}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))

# Debug WebUI starts this script behind an atomic lock directory. The recorder, not its
# short-lived launcher, owns the lock: publish our own PID only after the helper-provided
# token matches, and remove it only if the same PID still owns it. Direct terminal starts do
# not set these variables and retain their original behaviour.
LK_WEBUI_LOCKDIR="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"
LK_WEBUI_LOCK_TOKEN="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
LK_WEBUI_OUTPUTFILE="${LK_WEBUI_LOCKDIR:+$LK_WEBUI_LOCKDIR/output_dir}"
lk_webui_guard_claim() {
  [ -n "$LK_WEBUI_LOCKDIR" ] && [ -n "$LK_WEBUI_LOCK_TOKEN" ] || return 0
  [ -d "$LK_WEBUI_LOCKDIR" ] || return 1
  _lwg_token="$(cat "$LK_WEBUI_LOCKDIR/token" 2>/dev/null || true)"
  [ "$_lwg_token" = "$LK_WEBUI_LOCK_TOKEN" ] || return 1
  _lwg_tmp="$LK_WEBUI_LOCKDIR/pid.tmp.$$"
  printf '%s\n' "$$" > "$_lwg_tmp" 2>/dev/null || return 1
  mv -f "$_lwg_tmp" "$LK_WEBUI_LOCKDIR/pid" 2>/dev/null || { rm -f "$_lwg_tmp" 2>/dev/null || true; return 1; }
  return 0
}
lk_webui_guard_release() {
  [ -n "$LK_WEBUI_LOCKDIR" ] && [ -d "$LK_WEBUI_LOCKDIR" ] || return 0
  _lwg_pid="$(tr -dc '0-9' < "$LK_WEBUI_LOCKDIR/pid" 2>/dev/null || true)"
  [ "$_lwg_pid" = "$$" ] || return 0
  rm -rf "$LK_WEBUI_LOCKDIR" 2>/dev/null || true
}
lk_webui_guard_publish_output() {
  [ -n "$LK_WEBUI_OUTPUTFILE" ] || return 0
  [ -d "$LK_WEBUI_LOCKDIR" ] && [ -d "$LK_OUT_DIR" ] || return 1
  _lwo_tmp="${LK_WEBUI_OUTPUTFILE}.tmp.$$"
  printf '%s\n' "$LK_OUT_DIR" > "$_lwo_tmp" 2>/dev/null || return 1
  mv -f "$_lwo_tmp" "$LK_WEBUI_OUTPUTFILE" 2>/dev/null || { rm -f "$_lwo_tmp" 2>/dev/null || true; return 1; }
  return 0
}
# Claim before creating capture artefacts, so any observer sees a recorder PID rather than
# a transient launcher PID. A failed claim means a stale/mismatched caller and must exit.
lk_webui_guard_claim || { echo '[debug-webui] guard claim failed'; exit 2; }
LK_SNAPSHOT_S=3600          # full state snapshot + interim report every hour
LK_BSTATS_WINDOW_MIN=$(( LK_SNAPSHOT_S / 60 ))
export LK_BSTATS_WINDOW_MIN

# Phase-adaptive poll cadence (seconds)
LK_POLL_FAST=15             # gaming / charging — catch transients
LK_POLL_NORMAL=45           # active / post-wake
LK_POLL_SLOW=90             # sleep / idle — don't cost battery
LK_POLL_S=$LK_POLL_NORMAL

# Wakelock attribution snapshot cadence (kernel sources are cheap; app-side
# batterystats is heavier, so only at phase boundaries + hourly).
LK_WAKE_SNAP_S=900

LK_WAKELOCK_NAME="asb_logkit_$$"
LK_HAVE_WAKELOCK=0
lk_wl_acquire() {
  [ -w /sys/power/wake_lock ] || return 0
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null && LK_HAVE_WAKELOCK=1
}
lk_wl_release() {
  [ "$LK_HAVE_WAKELOCK" = "1" ] || return 0
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null && LK_HAVE_WAKELOCK=0
}

# ── phase detection ────────────────────────────────────────────────────────
LK_SCREEN_OFF_SINCE=0
LK_LAST_SCREEN="unknown"
LK_WOKE_AT=0
LK_PHASE_OUT=""
LK_GPU_HI=60
LK_GPU_LO=35
LK_GPU_ENTER=2
LK_GPU_EXIT=3
LK_GPU_HI_STREAK=0
LK_GPU_LO_STREAK=0
LK_IN_GAMING=0
LK_GPU_NOW=0

# Charging phase labels are telemetry, never a governor command. OxygenOS can briefly report
# Awake/Asleep transitions while a plugged-in screen is settling; recording each 15s flip made
# `charging_active` and `charging_idle` look like different workloads. Screen-on remains
# immediate, while active→idle must persist for this bounded window before the ledger changes.
LK_CHG_PHASE_STABLE=""
LK_CHG_IDLE_CANDIDATE_SINCE=0
LK_CHG_IDLE_DEBOUNCE_S="${ASB_LOGKIT_CHG_IDLE_DEBOUNCE_S:-45}"
LK_CHG_IDLE_COALESCED=0
LK_CHG_IDLE_SAMPLES=0
LK_CHG_IDLE_AUDIO_SAMPLES=0
LK_SCREENOFF_LONGEST_S=0
lk_stabilize_charging_phase() {
  _lscp="$1"; _lscn="$2"; LK_CHG_PHASE_OUT=""
  case "$_lscp" in charging_active|charging_idle) : ;; *)
    LK_CHG_PHASE_STABLE=""; LK_CHG_IDLE_CANDIDATE_SINCE=0; LK_CHG_PHASE_OUT="$_lscp"; return 0 ;;
  esac
  # First charging sample establishes context. A return to visible screen use is immediate.
  if [ -z "$LK_CHG_PHASE_STABLE" ] || [ "$_lscp" = "charging_active" ]; then
    LK_CHG_PHASE_STABLE="$_lscp"; LK_CHG_IDLE_CANDIDATE_SINCE=0; LK_CHG_PHASE_OUT="$_lscp"; return 0
  fi
  if [ "$_lscp" = "$LK_CHG_PHASE_STABLE" ]; then
    LK_CHG_IDLE_CANDIDATE_SINCE=0; LK_CHG_PHASE_OUT="$_lscp"; return 0
  fi
  # The only deferred edge is active→idle. Keep the currently visible phase until sleep is
  # sustained; this does not suppress sampling, thermal reads or any ASB policy write.
  [ "$LK_CHG_IDLE_CANDIDATE_SINCE" -gt 0 ] 2>/dev/null || LK_CHG_IDLE_CANDIDATE_SINCE="$_lscn"
  if [ $(( _lscn - LK_CHG_IDLE_CANDIDATE_SINCE )) -ge "$LK_CHG_IDLE_DEBOUNCE_S" ] 2>/dev/null; then
    LK_CHG_PHASE_STABLE="charging_idle"; LK_CHG_IDLE_CANDIDATE_SINCE=0; LK_CHG_PHASE_OUT=charging_idle
  else
    LK_CHG_IDLE_COALESCED=$((LK_CHG_IDLE_COALESCED + 1)); LK_CHG_PHASE_OUT="$LK_CHG_PHASE_STABLE"
  fi
}

lk_sample_gpu_busy() {
  LK_GPU_NOW=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')
  [ -z "$LK_GPU_NOW" ] && LK_GPU_NOW=0
  export LK_GPU_NOW
}

# $1 = "scr" when the display is on.
#
# The screen state HAS to be part of the phase name. Measured over a full day, the
# display costs ~368 mA on this device (480 mA average with it on vs 112 mA off), which
# is several times what playback itself draws. Folding both into one "audio_spk" bucket
# meant its %/h figure mostly reported whether the screen happened to be on -- useless
# for judging what audio actually costs, which is the whole point of these phases.
# Screen-off audio is the clean signal; screen-on audio is kept separately rather than
# thrown away, because it is what the user actually experiences.
lk_audio_phase_name() {
  case "$LK_AUDIO_ROUTE" in
    bt|bt_le) _apn="audio_bt" ;;
    speaker)  _apn="audio_spk" ;;
    wired|usb) _apn="audio_wired" ;;
    *) _apn="audio" ;;
  esac
  [ "${1:-}" = "scr" ] && _apn="${_apn}_scr"
  echo "$_apn"
}

lk_detect_phase() {
  _now="$1"
  # charging?
  _cs=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  # screen state via power manager (cheap, no toybox dep beyond grep/sed)
  _scr=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//;s/ .*//')
  [ -z "$_scr" ] && _scr="$LK_LAST_SCREEN"
  # screen-off duration tracking
  if [ "$_scr" = "Asleep" ] || [ "$_scr" = "Dozing" ]; then
    [ "$LK_SCREEN_OFF_SINCE" = "0" ] && LK_SCREEN_OFF_SINCE="$_now"
  else
    if [ "$LK_LAST_SCREEN" = "Asleep" ] || [ "$LK_LAST_SCREEN" = "Dozing" ]; then
      LK_WOKE_AT="$_now"            # just woke
    fi
    LK_SCREEN_OFF_SINCE=0
  fi
  LK_LAST_SCREEN="$_scr"
  _off_for=0
  [ "$LK_SCREEN_OFF_SINCE" != "0" ] && _off_for=$(( _now - LK_SCREEN_OFF_SINCE ))
  [ "$_off_for" -gt "$LK_SCREENOFF_LONGEST_S" ] 2>/dev/null && LK_SCREENOFF_LONGEST_S="$_off_for"

  # GPU busy + top-app cpu for gaming detection
  _gb="$LK_GPU_NOW"
  [ -z "$_gb" ] && _gb=0
  read -r _l1 _rest < /proc/loadavg
  _l1i=$(echo "$_l1" | tr -dc '0-9')      # e.g. 3.42 -> 342, compared *100

  # charging branches
  case "$_cs" in
    Charging|Full)
      LK_IN_GAMING=0; LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
      if [ "$_scr" = "Awake" ]; then _charge_phase="charging_active"; else _charge_phase="charging_idle"; fi
      lk_stabilize_charging_phase "$_charge_phase" "$_now"
      LK_PHASE_OUT="$LK_CHG_PHASE_OUT"
      return 0 ;;
  esac
  # screen off → sleep vs idle (sleep = off > 20 min)
  if [ "$_scr" = "Asleep" ] || [ "$_scr" = "Dozing" ]; then
    LK_IN_GAMING=0; LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
    if [ "$LK_AUDIO_PLAY" = "1" ]; then LK_PHASE_OUT="$(lk_audio_phase_name)"; return 0; fi
    # Three bands, not two: a pause is not idle.
    #
    # Screen-off under 20 min was all called "idle", so the 40 seconds between putting the
    # phone down and picking it up again landed in the same column as an hour on a desk.
    # The CPU is still finishing what the last app started, so those samples carry
    # screen-on cost into a screen-off average - which is why the idle figure swung from
    # 0.90 %/h to 8.69 between two captures of the same phone, and why the wakelock list
    # for "idle" was full of *launch*.
    #
    # Under two minutes is a gap and is reported as one: still visible, because a phone
    # that never settles is worth seeing, just not averaged into the idle number.
    if [ "$_off_for" -ge 1200 ]; then
      LK_PHASE_OUT="sleep"
    elif [ "$_off_for" -lt 120 ]; then
      LK_PHASE_OUT="gap"
    else
      LK_PHASE_OUT="idle"
    fi
    return 0
  fi
  # screen on: gaming if GPU sustained high (hysteresis, not a single sample)
  if [ "$_gb" -ge "$LK_GPU_HI" ]; then
    LK_GPU_HI_STREAK=$(( LK_GPU_HI_STREAK + 1 )); LK_GPU_LO_STREAK=0
  elif [ "$_gb" -lt "$LK_GPU_LO" ]; then
    LK_GPU_LO_STREAK=$(( LK_GPU_LO_STREAK + 1 )); LK_GPU_HI_STREAK=0
  else
    LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
  fi
  if [ "$LK_IN_GAMING" = "1" ]; then
    [ "$LK_GPU_LO_STREAK" -ge "$LK_GPU_EXIT" ] && LK_IN_GAMING=0
  else
    [ "$LK_GPU_HI_STREAK" -ge "$LK_GPU_ENTER" ] && LK_IN_GAMING=1
  fi
  if [ "$LK_IN_GAMING" = "1" ]; then LK_PHASE_OUT="gaming"; return 0; fi
  if [ "$LK_AUDIO_PLAY" = "1" ]; then LK_PHASE_OUT="$(lk_audio_phase_name scr)"; return 0; fi
  # within 5 min of waking → post_wake (ASB ramp window of interest)
  if [ "$LK_WOKE_AT" != "0" ] && [ $(( _now - LK_WOKE_AT )) -le 300 ]; then
    LK_PHASE_OUT="post_wake"; return 0
  fi
  LK_PHASE_OUT="active"
  return 0
}

# Poll cadence per phase
lk_poll_for_phase() {
  case "$1" in
    gaming|charging_active|charging_idle) echo "$LK_POLL_FAST" ;;
    sleep|idle)                           echo "$LK_POLL_SLOW" ;;
    *)                                    echo "$LK_POLL_NORMAL" ;;
  esac
}

# ── throttle detection ─────────────────────────────────────────────────────
# Prime is the LAST policy, not always policy6.
#
# policy6 is right on a 6+2 layout and does not exist on a 4-cluster one (policy0/2/5/7).
# The same assumption was fixed in the phase sampler earlier; this copy was missed, so on
# those devices the throttle column compared against an empty hwmax and reported 0 for
# every phase - "never throttled" on a phone that was throttling.
LK_PRIME_POL=""
for _pp in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pp" ] && LK_PRIME_POL="$_pp"
done
[ -n "$LK_PRIME_POL" ] || LK_PRIME_POL=/sys/devices/system/cpu/cpufreq/policy6
LK_P0_HWMAX=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
LK_P6_HWMAX=$(cat "$LK_PRIME_POL/cpuinfo_max_freq" 2>/dev/null)
lk_throttle_row() {
  _ph="$1"; _e=$(date +%s)
  _p0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
  _p6=$(cat "$LK_PRIME_POL/scaling_max_freq" 2>/dev/null)
  _capped=0
  [ -n "$_p0" ] && [ -n "$LK_P0_HWMAX" ] && [ "$_p0" -lt "$LK_P0_HWMAX" ] 2>/dev/null && _capped=1
  [ -n "$_p6" ] && [ -n "$LK_P6_HWMAX" ] && [ "$_p6" -lt "$LK_P6_HWMAX" ] 2>/dev/null && _capped=1
  [ "$_capped" = "0" ] && return 0
  _j=$(lk_status_json)
  _temp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}')
  _surf=$(echo "$_j" | awk -F'"surface_hotspot":' '{print $2}' | awk -F, '{print $1}')
  _own=$(echo "$_j"  | awk -F'"cap_owner":"' '{print $2}' | awk -F'"' '{print $1}')
  echo "${_e}|${_ph}|p0_max=${_p0}/${LK_P0_HWMAX}|p6_max=${_p6}/${LK_P6_HWMAX}|cpu_temp=${_temp}|surface=${_surf}|cap_owner=${_own}" >> "$LK_OUT_DIR/throttle_trace.txt"
  # Count it for the summary as well as the trace.
  #
  # LK_PH_THROTTLE was declared, reset per phase and printed - and incremented nowhere.
  # So every report from every device showed "throttle 0" in every phase while the trace
  # beside it held hundreds of capping events: 538 on one capture, 297 on another. Four
  # users read that column as "the module never throttles" and concluded the module was
  # doing nothing about the heat. The column was wrong, not the module.
  LK_PH_THROTTLE=$(( LK_PH_THROTTLE + 1 ))
}

# ── per-phase accounting ───────────────────────────────────────────────────
LK_CUR_PHASE=""
LK_PH_START=0
LK_PH_START_PCT=0
LK_PH_MAXCPU=0
# Discharge current, summed per sample. The percent column is quantised to whole points
# and lags, so on a short capture it can be out by a factor of two: a night trace with a
# 96 mA median was reported as 0.73 %/h, which is the arithmetic of ~44 mA. Current has
# no such step, so it is carried alongside and the two can be compared.
LK_PH_MASUM=0
LK_PH_MACNT=0
LK_PH_MAXSURF=0
LK_PH_MAXP6=0
LK_PH_GPUSUM=0
LK_PH_GPUCNT=0
LK_PH_THROTTLE=0
LK_PH_WAKEPEAK=0
LK_PH_START_UP=0

lk_uptime_s() {
  awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0
}

lk_mono_s() {
  _m=$(awk '/now at/{printf "%d", $3/1000000000; exit}' /proc/timer_list 2>/dev/null)
  [ -n "$_m" ] && echo "$_m" || echo -1
}

# The common battery trace resolves LK_NET_RMNET_IF once per capture. Reuse that
# counter for phase attribution rather than polling a second interface or assuming
# rmnet_data0 exists on every modem.
lk_phase_rmnet_bytes() {
  _if="${LK_NET_RMNET_IF:-rmnet_data0}"
  _rx=$(cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null)
  _tx=$(cat "/sys/class/net/$_if/statistics/tx_bytes" 2>/dev/null)
  case "$_rx" in ''|*[!0-9]*) _rx=0 ;; esac
  case "$_tx" in ''|*[!0-9]*) _tx=0 ;; esac
  printf '%s %s' "$_rx" "$_tx"
}

lk_phase_ledger_row() {
  [ -z "$LK_CUR_PHASE" ] && return 1
  _endpct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _end=$(date +%s)
  _upend=$(lk_uptime_s)
  _monoend=$(lk_mono_s)
  _gavg=0; [ "$LK_PH_GPUCNT" -gt 0 ] && _gavg=$(( LK_PH_GPUSUM / LK_PH_GPUCNT ))
  _elapsed=$(( _upend - LK_PH_START_UP ))
  _awake=-1
  if [ "$_elapsed" -gt 0 ] && [ "$LK_PH_START_MONO" -ge 0 ] 2>/dev/null && [ "$_monoend" -ge 0 ] 2>/dev/null; then
    _mono=$(( _monoend - LK_PH_START_MONO ))
    [ "$_mono" -lt 0 ] && _mono=0
    _awake=$(( _mono * 100 / _elapsed ))
    [ "$_awake" -gt 100 ] && _awake=100
  fi
  _maavg=0
  [ "$LK_PH_MACNT" -gt 0 ] 2>/dev/null && _maavg=$(( LK_PH_MASUM / LK_PH_MACNT ))
  read -r _rmrx _rmtx <<EOF
$(lk_phase_rmnet_bytes)
EOF
  _drx=$(( _rmrx - LK_PH_START_RMNET_RX )); _dtx=$(( _rmtx - LK_PH_START_RMNET_TX ))
  [ "$_drx" -lt 0 ] && _drx=0; [ "$_dtx" -lt 0 ] && _dtx=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LK_CUR_PHASE" "$LK_PH_START" "$_end" "$LK_PH_START_PCT" "$_endpct" \
    "$LK_PH_MAXCPU" "$LK_PH_MAXSURF" "$LK_PH_MAXP6" "$_gavg" \
    "$LK_PH_THROTTLE" "$LK_PH_WAKEPEAK" "$_awake" "$_maavg" "$_drx" "$_dtx"
  return 0
}

lk_phase_ledger_flush() {
  lk_phase_ledger_row >> "$LK_OUT_DIR/phase_ledger.tsv" 2>/dev/null || return 0
}

lk_phase_ledger_snapshot_open() {
  : > "$LK_OUT_DIR/.phase_open.tsv"
  lk_phase_ledger_row >> "$LK_OUT_DIR/.phase_open.tsv" 2>/dev/null || true
}

lk_phase_ledger_open() {
  LK_CUR_PHASE="$1"
  LK_PH_START=$(date +%s)
  LK_PH_START_UP=$(lk_uptime_s)
  LK_PH_START_MONO=$(lk_mono_s)
  LK_PH_START_PCT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  LK_PH_MAXCPU=0; LK_PH_MAXSURF=0; LK_PH_MAXP6=0
  LK_PH_MASUM=0; LK_PH_MACNT=0
  read -r LK_PH_START_RMNET_RX LK_PH_START_RMNET_TX <<EOF
$(lk_phase_rmnet_bytes)
EOF
  LK_PH_GPUSUM=0; LK_PH_GPUCNT=0; LK_PH_THROTTLE=0; LK_PH_WAKEPEAK=0
}

lk_phase_ledger_accumulate() {
  _j=$(lk_status_json)
  _temp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _surf=$(echo "$_j" | awk -F'"surface_hotspot":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _p6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null)
  _gb="$LK_GPU_NOW"
  [ -n "$_temp" ] && [ "$_temp" -gt "$LK_PH_MAXCPU" ] 2>/dev/null && LK_PH_MAXCPU=$_temp
  [ -n "$_surf" ] && [ "$_surf" -gt "$LK_PH_MAXSURF" ] 2>/dev/null && LK_PH_MAXSURF=$_surf
  [ -n "$_p6" ] && [ "$_p6" -gt "$LK_PH_MAXP6" ] 2>/dev/null && LK_PH_MAXP6=$_p6
  if [ -n "$_gb" ]; then LK_PH_GPUSUM=$(( LK_PH_GPUSUM + _gb )); LK_PH_GPUCNT=$(( LK_PH_GPUCNT + 1 )); fi
  # Discharge current only, and the sign convention decides which samples those are.
  #
  # I assumed negative meant discharge and took the absolute value, which folded charging
  # into the same average: a capture that included a charge session reported 5409 mA for
  # charging_idle and 1003 for idle, both meaningless. On this platform the sign is the
  # other way round - discharge is positive, charge is negative - so charging samples are
  # skipped outright rather than flipped. A phase that is entirely charging simply has no
  # current figure, which is honest: there is no discharge to report.
  _ma=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  case "$_ma" in ''|*[!0-9-]*) _ma='' ;; esac
  if [ -n "$_ma" ]; then
    [ "$_ma" -gt 100000 ] 2>/dev/null && _ma=$(( _ma / 1000 ))
    [ "$_ma" -lt -100000 ] 2>/dev/null && _ma=$(( _ma / 1000 ))
    if [ "$_ma" -gt 0 ] && [ "$_ma" -lt 15000 ] 2>/dev/null; then
      LK_PH_MASUM=$(( LK_PH_MASUM + _ma )); LK_PH_MACNT=$(( LK_PH_MACNT + 1 ))
    fi
  fi
  # wake active peak
  _ksrc=/sys/kernel/debug/wakeup_sources
  [ -r "$_ksrc" ] || _ksrc=/d/wakeup_sources
  if [ -r "$_ksrc" ]; then
    _ka=$(awk -v self="$LK_WAKELOCK_NAME" 'NR>1 && $1!=self && $2>0 {n++} END{print n+0}' "$_ksrc" 2>/dev/null)
    [ -n "$_ka" ] && [ "$_ka" -gt "$LK_PH_WAKEPEAK" ] 2>/dev/null && LK_PH_WAKEPEAK=$_ka
  fi
}

# ── screen-off class observation ─────────────────────────────────────────────
# The runtime classifier already produces one read-only state record while the screen is off.
# Reuse it during the user-requested full-day capture; do not wake or probe another subsystem.
lk_screenoff_class_trace_header() {
  printf '# epoch|phase|class|awake_pct|window_min|bat_mA|reason\n' > "$LK_OUT_DIR/screenoff_class_trace.tsv"
}

lk_capture_screenoff_class_row() {
  _sc_phase="${1:-}"
  # Only true screen-off phase labels may consume the classifier's state. The file remains
  # deliberately persistent after waking, so reading it for active/post_wake would be stale.
  case "$_sc_phase" in sleep|idle|gap|audio_bt|audio_spk|audio_wired|audio) : ;; *) return 0 ;; esac
  _sc_file=/dev/.asb/screenoff_class
  [ -r "$_sc_file" ] || return 0
  _sc_values="$(awk -F= '
    /^class=/{c=$2}
    /^awake_pct=/{a=$2}
    /^window_min=/{w=$2}
    END{printf "%s|%s|%s", c,a,w}
  ' "$_sc_file" 2>/dev/null)"
  _sc_reason="$(sed -n 's/^reason=//p' "$_sc_file" 2>/dev/null | head -n 1 | tr '|' '/')"
  [ -n "$_sc_values" ] || return 0
  _sc_bma="$(tail -n 1 "$LK_OUT_DIR/battery_trace.txt" 2>/dev/null | cut -d'|' -f7)"
  case "$_sc_bma" in ''|*[!0-9-]*) _sc_bma='' ;; esac
  # Header order is epoch, phase, class, awake, window, battery current, reason.
  printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$_sc_phase" "$_sc_values" "$_sc_bma" "$_sc_reason" >> "$LK_OUT_DIR/screenoff_class_trace.tsv"
}

lk_emit_screenoff_class_summary() {
  _sc_trace="$LK_OUT_DIR/screenoff_class_trace.tsv"
  [ -s "$_sc_trace" ] || return 0
  echo "===== SCREEN-OFF CLASS OBSERVATIONS ====="
  echo "class        samples cover_min avgAwake    avg_mA  latest observed reason"
  awk -F'|' '
    NR==1 {next}
    NF<7 {next}
    {
      now=$1+0; c=$3; aw=$4; ma=$6; reason=$7
      if(c=="") next
      n[c]++
      if(aw ~ /^[0-9]+$/){aws[c]+=aw; awn[c]++}
      # Assign only a short, same-class interval. Gaps/transitions stay unassigned rather than
      # pretending to know their source; this is observed coverage, not causal energy split.
      if(last[c]>0 && now>=last[c] && now-last[c]<=180) cov[c]+=now-last[c]
      last[c]=now; why[c]=reason
      if(ma ~ /^[0-9]+$/ && ma>0){mas[c]+=ma; man[c]++}
    }
    END{
      for(c in n){
        aa=(awn[c]>0)?aws[c]/awn[c]:-1; mm=(man[c]>0)?mas[c]/man[c]:-1
        aas=(aa>=0)?sprintf("%7.1f",aa):"      -"; mms=(mm>=0)?sprintf("%8.0f",mm):"       -"
        printf "%-12s %7d %9.1f %8s %9s  %s\n",c,n[c],cov[c]/60.0,aas,mms,why[c]
      }
    }
  ' "$_sc_trace" | sort
  echo "Coverage counts adjacent samples of the same observed class (intervals <=180s)."
  echo "avg_mA is sampled discharge current only; it is not a percentage or causal energy allocation."
  echo "Use quiet as a valid night reference; media/network/noisy identify context to investigate."
  echo ""
}

# ── reporting ──────────────────────────────────────────────────────────────
lk_emit_phase_summary() {
  _led="$LK_OUT_DIR/phase_ledger.tsv"
  [ -r "$_led" ] || return 0
  lk_phase_ledger_snapshot_open
  _all="$LK_OUT_DIR/.phase_all.tsv"
  cat "$_led" > "$_all" 2>/dev/null
  [ -s "$LK_OUT_DIR/.phase_open.tsv" ] && cat "$LK_OUT_DIR/.phase_open.tsv" >> "$_all"
  {
    echo "===== PER-PHASE SUMMARY ====="
    echo ""
    printf "%-15s %8s %7s %8s %6s %9s %8s %8s %9s %7s %9s %8s\n" \
      "phase" "dur_min" "d_pct" "pct/h" "mA" "rmnetMiB" "cpuT" "surfT" "p6MHz" "gpu%" "throttle" "awake%"
    awk -F'\t' '
      /^#/{next}
      {
        ph=$1; dur=($3-$2); dpct=($4-$5);
        D[ph]+=dur; DP[ph]+=dpct; N[ph]++;
        # Temperature averaged over the phase, weighted by sample duration - the same
        # basis as pct/h beside it. It was the peak, so one brief spike described a
        # whole night: a capture read "sleep cpuT 67" while the trace behind it sat
        # mostly at 38-44. Peaks keep their place in the hotspots section, where a
        # single moment is exactly the point.
        CT[ph]+=$6*dur; SF[ph]+=$7*dur; TD[ph]+=dur;
        if($8>P6[ph])P6[ph]=$8; G[ph]+=$9; TH[ph]+=$10;
        if($12>=0){ AW[ph]+=$12*dur; AWD[ph]+=dur }
        # Current, averaged on the same duration basis. The print line for this column was
        # added without its accumulator, so MA[] stayed empty and every phase reported 0 mA
        # even though the ledger held real values - 681 in the very first row.
        if($13>0){ MA[ph]+=$13*dur; MAD[ph]+=dur }
        RX[ph]+=$14; TX[ph]+=$15
      }
      END{
        for(p in D){
          durm=D[p]/60.0;
          rate=(D[p]>0)?(DP[p]*3600.0/D[p]):0;
          gavg=(N[p]>0)?(G[p]/N[p]):0;
          aw=(AWD[p]>0)?(AW[p]/AWD[p]):-1;
          aws=(aw>=0)?sprintf("%.1f",aw):"-";
          printf "%-15s %8.1f %7d %8.2f %6d %9.1f %8d %8d %9d %7d %9d %8s\n", \
            p, durm, DP[p], rate, (MAD[p]>0?MA[p]/MAD[p]:0), ((RX[p]+TX[p])/1048576.0), (TD[p]>0?CT[p]/TD[p]:0), (TD[p]>0?SF[p]/TD[p]:0), (P6[p]/1000), gavg, TH[p], aws;
        }
      }
    ' "$_all" | sort -k4 -rn
    awk -F'\t' '
      # Carry current too, and print as many fields as the rows above.
      # When mA was added this line stayed at ten fields while the header went to eleven,
      # so everything after pct/h printed one column left: CPU temperature appeared under
      # "mA" and surface under "cpuT". It reads as plausible numbers, which is exactly
      # what makes it worth fixing rather than tolerating.
      !/^#/ && ($1=="idle" || $1=="sleep") { d=$3-$2; if(d>DUR){DUR=d;SP=$4;EP=$5;CT=$6;SF=$7;P6=$8;AW=$12;MAV=$13} }
      END{ if(DUR>=10800){ aws=(AW>=0)?sprintf("%.1f",AW):"-";
        printf "%-15s %8.1f %7d %8.2f %6d %9s %8d %8d %9d %7s %9s %8s\n", \
        "night(longest)", DUR/60.0, SP-EP, (SP-EP)*3600.0/DUR, MAV, "-", CT, SF, (P6/1000), "-", "-", aws } }
    ' "$_all"
    echo ""
    echo "Legend: d_pct=battery % consumed (negative=gained while charging),"
    echo "        pct/h=drain rate (from %), mA=average discharge current, rmnetMiB=mobile RX+TX"
    echo "        traffic in the phase, cpuT/surfT=average temps (°C), p6MHz=peak prime"
    echo "        clock, gpu%=avg GPU busy, throttle=ticks the prime was capped."
    echo "        awake%=awake share = CLOCK_MONOTONIC delta / boottime delta"
    echo "        (Android uptimeMillis/elapsedRealtime); excludes suspend."
    echo "        On sleep/idle blocks target <5%, >15% = something holds the CPU."
    echo "        night(longest)=longest continuous screen-off block >=3h — the pure"
    echo "        overnight rate; compare IT (not the mixed idle row) against 0.3-0.7 %/h."
    echo "        The currently-open phase is included, so interim reports are complete."
  } > "$LK_OUT_DIR/phase_summary.txt"
  rm -f "$_all" "$LK_OUT_DIR/.phase_open.tsv" 2>/dev/null
}

lk_emit_screenoff_sleep() {
  _bs=$(dumpsys batterystats 2>/dev/null | grep -m1 -iE "screen off:.*realtime.*uptime")
  [ -z "$_bs" ] && { echo "  screen-off CPU sleep: n/a (batterystats line not found)"; return 0; }
  echo "$_bs" | sed 's/.*[Ss]creen off: //; s/ realtime,/|/; s/ uptime.*//' | awk -F'|' '
    function tosec(t,  n,a,i,v,u){ n=split(t,a," "); v=0
      for(i=1;i<=n;i++){ u=a[i]
        if(u ~ /ms$/) continue
        if(u ~ /h$/){sub(/h/,"",u); v+=u*3600}
        else if(u ~ /m$/){sub(/m/,"",u); v+=u*60}
        else if(u ~ /s$/){sub(/s/,"",u); v+=u} }
      return v }
    { rt=$1; sub(/ \(.*\)/,"",rt); r=tosec(rt); u=tosec($2)
      if(r>0){ aw=u*100.0/r
        printf "  screen-off: %.1fh realtime, CPU awake %.0fm -> awake %.1f%% (deep sleep %.1f%%)\n", r/3600.0, u/60.0, aw, 100-aw
        printf "  NOTE: batterystats is reset every %s min, so this covers only the last\n", ENVIRON["LK_BSTATS_WINDOW_MIN"]
        printf "        window, NOT the whole night. For the overnight number read the\n"
        printf "        awake%% column of night(longest) in the per-phase summary.\n" } }'
}

lk_emit_full_day_report() {
  _led="$LK_OUT_DIR/phase_ledger.tsv"
  _out="$LK_OUT_DIR/_full_day_report.txt"
  {
    echo "==================================================================="
    echo " ASB FULL-DAY REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
    echo " capture: ${LK_HOURS}h target, $(( ($(date +%s) - LK_START_EPOCH) / 60 )) min elapsed"
    echo "==================================================================="
    echo ""
    echo "----- NIGHT / SCREEN-OFF CPU SLEEP -----"
    lk_emit_screenoff_sleep
    echo ""
    lk_emit_capture_validity
    echo ""
    lk_emit_screenoff_class_summary
    if [ -r "$LK_OUT_DIR/phase_summary.txt" ]; then
      cat "$LK_OUT_DIR/phase_summary.txt"
    fi
    echo ""
    echo "----- THROTTLE HOTSPOTS (prime capped below hardware max) -----"
    if [ -s "$LK_OUT_DIR/throttle_trace.txt" ]; then
      # One trace row is one scheduled poll where a ceiling was already below hardware max;
      # it is not one independent thermal incident. Count data rows only and group continuous
      # ownership so a 30-minute vendor hold is read as one period, not dozens of "events".
      _tc=$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}' "$LK_OUT_DIR/throttle_trace.txt")
      echo "throttle samples logged: $_tc (poll observations, not independent clamp incidents)"
      echo "continuous clamp periods (new period after >180s gap or owner change):"
      awk -F'|' '
        function emit(){ if(n>0) printf "  owner=%-8s duration=%4d min samples=%d  epoch=%s..%s\n", own, (last-start)/60, n, start, last }
        NR==1 {next}
        NF<6 {next}
        {
          raw=$0; split(raw,a,"cap_owner="); own_now=a[2]; sub(/\|.*/,"",own_now)
          if(own_now=="") own_now="unknown"
          now=$1+0
          if(n==0){ start=now; last=now; own=own_now; n=1; next }
          if((now-last)>180 || own_now!=own){ emit(); start=now; own=own_now; n=1 }
          else n++
          last=now
        }
        END{emit()}
      ' "$LK_OUT_DIR/throttle_trace.txt"
      echo "by phase:"
      awk -F'|' 'NR>1{print $2}' "$LK_OUT_DIR/throttle_trace.txt" \
        | sort | uniq -c | sort -rn | head
      echo "by cap owner:"
      awk -F'cap_owner=' 'NR>1 && NF>1{split($2,a,"|"); print a[1]}' "$LK_OUT_DIR/throttle_trace.txt" \
        | sort | uniq -c | sort -rn | head
      echo "sample (first + worst-temp few):"
      head -3 "$LK_OUT_DIR/throttle_trace.txt"
    else
      echo "none — prime never capped below hardware max during capture."
      echo "(if you gamed hard and still see none, ASB+thermal kept full clocks)"
    fi
    echo ""
    lk_emit_cap_ownership_verdict
    echo ""
    echo "----- WAKE SOURCES (who kept the device awake) -----"
    if [ -s "$LK_OUT_DIR/_wakelock_report.txt" ]; then
      echo "Android batterystats attribution (works without debugfs):"
      echo "see _wakelock_report.txt for the ranked offenders. Top of it:"
      sed -n '/TOP PARTIAL WAKELOCK HOLDERS/,/TOP ALARM/p' \
        "$LK_OUT_DIR/_wakelock_report.txt" 2>/dev/null | head -12
    elif [ -s "$LK_OUT_DIR/wake_sources.txt" ]; then
      echo "see wake_sources.txt for full detail. DELTA (active time gained"
      echo "during capture) is the actionable part — top offenders:"
      awk '/DELTA over capture/{f=1;next} /^=====/{f=0} f&&NF>=3 && $1!~/^#/{print}' \
        "$LK_OUT_DIR/wake_sources.txt" | head -12
    else
      echo "wakeup attribution unavailable (no debugfs and no dumpsys)."
    fi
    echo ""
  lk_emit_charging_idle_anomaly
  echo ""
  echo "----- AUDIOMIX LIVE ATTRIBUTION -----"
  _amix="$LK_OUT_DIR/audio_wakelock_attribution.tsv"
  if [ -r "$_amix" ] && [ "$(awk 'NR>1{n++} END{print n+0}' "$_amix")" -gt 0 ] 2>/dev/null; then
    awk -F'|' 'NR>1 {k=$3"|"$4; n[k]++} END {for(k in n) print n[k]"  "k}' "$_amix" | sort -rn | head -12 | \
      awk -F'  ' '{print "samples=" $1 "  uid|package=" $2}'
    echo "detail: audio_wakelock_attribution.tsv; unresolved means Android did not expose a UID mapping."
  else
    echo "no AudioMix partial wakelock observed in live power-manager samples."
  fi
  echo ""
    echo "----- BLUETOOTH LIFECYCLE (read-only, addresses redacted) -----"
    _bt_ev="$LK_OUT_DIR/bt_lifecycle_events.tsv"
    _bt_ctx="$LK_OUT_DIR/bt_lifecycle_context.tsv"
    if [ -r "$_bt_ev" ]; then
      _bt_n=$(awk '!/^#/ && NF>=4 {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_hfp_c=$(awk '!/^#/ && $3=="hfp_audio_connect" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_hfp_d=$(awk '!/^#/ && $3=="hfp_audio_disconnect" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_a2dp_c=$(awk '!/^#/ && $3=="a2dp_profile_connect" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_a2dp_d=$(awk '!/^#/ && $3=="a2dp_profile_disconnect" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_gc=$(awk '!/^#/ && $3=="connect_generic" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_gd=$(awk '!/^#/ && $3=="disconnect_generic" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      _bt_r=$(awk '!/^#/ && $3=="reconnect_literal" {n++} END{print n+0}' "$_bt_ev" 2>/dev/null)
      echo "lifecycle events: $_bt_n  A2DP profile=$_bt_a2dp_c/$_bt_a2dp_d (connect/disconnect)  HFP audio=$_bt_hfp_c/$_bt_hfp_d (attach/detach)  generic=$_bt_gc/$_bt_gd  explicit_reconnect=$_bt_r"
      echo "HFP audio detach is not a Bluetooth-device disconnect; A2DP profile disconnect is the media-profile evidence."
      echo "see bt_lifecycle_events.tsv for timestamped stack evidence and bt_lifecycle_context.tsv for nearest audio route context."
      echo "A route/context row alone is not counted as a reconnect."
    else
      echo "unavailable — Bluetooth lifecycle recorder did not start."
    fi
    echo ""
    echo "----- READING THIS -----"
    echo "* Compare pct/h across phases. 'sleep' and 'idle' should be the"
    echo "  lowest; if 'idle' ≈ 'active' something is keeping the SoC busy —"
    echo "  cross-check wake_sources.txt for that window."
    echo "* In 'gaming', look at p6MHz vs hardware max and the throttle count:"
    echo "  if throttle is high and surfT is moderate, the cap is vendor/ASB,"
    echo "  not heat — there may be headroom to let clocks run higher."
    echo "* If a kernel wake source dominates the DELTA and isn't essential,"
    echo "  that's a concrete ASB target (prop/standby tuning)."
    echo "* 'audio_bt' / 'audio_spk' / 'audio_wired' = media was playing on that"
    echo "  route. Compare pct/h and cpuT between BT and speaker playback, and"
    echo "  read audio_trace.txt for codec / offload / effect state per route."
    echo "* Bluetooth evidence: `hfp_audio_disconnect` is an HFP/SCO audio-link detach, not a device loss;"
    echo "  `a2dp_profile_disconnect` is the media-profile disconnect evidence. Use context to correlate route/playback."
    echo "* kernel_params.txt captures governors, sched, io, walt and vm tunables"
    echo "  (stock vs custom kernel); network_trace.txt captures the data path,"
    echo "  signal, tcp tunables and rmnet/wlan counters."
    # ── what the user changed during the capture ─────────────────────────
    # This section exists so a reader never has to guess whether an effect had a
    # cause. Every other trace answers "what happened"; only this one answers
    # "because someone changed X at 14:06".
    if [ -s "$LK_OUT_DIR/config_changes.txt" ] \
       && [ "$(wc -l < "$LK_OUT_DIR/config_changes.txt" 2>/dev/null)" -gt 1 ]; then
      echo ""
      echo "── SETTINGS CHANGED DURING CAPTURE ────────────────────────────"
      echo "  time                 source    key                     old -> new"
      awk -F'|' 'NR>1 && NF>=6 {printf "  %-20s %-9s %-23s %s -> %s\n", $2, $3, $4, $5, $6}' \
        "$LK_OUT_DIR/config_changes.txt" 2>/dev/null | head -60
      echo ""
      echo "  Cross-reference these timestamps against battery_trace.txt and"
      echo "  phase_timeline.txt before blaming any single tunable."
    fi

    # ── charging ─────────────────────────────────────────────────────────
    if [ -s "$LK_OUT_DIR/charge_trace.txt" ] \
       && [ "$(wc -l < "$LK_OUT_DIR/charge_trace.txt" 2>/dev/null)" -gt 1 ]; then
      echo ""
      echo "── CHARGING ───────────────────────────────────────────────────"
      awk -F'|' '
        NR<=1 { next }
        {
          n++
          if (first=="") { first=$2; fpct=$8; fcc=$12 }
          last=$2; lpct=$8; lcc=$12
          mA=$9/1000; if (mA<0) mA=-mA
          if (mA>peak) peak=mA
          sum+=mA
          t=$11/10; if (t>tmax) tmax=t
          if ($4!="" && $4!="?") type[$4]++
          if ($14!="" && $14!="?") { icl=$14/1000; if (iclmin==0 || icl<iclmin) iclmin=icl; if (icl>iclmax) iclmax=icl }
        }
        END {
          if (n==0) exit
          printf "  samples while plugged in : %d\n", n
          printf "  battery                  : %s%% -> %s%%\n", fpct, lpct
          if (fcc+0>0 && lcc+0>0) printf "  charge counter delta     : %.0f mAh\n", (lcc-fcc)/1000
          printf "  charge current  avg/peak : %.0f / %.0f mA\n", sum/n, peak
          if (iclmax>0) printf "  input current limit rng  : %.0f - %.0f mA  (OEM thermal pulls this back)\n", iclmin, iclmax
          printf "  peak battery temperature : %.1f C\n", tmax
          printf "  charge types seen        : "
          for (k in type) printf "%s(%d) ", k, type[k]
          printf "\n"
        }' "$LK_OUT_DIR/charge_trace.txt" 2>/dev/null
      echo ""
      echo "  A falling input-current limit with a rising temperature is the OEM"
      echo "  charger backing off, not ASB - ASB does not touch charge current."
    fi

    # ── ASB feature engagement ───────────────────────────────────────────
    if [ -s "$LK_OUT_DIR/asb_features.txt" ] \
       && [ "$(wc -l < "$LK_OUT_DIR/asb_features.txt" 2>/dev/null)" -gt 1 ]; then
      echo ""
      echo "── ASB FEATURE ENGAGEMENT ─────────────────────────────────────"
      awk -F'|' '
        NR<=1 { next }
        { n++; if ($3==1) cam++; lpm[$4]++; if ($5==1) dsp++; if ($8==1) veto++; abi=$7 }
        END {
          if (n==0) exit
          printf "  samples                  : %d\n", n
          printf "  camera hold active       : %d (%.1f%%)\n", cam+0, (cam*100.0)/n
          printf "  thermal veto active      : %d (%.1f%%)\n", veto+0, (veto*100.0)/n
          printf "  DSP enabled              : %d (%.1f%%)  abi=%s\n", dsp+0, (dsp*100.0)/n, abi
          printf "  modem LPM mode           : "
          for (k in lpm) if (k!="") printf "%s(%d) ", k, lpm[k]
          printf "\n"
        }' "$LK_OUT_DIR/asb_features.txt" 2>/dev/null
    fi

    echo ""
    echo "Send the whole output folder back for a targeted ASB tuning pass."
  } > "$_out"
}

# ── report-only validity and attribution helpers ───────────────────────────
# These helpers read recorder artifacts only. They never adjust charging, thermal, CPU or app policy.
lk_emit_capture_validity() {
  _lv_elapsed=$(( $(date +%s) - LK_START_EPOCH ))
  echo "----- CAPTURE VALIDITY -----"
  if [ "$_lv_elapsed" -lt 10800 ]; then
    echo "runtime verdict: preliminary (${_lv_elapsed}s captured; <3h). Use it for state/ownership evidence, not battery-life conclusions."
  elif [ "$_lv_elapsed" -lt 21600 ]; then
    echo "runtime verdict: partial-day (${_lv_elapsed}s captured; <6h). Phase evidence is useful; day-level battery estimates remain provisional."
  else
    echo "runtime verdict: extended capture (${_lv_elapsed}s captured)."
  fi
  if [ "$LK_SCREENOFF_LONGEST_S" -ge 10800 ] 2>/dev/null; then
    echo "night verdict: valid (longest continuous screen-off $((LK_SCREENOFF_LONGEST_S / 60)) min >=180 min)."
  else
    echo "night verdict: unavailable (longest continuous screen-off $((LK_SCREENOFF_LONGEST_S / 60)) min; need >=180 min)."
  fi
}

lk_emit_cap_ownership_verdict() {
  _lc_trace="$LK_OUT_DIR/throttle_trace.txt"
  [ -s "$_lc_trace" ] || return 0
  _lc_vendor=$(awk -F'cap_owner=' 'NF>1 && $2 ~ /^vendor/{n++} END{print n+0}' "$_lc_trace")
  _lc_shell=$(awk -F'cap_owner=' 'NF>1 && $2 ~ /^shell/{n++} END{print n+0}' "$_lc_trace")
  _lc_asb=$(awk -F'cap_owner=' 'NF>1 && $2 ~ /^asb/{n++} END{print n+0}' "$_lc_trace")
  _lc_foreign=$(( _lc_vendor + _lc_shell ))
  echo "----- CAP OWNERSHIP VERDICT -----"
  echo "observed throttle owners: vendor=$_lc_vendor shell=$_lc_shell asb=$_lc_asb"
  if [ "$_lc_foreign" -gt "$_lc_asb" ] && [ "$_lc_foreign" -ge 3 ]; then
    echo "verdict: foreign cap ownership dominated this capture; ASB does not raise universal frequencies. Native vendor holddown/detente remains responsible for suppressing losing idle writes."
  else
    echo "verdict: no foreign-owner dominance established in this capture."
  fi
}

lk_charge_idle_observe() {
  [ "$1" = "charging_idle" ] || return 0
  LK_CHG_IDLE_SAMPLES=$((LK_CHG_IDLE_SAMPLES + 1))
  [ "${LK_AUDIO_PLAY:-0}" = "1" ] && LK_CHG_IDLE_AUDIO_SAMPLES=$((LK_CHG_IDLE_AUDIO_SAMPLES + 1))
}

lk_emit_charging_idle_anomaly() {
  _lci_ledger="$LK_OUT_DIR/phase_ledger.tsv"
  [ -s "$_lci_ledger" ] || return 0
  _lci=$(awk -F'\t' '$1=="charging_idle" {d=$3-$2; if(d>0){sec+=d; aw+=$12*d}} END{if(sec>0) printf "%d %.1f",sec,aw/sec}' "$_lci_ledger")
  [ -n "$_lci" ] || return 0
  set -- $_lci; _lci_sec="$1"; _lci_awake="$2"
  _lci_audio_pct=0
  [ "$LK_CHG_IDLE_SAMPLES" -gt 0 ] 2>/dev/null && _lci_audio_pct=$(( LK_CHG_IDLE_AUDIO_SAMPLES * 100 / LK_CHG_IDLE_SAMPLES ))
  echo "----- CHARGING-IDLE AWAKE VERDICT -----"
  echo "charging_idle: $((_lci_sec / 60)) min, awake ${_lci_awake}%, audio samples ${_lci_audio_pct}%, debounce-coalesced samples ${LK_CHG_IDLE_COALESCED}"
  if [ "$_lci_sec" -ge 900 ] && awk -v a="$_lci_awake" 'BEGIN{exit !(a >= 50)}' && [ "$_lci_audio_pct" -le 10 ]; then
    echo "anomaly: sustained screen-off charging idle stayed awake. Inspect ranked partial wakelocks below; ASB does not alter charge current or kill apps automatically."
  else
    echo "verdict: no sustained no-audio charging-idle awake anomaly established."
  fi
}

# ── run ────────────────────────────────────────────────────────────────────
# Full-day logs are a user-requested diagnostic capture. Enable bounded, redacted Bluetooth
# lifecycle evidence by default so a reconnect can be proven without an extra environment flag.
# A tester who explicitly does not want the trace may still start with ASB_BT_RECONNECT_TRACE=0.
: "${ASB_BT_RECONNECT_TRACE:=1}"
export ASB_BT_RECONNECT_TRACE
lk_init
# Publish after lk_init created the per-capture directory. If the user later deletes this
# exact directory, the launcher can safely identify this capture as cancelled/orphaned.
lk_webui_guard_publish_output || { echo '[debug-webui] output marker publish failed'; lk_webui_guard_release; exit 2; }
lk_audio_wakelock_attribution_init
lk_fsm_media_trace_header
lk_bt_reconnect_start

# trace headers
lk_perf_trace_header
lk_battery_trace_header
lk_charge_trace_header
lk_asb_feature_header
lk_config_watch_init
lk_screenoff_class_trace_header
{ echo "# phase timeline — epoch | iso | phase | trigger"; } > "$LK_OUT_DIR/phase_timeline.txt"
{ echo "# throttle trace — epoch | phase | p0 | p6 | temps | cap_owner"; } > "$LK_OUT_DIR/throttle_trace.txt"
printf '# phase\tstart\tend\tstart_pct\tend_pct\tmaxCpuT\tmaxSurfT\tmaxP6\tgpuAvg\tthrottle\twakePeak\tawakePct\tavgMA\trmnetRxBytes\trmnetTxBytes\n' > "$LK_OUT_DIR/phase_ledger.tsv"

# wakelock baseline + reset
lk_wakelock_kernel_baseline
lk_wakelock_kernel_snapshot "start"
lk_wakelock_batterystats_reset
lk_oem_ram_expand_probe "start"
lk_oem_toggle_row

lk_finalize() {
  [ "${LK_FINALIZED:-0}" = "1" ] && return 0
  LK_FINALIZED=1
  lk_wl_release
  lk_bt_reconnect_snapshot "end"
  lk_bt_reconnect_stop
  lk_phase_ledger_accumulate
  lk_phase_ledger_flush
  lk_wakelock_kernel_snapshot "end"
  lk_wakelock_kernel_delta
  lk_wakelock_batterystats_dump
  lk_oem_ram_expand_probe "end"
  lk_emit_phase_summary
  lk_emit_full_day_report
  lk_snapshot_state "after"
}
trap 'lk_finalize; lk_webui_guard_release; exit 0' TERM INT HUP

echo "[$(date '+%H:%M:%S')] FULL-DAY capture running up to ${LK_HOURS}h. Use the phone normally."

_last_snapshot=$(date +%s)
_last_wakesnap=$(date +%s)
lk_snapshot_kernel "before"
lk_snapshot_network "before"
lk_sample_gpu_busy
lk_sample_audio
# Resolve the live route counters before opening the first phase, so its mobile
# traffic delta has the same interface identity as later battery-trace rows.
lk_capture_battery_trace_row
lk_snapshot_audio "before"
lk_bt_reconnect_snapshot "before"
lk_detect_phase "$(date +%s)"; _phase="$LK_PHASE_OUT"
lk_capture_screenoff_class_row "$_phase"
lk_phase_ledger_open "$_phase"
echo "$(date +%s)|$(date '+%Y-%m-%d %H:%M:%S')|$_phase|capture_start" >> "$LK_OUT_DIR/phase_timeline.txt"

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  lk_wl_acquire
  lk_sample_gpu_busy
  lk_sample_audio

  # detect phase; on change, flush the ledger and re-open
  lk_detect_phase "$_now"; _new_phase="$LK_PHASE_OUT"
  if [ "$_new_phase" != "$_phase" ]; then
    lk_phase_ledger_accumulate
    lk_phase_ledger_flush
    echo "${_now}|$(date '+%Y-%m-%d %H:%M:%S')|${_new_phase}|from:${_phase}" >> "$LK_OUT_DIR/phase_timeline.txt"
    # at every phase boundary, grab a wake snapshot (cheap kernel side)
    lk_wakelock_kernel_snapshot "phase:${_new_phase}"
    # Both snapshots gated on an audio phase, matching the deployed 507 build.
    #
    # My port put the reconnect snapshot after the case instead of inside it, so it fired on
    # every phase transition rather than only audio ones. The recorder is opt-in, so no
    # ordinary capture was affected - but a reconnect trace is about audio, and a snapshot
    # taken entering "idle" spends a logcat read to record nothing.
    case "$_new_phase" in
      audio*)
        lk_snapshot_audio "enter:${_new_phase}"
        lk_bt_reconnect_snapshot "phase:${_new_phase}"
        ;;
    esac
    lk_phase_ledger_open "$_new_phase"
    _phase="$_new_phase"
    LK_POLL_S="$(lk_poll_for_phase "$_phase")"
  fi

  # per-poll capture
  lk_capture_perf_trace_row
  lk_capture_battery_trace_row
  lk_capture_screenoff_class_row "$_phase"
  lk_capture_fsm_media_trace_row "$_phase"
  lk_wakelock_live_row
  lk_oem_toggle_row
  lk_throttle_row "$_phase"
  # What the user changed, what the charger is doing, and which ASB features are
  # engaged. The first is the one that was missing most: without it a trace shows an
  # effect with no visible cause, because the cause was someone tapping a switch.
  lk_config_watch_row
  lk_charge_trace_row
  lk_asb_feature_row
  lk_charge_idle_observe "$_phase"
  lk_phase_ledger_accumulate
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # periodic heavier wake snapshot
  if [ $(( _now - _last_wakesnap )) -ge "$LK_WAKE_SNAP_S" ]; then
    lk_wakelock_kernel_snapshot "periodic"
    _last_wakesnap=$_now
  fi

  # hourly: full state snapshot + interim reports
  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_snapshot_kernel "hourly"
    lk_snapshot_network "hourly"
    lk_snapshot_audio "hourly"
    lk_bt_reconnect_snapshot "hourly"
    lk_verify_caps
    lk_emit_phase_summary 2>/dev/null || true
    lk_emit_full_day_report 2>/dev/null || true
    # Android-side wakelock attribution snapshot each hour (works without
    # debugfs). Dumps + refreshes the parsed offenders report, then resets the
    # batterystats window so the next hour is attributed cleanly.
    lk_wakelock_batterystats_dump 2>/dev/null || true
    lk_wakelock_batterystats_reset 2>/dev/null || true
    _last_snapshot=$_now
  fi

  lk_wl_release
  sleep "$LK_POLL_S"
done

# finalize
lk_finalize
lk_wl_release
lk_finalize
lk_webui_guard_release
echo "[$(date '+%H:%M:%S')] FULL-DAY capture complete. Output: $LK_OUT_DIR"
