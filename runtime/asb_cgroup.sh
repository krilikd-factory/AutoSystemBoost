#!/system/bin/sh
# asb_cgroup.sh - sourced, not run. Puts a long-running ASB helper where the boot-started
# ones live (fix141).
#
# A watcher started from the WebUI inherits the cgroups of the root manager that ran the
# command. OP15 capture 2830 recorded its own: "cpuset:/top-app cpu:/top-app memory:/apps" -
# the foreground app's groups, all night: every core including the prime, top-app's
# uclamp.min boost on each wake-up, the app memcg. The video-refresh watcher, the Wi-Fi
# fallback watcher and the LTE light-traffic loop are started from the WebUI the same way
# when their switch is turned on. On a manager whose WebUI commands run inside the app
# process (seen with KernelSU without -Next) it is worse: the cached-app freezer stops the
# app's group when the manager goes to the background and ActivityManager kills it with the
# app - the logkit found that first (fix67), with a "24 h" capture that held ten minutes of
# samples. A video-refresh watcher frozen while it holds the panel at 60 Hz keeps it there
# until the manager is opened again or the phone reboots.
#
# Moving the process to each hierarchy's root is exactly where ASB's daemons started at
# boot already are; children forked afterwards follow. Prints moved:<n>, not_needed,
# partial:<n> (an app group the kernel did not let go - cpuset/cpuctl/memcg) or failed
# (still in the app's uid_ group, the one that freezes and kills).
asb_cgroup_detach() {
  _acd_pid="${1:-$$}"
  _acd_cg="${ASB_CG_FILE:-/proc/$_acd_pid/cgroup}"
  grep -qE 'uid_[0-9]+|/apps|/top-app|/foreground|frozen' "$_acd_cg" 2>/dev/null || { echo not_needed; return 0; }
  _acd_n=0
  for _acd_g in ${ASB_CG_ROOTS:-/sys/fs/cgroup/cgroup.procs /acct/cgroup.procs /dev/freezer/cgroup.procs \
      /dev/cpuset/cgroup.procs /dev/cpuctl/cgroup.procs /dev/memcg/cgroup.procs /dev/stune/cgroup.procs}; do
    [ -w "$_acd_g" ] || continue
    echo "$_acd_pid" > "$_acd_g" 2>/dev/null && _acd_n=$((_acd_n + 1))
  done
  if grep -qE 'uid_[0-9]+' "$_acd_cg" 2>/dev/null; then echo failed
  elif grep -qE '/apps|/top-app|/foreground' "$_acd_cg" 2>/dev/null; then echo "partial:$_acd_n"
  else echo "moved:$_acd_n"; fi
}
