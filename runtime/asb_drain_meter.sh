DM_DIR="${ASB_DM_DIR:-/data/adb/asb}"
DM_FILE="$DM_DIR/drain_meter"
DM_LIVE="${ASB_DM_LIVE:-/dev/.asb_drain_meter}"
DM_PSY="${ASB_DM_PSY:-/sys/class/power_supply}"
DM_PS="${ASB_DM_PS:-$DM_PSY/battery}"
DM_BL="${ASB_DM_BL:-/sys/class/backlight}"
DM_PROF_FILE="${ASB_DM_PROFILE:-/data/adb/modules/AutoSystemBoost/current_profile}"
DM_PROFILES="smart balanced battery performance stock"

dm_prof=""
dm_prev_ts=""
dm_prev_pct=""
dm_prev_scr=""
dm_off_ts=""
dm_off_pct=""
dm_off_media=0
dm_aud_run=0
dm_glance_ts=""
dm_glance_pct=""
# A glance does not end a night (fix178): a screen-on shorter than this is folded into the
# screen-off window, as the governor's own screen-off meter does. Checking the time once in
# the night split every window under the hour, and no profile ever got a screen-off figure.
DM_GLANCE_S="${ASB_DM_GLANCE_S:-120}"
dm_dirty=0
dm_flush_ts=0

dm_get() {
  eval "printf '%s' \"\${dm_${1}_${2}:-0}\""
}

dm_set() {
  eval "dm_${1}_${2}=\$3"
}

dm_load() {
  for _dp in $DM_PROFILES; do
    for _df in on_s on_x off_s off_x off_n; do dm_set "$_dp" "$_df" 0; done
  done
  [ -r "$DM_FILE" ] || return 0
  while read -r _dp _a _b _c _d _e _rest; do
    case " $DM_PROFILES " in *" $_dp "*) : ;; *) continue ;; esac
    for _dv in "$_a" "$_b" "$_c" "$_d" "$_e"; do
      case "$_dv" in ''|*[!0-9]*) continue 2 ;; esac
    done
    dm_set "$_dp" on_s "$_a"; dm_set "$_dp" on_x "$_b"
    dm_set "$_dp" off_s "$_c"; dm_set "$_dp" off_x "$_d"; dm_set "$_dp" off_n "$_e"
  done < "$DM_FILE"
}

dm_table() {
  for _dp in $DM_PROFILES; do
    printf '%s %s %s %s %s %s\n' "$_dp" "$(dm_get "$_dp" on_s)" "$(dm_get "$_dp" on_x)" \
      "$(dm_get "$_dp" off_s)" "$(dm_get "$_dp" off_x)" "$(dm_get "$_dp" off_n)"
  done
}

dm_publish() {
  { dm_table; printf 'current %s\n' "${dm_prof:-none}"; } > "$DM_LIVE.tmp" 2>/dev/null \
    && mv -f "$DM_LIVE.tmp" "$DM_LIVE" 2>/dev/null
}

dm_flush() {
  mkdir -p "$DM_DIR" 2>/dev/null
  dm_table > "$DM_FILE.tmp" 2>/dev/null && mv -f "$DM_FILE.tmp" "$DM_FILE" 2>/dev/null
  dm_dirty=0
  dm_flush_ts="$1"
}

dm_add_on() {
  _ds=$(( $(dm_get "$dm_prof" on_s) + $1 ))
  _dx=$(( $(dm_get "$dm_prof" on_x) + $2 * 100 ))
  if [ "$_ds" -gt 14400 ]; then _ds=$((_ds / 2)); _dx=$((_dx / 2)); fi
  dm_set "$dm_prof" on_s "$_ds"; dm_set "$dm_prof" on_x "$_dx"
  dm_dirty=1
}

dm_add_off() {
  _ds=$(( $(dm_get "$dm_prof" off_s) + $1 ))
  _dx=$(( $(dm_get "$dm_prof" off_x) + $2 * 100 ))
  _dn=$(( $(dm_get "$dm_prof" off_n) + 1 ))
  if [ "$_ds" -gt 172800 ]; then
    _ds=$((_ds / 2)); _dx=$((_dx / 2)); _dn=$((_dn / 2)); [ "$_dn" -ge 1 ] || _dn=1
  fi
  dm_set "$dm_prof" off_s "$_ds"; dm_set "$dm_prof" off_x "$_dx"; dm_set "$dm_prof" off_n "$_dn"
  dm_dirty=1
}

dm_step() {
  _n="$1"; _p="$2"; _c="$3"; _s="$4"; _pf="$5"; _m="$6"
  case " $DM_PROFILES " in *" $_pf "*) : ;; *) _pf="" ;; esac
  if [ "$_pf" != "$dm_prof" ]; then
    dm_prof="$_pf"; dm_prev_ts=""; dm_prev_scr=""; dm_off_ts=""; dm_off_media=0; dm_aud_run=0; dm_glance_ts=""
  fi
  [ -n "$dm_prof" ] || return 0
  case "$_p" in ''|*[!0-9]*) dm_prev_ts=""; return 0 ;; esac
  case "$_n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_c" = 1 ]; then
    dm_prev_ts=""; dm_off_ts=""; dm_off_media=0; dm_aud_run=0; dm_glance_ts=""; dm_prev_scr="$_s"
    return 0
  fi
  if [ "$_s" = 1 ]; then
    if [ -n "$dm_off_ts" ]; then
      # The window ends where the screen came on, once it has stayed on past a glance.
      [ -n "$dm_glance_ts" ] || { dm_glance_ts="$_n"; dm_glance_pct="$_p"; }
      if [ $((_n - dm_glance_ts)) -ge "$DM_GLANCE_S" ]; then
        _dd=$((dm_glance_ts - dm_off_ts)); _dq=$((dm_off_pct - dm_glance_pct))
        if [ "$_dd" -ge 3600 ] && [ "$dm_off_media" = 0 ] && [ "$_dq" -ge 0 ] && [ "$_dq" -le 50 ]; then
          dm_add_off "$_dd" "$_dq"
        fi
        dm_off_ts=""; dm_off_media=0; dm_aud_run=0; dm_glance_ts=""
      fi
    fi
    if [ "$dm_prev_scr" = 1 ] && [ -n "$dm_prev_ts" ]; then
      _dd=$((_n - dm_prev_ts)); _dq=$((dm_prev_pct - _p))
      if [ "$_dd" -gt 0 ] && [ "$_dd" -le 90 ]; then
        { [ "$_dq" -gt 0 ] && [ "$_dq" -le 5 ]; } || _dq=0
        dm_add_on "$_dd" "$_dq"
      fi
    fi
  else
    # Off again within the glance: the same window goes on.
    dm_glance_ts=""
    if [ -z "$dm_off_ts" ]; then dm_off_ts="$_n"; dm_off_pct="$_p"; dm_off_media=0; dm_aud_run=0; fi
    # Playback, not a sound (fix178): two samples in a row with audio, about a minute of it.
    # One notification - or the first sample after the screen went off, which saw the screen-on
    # audio - no longer threw the whole night away.
    if [ "$_m" = 1 ]; then
      dm_aud_run=$((dm_aud_run + 1))
      [ "$dm_aud_run" -ge 2 ] && dm_off_media=1
    else
      dm_aud_run=0
    fi
  fi
  dm_prev_ts="$_n"; dm_prev_pct="$_p"; dm_prev_scr="$_s"
  return 0
}

dm_screen() {
  _dsv="$(getprop debug.tracing.screen_state 2>/dev/null)"
  case "$_dsv" in
    2|6) return 0 ;;
    1|3|4) return 1 ;;
  esac
  for _db in "$DM_BL"/*/brightness; do
    [ -r "$_db" ] || continue
    _dbv=0; read -r _dbv < "$_db" 2>/dev/null
    [ "${_dbv:-0}" -gt 0 ] 2>/dev/null && return 0
  done
  return 1
}

dm_charging() {
  _dst=""; [ -r "$DM_PS/status" ] && read -r _dst < "$DM_PS/status" 2>/dev/null
  case "$_dst" in
    Charging|Full) return 0 ;;
    Discharging) return 1 ;;
  esac
  for _dsn in usb ac dc wireless wls pc_port; do
    _dso=""; [ -r "$DM_PSY/$_dsn/online" ] && read -r _dso < "$DM_PSY/$_dsn/online" 2>/dev/null
    [ "$_dso" = 1 ] && return 0
  done
  return 1
}

dm_loop() {
  dm_load
  _dl_dir="$(dirname "$0")"
  [ -r "$_dl_dir/asb_audio_activity.sh" ] && . "$_dl_dir/asb_audio_activity.sh"
  while :; do
    _ln="$(date +%s 2>/dev/null)"
    _lp=""; [ -r "$DM_PS/capacity" ] && read -r _lp < "$DM_PS/capacity" 2>/dev/null
    _lc=0; dm_charging && _lc=1
    _ls=0; dm_screen && _ls=1
    _lf=""; [ -r "$DM_PROF_FILE" ] && read -r _lf < "$DM_PROF_FILE" 2>/dev/null
    _lm=0
    if [ "$_ls" = 0 ] && command -v asb_audio_sig >/dev/null 2>&1; then
      # The thread-activity probe compares with its previous call, and it is only called with
      # the screen off - so the first call after a screen-on period counted everything the
      # audio threads did while the phone was in use (taps, a video) as screen-off playback,
      # and every window was dropped as "music". The ROMs without readable PCM status (the
      # OP15 among them) measured no screen-off drain at all (fix178). Start it afresh here.
      [ "$dm_prev_scr" = 0 ] || _aa_prev=""
      asb_audio_sig
      [ -n "${_aa_sig:-}" ] && _lm=1
    fi
    _was="$dm_prof"; _was_scr="$dm_prev_scr"
    dm_step "$_ln" "$_lp" "$_lc" "$_ls" "$_lf" "$_lm"
    if [ "$dm_dirty" = 1 ] || [ "$_was" != "$dm_prof" ]; then dm_publish; fi
    if [ "$dm_dirty" = 1 ]; then
      if [ "$_was" != "$dm_prof" ] || { [ "$_was_scr" = 1 ] && [ "$_ls" = 0 ]; } || [ $((_ln - dm_flush_ts)) -ge 600 ]; then
        dm_flush "$_ln"
      fi
    fi
    [ -s "$DM_LIVE" ] || dm_publish
    if [ "$_ls" = 1 ]; then sleep 30; else sleep 60; fi
  done
}

case "${1:-}" in
  run)
    _dl_pid="$DM_LIVE.pid"
    if [ -r "$_dl_pid" ]; then
      read -r _dl_old < "$_dl_pid" 2>/dev/null
      [ -n "${_dl_old:-}" ] && kill -0 "$_dl_old" 2>/dev/null && exit 0
    fi
    echo $$ > "$_dl_pid" 2>/dev/null
    dm_loop
    ;;
esac
