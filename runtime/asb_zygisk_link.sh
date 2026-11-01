#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_ZL_DIR:-/data/adb/asb}"
RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
CLASSES="${ASB_ZYGISK_CLASSES:-$MODDIR/zygisk/classes}"
CONF="$MODDIR/config/governor.conf"
LAUNCH="$D/zygisk_aot_launch"
CUM="$D/zygisk_aot_count"
APPS="$D/zygisk_aot_apps"
ACT="$D/zygisk_guard_active"
GHOST="$D/zygisk_guard_ghost"
HIST="$D/zygisk_guard_hist"
NFL="$D/notif_fix"
KEEP="${ASB_DOZE_KEEP:-$D/doze_whitelist_keep}"
LSPMOD="$D/zygisk_lsposed_modules"
LSPD="${ASB_LSPD_DIR:-/data/adb/lspd}"
GOV="${ASB_GOV_BIN:-$MODDIR/bin/asb}"
MODS="${ASB_ZL_MODULES:-/data/adb/modules}"
GSTATE="${ASB_ZL_GOV_STATE:-/dev/.asb/state}"
SLOW="${ASB_ZL_SLOW_MS:-1000}"
FAST="${ASB_ZL_FAST_MS:-400}"
MINN="${ASB_ZL_MIN_COLD:-3}"
ROWS="${ASB_ZL_ROWS:-24}"

_cfg() {
  sed -n "s/^[[:space:]]*$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d ' \r'
}

NAMEOK='
    function ok(p, n) {
      n = length(p)
      if (n < 3 || n > 127 || p !~ /^[A-Za-z0-9_.]+$/ || p !~ /\./ || p ~ /^\./ || p ~ /\.$/ || p ~ /\.\./) return 0
      if (p ~ /^(system_server|zygote|zygote32|zygote64|com\.android\.systemui|com\.android\.packageinstaller|com\.android\.permissioncontroller|com\.android\.settings|com\.android\.phone|com\.android\.providers\.media|com\.android\.providers\.downloads|me\.weishu\.kernelsu|com\.rifsxd\.ksunext|com\.topjohnwu\.magisk|io\.github\.vvb2060\.magisk|org\.lsposed\.manager|com\.tsng\.hidemyapplist)$/) return 0
      if (p ~ /^(android\.|com\.android\.shell|com\.qualcomm\.|com\.qti\.|vendor\.|com\.oplus\.safecenter|com\.coloros\.safecenter|com\.heytap\.safecenter)/) return 0
      return 1
    }'

_names() {
  awk "$NAMEOK"' ok($1) { print }'
}

_hooks() {
  _hdb="$LSPD/config/modules_config.db"
  [ -f "$GOV" ] && [ -r "$_hdb" ] || return 0
  "$GOV" --lspd modules "$_hdb" 2>/dev/null | awk -F'|' '
    $1 == "module" && NF == 4 && $3 == 1 && $2 ~ /^[A-Za-z0-9_.]+$/ { on[$2] = 1 }
    $1 == "scope" && NF == 4 && $2 ~ /^[A-Za-z0-9_.]+$/ && $3 ~ /^[A-Za-z0-9_.]+$/ { sc[$3 " " $2] = 1 }
    END {
      for (m in on) print "M", m
      for (k in sc) { split(k, a, " "); if (a[2] in on) print "H", a[1], a[2] }
    }'
}

_evidence() {
  _hooks > "$1.hooks" 2>/dev/null
  awk -v lf="$LAUNCH" -v cf="$CUM" -v hf="$1.hooks" -v slow="$SLOW" -v fast="$FAST" -v minn="$MINN" "$NAMEOK"'
    BEGIN {
      while ((getline ln < hf) > 0) {
        n = split(ln, f, " ")
        if (f[1] == "H" && n == 3) { if (++hk[f[2]] <= 3) hm[f[2]] = hm[f[2]] (hm[f[2]] ? "," : "") f[3] }
      }
      while ((getline ln < lf) > 0) {
        n = split(ln, f, "|")
        if (n != 4 || f[2] !~ /^[A-Za-z0-9_.]+$/) continue
        use[f[2]]++
        if (f[4] == 1 && f[3] ~ /^[0-9]+$/) { c = ++cnt[f[2]]; v[f[2], c] = f[3] + 0 }
      }
      while ((getline ln < cf) > 0) {
        n = split(ln, f, " ")
        if (n == 3 && f[1] ~ /^[A-Za-z0-9_.]+$/ && f[2] + 0 > use[f[1]]) use[f[1]] = f[2] + 0
      }
      for (p in hk) all[p] = 1
      for (p in use) all[p] = 1
      for (p in all) {
        k = 0; s = (cnt[p] > 15) ? cnt[p] - 15 : 0
        for (i = s + 1; i <= cnt[p]; i++) u[++k] = v[p, i]
        for (i = 2; i <= k; i++) { x = u[i]; j = i - 1; while (j >= 1 && u[j] > x) { u[j + 1] = u[j]; j-- } u[j + 1] = x }
        md = 0
        if (k > 0) md = (k % 2) ? u[(k + 1) / 2] : int((u[k / 2] + u[k / 2 + 1]) / 2)
        cls = "normal"; why = "-"
        if (!ok(p)) why = "excluded"
        else if (k >= minn) {
          why = "measured"
          if (md >= slow) cls = "slow"; else if (md <= fast) cls = "fast"
        } else if (hk[p] > 0) { why = "hooks"; if (k >= 1 && md >= slow) cls = "slow" }
        printf "%s %s %s %d %d %d %d %s\n", p, cls, why, k, md, hk[p] + 0, use[p] + 0, (hm[p] ? hm[p] : "-")
      }
    }'
}

_classes() {
  _ce="$(_cfg zygisk_enabled)"; _cl="$(_cfg zygisk_launch)"
  _tmp="${CLASSES}.tmp"
  mkdir -p "$D" 2>/dev/null
  if [ "$1" != --no-scan ] && [ "$_ce" = 1 ] && [ "$_cl" = 1 ] && [ ! -f "$D/zygisk_aot" ] && [ -f "$MODDIR/runtime/asb_zygisk_aot.sh" ]; then
    MODDIR="$MODDIR" ASB_ZA_DIR="$D" sh "$MODDIR/runtime/asb_zygisk_aot.sh" scan >/dev/null 2>&1
  fi
  _evidence "$D/zygisk_link" > "$D/zygisk_link.ev" 2>/dev/null
  if [ -s "$D/zygisk_link.hooks" ]; then
    awk '$1 == "M" && $2 ~ /^[A-Za-z0-9_.]+$/ { print $2 }' "$D/zygisk_link.hooks" | sort -u > "$LSPMOD.tmp" 2>/dev/null
    if [ -s "$LSPMOD.tmp" ]; then mv -f "$LSPMOD.tmp" "$LSPMOD"; else rm -f "$LSPMOD.tmp" "$LSPMOD"; fi
  elif [ -f "$GOV" ] && [ -r "$LSPD/config/modules_config.db" ]; then
    rm -f "$LSPMOD" 2>/dev/null
  fi
  if [ "$_ce" != 1 ] || [ "$_cl" != 1 ] || [ -e "$D/zygisk_observer/disable" ] || [ ! -d "${CLASSES%/*}" ]; then
    rm -f "$CLASSES" "$_tmp" "$D/zygisk_link.ev" "$D/zygisk_link.hooks" 2>/dev/null
    echo 'result=absent slow=0 fast=0'
    return 0
  fi
  {
    echo 'v=1'
    awk '$2 == "slow" { print ($3 == "measured" ? 0 : 1), -$5, -$7, $1 }' "$D/zygisk_link.ev" | sort -k1,1n -k2,2n -k3,3n -k4,4 \
      | awk '{ print $4 }' | _names | head -n 64 | sed 's/^/slow=/'
    awk '$2 == "fast" { print -$7, $1 }' "$D/zygisk_link.ev" | sort -k1,1n -k2,2 \
      | awk '{ print $2 }' | _names | head -n 64 | sed 's/^/fast=/'
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp" "$D/zygisk_link.ev" "$D/zygisk_link.hooks"; echo 'result=write_failed'; return 1; }
  rm -f "$D/zygisk_link.ev" "$D/zygisk_link.hooks" 2>/dev/null
  _ns="$(grep -c '^slow=' "$_tmp")"; _nf="$(grep -c '^fast=' "$_tmp")"
  if [ "$_ns" = 0 ] && [ "$_nf" = 0 ]; then
    rm -f "$_tmp" "$CLASSES" 2>/dev/null
    echo 'result=absent slow=0 fast=0'
    return 0
  fi
  if cmp -s "$_tmp" "$CLASSES" 2>/dev/null; then
    rm -f "$_tmp"
    echo "result=unchanged slow=$_ns fast=$_nf"
    return 0
  fi
  chmod 644 "$_tmp" 2>/dev/null || true
  chcon u:object_r:system_file:s0 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$CLASSES" 2>/dev/null || { rm -f "$_tmp"; echo 'result=write_failed'; return 1; }
  echo "result=written slow=$_ns fast=$_nf"
}

_zmods() {
  _zn=0
  for _zm in "$MODS"/*; do
    [ -d "$_zm/zygisk" ] || continue
    _zid="${_zm##*/}"
    [ "$_zm" = "$MODDIR" ] && continue
    case "$_zid" in AutoSystemBoost|''|*[!A-Za-z0-9_.-]*) continue ;; esac
    ls "$_zm"/zygisk/*.so >/dev/null 2>&1 || continue
    [ "$_zn" -lt 24 ] || break
    _zon=1
    [ -e "$_zm/disable" ] || [ -e "$_zm/remove" ] && _zon=0
    _znm="$(sed -n 's/^name=//p' "$_zm/module.prop" 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9 ._()+-' | cut -c1-48)"
    printf 'zmod|%s|%s|%s\n' "$_zid" "$_zon" "${_znm:-$_zid}"
    _zn=$((_zn + 1))
  done
}

_rget() { grep -E "^$1=" "$2" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//' | tr -cd '0-9'; }

_status() {
  echo 'version=1'
  _se="$(_cfg zygisk_enabled)"; _sl="$(_cfg zygisk_launch)"; _sg="$(_cfg zygisk_ledger)"
  echo "launch=${_sl:-0}"
  echo "ledger=${_sg:-0}"
  echo "enabled=${_se:-0}"
  [ -f "$D/zygisk_guard" ] && echo "guard=$(head -n 1 "$D/zygisk_guard" 2>/dev/null | tr -cd 'a-z' | sed 's/^$/loops/')" || echo 'guard=off'
  [ -f "$D/zygisk_aot" ] && echo 'art=1' || echo 'art=0'
  _sc=absent; _ss=0; _sf=0; _sa=0
  if [ -s "$CLASSES" ]; then
    _sc=on
    _ss="$(grep -c '^slow=' "$CLASSES" 2>/dev/null)"; _sf="$(grep -c '^fast=' "$CLASSES" 2>/dev/null)"
    _sa="$(stat -c %Y "$CLASSES" 2>/dev/null | tr -cd '0-9')"
  fi
  echo "classes=$_sc"
  echo "classes_slow=${_ss:-0}"
  echo "classes_fast=${_sf:-0}"
  echo "classes_at=${_sa:-0}"
  cat "$RUN"/state.*.tsv 2>/dev/null | awk -F'\t' '
    $1 == "Z" && $3 ~ /^[0-9]+$/ && length($3) <= 12 {
      if ($2 == "launch_long") a += $3; else if ($2 == "launch_short") b += $3
      else if ($2 == "launch_class_fallback") c += $3; else if ($2 == "denylist_spawns") d += $3
      else if ($2 == "classes_loaded") e += $3
      if ($2 == "launch_long") v = 1
      if ($2 == "events_total") st = 1
    }
    END { printf "comp_state=%d\ncomp_supported=%d\ncomp_long=%d\ncomp_short=%d\ncomp_fallback=%d\ncomp_classes_loaded=%d\ndenylist_spawns=%d\n", st, v, a, b, c, e, d }'
  _gl="$(_rget zygisk_launch_long "$GSTATE")"; _gs="$(_rget zygisk_launch_short "$GSTATE")"
  _gcl="$(_rget unlock_cold_long "$GSTATE")"; _gct="$(_rget unlock_cold_trims "$GSTATE")"
  _gla="$(_rget zygisk_launch_accepted "$GSTATE")"
  echo "gov_launch=${_gla:--}"
  echo "gov_long=${_gl:--}"
  echo "gov_short=${_gs:--}"
  echo "gov_cold_long=${_gcl:--}"
  echo "gov_trims=${_gct:--}"
  _tmpd="${ASB_ZL_TMP:-/dev/.asb}"
  mkdir -p "$_tmpd" 2>/dev/null
  _evidence "$_tmpd/zygisk_link_st" > "$_tmpd/zygisk_link_st.ev" 2>/dev/null
  if [ -d "$LSPD" ]; then
    echo 'lsposed=1'
    if [ -s "$_tmpd/zygisk_link_st.hooks" ]; then
      awk '$1 == "M" { m++ } $1 == "H" { a[$2] = 1; if ($2 == "android" || $2 == "system") s[$3] = 1; if ($2 == "com.android.systemui") u[$3] = 1 }
        END { for (x in a) if (x != "android" && x != "system") n++; for (x in s) ns++; for (x in u) nu++
          printf "lsposed_modules=%d\nlsposed_apps=%d\nlsposed_system=%d\nlsposed_sysui=%d\n", m, n, ns, nu }' "$_tmpd/zygisk_link_st.hooks"
    elif [ -f "$GOV" ]; then
      echo 'lsposed_modules=0'
    else
      echo 'lsposed_modules=-'
    fi
  else
    echo 'lsposed=0'
  fi
  _zmods
  awk -v minn="$MINN" '$4 >= minn && $5 > 0 { if ($6 > 0) h[++nh] = $5; else q[++nq] = $5 }
    function med(a, n,   i, j, x) {
      for (i = 2; i <= n; i++) { x = a[i]; j = i - 1; while (j >= 1 && a[j] > x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
      return (n % 2) ? a[(n + 1) / 2] : int((a[n / 2] + a[n / 2 + 1]) / 2)
    }
    END { if (nh >= 2 && nq >= 2) printf "cmp|%d|%d|%d|%d\n", med(h, nh), nh, med(q, nq), nq }' "$_tmpd/zygisk_link_st.ev"
  awk -v cf="$CLASSES" -v act="$ACT" -v gh="$GHOST" -v hist="$HIST" -v apps="$APPS" -v nfl="$NFL" -v keep="$KEEP" -v lsm="$LSPMOD" -v rows="$ROWS" '
    BEGIN {
      while ((getline ln < cf) > 0) { if (ln ~ /^slow=/) eff[substr(ln, 6)] = "slow"; else if (ln ~ /^fast=/) eff[substr(ln, 6)] = "fast" }
      while ((getline ln < act) > 0) { n = split(ln, f, "|"); if (n >= 6) { g[f[1]] = (f[6] ~ /^[a-z_]+$/) ? f[6] : "loop"; pick[f[1]] = 1 } }
      while ((getline ln < gh) > 0) { n = split(ln, f, "|"); if (n >= 4) { g[f[1]] = "ghost"; pick[f[1]] = 1 } }
      first = 0
      while ((getline ln < hist) > 0) {
        n = split(ln, f, " ")
        if (f[1] == "b" && n >= 3) first = f[3] + 0
        else if (n >= 4 && f[1] ~ /^[A-Za-z0-9_.]+$/) { b = f[2] + f[3] - f[4]; bg[f[1]] = (b > 0) ? b : 0 }
      }
      while ((getline ln < apps) > 0) { n = split(ln, f, "|"); if (n >= 3 && f[3] ~ /^[a-z-]+$/) art[f[1]] = f[3] }
      while ((getline ln < nfl) > 0) { n = split(ln, f, "|"); if (f[1] != "") pr[f[1]] = "notif" }
      while ((getline ln < keep) > 0) { if (ln != "" && !(ln in pr)) pr[ln] = "keep" }
      while ((getline ln < lsm) > 0) { if (ln != "") mod[ln] = 1 }
      for (p in eff) pick[p] = 1
    }
    NF == 8 { ev[$1] = $0; if ($7 > 0 || ($1 in pick)) { sc[$1] = $7 + (($1 in pick) ? 1000000 : 0) } }
    END {
      for (p in pick) if (!(p in sc)) sc[p] = 1000000
      for (p in sc) print sc[p], p
      print "#"
      for (p in sc) {
        if (p in ev) { split(ev[p], e, " ") } else { e[2] = "normal"; e[3] = "-"; e[4] = 0; e[5] = 0; e[6] = 0; e[7] = 0; e[8] = "-" }
        printf "app|%s|%s|%s|%s|%d|%d|%d|%s|%d|%d|%s|%s|%s|%d\n", p, (p in eff) ? eff[p] : "normal", e[2], e[3], e[4], e[5], e[6], e[8],
          e[7], (p in bg) ? bg[p] : -1, (p in g) ? g[p] : "-", (p in art) ? art[p] : "-", (p in pr) ? pr[p] : "-", (p in mod) ? 1 : 0
      }
      if (first > 0) printf "hist_first=%d\n", first
    }' "$_tmpd/zygisk_link_st.ev" | awk -v rows="$ROWS" '
      $0 == "#" { split("", seen); hdr = 1; next }
      !hdr { r[$2] = $1; next }
      /^app\|/ { split($0, f, "|"); o[f[2]] = $0; next }
      { print }
      END {
        n = 0
        for (p in o) { k[++n] = p }
        for (i = 2; i <= n; i++) { x = k[i]; j = i - 1; while (j >= 1 && (r[k[j]] < r[x] || (r[k[j]] == r[x] && k[j] > x))) { k[j + 1] = k[j]; j-- } k[j + 1] = x }
        for (i = 1; i <= n && i <= rows; i++) print o[k[i]]
      }'
  rm -f "$_tmpd/zygisk_link_st.ev" "$_tmpd/zygisk_link_st.hooks" 2>/dev/null
  return 0
}

case "${1:-status}" in
  classes) _classes "${2:-}" ;;
  status) _status ;;
  restore-all) rm -f "$CLASSES" "$CLASSES.tmp" "$LSPMOD" "$LSPMOD.tmp" "$D/zygisk_link.ev" "$D/zygisk_link.hooks" 2>/dev/null; echo 'result=removed' ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
