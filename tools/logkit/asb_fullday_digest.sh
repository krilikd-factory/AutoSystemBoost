#!/system/bin/sh
#
# asb_fullday_digest.sh - machine-readable digest of a session capture, for the WebUI report.
#
# The full-day recorder writes a rich but long report aimed at a developer reading a text
# file. The WebUI "Log report" sheet needs the same facts in a form it can render and
# explain in plain words, and it needs them fast: no dumpsys, no batterystats, only awk
# over files the recorder already wrote. This script is that projection.
#
# Output: TAB-separated lines, one fact per line:
#   meta     elapsed_min=<n>  target_h=<n>  running=0|1  started=<YYYY-MM-DD HH:MM>  profile=<name>
#   meta2    model=<m>  device=<codename>  soc=<soc>  rom=<build>  mod=<build>   (fix213)
#   capture  dir=<absolute capture path>             (report.json export target, fix225)
#   cover    on_min=<n>  off_min=<n>  on_pct=<n>
#   drain    pctph=<x.x>  total_drop=<n>  hours=<x.x>  ma=<n>
#   night    dur_min=<n>  drop=<n>  pctph=<x.x>  awake=<n>
#   nightd   ma=<n>  radio_mib=<x.x>  cpu_t=<n>  skin_t=<n>  wake_pk=<n>
#   idlemax  awake=<n>  phase=<name>  dur_min=<n>
#   jank     pct=<x.x>  jps=<x.x>  frames=<n>
#   japp     pkg=<package>  frames=<n>  pct=<x.x>      (up to 4 rows, most frames first)
#   jwake    wakes=<n>  pct=<x.x>  ord=<x.x>  frames=<n>  top=<pkg>  top_pct=<x.x>   (fix220)
#   jphase   phase=<name>  intv=<n>  frames=<n>  pct=<x.x>  jps=<x.xx>               (fix220)
#   jstate   state=<name>  intv=<n>  frames=<n>  pct=<x.x>  jps=<x.xx>               (fix220)
#   hz       mode=<60|90|120|..>  share=<n>  ma=<n>    (one row per refresh rate)
#   asbcost  cpu_msh=<n>  writes_h=<n>  wakes_h=<n>
#   gauge    factor=<x.xx>  windows=<n>  mult=<x.x>    (current_now vs SOC, fix220)
#   audio    spk_min=<n>  pctph=<x.x>  ma=<n>
#   charge   types=<Fast(17) N/A(197)>
#   smart    watching=<n>  testing=<n>  helped=<n>  nothelped=<n>  ctxlearn=<n>
#   mwake    n=<n>  per_night=<x.x>  typical_s=<n>     (night habits, fix213)
#   cfg      key=<setting>  value=<v>                  (the settings the advice can point at)
#   wl       pkg=<package>  sec=<n>            (up to 5 rows, worst first)
#   wl       none=1                            (nothing recorded)
#   wlive    tag=<cleaned tag>  pct=<n>  min=<n>  pkg=<package|''>   (up to 3 rows)
#   wlt      tag=<wakelock tag>  n=<count>      (top 5 partial holders by occurrence, n>=3)
#   wla      tag=<alarm source>  n=<count>      (top 4 alarm/wakeup sources, n>=2)
#   sradio   mib=<x.x>                          (idle/sleep mobile traffic, screen off)
#   kwk      tag=<kernel wakelock>  min=<n>      (up to 3 rows, holders on the charger)
#   prof     name=<profile>  on_min=<n>  off_min=<n>  on_pctph=<x.x>  off_pctph=<x.x>
#   scr      on_pctph=<x.x>  off_pctph=<x.x>  on_min=<n>  off_min=<n>
#   phase    name=<p>  min=<n>  drop=<signed n>  pctph=<x.x>   (up to 10 rows, longest first)
#   chg      min=<n>  gain=<n>  sess=<n>
#   ltpo     n=<n>  min=<n>
#   aod      lit=<n>  of=<n>
#   crash    count=<n>  asb=<n>  latest=<cmdline|none>  ltime=<HH:MM>
#   sysui    count=<n>
#   thermal  cpu=<n>  surf=<n>
#   heat     peak_phase=<name>  peak_c=<n>  warm_min=<n>  skin_min=<n>   (durations hot, fix213; peak_c fix218)
#   throttle clamps=<n>  owner=<dominant>  by=<owner:n,...>   (per-owner split, fix219)
#   radio    mib=<x.x>
#   hist     started=<...>  night=<x.x>  drain=<x.x>  jank=<x.x>  cpu=<n>  clamps=<n>
#            device=<codename> rom=<build> mod=<build> elapsed=<n> on_pct=<n> off_min=<n>
#            (up to 3 earlier finished captures, newest first; six-field legacy rows remain
#             readable but are not comparable; context fields were added in fix225)
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
  # " capture: 24h target, N min elapsed" or "capture: 0h target (until shutdown), N min elapsed"
  _th="$(printf '%s\n' "$_hl" | sed -n 's/^ capture: \([0-9][0-9]*\)h target.*/\1/p')"
  _el="$(printf '%s\n' "$_hl" | sed -n 's/.*, \([0-9][0-9]*\) min elapsed.*/\1/p')"
fi
# fix214: while the capture runs, the elapsed time comes from the ledger and the clock,
# not from the interim report. The interim line is rewritten every fifteen minutes, so
# between writes it read "15 min" while the live sections right below (computed fresh
# from the traces) already showed 24 - one sheet disagreeing with itself.
# (The ledger leads with a "# phase start end ..." comment - skip it.)
if [ "$_HAVE_LEDGER" = "1" ]; then
  _fs="$(_cat_ledger | awk -F'\t' '!/^#/ { print $2; exit }')"
  case "$_fs" in
    ''|*[!0-9]*) : ;;
    *) _el_live=$(( ($(date +%s) - _fs) / 60 ))
       # A finished capture keeps the report-writer number; a running one goes live.
       if [ -f "$_LOCK/output_dir" ] && [ -f "$_LOCK/pid" ]; then
         _lod0="$(cat "$_LOCK/output_dir" 2>/dev/null)"; _lpid0="$(cat "$_LOCK/pid" 2>/dev/null)"
         if [ "$_lod0" = "$_DIR" ] && [ -n "$_lpid0" ] && kill -0 "$_lpid0" 2>/dev/null; then
           _el="$_el_live"
         fi
       fi
       [ -z "$_el" ] && _el="$_el_live" ;;
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
  "${_el:-0}" "${_th:-0}" "$_running" "${_started:-}" "${_prof:-}"
# The structured report export belongs beside the capture, not in an unrelated global state
# directory. This is a path, not device content; the WebUI shell-quotes it before writing.
printf 'capture\tdir=%s\n' "$_DIR"

# ----- meta2: device context (fix213, audit 8.1) ----------------------------------
# The page used to be device-blind, so no advice could know the device it talked about.
# All of it is in env.txt, written by the recorder when the capture started - reading it
# costs nothing extra. The module build is the one that RAN the capture, which is the
# honest answer to "which build was this day measured on".
if [ -f "$_DIR/env.txt" ]; then
  _m2() { sed -n "s/^$1:[[:space:]]*//p" "$_DIR/env.txt" 2>/dev/null | head -n 1 | tr -d '\t'; }
  printf 'meta2\tmodel=%s\tdevice=%s\tsoc=%s\trom=%s\tmod=%s\n' \
    "$(_m2 model)" "$(_m2 device)" "$(_m2 soc_model)" "$(_m2 oem_build)" "$(_m2 module_version)"
fi

# ----- cover (screen on/off split, time-weighted) ---------------------------
# Same rule as the report writer: an interval counts as screen-on only when it started
# with the screen on and is no longer than five minutes - while suspended the recorder
# does not sample, so long gaps belong to screen-off time regardless.
_h_cover_line=""
if [ -s "$_DIR/battery_trace.txt" ]; then
  _h_cover_line="$(awk -F'|' '$1 ~ /^[0-9]+$/ {
      if (pe != "") { dt = $1 - pe; if (dt > 300 || ps != "1") off += dt; else on += dt }
      pe = $1; ps = $5
    } END {
      t = on + off
      if (t >= 600) printf "cover\ton_min=%d\toff_min=%d\ton_pct=%d\n", on / 60, off / 60, 100 * on / t
    }' "$_DIR/battery_trace.txt" 2>/dev/null)"
  [ -n "$_h_cover_line" ] && printf '%s\n' "$_h_cover_line"
fi

# ----- drain (discharging phases only) --------------------------------------
# Charging rows have a negative drop and would cancel real drain out of the average.
# mA is the duration-weighted mean of the per-phase averages, reported only where the
# recorder itself trusted its sensor readings (it already blanks the unusable ones).
if [ "$_HAVE_LEDGER" = "1" ]; then
  # fix213: the line is captured, not printed straight, so the history block at the end
  # can lift the headline figure for the trend without recomputing it.
  _h_drain_line="$(_cat_ledger | awk -F'\t' '
    /^#/ { next }
    NF >= 5 {
      d = $4 - $5; dur = $3 - $2
      if ($1 ~ /^charging/ || dur <= 0) next
      drop += d; sec += dur
      if (($13 + 0) > 0) { ma += $13 * dur; maw += dur }
    }
    END {
      if (drop < 0) drop = 0
      if (sec > 0 && drop > 0)
        printf "drain\tpctph=%.1f\ttotal_drop=%d\thours=%.1f\tma=%d\n", \
          drop * 3600 / sec, drop, sec / 3600, (maw > 0 ? ma / maw : 0)
    }' 2>/dev/null)"
  [ -n "$_h_drain_line" ] && printf '%s\n' "$_h_drain_line"

  # ----- night (longest uninterrupted idle/sleep chain) ---------------------
  # Consecutive idle/sleep rows with at most two minutes between them are one stretch:
  # that is the number a user recognises as "how my phone did overnight". Reported only
  # from fifteen minutes up - shorter stretches say nothing about idle drain.
  # fix207: the same pass keeps the chain's detail - average current, mobile traffic,
  # peak CPU/skin temperatures, the wakeup-source peak - so the sheet can give the
  # night its own section ("потрачено за ночь, почему") instead of one bare rate.
  _h_night_line="$(_cat_ledger | awk -F'\t' '
    function flush() {
      if (in_c && cd > bd) {
        bd = cd; bdrop = cdrop; baw = (cawt > 0 ? caw / cawt : 0)
        bma = (cmaw > 0 ? cma / cmaw : 0); br = cr; bct = cct; bst = cst; bwp = cwp
      }
    }
    /^#/ { next }
    $1 == "idle" || $1 == "sleep" {
      dur = $3 - $2
      if (!(in_c && ($2 - pe) <= 120)) {
        flush()
        in_c = 1; cs = $2; cd = 0; cdrop = 0; caw = 0; cawt = 0
        cma = 0; cmaw = 0; cr = 0; cct = 0; cst = 0; cwp = 0
      }
      cdrop += ($4 - $5); cd = $3 - cs
      if (dur > 0) {
        caw += $12 * dur; cawt += dur
        if (($13 + 0) > 0) { cma += $13 * dur; cmaw += dur }
      }
      cr += $14 + $15
      if (($6 + 0) > cct) cct = $6 + 0
      if (($7 + 0) > cst) cst = $7 + 0
      if (($11 + 0) > cwp) cwp = $11 + 0
      pe = $3
      next
    }
    { flush(); in_c = 0 }
    END {
      flush()
      if (bd >= 900) {
        printf "night\tdur_min=%d\tdrop=%d\tpctph=%.1f\tawake=%d\n", \
          bd / 60, bdrop, (bdrop > 0 ? bdrop * 3600 / bd : 0), baw
        printf "nightd\tma=%d\tradio_mib=%.1f\tcpu_t=%d\tskin_t=%d\twake_pk=%d\n", \
          bma, br / 1048576, bct, bst, bwp
      }
    }' 2>/dev/null)"
  [ -n "$_h_night_line" ] && printf '%s\n' "$_h_night_line"

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
  _h_thermal_line="$(_cat_ledger | awk -F'\t' '
    /^#/ { next }
    ($3 - $2) <= 0 { next }
    { if (($6 + 0) > c) c = $6 + 0; if (($7 + 0) > s) s = $7 + 0 }
    END { if (c > 0 || s > 0) printf "thermal\tcpu=%d\tsurf=%d\n", c, s }' 2>/dev/null)"
  [ -n "$_h_thermal_line" ] && printf '%s\n' "$_h_thermal_line"

  # ----- heat detail (fix213, audit 8.3/К9) -----------------------------------
  # A peak alone does not say how LONG the phone ran hot, and the duration is what
  # costs battery and comfort: minutes at cpu>=45 / skin>=40, plus the phase that
  # saw the cpu peak, so the advice can name WHEN the day ran hot.
  # fix218: a "gap" is a sub-two-minute screen-off pause - it carries the heat of
  # whatever the phone was doing around it, so naming it "the hottest phase" tells
  # the user nothing (a field capture read "Hottest phase: Recording gap" while the
  # gap itself lasted three minutes). The peak is attributed to the hottest NAMED
  # phase; gap minutes still count in the durations. peak_c reports that phase's own
  # peak, so the sheet can show the number next to the name.
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    ($3 - $2) <= 0 { next }
    {
      c = $6 + 0; s = $7 + 0; dur = ($3 - $2) / 60
      if (c > mc) { mc = c; mpa = $1 }
      if ($1 != "gap" && c > mcn) { mcn = c; mp = $1 }
      if (c >= 45) cm += dur
      if (s >= 40) sm += dur
    }
    END {
      if (mp == "") { mp = mpa; mcn = mc }
      if (mc > 0) printf "heat\tpeak_phase=%s\tpeak_c=%d\twarm_min=%d\tskin_min=%d\n", mp, mcn, cm, sm
    }' 2>/dev/null

  # ----- radio traffic -------------------------------------------------------
  # Byte counters outgrow mksh 32-bit arithmetic, hence awk for the sum.
  # fix210: the idle/sleep share is split out (sradio) - mobile traffic while the screen
  # was OFF is background sync, one of the real causes of a restless idle, and the sheet
  # names it in the wake section instead of only in the day-wide total.
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    { rx += $14 + 0; tx += $15 + 0
      if ($1 == "idle" || $1 == "sleep") { irx += $14 + 0; itx += $15 + 0 } }
    END {
      m = (rx + tx) / 1048576; if (m >= 0.1) printf "radio\tmib=%.1f\n", m
      im = (irx + itx) / 1048576; if (im >= 0.1) printf "sradio\tmib=%.1f\n", im
    }' 2>/dev/null
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

# ----- live wakelock holders (fix206) -----------------------------------------
# The per-uid delta only moves when batterystats counts - and it counts nothing while
# charging, and sometimes nothing at all over a whole capture (owner's log: awake 30%
# at night, delta flat, the sheet then claimed "no wakelocks - great" while the phone
# plainly had holders). The report's LIVE WAKELOCK HOLDERS section samples the power
# manager directly, so it sees holders regardless. Up to three rows, as listed.
if [ -f "$_DIR/_full_day_report.txt" ]; then
  awk '/LIVE WAKELOCK HOLDERS/ { t = 1; next }
       t && /held in/ {
         # "  held in  23% of samples, longest hold    9 min  TAG  (pkg)"
         line = $0
         pct = line; sub(/.*held in[ ]*/, "", pct); sub(/%.*/, "", pct)
         mn  = line; sub(/.*longest hold[ ]*/, "", mn); sub(/[^0-9].*/, "", mn)
         tag = line; sub(/.*min[ ]+/, "", tag)
         pkg = ""
         if (tag ~ /\(/) {
           pkg = tag; sub(/^[^(]*\(/, "", pkg); sub(/\).*/, "", pkg)
           sub(/[ ]*\(.*/, "", tag)
         }
         # JobScheduler/sync wrappers: keep the meaningful tail of the tag.
         sub(/^\*job\*r\//, "", tag); sub(/^\*sync\*\//, "", tag)
         sub(/^\*alarm\//, "", tag)
         n = split(tag, seg, "/"); if (n > 1) tag = seg[n]
         sub(/^\.+/, "", tag)
         if (pkg ~ /^system uid/) pkg = ""
         gsub(/[\t=]/, " ", tag); gsub(/[\t=]/, " ", pkg)
         gsub(/^[ ]+|[ ]+$/, "", tag)
         if (tag != "" && pct + 0 >= 3) {
           printf "wlive\ttag=%s\tpct=%d\tmin=%d\tpkg=%s\n", tag, pct, mn, pkg
           c++; if (c >= 3) exit
         }
         next
       }
       t && NF == 0 { t = 0 }' "$_DIR/_full_day_report.txt" 2>/dev/null
fi

# ----- wake causes by occurrence (fix210) ---------------------------------------
# The per-uid held-time delta above is a DURATION counter: it stays flat while charging
# and on several ROM builds simply never moves. "Nothing recorded" then sat next to a
# restless idle and the sheet could not name a single cause - while the capture's own
# wakelock report had them, counted by occurrence:
#   TOP PARTIAL WAKELOCK HOLDERS:  "  x54   taken  *alarm*"   (each = one partial hold)
#   TOP ALARM / WAKEUP SOURCES:    "  x18    *walarm*:tag"    (each = one scheduled wakeup)
# Counts, not seconds - but "the alarm manager fired 54 times over a restless night" IS
# the answer to "what kept waking it", and it exists even when every duration is zero.
if [ -f "$_DIR/_wakelock_report.txt" ]; then
  awk '/TOP PARTIAL WAKELOCK HOLDERS/ { t = 1; next }
       t && /^-----/ { t = 0; next }
       t && $1 ~ /^x[0-9]+$/ && $2 == "taken" {
         n = $1; sub(/^x/, "", n)
         tag = ""
         for (i = 3; i <= NF; i++) tag = (tag == "" ? $i : tag " " $i)
         gsub(/[\t=]/, " ", tag); gsub(/^[ ]+|[ ]+$/, "", tag)
         if (tag != "" && n + 0 >= 3) {
           printf "wlt\ttag=%s\tn=%d\n", tag, n
           c++; if (c >= 5) exit
         }
       }' "$_DIR/_wakelock_report.txt" 2>/dev/null
  awk '/TOP ALARM \/ WAKEUP SOURCES/ { t = 1; next }
       t && /^-----/ { t = 0; next }
       t && $1 ~ /^x[0-9]+$/ && $2 ~ /^\*walarm\*:/ {
         n = $1; sub(/^x/, "", n)
         tag = ""
         for (i = 2; i <= NF; i++) tag = (tag == "" ? $i : tag " " $i)
         sub(/^\*walarm\*:/, "", tag)
         gsub(/[\t=]/, " ", tag); gsub(/^[ ]+|[ ]+$/, "", tag)
         if (tag != "" && n + 0 >= 2) {
           printf "wla\ttag=%s\tn=%d\n", tag, n
           c++; if (c >= 4) exit
         }
       }' "$_DIR/_wakelock_report.txt" 2>/dev/null
fi

# ----- per-profile drain attribution (fix206) -----------------------------------
# battery_trace field 4 is the active profile at every sample, so a day spent switching
# profiles (the tester who ran all of them, night on performance) can be split per
# profile without config_changes. Same interval rule as cover: an interval belongs to
# the profile at its start, counts only when not longer than five minutes, and only
# positive drops count (charging would fake a negative "drain"). Emitted only when two
# or more profiles actually ran - a one-profile day has nothing to compare.
if [ -s "$_DIR/battery_trace.txt" ]; then
  awk -F'|' '$1 ~ /^[0-9]+$/ {
      p = $4; if (p == "") p = "unknown"
      seen[p] = 1
      if (pe != "") {
        dt = $1 - pe
        if (dt > 0 && dt <= 300) {
          d = pb - $6
          if (ps == "1") { on[pp] += dt; if (d > 0) od[pp] += d }
          else           { off[pp] += dt; if (d > 0) fd[pp] += d }
        }
      }
      pe = $1; pp = p; ps = $5; pb = $6
    } END {
      np = 0
      for (p in seen) if ((on[p] + off[p]) >= 120) { np++; ord[np] = p }
      if (np >= 2) {
        # most time first, insertion-order bubble (np <= 8 in practice)
        for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++)
          if (on[ord[j]] + off[ord[j]] > on[ord[i]] + off[ord[i]]) {
            t = ord[i]; ord[i] = ord[j]; ord[j] = t
          }
        if (np > 8) np = 8
        for (i = 1; i <= np; i++) {
          p = ord[i]
          op = (on[p]  > 0 && od[p] > 0) ? od[p] * 3600 / on[p]  : 0
          fp = (off[p] > 0 && fd[p] > 0) ? fd[p] * 3600 / off[p] : 0
          printf "prof\tname=%s\ton_min=%d\toff_min=%d\ton_pctph=%.1f\toff_pctph=%.1f\n", \
            p, on[p] / 60, off[p] / 60, op, fp
        }
      }
    }' "$_DIR/battery_trace.txt" 2>/dev/null
fi

# ----- screen on/off drain split (fix207) ---------------------------------------
# "Самый долгий простой 0.7 %/ч, а Монитор пишет Экран выкл 1.3 %/ч": three different
# windows, three right answers. The night figure is ONE deep-sleep-heavy chain; the
# Monitor meter averages clean stretches of an hour or more, WITHOUT music; this split
# is the whole ledger - the same classification the report writer uses (screen-on:
# *_scr, active, gaming, post_wake, charging_active), charging and gap excluded, only
# positive drops count. The sheet shows all three, so the numbers stop contradicting.
# Same awk pass emits the per-phase table (fix207): every phase's time, signed drop
# (negative = charge gained) and drain rate - the detailed breakdown section.
if [ "$_HAVE_LEDGER" = "1" ]; then
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    NF >= 5 {
      ph = $1; dd = $3 - $2; d = $4 - $5
      if (dd <= 0) next
      dur[ph] += dd; drop[ph] += d; seen[ph] = 1
      if (ph ~ /^charging/ || ph == "gap") next
      if (ph ~ /_scr$/ || ph == "active" || ph == "gaming" || ph == "post_wake") {
        on += dd; if (d > 0) ond += d
      } else {
        off += dd; if (d > 0) offd += d
        if (ph == "idle" || ph == "sleep") { idl += dd; if (d > 0) idd += d }
        else if (ph ~ /^audio_/) mus += dd
      }
    }
    END {
      if (on >= 300 || off >= 300)
        printf "scr\ton_pctph=%.1f\toff_pctph=%.1f\ton_min=%d\toff_min=%d\tidle_pctph=%.1f\tidle_min=%d\tmusic_min=%d\n", \
          (on > 0 && ond > 0 ? ond * 3600 / on : 0), \
          (off > 0 && offd > 0 ? offd * 3600 / off : 0), on / 60, off / 60, \
          (idl > 0 && idd > 0 ? idd * 3600 / idl : 0), idl / 60, mus / 60
      np = 0
      for (p in seen) if (dur[p] >= 120) { np++; ord[np] = p }
      for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++)
        if (dur[ord[j]] > dur[ord[i]]) { t = ord[i]; ord[i] = ord[j]; ord[j] = t }
      if (np > 10) np = 10
      for (i = 1; i <= np; i++) {
        p = ord[i]
        r = (drop[p] > 0) ? drop[p] * 3600 / dur[p] : 0
        printf "phase\tname=%s\tmin=%d\tdrop=%d\tpctph=%.1f\n", p, dur[p] / 60, drop[p], r
      }
    }' 2>/dev/null
fi

# ----- kernel wakelock holders on the charger (fix207) ---------------------------
# batterystats counts no app wakelock while charging; the report lists the KERNEL
# holders it sampled instead ("kernel holder on the charger: rx_wake_lock 343 min").
# They explain a warm phone on a wireless pad - surface them in the wake section.
if [ -f "$_DIR/_full_day_report.txt" ]; then
  awk '/kernel holder on the charger:/ {
         line = $0; sub(/.*charger:[ ]*/, "", line)
         mn = line; sub(/[ ]*min$/, "", mn); sub(/.*[ ]/, "", mn)
         sub(/[ ]+[0-9]+ min$/, "", line)
         tag = line; gsub(/[\t=]/, " ", tag); gsub(/^[ ]+|[ ]+$/, "", tag)
         if (tag != "" && mn ~ /^[0-9]+$/ && mn + 0 >= 1) {
           printf "kwk\ttag=%s\tmin=%d\n", tag, mn
           c++; if (c >= 3) exit
         }
       }' "$_DIR/_full_day_report.txt" 2>/dev/null
fi

# ----- charging sessions (fix206) -------------------------------------------------
# The user on 5W wireless all day gained 62% across nearly 400 minutes of charging and
# the old sheet said nothing about it. Ledger rows are charging_idle/charging_active;
# sessions are contiguous rows with at most two minutes between them.
if [ "$_HAVE_LEDGER" = "1" ]; then
  _cat_ledger | awk -F'\t' '
    /^#/ { next }
    $1 ~ /^charging/ {
      dur = $3 - $2; g = $5 - $4
      if (dur > 0) { tot += dur; if (g > 0) gain += g }
      if (pe == "" || ($2 - pe) > 120) sess++
      pe = $3
    }
    END {
      if (tot >= 300) printf "chg\tmin=%d\tgain=%d\tsess=%d\n", tot / 60, gain, sess
    }' 2>/dev/null
fi

# ----- native crashes inside the capture window ------------------------------
# Window start: the first ledger row (the ledger leads with a "# ..." comment - skip it),
# else derived from the elapsed time, else - for a capture that is RUNNING but has
# written neither the ledger nor the interim report yet (the first snapshot lands after
# fifteen minutes) - the capture's own launch time, stamped on the lock's pid file
# (fix204). Only when nothing is known at all does the window reach back 24h. Without
# the launch-time step a fresh capture counted tombstones from BEFORE it started at
# minute 0 (a com.oplus.screenshot crash from an earlier screenshot), and that count then
# "disappeared" the moment the first ledger row landed - the crash list must not change
# under the user's eyes.
_start=""
if [ -s "$_LEDGER" ]; then
  _start="$(awk -F'\t' '!/^#/ { print $2; exit }' "$_LEDGER" 2>/dev/null)"
fi
case "$_start" in
  ''|*[!0-9]*)
    if [ -n "$_el" ]; then
      _start=$(( $(date +%s) - _el * 60 ))
    elif [ "$_running" = "1" ]; then
      _start="$(stat -c %Y "$_LOCK/pid" 2>/dev/null || date -r "$_LOCK/pid" +%s 2>/dev/null)"
      case "$_start" in ''|*[!0-9]*) _start="$(date +%s)" ;; esac
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
# The crash time lets the user place it ("that was when I took the screenshot") instead
# of wondering who crashed and why - the sheet shows "latest: proc, HH:MM".
_clh=""
if [ "$_clt" -gt 0 ] 2>/dev/null; then
  _clh="$(date -d "@$_clt" '+%H:%M' 2>/dev/null || date -r "$_clt" '+%H:%M' 2>/dev/null)"
fi
printf 'crash\tcount=%d\tasb=%d\tlatest=%s\tltime=%s\n' "$_cn" "$_ca" "${_cl:-none}" "${_clh:-}"

# ----- SystemUI restarts ------------------------------------------------------
_sn=0
if [ -f "$_DIR/sysui_restarts.txt" ]; then
  _sn="$(grep -c '^===== SYSTEMUI RESTART' "$_DIR/sysui_restarts.txt" 2>/dev/null)"
fi
case "$_sn" in ''|*[!0-9]*) _sn=0 ;; esac
printf 'sysui\tcount=%d\n' "$_sn"

_sdr="$_DIR/_full_day_report.txt"
if [ -f "$_sdr" ]; then
  _sd="$(sed -n 's/^com\.android\.systemui missed deadlines in \([0-9][0-9]*\) of \([0-9][0-9]*\) screen-on intervals.*/\1 \2/p' "$_sdr" 2>/dev/null | head -n 1)"
  if [ -n "$_sd" ]; then
    _sj="$(awk '$1 == "com.android.systemui" && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 { printf "%.1f", $2 * 100 / $3; exit }' "$_sdr" 2>/dev/null)"
    _sdc="$_DIR/display_config.txt"
    _sns="$(sed -n 's/^system: show_network_speed=\([0-9]\).*/\1/p' "$_sdc" 2>/dev/null | head -n 1)"
    _scs='?'
    if grep -Eq '^(secure|system): clock_seconds=1|^global: oost_systemui_permanent_clock_seconds=1' "$_sdc" 2>/dev/null; then _scs=1
    elif grep -Eq '^(secure|system): clock_seconds=0' "$_sdc" 2>/dev/null; then _scs=0; fi
    _slw='?'
    if grep -q '^wallpaper: static image' "$_sdc" 2>/dev/null; then _slw=0
    elif grep -q '^wallpaper: .*wallpaper service' "$_sdc" 2>/dev/null; then _slw=1; fi
    printf 'sysuidraw\tintv=%s\tof=%s\tpct=%s\tnetspeed=%s\tclocksec=%s\tlivewp=%s\n' \
      "${_sd% *}" "${_sd#* }" "${_sj:-0}" "${_sns:-?}" "$_scs" "$_slw"
  fi
fi

# ----- throttling periods -----------------------------------------------------
# A new period starts when the cap owner changes or the trace goes quiet for over three
# minutes (the throttle ended and later came back - two episodes, not one).
# fix219: the sheet blamed every period on the LAST period's owner - a field capture
# showed "16 (asb)" for a day of 3 ASB + 6 vendor + 6 shell + 1 unknown periods. The
# owner is now the one with the most periods (the more recent wins a tie) and the
# per-owner breakdown rides along as by=owner:n,... so the sheet can name them all.
if [ -s "$_DIR/throttle_trace.txt" ]; then
  _h_throttle_line="$(awk -F'|' '$1 ~ /^[0-9]+$/ {
      t = $1 + 0; o = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^cap_owner=/) { o = $i; sub(/^cap_owner=/, "", o) }
      if (o == "") o = "unknown"
      if (n == 0 || (t - pt) > 180 || o != po) { n++; cnt[o]++; last[o] = t }
      pt = t; po = o
    } END {
      if (n > 0) {
        best = ""; bc = -1; bl = -1
        for (o in cnt) if (cnt[o] > bc || (cnt[o] == bc && last[o] > bl)) { best = o; bc = cnt[o]; bl = last[o] }
        by = ""
        while (1) {
          bo = ""; bc2 = -1; bl2 = -1
          for (o in cnt) if (!(o in done) && (cnt[o] > bc2 || (cnt[o] == bc2 && last[o] > bl2))) { bo = o; bc2 = cnt[o]; bl2 = last[o] }
          if (bo == "") break
          done[bo] = 1; by = by (by == "" ? "" : ",") bo ":" bc2
        }
        printf "throttle\tclamps=%d\towner=%s\tby=%s\n", n, best, by
      }
    }' "$_DIR/throttle_trace.txt" 2>/dev/null)"
  [ -n "$_h_throttle_line" ] && printf '%s\n' "$_h_throttle_line"
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
  # Wake smoothness (fix220): "the wake itself: 23 wake(s), ... frames 109484, janky 8.0%
  # (ordinary screen-on intervals: 7.2%)" plus the top wake janker from the "at the wakes,
  # by app:" line below it. The wake rows are exactly where ColorOS 17 janked (lock/unlock,
  # open/close), so the sheet shows them next to the day average.
  _wk="$(grep -m1 '^the wake itself:' "$_RPT" 2>/dev/null)"
  if [ -n "$_wk" ]; then
    _wn="$(printf '%s\n' "$_wk" | sed -n 's/^the wake itself: \([0-9][0-9]*\) wake.*/\1/p')"
    _wf="$(printf '%s\n' "$_wk" | sed -n 's/.* frames \([0-9][0-9]*\),.*/\1/p')"
    _wp="$(printf '%s\n' "$_wk" | sed -n 's/.*janky \([0-9.][0-9.]*\)%.*/\1/p')"
    _wo="$(printf '%s\n' "$_wk" | sed -n 's/.*ordinary screen-on intervals: \([0-9.][0-9.]*\)%.*/\1/p')"
    _wt="$(sed -n 's/^  at the wakes, by app: \([a-z0-9._]*\) [0-9][0-9]* of [0-9][0-9]* janky (\([0-9.][0-9.]*\)%.*/\1 \2/p' "$_RPT" 2>/dev/null | head -n 1)"
    if [ -n "$_wn" ] && [ -n "$_wp" ]; then
      printf 'jwake\twakes=%s\tpct=%s\tord=%s\tframes=%s\ttop=%s\ttop_pct=%s\n' \
        "$_wn" "$_wp" "${_wo:-0}" "${_wf:-0}" "${_wt%% *}" "${_wt##* }"
    fi
  fi
  # Smoothness by phase and by ASB state (fix220): the two small tables under the
  # smoothness headline - "phase  intervals  frames  janky  janky/s" and the same with
  # "ASB state". Headers are matched in full so the drain phase table (dur_min, pct/h)
  # further down cannot leak in.
  awk '/^phase[ \t]+intervals[ \t]+frames[ \t]+janky[ \t]+janky\/s[ \t]*$/ { t = 1; next }
       t && $1 ~ /^[a-z_]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9.]+%$/ {
         p = $4; sub(/%$/, "", p)
         printf "jphase\tphase=%s\tintv=%s\tframes=%s\tpct=%s\tjps=%s\n", $1, $2, $3, p, $5; next
       }
       t { exit }' "$_RPT" 2>/dev/null
  awk '/^ASB state[ \t]+intervals[ \t]+frames[ \t]+janky[ \t]+janky\/s[ \t]*$/ { t = 1; next }
       t && $1 ~ /^[A-Za-z_]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9.]+%$/ {
         p = $4; sub(/%$/, "", p)
         printf "jstate\tstate=%s\tintv=%s\tframes=%s\tpct=%s\tjps=%s\n", $1, $2, $3, p, $5; next
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
  # Gauge check (fix220): "governor's gauge check: on screen-on windows current_now
  # integrates to x0.34 of the SOC-derived drain (40 windows) - multiply screen-on mA by
  # about 2.9; ...". On the OP15 the sensor under-reads by ~3x, which makes every mA figure
  # in the sheet look better than the battery's own count - the sheet says so.
  _gl="$(grep -m1 "^governor's gauge check:" "$_RPT" 2>/dev/null)"
  if [ -n "$_gl" ]; then
    _gf="$(printf '%s\n' "$_gl" | sed -n 's/.* integrates to x\([0-9.][0-9.]*\) of .*/\1/p')"
    _gw="$(printf '%s\n' "$_gl" | sed -n 's/.* (\([0-9][0-9]*\) windows).*/\1/p')"
    _gm="$(printf '%s\n' "$_gl" | sed -n 's/.*multiply screen-on mA by about \([0-9.][0-9.]*\).*/\1/p')"
    [ -n "$_gf" ] && printf 'gauge\tfactor=%s\twindows=%s\tmult=%s\n' "$_gf" "${_gw:-0}" "${_gm:-0}"
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
  # LTPO video drop (fix206): "ltpo_video (lifetime): lowered N times, M min at the
  # lower rate, ..." - proof the panel savings actually engage.
  _lt="$(sed -n 's/^ltpo_video (lifetime): lowered \([0-9][0-9]*\) times, \([0-9][0-9]*\) min at the lower rate.*/\1 \2/p' "$_RPT" 2>/dev/null | head -n 1)"
  if [ -n "$_lt" ]; then
    printf 'ltpo\tn=%s\tmin=%s\n' "${_lt% *}" "${_lt#* }"
  fi
  # Always-on display share of screen-off time (fix206): "always-on display: X of Y
  # screen-off samples had the panel lit ..." - AOD is a steady idle drain worth naming.
  _ao="$(sed -n 's/^always-on display: \([0-9][0-9]*\) of \([0-9][0-9]*\) screen-off samples had the panel lit.*/\1 \2/p' "$_RPT" 2>/dev/null | head -n 1)"
  if [ -n "$_ao" ]; then
    printf 'aod\tlit=%s\tof=%s\n' "${_ao% *}" "${_ao#* }"
  fi
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
  # ----- night habits (fix213, audit 8.8) ---------------------------------------
  # The microwake learner's summary rides in the same file. A reassuring fact the page
  # never showed: how rarely the phone stirs at night and for how long - deliberately a
  # calm row, not an alarm.
  _mw="$(grep -m1 '^microwake|' "$_DIR/smart_records.txt" 2>/dev/null)"
  if [ -n "$_mw" ]; then
    _mwn="$(printf '%s' "$_mw" | sed -n 's/.*learned=\([0-9]*\).*/\1/p')"
    [ -n "$_mwn" ] && printf 'mwake\tn=%s\tper_night=%s\ttypical_s=%s\n' \
      "$_mwn" \
      "$(printf '%s' "$_mw" | sed -n 's/.*per_night=\([0-9.]*\).*/\1/p')" \
      "$(printf '%s' "$_mw" | sed -n 's/.*typical_s=\([0-9]*\).*/\1/p')"
  fi
fi

# ----- the settings the advice can point at (fix200) -----------------------------
# Read from the CURRENT config, not the capture: a saved week's-old log should still give
# advice that matches the settings as they are now. The list is fixed; values are
# sanitized to one word.
_MD="$(CDPATH= cd -- "$(dirname "$0")/../.." 2>/dev/null && pwd)"
_CFG="${ASB_CFG_FILE:-$_MD/config/governor.conf}"
if [ -f "$_CFG" ]; then
  for _k in wakelock_action ltpo_video night_modem_idle net_screen_off_lte wifi_powersave gms_freeze doze_level sustained_temp_mode; do
    _v="$(grep -E "^[[:space:]]*$_k=" "$_CFG" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \t\r')"
    [ -n "$_v" ] && printf 'cfg\tkey=%s\tvalue=%s\n' "$_k" "$_v"
  done
fi

# ----- capture history + trend (fix213, audit 8.2) --------------------------------
# A finished capture leaves one compact line in report_history.tsv; the NEXT report then
# answers the question no single-day report could: "did what I changed actually help?"
# Keyed by the capture's start minute (a re-opened report rewrites its own line instead
# of duplicating it), the last 12 kept. Strictly best-effort - on a device where the
# state dir is unwritable the report works exactly as before, just without a trend.
_hkv() { printf '%s\n' "$1" | grep -E "^$2[[:space:]]" | head -n 1 | tr '\t' '\n' | sed -n "s/^$3=//p"; }
_h_dp="$(_hkv "${_h_drain_line:-}" drain pctph)"
_h_np="$(_hkv "${_h_night_line:-}" night pctph)"
_h_cp="$(_hkv "${_h_thermal_line:-}" thermal cpu)"
_h_tc="$(_hkv "${_h_throttle_line:-}" throttle clamps)"
_h_on="$(_hkv "${_h_cover_line:-}" cover on_pct)"
_h_off="$(_hkv "${_h_cover_line:-}" cover off_min)"
_h_env() { sed -n "s/^$1:[[:space:]]*//p" "$_DIR/env.txt" 2>/dev/null | head -n 1 | tr -d '\t'; }
_h_device="$(_h_env device)"; _h_rom="$(_h_env oem_build)"; _h_mod="$(_h_env module_version)"
_HF="$_STATE/report_history.tsv"
if [ -s "$_HF" ]; then
  # Up to three earlier captures, newest first - enough for "was -> became" without a
  # wall of history on the page.
  awk -F'\t' -v k="${_started:-}" '
    $1 != k { r[++n] = $0 }
    END {
      for (i = n; i >= 1 && s < 3; i--) {
        split(r[i], f, "\t"); s++
        printf "hist\tstarted=%s\tnight=%s\tdrain=%s\tjank=%s\tcpu=%s\tclamps=%s\tdevice=%s\trom=%s\tmod=%s\telapsed=%s\ton_pct=%s\toff_min=%s\tdm=%s\n", \
          f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13]
      }
    }' "$_HF" 2>/dev/null
fi
if [ "$_running" = 0 ] && [ -n "${_started:-}" ] && { [ -n "$_h_dp" ] || [ -n "$_h_np" ]; }; then
  if mkdir -p "$_STATE" 2>/dev/null && touch "$_HF" 2>/dev/null; then
    { awk -F'\t' -v k="$_started" '$1 != k' "$_HF" 2>/dev/null
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_started" "${_h_np:--}" "${_h_dp:--}" "${_jp:--}" "${_h_cp:--}" "${_h_tc:--}" \
        "${_h_device:--}" "${_h_rom:--}" "${_h_mod:--}" "${_el:-0}" "${_h_on:--}" "${_h_off:--}" 2
    } | tail -n 12 > "$_HF.tmp" 2>/dev/null && mv "$_HF.tmp" "$_HF" 2>/dev/null || rm -f "$_HF.tmp"
  fi
fi

exit 0
