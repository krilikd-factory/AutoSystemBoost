#!/system/bin/sh

_asb_lsp_hookre='LSPHooker_|de\.robv\.android\.xposed\.|org\.lsposed\.|XposedBridge|LSPlant|io\.github\.libxposed\.'

_asb_lsp_list() {
  printf '%s\n' "$1" | awk 'NF { printf "%s%s", (n++ ? " " : ""), $0 }'
}

_asb_lsp_uidmap() {
  command -v pm >/dev/null 2>&1 || return 0
  pm list packages -U 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.][A-Za-z0-9_.]*\) uid:\([0-9][0-9]*\).*/\2 \1/p'
}

_asb_lsp_logs() {
  for _lg_kind in modules verbose; do
    _lg_f="$(ls -t "$1"/log/"${_lg_kind}"_*.log 2>/dev/null | head -n 1)"
    [ -n "$_lg_f" ] && [ -s "$_lg_f" ] || continue
    printf '\001 %s\n' "$_lg_kind"
    tail -c 1048576 "$_lg_f" 2>/dev/null
    printf '\n'
  done
}

_asb_lsp_dropbox() {
  _db_to=''
  command -v timeout >/dev/null 2>&1 && _db_to='timeout 4'
  for _db_tag in data_app_crash system_app_crash data_app_anr; do
    printf '======== %s\n' "$_db_tag"
    $_db_to dumpsys dropbox -p "$_db_tag" 2>/dev/null | tail -c 600000
    printf '\n'
  done
}

_asb_lsp_join() {
  awk -v suf="$1" 'NF >= 2 { s = s (s ? ", " : "") $2 " " $1 suf } END { print (s ? s : "none") }'
}

_asb_lsposed_quick() {
  if [ -d "${ASB_LSPD_DIR:-$DATA/lspd}" ]; then
    _emit lsposed_hooks present 1
    _emit lsposed_hooks collection on_demand
  else
    _emit lsposed_hooks present 0
  fi
}

_asb_lsposed_info() {
  _ls_dir="${ASB_LSPD_DIR:-$DATA/lspd}"
  _ls_db="$_ls_dir/config/modules_config.db"
  _ls_bin="${ASB_GOV_BIN:-$MODDIR/bin/asb}"
  _ls_run="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
  _ls_basis='LSPosed exposes no per-hook call counts or energy: this joins its module/scope database, its own logs, Android crash records, process CPU and the Zygisk start ledger per hooked app (correlation, not attribution)'
  if [ ! -d "$_ls_dir" ]; then
    _emit lsposed_hooks present 0
    _emit lsposed_hooks basis "$_ls_basis"
    return 0
  fi
  _emit lsposed_hooks present 1

  _ls_inv=''
  _ls_state=no_governor
  if [ -f "$_ls_bin" ]; then
    _ls_inv="$("$_ls_bin" --lspd modules "$_ls_db" 2>/dev/null)"
    _ls_state="$(printf '%s\n' "$_ls_inv" | sed -n 's/^reason=//p' | head -n 1)"
    if [ -z "$_ls_state" ]; then
      if printf '%s\n' "$_ls_inv" | grep -qx 'format=v1'; then _ls_state=ok; else _ls_state=unknown; fi
    fi
  fi
  _emit lsposed_hooks database "$_ls_state"

  _ls_mods="$(printf '%s\n' "$_ls_inv" | awk -F'|' '$1 == "module" && $3 == 1 && NF == 4 { print $2 }')"
  _ls_modl="$(_asb_lsp_list "$_ls_mods")"
  _ls_scope="$(printf '%s\n' "$_ls_inv" | awk -F'|' -v on="$_ls_modl" '
    BEGIN { n = split(on, a, " "); for (i = 1; i <= n; i++) E[a[i]] = 1 }
    $1 == "scope" && NF == 4 && ($2 in E) { print $2 " " $3 }')"
  _ls_apps="$(printf '%s\n' "$_ls_scope" | awk 'NF == 2 && $2 != "system" && $2 != "android" { print $2 }' | sort -u)"
  _ls_appl="$(_asb_lsp_list "$_ls_apps")"
  if [ "$_ls_state" = ok ]; then
    _emit lsposed_hooks modules_enabled "$(printf '%s\n' "$_ls_mods" | awk 'NF { n++ } END { print n + 0 }')"
    _emit lsposed_hooks modules "$(printf '%s\n' "$_ls_scope" | awk 'NF == 2 { c[$1]++ } END { for (m in c) printf "%d %s\n", c[m], m }' \
      | sort -k1,1nr -k2,2 | head -n 8 | _asb_lsp_join ' targets')"
    _emit lsposed_hooks hooked_apps "$(printf '%s\n' "$_ls_apps" | awk 'NF { n++ } END { print n + 0 }')"
    _emit lsposed_hooks system_scope "$(printf '%s\n' "$_ls_scope" | awk '$2 == "system" || $2 == "android" || $2 == "com.android.systemui" {
        l[$1] = l[$1] (l[$1] ? "+" : "") $2 } END { for (m in l) printf "%s: %s\n", m, l[m] }' | sort \
      | awk 'NF { s = s (s ? ", " : "") $0 } END { print (s ? s : "none") }')"
    _emit lsposed_hooks multi_hooked "$(printf '%s\n' "$_ls_scope" | awk 'NF == 2 { c[$2]++ } END { for (a in c) if (c[a] >= 2) printf "%d %s\n", c[a], a }' \
      | sort -k1,1nr -k2,2 | head -n 8 | _asb_lsp_join ' modules')"
  fi

  _ls_found=0
  _ls_detail=''
  _ls_map="$(_asb_lsp_uidmap)"
  _ls_logs="$(_asb_lsp_logs "$_ls_dir")"
  if [ -n "$_ls_logs" ]; then
    _ls_lstat="$(printf '%s\n' "$_ls_logs" | awk -v mods="$_ls_modl" '
      function days(y, m, d) { if (m <= 2) { y--; m += 12 } return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d }
      function secs(t) {
        if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return -1
        return days(substr(t, 1, 4) + 0, substr(t, 6, 2) + 0, substr(t, 9, 2) + 0) * 86400 + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
      }
      BEGIN { nm = split(mods, M, " "); fi = 0; T0 = secs("2015-01-01T00:00:00") }
      substr($0, 1, 1) == "\001" { fi++; cur = ""; next }
      {
        if (substr($0, 1, 1) == "[") {
          n = split($0, f, " "); uid = ""; pri = ""; ts = -1
          for (i = 1; i <= n; i++) {
            if (ts < 0) { if ((s = secs(f[i])) >= 0) { ts = s; if (i < n) { split(f[i + 1], uu, ":"); uid = uu[1] } } }
            else if (pri == "" && f[i] ~ /^[VDIWEF]\//) pri = substr(f[i], 1, 1)
          }
          if (ts < 0) { if (cur == "") next }
          else {
            cur = (uid ~ /^[0-9]+$/) ? uid % 100000 : "?"
            err = (pri == "E" || pri == "F" || (pri == "W" && $0 ~ /Exception|Throwable|Error:/))
            if (err) E[cur]++
            if (ts >= T0) {
              if ((fi in HI) && (ts > HI[fi] + 21600 || ts < LS[fi] - 3600)) {
                delete LO[fi]; delete HI[fi]
                for (k in BF) { split(k, kk, SUBSEP); if (kk[1] == fi) delete BF[k] }
              }
              if (!(fi in LO) || ts < LO[fi]) LO[fi] = ts
              if (!(fi in HI) || ts > HI[fi]) HI[fi] = ts
              LS[fi] = ts
            }
            split("", seen)
          }
        } else if (cur == "") next
        BF[fi, cur] += length($0) + 1; BT[fi, cur] += length($0) + 1; U[cur] = 1
        if (err) for (i = 1; i <= nm; i++) if (!(M[i] in seen) && index($0, M[i] ".")) { R[M[i]]++; seen[M[i]] = 1 }
      }
      END {
        w = -1; tr = 0; ok = 0
        for (k in BT) { split(k, kk, SUBSEP); tb[kk[2]] += BT[k] }
        for (k in BF) {
          split(k, kk, SUBSEP); x = kk[1]; u = kk[2]
          if ((x in LO) && HI[x] - LO[x] >= 60) { rr = BF[k] * 3600 / (HI[x] - LO[x]); RU[u] += rr; tr += rr; ok = 1 }
        }
        for (x in LO) if (HI[x] - LO[x] > w) w = HI[x] - LO[x]
        printf "W %d %d\n", w, ok ? int(tr / 1024) : -1
        for (u in U) printf "U %s %d %d %d\n", u, tb[u], E[u] + 0, ok ? int(RU[u] / 1024) : -1
        for (m in R) printf "M %s %d\n", m, R[m]
      }')"
    _ls_win="$(printf '%s\n' "$_ls_lstat" | awk '$1 == "W" { print $2; exit }')"
    _ls_rate="$(printf '%s\n' "$_ls_lstat" | awk '$1 == "W" { print $3; exit }')"
    case "$_ls_win" in ''|-*|*[!0-9]*) _ls_win=-1 ;; esac
    case "$_ls_rate" in ''|-*|*[!0-9]*) _ls_rate=-1 ;; esac
    if [ "$_ls_win" -ge 60 ] && [ "$_ls_rate" -ge 0 ]; then
      _emit lsposed_hooks log_window_min $((_ls_win / 60))
      _emit lsposed_hooks log_rate_kb_h "$_ls_rate"
    else
      _emit lsposed_hooks log_window_min unknown
      _emit lsposed_hooks log_rate_kb_h unknown
    fi
    _ls_top="$(printf '%s\n' "$_ls_lstat" | awk -v map="$_ls_map" '
      BEGIN { n = split(map, a, "\n"); for (i = 1; i <= n; i++) if (split(a[i], b, " ") == 2 && !(b[1] in P)) P[b[1]] = b[2] }
      $1 == "U" && NF == 5 { u = $2; name = (u in P) ? P[u] : (u == "1000" ? "system" : (u == "?" ? "unattributed" : "uid_" u))
        printf "%d %s %d %d\n", $3, name, $4, $5 }' | sort -k1,1nr -k2,2 | head -n 5)"
    _emit lsposed_hooks log_top "$(printf '%s\n' "$_ls_top" | awk 'NF == 4 { s = s (s ? ", " : "") $2 " " int($1 / 1024) " KB" ($4 >= 0 ? " (" $4 " KB/h)" : "") ", " $3 " errors" } END { print (s ? s : "none") }')"
    for _ls_x in $(printf '%s\n' "$_ls_top" | awk 'NF == 4 && $4 >= 512 && $2 != "unattributed" { print $2 }'); do
      _ls_found=$((_ls_found + 1)); _ls_detail="$_ls_detail log_spam:$_ls_x"
    done
    _emit lsposed_hooks error_modules "$(printf '%s\n' "$_ls_lstat" | awk '$1 == "M" && NF == 3 { printf "%d %s\n", $3, $2 }' \
      | sort -k1,1nr -k2,2 | head -n 5 | _asb_lsp_join '')"
    for _ls_x in $(printf '%s\n' "$_ls_lstat" | awk '$1 == "M" && NF == 3 && $3 >= 20 { print $2 }' | sort); do
      _ls_found=$((_ls_found + 1)); _ls_detail="$_ls_detail errors:$_ls_x"
    done
  else
    _emit lsposed_hooks log_window_min unknown
    _emit lsposed_hooks log_rate_kb_h unknown
    _emit lsposed_hooks log_top 'no current log'
    _emit lsposed_hooks error_modules unknown
  fi

  if command -v dumpsys >/dev/null 2>&1; then
    _ls_crash="$(_asb_lsp_dropbox | awk -v re="$_asb_lsp_hookre" -v mods="$_ls_modl" '
      BEGIN { nm = split(mods, M, " ") }
      function flush(   m) {
        if (proc != "" && hook) { C[proc]++; for (m in got) if (index("+" G[proc] "+", "+" m "+") == 0) G[proc] = G[proc] (G[proc] != "" ? "+" : "") m }
        proc = ""; hook = 0; split("", got)
      }
      /^========/ { flush(); next }
      /^Process: / { proc = $2; next }
      $0 ~ re { hook = 1 }
      /^[[:space:]]*at / { for (i = 1; i <= nm; i++) if (index($0, M[i] ".")) got[M[i]] = 1 }
      END { flush(); for (p in C) printf "%d %s %s\n", C[p], p, (G[p] != "" ? G[p] : "-") }' | sort -k1,1nr -k2,2 | head -n 5)"
    _emit lsposed_hooks crash_hooked "$(printf '%s\n' "$_ls_crash" | awk 'NF == 3 { s = s (s ? ", " : "") $2 " x" $1 ($3 != "-" ? " (" $3 ")" : "") } END { print (s ? s : "none") }')"
    for _ls_x in $(printf '%s\n' "$_ls_crash" | awk 'NF == 3 { print $2 }'); do
      _ls_found=$((_ls_found + 1)); _ls_detail="$_ls_detail crash:$_ls_x"
    done
  else
    _emit lsposed_hooks crash_hooked unknown
  fi

  if [ -n "$_ls_appl" ]; then
    _ls_ps="$(ps -A -o UID,TIME,NAME 2>/dev/null)"
    if [ -n "$_ls_ps" ] && [ -n "$_ls_map" ]; then
      _emit lsposed_hooks cpu_hooked_top "$(printf '%s\n' "$_ls_ps" | awk -v map="$_ls_map" -v apps="$_ls_appl" '
        BEGIN { n = split(map, a, "\n"); for (i = 1; i <= n; i++) if (split(a[i], b, " ") == 2) P[b[1]] = b[2]
                k = split(apps, x, " "); for (i = 1; i <= k; i++) H[x[i]] = 1 }
        $1 ~ /^[0-9]+$/ {
          u = $1 % 100000; if (!(u in P) || !(P[u] in H)) next
          t = $2; d = 0
          if (index(t, "-")) { split(t, dd, "-"); d = dd[1]; t = dd[2] }
          if (t !~ /^[0-9:]+$/) next
          c = split(t, p, ":"); s = 0; for (i = 1; i <= c; i++) s = s * 60 + p[i]
          S[P[u]] += s + d * 86400 }
        END { for (q in S) if (S[q] > 0) printf "%d %s\n", S[q], q }' | sort -k1,1nr -k2,2 | head -n 5 | _asb_lsp_join ' s')"
    else
      _emit lsposed_hooks cpu_hooked_top 'not exposed'
    fi
    _ls_led=''
    for _ls_f in "$_ls_run/state.arm64-v8a.tsv" "$_ls_run/state.armeabi-v7a.tsv"; do
      [ -r "$_ls_f" ] || continue
      _ls_led="$_ls_led$(awk -F'\t' '$1 == "L" && NF >= 5 && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $3, $4, ((NF >= 6 && $6 ~ /^[0-9]+$/) ? $6 : 0) }' "$_ls_f" 2>/dev/null)
"
    done
    if [ -n "$(printf '%s' "$_ls_led" | tr -d '\n')" ]; then
      _ls_churn="$(printf '%s\n' "$_ls_led" | awk -v apps="$_ls_appl" '
        BEGIN { k = split(apps, x, " "); for (i = 1; i <= k; i++) H[x[i]] = 1 }
        NF == 4 && ($1 in H) { off[$1] += $2; on[$1] += $3; if ($4 + 0 > b[$1]) b[$1] = $4 + 0 }
        END { for (p in off) if (off[p] > 0) printf "%d %d %d %s\n", off[p], on[p], b[p], p }' | sort -k1,1nr -k4,4 | head -n 5)"
      _emit lsposed_hooks churn_hooked_top "$(printf '%s\n' "$_ls_churn" | awk 'NF == 4 { s = s (s ? ", " : "") $4 " " $1 "/" $2 (($3 >= 6) ? " burst " $3 "/5min" : "") } END { print (s ? s : "none") }')"
      for _ls_x in $(printf '%s\n' "$_ls_churn" | awk 'NF == 4 && $3 >= 6 { print $4 }'); do
        _ls_found=$((_ls_found + 1)); _ls_detail="$_ls_detail loop:$_ls_x"
      done
    else
      _emit lsposed_hooks churn_hooked_top 'no ledger data'
    fi
  fi
  _emit lsposed_hooks findings "$_ls_found"
  _emit lsposed_hooks findings_detail "${_ls_detail# }"
  _emit lsposed_hooks basis "$_ls_basis"
}
