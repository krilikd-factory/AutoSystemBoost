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
RTDIR="$MODDIR/runtime"
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
warn() { WARN=$((WARN+1)); echo "  ⚠️  $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

find_python() {
  for p in "${PYTHON3:-}" python3 /data/data/com.termux/files/usr/bin/python3; do
    [ -n "$p" ] || continue
    command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
PYTHON_BIN="$(find_python 2>/dev/null || true)"
validate_json() {
  _f="$1"
  [ -z "$PYTHON_BIN" ] && return 2
  "$PYTHON_BIN" -c "import json; json.load(open('$_f', encoding='utf-8'))" >/dev/null 2>&1
}

last_perf_unfinalized() {
  _hist="$1"
  [ -f "$_hist" ] || return 1
  [ -z "$PYTHON_BIN" ] && return 2
  "$PYTHON_BIN" - <<PY >/dev/null 2>&1
import json
path = r'''$_hist'''
last = None
with open(path, encoding='utf-8') as f:
    for line in f:
        line=line.strip()
        if line.startswith('{'):
            last=json.loads(line)
if last and last.get('profile')=='performance' and last.get('end','') not in ('profile_change','idle_boundary','shutdown','manual_end','new_session','stale_recovered'):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

benchmark_isolation_status() {
  _src="$MODDIR/src/asb_governor.c"
  [ -f "$_src" ] || return 2
  grep -q 'benchmark session, skipping per-profile memory update' "$_src" || return 1
  grep -q 'ses_intent != INTENT_BENCHMARK' "$_src" || return 1
  grep -q 'learn_exempt' "$_src" || return 1
  return 0
}

IS_SOURCE=0
IS_INSTALLED=0
if [ -f "$MODDIR/src/asb_governor.c" ] && [ ! -x "$MODDIR/bin/asb" ]; then
  IS_SOURCE=1
elif [ -x "$MODDIR/bin/asb" ]; then
  IS_INSTALLED=1
elif [ -d "/dev/.asb" ]; then
  IS_INSTALLED=1
fi

echo "═══════════════════════════════════════"
echo "  ASB Doctor — Module Health Check"
echo "═══════════════════════════════════════"
echo "  Module dir: $MODDIR"
if [ $IS_SOURCE -eq 1 ]; then
  echo "  Context: SOURCE TREE (binary not compiled)"
elif [ $IS_INSTALLED -eq 1 ]; then
  echo "  Context: INSTALLED MODULE"
else
  echo "  Context: UNKNOWN"
fi
echo

echo "🔧 Binary"
GOV_BIN="$MODDIR/bin/asb"
if [ -x "$GOV_BIN" ]; then
  ok "governor binary exists ($GOV_BIN)"
elif [ $IS_SOURCE -eq 1 ]; then
  ok "source tree detected (binary built via GitHub Actions, not expected here)"
else
  warn "governor binary not found at $GOV_BIN (shell fallback mode)"
fi
PID=""
if [ -f /dev/.asb/governor.pid ]; then
  _pid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    PID="$_pid"
  fi
fi
[ -z "$PID" ] && PID="$(pidof asb 2>/dev/null)"
if [ -n "$PID" ]; then
  ok "governor running (pid $PID)"
elif [ $IS_SOURCE -eq 1 ]; then
  ok "governor not expected to run in source tree context"
elif [ -f /dev/.asb/safe_mode ]; then
  warn "governor not running (safe mode active)"
else
  warn "governor not running"
fi

echo
echo "📋 Profiles"
for p in battery balanced performance; do
  f="$MODDIR/profiles/${p}.sh"
  if [ ! -f "$f" ]; then
    fail "$p.sh missing"
    continue
  fi
  if sh -n "$f" 2>/dev/null && grep -q '^PROFILE=' "$f"; then
    ok "$p.sh valid"
  else
    fail "$p.sh syntax invalid or PROFILE missing"
  fi
done

echo
echo "💾 Runtime"
if [ $IS_SOURCE -eq 1 ]; then
  if [ -d "$RTDIR" ]; then
    ok "runtime/ directory present (source tree)"
  else
    ok "runtime/ not required in source tree"
  fi
else
  if [ -d "$RTDIR" ] && [ -w "$RTDIR" ]; then
    _touch="$RTDIR/.doctor.$$"
    if : > "$_touch" 2>/dev/null; then
      rm -f "$_touch"
      ok "runtime/ directory writable"
    else
      fail "runtime/ not writable"
    fi
  else
    fail "runtime/ missing or not writable"
  fi
fi
for pf in pstats_battery.json pstats_balanced.json pstats_performance.json; do
  fp="$RTDIR/$pf"
  if [ -f "$fp" ]; then
    if validate_json "$fp"; then
      ok "$pf valid JSON"
    elif [ $? -eq 2 ]; then
      warn "python3 not found, skipped JSON validation for $pf"
    else
      fail "$pf corrupted JSON"
    fi
  elif [ $IS_INSTALLED -eq 1 ]; then
    warn "$pf not found (will be created on first session)"
  fi
done
HIST="/data/adb/asb/session_history.jsonl"
[ ! -f "$HIST" ] && HIST="$RTDIR/session_history.jsonl"
if [ -f "$HIST" ]; then
  LINES="$(wc -l < "$HIST" 2>/dev/null | tr -d ' ')"
  SIZE_KB="$(du -k "$HIST" 2>/dev/null | awk '{print $1}')"
  ok "session_history.jsonl (${LINES:-0} entries, ${SIZE_KB:-0} KB, $HIST)"
  if last_perf_unfinalized "$HIST"; then
    warn "last performance session may not be finalized"
  fi
elif [ $IS_INSTALLED -eq 1 ]; then
  warn "session_history.jsonl not found"
fi

echo
echo "⚙️  Config"
CONF="$MODDIR/config/governor.conf"
if [ -f "$CONF" ]; then
  ok "governor.conf exists"
  DUPES="$(awk -F= '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if (k != "") print k}' "$CONF" | sort | uniq -d)"
  [ -z "$DUPES" ] && ok "no duplicate keys" || warn "duplicate keys: $DUPES"
else
  fail "governor.conf missing"
fi
FEAT="$MODDIR/features.conf"
[ -f "$FEAT" ] && ok "features.conf exists" || fail "features.conf missing"

if [ $IS_INSTALLED -eq 1 ]; then
  echo
  echo "🔌 sysfs Paths"
  for path in \
    /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq \
    /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq \
    /sys/class/kgsl/kgsl-3d0/devfreq/max_freq; do
    if [ -e "$path" ]; then
      [ -w "$path" ] && ok "$path writable" || warn "$path not writable"
    else
      warn "$path not found"
    fi
  done
fi

echo
echo "📦 Build"
MANIFEST="$RTDIR/build_manifest.json"
[ -f "$MANIFEST" ] && ok "build_manifest.json present" || warn "build_manifest.json missing"
VERSION="$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
[ -n "$VERSION" ] && ok "module version: $VERSION" || warn "version missing in module.prop"

echo
echo "🎯 Benchmark Isolation"
if benchmark_isolation_status; then
  ok "benchmark isolation detected in governor source"
elif [ $? -eq 2 ]; then
  [ $IS_INSTALLED -eq 1 ] && ok "source not bundled (expected for installed module)" \
                           || warn "cannot verify (source missing)"
else
  warn "benchmark isolation patterns not fully detected"
fi

if [ $IS_INSTALLED -eq 1 ]; then
  echo
  echo "🔍 Conflict Scan"
  CONFLICTS=""
  for m in /data/adb/modules/*/ /data/adb/ksu/modules/*/; do
    [ -d "$m" ] || continue
    [ "$(basename "$m")" = "$MODID" ] && continue
    [ -f "$m/disable" ] && continue
    [ ! -f "${m}module.prop" ] && continue
    MNAME="$(grep '^name=' "${m}module.prop" 2>/dev/null | cut -d= -f2)"
    [ -z "$MNAME" ] && MNAME="$(basename "$m")"
    if grep -qE 'scaling_max_freq|cpufreq|schedutil|msm_performance|thermal' "${m}service.sh" 2>/dev/null || \
       grep -qEi 'cpu|sched|freq|governor|thermal' "${m}system.prop" 2>/dev/null; then
      CONFLICTS="$CONFLICTS $MNAME"
    fi
  done
  [ -z "$CONFLICTS" ] && ok "no conflicting modules detected" || warn "potential conflicts:$CONFLICTS"
fi

echo
echo "📝 Logs"
GOVLOG="/dev/.asb/governor.log"
if [ -f "$GOVLOG" ]; then
  LOGSZ="$(wc -c < "$GOVLOG" 2>/dev/null | tr -d ' ')"
  ok "governor.log $(( ${LOGSZ:-0} / 1024 ))KB"
elif [ $IS_SOURCE -eq 1 ]; then
  ok "governor.log not expected in source tree"
else
  warn "governor.log not found"
fi
STATEF="/dev/.asb/state"
if [ -f "$STATEF" ]; then
  ok "state file present"
  PROF="$(grep '^profile=' "$STATEF" 2>/dev/null | cut -d= -f2)"
  STATE="$(grep '^state=' "$STATEF" 2>/dev/null | cut -d= -f2)"
  QUAR="$(grep '^quarantine=' "$STATEF" 2>/dev/null | cut -d= -f2)"
  PCLASS="$(grep '^plan_class=' "$STATEF" 2>/dev/null | cut -d= -f2)"
  echo "       profile=$PROF state=$STATE quarantine=$QUAR plan_class=$PCLASS"
elif [ $IS_SOURCE -eq 1 ]; then
  ok "state file not expected in source tree"
else
  warn "state file not found"
fi
[ -f /dev/.asb/safe_mode ] && warn "safe_mode flag present"

echo
echo "🌡  Thermal Sensors (type-resolved)"
THERMAL_BASE="/sys/class/thermal"
if [ -d "$THERMAL_BASE" ]; then
  TZ_FOUND=0
  for sensor in socd cpu-1-1-0 cpu-0-5-0 cpullc-0-0 shell_front shell_frame shell_back sys-therm-6 board_temp; do
    ZONE=""
    for tz in "$THERMAL_BASE"/thermal_zone*; do
      [ -r "$tz/type" ] || continue
      t="$(cat "$tz/type" 2>/dev/null | tr -d '\n\r')"
      [ "$t" = "$sensor" ] || continue
      ZONE="$(basename "$tz" | sed 's/thermal_zone//')"
      break
    done
    if [ -n "$ZONE" ]; then
      RAW="$(cat "$THERMAL_BASE/thermal_zone$ZONE/temp" 2>/dev/null)"
      [ -z "$RAW" ] && RAW=0
      if [ "$RAW" -gt 200 ] 2>/dev/null; then
        C=$(( RAW / 1000 ))
      else
        C=$RAW
      fi
      printf "  %-18s zone%-3s = %sC (raw=%s)\n" "$sensor" "$ZONE" "$C" "$RAW"
      TZ_FOUND=$((TZ_FOUND+1))
    fi
  done
  if [ $TZ_FOUND -eq 0 ]; then
    warn "no recognised thermal zones found"
  else
    ok "$TZ_FOUND thermal sensor(s) discovered by type"
  fi
else
  warn "$THERMAL_BASE not accessible"
fi

echo
echo "═══════════════════════════════════════"
echo "  Results: ✅ $PASS passed  ⚠️  $WARN warnings  ❌ $FAIL failures"
if [ $FAIL -gt 0 ]; then
  echo "  Status: UNHEALTHY"
elif [ $IS_SOURCE -eq 1 ]; then
  echo "  Status: SOURCE_TREE"
elif [ $WARN -gt 4 ]; then
  echo "  Status: DEGRADED"
else
  echo "  Status: HEALTHY"
fi
echo "═══════════════════════════════════════"
