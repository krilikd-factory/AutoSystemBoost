#!/system/bin/sh
# asb_doze_apply.sh - how quickly Android puts the phone into deep sleep when it is idle.
#
# WHY THIS ONE
#
# The full-day capture from an OP15 showed the idle phase sitting at 45.5% CPU-awake over
# 116 minutes, against the report's own target of under 5%. The wakelock ranking named only
# ordinary Android and GMS components - nothing the module could switch off. What CAN be
# moved is when the framework stops letting them run at all, and that is Doze.
#
# Doze is Android's own mechanism, so this is not a workaround: it just stops waiting so
# long before using it. Stock waits 30 minutes of screen-off before even entering INACTIVE,
# which on a phone picked up every few minutes is 30 minutes that never elapse.
#
#   doze_level = stock | moderate | aggressive
#
#   stock       the key is deleted and Android's own timings apply. Nothing is changed.
#   moderate    idle begins after 5 minutes instead of 30. The change most people want.
#   aggressive  2 minutes, and the sensing and locating windows are shortened too.
#
# THE COST, PLAINLY
#
# In Doze the system batches background work and holds most network access until the next
# maintenance window. That is exactly where the saving comes from, and it is also why chat
# messages can arrive late. Apps using high-priority FCM still break through - that is the
# path Android guarantees - but an app that polls on its own will be delayed. If messages
# arriving on time matters more than standby drain, stock is the right answer.
#
# Everything is one Settings.Global key, so leaving is deleting it: no residue.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"

[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_lvl="$(_cfg doze_level)"
case "$_lvl" in stock|moderate|aggressive) : ;; *) _lvl=stock ;; esac

# Only the timings that decide WHEN idle starts. Deliberately not touching the maintenance
# window lengths or the quota constants: those govern how much work gets done once idle,
# and shrinking them is how you turn "battery saving" into "my alarms stopped firing".
case "$_lvl" in
  moderate)
    _c="inactive_to=300000,idle_after_inactive_to=300000,motion_inactive_to=300000"
    ;;
  aggressive)
    _c="inactive_to=120000,idle_after_inactive_to=120000,motion_inactive_to=120000,sensing_to=60000,locating_to=15000"
    ;;
esac

if [ "$_lvl" = "stock" ]; then
  if [ -n "$(asb_set_get global device_idle_constants)" ]; then
    asb_set_del global device_idle_constants
    echo "doze: stock - Android's own timings, nothing set by ASB"
  else
    echo "doze: stock (nothing had been set)"
  fi
  exit 0
fi

if asb_set_put global device_idle_constants "$_c"; then
  case "$_lvl" in
    moderate)   echo "doze: moderate - idle begins after 5 minutes of screen-off instead of 30" ;;
    aggressive) echo "doze: aggressive - idle after 2 minutes; background messages may arrive late" ;;
  esac
else
  # Some ROMs guard this key. Say so rather than leaving the card looking applied - the
  # value not sticking is indistinguishable from success unless it is read back.
  echo "doze: this ROM refused the setting - Android's own timings still apply"
fi
exit 0
