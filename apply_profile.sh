#!/system/bin/sh
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
STATE_DIR="/dev/.asb_profile_state"
PIDFILE="$STATE_DIR/worker.pid"
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

PROFILE_CORE=""
for _pc in "$MODDIR/runtime/profile_core.sh" "$MODDIR/common/profile_core.sh"; do
  [ -r "$_pc" ] && { PROFILE_CORE="$_pc"; break; }
done

MODE="direct"
PROFILE="${1:-balanced}"
PROFILE_FLAG=""
[ "$1" = "--worker" ] && { MODE="worker"; PROFILE="${2:-balanced}"; PROFILE_FLAG="${3:-}"; }
[ "$MODE" = "direct" ] && PROFILE_FLAG="${2:-}"
case "$PROFILE" in
  performance|balanced|battery) : ;;
  *) PROFILE="balanced" ;;
esac
case "$PROFILE_FLAG" in
  auto) : ;;
  *) PROFILE_FLAG="" ;;
esac

kill_prev_worker() {
  [ -r "$PIDFILE" ] || return 0
  _oldpid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$_oldpid" ] && kill -0 "$_oldpid" >/dev/null 2>&1 && kill "$_oldpid" >/dev/null 2>&1 || true
  rm -f "$PIDFILE" >/dev/null 2>&1 || true
}

asb_update_desc_fallback() {
  case "$1" in
    performance) _s='description=status: performance 🔥 | active ✅' ;;
    battery) _s='description=status: battery 🔋 | active ✅' ;;
    *) _s='description=status: balanced ⚖️ | active ✅' ;;
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
  kill_prev_worker
  nohup /system/bin/sh "$MODDIR/apply_profile.sh" --worker "$PROFILE" "$PROFILE_FLAG" >/dev/null 2>&1 &
  echo $! > "$PIDFILE" 2>/dev/null || true
  asb_log "scheduled profile=$PROFILE flag=$PROFILE_FLAG moddir=$MODDIR"
}

notify_governor() {
  # Tell governor about the profile change immediately, instead of waiting
  # for asb_reconcile.sh to poll-detect (which can take 45-600s). Without this,
  # the C-side FSM uses old profile_idx during the lag — wrong bounds applied,
  # session metrics attributed to wrong profile, state file shows stale profile.
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

quick_return_or_spawn() {
  echo "$PROFILE" > "$MODDIR/current_profile" 2>/dev/null || true
  notify_governor
  update_desc_now
  spawn_worker
  echo "Profile scheduled: $PROFILE"
  exit 0
}

run_worker() {
  if [ ! -r "$PROFILE_CORE" ]; then
    asb_log "worker failed: missing profile_core.sh (checked runtime/ and common/)"
    exit 1
  fi

  PROFILE="$PROFILE"
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
  while [ "$_i" -le 4 ]; do
    PROFILE="$PROFILE"
    asb_apply_profile_once || _rc=1
    sleep 2
    _i=$((_i + 1))
  done
  asb_log "worker done profile=$PROFILE rc=$_rc"
  exit $_rc
}

[ "$MODE" = "worker" ] && run_worker
quick_return_or_spawn
