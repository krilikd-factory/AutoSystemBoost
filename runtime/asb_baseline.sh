# AutoSystemBoost — baseline tracking helpers (V44)
#
# Captures original Android `settings`, persistent props, and pm package
# states the FIRST time ASB modifies each, so uninstall.sh can replay them.
#
# File format: pipe-delimited, append-only, never overwritten on re-write.
#   settings|<namespace>|<key>|<original_value>
#   prop|<key>|<original_value>
#   pm|<package>|<enabled|disabled>
#
# Use these helpers instead of direct `settings put`, `setprop persist.*`,
# or `pm disable-user` for any persistent change. Ephemeral runtime tweaks
# (sysfs writes, transient setprop) don't need baseline tracking.

ASB_BASELINE="/data/adb/asb_baseline.txt"

# Initialise baseline file (create if missing — never wipe existing)
asb_baseline_init() {
  [ -f "$ASB_BASELINE" ] && return 0
  mkdir -p "$(dirname "$ASB_BASELINE")" 2>/dev/null
  : > "$ASB_BASELINE" 2>/dev/null || true
  chmod 0644 "$ASB_BASELINE" 2>/dev/null || true
}

# settings put wrapper with baseline capture
# Usage: asb_settings_put <namespace> <key> <new_value>
asb_settings_put() {
  local _ns="$1" _key="$2" _val="$3"
  [ -z "$_ns" ] || [ -z "$_key" ] && return 1
  asb_baseline_init
  # Capture original ONCE — never overwrite if entry already exists
  if ! grep -qE "^settings\|${_ns}\|${_key}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _orig
    _orig="$(settings get "$_ns" "$_key" 2>/dev/null)"
    [ "$_orig" = "null" ] && _orig=""
    printf 'settings|%s|%s|%s\n' "$_ns" "$_key" "$_orig" >> "$ASB_BASELINE" 2>/dev/null
  fi
  settings put "$_ns" "$_key" "$_val" >/dev/null 2>&1 || true
}

# setprop persist wrapper with baseline capture
# Usage: asb_persist_safe <prop> <new_value>
asb_persist_safe() {
  local _prop="$1" _val="$2"
  [ -z "$_prop" ] && return 1
  asb_baseline_init
  if ! grep -qE "^prop\|${_prop}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _orig
    _orig="$(getprop "$_prop" 2>/dev/null)"
    printf 'prop|%s|%s\n' "$_prop" "$_orig" >> "$ASB_BASELINE" 2>/dev/null
  fi
  setprop "$_prop" "$_val" 2>/dev/null || true
}

# pm disable-user wrapper with baseline capture
# Usage: asb_pm_disable <package>
asb_pm_disable() {
  local _pkg="$1"
  [ -z "$_pkg" ] && return 1
  asb_baseline_init
  if ! grep -qE "^pm\|${_pkg}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _state="disabled"
    pm list packages -e 2>/dev/null | grep -qE "^package:${_pkg}$" && _state="enabled"
    printf 'pm|%s|%s\n' "$_pkg" "$_state" >> "$ASB_BASELINE" 2>/dev/null
  fi
  pm disable-user --user 0 "$_pkg" >/dev/null 2>&1 || true
}

# Replay baseline (used by uninstall.sh)
# Usage: asb_baseline_replay
asb_baseline_replay() {
  [ -f "$ASB_BASELINE" ] || return 0
  while IFS='|' read -r _type _a1 _a2 _a3; do
    case "$_type" in
      settings)
        if [ -z "$_a3" ]; then
          settings delete "$_a1" "$_a2" >/dev/null 2>&1 || true
        else
          settings put "$_a1" "$_a2" "$_a3" >/dev/null 2>&1 || true
        fi
        ;;
      prop)
        if [ -z "$_a2" ]; then
          resetprop --delete "$_a1" >/dev/null 2>&1 || true
        else
          setprop "$_a1" "$_a2" 2>/dev/null || true
        fi
        ;;
      pm)
        [ "$_a2" = "enabled" ] && pm enable --user 0 "$_a1" >/dev/null 2>&1 || true
        ;;
    esac
  done < "$ASB_BASELINE"
}
