#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# The effective policy extension must remain a JSON-producing observer. It is
# intentionally executable on a host with neither Android properties nor ZRAM.
MODDIR="$ROOT" sh "$ROOT/tools/asb_effective_policy.sh" > "$TMP/effective_policy.json"
python3 - "$TMP/effective_policy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

for section in ("audio", "network", "memory", "asb_overhead"):
    assert section in payload, f"missing {section}"

assert set(("dsp_enabled", "dsp_route_published", "a2dp_offload_requested")) <= set(payload["audio"])
assert set(("congestion_requested", "congestion_result", "qdisc_requested", "qdisc_result")) <= set(payload["network"])
assert set(("psi_some_avg10", "psi_full_avg10", "zram_algorithm", "zram_mm_stat")) <= set(payload["memory"])
PY

# Telemetry is evidence only. No new property, settings, sysctl or ZRAM writer
# may appear in the effective-policy producer or in the added logkit blocks.
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/asb_effective_policy.sh"
! grep -Eq '^[[:space:]]*(setprop|resetprop|sysctl[[:space:]]+-w|settings[[:space:]]+put|swapoff|swapon|mkswap)[[:space:]]' \
  "$ROOT/tools/logkit/_asb_logkit_common.sh"

# The routine captures must disclose requested-versus-live state. A raw property
# alone is not sufficient because it cannot tell a refused kernel write from a
# setting that ASB never requested.
grep -q 'ASB audio / offload provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'ASB network provenance' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'memory PSI (read-only' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'zram\.\$_zf' "$ROOT/tools/logkit/_asb_logkit_common.sh"

# Human and machine diagnostics must expose the same core facts, and the
# installed command must never drift from the source copy.
grep -q 'bt_a2dp_offload: requested=' "$ROOT/tools/asb_diag.sh"
grep -q 'DSP requested/applied gain' "$ROOT/tools/asb_diag.sh"
grep -q 'memory PSI (read-only)' "$ROOT/tools/asb_diag.sh"
grep -q '"audio"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"network"' "$ROOT/tools/asb_effective_policy.sh"
grep -q '"memory"' "$ROOT/tools/asb_effective_policy.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
grep -q 'provenance snapshots' "$ROOT/docs/log_schemas.md"

# A selected throttle point equal to the live CPU maximum is the policy transition edge,
# not evidence that the diagnostic itself failed. Only a strictly hotter live sensor may
# emit the red verdict. A vendor camera file with comments is similarly not proof that ASB
# wrote malformed JSON unless one of ASB's staged payloads is itself commented.
grep -Fq '[ "$_tp_set" -lt "$_tp_now" ]' "$ROOT/tools/asb_diag.sh"
grep -Fq 'boundary observed, not a failure' "$ROOT/tools/asb_diag.sh"
if grep -Fq '[ "$_tp_set" -le "$_tp_now" ]' "$ROOT/tools/asb_diag.sh"; then
  printf '%s\n' 'FAIL asbdiag equality is still a red throttle diagnostic' >&2
  exit 1
fi
grep -q '^camera_json_comment_verdict() {' "$ROOT/tools/asb_diag.sh"
grep -Fq 'ASB-managed camera payload has // comments' "$ROOT/tools/asb_diag.sh"
grep -Fq 'vendor JSON-with-comments:' "$ROOT/tools/asb_diag.sh"
grep -Fq 'ASB did not assert a JSON policy for this live vendor camera domain' "$ROOT/tools/asb_diag.sh"
# Execute the branch in isolation: equality must not call V (the failure printer), while
# a live temperature strictly over the configured point must still do so.
sed -n '/^case "$_tp_set" in/,/^esac$/p' "$ROOT/tools/asb_diag.sh" > "$TMP/throttle_boundary.sh"
[ -s "$TMP/throttle_boundary.sh" ] || { printf '%s\n' 'FAIL asbdiag throttle boundary branch not extracted' >&2; exit 1; }
P(){ printf 'P:%s\n' "$1"; }
NOTE(){ printf 'NOTE:%s\n' "$1"; }
V(){ printf 'V:%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
_tp_set=60 _tp_now=60 _tp_n=1
_boundary_out="$(. "$TMP/throttle_boundary.sh")"
printf '%s\n' "$_boundary_out" | grep -Fq 'boundary observed, not a failure' || { printf '%s\n' 'FAIL asbdiag equality boundary message missing' >&2; exit 1; }
if printf '%s\n' "$_boundary_out" | grep -q '^V:'; then
  printf '%s\n' 'FAIL asbdiag equality invoked red verdict' >&2
  exit 1
fi
_tp_set=60 _tp_now=61 _tp_n=1
_over_out="$(. "$TMP/throttle_boundary.sh")"
printf '%s\n' "$_over_out" | grep -Fq 'V:  throttle point below live CPU sensor' || { printf '%s\n' 'FAIL asbdiag strictly-over-threshold sensor lost verdict' >&2; exit 1; }
# Exercise camera provenance without Android paths. A commented live vendor file is INFO
# when ASB carries no malformed payload; a commented ASB payload remains a V failure.
sed -n '/^camera_json_comment_verdict() {/,/^}/p' "$ROOT/tools/asb_diag.sh" > "$TMP/camera_json_verdict.sh"
[ -s "$TMP/camera_json_verdict.sh" ] || { printf '%s\n' 'FAIL asbdiag camera JSON helper not extracted' >&2; exit 1; }
MODDIR="$TMP/module"
LIVE="$TMP/live_camera/video_beauty_default_config"
mkdir -p "$(dirname "$LIVE")" "$MODDIR/system/odm$(dirname "$LIVE")"
printf '// vendor comment\n{}\n' > "$LIVE"
. "$TMP/camera_json_verdict.sh"
_vendor_out="$(camera_json_comment_verdict "$LIVE")"
printf '%s\n' "$_vendor_out" | grep -Fq 'vendor JSON-with-comments:' || { printf '%s\n' 'FAIL asbdiag vendor comment was not informational' >&2; exit 1; }
if printf '%s\n' "$_vendor_out" | grep -q '^V:'; then
  printf '%s\n' 'FAIL asbdiag vendor comment emitted a malformed-ASB verdict' >&2
  exit 1
fi
printf '// broken staged payload\n{}\n' > "$MODDIR/system/odm$LIVE"
_managed_out="$(camera_json_comment_verdict "$LIVE")"
printf '%s\n' "$_managed_out" | grep -Fq 'V:  ASB-managed camera payload has // comments' || { printf '%s\n' 'FAIL asbdiag malformed ASB camera payload lost verdict' >&2; exit 1; }

# Conservative offload semantics must stay conservative.
#
# A review found this contract had lost its offload assertions at the same time the code
# lost the behaviour - so the suite went green on a regression it was written to catch. A
# test deleted alongside its feature proves nothing, which makes these three lines the
# actual protection rather than the code comment above them.
#
# Assert on the SHAPE of the verdict, not on wording: it must be able to say "unknown", and
# it must not conclude offload from an AudioFlinger thread alone.
grep -q 'offload state:' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_verdict="unknown"' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_route' "$ROOT/tools/asb_diag.sh"
grep -q '_ev_play' "$ROOT/tools/asb_diag.sh"
# The bare form - verdict set from the thread with no corroboration - is the regression.
if grep -qE '^\s*\[ -n "\$_ev_af" \] && _ev_verdict=' "$ROOT/tools/asb_diag.sh"; then
  printf '%s\n' 'FAIL offload verdict taken from AudioFlinger thread alone' >&2
  exit 1
fi
# Every capture must carry the same field, or an A/B experiment has nothing to compare -
# and it must apply the SAME rule as the manual report.
#
# Tightening asbdiag while leaving logkit on the old one-signal logic is exactly what
# happened once: the hand-run report became honest while every full-day archive kept
# claiming offload from an uncorroborated thread. These assertions exist so the two copies
# cannot drift apart again without the suite saying so.
grep -q 'offload.state' "$ROOT/tools/logkit/_asb_logkit_common.sh"
# Assert the corroborating signals by their real names.
#
# My first version of this test looked for _lk_route and _lk_play - variables from my own
# implementation. The deployed build reaches the same conclusion through LK_AUDIO_ROUTE and
# LK_AUDIO_PLAY, and is stricter still: it also reports "conflicting" when a thread exists
# while a property says offload is blocked. Testing for my variable names would have failed
# the better implementation, which is a good reminder that a contract should describe
# behaviour, not the author who wrote it first.
grep -q 'LK_AUDIO_ROUTE' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'LK_AUDIO_PLAY' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'conflicting AudioFlinger' "$ROOT/tools/logkit/_asb_logkit_common.sh"
# The bare form - verdict from the thread with nothing corroborating it - is the regression.
if grep -qE 'offload.state = offload thread present"' "$ROOT/tools/logkit/_asb_logkit_common.sh"; then
  printf '%s\n' 'FAIL logkit offload verdict taken from AudioFlinger thread alone' >&2
  exit 1
fi

# The reconnect recorder must survive merges.
#
# It was present in the deployed 507 build and absent from the source for three rounds -
# nobody noticed until an audit compared the two. These assertions cover the functions, the
# default full-day enablement, and every call site, so a future merge that drops it fails here
# instead of in a user's log six hours into a capture.
grep -q 'ASB_BT_RECONNECT_TRACE' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -Fq ': "${ASB_BT_RECONNECT_TRACE:=1}"' "$ROOT/tools/logkit/asb_log_full_day.sh"
grep -q 'lk_bt_reconnect_start' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'lk_bt_reconnect_snapshot' "$ROOT/tools/logkit/_asb_logkit_common.sh"
grep -q 'lk_bt_reconnect_stop' "$ROOT/tools/logkit/_asb_logkit_common.sh"
_bt_calls="$(grep -c 'lk_bt_reconnect_' "$ROOT/tools/logkit/asb_log_full_day.sh")"
if [ "$_bt_calls" -lt 6 ]; then
  printf '%s\n' "FAIL reconnect recorder call sites: found $_bt_calls, expected 6" >&2
  exit 1
fi
grep -q 'Bluetooth lifecycle recorder' "$ROOT/docs/log_schemas.md"
grep -q 'bt_lifecycle_events.tsv' "$ROOT/docs/log_schemas.md"
grep -q 'bt_lifecycle_context.tsv' "$ROOT/docs/log_schemas.md"

printf '%s\n' 'PASS donor telemetry contract'
