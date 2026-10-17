#!/bin/sh
# Runtime (fix159): asbdiag ends with "your settings vs what is live" - what the user changed
# in the WebUI (name, default -> value), what the device really has (one line per live check,
# the system settings Android refused, what waits for a reboot) and a verdict that reads FAIL,
# not PASS.
#
# Field reports compared "30 PASS" on one phone with "11 PASS" on another and read the second
# as a broken install; the difference was how many tweaks were switched on. The section is cut
# out of the REAL tools/asb_diag.sh (and the REAL V()) and run against the REAL WebUI, shipped
# config and key ownership registry, with a config, a boot-time copy and an apply ledger made
# up here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL asbdiag settings summary: $*" >&2; fail=1; }
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag is not a copy of tools/asb_diag.sh"
awk '/^SEC "11. YOUR SETTINGS/ { on = 1 } /^P "  PASS=\$PASS/ { exit } on' "$D" > "$T/sec.sh"
grep -q 'WHAT YOU CHOSE' "$T/sec.sh" || { echo "FAIL asbdiag settings summary: section 11 not found" >&2; exit 1; }
awk '/^V\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$D" > "$T/v.sh"
grep -q 'CHK_LIST=' "$T/v.sh" || f "V() does not record its checks"

mkdir -p "$T/mod/config" "$T/mod/webroot" "$T/state"
cp "$ROOT/config/governor.conf.shipped" "$ROOT/config/key_ownership.tsv" "$T/mod/config/"
cp "$ROOT/webroot/index.html" "$T/mod/webroot/"
S="$T/mod/config/governor.conf.shipped"
sed -e 's/^dsp_loudness=.*/dsp_loudness=25/' -e 's/^CAMERA_LEVEL=.*/CAMERA_LEVEL=10/' \
    -e 's/^media_vol_steps=.*/media_vol_steps=30/' -e 's/^heavy_gpu_enter=.*/heavy_gpu_enter=99/' "$S" > "$T/conf"
grep -q '^dsp_loudness=25$' "$T/conf" && grep -q '^media_vol_steps=30$' "$T/conf" && grep -q '^heavy_gpu_enter=99$' "$T/conf" \
  || { echo "FAIL asbdiag settings summary: shipped config lacks the keys this test edits" >&2; exit 1; }
cp "$T/conf" "$T/boot_same"
cp "$S" "$T/boot_old"
cat > "$T/state/apply_ledger" <<'L'
1|settings|ntp_server|time.example|time.example|time.example|already_set||
2|settings|network_recommendations_enabled|0|1|1|not_writable|write rejected|
3|settings|ram_expand_switch_state|0|1|0|applied||
4|reconcile|uclamp.max|100|0|100|applied||
L
run() {
  cat > "$T/run.sh" <<EOF
P() { printf '%s\n' "\$1"; }
SEC() { P "== \$1"; }
NOTE() { P "  (i) \$1"; }
MODDIR="$T/mod"; CONF="$1"; ASB_CONFIG_STATE="$T/state"; ASB_DIAG_BOOT_CONF="$2"
PASS=0; FAIL=0; NA=0; OFFN=0; OFF_LIST=""; CHK_LIST=""
. "$T/v.sh"
V "DSP gain applied (persist.asb.dsp.gain_mb)" 2500 2500 eq
V "camera grade live" 10 "$3" eq
. "$T/sec.sh"
EOF
  sh "$T/run.sh" 2>&1
}

o="$(run "$T/conf" "$T/boot_old" 3)"
printf '%s\n' "$o" | grep -q '^  A. WHAT YOU CHOSE' || f "part A missing"
printf '%s\n' "$o" | awk '/^     Audio$/ { a = 1; next } /^     [A-Z]/ { a = 0 } a && /DSP Loudness/ && /0 -> 25/ && /\[dsp_loudness\]/ { ok = 1 } END { exit !ok }' \
  || f "DSP Loudness not listed under Audio as 0 -> 25 with its key: $o"
printf '%s\n' "$o" | grep -q 'Camera Grade .*0 -> 10 .*\[CAMERA_LEVEL\]' || f "camera grade change not listed"
printf '%s\n' "$o" | grep -q 'heavy_gpu_enter' && f "an internal engine key listed as a user choice"
printf '%s\n' "$o" | grep -Eq '^     3 of [0-9]+ WebUI settings changed' || f "changed-count line wrong: $o"
printf '%s\n' "$o" | grep -q 'Media Volume Steps .*stock -> 30  (waits for a reboot)' || f "reboot-scoped change not flagged"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot (changed after this boot, read only at boot):$' || f "waiting-for-reboot heading missing"
printf '%s\n' "$o" | grep -q '^       Media Volume Steps: stock -> 30   \[media_vol_steps\]$' || f "waiting key not named"
printf '%s\n' "$o" | grep -q '^       Camera Grade: 0 -> 10   \[CAMERA_LEVEL\]$' || f "reboot-scoped camera grade not listed as waiting"
printf '%s\n' "$o" | grep -q 'DSP Loudness:' && f "a setting applied live listed as waiting for a reboot"
printf '%s\n' "$o" | grep -q '^     \[PASS\] DSP gain applied (persist.asb.dsp.gain_mb)  ->  2500$' || f "PASS check not echoed in part B"
printf '%s\n' "$o" | grep -q '^     \[FAIL\] camera grade live  ->  3$' || f "FAIL check not echoed in part B"
printf '%s\n' "$o" | grep -q 'applied 1 · already set 1 · refused by Android 1' || f "ledger totals wrong (reconcile rows must not count): $o"
printf '%s\n' "$o" | grep -q 'refused, not in effect: settings/network_recommendations_enabled (wanted 0, device keeps 1)' || f "refused key not named"
printf '%s\n' "$o" | grep -q '^     FAIL=1 - these did not take effect' || f "verdict does not name the failure count"
printf '%s\n' "$o" | grep -q '^       camera grade live: want 10, live 3$' || f "failing check not listed in the verdict"
printf '%s\n' "$o" | grep -q 'Read FAIL, not PASS' || f "PASS-count explanation missing"

o="$(run "$T/conf" "$T/boot_same" 10)"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot: nothing' || f "nothing pending not said when the boot copy matches"
printf '%s\n' "$o" | grep -q '(waits for a reboot)' && f "a change already booted with flagged as waiting"
printf '%s\n' "$o" | grep -q '^     FAIL=0 - everything this report can check for your settings is in effect.$' || f "clean verdict missing"

o="$(run "$S" "$T/missing" 10)"
printf '%s\n' "$o" | grep -q '^     nothing - every setting is at its shipped default$' || f "all-default config not described: $o"
printf '%s\n' "$o" | grep -q '^     waiting for a reboot: unknown' || f "missing boot copy not reported as unknown"
printf '%s\n' "$o" | grep -q 'not an install error' || f "default-is-not-an-error line missing"

grep -q 'cp -f "$MODDIR/config/governor.conf" /dev/.asb_profile_state/governor.boot.conf' "$ROOT/post-fs-data.sh" \
  || f "post-fs-data does not keep the config this boot used"
[ "$fail" = 0 ] && echo "PASS asbdiag settings summary: your choices, what is live, refused writes, pending reboots and a FAIL-based verdict"
exit "$fail"
