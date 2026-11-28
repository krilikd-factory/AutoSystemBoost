#!/system/bin/sh
# ASB Evolution Engine, stages 0-3: identity, an append-only experiment journal, a read-only
# evaluator that checks itself, and a shadow advisor. It never writes a system setting.
#
# The experiments are the Smart lab's own (src/asb_lab.h): one existing knob at a time, champion
# against one challenger, side by side, with the governor as the only owner of every write and
# its restore. This script is the independent half the plan asks for:
#   - Evaluator: recomputes each verdict from the lab's raw pair statistics (kstat lines) under
#     the shipped constitution (asb_evolution.policy), hard gates before energy, and says
#     promoted / rejected / inconclusive / held / blocked with a reason. It cannot apply anything.
#   - Self-check: synthetic fixtures with known answers, a no-op among them. One misjudged
#     fixture marks the evaluator untrusted and every verdict becomes held until it passes.
#   - Journal: what the lab did and what the evaluator said, hash-chained, bounded in entries and
#     age, with the build identity (source commit, payload hash, ROM/kernel) on every entry.
#     Entries are never rewritten; a damaged chain is reported and its verdicts are not trusted.
#   - Advisor: proposes at most one next step, with its hypothesis and cost. It applies nothing.
#
# No timer or worker: it runs only when asked (WebUI, asbdiag, export). Nothing it stores names
# an account, a serial, a network or the content of an app.
#
#   sh asb_evolution.sh status | record | evaluate | selftest | advise | verify | export | clear
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D="${ASB_EVO_DIR:-/data/adb/asb/evolution}"
LAB="${ASB_EVO_LAB:-/dev/.asb/smart_lab.txt}"
POLICY="${ASB_EVO_POLICY:-$MODDIR/runtime/asb_evolution.policy}"
SAFE="${ASB_EVO_SAFE:-/dev/.asb/safe_mode}"
MANIFEST="${ASB_EVO_MANIFEST:-$MODDIR/release-manifest.json}"
J="$D/journal"
KNOBS='radio wake_lift membus_on membus_off app1 app2 app3'

_now() { case "${ASB_EVO_NOW:-}" in ''|*[!0-9]*) date +%s 2>/dev/null || echo 0 ;; *) echo "$ASB_EVO_NOW" ;; esac; }
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else cksum | tr -c '0-9\n' ' ' | awk '{ printf "ck%s\n", $1 }'; fi; }
_clean() { tr ' ' '_' | tr -cd 'A-Za-z0-9_.:=,;+%-'; }

# ---- constitution ---------------------------------------------------------------------------
P_OK=0; P_HASH=none
_policy() {
  P_OK=0; P_HASH=none
  [ -r "$POLICY" ] || return 1
  P_HASH="$(_sha < "$POLICY" | cut -c1-12)"
  eval "$(awk -F= -v known=" $KNOBS " '
    /^[[:space:]]*#/ || !NF { next }
    { k = $1; v = substr($0, length($1) + 2) }
    k == "schema" && v == "1" { s = 1 }
    k == "allow" { n = split(v, a, ","); ok = n > 0
      for (i = 1; i <= n; i++) if (index(known, " " a[i] " ") == 0) ok = 0
      if (ok) allow = v }
    k ~ /^(min_pairs|journal_max|retention_days)$/ && v ~ /^[1-9][0-9]*$/ { num[k] = v }
    k ~ /^(min_gain|t_min|dearer|max_press|max_jank|max_heat)$/ && v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 > 0 { num[k] = v }
    END {
      # Floors: the file may tighten a rule, never loosen it below the lab'"'"'s own (src/asb_lab.h).
      if (num["t_min"] + 0 < 2.5 || num["min_gain"] + 0 < 0.03 || num["min_pairs"] + 0 < 6 ||
          num["dearer"] + 0 > 0.15 || num["max_press"] + 0 > 0.08 || num["max_jank"] + 0 > 0.01 ||
          num["max_heat"] + 0 > 15 || num["journal_max"] + 0 < 4 || num["journal_max"] + 0 > 4000 ||
          num["retention_days"] + 0 > 365) s = 0
      need = "min_pairs journal_max retention_days min_gain t_min dearer max_press max_jank max_heat"
      m = split(need, w, " "); good = s && allow != ""
      for (i = 1; i <= m; i++) { if (!(w[i] in num)) good = 0; else printf "P_%s=%s\n", w[i], num[w[i]] }
      printf "P_ALLOW=%s\nP_GOOD=%d\n", allow, good
    }' "$POLICY" 2>/dev/null)"
  [ "${P_GOOD:-0}" = 1 ] && P_OK=1
  [ "$P_OK" = 1 ]
}

# ---- build identity -------------------------------------------------------------------------
_identity() {
  _src="$(sed -n 's/.*"source_commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$MANIFEST" 2>/dev/null | head -n 1)"
  _pay="$(sed -n 's/.*"payload_sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" 2>/dev/null | head -n 1)"
  # ROM and kernel as one opaque short hash: a change asks for re-validation, nothing more.
  _env="$( { getprop ro.build.fingerprint 2>/dev/null; uname -r 2>/dev/null; } | _sha | cut -c1-10)"
  ID="$(printf '%s' "${_src:-unknown}" | cut -c1-12):$(printf '%s' "${_pay:-unknown}" | cut -c1-12):${_env:-unknown}"
  case "$ID" in unknown:*|*:unknown:*) ID_OK=0 ;; *) ID_OK=1 ;; esac
}

# ---- journal --------------------------------------------------------------------------------
# One writer at a time, without waiting: a page or a report that finds the journal busy skips
# its recording (the next read records the same state). A lock older than a minute belongs to
# a run that was killed and is cleared, so an interruption cannot stop recording for good.
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
  set -- "$1" "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_.:=,;+%-')"
  _r="$(_tail_ref)"; _ps="${_r%% *}"; _ph="${_r#* }"
  case "$_ps" in ''|*[!0-9]*) return 1 ;; esac
  _body="$((_ps + 1))|$(_now)|$1|$2|$_ph"
  printf '%s|%s\n' "$_body" "$(printf '%s' "$_body" | _sha)" >> "$J"
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
# Verify the chain from the anchor (full) or from the last verified entry (incremental).
J_STATE=empty; J_BAD=0
_verify() {
  J_STATE=empty; J_BAD=0
  [ -s "$J" ] || return 0
  _from=0; _prev=genesis
  if [ -s "$D/anchor" ]; then read -r _from _prev < "$D/anchor"; fi
  _skip=0
  if [ "$1" != full ] && [ -s "$D/verified" ]; then
    read -r _vs _vh < "$D/verified"
    if awk -F'|' -v s="$_vs" -v h="$_vh" '$1 == s && $NF == h { f = 1 } END { exit !f }' "$J"; then
      _from="$_vs"; _prev="$_vh"; _skip="$_vs"
    fi
  fi
  J_STATE=ok
  while IFS= read -r _l; do
    # \| : an unquoted | in a pattern is alternation under mksh (Android's sh), literal in dash.
    _s="${_l%%\|*}"
    case "$_s" in ''|*[!0-9]*) J_STATE=damaged; J_BAD=unparsable; break ;; esac
    [ "$_s" -le "$_skip" ] && continue
    _h="${_l##*\|}"; _b="${_l%\|*}"; _p="${_b##*\|}"
    if [ "$_s" != "$((_from + 1))" ] || [ "$_p" != "$_prev" ] || [ "$(printf '%s' "$_b" | _sha)" != "$_h" ]; then
      J_STATE=damaged; J_BAD="$_s"; break
    fi
    _from="$_s"; _prev="$_h"
  done < "$J"
  [ "$J_STATE" = ok ] && printf '%s %s\n' "$_from" "$_prev" > "$D/verified" 2>/dev/null
  return 0
}

# ---- evaluator ------------------------------------------------------------------------------
# One awk program judges the live lab file and the fixtures alike: the self-check exercises
# exactly the code that judges the phone.
EVAL_AWK='
function kv(p, key,   n, a, i) { n = split(p, a, ";"); for (i = 1; i <= n; i++) if (index(a[i], key "=") == 1) return substr(a[i], length(key) + 2); return "" }
FILENAME == jf {
  if (split($0, f, "|") < 6 || f[3] != "obs") next
  k = kv(f[4], "knob"); seg = kv(f[4], "best") "/" kv(f[4], "try")
  if (kv(f[4], "n") + 0 == 0 || seg != segk[k]) { ids[k] = ""; segk[k] = seg }
  i = kv(f[4], "id"); if (index(" " ids[k] " ", " " i " ") == 0) ids[k] = ids[k] " " i
  next
}
$1 == "knob" && (NF == 18 || NF == 20) { st[$2] = $3; be[$2] = $4; tr[$2] = $5; lv[$2] = (NF == 20 ? $19 : "-"); seen[$2] = 1; next }
$1 == "kstat" && NF == 10 { n[$2] = $3 + 0; m[$2] = $4 + 0; v[$2] = $5 + 0; jp[$2] = $6 + 0; pr[$2] = $7 + 0; jk[$2] = $8 + 0; ht[$2] = $9 + 0; ks[$2] = 1; next }
END {
  na = split(allow, al, ",")
  for (q = 1; q <= na; q++) {
    k = al[q]; if (!(k in seen)) continue
    verdict = "inconclusive"; why = "-"; t = 0; sd = 0
    if (k in ks) { sd = (v[k] > 0) ? sqrt(v[k]) : 0; t = (sd > 0 && n[k] > 0) ? -m[k] / (sd / sqrt(n[k])) : (m[k] < 0 ? 99 : (m[k] > 0 ? -99 : 0)) }
    # The lab exempts the screen-off bus and the wake lift from the warming gate; so does this.
    heatgate = (k != "membus_off" && k != "wake_lift")
    if (!policy_ok) { verdict = "blocked"; why = "policy_invalid" }
    else if (st[k] == "off" || st[k] == "free") { verdict = "blocked"; why = (st[k] == "free" ? "no_app_assigned" : "lab_off") }
    else if (!(k in ks)) { verdict = "blocked"; why = "no_pair_statistics" }
    else if (safe) { verdict = "held"; why = "safe_mode" }
    else if (trust != "trusted") { verdict = "held"; why = "evaluator_untrusted" }
    else if (n[k] == 0) { verdict = "inconclusive"; why = (tr[k] == "-" ? "no_challenger" : "no_pairs_yet") }
    else if (split(ids[k], z, " ") > 1) { verdict = "inconclusive"; why = "mixed_build_identity" }
    else if (n[k] >= 3 && m[k] >= dearer) { verdict = "rejected"; why = "dearer" }
    else if (n[k] < min_pairs) { verdict = "inconclusive"; why = "too_few_pairs" }
    else if (pr[k] > max_press) { verdict = "rejected"; why = "gate_ceiling" }
    else if (jp[k] > 0 && jk[k] > max_jank) { verdict = "rejected"; why = "gate_jank" }
    else if (heatgate && ht[k] > max_heat) { verdict = "rejected"; why = "gate_heat" }
    else if (m[k] <= -min_gain && t >= t_min) { verdict = "promoted"; why = "cheaper_significant" }
    else if (t <= -t_min) { verdict = "rejected"; why = "dearer_significant" }
    else { verdict = "inconclusive"; why = "within_noise" }
    printf "ev|%s|%s|%s|%s|%d|%.4f|%.4f|%.2f|%.4f|%.4f|%.1f|%s|%s|%s\n", k, st[k], be[k], tr[k], n[k], m[k], sd, t, pr[k], jk[k], ht[k], verdict, why, lv[k]
  }
}'
_evaluate() {  # lab_file journal_file trust safe
  set -- "$1" "$( [ -r "$2" ] && printf '%s' "$2" || printf /dev/null)" "$3" "$4"
  [ -r "$1" ] || return 0
  awk -F'|' -v jf="$2" -v allow="$P_ALLOW" -v policy_ok="$P_OK" -v trust="$3" -v safe="$4" \
    -v min_pairs="${P_min_pairs:-6}" -v min_gain="${P_min_gain:-0.03}" -v t_min="${P_t_min:-2.5}" \
    -v dearer="${P_dearer:-0.15}" -v max_press="${P_max_press:-0.08}" -v max_jank="${P_max_jank:-0.01}" \
    -v max_heat="${P_max_heat:-15}" "$EVAL_AWK" "$2" "$1" 2>/dev/null
}

# Synthetic fixtures with known answers. They are part of the shipped code and are never
# adjusted to match an output: a mismatch is a defect of the evaluator, reported as such.
_selftest() {
  _t="$D/.selftest.$$"; mkdir -p "$_t" 2>/dev/null || return 1
  _k() { printf 'knob|%s|testing|a|b|%s|0|0|0|0|0|0|0|0|0|0|0|-|-|-1\nkstat|%s|%s|%s|%s|%s|%s|%s|%s|1\n' "$1" "$2" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; }
  {
    _k radio 16 0.001 0.0009 0 0.01 0 0              # no-op: pure noise must not be promoted
    _k wake_lift 6 -0.031 0.0036 0 0.01 0 0          # a lucky small "gain" inside the noise
    _k membus_on 8 -0.06 0.0004 4 0.01 0.002 2       # a clear, clean saving
    _k membus_off 8 -0.06 0.0004 4 0.01 0.02 0       # the same saving with more janky frames
    _k app1 3 0.20 0.0004 0 0.01 0 0                 # plainly dearer
    _k app2 4 -0.08 0.0001 0 0.01 0 0                # too few pairs to decide
    _k app3 7 -0.06 0.0004 0 0.01 0 3                # clean, but measured on two builds
  } > "$_t/lab"
  printf '1|1|obs|knob=app3;best=a;try=b;n=3;id=aaa:bbb:env1|genesis|x\n2|2|obs|knob=app3;best=a;try=b;n=7;id=aaa:ccc:env1|x|y\n' > "$_t/j"
  _want='radio=inconclusive:within_noise wake_lift=inconclusive:within_noise membus_on=promoted:cheaper_significant membus_off=rejected:gate_jank app1=rejected:dearer app2=inconclusive:too_few_pairs app3=inconclusive:mixed_build_identity'
  _got="$(_evaluate "$_t/lab" "$_t/j" trusted 0 | awk -F'|' '{ printf "%s%s=%s:%s", (NR > 1 ? " " : ""), $2, $13, $14 }')"
  # A lab line without pair statistics is blocked, never judged from the summary alone.
  printf 'knob|radio|testing|a|b|5|0|0|0|0|0|0|0|0|0|0|0|-|-|-1\n' > "$_t/old"
  _old="$(_evaluate "$_t/old" "$_t/none" trusted 0 | cut -d'|' -f13,14)"
  rm -rf "$_t"
  if [ "$P_OK" != 1 ]; then TRUST=untrusted; TRUST_WHY=policy_invalid
  elif [ "$_got" != "$_want" ]; then
    TRUST=untrusted
    TRUST_WHY="fixture:$(printf '%s\n%s\n' "$_want" "$_got" | tr ' ' '\n' | sort | uniq -u | head -n 1 | cut -d= -f1)"
  elif [ "$_old" != 'blocked|no_pair_statistics' ]; then TRUST=untrusted; TRUST_WHY=fixture:no_stats
  else TRUST=trusted; TRUST_WHY=fixtures_passed; fi
  mkdir -p "$D" 2>/dev/null && printf '%s|%s|%s|%s\n' "$TRUST" "$TRUST_WHY" "$P_HASH" "$(_now)" > "$D/trust" 2>/dev/null
}
_trust() {  # reuse a passed self-check only for the same constitution
  TRUST=; TRUST_WHY=
  if [ -r "$D/trust" ]; then IFS='|' read -r TRUST TRUST_WHY _th _tt < "$D/trust"; [ "$_th" = "$P_HASH" ] || TRUST=; fi
  [ -n "$TRUST" ] || _selftest
}

# ---- recording ------------------------------------------------------------------------------
# One obs entry per knob whose lab state changed since the last entry, one ev entry per knob
# whose independent verdict changed. A quiet phone adds nothing.
_record() {
  [ -r "$LAB" ] || return 0
  _lock || return 0
  _identity
  # Arm names carry spaces ("LTE on light traffic"): underscores keep one knob on one word.
  _snap="$(awk -F'|' '
    $1 == "knob" && (NF == 18 || NF == 20) && $2 ~ /^[a-z_0-9]+$/ { st[$2] = $3; be[$2] = $4; tr[$2] = $5; lv[$2] = (NF == 20 ? $19 : "-"); o[++c] = $2 }
    $1 == "kstat" && NF == 10 { n[$2] = $3; m[$2] = $4; v[$2] = $5; pr[$2] = $7; jk[$2] = $8; ht[$2] = $9; lb[$2] = $10 }
    END { for (i = 1; i <= c; i++) { k = o[i]
      p = sprintf("knob=%s;state=%s;best=%s;try=%s;n=%s;mean=%s;var=%s;press=%s;jank=%s;heat=%s;labv=%s;lab_build=%s", k, st[k], be[k], tr[k], n[k], m[k], v[k], pr[k], jk[k], ht[k], lv[k], lb[k])
      gsub(/[ \t]/, "_", p); print k, p } }' "$LAB")"
  _last="$D/last"; touch "$_last" 2>/dev/null
  printf '%s\n' "$_snap" | while read -r _k _p; do
    [ -n "$_k" ] || continue
    _p="$(printf '%s' "$_p" | _clean);id=$ID"
    if [ "$(awk -v k="$_k" '$1 == "obs:" k { print $2 }' "$_last")" != "$_p" ]; then
      _append obs "$_p" && { awk -v k="obs:$_k" '$1 != k' "$_last" > "$_last.t"; printf 'obs:%s %s\n' "$_k" "$_p" >> "$_last.t"; mv -f "$_last.t" "$_last"; }
    fi
  done
  _trust; _sm=0; [ -e "$SAFE" ] && _sm=1
  _evaluate "$LAB" "$J" "$TRUST" "$_sm" | while IFS='|' read -r _e _k _st _be _tr _n _m _sd _t _pr _jk _ht _v _w _lv; do
    _p="knob=$_k;verdict=$_v;why=$_w;n=$_n;t=$_t;lab=$_st;labv=$_lv;policy=$P_HASH;trust=$TRUST;id=$ID"
    _key="$(printf '%s' "$_k;$_v;$_w;$_n" | _clean)"
    if [ "$(awk -v k="ev:$_k" '$1 == k { print $2 }' "$_last")" != "$_key" ]; then
      _append ev "$_p" && { awk -v k="ev:$_k" '$1 != k' "$_last" > "$_last.t"; printf 'ev:%s %s\n' "$_k" "$_key" >> "$_last.t"; mv -f "$_last.t" "$_last"; }
    fi
  done
  _trim
  _unlock
}

# ---- audit of the lab (the optimizer judged by its own record) ----------------------------
# A lab promotion counts as agreed when the evaluator's last verdict on that knob before it was
# promoted, disputed when it was anything else on data, unverified when nothing was recorded.
_audit() {
  [ -s "$J" ] || { echo 'audit|0|0|0|0|0'; return 0; }
  awk -F'|' 'function kv(p, key,   n, a, i) { n = split(p, a, ";"); for (i = 1; i <= n; i++) if (index(a[i], key "=") == 1) return substr(a[i], length(key) + 2); return "" }
    NF < 6 { next }
    $3 == "ev" { k = kv($4, "knob"); last[k] = kv($4, "verdict") }
    $3 == "obs" { k = kv($4, "knob"); lv = kv($4, "labv")
      if (k in plv && lv != plv[k]) {
        if (lv == "won_energy") { won++; if (last[k] == "promoted") agree++; else if (last[k] != "") dispute++; else unver++ }
        else if (lv ~ /^lost_|^no_clear/) lost++
      }
      plv[k] = lv }
    END { printf "audit|%d|%d|%d|%d|%d\n", won, agree, dispute, unver, lost }' "$J"
}

# ---- shadow advisor -------------------------------------------------------------------------
# At most one proposal, never applied: the lab already owns the schedule; this says which open
# question is closest to an answer and what it would cost to get there.
_advise() {  # ev lines on stdin
  awk -F'|' -v t_min="${P_t_min:-2.5}" -v min_gain="${P_min_gain:-0.03}" -v min_pairs="${P_min_pairs:-6}" '
    $1 != "ev" { next }
    $13 == "held" || $13 == "blocked" { next }
    # Fields: 2 knob, 3 lab state, 6 pairs, 8 pair SD, 13 verdict, 14 reason. Pairs needed to see
    # the smallest gain that may promote at this spread; a trial already past it sits in the
    # noise and more pairs will not decide it (the lab closes it as no clear saving).
    $3 == "testing" && $13 == "inconclusive" && $14 != "mixed_build_identity" {
      sd = $8 + 0; need = (sd > 0) ? int((t_min * sd / min_gain) ^ 2 + 0.999) : min_pairs
      if (need < min_pairs) need = min_pairs
      more = need - $6
      if (more <= 0) next
      if (bline == "" || more < bmore) { bline = $0; bmore = more }
      next
    }
    $14 == "mixed_build_identity" && mixed == "" { mixed = $0 }
    END {
      if (bline != "") { split(bline, f, "|")
        printf "advice|%s|continue|%s|%s|%d|%.4f\n", f[2], f[4], f[5], bmore, f[8] + 0 }
      else if (mixed != "") { split(mixed, f, "|"); printf "advice|%s|restart_after_update|%s|%s|0|0\n", f[2], f[4], f[5] }
      else print "advice|-|none|-|-|0|0"
    }'
}

_status() {
  _policy; _identity; _trust; _sm=0; [ -e "$SAFE" ] && _sm=1
  _record
  _verify inc
  echo 'version=1'
  echo "stage=identity,journal,evaluator,selftest,shadow_advisor"
  echo "stage_next=manual_aba_not_started"
  echo "policy=$([ "$P_OK" = 1 ] && echo ok || echo invalid)"
  echo "policy_hash=$P_HASH"
  echo "identity=$ID"
  echo "identity_complete=$ID_OK"
  echo "trust=$TRUST"
  echo "trust_reason=$TRUST_WHY"
  echo "safe_mode=$_sm"
  if [ -r "$LAB" ]; then echo 'lab=present'; else echo 'lab=absent'; fi
  echo "journal=$J_STATE"
  [ "$J_STATE" = damaged ] && echo "journal_bad=$J_BAD"
  echo "journal_entries=$( [ -s "$J" ] && wc -l < "$J" | tr -d ' ' || echo 0)"
  _ev="$(_evaluate "$LAB" "$J" "$TRUST" "$_sm")"
  # A damaged journal cannot vouch for identity continuity: no promotion stands on it.
  if [ "$J_STATE" = damaged ]; then _ev="$(printf '%s\n' "$_ev" | awk -F'|' 'BEGIN { OFS = "|" } $13 == "promoted" { $13 = "held"; $14 = "journal_damaged" } { print }')"; fi
  [ -n "$_ev" ] && printf '%s\n' "$_ev"
  printf '%s\n' "$_ev" | _advise
  _audit
}

case "${1:-status}" in
  status) _status ;;
  record) _policy; _record; echo 'result=recorded' ;;
  evaluate) _policy; _identity; _trust; _sm=0; [ -e "$SAFE" ] && _sm=1; _evaluate "$LAB" "$J" "$TRUST" "$_sm" ;;
  selftest) _policy; _selftest; echo "trust=$TRUST"; echo "trust_reason=$TRUST_WHY" ;;
  verify) _policy; _verify full; echo "journal=$J_STATE"; [ "$J_STATE" = damaged ] && echo "journal_bad=$J_BAD"; true ;;
  advise) _policy; _identity; _trust; _sm=0; [ -e "$SAFE" ] && _sm=1; _evaluate "$LAB" "$J" "$TRUST" "$_sm" | _advise ;;
  export)
    # Sanitized report: verdicts, reasons, identity hashes and the journal's shape. App slots
    # are named app1..app3 only; the lab's package names stay on the phone.
    _status | grep -E '^(version|stage|stage_next|policy|policy_hash|identity|identity_complete|trust|trust_reason|safe_mode|lab|journal|journal_bad|journal_entries)=|^(ev|advice|audit)[|]' ;;
  clear)
    _lock || { echo 'result=busy'; exit 1; }
    rm -f "$J" "$J.tmp" "$D/anchor" "$D/verified" "$D/last" "$D/last.t" "$D/trust" 2>/dev/null
    _unlock; _policy; _identity; _lock && { _append cleared "by=user;id=$ID"; _unlock; }
    echo 'result=cleared' ;;
  *) echo 'usage: asb_evolution.sh status|record|evaluate|selftest|advise|verify|export|clear' >&2; exit 2 ;;
esac
