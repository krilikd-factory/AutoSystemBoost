#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"

PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"

_lvl=$(dumpsys battery 2>/dev/null | grep -m1 ' level:' | awk '{print $2}')
_btemp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
_cap_uah=$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null)

_cputemp=0
for z in /sys/class/thermal/thermal_zone*/; do
  tp=$(cat "${z}type" 2>/dev/null)
  case "$tp" in
    cpu-1-1-0|cpu0-silver-usr|cpuss-2-usr|cpu-0-0-0)
      tv=$(cat "${z}temp" 2>/dev/null)
      [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null && _cputemp=$((tv / 1000)) && break
      ;;
  esac
done
if [ "$_cputemp" -eq 0 ]; then
  for z in /sys/class/thermal/thermal_zone*/; do
    tp=$(cat "${z}type" 2>/dev/null)
    case "$tp" in
      *cpu*)
        tv=$(cat "${z}temp" 2>/dev/null)
        if [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null; then
          dc=$((tv / 1000))
          [ "$dc" -gt "$_cputemp" ] && _cputemp=$dc
        fi
        ;;
    esac
  done
fi

if [ -n "$_btemp" ] && [ "$_btemp" -gt 0 ] 2>/dev/null; then
  _btempC=$((_btemp / 10))
  _btempCx=$((_btemp % 10))
else
  _btempC=0
  _btempCx=0
fi

_state_mA=$(grep -oE '"current_now":[-0-9]+' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)
if [ -n "$_state_mA" ] && [ "$_state_mA" -ne 0 ] 2>/dev/null; then
  _real_mA_abs=$(( _state_mA < 0 ? -_state_mA : _state_mA ))
  _on_ma=$_real_mA_abs
  _off_ma=$(( _real_mA_abs / 8 ))
  _eta_note="(measured)"
else
  case "$PROFILE" in
    performance) _on_ma=650;  _off_ma=85  ;;
    battery)     _on_ma=400;  _off_ma=45  ;;
    *)           _on_ma=500;  _off_ma=60  ;;
  esac
  _eta_note="(heuristic)"
fi

_remain_mah=0
if [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null && [ -n "$_lvl" ]; then
  _remain_mah=$(( (_cap_uah / 1000) * _lvl / 100 ))
fi

_ton_h=0
_ton_m=0
_toff_h=0
_toff_m=0
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_on_ma" -gt 0 ] 2>/dev/null; then
  _ton_min=$(( _remain_mah * 60 / _on_ma ))
  _ton_h=$(( _ton_min / 60 ))
  _ton_m=$(( _ton_min % 60 ))
fi
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_off_ma" -gt 0 ] 2>/dev/null; then
  _toff_min=$(( _remain_mah * 60 / _off_ma ))
  _toff_h=$(( _toff_min / 60 ))
  _toff_m=$(( _toff_min % 60 ))
fi

_auto_bat=$(grep -oE '"auto_bat":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)
_qn_active=$(grep -oE '"qn_active":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)

_rec_count=0
_rec_disabled=0
_rec_reason=""
if [ -r /dev/.asb/recovery.json ]; then
  _rec_line=$(cat /dev/.asb/recovery.json 2>/dev/null)
  _rec_count=$(echo "$_rec_line" | sed -n 's/.*"recovery_count":\([0-9]*\).*/\1/p')
  _rec_disabled=$(echo "$_rec_line" | sed -n 's/.*"gov_disabled":\([0-9]*\).*/\1/p')
  _rec_reason=$(echo "$_rec_line" | sed -n 's/.*"last_recovery_reason":"\([^"]*\)".*/\1/p')
  case "$_rec_count" in ''|*[!0-9]*) _rec_count=0 ;; esac
  case "$_rec_disabled" in ''|*[!0-9]*) _rec_disabled=0 ;; esac
fi

echo ""
echo "  ASB V46 · ${PROFILE}"
if [ "$_rec_disabled" = "1" ]; then
  echo "  ⚠️  SAFE MODE  : governor disabled (${_rec_reason:-recovery})"
elif [ "$_rec_count" -gt 0 ] 2>/dev/null; then
  echo "  ⚠️  Recovery  : ${_rec_count} restart(s) — ${_rec_reason:-unknown}"
fi
echo ""
echo "  🌡  CPU      : ${_cputemp}°C"
if [ "$_btempC" -gt 0 ]; then
  echo "  🔋 Battery  : ${_btempC}.${_btempCx}°C   ${_lvl:-?}%"
else
  echo "  🔋 Battery  : ${_lvl:-?}%"
fi
[ "$_auto_bat" = "1" ] && echo "  🔻 Auto-battery active"
[ "$_qn_active" = "1" ] && echo "  🌙 Night-quiet active"
echo ""
echo "  Estimated time to 0%  $_eta_note:"
echo "    📱 screen on  : ~${_ton_h}h ${_ton_m}m"
echo "    💤 screen off : ~${_toff_h}h ${_toff_m}m"
echo ""
echo "  Opening Telegram channel..."

am start -a android.intent.action.VIEW -d "tg://resolve?domain=oneplusmod" >/dev/null 2>&1 \
  || am start -a android.intent.action.VIEW -d "https://t.me/oneplusmod" >/dev/null 2>&1

exit 0
