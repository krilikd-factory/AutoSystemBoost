#!/bin/sh
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
