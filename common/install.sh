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
  # CRITICAL boot-safety step. A Magisk/KernelSU module must keep ALL of its
  # mounted files under $MODPATH/system/ — the framework maps system/vendor ->
  # /vendor, system/odm -> /odm, etc. via magic-mount. If a REAL top-level
  # vendor/ (or odm/, product/, system_ext/) directory exists at the module
  # root, the root layer can bind that partial directory over the WHOLE real
  # /vendor partition, hiding everything the device needs -> vendor init fails
  # -> BOOTLOOP. This was the OnePlus 13 failure: the device-overlay + in-place
  # passes left a real /vendor with only ~32 files shadowing the stock 1000s.
  #
  # OP15 happened to dodge it (its full shipped system/vendor produced a clean
  # symlink), but on OP12/OP13 the pruned+rebuilt tree materialised a real dir.
  # Here we fold any stray top-level partition dir back into system/ and delete
  # the root copy, so every device ends with the single safe system/-only tree.
  for _part in vendor odm product system_ext my_product mi_ext; do
    _root="$MODPATH/$_part"
    # Skip if absent, or if it is a symlink (the framework's own valid link).
    [ -e "$_root" ] || continue
    if [ -L "$_root" ]; then continue; fi
    [ -d "$_root" ] || continue

    ui_print "[*] Layout fix: folding stray /$_part into system/$_part (boot-safety)"
    # Move every file under the stray dir to system/<part>/, without clobbering
    # a file the proper pass already placed there (system/ copy wins).
    for _f in $(cd "$_root" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _target="$MODPATH/system/$_part/$_f"
      if [ ! -f "$_target" ]; then
        mkdir -p "$(dirname "$_target")" 2>/dev/null
        cp -f "$_root/$_f" "$_target" 2>/dev/null || true
      fi
    done
    rm -rf "$_root" 2>/dev/null || true
  done

  # Also drop the framework's per-file restore manifest entries that point at a
  # root-level partition path, so uninstall/reinstall never resurrects them.
  if [ -f "$INFO" ]; then
    for _part in vendor odm product system_ext my_product mi_ext; do
      sed -i "\|^$MODPATH/$_part/|d" "$INFO" 2>/dev/null || true
    done
  fi

  # Final guard: never ship an empty stray dir either.
  for _part in vendor odm product system_ext my_product mi_ext; do
    [ -L "$MODPATH/$_part" ] && continue
    [ -d "$MODPATH/$_part" ] && rmdir "$MODPATH/$_part" 2>/dev/null || true
  done

  # NOTE: KernelSU Next runs its own "Handle partition /vendor" step AFTER this
  # script finishes, which materialises a service vendor/ at the module root as
  # part of its magic-mount (mirror + per-file merge). That root vendor/ is a
  # framework artifact, NOT a shadow of the whole /vendor partition — the device
  # keeps its stock files and only ASB's files are merged on top. So we do NOT
  # fight it here (no whiteout, no symlink); the fold above only cleans a
  # genuinely malformed layout left by an older buggy build.
}

asb_end_banner() {
  # Remove the legacy Magisk-template index file (.$MODID-files) if it was
  # left behind empty. ASB ships its own uninstall.sh and does not rely on
  # this per-file tracking list, so an empty one is just litter in modules/.
  if [ -n "$INFO" ] && [ -f "$INFO" ] && [ ! -s "$INFO" ]; then
    rm -f "$INFO" 2>/dev/null || true
  fi
  [ -f "$NVBASE/modules/.$MODID-files" ] && [ ! -s "$NVBASE/modules/.$MODID-files" ] \
    && rm -f "$NVBASE/modules/.$MODID-files" 2>/dev/null || true

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
  ASB_IS_OP13=false
  ASB_IS_OP12=false

  echo "$ASB_MANUFACTURER_L $ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_ONEPLUS=true

  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 15"*|*"oneplus15"*|*"op15"*|*"cph274"*|*"cph275"*|*"op611fl1"*|*"plk110"*|*"pjz110"*|*"pkz110"*)
      ASB_IS_OP15=true ;;
  esac

  # OnePlus 13 — chipset "sun"/SM8750, model CPH2649, device OP5D55*
  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 13"*|*"oneplus13"*|*"op13"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
      ASB_IS_OP13=true ;;
  esac
  # platform/SoC fallback for OP13 (sun / SM8750) — only if not already OP15.
  #
  # CRITICAL: SM8750 is shared by a LOT of OnePlus devices that are NOT the
  # OnePlus 13 and do NOT share the OP13 'sun' vendor partition layout — e.g.
  # Ace 6 (ktm), 13T/13s (pagani), Ace 5 Pro (hummer), Ace 5 Ultra (emira),
  # Ace 5 Race (subaru). Applying the OP13 'sun' device overlay (camera/audio/
  # perf XMLs authored for sun) to any of those mismatches the HALs and bootloops
  # — this is the "Ace 6 won't boot on V52" regression (pre-V52 had no OP13 path,
  # so those devices fell through to the generic-safe path and booted fine).
  #
  # So the SoC fallback is an ALLOWLIST, not a blanket SoC match: an unidentified
  # SM8750 OnePlus is only treated as OP13 when its codename/model is positively
  # in the OP13 'sun' family. Everything else on SM8750 falls through to the
  # generic-safe path (governor + sed only, no device overlay), which boots on
  # any device. Real OP13 is already caught by the explicit model match above;
  # this fallback only adds OP13 when the platform is sun AND the codename
  # confirms it, so a hidden-model OP13 still works without risking foreign SoC
  # siblings.
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8750"*|*"sun"*)
        # Only the OP13 'sun' family — confirmed by codename/model — gets the
        # overlay. 'sun' is the OP13 codename; CPH2649/53/55 and OP5D55 are OP13
        # models. Foreign SM8750 codenames (ktm/pagani/hummer/emira/subaru/…)
        # deliberately do NOT match and stay on the generic-safe path.
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"sun"*|*"cph2649"*|*"cph2653"*|*"cph2655"*|*"op5d55"*)
            echo "$ASB_MANUFACTURER_L" | grep -Eqi '(oneplus|oplus)' && ASB_IS_OP13=true ;;
          *)
            ui_print "[*] SM8750 device, non-OP13 codename — generic-safe tuning (no OP13 overlay, boots on any SM8750 sibling)" ;;
        esac ;;
    esac
  fi

  # OnePlus 12 — chipset "pineapple"/SM8650, model CPH2581, device OP595*
  case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_FP_L" in
    *"oneplus 12"*|*"oneplus12"*|*"op12"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*)
      ASB_IS_OP12=true ;;
  esac
  # platform/SoC fallback for OP12 (pineapple / SM8650) — only if not OP15/OP13.
  #
  # Same allowlist discipline as the SM8750 path above: SM8650 (Snapdragon 8
  # Gen 3) is shared by many OnePlus devices that are NOT the OP12 and don't
  # share its 'pineapple' vendor layout (Ace 3, Ace 3 Pro, Ace 3V, …). Applying
  # the OP12 device overlay to one of those would mismatch the HALs and risk a
  # bootloop, so the fallback only treats an unidentified SM8650 OnePlus as OP12
  # when its codename/model positively confirms the 'pineapple' family. Everything
  # else on SM8650 stays on the generic-safe path (governor + sed only), which
  # boots on any sibling. Real OP12 is already caught by the explicit match above.
  if [ "$ASB_IS_OP15" != "true" ] && [ "$ASB_IS_OP13" != "true" ] && [ "$ASB_IS_OP12" != "true" ]; then
    ASB_PLATFORM_L="$(asb_norm_l "$(asb_prop_first ro.board.platform ro.soc.model)")"
    case "$ASB_PLATFORM_L" in
      *"sm8650"*|*"pineapple"*)
        case "$ASB_MODEL_L $ASB_DEVICE_L $ASB_PRJ_L $ASB_FP_L" in
          *"pineapple"*|*"cph2581"*|*"cph2583"*|*"cph2573"*|*"op595"*)
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
        # CPU-clock heuristic for OP15 (SM8850 prime ~4.5-4.6 GHz), but SM8850 is
        # also used by other OnePlus devices that are NOT the OP15 and don't share
        # its 'canoe' vendor layout (Ace 6T/15R 'macan', 15T 'fairlady', Ace 6 Pro).
        # Forcing OP15 on those would apply the canoe overlay and risk a bootloop,
        # so only accept this heuristic when the codename/model isn't a known
        # foreign SM8850 sibling. Unknown SM8850 codenames still pass (so a
        # hidden-model OP15 works), but the known siblings are excluded and fall
        # through to the generic-safe path.
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
  # OP15 is primary — if both matched, OP15 wins. OP12/OP13 are mutually exclusive too.
  [ "$ASB_IS_OP15" = "true" ] && ASB_IS_OP13=false && ASB_IS_OP12=false
  [ "$ASB_IS_OP13" = "true" ] && ASB_IS_OP12=false
}

# Detect the root manager at install time. Used to scope the OP12 camera-engine
# exclusion to APatch ONLY: the OP12 multicamera HAL crash is APatch-specific
# (APatch's /odm is a real separate mount, so any camera-conf churn stacks/
# disturbs a mount the HAL is reading); on KernelSU /odm is a symlink to
# /vendor/odm and the camera tolerates the tweak engine fine. We rely on the
# manager-exported env vars first (KSU / APATCH are set by the boot scripts that
# run module install) and fall back to the on-disk control dirs, which are far
# more reliable here than getprop in the install/recovery environment.
ASB_IS_APATCH=false
asb_detect_manager() {
  if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ] || [ -f /data/adb/apd ]; then
    # KernelSU also ships some /data/adb/ap-like staging in odd setups, so prefer
    # an explicit APatch marker and make sure this isn't actually KSU.
    if [ "${KSU:-}" = "true" ] || [ -f /data/adb/ksud ]; then
      # Both markers present — trust the explicit APATCH env if set, else treat
      # as KSU (the camera works there, so the safe default is "not APatch").
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
  # $1 = overlay dir name (op12_overlay / op13_overlay)
  # $2 = human label (e.g. "OnePlus 13 (CPH2649 / SM8750 'sun')")
  _ov="$1"; _label="$2"
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] $_label detected"
  ui_print "[*] Applying device-tuned overlay (GPS, camera, media)"
  ui_print "[*] Audio/volume/codecs apply via device-agnostic patches"
  ui_print "${SEPARATOR}"

  # Remove the OP15-specific shipped overlays that don't fit this device
  # (OP15 SKU audio dirs, OP15 camera calibration, OP15 wifi SKU, OP15 media).
  rm -rf "$MODPATH/system/vendor/etc/audio" 2>/dev/null || true
  rm -rf "$MODPATH/system/vendor/odm/etc/audio" 2>/dev/null || true
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
    # IMPORTANT (OP12 fix): OnePlus 12/13 have a SEPARATE real /odm partition,
    # and the camera/GPS HAL reads /odm directly — not /vendor/odm. Earlier
    # builds wrote only system/vendor/odm, leaving /odm stock; on OP12 that
    # showed up as /odm vs /vendor/odm desync (camera crash, stale GPS). We now
    # ALSO write the overlay into system/odm so the manager mounts it into the
    # real /odm partition (the manager builds its partition list from the dirs
    # the module ships under system/, and creates an /odm mirror for exactly
    # this). We keep the system/vendor/odm copy too, so whichever path the HAL
    # reads is patched. _odm_targets maps a shipped overlay path to the system/
    # destinations it must land in.
    _odm_dups() {
      # $1 = relative overlay path under the overlay dir. echoes the system/
      # destination path(s) this file should be copied to.
      #
      # CAMERA FIX (final, proven by direct comparison of the known-good 20000
      # build vs the regressed 3590): the working module writes the camera/media
      # overlay to system/vendor/odm ONLY and the camera works on BOTH KernelSU
      # AND APatch. The "also mirror into system/odm" approach (added to chase an
      # APatch /odm desync) was itself the regression: on APatch, shipping
      # system/odm/etc/camera makes the manager stack a separate mount over the
      # real /odm partition, which breaks the multicamera HAL (ChiMcxRoiTranslator
      # SIGABRT). KernelSU tolerates it (its /odm is a symlink to /vendor/odm), so
      # only APatch broke. So we now match the working module exactly: camera and
      # media_profiles go to system/vendor/odm only — NO system/odm mirror.
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
    # GPS overlay — gated by GPS category. Write every destination path.
    if [ "$ASB_GPS" = "true" ]; then
      for _f in vendor/etc/gps.conf vendor/odm/etc/gps.conf \
                vendor/etc/izat.conf vendor/odm/etc/izat.conf; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "    + GPS: $_dst"
          done
        fi
      done
    fi
    # Camera/media overlay — gated by CAMERA category. Camera goes to
    # system/vendor/odm ONLY (via _odm_dups), matching the known-good module.
    if [ "$ASB_CAMERA" = "true" ]; then
      for _f in vendor/etc/media_profiles.xml \
                vendor/odm/etc/camera/media_profiles.xml \
                vendor/odm/etc/camera/conf_tuning_params.json \
                vendor/odm/etc/camera/config/video_beauty_default_config; do
        if [ -f "$MODPATH/$_ov/$_f" ]; then
          for _dst in $(_odm_dups "$_f"); do
            mkdir -p "$MODPATH/$(dirname "$_dst")" 2>/dev/null
            cp -f "$MODPATH/$_ov/$_f" "$MODPATH/$_dst" 2>/dev/null \
              && ui_print "    + Camera/media: $_dst"
          done
        fi
      done
      # Camera tone: baseline (stock conf_tuning) is saved here; the opt-in
      # aggressive tone + inject layers are applied at boot by post-fs-data from
      # that baseline, so the CAMERA_AGGRESSIVE / _INJECT toggles take effect on
      # a plain reboot instead of only on reinstall.
      #
      # CRITICAL OP12+APatch EXCLUSION: skip the install-time tweak engine on the
      # camera conf ONLY when this is OP12 running APatch. The multicamera HAL
      # crash is APatch-specific (its /odm is a real separate mount; any churn of
      # the camera conf disturbs a mount the HAL reads). On OP12 + KernelSU (where
      # /odm is a symlink to /vendor/odm) the camera tolerates the engine, so KSU
      # OP12 keeps the full reversible-tweak path like OP13/OP15. asb_apply_dynamic_tweaks
      # has a pineapple guard, but it relies on getprop which is unreliable in the
      # install/recovery environment, and asb_tw_save_base would touch the file
      # before that guard — so we gate on the reliable install-time flags here.
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
            ui_print "    + Camera aggressive tone applied (incl. injected keys)"
          else
            ui_print "    + Camera aggressive tone applied (existing keys only)"
          fi
        fi
      elif [ "$_skip_cam_engine" = "true" ]; then
        ui_print "    + OP12/APatch: camera kept stock (tweak engine skipped)"
      fi
    fi
  fi

  # Clean up both staging dirs (only the live device's was used).
  rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true
  ui_print "[*] Overlay applied. Audio EQ/volume/hi-res + codecs are"
  ui_print "    patched in-place during the audio/media pass."
}

# ---------------------------------------------------------------------------
# Per-device perf tuning (OP12 / OP13).
#
# The OP15 package ships pre-tuned perf XML as full-file replacements, valid
# only for the 'canoe' target. OP12 ('pineapple','cliffs') and OP13
# ('sun','tuna','kera') have different stock perf files, so instead of shipping
# a fragile pre-edited copy we patch the LIVE device's stock files in place —
# the same philosophy ASB already uses for audio. This survives OS updates: we
# always patch whatever perfconfigstore/qapegameconfig the device currently has.
#
# The tuning mirrors OP15 exactly (same intent, device-correct values):
#   * qapegameconfig.txt: per-game thermal/current ceilings lowered
#       48000/1150/1000 -> 44000/900/800  (games throttle earlier, run cooler)
#   * perfconfigstore.xml:
#       - debug daemons off (enable.lm, memperfd, prekill) — pure overhead
#       - topAppRenderThreadBoost on — smoother foreground UI thread
#       - qape boost_duration 10->3, max_boost_count 3->1 — shorter blind boosts
#       - fps_switch_hyst 10->12 — fewer refresh-rate flips
#       - wlc.exit.timeout 120000->30000, active_reqs_max 30->28 (only if present)
#   * perfboostsconfig.xml: idle render-thread boost 0x10A7 2000->1600ms
#
# Only props/rows that already exist are touched; missing ones are skipped, so
# OP12 (no qapegameconfig, no wlc/active_reqs props) degrades gracefully.
# ---------------------------------------------------------------------------
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
  # data rows: <id> <apk> 48000 1150 1000  ->  ... 44000 900 800
  sedi 's/^\([0-9][0-9]*[ 	][ 	]*[^ 	][^ 	]*[ 	][ 	]*\)48000\([ 	][ 	]*\)1150\([ 	][ 	]*\)1000/\144000\2900\3800/' "$_f"
}

# ---------------------------------------------------------------------------
# Wi-Fi driver tuning (all devices). We clone the device's own stock WCNSS_*.ini
# from the live partition and sed-patch a SMALL, conservative set of values in
# place — exactly like the audio/perf passes. This is device-safe: we only
# rewrite keys that already exist, so a device that lacks one just keeps stock.
#
# CRITICAL: we never touch wpa_supplicant_overlay.conf / p2p_supplicant_overlay
# (the p2p_disabled / tdls_disabled lines there are load-bearing — removing them
# stops the Wi-Fi toggle from enabling on OP15). We also never touch roaming
# thresholds (RoamRssiDiff, gNeighborScan*) or the regulatory country — those
# are stability/regdomain sensitive.
#
# Tuning applied (only to keys present in the file):
#   gRuntimePMDelay        3000 -> 2000   power: quicker runtime-PM idle entry
#   gActiveMaxChannelTime    45 -> 40     latency: shorter active-scan dwell
#   gBusBandwidthVeryHighThreshold 15000->12000  throughput: engage high-perf bus sooner
asb_patch_one_wcnss() {
  _f="$1"; [ -f "$_f" ] || return 0
  sed -i 's/^gRuntimePMDelay=.*/gRuntimePMDelay=2000/'                       "$_f" 2>/dev/null || true
  sed -i 's/^gActiveMaxChannelTime=.*/gActiveMaxChannelTime=40/'            "$_f" 2>/dev/null || true
  sed -i 's/^gBusBandwidthVeryHighThreshold=.*/gBusBandwidthVeryHighThreshold=12000/' "$_f" 2>/dev/null || true
}

asb_patch_wifi_inplace() {
  # $1 = human label
  _label="$1"
  [ "$ASB_WIFI" = "true" ] || return 0

  # Clone the live stock wifi dir (vendor first, then odm/system mirrors) into
  # the module under system/, then patch the WCNSS .ini files in place. The
  # supplicant .conf files are copied verbatim (NOT patched) so the toggle-
  # critical p2p_disabled/tdls lines are preserved exactly as the device ships.
  _wifi_src=""
  for _ws in /vendor/etc/wifi /odm/etc/wifi /system/vendor/etc/wifi; do
    [ -d "$_ws" ] && { _wifi_src="$_ws"; break; }
  done
  [ -n "$_wifi_src" ] || return 0

  asb_clone_dir_from_live "$_wifi_src" >/dev/null 2>&1 || return 0

  # Patch every cloned WCNSS_*.ini (covers per-SKU subdirs too). Supplicant
  # .conf files are deliberately left untouched.
  _wdir="$MODPATH/system${_wifi_src#/system}"
  for _wf in $(find "$_wdir" -type f -iname "WCNSS_qcom_cfg*.ini" 2>/dev/null); do
    asb_patch_one_wcnss "$_wf"
  done
}

asb_patch_perf_inplace() {
  # $1 = human label
  _label="$1"
  [ "$ASB_CPU" = "true" ] || { ui_print "[*] CPU/perf category off — skipping perf tuning"; return 0; }

  # Locate the live stock perf dir (vendor first, then odm/system_ext mirrors).
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
  # The shipped perf dir is OP15-only (canoe target). Its qapegameconfig.txt
  # has no Target column and would apply canoe caps globally on this device,
  # and qapeboostsconfig.xml is canoe-keyed. Remove the whole shipped dir and
  # rebuild only the files we patch from the live stock perf.
  rm -rf "$_dst" 2>/dev/null || true
  mkdir -p "$_dst" 2>/dev/null

  # Clone only the files we tune (full replacement of those, nothing else),
  # so the rest of the stock perf framework keeps loading from vendor.
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
    # idle render-thread boost: shorten hold to cut idle heat (2000 -> 1600)
    sedi 's/\(Id="0x000010A7"[^>]*Timeout="\)2000"/\11600"/g' "$_dst/perfboostsconfig.xml"
  fi
}

# ---------------------------------------------------------------------------
# Per-device location/GPS-assist tuning (OP12 / OP13).
#
# OP15 ships tuned xtwifi.conf (Qualcomm GTP / XTRA assisted-GNSS) and
# lowi.conf (WiFi RTT ranging) as static canoe copies. The tweaks are pure
# value edits and device-agnostic, so — like perf and audio — we patch the
# live device's own files in place. Mirrors OP15 intent:
#   xtwifi: assisted-GNSS cache 5MB -> 32MB (more almanac/XTRA cached = faster
#           re-locks), debug logging off, MODEL_ID set to the real device
#           (some GTP backends tune response by model id).
#   lowi:   verbose logging off, low-power WiFi RTT path on.
# Only keys that already exist are rewritten. Gated by the GPS category.
# ---------------------------------------------------------------------------
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

asb_patch_location_inplace() {
  # $1 = device model id for GTP (e.g. OnePlus13)
  _model="$1"
  [ "$ASB_GPS" = "true" ] || { ui_print "[*] GPS category off — skipping location tuning"; return 0; }

  # Remove the shipped OP15 (canoe) copies — they carry MODEL_ID="OnePlus15"
  # and OP15-only GTP server entries. We rebuild from the live device files.
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
}

# ---------------------------------------------------------------------------
# Per-device audio + wifi config dirs (OP12 / OP13).
#
# The shipped system/vendor/etc/audio (sku_canoe/sku_alor) and .../wifi
# (wcn7750/kiwi_v2/peach_v2) dirs are OnePlus-15 hardware-specific. The overlay
# path correctly DELETES them for OP12/OP13 — but never replaces them, so those
# devices were left with no SKU audio dir and a WRONG top-level mixer_paths.xml
# (the OP15 canoe one), while their real per-codec configs live under
# sku_sun / sku_kera / sku_tuna (OP13) and sku_pineapple / sku_cliffs (OP12).
#
# Android's audio HAL selects its mixer/policy/resourcemanager by SKU at
# runtime (ro.vendor.audio.* / hw sku), so a module that overlays only the
# generic top-level file — with values for a different codec — can mis-route or
# mute paths. WiFi (WCNSS_qcom_cfg*.ini) is regulatory/chip-specific too.
#
# Fix: clone the LIVE device's own audio + wifi dirs into the module so it ships
# the device-correct configs, and drop the OP15 top-level audio policy/mixer
# files that don't belong. We do NOT cross-port OP15's tuned values onto a
# different codec/chip — that is unsafe — we restore the device's own working
# configs. (Audio EQ/volume/codec tuning still happens via the device-agnostic
# in-place pass, which name-matches and patches the device's own files.)
# ---------------------------------------------------------------------------
asb_clone_dir_from_live() {
  # $1 = absolute live source dir (e.g. /vendor/etc/audio or /system/vendor/etc/audio)
  # Computes a single canonical module dest under system/, collapsing a leading
  # /system so /system/vendor/... and /vendor/... both land at system/vendor/...
  # (never system/system/...). Returns 0 on a successful clone.
  _src="$1"
  [ -d "$_src" ] || return 1
  # canonical partition-relative path: strip a leading /system if present
  _canon="$_src"
  case "$_canon" in
    /system/*) _canon="${_canon#/system}" ;;
  esac
  _dest="$MODPATH/system${_canon}"
  rm -rf "$_dest" 2>/dev/null
  mkdir -p "$_dest" 2>/dev/null
  ( cd "$_src" && find . -type f 2>/dev/null | while IFS= read -r _f; do
      _f="${_f#./}"
      mkdir -p "$_dest/$(dirname "$_f")" 2>/dev/null
      cp -f "$_src/$_f" "$_dest/$_f" 2>/dev/null || true
    done )
  ui_print "    + ${_src} -> system${_canon}"
  return 0
}

asb_clone_device_audio_wifi() {
  # $1 = human label
  _label="$1"

  if [ "$ASB_AUDIO" = "true" ]; then
    ui_print " "
    ui_print "${SEPARATOR}"
    ui_print "[*] Device audio configs for $_label"
    ui_print "${SEPARATOR}"
    # Drop OP15 top-level audio files that are canoe/alor-specific and would
    # otherwise shadow the device's own with wrong-codec values.
    for _af in mixer_paths.xml ftm_mixer_paths.xml resourcemanager.xml \
               audio_module_config_primary.xml; do
      rm -f "$MODPATH/system/vendor/etc/$_af" 2>/dev/null || true
      rm -f "$MODPATH/system/vendor/odm/etc/$_af" 2>/dev/null || true
    done
    # Clone the device's own audio dir from the FIRST live source that exists.
    # /vendor and /system/vendor usually resolve to the same files, so we take
    # only one to avoid cloning the same tree to two dests.
    _audio_done=0
    for _asrc in /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
      if [ -d "$_asrc" ]; then
        asb_clone_dir_from_live "$_asrc" && { _audio_done=1; break; }
      fi
    done
    [ "$_audio_done" = "1" ] || ui_print "    - no device audio dir found"
  fi

  # NOTE: Wi-Fi is handled separately by asb_patch_wifi_inplace, which clones
  # the device's stock wifi dir and sed-patches only the WCNSS driver .ini
  # values — never the supplicant .conf files (their p2p_disabled/tdls lines are
  # load-bearing for the Wi-Fi toggle). Regulatory country stays runtime in
  # service.sh.
}

# ---------------------------------------------------------------------------
# Per-device mixer tuning (OP12 / OP13) — the portable subset of the OP15 sound.
#
# OnePlus 15 ships a hand-tuned canoe mixer with ~44 control changes. Most are
# canoe-codec-specific (HiFi Function, DS2 OnOff, Amp DSP Enable, Audiosphere,
# Virtual Bass …) and DO NOT exist on OP13's WCD9395 / OP12's WCD9395 mixer, so
# injecting them would be wrong or harmful. What IS shared across all three
# codecs — verified against each device's own stock mixer — is the *character*
# of the tune:
#   * RX_RX0/1/2 Digital Volume 84 -> 88   (the +4-step louder playback)
#   * IIR0 Enable Band1..5 -> 0            (flatten the stock EQ coloring)
#   * HPHL/HPHR_RDAC Switch 0 -> 1         (Class-H headphone DAC always armed)
# These edits use name-anchored sed so they only touch controls that already
# exist; on a codec lacking a given control the edit is simply a no-op. Applied
# to the device's freshly-cloned mixer files (every sku_* / cdp/mtp/qrd variant).
# Gated by the audio category.
# ---------------------------------------------------------------------------
asb_patch_one_mixer() {
  _f="$1"; [ -f "$_f" ] || return 0
  # Louder playback: raise Digital Volume to 88 on both the RX (headphone)
  # and WSA (speaker amp) paths — matches what the OP15 mixer pass does, so
  # the speaker gets the same boost as headphones. Covers stock 80-87.
  for _v in 80 81 82 83 84 85 86 87; do
    sedi "s/\\(name=\"RX_RX[012] Digital Volume\" value=\"\\)${_v}\"/\\188\"/g" "$_f"
    sedi "s/\\(name=\"WSA_RX[01] Digital Volume\" value=\"\\)${_v}\"/\\188\"/g" "$_f"
  done
  # flat EQ: disable IIR0 bands that stock leaves engaged
  sedi 's/\(name="IIR0 Enable Band[1-5]" value="\)1"/\10"/g' "$_f"
  # Class-H headphone DAC armed
  sedi 's/\(name="HPH[LR]_RDAC Switch" value="\)0"/\11"/g' "$_f"
  # NOTE: the opt-in aggressive layer (compander off, HPH HIFI) is NOT applied
  # here anymore — it is applied at boot by post-fs-data from the .asbbase
  # baseline so the AUDIO_AGGRESSIVE toggle takes effect on a plain reboot.
}

asb_patch_audio_inplace_aggr_flag() {
  # Read the AUDIO_AGGRESSIVE toggle from governor.conf so the mixer pass can
  # honor the user's choice at install time. Default 0 (stock-safe).
  _ASB_AUDIO_AGGR="$(grep -E '^[[:space:]]*AUDIO_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_AUDIO_AGGR" ] || _ASB_AUDIO_AGGR=0
}

asb_camera_aggr_flag() {
  # Read the camera grade LEVEL (0..4) from governor.conf, with back-compat for
  # the old CAMERA_AGGRESSIVE bool (=1 -> level 3). Default 0 (stock-safe).
  _ASB_CAMERA_LEVEL="$(grep -E '^[[:space:]]*CAMERA_LEVEL=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_ASB_CAMERA_LEVEL" in ''|*[!0-9]*) _ASB_CAMERA_LEVEL="" ;; esac
  _ASB_CAMERA_AGGR="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  [ -n "$_ASB_CAMERA_AGGR" ] || _ASB_CAMERA_AGGR=0
  if [ -z "$_ASB_CAMERA_LEVEL" ]; then
    [ "$_ASB_CAMERA_AGGR" = "1" ] && _ASB_CAMERA_LEVEL=3 || _ASB_CAMERA_LEVEL=0
  fi
  [ "$_ASB_CAMERA_LEVEL" -gt 0 ] 2>/dev/null && _ASB_CAMERA_AGGR=1 || _ASB_CAMERA_AGGR=0
  # Separate, riskier opt-in: INJECT tone keys the device's stock conf_tuning
  # doesn't ship (its camera HAL may not consume them). Sub-control of the
  # camera toggle, a seg with values safe|aggressive (aggressive = inject).
  _inj_raw="$(grep -E '^[[:space:]]*CAMERA_AGGRESSIVE_INJECT=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_inj_raw" in
    aggressive|1) _ASB_CAMERA_INJECT=1 ;;
    *)            _ASB_CAMERA_INJECT=0 ;;
  esac
}

asb_guard_v4a_effects() {
  # Decide whether V4A (ViPER4Android FX) is safe on THIS device, then keep or
  # strip it from the module's audio_effects files accordingly.
  #
  # Detection: probe the live device's OWN stock audio_effects for a v4a
  # reference. If the stock config already wires v4a, the platform ships
  # libv4a_re.so (Android is loading it today) and V4A is safe to keep. If no
  # stock config mentions v4a, the library is absent and referencing it would
  # crash audioserver at boot -> BOOTLOOP, so we strip it. This stock-reference
  # signal is far more reliable than probing soundfx lib paths directly (which
  # can miss the lib due to SELinux or non-standard locations and false-strip a
  # device that actually has V4A — that mistake removed OnePlus 15's V4A).
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
  # Also scan the device's per-sku audio dirs (where OP12/OP13/OP15 keep them).
  if [ "$_v4a_ok" = "0" ]; then
    for _sf in $(find /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio \
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
      # Inline removal — the v4a effect can share a line with a closing
      # </effectProxy>, so whole-line deletion would corrupt the XML.
      sedi 's#<effect name="v4a_standard_re"[^/]*/>##g' "$_ef"
      sedi 's#<library name="v4a_re"[^/]*/>##g' "$_ef"
      _stripped=$((_stripped + 1))
    fi
  done
  return 0
}

asb_patch_audio_inplace() {
  # $1 = human label
  [ "$ASB_AUDIO" = "true" ] || { ui_print "[*] Audio category off — skipping mixer tune"; return 0; }
  _adir="$MODPATH/system/vendor/etc/audio"
  [ -d "$_adir" ] || { ui_print "[*] No cloned audio dir — skipping mixer tune"; return 0; }

  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Mixer tune for $1 (portable OP15 sound)"
  ui_print "${SEPARATOR}"

  _n=0
  for _mx in $(find "$_adir" -type f -name "mixer_paths*.xml" 2>/dev/null); do
    asb_patch_one_mixer "$_mx"
    _n=$((_n + 1))
  done
  # Save baselines (base tweaks, no aggressive) to the external store and reflect
  # the current toggle state immediately; boot keeps it in sync afterwards.
  if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
    . "$MODPATH/runtime/asb_tweaks.sh"
    asb_save_dynamic_baselines "$MODPATH"
    asb_apply_dynamic_tweaks "$MODPATH"
  fi
  asb_patch_audio_inplace_aggr_flag
  if [ "$_ASB_AUDIO_AGGR" = "1" ]; then
    ui_print "    + tuned $_n mixer file(s): vol->88, flat EQ, Class-H DAC, +aggressive (compander off, HPH HIFI)"
  else
    ui_print "    + tuned $_n mixer file(s): vol->88 (RX+speaker), flat EQ, Class-H DAC"
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

asb_preserve_user_config() {
  # On REINSTALL/UPDATE, carry the user's WebUI choices over the freshly-shipped
  # governor.conf. We look in TWO places for the old values, in priority order:
  #   1. the previous install's config/governor.conf (live or update-staged), and
  #   2. an external snapshot at /data/adb/asb/governor.conf.snapshot that we
  #      write at the end of every install (below). The snapshot is the reliable
  #      one: on a version jump or certain KSU/APatch update flows the old module
  #      dir may already be swapped out when we run, which is why users saw their
  #      V52 toggles reset on the V54 update. The snapshot lives outside the
  #      module so it always survives.
  _new_conf="$MODPATH/config/governor.conf"
  _old_conf="$NVBASE/modules/$MODID/config/governor.conf"
  [ -f "$_old_conf" ] || _old_conf="$NVBASE/modules_update/$MODID/config/governor.conf"
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  # Pick the best available source of old values.
  _src=""
  [ -f "$_old_conf" ] && _src="$_old_conf"
  [ -z "$_src" ] && [ -f "$_snap_conf" ] && _src="$_snap_conf"
  if [ -z "$_src" ]; then ui_print "[*] Fresh install - using default config"; return 0; fi

  _user_keys="AUDIO_AGGRESSIVE AUDIO_EQ_COMPAT CAMERA_LEVEL CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias \
bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable \
night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_ANIM_SCALE UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale device_bounds_override"

  _migrated=0
  for _k in $_user_keys; do
    # prefer the live old config, but fall back per-key to the snapshot so a
    # value present in either source is preserved.
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

# Write an external snapshot of the user-settable keys so the NEXT install can
# restore them even if the old module dir is gone (see asb_preserve_user_config).
asb_snapshot_user_config() {
  _new_conf="$MODPATH/config/governor.conf"
  _snap_conf="/data/adb/asb/governor.conf.snapshot"
  [ -f "$_new_conf" ] || return 0
  mkdir -p "$(dirname "$_snap_conf")" 2>/dev/null || true
  _keys="AUDIO_AGGRESSIVE AUDIO_EQ_COMPAT CAMERA_LEVEL CAMERA_AGGRESSIVE CAMERA_AGGRESSIVE_INJECT \
smart_battery_bias bt_absvol_mode BG_TRIM_LEVEL cool_gaming \
auto_battery_enable charge_aware_enable night_quiet_enable night_quiet_auto \
UX_ANIM_FORCE_RESTART UX_MANAGE_ANIM_SCALE UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
region_allow_locale device_bounds_override"
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
  # Always strip any system/odm/etc/camera mirror: we ship the camera overlay to
  # system/vendor/odm ONLY (matching the known-good module). A system/odm camera
  # copy is what made APatch stack a mount over the real /odm and crash the
  # multicamera HAL, so we remove it unconditionally to clean up any stale mirror
  # a previous (broken) build may have left.
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

# Clean up the per-module work litter some root managers leave next to the
# module dir (".AutoSystemBoost-files" marker + "CLEAR" dir). Do it at INSTALL
# too, not just uninstall, so a reinstall over a previous version clears any
# stale artifact immediately instead of waiting for a future removal.
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

asb_detect_compat
asb_detect_manager
if [ "$ASB_IS_OP15" = "true" ]; then
  ui_print " "
  ui_print "${SEPARATOR}"
  ui_print "[*] Full OnePlus 15 package will be installed"
  ui_print "${SEPARATOR}"
fi
asb_prune_module

if [ "$ASB_IS_OP15" = "true" ]; then
  # OP15: keep the hand-tuned audio/wifi overlay (irreproducible by sed), but
  # run perf + location the same dynamic in-place way as OP13/OP12 so those
  # static files can be dropped from the shipped archive.
  asb_patch_perf_inplace "OnePlus 15 (canoe)"
  asb_patch_location_inplace "OnePlus15"
  asb_patch_wifi_inplace "OnePlus 15 (canoe)"
  # The shipped OP15 mixers already carry vol=88 / flat EQ / Class-H DAC, and
  # the conf_tuning is in system/. Save baselines and apply the opt-in
  # aggressive layers through the dynamic engine so the AUDIO_AGGRESSIVE /
  # CAMERA_AGGRESSIVE / _INJECT toggles take effect on a plain reboot.
  if [ "$ASB_AUDIO" = "true" ] || [ "$ASB_CAMERA" = "true" ]; then
    if [ -r "$MODPATH/runtime/asb_tweaks.sh" ]; then
      . "$MODPATH/runtime/asb_tweaks.sh"
      asb_save_dynamic_baselines "$MODPATH"
      asb_apply_dynamic_tweaks "$MODPATH"
    fi
  fi
elif [ "$ASB_IS_OP13" = "true" ]; then
  asb_apply_device_overlay op13_overlay "OnePlus 13 (CPH2649 / SM8750 'sun')"
  asb_clone_device_audio_wifi "OnePlus 13 (sun / tuna / kera)"
  asb_patch_audio_inplace "OnePlus 13 (sun / tuna / kera)"
  asb_patch_perf_inplace "OnePlus 13 (sun / tuna / kera)"
  asb_patch_location_inplace "OnePlus13"
  asb_patch_wifi_inplace "OnePlus 13 (sun / tuna / kera)"
elif [ "$ASB_IS_OP12" = "true" ]; then
  asb_apply_device_overlay op12_overlay "OnePlus 12 (CPH2581 / SM8650 'pineapple')"
  # NOTE: no asb_op12_camera_off here. The old working OP12 build simply applied
  # the overlay to system/vendor/odm and the camera worked; the later
  # "hard camera-off" path plus the system/odm mirror were themselves the
  # regression that SIGABRTed the multicamera HAL. OP12 camera is back to the
  # proven working path (overlay to system/vendor/odm only, no /odm mirror).
  #
  # UPGRADE PATH FIX: a user coming FROM a regressed build still has that build's
  # system/odm/etc/camera mirror in the previous install dir, which the manager
  # may keep mounted into the real /odm until reboot — so the camera kept
  # crashing even after installing the corrected module. Scrub the camera/media
  # mirror out of the previous install (and our own staging, belt-and-braces) so
  # nothing re-mounts the OP15-shaped multicamera env into /odm on OP12.
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
  ui_print "[*] OP12: camera overlay -> system/vendor/odm only (no /odm mirror)"
  asb_clone_device_audio_wifi "OnePlus 12 (pineapple / cliffs)"
  asb_patch_audio_inplace "OnePlus 12 (pineapple / cliffs)"
  asb_patch_perf_inplace "OnePlus 12 (pineapple / cliffs)"
  asb_patch_location_inplace "OnePlus12"
  asb_patch_wifi_inplace "OnePlus 12 (pineapple / cliffs)"
else
  asb_prune_non_op15_vendor_overlays
fi
# Clean up any unused overlay staging dirs on non-OP12/13 paths too.
rm -rf "$MODPATH/op12_overlay" "$MODPATH/op13_overlay" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Regional localization: the shipped WiFi/GPS configs were authored with an
# Italian regulatory domain (gCountryCode=IT, country=IT, it.pool.ntp.org).
# WiFi country code is regulatory — a wrong one blocks channels or violates
# local rules — so we detect the installing device's country and rewrite it.
# Source of truth (no network needed): the SIM/network ISO country from the
# modem. Falls back to leaving the value untouched if nothing is detectable.
# ---------------------------------------------------------------------------
asb_localize_region() {
  _cc=""
  _src="none"
  # Trust only the modem's ISO country (SIM first, then network operator).
  # locale is deliberately NOT used by default — locale != real location, and
  # rewriting a Wi-Fi regulatory domain on a guess is risky. A user who wants
  # locale as a last resort can set region_allow_locale=1 in the config.
  for _p in gsm.sim.operator.iso-country gsm.operator.iso-country; do
    _v="$(getprop "$_p" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    case "$_v" in
      [A-Z][A-Z]) _cc="$_v"; _src="$([ "$_p" = "gsm.sim.operator.iso-country" ] && echo sim || echo operator)"; break ;;
    esac
  done

  # Optional opt-in: locale region only as a last resort, only if asked.
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

  # NTP -> global pool is region-neutral and always safe; do it regardless.
  for _gf in $(find "$MODPATH/system" -type f -iname "gps.conf" 2>/dev/null); do
    [ -f "$_gf" ] && sed -i "s|^NTP_SERVER=.*|NTP_SERVER=pool.ntp.org|g" "$_gf" 2>/dev/null
  done

  if [ -z "$_cc" ]; then
    return 0
  fi

  # Wi-Fi country: only REPLACE an existing country line — never insert one.
  # If a device ships WCNSS/supplicant without an explicit gCountryCode (e.g.
  # OP13), that's intentional: the modem drives the regulatory domain at
  # runtime. Forcing a SIM-derived country there could set the wrong regdomain
  # (travel, roaming), so we leave those files untouched.
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

# ---------------------------------------------------------------------------
# Bluetooth absolute-volume mode (bt_absvol_mode = auto|on|off).
# Absolute volume delegates loudness to the BT sink. Disabling it can be
# louder on some car head-units / speakers, but it can also change the volume
# scale, step granularity and dual-control behavior — so it is NOT a safe
# universal default. We honor an explicit config choice; auto = off for now.
# ---------------------------------------------------------------------------
asb_apply_bt_absvol() {
  _prop="$MODPATH/system.prop"
  [ -f "$_prop" ] || return 0
  _mode="$(grep -E '^[[:space:]]*bt_absvol_mode=' "$MODPATH/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [ -n "$_mode" ] || _mode="auto"
  if [ "$_mode" = "auto" ]; then
    # AUTO = hands-off. Strip our absolute-volume / AVRCP-override props from
    # system.prop so we don't force values on every boot (which desyncs BT
    # volume until an audio restart, e.g. opening ViPER). None of these exist
    # in OP12 stock, and forcing newavrcp changes volume negotiation. The stock
    # BT stack keeps its own behavior.
    sed -i '/^persist\.bluetooth\.disableabsvol=/d' "$_prop" 2>/dev/null
    sed -i '/^persist\.vendor\.bluetooth\.disableabsvol=/d' "$_prop" 2>/dev/null
    sed -i '/^persist\.bluetooth\.enablenewavrcp=/d' "$_prop" 2>/dev/null
    ASB_BT_ABSVOL_APPLIED="mode=auto (absolute-volume + avrcp left stock)"
    return 0
  fi
  case "$_mode" in
    on)  _val="true" ;;
    off) _val="false" ;;
    *)   _val="false" ;;
  esac
  # Only the BT block ships these props; rewrite both to the chosen value.
  sed -i "s/^persist.bluetooth.disableabsvol=.*/persist.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  sed -i "s/^persist.vendor.bluetooth.disableabsvol=.*/persist.vendor.bluetooth.disableabsvol=$_val/" "$_prop" 2>/dev/null
  ASB_BT_ABSVOL_APPLIED="mode=$_mode disableabsvol=$_val"
  ui_print "[*] BT volume mode: $_mode"
}
[ "$ASB_BT" = "true" ] && asb_apply_bt_absvol

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
RADIO_IMS=$([ "$ASB_RADIO_IMS" = "true" ] && echo 1 || echo 0)
DISPLAY=$([ "$ASB_DISPLAY" = "true" ] && echo 1 || echo 0)
FPS=$([ "$ASB_FPS" = "true" ] && echo 1 || echo 0)
SECURITY=$([ "$ASB_SECURITY" = "true" ] && echo 1 || echo 0)
BG_TRIM=$([ "$ASB_BG_TRIM" = "true" ] && echo 1 || echo 0)
VENDOR_OVERLAY=1
EOF

# ---------------------------------------------------------------------------
# Install summary — a single human-readable file capturing what was applied,
# so post-install debugging doesn't require guessing. Lives next to the module.
# ---------------------------------------------------------------------------
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

# Device discovery (facts only — writes /data/adb/asb/device_caps.env, changes
# no tunable). Captures the real CPU topology, GPU back-end, thermal zone count
# and subsystem path presence so asbdiag can show them and future per-device
# tuning has a stable, inspectable input. Safe to run at every install.
if [ -f "$MODPATH/tools/asb_discover.sh" ]; then
  sh "$MODPATH/tools/asb_discover.sh" >/dev/null 2>&1 || true
fi

# Bounds synthesis (Phase 2): reads the just-written device_caps.env and scales
# the OP15 reference ratios onto THIS device's real frequencies, writing
# /data/adb/asb/device_bounds.env. The governor only consumes that file when
# device_bounds_override=1 (off by default), and on OP15 the synthesised values
# equal the shipped bounds — so this is safe to run at every install. On a
# non-2-cluster SoC it writes a low-confidence marker and emits no overrides.
if [ -f "$MODPATH/tools/asb_synthesize_bounds.sh" ]; then
  sh "$MODPATH/tools/asb_synthesize_bounds.sh" >/dev/null 2>&1 || true
fi

echo 0 > "/data/adb/asb/vendor_boot_counter" 2>/dev/null
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
	sedi "/^ *$/d" $ACCXM
	done

  for OSNDTRPL in ${SNDTRPL}; do
	cp_ch $ORIGDIR$OSNDTRPL $SNDTRP
	sedi "/^ *$/d" $SNDTRP
	done

  for OMEDCX in ${MEDCA}; do
	cp_ch $ORIGDIR$OMEDCX $MEDCX
	sedi "/^ *$/d" $MEDCX
	done

  for OMIX in ${MPATHS}; do
	cp_ch $ORIGDIR$OMIX $MIX
	sedi "/^ *$/d" $MIX
	done

  if [ "${ASB_BT}" = "true" ]; then
  for OA2DPXML in ${A2DPXML}; do
	cp_ch $ORIGDIR$OA2DPXML $A2DPXM
	sedi '/^ *$/d' $A2DPXM
	done

  for OBTQTIXML in ${BTQTIXML}; do
	cp_ch $ORIGDIR$OBTQTIXML $BTQTIXM
	sedi '/^ *$/d' $BTQTIXM
	done

  fi

  for OVEHXML in ${VEHXML}; do
	cp_ch $ORIGDIR$OVEHXML $VEHXM
	sedi "/^ *$/d" $VEHXM
	done

  for OVIRTXML in ${VIRTXML}; do
	cp_ch $ORIGDIR$OVIRTXML $VIRTXM
	sedi "/^ *$/d" $VIRTXM
	done

  for OUSBXML in ${USBXML}; do
	cp_ch $ORIGDIR$OUSBXML $USBXM
	sedi "/^ *$/d" $USBXM
	done

  for OAPCXM in ${APCXML}; do
	cp_ch $ORIGDIR$OAPCXM $APCXM
	sedi "/^ *$/d" $APCXM
	done

  for OAPIOCXM in ${APIOCXML}; do
	cp_ch $ORIGDIR$OAPIOCXM $APIOCXM
	sedi "/^ *$/d" $APIOCXM
	done

  for OAPLI in ${APINF}; do
	cp_ch $ORIGDIR$OAPLI $APLI
	sedi "/^ *$/d" $APLI
	done

  for OACONF in ${ACONFS}; do
	cp_ch $ORIGDIR$OACONF $ACONF
	sedi "/^ *$/d" $ACONF
	done

  # V4A (ViPER4Android FX) wiring is only safe when libv4a_re.so actually
  # exists on the device. OP15's OxygenOS ships it; some OP13/OP12 builds do
  # not. Referencing a missing effect library makes audioserver fail to load
  # audio_effects at boot -> audio HAL crash loop -> BOOTLOOP. Detect the
  # library ONCE here, report status once, then apply across all effect files.
  _v4a_lib=""
  for _vd in /vendor/lib64/soundfx /vendor/lib/soundfx \
             /odm/lib64/soundfx /odm/lib/soundfx \
             /system/lib64/soundfx /system/lib/soundfx \
             /system/vendor/lib64/soundfx /system/vendor/lib/soundfx; do
    if [ -f "$_vd/libv4a_re.so" ]; then _v4a_lib="$_vd/libv4a_re.so"; break; fi
  done
  # V4A is wired only when the library exists; applied silently either way.
  for OAEFFECT in ${AEFFECT}; do
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

	# Diagnostic launcher (short command: `su -c asbdiag`) + the script it runs.
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

	asb_preserve_user_config

	if [ -f "$MODPATH/config/governor.conf" ]; then
	  cp -f "$MODPATH/config/governor.conf" "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
	  chmod 644 "$MODPATH/config/governor.conf.shipped" 2>/dev/null || true
	fi

	# Persist the (possibly just-restored) WebUI settings to an external snapshot
	# so the NEXT update/reinstall can recover them even if the old module dir is
	# gone — this is what stops toggles resetting across a version jump.
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

# BOOTLOOP GUARD (all devices, runs after ALL audio processing): module
# audio_effects files may carry a V4A (ViPER4Android FX) library reference —
# either shipped baked-in or re-added by the dynamic effect pass. If
# libv4a_re.so is absent, audioserver fails to load effects at boot -> audio
# HAL crash loop -> BOOTLOOP (this bricked OnePlus 12). Strip V4A unless the
# library exists. OnePlus 15 (which ships the lib) keeps it.
asb_guard_v4a_effects

# P1 hygiene: some stock video_beauty_default_config files carry a // line
# comment (e.g. "// Sort by English alphabet"). The file is otherwise JSON and
# a strict parser can choke on it. Strip whole-line // comments from every copy
# the module ships, on all devices and both odm paths.
for _vb in $(find "$MODPATH/system" -type f -name "video_beauty_default_config" 2>/dev/null); do
  if grep -q '//' "$_vb" 2>/dev/null; then
    _vbt="${_vb}.asbc$$"
    if sed '/^[[:space:]]*\/\//d' "$_vb" > "$_vbt" 2>/dev/null; then
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
