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
grep -q '^LIGHT_LOW_KBPS="${ASB_LTE_LIGHT_LOW_KBPS:-4000}"' "$L" || fail "light low mark not 4 Mbit/s"
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
grep -q '\[ $(( _dk \* DELAY )) -ge $(( OFF_MIN_KIB \* _dt )) \] && break' "$L" || fail "screen-off LTE does not wait for mobile data"
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
grep -q "little: ASB's own thermal-budget trim" "$D" || fail "asbdiag blames the vendor for ASB's own trim"
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
echo "PASS: field-fix contracts"
