
ASB_BASELINE="/data/adb/asb/baseline.txt"

asb_baseline_init() {
  [ -f "$ASB_BASELINE" ] && return 0
  mkdir -p "$(dirname "$ASB_BASELINE")" 2>/dev/null
  : > "$ASB_BASELINE" 2>/dev/null || true
  chmod 0644 "$ASB_BASELINE" 2>/dev/null || true
}

asb_settings_put() {
  local _ns="$1" _key="$2" _val="$3"
  [ -z "$_ns" ] || [ -z "$_key" ] && return 1
  asb_baseline_init
  if ! grep -qE "^settings\|${_ns}\|${_key}\|" "$ASB_BASELINE" 2>/dev/null; then
    local _orig
    _orig="$(settings get "$_ns" "$_key" 2>/dev/null)"
    [ "$_orig" = "null" ] && _orig=""
    printf 'settings|%s|%s|%s\n' "$_ns" "$_key" "$_orig" >> "$ASB_BASELINE" 2>/dev/null
  fi
  settings put "$_ns" "$_key" "$_val" >/dev/null 2>&1 || true
}

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
          resetprop -p --delete "$_a1" >/dev/null 2>&1 || resetprop --delete "$_a1" >/dev/null 2>&1 || true
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
