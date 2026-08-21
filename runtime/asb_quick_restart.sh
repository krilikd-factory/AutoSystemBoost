#!/system/bin/sh
# ASB quick restart helper.
#
# A normal reboot crosses bootloader, kernel and every Android boot stage; those timings are
# owned by the device firmware and must not be shortened by killing services or changing boot
# properties. This helper deliberately offers only supported *runtime* restart paths:
#
#   userspace  - Android's own userspace reboot when init explicitly advertises support.
#   unavailable - no destructive fallback; the WebUI keeps the normal full reboot available.
#
# A direct Zygote restart is intentionally not used as a fallback. It is not Android's documented
# userspace-reboot path and cannot prove that every vendor dependency was restarted cleanly.
# No persistent property is written. No process is killed directly.
set -u

prop() { getprop "$1" 2>/dev/null | tr -d '\r\n'; }
reply() { printf '%s\n' "$1"; }

boot_completed="$(prop sys.boot_completed)"
case "$boot_completed" in
  1) ;;
  *) reply 'mode=unavailable reason=boot_not_completed'; exit 3 ;;
esac

userspace_supported="$(prop init.userspace_reboot.is_supported)"
case "$userspace_supported" in
  1|true|TRUE|yes|YES) reply 'mode=userspace reason=init_supported' ;;
  *) reply 'mode=unavailable reason=userspace_not_supported'; exit 3 ;;
esac

case "${1:-status}" in
  status) exit 0 ;;
  restart)
    # Ask PowerManager/init for its documented userspace reboot. It keeps kernel and radio
    # state but still runs Android's graceful stop/fallback sequence.
    if svc power reboot userspace >/dev/null 2>&1; then
      reply 'requested=userspace'
      exit 0
    fi
    reply 'mode=unavailable reason=userspace_request_rejected'
    exit 4
    ;;
  *)
    reply 'mode=unavailable reason=usage'
    exit 64
    ;;
esac
