#!/usr/bin/env sh
# tests/test_arbiter.sh — lease priority and camera ownership regression.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_arbiter.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export ASB_ARBITER_DIR="$TMP/leases"
export ASB_ARBITER_EVENTS="$TMP/events.jsonl"
export ASB_ARBITER_LOCK="$TMP/leases/.lock"
export ASB_CAMERA_GUARD="$TMP/camera_guard"
# Sourced: command-mode dispatcher is intentionally not invoked.
# shellcheck disable=SC1091
. "$ROOT_DIR/runtime/asb_arbiter.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

asb_arbiter_claim cpu_cap profile 30 60 profile_apply || fail 'profile cpu_cap claim'
asb_arbiter_can_write cpu_cap profile || fail 'same owner may write'
if asb_arbiter_can_write cpu_cap smart; then fail 'lower Smart owner bypassed profile lease'; fi
asb_arbiter_can_write cpu_cap safety || fail 'safety owner could not preempt profile'
asb_arbiter_claim cpu_cap safety 80 60 thermal_guard || fail 'safety preemption failed'
if asb_arbiter_can_write cpu_cap profile; then fail 'profile bypassed safety lease'; fi

# A zero-TTL lease is immediately expired and must not block a later normal claim.
asb_arbiter_claim temporary user_cap 40 0 one_shot || fail 'zero ttl claim failed'
asb_arbiter_can_write temporary smart || fail 'expired lease blocked Smart owner'

: > "$ASB_CAMERA_GUARD"
if asb_arbiter_can_write cpuset_fg profile; then fail 'profile bypassed camera cpuset lease'; fi
if asb_arbiter_can_write uclamp_max profile; then fail 'profile bypassed camera uclamp lease'; fi
asb_arbiter_can_write cpuset_fg camera || fail 'camera could not own cpuset'
asb_arbiter_can_write uclamp_max camera || fail 'camera could not own uclamp'
rm -f "$ASB_CAMERA_GUARD"
asb_arbiter_can_write cpuset_fg profile || fail 'profile remained blocked after camera release'

asb_arbiter_claim cpuset_fg profile 30 60 profile_apply || fail 'cpuset profile claim'
asb_arbiter_note cpuset_fg profile profile_apply 0-7 0-7 applied || fail 'lease applied note'
LEASE="$ASB_ARBITER_DIR/cpuset_fg.lease"
grep -qx 'desired=0-7' "$LEASE" || fail 'desired state missing'
grep -qx 'applied=0-7' "$LEASE" || fail 'applied state missing'
grep -qx 'last_error=none' "$LEASE" || fail 'last error state missing'
grep -q '"action":"claim"' "$ASB_ARBITER_EVENTS" || fail 'claim telemetry missing'
grep -q '"resource":"cpuset_fg"' "$ASB_ARBITER_EVENTS" || fail 'write telemetry missing'

echo 'PASS arbiter'
