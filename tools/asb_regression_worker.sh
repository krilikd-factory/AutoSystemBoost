#!/usr/bin/env bash
# Host test supervisor. Each test owns a process group, so the timeout handler
# can record a bounded, argument-free process snapshot before stopping it.
set -u
setsid "$@" &
worker=$!
stop_worker() {
  trap '' USR1 TERM INT
  printf '\nTIMEOUT process group %s (pid ppid pgid state wait-channel):\n' "$worker" >&2
  snapshot="$(ps -eo pid=,ppid=,pgid=,stat=,wchan= 2>/dev/null | awk -v pg="$worker" '$3 == pg { print; if (++n >= 100) exit }')"
  printf '%s\n' "$snapshot" >&2
  # Counts only: FD targets and command lines can contain test or user data.
  while read -r pid _; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if [ -r "/proc/$pid/fd" ]; then
      count="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
      printf 'pid=%s open_fds=%s\n' "$pid" "$count" >&2
    fi
  done <<< "$snapshot"
  kill -TERM -- "-$worker" 2>/dev/null || true
  sleep 0.2
  kill -KILL -- "-$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  exit 124
}
trap stop_worker USR1 TERM INT
wait "$worker"
exit $?
