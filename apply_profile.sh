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

MODE="direct"
PROFILE="${1:-balanced}"
[ "$1" = "--worker" ] && { MODE="worker"; PROFILE="${2:-balanced}"; }
case "$PROFILE" in
  performance|balanced|battery) : ;;
  *) PROFILE="balanced" ;;
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
  if [ -r "$MODDIR/common/profile_core.sh" ]; then
    PROFILE="$PROFILE"
    . "$MODDIR/common/profile_core.sh" >/dev/null 2>&1 || true
    command -v asb_update_desc >/dev/null 2>&1 && {
      asb_update_desc
      return 0
    }
  fi
  asb_update_desc_fallback "$PROFILE"
}

spawn_worker() {
  kill_prev_worker
  nohup /system/bin/sh "$MODDIR/apply_profile.sh" --worker "$PROFILE" >/dev/null 2>&1 &
  echo $! > "$PIDFILE" 2>/dev/null || true
  asb_log "scheduled profile=$PROFILE moddir=$MODDIR"
}

quick_return_or_spawn() {
  echo "$PROFILE" > "$MODDIR/current_profile" 2>/dev/null || true
  update_desc_now
  spawn_worker
  echo "Profile scheduled: $PROFILE"
  exit 0
}

run_worker() {
  if [ ! -r "$MODDIR/common/profile_core.sh" ]; then
    asb_log "worker failed: missing $MODDIR/common/profile_core.sh"
    exit 1
  fi

  PROFILE="$PROFILE"
  . "$MODDIR/common/profile_core.sh" || {
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
