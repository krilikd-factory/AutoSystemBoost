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
grep -Fq '#define ASB_LI_PIN_HOLD_S 20' "$F" || fail "pin hold constant"
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
grep -q "grep -o '\"screen\":\[01\]' /dev/.asb/state" "$D" || fail "diag plan line has no governor screen fallback"
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
grep -q 'if (_pf >= 200) _mem_stall = 1;' "$G" || fail "stall entry threshold changed"
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
echo "PASS: field-fix contracts"
