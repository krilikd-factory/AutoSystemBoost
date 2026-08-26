#!/system/bin/sh
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
STATE_DIR="/dev/.asb_profile_state"
# The user has now chosen. Clear the "nothing selected" marker so the boot-time restore
# from active_profile starts working again - it is a useful feature once there is a
# choice to preserve, and only wrong before that.
rm -f /data/adb/asb/no_profile_chosen 2>/dev/null
PIDFILE="$STATE_DIR/worker.pid"
EPOCH_FILE="$STATE_DIR/profile_epoch"
EPOCH_LOCK="$STATE_DIR/profile_epoch.lock"
WORKER_LOCK="$STATE_DIR/profile_worker.lock"
LOGFILE="$STATE_DIR/apply_profile.log"
mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true

asb_log() {
  echo "[$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo now)] $*" >> "$LOGFILE" 2>/dev/null || true
}

asb_resolve_moddir() {
  for _d in     "$MODDIR"     "/data/adb/modules/$MODID"     "/data/adb/modules_update/$MODID"     "/data/adb/modules/${MODID}_TMP"     "/data/adb/modules_update/${MODID}_TMP"     /data/adb/modules/*AutoSystemBoost*     /data/adb/modules_update/*AutoSystemBoost*
  do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] && { echo "$_d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(asb_resolve_moddir)"

mkdir -p /data/adb/asb 2>/dev/null

PROFILE_CORE=""
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"
[ -r "$MODDIR/runtime/asb_stock_policy.sh" ] && . "$MODDIR/runtime/asb_stock_policy.sh"
for _pc in "$MODDIR/runtime/profile_core.sh" "$MODDIR/common/profile_core.sh"; do
  [ -r "$_pc" ] && { PROFILE_CORE="$_pc"; break; }
done

MODE="direct"
PROFILE="${1:-balanced}"
PROFILE_FLAG=""
WORKER_EPOCH=""
if [ "$1" = "--worker" ]; then
  MODE="worker"
  PROFILE="${2:-balanced}"
  PROFILE_FLAG="${3:-}"
  WORKER_EPOCH="${4:-}"
else
  PROFILE_FLAG="${2:-}"
fi
case "$PROFILE" in
  stock|performance|balanced|battery)
    : ;;
  smart)
    mkdir -p /data/adb/asb 2>/dev/null
    echo "1" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    if [ ! -r /data/adb/asb/smart_prev_profile ]; then
      _prev_for_save="$(cat "$MODDIR/current_profile" 2>/dev/null)"
      case "$_prev_for_save" in
        battery|balanced|performance) echo "$_prev_for_save" > /data/adb/asb/smart_prev_profile 2>/dev/null ;;
        *) echo "balanced" > /data/adb/asb/smart_prev_profile 2>/dev/null ;;
      esac
    fi
    ;;
  *)
    PROFILE="balanced"
    ;;
esac
# Normalise to one of exactly two words, and never to the empty string.
#
# "" used to mean "the user asked for this", because only apply_profile.sh ever set the
# variable. But service.sh re-applies the profile at boot without going through here, so
# an unset PROFILE_FLAG ALSO means "boot", and downstream code could not tell the two
# apart. profile_core reads it to decide whether it may restart SystemUI - so at boot it
# saw an empty flag, concluded the user had just asked for a profile change, and killed
# SystemUI a minute into startup. Naming the user case explicitly makes "unset" mean
# only what it actually is: nobody asked.
case "$PROFILE_FLAG" in
  auto) : ;;
  *)    PROFILE_FLAG="user" ;;
esac

if [ "$PROFILE" != "smart" ] && [ "$PROFILE_FLAG" != "auto" ]; then
  if [ "$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)" = "1" ]; then
    echo "0" > /data/adb/asb/smart_mode_enabled 2>/dev/null
    rm -f /data/adb/asb/smart_prev_profile 2>/dev/null
  fi
fi

if [ "$PROFILE_FLAG" = "auto" ]; then
  echo "$PROFILE" > /data/adb/asb/auto_switch_marker 2>/dev/null || true
fi

profile_next_epoch() {
  _tries=0
  _retry_sleep="${1:-1}"
  _max_tries="${2:-5}"
  while ! mkdir "$EPOCH_LOCK" 2>/dev/null; do
    _tries=$((_tries + 1))
    [ "$_tries" -ge "$_max_tries" ] && return 1
    sleep "$_retry_sleep"
  done
  _old="$(cat "$EPOCH_FILE" 2>/dev/null)"
  case "$_old" in ''|*[!0-9]*) _old=0 ;; esac
  _next=$((_old + 1))
  printf '%s\n' "$_next" > "$EPOCH_FILE.tmp.$$" 2>/dev/null && mv -f "$EPOCH_FILE.tmp.$$" "$EPOCH_FILE" 2>/dev/null
  rmdir "$EPOCH_LOCK" 2>/dev/null || true
  printf '%s\n' "$_next"
}

profile_epoch_current() {
  _live="$(cat "$EPOCH_FILE" 2>/dev/null)"
  [ -n "$WORKER_EPOCH" ] && [ "$WORKER_EPOCH" = "$_live" ]
}

profile_worker_lock() {
  _tries=0
  while ! mkdir "$WORKER_LOCK" 2>/dev/null; do
    _owner="$(cat "$WORKER_LOCK/pid" 2>/dev/null)"
    if [ -n "$_owner" ] && ! kill -0 "$_owner" >/dev/null 2>&1; then
      rm -rf "$WORKER_LOCK" 2>/dev/null || true
      continue
    fi
    _tries=$((_tries + 1))
    [ "$_tries" -ge 10 ] && return 1
    sleep 1
  done
  printf '%s\n' "$$" > "$WORKER_LOCK/pid" 2>/dev/null
  return 0
}

profile_worker_unlock() {
  rm -rf "$WORKER_LOCK" 2>/dev/null || true
}

kill_prev_worker() {
  [ -r "$PIDFILE" ] || return 0
  _oldpid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$_oldpid" ] && kill -0 "$_oldpid" >/dev/null 2>&1 && kill "$_oldpid" >/dev/null 2>&1 || true
  rm -f "$PIDFILE" >/dev/null 2>&1 || true
}

asb_update_desc_fallback() {
  case "$1" in
    performance) _s='description=status: Performance 🔥 | active ✅' ;;
    battery) _s='description=status: Battery 🔋 | active ✅' ;;
    smart) _s='description=status: Smart Mode 🤖 | active ✅' ;;
    stock) _s='description=status: Stock 👶🏻 | active ✅' ;;
    *) _s='description=status: Balanced ⚖️ | active ✅' ;;
  esac
  sed "s/^description=.*/$_s/g" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null || true
  grep -q '^description=' "$MODDIR/module.prop.tmp" 2>/dev/null && cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
  rm -f "$MODDIR/module.prop.tmp"
}

update_desc_now() {
  if [ -r "$PROFILE_CORE" ]; then
    PROFILE="$PROFILE"
    . "$PROFILE_CORE" >/dev/null 2>&1 || true
    command -v asb_update_desc >/dev/null 2>&1 && {
      asb_update_desc
      return 0
    }
  fi
  asb_update_desc_fallback "$PROFILE"
}

spawn_worker() {
  _epoch="$(profile_next_epoch)" || {
    asb_log "profile transaction failed: epoch lock unavailable"
    return 1
  }
  kill_prev_worker
  nohup /system/bin/sh "$MODDIR/apply_profile.sh" --worker "$PROFILE" "$PROFILE_FLAG" "$_epoch" >/dev/null 2>&1 &
  echo $! > "$PIDFILE" 2>/dev/null || true
  asb_log "scheduled profile=$PROFILE flag=$PROFILE_FLAG epoch=$_epoch moddir=$MODDIR"
}

notify_governor() {
  if [ "$PROFILE" = "stock" ]; then
    command -v asb_stock_enter >/dev/null 2>&1 && asb_stock_enter
    return 0
  fi
  # A non-Stock profile re-enables the native policy engine after a live Stock transition.
  command -v asb_stock_leave >/dev/null 2>&1 && asb_stock_leave
  if command -v asb_stock_start_governor >/dev/null 2>&1; then
    asb_stock_start_governor >/dev/null 2>&1 || asb_log "profile=$PROFILE: governor start pending service watchdog"
  fi
  _gov="$MODDIR/bin/asb"
  [ -x "$_gov" ] || _gov="$MODDIR/bin/$(uname -m)/asb"
  if [ -x "$_gov" ]; then
    if [ "$PROFILE_FLAG" = "auto" ]; then
      "$_gov" "profile:${PROFILE}:auto" >/dev/null 2>&1 &
    else
      "$_gov" "profile:$PROFILE" >/dev/null 2>&1 &
    fi
  fi
}

stock_cancel_pending_worker() {
  # Smart/other profile work may still be applying when the user requests Stock. Advance the
  # epoch with a short bounded lock attempt, then terminate the old worker. Stock has already
  # been persisted before this call, so a worker that wakes in the small race window reads Stock
  # and exits through profile_core's terminal boundary instead of writing another profile.
  profile_next_epoch 0.05 4 >/dev/null 2>&1 || asb_log 'stock: epoch lock busy; terminating previous worker anyway'
  kill_prev_worker
}

quick_return_or_spawn() {
  _prev="$(cat /data/adb/asb/active_profile 2>/dev/null)"
  [ -z "$_prev" ] && _prev="unknown"
  echo "$_prev" > "$STATE_DIR/prev_profile" 2>/dev/null || true
  echo "$PROFILE" > "$MODDIR/current_profile" 2>/dev/null || true
  echo "$PROFILE" > /data/adb/asb/active_profile 2>/dev/null || true

  if [ "$PROFILE" = "stock" ]; then
    # notify_governor performs the complete synchronous Stock transaction: stop ASB, release
    # profile leases and restore the captured profile baseline. Starting the ordinary worker
    # afterwards only repeats that same no-policy branch and can sit behind the old Smart lock.
    stock_cancel_pending_worker
    notify_governor
    update_desc_now
    asb_log 'stock applied immediately; no duplicate profile worker spawned'
    echo "Stock applied: ASB policy stopped"
    exit 0
  fi

  notify_governor
  update_desc_now
  spawn_worker
  echo "Profile scheduled: $PROFILE"
  exit 0
}

run_worker() {
  [ -n "$WORKER_EPOCH" ] || WORKER_EPOCH="$(cat "$EPOCH_FILE" 2>/dev/null)"
  if ! profile_epoch_current; then
    asb_log "worker superseded before start profile=$PROFILE epoch=$WORKER_EPOCH"
    exit 0
  fi
  if ! profile_worker_lock; then
    asb_log "worker deferred: apply lock busy profile=$PROFILE epoch=$WORKER_EPOCH"
    exit 0
  fi
  trap 'profile_worker_unlock' EXIT HUP INT TERM
  if ! profile_epoch_current; then
    asb_log "worker superseded after lock profile=$PROFILE epoch=$WORKER_EPOCH"
    exit 0
  fi
  if [ ! -r "$PROFILE_CORE" ]; then
    asb_log "worker failed: missing profile_core.sh (checked runtime/ and common/)"
    exit 1
  fi

  PROFILE="$PROFILE"
  # profile_core reads PROFILE_FLAG to tell an automatic switch from one the user asked
  # for - it must not restart SystemUI behind their back. Export it so the value is
  # visible to everything sourced below rather than only to this shell.
  export PROFILE_FLAG
  . "$PROFILE_CORE" || {
    asb_log "worker failed: source profile_core"
    exit 1
  }

  if ! command -v asb_apply_profile_once >/dev/null 2>&1; then
    asb_log "worker failed: asb_apply_profile_once missing"
    exit 1
  fi

  _rc=0
  _i=1
  # Stock is a release/restore transaction, not a profile that needs retrying. One guarded
  # pass makes the WebUI change immediate and avoids three needless stop/restore cycles.
  _passes=4
  [ "$PROFILE" = "stock" ] && _passes=1
  while [ "$_i" -le "$_passes" ]; do
    if ! profile_epoch_current; then
      asb_log "worker superseded profile=$PROFILE epoch=$WORKER_EPOCH pass=$_i"
      exit 0
    fi
    PROFILE="$PROFILE"
    asb_apply_profile_once || _rc=1
    sleep 2
    _i=$((_i + 1))
  done
  asb_log "worker done profile=$PROFILE rc=$_rc"

  if [ "$_rc" = "0" ]; then
    _ts="$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || date)"
    _prev="$(cat "$STATE_DIR/prev_profile" 2>/dev/null)"
    [ -z "$_prev" ] && _prev="unknown"
    _trigger="${PROFILE_FLAG:-user}"
    printf '%s\t%s -> %s\ttrigger=%s\n' "$_ts" "$_prev" "$PROFILE" "$_trigger" >> /data/adb/asb/profile_switches.log 2>/dev/null
    rm -f "$STATE_DIR/prev_profile" 2>/dev/null || true
  fi

  exit $_rc
}

[ "$MODE" = "worker" ] && run_worker
quick_return_or_spawn
