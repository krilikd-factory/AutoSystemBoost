#!/system/bin/sh
# /odm runtime binds, applied and then CHECKED.
#
# service.sh used to run "mount --bind payload target" for every manifest line and log
# "odm_bind_late result=applied" when any one of them returned 0. A field diag on a
# OnePlus 15 (KernelSU-Next, NoMount) showed exactly that line for the boot, yet neither
# camera file was in front of the camera: the retouch list read 4 apps in init's
# namespace while the payload had 19, and the tone table was stock. The audio effects
# bind from the same manifest worked, so "applied" was true for one line and said
# nothing about the others.
#
# Each line is now judged by what init's namespace actually reads back after the bind:
#   ok        - content matches the payload
#   already   - it matched before we did anything
#   retry_ok  - the first bind did not show; stale binds on that path were peeled and a
#               fresh one shows
#   hidden    - mount returned success but the path still reads something else
#               (another layer sits in front - logged with the mountinfo line)
#   failed    - mount itself failed
# One log line per target, so the next diag names the file and the reason.
#
#   apply  [camera]   bind every line (or only the camera ones), verify, log
#   status            one line per target: state and what init's namespace reads
# Env overrides (tests): ASB_ODM_MAN, ASB_ODM_LOG, ASB_ODM_MOUNTINFO, ASB_ODM_NS ("none" = run
# commands in this namespace instead of nsenter into init's).

MAN="${ASB_ODM_MAN:-/data/adb/asb/odm_bind_manifest.txt}"
LOG="${ASB_ODM_LOG:-/data/adb/asb/vendor_mounts.log}"
MI="${ASB_ODM_MOUNTINFO:-/proc/1/mountinfo}"

_ns() {
  if [ "${ASB_ODM_NS:-}" != none ] && command -v nsenter >/dev/null 2>&1; then
    nsenter -t 1 -m -- "$@"
  else
    "$@"
  fi
}

_mounted() { grep -qs " $1 " "$MI"; }

_log() { echo "ts=$(date +%s) $*" >> "$LOG" 2>/dev/null; }

_bind() {   # $1 payload $2 target
  _ns mount --bind "$1" "$2" 2>/dev/null && return 0
  mount --bind "$1" "$2" 2>/dev/null
}

_one() {   # $1 target $2 payload -> prints the verdict
  if ! _ns test -f "$1" 2>/dev/null || [ ! -f "$2" ]; then echo missing; return; fi
  if _ns cmp -s "$2" "$1" 2>/dev/null; then echo already; return; fi
  if ! _bind "$2" "$1"; then echo failed; return; fi
  if _ns cmp -s "$2" "$1" 2>/dev/null; then echo ok; return; fi
  # Something in front of the new bind, or an older bind of a stale payload stacked
  # under a layer that wins. Peel what is mounted exactly on this path (bounded: never
  # more than our own few layers) and bind once more.
  _pl=0
  while [ "$_pl" -lt 4 ] && _mounted "$1"; do
    _ns umount "$1" 2>/dev/null || umount "$1" 2>/dev/null || break
    _pl=$((_pl + 1))
  done
  if _bind "$2" "$1" && _ns cmp -s "$2" "$1" 2>/dev/null; then echo retry_ok; return; fi
  echo hidden
}

do_apply() {
  [ -f "$MAN" ] || return 0
  _any=0; _aud=0; _bad=0
  while IFS='|' read -r _t _p; do
    case "$_t" in ''|'#'*) continue ;; esac
    case "$_t" in */camera/*) _is_cam=1 ;; *) _is_cam=0 ;; esac
    [ "${1:-}" = camera ] && [ "$_is_cam" = 0 ] && continue
    _v="$(_one "$_t" "$_p")"
    case "$_v" in
      ok|retry_ok) _any=1; [ "$_is_cam" = 0 ] && _aud=1 ;;
      hidden|failed) _bad=1 ;;
    esac
    if [ "$_v" = hidden ]; then
      _mil="$(grep -s " $_t " "$MI" | tail -n 1 | awk '{print $5, $(NF-2), $(NF-1)}')"
      _log "action=odm_bind_target target=$_t result=hidden mountinfo=${_mil:-none}"
    else
      _log "action=odm_bind_target target=$_t result=$_v"
    fi
  done < "$MAN"
  [ "$_any" = 1 ] && _log "action=odm_bind_late result=applied${1:+ scope=$1}"
  [ "$_bad" = 1 ] && _log "action=odm_bind_late result=incomplete${1:+ scope=$1}"
  # Exit 10 = an audio-side file changed: the caller restarts audioserver for that only.
  [ "$_aud" = 1 ] && return 10
  return 0
}

do_status() {
  [ -f "$MAN" ] || { echo "no manifest"; return 0; }
  while IFS='|' read -r _t _p; do
    case "$_t" in ''|'#'*) continue ;; esac
    if [ ! -f "$_p" ]; then _s=payload_missing
    elif _ns cmp -s "$_p" "$_t" 2>/dev/null; then _s=live
    else _s=NOT_LIVE
    fi
    _m=no; _mounted "$_t" && _m=yes
    echo "$_t state=$_s mounted=$_m"
  done < "$MAN"
}

case "${1:-apply}" in
  apply)  do_apply "${2:-}" ;;
  status) do_status ;;
  *) echo "usage: $0 apply [camera] | status" >&2; exit 2 ;;
esac
