#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_CONFIG_STATE:-/data/adb/asb}"
CONF="$MODDIR/config/governor.conf"
DEX="$MODDIR/bin/asb_btcodec.dex"
PIDF="$STATE_DIR/bt_ldac.pid"
STF="$STATE_DIR/bt_ldac.state"
LOG="$STATE_DIR/bt_ldac.log"
OUT="$STATE_DIR/bt_ldac.out"

_has() { command -v "$1" >/dev/null 2>&1; }
_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'; }
_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s bt_ldac: %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null
  tail -n 30 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
}
_want() {
  case "$(_cfg bt_ldac_quality)" in
    990) echo 990 ;;
    660) echo 660 ;;
    330) echo 330 ;;
    abr) echo abr ;;
    *) echo auto ;;
  esac
}
_rate() {
  case "$(_cfg bt_ldac_rate)" in
    44|48|88|96|192) _cfg bt_ldac_rate ;;
    *) echo auto ;;
  esac
}
_ap() {
  if [ -x /system/bin/app_process64 ]; then echo /system/bin/app_process64
  elif [ -x /system/bin/app_process ]; then echo /system/bin/app_process
  else echo ""
  fi
}
_alive() {
  [ -s "$PIDF" ] || return 1
  _p=""; _q=""
  _r=""
  IFS='|' read -r _p _q _r _born < "$PIDF" 2>/dev/null || return 1
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$_born" ] || [ "$(_starttime "$_p")" = "$_born" ] || return 1
  [ -r "/proc/$_p/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -qE 'asb_btcodec|asb\.BtCodec' || return 1
  return 0
}
_starttime() {
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}
_stop() {
  if _alive; then
    _target="$_p"; _start="$(_starttime "$_target")"
    if [ -n "$_start" ] && _alive && [ "$_p" = "$_target" ] && kill "$_target" 2>/dev/null; then
      sleep 1
      if _alive && [ "$_p" = "$_target" ] && [ "$(_starttime "$_target")" = "$_start" ]; then
        kill -9 "$_target" 2>/dev/null
      fi
    fi
  fi
  rm -f "$PIDF" 2>/dev/null
}
_ready() {
  [ -f "$DEX" ] || { echo "result=unavailable"; echo "reason=no_helper"; return 1; }
  [ -n "$(_ap)" ] || { echo "result=unavailable"; echo "reason=no_app_process"; return 1; }
  chmod 0444 "$DEX" 2>/dev/null
  return 0
}
_run() {
  CLASSPATH="$DEX" "$(_ap)" /system/bin asb.BtCodec "$@"
}

case "${1:-status}" in
  apply|stop)
    mkdir -p "$STATE_DIR" || exit 1
    exec 9>>"$STATE_DIR/bt_ldac.lock" || exit 1
    flock -x 9 9>&9 || exit 1 ;;
esac

case "${1:-status}" in
  apply)
    _w="$(_want)"
    _wr="$(_rate)"
    if [ "$_w" = auto ] && [ "$_wr" = auto ]; then
      _stop
      rm -f "$STF" 2>/dev/null
      echo "result=stock"
      exit 0
    fi
    _ready || exit 1
    if _alive && [ "$_q" = "$_w" ] && [ "${_r:-auto}" = "$_wr" ]; then echo "result=running"; echo "quality=$_w"; echo "rate=$_wr"; exit 0; fi
    _stop
    mkdir -p "$STATE_DIR" 2>/dev/null
    rm -f "$STF" 2>/dev/null
    _ap_bin="$(_ap)"
    if _has setsid; then
      CLASSPATH="$DEX" setsid "$_ap_bin" /system/bin --nice-name=asb_btcodec asb.BtCodec watch "$_w" "$STF" "$_wr" 9>&- </dev/null >"$OUT" 2>&1 &
    else
      CLASSPATH="$DEX" nohup "$_ap_bin" /system/bin --nice-name=asb_btcodec asb.BtCodec watch "$_w" "$STF" "$_wr" 9>&- </dev/null >"$OUT" 2>&1 &
    fi
    _np=$!
    printf '%s|%s|%s|%s\n' "$_np" "$_w" "$_wr" "$(_starttime "$_np")" > "$PIDF.tmp" && mv -f "$PIDF.tmp" "$PIDF" || exit 1
    _log "watch started quality=$_w rate=$_wr pid=$_np"
    echo "result=started"
    echo "quality=$_w"
    echo "rate=$_wr"
    ;;
  once)
    _w="$(_want)"
    _wr="$(_rate)"
    [ "$_w" = auto ] && [ "$_wr" = auto ] && { echo "result=stock"; exit 0; }
    _ready || exit 1
    _run apply "$_w" - "$_wr"
    ;;
  stop)
    _stop
    rm -f "$STF" "$OUT" 2>/dev/null
    echo "result=stopped"
    ;;
  status)
    echo "version=1"
    echo "want=$(_want)"
    echo "want_rate=$(_rate)"
    if [ -f "$DEX" ]; then echo "helper=1"; else echo "helper=0"; fi
    if _alive; then echo "watch=1"; else echo "watch=0"; fi
    [ -s "$STF" ] && sed 's/^/live_/' "$STF" 2>/dev/null
    [ -s "$OUT" ] && tail -n 3 "$OUT" 2>/dev/null | sed 's/^/out_/'
    [ -s "$LOG" ] && tail -n 3 "$LOG" 2>/dev/null | sed 's/^/log_/'
    if [ "${2:-}" = probe ] && _ready >/dev/null 2>&1; then
      _run status 2>/dev/null | sed 's/^/probe_/'
    fi
    ;;
  *)
    echo "usage: asb_bt_codec.sh apply|once|stop|status [probe]" >&2
    exit 2
    ;;
esac
