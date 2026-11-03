#!/system/bin/sh
# Shared, small critical section for the LTPO video ownership record and its
# peak_refresh_rate write. An atomic symlink publishes the owner PID in the same
# operation that claims the slot; no flock or separately initialized pid file.
# The caller MUST release the lock on every path. A dead owner's lock is reclaimed;
# a live, ownerless or unreadable owner is never stolen, so writers fail closed.

ASB_LTPO_LOCK_DIR="${ASB_LTPO_LOCK_DIR:-$STATE_DIR/ltpo_video.lock}"

asb_ltpo_lock() {
  _al_try=0
  while ! ln -s "$$" "$ASB_LTPO_LOCK_DIR" 2>/dev/null; do
    # Read locks left by the pre-symlink implementation during a live module update.
    # A legacy ownerless directory is not provably dead and is therefore never reaped.
    if [ -L "$ASB_LTPO_LOCK_DIR" ]; then
      _al_owner="$(readlink "$ASB_LTPO_LOCK_DIR" 2>/dev/null)"
    elif [ -d "$ASB_LTPO_LOCK_DIR" ]; then
      _al_owner="$(cat "$ASB_LTPO_LOCK_DIR/pid" 2>/dev/null)"
    else
      _al_owner=""
    fi
    case "$_al_owner" in
      ''|*[!0-9]*)
        # Missing or corrupt ownership is not proof that the writer is dead.
        ;;
      *)
        if ! kill -0 "$_al_owner" 2>/dev/null; then
          # Reclaim the whole dead lock atomically. The quarantine name is private to
          # this contender; the live path never passes through an ownerless state.
          _al_dead="$ASB_LTPO_LOCK_DIR.dead.$$"
          rm -rf "$_al_dead" 2>/dev/null
          if mv "$ASB_LTPO_LOCK_DIR" "$_al_dead" 2>/dev/null; then
            rm -rf "$_al_dead" 2>/dev/null
          fi
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
  return 0
}

asb_ltpo_unlock() {
  [ -L "$ASB_LTPO_LOCK_DIR" ] || return 0
  _al_owner="$(readlink "$ASB_LTPO_LOCK_DIR" 2>/dev/null)"
  # Never remove a lock now owned by another writer. The normal release is one atomic
  # rename of the already-owned symlink, with no uninitialized interval.
  [ -n "$_al_owner" ] && [ "$_al_owner" = "$$" ] || return 0
  _al_release="$ASB_LTPO_LOCK_DIR.release.$$"
  rm -rf "$_al_release" 2>/dev/null
  if mv "$ASB_LTPO_LOCK_DIR" "$_al_release" 2>/dev/null; then
    rm -rf "$_al_release" 2>/dev/null
  fi
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
