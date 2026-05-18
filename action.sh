#!/system/bin/sh
# AutoSystemBoost V43 — action.sh
# Triggered from Magisk/KSU module list "Action" button.
#
# V43: integrated diagnostics printout + WebUI launch.
# Output appears in the Magisk/KSU action window.

MODDIR="${MODDIR:-${0%/*}}"
MODID="AutoSystemBoost"

# ── First: integrated diag if user invoked from terminal/script with --diag
#    The Magisk UI ignores stdout when WebUI activity is launched, so we
#    print diag first, then attempt to open WebUI. If WebUI is missing,
#    diag stays visible in the action window.

PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"

# Update description in module.prop
case "$PROFILE" in
  performance) _desc='description=status: performance 🔥 | active ✅' ;;
  battery)     _desc='description=status: battery 🔋 | active ✅' ;;
  *)           _desc='description=status: balanced ⚖️ | active ✅' ;;
esac
sed "s/^description=.*/$_desc/" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null
if grep -q '^description=' "$MODDIR/module.prop.tmp" 2>/dev/null; then
  cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
fi
rm -f "$MODDIR/module.prop.tmp"

# ── Banner
echo "╔══════════════════════════════════════════════╗"
echo "║       AutoSystemBoost V43                    ║"
echo "║       $(date '+%Y-%m-%d %H:%M:%S')                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "- Current profile: $PROFILE"
echo ""

# ── Battery
echo "── BATTERY ───────────────────────────────────"
BAT_TEMP=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
BAT_LEVEL=$(dumpsys battery 2>/dev/null | grep -m1 ' level:' | awk '{print $2}')
BAT_STATUS=$(dumpsys battery 2>/dev/null | grep -m1 ' status:' | awk '{print $2}')
[ -n "$BAT_TEMP" ] && echo "  Temp     : $((BAT_TEMP / 10)).$((BAT_TEMP % 10))°C"
[ -n "$BAT_LEVEL" ] && echo "  Level    : ${BAT_LEVEL}%"
[ -n "$BAT_STATUS" ] && echo "  Status   : $BAT_STATUS  (2=charging 3=discharging 5=full)"
echo ""

# ── Hot thermal zones (only show >40°C to keep output short)
echo "── THERMAL (warm zones only) ─────────────────"
_any=0
for z in /sys/class/thermal/thermal_zone*/; do
  tp=$(cat "${z}type" 2>/dev/null)
  tv=$(cat "${z}temp" 2>/dev/null)
  if [ -n "$tv" ] && [ "$tv" -gt 40000 ] 2>/dev/null; then
    degC=$((tv / 1000))
    if [ "$degC" -ge 50 ]; then
      printf "  🔥 %-22s : %d°C\n" "$tp" "$degC"
    else
      printf "  ⚠️  %-22s : %d°C\n" "$tp" "$degC"
    fi
    _any=1
  fi
done
[ "$_any" -eq 0 ] && echo "  ✅ all zones cool (<40°C)"
echo ""

# ── CPU policies (Qcom/Oryon — policy0 little, policy6 big)
echo "── CPU FREQUENCIES ───────────────────────────"
for p in /sys/devices/system/cpu/cpufreq/policy*/; do
  pol=$(basename "$p")
  gov=$(cat "${p}scaling_governor" 2>/dev/null)
  cur=$(cat "${p}scaling_cur_freq" 2>/dev/null)
  maxf=$(cat "${p}scaling_max_freq" 2>/dev/null)
  if [ -n "$cur" ] && [ -n "$maxf" ]; then
    printf "  %-9s : gov=%-9s cur=%dMHz max=%dMHz\n" \
      "$pol" "$gov" "$((cur / 1000))" "$((maxf / 1000))"
  fi
done
echo ""

# ── GPU (Adreno on Qcom — kgsl path, NOT mali)
echo "── GPU (Adreno) ──────────────────────────────"
_kgsl=/sys/class/kgsl/kgsl-3d0
if [ -d "$_kgsl" ]; then
  _gov=$(cat "$_kgsl/devfreq/governor" 2>/dev/null)
  _cur=$(cat "$_kgsl/devfreq/cur_freq" 2>/dev/null)
  _max=$(cat "$_kgsl/devfreq/max_freq" 2>/dev/null)
  _busy=$(cat "$_kgsl/gpubusy" 2>/dev/null | awk '{print $1}')
  _bustot=$(cat "$_kgsl/gpubusy" 2>/dev/null | awk '{print $2}')
  [ -n "$_gov" ] && echo "  Governor : $_gov"
  [ -n "$_cur" ] && echo "  Cur Freq : $((_cur / 1000000)) MHz"
  [ -n "$_max" ] && echo "  Max Freq : $((_max / 1000000)) MHz"
  if [ -n "$_busy" ] && [ -n "$_bustot" ] && [ "$_bustot" -gt 0 ] 2>/dev/null; then
    echo "  Busy     : $((_busy * 100 / _bustot))%"
  fi
else
  echo "  kgsl-3d0 path not present"
fi
echo ""

# ── BG_TRIM status
echo "── ASB CATEGORIES ENABLED ────────────────────"
if [ -f "$MODDIR/features.conf" ]; then
  _bg=$(grep '^BG_TRIM=' "$MODDIR/features.conf" | cut -d= -f2)
  echo "  BG_TRIM    : $([ "$_bg" = "1" ] && echo 'ON ✅' || echo 'off')"
fi
echo ""

# ── Smart Reclaim status (if BG_TRIM is on)
if [ -f "$MODDIR/features.conf" ] && grep -q '^BG_TRIM=1' "$MODDIR/features.conf"; then
  echo "── SMART RECLAIM STATE ───────────────────────"
  echo "  athena.force_kill      : $(getprop persist.sys.oplus.athena.force_kill)"
  echo "  athena.reclaim_enable  : $(getprop persist.sys.oplus.athena.reclaim_enable)"
  echo "  athena.limit_count     : $(getprop persist.sys.oplus.athena.limit_count)"
  echo "  vm.compaction_proactive: $(cat /proc/sys/vm/compaction_proactiveness 2>/dev/null)"
  _lru=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)
  echo "  lru_gen.enabled        : ${_lru:-not present}"
  echo ""
fi

# ── Doze state (ensure stock)
echo "── DOZE STATE ────────────────────────────────"
_idle=$(dumpsys deviceidle 2>/dev/null | grep -m1 'mState=' | awk -F= '{print $2}' | awk '{print $1}')
_lidle=$(dumpsys deviceidle 2>/dev/null | grep -m1 'mLightState=' | awk -F= '{print $2}' | awk '{print $1}')
echo "  Deep idle  : ${_idle:-unknown}"
echo "  Light idle : ${_lidle:-unknown}"
_doze_const=$(settings get global device_idle_constants 2>/dev/null)
case "$_doze_const" in
  ''|null) echo "  Doze const : stock ✅" ;;
  *)       echo "  Doze const : custom (length ${#_doze_const})  ⚠️" ;;
esac
echo ""

# ── Custom OnePlus packages — quick health check
echo "── CRITICAL PACKAGES (should be enabled) ─────"
for p in com.oplus.customize.coreapp com.oplus.aimemory com.oplus.healthservice \
         com.oplus.trafficmonitor com.oplus.gameopt; do
  _disabled=$(pm list packages -d 2>/dev/null | grep -c "^package:${p}$")
  if [ "$_disabled" -gt 0 ]; then
    echo "  ⚠️  $p : DISABLED"
  else
    _inst=$(pm list packages 2>/dev/null | grep -c "^package:${p}$")
    if [ "$_inst" -gt 0 ]; then
      printf "  ✅ %s\n" "$p"
    else
      printf "  -- %s (not installed)\n" "$p"
    fi
  fi
done
echo ""

# ── Open WebUI if available
echo "── OPENING WEBUI ─────────────────────────────"
if [ -z "$MMRL" ] && [ ! -z "$MAGISKTMP" ]; then
  if pm path io.github.a13e300.ksuwebui > /dev/null 2>&1; then
    echo "  → KSUWebUI"
    am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "$MODID" 2>/dev/null
    exit 0
  fi
  if pm path com.dergoogler.mmrl.wx > /dev/null 2>&1; then
    echo "  → MMRL WebUI"
    am start -n "com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity" -e MOD_ID "$MODID" 2>/dev/null
    exit 0
  fi
  echo "  WebUI client not installed — install KSUWebUI or MMRL"
fi
echo ""

# ── Final hint
echo "╔══════════════════════════════════════════════╗"
echo "║  Tip: tap the Action button again to refresh ║"
echo "║  or open WebUI for full controls.            ║"
echo "╚══════════════════════════════════════════════╝"
