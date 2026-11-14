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
  assert(c.start(b,1500)==AsbObserverResult::accepted && c.rate_limited()==0); // a sibling process in the same second
  b=frame(14,"com.example.app",1600);
  assert(c.start(b,1600)==AsbObserverResult::accepted && c.rate_limited()==0);
  b=frame(15,"com.example.app",1700);
  assert(c.start(b,1700)==AsbObserverResult::rate_limited && c.rate_limited()==1); // a fourth start in one second
  b=frame(15,"com.example.app",2600);
  assert(c.start(b,2600)==AsbObserverResult::accepted); // the second has passed
  assert(c.exit(11) && c.exit(14) && c.exit(15));
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
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|32u; assert(!asb_observer_frame_valid(sp)); // unknown bit
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_DENYLIST; assert(asb_observer_frame_valid(sp));
  sp.flags=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH; snprintf(sp.package,sizeof(sp.package),"com.example.app");
  assert(asb_observer_frame_valid(sp)); // fix286: a launch-only record may name its package for the class lookup
  snprintf(sp.package,sizeof(sp.package),"com.android.systemui"); assert(!asb_observer_frame_valid(sp));
  snprintf(sp.package,sizeof(sp.package),"bad name"); assert(!asb_observer_frame_valid(sp));
  snprintf(sp.package,sizeof(sp.package),"com.example.app");
  sp.flags=ASB_OBSERVER_FLAG_LEDGER; assert(asb_observer_frame_valid(sp));
  snprintf(sp.package,sizeof(sp.package),"com.android.systemui"); assert(!asb_observer_frame_valid(sp));
  sp.version=1; snprintf(sp.package,sizeof(sp.package),"com.example.app"); assert(!asb_observer_frame_valid(sp));
  auto spawn_as_start=frame(21,"com.example.app",6000); spawn_as_start.kind=ASB_OBSERVER_EVENT_SPAWN; spawn_as_start.flags=ASB_OBSERVER_FLAG_LEDGER;
  AsbObserverCore s2; assert(s2.start(spawn_as_start,6000)==AsbObserverResult::invalid && s2.loaded()==0);
  // fix339: an allowlisted app's SPAWN frame (OBSERVE) starts the record; it must name a valid,
  // unprotected package. An exit counts once and only for the instance that was started.
  spawn_as_start.flags=ASB_OBSERVER_FLAG_OBSERVE; assert(asb_observer_frame_valid(spawn_as_start));
  spawn_as_start.flags=ASB_OBSERVER_FLAG_OBSERVE|ASB_OBSERVER_FLAG_LEDGER|ASB_OBSERVER_FLAG_DENYLIST; assert(asb_observer_frame_valid(spawn_as_start));
  auto obs_empty=spawn_as_start; obs_empty.package[0]=0; assert(!asb_observer_frame_valid(obs_empty));
  auto obs_denied=spawn_as_start; snprintf(obs_denied.package,sizeof(obs_denied.package),"com.android.systemui"); assert(!asb_observer_frame_valid(obs_denied));
  assert(s2.start(spawn_as_start,6000)==AsbObserverResult::accepted && s2.loaded()==1 && s2.events_total()==1);
  assert(s2.has(21,99) && !s2.has(21,98) && !s2.exit_if(21,98) && s2.loaded()==1);
  assert(s2.exit_if(21,99) && !s2.exit_if(21,99) && !s2.exit(21) && s2.loaded()==0 && s2.events_total()==2);
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
  const char xok[]="v=2\ngen=1730000001\nobserver=1\nhints=1\nlaunch=1\nledger=1\npkg=com.example.app\npkg=org.example.game\nxpkg=com.example.compat\nxpkg=org.example.game\n";
  assert(asb_observer_policy_parse(xok,sizeof(xok)-1,pol) && pol.active() && pol.excluded_packages==2);
  assert(pol.excluded("com.example.compat") && pol.excluded("org.example.game") && !pol.excluded("com.example.app"));
  assert(pol.selected("com.example.app") && !pol.selected("org.example.game")); // exclusion wins over allowlist
  const char xbad[]="v=2\nlaunch=1\nxpkg=com.android.systemui\n"; assert(!asb_observer_policy_parse(xbad,sizeof(xbad)-1,pol));
  const char xdup[]="v=2\nlaunch=1\nxpkg=com.example.compat\nxpkg=com.example.compat\n"; assert(!asb_observer_policy_parse(xdup,sizeof(xdup)-1,pol));
  const char pdup[]="v=2\nobserver=1\npkg=com.example.app\npkg=com.example.app\n"; assert(!asb_observer_policy_parse(pdup,sizeof(pdup)-1,pol));
  std::string xmany="v=2\nlaunch=1\n"; for (int i=0;i<65;i++) xmany+="xpkg=com.example.x"+std::to_string(i)+"\n";
  assert(!asb_observer_policy_parse(xmany.data(),xmany.size(),pol));
  const char nover[]="observer=1\npkg=com.example.app\n"; assert(!asb_observer_policy_parse(nover,sizeof(nover)-1,pol) && !pol.active());
  const char badpkg[]="v=2\nobserver=1\npkg=com.android.systemui\n"; assert(!asb_observer_policy_parse(badpkg,sizeof(badpkg)-1,pol));
  const char unknown[]="v=2\nlaunch=1\ncap=3000000\n"; assert(!asb_observer_policy_parse(unknown,sizeof(unknown)-1,pol));
  const char flag2[]="v=2\nlaunch=2\n"; assert(!asb_observer_policy_parse(flag2,sizeof(flag2)-1,pol));
  const char idle[]="v=2\nobserver=0\nhints=1\nlaunch=0\nledger=0\n"; assert(asb_observer_policy_parse(idle,sizeof(idle)-1,pol) && !pol.active());
  std::string many="v=2\nobserver=1\n"; for (int i=0;i<65;i++) many+="pkg=com.example.p"+std::to_string(i)+"\n";
  assert(!asb_observer_policy_parse(many.data(),many.size(),pol));
  // fix286: launch classes - strict, bounded, and an invalid file leaves every app normal.
  static AsbObserverClasses cl;
  const char cok[]="v=1\nslow=com.example.heavy\nslow=org.example.hooked\nfast=com.example.light\n";
  assert(asb_observer_classes_parse(cok,sizeof(cok)-1,cl) && cl.valid && cl.slow==2 && cl.fast==1);
  assert(cl.lookup("com.example.heavy")==ASB_LAUNCH_LONG && cl.lookup("org.example.hooked")==ASB_LAUNCH_LONG);
  assert(cl.lookup("com.example.light")==ASB_LAUNCH_SHORT && cl.lookup("com.example.other")==ASB_LAUNCH_NORMAL);
  assert(cl.lookup("")==ASB_LAUNCH_NORMAL && cl.lookup(nullptr)==ASB_LAUNCH_NORMAL);
  const char cnov[]="slow=com.example.heavy\n"; assert(!asb_observer_classes_parse(cnov,sizeof(cnov)-1,cl) && cl.lookup("com.example.heavy")==ASB_LAUNCH_NORMAL);
  const char cv2[]="v=2\nslow=com.example.heavy\n"; assert(!asb_observer_classes_parse(cv2,sizeof(cv2)-1,cl));
  const char cdup[]="v=1\nslow=com.example.app\nfast=com.example.app\n"; assert(!asb_observer_classes_parse(cdup,sizeof(cdup)-1,cl));
  const char cdup2[]="v=1\nfast=com.example.app\nfast=com.example.app\n"; assert(!asb_observer_classes_parse(cdup2,sizeof(cdup2)-1,cl));
  const char cden[]="v=1\nslow=com.android.systemui\n"; assert(!asb_observer_classes_parse(cden,sizeof(cden)-1,cl));
  const char ckey[]="v=1\nslow=com.example.heavy\nlift=10\n"; assert(!asb_observer_classes_parse(ckey,sizeof(ckey)-1,cl) && !cl.valid);
  const char cbad[]="v=1\nslow=com.example.heavy;rm\n"; assert(!asb_observer_classes_parse(cbad,sizeof(cbad)-1,cl));
  const char cnoeq[]="v=1\nslow\n"; assert(!asb_observer_classes_parse(cnoeq,sizeof(cnoeq)-1,cl));
  std::string cmany="v=1\n"; for (int i=0;i<65;i++) cmany+="slow=com.example.s"+std::to_string(i)+"\n";
  assert(!asb_observer_classes_parse(cmany.data(),cmany.size(),cl));
  std::string cfull="v=1\n"; for (int i=0;i<64;i++) cfull+="slow=com.example.s"+std::to_string(i)+"\nfast=com.example.f"+std::to_string(i)+"\n";
  assert(cfull.size()<=ASB_OBSERVER_CLASSES_MAX_BYTES && asb_observer_classes_parse(cfull.data(),cfull.size(),cl) && cl.slow==64 && cl.fast==64);
  const char cempty[]="v=1\n"; assert(asb_observer_classes_parse(cempty,sizeof(cempty)-1,cl) && cl.lookup("com.example.s1")==ASB_LAUNCH_NORMAL);
  std::cout << "observer core ok\n";
}
CPP
  g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/core.cpp" -o "$T/core" || fail 'C++ build'
  "$T/core" | grep -qx 'observer core ok' || fail 'core assertions'
  echo 'PASS observer native core: validation, exclusions, lifecycle/hint/cold-start bounds, ledger, policy and launch-class parsers, exit and TTL'
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
  ! grep -q 'api_->exemptFd\|socket_ = sock\|package_ = base' "$S" \
    || fail 'an app-side retained socket/state returned'
  grep -q 'close(sock);' "$S" && grep -q 'return skip();' "$S" \
    || fail 'one-shot app lifecycle does not close and request unload'
  grep -q 'rm -f "$POLICY"' "$ROOT/runtime/asb_zygisk.sh" || fail 'safe mode/disable does not withdraw the policy'
  ! grep -q 'api_->hookJniNativeMethods\|api_->pltHook\|scaling_\|APP_FOREGROUND\|APP_CAMERA' "$S" \
    || fail 'observer gained hooks, hardware writes or unimplemented events'
  grep -q 'ASB_GOVERNOR_SOCKET "/dev/.asb/ctl.sock"' "$S" || fail 'bounded governor refresh channel missing'
  grep -q 'static const char command\[\] = "zygisk-refresh"' "$S" || fail 'refresh carries more than its fixed opcode'
  grep -q 'static const char command\[\] = "zygisk-launch"' "$S" || fail 'cold start carries more than its fixed opcode'
  grep -q 'static const char command\[\] = "zygisk-launch-long"' "$S" && grep -q 'static const char command\[\] = "zygisk-launch-short"' "$S" \
    || fail 'launch classes are not fixed opcodes'
  ! grep -q 'request_governor(frame\|request_governor(base\|request_governor(package\|request_governor(std::' "$S" || fail 'a package reaches the governor request'
  grep -q 'api_->getFlags() & zygisk::PROCESS_ON_DENYLIST' "$S" || fail 'the unmount flag is not counted'
  grep -q 'const bool observe = !base.empty() && policy.selected(base.c_str());' "$S" \
    || fail 'the unmount flag (every app without root on KernelSU) still silences the allowlist'
  [ "$(grep -c 'classes_locked()' "$S")" = 2 ] || fail 'launch classes are read outside the companion'
  sed -n '/void preAppSpecialize/,/void preServerSpecialize/p' "$S" | grep -q 'CLASSES' && fail 'the zygote side reads the launch classes'
  grep -q 'ASB_ZYGISK_CLASSES_ABS "/data/adb/modules/AutoSystemBoost/zygisk/classes"' "$ROOT/src/zygisk/asb_observer_protocol.h" || fail 'classes path'
  ! grep -q 'slow=\|fast=' "$ROOT/runtime/asb_zygisk.sh" || fail 'launch classes leaked into the process policy'
  grep -q "printf 'xpkg=%s" "$ROOT/runtime/asb_zygisk.sh" || fail 'owner exclusions do not reach the generated policy'
  ! grep -q 'fsync' "$S" || fail 'companion state is fsynced to flash on every event'
  grep -q 'ASB_GOVERNOR_HINT_TIMEOUT_US 100000' "$S" || fail 'governor round trip is not bounded to 100 ms'
  ! grep -q 'profile:\|start-session:\|zygisk-refresh:' "$S" || fail 'observer gained a profile/policy command'
  ! grep -q 'write_all(socket_' "$S" || fail 'the removed retained-socket START send returned'
  [ "$(grep -c 'send_spawn(sock,' "$S")" = 1 ] || fail 'more than the single one-shot spawn send exists'
  grep -q 'MSG_NOSIGNAL | MSG_DONTWAIT' "$S" || fail 'optional spawn telemetry can still block app startup'
  grep -q 'policy.excluded(base.c_str())' "$S" && grep -q 'policy.excluded(frame.package)' "$S" \
    || fail 'owner exclusion is not enforced on both app and companion sides'
  grep -q 'std::lock_guard<std::mutex>' "$S" || fail 'parallel companion handlers are not serialized'
  grep -q 'SO_PEERCRED' "$S" && grep -q 'process_start_ticks(frame.pid)' "$S" || fail 'peer/PID reuse validation missing'
  # fix339: exits are watched by the companion through process fds in one poll() without a
  # timeout - an event wait, not a periodic loop - and the watch set is bounded.
  grep -q 'const int pidfd = open_pidfd(frame.pid);' "$S" || fail 'allowlisted exits still depend on the app keeping its socket'
  grep -q 'poll(fds.data(), static_cast<nfds_t>(fds.size()), -1)' "$S" || fail 'the exit watcher is not a pure event wait'
  grep -q 'watches_.size() >= ASB_OBSERVER_MAX_PROCESSES' "$S" || fail 'the process-fd watch set is unbounded'
  G="$ROOT/src/asb_governor.c"
  sed -n '/else if (strcmp(cmd, "zygisk-refresh") == 0)/,/else if (strcmp(cmd, "status")/p' "$G" > "$T.hint"
  grep -q 'g_asb_cfg.zygisk_enabled' "$T.hint" && grep -q 'g_asb_cfg.zygisk_hints' "$T.hint" || fail 'governor hint opt-in gates missing'
  grep -q 'zygisk_observer/disable' "$T.hint" && grep -q 'err:screen_off' "$T.hint" || fail 'safe-mode/screen-off veto missing'
  grep -q 'need_metrics = 1' "$T.hint" && grep -q 'asb_smart_pkg_cache_invalidate' "$T.hint" || fail 'hint does not request fresh evidence'
  ! grep -q 'force_write = 1\|g_last_reassert = 0\|profile_idx =\|CPU_MAX\|scaling_' "$T.hint" || fail 'hint bypassed normal governor policy'
  rm -f "$T.hint"
  sed -n '/else if (strcmp(cmd, "zygisk-launch") == 0 ||/,/else if (strcmp(cmd, "status")/p' "$G" > "$T.launch"
  grep -q 'g_asb_cfg.zygisk_enabled' "$T.launch" && grep -q 'g_asb_cfg.zygisk_launch' "$T.launch" || fail 'cold-start opt-in gates missing'
  grep -q 'zygisk_observer/disable' "$T.launch" && grep -q 'err:screen_off' "$T.launch" || fail 'cold-start safe-mode/screen-off veto missing'
  grep -q 'g_unlock_cold_kick = asb_cold_kick_merge(g_unlock_cold_kick, cold_class);' "$T.launch" && grep -q 'need_metrics = 1' "$T.launch" \
    || fail 'cold start does not feed the existing lift'
  grep -q 'strcmp(cmd, "zygisk-launch-long") == 0 ? ASB_COLD_LONG' "$T.launch" && grep -q 'strcmp(cmd, "zygisk-launch-short") == 0 ? ASB_COLD_SHORT : ASB_COLD_NORMAL' "$T.launch" \
    || fail 'launch class opcodes are not decoded'
  grep -q 'strcmp(cmd, "zygisk-launch-long") == 0 ||' "$G" && grep -q 'strcmp(cmd, "zygisk-launch-short") == 0)' "$G" || fail 'class opcodes are logged on every launch'
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
  # fix285: the companion's windows and state age are on the suspend-aware clock.
  grep -q 'clock_gettime(CLOCK_BOOTTIME, &ts)' "$ROOT/src/zygisk/asb_observer_protocol.h" || fail 'no CLOCK_BOOTTIME source'
  grep -q 'const int64_t now = asb_observer_boottime_ms();' "$ROOT/src/zygisk/asb_observer.cpp" || fail 'companion windows still on CLOCK_MONOTONIC'
  grep -q 'updated_boottime_ms' "$ROOT/src/zygisk/asb_observer.cpp" || fail 'state does not carry a boottime stamp'
  ! grep -q 'asb_observer_monotonic_ms()' "$ROOT/src/zygisk/asb_observer_core.h" || fail 'the core reads a clock itself'
  echo 'PASS observer native contract: fail-open, no hooks/cap writer, bounded refresh IPC, two ABIs, suspend-aware windows and synchronized diagnostics'
)

t_zygisk_policy_read_runtime() (
  # V66 dev29. dev23 added a stat-keyed policy cache to the Observer object. read_policy runs
  # from preAppSpecialize, i.e. in the freshly forked app process, so whatever it stores stays in
  # that process; under Magisk the module is even dlopened and constructed anew in every app
  # process. The cache could never serve the next fork and only added a stat and an fstat, so the
  # simple read is back. This drives the REAL Observer with wrapped libc calls: one open, one
  # parse, no stat/fstat per read; replacement, removal, malformed and inactive policies; every
  # failure leaves an empty inactive policy; EACCES falls back to the loader's module dir.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer policy read: $*" >&2; exit 1; }
  command -v g++ >/dev/null 2>&1 || { echo 'SKIP observer policy read: no g++'; exit 0; }
  ! grep -Eq 'policy_cached_|PolicyStamp|cached_policy_' "$ROOT/src/zygisk/asb_observer.cpp" || fail 'a cross-fork policy cache is back'
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/inc" "$T/mod/zygisk"
  cat > "$T/inc/jni.h" <<'JNI'
#pragma once
#include <cstdint>
typedef int32_t jint; typedef int64_t jlong; typedef uint8_t jboolean; typedef void* jobject; typedef jobject jstring; typedef jobject jintArray; typedef jobject jobjectArray;
struct JNINativeMethod { const char* name; const char* signature; void* fnPtr; };
struct JNIEnv { const char* GetStringUTFChars(jstring, void*){return nullptr;} void ReleaseStringUTFChars(jstring,const char*){} };
JNI
  cat > "$T/read.cpp" <<'CPP'
#include <string>
static std::string g_policy_abs, g_policy_rel, g_run_dir, g_classes, g_gov_state, g_socket, g_client_dir;
#define ASB_ZYGISK_POLICY_ABS (g_policy_abs.c_str())
#define ASB_ZYGISK_POLICY_REL (g_policy_rel.c_str())
#define ASB_ZYGISK_RUN_DIR (g_run_dir.c_str())
#define ASB_ZYGISK_CLASSES_ABS (g_classes.c_str())
#define ASB_GOVERNOR_STATE (g_gov_state.c_str())
#define ASB_GOVERNOR_SOCKET (g_socket.c_str())
#define ASB_GOVERNOR_CLIENT_DIR (g_client_dir.c_str())
#include "zygisk.hpp"
#include "asb_observer_core.h"
#include <cassert>
#include <cerrno>
#include <cstdarg>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <map>
#include <mutex>
#include <poll.h>
#include <pthread.h>
#include <set>
#include <sstream>
#include <string>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

static bool g_deny_abs = false, g_fail_stat = false, g_fail_open = false, g_fail_fstat = false;
static bool g_fail_fstatat = false, g_no_moddir = false;
static int g_moddir = -1;
static zygisk::internal::module_abi *g_abi = nullptr;
static bool register_module(zygisk::internal::api_table *, zygisk::internal::module_abi *abi) { g_abi = abi; return true; }
static int g_opens = 0, g_openats = 0, g_reads = 0, g_parses = 0, g_stats = 0, g_fstatats = 0, g_fstats = 0;
static std::set<int> g_policy_fds;
static bool is_abs(const char *p) { return p && g_policy_abs == p; }
static bool is_rel(const char *p) { return p && g_policy_rel == p; }
[[maybe_unused]] static int test_open(const char *path, int flags, ...) {
  if (is_abs(path) && g_deny_abs) { errno = EACCES; return -1; }
  if (is_abs(path) && g_fail_open) { errno = EIO; return -1; }
  mode_t mode = 0;
  if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = static_cast<mode_t>(va_arg(ap, int)); va_end(ap); }
  const int fd = open(path, flags, mode);
  if (fd >= 0 && is_abs(path)) { ++g_opens; g_policy_fds.insert(fd); }
  return fd;
}
[[maybe_unused]] static int test_openat(int dir, const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = static_cast<mode_t>(va_arg(ap, int)); va_end(ap); }
  const int fd = openat(dir, path, flags, mode);
  if (fd >= 0 && is_rel(path)) { ++g_openats; g_policy_fds.insert(fd); }
  return fd;
}
[[maybe_unused]] static int test_stat(const char *path, struct stat *st) {
  if (is_abs(path)) {
    ++g_stats;
    if (g_deny_abs) { errno = EACCES; return -1; }
    if (g_fail_stat) { errno = EIO; return -1; }
  }
  return stat(path, st);
}
[[maybe_unused]] static int test_fstatat(int dir, const char *path, struct stat *st, int flags) {
  if (is_rel(path)) {
    ++g_fstatats;
    if (g_fail_fstatat) { errno = EIO; return -1; }
  }
  return fstatat(dir, path, st, flags);
}
[[maybe_unused]] static int test_fstat(int fd, struct stat *st) {
  if (g_policy_fds.count(fd)) { ++g_fstats; if (g_fail_fstat) { errno = EIO; return -1; } }
  return fstat(fd, st);
}
static ssize_t test_read(int fd, void *buf, size_t cap) {
  if (g_policy_fds.count(fd)) ++g_reads;
  return read(fd, buf, cap);
}
[[maybe_unused]] static int test_close(int fd) { g_policy_fds.erase(fd); return close(fd); }
static bool test_parse(const char *text, size_t len, AsbObserverPolicy &out) {
  ++g_parses;
  return asb_observer_policy_parse(text, len, out);
}
#define private public
#define open(...) test_open(__VA_ARGS__)
#define openat(...) test_openat(__VA_ARGS__)
#define stat(path, st) test_stat(path, st)
#define fstatat(dir, path, st, flags) test_fstatat(dir, path, st, flags)
#define fstat(fd, st) test_fstat(fd, st)
#define read(fd, buf, cap) test_read(fd, buf, cap)
#define close(fd) test_close(fd)
#define asb_observer_policy_parse(text, len, out) test_parse(text, len, out)
#include "asb_observer.cpp"
#undef asb_observer_policy_parse
#undef close
#undef read
#undef fstat
#undef fstatat
#undef stat
#undef openat
#undef open
#undef private

static void put_policy(const std::string &text) {
  const std::string tmp = g_policy_abs + ".tmp";
  { std::ofstream f(tmp, std::ios::trunc); f << text; f.close(); assert(f); }
  assert(rename(tmp.c_str(), g_policy_abs.c_str()) == 0);
}
static void reset_counts() {
  g_opens = g_openats = g_reads = g_parses = g_stats = g_fstatats = g_fstats = 0;
}
int main(int argc, char **argv) {
  assert(argc == 2);
  g_policy_abs = std::string(argv[1]) + "/zygisk/policy";
  g_policy_rel = "zygisk/policy";
  g_run_dir = std::string(argv[1]) + "/run";
  g_classes = std::string(argv[1]) + "/zygisk/classes";
  g_gov_state = std::string(argv[1]) + "/state";
  g_socket = std::string(argv[1]) + "/ctl.sock";
  g_client_dir = argv[1];
  g_moddir = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  assert(g_moddir >= 0);
  zygisk::internal::api_table table{};
  table.registerModule = register_module;
  table.getModuleDir = [](void *) { return g_no_moddir ? -1 : g_moddir; };
  zygisk_module_entry(&table, nullptr);
  assert(g_abi);
  Observer &observer = *static_cast<Observer *>(g_abi->impl);
  AsbObserverPolicy p;
  reset_counts();
  assert(!observer.read_policy(p) && !p.valid && !p.active());
  assert(g_opens == 0 && g_openats == 0 && g_parses == 0);

  put_policy("v=2\ngen=1\nobserver=1\nhints=0\nlaunch=0\nledger=0\npkg=com.example.aa\n");
  reset_counts();
  assert(observer.read_policy(p) && p.active() && p.generation == 1 && p.selected("com.example.aa"));
  assert(g_opens == 1 && g_openats == 0 && g_reads == 2 && g_parses == 1);
  assert(g_stats == 0 && g_fstats == 0 && g_fstatats == 0);
  for (int i = 0; i < 3; ++i) assert(observer.read_policy(p) && p.generation == 1);
  assert(g_opens == 4 && g_parses == 4 && g_stats == 0 && g_fstats == 0);

  put_policy("v=2\ngen=2\nobserver=1\nhints=1\nlaunch=0\nledger=0\npkg=com.example.bb\n");
  assert(observer.read_policy(p) && p.generation == 2 && p.hints && p.selected("com.example.bb"));
  assert(!p.selected("com.example.aa"));
  assert(unlink(g_policy_abs.c_str()) == 0);
  assert(!observer.read_policy(p) && !p.valid && !p.active() && p.packages == 0);

  put_policy("v=2\ngen=3\nobserver=1\nhints=0\nlaunch=0\nledger=0\npkg=com.example.cc\n");
  assert(observer.read_policy(p) && p.generation == 3);
  put_policy("v=2\nlaunch=1\ncap=1\n");
  assert(!observer.read_policy(p) && !p.valid && !p.active() && p.packages == 0);

  put_policy("v=2\ngen=4\nobserver=0\nhints=0\nlaunch=0\nledger=0\n");
  assert(observer.read_policy(p) && p.valid && !p.active());

  put_policy("v=2\ngen=5\nobserver=1\nhints=0\nlaunch=0\nledger=0\npkg=com.example.dd\n");
  g_fail_open = true; g_no_moddir = true;
  assert(!observer.read_policy(p) && !p.valid && !p.active() && p.packages == 0);
  g_no_moddir = false;
  reset_counts();
  assert(observer.read_policy(p) && p.generation == 5 && g_opens == 0 && g_openats == 1);
  g_fail_open = false;

  g_deny_abs = true;
  reset_counts();
  assert(observer.read_policy(p) && p.generation == 5 && g_opens == 0 && g_openats == 1);
  g_no_moddir = true;
  assert(!observer.read_policy(p) && !p.valid && !p.active());
  g_no_moddir = false;

  Observer fallback;
  fallback.onLoad(observer.api_, nullptr);
  reset_counts();
  assert(fallback.read_policy(p) && p.generation == 5 && p.selected("com.example.dd"));
  assert(g_opens == 0 && g_openats == 1 && g_reads == 2 && g_parses == 1 && g_stats == 0 && g_fstatats == 0);
  assert(unlink(g_policy_abs.c_str()) == 0);
  assert(!fallback.read_policy(p) && !p.valid && !p.active() && p.packages == 0);
  g_deny_abs = false;
  close(g_moddir);
  return 0;
}
CPP
  g++ -std=c++17 -Wall -Wextra -Werror -Werror=narrowing -Wno-unused-parameter -pthread -I"$T/inc" -I"$ROOT/src/zygisk" \
    -DASB_ABI_TAG='"arm64-v8a"' "$T/read.cpp" -o "$T/read" || fail 'policy read fixture build'
  "$T/read" "$T/mod" || fail 'policy read runtime assertions'
  echo 'PASS observer policy read: one open and one parse per read, no stat/fstat, replacement, removal, malformed and inactive policies, fail-closed errors, EACCES module-dir fallback'
)

t_zygisk_hot_path_runtime() (
  # fix272: the REAL module and companion, driven through the Zygisk ABI on the host with a
  # fake loader table. Dormant = no policy, DLCLOSE and no companion; isolated/system
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
#include <sys/wait.h>
#include <thread>
#include <vector>
using namespace zygisk::internal;
static module_abi *g_abi; static int g_connects=0, g_dlclose=0, g_exempt=0, g_peer=-1;
static bool g_fill_socket=false;
static bool reg(api_table*, module_abi *abi){ g_abi=abi; return true; }
static bool exempt(int){ ++g_exempt; return true; }
static int connect_c(void*){
  ++g_connects; int sv[2]; if (socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sv)) return -1;
  if(g_fill_socket){
    int small=4096; setsockopt(sv[0],SOL_SOCKET,SO_SNDBUF,&small,sizeof(small));
    int fl=fcntl(sv[0],F_GETFL,0); assert(fl>=0 && fcntl(sv[0],F_SETFL,fl|O_NONBLOCK)==0);
    char fill[4096]{}; while(send(sv[0],fill,sizeof(fill),MSG_NOSIGNAL)>0){}
    assert(errno==EAGAIN || errno==EWOULDBLOCK); assert(fcntl(sv[0],F_SETFL,fl)==0);
  }
  g_peer=sv[1]; return sv[0];
}
static void setopt(void*, zygisk::Option o){ if (o==zygisk::DLCLOSE_MODULE_LIBRARY) ++g_dlclose; }
static int moddir(void*){ return -1; }
static uint32_t g_flags=0;
static uint32_t flags_fn(void*){ return g_flags; }
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
static long zval(const std::string &s, const char *key){ std::string k=std::string("Z\t")+key+"\t"; size_t at=s.find(k);
  return at==std::string::npos ? -1 : std::atol(s.c_str()+at+k.size()); }
static bool has_proc(const std::string &s, pid_t pid){ return s.find("\nP\t"+std::to_string(pid)+"\t")!=std::string::npos; }
static bool wait_state(bool (*ok)(const std::string&)){ for(int i=0;i<400;i++){ if(ok(state())) return true; std::this_thread::sleep_for(std::chrono::milliseconds(5)); } return false; }
// fix339: a real child process stands in for an allowlisted app. Its own connection gives
// SO_PEERCRED its PID, as the loader's companion socket does; "keep" is an app whose socket the
// loader let it keep (a START follows), otherwise the socket is gone right after SPAWN.
struct App { pid_t pid; int go; };
static std::string g_comp_path;
static App start_app(const char *pkg, bool keep){
  AsbObserverFrame sp=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_OBSERVE|ASB_OBSERVER_FLAG_LEDGER,pkg);
  AsbObserverFrame st=make_frame(ASB_OBSERVER_EVENT_PROCESS_START,0,pkg);
  sockaddr_un a{}; a.sun_family=AF_UNIX; snprintf(a.sun_path,sizeof(a.sun_path),"%s",g_comp_path.c_str());
  int go[2]; assert(!pipe(go));
  pid_t pid=fork(); assert(pid>=0);
  if(pid==0){ close(go[1]);
    sp.pid=st.pid=getpid(); sp.process_start_ticks=st.process_start_ticks=process_start_ticks(sp.pid);
    int c=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
    if(c<0 || connect(c,reinterpret_cast<sockaddr*>(&a),sizeof(a))) _exit(2);
    if(!write_all(c,&sp,sizeof(sp))) _exit(3);
    if(keep){ if(!write_all(c,&st,sizeof(st))) _exit(4); } else close(c);
    char b; while(read(go[0],&b,1)<0 && errno==EINTR){}
    _exit(0); }
  close(go[0]); return App{pid,go[1]};
}
static void stop_app(const App &app){ char z=1; assert(write(app.go,&z,1)==1); close(app.go); int st=0; assert(waitpid(app.pid,&st,0)==app.pid && WIFEXITED(st) && WEXITSTATUS(st)==0); }
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
  // Cold-start lift only: a top-app regular app sends one frame and unloads. fix286: the frame
  // names the package for the companion's launch-class lookup (never stored, never sent on).
  put_policy("v=2\ngen=7\nobserver=0\nhints=0\nlaunch=1\nledger=0\n");
  int dl=g_dlclose; pre(); assert(g_connects==1 && g_dlclose==dl+1 && g_exempt==0);
  AsbObserverFrame f=take(); assert(f.kind==ASB_OBSERVER_EVENT_SPAWN && std::string(f.package)=="com.example.app");
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
  // dev46: the owner's compatibility exclusion covers even a package also present in the
  // allowlist, and its process suffix. No companion connection, ledger or launch frame is made.
  put_policy("v=2\ngen=81\nobserver=1\nhints=1\nlaunch=1\nledger=1\npkg=com.example.compat\nxpkg=com.example.compat\n");
  g_nice="com.example.compat"; top=1; int xc=g_connects, xd=g_dlclose; pre();
  assert(g_connects==xc && g_dlclose==xd+1);
  g_nice="com.example.compat:worker"; top=0; pre(); assert(g_connects==xc && g_dlclose==xd+2);
  // A full companion queue used to block the blocking send in preAppSpecialize forever. The
  // child alarm makes the old defect fail in two seconds instead of hanging the whole suite.
  put_policy("v=2\ngen=82\nobserver=0\nhints=0\nlaunch=1\nledger=0\n");
  g_nice="com.example.app"; top=1; g_fill_socket=true;
  pid_t full_child=fork(); assert(full_child>=0);
  if(full_child==0){ alarm(2); pre(); _exit(0); }
  int full_status=0; assert(waitpid(full_child,&full_status,0)==full_child);
  g_fill_socket=false;
  assert(WIFEXITED(full_status) && WEXITSTATUS(full_status)==0); // optional telemetry never stalls startup
  // Allowlisted process: one SPAWN, no exemptFd, socket EOF and an explicit unload request.
  // post-specialize is intentionally silent; the root companion's pidfd owns exit tracking.
  put_policy("v=2\ngen=9\nobserver=1\nhints=0\nlaunch=1\nledger=0\npkg=com.example.app\n");
  g_nice="com.example.app"; top=1; dl=g_dlclose; int ex0=g_exempt; pre();
  assert(g_exempt==ex0 && g_dlclose==dl+1);
  f=take(); assert(f.kind==ASB_OBSERVER_EVENT_SPAWN && (f.flags&ASB_OBSERVER_FLAG_LAUNCH) && (f.flags&ASB_OBSERVER_FLAG_OBSERVE));
  assert(std::string(f.package)=="com.example.app" && asb_observer_frame_valid(f));
  g_abi->postAppSpecialize(g_abi->impl,&args); assert(recv(g_peer,&extra,1,0)==0); close(g_peer); g_peer=-1;
  // Observer only (no ledger, no cold-start lift): exactly the same one-shot/unload lifecycle.
  put_policy("v=2\ngen=10\nobserver=1\nhints=0\nlaunch=0\nledger=0\npkg=com.example.app\n");
  top=0; dl=g_dlclose; pre(); assert(g_dlclose==dl+1);
  f=take(); assert(f.kind==ASB_OBSERVER_EVENT_SPAWN && f.flags==ASB_OBSERVER_FLAG_OBSERVE && asb_observer_frame_valid(f));
  g_abi->postAppSpecialize(g_abi->impl,&args); assert(recv(g_peer,&extra,1,0)==0);
  close(g_peer); g_peer=-1; top=1;
  put_policy("v=2\ngen=9\nobserver=1\nhints=0\nlaunch=1\nledger=0\npkg=com.example.app\n");
  // fix287: the root manager's unmount flag (KernelSU sets it for every app without root) is
  // counted in the one-shot record and never stops an allowlisted app from being observed.
  g_flags=zygisk::PROCESS_ON_DENYLIST; dl=g_dlclose; pre();
  assert(g_exempt==ex0 && g_dlclose==dl+1);
  f=take(); assert((f.flags&ASB_OBSERVER_FLAG_DENYLIST) && (f.flags&ASB_OBSERVER_FLAG_LAUNCH) && asb_observer_frame_valid(f));
  g_abi->postAppSpecialize(g_abi->impl,&args); assert(recv(g_peer,&extra,1,0)==0);
  close(g_peer); g_peer=-1; g_flags=0;
  // A protected name still starts with the plain, package-free launch record.
  g_nice="com.android.settings"; pre(); f=take(); assert(f.package[0]==0 && asb_observer_frame_valid(f)); close(g_peer); g_peer=-1;
  g_nice="com.example.app";
  // A malformed policy observes nothing.
  put_policy("v=2\nlaunch=1\ncap=1\n"); int c0=g_connects; pre(); assert(g_connects==c0);
  // Companion: a published screen-off state vetoes locally without a datagram and without
  // consuming the one-second launch budget. The next screen-on start must reach the governor;
  // only the following start inside that second is throttled. The ledger still keeps both sides.
  put_policy("v=2\ngen=11\nobserver=1\nhints=0\nlaunch=1\nledger=1\npkg=com.example.app\nxpkg=com.example.compat\n");
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=IDLE\nprofile=battery\nscreen=0\n"; }
  int gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); sockaddr_un ga{}; ga.sun_family=AF_UNIX;
  snprintf(ga.sun_path,sizeof(ga.sun_path),"%s",ASB_GOVERNOR_SOCKET); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  AsbObserverFrame l=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_LEDGER,"com.example.sync");
  companion_send(l);
  timeval no_ipc_tv{0,100000}; setsockopt(gfd,SOL_SOCKET,SO_RCVTIMEO,&no_ipc_tv,sizeof(no_ipc_tv));
  char no_ipc[64]{}; sockaddr_un no_ipc_src{}; socklen_t no_ipc_len=sizeof(no_ipc_src);
  assert(recvfrom(gfd,no_ipc,sizeof(no_ipc),0,reinterpret_cast<sockaddr*>(&no_ipc_src),&no_ipc_len)<0 &&
         (errno==EAGAIN || errno==EWOULDBLOCK)); // any datagram here is a regression
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=ACTIVE\nprofile=battery\nscreen=1\n"; }
  std::thread gt(governor,gfd,1);
  companion_send(l); gt.join();
  assert(gov_cmds.size()==1 && gov_cmds[0]=="zygisk-launch");
  l=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_LEDGER,"com.example.sync");
  companion_send(l); // inside one second after the real screen-on launch: throttled locally
  AsbObserverFrame spoof=l; spoof.pid=1234567; companion_send(spoof); // peer/PID mismatch
  AsbObserverFrame g=make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_LEDGER,"com.example.sync"); companion_send(g);
  // Companion-side enforcement closes the rolling-update and forged-frame paths as well: no
  // pidfd, ledger row, launch-class lookup, governor datagram or legacy PROCESS_START record.
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH|ASB_OBSERVER_FLAG_LEDGER|ASB_OBSERVER_FLAG_OBSERVE,"com.example.compat"));
  companion_send(make_frame(ASB_OBSERVER_EVENT_PROCESS_START,0,"com.example.compat"));
  assert(gov_cmds.size()==1);
  std::string s=state();
  assert(s.find("Z\texcluded_spawns\t2\n")!=std::string::npos);
  assert(s.find("com.example.compat")==std::string::npos);
  assert(s.find("Z\tlaunch_accepted\t1\n")!=std::string::npos);
  assert(s.find("Z\tlaunch_vetoed\t1\n")!=std::string::npos);
  assert(s.find("Z\tlaunch_screen_off\t1\n")!=std::string::npos);
  assert(s.find("Z\tlaunch_throttled\t1\n")!=std::string::npos);
  assert(s.find("L\tcom.example.sync\t1\t3\t3\t1\n")!=std::string::npos);
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
  // fix286: launch classes. A slow app's cold start asks for "zygisk-launch-long", a fast one's
  // for "zygisk-launch-short", anything else for the plain opcode - never a package. A governor
  // that does not answer a class opcode gets the plain one. A broken classes file = all normal.
  put_policy("v=2\ngen=13\nobserver=0\nhints=0\nlaunch=1\nledger=0\n");
  { std::ofstream c(ASB_ZYGISK_CLASSES_ABS); c<<"v=1\nslow=com.example.heavy\nfast=com.example.light\n"; }
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=ACTIVE\nprofile=battery\nscreen=1\n"; }
  gov_cmds.clear();
  gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  std::thread ct(governor,gfd,3);
  const uint32_t lf=ASB_OBSERVER_FLAG_TOP_APP|ASB_OBSERVER_FLAG_LAUNCH;
  std::this_thread::sleep_for(std::chrono::milliseconds(1050)); // outside the previous launch's 1 s gap
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,lf,"com.example.heavy"));
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,lf,"com.example.light"));
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,lf,"com.example.plain"));
  ct.join();
  assert(gov_cmds.size()==3 && gov_cmds[0]=="zygisk-launch-long" && gov_cmds[1]=="zygisk-launch-short" && gov_cmds[2]=="zygisk-launch");
  s=state();
  assert(s.find("Z\tlaunch_long\t1\n")!=std::string::npos && s.find("Z\tlaunch_short\t1\n")!=std::string::npos);
  assert(s.find("Z\tclasses_loaded\t1\n")!=std::string::npos && s.find("Z\tclasses_slow\t1\n")!=std::string::npos);
  assert(s.find("Z\tclasses_reads\t1\n")!=std::string::npos); // re-read only when the file changes
  assert(s.find("com.example.plain")==std::string::npos && s.find("com.example.heavy")==std::string::npos); // not stored
  close(gfd);
  // An older governor ignores the class opcode: one 100 ms timeout, then the plain request.
  gov_cmds.clear();
  gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  std::thread ot([&]{ for(int i=0;i<2;i++){ char b[64]{}; sockaddr_un src{}; socklen_t l=sizeof(src);
    timeval tv{2,0}; setsockopt(gfd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
    ssize_t r=recvfrom(gfd,b,sizeof(b)-1,0,reinterpret_cast<sockaddr*>(&src),&l); if(r<=0) return; gov_cmds.push_back(b);
    if (std::strcmp(b,"zygisk-launch")==0) sendto(gfd,"ok",2,0,reinterpret_cast<sockaddr*>(&src),l);} });
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,lf,"com.example.heavy"));
  ot.join();
  assert(gov_cmds.size()==2 && gov_cmds[0]=="zygisk-launch-long" && gov_cmds[1]=="zygisk-launch");
  s=state(); assert(s.find("Z\tlaunch_class_fallback\t1\n")!=std::string::npos);
  close(gfd);
  { std::ofstream c(ASB_ZYGISK_CLASSES_ABS); c<<"v=1\nslow=com.android.systemui\n"; }
  gov_cmds.clear();
  gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  std::thread bt(governor,gfd,1);
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,lf,"com.example.heavy"));
  bt.join(); assert(gov_cmds.size()==1 && gov_cmds[0]=="zygisk-launch");
  s=state(); assert(s.find("Z\tclasses_loaded\t0\n")!=std::string::npos);
  // The denylist record is counted, not acted on.
  companion_send(make_frame(ASB_OBSERVER_EVENT_SPAWN,ASB_OBSERVER_FLAG_LEDGER|ASB_OBSERVER_FLAG_DENYLIST,"com.example.bank"));
  s=state(); assert(s.find("Z\tdenylist_spawns\t1\n")!=std::string::npos);
  close(gfd); unlink(ASB_ZYGISK_CLASSES_ABS);
  // fix286: with the screen off (as the governor published it) a lifecycle refresh is not
  // sent - the governor would only veto it after waking up; with the screen on it is.
  put_policy("v=2\ngen=14\nobserver=1\nhints=1\nlaunch=0\nledger=0\npkg=com.example.hint\n");
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=IDLE\nprofile=battery\nscreen=0\n"; }
  gov_cmds.clear();
  gfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0); unlink(ga.sun_path);
  assert(bind(gfd,reinterpret_cast<sockaddr*>(&ga),sizeof(ga))==0);
  companion_send(make_frame(ASB_OBSERVER_EVENT_PROCESS_START,0,"com.example.hint"));
  s=state(); assert(s.find("Z\thints_screen_off\t2\n")!=std::string::npos); // start and exit
  { std::ofstream st(ASB_GOVERNOR_STATE); st<<"state=ACTIVE\nprofile=battery\nscreen=1\n"; }
  std::thread ht(governor,gfd,1);
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  companion_send(make_frame(ASB_OBSERVER_EVENT_PROCESS_START,0,"com.example.hint"));
  ht.join(); assert(gov_cmds.size()==1 && gov_cmds[0]=="zygisk-refresh");
  s=state(); assert(s.find("Z\thints_screen_off\t2\n")!=std::string::npos);
  close(gfd);
  // fix339: exit tracking without the app's help. An app whose socket is gone right after SPAWN
  // is still recorded, watched through a process fd, and its exit is counted once it dies. An
  // app that kept its socket is confirmed by its START and its exit is still counted once, not
  // twice (socket EOF and process fd). A rate-limited start opens no watch.
  put_policy("v=2\ngen=15\nobserver=1\nhints=0\nlaunch=0\nledger=1\npkg=com.example.watch\npkg=com.example.keep\n");
  g_comp_path=std::string(ASB_ZYGISK_RUN_DIR)+"/comp.sock"; unlink(g_comp_path.c_str());
  int lfd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0); sockaddr_un la{}; la.sun_family=AF_UNIX;
  snprintf(la.sun_path,sizeof(la.sun_path),"%s",g_comp_path.c_str());
  assert(bind(lfd,reinterpret_cast<sockaddr*>(&la),sizeof(la))==0 && listen(lfd,4)==0);
  s=state(); const long ev0=zval(s,"events_total"), ret0=zval(s,"observe_retained"), dup0=zval(s,"events_dropped_duplicate"), peer0=zval(s,"exits_peer");
  assert(zval(s,"observe_pidfd")==0 && zval(s,"observe_watching")==0 && zval(s,"exits_pidfd")==0);
  App a=start_app("com.example.watch",false);
  { int c=accept(lfd,nullptr,nullptr); assert(c>=0); std::thread t(zygisk_companion_entry,c); t.join(); }
  s=state(); assert(has_proc(s,a.pid) && zval(s,"observe_requested")==1 && zval(s,"observe_pidfd")==1);
  assert(zval(s,"observe_watching")==1 && zval(s,"observe_retained")==ret0 && zval(s,"events_total")==ev0+1 && zval(s,"exits_peer")==peer0);
  stop_app(a);
  assert(wait_state([](const std::string &x){ return zval(x,"exits_pidfd")==1 && zval(x,"observe_watching")==0; }));
  s=state(); assert(!has_proc(s,a.pid) && zval(s,"events_total")==ev0+2);
  App b=start_app("com.example.keep",true);
  int bc=accept(lfd,nullptr,nullptr); assert(bc>=0); std::thread bt2(zygisk_companion_entry,bc);
  assert(wait_state([](const std::string &x){ return zval(x,"observe_pidfd")==2; }));
  for(int i=0;i<400 && zval(state(),"observe_retained")!=ret0+1;i++) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  s=state(); assert(has_proc(s,b.pid) && zval(s,"observe_retained")==ret0+1 && zval(s,"events_total")==ev0+3);
  // V66 dev16: two sibling processes inside one second of b are watched; a fourth start is
  // rate-limited and opens no watch.
  const long rl0=zval(s,"events_dropped_rate_limit");
  App c=start_app("com.example.keep",false);
  { int cc=accept(lfd,nullptr,nullptr); assert(cc>=0); std::thread t(zygisk_companion_entry,cc); t.join(); }
  s=state(); assert(has_proc(s,c.pid) && zval(s,"observe_requested")==3 && zval(s,"observe_watching")==2);
  App d=start_app("com.example.keep",false);
  { int cc=accept(lfd,nullptr,nullptr); assert(cc>=0); std::thread t(zygisk_companion_entry,cc); t.join(); }
  s=state(); assert(has_proc(s,d.pid) && zval(s,"observe_requested")==4 && zval(s,"observe_watching")==3);
  App e=start_app("com.example.keep",false);
  { int cc=accept(lfd,nullptr,nullptr); assert(cc>=0); std::thread t(zygisk_companion_entry,cc); t.join(); }
  s=state(); assert(!has_proc(s,e.pid) && zval(s,"observe_requested")==5 && zval(s,"observe_watching")==3 && zval(s,"events_dropped_rate_limit")==rl0+1);
  stop_app(e); stop_app(d); stop_app(c);
  stop_app(b); bt2.join();
  assert(wait_state([](const std::string &x){ return zval(x,"observe_watching")==0; }));
  s=state(); assert(!has_proc(s,b.pid) && zval(s,"events_total")==ev0+8 && zval(s,"events_dropped_duplicate")==dup0);
  assert(zval(s,"exits_pidfd")+zval(s,"exits_peer")-peer0==4 && zval(s,"observe_untracked")==0);
  close(lfd); unlink(g_comp_path.c_str());
  // No policy: the companion ignores late one-shot frames instead of acting on stale state.
  unlink(ASB_ZYGISK_POLICY_ABS); companion_send(g); s=state();
  assert(s.find("Z\tevents_policy_absent\t1\n")!=std::string::npos);
  std::cout<<"hot path ok\n";
  return 0;
}
CPP
  g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-missing-field-initializers -pthread \
    -I"$T/inc" -I"$ROOT/src/zygisk" -DASB_ABI_TAG='"arm64-v8a"' \
    -DASB_ZYGISK_POLICY_ABS="\"$T/policy\"" -DASB_ZYGISK_RUN_DIR="\"$T/run\"" -DASB_ZYGISK_CLASSES_ABS="\"$T/classes\"" \
    -DASB_GOVERNOR_STATE="\"$T/gov/state\"" -DASB_GOVERNOR_SOCKET="\"$T/gov/ctl.sock\"" \
    -DASB_GOVERNOR_CLIENT_DIR="\"$T/gov\"" "$T/hot.cpp" -o "$T/hot" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail 'host harness build'; }
  out="$("$T/hot")" || fail "runtime: $out"
  printf '%s\n' "$out" | grep -qx 'hot path ok' || fail "$out"
  if grep -q 'api_->exemptFd\|socket_ = sock\|package_ = base' "$ROOT/src/zygisk/asb_observer.cpp"; then
    fail 'app-side retained socket state returned'
  fi
  ns="$(printf '%s\n' "$out" | sed -n 's/^dormant_ns=//p')"
  echo "PASS observer hot path: dormant ${ns} ns/fork on this host, uid/child prefilter, owner exclusions before companion IPC, full-socket nonblocking spawn, cold start with class lookup, unmount flag counted and never silencing the allowlist, ledger, allowlisted/observer-only one-shot SPAWN with socket close and DLCLOSE and no exemptFd, legacy START compatibility, companion exit by process fd or legacy socket counted once, companion launch/class opcodes/old-governor fallback/screen-off launch veto without IPC or budget use/screen-off refresh skipped/throttle/spoof/ledger/no-policy"
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

t_zygisk_auto_setup_runtime() (
  # fix284: one-tap automation is bounded to observation, the existing evidence guard and ART.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL observer automatic setup: $*" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/mod/config" "$T/mod/runtime" "$T/mod/zygisk" "$T/state/zygisk_observer" "$T/run" "$T/bin"
  cp "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped" "$T/mod/config/"
  cp "$ROOT/runtime/asb_config_safe.sh" "$ROOT/runtime/asb_zygisk_guard.sh" "$ROOT/runtime/asb_zygisk_aot.sh" "$T/mod/runtime/"
  printf 'com.example.manual\norg.example.keep\n' > "$T/state/zygisk_observer/packages.list"
  : > "$T/packages"
  i=0; while [ $i -lt 70 ]; do printf 'com.example.p%02d\n' "$i" >> "$T/packages"; i=$((i+1)); done
  printf 'com.android.systemui\ncom.topjohnwu.magisk\n' >> "$T/packages"
  cat > "$T/bin/pm" <<'SH'
#!/bin/sh
if [ "$1 $2 $3" = "list packages -3" ]; then sed 's/^/package:/' "$PKG_FILE"; fi
SH
  cat > "$T/bin/logcat" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$T/bin/pm" "$T/bin/logcat"
  run() { PATH="$T/bin:$PATH" PKG_FILE="$T/packages" ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/state/zygisk_observer" ASB_ZYGISK_RUN_DIR="$T/run" sh "$ROOT/runtime/asb_zygisk.sh" "$@"; }
  run safe-mode on
  run auto-enable > "$T/safe.out" 2>/dev/null && fail 'automatic setup cleared or bypassed Safe mode'
  grep -qx 'result=safe_mode' "$T/safe.out" || fail 'Safe mode refusal not explicit'
  [ ! -e "$T/state/zygisk_guard" ] && [ ! -e "$T/state/zygisk_aot" ] || fail 'Safe-mode refusal enabled features'
  run safe-mode off
  printf 'b test\ncom.example.p69 900 0\ncom.example.p05 800 0\n' > "$T/state/zygisk_aot_count"
  run auto-enable > "$T/enable.out" || fail "automatic enable failed: $(cat "$T/enable.out")"
  grep -qx 'result=enabled' "$T/enable.out" && grep -qx 'packages=64' "$T/enable.out" || fail "wrong enable result: $(cat "$T/enable.out")"
  [ "$(run list | wc -l)" = 64 ] || fail 'automatic list exceeded or missed the 64-package bound'
  run list | grep -qx 'com.example.p69' || fail 'usage history did not prioritise frequently opened apps'
  run list | grep -qx 'com.example.p05' || fail 'second usage-ranked app missing'
  run list | grep -qE 'com\.android\.systemui|com\.topjohnwu\.magisk' && fail 'protected/system package entered automatic list'
  grep -qx 'zygisk_enabled=1' "$T/mod/config/governor.conf" && grep -qx 'zygisk_ledger=1' "$T/mod/config/governor.conf" || fail 'Observe did not enable observer + ledger'
  grep -qx 'zygisk_hints=0' "$T/mod/config/governor.conf" && grep -qx 'zygisk_launch=0' "$T/mod/config/governor.conf" || fail 'Observe enabled launch policy'
  [ ! -e "$T/state/zygisk_guard" ] && [ ! -e "$T/state/zygisk_aot" ] || fail 'Observe enabled AppOps guard or ART'
  grep -qx 'mode=observe' "$T/state/zygisk_observer/auto" || fail 'Observe marker absent'
  grep -qx 'observer=1' "$T/mod/zygisk/policy" && grep -qx 'ledger=1' "$T/mod/zygisk/policy" || fail 'automatic policy incomplete'
  run status | grep -qx 'automatic=on' && run status | grep -qx 'automatic_profile=observe' || fail 'status does not expose automatic ownership/profile'
  # Unchanged refresh does not advance policy generation or rewrite the policy.
  before="$(sha256sum "$T/mod/zygisk/policy")"; sleep 1
  run auto-refresh > "$T/refresh.out"
  after="$(sha256sum "$T/mod/zygisk/policy")"; [ "$before" = "$after" ] || fail 'unchanged automatic refresh rewrote policy'
  # A newly installed, frequently opened app joins without a new worker; a package-manager
  # outage keeps the last good list instead of proving that no apps exist.
  printf 'com.example.new 1000 0\n' >> "$T/state/zygisk_aot_count"
  printf 'com.example.new\n' >> "$T/packages"
  run auto-refresh >/dev/null; run list | grep -qx 'com.example.new' || fail 'new user app not added on refresh'
  : > "$T/packages"; run auto-refresh >/dev/null
  run list | grep -qx 'com.example.new' || fail 'empty Package Manager response erased the last good list'
  run auto-enable launch > "$T/launch.out" || fail 'Launch profile failed'
  grep -qx 'zygisk_launch=1' "$T/mod/config/governor.conf" && grep -qx 'zygisk_hints=0' "$T/mod/config/governor.conf" || fail "Launch profile has wrong observer switches: $(cat "$T/launch.out") $(cat "$T/state/zygisk_observer/auto") $(grep '^zygisk_' "$T/mod/config/governor.conf" | tr '\n' ' ')"
  [ ! -e "$T/state/zygisk_guard" ] && [ ! -e "$T/state/zygisk_aot" ] || fail 'Launch enabled AppOps guard or ART'
  run auto-enable battery >/dev/null || fail 'Battery profile failed'
  grep -qx wakers "$T/state/zygisk_guard" || fail 'Battery did not enable evidence guard'
  [ ! -e "$T/state/zygisk_aot" ] || fail 'Battery implicitly enabled ART'
  grep -qx 'zygisk_launch=0' "$T/mod/config/governor.conf" || fail 'Battery left launch assist enabled'
  run auto-enable auto > "$T/auto.out" || fail 'Auto profile failed'
  for kv in zygisk_enabled=1 zygisk_hints=1 zygisk_launch=1 zygisk_ledger=1; do grep -qx "$kv" "$T/mod/config/governor.conf" || fail "Auto has wrong switch set: $kv"; done
  grep -qx wakers "$T/state/zygisk_guard" && grep -qx 'mode=auto' "$T/state/zygisk_observer/auto" || fail 'Auto did not retain evidence guard and marker'
  [ ! -e "$T/state/zygisk_aot" ] || fail 'Auto implicitly enabled ART'
  run status | grep -qx 'automatic_profile=auto' || fail 'Auto profile absent from status'
  run auto-enable observe >/dev/null || fail 'switch back to Observe failed'
  [ ! -e "$T/state/zygisk_guard" ] && [ ! -e "$T/state/zygisk_aot" ] || fail 'Observe retained automatic guard/ART'
  run auto-disable > "$T/disable.out" || fail 'automatic disable failed'
  grep -qx 'result=disabled' "$T/disable.out" || fail 'disable result missing'
  printf 'com.example.manual\norg.example.keep\n' > "$T/want"
  cmp -s "$T/want" "$T/state/zygisk_observer/packages.list" || fail 'previous manual list was not restored exactly'
  for k in zygisk_enabled zygisk_hints zygisk_launch zygisk_ledger; do grep -qx "$k=0" "$T/mod/config/governor.conf" || fail "$k left enabled after auto disable"; done
  [ ! -e "$T/state/zygisk_guard" ] && [ ! -e "$T/state/zygisk_aot" ] && [ ! -e "$T/state/zygisk_observer/auto" ] || fail 'automatic flags survived disable'
  [ ! -e "$T/mod/zygisk/policy" ] || fail 'automatic disable left an active policy'
  grep -q 'zygisk_observer/auto' "$ROOT/service.sh" && grep -q 'auto-refresh' "$ROOT/service.sh" || fail 'existing service refresh hook missing'
  grep -q 'zygisk_observer/packages.before_auto' "$ROOT/uninstall.sh" || fail 'uninstall cleanup missing'
  ! grep -qE 'auto.*(appops|RUN_ANY_IN_BACKGROUND)|appops.*auto' "$ROOT/runtime/asb_zygisk.sh" || fail 'automatic package selection became an AppOps writer'
  sed -i 's/^zygisk_enabled=.*/zygisk_enabled=1/; s/^zygisk_hints=.*/zygisk_hints=1/; s/^zygisk_launch=.*/zygisk_launch=0/; s/^zygisk_ledger=.*/zygisk_ledger=0/' "$T/mod/config/governor.conf"
  printf 'loops\n' > "$T/state/zygisk_guard"; : > "$T/state/zygisk_aot"
  run auto-enable launch >/dev/null || fail 'automatic enable over manual state failed'
  run auto-disable >/dev/null || fail 'restore over manual state failed'
  for kv in zygisk_enabled=1 zygisk_hints=1 zygisk_launch=0 zygisk_ledger=0; do grep -qx "$kv" "$T/mod/config/governor.conf" || fail "previous config not restored: $kv"; done
  grep -qx loops "$T/state/zygisk_guard" && [ -f "$T/state/zygisk_aot" ] || fail 'previous manual guard/ART state not restored'
  echo 'PASS observer automatic setup: compatible Observe/Launch/Battery plus unified Auto, no implicit ART, 64 bound, safe-mode refusal, unchanged refresh and exact pre-automatic state restore'
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
  run() { ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/state" ASB_ZYGISK_AOT_EXCLUDE="$T/state/zygisk_aot_exclude" sh "$ROOT/runtime/asb_zygisk.sh" "$@"; }
  P="$T/mod/zygisk/policy"
  run sync | grep -qx 'policy=absent' || fail 'disabled master wrote a policy'
  [ ! -e "$P" ] || fail 'policy exists while disabled'
  run enable
  [ ! -e "$P" ] || fail 'enabled with nothing selected still wrote a policy'
  sed -i 's/^zygisk_launch=0/zygisk_launch=1/' "$T/mod/config/governor.conf"
  run sync | grep -q '^policy=written .*launch=1 ledger=0' || fail 'cold-start policy not written'
  grep -qx 'v=2' "$P" && grep -qx 'launch=1' "$P" && grep -qx 'observer=0' "$P" || fail "policy content: $(cat "$P")"
  [ "$(stat -c %a "$P")" = 600 ] || fail "policy is not root-only: $(stat -c %a "$P")"
  ! grep -q '^pkg=' "$P" || fail 'launch-only policy names packages'
  run set-packages com.example.app org.example.game
  grep -qx 'pkg=com.example.app' "$P" && grep -qx 'pkg=org.example.game' "$P" && grep -qx 'observer=1' "$P" \
    || fail 'allowlist change did not reach the policy'
  sed -i 's/^zygisk_ledger=0/zygisk_ledger=1/' "$T/mod/config/governor.conf"
  printf 'com.example.compat\n' > "$T/state/zygisk_aot_exclude"; run sync >/dev/null
  grep -qx 'ledger=1' "$P" && grep -qx 'xpkg=com.example.compat' "$P" || fail 'ledger or owner exclusion did not reach the policy'
  run set-packages com.android.shellx >/dev/null 2>&1 && fail 'a name the native module denies was accepted'
  if command -v g++ >/dev/null 2>&1; then
    cat > "$T/parse.cpp" <<'CPP'
#include "asb_observer_protocol.h"
#include <fstream>
#include <iostream>
int main(int, char **argv) {
  std::ifstream f(argv[1]); std::string s((std::istreambuf_iterator<char>(f)), {});
  AsbObserverPolicy p; if (!asb_observer_policy_parse(s.data(), s.size(), p) || !p.active()) return 1;
  if (!p.excluded("com.example.compat") || p.selected("com.example.compat")) return 2;
  std::cout << p.observer << p.launch << p.ledger << ' ' << p.packages << ' ' << p.excluded_packages << "\n"; return 0;
}
CPP
    g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/parse.cpp" -o "$T/parse" || fail 'parser build'
    [ "$("$T/parse" "$P")" = '111 2 1' ] || fail "native parser rejected the shell policy: $(cat "$P")"
  fi
  run safe-mode on
  [ ! -e "$P" ] || fail 'safe mode left the policy for new processes'
  run safe-mode off
  [ ! -e "$P" ] || fail 'clearing safe mode silently re-enabled injection'
  run enable; [ -s "$P" ] || fail 're-enable did not restore the policy'
  mkdir -p "$T/mod/runtime"
  cat > "$T/mod/runtime/asb_zygisk_link.sh" <<'SH'
#!/bin/sh
printf 'v=1\nslow=com.example.partial\n' > "$ASB_ZYGISK_CLASSES"
exit 1
SH
  printf 'v=1\nslow=com.example.previous\n' > "$T/mod/zygisk/classes"
  cp "$P" "$T/policy.good"; cp "$T/mod/zygisk/classes" "$T/classes.good"
  run sync > "$T/rollback.out" 2>/dev/null && fail 'classes writer failure was masked'
  grep -qx 'policy=rolled_back reason=classes_write_failed' "$T/rollback.out" || fail "rollback result: $(cat "$T/rollback.out")"
  cmp -s "$P" "$T/policy.good" && cmp -s "$T/mod/zygisk/classes" "$T/classes.good" || fail 'policy/classes pair was not restored exactly'
  [ ! -e "$P.rollback.tmp" ] && [ ! -e "$T/mod/zygisk/classes.rollback.tmp" ] || fail 'rollback temporary files survived'
  rm -f "$T/mod/runtime/asb_zygisk_link.sh"
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
  printf 'Z\tlaunch_long\t4\nZ\tlaunch_short\t2\nZ\tlaunch_class_fallback\t1\nZ\tclasses_loaded\t1\nZ\tclasses_slow\t5\nZ\tclasses_fast\t3\nZ\tdenylist_spawns\t6\nZ\texcluded_spawns\t4\nZ\tlaunch_long\tx\nZ\thints_screen_off\t9\nZ\tlaunch_screen_off\t1\n' >> "$T/run/state.arm64-v8a.tsv"
  printf 'Z\tlaunch_long\t1\nZ\tdenylist_spawns\t2\nZ\texcluded_spawns\t3\nZ\tlaunch_screen_off\t1\n' >> "$T/run/state.armeabi-v7a.tsv"
  mkdir -p "$T/run_old"; cp "$T/run/state.arm64-v8a.tsv" "$T/run_old/"
  printf 'Z\tobserve_requested\t5\nZ\tobserve_retained\t0\nZ\tobserve_pidfd\t4\nZ\tobserve_untracked\t1\nZ\tobserve_watching\t2\nZ\texits_pidfd\t2\nZ\texits_peer\t0\n' >> "$T/run/state.arm64-v8a.tsv"
  printf 'Z\tobserve_requested\t1\nZ\tobserve_pidfd\t1\nZ\tobserve_watching\tx\n' >> "$T/run/state.armeabi-v7a.tsv"
  . "$ROOT/runtime/asb_zygisk_info.sh"; _asb_zygisk_info
  want() { grep -Fqx "zygisk_observer	$1	$2" "$T/out" || fail "missing $1=$2: $(cat "$T/out")"; }
  want launch_long 5; want launch_short 2; want launch_class_fallback 1; want launch_classes_loaded 1
  want launch_classes 'slow 5, fast 3'; want denylist_spawns 8; want excluded_spawns 7; want hints_screen_off 9; want launch_screen_off 2
  want enabled 1; want enabled_packages 1; want loaded_processes 1; want events_total 10; want link_state connected
  want auto_mode 0
  want events_dropped_rate_limit 1; want ipc_cpu_ms 3; want ipc_wakeups 12; want memory_kb 2222
  want state_freshness current; want crash_count unknown; want anr_count unknown; want policy_hints 7
  want lifecycle_hints 1; want hints_accepted 4; want hints_vetoed 1; want hints_unavailable 1; want hints_throttled 3
  want launch_hints 1; want spawn_ledger 1; want policy_generation 42; want policy_seen_generation 42
  want spawn_events 30; want launch_events 9; want launch_accepted 7; want launch_vetoed 2; want launch_throttled 1
  want ledger_events 21; want ledger_top_screen_off 'com.example.sync 17/3, com.example.mail 2/5'
  want ledger_restart_loops 'com.example.sync 9/5min'
  # fix339: exit tracking per ABI is summed; a companion built before it reads as unknown, not as
  # zero tracked processes.
  want observe_requested 6; want observe_retained 0; want observe_pidfd 5; want observe_untracked 1
  want observe_watching 2; want exits_pidfd 2; want exits_peer 0
  : > "$T/out.old"
  ( _emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/out.old"; }; ASB_ZYGISK_RUN_DIR="$T/run_old"; _asb_zygisk_info )
  grep -Fqx "$(printf 'zygisk_observer\tobserve_requested\tunknown')" "$T/out.old" && ! grep -q 'observe_pidfd' "$T/out.old" \
    || fail "an older companion's state reads as tracked counters: $(grep observe "$T/out.old")"
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
  # fix287: link-status read its state from /data/asb instead of /data/adb/asb (the WebUI's
  # Zygisk page, header and Actions), so automatic setup, the observed apps and safe mode
  # always read "off/0" there. Without any directory override it must find /data/adb/asb.
  grep -q 'DATA="${ASB_ZYGISK_DATA:-/data/adb}"' "$ROOT/runtime/asb_zygisk.sh" || fail 'link-status data root is not /data/adb'
  grep -q 'DATA="${ASB_DEVINFO_DATA:-/data/adb}"' "$ROOT/tools/asb_device_info.sh" || fail 'collectors disagree on the data root'
  mkdir -p "$T/adb/asb/zygisk_observer"
  printf 'version=1\nupdated=5\n' > "$T/adb/asb/zygisk_observer/auto"
  printf 'com.example.app\norg.example.two\n' > "$T/adb/asb/zygisk_observer/packages.list"
  env -u ASB_ZYGISK_DIR ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/adb" \
    sh "$ROOT/runtime/asb_zygisk.sh" link-status > "$T/link2.out"
  grep -Fqx "$(printf 'D\tzygisk_observer\tauto_mode\t1')" "$T/link2.out" || fail "automatic setup not seen by link-status: $(grep auto_mode "$T/link2.out")"
  grep -Fqx "$(printf 'D\tzygisk_observer\tauto_profile\tlegacy')" "$T/link2.out" || fail 'legacy automatic profile was not reported honestly'
  grep -Fqx "$(printf 'D\tzygisk_observer\tenabled_packages\t2')" "$T/link2.out" || fail 'observed apps not seen by link-status'
  printf 'version=2\nmode=auto\nupdated=6\n' > "$T/adb/asb/zygisk_observer/auto"
  env -u ASB_ZYGISK_DIR ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/adb" \
    sh "$ROOT/runtime/asb_zygisk.sh" link-status | grep -Fqx "$(printf 'D\tzygisk_observer\tauto_profile\tauto')" || fail 'Auto automatic profile was not exposed by diagnostics'
  : > "$T/adb/asb/zygisk_observer/disable"
  env -u ASB_ZYGISK_DIR ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/adb" \
    sh "$ROOT/runtime/asb_zygisk.sh" link-status | grep -Fqx "$(printf 'D\tzygisk_observer\tsafe_mode\ton')" || fail 'safe mode not seen by link-status'
  {
    sed -n '/^T_ZY_HEAD=/,/^T_ZY_UNKNOWN=/p' "$ROOT/action.sh"
    printf '_f() { _sfmt="$1"; shift; printf "$_sfmt\\n" "$@"; }\n'
    sed -n '/# Compact, current Zygisk evidence/,/^echo "  ⚙️  \${H_SYSTEM}"$/p' "$ROOT/action.sh" | sed '$d'
  } > "$T/action.zy.sh"
  MODDIR="$T/mod" ASB_ZYGISK_MODDIR="$T/mod" ASB_ZYGISK_DIR="$T/data/asb/zygisk_observer" \
    ASB_ZYGISK_RUN_DIR="$T/run" ASB_ZYGISK_PROC="$T/proc" ASB_ZYGISK_DATA="$T/data" \
    sh "$T/action.zy.sh" > "$T/action.out" || fail 'Actions Zygisk block failed'
  grep -q 'Zygisk · ASB link: Connected' "$T/action.out" || fail "Actions verdict absent: $(cat "$T/action.out")"
  grep -q 'live processes 1 · events 10 · spawn 30' "$T/action.out" || fail 'Actions evidence counters absent'
  grep -q 'generation 42 / acknowledged 42' "$T/action.out" || fail 'Actions policy acknowledgement absent'
  grep -q 'not pure ASB cost' "$T/action.out" || fail 'Actions RSS basis is not honest'
  awk '/^echo "  🌙  \${H_SLEEP}"/ { s=NR } /T_ZY_HEAD.*_zy_label/ { z=NR } /^echo "  ⚙️  \${H_SYSTEM}"/ { y=NR } END { if (!(s && z && y && s < z && z < y)) exit 1 }' "$ROOT/action.sh" || fail 'Actions Zygisk block is not between Sleep and System'
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
  want loaded_processes 0; want state_freshness current; want link_state confirmed; want state_age_clock file_mtime
  # fix285: a companion writing only CLOCK_MONOTONIC falls behind /proc/uptime by every second
  # of deep sleep. A night of suspend must not turn a file written just now into "stale".
  printf '20000.0 0.0\n' > "$T/proc/uptime"
  : > "$T/out"; _asb_zygisk_info; want state_freshness current; want link_state confirmed
  # Pin both sides of the file-mtime calculation. Under the eight-worker CI queue a slow
  # scheduling slice otherwise turns this exact 600 s fixture into a flaky 601/602 s result.
  _zi_fixture_now="$(date +%s)"
  touch -d "@$(( _zi_fixture_now - 600 ))" "$T/run/state.arm64-v8a.tsv" "$T/run/state.armeabi-v7a.tsv"
  : > "$T/out"; ASB_ZYGISK_NOW_S="$_zi_fixture_now" _asb_zygisk_info; unset ASB_ZYGISK_NOW_S
  want state_freshness stale_over_5_minutes; want link_state quiet; want state_age_ms 600000
  sed -i 's/^gen=42$/gen=43/' "$T/mod/zygisk/policy"
  : > "$T/out"; _asb_zygisk_info; want state_freshness stale_over_5_minutes; want link_state stale
  sed -i 's/^gen=43$/gen=42/' "$T/mod/zygisk/policy"
  # A rebuilt companion also writes CLOCK_BOOTTIME; that is compared with /proc/uptime directly.
  printf 'Z\tupdated_boottime_ms\t19990000\n' >> "$T/run/state.arm64-v8a.tsv"
  touch -d "@$(( $(date +%s) - 3600 ))" "$T/run/state.arm64-v8a.tsv" "$T/run/state.armeabi-v7a.tsv"
  : > "$T/out"; _asb_zygisk_info; want state_freshness current; want state_age_ms 10000; want state_age_clock boottime
  printf '21000.0 0.0\n' > "$T/proc/uptime"
  : > "$T/out"; _asb_zygisk_info; want state_freshness stale_over_5_minutes; want state_age_ms 1010000; want link_state quiet
  echo 'PASS observer diagnostics: live PID/start-ticks validation, current RSS, counters, stale TTL on suspend-aware clocks and honest unknowns'
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
function mk(tag){const e={tagName:tag,className:'',children:[],style:{},disabled:false,value:'',attrs:{},setAttribute(k,v){e.attrs[k]=String(v);},getAttribute(k){return e.attrs[k];},classList:{add(...cs){e.className=(e.className+' '+cs.join(' ')).trim();},remove(...cs){e.className=e.className.split(/\s+/).filter(c=>c&&!cs.includes(c)).join(' ');}},appendChild(c){e.children.push(c);c.parentNode=e;return c;},querySelector(sel){const c=sel.slice(1);return find(e,c);},replaceChild(n,o){const i=e.children.indexOf(o);if(i>=0){e.children[i]=n;n.parentNode=e;}return o;}};Object.defineProperty(e,'textContent',{get(){return e._text||''},set(v){e._text=String(v);e.children=[];}});return e;}
const hosts=Array.from({length:5},()=>mk('div'));
const document={createElement:mk,querySelectorAll(sel){if(sel==='.hdr-info')return hosts;if(sel==='.zygisk-header-link')return hosts.map(h=>find(h,'zygisk-header-link')).filter(Boolean);return [];}};
function _el(){return null;} function openZygiskPage(){} function shQuote(s){return "'"+s+"'";} function dozePkgOk(s){return /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/.test(s||'');}
function logReportSec(t,icon){const e=mk('div');e.className='lgr-sec';if(icon)e.setAttribute('data-zygisk-icon',icon);const h=mk('div');h.textContent=t;e.appendChild(h);return e;}
function zygiskButtonIcon(btn){return btn;}
let _zyGuard={enabled:true,level:'wakers'},_zyAot={enabled:true}; function zygiskGuardParse(s){return {enabled:/^enabled=1$/m.test(s),level:(/^level=(.+)$/m.exec(s)||[])[1]||'off'};} function zygiskAotParse(s){return {enabled:/^enabled=1$/m.test(s)};}
function uiSound(){} function haptic(){} let pageRenders=0; function zygiskPageRender(){pageRenders++;} let _zygiskOpen=true; let _cfgVals={}; let _cfgLoadSig='x';
const CFG_ITEMS=[
 {key:'zygisk_enabled',type:'bool',def:'0',name:'ASB Zygisk'},
 {key:'zygisk_hints',type:'bool',def:'0',name:'Zygisk Lifecycle Refresh'},
 {key:'zygisk_launch',type:'bool',def:'0',name:'Zygisk Cold-Start Lift'},
 {key:'zygisk_ledger',type:'bool',def:'0',name:'Zygisk Process-Start Ledger'}
];
let cfgWrites=[],pageLoads=0,paintYields=0;
async function cfgSet(key,val,ctl){cfgWrites.push({key,val:String(val),busy:!!(ctl&&ctl.className.includes('busy'))});_cfgVals[key]=String(val);}
async function zygiskPageLoad(){pageLoads++;}
function cfgRenderRow(list,it){const cur=_cfgVals[it.key]===undefined?it.def:_cfgVals[it.key];const row=mk('div');row.className='cfg-row';row.setAttribute('data-key',it.key);const sw=mk('div');sw.className='cfg-switch'+(cur==='1'?' on':'');sw.setAttribute('role','switch');sw.setAttribute('aria-checked',cur==='1'?'true':'false');row.appendChild(sw);list.appendChild(row);}
 function logReportNote(t){const e=mk('div');e.textContent=t;return e;}
function deviceSnapshotCard(title,value,detail,tone){const e=mk('div');e.textContent=title+' '+value+' '+detail+' '+tone;return e;} function deviceSizeKb(v){return v+' KiB';}
let commands=[],refreshes=0,toastText=''; async function asbPaintYield(){paintYields++;} async function run(c){commands.push(c);return {errno:0,stdout:''};} function runOk(r){return r.errno===0;} function runText(r){return r.stdout||'';} function toast(t){toastText=t;} function asbDeviceInfoLoad(){refreshes++;}
JS
    sed -n '/^const TECH_ICON_PATHS = {/,/^};/p; /^function parseDeviceInfo(/,/^}/p; /^function devicePressureScale(/,/^}/p; /^function deviceZygiskLinkState(/,/^}/p; /^function deviceZygiskLinkVerdict(/,/^}/p; /^function deviceZygiskLink(/,/^}/p; /^let _zygiskHeaderSeq/p; /^let _zygiskHeaderAt/p; /^const ZYGISK_HEADER_TTL_MS/p; /^const _ASB_PART/p; /^function runBatchCmd(/,/^}/p; /^function runBatchSplit(/,/^}/p; /^async function runBatch(/,/^}/p; /^let _zygiskLoadSeq/p; /^const ZYGISK_MODES = \[/,/^\];/p; /^function zygiskModeOf(/,/^}/p; /^function zygiskModeLabel(/,/^}/p; /^function zygiskAutoCard(/,/^}/p; /^const ZYGISK_CONTROL_KEYS =/p; /^const ZYGISK_FEATURE_KEYS =/p; /^let _zygiskControlBusy/p; /^let _zygiskControlsExpanded/p; /^function zygiskControlsCard(/,/^}/p; /^async function zygiskControlSet(/,/^}/p; /^function zygiskOpenSettings(/,/^}/p; /^function zygiskOffCard(/,/^}/p; /^async function zygiskAutoSet(/,/^}/p; /^async function zygiskGuardPackage(/,/^}/p; /^function zygiskModeCard(/,/^}/p; /^async function zygiskModeSet(/,/^}/p; /^function zygiskHeaderPaint(/,/^}/p; /^function zygiskHeaderWordmark(/,/^}/p; /^function zygiskHeaderInit(/,/^}/p; /^function zygiskHeaderPublish(/,/^}/p; /^async function zygiskHeaderRefresh(/,/^}/p; /^function cfgRenderZygiskCard(/,/^}/p; /^function deviceZygiskOverview(/,/^}/p; /^function deviceZygiskEditor(/,/^}/p' "$ROOT/webroot/index.html"
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
linkState({state_freshness:'stale_over_5_minutes',spawn_events:'438',policy_seen_generation:'7',policy_generation:'7'},'quiet');
linkState({state_freshness:'stale_over_5_minutes',spawn_events:'438',policy_seen_generation:'6',policy_generation:'7'},'stale');
linkState({link_state:'quiet'},'quiet');
linkState({safe_mode:'on',state_freshness:'current',loaded_processes:'2'},'safe');
linkState({enabled:'0'},'off');linkState({events_total:'broken',state_freshness:'current'},'unknown');
linkState({enabled:'—'},'unknown');linkState({state_freshness:'not exposed'},'unknown');
let link=deviceZygiskLink(linkData({state_freshness:'current',loaded_processes:'2',events_total:'2'}));
chk(link.className.includes('dev-zygisk-link-connected'),'connected badge class');chk(find(link,'dev-zygisk-link-state').textContent==='Connected','connected badge text');chk(find(link,'dev-zygisk-link-detail').textContent.includes('2'),'live process evidence missing');
link=deviceZygiskLink(linkData({}));chk(link.className.includes('dev-zygisk-link-idle'),'installed ABI files falsely confirmed a channel');chk(find(link,'dev-zygisk-link-state').textContent==='Enabled · nothing selected','empty-selection badge text');
const zeroNote=p=>find(deviceZygiskOverview(linkData(p)),'dev-zygisk-zero');
chk(zeroNote({state_freshness:'current',loaded_processes:'0'}),'current enabled zero-resident snapshot lacks its bounded explanation');
chk(zeroNote({state_freshness:'current',loaded_processes:'0'}).textContent.includes('not an injection-failure count'),'zero-resident explanation lost the evidence boundary');
chk(!zeroNote({state_freshness:'current',loaded_processes:'1'}),'resident process still shows the zero explanation');
chk(!zeroNote({state_freshness:'stale_over_5_minutes',loaded_processes:'0'}),'stale snapshot claims a current zero-resident state');
chk(!zeroNote({state_freshness:'current',loaded_processes:'0',safe_mode:'on'}),'safe mode incorrectly uses the ordinary zero explanation');
chk(!zeroNote({state_freshness:'current',loaded_processes:'0',enabled:'0'}),'disabled observer incorrectly uses the enabled zero explanation');
zygiskHeaderInit();chk(hosts.every(h=>!!find(h,'zygisk-header-link')),'not all five page headers received the badge');
chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='unknown'),'missing evidence did not remain unknown');
zygiskHeaderPublish(linkData({state_freshness:'current',loaded_processes:'2',events_total:'2'}));
chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='connected'),'validated live process did not paint every header');
zygiskHeaderPublish(linkData({}));chk(hosts.every(h=>find(h,'zygisk-header-link').attrs['data-state']==='idle'),'installed ABI files falsely connected a page header');
const unifiedList=mk('div');cfgRenderZygiskCard(unifiedList,CFG_ITEMS);
const unified=find(unifiedList,'cfg-zygisk-card');chk(!!unified&&unified.children.length===6,'Settings card must contain verdict, four control rows and ZYGISK navigation');
chk(unified&&!find(unified,'cfg-zygisk-preset'),'Settings still exposes a second preset panel');
chk(unified&&unified.children.filter(r=>find(r,'cfg-switch')).length===4,'Settings does not expose all four Zygisk switches');
chk(unified&&unified.children[1].attrs['data-key']==='zygisk_enabled','the first Settings switch is not the master');
chk(unified&&unified.children[1].querySelector('.cfg-switch').attrs['aria-checked']==='true','Settings master is not synchronized from the same evidence as its indicator');
chk(unified&&find(unified,'cfg-zygisk-open')&&find(unified,'cfg-zygisk-open').onclick===openZygiskPage,'Settings lost its ZYGISK navigation');
(async()=>{const ed=deviceZygiskEditor(d),input=find(ed,'dev-zygisk-input'),buttons=ed.children.flatMap(x=>x.children||[]).filter(x=>x.tagName==='button');
chk(input.tagName==='textarea'&&input.rows===4,'allowlist editor is not a four-row wrapping textarea');
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
// fix305: three user goals own automatic selection, four switches and the guard baseline.
const md=p=>({sections:{zygisk_observer:Object.assign({enabled:'1',lifecycle_hints:'0',launch_hints:'1',spawn_ledger:'1',safe_mode:'off',auto_mode:'1',auto_profile:'launch'},p)}});
_zyGuard={enabled:false,level:'off'};
chk(zygiskModeOf(md({enabled:'0'}))==='off','master off is Off whatever the automatic marker says');
chk(zygiskModeOf(md({}))==='performance','Launch baseline is Performance');
_zyGuard={enabled:true,level:'wakers'};
chk(zygiskModeOf(md({auto_profile:'battery',launch_hints:'0'}))==='battery','Battery requires its exact switches and wakers guard');
chk(zygiskModeOf(md({auto_profile:'auto',lifecycle_hints:'1'}))==='auto','Auto combines all switches and wakers guard');
chk(zygiskModeOf(md({auto_profile:'battery'}))==='custom','Battery with cold-start lift still on becomes Custom');
chk(zygiskModeOf(md({auto_profile:'battery',launch_hints:'0',lifecycle_hints:'1'}))==='custom','Battery with lifecycle requests becomes Custom');
chk(zygiskModeOf(md({auto_profile:'auto',lifecycle_hints:'1',spawn_ledger:'0'}))==='custom','Auto with ledger manually removed becomes Custom');
_zyGuard={enabled:false,level:'off'};
chk(zygiskModeOf(md({auto_profile:'auto',lifecycle_hints:'1'}))==='custom','Auto with a changed guard does not keep the Auto label');
chk(zygiskModeOf(md({auto_profile:'battery',launch_hints:'0'}))==='custom','Battery with guard off becomes Custom');
chk(zygiskModeOf(md({auto_mode:'0'}))==='custom','manual Settings switches are Custom, not false automatic ownership');
chk(zygiskModeOf(md({enabled:'—'}))==='unknown','an unreadable master is unknown, not Off');
_zyGuard=null;chk(zygiskModeOf(md({}))==='unknown','pending guard evidence does not confirm Performance');
chk(zygiskModeOf(md({auto_profile:'battery',launch_hints:'0',lifecycle_hints:'1'}))==='custom','a known switch conflict is Custom even before guard evidence arrives');
_zyGuard={enabled:false,level:'off'};
let card=zygiskModeCard(md({})),seg=find(card,'zy-mode-seg');
chk(card.attrs['data-zygisk-icon']==='zygisk_mode','Mode still reuses the Controls glyph');
chk(seg&&seg.children.length===3,'unified mode does not have exactly three choices');
chk(seg&&seg.children[2].className.split(/\s+/).includes('on')&&seg.children.filter(b=>b.className.split(/\s+/).includes('on')).length===1,'exactly Performance is selected');
chk(seg&&seg.children.every(b=>b.title&&b.title.length>20),'unified mode buttons lack their explanatory native titles');
chk(seg.children[0].textContent==='Auto'&&seg.children[1].textContent==='Battery'&&seg.children[2].textContent==='Performance','unified mode labels/order changed');
card=zygiskModeCard(md({auto_profile:'battery',launch_hints:'0',lifecycle_hints:'1'}));seg=find(card,'zy-mode-seg');
chk(seg.children.every(b=>!b.className.split(/\s+/).includes('on'))&&find(card,'zy-custom-note'),'Custom selects no preset and explains the manual override');
// fix306: one control panel owns the master and all three feature switches.
_zyGuard={enabled:false,level:'off'};_cfgVals={zygisk_enabled:'0',zygisk_hints:'0',zygisk_launch:'0',zygisk_ledger:'0'};
const controls=zygiskControlsCard(md({}));
chk(controls.attrs['data-zygisk-icon']==='switches','Controls lost its dedicated sliders glyph');
const controlPanel=find(controls,'zy-controls-panel');
chk(controlPanel&&controlPanel.hidden===true&&find(controls,'zy-controls-reveal').attrs['aria-expanded']==='false','ZYGISK controls are not collapsed by default');
const controlRows=controlPanel.children.filter(r=>r.attrs&&r.attrs['data-key']);
chk(controlRows.length===4&&controlRows.map(r=>r.attrs['data-key']).join(',')===ZYGISK_CONTROL_KEYS.join(','),'ZYGISK panel does not own all four controls in order');
chk(controlRows[0].querySelector('.cfg-switch').attrs['aria-checked']==='true','master is not synchronized from current evidence');
chk(controlRows[1].querySelector('.cfg-switch').attrs['aria-checked']==='false'&&controlRows[2].querySelector('.cfg-switch').attrs['aria-checked']==='true'&&controlRows[3].querySelector('.cfg-switch').attrs['aria-checked']==='true','feature switches are not synchronized from current evidence');
const off=zygiskOffCard();chk(find(off,'zy-off-enable')&&find(off,'zy-off-settings'),'Off state lacks Enable or Settings navigation');
chk(off.attrs['data-zygisk-icon']==='zygisk_master','Off state still reuses the Controls glyph');
chk(!find(off,'zy-mode-seg')&&!find(off,'zy-auto-actions')&&!find(off,'dev-zygisk-editor'),'Off state exposes inactive preset/automatic/app controls');
chk(off.children.some(x=>String(x.textContent).includes('already running')&&String(x.textContent).includes('restarted')),'Off state does not bound the restart semantics');
cfgWrites=[];pageLoads=0;paintYields=0;_cfgVals={zygisk_enabled:'0',zygisk_hints:'1',zygisk_launch:'0',zygisk_ledger:'1',other:'kept'};
await find(off,'zy-off-enable').onclick();await new Promise(r=>setTimeout(r,0));
chk(cfgWrites.length===1&&cfgWrites[0].key==='zygisk_enabled'&&cfgWrites[0].val==='1'&&cfgWrites[0].busy,'Off Enable did not use the single master config write');
chk(_cfgVals.zygisk_hints==='1'&&_cfgVals.zygisk_launch==='0'&&_cfgVals.zygisk_ledger==='1'&&_cfgVals.other==='kept','Off to On silently reset the saved feature setup');
chk(pageLoads===1&&paintYields===1,'Zygisk write did not paint busy state and refresh the page');
_cfgVals.zygisk_hints='0';await controlRows[1].querySelector('.cfg-switch').onclick({stopPropagation(){}});await new Promise(r=>setTimeout(r,0));
chk(cfgWrites.length===2&&cfgWrites[1].key==='zygisk_hints'&&cfgWrites[1].val==='1','feature switch bypassed the shared config writer');
chk(pageLoads===2,'feature switch did not refresh preset/Custom evidence');
await zygiskControlSet('not_a_setting','1',null);chk(cfgWrites.length===2,'unknown key reached the config writer');
// fix284: automatic card, its single-shell command flow and read-only package editor.
_zyGuard={enabled:true,level:'wakers'};
let autoCard=zygiskAutoCard(md({auto_mode:'1',auto_profile:'battery',enabled_packages:'64',enabled:'1',lifecycle_hints:'0',launch_hints:'0',spawn_ledger:'1'}));
chk(find(autoCard,'zy-auto-summary').textContent.includes('64')&&find(autoCard,'zy-auto-summary').textContent.includes('Loops + night wakers')&&find(autoCard,'zy-auto-summary').textContent.includes('ART (independent): On'),'automatic summary does not show actual profile/package/guard/independent ART state');
chk(find(autoCard,'zy-auto-current').textContent==='Current independent switches: Observer: Enabled · Lifecycle hints: Disabled · Cold-start lift: Disabled · Process ledger: Enabled','automatic profile hides or misreports the independent Zygisk switches');
chk(!find(autoCard,'zy-auto-profiles'),'automatic card still exposes competing profile buttons');
chk(find(autoCard,'zy-auto-actions').children.length===2,'enabled automatic card lacks refresh/disable actions');
chk(zygiskAutoCard(md({auto_mode:'0'})).children.length>0&&find(zygiskAutoCard(md({auto_mode:'0'})),'zy-auto-actions').children.length===0,'off automatic card has an obsolete combined enable action');
const autoEd=deviceZygiskEditor(md({auto_mode:'1',enabled_package_list:'com.example.auto'}));
chk(find(autoEd,'dev-zygisk-input').attrs.readonly==='readonly','automatic package editor is not read-only');
chk(autoEd.children.flatMap(x=>x.children||[]).filter(x=>x.tagName==='button')[0].hidden===true,'manual save remains visible in automatic mode');
const autoOutput=(result,auto)=>result+'\n'+_ASB_PART+'set\n'+raw({auto_mode:auto?'1':'0',enabled_packages:auto?'64':'0'})+'\n'+_ASB_PART+'link\nversion=1\nenabled='+(auto?'1':'0')+'\nlevel=wakers\n'+_ASB_PART+'guard\nversion=1\nenabled='+(auto?'1':'0')+'\n'+_ASB_PART+'aot';
let busyAtRun='',labelAtRun='';
commands=[];run=async c=>{commands.push(c);busyAtRun=_zygiskAutoBusy;labelAtRun=find(zygiskModeCard(md({auto_mode:'0'})),'zy-mode-seg').children[2].textContent;return {errno:0,stdout:autoOutput('result=enabled',true),stderr:''};};
await zygiskAutoSet('enable','launch');
chk(busyAtRun==='enable:launch'&&labelAtRun==='Setting up…','the selected unified mode did not say it was working while setup ran');
chk(_zygiskAutoBusy==='','fix287: the busy label outlived the setup');
chk(commands.length===1&&commands[0].includes('auto-enable launch'),'automatic enable is not one profile-specific shell');
chk(commands[0].indexOf('auto-enable')<commands[0].indexOf('link-status')&&commands[0].includes('asb_zygisk_guard.sh')&&commands[0].includes('asb_zygisk_aot.sh'),'automatic enable did not refresh all state');
chk(/Mode applied/.test(toastText),'unified mode result not reported');
commands=[];_cfgVals={};run=async c=>{commands.push(c);return {errno:0,stdout:autoOutput('result=enabled',true),stderr:''};};
await zygiskModeSet('auto');
chk(commands.length===1&&commands[0].includes('auto-enable auto'),'Auto mode does not delegate to the single transactional Auto profile');
chk(_cfgVals.zygisk_enabled==='1'&&_cfgVals.zygisk_hints==='1'&&_cfgVals.zygisk_launch==='1'&&_cfgVals.zygisk_ledger==='1','Auto did not synchronize all four Settings switches');
chk(ZYGISK_MODES[0].icon==='zygisk_mode_auto'&&ZYGISK_MODES[2].icon==='zygisk_mode_performance','Auto/Performance lost their dedicated mode icons');
chk(TECH_ICON_PATHS.zygisk_mode_auto.includes('M18.8 8A7.5')&&TECH_ICON_PATHS.zygisk_mode_performance.includes('M3.5 17a8.5'),'dedicated mode glyphs regressed');
chk(ZYGISK_MODES[2].icon!=='zygisk_launch'&&TECH_ICON_PATHS.zygisk_launch.includes('M11 13 19.5 4.5'),'Performance icon change leaked into Cold-start');
chk(['zygisk_master','zygisk_mode','zygisk_art'].every(k=>typeof TECH_ICON_PATHS[k]==='string'&&TECH_ICON_PATHS[k].length>20),'master/Mode/ART dedicated glyphs are missing');
chk(new Set([TECH_ICON_PATHS.zygisk_master,TECH_ICON_PATHS.zygisk_mode,TECH_ICON_PATHS.zygisk_art,TECH_ICON_PATHS.switches,TECH_ICON_PATHS.zygisk_observer,TECH_ICON_PATHS.zygisk_launch]).size===6,'semantically different Zygisk sections still share identical glyph geometry');
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:autoOutput('result=refreshed',true),stderr:''};};await zygiskAutoSet('refresh');chk(commands.length===1&&commands[0].includes('auto-refresh')&&/refreshed/.test(toastText),'automatic refresh flow failed');
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:autoOutput('result=disabled',false),stderr:''};};await zygiskAutoSet('disable');chk(commands.length===1&&commands[0].includes('auto-disable')&&/previous Zygisk state restored/.test(toastText),'automatic disable/restore flow failed');
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:'result=approved\n'+_ASB_PART+'set\nversion=1\nenabled=1\nlevel=wakers\n'+_ASB_PART+'guard\n',stderr:''};};
await zygiskGuardPackage('approve','com.loop.app');
chk(commands.length===1&&commands[0].includes("asb_zygisk_guard.sh' approve 'com.loop.app'")&&commands[0].includes("asb_zygisk_guard.sh' status"),'guard approval is not one shell followed by a fresh status');
chk(_zyGuard.enabled&&_zyGuard.level==='wakers'&&!_zygiskModeBusy&&/two-session evidence/.test(toastText),'guard approval did not update state/busy/toast');
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:'result=released\n'+_ASB_PART+'set\nversion=1\nenabled=1\nlevel=wakers\n'+_ASB_PART+'guard\n',stderr:''};};
await zygiskGuardPackage('release','com.loop.app');
chk(commands.length===1&&commands[0].includes("asb_zygisk_guard.sh' release 'com.loop.app'")&&/Previous background mode restored/.test(toastText),'emergency per-package release flow failed');
commands=[];await zygiskGuardPackage('delete','com.loop.app');chk(commands.length===0,'an unsupported guard package action reached the shell');
commands=[];run=async c=>{commands.push(c);return {errno:0,stdout:autoOutput('result=safe_mode',false),stderr:''};};await zygiskAutoSet('enable','battery');chk(/Safe mode is on/.test(toastText)&&!/_cfgLoadSig/.test(''),'Safe mode refusal was not explained');
if(bad)process.exit(1);console.log('ok');})().catch(e=>{console.error(e);process.exit(1)});
JS
  } > "$T/test.js"
  out="$(node "$T/test.js" 2>&1)" || fail "$out"
  [ "$out" = ok ] || fail "$out"
  python3 - "$ROOT/webroot/i18n" <<'PY' || fail 'link badge locales'
import json, pathlib, sys
states = ('connected', 'confirmed', 'waiting', 'idle', 'quiet', 'stale', 'safe', 'off', 'unknown')
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
    auto_keys = ('title','recommended','desc','enable','refresh','disable','summary','note','enabled','refreshed','disabled','failed','safe','managed_label','managed_note')
    for key in auto_keys:
        assert d['zy_auto_' + key].strip(), (p, key)
    unified_keys = ('zy_mode_battery', 'zy_mode_battery_desc',
                    'zy_mode_performance', 'zy_mode_performance_desc',
                    'zy_mode_auto', 'zy_mode_auto_desc', 'zy_mode_custom_short',
                    'zy_mode_custom_unified', 'zy_mode_custom_warning',
                    'zy_auto_managed_by_mode', 'zy_auto_desc_unified',
                    'zy_settings_mode', 'zy_settings_custom', 'dev_zygisk_zero_processes',
                    'zy_settings_open', 'zy_sec_controls', 'zy_controls_note', 'zy_control_failed',
                    'zy_off_title', 'zy_off_desc', 'zy_off_kept', 'zy_off_enable', 'zy_off_settings')
    for key in unified_keys:
        assert d[key].strip(), (p, key)
source = (pathlib.Path(sys.argv[1]).parent / 'index.html').read_text(encoding='utf-8')
page = source.split('function zygiskPageRender(d, state) {', 1)[1].split('/* fix280:', 1)[0]
assert page.index("const zyOn = deviceVal(d, 'zygisk_observer', 'enabled') !== '0';") < page.index('if (!zyOn) {') < page.index('const mode = zygiskModeCard(d);')
assert page.index('body.appendChild(zygiskOffCard());') < page.index('const mode = zygiskModeCard(d);')
assert page.index('const controls = zygiskControlsCard(d, true);') < page.index('const mode = zygiskModeCard(d);') < page.index('const automatic = zygiskAutoCard(d);')
assert "st.appendChild(controls);" in page and "T('zy_sec_link_controls', 'Connection and controls')" in page, 'controls are not merged into the Connection card'
assert "zygisk_enabled:'zygisk_master'" in source, 'master still reuses Connection evidence glyph'
assert "logReportSec(T('zy_sec_mode', 'Mode'), 'zygisk_mode')" in source, 'Mode still reuses Controls glyph'
assert "logReportSec(T('zy_sec_controls', 'ASB Zygisk controls'), 'switches')" in source, 'Controls glyph changed unexpectedly'
assert "logReportSec(T('zy_aot_title', 'Faster app starts (ART)'), 'zygisk_art')" in source, 'ART still reuses Cold-start glyph'
assert "logReportSec(T('zy_off_title', 'ASB Zygisk is off'), 'zygisk_master')" in source, 'Off still reuses Controls glyph'
assert "zygiskButtonIcon(open, 'switches');" in source, 'Open ZYGISK navigation still duplicates Connection glyph'
assert 'zygiskGoalGuide' not in source and 'zy-auto-profiles' not in source, 'obsolete competing Zygisk controls remain'
assert 'zy_mode_fine' not in page and 'Fine-tune in Settings' not in source, 'obsolete second fine-tuning panel remains'
writer = source.split('async function cfgSet(key, val, ctl) {', 1)[1].split('let _cfgRebootArmed', 1)[0]
assert "if (/^zygisk_/.test(key))" in writer and 'asb_zygisk.sh' in writer and ' sync ' in writer, 'shared Zygisk sync writer was lost'
assert "T('t_cfg_next'" in writer.split("if (/^zygisk_/.test(key))", 1)[1].split("if (key === 'log_level')", 1)[0], 'Zygisk writes still fall through to a false reboot toast'
lazy = source.split('function zygiskHeaderRefreshLazy() {', 1)[1].split('\n}', 1)[0]
assert lazy.count('zygiskHeaderRefresh();') == 1, 'lazy header refresh must have exactly one delayed refresh call'
PY
  echo 'PASS observer UI: three unified presets, Custom conflicts, four Settings controls, default-collapsed complete ZYGISK panel, preserved Off/On state, bounded evidence, 13 locales and safe editor'
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
      printf 'D\tzygisk_observer\tledger_top_screen_off\tcom.example.sync 17/3\nD\tzygisk_observer\tledger_restart_loops\t4\n'
      for _k in events_total spawn_events launch_events launch_accepted launch_vetoed launch_unavailable launch_throttled launch_screen_off policy_hints hints_accepted hints_vetoed ledger_events events_dropped_total ipc_cpu_ms ipc_wakeups; do
        printf 'D\tzygisk_observer\t%s\t%s\n' "$_k" "$_base"
      done
    } > "$_file"
  }
  _set_counter() {
    awk -F '\t' -v OFS='\t' -v key="$2" -v value="$3" '$3 == key { $4=value } { print }' "$1" > "$1.tmp"
    mv "$1.tmp" "$1"
  }
  _snap "$CAP/zygisk_observer_start.tsv" waiting 10
  _snap "$CAP/zygisk_observer_latest.tsv" connected 15
  out="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP")"
  zy="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'^zygisk\tstate=connected\tstart_state=waiting\tcoverage=start_latest' || fail "capture verdict missing: $zy"
  printf '%s\n' "$zy" | grep -q $'events_total_delta=5' || fail 'event delta missing'
  printf '%s\n' "$zy" | grep -q $'launch_accepted_delta=5' || fail 'launch delta missing'
  printf '%s\n' "$zy" | grep -q $'launch_vetoed_delta=5' && printf '%s\n' "$zy" | grep -q $'launch_unavailable_delta=5' && printf '%s\n' "$zy" | grep -q $'launch_throttled_delta=5' && printf '%s\n' "$zy" | grep -q $'launch_screen_off_delta=5' || fail 'cold-start outcome deltas missing'
  printf '%s\n' "$zy" | grep -q $'memory_kb=2222' && printf '%s\n' "$zy" | grep -q $'ledger_top_screen_off=com.example.sync 17/3' && printf '%s\n' "$zy" | grep -q $'ledger_restart_loops=4' || fail 'ledger diagnostics missing'
  printf '%s\n' "$zy" | grep -q $'ipc_cpu_ms_delta=5' || fail 'IPC delta missing'
  printf '%s\n' "$zy" | grep -q $'deltas=available' || fail 'valid deltas not acknowledged'
  # Governor-side action evidence comes only from the state blocks already present in
  # before/after snapshots. Decoys outside that block must never enter the projection.
  cat > "$CAP/before.txt" <<'EOF_GOV_BEFORE'
===== before =====
zygisk_launch_accepted=999
--- state (key=value) ---
zygisk_launch_accepted=10
zygisk_launch_vetoed=2
zygisk_refresh_accepted=7
zygisk_refresh_vetoed=1
unlock_cold_lifts=4
unlock_cold_extends=3
unlock_cold_long=2
unlock_cold_trims=1
unrelated_counter=500
--- end state ---
unlock_cold_lifts=999
EOF_GOV_BEFORE
  cat > "$CAP/after.txt" <<'EOF_GOV_AFTER'
===== after =====
--- state (key=value) ---
zygisk_launch_accepted=15
zygisk_launch_vetoed=4
zygisk_refresh_accepted=10
zygisk_refresh_vetoed=2
unlock_cold_lifts=7
unlock_cold_extends=5
unlock_cold_long=4
unlock_cold_trims=2
--- end state ---
EOF_GOV_AFTER
  gov="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygov"')"
  printf '%s\n' "$gov" | grep -q $'^zygov\tcoverage=start_latest' || fail "governor coverage missing: $gov"
  for field in zygisk_launch_accepted_delta=5 zygisk_launch_vetoed_delta=2 zygisk_refresh_accepted_delta=3 zygisk_refresh_vetoed_delta=1 unlock_cold_lifts_delta=3 unlock_cold_extends_delta=2 unlock_cold_long_delta=2 unlock_cold_trims_delta=1 deltas=available; do
    printf '%s\n' "$gov" | grep -q "	$field" || fail "governor action projection: $field: $gov"
  done
  ! printf '%s\n' "$gov" | grep -q '999\|unrelated_counter' || fail 'state-block allowlist leaked decoy evidence'
  # A capture zipped while the recorder still runs has no after.txt yet: the newest hourly
  # snapshot is its latest point, as it already is for the Smart counters.
  mv "$CAP/after.txt" "$CAP/after.hold"
  cp "$CAP/after.hold" "$CAP/snapshot_1794000100.txt"
  sed 's/^zygisk_launch_accepted=15$/zygisk_launch_accepted=12/' "$CAP/after.hold" > "$CAP/snapshot_1794000000.txt"
  gov="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygov"')"
  printf '%s\n' "$gov" | grep -q $'^zygov\tcoverage=start_latest' && printf '%s\n' "$gov" | grep -q $'\tzygisk_launch_accepted_delta=5\t' \
    || fail "a live export without after.txt did not read the newest snapshot: $gov"
  rm -f "$CAP"/snapshot_*.txt; mv "$CAP/after.hold" "$CAP/after.txt"
  sed -i 's/^unlock_cold_lifts=7$/unlock_cold_lifts=3/' "$CAP/after.txt"
  gov="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygov"')"
  for k in zygisk_launch_accepted zygisk_launch_vetoed zygisk_refresh_accepted zygisk_refresh_vetoed unlock_cold_lifts unlock_cold_extends unlock_cold_long unlock_cold_trims; do
    printf '%s\n' "$gov" | grep -q "	${k}_delta=unknown" || fail "governor reset invented $k: $gov"
  done
  printf '%s\n' "$gov" | grep -q $'deltas=counter_reset_or_restart' || fail 'governor reset was not named'
  rm "$CAP/before.txt"
  gov="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygov"')"
  printf '%s\n' "$gov" | grep -q $'coverage=latest_only' && printf '%s\n' "$gov" | grep -q $'unlock_cold_lifts_latest=3' && printf '%s\n' "$gov" | grep -q $'unlock_cold_lifts_delta=unknown' || fail "single governor snapshot was not bounded: $gov"
  rm "$CAP/after.txt"
  # SM8750 field shape: an outcome decreased across a companion restart while the total
  # stayed at ten and accepted rose. No cold-start delta is comparable in that window;
  # independent spawn activity remains a valid monotonic counter.
  _snap "$CAP/zygisk_observer_start.tsv" confirmed 0
  _snap "$CAP/zygisk_observer_latest.tsv" confirmed 0
  for pair in 'launch_events 10' 'launch_accepted 8' 'launch_vetoed 0' 'launch_unavailable 2' 'launch_throttled 0' 'spawn_events 92'; do
    set -- $pair; _set_counter "$CAP/zygisk_observer_start.tsv" "$1" "$2"
  done
  for pair in 'launch_events 10' 'launch_accepted 9' 'launch_vetoed 0' 'launch_unavailable 1' 'launch_throttled 0' 'spawn_events 102'; do
    set -- $pair; _set_counter "$CAP/zygisk_observer_latest.tsv" "$1" "$2"
  done
  zy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygisk"')"
  for k in launch_events launch_accepted launch_vetoed launch_unavailable launch_throttled launch_screen_off; do
    printf '%s\n' "$zy" | grep -q "	${k}_delta=unknown" || fail "reset launch family invented $k: $zy"
  done
  printf '%s\n' "$zy" | grep -q $'spawn_events_delta=10' || fail 'an independent monotonic spawn counter was discarded'
  printf '%s\n' "$zy" | grep -q $'deltas=counter_reset_or_restart' || fail 'partial cold-start reset was not named'
  _snap "$CAP/zygisk_observer_start.tsv" waiting 10
  _snap "$CAP/zygisk_observer_latest.tsv" connected 4
  zy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'events_total_delta=unknown' || fail 'counter reset invented a delta'
  printf '%s\n' "$zy" | grep -q $'deltas=counter_reset_or_restart' || fail 'counter reset was not named'
  rm "$CAP/zygisk_observer_start.tsv"
  zy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP" | awk -F '\t' '$1 == "zygisk"')"
  printf '%s\n' "$zy" | grep -q $'coverage=latest_only' || fail 'single snapshot not bounded'
  printf '%s\n' "$zy" | grep -q $'events_total_delta=unknown' || fail 'single snapshot invented a delta'
  rm "$CAP/zygisk_observer_latest.tsv"
  legacy="$(ASB_LK_LOCK="$T/no-lock" ASB_LK_STATE_DIR="$T/state" ASB_CFG_FILE="$T/no-config" sh "$ROOT/tools/logkit/asb_fullday_digest.sh" "$CAP")"
  ! printf '%s\n' "$legacy" | grep -q '^zygisk' || fail 'legacy capture gained fake Zygisk evidence'
  ! printf '%s\n' "$legacy" | grep -q '^zygov' || fail 'legacy capture gained fake Governor action evidence'
  echo 'PASS observer capture digest: companion/Governor start/latest verdicts, newest hourly snapshot for a live export, monotonic deltas, full-family resets, single-snapshot and legacy-capture honesty'
)

t_zygisk_link_runtime() (
  # fix286: one engine. The REAL runtime/asb_zygisk_link.sh joins LSPosed's scope (through the
  # same "asb --lspd modules" reader asbdiag uses), Android's launch log and the guard/ART/
  # protection files. It writes the launch classes the companion reads - parsed here by the
  # native parser itself, so a name the native side would refuse can never invalidate the file
  # - writes them only when they change, withdraws them with the cold-start lift, keeps the
  # list of LSPosed module apps the guard never restricts, and reports one row per app.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL zygisk link: $*" >&2; exit 1; }
  S="$ROOT/runtime/asb_zygisk_link.sh"
  sh -n "$S" || fail syntax
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/mod/config" "$T/mod/zygisk" "$T/mod/runtime" "$T/asb/zygisk_observer" "$T/run" "$T/lspd/config" "$T/bin" "$T/tmp" \
    "$T/mods/zygisk_lsposed/zygisk" "$T/mods/other_x/zygisk" "$T/mods/plain" "$T/mods/AutoSystemBoost/zygisk"
  cp "$ROOT/runtime/asb_zygisk_aot.sh" "$T/mod/runtime/"
  printf 'zygisk_enabled=1\nzygisk_launch=1\nzygisk_ledger=1\n' > "$T/mod/config/governor.conf"
  : > "$T/lspd/config/modules_config.db"
  cat > "$T/bin/asb" <<'SH'
#!/bin/sh
[ "$1" = --lspd ] && [ "$2" = modules ] || exit 1
cat "$ZL_T/lspd.out"
SH
  cat > "$T/bin/logcat" <<'SH'
#!/bin/sh
case "$*" in *"-b events"*) cat "$ZL_T/events" 2>/dev/null ;; esac
SH
  cat > "$T/bin/pm" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = "list packages -3" ] && printf 'package:com.luckyzyx.luckytool\npackage:com.example.plainapp\n'
exit 0
SH
  chmod +x "$T/bin/"*
  cat > "$T/lspd.out" <<'E'
format=v1
module|com.luckyzyx.luckytool|1|x
module|it.dhd.oxygencustomizer|1|x
module|com.off.mod|0|x
scope|com.luckyzyx.luckytool|com.android.systemui|0
scope|com.luckyzyx.luckytool|android|0
scope|com.luckyzyx.luckytool|system|0
scope|com.luckyzyx.luckytool|com.example.hooked|0
scope|it.dhd.oxygencustomizer|com.android.systemui|0
scope|it.dhd.oxygencustomizer|com.example.hooked|0
scope|it.dhd.oxygencustomizer|com.example.hookedfast|0
scope|com.luckyzyx.luckytool|com.example.hookedfast|0
scope|com.off.mod|com.example.offonly|0
scope|com.luckyzyx.luckytool|com.example.hookednolaunch|0
scope|it.dhd.oxygencustomizer|com.example.hookedmid|0
E
  now=1730000000
  { for i in 1 2 3 4; do echo "$((now+i))|com.example.slowapp|$((1200+i*10))|1"; done
    for i in 1 2 3; do echo "$((now+10+i))|com.example.fastapp|$((300+i))|1"; done
    for i in 1 2 3; do echo "$((now+20+i))|com.example.midapp|700|1"; done
    for i in 1 2 3; do echo "$((now+30+i))|com.example.hookedfast|350|1"; done
    echo "$((now+40))|com.example.hooked|1300|1"; echo "$((now+41))|com.example.hooked|200|0"
    for i in 1 2 3; do echo "$((now+50+i))|com.android.settings|1500|1"; done
    for i in 1 2 3; do echo "$((now+60+i))|com.example.offonly|500|1"; done
    for i in 1 2 3; do echo "$((now+65+i))|com.example.hookedmid|800|1"; done
  } > "$T/asb/zygisk_aot_launch"
  printf 'b boot-1 %s\ncom.example.slowapp 30 20 4 0 0 0\n' "$now" > "$T/asb/zygisk_guard_hist"
  printf 'com.example.midapp|default|default|%s|7|loop|7|0\n' "$now" > "$T/asb/zygisk_guard_active"
  printf 'com.example.fastapp|4|verify|install|%s|0|-|0|-\n' "$now" > "$T/asb/zygisk_aot_apps"
  printf 'com.example.midapp|1|2\n' > "$T/asb/notif_fix"
  printf 'name=Zygisk - LSPosed\n' > "$T/mods/zygisk_lsposed/module.prop"; : > "$T/mods/zygisk_lsposed/zygisk/arm64-v8a.so"
  printf 'name=Other `x`;$(id)\n' > "$T/mods/other_x/module.prop"; : > "$T/mods/other_x/zygisk/arm64-v8a.so"; : > "$T/mods/other_x/disable"
  : > "$T/mods/AutoSystemBoost/zygisk/arm64-v8a.so"
  printf 'zygisk_launch_long=4\nzygisk_launch_short=2\nunlock_cold_long=3\nunlock_cold_trims=1\nzygisk_launch_accepted=20\n' > "$T/gstate"
  printf 'Z\tevents_total\t3\nZ\tlaunch_long\t5\nZ\tlaunch_short\t3\nZ\tdenylist_spawns\t7\nZ\tclasses_loaded\t1\n' > "$T/run/state.arm64-v8a.tsv"
  run() { PATH="$T/bin:$PATH" ZL_T="$T" MODDIR="$T/mod" ASB_ZL_DIR="$T/asb" ASB_ZYGISK_RUN_DIR="$T/run" ASB_LSPD_DIR="$T/lspd" \
    ASB_GOV_BIN="$T/bin/asb" ASB_ZL_MODULES="$T/mods" ASB_ZL_GOV_STATE="$T/gstate" ASB_ZL_TMP="$T/tmp" ASB_DOZE_KEEP="$T/asb/keep" sh "$S" "$@"; }
  out="$(run classes)"; [ "$out" = 'result=written slow=1 fast=2' ] || fail "classes: $out"
  C="$T/mod/zygisk/classes"
  [ "$(stat -c %a "$C")" = 600 ] || fail "launch classes are not root-only: $(stat -c %a "$C")"
  [ "$(cat "$C")" = "$(printf 'v=1\nslow=com.example.slowapp\nfast=com.example.fastapp\nfast=com.example.hookedfast')" ] \
    || fail "classes file: $(cat "$C")"
  grep -q 'systemui\|android$\|=system$\|settings\|offonly\|midapp\|hookednolaunch' "$C" && fail 'a protected, unhooked-by-enabled, usual or never-measured hooked app was classed'
  [ "$(cat "$T/asb/zygisk_lsposed_modules")" = "$(printf 'com.luckyzyx.luckytool\nit.dhd.oxygencustomizer')" ] || fail "module list: $(cat "$T/asb/zygisk_lsposed_modules")"
  if command -v g++ >/dev/null 2>&1; then
    cat > "$T/p.cpp" <<'CPP'
#include "asb_observer_protocol.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <sstream>
int main(int, char **argv) {
  std::ifstream f(argv[1]); std::stringstream b; b << f.rdbuf(); const std::string t = b.str();
  static AsbObserverClasses c;
  assert(asb_observer_classes_parse(t.data(), t.size(), c) && c.slow == 1 && c.fast == 2);
  assert(c.lookup("com.example.slowapp") == ASB_LAUNCH_LONG && c.lookup("com.example.hookedfast") == ASB_LAUNCH_SHORT);
  std::cout << "parsed\n";
}
CPP
    g++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT/src/zygisk" "$T/p.cpp" -o "$T/p" || fail 'parser fixture build'
    [ "$("$T/p" "$C")" = parsed ] || fail 'the native parser refused the generated classes'
  fi
  m0="$(stat -c %Y.%i "$C")"; chmod 644 "$C"; sleep 1
  out="$(run classes)"; [ "$out" = 'result=unchanged slow=1 fast=2' ] && [ "$(stat -c %Y.%i "$C")" = "$m0" ] || fail "an unchanged pass rewrote the file: $out"
  [ "$(stat -c %a "$C")" = 600 ] || fail 'an unchanged pass kept legacy world-readable classes'
  ls "$T/asb" | grep -q 'zygisk_link\.' && fail "temporary files left: $(ls "$T/asb")"
  st="$(run status)"
  for want in version=1 classes=on classes_slow=1 classes_fast=2 comp_state=1 comp_supported=1 comp_long=5 comp_short=3 comp_classes_loaded=1 \
      denylist_spawns=7 gov_launch=20 gov_long=4 gov_short=2 gov_cold_long=3 gov_trims=1 lsposed=1 lsposed_modules=2 lsposed_apps=5 lsposed_system=1 lsposed_sysui=2 \
      'zmod|other_x|0|Other x(id)' 'zmod|zygisk_lsposed|1|Zygisk - LSPosed' 'cmp|575|2|700|5'; do
    printf '%s\n' "$st" | grep -qxF "$want" || fail "status lacks '$want': $st"
  done
  printf '%s\n' "$st" | grep -q 'AutoSystemBoost' && fail 'ASB listed itself among other Zygisk modules'
  printf '%s\n' "$st" | grep -qxF 'app|com.example.midapp|normal|normal|measured|3|700|0|-|3|-1|loop|-|notif|0' || fail "guarded + protected row: $st"
  printf '%s\n' "$st" | grep -qxF 'app|com.example.slowapp|slow|slow|measured|4|1225|0|-|4|46|-|-|-|0' || fail "slow row with background history: $st"
  printf '%s\n' "$st" | grep -qxF 'app|com.example.fastapp|fast|fast|measured|3|302|0|-|3|-1|-|verify|-|0' || fail "fast row with ART: $st"
  printf '%s\n' "$st" | grep -qxF 'app|com.example.hooked|normal|normal|hooks|1|1300|2|it.dhd.oxygencustomizer,com.luckyzyx.luckytool|2|-1|-|-|-|0' \
    || printf '%s\n' "$st" | grep -qxF 'app|com.example.hooked|normal|normal|hooks|1|1300|2|com.luckyzyx.luckytool,it.dhd.oxygencustomizer|2|-1|-|-|-|0' || fail "one hooked slow launch must keep the normal lift: $st"
  printf '%s\n' "$st" | grep -q '^app|com.example.hookednolaunch|' && fail "fix287: a hooked app never opened is listed or classed: $st"
  printf '%s\n' "$st" | grep -qxF 'app|com.android.settings|normal|normal|excluded|3|1500|0|-|3|-1|-|-|-|0' || fail "excluded row: $st"
  printf '%s\n' "$st" | grep -qxF 'app|com.example.hookedmid|normal|normal|measured|3|800|1|it.dhd.oxygencustomizer|3|-1|-|-|-|0' || fail "measured beats hooks: $st"
  printf '%s\n' "$st" | awk -F'|' '$1 == "app" && NF != 15 { exit 1 }' || fail 'an app row is not 15 fields'
  [ "$(printf '%s\n' "$st" | sed -n '/^app|/{p;q}' | cut -d'|' -f2)" = com.example.slowapp ] || fail "rows not ordered by action, then use: $st"
  ASB_ZL_ROWS=2 run status | grep -c '^app|' | grep -qx 2 || fail 'row cap ignored'
  ls "$T/tmp" | grep -q . && fail "status left temporary files: $(ls "$T/tmp")"
  # fix321: hooks remain context, not an evidence shortcut. The same app earns the long
  # class only after the ordinary three-sample measured median is available.
  printf '%s\n' "$((now+42))|com.example.hooked|1250|1" "$((now+43))|com.example.hooked|1200|1" >> "$T/asb/zygisk_aot_launch"
  out="$(run classes)"; [ "$out" = 'result=written slow=2 fast=2' ] || fail "measured hooked app was not promoted: $out"
  grep -qx 'slow=com.example.hooked' "$C" || fail "three slow hooked launches did not produce the measured class"
  run status | grep -qE '^app\|com\.example\.hooked\|slow\|slow\|measured\|3\|1250\|2\|' || fail "promoted hooked row is not measured: $(run status | grep hooked)"
  printf 'v=1\nslow=com.example.oldstale\n' > "$C"
  run status | grep -qxF 'app|com.example.oldstale|slow|normal|-|0|0|0|-|0|-1|-|-|-|0' || fail "a class in effect without evidence is not shown as changing: $(run status | grep oldstale)"
  printf '%s\n' "$((now+70)).100  1000  1500 I am_proc_start: [0,4001,10201,com.example.newapp,next-top-activity,{com.example.newapp/.Main}]" \
    "$((now+70)).600  1000  1500 I wm_activity_launch_time: [0,111,com.example.newapp/.Main,1500]" > "$T/events"
  run classes --no-scan >/dev/null
  grep -q "|com.example.newapp|" "$T/asb/zygisk_aot_launch" && fail 'the boot-time pass read the log'
  run classes >/dev/null
  grep -q "|com.example.newapp|1500|1" "$T/asb/zygisk_aot_launch" || fail 'without ART the classes pass did not read the launch log'
  [ ! -e "$T/asb/zygisk_aot" ] && [ ! -e "$T/asb/zygisk_aot_apps.new" ] || fail 'the scan enabled or ran ART'
  sed -i 's/^zygisk_launch=1/zygisk_launch=0/' "$T/mod/config/governor.conf"
  out="$(run classes)"; [ "$out" = 'result=absent slow=0 fast=0' ] && [ ! -e "$C" ] || fail "classes survived the lift being switched off: $out"
  [ -s "$T/asb/zygisk_lsposed_modules" ] || fail 'the guard lost the module list with the lift off'
  run status | grep -qx 'classes=absent' || fail 'status after withdraw'
  sed -i 's/^zygisk_launch=0/zygisk_launch=1/' "$T/mod/config/governor.conf"; : > "$T/asb/zygisk_observer/disable"
  out="$(run classes)"; [ "$out" = 'result=absent slow=0 fast=0' ] || fail "safe mode kept classes: $out"
  rm -f "$T/asb/zygisk_observer/disable"
  printf 'format=v1\nmodule|com.luckyzyx.luckytool|0|x\n' > "$T/lspd.out"
  run classes >/dev/null; [ ! -e "$T/asb/zygisk_lsposed_modules" ] || fail 'a disabled module stayed protected'
  printf 'format=v1\nmodule|com.luckyzyx.luckytool|1|x\n' > "$T/lspd.out"; run classes >/dev/null
  # The guard never restricts an enabled LSPosed module app; another user app is not protected by it.
  : > "$T/asb/zygisk_guard"
  g() { PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_ZG_DIR="$T/asb" ASB_ZG_TMP="$T/tmp" ASB_ZYGISK_RUN_DIR="$T/run" ASB_DOZE_KEEP="$T/asb/keep" sh "$ROOT/runtime/asb_zygisk_guard.sh" "$@"; }
  [ "$(g ghost-restrict com.luckyzyx.luckytool)" = result=protected ] || fail 'the guard would restrict an LSPosed module app'
  [ "$(g ghost-restrict com.example.plainapp)" != result=protected ] || fail 'the module list protected an ordinary app'
  out="$(run restore-all)"; [ "$out" = result=removed ] && [ ! -e "$T/asb/zygisk_lsposed_modules" ] || fail "restore-all: $out"
  # Wiring: the policy sync builds or withdraws the classes, the service refreshes them, the
  # uninstaller removes them, the workflows ship the script, asbdiag and the page show it.
  grep -q 'asb_zygisk_link.sh" classes --no-scan' "$ROOT/runtime/asb_zygisk.sh" && grep -q '_zygisk_classes$' "$ROOT/runtime/asb_zygisk.sh" && grep -q 'rm -f "$POLICY" "$POLICY.tmp" "$CLASSES" "$CLASSES.tmp"' "$ROOT/runtime/asb_zygisk.sh" || fail 'sync does not drive the classes'
  grep -q 'asb_zygisk_link.sh" classes' "$ROOT/service.sh" || fail 'no periodic refresh'
  grep -q 'asb_zygisk_link.sh" restore-all' "$ROOT/uninstall.sh" || fail 'uninstall does not clean up'
  grep -q 'runtime/asb_zygisk_link.sh' "$ROOT/.github/workflows/build-test.yml" && grep -q 'runtime/asb_zygisk_link.sh' "$ROOT/.github/workflows/build-release.yml" || fail 'not in the workflow file lists'
  grep -q 'grep -qxF "$1" "$LSPMOD"' "$ROOT/runtime/asb_zygisk_guard.sh" || fail 'guard protection missing'
  grep -q 'link_class :' "$ROOT/tools/asb_diag.sh" && cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail 'asbdiag does not show it'
  grep -Fq "const engine = zygiskLinkCard(); engine.id = 'zy-engine'; body.appendChild(engine);" "$ROOT/webroot/index.html" || fail 'the Zygisk page does not show it'
  echo 'PASS zygisk link: classes from LSPosed scope and measured cold starts, accepted by the native parser, written only on change, withdrawn with the lift or safe mode, LSPosed module apps protected from the guard, per-app evidence'
)

t_zygisk_link_ui_runtime() (
  # fix286: the page parses the engine status defensively and says what each app gets.
  set -eu
  ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  fail() { echo "FAIL zygisk link UI: $*" >&2; exit 1; }
  command -v node >/dev/null 2>&1 || { echo 'SKIP zygisk link UI: no node'; exit 0; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  H="$ROOT/webroot/index.html"
  {
    echo "const T = (k, d) => d;"
    for fn in dozePkgOk zygiskLinkParse zygiskLinkAppValue; do sed -n "/^function $fn(/,/^}/p" "$H"; done
    cat <<'JS'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
const out = [
  'version=1', 'launch=1', 'classes=on', 'classes_slow=3', 'comp_supported=0', 'comp_state=1', 'gov_long=-',
  'zmod|zygisk_lsposed|1|Zygisk - LSPosed', 'zmod|bad id;|1|x', 'zmod|other_x|0|Other <b>x</b>',
  'cmp|1192|2|700|3',
  'app|com.example.slowapp|slow|slow|measured|4|1225|0|-|4|46|-|-|-|0',
  'app|com.example.hooked|slow|fast|hooks|1|900|5|com.a.mod,com.b.mod,com.c.mod|2|-1|loop|speed-profile|notif|0',
  'app|com.luckyzyx.luckytool|normal|normal|-|0|0|0|-|1|-1|-|-|keep|1',
  'app|com.android.settings|normal|slow|excluded|3|1500|0|-|3|-1|-|-|-|0',
  'app|bad pkg|slow|slow|measured|4|1|0|-|4|0|-|-|-|0', 'app|com.x.y|slow|slow|measured|4',
  'classes_at=$(id)'
].join('\n');
const g = zygiskLinkParse(out);
chk(g.ok && g.kv.classes === 'on' && g.kv.comp_supported === '0' && g.kv.gov_long === '-' && !('classes_at' in g.kv), 'kv: ' + JSON.stringify(g.kv));
chk(g.apps.length === 4, 'unsafe rows rejected: ' + g.apps.length);
chk(g.zmods.length === 2 && g.zmods[1].name === 'Other bxb' && !g.zmods[1].on, 'module names sanitized: ' + JSON.stringify(g.zmods));
chk(g.cmp && g.cmp.hooked === 1192 && g.cmp.plainN === 3, 'cmp');
const nm = p => ({ 'com.a.mod': 'Mod A' })[p] || p;
const v0 = zygiskLinkAppValue(g.apps[0], nm);
chk(v0 === 'slow start · median 1225 ms over 4', 'slow app: ' + v0);
const v1 = zygiskLinkAppValue(g.apps[1], nm);
chk(/^slow start · 1 of 3 cold starts measured · next update: fast start · LSPosed: Mod A, com\.b\.mod, com\.c\.mod \+2 · background restricted · ART speed.profile · notification fix$/.test(v1), 'hooked app: ' + v1);
chk(/LSPosed module, never restricted/.test(zygiskLinkAppValue(g.apps[2], nm)) && /Doze keep list/.test(zygiskLinkAppValue(g.apps[2], nm)), 'module app');
const v3 = zygiskLinkAppValue(g.apps[3], nm);
chk(v3 === 'usual start · protected system app, never classed', 'excluded app: ' + v3);
chk(!/%[0-9s]/.test(v0 + v1 + v3), 'placeholder left');
process.exit(bad ? 1 : 0);
JS
  } > "$T/l.js"
  node "$T/l.js" || fail 'parser/value assertions'
  echo 'PASS zygisk link UI: defensive parse, sanitized module names, per-app value text'
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
