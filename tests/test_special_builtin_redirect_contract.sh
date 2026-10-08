#!/bin/sh
# Contract: no ": > file" in device scripts. ":" is a special builtin, and a failed
# redirect on one aborts the script under mksh and POSIX shells (asbdiag stopped at line 34
# when /sdcard was missing). "true > file" fails only the command.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bad="$(cd "$ROOT" && grep -nE '(^|[;&|{(]|[[:space:]]):[[:space:]]*>>?[[:space:]]*["$/]' \
        runtime/*.sh tools/*.sh tools/logkit/*.sh common/*.sh action.sh service.sh post-fs-data.sh uninstall.sh apply_profile.sh customize.sh system/bin/asbdiag 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
if [ -n "$bad" ]; then printf 'FAIL special-builtin redirect:\n%s\n' "$bad" >&2; exit 1; fi
echo "PASS special-builtin redirect contract"
