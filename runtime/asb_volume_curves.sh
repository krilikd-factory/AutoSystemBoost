#!/system/bin/sh
# asb_volume_curves.sh - the media_loudness volume-table reshape, as a library.
#
# This used to live only inside common/install.sh, which meant the curves were
# rebuilt at FLASH time and nowhere else. Changing media_loudness in the WebUI
# wrote the config, the UI said "reboot to apply", and the reboot could not
# possibly apply it - nothing rebuilds the table outside the installer. Field
# report: "loudness max - volume table not reshaped" on a device where the
# setting had been changed after install and the phone rebooted twice.
#
# Both callers source this file, so the installer and the runtime path share one
# implementation and cannot drift apart.

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

# Every volume table this device actually ships.
#
# The reshaper used to know exactly one path, /vendor/etc/default_volume_tables.xml,
# and that is the GENERIC AOSP copy. On OxygenOS the tuned tables live under the ODM
# paths - on a OnePlus 15 those are 9665-byte files full of OPLUS #ifdef blocks and
# vendor engineers' comments, against 5156 bytes for the generic one. So "media
# loudness = max" reshaped a table the audio policy very likely never reads, which is
# exactly how a boost can be applied, verified present in the overlay, and still not
# be audible. The module already clones the ODM copies into its own overlay; now the
# reshaper covers them too.
ASB_VT_PATHS="/odm/etc/audio/default_volume_tables.xml
/vendor/odm/etc/audio/default_volume_tables.xml
/vendor/etc/default_volume_tables.xml"

# Stash name for one live path: the stock copy is per-file, because these files are
# genuinely different from each other.
asb_volume_stash_for() {
  _vs_live="$1"
  _vs_name="$(printf '%s' "${_vs_live#/}" | tr '/' '_')"
  printf '/data/adb/asb/stock/%s' "$_vs_name"
}

# Pristine source for one live path, stashing it on first sight.
asb_volume_table_src() {
  _vt_live="$1"
  [ -n "$_vt_live" ] || _vt_live="/vendor/etc/default_volume_tables.xml"
  [ -f "$_vt_live" ] || return 1
  _vt_stash="$(asb_volume_stash_for "$_vt_live")"
  # Legacy stash from the single-path era - keep honouring it for /vendor/etc so an
  # existing install does not lose its captured stock.
  if [ "$_vt_live" = "/vendor/etc/default_volume_tables.xml" ] \
     && [ ! -f "$_vt_stash" ] && [ -f /data/adb/asb/stock/default_volume_tables.xml ]; then
    _vt_stash="/data/adb/asb/stock/default_volume_tables.xml"
  fi
  if [ ! -f "$_vt_stash" ]; then
    # Never stash something we already reshaped - that would freeze a boosted table
    # as "stock" and compound the boost on the next rebuild.
    grep -q 'ASB:VOLCURVE' "$_vt_live" 2>/dev/null && return 1
    mkdir -p /data/adb/asb/stock 2>/dev/null
    cp -f "$_vt_live" "$_vt_stash" 2>/dev/null || return 1
  fi
  printf '%s' "$_vt_stash"
}

# Rebuild every overlay volume table for the given percentage, from the pristine
# stock stashes. Returns 0 when at least one table now matches the request.
asb_volume_curves_build() {
  _vc_mod="$1"
  _vc_pct="$2"
  [ -d "$_vc_mod" ] || return 1
  _vc_any=0

  for _vc_live in $ASB_VT_PATHS; do
    [ -f "$_vc_live" ] || continue
    # Overlay destinations live under $MODPATH/system, and a live path that already
    # starts with /system must have it stripped or the two prefixes stack up into
    # $MODPATH/system/system/... - a path the mount layer then tries to place at
    # /system/system, which does not exist. That BOOTLOOPS the device.
    #
    # It happened: /system/vendor/... was in the path list above (it is a symlink to
    # /vendor, so it resolved to a real file and looked legitimate), and the resulting
    # system/system/vendor/odm/etc/audio/default_volume_tables.xml in the overlay was
    # the ONLY difference between a module that booted and one that did not. It is gone
    # from the list now - /vendor/odm/... is the same file - and the strip below makes
    # the class of mistake impossible rather than merely absent. It matches what the
    # rest of the installer already does (see install.sh: "${_ecl#/system}").
    _vc_rel="${_vc_live#/system}"
    _vc_dst="$_vc_mod/system${_vc_rel}"

    if [ "$_vc_pct" = "100" ]; then
      rm -f "$_vc_dst" 2>/dev/null
      _vc_any=1
      continue
    fi

    _vc_src="$(asb_volume_table_src "$_vc_live")"
    [ -n "$_vc_src" ] && [ -f "$_vc_src" ] || continue

    mkdir -p "$(dirname "$_vc_dst")" 2>/dev/null || continue
    cp -f "$_vc_src" "$_vc_dst" 2>/dev/null || continue
    chmod 0644 "$_vc_dst" 2>/dev/null
    asb_reshape_volume_curves "$_vc_dst" "$_vc_pct"
    if ! grep -q 'ASB:VOLCURVE' "$_vc_dst" 2>/dev/null; then
      rm -f "$_vc_dst" 2>/dev/null
      continue
    fi
    _vc_ctx="$(ls -Zd "$_vc_live" 2>/dev/null | awk '{print $1}')"
    case "$_vc_ctx" in
      ?*:?*:?*:?*) chcon "$_vc_ctx" "$_vc_dst" 2>/dev/null || true ;;
    esac
    _vc_any=1
  done

  [ "$_vc_any" = "1" ] && return 0
  return 1
}

asb_volume_curves_pct() {
  case "$1" in
    mild)   echo 80 ;;
    strong) echo 65 ;;
    max)    echo 40 ;;
    *)      echo 100 ;;
  esac
}
