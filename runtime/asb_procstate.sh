#!/system/bin/sh
# asb_procstate.sh - what Android thinks of an app's processes right now. Sourced.
#
# Several trims act only on apps the user has left ("cached"). They used to decide that by
# grepping `dumpsys activity processes <pkg>` for the first of cached|foreground|...; the
# per-process dump carries a "cached=false" field on every record, so the first word found
# was "cached" for running apps of any state - and nothing at all when the format changed.
#
# `dumpsys activity lru` prints one line per process with the adjustment label the
# scheduler is actually using ("#12: cch+5 CEM ---- 4567:com.foo/u0a200"): cch* is cached,
# svc/svcb/prev are background work, everything else (fg, vis, prcp, fgs, home, pers...)
# is something the user can see or hear. An unfamiliar layout yields "unknown", and every
# caller treats unknown as "do not touch".

# Load once per run; callers may reuse $_ASB_LRU.
asb_lru_load() {
  _ASB_LRU="$(dumpsys activity lru 2>/dev/null | grep -E '^[[:space:]]*#[0-9]+: ')"
}

# asb_pkg_proc_class <pkg> -> none | cached | background | active | unknown
asb_pkg_proc_class() {
  [ -n "${_ASB_LRU:-}" ] || { echo unknown; return 0; }
  printf '%s\n' "$_ASB_LRU" | awk -v p="$1" '
    { for (i = 3; i <= NF; i++)
        if (index($i, ":" p "/") || index($i, ":" p ":")) { seen = 1; l = $2
          if (l ~ /^(cch|cac|empt)/) c = (c == "" ? "cached" : c)
          else if (l ~ /^(svcb|svc|prev)$/) { if (c != "active") c = "background" }
          else c = "active"
          break } }
    END { print (seen ? c : "none") }'
}

# asb_pkg_uid <pkg> -> uid, or nothing. The data directory is owned by the app uid on
# every Android version; `dumpsys package` printed "userId=" until Android 12 and
# "appId=" after, which is why parsing it alone stopped working.
asb_pkg_uid() {
  _pu="$(stat -c %u "/data/data/$1" 2>/dev/null)"
  case "$_pu" in ''|*[!0-9]*|0) _pu="" ;; esac
  if [ -z "$_pu" ]; then
    _pu="$(dumpsys package "$1" 2>/dev/null \
           | sed -n -e 's/^[[:space:]]*appId=\([0-9][0-9]*\).*/\1/p' \
                   -e 's/^[[:space:]]*userId=\([0-9][0-9]*\).*/\1/p' | head -1)"
  fi
  [ -n "$_pu" ] && echo "$_pu"
}
