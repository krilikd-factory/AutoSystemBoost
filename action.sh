#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"

# Section headings in the device's language.
#
# This screen had no localisation at all - every heading was English regardless of the
# phone's locale, while the installer and the WebUI were translated. Headings only: the
# detail lines under them carry measured values and unit names, and translating those
# badly would make a diagnostic report misleading rather than merely foreign.
_asb_loc="$(settings get system system_locales 2>/dev/null)"
[ -z "$_asb_loc" ] || [ "$_asb_loc" = "null" ] && _asb_loc="$(getprop persist.sys.locale 2>/dev/null)"
case "$(printf '%s' "$_asb_loc" | tr '[:upper:]' '[:lower:]')" in
  *ru-*|*ru_*|ru) H_AUDIO="АУДИО"; H_CAMERA="КАМЕРА"; H_MEMORY="ПАМЯТЬ"; H_NETWORK="СЕТЬ"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="СИСТЕМА"; H_IFACE="ИНТЕРФЕЙС"
                  H_SLEEP="СОН"; H_LEARN="ОБУЧЕНИЕ"; H_SMART="ЧТО ВЫУЧИЛ SMART"
                  H_GOV="ГУБЕРНАТОР"; H_BATT="АВТО-БАТАРЕЯ"; H_LPM="МОДЕМ LPM" ;;
  *uk-*|*uk_*|uk) H_AUDIO="АУДІО"; H_CAMERA="КАМЕРА"; H_MEMORY="ПАМʼЯТЬ"; H_NETWORK="МЕРЕЖА"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="СИСТЕМА"; H_IFACE="ІНТЕРФЕЙС"
                  H_SLEEP="СОН"; H_LEARN="НАВЧАННЯ"; H_SMART="ЩО ВИВЧИВ SMART"
                  H_GOV="ГУБЕРНАТОР"; H_BATT="АВТО-БАТАРЕЯ"; H_LPM="МОДЕМ LPM" ;;
  *de-*|*de_*|de) H_AUDIO="AUDIO"; H_CAMERA="KAMERA"; H_MEMORY="SPEICHER"; H_NETWORK="NETZWERK"
                  H_WIFI="WLAN"; H_GPS="GPS"; H_SYSTEM="SYSTEM"; H_IFACE="OBERFLÄCHE"
                  H_SLEEP="SCHLAF"; H_LEARN="LERNEN"; H_SMART="WAS SMART GELERNT HAT"
                  H_GOV="GOVERNOR"; H_BATT="AUTO-AKKU"; H_LPM="MODEM LPM" ;;
  *es-*|*es_*|es) H_AUDIO="AUDIO"; H_CAMERA="CÁMARA"; H_MEMORY="MEMORIA"; H_NETWORK="RED"
                  H_WIFI="WIFI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFAZ"
                  H_SLEEP="SUEÑO"; H_LEARN="APRENDIZAJE"; H_SMART="LO QUE SMART HA APRENDIDO"
                  H_GOV="GOBERNADOR"; H_BATT="BATERÍA AUTO"; H_LPM="MÓDEM LPM" ;;
  *pt-*|*pt_*|pt) H_AUDIO="ÁUDIO"; H_CAMERA="CÂMERA"; H_MEMORY="MEMÓRIA"; H_NETWORK="REDE"
                  H_WIFI="WIFI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFACE"
                  H_SLEEP="SONO"; H_LEARN="APRENDIZADO"; H_SMART="O QUE O SMART APRENDEU"
                  H_GOV="GOVERNADOR"; H_BATT="BATERIA AUTO"; H_LPM="MODEM LPM" ;;
  *tr-*|*tr_*|tr) H_AUDIO="SES"; H_CAMERA="KAMERA"; H_MEMORY="BELLEK"; H_NETWORK="AĞ"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SİSTEM"; H_IFACE="ARAYÜZ"
                  H_SLEEP="UYKU"; H_LEARN="ÖĞRENME"; H_SMART="SMART NE ÖĞRENDİ"
                  H_GOV="GOVERNOR"; H_BATT="OTO PİL"; H_LPM="MODEM LPM" ;;
  *in-*|*id-*|*id_*|id) H_AUDIO="AUDIO"; H_CAMERA="KAMERA"; H_MEMORY="MEMORI"; H_NETWORK="JARINGAN"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SISTEM"; H_IFACE="ANTARMUKA"
                  H_SLEEP="TIDUR"; H_LEARN="PEMBELAJARAN"; H_SMART="YANG DIPELAJARI SMART"
                  H_GOV="GOVERNOR"; H_BATT="BATERAI OTOMATIS"; H_LPM="MODEM LPM" ;;
  *it-*|*it_*|it) H_AUDIO="AUDIO"; H_CAMERA="FOTOCAMERA"; H_MEMORY="MEMORIA"; H_NETWORK="RETE"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFACCIA"
                  H_SLEEP="SONNO"; H_LEARN="APPRENDIMENTO"; H_SMART="COSA HA IMPARATO SMART"
                  H_GOV="GOVERNOR"; H_BATT="BATTERIA AUTO"; H_LPM="MODEM LPM" ;;
  *ar-*|*ar_*|ar) H_AUDIO="الصوت"; H_CAMERA="الكاميرا"; H_MEMORY="الذاكرة"; H_NETWORK="الشبكة"
                  H_WIFI="واي فاي"; H_GPS="GPS"; H_SYSTEM="النظام"; H_IFACE="الواجهة"
                  H_SLEEP="النوم"; H_LEARN="التعلّم"; H_SMART="ما تعلّمه SMART"
                  H_GOV="المنظّم"; H_BATT="البطارية التلقائية"; H_LPM="مودم LPM" ;;
  zh-cn*|zh_cn*|*zh-hans*|zh) H_AUDIO="音频"; H_CAMERA="相机"; H_MEMORY="内存"; H_NETWORK="网络"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="系统"; H_IFACE="界面"
                  H_SLEEP="休眠"; H_LEARN="学习"; H_SMART="SMART 学到了什么"
                  H_GOV="调度器"; H_BATT="自动电池"; H_LPM="调制解调器 LPM" ;;
  *)              H_AUDIO="AUDIO"; H_CAMERA="CAMERA"; H_MEMORY="MEMORY"; H_NETWORK="NETWORK"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SYSTEM"; H_IFACE="INTERFACE"
                  H_SLEEP="SLEEP"; H_LEARN="LEARNING"; H_SMART="WHAT SMART HAS LEARNED"
                  H_GOV="GOVERNOR"; H_BATT="AUTO BATTERY"; H_LPM="MODEM LPM" ;;
esac

# Body strings, not just headings.
#
# The headings were translated and everything under them was not, which is arguably worse
# than all-English: the screen looks finished until you read a line. These are the
# sentences a user actually reads. Numbers, units and identifiers are left alone - a
# mistranslated unit turns a diagnostic into a wrong reading.
case "$(printf '%s' "$_asb_loc" | tr '[:upper:]' '[:lower:]')" in
  *ru-*|*ru_*|ru)
    M_SLOT="Слот времени"; M_SLOT_OF="из 12"
    M_SLOT_H1="День разбит на 12 слотов, каждый учится отдельно:"
    M_SLOT_H2="утро буднего дня и вечер воскресенья — это разные телефоны."
    M_CONF="Уверенность в этом слоте"; M_SES_BANK="сессий накоплено всего"
    M_MEASURED="Измерено для этого слота"; M_TYP_PEAK="типичный пик"; M_DRAIN="расход"
    M_NORMAL="Норма для вашего телефона"
    M_ABOVE="Выше"; M_LEANS="Smart склоняется к экономии, ниже"; M_ALLOWS="разрешает чуть больше."
    M_NOTFIXED1="Это не фиксированные числа — это медиана ваших же"
    M_NOTFIXED2="12 слотов, поэтому телефон, который просто горячее, не наказывается."
    M_RIGHTNOW="Сейчас"; M_LEAN_BAT="склоняется к экономии"
    M_LEAN_PERF="склоняется к производительности"; M_LEAN_BAL="сбалансировано"
    M_TOUCH_BOOST="плюс короткий подъём при касании экрана"
    M_WATCHING="Наблюдает сейчас"; M_APP="приложение"
    M_IDLE="простой"; M_LIGHT="лёгкая нагрузка"; M_NORMAL_USE="обычная нагрузка"
    M_HEAVY="высокая нагрузка"; M_GAMING="игра"
    M_REMEMBERS="Помнит тепловое поведение приложений:"; M_APPS=""
    M_PREDICT="Прогноз времени экрана"; M_AT_RATE="при текущем расходе"
    M_NOTE_PARTIAL="Примечание: работает на неполных данных для этого слота"
    M_NOTE_NEIGHBOUR="Примечание: используется соседний слот"
    M_NOTE_NODATA="Примечание: истории пока нет — безопасные значения"
    M_DISCARDED="сессий отброшено как ненадёжные"
    M_THIS_HOUR="в этот час обычно"
    M_WARM_HERE="тепло для этого телефона — Smart склоняется к экономии"
    M_COOL_HERE="прохладно для этого телефона — Smart разрешает чуть больше"
    M_SES_LEARNED="сессий изучено"; M_DRAIN_NOW="расход сейчас"
    M_BANKED="накоплено — Smart не управляет на этом профиле"
    M_DP0="ночь"; M_DP1="раннее утро"; M_DP2="утро"; M_DP3="день"; M_DP4="вечер"; M_DP5="поздний вечер"
    M_WEEKEND="выходной"; M_WEEKDAY="будний день"
    M_FOREGROUND="активное приложение" ;;
  *)
    M_SLOT="Time slot"; M_SLOT_OF="of 12"
    M_SLOT_H1="Your day is split into 12 slots. Each one is learned separately,"
    M_SLOT_H2="because a weekday morning and a Sunday evening are not the same phone."
    M_CONF="Confidence in this slot"; M_SES_BANK="sessions banked overall"
    M_MEASURED="Measured for this slot"; M_TYP_PEAK="typical peak"; M_DRAIN="drain"
    M_NORMAL="Normal for your phone"
    M_ABOVE="Above"; M_LEANS="Smart leans to battery, below"; M_ALLOWS="it allows a little more."
    M_NOTFIXED1="These are not fixed numbers - they are the median of your own"
    M_NOTFIXED2="12 slots, so a phone that simply runs hotter is not punished for it."
    M_RIGHTNOW="Right now"; M_LEAN_BAT="leaning to battery"
    M_LEAN_PERF="leaning to performance"; M_LEAN_BAL="balanced"
    M_TOUCH_BOOST="plus a short boost when you touch the screen"
    M_WATCHING="Watching now"; M_APP="app"
    M_IDLE="idle"; M_LIGHT="light use"; M_NORMAL_USE="normal use"
    M_HEAVY="heavy use"; M_GAMING="gaming"
    M_REMEMBERS="Remembers the heat behaviour of"; M_APPS="app(s) it has seen"
    M_PREDICT="Predicted screen time left"; M_AT_RATE="at the current rate"
    M_NOTE_PARTIAL="Note: running on partial data for this slot"
    M_NOTE_NEIGHBOUR="Note: falling back to a neighbouring slot"
    M_NOTE_NODATA="Note: no usable history yet - safe defaults in use"
    M_DISCARDED="session(s) were discarded as unreliable"
    M_THIS_HOUR="this hour usually"
    M_WARM_HERE="warm for this phone - Smart leans to battery here"
    M_COOL_HERE="cool for this phone - Smart allows a little more here"
    M_SES_LEARNED="sessions learned"; M_DRAIN_NOW="drain now"
    M_BANKED="banked - Smart not steering on this profile"
    M_DP0="night"; M_DP1="early morning"; M_DP2="morning"; M_DP3="midday"; M_DP4="afternoon"; M_DP5="evening"
    M_WEEKEND="weekend"; M_WEEKDAY="weekday"
    M_FOREGROUND="foreground" ;;
esac

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

_ewma_x10=$(grep "^smart_drain_ewma_x10=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
_on_ma=0
if [ -n "$_ewma_x10" ] && [ "$_ewma_x10" -gt 0 ] 2>/dev/null && \
   [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null; then
  _on_ma=$(( (_cap_uah / 1000) * _ewma_x10 / 1000 ))
  _eta_note="(measured)"
fi
if [ "$_on_ma" -lt 50 ] 2>/dev/null; then
  case "$PROFILE" in
    performance) _on_ma=650 ;;
    battery)     _on_ma=400 ;;
    *)           _on_ma=500 ;;
  esac
  _eta_note="(heuristic)"
fi
_off_ma=$(( _on_ma / 10 ))
[ "$_off_ma" -lt 40 ] && _off_ma=40
[ "$_off_ma" -gt 90 ] && _off_ma=90

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

# Smart Mode status
_smart_enabled=0
_smart_bucket=0
_smart_daypart=0
_smart_we=0
_smart_conf=0
_smart_alpha=500
_smart_fb=4
_smart_app=0
_smart_sleep=0
_smart_veto=0
if [ -r /data/adb/asb/smart_mode_enabled ]; then
  _smart_enabled=$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)
  case "$_smart_enabled" in ''|*[!0-9]*) _smart_enabled=0 ;; esac
fi
if [ "$_smart_enabled" = "1" ] && [ -r /dev/.asb/state ]; then
  _smart_bucket=$(grep -m1 '^smart_bucket_id=' /dev/.asb/state | cut -d= -f2)
  _smart_daypart=$(grep -m1 '^smart_daypart=' /dev/.asb/state | cut -d= -f2)
  _smart_we=$(grep -m1 '^smart_is_weekend=' /dev/.asb/state | cut -d= -f2)
  _smart_conf=$(grep -m1 '^smart_confidence=' /dev/.asb/state | cut -d= -f2)
  _smart_alpha=$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state | cut -d= -f2)
  _smart_fb=$(grep -m1 '^smart_fallback_level=' /dev/.asb/state | cut -d= -f2)
  _smart_app=$(grep -m1 '^smart_app_hint=' /dev/.asb/state | cut -d= -f2)
  _smart_sleep=$(grep -m1 '^smart_sleep_override=' /dev/.asb/state | cut -d= -f2)
  _smart_veto=$(grep -m1 '^smart_thermal_veto=' /dev/.asb/state | cut -d= -f2)
  for _v in _smart_bucket _smart_daypart _smart_we _smart_conf _smart_alpha _smart_fb _smart_app _smart_sleep _smart_veto; do
    eval _val="\$$_v"
    case "$_val" in ''|*[!0-9]*) eval "$_v=0" ;; esac
  done
fi
_daypart_name=""
case "$_smart_daypart" in
  0) _daypart_name="sleep" ;;
  1) _daypart_name="wake" ;;
  2) _daypart_name="morn" ;;
  3) _daypart_name="day" ;;
  4) _daypart_name="evening" ;;
  5) _daypart_name="late" ;;
esac
_we_name=""
[ "$_smart_we" = "1" ] && _we_name=" (weekend)" || _we_name=" (weekday)"

# Everything below is rendered in a PROPORTIONAL font dialog, not a terminal.
# Box frames and space-padded columns cannot line up there (an emoji is two cells wide but one
# character), which is why the old ╭──╮ frame came out ragged.
echo ""
echo "  🚀  AutoSystemBoost V62"
if [ "$_smart_enabled" = "1" ]; then
  _conf_pct=$((_smart_conf / 10))
  echo "  🤖  Smart · bucket ${_smart_bucket} · ${_daypart_name}${_we_name} · conf ${_conf_pct}%"
  # The profile still matters under Smart: it is the rail the learner moves within, so
  # "Smart" alone does not tell you what the caps are anchored to.
  echo "  🎛  Profile: ${PROFILE} (Smart picks caps within it)"
else
  echo "  🎛  Profile: ${PROFILE} (manual — Smart off)"
fi
_bias="$(grep -E '^[[:space:]]*smart_battery_bias=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
# Show the LIVE learning weight, the same number the WebUI shows as "battery-lean", so the two
# screens agree.
# smart_battery_bias is a different thing - it is the user's configured tilt, not the current
# runtime weight - so it was showing 60% while the WebUI showed the live 100%, and they looked
# like a bug.
_alpha_live="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
[ -n "$_alpha_live" ] && echo "  ⚖️  Battery lean: $((_alpha_live / 10))% (live)"
[ -n "$_bias" ] && [ "$_bias" != "0" ] && echo "  🔋  Battery tilt set to: $((_bias / 10))%"
# The throttling threshold is now user-settable, so it belongs where the profile is - reading a
# temperature elsewhere in the report and not knowing what it is compared against was the gap.
#
# They used to sit further down, after the throttling line already called _cfg - so
# the action screen printed "_cfg: not found" right under the battery tilt and the
# throttling temperature came out blank. A helper has to exist before its first use.
_cfg() {
  grep -E "^[[:space:]]*$1=" "$MODDIR/config/governor.conf" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_feat() {
  grep -E "^$1=" "$MODDIR/features.conf" 2>/dev/null | tail -1 | sed 's/.*=//' | tr -d ' \r'
}

_ste="$(_cfg sustained_temp_enter)"
[ -n "$_ste" ] && [ "$_ste" != "65" ] && echo "  🌡️  Throttling temperature: ${_ste}°C (default 65)"
if [ "$_rec_disabled" = "1" ]; then
  echo "  ⚠️  SAFE MODE  : governor disabled (${_rec_reason:-recovery})"
elif [ "$_rec_count" -gt 0 ] 2>/dev/null; then
  echo "  ⚠️  Recovery  : ${_rec_count} restart(s) — ${_rec_reason:-unknown}"
fi
echo ""
_cpu_note=""
[ "${_cputemp:-0}" -ge 80 ] 2>/dev/null && _cpu_note="  🔥 hot"
if [ "$_btempC" -gt 0 ]; then
  echo "  🌡  ${_cputemp}°C CPU  ·  ${_btempC}.${_btempCx}°C battery${_cpu_note}"
else
  echo "  🌡  ${_cputemp}°C CPU${_cpu_note}"
fi
echo "  🔋  ${_lvl:-?}%"
[ "$_auto_bat" = "1" ] && echo "  🔻 Auto-battery active"
[ "$_qn_active" = "1" ] && echo "  🌙 Night-quiet active"

if [ "$_smart_enabled" = "1" ]; then
  _alpha_pct=$((_smart_alpha / 10))
  # bucket/daypart/confidence are already on the header line - only print the things
  # that are NOT always true, so the screen stays short and every line carries news.
  [ "$_alpha_pct" != "100" ] && echo "  ⚖️  Battery bias: ${_alpha_pct}%"
  if [ "$_smart_fb" != "0" ]; then
    _fb_name=""
    case "$_smart_fb" in
      1) _fb_name="daypart fallback" ;;
      2) _fb_name="class fallback" ;;
      3) _fb_name="global fallback" ;;
      4) _fb_name="cold start (safe default)" ;;
    esac
    echo "  ↩️  Learning: ${_fb_name}"
  fi
  [ "$_smart_sleep" = "1" ] && echo "  🌙  Night-safe override active"
  [ "$_smart_veto" = "1" ] && echo "  🔥  Thermal veto active"
fi
echo ""
echo "  ⏳  Time to 0% ${_eta_note}"
echo "       ~${_ton_h}h ${_ton_m}m screen on  ·  ~${_toff_h}h ${_toff_m}m idle"

# ── Live state ──────────────────────────────────────────────────────────────────
# Read from the config the daemon reads, not from whatever the WebUI last drew.

_a_prof="$(_cfg audio_profile)";  [ -n "$_a_prof" ] || _a_prof="stock"
_a_dac="$(_cfg audio_dac_hifi)"
_a_loud="$(_cfg media_loudness)"; [ -n "$_a_loud" ] || _a_loud="stock"
_a_dsp="$(_cfg dsp_loudness)";    [ -n "$_a_dsp" ]  || _a_dsp="off"
_a_bt="$(_cfg bt_absvol_mode)";   [ -n "$_a_bt" ]   || _a_bt="stock"
_c_lvl="$(_cfg CAMERA_LEVEL)";    [ -n "$_c_lvl" ]  || _c_lvl="0"
_blur="$(_cfg disable_blur)"
_cool="$(_cfg cool_gaming)"
_dsp_so=0
{ [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; } && _dsp_so=1
# Assigned inside the WIFI / CAMERA gates further down; seed them here so the
# verification block at the end cannot read them unset.
_cc_drv=""
_vb_n=0

# Every place an effects config can live on any of these devices, in one list so the AUDIO
# section and the NOT APPLIED check below can never disagree about where to look.
# Both names matter: the SKU dirs on SM8650 carry audio_effects.xml, NOT
# audio_effects_config.xml - the installer registered into exactly those two files and the
# checker, which globbed only the *_config name under sku_*, reported the effect as missing on
# a device where it was live.
_asb_effect_files() {
  for _d in /odm/etc /vendor/etc /vendor/odm/etc /system/etc \
            /vendor/etc/audio/sku_* /odm/etc/audio/sku_* \
            /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
    for _n in audio_effects_config.xml audio_effects.xml; do
      [ -f "$_d/$_n" ] && echo "$_d/$_n"
    done
  done
}

_st() { grep -m1 "^$1=" /dev/.asb/state 2>/dev/null | cut -d= -f2; }

# Append "$2" to the accumulator "$1", inserting the separator only between real items.
_join() {
  [ -n "$2" ] || { printf '%s' "$1"; return; }
  if [ -n "$1" ]; then printf '%s  ·  %s' "$1" "$2"; else printf '%s' "$2"; fi
}

_g_state="$(_st state)"
_g_owner="$(_st cap_owner)"
_g_cpumax="$(_st cpu_max)"
_g_dwell="$(_st dwell_sec)"
_g_iq="$(_st iq)"
_g_thermal="$(_st thermal)"
_g_head="$(_st headroom_pct)"
if [ -n "$_g_state" ]; then
  echo ""
  echo "  ⚡  ${H_GOV}"
  # cap_owner is empty until the governor has taken ownership; saying "unknown" is
  # noise, so just omit it and let the state speak.
  _gl="$_g_state"
  case "$_g_owner" in ''|unknown|none) : ;; *) _gl="$(_join "$_gl" "caps by ${_g_owner}")" ;; esac
  echo "       ${_gl}"

  _gl=""
  [ "${_g_cpumax:-0}" -gt 0 ] 2>/dev/null && _gl="$(_join "$_gl" "CPU max ${_g_cpumax} MHz")"
  [ -n "$_g_dwell" ] && _gl="$(_join "$_gl" "dwell ${_g_dwell}s")"
  [ -n "$_gl" ] && echo "       ${_gl}"

  _gl=""
  [ -n "$_g_iq" ] && _gl="$(_join "$_gl" "environment iq ${_g_iq}")"
  [ -n "$_g_head" ] && _gl="$(_join "$_gl" "headroom ${_g_head}%")"
  [ "${_g_thermal:-0}" != "0" ] && _gl="$(_join "$_gl" "🔥 thermal ${_g_thermal}")"
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

# Show the SAME learner numbers the WebUI shows, so the two screens agree.
_l_sess="$(_st smart_sessions_total)"
[ -n "$_l_sess" ] || _l_sess="$(_st hist_sessions)"   # fall back on older governors
_l_conf="$(_st smart_last_confidence)"
[ -n "$_l_conf" ] || _l_conf="$(_st smart_confidence)"   # fall back on older governors
_l_pkg="$(_st smart_pkg)"
# smart_drain_pctph_x10 first: the EWMA field reads 0 on this governor (confirmed on
# device - pctph said 114 while ewma said 0), so preferring the EWMA meant the drain line
# never printed at all. Keep the EWMA as a fallback for older governors that fill it.
_l_drain="$(_st smart_drain_pctph_x10)"
case "$_l_drain" in ''|0) _l_drain="$(_st smart_drain_ewma_x10)" ;; esac
# Not gated on Smart being active.
#
# smart_mode_enabled goes to 0 when the profile leaves Smart, and that took the whole LEARNING
# block with it - so a user who dropped to 20% and got auto-switched to Battery saw "unknown, 0
# sessions" on a governor that had ten sessions banked and knew it.
# The sessions are history, not a live feature: they do not stop existing because the current
# profile is not Smart, and they are what Smart will use again next time it runs.
if [ -n "${_l_sess}${_l_pkg}" ]; then
  echo ""
  echo "  🧠  ${H_LEARN}"
  _ll=""
  if [ -n "$_l_sess" ]; then
    [ "$_l_sess" = "1" ] && _ll="1 ${M_SES_LEARNED}" \
                         || _ll="${_l_sess} ${M_SES_LEARNED}"
  fi
  # Confidence tier, worded the same way the WebUI tiers it.
  if [ -n "$_l_conf" ] && [ "$_l_conf" -gt 0 ] 2>/dev/null; then
    if   [ "$_l_conf" -ge 650 ]; then _tier="strong"
    elif [ "$_l_conf" -ge 350 ]; then _tier="active"
    else _tier="learning"; fi
    _ll="$(_join "$_ll" "${_tier} $((_l_conf / 10))%")"
  fi
  # What the current bucket has learned, and therefore why Smart is leaning the way it
  # is. The alpha number alone told nobody anything.
  _bt="$(_st smart_bucket_temp_x10)"; _bd="$(_st smart_bucket_drain_x10)"
  if [ -n "$_bt" ] && [ "$_bt" -gt 0 ] 2>/dev/null; then
    # A literal degree sign: printf %b expands \n and friends but not \uXXXX, so the
    # escape came out as the four characters "u00b0" on screen.
    _bl="       ${M_THIS_HOUR}: $((_bt / 10)).$((_bt % 10))°C"
    [ -n "$_bd" ] && [ "$_bd" -gt 0 ] 2>/dev/null \
      && _bl="${_bl}  ·  $((_bd / 10)).$((_bd % 10))%/h"
    printf '%b\n' "$_bl"
    # Compare against this device's learned thresholds, not fixed degrees.
    _tw="$(_st smart_therm_warm_x10)"; _tc="$(_st smart_therm_cool_x10)"
    case "$_tw" in ''|*[!0-9]*) _tw=420 ;; esac
    case "$_tc" in ''|*[!0-9]*) _tc=380 ;; esac
    [ "$_bt" -gt "$_tw" ] 2>/dev/null && echo "       (${M_WARM_HERE})"
    [ "$_bt" -lt "$_tc" ] 2>/dev/null && echo "       (${M_COOL_HERE})"
  fi
  [ "$_smart_enabled" != "1" ] && _ll="$(_join "$_ll" "$M_BANKED")"
  [ -n "$_ll" ] && echo "       ${_ll}"
  if [ -n "$_l_drain" ] && [ "$_l_drain" -gt 0 ] 2>/dev/null; then
    echo "       ${M_DRAIN_NOW}: $((_l_drain / 10)).$((_l_drain % 10))%/h"
  fi
  [ -n "$_l_pkg" ] && echo "       ${M_FOREGROUND}: ${_l_pkg}"

  # Full picture, only while Smart is the profile actually steering.
  #
  # Everything below already existed as a number in /dev/.asb/state and was readable by
  # nobody: 46 smart_* fields, of which the report showed four. The learner is the part of
  # this module people are most sceptical about, and "trust me, it is learning" is not an
  # answer - so this says what it has measured, what it concluded, and what it is doing
  # about it, in the order someone would ask.
  if [ "$_smart_enabled" = "1" ]; then
    echo ""
    echo "  🎓  ${H_SMART}"

    # --- 1. when it thinks it is -----------------------------------------------------
    _bid="$(_st smart_bucket_id)"; _dp="$(_st smart_daypart)"; _we="$(_st smart_is_weekend)"
    case "$_dp" in
      0) _dpn="$M_DP0" ;; 1) _dpn="$M_DP1" ;; 2) _dpn="$M_DP2" ;;
      3) _dpn="$M_DP3" ;; 4) _dpn="$M_DP4" ;; 5) _dpn="$M_DP5" ;;
      *) _dpn="?" ;;
    esac
    [ "$_we" = "1" ] && _dayk="$M_WEEKEND" || _dayk="$M_WEEKDAY"
    echo "       ${M_SLOT}: ${_dpn} · ${_dayk} (${_bid} ${M_SLOT_OF})"
    echo "         ${M_SLOT_H1}"
    echo "         ${M_SLOT_H2}"

    # --- 2. how sure it is -----------------------------------------------------------
    _conf="$(_st smart_confidence)"; _ses="$(_st smart_sessions_total)"
    if [ -n "$_conf" ] && [ "$_conf" -gt 0 ] 2>/dev/null; then
      echo "       ${M_CONF}: $((_conf / 10))%  ·  ${_ses:-0} ${M_SES_BANK}"
      [ "$_conf" -lt 350 ] 2>/dev/null \
        && echo "         Still low - Smart is mostly using safe defaults here."
      [ "$_conf" -ge 650 ] 2>/dev/null \
        && echo "         High - decisions in this slot are driven by what it measured, not defaults."
    fi

    # --- 3. what it measured ---------------------------------------------------------
    _bt2="$(_st smart_bucket_temp_x10)"; _bd2="$(_st smart_bucket_drain_x10)"
    _tw2="$(_st smart_therm_warm_x10)"; _tc2="$(_st smart_therm_cool_x10)"
    if [ -n "$_bt2" ] && [ "$_bt2" -gt 0 ] 2>/dev/null; then
      echo "       ${M_MEASURED}: $((_bt2 / 10)).$((_bt2 % 10))°C ${M_TYP_PEAK}, $((_bd2 / 10)).$((_bd2 % 10))%/h ${M_DRAIN}"
      if [ -n "$_tw2" ] && [ "$_tw2" -gt 0 ] 2>/dev/null; then
        # Say the band, then the edges. "warm above 56, cool below 48" listed two
        # thresholds and read as a single self-contradicting range - the normal zone
        # between them was never stated, so the two numbers looked like nonsense.
        echo "       ${M_NORMAL}: $((_tc2 / 10))-$((_tw2 / 10))°C"
        echo "         ${M_ABOVE} $((_tw2 / 10))°C ${M_LEANS} $((_tc2 / 10))°C ${M_ALLOWS}"
        echo "         ${M_NOTFIXED1}"
        echo "         ${M_NOTFIXED2}"
      fi
    fi

    # --- 4. what it decided ----------------------------------------------------------
    _alpha="$(_st smart_alpha_battery)"; _ib="$(_st smart_interactive_bonus)"
    if [ -n "$_alpha" ] && [ "$_alpha" -gt 0 ] 2>/dev/null; then
      if   [ "$_alpha" -ge 650 ] 2>/dev/null; then _lean="$M_LEAN_BAT"
      elif [ "$_alpha" -le 350 ] 2>/dev/null; then _lean="$M_LEAN_PERF"
      else _lean="$M_LEAN_BAL"; fi
      echo "       ${M_RIGHTNOW}: ${_lean} (${_alpha}/1000)"
      [ -n "$_ib" ] && [ "$_ib" -gt 0 ] 2>/dev/null \
        && echo "         ${M_TOUCH_BOOST} (+${_ib})"
    fi

    # --- 5. what it is watching in real time -----------------------------------------
    _wl=""
    _ah="$(_st smart_app_hint)"
    case "$_ah" in
      0) _ahn="$M_IDLE" ;; 1) _ahn="$M_LIGHT" ;; 2) _ahn="$M_NORMAL_USE" ;;
      3) _ahn="$M_HEAVY" ;; 4) _ahn="$M_GAMING" ;; *) _ahn="" ;;
    esac
    [ -n "$_ahn" ] && _wl="${M_APP}: ${_ahn}"
    _hot="$(_st smart_app_hot)"
    [ "$_hot" = "1" ] && _wl="$(_join "$_wl" "this app runs hot")"
    _veto="$(_st smart_thermal_veto)"
    [ "$_veto" = "1" ] && _wl="$(_join "$_wl" "thermal veto ACTIVE - holding back for heat")"
    _slp="$(_st smart_sleep_override)"
    [ "$_slp" = "1" ] && _wl="$(_join "$_wl" "sleep window - minimal activity")"
    _lowb="$(_st smart_lowbat_override)"
    [ "$_lowb" = "1" ] && _wl="$(_join "$_wl" "low battery - saving")"
    _chg="$(_st smart_charge_assist)"
    [ "$_chg" = "1" ] && _wl="$(_join "$_wl" "charging - extra headroom while cool")"
    [ -n "$_wl" ] && echo "       ${M_WATCHING}: ${_wl}"

    _aph="$(_st smart_appheat_n)"
    [ -n "$_aph" ] && [ "$_aph" -gt 0 ] 2>/dev/null \
      && echo "       ${M_REMEMBERS} ${_aph} ${M_APPS}"

    # --- 6. how long the battery is expected to last ---------------------------------
    _bp="$(_st smart_budget_pred_h_x10)"
    if [ -n "$_bp" ] && [ "$_bp" -gt 0 ] 2>/dev/null; then
      echo "       ${M_PREDICT}: $((_bp / 10)).$((_bp % 10))h ${M_AT_RATE}"
    fi

    # --- 7. honest limits ------------------------------------------------------------
    _fb="$(_st smart_fallback_level)"
    case "$_fb" in
      0) : ;;
      1) echo "       ${M_NOTE_PARTIAL}" ;;
      2) echo "       ${M_NOTE_NEIGHBOUR}" ;;
      3) echo "       ${M_NOTE_NODATA}" ;;
    esac
    _qf="$(_st smart_q_fail)"
    [ -n "$_qf" ] && [ "$_qf" -gt 0 ] 2>/dev/null \
      && echo "       ${_qf} ${M_DISCARDED}"
  fi
fi

echo ""
echo "  🎵  ${H_AUDIO}"
_audio_l="       ${_a_prof} profile"
[ "$_a_dac" = "1" ] && _audio_l="${_audio_l}  ·  hi-fi DAC"
echo "$_audio_l"
_loud_l="       loudness: ${_a_loud}"
[ "$_a_dsp" != "off" ] && _loud_l="${_loud_l}  ·  DSP +${_a_dsp} dB"
echo "$_loud_l"
[ "$_a_bt" = "disabled" ] && echo "       BT volume: phone drives gain (independent scales)"
# The compressor only exists while the DSP is on - saying "compressor: on" next to a
# disabled DSP describes a setting, not the device.
if [ "$_a_dsp" != "off" ]; then
  case "$(_cfg dsp_compressor)" in
    off|0|false) echo "       compressor: off  ·  limiter only" ;;
    *)           echo "       compressor: on  ·  6:1 above -24 dBFS" ;;
  esac
fi
_a_bass="$(_cfg dsp_bass)"
case "$_a_bass" in ''|off|0) : ;; *) echo "       bass shelf: +${_a_bass} dB @ 90 Hz" ;; esac
if [ "$_a_dsp" != "off" ]; then
  _l64="✗"; _l32="✗"
  [ -f /vendor/lib64/soundfx/libasbdsp.so ] && _l64="✓"
  [ -f /vendor/lib/soundfx/libasbdsp.so ] && _l32="✓"
  _dsp_abi="?"
  if [ -f /vendor/lib64/soundfx/libasbdsp.so ]; then
    if grep -aq 'ASB createEffect' /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null; then
      _dsp_abi="AIDL"
    elif grep -aq 'AELI\|ASB_DSP' /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null; then
      _dsp_abi="legacy"
    fi
  fi
  if [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] \
     && [ "$(getprop persist.asb.dsp.comp 2>/dev/null)" = "0" ]; then
    echo "       compressor: off (limiter only)"
  fi
  echo "       libasbdsp: 64-bit ${_l64}  ·  32-bit ${_l32}  ·  ABI ${_dsp_abi}"
  for _ecs in $(_asb_effect_files); do
    if grep -q 'asb_loudness' "$_ecs" 2>/dev/null; then
      echo "       effect registered in: ${_ecs}"
      break
    fi
  done
fi

echo ""
echo "  📷  ${H_CAMERA}"
_vb_n="$(grep -c '"packageName"' /odm/etc/camera/config/video_beauty_default_config 2>/dev/null)"
_cam_l="processing level ${_c_lvl}"
[ "${_vb_n:-0}" -gt 0 ] 2>/dev/null && _cam_l="$(_join "$_cam_l" "${_vb_n} retouch apps")"
echo "       ${_cam_l}"
_cam_ag="$(_cfg CAMERA_AGGRESSIVE)"
_cam_in="$(_cfg CAMERA_AGGRESSIVE_INJECT)"
_cam_l=""
[ "$_cam_ag" = "1" ] && _cam_l="$(_join "$_cam_l" "aggressive tone")"
case "$_cam_in" in
  full) _cam_l="$(_join "$_cam_l" "inject: full")" ;;
  ''|standard) : ;;
  *) _cam_l="$(_join "$_cam_l" "inject: ${_cam_in}")" ;;
esac
[ -n "$_cam_l" ] && echo "       ${_cam_l}"
# The grade is a ratio applied to the device's own tuning file, so report what it
# multiplied rather than a bare level number - the level alone says nothing about what
# changed. Only lines that differ from stock are printed.
_c_grain="$(_cfg CAMERA_GRAIN)";    case "$_c_grain" in ''|3) _c_grain="" ;; esac
_c_contr="$(_cfg CAMERA_CONTRAST)"; case "$_c_contr" in ''|3) _c_contr="" ;; esac
_c_port="$(_cfg CAMERA_PORTRAIT)";  case "$_c_port"  in ''|0) _c_port=""  ;; esac
_c_low="$(_cfg CAMERA_LOWLIGHT)";   case "$_c_low"   in ''|0) _c_low=""   ;; esac
[ -n "$_c_grain" ] && echo "       film grain: ${_c_grain}/8 (3 = stock)"
[ -n "$_c_contr" ] && echo "       contrast & colour depth: ${_c_contr}/8 (3 = stock)"
[ -n "$_c_port" ]  && echo "       portrait AI: ${_c_port}/6 (ships off)"
# Camera hold belongs here, not under SYSTEM.
#
# It reports that the governor is holding interactive caps BECAUSE the camera pipeline is
# streaming - a camera fact that was printed three sections away from everything else about the
# camera.
# The block that printed it also carried a mangled `echo ""echo ""`, emitting a stray blank
# line, and it was gated on lpm_mode and the LPM category, which have nothing to do with the
# camera: on a device with LPM switched off, camera hold was never reported at all.
if [ "$(_st camera_hold)" = "1" ]; then
  echo "       hold ACTIVE · interactive caps held, cpuset + uclamp lifted"
fi
[ -n "$_c_low" ]   && echo "       macro / low-light sharpening: ${_c_low}/8"
# Whether the grade actually landed on the live partition, which is the only claim
# worth making - the config saying 4 proved nothing until this was checked.
_c_live="/odm/etc/camera/conf_tuning_params.json"
if [ "${_c_lvl:-0}" -gt 0 ] 2>/dev/null && [ -r "$_c_live" ]; then
  _c_bw="$(grep -m1 -o '"BlendWeight"[^]]*]' "$_c_live" 2>/dev/null | sed 's/.*\[//;s/\]//')"
  case "$_c_bw" in
    *0.35,*0.5,*0.7*) echo "       ⚠️  grade NOT on the live file (still stock values)" ;;
    ?*)               echo "       ✅ live file graded: BlendWeight [${_c_bw}]" ;;
  esac
fi


echo ""
echo "  💾  ${H_MEMORY}"
_bgl="$(_cfg BG_TRIM_LEVEL)"
_ml=""
[ -n "$_bgl" ] && _ml="$(_join "$_ml" "bg trim: level ${_bgl}")"
_swp="$(cat /proc/sys/vm/swappiness 2>/dev/null)"
[ -n "$_swp" ] && _ml="$(_join "$_ml" "swappiness ${_swp}")"
[ -n "$_ml" ] && echo "       ${_ml}"
_mfree="$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}')"
_zram="$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) print int((t-f)/1024)}' /proc/meminfo 2>/dev/null)"
_ml=""
[ -n "$_mfree" ] && _ml="$(_join "$_ml" "${_mfree} MB free")"
[ -n "$_zram" ] && _ml="$(_join "$_ml" "zram ${_zram} MB used")"
[ -n "$_ml" ] && echo "       ${_ml}"

if [ "$(_feat NET)" = "1" ]; then
  echo ""
  echo "  🌐  ${H_NETWORK}"
  _nl=""
  _cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  [ -n "$_cc" ] && _nl="$(_join "$_nl" "$_cc")"
  _qd="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
  [ -n "$_qd" ] && _nl="$(_join "$_nl" "$_qd")"
  _nb="$(cat /proc/sys/net/core/netdev_budget 2>/dev/null)"
  [ -n "$_nb" ] && _nl="$(_join "$_nl" "budget ${_nb}")"
  [ -n "$_nl" ] && echo "       TCP: ${_nl}"

# What the user ASKED for, alongside what the kernel is actually running.
#
# The lines above read the live sysctls - true, but not the whole story: a request the kernel
# refused looks identical to one that was never made.
_nv="/data/adb/asb/net_apply_result"
_nverd() { [ -f "$_nv" ] && grep -E "^$1=" "$_nv" 2>/dev/null | head -1 | sed 's/.*=//'; }
_nfmt() {
  _w="$(_cfg "$2")"
  case "$_w" in ''|auto) return 0 ;; esac
  _v="$(_nverd "$2")"
  case "$_v" in
    unavailable) echo "       $1: ${_w} requested · NOT SUPPORTED by this kernel" ;;
    failed)      echo "       $1: ${_w} requested · NOT APPLIED" ;;
    pending)     echo "       $1: ${_w} · waiting for a link" ;;
    *)           if [ -n "$3" ] && [ "$3" != "$_w" ]; then
                   echo "       $1: ${_w} requested · running ${3}"
                 else
                   echo "       $1: ${_w}"
                 fi ;;
  esac
}
_nfmt "ramp (other links)" net_congestion "$_cc"
_nfmt "queue (other links)" net_qdisc "$_qd"

# Per-link overrides print only when set, so the section stays short on a default install
# and grows only for someone who has actually split Wi-Fi from mobile.
for _pk in net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile; do
  _pv="$(_cfg "$_pk")"
  case "$_pv" in ''|auto) continue ;; esac
  case "$_pk" in *_wifi) _plabel="Wi-Fi" ;; *) _plabel="mobile" ;; esac
  case "$_pk" in net_congestion_*) _pwhat="ramp" ;; *) _pwhat="queue" ;; esac
  case "$(_nverd "$_pk")" in
    unavailable) echo "       ${_pwhat} · ${_plabel}: ${_pv} · NOT SUPPORTED" ;;
    failed)      echo "       ${_pwhat} · ${_plabel}: ${_pv} · NOT APPLIED" ;;
    *)           echo "       ${_pwhat} · ${_plabel}: ${_pv}" ;;
  esac
done

# Initial windows: read the real route attributes, since that is the only proof the change
# survived the connectivity stack replacing the route underneath us.
_rt="$(_cfg net_route_tune)"
case "$_rt" in
  ''|off) : ;;
  *)
    _rtl="$(ip route show 2>/dev/null | grep -m1 -oE 'initcwnd [0-9]+ initrwnd [0-9]+')"
    if [ -n "$_rtl" ]; then
      echo "       buffers: ${_rt} · ${_rtl} on the default route"
    else
      echo "       buffers: ${_rt} · not on the route yet (pending or replaced)"
    fi
    ;;
esac

# Wi-Fi region and scan rate live here too - they are network settings, and putting them
# under a separate WIFI heading split one topic across two sections.
_wcc="$(_cfg wifi_country)"
case "$_wcc" in
  ''|auto) : ;;
  *) case "$(_nverd wifi_country)" in
       failed) echo "       Wi-Fi region: ${_wcc} · NOT APPLIED" ;;
       *)      echo "       Wi-Fi region: ${_wcc}" ;;
     esac ;;
esac
_wst="$(_cfg wifi_scan_throttle)"
case "$_wst" in
  0) echo "       Wi-Fi scan: unthrottled (roams sooner, costs battery)" ;;
  1) echo "       Wi-Fi scan: stock limit (4 per 2 min)" ;;
esac
  # Which interface is actually carrying traffic - not always rmnet_data0.
  _if="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [a-z0-9_]+' | head -1 | cut -d' ' -f2)"
  if [ -n "$_if" ]; then
    _rx="$(cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null)"
    _nl="route via ${_if}"
    [ -n "$_rx" ] && _nl="${_nl}  ·  $((_rx / 1048576)) MB rx"
    echo "       ${_nl}"
  fi
fi

  # Modem LPM: a NETWORK line, gated on LPM, with its own wording.
  #
  # Three things were wrong.
  if [ "$(_feat LPM)" = "1" ]; then
    _lpm="$(cat /dev/.asb/lpm_mode 2>/dev/null)"
    case "$_lpm" in
      fast) echo "       modem LPM: fast · data call held up (low latency)" ;;
      save) echo "       modem LPM: save · radio idling, keepalives stretched" ;;
      '')   : ;;
      *)    echo "       modem LPM: normal · profile defaults" ;;
    esac
  fi

_cam_hold="$(_st camera_hold)"
if [ "$_cam_hold" = "1" ]; then

echo ""
  echo "  📶  ${H_WIFI}"
# Read what the DRIVER actually ended up with, not `settings get global wifi_country_code`.
# That settings key is telephony-derived and the framework keeps rewriting it from the SIM, so
# it reported the SIM's country (IT) while the module's override was live - which looked
# exactly like the tweak had failed.
_wifi_dump="$(dumpsys wifi 2>/dev/null)"
_cc_drv="$(echo "$_wifi_dump" | grep -iE 'mDriverCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_ovr="$(echo "$_wifi_dump" | grep -iE 'mOverrideCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_tel="$(echo "$_wifi_dump" | grep -iE 'mTelephonyCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
[ -n "$_cc_drv" ] || _cc_drv="$(cmd -w wifi get-country-code 2>/dev/null | grep -oE '[A-Z]{2}' | head -1)"
_cc_forced=0
[ -f /data/adb/asb/wifi_cc_forced ] && _cc_forced=1
_cc_want=""
for _pf in /data/adb/modules/AutoSystemBoost/profiles/*.sh; do
  [ -f "$_pf" ] || continue
  case "$_pf" in *"/$(cat /data/adb/modules/AutoSystemBoost/current_profile 2>/dev/null).sh") ;; *) continue ;; esac
  _cc_want="$(grep -E '^[[:space:]]*WIFI_COUNTRY=' "$_pf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r"' | tr '[:lower:]' '[:upper:]')"
done

if [ -n "$_cc_drv" ]; then
  _wl="       region: ${_cc_drv}"
  [ "$_cc_forced" = "1" ] && _wl="${_wl} (forced)"
  [ -n "$_cc_tel" ] && [ "$_cc_tel" != "$_cc_drv" ] && _wl="${_wl}  ·  SIM says ${_cc_tel}"
  echo "$_wl"
elif [ "$_cc_forced" = "1" ]; then
  echo "       region: forced${_cc_ovr:+ ${_cc_ovr}} (radio off?)"
fi
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  _lnk="$(echo "$_wifi_dump" | grep -m1 -iE 'mWifiInfo|SSID' | grep -oE '[0-9]+Mbps' | head -1)"
  _wl2=""
  [ -n "$_txq" ] && _wl2="$(_join "$_wl2" "txqueue ${_txq}")"
  [ -n "$_lnk" ] && _wl2="$(_join "$_wl2" "link ${_lnk}")"
  [ -n "$_wl2" ] && echo "       ${_wl2}"
fi

if [ "$(_feat GPS)" = "1" ]; then
  echo ""
  echo "  🛰  ${H_GPS}"
  _agps="$(settings get global assisted_gps_enabled 2>/dev/null)"
  _gl=""
  case "$_agps" in 1) _gl="$(_join "$_gl" "A-GPS on")" ;; 0) _gl="$(_join "$_gl" "A-GPS off")" ;; esac
  _xtra="$(settings get global gps_xtra_server 2>/dev/null)"
  case "$_xtra" in *gpsonextra*) _gl="$(_join "$_gl" "XTRA servers set")" ;; esac
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

echo ""
# If the fail-safe fired, say so first - a user whose blur setting silently stopped
# working deserves to know the module turned it off rather than that it broke.
if [ -f /data/adb/asb/prop_blocks_disabled ]; then
  echo ""
  echo "  ⚠️  BOOT SAFETY"
  echo "       ASB removed its display properties after two failed boots."
  echo "       Re-enable blur and animations one at a time to find the culprit."
fi
_pbn="$(cat /data/adb/asb/prop_boot_counter 2>/dev/null)"
case "$_pbn" in
  ''|0) : ;;
  *) echo "       (boot-safety counter at ${_pbn}/2 - last boot did not report completion)" ;;
esac

# Interface gets its own heading. Blur and animations were reported under SYSTEM next to
# process limits and logging, which put four unrelated things under one word - and the
# WebUI has had them as separate categories for a while now. The report should agree with
# the screen the user just came from.
echo "  🖥  ${H_IFACE}"
echo "       blur: $([ "$_blur" = "1" ] && echo off || echo stock)"
# Animations: auto follows blur, so resolve it rather than printing "auto" and leaving
# the reader to work out what that means on this device.
_ui_fx="$(_cfg ui_effects_level)"
case "$_ui_fx" in
  flat|0)  echo "       animations: simplified" ;;
  stock|1) echo "       animations: normal" ;;
  *)       [ "$_blur" = "1" ] \
             && echo "       animations: simplified (auto, follows blur)" \
             || echo "       animations: normal (auto, follows blur)" ;;
esac
case "$(_cfg UX_MANAGE_TIMEOUTS)" in
  1) echo "       UI speed: managed (animations and touch windows scaled per profile)" ;;
esac
case "$(_cfg lockscreen_shortcuts)" in
  clean) echo "       lock screen: camera and wallet shortcuts hidden" ;;
esac

# Sleep. Nothing reported this at all, which is a gap on the one subsystem whose whole
# purpose is what happens while nobody is looking - and the night window is learned, so
# the user cannot know it without being told.
echo ""
echo "  🌙  ${H_SLEEP}"
_dz="$(_cfg doze_level)"
case "$_dz" in
  night)
    _nw="/data/adb/asb/night_window.conf"
    if [ -r "$_nw" ]; then
      _nsm="$(grep -E '^sleep_min=' "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _nwm="$(grep -E '^wake_min='  "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _nns="$(grep -E '^samples='   "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
    fi
    case "$_nsm$_nwm" in
      ''|*[!0-9]*) echo "       deep sleep: night mode, still learning your schedule" ;;
      *)
        # Report the window actually used, margins included - printing the raw learned
        # times would not match when the phone changes behaviour.
        _ws=$(( (_nsm + 15) % 1440 )); _we=$(( (_nwm - 20 + 1440) % 1440 ))
        printf '       deep sleep: night mode · %02d:%02d-%02d:%02d (learned from %s nights)\n' \
          $((_ws / 60)) $((_ws % 60)) $((_we / 60)) $((_we % 60)) "${_nns:-?}" ;;
    esac
    [ -f /data/adb/asb/aod_baseline ] && echo "       always-on display: paused for the night window"
    ;;
  moderate)   echo "       deep sleep: moderate (idle after 5 min instead of 30)" ;;
  aggressive) echo "       deep sleep: aggressive (idle after 2 min; messages may lag)" ;;
  *)          echo "       deep sleep: stock" ;;
esac
case "$(_cfg night_quiet_enable)" in
  1) echo "       night quiet: sensor polling slowed inside the sleep window" ;;
esac

echo ""
echo "  ⚙️  ${H_SYSTEM}"
case "$(_cfg phantom_procs)" in
  relaxed) echo "       background processes: unlimited (phantom monitor off)" ;;
  strict)  echo "       background processes: Android default (32 max)" ;;
esac
case "$(_cfg UX_MANAGE_OEM_TOGGLES)" in
  1) echo "       OEM toggles: managed (RAM expansion, battery, heat)" ;;
esac

# Haptics. The numbers that matter are the OEM stepless values actually in force, not
# the level we asked for - a rejected write would leave the two disagreeing.
_hap="$(_cfg haptic_strength)"
_hap_t="$(_cfg haptic_touch_strength)"
case "$_hap" in
  ''|-1|auto|stock) echo "       vibration: stock (not managed)" ;;
  0|off)            echo "       vibration: off" ;;
  *)
    _hap_live="$(settings get system notification_stepless_vibration_intensity 2>/dev/null)"
    _hap_l="       vibration: ${_hap}/10"
    case "$_hap_live" in ''|null) : ;; *) _hap_l="${_hap_l}  ·  live ${_hap_live}" ;; esac
    case "$_hap_t" in
      ''|-1|auto) _hap_l="${_hap_l}  ·  touch: follows" ;;
      0)          _hap_l="${_hap_l}  ·  touch: off" ;;
      *)          _hap_l="${_hap_l}  ·  touch: ${_hap_t}/10" ;;
    esac
    echo "$_hap_l" ;;
esac

# Every category, not the six that happened to be hard-coded here. Wrapped by hand
# because a single 20-item line is unreadable on a phone.
_cats=""; _catn=0; _catline=""
for _c in CPU VM AUDIO BT NFC CAMERA MEDIA NET WIFI GPS KERNEL LOG LPM \
          RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY SOTER_REPAIR; do
  [ "$(_feat "$_c")" = "1" ] || continue
  _catline="$(_join "$_catline" "$_c")"
  _catn=$((_catn + 1))
  if [ "$_catn" -ge 5 ]; then
    echo "       ${_catline}"
    _catline=""; _catn=0
  fi
done
[ -n "$_catline" ] && echo "       ${_catline}"
# Magisk does its magic mounts in a private namespace, so /proc/mounts read from here shows
# zero entries for the module even when the overlay is perfectly live - on KernelSU the same
# grep finds them.
_mnt="$(grep -c 'AutoSystemBoost' /proc/mounts 2>/dev/null)"
case "$_mnt" in ''|*[!0-9]*) _mnt=0 ;; esac
_ovl_live=0
for _op in /vendor/lib64/soundfx/libasbdsp.so /vendor/lib/soundfx/libasbdsp.so; do
  [ -f "$_op" ] && { _ovl_live=1; break; }
done
_krn="$(uname -r 2>/dev/null | cut -d- -f1)"
if [ "$_mnt" -gt 0 ] 2>/dev/null; then
  _sysl="       overlay: ${_mnt} mount$([ "$_mnt" = "1" ] || echo s)"
elif [ "$_ovl_live" = "1" ]; then
  _sysl="       overlay: live (private namespace)"
else
  _sysl="       overlay: not detected"
fi
[ -n "$_krn" ] && _sysl="${_sysl}  ·  kernel ${_krn}"
_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
if [ -n "$_up" ]; then
  _sysl="${_sysl}  ·  up $((_up / 3600))h $(((_up % 3600) / 60))m"
fi
echo "$_sysl"


_abo="$(cat /data/adb/asb/auto_battery_origin 2>/dev/null)"
if [ -n "$_abo" ]; then
  echo ""
  echo "  🔋  ${H_BATT}"
  echo "       switched here automatically · returns to ${_abo} when charged"
fi


# ── Configured vs actually applied ────────────────────────────────────────────── The sections
# above report what the config ASKS for.
# A setting that silently does nothing is invisible everywhere else - that is precisely how
# "DSP +9 dB" shipped for weeks next to a library that was never installed.
_bad=""
_add_bad() { _bad="${_bad}${_bad:+
}       $1"; }

# governor process
pgrep -f 'asb_governor|/asb$' >/dev/null 2>&1 || _add_bad "governor is not running"

# audio profile -> UHQA property
if [ "$_a_prof" = "hifi" ] && [ "$(getprop persist.audio.uhqa 2>/dev/null)" != "1" ]; then
  _add_bad "hi-fi profile — persist.audio.uhqa is not 1 (restart audioserver?)"
fi

# media loudness -> the reshape leaves a marker in the table it rewrote
if [ "$_a_loud" != "stock" ]; then
  grep -q 'ASB:VOLCURVE' /vendor/etc/default_volume_tables.xml 2>/dev/null \
    || _add_bad "loudness ${_a_loud} — volume table not reshaped (reboot needed?)"
fi

# DSP -> library staged AND registered; either half missing means silence
if [ "$_a_dsp" != "off" ]; then
  [ "$_dsp_so" = "1" ] || _add_bad "DSP +${_a_dsp} dB — libasbdsp.so not installed (reinstall)"
  # Two different failures hide behind "not registered", and they need different fixes: the
  # staged copy under /data/adb/asb/odm_patched is what install.sh patches, and a bind mount is
  # what makes it the live file.
  # Patched-but-not-bound means the mount was skipped (bootloop fuse, or the boot counter
  # tripped); not-patched-at-all means install never ran the registration.
  _reg_live=0; _reg_stage=0
  for _ec in $(_asb_effect_files); do
    grep -q 'asb_loudness' "$_ec" 2>/dev/null && { _reg_live=1; break; }
  done
  # Search the whole staged tree AND the module overlay.
  # The old two-path probe missed every device whose effects config lives under a per-SKU
  # directory (sku_cliffs, sku_pineapple, ...), so a registration that had actually landed was
  # still reported as "install never ran the registration" - the wrong fix for the user to be
  # told to apply.
  for _ec in $(find /data/adb/asb/odm_patched \
                    /data/adb/modules/AutoSystemBoost/system \
                    -type f -name 'audio_effects*.xml' 2>/dev/null); do
    grep -q 'asb_loudness' "$_ec" 2>/dev/null && { _reg_stage=1; break; }
  done
  if [ "$_reg_live" != "1" ]; then
    if [ "$_reg_stage" = "1" ]; then
      _add_bad "DSP +${_a_dsp} dB — effect registered but the odm bind is not mounted"
      [ -f /data/adb/asb/vendor_overlay_blocked ] \
        && _add_bad "  (overlay is blocked by the bootloop fuse — see uninstall/reinstall)"
    else
      _add_bad "DSP +${_a_dsp} dB — effect not registered by install (reinstall)"
    fi
  fi
  [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] \
    || _add_bad "DSP +${_a_dsp} dB — persist.asb.dsp.enable is not 1"

fi

# blur -> report WHICH properties took, not just that something did not.
# If the persist ones land and the ro ones do not, the root manager's resetprop cannot touch
# read-only properties on this setup - which is a completely different problem from "the tweak
# did not run".
if [ "$_blur" = "1" ]; then
  # The real switch first. If persist.sys.sf.disable_blurs is 1, SurfaceFlinger has blur
  # off regardless of the capability/oplus keys, so that alone means applied.
  _b_sf="$(getprop persist.sys.sf.disable_blurs 2>/dev/null)"
  _b_ro_bad=0; _b_ro_n=0
  for _bp in ro.surface_flinger.supports_background_blur:0 \
             ro.surface_flinger.media_panel_bg_blur:0 \
             ro.oplus.display.disable.volume_blur:1 \
             ro.oplus.gaussianlevel:0 \
             ro.launcher.blur.appLaunch:0; do
    _bn="${_bp%:*}"; _bw="${_bp##*:}"
    _bv="$(getprop "$_bn" 2>/dev/null)"
    [ -n "$_bv" ] || continue
    _b_ro_n=$((_b_ro_n + 1))
    [ "$_bv" = "$_bw" ] || _b_ro_bad=$((_b_ro_bad + 1))
  done
  _b_ps_bad=0
  [ "$(getprop persist.sys.oplus.anim_level 2>/dev/null)" = "0" ] || _b_ps_bad=$((_b_ps_bad + 1))
  [ "$(getprop persist.sys.oplus.material_blur_switch 2>/dev/null)" = "false" ] || _b_ps_bad=$((_b_ps_bad + 1))

  # persist.sys.sf.disable_blurs is authoritative: if it is 1, blur is off at the
  # SurfaceFlinger level and we are done, whatever the capability keys say.
  if [ "$_b_sf" = "1" ]; then
    :   # applied
  else
    _sp_has=0
    for _spf in /data/adb/modules/AutoSystemBoost/system.prop "$MODDIR/system.prop"; do
      grep -q '^persist.sys.sf.disable_blurs=1' "$_spf" 2>/dev/null && { _sp_has=1; break; }
    done
    if [ "$_sp_has" = "1" ]; then
      _add_bad "blur — set in system.prop (persist.sys.sf.disable_blurs), applies after a reboot"
    else
      _add_bad "blur — persist.sys.sf.disable_blurs not set (${_b_ro_bad}/${_b_ro_n} legacy keys also off)"
    fi
  fi
fi

# wi-fi -> driver domain.
# The check below used to assert a hardcoded "CR", so on every device that has ever had a SIM
# in it this line was guaranteed to fire - a permanent false alarm sitting in NOT APPLIED next
# to two real findings.
if [ "$(_feat WIFI)" = "1" ] && [ -n "$_cc_drv" ] && [ -n "$_cc_want" ] \
   && [ "$_cc_drv" != "$_cc_want" ]; then
  _add_bad "Wi-Fi ${_cc_want} — driver is on ${_cc_drv} (override did not take)"
fi

# camera -> the retouch list is the visible half of the camera patch
if [ "$(_feat CAMERA)" = "1" ] && [ "${_c_lvl:-0}" -gt 0 ] 2>/dev/null; then
  [ "${_vb_n:-0}" -ge 7 ] 2>/dev/null \
    || _add_bad "camera — retouch app list not injected (${_vb_n:-0} apps)"
fi

echo ""
if [ -n "$_bad" ]; then
  echo "  ⚠️  NOT APPLIED"
  echo "$_bad"
else
  echo "  ✅  All configured tweaks verified applied"
fi

echo ""
echo "  ─────────────────────────────"
echo "  💬  Opening Telegram…"
echo ""

am start -a android.intent.action.VIEW -d "tg://resolve?domain=AutoSystemBoost" >/dev/null 2>&1 \
  || am start -a android.intent.action.VIEW -d "https://t.me/AutoSystemBoost" >/dev/null 2>&1

exit 0
