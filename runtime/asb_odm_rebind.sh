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

MD="${ASB_ODM_MODDIR:-${MODDIR:-/data/adb/modules/AutoSystemBoost}}"

# Camera payloads follow the module's own copy.
#
# The payload under /data/adb/asb/odm_patched was written once, at install, and nothing
# refreshed it: a field diag showed the module copy graded (BlendWeight 1, 1, 1) while the
# bound payload held the stock table (0.35, 0.5, 0.7) - the bind was perfect and delivered
# the wrong file. The module copy is the one post-fs-data re-grades from the stock baseline
# with the current settings on every boot, so it is the source of truth; the payload is
# rewritten in place (same inode), which also updates a bind that is already mounted.
_sync_payload() {   # $1 target $2 payload
  case "$1" in
    */odm/etc/camera/*) _rel="${1#*/odm/etc/camera/}" ;;
    *) return 0 ;;
  esac
  for _src in "$MD/odm/etc/camera/$_rel" "$MD/system/odm/etc/camera/$_rel" \
              "$MD/system/vendor/odm/etc/camera/$_rel"; do
    [ -s "$_src" ] && break
    _src=""
  done
  [ -n "$_src" ] && [ -f "$2" ] || return 0
  # Whole-line // comments are stripped on the way, as the installer does: the payload is
  # meant to be strict JSON, and a module copy that kept them must not undo that.
  if grep -q '^[[:space:]]*//' "$_src" 2>/dev/null; then
    _clean="$2.sync.$$"
    sed -e '/^[[:space:]]*\/\//d' -e 's#[[:space:]]//[^"]*$##' "$_src" > "$_clean" 2>/dev/null \
      || { rm -f "$_clean"; return 0; }
    _src="$_clean"
  fi
  if cmp -s "$_src" "$2" 2>/dev/null; then rm -f "$2.sync.$$"; return 0; fi
  # Same structural gate the overlay guard applies to every payload.
  _so="$(tr -cd '{' < "$_src" 2>/dev/null | wc -c)"
  _sc="$(tr -cd '}' < "$_src" 2>/dev/null | wc -c)"
  [ "$_so" = "$_sc" ] && [ "${_so:-0}" -gt 0 ] 2>/dev/null || { rm -f "$2.sync.$$"; _log "action=odm_payload_sync target=$1 result=rejected_unbalanced"; return 0; }
  if cat "$_src" > "$2" 2>/dev/null; then
    _log "action=odm_payload_sync target=$1 result=updated"
    _synced=1
  else
    _log "action=odm_payload_sync target=$1 result=write_failed"
  fi
  rm -f "$2.sync.$$" 2>/dev/null
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
  _any=0; _aud=0; _bad=0; _camnew=0
  while IFS='|' read -r _t _p; do
    case "$_t" in ''|'#'*) continue ;; esac
    case "$_t" in */camera/*) _is_cam=1 ;; *) _is_cam=0 ;; esac
    [ "${1:-}" = camera ] && [ "$_is_cam" = 0 ] && continue
    _synced=0
    [ "$_is_cam" = 1 ] && _sync_payload "$_t" "$_p"
    _v="$(_one "$_t" "$_p")"
    # A payload rewritten under a bind that was already in place reads "already", yet the
    # camera now sees new content - count it as a change.
    [ "$_synced" = 1 ] && [ "$_v" = already ] && _camnew=1
    case "$_v" in
      ok|retry_ok) _any=1; if [ "$_is_cam" = 0 ]; then _aud=1; else _camnew=1; fi ;;
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
  # A camera file that changed under a running camera stack: the provider may hold the
  # table it read at start. Restart it (and cameraserver) once - only at boot, where the
  # caller asks for it and nobody is in the camera yet; the action screen never does.
  if [ "$_camnew" = 1 ] && [ "${ASB_ODM_RESTART_CAM:-0}" = 1 ]; then
    for _svc in $(getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\(vendor\.camera[^]]*provider[^]]*\)\]: \[running\]$/\1/p'); do
      setprop ctl.restart "$_svc" 2>/dev/null
    done
    setprop ctl.restart cameraserver 2>/dev/null
    _log "action=odm_bind_late camera_stack=restarted"
  fi
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

# Effects-config crash fuse.
#
# fix73 registers the DSP in the effects config a HIDL audio HAL actually reads
# (/odm/etc/audio_effects.xml on SM8650). That is the first time the library is loaded by
# that HAL generation, and a library the HAL cannot take shows up as audioserver dying over
# and over - no sound, and SystemUI/camera stalling behind it - while the phone itself
# boots fine, so the boot fuse never sees it.
# Watched for a few minutes after boot: three or more audioserver restarts while an
# effects config is bound means the effect goes. Every effects-config line leaves the
# manifest and is unmounted, a flag stops the next install from registering it again, and
# audioserver is restarted once on stock configs.
# audioserver and the HAL that loads effects: a library the HAL cannot take kills the HAL,
# and audioserver follows it. A poll counts once when either pid moved to a new value; a
# pid missing mid-restart is not a change (it would double-count one restart).
_hal_pid() {
  for _an in audiohalservice.qti android.hardware.audio.service \
             android.hardware.audio.service_64; do
    _hp="$(pidof "$_an" 2>/dev/null | awk '{print $1}')"
    [ -n "$_hp" ] && { echo "$_hp"; return 0; }
  done
  echo ""
}

do_effects_guard() {
  grep -q 'audio_effects' "$MAN" 2>/dev/null || return 0
  _polls="${ASB_ODM_GUARD_POLLS:-18}"; _gap="${ASB_ODM_GUARD_SLEEP:-10}"
  _la="$(pidof audioserver 2>/dev/null | awk '{print $1}')"; _lh="$(_hal_pid)"
  _deaths=0; _i=0
  while [ "$_i" -lt "$_polls" ]; do
    sleep "$_gap"
    _na="$(pidof audioserver 2>/dev/null | awk '{print $1}')"; _nh="$(_hal_pid)"
    _moved=0
    [ -n "$_na" ] && [ -n "$_la" ] && [ "$_na" != "$_la" ] && _moved=1
    [ -n "$_nh" ] && [ -n "$_lh" ] && [ "$_nh" != "$_lh" ] && _moved=1
    [ "$_moved" = 1 ] && _deaths=$((_deaths + 1))
    [ -n "$_na" ] && _la="$_na"
    [ -n "$_nh" ] && _lh="$_nh"
    _i=$((_i + 1))
  done
  if [ "$_deaths" -lt 3 ]; then
    _log "action=effects_guard result=stable restarts=$_deaths"
    return 0
  fi
  _keep="$MAN.keep.$$"; true > "$_keep"
  while IFS='|' read -r _t _p; do
    case "$_t" in
      */audio_effects*.xml)
        _pl=0
        while [ "$_pl" -lt 4 ] && _mounted "$_t"; do
          _ns umount "$_t" 2>/dev/null || umount "$_t" 2>/dev/null || break
          _pl=$((_pl + 1))
        done
        rm -f "$_p" 2>/dev/null
        _log "action=effects_guard target=$_t result=unbound" ;;
      '') ;;
      *) echo "$_t|$_p" >> "$_keep" ;;
    esac
  done < "$MAN"
  if [ -s "$_keep" ]; then cat "$_keep" > "$MAN"; else rm -f "$MAN"; fi
  rm -f "$_keep" 2>/dev/null
  echo "ts=$(date +%s) restarts=$_deaths" > "${ASB_ODM_STATE:-/data/adb/asb}/dsp_effects_blocked" 2>/dev/null
  _log "action=effects_guard result=tripped restarts=$_deaths"
  setprop ctl.restart audioserver 2>/dev/null
  return 0
}

case "${1:-apply}" in
  apply)  do_apply "${2:-}" ;;
  status) do_status ;;
  effects-guard) do_effects_guard ;;
  *) echo "usage: $0 apply [camera] | status | effects-guard" >&2; exit 2 ;;
esac
