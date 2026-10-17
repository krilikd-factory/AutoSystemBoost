#!/bin/sh
# Field-fix contracts (fix90 onward), one section per fix. Kept in one file so that each
# small fix no longer adds a script of its own - new ones go in as a new section.

# ---- fix90 ----------------------------------------------------------------
(
# fix90: (1) never disable the kernel's reboot-on-panic / panic-on-oops - a wedged phone
# (OP12: black launcher, alarm missed, reboot fixed it) is worse than any saving;
# (2) LIGHT_IDLE escalates when the main cores sit at the light-idle ceiling (OP15: 52% of
# screen-on LIGHT_IDLE samples pinned at 1440 MHz).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL fix90: $*" >&2; exit 1; }
grep -rnE 'sysctlw kernel\.panic(_on_oops)? |/proc/sys/kernel/panic(_on_oops)?' \
  "$ROOT/service.sh" "$ROOT/post-fs-data.sh" "$ROOT/runtime" "$ROOT/profiles" 2>/dev/null \
  | grep -v '^\s*#' | grep -v ':[0-9]*: *#' && fail "a script still writes kernel.panic / panic_on_oops"
F="$ROOT/src/asb_fsm.h"
grep -Fq '#define ASB_LI_PIN_HOLD_S 40' "$F" || fail "pin hold constant"
grep -Fq 'if (_cm > 0 && _cc > 0 && _cc * 100 >= _cm * 98) _sl = _c;' "$F" || fail "pinned test"
grep -Fq 'if (m->misc.screen_on && !fsm_profile_is_battery && !m->misc.camera_active) {' "$F" || fail "escalation must be screen-on, not Battery, not camera"
grep -Fq 'light_idle_pin_escalations=' "$ROOT/src/asb_governor.c" || fail "escalations not published"
grep -q 'resetprop -n tombstoned.max_tombstone_count 0' "$ROOT/post-fs-data.sh" && fail "native crash records still thrown away"
grep -Eq 'for _svc in .*(minidump|mtdoopslog|bootstat)' "$ROOT/service.sh" && fail "bg_trim still stops the crash recorders"
grep -Fq 'kernel panic policy' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the panic policy"
for _k in persist.sys.crash_dumps persist.sys.pstore_dumps persist.sys.mdlog_dumpback \
          persist.sys.oom_crash_on_watchdog persist.sys.stability.nativehang.enable \
          persist.sys.stability.nativehangII.enable persist.sys.stability.qcom_hang_task.enable \
          persist.sys.stability.scout.enable persist.sys.stability.enable_res_leak_abort; do
  grep -q "^$_k=" "$ROOT/runtime/asb_managed.props" && fail "managed props still set $_k"
done
echo "PASS fix90: panic reboot left to the vendor, pinned light idle escalates"
) || exit 1

# ---- fix94 ----------------------------------------------------------------
(
# fix94: tombstones kept by the platform; carried-over drain rate never replaces a live one;
# the ASB board-temperature cell is not labelled as the die.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
grep -qE '^tombstoned\.max_tombstone_count=' "$ROOT/runtime/asb_managed.props" && fail "managed props still zero tombstones"
grep -qE '^ro\.tombstoned\.crash\.dump=' "$ROOT/runtime/asb_managed.props" && fail "managed props still disable tombstone dumps"
G="$ROOT/src/asb_governor.c"
grep -q 'if (live_x10 <= 0 && g_smart_drain_last_x10 > 0' "$G" || fail "stale drain rate can override the live one"
grep -q 'if (_live_stale) _pub_win = 0;' "$G" || fail "carried-over rate published with a live window"
grep -q "T('lv_board', 'Board')" "$ROOT/webroot/index.html" || fail "board cell still labelled as die"
for f in "$ROOT"/webroot/i18n/*.json; do
  grep -q '"lv_board"' "$f" || fail "lv_board missing in $f"
  grep -q '"lv_board_tip"' "$f" || fail "lv_board_tip missing in $f"
done
echo "PASS: fix94 contract"
) || exit 1

# ---- fix95 ----------------------------------------------------------------
(
# fix95: the 40% ceiling guard snaps UP to a real OPP; asbdiag reads screen state from the
# governor when the panel node is absent and flags post-boot heat in the throttle warning.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
W="$ROOT/src/asb_writer.h"
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" > /tmp/_asb_fc.$$ 
grep -q 'if (v >= guard && (up == 0 || v < up)) up = v;' /tmp/_asb_fc.$$ || { rm -f /tmp/_asb_fc.$$; fail "guard still rounds down below 40%"; }
rm -f /tmp/_asb_fc.$$
# Runtime: build the guard against the OP15 prime table and check the result.
T="${TMPDIR:-/tmp}/asb_fix95.$$"; mkdir -p "$T"
cat > "$T/t.c" <<'C'
#include <stdio.h>
static long g_cpu_freq_tables[16][32]; static int g_cpu_freq_table_len[16];
static void cpu_read_freq_tables(void) {}
static long cpu_snap_freq(int p, long w) { long b=0; for (int i=0;i<g_cpu_freq_table_len[p];i++){long v=g_cpu_freq_tables[p][i]; if(v<=w&&v>b)b=v;} return b?b:w; }
#define ASB_MIN_CEILING_PCT_OF_HW 40
C
awk '/^static int cpu_floor_ceiling/,/^}/' "$W" >> "$T/t.c"
cat >> "$T/t.c" <<'C'
int main(void){
  long t[]={1497600,1747200,1900800,2380800,4608000};
  for(int i=0;i<5;i++) g_cpu_freq_tables[1][i]=t[i]; g_cpu_freq_table_len[1]=5;
  int a=cpu_floor_ceiling(1,1497600,0), b=cpu_floor_ceiling(1,1497600,1), c=cpu_floor_ceiling(1,2380800,0);
  if(a!=1900800||b!=1497600||c!=2380800){printf("got %d %d %d\n",a,b,c);return 1;}
  return 0; }
C
gcc -O0 -o "$T/t" "$T/t.c" 2>"$T/err" || { cat "$T/err"; rm -rf "$T"; fail "guard harness does not build"; }
"$T/t" || { rm -rf "$T"; fail "guard result wrong"; }
rm -rf "$T"
D="$ROOT/tools/asb_diag.sh"
grep -q "grep -m1 '^screen=\[01\]\$' /dev/.asb/state" "$D" || fail "diag plan line has no governor screen fallback"
grep -q 'post-boot dexopt/indexing heat' "$D" || fail "throttle warning does not flag post-boot heat"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag differs from tools/asb_diag.sh"
echo "PASS: fix95 contract"
) || exit 1

# ---- fix96 ----------------------------------------------------------------
(
# fix96: budget grading scales by the anchor level; screen forecast falls back to the slot's
# learned drain before a fixed mA; diag block order; zero-second dwell hidden.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '(_elapsed \* (long)g_budget_acc_anchor_pct \* 100L)' "$G" || fail "budget grade not scaled by anchor level"
grep -q '(_elapsed \* 100L \* 100L)' "$G" && fail "old per-100% budget grade still present"
# Arithmetic: 44 % anchor, 3.3 h to empty -> 13.3 %/h -> 30 min predicts ~6.7 %.
_p=$(( 1800 * 44 * 100 / (33 * 360) ))
[ "$_p" -ge 660 ] && [ "$_p" -le 670 ] || fail "budget grade arithmetic: $_p"
A="$ROOT/action.sh"

grep -q 'smart_bucket_drain_x10=" /dev/.asb/state' "$A" || fail "action ETA lacks slot fallback"
grep -q '_eta_kind=slot' "$A" || fail "action ETA slot kind missing"
grep -q "kv.smart_bucket_drain_x10 || '0'" "$ROOT/webroot/index.html" || fail "WebUI ETA lacks slot fallback"
for l in ar de en es fr hy id it pt ru tr uk zh; do
  { [ "$l" = en ] || grep -q "^T_ETA_SLOT=" "$ROOT/runtime/i18n/action_$l.sh"; } || fail "T_ETA_SLOT missing: $l"
  grep -q '"eta_slot"' "$ROOT/webroot/i18n/$l.json" || fail "eta_slot missing: $l"
done
grep -q '^T_ETA_SLOT=' "$A" || fail "T_ETA_SLOT default missing"
D="$ROOT/tools/asb_diag.sh"
_l=$(grep -n 'P "  LMKD / vmpressure props:"' "$D" | cut -d: -f1)
_r=$(grep -n 'for _p in ro.lmk.use_psi' "$D" | cut -d: -f1)
_o=$(grep -n 'P "  OEM toggles' "$D" | cut -d: -f1)
[ "$_l" -lt "$_r" ] && [ "$_r" -lt "$_o" ] || fail "LMKD props not under their header"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag differs"
grep -q '\[ "$_g_dwell" -lt 5 \] && _g_dwell=""' "$A" || fail "zero-second dwell still printed"
echo "PASS: fix96 contract"
) || exit 1
# ---- fix97 ----------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix97: $*"; exit 1; }
[ -e "$ROOT/webroot/switch.mp3" ] && fail "switch.mp3 is back"
grep -q 'switch\.mp3"' "$ROOT/webroot/index.html" && fail "WebUI still loads switch.mp3"
grep -q 'clickAudio' "$ROOT/webroot/index.html" && fail "clickAudio fallback still referenced"
grep -q '^run_queue$' "$ROOT/tools/asb_full_regression.sh" || fail "regression no longer runs the queue"
grep -q 'ASB_REGRESSION_JOBS' "$ROOT/tools/asb_full_regression.sh" || fail "parallel runner missing"
echo "PASS: fix97 contract"
) || exit 1
# ---- fix99 ----------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix99: $*"; exit 1; }
A="$ROOT/action.sh"
F="${TMPDIR:-/tmp}/asb_npl.$$"
sed -n '/^_npl() {/,/^}/p' "$A" > "$F"
[ -s "$F" ] || fail "_npl helper missing"
_got="$(sh -c '. "$1"; M_X=many; M_X_1=one; M_X_2=few; M_E=items
  for n in 1 2 5 11 12 21 24 111 579; do printf "%s " "$(_npl $n M_X)"; done; _npl 3 M_E' _ "$F")"
rm -f "$F"
[ "$_got" = "one few many many many one few many many items" ] || fail "plural forms wrong: $_got"
grep -q '^    M_SES_LEARNED_1="сессия изучена"' "$A" || fail "ru singular form missing"
grep -q '$(_npl "$_l_sess" M_SES_LEARNED)' "$A" || fail "sessions line not pluralised"
grep -q 'в %s проверках' "$ROOT/runtime/i18n/action_ru.sh" && fail "ru vendor-ceiling line still declines a bare count"
echo "PASS: fix99 contract"
) || exit 1
# ---- fix100 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix100: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"
grep -q 'had WAKE_LOCK reset by the system - limit re-applied' "$W" || fail "lapsed fitness limit not re-asserted"
grep -q 'had WIFI_MULTICAST reset by the system - denial re-applied' "$W" || fail "lapsed multicast denial not re-asserted"
grep -q 'limit lapsed - the system reset this app-op' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not flag a lapsed limit"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix100 contract"
) || exit 1
# ---- fix101 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix101: $*"; exit 1; }
S="$ROOT/src/asb_smart.h"
grep -q 'static void asb_smart_apply_memory_pressure(asb_smart_runtime_t \*rt, int screen_on) {' "$S" || fail "memory lean has no screen gate"
grep -q '    if (screen_on) return;' "$S" || fail "memory lean still applies with the screen on"
grep -q 'm->misc.screen_on, &g_smart_rt);' "$ROOT/src/asb_governor.c" || fail "modifiers not told the screen state"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix101 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n'
  sed -n '/^static int asb_smart_refresh_rate_hz(void) {/,/^}$/p' "$S" \
    | sed -e 's#"/sys/class/drm/sde-crtc-0/measured_fps"#getenv("FPS_FILE")#' -e 's#static const char \*paths#const char *paths#'
  cat <<'X'
int main(void) { printf("%d\n", asb_smart_refresh_rate_hz()); return 0; }
X
} > "$T/t.c"
"$CC" -O2 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "refresh fixture did not compile"; }
chk() { printf '%s\n' "$1" > "$T/fps"; r="$(FPS_FILE="$T/fps" "$T/t")"; [ "$r" = "$2" ] || fail "measured_fps '$1' -> $r, want $2"; }
chk 'fps: 59.9 duration:500000 frame_count:30' 59
chk 'fps: 120.0 duration:500000 frame_count:60' 120
chk 'fps: 1.0 duration:500000 frame_count:1' 0
chk '90' 90
echo "PASS: fix101 contract"
) || exit 1
# ---- fix102 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix102: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q 'g_cam_pids\[g_cam_npid++\] = pid;' "$M" || fail "camera scan still stops at the first match"
grep -q 'cam_read_jiffies_all() : cam_read_jiffies(g_cam_pid)' "$M" || fail "camera load not summed"
grep -q 'wall - g_cam_scan_ts >= 300 && wall >= g_cam_hold_until' "$M" || fail "camera set never refreshed"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix102 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <sys/types.h>\n'
  printf '#define ASB_CAM_PID_MAX 8\nstatic pid_t g_cam_pids[ASB_CAM_PID_MAX]; static int g_cam_npid = 0;\n'
  sed -n '/^static unsigned long long cam_read_jiffies(pid_t pid) {/,/^}$/p' "$M"
  sed -n '/^static unsigned long long cam_read_jiffies_all(void) {/,/^}$/p' "$M"
  cat <<'X'
int main(void) {
    volatile unsigned long x = 0; for (unsigned long i = 0; i < 300000000UL; i++) x += i;
    unsigned long long self = cam_read_jiffies(getpid());
    g_cam_pids[0] = 999999; g_cam_pids[1] = getpid(); g_cam_npid = 2;
    unsigned long long all = cam_read_jiffies_all();
    if (all < self) { printf("sum %llu < self %llu\n", all, self); return 1; }
    g_cam_pids[1] = 999998;
    if (cam_read_jiffies_all() != 0ULL) { puts("all dead must read 0"); return 1; }
    return 0;
}
X
} > "$T/t.c"
"$CC" -O0 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "camera fixture did not compile"; }
"$T/t" || fail "camera load sum wrong"
echo "PASS: fix102 contract"
) || exit 1
# ---- fix103 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix103: $*"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^asb_cpu_cluster_init() {/,/^}$/p' "$ROOT/runtime/profile_core.sh" > "$T/f.sh"
[ -s "$T/f.sh" ] || fail "asb_cpu_cluster_init not found"
mk() { # name present "pol:cpus:max" ...
  d="$T/$1"; mkdir -p "$d/cpufreq"; echo "$2" > "$d/present"; shift 2
  for x in "$@"; do p="${x%%:*}"; r="${x#*:}"; c="${r%%:*}"; m="${r##*:}"
    mkdir -p "$d/cpufreq/policy$p"; echo "$c" > "$d/cpufreq/policy$p/related_cpus"; echo "$m" > "$d/cpufreq/policy$p/cpuinfo_max_freq"; done; }
mk op12 0-7 "0:0 1:2265600" "2:2 3 4:3148800" "5:5 6:2956800" "7:7:3302400"
mk op15 0-7 "0:0 1 2 3 4 5:3628800" "6:6 7:4608000"
mk sm8550 0-7 "0:0 1 2:2016000" "3:3 4 5 6:2803200" "7:7:3187200"
got() { sh -c '. "$1"; PROFILE="$3"; ASB_CPU_SYSFS="$2" asb_cpu_cluster_init; echo "$FG_CPUS|$BG_CPUS"' _ "$T/f.sh" "$T/$1" "$2"; }
[ "$(got op12 battery)" = "0-6|0-1" ] || fail "OP12 battery: $(got op12 battery)"
[ "$(got op15 battery)" = "0-5|0-5" ] || fail "OP15 battery: $(got op15 battery)"
[ "$(got sm8550 battery)" = "0-6|0-2" ] || fail "SM8550 battery: $(got sm8550 battery)"
[ "$(got op12 balanced)" = "0-7|0-1" ] || fail "OP12 balanced: $(got op12 balanced)"
echo "PASS: fix103 contract"
) || exit 1
# ---- fix104 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix104: $*"; exit 1; }
S="$ROOT/service.sh"
grep -q 'writef_retry /dev/cpuset/top-app/cpus         "0-${bat_fg_end}"' "$S" || fail "service.sh battery top-app still on the first cluster"
grep -q '_fg="0-${bat_fg_end}"' "$S" || fail "service.sh battery cgroup pass still on the first cluster"
# Run the derivation block against fake per-cpu sysfs for OP12 and OP15.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^_prime_hi=0; _prime_start=""$/,/^esac$/p' "$S" | sed 's#/sys/devices/system/cpu/#$CPUS/#g' > "$T/b.sh"
[ -s "$T/b.sh" ] || fail "derivation block not found"
mk() { d="$T/$1"; shift; i=0; for f in "$@"; do mkdir -p "$d/cpu$i/cpufreq"; echo "$f" > "$d/cpu$i/cpufreq/cpuinfo_max_freq"; i=$((i+1)); done; }
mk op12 2265600 2265600 3148800 3148800 3148800 2956800 2956800 3302400
mk op15 3628800 3628800 3628800 3628800 3628800 3628800 4608000 4608000
r12="$(CPUS="$T/op12" cpu_max=7 little_end=1 sh -c '. "$1"; echo $bat_fg_end' _ "$T/b.sh")"
r15="$(CPUS="$T/op15" cpu_max=7 little_end=5 sh -c '. "$1"; echo $bat_fg_end' _ "$T/b.sh")"
[ "$r12" = 6 ] || fail "OP12 battery foreground end $r12, want 6"
[ "$r15" = 5 ] || fail "OP15 battery foreground end $r15, want 5"
echo "PASS: fix104 contract"
) || exit 1
# ---- fix107 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix107: $*"; exit 1; }
D="$ROOT/runtime/smart_dynamic_tune.sh"
grep -q "s/^full .*avg10=" "$D" || fail "screen-on swappiness ignores memory stalls"
grep -q 'if \[ "$_psf_i" -ge 2 \] 2>/dev/null && \[ "$_swp" -lt $((_base + 20)) \]; then' "$D" || fail "stall gate changed"
sh -n "$D" || fail "smart_dynamic_tune.sh syntax"
grep -q 'fsm.state == ASB_STATE_MODERATE ? "MODERATE" : "HEAVY"' "$ROOT/src/asb_governor.c" || fail "lift log does not name the state"
echo "PASS: fix107 contract"
) || exit 1
# ---- fix108 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix108: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '(_mem_stall << 1) | screen_on_v;' "$G" || fail "tuner signature has no memory-stall bit"
grep -q 'if (_pf >= 200) {' "$G" || fail "stall entry threshold changed"
grep -q 'else if (_pf >= 0 && _pf < 100) _mem_stall = 0;' "$G" || fail "stall exit hysteresis missing"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS: fix108 contract (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n'
  sed -n '/^static int asb_read_mem_psi_full_x100(void) {/,/^}$/p' "$G" | sed 's#"/proc/pressure/memory"#getenv("PSI")#'
  printf 'int main(void){printf("%%d\\n", asb_read_mem_psi_full_x100());return 0;}\n'; } > "$T/t.c"
"$CC" -O2 -o "$T/t" "$T/t.c" 2>"$T/e" || { cat "$T/e"; fail "PSI fixture did not compile"; }
printf 'some avg10=7.39 avg60=8.41 avg300=2.74 total=9449753\nfull avg10=4.78 avg60=4.16 avg300=1.26 total=4448849\n' > "$T/p"
[ "$(PSI="$T/p" "$T/t")" = 478 ] || fail "full avg10 parsed as $(PSI="$T/p" "$T/t")"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' > "$T/p"
[ "$(PSI="$T/p" "$T/t")" = -1 ] || fail "missing full line must read -1"
echo "PASS: fix108 contract"
) || exit 1
# ---- fix109 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix109: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"
grep -Fq 'int _cand[2] = { _multi ? 1 : 0, _multi ? 2 : -1 };' "$F" || fail "light-idle pin still watches only slot 0 on 3/4-cluster parts"
grep -Fq '_li_pin_slot = _sl;' "$F" || fail "pinned slot not remembered for the hold"
grep -Fq '_li_pin_cap = 0; _li_pin_slot = -1; }' "$F" || fail "pinned slot not cleared when the hold ends"
echo "PASS: fix109 contract"
) || exit 1
# ---- fix110 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix110: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"
grep -Fq '? _t10 : fsm->ses_temp_ema_x10 + (_t10 - fsm->ses_temp_ema_x10) / 4;' "$F" || fail "session temperature EMA missing"
grep -Fq 'fsm->ses_max_temp_sm         = 0;' "$F" || fail "smoothed peak not reset per session"
grep -Fq 'sin.max_temp_c = (fsm->ses_max_temp_sm > 0) ? fsm->ses_max_temp_sm : fsm->ses_max_temp;' "$G" || fail "learner still taught the raw single-sample peak"
grep -Fq 'ses_max_temp_raw=%d\nses_max_temp_smooth=%d\n' "$G" || fail "raw/smooth peaks not published"
# Safety thresholds keep the RAW peak.
grep -Fq 'if (fsm->ses_max_temp >= 90) cur_cause = 5;' "$G" || fail "safety classification moved off the raw peak"
# EMA arithmetic: a one-tick 94 C spike over a 45 C session must not reach 70 C.
e=450; pk=0; for t in 45 45 94 45 45 45; do e=$(( e + (t*10 - e) / 4 )); s=$(( (e+5)/10 )); [ $s -gt $pk ] && pk=$s; done
[ "$pk" -lt 70 ] || fail "one-tick 94 C spike reached $pk C"
e=450; pk=0; for t in 72 72 72 72 72 72 72 72 72 72 72 72; do e=$(( e + (t*10 - e) / 4 )); s=$(( (e+5)/10 )); [ $s -gt $pk ] && pk=$s; done
[ "$pk" -ge 70 ] || fail "sustained 72 C (12 ticks) reached only $pk C"
echo "PASS: fix110 contract"
) || exit 1
# ---- fix111 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix111: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"
grep -Fq 'if (!_mem_stall) g_mem_stall_entries++;' "$G" || fail "stall entries not counted on the rising edge"
grep -Fq 'mem_stall_now=%d\nmem_stall_entries=%lu\n' "$G" || fail "stall counters not published"
grep -Fq 'screen-on memory stalls since governor start' "$D" || fail "asbdiag does not show memory stalls"
grep -Fq 'current session peak: raw ${_spr}C, smoothed ${_sps}C' "$D" || fail "asbdiag does not show raw vs smoothed peak"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix111 contract"
) || exit 1
# ---- fix112 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix112: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
grep -Fq '(tombstones kept: ${_tbk:-platform default})' "$D" || fail "unset tombstone prop still prints blank"
grep -Fq "see 'last boot reason' below" "$D" || fail "blank boot reason in the timeline"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
for f in "$ROOT"/common/*text.sh; do
  grep -q '^ASB_L_CAM_LIVE_DIRTY2=' "$f" || fail "$(basename "$f") lacks the camera advice"
  grep -qiE '^ASB_L_CAM_LIVE_DIRTY2=.*(disable ASB|отключите ASB|вимкніть ASB)' "$f" && fail "$(basename "$f") still asks to disable ASB first"
done
echo "PASS: fix112 contract"
) || exit 1
# ---- fix113 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix113: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; F="$ROOT/src/asb_fsm.h"; A="$ROOT/action.sh"
grep -Fq 'int _sm_boot = ((long)(_sm_now - _sm_t0) < 300);' "$F" || fail "boot window still feeds the smoothed peak"
grep -Fq 'if (!_sm_boot && m->therm.temp_valid' "$F" || fail "boot gate not applied"
grep -q '^T_A_VOICE=' "$A" || fail "no English voice-tone line"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_A_VOICE=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_A_VOICE missing: $l"
done
# Runtime: level 4 prints +2.0 / -2.4, level 0 and DSP off print nothing.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^_a_voice=/,/^esac$/p' "$A" > "$T/v.sh"
run() { sh -c '_f() { _sfmt="$1"; shift; printf "$_sfmt\n" "$@"; }; _cfg(){ echo "$V"; }; T_A_VOICE="v %s +%s -%s"; _a_dsp="$D"; . "$1"' _ "$T/v.sh"; }
[ "$(V=4 D=5 run | sed 's/^ *//')" = "v 4 +2.0 -2.4" ] || fail "level 4 rendered as '$(V=4 D=5 run)'"
[ -z "$(V=0 D=5 run)" ] || fail "level 0 printed a line"
[ -z "$(V=4 D=off run)" ] || fail "voice line printed with the DSP off"
echo "PASS: fix113 contract"
) || exit 1
# ---- fix114 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix114: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
# fix131: the drop mark moved to 2 Mbit/s and a sustained-demand mark (3 Mbit/s) was added -
# see test_lte_bulk_runtime.sh.
grep -q '^LIGHT_LOW_KBPS="${ASB_LTE_LIGHT_LOW_KBPS:-2000}"' "$L" || fail "light low mark not 2 Mbit/s"
grep -q '^LIGHT_BUSY_KBPS="${ASB_LTE_LIGHT_BUSY_KBPS:-3000}"' "$L" || fail "no sustained-demand mark"
grep -q '^LIGHT_HIGH_KBPS="${ASB_LTE_LIGHT_HIGH_KBPS:-12000}"' "$L" || fail "light high mark not 12 Mbit/s"
grep -q '^  screen_on) do_screen_on ;;' "$L" || fail "no screen_on entry"
grep -Fq 'asb_lte_screenoff.sh screen_on' "$ROOT/runtime/smart_dynamic_tune.sh" || fail "tuner still restores on every screen-on tick"
grep -Fq 'asb_lte_screenoff.sh restore' "$ROOT/runtime/smart_dynamic_tune.sh" && fail "tuner would undo a light LTE choice"
for c in config/governor.conf config/governor.conf.shipped; do
  grep -q '^net_lte_light=0$' "$ROOT/$c" || fail "$c: net_lte_light not off by default"
done
grep -q '^net_lte_light|' "$ROOT/config/key_ownership.tsv" || fail "key ownership missing"
[ "$(grep -c "net_screen_off_lte net_lte_light" "$ROOT/common/install.sh")" -ge 2 ] || fail "installer does not keep the toggle"
grep -Fq "key:'net_lte_light'" "$ROOT/webroot/index.html" || fail "no WebUI item"
grep -Fq "if (key === 'net_lte_light')" "$ROOT/webroot/index.html" || fail "WebUI toggle not live"
for j in "$ROOT"/webroot/i18n/*.json; do
  grep -q '"net_lte_light"' "$j" || fail "$(basename "$j") lacks net_lte_light"
done
for l in ar de es fr hy id it pt ru tr uk zh; do
  for k in T_N_LTE_LIGHT_LTE T_N_LTE_LIGHT_5G; do
    grep -q "^$k=" "$ROOT/runtime/i18n/action_$l.sh" || fail "$k missing: $l"
  done
done
grep -Fq 'fprintf(f, "screen_on=%d' "$ROOT/src/asb_governor.c" && fail "redundant screen_on= key is back (state has screen=)"
grep -Fq "5G only when needed: LTE chosen" "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the light mode"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix114 contract"
) || exit 1
# ---- fix115 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix115: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q '#include <sys/system_properties.h>' "$M" || fail "property API not included on Android"
grep -q '^#if defined(__ANDROID__)$' "$M" || fail "property include not guarded for host builds"
# the doze veto runs before every panel node
awk '/^static int metrics_screen_on\(/{f=1} f&&/asb_display_state_read\(\)/{print "prop"; exit} f&&/PATH_SCREEN_STATUS/{print "node"; exit}' "$M" | grep -qx prop \
  || fail "a panel node is read before Android's display state"
grep -q 'display_state|' "$ROOT/tools/logkit/_asb_logkit_common.sh" || grep -q '|wake|disp_state"' "$ROOT/tools/logkit/_asb_logkit_common.sh" \
  || fail "logkit display trace lacks wake/disp_state"
grep -q 'always-on display: %d of %d' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "full-day report does not count lit screen-off samples"
grep -q 'always-on display counted as screen-off' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report AOD time"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix115 contract"
) || exit 1
# ---- fix116 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix116: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q '^#include <sys/eventfd.h>$' "$G" || fail "eventfd header missing"
grep -q 'dlsym(RTLD_DEFAULT, "__system_property_wait")' "$G" || fail "waiter not resolved at run time (API 24 target)"
grep -q 'asb_disp_waiter_start();' "$G" || fail "waiter never started"
grep -q '^LDFLAGS=(-lm -ldl)' "$ROOT/src/build_ndk_release.sh" || fail "NDK build does not link libdl"
grep -q '^LDFLAGS="-lm -ldl"$' "$ROOT/src/build_termux.sh" || fail "Termux build does not link libdl"
grep -q 'display-state waiter:' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the waiter"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix116 contract"
) || exit 1
# ---- fix117 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix117: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'asb_bit_test(absb, ABS_MT_POSITION_X) && asb_bit_test(absb, ABS_MT_TRACKING_ID)' "$G" || fail "touch panel not identified by multitouch axes"
grep -q 'INPUT_PROP_DIRECT' "$G" || fail "touchpads/digitisers not excluded"
grep -q 'EVIOCGRAB' "$G" && fail "the touch node must never be grabbed"
grep -q 'touch watch:' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report the touch watch"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix117 contract"
) || exit 1
# ---- fix118 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix118: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'for (int i = 0; i < 20 && !pi; i++)' "$G" && fail "the waiter still gives up after ten minutes"
grep -q 'if (!pi) sleep(ASB_DISP_FIND_RETRY_S);' "$G" || fail "waiter does not keep looking for the property"
grep -q 'if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 0); return; }' "$G" || fail "screen-off still unparks the uevent socket with the waiter live"
grep -q 'if (g_disp_waiter_up == 2 && g_uev_parked) { wake_keys_park(epfd, 1); return; }' "$G" || fail "screen-on leaves the wake keys (touch panel) in epoll"
grep -q 'int _not_wake = (g_disp_waiter_up == 2 && (_dsr == 1 || _dsr == 3 || _dsr == 4));' "$G" || fail "resume chain not skipped when Android says off/doze"
grep -q '} else if (g_disp_waiter_up != 2 && g_uev_parked) {' "$G" || fail "uevent socket not given back when the waiter is gone"
grep -q 'screen_on_resume_skipped=%lu' "$G" || fail "skipped resume chains not published"
grep -q 'resume re-check(s) skipped' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report skipped resume chains"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix118 contract"
) || exit 1
# ---- fix119 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix119: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
grep -q 'case "$_dev" in rmnet\*|ccmni\*|v4-rmnet\*|v4-ccmni\*) return 0 ;; esac' "$L" || fail "CLAT route not read as mobile"
grep -q '"$_IPB" route show table all' "$L" || fail "VPN check still reads only the main table"
grep -q 'v4-rmnet\*|v4-ccmni\*) echo mobile' "$ROOT/runtime/asb_net_apply.sh" || fail "net apply does not class CLAT as mobile"
grep -q 'rmnet\*|ccmni\*|wwan\*|v4-rmnet\*|v4-ccmni\*)' "$ROOT/runtime/asb_net_routes.sh" || fail "route windows do not class CLAT as mobile"
grep -q '^T_N_LTE_LIGHT_HINT=' "$ROOT/action.sh" || fail "no English hint"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_N_LTE_LIGHT_HINT=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_N_LTE_LIGHT_HINT missing: $l"
done
grep -q 'g_asb_cfg.log_level >= (g_active_by_touch && calm ? 3 : 1)' "$ROOT/src/asb_governor.c" || fail "touch cadence still floods the log"
echo "PASS: fix119 contract"
) || exit 1
# ---- fix120 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix120: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
F="$ROOT/src/asb_fsm.h"
grep -q 'int cam_open = m->misc.camera_active;' "$G" || fail "camera flag not read by the app-hint inference"
[ "$(grep -c '} else if (!boot_grace && !cam_open &&' "$G")" = 2 ] || fail "a heat branch still infers a game with the camera open"
grep -q 'static const char \*_snames\[\]' "$G" && fail "heartbeat still carries its own state-name table"
grep -q 'asb_state_names\[fsm.state\] : "?",' "$G" || fail "heartbeat does not use the FSM state names"
# The name table must follow the enum, entry for entry.
_enum="$(sed -n '/^typedef enum {/,/} asb_state_t;/p' "$F" | grep -oE 'ASB_STATE_[A-Z_]+ *= *[0-9]+' | grep -v COUNT | sort -t= -k2 -n | sed -E 's/ASB_STATE_([A-Z_]+).*/\1/' | tr '\n' ' ')"
_names="$(sed -n '/^static const char \*asb_state_names\[\] = {/,/};/p' "$F" | grep -oE '"[A-Z_]+"' | tr -d '"' | tr '\n' ' ')"
[ -n "$_enum" ] || fail "state enum not found"
[ "$_enum" = "$_names" ] || fail "asb_state_names ($_names) does not follow the enum ($_enum)"
echo "PASS: fix120 contract"
) || exit 1
# ---- fix121 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix121: $*"; exit 1; }
L="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '^lk_capture_jank_row() {' "$L" || fail "no jank row capture"
grep -q 'lk_dumpsys graphicsstats' "$L" || fail "jank trace does not read graphicsstats"
grep -q '/^Janky frames:/ ' "$L" || fail "legacy janky count could be summed instead of the current one"
grep -q 'lk_capture_jank_row "$_phase" "${_dscr:-0}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "full-day capture does not record UI smoothness"
grep -q 'UI smoothness today' "$ROOT/tools/asb_diag.sh" || fail "asbdiag has no UI smoothness line"
grep -q 'jank_trace.tsv' "$ROOT/docs/log_schemas.md" || fail "jank_trace.tsv schema not documented"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'int _cma = asb_comfort_ma(m);' "$ROOT/src/asb_governor.c" || fail "comfort trims still read one current sample"
echo "PASS: fix121 contract"
) || exit 1
# ---- fix122 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix122: $*"; exit 1; }
L="$ROOT/runtime/asb_lte_screenoff.sh"
# fix131 restructured the loop (the timer keeps watching after the switch); the mobile-data
# gate is the same comparison.
grep -q '\[ $(( _dk \* DELAY )) -ge $(( OFF_MIN_KIB \* _dt )) \]; }; then' "$L" || fail "screen-off LTE does not wait for mobile data"
grep -q '_screen_off_strict || return 0' "$L" || fail "no re-check right before the switch"
grep -q 'the screen came on during the switch' "$L" || fail "an interrupted switch is not given back"
grep -q '/ccmni\*; do' "$L" || fail "ccmni links not counted by the scripts"
grep -q 'ccmni\*/statistics/rx_bytes' "$ROOT/runtime/asb_screenoff_class.sh" || fail "screen-off classifier ignores ccmni"
grep -q 'strncmp(nm, "ccmni", 5)' "$ROOT/src/asb_metrics.h" || fail "governor does not count ccmni"
grep -q '"rmnet_ipa0"' "$ROOT/src/asb_metrics.h" && fail "governor still adds the ipa0 transport"
grep -q 'quiet_windows=' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report quiet windows"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix122 contract"
) || exit 1
# ---- fix123 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix123: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"
grep -q 'strstr(type, "cpu_big") || strstr(type, "cpu-big")' "$M" || fail "MediaTek big-core thermal zones not recognised"
grep -q 'strcmp(type, "soc_max") == 0 || strcmp(type, "mtktscpu") == 0' "$M" || fail "MediaTek SoC aggregate not recognised"
grep -q '"/sys/kernel/ged/hal/gpu_utilization",' "$M" || fail "no MediaTek GPU load source"
grep -q 'case_mediatek_lvts_names();' "$ROOT/tests/test_thermal_socd_validation.c" || fail "no MTK thermal fixture"
echo "PASS: fix123 contract"
) || exit 1
# ---- fix124 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix124: $*"; exit 1; }
S="$ROOT/src/asb_smart.h"
grep -q 'if (asb_smart_pkg_via_activity_top(pkg' "$S" && fail "dumpsys activity top still in the probe chain"
grep -q 'int _topapp = asb_smart_pkg_via_topapp(pkg, sizeof(pkg));' "$S" || fail "top-app cgroup not asked"
grep -q '"/dev/cpuset/top-app/cgroup.procs"' "$S" || fail "top-app cpuset not read"
grep -q 'if (_upn - g_user_poll_ts >= 120' "$ROOT/src/asb_governor.c" || fail "user poll still every few ticks"
grep -q 'from the top-app cgroup' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not report top-app answers"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix124 contract"
) || exit 1
# ---- fix125 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix125: $*"; exit 1; }
UI="$ROOT/webroot/index.html"
B="$ROOT/tools/asb_config_backup.sh"
_cell="$(awk '/^\.live-cell \{/{on=1} on{print} on&&/^}/{exit}' "$UI")"
printf '%s\n' "$_cell" | grep -Eq '^ *min-height: 54px;' || fail "forecast cells do not grow with their text"
printf '%s\n' "$_cell" | grep -Eq '^ *height: 54px;' && fail "fixed 54px cell height is back"
grep -q '_bundle_write()' "$B" || fail "no single-file export"
grep -q '_bundle_import()' "$B" || fail "no single-file import"
grep -q 'import-path FILE.asb|FILE.conf' "$B" || fail "usage does not name .asb"
grep -q 'const conf = !dir && /\\.(asb|conf)$/i.test(name);' "$UI" || fail "file browser does not list .asb"
A="$ROOT/runtime/asb_audio_apply.sh"
[ "$(grep -c '\[ "$(getprop "$1" 2>/dev/null)" = "$2" \] && return 0' "$A")" -ge 2 ] || fail "persist mirrors still rewritten when unchanged"
S="$ROOT/src/asb_smart.h"
grep -q 'if (screen_on_now && g_stat_probe_topapp > 0 && _ttl < 60) _ttl = 60;' "$S" || fail "dumpsys fallback not held back where the cgroup works"
grep -q 'probe_topapp_empty=%lu' "$ROOT/src/asb_governor.c" || fail "fallback reasons not published"
grep -q '(writer p%d: %s, req %d, holds %lu, backoff %lds)' "$ROOT/src/asb_governor.c" || fail "vendor_ceiling line lacks the writer status"
K="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '^lk_cap_share()' "$K" || fail "no time-at-ceiling from time_in_state"
grep -q '^lk_topapp_pkg()' "$K" || fail "no app column in the jank trace"
grep -q 'dstart = int(top / day) \* day' "$ROOT/tools/asb_diag.sh" || fail "asbdiag frames-today still keys on one start time"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix125 contract"
) || exit 1
# ---- fix126 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix126: $*"; exit 1; }
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"; W="$ROOT/src/asb_writer.h"
grep -q '#define ASB_ESC_ENTRY_MARGIN_C 3' "$F" || fail "no entry margin under the exit mark"
grep -q 'if (m->therm.cpu_max_c > _exit_c - ASB_ESC_ENTRY_MARGIN_C) {' "$F" || fail "burst opens right under its own exit mark"
grep -q 'int _pinned = (_pinned_prime && !asb_esc_ceiling_foreign(m, _ps)) ||' "$F" || fail "burst opens under a foreign ceiling"
grep -q 'g_fsm_slot_req_khz\[i\] = cmax\[i\];' "$W" || fail "writer does not record its kept request"
grep -q 'prime_escape_skip_warm=%lu\\nprime_escape_skip_foreign=%lu' "$G" || fail "escape refusals not published"
grep -q 'static int writer_slot_path_idx(int slot)' "$W" || fail "no slot -> policy table mapping"
grep -q 'writer_slot_ceiling(0, fsm.current_caps.cpu_max\[0\], fsm.thermal_cap);' "$G" || fail "vendor_ceiling still snaps with table index = slot"
grep -q 'desired_cpu_max_prime=%d\\neffective_cpu_max_prime=%d' "$G" || fail "prime figures not published"
grep -q 'screen_off_detect=\\"uevent:%lu,display:%lu,tick:%lu\\"' "$G" || fail "screen-off sources not counted"
grep -q 'asb_log("screen OFF (Android display state)")' "$G" || fail "waiter screen-off still logged as a tick"
D="$ROOT/tools/asb_diag.sh"
grep -q 'lifted to the race-to-idle floor (40% of hardware max)' "$D" || fail "asbdiag prime ceiling ignores the floor"
grep -q "_s0n: ASB's own thermal-budget trim" "$D" || fail "asbdiag blames the vendor for ASB's own trim"
grep -q 'screen-off noticed by:' "$D" || fail "asbdiag does not show screen-off sources"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q '|main_by=${_mb}|prime_by=${_pb}"' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "throttle rows carry no cause"
echo "PASS: fix126 contract"
) || exit 1
# ---- fix127 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix127: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; A="$ROOT/action.sh"; W="$ROOT/webroot/index.html"
grep -q 'fprintf(f, "forecast_rate_x10=%d\\nforecast_basis=%s\\n", _fr, _fb);' "$G" || fail "governor publishes no forecast"
grep -q '_frx=$(grep -m1 "^forecast_rate_x10=" /dev/.asb/state' "$A" || fail "action does not read the governor forecast"
grep -q "const _fRate = parseInt(kv.forecast_rate_x10 || '0', 10);" "$W" || fail "WebUI does not read the governor forecast"
grep -q '_ton_min=$(( _lvl \* 600 / _eta_rate ))' "$A" || fail "action minutes not percent over rate"
grep -q 'Math.floor(bcap \* 600 / ewma_x10)' "$W" || fail "WebUI minutes not percent over rate"
grep -q 'echo "       ${M_PREDICT}: $(_s "$T_ETA_SCREEN" "$_ton_h" "$_ton_m") ${_eta_note}"' "$A" || fail "Smart card prints its own forecast"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '^T_ETA_SCREEN=' "$ROOT/runtime/i18n/action_$l.sh" || fail "T_ETA_SCREEN missing: $l"
  grep -q '^T_ETA_AVG=".*%s' "$ROOT/runtime/i18n/action_$l.sh" || fail "forecast note without its rate: $l"
done
for l in ar de en es fr hy id it pt ru tr uk zh; do
  grep -q '"lv_avgdrain_tip"' "$ROOT/webroot/i18n/$l.json" || fail "slot tile tooltip missing: $l"
  grep -q '"unit_pcth"' "$ROOT/webroot/i18n/$l.json" || fail "unit missing: $l"
done
grep -q 'high-input-latency events %d' "$ROOT/tools/asb_diag.sh" || fail "asbdiag latency still a share"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
grep -q 'per cluster: the prime sat under a ceiling ASB did not write' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "verdict ignores the per-cluster cause"
Y="$ROOT/.github/workflows/build-release.yml"
grep -q 'prerelease:' "$Y" || fail "release workflow has no prerelease input"
grep -q 'rc\[1-9\]|rc\[1-9\]\[0-9\]) ;;' "$Y" || fail "prerelease tag not validated"
grep -q 'ASB_VER="${ASB_VER}-${PRERELEASE_INPUT}"' "$Y" || fail "prerelease does not name the build"
grep -q '\*conf_tuning_params.json.asbbase) asb_tw_cam_stock "$_bf" && asb_tw_base_rom_ok "$_bf" && continue ;;' "$ROOT/runtime/asb_tweaks.sh" \
  || fail "orphan prune deletes the stock camera baseline before the installer clones"
grep -q '\*conf_tuning_params.json.asbbase) asb_tw_base_rom_stamp "$_bp" ;;' "$ROOT/runtime/asb_tweaks.sh" || fail "camera baseline saved without a ROM stamp"
echo "PASS: fix127 contract"
) || exit 1
# ---- fix128 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix128: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; P="$ROOT/runtime/profile_core.sh"
grep -q 'if (!_live_stale && live_x10 > 0 && _pub_win >= 600 && _bconf >= 2) {' "$G" || fail "forecast does not lead with the actual drain"
grep -q '"lv_avgdrain": "Расход"' "$ROOT/webroot/i18n/ru.json" || fail "Monitor tile is not the actual drain"
grep -q '"eta_measured": "по факту"' "$ROOT/webroot/i18n/ru.json" || fail "actual forecast label not short"
grep -q '^T_ETA_MEASURED="(по факту %s)"' "$ROOT/runtime/i18n/action_ru.sh" || fail "action actual label"
grep -q 'rm -f "$_ux_base" 2>/dev/null' "$P" || fail "UX baseline restored on every run"
grep -q '\[ "$_cur_anim" = "$_mine" \] && _restore=1' "$P" || fail "restore ignores what the user set afterwards"
grep -q 'true > "$_ux_legacy"' "$P" || fail "legacy 0.8/0.9 cleanup not one-shot"
grep -q 'asb_anim_apply.sh" --if-changed' "$P" || fail "explicit Animation Speed loses to the profile"
grep -q 'animation scales: yours - ASB does not change them' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name the owner"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix128 contract"
) || exit 1
# ---- fix129 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix129: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"; L="$ROOT/runtime/asb_apply_ledger.sh"
grep -q '^static void thermal_conf_recheck(time_t now) {' "$M" || fail "no runtime confidence re-check"
grep -q '        thermal_conf_recheck(now);' "$M" || fail "re-check not called from the thermal read"
grep -q 'case_disputed_fallback_promoted_at_runtime();' "$ROOT/tests/test_thermal_socd_validation.c" || fail "no fixture for the promotion"
grep -q 'thermal_conf_promotions=%lu' "$ROOT/src/asb_governor.c" || fail "promotions not published"
grep -q 'rejected before on this ROM build - not retried' "$L" || fail "refused settings retried every pass"
grep -q '_lg_cr="$(printf' "$L" || fail "ledger note still forks per field"
grep -q "printf '%s|%.120s|%.120s" "$L" || fail "ledger field cap lost"
grep -q 'grep -Fq "setting|$_pb_ns:$_pb_key|" "$ASB_PROFILE_BASELINE" 2>/dev/null && return 0' "$ROOT/runtime/asb_baseline.sh" || fail "baseline capture reads Android for recorded keys"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix129 contract"
) || exit 1
# ---- fix130 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix130: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"
grep -q '^static void asb_main_capacity_parity(asb_profile_caps_t \*caps, const asb_metrics_t \*m,$' "$G" || fail "no main/prime parity"
grep -q 'if (g_parity_main_khz > want_p0) want_p0 = g_parity_main_khz;' "$G" || fail "the raised main ceiling would be logged as a leak"
grep -q 'if (g_parity_main_khz > _d0) _d0 = g_parity_main_khz;' "$G" || fail "desired_cpu_max0 does not include the raise"
grep -q '^static int writer_slot_step_at_least(int slot, long khz) {' "$ROOT/src/asb_writer.h" || fail "no step-at-or-above helper"
grep -q 'capacity at the ceilings: main' "$D" || fail "asbdiag does not show which cluster looks bigger"
grep -q 'main kept level with the prime' "$D" || fail "asbdiag does not report the raise"
grep -q 'uiAudioRelease(ctx, endAt);' "$ROOT/webroot/index.html" || fail "UI sounds keep the audio output open"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix130 contract"
) || exit 1
# ---- fix132 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix132: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; D="$ROOT/tools/asb_diag.sh"; I="$ROOT/common/install.sh"
grep -q '^#define ASB_PARITY_NEAR_PCT 90' "$G" || fail "no near-parity share"
grep -q 'lift = (int)top; near = 1;' "$G" || fail "level step over the limit still refuses everything"
grep -q 'main_parity_near=%d' "$G" || fail "state does not say the raise is the nearest step"
grep -q 'not raised - level needs $_mpo kHz, over 60% of the main maximum' "$D" || fail "asbdiag still says not needed when the limit refused it"
grep -q 'nearly level (within 10%)' "$D" || fail "asbdiag calls a near-level main ceiling the smaller cluster"
grep -q 'within 10%% of the prime' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "full-day report has no near-level bucket"
grep -q 'ASB_D_BT_STOCK:-BT absolute volume: stock' "$I" || fail "stock BT install prints an empty heading"
for f in "$ROOT"/common/*text.sh; do grep -q '^ASB_D_BT_STOCK=' "$f" || fail "ASB_D_BT_STOCK missing in ${f##*/}"; done
grep -q 'LK_BT_LAST_KIND' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "BT lifecycle recorder still writes a row per duplicate line"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix132 contract"
) || exit 1
# ---- fix133 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix133: $*"; exit 1; }
W="$ROOT/src/asb_writer.h"; D="$ROOT/tools/asb_diag.sh"; L="$ROOT/tools/logkit"
grep -q 'if (!_vendor_hold || requested == h->requested) {' "$W" || fail "a vendor hold still swallows a changed request"
grep -q 'writer_hold_bypass=%lu' "$W" || fail "hold bypasses not published"
grep -q 'sent through a vendor hold' "$D" || fail "asbdiag does not count hold bypasses"
grep -q 'by screen state        : screen on' "$L/asb_log_full_day.sh" || fail "timer wakeups not split by screen state"
grep -q "_ph() { awk" "$L/asb_log_full_day.sh" || fail "cost rates still divide by whole hours"
grep -q '^lk_sysui_verdict() {' "$L/_asb_logkit_common.sh" || fail "SystemUI restart has no verdict"
grep -q 'ASB_DSP_REFERENCE_OPTIONAL' "$ROOT/tests/test_dsp_reference_contract.sh" || fail "DSP reference has no explicit source-only switch"
grep -q 'ASB_DSP_REFERENCE_OPTIONAL' "$ROOT/.github/workflows/build-release.yml" && fail "release build must never skip the DSP reference"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix133 contract"
) || exit 1
# ---- fix134 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix134: $*"; exit 1; }
F="$ROOT/runtime/asb_wifi_fallback.sh"; N="$ROOT/runtime/asb_net_apply.sh"; B="$ROOT/tools/asb_config_backup.sh"
grep -q '^_enabled() { case "$(_cfg net_wifi_leave)" in weak|unusable|aggressive) return 0 ;; esac; return 1; }' "$F" || fail "leave watch still limited to one rung"
grep -q '^_uses_validation() { case "$(_cfg net_wifi_leave)" in unusable|aggressive)' "$F" || fail "weak rung reads validation"
grep -q '^_release_window() {' "$F" || fail "no escalating release window"
grep -q '_sn="${_sl%%\\|\*}"' "$F" || fail "release-window streak split not mksh-safe"
grep -q '^IDLE_INTERVAL_S=30' "$F" || fail "screen-off watch interval lost"
grep -q '_abw_prev=/data/adb/asb/avoid_bad_wifi.prev' "$N" || fail "avoid_bad_wifi written without keeping the device value"
grep -q 'case "$_nwl" in weak|unusable|aggressive) _wf=1' "$N" || fail "wifi_fallback status ignores weak/unusable"
grep -q 'avoid_bad_wifi.prev ] && _asb_net_any=1' "$ROOT/service.sh" || fail "boot apply skips a pending avoid_bad_wifi restore"
grep -q 'settings put global network_avoid_bad_wifi "$_abw_old"' "$ROOT/uninstall.sh" || fail "uninstall leaves avoid_bad_wifi=1"
grep -q 'Wi-Fi leave watch (' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the leave watch"
grep -q 'if \[ "${1:-}" = "--no-smart" \]; then _with_smart=0; shift; fi' "$B" || fail "save cannot leave the learning out"
grep -q '^smart_available() {' "$B" || fail "no smart-available probe"
grep -q '^_legacy_import() {' "$B" || fail "older multi-file copies have no line-by-line import"
grep -q "' --no-smart'" "$ROOT/webroot/index.html" || fail "save dialog does not pass the choice"
[ -f "$ROOT/tests/test_wifi_leave_rungs_runtime.sh" ] || fail "leave-rungs runtime test missing"
[ -f "$ROOT/tests/test_config_legacy_import_runtime.sh" ] || fail "legacy import runtime test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix134 contract"
) || exit 1
# ---- fix135 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix135: $*"; exit 1; }
A="$ROOT/runtime/asb_audio_apply.sh"; H="$ROOT/runtime/asb_dsp_thermal.sh"
[ -f "$H" ] || fail "no shared heat rule for the DSP gain"
grep -q 'cpu_max_c=' "$A" && fail "the DSP gain still follows the CPU's hottest core"
grep -q '^ASB_DSP_TH_BAT="${ASB_DSP_TH_BAT:-/sys/class/power_supply/battery/temp}"' "$H" || fail "heat rule not on the battery temperature"
grep -q 'case "$_tc_r" in bt|wired|call) echo "$_tc_g"; return 0 ;; esac' "$H" || fail "Bluetooth/wired reduced for heat"
grep -q '1) if \[ "$_ts_t" -ge 450 \]; then echo 2; elif \[ "$_ts_t" -lt 400 \]; then echo 0; else echo 1; fi ;;' "$H" || fail "no hysteresis"
grep -q 'asb_dsp_thermal_tick' "$ROOT/service.sh" || fail "no minute re-check"
grep -q 'if \[ "${_mwake:-0}" = 1 \]; then' "$A" || fail "mirror does not wake the attach daemon on a gain change"
[ -f "$ROOT/runtime/asb_dsp_live.sh" ] || fail "no live effect probe"
grep -q 'asb_dsp_live_state' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the live effect"
[ -f "$ROOT/tests/test_dsp_heat_backoff_runtime.sh" ] || fail "heat back-off runtime test missing"
[ -f "$ROOT/tests/test_dsp_live_state_runtime.sh" ] || fail "live state runtime test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix135 contract"
) || exit 1
# ---- fix136 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix136: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"; N="$ROOT/runtime/asb_net_apply.sh"; V="$ROOT/runtime/asb_ltpo_video.sh"
grep -q 'org.thoughtcrime.securesms|im.molly' "$W" || fail "Signal not protected by its real package id"
grep -q '^_wl_doze_exempt() {' "$W" || fail "apps exempt from battery optimisation can be restricted"
grep -q '^_wl_release_protected() {' "$W" || fail "a wrong earlier restriction is never released"
grep -q 'case "$_pall" in \*" congctl "\*) _congctl_ok=1; return 0 ;; esac' "$N" || fail "per-route congctl not decided on evidence"
grep -q 'cc\[\$_pk\]=\$_pw-pending' "$N" || fail "stale unsupported congestion verdict kept"
grep -q 'REARM_QUIET_S="${ASB_LTPO_REARM_QUIET_S:-10}"' "$V" || fail "no longer quiet after a touch restore"
grep -q 'ok_asb_dynamic (actual = ASB' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "a matching dynamic cap still reported as DESYNC"
grep -q 'T_N_SUF_WAIT' "$ROOT/action.sh" || fail "action screen silent about a per-link choice waiting for its link"
for t in test_wakelock_messenger_guard_runtime.sh test_net_congctl_probe_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix136 contract"
) || exit 1
# ---- fix137 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix137: $*"; exit 1; }
W="$ROOT/runtime/asb_wakelock_watch.sh"
grep -q 'elif \[ "\$_act" = 1 \] && \[ "\$_s" -lt 600 \] 2>/dev/null && \[ "\$_h" != 1 \]; then' "$W" || fail "a two-minute holder can still be restricted"
grep -q '^_wl_used_today() {' "$W" || fail "an app used today can be restricted"
grep -q '^_wl_rules_migrate() {' "$W" || fail "old-rule restrictions never handed back"
grep -q '_idle_due && _force=1 || continue' "$ROOT/service.sh" || fail "idle DSP route never refreshed"
grep -q 'in the interval the screen changed state' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "screen-change traffic still silently dropped"
grep -q "no ASB record of changing it" "$ROOT/tools/asb_diag.sh" || fail "avoid-bad-Wi-Fi owner not named"
for t in test_dsp_route_idle_runtime.sh test_logkit_traffic_edge_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix137 contract"
) || exit 1
# ---- fix138 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix138: $*"; exit 1; }
N="$ROOT/runtime/asb_net_apply.sh"
grep -q '_out="\$_out qdisc\[\$_pk\]=\$_pw-pending"' "$N" || fail "a per-link qdisc with no link still has no verdict"
grep -qF 'qdisc\[wifi*-pending*)' "$N" || fail "mapper has no pending for the Wi-Fi qdisc"
w="$(grep -nF 'qdisc\[wifi*-pending*)' "$N" | cut -d: -f1)"; g="$(grep -nF 'qdisc\[wifi*)' "$N" | head -1 | cut -d: -f1)"
[ "$w" -lt "$g" ] || fail "qdisc pending line after the generic ok line"
grep -q "case \"\$_pv\" in ''|\*=unsupported)" "$N" || fail "congestion kind without a verdict not filed as pending"
grep -q '_lgf="/dev/.asb/lru_gen_took_\$_lg"' "$ROOT/runtime/smart_dynamic_tune.sh" || fail "MGLRU node rewritten on every tuner run"
grep -q 'a bit missing here is one this kernel does not keep' "$ROOT/tools/asb_diag.sh" || fail "MGLRU bits not explained"
grep -q 'In detail: only an app that held the CPU for 10+ minutes' "$ROOT/webroot/index.html" || fail "wakelock card does not describe the fix137 rule"
for f in "$ROOT"/webroot/i18n/*.json; do
  case "${f##*/}" in en.json) continue ;; esac
  grep -q '10' "$f" || fail "${f##*/} lacks the wakelock rule text"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix138 contract"
) || exit 1
# ---- fix139 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix139: $*"; exit 1; }
E="$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp"
grep -q 'void queueCommon(const Parameter::Common& common)' "$E" || fail "AIDL effect has no way to take a new stream format"
grep -q 'mContext->queueCommon(param.get<Parameter::common>())' "$E" || fail "setParameter does not hand a new Parameter::common to the context"
grep -q 'if (mCommonPending.load(std::memory_order_acquire)) applyPendingCommonLocked();' "$E" || fail "process() never applies a queued format"
grep -q 'std::unique_lock<std::mutex> core(mCoreLock, std::try_to_lock);' "$E" || fail "process() waits on a settings push (or does not guard the core)"
grep -q 'applyTunables(mPushedGainMb);' "$E" || fail "a format change drops the gain pushed over binder"
grep -q 'mPushedGainMb = gainMb;' "$E" || fail "pushed gain not remembered"
# The freshness gate must not demand the new literal: an older library keeps working.
grep -q 'ASB reconfigure' "$ROOT/src/build_ndk_release.sh" && fail "release gate demands the fix139 literal"
grep -q 'rate=%s session=' "$ROOT/runtime/asb_dsp_live.sh" || fail "live state does not show the output rate"
grep -q '(Input|Record) thread' "$ROOT/runtime/asb_dsp_live.sh" || fail "capture threads counted against the output"
grep -q "ASB reconfigure" "$ROOT/tools/asb_diag.sh" || fail "asbdiag silent about a pre-fix139 library on a non-48 kHz output"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix139 contract"
) || exit 1
# ---- fix140 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix140: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q '> "\$LK_OUT_DIR/.wl_uid_delta"' "$C" || fail "per-uid batterystats deltas not kept"
grep -q "not one app's total moved in" "$C" || fail "a stalled batterystats still reads as 'no app held a wakelock'"
grep -q '^lk_capture_on_battery()' "$C" || fail "stall check not limited to a capture on battery"
grep -q 'batterystats disagrees with these samples:' "$C" || fail "live holders not checked against batterystats"
grep -q 'within %s (%s), by ASB state and touch' "$C" && grep -q 'wn += within(top, "most frames")' "$C" || fail "jank by state not shown inside one app"
F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -n 'echo "' "$F" | grep -q '`' && fail "a backtick inside a double-quoted echo runs a command"
grep -q "'hfp_audio_disconnect' is an HFP/SCO audio-link detach" "$F" || fail "Bluetooth evidence line still empty"
grep -q 'Look again for up to 3 s before naming anything' "$ROOT/tools/asb_diag.sh" || fail "asbdiag grades a momentary boost as a vendor floor"
grep -q 'vendor floor - \$_drv/\$_gov clamps the minimum, not a write failure' "$ROOT/tools/asb_diag.sh" && fail "unproven vendor-floor claim still printed"
for t in test_logkit_bstats_stall_runtime.sh test_jank_app_state_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix140 contract"
) || exit 1
# ---- fix141 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix141: $*"; exit 1; }
M="$ROOT/src/asb_metrics.h"; G="$ROOT/src/asb_governor.c"
grep -q 'No camera guard while the screen is off (fix141)' "$M" || fail "camera guard still runs with the screen off"
awk '/static int metrics_camera_active/ { f = 1 } f && /if \(!g_cam_scr_prev\) \{/ { ok = 1; exit } END { exit !ok }' "$M" || fail "screen-off check not in the camera probe"
grep -q '^static int metrics_pcm_playing(void)' "$M" || fail "no PCM playback probe"
grep -q 'if (!g_offdrain_media && metrics_pcm_playing() == 1) g_offdrain_media = 1;' "$G" || fail "screen-off drain does not notice playback"
grep -q 'g_offdrain_media_skipped++;' "$G" || fail "a window with music still counts as idle"
grep -q 'if (got >= 3 && fmt == ASB_OFFDRAIN_FMT' "$G" || fail "a pre-fix141 idle figure (music mixed in) is still trusted"
grep -q 'offdrain_media_skipped=%d' "$G" || fail "skipped windows not published"
grep -q 'if (!need_thermal && metrics.misc.screen_on && g_last_thermal_read_ts > 0 &&' "$G" || fail "a screen-on tick can still decide on an hours-old temperature"
grep -q 'not below the race-to-idle floor' "$G" || fail "cooldown log still claims the hardware minimum"
grep -q '^asb_cgroup_detach()' "$ROOT/runtime/asb_cgroup.sh" || fail "no cgroup detach helper"
for f in asb_ltpo_video.sh asb_wifi_fallback.sh asb_lte_screenoff.sh; do
  grep -q 'asb_cgroup_detach \$\$' "$ROOT/runtime/$f" || fail "$f watcher stays in the WebUI's app cgroups"
done
grep -q "uid_\[0-9\]+|/apps|/top-app|/foreground|frozen" "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "recorder still calls top-app not_needed"
grep -q '"runtime/asb_cgroup.sh"' "$ROOT/.github/workflows/build-release.yml" || fail "release build does not require asb_cgroup.sh"
grep -q '^_asb_tombstones() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name crashed processes"
grep -q '^lk_emit_native_crashes() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "captures do not name crashed processes"
grep -q '^lk_direct_temps() {' "$ROOT/tools/logkit/_asb_logkit_common.sh" || fail "stale governor temperatures still in the phase table"
grep -q 'com.radolyn.ayugram' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "Telegram forks not protected"
for t in test_camera_pcm_native_runtime.sh test_cgroup_detach_runtime.sh test_native_crash_names_runtime.sh test_logkit_stale_temp_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
[ -f "$ROOT/tests/test_camera_pcm_native.c" ] || fail "native fixture source missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix141 contract"
) || exit 1
# ---- fix142 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix142: $*"; exit 1; }
W="$ROOT/webroot/index.html"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'function cfgProfileShowResult(res)' "$W" || fail "save/apply outcome not shown in the window"
grep -q 'cfg_res_opened_banner' "$W" || fail "an opened file is not marked as not applied"
grep -q 'const settingsDone = ' "$W" || fail "a Smart-only failure after the settings were written reads as nothing applied"
grep -q 'echo "changed=' "$ROOT/tools/asb_config_backup.sh" || fail "restore does not report what it changed"
grep -q '} > "$_out.part" && mv -f "$_out.part" "$_out"' "$F" || fail "full-day report still rewritten in place"
grep -q 'phase_summary.txt.part' "$F" || fail "phase summary still rewritten in place"
grep -q 'oa = age; if (offst > 0 && e - offst < oa) oa = e - offst' "$C" || fail "live holds compared with batterystats including screen-on time"
grep -q '^lk_screen_off_min() {' "$C" || fail "stall claim without screen-off time"
grep -q 'first frame outside libc' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name the crashing code"
grep -q 'first frame outside libc' "$C" || fail "captures do not name the crashing code"
grep -q "AIDL library: fix139 build" "$ROOT/tools/asb_diag.sh" || fail "asbdiag cannot tell which DSP library is installed"
grep -q '^T_S_MC_PAST=' "$ROOT/action.sh" || fail "multicast with Wi-Fi off still reads as a present cost"
for f in "$ROOT"/runtime/i18n/action_*.sh; do grep -q '^T_S_MC_PAST=' "$f" || fail "T_S_MC_PAST missing in ${f##*/}"; done
[ -f "$ROOT/tests/test_config_restore_outcome_runtime.sh" ] || fail "outcome test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix142 contract"
) || exit 1
# ---- fix143 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix143: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_gfx_pkg_delta() {' "$C" || fail "jank trace does not record which app drew the janky frames"
grep -q '|fg_pkg|jank_pkgs|wake"' "$C" || fail "jank trace header lacks column 17"
grep -q 'steady floor: %.2f janky frames a second' "$C" || fail "report does not tell a steady floor from lag"
grep -q 'printf "%-16s %9s %9s %8s %8s\\n", "ASB state", "intervals", "frames", "janky", "janky/s"' "$C" || fail "state table without janky/s"
grep -q '^asb_gfx_run_delta() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not measure frames per app while it runs"
grep -q 'wake_lock=\[^:" \]\*:"\\\*walarm' "$C" || fail "alarm list still counts releases and summary lines"
grep -q 'alarmtimer -16: a wake-up alarm was due within 2 s' "$C" || fail "alarmtimer refusals still called driver faults"
grep -q '^lk_wh_app_parse() {' "$C" || fail "phase holders still batterystats running totals"
grep -q '^lk_wh_kernel_snap() {' "$C" || fail "kernel holders not measured per phase"
grep -q 'LK_PH_SNAPSHOT=1' "$F" || fail "interim report snapshot still writes holder blocks"
grep -q 'asb_wakelock_watch.sh" fitness' "$ROOT/service.sh" || fail "fitness limit not put back after boot"
grep -q '^if \[ "\${1:-}" = fitness \]; then' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "watcher has no fitness-only pass"
for t in test_jank_floor_runtime.sh test_phase_wakeholders_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix143 contract"
) || exit 1
# ---- fix144 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix144: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"
grep -q 'runtime/asb_reconcile.sh"' "$G" && fail "governor still spawns the no-op reconcile --once"
grep -q 'runtime/asb_watchdog.sh"' "$G" && fail "governor still spawns the no-op watchdog --once"
grep -q '^asb_gov_liveness() {' "$ROOT/service.sh" || fail "no governor liveness check"
grep -q '^    asb_gov_liveness$' "$ROOT/service.sh" || fail "liveness check not on the housekeeping tick"
grep -q 'stopped cleanly (pid %d)' "$G" || fail "a clean stop leaves no trace"
grep -q '^asb_gov_starts() {' "$ROOT/tools/asb_diag.sh" || fail "asbdiag cannot tell crashes from boots"
grep -q 'not set at boot with the native governor' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still names a gmin target nothing applies"
[ -f "$ROOT/tests/test_gov_liveness_runtime.sh" ] || fail "liveness test missing"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix144 contract"
) || exit 1
# ---- fix145 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix145: $*"; exit 1; }
W="$ROOT/webroot/index.html"; D="$ROOT/tools/asb_diag.sh"
grep -q 'id="cfgSoundBtn" onclick="uiSoundToggle()"' "$W" || fail "no switch for the interface sounds"
grep -q '^function uiOtherAudioRefresh() {' "$W" || fail "cues still play over another app's audio"
grep -q "if (_screen !== _cfgShownScreen) {" "$W" || fail "settings entrance runs on every repaint (cards twitch)"
grep -q '^_vlim="$(dumpsys audio' "$D" || fail "asbdiag does not show Android's volume limits"
grep -q 'disabled|on) V "BT absolute volume disabled' "$D" || fail "asbdiag ignores bt_absvol_mode=disabled"
grep -q 'dsp_load_check.txt' "$D" || fail "asbdiag does not print the boot DSP load check"
grep -q '_dlc=/data/adb/asb/dsp_load_check.txt' "$ROOT/service.sh" || fail "no DSP load check a minute after boot"
grep -q '# volume limits (safe media volume, sound dose, absolute volume)' "$ROOT/tools/logkit/_asb_logkit_common.sh" \
  || fail "full-day audio snapshot without the volume limits"
[ -f "$ROOT/tests/test_webui_quiet_ui_runtime.sh" ] || fail "quiet-ui test missing"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix145 contract"
) || exit 1
# ---- fix146 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix146: $*"; exit 1; }
I="$ROOT/common/install.sh"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; D="$ROOT/tools/asb_diag.sh"
grep -q '^asb_reset_odm_binds() {' "$I" || fail "no odm bind reset ahead of the audio stage"
grep -q '^asb_odm_bound_by_asb() {' "$I" || fail "the generator cannot tell its own bind from stock"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q 'rm -rf "$_ob_root"' && fail "the generator wipes the DSP registration's bind again"
grep -q '^lk_cluster_roles() {' "$C" || fail "jank trace still guesses main/prime from policy numbers"
grep -q 'wn += within(topj, "most janky frames")' "$C" || fail "no table for the app with the most janky frames"
grep -q 'the little cluster (%s) runs no UI' "$C" || fail "report does not name the clusters on a 4-cluster part"
grep -q '_tier="little"; \[ "$_npol" -eq 2 \] && _tier="main"' "$D" || fail "asbdiag calls the six main cores little"
grep -q 'no ASB entry and no runtime bind queued - it is read before /vendor/etc' "$D" || fail "asbdiag does not explain a stock /odm effects config"
for t in test_cluster_roles_runtime.sh test_odm_bind_reinstall_runtime.sh; do
  [ -f "$ROOT/tests/$t" ] || fail "$t missing"
done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix146 contract"
) || exit 1
# ---- fix148 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix148: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_power_state() {' "$C" || fail "no power state that knows a paused charge"
grep -q 'case "$(lk_power_state "$_cs")" in' "$F" || fail "a battery-protection hold is filed as sleep again"
grep -q 'longest stretch off the charger was' "$F" || fail "night verdict counts the charger"
grep -q 'kernel holder on the charger:' "$F" || fail "charging-idle verdict names no kernel holder"
grep -q "else if (st\[0\] == 'D')                 b->charging = 0;" "$ROOT/src/asb_metrics.h" || fail "governor reads Not charging as on battery"
[ -f "$ROOT/tests/test_charge_hold_runtime.sh" ] || fail "charge hold test missing"
echo "PASS: fix148 contract"
) || exit 1
# ---- fix149 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix149: $*"; exit 1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q '^lk_bt_dump_filter() {' "$C" || fail "BT evidence still crowded out by Android 16 flag lines"
[ "$(grep -c 'lk_dumpsys bluetooth_manager 2>/dev/null | lk_bt_dump_filter' "$C")" = 2 ] || fail "a BT dump left unfiltered"
grep -q 'fwmark 0x0/0xffff iif lo .*lookup ' "$ROOT/runtime/asb_wifi_fallback.sh" || fail "leave-bad-Wi-Fi blind under a VPN"
grep -q 'fwmark 0x0/0xffff iif lo .*lookup ' "$ROOT/runtime/asb_lte_screenoff.sh" || fail "LTE check guesses the network under a VPN"
grep -q 'measured screen-off mobile traffic %.1f MiB, Wi-Fi %.1f MiB' "$F" || fail "screen-off traffic counts mobile only"
grep -q '_label="LITTLE"; \[ "$_cv_np" -eq 2 \] && _label="MAIN"' "$C" || fail "cap_verify calls the six main cores LITTLE"
grep -q 'metrics.bat.charging ? -1 : metrics.bat.current_ma' "$ROOT/src/asb_governor.c" || fail "hourly learner takes charging current as drain"
grep -q "tr '\\\\n' ',' | sed 's/,\$//') fps video" "$ROOT/runtime/asb_ltpo_video.sh" || fail "LTPO log line breaks on two rates"
for t in test_wifi_default_vpn_runtime.sh test_learner_charging_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
echo "PASS: fix149 contract"
) || exit 1
# ---- fix150 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix150: $*"; exit 1; }
G="$ROOT/src/asb_governor.c"; C="$ROOT/tools/logkit/_asb_logkit_common.sh"; D="$ROOT/tools/asb_diag.sh"
grep -q '^static int asb_unlock_lift_update(int screen_on, int touch_kick, long now_ms, int profile_idx,$' "$G" || fail "no unlock lift"
grep -q '^static void asb_smart_night_awake(int screen_on, int daypart, int is_weekend, time_t now) {$' "$G" || fail "no night-awake lean"
grep -q '^unlock_lift_s=3$' "$ROOT/config/governor.conf" && grep -q '^smart_night_awake=1$' "$ROOT/config/governor.conf" || fail "not shipped on"
cmp -s "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped" || fail "shipped governor.conf differs"
grep -q 'NF >= 18 && $18 == "wake" {' "$C" || fail "wake rows mixed into the ordinary jank figures"
grep -q '"wake" >> "$LK_OUT_DIR/jank_trace.tsv"' "$C" || fail "the wake itself is still in no row"
grep -q '_s0n="little"; \[ "$_s1n" = "prime" \] && _s0n="main"' "$D" || fail "asbdiag cap line calls the main cores little"
grep -q 'waiting_for_wifi_default_route) _f "       $T_N_FB_WAIT" ;;' "$ROOT/action.sh" || fail "action screen prints the watcher's raw token"
for t in test_unlock_lift_runtime.sh test_smart_night_awake_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix150 contract"
) || exit 1
# ---- fix151 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix151: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
_ln_nv="$(grep -n '^\[ -n "\$NVBASE" \] || NVBASE=/data/adb$' "$ROOT/customize.sh" | cut -d: -f1)"
_ln_fn="$(grep -n '^\. \$TMPDIR/functions.sh$' "$ROOT/customize.sh" | cut -d: -f1)"
[ -n "$_ln_nv" ] && [ -n "$_ln_fn" ] && [ "$_ln_nv" -lt "$_ln_fn" ] || fail "NVBASE not defaulted before the template reads it"
grep -q '  resetprop -n audio.safemedia.bypass true >/dev/null 2>&1 || true' "$ROOT/post-fs-data.sh" || fail "limiter switch does not set the bypass before Android starts"
grep -q 'audio.safemedia.bypass = ${_smb:-<unset>}' "$D" || fail "asbdiag does not show the bypass"
grep -q '_no_now="$(ls -d /sys/class/net/\*/queues/rx-\* 2>/dev/null | wc -l):$(cat /sys/class/net/wlan\*/tx_queue_len' "$ROOT/service.sh" || fail "a Wi-Fi queue reset by the driver is not noticed"
grep -q 'the queue did not take (send this diag)' "$D" || fail "asbdiag does not judge the Wi-Fi queue"
grep -q '^CONFIRM_INTERVAL_S=3$' "$ROOT/runtime/asb_wifi_fallback.sh" || fail "no fast confirmation"
for t in test_net_txqueue_runtime.sh test_wifi_leave_fast_confirm_runtime.sh test_asbdiag_report_host_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix151 contract"
) || exit 1
# ---- fix152 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix152: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
Z="$ROOT/runtime/asb_doze_apply.sh"
H="$ROOT/webroot/index.html"
grep -q '^if \[ "${1:-}" = list \]; then$' "$Z" || fail "the applier has no list for the picker"
_ln_l="$(grep -n '^if \[ "${1:-}" = list \]; then$' "$Z" | cut -d: -f1)"
_ln_c="$(grep -n '^case "$_lvl" in$' "$Z" | head -1 | cut -d: -f1)"
[ -n "$_ln_l" ] && [ -n "$_ln_c" ] && [ "$_ln_l" -lt "$_ln_c" ] || fail "list runs after the night block that pauses AOD"
grep -q '_ga_file="${_DZ_DIR}/doze_whitelist_added"' "$Z" || fail "no record of the exemptions ASB grants"
grep -q 'done < /data/adb/asb/doze_whitelist_added' "$ROOT/uninstall.sh" || fail "uninstall leaves ASB's grants behind"
grep -q 'doze_whitelist_removed" "$D/doze_whitelist_keep" 2>/dev/null' "$ROOT/runtime/asb_wakelock_watch.sh" || fail "wakelock watcher forgets apps the trim removed"
grep -q '^async function dozeOpenEditor() {$' "$H" || fail "no picker"
grep -q 'id="dozeKeepSearch" type="search"' "$H" || fail "the picker has no search"
grep -q 'made exempt by ASB: $(_dzn added)' "$D" || fail "asbdiag does not show the trim's records"
for t in test_doze_keep_list_runtime.sh test_webui_doze_keep_picker_runtime.sh test_wakelock_trimmed_exempt_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix152 contract"
) || exit 1
# ---- fix153 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix153: $*"; exit 1; }
D="$ROOT/tools/asb_diag.sh"
grep -q ' s of CPU per hour"$' "$D" || fail "asbdiag does not put ASB's CPU per hour"
grep -q '^    lk_emit_wifi_leave_summary$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the capture does not report Wi-Fi leaving"
grep -q '^  lk_wifi_leave_collect$' "$ROOT/tools/logkit/asb_log_full_day.sh" || fail "the capture does not keep the watcher's events"
[ -s "$ROOT/docs/field_baseline/fix150.json" ] || fail "no fix150 baseline to compare against"
[ -f "$ROOT/tools/asb_capture_compare.py" ] || fail "no comparison tool"
for t in test_logkit_wifi_leave_runtime.sh test_capture_compare_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS: fix153 contract"
) || exit 1
# ---- fix154 ---------------------------------------------------------------
(
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL fix154: $*"; exit 1; }
H="$ROOT/webroot/index.html"
grep -q '^  --page-fade-in: 0.26s;$' "$H" || fail "no fade timing"
grep -q 'translateX(-50%) translateX(120%)' "$H" && fail "pages still slide in from the right"
grep -q '^  audio_remove_volume_limit:APPLY_REBOOT,$' "$H" || fail "the limiter card still claims to apply at once"
grep -q "resetprop -n audio.safemedia.bypass true'" "$H" || fail "the limiter switch does not set the bypass"
grep -q '^LIGHT_HOLD_MAX_S="${ASB_LTE_LIGHT_HOLD_MAX_S:-2400}"$' "$ROOT/runtime/asb_lte_screenoff.sh" || fail "no growing 5G hold"
grep -q 'T_A_LIMIT_ON=' "$ROOT/action.sh" || fail "action screen does not show the limiter"
grep -q 'ASB_DOZE_KEEP:-/data/adb/asb/doze_whitelist_keep' "$ROOT/service.sh" || fail "background trim ignores the keep list"
for t in test_lte_light_flap_runtime.sh test_keep_list_guards_runtime.sh; do [ -f "$ROOT/tests/$t" ] || fail "$t missing"; done
echo "PASS: fix154 contract"
) || exit 1
echo "PASS: field-fix contracts"
