#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_S7_DIR:-/data/adb/asb/smart7}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
UPTIME="${ASB_S7_UPTIME:-/proc/uptime}"
KEEP="${ASB_S7_KEEP:-/data/adb/asb/doze_whitelist_keep}"
NFL="${ASB_S7_NOTIF:-/data/adb/asb/notif_fix}"
PROF="${ASB_S7_PROFILE:-$MODDIR/current_profile}"
TTL="${ASB_S7_EVID_TTL:-21600}"
AUTO_EVERY="${ASB_S7_AUTO_S:-86400}"
B_IDLE="${ASB_S7_B_IDLE:-7}"
B_BG="${ASB_S7_B_BG:-6}"
B_SOFT_IDLE="${ASB_S7_B_SOFT_IDLE:-14}"
B_SOFT_BG="${ASB_S7_B_SOFT_BG:-10}"
N_IDLE="${ASB_S7_N_IDLE:-3}"
N_MIB="${ASB_S7_N_MIB:-5}"
N_AUTO_MIB="${ASB_S7_N_AUTO_MIB:-10}"
N_DAYS="${ASB_S7_N_DAYS:-3}"
EVID="$D/evidence"
JOUR="$D/journal"
LOCK="$D/refresh.lock"

_now() { date +%s 2>/dev/null || echo 0; }
_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) return 1 ;; *.*) return 0 ;; esac
  return 1
}
_upsec() { _u=""; read -r _u _rest < "$UPTIME" 2>/dev/null; echo "${_u%%.*}"; }
_tzoff() {
  _z="$(date +%z 2>/dev/null)"
  case "$_z" in
    [+-][0-9][0-9][0-9][0-9])
      _zs="${_z%????}"; _zh="${_z#?}"; _zm="${_zh#??}"; _zh="${_zh%??}"
      _zo=$(( (${_zh#0} * 3600) + (${_zm#0} * 60) ))
      [ "$_zs" = - ] && _zo=$((0 - _zo))
      echo "$_zo" ;;
    *) echo 0 ;;
  esac
}
_tmo() { command -v timeout >/dev/null 2>&1 && echo "timeout $1"; }
_usage() {
  $(_tmo 10) dumpsys usagestats 2>/dev/null | awk -v off="$(_tzoff)" '
    function days(y, m, d) { if (m <= 2) { y--; m += 12 } return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d }
    function secs(t) {
      if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return -1
      return (days(substr(t, 1, 4) + 0, substr(t, 6, 2) + 0, substr(t, 9, 2) + 0) - days(1970, 1, 1)) * 86400 + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2) - off
    }
    /package=[A-Za-z0-9_.]+ / && /lastTimeUsed="/ {
      p = $0; sub(/.*package=/, "", p); sub(/ .*/, "", p)
      t = $0; sub(/.*lastTimeUsed="/, "", t); sub(/".*/, "", t)
      s = secs(t); seen++
      if (s > 86400 && (!(p in L) || s > L[p])) L[p] = s
    }
    END { if (seen) { print "us=ok"; for (p in L) printf "u|%s|%d\n", p, L[p] } else print "us=none" }'
}
_netbg() {
  $(_tmo 10) dumpsys netstats --uid 2>/dev/null | awk -v since="$(( $(_now) - N_DAYS * 86400 ))" '
    /^UID stats:/ { sec = 1; next }
    /^[A-Za-z][A-Za-z ]*:/ { sec = 0; cur = ""; next }
    sec && /uid=[0-9]+[ \t]+set=/ {
      cur = ""
      if ($0 ~ /type=0[,}]/ && $0 ~ /tag=0x0([^0-9a-f]|$)/ && $0 ~ /set=(DEFAULT|0)([^A-Za-z0-9]|$)/) { u = $0; sub(/.*uid=/, "", u); sub(/[ \t].*/, "", u); cur = u + 0 }
      next
    }
    sec && cur != "" && /st=[0-9]+[ \t]+rb=[0-9]+/ {
      st = $0; sub(/.*st=/, "", st); sub(/[ \t].*/, "", st)
      rb = $0; sub(/.*rb=/, "", rb); sub(/[ \t].*/, "", rb)
      tb = $0; sub(/.*tb=/, "", tb); sub(/[ \t].*/, "", tb)
      if (st + 0 >= since) { B[cur] += rb + tb; ok = 1 }
    }
    END { print (ok ? "ns=ok" : "ns=none"); for (u in B) if (B[u] > 0) printf "n|%d|%d\n", u, B[u] / 1024 }'
}
_refresh_now() {
  mkdir -p "$D" 2>/dev/null
  {
    echo "at=$(_now)"
    pm list packages -3 -U 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.][A-Za-z0-9_.]*\) uid:\([0-9][0-9]*\).*/i|\1|\2/p'
    _usage
    _netbg
  } > "$D/evidence.tmp" 2>/dev/null && mv -f "$D/evidence.tmp" "$EVID"
}
_refresh() {
  mkdir -p "$D" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    _lp=""; read -r _lp < "$LOCK/pid" 2>/dev/null
    case "$_lp" in ''|*[!0-9]*) ;; *) kill -0 "$_lp" 2>/dev/null && return 0 ;; esac
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || return 0
  fi
  echo $$ > "$LOCK/pid"
  _refresh_now
  rm -rf "$LOCK" 2>/dev/null
}
_evid_age() {
  _ea="$(sed -n 's/^at=//p' "$EVID" 2>/dev/null | head -n 1)"
  case "$_ea" in ''|*[!0-9]*) echo -1 ;; *) echo $(( $(_now) - _ea )) ;; esac
}
_ledger() {
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ { o[$2] += $3; n[$2] += $4; t[$2] += $5 }
    END { for (p in o) print p, o[p], n[p], t[p] }'
}
_bucket() { am get-standby-bucket "$1" 2>/dev/null | tr -d ' \r\n'; }
_np() {
  _no="$(cmd netpolicy "$1" restrict-background-blacklist $2 2>&1)"
  case "$_no" in
    *[Ee]rror*|*[Uu]nknown*|*[Ii]nvalid*|*[Uu]nsupported*) cmd netpolicy "$1" restrict-background-denylist $2 2>&1 ;;
    *) printf '%s\n' "$_no" ;;
  esac
}
_denied() { _np list "" | sed 's/^[^:]*://' | tr ' ,' '\n\n' | grep -E '^[0-9]+$'; }
_profile() { _pr="$(cat "$PROF" 2>/dev/null | tr -d ' \r\n')"; echo "${_pr:-none}"; }
_auto_on() { [ -f "$D/auto_$1" ]; }
_candidates() {
  _cup="$(_upsec)"
  _cp="$(_profile)"
  { [ -s "$EVID" ] && sed 's/^/E|/' "$EVID"
    _ledger | sed 's/^/L|/'
    [ -s "$KEEP" ] && sed 's/^/K|/' "$KEEP"
    [ -s "$NFL" ] && cut -d'|' -f1 "$NFL" | sed 's/^/K|/'
    [ -s "$JOUR" ] && awk -F'|' '$8 == "active" { print "J|" $4 "|" $5 }' "$JOUR"
    _denied 2>/dev/null | sed 's/^/X|/'
  } | awk -v now="$(_now)" -v up="${_cup:-0}" -v bi="$B_IDLE" -v bb="$B_BG" -v si="$B_SOFT_IDLE" -v sb="$B_SOFT_BG" \
      -v ni="$N_IDLE" -v nm="$N_MIB" -v na="$N_AUTO_MIB" -v nd="$N_DAYS" -v soft="$( [ "$_cp" = battery ] && echo 1 || echo 0)" \
      -v ab="$(_auto_on budget && echo 1 || echo 0)" '
    function prot(p) {
      if (p in K) return 1
      return (p ~ /authenticator|\.auth\.|\.otp\.|twofactor|passkey|\.mfa\.|bluetooth|wearable|\.wear\.|watch|fitbit|garmin|amazfit|zepp|huami|health|truecaller|callerid|callblock|vpn|wireguard|\.clock|alarm|maps|navi|waze|^org\.telegram\.|^com\.whatsapp|^org\.thoughtcrime\.securesms|^im\.vector\.|^com\.viber\.|^com\.discord$|^com\.Slack$|^com\.microsoft\.teams|^com\.skype\.|^jp\.naver\.line\.|^com\.facebook\.orca$|^com\.kakao\.talk$|^com\.tencent\.mm$|^com\.wire$|^ch\.threema\.|^com\.google\.android\.gm$|^com\.microsoft\.office\.outlook$|\.mail|\.email|^com\.zoom\.|^us\.zoom\.|launcher|\.home$|inputmethod|keyboard|^com\.android\.|^com\.google\.android\.gms|^com\.oplus\.|^com\.coloros\.|^com\.heytap\.|^com\.oneplus\./)
    }
    { t = substr($0, 1, 2); r = substr($0, 3); n = split(r, f, "|") }
    t == "E|" { if (r == "us=ok") us = 1; else if (r == "ns=ok") ns = 1; else if (f[1] == "i" && n == 3) I[f[2]] = f[3]; else if (f[1] == "u" && n == 3) U[f[2]] = f[3] + 0; else if (f[1] == "n" && n == 3) N[f[2]] = f[3] + 0; next }
    t == "L|" { split(r, g, " "); b = g[2] + g[3] - g[4]; if (b < g[2]) b = g[2]; BG[g[1]] = b; led = 1; next }
    t == "K|" { K[r] = 1; next }
    t == "J|" { J[f[1] "|" f[2]] = 1; next }
    t == "X|" { X[r] = 1; next }
    END {
      upd = up / 86400; if (upd < 0.25) upd = 0.25
      for (p in I) {
        if (prot(p)) continue
        idle = (us && (p in U)) ? int((now - U[p]) / 86400) : (us ? 9999 : -1)
        if (led && us && !(("budget|" p) in J)) {
          bg = int((BG[p] + 0) / upd + 0.5)
          if (idle >= bi && bg >= bb) {
            au = ab ? 1 : (soft && idle >= si && bg >= sb ? 1 : 0)
            printf "cand|budget|%s|%s|%d|%d|%d\n", p, I[p], idle, bg, au
          }
        }
        if (ns && us && !(("data|" p) in J) && !(I[p] in X)) {
          mib = (N[I[p]] + 0) / 1024 / nd
          if (idle >= ni && mib >= nm) printf "cand|data|%s|%s|%d|%d|%d\n", p, I[p], idle, int(mib + 0.5), (mib >= na ? 1 : 0)
        }
      }
      printf "usage=%s\nnetstats=%s\nledger=%d\n", us ? "ok" : "unknown", ns ? "ok" : "unknown", led
    }'
}
_jid() { awk -F'|' '$1 ~ /^[0-9]+$/ && $1 > m { m = $1 } END { print m + 1 }' "$JOUR" 2>/dev/null; }
_journal() {
  mkdir -p "$D" 2>/dev/null
  _jn="$(_jid)"; [ -n "$_jn" ] || _jn=1
  printf '%s|%s|%s|%s|%s|%s|%s|active\n' "$_jn" "$(_now)" "$1" "$2" "$3" "$4" "$5" >> "$JOUR"
}
_apply() {
  _ae="$1"; _ap="$2"; _ak="$3"
  _pkgok "$_ap" || return 2
  _au="$(pm list packages -3 -U 2>/dev/null | sed -n "s/^package:$_ap uid:\([0-9][0-9]*\).*/\1/p" | head -n 1)"
  case "$_au" in ''|*[!0-9]*) return 1 ;; esac
  case "$_ae" in
    budget)
      _ab="$(_bucket "$_ap")"
      case "$_ab" in 10|20|30) ;; *) return 1 ;; esac
      am set-standby-bucket "$_ap" rare >/dev/null 2>&1
      [ "$(_bucket "$_ap")" = 40 ] || return 1
      _journal "$_ak" budget "$_ap" "$_au" "$_ab" ;;
    data)
      _denied | grep -qx "$_au" && return 0
      _np add "$_au" >/dev/null
      _denied | grep -qx "$_au" || return 1
      _journal "$_ak" data "$_ap" "$_au" 0 ;;
    *) return 2 ;;
  esac
  return 0
}
_undo() {
  _ul="$(awk -F'|' -v i="$1" '$1 == i && $8 == "active"' "$JOUR" 2>/dev/null)"
  [ -n "$_ul" ] || return 1
  _ue="$(printf '%s' "$_ul" | cut -d'|' -f4)"; _up="$(printf '%s' "$_ul" | cut -d'|' -f5)"
  _uu="$(printf '%s' "$_ul" | cut -d'|' -f6)"; _uv="$(printf '%s' "$_ul" | cut -d'|' -f7)"
  _pkgok "$_up" || return 1
  case "$_uu" in ''|*[!0-9]*) return 1 ;; esac
  _uo=undone
  case "$_ue" in
    budget)
      case "$_uv" in 10|20|30) ;; *) return 1 ;; esac
      if [ "$(_bucket "$_up")" = 40 ]; then
        am set-standby-bucket "$_up" "$_uv" >/dev/null 2>&1
        [ "$(_bucket "$_up")" = 40 ] && return 1
      else
        _uo=external
      fi ;;
    data)
      if _denied | grep -qx "$_uu"; then
        _np remove "$_uu" >/dev/null
        _denied | grep -qx "$_uu" && return 1
      else
        _uo=external
      fi ;;
    *) return 1 ;;
  esac
  awk -F'|' -v OFS='|' -v i="$1" -v o="$_uo" '$1 == i { $8 = o } { print }' "$JOUR" > "$JOUR.t" 2>/dev/null && mv -f "$JOUR.t" "$JOUR"
  UNDO_RESULT="$_uo"
  return 0
}
_auto_pass() {
  _aa="$(cat "$D/auto_at" 2>/dev/null)"
  case "$_aa" in ''|*[!0-9]*) _aa=0 ;; esac
  [ $(( $(_now) - _aa )) -ge "$AUTO_EVERY" ] || return 0
  [ "$(_evid_age)" -ge 0 ] || return 0
  _ap_list="$(_candidates | awk -F'|' -v db="$(_auto_on data && echo 1 || echo 0)" '$1 == "cand" && $7 == 1 && ($2 == "budget" || db == 1) { print $2 "|" $3 }')"
  [ -n "$_ap_list" ] || { _now > "$D/auto_at"; return 0; }
  _now > "$D/auto_at"
  for _x in $_ap_list; do _apply "${_x%%\|*}" "${_x#*\|}" auto; done
}
_status() {
  echo 'version=1'
  _auto_on budget && echo 'auto_budget=1' || echo 'auto_budget=0'
  _auto_on data && echo 'auto_data=1' || echo 'auto_data=0'
  echo "profile=$(_profile)"
  echo "evidence_age=$(_evid_age)"
  [ -d "$LOCK" ] && echo 'refreshing=1' || echo 'refreshing=0'
  _candidates
  [ -s "$JOUR" ] && tail -n 30 "$JOUR" | awk -F'|' 'NF == 8 { print "j|" $0 }'
  return 0
}

case "${1:-status}" in
  status) _status ;;
  refresh)
    mkdir -p "$D" 2>/dev/null
    if [ "${ASB_S7_SYNC:-0}" = 1 ]; then _refresh; else MODDIR="$MODDIR" sh "$0" refresh-now >/dev/null 2>&1 & fi
    echo 'result=started' ;;
  refresh-now) _refresh ;;
  apply)
    case "${2:-}" in budget|data) ;; *) echo 'result=bad_request'; exit 2 ;; esac
    _pkgok "${3:-}" || { echo 'result=bad_request'; exit 2; }
    _apply "$2" "$3" user && echo 'result=ok' || { echo 'result=failed'; exit 1; } ;;
  undo)
    case "${2:-}" in ''|*[!0-9]*) echo 'result=bad_request'; exit 2 ;; esac
    if _undo "$2"; then
      [ "$UNDO_RESULT" = external ] && echo 'restore=external' || echo 'restore=restored'
      echo 'result=ok'
    else
      echo 'restore=failed'; echo 'result=failed'; exit 1
    fi ;;
  undo-all)
    _un=0
    [ -s "$JOUR" ] && for _ri in $(awk -F'|' '$8 == "active" { print $1 }' "$JOUR" | sort -rn); do _undo "$_ri" && _un=$((_un + 1)); done
    echo "undone=$_un"; echo 'result=ok' ;;
  auto)
    case "${2:-}" in budget|data) ;; *) echo 'result=bad_request'; exit 2 ;; esac
    case "${3:-}" in
      on) mkdir -p "$D" 2>/dev/null; true > "$D/auto_$2" && echo 'result=on' ;;
      off) rm -f "$D/auto_$2" 2>/dev/null; echo 'result=off' ;;
      *) echo 'result=bad_request'; exit 2 ;;
    esac ;;
  tick)
    if [ ! -d "$D" ]; then [ "$(_profile)" = battery ] || exit 0; mkdir -p "$D" 2>/dev/null; fi
    _age="$(_evid_age)"
    if [ "$_age" -lt 0 ] || [ "$_age" -ge "$TTL" ]; then
      if [ "${ASB_S7_SYNC:-0}" = 1 ]; then _refresh; else MODDIR="$MODDIR" sh "$0" refresh-now >/dev/null 2>&1 & fi
    fi
    _auto_pass ;;
  restore-all)
    [ -s "$JOUR" ] && for _ri in $(awk -F'|' '$8 == "active" { print $1 }' "$JOUR" | sort -rn); do _undo "$_ri"; done
    rm -rf "$D" 2>/dev/null ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
