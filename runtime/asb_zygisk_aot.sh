#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_ZA_DIR:-/data/adb/asb}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
ON="$D/zygisk_aot"
APPS="$D/zygisk_aot_apps"
CUM="$D/zygisk_aot_count"
LAUNCH="$D/zygisk_aot_launch"
SCAN="$D/zygisk_aot_scan"
LOG="$D/zygisk_aot_log"
LOCK="$D/zygisk_aot.lock"
CHARGE="$D/zygisk_aot_charge"
EXCL="$D/zygisk_aot_exclude"
CLASSES="${ASB_ZYGISK_CLASSES:-$MODDIR/zygisk/classes}"
POWER="${ASB_ZA_POWER:-/sys/class/power_supply/battery}"
BOOTID="${ASB_ZA_BOOTID:-/proc/sys/kernel/random/boot_id}"
TOP="${ASB_ZA_TOP:-8}"
MAXRUN="${ASB_ZA_MAX:-4}"
RETRY="${ASB_ZA_RETRY_S:-604800}"
REFRESH="${ASB_ZA_REFRESH_S:-21600}"
HOT="${ASB_ZA_HOT:-400}"
CTIME="${ASB_ZA_TIMEOUT:-900}"

_now() { date +%s 2>/dev/null || echo 0; }
_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) return 1 ;; *.*) return 0 ;; esac
  return 1
}
_gov_live() {
  _gp=""; read -r _gp < "${ASB_ZA_GOVPID:-/dev/.asb/governor.pid}" 2>/dev/null
  case "$_gp" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_gp" 2>/dev/null
}
_screen_off() {
  if _gov_live; then
    [ "$(grep -m1 '^screen=' "${ASB_ZA_STATE:-/dev/.asb/state}" 2>/dev/null | cut -d= -f2)" = 0 ]
    return
  fi
  case "$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//; s/[^A-Za-z].*//')" in
    Asleep|Dozing) return 0 ;;
  esac
  return 1
}
_charging() {
  case "$(tr -d ' \r\n' < "$POWER/status" 2>/dev/null)" in
    Charging|Full) return 0 ;;
  esac
  return 1
}
_cool() {
  _bt=""; [ -r "$POWER/temp" ] && _bt="$(tr -d ' \r\n' < "$POWER/temp" 2>/dev/null)"
  # Missing thermal evidence is not permission to compile on a charger.
  case "$_bt" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$_bt" -lt "$HOT" ]
}
_charge_session() {
  _cs_state=0; _charging && _cs_state=1
  _cs_boot="$(tr -d ' \r\n' < "$BOOTID" 2>/dev/null)"; _cs_boot="${_cs_boot:-unknown}"
  _cs_old="$(sed -n 's/^state=//p' "$CHARGE" 2>/dev/null | head -n 1)"
  _cs_oboot="$(sed -n 's/^boot=//p' "$CHARGE" 2>/dev/null | head -n 1)"
  _cs_batch="$(sed -n 's/^batch=//p' "$CHARGE" 2>/dev/null | head -n 1)"
  case "$_cs_batch" in 0|1) ;; *) _cs_batch=0 ;; esac
  if [ "$_cs_state" != "$_cs_old" ] || [ "$_cs_boot" != "$_cs_oboot" ]; then
    _cs_batch=0
    mkdir -p "$D" 2>/dev/null
    { echo "state=$_cs_state"; echo "batch=0"; echo "boot=$_cs_boot"; } > "$CHARGE.tmp" 2>/dev/null && mv -f "$CHARGE.tmp" "$CHARGE"
  fi
}
_charge_batch_consume() {
  [ "$_cs_state" = 1 ] && [ "$_cs_batch" = 0 ] || return 1
  { echo 'state=1'; echo 'batch=1'; echo "boot=$_cs_boot"; } > "$CHARGE.tmp" 2>/dev/null && mv -f "$CHARGE.tmp" "$CHARGE" || return 1
  _cs_batch=1
}
_running() {
  [ -d "$LOCK" ] || return 1
  _lp=""; read -r _lp < "$LOCK/pid" 2>/dev/null
  case "$_lp" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_lp" 2>/dev/null
}
_note() {
  mkdir -p "$D" 2>/dev/null
  { [ -f "$LOG" ] && tail -n 39 "$LOG"; printf '%s|%s|%s|%s\n' "$(_now)" "$1" "$2" "$3"; } > "$LOG.tmp" 2>/dev/null \
    && mv -f "$LOG.tmp" "$LOG"
}
_excluded() {
  [ -s "$EXCL" ] && grep -qxF "$1" "$EXCL" 2>/dev/null
}
_ledger_top() {
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ { t[$2] += $5 } END { for (p in t) if (t[p] > 0) print p, t[p] }'
}
_count_update() {
  _bid="$(tr -d ' \r\n' < "$BOOTID" 2>/dev/null)"
  _obid="$(sed -n '1s/^b //p' "$CUM" 2>/dev/null)"
  _same=0; [ -n "$_bid" ] && [ "$_bid" = "$_obid" ] && _same=1
  mkdir -p "$D" 2>/dev/null
  _ledger_top | awk -v same="$_same" -v bid="${_bid:-none}" -v cf="$CUM" '
    BEGIN {
      while ((getline ln < cf) > 0) {
        n = split(ln, f, " ")
        if (n == 3 && f[1] ~ /^[A-Za-z0-9_.]+$/) { tot[f[1]] = f[2] + 0; last[f[1]] = same ? f[3] + 0 : 0 }
      }
    }
    NF == 2 && $1 ~ /^[A-Za-z0-9_.]+$/ { c = $2 + 0; l = last[$1] + 0; d = (c >= l) ? c - l : c; tot[$1] += d; last[$1] = c }
    END { print "b " bid; for (p in tot) print p, tot[p] + 0, last[p] + 0 }' > "$CUM.tmp" 2>/dev/null || return 0
  { sed -n 1p "$CUM.tmp"; sed 1d "$CUM.tmp" | sort -k2,2nr | head -n 64; } > "$CUM.new" 2>/dev/null && mv -f "$CUM.new" "$CUM"
  rm -f "$CUM.tmp" 2>/dev/null
}
_launch_scan() {
  _since="$(sed -n 's/^scan=//p' "$SCAN" 2>/dev/null)"
  case "$_since" in ''|*[!0-9]*) _since=0 ;; esac
  _ev="$(logcat -b events -d -v epoch -s wm_activity_launch_time:I am_proc_start:I 2>/dev/null)"
  _new="$(printf '%s\n' "$_ev" | awk -v since="$_since" '
    {
      t = int($1 + 0); if (t <= since) next
      if (index($0, "am_proc_start: [")) {
        s = $0; sub(/.*am_proc_start: \[/, "", s); n = split(s, f, ",")
        if (n >= 5 && f[5] ~ /activity/) { p = f[4]; sub(/:.*/, "", p); ps[p] = t }
        next
      }
      if (index($0, "wm_activity_launch_time: [")) {
        s = $0; sub(/.*wm_activity_launch_time: \[/, "", s); sub(/\].*/, "", s); n = split(s, f, ",")
        if (n < 4) next
        p = f[3]; sub(/\/.*/, "", p); ms = f[n] + 0
        cold = ((p in ps) && t - ps[p] >= 0 && t - ps[p] <= 15) ? 1 : 0
        if (cold) delete ps[p]
        if (p ~ /^[A-Za-z0-9_.]+$/ && ms > 0 && ms < 60000) printf "%d|%s|%d|%d\n", t, p, ms, cold
      }
    }')"
  if [ -z "$_ev" ]; then
    _new="$(logcat -d -v epoch -s ActivityTaskManager:I ActivityManager:I 2>/dev/null | awk -v since="$_since" '
      {
        t = int($1 + 0); if (t <= since) next
        if (match($0, /Start proc [0-9]+:[A-Za-z0-9_.]+/) && $0 ~ /for [a-z-]*activity/) {
          s = substr($0, RSTART + 11, RLENGTH - 11); sub(/^[0-9]+:/, "", s); ps[s] = t; next
        }
        if (match($0, /Displayed [A-Za-z0-9_.]+\//)) {
          p = substr($0, RSTART + 10, RLENGTH - 11)
          if (!match($0, /: \+[0-9]+(s[0-9]+)?ms/) && !match($0, /: \+[0-9]+s/)) next
          v = substr($0, RSTART + 3, RLENGTH - 3); ms = 0
          if (v ~ /^[0-9]+s/) { split(v, q, "s"); ms = (q[1] + 0) * 1000 + (q[2] + 0) } else ms = v + 0
          cold = ((p in ps) && t - ps[p] >= 0 && t - ps[p] <= 15) ? 1 : 0
          if (cold) delete ps[p]
          if (ms > 0 && ms < 60000) printf "%d|%s|%d|%d\n", t, p, ms, cold
        }
      }')"
  fi
  mkdir -p "$D" 2>/dev/null
  if [ -n "$_new" ]; then
    { [ -f "$LAUNCH" ] && cat "$LAUNCH"; printf '%s\n' "$_new"; } | tail -n 400 > "$LAUNCH.tmp" 2>/dev/null && mv -f "$LAUNCH.tmp" "$LAUNCH"
    _last="$(printf '%s\n' "$_new" | tail -n 1 | cut -d'|' -f1)"
  else
    _last="$_since"
  fi
  printf 'scan=%s\nat=%s\n' "${_last:-0}" "$(_now)" > "$SCAN" 2>/dev/null
}
_filter() {
  _fx="$(dumpsys package "$1" 2>/dev/null | sed -n '/^Dexopt state:/,/^[^ ]/p')"
  case "$_fx" in *'[status='*) ;; *) _fx="$(pm art dump "$1" 2>/dev/null)" ;; esac
  printf '%s\n' "$_fx" | awk '
    /\[status=/ {
      s = $0; sub(/.*\[status=/, "", s); sub(/\].*/, "", s)
      r = "-"; if ($0 ~ /\[reason=/) { r = $0; sub(/.*\[reason=/, "", r); sub(/\].*/, "", r) }
      if (first == "") first = s " " r
      if ($0 ~ /primary-abi/) { print s " " r; done = 1; exit }
    }
    END { if (!done) print (first == "" ? "unknown -" : first) }'
}
_weak() {
  case "$1" in
    verify|quicken|extract|assume-verified|run-from-apk|run-from-apk-fallback|run-from-vdex-fallback|space|space-profile|error) return 0 ;;
  esac
  return 1
}
_strong() {
  case "$1" in speed-profile|speed|everything|everything-profile) return 0 ;; esac
  return 1
}
_ranked() {
  awk -v cf="$CUM" -v lf="$LAUNCH" -v kf="$CLASSES" -v xf="$EXCL" '
    BEGIN {
      while ((getline ln < xf) > 0) x[ln] = 1
      while ((getline ln < cf) > 0) { n = split(ln, f, " "); if (n == 3 && f[1] ~ /^[A-Za-z0-9_.]+$/) z[f[1]] = f[2] + 0 }
      while ((getline ln < lf) > 0) { n = split(ln, f, "|"); if (n == 4 && f[2] ~ /^[A-Za-z0-9_.]+$/) e[f[2]]++ }
      while ((getline ln < kf) > 0) if (ln ~ /^slow=[A-Za-z0-9_.]+$/) sl[substr(ln, 6)] = 1
      for (p in z) sc[p] = z[p]
      for (p in e) if (!(p in sc) || e[p] > sc[p]) sc[p] = e[p]
      for (p in sc) if (!(p in x)) print p, sc[p], (p in sl) ? 1 : 0
    }' | awk '$2 >= 2' | sort -k3,3nr -k2,2nr | head -n "$TOP" | awk '{ print $1, $2 }'
}
_refresh() {
  _rt="$(_now)"
  mkdir -p "$D" 2>/dev/null
  true > "$APPS.new" 2>/dev/null || return 0
  _ranked | while read -r _rp _rn; do
    _pkgok "$_rp" || continue
    _old="$(grep -m1 "^$_rp|" "$APPS" 2>/dev/null)"
    _fr="$(_filter "$_rp")"
    _f="${_fr%% *}"; _r="${_fr#* }"
    case "$_f" in ''|*[!a-z-]*) _f=unknown ;; esac
    case "$_r" in ''|*[!A-Za-z0-9_.-]*) _r=- ;; esac
    _tr="$(printf '%s' "$_old" | cut -d'|' -f6)"; _res="$(printf '%s' "$_old" | cut -d'|' -f7)"
    _ca="$(printf '%s' "$_old" | cut -d'|' -f8)"; _bf="$(printf '%s' "$_old" | cut -d'|' -f9)"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_rp" "$_rn" "$_f" "$_r" "$_rt" "${_tr:-0}" "${_res:--}" "${_ca:-0}" "${_bf:--}" >> "$APPS.new"
  done
  mv -f "$APPS.new" "$APPS" 2>/dev/null
}
_due() {
  [ -s "$APPS" ] || return 0
  _ck="$(head -n 1 "$APPS" | cut -d'|' -f5)"
  case "$_ck" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(_now) - _ck )) -ge "$REFRESH" ]
}
_candidates() {
  _cn="$(_now)"
  awk -F'|' -v now="$_cn" -v retry="$RETRY" -v xf="$EXCL" '
    BEGIN { while ((getline ln < xf) > 0) x[ln] = 1 }
    !($1 in x) && $3 ~ /^(verify|quicken|extract|assume-verified|run-from-apk|run-from-apk-fallback|run-from-vdex-fallback|space|space-profile|error)$/ && (now - $6 >= retry) { print $1 }' "$APPS" 2>/dev/null
}
_set_row() {
  awk -F'|' -v OFS='|' -v p="$1" -v f="$2" -v r="$3" -v tr="$4" -v res="$5" -v ca="$6" -v bf="$7" -v ck="$(_now)" '
    $1 == p { $3 = f; $4 = r; $5 = ck; $6 = tr; $7 = res; if (ca != "") $8 = ca; $9 = bf } { print }' "$APPS" > "$APPS.t" 2>/dev/null \
    && mv -f "$APPS.t" "$APPS"
}
_compile_run() {
  mkdir -p "$D" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    _running && return 0
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || return 0
  fi
  echo $$ > "$LOCK/pid"
  _done=0
  for _cp in $(_candidates); do
    [ "$_done" -lt "$MAXRUN" ] || break
    _pkgok "$_cp" || continue
    _excluded "$_cp" && continue
    [ -f "$ON" ] || break
    if ! _charging || ! _screen_off || ! _cool; then _note "$_cp" stopped -; break; fi
    _b="$(_filter "$_cp")"; _bf="${_b%% *}"
    if _strong "$_bf"; then _set_row "$_cp" "$_bf" "${_b#* }" "$(_now)" already "" "$_bf"; continue; fi
    if command -v timeout >/dev/null 2>&1; then
      _o="$(timeout "$CTIME" pm compile -r bg-dexopt "$_cp" 2>&1)"; _rc=$?
      case "$_o" in *Success*) ;; *) [ "$_rc" = 124 ] || { _o="$(timeout "$CTIME" pm compile -m speed-profile "$_cp" 2>&1)"; _rc=$?; } ;; esac
    else
      _o="$(pm compile -r bg-dexopt "$_cp" 2>&1)"; _rc=$?
      case "$_o" in *Success*) ;; *) _o="$(pm compile -m speed-profile "$_cp" 2>&1)"; _rc=$? ;; esac
    fi
    _a="$(_filter "$_cp")"; _af="${_a%% *}"
    _t="$(_now)"
    if _strong "$_af"; then
      _set_row "$_cp" "$_af" "${_a#* }" "$_t" compiled "$_t" "$_bf"; _note "$_cp" compiled "$_bf>$_af"
    elif [ "$_rc" = 124 ]; then
      _set_row "$_cp" "$_af" "${_a#* }" "$_t" timeout "" "$_bf"; _note "$_cp" timeout "$_bf"
    elif [ "$_af" = "$_bf" ]; then
      _set_row "$_cp" "$_af" "${_a#* }" "$_t" no_profile "" "$_bf"; _note "$_cp" no_profile "$_bf"
    else
      _set_row "$_cp" "$_af" "${_a#* }" "$_t" failed "" "$_bf"; _note "$_cp" failed "$_bf>$_af"
    fi
    _done=$((_done + 1))
  done
  rm -rf "$LOCK" 2>/dev/null
}
_asb_compiled() {
  [ "$(awk -F'|' -v p="$1" '$1 == p { print $7; exit }' "$APPS" 2>/dev/null)" = compiled ] && return 0
  [ -s "$LOG" ] && awk -F'|' -v p="$1" '$2 == p && $3 == "compiled" { f = 1 } END { exit !f }' "$LOG" 2>/dev/null
}
_reset() {
  _rb="$(_filter "$1")"; _rbf="${_rb%% *}"
  if command -v timeout >/dev/null 2>&1; then
    _ro="$(timeout "$CTIME" pm compile --reset "$1" 2>&1)"
  else
    _ro="$(pm compile --reset "$1" 2>&1)"
  fi
  _ra="$(_filter "$1")"; _raf="${_ra%% *}"
  case "$_rbf" in ''|*[!a-z-]*) _rbf=unknown ;; esac
  case "$_raf" in ''|*[!a-z-]*) _raf=unknown ;; esac
  case "$_ro" in
    *Success*) _note "$1" reset "$_rbf>$_raf"; echo 'reset=ok' ;;
    *) _note "$1" reset_failed "$_rbf>$_raf"; echo 'reset=failed' ;;
  esac
}
_exclude() {
  _pkgok "$1" || { echo 'result=bad_request'; return 2; }
  mkdir -p "$D" 2>/dev/null
  { [ -s "$EXCL" ] && grep -vxF "$1" "$EXCL"; echo "$1"; } | tail -n 64 > "$EXCL.tmp" 2>/dev/null && mv -f "$EXCL.tmp" "$EXCL" \
    || { rm -f "$EXCL.tmp" 2>/dev/null; echo 'result=failed'; return 1; }
  if ! _asb_compiled "$1"; then
    echo 'reset=skipped'
  elif [ "${ASB_ZA_SYNC:-0}" = 1 ]; then
    _reset "$1"
  else
    MODDIR="$MODDIR" sh "$0" reset "$1" >/dev/null 2>&1 &
    echo 'reset=started'
  fi
  if [ -f "$APPS" ]; then
    awk -F'|' -v p="$1" '$1 != p' "$APPS" > "$APPS.t" 2>/dev/null && mv -f "$APPS.t" "$APPS"
  fi
  echo 'result=excluded'
}
_include() {
  _pkgok "$1" || { echo 'result=bad_request'; return 2; }
  if [ -s "$EXCL" ]; then
    grep -vxF "$1" "$EXCL" > "$EXCL.tmp" 2>/dev/null
    if [ -s "$EXCL.tmp" ]; then mv -f "$EXCL.tmp" "$EXCL"; else rm -f "$EXCL.tmp" "$EXCL" 2>/dev/null; fi
  fi
  echo 'result=included'
}
_tick() {
  [ -f "$ON" ] || return 0
  _charge_session
  _sa="$(sed -n 's/^at=//p' "$SCAN" 2>/dev/null)"
  case "$_sa" in ''|*[!0-9]*) _sa=0 ;; esac
  if ! _screen_off || [ $(( $(_now) - _sa )) -ge 1800 ]; then _launch_scan; fi
  _count_update
  _due && _refresh
  _charging && _screen_off && _cool || return 0
  _running && return 0
  [ -n "$(_candidates)" ] || return 0
  [ "$_cs_batch" = 0 ] || return 0
  _charge_batch_consume || return 0
  if [ "${ASB_ZA_SYNC:-0}" = 1 ]; then _compile_run; else MODDIR="$MODDIR" sh "$0" compile-run >/dev/null 2>&1 & fi
}
_status() {
  echo 'version=1'
  [ -f "$ON" ] && echo 'enabled=1' || echo 'enabled=0'
  [ -n "$(cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '$1 == "L"' | head -1)" ] && echo 'ledger=1' || echo 'ledger=0'
  _charging && echo 'charging=1' || echo 'charging=0'
  _screen_off && echo 'screen=0' || echo 'screen=1'
  _running && echo 'running=1' || echo 'running=0'
  _csb="$(sed -n 's/^batch=//p' "$CHARGE" 2>/dev/null | head -n 1)"
  case "$_csb" in 0) echo 'last_charge_batch=available' ;; 1) echo 'last_charge_batch=used' ;; *) echo 'last_charge_batch=unknown' ;; esac
  _ck="$(head -n 1 "$APPS" 2>/dev/null | cut -d'|' -f5)"
  echo "checked=${_ck:-0}"
  _lc="$(grep -c '|' "$LAUNCH" 2>/dev/null)"
  echo "launches=${_lc:-0}"
  [ -s "$APPS" ] && awk -F'|' -v lf="$LAUNCH" '
    function med(p, lo, hi,   i, m, s, k, x, j) {
      delete w; delete u; m = 0
      for (i = 1; i <= cnt[p]; i++) if (tt[p, i] >= lo && tt[p, i] < hi) w[++m] = vv[p, i]
      s = (m > 15) ? m - 15 : 0; k = 0
      for (i = s + 1; i <= m; i++) u[++k] = w[i]
      for (i = 2; i <= k; i++) { x = u[i]; j = i - 1; while (j >= 1 && u[j] > x) { u[j + 1] = u[j]; j-- } u[j + 1] = x }
      if (k == 0) return "0|0"
      return k "|" ((k % 2) ? u[(k + 1) / 2] : int((u[k / 2] + u[k / 2 + 1]) / 2))
    }
    BEGIN {
      while ((getline ln < lf) > 0) {
        n = split(ln, f, "|")
        if (n == 4 && f[4] == 1) { c = ++cnt[f[2]]; tt[f[2], c] = f[1] + 0; vv[f[2], c] = f[3] + 0 }
      }
    }
    NF >= 9 && $1 ~ /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/ {
      ca = ($8 ~ /^[0-9]+$/) ? $8 + 0 : 0
      pre = (ca > 0) ? med($1, 0, ca) : "0|0"; post = (ca > 0) ? med($1, ca, 9999999999) : "0|0"
      printf "app|%s|%s|%s|%s|%s|%s|%d|%s|%s|%s|%s\n", $1, $2, $3, $4, ($6 == "" ? 0 : $6), ($7 == "" ? "-" : $7), ca, ($9 == "" ? "-" : $9), med($1, 0, 9999999999), pre, post
    }' "$APPS" 2>/dev/null
  [ -s "$EXCL" ] && while IFS= read -r _xp; do
    _pkgok "$_xp" && printf 'exclude|%s\n' "$_xp"
  done < "$EXCL"
  [ -s "$LOG" ] && tail -n 12 "$LOG" | while IFS='|' read -r _le _lp _lw _ld; do
    _pkgok "$_lp" && printf 'event|%s|%s|%s|%s\n' "$_le" "$_lp" "$_lw" "$_ld"
  done
  return 0
}

case "${1:-status}" in
  status) _status ;;
  enable) mkdir -p "$D" 2>/dev/null; true > "$ON" && { _launch_scan; _count_update; _refresh; echo 'result=enabled'; } ;;
  disable) rm -f "$ON" 2>/dev/null; echo 'result=disabled' ;;
  tick) _tick ;;
  scan) _launch_scan ;;
  compile-run) _compile_run ;;
  exclude) _exclude "${2:-}" || exit $? ;;
  include) _include "${2:-}" || exit $? ;;
  reset) _pkgok "${2:-}" || { echo 'result=bad_request'; exit 2; }; _reset "$2" ;;
  restore-all) rm -rf "$EXCL" "$EXCL.tmp" "$ON" "$APPS" "$APPS.new" "$APPS.t" "$CUM" "$CUM.tmp" "$CUM.new" "$LAUNCH" "$LAUNCH.tmp" "$SCAN" "$LOG" "$LOG.tmp" "$LOCK" "$CHARGE" "$CHARGE.tmp" 2>/dev/null ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
