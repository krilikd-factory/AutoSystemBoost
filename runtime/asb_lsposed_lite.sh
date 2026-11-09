#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_LL_DIR:-/data/adb/asb/lsp_lite}"
LSPD="${ASB_LSPD_DIR:-/data/adb/lspd}"
DB="${ASB_LSPD_DB:-$LSPD/config/modules_config.db}"
BIN="${ASB_GOV_BIN:-$MODDIR/bin/asb}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
BOOTID="${ASB_LL_BOOTID:-/proc/sys/kernel/random/boot_id}"
UPTIME="${ASB_LL_UPTIME:-/proc/uptime}"
DM="${ASB_LL_DM:-/data/adb/asb/drain_meter}"
UIDCPU="${ASB_LL_UIDCPU:-/proc/uid_cputime/show_uid_stat}"
KEEP="${ASB_LL_KEEP:-/data/adb/asb/doze_whitelist_keep}"
NFL="${ASB_LL_NOTIF:-/data/adb/asb/notif_fix}"
PROF="${ASB_LL_PROFILE:-$MODDIR/current_profile}"
UNUSED_D="${ASB_LL_UNUSED_DAYS:-21}"
BG_MIN="${ASB_LL_BG_MIN:-4}"
CRASH_MIN="${ASB_LL_CRASH_MIN:-5}"
WIDE="${ASB_LL_WIDE:-15}"
BG_HEAVY="${ASB_LL_BG_HEAVY:-100}"
TTL="${ASB_LL_EVID_TTL:-21600}"
AUTO_EVERY="${ASB_LL_AUTO_S:-86400}"
AB_H="${ASB_LL_AB_H:-24}"
AB_MAX_H="${ASB_LL_AB_MAX_H:-96}"
AB_OFF_S="${ASB_LL_AB_OFF_S:-21600}"
AB_ON_S="${ASB_LL_AB_ON_S:-3600}"
EVID="$D/evidence"
JOUR="$D/journal"
AUTO="$D/auto"
AUTOAT="$D/auto_at"
AB="$D/ab"
WROTE="$D/written"
EV="$D/events"
LOCK="$D/refresh.lock"

_now() { date +%s 2>/dev/null || echo 0; }
_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) return 1 ;; *.*) return 0 ;; esac
  return 1
}
_boot() { _b="$(tr -d ' \r\n' < "$BOOTID" 2>/dev/null)"; echo "${_b:-unknown}"; }
_upsec() { _u=""; read -r _u _rest < "$UPTIME" 2>/dev/null; echo "${_u%%.*}"; }
_note() {
  mkdir -p "$D" 2>/dev/null
  { [ -f "$EV" ] && tail -n 39 "$EV"; printf '%s|%s|%s|%s|%s\n' "$(_now)" "$1" "$2" "$3" "$4"; } > "$EV.tmp" 2>/dev/null \
    && mv -f "$EV.tmp" "$EV"
}
_inv() {
  [ -f "$BIN" ] || { echo 'modules=unknown'; echo 'reason=no_governor'; return 0; }
  "$BIN" --lspd modules "$DB" 2>/dev/null
}
_ledger() {
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ { o[$2] += $3; n[$2] += $4; t[$2] += $5 }
    END { for (p in o) print p, o[p], n[p], t[p] }'
}
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
_usage() {
  _ut=''
  command -v timeout >/dev/null 2>&1 && _ut='timeout 10'
  $_ut dumpsys usagestats 2>/dev/null | awk -v off="$(_tzoff)" '
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
_crashes() {
  command -v dumpsys >/dev/null 2>&1 || return 0
  _ct=''
  command -v timeout >/dev/null 2>&1 && _ct='timeout 4'
  for _tag in data_app_crash system_app_crash data_app_anr; do
    printf '======== %s\n' "$_tag"
    $_ct dumpsys dropbox -p "$_tag" 2>/dev/null | tail -c 600000
    printf '\n'
  done | awk -v mods="$1" '
    BEGIN { nm = split(mods, M, " ") }
    function flush(   m) { if (proc != "") for (m in got) C[m "|" proc]++; proc = ""; split("", got) }
    /^========/ { flush(); next }
    /^Process: / { flush(); proc = $2; sub(/:.*/, "", proc); next }
    /^[[:space:]]*at / { for (i = 1; i <= nm; i++) if (index($0, M[i] ".")) got[M[i]] = 1 }
    END { flush(); for (k in C) if (k ~ /^[A-Za-z0-9_.]+\|[A-Za-z0-9_.]+$/) printf "c|%s|%d\n", k, C[k] }'
}
_refresh_now() {
  mkdir -p "$D" 2>/dev/null
  _ri="$(_inv)"
  _rm="$(printf '%s\n' "$_ri" | awk -F'|' '$1 == "module" && NF == 4 { printf "%s%s", (n++ ? " " : ""), $2 }')"
  {
    echo "at=$(_now)"
    pm list packages -U 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.][A-Za-z0-9_.]*\) uid:\([0-9][0-9]*\).*/i|\1|\2/p'
    _usage
    _crashes "$_rm"
  } > "$EVID.tmp" 2>/dev/null && mv -f "$EVID.tmp" "$EVID"
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
_assess() {
  _ai="$1"
  _aup="$(_upsec)"
  { printf '%s\n' "$_ai" | sed 's/^/I|/'
    [ -s "$EVID" ] && sed 's/^/E|/' "$EVID"
    _ledger | sed 's/^/L|/'
    [ -s "$KEEP" ] && sed 's/^/K|/' "$KEEP"
    [ -s "$NFL" ] && cut -d'|' -f1 "$NFL" | sed 's/^/K|/'
    [ -s "$AB" ] && sed 's/^/A|/' "$AB"
  } | awk -v now="$(_now)" -v up="${_aup:-0}" -v ud="$UNUSED_D" -v bgmin="$BG_MIN" -v cmin="$CRASH_MIN" -v wide="$WIDE" -v bgh="$BG_HEAVY" '
    function prot(p) {
      if (p in K) return 1
      return (p ~ /authenticator|\.auth\.|\.otp\.|twofactor|passkey|\.mfa\.|bluetooth|wearable|\.wear\.|watch|fitbit|garmin|amazfit|zepp|huami|health|truecaller|callerid|callblock|vpn|wireguard|\.clock|alarm|maps|navi|waze|^org\.telegram\.|^com\.whatsapp|^org\.thoughtcrime\.securesms|^im\.vector\.|^com\.viber\.|^com\.discord$|^com\.Slack$|^com\.microsoft\.teams|^com\.skype\.|^jp\.naver\.line\.|^com\.facebook\.orca$|^com\.kakao\.talk$|^com\.tencent\.mm$|^com\.wire$|^ch\.threema\.|^com\.google\.android\.gm$|^com\.microsoft\.office\.outlook$|\.mail|\.email|^com\.zoom\.|^us\.zoom\./)
    }
    { t = substr($0, 1, 2); r = substr($0, 3) }
    t == "I|" { n = split(r, f, "|")
      if (f[1] == "module" && n == 4) { mods[++nm] = f[2]; en[f[2]] = f[3]; cnt[f[2]] = f[4] }
      else if (f[1] == "scope" && n == 4) { sc[++ns] = f[2] "|" f[3] "|" f[4] }
      else if (r ~ /^reason=/) ir = substr(r, 8)
      next }
    t == "E|" { n = split(r, f, "|")
      if (r ~ /^at=/) eat = substr(r, 4) + 0
      else if (r == "us=ok") us = 1
      else if (f[1] == "i" && n == 3) { inst[f[2]] = f[3]; ni++ }
      else if (f[1] == "u" && n == 3) lu[f[2]] = f[3] + 0
      else if (f[1] == "c" && n == 4) cr[f[2] "|" f[3]] = f[4] + 0
      next }
    t == "L|" { n = split(r, f, " "); if (n == 4) { b = f[2] + f[3] - f[4]; if (b < f[2]) b = f[2]; bg[f[1]] = b; led = 1 } next }
    t == "K|" { K[r] = 1; next }
    t == "A|" { if (r ~ /^module=/) abm = substr(r, 8); else if (r ~ /^result=/) abr = substr(r, 8); next }
    END {
      upd = up / 86400; if (upd < 0.25) upd = 0.25
      for (i = 1; i <= ns; i++) {
        split(sc[i], f, "|"); m = f[1]; a = f[2]; u = f[3]
        apps[m]++
        if (a == "system" || a == "android") { fw[m] = 1; continue }
        if (a == "com.android.systemui") { su[m] = 1; continue }
        if (a == m || en[m] != 1) continue
        rate = led ? int((bg[a] + 0) / upd + 0.5) : -1
        if (rate > 0) bgt[m] += rate
        c = cr[m "|" a] + 0
        if (c > 0) crt[m] += c
        miss = (ni > 0 && !(a in inst))
        if (miss) continue
        unused = 0; idle = -1
        if (us) { idle = (a in lu) ? int((now - lu[a]) / 86400) : 9999; unused = (idle >= ud) }
        why = ""
        if (c >= 2) why = "crash"
        else if (unused && (rate < 0 || rate >= bgmin)) why = "unused"
        if (why == "") continue
        au = (why == "crash" && c >= cmin) || (why == "unused" && rate >= bgmin && !prot(a))
        if (why == "unused") uc[m]++
        printf "cand|%s|%s|%s|%s|%d|%d|%d|%d\n", m, a, u, why, rate, idle, c, au ? 1 : 0
      }
      for (i = 1; i <= nm; i++) {
        m = mods[i]; rs = ""
        if (crt[m] >= 2) rs = rs ",crash"
        if (fw[m]) rs = rs ",framework"
        if (su[m]) rs = rs ",systemui"
        if (apps[m] >= wide) rs = rs ",wide"
        if (bgt[m] >= bgh) rs = rs ",bgheavy"
        if (uc[m] > 0) rs = rs ",unused"
        if (abm == m && abr == "worse") rs = rs ",ab_worse"
        if (abm == m && abr == "neutral") rs = rs ",ab_neutral"
        v = "light"
        if (en[m] != 1) v = "off"
        else if (crt[m] >= cmin || (abm == m && abr == "worse")) v = "heavy"
        else if (rs != "" && rs != ",ab_neutral") v = "watch"
        reach = fw[m] ? "framework" : (su[m] ? "systemui" : "apps")
        printf "mod|%s|%d|%d|%s|%s|%s|%d|%d|%d\n", m, en[m], apps[m] + 0, reach, v, (rs == "" ? "-" : substr(rs, 2)), led ? bgt[m] + 0 : -1, uc[m] + 0, crt[m] + 0
      }
      printf "usage=%s\nledger=%d\n", us ? "ok" : "unknown", led
    }'
}
_pending() {
  _pw="$(cat "$WROTE" 2>/dev/null)"
  case "$_pw" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  _pu="$(_upsec)"
  case "$_pu" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$_pw" -gt $(( $(_now) - _pu )) ] && echo 1 || echo 0
}
_jid() { awk -F'|' '$1 ~ /^[0-9]+$/ && $1 > m { m = $1 } END { print m + 1 }' "$JOUR" 2>/dev/null; }
_journal() {
  mkdir -p "$D" 2>/dev/null
  _jn="$(_jid)"; [ -n "$_jn" ] || _jn=1
  printf '%s|%s|%s|%s|%s|%s|%s|%s|active\n' "$_jn" "$(_now)" "$1" "$2" "$3" "$4" "$5" "$6" >> "$JOUR"
  _now > "$WROTE"
  echo "$_jn"
}
_jstate() {
  awk -F'|' -v OFS='|' -v i="$1" -v s="$2" '$1 == i { $9 = s } { print }' "$JOUR" > "$JOUR.t" 2>/dev/null && mv -f "$JOUR.t" "$JOUR"
}
_drop() {
  _pkgok "$1" && _pkgok "$2" || return 2
  case "$2" in system|android|com.android.systemui|"$1") return 2 ;; esac
  _du="${4:-0}"
  case "$_du" in ''|*[!0-9]*) return 2 ;; esac
  _dr="$("$BIN" --lspd scope-del "$1" "$2" "$_du" "$DB" 2>/dev/null)"
  case "$_dr" in
    *result=removed*) _journal "$3" scope_del "$1" "$2" "$_du" 1 >/dev/null; _note "$3" scope_del "$1" "$2"; return 0 ;;
    *result=absent*) return 0 ;;
  esac
  return 1
}
_modset() {
  _pkgok "$1" || return 2
  _mr="$("$BIN" --lspd module-set "$1" "$2" "$DB" 2>/dev/null)"
  case "$_mr" in
    *result=ok*)
      _mb="$(printf '%s\n' "$_mr" | sed -n 's/^before=//p')"
      if [ "$_mb" != "$2" ]; then _journal "$3" "module_$( [ "$2" = 0 ] && echo off || echo on)" "$1" - 0 "$_mb" >/dev/null; _note "$3" "module_$( [ "$2" = 0 ] && echo off || echo on)" "$1" -; fi
      return 0 ;;
  esac
  return 1
}
_undo() {
  _ul="$(awk -F'|' -v i="$1" '$1 == i && $9 == "active"' "$JOUR" 2>/dev/null)"
  [ -n "$_ul" ] || return 1
  _ua="$(printf '%s' "$_ul" | cut -d'|' -f4)"; _um="$(printf '%s' "$_ul" | cut -d'|' -f5)"
  _up="$(printf '%s' "$_ul" | cut -d'|' -f6)"; _uu="$(printf '%s' "$_ul" | cut -d'|' -f7)"; _uv="$(printf '%s' "$_ul" | cut -d'|' -f8)"
  _pkgok "$_um" || return 1
  case "$_ua" in
    scope_del)
      _pkgok "$_up" || return 1
      _ur="$("$BIN" --lspd scope-add "$_um" "$_up" "$_uu" "$DB" 2>/dev/null)"
      case "$_ur" in *result=added*|*result=present*) ;; *) return 1 ;; esac ;;
    module_off|module_on)
      case "$_uv" in 0|1) ;; *) return 1 ;; esac
      _ur="$("$BIN" --lspd module-set "$_um" "$_uv" "$DB" 2>/dev/null)"
      case "$_ur" in *result=ok*) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  _jstate "$1" undone
  _now > "$WROTE"
  _note undo "$_ua" "$_um" "$_up"
  return 0
}
_trim() {
  _ti="$(_inv)"
  _tn=0
  for _tc in $(_assess "$_ti" | awk -F'|' -v m="$1" -v auto="$2" '$1 == "cand" && $2 == m && (auto == "" || $9 == 1) { print $3 "|" $4 }'); do
    _drop "$1" "${_tc%\|*}" "${3:-user}" "${_tc#*\|}" && _tn=$((_tn + 1))
  done
  echo "$_tn"
}
_auto_pass() {
  [ -f "$AUTO" ] || return 0
  _aa="$(cat "$AUTOAT" 2>/dev/null)"
  case "$_aa" in ''|*[!0-9]*) _aa=0 ;; esac
  [ $(( $(_now) - _aa )) -ge "$AUTO_EVERY" ] || return 0
  [ "$(_evid_age)" -ge 0 ] || return 0
  _now > "$AUTOAT"
  _pi="$(_inv)"
  for _pm in $(_assess "$_pi" | awk -F'|' '$1 == "cand" && $9 == 1 { print $2 }' | sort -u); do
    [ "$(_ab_get module)" = "$_pm" ] && continue
    _trim "$_pm" 1 auto >/dev/null
  done
}
_ab_get() { sed -n "s/^$1=//p" "$AB" 2>/dev/null | head -n 1; }
_ab_set() {
  mkdir -p "$D" 2>/dev/null
  { [ -f "$AB" ] && grep -v "^$1=" "$AB"; echo "$1=$2"; } > "$AB.t" 2>/dev/null && mv -f "$AB.t" "$AB"
}
_dm_sum() { awk 'NF >= 5 && $2 ~ /^[0-9]+$/ { a += $2; b += $3; c += $4; d += $5 } END { printf "%d %d %d %d\n", a, b, c, d }' "$DM" 2>/dev/null; }
_uids() {
  _ui="$(_inv)"
  { printf '%s\n' "$_ui" | sed 's/^/I|/'; [ -s "$EVID" ] && sed 's/^/E|/' "$EVID"; } | awk -v m="$1" '
    { t = substr($0, 1, 2); r = substr($0, 3); n = split(r, f, "|") }
    t == "I|" && f[1] == "scope" && f[2] == m { if (f[3] == "system" || f[3] == "android") U[1000] = 1; else A[f[3]] = 1 }
    t == "E|" && f[1] == "i" && n == 3 { I[f[2]] = f[3] }
    END { for (a in A) if (a in I) U[I[a] % 100000] = 1; for (u in U) printf "%s%s", (k++ ? "," : ""), u; print "" }'
}
_cpu_ms() {
  awk -v uids="$1" 'BEGIN { n = split(uids, a, ","); for (i = 1; i <= n; i++) W[a[i]] = 1 }
    { u = $1; sub(/:$/, "", u); if ((u % 100000) in W && $2 ~ /^[0-9]+$/) s += $2 + $3 }
    END { printf "%d\n", s / 1000 }' "$UIDCPU" 2>/dev/null
}
_ab_cpu_step() {
  _cb="$(_boot)"; _cv="$(_cpu_ms "$(_ab_get uids)")"
  case "$_cv" in ''|*[!0-9]*) return 0 ;; esac
  _cacc="$(_ab_get cpu_acc)"; _clast="$(_ab_get cpu_last)"; _cboot="$(_ab_get cpu_boot)"
  case "$_cacc" in ''|*[!0-9]*) _cacc=0 ;; esac
  case "$_clast" in ''|*[!0-9]*) _clast=0 ;; esac
  if [ "$_cb" = "$_cboot" ] && [ "$_cv" -ge "$_clast" ]; then _cacc=$((_cacc + _cv - _clast)); else _cacc=$((_cacc + _cv)); fi
  _ab_set cpu_acc "$_cacc"; _ab_set cpu_last "$_cv"; _ab_set cpu_boot "$_cb"
}
_ab_phase_start() {
  _ab_set phase "$1"; _ab_set t0 "$(_now)"; _ab_set dm0 "$(_dm_sum | tr ' ' ':')"
  _ab_set cpu_acc 0; _ab_set cpu_boot "$(_boot)"
  _cv0="$(_cpu_ms "$(_ab_get uids)")"; case "$_cv0" in ''|*[!0-9]*) _cv0=0 ;; esac
  _ab_set cpu_last "$_cv0"
}
_ab_finish_phase() {
  _ft0="$(_ab_get t0)"; _fd0="$(_ab_get dm0)"; _fd1="$(_dm_sum | tr ' ' ':')"
  _fh=$(( ($(_now) - _ft0) ))
  printf '%s %s %s %s\n' "$_fd0" "$_fd1" "$_fh" "$(_ab_get cpu_acc)" | awk -v offmin="$AB_OFF_S" -v onmin="$AB_ON_S" '{
    split($1, a, ":"); split($2, b, ":")
    on_s = b[1] - a[1]; on_x = b[2] - a[2]; off_s = b[3] - a[3]; off_x = b[4] - a[4]; el = $3; cpu = $4
    if (off_s < offmin || on_s < onmin) { print "short"; exit }
    if (el < 1) el = 1
    printf "%d %d %d %d %d\n", off_x * 3600 / off_s, on_x * 3600 / on_s, cpu * 3600 / el, off_s, on_s }'
}
_ab_tick() {
  _ap="$(_ab_get phase)"
  _am="$(_ab_get module)"
  case "$_ap" in
    a|b)
      _ab_cpu_step
      _at0="$(_ab_get t0)"; case "$_at0" in ''|*[!0-9]*) return 0 ;; esac
      _ael=$(( $(_now) - _at0 ))
      [ "$_ael" -ge $((AB_H * 3600)) ] || return 0
      _af="$(_ab_finish_phase)"
      if [ "$_af" = short ]; then
        if [ "$_ael" -ge $((AB_MAX_H * 3600)) ]; then
          [ "$_ap" = b ] && _ab_restore
          _ab_set phase aborted; _ab_set reason coverage; _note ab aborted "$_am" coverage
        fi
        return 0
      fi
      set -- $_af
      _ab_set "${_ap}_off" "$1"; _ab_set "${_ap}_on" "$2"; _ab_set "${_ap}_cpu" "$3"; _ab_set "${_ap}_off_s" "$4"; _ab_set "${_ap}_on_s" "$5"
      if [ "$_ap" = a ]; then
        _abj="$(_modset_ab "$_am" 0)"
        if [ -n "$_abj" ]; then
          _ab_set jid "$_abj"; _ab_set phase b_wait; _ab_set wboot "$(_boot)"; _note ab phase_b_wait "$_am" -
        else
          _ab_set phase aborted; _ab_set reason write_failed; _note ab aborted "$_am" write_failed
        fi
      else
        _ab_restore
        _ab_verdict
        _ab_set phase done; _ab_set wboot "$(_boot)"; _note ab done "$_am" "$(_ab_get result)"
      fi ;;
    b_wait)
      [ "$(_boot)" != "$(_ab_get wboot)" ] && { _ab_phase_start b; _note ab phase_b "$_am" -; } ;;
  esac
  return 0
}
_modset_ab() {
  _mr="$("$BIN" --lspd module-set "$1" "$2" "$DB" 2>/dev/null)"
  case "$_mr" in *result=ok*) ;; *) return 1 ;; esac
  _mb="$(printf '%s\n' "$_mr" | sed -n 's/^before=//p')"
  _journal ab module_off "$1" - 0 "$_mb"
}
_ab_restore() {
  _rj="$(_ab_get jid)"
  [ -n "$_rj" ] && _undo "$_rj"
  return 0
}
_ab_verdict() {
  _vr="$(awk -v ao="$(_ab_get a_off)" -v bo="$(_ab_get b_off)" -v an="$(_ab_get a_on)" -v bn="$(_ab_get b_on)" -v ac="$(_ab_get a_cpu)" -v bc="$(_ab_get b_cpu)" 'BEGIN {
    w = 0
    if (ao - bo >= 10 && ao >= bo * 1.15) w = 1
    if (an - bn >= 50 && an >= bn * 1.15) w = 1
    if (ac - bc >= 20000 && ac >= bc * 1.25) w = 1
    print w ? "worse" : "neutral" }')"
  _ab_set result "$_vr"
  [ "$(cat "$PROF" 2>/dev/null)" = "$(_ab_get prof)" ] || _ab_set profile_changed 1
}
_status() {
  echo 'version=1'
  [ -d "$LSPD" ] && echo 'lspd=1' || echo 'lspd=0'
  _si="$(_inv)"
  _sr="$(printf '%s\n' "$_si" | sed -n 's/^reason=//p' | head -n 1)"
  if printf '%s\n' "$_si" | grep -qx 'format=v1'; then echo 'database=ok'; else echo "database=${_sr:-unknown}"; fi
  [ -f "$AUTO" ] && echo 'auto=1' || echo 'auto=0'
  echo "pending_reboot=$(_pending)"
  echo "evidence_age=$(_evid_age)"
  [ -d "$LOCK" ] && echo 'refreshing=1' || echo 'refreshing=0'
  echo "unused_days=$UNUSED_D"
  _assess "$_si"
  [ -s "$JOUR" ] && tail -n 30 "$JOUR" | awk -F'|' 'NF == 9 { print "j|" $0 }'
  [ -s "$AB" ] && awk -F= 'NF == 2 && $1 ~ /^[a-z_0-9]+$/ && $2 ~ /^[A-Za-z0-9_.:,-]*$/ { print "ab|" $1 "|" $2 }' "$AB"
  [ -s "$EV" ] && tail -n 12 "$EV" | awk -F'|' 'NF == 5 { print "ev|" $0 }'
  return 0
}
_restore_all() {
  [ -s "$JOUR" ] && for _ri in $(awk -F'|' '$9 == "active" { print $1 }' "$JOUR" | sort -rn); do _undo "$_ri"; done
  rm -rf "$D" 2>/dev/null
}

case "${1:-status}" in
  status) _status ;;
  refresh)
    if [ "${ASB_LL_SYNC:-0}" = 1 ]; then _refresh; else MODDIR="$MODDIR" sh "$0" refresh-now >/dev/null 2>&1 & fi
    echo 'result=started' ;;
  refresh-now) _refresh ;;
  trim)
    _pkgok "${2:-}" || { echo 'result=bad_request'; exit 2; }
    [ "$(_ab_get module)" = "$2" ] && case "$(_ab_get phase)" in a|b_wait|b) echo 'result=busy_ab'; exit 0 ;; esac
    echo "trimmed=$(_trim "$2" "" user)"; echo 'result=ok' ;;
  drop)
    _pkgok "${2:-}" && _pkgok "${3:-}" || { echo 'result=bad_request'; exit 2; }
    _drop "$2" "$3" user "${4:-0}" && echo 'result=ok' || { echo 'result=failed'; exit 1; } ;;
  disable|enable)
    _pkgok "${2:-}" || { echo 'result=bad_request'; exit 2; }
    [ "$(_ab_get module)" = "$2" ] && case "$(_ab_get phase)" in a|b_wait|b) echo 'result=busy_ab'; exit 0 ;; esac
    _modset "$2" "$( [ "$1" = disable ] && echo 0 || echo 1)" user && echo 'result=ok' || { echo 'result=failed'; exit 1; } ;;
  undo)
    case "${2:-}" in ''|*[!0-9]*) echo 'result=bad_request'; exit 2 ;; esac
    _undo "$2" && echo 'result=ok' || { echo 'result=failed'; exit 1; } ;;
  undo-all)
    _un=0
    [ -s "$JOUR" ] && for _ri in $(awk -F'|' '$9 == "active" && $3 != "ab" { print $1 }' "$JOUR" | sort -rn); do _undo "$_ri" && _un=$((_un + 1)); done
    echo "undone=$_un"; echo 'result=ok' ;;
  auto)
    case "${2:-}" in
      on) mkdir -p "$D" 2>/dev/null; true > "$AUTO" && echo 'result=on' ;;
      off) rm -f "$AUTO" "$AUTOAT" 2>/dev/null; echo 'result=off' ;;
      *) echo 'result=bad_request'; exit 2 ;;
    esac ;;
  ab-start)
    _pkgok "${2:-}" || { echo 'result=bad_request'; exit 2; }
    case "$(_ab_get phase)" in a|b_wait|b) echo 'result=busy_ab'; exit 0 ;; esac
    printf '%s\n' "$(_inv)" | grep -qx "module|$2|1|[0-9]*" || { echo 'result=not_enabled'; exit 0; }
    rm -f "$AB" 2>/dev/null
    _ab_set module "$2"; _ab_set prof "$(cat "$PROF" 2>/dev/null)"; _ab_set uids "$(_uids "$2")"
    _ab_phase_start a; _note ab phase_a "$2" -
    echo 'result=started' ;;
  ab-stop)
    case "$(_ab_get phase)" in
      a|b_wait|b) _ab_restore; _ab_set phase aborted; _ab_set reason user; _note ab aborted "$(_ab_get module)" user; echo 'result=stopped' ;;
      *) rm -f "$AB" 2>/dev/null; echo 'result=cleared' ;;
    esac ;;
  tick)
    [ -d "$D" ] || exit 0
    _ab_tick
    _age="$(_evid_age)"
    if [ "$_age" -lt 0 ] || [ "$_age" -ge "$TTL" ]; then
      if [ "${ASB_LL_SYNC:-0}" = 1 ]; then _refresh; else MODDIR="$MODDIR" sh "$0" refresh-now >/dev/null 2>&1 & fi
    fi
    _auto_pass ;;
  restore-all) _restore_all ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
