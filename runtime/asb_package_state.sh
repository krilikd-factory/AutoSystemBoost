#!/system/bin/sh
# Shared, read-only PackageManager state parsers and exact state restoration helpers.
# No account, serial, IMEI or network identifiers are read or retained.

asb_pkg_present() {
  pm list packages 2>/dev/null | grep -Fqx "package:$1"
}

# Print COMPONENT_ENABLED_STATE_* for user 0, or return 1 when it is not exposed.
asb_pkg_enabled() {
  awk '
    /^[[:space:]]*User 0:/ { in0=1 }
    /^[[:space:]]*User [0-9]+:/ { if ($0 !~ /^[[:space:]]*User 0:/ && in0) exit }
    in0 && match($0, /enabled=[0-9]+/) {
      s=substr($0, RSTART, RLENGTH); sub(/^enabled=/, "", s); print s; found=1; exit
    }
    END { if (!found) exit 1 }
  ' "$1" 2>/dev/null
}

# Print 1 when hidden, 0 when visible; absence of a user-state value is unknown.
asb_pkg_hidden() {
  awk '
    /^[[:space:]]*User 0:/ { in0=1 }
    /^[[:space:]]*User [0-9]+:/ { if ($0 !~ /^[[:space:]]*User 0:/ && in0) exit }
    in0 && match($0, /hidden=(true|false)/) {
      s=substr($0, RSTART, RLENGTH); sub(/^hidden=/, "", s); print (s == "true" ? 1 : 0); found=1; exit
    }
    END { if (!found) exit 1 }
  ' "$1" 2>/dev/null
}

# Component enabled state. PackageManager exposes the two override sets: membership in
# neither means COMPONENT_ENABLED_STATE_DEFAULT. If both sets are not exposed, the state is
# unknown rather than guessed to be default.
asb_component_enabled() {
  _ace_dump="$1" _ace_pkg="$2" _ace_class="$3"
  awk -v pkg="$_ace_pkg" -v cls="$_ace_class" '
    BEGIN {
      short=cls
      if (index(cls, pkg ".") == 1) short="." substr(cls, length(pkg) + 2)
      full_class=pkg "/" cls
      short_class=pkg "/" short
      state=0
    }
    {
      key=$1
      if (key == "disabledComponents:") { section=2; seen_d=1; next }
      if (key == "enabledComponents:")  { section=1; seen_e=1; next }
      if (key ~ /:$/) { section=0; next }
      if (!section) next
      c=key
      if (c == cls || c == full_class || c == short_class || c == short) state=section
    }
    END {
      if (!seen_d || !seen_e) exit 1
      print state
    }
  ' "$_ace_dump" 2>/dev/null
}

asb_pkg_restore_enabled() {
  _pre_state="$1" _pre_pkg="$2" _pre_user="${3:-0}"
  case "$_pre_state" in
    0) pm default-state      --user "$_pre_user" "$_pre_pkg" >/dev/null 2>&1 ;;
    1) pm enable             --user "$_pre_user" "$_pre_pkg" >/dev/null 2>&1 ;;
    2) pm disable            --user "$_pre_user" "$_pre_pkg" >/dev/null 2>&1 ;;
    3) pm disable-user       --user "$_pre_user" "$_pre_pkg" >/dev/null 2>&1 ;;
    4) pm disable-until-used --user "$_pre_user" "$_pre_pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

asb_pkg_restore_hidden() {
  _prh_state="$1" _prh_pkg="$2" _prh_user="${3:-0}"
  case "$_prh_state" in
    0) pm unhide --user "$_prh_user" "$_prh_pkg" >/dev/null 2>&1 ;;
    1) pm hide   --user "$_prh_user" "$_prh_pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
