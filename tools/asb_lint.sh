#!/system/bin/sh

MODID="AutoSystemBoost"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
resolve_moddir() {
  for d in \
    "$MODDIR" \
    "${SCRIPT_DIR%/tools}" \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID"; do
    [ -n "$d" ] || continue
    [ -f "$d/module.prop" ] && { echo "$d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(resolve_moddir)"

find_python() {
  for p in "${PYTHON3:-}" python3 /data/data/com.termux/files/usr/bin/python3; do
    [ -n "$p" ] || continue
    command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
PYTHON_BIN="$(find_python 2>/dev/null || true)"

ERRORS=0; WARNS=0
err()  { ERRORS=$((ERRORS+1)); echo "  ❌ $1"; }
warn() { WARNS=$((WARNS+1));   echo "  ⚠️  $1"; }
ok()   { echo "  ✅ $1"; }

get_kv() {
  _file="$1"; _key="$2"
  awk -F= -v k="$_key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      split(line, a, "=")
      key=a[1]
      gsub(/[[:space:]]+$/, "", key)
      if (key == k) {
        sub(/^[^=]*=/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        sub(/^"/, "", line)
        sub(/"$/, "", line)
        print line
        exit
      }
    }
  ' "$_file"
}

num_ge() { [ "$1" -ge "$2" ] 2>/dev/null; }
num_le() { [ "$1" -le "$2" ] 2>/dev/null; }
num_gt() { [ "$1" -gt "$2" ] 2>/dev/null; }

check_shell_syntax() {
  _f="$1"
  if sh -n "$_f" 2>/dev/null; then
    ok "$(basename "$_f") syntax ok"
  else
    err "$(basename "$_f") syntax error"
  fi
}

validate_json() {
  _f="$1"
  if [ -z "$PYTHON_BIN" ]; then
    warn "python3 not found, skipped JSON validation for $(basename "$_f")"
    return 0
  fi
  if "$PYTHON_BIN" -c "import json; json.load(open('$_f', encoding='utf-8'))" 2>/dev/null; then
    ok "$(basename "$_f"): valid JSON"
  else
    err "$(basename "$_f"): invalid JSON"
  fi
}

echo "═══════════════════════════════"
echo "  ASB Config Lint"
echo "═══════════════════════════════"
echo "  Module dir: $MODDIR"

echo
echo "🐚 Shell Syntax"
for f in \
  "$MODDIR/service.sh" \
  "$MODDIR/runtime/asb_watchdog.sh" \
  "$MODDIR/runtime/asb_reconcile.sh" \
  "$MODDIR/tools/asb_doctor.sh" \
  "$MODDIR/tools/asb_release_pack.sh"; do
  [ -f "$f" ] && check_shell_syntax "$f"
done

echo
echo "⚙️  governor.conf"
CONF="$MODDIR/config/governor.conf"
if [ ! -f "$CONF" ]; then
  err "governor.conf not found"
else
  DUPES="$(awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != "") print key
    }' "$CONF" | sort | uniq -d)"
  [ -n "$DUPES" ] && err "duplicate keys: $DUPES" || ok "no duplicate keys"

  for need in sustained_temp_enter sustained_temp_exit auto_degrade_thermal_pct; do
    v="$(get_kv "$CONF" "$need")"
    [ -n "$v" ] && ok "$need present" || err "$need missing"
  done
  A_TIME="$(get_kv "$CONF" auto_degrade_time_gate)"
  [ -n "$A_TIME" ] && ok "auto_degrade_time_gate present" || warn "auto_degrade_time_gate not set (using built-in timing logic)"

  HEAVY_GPU="$(get_kv "$CONF" heavy_gpu_enter)"
  S_ENTER="$(get_kv "$CONF" sustained_temp_enter)"
  S_EXIT="$(get_kv "$CONF" sustained_temp_exit)"
  A_THERM="$(get_kv "$CONF" auto_degrade_thermal_pct)"

  [ -n "$HEAVY_GPU" ] && { num_ge "$HEAVY_GPU" 10 && num_le "$HEAVY_GPU" 90 && ok "heavy_gpu_enter in range" || warn "heavy_gpu_enter=$HEAVY_GPU outside 10-90"; }
  [ -n "$S_ENTER" ] && { num_ge "$S_ENTER" 50 && num_le "$S_ENTER" 95 && ok "sustained_temp_enter in range" || warn "sustained_temp_enter=$S_ENTER outside 50-95"; }
  [ -n "$S_EXIT" ]  && { num_ge "$S_EXIT" 35 && num_le "$S_EXIT" 90 && ok "sustained_temp_exit in range" || warn "sustained_temp_exit=$S_EXIT outside 35-90"; }
  [ -n "$A_THERM" ] && { num_ge "$A_THERM" 20 && num_le "$A_THERM" 95 && ok "auto_degrade_thermal_pct in range" || warn "auto_degrade_thermal_pct=$A_THERM outside 20-95"; }
  [ -n "$A_TIME" ]  && { num_ge "$A_TIME" 30 && num_le "$A_TIME" 600 && ok "auto_degrade_time_gate in range" || warn "auto_degrade_time_gate=$A_TIME outside 30-600"; }

  if [ -n "$S_ENTER" ] && [ -n "$S_EXIT" ]; then
    if num_ge "$S_EXIT" "$S_ENTER"; then
      err "sustained_temp_exit($S_EXIT) >= sustained_temp_enter($S_ENTER)"
    else
      ok "sustained temp enter/exit consistent"
    fi
  fi
fi

echo
echo "📋 Profile Consistency"
for p in battery balanced performance; do
  f="$MODDIR/profiles/${p}.sh"
  [ ! -f "$f" ] && { err "$p.sh missing"; continue; }
  check_shell_syntax "$f"

  P="$(echo "$p" | tr '[:lower:]' '[:upper:]')"
  if [ -f "$MODDIR/config/profile_bounds.generated.sh" ]; then
    _src="$MODDIR/config/profile_bounds.generated.sh"
    CPU_MIN_L="$(get_kv "$_src" "${P}_CPU_MIN_LITTLE")"
    CPU_MIN_B="$(get_kv "$_src" "${P}_CPU_MIN_BIG")"
    CPU_MAX_L="$(get_kv "$_src" "${P}_CPU_MAX_LITTLE")"
    CPU_MAX_B="$(get_kv "$_src" "${P}_CPU_MAX_BIG")"
    CPU_CAP_L="$(get_kv "$_src" "${P}_CPU_CAP_LITTLE")"
    CPU_CAP_B="$(get_kv "$_src" "${P}_CPU_CAP_BIG")"
    GPU_MAX="$(get_kv "$_src" "${P}_GPU_MAX_PCT")"
  else
    CPU_MIN_L="$(get_kv "$f" CPU_MIN_LITTLE)"
    CPU_MIN_B="$(get_kv "$f" CPU_MIN_BIG)"
    CPU_MAX_L="$(get_kv "$f" CPU_MAX_LITTLE)"
    CPU_MAX_B="$(get_kv "$f" CPU_MAX_BIG)"
    CPU_CAP_L="$(get_kv "$f" CPU_CAP_LITTLE)"
    CPU_CAP_B="$(get_kv "$f" CPU_CAP_BIG)"
    GPU_MAX="$(get_kv "$f" GPU_MAX_PCT)"
  fi
  GPU_MIN="$(get_kv "$f" GPU_MIN_PCT)"
  SCHED_UP="$(get_kv "$f" SCHED_UP_RATE)"
  SCHED_DOWN="$(get_kv "$f" SCHED_DOWN_RATE)"

  [ -n "$CPU_MIN_L" ] && [ -n "$CPU_CAP_L" ] && num_gt "$CPU_MIN_L" "$CPU_CAP_L" && err "$p: CPU_MIN_LITTLE($CPU_MIN_L) > CPU_CAP_LITTLE($CPU_CAP_L)"
  [ -n "$CPU_MIN_B" ] && [ -n "$CPU_CAP_B" ] && num_gt "$CPU_MIN_B" "$CPU_CAP_B" && err "$p: CPU_MIN_BIG($CPU_MIN_B) > CPU_CAP_BIG($CPU_CAP_B)"
  [ -n "$CPU_CAP_L" ] && [ -n "$CPU_MAX_L" ] && num_gt "$CPU_CAP_L" "$CPU_MAX_L" && err "$p: CPU_CAP_LITTLE($CPU_CAP_L) > CPU_MAX_LITTLE($CPU_MAX_L)"
  [ -n "$CPU_CAP_B" ] && [ -n "$CPU_MAX_B" ] && num_gt "$CPU_CAP_B" "$CPU_MAX_B" && err "$p: CPU_CAP_BIG($CPU_CAP_B) > CPU_MAX_BIG($CPU_MAX_B)"
  [ -n "$GPU_MIN" ] && [ -n "$GPU_MAX" ] && num_gt "$GPU_MIN" "$GPU_MAX" && err "$p: GPU_MIN_PCT($GPU_MIN) > GPU_MAX_PCT($GPU_MAX)"
  [ -n "$SCHED_UP" ] && [ -n "$SCHED_DOWN" ] && num_gt "$SCHED_UP" "$SCHED_DOWN" && warn "$p: SCHED_UP_RATE($SCHED_UP) > SCHED_DOWN_RATE($SCHED_DOWN)"

  [ -n "$CPU_MAX_L" ] && [ -n "$CPU_MAX_B" ] && ok "$p.sh core ranges parsed"
done

echo
echo "📊 Profile Hierarchy"
_bsh="$MODDIR/config/profile_bounds.generated.sh"
_bcf="$MODDIR/config/profile_bounds.conf"
_hierarchy_src=""
if [ -f "$_bsh" ]; then
  _hierarchy_src="$_bsh"
elif [ -f "$_bcf" ]; then
  _hierarchy_src="$_bcf"
fi
if [ -n "$_hierarchy_src" ]; then
  BAT_CAP_L="$(get_kv "$_hierarchy_src" BATTERY_CPU_CAP_LITTLE)"
  BAL_CAP_L="$(get_kv "$_hierarchy_src" BALANCED_CPU_CAP_LITTLE)"
  PER_CAP_L="$(get_kv "$_hierarchy_src" PERFORMANCE_CPU_CAP_LITTLE)"
  BAT_CAP_B="$(get_kv "$_hierarchy_src" BATTERY_CPU_CAP_BIG)"
  BAL_CAP_B="$(get_kv "$_hierarchy_src" BALANCED_CPU_CAP_BIG)"
  PER_CAP_B="$(get_kv "$_hierarchy_src" PERFORMANCE_CPU_CAP_BIG)"
else
  BAT_CAP_L="$(get_kv "$MODDIR/profiles/battery.sh" CPU_CAP_LITTLE)"
  BAL_CAP_L="$(get_kv "$MODDIR/profiles/balanced.sh" CPU_CAP_LITTLE)"
  PER_CAP_L="$(get_kv "$MODDIR/profiles/performance.sh" CPU_CAP_LITTLE)"
  BAT_CAP_B="$(get_kv "$MODDIR/profiles/battery.sh" CPU_CAP_BIG)"
  BAL_CAP_B="$(get_kv "$MODDIR/profiles/balanced.sh" CPU_CAP_BIG)"
  PER_CAP_B="$(get_kv "$MODDIR/profiles/performance.sh" CPU_CAP_BIG)"
fi
if [ -n "$BAT_CAP_L" ] && [ -n "$BAL_CAP_L" ] && [ -n "$PER_CAP_L" ]; then
  if num_le "$BAT_CAP_L" "$BAL_CAP_L" && num_le "$BAL_CAP_L" "$PER_CAP_L"; then
    ok "little-cluster caps: battery ≤ balanced ≤ performance"
  else
    warn "little-cluster hierarchy broken: bat=$BAT_CAP_L bal=$BAL_CAP_L perf=$PER_CAP_L"
  fi
fi
if [ -n "$BAT_CAP_B" ] && [ -n "$BAL_CAP_B" ] && [ -n "$PER_CAP_B" ]; then
  if num_le "$BAT_CAP_B" "$BAL_CAP_B" && num_le "$BAL_CAP_B" "$PER_CAP_B"; then
    ok "big-cluster caps: battery ≤ balanced ≤ performance"
  else
    warn "big-cluster hierarchy broken: bat=$BAT_CAP_B bal=$BAL_CAP_B perf=$PER_CAP_B"
  fi
fi

echo
echo "💾 Runtime Files"
for pf in pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  fp="$MODDIR/runtime/$pf"
  [ -f "$fp" ] || continue
  case "$pf" in
    *.json)  validate_json "$fp" ;;
    *.jsonl)
      if [ -z "$PYTHON_BIN" ]; then
        warn "python3 not found, skipped JSONL validation for $pf"
      elif "$PYTHON_BIN" -c "import json,sys; [json.loads(l) for l in open('$fp', encoding='utf-8') if l.strip().startswith('{')]" 2>/dev/null; then
        ok "$pf: valid JSONL"
      else
        err "$pf: invalid JSONL"
      fi
      ;;
  esac
done

echo
echo "🔧 Features"
FEAT="$MODDIR/features.conf"
KNOWN_FEATURES="AUDIO BT CAMERA CPU VM NET WIFI GPS KERNEL LOG RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY SOTER_REPAIR"
# V44: features explicitly declared as RESERVED (no runtime path yet)
RESERVED_FEATURES="RADIO_IMS DISPLAY FPS SECURITY"
if [ -f "$FEAT" ]; then
  F_DUPES="$(awk -F= '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {k=$1; gsub(/[[:space:]]+$/, "", k); print k}' "$FEAT" | sort | uniq -d)"
  [ -n "$F_DUPES" ] && warn "duplicate feature keys: $F_DUPES" || ok "no duplicate feature keys"
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    case "$key" in ''|\#*) continue ;; esac
    key="$(echo "$key" | tr -d '[:space:]')"
    # V44: strip inline # comments and surrounding whitespace from value
    val="$(echo "$val" | sed 's/#.*$//' | tr -d '[:space:]')"
    case " $KNOWN_FEATURES " in
      *" $key "*) : ;;
      *) warn "unknown feature key: $key" ;;
    esac
    case "$val" in 0|1) : ;; *) warn "features.conf: $key=$val (expected 0 or 1)" ;; esac
  done < "$FEAT"
  # V44: check RESERVED features and warn (not err) if declared
  for _rf in $RESERVED_FEATURES; do
    if grep -qE "^${_rf}=" "$FEAT" 2>/dev/null; then
      warn "feature $_rf is RESERVED (declared but no runtime code yet)"
    fi
  done
  ok "features.conf parsed"
else
  err "features.conf missing"
fi

echo
echo "🩺 V44 — Operational Health"
# Check 1: common/profile_core.sh must NOT exist (V44 deduped — only runtime/ remains)
if [ -f "$MODDIR/common/profile_core.sh" ]; then
  err "common/profile_core.sh present — V44 expects only runtime/profile_core.sh (V27-class regression risk)"
elif [ ! -f "$MODDIR/runtime/profile_core.sh" ]; then
  err "runtime/profile_core.sh missing"
else
  ok "profile_core.sh: only runtime/ copy (V44 deduplication enforced)"
fi

# Check 2: baseline helper must exist (V44 restore safety net)
if [ -f "$MODDIR/runtime/asb_baseline.sh" ]; then
  ok "runtime/asb_baseline.sh present (restore path enabled)"
else
  warn "runtime/asb_baseline.sh missing — persistent settings will not be restored on uninstall"
fi

# Check 3: BG_TRIM_LEVEL must be safe or aggressive
if [ -f "$MODDIR/config/governor.conf.shipped" ]; then
  _bgl="$(grep -E "^BG_TRIM_LEVEL=" "$MODDIR/config/governor.conf.shipped" 2>/dev/null | tail -1 | cut -d= -f2)"
  case "$_bgl" in
    safe|aggressive) ok "BG_TRIM_LEVEL=$_bgl (valid)" ;;
    "") warn "BG_TRIM_LEVEL not set in shipped config (will default to safe at runtime)" ;;
    *) err "BG_TRIM_LEVEL=$_bgl (must be safe or aggressive)" ;;
  esac
fi

# Check 4: KERNEL block must not contain audio props (V44 fix for Chinese OnePlus 15)
if [ -f "$MODDIR/system.prop" ]; then
  _kern_audio="$(sed -n '/# ASB:KERNEL:BEGIN/,/# ASB:KERNEL:END/p' "$MODDIR/system.prop" | grep -cE "^(persist\.|ro\.|vendor\.).*audio|^(persist\.|ro\.|vendor\.).*dts|^(persist\.|ro\.|vendor\.).*dolby")"
  if [ "$_kern_audio" -gt 0 ]; then
    err "system.prop ASB:KERNEL block contains $_kern_audio audio props (V44 regression — moved to docs/removed_audio_props_v44.txt)"
  else
    ok "system.prop KERNEL block free of audio overrides"
  fi
fi

# Check 5: Soter loop must be opt-in (SOTER_REPAIR=0 default)
if grep -qE "^SOTER_REPAIR=" "$MODDIR/features.conf" 2>/dev/null; then
  _sv="$(grep -E "^SOTER_REPAIR=" "$MODDIR/features.conf" | tail -1 | sed 's/SOTER_REPAIR=//;s/#.*//;s/[[:space:]]//g')"
  if [ "$_sv" = "0" ]; then
    ok "SOTER_REPAIR=0 (opt-in, default off)"
  elif [ "$_sv" = "1" ]; then
    warn "SOTER_REPAIR=1 — Soter repair runs on every boot"
  fi
fi

# Check 6: pm clear in Soter loop must NOT be present (V44 — destructive, removed)
if [ -f "$MODDIR/service.sh" ]; then
  # Exclude comments — grep for pm clear NOT preceded by '#'
  if grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -qE "pm clear com\.tencent\.soter\.soterserver"; then
    err "service.sh contains destructive 'pm clear com.tencent.soter.soterserver' (V44 fix — should be removed)"
  else
    ok "Soter loop free of pm clear (V44 safe)"
  fi
fi

# V45 check: Athena/COSA persist setprops must not be in service.sh non-comment lines
# Reason: setting persist.sys.oplus.athena.reclaim_enable=1 on OnePlus Ace 5
# (SM8635, OxygenOS 16) caused system_server deadlock with CachedAppOptimizer.
if [ -f "$MODDIR/service.sh" ]; then
  _athena_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "(asb_persist_safe|setprop)[[:space:]]+persist\\.sys\\.oplus\\.(athena|deepthinker)" 2>/dev/null)"
  if [ "$_athena_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh writes $_athena_writes Athena/deepthinker persist props (V45 regression — causes deadlock on OnePlus Ace 5)"
  else
    ok "Athena/COSA persist props not written (V45 safe)"
  fi
fi

# V45 check: matrix.limiter.enable=false and ro.audio.audiozoom=true must
# not be in service.sh or system.prop non-comment lines.
# Reason: both cause stereo widening / center channel weakness (user-reported).
if [ -f "$MODDIR/service.sh" ]; then
  _widening_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "(matrix\\.limiter\\.enable[[:space:]]+false|audiozoom[[:space:]]+true)" 2>/dev/null)"
  if [ "$_widening_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh writes $_widening_writes stereo-widening props (V45 regression — causes side-bias/weak center)"
  else
    ok "Stereo-widening props not written (V45 safe)"
  fi
fi
if [ -f "$MODDIR/system.prop" ]; then
  _widening_sysprop="$(grep -vE "^[[:space:]]*#" "$MODDIR/system.prop" | grep -cE "^(audio\\.matrix\\.limiter\\.enable=false|vendor\\.audio\\.matrix\\.limiter\\.enable=false|ro\\.audio\\.audiozoom=true)" 2>/dev/null)"
  if [ "$_widening_sysprop" -gt 0 ] 2>/dev/null; then
    err "system.prop has $_widening_sysprop stereo-widening defaults (V45 regression)"
  else
    ok "system.prop free of stereo-widening defaults (V45 safe)"
  fi
fi

# V46 check: vm.oom_kill_allocating_task=1 must not be written anywhere
# in service.sh. This setting caused false-positive OOM kills of legitimately
# allocating apps (App Market, WhatsApp) on V44/V45 under battery profile
# memory pressure (swappiness=200 + minfree=112MB).
if [ -f "$MODDIR/service.sh" ]; then
  _oom_writes="$(grep -vE "^[[:space:]]*#" "$MODDIR/service.sh" | grep -cE "sysctlw[[:space:]]+vm\\.oom_kill_allocating_task[[:space:]]+1|echo[[:space:]]+1[[:space:]]*>.*oom_kill_allocating_task" 2>/dev/null)"
  if [ "$_oom_writes" -gt 0 ] 2>/dev/null; then
    err "service.sh sets vm.oom_kill_allocating_task=1 ($_oom_writes occurrences) — V46 regression, causes false-positive OOM kills"
  else
    ok "vm.oom_kill_allocating_task not forced to 1 (V46 safe)"
  fi
fi

# V46 check: battery profile VM_SWAPPINESS must not exceed 175. V44/V45 had
# 200 (kernel default is 60) which combined with oom_kill_allocating_task=1
# caused app kills under normal memory pressure. 175 is the safe ceiling.
if [ -f "$MODDIR/profiles/battery.sh" ]; then
  _swap_bat="$(grep -E "^VM_SWAPPINESS=" "$MODDIR/profiles/battery.sh" | cut -d= -f2)"
  if [ -n "$_swap_bat" ] && [ "$_swap_bat" -gt 175 ] 2>/dev/null; then
    err "battery profile VM_SWAPPINESS=$_swap_bat exceeds safe ceiling 175 (V46 regression — causes app kills under memory pressure)"
  else
    ok "battery profile VM_SWAPPINESS=$_swap_bat within safe range (V46)"
  fi
fi

if [ -f "$MODDIR/src/asb_governor.c" ]; then
  if grep -qE "^#define BAT_TRUST_NOISY[[:space:]]" "$MODDIR/src/asb_governor.c"; then
    ok "BAT_TRUST_NOISY constant present (V47 active)"
  else
    err "BAT_TRUST_NOISY constant missing from asb_governor.c (V47 regression)"
  fi
  _intent_names_count="$(grep -E "^static const char \*intent_names\[\]" "$MODDIR/src/asb_governor.c" | grep -oE '"[^"]+"' | wc -l)"
  if [ "$_intent_names_count" = "7" ]; then
    ok "intent_names[] has 7 entries (V47 IDLE_WARM present)"
  else
    err "intent_names[] has $_intent_names_count entries (V47 expects 7 including idle_warm)"
  fi
  if grep -qE "asb_log_critical|asb_log_persist" "$MODDIR/src/asb_governor.c"; then
    ok "persistent log mirror present (V47)"
  else
    err "persistent log mirror missing (V47 regression)"
  fi
fi

echo
echo "🏗  Bounds Source-of-Truth (V42)"
_bc="$MODDIR/config/profile_bounds.conf"
_bsh="$MODDIR/config/profile_bounds.generated.sh"
_bh="$MODDIR/src/asb_fsm_bounds.generated.h"
_gen="$MODDIR/tools/gen_bounds.sh"
if [ -f "$_bc" ] && [ -f "$_bsh" ] && [ -f "$_bh" ] && [ -f "$_gen" ]; then
  if [ "$_bc" -nt "$_bsh" ] || [ "$_bc" -nt "$_bh" ]; then
    warn "profile_bounds.conf newer than generated files — run tools/gen_bounds.sh"
  else
    ok "generated bounds files newer than source"
  fi
  if [ -x "$_gen" ] || [ -r "$_gen" ]; then
    _tmp_sh="$(mktemp 2>/dev/null || echo "/tmp/asb_lint_sh.$$")"
    _tmp_h="$(mktemp 2>/dev/null || echo "/tmp/asb_lint_h.$$")"
    _cur_sh_md5="$(md5sum "$_bsh" 2>/dev/null | awk '{print $1}')"
    _cur_h_md5="$(md5sum "$_bh"  2>/dev/null | awk '{print $1}')"
    _backup_sh="$(cat "$_bsh" 2>/dev/null)"
    _backup_h="$(cat "$_bh"  2>/dev/null)"
    if bash "$_gen" >/dev/null 2>&1; then
      _new_sh_md5="$(md5sum "$_bsh" 2>/dev/null | awk '{print $1}')"
      _new_h_md5="$(md5sum "$_bh"  2>/dev/null | awk '{print $1}')"
      if [ "$_cur_sh_md5" = "$_new_sh_md5" ] && [ "$_cur_h_md5" = "$_new_h_md5" ]; then
        ok "regeneration produces identical output (no drift)"
      else
        err "regeneration would change files — generated bounds are STALE"
        printf '%s\n' "$_backup_sh" > "$_bsh" 2>/dev/null
        printf '%s\n' "$_backup_h"  > "$_bh"  2>/dev/null
      fi
    else
      err "gen_bounds.sh exited non-zero (invariant violation in profile_bounds.conf)"
    fi
    rm -f "$_tmp_sh" "$_tmp_h" 2>/dev/null
  fi

  for P in BATTERY BALANCED PERFORMANCE; do
    _shc_min_l="$(grep -E "^${P}_CPU_MIN_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _shc_max_l="$(grep -E "^${P}_CPU_MAX_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _shc_cap_l="$(grep -E "^${P}_CPU_CAP_LITTLE=" "$_bsh" 2>/dev/null | cut -d= -f2)"
    _chc_floor_max_l="$(grep -E "^#define ASB_${P}_FLOOR_CPU_MAX_LITTLE" "$_bh" 2>/dev/null | awk '{print $3}')"
    _chc_ceil_max_l="$(grep -E "^#define ASB_${P}_CEIL_CPU_MAX_LITTLE"  "$_bh" 2>/dev/null | awk '{print $3}')"
    _chc_floor_min_l="$(grep -E "^#define ASB_${P}_FLOOR_CPU_MIN_LITTLE" "$_bh" 2>/dev/null | awk '{print $3}')"
    if [ -n "$_shc_cap_l" ] && [ -n "$_chc_floor_max_l" ] && [ "$_shc_cap_l" = "$_chc_floor_max_l" ]; then
      :
    else
      err "${P}: CPU_CAP_LITTLE shell=$_shc_cap_l vs C FLOOR_CPU_MAX_LITTLE=$_chc_floor_max_l (must match)"
    fi
    if [ -n "$_shc_max_l" ] && [ -n "$_chc_ceil_max_l" ] && [ "$_shc_max_l" = "$_chc_ceil_max_l" ]; then
      :
    else
      err "${P}: CPU_MAX_LITTLE shell=$_shc_max_l vs C CEIL_CPU_MAX_LITTLE=$_chc_ceil_max_l (must match)"
    fi
    if [ -n "$_shc_min_l" ] && [ -n "$_chc_floor_min_l" ] && [ "$_shc_min_l" = "$_chc_floor_min_l" ]; then
      :
    else
      err "${P}: CPU_MIN_LITTLE shell=$_shc_min_l vs C FLOOR_CPU_MIN_LITTLE=$_chc_floor_min_l (must match)"
    fi
  done
  ok "shell↔C bounds parity checked (BATTERY/BALANCED/PERFORMANCE)"
elif [ -f "$_bsh" ] && [ ! -f "$_bc" ] && [ ! -f "$_gen" ]; then
  if grep -qE "^BATTERY_CPU_MIN_LITTLE=[0-9]+" "$_bsh" && \
     grep -qE "^BALANCED_CPU_MIN_LITTLE=[0-9]+" "$_bsh" && \
     grep -qE "^PERFORMANCE_CPU_MIN_LITTLE=[0-9]+" "$_bsh"; then
    ok "profile_bounds.generated.sh present and well-formed (release deployment)"
  else
    err "profile_bounds.generated.sh malformed (missing per-profile keys)"
  fi
else
  if [ ! -f "$_bc" ] && [ ! -f "$_bsh" ]; then
    warn "no bounds source-of-truth files found — older module version?"
  elif [ ! -f "$_bsh" ] || [ ! -f "$_bh" ]; then
    err "generated bounds files missing — run tools/gen_bounds.sh"
  fi
fi

echo
echo "📋 Version Sync"
_mp="$MODDIR/module.prop"
_uj="$MODDIR/update.json"
_cl="$MODDIR/CHANGELOG.md"
if [ -f "$_mp" ] && [ -f "$_uj" ]; then
  _mp_ver="$(grep '^version=' "$_mp" | head -1 | cut -d= -f2)"
  _mp_code="$(grep '^versionCode=' "$_mp" | head -1 | cut -d= -f2)"
  _uj_ver=""
  _uj_code=""
  if [ -n "$PYTHON_BIN" ]; then
    _uj_ver="$("$PYTHON_BIN" -c "import json; print(json.load(open('$_uj'))['version'])" 2>/dev/null)"
    _uj_code="$("$PYTHON_BIN" -c "import json; print(json.load(open('$_uj'))['versionCode'])" 2>/dev/null)"
  else
    _uj_ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$_uj" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
    _uj_code="$(grep -oE '"versionCode"[[:space:]]*:[[:space:]]*[0-9]+' "$_uj" | head -1 | grep -oE '[0-9]+')"
  fi
  if [ -n "$_mp_ver" ] && [ -n "$_uj_ver" ] && [ "$_mp_ver" = "$_uj_ver" ]; then
    ok "module.prop:version == update.json:version ($_mp_ver)"
  else
    err "version mismatch: module.prop=$_mp_ver update.json=$_uj_ver"
  fi
  if [ -n "$_mp_code" ] && [ -n "$_uj_code" ] && [ "$_mp_code" = "$_uj_code" ]; then
    ok "module.prop:versionCode == update.json:versionCode ($_mp_code)"
  else
    err "versionCode mismatch: module.prop=$_mp_code update.json=$_uj_code"
  fi
  if [ -f "$_cl" ] && [ -n "$_mp_ver" ]; then
    if grep -qE "^# .*${_mp_ver}|^## .*${_mp_ver}" "$_cl" 2>/dev/null; then
      ok "CHANGELOG.md mentions $_mp_ver"
    else
      warn "CHANGELOG.md has no section heading for $_mp_ver"
    fi
  fi
  _ws="$MODDIR/webroot/index.html"
  if [ -f "$_ws" ] && [ -n "$_mp_ver" ]; then
    if grep -q "verBadge\"[^>]*>${_mp_ver}<" "$_ws" 2>/dev/null; then
      ok "WebUI badge matches $_mp_ver"
    else
      warn "WebUI verBadge does not match module.prop:version=$_mp_ver"
    fi
  fi
  _ac="$MODDIR/action.sh"
  if [ -f "$_ac" ] && [ -n "$_mp_ver" ]; then
    if grep -qE "(AutoSystemBoost|ASB)\s+${_mp_ver}\b" "$_ac" 2>/dev/null; then
      ok "action.sh banner matches $_mp_ver"
    else
      warn "action.sh banner does not match module.prop:version=$_mp_ver"
    fi
  fi
else
  warn "module.prop or update.json missing, skipped version sync check"
fi

_ss="$MODDIR/service.sh"
_is="$MODDIR/common/install.sh"
if [ -f "$_ss" ]; then
  _exp_schema="$(grep -oE '_expected_schema=[0-9]+' "$_ss" | head -1 | grep -oE '[0-9]+')"
  _bm_schema=""
  if [ -f "$_is" ]; then
    _bm_schema="$(grep -A1 'build_manifest.json' "$_is" 2>/dev/null | grep -oE 'schema_version"?:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')"
    [ -z "$_bm_schema" ] && _bm_schema="$(grep -oE 'schema_version":[[:space:]]*[0-9]+' "$_is" | head -1 | grep -oE '[0-9]+')"
  fi
  if [ -n "$_exp_schema" ] && [ -n "$_bm_schema" ] && [ "$_exp_schema" = "$_bm_schema" ]; then
    ok "service.sh:_expected_schema == install.sh:build_manifest schema_version ($_exp_schema)"
  elif [ -n "$_exp_schema" ] && [ -n "$_bm_schema" ]; then
    err "schema mismatch: service.sh=$_exp_schema build_manifest=$_bm_schema"
  fi
fi

echo
echo "═══════════════════════════════"
echo "  Lint: ❌ $ERRORS errors  ⚠️  $WARNS warnings"
[ $ERRORS -eq 0 ] && echo "  Config: CLEAN" || echo "  Config: FIX REQUIRED"
echo "═══════════════════════════════"
