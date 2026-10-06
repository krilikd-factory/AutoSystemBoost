#!/usr/bin/env bash
# system-background follows the screen (floor 50 while on), so a screen change is a new
# target, not drift. If flips went through the drift path they would count toward the
# 5-rewrite backoff - never cleared for uclamp nodes - and every few screen cycles leave
# the node stuck at the background ceiling right after screen-on.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL sybg screen-flip contract: $*"; exit 1; }
grep -q 'static int s_sybg_screen = -1;' "$W" || fail "no per-screen memory for the sybg target"
grep -q 'if (_sybg_flip) _ucl_sybg_drift = 0;' "$W" || fail "a screen flip still counts as drift"
grep -q 'force || _ucl_bg_drift || _ucl_sybg_drift || _sybg_flip ||' "$W" || fail "a screen flip does not force the write"
grep -q 's_sybg_screen = fsm_screen_is_on ? 1 : 0;' "$W" || fail "screen state not recorded after the write"
# The floor itself must be applied identically on all three writers of the node.
[ "$(grep -c 'fsm_screen_is_on && _sybg_' "$W")" -ge 4 ] || fail "screen-on floor missing on a sybg writer"
echo "PASS sybg screen-flip contract"
