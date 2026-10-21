#!/system/bin/sh
#
# asb_fullday_digest.sh - machine-readable digest of a 24h capture, for the WebUI report.
#
# The full-day recorder writes a rich but long report aimed at a developer reading a text
# file. The WebUI "Log report" sheet needs the same facts in a form it can render and
# explain in plain words, and it needs them fast: no dumpsys, no batterystats, only awk
# over files the recorder already wrote. This script is that projection.
#
# Output: TAB-separated lines, one fact per line:
#   meta     elapsed_min=<n>  target_h=<n>  running=0|1  started=<YYYY-MM-DD HH:MM>  profile=<name>
#   cover    on_min=<n>  off_min=<n>  on_pct=<n>
#   drain    pctph=<x.x>  total_drop=<n>  hours=<x.x>  ma=<n>
#   night    dur_min=<n>  drop=<n>  pctph=<x.x>  awake=<n>
#   idlemax  awake=<n>  phase=<name>  dur_min=<n>
#   jank     pct=<x.x>  jps=<x.x>  frames=<n>
#   japp     pkg=<package>  frames=<n>  pct=<x.x>      (up to 4 rows, most frames first)
#   hz       mode=<60|90|120|..>  share=<n>  ma=<n>    (one row per refresh rate)
#   asbcost  cpu_msh=<n>  writes_h=<n>  wakes_h=<n>
#   audio    spk_min=<n>  pctph=<x.x>  ma=<n>
#   charge   types=<Fast(17) N/A(197)>
#   smart    watching=<n>  testing=<n>  helped=<n>  nothelped=<n>  ctxlearn=<n>
#   cfg      key=<setting>  value=<v>                  (the settings the advice can point at)
#   wl       pkg=<package>  sec=<n>            (up to 5 rows, worst first)
#   wl       none=1                            (nothing recorded)
#   crash    count=<n>  asb=<n>  latest=<cmdline|none>
#   sysui    count=<n>
#   thermal  cpu=<n>  surf=<n>
#   throttle clamps=<n>  owner=<name|unknown>
#   radio    mib=<x.x>
#   error    no_capture                        (no capture directory found)
#
# Sections are emitted only when their source file exists, so a capture that just started
# yields meta alone - the caller treats that as "too early", not as a failure.
#
# Capture directory resolution, first match wins:
#   1. $1 / $ASB_LK_DIGEST_DIR       (explicit, used by tests)
#   2. the dir published in the WebUI launch lock (the RUNNING capture)
#   3. the newest asb_log_full_day_* under /sdcard, /storage/emulated/0, /data/local/tmp
# The lock wins over "newest dir" so a finished capture made AFTER a failed/aborted one
# never shadows the capture the user is actually running.

set -u

_STATE="${ASB_LK_STATE_DIR:-/data/adb/asb/logkit}"
_LOCK="${ASB_LK_LOCK:-$_STATE/full_day_webui.lock}"

_DIR="${1:-${ASB_LK_DIGEST_DIR:-}}"
if [ -z "$_DIR" ] && [ -f "$_LOCK/output_dir" ]; then
  _c="$(cat "$_LOCK/output_dir" 2>/dev/null)"
  if [ -n "$_c" ] && [ -d "$_c" ]; then _DIR="$_c"; fi
fi
if [ -z "$_DIR" ]; then
  for _b in /sdcard /storage/emulated/0 /data/local/tmp; do
    [ -d "$_b" ] || continue
    _c="$(ls -dt "$_b"/asb_log_full_day_* 2>/dev/null | head -n 1)"
    if [ -n "$_c" ]; then _DIR="$_c"; break; fi
  done
fi
if [ -z "$_DIR" ] || [ ! -d "$_DIR" ]; then
  printf 'error\tno_capture\n'
  exit 0
fi

# The open (still running) phase lives in .phase_open.tsv, appended by the interim report
# snapshot. Concatenating it after the committed ledger lets a live capture report the
# stretch it is in right now instead of ending at the last transition. Piped to each
# consumer, never written out: a scratch file inside the capture dir would get swept into
# the recorder's own hidden-artifact snapshot.
_LEDGER="$_DIR/phase_ledger.tsv"
_cat_ledger() {
  cat "$_LEDGER" 2>/dev/null
  [ -s "$_DIR/.phase_open.tsv" ] && cat "$_DIR/.phase_open.tsv" 2>/dev/null
  return 0
}
_HAVE_LEDGER=0
if [ -s "$_LEDGER" ] || [ -s "$_DIR/.phase_open.tsv" ]; then _HAVE_LEDGER=1; fi

# ----- meta -----------------------------------------------------------------
_el=""
_th=""
if [ -f "$_DIR/_full_day_report.txt" ]; then
  _hl="$(grep 'min elapsed' "$_DIR/_full_day_report.txt" 2>/dev/null | tail -n 1)"
  # " capture: 24h target, N min elapsed"
  _th="$(printf '%s\n' "$_hl" | sed -n 's/^ capture: \([0-9][0-9]*\)h target.*/\1/p')"
  _el="$(printf '%s\n' "$_hl" | sed -n 's/.*, \([0-9][0-9]*\) min elapsed.*/\1/p')"
fi
# No interim report yet (the first one lands after 15 minutes): derive the elapsed time
# from the first ledger row so the sheet can still say "recording, N min so far".
# (The ledger leads with a "# phase start end ..." comment - skip it.)
if [ -z "$_el" ] && [ "$_HAVE_LEDGER" = "1" ]; then
  _fs="$(_cat_ledger | awk -F'\t' '!/^#/ { print $2; exit }')"
  case "$_fs" in
    ''|*[!0-9]*) : ;;
    *) _el=$(( ($(date +%s) - _fs) / 60 )) ;;
  esac
fi
_running=0
if [ -f "$_LOCK/output_dir" ] && [ -f "$_LOCK/pid" ]; then
  _lod="$(cat "$_LOCK/output_dir" 2>/dev/null)"
  _lpid="$(cat "$_LOCK/pid" 2>/dev/null)"
  if [ "$_lod" = "$_DIR" ] && [ -n "$_lpid" ] && kill -0 "$_lpid" 2>/dev/null; then
    _running=1
  fi
fi
# fix200: when the capture started and under which profile, so the sheet can name a SAVED
# capture ("started 2026-10-20 23:10, smart") instead of pretending it is live.
_started=""
if [ "$_HAVE_LEDGER" = "1" ]; then
  _fs0="$(_cat_ledger | awk -F'\t' '!/^#/ { print $2; exit }')"
  case "$_fs0" in
    ''|*[!0-9]*) : ;;
    *) _started="$(date -d "@$_fs0" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$_fs0" '+%Y-%m-%d %H:%M' 2>/dev/null)" ;;
  esac
fi
_prof="$(sed -n 's/^current_profile:[[:space:]]*//p' "$_DIR/env.txt" 2>/dev/null | head -n 1 | tr -cd 'a-z')"
printf 'meta\telapsed_min=%s\ttarget_h=%s\trunning=%d\tstarted=%s\tprofile=%s\n' \
  "${_el:-0}" "${_th:-24}" "$_running" "${_started:-}" "${_prof:-}"

# ----- cover (screen on/off split, time-weighted) ---------------------------
# Same rule as the report writer: an interval counts as screen-on only when it started
# with the screen on and is no longer than five minutes - while suspended the recorder
# does not sample, so long gaps belong to screen-off time regardless.
if [ -s "$_DIR/battery_trace.txt" ]; then
  awk -F'|' '$1 ~ /^[0-9]+$/ {
      if (pe != "") { dt = $1 - pe; if (dt > 300 || ps != "1") off += dt; else on += dt }
      pe = $1; ps = $5
    } END {
      t = on + off
      if (t >= 600) printf "cover\ton_min=%d\toff_min=%d\ton_pct=%d\n", on / 60, off / 60, 100 * on / t
    }' "$_DIR/battery_trace.txt" 2>/dev/null
fi

# ----- drain (discharging phases only) --------------------------------------
# Charging rows have a negative drop and would cancel real drain out of the average.
# mA is the duration-weighted mean of the per-phase averages, reported only where the
# recorder itself trusted its sensor readings (it already blanks the unusable ones).
if [ "$_HAVE_LEDGER" = "1" ]; then
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    NF >= 5 {
      d = $4 - $5; dur = $3 - $2
      if (d > 0 && dur > 0) {
        drop += d; sec += dur
        if (($13 + 0) > 0) { ma += $13 * dur; maw += dur }
      }
    }
    END {
      if (sec > 0)
        printf "drain\tpctph=%.1f\ttotal_drop=%d\thours=%.1f\tma=%d\n", \
          drop * 3600 / sec, drop, sec / 3600, (maw > 0 ? ma / maw : 0)
    }' 2>/dev/null

  # ----- night (longest uninterrupted idle/sleep chain) ---------------------
  # Consecutive idle/sleep rows with at most two minutes between them are one stretch:
  # that is the number a user recognises as "how my phone did overnight". Reported only
  # from fifteen minutes up - shorter stretches say nothing about idle drain.
  _cat_ledger | awk -F'\t' '
    function flush() {
      if (in_c && cd > bd) { bd = cd; bdrop = cdrop; baw = (cawt > 0 ? caw / cawt : 0) }
    }
    /^#/ { next }
    $1 == "idle" || $1 == "sleep" {
      dur = $3 - $2
      if (in_c && ($2 - pe) <= 120) {
        cdrop += ($4 - $5); cd = $3 - cs
        if (dur > 0) { caw += $12 * dur; cawt += dur }
      } else {
        flush()
        in_c = 1; cs = $2; cd = $3 - $2; cdrop = ($4 - $5)
        caw = (dur > 0 ? $12 * dur : 0); cawt = (dur > 0 ? dur : 0)
      }
      pe = $3
      next
    }
    { flush(); in_c = 0 }
    END {
      flush()
      if (bd >= 900)
        printf "night\tdur_min=%d\tdrop=%d\tpctph=%.1f\tawake=%d\n", \
          bd / 60, bdrop, (bdrop > 0 ? bdrop * 3600 / bd : 0), baw
    }' 2>/dev/null

  # ----- idlemax (worst screen-off awake share) -----------------------------
  # awake% is the share of a screen-off phase the phone spent NOT in suspend. A high
  # value on a long phase is the classic "something keeps waking it" signal.
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    ($1 == "idle" || $1 == "sleep" || $1 == "gap") && ($3 - $2) >= 300 {
      if (($12 + 0) > mx) { mx = $12 + 0; mp = $1; md = $3 - $2 }
    }
    END {
      if (mx > 0) printf "idlemax\tawake=%d\tphase=%s\tdur_min=%d\n", mx, mp, md / 60
    }' 2>/dev/null

  # ----- thermal peaks -------------------------------------------------------
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    { if (($6 + 0) > c) c = $6 + 0; if (($7 + 0) > s) s = $7 + 0 }
    END { if (c > 0 || s > 0) printf "thermal\tcpu=%d\tsurf=%d\n", c, s }' 2>/dev/null

  # ----- radio traffic -------------------------------------------------------
  # Byte counters outgrow mksh 32-bit arithmetic, hence awk for the sum.
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    { rx += $14 + 0; tx += $15 + 0 }
    END { m = (rx + tx) / 1048576; if (m >= 0.1) printf "radio\tmib=%.1f\n", m }' 2>/dev/null
fi

# ----- wakelocks (top apps by held time) -------------------------------------
# Primary source: the per-uid delta the recorder maintains during the capture, mapped to
# package names. Fallback: the human report's own "top tag" table, so the sheet still has
# names for a capture made by an older recorder that never wrote the delta files.
_wl_out=""
if [ -s "$_DIR/.wl_uid_delta" ]; then
  _wl_out="$(awk -v MAP="$_DIR/.uid_package_map.tsv" '
      BEGIN { while ((getline l < MAP) > 0) { split(l, a, "|"); if (a[1] != "") pkg[a[1]] = a[2] } close(MAP) }
      NF >= 2 { s = $2 + 0; if (s > 0) { p = (($1) in pkg) ? pkg[$1] : "uid " $1; tot[p] += s } }
      END { for (p in tot) printf "%d\t%s\n", tot[p], p }
    ' "$_DIR/.wl_uid_delta" 2>/dev/null | sort -rn | head -n 5 | \
    awk -F'\t' '{ printf "wl\tpkg=%s\tsec=%d\n", $2, $1 }')"
fi
if [ -z "$_wl_out" ] && [ -f "$_DIR/_full_day_report.txt" ]; then
  _wl_out="$(awk '/^ *[0-9]+m [0-9]+s / {
      m = $1; sub(/m$/, "", m); s = $2; sub(/s$/, "", s)
      printf "%d\t%s\n", m * 60 + s, $3
    }' "$_DIR/_full_day_report.txt" 2>/dev/null | sort -rn | head -n 5 | \
    awk -F'\t' '{ printf "wl\tpkg=%s\tsec=%d\n", $2, $1 }')"
fi
if [ -n "$_wl_out" ]; then
  printf '%s\n' "$_wl_out"
else
  printf 'wl\tnone=1\n'
fi

# ----- native crashes inside the capture window ------------------------------
# Window start: the first ledger row, else derived from the elapsed time, else the last
# 24h - an old tombstone from before the capture must not count against it.
_start=""
if [ -s "$_LEDGER" ]; then
  _start="$(head -n 1 "$_LEDGER" 2>/dev/null | cut -f2)"
fi
case "$_start" in
  ''|*[!0-9]*)
    if [ -n "$_el" ]; then
      _start=$(( $(date +%s) - _el * 60 ))
    else
      _start=$(( $(date +%s) - 86400 ))
    fi ;;
esac
_tdir="${ASB_TOMBSTONE_DIR:-/data/tombstones}"
_cn=0; _ca=0; _cl=""; _clt=0
if [ -d "$_tdir" ]; then
  for _f in "$_tdir"/tombstone_[0-9][0-9]; do
    [ -f "$_f" ] || continue
    _mt="$(stat -c %Y "$_f" 2>/dev/null || date -r "$_f" +%s 2>/dev/null || echo 0)"
    case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
    [ "$_mt" -lt "$_start" ] && continue
    _cn=$((_cn + 1))
    if grep -q -e 'libasbdsp' -e 'asb_dsp_attach' -e 'AutoSystemBoost' -e '/data/adb/asb/' "$_f" 2>/dev/null; then
      _ca=$((_ca + 1))
    fi
    if [ "$_mt" -gt "$_clt" ]; then
      _clt="$_mt"
      _cl="$(grep -m1 '^Cmdline:' "$_f" 2>/dev/null | sed 's/^Cmdline:[ ]*//' | tr '\t' ' ' | cut -c1-40)"
    fi
  done
fi
printf 'crash\tcount=%d\tasb=%d\tlatest=%s\n' "$_cn" "$_ca" "${_cl:-none}"

# ----- SystemUI restarts ------------------------------------------------------
_sn=0
if [ -f "$_DIR/sysui_restarts.txt" ]; then
  _sn="$(grep -c '^===== SYSTEMUI RESTART' "$_DIR/sysui_restarts.txt" 2>/dev/null)"
fi
case "$_sn" in ''|*[!0-9]*) _sn=0 ;; esac
printf 'sysui\tcount=%d\n' "$_sn"

# ----- throttling periods -----------------------------------------------------
# A new period starts when the cap owner changes or the trace goes quiet for over three
# minutes (the throttle ended and later came back - two episodes, not one).
if [ -s "$_DIR/throttle_trace.txt" ]; then
  awk -F'|' '$1 ~ /^[0-9]+$/ {
      t = $1 + 0; o = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^cap_owner=/) { o = $i; sub(/^cap_owner=/, "", o) }
      if (NR == 1 || (t - pt) > 180 || o != po) n++
      pt = t; po = o; lo = o
    } END {
      if (n > 0) printf "throttle\tclamps=%d\towner=%s\n", n, (lo == "" ? "unknown" : lo)
    }' "$_DIR/throttle_trace.txt" 2>/dev/null
fi

# ----- report-derived facts (fix200) -------------------------------------------
# The interim/final human report already computed these; the sheet reuses its numbers
# instead of recomputing them. Every pattern tolerates a missing file or a missing table
# (a capture that just started writes its first interim report after fifteen minutes).
_RPT="$_DIR/_full_day_report.txt"
if [ -f "$_RPT" ]; then
  # UI smoothness headline: "all screen-on intervals: 167  frames 366481  janky 5.1%  ..."
  _jl="$(grep -m1 '^all screen-on intervals:' "$_RPT" 2>/dev/null)"
  if [ -n "$_jl" ]; then
    _jf="$(printf '%s\n' "$_jl" | sed -n 's/.*frames \([0-9][0-9]*\).*/\1/p')"
    _jp="$(printf '%s\n' "$_jl" | sed -n 's/.*janky \([0-9.][0-9.]*\)%.*/\1/p')"
    _js="$(sed -n 's/^janky frames per second on screen: \([0-9.]*\).*/\1/p' "$_RPT" 2>/dev/null | head -n 1)"
    if [ -n "$_jf" ] && [ -n "$_jp" ]; then
      printf 'jank\tpct=%s\tjps=%s\tframes=%s\n' "$_jp" "${_js:-0}" "$_jf"
    fi
  fi
  # Per-app jank, the "app in front" table: unindented rows of "pkg frames pct% jps",
  # most frames first, up to four. The indented per-interval table above it must not
  # match - its rows lead with two spaces.
  awk '/^app in front / { t = 1; next }
       t && $1 ~ /^[a-z0-9._]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+%$/ {
         if ($1 == "multi") next   # split-screen frames belong to no app
         p = $3; sub(/%$/, "", p)
         printf "japp\tpkg=%s\tframes=%s\tpct=%s\n", $1, $2, p
         n++; if (n >= 4) exit; next
       }
       t { exit }' "$_RPT" 2>/dev/null
  # Display refresh split: rows "60  112  64%  30  264" under the refresh_hz header.
  # The brightness table right below starts "0-24 ..." - the dash keeps it out.
  awk '/^refresh_hz[ \t]/ { t = 1; next }
       t && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+%$/ && $5 ~ /^[0-9]+$/ {
         s = $3; sub(/%$/, "", s)
         printf "hz\tmode=%s\tshare=%s\tma=%s\n", $1, s, $5; next
       }
       t { t = 0 }' "$_RPT" 2>/dev/null
  # ASB's own cost.
  _cc="$(sed -n 's/^  governor cpu[ ]*: \([0-9][0-9]*\) ms\/h.*/\1/p' "$_RPT" 2>/dev/null | head -n 1)"
  if [ -n "$_cc" ]; then
    _cw="$(sed -n 's/^  physical writes[ ]*: \([0-9][0-9]*\)\/h.*/\1/p' "$_RPT" 2>/dev/null | head -n 1)"
    _ck="$(sed -n 's/^  timer wakeups[ ]*: \([0-9][0-9]*\)\/h.*/\1/p' "$_RPT" 2>/dev/null | head -n 1)"
    printf 'asbcost\tcpu_msh=%s\twrites_h=%s\twakes_h=%s\n' "$_cc" "${_cw:-0}" "${_ck:-0}"
  fi
  # Speaker playback cost, from the phase table (the one whose header carries pct/h -
  # the "sampled current" table further down lists audio rows too, with mA in this
  # column, so the header match must be exact).
  awk '/^phase[ \t]+dur_min[ \t]+d_pct[ \t]+pct\/h/ { t = 1; next }
       t && $1 ~ /^[a-z_]+$/ && $2 ~ /^[0-9.]+$/ {
         if ($1 == "audio_spk_scr") {
           p = $4; sub(/[^0-9.].*$/, "", p); m = $5; sub(/[^0-9].*$/, "", m)
           printf "audio\tspk_min=%d\tpctph=%s\tma=%d\n", $2, p, m
         }
         next
       }
       t { exit }' "$_RPT" 2>/dev/null
  # Charging flavours seen.
  _ct="$(sed -n 's/^  charge types seen[ ]*: *//p' "$_RPT" 2>/dev/null | head -n 1 | tr '\t' ' ' | tr -s ' ' | sed 's/ $//')"
  [ -n "$_ct" ] && printf 'charge\ttypes=%s\n' "$_ct"
fi

# ----- Smart learner progress (fix200) ------------------------------------------
if [ -s "$_DIR/smart_records.txt" ]; then
  _sm="$(grep -m1 '^smooth|' "$_DIR/smart_records.txt" 2>/dev/null)"
  if [ -n "$_sm" ]; then
    _cl="$(awk -F'|' '$1 ~ /^(off_night|off_day|on_light_dim|on_light_bright|on_medium_dim|on_medium_bright)$/ && $2 != "measuring" { n++ } END { print n + 0 }' "$_DIR/smart_records.txt" 2>/dev/null)"
    printf 'smart\twatching=%s\ttesting=%s\thelped=%s\tnothelped=%s\tctxlearn=%s\n' \
      "$(printf '%s' "$_sm" | sed -n 's/.*watching=\([0-9]*\).*/\1/p')" \
      "$(printf '%s' "$_sm" | sed -n 's/.*|testing=\([0-9]*\).*/\1/p')" \
      "$(printf '%s' "$_sm" | sed -n 's/.*helped=\([0-9]*\).*/\1/p')" \
      "$(printf '%s' "$_sm" | sed -n 's/.*not_helped=\([0-9]*\).*/\1/p')" \
      "${_cl:-0}"
  fi
fi

# ----- the settings the advice can point at (fix200) -----------------------------
# Read from the CURRENT config, not the capture: a saved week's-old log should still give
# advice that matches the settings as they are now. The list is fixed; values are
# sanitized to one word.
_MD="$(CDPATH= cd -- "$(dirname "$0")/../.." 2>/dev/null && pwd)"
_CFG="${ASB_CFG_FILE:-$_MD/config/governor.conf}"
if [ -f "$_CFG" ]; then
  for _k in wakelock_action ltpo_video night_modem_idle net_screen_off_lte wifi_powersave gms_freeze doze_level; do
    _v="$(grep -E "^[[:space:]]*$_k=" "$_CFG" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \t\r')"
    [ -n "$_v" ] && printf 'cfg\tkey=%s\tvalue=%s\n' "$_k" "$_v"
  done
fi

exit 0
