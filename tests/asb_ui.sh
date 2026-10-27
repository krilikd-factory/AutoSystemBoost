#!/usr/bin/env bash
# ASB host tests: WebUI, log kit, asbdiag and capture comparison.
#
# Each test is a function t_<name> whose body runs in its own subshell, exactly as the
# standalone script it used to be; the C fixtures it builds are the functions _c_<name>.
#   bash tests/asb_ui.sh                 run every test in this file
#   bash tests/asb_ui.sh NAME [NAME...]  run the named tests
#   bash tests/asb_ui.sh --list          list the tests
#   bash tests/asb_ui.sh --source NAME   print an embedded C fixture
# tools/asb_full_regression.sh runs every test of every tests/asb_*.sh in parallel.

t_asbdiag_report_host_runtime() (
# Runtime (fix151): asbdiag says which janky frames are its own output scrolling.
#
# A CPH2691 report run from Termux: "com.termux 663 of 676 frames (20.72/s)" and "steady:
# com.termux missed 663 of the 676 frames ... while you only waited for this report". An
# outside audit read that as "over 90% UI lag in Termux, up to 20 a second" and proposed CPU
# boosts and big-core whitelists for it. Termux was drawing the report. The REAL functions
# run on a fake /proc and cpuset: the app in front at the start is found from the top-app
# group (uid >= 10000, oom_score_adj 0), and its line says it is the report's own window.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag report host: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^# asb_gfx_pkg_begin$/,/^# asb_gfx_pkg_end$/p' "$D" > "$T/f.sh"
grep -q '^asb_report_host() {' "$T/f.sh" || fail "no host lookup in the testable block"
mkdir -p "$T/cpuset/top-app"
mk() {   # pid uid oom cmdline
  mkdir -p "$T/proc/$1"
  printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$2" "$2" "$2" > "$T/proc/$1/status"
  echo "$3" > "$T/proc/$1/oom_score_adj"
  printf '%s\000' "$4" > "$T/proc/$1/cmdline"
}
mk 100 1000 0 system_server
mk 200 10123 200 com.google.android.inputmethod.latin
mk 300 10234 0 /data/data/com.termux/files/usr/bin/bash
mk 400 10234 0 com.termux
printf '100\n200\n300\n400\n' > "$T/cpuset/top-app/cgroup.procs"
h="$(ASB_PROC_ROOT="$T/proc" ASB_CPUSET_ROOT="$T/cpuset" sh -c '. "$1"; asb_report_host' x "$T/f.sh")"
[ "$h" = com.termux ] || fail "host: '$h', want com.termux"
printf 'com.termux 1000 10\ncom.android.systemui 2000 20\n' > "$T/a"
printf 'com.termux 1676 673\ncom.android.systemui 3144 44\n' > "$T/b"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.termux' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q 'com.termux 663 of 676 frames (20.72/s, the window this report is printed in)' || fail "per-app line: $d"
printf '%s\n' "$d" | grep -q '^host: com.termux missed 663 of the 676 frames it drew - the report scrolling in it, not a lag$' || fail "host line: $d"
printf '%s\n' "$d" | grep -q '^steady:' && fail "the report's own window called a steady redraw: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 com.rifsxd.ksunext' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q '^steady: com.termux missed 663' || fail "another app in front still gets the steady verdict: $d"
# fix178: no host found at all (a CPH2691 run from Termux) - a terminal at the top is the host.
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 ""' x "$T/f.sh" "$T/a" "$T/b")"
printf '%s\n' "$d" | grep -q '^host: com.termux missed 663' || fail "a terminal at the top without a host lookup: $d"
printf '%s\n' "$d" | grep -q 'the window this report is printed in' || fail "no host label on the terminal's line: $d"
printf 'com.example.feed 1000 10\ncom.android.systemui 2000 20\n' > "$T/a2"
printf 'com.example.feed 1676 673\ncom.android.systemui 3144 44\n' > "$T/b2"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(cat "$2")" "$(cat "$3")" 32 ""' x "$T/f.sh" "$T/a2" "$T/b2")"
printf '%s\n' "$d" | grep -q '^steady: com.example.feed missed 663' || fail "an ordinary app at the top lost its steady verdict: $d"
grep -q 'asb_gfx_run_delta "$_gfx_run0" "$_gfx_run1" "$(( $(date +%s) - ${_gfx_run0_t:-0} ))" "$_gfx_host"' "$D" || fail "7c does not pass the host"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag report host: the window the report prints into is named, not read as lag"
)

t_asbdiag_wake_paths_runtime() (
# Runtime (fix178): two asbdiag lines that misread a CPH2691.
#
# "WARN: 4 of 4 screen wakes were found only by the idle tick" on a phone whose governor had
# caught 32 wakes on the display-state path (screen_on_detect=uevent:0,recheck:0,tick:4,display:32)
# - the total left that path out. And the status-bar settings list printed the whole of
# oplus.radio.smart5g_apk_cfg, matched on "Internetspeed" inside its value. The REAL lines run.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag wake paths: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ echo '_sod="uevent:0,recheck:0,tick:4,display:32"; _sot=4'
  sed -n '/_sou="$(printf .%s. "$_sod" | sed -n .s\/.\*uevent/,/^    _sall=/p' "$D"
  echo 'echo "$_sall"'; } > "$T/w.sh"
grep -q '_sodp=' "$T/w.sh" || fail "the display path is not read"
[ "$(sh "$T/w.sh")" = 36 ] || fail "wake total: $(sh "$T/w.sh"), want 36"
prog="$(grep -m1 "awk -F= 'tolower(\$1) ~ /net(work)?_?speed" "$D" | sed "s/.*awk -F= '//; s/' *\\\\\$//")"
[ -n "$prog" ] || fail "status-bar matcher not found"
out="$(printf '%s\n' 'system:oplus.radio.smart5g_apk_cfg=ver_num=9;filetrans=com.Wifi.lte5g.speedtest.Internetspeed' \
                     'system:show_network_speed=1' 'secure:clock_seconds=0' 'global:wifi_on=1' | awk -F= "$prog")"
printf '%s\n' "$out" | grep -q 'smart5g' && fail "a key matched on its value: $out"
printf '%s\n' "$out" | grep -qx 'system:show_network_speed=1' || fail "network speed key missed: $out"
printf '%s\n' "$out" | grep -qx 'secure:clock_seconds=0' || fail "clock seconds key missed: $out"
# fix178: the codec of the ACTIVE A2DP device (an inactive one listed first is not it), and the
# multipoint hint only for a high-bitrate codec. The REAL block runs against a stub dumpsys.
mkdir -p "$T/bin"
cat > "$T/bin/dumpsys" <<'B'
#!/bin/sh
cat "$DUMP"
B
chmod +x "$T/bin/dumpsys"
{ echo 'NOTE() { echo "NOTE $*"; }'
  sed -n '/^_btc="\$(dumpsys bluetooth_manager/,/^fi$/p' "$D"; } > "$T/c.sh"
grep -q 'mCodecConfig' "$T/c.sh" || fail "codec block not found"
cat > "$T/dump1" <<'B'
  === A2dpStateMachine for XX:XX:XX:XX:9D:9F ===
    mCodecConfig: {codecName:SBC,mCodecType:0,mCodecPriority:1001,mSampleRate:0x1(44100),mBitsPerSample:0x1(16),mChannelMode:0x2(STEREO)}
  === A2dpStateMachine for XX:XX:XX:XX:B8:86 (Active) ===
    mConnectionState: STATE_CONNECTED, mLastConnectionState: STATE_CONNECTING
    mCodecConfig: {codecName:LHDC,mCodecType:19,mCodecPriority:9002,mSampleRate:0x2(48000),mBitsPerSample:0x2(24),mChannelMode:0x2(STEREO)}
B
out="$(PATH="$T/bin:$PATH" DUMP="$T/dump1" sh "$T/c.sh")"
printf '%s\n' "$out" | grep -qx 'NOTE active A2DP codec: LHDC 48000 Hz / 24-bit' || fail "active codec line: $out"
printf '%s\n' "$out" | grep -q 'multipoint' || fail "no multipoint hint on LHDC: $out"
sed 's/codecName:LHDC/codecName:AAC/' "$T/dump1" > "$T/dump2"
out="$(PATH="$T/bin:$PATH" DUMP="$T/dump2" sh "$T/c.sh")"
printf '%s\n' "$out" | grep -qx 'NOTE active A2DP codec: AAC 48000 Hz / 24-bit' || fail "AAC codec line: $out"
printf '%s\n' "$out" | grep -q 'multipoint' && fail "multipoint hint on AAC: $out"
out="$(PATH="$T/bin:$PATH" DUMP=/dev/null sh "$T/c.sh")"
[ -z "$out" ] || fail "no A2DP device still printed: $out"
# fix178: the Wi-Fi link line names the band, not the network, and skips state-machine rows.
cat > "$T/bin/cmd" <<'B'
#!/bin/sh
[ "$1 $2" = "wifi status" ] && cat "$CMDOUT"
B
chmod +x "$T/bin/cmd"
{ echo 'P() { echo "$*"; }; NOTE() { echo "NOTE $*"; }'
  sed -n '/^_wfl="\$({ cmd wifi status/,/^case "\$_wfl" in/p' "$D"; } > "$T/wf.sh"
grep -q 'Frequency' "$T/wf.sh" || fail "wifi link block not found"
printf '%s\n' '       rec[5]: time=10-18 18:10:22.130 processed=DefaultState org=EnabledState SSID x' \
  'mWifiInfo SSID: "home", BSSID: 11:22:33:44:55:66, Wi-Fi standard: 11ax, RSSI: -61, Link speed: 573Mbps, Tx Link speed: 573Mbps, Rx Link speed: 432Mbps, Frequency: 2437MHz' > "$T/wd"
out="$(PATH="$T/bin:$PATH" DUMP="$T/wd" CMDOUT=/dev/null sh "$T/wf.sh")"
printf '%s\n' "$out" | grep -qx '  live wifi link: 2437 MHz (2.4 GHz), RSSI -61 dBm, 573 Mbps, 11ax' || fail "wifi link: $out"
printf '%s\n' "$out" | grep -q 'home\|11:22' && fail "the network name or BSSID reached the report: $out"
printf '%s\n' "$out" | grep -q '^NOTE Wi-Fi on 2.4 GHz' || fail "no 2.4 GHz note: $out"
printf '%s\n' 'Wifi is connected to "home"' 'WifiInfo: SSID: "home", RSSI: -50, Link speed: 1200Mbps, Frequency: 5745MHz' > "$T/wc"
out="$(PATH="$T/bin:$PATH" DUMP=/dev/null CMDOUT="$T/wc" sh "$T/wf.sh")"
[ "$out" = '  live wifi link: 5745 MHz (5 GHz), RSSI -50 dBm, 1200 Mbps' ] || fail "cmd wifi status link: $out"
printf 'mWifiInfo SSID: <unknown ssid>, RSSI: -127, Link speed: -1Mbps, Frequency: -1MHz\n' > "$T/wd"
out="$(PATH="$T/bin:$PATH" DUMP="$T/wd" CMDOUT=/dev/null sh "$T/wf.sh")"
[ "$out" = '  live wifi link: not connected, or the ROM printed no link line' ] || fail "disconnected link: $out"
# fix179: who held Wi-Fi multicast since the unplug, from batterystats' per-uid blocks.
cat > "$T/bin/dumpsys" <<'B'
#!/bin/sh
printf '  Total WiFi Multicast wakelock time: 3h 49m\n  1000:\n    WiFi Multicast Wakelock count = 12 time = 41m2s3ms\n  u0a345:\n    WiFi Multicast Wakelock count = 3 time = 11m56s541ms\n'
B
cat > "$T/bin/pm" <<'B'
#!/bin/sh
printf 'package:com.instagram.android uid:10345\npackage:com.other uid:103450\n'
B
chmod +x "$T/bin/dumpsys" "$T/bin/pm"
{ echo 'P() { echo "$*"; }; _mct=13752'
  sed -n '/^  if \[ "\$_mct" -ge 600 \]; then$/,/^  fi$/p' "$D"; } > "$T/mc.sh"
grep -q 'held since the unplug' "$T/mc.sh" || fail "multicast holder block not found"
out="$(PATH="$T/bin:$PATH" sh "$T/mc.sh")"
printf '%s\n' "$out" | grep -qx '    held since the unplug: system  ·  WiFi Multicast Wakelock count = 12 time = 41m2s3ms' || fail "system holder: $out"
printf '%s\n' "$out" | grep -qx '    held since the unplug: com.instagram.android  ·  WiFi Multicast Wakelock count = 3 time = 11m56s541ms' || fail "app holder: $out"
printf '%s\n' "$out" | grep -q 'com.other' && fail "a uid prefix matched another app: $out"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag wake paths: the display path counts in the wake total, status-bar keys are matched by name, the active codec, the Wi-Fi band and the multicast holders are named"
)

t_asbdiag_write_ratio_runtime() (
# Runtime (fix179): "writes per transition" is judged against the phone's own cpufreq slots,
# and chatter by how often the state changes. A CPH2691 read "13 (8+ ... suggests the ladder
# is chattering)" with three slots, 65 unlock lifts, 63 prime bursts, 296 re-sends through a
# vendor hold and 35 state changes an hour. The REAL block of tools/asb_diag.sh runs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail() { echo "FAIL asbdiag write ratio: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^  if \[ "\$_ov_t" -gt 0 \] 2>\/dev\/null; then$/ { f = 1 } f { print } f && /^  fi$/ { exit }' "$D" > "$T/b.sh"
grep -q '_ov_nd' "$T/b.sh" || fail "ratio block not found"
run() {  # $1 transitions, $2 writes, $3 slots, $4 uptime
  printf 'governor_transitions=%s\ngovernor_writes=%s\nslot_policy_ids=%s\nunlock_lifts=65\nprime_escape_count=63\nwriter_hold_bypass=296\ngovernor_uptime_s=%s\ncap_vendor_passive=0\ngovernor_vendor_overrides=0\n' "$1" "$2" "$3" "$4" > "$T/st"
  { echo 'P() { echo "$*"; }; _rget() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed "s/^[^=]*=//"; }'
    echo "_state=$T/st; _ov_t=$1; _ov_w=$2"; cat "$T/b.sh"; } > "$T/r.sh"
  sh "$T/r.sh"
}
out="$(run 224 2940 0,2,5 22800)"
printf '%s\n' "$out" | grep -q 'chattering$' && fail "the CPH2691 still reads as chattering: $out"
printf '%s\n' "$out" | grep -q 'above the 9 nodes one transition writes on 3 cpufreq slot(s).*65 unlock lift(s), 63 prime burst(s) and 296 re-send(s)' || fail "OP12 breakdown: $out"
printf '%s\n' "$out" | grep -q '35 an hour, one every 101 s on average - not a chattering ladder' || fail "OP12 rate: $out"
out="$(run 628 5544 0,6,-1 86186)"
printf '%s\n' "$out" | grep -q 'writes per transition: 8 - above the 7 nodes one transition writes on 2 cpufreq slot(s)' || fail "OP15 ratio: $out"
out="$(run 900 3600 0,6,-1 3600)"
printf '%s\n' "$out" | grep -q 'normal - one transition writes up to 7 nodes' || fail "normal ratio: $out"
printf '%s\n' "$out" | grep -q '900 an hour, one every 4 s - the ladder is chattering' || fail "real chatter not named: $out"
out="$(run 5 40 0,6,-1 3600)"
printf '%s\n' "$out" | grep -q 'too few to judge' || fail "few transitions: $out"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag write ratio: writes per transition against the phone's own slots, chatter by how often the state changes"
)

t_asbdiag_settings_summary_runtime() (
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
5|settings|cloud_dns_happy_eyeballs_priority_enabled|off|||unsupported|key absent on this ROM|
6|sysfs|some_node|1|||unsupported|node absent on this device|
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
# fix221: an absent-on-this-ROM settings key is counted and listed apart from refusals;
# an unsupported SYSFS node is neither counted nor listed here.
printf '%s\n' "$o" | grep -q 'refused by Android 1 · not on this ROM 1' || f "absent-on-ROM count missing: $o"
printf '%s\n' "$o" | grep -q '^       not on this ROM: settings/cloud_dns_happy_eyeballs_priority_enabled (wanted off) - this ROM has no such setting; nothing is wrong$' || f "absent-on-ROM key not listed: $o"
printf '%s\n' "$o" | grep -q 'some_node' && f "an unsupported sysfs node leaked into the settings list: $o"
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
)

t_capture_compare_runtime() (
# Runtime (fix152): the host comparison of field logs, build against build.
#
# Asked for: "after the tests I will send a new archive of logs from different users - compare
# how much better it got". The REAL tool reads full-day captures and asbdiag reports from
# folders and zips (a zip inside a zip too), counts a capture sent twice once, saves the
# figures (--json) and compares a new set with them per phone model (--baseline): lower drain
# and fewer janky frames read "better", a figure the report marks '~' is not compared.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_capture_compare.py"
fail() { echo "FAIL capture compare: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP capture compare: no python3"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cap() {   # dir model start night_pct night_awake idle_pct janky_s li_s cpu_ms wifi_med
  mkdir -p "$1"
  printf 'model:           %s\nmodule_version:  V65-debug%s\noem_build:       X\n' "$2" "$3" > "$1/env.txt"
  printf '# phase timeline\n%s|2026-10-20 08:00:00|active|capture_start\n' "$3" > "$1/phase_timeline.txt"
  printf 'governor_cpu_ms=%s\ngovernor_uptime_s=36000\n' "$9" > "$1/snapshot_1.txt"
  cat > "$1/_full_day_report.txt" <<R
 capture: 24h target, 1200 min elapsed
===== UI SMOOTHNESS (screen-on, HWUI frames of every app) =====
all screen-on intervals: 400  frames 900000  janky 4.0%  deadline missed 4.0%  slow UI thread 2.0%
janky frames per second on screen: $7
ASB state        intervals    frames    janky  janky/s
MODERATE               278    756613     3.0%     1.70
LIGHT_IDLE              65     44071    28.1%     $8

steady floor: 1.11 janky frames a second while almost nothing was drawn (under 5 frames/s),
1.73 a second in the busy intervals (20 frames/s and more). Something misses a deadline about
screen-on samples 472: prime cores working in 14%, main cores in 81%
===== WI-FI LEAVE (the leave-bad-Wi-Fi watcher, this capture) =====
releases: 3 (out of range 2, no internet 1) - Wi-Fi given back after the window: 3, could not disable: 0
first failing reading to the release: median ${10} s, longest 12 s (3 release(s))
===== PER-PHASE SUMMARY =====

phase            dur_min   d_pct    pct/h     mA  rmnetMiB     cpuT    surfT     p6MHz    gpu%  throttle   awake%
active             142.2      26   10.97     297    1420.4       39       35       917       7        39     98.1
idle               126.3       4    $6     182     106.1       34       36       806       5         0     23.5
sleep              553.9       6    0.65     155     113.2       36       38       768       4         0      5.1
night(longest)     538.2       5     $4    154         -       37       39       768       -         -      $5

Legend: x
R
}
cap "$T/old/a" CPH2745 1000 0.56 4.0 1.90 2.08 3.92 18000 20
cap "$T/old/b" CPH2691 2000 0.90 9.0 5.50 1.94 2.50 18000 20
cap "$T/new/a" CPH2745 3000 0.44 3.0 1.95 1.80 2.00 14400 6
cap "$T/new/b" CPH2691 4000 0.95 9.5 3.36~ 1.94 2.50 18000 6
( cd "$T/new" && mkdir -p z && cp -r a z/dup && cd z && python3 -c "
import zipfile,os
with zipfile.ZipFile('inner.zip','w') as z:
    for r,_,fs in os.walk('dup'):
        for f in fs: z.write(os.path.join(r,f))
with zipfile.ZipFile('../outer.zip','w') as z: z.write('inner.zip')
" && cd .. && rm -rf z )
cat > "$T/new/diag.txt" <<'D'
################################################################
#         AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC            #
################################################################
 date    : Mon Oct 20 10:00:00 CEST 2026
 device  : OnePlus CPH2745  (OP611FL1)
 version : V65-debug9  (650)
  ASB overhead          : event_wakeups=1 timer_wakeups=2 cpu_ms=14201 over 8 h 36 min = 1.6 s of CPU per hour
    mSafeMediaVolumeState=SAFE_MEDIA_VOLUME_INACTIVE
  (i) net_txqueue=short - live: rmnet_data0=1000 wlan0=256
  (i) doze_trim_whitelist = 1 · trimmed by ASB: 7 · kept (WebUI list): 3 · made exempt by ASB: 1
    audio_remove_volume_limit=1
D
python3 "$TOOL" "$T/old" --json "$T/base.json" --label base > "$T/o1" || fail "baseline run failed"
grep -q '^FULL-DAY CAPTURES (2)$' "$T/o1" || fail "baseline captures: $(head -3 "$T/o1")"
python3 "$TOOL" "$T/new" "$T/new/outer.zip" --baseline "$T/base.json" > "$T/o2" || fail "compare run failed"
grep -q '^FULL-DAY CAPTURES (2)$' "$T/o2" || fail "a capture sent twice (a zip inside a zip) counted twice: $(grep -c CPH2745 "$T/o2")"
grep -q '^night %/h *0.56 *0.44 .*better' "$T/o2" || fail "night not better: $(grep 'night %/h' "$T/o2")"
grep -q '^LIGHT_IDLE janky/s *3.92 *2.00 .*better' "$T/o2" || fail "LIGHT_IDLE jank: $(grep LIGHT "$T/o2")"
grep -q '^Wi-Fi leave median s *20 *6 .*better' "$T/o2" || fail "Wi-Fi leave: $(grep 'Wi-Fi leave' "$T/o2")"
grep -q '^ASB CPU s/h *1.80 *1.44 .*better' "$T/o2" || fail "ASB CPU: $(grep 'ASB CPU s/h' "$T/o2")"
grep -q '^night %/h *0.90 *0.95 .*same' "$T/o2" || fail "a 5% change called a verdict: $(grep 'night %/h' "$T/o2")"
grep -q '^idle %/h *5.50 *- ' "$T/o2" || fail "a '~' figure was compared: $(grep 'idle %/h' "$T/o2")"
grep -q 'wlan0=256' "$T/o2" || fail "the Wi-Fi queue from asbdiag is not shown"
grep -q 'doze trim 7/kept 3/granted 1' "$T/o2" || fail "the doze trim figures from asbdiag are not shown"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['label']=='base' and len(d['captures'])==2" "$T/base.json" || fail "saved figures unreadable"
python3 "$TOOL" "$ROOT/docs/field_baseline" --baseline "$ROOT/docs/field_baseline/fix150.json" >/dev/null || fail "the stored fix150 baseline does not load"
echo "PASS capture compare: field logs read from folders and nested zips, one capture once, build against build per model"
)

t_capture_compare_warm_runtime() (
# Runtime (fix156): the comparison reads how the clusters were used while the phone was warm.
#
# fix156 keeps the main cores level with the prime under Smart's comfort trim and in HEAVY and
# SUSTAINED. What should change in the next round of logs: fewer warm screen-on samples with the
# main ceiling under the prime's, the prime working less, a lower sampled current. The REAL
# tool computes those from the raw traces of a capture (so captures made before the report
# printed them compare too): screen-on samples only, surface 40 C and above, capacities from the
# governor state, hardware maxima from the throttle trace; and the --baseline table names them.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_capture_compare.py"
fail() { echo "FAIL capture compare warm: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP capture compare warm: no python3"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cap() {
  d="$T/$1"; mkdir -p "$d"
  printf 'model:           CPH2745\nmodule_version:  V65-debug%s\n' "$2" > "$d/env.txt"
  printf '%s|2026-10-20 08:00:00|active|capture_start\n' "$3" > "$d/phase_timeline.txt"
  printf ' capture: 24h target, 600 min elapsed\n' > "$d/_full_day_report.txt"
  printf 'main_parity_capacity="762,1024"\n' > "$d/snapshot_1.txt"
  printf '# throttle trace\n%s|active|p0_max=1555200/3628800|p6_max=1862400/4608000|cpu_temp=50\n' "$3" > "$d/throttle_trace.txt"
  echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$d/display_trace.txt"
  echo "epoch|datetime|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max|x|x|x|x|x|bat_mA|x|x|x|x|x|x|x|x|x|x|x|x|x|surface_c" > "$d/perf_trace.txt"
}
row() {   # dir epoch screen p0_max p6_cur p6_max mA surface
  echo "$2|d|active|$3|1|1|1|90|1||" >> "$T/$1/display_trace.txt"
  echo "$2|d|||||||||||1|$4|$5|$6||||||$7||||||||||||||$8" >> "$T/$1/perf_trace.txt"
}
cap old 8 1000
e=1000
for i in 1 2 3 4; do row old $e 1 1555200 1862400 1862400 480 44; e=$((e + 20)); done
for i in 1 2; do row old $e 1 1996800 768000 1862400 340 43; e=$((e + 20)); done
row old $e 1 1555200 1862400 1862400 900 33; e=$((e + 20))
row old $e 0 1555200 1862400 1862400 900 45; e=$((e + 20))
cap new 10 5000
e=5000
for i in 1 2 3 4 5; do row new $e 1 1996800 768000 1862400 330 44; e=$((e + 20)); done
row new $e 1 1996800 1862400 1862400 410 42
python3 "$TOOL" "$T/old" --json "$T/base.json" --label old > "$T/o1" 2>&1 || { cat "$T/o1" >&2; fail "tool failed"; }
python3 - "$T/base.json" <<'P' || fail "warm figures of the old capture"
import json, sys
c = json.load(open(sys.argv[1]))["captures"][0]
want = {"warm_on_n": 6, "warm_below_pct": 66.7, "warm_prime_pct": 66.7, "warm_on_ma": 433}
bad = {k: (c.get(k), v) for k, v in want.items() if c.get(k) != v}
if bad:
    print(bad); sys.exit(1)
P
python3 "$TOOL" "$T/new" --baseline "$T/base.json" > "$T/o2" 2>&1 || { cat "$T/o2" >&2; fail "comparison failed"; }
grep -qE '^warm: main under prime % +66\.70 +0\.00 +-66\.70 \(-100%\) +better' "$T/o2" || fail "main-under-prime row: $(cat "$T/o2")"
grep -qE '^warm: prime working % +66\.70 +16\.70 .* better' "$T/o2" || fail "prime row: $(cat "$T/o2")"
grep -qE '^warm screen-on mA +433 +343 .* better' "$T/o2" || fail "current row: $(cat "$T/o2")"
cap cool 9 9000
e=9000
for i in 1 2 3 4 5 6; do row cool $e 1 1555200 1862400 1862400 480 35; e=$((e + 20)); done
python3 "$TOOL" "$T/cool" --json "$T/cool.json" > "$T/o3" 2>&1 || fail "cool capture"
python3 -c "import json,sys; c=json.load(open(sys.argv[1]))['captures'][0]; sys.exit(0 if c['warm_on_n'] is None and c['warm_on_ma'] is None else 1)" "$T/cool.json" || fail "a capture that never got warm produced warm figures"
echo "PASS capture compare warm: warm screen-on samples, main under the prime, prime work and current, from the raw traces"
)

t_cluster_roles_runtime() (
# Runtime (fix146): the capture judges the cores the governor calls main, and says which.
#
# 1. The jank trace took the lowest and the highest policy for "main" and "prime". On a
#    1+3+2+1 part (CPH2691, SM8650: policies 0/2/5/7) "main" was the A520 pair, which runs
#    no UI - every "main cores at the ASB ceiling" line of those captures described the
#    wrong cores. Main and prime now come from the governor's slot_policy_ids.
# 2. The report names them where it is not the obvious pair, and the throttle split calls
#    slot 0 "little" there instead of "main".
# 3. The per-app table went to the app with the most frames only; on PLQ110 capture 28616
#    that was the app store while "LIGHT_IDLE 25.6% janky" was YouTube playing untouched.
#    The app in front with the most janky frames gets its own table.
# 4. asbdiag called policy0 of a 6+2 part "little".
# The REAL functions run here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL cluster roles: $*" >&2; fail=1; }

# --- 1. roles from the governor's map --------------------------------------------------------
roles() { printf 'slot_policy_ids=%s\n' "$1" > "$T/st"; ASB_LK_STATE_FILE="$T/st" sh -c '. "$0" >/dev/null 2>&1; lk_cluster_roles' "$C"; }
[ "$(roles 0,2,7)" = "2 7 0" ] || f "1+3+2+1 map: '$(roles 0,2,7)' (want main 2, prime 7, little 0)"
[ "$(roles 0,6,-1)" = "0 6 -" ] || f "6+2 map: '$(roles 0,6,-1)' (want main 0, prime 6)"
: > "$T/st"
[ -z "$(ASB_LK_STATE_FILE="$T/st" sh -c '. "$0" >/dev/null 2>&1; lk_cluster_roles' "$C")" ] || f "roles invented with no map"

# --- 2. the recorder measures policy2, not policy0, on a 4-cluster part ----------------------
for p in 0 2 5 7; do mkdir -p "$T/cpufreq/policy$p/stats"; done
# policy0 (little) idles far below its ceiling; policy2 (main) sits at it the whole interval.
echo 1017600 > "$T/cpufreq/policy0/scaling_max_freq"; echo 364800 > "$T/cpufreq/policy0/scaling_cur_freq"
echo 1497600 > "$T/cpufreq/policy2/scaling_max_freq"; echo 1497600 > "$T/cpufreq/policy2/scaling_cur_freq"
echo 1497600 > "$T/cpufreq/policy5/scaling_max_freq"; echo 1497600 > "$T/cpufreq/policy5/scaling_cur_freq"
echo 1593600 > "$T/cpufreq/policy7/scaling_max_freq"; echo 480000  > "$T/cpufreq/policy7/scaling_cur_freq"
printf '364800 1000\n1017600 0\n' > "$T/cpufreq/policy0/stats/time_in_state"
printf '499200 0\n1497600 1000\n' > "$T/cpufreq/policy2/stats/time_in_state"
printf '480000 1000\n1593600 0\n' > "$T/cpufreq/policy7/stats/time_in_state"
printf 'state=MODERATE\ntouch_starts=1\nslot_policy_ids=0,2,7\n' > "$T/st4"
gfx() { printf 'Package: com.x\nStats since: 1000ns\nTotal frames rendered: %s\nJanky frames: %s (1.00%%)\nNumber Frame deadline missed: %s\nNumber Slow UI thread: 0\nNumber High input latency: 0\n' "$2" "$3" "$3" > "$1"; }
gfx "$T/g1" 1000 10; gfx "$T/g2" 3000 50
mkdir -p "$T/c"
rec="$(LK_OUT_DIR="$T/c" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_STATE_FILE="$T/st4" T="$T" sh -c '
  . "$0" >/dev/null 2>&1
  lk_jank_trace_header
  ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  printf "499200 0\n1497600 2000\n" > "$T/cpufreq/policy2/stats/time_in_state"
  printf "364800 2000\n1017600 0\n" > "$T/cpufreq/policy0/stats/time_in_state"
  printf "480000 2000\n1593600 0\n" > "$T/cpufreq/policy7/stats/time_in_state"
  ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
' "$C" 2>&1)"
r="$(printf '%s\n' "$rec" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r" | cut -d'|' -f6)" = 1 ] || f "main_at_cap not from policy2 (at its ceiling): $r"
[ "$(printf '%s' "$r" | cut -d'|' -f14)" = 100 ] || f "main_cap_pct not from policy2 (100% at the ceiling): $r"
[ "$(printf '%s' "$r" | cut -d'|' -f7)" = 0 ] || f "prime_at_cap not from policy7: $r"
L="$T/c/cluster_layout.txt"
[ -s "$L" ] || f "no cluster_layout.txt"
grep -qx 'policies=0 2 5 7' "$L" || f "layout policies: $(cat "$L" 2>/dev/null)"
grep -qx 'main=policy2' "$L" && grep -qx 'prime=policy7' "$L" && grep -qx 'little=policy0' "$L" || f "layout roles: $(cat "$L" 2>/dev/null)"
# A 6+2 part: no little line, policy0 is main.
mkdir -p "$T/c2" "$T/cf2/policy0" "$T/cf2/policy6"
printf 'slot_policy_ids=0,6,-1\n' > "$T/st2"
LK_OUT_DIR="$T/c2" ASB_LK_CPUFREQ_ROOT="$T/cf2" ASB_LK_STATE_FILE="$T/st2" sh -c '. "$0" >/dev/null 2>&1; lk_jank_trace_header' "$C"
grep -qx 'main=policy0' "$T/c2/cluster_layout.txt" && ! grep -q '^little=' "$T/c2/cluster_layout.txt" || f "6+2 layout: $(cat "$T/c2/cluster_layout.txt" 2>/dev/null)"

# --- 3. report: names the clusters on a 4-cluster part only --------------------------------
J="$T/c/jank_trace.tsv"
i=0
row() {   # state touches frames janky front pkgs
  i=$((i + 1))
  printf '%s|t|active|%s|48|1|0|%s|%s|%s|%s|5|1|70|0|%s|%s\n' "$i" "$1" "$2" "$3" "$4" "$4" "$5" "$6" >> "$J"
}
for k in 1 2 3 4 5 6; do row MODERATE 2 9000 30 com.heytap.market "com.heytap.market:28:8800"; done
for k in 1 2; do row MODERATE 0 3000 0 com.heytap.market "-"; done
for k in 1 2 3; do row MODERATE 0 600 130 com.google.android.youtube "com.google.android.youtube:128:590"; done
for k in 1 2 3 4; do row LIGHT_IDLE 0 500 135 com.google.android.youtube "com.google.android.youtube:134:495"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/c" 2>&1)"
printf '%s\n' "$out" | grep -q '^main cores below = policy2 and policy5 (the middle clusters, under one ceiling), prime = policy7; the little cluster (policy0) runs no UI and is not in these lines.$' \
  || f "4-cluster layout line: $out"
printf '%s\n' "$out" | grep -q '^within com.heytap.market (most frames), by ASB state and touch:$' || f "most-frames table: $out"
printf '%s\n' "$out" | grep -q '^within com.google.android.youtube (most janky frames), by ASB state and touch:$' || f "no table for the app with the most janky frames: $out"
printf '%s\n' "$out" | awk '/^within com.google.android.youtube/ { f = 1; next } /^within |^  Compare/ { f = 0 } f' > "$T/yt"
grep -qE '^  MODERATE +no +3 +1800 +21\.7% +2\.71$' "$T/yt" || f "YouTube MODERATE row: $(cat "$T/yt")"
grep -qE '^  LIGHT_IDLE +no +4 +2000 +27\.0% +2\.81$' "$T/yt" || f "YouTube LIGHT_IDLE row: $(cat "$T/yt")"
[ "$(printf '%s\n' "$out" | grep -c '^  Compare states inside one app')" = 1 ] || f "the caveat is printed once: $out"
printf '%s\n' "$out" | grep -q '^  touch = a touch began after 3 s without one; steady typing or scrolling can read no.$' || f "touch column not explained: $out"
# Same app most frames and most janky: one table. 6+2 layout: no cluster line.
mkdir -p "$T/d"; J="$T/d/jank_trace.tsv"; i=0; echo "# h" > "$J"
cp "$T/c2/cluster_layout.txt" "$T/d/"
for k in 1 2 3; do row MODERATE 1 4000 40 com.a "com.a:40:4000"; done
for k in 1 2; do row LIGHT_IDLE 0 300 20 com.a "com.a:20:300"; done
for k in 1 2; do row MODERATE 1 200 5 com.b "com.b:5:200"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/d" 2>&1)"
[ "$(printf '%s\n' "$out" | grep -c '^within ')" = 1 ] || f "two tables for one app: $out"
printf '%s\n' "$out" | grep -q '^main cores below' && f "cluster line on a 6+2 part: $out"

# --- 4. throttle split: slot 0 is the little pair there --------------------------------------
printf '1|active|p0_max=1/2|p6_max=1/2|cpu_temp=40|surface=33|cap_owner=asb|main_by=asb_trim|prime_by=vendor\n' > "$T/thr"
out="$(LK_OUT_DIR="$T/c" sh -c '. "$0" >/dev/null 2>&1; lk_emit_cap_cause_split "$1"' "$C" "$T/thr")"
printf '%s\n' "$out" | grep -qE '^  little: asb_trim 1$' || f "4-cluster split still says main: $out"
printf '%s\n' "$out" | grep -q 'little = policy0, the efficiency cores' || f "little note: $out"
out="$(LK_OUT_DIR="$T/d" sh -c '. "$0" >/dev/null 2>&1; lk_emit_cap_cause_split "$1"' "$C" "$T/thr")"
printf '%s\n' "$out" | grep -qE '^  main: +asb_trim 1$' || f "6+2 split: $out"
grep -q 'the LPM feature or the cellular power policy (radio_policy_enable, off by default) is off' "$ROOT/tools/logkit/asb_log_full_day.sh" \
  || f "an empty modem LPM line still prints nothing"

# --- 5. asbdiag: policy0 of a 6+2 part is "main" ---------------------------------------------
D="$ROOT/tools/asb_diag.sh"
grep -q '_tier="little"; \[ "$_npol" -eq 2 \] && _tier="main"' "$D" || f "asbdiag policy list calls the six main cores little"
grep -q '\[ "$_ncl" -eq 2 \] && _role=main' "$D" || f "asbdiag slot map calls the six main cores little"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS cluster roles: main/prime from the governor's map, named in the report, a table for the jankiest app, asbdiag labels"
exit "$fail"
)

t_debug_support_contract() (
# Contract: debug WebUI support actions stay debug-gated, bounded and non-overlapping.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TIMELINE="$ROOT/runtime/asb_boot_timeline.sh"
DIAG="$ROOT/tools/asb_diag.sh"
INSTALLED_DIAG="$ROOT/system/bin/asbdiag"
UI="$ROOT/webroot/index.html"
TMP="$(mktemp -d)"
trap 'if [ -n "${REC_PID:-}" ]; then kill "$REC_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" || { echo "FAIL debug support: missing [$2]" >&2; exit 1; }; }
count_exact() {
  _actual="$(grep -Foc -- "$2" "$1" 2>/dev/null || true)"
  [ "$_actual" -eq "$3" ] || { echo "FAIL debug support: expected $3 [$2], found $_actual" >&2; exit 1; }
}
[ -f "$HELPER" ] || { echo "FAIL debug support: helper missing" >&2; exit 1; }
[ -f "$TIMELINE" ] || { echo "FAIL debug support: boot timeline helper missing" >&2; exit 1; }
[ -f "$DIAG" ] && [ -f "$INSTALLED_DIAG" ] || { echo "FAIL debug support: asbdiag copy missing" >&2; exit 1; }
sh -n "$HELPER"
sh -n "$TIMELINE"
cmp -s "$DIAG" "$INSTALLED_DIAG" || { echo "FAIL debug support: asbdiag copies diverged" >&2; exit 1; }
need "$DIAG" 'BOOT TIMELINE'
need "$DIAG" 'boot_timeline.tsv'

# Execute the actual asbdiag version gate fragment. A prior shell glob used
# [1-9][0-9]*, which requires two digits and therefore hid timeline evidence on
# V64-debug4 even though the recorder had correctly created it.
awk '
  /^_boot_debug=0$/ { capture=1 }
  capture && /^if \[ "\$_boot_debug" = "1" \]; then$/ { exit }
  capture { print }
' "$DIAG" > "$TMP/asbdiag_boot_gate.sh"
[ -s "$TMP/asbdiag_boot_gate.sh" ] || { echo 'FAIL debug support: cannot extract asbdiag boot gate' >&2; exit 1; }
diag_boot_gate() (
  _boot_version="$1"
  . "$TMP/asbdiag_boot_gate.sh"
  printf '%s' "$_boot_debug"
)
for _gate_case in \
  'V64-debug1:1' \
  'V64-debug4:1' \
  'V64-debug10:1' \
  'V64-debug42:1' \
  'V64-debug999999999:1' \
  'V64:0' \
  'V64-debug:0' \
  'V64-debug0:0' \
  'V64-debug4x:0'; do
  _gate_version="${_gate_case%:*}"; _gate_want="${_gate_case##*:}"
  _gate_live="$(diag_boot_gate "$_gate_version")"
  [ "$_gate_live" = "$_gate_want" ] || {
    echo "FAIL debug support: asbdiag boot gate version=$_gate_version want=$_gate_want live=$_gate_live" >&2; exit 1
  }
done

# A release module must refuse both mutations even if someone manufactures a DOM click.
REL="$TMP/release"; mkdir -p "$REL"
printf 'id=AutoSystemBoost\nversion=V65\n' > "$REL/module.prop"
REL_OUT="$(ASB_DEBUG_SUPPORT_MODDIR="$REL" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" sh "$HELPER" full-day || true)"
printf '%s\n' "$REL_OUT" | grep -Fq 'error=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse recorder' >&2; exit 1
}
REL_TL="$(ASB_BOOT_TIMELINE_MODDIR="$REL" ASB_BOOT_TIMELINE_STATE_DIR="$TMP/timeline-release" sh "$TIMELINE" begin postfs_begin || true)"
printf '%s\n' "$REL_TL" | grep -Fq 'status=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse boot timeline' >&2; exit 1
}
[ ! -e "$TMP/timeline-release/boot_timeline.tsv" ] || { echo 'FAIL debug support: release timeline wrote state' >&2; exit 1; }

# A debug module gets a mocked diagnostic and recorder. The recorder reproduces the real
# ownership protocol: it claims the tokenized directory with ITS OWN PID and only removes
# a guard that still names that PID. This catches launcher-PID and cleanup races on host.
DBG="$TMP/debug"; mkdir -p "$DBG/system/bin" "$DBG/tools/logkit" "$TMP/out"
printf 'id=AutoSystemBoost\nversion=V65-debug10\n' > "$DBG/module.prop"
TL_STATE="$TMP/timeline-debug"
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" begin postfs_begin >/dev/null
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" mark service_enter >/dev/null
grep -Fq $'\tpostfs_begin\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: postfs boot marker missing' >&2; exit 1; }
grep -Fq $'\tservice_enter\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: service boot marker missing' >&2; exit 1; }
printf '#!/bin/sh\n[ "${ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY:-0}" = 1 ] && sleep 1\nif [ "${ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL:-0}" = 1 ]; then echo diagnostic-failed; exit 9; fi\necho diagnostic-ok\n' > "$DBG/system/bin/asbdiag"; chmod 0755 "$DBG/system/bin/asbdiag"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" <<'EOF_RECORDER'
#!/bin/sh
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"
_token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -n "$_lock" ] && [ -d "$_lock" ] || exit 91
[ "$(cat "$_lock/token" 2>/dev/null || true)" = "$_token" ] || exit 92
printf '%s\n' "$$" > "$_lock/pid.tmp.$$" || exit 93
mv -f "$_lock/pid.tmp.$$" "$_lock/pid" || exit 94
_out="$_lock/capture_output"; mkdir -p "$_out" || exit 95
printf '%s\n' "$_out" > "$_lock/output_dir" || exit 96
cleanup() {
  _pid="$(tr -dc '0-9' < "$_lock/pid" 2>/dev/null || true)"
  [ "$_pid" = "$$" ] && rm -rf "$_lock" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT HUP
sleep 30
cleanup
EOF_RECORDER
chmod 0755 "$DBG/tools/logkit/asb_log_full_day.sh"
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/full_day.out" ASB_DEBUG_SUPPORT_DIAG_OUTDIR="$TMP/out")
# Capture the output AND the status separately.
#
# Under `set -e` a non-zero exit from the helper aborts the test at this line, before any
# assertion runs - so the whole regression reported "exit code 8" with no failing check
# named, and the real problem was invisible. The helper legitimately returns non-zero for
# conditions this test is meant to observe, so its status is data here, not an error.
DIAG_OUT="$(env "${ENV[@]}" sh "$HELPER" diag || true)"
echo "$DIAG_OUT" | grep -Fq 'status=saved'
DIAG_PATH="$(printf '%s\n' "$DIAG_OUT" | sed -n 's/^path=//p')"
[ -f "$DIAG_PATH" ] && grep -Fq 'diagnostic-ok' "$DIAG_PATH" || { echo 'FAIL debug support: diag export' >&2; exit 1; }

# WebUI cannot paint while a KSU bridge waits for a synchronous diagnostic export.
# The async action must acknowledge a delayed worker immediately, remain observable via
# fixed status command, and publish a complete saved record after the worker exits.
ASYNC_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$ASYNC_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: async diag did not return started' >&2; exit 1; }
ASYNC_PID="$(printf '%s\n' "$ASYNC_DIAG" | sed -n 's/^pid=//p')"
[ -n "$ASYNC_PID" ] && kill -0 "$ASYNC_PID" 2>/dev/null || { echo 'FAIL debug support: async diag worker missing' >&2; exit 1; }
ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
printf '%s\n' "$ASYNC_STATUS" | grep -Eq '^status=(starting|running)$' || { echo 'FAIL debug support: async diag status not live' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' && break
done
printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' || { echo 'FAIL debug support: async diag never reached saved' >&2; exit 1; }
ASYNC_PATH="$(printf '%s\n' "$ASYNC_STATUS" | sed -n 's/^path=//p')"
[ -f "$ASYNC_PATH" ] && grep -Fq 'diagnostic-ok' "$ASYNC_PATH" || { echo 'FAIL debug support: async diag saved output missing' >&2; exit 1; }

# A dead diagnostic worker must not leave a permanent `already_running` lock, and a nonzero
# asbdiag exit must become an explicit failed status rather than a misleading saved toast.
mkdir -p "$TMP/state/asbdiag_webui.lock"
printf '999999\n' > "$TMP/state/asbdiag_webui.lock/pid"
STALE_DIAG="$(env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$STALE_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: known-dead diag lock not reclaimed' >&2; exit 1; }
for _diag_try in $(seq 1 30); do sleep 0.1; env "${ENV[@]}" sh "$HELPER" diag-status | grep -Fqx 'status=saved' && break; done
FAIL_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$FAIL_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: failing diag did not launch' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  FAIL_DIAG_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' && break
done
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' || { echo 'FAIL debug support: nonzero diag did not reach failed state' >&2; exit 1; }
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'error=asbdiag_exit_9' || { echo 'FAIL debug support: nonzero diag exit was not surfaced' >&2; exit 1; }
START1="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START1" | grep -Fq 'status=started'
REC_PID="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recorder did not stay alive' >&2; exit 1; }
START2="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START2" | grep -Fq 'status=already_running'
echo "$START2" | grep -Fq "pid=$REC_PID"

# Deleting the exact directory published by the live recorder is an explicit cancellation.
# The helper may stop ONLY that recorder, clear its lock and launch a new single capture.
# Simulate a common Android toybox limitation: both ps formats expose only a shortened command
# line. The recovery still needs the script basename, but remains gated by a live lock PID and
# an explicitly removed recorder-owned output directory.
mkdir -p "$TMP/ps-truncated"
cat > "$TMP/ps-truncated/ps" <<'EOF_PS'
#!/bin/sh
printf '%s\n' 'sh asb_log_full_day.sh 24'
EOF_PS
chmod 0755 "$TMP/ps-truncated/ps"
ORPHAN_OUT="$(cat "$TMP/state/full_day_webui.lock/output_dir")"
[ -d "$ORPHAN_OUT" ] || { echo 'FAIL debug support: recorder did not publish output dir' >&2; exit 1; }
rm -rf "$ORPHAN_OUT"
RECOVERED="$(PATH="$TMP/ps-truncated:$PATH" env "${ENV[@]}" sh "$HELPER" full-day || true)"
# fix220: the same storm fix219 proved in the sibling test fired here once in a full
# regression: the helper had cancelled the orphan (cancel=output_removed in the log, the
# recorder gone) but a loaded /proc misread kept the still-live check from clearing the
# lock inside the wait, and the answer was already_running over a corpse. The recovery is
# idempotent, so one retry tells a flake from a regression: the retry reclaims the now
# dead lock and starts; a helper that genuinely lost orphan recovery answers
# already_running to BOTH attempts and still fails below.
case "$RECOVERED" in
  *status=started*) : ;;
  *status=already_running*)
    sleep 0.5
    RECOVERED="$RECOVERED
$(PATH="$TMP/ps-truncated:$PATH" env "${ENV[@]}" sh "$HELPER" full-day || true)" ;;
esac
printf '%s\n' "$RECOVERED" | grep -Fq 'status=started' || {
  echo 'FAIL debug support: removed output dir did not recover capture slot' >&2
  # What the helper answered and why (fix146: a CI run failed here with nothing to read).
  printf '  helper: %s\n' "$RECOVERED" >&2
  sed 's/^/  recovery log: /' "$TMP/state/full_day_webui.recovery.log" >&2 2>/dev/null || true
  _rp="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
  [ -n "$_rp" ] && { printf '  recorder %s: ' "$_rp"; cat "/proc/$_rp/stat" 2>/dev/null || echo gone; } >&2
  exit 1
}
# The evidence of the recovery path is the cancel note itself - the recovered= note can be
# lost when the retry takes the dead-lock reclaim instead (the cancel already proved the
# missing-output path was taken).
grep -Fq 'output_removed' "$TMP/state/full_day_webui.recovery.log" || { echo 'FAIL debug support: orphan recovery evidence missing' >&2; exit 1; }
# With the retry the combined answer can name two PIDs - the cancelled orphan's and the new
# recorder's. The new recorder is the last.
REC_PID="$(printf '%s\n' "$RECOVERED" | sed -n 's/^pid=//p' | tail -n 1)"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recovered recorder missing' >&2; exit 1; }

# Repeat simultaneous starts from a clean state. One and only one recorder may be created in
# every round; the losing request must publish the winner PID rather than relying on a
# short-lived helper process or a removable empty PID file.
for round in $(seq 1 12); do
  kill -KILL "$REC_PID" 2>/dev/null || true
  wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  rm -rf "$TMP/state/full_day_webui.lock"
  rm -f "$TMP/state/full_day_webui.pid"
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_a.out" & C1=$!
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_b.out" & C2=$!
  # wait propagates the child status, and under set -e that aborts the test before the
  # assertion that is meant to inspect it. The helper legitimately returns non-zero for
  # the losing side of this race - that is the behaviour being measured.
  wait "$C1" || true; wait "$C2" || true
  CONCURRENT="$(cat "$TMP/concurrent_${round}_a.out" "$TMP/concurrent_${round}_b.out")"
  [ "$(printf '%s\n' "$CONCURRENT" | grep -c '^status=started$')" -eq 1 ] || { echo "FAIL debug support: concurrent start count round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq 'status=already_running' || { echo "FAIL debug support: concurrent guard did not report running round=$round" >&2; exit 1; }
  REC_PID="$(printf '%s\n' "$CONCURRENT" | sed -n 's/^pid=//p' | grep -E '^[0-9]+$' | head -n 1)"
  [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo "FAIL debug support: concurrent recorder missing round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq "pid=$REC_PID" || { echo "FAIL debug support: loser did not observe winner PID round=$round" >&2; exit 1; }
done

# A killed recorder leaves a known-dead PID. The next action may reclaim only that stale lock.
kill -KILL "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
# The recorder is not this shell's child, so `wait` returns at once; SIGKILL lands
# asynchronously. Give it up to 5 s to be gone or a zombie before asking (fix136 - the
# full regression failed here once in a while on a loaded host, never on a device).
_dk=0
while [ "$_dk" -lt 50 ]; do
  kill -0 "$REC_PID" 2>/dev/null || break
  case "$(cat "/proc/$REC_PID/stat" 2>/dev/null)" in *') Z '*) break ;; esac
  sleep 0.1; _dk=$((_dk + 1))
done
STALE="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$STALE" | grep -Fq 'status=started' || { echo 'FAIL debug support: known-dead lock not reclaimed' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$STALE" | sed -n 's/^pid=//p')"

# The helper accepts a fixed enum only; it has no eval/source/untrusted command interpolation.
need "$HELPER" "case \"\${1:-status}\" in"
need "$HELPER" 'mkdir "$LOCKDIR"'
need "$HELPER" 'lock_known_dead()'
need "$HELPER" 'full_day_output_missing()'
need "$HELPER" 'full_day_cancel_orphan()'
need "$HELPER" 'full_day_pid_matches_recorder()'
need "$HELPER" 'asb_log_full_day.sh*) return 0'
need "$HELPER" 'full_day_recovery_note()'
need "$HELPER" 'RECOVERY_LOG='
need "$HELPER" 'PROC_ROOT='
need "$HELPER" 'diag_lock_known_dead()'
need "$HELPER" 'asbdiag_exit_${_rc}'
need "$HELPER" 'lock_wait_live_pid()'
need "$HELPER" 'ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR"'
need "$HELPER" 'diag-start) diag_start'
need "$HELPER" 'diag-status) diag_status'
need "$HELPER" 'full-day-start) start_full_day 1'
need "$HELPER" 'DIAG_LOCKDIR="$STATE_DIR/asbdiag_webui.lock"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_LOCKDIR="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim || { echo '\''[debug-webui] guard claim failed'\''; exit 2; }'
need "$ROOT/tools/logkit/asb_log_full_day.sh" "trap 'lk_finalize; lk_webui_guard_release; exit 0' TERM INT HUP"
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_release'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_publish_output()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_OUTPUTFILE'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'FULL-DAY capture complete. Output: $LK_OUT_DIR'
# Debug capture must expose a resolvable AudioMix owner and the evidence that made
# a media-like workload game-like, without putting any package-manager polling in
# the native governor. The logkit helpers are passive and use one capture-start map.
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
need "$COMMON" 'lk_audio_wakelock_attribution_init()'
need "$COMMON" 'audio_wakelock_attribution.tsv'
need "$COMMON" 'lk_fsm_media_trace_header()'
need "$COMMON" 'fsm_media_trace.tsv'
# Android 16 emits a chained WorkSource for AudioMix. Test both that real form and
# the compact legacy form; raw UID attribution is useless if the recorder prints '-'.
sed -n '/^lk_audio_wakelock_live_row() {/,/^}/p' "$COMMON" > "$TMP/audio_wakelock_fn.sh"
[ -s "$TMP/audio_wakelock_fn.sh" ] || { echo 'FAIL debug support: cannot extract AudioMix attribution helper' >&2; exit 1; }
lk_audio_wakelock_package_for_uid() { printf 'pkg.uid.%s\n' "$1"; }
LK_OUT_DIR="$TMP/audio_attr"; mkdir -p "$LK_OUT_DIR"
. "$TMP/audio_wakelock_fn.sh"
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}})" 123
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' WorkSource{10652}" 124
grep -Fq '123|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained AudioMix row absent' >&2; exit 1; }
grep -Fq '|10658|pkg.uid.10658|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained WorkSource UID unresolved' >&2; exit 1; }
grep -Fq '|10652|pkg.uid.10652|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: compact WorkSource UID unresolved' >&2; exit 1; }
# fix179: a job lock held beside AudioMix is not AudioMix (capture 30423: ru.vk.store, 95 rows).
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK '*job*r/@androidx.work.systemjobscheduler@ru.vk.store/x' ACQ=-1s (uid=1000 ws=WorkSource{ chains=WorkChain{(10436), (1000, JobScheduler)}});PARTIAL_WAKE_LOCK 'AudioMix' ACQ=-5s (uid=1041 ws=WorkSource{10345});" 125
grep -Fq '125|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: AudioMix beside a job lock not recorded' >&2; exit 1; }
grep -Fq '|10436|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" && { echo 'FAIL debug support: a job lock held beside AudioMix was credited to AudioMix' >&2; exit 1; }
grep -F '125|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" | grep -q 'ru.vk.store' && { echo 'FAIL debug support: the job lock text was kept as AudioMix evidence' >&2; exit 1; }
grep -Fq '125|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" && grep -F '125|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" | grep -Fq '|10345|pkg.uid.10345|' || { echo 'FAIL debug support: the AudioMix owner beside a job lock was lost' >&2; exit 1; }
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_audio_wakelock_attribution_init'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_capture_fsm_media_trace_row "$_phase"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'rmnetMiB'
need "$ROOT/src/asb_governor.c" 'asb_smart_media_guard_observe'
need "$ROOT/src/asb_governor.c" 'no_fresh_known_media_pkg'
need "$ROOT/src/asb_governor.c" 'ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT = 70'
need "$ROOT/src/asb_smart.h" 'asb_smart_pkg_is_media_candidate'
if grep -nE '\beval\b|\bsource\b|/system/bin/sh -c|sh -c' "$HELPER" >/dev/null; then
  echo 'FAIL debug support: helper accepts unsafe shell execution' >&2; exit 1
fi
# Every one of Profile, Monitor and Settings gets one support wrapper. A debug build
# swaps its single release Telegram link for exactly one no-wrap, three-control rail.
count_exact "$UI" '<div class="footer-support-row" data-debug-support-row hidden>' 3
count_exact "$UI" '<a class="tg-link" data-release-telegram' 3
count_exact "$UI" '<a class="tg-link" data-debug-telegram' 3
count_exact "$UI" "asbDebugAction('diag')" 3
count_exact "$UI" "asbDebugAction('full-day')" 3
count_exact "$UI" '<span class="tg-link-ico" data-tech-icon="telegram"></span>' 6
need "$UI" '.tg-link-ico .tech-icon { width: 18px; height: 18px; }'
need "$UI" '.footer-support-row .tg-link-ico { width: 16px; height: 16px; flex-basis: 16px; }'
need "$UI" 'background: linear-gradient(135deg, rgba(0,240,180,0.08), rgba(0,212,255,0.05));'
need "$UI" 'height: 40px;'
need "$UI" 'flex-wrap: nowrap;'
need "$UI" '[data-release-telegram][hidden] { display: none !important; }'
need "$UI" 'runtime/asb_debug_support.sh'
need "$UI" 'loadDebugSupport()'
need "$UI" '/-debug[1-9][0-9]*$/i'
# asbdiag can spend seconds writing its export. A persistent modal must open before
# the root bridge await, stay while the pulse is active, and close only in finally.
need "$UI" 'id="debugActionWait"'
need "$UI" 'debug-action-wait-sheet'
need "$UI" 'background:#000;'
need "$UI" 'stockRestoreToastOpen();'
need "$UI" 'stockRestoreToastClose();'
need "$UI" 'toast.stock-restoring'
need "$UI" 'stockRestoreToastPulse'
need "$UI" 'debugDiagPulse .38s'
need "$UI" 'debugActionWaitOpen(action);'
need "$UI" 'debugActionWaitClose();'
need "$UI" 'await debugFrame();'
need "$UI" "'diag-start' : 'full-day-start'"
need "$UI" 'runtime/asb_debug_support.sh diag-status'
need "$UI" 'async function debugDiagPoll()'
need "$UI" 'async function debugFullDayPoll()'
need "$UI" 'runtime/asb_debug_support.sh status'
awk '
  /async function asbDebugAction\(action\)/ { in_fn=1 }
  in_fn && /debugActionWaitOpen\(action\)/ { opened=NR }
  in_fn && /await run\(/ && !awaited { awaited=NR }
  in_fn && /finally \{/ { in_final=1 }
  in_final && /debugActionWaitClose\(\)/ { closed=1 }
  in_fn && /^}/ { if (opened && awaited && opened < awaited && closed) ok=1; in_fn=0 }
  END { if (!ok) { print "FAIL debug support: wait modal lifecycle is not open-before-await / close-in-finally" > "/dev/stderr"; exit 1 } }
' "$UI"
awk '
  /<div class="footer-support-row" data-debug-support-row hidden>/ { inrow=1; seq=""; next }
  inrow && /asbDebugAction\('\''diag'\''\)/ { seq=seq "D" }
  inrow && /data-debug-telegram/ { seq=seq "T" }
  inrow && /asbDebugAction\('\''full-day'\''\)/ { seq=seq "L" }
  inrow && /<\/div>/ { if (seq != "DTL") { printf "FAIL debug support: expected DTL rail order, got %s\\n", seq > "/dev/stderr"; exit 1 }; rails++; inrow=0 }
  END { if (rails != 3) { printf "FAIL debug support: checked %d central rails\\n", rails > "/dev/stderr"; exit 1 } }
' "$UI"
for locale in "$ROOT"/webroot/i18n/*.json; do
  # Check the VALUE, not the byte sequence.
  #
  # These matched '"key": "value"' with the space that json.dump's indent mode happens to
  # emit. Compacting the locale files to save 43 KB changed no data at all and broke both
  # lines, because a grep for punctuation is not a test of content.
  #
  # Matching the key and value with optional whitespace between them holds for either
  # formatting, and still fails if the string is actually missing or renamed - which is
  # what the contract is about.
  grep -Eq '"dbg_diag_btn"[[:space:]]*:[[:space:]]*"asbdiag"' "$locale" \
    || fail "missing dbg_diag_btn=asbdiag in $locale"
  grep -Eq '"dbg_log_btn"[[:space:]]*:[[:space:]]*"24h log"' "$locale" \
    || fail "missing dbg_log_btn=24h log in $locale"
  need "$locale" '"dbg_log_failed"'
done

echo 'PASS debug support WebUI/helper contract'
)

t_debug_support_stale_lock() (
# Regression: the WebUI must be able to start a daily log again after a previous one ended or
# its folder was deleted. Three cases:
#   1. stale lock whose PID now belongs to an UNRELATED live process (PID reuse within a boot)
#      -> the lock is not ours: start must succeed, the unrelated process must be left alive;
#   2. our recorder alive, folder present -> still "already running" (no second recorder);
#   3. our recorder alive, folder deleted -> recorder AND its sampler child stopped, new start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL debug stale-lock: $*" >&2; exit 1; }
# Alive and not a zombie: a killed process stays visible to kill -0 until it is reaped.
alive() { [ -r "/proc/$1/stat" ] || return 1; case "$(sed 's/^.*) //' "/proc/$1/stat" | cut -c1)" in Z|X) return 1 ;; esac; return 0; }
DBG="$TMP/mod"; mkdir -p "$DBG/tools/logkit" "$DBG/runtime"
printf 'id=AutoSystemBoost\nversion=V65-debug10\nversionCode=650\n' > "$DBG/module.prop"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" << 'EOF_REC'
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"; _token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -d "$_lock" ] && [ "$(cat "$_lock/token")" = "$_token" ] || exit 91
printf '%s\n' "$$" > "$_lock/pid"
_out="$_lock/../capture_$$"; mkdir -p "$_out"; printf '%s\n' "$_out" > "$_lock/output_dir"
( while :; do sleep 1; done ) &          # a sampler child, as the real recorder has
echo $! > "$_lock/../child_$$"
sleep 60
EOF_REC
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/run.out")
H() { env "${ENV[@]}" sh "$HELPER" "$@" 2>/dev/null || true; }
LOCK="$TMP/state/full_day_webui.lock"
boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo boot)"

# ---- case 1: stale lock, PID reused by an unrelated live process
mkdir -p "$LOCK"; sleep 300 & OTHER=$!
printf '%s\n' "$boot" > "$LOCK/boot_id"; printf 'tok\n' > "$LOCK/token"
printf '%s\n' "$OTHER" > "$LOCK/pid"; printf '%s\n' "$OTHER" > "$LOCK/launcher"
printf '%s\n' "$TMP/deleted_capture" > "$LOCK/output_dir"
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=started' || fail "case 1: stale lock blocked the start: $OUT"
kill -0 "$OTHER" 2>/dev/null || fail "case 1: an unrelated process was killed"
sleep 0.6
P1="$(tr -dc 0-9 < "$LOCK/pid" 2>/dev/null)"; [ -n "$P1" ] && kill -0 "$P1" || fail "case 1: recorder not running"

# ---- case 2: our recorder alive, folder present -> already running
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=already_running' || fail "case 2: a second recorder was allowed: $OUT"

# ---- case 3: folder deleted -> recorder and child stopped, new recorder started
CHILD="$(cat "$TMP/state/child_$P1" 2>/dev/null)"
CAPDIR="$(cat "$LOCK/output_dir")"
[ -n "$CAPDIR" ] || fail "case 3: the published output_dir read empty under load"
rm -rf "$CAPDIR"
[ ! -d "$CAPDIR" ] || fail "case 3: could not remove the capture dir"
OUT="$(H full-day-start)"
# A host under the full suite's fork pressure can transiently read a tiny lock file as
# empty (a failed fork inside a command substitution), which the helper - correctly -
# fails closed on: "cannot prove the output is gone, so the live recorder stays". On a
# device that answer is right; here it is the storm, not the logic. The recovery is
# idempotent, so one retry tells a flake from a regression: a helper that genuinely lost
# orphan recovery answers already_running to BOTH attempts and still fails below.
case "$OUT" in
  *orphan_recovered=output_dir_removed*) : ;;
  *status=already_running*)
    sleep 0.5
    OUT="$OUT
$(H full-day-start)" ;;
esac
if ! printf '%s\n' "$OUT" | grep -q 'orphan_recovered=output_dir_removed'; then
  # The first attempt may have recovered the slot but tripped on the final still-live
  # check; the retry then started over the dead lock without the note line. The contract
  # is "a new start succeeds and the old recorder is gone" - checked either way below.
  printf '%s\n' "$OUT" | grep -q 'status=started' || fail "case 3: orphan not recovered: $OUT"
fi
printf '%s\n' "$OUT" | grep -q 'status=started' || fail "case 3: no new start: $OUT"
sleep 0.4
alive "$P1" && fail "case 3: old recorder still alive"
[ -n "$CHILD" ] && alive "$CHILD" && fail "case 3: old sampler child still alive"
kill "$OTHER" 2>/dev/null
echo "PASS debug support stale-lock and deleted-folder recovery"
)

t_jank_app_state_runtime() (
# Runtime (fix140): the smoothness report compares ASB states inside the app with the most
# frames, touched and untouched apart.
#
# Capture 2830 read "LIGHT_IDLE 34.8% janky, MODERATE 4.1%" - and YouTube playing untouched
# made up most of LIGHT_IDLE. Inside YouTube untouched: 43.8% in LIGHT_IDLE, 42.3% in mixed.
# The per-state table on its own pointed at the state. The REAL report function runs here.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
fail() { echo "FAIL jank app/state: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
J="$T/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg" > "$J"
row() { printf '%s|t|audio_bt_scr|%s|48|0|0|%s|%s|%s|%s|50|5|1|0|%s\n' "$1" "$2" "$3" "$4" "$5" "$5" "$6" >> "$J"; }
row 1 LIGHT_IDLE 0 600 264 com.google.android.youtube
row 2 LIGHT_IDLE 0 600 262 com.google.android.youtube
row 3 mixed      0 600 254 com.google.android.youtube
row 4 MODERATE   3 1300 110 com.google.android.youtube
row 5 MODERATE   2 900 40 com.rifsxd.ksunext
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T" 2>&1)"
printf '%s\n' "$out" | grep -q '^within com.google.android.youtube (most frames), by ASB state and touch:$' || fail "no per-app table: $out"
printf '%s\n' "$out" | grep -qE '^  MODERATE +yes +1 +1300 +8\.5% +2\.29$' || fail "touched MODERATE row: $out"
printf '%s\n' "$out" | grep -qE '^  LIGHT_IDLE +no +2 +1200 +43\.8% +5\.48$' || fail "untouched LIGHT_IDLE row: $out"
printf '%s\n' "$out" | grep -qE '^  mixed +no +1 +600 +42\.3% +5\.29$' || fail "untouched mixed row: $out"
printf '%s\n' "$out" | grep -q 'ksunext .*yes' && fail "another app's rows in the table: $out"
# MODERATE before LIGHT_IDLE before mixed - a fixed order, not awk's hash order.
printf '%s\n' "$out" | awk '/^  MODERATE/ { m = NR } /^  LIGHT_IDLE/ { l = NR } /^  mixed/ { x = NR } END { exit !(m < l && l < x) }' \
  || fail "rows out of order: $out"
# One group only: nothing to compare, no table.
grep -v '|mixed|\||MODERATE|' "$J" > "$T/j2"; mkdir -p "$T/o2"; mv "$T/j2" "$T/o2/jank_trace.tsv"
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/o2" 2>&1)"
printf '%s\n' "$out" | grep -q '^within ' && fail "table printed for a single group: $out"
echo "PASS jank app/state: states compared inside the top app, touched and untouched apart"
)

t_jank_floor_runtime() (
# Runtime (fix143): a steady source of janky frames is told apart from lag.
#
# Capture 26147: about 1.5 janky frames a second in every ASB state and at every frame rate,
# so LIGHT_IDLE - few frames drawn - read "42.0% janky" at 1.44 janky/s while MODERATE read
# 3.0% at 1.64/s. The report now prints janky/s, the frame-rate bands and the floor, records
# which app drew the janky frames (jank_trace column 17), and asbdiag measures the same per
# app while it runs. The REAL functions run here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL jank floor: $*" >&2; fail=1; }

# --- 1. report: a floor of 1.5 janky/s from SystemUI, under quiet and busy intervals ---------
mkdir -p "$T/a"
J="$T/a/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg|jank_pkgs" > "$J"
i=0
row() {   # state frames janky pkgs
  i=$((i + 1))
  printf '%s|t|active|%s|48|0|0|0|%s|%s|%s|50|5|1|0|com.instagram.android|%s\n' "$i" "$1" "$2" "$3" "$3" "$4" >> "$J"
}
for k in 1 2 3 4 5 6; do row LIGHT_IDLE 120 72 "com.android.systemui:70:72,com.instagram.android:2:48"; done
for k in 1 2 3 4 5 6 7 8; do row MODERATE 4000 76 "com.android.systemui:71:73,com.instagram.android:5:3900"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out" | grep -qE '^LIGHT_IDLE +6 +720 +60\.0% +1\.50$' || f "state row without janky/s: $out"
printf '%s\n' "$out" | grep -qE '^MODERATE +8 +32000 +1\.9% +1\.58$' || f "MODERATE row: $out"
printf '%s\n' "$out" | grep -qE '^  under 5 +6 +1\.50 +60\.0%$' || f "quiet band: $out"
printf '%s\n' "$out" | grep -qE '^  60 and over +8 +1\.58 +1\.9%$' || f "busy band: $out"
printf '%s\n' "$out" | grep -q '^steady floor: 1.50 janky frames a second while almost nothing was drawn' || f "no floor verdict: $out"
printf '%s\n' "$out" | grep -q '^  high share, ordinary rate: LIGHT_IDLE 60.0% janky at 1.50/s$' || f "LIGHT_IDLE not named as share-only: $out"
printf '%s\n' "$out" | grep -q 'high share, ordinary rate:.*MODERATE' && f "MODERATE named as share-only: $out"
printf '%s\n' "$out" | grep -qE '^  com\.android\.systemui +988 +1016 +1\.47   14 of 14$' || f "per-app source row: $out"
printf '%s\n' "$out" | grep -q '^the floor: com.android.systemui drew 97.2% of the janky frames in the quiet intervals.$' || f "floor source not named: $out"
printf '%s\n' "$out" | grep -q '^com.android.systemui missed deadlines in 14 of 14 screen-on intervals, whatever app was in front' || f "steady redraw line missing: $out"
printf '%s\n' "$out" | grep -q '^(the app in front is credited with every app' || f "front-app caveat missing: $out"
printf '%s\n' "$out" | grep -qE 'main cores at the ASB ceiling \(end of interval\): yes - of 0 frames \(-/s\), no 3\.2% of 32720 frames \(1\.55/s\)' || f "ceiling line without janky/s: $out"

# --- 2. no floor: janky frames only where much is drawn ---------------------------------------
mkdir -p "$T/b"; J="$T/b/jank_trace.tsv"; i=0
echo "# header" > "$J"
for k in 1 2 3 4 5 6; do row LIGHT_IDLE 120 1 "-"; done
for k in 1 2 3 4 5 6 7 8; do row MODERATE 4000 150 "-"; done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/b" 2>&1)"
printf '%s\n' "$out" | grep -q 'steady floor' && f "floor claimed where the quiet intervals are clean: $out"
printf '%s\n' "$out" | grep -q 'janky frames by the app that drew them' && f "per-app table printed with no column 17: $out"
printf '%s\n' "$out" | grep -q '^  under 5 ' || f "bands missing: $out"

# --- 3. recorder: column 17 from two dumps ------------------------------------------------------
gfx() {   # $1 file; then pairs "pkg frames janky"
  _o="$1"; shift; : > "$_o"
  while [ "$#" -ge 3 ]; do
    printf 'Package: %s\nStats since: 1000ns\nTotal frames rendered: %s\nJanky frames: %s (1.00%%)\nNumber Frame deadline missed: %s\nNumber Slow UI thread: 0\nNumber High input latency: 0\n' "$1" "$2" "$3" "$3" >> "$_o"
    shift 3
  done
}
gfx "$T/g1" com.android.systemui 1000 100 com.instagram.android 5000 10 com.old.app 900 90
gfx "$T/g2" com.android.systemui 1050 148 com.instagram.android 9000 14 com.old.app 900 90 com.new.app 30 6
gfx "$T/g3" com.android.systemui 1100 196 com.instagram.android 9000 14 com.old.app 100 1
mkdir -p "$T/c" "$T/cpufreq/policy0"
echo 100 > "$T/cpufreq/policy0/scaling_max_freq"; echo 50 > "$T/cpufreq/policy0/scaling_cur_freq"
printf 'state=MODERATE\ntouch_starts=1\n' > "$T/st"
rec="$(LK_OUT_DIR="$T/c" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_STATE_FILE="$T/st" sh -c '
  . "$0" >/dev/null 2>&1
  lk_jank_trace_header
  ASB_LK_GFXSTATS_DUMP="$1/g1" lk_capture_jank_row active 1
  ASB_LK_GFXSTATS_DUMP="$1/g2" lk_capture_jank_row active 1
  ASB_LK_GFXSTATS_DUMP="$1/g3" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  ls -a "$LK_OUT_DIR"
' "$C" "$T" 2>&1)"
r1="$(printf '%s\n' "$rec" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r1" | cut -d'|' -f17)" = "com.android.systemui:48:50,com.new.app:6:30,com.instagram.android:4:4000" ] \
  || f "column 17 wrong (worst first, a package new today counted from zero): $r1"
# g3: old.app went backwards (pruned) - the whole row is skipped like before, no column to check.
[ "$(printf '%s\n' "$rec" | grep -c '|active|')" = 1 ] || f "a pruned day must still skip the row: $rec"
printf '%s\n' "$rec" | grep -q '^\.jank_pkg_prev$' || f "per-package baseline not kept: $rec"
printf '%s\n' "$rec" | grep -q '^\.jank_pkg_now$' && f "per-package scratch file left behind: $rec"
# Screen off drops the baseline with the totals.
LK_OUT_DIR="$T/c" sh -c '. "$0" >/dev/null 2>&1; lk_capture_jank_row idle 0' "$C"
[ -e "$T/c/.jank_pkg_prev" ] && f "per-package baseline survived a screen-off"

# --- 4. asbdiag: per app while the report runs -------------------------------------------------
sed -n '/^# asb_gfx_pkg_begin$/,/^# asb_gfx_pkg_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gp.sh"
[ -s "$T/gp.sh" ] || f "asbdiag has no asb_gfx_pkg block"
a="$(sh -c '. "$1"; asb_gfx_pkg < "$2"' x "$T/gp.sh" "$T/g1" | sort)"
[ "$a" = "$(printf 'com.android.systemui 1000 100\ncom.instagram.android 5000 10\ncom.old.app 900 90')" ] || f "asb_gfx_pkg: $a"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$3")" 40' x "$T/gp.sh" "$T/g1" "$T/g2")"
printf '%s\n' "$d" | grep -q '^while this report ran (40 s), janky frames by app: com.android.systemui 48 of 50 frames (1.20/s)  ·  com.new.app 6 of 30 frames (0.15/s)  ·  com.instagram.android 4 of 4000 frames (0.10/s)$' \
  || f "asbdiag per-app line: $d"
printf '%s\n' "$d" | grep -q '^steady: com.android.systemui missed 48 of the 50 frames it drew - about 1.2 a second' || f "asbdiag steady line: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$3")" 3' x "$T/gp.sh" "$T/g1" "$T/g2")"
[ -z "$d" ] || f "asbdiag printed a 3-second window: $d"
d="$(sh -c '. "$1"; asb_gfx_run_delta "$(asb_gfx_pkg < "$2")" "$(asb_gfx_pkg < "$2")" 40' x "$T/gp.sh" "$T/g1")"
[ -z "$d" ] || f "asbdiag printed a window with nothing drawn (screen off): $d"
grep -q '_gfx_run0="$(dumpsys graphicsstats 2>/dev/null | asb_gfx_pkg)"' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not read the counters at its start"
grep -q 'asb_gfx_run_delta "$_gfx_run0" "$_gfx_run1"' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not compare them in 7c"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS jank floor: janky/s and frame-rate bands, the floor and who draws it, asbdiag per app while it runs"
exit "$fail"
)

t_jank_trace_runtime() (
# Runtime (fix121): the full-day capture measures UI smoothness - HWUI frame deltas from
# dumpsys graphicsstats between screen-on polls, tagged with the ASB state and whether the
# clusters sat at ASB's ceiling - and the report puts janky% next to each.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL jank trace: $*" >&2; fail=1; }
mkdir -p "$T/out" "$T/cpufreq/policy0" "$T/cpufreq/policy6"

# Two packages; the second also has a block from an older day (counted in the totals too).
gfx() {   # $1 file  $2 sysui frames  $3 sysui janky  $4 app frames  $5 app janky  $6 app deadline
  cat > "$1" <<EOF

Package: com.android.systemui
Version: 36
Stats since: 1000ns
Stats end: 2000ns
Total frames rendered: $2
Janky frames: $3 (1.00%)
Janky frames (legacy): 999 (9.99%)
50th percentile: 5ms
Number Missed Vsync: 0
Number High input latency: 1
Number Slow UI thread: 2
Number Slow bitmap uploads: 0
Number Slow issue draw commands: 0
Number Frame deadline missed: $3
HISTOGRAM: 5ms=10 6ms=2
Package: com.google.android.youtube
Version: 1
Stats since: 1000ns
Stats end: 2000ns
Total frames rendered: $4
Janky frames: $5 (2.00%)
Janky frames (legacy): 888 (9.99%)
Number Missed Vsync: 0
Number High input latency: 0
Number Slow UI thread: 3
Number Slow bitmap uploads: 0
Number Slow issue draw commands: 0
Number Frame deadline missed: $6
Package: com.google.android.youtube
Version: 1
Stats since: 500ns
Stats end: 900ns
Total frames rendered: 7000
Janky frames: 70 (1.00%)
Number Frame deadline missed: 70
Number Slow UI thread: 5
Number High input latency: 1
EOF
}
gfx "$T/g1" 1000 10 5000 50 60
gfx "$T/g2" 1600 16 6400 150 180     # +600/+6 and +1400/+100 -> 2000 frames, 106 janky
gfx "$T/g3" 1700 17 6500 151 181     # +100/+1 and +100/+1 -> 200 frames, 2 janky
gfx "$T/g4"  100  1 6500 151 181     # sysui went backwards: pruned day, no row

printf 'state=MODERATE\ntouch_starts=10\n' > "$T/state1"
printf 'state=MODERATE\ntouch_starts=14\n' > "$T/state2"
printf 'state=LIGHT_IDLE\ntouch_starts=14\n' > "$T/state3"
echo 1555200 > "$T/cpufreq/policy0/scaling_max_freq"; echo 1555200 > "$T/cpufreq/policy0/scaling_cur_freq"
echo 1862400 > "$T/cpufreq/policy6/scaling_max_freq"; echo  768000 > "$T/cpufreq/policy6/scaling_cur_freq"

out="$(LK_OUT_DIR="$T/out" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row audio_bt_scr 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g4" lk_capture_jank_row audio_bt_scr 1
  # Screen off keeps the last screen-on baseline (fix150); this wake went backwards against
  # it (a pruned day), so the first screen-on poll after it writes no row.
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g4" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  echo "--- trace"; cat "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"

rows="$(printf '%s\n' "$out" | sed -n '/^--- trace/,/^--- report/p' | grep -v '^#' | grep -c '|')"
[ "$rows" = 2 ] || f "expected 2 interval rows (pruned day and screen-off must not write one), got $rows: $out"
r1="$(printf '%s\n' "$out" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r1" | cut -d'|' -f4)" = MODERATE ] || f "same state at both ends must be named: $r1"
[ "$(printf '%s' "$r1" | cut -d'|' -f6-13)" = "1|0|4|2000|106|126|0|0" ] || f "deltas or tags wrong: $r1"
r2="$(printf '%s\n' "$out" | grep '|audio_bt_scr|' | head -1)"
[ "$(printf '%s' "$r2" | cut -d'|' -f4)" = mixed ] || f "a state change inside the interval must read mixed: $r2"
[ "$(printf '%s' "$r2" | cut -d'|' -f9-10)" = "200|2" ] || f "second interval deltas wrong: $r2"
printf '%s\n' "$out" | grep -q 'all screen-on intervals: 2  frames 2200  janky 4.9%' || f "overall janky share wrong: $out"
printf '%s\n' "$out" | grep -qE '^MODERATE +1 +2000 +5.3%' || f "per-state line wrong: $out"
printf '%s\n' "$out" | grep -q 'main cores at the ASB ceiling (end of interval): yes 4.9% of 2200 frames' || f "ceiling correlation missing: $out"

# fix150: the wake itself. The last screen-on baseline survives the screen-off stretch and the
# first screen-on poll after it writes one row marked "wake" (column 18); the report keeps
# those rows apart - their seconds are mostly screen-off.
mkdir -p "$T/outw"
outw="$(LK_OUT_DIR="$T/outw" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state3" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row idle 0
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row post_wake 1
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g3" lk_capture_jank_row post_wake 1
  echo "--- trace"; grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"
rw="$(printf '%s\n' "$outw" | grep '|wake$')"
[ "$(printf '%s\n' "$rw" | grep -c .)" = 1 ] || f "expected one wake row: $outw"
[ "$(printf '%s' "$rw" | cut -d'|' -f3-4)" = "post_wake|MODERATE" ] || f "wake row phase/state: $rw"
[ "$(printf '%s' "$rw" | cut -d'|' -f6-10)" = "-|-|0|200|2" ] || f "wake row deltas (against the last screen-on poll): $rw"
case "$(printf '%s' "$rw" | cut -d'|' -f17)" in
  "com.android.systemui:1:100,com.google.android.youtube:1:100"|"com.google.android.youtube:1:100,com.android.systemui:1:100") : ;;
  *) f "wake row apps: $rw" ;;
esac
[ "$(printf '%s\n' "$outw" | sed -n '/^--- trace/,/^--- report/p' | grep -c '|')" = 3 ] || f "wake must not replace the ordinary rows: $outw"
printf '%s\n' "$outw" | grep -q 'all screen-on intervals: 2  frames 2000  janky 5.3%' || f "a wake row leaked into the ordinary figures: $outw"
printf '%s\n' "$outw" | grep -q 'the wake itself: 1 wake(s), last screen-on poll before each to the first after it - frames 200, janky 1.0% (ordinary screen-on intervals: 5.3%)' \
  || f "wake summary missing: $outw"
printf '%s\n' "$outw" | grep -q '  at the wakes, by app: com.android.systemui 1 of 100 janky (1.0%), com.google.android.youtube 1 of 100 janky (1.0%)' \
  || printf '%s\n' "$outw" | grep -q '  at the wakes, by app: com.google.android.youtube 1 of 100 janky (1.0%), com.android.systemui 1 of 100 janky (1.0%)' \
  || f "wake apps missing: $outw"

# fix125: time at the ceiling from time_in_state, and the app in front from the top-app cgroup.
mkdir -p "$T/cpufreq/policy0/stats" "$T/cpufreq/policy6/stats" "$T/proc/2001" "$T/proc/1000" "$T/out2"
printf '384000 1000\n1555200 500\n' > "$T/cpufreq/policy0/stats/time_in_state"
printf '768000 900\n1862400 100\n' > "$T/cpufreq/policy6/stats/time_in_state"
printf 'Name:\tx\nUid:\t10234\t10234\t10234\t10234\n' > "$T/proc/2001/status"; echo 0 > "$T/proc/2001/oom_score_adj"
printf 'com.instagram.android\0' > "$T/proc/2001/cmdline"
printf 'Name:\tx\nUid:\t1000\t1000\t1000\t1000\n' > "$T/proc/1000/status"; echo -900 > "$T/proc/1000/oom_score_adj"
printf 'system_server\0' > "$T/proc/1000/cmdline"
printf '1000\n2001\n' > "$T/topapp"
out2="$(LK_OUT_DIR="$T/out2" ASB_LK_CPUFREQ_ROOT="$T/cpufreq" ASB_LK_TOPAPP_PROCS="$T/topapp" ASB_LK_PROC_ROOT="$T/proc" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  lk_jank_trace_header
  ASB_LK_STATE_FILE="$T/state1" ASB_LK_GFXSTATS_DUMP="$T/g1" lk_capture_jank_row active 1
  # 4 s more at 1555200 (the ceiling), 1 s at 384000 on the main cores; prime idle.
  printf "384000 1100\n1555200 900\n" > "$T/cpufreq/policy0/stats/time_in_state"
  printf "768000 1400\n1862400 100\n" > "$T/cpufreq/policy6/stats/time_in_state"
  ASB_LK_STATE_FILE="$T/state2" ASB_LK_GFXSTATS_DUMP="$T/g2" lk_capture_jank_row active 1
  grep -v "^#" "$LK_OUT_DIR/jank_trace.tsv"
  echo "--- report"; lk_emit_jank_summary
' "$C" "$T" 2>&1)"
r3="$(printf '%s\n' "$out2" | grep '|active|' | head -1)"
[ "$(printf '%s' "$r3" | cut -d'|' -f14-16)" = "80|0|com.instagram.android" ] || f "time-at-ceiling or app columns wrong: $r3"
printf '%s\n' "$out2" | grep -q 'main cores, share of the interval AT the ceiling ->  >=60%: 5.3% of 2000' || f "time-at-ceiling split missing: $out2"
printf '%s\n' "$out2" | grep -qE '^com.instagram.android +2000 +5.3%' || f "per-app line missing: $out2"
printf '%s\n' "$out2" | grep -q 'high-input-latency events:' || f "input latency not shown as a count"
printf '%s\n' "$out2" | grep -q 'high input latency [0-9.]*%' && f "input latency still shown as a share of frames"

# asbdiag: today's blocks only (the newest "Stats since"), totals and the most janky apps.
sed -n '/^# asb_gfx_today_begin$/,/^# asb_gfx_today_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gfx_today.sh"
[ -s "$T/gfx_today.sh" ] || f "asbdiag has no asb_gfx_today block"
# Field shape (fix125): each process's block starts when it first drew - different starts on
# the same UTC day must all count; yesterday's block must not.
cat > "$T/gd" <<'EOF'
Package: com.old.app
Stats since: 1791590400000000000ns
Total frames rendered: 90000
Janky frames: 9000 (10.00%)
Number Slow UI thread: 10
Number High input latency: 0
Package: com.android.systemui
Stats since: 1791712801000000000ns
Total frames rendered: 8000
Janky frames: 80 (1.00%)
Number Slow UI thread: 40
Number High input latency: 8
Package: com.instagram.android
Stats since: 1791716455000000000ns
Total frames rendered: 2000
Janky frames: 120 (6.00%)
Number Slow UI thread: 60
Number High input latency: 2
Package: com.tiny.app
Stats since: 1791714000000000000ns
Total frames rendered: 100
Janky frames: 50 (50.00%)
Number Slow UI thread: 0
Number High input latency: 0
EOF
gd="$(sh -c '. "$1"; asb_gfx_today < "$2"' x "$T/gfx_today.sh" "$T/gd" 2>&1)"
printf '%s\n' "$gd" | grep -q '^frames 10100  ·  janky 2.5%  ·  slow UI thread 1.0%  ·  high-input-latency events 10$' || f "asbdiag totals wrong (older day must be left out, latency is a count): $gd"
printf '%s\n' "$gd" | grep -q '^most janky frames: com.instagram.android 120 (6.0% of 2000)  ·  com.android.systemui 80 (1.0% of 8000)$' || f "asbdiag ranking wrong (under 300 frames must be left out): $gd"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

# The full-day recorder calls it and prints the section.
grep -q '^lk_jank_trace_header$' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "trace header not created by the full-day capture"
grep -q 'lk_capture_jank_row "$_phase" "${_dscr:-0}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "rows not captured per poll"
grep -q '^    lk_emit_jank_summary$' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "report does not print the section"

[ "$fail" = 0 ] && echo "PASS jank trace: frame deltas per screen-on interval, state and ceiling tags, report"
exit "$fail"
)

t_logkit_bstats_no_reset_runtime() (
# Runtime: the capture no longer resets batterystats by default, and the per-app wakelock
# section shows the capture's own window as a difference against the start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit batterystats: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/out"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$2" = "--reset" ] && { echo reset >> "$RESETS"; exit 0; }
cat "$BS"
S
chmod +x "$T/bin/dumpsys"
cat > "$T/bs1" <<'B'
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 10s 1ms (4 times) realtime
B
cat > "$T/bs2" <<'B'
  Wake lock u0a493 PedometerLib:tag: 9m 4s 955ms (9 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 12s 1ms (5 times) realtime
  Wake lock u0a800 NewOne: 1m 0s 1ms (1 times) realtime
B
printf '10493|com.sec.android.app.shealth\n10800|com.example.new\n' > "$T/out/.uid_package_map.tsv"
out="$(PATH="$T/bin:$PATH" RESETS="$T/resets" LK_OUT_DIR="$T/out" BS="$T/bs1" sh -c '
  . "$0" >/dev/null 2>&1
  lk_have() { command -v "$1" >/dev/null 2>&1 || type "$1" >/dev/null 2>&1; }
  lk_dumpsys() { dumpsys "$@"; }
  LK_WAKELOCK_NAME=asb_logkit_self
  lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_emit_report "'"$T"'/bs2"
  sed -n "/TOP APPS/,/^$/p" "$LK_OUT_DIR/_wakelock_report.txt"
' "$C" 2>&1)"
[ -f "$T/resets" ] && f "batterystats was reset without ASB_LK_BSTATS_RESET=1"
printf '%s\n' "$out" | grep -q 'during this capture' || f "section not labelled as the capture window: $out"
printf '%s\n' "$out" | grep -q '5m 00s  com.sec.android.app.shealth' || f "pedometer delta should be 5m 00s: $out"
printf '%s\n' "$out" | grep -q '1m 00s  com.example.new' || f "new holder missing: $out"
printf '%s\n' "$out" | grep -q 'uid 10700' && f "2 s delta must stay under the 5 s floor"
[ "$fail" = 0 ] && echo "PASS logkit batterystats no-reset runtime"
exit "$fail"
)

t_logkit_bstats_stall_runtime() (
# Runtime (fix140): a capture says so when batterystats did not update, instead of "no app
# held a partial wakelock".
#
# Capture 2830 (OP15, 9.5 h): "TOP APPS BY HELD WAKELOCK TIME ... (no app held a partial
# wakelock for 5 s or more in this window)" while the live power-manager samples saw
# YouTube's AudioMix held for 20 minutes at a stretch. Every uid's batterystats total was the
# one recorded at the start (AudioMix 1m 52s at 22:45 and at 08:03), the kernel wakelock
# totals too: Android's accounting did not move. The REAL report functions run on fixtures
# with a fake dumpsys.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
fail() { echo "FAIL logkit batterystats stall: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
O="$T/out"; B="$T/bin"; mkdir -p "$O" "$B"
cat > "$B/dumpsys" <<'S'
#!/bin/sh
[ "$1" = batterystats ] || exit 0
cat "$BS_FILE"
S
chmod +x "$B/dumpsys"
cat > "$T/bs_frozen.txt" <<'X'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 24s 17ms (4 times) max=79609 actual=339376 realtime
  Wake lock u0a658 AudioMix: 1m 52s 686ms (0 times) max=139335 actual=148655 realtime

X
printf '10493 264 PedometerLib:tag\n10658 112 AudioMix\n' > "$O/.wl_uid_base"
echo $(( $(date +%s) - 3 * 3600 - 60 )) > "$O/.bstats_base_epoch"
echo "epoch|datetime|status" > "$O/charge_trace.txt"
printf '10658|com.google.android.youtube\n10493|com.sec.android.app.shealth\n' > "$O/.uid_package_map.tsv"
# On battery: 52 % -> 35 % over the night (the OP15's status node reads "Unknown" throughout).
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|52|1124\n2|d|DEEP_IDLE|smart|0|35|83\n' > "$O/battery_trace.txt"

run_dump() {
  BS_FILE="$1" PATH="$B:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_wakelock_batterystats_dump' "$C" "$O" >/dev/null 2>&1
}

# The screen was off for most of it (fix142: batterystats charges partial wakelocks only with
# the screen off, so the stall claim needs real screen-off time). Rows 30 min apart at night.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|sleep|0|0|4094|0||-60||" >> "$O/display_trace.txt"; done
cp "$O/display_trace.txt" "$T/dt.night"

# 0. Screen on the whole time and nothing moved: batterystats had nothing to charge - no claim.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 2600 4400 6200 8000; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed for a capture with the screen on throughout"
cp "$T/dt.night" "$O/display_trace.txt"

# 1. Nothing moved in 3 h, no charging: the stall is named, "no app" is not printed.
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved in 3 h of capture" "$O/_wakelock_report.txt" || fail "stall not named: $(sed -n '/TOP APPS/,/^$/p' "$O/_wakelock_report.txt")"
grep -q 'no app held a partial wakelock' "$O/_wakelock_report.txt" && fail "still says no app held one"
grep -qx '10658 0' "$O/.wl_uid_delta" || fail "per-uid deltas not kept for the report"

# 2. The live samples saw AudioMix (YouTube's worksource) held 20 min at a stretch.
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
# Screen off since 800: the 20-minute hold sampled at 2020 lies entirely in the dark.
for e in 800 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
cat > "$O/wake_live.txt" <<'X'
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-5m1s2ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-20m3s9ms LONG (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}});
2040|kactive=0|ktop=|plocks=
X
printf '10658 com.google.android.youtube\n' > "$O/uid_map.txt"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q '^batterystats disagrees with these samples:$' || fail "no disagreement line: $live"
printf '%s\n' "$live" | grep -q 'com.google.android.youtube (AudioMix): held 20 min at a stretch with the screen off here, batterystats added 0 s' \
  || fail "holder not compared: $live"

# 2b. fix142: the same 20-minute hold, but the screen went off 20 s before the sample - the
# hold ran with the screen on, which batterystats does not charge. No disagreement.
cp "$O/display_trace.txt" "$T/dt.keep"
echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
for e in 800 1950; do echo "$e|d|active|1|900|4094|22|120|-400||2" >> "$O/display_trace.txt"; done
for e in 2000 2020 2040; do echo "$e|d|audio_bt|0|0|4094|0||-120||" >> "$O/display_trace.txt"; done
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "a hold that ran with the screen on compared against batterystats: $live"
cp "$T/dt.keep" "$O/display_trace.txt"

# 3. On the charger batterystats counts nothing by design: no stall claim, no disagreement.
echo "1|d|Charging" >> "$O/charge_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed during a charging capture"
grep -q 'no app held a partial wakelock for 5 s' "$O/_wakelock_report.txt" || fail "charging capture lost the plain line"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement printed while charging: $live"
echo "epoch|datetime|status" > "$O/charge_trace.txt"

# 3b. No charge row but the level held (a phone kept at a charge limit): no claim either.
cp "$O/battery_trace.txt" "$T/bt.keep"
printf 'epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA\n1|d|MODERATE|smart|1|80|-5\n2|d|DEEP_IDLE|smart|0|80|3\n' > "$O/battery_trace.txt"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with the level held"
cp "$T/bt.keep" "$O/battery_trace.txt"

# 4. Accounting that moves: the ranking as before, and no disagreement once it covers the hold.
sed 's/AudioMix: 1m 52s 686ms/AudioMix: 26m 2s 1ms/' "$T/bs_frozen.txt" > "$T/bs_live.txt"
run_dump "$T/bs_live.txt"
grep -q 'com.google.android.youtube' "$O/_wakelock_report.txt" || fail "moving totals not ranked"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed with moving totals"
live="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$live" | grep -q 'batterystats disagrees' && fail "disagreement with totals that cover the hold: $live"

# 5. A short capture with nothing moved is just a quiet window.
echo $(( $(date +%s) - 1800 )) > "$O/.bstats_base_epoch"
run_dump "$T/bs_frozen.txt"
grep -q "not one app's total moved" "$O/_wakelock_report.txt" && fail "stall claimed after 30 minutes"
echo "PASS logkit batterystats stall: a stalled batterystats is named and checked against the live samples"
)

t_logkit_capture_quality_contract() (
# Contract: full-day telemetry improvements must remain observer-only and phase-stable.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOGKIT="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" >/dev/null || { echo "FAIL logkit capture-quality: missing [$2]" >&2; exit 1; }; }

[ -f "$LOGKIT" ] || { echo "FAIL logkit capture-quality: missing full-day logkit" >&2; exit 1; }
sh -n "$LOGKIT"

# Extract the standalone debounce function: this avoids sourcing a device-only recorder.
sed -n '/^lk_stabilize_charging_phase() {/,/^}/p' "$LOGKIT" > "$TMP/debounce.sh"
[ -s "$TMP/debounce.sh" ] || { echo "FAIL logkit capture-quality: cannot extract debounce helper" >&2; exit 1; }
. "$TMP/debounce.sh"

LK_CHG_PHASE_STABLE=""
LK_CHG_IDLE_CANDIDATE_SINCE=0
LK_CHG_IDLE_DEBOUNCE_S=45
LK_CHG_IDLE_COALESCED=0
# Charging-idle telemetry is intentionally less frequent than visible charging/gaming so an
# opt-in diagnostic capture does not itself keep a plugged, screen-off device busy.
need "$LOGKIT" 'LK_POLL_CHARGING_IDLE=60'
need "$LOGKIT" 'charging_idle)          echo "$LK_POLL_CHARGING_IDLE" ;'
sed -n '/^lk_poll_for_phase() {/,/^}/p' "$LOGKIT" > "$TMP/cadence.sh"
[ -s "$TMP/cadence.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract cadence helper' >&2; exit 1; }
LK_POLL_FAST=15 LK_POLL_NORMAL=45 LK_POLL_SLOW=90 LK_POLL_CHARGING_IDLE=60
. "$TMP/cadence.sh"
[ "$(lk_poll_for_phase charging_idle)" = 60 ] || { echo 'FAIL logkit capture-quality: charging-idle cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase charging_active)" = 15 ] || { echo 'FAIL logkit capture-quality: visible charging cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase gaming)" = 15 ] || { echo 'FAIL logkit capture-quality: gaming cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase sleep)" = 90 ] || { echo 'FAIL logkit capture-quality: sleep cadence' >&2; exit 1; }
lk_stabilize_charging_phase charging_active 100
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: first active sample" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 115
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: short idle must stay active" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 145
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: debounce must remain bounded" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 160
[ "$LK_CHG_PHASE_OUT" = charging_idle ] || { echo "FAIL logkit capture-quality: sustained idle must commit" >&2; exit 1; }
lk_stabilize_charging_phase charging_active 161
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: visible screen use must be immediate" >&2; exit 1; }
[ "$LK_CHG_IDLE_COALESCED" -ge 2 ] || { echo "FAIL logkit capture-quality: coalesced counter" >&2; exit 1; }

need "$LOGKIT" 'LK_SCREENOFF_LONGEST_S=0'
need "$LOGKIT" '----- CAPTURE VALIDITY -----'
need "$LOGKIT" 'night verdict: unavailable'
need "$LOGKIT" '----- CAP OWNERSHIP VERDICT -----'
need "$LOGKIT" 'Native vendor holddown/detente'
need "$LOGKIT" 'throttle samples logged: $_tc (poll observations, not independent clamp incidents)'
need "$LOGKIT" 'continuous clamp periods (new period after >180s gap or owner change):'
need "$LOGKIT" 'owner=%-8s duration=%4d min samples=%d'
need "$LOGKIT" "_tc=\$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}'"
if grep -Fq '%s..%s\\\\n", own' "$LOGKIT"; then
  echo 'FAIL logkit capture-quality: grouping would print literal \\n' >&2
  exit 1
fi
cat > "$TMP/throttle_trace.txt" <<'EOF_TRACE'
# throttle trace — epoch | phase | p0 | p6 | temps | cap_owner
100|active|p0_max=1/2|p6_max=1/2|cpu_temp=45|surface=40|cap_owner=vendor
160|active|p0_max=1/2|p6_max=1/2|cpu_temp=46|surface=41|cap_owner=vendor
400|idle|p0_max=1/2|p6_max=1/2|cpu_temp=44|surface=39|cap_owner=asb
EOF_TRACE
_count="$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}' "$TMP/throttle_trace.txt")"
[ "$_count" = 3 ] || { echo "FAIL logkit capture-quality: expected 3 data rows, got $_count" >&2; exit 1; }
_grouped="$(awk -F'|' '
  function emit(){ if(n>0) printf "owner=%s samples=%d epoch=%s..%s\n", own, n, start, last }
  NR==1 {next}; NF<6 {next}
  { split($0,a,"cap_owner="); own_now=a[2]; sub(/\|.*/,"",own_now); now=$1+0
    if(n==0){start=now;last=now;own=own_now;n=1;next}
    if((now-last)>180 || own_now!=own){emit();start=now;own=own_now;n=1}else n++
    last=now }
  END{emit()}
' "$TMP/throttle_trace.txt")"
printf '%s\n' "$_grouped" | grep -Fqx 'owner=vendor samples=2 epoch=100..160' || { echo 'FAIL logkit capture-quality: vendor period grouping' >&2; exit 1; }
printf '%s\n' "$_grouped" | grep -Fqx 'owner=asb samples=1 epoch=400..400' || { echo 'FAIL logkit capture-quality: ASB period grouping' >&2; exit 1; }
case "$_grouped" in *'\\n'*) echo 'FAIL logkit capture-quality: literal \\n in fixture output' >&2; exit 1 ;; esac
need "$LOGKIT" '----- CHARGING-IDLE AWAKE VERDICT -----'
need "$LOGKIT" 'ASB does not alter charge current or kill apps automatically.'
need "$LOGKIT" 'lk_charge_idle_observe "$_phase"'
# The source-class report is a passive observed-context diagnostic. It must never claim a
# causal battery percentage by class, and may only cover adjacent same-class samples.
need "$LOGKIT" '===== SCREEN-OFF CLASS OBSERVATIONS ====='
need "$LOGKIT" 'screenoff_class_trace.tsv'
need "$LOGKIT" 'lk_capture_screenoff_class_row "$_phase"'
need "$LOGKIT" 'intervals <=180s'
need "$LOGKIT" 'not a percentage or causal energy allocation'
sed -n '/^lk_emit_screenoff_class_summary() {/,/^}/p' "$LOGKIT" > "$TMP/screenoff_summary.sh"
[ -s "$TMP/screenoff_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract screen-off summary' >&2; exit 1; }
cat > "$TMP/screenoff_class_trace.tsv" <<'EOF_CLASS'
# epoch|phase|class|awake_pct|window_min|bat_mA|reason
100|sleep|quiet|2|55|80|low awake / no media or network
160|sleep|quiet|4|56|100|low awake / no media or network
230|idle|network|28|58|240|active mobile transfer
700|idle|network|31|60|280|active mobile transfer
EOF_CLASS
LK_OUT_DIR="$TMP"
. "$TMP/screenoff_summary.sh"
_class_summary="$(lk_emit_screenoff_class_summary)"
printf '%s\n' "$_class_summary" | grep -Eq '^quiet[[:space:]]+2[[:space:]]+1\.0' || { echo 'FAIL logkit capture-quality: quiet observed coverage' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Eq '^network[[:space:]]+2[[:space:]]+0\.0' || { echo 'FAIL logkit capture-quality: gap must not be attributed to network class' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Fq 'not a percentage or causal energy allocation' || { echo 'FAIL logkit capture-quality: causal allocation disclaimer missing' >&2; exit 1; }

# Current and capacity-percent rates are complementary measurements, not source attribution.
# A synthetic ledger verifies both the aligned path and the explicit >30% quality warning.
need "$LOGKIT" '===== CURRENT / SOC CONSISTENCY (MEASUREMENT QUALITY) ====='
need "$LOGKIT" 'A CHECK result is a measurement-consistency warning, not causal energy attribution.'
sed -n '/^lk_emit_current_soc_consistency() {/,/^}/p' "$LOGKIT" > "$TMP/current_soc_summary.sh"
[ -s "$TMP/current_soc_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract current/SOC helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
sleep	0	3600	90	88	40	35	1000000	0	0	0	2	100	0	0
idle	3600	7200	88	86	42	36	1000000	0	0	0	5	400	0	0
EOF_LEDGER
LK_OUT_DIR="$TMP" LK_BATTERY_CAPACITY_MAH=5000
. "$TMP/current_soc_summary.sh"
_consistency="$(lk_emit_current_soc_consistency)"
printf '%s\n' "$_consistency" | grep -Eq '^sleep[[:space:]]+60\.0[[:space:]]+2\.00[[:space:]]+2\.00[[:space:]]+0\.0%[[:space:]]+aligned$' || { echo 'FAIL logkit capture-quality: aligned current/SOC verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Eq '^idle[[:space:]]+60\.0[[:space:]]+2\.00[[:space:]]+8\.00[[:space:]]+75\.0%[[:space:]]+CHECK high \(>30%\)$' || { echo 'FAIL logkit capture-quality: current/SOC check verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Fq 'not causal energy attribution' || { echo 'FAIL logkit capture-quality: current/SOC causal disclaimer missing' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -q "governor's gauge check" && { echo 'FAIL logkit capture-quality: gauge line without a governor state' >&2; exit 1; }
# fix179: the governor's own gauge factor is named (a CPH2747 read x0.35 over 61 windows).
lk_state_kv() { case "$1" in current_scale_x100) echo 35 ;; current_scale_windows) echo 61 ;; esac; }
_consistency="$(lk_emit_current_soc_consistency)"
printf '%s\n' "$_consistency" | grep -Fq "governor's gauge check: on screen-on windows current_now integrates to x0.35 of the SOC-derived drain (61 windows) - multiply screen-on mA by about 2.8" || { echo "FAIL logkit capture-quality: governor gauge factor: $_consistency" >&2; exit 1; }
lk_state_kv() { case "$1" in current_scale_x100) echo 135 ;; current_scale_windows) echo 61 ;; esac; }
lk_emit_current_soc_consistency | grep -Fq 'integrates to x1.35 of' || { echo 'FAIL logkit capture-quality: gauge factor above 1' >&2; exit 1; }
lk_state_kv() { case "$1" in current_scale_x100) echo 92 ;; current_scale_windows) echo 61 ;; esac; }
lk_emit_current_soc_consistency | grep -q "governor's gauge check" && { echo 'FAIL logkit capture-quality: an accurate gauge was flagged' >&2; exit 1; }
unset -f lk_state_kv

# Per-phase distribution must use raw battery samples mapped to each concrete ledger interval,
# not a median of phase averages. The outlier makes this distinction visible: mean=250 but
# median=100 for the two disjoint active intervals. The endpoint rule must not double-count
# the transition sample at epoch 200, while epoch 400 belongs once to the final interval.
need "$LOGKIT" '===== SAMPLED CURRENT DISTRIBUTION ====='
need "$LOGKIT" 'raw positive discharge samples'
need "$LOGKIT" 'not physical whole-phase averages'
need "$LOGKIT" 'Suspend and intervals between recorder wake-ups are under-sampled'
sed -n '/^lk_emit_sampled_current_distribution() {/,/^}/p' "$LOGKIT" > "$TMP/sampled_current_distribution.sh"
[ -s "$TMP/sampled_current_distribution.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract sampled-current helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_SAMPLE_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	0	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	0	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	0	0
EOF_SAMPLE_LEDGER
cat > "$TMP/battery_trace.txt" <<'EOF_SAMPLE_TRACE'
epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA
100|x|x|x|1|90|100000
150|x|x|x|1|90|100000
199|x|x|x|1|90|1000000
200|x|x|x|0|90|900000
250|x|x|x|0|90|-100000
300|x|x|x|1|90|100000
350|x|x|x|1|90|100000
400|x|x|x|1|90|100000
EOF_SAMPLE_TRACE
LK_OUT_DIR="$TMP"
. "$TMP/sampled_current_distribution.sh"
_sampled_current="$(lk_emit_sampled_current_distribution "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_sampled_current" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+6[[:space:]]+250\.0[[:space:]]+100\.0$' || { echo 'FAIL logkit capture-quality: mapped active raw-sample mean/median' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Eq '^idle[[:space:]]+1\.7[[:space:]]+1[[:space:]]+900\.0[[:space:]]+900\.0$' || { echo 'FAIL logkit capture-quality: endpoint belongs to next interval once' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Fq 'not causal attribution' || { echo 'FAIL logkit capture-quality: sampled-current disclaimer missing' >&2; exit 1; }

# Mobile traffic is a qualified phase context only. Aggregate two active blocks across the
# 32 MiB report-only threshold and keep a 31 MiB idle block out of the listing.
need "$LOGKIT" '===== MOBILE TRAFFIC CONTEXT ====='
need "$LOGKIT" 'LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32'
need "$LOGKIT" 'does not prove cause or assign battery percentage'
sed -n '/^lk_emit_mobile_traffic_context() {/,/^}/p' "$LOGKIT" > "$TMP/mobile_traffic_context.sh"
[ -s "$TMP/mobile_traffic_context.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract mobile-traffic helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_TRAFFIC_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	20971520	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	32505856	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	13631488	0
EOF_TRAFFIC_LEDGER
LK_OUT_DIR="$TMP" LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32
. "$TMP/mobile_traffic_context.sh"
_traffic_context="$(lk_emit_mobile_traffic_context "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_traffic_context" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+33\.0[[:space:]]+screen-on$' || { echo 'FAIL logkit capture-quality: aggregated traffic context' >&2; exit 1; }
if printf '%s\n' "$_traffic_context" | grep -Eq '^idle[[:space:]]'; then
  echo 'FAIL logkit capture-quality: below-threshold mobile traffic was listed' >&2
  exit 1
fi
printf '%s\n' "$_traffic_context" | grep -Fq 'does not prove cause or assign battery percentage' || { echo 'FAIL logkit capture-quality: mobile-traffic disclaimer missing' >&2; exit 1; }

# New verdict code must remain read-only: no global runtime-policy writes are allowed here.
if grep -nE 'setprop|settings[[:space:]]+put|sysctl[[:space:]]+-w|swapoff|svc[[:space:]]+power|reboot' "$LOGKIT" >/dev/null 2>&1; then
  echo "FAIL logkit capture-quality: full-day telemetry gained a policy write" >&2
  exit 1
fi

echo 'PASS logkit capture-quality telemetry contract'
)

t_logkit_cluster_wakelock_runtime() (
# Runtime (fix130): the full-day report says which cluster carried the screen-on work and
# who held a wakelock while the phone charged.
#
# An OP15 capture on V65-debug5: the prime above a quarter of its top clock in 90% of the
# screen-on samples, the main cores in 32%, and the split followed the ceilings. The same
# capture's "anomaly: charging idle stayed awake" pointed at a batterystats ranking that was
# empty - batterystats counts nothing on the charger - while the live power-manager samples
# showed a proxy app holding a partial wakelock in every one of them. The REAL report
# functions run on fixtures and a fake two-cluster sysfs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
fail() { echo "FAIL logkit cluster/wakelock: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$T/sys"; O="$T/out"
mkdir -p "$F/cpufreq/policy0" "$F/cpufreq/policy6" "$F/cpu0" "$F/cpu6" "$O"
echo 762 > "$F/cpu0/cpu_capacity"; echo 1024 > "$F/cpu6/cpu_capacity"
echo 3628800 > "$F/cpufreq/policy0/cpuinfo_max_freq"; echo 4608000 > "$F/cpufreq/policy6/cpuinfo_max_freq"
echo "6 7" > "$F/cpufreq/policy6/related_cpus"

echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
echo "epoch|x|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max" > "$O/perf_trace.txt"
i=0
while [ $i -lt 14 ]; do
  e=$((1000 + i * 20))
  echo "$e|d|active|1|1000|4094|25|120|300||" >> "$O/display_trace.txt"
  # 8 samples main 1555200 / prime 1862400 with the prime working; 4 level (1996800) with it idle;
  # 2 within 10% (1900800 = capacity 399 of the prime's 414, fix132) with it idle.
  # fix156: discharge current in column 22, surface temperature in column 36; the first five
  # below-the-prime samples and two level ones are warm.
  sf=33; [ $i -lt 5 ] && sf=41; [ $i -eq 8 ] || [ $i -eq 9 ] && sf=42
  if [ $i -lt 8 ]; then row="883200|1555200|1862400|1862400"; ma=480
  elif [ $i -lt 12 ]; then row="1996800|1996800|768000|1862400"; ma=320
  else row="1900800|1900800|768000|1862400"; ma=400; fi
  echo "$e|d|||||||||||$row||||||$ma||||||||||||||$sf" >> "$O/perf_trace.txt"
  i=$((i + 1))
done
for e in 2000 2020 2040 2060; do
  echo "$e|d|charging_idle|0|0|4094|0||-120||" >> "$O/display_trace.txt"
done
cat > "$O/wake_live.txt" <<'X'
1000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'ScreenOnOnly' ACQ=-50m0s1ms LONG (uid=10999 pid=1);
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-9m7s229ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 '*sync*/com.android.contacts/com.whatsapp' ACQ=-47s696ms (uid=1000 pid=4813 ws=WorkSource{10384});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-23m57s318ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-3s916ms (uid=1041 ws=WorkSource{ chains=WorkChain{(10382), (1041)}});
2040|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-1h2m4s5ms LONG (uid=10383 pid=16659);
2060|kactive=0|ktop=|plocks=
X
printf '10383 com.amurcanov.tgwsproxy\n10384 com.whatsapp\n1000 com.oplus.atlas\n10382 org.telegram.messenger\n' > "$O/uid_map.txt"

out="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$out" | grep -q '^screen-on samples 14: prime cores working in 57%, main cores in 42%$' || fail "cluster split: $out"
printf '%s\n' "$out" | grep -qE 'level with the prime .*: +4 samples, prime working in 0%' || fail "level bucket: $out"
printf '%s\n' "$out" | grep -qE "more than 10% below the prime's: +8 samples, prime working in 100%" || fail "below bucket: $out"
printf '%s\n' "$out" | grep -qE "within 10% of the prime's: +2 samples, prime working in 0%, mean 400 mA$" || fail "near bucket: $out"
printf '%s\n' "$out" | grep -qE "more than 10% below the prime's: +8 samples, prime working in 100%, mean 480 mA$" || fail "below bucket current: $out"
printf '%s\n' "$out" | grep -q '^  warm (surface 40 C and above), 7 samples:$' || fail "warm split: $out"
printf '%s\n' "$out" | grep -qE '^    main level with the prime: +2 samples, prime working in 0%, mean 320 mA$' || fail "warm level row: $out"
printf '%s\n' "$out" | grep -qE '^    main more than 10% below it: +5 samples, prime working in 100%, mean 480 mA$' || fail "warm below row: $out"
printf '%s\n' "$out" | grep -q 'main within 10% of the prime.s:   ' && fail "a warm row printed with no warm samples: $out"
printf '%s\n' "$out" | grep -q '^screen-off samples: 4$' || fail "screen-off samples: $out"
printf '%s\n' "$out" | grep -qE '^  held in  75% of samples, longest hold   62 min  TgWsProxy::ServiceWakeLock  \(com.amurcanov.tgwsproxy\)$' || fail "proxy not ranked first with its longest hold: $out"
printf '%s\n' "$out" | grep -q 'com.android.contacts/com.whatsapp  (com.whatsapp)' || fail "compact WorkSource uid not resolved: $out"
printf '%s\n' "$out" | grep -q 'ScreenOnOnly' && fail "a screen-on sample counted: $out"
# Not shown on a three-cluster phone.
mkdir -p "$F/cpufreq/policy2"
out2="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary' "$C" "$O" 2>&1)"
[ -z "$out2" ] || fail "cluster summary printed on a 3-cluster layout: $out2"
grep -q '^    lk_emit_cluster_work_summary$' "$FD" || fail "report does not include the cluster summary"
grep -q '^  lk_emit_live_wakelock_holders$' "$FD" || fail "report does not include the live wakelock holders"
grep -q 'LIVE WAKELOCK HOLDERS below names who held the CPU' "$FD" || fail "charging verdict still points at the empty ranking"
echo "PASS logkit cluster/wakelock: screen-on work by cluster, wakelock holders while charging"
)

t_logkit_detach_sysui_sco_runtime() (
# Runtime + contract: fix67 field reports.
#  1. A capture started from the manager app escapes the app's cgroup (frozen/killed with
#     the app on KernelSU: a "24 h" capture held ten minutes of samples).
#  2. bt_sco is classified as the call link - in the logkit (was route=none) and in the DSP
#     route publishers (was "bt", so a Bluetooth boost processed a VoIP call).
#  3. A SystemUI restart during a capture is recorded with the crash/ANR evidence.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit detach/sysui/sco: $*" >&2; fail=1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"

run_fn() {   # source the common file in a subshell and run one function
  ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; "$@" )
}

# --- 1. cgroup escape -------------------------------------------------------------------
printf '0::/uid_10853/pid_4242\n' > "$T/cg"
true > "$T/root1"; true > "$T/root2"
out="$(ASB_LK_CG_FILE="$T/cg" ASB_LK_CG_ROOTS="$T/root1 $T/root2 $T/absent" run_fn lk_escape_app_cgroup 777)"
[ "$(cat "$T/root1")" = 777 ] && [ "$(cat "$T/root2")" = 777 ] || f "pid not written to the root groups"
# The fake cgroup file still says uid_ (nothing moved it for real) -> must report failed,
# never claim success it cannot see.
[ "$out" = failed ] || f "escape claimed '$out' while the process is still in uid_"
printf '0::/\n' > "$T/cg2"
out="$(ASB_LK_CG_FILE="$T/cg2" ASB_LK_CG_ROOTS="$T/root1" run_fn lk_escape_app_cgroup 778)"
[ "$out" = not_needed ] || f "a process outside any app group should not be moved ($out)"
grep -Fq 'LK_CGROUP_ESCAPE="$(lk_escape_app_cgroup $$)"' "$C" || f "lk_init does not escape the app cgroup"
grep -q '_recorder_cgroup.txt' "$C" || f "capture does not record its cgroup"

# --- 2. bt_sco classification ---------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
cat <<'D'
Audio mode:
- mode (internal) = MODE_IN_COMMUNICATION
- mode (external) = MODE_IN_COMMUNICATION
mode owner: pid: 5555 uid: 10499
  AudioPlaybackConfiguration piid:1 deviceIds:[3] type:android.media.AudioTrack u/pid:10499/5555 state:started attr:x
- STREAM_MUSIC:
   Muted: false
   Devices: bt_sco
- STREAM_ALARM:
   Devices: speaker
D
X
chmod +x "$T/bin/dumpsys"
res="$(PATH="$T/bin:$PATH" run_fn sh -c 'true' ; ( set +u; PATH="$T/bin:$PATH"; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; lk_dumpsys() { dumpsys "$@"; }; lk_sample_audio; echo "$LK_AUDIO_ROUTE|$LK_AUDIO_MODE|$LK_AUDIO_MODE_OWNER" ))"
# fix178: the owner is the value after "mode owner:" (the snapshot already labels it).
case "$res" in
  "bt_sco|MODE_IN_COMMUNICATION|pid: 5555 uid: 10499"*) : ;;
  *) f "bt_sco/mode not classified: '$res'" ;;
esac
# Android 16 prints "- Actual mode = ..." and the owner on the line after "- Mode owner:" -
# capture 30423 recorded an empty owner in every snapshot.
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
cat <<'D'
Audio mode:
- Requested mode = MODE_IN_CALL
- Actual mode = MODE_IN_CALL
- Mode owner:
   SetModeDeathHandler: pid: 4437 uid: 1000 mode: MODE_IN_CALL
- STREAM_MUSIC:
   Devices: bt_sco
D
X
res="$( ( set +u; PATH="$T/bin:$PATH"; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; lk_dumpsys() { dumpsys "$@"; }; lk_sample_audio; echo "$LK_AUDIO_MODE|$LK_AUDIO_MODE_OWNER" ))"
case "$res" in
  *MODE_IN_CALL*"|SetModeDeathHandler: pid: 4437 uid: 1000 mode: MODE_IN_CALL") : ;;
  *) f "Android 16 mode/owner not read: '$res'" ;;
esac
grep -q 'bt|bt_le|bt_sco) _apn="audio_bt"' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "bt_sco not mapped to a Bluetooth audio phase"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' "$ROOT/service.sh" || f "live DSP route watcher still calls SCO bt"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _asb_route="call"' "$ROOT/runtime/asb_audio_apply.sh" || f "audio apply still calls SCO bt"
grep -q 'call:\*) _dsp_ra=0' "$ROOT/runtime/asb_audio_apply.sh" || f "call route not excluded from processing"

# --- 3. SystemUI restart recorder -------------------------------------------------------
cat > "$T/bin/pidof" <<'X'
#!/bin/sh
cat "$SYSUI_PIDF"
X
cat > "$T/bin/logcat" <<'X'
#!/bin/sh
echo "10-08 19:54:30 E AndroidRuntime: FATAL EXCEPTION: main Process: com.android.systemui"
X
chmod +x "$T/bin/"*
mkdir -p "$T/out"
echo 1000 > "$T/pid"
( set +u; PATH="$T/bin:$PATH"; SYSUI_PIDF="$T/pid"; export SYSUI_PIDF
  LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1
  lk_dumpsys() { echo "dropbox $*"; }
  LK_OUT_DIR="$T/out"
  lk_sysui_watch_row; lk_sysui_watch_row
  echo 2000 > "$T/pid"; lk_sysui_watch_row; lk_sysui_watch_row
  echo "$LK_SYSUI_RESTARTS" > "$T/count" )
[ "$(cat "$T/count")" = 1 ] || f "restart count $(cat "$T/count") (want 1)"
grep -q 'SYSTEMUI RESTART .* pid 1000 -> 2000' "$T/out/sysui_restarts.txt" || f "restart not recorded"
grep -q 'FATAL EXCEPTION' "$T/out/sysui_restarts.txt" || f "crash evidence not captured"
grep -q 'dropbox --print system_app_anr' "$T/out/sysui_restarts.txt" || f "ANR dropbox not captured"
grep -q 'lk_sysui_watch_row' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "full-day capture does not watch SystemUI"
grep -q 'SYSTEMUI RESTARTS' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "report has no SystemUI section"

[ "$fail" = 0 ] && echo "PASS logkit detach/sysui/sco runtime"
exit "$fail"
)

t_logkit_stale_temp_runtime() (
# Runtime (fix141): the per-phase cpuT/surfT do not carry a governor reading hours old.
#
# Capture 2830: the governor's deep-idle economy skips the thermal zones, its status kept
# temp 43 / surface 37 from 01:03 to 08:02, and the sleep row read "cpuT 41 surfT 36" while
# the capture's own zone reads sat at 26-35 C.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL logkit stale temp: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tz/thermal_zone26" "$T/tz/thermal_zone15" "$T/tz/thermal_zone79" "$T/tz/thermal_zone84"
echo 29400 > "$T/tz/thermal_zone26/temp"; echo 31200 > "$T/tz/thermal_zone15/temp"
echo 27100 > "$T/tz/thermal_zone79/temp"; echo 28000 > "$T/tz/thermal_zone84/temp"
r="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
       LK_THERMAL_BASE="$T/tz" TZ_CPU_PRIME=26 TZ_CPU_PERF=15 TZ_SYSTHERM6=79 TZ_BOARD=84 lk_direct_temps) )"
[ "$r" = "31|28" ] || fail "direct reads: $r"
r="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
       LK_THERMAL_BASE="$T/tz" TZ_CPU_PRIME= TZ_CPU_PERF= TZ_SYSTHERM6=79 TZ_BOARD= lk_direct_temps) )"
[ "$r" = "|27" ] || fail "missing CPU zones must leave the field empty, not shift the surface into it: $r"
F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '"temp_read_epoch":' "$F" || fail "phase accumulation ignores the reading's age"
grep -q "IFS='|' read -r _temp _surf" "$F" || fail "stale reading not replaced by the zones"
grep -q 'temp_read_epoch' "$ROOT/src/asb_governor.c" || fail "governor no longer publishes the read time"
echo "PASS logkit stale temp: a governor reading over two minutes old is replaced by the capture's own zone reads"
)

t_logkit_stock_battery_row_runtime() (
# Runtime (fix177): a Stock capture has a profile, a screen state and temperatures.
#
# Owner's 77-minute Stock capture (stock_755): no governor, so its status was empty, and the
# battery trace carried no profile, no screen and no temperature - the report said "screen on
# for 0% of the capture (0 min on, 76 min off)" and cpuT 0 / surfT - for every phase. The REAL
# row function runs with an empty status and a fake thermal tree.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL logkit stock battery row: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tz/thermal_zone26" "$T/tz/thermal_zone79" "$T/mod" "$T/out"
echo 41400 > "$T/tz/thermal_zone26/temp"; echo 33100 > "$T/tz/thermal_zone79/temp"
echo stock > "$T/mod/current_profile"
row() {
  ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
    _J="$1"; lk_status_json() { echo "$_J"; }
    getprop() { :; }
    MODDIR="$T/mod" LK_OUT_DIR="$T/out" LK_THERMAL_BASE="$T/tz" TZ_CPU_PRIME=26 TZ_CPU_PERF= TZ_SYSTHERM6=79 TZ_BOARD= \
      LK_LAST_SCREEN="$2" lk_capture_battery_trace_row
    tail -n 1 "$T/out/battery_trace.txt" )
}
r="$(row '{}' Awake)"
[ "$(printf '%s' "$r" | cut -d'|' -f4)" = stock ] || fail "profile: $r"
[ "$(printf '%s' "$r" | cut -d'|' -f5)" = 1 ] || fail "screen on not recorded: $r"
[ "$(printf '%s' "$r" | cut -d'|' -f10)" = 41 ] || fail "CPU temperature: $r"
[ "$(printf '%s' "$r" | cut -d'|' -f12)" = 33 ] || fail "surface temperature: $r"
r="$(row '{}' Asleep)"
[ "$(printf '%s' "$r" | cut -d'|' -f5)" = 0 ] || fail "screen off not recorded: $r"
# With a governor its own readings stand.
r="$(row '{"state":"MODERATE","profile":"smart","screen":1,"temp":52,"surface_hotspot":38,' Asleep)"
[ "$(printf '%s' "$r" | cut -d'|' -f4,5,10,12)" = 'smart|1|52|38' ] || fail "governor reading replaced: $r"
F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '|| \[ -z "$_temp" \]; then' "$F" || fail "the phase table still averages an empty Stock temperature as 0"
echo "PASS logkit stock battery row: a Stock capture records the profile, the screen and the zones' temperatures"
)

t_logkit_sysui_redraw_runtime() (
# Runtime (fix159): when SystemUI misses frames in every interval, the report names the
# status-bar settings that redraw every second.
#
# The owner's OP15 shows SystemUI at about one janky frame a second in every screen-on interval
# of four captures, at 60, 90 and 120 Hz alike - against 0.05-0.2 a second on two other OP15s
# and an OP15R. The report already says "a steady redraw, turn off what updates every second",
# but not what is switched on. The REAL capture function records the status-bar settings once
# (fake `settings` here), and the REAL report prints them under the steady-redraw line - only
# when SystemUI is the steady source, and nothing when the phone has none of those settings.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL sysui redraw: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/a" "$T/b"
cat > "$T/bin/settings" <<'S'
#!/bin/sh
[ "$1" = list ] || exit 0
case "$2" in
  system) printf '%s\n' 'peak_refresh_rate=165.0' 'show_network_speed=1' 'status_bar_show_battery_percent=1' 'screen_off_timeout=30000' \
            'oplus.radio.smart5g_apk_cfg=ver_num=9;filetrans=org.zwanoo.android.speedtest,com.Wifi.lte5g.Internetspeed;others=com.antutu.ABenchMark' ;;
  secure) printf '%s\n' 'clock_seconds=1' 'doze_always_on=0' 'icon_blacklist=rotate,ime,show_network_speed,vpn' ;;
  global) printf '%s\n' 'wifi_on=1' ;;
esac
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = wallpaper ] || exit 0
printf '%s\n' 'System wallpaper state:' ' User 0: id=12 mWidth=1440' '  mWallpaperComponent=ComponentInfo{com.example.live/com.example.live.Waves}'
S
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_display_config_capture' "$C" "$T/a"
D="$T/a/display_config.txt"
grep -qx '## status bar redraw settings' "$D" || f "no status-bar section in display_config"
grep -qx 'system: show_network_speed=1' "$D" || f "network speed meter not recorded"
grep -qx 'secure: clock_seconds=1' "$D" || f "seconds on the clock not recorded"
grep -q 'screen_off_timeout\|doze_always_on\|wifi_on' "$D" && f "unrelated settings recorded"
# fix168: the owner's capture listed oplus.radio.smart5g_apk_cfg - two kilobytes of 5G app
# lists - because its VALUE holds "Internetspeed". Keys are matched, not values.
grep -q 'smart5g_apk_cfg' "$D" && f "a setting matched on its value"
grep -qx 'secure: icon_blacklist=rotate,ime,show_network_speed,vpn' "$D" || f "hidden status-bar icons not recorded"
grep -qx 'wallpaper: ComponentInfo{com.example.live/com.example.live.Waves} - a wallpaper service; a live one redraws whenever it is visible' "$D" || f "wallpaper not recorded"
J="$T/a/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg|jank_pkgs" > "$J"
i=0
while [ $i -lt 10 ]; do
  i=$((i + 1))
  printf '%s|t|active|MODERATE|48|0|0|1|4000|60|60|10|5|1|0|com.twitter.android|com.android.systemui:48:200,com.twitter.android:12:3800\n' "$i" >> "$J"
done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out" | grep -q '^com.android.systemui missed deadlines in 10 of 10 screen-on intervals' || f "steady redraw line missing: $out"
printf '%s\n' "$out" | grep -q '^status-bar settings read on this phone at the start of the capture:$' || f "settings heading missing: $out"
printf '%s\n' "$out" | grep -qx '  system: show_network_speed=1' || f "network speed not listed: $out"
printf '%s\n' "$out" | grep -qx '  secure: clock_seconds=1' || f "clock seconds not listed: $out"
printf '%s\n' "$out" | grep -q '^  wallpaper: ComponentInfo{com.example.live' || f "wallpaper not listed: $out"
cp "$J" "$T/b/jank_trace.tsv"
out2="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/b" 2>&1)"
printf '%s\n' "$out2" | grep -q 'missed deadlines in 10 of 10' || f "steady redraw line missing without a config file"
printf '%s\n' "$out2" | grep -q 'status-bar settings read' && f "a settings heading printed with nothing recorded: $out2"
sed 's/com.android.systemui:48:200,com.twitter.android:12:3800/com.twitter.android:60:4000/' "$J" > "$T/a/j2" && mv "$T/a/j2" "$J"
out3="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out3" | grep -q 'status-bar settings read' && f "status-bar settings printed for an app that is not SystemUI: $out3"
# fix186: all three usual sources already off (an OP15 capture) - say so, do not advise them.
mkdir -p "$T/c" "$T/bin2"
cat > "$T/bin2/settings" <<'S'
#!/bin/sh
[ "$1" = list ] || exit 0
case "$2" in
  system) printf '%s\n' 'show_network_speed=0' 'status_bar_show_battery_percent=0' ;;
  secure) printf '%s\n' 'clock_seconds=0' 'icon_blacklist=rotate,ime,show_network_speed' ;;
esac
S
cat > "$T/bin2/dumpsys" <<'S'
#!/bin/sh
[ "$1" = wallpaper ] || exit 0
printf '%s\n' '  mWallpaperComponent=ComponentInfo{com.android.systemui/com.android.systemui.wallpapers.ImageWallpaper}'
S
chmod +x "$T/bin2/"*
PATH="$T/bin2:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_display_config_capture' "$C" "$T/c"
sed 's/com.twitter.android:60:4000/com.android.systemui:48:200,com.twitter.android:12:3800/' "$J" > "$T/c/jank_trace.tsv"
out4="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/c" 2>&1)"
printf '%s\n' "$out4" | grep -q '^The usual per-second sources are already off on this phone' || f "all-off case not recognised: $out4"
printf '%s\n' "$out4" | grep -q '^Turn off one thing at a time that it updates every second' && f "advised switching off what is already off: $out4"
printf '%s\n' "$out" | grep -q '^Turn off one thing at a time that it updates every second' || f "the advice is gone where it applies: $out"
[ "$fail" = 0 ] && echo "PASS sysui redraw: the status-bar settings that redraw every second are recorded and named under a steady SystemUI redraw"
exit "$fail"
)

t_logkit_sysui_verdict_runtime() (
# Runtime (fix133): a SystemUI restart in the full-day capture carries one line saying why.
#
# The restart block showed "dropbox system_app_crash (latest)" - the latest crash of ANY
# system app. An OP15 capture had a Contacts crash there for both SystemUI restarts, while
# the crash buffer held the real cause: SIGSEGV in libart.so (ProfileSaver) inside
# com.android.systemui. The REAL verdict function runs on fixtures cut from that capture.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
fail() { echo "FAIL logkit sysui verdict: $*" >&2; exit 1; }
v() { sh -c '. "$0" >/dev/null 2>&1; lk_sysui_verdict' "$C"; }

# A native crash of SystemUI, after an unrelated process's tombstone.
out="$(v <<'T'
10-12 11:20:00.000   700   700 F DEBUG   : pid: 9001, tid: 9001, name: something  >>> com.android.contacts <<<
10-12 11:20:00.000   700   700 F DEBUG   : signal 7 (SIGBUS), code 2 (BUS_ADRERR), fault addr 0x1
10-12 11:20:00.000   700   700 F DEBUG   :       #00 pc 000000000007126c  /system/lib64/libft2.so (tt_face_load_strike_metrics+96) (BuildId: d9)
10-12 11:25:10.110   759   759 F DEBUG   : pid: 8142, tid: 8230, name: Profile Saver  >>> com.android.systemui <<<
10-12 11:25:10.110   759   759 F DEBUG   : signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x00000000c2e15038
10-12 11:25:10.111   759   759 F DEBUG   :       #00 pc 00000000004feeb8  /apex/com.android.art/lib64/libart.so (void art::ProfileSaver::GetClassesAndMethodsHelper::CollectInternal<false>(art::Handle<art::mirror::ClassLoader>)+176) (BuildId: a4)
T
)"
case "$out" in "native crash SIGSEGV in libart.so (art::ProfileSaver::"*"not a kill") : ;; *) fail "native: $out" ;; esac
# A Java crash.
out="$(v <<'T'
10-12 11:25:10.000  8142  8142 E AndroidRuntime: FATAL EXCEPTION: main
10-12 11:25:10.000  8142  8142 E AndroidRuntime: Process: com.android.systemui, PID: 8142
10-12 11:25:10.000  8142  8142 E AndroidRuntime: java.lang.IllegalStateException: View not attached
T
)"
[ "$out" = "Java crash: java.lang.IllegalStateException: View not attached" ] || fail "java: $out"
# Another process crashed; SystemUI did not.
out="$(v <<'T'
10-12 11:20:00.000   700   700 F DEBUG   : pid: 9001, tid: 9001, name: x  >>> com.android.contacts <<<
10-12 11:20:00.000   700   700 F DEBUG   : signal 7 (SIGBUS), code 2 (BUS_ADRERR), fault addr 0x1
10-12 11:20:00.000   700   700 F DEBUG   :       #00 pc 000000000007126c  /system/lib64/libft2.so (tt+96)
10-11 22:08:35.415   654   654 E lowmemorykiller: device has enough memory 4998492Kib, disable killing
T
)"
case "$out" in "no SystemUI crash in the crash buffer"*) : ;; *) fail "other process taken for SystemUI: $out" ;; esac
# A low-memory kill of SystemUI.
out="$(v <<'T'
10-12 11:25:10.000   654   654 I lowmemorykiller: Kill 'com.android.systemui' (8142), uid 10283, oom_score_adj -800
T
)"
[ "$out" = "killed by lowmemorykiller" ] || fail "lmk: $out"
grep -q 'echo "verdict: $(printf' "$C" || fail "restart block does not record the verdict"
grep -q '/^verdict: / { print "      " $0 }' "$FD" || fail "report does not print the verdict"
echo "PASS logkit sysui verdict: native, Java, other-process and low-memory cases"
)

t_logkit_traffic_edge_runtime() (
# Runtime (fix137): the screen-off traffic line and the phase table add up.
#
# Capture 2830: "sleep ... rmnetMiB 168.7" in the phase table, "measured screen-off mobile
# traffic 45.7 MiB" below it. Both were right - the 122.9 MiB moved in the interval in which
# the morning screen came on, which the table counts and the measured line silently dropped.
# The REAL awk from asb_log_full_day.sh runs against a battery_trace fixture.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL logkit traffic edge: $*" >&2; exit 1; }
# The program between the quotes of  _meas="$(awk -F'|' -v A=.. -v Z=.. '<program>' file)".
awk '/_meas="\$\(awk -F.\|. -v A="\$_a" -v Z="\$_z" .\$1/ { on = 1 }
     on { print }
     on && /END \{ printf "%d %d %d", m \+ 0, e \+ 0, wf \+ 0 \}/ { exit }' "$SRC" \
  | sed -e "1s/^.*-v Z=\"\$_z\" '//" -e "\$s/' \"\$LK_OUT_DIR.*\$//" > "$TMP/meas.awk"
grep -q 'else if (ps != \$5) e += b - pb' "$TMP/meas.awk" || fail "edge accounting not found"
# epoch|...|screen(5)|...|wifi_rx(24)|wifi_tx(25)|rmnet_rx(26)|rmnet_tx(27): only the columns
# the program reads matter. fix148: Wi-Fi with the screen off is the third figure; a Wi-Fi
# counter that went backwards (interface restarted) adds nothing.
row() { printf '%s|x|x|x|%s|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|%s|0|%s|%s\n' "$1" "$2" "$5" "$3" "$4"; }
{ row 1000 1 100 0 0          # screen on before the phase
  row 1100 0 200 0 1000       # phase starts (screen off)
  row 1200 0 1048776 0 2098152  # +1 MiB mobile, +2 MiB Wi-Fi with the screen off
  row 1250 0 2097352 0 500    # +1 MiB mobile; Wi-Fi counter reset
  row 1300 0 3145928 0 1049076  # +1 MiB mobile, +1 MiB Wi-Fi
  row 1302 1 9437384 0 9999999; } > "$TMP/bt.txt"   # the morning: +6 MiB across the screen-on edge
out="$(awk -F'|' -v A=1100 -v Z=1301 -f "$TMP/meas.awk" "$TMP/bt.txt")"
[ "$out" = "3145728 6291456 3145728" ] || fail "measured/edge/Wi-Fi split wrong: $out"
grep -q 'in the interval the screen changed state' "$SRC" || fail "edge traffic not printed"
grep -q 'measured screen-off mobile traffic %.1f MiB, Wi-Fi %.1f MiB' "$SRC" || fail "Wi-Fi not printed beside mobile"
echo "PASS logkit traffic edge: screen-off measured and screen-change edge reported apart, adding up to the table, Wi-Fi beside mobile"
)

t_logkit_wifi_leave_runtime() (
# Runtime (fix152): the full-day capture keeps the Wi-Fi leave watcher's events and says how
# long leaving took.
#
# Testers: "it leaves Wi-Fi about 10 s sooner, but still holds a dead access point for about
# 10 s". The watcher's own log keeps 80 lines and no capture copied it, so neither that nor
# the fix151 change could be measured. The REAL collector copies new lines each poll -
# nothing from before the capture, nothing twice, also after the watcher trims its log - and
# the REAL report section counts releases by reason and the time from the first failing
# reading to the release.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit wifi leave: $*" >&2; fail=1; }
mkdir -p "$T/out" "$T/mod/config"
{ sed -n '/^lk_wifi_leave_collect() {$/,/^}$/p' "$S"; sed -n '/^lk_emit_wifi_leave_summary() {$/,/^}$/p' "$S"; } > "$T/f.sh"
grep -q '^lk_emit_wifi_leave_summary() {$' "$T/f.sh" || f "summary function not found"
grep -q '^  lk_wifi_leave_collect$' "$S" || f "the poll loop does not collect"
grep -q '^    lk_emit_wifi_leave_summary$' "$S" || f "the report has no Wi-Fi leave section"
printf 'net_wifi_leave=aggressive\nnet_wifi_leave_dbm=-80\n' > "$T/mod/config/governor.conf"
L="$T/wifi_fallback.log"
w() { printf '%s wifi_fallback: %s\n' "$1" "$2" >> "$L"; }
w '2026-10-20 08:00:00' 'out of range (rssi=-88) pass 1/3'
w '2026-10-20 08:00:03' 'out of range (rssi=-88) pass 2/3'
w '2026-10-20 08:00:06' 'out of range (rssi=-88) - releasing Wi-Fi default route for 30s'
run() { LK_OUT_DIR="$T/out" LK_MODDIR="$T/mod" LK_WIFI_FALLBACK_LOG="$L" LK_WIFI_SINCE='2026-10-20 09:00:00' sh -c '. "$1"; '"$1" x "$T/f.sh"; }
run lk_wifi_leave_collect
[ -s "$T/out/wifi_leave_events.log" ] && f "events from before the capture were copied"
w '2026-10-20 09:10:00' 'out of range (rssi=-86) pass 1/3'
w '2026-10-20 09:10:03' 'out of range (rssi=-86) pass 2/3'
w '2026-10-20 09:10:06' 'out of range (rssi=-86) - releasing Wi-Fi default route for 30s'
run lk_wifi_leave_collect
run lk_wifi_leave_collect
[ "$(grep -c . "$T/out/wifi_leave_events.log")" = 3 ] || f "first copy wrong: $(cat "$T/out/wifi_leave_events.log")"
w '2026-10-20 09:10:36' 'Wi-Fi re-enabled after ASB fallback window'
w '2026-10-20 09:10:36' 'cooldown started (300s)'
w '2026-10-20 09:30:00' 'out of range (rssi=-84) pass 1/3'
w '2026-10-20 09:40:00' 'unvalidated Wi-Fi pass 1/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:03' 'unvalidated Wi-Fi pass 2/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:09' 'released unvalidated Wi-Fi default route for 60s'
tail -n 4 "$L" > "$L.t"; mv "$L.t" "$L"
w '2026-10-20 10:00:00' 'could not disable Wi-Fi; no route action taken'
run lk_wifi_leave_collect
[ "$(grep -c 'released unvalidated' "$T/out/wifi_leave_events.log")" = 1 ] || f "line after a trimmed log lost or doubled"
[ "$(grep -c 'pass 1/3' "$T/out/wifi_leave_events.log")" -ge 2 ] || f "streak starts lost"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'rung now: aggressive, threshold -80 dBm' "$T/rep" || f "rung line: $(cat "$T/rep")"
grep -q '^releases: 2 (out of range 1, no internet 1) - Wi-Fi given back after the window: 0, could not disable: 1$' "$T/rep" || f "counts: $(cat "$T/rep")"
grep -qx 'first failing reading to the release: median 7 s, longest 9 s (2 release(s))' "$T/rep" || f "timing: $(cat "$T/rep")"
grep -qx 'failing streaks that recovered before a release: 1' "$T/rep" || f "recovered: $(cat "$T/rep")"
rm -f "$T/out/wifi_leave_events.log"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'no watcher events in this capture' "$T/rep" || f "empty capture: $(cat "$T/rep")"
[ "$fail" = 0 ] && echo "PASS logkit wifi leave: watcher events kept for the whole capture, releases timed from the first failing reading"
exit "$fail"
)

t_webui_back_nav_runtime() (
# Runtime (fix159): the back gesture steps back inside the WebUI and leaves it only from Home;
# the Monitor's Smart card shows the drain with the screen on and off and opens a sheet with
# what each figure is based on.
#
# Asked for: from a category, a popup or any page but Home, back should go back inside the
# WebUI (as other modules do); only back on Home leaves. A root manager's WebView goes back
# through the page's history before it closes, so the page keeps one history entry per open
# level. The REAL navigation code runs in node against a history that behaves like a WebView's
# (pushState, go(-n) answered by an asynchronous popstate, nothing left = the manager closes the
# page), and the REAL drain sheet painter is run with the Smart card's figures.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui back nav: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui back nav: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ "$(grep -c "addEventListener('popstate'" "$H")" = 1 ] || fail "more than one popstate handler - two would both act on one back"
grep -q 'if (typeof navSyncSoon === .function.) navSyncSoon();' "$H" || fail "category changes do not resync the history"
for id in bnDrainStrip bnDrainOff bnSlotTemp bnDrain; do grep -q "id=\"$id\"" "$H" || fail "Smart card lacks #$id"; done
grep -q 'onclick="liveDrainOpen()"' "$H" || fail "the drain strip does not open the sheet"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  J="$ROOT/webroot/i18n/$l.json"
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp lv_scr_on lv_scr_off lv_drain_title lv_drain_on_now lv_drain_on_recent lv_drain_on_slot lv_drain_on_wait lv_drain_off_measured lv_drain_off_wait lv_drain_left lv_drain_note; do
    grep -q "\"$k\"" "$J" || fail "$l.json lacks $k"
  done
  for k in lv_drain_on_now lv_drain_off_measured lv_drain_left; do
    grep -q "\"$k\": \"[^\"]*%s" "$J" || fail "$l.json $k has no place for its number"
  done
done
{
  sed -n '/^const NAV_OVERLAYS = \[/,/^})();$/p' "$H"
  cat <<'EOF'
;
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
async function tick() { for (let i = 0; i < 6; i++) await new Promise(function (r) { setImmediate(r); }); }
async function back() { if (!hist.canGoBack()) { exited++; return; } hist.go(-1); await tick(); }
(async function () {
  chk(_nav.depth === 0 && hist.idx === 0, 'start: ' + _nav.depth + '/' + hist.idx);
  _liveOpen = true; navSync();
  chk(hist.idx === 1, 'Monitor opened: one history entry, have ' + hist.idx);
  _el('liveDrainSheet').hidden = false; navSync();
  chk(hist.idx === 2, 'drain sheet opened: two entries, have ' + hist.idx);
  await back();
  chk(_el('liveDrainSheet').hidden === true && _liveOpen === true, 'back closed the sheet and kept Monitor');
  await back();
  chk(_liveOpen === false && hist.idx === 0 && exited === 0, 'back from Monitor went Home, not out: live=' + _liveOpen + ' idx=' + hist.idx);
  await back();
  chk(exited === 1, 'back on Home leaves the WebUI');

  exited = 0;
  _cfgOpen = true; navSync(); _cfgGroup = 'battery'; navSync(); _el('dozeKeepModal').hidden = false; navSync();
  chk(hist.idx === 3, 'Settings > Battery > picker: three entries, have ' + hist.idx);
  await back();
  chk(_el('dozeKeepModal').hidden && _cfgGroup === 'battery' && _cfgOpen, 'back closed the picker only');
  await back();
  chk(_cfgGroup === null && _cfgOpen, 'back left the category for the Settings hub');
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'back from the hub went Home');

  _cfgOpen = true; _cfgGroup = 'audio'; navSync();
  chk(hist.idx === 2, 'category opened: two entries, have ' + hist.idx);
  _cfgGroup = null; navSync(); await tick();
  chk(hist.idx === 1 && _cfgOpen && !_nav.pending, 'category closed by a tap: history stepped back once without acting, idx=' + hist.idx);
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'next back went Home after a tap-close');

  _liveOpen = true; navSync(); _liveOpen = false; _cfgOpen = true; navSync(); await tick();
  chk(hist.idx === 1, 'switching tabs Monitor -> Settings keeps one entry, have ' + hist.idx);
  _el('logMenu').hidden = false; _el('cfgFm').hidden = false; navSync();
  chk(hist.idx === 3, 'two overlays over Settings: three entries, have ' + hist.idx);
  await back();
  chk(_el('logMenu').hidden && !_el('cfgFm').hidden, 'back closes one overlay at a time');
  await back(); await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'everything closed, Home reached, nothing left the WebUI');
  await back();
  chk(exited === 1, 'and only now does back leave');

  /* fix197: the log report is a page of its own - back closes it and returns to the page
   * it was opened from, instead of leaving the WebUI. */
  exited = 0;
  _rpOpen = true; navSync();
  chk(hist.idx === 1, 'report over Home: one entry, have ' + hist.idx);
  await back();
  chk(_rpOpen === false && hist.idx === 0 && exited === 0, 'back closed the report, stayed in the WebUI');
  _cfgOpen = true; navSync(); _rpOpen = true; navSync();
  chk(hist.idx === 2, 'report over Settings: two entries, have ' + hist.idx);
  await back();
  chk(_rpOpen === false && _cfgOpen === true && hist.idx === 1, 'back from the report returned to Settings');
  await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'and the next back went Home');

  /* fix230: Device is the top page. Back returns to Report or to the exact Config category
   * underneath it instead of unloading the WebUI or skipping a level. */
  _rpOpen = true; navSync(); _deviceOpen = true; navSync();
  chk(hist.idx === 2, 'Device over Report: two entries, have ' + hist.idx);
  await back();
  chk(!_deviceOpen && _rpOpen && hist.idx === 1, 'back from Device returned to Report');
  await back();
  chk(!_rpOpen && hist.idx === 0 && exited === 0, 'next back closed Report');
  _cfgOpen = true; navSync(); _cfgGroup = 'audio'; navSync(); _deviceOpen = true; navSync();
  chk(hist.idx === 3, 'Device over Config category: three entries, have ' + hist.idx);
  await back();
  chk(!_deviceOpen && _cfgOpen && _cfgGroup === 'audio' && hist.idx === 2, 'back from Device preserved the Config category');
  await back(); await back();
  chk(!_cfgOpen && hist.idx === 0 && exited === 0, 'Config category and hub closed after Device');

  _lvDrain.on = 'recent'; _lvDrain.off = 'measured'; _lvDrain.offN = 3; _lvDrain.winS = 0;
  _el('bnDrain').textContent = '~8.5%/h'; _el('bnDrainOff').textContent = '0.52%/h';
  _el('liveEtaOn').textContent = '8h 56m'; _el('liveEtaOff').textContent = '> 72h';
  liveDrainPaint();
  const blocks = _el('liveDrainBody').children;
  chk(blocks.length === 3, 'sheet: two figures and a note, have ' + blocks.length);
  const txt = function (b) { return b.children[1].children.map(function (c) { return c.className + '=' + c.textContent; }).join(' | '); };
  const on = txt(blocks[0]), off = txt(blocks[1]);
  chk(/live-drain-val=~8\.5%\/h/.test(on) && /lv_drain_on_recent/.test(on) && /to 0%: 8h 56m/.test(on), 'screen-on block: ' + on);
  chk(/live-drain-val=0\.52%\/h/.test(off) && /stretch\(es\)/.test(off) && / 3 /.test(off) && /to 0%: > 72h/.test(off), 'screen-off block: ' + off);
  _lvDrain.on = 'charging'; _lvDrain.off = 'wait'; liveDrainPaint();
  const on2 = txt(_el('liveDrainBody').children[0]), off2 = txt(_el('liveDrainBody').children[1]);
  chk(!/to 0%/.test(on2), 'no time-to-empty while charging: ' + on2);
  chk(/lv_drain_off_wait/.test(off2), 'screen-off waits for an hour of screen off: ' + off2);
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/body.js"
cat > "$T/run.js" <<'EOF'
const fs = require('fs');
const els = {};
function mk(tag) {
  const e = { tagName: tag, id: '', hidden: true, className: '', innerHTML: '', children: [], attrs: {}, _t: '',
    setAttribute: function (k, v) { this.attrs[k] = v; }, addEventListener: function () {},
    appendChild: function (c) { this.children.push(c); if (c.id) els[c.id] = c; return c; } };
  Object.defineProperty(e, 'textContent', { get: function () { return this._t; }, set: function (v) { this._t = String(v); this.children = []; } });
  return e;
}
['logMenu', 'liveDrainSheet', 'cfgFm', 'dozeKeepModal', 'cfgResetModal', 'cfgProfileModal', 'bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff',
 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { const e = mk('div'); e.id = id; els[id] = e; });
['bnDrain', 'bnDrainOff', 'liveEtaOn', 'liveEtaOff', 'liveDrainBody', 'liveDrainTitle', 'liveDrainDone'].forEach(function (id) { els[id].hidden = false; });
const listeners = {};
const hist = { stack: [{ state: null }], idx: 0,
  pushState: function (s) { this.stack = this.stack.slice(0, this.idx + 1); this.stack.push({ state: s }); this.idx++; },
  canGoBack: function () { return this.idx > 0; },
  go: function (n) { const self = this; setImmediate(function () { self.idx = Math.max(0, self.idx + n); (listeners.popstate || []).forEach(function (f) { f({ state: self.stack[self.idx].state }); }); }); } };
global.hist = hist; global.exited = 0;
global.window = { history: hist, addEventListener: function (t, f) { (listeners[t] = listeners[t] || []).push(f); } };
global.history = hist;
global.document = { body: mk('body'), createElement: mk, addEventListener: function () {} };
global.MutationObserver = function () { this.observe = function () {}; };
global._el = function (id) { return els[id] || null; };
global.T = function (k, d) { return d; };
global.techIcon = function (k) { return '<svg data-k="' + k + '"></svg>'; };
global.uiSound = function () {};
global._liveOpen = false; global._cfgOpen = false; global._cfgGroup = null; global._rpOpen = false; global._deviceOpen = false;
global.closeLivePage = function () { _liveOpen = false; };
global.closeConfigPage = function () { _cfgOpen = false; _cfgGroup = null; };
global.closeReportPage = function () { _rpOpen = false; };
global.closeDevicePage = function () { _deviceOpen = false; };
global.cfgBack = function () { _cfgGroup = null; };
global.asbCloseLogMenu = function () { els.logMenu.hidden = true; };
global.cfgFmClose = function () { els.cfgFm.hidden = true; };
global.dozeKeepClose = function () { els.dozeKeepModal.hidden = true; };
global.cfgResetDialogClose = function () { els.cfgResetModal.hidden = true; };
global.cfgProfileClose = function () { els.cfgProfileModal.hidden = true; };
const src = fs.readFileSync(process.argv[2], 'utf8')
  .replace('const _nav =', 'var _nav =').replace('const _lvDrain =', 'var _lvDrain =')
  .replace(/T\('lv_drain_on_recent', '[^']*'\)/, "'lv_drain_on_recent'").replace(/T\('lv_drain_off_wait', '[^']*'\)/, "'lv_drain_off_wait'");
(0, eval)(src);
EOF
out="$(node "$T/run.js" "$T/body.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui back nav: back closes the top popup, then the category, then the page; only Home lets the WebUI close; the drain sheet shows both figures with their basis"
)

t_webui_doze_keep_picker_runtime() (
# Runtime (fix152): the WebUI picker for apps the Doze trim must leave alone.
#
# Testers asked to choose these apps in the WebUI, easily, with a search. The REAL page
# functions run in node on the REAL applier's `list` output (fake pm / deviceidle):
#   - every user app is offered, not only the ones Android still exempts, and an app ASB
#     already trimmed is there to tick, marked as trimmed;
#   - names come from the root manager when it gives them, and the search finds an app by
#     its name or by its package;
#   - ticked apps come first, then what ASB trimmed, then the exempt ones, then the rest;
#   - the saved file holds exactly the ticked packages, one per line, and nothing else.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep picker: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep picker: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q "eb.onclick = (e) => { e.stopPropagation(); uiSound('option'); dozeOpenEditor(); };" "$H" || fail "the card button does not open the picker"
grep -q "run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' list 2>/dev/null')" "$H" || fail "the picker does not read the applier's list"
grep -q "try { await run('sh ' + shQuote(MD + '/runtime/asb_doze_apply.sh') + ' >/dev/null 2>&1'); } catch (e) {}" "$H" || fail "closing the picker does not apply"
grep -q 'id="dozeKeepSearch" type="search"' "$H" || fail "no search field"
for l in en ru uk; do
  for k in doze_keep_title doze_keep_search doze_keep_copy doze_tag_trimmed doze_chip_trimmed doze_keep_saved; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' com.example.zeta org.telegram.messenger com.example.vpn com.example.game com.azure.authenticator com.whatsapp com.example.alpha
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] && [ "$2" = whitelist ] && [ -z "${3:-}" ] || exit 0
printf '%s\n' 'system-excidle,com.android.phone,1001' 'user,com.example.vpn,10100' 'user,com.azure.authenticator,10101'
S
chmod +x "$T/bin/"*
printf 'doze_level=night\ndoze_trim_whitelist=1\n' > "$T/mod/config/governor.conf"
printf '%s\n' com.example.game > "$T/st/doze_whitelist_removed"
printf '%s\n' com.example.zeta > "$T/st/doze_whitelist_keep"
PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" sh "$ROOT/runtime/asb_doze_apply.sh" list > "$T/list" 2>/dev/null
{
  echo "const DOZE_KEEP_PATH = process.env.KEEP;"
  sed -n '/^const DOZE_MESSENGERS = \[/,/^\];/p' "$H"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  grep '^function dozePkgOk(p) { return /^\[A-Za-z0-9_.\]+\$/.test(p); }$' "$H"
  for fn in shQuote dozeIsMessenger dozeKeepParse dozeKeepLabels dozeKeepRank dozeKeepMatch dozeKeepWrite; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
const fs = require('fs'); const cp = require('child_process');
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const d = dozeKeepParse(fs.readFileSync(process.env.LIST, 'utf8'));
chk(d.trim === true, 'night doze with trim on not read as working');
chk(d.apps.length === 7, 'not every user app offered: ' + d.apps.length);
chk(!d.E['com.android.phone'] && !d.apps.some(a => a.pkg === 'com.android.phone'), 'a system entry offered');
chk(d.R['com.example.game'] === 1, 'the app ASB trimmed is not marked');
chk(d.apps.some(a => a.pkg === 'com.example.game'), 'the app ASB trimmed is not offered');
chk(d.apps.find(a => a.pkg === 'com.azure.authenticator').prot === true, 'rule protection lost');
global.ksu = { getPackagesInfo: function (j) {
  const want = JSON.parse(j);
  const names = { 'org.telegram.messenger': 'Telegram', 'com.whatsapp': 'WhatsApp', 'com.example.alpha': 'Альфа Банк', 'com.example.zeta': 'com.example.zeta' };
  return JSON.stringify(want.map(p => ({ packageName: p, appLabel: names[p] || '' })));
} };
const labels = dozeKeepLabels(d.apps.map(a => a.pkg));
chk(labels['org.telegram.messenger'] === 'Telegram', 'name from the root manager not used');
chk(!('com.example.zeta' in labels), 'a label equal to the package treated as a name');
delete global.ksu;
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'no root-manager API must give no names, not an error');
global.ksu = { getPackagesInfo: function () { throw new Error('x'); } };
chk(Object.keys(dozeKeepLabels(['com.whatsapp'])).length === 0, 'a failing API must give no names');
delete global.ksu;
const apps = d.apps.map(function (a) {
  const name = labels[a.pkg] || '';
  return { pkg: a.pkg, name: name, prot: a.prot, e: !!d.E[a.pkg], r: !!d.R[a.pkg], g: !!d.G[a.pkg],
    msg: dozeIsMessenger(a.pkg), kept0: !!d.K[a.pkg], q: (name + ' ' + a.pkg).toLowerCase() };
});
apps.sort(function (x, y) { const a = dozeKeepRank(x), b = dozeKeepRank(y); return a !== b ? a - b : (x.name || x.pkg).toLowerCase().localeCompare((y.name || y.pkg).toLowerCase()); });
const order = apps.map(a => a.pkg).join(' ');
chk(order === 'com.example.zeta com.example.game com.example.vpn org.telegram.messenger com.whatsapp com.example.alpha com.azure.authenticator', 'order: ' + order);
_dozeKeep.apps = apps; _dozeKeep.keep = { 'com.example.zeta': 1 };
function hits(q, f) { _dozeKeep.q = q.toLowerCase(); _dozeKeep.filter = f || 'all'; return apps.filter(dozeKeepMatch).map(a => a.pkg).join(' '); }
chk(hits('tele') === 'org.telegram.messenger', 'search by name: ' + hits('tele'));
chk(hits('WHATS') === 'com.whatsapp', 'search is case-sensitive');
chk(hits('альфа') === 'com.example.alpha', 'search by a Cyrillic name: ' + hits('альфа'));
chk(hits('messenger') === 'org.telegram.messenger', 'search by package: ' + hits('messenger'));
chk(hits('', 'trimmed') === 'com.example.game', 'trimmed filter: ' + hits('', 'trimmed'));
chk(hits('', 'kept') === 'com.example.zeta', 'ticked filter: ' + hits('', 'kept'));
chk(hits('zzz') === '', 'a search with no match still shows apps');
let cmd = '';
global.run = function (c) { cmd = c; return Promise.resolve({ errno: cp.spawnSync('sh', ['-c', c]).status }); };
_dozeKeep.keep = { 'org.telegram.messenger': 1, 'com.whatsapp': 1, "x';touch /tmp/asb_pwn;'": 1 };
dozeKeepWrite().then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === 'com.whatsapp\norg.telegram.messenger\n', 'file: ' + JSON.stringify(fs.readFileSync(process.env.KEEP, 'utf8')));
  chk(!fs.existsSync('/tmp/asb_pwn') && cmd.indexOf('pwn') < 0, 'an invalid name reached the shell');
  chk(_dozeKeep.failed === false, 'a good write reported as failed');
  _dozeKeep.keep = {};
  return dozeKeepWrite();
}).then(function () {
  chk(fs.readFileSync(process.env.KEEP, 'utf8') === '', 'unticking everything left names in the file');
  process.exit(bad ? 1 : 0);
});
EOF
} > "$T/t.js"
LIST="$T/list" KEEP="$T/keep" node "$T/t.js" || fail "see above"
echo "PASS webui doze keep picker: all user apps, trimmed ones marked, search by name or package, exact keep file"
)

t_webui_doze_keep_tags_runtime() (
# Runtime (fix158): the picker's labels say what will happen, and the night window is named.
#
# Asked: what is the difference between "exempt" and "exempt via ASB", between Ticked and
# Trimmed, and does Trimmed work. The labels were fixed when the list opened, so ticking an
# app ASB had trimmed still read "trimmed by ASB" until the window was closed and opened
# again, and Deep Sleep on night by day showed an empty Trimmed with no reason. The REAL page
# functions run in node:
#   - the applier's window/night lines are read;
#   - each label follows the tick: trimmed -> returns on Done, ASB's exemption -> removed on
#     Done, a new tick -> exempt on Done, an exempt app just unticked -> trimmed on Done (only
#     while the trim is live), and back to the plain label when the tick is undone;
#   - protected apps keep their own label whatever the tick;
#   - every new string exists in every language, and the legend names every label.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui doze keep tags: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui doze keep tags: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q '<details class="doze-keep-legend" id="dozeKeepLegend">' "$H" || fail "no legend in the picker"
grep -q "_dozeKeep.live = d.trim && d.window !== false;" "$H" || fail "the live state ignores the night window"
grep -q "} else if (d.window === false) {" "$H" || fail "no note for the closed night window"
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in doze_tag_back doze_tag_drop doze_tag_willtrim doze_tag_give doze_keep_day doze_keep_legend_title doze_keep_legend; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"doze_keep_day": "[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json doze_keep_day has no place for the window"
done
python3 - "$ROOT/webroot/i18n" <<'P' || fail "a legend does not name every label"
import json, sys
for l in ("en", "ru", "uk", "de", "es", "fr", "it", "pt", "tr", "id", "ar", "hy", "zh"):
    d = json.load(open("%s/%s.json" % (sys.argv[1], l), encoding="utf-8"))
    leg = d["doze_keep_legend"].lower()
    for k in ("doze_tag_exempt", "doze_tag_granted", "doze_tag_trimmed", "doze_tag_always", "doze_chip_kept", "doze_chip_trimmed"):
        if d[k].lower() not in leg:
            print(l, k, d[k]); sys.exit(1)
P
{
  echo "function T(k, d) { return k; }"
  sed -n '/^const _dozeKeep = {/,/};$/p' "$H"
  for fn in dozeKeepParse dozeKeepTag; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const out = ['trim=1', 'level=night', 'window=0', 'night=23:15-06:40', 'A com.a -', 'A com.b -', 'A com.c -',
  'A com.d -', 'A com.auth p', 'E com.b', 'E com.d', 'E com.auth', 'R com.a', 'G com.b', 'K com.b', 'K com.d'].join('\n');
const d = dozeKeepParse(out);
chk(d.trim === true && d.window === false && d.night === '23:15-06:40', 'window lines: ' + JSON.stringify([d.trim, d.window, d.night]));
chk(dozeKeepParse('trim=1\nlevel=aggressive').window === null, 'no window line must read as no window');
chk(dozeKeepParse('window=1').window === true, 'open window');
function app(p) { return { pkg: p, prot: p === 'com.auth', e: !!d.E[p], r: !!d.R[p], g: !!d.G[p], kept0: !!d.K[p] }; }
const A = app('com.a'), B = app('com.b'), C = app('com.c'), D = app('com.d'), P = app('com.auth');
function tag(a) { const t = dozeKeepTag(a); return t ? t[0] : '-'; }
_dozeKeep.trim = true; _dozeKeep.live = true; _dozeKeep.keep = { 'com.b': 1, 'com.d': 1 };
chk(tag(A) === 'trimmed', 'trimmed app: ' + tag(A));
chk(tag(B) === 'granted', 'ASB grant: ' + tag(B));
chk(tag(C) === '-', 'plain app: ' + tag(C));
chk(tag(D) === 'exempt', 'kept exempt app: ' + tag(D));
chk(tag(P) === 'always', 'protected app: ' + tag(P));
_dozeKeep.keep = { 'com.a': 1, 'com.c': 1, 'com.auth': 1 };
chk(tag(A) === 'back', 'ticking a trimmed app: ' + tag(A));
chk(tag(B) === 'drop', 'unticking an ASB grant: ' + tag(B));
chk(tag(C) === 'give', 'ticking an app with no exemption: ' + tag(C));
chk(tag(D) === 'drop' && dozeKeepTag(D)[1] === 'doze_tag_willtrim', 'unticking an exempt app while the trim is live: ' + tag(D));
chk(tag(P) === 'always', 'protected app ticked: ' + tag(P));
_dozeKeep.live = false;
chk(tag(D) === 'exempt', 'unticking an exempt app by day must not promise a trim: ' + tag(D));
chk(tag(C) === 'give', 'by day a tick still gets an exemption: ' + tag(C));
_dozeKeep.trim = false;
chk(tag(C) === '-' && tag(A) === 'trimmed' && tag(B) === 'granted', 'trim off: no promise of a change');
process.exit(bad ? 1 : 0);
EOF
} > "$T/t.js"
node "$T/t.js" || fail "see above"
echo "PASS webui doze keep tags: labels follow the tick, the night window is named, every language explains every label"
)

t_webui_monitor_card_head_runtime() (
# Runtime (fix162, reworked fix163): the Monitor card is symmetric, carries the time to empty
# beside each drain figure, and speaks the UI language.
#
# fix162 moved the "exact" chip off the card border into a title row; the owner found the card
# lopsided that way and the page half empty below the tiles, and asked for the screen-on and
# idle forecasts to sit with the two drain figures they belong to. fix163: a section title over
# the card (as on Home and Settings), two equal battery tiles - drain, then time to empty - and
# the eight Smart readings, the chip's meaning folded into a "Basis" reading; the live grid is
# three rows of three. The REAL page functions run in node.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor card: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor card: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
top = s.index('id="liveTopSecLabel"')
sb = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
st = s[s.index('id="liveStockRomBanner"'):s.index('data-i18n="sec_live"')]
assert top < s.index('id="liveSmartBanner"'), "no section title over the card"
for part, name in ((sb, "Smart"), (st, "ROM")):
    assert "smart-banner-head" not in part and "smart-banner-tag" not in part and "tags" not in part, "%s card still carries a title row or chips" % name
strip = sb[sb.index('id="bnDrainStrip"'):sb.index('<div class="smart-banner-row">')]
halves = strip.split('class="smart-drain-half"')[1:]
assert len(halves) == 2, "want two drain tiles, have %d" % len(halves)
for h, val, eta in zip(halves, ("bnDrain", "bnDrainOff"), ("liveEtaOn", "liveEtaOff")):
    assert 'onclick="liveDrainOpen()"' in h, "a drain tile does not open the sheet"
    assert h.index('id="%s"' % val) < h.index('id="%s"' % eta), "%s is not under %s" % (eta, val)
for k in ("lv_bucket", "lv_conf", "lv_alpha", "lv_app", "lv_basis", "lv_slot_heat", "lv_trend", "lv_lpm"):
    assert ('data-i18n="%s"' % k) in sb, "Smart reading %s missing or untranslated" % k
assert 'id="bnSes"' not in sb and 'id="bnBasis"' in sb, "Basis did not take the sessions slot"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
rows = g.count('<div class="live-row">')
cells = len(re.findall(r'<div class="live-cell"(?: data-lvi="[a-z]+")?>', g))
assert rows == 3 and cells == 9 and "live-cell-wide" not in g, "live grid is %d rows / %d cells, want 3 x 3" % (rows, cells)
assert "fbTag" not in s and "T('lv_fb_' + fb," in s, "the slot source is still a chip"
assert "T('lv_mode_guard'," in s and "T('lv_mode_night'," in s, "night and thermal guard are not shown in Basis"
assert "T('lv_dp_' + dp, dpNames[dp])" in s and "T('lv_app_' + appH," in s, "day part or load class still English"
assert "+ '% bat'" not in s and "T('unit_d', 'd')" in s, "English units left"
assert "_el('liveLearner').textContent = sm.total + ' ' + _ses;" in s, "Learner repeats the confidence instead of the session count"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_card_smart lv_card_rom lv_bucket lv_conf lv_alpha lv_basis lv_we_short lv_wd_short lv_fb_tip lv_eta_meter_tip \
           lv_mode_night lv_mode_guard unit_d lv_dp_0 lv_dp_1 lv_dp_2 lv_dp_3 lv_dp_4 lv_dp_5 \
           lv_app_0 lv_app_1 lv_app_2 lv_app_3 lv_app_4 lv_fb_0 lv_fb_1 lv_fb_2 lv_fb_3 lv_fb_4; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
done
python3 - "$ROOT/webroot/i18n/ru.json" <<'P' || fail "ru strings"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k, v in (("lv_bucket", "Слот"), ("lv_basis", "Основа"), ("lv_fb_0", "свой слот"), ("lv_app_2", "средняя"), ("lv_dp_0", "сон"), ("lv_card_smart", "Батарея и Smart"), ("lv_card_rom", "Батарея и система")):
    assert d[k] == v, (k, d[k])
P
{
  cat <<'EOF'
const _nodes = {};
function _el(id) { return _nodes[id] || null; }
function T(k, d) { return d; }
let _selectedProfile = 'smart';
const _lvMeter = { at: 0, cur: '', p: {} };
function liveDrainIsOpen() { return false; }
function liveDrainPaint() {}
EOF
  for fn in lvEtaFmt lvEtaPaint lvTopSec lvTopSecSync lvDrainHome lvMeterPaint lvPct lvOffFigure; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  sed -n "/^const _lvEta = /p; /^const _lvDrain = /p; /^const _lvGovOff = /p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function el(id) { const e = { id: id, textContent: '', title: '', style: { display: '' }, parentElement: null }; _nodes[id] = e; return e; }
const on = el('liveEtaOn'), off = el('liveEtaOff'); el('bnDrain'); el('bnDrainOff');
_lvEta.gov = { on: 536, onTip: 'gov on', off: 5000, offTip: 'gov off' };
_lvEta.cap = 88;
lvEtaPaint();
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Smart shows the governor forecast: ' + on.textContent + ' / ' + off.textContent);
_lvEta.chg = true; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'no time to empty while charging');
_lvEta.chg = false;
_selectedProfile = 'stock'; lvEtaPaint();
chk(on.textContent === '—' && off.textContent === '—', 'Stock without a measurement borrows nothing from the governor');
_lvMeter.p.stock = { on: 75, off: 50, offN: 1, onMin: 40 };
lvMeterPaint('stock');
chk(on.textContent === '11h 44m' && on.title.indexOf('measured') >= 0, 'Stock: level over its own measured drain: ' + on.textContent);
chk(off.textContent === '> 72h', 'Stock idle past three days shows the ceiling: ' + off.textContent);
_selectedProfile = 'battery'; lvMeterPaint('battery');
chk(on.textContent === '8h 56m' && off.textContent === '> 72h', 'Battery without a measurement falls back to the governor: ' + on.textContent);
_lvMeter.p.battery = { on: 120, off: 0, offN: 0, onMin: 30 };
lvMeterPaint('battery');
chk(on.textContent === '7h 20m' && off.textContent === '> 72h', 'Battery: measured screen-on, governor idle: ' + on.textContent + ' / ' + off.textContent);
const sec = { style: { display: 'none' } };
_nodes.liveTopSecLabel = { textContent: '', parentElement: sec };
const smart = el('liveSmartBanner'), rom = el('liveStockRomBanner');
smart.style.display = 'none'; rom.style.display = 'none';
lvTopSec(true);
chk(sec.style.display === 'none', 'section title hidden while no card is shown');
smart.style.display = ''; lvTopSec(true);
chk(sec.style.display === '' && _nodes.liveTopSecLabel.textContent === 'Battery & Smart', 'Smart card titled');
smart.style.display = 'none'; rom.style.display = ''; lvTopSec(false);
chk(_nodes.liveTopSecLabel.textContent === 'Battery & system', 'ROM card titled');
function card() {
  const c = { kids: [{ k: 'grid' }], style: { display: '' } };
  c.kids.forEach(function (k) { k.parentElement = c; });
  c.firstChild = c.kids[0];
  c.insertBefore = function (n, ref) {
    if (n.parentElement && n.parentElement !== c) { const p = n.parentElement; p.kids = p.kids.filter(function (k) { return k !== n; }); p.firstChild = p.kids[0] || null; }
    c.kids = c.kids.filter(function (k) { return k !== n; });
    const i = ref ? c.kids.indexOf(ref) : c.kids.length; c.kids.splice(i < 0 ? c.kids.length : i, 0, n); n.parentElement = c; c.firstChild = c.kids[0];
  };
  return c;
}
const a = card(), b = card(), strip = { k: 'strip', parentElement: null };
_nodes.bnDrainStrip = strip;
lvDrainHome(a); chk(a.kids[0] === strip, 'drain tiles open the Smart card');
lvDrainHome(b); chk(b.kids[0] === strip && a.kids.indexOf(strip) < 0, 'drain tiles move to the ROM card');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor card: section title, two drain tiles with their time to empty on every profile, Basis instead of chips, three by three live grid, all in the UI language"
)

t_webui_monitor_compact_runtime() (
# Runtime (fix161): the Monitor fits with room to spare, its heat tile no longer scares, every
# profile shows both drains, and the Settings restarts are one row of small tiles.
#
# Owner's screenshot: the last row of Monitor tiles touched the tab bar after the screen-on /
# screen-off pair went into the Smart card, and "usual peak 51.8 C" read as a hot phone - it is
# the hottest core at its busiest moment, and this phone's own norm is 41-49 C. Asked too: the
# drain pair on every profile (Stock included) and lighter restart buttons. The REAL page
# functions run in node; the markup is checked for the new layout.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor compact: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor compact: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'P' || fail "layout"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
b = s[s.index('id="liveSmartBanner"'):s.index('id="liveStockRomBanner"')]
assert b.index('id="bnDrainStrip"') < b.index('id="bnBucket"'), "drain pair is not the first row of the Smart card"
assert 'data-i18n="lv_slot_heat"' in b and 'lv_slot_temp' not in b, "the usual-peak tile is still a bare temperature"
st = s[s.index('id="liveStockRomBanner"'):s.index('<div class="live-metrics">')]
assert 'id="bnStockDrain"' in st, "stock card lost its battery current"
g = s[s.index('<div class="live-metrics">'):s.index('<section class="stock-telemetry"')]
for i in ("liveCpu", "liveSkin", "liveSurface", "liveState", "liveGpu", "liveHeadroom", "liveCapSrc", "liveClamp", "liveLearner"):
    assert ('id="%s"' % i) in g, "metric %s lost" % i
for i in ("liveEtaOn", "liveEtaOff"):
    assert ('id="%s"' % i) in b, "time to empty %s is not beside the drain figures" % i
r = s[s.index('<div id="cfgRebootWrap" class="cfg-reboot-row">'):]
r = r[:r.index('</div>')]
assert r.count('class="cfg-reboot-tile') == 3, "restarts are not three tiles"
assert "#cfgRebootWrap.cfg-reboot-row { display: grid; grid-template-columns: repeat(3, 1fr);" in s, "restart tiles not in one row"
assert re.search(r"if \(stockBanner\) \{ lvDrainHome\(stockBanner\);[^}]*lvMeterPaint\(_selectedProfile\); \}", s), "other profiles do not get the drain pair"
P
for l in en ru uk de es fr it pt tr id ar hy zh; do
  for k in lv_slot_heat lv_heat_cool lv_heat_norm lv_heat_warm lv_heat_tip lv_drain_on_meter lv_drain_cmp cfg_reboot_tile cfg_soft_tile cfg_sysui_tile; do
    grep -q "\"$k\"" "$ROOT/webroot/i18n/$l.json" || fail "$l.json lacks $k"
  done
  grep -q '"lv_heat_tip": "[^"]*%s[^"]*%s' "$ROOT/webroot/i18n/$l.json" || fail "$l.json lv_heat_tip needs two places"
done
{
  echo "var T = function (k, d) { return d; };"
  for fn in lvSlotHeat lvMeterParse liveDrainCompare lvOffFigure; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
let h = lvSlotHeat(518, 414, 494);
chk(h.text === 'warm' && h.warm === true, 'slot above the norm: ' + JSON.stringify(h));
chk(h.tip.indexOf('51.8') >= 0 && h.tip.indexOf('41') >= 0 && h.tip.indexOf('49') >= 0, 'number kept in the tooltip: ' + h.tip);
h = lvSlotHeat(487, 414, 494); chk(h.text === 'typical' && !h.warm, 'slot inside the norm: ' + h.text);
h = lvSlotHeat(400, 414, 494); chk(h.text === 'cool' && !h.warm, 'slot under the norm: ' + h.text);
h = lvSlotHeat(0, 414, 494); chk(h.text === '—', 'nothing learned shows a dash');
h = lvSlotHeat(530, 0, 0); chk(h.text === 'typical' && !h.warm, 'no norm known: never "warm"');
const m = lvMeterParse('smart 1170 300 7230 100 1\nbattery 300 100 0 0 0\nstock 2400 500 7200 100 1\njunk\ncurrent stock\n');
chk(m.cur === 'stock', 'current profile');
chk(m.p.smart.on === 92 && m.p.smart.off === 50, 'smart rates: ' + JSON.stringify(m.p.smart));
chk(m.p.battery.on === 0, 'under 10 min of screen time is not a rate');
chk(m.p.stock.on === 75 && m.p.stock.offN === 1, 'stock rates: ' + JSON.stringify(m.p.stock));
/* fix177: no dash under the moon. A measured screen-off hour whose level did not move is
 * "below one step over the time measured"; with none at all the current profile borrows the
 * governor's own screen-off figure, others say they are measuring. */
const _nodes = {};
globalThis.document = { createElement: function () { return { className: '', textContent: '', title: '', innerHTML: '', children: [], appendChild(c) { this.children.push(c); }, }; }, createTextNode: function (t) { return { textContent: t }; } };
globalThis.techIcon = function () { return ''; };
globalThis.lvPct = function (x, div, digits) { return (x / div).toFixed(digits) + '%/h'; };
const cell = (row, i) => row.children[i].children.map(function (c) { return c.textContent; }).join('');
globalThis._lvMeter = { p: lvMeterParse('smart 1200 300 0 0 0\nbattery 1200 300 14400 0 2\nstock 1200 300 0 0 0\n').p };
globalThis._lvDrain = { off: 'measured', offX: 56 };
globalThis._lvGovOff = { x: 56, n: 5, by: {} };
globalThis._selectedProfile = 'smart';
let box = liveDrainCompare();
let rows = box.children.slice(1);
/* fix189: the phone-wide figure is not lent to the current profile any more ("~0.56" read as
 * Smart's own); the governor's figure for the profile itself is used. */
chk(cell(rows[0], 2) === '\u2026', 'current profile without its own screen-off hour: ' + cell(rows[0], 2));
_lvGovOff.by = { smart: { x: 62, n: 3 } };
box = liveDrainCompare(); rows = box.children.slice(1);
chk(cell(rows[0], 2) === '0.62%/h', 'the governor figure measured in Smart: ' + cell(rows[0], 2));
chk(cell(rows[1], 2) === '<0.25%/h', 'a level that did not move over 4 h: ' + cell(rows[1], 2));
chk(cell(rows[2], 2) === '\u2026', 'another profile still measuring: ' + cell(rows[2], 2));
chk(rows.every(function (r) { return cell(r, 2) !== '\u2014'; }), 'a dash under the moon');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor compact: drain pair first in the card on every profile, heat against the phone's own norm, restarts as one row of tiles"
)

t_webui_quiet_ui_runtime() (
# Runtime (fix145): the WebUI keeps still and quiet where it should.
#
# 1. Interface sounds: a switch, and no cue while another app plays. A CPH2691 user heard his
#    Bluetooth music dip in loudness and bass for about a second on opening the Audio
#    category - the length of the WebView stream each cue opens. The REAL sound block runs
#    on a fake AudioContext, a fake clock and a fake run(): dumpsys says another player has
#    started -> no cue; switched off -> no cue; the look is never taken while this page's
#    own stream could be the player counted.
# 2. Settings entrance: "the six category cards twitch every time I open Settings". The hub
#    was painted, slid in, and painted again with the loaded values - with the entrance
#    animation both times. Pinned: the entrance runs on a change of screen only, the slide-in
#    paint does not run it, and a same-screen repaint during an entrance waits for it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/webroot/index.html"
fail() { echo "FAIL webui quiet ui: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui quiet ui: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_s="$(grep -n '^let _uiAudioCtx = null;$' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '^  } catch (e) { /\* no WebAudio: stay silent \*/ }' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "sound block not found"
{ sed -n "${_s},${_e}p" "$W"; echo "}"; } > "$T/s.js"
sed -n '/^const UI_SONIC = {/,/^};/p' "$W" > "$T/u.js"
cat > "$T/run.js" <<'X'
const fs = require('fs');
let now = 0; const timers = [];
global.setTimeout = (fn, ms) => { const t = { at: now + ms / 1000, fn, live: true }; timers.push(t); return t; };
global.clearTimeout = (t) => { if (t) t.live = false; };
function advance(s) {
  const end = now + s;
  for (;;) {
    const due = timers.filter(t => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    now = due.at; due.live = false; due.fn();
  }
  now = end;
}
global.performance = { now: () => now * 1000 };
const store = {};
global.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
global.document = { hidden: false, addEventListener: () => {} };
let oscs = 0;
class FakeCtx {
  constructor() { this.state = 'running'; this.destination = {}; }
  get currentTime() { return now; }
  suspend() { this.state = 'suspended'; }
  resume() { this.state = 'running'; }
  createOscillator() { oscs++; return { frequency: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {}, start() {}, stop() {} }; }
  createGain() { return { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} }; }
}
global.window = { AudioContext: FakeCtx };
let playing = '0', looks = [];
global.run = (cmd) => { looks.push(cmd); return Promise.resolve({ stdout: playing + '\n' }); };
global._el = () => null; global.T = (k, d) => d; global.toast = () => {};
eval(fs.readFileSync(process.argv[2], 'utf8') + fs.readFileSync(process.argv[3], 'utf8') + `
(async () => {
  const flush = () => new Promise(r => setImmediate(r));
  const out = [];
  advance(2); await flush();                                    // the look taken at page open completes
  advance(18);
  uiSound('nav'); await flush();
  out.push('first=' + oscs + '/' + looks.length);           // looked at open (nothing playing) and again at the cue 15 s+ later
  advance(30);                                                  // own context suspended, cue long ago
  playing = '1';
  uiSound('nav'); await flush();
  const afterLook = oscs;
  out.push('lookedWhilePlaying=' + looks.length);
  uiSound('nav');
  out.push('mutedWhilePlaying=' + (oscs === afterLook));
  advance(20); playing = '0';
  uiSound('nav'); await flush();
  uiSound('nav');
  out.push('backAfterStop=' + (oscs > afterLook));
  // Never look while this page's own stream is the likely player.
  const n = looks.length; _uiOtherAudioAt = -1e9; uiSound('nav');
  out.push('noLookRightAfterOwnCue=' + (looks.length === n));
  // Switched off: nothing plays, the choice is stored.
  advance(30); _uiOtherAudio = false; const o = oscs;
  uiSoundToggle(); uiSound('nav');
  out.push('off=' + (oscs === o) + '/' + store.asb_ui_sound);
  uiSoundToggle();
  out.push('on=' + (oscs > o) + '/' + store.asb_ui_sound);
  out.push('cmd=' + /dumpsys audio .*state:started .*USAGE_\\(MEDIA\\|GAME/.test(looks[0]) );
  console.log(out.join(' '));
})();
`);
X
r="$(node "$T/run.js" "$T/u.js" "$T/s.js")"
printf '%s\n' "$r" | grep -q 'first=4/2' || fail "first cue: $r"
printf '%s\n' "$r" | grep -q 'lookedWhilePlaying=3' || fail "no second look after 15 s: $r"
printf '%s\n' "$r" | grep -q 'mutedWhilePlaying=true' || fail "a cue played over another app's audio: $r"
printf '%s\n' "$r" | grep -q 'backAfterStop=true' || fail "cues did not come back once playback stopped: $r"
printf '%s\n' "$r" | grep -q 'noLookRightAfterOwnCue=true' || fail "looked while its own stream could be counted: $r"
printf '%s\n' "$r" | grep -q 'off=true/0' || fail "switch off did not silence or was not stored: $r"
printf '%s\n' "$r" | grep -q 'on=true/1' || fail "switch on: $r"
grep -q 'id="cfgSoundBtn" onclick="uiSoundToggle()"' "$W" || fail "no sound switch in the settings tools row"
for f in "$ROOT"/webroot/i18n/*.json; do
  for k in ui_sound_aria ui_sound_on ui_sound_off; do grep -q "\"$k\":" "$f" || fail "$k missing in ${f##*/}"; done
done

# 2. Entrance motion only on a change of screen.
grep -q "if (_screen !== _cfgShownScreen) {" "$W" || fail "entrance not tied to a change of screen"
grep -q "^  _cfgShownScreen = 'hub';" "$W" || fail "the slide-in paint runs the entrance as well"
grep -q "(_cfgGroup || 'hub') === _cfgShownScreen && performance.now() < _cfgEnterUntil" "$W" \
  || fail "a repaint during the entrance restarts it"
_n="$(grep -c "list.classList.add('cfg-stagger');" "$W")"
[ "$_n" = 1 ] || fail "cfg-stagger added in $_n places (want exactly the screen-change one)"
echo "PASS webui quiet ui: cues switchable and quiet over other audio, entrance only on a change of screen"
)

t_webui_monitor_semantics_runtime() (
# Runtime (fix230): Monitor value colours come from each reading's own unit and state.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor semantics: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor semantics: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$H" <<'PY' || fail 'markup or semantic CSS'
import sys
h = open(sys.argv[1], encoding='utf-8').read()
for i in ('bnBasis','bnSlotTemp','bnConf','bnLpm','bnStockRam','bnStockDrain','bnStockCpuClock',
          'liveCpu','liveSkin','liveSurface','liveGpu','liveHeadroom'):
    assert "asbMetricPaint('%s'" % i in h, '%s is not semantically painted' % i
for cls in ('good','warm','bad','neutral'):
    assert '.live-cell-value.metric-' + cls in h
    assert 'html[data-asb-glass="1"] .live-cell-value.metric-' + cls in h
assert "asbThermalMetric(cpuT ? fmtTempC(cpuT) : 0, 'cpu')" in h, 'governor deci-C temperature is classified without display-unit normalization'
assert h.index('/* Every monitored value uses the same evidence vocabulary') > h.index('html[data-asb-glass="1"] .smart-banner-value { color:var(--text); }'), 'Glass neutral rules override the evidence colours'
PY
{
  echo "function T(k, d) { return d; }"
  echo "const _node = { className: 'live-cell-value cap-raised metric-good' }; function _el(id) { return id === 'x' ? _node : null; }"
  sed -n '/^const METRIC_CLASSES = /p' "$H"
  for fn in asbMetricPaint asbLoadMetric asbThermalMetric asbRamMetric asbDrainMetric asbClockMetric asbHeadroomMetric asbConfidenceMetric asbBasisMetric asbModemMetric asbSlotMetric lvSlotHeat; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function eq(actual, want, name) { chk(actual === want, name + ': ' + actual + ', want ' + want); }
eq(asbLoadMetric(34), 'metric-good', 'low load'); eq(asbLoadMetric(35), 'metric-warm', 'medium load');
eq(asbLoadMetric(70), 'metric-bad', 'high load'); eq(asbLoadMetric(null), 'metric-neutral', 'unknown load');
eq(asbThermalMetric(31, 'body'), 'metric-good', 'cool body'); eq(asbThermalMetric(32, 'body'), 'metric-warm', 'warm body');
eq(asbThermalMetric(38, 'body'), 'metric-bad', 'hot body'); eq(asbThermalMetric(44, 'board'), 'metric-warm', 'warm board');
eq(asbThermalMetric(45, 'board'), 'metric-bad', 'hot board'); eq(asbThermalMetric(64, 'cpu'), 'metric-warm', 'warm CPU');
eq(asbThermalMetric(65, 'cpu'), 'metric-bad', 'hot CPU'); eq(asbThermalMetric(0, 'cpu'), 'metric-neutral', 'unknown CPU');
eq(asbRamMetric(3500, 10000), 'metric-good', '35% RAM'); eq(asbRamMetric(1800, 10000), 'metric-warm', '18% RAM');
eq(asbRamMetric(1799, 10000), 'metric-bad', 'low RAM'); eq(asbRamMetric(0, 0), 'metric-neutral', 'unknown RAM');
eq(asbDrainMetric(-100, 5000), 'metric-good', 'charging'); eq(asbDrainMetric(0, 5000), 'metric-neutral', 'zero current');
eq(asbDrainMetric(200, 5000), 'metric-good', '4%/h current'); eq(asbDrainMetric(201, 5000), 'metric-warm', 'medium current');
eq(asbDrainMetric(601, 5000), 'metric-bad', 'high current'); eq(asbDrainMetric(100, 0), 'metric-neutral', 'current without capacity');
eq(asbClockMetric(440, 1000), 'metric-good', 'low clock'); eq(asbClockMetric(450, 1000), 'metric-warm', 'medium clock');
eq(asbClockMetric(800, 1000), 'metric-bad', 'high clock'); eq(asbClockMetric(100, 0), 'metric-neutral', 'clock without maximum');
eq(asbHeadroomMetric(20), 'metric-good', 'ample headroom'); eq(asbHeadroomMetric(10), 'metric-warm', 'limited headroom');
eq(asbHeadroomMetric(9), 'metric-bad', 'low headroom'); eq(asbHeadroomMetric(null), 'metric-neutral', 'unknown headroom');
eq(asbConfidenceMetric('high'), 'metric-good', 'high confidence'); eq(asbConfidenceMetric('med'), 'metric-warm', 'medium confidence');
eq(asbConfidenceMetric('low'), 'metric-bad', 'low confidence'); eq(asbConfidenceMetric(''), 'metric-neutral', 'unknown confidence');
eq(asbBasisMetric('stable'), 'metric-good', 'stable basis'); eq(asbBasisMetric('fallback'), 'metric-warm', 'fallback basis');
eq(asbBasisMetric('basis-veto'), 'metric-bad', 'veto basis'); eq(asbModemMetric('save'), 'metric-good', 'save modem');
eq(asbModemMetric('night'), 'metric-good', 'night modem'); eq(asbModemMetric('fast'), 'metric-bad', 'fast modem');
eq(asbModemMetric('normal'), 'metric-neutral', 'normal modem is the stock baseline'); eq(asbModemMetric(''), 'metric-neutral', 'unknown modem');
eq(asbModemMetric('unavailable'), 'metric-neutral', 'unavailable modem');
eq(asbSlotMetric('cool'), 'metric-good', 'cool slot'); eq(asbSlotMetric('typical'), 'metric-good', 'typical slot');
eq(asbSlotMetric('warm'), 'metric-warm', 'warm slot'); eq(asbSlotMetric(undefined), 'metric-neutral', 'unknown slot');
eq(lvSlotHeat(400, 410, 490).state, 'cool', 'cool slot evidence'); eq(lvSlotHeat(450, 410, 490).state, 'typical', 'typical slot evidence');
eq(lvSlotHeat(500, 410, 490).state, 'warm', 'warm slot evidence'); eq(lvSlotHeat(0, 410, 490).state, undefined, 'empty slot evidence');
asbMetricPaint('x', 'metric-warm');
chk(_node.className === 'live-cell-value cap-raised metric-warm', 'semantic repaint preserves non-semantic state and replaces the old colour: ' + _node.className);
asbMetricPaint('x', 'nonsense'); chk(/metric-neutral/.test(_node.className), 'invalid state fails neutral');
asbMetricPaint('missing', 'metric-good');
if (bad) process.exit(1); console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor semantics: unit-specific thermal/load/RAM/current/clock/headroom/confidence/modem/slot colours, neutral unknowns, all four themes"
)

t_webui_stock_monitor_runtime() (
# Runtime (fix168): on Stock the Monitor shows nine real ROM readings, never a trip point.
#
# Owner's screenshots after switching Smart -> Stock: CPU 95 C on a phone at 43 C, cells left
# as placeholders, and on a second visit almost nothing at all. The OP15 publishes
# cpu-hw-trip-0/1 as thermal zones reading a constant 95000 and the CPU filter took them; the
# page cleared its cells on open and then skipped the read as too recent. The REAL
# paintStockLive runs in node against a ROM sample shaped like the owner's phone.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui stock monitor: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui stock monitor: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -Fq "if (Object.keys(_stockTelemetryKv).length) paintStockLive(_stockTelemetryKv);" "$H" || fail "a throttled read still leaves the cells empty"
grep -Fq "    if (_selectedProfile === 'stock') pollStockTelemetry(true, true);" "$H" || fail "opening Monitor on Stock does not read a fresh sample"
grep -Fq "  if (_selectedProfile !== 'smart') paintStockLive(_stockTelemetryKv);" "$H" || fail "opening Monitor does not paint the last ROM sample"
# fix177: the read waits for the slide, and is a script of builtin reads, not a cat per value.
python3 - "$H" <<'P' || fail "Monitor open order / ROM read"
import sys
s = open(sys.argv[1], encoding='utf-8').read()
o = s[s.index('function openLivePage() {'):s.index('function closeLivePage() {')]
assert o.index("paintStockLive(_stockTelemetryKv)") < o.index('setTimeout(function () {') < o.index("pollStockTelemetry(true, true)"), 'the fresh read runs before the page has slid in'
p = s[s.index('async function pollStockTelemetry('):s.index('async function pollLive(')]
assert "'/runtime/asb_rom_telemetry.sh'" in p and 'thermal_zone' not in p and 'settings get' not in p, 'Stock still reads the ROM with an inline fork-per-value command'
assert '(now - _stockSettingsAtMs) >= 60000' in p, 'the settings client is started on every pass'
P
grep -Fq "const ownGrid = _selectedProfile === 'stock';" "$H" || fail "the ROM sample still repaints the governor's grid on other profiles"
{
  cat <<'EOF'
const _nodes = {};
function _el(id) { if (!_nodes[id]) _nodes[id] = { id: id, textContent: '', title: '', className: '', style: { display: '' }, classList: { remove() {} }, clientWidth: 0, scrollWidth: 0, appendChild(ch) { this.textContent += ch.textContent; if (!this.firstChild) this.firstChild = ch; } }; return _nodes[id]; }
const document = { createElement: function () { return { className: '', textContent: '' }; } };
function T(k, d) { return d; }
let _selectedProfile = 'stock';
let _stockRomHistory = { ts: 0, cpuT: 0 };
let _stockTrendSamples = [], _stockTrendLast = null;
let _stockCpuStatPrev = null;
/* fix210: the trend persists in localStorage - the harness fakes it and checks the save. */
const _ls = {};
const localStorage = {
  getItem: function (k) { return (k in _ls) ? _ls[k] : null; },
  setItem: function (k, v) { _ls[k] = String(v); },
  removeItem: function (k) { delete _ls[k]; }
};
function _stockTrendSave() {
  try {
    localStorage.setItem('asb_stock_trend', JSON.stringify({
      s: _stockTrendSamples.slice(-16), l: _stockTrendLast }));
  } catch (e) {}
}
const ASB_LANG = 'en';
const _stockLiveInfo = { ceil: [] };
const _lvEta = { cap: 0, chg: false, gov: null };
function lvTopSecSync() {} function lvDrainHome() {} function lvTopSec() {} function lvMeterPaint() {}
EOF
  sed -n '/^const METRIC_CLASSES = /p' "$H"
  for fn in fmtTempC setLiveLabel fmtStockLoad lvLoadShare asbMetricPaint asbThermalMetric asbLoadMetric asbDrainMetric asbRamMetric asbClockMetric paintStockLive; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const kv = {
  ts: '1760000000', uptime: '5400.2', loadavg: '6.12 5.80 5.10',
  'battery.capacity': '88', 'battery.current_now': '412000', 'battery.voltage_now': '4210000',
  'battery.temp': '331', 'battery.status': 'Discharging', 'battery.charge_full': '5300000',
  MemTotal: '8388608 kB', MemAvailable: '5242880 kB', SwapTotal: '8388604 kB', SwapFree: '5420000 kB',
  'cpu.policy0.scaling_cur_freq': '1785600', 'cpu.policy0.scaling_max_freq': '3628800', 'cpu.policy0.cpuinfo_max_freq': '3628800',
  'cpu.policy6.scaling_cur_freq': '1132800', 'cpu.policy6.scaling_max_freq': '1632000', 'cpu.policy6.cpuinfo_max_freq': '4608000',
  'gpu.gpuclk': '220000000', 'gpu.gpu_busy_percentage': '12 %',
  'thermal.cpu-1-1-0': '43000', 'thermal.cpu-1-1-1': '44500',
  'thermal.cpu-hw-trip-0': '95000', 'thermal.cpu-hw-trip-1': '95000', 'thermal.pmh0101-bcl-lvl0': '96000',
  'thermal.shell_frame': '29600', 'thermal.shell_back': '29700', 'thermal.board_temp': '41800',
  'thermal.gpuss-0': '43200', 'thermal.ddr': '44000'
};
paintStockLive(kv);
const v = (id) => _nodes[id] ? _nodes[id].textContent : '';
chk(v('liveCpu') === '45°C', 'CPU from the core zones, not the 95 C trip point: ' + v('liveCpu'));
chk(v('liveSkin') === '30°C', 'shell: ' + v('liveSkin'));
chk(v('liveSurface') === '42°C' && v('liveSurfaceLabel') === 'Board', 'board sensor: ' + v('liveSurface') + ' / ' + v('liveSurfaceLabel'));
chk(v('liveState') === '35%' && /cap-raised/.test(_nodes.liveState.className) && v('liveStateLabel') === 'CPU ceiling', 'CPU ceiling on the most limited cluster: ' + v('liveState'));
chk(_stockLiveInfo.ceil.length === 2 && _stockLiveInfo.ceil[1] === 'policy6: 1.63 / 4.61 GHz', 'ceiling lines for the sheet: ' + JSON.stringify(_stockLiveInfo.ceil));
chk(v('liveGpu') === '12%' && v('liveHeadroom') === '220 MHz', 'GPU load and clock: ' + v('liveGpu') + ' / ' + v('liveHeadroom'));
chk(/metric-warm/.test(_nodes.liveCpu.className) && /metric-good/.test(_nodes.liveSkin.className) && /metric-good/.test(_nodes.liveGpu.className), '45°C CPU is amber while cool body and low GPU load are green: ' + _nodes.liveCpu.className + ' / ' + _nodes.liveSkin.className + ' / ' + _nodes.liveGpu.className);
chk(/metric-warm/.test(_nodes.liveSurface.className), 'warm board is amber: ' + _nodes.liveSurface.className);
chk(/metric-warm/.test(_nodes.bnStockDrain.className), '7.8%/h battery current is amber: ' + _nodes.bnStockDrain.className);
chk(/metric-good/.test(_nodes.bnStockRam.className), '62.5% available RAM is green: ' + _nodes.bnStockRam.className);
chk(/metric-warm/.test(_nodes.bnStockCpuClock.className), '49% CPU clock is amber: ' + _nodes.bnStockCpuClock.className);
chk(/metric-neutral/.test(_nodes.liveHeadroom.className) && /metric-neutral/.test(_nodes.bnStockLpm.className), 'GPU clock without a ceiling and unknown modem state stay neutral');
chk(v('liveCapSrc') === '33°C' && v('liveCapSrcLabel') === 'Battery temp', 'battery temperature: ' + v('liveCapSrc'));
chk(v('liveClamp') === '2.8 GB' && v('liveClampLabel') === 'zRAM used', 'zRAM in use: ' + v('liveClamp'));
chk(v('liveLearner') === 'paused' && v('liveLearnerLabel') === 'Smart learning', 'learner: ' + v('liveLearner'));
chk(v('bnStockLoad') === '6.12', 'system load is a number, not "1 min 6.12": ' + v('bnStockLoad'));
/* fix214: the inline percentage is the REAL busy share between two /proc/stat reads, not
 * the load-average share (which counts storage waits and reads past 100% on an idle
 * phone). First read: no percentage yet. Second read: the delta. A repaint of the same
 * read keeps the figure instead of blanking it. */
_stockCpuStatPrev = null;
paintStockLive(Object.assign({}, kv, { tsms: '1760000100000', cpustat: '1000 0 500 7800 200 100 50 350', cpus_online: '8', loadavg: '9.40 8.00 7.00' }));
chk(v('bnStockLoad') === '9.40', 'no busy share before the second reading: ' + v('bnStockLoad'));
paintStockLive(Object.assign({}, kv, { tsms: '1760000110000', cpustat: '1100 0 550 8580 210 110 55 385', cpus_online: '8', loadavg: '9.40 8.00 7.00' }));
/* total +990, idle +790 -> busy 20% */
chk(v('bnStockLoad') === '9.4 · 20%', 'the busy share beside the load: ' + v('bnStockLoad'));
chk(/CPU actually busy: 20 % over the last 10 s/.test(_nodes.bnStockLoad.title), 'the busy share is captioned: ' + _nodes.bnStockLoad.title);
chk(/of 8 cores/.test(_nodes.bnStockLoad.title), 'the loadavg share moved to the tooltip: ' + _nodes.bnStockLoad.title);
paintStockLive(Object.assign({}, kv, { tsms: '1760000110000', cpustat: '1100 0 550 8580 210 110 55 385', cpus_online: '8', loadavg: '9.40 8.00 7.00' }));
chk(v('bnStockLoad') === '9.4 · 20%', 'a repaint of the same reading keeps the busy share: ' + v('bnStockLoad'));
_stockCpuStatPrev = null;
_stockTrendSamples = []; _stockTrendLast = null;   /* keep the trend checks below isolated */
paintStockLive(kv);   /* one fresh sample again - the tile is back to "measuring" */
/* fix177: the thermal trend over a window, kept between reads. One sample: measuring, not a
 * dash. A repaint of the same sample keeps the verdict; 40 s of a warming CPU says warming. */
chk(v('bnStockTrend') === '\u2026', 'first sample says it is measuring: ' + v('bnStockTrend'));
const at = (ms, c) => Object.assign({}, kv, { tsms: String(ms), 'thermal.cpu-1-1-0': String(c * 1000), 'thermal.cpu-1-1-1': String(c * 1000) });
_stockTrendSamples = []; _stockTrendLast = null;
paintStockLive(at(1000000, 40)); paintStockLive(at(1010000, 40.5)); paintStockLive(at(1020000, 41)); paintStockLive(at(1040000, 42));
chk(v('bnStockTrend') === '\u2191 warming' && /cap-clamp/.test(_nodes.bnStockTrend.className), 'warming over 40 s: ' + v('bnStockTrend'));
chk(/per minute over the last 40 s/.test(_nodes.bnStockTrend.title), 'rate in the sheet source: ' + _nodes.bnStockTrend.title);
chk(_ls.asb_stock_trend && JSON.parse(_ls.asb_stock_trend).s.length === 4, 'the trend persists across a page reload (fix210): ' + _ls.asb_stock_trend);
paintStockLive(at(1040000, 42));
chk(v('bnStockTrend') === '\u2191 warming', 'a repaint of the same sample shows a dash again: ' + v('bnStockTrend'));
/* A one-core spike between steady samples does not flip it. */
_stockTrendSamples = []; _stockTrendLast = null;
[0, 10, 20, 30, 40].forEach(function (s2) { paintStockLive(Object.assign(at(2000000 + s2 * 1000, 41), s2 === 20 ? { 'thermal.cpu-1-1-1': '49000' } : {})); });
chk(v('bnStockTrend') === '\u2192 steady', 'a single-core spike flipped the trend: ' + v('bnStockTrend'));
chk(_nodes.bnStockLpm.title === 'mobile_data_always_on: \u2014' && _nodes.bnStockCpuClock.title.indexOf('policy6: 1.13 GHz') >= 0, 'Stock sheet sources: ' + _nodes.bnStockLpm.title + ' / ' + _nodes.bnStockCpuClock.title);
const tripOnly = { 'thermal.cpu-hw-trip-0': '95000', 'thermal.cpu-hw-trip-1': '95000', 'thermal.socd': '8' };
paintStockLive(tripOnly);
chk(v('liveCpu') === '—' && v('liveSurface') === '—', 'trip zones and the socd level are not temperatures: ' + v('liveCpu') + ' / ' + v('liveSurface'));
chk(/metric-neutral/.test(_nodes.liveCpu.className) && /metric-neutral/.test(_nodes.liveSurface.className) && /metric-neutral/.test(_nodes.liveGpu.className), 'unknown thermal/GPU readings are not painted green');
chk(/metric-neutral/.test(_nodes.bnStockDrain.className) && /metric-neutral/.test(_nodes.bnStockRam.className) && /metric-neutral/.test(_nodes.bnStockCpuClock.className), 'unknown Stock banner values stay neutral');
_selectedProfile = 'battery';
_nodes.liveCpu.textContent = '39°C'; _nodes.liveStateLabel.textContent = 'FSM';
paintStockLive(kv);
chk(v('liveCpu') === '39°C' && v('liveStateLabel') === 'FSM', 'on Battery the governor keeps its own grid');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui stock monitor: nine ROM readings on Stock, trip points and alarm zones never read as a temperature, last sample painted on every visit"
)

t_rom_telemetry_runtime() (
# Runtime (fix177): the Stock Monitor's ROM snapshot is builtin reads, in the format the page
# parses, and never reads a trip zone or starts the settings client in the foreground.
#
# "Monitor opens slowly on Stock": the inline command forked two cats per thermal zone (100+
# zones on an OP15) and ran `settings get` every 10 s, inside a root call that blocks the page.
# The REAL script runs against a fake /sys and /proc; `settings` is a stub that records calls.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
R="$ROOT/runtime/asb_rom_telemetry.sh"
fail() { echo "FAIL rom telemetry: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/class/power_supply/battery" "$T/sys/devices/system/cpu/cpufreq/policy0" "$T/proc" "$T/bin"
for z in 0 1 2 3; do mkdir -p "$T/sys/class/thermal/thermal_zone$z"; done
echo 77 > "$T/sys/class/power_supply/battery/capacity"; echo 412000 > "$T/sys/class/power_supply/battery/current_now"
echo 1996800 > "$T/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
echo cpu-1-1-0 > "$T/sys/class/thermal/thermal_zone0/type"; echo 41200 > "$T/sys/class/thermal/thermal_zone0/temp"
echo cpu-hw-trip-0 > "$T/sys/class/thermal/thermal_zone1/type"; echo 95000 > "$T/sys/class/thermal/thermal_zone1/temp"
echo pm8550_tz > "$T/sys/class/thermal/thermal_zone2/type"; echo 30000 > "$T/sys/class/thermal/thermal_zone2/temp"
printf 'shell_back' > "$T/sys/class/thermal/thermal_zone3/type"; printf '29700' > "$T/sys/class/thermal/thermal_zone3/temp"
printf '1234.5 999.1\n' > "$T/proc/uptime"; printf '1.50 2.00 3.00 1/200 33\n' > "$T/proc/loadavg"
printf 'MemTotal:  12000000 kB\nMemAvailable:   5000000 kB\nBuffers: 1 kB\n' > "$T/proc/meminfo"
printf '#!/bin/sh\necho "$*" >> "%s/settings.log"\necho 1\n' "$T" > "$T/bin/settings"; chmod +x "$T/bin/settings"
run() { PATH="$T/bin:$PATH" ASB_ROM_TEL_CACHE="$T/mdao" ASB_ROM_TEL_SYS="$T/sys" ASB_ROM_TEL_PROC="$T/proc" sh "$R" "$@"; }
out="$(run)"
for want in 'uptime=1234.5' 'loadavg=1.50 2.00 3.00' 'battery.capacity=77' 'battery.current_now=412000' \
            'cpu.policy0.scaling_max_freq=1996800' 'thermal.cpu-1-1-0=41200' 'thermal.shell_back=29700' \
            'MemAvailable: 5000000 kB' 'settings.global.mobile_data_always_on='; do
  printf '%s\n' "$out" | grep -qxF "$want" || fail "missing line [$want] in: $out"
done
printf '%s\n' "$out" | grep -q 'trip\|pm8550' && fail "a trip point or an unshown zone was read: $out"
[ -e "$T/settings.log" ] && fail "the settings client ran without refresh"
run refresh >/dev/null
i=0; while [ ! -s "$T/mdao" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(cat "$T/mdao" 2>/dev/null)" = 1 ] || fail "the background refresh did not fill the cache"
printf '%s\n' "$(run)" | grep -qx 'settings.global.mobile_data_always_on=1' || fail "the cached value is not printed"
# Builtins only: no cat, no date, no grep in the foreground part.
sed -n '/^_r() {/,$p' "$R" | grep -vE '^[[:space:]]*#' | grep -v 'nohup sh -c' | grep -qE '\$\((cat|date|grep|head|cut) ' \
  && fail "the snapshot forks a reader again"
echo "PASS rom telemetry: the Stock snapshot is builtin reads of the zones the Monitor shows, the settings value comes from a background cache"
)

t_webui_live_info_runtime() (
# Runtime (fix168): every live tile opens an explanation in the UI language.
#
# Owner's request: a tap on any of the nine Monitor readings shows what it is and how to read
# it, in every language. Stock swaps five tiles for ROM readings, so it has its own five texts.
# fix172 extended the same sheet to the eight Smart-banner readings (slot, confidence, lean,
# load, basis, heat, trend, LPM); fix174 stops the weekday pill from gluing itself onto the
# slot value. The REAL liveInfoOpen runs in node against stub cells.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui live info: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui live info: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT" <<'P' || fail "texts"
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
s = (root / 'webroot' / 'index.html').read_text(encoding='utf-8')
lvi = s[s.index('const LVI_TEXT = {'):s.index('function lviFill(t) {')]
pairs = dict(re.findall(r"^  (\w+): \['(lvi_\w+)', ", lvi, re.M))
stock = dict(re.findall(r"(\w+): '(\w+)'", s[s.index('const LVI_STOCK = {'):].split('\n', 1)[0]))
cells = re.findall(r'<div class="live-cell" data-lvi="([a-z]+)">', s)
assert len(cells) == 9 and len(set(cells)) == 9, cells
for c in cells:
    assert c in pairs, "tile %s has no explanation" % c
banner = re.findall(r'<div class="smart-banner-item" data-lvi="([a-z]+)">', s)
# fix177: the eight Stock-banner readings open the sheet too.
assert len(banner) == 16 and len(set(banner)) == 16, banner
for b in banner:
    assert b in pairs, "banner reading %s has no explanation" % b
for pos, key in stock.items():
    assert pos in cells and key in pairs, "Stock tile %s -> %s has no explanation" % (pos, key)
assert len(stock) == 5, stock
en = json.loads((root / 'webroot' / 'i18n' / 'en.json').read_text(encoding='utf-8'))
for name, key in pairs.items():
    fb = re.search(r"%s: \['%s', '((?:[^'\\]|\\.)*)'\]" % (name, key), lvi).group(1)
    fb = re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), fb)
    assert en.get(key) == fb, "en.json %s differs from the page fallback" % key
files = sorted((root / 'webroot' / 'i18n').glob('*.json'))
assert len(files) == 13
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for key in list(pairs.values()) + ['lvi_now', 'lvi_source', 'lvi_dwell']:
        assert isinstance(d.get(key), str) and d[key].strip(), "%s lacks %s" % (p.name, key)
    assert '%s' in d['lvi_dwell'], "%s: lvi_dwell lost its %%s" % p.name
    if p.name != 'en.json':
        same = [k for k in pairs.values() if d[k] == en[k]]
        assert not same, "%s: untranslated %s" % (p.name, same)
    # fix177: a text names the words its tile shows through the tile's own strings - the same
    # placeholders in every language, and no English value list left behind.
    for k in pairs.values():
        assert sorted(set(re.findall(r'\{[a-z0-9]+\}', d[k]))) == sorted(set(re.findall(r'\{[a-z0-9]+\}', en[k]))), \
            "%s: %s placeholders differ" % (p.name, k)
    for k, bad in (('lvi_apphint', 'idle, light'), ('lvi_lpm', 'normal follows'), ('lvi_slot', 'two-hour'),
                   ('lvi_trend', 'warming, steady'), ('lvi_slotheat', 'cool, normal or warm')):
        assert bad not in d[k], "%s: %s still lists the English values" % (p.name, k)
    for k in ('lvi_usual', 'lvi_cpu_now', 'lvi_trend_rate', 'lv_lpm_night', 'lv_lpm_night_t'):
        assert d.get(k), "%s lacks %s" % (p.name, k)
fills = set(re.findall(r"\{([a-z0-9]+)\}", ' '.join(en[k] for k in pairs.values())))
lf = s[s.index('function lviFill(t) {'):s.index('const LVI_STOCK')]
for f in fills:
    assert ("%s:" % f) in lf or re.sub(r'\d+$', '', f) in ('dp', 'app', 'fb'), "placeholder {%s} is never filled" % f
P
{
  cat <<'EOF'
const _nodes = {};
function mk(id) { const e = { id: id, textContent: '', className: '', hidden: true, title: '', style: {}, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, querySelector() { return null; } }; _nodes[id] = e; return e; }
function _el(id) { return _nodes[id] || null; }
function T(k, d) { return d; }
function uiSound() {} function navSyncSoon() {}
let _selectedProfile = 'smart';
const _stockLiveInfo = { ceil: ['policy6: 1.63 / 4.61 GHz'] };
const _lvLast = { st: { thermal_cpu_type: 'cpu-1-1-1' }, kv: { dwell_sec: '210', cpu_max_live: '3628800,1862400' } };
function liveInfoEnsure() { if (_nodes.liveInfoSheet) return _nodes.liveInfoSheet; ['liveInfoTitle', 'liveInfoNowLbl', 'liveInfoVal', 'liveInfoText', 'liveInfoSrc', 'liveInfoDone'].forEach(mk); return mk('liveInfoSheet'); }
function cell(pos, label, value, cls, title) {
  const l = { textContent: label }, v = { textContent: value, className: 'live-cell-value' + (cls ? ' ' + cls : ''), title: title || '' };
  return { getAttribute() { return pos; }, querySelector(q) { return q === '.live-cell-label' ? l : v; } };
}
function bcell(pos, label, value, cls, title, pill) {
  /* With a pill badge the real span reads "value"+"pill" through textContent, exactly
   * like the DOM the banner builder produces. */
  const l = { textContent: label }, v = { textContent: value + (pill || ''), className: 'smart-banner-value' + (cls ? ' ' + cls : ''), title: title || '' };
  if (pill) v.childNodes = [ { nodeType: 3, textContent: value }, { nodeType: 1, textContent: pill } ];
  return { getAttribute() { return pos; }, querySelector(q) {
    if (q === '.smart-banner-label') return l;
    if (q === '.smart-banner-value') return v;
    return null;
  } };
}
EOF
  sed -n "/^const LVI_TEXT = {/,/^};/p; /^const LVI_STOCK = /p" "$H"
  for fn in lviFill liveInfoSource liveInfoValText liveInfoOpen liveInfoClose; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
liveInfoOpen(cell('cpu', 'CPU', '41°C'));
chk(_nodes.liveInfoTitle.textContent === 'CPU' && _nodes.liveInfoVal.textContent === '41°C', 'title and value from the tile');
chk(_nodes.liveInfoText.textContent.indexOf('CPU cores') >= 0, 'CPU explanation');
chk(_nodes.liveInfoSrc.textContent === 'Source: cpu-1-1-1' && !_nodes.liveInfoSrc.hidden, 'CPU source zone: ' + _nodes.liveInfoSrc.textContent);
chk(!_nodes.liveInfoSheet.hidden, 'sheet opens');
liveInfoClose();
chk(_nodes.liveInfoSheet.hidden, 'sheet closes');
liveInfoOpen(cell('fsm', 'FSM', 'MODERATE'));
chk(_nodes.liveInfoSrc.textContent === 'in this state for 210 s', 'FSM dwell: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('headroom', 'Headroom', '40%'));
chk(_nodes.liveInfoSrc.textContent === '3.63 · 1.86 GHz', 'live ceilings: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('capsrc', 'Cap Src', 'ASB', 'cap-asb', 'owner=asb\nASB holds the ceiling'));
chk(_nodes.liveInfoVal.className === 'live-info-val cap-asb', 'value keeps the tile colour: ' + _nodes.liveInfoVal.className);
chk(_nodes.liveInfoSrc.textContent === 'ASB holds the ceiling', 'tile tooltip without raw key=value lines: ' + _nodes.liveInfoSrc.textContent);
_selectedProfile = 'stock';
liveInfoOpen(cell('fsm', 'CPU ceiling', '35%', 'cap-raised'));
chk(_nodes.liveInfoText.textContent.indexOf('In Stock ASB sets no ceilings') >= 0, 'Stock explains the ROM ceiling, not the FSM');
chk(_nodes.liveInfoSrc.textContent === 'policy6: 1.63 / 4.61 GHz', 'Stock ceiling per cluster: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(cell('cpu', 'CPU', '45°C'));
chk(_nodes.liveInfoSrc.hidden, 'Stock shows no governor sensor name');
liveInfoOpen(cell('learner', 'Smart learning', 'paused'));
chk(_nodes.liveInfoText.textContent.indexOf('neither learns nor decides') >= 0, 'Stock learner text');
_selectedProfile = 'smart';
/* The eight Smart-banner readings open the same sheet: label and value come from the
 * banner's own span classes, and the value keeps its colour. */
liveInfoOpen(bcell('lpm', 'Modem LPM', 'save', 'cap-raised'));
chk(_nodes.liveInfoTitle.textContent === 'Modem LPM', 'banner item title: ' + _nodes.liveInfoTitle.textContent);
chk(_nodes.liveInfoVal.textContent === 'save', 'banner item value: ' + _nodes.liveInfoVal.textContent);
chk(_nodes.liveInfoVal.className === 'live-info-val cap-raised', 'banner value keeps its colour: ' + _nodes.liveInfoVal.className);
chk(_nodes.liveInfoText.textContent.indexOf('power mode') >= 0, 'LPM explanation: ' + _nodes.liveInfoText.textContent);
chk(!_nodes.liveInfoSheet.hidden, 'sheet opens from a banner item');
/* The slot value carries the weekday/weekend pill as a child element; the sheet must
 * show the slot name alone (the fix174 "вечервых" report). */
liveInfoOpen(bcell('slot', 'Слот', 'вечер', '', '#9 · вечер · вых', 'вых'));
chk(_nodes.liveInfoVal.textContent === 'вечер', 'pill badge is not glued onto the value: ' + _nodes.liveInfoVal.textContent);
chk(_nodes.liveInfoText.textContent.indexOf('six parts - sleep 0–6') >= 0 && _nodes.liveInfoText.textContent.indexOf('{') < 0,
  'slot explanation names the real day parts: ' + _nodes.liveInfoText.textContent);
liveInfoOpen(bcell('slot', 'Slot', 'morning'));
chk(_nodes.liveInfoVal.textContent === 'morning', 'slot without a pill still reads whole: ' + _nodes.liveInfoVal.textContent);
liveInfoOpen(bcell('trend', 'Trend', '↑ warming', 'cap-clamp'));
chk(_nodes.liveInfoText.textContent.indexOf('“warming”, “steady” or “cooling”') >= 0, 'trend explanation uses the tile words: ' + _nodes.liveInfoText.textContent);
liveInfoOpen(bcell('apphint', 'Load', 'medium'));
chk(_nodes.liveInfoText.textContent.indexOf('“idle”, “light”, “medium”, “heavy” or “gaming”') >= 0, 'load words: ' + _nodes.liveInfoText.textContent);
/* fix177: the sheet value takes the colour the tile is drawn in. */
globalThis.getComputedStyle = function (el) { return { color: el.className.indexOf('cap-raised') >= 0 ? 'rgb(52, 211, 153)' : (el.className.indexOf('heat-warm') >= 0 ? 'rgb(245, 194, 107)' : 'rgb(255, 255, 255)') }; };
_nodes.liveInfoVal.style = {};
liveInfoOpen(bcell('trend', 'Trend', '↓ cooling', 'cap-raised'));
chk(_nodes.liveInfoVal.style.color === 'rgb(52, 211, 153)', 'cooling keeps the tile green: ' + _nodes.liveInfoVal.style.color);
mk('liveCpu').textContent = '41°C';
liveInfoOpen(bcell('slotheat', 'Slot heat', 'warm', 'heat-warm', 'Typical CPU peak in this slot: 51.8°C; this phone’s norm: 41–49°C'));
chk(_nodes.liveInfoVal.style.color === 'rgb(245, 194, 107)', 'warm keeps the tile amber: ' + _nodes.liveInfoVal.style.color);
chk(_nodes.liveInfoNowLbl.textContent === 'Usually in this slot', 'slot heat is not labelled "Now": ' + _nodes.liveInfoNowLbl.textContent);
chk(_nodes.liveInfoSrc.textContent.indexOf('CPU now: 41°C') >= 0, 'the CPU temperature now stands beside the usual heat: ' + _nodes.liveInfoSrc.textContent);
/* The Stock banner readings explain themselves. */
_selectedProfile = 'stock';
liveInfoOpen(bcell('strend', 'Thermal trend', '\u2026', '', '+0.4 °C per minute over the last 40 s'));
chk(_nodes.liveInfoText.textContent.indexOf('In Stock nothing in ASB') >= 0, 'Stock trend text: ' + _nodes.liveInfoText.textContent);
chk(_nodes.liveInfoSrc.textContent === '+0.4 °C per minute over the last 40 s', 'Stock trend source: ' + _nodes.liveInfoSrc.textContent);
liveInfoOpen(bcell('slpm', 'Modem state', 'normal', '', 'mobile_data_always_on: 0'));
chk(_nodes.liveInfoText.textContent.indexOf('“fast” - kept up') >= 0 && _nodes.liveInfoSrc.textContent === 'mobile_data_always_on: 0', 'Stock modem: ' + _nodes.liveInfoSrc.textContent);
_selectedProfile = 'smart';
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "e.target.closest('.live-cell[data-lvi], .smart-banner-item[data-lvi]');" "$H" || fail "tiles and banner readings are not tappable"
grep -Fq "html[dir=\"rtl\"] .live-page .smart-banner-item[data-lvi]::after { content: '\\2039'; }" "$H" || fail "the banner chevron does not mirror in Arabic"
grep -Fq "html[dir=\"rtl\"] .live-page .live-cell[data-lvi]::after { content: '\\2039'; }" "$H" || fail "the tile chevron does not mirror in Arabic"
grep -Fq 'function liveInfoValText(val)' "$H" || fail "the sheet has no pill-safe value reader"
echo "PASS webui live info: all nine tiles, the eight Smart-banner and the eight Stock-banner readings explain themselves in the tile's own words and colour, the pill never glues onto the value, every language translated"
)

t_webui_fill_pages_runtime() (
# Runtime (fix168): Home and Settings fill the screen the way Monitor does, at any density.
#
# Owner's request: Home and Settings looked empty next to Monitor; bigger, richer profile cards
# and category tiles that look right on screens of different DPI. The free height is measured
# and shared out within limits, so a short screen scrolls and a tall one stops before the
# cards look stretched. fix203: the compaction tiers decide from the page's NATURAL height -
# the fitted card heights are zeroed for the measurement, the floating bar's reserved padding
# is not counted as overflow, a fixed overlay is unclamped for the measurement, and an
# overflow within a fifth of the screen just scrolls (fix201) instead of squeezing the
# chrome over a void. fix205: the log report and an open tweak category never take a tier -
# the tiers style the header/cards/tiles/cells only, so on those long-list surfaces they
# would squash the header and buy nothing. The REAL asbFitPages runs in node against
# measured boxes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui fill pages: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui fill pages: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT" <<'P' || fail "markup"
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
s = (root / 'webroot' / 'index.html').read_text(encoding='utf-8')
assert re.findall(r'<div class="pmeta" data-meter="(\w+)" hidden></div>', s) == ['smart', 'performance', 'balanced', 'battery', 'stock'], "a profile card lacks its measured drain"
for k in ('prof_performance_desc', 'prof_balanced_desc', 'prof_battery_desc'):
    assert ('class="pdesc" data-i18n="%s"' % k) in s, "%s card has no description" % k
assert re.search(r'\.pbtn \{[^}]*min-height: var\(--pbtn-h', s) and re.search(r'\.cfg-tile \{[^}]*min-height: var\(--cfg-tile-h', s), "cards do not take the fitted height"
# fix174-175: the six hub categories carry a tint of their own hue so they lift off the
# neutral restart row, and the nine Monitor tiles are filled a notch stronger.
# fix193: the tint became one --cat token per category (tile, icon pill, heading and
# toast cannot drift). fix195: the cards dropped the #07090b base that read as grey
# slabs next to Monitor's cells - the fix192 three-stop hue gradient is back, the tweak
# rows wear the Monitor cell material, and the selected segment option wears the pill.
assert re.search(r'\.cfg-tile \{[^}]*color-mix\(in srgb, var\(--cat, var\(--accent\)\) 17%', s), "hub tiles lost their deep category gradient"
_strip = lambda b: re.sub(r'/\*.*?\*/', '', b, flags=re.S)
assert '#07090b' not in _strip(re.search(r'\.cfg-tile \{([^}]*)\}', s).group(1)), "the grey slab base is back on hub tiles"
assert '#07090b' not in _strip(re.search(r'\.cfg-row \{([^}]*)\}', s).group(1)), "the grey slab base is back on tweak cards"
assert 'linear-gradient(160deg, rgba(255,255,255,0.045), rgba(255,255,255,0.018))' in s, "tweak cards lost the Monitor cell material"
assert 'color-mix(in srgb, var(--cat) 13%, #ffffff)' in s, "light hub tiles lost their category tint"
for _cat in ('audio', 'camera', 'battery', 'ux', 'net', 'iface'):
    assert re.search(r'\.cfg-tile\.cat-%s\s*\{ --cat: #[0-9a-f]{6}; \}' % _cat, s), 'category %s lost its hue token' % _cat
assert '.cfg-row.is-on .cfg-icon[class*="cat-"]' in s, "active tweak icons lost the category pill"
# fix217: an enabled tweak card lights up like its hub tile - the row carries its
# cat-* class, shares the hue map with the icon and wears the same gradient and glow.
assert "row.className = 'cfg-row ' + cfgCatClass(it.key) + (isOn ? ' is-on' : '');" in s, "tweak rows no longer carry their category class"
assert ':is(.cfg-icon,.cfg-row).cat-audio' in s and ':is(.cfg-icon,.cfg-row).cat-system' in s, "the category hue map does not feed tweak rows"
oncard = re.search(r'\.cfg-row\.is-on\[class\*="cat-"\] \{([^}]*)\}', s)
assert oncard and 'color-mix(in srgb, var(--cat, var(--accent)) 17%, transparent) 0%' in oncard.group(1), "enabled tweak cards lost the hub-tile gradient"
assert oncard and 'box-shadow: inset 0 1px 0 rgba(255,255,255,0.06), 0 4px 16px -8px color-mix(in srgb, var(--cat, var(--accent)) 55%, transparent);' in oncard.group(1), "enabled tweak cards lost the category glow"
lon = re.search(r'html\[data-asb-theme="light"\] \.cfg-row\.is-on\[class\*="cat-"\] \{([^}]*)\}', s, re.S)
assert lon and 'color-mix(in srgb, var(--cat) 13%, #ffffff) 0%' in lon.group(1), "light enabled cards lost the hub-tile tint"
assert re.search(r'html\[data-asb-theme="light"\] \.cfg-row\.cat-audio\s*\{ --cat:#c0362c; \}', s), "light tweak rows lost the deepened hues"
assert re.search(r'\.cfg-seg button\.on \{[^}]*var\(--pill-wash\)', s), "the selected segment option is not the bar's pill"
assert 'background: linear-gradient(135deg, rgba(255,255,255,0.065), rgba(255,255,255,0.024));' in s, "Monitor tiles lost their stronger fill"
prim = re.search(r'\.cfg-profile-primary \{([^}]*)\}', s).group(1)
assert 'background:linear-gradient(135deg,#2cd6ad,#67e4c8)' not in prim, "the poisonous green slab is back on the sheet button"
assert 'rgba(44,214,173,.16)' in prim and 'border:1px solid rgba(44,214,173,.34)' in prim, "sheet button lost its tonal dark style"
assert '.cfg-profile-primary:active' in s, "sheet button has no pressed state"
assert 'html[data-asb-theme="light"] :is(.cfg-profile-primary,.cfg-profile-apply)' in s, "light tonal primary rule is missing"
assert "'cfg-tile-desc'" in s and "'cfg-tile-bar'" in s, "category tiles lack their description and fill bar"
assert "sub.className = 'smart-banner-pill' + (we ? ' we' : '');" in s, "weekday/weekend is still glued to the slot name"
assert "html[data-asb-font=\"device\"] { --sans: 'ASB Device', sans-serif; --mono: 'ASB Device', sans-serif; }" in s, "no device-font switch"
assert "'px @ '" not in s and "document.documentElement.dataset.asbUi = w + 'px@' + scale;" in s, "the scale reading is still glued to the device line"
# fix202: the shrink direction. Two compaction tiers on <html>, raised only while the
# visible page measures past its viewport, with the card/tile floors stepping down; the
# page opens report their size so the check runs on every screen change.
for t in ('html.asb-fit-c1', 'html.asb-fit-c2'):
    assert t + ' { --page-top:' in s, t + ' does not tighten the top gap'
    assert t + ' .logo-c {' in s and t + ' .pbtn {' in s and t + ' .pbtn .pico {' in s, t + ' does not compact the header and the profile cards'
    assert t + ' .live-cell {' in s and t + ' .tg-link-wrap {' in s, t + ' does not compact the Monitor cells and the support rail'
    assert t + ' .cfg-tile {' in s, t + ' does not compact the Settings tiles'
assert "classList.toggle('asb-fit-c1'" in s and "classList.toggle('asb-fit-c2'" in s, "the fit never raises a compaction tier"
assert '[68, 58, 48][tier]' in s and '[104, 92, 80][tier]' in s, "the card/tile floors do not step down with the tier"
assert 'asbFitPages._tier' in s, "the tier is not remembered between passes"
# fix203: the tier decision reads the page as it asks to be - the fitted heights are zeroed
# for the measurement, the floating bar's reserved padding is out of the reading, a fixed
# overlay is unclamped for the measurement (its scrollHeight never reads below its own
# clientHeight), and a small overflow just scrolls (fix201) instead of compacting the
# chrome over a void.
assert 'const need = Math.max(56, Math.round(' in s, "a small overflow must keep the look and scroll, not compact"
assert "root.style.setProperty('--pbtn-h', '0px');" in s and "root.style.setProperty('--cfg-tile-h', '0px');" in s, "the tier is not decided from the page's natural height"
assert "st.bottom = 'auto'; st.height = 'auto';" in s, "a fixed overlay is still measured through its clamped scrollHeight"
assert 'over2 > need - 8' in s, "a tier comes off without hysteresis"
assert 'getComputedStyle(el).paddingBottom' in s, "the bar's reserved padding is still counted as overflow"
for fn in ('openLivePage', 'closeLivePage', 'closeConfigPage', 'cfgBack', 'openReportPage', 'closeReportPage', 'asbLogReportLoad'):
    m = re.search(r'(?:async )?function %s\s*\([^)]*\)\s*\{(.*?)\n\}' % fn, s, re.S)
    assert m, fn + ' is missing'
    assert 'requestAnimationFrame(asbFitPages)' in m.group(1), fn + ' never re-measures the fit'
files = sorted((root / 'webroot' / 'i18n').glob('*.json'))
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for k in ('prof_performance_desc', 'prof_balanced_desc', 'prof_battery_desc') + tuple('grp_%s_desc' % g for g in ('audio', 'camera', 'iface', 'net', 'battery', 'ui')):
        assert isinstance(d.get(k), str) and d[k].strip(), "%s lacks %s" % (p.name, k)
P
{
  cat <<'EOF'
let _cfgGroup = null;
const props = {};
const fitCls = new Set();
/* fix203: the mock measures like a browser - the fit reads the content's own bottom edge
 * against the floating bar's top (the fit line sits 20 px above it), each compaction tier
 * buys back 80 px of content height, and a fixed overlay reports its unclamped content
 * bottom while the measurement holds its box at bottom/height:auto (a real overlay's
 * scrollHeight never reads below its own clientHeight). The allowance is generous: a
 * fifth of the screen, so a page that only runs a little past the line keeps its look
 * and scrolls. */
let homeBase = 1022, cfgBase = 1100, clientH = 1900, barTop = 1700;
let profTop = 600, hubTop = 760, live = false, cfgOpen = false;
/* fix205: the log report is the scroll surface - a long list by design. The tiers style
 * the header/cards/tiles/cells only, so they must never go on there (nor inside an open
 * tweak category): they would squash the header and buy nothing. */
let reportOpen = false, reportBase = 3000;
function tierOf() { return fitCls.has('asb-fit-c2') ? 2 : (fitCls.has('asb-fit-c1') ? 1 : 0); }
function resetFit() { fitCls.clear(); delete asbFitPages._tier; }
const root = {
  style: { setProperty(k, v) { if (v === '') delete props[k]; else props[k] = v; },
           getPropertyValue(k) { return props[k] || ''; } },
  classList: { toggle(c, on) { if (on) fitCls.add(c); else fitCls.delete(c); } },
  get clientHeight() { return clientH; }
};
const box = (top, h) => ({ getBoundingClientRect() { return { top: top, height: h, bottom: top + h }; } });
const pb = new Array(5).fill(0), tiles = new Array(6).fill(0);
const prof = { getBoundingClientRect() { return { top: profTop }; }, querySelectorAll() { return pb; } };
const hub = { getBoundingClientRect() { return { top: hubTop }; }, querySelectorAll() { return tiles; } };
/* fix206: home is a self-scrolling fixed overlay now - it mocks like the report page:
 * unclamped (height:auto) it reports its natural content bottom, clamped it reports the
 * viewport. scrollTop feeds sizeCards' profiles-top measurement. */
const homePage = { scrollTop: 0, style: {},
  getBoundingClientRect() {
    return this.style.height === 'auto'
      ? { top: 0, bottom: homeBase - tierOf() * 80 }
      : { top: 0, bottom: clientH };
  } };
const page = { scrollTop: 0, style: {}, getAttribute() { return cfgOpen ? 'false' : 'true'; },
  get clientHeight() { return clientH; },
  getBoundingClientRect() {
    return this.style.height === 'auto'
      ? { top: 0, bottom: (cfgBase - tierOf() * 80) * (window._asbUiScale || 1) }
      : { top: 0, bottom: clientH };
  } };
const reb = box(0, 84);
const reportPage = { scrollTop: 0, style: {}, get clientHeight() { return clientH; },
  getBoundingClientRect() {
    return this.style.height === 'auto'
      ? { top: 0, bottom: reportBase - tierOf() * 80 }
      : { top: 0, bottom: clientH };
  } };
global.window = { _asbUiScale: 1, innerHeight: 1900, scrollY: 0 };
global.document = {
  documentElement: root,
  body: { classList: { contains(c) { return (c === 'live-active' && live) || (c === 'config-active' && cfgOpen) || (c === 'report-active' && reportOpen); } } },
  querySelector(q) {
    if (q === '.asb-tabbar') return box(barTop, 60);
    if (q.indexOf('.profiles') >= 0) return prof;
    if (q.indexOf('.cfg-hub') >= 0) return hub;
    if (q.indexOf('.page:not(.live-page)') >= 0) return homePage;
    return null;
  }
};
global.getComputedStyle = () => ({ rowGap: '10px', gap: '10px', marginTop: '10px', paddingBottom: '0px' });
function _el(id) { return id === 'configPage' ? page : id === 'reportPage' ? reportPage : id === 'cfgRebootWrap' ? reb : null; }
EOF
  sed -n "/^function asbFitPages(/,/^}/p" "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
asbFitPages();
chk(props['--pbtn-h'] === '104px', 'a tall screen stops at the upper limit: ' + props['--pbtn-h']);
barTop = 1100; asbFitPages();
chk(props['--pbtn-h'] === '88px', 'shared out to the five cards: ' + props['--pbtn-h']);
barTop = 960; asbFitPages();
chk(tierOf() === 0 && props['--pbtn-h'] === '68px', '82 px past the fit line just scrolls - the tier-0 floor stays: ' + props['--pbtn-h'] + ' tier ' + tierOf());
chk(props['--cfg-tile-h'] === undefined, 'Settings closed: tiles untouched');
cfgOpen = true; barTop = 1200; delete props['--pbtn-h']; asbFitPages();
chk(props['--pbtn-h'] === undefined, 'Home cards are not refitted while Settings covers them');
chk(props['--cfg-tile-h'] === '158px', 'two rows of tiles share the height left over the restart row: ' + props['--cfg-tile-h']);
_cfgGroup = 'audio'; props['--cfg-tile-h'] = 'x'; asbFitPages();
chk(props['--cfg-tile-h'] === 'x', 'an open category leaves the hub alone');
_cfgGroup = null; barTop = 2600; asbFitPages();
chk(props['--cfg-tile-h'] === '176px', 'upper limit on Settings: ' + props['--cfg-tile-h']);
barTop = 900; cfgBase = 975; asbFitPages();
chk(tierOf() === 0 && props['--cfg-tile-h'] === '104px', 'a Settings page at the allowance keeps the tier-0 floor: ' + props['--cfg-tile-h'] + ' tier ' + tierOf());
window._asbUiScale = 0.82; barTop = 1120; asbFitPages();
chk(props['--cfg-tile-h'] === '148px', 'a scaled UI shares out unscaled pixels: ' + props['--cfg-tile-h']);
/* fix203: a page genuinely past its viewport compacts in tiers; a page only a little past
   the fit line keeps its look and scrolls (the allowance is a fifth of the screen). */
resetFit(); cfgOpen = false; live = false; window._asbUiScale = 1;
clientH = 700; window.innerHeight = 700; barTop = 640; homeBase = 920;   /* 300 px past the fit line; a tier buys back 80 */
asbFitPages();
chk(tierOf() === 2 && fitCls.has('asb-fit-c1') && fitCls.has('asb-fit-c2'), 'escalates tier by tier while it still overflows: tier ' + tierOf());
barTop = 660; asbFitPages();
chk(tierOf() === 2 && props['--pbtn-h'] === '48px', 'the card floor steps down with the tier: ' + props['--pbtn-h']);
resetFit(); fitCls.add('asb-fit-c1'); asbFitPages._tier = 1; homeBase = 776;   /* tier 0 would sit 136 px past - over the 132 px margin */
asbFitPages();
chk(tierOf() === 1 && fitCls.has('asb-fit-c1') && !fitCls.has('asb-fit-c2'), 'a tier comes off only with real room: tier ' + tierOf());
homeBase = 768;                  /* now tier 0 sits within the margin */
asbFitPages();
chk(tierOf() === 0 && fitCls.size === 0 && props['--pbtn-h'] === '68px', 'within the margin the lighter look wins: tier ' + tierOf());
/* the owner's OP15: the page is a touch past the fit line and keeps its look, scrolling the rest */
resetFit(); clientH = 1900; window.innerHeight = 1900; barTop = 1700; homeBase = 1755;
asbFitPages();
chk(tierOf() === 0 && props['--pbtn-h'] === '104px', 'a tall phone keeps its look and scrolls a touch: tier ' + tierOf());
homeBase = 2070;                 /* past the allowance: the compaction earns its keep */
asbFitPages();
chk(tierOf() === 1 && fitCls.has('asb-fit-c1') && !fitCls.has('asb-fit-c2'), 'past the allowance the page compacts, and stays compact: tier ' + tierOf());
resetFit(); cfgOpen = true; clientH = 700; window.innerHeight = 700; barTop = 640; cfgBase = 1400;   /* Settings 780 px past */
asbFitPages();
chk(tierOf() === 2 && props['--cfg-tile-h'] === '80px', 'the Settings tiles compact too: ' + props['--cfg-tile-h']);
/* fix205: the scroll surfaces never take a tier. The report is 2380 px past the fit line
   on this small screen - and the header still stays exactly as drawn. */
resetFit(); reportOpen = true; cfgOpen = false; reportBase = 3000;
asbFitPages();
chk(tierOf() === 0 && fitCls.size === 0, 'the report scrolls by design - its header is never squashed: tier ' + tierOf());
fitCls.add('asb-fit-c1'); fitCls.add('asb-fit-c2'); asbFitPages._tier = 2;   /* carried over from a small screen's Home */
asbFitPages();
chk(tierOf() === 0 && fitCls.size === 0, 'a tier carried into the report comes off: tier ' + tierOf());
reportOpen = false; cfgOpen = true; _cfgGroup = 'audio'; cfgBase = 2600;    /* an open category, 1980 px past */
asbFitPages();
chk(tierOf() === 0 && fitCls.size === 0, 'an open tweak category scrolls too - no squashed header: tier ' + tierOf());
_cfgGroup = null; cfgBase = 1400;
asbFitPages();
chk(tierOf() === 2, 'back on the Settings hub the tiers work as before: tier ' + tierOf());
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "window.addEventListener('resize', function () { requestAnimationFrame(asbFitPages); });" "$H" || fail "the fit is not redone on resize"
grep -Fq "window.addEventListener('orientationchange', function () { requestAnimationFrame(asbFitPages); });" "$H" || fail "the fit is not redone when the panel rotates"
echo "PASS webui fill pages: profile cards and category tiles take the free height within limits on any screen, a page well past its fit line compacts in tiers (decided from its natural height, the bar's padding not counted), a small overflow just scrolls, and the tiers come off with room to spare"
)

t_webui_device_font_runtime() (
# Runtime (fix168): the device-font test variant draws with the font the system UI uses.
#
# Owner's request: a variant with the WebUI text in the phone's font. A WebView only knows the
# families in fonts.xml, so a font applied through the font settings or a font app never reaches
# it; the variant takes the files the system UI process has mapped, prefers one applied from
# /data, falls back to the OnePlus system family, copies them next to the page and registers
# them under one name. The REAL discovery command runs against a fixture maps file and the REAL
# loader runs in node; the normal build never runs either.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui device font: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui device font: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q '^<html lang="en">$' "$H" || fail "the normal build must not carry the device-font switch"
grep -Fq "html[data-asb-font=\"device\"] { --sans: 'ASB Device', sans-serif; --mono: 'ASB Device', sans-serif; }" "$H" || fail "the variant does not draw with the found font"
mkdir -p "$T/mod/webroot" "$T/data/fonts" "$T/system/fonts"
printf 'R' > "$T/data/fonts/Custom-Regular.ttf"; printf 'B' > "$T/data/fonts/Custom-Bold.ttf"
printf 'E' > "$T/data/fonts/NotoColorEmoji.ttf"; printf 'S' > "$T/system/fonts/SysSans-En-Regular.ttf"
printf 'H' > "$T/system/fonts/SysSans-Hans-Regular.ttf"
for f in system/fonts/SysSans-En-Regular.ttf system/fonts/SysSans-Hans-Regular.ttf data/fonts/Custom-Regular.ttf data/fonts/Custom-Bold.ttf data/fonts/NotoColorEmoji.ttf; do
  printf '7000-8000 r--s 00000000 fd:00 1 %s\n' "$T/$f"
done > "$T/maps"
printf '7000-8000 r-xp 00000000 fd:00 1 /system/lib64/libc.so\n' >> "$T/maps"
cat > "$T/cmd.js" <<'EOF'
const fs = require('fs');
const [, , html, T] = process.argv;
const src = fs.readFileSync(html, 'utf8');
const m = src.match(/const ASB_DEVICE_FONT_CMD = ([\s\S]*?);\nfunction asbDeviceFontWeight/);
if (!m) { console.log('no command'); process.exit(1); }
const MD = T + '/mod';
let cmd = eval(m[1]);
for (const w of ['settings put', 'resetprop', 'setprop', 'rm ', 'mv ', '/sys/', 'echo ']) if (cmd.indexOf(w) >= 0) { console.log('writes outside its folder: ' + w); process.exit(1); }
cmd = cmd.replace('$(pidof com.android.systemui)', '1').replace('/proc/$p/maps', T + '/maps').replace('grep "^/data/"', 'grep "^' + T + '/data/"');
fs.writeFileSync(T + '/cmd.sh', cmd.replace(/^sh -c '/, '').replace(/'$/, '') + '\n');
EOF
node "$T/cmd.js" "$H" "$T" || fail "command"
out="$(sh "$T/cmd.sh")"
[ "$(printf '%s\n' "$out" | cut -d'|' -f1,2 | tr '\n' ' ')" = "f0.ttf|$T/data/fonts/Custom-Bold.ttf f1.ttf|$T/data/fonts/Custom-Regular.ttf " ] || fail "applied font not preferred: $out"
cmp -s "$T/mod/webroot/devfont/f1.ttf" "$T/data/fonts/Custom-Regular.ttf" || fail "font not copied next to the page"
grep -v '/data/fonts/' "$T/maps" > "$T/maps2"; mv "$T/maps2" "$T/maps"
out="$(sh "$T/cmd.sh")"
if [ "$(printf '%s\n' "$out" | cut -d'|' -f1,2)" != "f0.ttf|$T/system/fonts/SysSans-En-Regular.ttf" ]; then
  # The failure is environment-flaky inside the parallel suite; leave evidence behind.
  echo "FAIL webui device font: no OnePlus family fallback, or a CJK face taken: $out" >&2
  echo "--- maps ---" >&2; cat "$T/maps" >&2 2>&1
  echo "--- cmd.sh ---" >&2; cat "$T/cmd.sh" >&2 2>&1
  echo "--- sh -x rerun ---" >&2; sh -x "$T/cmd.sh" >&2 2>&1
  echo "--- devfont dir ---" >&2; ls -la "$T/mod/webroot/devfont" >&2 2>&1
  exit 1
fi
# fix216: the patterns must match the font FILE NAME, never the full path. A CI run once
# lost the whole list because mktemp named the fixture dir "tmp.5wIeilzKrt" - the "kr" in
# the random suffix matched the Korean-face exclusion and every path under it died. That
# layout is reproduced here on purpose: a directory carrying several exclusion tokens.
T2="$T/kr-mono-hans-cond-arab"
mkdir -p "$T2/mod/webroot" "$T2/system/fonts"
printf 'S' > "$T2/system/fonts/SysSans-En-Regular.ttf"
printf 'H' > "$T2/system/fonts/SysSans-Hans-Regular.ttf"
printf '7000-8000 r--s 00000000 fd:00 1 %s\n' "$T2/system/fonts/SysSans-En-Regular.ttf" > "$T2/maps"
printf '7000-8000 r--s 00000000 fd:00 1 %s\n' "$T2/system/fonts/SysSans-Hans-Regular.ttf" >> "$T2/maps"
node "$T/cmd.js" "$H" "$T2" || fail "command (token dir)"
out="$(sh "$T2/cmd.sh")"
[ "$(printf '%s\n' "$out" | cut -d'|' -f1,2)" = "f0.ttf|$T2/system/fonts/SysSans-En-Regular.ttf" ] \
  || fail "a directory named with exclusion tokens must not empty the family list: $out"
{
  cat <<'EOF'
const faces = [];
global.FontFace = function (fam, src, d) { this.fam = fam; this.src = src; this.d = d; faces.push(this); this.load = () => Promise.resolve(this); };
const root = { dataset: {} };
global.document = { documentElement: root, fonts: { add() {}, delete() {} } };
let ran = 0;
function run() { ran++; return Promise.resolve({ stdout: 'f0.ttf|/data/x/Custom-Bold.ttf|11\nf1.ttf|/data/x/Custom-Regular.ttf|12\nf2.ttf|/data/x/OPlusSans3.0-VF.ttf|13\nf3.ttf|/data/x/Custom-LightItalic.ttf|14\njunk|/etc/passwd|1\n' }); }
const MD = '/m';
EOF
  sed -n "/^const ASB_DEVICE_FONT_CMD = /,/^function asbDeviceFontWeight/p" "$H" | sed '$d'
  for fn in asbDeviceFontWeight asbDeviceFont; do sed -n "/^\(async \)\{0,1\}function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
(async () => {
  let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
  chk(await asbDeviceFont() === 0 && ran === 0, 'the normal build runs nothing');
  root.dataset.asbFont = 'device';
  chk(await asbDeviceFont() === 4, 'four faces registered, the junk line ignored');
  chk(faces.every(f => f.fam === 'ASB Device'), 'one family name');
  chk(faces.map(f => f.d.weight).join(',') === '700,400,100 900,300', 'weights from the file names: ' + faces.map(f => f.d.weight).join(','));
  chk(faces[3].d.style === 'italic' && faces[0].d.style === 'normal', 'italic face');
  chk(faces[1].src === "url('devfont/f1.ttf?v=12')", 'served next to the page, refreshed when the copy changes: ' + faces[1].src);
  chk(root.dataset.asbFontSrc.indexOf('/data/x/Custom-Regular.ttf') >= 0, 'source recorded');
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui device font: the variant takes the system UI's own font, an applied one first, and the normal build runs nothing"
)

t_webui_option_labels_runtime() (
# Runtime (fix169): option buttons and value badges speak the UI language.
#
# Owner's Settings > Network in Russian: Wi-Fi power save offered "выкл / screen_off / always"
# under a badge reading "OFF", Leave Bad Wi-Fi listed "weak" and "unusable", Act on Wakelocks
# and Trim Background GPS showed bare "0" / "1", and the Wi-Fi scan slider read "1" where the
# action screen said "every 10 min". The REAL Topt, cfgScanLabel and cfgStatus run in node with
# the shipped en.json and ru.json; every language is checked for the labels. fix176 adds the
# wakelock_fitness honesty badge: on a ROM that does not enforce the WAKE_LOCK app-op the badge
# says so (warn) instead of claiming "Enabled", and all 13 locales carry the strings.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui option labels: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui option labels: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT/webroot/i18n" <<'P' || fail "locales"
import json, sys, pathlib
need = {'bt_link_stability': ['stable'], 'net_wifi_leave': ['weak', 'unusable'],
        'wifi_powersave': ['screen_off', 'always'], 'wakelock_action': ['0', '1'],
        'gnss_trim': ['0', '1'], 'mglru_hold': ['hold']}
files = sorted(pathlib.Path(sys.argv[1]).glob('*.json'))
assert len(files) == 13
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for k, opts in need.items():
        for o in opts:
            v = d.get('optFor', {}).get(k, {}).get(o) or d.get('opt', {}).get(o)
            assert v and not (v == o and o.isdigit()), '%s: %s=%s has no label' % (p.name, k, o)
    assert d.get('wst_every', '').count('%s') == 1 and d.get('wst_free'), p.name + ': scan labels'
    for k in ('st_wlf_ignored', 'st_wlf_none', 't_wlf_ignored'):
        assert d.get(k), '%s: %s missing' % (p.name, k)
    assert '·' in d['t_wlf_ignored'], p.name + ': the fitness-limit toast keeps its middle dot'
    if p.name == 'en.json':
        assert d['st_wlf_ignored'] == 'ROM ignores it' and d['st_wlf_none'] == 'no fitness apps'
        assert d['t_wlf_ignored'] == ' · this ROM ignores the limit', 'en.json matches the T() fallbacks'
P
{
  printf 'const I18N = { en: %s, ru: %s };\n' "$(cat "$ROOT/webroot/i18n/en.json")" "$(cat "$ROOT/webroot/i18n/ru.json")"
  cat <<'EOF'
let ASB_LANG = 'ru';
function T(k, d) { const L = I18N[ASB_LANG]; return (L && typeof L[k] === 'string') ? L[k] : d; }
function ledgerBadge() { return null; } function trialHoursLeft() { return 0; } function trialExpired() { return false; }
const _netResult = {}; const _cfgVals = {};
let _wlFitIgnored = 0, _wlFitLimited = 0, _wlFitInstalled = 0, _wlFitProbed = false;
EOF
  for fn in Topt cfgScanLabel cfgStatus; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
const seg = (key, stock) => ({ key: key, type: 'seg', stock: stock });
chk(Topt('screen_off', 'wifi_powersave') === 'экран выкл', 'power-save option: ' + Topt('screen_off', 'wifi_powersave'));
chk(cfgStatus(seg('wifi_powersave', 'off'), 'off').text === 'ВЫКЛ', 'badge over "выкл" reads OFF: ' + cfgStatus(seg('wifi_powersave', 'off'), 'off').text);
chk(cfgStatus(seg('wifi_powersave', 'off'), 'always').text === 'ВСЕГДА', 'badge: ' + cfgStatus(seg('wifi_powersave', 'off'), 'always').text);
chk(cfgStatus(seg('wakelock_action', '0'), '1').text === 'ДЕЙСТВОВАТЬ', 'wakelock badge: ' + cfgStatus(seg('wakelock_action', '0'), '1').text);
chk(cfgStatus(seg('net_congestion_wifi', 'auto'), 'cubic').text === 'CUBIC', 'technical names unchanged');
chk(cfgStatus({ key: 'wifi_scan_throttle', type: 'range' }, '1').text === 'раз в 10 мин', 'scan badge: ' + cfgStatus({ key: 'wifi_scan_throttle', type: 'range' }, '1').text);
chk(cfgScanLabel(0) === 'выкл' && cfgScanLabel(3) === 'раз в 2 мин' && cfgScanLabel(4) === 'без ограничений', 'scan labels');
chk(cfgStatus({ key: 'dsp_bass', type: 'range' }, '0').text === 'выкл', 'a range at zero says off in the UI language');
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'protect').text === String(Topt('protect', 'wakelock_fitness')).toUpperCase(), 'protect badge: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'protect').text);
_wlFitIgnored = 1;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').cls === 'warn' && cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text === 'прошивка игнорирует', 'ROM-ignored limit badge: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text);
_wlFitIgnored = 0; _wlFitLimited = 2;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').cls === 'good', 'an enforced limit badge is good');
_wlFitLimited = 0; _wlFitProbed = true; _wlFitInstalled = 0;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').cls === 'neutral' && cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text === 'нет фитнес-приложений', 'no fitness apps badge: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text);
/* fix177: two fitness apps installed, nothing limited yet - never "no fitness apps". */
_wlFitInstalled = 2;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text === 'ожидает', 'installed apps read as none: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text);
_wlFitInstalled = 0;
_wlFitProbed = false;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text === 'ожидает', 'unprobed limit badge: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text);
ASB_LANG = 'en';
chk(cfgScanLabel(2) === 'every 5 min', 'English scan label');
_wlFitIgnored = 1;
chk(cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text === 'ROM ignores it', 'English ROM-ignored badge: ' + cfgStatus(seg('wakelock_fitness', 'protect'), 'limit').text);
_wlFitIgnored = 0;
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "if (it.key === 'wifi_scan_throttle') return cfgScanLabel(v);" "$H" || fail "the slider value is still a bare number"
grep -Fq '.cfg-row-top > .cfg-range input[type="range"] { flex: 1 1 auto; width: auto; min-width: 0; }' "$H" || fail "a slider on its own row keeps its short track"
grep -Fq "if (it.key === 'wakelock_fitness') {" "$H" || fail "cfgStatus lost the wakelock_fitness honesty branch"
grep -Fq 'async function loadWlFitStatus(force)' "$H" || fail "loadWlFitStatus is gone"
echo "PASS webui option labels: option buttons and value badges are labelled in the UI language, the Wi-Fi scan rate in minutes, sliders use their row, and the fitness limit admits when the ROM ignores it"
)

t_webui_smart_basis_runtime() (
# Runtime (fix186): the Monitor's Smart "Basis" tile said "own slot" around the clock once the
# learner had history - true and uninformative. It now shows what shapes Smart's lean right
# now (an override, the records' result or trial for this situation, the smoothness check),
# keeps the slot basis while the learner borrows from another slot, and its sheet lists every
# situation's record from smart_records.txt. The REAL functions run in node.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"; G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL webui smart basis: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui smart basis: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'const _b = lvBasisPaint(kv, fb, dp, we, conf, night, veto);' "$H" || fail "the tile does not use lvBasisPaint"
grep -q "if (key === 'basis' && typeof lviRecordsAppend === 'function') lviRecordsAppend(src, tok);" "$H" || fail "the sheet does not list the records"
for k in rec_ctx rec_ctx_status rec_ctx_best rec_ctx_test rec_ctx_trial rec_ctx_pairs rec_ctx_need rec_ctx_max rec_ctx_n rec_ctx_gain_x10; do
  grep -q "\"$k=%" "$G" || grep -q "\\\\n$k=%" "$G" || grep -q "$k=%" "$G" || fail "governor does not publish $k"
done
for l in en ru uk de es fr it pt tr id ar hy zh; do
  J="$ROOT/webroot/i18n/$l.json"
  for k in lvb_record lvb_record_ok lvb_trial lvb_measure lvb_smooth_test lvb_smooth_on lvb_cold lvb_lowbat lvb_brief \
           lvr_ctx_off_night lvr_ctx_on_medium_bright lvr_arm_off lvr_arm_on lvr_plateau lvr_testing lvr_testing_more \
           lvr_title lvr_rejected lvr_mw lvr_smooth lvb_clim unit_mw lvi_basis; do
    grep -q "\"$k\"" "$J" || fail "$l.json lacks $k"
  done
  grep -q '"lvb_record": "[^"]*%s' "$J" || fail "$l.json lvb_record has no place for its figure"
  grep -q '"lvi_basis": "[^"]*{rec}[^"]*{trial}[^"]*{cold}' "$J" || fail "$l.json lvi_basis does not explain the new values"
done
cat > "$T/rec.txt" <<'E'
# Smart records (Smart V5): power per situation, charge counter x battery voltage
counter=ok blocks_ok=57 blocks_rejected=6
rejected|meter=0|charge=2|radio=1|busy=1|climate=2|other=0
# ctx|status|best|record_mW|record_mA|record_n|gain_pct|testing|pairs|pair_diff_pct|trials|wins|blocks|first_mW
off_night|plateau|x0.875|176|45.6|9|7.7|-|0|0.0|2|1|25|192
off_day|testing|x1.000|0|0.0|0|0.0|x0.875|3|-4.1|0|0|8|0
on_light_dim|holding|+100|1477|381.2|11|3.9|-|0|0.0|1|1|24|1540
on_light_bright|testing|+0|0|0.0|0|0.0|+100|9|-1.0|0|0|20|0
on_medium_dim|plateau|+0|1500|390.0|8|0.0|-|0|0.0|2|0|30|1500
on_medium_bright|measuring|+0|0|0.0|0|0.0|-|0|0.0|0|0|2|0
microwake|learned=3|nights=3|per_night=1.0|typical_s=220|usual=03:00-03:30
smooth|watching=4|testing=1|helped=1|not_helped=2
E
{
  sed -n '/^\/\* Smart records in words (fix186)/,/^const LVI_TEXT = {/p' "$H" | sed '$d'
  cat <<'EOF'
;
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const base = { rec_enabled: '1', rec_ctx: 'on_medium_dim', rec_ctx_status: 'plateau', rec_ctx_best: '0', rec_ctx_test: '0',
  rec_ctx_pairs: '0', rec_ctx_need: '8', rec_ctx_max: '20', rec_ctx_n: '0', rec_ctx_gain_x10: '0' };
function paint(over, fb, night, veto) { return lvBasisPaint(Object.assign({}, base, over || {}), fb || 0, 4, 0, 720, night || 0, veto || 0); }
let r = paint({}, 0);
chk(r.txt === 'record ✓', 'plateau at the original setting: ' + r.txt);
chk(/plateau: the original setting is the best/.test(r.tip) && /Confidence: 72%/.test(r.tip) && r.tip.indexOf('=') < 0, 'tip: ' + r.tip);
r = paint({ rec_ctx: 'off_night', rec_ctx_best: '875', rec_ctx_test: '875', rec_ctx_gain_x10: '77' });
chk(r.txt === '🏆 −8%' && r.cls === ' cap-raised' && r.short === '', 'a win shows its saving: ' + r.txt + r.cls);
chk(/night, screen off: plateau: ceilings ×0\.875 is the best found, 7\.7% cheaper/.test(r.tip), 'win tip: ' + r.tip);
r = paint({ rec_ctx_status: 'testing', rec_ctx_test: '100', rec_ctx_pairs: '3' });
chk(r.txt === 'trial 3/8' && r.short === '🧪 3/8' && /trial: lean \+10 against lean ±0, 3 of 8 pairs/.test(r.tip), 'trial: ' + r.txt + ' / ' + r.tip);
r = paint({ rec_ctx_status: 'testing', rec_ctx_test: '-100', rec_ctx_pairs: '11' });
chk(r.txt === 'trial 11' && r.short === '🧪 11' && /lean −10 against .* 11 pairs - not a clear result yet, up to 20/.test(r.tip), 'long trial: ' + r.txt + ' / ' + r.tip);
r = paint({ rec_ctx_status: 'measuring', rec_ctx_n: '2' });
chk(r.txt === 'measure 2/8' && r.short === '⏳ 2/8', 'measuring: ' + r.txt);
r = paint({ smooth_lean: '-150' });
chk(r.txt === '🎞 smooth' && r.short === '🎞 ↑' && /kept for it/.test(r.tip), 'smoothness kept: ' + r.txt);
r = paint({ smooth_lean: '-150', smooth_testing: '1' });
chk(r.txt === '🎞 test' && r.short === '🎞 A/B', 'smoothness test: ' + r.txt);
r = paint({ smart_cold_guard: '1' });
chk(r.txt === '❄ cold' && r.cls === ' basis-warn' && r.short === '' && /under 5 °C/.test(r.tip), 'cold guard: ' + r.txt);
r = paint({ smart_lowbat_override: '1' });
chk(r.txt === '🔋 low', 'low battery: ' + r.txt);
r = paint({ microwake_active: '1' });
chk(r.txt === '🌙 brief', 'night check: ' + r.txt);
r = paint({ smart_cold_guard: '1' }, 0, 1, 1);
chk(r.txt === '🛡 guard' && r.cls === ' basis-veto', 'the thermal guard comes first: ' + r.txt);
r = paint({}, 1);
chk(r.txt === 'neighbour', 'a borrowed slot is still shown: ' + r.txt);
r = paint({}, 4);
chk(r.txt === 'cold start' && r.cls === ' basis-warn', 'cold start: ' + r.txt);
r = paint({ rec_enabled: '0' });
chk(r.txt === 'own slot', 'records off: the slot basis: ' + r.txt);
/* fix190: on the charger the records pause - "own slot" there answered nothing. */
r = paint({ charging: '1', rec_ctx: '-', rec_ctx_status: '-', smart_charge_cool: '1' });
chk(r.txt === '⚡ charging' && r.short === '⚡' && /records and the drain learning pause/.test(r.tip) && /holds the CPU back/.test(r.tip), 'charging: ' + r.txt + ' / ' + r.tip);
r = paint({ charging: '1', smart_cold_guard: '1' });
chk(r.txt === '❄ cold', 'the cold guard outranks the charger: ' + r.txt);
r = paint({ rec_ctx: '-', rec_ctx_status: '-' });
chk(r.txt === 'own slot', 'no situation now: the slot basis: ' + r.txt);
r = paint({ ses_climate: '2' });
chk(/taught nothing about drain: a cold battery was warming up or cooling down/.test(r.tip), 'climate note: ' + r.tip);
(async function () {
  const src = { textContent: 'first line', hidden: true };
  _lviTok = 1;
  await lviRecordsAppend(src, 1);
  const t = src.textContent;
  chk(!src.hidden && t.indexOf('first line\n\nSmart records') === 0, 'appended after the tile lines: ' + t.slice(0, 60));
  chk(/night, screen off: plateau: ceilings ×0\.875 is the best found, 7\.7% cheaper .* · 176 mW/.test(t), 'off_night line');
  chk(/day, screen off: trial: ceilings ×0\.875 against ceilings ×1, 3 of 6 pairs/.test(t), 'off_day line');
  chk(/screen on, light apps, dim: best so far: lean \+10, 3\.9% cheaper/.test(t), 'on_light_dim line');
  chk(/screen on, light apps, bright: trial: lean \+10 against lean ±0, 9 pairs - not a clear result yet, up to 20/.test(t), 'on_light_bright line');
  chk(/screen on, other apps, dim: plateau: the original setting is the best/.test(t), 'on_medium_dim line');
  chk(/screen on, other apps, bright: measuring: 2 block\(s\) so far/.test(t), 'on_medium_bright line');
  chk(/Set aside, credited to no setting: charging 2, busy radio 1, CPU kept awake 1, climate 2/.test(t), 'rejections: ' + t);
  chk(/Night check-ins: 3 over 3 night\(s\), usually 03:00-03:30, about 220 s/.test(t), 'night check-ins');
  chk(/Smoothness: watching 4, testing 1, helped 1, not helped 2/.test(t), 'smoothness');
  const late = { textContent: 'x', hidden: true };
  _lviTok = 5;
  await lviRecordsAppend(late, 4);
  chk(late.textContent === 'x', 'a sheet that was replaced is not written into');
  if (bad) process.exit(1);
  console.log('ok');
})();
EOF
} > "$T/body.js"
cat > "$T/run.js" <<EOF
const fs = require('fs');
global.T = function (k, d) { return d; };
global.liveInfoIsOpen = function () { return true; };
global.run = function () { return Promise.resolve({ errno: 0, stdout: fs.readFileSync('$T/rec.txt', 'utf8'), stderr: '' }); };
const src = fs.readFileSync(process.argv[2], 'utf8');
(0, eval)(src);
EOF
out="$(node "$T/run.js" "$T/body.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui smart basis: the tile says what shapes Smart now (records, trials, smoothness, overrides), the sheet lists every situation's record"
)

t_webui_home_offdrain_runtime() (
# Runtime (fix187, reworked in fix189): a profile card's screen-off chip is what was measured
# in that profile. fix187 put the governor's phone-wide figure on the running profile's card,
# and an OP15 switched from Smart to Balanced showed Smart's 0.70 %/h on Balanced's card a
# minute later. The REAL chooser runs in node: the meter's figure, "<x" for an hour that did
# not move the level, the governor's per-profile figure - never the phone-wide one.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui home offdrain: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui home offdrain: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'const off = homeOffFigure(prof);' "$H" || fail "the home card does not use the shared rule"
grep -q "const _of = lvOffFigure(_selectedProfile);" "$H" || fail "the time to empty does not use the shared rule"
grep -q "const of = lvOffFigure(k);" "$H" || fail "the sheet's rows do not use the shared rule"
grep -q "cat /data/adb/asb/offdrain_profiles" "$H" || fail "the per-profile figures are not read where the meter is"
{
  echo "function T(k, d) { return d; }"
  echo "function lvPct(x, div, digits) { return (x / div).toFixed(digits) + '%/h'; }"
  echo "var _selectedProfile = 'balanced';"
  sed -n '/^const _lvMeter = /p' "$H" | sed 's/^const /var /'
  sed -n '/^const _lvGovOff = /p' "$H" | sed 's/^const /var /'
  sed -n '/^function lvGovOffParse(/,/^}/p' "$H"
  sed -n '/^function lvOffFigure(/,/^}/p' "$H"
  sed -n '/^function homeOffFigure(/,/^}/p' "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
_lvGovOff.x = 70; _lvGovOff.n = 5;   /* phone-wide: never on a card */
_lvMeter.p = { smart: { on: 82, off: 0, offN: 0, offS: 0 }, battery: { on: 100, off: 37, offN: 1, offS: 9771 },
               balanced: { on: 154, off: 0, offN: 0, offS: 0 }, stock: { on: 0, off: 0, offN: 2, offS: 7200 } };
_lvGovOff.by = lvGovOffParse('smart 62 3\nbogus x y\nbattery 0 0\n');
chk(homeOffFigure('balanced') === null, 'Balanced got the phone-wide figure: ' + JSON.stringify(homeOffFigure('balanced')));
let r = homeOffFigure('smart');
chk(r && r.t === '0.62%/h' && r.src === 'gov' && /3 screen-off/.test(r.tip), 'Smart keeps its own governor figure: ' + JSON.stringify(r));
r = homeOffFigure('battery');
chk(r && r.t === '0.37%/h' && r.src === 'meter', 'meter figure first: ' + JSON.stringify(r));
r = homeOffFigure('stock');
chk(r && r.t === '<0.50%/h', 'an hour that did not move the level: ' + JSON.stringify(r));
chk(homeOffFigure('performance') === null, 'nothing measured: nothing shown');
_selectedProfile = 'smart';
chk(homeOffFigure('balanced') === null, 'the running profile does not matter');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui home offdrain: a card's screen-off figure is the one measured in that profile, never the phone-wide one"
)

t_webui_navbar_profiles() (
# fix187: the first tab is the profile picker and says so. The user asked for "Profiles" in
# place of "Home", an icon that fits it, and a bar in a current style: a sliding tonal pill
# behind the active icon, line icons that fill when active, no aria-label overriding the
# translated text. The pill is placed from the active tab's measured box (RTL included),
# and again when the bar comes back from a settings category.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui navbar: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP webui navbar: no python3"; exit 0; }
python3 - "$ROOT" <<'P' || exit 1
import json, re, sys, glob, os
root = sys.argv[1]; h = open(os.path.join(root, 'webroot/index.html'), encoding='utf-8').read()
bad = []
nav = h[h.index('<nav class="asb-tabbar"'):h.index('</nav>', h.index('<nav class="asb-tabbar"'))]
tabs = re.findall(r'<button class="asb-tab"[^>]*>', nav)
if len(tabs) != 3: bad.append('three tabs expected, found %d' % len(tabs))
if any('aria-label' in t for t in tabs): bad.append('a tab still overrides its translated label with an English aria-label')
if nav.count('class="asb-tab-ico"') != 3 or nav.count('class="f"') + nav.count('class="f" ') < 3: bad.append('every icon needs a line form and a filled form')
if 'class="asb-tab-ind"' not in nav: bad.append('no sliding indicator')
if '>Profiles</span>' not in nav: bad.append('the first tab is not called Profiles')
if 'is-active::before' in h: bad.append('the old top-edge marker is back')
fn = h[h.index('function asbNavSync()'):h.index('function asbNavGo(')]
if 'asbNavIndicator();' not in fn or 'on.offsetLeft' not in fn: bad.append('the pill is not placed from the active tab')
vis = h[h.index('function asbTabbarVisibility()'):h.index('function cfgRender()')]
if 'asbNavIndicator()' not in vis: bad.append('returning from a category leaves the pill where it was')
want = {'en': 'Profiles', 'ru': 'Профили', 'uk': 'Профілі', 'de': 'Profile'}
for f in sorted(glob.glob(os.path.join(root, 'webroot/i18n/*.json'))):
    lang = os.path.basename(f)[:-5]; d = json.load(open(f, encoding='utf-8'))
    v = d.get('nav_home', '')
    if lang in want and v != want[lang]: bad.append('%s nav_home=%r' % (lang, v))
    if v in ('Home', 'Главная', 'Головна', 'Start', 'Accueil', 'Inicio', 'Início', 'Beranda', 'Ana sayfa', '主页', 'الرئيسية', 'Գլխավոր'):
        bad.append('%s still says Home' % lang)
for b in bad: print('FAIL webui navbar: ' + b, file=sys.stderr)
sys.exit(1 if bad else 0)
P
echo "PASS webui navbar: Profiles / Monitor / Settings with fitting icons, a sliding pill and translated names"
)

t_webui_lsposed_badge_runtime() (
# Runtime (fix187): the LSPosed card's badge says what LSPosed has, not what the card asked.
# The REAL parser and badge run in node on asb_lsposed.sh status output.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui lsposed badge: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui lsposed badge: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'await loadLspStatus();' "$H" || fail "the status is never loaded"
grep -q "if (it.key === 'lsposed_verbose') {" "$H" || fail "the card has no badge of its own"
{
  echo "function T(k, d) { return d; }"
  sed -n '/^function lspParse(/,/^}/p' "$H"
  sed -n '/^function lspBadge(/,/^}/p' "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const P = (s) => lspParse(s.join('\n'));
let b = lspBadge(P(['present=1', 'setting=keep', 'verbose=default_on', 'log_kib=31744', 'verbose_kib=30000', 'modules_kib=1700', 'pending_reboot=0']), 'keep');
chk(b.cls === 'warn' && b.text === 'verbose log on · 29 MB', 'a big verbose log: ' + JSON.stringify(b));
/* fix189: verbose off, 20 MB of modules log - named apart, not read as the verbose log */
b = lspBadge(P(['present=1', 'verbose=off', 'log_kib=20148', 'verbose_kib=37', 'modules_kib=19800', 'pending_reboot=0']), 'off');
chk(b.cls === 'good' && b.text === 'verbose log off · modules log 19 MB', 'the modules log named apart: ' + JSON.stringify(b));
b = lspBadge(P(['present=1', 'verbose=off', 'log_kib=2048', 'pending_reboot=1', 'asb_changed=1 prev=default_on']), 'off');
chk(b.cls === 'warn' && b.text === 'off after a reboot', 'written this boot: ' + JSON.stringify(b));
b = lspBadge(P(['present=1', 'verbose=off', 'log_kib=512', 'pending_reboot=0']), 'off');
chk(b.cls === 'good' && b.text === 'verbose log off', 'off and in force: ' + JSON.stringify(b));
b = lspBadge(P(['present=1', 'verbose=unknown', 'reason=no_sqlite']), 'off');
chk(b.text === 'set in LSPosed (no_sqlite)', 'unreadable names why (fix213): ' + JSON.stringify(b));
b = lspBadge(P(['present=1', 'verbose=unknown', 'reason=unexpected_schema']), 'keep');
chk(b.text === 'set in LSPosed (unexpected_schema)', 'a newer LSPosed schema names itself (fix213): ' + JSON.stringify(b));
b = lspBadge(P(['present=0', 'setting=keep']), 'keep');
chk(b.text === 'no LSPosed', 'absent: ' + JSON.stringify(b));
chk(lspBadge(P(['']), 'keep') === null, 'no answer: the generic badge stays');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui lsposed badge: LSPosed's real state, its log size and a pending reboot reach the card"
)

t_webui_monitor_manual_tiles_runtime() (
# Runtime (fix189): the Monitor on Battery/Balanced/Performance. Balanced read "Learner:
# unknown · 2" - Battery's session count (the tile always took learner.sessions.battery) and an
# untranslated rating of the last Battery session - with ten Balanced sessions recorded. And the
# system load gets its share of the cores, coloured like the temperatures (asked for).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor manual tiles: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui monitor manual tiles: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'learner.sessions && learner.sessions.battery' "$H" && fail "the tile still counts Battery's sessions on every profile"
grep -q 'const sessions = parseInt(sesMap\[profile\], 10) || 0;' "$H" || fail "the tile does not count this profile's sessions"
grep -q "if (key === 'learner' && _selectedProfile !== 'smart') key = 'learnerp';" "$H" || fail "the sheet explains Smart's learning on a manual profile"
grep -q 'echo "cpus_online=$_nc"' "$ROOT/runtime/asb_rom_telemetry.sh" || fail "no core count for the load share"
for l in en ru uk de fr it pt es id tr zh ar hy; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [d[k] for k in ('learn_clean','learn_partial','learn_noisy','learn_dirty','lvi_learner_prof','stock_load_share','stock_load_busy','learn_tip_profile')]" "$ROOT/webroot/i18n/$l.json" \
    || fail "$l: tile strings missing"
done
{
  sed -n '/^function lvLoadShare(/,/^}/p' "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
let r = lvLoadShare('9.06 7.13 5.64', '8');
chk(r && r.pct === 113 && r.cls === 'load-high', 'busy: ' + JSON.stringify(r));
r = lvLoadShare('2.40 2 2', '8'); chk(r && r.pct === 30 && r.cls === 'load-low', 'light: ' + JSON.stringify(r));
r = lvLoadShare('4.4 1 1', '8'); chk(r && r.pct === 55 && r.cls === 'load-mid', 'half: ' + JSON.stringify(r));
r = lvLoadShare('6.0', '6'); chk(r && r.pct === 100 && r.cls === 'load-high', 'parked cores: ' + JSON.stringify(r));
chk(lvLoadShare('3.0', '') === null && lvLoadShare('', '8') === null && lvLoadShare('x', '8') === null, 'no core count or no load: no share');
if (bad) process.exit(1);
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui monitor manual tiles: this profile's sessions on the learner tile, the load as a coloured share of the cores"
)

t_webui_monitor_binding_tiles_contract() (
# Contract (fix190): from OP15 screenshots taken on the charger a few minutes after a boot.
# "Who set the limit: ASB" on Performance beside "Headroom 35 %" (the vendor's 1632000 on the
# prime; the tile read only the main cluster); "38/ч · 38 всего" broken over two lines; the
# slot tile cut to "вечер…".
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui monitor binding tiles: $*" >&2; exit 1; }
grep -q "const capSrc = (_csForeign(_cs1) && !_csForeign(_cs0)) ? _cs1 : (_cs0 || _cs1);" "$H" || fail "the owner tile reads only the main cluster"
grep -q "T('cap_tip_clusters'" "$H" || fail "the owner tile does not name both clusters"
grep -q "clampEl.offsetHeight > _lh \* 1.5" "$H" || fail "the clamp counts still break onto two lines"
grep -q 'bEl.scrollWidth > bEl.clientWidth + 1) sub.remove();' "$H" || fail "the slot pill still cuts the slot name"
for l in en ru uk de fr it pt es id tr zh ar hy; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [d[k] for k in ('cap_tip_clusters','lvb_charge','lvb_charge_tip','lvb_charge_cool_tip','lvb_charge_assist_tip')]" "$ROOT/webroot/i18n/$l.json" || fail "$l: strings missing"
done
echo "PASS webui monitor binding tiles: the binding cluster's owner, counts on one line, the slot name whole"
)

t_webui_header_capsules() (
# fix192: the header in the bottom bar's language - "make the header in the same style as the
# nav bar, on every page". One material for bar and header capsules (shared tokens, so they
# cannot drift apart), the bar's tonal pill for every "selected" thing (theme icon, current
# profile, open Logs menu), and an island that stays on one line: Logs/Channel fold to icons
# inside a Settings category and whenever the row would otherwise wrap (measured at runtime).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui header capsules: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP webui header capsules: no python3"; exit 0; }
python3 - "$H" <<'P' || exit 1
import re, sys
h = open(sys.argv[1], encoding='utf-8').read()
bad = []
def need(x, why):
    if x not in h: bad.append(why)
def absent(x, why):
    if x in h: bad.append(why)
for pre in ('', 'live', 'cfg', 'rp', 'dev'):
    soc = (pre + 'SocBadge') if pre else 'socBadge'
    ver = (pre + 'VerBadge') if pre else 'verBadge'
    blk = r'<div class="hdr-cap hdr-info">\s*<button class="badge badge-a" id="%s" type="button" onclick="openDevicePage\(\)" aria-label="Open device diagnostics" title="Device diagnostics">DEVICE</button>\s*<div class="badge badge-a" id="%s">V65</div>\s*</div>' % (soc, ver)
    if not re.search(blk, h): bad.append('%s/%s are not one capsule' % (soc, ver))
need('.hdr-cap, .theme-toggle, .status-row {\n  background: var(--cap-wash), var(--tabbar-bg, #000000);\n  border: 1px solid var(--cap-edge);\n  box-shadow: var(--cap-shadow);', 'header capsules do not use the shared material')
need('    var(--cap-wash),\n    var(--tabbar-bg, #000000);\n  border: 1px solid var(--cap-edge);', 'the bar no longer uses the shared material')
bar = h[h.index('.asb-tab-ind::before {'):h.index('}', h.index('.asb-tab-ind::before {'))]
if 'var(--pill-wash)' not in bar: bad.append('the bar indicator is not the shared pill')
tt = h[h.index('.theme-toggle::before {'):h.index('}', h.index('.theme-toggle::before {'))]
if 'var(--pill-wash)' not in tt or 'transition: transform' not in tt: bad.append('the theme switch has no sliding pill')
need('html[data-asb-theme="light"] .theme-toggle::before { transform: translateX(38px); }', 'the pill does not follow the light theme')
need('html[dir="rtl"][data-asb-theme="light"] .theme-toggle::before { transform: translateX(-38px); }', 'the pill slides the wrong way in RTL')
need('html[data-asb-glass="1"] .theme-toggle::before { transform: translateX(76px); }', 'the pill does not follow Liquid Glass')
need('html[dir="rtl"][data-asb-glass="1"] .theme-toggle::before { transform: translateX(-76px); }', 'the Glass pill slides the wrong way in RTL')
sv = h[h.index('.status-val {\n  display: inline-flex;'):]
sv = sv[:sv.index('}')]
if 'var(--pill-wash)' not in sv: bad.append('the current profile is not on the tonal pill')
need('.island-btn[aria-expanded="true"] { color: var(--accent); background: var(--pill-wash);', 'the open Logs menu is not marked')
need('.status-row:is(.has-back,.is-tight) .island-btn > span { display: none; }', 'Logs/Channel never fold to icons')
need("if (row) row.classList.toggle('has-back', !!_cfgGroup);", 'the category Back does not fold the island')
lp = re.search(r'html\[data-asb-theme="light"\] :is\(([^)]*)\) \{\n  background:#ffffff !important;', h)
if not lp: bad.append('light paper list not found')
else:
    m = [x.strip() for x in re.sub(r'/\*.*?\*/', '', lp.group(1), flags=re.S).split(',')]
    for x in ('.hdr-cap', '.theme-toggle', '.status-row', '.asb-tabbar'):
        if x not in m: bad.append('light paper list lacks ' + x)
    if '.badge' in m: bad.append('light theme still paints each badge as its own white chip')
absent('html[data-asb-theme="light"] .theme-toggle { background:transparent', 'light theme strips the switch capsule')
rows = re.findall(r'\n\.status-row \{[^}]*\}', h)
if len(rows) != 1: bad.append('the island has %d base rules, expected one' % len(rows))
elif 'background' in rows[0] or 'border:' in rows[0]: bad.append('the island has a material of its own again')
for b in bad: print('FAIL webui header capsules: ' + b, file=sys.stderr)
sys.exit(1 if bad else 0)
P
command -v node >/dev/null 2>&1 || { echo "PASS webui header capsules (static; no node)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  sed -n '/^function asbHeaderRowWrapped(/,/^}/p' "$H"
  sed -n '/^function asbHeaderFit(/,/^}/p' "$H"
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
function kid(top, h, shown) { return { getClientRects() { return shown === false ? [] : [1]; }, getBoundingClientRect() { return { top: top, bottom: top + h }; } }; }
function row(kids) { const set = new Set(); return { children: kids, classList: { add(c) { set.add(c); }, remove(c) { set.delete(c); }, contains(c) { return set.has(c); } } }; }
/* one line: an 8px dot and a 30px button share a centre */
let r1 = row([kid(16, 8), kid(11, 18), kid(5, 30), kid(0, 0, false)]);
/* wrapped: the island dropped to a second line */
let r2 = row([kid(16, 8), kid(11, 18), kid(43, 30)]);
/* was tight, now fits again (shorter profile) */
let r3 = row([kid(16, 8), kid(5, 30)]); r3.classList.add('is-tight');
global.document = { querySelectorAll() { return [r1, r2, r3]; } };
asbHeaderFit();
chk(!r1.classList.contains('is-tight'), 'a one-line island was folded');
chk(r2.classList.contains('is-tight'), 'a wrapped island was not folded');
chk(!r3.classList.contains('is-tight'), 'an island that fits again stays folded');
chk(asbHeaderRowWrapped(row([kid(0, 30, false), kid(40, 30)])) === false, 'hidden children are counted');
/* unchanged text and width: no re-measure (Monitor rewrites the same label every poll) ... */
let measured = 0; const r4 = row([kid(16, 8), kid(43, 30)]); r4.textContent = 'smart';
r4.children[0].getBoundingClientRect = function () { measured++; return { top: 16, bottom: 24 }; };
global.document = { querySelectorAll() { return [r4]; } };
asbHeaderFit(); asbHeaderFit();
chk(measured === 1 && r4.classList.contains('is-tight'), 'the same label is measured again: ' + measured);
/* ... but a forced pass (Back shown/hidden, fonts loaded) always measures */
asbHeaderFit(true);
chk(measured === 2, 'a forced pass was skipped');
process.exit(bad ? 1 : 0);
EOF
} > "$T/t.js"
node "$T/t.js" || fail "fit logic"
echo "PASS webui header capsules: shared bar material, tonal pills, one-line island on every page"
)

t_webui_page_scroll() (
# fix201: "can't scroll down, there are more cards" - two user reports (an OP15 screenshot
# with the Monitor page cut mid-card, "same on an Ace 5"). Two causes, both pinned here.
# html/body were height:100%: overflow-x:hidden computes overflow-y to auto, so BODY became
# the scroll container and the document had nothing to scroll - WebViews that gesture-scroll
# only the document showed a page that does not move. Now min-height: the page grows, the
# document scrolls, every WebView scrolls it. Short content still fills exactly one viewport
# via .page's min-height, so the no-jelly property is unchanged. And .live-page carried
# overflow-y:hidden in portrait, clipping the Monitor page below the fold with no way to
# reach the rest; only landscape media queries re-enabled it.
#
# fix206: "Монитор листается, Профили не листаются" - a KernelSU-family WebView host that
# gesture-scrolls overflowing ELEMENTS but not the document. Home was the last
# document-scrolled page; it is now a self-scrolling fixed overlay like .live-page
# (element scroll works in every host, confirmed by the same user's Monitor). Centered
# with left/right:0 + margin:auto, NOT translateX(-50%): the prefers-reduced-motion block
# forces transform:none on .page:not(.live-page), so a translate centering would park the
# page half a width to the right there.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui page scroll: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP webui page scroll: no python3"; exit 0; }
python3 - "$H" <<'P' || exit 1
import re, sys
h = open(sys.argv[1], encoding='utf-8').read()
bad = []
m = re.search(r'\nhtml, body \{(.*?)\n\}', h, re.S)
if not m: bad.append('the html, body rule is gone')
else:
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    if re.search(r'(^|\s)height\s*:\s*100%', body):
        bad.append('html/body are a fixed 100% again - body becomes the only scroller and the document does not scroll')
    if 'min-height: 100%' not in body: bad.append('html/body lost min-height: 100%')
lp = re.search(r'\n\.live-page \{\n  position: fixed;(.*?)\n\}', h, re.S)
if not lp: bad.append('the main .live-page rule is gone')
else:
    body = re.sub(r'/\*.*?\*/', '', lp.group(1), flags=re.S)
    if 'overflow-y: auto' not in body: bad.append('the Monitor page cannot scroll in portrait again')
    if 'overflow-x: hidden' not in body: bad.append('the slide-in would flash a horizontal scrollbar track')
hp = re.search(r'\n\.page:not\(\.live-page\) \{\n  position: fixed;(.*?)\n\}', h, re.S)
if not hp: bad.append('home is not a fixed overlay - it is back to document scroll')
else:
    body = re.sub(r'/\*.*?\*/', '', hp.group(1), flags=re.S)
    if 'overflow-y: auto' not in body: bad.append('the home overlay cannot scroll itself')
    if 'overflow-x: hidden' not in body: bad.append('the home overlay can flash a horizontal scrollbar track')
    if 'margin: 0 auto' not in body: bad.append('the home overlay lost its margin:auto centering')
    if 'translateX(-50%)' in body: bad.append('translateX centering breaks under prefers-reduced-motion (transform:none)')
if 'body.live-active {\n  overflow: hidden;' not in h: bad.append('an open overlay no longer freezes the page under it')
if '.page:not(.live-page) > *:last-child' not in h: bad.append('the home overlay reserves no room for the floating bar at its end')
for b in bad: print('FAIL webui page scroll: ' + b, file=sys.stderr)
sys.exit(1 if bad else 0)
P
echo "PASS webui page scroll: every page is a self-scrolling overlay - element scroll works in every WebView host"
)

t_webui_log_report_runtime() (
# Runtime (fix194): the Logs menu grew a third entry, "Log report". It runs the REAL
# tools/logkit/asb_fullday_digest.sh - awk over the files the 24h recorder already wrote,
# no dumpsys - and explains the capture in plain words in a sheet: drain, what kept the
# phone awake, crashes, SystemUI restarts, throttling, plus advice. Works on the RUNNING
# capture (the digest folds in the open phase) and is not behind the debug-build gate.
# fix200 made the sheet much richer: it names a SAVED capture (start time + profile),
# adds smoothness with the real per-app frame table, the display-refresh split, the Smart
# learner's progress, ASB's own cost, speaker playback, charge types - and the advice can
# point at the exact Settings switch by name. Here: the digest over a fixture capture,
# the REAL parser/tips in node, the markup and all 13 locales.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
D="$ROOT/tools/logkit/asb_fullday_digest.sh"
fail() { echo "FAIL webui log report: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui log report: no node"; exit 0; }
[ -f "$D" ] || fail "tools/logkit/asb_fullday_digest.sh is missing"
sh -n "$D" || fail "digest script has a syntax error"
# fix231: Report and Device are fullscreen drill-ins, including when Liquid Glass opens
# them over Monitor/Config. Their opaque page surfaces must override the Glass tab rule.
grep -qF '#reportPage, #devicePage { background: var(--bg) !important; }' "$H" || fail "fullscreen report/device can inherit a transparent Glass page"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- fixture capture: 12h of phases, a 7.8h night chain at 1.0%/h, wakelocks, crashes ---
NOW=$(date +%s)
CAP="$T/asb_log_full_day_999"; mkdir -p "$CAP" "$T/tomb"
cat > "$CAP/phase_ledger.tsv" <<EOF
active	$((NOW-72000))	$((NOW-68400))	95	89	38	33	1800	42	0	0	-1	310	5000000	1200000	0
idle	$((NOW-68400))	$((NOW-64800))	89	88	31	29	400	0	0	5	12	40	0	0	0
sleep	$((NOW-64800))	$((NOW-43200))	88	82	30	28	0	0	0	0	8	35	1000000	200000	0
idle	$((NOW-43260))	$((NOW-40260))	82	81	31	29	400	0	0	0	10	45	0	0	0
charging	$((NOW-40000))	$((NOW-36400))	81	95	32	30	500	0	0	0	100	0	0	0	0
active	$((NOW-36000))	$((NOW-32400))	95	88	41	35	2100	55	0	0	-1	420	8000000	3000000	0
sleep	$((NOW-32400))	$((NOW-28800))	88	87	33	31	0	0	2	0	25	60	0	0	0
EOF
cat > "$CAP/battery_trace.txt" <<EOF
epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA
$((NOW-72000))|d|B|b|1|95|310
$((NOW-68400))|d|B|b|0|89|40
$((NOW-43200))|d|B|b|0|82|30
$((NOW-28800))|d|B|b|0|87|50
$((NOW-10000))|d|B|p|1|50|400
$((NOW-9900))|d|B|p|1|49|400
$((NOW-9800))|d|B|p|0|48|40
$((NOW-9700))|d|B|p|0|48|40
$((NOW-9600))|d|B|b|1|47|300
$((NOW-9500))|d|B|b|1|46|300
$((NOW-9400))|d|B|b|1|45|300
EOF
printf '10123 3661\n10456 1830\n' > "$CAP/.wl_uid_delta"
printf '10123|com.instagram.android\n10456|com.whatsapp\n' > "$CAP/.uid_package_map.tsv"
printf '===== SYSTEMUI RESTART at a\nverdict: ok\n===== SYSTEMUI RESTART at b\nverdict: ok\n' > "$CAP/sysui_restarts.txt"
printf '%s|active|cap_owner=thermal|x\n%s|active|cap_owner=asb_governor|x\n' "$((NOW-71000))" "$((NOW-70000))" > "$CAP/throttle_trace.txt"
# fix200: the interim report the digest mines for smoothness, per-app frames, refresh
# split, ASB's own cost, speaker playback and charge types. Field order and indentation
# match the real writer: asbcost lines are indented, table rows are not.
cat > "$CAP/_full_day_report.txt" <<EOF
 ASB FULL-DAY REPORT — x
 capture: 24h target, 720 min elapsed
governor's gauge check: on screen-on windows current_now integrates to x0.34 of the SOC-derived drain (40 windows) - multiply screen-on mA by about 2.9; a gauge property, not the load
all screen-on intervals: 167  frames 366481  janky 5.1%  over 12.2 h
janky frames per second on screen: 2.50
phase            intervals    frames    janky  janky/s
post_wake               23     61234     7.3%     4.11
active                 144    305247     4.6%     2.01
ASB state        intervals    frames    janky  janky/s
MODERATE                40    100000     4.0%     2.20
LIGHT_IDLE             100    200000     5.6%     2.60
mixed                   27     66481     5.2%     2.40
the wake itself: 23 wake(s), last screen-on poll before each to the first after it - frames 61234, janky 7.3% (ordinary screen-on intervals: 5.1%)
  at the wakes, by app: com.android.systemui 1740 of 12000 janky (14.5%), com.ttt.nagram 900 of 20000 janky (4.5%)
app in front      frames   jank   jps
com.ttt.nagram    122186   7.0%   4.20
com.whatsapp       40211   1.2%   0.40
multi               9000  12.0%   9.00
com.android.systemui   30000   0.5%   0.10

refresh_hz  samples  share   avg_brightness%  avg_mA
 60  112  64%  30  264
 90   40  23%  34  301
120   23  13%  40  380
0-24  9  5%  200

  governor cpu             : 1851 ms/h
  physical writes          : 176/h
  timer wakeups            : 491/h
phase  dur_min  d_pct  pct/h  mA  note
 audio_spk_scr  72  6.0  8.31  362  x
 active  400  10.0  1.50  200  x

  charge types seen        : Fast(17) N/A(197)

----- LIVE WAKELOCK HOLDERS (power-manager samples, screen off) -----
screen-off samples: 200
  held in  40% of samples, longest hold   12 min  *job*r/com.instagram.android/.job.Sync  (com.instagram.android)
  held in   9% of samples, longest hold    3 min  AudioMix  (com.google.android.youtube)

always-on display: 11 of 520 screen-off samples had the panel lit (10 with Android display state doze)
ltpo_video (lifetime): lowered 79 times, 11 min at the lower rate, 79 restored by touch
kernel holder on the charger: rx_wake_lock 343 min
kernel holder on the charger: qcom_rx_wakelock 13 min
EOF
# fix210: the capture's own wakelock report - counts by occurrence, the facts the sheet
# names when the held-time counters are flat.
cat > "$CAP/_wakelock_report.txt" <<EOF
WAKELOCK REPORT x

----- TOP PARTIAL WAKELOCK HOLDERS -----
  x54   taken  *alarm*
  x28   taken  *launch*
  x2    taken  tinyrare
----- TOP ALARM / WAKEUP SOURCES -----
  x18    *walarm*:com.android.systemui.aod.HIDE_TIME
  x6    *walarm*:android.app.backup.FullBackupJob
  x1    *walarm*:once.is.not.enough
----- end -----
EOF
printf 'current_profile: smart\n' > "$CAP/env.txt"
# fix213 (audit 8.1): the device context the page shows - the recorder writes these into
# env.txt when the capture starts, the digest projects them as meta2.
cat >> "$CAP/env.txt" <<EOF
model:           CPH2745
device:          OP611FL1
soc_model:       SM8850
oem_build:       CPH2745_16.0.10.601(EX01)
module_version:  V65-test
EOF
cat > "$CAP/smart_records.txt" <<EOF
smooth|watching=3|testing=0|helped=0|not_helped=0
off_night|ok|1760000000
on_light_dim|ok|1760000001
off_day|measuring|1760000002
microwake|learned=14|nights=9|per_night=2.6|typical_s=38|usual=03:00-03:30
EOF
printf 'Cmdline: com.crashy.app\nsignal 11\n' > "$T/tomb/tombstone_01"; touch -d "@$((NOW-4000))" "$T/tomb/tombstone_01"
printf 'Cmdline: /vendor/bin/hw/foo\nlibasbdsp x\n' > "$T/tomb/tombstone_02"; touch -d "@$((NOW-3000))" "$T/tomb/tombstone_02"
printf 'Cmdline: old.crash\n' > "$T/tomb/tombstone_03"; touch -d "@$((NOW-200000))" "$T/tomb/tombstone_03"

out="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$T/state0" sh "$D" "$CAP")" || fail "digest exit"
printf '%s\n' "$out" | grep -Eq '^meta	elapsed_min=720	target_h=24	running=0	started=[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}	profile=smart$' || fail "meta line: $(printf '%s' "$out" | head -1)"
printf '%s\n' "$out" | grep -qF "capture	dir=$CAP" || fail "capture path for report.json export"
printf '%s\n' "$out" | grep -q '^drain	pctph=2.0	total_drop=22	hours=10.8	ma=99$' || fail "drain line"
printf '%s\n' "$out" | grep -q '^night	dur_min=469	drop=8	pctph=1.0	awake=8$' || fail "night chain"
# fix207: the night chain's detail rides along - weighted average current, mobile
# traffic, peak temperatures and the wakeup-source peak of the SAME best chain.
printf '%s\n' "$out" | grep -q '^nightd	ma=36	radio_mib=1.1	cpu_t=31	skin_t=29	wake_pk=5$' || fail "night detail: $(printf '%s\n' "$out" | grep '^nightd')"
printf '%s\n' "$out" | grep -q '^idlemax	awake=25	phase=sleep	dur_min=60$' || fail "idlemax"
printf '%s\n' "$out" | grep -q '^wl	pkg=com.instagram.android	sec=3661$' || fail "top wakelock app"
printf '%s\n' "$out" | grep -Eq '^crash	count=2	asb=1	latest=/vendor/bin/hw/foo	ltime=[0-9]{2}:[0-9]{2}$' || fail "crash window, ASB attribution or the crash time"
printf '%s\n' "$out" | grep -q '^sysui	count=2$' || fail "sysui restarts"
printf '%s\n' "$out" | grep -q '^thermal	cpu=41	surf=35$' || fail "thermal peaks"
# fix213: device context, heat durations and night habits ride the same digest.
printf '%s\n' "$out" | grep -q '^meta2	model=CPH2745	device=OP611FL1	soc=SM8850	rom=CPH2745_16.0.10.601(EX01)	mod=V65-test$' || fail "meta2 device context: $(printf '%s\n' "$out" | grep '^meta2')"
printf '%s\n' "$out" | grep -q '^heat	peak_phase=active	peak_c=41	warm_min=0	skin_min=0$' || fail "heat detail: $(printf '%s\n' "$out" | grep '^heat')"
printf '%s\n' "$out" | grep -q '^mwake	n=14	per_night=2.6	typical_s=38$' || fail "night habits: $(printf '%s\n' "$out" | grep '^mwake')"
printf '%s\n' "$out" | grep -q '^cfg	key=sustained_temp_mode	value=' || fail "the thermal setting is not in the advice snapshot"
printf '%s\n' "$out" | grep -q '^throttle	clamps=2	owner=asb_governor	by=asb_governor:1,thermal:1$' || fail "throttle clamp periods: $(printf '%s\n' "$out" | grep '^throttle')"
printf '%s\n' "$out" | grep -q '^radio	mib=17.5$' || fail "radio MiB"
# fix200: the richer sections, mined from the interim report + smart_records + config.
printf '%s\n' "$out" | grep -q '^jank	pct=5.1	jps=2.50	frames=366481$' || fail "jank headline"
# fix220: wake smoothness, the per-phase and per-state jank tables and the gauge check.
printf '%s\n' "$out" | grep -q '^jwake	wakes=23	pct=7.3	ord=5.1	frames=61234	top=com.android.systemui	top_pct=14.5$' || fail "wake jank line: $(printf '%s\n' "$out" | grep '^jwake')"
printf '%s\n' "$out" | grep -q '^jphase	phase=post_wake	intv=23	frames=61234	pct=7.3	jps=4.11$' || fail "phase jank row: $(printf '%s\n' "$out" | grep '^jphase' | head -1)"
printf '%s\n' "$out" | grep -q '^jphase	phase=active	intv=144	frames=305247	pct=4.6	jps=2.01$' || fail "phase jank row 2"
printf '%s\n' "$out" | grep -q '^jstate	state=LIGHT_IDLE	intv=100	frames=200000	pct=5.6	jps=2.60$' || fail "state jank row: $(printf '%s\n' "$out" | grep '^jstate' | head -2 | tail -1)"
printf '%s\n' "$out" | grep -q '^jstate	state=mixed	intv=27	frames=66481	pct=5.2	jps=2.40$' || fail "the lowercase mixed state row"
printf '%s\n' "$out" | grep -q '^gauge	factor=0.34	windows=40	mult=2.9$' || fail "gauge line: $(printf '%s\n' "$out" | grep '^gauge')"
printf '%s\n' "$out" | grep -q '^japp	pkg=com.ttt.nagram	frames=122186	pct=7.0$' || fail "top jank app"
printf '%s\n' "$out" | grep -q '^japp	pkg=multi' && fail "the split-screen pseudo-app must not become a row"
printf '%s\n' "$out" | grep -q '^hz	mode=60	share=64	ma=264$' || fail "60 Hz row"
printf '%s\n' "$out" | grep -q '^hz	mode=120	share=13	ma=380$' || fail "120 Hz row"
printf '%s\n' "$out" | grep -q '^asbcost	cpu_msh=1851	writes_h=176	wakes_h=491$' || fail "ASB own cost"
printf '%s\n' "$out" | grep -q '^audio	spk_min=72	pctph=8.31	ma=362$' || fail "speaker audio cost"
printf '%s\n' "$out" | grep -q '^charge	types=Fast(17) N/A(197)$' || fail "charge types"
printf '%s\n' "$out" | grep -q '^smart	watching=3	testing=0	helped=0	nothelped=0	ctxlearn=2$' || fail "smart learner line"
printf '%s\n' "$out" | grep -q '^cfg	key=wakelock_action	value=0$' || fail "cfg snapshot for wakelock_action"
printf '%s\n' "$out" | grep -q '^cfg	key=night_modem_idle	value=0$' || fail "cfg snapshot for night_modem_idle"
# fix206: live wakelock holders from the power-manager samples, per-profile drain from
# the trace's profile field, charging sessions from the ledger, LTPO and AOD from the
# report - the facts the old sheet hid (a holder behind a flat batterystats delta, a day
# on 5W wireless, a profile comparison).
printf '%s\n' "$out" | grep -q '^wlive	tag=job.Sync	pct=40	min=12	pkg=com.instagram.android$' || fail "live holder row: $(printf '%s\n' "$out" | grep '^wlive' | head -1)"
printf '%s\n' "$out" | grep -q '^wlive	tag=AudioMix	pct=9	min=3	pkg=com.google.android.youtube$' || fail "live holder row 2"
printf '%s\n' "$out" | grep -q '^prof	name=p	on_min=3	off_min=3	on_pctph=36.0	off_pctph=18.0$' || fail "per-profile row p: $(printf '%s\n' "$out" | grep '^prof' | head -1)"
printf '%s\n' "$out" | grep -q '^prof	name=b	on_min=3	off_min=0	on_pctph=36.0	off_pctph=0.0$' || fail "per-profile row b"
printf '%s\n' "$out" | grep -q '^chg	min=60	gain=14	sess=1$' || fail "charging sessions: $(printf '%s\n' "$out" | grep '^chg')"
printf '%s\n' "$out" | grep -q '^ltpo	n=79	min=11$' || fail "ltpo line"
printf '%s\n' "$out" | grep -q '^aod	lit=11	of=520$' || fail "aod line"
# fix207: the screen on/off split over the whole ledger (the figure that reconciles with
# Monitor's tile), the per-phase breakdown and the kernel holders on the charger.
printf '%s\n' "$out" | grep -q '^scr	on_pctph=6.5	off_pctph=1.0	on_min=120	off_min=530$' || fail "screen split: $(printf '%s\n' "$out" | grep '^scr')"
printf '%s\n' "$out" | grep -q '^phase	name=sleep	min=420	drop=7	pctph=1.0$' || fail "phase sleep: $(printf '%s\n' "$out" | grep '^phase' | head -1)"
printf '%s\n' "$out" | grep -q '^phase	name=active	min=120	drop=13	pctph=6.5$' || fail "phase active"
printf '%s\n' "$out" | grep -q '^phase	name=charging	min=60	drop=-14	pctph=0.0$' || fail "phase charging keeps its signed drop"
printf '%s\n' "$out" | grep -q '^kwk	tag=rx_wake_lock	min=343$' || fail "kernel holder on the charger"
printf '%s\n' "$out" | grep -q '^kwk	tag=qcom_rx_wakelock	min=13$' || fail "kernel holder 2"
# fix210: causes by occurrence - the holders and alarms the capture counted, and the
# idle/sleep radio split off the day-wide total. Rows under the count floor stay out.
printf '%s\n' "$out" | grep -q '^wlt	tag=\*alarm\*	n=54$' || fail "holder row: $(printf '%s\n' "$out" | grep '^wlt' | head -1)"
printf '%s\n' "$out" | grep -q '^wlt	tag=\*launch\*	n=28$' || fail "holder row 2"
printf '%s\n' "$out" | grep -q 'tinyrare' && fail "a holder under the count floor leaked"
printf '%s\n' "$out" | grep -q '^wla	tag=com.android.systemui.aod.HIDE_TIME	n=18$' || fail "alarm row: $(printf '%s\n' "$out" | grep '^wla' | head -1)"
printf '%s\n' "$out" | grep -q '^wla	tag=android.app.backup.FullBackupJob	n=6$' || fail "alarm row 2"
printf '%s\n' "$out" | grep -q 'once.is.not.enough' && fail "an alarm under the count floor leaked"
printf '%s\n' "$out" | grep -q '^sradio	mib=1.1$' || fail "idle radio split: $(printf '%s\n' "$out" | grep '^sradio')"
# fix218: a sub-two-minute screen-off pause ("gap") can carry the day's peak reading -
# the pause inherits the heat of whatever surrounded it, so it must not be NAMED the
# hottest phase (a field capture read "Hottest phase: Recording gap" over a 3-minute
# gap). The true peak temperature still reports; the name falls to the hottest named
# phase, and the sheet shows that phase's own peak next to it.
GAPP="$T/asb_log_full_day_gap"; mkdir -p "$GAPP"
cat > "$GAPP/phase_ledger.tsv" <<EOF
active	$((NOW-6000))	$((NOW-4800))	90	88	41	35	1800	20	0	0	-1	300	0	0	0
gap	$((NOW-4800))	$((NOW-4680))	88	88	52	33	1700	0	0	0	100	450	0	0	0
EOF
gout="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$T/state4" sh "$D" "$GAPP")" || fail "gap fixture digest exit"
printf '%s\n' "$gout" | grep -q '^thermal	cpu=52	surf=35$' || fail "the true peak still reports: $(printf '%s\n' "$gout" | grep '^thermal')"
printf '%s\n' "$gout" | grep -q '^heat	peak_phase=active	peak_c=41	warm_min=2	skin_min=0$' || fail "a gap must not be named the hottest phase: $(printf '%s\n' "$gout" | grep '^heat')"
grep -qF "((+heat.peak_c || 0) > 0 ? ' · ' + String(+heat.peak_c) + '°' : '')" "$H" || fail "the hottest-phase row lost its peak temperature"
grep -qF ".replace(/\//g, '/\u2060');" "$H" || fail "the phase drain cell can orphan its unit again"
# fix219: the throttle owner was the LAST period's owner - a capture with 3 ASB, 6
# vendor, 6 shell and 1 unknown period showed "16 (asb)". The owner is the one with
# the most periods now (the more recent wins a tie), and the split rides along.
THR="$T/asb_log_full_day_thr"; mkdir -p "$THR"
cat > "$THR/throttle_trace.txt" <<EOF
$((NOW-10000))|active|cap_owner=vendor|x
$((NOW-9900))|active|cap_owner=asb|x
$((NOW-9800))|active|cap_owner=vendor|x
EOF
tout="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$T/state5" sh "$D" "$THR")" || fail "throttle fixture digest exit"
printf '%s\n' "$tout" | grep -q '^throttle	clamps=3	owner=vendor	by=vendor:2,asb:1$' || fail "the owner must be the majority, not the last: $(printf '%s\n' "$tout" | grep '^throttle')"
grep -qF "const names = { asb: 'ASB', asb_governor: 'ASB', vendor: 'ROM', shell: 'profile', thermal: 'ROM thermal', unknown: '?' };" "$H" || fail "the sheet no longer names every throttle owner"
[ "$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_STATE_DIR="$T/state1" sh "$D" "$T/no-such-dir")" = "error	no_capture" ] || fail "missing capture must say error no_capture"
EMPTY="$T/empty"; mkdir -p "$EMPTY"
eout="$(ASB_TOMBSTONE_DIR="$T/empty-tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$T/state2" sh "$D" "$EMPTY")"
printf '%s\n' "$eout" | grep -q '^meta	' || fail "an empty capture still reports meta"
printf '%s\n' "$eout" | grep -q '^wl	none=1$' || fail "an empty capture reports no wakelocks"
printf '%s\n' "$eout" | grep -q '^drain	' && fail "an empty capture must not invent drain numbers"

# fix204: a capture that JUST started has neither the ledger nor the interim report (the
# first snapshot lands after fifteen minutes). Its crash window must open at the
# capture's launch (the lock's pid-file mtime), not "24h ago" - otherwise tombstones from
# BEFORE the capture show at minute 0 and then vanish once the first ledger row lands
# (the user's com.oplus.screenshot crashes from before the recording did exactly that).
FRESH="$T/asb_log_full_day_fresh"; mkdir -p "$FRESH" "$T/lock2"
printf '%s\n' "$FRESH" > "$T/lock2/output_dir"
sleep 30 & _lp=$!
printf '%s\n' "$_lp" > "$T/lock2/pid"
touch -d "@$((NOW-600))" "$T/lock2/pid"   # launched ten minutes ago
printf 'Cmdline: com.oplus.screenshot\n' > "$T/tomb/tombstone_07"; touch -d "@$((NOW-4000))" "$T/tomb/tombstone_07"
printf 'Cmdline: fresh.crash\n' > "$T/tomb/tombstone_08"; touch -d "@$((NOW-300))" "$T/tomb/tombstone_08"
fout="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/lock2" ASB_LK_STATE_DIR="$T/state3" sh "$D" "$FRESH")"
kill "$_lp" 2>/dev/null || true; wait "$_lp" 2>/dev/null || true
printf '%s\n' "$fout" | grep -q '^meta	elapsed_min=0	target_h=24	running=1' || fail "the fresh capture must read as running: $(printf '%s' "$fout" | head -1)"
printf '%s\n' "$fout" | grep -Eq '^crash	count=1	asb=0	latest=fresh.crash	ltime=[0-9]{2}:[0-9]{2}$' || fail "a fresh capture's crash window must start at its launch, not 24h ago: $(printf '%s' "$fout" | grep '^crash')"
# The ledger may lead with a "# phase ..." comment: the window must read the first DATA
# row, not the comment. The main fixture's ledger has no comment, so pin it here.
CMNT="$T/asb_log_full_day_cmnt"; mkdir -p "$CMNT"
printf '# phase start end ...\nactive	%s	%s	95	89\n' "$((NOW-72000))" "$((NOW-68400))" > "$CMNT/phase_ledger.tsv"
cout="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$T/state4" sh "$D" "$CMNT")"
printf '%s\n' "$cout" | grep -Eq '^crash	count=4	asb=1	latest=fresh.crash' || fail "the window must skip the ledger's comment header: $(printf '%s' "$cout" | grep '^crash')"

# fix213 (audit 8.2): a finished capture leaves one compact line in report_history.tsv,
# and the NEXT capture's digest carries the earlier one as a hist row - that is the trend
# the page renders. Keyed by the capture's start minute: re-opening the same capture
# rewrites its line instead of duplicating it.
HST="$T/hist_state"
CB="$T/asb_log_full_day_b"; mkdir -p "$CB"
awk -F'\t' 'BEGIN{OFS="\t"} {$2=$2-100000; $3=$3-100000; print}' "$CAP/phase_ledger.tsv" > "$CB/phase_ledger.tsv"
ra="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$HST" sh "$D" "$CAP")"
printf '%s\n' "$ra" | grep -q '^hist	' && fail "the first finished capture must not invent a trend"
[ -s "$HST/report_history.tsv" ] || fail "a finished capture left no history line"
rb="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$HST" sh "$D" "$CB")"
printf '%s\n' "$rb" | grep -Eq '^hist	started=[0-9-]+ [0-9:]+	night=1.0	drain=2.0	jank=5.1	cpu=41	clamps=2	device=OP611FL1	rom=CPH2745_16.0.10.601\(EX01\)	mod=V65-test	elapsed=720	on_pct=0	off_min=1036$' || fail "the second capture must name the first with comparison context: $(printf '%s\n' "$rb" | grep '^hist')"
ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$HST" sh "$D" "$CAP" >/dev/null
[ "$(wc -l < "$HST/report_history.tsv")" -eq 2 ] || fail "re-opening the same capture must rewrite its line, not duplicate it"
rc="$(ASB_TOMBSTONE_DIR="$T/tomb" ASB_LK_LOCK="$T/nolock" ASB_LK_STATE_DIR="$HST" sh "$D" "$CAP")"
# capture B has no report and no throttle trace: its trend line carries dashes, and a
# dash must not break the row or count as a number.
printf '%s\n' "$rc" | grep -Eq '^hist	started=[0-9-]+ [0-9:]+	night=1.0	drain=2.0	jank=-	cpu=41	clamps=-	device=-	rom=-	mod=-	elapsed=2866	on_pct=-	off_min=-$' || fail "a capture without jank data still trends, with dashes and explicit unknown context: $(printf '%s\n' "$rc" | grep '^hist')"

# --- the REAL parser/tips in node, fed the fixture digest and the shipped locales ---
{
  printf 'const I18N = { en: %s, ru: %s };\n' "$(cat "$ROOT/webroot/i18n/en.json")" "$(cat "$ROOT/webroot/i18n/ru.json")"
  cat <<'EOF'
let ASB_LANG = 'ru';
function T(k, d) { const L = I18N[ASB_LANG]; return (L && typeof L[k] === 'string') ? L[k] : d; }
EOF
  for fn in Tcfg parseLogReport logReportT logReportDur logReportDurSec logReportTips \
    logReportScreenOnDrainState logReportAnalyze logReportHistoryComparable logReportMachineDigest logReportAnalysisT \
    logReportTipText logReportRow logReportSec logReportNote logReportHero \
    logReportAppendAnalysis logReportRender shQuote; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  sed -n '/^async function logReportExportJson(/,/^}/p' "$H"
  cat <<'EOF'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
const txt = [
  'meta\telapsed_min=720\ttarget_h=24\trunning=1\tstarted=2026-10-21 09:40\tprofile=smart',
  'meta2\tmodel=CPH2745\tdevice=OP611FL1\tsoc=SM8850\trom=TESTBUILD\tmod=V65-test',
  'capture\tdir=/storage/emulated/0/asb_log_full_day_test',
  'heat\tpeak_phase=active\tpeak_c=41\twarm_min=0\tskin_min=0',
  'mwake\tn=14\tper_night=2.6\ttypical_s=38',
  'hist\tstarted=2026-10-20 09:10\tnight=0.6\tdrain=2.4\tjank=5.1\tcpu=41\tclamps=2',
  'cover\ton_min=200\toff_min=520\ton_pct=27',
  'drain\tpctph=2.0\ttotal_drop=22\thours=10.8\tma=99',
  'night\tdur_min=469\tdrop=8\tpctph=1.0\tawake=8',
  'nightd\tma=36\tradio_mib=1.1\tcpu_t=31\tskin_t=29\twake_pk=5',
  'idlemax\tawake=25\tphase=sleep\tdur_min=60',
  'thermal\tcpu=41\tsurf=35',
  'radio\tmib=17.5',
  'wl\tpkg=com.instagram.android\tsec=3661',
  'wl\tpkg=com.whatsapp\tsec=1830',
  'wlive\ttag=TgWsProxy::ServiceWakeLock\tpct=78\tmin=24\tpkg=com.amurcanov.tgwsproxy',
  'wlive\ttag=com.android.server.MountServiceIdler\tpct=23\tmin=9\tpkg=',
  'prof\tname=performance\ton_min=236\toff_min=296\ton_pctph=6.1\toff_pctph=0.6',
  'prof\tname=balanced\ton_min=116\toff_min=118\ton_pctph=5.2\toff_pctph=3.0',
  'chg\tmin=402\tgain=63\tsess=10',
  'ltpo\tn=79\tmin=11',
  'aod\tlit=11\tof=520',
  'scr\ton_pctph=5.7\toff_pctph=1.8\ton_min=401\toff_min=478',
  'phase\tname=sleep\tmin=304\tdrop=8\tpctph=1.6',
  'phase\tname=charging_idle\tmin=397\tdrop=-62\tpctph=0.0',
  'kwk\ttag=rx_wake_lock\tmin=343',
  'wlt\ttag=*alarm*\tn=54',
  'wlt\ttag=*launch*\tn=28',
  'wla\ttag=com.android.systemui.aod.HIDE_TIME\tn=18',
  'wla\ttag=android.app.backup.FullBackupJob\tn=6',
  'sradio\tmib=1.1',
  'crash\tcount=2\tasb=1\tlatest=/vendor/bin/hw/foo\tltime=14:32',
  'sysui\tcount=2',
  'throttle\tclamps=2\towner=asb_governor\tby=asb_governor:1,thermal:1',
  'jank\tpct=1.4\tjps=0.6\tframes=366481',
  'jwake\twakes=23\tpct=7.3\tord=5.1\tframes=61234\ttop=com.android.systemui\ttop_pct=14.5',
  'jphase\tphase=post_wake\tintv=23\tframes=61234\tpct=7.3\tjps=4.11',
  'jphase\tphase=active\tintv=144\tframes=305247\tpct=4.6\tjps=2.01',
  'jstate\tstate=MODERATE\tintv=40\tframes=100000\tpct=4.0\tjps=2.20',
  'jstate\tstate=LIGHT_IDLE\tintv=100\tframes=200000\tpct=5.6\tjps=2.60',
  'gauge\tfactor=0.34\twindows=40\tmult=2.9',
  'japp\tpkg=com.ttt.nagram\tframes=122186\tpct=7.0',
  'japp\tpkg=com.whatsapp\tframes=40211\tpct=1.2',
  'hz\tmode=60\tshare=64\tma=264',
  'hz\tmode=90\tshare=23\tma=301',
  'hz\tmode=120\tshare=13\tma=380',
  'asbcost\tcpu_msh=1851\twrites_h=176\twakes_h=491',
  'audio\tspk_min=72\tpctph=8.31\tma=362',
  'charge\ttypes=Fast(17) N/A(197)',
  'smart\twatching=3\ttesting=0\thelped=0\tnothelped=0\tctxlearn=2',
  'cfg\tkey=wakelock_action\tvalue=0',
  'cfg\tkey=night_modem_idle\tvalue=0',
  'cfg\tkey=ltpo_video\tvalue=1',
  ''].join('\n');
const d = parseLogReport(txt);
chk(d.ok === true, 'fixture digest parses');
chk(d.sections.meta.running === '1' && d.sections.meta.elapsed_min === '720', 'meta fields');
chk(d.sections.meta.started === '2026-10-21 09:40' && d.sections.meta.profile === 'smart', 'meta names when the capture ran and under which profile');
/* fix213: the new sections parse - device context, heat durations, night habits, and
   the earlier captures the trend compares against. */
chk(d.sections.meta2.model === 'CPH2745' && d.sections.meta2.soc === 'SM8850' && d.sections.meta2.mod === 'V65-test', 'meta2 device context parses: ' + JSON.stringify(d.sections.meta2));
chk(d.sections.heat.peak_phase === 'active' && d.sections.heat.peak_c === '41' && d.sections.heat.warm_min === '0' && d.sections.heat.skin_min === '0', 'heat detail parses: ' + JSON.stringify(d.sections.heat));
chk(d.sections.throttle.by === 'asb_governor:1,thermal:1', 'fix219: the per-owner throttle split parses: ' + JSON.stringify(d.sections.throttle));
chk(d.sections.mwake.n === '14' && d.sections.mwake.per_night === '2.6' && d.sections.mwake.typical_s === '38', 'night habits parse: ' + JSON.stringify(d.sections.mwake));
chk(d.hist.length === 1 && d.hist[0].started === '2026-10-20 09:10' && d.hist[0].night === '0.6' && d.hist[0].drain === '2.4' && d.hist[0].clamps === '2', 'history rows parse: ' + JSON.stringify(d.hist));
chk(d.sections.drain.pctph === '2.0' && d.sections.night.dur_min === '469', 'drain/night fields');
chk(d.wl.length === 2 && d.wl[0].pkg === 'com.instagram.android' && d.wl[0].sec === 3661, 'wakelock rows: ' + JSON.stringify(d.wl));
chk(d.japps.length === 2 && d.japps[0].pkg === 'com.ttt.nagram' && d.japps[0].frames === 122186 && d.japps[0].pct === 7, 'per-app jank rows: ' + JSON.stringify(d.japps));
chk(d.hzs.length === 3 && d.hzs[0].mode === '60' && d.hzs[0].ma === 264 && d.hzs[2].share === 13, 'refresh rows: ' + JSON.stringify(d.hzs));
chk(d.cfg.wakelock_action === '0' && d.cfg.night_modem_idle === '0' && d.cfg.ltpo_video === '1', 'cfg snapshot: ' + JSON.stringify(d.cfg));
chk(d.sections.jank.pct === '1.4' && d.sections.audio.spk_min === '72' && d.sections.smart.ctxlearn === '2' && d.sections.asbcost.cpu_msh === '1851' && d.sections.charge.types === 'Fast(17) N/A(197)', 'the fix200 sections parse');
/* fix220: wake jank, the per-phase/per-state tables and the gauge parse. */
chk(d.sections.jwake.wakes === '23' && d.sections.jwake.pct === '7.3' && d.sections.jwake.ord === '5.1' && d.sections.jwake.top === 'com.android.systemui' && d.sections.jwake.top_pct === '14.5', 'wake jank parses: ' + JSON.stringify(d.sections.jwake));
chk(d.jphases.length === 2 && d.jphases[0].phase === 'post_wake' && d.jphases[0].pct === 7.3 && d.jphases[1].jps === 2.01, 'per-phase jank rows: ' + JSON.stringify(d.jphases));
chk(d.jstates.length === 2 && d.jstates[0].state === 'MODERATE' && d.jstates[1].pct === 5.6, 'per-state jank rows: ' + JSON.stringify(d.jstates));
chk(d.sections.gauge.factor === '0.34' && d.sections.gauge.windows === '40' && d.sections.gauge.mult === '2.9', 'the gauge check parses: ' + JSON.stringify(d.sections.gauge));
chk(d.sections.crash.ltime === '14:32', 'fix204: the crash time survives the parser');
/* fix206: the new digest facts parse. */
chk(d.wlive.length === 2 && d.wlive[0].pkg === 'com.amurcanov.tgwsproxy' && d.wlive[0].pct === 78 && d.wlive[0].min === 24, 'live wakelock rows: ' + JSON.stringify(d.wlive));
chk(d.wlive[1].pkg === '' && d.wlive[1].tag === 'com.android.server.MountServiceIdler', 'a system holder keeps the tag and no package');
chk(d.profs.length === 2 && d.profs[0].name === 'performance' && d.profs[0].onP === 6.1 && d.profs[1].offP === 3, 'per-profile rows: ' + JSON.stringify(d.profs));
chk(d.sections.chg.min === '402' && d.sections.chg.gain === '63' && d.sections.chg.sess === '10', 'charging line parses');
chk(d.sections.ltpo.n === '79' && d.sections.ltpo.min === '11', 'ltpo line parses');
chk(d.sections.aod.lit === '11' && d.sections.aod.of === '520', 'aod line parses');
/* fix207: the screen split, the phase table and the kernel charger holders parse. */
chk(d.sections.scr.on_pctph === '5.7' && d.sections.scr.off_pctph === '1.8' && d.sections.scr.off_min === '478', 'screen split parses');
chk(d.phases.length === 2 && d.phases[0].name === 'sleep' && d.phases[0].drop === 8 && d.phases[1].drop === -62, 'phase rows keep the signed drop: ' + JSON.stringify(d.phases));
chk(d.kwk.length === 1 && d.kwk[0].tag === 'rx_wake_lock' && d.kwk[0].min === 343, 'kernel charger holder parses');
/* fix210: the occurrence-counted causes parse too. */
chk(d.wlt.length === 2 && d.wlt[0].tag === '*alarm*' && d.wlt[0].n === 54 && d.wlt[1].n === 28, 'holder rows: ' + JSON.stringify(d.wlt));
chk(d.wla.length === 2 && d.wla[0].tag === 'com.android.systemui.aod.HIDE_TIME' && d.wla[0].n === 18, 'alarm rows: ' + JSON.stringify(d.wla));
chk(d.sections.sradio.mib === '1.1', 'the idle radio split parses');
chk(d.sections.nightd.ma === '36' && d.sections.nightd.radio_mib === '1.1' && d.sections.nightd.cpu_t === '31' && d.sections.nightd.skin_t === '29' && d.sections.nightd.wake_pk === '5', 'night detail parses: ' + JSON.stringify(d.sections.nightd));
/* fix207: the profile-saving tip fires on the tester's own numbers (Battery at 1.6 %/h
   against Performance at 6.1 %/h, both with enough screen-on minutes). */
const dps = { sections: { meta: {} }, wl: [], wlive: [], japps: [], hzs: [], cfg: {},
  profs: [{ name: 'performance', onMin: 236, offMin: 296, onP: 6.1, offP: 0.6 },
          { name: 'balanced', onMin: 116, offMin: 118, onP: 5.2, offP: 3.0 },
          { name: 'battery', onMin: 37, offMin: 130, onP: 1.6, offP: 0.9 }] };
const pst = logReportTips(dps).filter(function (t) { return t.key === 'lr_tip_prof_save'; });
chk(pst.length === 1 && pst[0].vars.x === '1.6' && pst[0].vars.y === '6.1' && pst[0].vars.cheap === I18N.ru.prof_battery, 'the profile-saving tip: ' + JSON.stringify(pst));
dps.profs[2].onMin = 10;
chk(!logReportTips(dps).some(function (t) { return t.key === 'lr_tip_prof_save'; }), 'the tip stays quiet without enough minutes on the cheap profile');
const tips = logReportTips(d);
const keys = tips.map(function (t) { return t.key; });
chk(keys.join(',') === 'lr_tip_crash,lr_tip_night_modem,lr_tip_awake_who,lr_tip_wl_enable,lr_tip_jank_ok,lr_tip_audio', 'fix200 advice, worst first, six cards max, the awake tip names its holder (fix206): ' + keys.join(','));
chk(tips[2].vars.who === 'com.amurcanov.tgwsproxy' && tips[2].vars.awake === '25', 'the awake tip names the top live holder: ' + JSON.stringify(tips[2].vars));
/* without live holders the awake tip names the counted causes (fix210): the loudest
   alarm first, then the loudest holder, then the generic wording */
d.wlive = [];
const tipA = logReportTips(d).filter(function (t) { return t.key === 'lr_tip_awake_alarm'; });
chk(tipA.length === 1 && tipA[0].vars.who === 'com.android.systemui.aod.HIDE_TIME' && tipA[0].vars.awake === '25', 'no live holders - the tip names the loudest alarm: ' + JSON.stringify(tipA));
d.wla = [];
const tipH = logReportTips(d).filter(function (t) { return t.key === 'lr_tip_awake_hold'; });
chk(tipH.length === 1 && tipH[0].vars.who === '*alarm*', 'no alarms either - the tip names the loudest holder: ' + JSON.stringify(tipH));
d.wlt = [];
chk(logReportTips(d).map(function (t) { return t.key; }).indexOf('lr_tip_awake') >= 0, 'no causes at all - the generic awake tip');
d.wlt = [{ tag: '*alarm*', n: 54 }, { tag: '*launch*', n: 28 }];
d.wla = [{ tag: 'com.android.systemui.aod.HIDE_TIME', n: 18 }, { tag: 'android.app.backup.FullBackupJob', n: 6 }];
d.wlive = [{ tag: 'TgWsProxy::ServiceWakeLock', pct: 78, min: 24, pkg: 'com.amurcanov.tgwsproxy' }];
chk(tips[1].vars.set === I18N.ru.cfg.night_modem_idle.name, 'the night-modem tip names the setting as Settings names it: ' + tips[1].vars.set);
chk(tips[3].vars.set === I18N.ru.cfg.wakelock_action.name, 'the wakelock tip names its setting too: ' + tips[3].vars.set);
d.cfg.wakelock_action = '1';
const keys2 = logReportTips(d).map(function (t) { return t.key; });
chk(keys2.indexOf('lr_tip_app') >= 0 && keys2.indexOf('lr_tip_wl_enable') < 0, 'with the setting already on, the tip just reports the app: ' + keys2.join(','));
d.cfg.wakelock_action = '0';
d.sections.jank.pct = '7.2';
const keys3 = logReportTips(d).map(function (t) { return t.key; });
chk(keys3.indexOf('lr_tip_jank_bad') >= 0 && keys3.indexOf('lr_tip_jank_ok') < 0, 'a stuttery day advises higher refresh: ' + keys3.join(','));
d.sections.jank.pct = '1.4';
/* fix211: ASB's own cost is judged per wakeup, not per hour. The owner's BATTERY capture
   (3627 ms/h over 1203 wakeups/h = 3.0 ms a tick) must read cheap; a tick that costs 30 ms
   is the runaway the "send the log" tip exists for. */
/* The sheet shows at most six tips, so isolate the cost section from the fixture's
   other tip sources (crash, night, awake, jank, audio) - the verdict must come from
   asbcost alone. */
const dcost = function (cost) {
  const dc = JSON.parse(JSON.stringify(d));
  dc.sections = { asbcost: cost };
  dc.cfg = {}; dc.wl = []; dc.wlive = []; dc.wla = []; dc.wlt = []; dc.kwk = []; dc.profs = [];
  return logReportTips(dc).map(function (t) { return t.key; });
};
const dc1 = dcost({ cpu_msh: '3627', writes_h: '52', wakes_h: '1203' });
chk(dc1.indexOf('lr_tip_cost_ok') >= 0 && dc1.indexOf('lr_tip_cost_hi') < 0, 'a busy day at 3 ms a tick reads cheap: ' + dc1.join(','));
const dc2 = dcost({ cpu_msh: '9000', writes_h: '52', wakes_h: '300' });
chk(dc2.indexOf('lr_tip_cost_hi') >= 0, 'a 30 ms tick is the runaway: ' + dc2.join(','));
const dc3 = dcost({ cpu_msh: '12000', writes_h: '52' });
chk(dc3.indexOf('lr_tip_cost_hi') >= 0, 'a spin without wake data still trips on the absolute figure: ' + dc3.join(','));
/* fix213 (audit 8.3/К9): the heat advice. A long hot stretch advises (and names the
   thermal switch when the protection is on Stock); a cool day without a single throttle
   says so; a day WITH throttles never claims calm; a short warm spell stays quiet. */
const dheat = function (heat, thermal, throttle, cfg) {
  const dc = JSON.parse(JSON.stringify(d));
  dc.sections = { heat: heat, thermal: thermal, throttle: throttle };
  dc.cfg = cfg || {}; dc.wl = []; dc.wlive = []; dc.wla = []; dc.wlt = []; dc.kwk = []; dc.profs = [];
  dc.hist = [];
  return logReportTips(dc).map(function (t) { return t.key; });
};
const hh = { peak_phase: 'gaming', warm_min: '47', skin_min: '12' };
chk(dheat(hh, { cpu: '52' }, { clamps: '3' }, {}).indexOf('lr_tip_heat_warm') >= 0, 'a hot stretch advises: ' + dheat(hh, { cpu: '52' }, { clamps: '3' }, {}).join(','));
chk(dheat(hh, { cpu: '52' }, { clamps: '3' }, { sustained_temp_mode: 'stock' }).indexOf('lr_tip_heat_warm_set') >= 0, 'protection on Stock names the switch');
const hk1 = dheat({ peak_phase: 'active', warm_min: '0', skin_min: '0' }, { cpu: '41' }, { clamps: '0' }, {});
chk(hk1.indexOf('lr_tip_heat_calm') >= 0, 'a cool day without throttling says so: ' + hk1.join(','));
const hk2 = dheat({ peak_phase: 'active', warm_min: '0', skin_min: '0' }, { cpu: '41' }, { clamps: '2' }, {});
chk(hk2.indexOf('lr_tip_heat_calm') < 0, 'a cool day WITH throttles does not claim calm');
const hk3 = dheat({ peak_phase: 'active', warm_min: '12', skin_min: '0' }, { cpu: '46' }, { clamps: '0' }, {});
chk(hk3.indexOf('lr_tip_heat_warm') < 0 && hk3.indexOf('lr_tip_heat_calm') < 0, 'a short warm spell stays quiet');
chk(logReportT('lr_tip_heat_warm', '', { min: '47 мин', phase: 'Игры' }).indexOf('{') < 0, 'the heat tip fills its placeholders');
/* fix220: a short night is noise, not a verdict - under two hours no red card (the owner's
   Battery capture read "1.5 %/h over 40 min" off a single battery-percent step). */
const dn1 = JSON.parse(JSON.stringify(d));
dn1.sections = { night: { dur_min: '40', pctph: '1.5', awake: '20', drop: '1' } };
dn1.cfg = {}; dn1.wl = []; dn1.wlive = []; dn1.wla = []; dn1.wlt = []; dn1.kwk = []; dn1.profs = []; dn1.hist = [];
chk(!logReportTips(dn1).some(function (t) { return t.key.indexOf('lr_tip_night') === 0; }), 'a 40-minute night stretch draws no night tip');
dn1.sections.night.dur_min = '469';
chk(logReportTips(dn1).some(function (t) { return t.key === 'lr_tip_night'; }), 'a full night over 0.8 %/h still advises');
/* fix222: the awake verdict needs a stretch that can carry it (under 20 min: no tip), and
   when the top holder is SystemUI with the panel lit in a tenth or more of screen-off
   checks, the tip names the always-on display, not a system app (the owner's Smart day:
   awake 64 %, holder com.android.systemui, AOD 14 of 67). */
const daod = JSON.parse(JSON.stringify(d));
daod.sections = { idlemax: { awake: '64', phase: 'idle', dur_min: '45' }, aod: { lit: '14', of: '67' } };
daod.cfg = {}; daod.wl = []; daod.wla = []; daod.wlt = []; daod.kwk = []; daod.profs = []; daod.hist = [];
daod.wlive = [{ tag: 'AODDisplayUtil', pct: 20, min: 0, pkg: 'com.android.systemui' }];
const kaod = logReportTips(daod).map(function (t) { return t.key; });
chk(kaod.indexOf('lr_tip_awake_aod') >= 0 && kaod.indexOf('lr_tip_awake_who') < 0, 'SystemUI + AOD names the display: ' + kaod.join(','));
daod.wlive = [{ tag: 'TgWsProxy::ServiceWakeLock', pct: 78, min: 24, pkg: 'com.amurcanov.tgwsproxy' }];
const kna = logReportTips(daod).map(function (t) { return t.key; });
chk(kna.indexOf('lr_tip_awake_who') >= 0 && kna.indexOf('lr_tip_awake_aod') < 0, 'a real app holder is still named: ' + kna.join(','));
daod.sections.idlemax.dur_min = '10';
chk(!logReportTips(daod).some(function (t) { return t.key.indexOf('lr_tip_awake') === 0; }), 'a ten-minute stretch draws no awake tip');
daod.sections.aod.lit = '3';
daod.sections.idlemax.dur_min = '45';
daod.wlive = [{ tag: 'AODDisplayUtil', pct: 20, min: 0, pkg: 'com.android.systemui' }];
chk(logReportTips(daod).some(function (t) { return t.key === 'lr_tip_awake_who'; }), 'SystemUI without the AOD pattern is still blamed by name');
/* fix222: the background-traffic advice - over 50 MiB with the screen off, the switch
   named while it is off; quiet when it is already on or the traffic is modest. */
const dsr = JSON.parse(JSON.stringify(d));
dsr.sections = { sradio: { mib: '214.7' } };
dsr.cfg = { net_screen_off_lte: '0' }; dsr.wl = []; dsr.wlive = []; dsr.wla = []; dsr.wlt = []; dsr.kwk = []; dsr.profs = []; dsr.hist = [];
const ksr = logReportTips(dsr);
chk(ksr.some(function (t) { return t.key === 'lr_tip_sradio' && t.vars.mib === '214.7' && t.vars.set === I18N.ru.cfg.net_screen_off_lte.name; }), 'the traffic tip names its setting: ' + JSON.stringify(ksr));
dsr.cfg.net_screen_off_lte = '1';
chk(!logReportTips(dsr).some(function (t) { return t.key === 'lr_tip_sradio'; }), 'already on - no traffic tip');
delete dsr.cfg.net_screen_off_lte;
chk(logReportTips(dsr).some(function (t) { return t.key === 'lr_tip_sradio'; }), 'an old capture without the cfg snapshot is the shipped default (off)');
dsr.sections.sradio.mib = '12.0';
chk(!logReportTips(dsr).some(function (t) { return t.key === 'lr_tip_sradio'; }), 'modest background traffic draws no tip');
/* fix220: the wake-jank tip - wakes clearly worse than the day, the top wake app named;
   quiet when the wakes match the day, under the visible threshold, or on a thin sample. */
const djw = function (jwake) {
  const dc = JSON.parse(JSON.stringify(d));
  dc.sections = { jwake: jwake };
  dc.cfg = {}; dc.wl = []; dc.wlive = []; dc.wla = []; dc.wlt = []; dc.kwk = []; dc.profs = []; dc.hist = [];
  return logReportTips(dc).map(function (t) { return t.key; });
};
chk(djw({ wakes: '23', pct: '8.0', ord: '7.2', top: 'com.android.systemui' }).indexOf('lr_tip_jank_wake') >= 0, 'wake jank clearly above the day advises');
chk(djw({ wakes: '23', pct: '8.0', ord: '7.2', top: '' }).indexOf('lr_tip_jank_wake_wh') >= 0, 'no top app - the wording without a name');
chk(djw({ wakes: '14', pct: '4.8', ord: '4.2', top: 'com.android.systemui' }).indexOf('lr_tip_jank_wake') < 0, 'smooth wakes stay quiet');
chk(djw({ wakes: '3', pct: '12.0', ord: '5.0', top: '' }).indexOf('lr_tip_jank_wake_wh') < 0, 'three wakes are no pattern');
chk(Tcfg('ltpo_video', 'name', 'x') === I18N.ru.cfg.ltpo_video.name, 'Tcfg reads the locale setting name');
chk(logReportT('lr_saved', '', { when: '2026-10-21 09:40', profile: 'Умный' }) === I18N.ru.lr_saved.split('{when}').join('2026-10-21 09:40').split('{profile}').join('Умный'), 'ru saved-capture line fills both placeholders');
chk(logReportT('lr_tip_audio', '', { pct: '8.31' }).indexOf('{') < 0, 'the audio tip fills its placeholder');
chk(logReportT('lr_ms_h', '', { n: '1851' }).indexOf('1851') === 0, 'the ms/h unit formats: ' + logReportT('lr_ms_h', '', { n: '1851' }));
chk(logReportT('lr_running', 'recording \u00b7 {min} min of {h} h', { min: '720', h: '24' }) === 'идёт запись \u00b7 720 мин из 24 ч', 'ru running line');
chk(logReportT('lr_tip_night', '', { pct: '1.0' }) === I18N.ru.lr_tip_night.replace('{pct}', '1.0'), 'ru night tip fills its placeholder');
chk(logReportT('lr_tip_app', '', { app: 'com.instagram.android', min: '61' }).indexOf('com.instagram.android') >= 0, 'ru app tip names the app');
chk(logReportDur(469) === '7 ч 49 мин', 'ru duration: ' + logReportDur(469));
chk(logReportDur(45) === '45 мин', 'ru short duration');
chk(logReportDurSec(9) === '9 сек', 'ru sub-minute hold reads in seconds: ' + logReportDurSec(9));
chk(logReportDurSec(3661) === logReportDur(61), 'long holds still read in hours/minutes');
ASB_LANG = 'en';
chk(logReportDur(469) === '7 h 49 min', 'en duration: ' + logReportDur(469));
chk(logReportDurSec(8) === '8 sec', 'en sub-minute hold: ' + logReportDurSec(8));
const clean = parseLogReport('meta\telapsed_min=10\ttarget_h=24\trunning=1\nwl\tnone=1\ncrash\tcount=0\tasb=0\tlatest=none\nsysui\tcount=0\n');
const ct = logReportTips(clean);
chk(ct.length === 1 && ct[0].key === 'lr_tip_ok' && ct[0].ic === 'ok', 'a clean capture gets the ok tip: ' + JSON.stringify(ct));
chk(logReportT('lr_tip_ok', '', {}) === 'No serious issues found - drain looks healthy.', 'en ok tip');
chk(parseLogReport('error\tno_capture\n').error === 'no_capture', 'no_capture error survives the parser');
chk(parseLogReport('').error === 'empty', 'empty output is an error, not data');
chk(parseLogReport('wl\tnone=1\n').ok === false, 'no meta line means not ok');

/* fix225: the analytical layer has explicit evidence floors and never turns overhead or
   correlation into a claimed net benefit / sole cause. */
chk(d.sections.capture.dir === '/storage/emulated/0/asb_log_full_day_test', 'capture export path parses');
const analysis = logReportAnalyze(d);
chk(analysis.schema === 2 && analysis.quality.level === 'high', 'rich capture quality: ' + JSON.stringify(analysis.quality));
chk(analysis.verdicts.length === 5 && analysis.actions.length <= 3, 'five verdict domains and at most three priority actions');
const selectedActions = analysis.actions.map(t => t.key);
chk(analysis.observations.every(t => selectedActions.indexOf(t.key) < 0), 'priority actions are not duplicated in observations');
const sortFixture = parseLogReport([
  'meta\telapsed_min=180',
  'night\tdur_min=180\tpctph=1.5\tawake=30\tdrop=3',
  'idlemax\tawake=40\tphase=sleep\tdur_min=45',
  'wlive\ttag=Holder\tpct=80\tmin=30\tpkg=com.example.holder',
  'cfg\tnight_modem_idle=1', 'cfg\twakelock_action=0', 'cfg\tnet_screen_off_lte=0',
  'audio\tspk_min=40\tpctph=6.0', 'sradio\tmib=60',
  'heat\tpeak_phase=active\twarm_min=47\tskin_min=12', 'thermal\tcpu=52', 'throttle\tclamps=3',
  'asbcost\tcpu_msh=9000\twrites_h=52\twakes_h=300', 'crash\tcount=3\tasb=0', ''].join('\n'));
const sortKeys = logReportAnalyze(sortFixture).observations.map(t => t.key).join(',');
chk(sortKeys === 'lr_tip_awake_who,lr_tip_sradio,lr_tip_night,lr_tip_audio',
  'observations use the same stable priority order as actions: ' + sortKeys);
chk(analysis.chains.some(c => c.kind === 'hypothesis' && c.key === 'lr_chain_holder'), 'holder causality remains a hypothesis');
chk(analysis.chains.some(c => c.kind === 'fact' && c.key === 'lr_chain_asb_crash'), 'an ASB crash remains a fact');
const overheadOnly = parseLogReport('meta\telapsed_min=120\nasbcost\tcpu_msh=1851\twrites_h=176\twakes_h=491\n');
chk(logReportAnalyze(overheadOnly).verdicts.find(v => v.domain === 'asb').state === 'normal', 'ordinary overhead is neutral, not a claimed saving');
const machine = logReportMachineDigest(d);
chk(machine.schema === 2 && machine.capture.elapsed_min === 720 && machine.device.device === 'OP611FL1', 'machine digest capture/device');
chk(machine.quality.level === analysis.quality.level && machine.scenario.family === analysis.scenario_family, 'machine digest quality/scenario');
chk(machine.verdicts.length === 5 && machine.facts.every(c => c.kind === 'fact') && machine.hypotheses.every(c => c.kind === 'hypothesis'), 'machine digest separates facts and hypotheses');
chk(machine.actions.length <= 3 && machine.asb_overhead.native_cpu_ms_per_wakeup > 3.7 && machine.asb_overhead.native_cpu_ms_per_wakeup < 3.8, 'machine digest actions and overhead');
chk(JSON.parse(JSON.stringify(machine)).schema === 2, 'machine digest is JSON serializable');
const early = parseLogReport('meta\telapsed_min=10\ttarget_h=24\trunning=1\nwl\tnone=1\n');
const earlyA = logReportAnalyze(early);
chk(earlyA.quality.level === 'low' && earlyA.verdicts.every(v => v.state === 'unknown'), 'meta-only capture yields no healthy verdict');
chk(earlyA.actions.length === 0 && earlyA.observations.length === 1 && earlyA.observations[0].key === 'lr_tip_wait', 'early capture waits instead of recommending or claiming health');
const shortNight = parseLogReport('meta\telapsed_min=180\nnight\tdur_min=40\tpctph=1.5\tawake=20\tdrop=1\n');
const shortA = logReportAnalyze(shortNight);
chk(shortA.verdicts.find(v => v.domain === 'drain').state === 'unknown' && shortA.verdicts.find(v => v.domain === 'deep_sleep').state === 'unknown', 'forty idle minutes produce neither drain nor sleep verdict');
const lowFrames = parseLogReport('meta\telapsed_min=120\njank\tpct=19\tjps=9\tframes=19999\n');
chk(logReportAnalyze(lowFrames).verdicts.find(v => v.domain === 'smoothness').state === 'unknown', 'thin jank sample stays unknown');
const wakeBad = parseLogReport('meta\telapsed_min=120\njank\tpct=1.0\tjps=0.4\tframes=30000\njwake\twakes=8\tpct=8.0\tord=1.0\tframes=900\ttop=com.android.systemui\n');
chk(logReportAnalyze(wakeBad).verdicts.find(v => v.domain === 'smoothness').state === 'problem', 'wake-window jank can overturn a good average');
const screenLed = parseLogReport('meta\telapsed_min=180\ncover\ton_min=150\toff_min=30\ton_pct=83\nscr\ton_pctph=4.2\toff_pctph=9.9\ton_min=150\toff_min=30\nnight\tdur_min=180\tpctph=3.0\tawake=30\n');
const screenA = logReportAnalyze(screenLed);
chk(screenA.scenario_family === 'screen_on' && screenA.verdicts.find(v => v.domain === 'drain').metric === '4.2%/h' && screenA.verdicts.find(v => v.domain === 'drain').reason === 'screen_on_ledger', 'screen-led capture uses the matching screen-on ledger');
/* fix231: 10.1%/h is ordinary screen-on use, not an automatic red verdict. Heavy and
   speaker scenarios have their own budgets, and the summary uses the same classifier. */
chk(logReportScreenOnDrainState(10.1, 'screen_on_light') === 'normal', '10.1%/h stays normal for ordinary screen use');
chk(logReportScreenOnDrainState(15.1, 'screen_on_light') === 'problem', 'ordinary screen use crosses the red line only above 15%/h');
chk(logReportScreenOnDrainState(25, 'screen_on_heavy') === 'normal' && logReportScreenOnDrainState(30.1, 'screen_on_heavy') === 'problem', 'gaming uses its own drain budget');
chk(logReportScreenOnDrainState(18, 'audio_speaker') === 'normal' && logReportScreenOnDrainState(20.1, 'audio_speaker') === 'problem', 'speaker playback uses its own drain budget');
const typicalScreen = parseLogReport('meta\telapsed_min=180\ncover\ton_min=150\toff_min=30\ton_pct=83\nscr\ton_pctph=10.1\toff_pctph=0.5\ton_min=150\toff_min=30\n');
chk(logReportAnalyze(typicalScreen).verdicts.find(v => v.domain === 'drain').state === 'normal', 'the rendered summary keeps 10.1%/h normal');
const oldHistory = d.hist[0];
chk(!logReportHistoryComparable(d, analysis, oldHistory), 'legacy six-field history is not comparable');
const sameHistory = { started:'2026-10-20 09:10', night:'1.0', drain:'2.0', jank:'1.4', device:'OP611FL1', rom:'TESTBUILD', mod:'old', elapsed:720, onPct:'40', offMin:300 };
const histBase = parseLogReport('meta\telapsed_min=120\nmeta2\tdevice=OP611FL1\trom=TESTBUILD\ncover\ton_min=40\toff_min=60\ton_pct=40\n');
const histBaseA = logReportAnalyze(histBase);
chk(logReportHistoryComparable(histBase, histBaseA, sameHistory), 'same device/ROM/scenario and sufficient durations are comparable');
chk(!logReportHistoryComparable(histBase, histBaseA, Object.assign({}, sameHistory, {rom:'OTHER'})), 'ROM mismatch blocks a numeric trend');
chk(!logReportHistoryComparable(histBase, histBaseA, Object.assign({}, sameHistory, {elapsed:20})), 'short previous capture blocks a numeric trend');
chk(!logReportHistoryComparable(histBase, histBaseA, Object.assign({}, sameHistory, {onPct:'-'})), 'unknown scenario blocks a numeric trend');

/* Real DOM-building functions over a small DOM stub: summary precedes details, five
   verdicts are visible, incompatible history never prints a numeric improvement. */
ASB_LANG = 'ru';
function domEl(tag) { return { tag:tag, children:[], _text:'', className:'', disabled:false,
  get textContent() { return this._text; }, set textContent(v) { this._text = String(v); this.children = []; },
  appendChild(c) { this.children.push(c); return c; }, classList:{ add() {} } }; }
const reportBody = domEl('div'), reportStatus = domEl('div'), jsonButton = domEl('button');
function _el(id) { return id === 'reportBody' ? reportBody : id === 'reportStatus' ? reportStatus : id === 'rpJson' ? jsonButton : null; }
const document = { createElement:domEl };
global.window = {};
function allText(e) { return (e.textContent || '') + e.children.map(allText).join('|'); }
function countClass(e, name) { return (String(e.className).split(/\s+/).indexOf(name) >= 0 ? 1 : 0) + e.children.reduce((n,c) => n + countClass(c,name), 0); }
logReportRender(early);
chk(countClass(reportBody, 'lgr-verdict') === 5, 'summary renders all five verdict rows');
chk(reportBody.children[0].children[0].textContent === I18N.ru.lr_sec_summary, 'smart summary is the first report section');
chk(countClass(reportBody, 'lgr-action') === 0 && allText(reportBody).indexOf(I18N.ru.lr_no_actions_early) >= 0, 'early DOM has no unsupported action');
logReportRender(typicalScreen);
chk(countClass(reportBody, 'lgr-state-problem') === 0 && countClass(reportBody, 'lgr-warn') === 0, 'neither summary nor detail paints 10.1%/h red');
const trendText = 'meta\telapsed_min=120\ttarget_h=24\trunning=0\tstarted=2026-10-21 09:40\tprofile=smart\nmeta2\tdevice=OP611FL1\trom=TESTBUILD\ndrain\tpctph=2.0\n';
const incompatible = parseLogReport(trendText + 'hist\tstarted=2026-10-20 09:10\tnight=-\tdrain=3.0\tjank=-\tcpu=-\tclamps=-\n');
logReportRender(incompatible);
let trendSec = reportBody.children.find(e => e.children[0] && e.children[0].textContent === I18N.ru.lr_sec_trend);
chk(trendSec && allText(trendSec).indexOf(I18N.ru.lr_trend_unmatched) >= 0 && allText(trendSec).indexOf('3.0') < 0, 'incompatible history has no was/became numbers');
const compatible = parseLogReport(trendText + 'hist\tstarted=2026-10-20 09:10\tnight=-\tdrain=3.0\tjank=-\tcpu=-\tclamps=-\tdevice=OP611FL1\trom=TESTBUILD\tmod=old\telapsed=120\ton_pct=40\toff_min=60\n');
chk(logReportHistoryComparable(compatible, logReportAnalyze(compatible), compatible.hist[0]), 'render fixture history is comparable: ' + JSON.stringify(compatible.hist[0]) + ' / ' + JSON.stringify(compatible.sections.meta2));
logReportRender(compatible);
trendSec = reportBody.children.find(e => e.children[0] && e.children[0].textContent === I18N.ru.lr_sec_trend);
chk(trendSec && allText(trendSec).indexOf('3.0') >= 0 && allText(trendSec).indexOf(I18N.ru.lr_trend_matched) >= 0, 'compatible history shows numbers plus the non-A/B caveat: ' + (trendSec ? allText(trendSec) : 'no section') + ' comparable-after=' + logReportHistoryComparable(compatible, compatible.analysis, compatible.hist[0]) + ' scenario=' + compatible.analysis.scenario_family);

let exportCommand = '', exportErrno = 0; const exportToasts = [];
function toast(msg, kind) { exportToasts.push({msg:msg, kind:kind}); }
async function run(cmd) { exportCommand = cmd; return { errno:exportErrno, stderr:'write failed' }; }
async function verifyJsonExport() {
  compatible.sections.capture = { dir:"/storage/emulated/0/asb log 'quoted'" };
  compatible.sections.meta.profile = 'Смарт';
  window._asbLogReportData = compatible;
  await logReportExportJson();
  chk(jsonButton.disabled === false && exportCommand.indexOf("printf '%s' ") === 0, 'JSON export button and command');
  chk(exportCommand.endsWith(shQuote("/storage/emulated/0/asb log 'quoted'/report.json")), 'JSON export quotes the exact capture path');
  const match = exportCommand.match(/^printf '%s' '([^']*)' \| base64 -d > /);
  chk(!!match, 'JSON export has a base64 payload');
  if (match) {
    const exported = JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
    chk(exported.schema === 2 && exported.capture.profile === 'Смарт', 'JSON export preserves UTF-8 and schema 2');
  }
  exportErrno = 1; await logReportExportJson();
  chk(exportToasts.some(t => t.kind === 'error') && jsonButton.disabled === false, 'JSON write failure reports an error and re-enables the button');
}
verifyJsonExport().then(function () {
  if (bad) process.exit(1);
  console.log('ok');
}, function (e) { console.log('FAIL async JSON export: ' + e.stack); process.exit(1); });
EOF
} > "$T/t.js"
rout="$(node "$T/t.js" 2>&1)" || fail "$rout"
[ "$rout" = ok ] || fail "$rout"

# --- locales + markup pins ---
python3 - "$ROOT" <<'P' || fail "locales/markup"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
KEYS = ['lr_menu','lr_refresh','lr_loading','lr_none_title','lr_none_body','lr_failed',
        'lr_running','lr_done','lr_early','lr_sec_drain','lr_overall','lr_temp_surf',
        'lr_screen_on','lr_screen_off','lr_night','lr_idle','lr_radio','lr_sec_wake',
        'lr_wake_none','lr_sec_crash','lr_crash_none','lr_crash_n','lr_crash_latest',
        'lr_crash_asb','lr_sysui','lr_sec_thermal','lr_clamp_none',
        'lr_clamp_some','lr_sec_tips','lr_tip_ok','lr_tip_night','lr_tip_awake',
        'lr_tip_crash','lr_tip_crashes','lr_tip_app','lr_min','lr_secs','lr_h','lr_per_hour',
        'lr_saved','lr_sec_smooth','lr_jank_hero','lr_jank_all','lr_jps_hero','lr_jps_sub',
        'lr_th_app','lr_th_frames','lr_th_jank','lr_sec_display','lr_th_hz','lr_th_share',
        'lr_th_ma','lr_hz_unit','lr_sec_smart','lr_sm_ctx','lr_sm_watching','lr_sm_testing',
        'lr_sm_helped','lr_sm_nothelped','lr_sm_fresh','lr_sec_asb','lr_cost_cpu',
        'lr_cost_writes','lr_cost_wakes','lr_ms_h','lr_charge_types','lr_audio_spk',
        'lr_tip_wl_enable','lr_tip_night_modem','lr_tip_jank_bad','lr_tip_jank_ok',
        'lr_tip_audio','lr_tip_cost_ok','lr_tip_cost_hi','lr_tip_smart_help','lr_tip_ltpo',
        'lr_sec_profiles','lr_th_profile','lr_th_time','lr_th_onscreen','lr_th_idle',
        'lr_prof_note','lr_charging','lr_chg_fmt','lr_aod','lr_aod_fmt','lr_ltpo',
        'lr_ltpo_fmt','lr_wlive_fmt','lr_tip_awake_who','lr_sm_smart_only',
        'lr_drain_on','lr_drain_off','lr_deep_sleep','lr_sec_phases','lr_th_phase',
        'lr_th_drop','lr_ph_note','lr_kwk_fmt','lr_wake_gap',
        'lr_ph_active','lr_ph_idle','lr_ph_sleep','lr_ph_post_wake','lr_ph_gap',
        'lr_ph_gaming','lr_ph_audio_spk','lr_ph_audio_spk_scr','lr_ph_audio_bt',
        'lr_ph_audio_bt_scr','lr_ph_charging_idle','lr_ph_charging_active',
        'lr_sec_nightd','lr_nd_spent','lr_nd_deep','lr_nd_awake','lr_nd_ma',
        'lr_nd_radio','lr_nd_temp','lr_nd_temp_fmt','lr_nd_holder',
        'lr_nd_verdict_ok','lr_nd_verdict_mid','lr_nd_verdict_bad','lr_tip_prof_save',
        'lr_wlt_head','lr_wla_head','lr_times','lr_sradio','lr_scr_note',
        'lr_tip_awake_alarm','lr_tip_awake_hold',
        'lr_heat_peak','lr_heat_warm_fmt','lr_heat_skin_fmt',
        'lr_tip_heat_warm','lr_tip_heat_warm_set','lr_tip_heat_calm',
        'lr_mwake','lr_mwake_fmt',
        'lr_sec_trend','lr_trend_night','lr_trend_day','lr_trend_jank','lr_trend_vs',
        'lr_th_jps','lr_th_state','lr_jwake','lr_jwake_fmt','lr_jwake_top',
        'lr_jphase_head','lr_jstate_head','lr_gauge_note','lr_nd_verdict_short',
        'lr_tip_jank_wake','lr_tip_jank_wake_wh',
        'lr_sec_nightd_short','lr_nd_spent_short','lr_tip_awake_aod','lr_tip_sradio']
KEYS += ['lr_sec_summary','lr_sec_causes','lr_sec_actions','lr_sec_observations',
         'lr_sum_drain','lr_sum_thermal','lr_sum_smooth','lr_sum_sleep','lr_sum_asb',
         'lr_state_good','lr_state_normal','lr_state_problem','lr_state_unknown',
         'lr_quality_low','lr_quality_medium','lr_quality_high',
         'lr_scenario_charging','lr_scenario_audio_speaker','lr_scenario_screen_on_heavy',
         'lr_scenario_screen_off_idle','lr_scenario_screen_off_network_active',
         'lr_scenario_screen_on_light','lr_scenario_mixed','lr_kind_fact','lr_kind_hypothesis',
         'lr_sum_drain_on','lr_sum_drain_night','lr_sum_drain_off','lr_sum_need_time',
         'lr_sum_thermal_detail','lr_sum_no_sensor','lr_sum_smooth_detail','lr_sum_need_frames',
         'lr_sum_sleep_detail','lr_sum_need_night','lr_sum_asb_crash','lr_sum_asb_cost',
         'lr_sum_asb_unknown','lr_quality_short','lr_quality_full',
         'lr_chain_asb_crash','lr_chain_heat','lr_chain_aod','lr_chain_radio','lr_chain_holder',
         'lr_chain_alarm','lr_chain_hold','lr_chain_wakegap','lr_chain_wake','lr_chain_audio',
         'lr_chain_cost','lr_no_actions','lr_no_actions_early','lr_trend_matched',
         'lr_trend_unmatched','lr_tip_wait','lr_json_saved','lr_json_error']
EMO = {'lr_sec_drain': '\U0001f50b', 'lr_sec_wake': '\u23f0', 'lr_sec_crash': '\U0001f4a5',
       'lr_sec_thermal': '\U0001f321\ufe0f', 'lr_sec_tips': '\U0001f4a1',
       'lr_sec_smooth': '\U0001f4f1', 'lr_sec_display': '\U0001f5a5',
       'lr_sec_smart': '\U0001f9e0', 'lr_sec_asb': '\u2699\ufe0f',
       'lr_sec_profiles': '\u2696\ufe0f', 'lr_sec_phases': '\U0001f4ca',
       'lr_sec_nightd': '\U0001f319', 'lr_sec_trend': '\U0001f4c8',
       'lr_sec_nightd_short': '\U0001f319', 'lr_sec_summary': '\U0001f9ed',
       'lr_sec_causes': '\U0001f517', 'lr_sec_actions': '\U0001f3af',
       'lr_sec_observations': '\U0001f4a1'}
PH = {'lr_running': ['{min}', '{h}'], 'lr_crash_n': ['{n}'], 'lr_crash_latest': ['{proc}'],
      'lr_crash_asb': ['{n}'], 'lr_sysui': ['{n}'], 'lr_temp_max': ['{cpu}', '{surf}'],
      'lr_clamp_some': ['{n}', '{owner}'], 'lr_tip_night': ['{pct}'], 'lr_tip_awake': ['{awake}'],
      'lr_tip_crashes': ['{n}'], 'lr_tip_app': ['{app}', '{min}'], 'lr_min': ['{n}'], 'lr_secs': ['{n}'], 'lr_h': ['{n}'],
      'lr_saved': ['{when}', '{profile}'], 'lr_jank_all': ['{frames}'], 'lr_ms_h': ['{n}'],
      'lr_tip_wl_enable': ['{app}', '{min}', '{set}'], 'lr_tip_night_modem': ['{pct}', '{set}'],
      'lr_tip_jank_bad': ['{pct}'], 'lr_tip_jank_ok': ['{pct}'], 'lr_tip_audio': ['{pct}'],
      'lr_tip_cost_ok': ['{ms}'], 'lr_tip_cost_hi': ['{ms}'], 'lr_tip_smart_help': ['{n}'],
      'lr_tip_ltpo': ['{set}'], 'lr_chg_fmt': ['{min}', '{gain}', '{sess}'],
      'lr_aod_fmt': ['{lit}', '{of}'], 'lr_ltpo_fmt': ['{n}', '{min}'],
      'lr_wlive_fmt': ['{pct}', '{dur}'], 'lr_tip_awake_who': ['{awake}', '{who}'],
      'lr_deep_sleep': ['{pct}'], 'lr_kwk_fmt': ['{tag}'],
      'lr_nd_temp_fmt': ['{cpu}', '{skin}'], 'lr_nd_verdict_ok': ['{pct}', '{deep}'],
      'lr_nd_verdict_mid': ['{awake}'], 'lr_nd_verdict_bad': ['{pct}'],
      'lr_tip_prof_save': ['{cheap}', '{x}', '{busy}', '{y}'],
      'lr_times': ['{n}'],
      'lr_tip_awake_alarm': ['{awake}', '{who}'], 'lr_tip_awake_hold': ['{awake}', '{who}'],
      'lr_tip_heat_warm': ['{min}', '{phase}'], 'lr_tip_heat_warm_set': ['{min}', '{phase}', '{set}'],
      'lr_tip_heat_calm': ['{cpu}'], 'lr_mwake_fmt': ['{n}', '{per}', '{sec}'],
      'lr_trend_night': ['{was}', '{now}'], 'lr_trend_day': ['{was}', '{now}'],
      'lr_trend_jank': ['{was}', '{now}'], 'lr_trend_vs': ['{when}'],
      'lr_jwake_fmt': ['{n}', '{pct}', '{ord}'], 'lr_jwake_top': ['{pkg}', '{pct}'],
      'lr_gauge_note': ['{x}', '{w}'], 'lr_nd_verdict_short': ['{min}', '{pct}'],
      'lr_tip_jank_wake': ['{pct}', '{ord}', '{who}'], 'lr_tip_jank_wake_wh': ['{pct}', '{ord}'],
      'lr_tip_awake_aod': ['{awake}', '{lit}', '{of}'], 'lr_tip_sradio': ['{mib}', '{set}']}
PH.update({'lr_sum_drain_on':['{min}'], 'lr_sum_drain_night':['{min}','{deep}'],
      'lr_sum_drain_off':['{min}'], 'lr_sum_thermal_detail':['{warm}','{clamps}'],
      'lr_sum_smooth_detail':['{frames}','{wake}'], 'lr_sum_sleep_detail':['{awake}','{min}'],
      'lr_sum_asb_cost':['{ms}','{per}'], 'lr_quality_short':['{min}'],
      'lr_chain_asb_crash':['{n}'], 'lr_chain_heat':['{min}','{clamps}','{owner}','{phase}'],
      'lr_chain_aod':['{awake}','{lit}','{of}'], 'lr_chain_radio':['{awake}','{mib}'],
      'lr_chain_holder':['{awake}','{who}'], 'lr_chain_alarm':['{awake}','{who}','{n}'],
      'lr_chain_hold':['{awake}','{who}','{n}'], 'lr_chain_wakegap':['{awake}'],
      'lr_chain_wake':['{pct}','{ord}'], 'lr_chain_audio':['{min}','{pct}'],
      'lr_chain_cost':['{ms}','{wakes}','{per}'], 'lr_json_saved':['{path}']})
files = sorted((root / 'webroot' / 'i18n').glob('*.json'))
assert len(files) == 13, 'locale count'
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for k in KEYS:
        assert d.get(k), '%s: %s missing' % (p.name, k)
        for ph in PH.get(k, []):
            assert ph in d[k], '%s: %s lost its %s placeholder' % (p.name, k, ph)
    for k, e in EMO.items():
        assert d[k].startswith(e + ' '), '%s: %s lost its emoji prefix' % (p.name, k)
    if p.name == 'en.json':
        assert d['lr_sec_drain'] == '\U0001f50b Battery drain'
        assert d['lr_running'] == 'recording \u00b7 {min} min of {h} h'
        assert d['lr_tip_night'] == 'Overnight the phone lost ~{pct}%/h - check background apps.'
        assert d['lr_per_hour'] == '%/h' and d['lr_refresh'] == 'Refresh'
        assert d['lr_secs'] == '{n} sec'
        assert d['lr_sec_smooth'] == '\U0001f4f1 Smoothness'
        assert d['lr_saved'] == 'saved capture \u00b7 {when} \u00b7 {profile}'
        assert d['lr_jank_all'] == 'of {frames} frames' and d['lr_ms_h'] == '{n} ms/h'
        assert d['lr_tip_jank_ok'] == 'Smoothness is excellent: only {pct}% of frames janky.'
    if p.name == 'ru.json':
        assert d['lr_sec_drain'] == '\U0001f50b Разряд батареи'
        assert d['lr_menu'] == 'Отчёт по логу' and d['lr_refresh'] == 'Обновить'
        assert d['lr_secs'] == '{n} сек'
        assert d['lr_sec_smooth'] == '\U0001f4f1 Плавность'
        assert d['lr_saved'] == 'сохранённый лог \u00b7 {when} \u00b7 {profile}'
# Key-set parity: every locale must carry exactly the English key set. A missing key
# silently falls back to English mid-screen; an extra one is dead weight. (Real drift
# caught: t_cfg_video existed in 12 locales but not en.)
ref = set(json.loads((root / 'webroot' / 'i18n' / 'en.json').read_text(encoding='utf-8')))
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    assert set(d) == ref, '%s: key set differs from en (%s)' % (p.name, sorted(set(d) ^ ref)[:3])
h = (root / 'webroot' / 'index.html').read_text(encoding='utf-8')
assert h.count('data-i18n="lr_menu"') == 2, 'menu item and page section label carry lr_menu'
P
grep -Fq 'onclick="asbLogMenuPick('"'"'report'"'"')"' "$H" || fail "the menu item does not pick report"
grep -Fq "if (action === 'report') { openReportPage(); return; }" "$H" || fail "the report branch is gone from asbLogMenuPick"
grep -Fq "run('sh ' + MD + '/tools/logkit/asb_fullday_digest.sh 2>/dev/null')" "$H" || fail "the digest invocation changed"
grep -Fq 'iclassName' "$H" && fail "typo"
grep -Fq '#reportPage { z-index: 130;' "$H" || fail "the report page is not a page layer above Config"
grep -Fq 'id="reportPage"' "$H" || fail "report page markup missing"
grep -Fq 'function openReportPage()' "$H" || fail "openReportPage missing"
grep -Fq 'function closeReportPage()' "$H" || fail "closeReportPage missing"
grep -Fq "if (document.body.classList.contains('report-active')) return 'report';" "$H" || fail "asbNavCurrent does not know the report page"
grep -Fq '.lgr-heros { display: grid;' "$H" || fail "hero tiles styles missing"
grep -Fq "'Noto Color Emoji'" "$H" || fail "the sans stack lost its emoji fallback"
grep -Fq 'function logReportDurSec(sec)' "$H" || fail "seconds-level duration formatter missing"
grep -Fq 'logReportDurSec(w.sec)' "$H" || fail "wakelock rows must format sub-minute holds in seconds"
grep -Fq 'textContent = tip.ic' "$H" || fail "tips must render via textContent, not markup"
grep -Fq 'function logReportTable(heads, rows, numCols)' "$H" || fail "the fix200 table builder is missing"
grep -Fq '.lgr-table { width: 100%; border-collapse: collapse; table-layout: fixed;' "$H" || fail "the fix200 table styles are missing"
grep -Fq "logReportT('lr_saved', 'saved capture · {when} · {profile}'" "$H" || fail "a saved capture must be named with its start time and profile"
grep -Fq "lr_tip_wl_enable: '{app} held the phone awake for {min} min" "$H" || fail "the wakelock tip lost its English fallback"
grep -Fq "Tcfg('night_modem_idle', 'name', 'Quiet Radio at Night')" "$H" || fail "advice must name settings as the Settings screen names them"
grep -Fq '"tools/logkit/asb_fullday_digest.sh"' "$ROOT/.github/workflows/build-debug.yml" || fail "debug workflow does not ship the digest"
grep -Fq '"tools/logkit/asb_fullday_digest.sh"' "$ROOT/.github/workflows/build-release.yml" || fail "release workflow does not ship the digest"
grep -Fq 'asb_fullday_digest.sh' "$ROOT/.github/workflows/build-release.yml" || fail "release staging loop lost the digest"
grep -Fq 'crash.ltime' "$H" || fail "fix204: the sheet must show WHEN the latest crash happened"
# fix213: device context, heat durations, night habits and the trend must all be wired
grep -Fq 'd.sections.meta2' "$H" || fail "the page never reads the device context"
grep -Fq "T('lr_sec_trend'," "$H" || fail "the trend section is not rendered"
grep -Fq "'lr_tip_heat_warm'" "$H" || fail "the heat advice is gone"
grep -Fq "Tcfg('sustained_temp_mode', 'name', 'Throttling Point')" "$H" || fail "the heat advice does not name the thermal switch"
grep -Fq "T('lr_mwake'," "$H" || fail "the night-habits row is gone"
grep -Fq "tag === 'hist'" "$H" || fail "the parser drops the history rows"
grep -Fq 'hist\tstarted=' "$ROOT/tools/logkit/asb_fullday_digest.sh" 2>/dev/null || grep -Fq 'hist\tstarted=%s' "$ROOT/tools/logkit/asb_fullday_digest.sh" || fail "the digest emits no history rows"
grep -Fq 'report_history.tsv' "$ROOT/tools/logkit/asb_fullday_digest.sh" || fail "the digest keeps no capture history"
echo "PASS webui log report: digest over a fixture capture (drain..cfg, live holders, per-profile drain, charging, LTPO, AOD, wake causes by occurrence fix210), fresh-capture crash window (fix204), plain-words parser/tips in node (ru+en), 13 locales, menu wiring"
)

t_webui_liquid_glass_runtime() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui liquid glass: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui liquid glass: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  cat <<'EOF'
const store = { asb_theme:'glass' };
const localStorage = { getItem:k => store[k] || null, setItem:(k,v) => { store[k]=v; } };
const attrs = {};
const root = { setAttribute:(k,v) => { attrs[k]=v; }, removeAttribute:k => { delete attrs[k]; } };
const meta = { setAttribute:(k,v) => { meta.content=v; } };
const buttons = [];
for (let page=0; page<5; page++) for (const choice of ['dark','light','glass']) {
  const classes = new Set();
  buttons.push({ choice, classes, attrs:{}, getAttribute(k) { return k==='data-theme-choice' ? choice : this.attrs[k]; }, setAttribute(k,v) { this.attrs[k]=v; }, classList:{ toggle(c,on) { on ? classes.add(c) : classes.delete(c); } } });
}
const document = { documentElement:root, querySelector:s => s==='meta[name="theme-color"]' ? meta : null, querySelectorAll:s => s==='[data-theme-choice]' ? buttons : [] };
function T(k,d) { return d; }
let sounds=0; function uiSound() { sounds++; }
EOF
  for fn in asbThemeValue asbGlassBase asbPaintThemeControls asbSetTheme; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
function chk(c,m) { if (!c) throw new Error(m); }
asbPaintThemeControls();
chk(!('data-asb-theme' in attrs)&&attrs['data-asb-glass']==='1','legacy Glass cold start defaults to the black palette');
chk(meta.content==='#000000','black Glass theme-color');
chk(buttons.filter(b=>b.classes.has('active')).length===5,'not all five switches select glass');
chk(buttons.filter(b=>b.choice==='glass').every(b=>b.attrs['aria-pressed']==='true'&&b.attrs['aria-label']==='Liquid Glass theme'),'glass aria state/label');
asbSetTheme('light'); chk(attrs['data-asb-theme']==='light'&&!('data-asb-glass' in attrs)&&store.asb_theme==='light'&&store.asb_glass_base==='light','Glass -> light remembers the light base');
asbSetTheme('glass'); chk(attrs['data-asb-theme']==='light'&&attrs['data-asb-glass']==='1'&&store.asb_theme==='glass'&&store.asb_glass_base==='light','Light -> Glass produces light glass');
chk(meta.content==='#f3f7f6','light Glass theme-color');
asbSetTheme('dark'); chk(!('data-asb-theme' in attrs)&&!('data-asb-glass' in attrs)&&store.asb_theme==='dark'&&store.asb_glass_base==='dark','light Glass -> dark remembers the dark base');
asbSetTheme('glass'); chk(!('data-asb-theme' in attrs)&&attrs['data-asb-glass']==='1'&&store.asb_theme==='glass'&&store.asb_glass_base==='dark','Dark -> Glass produces black glass');
store.asb_glass_base='light'; asbPaintThemeControls();
chk(attrs['data-asb-theme']==='light'&&attrs['data-asb-glass']==='1','a saved light-Glass choice cold-starts on the light palette');
asbSetTheme('invalid'); chk(!('data-asb-theme' in attrs)&&!('data-asb-glass' in attrs)&&store.asb_theme==='dark','unknown theme is not accepted');
chk(buttons.every(b=>(b.classes.has('active'))===(b.choice==='dark')),'switches diverged after cycling');
console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
python3 - "$H" <<'PY' || fail 'markup or material'
import sys
h=open(sys.argv[1],encoding='utf-8').read()
assert h.count('data-theme-choice="glass"') == 5
assert h.count('data-theme-toggle=') == 5
assert 'backdrop-filter:blur(8px)' in h
assert 'html[data-asb-glass="1"]' in h
assert 'html[data-asb-glass="1"][data-asb-theme="light"]' in h
assert '--accent:#00f0b4' in h and '--accent:#007c63' in h
assert '--surface:rgba(16,23,20,.86)' in h and '--border:rgba(108,151,133,.46)' in h
assert '.log-menu,.cfg-fm-box,.asb-tabbar' in h
assert ':is(.log-menu,.cfg-fm-box,.cfg-profile-sheet,.cfg-reset-dialog)' in h
assert '.cfg-fm-btn,.cfg-fm-place,.cfg-fm-cancel' in h
assert '#00aaff' not in h and '0,170,255' not in h and '101,215,255' not in h
assert "localStorage.getItem('asb_glass_base')" in h
assert '@media (prefers-reduced-motion:reduce)' in h
# Semantic readings survive both neutral Glass material layers, for direct Smart classes
# and Stock load's descendant spans alike.
for selector in (
    'html[data-asb-glass="1"] .smart-banner-value:is(.cap-raised,.load-low)',
    'html[data-asb-glass="1"] .smart-banner-value:is(.basis-warn,.heat-warm,.load-mid)',
    'html[data-asb-glass="1"] .smart-banner-value:is(.cap-clamp,.basis-veto,.load-high)',
    'html[data-asb-glass="1"] .smart-banner-value .load-mid',
):
    assert selector in h, selector
assert "appH === 2 ? ' load-mid'" in h and "appH <= 1 ? ' load-low'" in h
assert '.smart-banner-value.load-mid,' in h and 'color: var(--bal);' in h
for cls in ('good', 'warm', 'bad', 'neutral'):
    assert '.smart-banner-value.metric-' + cls in h
    assert '.live-cell-value.metric-' + cls in h
    assert 'html[data-asb-glass="1"] .smart-banner-value.metric-' + cls in h
    assert 'html[data-asb-glass="1"] .live-cell-value.metric-' + cls in h
# Category colour is a translucent material layer, not a flat replacement or a neutral wash.
assert 'html[data-asb-glass="1"] .cfg-tile[class*="cat-"] {' in h
assert 'html[data-asb-glass="1"][data-asb-theme="light"] .cfg-tile[class*="cat-"] {' in h
assert 'color-mix(in srgb,var(--cat) 28%,transparent)' in h
assert 'color-mix(in srgb,var(--cat) 17%,transparent)' in h
assert 'html[data-asb-glass="1"] .cfg-tile[class*="cat-"] .cfg-tile-ico {' in h
PY
echo "PASS webui liquid glass: cold start, five synchronized switches, dark/light compatibility and localized aria"
)

t_webui_stock_trend_retry_runtime() (
# A transient root/sysfs read failure must not erase the last good thermal trend.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui stock trend retry: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui stock trend retry: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  cat <<'EOF'
const nodes = {};
function _el(id) { if (!nodes[id]) nodes[id] = { classList:{remove(){}}, style:{display:''}, textContent:'' }; return nodes[id]; }
function T(k,d) { return d; }
let _selectedProfile = 'stock', _stockRomHistory = {};
let _stockTelemetryLastMs = 0, _stockSettingsAtMs = 0;
let _stockTelemetryKv = { tsms:'1000', 'thermal.cpu-1-1-0':'41000' };
const STOCK_TELEMETRY_MIN_INTERVAL_MS = 10000, MD = '/mod';
let painted = [];
function paintStockLive(kv) { painted.push(kv); _el('liveStockRomBanner').style.display = Object.keys(kv).length ? '' : 'none'; }
function lvTopSecSync() {} async function lvMeterPoll() {}
let calls = 0;
async function run() { calls++; if (calls === 1) throw new Error('temporary root failure'); return { stdout:'thermal.cpu-1-1-0=42000\n' }; }
let clock = 10000; Date.now = () => clock;
EOF
  for fn in parseStockTelemetry pollStockTelemetry; do sed -n "/^\\(async \\)\\{0,1\\}function $fn(/,/^}/p" "$H"; done
  cat <<'EOF'
(async function () {
  await pollStockTelemetry(true, true);
  if (calls !== 1 || !_stockTelemetryKv.tsms || painted.length !== 1 || painted[0].tsms !== '1000') throw new Error('cached snapshot lost after a transient failure');
  if (_el('liveStockRomBanner').style.display === 'none') throw new Error('thermal card hidden despite a cached trend');
  clock = 30000;
  await pollStockTelemetry(true, true);
  if (calls !== 2 || _stockTelemetryKv['thermal.cpu-1-1-0'] !== '42000' || !painted[1].tsms) throw new Error('retry did not replace the cache with fresh telemetry');
  console.log('ok');
})().catch(e => { console.error(e.message); process.exit(1); });
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui stock trend retry: a transient read keeps the last good trend and the next poll refreshes it"
)

t_webui_visual_hierarchy_contract() (
# Contract (fix230): DSP outputs precede loudness and the global icons have clean silhouettes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui visual hierarchy: $*" >&2; exit 1; }
python3 - "$H" <<'PY' || fail 'DSP order or icons'
import re, sys
h = open(sys.argv[1], encoding='utf-8').read()
assert "keys:['dsp_outputs','dsp_loudness','dsp_bass','dsp_voice','dsp_width','dsp_compressor']" in h, 'DSP Outputs is not first'
for name in ('smart','performance','theme_glass'):
    m = re.search(r'^  %s: \'([^\']*)\'' % name, h, re.M)
    assert m, '%s missing from TECH_ICON_PATHS' % name
    if name in ('performance','theme_glass'):
        assert m.group(1).count('<path') == 1 and '<circle' not in m.group(1) and '<rect' not in m.group(1), '%s has an unwanted inner glyph' % name
    else:
        assert '<rect' in m.group(1) and m.group(1).count('<path') >= 2, 'Smart lost its adaptive-core glyph'
assert h.count('const TECH_ICON_PATHS = {') == 1, 'icon definitions diverged by page'
PY
echo "PASS webui visual hierarchy: DSP Outputs first; global Smart, Performance and Liquid Glass icons use the cleaned geometry"
)

t_webui_device_page_runtime() (
# Runtime (fix230): SoC pills open a fifth page; its TSV renderer is safe and evidence-based.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL webui device page: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui device page: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$ROOT" <<'PY' || fail 'markup, localization or read-only wiring'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1]); h = (root/'webroot/index.html').read_text(encoding='utf-8')
assert len(re.findall(r'<button class="badge badge-a" id="(?:socBadge|liveSocBadge|cfgSocBadge|rpSocBadge|devSocBadge)"', h)) == 5, 'not every SoC pill is a button'
for i in ('socBadge','liveSocBadge','cfgSocBadge','rpSocBadge','devSocBadge'):
    assert re.search(r'<button class="badge badge-a" id="%s" type="button"\s+onclick="openDevicePage\(\)"' % i, h), i
assert h.count('data-theme-toggle=') == 5 and h.count('data-theme-choice="glass"') == 5
assert '#devicePage { z-index: 140;' in h and 'id="devicePage"' in h
assert "run('sh ' + MD + '/tools/asb_device_info.sh 2>/dev/null')" in h
loader = h[h.index('async function asbDeviceInfoLoad()'):h.index('async function asbLogReportLoad()')]
assert 'setInterval' not in loader and 'setTimeout' not in loader
assert 'seq !== _deviceLoadSeq' in loader and 'Nothing was changed' in loader
segment = h[h.index('function parseDeviceInfo('):h.index('function openDevicePage()')]
assert '.innerHTML' not in segment and 'textContent' in segment
assert "['kernel_features', 'dev_sec_kernel_features'" in h
assert "['metamodule', 'dev_sec_metamodule'" in h
feature_order = re.search(r'const DEVICE_KERNEL_FEATURE_ORDER = \[(.*?)\];', h, re.S)
assert feature_order, 'explicit custom-kernel feature order missing'
ordered_features = re.findall(r"'([^']+)'", feature_order.group(1))
assert ordered_features == ['susfs','susfs_version','bbg_baseband_guard','bbr_v2','bbr_v1','lto',
                            'tmpfs_xattr_posix_acl','unicode_bypass_fix','droidspaces','ntsync','nomount','nomount_version'], ordered_features
keys = set(json.loads((root/'webroot/i18n/en.json').read_text(encoding='utf-8')))
for p in (root/'webroot/i18n').glob('*.json'):
    d = json.loads(p.read_text(encoding='utf-8'))
    assert set(d) == keys, p.name
    for key in ('dev_sec_kernel_features','dev_kernel_features_nomount','dev_kernel_features_nomount_version',
                'dev_kernel_features_ntsync','dev_kernel_features_droidspaces','dev_kernel_features_unicode_bypass_fix',
                'dev_kernel_features_tmpfs_xattr_posix_acl','dev_kernel_features_lto','dev_kernel_features_bbr_v1',
                'dev_kernel_features_bbr_v2','dev_kernel_features_bbg_baseband_guard','dev_kernel_features_susfs',
                'dev_sec_metamodule','dev_metamodule_status','dev_metamodule_id','dev_metamodule_name',
                'dev_metamodule_version','dev_metamodule_version_code','dev_metamodule_nomount_driver',
                'dev_metamodule_nomount_driver_version','dev_metamodule_nomount_evidence'):
        assert d.get(key), '%s: %s missing' % (p.name, key)
ru = json.loads((root/'webroot/i18n/ru.json').read_text(encoding='utf-8'))
assert 'NoMount' in ru['dev_kernel_features_nomount'] and 'NTSync' in ru['dev_kernel_features_ntsync']
assert 'BBRv2' in ru['dev_kernel_features_bbr_v2'] and 'SuSFS' in ru['dev_kernel_features_susfs']
assert 'Метамодуль' in ru['dev_sec_metamodule'] and 'NoMount' in ru['dev_metamodule_nomount_driver_version']
for f in ('tools/release_tools.list','common/install.sh','.github/workflows/build-release.yml','.github/workflows/build-debug.yml'):
    assert 'asb_device_info.sh' in (root/f).read_text(encoding='utf-8'), f
PY
{
  cat <<'EOF'
const ASB_LANG = 'en';
function T(k, d) { return d; }
function requestAnimationFrame() {} function asbFitPages() {}
function mk(tag) {
  const e = { tagName: tag, className: '', children: [], _text: '',
    classList: { add(c) { const a = new Set(e.className.split(/\s+/).filter(Boolean)); a.add(c); e.className = Array.from(a).join(' '); } },
    appendChild(c) { e.children.push(c); return c; },
    querySelector(sel) { const want = sel.slice(1); let found = null;
      (function walk(n) { if (found) return; if (n.className && n.className.split(/\s+/).includes(want)) { found = n; return; } (n.children || []).forEach(walk); })(e);
      return found; }
  };
  Object.defineProperty(e, 'textContent', { get() { return e._text; }, set(v) { e._text = String(v); e.children = []; } });
  return e;
}
const body = mk('div');
function _el(id) { return id === 'deviceBody' ? body : null; }
const document = { createElement: mk };
function logReportNote(text, warn) { const n = mk('div'); n.className = 'lgr-note'; n.textContent = text; return n; }
function logReportSec(title) { const n = mk('section'); const h = mk('h3'); h.textContent = title; n.appendChild(h); return n; }
function logReportRow(key, value) { const r = mk('div'), k = mk('span'), v = mk('span'); k.textContent = key; v.className = 'lgr-v'; v.textContent = value; r.appendChild(k); r.appendChild(v); return r; }
EOF
  sed -n '/^const DEVICE_SECTION_ORDER = \[/,/^\];/p' "$H"
  sed -n '/^const DEVICE_KERNEL_FEATURE_ORDER = \[/,/^\];/p' "$H"
  for fn in parseDeviceInfo deviceVal deviceFallbackLabel deviceLabel deviceHero deviceValueClass deviceDisplayValue deviceInfoRender; do
    sed -n "/^function $fn(/,/^}/p" "$H"
  done
  cat <<'EOF'
let bad = 0; function chk(c, m) { if (!c) { console.log('FAIL ' + m); bad++; } }
const attack = '<img src=x onerror=globalThis.pwned=1> OnePlus 15';
const text = [
  'D\tfirmware\tmodel\t' + attack,
  'D\tfirmware\tandroid\t17',
  'D\tsoc\tsoc_model\tSM8850',
  'D\tsoc\tcpu_online\t0-7',
  'D\tkernel\trelease\t6.12.30-custom',
  'D\tkernel\tuname_consistency\tmismatch',
  'D\tkernel_features\tnomount\tbuilt-in',
  'D\tkernel_features\tnomount_version\t22 (105)',
  'D\tkernel_features\tntsync\tbuilt-in',
  'D\tkernel_features\tdroidspaces\tcore config present; runtime not verified',
  'D\tkernel_features\tunicode_bypass_fix\tnot runtime-discoverable',
  'D\tkernel_features\ttmpfs_xattr_posix_acl\tsupported',
  'D\tkernel_features\tlto\tThinLTO (Clang)',
  'D\tkernel_features\tbbr_v1\tavailable',
  'D\tkernel_features\tbbr_v2\tavailable',
  'D\tkernel_features\tbbg_baseband_guard\tactive in LSM; built-in',
  'D\tkernel_features\tsusfs\tinterface available',
  'D\tkernel_features\tsusfs_version\tv2.3.0',
  'D\tmetamodule\tstatus\tdetected at standard path',
  'D\tmetamodule\tid\tMetaCore',
  'D\tmetamodule\tname\tMetaCore Metamodule',
  'D\tmetamodule\tversion\t1.4.0',
  'D\tmetamodule\tversion_code\t140',
  'D\tmetamodule\tnomount_driver\tbuilt-in',
  'D\tmetamodule\tnomount_driver_version\t22 (105)',
  'D\tmetamodule\tnomount_evidence\tkernel config/sysfs; driver ownership not inferred',
  'D\tmeta\tschema\t2',
  'garbage', 'D\tbroken'
].join('\n');
const d = parseDeviceInfo(text);
chk(d.count === 27 && d.malformed === 2, 'TSV count/malformed: ' + d.count + '/' + d.malformed);
chk(deviceVal(d, 'soc', 'soc_model') === 'SM8850', 'SoC parsed');
chk(deviceVal(d, 'soc', 'missing') === '—', 'missing value fallback');
const shown = deviceInfoRender(d);
chk(shown === 27, 'renderer row count: ' + shown);
const dump = (function walk(n) { return [n.textContent || ''].concat((n.children || []).flatMap(walk)); })(body).join('\n');
chk(dump.includes(attack), 'markup-like device data was not preserved as literal text');
chk(globalThis.pwned !== 1 && !body.querySelector('.img'), 'device value became markup');
chk(dump.includes('22 (105)') && dump.includes('ThinLTO (Clang)') && dump.includes('active in LSM; built-in'), 'custom kernel facts missing from render');
chk(dump.includes('Metamodule') && dump.includes('MetaCore Metamodule') && dump.includes('1.4.0') && dump.includes('driver ownership not inferred'), 'metamodule metadata or independent NoMount evidence missing from render');
chk(dump.includes('mismatch evidence only'), 'uname mismatch was turned into a spoofing verdict or hidden');
const values = []; (function walk(n) { if (n.className && n.className.split(/\s+/).includes('lgr-v')) values.push(n); (n.children || []).forEach(walk); })(body);
const expectedFeatureValues = ['interface available','v2.3.0','active in LSM; built-in','available','available','ThinLTO (Clang)','supported','not runtime-discoverable','core config present; runtime not verified','built-in','built-in','22 (105)'];
const featureCard = body.children.find(n => n.children && n.children[0] && n.children[0].textContent === 'Custom kernel features');
const actualFeatureValues = []; (function walk(n) { if (n && n.className && n.className.split(/\s+/).includes('lgr-v')) actualFeatureValues.push(n.textContent); ((n && n.children) || []).forEach(walk); })(featureCard);
chk(JSON.stringify(actualFeatureValues) === JSON.stringify(expectedFeatureValues), 'custom-kernel groups are not reversed with SuSFS first: ' + JSON.stringify(actualFeatureValues));
chk(values.some(v => v.textContent === attack && v.className.includes('dev-long')), 'long untrusted value lacks safe wrapping class');
chk(values.some(v => v.textContent === 'mismatch' && v.className.includes('dev-warn')), 'uname mismatch is not amber');
if (bad) process.exit(1); console.log('ok');
EOF
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
echo "PASS webui device page: five SoC buttons/theme groups, safe TSV parser/renderer, metamodule metadata, independent NoMount evidence and read-only loader"
)

t_device_info_runtime() (
# Runtime (fix230): real read-only collector against fake Android procfs/sysfs and SuSFS.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
D="$ROOT/tools/asb_device_info.sh"
fail() { echo "FAIL device info: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sh -n "$D" || fail "shell syntax"
mkdir -p "$T/mod/tools" "$T/proc/sys/net/ipv4" "$T/proc/sys/net/core" \
  "$T/sys/module/nomount" "$T/sys/module/ntsync" "$T/sys/module/baseband_guard" \
  "$T/sys/devices/system/cpu/cpufreq/policy0" "$T/sys/class/power_supply/battery" \
  "$T/data/asb" "$T/data/modules" "$T/data/metamodule"
cp "$ROOT/tools/asb_kernel_uv_coexist.sh" "$T/mod/tools/"
printf 'id=AutoSystemBoost\nversion=V65-129-fix230\nversionCode=65230\n' > "$T/mod/module.prop"
printf 'id=MetaCore\nname=MetaCore Metamodule\nversion=1.4.0\nversionCode=140\n' > "$T/data/metamodule/module.prop"
cat > "$T/props" <<'EOF'
[ro.product.brand]: [OnePlus]
[ro.product.manufacturer]: [OnePlus]
[ro.product.model]: [CPH2691]
[ro.product.device]: [OP15]
[ro.product.name]: [CPH2691]
[ro.product.market.name]: [OnePlus 15]
[ro.build.version.release]: [17]
[ro.build.version.sdk]: [37]
[ro.build.display.id]: [CPH2691_17.0.0.100]
[ro.build.fingerprint]: [OnePlus/CPH2691/OP15:17/TEST/user/release-keys]
[ro.build.version.oplusrom]: [ColorOS 17.0]
[gsm.version.baseband]: [TEST_BASEBAND]
[ro.soc.model]: [SM8850]
[ro.soc.manufacturer]: [QTI]
[ro.board.platform]: [sun]
[ro.hardware.chipname]: [SM8850]
[ro.serialno]: [DO_NOT_COLLECT_SERIAL]
[gsm.imei]: [DO_NOT_COLLECT_IMEI]
EOF
printf 'Linux version 6.12.30-custom (builder@host) #1 SMP PREEMPT\n' > "$T/proc/version"
printf 'console=ttyMSM0 androidboot.hardware=qcom\n' > "$T/proc/cmdline"
printf 'Hardware\t: Qualcomm Technologies, Inc SM8850\n' > "$T/proc/cpuinfo"
printf 'MemTotal: 16000000 kB\nMemAvailable: 9000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 7000000 kB\n' > "$T/proc/meminfo"
printf '12345.6 99999.9\n' > "$T/proc/uptime"; printf '1.25 1.10 0.90 1/100 1\n' > "$T/proc/loadavg"
printf 'reno bbr bbrv2\n' > "$T/proc/sys/net/ipv4/tcp_available_congestion_control"
printf 'bbr\n' > "$T/proc/sys/net/ipv4/tcp_congestion_control"; printf 'fq_codel\n' > "$T/proc/sys/net/core/default_qdisc"
printf '0-7\n' > "$T/sys/devices/system/cpu/online"; cp "$T/sys/devices/system/cpu/online" "$T/sys/devices/system/cpu/present"; cp "$T/sys/devices/system/cpu/online" "$T/sys/devices/system/cpu/possible"
for spec in 'related_cpus:0-3' 'scaling_governor:schedutil' 'scaling_cur_freq:1800000' 'scaling_min_freq:300000' 'scaling_max_freq:3200000' 'cpuinfo_min_freq:300000' 'cpuinfo_max_freq:3600000'; do
  printf '%s\n' "${spec#*:}" > "$T/sys/devices/system/cpu/cpufreq/policy0/${spec%%:*}"
done
printf '22 (105)\n' > "$T/sys/module/nomount/version"
for spec in 'capacity:88' 'status:Discharging' 'temp:331' 'current_now:412000' 'voltage_now:4210000' 'charge_full:5300000'; do
  printf '%s\n' "${spec#*:}" > "$T/sys/class/power_supply/battery/${spec%%:*}"
done
printf 'profile=smart\nstate=LIGHT_IDLE\ndevice_bounds_status=applied\n' > "$T/state"
printf 'android_api=37\nkernel=6.12.30-custom\nsoc=SM8850\npolicy_count=2\n' > "$T/data/asb/device_caps.env"
cat > "$T/config" <<'EOF'
CONFIG_LOCALVERSION="-custom"
CONFIG_PREEMPT=y
CONFIG_HZ=300
CONFIG_NOMOUNT=y
CONFIG_NTSYNC=y
CONFIG_NAMESPACES=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_UTS_NS=y
CONFIG_DEVTMPFS=y
CONFIG_UNICODE=y
# CONFIG_UNICODE_BYPASS_FIX is not set
# CONFIG_UNICODE_BYPASS is not set
CONFIG_TMPFS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_NONE is not set
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BBR2=y
CONFIG_SECURITY_BASEBAND_GUARD=y
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor,baseband_guard"
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
EOF
gzip -c "$T/config" > "$T/proc/config.gz"
cat > "$T/susfs" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SUSFS_LOG"
case "$1 $2" in
  'show version') printf 'v2.3.0\n' ;;
  'show variant') printf 'KernelSU-Next\n' ;;
  'show enabled_features') printf 'sus_path\nsus_mount\n' ;;
esac
EOF
chmod +x "$T/susfs"
run() {
  ASB_DEVINFO_MODDIR="$T/mod" ASB_DEVINFO_SYS="$T/sys" ASB_DEVINFO_PROC="$T/proc" \
  ASB_DEVINFO_DATA="$T/data" ASB_DEVINFO_PROP_FILE="$T/props" ASB_DEVINFO_SUSFS="$T/susfs" \
  ASB_DEVINFO_STATE="$T/state" SUSFS_LOG="$T/susfs.log" sh "$D"
}
want() {
  _line="$(printf 'D\t%s\t%s\t%s' "$1" "$2" "$3")"
  printf '%s\n' "$out" | grep -Fqx "$_line" || fail "missing [$_line] in: $out"
}
out="$(run)"
printf '%s\n' "$out" | awk -F '\t' 'NF < 4 || $1 != "D" || $2 == "" || $3 == "" { bad = 1 } END { exit bad }' || fail "malformed TSV"
want meta schema 2; want firmware baseband TEST_BASEBAND; want firmware android 17; want soc soc_model SM8850
want kernel_features nomount built-in; want kernel_features nomount_version '22 (105)'; want kernel_features ntsync built-in
want metamodule status 'detected at standard path'; want metamodule id MetaCore; want metamodule name 'MetaCore Metamodule'
want metamodule version 1.4.0; want metamodule version_code 140
want metamodule nomount_driver built-in; want metamodule nomount_driver_version '22 (105)'
want metamodule nomount_evidence 'kernel config/sysfs; driver ownership not inferred'
want kernel_features droidspaces 'core config present; runtime not verified'
# Generic CONFIG_UNICODE is not evidence of the patch.
want kernel_features unicode_bypass_fix 'not runtime-discoverable'
want kernel_features tmpfs_xattr_posix_acl supported; want kernel_features lto 'ThinLTO (Clang)'
want kernel_features bbr_v1 available; want kernel_features bbr_v2 available
want kernel_features bbg_baseband_guard 'active in LSM; built-in'
want kernel_features susfs 'interface available'; want kernel_features susfs_version v2.3.0
want asb_caps policy_count 2; want asb device_bounds_status applied
printf '%s\n' "$out" | grep -q 'DO_NOT_COLLECT' && fail "a sensitive identifier was collected"
[ "$(wc -l < "$T/susfs.log")" = 3 ] || fail "SuSFS called more than the three show reads"
grep -Ev '^show (version|variant|enabled_features)$' "$T/susfs.log" && fail "a state-changing SuSFS command ran"
# Missing metmodule version fields stay explicitly unknown; NoMount evidence remains independent.
printf 'id=MetaCore\nname=MetaCore Metamodule\n' > "$T/data/metamodule/module.prop"
out="$(run)"
want metamodule status 'detected at standard path'; want metamodule version 'not exposed'; want metamodule version_code 'not exposed'
want metamodule nomount_driver built-in; want metamodule nomount_driver_version '22 (105)'
# A directory without readable metadata is not reported as a complete installation.
rm -f "$T/data/metamodule/module.prop"; out="$(run)"
want metamodule status 'standard path present; module.prop not readable'; want metamodule version 'not exposed'
want metamodule nomount_driver built-in; want metamodule nomount_driver_version '22 (105)'
# No standard path is not universal proof of absence, and does not hide a running NoMount driver.
rmdir "$T/data/metamodule"; out="$(run)"
want metamodule status 'not detected at standard path'
want metamodule nomount_driver built-in; want metamodule nomount_driver_version '22 (105)'
# Runtime bbr2 spelling is accepted as BBRv2 too.
printf 'reno bbr bbr2\n' > "$T/proc/sys/net/ipv4/tcp_available_congestion_control"
out="$(run)"; want kernel_features bbr_v2 available
# A missing kernel config never becomes proof that a runtime driver is absent.
mv "$T/proc/config.gz" "$T/config.gz.saved"
out="$(run)"
want kernel_config available unavailable; want kernel_features nomount 'driver present'; want kernel_features ntsync 'driver present'
want kernel_features droidspaces unknown; want kernel_features unicode_bypass_fix 'not runtime-discoverable'
want kernel_features tmpfs_xattr_posix_acl unknown; want kernel_features lto unknown
want kernel_features bbr_v1 available; want kernel_features bbr_v2 available
# LKM NoMount/NTSync: loaded state and a version that the driver does not expose.
sed -i -e 's/^CONFIG_NOMOUNT=y$/CONFIG_NOMOUNT=m/' -e 's/^CONFIG_NTSYNC=y$/CONFIG_NTSYNC=m/' "$T/config"
gzip -c "$T/config" > "$T/proc/config.gz"; rm -f "$T/sys/module/nomount/version"
out="$(run)"
want kernel_features nomount 'module loaded'; want kernel_features nomount_version 'not exposed'; want kernel_features ntsync 'module loaded'
want metamodule nomount_driver 'module loaded'; want metamodule nomount_driver_version 'not exposed'
# An executable with no read response is not advertised as a working SuSFS interface.
cat > "$T/susfs" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/susfs"
out="$(run)"; want susfs interface present_no_read_response; want kernel_features susfs built-in; want kernel_features susfs_version 'not exposed'
# Explicit specialized config is the only positive Unicode Bypass evidence in this fixture.
printf '\nCONFIG_UNICODE_BYPASS_FIX=y\n' >> "$T/config"; gzip -c "$T/config" > "$T/proc/config.gz"
out="$(run)"; want kernel_features unicode_bypass_fix built-in
! grep -Eq 'set_uname|add_sus_path|add_sus_map|add_sus_kstat|add_sus_' "$D" || fail "a SuSFS writer entered the collector"
echo "PASS device info: read-only TSV, metamodule presence/version variants, built-in/LKM NoMount and version, kernel feature evidence and missing-config semantics"
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac
