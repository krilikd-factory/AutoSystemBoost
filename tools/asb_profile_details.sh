#!/system/bin/sh
# Read-only, on-demand profile explanation. No writer, worker, package listing or
# sensitive identifier collection. Values come from the selected trusted profile and
# the apply ledger's own requested/previous/readback/result evidence.
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
EPOCH_FILE="${ASB_PROFILE_EPOCH_FILE:-/dev/.asb_profile_state/profile_epoch}"
LEDGER="${ASB_LEDGER:-$STATE/apply_ledger}"
PROFILE="${1:-$(cat "$MODDIR/current_profile" 2>/dev/null)}"
case "$PROFILE" in smart|performance|balanced|battery) ;; *) echo '{"error":"unsupported_profile"}'; exit 2 ;; esac
EPOCH="$(cat "$EPOCH_FILE" 2>/dev/null | tr -d ' \r')"
case "$EPOCH" in ''|*[!0-9]*) EPOCH=0 ;; esac

_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r' '  '; }

# Smart starts from the Balanced rails and the governor FSM subsequently owns its
# dynamic state. The WebUI obtains that live ownership from asb_effective_policy.sh.
_intent_profile="$PROFILE"
[ "$_intent_profile" = smart ] && _intent_profile=balanced
_intent_keys='RAVG_TICKS WALT_IDLE WALT_IDLE_CLUST WALT_CLUSTER WALT_CLUSTER_CLUST WALT_COLOC WALT_PIPE WALT_PIPE_NONSP WALT_PIPE_SP WALT_BUSY_HYST WALT_ED_BOOST WALT_TOPAPP_WEIGHT WALT_BOOST_MIN_UTIL WALT_SCHED_BOOST CPU_MIN_LITTLE CPU_MIN_BIG CPU_MAX_LITTLE CPU_MAX_BIG CPU_CAP_LITTLE CPU_CAP_BIG SCHED_RATE SCHED_UP_RATE SCHED_DOWN_RATE SCHED_HISPEED_LOAD SCHED_HISPEED_FREQ UCL_BG_MIN UCL_BG_MAX UCL_FG_MIN UCL_FG_MAX UCL_TOP_MIN UCL_TOP_MAX LATENCY_SENSITIVE GPU_IDLE_TIMER GPU_FORCE_NO_NAP GPU_MIN_PCT GPU_MAX_PCT GPU_MIN_FREQ GPU_MAX_FREQ GPU_BUS_SPLIT GPU_THROTTLING VM_SWAPPINESS VM_DIRTY_EXPIRE VM_DIRTY_WRITEBACK VM_VFS VM_STAT_INTERVAL VM_PAGE_CLUSTER VM_WMARK VM_MINFREE NET_TCP_RMEM NET_TCP_WMEM NET_RMEM_MAX NET_WMEM_MAX NET_OPTMEM_MAX NET_BACKLOG NET_BUDGET NET_BUDGET_USECS NET_DEV_WEIGHT NET_TCP_FASTOPEN NET_TCP_NOTSENT NET_TCP_KEEPIDLE NET_TCP_FIN NET_QDISC NET_UDP_MEM NET_TCP_MTU_PROBING NET_TCP_THIN NET_TCP_RTO_MAX UX_ANIM_SCALE UX_LONG_PRESS UX_MULTI_PRESS UX_ADAPTIVE_BAT UX_RAM_EXPAND UX_LOW_HEAT WIFI_PM_MODE WIFI_TXQLEN WIFI_COUNTRY'

printf '{"schema":1,"profile":"%s","intent_base":"%s","epoch":%s,"intent":[' \
  "$PROFILE" "$_intent_profile" "$EPOCH"
(
  MODDIR="$MODDIR"
  export MODDIR
  # Only ASB's own static, reviewed profile assignment file is sourced. It contains no
  # device writes; generated bounds remain the user's device-specific source of values.
  . "$MODDIR/profiles/$_intent_profile.sh" 2>/dev/null || exit 0
  _first=1
  for _key in $_intent_keys; do
    eval "_value=\${$_key-}"
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"key":"%s","value":"%s"}' "$_key" "$(printf '%s' "$_value" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r' '  ')"
  done
)
printf '],"ledger":'

if [ ! -r "$LEDGER" ]; then
  printf '{"scope":"unavailable","shown":0,"summary":{"applied":0,"already_set":0,"unsupported":0,"not_writable":0,"readback_mismatch":0,"lease_denied":0,"safety_veto":0,"deferred":0},"entries":[]}\n'
else
awk -F'|' -v profile="$PROFILE" -v epoch="$EPOCH" '
function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/," ",s); return s }
{
  line[NR]=$0
  if ($2 == "profile" && $3 == "apply_begin" && $4 == profile) begin=NR
}
END {
  if (!epoch) {
    scope=(NR ? "saved_history" : "unavailable")
    begin=(NR > 80 ? NR-80 : 0)
  } else {
    scope="current_profile_transaction"
    if (!begin) { scope=(NR ? "legacy_recent" : "unavailable"); begin=(NR > 80 ? NR-80 : 0) }
  }
  first=NR-begin+1
  if (first > 120) begin=NR-119
  emitted=0
  for (i=begin+1; i<=NR; i++) {
    n=split(line[i],f,"|")
    if (n < 8 || f[2] == "profile") continue
    result=f[7]
    count[result]++
    rows[emitted]=line[i]
    emitted++
  }
  printf "{\"scope\":\"%s\",\"shown\":%d,\"summary\":{",scope,emitted
  printf "\"applied\":%d,\"already_set\":%d,\"unsupported\":%d,\"not_writable\":%d,",count["applied"],count["already_set"],count["unsupported"],count["not_writable"]
  printf "\"readback_mismatch\":%d,\"lease_denied\":%d,\"safety_veto\":%d,\"deferred\":%d},\"entries\":[",count["readback_mismatch"],count["lease_denied"],count["safety_veto"],count["deferred"]
  for (j=0; j<emitted; j++) {
    split(rows[j],f,"|")
    if (j) printf ","
    printf "{\"ts\":\"%s\",\"domain\":\"%s\",\"key\":\"%s\",\"requested\":\"%s\",\"previous\":\"%s\",\"readback\":\"%s\",\"result\":\"%s\",\"reason\":\"%s\"}",esc(f[1]),esc(f[2]),esc(f[3]),esc(f[4]),esc(f[5]),esc(f[6]),esc(f[7]),esc(f[8])
  }
  printf "]}\n"
}' "$LEDGER" 2>/dev/null
fi
printf ',"io":['
_io_first=1
# loop/ram/zram/device-mapper nodes repeat capability lists but are not ASB storage rails.
for _io_q in /sys/block/*/queue/scheduler; do
  [ -r "$_io_q" ] || continue
  _io_dev="${_io_q#*/sys/block/}"; _io_dev="${_io_dev%%/*}"
  case "$_io_dev" in loop*|ram*|zram*|dm-*) continue ;; esac
  [ -e "/sys/block/$_io_dev/device" ] || continue
  _io_value="$(cat "$_io_q" 2>/dev/null | tr '\n\r' '  ')"
  _io_active="$(printf '%s\n' "$_io_value" | sed -n 's/.*\[\([^][]*\)\].*/\1/p' | head -1)"
  case "$_io_active" in ''|*[!A-Za-z0-9_-]*) _io_active=unknown ;; esac
  [ "$_io_first" = 1 ] || printf ','
  _io_first=0
  printf '{"device":"%s","active":"%s","scheduler":"%s"}' \
    "$(_json "$_io_dev")" "$(_json "$_io_active")" "$(_json "$_io_value")"
done
printf ']}\n'
