#!/bin/sh
# Contract: full-day Bluetooth lifecycle telemetry is read-only, bounded, privacy-aware and
# distinguishes literal reconnect evidence from phase/route snapshots.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
FULL="$ROOT/tools/logkit/asb_log_full_day.sh"
DOC="$ROOT/docs/log_schemas.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL BT lifecycle recorder: $*" >&2; exit 1; }
[ -f "$COMMON" ] || fail "common logkit missing"
[ -f "$FULL" ] || fail "full-day recorder missing"
sh -n "$COMMON" || fail "common shell syntax"
sh -n "$FULL" || fail "full-day shell syntax"

# Source pure helper definitions. No capture is started by sourcing common.
# shellcheck disable=SC1090
. "$COMMON"
LK_OUT_DIR="$TMP"
LK_BT_RECONNECT_EVENTS="$TMP/bt_lifecycle_events.tsv"
LK_BT_RECONNECT_CONTEXT="$TMP/bt_lifecycle_context.tsv"
LK_BT_RECONNECT_SNAPSHOTS="$TMP/bt_lifecycle_snapshots.txt"
LK_BT_RECONNECT_EVENT_COUNT=0
LK_BT_RECONNECT_MAX_EVENTS=3
printf '%s\n' '# epoch<TAB>iso_utc<TAB>event<TAB>source' > "$LK_BT_RECONNECT_EVENTS"

[ "$(lk_bt_lifecycle_kind '1.0 AdapterService: reconnect requested')" = "reconnect_literal" ] || fail "literal reconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 HeadsetService: disconnectAudio: device AA:BB:CC:DD:EE:FF')" = "hfp_audio_disconnect" ] || fail "HFP audio detach classification"
[ "$(lk_bt_lifecycle_kind '1.0 HeadsetService: connectAudio: device AA:BB:CC:DD:EE:FF')" = "hfp_audio_connect" ] || fail "HFP audio attach classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: connectionStateChanged, state: 2->3')" = "a2dp_profile_disconnect" ] || fail "A2DP profile disconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: connectionStateChanged, state: 1->2')" = "a2dp_profile_connect" ] || fail "A2DP profile connect classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: device disconnected')" = "disconnect_generic" ] || fail "generic disconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 AdapterService: connected state=2')" = "connect_generic" ] || fail "generic connect classification"
[ -z "$(lk_bt_lifecycle_kind 'feature disconnect_hid_channels_serially=true')" ] || fail "V63 static feature false positive"
[ -z "$(lk_bt_lifecycle_kind 'Devices: bt_a2dp(80)')" ] || fail "route snapshot must not become event"

# No raw line, BT address, or device name is written. The file is a four-column evidence TSV.
lk_bt_lifecycle_record '1787300000.100 HeadsetService: disconnectAudio: device AA:BB:CC:DD:EE:FF PixelBuds'
lk_bt_lifecycle_record '1787300001.100 A2dpService: connectionStateChanged, device AA:BB:CC:DD:EE:FF, state: 2->3 PixelBuds'
lk_bt_lifecycle_record '1787300002.100 HeadsetService: reconnect requested AA:BB:CC:DD:EE:FF PixelBuds'
[ "$(awk '!/^#/ {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 3 ] || fail "event persistence count"
awk -F'\t' '!/^#/ { if (NF != 4 || $3 !~ /^(hfp_audio_disconnect|a2dp_profile_disconnect|reconnect_literal)$/) exit 1 }' "$LK_BT_RECONNECT_EVENTS" || fail "event TSV shape"
! grep -Eq 'AA:BB:CC:DD:EE:FF|PixelBuds|device ' "$LK_BT_RECONNECT_EVENTS" || fail "raw identifier leaked"

# Reaching the cap stops rather than continually consuming the all-day log stream.
if lk_bt_lifecycle_record '1787300003.100 AdapterService: connected'; then
  fail "event cap should return stop status"
else
  [ "$?" = 2 ] || fail "event cap returned wrong status"
fi
[ "$(awk '!/^#/ {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 3 ] || fail "cap wrote extra event"

# Context is intentionally separate and can be written without device services on host.
LK_BT_RECONNECT_ENABLED=1
LK_AUDIO_PLAY=1
LK_AUDIO_ROUTE=bt
lk_get_prop() { printf '%s' ''; }
dumpsys() { :; }
settings() { :; }
lk_bt_reconnect_snapshot 'phase:audio_bt'
awk -F '\t' '$3=="phase:audio_bt" && $4=="1" && $5=="bt" {ok=1} END{exit !ok}' "$LK_BT_RECONNECT_CONTEXT" || fail "route context missing"

# Full-day capture turns trace on by default; still allowing an explicit opt-out is essential.
grep -Fq ': "${ASB_BT_RECONNECT_TRACE:=1}"' "$FULL" || fail "default lifecycle trace missing"
grep -Fq 'ASB_BT_RECONNECT_TRACE=0' "$FULL" || fail "explicit opt-out documentation missing"
grep -Fq 'bt_lifecycle_events.tsv' "$FULL" || fail "report lacks lifecycle events reference"
grep -Fq 'bt_lifecycle_context.tsv' "$FULL" || fail "report lacks lifecycle context reference"
grep -Fq 'HFP/SCO audio-link detach, not proof that the' "$COMMON" || fail "HFP versus device disconnect boundary missing"
grep -Fq 'a2dp_profile_disconnect' "$FULL" || fail "A2DP summary boundary missing"
grep -Fq 'disconnect_hid_channels_serially' "$COMMON" || fail "V63 false positive exclusion missing"
grep -Fq 'Bluetooth lifecycle recorder' "$DOC" || fail "schema documentation missing"
grep -Fq 'bt_lifecycle_events.tsv' "$DOC" || fail "event schema missing"
grep -Fq 'bt_lifecycle_context.tsv' "$DOC" || fail "context schema missing"

echo 'PASS Bluetooth lifecycle recorder contract'
