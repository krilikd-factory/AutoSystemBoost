#!/system/bin/sh
# asb_ltpo_video.sh - the lowest judder-free refresh rate while a video plays (ltpo_video=1).
#
# WHY
#
# A field capture of YouTube on the OnePlus 15: the video's SurfaceView asks for
# "30 Hz ExactOrMultiple", the OEM caps the render range at 0-90, and SurfaceFlinger picks
# 90 Hz - three panel refreshes per video frame where two are enough. Nothing is wrong with
# that choice for smoothness; it is just more refreshes than the content can use, for as
# long as the video runs. 60 Hz shows the same 30 fps with the same even cadence.
#
# The panel has no "video" mode to ask for, and Android exposes no per-app lever a module
# could use safely. What it does expose is the user's own ceiling, peak_refresh_rate. So
# this lowers that ceiling to the smallest panel mode that is an exact multiple of the
# video, and only while nothing else could notice.
#
# WHAT "NOTHING ELSE COULD NOTICE" MEANS HERE - every one of these must hold:
#   - the screen is on and audio is actually playing (kernel PCM state, no dumpsys),
#   - a layer asks for an explicit 30 or 60 fps with Exact/ExactOrMultiple compatibility,
#     which is what video players do and UI does not,
#   - no layer at all asks for a High frame-rate category (an animation, a touch hint),
#   - the governor is not in its GAMING state,
#   - the touchscreen has been quiet for 3 s.
# 24, 25 and 50 fps have no judder-free mode at or below 60, so they are left alone: a
# lower rate with uneven cadence is a worse picture, not a saving.
#
# AND IT LETS GO AT ONCE: the first touch (a background getevent writes the old value back
# the moment the screen is touched), the end of playback, the video layer going away, a
# high-category request, the screen turning off, or the switch going off. If the value is
# changed by anyone else while lowered - the user in Settings, the OEM - that value is
# theirs and is left alone.
#
# The record is written BEFORE the setting, so a crash or a reboot mid-video is repaired
# by the next reconcile (boot runs one) rather than leaving the phone at 60 Hz.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
CONF="$MODDIR/config/governor.conf"
STATE_DIR="${ASB_LTPO_STATE_DIR:-/data/adb/asb}"
RSTATE="${ASB_LTPO_RSTATE:-/dev/.asb/state}"
ASOUND="${ASB_LTPO_ASOUND:-/proc/asound}"
BL_ROOT="${ASB_LTPO_BACKLIGHT:-/sys/class/backlight}"
PIDF="$STATE_DIR/ltpo_video.pid"
GUARD="$STATE_DIR/ltpo_video.guard"
LOWERED="$STATE_DIR/ltpo_video.lowered"
STAT="$STATE_DIR/ltpo_video.stats"
LOG="$STATE_DIR/ltpo_video.log"
TOUCHDEV="$STATE_DIR/ltpo_video.touchdev"
QUIET_S="${ASB_LTPO_QUIET_S:-3}"

_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'; }
_has() { command -v "$1" >/dev/null 2>&1; }
_now() { date +%s 2>/dev/null || echo 0; }
_enabled() { [ "$(_cfg ltpo_video)" = 1 ]; }
_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s ltpo_video: %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null
  tail -n 40 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
}
_get() { if _has asb_set_get; then asb_set_get system peak_refresh_rate; else settings get system peak_refresh_rate 2>/dev/null | sed 's/^null$//'; fi; }
_put() { if _has asb_set_put; then asb_set_put system peak_refresh_rate "$1"; else settings put system peak_refresh_rate "$1" >/dev/null 2>&1; fi; }
_del() { if _has asb_set_del; then asb_set_del system peak_refresh_rate; else settings delete system peak_refresh_rate >/dev/null 2>&1; fi; }
_int() { printf '%s' "$1" | awk '{ printf "%d", $1 + 0.5 }'; }

# Counters for the diag/WebUI: lowers, touch restores, seconds spent lowered.
_stat_bump() {   # $1=field $2=add
  _l=0; _t=0; _s=0
  [ -f "$STAT" ] && IFS='|' read -r _l _t _s < "$STAT" 2>/dev/null
  case "$1" in
    lowers) _l=$(( ${_l:-0} + $2 )) ;;
    touch)  _t=$(( ${_t:-0} + $2 )) ;;
    secs)   _s=$(( ${_s:-0} + $2 )) ;;
  esac
  printf '%s|%s|%s\n' "${_l:-0}" "${_t:-0}" "${_s:-0}" > "$STAT" 2>/dev/null
}

# --- signals -------------------------------------------------------------------------

_screen_on() {
  _seen=0
  for _b in "$BL_ROOT"/*/brightness; do
    [ -r "$_b" ] || continue
    _seen=1
    [ "$(cat "$_b" 2>/dev/null)" -gt 0 ] 2>/dev/null && return 0
  done
  [ "$_seen" = 1 ] && return 1
  [ "$(sed -n 's/^screen=//p' "$RSTATE" 2>/dev/null | head -1)" = 1 ]
}

# Kernel PCM state: a file read, no binder call. dumpsys audio only where this kernel
# exposes no PCM status files at all.
_audio_live() {
  _any=0
  for _f in "$ASOUND"/card*/pcm*p/sub*/status; do
    [ -r "$_f" ] || continue
    _any=1
    grep -q RUNNING "$_f" 2>/dev/null && return 0
  done
  [ "$_any" = 1 ] && return 1
  dumpsys audio 2>/dev/null | grep -qE 'AudioPlaybackConfiguration .*state:started'
}

_gaming() { [ "$(sed -n 's/^state=//p' "$RSTATE" 2>/dev/null | head -1)" = GAMING ]; }

# Physical modes of the panel, integer Hz, ascending.
_modes() {
  if [ -n "${ASB_LTPO_DISPLAY_DUMP:-}" ]; then cat "$ASB_LTPO_DISPLAY_DUMP" 2>/dev/null
  else dumpsys display 2>/dev/null; fi \
    | sed -n 's/.*DisplayMode{id=[0-9]*,.*peakRefreshRate=\([0-9.]*\).*/\1/p' \
    | awk '{ v = int($1 + 0.5); if (v >= 1 && !(v in s)) { s[v] = 1; print v } }' | sort -n
}

# Explicit video rates requested right now, one per line, or HIGH when any layer asks
# for a high frame-rate category - which vetoes everything.
_video_rates() {
  if [ -n "${ASB_LTPO_SF_DUMP:-}" ]; then cat "$ASB_LTPO_SF_DUMP" 2>/dev/null
  else dumpsys SurfaceFlinger 2>/dev/null; fi | awk '
    /requestedFrameRate: \{/ {
      s = $0; sub(/.*requestedFrameRate: \{/, "", s); sub(/\}.*/, "", s)
      n = split(s, a, " ")
      r = a[1] + 0; c = ""; g = ""
      for (i = 2; i <= n; i++) {
        if (a[i] ~ /^FrameRateCompatibility::/) c = a[i]
        if (a[i] ~ /^FrameRateCategory::/) g = a[i]
      }
      if (g ~ /::High/) high = 1
      if (r > 0 && (c ~ /::ExactOrMultiple$/ || c ~ /::Exact$/)) rates[int(r + 0.5)] = 1
    }
    END { if (high) { print "HIGH"; exit } for (r in rates) print r }'
}

# Smallest mode that every requested rate divides evenly, if it is 60 Hz or lower.
_pick() {   # $1 = rates (newline list), modes on stdin
  awk -v R="$1" 'BEGIN { n = split(R, r, "\n") }
    { m = $1 + 0; ok = (n > 0)
      for (i = 1; i <= n; i++) { v = r[i] + 0; if (v <= 0 || m % v) { ok = 0; break } }
      if (ok && m <= 60) { print m; exit } }'
}

# --- touch ---------------------------------------------------------------------------

_touch_dev() {
  if [ -s "$TOUCHDEV" ]; then
    _td="$(cat "$TOUCHDEV" 2>/dev/null)"
    [ -c "$_td" ] && { printf '%s' "$_td"; return 0; }
  fi
  _td="$(getevent -pl 2>/dev/null | awk '/^add device/ { d = $4 } /ABS_MT_POSITION_X/ && d { print d; exit }')"
  [ -n "$_td" ] || return 1
  printf '%s\n' "$_td" > "$TOUCHDEV" 2>/dev/null
  printf '%s' "$_td"
}

# 0 = quiet for QUIET_S, 1 = touched, 2 = cannot tell (then nothing is lowered).
_quiet() {
  _has timeout || return 2
  _t0="$(_now)"
  timeout "$QUIET_S" getevent -qc 1 "$1" >/dev/null 2>&1
  _rc=$?
  [ "$_rc" = 0 ] && return 1
  # timeout's own "timed out" status, and only after the time actually passed: a getevent
  # that could not open the device fails at once, and that must not read as "quiet".
  if [ "$_rc" = 124 ] || [ "$_rc" = 143 ]; then
    [ $(( $(_now) - _t0 )) -ge $(( QUIET_S - 1 )) ] && return 0
  fi
  return 2
}

_guard_stop() {
  _gp="$(cat "$GUARD" 2>/dev/null | tr -dc '0-9')"
  [ -n "$_gp" ] && kill "$_gp" 2>/dev/null
  rm -f "$GUARD" 2>/dev/null
}

# --- lower / restore -----------------------------------------------------------------

_lower() {   # $1 = mode Hz, $2 = content rate(s)
  _orig="$(_get)"
  [ -n "$_orig" ] || _orig=__unset
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf 'orig=%s\nset=%s.0\ncontent=%s\nsince=%s\n' "$_orig" "$1" "$(printf '%s' "$2" | tr '\n' ',' | sed 's/,$//')" "$(_now)" \
    > "$LOWERED" 2>/dev/null || return 1
  if ! _put "$1.0"; then
    rm -f "$LOWERED" 2>/dev/null
    _log "could not lower to $1 Hz (Settings refused) - nothing changed"
    return 1
  fi
  _stat_bump lowers 1
  _log "lowered peak ${_orig} -> $1 Hz for ${2} fps video"
  # The first touch puts the old value back straight from here - no polling interval in
  # between - and only then tells the loop. Fastest path: one settings put, no reads.
  (
    exec </dev/null >/dev/null 2>&1   # detach here, not with a redirect on the ( ): mksh then waits for a body that uses $(...)
    getevent -qc 1 "$_dev" >/dev/null 2>&1 &
    _g=$!
    printf '%s\n' "$_g" > "$GUARD" 2>/dev/null
    wait "$_g"
    [ -f "$LOWERED" ] || exit 0
    _o="$(sed -n 's/^orig=//p' "$LOWERED" 2>/dev/null | head -1)"
    case "$_o" in
      __unset) command settings delete system peak_refresh_rate >/dev/null 2>&1 ;;
      ?*) command settings put system peak_refresh_rate "$_o" >/dev/null 2>&1 ;;
    esac
    # Verify the fast write; fall back to the wrapper where the cmd bridge is broken.
    [ "$_o" = __unset ] || [ "$(_get)" = "$_o" ] || _put "$_o"
    _since="$(sed -n 's/^since=//p' "$LOWERED" 2>/dev/null | head -1)"
    rm -f "$LOWERED" "$GUARD" 2>/dev/null
    _stat_bump touch 1
    [ -n "$_since" ] && _stat_bump secs $(( $(_now) - _since ))
  ) &
  return 0
}

_restore() {   # $1 = reason
  [ -f "$LOWERED" ] || { _guard_stop; return 0; }
  _o="$(sed -n 's/^orig=//p' "$LOWERED" 2>/dev/null | head -1)"
  _s="$(sed -n 's/^set=//p' "$LOWERED" 2>/dev/null | head -1)"
  _since="$(sed -n 's/^since=//p' "$LOWERED" 2>/dev/null | head -1)"
  _guard_stop
  _cur="$(_get)"
  if [ -n "$_s" ] && [ -n "$_cur" ] && [ "$(_int "$_cur")" != "$(_int "$_s")" ]; then
    # Someone else set a new value while we held it low. It is theirs now.
    _log "peak changed to $_cur by someone else while lowered - left as it is ($1)"
  else
    case "$_o" in
      __unset|'') _del ;;
      *) _put "$_o" || { _log "restore to $_o failed ($1) - record kept for a retry"; return 1; } ;;
    esac
    _log "restored peak $_o ($1)"
  fi
  rm -f "$LOWERED" 2>/dev/null
  [ -n "$_since" ] && _stat_bump secs $(( $(_now) - _since ))
  return 0
}

# --- loop ----------------------------------------------------------------------------

_watch() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$$" > "$PIDF" 2>/dev/null
  trap '_restore stopped; rm -f "$PIDF" 2>/dev/null; exit 0' HUP INT TERM
  _dev="$(_touch_dev)"
  if [ -z "$_dev" ]; then
    _log "no touchscreen found through getevent - not acting (a lowered rate needs a touch to undo it)"
    rm -f "$PIDF" 2>/dev/null
    return 0
  fi
  _sf_ts=0; _sf_pick=""; _sf_rates=""; _nov=10; _err_logged=0; _lt=0
  while _enabled; do
    _tnow="$(_now)"
    if [ -f "$LOWERED" ]; then
      if ! _screen_on; then _restore screen_off
      elif ! _audio_live; then _restore playback_stopped
      elif _gaming; then _restore gaming
      elif [ $(( _tnow - _lt )) -ge 15 ]; then
        _lt="$_tnow"
        _r="$(_video_rates)"
        _m="$(_modes | _pick "$_r")"
        _s="$(sed -n 's/^set=//p' "$LOWERED" 2>/dev/null | head -1)"
        if [ "$_r" = HIGH ] || [ -z "$_m" ]; then _restore video_gone
        elif [ "$(_int "$_m")" != "$(_int "$_s")" ]; then _restore content_changed
        else
          _cur="$(_get)"
          if [ -n "$_cur" ] && [ "$(_int "$_cur")" != "$(_int "$_s")" ]; then
            _log "peak changed to $_cur by someone else while lowered - left as it is"
            _since="$(sed -n 's/^since=//p' "$LOWERED" 2>/dev/null | head -1)"
            _guard_stop; rm -f "$LOWERED" 2>/dev/null
            [ -n "$_since" ] && _stat_bump secs $(( _tnow - _since ))
            # Do not take it straight back: wait for this playback to end first.
            while _enabled && _audio_live && _screen_on; do sleep 10; done
          fi
        fi
      fi
      sleep 2
      continue
    fi
    _screen_on || { sleep 10; continue; }
    _audio_live || { _sf_ts=0; _nov=10; sleep 5; continue; }
    _gaming && { sleep 10; continue; }
    # Nothing to gain when the ceiling is already at or below the lowest rate this ever
    # picks - checked before the expensive dump, not after it.
    _cur="$(_get)"
    _ci="$(_int "${_cur:-0}")"
    # Unset peak means "the system default", which on these panels is the maximum.
    [ -z "$_cur" ] && _ci=999
    [ "$_ci" -gt 60 ] 2>/dev/null || { sleep 30; continue; }
    # The SurfaceFlinger dump is the one expensive read here. Cache its verdict so a
    # touch-and-wait cycle during playback does not re-dump on every touch.
    if [ $(( _tnow - _sf_ts )) -ge "$_nov" ]; then
      _sf_ts="$_tnow"
      _sf_rates="$(_video_rates)"
      if [ "$_sf_rates" = HIGH ]; then _sf_pick=""; else _sf_pick="$(_modes | _pick "$_sf_rates")"; fi
      # No video under this audio (music, a call): look less often while it lasts.
      if [ -z "$_sf_pick" ]; then _nov=30; else _nov=10; fi
    fi
    [ -n "$_sf_pick" ] || { sleep 5; continue; }
    [ "$_ci" -gt "$_sf_pick" ] 2>/dev/null || { sleep 10; continue; }
    _quiet "$_dev"
    case $? in
      0) _lower "$_sf_pick" "$_sf_rates" ;;
      1) sleep 1 ;;
      *) [ "$_err_logged" = 1 ] || _log "cannot watch the touchscreen (timeout/getevent) - not lowering"
         _err_logged=1; sleep 30 ;;
    esac
  done
  _restore switched_off
  rm -f "$PIDF" 2>/dev/null
}

_alive() {
  _p="$(cat "$PIDF" 2>/dev/null | tr -dc '0-9')"
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q 'asb_ltpo_video.sh watch'
}

_stop() {
  if _alive; then
    _p="$(cat "$PIDF" 2>/dev/null | tr -dc '0-9')"
    kill "$_p" 2>/dev/null
    sleep 1
  fi
  _restore stopped
  rm -f "$PIDF" 2>/dev/null
}

case "${1:-reconcile}" in
  reconcile)
    if ! _alive; then
      # A record with no live watcher is a crash or a reboot mid-video: repair it first.
      if [ -f "$LOWERED" ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; then
        _restore recovered
      fi
      rm -f "$PIDF" 2>/dev/null
      if _enabled; then
        ( MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_ltpo_video.sh" watch </dev/null >/dev/null 2>&1 & )
      fi
    elif ! _enabled; then
      _stop
    fi
    ;;
  watch) _alive && exit 0; _watch ;;
  stop) _stop ;;
  status)
    _l=0; _t=0; _s=0
    [ -f "$STAT" ] && IFS='|' read -r _l _t _s < "$STAT" 2>/dev/null
    if ! _enabled; then _st=off
    elif [ -f "$LOWERED" ]; then _st="lowered:$(sed -n 's/^set=//p' "$LOWERED" | head -1)"
    elif _alive; then _st=watching
    else _st=not_running; fi
    printf 'state=%s lowers=%s touch_restores=%s lowered_s=%s touch_dev=%s\n' \
      "$_st" "${_l:-0}" "${_t:-0}" "${_s:-0}" "$(cat "$TOUCHDEV" 2>/dev/null || echo -)"
    ;;
  # Host fixtures: the pure decision, without touching anything.
  decide)
    _r="$(_video_rates)"
    if [ "$_r" = HIGH ]; then echo veto_high; exit 0; fi
    _m="$(_modes | _pick "$_r")"
    echo "${_m:-none}"
    ;;
  *) echo 'usage: asb_ltpo_video.sh reconcile|watch|stop|status' >&2; exit 2 ;;
esac
exit 0
