#!/usr/bin/env bash
# Host regression for the native observer/lifecycle core, allowlist and pressure diagnostics.
# No Android app is injected here; on-device Zygisk validation remains a separate requirement.

t_zygisk_native_core_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer native core: $*" >&2; exit 1; }
  command -v g++ >/dev/null 2>&1 || { echo 'SKIP observer native core: no g++'; exit 0; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  cat > "$T/core.cpp" <<'CPP'
#include "asb_observer_core.h"
#include <cassert>
#include <iostream>
static AsbObserverFrame frame(int pid, const char *pkg, long long ms) {
  AsbObserverFrame f{}; f.magic=ASB_OBSERVER_MAGIC; f.version=ASB_OBSERVER_VERSION;
  f.kind=ASB_OBSERVER_EVENT_PROCESS_START; f.size=sizeof(f); f.pid=pid;
  f.process_start_ticks=99; f.monotonic_ms=ms; snprintf(f.package,sizeof(f.package),"%s",pkg); return f;
}
int main() {
  assert(asb_observer_package_valid("com.example.app"));
  assert(!asb_observer_package_valid("system_server"));
  assert(!asb_observer_package_valid("com.example..app"));
  assert(!asb_observer_package_valid("com.example.app:remote"));
  assert(asb_observer_base_package("com.example.app:remote") == "com.example.app");
  assert(asb_observer_package_denied("system_server"));
  assert(asb_observer_package_denied("com.android.systemui"));
  assert(asb_observer_package_denied("com.topjohnwu.magisk"));
  assert(asb_observer_package_denied("com.qualcomm.qti.service"));
  assert(!asb_observer_package_denied("com.example.app:remote"));
  AsbObserverCore c; auto a=frame(10,"com.example.app",1000);
  assert(c.start(a,1000)==AsbObserverResult::accepted && c.loaded()==1 && c.events_total()==1);
  assert(c.start(a,1001)==AsbObserverResult::duplicate && c.dropped()==1);
  auto b=frame(11,"com.example.app",1500);
  assert(c.start(b,1500)==AsbObserverResult::rate_limited && c.rate_limited()==1);
  auto bad=frame(12,"system_server",3000);
  assert(c.start(bad,3000)==AsbObserverResult::invalid && c.invalid()==1);
  bad=frame(13,"com.example.app",3000); bad.magic=0;
  assert(c.start(bad,3000)==AsbObserverResult::invalid);
  bad=frame(13,"com.example.app",3000); bad.size=1;
  assert(c.start(bad,3000)==AsbObserverResult::invalid);
  assert(c.exit(10) && !c.exit(10) && c.loaded()==0);
  AsbObserverCore limit;
  for (int i=0;i<70;i++) { auto f=frame(1000+i,"com.example.app",1000+i*1100); limit.start(f,1000+i*1100); }
  assert(limit.loaded()<=ASB_OBSERVER_MAX_PROCESSES);
  assert(limit.capacity_dropped()+limit.rate_limited()>0);
  AsbObserverCore hints;
  assert(!hints.hint_permit(0));
  assert(hints.hint_permit(1000));
  assert(!hints.hint_permit(2999)); // two-second anti-chatter interval
  for (int64_t t=3000;t<=15000;t+=2000) assert(hints.hint_permit(t));
  assert(!hints.hint_permit(17000)); // ninth request inside one minute is vetoed locally
  assert(hints.hint_permit(61000)); // expired rate window, not a timer or polling loop
  c.prune(120000); // expired history is bounded; live-process semantics are unchanged
  std::cout << "observer core ok\n";
}
CPP
  g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/core.cpp" -o "$T/core" || fail 'C++ build'
  "$T/core" | grep -qx 'observer core ok' || fail 'core assertions'
  echo 'PASS observer native core: validation, exclusions, lifecycle/hint rate bounds, exit and TTL'
)

t_zygisk_native_contract() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer native contract: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  S="$ROOT/src/zygisk/asb_observer.cpp"
  sh -n "$ROOT/runtime/asb_zygisk.sh" || fail 'allowlist shell syntax'
  bash -n "$ROOT/src/build_ndk_release.sh" || fail 'NDK build syntax'
  grep -q 'REGISTER_ZYGISK_MODULE(Observer)' "$S" || fail 'module entry missing'
  grep -q 'REGISTER_ZYGISK_COMPANION(companion_handler)' "$S" || fail 'companion entry missing'
  grep -q 'preServerSpecialize.*skip()' "$S" || fail 'system_server is not excluded'
  grep -q 'ASB_ZYGISK_DIR "/disable"' "$S" || fail 'safe disable is not checked'
  grep -q 'api_->exemptFd(socket_)' "$S" || fail 'process-lifetime socket is not retained'
  ! grep -q 'api_->hookJniNativeMethods\|api_->pltHook\|scaling_\|APP_FOREGROUND\|APP_CAMERA' "$S" \
    || fail 'observer gained hooks, hardware writes or unimplemented events'
  grep -q 'ASB_GOVERNOR_SOCKET "/dev/.asb/ctl.sock"' "$S" || fail 'bounded governor refresh channel missing'
  grep -q 'static const char command\[\] = "zygisk-refresh"' "$S" || fail 'refresh carries more than its fixed opcode'
  grep -q 'ASB_GOVERNOR_HINT_TIMEOUT_US 100000' "$S" || fail 'governor round trip is not bounded to 100 ms'
  ! grep -q 'profile:\|start-session:\|zygisk-refresh:' "$S" || fail 'observer gained a profile/policy command'
  [ "$(grep -c 'write_all(socket_' "$S")" = 1 ] || fail 'more than the single process-start send exists'
  grep -q 'std::lock_guard<std::mutex>' "$S" || fail 'parallel companion handlers are not serialized'
  grep -q 'SO_PEERCRED' "$S" && grep -q 'process_start_ticks(frame.pid)' "$S" || fail 'peer/PID reuse validation missing'
  G="$ROOT/src/asb_governor.c"
  sed -n '/else if (strcmp(cmd, "zygisk-refresh") == 0)/,/else if (strcmp(cmd, "status")/p' "$G" > "$T.hint"
  grep -q 'g_asb_cfg.zygisk_enabled' "$T.hint" && grep -q 'g_asb_cfg.zygisk_hints' "$T.hint" || fail 'governor hint opt-in gates missing'
  grep -q 'zygisk_observer/disable' "$T.hint" && grep -q 'err:screen_off' "$T.hint" || fail 'safe-mode/screen-off veto missing'
  grep -q 'need_metrics = 1' "$T.hint" && grep -q 'asb_smart_pkg_cache_invalidate' "$T.hint" || fail 'hint does not request fresh evidence'
  ! grep -q 'force_write = 1\|g_last_reassert = 0\|profile_idx =\|CPU_MAX\|scaling_' "$T.hint" || fail 'hint bypassed normal governor policy'
  rm -f "$T.hint"
  grep -q 'for _zabi in arm64-v8a armeabi-v7a' "$ROOT/src/build_ndk_release.sh" || fail 'both ABIs are not built'
  grep -q 'zygisk_module_entry' "$ROOT/src/build_ndk_release.sh" && grep -q 'zygisk_companion_entry' "$ROOT/src/build_ndk_release.sh" \
    || fail 'export verification missing'
  cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail 'asbdiag copies differ'
  if command -v g++ >/dev/null 2>&1; then
    cat > "$T/jni.h" <<'JNI'
#pragma once
#include <cstdint>
typedef int32_t jint; typedef int64_t jlong; typedef uint8_t jboolean; typedef void* jobject; typedef jobject jstring; typedef jobject jintArray; typedef jobject jobjectArray;
struct JNINativeMethod { const char* name; const char* signature; void* fnPtr; };
struct JNIEnv { const char* GetStringUTFChars(jstring, void*){return nullptr;} void ReleaseStringUTFChars(jstring,const char*){} };
JNI
    g++ -std=c++17 -Wall -Wextra -Werror -Wno-unused-parameter -I"$T" -I"$ROOT/src/zygisk" \
      -DASB_ABI_TAG='"arm64-v8a"' -fsyntax-only "$S" || fail 'native source syntax'
    cat > "$T/ipc.cpp" <<'CPP'
#include <string>
std::string test_dir, test_socket;
#define ASB_GOVERNOR_SOCKET (test_socket.c_str())
#define ASB_GOVERNOR_CLIENT_DIR (test_dir.c_str())
#include "asb_observer.cpp"
#include <cassert>
#include <thread>
static int reply_server_socket() {
  int fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); assert(fd>=0);
  sockaddr_un addr{}; addr.sun_family=AF_UNIX;
  snprintf(addr.sun_path,sizeof(addr.sun_path),"%s",test_socket.c_str());
  unlink(addr.sun_path); assert(bind(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0);
  return fd;
}
static void reply_server(int fd,const char *reply) {
  timeval tv{1,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
  char buf[64]{}; sockaddr_un src{}; socklen_t len=sizeof(src);
  ssize_t n=recvfrom(fd,buf,sizeof(buf)-1,0,reinterpret_cast<sockaddr*>(&src),&len);
  assert(n==14 && std::strcmp(buf,"zygisk-refresh")==0); // no package/PID/cap payload
  assert(sendto(fd,reply,std::strlen(reply),0,reinterpret_cast<sockaddr*>(&src),len)==static_cast<ssize_t>(std::strlen(reply)));
  close(fd); unlink(test_socket.c_str());
}
int main(int argc,char **argv) {
  assert(argc==2); test_dir=argv[1]; test_socket=test_dir+"/missing.sock";
  assert(request_governor_refresh()==GovernorHintResult::unavailable);
  test_socket=test_dir+"/governor.sock";
  int ok_fd=reply_server_socket(); std::thread ok(reply_server,ok_fd,"ok");
  assert(request_governor_refresh()==GovernorHintResult::accepted); ok.join();
  int veto_fd=reply_server_socket(); std::thread veto(reply_server,veto_fd,"err:screen_off");
  assert(request_governor_refresh()==GovernorHintResult::vetoed); veto.join();
  std::string client=test_dir+"/zygisk_hint_"+std::to_string(getpid())+".sock";
  assert(access(client.c_str(),F_OK)!=0); // no persistent governor socket left behind
  return 0;
}
CPP
    g++ -std=c++17 -Wall -Wextra -Werror -Wno-unused-parameter -pthread -I"$T" -I"$ROOT/src/zygisk" \
      -DASB_ABI_TAG='"arm64-v8a"' "$T/ipc.cpp" -o "$T/ipc" || fail 'native IPC fixture build'
    "$T/ipc" "$T" || fail 'governor refresh ack/veto/timeout runtime'
  fi
  echo 'PASS observer native contract: fail-open, no hooks/cap writer, bounded refresh IPC, two ABIs and synchronized diagnostics'
)

t_zygisk_allowlist_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer allowlist: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/mod/config" "$T/state"
  printf 'zygisk_enabled=0\nzygisk_mode=observer\n' > "$T/mod/config/governor.conf"
  run() { ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/state" sh "$ROOT/runtime/asb_zygisk.sh" "$@"; }
  run list | grep -q . && fail 'default allowlist is not empty'
  run set-packages com.example.app org.example.game:remote >/dev/null 2>&1 && fail 'process suffix was accepted'
  run set-packages com.android.systemui >/dev/null 2>&1 && fail 'SystemUI was accepted'
  run set-packages com.topjohnwu.magisk >/dev/null 2>&1 && fail 'root manager was accepted'
  run set-packages "com.example.app;touch${IFS}/tmp/pwn" >/dev/null 2>&1 && fail 'shell metacharacters were accepted'
  run set-packages com.example.app com.example.app >/dev/null 2>&1 && fail 'duplicate was accepted'
  run set-packages com.example.app org.example.game || fail 'valid packages rejected'
  [ "$(run list | wc -l)" = 2 ] || fail 'valid allowlist was not saved'
  run enable || fail 'explicit enable failed'
  grep -qx 'zygisk_enabled=1' "$T/mod/config/governor.conf" || fail 'enable did not update config'
  run safe-mode on || fail 'safe mode on failed'
  [ -f "$T/state/disable" ] && grep -qx 'zygisk_enabled=0' "$T/mod/config/governor.conf" || fail 'safe mode did not disable new injection'
  run enable >/dev/null 2>&1 && fail 'safe mode was bypassed by enable'
  run safe-mode off || fail 'safe mode off failed'
  grep -qx 'zygisk_enabled=0' "$T/mod/config/governor.conf" || fail 'clearing safe mode silently enabled observer'
  run enable || fail 'explicit re-enable failed'
  args=''; i=0; while [ $i -lt 65 ]; do args="$args com.example.p$i"; i=$((i+1)); done
  # shellcheck disable=SC2086
  run set-packages $args >/dev/null 2>&1 && fail '65-package list exceeded the bound'
  [ "$(run list | wc -l)" = 2 ] || fail 'rejected list damaged the previous allowlist'
  echo 'PASS observer allowlist: empty default, native-equivalent validation, protected names, bounds and explicit safe mode'
)

t_pressure_score_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL pressure score: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/sys/devices/system/cpu" "$T/proc" "$T/bin"
  printf '0-7\n' > "$T/sys/devices/system/cpu/online"
  printf '1.25 1 1 1/1 1\n' > "$T/proc/loadavg"
  printf 'MemTotal: 16000000 kB\nMemAvailable: 9000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 7000000 kB\n' > "$T/proc/meminfo"
  printf 'cpu 100 0 100 800 0 0 0 0 0 0\n' > "$T/proc/stat"
  cat > "$T/run.sh" <<'SH'
#!/bin/sh
set -eu
ROOT="$1"; OUT="$2"
_read() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
_mem() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1; }
_emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }
. "$ROOT/runtime/asb_pressure.sh"
_asb_pressure_collect
SH
  chmod +x "$T/run.sh"
  : > "$T/out"; PROC="$T/proc" SYS="$T/sys" OUT="$T/out" ASB_PRESSURE_CPU_SAMPLE_S=0 "$T/run.sh" "$ROOT" "$T/out"
  grep -q $'^system_load\tcoverage_pct\t65$' "$T/out" || fail 'missing components were not excluded'
  grep -q $'^system_load\tscore\t8$' "$T/out" || fail 'load+memory weighted result'
  grep -q $'^system_load\tband\tlight$' "$T/out" || fail 'light band'
  grep -q $'^system_load\tswap_role\tsupporting signal only' "$T/out" || fail 'swap entered the score'
  : > "$T/out"; printf 'bad\n' > "$T/proc/loadavg"; : > "$T/proc/meminfo"
  PROC="$T/proc" SYS="$T/sys" OUT="$T/out" ASB_PRESSURE_CPU_SAMPLE_S=0 "$T/run.sh" "$ROOT" "$T/out"
  grep -q $'^system_load\tscore\tunknown$' "$T/out" && grep -q $'^system_load\tcoverage_pct\t0$' "$T/out" || fail 'malformed/missing data produced a score'
  # Full-component deterministic CPU delta and exposed GPU reading.
  printf '2.00 1 1 1/1 1\n' > "$T/proc/loadavg"; printf '0-1\n' > "$T/sys/devices/system/cpu/online"
  printf 'MemTotal: 1000 kB\nMemAvailable: 300 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$T/proc/meminfo"
  cat > "$T/bin/sleep" <<'SH'
#!/bin/sh
printf 'cpu 150 0 150 900 0 0 0 0 0 0\n' > "$PROC/stat"
SH
  chmod +x "$T/bin/sleep"; : > "$T/gpu"; printf '50 %%\n' > "$T/gpu"; : > "$T/out"
  PATH="$T/bin:$PATH" PROC="$T/proc" SYS="$T/sys" OUT="$T/out" ASB_PRESSURE_CPU_SAMPLE_S=0.20 ASB_PRESSURE_GPU_BUSY="$T/gpu" "$T/run.sh" "$ROOT" "$T/out"
  grep -q $'^system_load\tcoverage_pct\t100$' "$T/out" || fail 'full coverage'
  grep -q $'^system_load\tcpu_busy_pct\t50.0$' "$T/out" || fail 'CPU delta was not measured'
  grep -q $'^system_load\tgpu_busy_pct\t50.0$' "$T/out" || fail 'GPU busy was not measured'
  grep -q $'^system_load\tscore\t53$' "$T/out" && grep -q $'^system_load\tband\thigh$' "$T/out" || fail 'full formula result'
  # fix271: an idle Adreno reports "0 0" (no busy and no total time since the last read).
  # That is a measured 0 %, not a missing counter that would drop the GPU weight.
  printf '0 0\n' > "$T/gpu"; : > "$T/out"
  PATH="$T/bin:$PATH" PROC="$T/proc" SYS="$T/sys" OUT="$T/out" ASB_PRESSURE_CPU_SAMPLE_S=0.20 ASB_PRESSURE_GPU_BUSY="$T/gpu" "$T/run.sh" "$ROOT" "$T/out"
  grep -q $'^system_load\tgpu_busy_pct\t0.0$' "$T/out" || fail 'idle Adreno 0 0 was not read as 0 %'
  grep -q $'^system_load\tgpu_weight\t10$' "$T/out" || fail 'idle GPU dropped its weight'
  echo 'PASS pressure score: renormalized weights, insufficient/malformed coverage, CPU delta, GPU and unscored swap'
)

t_zygisk_info_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer diagnostics: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/mod/runtime" "$T/mod/config" "$T/data/asb/zygisk_observer" "$T/proc/4242"
  cp "$ROOT/runtime/asb_zygisk.sh" "$ROOT/runtime/asb_zygisk_info.sh" "$T/mod/runtime/"
  printf 'zygisk_enabled=1\nzygisk_mode=observer\nzygisk_hints=1\n' > "$T/mod/config/governor.conf"
  printf 'com.example.app\n' > "$T/data/asb/zygisk_observer/packages.list"
  python3 - "$T/proc/4242/stat" <<'PY'
import sys
fields=['S']+['0']*18+['777']
open(sys.argv[1],'w').write('4242 (fixture app) '+' '.join(fields)+'\n')
PY
  printf 'Name:\tfixture\nVmRSS:\t 2222 kB\n' > "$T/proc/4242/status"
  printf '1000.0 0.0\n' > "$T/proc/uptime"
  cat > "$T/data/asb/zygisk_observer/state.arm64-v8a.tsv" <<'EOF'
Z	schema	1
Z	updated_monotonic_ms	999000
Z	events_total	10
Z	events_dropped_total	2
Z	events_dropped_rate_limit	1
Z	events_dropped_duplicate	0
Z	events_dropped_invalid	1
Z	events_dropped_capacity	0
Z	ipc_cpu_ms	3
Z	ipc_wakeups	12
Z	policy_hints	7
Z	hints_accepted	4
Z	hints_vetoed	1
Z	hints_unavailable	1
Z	hints_throttled	3
P	4242	777	com.example.app	1234
P	4242	999	com.example.stale	9999
P	bad	777	com.example.bad	1
EOF
  : > "$T/out"
  _read() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
  _emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/out"; }
  MODDIR="$T/mod"; PROC="$T/proc"; DATA="$T/data"; ASB_ZYGISK_DIR="$T/data/asb/zygisk_observer"
  . "$ROOT/runtime/asb_zygisk_info.sh"; _asb_zygisk_info
  want() { grep -Fqx "zygisk_observer	$1	$2" "$T/out" || fail "missing $1=$2: $(cat "$T/out")"; }
  want enabled 1; want enabled_packages 1; want loaded_processes 1; want events_total 10
  want events_dropped_rate_limit 1; want ipc_cpu_ms 3; want ipc_wakeups 12; want memory_kb 2222
  want state_freshness current; want crash_count unknown; want anr_count unknown; want policy_hints 7
  want lifecycle_hints 1; want hints_accepted 4; want hints_vetoed 1; want hints_unavailable 1; want hints_throttled 3
  # A reused PID with different start ticks and malformed rows never contributes RSS/processes.
  ! grep -q '9999\|com.example.stale\|com.example.bad' "$T/out" || fail 'stale/malformed process leaked into diagnostics'
  : > "$T/out"; rm -rf "$T/proc/4242"; printf '999.0 0.0\n' > "$T/proc/uptime"; _asb_zygisk_info
  want loaded_processes 0; want state_freshness current
  printf '1000.0 0.0\n' > "$T/proc/uptime"; sed -i 's/999000/1/' "$T/data/asb/zygisk_observer/state.arm64-v8a.tsv"
  : > "$T/out"; _asb_zygisk_info; want state_freshness stale_over_5_minutes
  echo 'PASS observer diagnostics: live PID/start-ticks validation, current RSS, counters, stale TTL and honest unknowns'
)

t_zygisk_ui_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer UI: $*" >&2; exit 1; }
  command -v node >/dev/null 2>&1 || { echo 'SKIP observer UI: no node'; exit 0; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  {
    cat <<'JS'
const window=globalThis; const ASB_LANG='en'; const MD='/data/adb/modules/AutoSystemBoost';
function T(k,d){return d;} function deviceFill(k,d,v){let s=d;for(const x in v)s=s.replace('{'+x+'}',v[x]);return s;}
function deviceFallbackLabel(k){return String(k).replace(/_/g,' ');}
function deviceVal(d,s,k){return d.sections[s]&&d.sections[s][k]!=null?String(d.sections[s][k]):'—';}
function mk(tag){const e={tagName:tag,className:'',children:[],style:{},disabled:false,value:'',setAttribute(){},classList:{add(){}},appendChild(c){e.children.push(c);return c;}};Object.defineProperty(e,'textContent',{get(){return e._text||''},set(v){e._text=String(v);e.children=[];}});return e;}
const document={createElement:mk}; function logReportNote(t){const e=mk('div');e.textContent=t;return e;}
let commands=[],refreshes=0,toastText=''; async function run(c){commands.push(c);return {errno:0,stdout:''};} function runOk(r){return r.errno===0;} function runText(r){return r.stdout||'';} function toast(t){toastText=t;} function asbDeviceInfoLoad(){refreshes++;}
JS
    sed -n '/^function devicePressureScale(/,/^}/p; /^function deviceZygiskEditor(/,/^}/p' "$ROOT/webroot/index.html"
    cat <<'JS'
let bad=0;const chk=(c,m)=>{if(!c){console.log('FAIL '+m);bad++;}};
function find(n,c){if(n.className&&n.className.split(/\s+/).includes(c))return n;for(const x of n.children||[]){const r=find(x,c);if(r)return r;}return null;}
const d={sections:{system_load:{score:'53',band:'high',coverage_pct:'100'},zygisk_observer:{enabled_package_list:'com.example.app',safe_mode:'off'}}};
let scale=devicePressureScale(d),marker=find(scale,'dev-pressure-marker');chk(marker&&marker.style.left==='53%','valid pressure marker');chk(find(scale,'dev-pressure-score').textContent==='53/100','score text');
d.sections.system_load.score='unknown';scale=devicePressureScale(d);chk(!find(scale,'dev-pressure-marker'),'unknown gained a marker');chk(find(scale,'dev-pressure-score').textContent==='unknown','unknown not shown');
(async()=>{const ed=deviceZygiskEditor(d),input=find(ed,'dev-zygisk-input'),buttons=ed.children.flatMap(x=>x.children||[]).filter(x=>x.tagName==='button');
input.value='com.example.app;touch /tmp/pwn';await buttons[0].onclick();chk(commands.length===0,'malformed package reached shell');chk(refreshes===0,'malformed package refreshed collector');
input.value='com.example.app, org.example.game';await buttons[0].onclick();chk(commands.length===1&&commands[0].includes("set-packages 'com.example.app' 'org.example.game'"),'valid allowlist command');chk(refreshes===1,'valid save did not refresh');
await buttons[1].onclick();chk(commands[1].endsWith('safe-mode on'),'safe mode command');chk(refreshes===2,'safe mode did not refresh');
if(bad)process.exit(1);console.log('ok');})().catch(e=>{console.error(e);process.exit(1)});
JS
  } > "$T/test.js"
  out="$(node "$T/test.js" 2>&1)" || fail "$out"
  [ "$out" = ok ] || fail "$out"
  echo 'PASS observer UI: clamped/unknown scale, safe allowlist validation and explicit safe-mode action'
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
