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

# Rebuild the overlay's volume table for the given percentage, from the pristine
# stock stash. Returns 0 when the overlay file now matches the request.
asb_volume_curves_build() {
  _vc_mod="$1"
  _vc_pct="$2"
  [ -d "$_vc_mod" ] || return 1
  _vc_dst="$_vc_mod/system/vendor/etc/default_volume_tables.xml"

  if [ "$_vc_pct" = "100" ]; then
    rm -f "$_vc_dst" 2>/dev/null
    return 0
  fi

  _vc_src="$(asb_volume_table_src)"
  [ -n "$_vc_src" ] && [ -f "$_vc_src" ] || return 1

  mkdir -p "$(dirname "$_vc_dst")" 2>/dev/null || return 1
  cp -f "$_vc_src" "$_vc_dst" 2>/dev/null || return 1
  chmod 0644 "$_vc_dst" 2>/dev/null
  asb_reshape_volume_curves "$_vc_dst" "$_vc_pct"
  grep -q 'ASB:VOLCURVE' "$_vc_dst" 2>/dev/null || { rm -f "$_vc_dst" 2>/dev/null; return 1; }
  _vc_ctx="$(ls -Zd /vendor/etc/default_volume_tables.xml 2>/dev/null | awk '{print $1}')"
  case "$_vc_ctx" in
    ?*:?*:?*:?*) chcon "$_vc_ctx" "$_vc_dst" 2>/dev/null || true ;;
  esac
  return 0
}

asb_volume_curves_pct() {
  case "$1" in
    mild)   echo 80 ;;
    strong) echo 65 ;;
    max)    echo 40 ;;
    *)      echo 100 ;;
  esac
}
