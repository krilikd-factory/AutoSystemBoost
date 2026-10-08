#!/bin/sh
# WebUI tweak conflicts: choosing one side of a real contradiction switches the other side
# off in the same atomic write, so two cards can never both read "on" for a pair the
# runtime resolves behind the user's back. Dependencies are explained, never auto-enabled.
# Executable fixture: the REAL rule tables and resolver functions under node.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL cfg conflicts: $*" >&2; exit 1; }

grep -q "const _fix = cfgConflictResolve(key, val, cfgCurVal);" "$H" || fail "cfgSet does not resolve conflicts"
grep -q "' set-many --snapshot ' + shQuote(snap) + ' ' +" "$H" || fail "no atomic set-many write"
grep -Fq "_fix.map(function(c) { return ' ' + shQuote(c.key) + ' ' + shQuote(c.val); }).join('')" "$H" || fail "counterparts not in the same write"
grep -Fq "_fix.forEach(function(c) { _cfgVals[c.key] = c.val; });" "$H" || fail "UI state not updated for the switched-off card"
grep -Fq "(AUDIO_DSP_KEYS.indexOf(key) >= 0 && !_fix.length) ? ' dsp' : ''" "$H" || fail "a resolved audio_profile change would take the DSP-only path"
# The pair is real: the runtime resolves it the same way.
grep -q 'eq_compat wins and the DSP is turned off outright' "$ROOT/runtime/asb_audio_apply.sh" || fail "eq_compat/DSP precedence gone from runtime - re-check the rule"
grep -q '_radio_policy_enabled' "$ROOT/runtime/asb_lpm.sh" || fail "night_modem_idle dependency no longer real"
for f in "$ROOT"/webroot/i18n/*.json; do
  for k in t_cfg_conflict_off t_cfg_needs t_cfg_idle; do
    grep -q "\"$k\"" "$f" || fail "$(basename "$f") lacks $k"
  done
done

command -v node >/dev/null 2>&1 || { echo "PASS cfg conflicts contract (no node: source pins only)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  sed -n '/^const CFG_ITEMS = \[/,/^\];/p' "$H"
  sed -n '/^const CFG_CONFLICTS = \[/,/^\];/p' "$H"
  sed -n '/^const CFG_REQUIRES = \[/,/^\];/p' "$H"
  for fn in cfgConflictResolve cfgRequireNotes cfgDefOf; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
let bad = 0;
const keys = CFG_ITEMS.map(function(x) { return x.key; });
function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
CFG_CONFLICTS.forEach(function(r) {
  [r.a, r.b].forEach(function(s) {
    chk(keys.indexOf(s.key) >= 0, 'conflict key ' + s.key + ' is not a setting');
    chk(!s.on(s.off), 'off value of ' + s.key + ' still counts as on');
  });
});
CFG_REQUIRES.forEach(function(r) {
  chk(keys.indexOf(r.key) >= 0 && keys.indexOf(r.needs) >= 0, 'requires keys unknown: ' + r.key);
});
function cur(map) { return function(k) { return (k in map) ? map[k] : cfgDefOf(k); }; }
let x = cfgConflictResolve('dsp_loudness', '6', cur({ audio_profile:'eq_compat' }));
chk(x.length === 1 && x[0].key === 'audio_profile' && x[0].val === 'stock', 'DSP on did not switch EQ profile off: ' + JSON.stringify(x));
x = cfgConflictResolve('audio_profile', 'eq_compat', cur({ dsp_loudness:'12' }));
chk(x.length === 1 && x[0].key === 'dsp_loudness' && x[0].val === '0', 'EQ profile did not switch DSP off: ' + JSON.stringify(x));
chk(cfgConflictResolve('audio_profile', 'hifi', cur({ dsp_loudness:'12' })).length === 0, 'hifi is not a conflict');
chk(cfgConflictResolve('dsp_loudness', '0', cur({ audio_profile:'eq_compat' })).length === 0, 'DSP off is not a conflict');
chk(cfgConflictResolve('dsp_loudness', '6', cur({ audio_profile:'stock' })).length === 0, 'no conflict with stock');
chk(cfgConflictResolve('disable_blur', '1', cur({})).length === 0, 'unrelated key touched');
let n = cfgRequireNotes('night_modem_idle', '1', cur({ radio_policy_enable:'0' }));
chk(n.length === 1 && n[0].kind === 'needs' && n[0].other === 'radio_policy_enable', 'missing master not noted');
chk(cfgRequireNotes('night_modem_idle', '1', cur({ radio_policy_enable:'1' })).length === 0, 'note with master on');
n = cfgRequireNotes('dsp_loudness', '0', cur({ dsp_bass:'5' }));
chk(n.length === 1 && n[0].kind === 'idle' && n[0].key === 'dsp_bass', 'bass left idle not noted');
chk(cfgRequireNotes('heavy_prime_escape', '0', cur({})).length === 0, 'default burst/rest noted as idle');
chk(cfgRequireNotes('doze_trim_whitelist', '1', cur({ doze_level:'night' })).length === 0, 'night doze satisfies trim');
process.exit(bad);
EOF
} > "$TMP/t.js"
node "$TMP/t.js" || fail "resolver fixture failed"
echo "PASS cfg conflicts contract"
