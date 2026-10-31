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
  // fix272: one-shot spawn frames, the cold-start budget, the ledger and the policy file.
  auto sp=frame(20,"",5000); sp.kind=ASB_OBSERVER_EVENT_SPAWN; sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH;
  assert(asb_observer_frame_valid(sp));
  sp.flags=ASB_OBSERVER_FLAG_LAUNCH; assert(!asb_observer_frame_valid(sp)); // launch needs top-app
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP; assert(!asb_observer_frame_valid(sp)); // nothing requested
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|8u; assert(!asb_observer_frame_valid(sp)); // unknown bit
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH; snprintf(sp.package,sizeof(sp.package),"com.example.app");
  assert(!asb_observer_frame_valid(sp)); // a launch-only record names no package
  sp.flags=ASB_OBSERVER_FLAG_LEDGER; assert(asb_observer_frame_valid(sp));
  snprintf(sp.package,sizeof(sp.package),"com.android.systemui"); assert(!asb_observer_frame_valid(sp));
  sp.version=1; snprintf(sp.package,sizeof(sp.package),"com.example.app"); assert(!asb_observer_frame_valid(sp));
  auto spawn_as_start=frame(21,"com.example.app",6000); spawn_as_start.kind=ASB_OBSERVER_EVENT_SPAWN; spawn_as_start.flags=ASB_OBSERVER_FLAG_LEDGER;
  AsbObserverCore s2; assert(s2.start(spawn_as_start,6000)==AsbObserverResult::invalid && s2.loaded()==0);
  AsbObserverCore lc;
  assert(!lc.launch_permit(0) && lc.launch_permit(1000) && !lc.launch_permit(1999) && lc.launch_permit(2000));
  int granted=2; for (int64_t t=3000;t<60000;t+=1000) if (lc.launch_permit(t)) ++granted;
  assert(granted==20); // 20 cold starts a minute, then local veto until the window moves
  assert(lc.launch_permit(62000));
  AsbObserverCore lg;
  lg.ledger_record("com.example.sync",0,false,1); lg.ledger_record("com.example.sync",0,false,2);
  lg.ledger_record("com.example.sync",1,true,3); lg.ledger_record("com.example.sync",-1,false,4);
  assert(lg.ledger().at("com.example.sync").screen_off==2 && lg.ledger().at("com.example.sync").screen_on==2);
  assert(lg.ledger().at("com.example.sync").top_app==1 && lg.ledger_events()==4);
  for (int i=0;i<200;i++) lg.ledger_record("com.example.p"+std::to_string(i),1,false,100+i);
  assert(lg.ledger().size()==ASB_OBSERVER_LEDGER_MAX && lg.ledger_evicted()>0);
  assert(lg.ledger().count("com.example.sync")==1); // the busy entry survives one-off churn
  // fix277: the screen-off burst is a 5-minute window over a fixed ring, never a lifetime total.
  assert(lg.ledger().at("com.example.sync").burst_off==2);
  AsbObserverCore bl;
  for (int i=0;i<8;i++) bl.ledger_record("com.example.loop",0,false,1000+i*10000);
  assert(bl.ledger().at("com.example.loop").burst_off==8);
  for (int i=0;i<8;i++) bl.ledger_record("com.example.slow",0,false,1000+int64_t(i)*ASB_OBSERVER_BURST_WINDOW_MS);
  assert(bl.ledger().at("com.example.slow").burst_off==1 && bl.ledger().at("com.example.slow").screen_off==8);
  for (int i=0;i<100;i++) bl.ledger_record("com.example.storm",0,false,1000+i);
  assert(bl.ledger().at("com.example.storm").burst_off==ASB_OBSERVER_BURST_KEEP);
  bl.ledger_record("com.example.loop",1,true,500000); assert(bl.ledger().at("com.example.loop").burst_off==8);
  assert(asb_observer_regular_app_uid(10123) && asb_observer_regular_app_uid(1010123));
  assert(!asb_observer_regular_app_uid(1000) && !asb_observer_regular_app_uid(99123) && !asb_observer_regular_app_uid(90001));
  assert(!asb_observer_regular_app_uid(20123) && !asb_observer_regular_app_uid(-1));
  AsbObserverPolicy pol; const char ok[]="v=2\ngen=1730000000\nobserver=1\nhints=0\nlaunch=1\nledger=0\npkg=com.example.app\npkg=org.example.game\n";
  assert(asb_observer_policy_parse(ok,sizeof(ok)-1,pol) && pol.active() && pol.launch && !pol.ledger && pol.packages==2);
  assert(pol.generation==1730000000UL && pol.selected("org.example.game") && !pol.selected("com.example"));
  const char nover[]="observer=1\npkg=com.example.app\n"; assert(!asb_observer_policy_parse(nover,sizeof(nover)-1,pol) && !pol.active());
  const char badpkg[]="v=2\nobserver=1\npkg=com.android.systemui\n"; assert(!asb_observer_policy_parse(badpkg,sizeof(badpkg)-1,pol));
  const char unknown[]="v=2\nlaunch=1\ncap=3000000\n"; assert(!asb_observer_policy_parse(unknown,sizeof(unknown)-1,pol));
  const char flag2[]="v=2\nlaunch=2\n"; assert(!asb_observer_policy_parse(flag2,sizeof(flag2)-1,pol));
  const char idle[]="v=2\nobserver=0\nhints=1\nlaunch=0\nledger=0\n"; assert(asb_observer_policy_parse(idle,sizeof(idle)-1,pol) && !pol.active());
  std::string many="v=2\nobserver=1\n"; for (int i=0;i<65;i++) many+="pkg=com.example.p"+std::to_string(i)+"\n";
  assert(!asb_observer_policy_parse(many.data(),many.size(),pol));
  std::cout << "observer core ok\n";
}
CPP
  g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/core.cpp" -o "$T/core" || fail 'C++ build'
  "$T/core" | grep -qx 'observer core ok' || fail 'core assertions'
  echo 'PASS observer native core: validation, exclusions, lifecycle/hint/cold-start bounds, ledger, policy parser, exit and TTL'
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
  grep -q 'ASB_ZYGISK_POLICY_ABS' "$S" && grep -q 'ASB_ZYGISK_POLICY_REL' "$S" || fail 'generated policy is not the hot-path input'
  ! grep -q 'ASB_ZYGISK_CONFIG\|ASB_ZYGISK_DIR\|std::ifstream\|packages.list' "$S" \
    || fail 'app processes still parse governor.conf, the allowlist file or /data/adb/asb'
  grep -q 'asb_observer_regular_app_uid(args->uid)' "$S" && grep -q 'is_child_zygote' "$S" \
    || fail 'isolated/system/app-zygote processes are not filtered before any syscall'
  grep -q 'api_->exemptFd(sock)' "$S" || fail 'process-lifetime socket is not retained'
  grep -q 'rm -f "$POLICY"' "$ROOT/runtime/asb_zygisk.sh" || fail 'safe mode/disable does not withdraw the policy'
  ! grep -q 'api_->hookJniNativeMethods\|api_->pltHook\|scaling_\|APP_FOREGROUND\|APP_CAMERA' "$S" \
    || fail 'observer gained hooks, hardware writes or unimplemented events'
  grep -q 'ASB_GOVERNOR_SOCKET "/dev/.asb/ctl.sock"' "$S" || fail 'bounded governor refresh channel missing'
  grep -q 'static const char command\[\] = "zygisk-refresh"' "$S" || fail 'refresh carries more than its fixed opcode'
  grep -q 'static const char command\[\] = "zygisk-launch"' "$S" || fail 'cold start carries more than its fixed opcode'
  ! grep -q 'fsync' "$S" || fail 'companion state is fsynced to flash on every event'
  grep -q 'ASB_GOVERNOR_HINT_TIMEOUT_US 100000' "$S" || fail 'governor round trip is not bounded to 100 ms'
  ! grep -q 'profile:\|start-session:\|zygisk-refresh:' "$S" || fail 'observer gained a profile/policy command'
  [ "$(grep -c 'write_all(socket_' "$S")" = 1 ] || fail 'more than the single process-start send exists'
  [ "$(grep -c 'write_all(sock,' "$S")" = 1 ] || fail 'more than the single one-shot spawn send exists'
  grep -q 'std::lock_guard<std::mutex>' "$S" || fail 'parallel companion handlers are not serialized'
  grep -q 'SO_PEERCRED' "$S" && grep -q 'process_start_ticks(frame.pid)' "$S" || fail 'peer/PID reuse validation missing'
  G="$ROOT/src/asb_governor.c"
  sed -n '/else if (strcmp(cmd, "zygisk-refresh") == 0)/,/else if (strcmp(cmd, "status")/p' "$G" > "$T.hint"
  grep -q 'g_asb_cfg.zygisk_enabled' "$T.hint" && grep -q 'g_asb_cfg.zygisk_hints' "$T.hint" || fail 'governor hint opt-in gates missing'
  grep -q 'zygisk_observer/disable' "$T.hint" && grep -q 'err:screen_off' "$T.hint" || fail 'safe-mode/screen-off veto missing'
  grep -q 'need_metrics = 1' "$T.hint" && grep -q 'asb_smart_pkg_cache_invalidate' "$T.hint" || fail 'hint does not request fresh evidence'
  ! grep -q 'force_write = 1\|g_last_reassert = 0\|profile_idx =\|CPU_MAX\|scaling_' "$T.hint" || fail 'hint bypassed normal governor policy'
  rm -f "$T.hint"
  sed -n '/else if (strcmp(cmd, "zygisk-launch") == 0)/,/else if (strcmp(cmd, "status")/p' "$G" > "$T.launch"
  grep -q 'g_asb_cfg.zygisk_enabled' "$T.launch" && grep -q 'g_asb_cfg.zygisk_launch' "$T.launch" || fail 'cold-start opt-in gates missing'
  grep -q 'zygisk_observer/disable' "$T.launch" && grep -q 'err:screen_off' "$T.launch" || fail 'cold-start safe-mode/screen-off veto missing'
  grep -q 'g_unlock_cold_kick = 1' "$T.launch" && grep -q 'need_metrics = 1' "$T.launch" || fail 'cold start does not feed the existing lift'
  ! grep -q 'force_write = 1\|g_last_reassert = 0\|profile_idx =\|CPU_MAX\|scaling_\|g_unlock_until_ms' "$T.launch" \
    || fail 'cold start bypassed the lift gates or wrote a cap'
  rm -f "$T.launch"
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

t_zygisk_hot_path_runtime() (
  # fix272: the REAL module and companion, driven through the Zygisk ABI on the host with a
  # fake loader table. Dormant = one failed open and DLCLOSE, no companion; isolated/system
  # uids and app-zygote children never reach the policy; a top-app cold start sends one
  # package-free frame; the ledger names the package; an allowlisted process keeps its fd.
  # The companion turns those into a governor "zygisk-launch", a tmpfs ledger and counters.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer hot path: $*" >&2; exit 1; }
  command -v g++ >/dev/null 2>&1 || { echo 'SKIP observer hot path: no g++'; exit 0; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/inc" "$T/run" "$T/gov"
  cat > "$T/inc/jni.h" <<'JNI'
#pragma once
#include <cstdint>
#include <string>
typedef int32_t jint; typedef int64_t jlong; typedef uint8_t jboolean; typedef void* jobject; typedef jobject jstring; typedef jobject jintArray; typedef jobject jobjectArray;
struct JNINativeMethod { const char* name; const char* signature; void* fnPtr; };
extern std::string g_nice;
struct JNIEnv { const char* GetStringUTFChars(jstring, void*){return g_nice.c_str();} void ReleaseStringUTFChars(jstring,const char*){} };
JNI
  cat > "$T/hot.cpp" <<'CPP'
#include <string>
std::string g_nice;
#include "asb_observer.cpp"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>
using namespace zygisk::internal;
static module_abi *g_abi; static int g_connects=0, g_dlclose=0, g_exempt=0, g_peer=-1;
static bool reg(api_table*, module_abi *abi){ g_abi=abi; return true; }
static bool exempt(int){ ++g_exempt; return true; }
static int connect_c(void*){ ++g_connects; int sv[2]; if (socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sv)) return -1; g_peer=sv[1]; return sv[0]; }
static void setopt(void*, zygisk::Option o){ if (o==zygisk::DLCLOSE_MODULE_LIBRARY) ++g_dlclose; }
static int moddir(void*){ return -1; }
static uint32_t flags_fn(void*){ return 0; }
static void put_policy(const char *text){ std::ofstream f(ASB_ZYGISK_POLICY_ABS); f<<text; }
static jint uid=10123, gid=10123, rf=0, me=0; static jintArray gids=nullptr; static jobjectArray rl=nullptr;
static jstring se=nullptr, nn=reinterpret_cast<jstring>(1), isa=nullptr, add=nullptr; static jboolean child=0, top=0;
static zygisk::AppSpecializeArgs args{uid,gid,gids,rf,rl,me,se,nn,isa,add,nullptr,&child,&top,nullptr,nullptr,nullptr,nullptr,nullptr};
static void pre(){ g_abi->preAppSpecialize(g_abi->impl,&args); }
static AsbObserverFrame take(){ AsbObserverFrame f{}; assert(g_peer>=0); assert(read_frame(g_peer,f)==1); return f; }
static std::vector<std::string> gov_cmds;
static void governor(int fd,int n){ for(int i=0;i<n;i++){ char b[64]{}; sockaddr_un src{}; socklen_t l=sizeof(src);
  timeval tv{2,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
  ssize_t r=recvfrom(fd,b,sizeof(b)-1,0,reinterpret_cast<sockaddr*>(&src),&l); if(r<=0) return; gov_cmds.push_back(b);
  sendto(fd,"ok",2,0,reinterpret_cast<sockaddr*>(&src),l);} }
static std::string state(){ std::ifstream f(std::string(ASB_ZYGISK_RUN_DIR)+"/state.arm64-v8a.tsv"); return std::string((std::istreambuf_iterator<char>(f)),{}); }
static void companion_send(const AsbObserverFrame &f){ int sv[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sv));
  std::thread t(zygisk_companion_entry,sv[1]); assert(write_all(sv[0],&f,sizeof(f))); close(sv[0]); t.join(); }
int main(){
  api_table table{}; table.registerModule=reg; table.exemptFd=exempt; table.connectCompanion=connect_c;
  table.setOption=setopt; table.getModuleDir=moddir; table.getFlags=flags_fn;
  JNIEnv env; zygisk_module_entry(&table,&env); assert(g_abi);
  // Dormant: no policy file, so DLCLOSE and no companion.
  g_nice="com.example.app"; top=1; pre(); assert(g_dlclose==1 && g_connects==0);
  auto t0=std::chrono::steady_clock::now(); for(int i=0;i<20000;i++) pre();
  double ns=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-t0).count()/20000;
  std::cout<<"dormant_ns="<<static_cast<long>(ns)<<"\n";
  assert(g_connects==0);
  // Cold-start lift only: a top-app regular app sends one package-free frame and unloads.
  put_policy("v=2\ngen=7\nobserver=0\nhints=0\nlaunch=1\nledger=0\n");
  int dl=g_dlclose; pre(); assert(g_connects==1 && g_dlclose==dl+1 && g_exempt==0);
  AsbObserverFrame f=take(); assert(f.kind==ASB_OBSERVER_EVENT_SPAWN && f.package[0]==0);
  assert(f.flags==(ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH) && asb_observer_frame_valid(f));
  char extra; assert(recv(g_peer,&extra,1,0)==0); close(g_peer); g_peer=-1; // closed in pre-specialize
  top=0; pre(); assert(g_connects==1); // background start: nothing to say
  // Isolated services, system uids and app-zygote children are filtered before the policy.
  top=1; uid=99001; pre(); uid=1000; pre(); uid=10123; child=1; pre(); child=0; assert(g_connects==1);
  // Ledger: every regular app start, package named, screen state taken from the governor.
  put_policy("v=2\ngen=8\nobserver=0\nhints=0\nlaunch=0\nledger=1\n");
  top=0; g_nice="com.example.sync:worker"; pre(); f=take();
  assert(f.flags==ASB_OBSERVER_FLAG_LEDGER && std::string(f.package)=="com.example.sync"); close(g_peer); g_peer=-1;
  g_nice="com.android.settings"; uid=10200; pre(); assert(g_connects==2); uid=10123; // protected name: nothing sent
  // Allowlisted process: fd exempted, a START frame after specialize, library kept.
  put_policy("v=2\ngen=9\nobserver=1\nhints=0\nlaunch=1\nledger=0\npkg=com.example.app\n");
  g_nice="com.example.app"; top=1; dl=g_dlclose; pre(); assert(g_exempt==1 && g_dlclose==dl);
  f=take(); assert(f.kind==ASB_OBSERVER_EVENT_SPAWN && (f.flags&ASB_OBSERVER_FLAG_LAUNCH));
  g_abi->postAppSpecialize(g_abi->impl,&args); f=take(); assert(f.kind==ASB_OBSERVER_EVENT_PROCESS_START && std::string(f.package)=="com.example.app");
  close(g_peer); g_peer=-1;
  // A malformed policy observes nothing.
  put_policy("v=2\nlaunch=1\ncap=1\n"); int c0=g_connects; pre(); assert(g_connects==c0);
  // Companion: cold start -> one "zygisk-launch", throttled inside a second; ledger split by screen.
  put_policy("v=2\ngen=11\nobserver=0\nhints=0\nlaunch=1\nledger=1\n");
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=IDLE\nprofile=battery\nscreen=0\n"; }
  int gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); sockaddr_un ga{}; ga.sun_family=AF_UNIX;
  snprintf(ga.sun_path,sizeof(ga.sun_path),"%s",ASB_GOVERNOR_SOCKET); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  std::thread gt(governor,gfd,1);
  AsbObserverFrame l=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_LEDGER,"com.example.sync");
  companion_send(l); gt.join();
  assert(gov_cmds.size()==1 && gov_cmds[0]=="zygisk-launch");
  l=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_LEDGER,"com.example.sync");
  companion_send(l); // inside one second: throttled locally, no governor round trip
  AsbObserverFrame spoof=l; spoof.pid=1234567; companion_send(spoof); // peer/PID mismatch
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=ACTIVE\nprofile=battery\nscreen=1\n"; }
  AsbObserverFrame g=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_LEDGER,"com.example.sync"); companion_send(g);
  std::string s=state();
  assert(s.find("Z\tlaunch_accepted\t1\n")!=std::string::npos);
  assert(s.find("Z\tlaunch_throttled\t1\n")!=std::string::npos);
  assert(s.find("L\tcom.example.sync\t2\t1\t2\t2\n")!=std::string::npos);
  assert(s.find("Z\tevents_dropped_invalid\t1\n")!=std::string::npos);
  assert(s.find("Z\tpolicy_generation_seen\t11\n")!=std::string::npos);
  close(gfd);
  // fix277: an observed process's RSS is read once per TTL, not on every state rewrite.
  put_policy("v=2\ngen=12\nobserver=1\nhints=0\nlaunch=0\nledger=1\npkg=com.example.app\n");
  { int sv[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sv)); std::thread t(zygisk_companion_entry,sv[1]);
    AsbObserverFrame st=make_frame(ASB_OBSERVER_EVENT_PROCESS_START,0,"com.example.app"); assert(write_all(sv[0],&st,sizeof(st)));
    for(int i=0;i<5;i++){ AsbObserverFrame lf=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_LEDGER,"com.example.mail"); assert(write_all(sv[0],&lf,sizeof(lf))); }
    for(int i=0;i<200 && state().find("L\tcom.example.mail\t0\t5\t")==std::string::npos;i++) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    s=state(); assert(s.find("\nP\t")!=std::string::npos); assert(s.find("Z\trss_reads\t1\n")!=std::string::npos);
    close(sv[0]); t.join(); }
  // No policy: the companion ignores late one-shot frames instead of acting on stale state.
  unlink(ASB_ZYGISK_POLICY_ABS); companion_send(g); s=state();
  assert(s.find("Z\tevents_policy_absent\t1\n")!=std::string::npos);
  std::cout<<"hot path ok\n";
  return 0;
}
CPP
  g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-missing-field-initializers -pthread \
    -I"$T/inc" -I"$ROOT/src/zygisk" -DASB_ABI_TAG='"arm64-v8a"' \
    -DASB_ZYGISK_POLICY_ABS="\"$T/policy\"" -DASB_ZYGISK_RUN_DIR="\"$T/run\"" \
    -DASB_GOVERNOR_STATE="\"$T/gov/state\"" -DASB_GOVERNOR_SOCKET="\"$T/gov/ctl.sock\"" \
    -DASB_GOVERNOR_CLIENT_DIR="\"$T/gov\"" "$T/hot.cpp" -o "$T/hot" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail 'host harness build'; }
  out="$("$T/hot")" || fail "runtime: $out"
  printf '%s\n' "$out" | grep -qx 'hot path ok' || fail "$out"
  ns="$(printf '%s\n' "$out" | sed -n 's/^dormant_ns=//p')"
  echo "PASS observer hot path: dormant ${ns} ns/fork on this host, uid/child prefilter, package-free cold start, ledger, allowlist fd, companion launch/throttle/spoof/ledger/no-policy"
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

t_zygisk_policy_sync_runtime() (
  # fix272: runtime/asb_zygisk.sh is the only writer of the zygote-side policy. Every switch
  # change rewrites it atomically; disable, safe mode or nothing selected removes it (absent =
  # dormant module); and what the shell writes is exactly what the native parser accepts.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer policy sync: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/mod/config" "$T/mod/zygisk" "$T/state"
  printf 'zygisk_enabled=0\nzygisk_mode=observer\nzygisk_hints=0\nzygisk_launch=0\nzygisk_ledger=0\n' > "$T/mod/config/governor.conf"
  run() { ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/state" sh "$ROOT/runtime/asb_zygisk.sh" "$@"; }
  P="$T/mod/zygisk/policy"
  run sync | grep -qx 'policy=absent' || fail 'disabled master wrote a policy'
  [ ! -e "$P" ] || fail 'policy exists while disabled'
  run enable
  [ ! -e "$P" ] || fail 'enabled with nothing selected still wrote a policy'
  sed -i 's/^zygisk_launch=0/zygisk_launch=1/' "$T/mod/config/governor.conf"
  run sync | grep -q '^policy=written .*launch=1 ledger=0' || fail 'cold-start policy not written'
  grep -qx 'v=2' "$P" && grep -qx 'launch=1' "$P" && grep -qx 'observer=0' "$P" || fail "policy content: $(cat "$P")"
  ! grep -q '^pkg=' "$P" || fail 'launch-only policy names packages'
  run set-packages com.example.app org.example.game
  grep -qx 'pkg=com.example.app' "$P" && grep -qx 'pkg=org.example.game' "$P" && grep -qx 'observer=1' "$P" \
    || fail 'allowlist change did not reach the policy'
  sed -i 's/^zygisk_ledger=0/zygisk_ledger=1/' "$T/mod/config/governor.conf"; run sync >/dev/null
  grep -qx 'ledger=1' "$P" || fail 'ledger switch did not reach the policy'
  run set-packages com.android.shellx >/dev/null 2>&1 && fail 'a name the native module denies was accepted'
  if command -v g++ >/dev/null 2>&1; then
    cat > "$T/parse.cpp" <<'CPP'
#include "asb_observer_protocol.h"
#include <fstream>
#include <iostream>
int main(int, char **argv) {
  std::ifstream f(argv[1]); std::string s((std::istreambuf_iterator<char>(f)), {});
  AsbObserverPolicy p; if (!asb_observer_policy_parse(s.data(), s.size(), p) || !p.active()) return 1;
  std::cout << p.observer << p.launch << p.ledger << ' ' << p.packages << "\n"; return 0;
}
CPP
    g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/parse.cpp" -o "$T/parse" || fail 'parser build'
    [ "$("$T/parse" "$P")" = '111 2' ] || fail "native parser rejected the shell policy: $(cat "$P")"
  fi
  run safe-mode on
  [ ! -e "$P" ] || fail 'safe mode left the policy for new processes'
  run safe-mode off
  [ ! -e "$P" ] || fail 'clearing safe mode silently re-enabled injection'
  run enable; [ -s "$P" ] || fail 're-enable did not restore the policy'
  run disable; [ ! -e "$P" ] || fail 'disable left the policy'
  run status | grep -qx 'policy=absent' || fail 'status does not report the policy'
  grep -q 'asb_zygisk.sh" sync' "$ROOT/post-fs-data.sh" || fail 'boot does not regenerate the policy before zygote'
  grep -q "asb_zygisk.sh') + ' sync" "$ROOT/webroot/index.html" || fail 'WebUI switches do not regenerate the policy'
  echo 'PASS observer policy sync: atomic generation, absent when off/safe/empty, native parser agrees, boot and WebUI regenerate'
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
  mkdir -p "$T/mod/runtime" "$T/mod/config" "$T/mod/zygisk" "$T/data/asb/zygisk_observer" "$T/run" "$T/proc/4242"
  cp "$ROOT/runtime/asb_zygisk.sh" "$ROOT/runtime/asb_zygisk_info.sh" "$T/mod/runtime/"
  printf 'zygisk_enabled=1\nzygisk_mode=observer\nzygisk_hints=1\nzygisk_launch=1\nzygisk_ledger=1\n' > "$T/mod/config/governor.conf"
  printf 'com.example.app\n' > "$T/data/asb/zygisk_observer/packages.list"
  printf 'v=2\ngen=42\nobserver=1\nhints=1\nlaunch=1\nledger=1\npkg=com.example.app\n' > "$T/mod/zygisk/policy"
  python3 - "$T/proc/4242/stat" <<'PY'
import sys
fields=['S']+['0']*18+['777']
open(sys.argv[1],'w').write('4242 (fixture app) '+' '.join(fields)+'\n')
PY
  printf 'Name:\tfixture\nVmRSS:\t 2222 kB\n' > "$T/proc/4242/status"
  printf '1000.0 0.0\n' > "$T/proc/uptime"
  cat > "$T/run/state.arm64-v8a.tsv" <<'EOF'
Z	schema	2
Z	policy_generation_seen	42
Z	spawn_events	30
Z	launch_events	9
Z	launch_accepted	6
Z	launch_vetoed	2
Z	launch_unavailable	0
Z	launch_throttled	1
Z	ledger_events	21
L	com.example.sync	12	3	1	7
L	com.example.mail	2	5	0	x9
L	com.example.idle	0	4	0
L	bad;pkg	9	9	9	99
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
  MODDIR="$T/mod"; PROC="$T/proc"; DATA="$T/data"; ASB_ZYGISK_DIR="$T/data/asb/zygisk_observer"; ASB_ZYGISK_RUN_DIR="$T/run"
  printf 'L\tcom.example.sync\t5\t0\t0\t9\nZ\tlaunch_accepted\t1\n' > "$T/run/state.armeabi-v7a.tsv"
  . "$ROOT/runtime/asb_zygisk_info.sh"; _asb_zygisk_info
  want() { grep -Fqx "zygisk_observer	$1	$2" "$T/out" || fail "missing $1=$2: $(cat "$T/out")"; }
  want enabled 1; want enabled_packages 1; want loaded_processes 1; want events_total 10; want link_state connected
  want events_dropped_rate_limit 1; want ipc_cpu_ms 3; want ipc_wakeups 12; want memory_kb 2222
  want state_freshness current; want crash_count unknown; want anr_count unknown; want policy_hints 7
  want lifecycle_hints 1; want hints_accepted 4; want hints_vetoed 1; want hints_unavailable 1; want hints_throttled 3
  want launch_hints 1; want spawn_ledger 1; want policy_generation 42; want policy_seen_generation 42
  want spawn_events 30; want launch_events 9; want launch_accepted 7; want launch_vetoed 2; want launch_throttled 1
  want ledger_events 21; want ledger_top_screen_off 'com.example.sync 17/3, com.example.mail 2/5'
  want ledger_restart_loops 'com.example.sync 9/5min'
  ! grep -q 'bad;pkg\|com.example.idle 0' "$T/out" || fail 'malformed or screen-on-only ledger rows leaked into the top list'
  # A reused PID with different start ticks and malformed rows never contributes RSS/processes.
  ! grep -q '9999\|com.example.stale\|com.example.bad' "$T/out" || fail 'stale/malformed process leaked into diagnostics'
  before="$(sha256sum "$T/mod/config/governor.conf" "$T/mod/zygisk/policy" "$T/run/state.arm64-v8a.tsv")"
  ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/data/asb/zygisk_observer" \
    ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/data" \
    sh "$ROOT/runtime/asb_zygisk.sh" link-status > "$T/link.out"
  after="$(sha256sum "$T/mod/config/governor.conf" "$T/mod/zygisk/policy" "$T/run/state.arm64-v8a.tsv")"
  [ "$before" = "$after" ] || fail 'link-status mutated configuration, policy or event state'
  grep -Fqx "$(printf 'D\tzygisk_observer\tloaded_processes\t1')" "$T/link.out" || fail 'link-status omitted validated live process evidence'
  grep -Fqx "$(printf 'D\tzygisk_observer\tstate_freshness\tcurrent')" "$T/link.out" || fail 'link-status omitted freshness evidence'
  grep -Fqx "$(printf 'D\tzygisk_observer\tpolicy_seen_generation\t42')" "$T/link.out" || fail 'link-status omitted companion acknowledgement'

  grep -Fqx "$(printf 'D\tzygisk_observer\tlink_state\tconnected')" "$T/link.out" || fail 'shared machine verdict missing'
  {
    sed -n '/^T_ZY_HEAD=/,/^T_ZY_UNKNOWN=/p' "$ROOT/action.sh"
    printf '_f() { _sfmt="$1"; shift; printf "$_sfmt\\n" "$@"; }\n'
    sed -n '/# Compact, current Zygisk evidence/,/^_bias=/p' "$ROOT/action.sh" | sed '$d'
  } > "$T/action.zy.sh"
  MODDIR="$T/mod" ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/data/asb/zygisk_observer" \
    ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/data" \
    sh "$T/action.zy.sh" > "$T/action.out" || fail 'Actions Zygisk block failed'
  grep -q 'Zygisk · ASB link: Connected' "$T/action.out" || fail "Actions verdict absent: $(cat "$T/action.out")"
  grep -q 'live processes 1 · events 10 · spawn 30' "$T/action.out" || fail 'Actions evidence counters absent'
  grep -q 'generation 42 / acknowledged 42' "$T/action.out" || fail 'Actions policy acknowledgement absent'
  grep -q 'not pure ASB cost' "$T/action.out" || fail 'Actions RSS basis is not honest'
  {
    printf 'P() { printf "%%s\\n" "$*"; }\nNOTE() { printf "%%s\\n" "$*"; }\n'
    printf '_asb_observer_diag="$(cat "$T/diag.rows")"\n'
    sed -n '/^    _asb_zdiag_field() {/,/^    P "  RAW PRESSURE/p' "$ROOT/tools/asb_diag.sh" | sed '$d'
  } > "$T/asbdiag.zy.sh"
  awk -F '\t' '$1 == "D" && $2 == "zygisk_observer" { print $2 "\t" $3 "\t" $4 }' "$T/link.out" > "$T/diag.rows"
  T="$T" sh "$T/asbdiag.zy.sh" > "$T/asbdiag.out" || fail 'asbdiag summary failed'
  grep -q 'CONNECTED - validated live observed process(es)' "$T/asbdiag.out" || fail 'asbdiag connected verdict absent'
  grep -q 'written_gen=42 acknowledged_gen=42' "$T/asbdiag.out" || fail 'asbdiag policy evidence absent'
  grep -q 'ASB <-> ZYGISK / INJECTION VERDICT' "$ROOT/tools/asb_diag.sh" || fail 'asbdiag verdict missing'
  cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail 'asbdiag entry points differ'

  : > "$T/out"; rm -rf "$T/proc/4242"; printf '999.0 0.0\n' > "$T/proc/uptime"; _asb_zygisk_info
  want loaded_processes 0; want state_freshness current; want link_state confirmed
  printf '1000.0 0.0\n' > "$T/proc/uptime"; sed -i 's/999000/1/' "$T/run/state.arm64-v8a.tsv"
  : > "$T/out"; _asb_zygisk_info; want state_freshness stale_over_5_minutes; want link_state stale
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
function deviceVal(d,s,k){return d&&d.sections&&d.sections[s]&&d.sections[s][k]!=null?String(d.sections[s][k]):'—';}
function mk(tag){const e={tagName:tag,className:'',children:[],style:{},disabled:false,value:'',attrs:{},setAttribute(k,v){e.attrs[k]=String(v);},classList:{add(){}},appendChild(c){e.children.push(c);c.parentNode=e;return c;},querySelector(sel){const c=sel.slice(1);return find(e,c);},replaceChild(n,o){const i=e.children.indexOf(o);if(i>=0){e.children[i]=n;n.parentNode=e;}return o;}};Object.defineProperty(e,'textContent',{get(){return e._text||''},set(v){e._text=String(v);e.children=[];}});return e;}
const hosts=Array.from({length:5},()=>mk('div'));
const document={createElement:mk,querySelectorAll(sel){if(sel==='.hdr-info')return hosts;if(sel==='.zygisk-header-link')return hosts.map(h=>find(h,'zygisk-header-link')).filter(Boolean);return [];}};
function _el(){return null;} function openZygiskPage(){} function shQuote(s){return "'"+s+"'";}
function logReportSec(t){const e=mk('div');e.className='lgr-sec';const h=mk('div');h.textContent=t;e.appendChild(h);return e;}
function uiSound(){} function haptic(){} let pageRenders=0; function zygiskPageRender(){pageRenders++;} let _zygiskOpen=true; let _cfgVals={}; let _cfgLoadSig='x';
function cfgRenderRow(list,it){const row=mk('div');row.className='cfg-row';row.setAttribute('data-key',it.key);const sw=mk('div');sw.className='cfg-switch';sw.setAttribute('role','switch');row.appendChild(sw);list.appendChild(row);}
 function logReportNote(t){const e=mk('div');e.textContent=t;return e;}
let commands=[],refreshes=0,toastText=''; async function run(c){commands.push(c);return {errno:0,stdout:''};} function runOk(r){return r.errno===0;} function runText(r){return r.stdout||'';} function toast(t){toastText=t;} function asbDeviceInfoLoad(){refreshes++;}
JS
    sed -n '/^function parseDeviceInfo(/,/^}/p; /^function devicePressureScale(/,/^}/p; /^function deviceZygiskLinkState(/,/^}/p; /^function deviceZygiskLinkVerdict(/,/^}/p; /^function deviceZygiskLink(/,/^}/p; /^let _zygiskHeaderSeq/p; /^let _zygiskHeaderAt/p; /^const ZYGISK_HEADER_TTL_MS/p; /^const _ASB_PART/p; /^function runBatchCmd(/,/^}/p; /^function runBatchSplit(/,/^}/p; /^async function runBatch(/,/^}/p; /^let _zygiskLoadSeq/p; /^const ZYGISK_MODES = \[/,/^\];/p; /^function zygiskModeOf(/,/^}/p; /^function zygiskModeCard(/,/^}/p; /^async function zygiskModeSet(/,/^}/p; /^function zygiskHeaderPaint(/,/^}/p; /^function zygiskHeaderInit(/,/^}/p; /^function zygiskHeaderPublish(/,/^}/p; /^async function zygiskHeaderRefresh(/,/^}/p; /^function cfgRenderZygiskCard(/,/^}/p; /^function deviceZygiskEditor(/,/^}/p' "$ROOT/webroot/index.html"
    cat <<'JS'
let bad=0;const chk=(c,m)=>{if(!c){console.log('FAIL '+m);bad++;}};
function find(n,c){if(n.className&&n.className.split(/\s+/).includes(c))return n;for(const x of n.children||[]){const r=find(x,c);if(r)return r;}return null;}
const d={sections:{system_load:{score:'53',band:'high',coverage_pct:'100'},zygisk_observer:{enabled_package_list:'com.example.app',safe_mode:'off'}}};
let scale=devicePressureScale(d),marker=find(scale,'dev-pressure-marker');chk(marker&&marker.style.left==='53%','valid pressure marker');chk(find(scale,'dev-pressure-score').textContent==='53/100','score text');
d.sections.system_load.score='unknown';scale=devicePressureScale(d);chk(!find(scale,'dev-pressure-marker'),'unknown gained a marker');chk(find(scale,'dev-pressure-score').textContent==='unknown','unknown not shown');
const linkBase={enabled:'1',safe_mode:'off',state_freshness:'no event state',loaded_processes:'0',events_total:'0',spawn_events:'0',policy_seen_generation:'0',policy_generation:'0',enabled_packages:'0',launch_hints:'0',spawn_ledger:'0',installed_abis:'arm64-v8a,armeabi-v7a'};
const linkData=p=>({sections:{zygisk_observer:Object.assign({},linkBase,p||{})}});
const linkState=(p,w)=>chk(deviceZygiskLinkState(linkData(p))===w,'link state '+w+' with '+JSON.stringify(p||{}));
linkState({},'idle'); // The supplied fix272 diagnostic: installed/enabled, but no selected work or events.
linkState({enabled_packages:'1',enabled_package_list:'com.example.app'},'waiting');
linkState({launch_hints:'1'},'waiting');linkState({spawn_ledger:'1'},'waiting');
linkState({state_freshness:'current',loaded_processes:'2',events_total:'2'},'connected');
linkState({state_freshness:'current',events_total:'1'},'confirmed');
linkState({state_freshness:'current',spawn_events:'1'},'confirmed');
linkState({state_freshness:'current',policy_seen_generation:'42',policy_generation:'42'},'confirmed');
linkState({state_freshness:'stale_over_5_minutes',events_total:'9'},'stale');
linkState({safe_mode:'on',state_freshness:'current',loaded_processes:'2'},'safe');
linkState({enabled:'0'},'off');linkState({events_total:'broken',state_freshness:'current'},'unknown');
linkState({enabled:'—'},'unknown');linkState({state_freshness:'not exposed'},'unknown');
let link=deviceZygiskLink(linkData({state_freshness:'current',loaded_processes:'2',events_total:'2'}));
chk(link.className.includes('dev-zygisk-link-connected'),'connected badge class');chk(find(link,'dev-zygisk-link-state').textContent==='Connected','connected badge text');chk(find(link,'dev-zygisk-link-detail').textContent.includes('2'),'live process evidence missing');
link=deviceZygiskLink(linkData({}));chk(link.className.includes('dev-zygisk-link-idle'),'installed ABI files falsely confirmed a channel');chk(find(link,'dev-zygisk-link-state').textContent==='Enabled · nothing selected','empty-selection badge text');
zygiskHeaderInit();chk(hosts.every(h=>!!find(h,'zygisk-header-link')),'not all five page headers received the badge');
chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='unknown'),'missing evidence did not remain unknown');
zygiskHeaderPublish(linkData({state_freshness:'current',loaded_processes:'2',events_total:'2'}));
chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='connected'),'validated live process did not paint every header');
zygiskHeaderPublish(linkData({}));chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='idle'),'installed ABI files falsely connected a page header');
const unifiedList=mk('div');cfgRenderZygiskCard(unifiedList,['zygisk_enabled','zygisk_hints','zygisk_launch','zygisk_ledger'].map(key=>({key,type:'bool'})));
const unified=find(unifiedList,'cfg-zygisk-card');chk(!!unified&&unified.children.length===5,'unified card does not contain one verdict plus four settings');
chk(unified&&unified.children.slice(1).every(r=>find(r,'cfg-switch')),'a unified Zygisk setting lost its switch');
chk(unified&&unified.children.slice(1).map(r=>r.attrs['data-key']).join(',')==='zygisk_enabled,zygisk_hints,zygisk_launch,zygisk_ledger','unified card changed setting ownership/order');
(async()=>{const ed=deviceZygiskEditor(d),input=find(ed,'dev-zygisk-input'),buttons=ed.children.flatMap(x=>x.children||[]).filter(x=>x.tagName==='button');
input.value='com.example.app;touch /tmp/pwn';await buttons[0].onclick();chk(commands.length===0,'malformed package reached shell');chk(refreshes===0,'malformed package refreshed collector');
input.value='com.example.app, org.example.game';await buttons[0].onclick();chk(commands.length===1&&commands[0].includes("set-packages 'com.example.app' 'org.example.game'"),'valid allowlist command');chk(refreshes===1,'valid save did not refresh');
await buttons[1].onclick();chk(commands[1].endsWith('safe-mode on'),'safe mode command');chk(refreshes===2,'safe mode did not refresh');
// Coalesced reads are sequence-checked: an older response cannot replace newer evidence.
commands=[];const deferred=[];run=c=>{commands.push(c);return new Promise(resolve=>deferred.push(resolve));};
const raw=p=>Object.entries(Object.assign({},linkBase,p)).map(([k,v])=>'D\tzygisk_observer\t'+k+'\t'+v).join('\n');
const older=zygiskHeaderRefresh();zygiskHeaderRefresh();chk(commands.length===1&&commands[0].includes('link-status'),'concurrent header reads were not coalesced');
deferred[0]({errno:0,stdout:raw({state_freshness:'current',loaded_processes:'2',events_total:'2'}),stderr:''});await older;
await new Promise(r=>setTimeout(r,0));chk(commands.length===2,'queued header refresh did not start');chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='idle'),'stale header response overwrote newer request');
deferred[1]({errno:0,stdout:raw({state_freshness:'current',loaded_processes:'2',events_total:'2'}),stderr:''});await new Promise(r=>setTimeout(r,0));
chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='connected'),'newest header evidence was not published');chk(commands.every(c=>!c.includes(' sync')),'evidence read unexpectedly wrote policy');
// fix278: one mode control. The four switches map to four named presets; anything else is shown as custom.
const md=p=>({sections:{zygisk_observer:Object.assign({enabled:'1',lifecycle_hints:'0',launch_hints:'0',spawn_ledger:'0',safe_mode:'off'},p)}});
chk(zygiskModeOf(md({enabled:'0',lifecycle_hints:'1'}))==='off','master off is Off whatever the parts say');
chk(zygiskModeOf(md({spawn_ledger:'1'}))==='watch','ledger only is Watch');
chk(zygiskModeOf(md({lifecycle_hints:'1',launch_hints:'1'}))==='speed','hints + launch is Response');
chk(zygiskModeOf(md({lifecycle_hints:'1',launch_hints:'1',spawn_ledger:'1'}))==='full','all four is Full');
chk(zygiskModeOf(md({launch_hints:'1'}))==='custom','a set no preset matches is custom');
chk(zygiskModeOf(md({enabled:'—'}))==='unknown','an unreadable master is unknown, not Off');
let card=zygiskModeCard(md({lifecycle_hints:'1',launch_hints:'1'})),seg=find(card,'zy-mode-seg');
chk(seg&&seg.children.length===4,'four mode buttons');chk(seg&&seg.children[2].className==='on'&&seg.children.filter(b=>b.className==='on').length===1,'exactly the current mode is selected');
card=zygiskModeCard(md({launch_hints:'1'}));seg=find(card,'zy-mode-seg');chk(seg.children.every(b=>b.className!=='on'),'custom selects no preset');
// Choosing a mode is ONE root shell: the locked set-many write, the policy sync and the fresh read.
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:'asb-mode-ok\n'+_ASB_PART+'write\n'+raw({lifecycle_hints:'1',launch_hints:'1',spawn_ledger:'1'})+'\n'+_ASB_PART+'link',stderr:''};};
await zygiskModeSet('full');
chk(commands.length===1,'a mode change took '+commands.length+' root shells');
chk(/set-many --snapshot '[^']+' 'zygisk_enabled' '1' 'zygisk_hints' '1' 'zygisk_launch' '1' 'zygisk_ledger' '1' && \{ sh '[^']+asb_zygisk\.sh' sync/.test(commands[0]),'mode write is not one locked set-many followed by sync: '+commands[0]);
chk(commands[0].indexOf('link-status')>commands[0].indexOf(' sync'),'the fresh read does not follow the write');
chk(_cfgVals.zygisk_ledger==='1'&&_cfgVals.zygisk_hints==='1'&&_cfgLoadSig==='','Settings values not updated after the write');
chk(/applied/.test(toastText),'success not reported: '+toastText);
commands=[];await zygiskModeSet('off');chk(/set-many --snapshot '[^']+' 'zygisk_enabled' '0' &&/.test(commands[0]),'Off must only clear the master switch: '+commands[0]);
run=async c=>{commands.push(c);return {errno:0,stdout:'refused\n'+_ASB_PART+'write\n'+_ASB_PART+'link',stderr:''};};_cfgVals={};
await zygiskModeSet('watch');chk(!_cfgVals.zygisk_ledger&&/not saved/.test(toastText),'a refused write was reported as applied');
if(bad)process.exit(1);console.log('ok');})().catch(e=>{console.error(e);process.exit(1)});
JS
  } > "$T/test.js"
  out="$(node "$T/test.js" 2>&1)" || fail "$out"
  [ "$out" = ok ] || fail "$out"
  python3 - "$ROOT/webroot/i18n" <<'PY' || fail 'link badge locales'
import json, pathlib, sys
states = ('connected', 'confirmed', 'waiting', 'idle', 'stale', 'safe', 'off', 'unknown')
files = sorted(pathlib.Path(sys.argv[1]).glob('*.json'))
assert len(files) == 13
for p in files:
    d = json.loads(p.read_text(encoding='utf-8'))
    for state in states:
        assert d['dev_zygisk_link_' + state].strip(), (p, state)
        assert d['dev_zygisk_link_' + state + '_detail'].strip(), (p, state)
    assert d['dev_zygisk_link_connected_detail'].count('{n}') == 1, p
    assert d['cfg_ui_section_zygisk'].strip(), p
    assert d['cfg_ui_section_zygisk_hint'].strip(), p
PY
  echo 'PASS observer UI: unified four-switch card, five evidence-bounded headers, 13 locales, scale and safe editor'
)

t_zygisk_capture_digest_runtime() (
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer capture digest: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  CAP="$T/capture"; mkdir -p "$CAP"
  printf 'current_profile: smart\n' > "$CAP/env.txt"
  _snap() {
    _file="$1"; _state="$2"; _base="$3"
    {
      printf 'M\tcaptured_epoch=1000\n'
      printf 'D\tzygisk_observer\tlink_state\t%s\n' "$_state"
      printf 'D\tzygisk_observer\tenabled\t1\nD\tzygisk_observer\tsafe_mode\toff\n'
      printf 'D\tzygisk_observer\tstate_freshness\tcurrent\nD\tzygisk_observer\tloaded_processes\t1\n'
      printf 'D\tzygisk_observer\tpolicy_generation\t42\nD\tzygisk_observer\tpolicy_seen_generation\t42\n'
      printf 'D\tzygisk_observer\tenabled_packages\t1\nD\tzygisk_observer\tinstalled_abis\tarm64-v8a\n'
      printf 'D\tzygisk_observer\tlifecycle_hints\t1\nD\tzygisk_observer\tlaunch_hints\t1\nD\tzygisk_observer\tspawn_ledger\t1\nD\tzygisk_observer\tmemory_kb\t2222\n'
      for _k in events_total spawn_events launch_events launch_accepted policy_hints hints_accepted hints_vetoed ledger_events events_dropped_total ipc_cpu_ms ipc_wakeups; do
        printf 'D\tzygisk_observer\t%s\t%s\n' "$_k" "$_base"
      done
    } > "$_file"
  }
  _snap "$CAP/zygisk_observer_start.tsv" waiting 10
  _snap "$CAP/zygisk_observer_latest.tsv" connected 15
  out="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP")"
  zy="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'^zygisk\tstate=connected\tstart_state=waiting\tcoverage=start_latest' || fail "capture verdict missing: $zy"
  printf '%s\n' "$zy" | grep -q $'events_total_delta=5' || fail 'event delta missing'
  printf '%s\n' "$zy" | grep -q $'launch_accepted_delta=5' || fail 'launch delta missing'
  printf '%s\n' "$zy" | grep -q $'ipc_cpu_ms_delta=5' || fail 'IPC delta missing'
  printf '%s\n' "$zy" | grep -q $'deltas=available' || fail 'valid deltas not acknowledged'
  _snap "$CAP/zygisk_observer_latest.tsv" connected 4
  zy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'events_total_delta=unknown' || fail 'counter reset invented a delta'
  printf '%s\n' "$zy" | grep -q $'deltas=counter_reset_or_restart' || fail 'counter reset was not named'
  rm "$CAP/zygisk_observer_start.tsv"
  zy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'coverage=latest_only' || fail 'single snapshot not bounded'
  printf '%s\n' "$zy" | grep -q $'events_total_delta=unknown' || fail 'single snapshot invented a delta'
  rm "$CAP/zygisk_observer_latest.tsv"
  ! ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | grep -q '^zygisk' || fail 'legacy capture gained fake Zygisk evidence'
  echo 'PASS observer capture digest: start/latest verdicts, monotonic deltas, reset and legacy-capture honesty'
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
