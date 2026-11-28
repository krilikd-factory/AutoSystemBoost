#!/system/bin/sh
# ASB Evolution Engine, stages 0-3.5: identity, an append-only experiment journal, a read-only
# evaluator that checks itself, and a shadow advisor. It never writes a system setting.
#
# The experiments are the Smart lab's own (src/asb_lab.h): one existing knob at a time, champion
# against one challenger, side by side, with the governor as the only owner of every write and
# its restore. This script is the independent half. It does not gate the lab's own decisions:
# it re-checks, after the fact, what the lab's published pair statistics support.
#
# Every public command goes through one guarded pipeline (stage 3.5):
#   constitution -> complete build identity -> self-check of THIS engine (code + fixtures +
#   policy) -> full journal integrity (prefix digest) -> pairs of the current build generation
#   only -> evidence quality -> early harm -> pair count -> gates -> benefit.
# A positive result is "eligible_for_holdout": there is no field A/A and no holdout yet, so
# nothing here is called a proven champion.
#
# No timer or worker: it runs when the WebUI or asbdiag reads it, and once after boot (from the
# existing boot waiter) to mark where a new build generation starts. Nothing it stores names an
# account, a serial, a network or the content of an app.
#
#   sh asb_evolution.sh status | record | evaluate | selftest | advise | verify | export | clear
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_EVO_DIR:-/data/adb/asb/evolution}"
LAB="${ASB_EVO_LAB:-/dev/.asb/smart_lab.txt}"
ENERGY="${ASB_EVO_ENERGY:-/dev/.asb/smart_energy.txt}"
POLICY="${ASB_EVO_POLICY:-$MODDIR/runtime/asb_evolution.policy}"
SAFE="${ASB_EVO_SAFE:-/dev/.asb/safe_mode}"
MANIFEST="${ASB_EVO_MANIFEST:-$MODDIR/release-manifest.json}"
ENGINE="${ASB_EVO_ENGINE:-$0}"
J="$D/journal"
KNOBS='radio wake_lift membus_on membus_off app1 app2 app3'
SCHEMA=3          # journal/kstat/fixture contract; part of the trust key

_now() { case "${ASB_EVO_NOW:-}" in ''|*[!0-9]*) date +%s 2>/dev/null || echo 0 ;; *) echo "$ASB_EVO_NOW" ;; esac; }
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else cksum | tr -c '0-9\n' ' ' | awk '{ printf "ck%s\n", $1 }'; fi; }
_clean() { tr ' ' '_' | tr -cd 'A-Za-z0-9_.:=,;+%/-'; }

# ---- constitution ---------------------------------------------------------------------------
P_OK=0; P_HASH=none
_policy() {
  P_OK=0; P_HASH=none
  [ -r "$POLICY" ] || return 1
  P_HASH="$(_sha < "$POLICY" | cut -c1-12)"
  eval "$(awk -F= -v known=" $KNOBS " '
    /^[[:space:]]*#/ || !NF { next }
    { k = $1; v = substr($0, length($1) + 2) }
    k == "schema" && v == "2" { s = 1 }
    k == "allow" { n = split(v, a, ","); ok = n > 0
      for (i = 1; i <= n; i++) if (index(known, " " a[i] " ") == 0) ok = 0
      if (ok) allow = v }
    k ~ /^(min_pairs|journal_max|retention_days)$/ && v ~ /^[1-9][0-9]*$/ { num[k] = v }
    k ~ /^(min_gain|t_min|dearer|early_jank|early_press|early_heat|max_press|max_jank|max_heat)$/ && v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 > 0 { num[k] = v }
    END {
      need = "min_pairs journal_max retention_days min_gain t_min dearer early_jank early_press early_heat max_press max_jank max_heat"
      m = split(need, w, " "); good = s && allow != ""
      for (i = 1; i <= m; i++) if (!(w[i] in num)) good = 0
      # Floors: the file may tighten a rule, never loosen it below the lab'"'"'s own (src/asb_lab.h).
      if (num["t_min"] + 0 < 2.5 || num["min_gain"] + 0 < 0.03 || num["min_pairs"] + 0 < 6 ||
          num["dearer"] + 0 > 0.15 || num["early_jank"] + 0 > 0.02 || num["early_press"] + 0 > 0.15 ||
          num["early_heat"] + 0 > 30 || num["max_press"] + 0 > 0.08 || num["max_jank"] + 0 > 0.01 ||
          num["max_heat"] + 0 > 15 || num["journal_max"] + 0 < 4 || num["journal_max"] + 0 > 4000 ||
          num["retention_days"] + 0 > 365) good = 0
      for (i = 1; i <= m; i++) if (w[i] in num) printf "P_%s=%s\n", w[i], num[w[i]]
      printf "P_ALLOW=%s\nP_GOOD=%d\n", allow, good
    }' "$POLICY" 2>/dev/null)"
  [ "${P_GOOD:-0}" = 1 ] && P_OK=1
  [ "$P_OK" = 1 ]
}

# ---- build identity -------------------------------------------------------------------------
_identity() {
  _src="$(sed -n 's/.*"source_commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$MANIFEST" 2>/dev/null | head -n 1)"
  _pay="$(sed -n 's/.*"payload_sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" 2>/dev/null | head -n 1)"
  # ROM and kernel as one opaque short hash: a change starts a new generation, nothing more.
  _env="$( { getprop ro.build.fingerprint 2>/dev/null; uname -r 2>/dev/null; } | _sha | cut -c1-10)"
  ID="$(printf '%s' "${_src:-unknown}" | cut -c1-12):$(printf '%s' "${_pay:-unknown}" | cut -c1-12):${_env:-unknown}"
  case "$ID" in unknown:*|*:unknown:*|*:unknown) ID_OK=0 ;; *) ID_OK=1 ;; esac
}

# ---- evidence quality -----------------------------------------------------------------------
# The energy scale's own confidence, as the governor publishes it (asb_energy.h): high when the
# gauge correction rests on 30+ windows. Anything else limits a positive verdict; unreadable
# is unknown, never assumed good.
_meter() {
  METER="$(sed -n 's/^meter|.*|confidence=\([a-z]*\)|.*/\1/p' "$ENERGY" 2>/dev/null | head -n 1)"
  case "$METER" in high|medium|low) : ;; *) METER=unknown ;; esac
}

# ---- journal --------------------------------------------------------------------------------
# One writer at a time, without waiting: a page or a report that finds the journal busy skips
# its recording (the outcome says so). A lock older than a minute belongs to a run that was
# killed and is cleared, so an interruption cannot stop recording for good.
_lock() {
  mkdir -p "$D" 2>/dev/null || return 1
  mkdir "$D/.lock" 2>/dev/null && return 0
  [ -n "$(find "$D/.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
  rmdir "$D/.lock" 2>/dev/null
  mkdir "$D/.lock" 2>/dev/null
}
_unlock() { rmdir "$D/.lock" 2>/dev/null; }
_tail_ref() {  # prints "seq hash" of the newest entry, the anchor, or "0 genesis"
  if [ -s "$J" ]; then tail -n 1 "$J" | awk -F'|' 'NF >= 6 { print $1, $NF; ok = 1 } END { if (!ok) print "0 genesis" }'
  elif [ -s "$D/anchor" ]; then head -n 1 "$D/anchor"
  else echo '0 genesis'; fi
}
_append() {  # kind payload
  set -- "$1" "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_.:=,;+%/-')"
  _r="$(_tail_ref)"; _ps="${_r%% *}"; _ph="${_r#* }"
  case "$_ps" in ''|*[!0-9]*) return 1 ;; esac
  _body="$((_ps + 1))|$(_now)|$1|$2|$_ph"
  _hh="$(printf '%s' "$_body" | _sha)"
  printf '%s|%s\n' "$_body" "$_hh" >> "$J" || return 1
  # The newest seq ever written, only ever moved forward: a journal that later ends before it
  # was truncated, and no later append can lower the mark.
  _hs=0; [ -s "$D/head" ] && read -r _hs _hhh < "$D/head"
  case "$_hs" in ''|*[!0-9]*) _hs=0 ;; esac
  [ "$((_ps + 1))" -gt "$_hs" ] && printf '%s %s\n' "$((_ps + 1))" "$_hh" > "$D/head" 2>/dev/null
  return 0
}
_trim() {
  [ -s "$J" ] || return 0
  _cut=$(( $(_now) - ${P_retention_days:-30} * 86400 ))
  _drop="$(awk -F'|' -v max="${P_journal_max:-400}" -v cut="$_cut" '{ n++; ts[n] = $2 } END {
      d = n - max; if (d < 0) d = 0
      while (d < n && ts[d + 1] + 0 < cut) d++
      print d }' "$J")"
  [ "${_drop:-0}" -gt 0 ] 2>/dev/null || return 0
  # The last dropped entry becomes the anchor: the kept tail stays verifiable from it.
  sed -n "${_drop}p" "$J" | awk -F'|' '{ print $1, $NF }' > "$D/anchor.tmp" && mv -f "$D/anchor.tmp" "$D/anchor"
  sed "1,${_drop}d" "$J" > "$J.tmp" && mv -f "$J.tmp" "$J"
  rm -f "$D/verified" 2>/dev/null
}
# Integrity of the whole journal on every read. A checkpoint keeps the digest of the verified
# prefix: one hash of those lines proves none of them changed, so only newer entries are
# re-chained one by one. A changed, removed, reordered or replayed entry anywhere, or a journal
# that ends before the newest entry ever written, is damage.
J_STATE=empty; J_BAD=0
_verify() {
  J_STATE=empty; J_BAD=0
  if [ ! -s "$J" ]; then
    # Nothing left: fine only if nothing was ever written, or the anchor is the newest entry.
    if [ -s "$D/head" ]; then
      read -r _hs _hhh < "$D/head"; _as=0
      [ -s "$D/anchor" ] && read -r _as _ahh < "$D/anchor"
      case "$_hs$_as" in *[!0-9]*) J_STATE=damaged; J_BAD=unparsable ;; *) [ "$_as" -lt "$_hs" ] && { J_STATE=damaged; J_BAD=truncated; } ;; esac
    fi
    return 0
  fi
  _from=0; _prev=genesis; _lines=0
  if [ -s "$D/anchor" ]; then read -r _from _prev < "$D/anchor"; fi
  if [ "$1" != full ] && [ -s "$D/verified" ]; then
    read -r _vn _vs _vh _vd < "$D/verified"
    case "$_vn" in ''|*[!0-9]*) _vn=0 ;; esac
    if [ "$_vn" -gt 0 ] && [ "$(wc -l < "$J" | tr -d ' ')" -ge "$_vn" ] && \
       [ "$(head -n "$_vn" "$J" | _sha)" = "$_vd" ] && \
       [ "$(sed -n "${_vn}p" "$J" | awk -F'|' '{ print $1 " " $NF }')" = "$_vs $_vh" ]; then
      _lines="$_vn"; _from="$_vs"; _prev="$_vh"
    fi
  fi
  J_STATE=ok; _i=0
  while IFS= read -r _l; do
    _i=$((_i + 1)); [ "$_i" -le "$_lines" ] && continue
    # \| : an unquoted | in a pattern is alternation under mksh (Android's sh), literal in dash.
    _s="${_l%%\|*}"
    case "$_s" in ''|*[!0-9]*) J_STATE=damaged; J_BAD=unparsable; break ;; esac
    _h="${_l##*\|}"; _b="${_l%\|*}"; _p="${_b##*\|}"
    if [ "$_s" != "$((_from + 1))" ] || [ "$_p" != "$_prev" ] || [ "$(printf '%s' "$_b" | _sha)" != "$_h" ]; then
      J_STATE=damaged; J_BAD="$_s"; break
    fi
    _from="$_s"; _prev="$_h"
  done < "$J"
  if [ "$J_STATE" = ok ] && [ -s "$D/head" ]; then
    read -r _hs _hhh < "$D/head"
    case "$_hs" in ''|*[!0-9]*) : ;; *) [ "$_from" -lt "$_hs" ] && { J_STATE=damaged; J_BAD=truncated; } ;; esac
  fi
  if [ "$J_STATE" = ok ]; then
    _n="$(wc -l < "$J" | tr -d ' ')"
    printf '%s %s %s %s\n' "$_n" "$_from" "$_prev" "$(head -n "$_n" "$J" | _sha)" > "$D/verified" 2>/dev/null
  fi
  return 0
}

# ---- evaluator ------------------------------------------------------------------------------
# One awk program judges the live lab file and the fixtures alike: the self-check exercises
# exactly the code that judges the phone.
#
# Pairs of the current build generation only. The lab's aggregates run across builds (its
# store survives a module update), so the journal marks where each generation's run of a trial
# starts (an obs entry, written at the first read after boot). The pairs measured since then
# are recovered exactly from the two aggregate snapshots (the inverse of Welford's merge); the
# pairs before it - another build, a rollback's old run, or a run first seen already under way -
# never count. A run the journal cannot prove contributes no pairs.
EVAL_AWK='
function kv(p, key,   n, a, i) { n = split(p, a, ";"); for (i = 1; i <= n; i++) if (index(a[i], key "=") == 1) return substr(a[i], length(key) + 2); return "" }
function numok(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
# Arm names as the journal stores them (_clean in the shell): compared, never displayed.
function san(x) { gsub(/ /, "_", x); gsub(/[^A-Za-z0-9_.:=,;+%\/-]/, "", x); return x }
FILENAME == jf {
  if (split($0, f, "|") < 6 || f[3] != "obs") next
  p = f[4]; k = kv(p, "knob"); seg = kv(p, "best") "/" kv(p, "try"); g = kv(p, "id") "/" kv(p, "lab_build")
  ok = (kv(p, "sv") == "2") && numok(kv(p, "n")) && numok(kv(p, "mean")) && numok(kv(p, "var")) && numok(kv(p, "jp")) && numok(kv(p, "press")) && numok(kv(p, "jank")) && numok(kv(p, "heat"))
  nn = kv(p, "n") + 0
  if (seg != segk[k] || g != genk[k] || !ok || nn < bn[k] || nn == 0) {
    segk[k] = seg; genk[k] = g; bok[k] = ok
    bn[k] = nn; bm[k] = kv(p, "mean") + 0; bv[k] = kv(p, "var") + 0; bjp[k] = kv(p, "jp") + 0
    bp[k] = kv(p, "press") + 0; bj[k] = kv(p, "jank") + 0; bh[k] = kv(p, "heat") + 0
  }
  next
}
$1 == "knob" && (NF == 18 || NF == 20) { st[$2] = $3; be[$2] = $4; tr[$2] = $5; lv[$2] = (NF == 20 ? $19 : "-"); seen[$2] = 1; next }
$1 == "kstat" && NF == 10 {
  if (!(numok($3) && numok($4) && numok($5) && numok($6) && numok($7) && numok($8) && numok($9))) { bad[$2] = 1; next }
  n[$2] = $3 + 0; m[$2] = $4 + 0; v[$2] = $5 + 0; jp[$2] = $6 + 0; pr[$2] = $7 + 0; jk[$2] = $8 + 0; ht[$2] = $9 + 0; lb[$2] = $10; ks[$2] = 1; next
}
END {
  na = split(allow, al, ",")
  for (q = 1; q <= na; q++) {
    k = al[q]; if (!(k in seen)) continue
    verdict = "inconclusive"; why = "-"; quality = "unknown"
    nb = 0; mb = 0; vb = 0; jpb = 0; pb = 0; jb = 0; hb = 0; t = 0; sd = 0
    if (k in ks) {
      seg = san(be[k]) "/" san(tr[k]); g = cur_id "/" lb[k]
      if ((k in bok) && bok[k] && segk[k] == seg && genk[k] == g && n[k] >= bn[k]) {
        nb = n[k] - bn[k]
        if (nb > 0) {
          mb = (n[k] * m[k] - bn[k] * bm[k]) / nb
          m2a = (bn[k] > 1 ? bv[k] * (bn[k] - 1) : 0); m2t = (n[k] > 1 ? v[k] * (n[k] - 1) : 0)
          d = mb - bm[k]; m2b = m2t - m2a - (bn[k] > 0 ? d * d * bn[k] * nb / n[k] : 0)
          vb = (nb > 1 && m2b > 0) ? m2b / (nb - 1) : 0
          pb = (n[k] * pr[k] - bn[k] * bp[k]) / nb; hb = (n[k] * ht[k] - bn[k] * bh[k]) / nb
          jpb = jp[k] - bjp[k]; jb = (jpb > 0) ? (jp[k] * jk[k] - bjp[k] * bj[k]) / jpb : 0
        }
      }
      sd = (vb > 0) ? sqrt(vb) : 0
      t = (sd > 0 && nb > 0) ? -mb / (sd / sqrt(nb)) : 0
      # Scale quality: the meter, and for a screen-on knob frames counted in its pairs.
      screen_on = (k != "membus_off")
      if (meter == "high") quality = "valid"; else if (meter == "medium" || meter == "low") quality = "limited"; else quality = "unknown"
      qwhy = (meter == "high") ? "" : (meter == "unknown" ? "meter_unknown" : "meter_limited")
      if (quality == "valid" && screen_on && jpb == 0) { quality = "limited"; qwhy = "insufficient_jank_coverage" }
    }
    # The lab exempts the screen-off bus and the wake lift from the warming gate; so does this.
    heatgate = (k != "membus_off" && k != "wake_lift")
    if (!policy_ok) { verdict = "blocked"; why = "policy_invalid" }
    else if (st[k] == "off" || st[k] == "free") { verdict = "blocked"; why = (st[k] == "free" ? "no_app_assigned" : "lab_off") }
    else if (k in bad) { verdict = "blocked"; why = "malformed_statistics" }
    else if (!(k in ks)) { verdict = "blocked"; why = "no_pair_statistics" }
    else if (safe) { verdict = "held"; why = "safe_mode" }
    else if (trust != "trusted") { verdict = "held"; why = "evaluator_untrusted" }
    else if (journal != "ok" && journal != "empty") { verdict = "held"; why = "journal_damaged" }
    else if (!id_ok) { verdict = "held"; why = "incomplete_identity" }
    else if (n[k] == 0) { verdict = "inconclusive"; why = (tr[k] == "-" ? "no_challenger" : "no_pairs_yet") }
    else if (nb == 0) { verdict = "inconclusive"; why = "unproven_pair_identity" }
    # Early harm first, as the lab stops a trial (src/asb_lab.h asb_lab_verdict): harm outranks
    # a too-small sample.
    else if (nb >= 3 && mb >= dearer) { verdict = "rejected"; why = "dearer" }
    else if (jpb >= 2 && jb >= early_jank) { verdict = "rejected"; why = "early_jank" }
    else if (nb >= 3 && pb >= early_press) { verdict = "rejected"; why = "early_ceiling" }
    else if (nb >= 3 && heatgate && hb >= early_heat) { verdict = "rejected"; why = "early_heat" }
    else if (nb < min_pairs) { verdict = "inconclusive"; why = "too_few_pairs" }
    else if (pb > max_press) { verdict = "rejected"; why = "gate_ceiling" }
    else if (jpb > 0 && jb > max_jank) { verdict = "rejected"; why = "gate_jank" }
    else if (heatgate && hb > max_heat) { verdict = "rejected"; why = "gate_heat" }
    else if (vb <= 0) { verdict = "inconclusive"; why = "no_spread" }
    else if (mb <= -min_gain && t >= t_min) {
      if (quality == "valid") { verdict = "eligible_for_holdout"; why = "cheaper_significant" }
      else { verdict = "inconclusive"; why = qwhy }
    }
    else if (t <= -t_min) { verdict = "rejected"; why = "dearer_significant" }
    else { verdict = "inconclusive"; why = "within_noise" }
    printf "ev|%s|%s|%s|%s|%d|%d|%.4f|%.4f|%.2f|%.4f|%.4f|%.1f|%s|%s|%s|%s|%d\n", k, st[k], be[k], tr[k], n[k], nb, mb, sd, t, pb, jb, hb, verdict, why, lv[k], quality, jpb
  }
}'
_evaluate() {  # lab_file journal_file trust safe journal_state id_ok cur_id meter
  set -- "$1" "$( [ -r "$2" ] && printf '%s' "$2" || printf /dev/null)" "$3" "$4" "$5" "$6" "$7" "$8"
  [ -r "$1" ] || return 0
  awk -F'|' -v jf="$2" -v allow="$P_ALLOW" -v policy_ok="$P_OK" -v trust="$3" -v safe="$4" \
    -v journal="$5" -v id_ok="$6" -v cur_id="$7" -v meter="$8" \
    -v min_pairs="${P_min_pairs:-6}" -v min_gain="${P_min_gain:-0.03}" -v t_min="${P_t_min:-2.5}" \
    -v dearer="${P_dearer:-0.15}" -v early_jank="${P_early_jank:-0.02}" -v early_press="${P_early_press:-0.15}" \
    -v early_heat="${P_early_heat:-30}" -v max_press="${P_max_press:-0.08}" -v max_jank="${P_max_jank:-0.01}" \
    -v max_heat="${P_max_heat:-15}" "$EVAL_AWK" "$2" "$1" 2>/dev/null
}

# Synthetic fixtures with known answers. They are part of this file, so the engine's own hash
# covers them, and they are never adjusted to match an output: a mismatch is a defect of the
# evaluator, reported as such.
_selftest() {
  _t="$D/.selftest.$$"; mkdir -p "$_t" 2>/dev/null || return 1
  _k() {  # knob n mean var jp press jank heat
    printf 'knob|%s|testing|a|b|%s|0|0|0|0|0|0|0|0|0|0|0|-|-|-1\nkstat|%s|%s|%s|%s|%s|%s|%s|%s|1\n' "$1" "$2" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  }
  _o() {  # seq knob n id  - a run start (sv=2) of a trial a/b on lab build 1
    printf '%s|1|obs|knob=%s;best=a;try=b;n=%s;mean=0;var=0;jp=0;press=0;jank=0;heat=0;sv=2;lab_build=1;id=%s|x|y\n' "$1" "$2" "$3" "$4"
  }
  {
    _k radio 16 0.001 0.0009 16 0.01 0 0             # no-op: pure noise must not be eligible
    _k wake_lift 6 -0.031 0.0036 6 0.01 0 0          # a lucky small "gain" inside the noise
    _k membus_on 8 -0.06 0.0004 4 0.01 0.002 2       # a clear, clean saving
    _k membus_off 8 -0.06 0.0004 4 0.01 0.02 0       # the same saving, janky: early harm first
    _k app1 3 0.20 0.0004 0 0.01 0 0                 # plainly dearer
    _k app2 4 -0.08 0.0001 4 0.01 0 0                # too few pairs to decide
    _k app3 7 -0.06 0.0004 7 0.01 0 3                # clean, but first seen under way: unproven
  } > "$_t/lab"
  { _o 1 radio 0 fx; _o 2 wake_lift 0 fx; _o 3 membus_on 0 fx; _o 4 membus_off 0 fx; _o 5 app1 0 fx; _o 6 app2 0 fx
    _o 7 app3 7 fx; } > "$_t/j"
  _want='radio=inconclusive:within_noise wake_lift=inconclusive:within_noise membus_on=eligible_for_holdout:cheaper_significant membus_off=rejected:early_jank app1=rejected:dearer app2=inconclusive:too_few_pairs app3=inconclusive:unproven_pair_identity'
  _fx() { _evaluate "$1" "$_t/j" trusted 0 "${2:-ok}" "${3:-1}" fx "${4:-high}" | awk -F'|' '{ printf "%s%s=%s:%s", (NR > 1 ? " " : ""), $2, $14, $15 }'; }
  _got="$(_fx "$_t/lab")"
  _why=''
  [ "$_got" = "$_want" ] || _why="fixture:$(printf '%s\n%s\n' "$_want" "$_got" | tr ' ' '\n' | sort | uniq -u | head -n 1 | cut -d= -f1)"
  # The same clean saving must be held or limited under every weak input.
  _one() { _fx "$_t/lab" "$1" "$2" "$3" | tr ' ' '\n' | sed -n 's/^membus_on=//p'; }
  [ -n "$_why" ] || [ "$(_one ok 0 high)" = held:incomplete_identity ] || _why=fixture:identity
  [ -n "$_why" ] || [ "$(_one damaged 1 high)" = held:journal_damaged ] || _why=fixture:journal
  [ -n "$_why" ] || [ "$(_one ok 1 low)" = inconclusive:meter_limited ] || _why=fixture:meter
  [ -n "$_why" ] || [ "$(_one ok 1 unknown)" = inconclusive:meter_unknown ] || _why=fixture:meter_unknown
  # A lab line without pair statistics, or with a malformed one, is blocked, never read as 0.
  printf 'knob|radio|testing|a|b|5|0|0|0|0|0|0|0|0|0|0|0|-|-|-1\n' > "$_t/old"
  [ -n "$_why" ] || [ "$(_fx "$_t/old" | cut -d= -f2)" = blocked:no_pair_statistics ] || _why=fixture:no_stats
  printf 'knob|radio|testing|a|b|5|0|0|0|0|0|0|0|0|0|0|0|-|-|-1\nkstat|radio|5|nan|0.1|0|0|0|0|1\n' > "$_t/bad"
  [ -n "$_why" ] || [ "$(_fx "$_t/bad" | cut -d= -f2)" = blocked:malformed_statistics ] || _why=fixture:malformed
  rm -rf "$_t"
  if [ "$P_OK" != 1 ]; then TRUST=untrusted; TRUST_WHY=policy_invalid
  elif [ -z "$ENGINE_HASH" ] || [ "$ENGINE_HASH" = none ]; then TRUST=untrusted; TRUST_WHY=engine_unreadable
  elif [ -n "$_why" ]; then TRUST=untrusted; TRUST_WHY="$_why"
  else TRUST=trusted; TRUST_WHY=fixtures_passed; fi
  mkdir -p "$D" 2>/dev/null && printf '%s|%s|%s|%s\n' "$TRUST" "$TRUST_WHY" "$TRUST_KEY" "$(_now)" > "$D/trust" 2>/dev/null
}
# A passed self-check is reused only for the same engine code, fixtures, schema and policy.
_trust() {
  ENGINE_HASH="$( [ -r "$ENGINE" ] && _sha < "$ENGINE" | cut -c1-12 || echo none)"
  TRUST_KEY="$ENGINE_HASH:$P_HASH:$SCHEMA"
  TRUST=; TRUST_WHY=
  if [ -r "$D/trust" ]; then IFS='|' read -r TRUST TRUST_WHY _tk _tt < "$D/trust"; [ "$_tk" = "$TRUST_KEY" ] || TRUST=; fi
  [ -n "$TRUST" ] || _selftest
}

# ---- recording ------------------------------------------------------------------------------
# One obs entry per knob whose lab state changed since the last entry, one ev entry per knob
# whose verdict changed. The outcome is reported as it is: recorded, unchanged, busy, no_lab,
# invalid_lab or error - never "recorded" when nothing was written.
REC=none
_record() {
  REC=none
  [ -r "$LAB" ] || { REC=no_lab; return 4; }
  grep -q '^kstat|' "$LAB" 2>/dev/null || grep -q '^knob|' "$LAB" 2>/dev/null || { REC=invalid_lab; return 5; }
  _lock || { REC=busy; return 3; }
  # Nothing is chained onto a damaged journal: it would bury the damage under valid entries.
  _verify inc
  if [ "$J_STATE" = damaged ]; then _unlock; REC=journal_damaged; return 7; fi
  _identity; _meter
  _snap="$(awk -F'|' '
    $1 == "knob" && (NF == 18 || NF == 20) && $2 ~ /^[a-z_0-9]+$/ { st[$2] = $3; be[$2] = $4; tr[$2] = $5; lv[$2] = (NF == 20 ? $19 : "-"); o[++c] = $2 }
    $1 == "kstat" && NF == 10 { n[$2] = $3; m[$2] = $4; v[$2] = $5; jp[$2] = $6; pr[$2] = $7; jk[$2] = $8; ht[$2] = $9; lb[$2] = $10 }
    END { for (i = 1; i <= c; i++) { k = o[i]
      p = sprintf("knob=%s;state=%s;best=%s;try=%s;n=%s;mean=%s;var=%s;jp=%s;press=%s;jank=%s;heat=%s;labv=%s;lab_build=%s;sv=2", k, st[k], be[k], tr[k], n[k], m[k], v[k], jp[k], pr[k], jk[k], ht[k], lv[k], lb[k])
      gsub(/[ \t]/, "_", p); print k, p } }' "$LAB")"
  _last="$D/last"; touch "$_last" 2>/dev/null
  _wrote=0; _fail=0
  _changed="$(printf '%s\n' "$_snap" | while read -r _k _p; do
    [ -n "$_k" ] || continue
    _p="$(printf '%s' "$_p" | _clean);id=$ID"
    if [ "$(awk -v k="obs:$_k" '$1 == k { print $2 }' "$_last")" != "$_p" ]; then
      if _append obs "$_p"; then
        awk -v k="obs:$_k" '$1 != k' "$_last" > "$_last.t"; printf 'obs:%s %s\n' "$_k" "$_p" >> "$_last.t"; mv -f "$_last.t" "$_last"; echo w
      else echo f; fi
    fi
  done)"
  case "$_changed" in *f*) _fail=1 ;; esac
  case "$_changed" in *w*) _wrote=1 ;; esac
  _trust; _sm=0; [ -e "$SAFE" ] && _sm=1
  _verify inc
  _evaluate "$LAB" "$J" "$TRUST" "$_sm" "$J_STATE" "$ID_OK" "$ID" "$METER" | \
  while IFS='|' read -r _e _k _st _be _tr _n _nb _m _sd _t _pr _jk _ht _v _w _lv _q _jpb; do
    _seg="$(printf '%s' "$_be/$_tr" | _clean)"
    _p="knob=$_k;verdict=$_v;why=$_w;n=$_n;nb=$_nb;t=$_t;quality=$_q;seg=$_seg;lab=$_st;labv=$_lv;policy=$P_HASH;trust=$TRUST;id=$ID"
    _key="$(printf '%s' "$_k;$_v;$_w;$_nb;$_seg" | _clean)"
    if [ "$(awk -v k="ev:$_k" '$1 == k { print $2 }' "$_last")" != "$_key" ]; then
      _append ev "$_p" && { awk -v k="ev:$_k" '$1 != k' "$_last" > "$_last.t"; printf 'ev:%s %s\n' "$_k" "$_key" >> "$_last.t"; mv -f "$_last.t" "$_last"; }
    fi
  done
  _trim
  _unlock
  printf '%s\n' "$(_now)" > "$D/observed" 2>/dev/null
  if [ "$_fail" = 1 ]; then REC=error; return 6; fi
  if [ "$_wrote" = 1 ]; then REC=recorded; else REC=unchanged; fi
  return 0
}

# ---- audit of the lab (the optimizer judged by its own record) ----------------------------
# A lab promotion is compared only with the evaluator's last verdict on the same knob, the same
# champion/challenger (the trial before the promotion) and the build the promotion was seen on: agreed, disputed, missing (no verdict was
# recorded, or the last one had too few pairs of its own to confirm or refute anything) or stale
# (the last verdict belongs to another trial or generation). A promotion found between two
# reads is never called a dispute just because the confirming read did not happen.
_audit() {
  [ -s "$J" ] || { echo 'audit|0|0|0|0|0|0'; return 0; }
  awk -F'|' -v min_pairs="${P_min_pairs:-6}" 'function kv(p, key,   n, a, i) { n = split(p, a, ";"); for (i = 1; i <= n; i++) if (index(a[i], key "=") == 1) return substr(a[i], length(key) + 2); return "" }
    NF < 6 { next }
    $3 == "ev" { k = kv($4, "knob"); ev[k] = kv($4, "verdict"); evs[k] = kv($4, "seg"); evi[k] = kv($4, "id"); evn[k] = kv($4, "nb") + 0 }
    $3 == "obs" { k = kv($4, "knob"); lv = kv($4, "labv")
      if (k in plv && lv != plv[k]) {
        if (lv == "won_energy") { won++
          if (!(k in ev)) missing++
          else if (evs[k] != pseg[k] || evi[k] != kv($4, "id")) stale++
          else if (ev[k] == "eligible_for_holdout") agree++
          else if (ev[k] == "rejected" || (ev[k] == "inconclusive" && evn[k] >= min_pairs)) dispute++
          else missing++ }
        else if (lv ~ /^lost_|^no_clear/) lost++
      }
      plv[k] = lv; pseg[k] = kv($4, "best") "/" kv($4, "try") }
    END { printf "audit|%d|%d|%d|%d|%d|%d\n", won, agree, dispute, missing, stale, lost }' "$J"
}

# ---- shadow advisor -------------------------------------------------------------------------
# At most one proposal, never applied: the lab already owns the schedule; this says which open
# question is closest to an answer and what it would cost to get there.
_advise() {  # ev lines on stdin
  awk -F'|' -v t_min="${P_t_min:-2.5}" -v min_gain="${P_min_gain:-0.03}" -v min_pairs="${P_min_pairs:-6}" '
    $1 != "ev" { next }
    # Fields: 2 knob, 3 lab state, 7 usable pairs, 9 pair SD, 14 verdict, 15 reason.
    $3 == "testing" && $14 == "inconclusive" && ($15 == "too_few_pairs" || $15 == "within_noise") {
      sd = $9 + 0; need = (sd > 0) ? int((t_min * sd / min_gain) ^ 2 + 0.999) : min_pairs
      if (need < min_pairs) need = min_pairs
      more = need - $7
      if (more <= 0) next
      if (bline == "" || more < bmore) { bline = $0; bmore = more }
      next
    }
    $3 == "testing" && $15 == "unproven_pair_identity" && fresh == "" { fresh = $0 }
    END {
      if (bline != "") { split(bline, f, "|"); printf "advice|%s|continue|%s|%s|%d|%.4f\n", f[2], f[4], f[5], bmore, f[9] + 0 }
      else if (fresh != "") { split(fresh, f, "|"); printf "advice|%s|new_generation|%s|%s|%d|0\n", f[2], f[4], f[5], min_pairs }
      else print "advice|-|none|-|-|0|0"
    }'
}

# The one pipeline every public command uses.
_guarded() {  # record_first(0|1)
  _policy; _identity; _meter; _trust; _sm=0; [ -e "$SAFE" ] && _sm=1
  if [ "$1" = 1 ]; then _record; else REC=not_requested; fi
  _verify inc
  EV="$(_evaluate "$LAB" "$J" "$TRUST" "$_sm" "$J_STATE" "$ID_OK" "$ID" "$METER")"
}

_status() {
  _guarded 1
  _obs="$(head -n 1 "$D/observed" 2>/dev/null | tr -cd '0-9')"
  echo 'version=2'
  echo 'stage=identity,journal,evaluator,selftest,shadow_advisor,integrity'
  echo 'stage_next=field_aa_not_started'
  echo "policy=$([ "$P_OK" = 1 ] && echo ok || echo invalid)"
  echo "policy_hash=$P_HASH"
  echo "min_pairs=${P_min_pairs:-6}"
  echo "engine_hash=$ENGINE_HASH"
  echo "identity=$ID"
  echo "identity_complete=$ID_OK"
  echo "trust=$TRUST"
  echo "trust_reason=$TRUST_WHY"
  echo "safe_mode=$_sm"
  if [ -r "$LAB" ]; then echo 'lab=present'; else echo 'lab=absent'; fi
  echo "meter=$METER"
  echo "field_aa=missing"
  echo "holdout=missing"
  echo "record=$REC"
  echo "observed_at=${_obs:-0}"
  echo "journal=$J_STATE"
  [ "$J_STATE" = damaged ] && echo "journal_bad=$J_BAD"
  echo "journal_entries=$( [ -s "$J" ] && wc -l < "$J" | tr -d ' ' || echo 0)"
  [ -n "$EV" ] && printf '%s\n' "$EV"
  printf '%s\n' "$EV" | _advise
  _audit
}

case "${1:-status}" in
  status) _status ;;
  record)
    _policy; _identity; _meter; _record; _rc=$?
    echo "result=$REC"; exit "$_rc" ;;
  evaluate) _guarded 0; [ -n "$EV" ] && printf '%s\n' "$EV"; true ;;
  selftest) _policy; _identity; _meter; rm -f "$D/trust" 2>/dev/null; _trust
    echo "trust=$TRUST"; echo "trust_reason=$TRUST_WHY"; echo "engine_hash=$ENGINE_HASH" ;;
  verify) _policy; _verify full; echo "journal=$J_STATE"; [ "$J_STATE" = damaged ] && echo "journal_bad=$J_BAD"; true ;;
  advise) _guarded 0; printf '%s\n' "$EV" | _advise ;;
  export)
    # Sanitized report: verdicts, reasons, identity hashes and the journal's shape. App slots
    # are named app1..app3 only; the lab's package names stay on the phone.
    _status | grep -E '^(version|stage|stage_next|policy|policy_hash|min_pairs|engine_hash|identity|identity_complete|trust|trust_reason|safe_mode|lab|meter|field_aa|holdout|record|observed_at|journal|journal_bad|journal_entries)=|^(ev|advice|audit)[|]' ;;
  clear)
    _lock || { echo 'result=busy'; exit 3; }
    rm -f "$J" "$J.tmp" "$D/anchor" "$D/verified" "$D/head" "$D/last" "$D/last.t" "$D/trust" "$D/observed" 2>/dev/null
    _unlock; _policy; _identity; _lock && { _append cleared "by=user;id=$ID"; _unlock; }
    echo 'result=cleared' ;;
  *) echo 'usage: asb_evolution.sh status|record|evaluate|selftest|advise|verify|export|clear' >&2; exit 2 ;;
esac
