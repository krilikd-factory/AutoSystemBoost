#!/bin/sh
# Runtime (fix141): watchers the WebUI starts leave the manager app's cgroups.
#
# OP15 capture 2830: the recorder ran all night in "cpuset:/top-app cpu:/top-app memory:/apps"
# and reported cgroup_escape=not_needed. The video-refresh, Wi-Fi fallback and LTE light
# watchers are started from the WebUI the same way when their switch is turned on.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL cgroup detach: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
. "$ROOT/runtime/asb_cgroup.sh"
true > "$T/r1"; true > "$T/r2"
# The capture's own cgroup file, v1 groups of the foreground app, v2 root.
printf '5:freezer:/\n4:memory:/apps\n3:cpuset:/top-app\n2:cpu:/top-app\n1:blkio:/\n0::/\n' > "$T/cg"
out="$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1 $T/r2 $T/absent" asb_cgroup_detach 777)"
[ "$(cat "$T/r1")" = 777 ] && [ "$(cat "$T/r2")" = 777 ] || fail "pid not written to every writable root"
# The fixture still lists top-app (nothing really moved it): reported as partial, not moved.
[ "$out" = partial:2 ] || fail "top-app left behind reported as '$out'"
printf '0::/uid_10853/pid_4242\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1" asb_cgroup_detach 778)" = failed ] || fail "still in uid_ not reported as failed"
printf '0::/\n3:cpuset:/\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/r1" asb_cgroup_detach 779)" = not_needed ] || fail "a boot-started process moved"
# A move the kernel accepted: the cgroup file no longer names an app group afterwards.
printf '3:cpuset:/top-app\n' > "$T/cg"
[ "$(ASB_CG_FILE="$T/cg" ASB_CG_ROOTS="$T/cg" asb_cgroup_detach 780)" = moved:1 ] || fail "an accepted move not reported"

# The logkit's copy follows the same rule.
out="$( (set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$ROOT/tools/logkit/_asb_logkit_common.sh" >/dev/null 2>&1
         printf '4:memory:/apps\n3:cpuset:/top-app\n0::/\n' > "$T/cg"
         ASB_LK_CG_FILE="$T/cg" ASB_LK_CG_ROOTS="$T/r1" lk_escape_app_cgroup 781) )"
[ "$out" = partial:1 ] || fail "logkit still calls a top-app recorder not_needed ($out)"

# Wiring: every watcher the WebUI can start detaches before it forks.
for f in asb_ltpo_video.sh asb_wifi_fallback.sh asb_lte_screenoff.sh; do
  grep -q 'asb_cgroup_detach \$\$' "$ROOT/runtime/$f" || fail "$f does not leave the app cgroups"
done
[ "$(grep -c 'asb_cgroup_detach \$\$' "$ROOT/runtime/asb_ltpo_video.sh")" -ge 2 ] || fail "video watcher: reconcile and watch both detach"
echo "PASS cgroup detach: WebUI-started watchers and the recorder leave the app's cgroups"
