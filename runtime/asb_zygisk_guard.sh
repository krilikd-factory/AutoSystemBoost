#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_ZG_DIR:-/data/adb/asb}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
TMPD="${ASB_ZG_TMP:-/dev/.asb}"
ON="$D/zygisk_guard"
ACT="$D/zygisk_guard_active"
LOG="$D/zygisk_guard_log"
NIGHT="$D/zygisk_guard_night"
PREV="$TMPD/zygisk_guard.prev"
BASE="$TMPD/zygisk_guard.base"
SEEN="$TMPD/zygisk_guard.seen"
KEEP="${ASB_DOZE_KEEP:-$D/doze_whitelist_keep}"
NFL="$D/notif_fix"
MIN="${ASB_ZG_MIN_STARTS:-6}"
WMIN="${ASB_ZG_WAKER_STARTS:-8}"
NIGHT_MIN_S="${ASB_ZG_NIGHT_MIN_S:-900}"

_has() { command -v "$1" >/dev/null 2>&1; }
_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*) return 1 ;; esac
  return 0
}
_level() {
  [ -f "$ON" ] || { echo off; return 0; }
  _lv=""; read -r _lv < "$ON" 2>/dev/null
  case "$_lv" in wakers) echo wakers ;; *) echo loops ;; esac
}
_gov_live() {
  _gp=""; read -r _gp < "${ASB_ZG_GOVPID:-/dev/.asb/governor.pid}" 2>/dev/null
  case "$_gp" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_gp" 2>/dev/null
}
_screen_on() {
  _gov_live || return 0
  _so="$(grep -m1 '^screen=' "${ASB_ZG_STATE:-/dev/.asb/state}" 2>/dev/null | cut -d= -f2)"
  [ "$_so" != 0 ]
}
_ledger() {
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ { off[$2] += $3 } END { for (p in off) print p, off[p] }'
}
_protected() {
  case "$1" in
    *authenticator*|*.auth.*|*.otp.*|*twofactor*|*passkey*|*.mfa.*|\
    *bluetooth*|*wearable*|*.wear.*|*watch*|*fitbit*|*garmin*|*amazfit*|*zepp*|*huami*|*health*|\
    *truecaller*|*callerid*|*callblock*|*vpn*|*wireguard*|*.clock*|*alarm*|*maps*|*navi*|*waze*|\
    org.telegram.*|org.thunderdog.*|com.whatsapp*|org.thoughtcrime.securesms|im.vector.*|\
    com.viber.*|com.discord|com.Slack|com.microsoft.teams*|com.skype.*|jp.naver.line.*|\
    com.facebook.orca|com.instagram.android|com.kakao.talk|com.tencent.mm|com.wire|ch.threema.*|\
    com.google.android.gm|com.microsoft.office.outlook|*.mail*|*.email*|com.zoom.*|us.zoom.*)
      return 0 ;;
  esac
  grep -qxF "$1" "$KEEP" 2>/dev/null && return 0
  grep -q "^$1|" "$NFL" 2>/dev/null && return 0
  dumpsys deviceidle whitelist 2>/dev/null | grep -qE "^user,$1,"  && return 0
  return 1
}
_ops() { appops get "$1" 2>/dev/null; }
_pmode() {
  printf '%s\n' "$1" | grep -v 'Uid mode' | sed -n "s/^[[:space:]]*$2: \([a-z_]*\).*/\1/p" | head -1
}
_umode() {
  printf '%s\n' "$1" | sed -n "s/.*Uid mode: $2: \([a-z_]*\).*/\1/p" | head -1
}
_note() {
  mkdir -p "$D" 2>/dev/null
  { [ -f "$LOG" ] && tail -n 49 "$LOG"; printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" "$4"; } > "$LOG.tmp" 2>/dev/null \
    && mv -f "$LOG.tmp" "$LOG"
}
_note_once() {
  grep -qxF "$1|$3" "$SEEN" 2>/dev/null && return 0
  mkdir -p "$TMPD" 2>/dev/null
  echo "$1|$3" >> "$SEEN" 2>/dev/null
  _note "$1" "$2" "$3" ""
}
_limit() {
  _lp="$1"; _ln="$2"; _lw="${3:-loop}"; _lt="$4"
  grep -q "^$_lp|" "$ACT" 2>/dev/null && return 0
  _lo="$(_ops "$_lp")"
  _lm="$(_pmode "$_lo" RUN_ANY_IN_BACKGROUND)"; _lm="${_lm:-default}"
  _lu="$(_umode "$_lo" RUN_ANY_IN_BACKGROUND)"; _lu="${_lu:-default}"
  case "$_lm$_lu" in *ignore*|*deny*) _note_once "$_lp" "$_ln" already_restricted; return 0 ;; esac
  appops set "$_lp" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  if [ "$(_pmode "$(_ops "$_lp")" RUN_ANY_IN_BACKGROUND)" = ignore ]; then
    mkdir -p "$D" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$_lp" "$_lm" "$_lu" "$(date +%s)" "$_ln" "$_lw" "$_lt" >> "$ACT"
    _note "$_lp" "$_ln" limited "$_lw"
  else
    appops set "$_lp" RUN_ANY_IN_BACKGROUND "$_lm" >/dev/null 2>&1
    _note_once "$_lp" "$_ln" refused
  fi
}
_since_limit() {
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  _sc="$(printf '%s\n' "$3" | awk -v p="$1" '$1 == p { print $2; exit }')"
  case "$_sc" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_sc" -ge "$2" ]; then echo $(( _sc - $2 )); else echo "$_sc"; fi
}
_lift_all() {
  [ -s "$ACT" ] || { rm -f "$ACT" 2>/dev/null; return 0; }
  _lc="$(_ledger)"
  while IFS='|' read -r _fp _fm _fu _fs _fn _fw _ft; do
    _pkgok "$_fp" || continue
    appops set "$_fp" RUN_ANY_IN_BACKGROUND "${_fm:-default}" >/dev/null 2>&1
    [ "${ASB_ZG_QUIET:-0}" = 1 ] || _note "$_fp" "${_fn:-0}" "lifted_$1" "$(_since_limit "$_fp" "$_ft" "$_lc")"
  done < "$ACT"
  rm -f "$ACT" "$ACT.tmp" 2>/dev/null
}
_session_end() {
  if [ -s "$BASE" ] && [ -s "$PREV" ]; then
    _st="$(sed -n '1s/^t //p' "$BASE" 2>/dev/null)"; _et="$(sed -n '1s/^t //p' "$PREV" 2>/dev/null)"
    case "$_st$_et" in
      ''|*[!0-9]*) ;;
      *)
        if [ $(( _et - _st )) -ge "$NIGHT_MIN_S" ]; then
          _dl="$(awk -v bf="$BASE" '
            BEGIN { while ((getline l < bf) > 0) { n = split(l, f, " "); if (n == 2 && f[1] != "t") b[f[1]] = f[2] + 0 } }
            NR > 1 && NF == 2 { d = $2 - (($1 in b) ? b[$1] : 0); if (d > 0) print d, $1 }' "$PREV" 2>/dev/null | sort -k1,1nr)"
          _tot="$(printf '%s\n' "$_dl" | awk 'NF == 2 { s += $1 } END { print s + 0 }')"
          _top="$(printf '%s\n' "$_dl" | awk 'NF == 2 && NR <= 3 { printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')"
          _nr="$(grep -c '|' "$ACT" 2>/dev/null)"
          mkdir -p "$D" 2>/dev/null
          { [ -f "$NIGHT" ] && tail -n 6 "$NIGHT"; printf '%s|%s|%s|%s|%s\n' "$_st" "$_et" "$_tot" "${_nr:-0}" "${_top:--}"; } > "$NIGHT.tmp" 2>/dev/null \
            && mv -f "$NIGHT.tmp" "$NIGHT"
        fi
        ;;
    esac
  fi
  rm -f "$BASE" "$SEEN" 2>/dev/null
}
_tick() {
  [ -f "$ON" ] || return 0
  _has appops && _has pm && _has dumpsys || return 0
  if _screen_on; then _session_end; _lift_all screen_on; rm -f "$PREV" 2>/dev/null; return 0; fi
  _now="$(date +%s)"
  _cur="$(_ledger)"
  [ -n "$_cur" ] || return 0
  mkdir -p "$TMPD" 2>/dev/null
  [ -s "$BASE" ] || { echo "t $_now"; printf '%s\n' "$_cur"; } > "$BASE" 2>/dev/null
  _pt="$(sed -n '1s/^t //p' "$PREV" 2>/dev/null)"
  sed '1d' "$PREV" > "$PREV.old" 2>/dev/null || rm -f "$PREV.old" 2>/dev/null
  { echo "t $_now"; printf '%s\n' "$_cur"; } > "$PREV.tmp" 2>/dev/null && mv -f "$PREV.tmp" "$PREV"
  _dt=0
  case "$_pt" in ''|*[!0-9]*) ;; *) _dt=$(( _now - _pt )); { [ "$_dt" -gt 0 ] && [ "$_dt" -le 1800 ]; } || _dt=0 ;; esac
  _wk=0; [ "$(_level)" = wakers ] && _wk=1
  _cands="$(printf '%s\n' "$_cur" | awk -v pf="$PREV.old" -v bf="$BASE" -v dt="$_dt" -v min="$MIN" -v wmin="$WMIN" -v wk="$_wk" '
    BEGIN {
      while ((getline l < pf) > 0) { n = split(l, f, " "); if (n == 2) pv[f[1]] = f[2] + 0 }
      while ((getline l < bf) > 0) { n = split(l, f, " "); if (n == 2 && f[1] != "t") bs[f[1]] = f[2] + 0 }
    }
    NF == 2 {
      c = $2 + 0
      if (dt > 0 && ($1 in pv)) { d = c - pv[$1]; if (d >= min && int(d * 300 / dt) >= min) { print $1, d, "loop", c; next } }
      if (wk == 1) { d = c - (($1 in bs) ? bs[$1] : 0); if (d >= wmin) print $1, d, "waker", c }
    }')"
  rm -f "$PREV.old" 2>/dev/null
  [ -n "$_cands" ] || return 0
  _users="$(pm list packages -3 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.]*\).*/\1/p')"
  printf '%s\n' "$_cands" | while read -r _cp _cn _cw _ct; do
    _pkgok "$_cp" || continue
    printf '%s\n' "$_users" | grep -qxF "$_cp" || continue
    if _protected "$_cp"; then _note_once "$_cp" "$_cn" protected; continue; fi
    _limit "$_cp" "$_cn" "$_cw" "$_ct"
  done
}
_status() {
  echo 'version=1'
  [ -f "$ON" ] && echo 'enabled=1' || echo 'enabled=0'
  echo "level=$(_level)"
  _screen_on && echo 'screen=1' || echo 'screen=0'
  [ -n "$(cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L"' | head -1)" ] && echo 'ledger=1' || echo 'ledger=0'
  echo "threshold=$MIN"
  echo "waker_min=$WMIN"
  if [ -s "$ACT" ]; then
    _lc="$(_ledger)"
    while IFS='|' read -r _sp _sm _su _ss _sn _sw _st; do
      _pkgok "$_sp" || continue
      case "$_sw" in waker) ;; *) _sw=loop ;; esac
      printf 'active|%s|%s|%s|%s|%s\n' "$_sp" "${_ss:-0}" "${_sn:-0}" "$_sw" "$(_since_limit "$_sp" "$_st" "$_lc")"
    done < "$ACT"
  fi
  [ -s "$LOG" ] && tail -n 12 "$LOG" | while IFS='|' read -r _le _lp _ln _la _lx; do
    _pkgok "$_lp" && printf 'event|%s|%s|%s|%s|%s\n' "$_le" "$_lp" "$_ln" "$_la" "$_lx"
  done
  [ -s "$NIGHT" ] && while IFS='|' read -r _ns _ne _nt _nr _np; do
    case "$_ns$_ne$_nt$_nr" in ''|*[!0-9]*) continue ;; esac
    case "$_np" in *[!A-Za-z0-9_.:,-]*) _np=- ;; esac
    printf 'night|%s|%s|%s|%s|%s\n' "$_ns" "$_ne" "$_nt" "$_nr" "${_np:--}"
  done < "$NIGHT"
  return 0
}

case "${1:-status}" in
  status) _status ;;
  enable)
    case "${2:-loops}" in loops|wakers) ;; *) echo 'result=bad_request'; exit 2 ;; esac
    mkdir -p "$D" 2>/dev/null; printf '%s\n' "${2:-loops}" > "$ON" && echo 'result=enabled' ;;
  disable) rm -f "$ON" "$PREV" "$BASE" "$SEEN" 2>/dev/null; _lift_all disabled; echo 'result=disabled' ;;
  tick) _tick ;;
  screen_on) _session_end; [ -s "$ACT" ] && _lift_all screen_on; rm -f "$PREV" 2>/dev/null ;;
  restore-all) ASB_ZG_QUIET=1 _lift_all uninstall; rm -f "$ON" "$PREV" "$BASE" "$SEEN" "$LOG" "$NIGHT" 2>/dev/null ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
