#!/system/bin/sh
# asb_lsposed.sh status | apply | open - LSPosed's verbose log, switched only on request (fix187).
#
# ASB used to report LSPosed's logging and touch nothing: it is another module, and writing
# into another module's settings unasked makes ASB the second writer this project spent weeks
# untangling on the CPU caps. A user asked for the switch (31 MB of verbose logs on an OP15),
# so it exists now - as a card that is off by default, applied once when the user changes it
# and never again behind their back:
#
#   lsposed_verbose=keep   ASB leaves LSPosed alone. If ASB had switched the log off, the value
#                          LSPosed had before is put back (on, off, or its own default).
#   lsposed_verbose=off    LSPosed's own setting is written to off (the same row its manager's
#                          Settings > Verbose log writes) and the old verbose_*.log files are
#                          deleted - the newest stays, the daemon still holds it open. LSPosed
#                          reads the setting when it starts: it takes effect at the next boot.
#
# Nothing runs at boot. If the user later turns the log back on in the LSPosed manager, that
# is their choice and ASB does not undo it. Uninstalling ASB puts LSPosed's value back.
#
#   status  prints key=value lines for the WebUI and asbdiag (pending_reboot=1: ASB wrote
#           the setting after this boot began, so the daemon still runs with the old one)
#   apply   carries out the card's value, prints result=...
#   restore puts LSPosed's earlier value back (uninstall.sh)
#   open    opens the LSPosed manager (the parasitic one in Shell, else the standalone app)

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_CONF:-$MODDIR/config/governor.conf}"
LSPD="${ASB_LSPD_DIR:-/data/adb/lspd}"
DB="${ASB_LSPD_DB:-$LSPD/config/modules_config.db}"
PREV="${ASB_LSPD_PREV:-/data/adb/asb/lsposed_verbose_prev}"
# When ASB last wrote LSPosed's setting (epoch seconds). A write newer than this boot has not
# reached the daemon yet - the card says "after a reboot" instead of "off".
MARK="${PREV}_at"
GOV="${ASB_GOV_BIN:-$MODDIR/bin/asb}"

_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \r'; }
_kib() {   # total size of the files given, KiB
  _t=0
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _s=$(wc -c < "$_f" 2>/dev/null)
    case "$_s" in ''|*[!0-9]*) continue ;; esac
    _t=$((_t + _s))
  done
  echo $((_t / 1024))
}
_lspd() { "$GOV" --lspd "$@" "$DB" 2>/dev/null; }
_mark() { mkdir -p "${MARK%/*}" 2>/dev/null; date +%s > "$MARK" 2>/dev/null; }
_pending() {   # 1 when ASB's last write came after this boot started
  _at=$(cat "$MARK" 2>/dev/null); _now=$(date +%s 2>/dev/null); _up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  case "$_at$_now$_up" in ''|*[!0-9]*) echo 0; return ;; esac
  [ "$_at" -ge $((_now - _up)) ] && echo 1 || echo 0
}
_get() { _lspd verbose-get | sed -n 's/^verbose=//p' | head -1; }
_reason() { _lspd verbose-get | sed -n 's/^reason=//p' | head -1; }

present=0
[ -d "$LSPD" ] && [ -f "$DB" ] && present=1

_restore() {   # LSPosed's own earlier value back, if ASB ever changed it
  # "off" before ASB's change means ASB changed nothing (a fix187 record): nothing to restore.
  [ "$(cat "$PREV" 2>/dev/null)" = off ] && rm -f "$PREV"
  if [ -f "$PREV" ] && [ "$present" = 1 ]; then
    _p="$(cat "$PREV" 2>/dev/null)"
    case "$_p" in
      on)         _lspd verbose-set on >/dev/null && _mark ;;
      default_on) _lspd verbose-unset >/dev/null && _mark ;;
    esac
    rm -f "$PREV"
    echo "result=restored prev=$_p"
  else
    rm -f "$PREV" 2>/dev/null
    echo "result=untouched"
  fi
}

case "${1:-status}" in
  status)
    echo "present=$present"
    echo "setting=$(_cfg lsposed_verbose)"
    if [ "$present" = 1 ]; then
      _v="$(_get)"; echo "verbose=${_v:-unknown}"
      [ "${_v:-unknown}" = unknown ] && echo "reason=$(_reason)"
      echo "log_kib=$(_kib "$LSPD"/log/*.log "$LSPD"/log/*/*.log)"
      echo "verbose_kib=$(_kib "$LSPD"/log/verbose_*.log)"
      echo "pending_reboot=$(_pending)"
    fi
    [ -f "$PREV" ] && [ "$(cat "$PREV" 2>/dev/null)" != off ] && echo "asb_changed=1 prev=$(cat "$PREV" 2>/dev/null)"
    ;;
  apply)
    _want="$(_cfg lsposed_verbose)"
    case "$_want" in
      off)
        [ "$present" = 1 ] || { echo "result=absent"; exit 0; }
        _cur="$(_get)"
        case "$_cur" in on|off|default_on) : ;; *) echo "result=unsupported reason=$(_reason)"; exit 0 ;; esac
        if [ "$_cur" != off ]; then
          # Remember what LSPosed had before ASB's first change, so "keep" can put it back.
          [ -f "$PREV" ] || { mkdir -p "${PREV%/*}" 2>/dev/null; echo "$_cur" > "$PREV"; }
          [ "$(_lspd verbose-set off | sed -n 's/^verbose=//p' | head -1)" = off ] || { echo "result=write_failed"; exit 0; }
          _mark
          _res=off_after_reboot
        else
          # Already off and ASB wrote nothing: there is nothing to put back. fix187 recorded
          # "off" here anyway, and asbdiag then said ASB had switched the log off (an OP15
          # whose user had turned it off in the manager beforehand) - that record goes.
          [ "$(cat "$PREV" 2>/dev/null)" = off ] && rm -f "$PREV"
          _res=already_off
        fi
        # The old verbose logs: every one but the newest, which the daemon still writes to.
        _freed=0; _n=0
        for _f in $(ls -t "$LSPD"/log/verbose_*.log 2>/dev/null); do
          _n=$((_n + 1))
          [ "$_n" -eq 1 ] && continue
          _k=$(_kib "$_f"); rm -f "$_f" 2>/dev/null && _freed=$((_freed + _k))
        done
        echo "result=$_res freed_kib=$_freed"
        ;;
      *) _restore ;;
    esac
    ;;
  restore)
    # Uninstall: put back what LSPosed had, whatever the card says - ASB is leaving, and a
    # setting it changed in another module must not outlive it.
    _restore
    ;;
  open)
    # The parasitic manager lives in Shell and starts on this category (LSPosed's own
    # notification uses it); the standalone manager app is the fallback.
    if am start -a android.intent.action.MAIN -c org.lsposed.manager.LAUNCH_MANAGER \
         -n com.android.shell/.BugreportWarningActivity >/dev/null 2>&1; then
      echo "result=opened"
    elif monkey -p org.lsposed.manager -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
      echo "result=opened"
    else
      echo "result=open_failed"
    fi
    ;;
  *) echo "usage: asb_lsposed.sh status|apply|restore|open" >&2; exit 2 ;;
esac
exit 0
