set +x 2>/dev/null
set +v 2>/dev/null

asb_push_old_output() {
  local i=0
  while [ $i -lt 3 ]; do
    ui_print " "
    i=$((i+1))
  done
}

asb_big_banner() {
  asb_push_old_output
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print "      #####      "
  ui_print "     ##      ##     "
  ui_print "    ##        ##    "
  ui_print "   ##          ##   "
  ui_print "  ##            ##  "
  ui_print " ######### "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " "
  ui_print " "
  ui_print "  #########  "
  ui_print " ##              ## "
  ui_print " ##                 "
  ui_print " ##                 "
  ui_print "  #########  "
  ui_print "                   ## "
  ui_print "                   ## "
  ui_print " ##             ## "
  ui_print "  #########  "
  ui_print " "
  ui_print " "
  ui_print " #########  "
  ui_print " ##              ## "
  ui_print " ##              # "
  ui_print " ######## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " #########  "
  ui_print " "
  ui_print "${ASB_HELP:-${ASB_HINT:-[VOL+] Enable | [VOL-] Skip}}"
  ui_print "${SEPARATOR}"
}

asb_normalize_module_layout() {
  for _part in vendor odm product system_ext my_product mi_ext; do
    _root="$MODPATH/$_part"
    [ -e "$_root" ] || continue
    if [ -L "$_root" ]; then continue; fi
    [ -d "$_root" ] || continue

    for _f in $(cd "$_root" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _target="$MODPATH/system/$_part/$_f"
      if [ ! -f "$_target" ]; then
        mkdir -p "$(dirname "$_target")" 2>/dev/null
        cp -f "$_root/$_f" "$_target" 2>/dev/null || true
      fi
    done
    rm -rf "$_root" 2>/dev/null || true
  done

  if [ -f "$INFO" ]; then
    for _part in vendor odm product system_ext my_product mi_ext; do
      sed -i "\|^$MODPATH/$_part/|d" "$INFO" 2>/dev/null || true
    done
  fi

  for _part in vendor odm product system_ext my_product mi_ext; do
    [ -L "$MODPATH/$_part" ] && continue
    [ -d "$MODPATH/$_part" ] && rmdir "$MODPATH/$_part" 2>/dev/null || true
  done

}

asb_end_banner() {
  # A one-glance summary of what ended up enabled - the sections above show the work,
  # this shows the final category picture so the install closes like the action screen.
  _en=""; _en_n=0; _en_line=""
  for _c in CPU VM AUDIO BT NFC CAMERA MEDIA NET WIFI GPS KERNEL LOG LPM \
            RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY; do
    eval "_cv=\"\$ASB_${_c}\""
    [ "$_cv" = "true" ] || continue
    _en_line="${_en_line}${_en_line:+ · }${_c}"
    _en_n=$((_en_n + 1))
    if [ "$_en_n" -ge 5 ]; then
      _en="${_en}${_en:+
}      ${_en_line}"; _en_line=""; _en_n=0
    fi
  done
  [ -n "$_en_line" ] && _en="${_en}${_en:+
}      ${_en_line}"
  if [ -n "$_en" ]; then
    ui_print " "
    ui_print "  📋  ${ASB_SEC_CATEGORIES:-ENABLED CATEGORIES}"
    printf '%s\n' "$_en" | while IFS= read -r _l; do ui_print "$_l"; done
  fi

  if [ -n "$INFO" ] && [ -f "$INFO" ] && [ ! -s "$INFO" ]; then
    rm -f "$INFO" 2>/dev/null || true
  fi
  [ -f "$NVBASE/modules/.$MODID-files" ] && [ ! -s "$NVBASE/modules/.$MODID-files" ] \
    && rm -f "$NVBASE/modules/.$MODID-files" 2>/dev/null || true

  ui_print " "
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "  ${ASB_DONE_TITLE:-✓ AutoSystemBoost installed}"
  ui_print "  ${ASB_DONE_MSG:-Reboot to activate.}"
  ui_print "${SEPARATOR}"
  ui_print " "
  ui_print "      #####      "
  ui_print "     ##      ##     "
  ui_print "    ##        ##    "
  ui_print "   ##          ##   "
  ui_print "  ##            ##  "
  ui_print " ######### "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " "
  ui_print " "
  ui_print "  #########  "
  ui_print " ##              ## "
  ui_print " ##                 "
  ui_print " ##                 "
  ui_print "  #########  "
  ui_print "                   ## "
  ui_print "                   ## "
  ui_print " ##             ## "
  ui_print "  #########  "
  ui_print " "
  ui_print " "
  ui_print " #########  "
  ui_print " ##              ## "
  ui_print " ##              # "
  ui_print " ######## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " ##              ## "
  ui_print " #########  "
  ui_print " "
}

asb_install_prebuilt_governor() {
  local abi src dst
  dst="$MODPATH/bin/asb"
  abi="arm64-v8a"
  src="$MODPATH/bin/$abi/asb"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst" 2>/dev/null || cat "$src" > "$dst"
    chmod 0755 "$dst" 2>/dev/null || true
    ASB_GOV_ABI="$abi"
    return 0
  fi
  return 1
}
sedi() {
  local expr="$1"; shift
  [ -z "$expr" ] && return 0
  local f tmp
  for f in "$@"; do
    [ -f "$f" ] || continue
    tmp="${f}.asbtmp.$$"
    sed "$expr" "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    cat "$tmp" > "$f" 2>/dev/null || true
    rm -f "$tmp"
  done
}
set +x
set +v

SEPARATOR="────────────────────────────────────────────"

LANG="$(settings get system system_locales 2>/dev/null)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop persist.sys.locale)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop ro.product.locale)"
[ -z "$LANG" -o "$LANG" = "null" ] && LANG="$(getprop ro.product.locale.language)-$(getprop ro.product.locale.region)"

if echo "$LANG" | grep -qiE '(^|[, ])ru-|ru_' ; then
  . "$MODPATH/common/russiantext.sh"
else
  . "$MODPATH/common/englishtext.sh"
fi

ASB_SED_INPLACE_MODE=''
_asb_sed_do() {
  local mode="$1"; shift
  if [ "$mode" = "gnu" ]; then
    asb_sed "$@"
  else
    asb_sed "" "$@"
  fi
}
asb_sed() {
  if [ -z "$ASB_SED_INPLACE_MODE" ]; then
    local td="${TMPDIR:-/dev/tmp}"
    [ -d "$td" ] || mkdir -p "$td" 2>/dev/null
    local t="$td/.asb_sedtest.$$"
    echo x > "$t" 2>/dev/null
    if _asb_sed_do gnu 's/x/x/' "$t" >/dev/null 2>&1; then
      ASB_SED_INPLACE_MODE='gnu'
    elif _asb_sed_do bsd 's/x/x/' "$t" >/dev/null 2>&1; then
      ASB_SED_INPLACE_MODE='bsd'
    else
      ASB_SED_INPLACE_MODE='none'
    fi
    rm -f "$t" 2>/dev/null
  fi
  if [ "$ASB_SED_INPLACE_MODE" = 'gnu' ]; then
    _asb_sed_do gnu "$@"
  elif [ "$ASB_SED_INPLACE_MODE" = 'bsd' ]; then
    _asb_sed_do bsd "$@"
  else
    sed "$@"
  fi
}

map_files() {
  local module="$1"
  local dir="$2"
  [ -d "$module/$dir" ] || return 0
  find "$module/$dir" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r abs_path; do
    local rel="${abs_path#$module/}"
    local target="/$rel"
    if [ -e "$target" ]; then
      mount --bind "$abs_path" "$target" 2>/dev/null
    fi
  done
}

asb_has_xmlstarlet() { command -v xmlstarlet >/dev/null 2>&1; }
asb_poll_key() {
  local ev
  exec 7>&2
  exec 2>/dev/null
  ev="$(timeout 0.01 getevent -lqc 1)"
  exec 2>&7
  exec 7>&-

  case "$ev" in
    *KEY_VOLUMEUP*DOWN*)   echo "up" ;;
    *KEY_VOLUMEDOWN*DOWN*) echo "down" ;;
    *) echo "none" ;;
  esac
}

asb_wait_key_timed() {
  local timeout_sec="$1"
  local start now elapsed k
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      echo "none"
      return 0
    fi
    k="$(asb_poll_key)"
    if [ "$k" != "none" ]; then
      echo "$k"
      return 0
    fi
  done
}

asb_show_menu_timed() {
  local timeout_sec="$1"; shift
  local selected=1
  local total=$#
  local start now elapsed current
  start=$(date +%s)

  while true; do
    eval "current=\${$selected}"
    ui_print "➔ $current"
    ui_print " "

    while true; do
      now=$(date +%s)
      elapsed=$((now - start))
      if [ "$elapsed" -ge "$timeout_sec" ]; then
        return 0
      fi

      case "$(asb_poll_key)" in
        up)
          selected=$((selected % total + 1))
          break
          ;;
        down)
          ui_print "[*] Выбрано: $current"
          return "$selected"
          ;;
        *)
          ;;
      esac
    done
  done
}

asb_abort_timeout() {
  ui_print " "
  ui_print "$SEPARATOR"
  ui_print "$ASB_TIMEOUT"
  ui_print "$SEPARATOR"
  abort
}

asb_choose_cat() {
  local cat="$1" title="$2"
  ui_print " "
  ui_print "$SEPARATOR"
  ui_print "$title"
  ui_print " "
  ui_print "$ASB_HINT"
  ui_print " "

  local k
  k="$(asb_wait_key_timed 10)"
  case "$k" in
    up)   eval "ASB_${cat}=true" ;;
    down) eval "ASB_${cat}=false" ;;
    *)    asb_abort_timeout ;;
  esac
}

asb_drop_block_if_off() {
  local cat="$1" file="$2"
  eval "local on=\${ASB_${cat}}"
  [ "$on" = "true" ] && return 0
  [ -f "$file" ] || return 0
  sedi "/^# *ASB:${cat}:BEGIN\$/,/^# *ASB:${cat}:END\$/d" "$file" 2>/dev/null || true
}

asb_prop_first() {
  local v
  for k in "$@"; do
    v="$(getprop "$k" 2>/dev/null)"
    [ -n "$v" ] && [ "$v" != "null" ] && { echo "$v"; return 0; }
  done
  echo ""
}

asb_prop_file_first() {
  local _key _v _f
  for _key in "$@"; do
    for _f in       "$ORIGDIR/system/build.prop" "$ORIGDIR/system/system/build.prop"       "$ORIGDIR/vendor/build.prop" "$ORIGDIR/odm/build.prop"       "$ORIGDIR/product/build.prop" "$ORIGDIR/system_ext/build.prop"       /system/build.prop /system/system/build.prop /vendor/build.prop /odm/build.prop /product/build.prop /system_ext/build.prop; do
      [ -f "$_f" ] || continue
      _v="$(sed -n "s/^${_key}=//p" "$_f" 2>/dev/null | head -n 1)"
      [ -n "$_v" ] && [ "$_v" != "null" ] && { echo "$_v"; return 0; }
    done
  done
  echo ""
}

asb_norm_l() { echo "$*" | tr '[:upper:]' '[:lower:]'; }

asb_detect_compat() {
  ASB_MODEL_RAW="$(asb_prop_file_first ro.product.model ro.product.vendor.model ro.product.system.model ro.product.odm.model ro.product.product.model ro.build.product ro.product.name ro.product.vendor.name)"
  [ -n "$ASB_MODEL_RAW" ] || ASB_MODEL_RAW="$(asb_prop_first ro.product.model ro.product.vendor.model ro.product.system.model ro.product.odm.model ro.product.product.model)"
  ASB_DEVICE_RAW="$(asb_prop_file_first ro.product.device ro.product.vendor.device ro.vendor.product.device ro.product.system.device ro.product.odm.device ro.product.product.device ro.build.product ro.vendor.product.name ro.product.name)"
  [ -n "$ASB_DEVICE_RAW" ] || ASB_DEVICE_RAW="$(asb_prop_first ro.product.device ro.product.vendor.device ro.vendor.product.device ro.product.system.device ro.product.odm.device ro.product.product.device ro.build.product)"
  ASB_MANUFACTURER_RAW="$(asb_prop_file_first ro.product.manufacturer ro.product.vendor.manufacturer ro.vendor.product.manufacturer ro.product.brand ro.product.vendor.brand ro.product.system.brand ro.product.odm.brand)"
  [ -n "$ASB_MANUFACTURER_RAW" ] || ASB_MANUFACTURER_RAW="$(asb_prop_first ro.product.manufacturer ro.product.vendor.manufacturer ro.vendor.product.manufacturer ro.product.brand ro.product.vendor.brand ro.product.system.brand)"
  ASB_PRJ_RAW="$(asb_prop_file_first ro.boot.prjname ro.boot.project)"
  [ -n "$ASB_PRJ_RAW" ] || ASB_PRJ_RAW="$(asb_prop_first ro.boot.prjname ro.boot.project)"
  ASB_FP_RAW="$(asb_prop_file_first ro.build.fingerprint ro.vendor.build.fingerprint ro.system.build.fingerprint ro.bootimage.build.fingerprint)"
  [ -n "$ASB_FP_RAW" ] || ASB_FP_RAW="$(asb_prop_first ro.build.fingerprint ro.vendor.build.fingerprint ro.system.build.fingerprint)"
  ASB_MODEL_L="$(asb_norm_l "$ASB_MODEL_RAW")"
  ASB_DEVICE_L="$(asb_norm_l "$ASB_DEVICE_RAW")"
  ASB_MANUFACTURER_L="$(asb_norm_l "$ASB_MANUFACTURER_RAW")"
  ASB_PRJ_L="$(asb_norm_l "$ASB_PRJ_RAW")"
  ASB_FP_L="$(asb_norm_l "$ASB_FP_RAW")"

  ASB_IS_ONEPLUS=false
  ASB_IS_OP15=false
  ASB_IS_OP13=false
  ASB_IS_OP12=false

  echo "$ASB_MANUFACTURER_L $ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_ONEPLUS=true

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 15"*|*"oneplus15"*|*"op15"*|*"cph274"*|*"cph275"*|*"op611fl1"*|*"plk110"*|*"pjz110"*|*"pkz110"*)
      ASB_IS_OP15=true ;;
  esac

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 13"*|*"oneplus13"*|*"op13"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
      ASB_IS_OP13=true ;;
  esac
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8750"*|*"sun"*)
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"ktm"*|*"plq110"*|*"op6113"*|*"ace 6"*|*"ace6"*)
            ui_print "[*] OnePlus Ace 6 (ktm) on the shared SM8750/sun firmware — generic-safe tuning (no OP13 overlay; its live audio/media sit on /odm and are handled by runtime binds)" ;;
          *"sun"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
            echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP13=true ;;
          *)
            ui_print "[*] SM8750 device, non-OP13 codename — generic-safe tuning (no OP13 overlay, boots on any SM8750 sibling)" ;;
        esac ;;
    esac
  fi

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 12"*|*"oneplus12"*|*"op12"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*)
      ASB_IS_OP12=true ;;
  esac
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ] && [ "$ASB_IS_OP12" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8650"*|*"pineapple"*)
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"pineapple"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*|*"ossi"*|*"22877"*)
            echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP12=true ;;
          *)
            ui_print "[*] SM8650 device, non-OP12 codename — generic-safe tuning (no OP12 overlay, boots on any SM8650 sibling)" ;;
        esac ;;
    esac
  fi

  echo "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(^|[[:space:]/._-])(cph27[45][0-9a-z]*|op611fl1|op611|plk110|pjz110|pkz110|oplus/cph27[45]|oneplus/cph27[45])([[:space:]/._-]|$)' && ASB_IS_OP15=true
  echo "$ASB_PRJ_L" | grep -Eqi '^(24831|24833|24863)$' && ASB_IS_OP15=true

  if [ "$ASB_IS_OP15" != "true" ] && [ -r /proc/cmdline ]; then
    _cmdline_prj="$(cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -i 'prjname=' | cut -d= -f2 | head -1)"
    echo "$_cmdline_prj" | grep -Eqi '^(24831|24833|24863)$' && ASB_IS_OP15=true
    _cmdline_model="$(cat /proc/cmdline 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    echo "$_cmdline_model" | grep -Eqi '(cph274|cph275|op611fl1|plk110|pjz110|pkz110)' && ASB_IS_OP15=true
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    _dt_compat=""
    for _dt_f in /proc/device-tree/compatible \
                 /proc/device-tree/chosen/prj_name \
                 /proc/device-tree/chosen/prjname \
                 /sys/firmware/devicetree/base/compatible; do
      [ -r "$_dt_f" ] || continue
      _dt_val="$(cat "$_dt_f" 2>/dev/null | tr '\0' '\n' | tr '[:upper:]' '[:lower:]')"
      [ -n "$_dt_val" ] && _dt_compat="$_dt_compat $_dt_val"
    done
    echo "$_dt_compat" | grep -Eqi '(cph274|cph275|op611|plk110|pjz110|pkz110|24831|24833|24863|oneplus15|oneplus-15)' && ASB_IS_OP15=true
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    if [ -d /sys/devices/system/cpu/cpufreq/policy6 ]; then
      _max6="$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)"
      if echo "$_max6" | grep -q '^4[56][0-9][0-9][0-9][0-9][0-9]$'; then
        _sm8850_foreign=0
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"macan"*|*"fairlady"*|*"15r"*|*"ace 6t"*|*"ace6t"*|*"15t"*|*"plr110"*|*"plz110"*|*"pmb110"*|*"cph276"*|*"cph277"*)
            _sm8850_foreign=1 ;;
        esac
        if [ "$_sm8850_foreign" != "1" ]; then
          echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP15=true
        else
          ui_print "[*] SM8850 device, non-OP15 codename — generic-safe tuning (no OP15 overlay)"
        fi
      fi
    fi
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    ui_print "[*] Detect debug: manufacturer=$ASB_MANUFACTURER_RAW | model=$ASB_MODEL_RAW | device=$ASB_DEVICE_RAW | prj=$ASB_PRJ_RAW"
  fi
  [ "$ASB_IS_OP15" = "true" ] && ASB_IS_OP13=false && ASB_IS_OP12=false
  [ "$ASB_IS_OP13" = "true" ] && ASB_IS_OP12=false
  # Digital-gain ceiling for asb_patch_one_mixer. SM8650/pineapple (cliffs) WCD/WSA
  # "Digital Volume" controls top out at 0 dB = 84; writing 88 clips and breaks the
  # speaker volume path there. Every other SoC keeps the original +boost to 88.
  _asb_dv_max=88
  case "$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")" in
    *"sm8650"*|*"pineapple"*) _asb_dv_max=84 ;;
  esac
  asb_identify_device
}

# Resolve a human-readable device name for the install log so users of OP13 / OP12 /
# Ace 6 / Ace 5 / etc. no longer see "OnePlus (generic)" or bare "OP15" wording.
asb_identify_device() {
  # 1) OnePlus/OPPO expose the retail marketing name directly — no lookup needed.
  ASB_DEVICE_NAME="$(asb_prop_first \
      ro.vendor.oplus.market.enname ro.oplus.market.enname \
      ro.vendor.oplus.market.name ro.oplus.market.name \
      ro.config.marketing_name ro.product.marketname)"
  ASB_DEVICE_NAME="$(printf '%s' "$ASB_DEVICE_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # 2) Known-model fallback keyed off model / device / project / fingerprint.
  if [ -z "$ASB_DEVICE_NAME" ]; then
    case " $ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L " in
      *" ktm "*|*plq110*|*op6113*|*24851*|*ossi*)   ASB_DEVICE_NAME="OnePlus Ace 6" ;;
      *cph2691*|*op5d3b*)                            ASB_DEVICE_NAME="OnePlus Ace 5" ;;
      *canoe*|*pjz110*|*cph2747*|*cph2749*)          ASB_DEVICE_NAME="OnePlus 15" ;;
      *cph2649*|*cph2653*|*cph2655*|*pjz120*|*sun*)  ASB_DEVICE_NAME="OnePlus 13" ;;
      *cph2661*|*cph2663*|*aston*)                   ASB_DEVICE_NAME="OnePlus 13R" ;;
      *cph2573*|*cph2583*|*cph2581*|*pjd110*)        ASB_DEVICE_NAME="OnePlus 12" ;;
      *cph2609*|*cph2611*|*cph2607*|*waffle*)        ASB_DEVICE_NAME="OnePlus 12R" ;;
    esac
  fi
  # 3) Generic OnePlus by SoC family, then bare model code, then a safe default.
  if [ -z "$ASB_DEVICE_NAME" ]; then
    case "$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")" in
      *sm8850*|*canoe*)     ASB_DEVICE_NAME="OnePlus (SM8850)" ;;
      *sm8750*|*sun*)       ASB_DEVICE_NAME="OnePlus (SM8750)" ;;
      *sm8650*|*pineapple*) ASB_DEVICE_NAME="OnePlus (SM8650)" ;;
    esac
  fi
  [ -z "$ASB_DEVICE_NAME" ] && [ -n "$ASB_MODEL_RAW" ] && ASB_DEVICE_NAME="$ASB_MANUFACTURER_RAW $ASB_MODEL_RAW"
  [ -z "$ASB_DEVICE_NAME" ] && ASB_DEVICE_NAME="OnePlus device"
  ui_print "[*] Device identified: ${ASB_DEVICE_NAME}"
}

ASB_IS_APATCH=false
asb_detect_manager() {
  if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ] || [ -f /data/adb/apd ]; then
    if [ "${KSU:-}" = "true" ] || [ -f /data/adb/ksud ]; then
      [ "${APATCH:-}" = "true" ] && ASB_IS_APATCH=true || ASB_IS_APATCH=false
    else
      ASB_IS_APATCH=true
    fi
  fi
  if [ "$ASB_IS_APATCH" = "true" ]; then
    ui_print "[*] Root manager: APatch (OP12 camera engine exclusion will apply)"
  fi
}

asb_apply_device_overlay() {
  _ov="$1"; _label="$2"
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] $_label detected"
  ui_print "${SEPARATOR}"

  rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/audio" 2>/dev/null || true
  # Safety sweep: a previous build (before the configs-only clone) could have staged
  # multi-MB ML models and calibration blobs into the audio tree, ballooning the module
  # to ~32MB. Delete any such binaries anywhere under the module so an upgrade shrinks
  # back down instead of inheriting the bloat.
  find "$MODPATH/system" -type f \( -name '*.mnn' -o -name '*.onnx' -o -name '*.bin' \
       -o -name '*.dlc' -o -name '*.tflite' \) -delete 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true   # OP12/OP13: strip OP15 multicam set from /odm copy too (ChiMcx crash fix)
  rm -f  "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/izat.conf" 2>/dev/null || true

  if [ -d "$MODPATH/$_ov" ]; then
    _odm_dups() {
      case "$1" in
        vendor/odm/*)
          _sub="${1#vendor/odm/}"
          echo "system/vendor/odm/$_sub"
          ;;
        vendor/*)
          echo "system/$1"
          ;;
        *)
          echo "system/$1"
          ;;
      esac
    }
    if [ "$ASB_GPS" = "true" ]; then
      for _f in vendor/etc/gps.conf vendor/odm/etc/gps.conf \
                vendor/etc/izat.conf vendor/odm/etc/izat.conf; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "      + GPS: $_dst"
          done
        fi
      done
    fi
    if [ "$ASB_CAMERA" = "true" ]; then
      for _cf_rel in vendor/odm/etc/camera/conf_tuning_params.json \
                     vendor/odm/etc/camera/config/video_beauty_default_config; do
        _cf_base="${_cf_rel#vendor/odm/etc/camera/}"
        for _live in "/odm/etc/camera/$_cf_base" \
                     "/vendor/odm/etc/camera/$_cf_base" \
                     "/system/vendor/odm/etc/camera/$_cf_base"; do
          if [ -f "$_live" ] && [ ! -f "$MODPATH/$_ov/$_cf_rel" ]; then
            mkdir -p "$MODPATH/$_ov/$(dirname "$_cf_rel")" 2>/dev/null
            cp -f "$_live" "$MODPATH/$_ov/$_cf_rel" 2>/dev/null \
              && ui_print "      + Camera tone: cloned device-stock $_cf_base"
            break
          fi
        done
      done
      for _f in vendor/etc/media_profiles.xml \
                vendor/odm/etc/camera/media_profiles.xml \
                vendor/odm/etc/camera/conf_tuning_params.json \
                vendor/odm/etc/camera/config/video_beauty_default_config; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "      + Camera/media: $_dst"
          done
        fi
      done
      _ctf="$MODPATH/system/vendor/odm/etc/camera/conf_tuning_params.json"
      _skip_cam_engine=false
      [ "$ASB_IS_OP12" = "true" ] && [ "$ASB_IS_APATCH" = "true" ] && _skip_cam_engine=true
      if [ "$_skip_cam_engine" != "true" ] && [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
        . "$MODPATH/runtime/asb_tweaks.sh"
        asb_tw_save_base "$_ctf" force
        asb_apply_dynamic_tweaks "$MODPATH"
        asb_camera_aggr_flag
        if [ "$_ASB_CAMERA_AGGR" = "1" ] && [ -f "$_ctf" ]; then
          if [ "$_ASB_CAMERA_INJECT" = "1" ]; then
            ui_print "      + ${ASB_D_CAM_AGGR_INJ:-Camera aggressive tone applied (incl. injected keys)}"
          else
            ui_print "      + ${ASB_D_CAM_AGGR_EXIST:-Camera aggressive tone applied (existing keys only)}"
          fi
        fi
      elif [ "$_skip_cam_engine" = "true" ]; then
        ui_print "      + OP12/APatch: ${ASB_D_CAM_STOCK:-camera kept stock (tweak engine skipped)}"
      fi
    fi
  fi

  rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true
  ui_print "      + ${ASB_D_OVERLAY:-overlay patched in place (EQ / volume / hi-res / codecs)}"
}

asb_perf_patch_configstore() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/\(Name="vendor.debug.enable.lm" Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="vendor.debug.enable.memperfd"[^V]*Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.enable.prekill"[^V]*Value="\)true/\1false/g' "$_f"
  sedi 's/\(Name="vendor.perf.topAppRenderThreadBoost.enable" Value="\)false/\1true/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.qape.boost_duration" Value="\)10"/\13"/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.qape.max_boost_count" Value="\)3"/\11"/g' "$_f"
  sedi 's/\(Name="vendor.perf.fps_switch_hyst_time_secs" Value="\)10"/\112"/g' "$_f"
  sedi 's/\(Name="ro.vendor.wlc.exit.timeout" Value="\)120000"/\130000"/g' "$_f"
  sedi 's/\(Name="ro.vendor.perf.active_reqs_max" Value="\)30"/\128"/g' "$_f"
}

asb_perf_patch_gameconfig() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([0-9][0-9]*[ 	][ 	]*[^ 	][^ 	]*[ 	][ 	]*\)48000\([ 	][ 	]*\)1150\([ 	][ 	]*\)1000/\144000\2900\3800/' "$_f"
}

asb_clamp_down_key() {
  _ck_f="$1"; _ck_k="$2"; _ck_ceil="$3"
  [ -f "$_ck_f" ] || return 0
  _ck_cur=$(grep -E "^${_ck_k}=" "$_ck_f" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  case "$_ck_cur" in
    ''|*[!0-9]*) return 0 ;;   # absent or non-numeric -> leave stock
  esac
  if [ "$_ck_cur" -gt "$_ck_ceil" ] 2>/dev/null; then
    sed -i "s/^${_ck_k}=.*/${_ck_k}=${_ck_ceil}/" "$_ck_f" 2>/dev/null || true
  fi
}

asb_patch_one_wcnss() {
  _f="$1"; [ -f "$_f" ] || return 0
  asb_clamp_down_key "$_f" gRuntimePMDelay 2000
  asb_clamp_down_key "$_f" gActiveMaxChannelTime 40
  asb_clamp_down_key "$_f" gBusBandwidthVeryHighThreshold 12000
}

asb_patch_wifi_inplace() {
  _label="$1"
  [ "$ASB_WIFI" = "true" ] || return 0

  _wifi_hit=0
  for _ws in /vendor/etc/wifi /odm/etc/wifi /odm/vendor/etc/wifi /vendor/odm/etc/wifi /system/vendor/etc/wifi; do
    [ -d "$_ws" ] || continue
    # Enumerate the WCNSS config files with BOUNDED SHELL GLOBS — top-level plus up
    # to two nested sku folders (e.g. kiwi_v2/, peach/, peach_v2/). Deliberately NO
    # recursive `find` and NO whole-dir clone: on some devices (Ace 6) paths like
    # /vendor/odm/etc/wifi are bind-mounts of /odm, and a recursive walk can loop
    # through the bind-mount tree and stall the install for minutes. Globs only stat
    # the paths they match — exactly the traversal the old `ls` guard did (which
    # never hung) — while still catching the nested-only layouts the old guard
    # skipped. Only the patched .ini files are cloned, so the overlay stays minimal.
    _dst_root="$MODPATH/system${_ws#/system}"
    for _wf in "$_ws"/WCNSS_qcom_cfg*.ini \
               "$_ws"/*/WCNSS_qcom_cfg*.ini \
               "$_ws"/*/*/WCNSS_qcom_cfg*.ini; do
      [ -f "$_wf" ] || continue
      _rel="${_wf#"$_ws"/}"
      _dst="$_dst_root/$_rel"
      mkdir -p "$(dirname "$_dst")" 2>/dev/null
      cp -f "$_wf" "$_dst" 2>/dev/null || continue
      asb_patch_one_wcnss "$_dst"
      _wifi_hit=1
    done
  done
  [ "$_wifi_hit" = "1" ] || { ui_print "      + ${ASB_D_WIFI_NONE:-no device WCNSS config found — Wi-Fi left stock}"; return 0; }
  ui_print "      + ${ASB_D_WIFI_OK:-WCNSS Wi-Fi config patched (device-native)}"
}

asb_patch_perf_inplace() {
  _label="$1"
  [ "$ASB_CPU" = "true" ] || { ui_print "[*] CPU/perf category off — skipping perf tuning"; return 0; }

  _perfsrc=""
  for _d in /vendor/etc/perf /odm/etc/perf /system/vendor/etc/perf /system_ext/etc/perf; do
    if [ -f "$_d/perfconfigstore.xml" ] || [ -f "$_d/qapegameconfig.txt" ]; then
      _perfsrc="$_d"; break
    fi
  done
  if [ -z "$_perfsrc" ]; then
    ui_print "[*] No stock perf dir found — skipping perf tuning"
    return 0
  fi

  _dst="$MODPATH/system/vendor/etc/perf"
  rm -rf "$_dst" 2>/dev/null || true
  mkdir -p "$_dst" 2>/dev/null

  for _pf in perfconfigstore.xml qapegameconfig.txt perfboostsconfig.xml; do
    if [ -f "$_perfsrc/$_pf" ]; then
      cp -f "$_perfsrc/$_pf" "$_dst/$_pf" 2>/dev/null || continue
      chmod 0644 "$_dst/$_pf" 2>/dev/null || true
    fi
  done

  asb_perf_patch_configstore "$_dst/perfconfigstore.xml"
  if [ -f "$_dst/qapegameconfig.txt" ]; then
    asb_perf_patch_gameconfig "$_dst/qapegameconfig.txt"
  fi
  if [ -f "$_dst/perfboostsconfig.xml" ]; then
    sedi 's/\(Id="0x000010A7"[^>]*Timeout="\)2000"/\11600"/g' "$_dst/perfboostsconfig.xml"
  fi
  _pf_n="$(find "$_dst" -type f 2>/dev/null | wc -l)"
  [ "${_pf_n:-0}" -gt 0 ] && ui_print "      + ${ASB_D_PERF:-perf configs tuned} (${_pf_n} file(s): ${ASB_D_PERF_TAIL:-boost timeouts, game config})"
}

asb_loc_patch_xtwifi() {
  _f="$1"; _model="$2"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*SIZE_BYTE_TOTAL_CACHE[[:space:]]*=[[:space:]]*\)5000000/\132000000/' "$_f"
  sedi 's/^\([[:space:]]*DEBUG_GLOBAL_LOG_LEVEL[[:space:]]*=[[:space:]]*\)2/\10/' "$_f"
  sedi "s/^\([[:space:]]*MODEL_ID_IN_REQUEST_TO_SERVER[[:space:]]*=[[:space:]]*\)\"UNKNOWN\"/\1\"$_model\"/" "$_f"
}
asb_loc_patch_lowi() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*LOWI_LOG_LEVEL[[:space:]]*=[[:space:]]*\)4/\10/' "$_f"
  sedi 's/^\([[:space:]]*LOWI_USE_LOWI_LP[[:space:]]*=[[:space:]]*\)0/\11/' "$_f"
}

asb_loc_patch_gps() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*DEBUG_LEVEL[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\10/'                 "$_f"
  sedi 's/^\([[:space:]]*INTERMEDIATE_POS[[:space:]]*=[[:space:]]*\)0/\11/'                       "$_f"
  sedi 's/^\([[:space:]]*AP_CLOCK_PPM[[:space:]]*=[[:space:]]*\)100/\150/'                        "$_f"
  sedi 's/^\([[:space:]]*AP_TIMESTAMP_UNCERTAINTY[[:space:]]*=[[:space:]]*\)10/\13/'              "$_f"
  sedi 's/^\([[:space:]]*BUFFER_DIAG_LOGGING[[:space:]]*=[[:space:]]*\)1/\10/'                    "$_f"
  sedi 's/^\([[:space:]]*LOC_DIAGIFACE_ENABLED[[:space:]]*=[[:space:]]*\)1/\10/'                  "$_f"
  sedi 's/^\([[:space:]]*LPP_PROFILE[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\115/'                 "$_f"
  sedi 's/^\([[:space:]]*SUPL_VER[[:space:]]*=[[:space:]]*\)0x10000/\10x20000/'                   "$_f"
  sedi 's/^\([[:space:]]*NMEA_REPORT_RATE[[:space:]]*=[[:space:]]*\)NHZ/\11HZ/'                   "$_f"
}

asb_loc_patch_izat() {
  _f="$1"; [ -f "$_f" ] || return 0
  sedi 's/^\([[:space:]]*IZAT_DEBUG_LEVEL[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\10/'             "$_f"
}

asb_media_lift_file() {
  awk -v is_canoe="$2" '
    function lift_sized(b, w, h,   t) {
      t = b
      if (w == 1920 && h == 1080) t = (is_canoe ? 40000000 : 37300000)
      else if (w == 3840 && h == 2160) t = 100000000
      else if (w == 1280 && h == 720)  t = (b < 20000000 ? 20000000 : b)
      if (t < b) t = b
      return t
    }
    # Buffer a whole <Video ...> element (its attributes are split across lines in the
    # stock media_profiles), then lift bitRate by the width/height found ANYWHERE in that
    # element. The old per-line matcher required width, height and bitRate on the same
    # line, which never happens in the OP15 stock format - so 1080p fell through to the
    # unsized bracket bump and landed at 37.3M instead of 40M (a diag FAIL).
    {
      line = $0
      if (in_video) {
        vbuf = vbuf "\n" line
        if (line ~ /\/>/ || line ~ /<\/Video>/) {
          # element complete - lift it
          w = vbuf; h = vbuf
          if (match(vbuf, /width="[0-9]+"/))  { w = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", w); w = w + 0 } else w = 0
          if (match(vbuf, /height="[0-9]+"/)) { h = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", h); h = h + 0 } else h = 0
          if (w > 0 && h > 0 && match(vbuf, /bitRate="[0-9]+"/)) {
            b = substr(vbuf, RSTART, RLENGTH); gsub(/[^0-9]/, "", b); b = b + 0
            nb = lift_sized(b, w, h)
            sub(/bitRate="[0-9]+"/, "bitRate=\"" nb "\"", vbuf)
          }
          printf "%s\n", vbuf
          in_video = 0; vbuf = ""
        }
        next
      }
      if (line ~ /<Video([ \t]|$)/ && line !~ /\/>/) {
        in_video = 1; vbuf = line; next
      }
      # single-line <Video .../> (rare) - handle inline
      if (line ~ /<Video/ && match(line, /width="[0-9]+"/) && match(line, /height="[0-9]+"/)) {
        w = line; sub(/.*width="/, "", w); sub(/".*/, "", w); w = w + 0
        h = line; sub(/.*height="/, "", h); sub(/".*/, "", h); h = h + 0
        if (match(line, /bitRate="[0-9]+"/)) {
          b = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", b); b = b + 0
          nb = lift_sized(b, w, h)
          sub(/bitRate="[0-9]+"/, "bitRate=\"" nb "\"", line)
        }
        print line; next
      }
      print line
    }
    END { if (in_video && vbuf != "") printf "%s\n", vbuf }' "$1" > "$1.asbtmp" 2>/dev/null \
      && mv -f "$1.asbtmp" "$1" 2>/dev/null
}

# Format-agnostic hi-res sampling-rate lifter for audio_policy_configuration.xml.
# For every samplingRates="..." list that already reaches 96000 but stops short of
# 384000, it appends the missing hi-res steps (176400 192000 352800 384000) using
# the SAME delimiter the list already uses — comma OR space. This replaces the old
# pile of exact-string seds (which silently missed Ace 6's space-separated
# "44100 48000 88200 96000" format) and covers OP15/OP13/OP12/Ace and anything
# future. Idempotent: never appends a rate that is already present.
asb_lift_hires_policy() {
  [ -f "$1" ] || return 0
  awk '
  {
    line=$0; out=""
    while (match(line, /samplingRates="[^"]*"/)) {
      pre=substr(line,1,RSTART-1); m=substr(line,RSTART,RLENGTH)
      val=m; sub(/^samplingRates="/,"",val); sub(/"$/,"",val)
      sep=(val ~ /,/)?",":" "
      if (val ~ /(^|[, ])96000([, ]|$)/ && val !~ /(^|[, ])384000([, ]|$)/) {
        nn=split("176400 192000 352800 384000",hr," ")
        for(i=1;i<=nn;i++){ if(val !~ ("(^|[, ])" hr[i] "([, ]|$)")) val=val sep hr[i] }
        m="samplingRates=\"" val "\""
      }
      out=out pre m; line=substr(line,RSTART+RLENGTH)
    }
    print out line
  }' "$1" > "$1.hrtmp" 2>/dev/null \
    && mv -f "$1.hrtmp" "$1" 2>/dev/null
}

asb_patch_media_profiles_inplace() {
  [ "$ASB_MEDIA" = "true" ] || { ui_print "[*] Media category off - skipping media_profiles lift"; return 0; }
  _mpp_done=0
  _ASB_MP_CANOE=0
  case "$(getprop ro.board.platform 2>/dev/null)$(getprop ro.product.device 2>/dev/null)" in
    *canoe*|*sm8850*|*SM8850*) _ASB_MP_CANOE=1 ;;
  esac
  [ "$ASB_IS_OP15" = "true" ] && _ASB_MP_CANOE=1
  _mp_roots="/vendor /system/vendor /system_ext /product"
  if [ "$ASB_IS_OP15" = "true" ] || [ "$ASB_IS_OP13" = "true" ]; then
    _mp_roots="$_mp_roots /odm /system/odm"
  fi
  for _mp_live in $(find $_mp_roots \
                      -type f -name 'media_profiles*.xml' 2>/dev/null \
                      | grep -vE '/vintf/|/manifest' | sort -u); do
    _mp_rel="system${_mp_live}"
    mkdir -p "$MODPATH/$(dirname "$_mp_rel")" 2>/dev/null
    cp -f "$_mp_live" "$MODPATH/$_mp_rel" 2>/dev/null || continue
    chmod 0644 "$MODPATH/$_mp_rel" 2>/dev/null
    asb_media_lift_file "$MODPATH/$_mp_rel" "$_ASB_MP_CANOE"
    _mpp_done=$((_mpp_done + 1))
  done
  [ "$_mpp_done" -gt 0 ] && ui_print "      + media_profiles: ${ASB_D_MEDIA_LIFT:-video bitrate lifted in} $_mpp_done ${ASB_D_MEDIA_TAIL:-device-native file(s)}"
  return 0
}

asb_clone_device_camera_tone() {
  [ "$ASB_CAMERA" = "true" ] || return 0
  for _ct_base in conf_tuning_params.json config/video_beauty_default_config; do
    for _ct_live in "/odm/etc/camera/$_ct_base" \
                    "/vendor/odm/etc/camera/$_ct_base" \
                    "/system/vendor/odm/etc/camera/$_ct_base"; do
      [ -f "$_ct_live" ] || continue
      if [ "$ASB_IS_OP15" = "true" ] || [ "$ASB_IS_OP13" = "true" ]; then
        _ct_dsts="system/vendor/odm/etc/camera/$_ct_base system/odm/etc/camera/$_ct_base"
      else
        _ct_dsts="system/vendor/odm/etc/camera/$_ct_base"
      fi
      for _ct_dst in $_ct_dsts; do
        if [ ! -f "$MODPATH/$_ct_dst" ]; then
          mkdir -p "$MODPATH/$(dirname "$_ct_dst")" 2>/dev/null
          cp -f "$_ct_live" "$MODPATH/$_ct_dst" 2>/dev/null \
            && chmod 0644 "$MODPATH/$_ct_dst" 2>/dev/null
        fi
      done
      ui_print "      + Camera tone: cloned device-stock $_ct_base"
      break
    done
  done
}

asb_patch_location_inplace() {
  _model="$1"
  [ "$ASB_GPS" = "true" ] || { ui_print "[*] GPS category off — skipping location tuning"; return 0; }

  rm -f "$MODPATH/system/vendor/etc/xtwifi.conf" \
        "$MODPATH/system/vendor/odm/etc/xtwifi.conf" \
        "$MODPATH/system/odm/etc/xtwifi.conf" \
        "$MODPATH/system/vendor/etc/lowi.conf" \
        "$MODPATH/system/odm/etc/lowi.conf" 2>/dev/null || true

  for _src in /vendor/etc/xtwifi.conf /odm/etc/xtwifi.conf /vendor/odm/etc/xtwifi.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_xtwifi "$MODPATH/$_rel" "$_model"
      }
    fi
  done
  for _src in /vendor/etc/lowi.conf /odm/etc/lowi.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_lowi "$MODPATH/$_rel"
      }
    fi
  done

  for _src in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_gps "$MODPATH/$_rel"
      }
    fi
  done
  _loc_izat=0
  for _src in /vendor/etc/izat.conf /odm/etc/izat.conf /vendor/odm/etc/izat.conf; do
    if [ -f "$_src" ]; then
      _rel="system${_src}"
      mkdir -p "$MODPATH/$(dirname "$_rel")" 2>/dev/null
      cp -f "$_src" "$MODPATH/$_rel" 2>/dev/null && {
        chmod 0644 "$MODPATH/$_rel" 2>/dev/null
        asb_loc_patch_izat "$MODPATH/$_rel"
        _loc_izat=1
      }
    fi
  done
  ui_print "      + GPS/A-GPS tuned (gps.conf$([ "$_loc_izat" = "1" ] && echo " + izat.conf"))"
}

asb_clone_dir_from_live() {
  _src="$1"
  [ -d "$_src" ] || return 1
  _canon="$_src"
  case "$_canon" in
    /system/*) _canon="${_canon#/system}" ;;
  esac
  _dest="$MODPATH/system${_canon}"
  rm -rf "$_dest" 2>/dev/null
  mkdir -p "$_dest" 2>/dev/null
  # Copy ONLY the text config files ASB actually patches. The audio dir also holds huge
  # binary blobs - noise-suppression ML models (dcunet_nbf.onnx.mnn ~3.5M, oprec_nn_ve.mnn
  # ~1.5M) and mic/camera calibration (.bin, several MB each) - which ASB never touches.
  # Cloning the whole tree pulled ~29MB of that dead weight into the module (3.6MB -> 32MB).
  # Whitelisting extensions keeps the layout ASB needs while dropping the blobs. -maxdepth 6
  # still caps traversal against bind-mount loops (/vendor/odm -> /odm -> ...).
  _clone_n=0
  ( cd "$_src" && find . -maxdepth 6 -type f \
        \( -name '*.xml' -o -name '*.conf' -o -name '*.json' -o -name '*.txt' \
           -o -name '*.ini' -o -name '*.cfg' -o -name 'video_beauty_default_config' \) 2>/dev/null | while IFS= read -r _f; do
      _f="${_f#./}"
      mkdir -p "$_dest/$(dirname "$_f")" 2>/dev/null
      cp -f "$_src/$_f" "$_dest/$_f" 2>/dev/null || true
    done )
  # Prune any now-empty dirs the find above created nothing in.
  find "$_dest" -type d -empty -delete 2>/dev/null || true
  [ -d "$_dest" ] || return 1
  ui_print "      + ${_src} -> system${_canon} (configs only)"
  return 0
}

asb_clone_device_audio_wifi() {
  _label="$1"

  if [ "$ASB_AUDIO" = "true" ]; then
    for _af in mixer_paths.xml ftm_mixer_paths.xml resourcemanager.xml \
               audio_module_config_primary.xml; do
      rm -f "$MODPATH/system/vendor/etc/$_af" 2>/dev/null || true
      rm -f "$MODPATH/system/vendor/odm/etc/$_af" 2>/dev/null || true
    done
    _audio_done=0
    # Merge ALL audio dirs, do not stop at the first that exists. On newer OP15 revisions
    # (e.g. PLK110) /vendor/etc/audio exists but holds only SKU resourcemanager files,
    # while the real mixer_paths lives in /odm/etc/audio. Breaking after the first dir
    # copied /vendor but never reached /odm, so mixer_paths was never cloned and the whole
    # aggressive/EQ/Class-H mixer tune silently did nothing (device diag: 46% pass).
    for _asrc in /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
      if [ -d "$_asrc" ]; then
        asb_clone_dir_from_live "$_asrc" && _audio_done=1
      fi
    done
    # If we still have no mixer_paths anywhere, look wider: some revisions keep it under
    # sku_* subdirs the loop above already covers, but a few stage it beside the codecs.
    if [ -z "$(find "$MODPATH/system/vendor/etc/audio" "$MODPATH/system/odm/etc/audio" \
                    -name 'mixer_paths*.xml' 2>/dev/null | head -1)" ]; then
      for _mxsrc in $(find /vendor /odm /system/vendor -maxdepth 4 -name 'mixer_paths*.xml' 2>/dev/null | head -8); do
        _mxrel="system${_mxsrc#/system}"
        case "$_mxsrc" in /system/*) _mxrel="system${_mxsrc#/system}" ;; *) _mxrel="system${_mxsrc}" ;; esac
        mkdir -p "$MODPATH/$(dirname "$_mxrel")" 2>/dev/null
        cp -f "$_mxsrc" "$MODPATH/$_mxrel" 2>/dev/null && { _audio_done=1; ui_print "      + recovered mixer: ${_mxsrc}"; }
      done
    fi
    [ "$_audio_done" = "1" ] || ui_print "      - no device audio dir found"
  fi

}

asb_patch_one_mixer() {
  _f="$1"; [ -f "$_f" ] || return 0
  # Digital-gain ceiling is device-gated. On SM8650/pineapple (cliffs) the WCD/WSA
  # "Digital Volume" controls top out at 84 (0 dB); writing 88 there put the WSA
  # speaker path out of range so the framework slider stopped attenuating (speaker
  # blasted, and the wedged HAL also killed BT volume). Other codecs (e.g. sun/
  # canoe) accept 88, so they keep the original +boost. _asb_dv_max is set in
  # device detection (default 88; 84 for pineapple).
  _dvmax="${_asb_dv_max:-88}"
  for _v in 80 81 82 83 84 85 86 87; do
    [ "$_v" -ge "$_dvmax" ] 2>/dev/null && continue
    sedi "s/\\(name=\"RX_RX[012] Digital Volume\" value=\"\\)${_v}\"/\\1${_dvmax}\"/g" "$_f"
    sedi "s/\\(name=\"WSA_RX[01] Digital Volume\" value=\"\\)${_v}\"/\\1${_dvmax}\"/g" "$_f"
  done
  sedi 's/\(name="IIR0 Enable Band[1-5]" value="\)1"/\10"/g' "$_f"
  sedi 's/\(name="HPH[LR]_RDAC Switch" value="\)0"/\11"/g' "$_f"
  # Promote the Class-H headphone modes to HIFI. Only the CLS_H_* family is
  # touched — CLS_AB is left alone on purpose: on this codec it is a dedicated
  # <path name="hph-class-ab-mode"> the HAL selects deliberately, so forcing
  # Class-H there would mislabel a genuine Class-AB output. Converting ULP/LOHIFI
  # (the default + hph-highquality/lowpower paths) is enough to satisfy the
  # "RX HPH Mode = CLS_H_HIFI (>=1)" check while staying faithful to the stock tree.
  for _hphm in CLS_H_ULP CLS_H_LOHIFI CLS_H_LP CLS_H_NORMAL; do
    sedi "s/\\(name=\"RX HPH Mode\" value=\"\\)${_hphm}\"/\\1CLS_H_HIFI\"/g" "$_f"
  done
}

asb_patch_audio_inplace_aggr_flag() {
  _ASB_AUDIO_AGGR="$(grep -E '^[[:space:]]*audio_dac_hifi=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # legacy fallback: AUDIO_AGGRESSIVE was the old name of the mixer/DAC half
  [ -n "$_ASB_AUDIO_AGGR" ] || _ASB_AUDIO_AGGR="$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_AUDIO_AGGR" ] || _ASB_AUDIO_AGGR=0
}

asb_camera_aggr_flag() {
  _ASB_CAMERA_LEVEL="$(grep -E '^[[:space:]]*CAMERA_LEVEL=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_ASB_CAMERA_LEVEL" in ''|*[!0-9]*) _ASB_CAMERA_LEVEL="" ;; esac
  _ASB_CAMERA_AGGR="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_CAMERA_AGGR" ] || _ASB_CAMERA_AGGR=0
  if [ -z "$_ASB_CAMERA_LEVEL" ]; then
    [ "$_ASB_CAMERA_AGGR" = "1" ] && _ASB_CAMERA_LEVEL=3 || _ASB_CAMERA_LEVEL=0
  fi
  [ "$_ASB_CAMERA_LEVEL" -gt 0 ] 2>/dev/null && _ASB_CAMERA_AGGR=1 || _ASB_CAMERA_AGGR=0
  _inj_raw="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE_INJECT=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_inj_raw" in
    aggressive|1) _ASB_CAMERA_INJECT=1 ;;
    *)            _ASB_CAMERA_INJECT=0 ;;
  esac
}

asb_guard_v4a_effects() {
  _v4a_ok=0
  for _sd in /odm/etc /vendor/etc /vendor/odm/etc /system/vendor/etc \
             /system/vendor/odm/etc /system/etc; do
    for _sf in "$_sd"/audio_effects.xml "$_sd"/audio_effects_config.xml; do
      if [ -f "$_sf" ] && grep -q 'v4a_re' "$_sf" 2>/dev/null; then
        _v4a_ok=1; break
      fi
    done
    [ "$_v4a_ok" = "1" ] && break
  done
  if [ "$_v4a_ok" = "0" ]; then
    for _sf in $(find /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio -maxdepth 4 \
                      -type f -name "audio_effects*.xml" 2>/dev/null); do
      if grep -q 'v4a_re' "$_sf" 2>/dev/null; then _v4a_ok=1; break; fi
    done
  fi

  if [ "$_v4a_ok" = "1" ]; then
    ui_print "[*] V4A kept — device stock already wires ViPER (libv4a_re.so present)"
    return 0
  fi

  _stripped=0
  for _ef in $(find "$MODPATH/system" -type f -name "audio_effects*.xml" 2>/dev/null); do
    if grep -q 'v4a_re' "$_ef" 2>/dev/null; then
      sedi 's#<effect name="v4a_standard_re"[^/]*/>##g' "$_ef"
      sedi 's#<library name="v4a_re"[^/]*/>##g' "$_ef"
      _stripped=$((_stripped + 1))
    fi
  done
  return 0
}

# Media loudness: reshape the audio-policy volume CURVES (index -> attenuation in
# millibels). Stock OxygenOS attenuates brutally across the usable range — media
# sits at -40 dB at 20% and -17 dB at 60% — which is why "one step too quiet, one
# step too loud" happens and why the phone feels short of volume. Scaling those
# attenuations toward 0 makes every slider position genuinely louder.
#
# ONLY two curves are touched, chosen from the real stream->curve map:
#   DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE  -> MUSIC + ASSISTANT on speaker
#   DEFAULT_MEDIA_VOLUME_CURVE                    -> MUSIC on headset / BT / earpiece
# Deliberately NOT touched: NON_MUTABLE_* (alarms), HEADSET/EXT_MEDIA curves
# (ringtone + notifications), SILENT/FULL_SCALE. Alarms and ringtones keep stock
# loudness. Side effect worth knowing: MEDIA is also referenced by VOICE_CALL and
# BLUETOOTH_SCO on EXT_MEDIA, so BT call audio gets the same lift.
#
# The 100%/0 dB point is never raised above unity, so nothing can clip.
# $1 = file to patch, $2 = scale percent (100 = stock/no-op, 80 = mild, 65 = strong)
asb_reshape_volume_curves() {
  [ -f "$1" ] || return 0
  case "$2" in ''|100) return 0 ;; esac
  grep -q 'ASB:VOLCURVE' "$1" 2>/dev/null && return 0
  awk -v pct="$2" -v targets='|DEFAULT_MEDIA_VOLUME_CURVE|DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE|' '
  BEGIN { cur = 0 }
  {
    line = $0
    if (match(line, /<reference[ \t]+name="[^"]+"/)) {
      seg = substr(line, RSTART, RLENGTH)
      match(seg, /name="[^"]+"/)
      nm = substr(seg, RSTART + 6, RLENGTH - 7)
      cur = (index(targets, "|" nm "|") > 0) ? 1 : 0
    } else if (line ~ /<\/reference>/) {
      cur = 0
    } else if (cur && match(line, /<point>[0-9]+,-[0-9]+<\/point>/)) {
      p = substr(line, RSTART, RLENGTH)
      match(p, />[0-9]+,/);  idx = substr(p, RSTART + 1, RLENGTH - 2)
      match(p, /,-[0-9]+</); mb  = substr(p, RSTART + 1, RLENGTH - 2)
      # Position-weighted, not flat. Scaling every point by the same factor lifts the
      # BOTTOM of the curve hardest in dB terms: at "strong" the 1% step went from
      # -58 dB to -37.7 dB, i.e. +20 dB on the quietest setting the slider has. That
      # ruins quiet listening and buys nothing - nobody is short of volume at 1%. The
      # weight ramps in over the first 40% of travel, so the full boost lands across
      # the range people actually listen at (roughly 40-80%) while the bottom of the
      # slider stays where stock put it. 100%/0 dB is untouched either way: that is
      # unity, and raising it would just clip. Gain above unity is what dsp_loudness is for.
      w = (idx + 0) / 40.0
      if (w > 1) w = 1
      f = 1 - ((100 - pct) / 100.0) * w
      nv = int((mb + 0) * f)
      sub(/<point>[0-9]+,-[0-9]+<\/point>/, "<point>" idx "," nv "</point>", line)
    }
    print line
  }
  END { }
  ' "$1" > "$1.vctmp" 2>/dev/null || { rm -f "$1.vctmp"; return 0; }
  [ -s "$1.vctmp" ] || { rm -f "$1.vctmp"; return 0; }
  printf '<!-- ASB:VOLCURVE:%s -->\n' "$2" >> "$1.vctmp"
  mv -f "$1.vctmp" "$1" 2>/dev/null
}

# Media loudness needs to be patched from a PRISTINE stock copy, because scaling is
# not idempotent and the previous install's overlay may already be shadowing
# /vendor/etc. Stash the untouched stock table on first sight and always rebuild
# from that, so changing the setting (or reverting to stock) is exact.
asb_volume_table_src() {
  _vt_live="/vendor/etc/default_volume_tables.xml"
  [ -f "$_vt_live" ] || return 1
  _vt_stash="/data/adb/asb/stock/default_volume_tables.xml"
  if [ ! -f "$_vt_stash" ]; then
    grep -q 'ASB:VOLCURVE' "$_vt_live" 2>/dev/null && return 1
    mkdir -p /data/adb/asb/stock 2>/dev/null
    cp -f "$_vt_live" "$_vt_stash" 2>/dev/null || return 1
  fi
  printf '%s' "$_vt_stash"
}

# --- ASB DSP effect -----------------------------------------------------------
# Installs libasbdsp.so into the /vendor overlay and registers it in the device's
# audio_effects_config.xml. Registration matters as much as the library: an effect
# nobody attaches is dead weight. We hook it into <postprocess><stream type="music">
# so audioserver attaches it to EVERY music stream automatically -- no companion app,
# and therefore none of the "silent until you open the EQ app" behaviour that the
# session-attached effects suffer from.
ASB_DSP_UUID="a5b10001-7e55-4c60-9f21-415342445350"
ASB_DSP_TYPE="a5b10000-7e55-4c60-9f21-415342545950"

# Stage the effect library into the overlay UNCONDITIONALLY, the way ViperFX and
# friends ship theirs. It used to be installed only when dsp_loudness was already 3/6/9
# at install time - but the audio stage runs long before the user's config is carried
# over from the previous install, so it always read the shipped default (off) and the
# library was never staged. Users who set +9 in the WebUI got "libasbdsp absent" and a
# DSP that silently did nothing.
#
# Shipping it always costs nothing: an effect that is not listed in
# audio_effects_config.xml is never dlopen'd, so an unregistered .so is inert bytes on
# disk (~20 KB). Registration is what dsp_loudness actually gates, and that decision is
# made after the config carry-over where it can see the real value.
#
# 64-bit only on purpose: this platform has no /vendor/lib at all (no 32-bit audio
# processes), and the CI builds arm64-v8a only - an arm64 .so in a 32-bit soundfx dir
# would just fail to load.
asb_install_dsp_lib() {
  _dsp_any=0
  # 64-bit and 32-bit soundfx dirs both exist on the target, and an effect library has
  # to match the bitness of the process that dlopens it - so each gets the .so built
  # for its own ABI. Shipping only lib64 leaves any 32-bit audio path without the
  # effect; shipping the arm64 .so into lib/ would just fail to load.
  for _dsp_pair in \
    "$MODPATH/bin/libasbdsp.so|$MODPATH/system/vendor/lib64/soundfx|/vendor/lib64/soundfx" \
    "$MODPATH/bin/libasbdsp_32.so|$MODPATH/system/vendor/lib/soundfx|/vendor/lib/soundfx"; do
    _dsp_src="${_dsp_pair%%|*}"
    _dsp_rest="${_dsp_pair#*|}"
    _dsp_dir="${_dsp_rest%%|*}"
    _dsp_live="${_dsp_rest##*|}"
    [ -f "$_dsp_src" ] || continue
    mkdir -p "$_dsp_dir" 2>/dev/null || continue
    cp -f "$_dsp_src" "$_dsp_dir/libasbdsp.so" 2>/dev/null || continue
    chmod 0644 "$_dsp_dir/libasbdsp.so" 2>/dev/null
    # Borrow the SELinux label from a real library in the matching live soundfx dir.
    # Without a vendor_file-ish context audioserver is not allowed to dlopen it and the
    # effect silently never loads.
    _dsp_ref=""
    for _c in "$_dsp_live"/*.so; do [ -f "$_c" ] && { _dsp_ref="$_c"; break; }; done
    if [ -n "$_dsp_ref" ]; then
      _dsp_ctx="$(ls -Zd "$_dsp_ref" 2>/dev/null | awk '{print $1}')"
      case "$_dsp_ctx" in
        ?*:?*:?*:?*) chcon "$_dsp_ctx" "$_dsp_dir/libasbdsp.so" 2>/dev/null || true ;;
      esac
    fi
    _dsp_any=1
  done
  [ "$_dsp_any" = "1" ] || return 1
  return 0
}

asb_register_dsp_effect() {
  [ -f "$1" ] || return 0
  grep -q 'asb_loudness' "$1" 2>/dev/null && return 0
  # Either ABI is enough to justify registering the effect: audio_effects_config.xml
  # names the library by filename, and each process picks the soundfx dir matching its
  # own bitness.
  [ -f "$MODPATH/system/vendor/lib64/soundfx/libasbdsp.so" ] \
    || [ -f "$MODPATH/system/vendor/lib/soundfx/libasbdsp.so" ] || return 0
  grep -q '<libraries>' "$1" 2>/dev/null || return 0
  grep -q '<effects>' "$1" 2>/dev/null || return 0
  sedi "s#<libraries>#<libraries>\n        <library name=\"asbdsp\" path=\"libasbdsp.so\"/>#" "$1"
  sedi "s#<effects>#<effects>\n        <effect name=\"asb_loudness\" library=\"asbdsp\" uuid=\"${ASB_DSP_UUID}\" type=\"${ASB_DSP_TYPE}\"/>#" "$1"
  if grep -q '<postprocess>' "$1" 2>/dev/null; then
    sedi "s#<postprocess>#<postprocess>\n        <stream type=\"music\">\n            <apply effect=\"asb_loudness\"/>\n        </stream>#" "$1"
  else
    sedi "s#</effects>#</effects>\n\n    <postprocess>\n        <stream type=\"music\">\n            <apply effect=\"asb_loudness\"/>\n        </stream>\n    </postprocess>#" "$1"
  fi
}

asb_audio_ensure_volume_libs() {
  _aed="$1"
  [ -d "$_aed" ] || return 0
  for _vd in /vendor/lib64/soundfx /vendor/lib/soundfx \
             /odm/lib64/soundfx /odm/lib/soundfx \
             /system/lib64/soundfx /system/lib/soundfx \
             /system/vendor/lib64/soundfx /system/vendor/lib/soundfx; do
    [ -f "$_vd/libv4a_re.so" ] && return 0
  done
  _fixed=0
  for _ef in $(find "$_aed" -type f -name "audio_effects*.xml" 2>/dev/null); do
    grep -q "<libraries>" "$_ef" 2>/dev/null || continue
    if ! grep -q 'name="volume_listener"' "$_ef" 2>/dev/null; then
      sedi '/<libraries>/ a\        <library name="volume_listener" path="libvolumelistener.so"/>' "$_ef"
      _fixed=1
    fi
    if ! grep -q 'name="audio_pre_processing"' "$_ef" 2>/dev/null; then
      sedi '/<libraries>/ a\        <library name="audio_pre_processing" path="libqcomvoiceprocessing.so"/>' "$_ef"
      _fixed=1
    fi
  done
  [ "$_fixed" = "1" ] && ui_print "      + audio_effects: ensured stock volume libs present (device-native)"
  return 0
}

asb_patch_audio_inplace() {
  [ "$ASB_AUDIO" = "true" ] || { ui_print "[*] Audio category off — skipping mixer tune"; return 0; }
  _adir="$MODPATH/system/vendor/etc/audio"
  [ -d "$_adir" ] || { ui_print "[*] No cloned audio dir — skipping mixer tune"; return 0; }

  _n=0
  for _mx in $(find "$_adir" -type f -name "mixer_paths*.xml" 2>/dev/null); do
    asb_patch_one_mixer "$_mx"
    _n=$((_n + 1))
  done

  # Hi-res sampling rates for audio_policy_configuration.xml (what the diag reads
  # for "384000 present"). Lift the audio_policy files already inside the cloned
  # audio dir, PLUS the top-level /vendor/etc one the framework reads first — clone
  # it into the overlay if the device keeps it there. Format-agnostic lifter, so
  # Ace 6's space-separated lists are covered too.
  for _apc in $(find "$_adir" -type f -name "audio_policy_configuration.xml" 2>/dev/null); do
    asb_lift_hires_policy "$_apc"
  done
  if [ -f /vendor/etc/audio_policy_configuration.xml ]; then
    _apd="$MODPATH/system/vendor/etc/audio_policy_configuration.xml"
    [ -f "$_apd" ] || { mkdir -p "$MODPATH/system/vendor/etc" 2>/dev/null; cp -f /vendor/etc/audio_policy_configuration.xml "$_apd" 2>/dev/null; }
    asb_lift_hires_policy "$_apd"
  fi

  # ASB DSP effect: install the library first; the odm-bind stage registers it.
  # Always stage the library; only the registration below is gated on the setting.
  if asb_install_dsp_lib; then
    _dspg="$(grep -E '^[[:space:]]*dsp_loudness=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
    case "$_dspg" in
      ''|off|0|*[!0-9]*) _dspg_ok=0 ;;
      *) [ "$_dspg" -ge 1 ] 2>/dev/null && [ "$_dspg" -le 18 ] 2>/dev/null && _dspg_ok=1 || _dspg_ok=0 ;;
    esac
    if [ "$_dspg_ok" = "1" ]; then
        ui_print "      + ASB ${ASB_D_DSP_ENGINE:-DSP engine}: +${_dspg} dB ${ASB_D_DSP_GAIN:-gain}"
        ui_print "        ${ASB_D_DSP_CHAIN:-soft-knee compressor -> makeup gain -> peak limiter (no clip)}"
        _dsp_abis=""
        [ -f "$MODPATH/system/vendor/lib64/soundfx/libasbdsp.so" ] && _dsp_abis="64-bit"
        [ -f "$MODPATH/system/vendor/lib/soundfx/libasbdsp.so" ] && _dsp_abis="${_dsp_abis:+$_dsp_abis + }32-bit"
        ui_print "        ${ASB_D_DSP_STAGED:-library staged for}: ${_dsp_abis:-none}"
    else
        ui_print "      + ASB DSP: ${ASB_D_DSP_OFF:-library staged, effect off} (dsp_loudness=off)"
    fi
  else
    ui_print "    ! ASB DSP: libasbdsp.so missing from build - skipped"
  fi

  # Media loudness: reshape the MUSIC volume curves from a pristine stock copy.
  _ml="$(grep -E '^[[:space:]]*media_loudness=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  case "$_ml" in
    mild)   _mlpct=80 ;;
    strong) _mlpct=65 ;;
    max)    _mlpct=40 ;;
    *)      _mlpct=100 ;;
  esac
  if [ "$_mlpct" != "100" ]; then
    _vtsrc="$(asb_volume_table_src)"
    if [ -n "$_vtsrc" ] && [ -f "$_vtsrc" ]; then
      _vtd="$MODPATH/system/vendor/etc/default_volume_tables.xml"
      mkdir -p "$MODPATH/system/vendor/etc" 2>/dev/null
      cp -f "$_vtsrc" "$_vtd" 2>/dev/null
      asb_reshape_volume_curves "$_vtd" "$_mlpct"
      case "$_ml" in
        mild)   ui_print "      + ${ASB_D_LOUD:-media loudness}: mild (~+3 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
        strong) ui_print "      + ${ASB_D_LOUD:-media loudness}: strong (~+6 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
        max)    ui_print "      + ${ASB_D_LOUD:-media loudness}: max (~+10 dB ${ASB_D_LOUD_AT:-at mid volume})" ;;
      esac
      ui_print "        ${ASB_D_LOUD_NOTE:-music curves only; alarms/ringtones untouched; 100% never raised}"
    else
      ui_print "    ! media loudness: stock volume table unavailable - skipped"
    fi
  fi

  asb_audio_ensure_volume_libs "$_adir"

  if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
    . "$MODPATH/runtime/asb_tweaks.sh"
    asb_save_dynamic_baselines "$MODPATH"
    asb_apply_dynamic_tweaks "$MODPATH"
  fi
  asb_patch_audio_inplace_aggr_flag
  if [ "$_ASB_AUDIO_AGGR" = "1" ]; then
    ui_print "      + ${ASB_D_MIXER:-mixer}: $_n ${ASB_D_MIXER_TAIL:-file(s) tuned — digital vol 84->88}, flat EQ"
    ui_print "        ${ASB_D_MIXER_AGGR:-Class-H DAC, HPH HIFI mode, compander off (aggressive)}"
  else
    ui_print "      + ${ASB_D_MIXER:-mixer}: $_n ${ASB_D_MIXER_TAIL:-file(s) tuned — digital vol 84->88} (RX+speaker)"
    ui_print "        ${ASB_D_MIXER_STD:-flat EQ, Class-H DAC}"
  fi
}

asb_strip_shipped_static_vendor() {
  rm -rf "$MODPATH/system/vendor/etc/audio" \
         "$MODPATH/system/vendor/odm/etc/audio" \
         "$MODPATH/system/odm/etc/audio" 2>/dev/null || true
  for _af in mixer_paths.xml ftm_mixer_paths.xml resourcemanager.xml \
             audio_module_config_primary.xml; do
    rm -f "$MODPATH/system/vendor/etc/$_af" \
          "$MODPATH/system/vendor/odm/etc/$_af" 2>/dev/null || true
  done
  rm -f "$MODPATH/system/vendor/etc/media_profiles"*.xml \
        "$MODPATH/system/vendor/odm/etc/media_profiles"*.xml \
        "$MODPATH/system/odm/etc/media_profiles"*.xml 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" \
         "$MODPATH/system/odm/etc/camera" \
         "$MODPATH/system/vendor/etc/camera" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/gps.conf" \
        "$MODPATH/system/vendor/etc/izat.conf" \
        "$MODPATH/system/vendor/odm/etc/gps.conf" \
        "$MODPATH/system/vendor/odm/etc/izat.conf" \
        "$MODPATH/system/odm/etc/gps.conf" \
        "$MODPATH/system/odm/etc/izat.conf" 2>/dev/null || true
}

asb_apply_device_native_tuning() {
  _label="$1"
  ui_print " "
  ui_print "  🚀  AutoSystemBoost — ${ASB_SEC_INSTALLING:-installing for} ${_label}"
  ui_print "      ${ASB_SEC_BUILDING:-building a device-native overlay from this phone's own stock files}"
  ui_print " "

  asb_strip_shipped_static_vendor

  # Each stage prints ONE section with an emoji header and a few "+" detail lines, the
  # same shape as the action screen. The stages themselves emit the "+" lines; the
  # orchestrator just prints the header so audio no longer dominates and camera / perf /
  # wifi / gps get equal billing instead of a terse ". stage done".
  ui_print "  🎵  ${ASB_SEC_AUDIO:-AUDIO}"
  asb_clone_device_audio_wifi   "$_label"
  asb_patch_audio_inplace       "$_label"

  ui_print " "
  ui_print "  📷  ${ASB_SEC_CAMERA:-CAMERA}"
  asb_clone_device_camera_tone

  ui_print " "
  ui_print "  🎬  ${ASB_SEC_MEDIA:-MEDIA}"
  asb_patch_media_profiles_inplace

  ui_print " "
  ui_print "  ⚡  ${ASB_SEC_PERF:-PERFORMANCE}"
  asb_patch_perf_inplace        "$_label"

  ui_print " "
  ui_print "  🛰  ${ASB_SEC_LOCATION:-LOCATION}"
  asb_patch_location_inplace    "$2"

  ui_print " "
  ui_print "  📶  ${ASB_SEC_WIFI:-WI-FI}"
  asb_patch_wifi_inplace        "$_label"
  ui_print " "

  if [ "$ASB_AUDIO" = "true" ] || [ "$ASB_CAMERA" = "true" ]; then
    if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
      . "$MODPATH/runtime/asb_tweaks.sh"
      asb_save_dynamic_baselines "$MODPATH" 2>/dev/null || true
      asb_apply_dynamic_tweaks "$MODPATH" 2>/dev/null || true
    fi
  fi

  _man="$MODPATH/generated_overlay_manifest.txt"
  {
    echo "# ASB device-native overlay — $(date '+%F %T')"
    echo "# device: $_label"
    echo "# built by cloning + key-patching this device's own stock files"
    find "$MODPATH/system" -type f \( -path '*/etc/audio/*' -o -path '*/camera/*' \
      -o -name 'media_profiles*.xml' -o -name 'gps.conf' -o -name 'izat.conf' \
      -o -path '*/etc/perf/*' -o -name 'WCNSS_qcom_cfg*.ini' \) 2>/dev/null \
      | sed "s|$MODPATH/||"
  } > "$_man" 2>/dev/null
  cp -f "$_man" /data/adb/asb/generated_overlay_manifest.txt 2>/dev/null || true
  echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null || true
  ui_print " "
  ui_print "  ⚙️  ${ASB_SEC_SYSTEM:-SYSTEM}"
}

asb_prune_non_op15_vendor_overlays() {
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Compatibility mode enabled"
  ui_print "[*] ${ASB_DEVICE_NAME} — not the OP15 reference model"
  ui_print "[*] Keeping script/prop tweaks, pruning reference (OP15) vendor overlays that do not fit this model"
  ui_print "${SEPARATOR}"

  rm -f "$MODPATH/system/etc/permissions/Bluetooth.xml" 2>/dev/null || true
  rm -f "$MODPATH/system/etc/compatconfig/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*a2dp*"xml" 2>/dev/null || true

  rm -f "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true   # OP12/OP13: strip OP15 multicam set from /odm copy too (ChiMcx crash fix)

  rm -f "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true
  for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml usb_audio_policy_configuration.xml virtual_audio_policy_configuration.xml; do
    rm -f "$MODPATH/system/vendor/etc/${_f}" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/${_f}" 2>/dev/null || true
  done
  rm -f "$MODPATH/system/vendor/etc/"media_codecs_*_audio.xml 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true

  rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/etc/xtwifi.conf" 2>/dev/null || true
  rm -f  "$MODPATH/system/vendor/odm/etc/xtwifi.conf" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/lowi.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/gps" 2>/dev/null || true

  find "$MODPATH/system" -type d -empty -print -delete 2>/dev/null || true
}

asb_generate_odm_binds() {
  _ob_root="/data/adb/asb/odm_patched"
  _ob_man="/data/adb/asb/odm_bind_manifest.txt"
  rm -rf "$_ob_root" 2>/dev/null
  rm -f "$_ob_man" 2>/dev/null
  [ -f /data/adb/asb/vendor_overlay_blocked ] && return 0
  [ "$ASB_AUDIO" = "true" ] || [ "$ASB_MEDIA" = "true" ] || return 0
  _ob_canoe=0
  # Every access below touches LIVE /odm paths. On some devices those live under a
  # mount that can stall a bare read/stat during the installer's mount namespace,
  # which would hang the whole flash. Guard each live access with `timeout` when
  # it's available so a stalled path is skipped instead of freezing the install.
  _ob_to=""
  command -v timeout >/dev/null 2>&1 && _ob_to="timeout 20"
  for _ob_t in \
      /odm/etc/audio/audio_policy_configuration.xml \
      /odm/etc/mixer_paths.xml \
      /odm/etc/audio_effects_config.xml \
      /odm/etc/media_profiles_V1_0.xml \
      /odm/etc/camera/media_profiles.xml; do
    ui_print "    . odm-bind check: ${_ob_t}"
    _ob_p="$_ob_root$_ob_t"
    mkdir -p "$(dirname "$_ob_p")" 2>/dev/null
    # guarded cp covers existence, read AND a stalled-mount timeout in one step
    $_ob_to cp -f "$_ob_t" "$_ob_p" 2>/dev/null || continue
    case "$_ob_t" in
      *audio_policy_configuration.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_lift_hires_policy "$_ob_p"
        ;;
      *mixer_paths*.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_patch_one_mixer "$_ob_p"
        ;;
      *media_profiles*.xml)
        [ "$ASB_MEDIA" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_media_lift_file "$_ob_p" "$_ob_canoe"
        ;;
      *audio_effects_config.xml)
        [ "$ASB_AUDIO" = "true" ] || { rm -f "$_ob_p"; continue; }
        asb_register_dsp_effect "$_ob_p"
        ;;
    esac
  done
  ui_print "    . odm-bind: volume libs"
  [ "$ASB_AUDIO" = "true" ] && asb_audio_ensure_volume_libs "$_ob_root/odm/etc"
  ui_print "    . odm-bind: building manifest"
  : > "$_ob_man"
  for _ob_p in $(find "$_ob_root" -type f 2>/dev/null); do
    _ob_t="${_ob_p#$_ob_root}"
    if $_ob_to cmp -s "$_ob_p" "$_ob_t" 2>/dev/null; then
      rm -f "$_ob_p" 2>/dev/null
      continue
    fi
    chmod 0644 "$_ob_p" 2>/dev/null
    _ob_ctx="$($_ob_to ls -Zd "$_ob_t" 2>/dev/null | awk '{print $1}')"
    case "$_ob_ctx" in
      ?*:?*:?*:?*) chcon "$_ob_ctx" "$_ob_p" 2>/dev/null || true ;;
    esac
    echo "$_ob_t|$_ob_p" >> "$_ob_man"
  done
  if [ -s "$_ob_man" ]; then
    ui_print "[*] odm-side audio/media: $(wc -l < "$_ob_man") file(s) patched for runtime bind (the /odm partition itself is never modified)"
  else
    rm -f "$_ob_man" 2>/dev/null
    rm -rf "$_ob_root" 2>/dev/null
  fi
}

asb_reset_learning_on_upgrade_to_v56() {
  _asb_dir="/data/adb/asb"
  _marker="$_asb_dir/learning_reset_done"
  _marker_legacy="$_asb_dir/v56_learning_reset_done"
  if [ -f "$_marker_legacy" ]; then
    [ -f "$_marker" ] || mv -f "$_marker_legacy" "$_marker" 2>/dev/null
    rm -f "$_marker_legacy" 2>/dev/null
  fi
  [ -f "$_marker" ] && return 0   # already done on this device

  _old_prop="$NVBASE/modules/$MODID/module.prop"
  [ -f "$_old_prop" ] || _old_prop="$NVBASE/modules_update/$MODID/module.prop"
  [ -f "$_old_prop" ] || return 0   # no prior install -> nothing learned yet
  _old_vc="$(grep -E '^versionCode=' "$_old_prop" 2>/dev/null | head -1 | sed 's/[^0-9]//g')"
  case "$_old_vc" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_old_vc" -le 550 ] || return 0   # 560+ already has the fixed classifier

  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Upgrade from V55 or earlier: resetting Smart Mode learning"
  ui_print "    (classifier was fixed; old buckets were trained under the buggy"
  ui_print "     one). Your settings and device data are kept."
  ui_print "${SEPARATOR}"

  rm -f "$_asb_dir/buckets.bin" "$_asb_dir/buckets.bin.bak" \
        "$_asb_dir/pstats_balanced.json" "$_asb_dir/pstats_battery.json" \
        "$_asb_dir/smart_appheat.bin" \
        "$_asb_dir/session_history.jsonl" \
        "$_asb_dir/session_history_migrated_v47" \
        "$_asb_dir/auto_battery_state" 2>/dev/null || true

  : > "$_asb_dir/learning_reset_pending" 2>/dev/null || true

  mkdir -p "$_asb_dir" 2>/dev/null
  : > "$_marker" 2>/dev/null
  ui_print "      + learning reset; settings and device data preserved"
}

asb_preserve_user_config() {
  _new_conf="$MODPATH/config/governor.conf"
  _old_conf="$NVBASE/modules/$MODID/config/governor.conf"
  [ -f "$_old_conf" ] || _old_conf="$NVBASE/modules_update/$MODID/config/governor.conf"
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  for _stale_conf in "$_old_conf" "$_snap_conf"; do
    [ -f "$_stale_conf" ] && sed -i '/^[[:space:]]*device_bounds_override=/d' "$_stale_conf" 2>/dev/null || true
  done
  _src=""
  [ -f "$_old_conf" ] && _src="$_old_conf"
  [ -z "$_src" ] && [ -f "$_snap_conf" ] && _src="$_snap_conf"
  if [ -z "$_src" ]; then ui_print "      + ${ASB_D_FRESH:-fresh install — shipped defaults}"; return 0; fi

  # Migrate the retired audio switches. AUDIO_EQ_COMPAT + AUDIO_AGGRESSIVE became
  # audio_profile (software processing) + audio_dac_hifi (codec/mixer).
  # Mapping rationale: the PROPERTY halves of both old switches were unreachable code
  # (service.sh tested them as shell variables it never assigned), so every user was
  # really running the plain baseline == "stock". We therefore only promote to "hifi"
  # when the user had deliberately turned EQ-compat OFF and aggressive ON; the shipped
  # EQ_COMPAT=1 default maps to "stock" so nobody's sound changes silently on update.
  # The mixer half DID work, so audio_dac_hifi carries AUDIO_AGGRESSIVE across exactly.
  if ! grep -qE '^[[:space:]]*audio_profile=' "$_src" 2>/dev/null; then
    _oldeq="$(grep -E '^[[:space:]]*AUDIO_EQ_COMPAT=' "$_src" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    _oldag="$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' "$_src" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
    if [ -n "$_oldeq$_oldag" ]; then
      if [ "$_oldeq" != "1" ] && [ "$_oldag" = "1" ]; then _newp="hifi"; else _newp="stock"; fi
      sed -i "s|^\([[:space:]]*audio_profile=\).*|\1$_newp|" "$MODPATH/config/governor.conf" 2>/dev/null
      if [ "$_oldag" = "1" ]; then
        sed -i "s|^\([[:space:]]*audio_dac_hifi=\).*|\11|" "$MODPATH/config/governor.conf" 2>/dev/null
      fi
      ui_print "      + ${ASB_D_MIGRATED:-audio settings migrated} (profile=${_newp}, hi-fi DAC=${_oldag:-0})"
    fi
  fi

  _user_keys="audio_profile audio_dac_hifi CAMERA_LEVEL CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias \
bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable \
night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale disable_blur media_loudness dsp_loudness"

  _migrated=0
  for _k in $_user_keys; do
    _oldval="$(grep -E "^[[:space:]]*$_k=" "$_src" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
    if [ -z "$_oldval" ] && [ "$_src" != "$_snap_conf" ] && [ -f "$_snap_conf" ]; then
      _oldval="$(grep -E "^[[:space:]]*$_k=" "$_snap_conf" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
    fi
    [ -n "$_oldval" ] || continue
    if grep -qE "^[[:space:]]*$_k=" "$_new_conf" 2>/dev/null; then
      _esc="$(printf '%s' "$_oldval" | sed 's/[&/\|]/\\&/g')"
      sed -i "s|^\\([[:space:]]*$_k=\\).*|\\1$_esc|" "$_new_conf" 2>/dev/null \
        && _migrated=$((_migrated + 1))
    else
      printf '%s=%s\n' "$_k" "$_oldval" >> "$_new_conf"
      _migrated=$((_migrated + 1))
    fi
  done
}

asb_snapshot_user_config() {
  _new_conf="$MODPATH/config/governor.conf"
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  mkdir -p "$(dirname "$_snap_conf")" 2>/dev/null || true
  _keys="audio_profile audio_dac_hifi CAMERA_LEVEL CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale disable_blur media_loudness dsp_loudness"
  {
    echo "# ASB WebUI settings snapshot — survives module update/reinstall"
    for _k in $_keys; do
      _v="$(grep -E "^[[:space:]]*$_k=" "$_new_conf" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d '\r')"
      [ -n "$_v" ] && printf '%s=%s\n' "$_k" "$_v"
    done
  } > "$_snap_conf" 2>/dev/null
  chmod 644 "$_snap_conf" 2>/dev/null || true
}

asb_prune_module() {
  local svc="$MODPATH/service.sh"
  local prop="$MODPATH/system.prop"
  local pfd="$MODPATH/post-fs-data.sh"

  for c in AUDIO BT NFC CAMERA MEDIA CPU VM NET WIFI GPS KERNEL LOG RADIO_IMS DISPLAY FPS SECURITY BG_TRIM; do
    asb_drop_block_if_off "$c" "$svc"
    asb_drop_block_if_off "$c" "$prop"
    asb_drop_block_if_off "$c" "$pfd"
  done

  if [ "${ASB_AUDIO}" != "true" ]; then
    rm -f  "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/audio_effects_config.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/a2dp_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/bluetooth_qti_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/bluetooth_qti_hearing_aid_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/virtual_audio_policy_configuration.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/ftm_mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_c2_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_google_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_google_c2_audio.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/media_codecs_vendor_audio.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/audio_effects_config.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/ftm_mixer_paths.xml" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/virtual_audio_policy_configuration.xml" 2>/dev/null || true
  fi

  if [ "${ASB_BT}" != "true" ]; then
    rm -f "$MODPATH/system/etc/permissions/Bluetooth.xml" 2>/dev/null || true
    rm -f "$MODPATH/system/etc/compatconfig/"*bluetooth*"xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/"*bluetooth*"xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/"*a2dp*"xml" 2>/dev/null || true
  fi

  if [ "${ASB_CAMERA}" != "true" ]; then
    rm -f "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true
  fi
  rm -rf "$MODPATH/system/odm/etc/camera" 2>/dev/null || true
  rm -f  "$MODPATH/system/odm/etc/media_profiles"*".xml" 2>/dev/null || true

  if [ "${ASB_CPU}" != "true" ]; then
    rm -rf "$MODPATH/system/vendor/etc/perf" 2>/dev/null || true
  fi

  if [ "${ASB_WIFI}" != "true" ]; then
    rm -rf "$MODPATH/system/vendor/etc/wifi" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/xtwifi.conf" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/odm/etc/xtwifi.conf" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/vendor/etc/wifi" 2>/dev/null || true
  fi

  if [ "${ASB_GPS}" != "true" ]; then
    rm -f "$MODPATH/system/vendor/etc/lowi.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/izat.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/etc/gps.conf" 2>/dev/null || true
    rm -f "$MODPATH/system/vendor/odm/etc/gps.conf" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/gps" 2>/dev/null || true
  fi

  if [ "${ASB_KERNEL}" != "true" ]; then
    rm -f  "$MODPATH/system/etc/audio_effects.xml" 2>/dev/null || true

    for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml usb_audio_policy_configuration.xml virtual_audio_policy_configuration.xml; do
      rm -f "$MODPATH/system/vendor/etc/${_f}" 2>/dev/null || true
    done
    rm -f  "$MODPATH/system/vendor/etc/"media_codecs_*_audio.xml 2>/dev/null || true

    rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true

    rm -rf "$MODPATH/system/vendor/etc/vendor" 2>/dev/null || true

    for _f in audio_effects_config.xml audio_policy_configuration.xml ftm_mixer_paths.xml mixer_paths.xml resourcemanager.xml virtual_audio_policy_configuration.xml; do
      rm -f "$MODPATH/system/vendor/odm/etc/${_f}" 2>/dev/null || true
    done
    rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
  fi

  if [ "${ASB_LOG}" != "true" ]; then
    rm -rf "$MODPATH/system/etc/init" 2>/dev/null || true
    rm -f  "$MODPATH/system/vendor/etc/mem_logger_config.xml" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/etc/init" 2>/dev/null || true
    rm -rf "$MODPATH/system/vendor/odm/etc/init" 2>/dev/null || true
  fi

  find "$MODPATH/system" -type d -empty -print -delete 2>/dev/null || true
}

ASB_AUDIO=true
ASB_BT=true
ASB_NFC=true
ASB_CAMERA=true
ASB_MEDIA=true
ASB_CPU=true
ASB_VM=true
ASB_NET=true
ASB_WIFI=true
ASB_GPS=true
ASB_KERNEL=true
ASB_LOG=true
ASB_RADIO_IMS=true
ASB_DISPLAY=true
ASB_FPS=true
ASB_SECURITY=true
ASB_BG_TRIM=false

asb_install_prebuilt_governor
asb_big_banner

for _mroot in /data/adb/modules /data/adb/modules_update \
              /data/adb/ksu/modules /data/adb/ksu/modules_update \
              /data/adb/ap/modules /data/adb/ap/modules_update; do
  rm -f  "$_mroot/.AutoSystemBoost-files" 2>/dev/null
  rm -rf "$_mroot/AutoSystemBoost/CLEAR" 2>/dev/null
done

ASB_USER_CFG="/data/adb/asb/user_config"
ASB_USER_CFG_LEGACY="/data/adb/asb_user_config"
ASB_CFG_USED_SAVED=0

if [ -f "$ASB_USER_CFG_LEGACY" ] && [ ! -f "$ASB_USER_CFG" ]; then
  mkdir -p "$(dirname "$ASB_USER_CFG")" 2>/dev/null || true
  mv "$ASB_USER_CFG_LEGACY" "$ASB_USER_CFG" 2>/dev/null || true
fi

asb_apply_saved_config() {
  [ -f "$ASB_USER_CFG" ] || return 1
  local _line _k _v
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|\#*) continue ;; esac
    case "$_k" in
      AUDIO|BT|CAMERA|CPU|VM|NET|WIFI|GPS|KERNEL|LOG|RADIO_IMS|DISPLAY|FPS|SECURITY|BG_TRIM) : ;;
      *) continue ;;
    esac
    case "$_v" in
      1|true) eval "ASB_${_k}=true" ;;
      0|false) eval "ASB_${_k}=false" ;;
    esac
  done < "$ASB_USER_CFG"
  return 0
}

asb_save_user_config() {
  mkdir -p "$(dirname "$ASB_USER_CFG")" 2>/dev/null || true
  {
    echo "# AutoSystemBoost saved user config — auto-generated at install"
    echo "# Edit by hand only if you know what you're doing"
    echo "# Used on next install/update to skip the 15 category prompts"
    echo "saved_at=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    echo "saved_from_version=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)"
    for c in AUDIO BT NFC CAMERA MEDIA CPU VM NET WIFI GPS KERNEL LOG RADIO_IMS DISPLAY FPS SECURITY BG_TRIM; do
      eval "_v=\$ASB_${c}"
      case "$_v" in
        true) printf '%s=1\n' "$c" ;;
        *) printf '%s=0\n' "$c" ;;
      esac
    done
  } > "$ASB_USER_CFG" 2>/dev/null
  chmod 644 "$ASB_USER_CFG" 2>/dev/null || true
  ui_print "  ${ASB_CFG_SAVED_TO:-Config saved to:} $ASB_USER_CFG"
}

if [ -f "$ASB_USER_CFG" ]; then
  _saved_at="$(grep '^saved_at=' "$ASB_USER_CFG" 2>/dev/null | head -1 | cut -d= -f2-)"
  _saved_ver="$(grep '^saved_from_version=' "$ASB_USER_CFG" 2>/dev/null | head -1 | cut -d= -f2-)"
  ui_print ""
  ui_print "================================================"
  ui_print "  ${ASB_CFG_FOUND_TITLE:-Saved configuration found}"
  ui_print "    from: ${_saved_at:-unknown date}"
  ui_print "    ver:  ${_saved_ver:-unknown version}"
  ui_print "  ${ASB_CFG_FOUND_HINT:-VOL+ = use saved | VOL- = re-select}"
  ui_print "================================================"
  _cfg_key="$(asb_wait_key_timed 10)"
  case "$_cfg_key" in
    up)
      ui_print "  ${ASB_CFG_USING_SAVED:-Using saved configuration from:} ${_saved_at:-unknown}"
      if asb_apply_saved_config; then
        ASB_CFG_USED_SAVED=1
      fi
      ;;
    down)
      ui_print "  ${ASB_CFG_RESELECT:-Re-selecting categories...}"
      ;;
    *)
      ui_print "  ${ASB_CFG_USING_SAVED:-Using saved configuration from:} ${_saved_at:-unknown} (timeout default)"
      if asb_apply_saved_config; then
        ASB_CFG_USED_SAVED=1
      fi
      ;;
  esac
fi

if [ "$ASB_CFG_USED_SAVED" -ne 1 ]; then
  asb_choose_cat AUDIO  "$ASB_MENU_AUDIO"
  asb_choose_cat BT     "$ASB_MENU_BT"
  asb_choose_cat CAMERA "$ASB_MENU_CAMERA"
  asb_choose_cat CPU    "$ASB_MENU_CPU"
  asb_choose_cat VM     "$ASB_MENU_VM"
  asb_choose_cat NET    "$ASB_MENU_NET"
  asb_choose_cat WIFI   "$ASB_MENU_WIFI"
  asb_choose_cat GPS    "$ASB_MENU_GPS"
  asb_choose_cat KERNEL "$ASB_MENU_KERNEL"
  asb_choose_cat LOG    "$ASB_MENU_LOG"
  asb_choose_cat RADIO_IMS "$ASB_MENU_RADIO_IMS"
  asb_choose_cat DISPLAY   "$ASB_MENU_DISPLAY"
  asb_choose_cat FPS       "$ASB_MENU_FPS"
  asb_choose_cat SECURITY  "$ASB_MENU_SECURITY"
  asb_choose_cat BG_TRIM   "$ASB_MENU_BG_TRIM"
fi

asb_save_user_config

# MUST come before any stage that reads governor.conf (audio: DSP registration and
# volume curves; camera: level). See asb_preserve_user_config for why.
ui_print " "
ui_print "  💾  ${ASB_SEC_CONFIG:-CONFIG}"
asb_reset_learning_on_upgrade_to_v56
asb_preserve_user_config

if [ -n "${ASB_GOV_ABI:-}" ]; then
  ui_print " "
  ui_print "  🧠  ${ASB_SEC_GOVERNOR:-GOVERNOR}"
  ui_print "      + ${ASB_D_GOV:-native C governor daemon} (${ASB_GOV_ABI})"
fi

asb_detect_compat
asb_detect_manager
ui_print " "
ui_print "  🔍  ${ASB_SEC_DEVICE:-DEVICE}"
ui_print "      + ${ASB_D_IDENTIFIED:-identified}: ${ASB_DEVICE_NAME:-unknown}"
_soc="$(asb_prop_first ro.soc.model ro.board.platform 2>/dev/null)"
[ -n "$_soc" ] && ui_print "      + ${ASB_D_SOC:-SoC}: ${_soc}"
if [ "${ASB_IS_APATCH:-false}" = "true" ]; then _mgr="APatch"
elif [ -n "${KSU:-}" ] || [ -d /data/adb/ksu ]; then _mgr="KernelSU"
elif [ -d /data/adb/magisk ] || [ -n "${MAGISK_VER:-}" ]; then _mgr="Magisk"
else _mgr=""; fi
[ -n "$_mgr" ] && ui_print "      + ${ASB_D_MANAGER:-root manager}: ${_mgr}"
if [ "$ASB_IS_OP15" = "true" ]; then
  ui_print "      + ${ASB_D_FULL_PKG:-full OnePlus 15 device-native package}"
fi
asb_prune_module

if [ -f "$MODPATH/tools/asb_install_probe.sh" ]; then
  sh "$MODPATH/tools/asb_install_probe.sh" "$MODPATH/install_probe.txt" >/dev/null 2>&1 || true
  cp -f "$MODPATH/install_probe.txt" /data/adb/asb/install_probe.txt 2>/dev/null || true
  if [ -f "$MODPATH/install_probe.txt" ]; then
    ui_print "      + ${ASB_D_STOCK_ANALYSIS:-stock-file analysis:}"
    sed -n '/SUMMARY (what ASB can tune/,/Inventory only/p' "$MODPATH/install_probe.txt" 2>/dev/null \
      | grep -E '^[[:space:]]+(audio|wifi|perf|gps|camera|cpu)[[:space:]]+:' \
      | while IFS= read -r _line; do ui_print "        $_line"; done
  fi
fi

if [ "$ASB_IS_OP15" = "true" ]; then
  asb_apply_device_native_tuning "OnePlus 15 (canoe)" "OnePlus15"
  # Register the ASB DSP effect on OP15.
  #
  # OP15 delivers audio config through per-SKU overlay files
  # (system/vendor/etc/audio/sku_*/audio_effects_config.xml), NOT through the /odm
  # runtime binds that asb_generate_odm_binds builds - and asb_generate_odm_binds is
  # the ONLY caller of asb_register_dsp_effect. So on OP15 the library was staged and
  # the properties published, but the effect was never listed in any
  # audio_effects_config.xml, which means audioserver never loaded it. DSP silently did
  # nothing on the one device it was tuned for. Patch every effects config the overlay
  # actually ships so the effect is registered next to the stock ones.
  if [ "$ASB_AUDIO" = "true" ]; then
    _op15_reg=0
    for _ec in \
        "$MODPATH"/system/vendor/etc/audio/sku_*/audio_effects_config.xml \
        "$MODPATH"/system/vendor/odm/etc/audio_effects_config.xml \
        "$MODPATH"/system/odm/etc/audio_effects_config.xml; do
      [ -f "$_ec" ] || continue
      case "$_ec" in *_stub.xml) continue ;; esac
      asb_register_dsp_effect "$_ec"
      grep -q 'asb_loudness' "$_ec" 2>/dev/null && _op15_reg=$((_op15_reg + 1))
    done
    if [ "$_op15_reg" -gt 0 ]; then
      ui_print "      + ASB DSP ${ASB_D_DSP_REG:-effect registered in} ${_op15_reg} ${ASB_D_DSP_REG_TAIL:-audio_effects_config file(s)}"
    else
      ui_print "    ! ASB DSP: no audio_effects_config in overlay to register into"
    fi

    # The /vendor sku_* configs above are NOT what the framework reads on this device.
    # AOSP resolves audio_effects_config.xml as /odm/etc -> /vendor/etc -> /system/etc,
    # and OP15 ships a real /odm/etc/audio_effects_config.xml, so it wins. The OP15 branch
    # never called asb_generate_odm_binds, so that file was untouched: the library was
    # installed and the properties set, but audioserver never listed the effect (verified
    # on device: grep asb /odm/etc/... = 0 while the sku file had 3). Deliver a patched
    # copy through the SAME fuse-guarded runtime bind other devices use - we never graft
    # /odm into the magic-mount tree, which is what bootlooped the Ace 6.
    if [ -f /odm/etc/audio_effects_config.xml ]; then
      _oecs="/data/adb/asb/odm_patched/odm/etc/audio_effects_config.xml"
      _oecm="/data/adb/asb/odm_bind_manifest.txt"
      mkdir -p "$(dirname "$_oecs")" 2>/dev/null
      if cp -f /odm/etc/audio_effects_config.xml "$_oecs" 2>/dev/null; then
        asb_register_dsp_effect "$_oecs"
        if grep -q 'asb_loudness' "$_oecs" 2>/dev/null; then
          chmod 0644 "$_oecs" 2>/dev/null
          _oec_ctx="$(ls -Zd /odm/etc/audio_effects_config.xml 2>/dev/null | awk '{print $1}')"
          case "$_oec_ctx" in
            ?*:?*:?*:?*) chcon "$_oec_ctx" "$_oecs" 2>/dev/null || true ;;
          esac
          touch "$_oecm" 2>/dev/null
          grep -q "^/odm/etc/audio_effects_config.xml|" "$_oecm" 2>/dev/null \
            || echo "/odm/etc/audio_effects_config.xml|$_oecs" >> "$_oecm"
          ui_print "      + ASB DSP registered in /odm/etc/audio_effects_config.xml (runtime bind - the one the framework reads)"
        else
          rm -f "$_oecs" 2>/dev/null
          ui_print "    ! ASB DSP: could not patch the odm effects config"
        fi
      fi
    fi
  fi
elif [ "$ASB_IS_OP13" = "true" ]; then
  asb_apply_device_native_tuning "OnePlus 13 (sun / tuna / kera)" "OnePlus13"
elif [ "$ASB_IS_OP12" = "true" ]; then
  for _stale in \
      "$NVBASE/modules/$MODID/system/odm/etc/camera" \
      "$NVBASE/modules_update/$MODID/system/odm/etc/camera" \
      "$MODPATH/system/odm/etc/camera"; do
    [ -e "$_stale" ] && rm -rf "$_stale" 2>/dev/null || true
  done
  for _stalemp in \
      "$NVBASE/modules/$MODID/system/odm/etc/media_profiles"*.xml \
      "$NVBASE/modules_update/$MODID/system/odm/etc/media_profiles"*.xml; do
    [ -e "$_stalemp" ] && rm -f "$_stalemp" 2>/dev/null || true
  done
  asb_apply_device_native_tuning "OnePlus 12 (pineapple / cliffs)" "OnePlus12"
else
  asb_prune_non_op15_vendor_overlays
  if [ "$ASB_IS_ONEPLUS" = "true" ]; then
    if [ -f /data/adb/asb/vendor_overlay_blocked ] && [ ! -f /data/adb/asb/vendor_overlay_retry_done ]; then
      rm -f /data/adb/asb/vendor_overlay_blocked 2>/dev/null
      : > /data/adb/asb/vendor_overlay_retry_done 2>/dev/null
      ui_print "[*] Non-reference OnePlus: retrying the device overlay once with the odm-safe generator"
    fi
    if [ -f /data/adb/asb/vendor_overlay_blocked ]; then
      ui_print "[*] Non-reference OnePlus: a previous device overlay failed to boot here — staying governor-only"
      ui_print "    (delete /data/adb/asb/vendor_overlay_blocked to let the next install try again)"
      rm -rf "$MODPATH/system/vendor" "$MODPATH/system/odm" 2>/dev/null || true
      for _gen_stale in \
          "$NVBASE/modules/$MODID/system/vendor" \
          "$NVBASE/modules/$MODID/system/odm" \
          "$NVBASE/modules_update/$MODID/system/vendor" \
          "$NVBASE/modules_update/$MODID/system/odm"; do
        [ -e "$_gen_stale" ] && rm -rf "$_gen_stale" 2>/dev/null || true
      done
    else
      echo generic > "$MODPATH/overlay_device_class" 2>/dev/null
      asb_apply_device_native_tuning "$ASB_DEVICE_NAME" "OnePlus"
      rm -rf "$MODPATH/system/odm" "$MODPATH/system/my_product" 2>/dev/null || true
      ui_print "[*] preparing odm runtime binds"
      asb_generate_odm_binds
      ui_print "[*] Non-reference OnePlus: device-native patched overlay, guarded by a 1-strike boot fuse"
    fi
  fi
fi
[ -f "$MODPATH/overlay_device_class" ] || echo reference > "$MODPATH/overlay_device_class" 2>/dev/null
rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true

_gc="$MODPATH/config/governor.conf"
if [ -f "$_gc" ]; then
  _asb_plat="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
  if [ "$ASB_IS_OP15" = "true" ]; then
    sed -i 's/^device_bounds_override=.*/device_bounds_override=1/' "$_gc" 2>/dev/null || true
    ui_print "      + ${ASB_D_BOUNDS:-device-adaptive bounds: ON (OP15 — matches shipped tuning)}"
  else
    case "$_asb_plat" in
      *"sm8650"*|*"pineapple"*)
        # SM8650 1+3+2+1 (Ace5 / OP12 family): the global OP15-shaped rails pin the
        # main interactive cluster low in battery/smart mode (~52%), which reads as
        # UI lag. The per-device synthesis leans those interactive-cluster ceilings
        # UP (lag-safe direction) and snaps them to THIS device's real freq steps,
        # so turn the override on to actually apply them. OP15 unaffected.
        sed -i 's/^device_bounds_override=.*/device_bounds_override=1/' "$_gc" 2>/dev/null || true
        ui_print "[*] Device-adaptive bounds: ON (SM8650 — interactive-cluster caps leaned up to remove battery-mode lag)" ;;
      *)
        sed -i 's/^device_bounds_override=.*/device_bounds_override=0/' "$_gc" 2>/dev/null || true
        ui_print "[*] Device-adaptive bounds: OFF by default on this model (opt-in via WebUI)" ;;
    esac
  fi
fi

asb_localize_region() {
  _cc=""
  _src="none"
  for _p in gsm.sim.operator.iso-country gsm.operator.iso-country; do
    _v="$(getprop "$_p" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    case "$_v" in
      [A-Z][A-Z]) _cc="$_v"; _src="$([ "$_p" = "gsm.sim.operator.iso-country" ] && echo sim || echo operator)"; break ;;
    esac
  done

  if [ -z "$_cc" ]; then
    _allow_locale="$(grep -E '^[[:space:]]*region_allow_locale=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
    if [ "$_allow_locale" = "1" ]; then
      _loc="$(getprop ro.product.locale 2>/dev/null)"
      case "$_loc" in
        *-[A-Za-z][A-Za-z]) _cc="$(echo "$_loc" | sed 's/.*-//' | tr '[:lower:]' '[:upper:]')"; _src="locale" ;;
      esac
    fi
  fi

  ASB_REGION_SOURCE="$_src"
  ASB_REGION_APPLIED="unchanged"

  for _gf in $(find "$MODPATH/system" -type f -iname "gps.conf" 2>/dev/null); do
    [ -f "$_gf" ] && sed -i "s|^NTP_SERVER=.*|NTP_SERVER=pool.ntp.org|g" "$_gf" 2>/dev/null
  done

  if [ -z "$_cc" ]; then
    return 0
  fi

  _wrote=0
  for _wf in $(find "$MODPATH/system" -type f \( -iname "WCNSS_qcom_cfg*.ini" \) 2>/dev/null); do
    [ -f "$_wf" ] || continue
    if grep -q "^gCountryCode=" "$_wf" 2>/dev/null; then
      sed -i "s/^gCountryCode=.*/gCountryCode=$_cc/g" "$_wf" 2>/dev/null && _wrote=1
    fi
  done
  for _wf in $(find "$MODPATH/system" -type f \( -iname "wpa_supplicant*.conf" -o -iname "p2p_supplicant*.conf" \) 2>/dev/null); do
    [ -f "$_wf" ] || continue
    if grep -q "^country=" "$_wf" 2>/dev/null; then
      sed -i "s/^country=.*/country=$_cc/g" "$_wf" 2>/dev/null && _wrote=1
    fi
  done
  if [ "$_wrote" = "1" ]; then
    ASB_REGION_APPLIED="$_cc"
  else
    ASB_REGION_APPLIED="unchanged (modem-driven regdomain)"
  fi
}
asb_localize_region

asb_apply_bt_absvol() {
  _prop="$MODPATH/system.prop"
  [ -f "$_prop" ] || return 0
  _mode="$(grep -E '^[[:space:]]*bt_absvol_mode=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  case "$_mode" in
    on)            _mode="disabled" ;;
    disabled)      _mode="disabled" ;;
    auto|off|''|*) _mode="stock" ;;
  esac
  if [ "$_mode" = "disabled" ]; then _val="true"; else _val="false"; fi
  sed -i "s/^persist.bluetooth.disableabsvol=.*/persist.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  sed -i "s/^persist.vendor.bluetooth.disableabsvol=.*/persist.vendor.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  if [ "$_mode" = "stock" ]; then
    sed -i '/^persist\.bluetooth\.enablenewavrcp=/d' "$_prop" 2>/dev/null
    ASB_BT_ABSVOL_APPLIED="mode=stock (absolute volume ON — loud, synced)"
    return 0
  fi
  ASB_BT_ABSVOL_APPLIED="mode=disabled (absolute volume OFF — phone-side gain)"
  ui_print "      + ${ASB_D_BT:-BT absolute volume: disabled (phone drives gain)}"
  ui_print "        ${ASB_D_BT_NOTE:-(headset drives its own level; use 'stock' if BT starts quiet)}"
}
[ "$ASB_BT" = "true" ] && asb_apply_bt_absvol

# Build the blur block into system.prop at INSTALL time, not in post-fs-data.
#
# Why install time is the only correct place: the root manager (KernelSU here, Magisk
# too) reads $MODPATH/system.prop when it MOUNTS the module, which happens BEFORE
# post-fs-data.sh runs. The previous approach rewrote system.prop from inside
# post-fs-data - i.e. after the manager had already read it - so the fresh block only
# ever took effect a boot later, and since it was rewritten every boot it never caught
# up. ro.* props are read once at process start and cannot be changed afterwards, which
# is why the runtime resetprop calls were rejected too (5/5 ro.* not applied). Writing
# the block here means it is on disk before the very first mount reads it.
asb_apply_blur_prop() {
  _prop="$MODPATH/system.prop"
  [ -f "$_prop" ] || : > "$_prop"
  _db="$(grep -E '^[[:space:]]*disable_blur=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  # Rewrite the managed block from scratch every install so the WebUI toggle drives it.
  # Also strip any BARE (unmarked) copies of these props first: an earlier build wrote
  # them straight into system.prop without markers, and without this cleanup a fresh
  # install would leave both the old bare lines and the new managed block, i.e. the
  # property twice. resetprop/property_service take the last one, but duplicates are
  # confusing and the stale copy could win depending on order.
  _pt="${_prop}.asbblur$$"
  sed -e '/^# ASB:BLUR:BEGIN$/,/^# ASB:BLUR:END$/d' \
      -e '/^ro\.surface_flinger\.supports_background_blur=/d' \
      -e '/^ro\.surface_flinger\.media_panel_bg_blur=/d' \
      -e '/^ro\.oplus\.display\.disable\.volume_blur=/d' \
      -e '/^ro\.oplus\.gaussianlevel=/d' \
      -e '/^ro\.launcher\.blur\.appLaunch=/d' \
      -e '/^persist\.sys\.oplus\.anim_level=/d' \
      -e '/^persist\.sys\.oplus\.material_blur_switch=/d' \
      -e '/^persist\.sys\.sf\.disable_blurs=/d' \
      "$_prop" > "$_pt" 2>/dev/null || cp -f "$_prop" "$_pt"
  {
    echo "# ASB:BLUR:BEGIN"
    if [ "$_db" = "1" ]; then
      # THE switch: persist.sys.sf.disable_blurs is what SurfaceFlinger actually reads to
      # turn blur off, and it is read at the late_start service stage (not at SF's early
      # boot), so a persist.* value set in post-fs-data reaches it in time. The
      # ro.surface_flinger.* keys are capability flags ("hardware can blur"), not
      # switches - forcing them to 0 on a device that already supports blur does nothing,
      # which is why every previous attempt failed. The oplus.* keys are kept as
      # belt-and-braces for ColorOS-specific surfaces.
      echo "persist.sys.sf.disable_blurs=1"
      echo "ro.surface_flinger.supports_background_blur=0"
      echo "ro.surface_flinger.media_panel_bg_blur=0"
      echo "ro.oplus.display.disable.volume_blur=1"
      echo "ro.oplus.gaussianlevel=0"
      echo "ro.launcher.blur.appLaunch=0"
      echo "persist.sys.oplus.anim_level=0"
      echo "persist.sys.oplus.material_blur_switch=false"
    fi
    echo "# ASB:BLUR:END"
  } >> "$_pt"
  mv -f "$_pt" "$_prop" 2>/dev/null || { cat "$_pt" > "$_prop"; rm -f "$_pt"; }
  if [ "$_db" = "1" ]; then
    ui_print "      + ${ASB_D_BLUR:-blur disabled via system.prop (applies after reboot)}"
    ASB_BLUR_APPLIED="disabled"
  else
    ASB_BLUR_APPLIED="stock"
  fi
}
asb_apply_blur_prop

cat > "$MODPATH/features.conf" <<EOF
AUDIO=$([ "$ASB_AUDIO" = "true" ] && echo 1 || echo 0)
BT=$([ "$ASB_BT" = "true" ] && echo 1 || echo 0)
NFC=$([ "$ASB_NFC" = "true" ] && echo 1 || echo 0)
CAMERA=$([ "$ASB_CAMERA" = "true" ] && echo 1 || echo 0)
MEDIA=$([ "$ASB_MEDIA" = "true" ] && echo 1 || echo 0)
CPU=$([ "$ASB_CPU" = "true" ] && echo 1 || echo 0)
VM=$([ "$ASB_VM" = "true" ] && echo 1 || echo 0)
NET=$([ "$ASB_NET" = "true" ] && echo 1 || echo 0)
WIFI=$([ "$ASB_WIFI" = "true" ] && echo 1 || echo 0)
GPS=$([ "$ASB_GPS" = "true" ] && echo 1 || echo 0)
KERNEL=$([ "$ASB_KERNEL" = "true" ] && echo 1 || echo 0)
LOG=$([ "$ASB_LOG" = "true" ] && echo 1 || echo 0)
LPM=1
RADIO_IMS=$([ "$ASB_RADIO_IMS" = "true" ] && echo 1 || echo 0)
DISPLAY=$([ "$ASB_DISPLAY" = "true" ] && echo 1 || echo 0)
FPS=$([ "$ASB_FPS" = "true" ] && echo 1 || echo 0)
SECURITY=$([ "$ASB_SECURITY" = "true" ] && echo 1 || echo 0)
BG_TRIM=$([ "$ASB_BG_TRIM" = "true" ] && echo 1 || echo 0)
VENDOR_OVERLAY=1
EOF

{
  echo "ASB install summary"
  echo "date:            $(date 2>/dev/null || echo n/a)"
  echo "module version:  $(grep -E '^version=' "$MODPATH/module.prop" 2>/dev/null | sed 's/version=//')"
  if [ "$ASB_IS_OP15" = "true" ]; then _dev="OnePlus 15 (full shipped overlay)";
  elif [ "$ASB_IS_OP13" = "true" ]; then _dev="OnePlus 13 (op13 overlay)";
  elif [ "$ASB_IS_OP12" = "true" ]; then _dev="OnePlus 12 (op12 overlay)";
  else _dev="generic OnePlus (sed patches only, vendor overlay pruned)"; fi
  echo "device detected: $_dev"
  echo "  model=$ASB_MODEL_RAW device=$ASB_DEVICE_RAW platform=$(getprop ro.board.platform 2>/dev/null)"
  echo "region source:   ${ASB_REGION_SOURCE:-none}"
  echo "region applied:  ${ASB_REGION_APPLIED:-unchanged}"
  echo "bt absvol:       ${ASB_BT_ABSVOL_APPLIED:-not-applied (BT category off)}"
  echo "camera/media:    $([ "$ASB_CAMERA" = "true" ] && echo applied || echo skipped)"
  echo "gps overlay:     $([ "$ASB_GPS" = "true" ] && echo applied || echo skipped)"
  echo "wifi localized:  $([ "${ASB_REGION_APPLIED:-unchanged}" != "unchanged" ] && echo yes || echo no)"
  echo "audio category:  $([ "$ASB_AUDIO" = "true" ] && echo on || echo off)"
} > "$MODPATH/install_summary.txt" 2>/dev/null
cp -f "$MODPATH/install_summary.txt" /data/adb/asb/install_summary.txt 2>/dev/null || true

if [ -f "$MODPATH/tools/asb_discover.sh" ]; then
  sh "$MODPATH/tools/asb_discover.sh" >/dev/null 2>&1 || true
fi

if [ -f "$MODPATH/tools/asb_synthesize_bounds.sh" ]; then
  sh "$MODPATH/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1 || true
fi

echo 0 > "/data/adb/asb/vendor_boot_counter" 2>/dev/null
# A fresh install must start from a clean slate: drop any skip_mount left by a
# previous build's fuse (it would suppress the whole module incl. asbdiag/webui/
# governor on a device that now boots), and clear a stale generic block/flag.
rm -f "$MODPATH/skip_mount" 2>/dev/null
rm -f /data/adb/asb/vendor_overlay_blocked /data/adb/asb/vendor_overlay_active /data/adb/asb/vendor_overlay_retry_done 2>/dev/null
rm -f "/data/adb/asb/vendor_overlay_active" 2>/dev/null

  for module in $MODPATH/system
  do
    for dir in 'my_product' 'vendor/odm'
    do
      if [[ -d $module/$dir ]]; then
        echo ">> $module/$dir"
        map_files "$module" "$dir"
      fi
    done
  done

ASB_xml() {
  asb_has_xmlstarlet || return 0
  local Name0=$(echo "$3" | sed -r "s|^.*/.*\[@(.*)=\".*\".*$|\1|")
  local Value0=$(echo "$3" | sed -r "s|^.*/.*\[@.*=\"(.*)\".*$|\1|")
  [ "$(echo "$4" | grep '=')" ] && Name1=$(echo "$4" | sed "s|=.*||") || local Name1="value"
  local Value1=$(echo "$4" | sed "s|.*=||")
  case $1 in
  "-s"|"-u"|"-i")
    local SNP=$(echo "$3" | sed -r "s|(^.*/.*)\[@.*=\".*\".*$|\1|")
    local NP=$(dirname "$SNP")
    local SN=$(basename "$SNP")
	if [ "$5" ]; then
      [ "$(echo "$5" | grep '=')" ] && local Name2=$(echo "$5" | sed "s|=.*||") || local Name2="value"
      local Value2=$(echo "$5" | sed "s|.*=||")
	fi
	if [ "$6" ]; then
      [ "$(echo "$6" | grep '=')" ] && local Name3=$(echo "$6" | sed "s|=.*||") || local Name3="value"
      local Value3=$(echo "$6" | sed "s|.*=||")
	fi
	if [ "$7" ]; then
      [ "$(echo "$7" | grep '=')" ] && local Name4=$(echo "$7" | sed "s|=.*||") || local Name4="value"
      local Value4=$(echo "$7" | sed "s|.*=||")
	fi
  ;;
  esac
  case "$1" in
    "-d") xmlstarlet ed -L -d "$3" "$2";;
    "-u") xmlstarlet ed -L -u "$3/@$Name1" -v "$Value1" "$2";;
    "-s")
  	if asb_has_xmlstarlet && [ "$(xmlstarlet sel -t -m "$3" -c . "$2")" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -u "$3/@$Name1" -v "$Value1" "$2"
      else
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -r "$SNP-$MODID" -v "$SN" "$2"
  	fi;;
    "-i")
  	if asb_has_xmlstarlet && [ "$(xmlstarlet sel -t -m "$3[@$Name1=\"$Value1\"]" -c . "$2")" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -d "$3[@$Name1=\"$Value1\"]" "$2"
  	fi
  	if [ -z "$Value3" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -r "$SNP-$MODID" -v "$SN" "$2"
      elif [ "$Value4" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -i "$SNP-$MODID" -t attr -n "$Name3" -v "$Value3" \
        -i "$SNP-$MODID" -t attr -n "$Name4" -v "$Value4" \
        -r "$SNP-$MODID" -v "$SN" "$2"
      elif [ "$Value3" ]; then
        asb_has_xmlstarlet && xmlstarlet ed -L -s "$NP" -t elem -n "$SN-$MODID" \
        -i "$SNP-$MODID" -t attr -n "$Name0" -v "$Value0" \
        -i "$SNP-$MODID" -t attr -n "$Name1" -v "$Value1" \
        -i "$SNP-$MODID" -t attr -n "$Name2" -v "$Value2" \
        -i "$SNP-$MODID" -t attr -n "$Name3" -v "$Value3" \
        -r "$SNP-$MODID" -v "$SN" "$2"
  	fi
      ;;
  esac
}

  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "
  ui_print " "

MPATHS="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "*mixer_path*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APINF="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACONFS="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_configs*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
AEFFECT="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_effects*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_cloud_control*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_policy_configuration*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
A2DPXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "a2dp*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VEHXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "vehicle*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VIRTXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "virtual*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
USBXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "usb*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTQTIXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bluetooth*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APIOCXML="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "audio_output_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "audio_io_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bt_configstore*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF2="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "bt_stack*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
MEDCA="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "media_codecs*audio.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
SNDTRPL="$(find /system /vendor /system_ext /product -depth -type f ! -path "/system/odm/*" ! -path "/system/my_product/*" -iname "sound_trigger_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "resourcemanager*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
if [ -f /data/adb/asb/vendor_overlay_blocked ]; then
  A2DPXML=""; ACCXML=""; ACONFS=""; AEFFECT=""; APCXML=""; APINF=""; APIOCXML=""; BTCONF=""; BTCONF2=""; BTQTIXML=""; MEDCA=""; MPATHS=""; SNDTRPL=""; USBXML=""; VEHXML=""; VIRTXML=""
fi
# Structural audio/BT XML sed-tuning is verified only against OP15/OP13/OP12 stock.
# Detection alone is not enough: SoC siblings (e.g. Ace 6 on the OP15 platform,
# matched via shared model codes) carry a DIFFERENT audio stock, and applying the
# reference seds there corrupted vendor HAL configs (field bootloop). So the gate
# requires the detected family's own audio fingerprint (its sku_* dirs) to be
# physically present on the device before any structural list survives.
_asb_audio_ref=0
_asb_ref_skus=""
[ "$ASB_IS_OP15" = "true" ] && _asb_ref_skus="sku_canoe sku_alor"
[ "$ASB_IS_OP13" = "true" ] && _asb_ref_skus="sku_sun sku_kera sku_tuna"
[ "$ASB_IS_OP12" = "true" ] && _asb_ref_skus="sku_pineapple sku_cliffs"
_asb_sibling=0
if [ -n "$_asb_ref_skus" ]; then
  for _ad in /vendor/etc/audio /system/vendor/etc/audio /odm/etc/audio; do
    [ -d "$_ad" ] || continue
    for _sk in $_asb_ref_skus; do
      ls -d "$_ad/$_sk"* >/dev/null 2>&1 && _asb_audio_ref=1
    done
  done
else
  # Generic path: a platform sibling can carry a KNOWN reference audio stock
  # (field: Ace 6 = ossi/SM8750 ships the OP13 sun/kera/tuna tree, verified
  # byte-identical on the structural files). Grant it the full structural set;
  # the deferred first-clean-boot staging stays on as the safety net.
  for _ad in /vendor/etc/audio /system/vendor/etc/audio /odm/etc/audio; do
    [ -d "$_ad" ] || continue
    for _sk in sku_canoe sku_alor sku_sun sku_kera sku_tuna sku_pineapple sku_cliffs; do
      ls -d "$_ad/$_sk"* >/dev/null 2>&1 && { _asb_audio_ref=1; _asb_sibling=1; _asb_sib_fam="$_sk"; }
    done
  done
  [ "$_asb_sibling" = "1" ] && ui_print "[*] Known reference audio stock on sibling device (family: ${_asb_sib_fam#sku_}) - full structural tuning enabled, deferred-activation safety stays on"
fi
if [ "$_asb_audio_ref" != "1" ]; then
  A2DPXML=""; ACONFS=""; AEFFECT=""; APCXML=""; APINF=""; APIOCXML=""; BTCONF=""; BTCONF2=""; BTQTIXML=""; DAXXML=""; SNDTRPL=""; USBXML=""; VEHXML=""; VIRTXML=""
  if [ -n "$_asb_ref_skus" ]; then
    ui_print "[*] Reference match without native audio stock (platform sibling) - structural audio/BT XML patches skipped; mixer/codec/GPS/Wi-Fi tuning stays on"
  else
    ui_print "[*] Non-reference OnePlus: structural audio/BT XML patches skipped; mixer/codec/GPS/Wi-Fi tuning stays on"
  fi
fi

mkdir -p $MODPATH/tools
EXTTOOLS="$MODPATH/common/addon/External-Tools/tools/$ARCH32"
if [ -d "$EXTTOOLS" ] && ls "$EXTTOOLS"/* >/dev/null 2>&1; then
  mkdir -p "$MODPATH/tools"
  cp -af "$EXTTOOLS"/* "$MODPATH/tools/" >/dev/null 2>&1 || true
fi

  for OACCXML in ${ACCXML}; do
  	ACCXM=$MODPATH${OACCXML}
	cp_ch $ORIGDIR$OACCXML $ACCXM
	sedi "/^ *$/d" $ACCXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
  	SNDTRP=$MODPATH${OSNDTRPL}
	cp_ch $ORIGDIR$OSNDTRPL $SNDTRP
	sedi "/^ *$/d" $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
  	MEDCX=$MODPATH${OMEDCX}
	cp_ch $ORIGDIR$OMEDCX $MEDCX
	sedi "/^ *$/d" $MEDCX
	done

  for OMIX in ${MPATHS}; do
  	MIX=$MODPATH${OMIX}
	cp_ch $ORIGDIR$OMIX $MIX
	sedi "/^ *$/d" $MIX
	done

  if [ "${ASB_BT}" = "true" ]; then
  for OA2DPXML in ${A2DPXML}; do
  	A2DPXM=$MODPATH${OA2DPXML}
	cp_ch $ORIGDIR$OA2DPXML $A2DPXM
	sedi '/^ *$/d' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
  	BTQTIXM=$MODPATH${OBTQTIXML}
	cp_ch $ORIGDIR$OBTQTIXML $BTQTIXM
	sedi '/^ *$/d' $BTQTIXM
	done

  fi

  for OVEHXML in ${VEHXML}; do
  	VEHXM=$MODPATH${OVEHXML}
	cp_ch $ORIGDIR$OVEHXML $VEHXM
	sedi "/^ *$/d" $VEHXM
	done

  for OVIRTXML in ${VIRTXML}; do
  	VIRTXM=$MODPATH${OVIRTXML}
	cp_ch $ORIGDIR$OVIRTXML $VIRTXM
	sedi "/^ *$/d" $VIRTXM
	done

  for OUSBXML in ${USBXML}; do
  	USBXM=$MODPATH${OUSBXML}
	cp_ch $ORIGDIR$OUSBXML $USBXM
	sedi "/^ *$/d" $USBXM
	done

  for OAPCXM in ${APCXML}; do
  	APCXM=$MODPATH${OAPCXM}
	cp_ch $ORIGDIR$OAPCXM $APCXM
	sedi "/^ *$/d" $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
  	APIOCXM=$MODPATH${OAPIOCXM}
	cp_ch $ORIGDIR$OAPIOCXM $APIOCXM
	sedi "/^ *$/d" $APIOCXM
	done

  for OAPLI in ${APINF}; do
  	APLI=$MODPATH${OAPLI}
	cp_ch $ORIGDIR$OAPLI $APLI
	sedi "/^ *$/d" $APLI
	done

  for OACONF in ${ACONFS}; do
  	ACONF=$MODPATH${OACONF}
	cp_ch $ORIGDIR$OACONF $ACONF
	sedi "/^ *$/d" $ACONF
	done

  _v4a_lib=""
  for _vd in /vendor/lib64/soundfx /vendor/lib/soundfx \
             /odm/lib64/soundfx /odm/lib/soundfx \
             /system/lib64/soundfx /system/lib/soundfx \
             /system/vendor/lib64/soundfx /system/vendor/lib/soundfx; do
    if [ -f "$_vd/libv4a_re.so" ]; then _v4a_lib="$_vd/libv4a_re.so"; break; fi
  done
  for OAEFFECT in ${AEFFECT}; do
  	EFFECT=$MODPATH${OAEFFECT}
	sedi '/"audiosphere"/d' $EFFECT
	if [ -n "$_v4a_lib" ]; then
	  sedi '/effect name="volume"/d' $EFFECT
	  sedi '/"dvl"/d' $EFFECT
	  sedi '/"agc"/d' $EFFECT
	  sedi '/"volume_listener"/d' $EFFECT
	  sedi '/"audio_pre_processing"/d' $EFFECT
	  sedi '/v4a_standard_re/d' $EFFECT
	  sedi '/v4a_re/d' $EFFECT
	  sedi '/<libraries>/ a\\        <library name=\\"v4a_re\\" path=\\"libv4a_re.so\\"\\/>' $EFFECT
	  sedi '/<effects>/ a\\        <effect name=\\"v4a_standard_re\\" library=\\"v4a_re\\" uuid=\\"90380da3-8536-4744-a6a3-5731970e640f\\"\\/>' $EFFECT
	fi
	done

  for OACCXML in ${ACCXML}; do
  	ACCXM=$MODPATH${OACCXML}
	sedi '/<kara_app_name_list>/a\
        <com.neutroncode.mp/>\
        <ru.yandex.music/>\
        <com.hitrolab.audioeditor/>\
        <com.google.android.youtube/>\
        <com.google.android.youtube.music/>\
        <com.mxtech.videoplayer/>\
        <com.mxtech.videoplayer.pro/>\
        <com.spotify.music/>\
        <com.apple.android.music/>\
        <deezer.android.app/>\
        <com.vkontakte.android/>\
        <com.uma.musicvk/>\
        <com.vk.clips/>\
        <ru.ok.android/>\
        <com.facebook.katana/>\
        <com.instagram.android/>\
        <tunein.player/>\
        <free.zaycev.net/>\
        <fm.last.android/>\
        <com.aspiro.tidal/>\
        <com.qobuz.music/>\
        <com.extreamsd.usbaudioplayerpro/>\
        <com.zvooq.openplay/>\
        <com.jetappfactory.jetaudio/>\
        <com.jetappfactory.jetaudioplus/>\
		<ru.mts.music.android/>\
        <com.maxmpz.audioplayer/>' $ACCXM
	sedi '/<record_unsilence_app_name_list>/a\
        <com.SearingMedia.Parrot/>\
        <com.hitrolab.audioeditor/>' $ACCXM
	done
	
  if [ "${ASB_BT}" = "true" ]; then
  for OBTCONF in ${BTCONF}; do
  	BTCON=$MODPATH${OBTCONF}
	sedi 's/aacFrameCtlEnabled = true/aacFrameCtlEnabled = false/g' $BTCON
	done

  for OBTCONF2 in ${BTCONF2}; do
  	BTCON2=$MODPATH${OBTCONF2}
	sedi 's/TraceConf=true/TraceConf=false/g' $BTCON2
	sedi 's/TRC_BTM=2/TRC_BTM=0/g' $BTCON2
	sedi 's/TRC_HCI=2/TRC_HCI=0/g' $BTCON2
	sedi 's/TRC_L2CAP=2/TRC_L2CAP=0/g' $BTCON2
	sedi 's/TRC_RFCOMM=2/TRC_RFCOMM=0/g' $BTCON2
	sedi 's/TRC_OBEX=2/TRC_OBEX=0/g' $BTCON2
	sedi 's/TRC_AVCT=2/TRC_AVCT=0/g' $BTCON2
	sedi 's/TRC_AVDT=2/TRC_AVDT=0/g' $BTCON2
	sedi 's/TRC_AVRC=2/TRC_AVRC=0/g' $BTCON2
	sedi 's/TRC_AVDT_SCB=2/TRC_AVDT_SCB=0/g' $BTCON2
	sedi 's/TRC_AVDT_CCB=2/TRC_AVDT_CCB=0/g' $BTCON2
	sedi 's/TRC_A2D=2/TRC_A2D=0/g' $BTCON2
	sedi 's/TRC_SDP=2/TRC_SDP=0/g' $BTCON2
	sedi 's/TRC_SMP=2/TRC_SMP=0/g' $BTCON2
	sedi 's/TRC_BTAPP=2/TRC_BTAPP=0/g' $BTCON2
	sedi 's/TRC_BTIF=2/TRC_BTIF=0/g' $BTCON2
	sedi 's/TRC_BNEP=2/TRC_BNEP=0/g' $BTCON2
	sedi 's/TRC_PAN=2/TRC_PAN=0/g' $BTCON2
	sedi 's/TRC_HID_HOST=2/TRC_HID_HOST=0/g' $BTCON2
	sedi 's/TRC_HID_DEV=2/TRC_HID_DEV=0/g' $BTCON2
	sedi 's/TRC_GATT=2/TRC_GATT=0/g' $BTCON2
	done

  fi

  for ODAXXML in ${DAXXML}; do
  	DAXXM=$MODPATH${ODAXXML}
	sedi 's/mi-dv-leveler-steering-enable value="true"/mi-dv-leveler-steering-enable value="false"/g' $DAXXM
	sedi 's/mi-surround-compressor-steering-enable value="true"/mi-surround-compressor-steering-enable value="false"/g' $DAXXM
	sedi 's/mi-dialog-enhancer-steering-enable value="false"/mi-dialog-enhancer-steering-enable value="true"/g' $DAXXM
	sedi 's/mi-ieq-steering-enable value="false"/mi-ieq-steering-enable value="true"/g' $DAXXM
	sedi 's/mi-adaptive-virtualizer-steering-enable value="false"/mi-adaptive-virtualizer-steering-enable value="true"/g' $DAXXM
	sedi 's/low-filter-mode value="1"/low-filter-mode value="0"/g' $DAXXM
	sedi 's/band-filter-mode value="1"/band-filter-mode value="0"/g' $DAXXM
	sedi 's/middle-filter-mode value="1"/middle-filter-mode value="0"/g' $DAXXM
	sedi 's/height-filter-mode value="1"/height-filter-mode value="0"/g' $DAXXM
	sedi 's/volume-leveler-compressor-enable value="true"/volume-leveler-compressor-enable value="false"/g' $DAXXM
	sedi 's/hearing-protection-enable value="true"/hearing-protection-enable value="false"/g' $DAXXM
	sedi 's/regulator-speaker-dist-enable value="true"/regulator-speaker-dist-enable value="false"/g' $DAXXM
	sedi 's/bass-mbdrc-enable value="true"/bass-mbdrc-enable value="false"/g' $DAXXM
	sedi 's/bass-extraction-enable value="true"/bass-extraction-enable value="false"/g' $DAXXM
	sedi 's/reverb-suppression-enable value="true"/reverb-suppression-enable value="false"/g' $DAXXM
	sedi 's/audio-optimizer-enable value="true"/audio-optimizer-enable value="false"/g' $DAXXM
	sedi 's/regulator-sibilance-suppress-enable value="true"/regulator-sibilance-suppress-enable value="false"/g' $DAXXM
	sedi 's/ieq-enable value="true"/ieq-enable value="false"/g' $DAXXM
	sedi 's/complex-equalizer-enable value="true"/complex-equalizer-enable value="false"/g' $DAXXM
	sedi 's/virtual-bass-process-enable value="true"/virtual-bass-process-enable value="false"/g' $DAXXM
	sedi 's/virtualizer-enable value="true"/virtualizer-enable value="false"/g' $DAXXM
	sedi 's/bass-enhancer-enable value="false"/bass-enhancer-enable value="true"/g' $DAXXM
	sedi 's/dialog-enhancer-enable value="true"/dialog-enhancer-enable value="false"/g' $DAXXM
	sedi 's/graphic-equalizer-enable value="false"/graphic-equalizer-enable value="true"/g' $DAXXM
	sedi 's/surround-decoder-enable value="false"/surround-decoder-enable value="true"/g' $DAXXM
	sedi 's/volume-leveler-enable value="false"/volume-leveler-enable value="true"/g' $DAXXM
	sedi 's/volume-modeler-enable value="true"/volume-modeler-enable value="false"/g' $DAXXM
	sedi 's/tuned_rate="48000"/tuned_rate="96000"/g' $DAXXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
  	SNDTRP=$MODPATH${OSNDTRPL}
	sedi 's/"hifi_filter" value="false"/"hifi_filter" value="true"/g' $SNDTRP
	sedi 's/ec_ref="true"/ec_ref="false"/g' $SNDTRP
	sedi 's/support_nlpi_switch="false"/support_nlpi_switch="true"/g' $SNDTRP
	sedi 's/transit_to_non_lpi_on_charging="false"/transit_to_non_lpi_on_charging="true"/g' $SNDTRP
	sedi 's/support_non_lpi_without_ec="true"/support_non_lpi_without_ec="false"/g' $SNDTRP
	sedi 's/low_latency_bargein_enable="false"/low_latency_bargein_enable="true"/g' $SNDTRP
	sedi 's/enable_debug_dumps="true"/enable_debug_dumps="false"/g' $SNDTRP
	sedi 's/acd_enable="false"/acd_enable="true"/g' $SNDTRP
	sedi '/logging_level/d' $SNDTRP
	sedi 's/mmap_enable="false"/mmap_enable="true"/g' $SNDTRP
	sedi 's/"enc"/"enc|dec"/g' $SNDTRP
	sedi 's/"dec"/"enc|dec"/g' $SNDTRP
	sedi 's/sidetone_mode>HW/sidetone_mode>OFF/g' $SNDTRP
	sedi 's/sidetone_mode>SW/sidetone_mode>OFF/g' $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
  	MEDCX=$MODPATH${OMEDCX}
	sedi 's/name="sample-rate" ranges="8000,11025,12000,16000,22050,24000,32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="7350,8000,11025,12000,16000,22050,24000,32000,44100,48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-48000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-96000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="sample-rate" ranges="8000-192000"/name="sample-rate" ranges="1-192000"/g' $MEDCX
	sedi 's/name="bitrate-modes" value="CBR"/name="bitrate-modes" value="CQ"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="9"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="8"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="7"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-10"  default="6"/name="complexity" range="0-10"  default="10"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="7"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="6"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="5"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="complexity" range="0-8"  default="4"/name="complexity" range="0-8"  default="8"/g' $MEDCX
	sedi 's/name="quality" range="0-80"  default="100"/name="quality" range="0-100"  default="100"/g' $MEDCX
	sedi 's/name="bitrate" range="8000-320000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="8000-960000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-500000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="6000-510000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="1-10000000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="500-512000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-640000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="32000-6144000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="16000-2688000"/name="bitrate" range="1-18000000"/g' $MEDCX
	sedi 's/name="bitrate" range="64000"/name="bitrate" range="1-18000000"/g' $MEDCX
	done

  for OAPLI in ${APINF}; do
  	APLI=$MODPATH${OAPLI}
	sedi 's/bit_width="16"/bit_width="32"/g' $APLI
	sedi 's/bit_width="24"/bit_width="32"/g' $APLI
	sedi '/<bit_width_configs/a\
    <device name="SND_DEVICE_OUT_SPEAKER" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_HEADPHONES" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_SPEAKER_REVERSE" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_SPEAKER_PROTECTED" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_HEADPHONES_44_1" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_GAME_SPEAKER" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_GAME_HEADPHONES" bit_width="32"/>\
    <device name="SND_DEVICE_OUT_BT_A2DP" bit_width="32"/>' $APLI
	done

  for OA2DPXML in ${A2DPXML}; do
  	A2DPXM=$MODPATH${OA2DPXML}
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $A2DPXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $A2DPXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $A2DPXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $A2DPXM
	sedi 's/samplingRates="44100"/samplingRates="96000"/g' $A2DPXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $A2DPXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $A2DPXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $A2DPXM
	sedi 's/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink">/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
  	BTQTIXM=$MODPATH${OBTQTIXML}
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $BTQTIXM
	sedi 's/samplingRates="44100"/samplingRates="96000"/g' $BTQTIXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $BTQTIXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $BTQTIXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $BTQTIXM
	sedi 's/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink">/"AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_HEADPHONES" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	sedi 's/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink">/AUDIO_DEVICE_OUT_BLUETOOTH_A2DP_SPEAKER" role="sink" encodedFormats="AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL">/g' $BTQTIXM
	done

  for OUSBXML in ${USBXML}; do
  	USBXM=$MODPATH${OUSBXML}
	sedi 's/samplingRates="44100"/samplingRates="48000"/g' $USBXM
	done

  for OAPCXM in ${APCXML}; do
  	APCXM=$MODPATH${OAPCXM}
	sedi 's/AUDIO_FORMAT_PCM_32_BIT/AUDIO_FORMAT_PCM_FLOAT/g' $APCXM
	sedi 's/samplingRates="44100"/samplingRates="48000"/g' $APCXM
	sedi 's/samplingRates="44100,48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/samplingRates="44100,48000,96000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/g' $APCXM
	sedi 's/samplingRates="44100 48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/samplingRates="44100 48000 96000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_FAST|AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW|AUDIO_OUTPUT_FLAG_FAST/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_FAST AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW AUDIO_OUTPUT_FLAG_FAST/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/flags="AUDIO_OUTPUT_FLAG_RAW/flags="AUDIO_OUTPUT_FLAG_NONE/g' $APCXM
	sedi 's/name="raw"/name="none"/g' $APCXM
	sedi 's/,raw//g' $APCXM
	sedi 's/raw,//g' $APCXM
	sedi 's/ AUDIO_FORMAT_FORCE_AOSP_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_FORCE_AOSP/AUDIO_FORMAT_FORCE_AOSP AUDIO_FORMAT_FORCE_AOSP_LL/g' $APCXM
	sedi 's/ AUDIO_FORMAT_LHDC_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_LHDC_LL//g' $APCXM
	sedi 's/AUDIO_FORMAT_LHDC/AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL/g' $APCXM
	sedi 's/speaker_drc_enabled="true"/speaker_drc_enabled="false"/g' $APCXM
	sedi 's/samplingRates="32000,44100,48000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="32000,44100,48000,64000,88200,96000,128000,176400,192000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000,352800,384000"/g' $APCXM
	sedi 's/samplingRates="44100,48000,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $APCXM
	sedi 's/samplingRates="44100,48000,88200,96000"/samplingRates="8000,11025,12000,16000,22050,24000,32000,44100,48000,64000,88200,96000,128000,176400,192000"/g' $APCXM
	sedi 's/samplingRates="32000 44100 48000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="32000 44100 48000 64000 88200 96000 128000 176400 192000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"/g' $APCXM
	sedi 's/samplingRates="44100 48000 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $APCXM
	sedi 's/samplingRates="44100 48000 88200 96000"/samplingRates="8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_MONO"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_MONO"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO,AUDIO_CHANNEL_OUT_STEREO,AUDIO_CHANNEL_OUT_2POINT1,AUDIO_CHANNEL_OUT_QUAD,AUDIO_CHANNEL_OUT_PENTA,AUDIO_CHANNEL_OUT_5POINT1,AUDIO_CHANNEL_OUT_6POINT1,AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi 's/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1"/channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO AUDIO_CHANNEL_OUT_2POINT1 AUDIO_CHANNEL_OUT_QUAD AUDIO_CHANNEL_OUT_PENTA AUDIO_CHANNEL_OUT_5POINT1 AUDIO_CHANNEL_OUT_6POINT1 AUDIO_CHANNEL_OUT_7POINT1"/g' $APCXM
	sedi '/^ *#/d; /^ *$/d' $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
  	APIOCXM=$MODPATH${OAPIOCXM}
	sedi 's/sampling_rates 44100|48000|88200|96000|176400|192000|352800|384000/sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000/g' $APIOCXM
	sedi 's/sampling_rates 32000|44100|48000|88200|96000|176400|192000|352800/sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000/g' $APIOCXM
	sedi 's/AUDIO_FORMAT_PCM_32_BIT/AUDIO_FORMAT_PCM_FLOAT/g' $APIOCXM
	sedi '/AUDIO_FORMAT_MP3/a\
AutoSystemBoost' $APIOCXM
	sedi '/AutoSystemBoost/,+1d' $APIOCXM
	sedi '/AUDIO_FORMAT_MP3/a\
    sampling_rates 8000|11025|12000|16000|22050|24000|32000|44100|48000|88200|96000|176400|192000|352800|384000' $APIOCXM
	sedi '/proaudio/,+6d' $APIOCXM
	done

  for OMIX in ${MPATHS}; do
  	MIX=$MODPATH${OMIX}
	sedi 's/IIR0 Enable Band1" value="1"/IIR0 Enable Band1" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band2" value="1"/IIR0 Enable Band2" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band3" value="1"/IIR0 Enable Band3" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band4" value="1"/IIR0 Enable Band4" value="0"/g' $MIX
	sedi 's/IIR0 Enable Band5" value="1"/IIR0 Enable Band5" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band1" value="1"/IIR1 Enable Band1" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band2" value="1"/IIR1 Enable Band2" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band3" value="1"/IIR1 Enable Band3" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band4" value="1"/IIR1 Enable Band4" value="0"/g' $MIX
	sedi 's/IIR1 Enable Band5" value="1"/IIR1 Enable Band5" value="0"/g' $MIX
	sedi 's/"Voice Sidetone Enable" value="1"/"Voice Sidetone Enable" value="0"/g' $MIX
	sedi 's/COMP Switch" value="1"/COMP Switch" value="0"/g' $MIX
	sedi 's/COMP0 Switch" value="1"/COMP0 Switch" value="0"/g' $MIX
	sedi 's/COMP1 Switch" value="1"/COMP1 Switch" value="0"/g' $MIX
	sedi 's/COMP2 Switch" value="1"/COMP2 Switch" value="0"/g' $MIX
	sedi 's/COMP3 Switch" value="1"/COMP3 Switch" value="0"/g' $MIX
	sedi 's/COMP4 Switch" value="1"/COMP4 Switch" value="0"/g' $MIX
	sedi 's/COMP5 Switch" value="1"/COMP5 Switch" value="0"/g' $MIX
	sedi 's/COMP6 Switch" value="1"/COMP6 Switch" value="0"/g' $MIX
	sedi 's/COMP7 Switch" value="1"/COMP7 Switch" value="0"/g' $MIX
	sedi 's/COMP8 Switch" value="1"/COMP8 Switch" value="0"/g' $MIX
	sedi 's/Softclip0 Enable" value="1"/Softclip0 Enable" value="0"/g' $MIX
	sedi 's/Softclip1 Enable" value="1"/Softclip1 Enable" value="0"/g' $MIX
	sedi 's/Softclip2 Enable" value="1"/Softclip2 Enable" value="0"/g' $MIX
	sedi 's/Softclip3 Enable" value="1"/Softclip3 Enable" value="0"/g' $MIX
	sedi 's/Softclip4 Enable" value="1"/Softclip4 Enable" value="0"/g' $MIX
	sedi 's/Softclip5 Enable" value="1"/Softclip5 Enable" value="0"/g' $MIX
	sedi 's/Softclip6 Enable" value="1"/Softclip6 Enable" value="0"/g' $MIX
	sedi 's/Softclip7 Enable" value="1"/Softclip7 Enable" value="0"/g' $MIX
	sedi 's/Softclip8 Enable" value="1"/Softclip8 Enable" value="0"/g' $MIX
	sedi 's/HPHL_RDAC Switch" value="0"/HPHL_RDAC Switch" value="1"/g' $MIX
	sedi 's/HPHR_RDAC Switch" value="0"/HPHR_RDAC Switch" value="1"/g' $MIX
	sedi 's/"RX INT0 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT0 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT1 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT1 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT2 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT2 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT3 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT3 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi 's/"RX INT4 DEM MUX" value="NORMAL_DSM_OUT"/"RX INT4 DEM MUX" value="CLSH_DSM_OUT"/g' $MIX
	sedi '/EC Reference SampleRate/d' $MIX
	sedi '/EC Reference Bit Format/d' $MIX
	sedi 's/Digital Volume" value="87"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="86"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="85"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="84"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="83"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="82"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="81"/Digital Volume" value="88"/g' $MIX
	sedi 's/Digital Volume" value="80"/Digital Volume" value="88"/g' $MIX
	sedi '/HPHL Volume/d' $MIX
	sedi '/HPHR Volume/d' $MIX
	ASB_xml -s $MIX '/mixer/ctl[@name="HPHL Volume"]' "20"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPHR Volume"]' "20"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPHL"]' "Switch"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPHR"]' "Switch"
	ASB_xml -u $MIX '/mixer/ctl[@name="Load acoustic model"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Audiosphere Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="Audiosphere Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set HPX OnOff"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set HPX OnOff"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set HPX ActiveBe"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set HPX ActiveBe"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="DS2 OnOff"]' "On"
	ASB_xml -s $MIX '/mixer/ctl[@name="DS2 OnOff"]' "On"
	ASB_xml -u $MIX '/mixer/ctl[@name="THD3 Compensation"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="THD3 Compensation"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="MSM ASphere Set Param"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="MSM ASphere Set Param"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Codec Wideband"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Codec Wideband"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="Set Custom Stereo OnOff"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="Set Custom Stereo OnOff"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="HiFi Function"]' "On"
	ASB_xml -s $MIX '/mixer/ctl[@name="HiFi Function"]' "On"
	ASB_xml -u $MIX '/mixer/ctl[@name="Virtual Bass Boost"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="Virtual Bass Boost"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX0 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX1 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX2 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX3 EC_HQ Switch"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="WSA_RX4 EC_HQ Switch"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT1 SEC MIX HPHL Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT2 SEC MIX HPHR Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT1 MIX3 DSD HPHL Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="RX INT2 MIX3 DSD HPHR Switch"]' "1"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPH Idle Detect"]' "ON"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPH Idle Detect"]' "ON"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="HPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="HPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="LPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="LPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="AUX_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="AUX_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="A2DP_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="A2DP_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BT_BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BT_BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BPF Enable"]' "Off"
	ASB_xml -s $MIX '/mixer/ctl[@name="BPF Enable"]' "Off"
	ASB_xml -u $MIX '/mixer/ctl[@name="BDE Enable"]' "0"
	ASB_xml -s $MIX '/mixer/ctl[@name="BDE Enable"]' "0"
	ASB_xml -u $MIX '/mixer/ctl[@name="Amp DSP Enable"]' "1"
	ASB_xml -s $MIX '/mixer/ctl[@name="Amp DSP Enable"]' "1"
	sedi 's/RX_FIR Filter" value="ON"/RX_FIR Filter" value="OFF"/g' $MIX
	sedi 's/VBAT Enable" value="1"/VBAT Enable" value="0"/g' $MIX
	done

  for OACONF in ${ACONFS}; do
  	ACONF=$MODPATH${OACONF}
	ASB_xml -u $ACONF '/configs/property[@name="audio.offload.disable"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="av.offload.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="audio.offload.video"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.av.streaming.offload.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.offload.multiple.enabled"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.offload.track.enable"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.path.for.pcm.voip"]' "true"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.alac.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.ape.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.use.sw.mpegh.decoder"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.flac.sw.decoder.24bit"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="persist.vendor.audio.sva.conc.enabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="persist.vendor.audio.va_concurrency_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.conc.fallbackpath"]' "deep-buffer"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.audio.rec.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.dsd.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.playback.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.record.conc.disabled"]' "false"
	ASB_xml -u $ACONF '/configs/property[@name="vendor.voice.voip.conc.disabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="voice_concurrency"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_extn_formats_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_extn_hdmi_spk_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="aac_adts_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="alac_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="ape_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="flac_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="pcm_offload_enabled_16"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="pcm_offload_enabled_24"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="qti_flac_decoder"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="vorbis_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="wma_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="fm_power_opt"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="a2dp_offload_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="anc_headset_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audio_zoom_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="audiosphere_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="battery_listener_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="custom_stereo_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="dsm_feedback_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_hw_plugin_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_qdsp_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_spkr_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="ext_spkr_tfa_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="hfp_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="hifi_audio_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="hwdep_cal_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="keep_alive_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="kpi_optimize_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="maxx_audio_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="record_play_concurrency"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="spkr_prot_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="snd_monitor_enabled"]' "true"
	ASB_xml -u $ACONF '/configs/flag[@name="use_deep_buffer_as_primary_output"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="vbat_enabled"]' "false"
	ASB_xml -u $ACONF '/configs/flag[@name="wsa_enabled"]' "true"
	done

	if [ "${ASB_KERNEL}" = "true" ]; then
	  settings put global audio_safe_volume_state 0
	fi
	
	if [ -d "$MODPATH/tools" ]; then
	  find "$MODPATH/tools" -maxdepth 1 -type f \
	    ! -name "asb_state_sampler.sh" \
	    ! -name "asb_drain_analyzer.sh" \
	    ! -name "asb_doctor.sh" \
	    ! -name "asb_lint.sh" \
	    ! -name "asb_session_report.py" \
	    ! -name "asb_compare_sessions.py" \
	    ! -name "asb_analyze.py" \
	    -delete 2>/dev/null
	fi

	if [ "${ASB_LOG}" = "true" ]; then
	  rm -rf /data/*bsplog*/*
	  rm -rf /data/*/*bsplog*/*
	  rm -rf /data/*/*/*bsplog*/*
	  	  for _dbdir in /data/system/dropbox /data/vendor/dropbox; do
	    [ -d "$_dbdir" ] || continue
	    ls -t "$_dbdir" 2>/dev/null | tail -n +6 | while read -r _f; do
	      rm -f "$_dbdir/$_f" 2>/dev/null || true
	    done
	  done
	  rm -rf /data/*ramdump*/*
	  rm -rf /data/*/*ramdump*/*
	  rm -rf /data/*/*/*ramdump*/*
	  rm -rf /data/*tombstones*/*
	  rm -rf /data/*/*tombstones*/*
	  rm -rf /data/*/*/*tombstones*/*
	  rm -rf /data/anr/*
	  rm -rf /data/system/package_cache/*/*
	  rm -rf /data/local/*trace*/*
	  rm -rf /data/mlog/*
	  rm -rf /data/klog/*
	  rm -rf /data/ap-log/*
	  rm -rf /data/cp-log/*
	  rm -rf /data/last_alog/*
	  rm -rf /data/last_kmsg/*
	  rm -rf /data/dontpanic/*
	  rm -rf /data/memorydump/*
	  rm -rf /data/dumplog/*
	fi

	ASB_WEB_MODEL_CODE="$(getprop ro.product.model 2>/dev/null)"
	[ -z "$ASB_WEB_MODEL_CODE" ] && ASB_WEB_MODEL_CODE="$(getprop ro.product.name 2>/dev/null)"
	[ -z "$ASB_WEB_MODEL_CODE" ] && ASB_WEB_MODEL_CODE="UNKNOWN"

	ASB_WEB_NAME_CODE="$(getprop ro.product.name 2>/dev/null)"
	[ -z "$ASB_WEB_NAME_CODE" ] && ASB_WEB_NAME_CODE="$(getprop ro.product.device 2>/dev/null)"
	[ -z "$ASB_WEB_NAME_CODE" ] && ASB_WEB_NAME_CODE="UNKNOWN"

	ASB_WEB_SOC_CODE="$(getprop ro.soc.model 2>/dev/null)"
	[ -z "$ASB_WEB_SOC_CODE" ] && ASB_WEB_SOC_CODE="$(getprop ro.board.platform 2>/dev/null)"
	[ -z "$ASB_WEB_SOC_CODE" ] && ASB_WEB_SOC_CODE="UNKNOWN"

	mkdir -p "$MODPATH/webroot" 2>/dev/null
	cat > "$MODPATH/webroot/device_info.json" <<EOF
{
  "model_code": "$ASB_WEB_MODEL_CODE",
  "name_code": "$ASB_WEB_NAME_CODE",
  "soc_code": "$ASB_WEB_SOC_CODE"
}
EOF

	if [ -f "$MODPATH/runtime/profile_core.sh" ]; then
		chmod 0755 "$MODPATH/runtime/profile_core.sh"
	fi

	if [ -f "$MODPATH/system/bin/asb" ]; then
	  chmod 0755 "$MODPATH/system/bin/asb"
	fi

	if [ -f "$MODPATH/tools/asb_discover.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_discover.sh"
	fi

	if [ -f "$MODPATH/tools/asb_synthesize_bounds.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_synthesize_bounds.sh"
	fi

	if [ -f "$MODPATH/system/bin/asbdiag" ]; then
	  chmod 0755 "$MODPATH/system/bin/asbdiag"
	fi
	if [ -f "$MODPATH/tools/asb_diag.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_diag.sh"
	fi
	if [ -f "$MODPATH/tools/asb_verify_device.sh" ]; then
	  chmod 0755 "$MODPATH/tools/asb_verify_device.sh"
	fi

	if [ -f "$MODPATH/bin/asb" ]; then
	  chmod 0755 "$MODPATH/bin/asb"
	fi

	asb_prune_module
	find $MODPATH -empty -type d -delete

	if [ -d "$MODPATH/system" ]; then
	  _man="$MODPATH/generated_overlay_manifest.txt"
	  { echo "# ASB generated overlay manifest (install sweep)"
	    find "$MODPATH/system" -type f ! -path "*/system/bin/*" 2>/dev/null | sed "s|^$MODPATH/||"
	  } > "$_man"
	  cp -f "$_man" /data/adb/asb/generated_overlay_manifest.txt 2>/dev/null || true
	fi

# Deferred overlay: on firmware without the detected family's native audio stock
# the generated file overlay is NOT mounted on the first boot. It is staged and
# activated by service.sh only after sys.boot_completed confirms a clean boot,
# so a bad clone can never brick the very first boot (field: Ace 6 bootloops
# survived the 1-strike fuse because users recovery-flash before boot #2).
_mo_src="$MODPATH/system/odm"; _mo_dst="$MODPATH/system/vendor/odm"
if [ -d "$_mo_src" ]; then
  ( cd "$_mo_src" && find . -type f 2>/dev/null ) | while IFS= read -r _mf; do
    _mf="${_mf#./}"
    [ -f "$_mo_dst/$_mf" ] && continue
    mkdir -p "$_mo_dst/$(dirname "$_mf")" 2>/dev/null
    cp -f "$_mo_src/$_mf" "$_mo_dst/$_mf" 2>/dev/null
  done
fi
if [ -d "$_mo_dst" ]; then
  ( cd "$_mo_dst" && find . -type f 2>/dev/null ) | while IFS= read -r _mf; do
    _mf="${_mf#./}"
    [ -f "$_mo_src/$_mf" ] && continue
    mkdir -p "$_mo_src/$(dirname "$_mf")" 2>/dev/null
    cp -f "$_mo_dst/$_mf" "$_mo_src/$_mf" 2>/dev/null
  done
fi

if [ "$_asb_audio_ref" != "1" ] || [ "${_asb_sibling:-0}" = "1" ]; then
  # ONE-reboot activation via the standard /vendor magic-mount overlay — exactly
  # what the OP15 reference does. Everything the diag reads (mixer_paths_*_cdp.xml,
  # media_profiles.xml, hi-res audio_policy_configuration.xml) lives under
  # /vendor/etc and magic-mounts cleanly with the correct SELinux context on the
  # first boot. The Ace 6 hard-bootloop came NOT from /vendor but from grafting
  # /odm content into the magic-mount tree (/odm is a bind-mount of another
  # partition on these devices and breaks early boot before the fuse can run). So
  # we HARD-REMOVE every /odm graft — the /vendor overlay alone is safe like OP15.
  # Real /odm audio is still delivered, via the fuse-guarded runtime binds in
  # post-fs-data (counter synced to disk BEFORE any bind, so those can only ever
  # cost one recoverable boot, never a loop). No deferred 2-boot dance.
  rm -rf "$MODPATH/system/odm" "$MODPATH/system/vendor/odm" \
         "$MODPATH/system/my_product" "$MODPATH/deferred_overlay" 2>/dev/null || true
  echo 0 > /data/adb/asb/vendor_boot_counter 2>/dev/null || true
  rm -f /data/adb/asb/vendor_overlay_blocked 2>/dev/null || true
  ui_print "[*] /vendor overlay active after ONE reboot (OP15-style); /odm audio via fuse-guarded runtime binds"
fi

	if [ -f "$MODPATH/config/governor.conf" ]; then
	  cp -f "$MODPATH/config/governor.conf" "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
	  chmod 644 "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
	fi

	asb_snapshot_user_config

	if [ -d "$MODPATH/config" ]; then
	  echo 17 > "$MODPATH/config/.schema_version" 2>/dev/null || true
	  chmod 644 "$MODPATH/config/.schema_version" 2>/dev/null || true
	fi

	_asb_ver="$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)"
	_asb_date="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	_gov_hash="$(sha256sum "$MODPATH/bin/asb" 2>/dev/null | cut -c1-12 || echo none)"
	_perf_hash="$(sha256sum "$MODPATH/profiles/performance.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_bat_hash="$(sha256sum "$MODPATH/profiles/battery.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_bal_hash="$(sha256sum "$MODPATH/profiles/balanced.sh" 2>/dev/null | cut -c1-12 || echo none)"
	_conf_hash="$(sha256sum "$MODPATH/config/governor.conf" 2>/dev/null | cut -c1-12 || echo none)"
	mkdir -p "$MODPATH/runtime" 2>/dev/null
	cat > "$MODPATH/runtime/build_manifest.json" <<MANIFEST_EOF
{
  "asb_version": "$_asb_ver",
  "build_date": "$_asb_date",
  "schema_version": 17,
  "hashes": {
    "governor": "$_gov_hash",
    "performance": "$_perf_hash",
    "battery": "$_bat_hash",
    "balanced": "$_bal_hash",
    "governor_conf": "$_conf_hash"
  }
}
MANIFEST_EOF

asb_guard_v4a_effects

for _vb in $(find "$MODPATH/system" "$MODPATH/deferred_overlay" -type f -name "video_beauty_default_config" 2>/dev/null); do
  if grep -q '//' "$_vb" 2>/dev/null; then
    _vbt="${_vb}.asbc$$"
    if sed -e '/^[[:space:]]*\/\//d' -e 's#[[:space:]]//[^"]*$##' "$_vb" > "$_vbt" 2>/dev/null; then
      chmod --reference="$_vb" "$_vbt" 2>/dev/null || chmod 0644 "$_vbt" 2>/dev/null
      _vbctx="$(ls -Z "$_vb" 2>/dev/null | awk '{print $1}')"
      case "$_vbctx" in u:object_r:*) chcon "$_vbctx" "$_vbt" 2>/dev/null ;; esac
      mv -f "$_vbt" "$_vb" 2>/dev/null || { cat "$_vbt" > "$_vb" 2>/dev/null; rm -f "$_vbt"; }
    else
      rm -f "$_vbt" 2>/dev/null
    fi
  fi
done

asb_normalize_module_layout
asb_end_banner
