#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
D="${ASB_ZG_DIR:-/data/adb/asb}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
TMPD="${ASB_ZG_TMP:-/dev/.asb}"
ON="$D/zygisk_guard"
ACT="$D/zygisk_guard_active"
LOG="$D/zygisk_guard_log"
NIGHT="$D/zygisk_guard_night"
HIST="$D/zygisk_guard_hist"
GHOST="$D/zygisk_guard_ghost"
GHC="$D/zygisk_guard_ghost_cand"
PREV="$TMPD/zygisk_guard.prev"
PREVON="$TMPD/zygisk_guard.prev_on"
BASE="$TMPD/zygisk_guard.base"
SEEN="$TMPD/zygisk_guard.seen"
PEND="$TMPD/zygisk_guard.pending"
ONSESS="$TMPD/zygisk_guard.session_on"
APPROVED="$D/zygisk_guard_approved"
KEEP="${ASB_DOZE_KEEP:-$D/doze_whitelist_keep}"
NFL="$D/notif_fix"
LSPMOD="$D/zygisk_lsposed_modules"
BOOTID="${ASB_ZG_BOOTID:-/proc/sys/kernel/random/boot_id}"
MIN="${ASB_ZG_MIN_STARTS:-6}"
WMIN="${ASB_ZG_WAKER_STARTS:-8}"
NIGHT_MIN_S="${ASB_ZG_NIGHT_MIN_S:-900}"
HOLD_S="${ASB_ZG_ON_HOLD_S:-1800}"
GDAYS="${ASB_ZG_GHOST_DAYS:-3}"
GMIN="${ASB_ZG_GHOST_MIN:-30}"
GEVERY="${ASB_ZG_GHOST_EVERY_S:-3600}"
MINSESS="${ASB_ZG_MIN_SESSIONS:-2}"
case "$MINSESS" in ''|*[!0-9]*) MINSESS=2 ;; esac
[ "$MINSESS" -ge 2 ] 2>/dev/null || MINSESS=2

_has() { command -v "$1" >/dev/null 2>&1; }
_now() { date +%s 2>/dev/null || echo 0; }
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
_ledger_cols() {
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ { o[$2] += $3; n[$2] += $4; t[$2] += $5 }
    END { for (p in o) print p, o[p], n[p], t[p] }'
}
_ledger() { _ledger_cols | awk '{ print $1, $2 }'; }
_ledger_bg_on() { _ledger_cols | awk '{ b = $3 - $4; if (b < 0) b = 0; print $1, b }'; }
_users() { pm list packages -3 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.]*\).*/\1/p'; }
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
  grep -qxF "$1" "$LSPMOD" 2>/dev/null && return 0
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
  { [ -f "$LOG" ] && tail -n 49 "$LOG"; printf '%s|%s|%s|%s|%s\n' "$(_now)" "$1" "$2" "$3" "$4"; } > "$LOG.tmp" 2>/dev/null \
    && mv -f "$LOG.tmp" "$LOG"
}
_note_once() {
  grep -qxF "$1|$3" "$SEEN" 2>/dev/null && return 0
  mkdir -p "$TMPD" 2>/dev/null
  echo "$1|$3" >> "$SEEN" 2>/dev/null
  _note "$1" "$2" "$3" ""
}
_restricted_now() {
  _ro="$(_ops "$1")"
  case "$(_pmode "$_ro" RUN_ANY_IN_BACKGROUND)$(_umode "$_ro" RUN_ANY_IN_BACKGROUND)" in *ignore*|*deny*) return 0 ;; esac
  return 1
}
_limit() {
  _lp="$1"; _ln="$2"; _lw="${3:-loop}"; _lt="$4"; _lx="${5:-0}"
  grep -q "^$_lp|" "$ACT" 2>/dev/null && return 0
  grep -q "^$_lp|" "$GHOST" 2>/dev/null && return 0
  _lo="$(_ops "$_lp")"
  _lm="$(_pmode "$_lo" RUN_ANY_IN_BACKGROUND)"; _lm="${_lm:-default}"
  _lu="$(_umode "$_lo" RUN_ANY_IN_BACKGROUND)"; _lu="${_lu:-default}"
  case "$_lm$_lu" in *ignore*|*deny*) _note_once "$_lp" "$_ln" already_restricted; return 0 ;; esac
  # Positive runtime evidence wins over the package-name heuristic. Empty/unknown output is
  # not treated as proof that no service or permission exists; user confirmation is still required.
  case "$_lo" in *'SCHEDULE_EXACT_ALARM: allow'*|*'USE_EXACT_ALARM: allow'*) _note_once "$_lp" "$_ln" protected_alarm; return 0 ;; esac
  if dumpsys activity services "$_lp" 2>/dev/null | grep -qE 'isForeground=true|foregroundServiceTypes?=[1-9]'; then
    _note_once "$_lp" "$_ln" protected_fgs; return 0
  fi
  if _has settings; then
    _nl="$(settings get secure enabled_notification_listeners 2>/dev/null)"
    _na="$(settings get secure enabled_notification_policy_access_packages 2>/dev/null)"
    case "$_nl:$_na" in *"$_lp/"*|*"$_lp:"*|*"$_lp;"*) _note_once "$_lp" "$_ln" protected_notifications; return 0 ;; esac
  fi
  appops set "$_lp" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  if [ "$(_pmode "$(_ops "$_lp")" RUN_ANY_IN_BACKGROUND)" = ignore ]; then
    mkdir -p "$D" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_lp" "$_lm" "$_lu" "$(_now)" "$_ln" "$_lw" "$_lt" "$_lx" >> "$ACT"
    _note "$_lp" "$_ln" limited "$_lw"
  else
    appops set "$_lp" RUN_ANY_IN_BACKGROUND "$_lm" >/dev/null 2>&1
    _note_once "$_lp" "$_ln" refused
  fi
}
_pending_drop() {
  [ -s "$PEND" ] || return 0
  awk -F'|' -v p="$1" '$1 != p' "$PEND" > "$PEND.tmp" 2>/dev/null || return 0
  if [ -s "$PEND.tmp" ]; then mv -f "$PEND.tmp" "$PEND"; else rm -f "$PEND" "$PEND.tmp"; fi
}
_guard_admit() {
  _gp="$1"; _gn="$2"; _gw="$3"; _gt="$4"; _gx="$5"; _gs="$6"
  grep -q "^$_gp|" "$ACT" 2>/dev/null && return 0
  grep -q "^$_gp|" "$GHOST" 2>/dev/null && return 0
  case "$_gs" in ''|*[!0-9]*) _gs=0 ;; esac
  _gns=1; _gpr="$(grep -m1 "^$_gp|" "$PEND" 2>/dev/null)"
  if [ -n "$_gpr" ]; then
    _gns="$(printf '%s' "$_gpr" | cut -d'|' -f2)"
    _gls="$(printf '%s' "$_gpr" | cut -d'|' -f3)"
    case "$_gns" in ''|*[!0-9]*) _gns=1 ;; esac
    [ "$_gls" = "$_gs" ] || _gns=$(( _gns + 1 ))
  fi
  mkdir -p "$TMPD" 2>/dev/null
  awk -F'|' -v p="$_gp" '$1 != p' "$PEND" 2>/dev/null > "$PEND.tmp" 2>/dev/null || true
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$_gp" "$_gns" "$_gs" "$_gn" "$_gw" "$_gt" "$_gx" >> "$PEND.tmp" 2>/dev/null && mv -f "$PEND.tmp" "$PEND"
  if [ "$_gns" -lt "$MINSESS" ]; then
    _note_once "$_gp" "$_gn" evidence_session "$_gw"
    return 0
  fi
  if ! grep -qxF "$_gp" "$APPROVED" 2>/dev/null; then
    _note_once "$_gp" "$_gn" confirmation_required "$_gw"
    return 0
  fi
  _limit "$_gp" "$_gn" "$_gw" "$_gt" "$_gx"
  grep -q "^$_gp|" "$ACT" 2>/dev/null && _pending_drop "$_gp"
}
_since_limit() {
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  _sc="$(printf '%s\n' "$3" | awk -v p="$1" '$1 == p { print $2; exit }')"
  case "$_sc" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_sc" -ge "$2" ]; then echo $(( _sc - $2 )); else echo "$_sc"; fi
}
_lift_rows() {
  [ -s "$ACT" ] || { rm -f "$ACT" 2>/dev/null; return 0; }
  _lr="$1"; _lsel="$2"; _lpk="${3:-}"
  _lc="$(_ledger)"; _lb="$(_ledger_bg_on)"
  true > "$ACT.keep" 2>/dev/null || return 0
  while IFS='|' read -r _fp _fm _fu _fs _fn _fw _ft _fx; do
    _pkgok "$_fp" || continue
    case "$_fw" in loop_on|waker) ;; *) _fw=loop ;; esac
    _go=0
    case "$_lsel" in
      all) _go=1 ;;
      off) [ "$_fw" != loop_on ] && _go=1 ;;
      expired) [ "$_fw" = loop_on ] && case "$_fx" in ''|*[!0-9]*) _go=1 ;; *) [ "$(_now)" -ge "$_fx" ] && _go=1 ;; esac ;;
      pkg) [ "$_fp" = "$_lpk" ] && _go=1 ;;
    esac
    if [ "$_go" = 1 ]; then
      appops set "$_fp" RUN_ANY_IN_BACKGROUND "${_fm:-default}" >/dev/null 2>&1
      if [ "$_fw" = loop_on ]; then _fa="$(_since_limit "$_fp" "$_ft" "$_lb")"; else _fa="$(_since_limit "$_fp" "$_ft" "$_lc")"; fi
      [ "${ASB_ZG_QUIET:-0}" = 1 ] || _note "$_fp" "${_fn:-0}" "lifted_$_lr" "$_fa"
    else
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_fp" "$_fm" "$_fu" "$_fs" "$_fn" "$_fw" "$_ft" "$_fx" >> "$ACT.keep"
    fi
  done < "$ACT"
  if [ -s "$ACT.keep" ]; then mv -f "$ACT.keep" "$ACT"; else rm -f "$ACT" "$ACT.keep" 2>/dev/null; fi
}
_lift_all() { _lift_rows "$1" all; }
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
          _nr="$(awk -F'|' '$6 != "loop_on"' "$ACT" 2>/dev/null | grep -c '|')"
          mkdir -p "$D" 2>/dev/null
          { [ -f "$NIGHT" ] && tail -n 6 "$NIGHT"; printf '%s|%s|%s|%s|%s\n' "$_st" "$_et" "$_tot" "${_nr:-0}" "${_top:--}"; } > "$NIGHT.tmp" 2>/dev/null \
            && mv -f "$NIGHT.tmp" "$NIGHT"
        fi
        ;;
    esac
  fi
  rm -f "$BASE" "$SEEN" 2>/dev/null
}
_hist_update() {
  _hb="$(tr -d ' \r\n' < "$BOOTID" 2>/dev/null)"; _hb="${_hb:-none}"
  _hh="$(sed -n 1p "$HIST" 2>/dev/null)"
  _hob="$(printf '%s' "$_hh" | awk '$1 == "b" { print $2 }')"
  _hf="$(printf '%s' "$_hh" | awk '$1 == "b" { print $3 }')"
  case "$_hf" in ''|*[!0-9]*) _hf="$(_now)" ;; esac
  _hs=0; [ "$_hb" = "$_hob" ] && _hs=1
  mkdir -p "$D" 2>/dev/null
  _ledger_cols | awk -v same="$_hs" -v bid="$_hb" -v first="$_hf" -v hf="$HIST" '
    BEGIN {
      while ((getline ln < hf) > 0) {
        n = split(ln, f, " ")
        if (n == 7 && f[1] ~ /^[A-Za-z0-9_.]+$/) {
          o[f[1]] = f[2] + 0; w[f[1]] = f[3] + 0; t[f[1]] = f[4] + 0
          lo[f[1]] = same ? f[5] + 0 : 0; lw[f[1]] = same ? f[6] + 0 : 0; lt[f[1]] = same ? f[7] + 0 : 0
        }
      }
    }
    function add(cur, last) { return (cur >= last) ? cur - last : cur }
    NF == 4 && $1 ~ /^[A-Za-z0-9_.]+$/ {
      p = $1
      o[p] += add($2 + 0, lo[p] + 0); w[p] += add($3 + 0, lw[p] + 0); t[p] += add($4 + 0, lt[p] + 0)
      lo[p] = $2 + 0; lw[p] = $3 + 0; lt[p] = $4 + 0
    }
    END { print "b " bid " " first; for (p in o) print p, o[p] + 0, w[p] + 0, t[p] + 0, lo[p] + 0, lw[p] + 0, lt[p] + 0 }' > "$HIST.tmp" 2>/dev/null || return 0
  { sed -n 1p "$HIST.tmp"; sed 1d "$HIST.tmp" | awk '{ print $2 + $3, $0 }' | sort -k1,1nr | head -n 96 | cut -d' ' -f2-; } > "$HIST.new" 2>/dev/null \
    && mv -f "$HIST.new" "$HIST"
  rm -f "$HIST.tmp" 2>/dev/null
}
_hist_days10() {
  _hf2="$(sed -n '1s/^b [^ ]* \([0-9]*\)$/\1/p' "$HIST" 2>/dev/null)"
  case "$_hf2" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  echo $(( ( $(_now) - _hf2 ) * 10 / 86400 ))
}
_hist_row() { awk -v p="$1" '$1 == p && NF == 7 { b = $2 + $3 - $4; if (b < 0) b = 0; print b, $4; exit }' "$HIST" 2>/dev/null; }
_ghost_scan() {
  _gt="$(sed -n '1s/^at //p' "$GHC" 2>/dev/null)"
  case "$_gt" in ''|*[!0-9]*) _gt=0 ;; esac
  [ $(( $(_now) - _gt )) -ge "$GEVERY" ] || return 0
  _gd="$(_hist_days10)"
  mkdir -p "$D" 2>/dev/null
  { echo "at $(_now)"
    if [ "$_gd" -ge $(( GDAYS * 10 )) ]; then
      _gu="$(_users)"
      awk -v gmin="$GMIN" 'NF == 7 && $1 ~ /^[A-Za-z0-9_.]+$/ { b = $2 + $3 - $4; if ($4 == 0 && b >= gmin) print $1, b }' "$HIST" 2>/dev/null \
        | sort -k2,2nr | head -n 8 | while read -r _gp _gb; do
          _pkgok "$_gp" || continue
          printf '%s\n' "$_gu" | grep -qxF "$_gp" || continue
          grep -q "^$_gp|" "$GHOST" 2>/dev/null && continue
          _protected "$_gp" && continue
          case "$(am get-inactive "$_gp" 2>/dev/null)" in *Idle=true*) ;; *) continue ;; esac
          printf '%s|%s|%s\n' "$_gp" "$_gb" "$_gd"
        done
    fi
  } > "$GHC.tmp" 2>/dev/null && mv -f "$GHC.tmp" "$GHC"
}
_ghost_check() {
  [ -s "$GHOST" ] || return 0
  while IFS='|' read -r _hp _hm _hu _hs _hb _hd _ht; do
    _pkgok "$_hp" || continue
    _hr="$(_hist_row "$_hp")"; _hrt="${_hr#* }"
    case "$_hrt$_ht" in ''|*[!0-9]*) continue ;; esac
    [ "$_hrt" -gt "$_ht" ] && _ghost_release "$_hp" opened >/dev/null
  done < "$GHOST"
}
_ghost_restrict() {
  _pkgok "$1" || { echo 'result=bad_request'; return 0; }
  _users | grep -qxF "$1" || { echo 'result=not_user_app'; return 0; }
  _protected "$1" && { echo 'result=protected'; return 0; }
  grep -q "^$1|" "$GHOST" 2>/dev/null && { echo 'result=already'; return 0; }
  grep -q "^$1|" "$ACT" 2>/dev/null && _lift_rows released pkg "$1"
  _restricted_now "$1" && { echo 'result=already_restricted'; return 0; }
  _go="$(_ops "$1")"
  _gm="$(_pmode "$_go" RUN_ANY_IN_BACKGROUND)"; _gm="${_gm:-default}"
  _gu2="$(_umode "$_go" RUN_ANY_IN_BACKGROUND)"; _gu2="${_gu2:-default}"
  appops set "$1" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  if [ "$(_pmode "$(_ops "$1")" RUN_ANY_IN_BACKGROUND)" != ignore ]; then
    appops set "$1" RUN_ANY_IN_BACKGROUND "$_gm" >/dev/null 2>&1
    _note "$1" 0 refused ghost; echo 'result=refused'; return 0
  fi
  _gr="$(_hist_row "$1")"; _gb2="${_gr%% *}"; _gt2="${_gr#* }"
  case "$_gb2" in ''|*[!0-9]*) _gb2=0 ;; esac
  case "$_gt2" in ''|*[!0-9]*) _gt2=0 ;; esac
  mkdir -p "$D" 2>/dev/null
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$_gm" "$_gu2" "$(_now)" "$_gb2" "$(_hist_days10)" "$_gt2" >> "$GHOST"
  awk -F'|' -v p="$1" 'NR == 1 || $1 != p' "$GHC" > "$GHC.t" 2>/dev/null && mv -f "$GHC.t" "$GHC"
  _note "$1" "$_gb2" limited ghost
  echo 'result=restricted'
}
_ghost_release() {
  _pkgok "$1" || { echo 'result=bad_request'; return 0; }
  _rl="$(grep -m1 "^$1|" "$GHOST" 2>/dev/null)"
  [ -n "$_rl" ] || { echo 'result=not_held'; return 0; }
  _rm="$(printf '%s' "$_rl" | cut -d'|' -f2)"; _rb="$(printf '%s' "$_rl" | cut -d'|' -f5)"
  appops set "$1" RUN_ANY_IN_BACKGROUND "${_rm:-default}" >/dev/null 2>&1
  awk -F'|' -v p="$1" '$1 != p' "$GHOST" > "$GHOST.t" 2>/dev/null && mv -f "$GHOST.t" "$GHOST"
  [ -s "$GHOST" ] || rm -f "$GHOST" 2>/dev/null
  _hr2="$(_hist_row "$1")"; _hn="${_hr2%% *}"
  _ha=""; case "$_hn$_rb" in ''|*[!0-9]*) ;; *) [ "$_hn" -ge "$_rb" ] && _ha=$(( _hn - _rb )) ;; esac
  [ "${ASB_ZG_QUIET:-0}" = 1 ] || _note "$1" "${_rb:-0}" "lifted_${2:-released}" "$_ha"
  echo 'result=released'
}
_ghost_release_all() {
  [ -s "$GHOST" ] || return 0
  cut -d'|' -f1 "$GHOST" | while read -r _ap; do _ghost_release "$_ap" "$1" >/dev/null; done
  rm -f "$GHOST" "$GHOST.t" 2>/dev/null
}
_tick_on() {
  _on_now="$(_now)"
  if [ ! -s "$ONSESS" ]; then mkdir -p "$TMPD" 2>/dev/null; echo "$_on_now" > "$ONSESS" 2>/dev/null; fi
  _ons="$(head -n 1 "$ONSESS" 2>/dev/null)"; case "$_ons" in ''|*[!0-9]*) _ons="$_on_now" ;; esac
  _lift_rows screen_on off
  rm -f "$PREV" 2>/dev/null
  _lift_rows expired expired
  if [ -s "$ACT" ] && grep -q '|loop_on|' "$ACT" 2>/dev/null; then
    [ -f "$MODDIR/runtime/asb_procstate.sh" ] && . "$MODDIR/runtime/asb_procstate.sh" 2>/dev/null
    if command -v asb_lru_load >/dev/null 2>&1; then
      asb_lru_load
      awk -F'|' '$6 == "loop_on" { print $1 }' "$ACT" | while read -r _vp; do
        [ "$(asb_pkg_proc_class "$_vp")" = active ] && _lift_rows in_use pkg "$_vp"
      done
    fi
  fi
  _on_cur="$(_ledger_bg_on)"
  [ -n "$_on_cur" ] || return 0
  _on_pt="$(sed -n '1s/^t //p' "$PREVON" 2>/dev/null)"
  sed '1d' "$PREVON" > "$PREVON.old" 2>/dev/null || rm -f "$PREVON.old" 2>/dev/null
  mkdir -p "$TMPD" 2>/dev/null
  { echo "t $_on_now"; printf '%s\n' "$_on_cur"; } > "$PREVON.tmp" 2>/dev/null && mv -f "$PREVON.tmp" "$PREVON"
  case "$_on_pt" in ''|*[!0-9]*) rm -f "$PREVON.old"; return 0 ;; esac
  _on_dt=$(( _on_now - _on_pt ))
  { [ "$_on_dt" -gt 0 ] && [ "$_on_dt" -le 1800 ]; } || { rm -f "$PREVON.old"; return 0; }
  _on_c="$(printf '%s\n' "$_on_cur" | awk -v pf="$PREVON.old" -v dt="$_on_dt" -v min="$MIN" '
    BEGIN { while ((getline l < pf) > 0) { n = split(l, f, " "); if (n == 2) pv[f[1]] = f[2] + 0 } }
    NF == 2 && ($1 in pv) { d = $2 - pv[$1]; if (d >= min && int(d * 300 / dt) >= min) print $1, d, $2 }')"
  rm -f "$PREVON.old" 2>/dev/null
  [ -n "$_on_c" ] || return 0
  [ -f "$MODDIR/runtime/asb_procstate.sh" ] && . "$MODDIR/runtime/asb_procstate.sh" 2>/dev/null
  command -v asb_lru_load >/dev/null 2>&1 || return 0
  asb_lru_load
  _on_u="$(_users)"
  printf '%s\n' "$_on_c" | while read -r _op _od _ot; do
    _pkgok "$_op" || continue
    printf '%s\n' "$_on_u" | grep -qxF "$_op" || continue
    case "$(asb_pkg_proc_class "$_op")" in cached|background|none) ;; *) continue ;; esac
    if _protected "$_op"; then _note_once "$_op" "$_od" protected; continue; fi
    _guard_admit "$_op" "$_od" loop_on "$_ot" $(( _on_now + HOLD_S )) "$_ons"
  done
}
_tick() {
  [ -f "$ON" ] || return 0
  _has appops && _has pm && _has dumpsys || return 0
  _hist_update
  _ghost_check
  _ghost_scan
  if _screen_on; then _session_end; _tick_on; return 0; fi
  rm -f "$PREVON" "$ONSESS" 2>/dev/null
  _lift_rows expired expired
  _now_t="$(_now)"
  _cur="$(_ledger)"
  [ -n "$_cur" ] || return 0
  mkdir -p "$TMPD" 2>/dev/null
  [ -s "$BASE" ] || { echo "t $_now_t"; printf '%s\n' "$_cur"; } > "$BASE" 2>/dev/null
  _bs="$(sed -n '1s/^t //p' "$BASE" 2>/dev/null)"; case "$_bs" in ''|*[!0-9]*) _bs="$_now_t" ;; esac
  _pt="$(sed -n '1s/^t //p' "$PREV" 2>/dev/null)"
  sed '1d' "$PREV" > "$PREV.old" 2>/dev/null || rm -f "$PREV.old" 2>/dev/null
  { echo "t $_now_t"; printf '%s\n' "$_cur"; } > "$PREV.tmp" 2>/dev/null && mv -f "$PREV.tmp" "$PREV"
  _dt=0
  case "$_pt" in ''|*[!0-9]*) ;; *) _dt=$(( _now_t - _pt )); { [ "$_dt" -gt 0 ] && [ "$_dt" -le 1800 ]; } || _dt=0 ;; esac
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
  _tu="$(_users)"
  printf '%s\n' "$_cands" | while read -r _cp _cn _cw _ct; do
    _pkgok "$_cp" || continue
    printf '%s\n' "$_tu" | grep -qxF "$_cp" || continue
    if _protected "$_cp"; then _note_once "$_cp" "$_cn" protected; continue; fi
    _guard_admit "$_cp" "$_cn" "$_cw" "$_ct" 0 "$_bs"
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
  echo "ghost_min=$GMIN"
  echo "ghost_days=$GDAYS"
  echo "history_days10=$(_hist_days10)"
  echo "sessions_required=$MINSESS"
  if [ -s "$PEND" ]; then
    while IFS='|' read -r _pp _ps _pl _pn _pw _pt _px; do
      _pkgok "$_pp" || continue
      case "$_ps$_pl$_pn$_pt$_px" in *[!0-9]*) continue ;; esac
      case "$_pw" in loop|waker|loop_on) ;; *) continue ;; esac
      _pa=0; grep -qxF "$_pp" "$APPROVED" 2>/dev/null && _pa=1
      printf 'pending|%s|%s|%s|%s|%s\n' "$_pp" "$_ps" "$_pn" "$_pw" "$_pa"
    done < "$PEND"
  fi
  if [ -s "$ACT" ]; then
    _lc="$(_ledger)"; _lb="$(_ledger_bg_on)"
    while IFS='|' read -r _sp _sm _su _ss _sn _sw _st _sx; do
      _pkgok "$_sp" || continue
      case "$_sw" in waker|loop_on) ;; *) _sw=loop ;; esac
      if [ "$_sw" = loop_on ]; then _sa="$(_since_limit "$_sp" "$_st" "$_lb")"; else _sa="$(_since_limit "$_sp" "$_st" "$_lc")"; fi
      case "$_sx" in ''|*[!0-9]*) _sx=0 ;; esac
      printf 'active|%s|%s|%s|%s|%s|%s\n' "$_sp" "${_ss:-0}" "${_sn:-0}" "$_sw" "$_sa" "$_sx"
    done < "$ACT"
  fi
  if [ -s "$HIST" ]; then
    awk 'NF == 7 && $1 ~ /^[A-Za-z0-9_.]+$/ { b = $2 + $3 - $4; if (b < 0) b = 0; if (b > 0) print b, $1, $2, $3, $4 }' "$HIST" 2>/dev/null \
      | sort -k1,1nr | head -n 8 | while read -r _xb _xp _xo _xn _xt; do
        printf 'bg|%s|%s|%s|%s|%s\n' "$_xp" "$_xb" "$_xo" "$_xn" "$_xt"
      done
  fi
  [ -s "$GHC" ] && sed 1d "$GHC" | while IFS='|' read -r _cp _cb _cd; do
    _pkgok "$_cp" && printf 'suggest|%s|%s|%s\n' "$_cp" "$_cb" "$_cd"
  done
  if [ -s "$GHOST" ]; then
    _hd="$(_hist_days10)"
    while IFS='|' read -r _hp _hm _hu _hs _hb _hdd _ht; do
      _pkgok "$_hp" || continue
      _hr="$(_hist_row "$_hp")"; _hn="${_hr%% *}"
      case "$_hn" in ''|*[!0-9]*) _hn="$_hb" ;; esac
      _hsince=$(( ( $(_now) - _hs ) * 10 / 86400 ))
      _pre=0; [ "${_hdd:-0}" -gt 0 ] 2>/dev/null && _pre=$(( _hb * 100 / _hdd ))
      _post=-1; [ "$_hsince" -ge 5 ] 2>/dev/null && _post=$(( (_hn - _hb) * 100 / _hsince ))
      printf 'held|%s|%s|%s|%s|%s\n' "$_hp" "$_hs" "$_pre" "$_post" "$_hsince"
    done < "$GHOST"
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
    mkdir -p "$D" 2>/dev/null; printf '%s\n' "${2:-loops}" > "$ON" && { _hist_update; echo 'result=enabled'; } ;;
  disable) rm -f "$ON" "$PREV" "$PREVON" "$BASE" "$SEEN" "$PEND" "$PEND.tmp" "$ONSESS" 2>/dev/null; _lift_all disabled; _ghost_release_all disabled; echo 'result=disabled' ;;
  tick) _tick ;;
  screen_on) _session_end; [ -s "$ACT" ] && _lift_rows screen_on off; rm -f "$PREV" 2>/dev/null ;;
  approve)
    _pkgok "$2" && grep -q "^$2|" "$PEND" 2>/dev/null || { echo 'result=not_pending'; exit 0; }
    mkdir -p "$D" 2>/dev/null
    grep -qxF "$2" "$APPROVED" 2>/dev/null || { echo "$2" >> "$APPROVED" 2>/dev/null; }
    echo 'result=approved' ;;
  release)
    _pkgok "$2" && grep -q "^$2|" "$ACT" 2>/dev/null || { echo 'result=not_held'; exit 0; }
    _lift_rows emergency pkg "$2"
    _pending_drop "$2"
    if [ -s "$APPROVED" ]; then
      grep -vxF "$2" "$APPROVED" > "$APPROVED.tmp" 2>/dev/null && mv -f "$APPROVED.tmp" "$APPROVED"
      [ -s "$APPROVED" ] || rm -f "$APPROVED" 2>/dev/null
    fi
    echo 'result=released' ;;
  ghost-restrict) [ -f "$ON" ] || { echo 'result=disabled'; exit 0; }; _ghost_restrict "$2" ;;
  ghost-release) _ghost_release "$2" released ;;
  restore-all)
    ASB_ZG_QUIET=1 _lift_all uninstall; ASB_ZG_QUIET=1 _ghost_release_all uninstall
    rm -f "$ON" "$PREV" "$PREVON" "$BASE" "$SEEN" "$PEND" "$PEND.tmp" "$ONSESS" "$APPROVED" "$APPROVED.tmp" "$LOG" "$NIGHT" "$HIST" "$GHOST" "$GHC" "$GHC.tmp" "$HIST.tmp" "$HIST.new" 2>/dev/null ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
