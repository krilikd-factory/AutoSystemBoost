#!/system/bin/sh
# ASB V48 — Smart Mode toggle/reset/status command
#
# Usage (as root):
#   sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh status
#   sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh enable
#   sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh disable
#   sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh reset
#
# Commands:
#   status   show current state (flag + bucket store info)
#   enable   set smart_mode_enabled=1 (governor picks up on next read)
#   disable  set smart_mode_enabled=0 + restore manual profile from smart_prev_profile
#   reset    delete buckets.bin + buckets.bin.bak — all learning lost, defaults reseeded on next boot

ASB_DIR="/data/adb/asb"
MOD_DIR="/data/adb/modules/AutoSystemBoost"
FLAG="$ASB_DIR/smart_mode_enabled"
PREV="$ASB_DIR/smart_prev_profile"
STORE="$ASB_DIR/buckets.bin"
BAK="$ASB_DIR/buckets.bin.bak"

usage() {
  cat <<HELP
ASB V48 Smart Mode control

Usage: sh $0 <command>

Commands:
  status   Show current Smart Mode state
  enable   Enable Smart Mode (adaptive blend battery↔balanced)
  disable  Disable Smart Mode (revert to manual profile)
  reset    Erase all learned bucket data (defaults reseeded on next boot)
HELP
}

cmd_status() {
  echo "=== ASB Smart Mode status ==="
  if [ -r "$FLAG" ]; then
    _en=$(cat "$FLAG" 2>/dev/null)
    case "$_en" in
      1) echo "  Smart Mode: ENABLED" ;;
      0) echo "  Smart Mode: DISABLED" ;;
      *) echo "  Smart Mode: unknown (flag value '$_en')" ;;
    esac
  else
    echo "  Smart Mode: not yet initialized (no flag file)"
  fi
  if [ -r "$PREV" ]; then
    echo "  Prev profile: $(cat "$PREV" 2>/dev/null)"
  fi
  if [ -r "$STORE" ]; then
    _size=$(wc -c < "$STORE" 2>/dev/null)
    echo "  Bucket store: $STORE ($_size bytes)"
  else
    echo "  Bucket store: not present (will be seeded on next boot)"
  fi
  if [ -r "$BAK" ]; then
    _size=$(wc -c < "$BAK" 2>/dev/null)
    echo "  Backup store: $BAK ($_size bytes)"
  fi
  if [ -r /dev/.asb/state ]; then
    echo ""
    echo "=== Runtime state (from /dev/.asb/state) ==="
    grep -E '^smart_' /dev/.asb/state | head -20
  fi
}

cmd_enable() {
  mkdir -p "$ASB_DIR" 2>/dev/null
  _cur_profile=$(cat "$MOD_DIR/current_profile" 2>/dev/null)
  [ -z "$_cur_profile" ] && _cur_profile=balanced

  # Save current profile for restore-on-disable, unless already saved
  if [ ! -r "$PREV" ]; then
    case "$_cur_profile" in
      battery|balanced|performance) echo "$_cur_profile" > "$PREV" 2>/dev/null ;;
      *) echo "balanced" > "$PREV" 2>/dev/null ;;
    esac
  fi

  # Set the master file flag
  echo "1" > "$FLAG" 2>/dev/null
  if [ ! -r "$FLAG" ] || [ "$(cat "$FLAG" 2>/dev/null)" != "1" ]; then
    echo "ERROR: could not write $FLAG"
    return 1
  fi

  # Switch persisted profile to 'smart' so C-side read_profile_idx() picks it up
  echo "smart" > "$MOD_DIR/current_profile" 2>/dev/null
  echo "smart" > "$ASB_DIR/active_profile" 2>/dev/null

  # Notify the running governor via socket (instant effect, no restart needed)
  _gov="$MOD_DIR/bin/asb"
  [ -x "$_gov" ] || _gov="$MOD_DIR/bin/$(uname -m)/asb"
  if [ -x "$_gov" ]; then
    "$_gov" "profile:smart" >/dev/null 2>&1 &
    echo "✓ Smart Mode ENABLED"
    echo "  prev_profile saved: $(cat "$PREV" 2>/dev/null)"
    echo "  current_profile → smart (notified governor via socket)"
  else
    echo "✓ Smart Mode flag set, but governor binary not found at $_gov"
    echo "  Restart module to activate, or reboot."
  fi
}

cmd_disable() {
  mkdir -p "$ASB_DIR" 2>/dev/null
  echo "0" > "$FLAG" 2>/dev/null
  if [ ! -r "$FLAG" ] || [ "$(cat "$FLAG" 2>/dev/null)" != "0" ]; then
    echo "ERROR: could not write $FLAG"
    return 1
  fi
  _prev=""
  [ -r "$PREV" ] && _prev=$(cat "$PREV" 2>/dev/null)
  case "$_prev" in
    battery|balanced|performance)
      echo "$_prev" > "$MOD_DIR/current_profile" 2>/dev/null
      echo "$_prev" > "$ASB_DIR/active_profile" 2>/dev/null
      _gov="$MOD_DIR/bin/asb"
      [ -x "$_gov" ] || _gov="$MOD_DIR/bin/$(uname -m)/asb"
      if [ -x "$_gov" ]; then
        "$_gov" "profile:$_prev" >/dev/null 2>&1 &
      fi
      echo "✓ Smart Mode DISABLED, profile restored to: $_prev (governor notified)"
      ;;
    *)
      echo "WARN: no valid prev profile saved, leaving current profile unchanged"
      echo "  manually set with: echo balanced > $MOD_DIR/current_profile"
      ;;
  esac
}

cmd_reset() {
  if [ ! -r "$STORE" ] && [ ! -r "$BAK" ]; then
    echo "Already clean — no bucket store to delete."
    return 0
  fi
  printf "This will ERASE all Smart Mode learning. Continue? (y/N): "
  read _ans
  case "$_ans" in
    y|Y|yes|YES)
      rm -f "$STORE" "$BAK" 2>/dev/null
      echo "✓ Bucket store deleted. Defaults will reseed on next governor restart."
      ;;
    *)
      echo "Aborted."
      ;;
  esac
}

case "${1:-status}" in
  status)   cmd_status ;;
  enable)   cmd_enable ;;
  disable)  cmd_disable ;;
  reset)    cmd_reset ;;
  help|-h|--help) usage ;;
  *)
    echo "Unknown command: $1"
    echo ""
    usage
    exit 1
    ;;
esac
