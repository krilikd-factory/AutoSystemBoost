
# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

ASB_BASELINE="/data/adb/asb/baseline.txt"

asb_baseline_init() {
  [ -f "$ASB_BASELINE" ] && return 0
  mkdir -p "$(dirname "$ASB_BASELINE")" 2>/dev/null
  : > "$ASB_BASELINE" 2>/dev/null || true
  chmod 0644 "$ASB_BASELINE" 2>/dev/null || true
}

# Load the apply ledger if it is present. Sourced rather than required: a stripped build
# or an old install must keep working, just without the extra record.
if ! command -v asb_ledger_settings >/dev/null 2>&1; then
  for _lgp in "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_apply_ledger.sh" \
              "$(dirname "$0")/asb_apply_ledger.sh"; do
    [ -f "$_lgp" ] && . "$_lgp" && break
  done
fi

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
  # Record what the device actually did with it.
  #
  # The `|| true` below is deliberate and stays: one rejected key must not abort a profile
  # apply. But swallowing the result also meant a write the ROM ignored looked identical
  # to one that took effect, and the WebUI would report "on" either way. The ledger is
  # where that difference now lives; the control flow is unchanged.
  if command -v asb_ledger_settings >/dev/null 2>&1; then
    asb_ledger_settings "$_ns" "$_key" "$_val" "" || true
  else
    settings put "$_ns" "$_key" "$_val" >/dev/null 2>&1 || true
  fi
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
