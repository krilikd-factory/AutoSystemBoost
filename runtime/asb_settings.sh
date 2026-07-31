#!/system/bin/sh
# asb_settings.sh - read and write Settings, with a fallback for devices where the
# `settings` command cannot reach the service.
#
# WHY THIS EXISTS
#
# On a OnePlus 15R every settings call in the diagnostic came back as:
#
#   cmd: Failure calling service settings: Failed transaction (2147483646)
#
# Not one setting, not one feature - every single one. Bluetooth absolute volume, RAM
# expand, adaptive battery, the lockscreen skip, all of it. The binary is present and
# exits 0, so nothing noticed: `settings put` looked like it worked and `settings get`
# returned the error text as though it were a value. Several tweaks were quietly doing
# nothing on that device and reporting success.
#
# `content` talks to the same settings provider over a different path and works where the
# cmd bridge does not, so it is the fallback rather than a second-best.
#
# Source it:  . "$MODDIR/runtime/asb_settings.sh"
# Then use:   asb_set_get secure lockscreen.disabled
#             asb_set_put secure lockscreen.disabled 1
#             asb_set_del secure lockscreen.disabled
#             asb_set_ok            # 0 if either mechanism works at all

# A reply is only a value if it is not one of the framework's failure strings. Treating
# "Failure calling service" as data is what let the breakage go unseen.
# Every call to the real binary in this file goes through `command`, because the wrapper at
# the bottom shadows the name - without it these helpers would call themselves forever.
_asb_set_clean() {
  case "$1" in
    *'Failure calling service'*|*'Exception occurred'*|*'Error:'*|*'Can'\''t find service'*)
      return 1 ;;
  esac
  printf '%s' "$1"
  return 0
}

# Strip the metadata newer Android appends to a value.
#
# On Android 15 `settings get` answers "1, is_preserved_in_restore=true" rather than "1".
# Every comparison in this module is against a bare value, so each one silently failed:
# the lock delay parsed as non-numeric and became 0 ("instant lock, refusing"), and the
# read-back of a value that HAD been written compared unequal and reported "the ROM did
# not keep the value". Both were false. Cut at the first comma-space.
_asb_set_bare() {
  case "$1" in
    *", is_preserved_in_restore="*) printf '%s' "${1%%, is_preserved_in_restore=*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

asb_set_get() {   # $1=namespace $2=key
  _r="$(command settings get "$1" "$2" 2>/dev/null)"
  if _asb_set_clean "$_r" >/dev/null 2>&1; then
    case "$_r" in null|'') printf '' ;; *) printf '%s' "$(_asb_set_bare "$_r")" ;; esac
    return 0
  fi
  # Fallback: query the provider directly. Its output is "Row: 0 value=X", so pull the tail.
  _r="$(content query --uri "content://settings/$1" --where "name='$2'" 2>/dev/null \
        | sed -n 's/.*value=\(.*\)$/\1/p' | head -1)"
  case "$_r" in
    *'Failure'*|*'Error'*) printf '' ;;
    *) printf '%s' "$_r" ;;
  esac
}

asb_set_put() {   # $1=namespace $2=key $3=value
  command settings put "$1" "$2" "$3" >/dev/null 2>&1
  # Verify rather than trust the exit code: the command exits 0 on this failure.
  if [ "$(asb_set_get "$1" "$2")" = "$3" ]; then
    return 0
  fi
  content insert --uri "content://settings/$1" \
    --bind name:s:"$2" --bind value:s:"$3" >/dev/null 2>&1
  [ "$(asb_set_get "$1" "$2")" = "$3" ]
}

asb_set_del() {   # $1=namespace $2=key
  command settings delete "$1" "$2" >/dev/null 2>&1
  [ -z "$(asb_set_get "$1" "$2")" ] && return 0
  content delete --uri "content://settings/$1" --where "name='$2'" >/dev/null 2>&1
  [ -z "$(asb_set_get "$1" "$2")" ]
}

# Can Settings be reached at all? Read a key every Android has. Used to tell "this tweak
# failed" apart from "nothing on this device can be set", which need different messages.
asb_set_ok() {
  _p="$(command settings get system screen_off_timeout 2>/dev/null)"
  _asb_set_clean "$_p" >/dev/null 2>&1 && [ -n "$(_asb_set_bare "$_p")" ] && return 0
  _p="$(content query --uri content://settings/system --where "name='screen_off_timeout'" 2>/dev/null \
        | sed -n 's/.*value=\(.*\)$/\1/p' | head -1)"
  [ -n "$_p" ]
}

# --- transparent wrapper ------------------------------------------------------------------
#
# Shadowing the command itself, rather than rewriting sixty-odd call sites.
#
# The calls in this module come in every shape: quoted keys, keys from loop variables,
# values from variables, `|| true` tails, results piped into files. Rewriting each one to
# asb_set_* would have been sixty chances to get an argument wrong for no behavioural gain.
# A function named `settings` is found before the binary by every one of them, so they all
# get the fallback with no edit at all.
#
# `command settings` is what actually runs the binary - calling `settings` in here would
# recurse forever. Anything that is not get/put/delete is passed straight through.
settings() {
  case "$1" in
    get)
      shift
      [ "$#" -ge 2 ] && asb_set_get "$1" "$2" || command settings get "$@"
      ;;
    put)
      shift
      if [ "$#" -ge 3 ]; then
        asb_set_put "$1" "$2" "$3"
      else
        command settings put "$@"
      fi
      ;;
    delete)
      shift
      [ "$#" -ge 2 ] && asb_set_del "$1" "$2" || command settings delete "$@"
      ;;
    *)
      command settings "$@"
      ;;
  esac
}
