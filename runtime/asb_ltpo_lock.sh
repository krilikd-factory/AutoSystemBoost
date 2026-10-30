#!/system/bin/sh
# Shared, small critical section for the LTPO video ownership record and its
# peak_refresh_rate write. mkdir is atomic on Android; no flock dependency.
# The caller MUST release the lock on every path. A dead owner's lock is reclaimed;
# a live or unreadable owner is never stolen, so concurrent writers fail closed.

ASB_LTPO_LOCK_DIR="${ASB_LTPO_LOCK_DIR:-$STATE_DIR/ltpo_video.lock}"

asb_ltpo_lock() {
  _al_try=0
  while ! mkdir "$ASB_LTPO_LOCK_DIR" 2>/dev/null; do
    _al_owner="$(cat "$ASB_LTPO_LOCK_DIR/pid" 2>/dev/null | tr -dc '0-9')"
    case "$_al_owner" in
      '')
        # mkdir and the pid write are separate operations. Give a live creator several
        # rounds to publish its pid; only a persistently ownerless lock is reclaimed.
        if [ "$_al_try" -ge 5 ] && [ ! -e "$ASB_LTPO_LOCK_DIR/pid" ]; then
          rmdir "$ASB_LTPO_LOCK_DIR" 2>/dev/null || true
        fi
        ;;
      *[!0-9]*)
        # Corrupt ownership is not proof that the writer is dead: fail closed.
        ;;
      *)
        if ! kill -0 "$_al_owner" 2>/dev/null; then
          rm -f "$ASB_LTPO_LOCK_DIR/pid" 2>/dev/null
          rmdir "$ASB_LTPO_LOCK_DIR" 2>/dev/null || true
          continue
        fi
        ;;
    esac
    _al_try=$((_al_try + 1))
    [ "$_al_try" -lt 50 ] || return 1
    # Old sleep implementations may reject fractions. The bounded integer fallback
    # is slower only on those ROMs and preserves mutual exclusion.
    sleep 0.05 2>/dev/null || sleep 1
  done
  if ! printf '%s\n' "$$" > "$ASB_LTPO_LOCK_DIR/pid" 2>/dev/null; then
    rmdir "$ASB_LTPO_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  return 0
}

asb_ltpo_unlock() {
  rm -f "$ASB_LTPO_LOCK_DIR/pid" 2>/dev/null
  rmdir "$ASB_LTPO_LOCK_DIR" 2>/dev/null || true
}

# Replace only the restore target, preserving every other ownership field. The
# rename prevents diagnostic readers from observing a partially written record.
asb_ltpo_set_orig() {
  _aso_file="$1"
  _aso_value="$2"
  _aso_tmp="$_aso_file.$$"
  if sed "s/^orig=.*/orig=$_aso_value/" "$_aso_file" 2>/dev/null > "$_aso_tmp" && \
     [ -s "$_aso_tmp" ] && mv -f "$_aso_tmp" "$_aso_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$_aso_tmp" 2>/dev/null
  return 1
}
