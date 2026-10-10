#!/usr/bin/env bash
# Source-pin contracts bundled into one script (fix98).
#
# Each section is one former tests/test_<name>.sh, verbatim, run in its own subshell so
# its variables, traps and early "exit 0" skips stay local. They were ~40 separate files
# of 10-200 ms each; the runtime tests that wait on real timers stay separate so the
# parallel regression runner can overlap them. Add a new source-pin contract as a new
# section here rather than a new file.

# ==== action_helper_order_contract ====================================================================
(
# Contract: action.sh never calls a helper before the line that defines it.
# A fix44 block called _st above its definition and the report printed "_st: not found".
set -u
A="$(cd "$(dirname "$0")/.." && pwd)/action.sh"
fail=0
for h in _st _cfg _feat _s _f _join; do
  d="$(grep -n "^$h() *{" "$A" | head -1 | cut -d: -f1)"
  [ -n "$d" ] || continue
  u="$(grep -nE "(\\\$\\(|^[[:space:]]*|[;&|] *)$h " "$A" | grep -v "^$d:" | head -1 | cut -d: -f1)"
  [ -n "$u" ] && [ "$u" -lt "$d" ] && { echo "FAIL action helper order: $h used on line $u, defined on line $d" >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "PASS action helper order"
exit "$fail"

) || { echo "FAIL in bundled contract: action_helper_order_contract" >&2; exit 1; }

# ==== action_i18n_contract ====================================================================
(
# Contract: action.sh report translations.
#
# Every runtime/i18n/action_<lang>.sh must cover every T_* key action.sh defines, with
# the same printf placeholders in the same number - a missing %s shifts every value after
# it, and a bare % makes printf eat the rest of the line. No translation may contain a
# backslash, a backtick or "$(" - the files are sourced, not parsed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$ROOT/action.sh"
DIR="$ROOT/runtime/i18n"
fail=0
f() { echo "FAIL: $*" >&2; fail=1; }

# One awk pass per language: placeholder COUNTS (%s, %%, any other %), not order -
# Turkish writes the percent sign before the number ("%%%s").
_awk='
function sig(v,  r, n1, n2, n3) {
  r = v; n2 = gsub(/%%/, "", r); n1 = gsub(/%s/, "", r); n3 = gsub(/%/, "", r)
  return "s=" n1 " pct=" n2 " bare=" n3
}
function val(line,  v) { v = line; sub(/^[A-Z0-9_]+="/, "", v); sub(/"[[:space:]]*$/, "", v); return v }
FNR == NR { if ($0 ~ /^T_[A-Z0-9_]+="/) { k = $0; sub(/=.*/, "", k); if (!(k in en)) { en[k] = val($0); order[++n] = k } } next }
$0 ~ /^T_[A-Z0-9_]+="/ { k = $0; sub(/=.*/, "", k); tr[k] = val($0) }
END {
  if (n == 0) { print "no T_* defaults in action.sh"; exit }
  for (i = 1; i <= n; i++) { k = order[i]
    if (!(k in tr)) { print lang ": missing " k; continue }
    if (sig(tr[k]) != sig(en[k])) print lang ": " k " placeholders " sig(tr[k]) " != en " sig(en[k])
  }
  for (k in tr) if (!(k in en)) print lang ": unknown key " k
}'

for lang in ru uk de es pt tr id fr hy it ar zh; do
  file="$DIR/action_${lang}.sh"
  [ -f "$file" ] || { f "missing $file"; continue; }
  sh -n "$file" 2>/dev/null || f "$lang: syntax error"
  if grep -nE '\\|`|\$\(' "$file" | grep -v '^[0-9]*:#' >/dev/null; then f "$lang: shell-unsafe character"; fi
  _out="$(awk -v lang="$lang" "$_awk" "$ACTION" "$file")"
  [ -z "$_out" ] || { echo "$_out" | while IFS= read -r l; do echo "FAIL: $l" >&2; done; fail=1; }
  # Indonesian has no learning-block strings in action.sh itself; its file must carry them.
  if [ "$lang" = id ]; then
    for k in M_CONF_LOW M_SLOT M_DP0 M_WEEKDAY M_W_HOT; do
      grep -qE "(^|[; ])$k=" "$file" || f "id: missing $k"
    done
  fi
done

grep -q 'runtime/i18n/action_${_asb_lang}.sh' "$ACTION" || f "action.sh does not load the translation file"

[ "$fail" = 0 ] && echo "PASS: action i18n contract"
exit "$fail"

) || { echo "FAIL in bundled contract: action_i18n_contract" >&2; exit 1; }

# ==== asb_state_dir_fixes_contract ====================================================================
(
# fix88: findings from an OP15 /data/adb/asb snapshot.
#  - gpu_pwrlevel_floor was a one-time snapshot of max_pwrlevel (9 of 18, ASB's own earlier
#    write) that clamped every profile apply; the live thermal level is the vendor limit.
#  - capabilities.env said dsp_soundfx=0 with the effect audible: the probe runs before the
#    overlay is mounted, so the module's staged copy has to count.
#  - every Smart session was conf=low / sig=mixed (500 of 500).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL asb state-dir fixes: $*" >&2; exit 1; }
grep -Fq 'rm -f /data/adb/asb/gpu_pwrlevel_floor' "$ROOT/service.sh" || fail "stale GPU floor snapshot not removed"
grep -Fq '_vfloor="$(cat /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 2>/dev/null)"' "$ROOT/service.sh" || fail "GPU floor not taken from the live thermal level"
grep -q 'cat "\$_floor_file"' "$ROOT/service.sh" && fail "service.sh still reads the snapshot"
grep -Fq '"$MODDIR/system/vendor/lib64/soundfx"' "$ROOT/runtime/asb_capabilities.sh" || fail "capability probe ignores the staged DSP library"
G="$ROOT/src/asb_governor.c"
grep -Fq 'static int asb_smart_session_idle_dominant(' "$G" || fail "Smart session idle/active split missing"
awk '/^static const char \*classify_confidence\(/,/^}$/' "$G" | grep -q 'PROFILE_SMART' || fail "Smart has no confidence branch"
awk '/^static const char \*classify_signature\(/,/^}$/' "$G" | grep -q 'PROFILE_SMART' || fail "Smart has no signature branch"
grep -Fq "asb_settings_put global dropbox_max_files 50" "$ROOT/service.sh" || fail "dropbox still capped so low that crash evidence is lost"
echo "PASS /data/adb/asb findings: GPU floor, DSP capability, Smart session labels"

) || { echo "FAIL in bundled contract: asb_state_dir_fixes_contract" >&2; exit 1; }

# ==== audio_live_player_contract ====================================================================
(
# Contract + fixture: "something is playing" means a live AudioPlaybackConfiguration line.
# History lines and idle players must not count (external audit fix44, P2).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL audio live player: $*" >&2; fail=1; }
RX='AudioPlaybackConfiguration .*state:started'
live='  AudioPlaybackConfiguration piid:79 deviceIds:[2] type:android.media.MediaPlayer u/pid:10652/9876 state:started attr:AudioAttributes: usage=USAGE_MEDIA'
idle='  AudioPlaybackConfiguration piid:80 deviceIds:[] type:AAudio u/pid:10658/1234 state:paused attr:AudioAttributes: usage=USAGE_MEDIA'
hist='  10-07 12:01:02:123 player piid:63 state:started'
hist2='  10-07 12:01:02:123 player piid:63 event:started'
printf '%s\n' "$live" | grep -qE "$RX" || f "live player not recognised"
printf '%s\n%s\n%s\n' "$idle" "$hist" "$hist2" | grep -qE "$RX" && f "idle player or history counted as playing"
for file in runtime/asb_screenoff_class.sh service.sh tools/asb_diag.sh tools/logkit/_asb_logkit_common.sh tools/logkit/asb_audio_ab.sh; do
  grep -q "AudioPlaybackConfiguration .\*state:started" "$ROOT/$file" || f "$file does not use the live-player pattern"
  grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE "player piid\.\*started|grep -q[a-zA-Z]* '?\"?state:started|\*state:started\*" && f "$file still matches history lines"
done
[ "$fail" = 0 ] && echo "PASS audio live player"
exit "$fail"

) || { echo "FAIL in bundled contract: audio_live_player_contract" >&2; exit 1; }

# ==== bg_bucket_restore_contract ====================================================================
(
# Contract + runtime: standby buckets forced by background trimming are recorded and
# handed back, and uninstall does it too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"; U="$ROOT/uninstall.sh"
fail=0; f() { echo "FAIL bg buckets: $*" >&2; fail=1; }
blk="$(sed -n '/^asb_bg_trim_apply_buckets() {/,/^}/p' "$S")"
printf '%s\n' "$blk" | grep -q 'am set-standby-bucket' && f "apply_buckets forces a bucket without recording it"
grep -q '/data/adb/asb/bg_buckets_orig' "$U" || f "uninstall does not restore recorded buckets"
# Uninstall's fallback list must be the heavy list, or an old install keeps apps in rare.
heavy="$(sed -n '/^_BG_TRIM_HEAVY="/,/^"/p' "$S" | grep -E '^[a-z]' | sort | tr '\n' ' ')"
unl="$(sed -n '/for _bp in com.facebook.katana/,/; do/p' "$U" | tr -s ' \\\n' '\n' | sed 's/;$//' | grep -E '^com\.' | sort | tr '\n' ' ')"
[ "$heavy" = "$unl" ] || f "uninstall fallback list differs from _BG_TRIM_HEAVY: [$heavy] vs [$unl]"

# Runtime: extract the two helpers and drive them with a stub am.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/am" <<'A'
#!/bin/sh
case "$1" in
  get-standby-bucket) case "$2" in com.inst|com.daily) echo 10 ;; com.gone) echo "Error: no package" ;; *) echo 30 ;; esac ;;
  set-standby-bucket) echo "$2 $3" >> "$AMLOG" ;;
esac
A
chmod +x "$T/bin/am"
{ sed -n '/^ASB_BG_BUCKETS_ORIG=/p' "$S"; sed -n '/^asb_bg_bucket_set() {/,/^}/p;/^asb_bg_bucket_restore() {/,/^}/p;/^asb_bg_bucket_demote_idle() {/,/^}/p' "$S"; } \
  | sed "s#/data/adb/asb#$T/d#g" > "$T/h.sh"
cat >> "$T/h.sh" <<'E'
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.gone rare
asb_bg_bucket_set com.msg active
asb_bg_bucket_demote_idle com.daily rare
asb_bg_bucket_demote_idle com.weekly rare
asb_bg_bucket_restore
E
AMLOG="$T/am.log" PATH="$T/bin:$PATH" bash "$T/h.sh"
grep -qx 'com.inst 10' "$T/am.log" || f "original bucket not restored"
grep -qx 'com.msg 30' "$T/am.log" || f "second app not restored"
grep -q 'com.gone' "$T/am.log" && f "uninstalled package touched"
[ "$(grep -c '^com.inst rare$' "$T/am.log")" = 2 ] || f "set not applied"
[ -f "$T/d/bg_buckets_orig" ] && f "record not cleared after restore"
grep -q '^com.daily ' "$T/am.log" && f "an app in daily use was demoted"
grep -qx 'com.weekly rare' "$T/am.log" || f "an app out of daily use was not demoted"
# Heavy apps go through the idle-only rule; aggressive without opt-in gets the periodic pass.
printf '%s\n' "$blk" | grep -q 'asb_bg_bucket_demote_idle "$_p" rare' || f "heavy apps bypass the idle-only rule"
sed -n '/allow_disruptive_bg_trim \]; then/,/return 0/p' "$S" | grep -q 'asb_bg_trim_periodic' || f "smart aggressive has no periodic pass"
[ "$fail" = 0 ] && echo "PASS bg bucket restore"
exit "$fail"

) || { echo "FAIL in bundled contract: bg_bucket_restore_contract" >&2; exit 1; }

# ==== camera_bind_requeue_contract ====================================================================
(
# Contract: every staged camera payload is queued for the boot-time bind - no comparison with
# the live file at install time (fix54 skipped on equality; fix64 drops the comparison: what
# the live path shows mid-install says nothing about what it shows after the reboot).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
fail=0; f() { echo "FAIL camera bind requeue: $*" >&2; fail=1; }
body="$(sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$I")"
printf '%s\n' "$body" | grep -q 'cmp -s' && f 'a live-file comparison can skip the camera bind again'
printf '%s\n' "$body" | grep -Fq 'echo "${_obc_live}|${_obc_dst}" >> "$_obc_man"' || f 'camera payload no longer queued'
grep -Fq 'camera bind: ' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show camera bind evidence'
grep -Fq 'nsenter -t 1 -m -- umount "$_ct_live"' "$I" || f 'installer does not take down its own camera bind before declaring the live tone table dirty'
# fix112: the skipped install ships no tone file and the install wipes odm_patched and the
# bind manifest, so after its reboot one more install finds stock - no disable step needed.
grep -q 'ASB_L_CAM_LIVE_DIRTY2=".*after the reboot just install ASB once more' "$ROOT/common/englishtext.sh" || f 'dirty-camera advice does not say "install once more after the reboot"'
grep -Fq 'rm -rf "$_ob_root" 2>/dev/null' "$I" || f 'install no longer wipes the old odm payloads (the advice depends on it)'
[ "$fail" = 0 ] && echo "PASS camera bind requeue contract"
exit "$fail"

) || { echo "FAIL in bundled contract: camera_bind_requeue_contract" >&2; exit 1; }

# ==== cap_source_own_write_contract ====================================================================
(
# fix74: the ceiling ASB wrote to scaling_max_freq is classified as ASB's, not as a vendor
# clamp. The classifier compared the live ceiling with the msm_performance cap, which the
# writer only touches in HEAVY/GAMING - so every Smart cap in LIGHT/MODERATE read as
# "vendor_clamp" (field OP15, 35 C: vendor_clamp_1h=424, holddown active on its own writes).
# Executable fixture: the REAL cap_source_classify() cut out of asb_governor.c.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL cap source own-write: $*" >&2; exit 1; }

grep -q 'real_max_p0, hw_ceil_p0,' "$G" || fail "status builder call changed shape"
grep -q 'g_wcache.cpu_max\[0\]);' "$G" || fail "little cluster classified without ASB's written cap"
grep -q 'g_wcache.cpu_max\[1\]);' "$G" || fail "prime cluster classified without ASB's written cap"

awk '/^static inline const char \*cap_source_classify\(/{on=1} on{print} on&&/^}/{exit}' "$G" > "$T/fn.c"
[ -s "$T/fn.c" ] || fail "cap_source_classify not found"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include "fn.c"
static int bad;
static void eq(const char *got, const char *want, const char *what) {
    if (strcmp(got, want)) { printf("%s: got %s want %s\n", what, got, want); bad = 1; }
}
int main(void) {
    // OP15 LIGHT_IDLE: profile ceiling 3628800, msm cap at hw max, ASB wrote 1440000
    eq(cap_source_classify(3628800, 3628800, 1440000, 3628800, 1440000), "asb_dynamic", "own smart cap");
    eq(cap_source_classify(1440000, 3628800, 1440000, 3628800, 1440000), "asb", "own cap = profile");
    // something below what ASB wrote is still a clamp
    eq(cap_source_classify(3628800, 3628800, 1209600, 3628800, 1440000), "vendor_clamp", "real clamp");
    // somebody rewrote the node above ours
    eq(cap_source_classify(3628800, 1440000, 2000000, 3628800, 1440000), "vendor_raised", "raised");
    // no msm_performance node: ASB's own write is not a shell override
    eq(cap_source_classify(3628800, 0, 1440000, 3628800, 1440000), "asb_dynamic", "no msm, own cap");
    eq(cap_source_classify(3628800, 0, 3628800, 3628800, 0), "shell_applied", "nothing written yet");
    return bad;
}
X
cc -std=gnu11 -Wall -Werror -I"$T" "$T/t.c" -o "$T/t" || fail "fixture does not compile"
"$T/t" || fail "classification wrong"
echo "PASS cap source recognises ASB's own writes"

) || { echo "FAIL in bundled contract: cap_source_own_write_contract" >&2; exit 1; }

# ==== cfg_conflicts_contract ====================================================================
(
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

) || { echo "FAIL in bundled contract: cfg_conflicts_contract" >&2; exit 1; }

# ==== current_scale_contract ====================================================================
(
# Contract + simulation: the governor measures the battery-current gauge scale.
# A gauge that reports half the real current (OnePlus 15) must come out near 0.5; screen-off
# time and charging must not contaminate the window.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL current scale: $*" >&2; fail=1; }
grep -q 'current_scale_x100=%d' "$G" || f "scale not published"
[ "$(grep -c 'asb_curscale_track(metrics.misc.screen_on' "$G")" -ge 2 ] || f "not called on both tick paths"
command -v gcc >/dev/null 2>&1 || { [ "$fail" = 0 ] && echo "PASS current scale (contract only, no gcc)"; exit "$fail"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$G" "$T" <<'PY' || { echo "FAIL current scale: extraction" >&2; exit 1; }
import sys
s=open(sys.argv[1]).read(); t=sys.argv[2]
a=s.index('#define ASB_CURSCALE_FILE'); b=s.index('/* Called once per tick. screen_on resets the window')
code=s[a:b].replace('"/data/adb/asb/current_scale_x100"','"%s/cs"' % t)
main=r'''
int main(int argc,char**argv){ double gauge=atof(argv[1]); int pct; int t;
 for(t=0;t<5*3600;t+=5){ g_now=t*1000L;
   double used=700.0*t/3600.0; pct=85-(int)(used*100/7300);
   int scr=(t/600)%3!=2;
   int chg=(t>=3*3600 && t<3*3600+600);    /* a charger plugged in briefly */
   asb_curscale_track(scr,pct,chg,(int)(700.0*gauge)); }
 printf("%d %d\n",g_curscale_x100,g_curscale_n); return 0;}
'''
open(t+'/t.c','w').write('#include <stdio.h>\n#include <stdlib.h>\n#include <time.h>\nstatic long g_now=0;\nstatic long asb_clock_ms(int c){(void)c;return g_now;}\nstatic long sysfs_read_long(const char*p,long d){(void)p;(void)d;return 7300000;}\n'+code+main)
PY
gcc -Wall -Werror -o "$T/t" "$T/t.c" || { echo "FAIL current scale: compile" >&2; exit 1; }
set -- $("$T/t" 0.5); [ "$1" -ge 42 ] && [ "$1" -le 58 ] && [ "$2" -ge 2 ] || f "half-reading gauge measured as $1 ($2 windows)"
rm -f "$T/cs"
set -- $("$T/t" 1.0); [ "$1" -ge 88 ] && [ "$1" -le 112 ] || f "true gauge measured as $1"
[ "$fail" = 0 ] && echo "PASS current scale"
exit "$fail"

) || { echo "FAIL in bundled contract: current_scale_contract" >&2; exit 1; }

# ==== dsp_core_cpu_contract ====================================================================
(
# fix78: the compressor gain (log10f + powf) is evaluated every ASB_COMP_EVERY frames and
# skipped below the knee instead of 48000 times a second; the limiter stays per frame.
# Host measurement at +12 dB on a 60 s music-like signal: 101 -> 45 ms CPU, output
# difference -55 dB relative, peak still under the ceiling. Runtime: same signal through the
# real core, every output sample within the ceiling.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/src/DSP_AIDL/asb_dsp_core.h"
fail() { echo "FAIL dsp core cpu: $*" >&2; exit 1; }
grep -q '#define ASB_COMP_EVERY   16' "$H" || fail "no decimation constant"
grep -q 'if (env <= c->knee_lo_lin) return 1.0f;' "$H" || fail "no below-knee shortcut"
[ "$(grep -c 'float cg = asb_core_comp_step(c, peak);' "$H")" = 2 ] || fail "a process path still evaluates the gain per frame"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <stdlib.h>
#include "asb_dsp_core.h"
#define N 96000
static float in[N*2], out[N*2];
int main(void){
  srand(3);
  for(int i=0;i<N;i++){ float e=0.3f+0.7f*fabsf(sinf(i*0.0003f)); float x=e*(0.6f*sinf(i*0.05f)+0.3f*((rand()/(float)RAND_MAX)-0.5f)); in[2*i]=x; in[2*i+1]=-x; }
  asb_core_t c={0}; asb_core_reset(&c);
  asb_core_configure_ex(&c,1,2500,-15,1,60,-2400,2,48000,1,0,300);
  for(int o=0;o<N;o+=480) asb_core_process_f32(&c,in+2*o,out+2*o,480,0);
  for(int i=0;i<N*2;i++) if (fabsf(out[i]) > c.ceiling + 1e-6f) { printf("over ceiling at %d: %f\n", i, out[i]); return 1; }
  return 0;
}
X
cc -O2 -I"$ROOT/src/DSP_AIDL" "$T/t.c" -lm -o "$T/t" && "$T/t" || fail "limiter ceiling broken"
echo "PASS DSP core evaluates the compressor gain per block"

) || { echo "FAIL in bundled contract: dsp_core_cpu_contract" >&2; exit 1; }

# ==== dsp_route_backoff_contract ====================================================================
(
# Contract: the DSP route watcher does not dump the audio service on a fixed 5 s clock.
#
# With a dsp_outputs filter set it ran `dumpsys audio` every 5 s of screen-on time - about
# 720 framework dumps an hour, nearly all returning the same route. It now backs off to
# 30 s (15 s while playing) and is pulled forward by the kernel's PCM state, which costs
# a file read instead of a binder walk.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL dsp route backoff: $*" >&2; fail=1; }
blk="$(sed -n '/_prev_route=""/,/persist.asb.dsp.route "\$_now"/p' "$S")"
[ -n "$blk" ] || { echo "FAIL dsp route backoff: watcher block not found" >&2; exit 1; }
printf '%s\n' "$blk" | grep -q 'grep -l RUNNING /proc/asound/card\*/pcm\*p/sub\*/status' || f "no PCM-state pull-forward"
printf '%s\n' "$blk" | grep -q '\[ "$_since" -lt "${_iv:-5}" \]' || f "dump not gated by the interval"
printf '%s\n' "$blk" | grep -q '_ivmax=30; \[ "$_play_now" = 1 \] && _ivmax=15' || f "back-off ceilings changed"
# The dump must come after the gate, never straight after a fixed sleep.
printf '%s\n' "$blk" | awk '/sleep 5$/ { s = NR } /_adump="\$\(dumpsys audio/ { if (s && NR - s < 3) bad = 1 } END { exit bad }' \
  || f "dumpsys audio directly after a fixed sleep"
[ "$fail" = 0 ] && echo "PASS dsp route backoff contract"
exit "$fail"

) || { echo "FAIL in bundled contract: dsp_route_backoff_contract" >&2; exit 1; }

# ==== dsp_route_release_contract ====================================================================
(
# fix77: off the selected outputs the attach daemon RELEASES the effect instead of keeping
# it attached at gain 0. An enabled effect on the global mix is non-offloadable for the
# audio policy even as a pass-through, so the stream stayed off the offload path and the
# CPU awake (dsp_outputs=speaker/bt is set on field phones). The daemon is a prebuilt, so
# the freshness gate must refuse an older binary.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp"
fail() { echo "FAIL dsp route release: $*" >&2; exit 1; }
grep -q 'int route_ok = route_allows_dsp();' "$A" || fail "daemon does not check the route before attaching"
grep -q 'if (want_on && !route_ok) {' "$A" || fail "no release branch"
grep -q 'logline("released (route not selected)");' "$A" || fail "release not logged (freshness marker)"
# the release branch must come before the attach code, or it never runs while attached
_rel="$(grep -n 'if (want_on && !route_ok) {' "$A" | cut -d: -f1)"
_att="$(grep -n 'next->set(&kAsbTypeUuid' "$A" | cut -d: -f1)"
[ "$_rel" -lt "$_att" ] || fail "release branch after the attach path"
grep -q '"released (route not selected)"; do' "$ROOT/src/build_ndk_release.sh" || fail "freshness gate misses the release marker"
grep -q 'persist.asb.dsp.voice' "$A" || fail "voice edits do not trigger a push"
grep -q 'DSP released on purpose' "$ROOT/tools/asb_diag.sh" || fail "asbdiag reports the intended release as a failure"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
# fix79: with the screen off the route watcher still reacts to a PCM change (one pass)
grep -q '_sig_off="$(grep -l RUNNING /proc/asound/card\*/pcm\*p/sub\*/status' "$ROOT/service.sh" || fail "screen-off route change is never noticed"
grep -q '\[ "$_sig_off" != "${_prev_sig:-}" \] || continue' "$ROOT/service.sh" || fail "screen-off pass is not gated on a PCM change"
echo "PASS DSP released off the selected outputs"

) || { echo "FAIL in bundled contract: dsp_route_release_contract" >&2; exit 1; }

# ==== fg_uclamp_guard_contract ====================================================================
(
# Foreground uclamp had no owner while the governor ran (reconcile skips per-cgroup checks
# then, the writer manages only top/bg/sybg), so a ROM "max" stayed for whole screen-on
# sessions. The guard's limits are what keep it from fighting vendor launch boosts.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL fg uclamp guard contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$W" 'static void writer_fg_guard(int screen_on)' 'guard missing'
need "$W" 'if (!screen_on || g_cam_guard_on) { g_fg_max_since = 0; return; }' 'acts with screen off or during camera guard'
need "$W" 'if (cur < 100) { g_fg_last_good = cur; g_fg_max_since = 0; return; }' 'corrects values other than max'
need "$W" 'if (now - g_fg_max_since < 60) return;' 'no 60 s persistence before acting'
need "$W" 'g_fg_backoff_until = now + 600' 'no stand-down when something keeps reasserting'
need "$G" 'writer_fg_guard(metrics.misc.screen_on);' 'guard not called from the governor loop'
need "$G" 'fg_guard_fixes=%lu' 'corrections not published'
echo "PASS fg uclamp guard contract"

) || { echo "FAIL in bundled contract: fg_uclamp_guard_contract" >&2; exit 1; }

# ==== gpu_pwrlevel_order_contract ====================================================================
(
# fix74: a GPU ceiling lowered past the live floor is put back once the floor follows.
#
# KGSL clamps max_pwrlevel to min_pwrlevel at write time (higher index = lower clock), so
# "write ceiling 17, then floor 17" against a floor of 8 ends as max=8 min=17. The override
# check then blamed the vendor and held every GPU write for 15 s - OP15 field capture:
# max_overrides=323 backoffs=492, written 17 / observed 8 with the floor at 17.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { printf '%s\n' "FAIL gpu pwrlevel order: $*" >&2; exit 1; }
need() { grep -Fq "$1" "$W" || fail "missing [$1]"; }

need 'int _gmax_pl_this_tick = -1;'
need 'g_wcache.last_max_pwrlevel_written = pl; _gmax_pl_this_tick = pl;'
need 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel && g_gpu_max_path[0]) {'
# only when the pair is consistent: a vendor floor above our ceiling is not fought
need 'if (_gmin_now < 0 || _gmin_now >= _gmax_pl_this_tick)'

# the re-check runs AFTER the floor write, or it would see the old floor
_floor="$(grep -Fn 'g_wcache.last_min_pwrlevel_written = pl;' "$W" | head -1 | cut -d: -f1)"
_fix="$(grep -Fn 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel' "$W" | head -1 | cut -d: -f1)"
[ -n "$_floor" ] && [ -n "$_fix" ] || fail "anchors not found"
[ "$_fix" -gt "$_floor" ] || fail "ceiling re-check precedes the floor write"

# Model of the KGSL rule the fix relies on (kgsl_pwrctrl max/min_pwrlevel_store):
# max cannot exceed min as an index, min cannot go below max.
python3 - <<'PY'
class K:
    def __init__(s, mx, mn): s.max, s.min = mx, mn
    def wmax(s, l): s.max = min(l, s.min)
    def wmin(s, l): s.min = max(l, s.max)
k = K(0, 8)            # vendor floor at 8
k.wmax(17); k.wmin(17) # the old order
assert (k.max, k.min) == (8, 17), (k.max, k.min)
if k.max != 17 and k.min >= 17: k.wmax(17)   # the fix
assert (k.max, k.min) == (17, 17), (k.max, k.min)
k = K(0, 8); k.wmax(17)                        # floor NOT ours to move (no min write)
if k.max != 17 and k.min >= 17: k.wmax(17)
assert k.max == 8                              # left alone
PY
printf '%s\n' 'PASS gpu pwrlevel order contract'

) || { echo "FAIL in bundled contract: gpu_pwrlevel_order_contract" >&2; exit 1; }

# ==== heavy_prime_escape_contract ====================================================================
(
# HEAVY prime escape: a bounded, Smart-only lift of a pinned prime ceiling. Every limit is
# the point of the feature, so each one is pinned here.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"; C="$ROOT/src/asb_config.h"
fail() { echo "FAIL heavy prime escape contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'fsm->profile_idx == PROFILE_SMART' 'not limited to Smart'
need "$F" '(fsm->state == ASB_STATE_HEAVY || fsm->state == ASB_STATE_MODERATE) &&' 'not limited to HEAVY/MODERATE'
need "$F" '                  m->misc.screen_on &&' 'not limited to screen on'
need "$F" '!fsm->thermal_cap && !m->bat.charging && !m->misc.camera_active' 'thermal/charging/camera gates missing'
need "$F" 'm->misc.app_hint < ASB_APP_GAMING' 'games are not excluded'
need "$F" 'asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx) &&' 'die temperature gate missing'
need "$F" 'g_asb_cfg.thermal_skin_c - 8' 'skin pre-lean gate missing'
# Burst and rest are WebUI settings now; the contract is that both stay bounded.
need "$F" 'if (_now - _esc_since >= _esc_burst)' 'burst is not time-limited'
need "$F" '_esc_rest_until = _now + _esc_rest;' 'no rest period after a burst'
need "$F" 'if (_esc_burst > 60) _esc_burst = 60;' 'burst not capped at 60 s'
need "$F" 'if (_esc_rest < 10) _esc_rest = 10;' 'rest not floored at 10 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_burst_s         = 20;' 'burst default is not 20 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_rest_s          = 40;' 'rest default is not 40 s'
need "$F" 'if (_esc_streak >= (fsm->state == ASB_STATE_MODERATE ? 3 : 2))' 'escape does not require the prime to stay pinned (3 ticks in MODERATE)'
need "$F" 'g_profile_bounds[PROFILE_BALANCED]' 'ceiling is not bounded by Balanced'
need "$F" 'g_state_level[_lvl_state]' 'bound is not the Balanced rail of the current state'
need "$F" 'int _lvl_state = (fsm->state == ASB_STATE_MODERATE) ? ASB_STATE_MODERATE' 'MODERATE burst may reach the HEAVY rail'
# The escape must sit before the caps are committed and before the thermal budget runs
# (the budget lives in the governor and is applied to the committed caps afterwards).
_e="$(grep -n 'HEAVY prime escape (Smart only)' "$F" | head -1 | cut -d: -f1)"
_c="$(grep -n 'memcmp(&new_caps, &fsm->current_caps' "$F" | head -1 | cut -d: -f1)"
[ -n "$_e" ] && [ -n "$_c" ] && [ "$_e" -lt "$_c" ] || fail "escape applied after the caps are committed"
need "$C" 'c->heavy_prime_escape           = 1;' 'default not on'
need "$C" '"heavy_prime_escape"' 'config key not parsed'
grep -q '^heavy_prime_escape=1$' "$ROOT/config/governor.conf.shipped" || fail 'shipped config lacks the key'
need "$G" 'prime_escape=%d' 'state file does not publish the escape'
need "$G" 'prime_escape: lift' 'lift edge not logged'
# Multi-cluster: on 3+ cluster SoCs the middle slot is part of the burst (trigger and lift),
# and two-cluster devices must not grow a slot - the mid index exists only when slot 2 does.
need "$F" 'int _ms = (g_cpu_policy_ids[2] >= 0 && g_cpu_policy_ids[1] >= 0) ? 1 : -1;' 'mid slot not derived from topology'
need "$F" 'int _pinned = _pinned_prime || _pinned_mid;' 'mid cluster cannot trigger the burst'
need "$F" 'int _slots[2] = { _ps, _ms };' 'burst does not lift the mid cluster'
need "$F" 'if (_hw > 0 && _lim > _hw) _lim = _hw;' 'lift not bounded by hardware max'
need "$G" 'prime_escape_mid=%d' 'mid lift not published'
echo "PASS heavy prime escape contract"

) || { echo "FAIL in bundled contract: heavy_prime_escape_contract" >&2; exit 1; }

# ==== learner_prediction_contract ====================================================================
(
# Contract + runtime: the hour-of-week learner predicts from screen share, never slows a
# ramp-up below the FSM default, and keeps its data outside the module directory.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/src/asb_learner.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL learner prediction: $*" >&2; fail=1; }
grep -Fq '#define LEARN_FILE        "/data/adb/asb/learn.bin"' "$L" || f 'learn.bin still inside the module directory (lost on every update)'
grep -Fq 'learner_load_from(db, LEARN_FILE_LEGACY)' "$L" || f 'legacy learn.bin not carried over'
grep -Fq 'drain_ma_ema < ' "$L" && f 'prediction still uses milliamps (awake-only samples, gauge-scaled)'
grep -Fq '/data/adb/asb/learn.bin' "$ROOT/service.sh" || f 'learning reset does not clear learn.bin'
grep -Fq '#define PERSISTENT_STATS_DIR        "/data/adb/asb"' "$ROOT/src/asb_governor.c" || f 'pstats/env fingerprint still inside the module directory'
grep -Fq 'pstats_load_migrating(PERSISTENT_STATS_FILE' "$ROOT/src/asb_governor.c" || f 'legacy pstats not carried over'
CC="${CC:-}"; [ -n "$CC" ] || CC="$(command -v gcc || command -v clang || true)"
if [ -n "$CC" ]; then
  cat > "$T/t.c" <<'C'
#include <stdint.h>
#include <unistd.h>
#include "asb_learner.h"
#include <stdio.h>
int main(void) {
  asb_learn_db_t db; memset(&db, 0, sizeof db);
  int slot = learner_slot(), up, down, bad = 0;
  float shares[] = { 0.05f, 0.30f, 0.80f };
  int want[] = { LEARN_PREDICT_IDLE, LEARN_PREDICT_LIGHT, LEARN_PREDICT_ACTIVE };
  for (int i = 0; i < 3; i++) {
    db.slots[slot].samples = 5; db.slots[slot].screen_on_ema = shares[i];
    db.slots[slot].drain_ma_ema = 500.0f;   /* a real awake-sampled hour */
    if ((int)learner_predict(&db) != want[i]) { printf("share %.2f predicted %d\n", shares[i], learner_predict(&db)); bad = 1; }
    learner_adjust_windows(&db, &up, &down);
    if (up > 2) { printf("share %.2f slows ramp-up to %d ticks\n", shares[i], up); bad = 1; }
  }
  return bad;
}
C
  if "$CC" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/err"; then
    "$T/t" || f 'runtime prediction check failed'
  else
    f "learner header does not compile standalone: $(head -3 "$T/err")"
  fi
fi
[ "$fail" = 0 ] && echo "PASS learner prediction contract"
exit "$fail"

) || { echo "FAIL in bundled contract: learner_prediction_contract" >&2; exit 1; }

# ==== mksh_32bit_arith_contract ====================================================================
(
# Contract: byte counters and other values past 2^31 are not summed or compared with
# shell arithmetic in device scripts.
#
# Android's /system/bin/sh is mksh, whose arithmetic is 32-bit signed (a built mksh R59:
# $((2147483647+1)) = -2147483648, and [ 3000000000 -gt 2000000000 ] is false). Host
# shells are 64-bit, so host tests never saw it. Field effects: the screen-off class lost
# "network" after 2 GiB received since boot, the opt-in zram rebuild compared against a
# wrapped 8 GiB and ran every boot. These go through awk now.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL mksh 32-bit: $*" >&2; fail=1; }
grep -nE '\$\(\([^)]*(rx_bytes|tx_bytes)' "$ROOT"/runtime/*.sh "$ROOT"/action.sh "$ROOT"/tools/logkit/*.sh && f 'byte counter in $(( ))'
grep -Fq '_rx1=$(( _rx1 +' "$ROOT/runtime/asb_screenoff_class.sh" && f 'screen-off class sums rx bytes in shell arithmetic'
grep -Fq '_mrx=$(( _mrx + _a ))' "$ROOT/tools/logkit/_asb_logkit_common.sh" && f 'logkit sums mobile bytes in shell arithmetic'
grep -Fq '$((ZRAM_SIZE_MB * 1024 * 1024))' "$ROOT/service.sh" && f 'zram bytes computed in shell arithmetic'
grep -Fq '_wf_rate * 125000 * 60' "$ROOT/runtime/asb_net_routes.sh" && f 'BDP product overflows 32 bits above ~286 Mbit/s'
grep -Fq '_ma * 100 / _mt' "$ROOT/runtime/smart_dynamic_tune.sh" && f 'memory share overflows on 24 GB phones'
if command -v mksh >/dev/null 2>&1; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/net/rmnet_data0/statistics"
  echo 3000000000 > "$T/net/rmnet_data0/statistics/rx_bytes"
  _s="$(cat "$T"/net/rmnet_data*/statistics/rx_bytes | awk '{ s += $1 } END { printf "%.0f", s + 0 }')"
  [ "$_s" = 3000000000 ] || f "awk sum under mksh gave $_s"
fi
[ "$fail" = 0 ] && echo "PASS mksh 32-bit arithmetic contract"
exit "$fail"

) || { echo "FAIL in bundled contract: mksh_32bit_arith_contract" >&2; exit 1; }

# ==== mksh_background_detach_contract ====================================================================
(
# Contract: runtime helpers detach background bodies with an exec inside the subshell,
# never with a redirect on the closing ")".
#
# Under mksh (Android's /system/bin/sh) "( ...; x=$(cmd); ... ) >/dev/null 2>&1 &" does not
# release the caller's stdout: a caller capturing the output - the WebUI's exec bridge -
# waits for the whole background body. Measured: the async asbdiag start returned only
# after the export finished (1066 ms for a 1 s fake export, 19 ms under dash). The
# working form is "( exec </dev/null >/dev/null 2>&1; ... ) &".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(grep -nE '^[[:space:]]*\)[[:space:]]*(</dev/null[[:space:]]*)?>[[:space:]]*/dev/null[[:space:]]+2>&1[[:space:]]*(</dev/null[[:space:]]*)?&[[:space:]]*$' \
        "$ROOT"/runtime/*.sh "$ROOT"/uninstall.sh 2>/dev/null)"
if [ -n "$bad" ]; then
  echo "FAIL mksh background detach: redirect on a closing ) - use exec inside the subshell:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
if command -v mksh >/dev/null 2>&1; then
  _a="$(date +%s%N 2>/dev/null || echo 0)"
  _x="$(mksh -c '( exec </dev/null >/dev/null 2>&1; y="$(echo z)"; sleep 1 ) & echo p')"
  _b="$(date +%s%N 2>/dev/null || echo 0)"
  [ "$_a" != 0 ] && [ $(( (_b - _a) / 1000000 )) -lt 500 ] || { echo "FAIL mksh background detach: the exec form still blocks on this mksh" >&2; exit 1; }
fi
echo "PASS mksh background-detach contract"

) || { echo "FAIL in bundled contract: mksh_background_detach_contract" >&2; exit 1; }

# ==== mksh_pipe_pattern_contract ====================================================================
(
# Contract: no unescaped | inside a ${var#pat} / ${var%pat} pattern.
#
# Android's /system/bin/sh is mksh, and mksh reads a bare | in those patterns as an
# alternation: "${l%%|*}" on "0|916479" yields "" and "${l#*|}" yields the whole string.
# Every host shell (dash, bash, BusyBox ash) does the expected split, so host tests passed
# while the device failed: the screen-off LTE restore dropped every record as "bad" and
# never gave 5G back, and the GNSS, phantom-process and Wi-Fi fallback restores parsed
# their records the same way. Write \| (works in every shell) or split with IFS/read.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -rnoE '\$\{[A-Za-z_][A-Za-z0-9_]*(%%?|##?)[^}]*\}' \
        --include=*.sh common runtime tools system/bin service.sh post-fs-data.sh uninstall.sh action.sh customize.sh 2>/dev/null \
      | grep -E '[^\\]\|' | grep -vE '"[^"]*\|[^"]*"' )"
if [ -n "$bad" ]; then
  echo "FAIL mksh pipe patterns: unescaped | in a parameter pattern:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
echo "PASS mksh pipe-pattern contract"

) || { echo "FAIL in bundled contract: mksh_pipe_pattern_contract" >&2; exit 1; }

# ==== module_overlap_contract ====================================================================
(
# Contract + fixture: asbdiag names other enabled modules that set properties ASB manages,
# with the differing values (AIST v2.1 shares 141 keys with ASB, 16 at other values).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail=0; f() { echo "FAIL module overlap: $*" >&2; fail=1; }
grep -q 'SEC "0a0. MODULE OVERLAP' "$D" || f "section missing"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag out of sync"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '# c\nk.same=1\nk.diff=true\nk.only=1\n' > "$T/asb"
printf 'k.same=1\nk.diff=false\nk.other=1\n# k.diff=x\n' > "$T/other"
awk_prog="$(sed -n "/_ov_rows=\"\$(awk -F= '/,/' \"\$_ov_asb\" \"\$_ov_m\/system.prop\" 2>\/dev\/null)\"/p" "$D" | sed "1s/.*awk -F= '//; \$s/' \"\\\$_ov_asb\".*//")"
[ -n "$awk_prog" ] || f "could not extract the overlap program"
out="$(awk -F= "$awk_prog" "$T/asb" "$T/other")"
printf '%s\n' "$out" | grep -qx 'k.diff|true|false' || f "differing key not reported: $out"
printf '%s\n' "$out" | grep -qx '#|2|1' || f "summary wrong: $out"
printf '%s\n' "$out" | grep -q 'k.same|' && f "equal key reported as different"
[ "$fail" = 0 ] && echo "PASS module overlap contract"
exit "$fail"

) || { echo "FAIL in bundled contract: module_overlap_contract" >&2; exit 1; }

# ==== offdrain_contract ====================================================================
(
# Measured screen-off drain replaces the idle guess in every forecast.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"; D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL offdrain contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" 'if (charging) { g_offdrain_start_ms = 0; g_offdrain_on_ms = 0; return; }' 'charging window not discarded'
need "$G" 'if (dur >= 3600000L && dpct >= 2) {' 'short or rounding-only windows can count'
need "$G" 'now - g_offdrain_on_ms >= 120000L' 'a glance at the clock splits the night'
need "$G" 'long now = asb_clock_ms(CLOCK_BOOTTIME);' 'window not timed on a suspend-aware clock'
need "$G" 'offdrain_pctph_x100=%d\noffdrain_windows=%d' 'not published'
[ "$(grep -c 'asb_offdrain_track(metrics.misc.screen_on' "$G")" -ge 2 ] || fail 'not called on both tick paths'
need "$A" "grep -m1 '^offdrain_pctph_x100=' /dev/.asb/state" 'action ignores the measured idle drain'
need "$W" 'kv.offdrain_pctph_x100' 'WebUI ignores the measured idle drain'
need "$D" "^offdrain_pctph_x100=" 'diag does not report it'
echo "PASS offdrain contract"

) || { echo "FAIL in bundled contract: offdrain_contract" >&2; exit 1; }

# ==== quiet_night_any_profile_contract ====================================================================
(
# Contract: Quiet Night is eligible inside the night window on any profile.
#
# A full OP15 night on Smart (battery weight 0.45-0.79, under the 0.8 "battery-like" bar)
# never entered Quiet Night, while two daytime screen-offs did. The mode trims the
# governor's own footprint on a sleeping phone; the profile's performance lean is not a
# reason to keep polling all night. Outside the window the battery-like rule still applies.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL quiet night eligibility: $*" >&2; fail=1; }
grep -Fq '(asb_profile_battery_like(fsm.profile_idx) || _qn_window) &&' "$G" || f 'night window does not make any profile eligible'
grep -Fq 'if (g_asb_cfg.night_quiet_enable && fsm.state == ASB_STATE_DEEP_IDLE &&' "$G" || f 'window is not gated by night_quiet_enable'
grep -Fq 'if (!_use_fast) _use_fast = _qn_window;' "$G" || f 'night window no longer speeds up entry'
[ "$fail" = 0 ] && echo "PASS quiet night any-profile contract"
exit "$fail"

) || { echo "FAIL in bundled contract: quiet_night_any_profile_contract" >&2; exit 1; }

# ==== route_table_all_contract ====================================================================
(
# Contract: route readers use every table, and the route watcher cannot feed itself.
#
# Android keeps each network's default route in its own table ("... table rmnet_data2"),
# never in main. Reading `ip route show` found no route on any phone: initcwnd/initrwnd
# were never applied, per-route congctl was "not supported" without the kernel being
# asked, and the report waited for a link forever.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL route tables: $*" >&2; fail=1; }
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh action.sh tools/asb_diag.sh; do
  sh -n "$ROOT/$file" || f "$file syntax"
  # Any `ip [-6] route show` that is not followed by a table selector reads main only.
  if grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -v '^[0-9]*:[[:space:]]*#' \
       | grep -vE 'route show table' >/dev/null; then
    f "$file reads the main table only: $(grep -nE 'ip( -6)? route show( |$)' "$ROOT/$file" | grep -vE 'route show table|^[0-9]*:[[:space:]]*#' | head -1)"
  fi
done
R="$ROOT/runtime/asb_net_routes.sh"
grep -q 'route show table all' "$R" || f "net_routes does not read table all"
# Our own route change is a route event: the watcher must compare a fingerprint that
# strips the tokens it writes, or it re-applies forever.
grep -q '_route_fp()' "$R" || f "no route fingerprint"
grep -q '\[ "$_nfp" = "$_fp" \] && continue' "$R" || f "monitor loop does not skip unchanged routes"
for tok in initcwnd initrwnd congctl; do
  sed -n '/^_route_fp()/,/^}/p' "$R" | grep -q "s/ $tok " || f "fingerprint keeps $tok"
done
# A re-created route lost its congctl too; the watcher restores it through the routes mode.
grep -q 'asb_net_apply.sh" routes' "$R" || f "watcher does not re-apply per-route congctl"
grep -q '\[ "$ASB_NET_MODE" = routes \] && exit 0' "$ROOT/runtime/asb_net_apply.sh" || f "net_apply has no routes mode"
grep -q 'route get 1.1.1.1' "$ROOT/runtime/asb_net_apply.sh" || f "active link not taken from the kernel's own route choice"
# Per-link congestion alone must still run the boot apply and keep the watcher alive.
grep -q 'net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile; do' "$ROOT/service.sh" \
  || f "boot apply ignores per-link network keys"
[ "$(grep -c "_rw_mode=cc_only\|_asb_rt=cc_only" "$ROOT/service.sh")" -ge 2 ] || f "watcher not started for per-link congctl alone"
grep -q 'in auto|conservative|aggressive) _apply' "$R" || f "watcher replays route windows while they are off"
# iproute2, not BusyBox: the root manager's applet has no monitor/initcwnd/congctl.
for file in runtime/asb_net_routes.sh runtime/asb_net_apply.sh; do
  grep -q 'for _ipb in /system/bin/ip' "$ROOT/$file" || f "$file does not prefer /system/bin/ip"
  if grep -vE '^[[:space:]]*#' "$ROOT/$file" | grep -qE '(^|[;|&(]|then|else|do)[[:space:]]*ip (route|-6|monitor)'; then
    f "$file still calls a bare ip"
  fi
done
[ "$fail" = 0 ] && echo "PASS route table contract"
exit "$fail"

) || { echo "FAIL in bundled contract: route_table_all_contract" >&2; exit 1; }

# ==== route_watch_idle_contract ====================================================================
(
# Contract: the DSP route watcher does not dump the audio service while nothing plays
# (kernel PCM state unchanged and empty) on kernels that expose PCM state; a stream opening
# still forces a dump at once, and kernels without PCM files keep the timed back-off.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"
fail=0; f() { echo "FAIL route watch idle: $*" >&2; fail=1; }
blk="$(sed -n '/^# Keep persist.asb.dsp.route honest while the phone is running./,/^) >\/dev\/null 2>&1 &$/p' "$S")"
printf '%s\n' "$blk" | grep -q 'elif \[ -z "$_sig" \] && \[ -n "${_pcm_known:-}" \] && \[ -n "$_prev_route" \]; then' \
  || f "idle skip missing"
printf '%s\n' "$blk" | grep -q '_pcm_known=1' || f "PCM-state availability not detected"
# Order: a changed signature must be handled before the idle skip.
_a="$(printf '%s\n' "$blk" | grep -n 'if \[ "$_sig" != "${_prev_sig:-}" \]; then' | cut -d: -f1)"
_b="$(printf '%s\n' "$blk" | grep -n 'elif \[ -z "$_sig" \]' | cut -d: -f1)"
[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ] || f "playback start no longer forces a dump first"
printf '%s\n' "$blk" | grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' || f "SCO route lost"
[ "$fail" = 0 ] && echo "PASS route watch idle contract"
exit "$fail"

) || { echo "FAIL in bundled contract: route_watch_idle_contract" >&2; exit 1; }

# ==== screen_wake_recheck_contract ====================================================================
(
# Contract: a display event inside the 30 s follow-up budget still buys one quick look.
#
# Field captures (OP15, two days): 22 of 54 screen-ons were noticed only by the idle tick,
# each exactly 45 s after the previous tick, with deep-idle rails and frozen cap writes in
# the meantime - an unlock and camera launch ran on sleep rails. The budget that rations the
# ~2 s follow-up chain had been spent by an earlier display event, and inside it nothing was
# armed at all. Guard the single re-check, its spacing, and the counters that expose it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL screen wake recheck: $*" >&2; fail=1; }
need() { grep -Fq -- "$1" "$G" || f "$2"; }
need 'time(NULL) - g_disp_single_ts >= 10' 'single re-check is not spaced (AOD would buy a wakeup per event)'
need 'arm_timerfd_once_ms(tfd_active, 1000);' 'no single re-check inside the follow-up budget'
need 'g_disp_retry = 3;' 'single re-check can grow into a chain'
need 'screen_on_detect=' 'screen-on detection path not published'
need 'g_scr_on_by_tick++' 'slow-path wakes not counted'
need 'make_timerfd_clock(CLOCK_BOOTTIME, TIMER_IDLE_S)' 'screen-off tick still on CLOCK_MONOTONIC (stalls through suspend)'
need 'g_scr_resume_chains++' 'no re-check chain after a resume'
grep -Fq 'screen_on_detect=' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show how wakes were noticed'
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f 'asbdiag copy out of date'
[ "$fail" = 0 ] && echo "PASS screen wake re-check contract"
exit "$fail"

) || { echo "FAIL in bundled contract: screen_wake_recheck_contract" >&2; exit 1; }

# ==== screenoff_awake_gate_contract ====================================================================
(
# Screen-off "real work" must mean the CPU was actually awake, not just a high loadavg.
#
# loadavg on these kernels counts uninterruptible waiters and is frozen across suspend: a
# OnePlus 15 night read load1 40-112 while suspended 96% of the time, held LIGHT_IDLE for
# hours, cut the deep-idle share the environment classifier reads (env=noisy all night)
# and kept the screen-off prime gate shut. The gate is the monotonic/boottime ratio per
# tick, which no idle waiter can fake and which reads the same on every SoC.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL screen-off awake gate: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$M" 'int     awake_tick_pct;' 'cpu metrics lack the awake share'
need "$M" 'clock_gettime(CLOCK_MONOTONIC, &_ts)' 'awake share not measured from CLOCK_MONOTONIC'
need "$M" 'clock_gettime(CLOCK_BOOTTIME, &_ts)' 'awake share not measured against CLOCK_BOOTTIME'
need "$M" 'if (_db >= 1000)' 'sub-second gaps are not ignored'
need "$F" 'int _awake_ok = (m->cpu.awake_tick_pct < 0 || m->cpu.awake_tick_pct >= 50);' 'busy rule not gated on awake share'
need "$F" 'if (m->cpu.load1 >= 8.0f && _awake_ok) {' 'busy streak still counts a sleeping CPU'
need "$F" '(m->cpu.awake_tick_pct >= 0 && m->cpu.awake_tick_pct < 50)) &&' 'screen-off prime gate ignores suspend'
need "$G" 'awake_tick_pct=%d' 'awake share not published'
# Three-tick streak and the load threshold itself are unchanged: the screen-off BT playback
# case this rule was built for (load1 13-19, CPU awake 99.8%) must still promote.
need "$F" 'int _off_busy = (_off_busy_streak >= 3);' 'streak requirement changed'
echo "PASS screen-off awake gate contract"

) || { echo "FAIL in bundled contract: screenoff_awake_gate_contract" >&2; exit 1; }

# ==== settings_wrapper_coverage_contract ====================================================================
(
# Contract: every standalone script that calls `settings` loads the fallback wrapper.
#
# On some OnePlus builds `settings` answers "cmd: Failure calling service settings: Failed
# transaction" and exits 0. The wrapper falls back to the content provider and never
# returns that text as a value; a script started with `sh` does not inherit it from
# service.sh. action.sh took the error string as the locale and printed in English.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for f in "$ROOT"/runtime/*.sh "$ROOT/action.sh" "$ROOT/service.sh" "$ROOT"/tools/logkit/_asb_logkit_common.sh; do
  case "${f##*/}" in
    asb_settings.sh|asb_apply_ledger.sh) continue ;;   # the wrapper itself / a sourced library
  esac
  grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[^_a-zA-Z.])settings (get|put|delete) ' || continue
  grep -q 'asb_settings.sh' "$f" || { echo "FAIL settings wrapper: ${f#$ROOT/} calls settings without the wrapper" >&2; fail=1; }
done
grep -q "case \"\$_asb_loc\" in \*\[Ff\]ailure\*" "$ROOT/action.sh" || { echo "FAIL settings wrapper: action.sh may take an error string as the locale" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS settings wrapper coverage"
exit "$fail"

) || { echo "FAIL in bundled contract: settings_wrapper_coverage_contract" >&2; exit 1; }

# ==== smart_prime_floor_contract ====================================================================
(
# fix80: Smart writes (and repairs) the lowest-OPP floor on every slot, including the prime
# slot whose profile floor is 0. Field OP12: policy7 min=672000 against 480000, the only
# cluster Smart never touched ("smart minimum: WARN"). Non-Smart profiles keep skipping a
# slot without a floor, and HEAVY/GAMING keep their profile floors.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL smart prime floor: $*" >&2; exit 1; }
grep -Fq 'int _smart_floor = (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED);' "$W" || fail "primary path"
grep -Fq 'if (want_min <= 0 && !_smart_floor) continue;' "$W" || fail "primary path still skips a zero floor in Smart"
grep -Fq 'if (want_min <= 0 && !(fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED)) continue;' "$W" || fail "extra clusters"
[ "$(grep -Fc 'if (want_min <= 0) continue;' "$W")" -ge 2 ] || fail "no guard against writing 0 when the OPP table is missing"
echo "PASS Smart floors every slot at its lowest OPP"

) || { echo "FAIL in bundled contract: smart_prime_floor_contract" >&2; exit 1; }

# ==== smart_prime_slot_cap_contract ====================================================================
(
# Smart caps the separate prime core of a 3/4-cluster part (slot 2), which nothing held
# before (field OP12 diag in Smart: "prime ceiling: none from ASB", policy7 at 2496000 of
# 3302400). Executable fixture: the REAL helper, plus source pins for where it is applied
# and for the HEAVY prime escape being able to lift it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart prime slot cap: $*" >&2; exit 1; }

grep -q 'int _pc = asb_smart_prime_slot_cap_khz((int)state, g_cpu_slot_hwmax\[2\],' "$F" || fail "helper not applied in fsm_interpolate_caps"
grep -q 'if (_pc > 0 && (out->cpu_max\[2\] <= 0 || out->cpu_max\[2\] > _pc))' "$F" || fail "an unmanaged (0) prime is not capped"
grep -q 'if (_lim <= 0) _lim = _hw;' "$F" || fail "HEAVY prime escape cannot lift a prime Balanced leaves unmanaged"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
[ -n "$CC_BIN" ] || { echo "PASS smart prime slot cap contract (no C compiler: source pins only)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  echo '#include <stdio.h>'
  echo 'enum { ASB_STATE_DEEP_IDLE = 0, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, ASB_STATE_GAMING };'
  sed -n '/^static int asb_smart_prime_slot_cap_khz(/,/^}$/p' "$F"
  cat <<'EOF'
static int bad = 0;
#define EQ(a, b, m) do { if ((a) != (b)) { printf("FAIL %s: got %d want %d\n", m, (a), (b)); bad++; } } while (0)
int main(void) {
    const int hw = 3302400;   /* OP12 prime */
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1), hw * 62 / 100, "moderate 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_HEAVY, hw, 4, 0, 1), hw * 62 / 100, "heavy 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_SUSTAINED, hw, 4, 0, 1), hw * 50 / 100, "sustained 50%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 1), hw * 55 / 100, "light idle screen on 55%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 0), 0, "light idle screen off: screen-off cap owns it");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_DEEP_IDLE, hw, 4, 0, 0), 0, "deep idle untouched");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_GAMING, hw, 4, 0, 1), 0, "gaming untouched");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 1, 1), 0, "a busy game is left alone");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 4608000, 2, 0, 1), 0, "2-cluster part: slot 1 is the prime, not this");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 0, 4, 0, 1), 0, "unknown hw max");
    /* Still the fastest core: above the middle cores' MODERATE share (58%). */
    if (!(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1) > hw * 58 / 100)) { puts("FAIL prime below middle share"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -o "$TMP/t" "$TMP/t.c" 2> "$TMP/e" || { cat "$TMP/e"; fail "fixture did not compile"; }
"$TMP/t" || fail "helper returned wrong caps"
echo "PASS smart prime slot cap contract"

) || { echo "FAIL in bundled contract: smart_prime_slot_cap_contract" >&2; exit 1; }

# ==== smart_wake_reblend_contract ====================================================================
(
# fix84-85: three Smart field defects.
#  1. CPH2769: after two hours screen-off the Smart blend kept the screen-off lean (pure
#     Battery rails) through the next screen-on session - the slot gate never looked at alpha.
#  2. PLQ110: GAMING <-> SUSTAINED every ~30 s at 49-52 C - exit was one degree under entry
#     and the trend path re-entered five degrees under it.
#  3. CPH2769 / OP15: the thermal-trend trim (18-32%) fired at 48-49 C on phones whose
#     learned normal is 45-54 C. In Smart the trend counts from the learned warm mark.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"; F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart wake re-blend: $*" >&2; exit 1; }
grep -Fq 'if (abs(rt->alpha_battery_x1000 - rt->last_alpha_x1000) >= 50) return 1;' "$S" || fail "alpha change does not re-blend"
grep -Fq 'if (abs(rt->interactive_bonus_x1000 - rt->last_bonus_x1000) >= 50) return 1;' "$S" || fail "bonus change does not re-blend"
grep -Fq 'rt->last_alpha_x1000 = rt->alpha_battery_x1000;' "$S" || fail "alpha not recorded at blend time"
grep -Fq 'm->therm.cpu_max_c <= sustained_temp_enter - ASB_GAME_SUS_HYST_C)' "$F" || fail "game exit lacks hysteresis"
grep -Fq '!_trend_game_exempt &&' "$F" || fail "trend path still pulls a busy game into SUSTAINED early"
G="$ROOT/src/asb_governor.c"
grep -Fq 'g_smart_rt.therm_warm_x10 / 10 > _trend_mark)' "$G" || fail "trend trim ignores the learned warm mark"
grep -Fq 'int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;' "$G" || fail "trend gate"
echo "PASS Smart re-blends on wake, and games have SUSTAINED hysteresis"

) || { echo "FAIL in bundled contract: smart_wake_reblend_contract" >&2; exit 1; }

# ==== special_builtin_redirect_contract ====================================================================
(
# Contract: no ": > file" in device scripts. ":" is a special builtin, and a failed
# redirect on one aborts the script under mksh and POSIX shells (asbdiag stopped at line 34
# when /sdcard was missing). "true > file" fails only the command.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -nE '(^|[;&|{(]|[[:space:]]):[[:space:]]*>>?[[:space:]]*["$/]' \
        runtime/*.sh tools/*.sh tools/logkit/*.sh common/*.sh action.sh service.sh post-fs-data.sh uninstall.sh apply_profile.sh customize.sh system/bin/asbdiag 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
if [ -n "$bad" ]; then printf 'FAIL special-builtin redirect:\n%s\n' "$bad" >&2; exit 1; fi
echo "PASS special-builtin redirect contract"

) || { echo "FAIL in bundled contract: special_builtin_redirect_contract" >&2; exit 1; }

# ==== surface_fallback_contract ====================================================================
(
# Contract: a phone without sys-therm/board zones still has a surface temperature.
#
# OnePlus 12 (SM8650) exposes only shell_* body sensors. surface_hotspot stayed 0 there,
# so every surface-driven heat trim was silently off on that model.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL surface fallback: $*" >&2; fail=1; }
grep -q 'g_thermal_surface_zone < 0 && g_thermal_board_zone < 0' "$M" || f "no fallback when both zones are missing"
grep -q 't->surface_hotspot_c = t->skin_temp_c;' "$M" || f "fallback does not use the shell sensor"
grep -q '!g_surface_from_skin &&' "$M" || f "borrowed surface counted twice in consensus"
grep -q 'surface_source=%s' "$G" || f "surface provenance not published"
grep -q 'surface_source' "$ROOT/tools/asb_diag.sh" || f "diag does not report the surface source"
grep -q 'policy6}/scaling_cur_freq' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read is not policy-agnostic"
grep -q 'LK_PRIME_POL:-' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "logkit phase prime read ignores LK_PRIME_POL"
[ "$fail" = 0 ] && echo "PASS surface fallback contract"
exit "$fail"

) || { echo "FAIL in bundled contract: surface_fallback_contract" >&2; exit 1; }

# ==== thermal_trend_gap_contract ====================================================================
(
# Thermal trend must not read a sleep gap or the unlock burst as a fast climb.
#
# The trend sums per-tick deltas, and ticks are 2-6 s on screen but 45 s or a whole
# suspend apart off screen. A OnePlus 15 day showed the first tick after unlock (40 -> 50 C)
# firing thermal_trend_fast - a 34% trim at the moment of interaction, "cool" 30 s later.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL thermal trend gap contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'clock_gettime(CLOCK_BOOTTIME, &_tts)' 'gap not measured on a suspend-aware clock'
need "$F" 'if (_tr_gap > 6) delta = (int)((long)delta * 6L / _tr_gap);' 'long-gap deltas are not scaled down'
need "$F" 'int _tr_wake = (m->misc.screen_on && _tr_prev_screen == 0);' 'screen-on edge not detected'
need "$F" 'fsm->warm_anchor_c = m->therm.cpu_max_c;' 'warm anchor not re-seeded on wake'
# Short ticks keep their tuning: the scale may only shrink a delta.
grep -Fq 'delta * 6L / _tr_gap' "$F" && ! grep -Eq 'delta \* _tr_gap' "$F" || fail 'deltas can be scaled up'
# The slow-climb rule itself is unchanged.
need "$F" 'if (m->therm.cpu_max_c >= 50 && _rise >= 6 && fsm->thermal_trend < 6)' 'slow-climb rule changed'
echo "PASS thermal trend gap contract"

) || { echo "FAIL in bundled contract: thermal_trend_gap_contract" >&2; exit 1; }

# ==== uevent_parking_contract ====================================================================
(
# Uevent parking: with the screen on, the uevent socket is out of epoll (a field OP15 had
# 29298 display uevents in ~7 h, each an epoll wake + panel sysfs read); the tick that sees
# the screen go off puts it back, drops what queued, and runs the screen-off work the
# uevent path runs (stats save, screen-off session plan + prearm).
# Executable fixture: the REAL park/unpark functions against epoll and a datagram socket.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/asb_governor.c"
fail() { echo "FAIL uevent parking: $*" >&2; exit 1; }

grep -q 'uev_park(epfd, uefd);' "$SRC" || fail "screen-on paths do not park"
grep -q 'if (screen_on) uev_park(epfd, uefd);' "$SRC" || fail "startup with the screen on does not park"
_off="$(sed -n '/} else if (!metrics.misc.screen_on && _ts == 1) {/,/^                }/p' "$SRC")"
printf '%s\n' "$_off" | grep -q 'uev_unpark(epfd, uefd);' || fail "tick screen-off does not unpark"
printf '%s\n' "$_off" | grep -q 'session_plan_build(&fsm, 0);' || fail "tick screen-off skips the screen-off session plan"
printf '%s\n' "$_off" | grep -q 'session_plan_apply_prearm(&fsm);' || fail "tick screen-off skips the prearm"
printf '%s\n' "$_off" | grep -q 'persistent_stats_save(&fsm);' || fail "tick screen-off skips the stats save"
grep -q 'uevent_dropped_while_parked=' "$SRC" || fail "parking not published"
grep -q 'uevent_dropped_while_parked' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show parking"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
if [ -z "$CC_BIN" ]; then echo "PASS uevent parking contract (no C compiler: source pins only)"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  printf '#include <stdio.h>\n#include <string.h>\n#include <errno.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <sys/ioctl.h>\n#include <linux/input.h>\n#include <sys/epoll.h>\n#include <sys/socket.h>\n'
  sed -n '/^static int           g_uev_parked = 0;$/,/^static void uev_unpark(int epfd, int uefd) {$/p' "$SRC" | sed '$d'
  sed -n '/^static void uev_unpark(int epfd, int uefd) {$/,/^}$/p' "$SRC"
  cat <<'EOF'
int main(void) {
    int sv[2], ep = epoll_create1(0), bad = 0;
    struct epoll_event ev = {0}, out[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0 || ep < 0) return 2;
    ev.events = EPOLLIN; ev.data.fd = sv[0];
    epoll_ctl(ep, EPOLL_CTL_ADD, sv[0], &ev);
    uev_park(ep, sv[0]);
    if (!g_uev_parked || g_uev_parks != 1) { puts("not parked"); bad++; }
    uev_park(ep, sv[0]);
    if (g_uev_parks != 1) { puts("parked twice"); bad++; }
    for (int i = 0; i < 3; i++) send(sv[1], "x", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("parked socket still wakes epoll"); bad++; }
    uev_unpark(ep, sv[0]);
    if (g_uev_parked) { puts("not unparked"); bad++; }
    if (g_uev_unpark_dropped != 3) { printf("dropped %lu, want 3\n", g_uev_unpark_dropped); bad++; }
    if (epoll_wait(ep, out, 2, 0) != 0) { puts("stale events left after unpark"); bad++; }
    send(sv[1], "y", 1, 0);
    if (epoll_wait(ep, out, 2, 0) != 1) { puts("unparked socket does not wake epoll"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -Wno-unused-function -Wno-unused-variable -o "$TMP/t" "$TMP/t.c" 2> "$TMP/err" || { cat "$TMP/err"; fail "fixture did not compile"; }
"$TMP/t" || fail "park/unpark fixture failed"
echo "PASS uevent parking contract"

) || { echo "FAIL in bundled contract: uevent_parking_contract" >&2; exit 1; }

# ==== undefined_shell_functions_contract ====================================================================
(
# Contract: every _helper called at command position in a device script is defined in that
# script (or, for the logkit, in its common library). smart_dynamic_tune.sh called an
# undefined _cfg, so wifi_powersave silently never applied.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP undefined-function contract (no python3)"; exit 0; }
python3 - "$ROOT" <<'PY'
import re,glob,os,sys
root=sys.argv[1]; os.chdir(root)
files=glob.glob('runtime/*.sh')+['action.sh','service.sh','post-fs-data.sh','apply_profile.sh','uninstall.sh','tools/asb_diag.sh']+glob.glob('tools/logkit/*.sh')
dre=re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)',re.M)
alld={f:set(dre.findall(open(f).read())) for f in files}
bad=[]
for f in files:
    d=alld[f]
    if 'logkit' in f: d=d|alld.get('tools/logkit/_asb_logkit_common.sh',set())
    for i,line in enumerate(open(f).read().split('\n'),1):
        t=line.strip()
        if t.startswith('#'): continue
        t=re.sub(r'\$\(\([^)]*\)\)','',t)
        for m in re.finditer(r'(?:^|;\s*|&&\s*|\|\|\s*|\|\s*|\$\(\s*|\b(?:then|do|else)\s+)(_[a-z][a-z0-9_]*)(?=\s|$|\)|;)',t):
            if re.match(r'\s*=', t[m.end():]): continue
            if m.group(1) not in d: bad.append('%s:%d %s'%(f,i,m.group(1)))
if bad:
    print('FAIL undefined shell functions:\n  '+'\n  '.join(bad), file=sys.stderr); sys.exit(1)
print('PASS undefined-function contract')
PY

) || { echo "FAIL in bundled contract: undefined_shell_functions_contract" >&2; exit 1; }

# ==== vendor_ceiling_cost_contract ====================================================================
(
# A vendor-raised CPU ceiling is reported by what it COST, not merely that it happened.
# The old line said "leak_observed ... reconcile.sh handles" for every raise - untrue during
# sleep detente and useless: on a OnePlus 15 night the clock exceeded ASB's limit in 3 of
# 64 screen-off samples. Raised-but-unused and really-used are counted separately.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"
fail() { echo "FAIL vendor ceiling cost contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$G" '(long)metrics.cpu.cur_freq[0] * 1000L > (long)want_p0 + 100000L' 'little clock not compared with the limit (MHz vs kHz)'
need "$G" 'if (used0 || used1) g_leak_used_ticks++;' 'really-used ticks not counted'
need "$G" 'vendor_ceiling_ticks=%lu\nvendor_ceiling_used_ticks=%lu' 'counters not published'
need "$G" 'int _lvl = (used0 || used1) ? 1 : 3;' 'unused raises still logged at the normal level'
grep -F 'asb_log(' "$G" | grep -Fq 'reconcile.sh handles' && fail 'misleading "reconcile.sh handles" text is back'
need "$A" '_vcu="$(_st vendor_ceiling_used_ticks)"' 'action does not report the cost'
echo "PASS vendor ceiling cost contract"

) || { echo "FAIL in bundled contract: vendor_ceiling_cost_contract" >&2; exit 1; }

# ==== webui_apply_truth_contract ====================================================================
(
# Contract: keys the WebUI sends to "governor reload" are keys the governor reads.
# BG_TRIM_LEVEL, UX_MANAGE_* and sustained_temp_mode were in that list; the binary parses
# none of them, so the toast said "applied" and nothing changed until a reboot.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail=0; f() { echo "FAIL webui apply truth: $*" >&2; fail=1; }
keys="$(sed -n "/var GOV_KEYS = \[/,/\];/p" "$H" | grep -oE "'[A-Za-z_]+'" | tr -d "'")"
for k in $keys; do
  # Keys handled by their own branch before the generic reload are fine.
  case "$k" in BG_TRIM_LEVEL|UX_MANAGE_OEM_TOGGLES|UX_MANAGE_TIMEOUTS|sustained_temp_mode)
    grep -q "key === '$k'" "$H" || f "$k has no dedicated apply branch"; continue ;;
  esac
  grep -q "\"$k\"" "$ROOT/src/asb_config.h" "$ROOT/src/asb_governor.c" || f "$k is reload-applied but the governor never parses it"
done
grep -q "shQuote('sustained_temp_user_override') + ' ' + shQuote('1')" "$H" || f "slider move does not publish the override flag"
grep -q 'off) asb_bg_bucket_restore >/dev/null 2>&1; break ;;' "$ROOT/service.sh" || f "six-hour bucket loop ignores BG_TRIM_LEVEL=off"
[ "$fail" = 0 ] && echo "PASS webui apply truth"
exit "$fail"

) || { echo "FAIL in bundled contract: webui_apply_truth_contract" >&2; exit 1; }

# ==== webui_hidden_poll_contract ====================================================================
(
# Contract: the WebUI does not poll the governor while it is not visible.
# The manager keeps the WebView alive in the background; its timers kept spawning root
# shells every 3 s (Live page) or 30 s (home) while the user was in another app.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)/webroot/index.html"
fail=0
sed -n '/^async function pollLive(visible) {/,/^  try {/p' "$H" | grep -q 'if (document.hidden) return;' \
  || { echo "FAIL webui: pollLive runs while hidden" >&2; fail=1; }
grep -q "if (!document.hidden) pollLive(_liveOpen);" "$H" \
  || { echo "FAIL webui: no catch-up poll when the page is shown again" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS webui hidden poll"
exit "$fail"

) || { echo "FAIL in bundled contract: webui_hidden_poll_contract" >&2; exit 1; }

# ==== writer_sybg_screen_flip_contract ====================================================================
(
# system-background follows the screen (floor 50 while on), so a screen change is a new
# target, not drift. If flips went through the drift path they would count toward the
# 5-rewrite backoff - never cleared for uclamp nodes - and every few screen cycles leave
# the node stuck at the background ceiling right after screen-on.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL sybg screen-flip contract: $*"; exit 1; }
grep -q 'static int s_sybg_screen = -1;' "$W" || fail "no per-screen memory for the sybg target"
grep -q 'if (_sybg_flip) _ucl_sybg_drift = 0;' "$W" || fail "a screen flip still counts as drift"
grep -q 'force || _ucl_bg_drift || _ucl_sybg_drift || _sybg_flip ||' "$W" || fail "a screen flip does not force the write"
grep -q 's_sybg_screen = fsm_screen_is_on ? 1 : 0;' "$W" || fail "screen state not recorded after the write"
# The floor itself must be applied identically on all three writers of the node.
[ "$(grep -c 'fsm_screen_is_on && _sybg_' "$W")" -ge 4 ] || fail "screen-on floor missing on a sybg writer"
echo "PASS sybg screen-flip contract"

) || { echo "FAIL in bundled contract: writer_sybg_screen_flip_contract" >&2; exit 1; }

echo "PASS: contract bundle (39 contracts)"
