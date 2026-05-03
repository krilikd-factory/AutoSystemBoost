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

asb_end_banner() {
  local i=0
  while [ $i -lt 2 ]; do
    ui_print " "
    i=$((i+1))
  done

  ui_print "${SEPARATOR}"
  ui_print "${ASB_DONE_TITLE:-ASB}"
  ui_print "${ASB_DONE_MSG:-Module installed. Reboot.}"
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
    ui_print "- Prebuilt governor installed: $abi"
    return 0
  fi
  # V39: removed misleading "fallback to shell mode" message — there is no
  # shell-mode fallback in modern ASB; the governor is the binary, and if it
  # isn't present the module simply won't start its daemon. Staying silent
  # keeps the installer UI clean when the binary is sideloaded separately.
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

SEPARATOR="____________________________________________"

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

  echo "$ASB_MANUFACTURER_L $ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_ONEPLUS=true

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 15"*|*"oneplus15"*|*"op15"*|*"cph274"*|*"cph275"*|*"op611fl1"*|*"plk110"*|*"pjz110"*|*"pkz110"*)
      ASB_IS_OP15=true ;;
  esac

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
        echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP15=true
      fi
    fi
  fi

  if [ "$ASB_IS_OP15" != "true" ]; then
    ui_print "[*] Detect debug: manufacturer=$ASB_MANUFACTURER_RAW | model=$ASB_MODEL_RAW | device=$ASB_DEVICE_RAW | prj=$ASB_PRJ_RAW"
  fi
}

asb_prune_non_op15_vendor_overlays() {
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Compatibility mode enabled"
  ui_print "[*] Non-OP15 device detected"
  ui_print "[*] Keeping script/prop tweaks, pruning risky OP15 vendor overlays"
  ui_print "${SEPARATOR}"

  rm -f "$MODPATH/system/etc/permissions/Bluetooth.xml" 2>/dev/null || true
  rm -f "$MODPATH/system/etc/compatconfig/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*bluetooth*"xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/etc/"*a2dp*"xml" 2>/dev/null || true

  rm -f "$MODPATH/system/vendor/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -f "$MODPATH/system/vendor/odm/etc/media_profiles"*".xml" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/camera" 2>/dev/null || true

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

asb_prune_module() {
  local svc="$MODPATH/service.sh"
  local prop="$MODPATH/system.prop"
  local pfd="$MODPATH/post-fs-data.sh"

  for c in BT CAMERA CPU VM NET WIFI GPS KERNEL LOG; do
    asb_drop_block_if_off "$c" "$svc"
    asb_drop_block_if_off "$c" "$prop"
    asb_drop_block_if_off "$c" "$pfd"
  done


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

ASB_BT=true
ASB_CAMERA=true
ASB_CPU=true
ASB_VM=true
ASB_NET=true
ASB_WIFI=true
ASB_GPS=true
ASB_KERNEL=true
ASB_LOG=true

asb_install_prebuilt_governor
asb_big_banner
asb_choose_cat BT     "$ASB_MENU_BT"
asb_choose_cat CAMERA "$ASB_MENU_CAMERA"
asb_choose_cat CPU    "$ASB_MENU_CPU"
asb_choose_cat VM     "$ASB_MENU_VM"
asb_choose_cat NET    "$ASB_MENU_NET"
asb_choose_cat WIFI   "$ASB_MENU_WIFI"
asb_choose_cat GPS    "$ASB_MENU_GPS"
asb_choose_cat KERNEL "$ASB_MENU_KERNEL"
asb_choose_cat LOG    "$ASB_MENU_LOG"

asb_detect_compat
if [ "$ASB_IS_OP15" = "true" ]; then
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Full OnePlus 15 package will be installed"
  ui_print "${SEPARATOR}"
fi
asb_prune_module
if [ "$ASB_IS_OP15" != "true" ]; then
  asb_prune_non_op15_vendor_overlays
fi

cat > "$MODPATH/features.conf" <<EOF
BT=$([ "$ASB_BT" = "true" ] && echo 1 || echo 0)
CAMERA=$([ "$ASB_CAMERA" = "true" ] && echo 1 || echo 0)
CPU=$([ "$ASB_CPU" = "true" ] && echo 1 || echo 0)
VM=$([ "$ASB_VM" = "true" ] && echo 1 || echo 0)
NET=$([ "$ASB_NET" = "true" ] && echo 1 || echo 0)
WIFI=$([ "$ASB_WIFI" = "true" ] && echo 1 || echo 0)
GPS=$([ "$ASB_GPS" = "true" ] && echo 1 || echo 0)
KERNEL=$([ "$ASB_KERNEL" = "true" ] && echo 1 || echo 0)
LOG=$([ "$ASB_LOG" = "true" ] && echo 1 || echo 0)
EOF

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

MPATHS="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "*mixer_path*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APINF="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACONFS="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_configs*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
AEFFECT="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_effects*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
ACCXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_cloud_control*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APCXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_policy_configuration*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
A2DPXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "a2dp*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VEHXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "vehicle*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
VIRTXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "virtual*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
USBXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "usb*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTQTIXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "bluetooth*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
APIOCXML="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "audio_output_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "audio_io_policy.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "bt_configstore*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
BTCONF2="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "bt_stack*.conf" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
MEDCA="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "media_codecs*audio.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"
SNDTRPL="$(find /system /vendor /system_ext /product /odm /my_product -depth -type f -iname "sound_trigger_platform_info*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*" -o -iname "resourcemanager*.xml" ! -path "*/vintf/*" ! -path "*/selinux/*" ! -path "*/lib*/*" ! -path "*/media*/*")"

mkdir -p $MODPATH/tools
EXTTOOLS="$MODPATH/common/addon/External-Tools/tools/$ARCH32"
if [ -d "$EXTTOOLS" ] && ls "$EXTTOOLS"/* >/dev/null 2>&1; then
  mkdir -p "$MODPATH/tools"
  cp -af "$EXTTOOLS"/* "$MODPATH/tools/" >/dev/null 2>&1 || true
fi

  for OACCXML in ${ACCXML}; do
	cp_ch $ORIGDIR$OACCXML $ACCXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $ACCXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
	cp_ch $ORIGDIR$OSNDTRPL $SNDTRP
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
	cp_ch $ORIGDIR$OMEDCX $MEDCX
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $MEDCX
	done

  for OMIX in ${MPATHS}; do
	cp_ch $ORIGDIR$OMIX $MIX
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $MIX
	done

  if [ "${ASB_BT}" = "true" ]; then
  for OA2DPXML in ${A2DPXML}; do
	cp_ch $ORIGDIR$OA2DPXML $A2DPXM
	# V39r9: removed unsafe /<!--/,/-->/d range delete.
	# Multi-line codec disabled-comment blocks like:
	#   <!-- Opus codec is OEM-specific
	#   <a2dp_codec name="opus" priority="..." />
	#   -->
	# get partially mangled by the range delete, leaving phantom codec
	# entries the vendor stack can't service. Confirmed cause of Opus
	# handshake hang on Pixel Buds Pro 2 paired with non-Pixel SoCs.
	# Now we ONLY strip blank lines to avoid disturbing codec semantics.
	sedi '/^ *$/d' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
	cp_ch $ORIGDIR$OBTQTIXML $BTQTIXM
	# Same safety fix for bluetooth_qti.xml — also contains multi-line
	# vendor codec metadata that should not be touched.
	sedi '/^ *$/d' $BTQTIXM
	done

  fi

  for OVEHXML in ${VEHXML}; do
	cp_ch $ORIGDIR$OVEHXML $VEHXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $VEHXM
	done

  for OVIRTXML in ${VIRTXML}; do
	cp_ch $ORIGDIR$OVIRTXML $VIRTXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $VIRTXM
	done

  for OUSBXML in ${USBXML}; do
	cp_ch $ORIGDIR$OUSBXML $USBXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $USBXM
	done

  for OAPCXM in ${APCXML}; do
	cp_ch $ORIGDIR$OAPCXM $APCXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
	cp_ch $ORIGDIR$OAPIOCXM $APIOCXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $APIOCXM
	done

  for OAPLI in ${APINF}; do
	cp_ch $ORIGDIR$OAPLI $APLI
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $APLI
	done

  for OACONF in ${ACONFS}; do
	cp_ch $ORIGDIR$OACONF $ACONF
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $ACONF
	done

  for OAEFFECT in ${AEFFECT}; do
	cp_ch $ORIGDIR$OAEFFECT $EFFECT
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $EFFECT
	done

  if [ "${ASB_BT}" = "true" ]; then
  for OBTCONF in ${BTCONF}; do
	cp_ch $ORIGDIR$OBTCONF $BTCON
	# V39r9: removed unsafe XML range-delete and # line strip.
	# bt_configstore.conf is KEY=VALUE with # line comments; vendor
	# blobs sometimes ship with intentionally-disabled codec defaults
	# (`# enable_opus_codec=false`) that should stay disabled. The
	# previous sed deleted ALL # lines plus XML comment ranges that
	# don't apply to .conf files anyway. Keep only blank-line trim.
	sedi '/^ *$/d' $BTCON
	done

  for OBTCONF2 in ${BTCONF2}; do
	cp_ch $ORIGDIR$OBTCONF2 $BTCON2
	# Same safety fix for bt_stack.conf — vendor sometimes ships
	# disabled-by-default codec/feature flags that affect handshake.
	sedi '/^ *$/d' $BTCON2
	done

  fi

  for ODAXXML in ${DAXXML}; do
	cp_ch $ORIGDIR$ODAXXML $DAXXM
	sedi 's/<<!--.*-->>//; s/<!--.*-->>//; s/<<!--.*-->//; s/<!--.*-->//; /<!--/,/-->/d; /^ *#/d; /^ *$/d' $DAXXM
	done

  for OAEFFECT in ${AEFFECT}; do
	sedi '/"audiosphere"/d' $EFFECT
	sedi '/effect name="volume"/d' $EFFECT
	sedi '/"dvl"/d' $EFFECT
	sedi '/"agc"/d' $EFFECT
	sedi '/"volume_listener"/d' $EFFECT
	sedi '/"audio_pre_processing"/d' $EFFECT
	sedi '/v4a_standard_re/d' $EFFECT
	sedi '/v4a_re/d' $EFFECT
	sedi '/<libraries>/ a\        <library name=\"v4a_re\" path=\"libv4a_re.so\"\/>' $EFFECT
	sedi '/<effects>/ a\        <effect name=\"v4a_standard_re\" library=\"v4a_re\" uuid=\"90380da3-8536-4744-a6a3-5731970e640f\"\/>' $EFFECT
	done

  for OACCXML in ${ACCXML}; do
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
	sedi 's/aacFrameCtlEnabled = true/aacFrameCtlEnabled = false/g' $BTCON
	done

  for OBTCONF2 in ${BTCONF2}; do
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
	sedi 's/samplingRates="44100"/samplingRates="48000"/g' $USBXM
	done

  for OAPCXM in ${APCXML}; do
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
	
	rm -rf $MODPATH/tools

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
	  rm -rf /data/local/*tmp*/*
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

	if [ -f "$MODPATH/common/profile_core.sh" ]; then
		cp -f "$MODPATH/common/profile_core.sh" "$MODPATH/runtime/profile_core.sh"
		chmod 0755 "$MODPATH/runtime/profile_core.sh"
	fi

	asb_prune_module
	find $MODPATH -empty -type d -delete

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
  "schema_version": 8,
  "hashes": {
    "governor": "$_gov_hash",
    "performance": "$_perf_hash",
    "battery": "$_bat_hash",
    "balanced": "$_bal_hash",
    "governor_conf": "$_conf_hash"
  }
}
MANIFEST_EOF

asb_end_banner
