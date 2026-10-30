DM_DIR="${ASB_DM_DIR:-/data/adb/asb}"
DM_FILE="$DM_DIR/drain_meter"
DM_LIVE="${ASB_DM_LIVE:-/dev/.asb_drain_meter}"
DM_PSY="${ASB_DM_PSY:-/sys/class/power_supply}"
DM_PS="${ASB_DM_PS:-$DM_PSY/battery}"
DM_BL="${ASB_DM_BL:-/sys/class/backlight}"
DM_PROF_FILE="${ASB_DM_PROFILE:-/data/adb/modules/AutoSystemBoost/current_profile}"
DM_PROFILES="smart balanced battery performance stock"
DM_BOOT="${ASB_DM_BOOT:-$DM_LIVE.boot}"
DM_BOOTID="${ASB_DM_BOOTID:-/proc/sys/kernel/random/boot_id}"
dm_b_id=""; dm_b_on=0; dm_b_off=0; dm_b_ts=""; dm_b_scr=""

dm_prof=""
dm_prev_ts=""
dm_prev_pct=""
dm_prev_scr=""
dm_off_ts=""
dm_off_pct=""
dm_off_media_s=0
dm_glance_ts=""
dm_glance_pct=""
# A glance does not end a night (fix178): a screen-on shorter than this is folded into the
# screen-off window, as the governor's own screen-off meter does. Checking the time once in
# the night split every window under the hour, and no profile ever got a screen-off figure.
DM_GLANCE_S="${ASB_DM_GLANCE_S:-120}"
# A short notification or an audio-thread blip must not discard a whole night. Sustained
# playback still does: count at most two minutes per sample, so suspend cannot invent audio.
DM_MEDIA_REJECT_S="${ASB_DM_MEDIA_REJECT_S:-600}"
dm_dirty=0
dm_flush_ts=0
# Screen-off windows that did not count, and why (fix189). An OP15's meter had no screen-off
# figure for Smart, the profile it runs most, while the governor counted five windows - with
# nothing on disk to say whether the windows were short, had playback in them or ended on the
# charger. "media short charge" counts, then the latest: profile:reason:minutes.
DM_REJ="$DM_DIR/drain_meter.rej"
dm_rej_media=0; dm_rej_short=0; dm_rej_charge=0; dm_rej_last="-"
dm_rej() {   # $1 reason  $2 seconds
  case "$1" in
    media) dm_rej_media=$((dm_rej_media + 1)) ;;
    short) dm_rej_short=$((dm_rej_short + 1)) ;;
    charge) dm_rej_charge=$((dm_rej_charge + 1)) ;;
  esac
  dm_rej_last="${dm_prof:-?}:$1:$(($2 / 60))"
  dm_dirty=1
}

dm_get() {
  eval "printf '%s' \"\${dm_${1}_${2}:-0}\""
}

dm_set() {
  eval "dm_${1}_${2}=\$3"
}

dm_load() {
  for _dp in $DM_PROFILES; do
    for _df in on_s on_x off_s off_x off_n off_last off_last_s off_last_at; do dm_set "$_dp" "$_df" 0; done
  done
  if [ -r "$DM_REJ" ]; then
    read -r _rm _rs _rc _rl < "$DM_REJ" 2>/dev/null
    case "$_rm$_rs$_rc" in ''|*[!0-9]*) : ;; *) dm_rej_media="$_rm"; dm_rej_short="$_rs"; dm_rej_charge="$_rc"; dm_rej_last="${_rl:--}" ;; esac
  fi
  [ -r "$DM_FILE" ] || return 0
  while read -r _dp _a _b _c _d _e _f _g _h _rest; do
    case " $DM_PROFILES " in *" $_dp "*) : ;; *) continue ;; esac
    for _dv in "$_a" "$_b" "$_c" "$_d" "$_e"; do
      case "$_dv" in ''|*[!0-9]*) continue 2 ;; esac
    done
    dm_set "$_dp" on_s "$_a"; dm_set "$_dp" on_x "$_b"
    dm_set "$_dp" off_s "$_c"; dm_set "$_dp" off_x "$_d"; dm_set "$_dp" off_n "$_e"
    # fix253 appends the latest qualifying window. Six-field files from older releases stay
    # valid and simply have no latest-window figure until the next screen-off stretch ends.
    for _dv in "${_f:-0}" "${_g:-0}" "${_h:-0}"; do
      case "$_dv" in ''|*[!0-9]*) _f=0; _g=0; _h=0; break ;; esac
    done
    dm_set "$_dp" off_last "${_f:-0}"; dm_set "$_dp" off_last_s "${_g:-0}"; dm_set "$_dp" off_last_at "${_h:-0}"
  done < "$DM_FILE"
}

dm_table() {
  for _dp in $DM_PROFILES; do
    printf '%s %s %s %s %s %s %s %s %s\n' "$_dp" "$(dm_get "$_dp" on_s)" "$(dm_get "$_dp" on_x)" \
      "$(dm_get "$_dp" off_s)" "$(dm_get "$_dp" off_x)" "$(dm_get "$_dp" off_n)" \
      "$(dm_get "$_dp" off_last)" "$(dm_get "$_dp" off_last_s)" "$(dm_get "$_dp" off_last_at)"
  done
}

dm_publish() {
  { dm_table; printf 'current %s\n' "${dm_prof:-none}"; } > "$DM_LIVE.tmp" 2>/dev/null \
    && mv -f "$DM_LIVE.tmp" "$DM_LIVE" 2>/dev/null
}

dm_flush() {
  mkdir -p "$DM_DIR" 2>/dev/null
  dm_table > "$DM_FILE.tmp" 2>/dev/null && mv -f "$DM_FILE.tmp" "$DM_FILE" 2>/dev/null
  printf '%s %s %s %s\n' "$dm_rej_media" "$dm_rej_short" "$dm_rej_charge" "$dm_rej_last" > "$DM_REJ.tmp" 2>/dev/null \
    && mv -f "$DM_REJ.tmp" "$DM_REJ" 2>/dev/null
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
  # Keep the just-finished window alongside the long-term aggregate. After a night the Monitor
  # must be able to show that night, not only an average dominated by older ones.
  dm_set "$dm_prof" off_last "$(( $2 * 360000 / $1 ))"
  dm_set "$dm_prof" off_last_s "$1"
  dm_set "$dm_prof" off_last_at "${3:-0}"
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
    dm_prof="$_pf"; dm_prev_ts=""; dm_prev_scr=""; dm_off_ts=""; dm_off_media_s=0; dm_glance_ts=""
  fi
  [ -n "$dm_prof" ] || return 0
  case "$_p" in ''|*[!0-9]*) dm_prev_ts=""; return 0 ;; esac
  case "$_n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_c" = 1 ]; then
    # A window of ten minutes or more ended by the charger is worth knowing about.
    [ -n "$dm_off_ts" ] && [ $((_n - dm_off_ts)) -ge 600 ] && dm_rej charge $((_n - dm_off_ts))
    dm_prev_ts=""; dm_off_ts=""; dm_off_media_s=0; dm_glance_ts=""; dm_prev_scr="$_s"
    return 0
  fi
  if [ "$_s" = 1 ]; then
    if [ -n "$dm_off_ts" ]; then
      # The window ends where the screen came on, once it has stayed on past a glance.
      [ -n "$dm_glance_ts" ] || { dm_glance_ts="$_n"; dm_glance_pct="$_p"; }
      if [ $((_n - dm_glance_ts)) -ge "$DM_GLANCE_S" ]; then
        _dd=$((dm_glance_ts - dm_off_ts)); _dq=$((dm_off_pct - dm_glance_pct))
        if [ "$_dd" -ge 3600 ] && [ "$dm_off_media_s" -lt "$DM_MEDIA_REJECT_S" ] && [ "$_dq" -ge 0 ] && [ "$_dq" -le 50 ]; then
          dm_add_off "$_dd" "$_dq" "$dm_glance_ts"
        elif [ "$_dd" -ge 3600 ] && [ "$dm_off_media_s" -ge "$DM_MEDIA_REJECT_S" ]; then
          dm_rej media "$_dd"
        elif [ "$_dd" -ge 600 ] && [ "$_dd" -lt 3600 ]; then
          dm_rej short "$_dd"
        fi
        dm_off_ts=""; dm_off_media_s=0; dm_glance_ts=""
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
    if [ -z "$dm_off_ts" ]; then dm_off_ts="$_n"; dm_off_pct="$_p"; dm_off_media_s=0; fi
    # Only sustained playback invalidates an idle window. Two one-minute samples used to throw
    # away a whole five-hour night after a notification or an audio-thread blip. The first
    # screen-off sample is not timed: it can still contain activity from screen-on playback.
    if [ "$_m" = 1 ] && [ "$dm_prev_scr" = 0 ] && [ -n "$dm_prev_ts" ]; then
      _md=$((_n - dm_prev_ts))
      if [ "$_md" -gt 0 ]; then
        [ "$_md" -le 120 ] || _md=120
        dm_off_media_s=$((dm_off_media_s + _md))
      fi
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

dm_boot_load() {
  dm_b_id=""; [ -r "$DM_BOOTID" ] && read -r dm_b_id < "$DM_BOOTID" 2>/dev/null
  dm_b_id="$(printf '%s' "$dm_b_id" | tr -dc '0-9a-f' | cut -c1-12)"
  [ -n "$dm_b_id" ] || dm_b_id=0
  dm_b_on=0; dm_b_off=0; dm_b_ts=""; dm_b_scr=""
  [ -r "$DM_BOOT" ] || return 0
  read -r _bi _bon _boff < "$DM_BOOT" 2>/dev/null
  [ "$_bi" = "$dm_b_id" ] || return 0
  case "$_bon$_boff" in ''|*[!0-9]*) return 0 ;; esac
  dm_b_on="$_bon"; dm_b_off="$_boff"
}

dm_boot_step() {
  if [ -n "$dm_b_ts" ]; then
    _bd=$(( $1 - dm_b_ts ))
    if [ "$_bd" -gt 0 ]; then
      if [ "$dm_b_scr" = 1 ]; then
        if [ "$_bd" -le 120 ]; then
          dm_b_on=$((dm_b_on + _bd))
        else
          dm_b_on=$((dm_b_on + 30)); dm_b_off=$((dm_b_off + _bd - 30))
        fi
      else
        dm_b_off=$((dm_b_off + _bd))
      fi
    fi
  fi
  dm_b_ts="$1"; dm_b_scr="$2"
  printf '%s %s %s\n' "$dm_b_id" "$dm_b_on" "$dm_b_off" > "$DM_BOOT.tmp" 2>/dev/null \
    && mv -f "$DM_BOOT.tmp" "$DM_BOOT" 2>/dev/null
  return 0
}

dm_loop() {
  dm_load
  dm_boot_load
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
    dm_boot_step "$_ln" "$_ls"
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
