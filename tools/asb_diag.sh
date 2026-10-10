#!/system/bin/sh
# ===================================================================== ASB GLOBAL DIAGNOSTIC —
# AutoSystemBoost full system audit
# ===================================================================== Easiest way to run
# (module installs a launcher on PATH): su -c asbdiag
#
#  Or run the script directly:
#       su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_diag.sh'
#
# Write probes are disabled by default. They temporarily change live CPU/GPU
# limits and can collide with a game, camera, thermal mitigation or PowerHAL.
# Run them only on an idle device with explicit consent:
#       su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_diag.sh --write-test'
#
# It inspects the LIVE system — the real mounted files and the real runtime properties/settings
# the OS is using right now — across every area ASB touches: module status, mounts, audio,
# bluetooth, GPS, Wi-Fi, network/TCP, camera, performance, display, props and the WebUI config.
#
# The full report is printed AND saved to: /sdcard/asb_diag_report.txt (storage root)
# /data/local/tmp/asb_diag_report.txt (fallback) The real filesystem root (/) is read-only, so
# "корень телефона" in practice means /sdcard — that's where the file lands.

# Read settings the way the module does.
# Without this the report showed "Failure calling service settings" for every value on a
# device where the module itself was already working through the content provider -
# the diagnostic was describing its own broken reads, not the module.
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh ] && \
  . /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh

WRITE_TEST=0
[ "${1:-}" = "--write-test" ] && WRITE_TEST=1
OUT1="/sdcard/asb_diag_report.txt"
OUT2="/data/local/tmp/asb_diag_report.txt"
true > "$OUT1" 2>/dev/null || OUT1=""
true > "$OUT2" 2>/dev/null || OUT2=""

P()  { printf '%s\n' "$1"; [ -n "$OUT1" ] && printf '%s\n' "$1" >> "$OUT1"; [ -n "$OUT2" ] && printf '%s\n' "$1" >> "$OUT2"; }
HR() { P "----------------------------------------------------------------"; }
SEC(){ P ""; P "================================================================"; P " $1"; P "================================================================"; }

PASS=0; FAIL=0; NA=0; INFO=0; OFFN=0; OFF_LIST=""
# verdict: $1 label  $2 expected  $3 actual  $4 mode(eq|has|ge|present)
V() {
  _l="$1"; _e="$2"; _a="$3"; _m="${4:-eq}"; _st="FAIL"
  case "$_m" in
    eq)      [ "$_a" = "$_e" ] && _st="PASS" ;;
    has)     printf '%s' "$_a" | grep -q -- "$_e" && _st="PASS" ;;
    ge)      [ -n "$_a" ] && [ "$_a" -ge "$_e" ] 2>/dev/null && _st="PASS" ;;
    le)      [ -n "$_a" ] && [ "$_a" -le "$_e" ] 2>/dev/null && _st="PASS" ;;
    present) [ -n "$_a" ] && _st="PASS" ;;
  esac
  if [ -z "$_a" ] && [ "$_m" != "eq" ]; then _st="N/A "; NA=$((NA+1));
  elif [ "$_st" = "PASS" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); fi
  P "  [$_st] $_l"
  [ "$_m" != "info" ] && P "         want: $_e   live: ${_a:-<none>}"
}
NOTE(){ P "  (i) $1"; INFO=$((INFO+1)); }
# A check that was not run because the user's setting turns the feature off (or leaves it
# on "auto", i.e. the system default). Counted apart from N/A and listed in the summary.
#
# Without this the totals said "16 PASS" on one phone and "30 PASS" on another and nothing
# explained the gap: most of it was camera grading, per-link network choices and media
# loudness switched off on the first phone - settings, not defects. A reader comparing two
# reports needs to see that at a glance instead of diffing them line by line.
OFF(){ P "  [OFF ] $1"; OFFN=$((OFFN+1)); OFF_LIST="${OFF_LIST:+$OFF_LIST, }$2"; }

gp() { getprop "$1" 2>/dev/null; }
firstf() { for _g in $@; do for _f in $_g; do [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }; done; done; return 1; }

# A vendor camera config may deliberately use JSON-with-comments. ASB strips leading
# comments from every payload it stages, but the live /odm file is not proof that ASB
# owns it: some root managers leave the vendor file visible, and unsupported camera
# domains have no ASB overlay at all. Report a real malformed ASB payload as FAIL;
# otherwise retain the observation as information rather than a false thermal/power alarm.
camera_json_comment_verdict() {
  _cj_file="$1"
  _cj_count="$(grep -cE '^[[:space:]]*//' "$_cj_file" 2>/dev/null)"
  if [ "${_cj_count:-0}" = "0" ]; then
    P "  [PASS] $_cj_file present, strict JSON (no // comments)"; PASS=$((PASS+1))
    return 0
  fi

  _cj_rel="${_cj_file#/odm}"
  _cj_asb_file=""
  _cj_asb_count=0
  # These are the exact destinations used by the installer and its deferred /odm bind.
  # A clean staged payload is intentionally not treated as ownership of a commented live
  # vendor file: the diagnostic must not turn a failed/unsupported mount into a false
  # claim that ASB wrote malformed JSON.
  for _cj_candidate in \
      "$MODDIR/system/odm$_cj_rel" \
      "$MODDIR/system/vendor/odm$_cj_rel" \
      "/data/adb/asb/odm_patched$_cj_file"; do
    [ -f "$_cj_candidate" ] || continue
    _cj_candidate_count="$(grep -cE '^[[:space:]]*//' "$_cj_candidate" 2>/dev/null)"
    if [ "${_cj_candidate_count:-0}" -gt 0 ] 2>/dev/null; then
      _cj_asb_file="$_cj_candidate"
      _cj_asb_count="$_cj_candidate_count"
      break
    fi
  done
  if [ -n "$_cj_asb_file" ]; then
    V "  ASB-managed camera payload has // comments (HAL JSON parser may reject)" "0" "$_cj_asb_count" eq
    NOTE "  staged payload: $_cj_asb_file"
  else
    NOTE "vendor JSON-with-comments: $_cj_file (${_cj_count}); ASB did not assert a JSON policy for this live vendor camera domain"
  fi
}

# ---- module discovery (KSU / APatch / Magisk) ----
MODDIR=""
for _root in /data/adb/modules /data/adb/ap/modules /data/adb/ksu/modules; do
  [ -d "$_root" ] || continue
  for _m in "$_root"/*; do
    [ -f "$_m/module.prop" ] || continue
    grep -q '^id=AutoSystemBoost$' "$_m/module.prop" 2>/dev/null && { MODDIR="$_m"; break; }
  done
  [ -n "$MODDIR" ] && break
done
[ -z "$MODDIR" ] && [ -d /data/adb/modules/AutoSystemBoost ] && MODDIR=/data/adb/modules/AutoSystemBoost
CONF="$MODDIR/config/governor.conf"
cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }

# =====================================================================
P "################################################################"
P "#         AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC            #"
P "################################################################"
P " date    : $(date 2>/dev/null)"
P " device  : $(gp ro.product.manufacturer) $(gp ro.product.model)  ($(gp ro.product.device))"
P " android : $(gp ro.build.version.release)  | build $(gp ro.build.id)"
P " platform: $(gp ro.board.platform)  | soc $(gp ro.soc.model)$(gp ro.hardware.chipname)"
P " kernel  : $(uname -r 2>/dev/null)"
_root_mgr="unknown"
[ -d /data/adb/ap ] && _root_mgr="APatch"
[ -d /data/adb/ksu ] && _root_mgr="KernelSU"
[ -f /data/adb/magisk/magisk ] && _root_mgr="Magisk"
P " root    : $_root_mgr"
P " module  : ${MODDIR:-NOT FOUND}"
[ -n "$MODDIR" ] && P " version : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)  ($(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2))"

if [ -z "$MODDIR" ]; then
  P ""; P "  !! AutoSystemBoost module not found — is it installed & enabled?"
  P ""; exit 0
fi

# =====================================================================
SEC "0. BOOT TIMELINE  (debug-only passive lifecycle evidence)"
_boot_timeline="/data/adb/asb/boot_timeline.tsv"
_boot_version="$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
# Keep this strict numeric debug-build rule in lockstep with runtime/asb_boot_timeline.sh
# and runtime/asb_debug_support.sh. A shell glob such as [1-9][0-9]* accidentally
# requires at least two digits, so it misclassified V64-debug4 as a release build.
_boot_debug=0
_boot_seq="${_boot_version##*-debug}"
case "$_boot_version:$_boot_seq" in
  *-debug[1-9]*:[1-9]*)
    case "$_boot_seq" in *[!0-9]*) ;; *) _boot_debug=1 ;; esac
    ;;
esac
if [ "$_boot_debug" = "1" ]; then
  if [ -r "$_boot_timeline" ]; then
    _boot_rows="$(grep -cv '^#' "$_boot_timeline" 2>/dev/null)"
    P "  recorder             : debug active · ${_boot_rows:-0} marker(s)"
    P "  boot reason           : $(grep '^# bootreason=' "$_boot_timeline" 2>/dev/null | head -1 | cut -d= -f2-)"
    P "  latest lifecycle rows:"
    tail -n 16 "$_boot_timeline" 2>/dev/null | while IFS= read -r _boot_row; do
      case "$_boot_row" in '#'*|'') continue ;; esac
      P "    $_boot_row"
    done
    NOTE "Rows use uptime_ms. A long gap before service_enter is pre-service; a long gap after service_dispatched is framework/vendor startup; a long post_boot_tweaks span identifies deferred helper work."
  else
    NOTE "No boot timeline yet. Reboot once, wait for the system to finish starting, then export asbdiag again."
  fi
else
  P "  recorder             : release build — disabled by design"
fi

# Why did the LAST boot end? Readable on every build, debug or not.
#
# An OP12 report: in the morning the launcher was black with only the clock, the alarm did
# not ring, the power button clicked but the screen stayed on; a reboot fixed it and nobody
# had logs. Everything that explains such a night is gone after the reboot except what the
# platform keeps on its own: the boot reason, and the dropbox entries for a system_server
# watchdog, a kernel panic or a tombstone. Counting them here costs one dumpsys call and
# turns "the phone hung" into "system_server watchdog at 06:41" or "nothing recorded".
_lb_reason="$(getprop sys.boot.reason 2>/dev/null)"
[ -n "$_lb_reason" ] || _lb_reason="$(getprop ro.boot.bootreason 2>/dev/null)"
_lb_hist="$(getprop persist.sys.boot.reason.history 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
P "  last boot reason      : ${_lb_reason:-unknown}"
# Whether a kernel crash reboots the phone or leaves it hanging. ASB set both to 0 up to
# fix89; another module or a custom kernel may still do it. 0/0 turns a crash the phone would
# reboot out of into a hang that needs a forced restart (black screen, alarm missed).
_kp="$(cat /proc/sys/kernel/panic 2>/dev/null)"; _kpo="$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)"
P "  kernel panic policy   : panic=${_kp:-?} panic_on_oops=${_kpo:-?}  (tombstones kept: $(getprop tombstoned.max_tombstone_count 2>/dev/null || echo default))"
if [ "$_kp" = "0" ] || [ "$_kpo" = "0" ]; then
  NOTE "a kernel crash will NOT reboot this phone (panic=0 waits forever / panic_on_oops=0 runs on after an oops) - a hang then looks like a frozen black screen until a forced restart. ASB no longer sets these; if they stay 0 after a reboot, another module or the kernel does."
fi
[ -n "$_lb_hist" ] && P "  boot reason history   : $_lb_hist"
if command -v dumpsys >/dev/null 2>&1; then
  _lb_db="$(dumpsys dropbox 2>/dev/null)"
  for _lb_tag in system_server_watchdog system_server_crash SYSTEM_TOMBSTONE SYSTEM_LAST_KMSG system_app_anr system_server_anr; do
    _lb_last="$(printf '%s\n' "$_lb_db" | grep -E "^[0-9-]+ [0-9:.]+ $_lb_tag( |$)" | tail -1 | cut -c1-19)"
    _lb_n="$(printf '%s\n' "$_lb_db" | grep -cE "^[0-9-]+ [0-9:.]+ $_lb_tag( |$)")"
    [ "${_lb_n:-0}" -gt 0 ] && P "  dropbox $_lb_tag : ${_lb_n} (latest ${_lb_last})"
  done
  NOTE "After a hang or a forced reboot, export asbdiag BEFORE using the phone further: the dropbox keeps only a few entries per tag."
fi

# =====================================================================
# Other modules that set the same properties.
#
# Audio/Bluetooth tweak modules (AIST and its relatives) ship long system.prop lists, and
# ASB's managed list overlaps them heavily - 141 shared keys with AIST v2.1, 16 of them with
# a different value (codec ABR on/off, sniff intervals, BLE power class, LPA). With two
# modules setting one key the boot order decides, the user sees neither module's intent,
# and a Bluetooth complaint can come from either. Name every enabled module that sets a
# key ASB manages to a different value, and what the phone holds now.
SEC "0a0. MODULE OVERLAP  (other modules setting properties ASB manages)"
_ov_asb="$MODDIR/runtime/asb_managed.props"
_ov_any=0
if [ -r "$_ov_asb" ]; then
  for _ov_m in /data/adb/modules/*; do
    [ -d "$_ov_m" ] || continue
    [ "$_ov_m" = "$MODDIR" ] && continue
    [ -f "$_ov_m/disable" ] || [ -f "$_ov_m/remove" ] && continue
    [ -r "$_ov_m/system.prop" ] || continue
    _ov_rows="$(awk -F= '
      FNR == NR { if ($0 !~ /^[[:space:]]*#/ && NF >= 2) { k = $1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k); v = substr($0, index($0, "=") + 1); a[k] = v }; next }
      $0 !~ /^[[:space:]]*#/ && NF >= 2 {
        k = $1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k); v = substr($0, index($0, "=") + 1)
        if (k in a) { both++; if (a[k] != v) { diff++; print k "|" a[k] "|" v } }
      }
      END { print "#|" both + 0 "|" diff + 0 }' "$_ov_asb" "$_ov_m/system.prop" 2>/dev/null)"
    _ov_sum="$(printf '%s\n' "$_ov_rows" | grep '^#|' | tail -1)"
    _ov_both="$(printf '%s' "$_ov_sum" | cut -d'|' -f2)"; _ov_diff="$(printf '%s' "$_ov_sum" | cut -d'|' -f3)"
    [ "${_ov_both:-0}" -gt 0 ] 2>/dev/null || continue
    _ov_any=1
    NOTE "$(basename "$_ov_m"): sets ${_ov_both} propert(ies) ASB also manages, ${_ov_diff:-0} to a different value"
    printf '%s\n' "$_ov_rows" | grep -v '^#|' | head -n 20 | while IFS='|' read -r _ok _oa _oo; do
      [ -n "$_ok" ] || continue
      P "    $_ok  ASB=$_oa  $(basename "$_ov_m")=$_oo  live=$(getprop "$_ok" 2>/dev/null)"
    done
    case "$(basename "$_ov_m")" in
      AIST*|aist*) NOTE "  AIST also deletes persist.bluetooth.a2dp_offload.disabled and media.resolution.limit.* from its service script, after ASB's own boot pass" ;;
    esac
  done
fi
[ "$_ov_any" = 1 ] || NOTE "no other enabled module sets a property ASB manages"

# =====================================================================
SEC "0a. EXTERNAL KERNEL / UV COEXISTENCE  (read-only evidence; ASB owns no voltage policy)"
_uv_tool="$MODDIR/tools/asb_kernel_uv_coexist.sh"
_uv_tmp="/data/local/tmp/asb_uv_coexist.$$"
if [ -r "$_uv_tool" ]; then
  sh "$_uv_tool" > "$_uv_tmp" 2>/dev/null
  _uvget() { grep -E "^$1=" "$_uv_tmp" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
  _uv_status="$(_uvget status)"; _uv_conf="$(_uvget confidence)"; _uv_reason="$(_uvget reason)"
  P "  coexistence verdict  : ${_uv_status:-unavailable}  (confidence=${_uv_conf:-none})"
  P "  evidence             : ${_uv_reason:-unavailable}; $(_uvget evidence)"
  P "  ASB voltage owner    : $(_uvget asb_voltage_owner)"
  NOTE "$(_uvget warning)"
  NOTE "$(_uvget limit)"
  case "$_uv_status" in
    voltage_surface_observed|external_uv_hint)
      NOTE "External kernel/UV evidence is present. ASB keeps its CPU/GPU workload policy only; do not attribute voltage stability, reboot or thermal behavior to ASB alone." ;;
    *)
      NOTE "No explicit external UV evidence was observable. This is not proof that the current kernel uses stock voltage tables." ;;
  esac
  rm -f "$_uv_tmp" 2>/dev/null
else
  P "  coexistence verdict  : helper unavailable in this package"
fi

# ===================================================================== EFFECTIVE STATE — the
# computed source-of-truth summary.
SEC "0. EFFECTIVE STATE  (computed source-of-truth — read this first)"
# --- Smart enable: file-flag is truth, config is fallback ---
_sm_flag="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
_sm_cfg="$(cfg smart_mode_enabled)"
if [ -n "$_sm_flag" ]; then
  _sm_eff="$_sm_flag"; _sm_src="file-flag (/data/adb/asb/smart_mode_enabled)"
else
  _sm_eff="${_sm_cfg:-0}"; _sm_src="config-fallback (governor.conf, no file-flag yet)"
fi
[ "$_sm_eff" = "1" ] && _sm_word="ON" || _sm_word="OFF"
P "  smart_mode_effective : $_sm_word  ($_sm_eff)"
P "  smart_mode_source    : $_sm_src"
[ -n "$_sm_cfg" ] && [ -n "$_sm_flag" ] && [ "$_sm_cfg" != "$_sm_flag" ] && \
  NOTE "config says $_sm_cfg but the file-flag ($_sm_flag) wins — config value is just the shipped default."
# --- active profile + who owns the CPU caps right now ---
_prof="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prof="${_prof:-<unknown>}"
P "  active_profile       : $_prof"
if [ "$_sm_eff" = "1" ] || [ "$_prof" = "smart" ]; then
  _cap_owner="smart (governor/FSM synthesises caps from profile_bounds rails)"
  _fsm_active=1; _manual_active=0; _mode="smart"
else
  case "$_prof" in
    performance) _cap_owner="manual (service.sh — performance leaves clusters uncapped)" ;;
    *)           _cap_owner="manual (service.sh per-device % of cpuinfo_max — _P_CPUCAP_*)" ;;
  esac
  _fsm_active=0; _manual_active=1; _mode="manual"
fi
P "  cpu_cap_owner        : $_cap_owner"
P "  effective_profile_mode: $_mode    (fsm_bounds_active=$_fsm_active manual_caps_active=$_manual_active)"
NOTE "thermal override (writer/governor) can clamp on top of EITHER owner when the SoC runs hot."
# --- autonomy dial: smart_battery_bias resolves to an alpha lean ---
_bias="$(cfg smart_battery_bias)"; _bias="${_bias:-0}"
if [ "$_mode" = "smart" ] && [ "$_bias" -gt 0 ] 2>/dev/null; then
  P "  smart_battery_bias   : $_bias  (battery-lean nudge; scaled by learner confidence, hard-capped at pure-battery)"
  [ "$_bias" -ge 400 ] 2>/dev/null && NOTE "bias >= 400 can pin active-use alpha into battery-like behaviour — Smart then rides the BATTERY rail in profile_bounds.conf."
else
  P "  smart_battery_bias   : $_bias  (0 = no extra lean)"
fi
# --- canonical root manager (single detection, mirrors the module's own logic) ---
_rm="other"
[ -d /data/adb/ap ] && _rm="apatch"
[ -d /data/adb/ksu ] && _rm="ksu"
[ -f /data/adb/magisk/magisk ] && _rm="magisk-like"
P "  root_manager         : $_rm"
[ "$_rm" = "apatch" ] && NOTE "APatch path: OP12 camera handling is scoped specifically for APatch (real /odm mount)."

# =====================================================================
SEC "0a4. MEMORY / GC  (MGLRU and the ART collector)"
# Report before proposing. A third-party module ships two settings in this area and the
# question is whether ASB should follow - which cannot be answered without knowing what
# the device already does.
#
# MGLRU is a kernel feature; on 6.1+ the vendor usually enables it, and forcing it from
# userspace when it is already on changes nothing while looking like it did something.
if [ -r /sys/kernel/mm/lru_gen/enabled ]; then
  NOTE "MGLRU: $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null) (0x7 = fully on)"
  NOTE "  min_ttl_ms: $(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null)"
else
  NOTE "MGLRU: not exposed by this kernel"
fi
NOTE "lru_gen_config prop: $(getprop persist.device_config.mglru_native.lru_gen_config 2>/dev/null)"
#
# UFFD GC is the ART collector introduced in Android 14. On a build compiled for it,
# turning it off does not revert to a tuned alternative - it falls back to the older
# concurrent-copying collector, which pauses more. Worth knowing before copying a tweak
# that sets it to false.
NOTE "ART uffd_gc: $(getprop ro.dalvik.vm.enable_uffd_gc 2>/dev/null) (empty = build default)"
NOTE "  (Android 14+ builds default to UFFD; disabling it is a downgrade, not a tune)"

SEC "0a3. WAKEUP SOURCES  (which ones ASB can actually gate)"
# List what exists, so a gate is never written against a guessed path again.
#
# The night gate targeted /sys/devices/platform/soc/*ipa*/power/wakeup for two releases.
# That path does not exist on a CPH2745 - the glob matched nothing, the gate did nothing,
# and the capture still showed 73 IPA wakeups with no error anywhere to explain it.
#
# /sys/class/wakeup is the kernel's own index. Printing the names and their current state
# means the next question about a wakeup source is answered from the device.
if [ -d /sys/class/wakeup ]; then
  for _wd in /sys/class/wakeup/wakeup*; do
    [ -d "$_wd" ] || continue
    _wn="$(cat "$_wd/name" 2>/dev/null)"
    case "$_wn" in *IPA*|*ipa*|*rmnet*|*wlan*|*qrtr*) : ;; *) continue ;; esac
    _wp="$(readlink -f "$_wd/device/power/wakeup" 2>/dev/null)"
    if [ -n "$_wp" ] && [ -e "$_wp" ]; then
      NOTE "$_wn = $(cat "$_wp" 2>/dev/null) (gateable)"
    else
      NOTE "$_wn = no power/wakeup node (cannot be gated from userspace)"
    fi
  done
else
  NOTE "/sys/class/wakeup absent - this kernel does not expose the index"
fi
# Say plainly when nothing here can be gated.
#
# A PLQ110 capture shows 254 IPA/rmnet wakeups an hour and 28 wake sources, none of which
# exposes a power/wakeup node. The night modem gate therefore cannot help on that device -
# and without this line the user reads 28 "cannot be gated" entries and is left to draw
# that conclusion themselves, or worse, to keep enabling a tweak that has no effect.
if [ -d /sys/class/wakeup ]; then
  _wg=0; _wn=0
  for _wd in /sys/class/wakeup/wakeup*; do
    [ -d "$_wd" ] || continue
    _wnm="$(cat "$_wd/name" 2>/dev/null)"
    case "$_wnm" in *IPA*|*ipa*|*rmnet*|*wlan*|*qrtr*) : ;; *) continue ;; esac
    _wn=$(( _wn + 1 ))
    _wp="$(readlink -f "$_wd/device/power/wakeup" 2>/dev/null)"
    [ -n "$_wp" ] && [ -e "$_wp" ] && _wg=$(( _wg + 1 ))
  done
  if [ "$_wn" -gt 0 ] && [ "$_wg" -eq 0 ]; then
    NOTE "none of the $_wn radio wake sources can be gated from userspace on this kernel"
    NOTE "  night_modem_idle will not reduce them here - the wakeups are held by the"
    NOTE "  modem subsystem itself, with no runtime-PM handle exposed"
  fi
fi
# And say what the gate itself did the last time it ran.
#
# The CPH2745 day log showed night_modem_idle active all night, this section reporting
# zero gateable sources, and no way to tell whether the gate had even fired - the wakeup
# state file only exists while something is actually gated, so a no-op pass leaves no
# trace. asb_lpm.sh now records every pass; printing it here closes the loop between
# "nothing to gate" and "the gate ran and found nothing".
_gr=/data/adb/asb/lpm_gate_result
if [ -f "$_gr" ]; then
  _gline="$(cat "$_gr" 2>/dev/null)"
  _gact="$(echo "$_gline" | sed -n 's/.*action=\([^ ]*\).*/\1/p')"
  _gws="$(echo "$_gline" | sed -n 's/.*wakeup_nodes=\([0-9]*\).*/\1/p')"
  _gif="$(echo "$_gline" | sed -n 's/.*net_ifaces=\([0-9]*\).*/\1/p')"
  _gts="$(echo "$_gline" | sed -n 's/.*ts=\([0-9]*\).*/\1/p')"
  _gwhen="$(date -d "@$_gts" '+%Y-%m-%d %H:%M' 2>/dev/null)"
  [ -n "$_gwhen" ] || _gwhen="ts=${_gts:-?}"
  NOTE "last modem wakeup gate: action=${_gact:-?} at $_gwhen - matched ${_gws:-0} wakeup-class node(s), ${_gif:-0} interface(s)"
  if [ "${_gws:-0}" = "0" ] && [ "${_gif:-0}" = "0" ]; then
    NOTE "  the gate ran and found nothing to gate - expected on kernels that hide these nodes"
  fi
else
  # Say WHICH reason it is: "disabled by setting" and "not run yet" read the same in the
  # old line, and an audit asked that a disabled feature never look like a failure.
  case "$(cfg night_modem_idle)" in
    1|on|true) NOTE "no modem wakeup gate record yet - night_modem_idle is ON but the night window has not run since install" ;;
    *)         NOTE "night_modem_idle is OFF (setting) - the modem wakeup gate is disabled, not failing" ;;
  esac
fi

SEC "0a2. WEBUI SCALE  (measured, not assumed)"
# Density is not the number that matters - the CSS viewport width is.
#
# Two attempts at "everything is too big on stock density" were calibrated against a width
# calculated from dpi, and both were wrong: the reference device reported something other
# than the arithmetic predicted, so it scaled itself down and the one phone that was
# already correct got smaller. The layout container is 420px, so at or above ~440 CSS px
# nothing is applied at all; below that the UI is scaled by exactly the shortfall.
#
# Printed so a support question is answered with numbers instead of screenshots.
NOTE "physical density: $(wm density 2>/dev/null | sed -n 's/.*Physical density: *//p' | head -1)"
NOTE "override density: $(wm density 2>/dev/null | sed -n 's/.*Override density: *//p' | head -1)"
NOTE "physical size: $(wm size 2>/dev/null | sed -n 's/.*Physical size: *//p' | head -1)"
NOTE "(no zoom is applied at or above 440 CSS px - the WebUI renders exactly as authored)"

SEC "0b. CAMERA GRADE  (is the live tone table actually the graded one?)"
# Compare the marker against the file the camera really reads.
#
# The WebUI can say a camera tweak is saved, and it can say the value matches what was last
# baked - but neither answers "did the graded table reach the camera". The grader writes
# into the module tree, which is bind-mounted over /odm at boot; if that mount is missing or
# a later update replaced the file, the settings are correct and the picture is unchanged.
#
# So read the live path, pull one value the grader always rewrites, and print it next to
# the recorded one. Two numbers that agree is evidence; a status word is not.
_cg_mark=""
for _m in /data/adb/asb/grade_marks/*.mark; do
  [ -f "$_m" ] && { _cg_mark="$(cat "$_m" 2>/dev/null)"; break; }
done
if [ -n "$_cg_mark" ]; then
  NOTE "recorded grade: ${_cg_mark#*=}   (hash:level:grain:contrast:portrait:lowlight)"
else
  NOTE "recorded grade: none - the grader has not run on this install"
fi
_cg_live=""
# The tone keys live in conf_tuning_params.json; video_beauty_default_config is the retouch
# app list and never carries them, so reading it here always printed two empty values.
for _f in /odm/etc/camera/conf_tuning_params.json \
          /vendor/odm/etc/camera/conf_tuning_params.json; do
  [ -r "$_f" ] || continue
  _cg_live="$_f"
  NOTE "live file: $_f"
  NOTE "  SatuColorScale in live file: $(grep -m1 -oE 'SatuColorScale[^,}]*' "$_f" 2>/dev/null)"
  NOTE "  sunsetSatScale in live file: $(grep -m1 -oE 'sunsetSatScale[^,}]*' "$_f" 2>/dev/null)"
  break
done
[ -n "$_cg_live" ] || NOTE "live file: not readable - camera config is not exposed here"
NOTE "(the module tree is bind-mounted over /odm at boot; a value here that never changes"
NOTE " between grade levels means the mount did not take, not that the tweak failed)"

SEC "0b2. LTPO REFRESH PATCH  (is the patched table actually in front of the display?)"
# Same question as the camera section, for the display table: the toggle can be saved
# and the patch can be staged, and neither says the bind took. Evidence, not status words:
# the staged state word, the toggle, the mount table, and a content compare of the file
# the display service reads against the payload that should be shadowing it.
_lt_state="$(cat /data/adb/asb/ltpo_state 2>/dev/null)"
_lt_force="$(grep -m1 '^ltpo_force=' /data/adb/asb/governor.conf.snapshot /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')"
NOTE "staged state: ${_lt_state:-none - installer never ran on this build}   toggle ltpo_force=${_lt_force:-0}"
if [ -f /data/adb/asb/ltpo_bind_manifest.txt ]; then
  _lt_t="$(cut -d'|' -f1 /data/adb/asb/ltpo_bind_manifest.txt 2>/dev/null | head -1)"
  _lt_p="$(cut -d'|' -f2 /data/adb/asb/ltpo_bind_manifest.txt 2>/dev/null | head -1)"
  NOTE "manifest target: ${_lt_t:-<malformed>}"
  if [ -z "$_lt_t" ] || [ -z "$_lt_p" ]; then
    V "LTPO manifest parses (target|payload)" "well-formed" "malformed"
  elif [ ! -f "$_lt_p" ]; then
    V "LTPO payload exists" "present" "missing"
  elif grep -q " $_lt_t " /proc/mounts 2>/dev/null &&
       [ "$_lt_force" != "1" ] && [ ! -f /data/adb/asb/ltpo_bind.active ]; then
    # Toggle off and no bind of ours on record, yet the file is a mountpoint: something
    # else shadows it - another refresh-rate module or a root-manager overlay. A field report
    # showed exactly this as FAIL "bound, but live content differs" on a phone where ASB had
    # never bound anything, which blamed the module for another module's file.
    NOTE "toggle is off and ASB holds no bind, but $_lt_t is a mountpoint"
    NOTE "  another module or the root manager shadows this file - not ASB's patch"
    if cmp -s "$_lt_t" "$_lt_p" 2>/dev/null; then
      NOTE "  (its content happens to equal ASB's payload)"
    fi
  elif grep -q " $_lt_t " /proc/mounts 2>/dev/null; then
    if cmp -s "$_lt_t" "$_lt_p" 2>/dev/null; then
      V "LTPO patch live (bound, live content matches payload)" "match" "match"
    else
      V "LTPO patch live (bound, but live content differs from payload)" "match" "differs"
    fi
  elif [ "$_lt_force" = "1" ]; then
    V "LTPO bind active (toggle is ON)" "bound" "not bound"
    NOTE " toggle is on but nothing is mounted - check vendor_mounts.log for ltpo_bind lines"
  else
    NOTE "toggle is off - nothing should be mounted, and nothing is (correct)"
  fi
elif [ "$_lt_state" = "already" ]; then
  NOTE "no manifest: this device's table already ships with every switch on - nothing to patch"
elif [ "$_lt_state" = "unsupported" ]; then
  NOTE "no manifest: no oplus_vrr_config.json found on this device - the tweak has nothing to bind"
elif [ "$_lt_state" = "ready" ]; then
  V "LTPO manifest present (state says ready)" "present" "missing"
fi
# Refresh range (ltpo_force range half) and the video watcher.
if [ -f /data/adb/modules/AutoSystemBoost/runtime/asb_ltpo_apply.sh ]; then
  NOTE "refresh range: $(MODDIR=/data/adb/modules/AutoSystemBoost sh /data/adb/modules/AutoSystemBoost/runtime/asb_ltpo_apply.sh range 2>/dev/null)"
fi
if [ -f /data/adb/modules/AutoSystemBoost/runtime/asb_ltpo_video.sh ]; then
  NOTE "video refresh (ltpo_video=$(cfg ltpo_video)): $(MODDIR=/data/adb/modules/AutoSystemBoost sh /data/adb/modules/AutoSystemBoost/runtime/asb_ltpo_video.sh status 2>/dev/null)"
  if [ "$(cfg ltpo_video)" = 1 ] && [ -s /data/adb/asb/ltpo_video.log ]; then
    tail -n 3 /data/adb/asb/ltpo_video.log 2>/dev/null | while IFS= read -r _lv; do P "    $_lv"; done
  fi
fi

SEC "0b3. MULTIMEDIA TELEMETRY PATCH  (is the feedback collector actually closed?)"
# Same evidence-first question for Multimedia_Feedback_List.xml: staged state, toggle,
# mount table, and a content compare - plus a direct read of the isOpen line the
# feedback service sees through the bind.
_mf_state="$(cat /data/adb/asb/mmfeed_state 2>/dev/null)"
_mf_off="$(grep -m1 '^mmfeed_off=' /data/adb/asb/governor.conf.snapshot /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')"
NOTE "staged state: ${_mf_state:-none - installer never ran on this build}   toggle mmfeed_off=${_mf_off:-0}"
if [ -f /data/adb/asb/mmfeed_bind_manifest.txt ]; then
  _mf_t="$(cut -d'|' -f1 /data/adb/asb/mmfeed_bind_manifest.txt 2>/dev/null | head -1)"
  _mf_p="$(cut -d'|' -f2 /data/adb/asb/mmfeed_bind_manifest.txt 2>/dev/null | head -1)"
  NOTE "manifest target: ${_mf_t:-<malformed>}"
  if [ -z "$_mf_t" ] || [ -z "$_mf_p" ]; then
    V "MMFEED manifest parses (target|payload)" "well-formed" "malformed"
  elif [ ! -f "$_mf_p" ]; then
    V "MMFEED payload exists" "present" "missing"
  elif grep -q " $_mf_t " /proc/mounts 2>/dev/null; then
    if cmp -s "$_mf_t" "$_mf_p" 2>/dev/null; then
      V "MMFEED patch live (bound, live content matches payload)" "match" "match"
    else
      V "MMFEED patch live (bound, but live content differs from payload)" "match" "differs"
    fi
    if [ -n "$_mf_t" ]; then
      _mf_open="$(grep -m1 '<isOpen>' "$_mf_t" 2>/dev/null | tr -d ' \r')"
      case "$_mf_open" in
        *false*) NOTE "isOpen through the bind: ${_mf_open:-<unreadable>} (collector closed)" ;;
        *)       V "isOpen through the bind is false" "false" "${_mf_open:-<unreadable>}" ;;
      esac
    fi
  elif [ "$_mf_off" = "1" ]; then
    V "MMFEED bind active (toggle is ON)" "bound" "not bound"
    NOTE " toggle is on but nothing is mounted - check vendor_mounts.log for mmfeed_bind lines"
  else
    NOTE "toggle is off - nothing should be mounted, and nothing is (correct)"
  fi
elif [ "$_mf_state" = "already" ]; then
  NOTE "no manifest: this device's feedback list already ships closed - nothing to patch"
elif [ "$_mf_state" = "unsupported" ]; then
  NOTE "no manifest: no Multimedia_Feedback_List.xml found on this device - the tweak has nothing to bind"
elif [ "$_mf_state" = "ready" ]; then
  V "MMFEED manifest present (state says ready)" "present" "missing"
fi

SEC "0c. AUDIO CONFIG TREE  (which SKU the platform actually reads)"
# ColorOS keeps several SKU trees in one image and loads exactly one.
#
# A stock Ace 5 capture carries sku_pineapple, sku_cliffs and their _qssi variants side by
# side, plus audio_effects.xml at eleven separate paths. ASB's own path list has no SKU
# component, so on such a device it can find a file the framework never reads - and an
# effect registered in one config while audioserver loads another is how audioserver dies,
# taking SystemUI and the camera with it.
#
# Read-only. Printed so a mismatch is visible before it becomes a crash report.
NOTE "board platform: $(gp ro.board.platform)"
_ad_p="$(gp ro.board.platform)"
_ad_live=""
case "$_ad_p" in ''|*[!a-z0-9_]*) _ad_p="" ;; esac
if [ -n "$_ad_p" ]; then
  for _d in "/vendor/etc/audio/sku_$_ad_p" "/odm/etc/audio/sku_$_ad_p"; do
    [ -d "$_d" ] && { _ad_live="$_d"; break; }
  done
fi
NOTE "live audio SKU dir: ${_ad_live:-none (no SKU split on this platform)}"
_ad_n=0
for _f in /vendor/etc/audio_effects.xml /odm/etc/audio_effects.xml \
          /vendor/etc/audio/sku_*/audio_effects.xml /odm/etc/audio/sku_*/audio_effects.xml \
          /vendor/etc/audio_effects_config.xml /odm/etc/audio_effects_config.xml; do
  [ -f "$_f" ] && _ad_n=$(( _ad_n + 1 ))
done
NOTE "audio effect configs present: $_ad_n"
NOTE "(ASB patches audio only where the DSP library exists - see dsp_soundfx in capabilities)"

SEC "0a. DEVICE CAPABILITIES  (discovered facts — from device_caps.env)"
_caps="/data/adb/asb/device_caps.env"
if [ -f "$_caps" ]; then
  _cget() { grep -E "^$1=" "$_caps" 2>/dev/null | head -1 | sed 's/^[^=]*=//'; }
  P "  soc / codename       : $(_cget soc_platform) / $(_cget codename)  ($(_cget model))"
  P "  android api / kernel : $(_cget android_api) / $(_cget kernel)"
  P "  cpu policies         : $(_cget cpu_policy_count) clusters [$(_cget cpu_policy_list)]"
  for _pid in $(_cget cpu_policy_list); do
    _hm="$(_cget cpu_policy${_pid}_hwmax)"; _nf="$(_cget cpu_policy${_pid}_nfreq)"
    _lo="$(_cget cpu_policy${_pid}_lowest_opp)"; _mw="$(_cget cpu_policy${_pid}_min_writable)"
    P "    - policy${_pid}: hw_max=${_hm} kHz, lowest_opp=${_lo:-unknown} kHz, min_write=${_mw:-unknown}, ${_nf} freq steps"
  done
  P "  gpu backend          : $(_cget gpu_backend)"
  P "  thermal zones        : $(_cget thermal_zone_count)"
  P "  paths: odm_camera=$(_cget has_odm_camera_dir) vendor_audio=$(_cget has_vendor_audio_dir) wlan_txqlen=$(_cget has_wlan_txqlen)"
  NOTE "Raw discovered facts. These feed the per-device bounds synthesis below."
else
  P "  (device_caps.env not present yet — run a reinstall, or it writes on next boot)"
fi

# =====================================================================
SEC "0b. RUNTIME ARBITRATION & WRITE HEALTH  (live owner / requested vs applied)"
_runtime_caps="/data/adb/asb/capabilities.env"
_state="/dev/.asb/state"
_rget() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
_stock_thermal="/data/adb/asb/thermal_stock"
_eff_env="/data/adb/asb/active_efficiency.env"
if [ -r "$_eff_env" ]; then
  P "  active-use envelope  : status=$(_rget status "$_eff_env") tier=$(_rget tier "$_eff_env") soc=$(_rget soc "$_eff_env") reason=$(_rget reason "$_eff_env")"
  P "    capability gate     : cpu_policies=$(_rget cpu_policy_count "$_eff_env") gpu=$(_rget gpu_backend "$_eff_env") thermal_zones=$(_rget thermal_zone_count "$_eff_env")"
  P "    policy deltas       : budget=$(_rget budget_light_bonus_pct "$_eff_env")/$(_rget budget_moderate_bonus_pct "$_eff_env")/$(_rget budget_severe_bonus_pct "$_eff_env")% gpu_idle+$(_rget gpu_idle_trim_bonus_pct "$_eff_env")% bg_uclamp-$(_rget bg_uclamp_moderate_delta "$_eff_env")/$(_rget bg_uclamp_severe_delta "$_eff_env")"
else
  P "  active-use envelope  : unavailable (generated at boot; generic ASB policy remains active)"
fi
if [ -r "$_stock_thermal" ]; then
  P "  stock thermal        : source=$(_rget SOURCE "$_stock_thermal") zone=$(_rget ZONE "$_stock_thermal") trip=$(_rget INDEX "$_stock_thermal") type=$(_rget TYPE "$_stock_thermal") raw=$(_rget RAW "$_stock_thermal") resolved=$(_rget RESOLVED "$_stock_thermal")C"
  [ "$(_rget SOURCE "$_stock_thermal")" = "passive_trip_point" ] || NOTE "No passive CPU trip was confirmed: stock/smart mode keeps the configured threshold unchanged."
else
  P "  stock thermal        : unavailable (captured on next boot)"
fi
if [ -r "$_runtime_caps" ]; then
  P "  boot manifest         : policies=$(_rget cpu_policy_count "$_runtime_caps") opp_complete=$(_rget cpu_opp_complete "$_runtime_caps") cgroup_v1=$(_rget cgroup_v1 "$_runtime_caps") cgroup_v2=$(_rget cgroup_v2 "$_runtime_caps")"
  P "  optional signals      : uclamp=$(_rget uclamp "$_runtime_caps") thermal=$(_rget thermal_sensors "$_runtime_caps") battery_current=$(_rget battery_current "$_runtime_caps") gpu_devfreq=$(_rget gpu_devfreq "$_runtime_caps")"
else
  P "  boot manifest         : unavailable (probe may not have completed)"
fi
_pack_state="/data/adb/asb/device_pack.state"
_props_state="/data/adb/asb/managed_props.state"
if [ -r "$_pack_state" ]; then
  P "  device-pack state     : status=$(_rget status "$_pack_state") reason=$(_rget reason "$_pack_state")"
else
  P "  device-pack state     : unavailable"
fi
if [ -r "$_props_state" ]; then
  P "  managed properties    : status=$(_rget status "$_props_state") reason=$(_rget reason "$_props_state") applied=$(_rget applied "$_props_state") skipped=$(_rget skipped "$_props_state")"
else
  P "  managed properties    : unavailable (applier has not run)"
fi
for _lease in /dev/.asb/arbiter/*.lease; do
  [ -r "$_lease" ] || continue
  _lo="$(_rget owner "$_lease")"; _lp="$(_rget priority "$_lease")"; _lr="$(_rget reason "$_lease")"; _le="$(_rget expires "$_lease")"
  _ld="$(_rget desired "$_lease")"; _la="$(_rget applied "$_lease")"; _lerr="$(_rget last_error "$_lease")"
  P "  lease ${_lease##*/} : owner=${_lo:-?} priority=${_lp:-?} reason=${_lr:-?} desired=${_ld:--} applied=${_la:--} error=${_lerr:-none} expires=${_le:-?}"
done
[ -f /dev/.asb/camera_guard ] && P "  camera lease          : ACTIVE (foreground/top-app/uclamp remain camera-owned)" || P "  camera lease          : inactive"
if [ -r "$_state" ]; then
  _wattempts="$(_rget writer_attempts "$_state")"; _wapplied="$(_rget writer_applied "$_state")"; _wfail="$(_rget writer_failures "$_state")"; _wskip="$(_rget writer_backoff_skips "$_state")"
  # Screen-off cooldown: is the clamp holding the caps down right now?
  #
  # Only engages on a phone that went to sleep warm - so it will read 0 in almost every
  # diag taken by hand, and that is correct. It matters in a capture taken the morning
  # after a heavy evening, where it is the difference between "the night was expensive"
  # and "the night was expensive and nothing tried to fix it".
  _cd="$(grep -m1 '^thermal_cooldown=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  case "$_cd" in
    1) P "  cooldown clamp        : ACTIVE (screen off, die still warm - caps at hw minimum)" ;;
    0) P "  cooldown clamp        : idle (not needed - phone is cool or screen is on)" ;;
    *) P "  cooldown clamp        : unknown (governor state not readable)" ;;
  esac
  # Desired versus effective: how far the hardware is from what ASB asked for.
  #
  # cap_owner names the winner but not the margin. A 5% trim and a total override read
  # identically, so a capture could not tell "vendor is slightly stricter" from "our
  # writes are being discarded" - and those need opposite responses.
  _dw0="$(_rget desired_cpu_max0 "$_state")"; _ew0="$(_rget effective_cpu_max0 "$_state")"
  _dwp="$(_rget desired_cpu_maxp "$_state")"; _ewp="$(_rget effective_cpu_maxp "$_state")"
  case "$_dw0$_ew0" in ''|*[!0-9]*) : ;; *)
    # The second figure is governor slot 1. That is the prime on a two-cluster SoC
    # (OP13/OP15) but the first mid cluster on a 1+3+2+1 part (OP12), where calling it
    # "prime" put a mid-core number next to the word prime.
    _sp2="$(_rget slot_policy_ids "$_state" | cut -d, -f3)"
    case "$_sp2" in ''|-1) _s1n="prime" ;; *) _s1n="mid" ;; esac
    P "  cap desired/effective : little $_dw0 -> $_ew0 kHz, $_s1n $_dwp -> $_ewp kHz"
    if [ "$_ew0" -lt "$_dw0" ] 2>/dev/null; then
      P "    (hardware is stricter than ASB asked - vendor or thermal owns the cap)"
      # The reverse case matters more and was silent.
      #
      # A capture reads prime 1497600 -> 1747200: the hardware is running ABOVE what ASB
      # asked for, which means our ceiling did not take at all. Only the stricter direction
      # was reported, so the louder failure produced no line.
      if [ "$_ewp" -gt "$_dwp" ] 2>/dev/null; then
        P "    (hardware is ABOVE the requested prime ceiling - our cap did not take)"
      fi
    fi ;;
  esac
  _re="$(_rget reassert_eligible "$_state")"
  [ "$_re" = "0" ] && P "  reassert              : suppressed (vendor owns the cap right now)"
  # Per-node breakdown beside the totals.
  #
  # "attempts=471" says the writer is busy, not with what. This line names the nodes so a
  # cut in writes can target the one doing the work instead of being spread blindly.
  _wbn="$(grep -m1 '^write_by_node=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
  # Wakeups by source beside the writes: 674/h is the module's real cost, and the split
  # says which timer to look at before touching any interval.
  _wbs="$(grep -m1 '^wake_by_src=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
  [ -n "$_wbs" ] && NOTE "wakeups by source: $_wbs"
  # Boot cost, from the last boot's log line. Decides whether a config-read cache is
  # worth the risk of new state in the atomic writer.
  _bms="$(grep -ao 'post-boot policy took [0-9]* ms' /dev/.asb_profile_state/runtime_apply.log 2>/dev/null | tail -1)"
  [ -n "$_bms" ] && NOTE "boot: $_bms"
  # Which path answered the screen question. 0=unknown 1,2=oplus 3=panel0 4=generic 5=default.
  # 5 means nothing was readable and the module assumed "on"; 0 means it never asked.
  _ssr="$(grep -m1 '^screen_src=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  case "${_ssr:-}" in
    1|2) NOTE "screen source: oplus_display (${_ssr})" ;;
    3)   NOTE "screen source: panel0-backlight" ;;
    4)   NOTE "screen source: generic backlight" ;;
    5)   NOTE "screen source: NONE readable - assuming on (idle cadence will be wrong)" ;;
    0)   NOTE "screen source: not sampled yet" ;;
  esac
  # How each wake was noticed. "tick" is the slow path: until then the governor is still on
  # screen-off rails while the phone is in someone's hand. A tick share near zero is the
  # goal; the late figure is an upper bound (time since the screen went off).
  _sod="$(grep -m1 '^screen_on_detect=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
  if [ -n "$_sod" ]; then
    _sot="$(printf '%s' "$_sod" | sed -n 's/.*tick:\([0-9]*\).*/\1/p')"
    _sol="$(grep -m1 '^screen_on_tick_late_max_s=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    _sos="$(grep -m1 '^screen_on_single_rechecks=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    NOTE "screen-on noticed by: $_sod  (single re-checks armed: ${_sos:-0}; slowest tick catch <= ${_sol:-0} s after screen-off)"
    _skd="$(grep -m1 '^screen_on_key_devices=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    _skh="$(grep -m1 '^screen_on_key_hints=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    [ -n "$_skd" ] && NOTE "wake keys watched: ${_skd} input device(s) · ${_skh:-0} power/wakeup press(es) started a re-check"
    _lpe="$(grep -m1 '^light_idle_pin_escalations=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
    [ -n "$_lpe" ] && NOTE "light idle -> moderate because the main cores sat at the light-idle ceiling: ${_lpe} time(s)"
    # A share, not a count: 5 of 201 wakes over a day is the occasional AOD/pocket case,
    # not a ROM whose display events never arrive - an absolute "> 3" warned on both.
    _sou="$(printf '%s' "$_sod" | sed -n 's/.*uevent:\([0-9]*\).*/\1/p')"
    _sor="$(printf '%s' "$_sod" | sed -n 's/.*recheck:\([0-9]*\).*/\1/p')"
    _sall=$(( ${_sou:-0} + ${_sor:-0} + ${_sot:-0} ))
    if [ "${_sot:-0}" -gt 3 ] 2>/dev/null && [ $(( ${_sot:-0} * 10 )) -gt "$_sall" ] 2>/dev/null; then
      NOTE "WARN: $_sot of $_sall screen wakes were found only by the idle tick - send this diag: the display event path misses them on this ROM"
    fi
  fi
  # Display uevents and the parking that keeps them from waking the governor with the
  # screen on (the active tick watches the panel then).
  _uet="$(grep -m1 '^uevent_events_total=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _ueb="$(grep -m1 '^uevent_by_subsys=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
  _uep="$(grep -m1 '^uevent_parks=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _ued="$(grep -m1 '^uevent_dropped_while_parked=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ -n "$_uet" ] && NOTE "uevents handled: ${_uet} (${_ueb:-?})  ·  skipped while the screen was on: ${_ued:-n/a} over ${_uep:-0} screen-on period(s)"
  [ -n "$_wbn" ] && NOTE "writes by node: $_wbn"
  # Vendor contention beside it: passive=1 means ASB stopped reasserting on purpose.
  _vp="$(grep -m1 '^cap_vendor_passive=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _vc="$(grep -m1 '^cap_vendor_slow_clamps=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ -n "$_vp" ] && NOTE "vendor contention: passive=${_vp} slow_clamps=${_vc:-0}"
  # Which stage set the prime ceiling. "profile" means neither the thermal budget nor the
  # efficiency envelope lowered it - the ceiling is simply the state's own.
  _cpr="$(grep -m1 '^cap_prime_reason=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _cpb="$(grep -m1 '^cap_prime_base_khz=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _cpe="$(grep -m1 '^cap_prime_eff_khz=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  # 0 means the profile sets no ceiling for that slot: the cluster runs to its hardware
  # (or vendor) limit. Printing "0 kHz" read as if the prime were switched off.
  if [ -n "$_cpr" ]; then
    if [ "${_cpb:-0}" = "0" ] && [ "${_cpe:-0}" = "0" ]; then
      NOTE "prime ceiling: none from ASB - the top cluster runs to its hardware/vendor limit"
    else
      # The governor publishes the ceiling before it is rounded to an OPP step, so the
      # figure could be a frequency the SoC does not have (1467648). Show the step the
      # writer actually sends: the largest available frequency at or below it.
      _sp_all="$(grep -m1 '^slot_policy_ids=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
      _sp_top=""
      for _spx in $(printf '%s' "$_sp_all" | tr ',' ' '); do
        [ "$_spx" -ge 0 ] 2>/dev/null && _sp_top="$_spx"
      done
      _snapf() {
        _sw="$1"; _sb=""
        for _sf in $(cat "/sys/devices/system/cpu/cpufreq/policy${_sp_top}/scaling_available_frequencies" 2>/dev/null); do
          [ "$_sf" -le "$_sw" ] 2>/dev/null && { [ -z "$_sb" ] || [ "$_sf" -gt "$_sb" ]; } && _sb="$_sf"
        done
        printf '%s' "${_sb:-$1}"
      }
      if [ -n "$_sp_top" ]; then
        NOTE "prime ceiling: $(_snapf "${_cpe:-0}") kHz (profile $(_snapf "${_cpb:-0}")) - set by ${_cpr}"
      else
        NOTE "prime ceiling: ${_cpe:-?} kHz (profile ${_cpb:-?}) - set by ${_cpr}"
      fi
    fi
  fi
  _pe="$(grep -m1 '^prime_escape=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _pec="$(grep -m1 '^prime_escape_count=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ -n "$_pe" ] && NOTE "HEAVY prime escape: $([ "$_pe" = 1 ] && echo ACTIVE || echo idle) · bursts this session: ${_pec:-0} · lifted $(_rget prime_escape_total_s /dev/.asb/state 2>/dev/null || echo 0) s in total (heavy_prime_escape=$(cfg heavy_prime_escape), burst $(cfg prime_escape_burst_s) s / rest $(cfg prime_escape_rest_s) s)"
  # 3+ cluster SoCs lift the middle cluster with the prime; say which this device is.
  if [ -n "$_pe" ]; then
    _pcl=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | wc -l)
    if [ "${_pcl:-0}" -ge 3 ] 2>/dev/null; then
      NOTE "  burst scope: prime + middle cluster (${_pcl} clusters)$([ "$(grep -m1 '^prime_escape_mid=' /dev/.asb/state 2>/dev/null | cut -d= -f2)" = 1 ] && echo ' · mid lifted now')"
    else
      NOTE "  burst scope: big cluster (${_pcl:-?} clusters)"
    fi
  fi
  P "  writer health         : attempts=${_wattempts:-0} applied=${_wapplied:-0} failures=${_wfail:-0} backoff_skips=${_wskip:-0}"
  # Say what the two numbers count, because they do not count the same thing.
  #
  # A capture reads attempts=292 backoff_skips=455 - more skips than attempts, which
  # looks impossible. It is not: a write deferred by backoff returns before attempts
  # is incremented, so the two are disjoint. Total requests is their sum.
  #
  # Printing the total makes the ratio readable instead of alarming.
  case "${_wattempts:-0}${_wskip:-0}" in
    *[!0-9]*) : ;;
    *) [ "${_wskip:-0}" -gt 0 ] 2>/dev/null && \
         NOTE "  attempts and skips are disjoint: $(( ${_wattempts:-0} + ${_wskip:-0} )) requests total, $(( 100 * ${_wskip:-0} / (${_wattempts:-0} + ${_wskip:-0}) ))% deferred" ;;
  esac
  # Say WHY writes were skipped - a bare count reads as breakage.
  #
  # A healthy capture shows attempts=84 applied=83 failures=0 backoff_skips=71: almost
  # every write deferred, yet nothing wrong. The usual cause is kernel_floor_higher -
  # the kernel already enforces a minimum above what ASB asked for, so after three
  # confirmations the writer stops retrying for an hour. That is correct behaviour and
  # the opposite of a failure, but the number alone cannot say so.
  _wskip_why="$(grep -m1 -oE 'kernel_floor_higher|unsupported_[a-z]+|vendor_[a-z_]+' \
               "$_state" 2>/dev/null)"
  case "$_wskip_why" in
    kernel_floor_higher) NOTE "  skips are kernel_floor_higher: the kernel enforces a higher minimum than requested - expected, not a fault" ;;
    unsupported_*)       NOTE "  skips are $_wskip_why: the node does not exist on this kernel" ;;
    vendor_*)            NOTE "  skips are $_wskip_why: the vendor owns this node right now" ;;
  esac
  # Separate "this kernel does not have the node" from "the write was refused".
  #
  # walt_ravg reads back INT_MIN on a custom kernel that lacks it. The writer already
  # handles that correctly - one attempt, then quiet for the day - but it still counts
  # in the failures total, so a healthy phone on OP-WILD shows a permanent FAIL and its
  # owner reasonably reports a bug. Nothing is wrong; the node is simply not there.
  _wh_unsup="$(grep -cE '^writer_node_.*status:unsupported' /dev/.asb/state 2>/dev/null)"
  case "$_wh_unsup" in ''|*[!0-9]*) _wh_unsup=0 ;; esac
  [ "$_wh_unsup" -gt 0 ] && NOTE "of which unsupported on this kernel: $_wh_unsup (not errors - the node does not exist here)"
  _w_vendor_ceiling="$(grep -E '^writer_node_cpu_max[0-2]=.*status:vendor_stricter_ceiling' "$_state" 2>/dev/null | cut -d= -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [ -n "$_w_vendor_ceiling" ] && NOTE "Vendor already holds a stricter CPU ceiling on ${_w_vendor_ceiling}; ASB accepts it and avoids a cap fight."
  P "  energy policy         : shadow=$(_rget shadow_mode "$_state") budget_enabled=$(_rget thermal_budget_enabled "$_state") trim=$(_rget thermal_budget_trim_pct "$_state")% (base=$(_rget thermal_budget_base_trim_pct "$_state")% + envelope=$(_rget thermal_budget_envelope_bonus_pct "$_state")%, stage=$(_rget thermal_budget_stage "$_state")) reason=$(_rget thermal_budget_reason "$_state") dwell=$(_rget thermal_budget_dwell_s "$_state")s"
  P "  active-use runtime    : loaded=$(_rget active_efficiency_active "$_state") tier=$(_rget active_efficiency_tier "$_state") reason=$(_rget active_efficiency_reason "$_state") gpu_idle_bonus=$(_rget active_efficiency_gpu_idle_bonus_pct "$_state")% bg_delta=$(_rget active_efficiency_bg_uclamp_moderate_delta "$_state")/$(_rget active_efficiency_bg_uclamp_severe_delta "$_state")"
  # "events" read as a generic activity count; it is wakeups caused by an event.
  #
  # A capture shows events=10546 next to timer_wakeups=1963, which invites the reading
  # that the governor handles five events per wake. It does not: both are wakeup
  # counts, one from epoll and one from the timer, and their sum is the real total.
  P "  ASB overhead          : event_wakeups=$(_rget governor_event_wakeups "$_state") timer_wakeups=$(_rget governor_timer_wakeups "$_state") cpu_ms=$(_rget governor_cpu_ms "$_state")"
  # Attribution, not just a total.
  #
  # The line above says how much overhead there was; this one says where it came from.
  # The ratio is what carries the meaning: many writes per transition means the reconcile
  # loop is fighting something, many transitions means the ladder is chattering, and a
  # high vendor count means neither - the cap is simply not ours right now.
  _ov_t="$(_rget governor_transitions "$_state")"
  _ov_w="$(_rget governor_writes "$_state")"
  case "$_ov_t" in ''|*[!0-9]*) _ov_t=0 ;; esac
  case "$_ov_w" in ''|*[!0-9]*) _ov_w=0 ;; esac
  P "    by source        : transitions=$_ov_t writes=$_ov_w readbacks=$(_rget governor_readbacks "$_state") vendor_overrides=$(_rget governor_vendor_overrides "$_state")"
  _wb="$(_rget write_batches "$_state")"
  case "$_wb" in ''|*[!0-9]*) _wb=0 ;; esac
  if [ "$_wb" -gt 0 ] 2>/dev/null && [ "$_ov_w" -gt 0 ] 2>/dev/null; then
    P "    write batches    : $_wb ($(( _ov_w / _wb )) nodes per batch)"
  fi
  _ph="$(_rget probe_cache_hits "$_state")"; _pm="$(_rget probe_cache_misses "$_state")"
  case "$_ph" in ''|*[!0-9]*) _ph=0 ;; esac
  case "$_pm" in ''|*[!0-9]*) _pm=0 ;; esac
  if [ $(( _ph + _pm )) -gt 0 ]; then
    P "    probe cache      : hits=$_ph misses=$_pm ($(( _ph * 100 / (_ph + _pm) ))% avoided forks)"
  fi
    _nt="$(_rget noop_ticks "$_state")"
    case "$_nt" in ''|*[!0-9]*) _nt=0 ;; esac
    if [ $(( _nt + _ov_t )) -gt 0 ]; then
      P "    smart re-slots   : $_nt changed nothing (Smart recomputes only, not every tick)"
    fi
      _jw="$(_rget json_written "$_state")"; _js="$(_rget json_skipped "$_state")"
      case "$_jw" in ''|*[!0-9]*) _jw=0 ;; esac
      case "$_js" in ''|*[!0-9]*) _js=0 ;; esac
      if [ $(( _jw + _js )) -gt 0 ]; then
        P "    json publishes   : written=$_jw skipped=$_js ($(( _js * 100 / (_jw + _js) ))% avoided fsync)"
      fi
  if [ "$_ov_t" -gt 0 ] 2>/dev/null; then
    # One transition legitimately writes ~4-6 nodes (two cluster caps plus the uclamp set),
    # so a flat "4+" threshold flags healthy devices. And vendor overrides inflate the write
    # count without any ladder movement at all: every vendor re-clamp forces a reconcile
    # write. Field captures tripped both ways: 6/transition with 0 overrides (healthy) and
    # 16/transition with 111 overrides (contention, not chatter) read identically.
    _ov_vo="$(_rget governor_vendor_overrides "$_state")"
    case "$_ov_vo" in ''|*[!0-9]*) _ov_vo=0 ;; esac
    _wpt=$(( _ov_w / _ov_t ))
    # governor_vendor_overrides is NOT a write count.
    #
    # It rises once per evaluation while the governor is passive - asb_governor.c only
    # increments it under g_cap_vendor_passive - and passive means ASB is deliberately NOT
    # writing the cap the vendor owns. This used to print "inflated by N vendor-override
    # rewrites", which on a field capture read 1509 rewrites against 317 writes in total:
    # impossible, and it blamed the ratio on writes that never happened.
    #
    # So the ratio is judged on real writes only, and the override figure is reported for
    # what it is - time spent deferring to the vendor.
    _ov_pas="$(_rget cap_vendor_passive "$_state")"
    if [ "$_ov_pas" = "1" ] && [ "$_ov_vo" -gt 0 ] 2>/dev/null; then
      P "    writes per transition: $_wpt  ($_ov_w writes / $_ov_t transitions)"
      P "    vendor-owned ticks   : $_ov_vo spent passive - ASB deferred to the vendor cap, no write"
    elif [ "$_ov_t" -lt 10 ] 2>/dev/null; then
      # The boot pass writes every node once before the first transition: a field diag
      # read "11 per transition - chattering" from 23 writes over 2 transitions.
      P "    writes per transition: $_wpt  ($_ov_w writes / $_ov_t transitions - too few to judge; the boot pass writes every node once)"
    elif [ "$_wpt" -gt 8 ]; then
      P "    writes per transition: $_wpt (8+ with little vendor contention suggests the ladder is chattering)"
    else
      P "    writes per transition: $_wpt (normal - a transition writes ~4-6 nodes)"
    fi
  fi
  if [ "${_wfail:-0}" = "0" ]; then
    NOTE "All observed native writes have read back successfully."
  else
    # Frequency-table size first: it decides how to read everything below.
    _ftn="$(grep -m1 "^freq_table_n=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d "\"")"
    case "${_ftn:-}" in
      ""|0,0,0) NOTE "OPP table not enumerable on this kernel - ceilings are written unrounded,"
                NOTE "  so observed>requested below is the kernel rounding up, not a vendor override." ;;
      *) NOTE "OPP steps per cluster: ${_ftn} (snapping active)" ;;
    esac
    NOTE "Writer failures are backoff-limited. Recent rejected writes:"
    # Show the rows instead of naming the file.
    #
    # This used to say "inspect /dev/.asb/write_errors" - which is exactly what nobody can
    # do from a pasted report, and what turned a one-line diagnosis into three rounds of
    # guessing at which node was failing and why. The rows carry the node, the value asked
    # for and the value read back; that triple is usually the whole answer.
    if [ -s /dev/.asb/write_errors ]; then
      tail -8 /dev/.asb/write_errors 2>/dev/null | while IFS= read -r _wl; do
        P "    $_wl"
      done
      NOTE "counts by node:"
      sed -n 's/.*node=\([A-Za-z_0-9]*\).*/\1/p' /dev/.asb/write_errors 2>/dev/null |
        sort | uniq -c | sort -rn | head -6 | while read -r _wn _wnode; do
          P "    ${_wnode}: ${_wn} rejected write(s)"
        done
    else
      NOTE "(no rows recorded yet - failures counted but nothing written to /dev/.asb/write_errors)"
    fi
  fi
else
  P "  (native state unavailable — start the governor before checking applied telemetry)"
fi

# =====================================================================
SEC "0a1. STOCK-FILE INVENTORY  (what was patchable at install — install_probe.txt)"
_probe="/data/adb/asb/install_probe.txt"
if [ -f "$_probe" ]; then
  # Echo the install-time per-subsystem summary (audio/wifi/perf/gps/camera/cpu)
  # plus the declared audio SKU, so a field report shows exactly what ASB found
  # it could tune on this specific model.
  _pl="$(grep -E '^[[:space:]]*declared_sku=' "$_probe" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')"
  [ -n "$_pl" ] && P "  $_pl"
  # Per-subsystem summary of what ASB actually tuned on THIS model (key-level).
  sed -n '/SUMMARY (what ASB/,/Inventory only/p' "$_probe" 2>/dev/null \
    | grep -E '^[[:space:]]+(audio|wifi|perf|gps|camera|cpu)[[:space:]]+:' \
    | while IFS= read -r _ln; do P "  $_ln"; done
  # Key-level tunability detail (which exact keys exist on this device's stock).
  _ct="$(grep -E '^[[:space:]]*camera_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _at="$(grep -E '^[[:space:]]*audio_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _wt="$(grep -E '^[[:space:]]*wifi_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _mt="$(grep -E '^[[:space:]]*media_codecs_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _pt="$(grep -E '^[[:space:]]*perf_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  _gt="$(grep -E '^[[:space:]]*gps_tunable=' "$_probe" 2>/dev/null | head -1 | sed 's/.*=//')"
  if [ -n "$_ct$_at$_wt$_mt$_pt$_gt" ]; then
    P "  tunable: camera=${_ct:-?} audio=${_at:-?} wifi=${_wt:-?} media=${_mt:-?} perf=${_pt:-?} gps=${_gt:-?}"
  fi
  NOTE "Captured at install. Full inventory + key lists: $_probe"
else
  P "  (install_probe.txt not present — written on next install)"
fi

# =====================================================================
SEC "0a2. DEVICE-ADAPTIVE BOUNDS  (OP15-ratio synthesis — device_bounds.env)"
_dbounds="/data/adb/asb/device_bounds.env"
_ovr_flag="$(cfg device_bounds_override)"
P "  override active       : ${_ovr_flag:-0}  (governor consumes device_bounds.env only when =1)"
_dba="$(_rget device_bounds_applied /dev/.asb/state)"
case "${_ovr_flag:-0}:${_dba:-}" in
  1:0) P "  [WARN] override=1 but the governor loaded 0 values - it runs the compiled OP15 reference rails (snapped to this device's table)" ;;
  1:[1-9]*) P "  governor loaded       : ${_dba} value(s) at start" ;;
esac
if [ -f "$_dbounds" ]; then
  _dconf="$(grep -E '^# confidence=' "$_dbounds" 2>/dev/null | head -1 | sed 's/^# confidence=//')"
  P "  synthesis confidence  : ${_dconf:-unknown}"
  _nvals="$(grep -cE '^[A-Z].*=' "$_dbounds" 2>/dev/null)"
  if [ "${_nvals:-0}" -gt 0 ] 2>/dev/null; then
    P "  synthesised bounds (scaled from OP15 ratios, snapped to this device):"
    grep -E '^[A-Z].*=' "$_dbounds" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
    if [ "${_ovr_flag:-0}" != "1" ]; then
      NOTE "These are a PREVIEW — not applied (override flag is off). The governor is using its compiled defaults. On OP15 the synthesised values equal those defaults anyway."
    else
      NOTE "ACTIVE: the governor loaded these over its compiled defaults at boot."
    fi
  else
    P "  (no overrides emitted — see confidence note above; compiled defaults stand)"
  fi
else
  P "  (device_bounds.env not present yet — writes at install or next boot)"
fi

# =====================================================================
SEC "0b. MODULE STATE  (running, mounts, governor)"
P "  module flags:"
for _fl in disable remove update skip_mount; do
  [ -f "$MODDIR/$_fl" ] && P "    - $_fl present (!!)" || P "    - $_fl absent (ok)"
done
# governor process
_gov_pid="$(pgrep -f 'asb_governor' 2>/dev/null | head -1)"
[ -z "$_gov_pid" ] && _gov_pid="$(pgrep -f '/asb' 2>/dev/null | head -1)"
V "ASB governor process alive" "running" "$([ -n "$_gov_pid" ] && echo running)" present
P "  current profile : $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# is module's system actually mounted?
_mounted="$(grep -c "AutoSystemBoost" /proc/mounts 2>/dev/null)"
NOTE "mount entries mentioning the module: ${_mounted:-0}"
# how the overlay arrived
P "  partitions handled by root mgr (from mounts):"
for _pp in vendor odm product system_ext; do
  grep -q " /$_pp " /proc/mounts 2>/dev/null && P "    - /$_pp is a mount point" || P "    - /$_pp not separately mounted"
done

# =====================================================================
SEC "1. AUDIO  (mixer files + runtime props)"
# The SKU the platform reads first. A device can carry several sku_* trees side by side
# (pineapple next to cliffs on OP12/Ace 5); the plain glob took the alphabetically first one,
# so the report quoted a mixer file the audio HAL never loads.
MIX=""
[ -n "$_ad_live" ] && MIX="$(firstf "$_ad_live/mixer_paths_*_cdp.xml" "$_ad_live/mixer_paths*.xml")"
[ -n "$MIX" ] || MIX="$(firstf '/vendor/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/odm/etc/audio/sku_*/mixer_paths_*_cdp.xml' '/vendor/etc/audio/mixer_paths*.xml' '/odm/etc/audio/mixer_paths*.xml')"
if [ -n "$MIX" ]; then
  P "  mixer file: $MIX"
  _vpeak=$(grep -oE '(RX_RX[012]|WSA_RX[01]) Digital Volume" value="[0-9]+"' "$MIX" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
  _vclip=$(grep -c '\(RX_RX[012]\|WSA_RX[01]\) Digital Volume" value="\(9[0-9]\|1[0-9][0-9]\)"' "$MIX" 2>/dev/null)
  _iir=$(grep -c 'IIR0 Enable Band[1-5]" value="1"' "$MIX" 2>/dev/null)
  _rdac=$(grep -c 'HPH[LR]_RDAC Switch" value="1"' "$MIX" 2>/dev/null)
  NOTE "RX/WSA Digital Volume peak: ${_vpeak:-n/a}  (84=0dB unity; SM8650/pineapple caps at 84, sun/canoe accept 88)"
  V "No out-of-range Digital Volume (>88 would break the speaker path)" "0" "$_vclip" eq
  # Only ASB's own claim is a verdict.
  #
  # With audio_profile=stock the module does not touch the mixer at all, so whatever the
  # vendor left in IIR0 is the vendor's business - reporting it as FAIL blamed ASB for a
  # setting it never wrote. The check is still worth printing, just not as a verdict.
  # The mixer flatten ships inside the /vendor overlay. With VENDOR_OVERLAY=0 the module
  # never mounts it, so the live mixer is the vendor's and 5 engaged bands is expected -
  # the audio block below already says "not checked" for exactly this reason, while this
  # line two screens earlier still counted a FAIL against the same missing overlay.
  _iir_vov="$(grep -E '^[[:space:]]*VENDOR_OVERLAY=' "$MODDIR/features.conf" 2>/dev/null \
             | head -1 | sed 's/.*=//' | tr -d ' \r' | cut -d'#' -f1)"
  if [ "$(cfg audio_profile)" = "stock" ]; then
    NOTE "IIR0 EQ bands engaged = $_iir (audio_profile=stock - vendor owns the mixer)"
  elif [ "${_iir_vov:-0}" != "1" ]; then
    NOTE "IIR0 EQ bands engaged = $_iir (flatten needs the /vendor overlay, VENDOR_OVERLAY=0 - not checked)"
  else
    V "IIR0 EQ bands flattened (engaged=0)" "0" "$_iir" eq
  fi
  V "Class-H headphone DAC armed (RDAC=1 present)" "1" "$_rdac" ge
  # aggressive (toggle)
  _aud_aggr="$(cfg audio_dac_hifi)"
  [ -n "$_aud_aggr" ] || _aud_aggr="$(cfg AUDIO_AGGRESSIVE)"
  NOTE "audio_dac_hifi toggle = ${_aud_aggr:-0}"
  # These land through the /vendor overlay, so without it there is nothing to check.
  #
  # The tweak being on does not mean the writes happened: mixer_paths and the media
  # profiles are patched into an overlay, and VENDOR_OVERLAY=0 ships in this build. The
  # report showed three FAIL lines for a mechanism that was never enabled, which reads as
  # a broken module rather than a disabled feature.
  _vov="$(grep -E '^[[:space:]]*VENDOR_OVERLAY=' "$MODDIR/features.conf" 2>/dev/null \
          | head -1 | sed 's/.*=//' | tr -d ' \r' | cut -d'#' -f1)"
  if [ "${_aud_aggr:-0}" = "1" ] && [ "${_vov:-0}" != "1" ]; then
    NOTE "mixer/profile tweaks need the /vendor overlay (VENDOR_OVERLAY=0) - not checked"
  fi
  if [ "${_aud_aggr:-0}" = "1" ] && [ "${_vov:-0}" = "1" ]; then
    _comp=$(grep -c 'HPH[LR] Compander" value="1"' "$MIX" 2>/dev/null)
    _hifi=$(grep -c 'RX HPH Mode" value="CLS_H_HIFI"' "$MIX" 2>/dev/null)
    V "Aggressive: HPH companders OFF (engaged=0)" "0" "$_comp" eq
    V "Aggressive: RX HPH Mode = CLS_H_HIFI" "1" "$_hifi" ge
  fi
else
  NA=$((NA+1)); P "  [N/A ] no mixer_paths*.xml found on /vendor or /odm"
fi
# hi-res
APOL="$(firstf '/vendor/etc/audio_policy_configuration*.xml' '/odm/etc/audio_policy_configuration*.xml' '/vendor/etc/audio/audio_policy_configuration*.xml')"
[ -n "$APOL" ] && V "Hi-res 384000 present in audio policy" "1" "$(grep -c '384000' "$APOL" 2>/dev/null)" ge || NOTE "audio_policy_configuration not found"
# runtime audio props
#
# The last four are the audio path's power-relevant knobs: how long a track must be to
# reach the DSP offload path, how large a HAL period is, whether the output can suspend,
# and the ADM phase shift. Another module ships its own values for all of them (offload
# from 60 s down to 5, buffer 32 KB up to 200, period multiplier 4) - plausible numbers,
# but numbers the OEM already chose for this chip.
#
# Reported, not changed: the same value that saves power on one device underruns on
# another, and this project has no way to tell which without seeing what the fleet
# actually ships. Read them across a few devices first, then decide.
P "  runtime audio props:"
for _p in persist.audio.hifi persist.audio.uhqa vendor.audio.hifi.dac \
          vendor.audio.feature.hifi_audio.enable \
          persist.vendor.audio.hifi.dac.enable \
          ro.vendor.audio.sdk.fluencetype \
          vendor.audio.offload.buffer.size.kb \
          persist.vendor.audio.ull.period.size \
          vendor.audio.offload.min.duration.secs \
          vendor.audio_hal.period_multiplier \
          vendor.audio.hal.output.suspend.supported \
          vendor.audio.adm.phaseshift.ms; do
  P "    $_p = $(gp $_p)"
done

# HFP state, because that is where the field failures are.
#
# A capture from a CPH2769 recorded 35 hfp_audio disconnects in one session, median hold
# 27 seconds, 18 of them under 30 - the signature of SCO being opened, carrying nothing,
# and being torn down. A2DP was almost untouched, so this is the call profile, not music.
#
# ASB does not configure HFP and will not start: the read-only picture comes first. These
# are the knobs that decide whether the stack keeps an idle SCO link alive, and knowing
# their live values is what separates a fix from a guess.
P "  HFP / SCO state:"
for _p in persist.bluetooth.hfp_available_guard bt.max.hfpclient.connections \
          persist.vendor.btstack.enable.swb persist.vendor.qcom.bluetooth.enable.splita2dp \
          persist.bluetooth.sco_managed_by_audio; do
  P "    $_p = $(gp $_p)"
done
_hfp_sr="$(settings get global bluetooth_hfp_client_enabled 2>/dev/null)"
P "    setting bluetooth_hfp_client_enabled = ${_hfp_sr:-<unset>}"
_hfp_ev="/data/adb/asb/bt_lifecycle_events.tsv"
if [ -r "$_hfp_ev" ]; then
  P "    recorded hfp disconnects: $(grep -c 'hfp_audio_disconnect' "$_hfp_ev" 2>/dev/null)"
  P "    recorded a2dp disconnects: $(grep -c 'a2dp_profile_disconnect' "$_hfp_ev" 2>/dev/null)"
else
  P "    (no lifecycle recording - start a capture with ASB_BT_RECONNECT_TRACE=1)"
fi
# audio_profile (replaced AUDIO_EQ_COMPAT + the property half of AUDIO_AGGRESSIVE)
NOTE "audio_profile = $(cfg audio_profile)"

# =====================================================================
# media_loudness rewrites the volume curves rather than any property, so the check is
# whether the curve file carries our marker - a config value alone proves nothing here.
NOTE "media_loudness = $(cfg media_loudness)"
_vt="$(firstf '/vendor/etc/default_volume_tables.xml' '/odm/etc/default_volume_tables.xml')"
case "$(cfg media_loudness)" in
  ''|stock|off|0)
    OFF "volume curves rebuilt by ASB - media_loudness=stock, curves are left alone" "media_loudness" ;;
  *)
    if [ -n "$_vt" ]; then
      V "  volume curves rebuilt by ASB" "present" "$(grep -m1 -o 'ASB:VOLCURVE' "$_vt" 2>/dev/null)" present
    fi ;;
esac
_a2dp_req="$(cfg bt_a2dp_offload)"
_a2dp_set="$(settings get global bluetooth_a2dp_offload_enabled 2>/dev/null)"
NOTE "bt_a2dp_offload: requested=${_a2dp_req:-auto}  ·  setting=${_a2dp_set:-<unavailable>}  ·  platform_disabled=$(gp persist.bluetooth.a2dp_offload.disabled)  ·  vendor_disabled=$(gp persist.vendor.bluetooth.a2dp_offload.disabled)"

SEC "0e. UCLAMP TIERS  (what the scheduler is allowed to ask for, per tier)"
# Read the tiers, not the lease.
#
# The lease line reports whichever tier claimed it last, so a diag showed desired=24 - the
# background value - while top-app was a different number entirely. One figure standing in
# for four made it impossible to tell whether a change to the foreground tier had taken
# effect, which is exactly the question that mattered after top-app was exempted from
# perf_ceiling_pct.
#
# top-app is the one the user is waiting on. If it reads far below the profile rail, the
# scheduler will refuse to raise frequency for the app on screen no matter what the task
# asks for - and the work then finishes slowly, with the display and radio awake for all
# of it.
for _uc_root in /dev/cpuctl /sys/fs/cgroup/cpu; do
  [ -d "$_uc_root" ] || continue
  for _uc_t in top-app foreground background system-background; do
    _uc_v=""
    for _uc_f in "$_uc_root/$_uc_t/cpu.uclamp.max" "$_uc_root/$_uc_t/uclamp.max"; do
      [ -r "$_uc_f" ] && { _uc_v="$(cat "$_uc_f" 2>/dev/null)"; break; }
    done
    [ -n "$_uc_v" ] && NOTE "$_uc_t uclamp.max = $_uc_v"
  done
  _uc_ls=""
  for _uc_f in "$_uc_root/top-app/cpu.uclamp.latency_sensitive" "$_uc_root/top-app/uclamp.latency_sensitive"; do
    [ -r "$_uc_f" ] && { _uc_ls="$(cat "$_uc_f" 2>/dev/null)"; break; }
  done
  [ -n "$_uc_ls" ] && NOTE "top-app latency_sensitive = $_uc_ls"
  break
done
NOTE "(profile rails: top-app should track UCL_TOP_MAX; perf_ceiling_pct no longer scales it)"
# The global ceiling on what any task may request as its minimum. OxygenOS ships 1024
# ("anything may demand full capacity"); ASB lowers it to the profile's top-app floor
# (never below 205). A live 1024 under a non-performance profile means the ROM put it
# back and per-cgroup ceilings are being outranked - reconcile watches this drift.
_gmin_live="$(cat /proc/sys/kernel/sched_util_clamp_min 2>/dev/null)"
case "$_gmin_live" in
  ''|*[!0-9]*) : ;;
  *) NOTE "global sched_util_clamp_min = $_gmin_live (ASB target: (UCL_TOP_MIN*1024)/100, floor 205; OxygenOS default 1024)" ;;
esac

SEC "0f. LSPOSED LOGGING  (read only — ASB never changes another module's settings)"
# Report it, do not touch it.
#
# A user asked ASB to switch LSPosed logging off, reasoning that the logging costs battery.
# ASB will not: LSPosed is a separate root module with its own configuration, and writing
# into another module's files makes ASB the kind of unannounced second writer this project
# has spent weeks untangling on the cap path. LSPosed does not know about us and would not
# put its settings back.
#
# What is useful is showing the state, so the answer is one glance instead of a guess. On
# the capture that prompted this, LSPosed had written zero lines - the noisy tags were
# ifw_intent_matched, FlagUtils and SmartTempDdsSwitchController, all OxygenOS components.
_lsp_dir=""
for _d in /data/adb/lspd /data/adb/lspd/log /data/misc/lspd; do
  [ -d "$_d" ] && { _lsp_dir="$_d"; break; }
done
if [ -z "$_lsp_dir" ]; then
  NOTE "LSPosed not present (no /data/adb/lspd) - nothing to report"
else
  NOTE "LSPosed directory: $_lsp_dir"
  _lsp_log_bytes=0
  for _f in /data/adb/lspd/log/*.log /data/adb/lspd/log/*/*.log; do
    [ -f "$_f" ] || continue
    _sz=$(wc -c < "$_f" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) continue ;; esac
    _lsp_log_bytes=$(( _lsp_log_bytes + _sz ))
  done
  NOTE "log files on disk: $(( _lsp_log_bytes / 1024 )) KiB"
  # A verbose_* file is the one LSPosed only writes when verbose logging is enabled, so its
  # presence answers the question directly.
  _lsp_verbose=0
  for _f in /data/adb/lspd/log/verbose_*.log; do [ -f "$_f" ] && _lsp_verbose=1; done
  if [ "$_lsp_verbose" = "1" ]; then
    NOTE "verbose logging: ON  -  turn it off in the LSPosed manager under Logs, not here"
  else
    NOTE "verbose logging: no verbose_*.log present (likely off)"
  fi
  NOTE "(ASB reports this and changes nothing: another module's settings are its own)"
fi

SEC "1a2. AUDIO ROUTE  (what the pipeline is doing right now — read only)"
# Measure the audio path instead of asserting properties at it.
#
# A comparative audit of two other Qualcomm modules concluded that their real value is not
# the property packs they ship - those fight whoever else owns the same files - but the
# fact that they force the question: which route is actually active, and is anything
# offloaded? ASB has never been able to answer it, and audio is the most expensive screen-on
# phase in every capture we have: 348 mA and 14.83 %/h for Bluetooth playback in the last
# one, against 152 for the same audio with the screen off.
#
# Everything below is a read. Nothing here changes a route, a codec or a property - if a
# node is absent the line says so and the report moves on.
_ap="$(dumpsys audio 2>/dev/null)"
if [ -n "$_ap" ]; then
  NOTE "active devices: $(echo "$_ap" | grep -m1 -iE 'Devices?:.*(SPEAKER|BLUETOOTH|USB|HEADSET|HEADPHONE)' | sed 's/^[[:space:]]*//' | cut -c1-90)"
  NOTE "audio mode: $(echo "$_ap" | grep -m1 -iE '^[[:space:]]*Mode:' | sed 's/^[[:space:]]*//' | cut -c1-60)"
else
  NOTE "dumpsys audio unavailable - route unknown"
fi
# Offload EVIDENCE, not an offload verdict.
#
# The first version of this block said hw_params and the PCM device count told us whether
# the DSP or the CPU was decoding. They do not: hw_params describes a stream's format, the
# device count is static platform topology, and a2dp_offload.cap is a capability list -
# what the platform CAN do, not what it IS doing. A review caught the overreach, and it
# mattered: the next step is an A/B experiment on A2DP offload, and starting that from a
# guess dressed as a measurement is how you get a result that means nothing.
#
# So: gather the signals, print them, and say "unknown" when they do not agree. A blank is
# more useful than a confident wrong answer.
_ev_req="$(cfg bt_a2dp_offload)"
_ev_set="$(settings get global bluetooth_a2dp_offload_enabled 2>/dev/null)"
_ev_pdis="$(gp persist.bluetooth.a2dp_offload.disabled)"
_ev_vdis="$(gp persist.vendor.bluetooth.a2dp_offload.disabled)"
_ev_cap="$(gp persist.bluetooth.a2dp_offload.cap)"
# AudioFlinger names an offloaded or compressed thread outright; that is the only line here
# that describes the running pipeline rather than its configuration.
_ev_af="$(dumpsys media.audio_flinger 2>/dev/null | grep -m1 -iE 'Offload|Compress' | sed 's/^[[:space:]]*//' | cut -c1-70)"
NOTE "a2dp evidence: requested=${_ev_req:-auto} setting=${_ev_set:-<none>} platform_disabled=${_ev_pdis:-<none>} vendor_disabled=${_ev_vdis:-<none>}"
NOTE "a2dp codecs advertised: ${_ev_cap:-<none>}   (capability, not proof of live offload)"
NOTE "audioflinger thread: ${_ev_af:-<no offload/compress thread reported>}"
# An offload thread is not evidence unless it belongs to THIS route, right now.
#
# The first version called any AudioFlinger Offload/Compress thread proof of A2DP
# offload. A review pointed out what that misses: the thread may serve a different
# output, or linger after playback stopped. Either way it produces a confident answer
# about Bluetooth from a signal that never mentioned Bluetooth - the same overreach
# this block was rewritten to remove once already.
#
# Three things must agree before the verdict firms up: a thread exists, the active
# route is Bluetooth, and something is actually playing. Short of that the honest
# answer is what is printed - the evidence, and "unknown".
_ev_route="$(echo "$_ap" | grep -m1 -icE 'Devices?:.*BLUETOOTH')"
_ev_play="$(dumpsys audio 2>/dev/null | grep -m1 -cE 'AudioPlaybackConfiguration .*state:started')"
# Conflict first, in the same order the shared logkit uses.
#
# The previous order set "off" from the properties and then let the thread branch
# overwrite it, so a phone whose vendor property blocks offload while AudioFlinger shows
# a thread on an active BT route was told "offload thread present" - a confident answer
# assembled from two signals that contradict each other. The shared logkit already calls
# that case "unknown (conflicting)", and two copies of one contract disagreeing is the
# defect this whole block was rewritten twice to remove.
_ev_blocked=0
case "$_ev_pdis$_ev_vdis" in *true*) _ev_blocked=1 ;; esac
if [ -n "$_ev_af" ] && [ "$_ev_blocked" = "1" ]; then
  _ev_verdict="unknown (conflicting AudioFlinger/property evidence)"
elif [ -n "$_ev_af" ] && [ "${_ev_route:-0}" -gt 0 ] && [ "${_ev_play:-0}" -gt 0 ]; then
  _ev_verdict="AudioFlinger offload/compress observed during BT playback (route association unverified)"
elif [ -n "$_ev_af" ]; then
  _ev_verdict="AudioFlinger offload/compress thread present (not tied to active BT playback)"
elif [ "$_ev_blocked" = "1" ]; then
  _ev_verdict="A2DP offload blocked by platform/vendor property"
else
  _ev_verdict="unknown"
fi
NOTE "offload state: $_ev_verdict"
NOTE "(read-only section: ASB changes nothing here, it only reports what the platform chose)"

SEC "1b. DSP ENGINE  (what the effect is actually doing)"
# The whole DSP block was missing from this report - six settings, none of them checked,
# on the subsystem most likely to be silently doing nothing. Config against live property
# is the only way to tell "configured" from "in force": the library reads the properties,
# not governor.conf.
_dsp_g="$(cfg dsp_loudness)"
case "$_dsp_g" in ''|0|off) NOTE "dsp_loudness = off - the effect is released from the audio path entirely" ;;
  *)
    _dsp_requested_mb=$((_dsp_g * 100))
    _dsp_expected_mb="$_dsp_requested_mb"
    [ "$_dsp_expected_mb" -gt 2500 ] && _dsp_expected_mb=2500
    # A thermally reduced gain is correct behaviour, not a failed write.
    #
    # asb_audio_apply backs the gain off to 1200 mB above 55C and 800 above 60. This check
    # compared against the REQUESTED value and reported FAIL on a phone that was simply
    # warm - the one state where the reduction is the whole point. A diagnostic that calls
    # a working safeguard a fault teaches the user to ignore it.
    _dsp_live_mb="$(gp persist.asb.dsp.gain_mb)"
    _dsp_t="$(grep -m1 '^cpu_max_c=' /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -dc '0-9')"
    case "$_dsp_t" in ''|*[!0-9]*) _dsp_t=0 ;; esac
    # Grade against what the module DECIDED, which it publishes, not against the request.
    #
    # asb_audio_apply.sh writes the thermally reduced target to gain_applied_mb. Guessing
    # from the die temperature at report time missed every case where the phone had cooled
    # between the back-off and the report: seven captures showed want 2500, live 800 or
    # 1200, with the die already under 55 C - a deliberate back-off counted as a failure.
    # If live matches the published decision, the path works; a mismatch against THAT
    # value is a real delivery failure and still FAILs below.
    _dsp_decided_mb="$(gp persist.asb.dsp.gain_applied_mb)"
    case "$_dsp_decided_mb" in ''|*[!0-9]*) _dsp_decided_mb="" ;; esac
    if [ -n "$_dsp_decided_mb" ] && [ "$_dsp_decided_mb" -lt "$_dsp_expected_mb" ] 2>/dev/null \
       && [ "$_dsp_live_mb" = "$_dsp_decided_mb" ]; then
      NOTE "DSP gain ${_dsp_live_mb}mB (requested ${_dsp_expected_mb}) - thermal back-off, applied as decided"
    elif [ "$_dsp_t" -ge 55 ] 2>/dev/null && [ "$_dsp_live_mb" -lt "$_dsp_expected_mb" ] 2>/dev/null; then
      NOTE "DSP gain ${_dsp_live_mb}mB (requested ${_dsp_expected_mb}) - reduced on purpose, die at ${_dsp_t}C"
    else
      V "  DSP gain applied (persist.asb.dsp.gain_mb)" "$_dsp_expected_mb" "$_dsp_live_mb"
    fi
    [ "$_dsp_requested_mb" -ne "$_dsp_expected_mb" ] && \
      NOTE "  requested ${_dsp_requested_mb}mB is safely capped to ${_dsp_expected_mb}mB (+25 dB compatibility limit)"
    V "  DSP enabled" "1" "$(gp persist.asb.dsp.enable)" eq
    ;;
esac
NOTE "dsp_bass = $(cfg dsp_bass)  ·  live: $(gp persist.asb.dsp.bass_db)"
NOTE "dsp_voice = $(cfg dsp_voice)  ·  live: $(gp persist.asb.dsp.voice)"
# The voice-tone stage lives in the native library: a library built before it ignores the
# setting while the WebUI shows the slider. AIDL logs " voice=", the legacy one reads "voice".
case "$(cfg dsp_voice)" in
  ''|0|off) : ;;
  *)
    _vt_lib=""
    for _vt_c in /vendor/lib64/soundfx/libasbdsp.so /vendor/lib/soundfx/libasbdsp.so; do
      [ -f "$_vt_c" ] && { _vt_lib="$_vt_c"; break; }
    done
    if [ -n "$_vt_lib" ]; then
      if grep -aq ' voice=' "$_vt_lib" 2>/dev/null || grep -aq 'persist.vendor.asb.dsp.%s' "$_vt_lib" 2>/dev/null \
           && grep -aq 'voice' "$_vt_lib" 2>/dev/null; then
        NOTE "  voice tone: supported by $_vt_lib"
      else
        NOTE "  voice tone: $_vt_lib predates it - the slider has no effect until the DSP library is rebuilt"
      fi
    fi
    ;;
esac
NOTE "dsp_compressor = $(cfg dsp_compressor)  ·  live comp: $(gp persist.asb.dsp.comp)"
# Output routing needs the rebuilt library to take effect; a config that says bt with a
# library that predates the feature will process everything and look correct here.
_dsp_o="$(cfg dsp_outputs)"
# Only meaningful while the engine is running.
#
# This reported FAIL on three of six devices in a cross-device sweep, every one of them
# with dsp_loudness=off - the effect is released from the audio path entirely, so the
# routing property is unset by design. Flagging that as a failure trains people to skim
# past red lines, which costs more than the check is worth.
if [ "$(cfg dsp_loudness)" = "off" ] || [ "$(cfg dsp_loudness)" = "0" ] || [ "$(gp persist.asb.dsp.enable)" != "1" ]; then
  NOTE "  DSP outputs: not applicable - the engine is off, so routing is unset by design"
else
  V "  DSP outputs live (persist.asb.dsp.outputs)" "${_dsp_o:-all}" "$(gp persist.asb.dsp.outputs)" eq
fi
NOTE "  DSP requested/applied gain: requested=$(gp persist.asb.dsp.gain_requested_mb)mB  ·  applied=$(gp persist.asb.dsp.gain_applied_mb)mB  ·  published_route=$(gp persist.asb.dsp.route)"
# Unset is expected while the engine is off - routing is not published then.
if [ "$(gp persist.asb.dsp.enable)" = "1" ]; then
  case "$(gp persist.asb.dsp.outputs)" in
    '') NOTE "outputs property unset - library may predate per-output routing (rebuild libasbdsp)" ;;
  esac
fi
_sfx64="$(ls -l /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null | awk '{print $5}')"
NOTE "installed library: ${_sfx64:-<absent>} bytes 64-bit  ·  ABI $(cat /data/adb/modules/AutoSystemBoost/dsp_abi_installed 2>/dev/null)"
# The process that loads effects has a different name per HAL generation: QTI's AIDL
# service on newer builds, the AOSP HIDL service (and its _64 variant) on OP12-era vendor
# images. Only the first name was tried, so on those phones the check silently vanished
# from the report instead of answering.
_dsp_pid=""
for _dsp_hn in audiohalservice.qti android.hardware.audio.service \
               android.hardware.audio.service_64 vendor.audio-hal vendor.audio-hal-aidl \
               android.hardware.audio.service.qti; do
  _dsp_pid="$(pidof "$_dsp_hn" 2>/dev/null | awk '{print $1}')"
  [ -n "$_dsp_pid" ] && { NOTE "audio HAL process: $_dsp_hn (pid $_dsp_pid)"; break; }
done
_dsp_on=0
case "$(cfg dsp_loudness)" in ''|0|off) : ;; *) [ "$(gp persist.asb.dsp.enable)" = "1" ] && _dsp_on=1 ;; esac
_dsp_map=""
[ -n "$_dsp_pid" ] && _dsp_map="$(grep -c asbdsp /proc/$_dsp_pid/maps 2>/dev/null | grep -v '^0$')"
_dsp_reg="$(dumpsys media.audio_flinger 2>/dev/null | grep -m1 -oiE 'ASB Loudness|AsbLoudness|asbdsp')"
if [ "$_dsp_on" = "1" ] && [ "$(gp persist.asb.dsp.route_allowed)" = "0" ] && [ -z "$_dsp_reg" ]; then
  # fix77: off the selected outputs the attach daemon releases the effect, so the stream can
  # use the offload path. Not attached is the intended state here, not a failure.
  NOTE "  DSP released on purpose: route $(gp persist.asb.dsp.route) is not in dsp_outputs=$(gp persist.asb.dsp.outputs) (audio stays on the low-power offload path)"
elif [ "$_dsp_on" = "1" ]; then
  # Present = PASS, absent = FAIL. ("has" mode looked for the literal word "present"
  # inside the value, so a library mapped 3 times and an effect named "ASB Loudness" were
  # both reported as failures.)
  if [ -n "$_dsp_pid" ]; then
    if [ -n "$_dsp_map" ]; then
      V "  library mapped into the audio HAL" "present" "$_dsp_map" present
    else
      V "  library mapped into the audio HAL" "present" "absent" eq
    fi
  fi
  # Enabled, configured, and not registered means the sound is NOT being processed - the
  # gain and bass PASS lines above only show what ASB asked for. This used to print N/A,
  # which hid the one result that says the DSP does nothing on this phone.
  if [ -n "$_dsp_reg" ]; then
    V "  effect registered with audioflinger" "present" "$_dsp_reg" present
  else
    V "  effect registered with audioflinger" "present" "absent" eq
  fi
  if [ -z "$_dsp_reg" ]; then
    NOTE "  DSP is enabled but no ASB effect is attached: what you hear is stock audio"
    NOTE "  installed ABI: $(cat /data/adb/modules/AutoSystemBoost/dsp_abi_installed 2>/dev/null) - try dsp_effect_abi=legacy/aidl and reboot, then rerun asbdiag"
    # Which of the three ways it can fail: no config the HAL reads lists the library, the
    # file is not visible / labelled for the HAL, or the HAL tried and refused it (dlopen,
    # symbol, version). A field report on an OnePlus 12 had only "absent" twice and nothing
    # to act on.
    for _dcfg in /odm/etc/audio_effects_config.xml /vendor/odm/etc/audio_effects_config.xml \
                 /vendor/etc/audio_effects_config.xml /vendor/etc/audio/sku_*/audio_effects_config.xml \
                 /odm/etc/audio_effects.xml /vendor/odm/etc/audio_effects.xml \
                 /vendor/etc/audio/sku_*/audio_effects.xml \
                 /vendor/etc/audio_effects.xml /system/etc/audio_effects.xml; do
      [ -f "$_dcfg" ] || continue
      if grep -q 'asb' "$_dcfg" 2>/dev/null; then NOTE "  effects config lists ASB: $_dcfg"
      else NOTE "  effects config WITHOUT ASB: $_dcfg"; fi
    done
    # The file the HAL loads is the FIRST hit in AOSP's order, per name (audio_effects.xml
    # for a HIDL HAL, audio_effects_config.xml for AIDL). Name it, so "registered in three
    # files" cannot hide that the one being read is the fourth.
    _dsku="$(gp ro.boot.product.vendor.sku)"
    for _dn in audio_effects.xml audio_effects_config.xml; do
      _dwin=""
      for _dd in ${_dsku:+/odm/etc/audio/sku_$_dsku /vendor/etc/audio/sku_$_dsku} /odm/etc /vendor/etc /system/etc; do
        [ -f "$_dd/$_dn" ] && { _dwin="$_dd/$_dn"; break; }
      done
      [ -n "$_dwin" ] || continue
      if grep -q 'asbdsp' "$_dwin" 2>/dev/null; then NOTE "  first $_dn in lookup order (read by the HAL): $_dwin - lists ASB"
      else NOTE "  first $_dn in lookup order (read by the HAL): $_dwin - does NOT list ASB"; fi
    done
    if [ -f /data/adb/asb/dsp_effects_blocked ]; then
      NOTE "  effects crash fuse TRIPPED ($(cat /data/adb/asb/dsp_effects_blocked 2>/dev/null)): audioserver kept restarting with the effect registered, so it was removed"
      NOTE "  to try again: delete /data/adb/asb/dsp_effects_blocked and reinstall"
    fi
    grep -s 'action=effects_guard' /data/adb/asb/vendor_mounts.log | tail -n 3 | while IFS= read -r _dl; do P "    $_dl"; done
    for _dlib in /vendor/lib64/soundfx/libasbdsp.so /vendor/lib/soundfx/libasbdsp.so; do
      [ -f "$_dlib" ] && NOTE "  $(ls -Z "$_dlib" 2>/dev/null | awk '{print $1}')  $_dlib"
    done
    logcat -d -t 4000 2>/dev/null | grep -iE 'asbdsp|asb_loudness|EffectsFactory.*(fail|error|cannot|could not)|loadLibrary|dlopen.*soundfx' \
      | tail -n 8 | while IFS= read -r _dl; do P "    log: $(printf '%s' "$_dl" | cut -c1-200)"; done
  fi
else
  OFF "DSP effect registration - the DSP engine is off" "dsp"
fi

# =====================================================================
SEC "2. BLUETOOTH"
# Automatic link-drop mitigation, when it engaged.
#
# Shown because the phone quietly changed a Wi-Fi setting on the user's behalf, and that
# should never be invisible - even when it is the right call.
if [ -f "${ASB_CONFIG_STATE:-/data/adb/asb}/bt_link_auto" ]; then
  NOTE "repeated audio-link drops were detected - Wi-Fi scanning is throttled to keep the link"
  _btl="${ASB_CONFIG_STATE:-/data/adb/asb}/bt_link_watch.log"
  [ -s "$_btl" ] && tail -2 "$_btl" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
fi
_btmode="$(cfg bt_absvol_mode)"
NOTE "bt_absvol_mode toggle = ${_btmode:-auto}"
P "  live bluetooth props:"
for _p in persist.bluetooth.disableabsvol persist.bluetooth.leaudio.enabled \
          persist.bluetooth.spatial_audio_support persist.bluetooth.enablenewavrcp \
          persist.bluetooth.a2dp_offload.cap; do
  P "    $_p = $(gp $_p)"
done
# global absolute-volume setting
_absvol="$(settings get global bluetooth_disable_absolute_volume 2>/dev/null)"
NOTE "settings global bluetooth_disable_absolute_volume = ${_absvol:-<unset>}"
case "${_btmode:-auto}" in
  on)  V "BT absolute volume disabled (mode=on)" "1" "$_absvol" eq ;;
  off) V "BT absolute volume kept (mode=off)" "0" "$_absvol" eq ;;
  *)   NOTE "BT mode auto — no forced expectation" ;;
esac

# =====================================================================
SEC "3. GPS / LOCATION"
_gfound=0
for GP in /vendor/etc/gps.conf /odm/etc/gps.conf /vendor/odm/etc/gps.conf /system/etc/gps.conf; do
  [ -f "$GP" ] || continue
  _gfound=1
  _cap=$(grep -E '^CAPABILITIES=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  _ntp=$(grep -E '^(NTP_SERVER|XTRA_SERVER_1)=' "$GP" 2>/dev/null | head -1 | tr -d ' \r')
  P "  file: $GP"
  # CAPABILITIES is a hardware capability bitmask that legitimately differs per SoC (OP15
  # canoe=0x3F, OP12 pineapple=0x17).
  # It must NOT be forced to a fixed value — doing so could advertise GNSS features the chip
  # lacks.
  [ -n "$_cap" ] && NOTE "GNSS $_cap (device-native bitmask; not forced)"
  [ -n "$_ntp" ] && NOTE "NTP/XTRA: $_ntp"
done
[ "$_gfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no gps.conf found in live system"; }

# =====================================================================
SEC "4. WI-FI"
_wfound=0
for WF in /vendor/etc/wifi/*/WCNSS_qcom_cfg.ini /vendor/etc/wifi/WCNSS_qcom_cfg.ini /odm/etc/wifi/*/WCNSS_qcom_cfg.ini; do
  [ -f "$WF" ] || continue
  _wfound=1
  P "  file: $WF"
  _pmd=$(grep -E '^gRuntimePMDelay=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  # Note when the live file is stock because the overlay never mounted.
  #
  # asbdiag reads the live /vendor file. With no overlay mounted that file is stock and
  # every Wi-Fi check reports FAIL although the module wrote its copy correctly - the
  # same confusion the camera checks had before they learned to name the mount problem.
  # The checks below still run; this line says which kind of failure they are.
  _wf_mod="${MODDIR}${WF}"
  # Say WHY the live file is stock. With VENDOR_OVERLAY=0 the module never mounts
  # $MODDIR/vendor at all - KernelSU binds only $MODDIR/system by itself - so "did not
  # mount" read as a mount failure when it is a feature switched off by design.
  _wf_vov="$(grep -E '^[[:space:]]*VENDOR_OVERLAY=' "$MODDIR/features.conf" 2>/dev/null \
            | head -1 | sed 's/.*=//' | tr -d ' \r' | cut -d'#' -f1)"
  if [ -f "$_wf_mod" ] && grep -qE '^gActiveMaxChannelTime=40' "$_wf_mod" 2>/dev/null &&
     ! grep -qE '^gActiveMaxChannelTime=40' "$WF" 2>/dev/null; then
    if [ "${_wf_vov:-0}" != "1" ]; then
      NOTE "  module copy has the tweak; $WF stays stock because VENDOR_OVERLAY=0"
    else
      NOTE "  module copy has the tweak but $WF is stock - the overlay did not mount"
    fi
  fi
  _amc=$(grep -E '^gActiveMaxChannelTime=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  _bbw=$(grep -E '^gBusBandwidthVeryHighThreshold=' "$WF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')
  # Device-safe clamp semantics: the patch only LOWERS these toward a ceiling and never raises
  # a device that already ships a better (lower) value.
  # With the overlay off these read the vendor's own file, so a PASS or FAIL here would
  # grade the ROM, not ASB: two passed only because stock already sat under the ceiling,
  # the third failed only because stock is 60. Report the values, count nothing.
  if [ "${_wf_vov:-0}" != "1" ]; then
    NOTE "  WCNSS live values (vendor, overlay off): gRuntimePMDelay=${_pmd:-?} gActiveMaxChannelTime=${_amc:-?} gBusBandwidthVeryHighThreshold=${_bbw:-?}"
  else
  [ -n "$_pmd" ] && V "  gRuntimePMDelay<=2000 (lower=quicker idle)" "2000" "$_pmd" le
  [ -n "$_amc" ] && V "  gActiveMaxChannelTime<=40 (lower=shorter dwell)" "40" "$_amc" le
  [ -n "$_bbw" ] && V "  gBusBandwidthVeryHighThreshold<=12000" "12000" "$_bbw" le
  fi
done
[ "$_wfound" = 0 ] && { NA=$((NA+1)); P "  [N/A ] no WCNSS_qcom_cfg.ini found"; }
# supplicant safety
SUP="$(firstf '/vendor/etc/wifi/wpa_supplicant_overlay.conf' '/odm/etc/wifi/wpa_supplicant_overlay.conf')"
[ -n "$SUP" ] && V "supplicant keeps p2p_disabled=1 (Wi-Fi-safe)" "1" "$(grep -c 'p2p_disabled=1' "$SUP" 2>/dev/null)" ge
P "  live wifi link: $(dumpsys wifi 2>/dev/null | grep -m1 -iE 'mWifiInfo|SSID' | sed 's/^[[:space:]]*//' | cut -c1-70)"

# =====================================================================
# Can Settings be reached at all? Ask once, loudly, before anything that depends on it.
#
# A OnePlus 15R report had ten separate lines reading "cmd: Failure calling service
# settings" scattered through Bluetooth, RAM expand, adaptive battery and the lockscreen -
# each looking like its own small problem. They were one problem: the settings command
# cannot bind to the service on that device, and it exits 0 while failing, so every caller
# believed it had worked. One line at the top is worth ten buried ones.
_set_probe="$(settings get system screen_off_timeout 2>/dev/null)"
case "$_set_probe" in
  *'Failure calling service'*|*'Exception'*|'')
    _set_alt="$(content query --uri content://settings/system --where "name='screen_off_timeout'" 2>/dev/null \
                | sed -n 's/.*value=\(.*\)$/\1/p' | head -1)"
    if [ -n "$_set_alt" ]; then
      V "  Settings service" "reachable" "settings-cmd-broken-provider-ok" eq
      NOTE "the settings command fails on this device; ASB falls back to the content provider"
      NOTE "  any tweak that writes a setting works, but only through the fallback"
    else
      V "  Settings service" "reachable" "UNREACHABLE" eq
      NOTE "NEITHER the settings command NOR the content provider answers."
      NOTE "  Every setting-based tweak is inert on this device: Bluetooth absolute volume,"
      NOTE "  scan rate, blur, haptics, the OEM toggles. This is a device"
      NOTE "  or root-manager condition, not something ASB can work around."
    fi
    ;;
  *)
    NOTE "settings service: reachable (screen_off_timeout=$_set_probe)"
    ;;
esac

SEC "5. NETWORK / TCP"
P "  net.tcp buffer sizes (live props):"
for _p in net.tcp.buffersize.wifi net.tcp.buffersize.lte net.tcp.buffersize.5g \
          net.tcp.buffersize.default; do
  P "    $_p = $(gp $_p)"
done
P "  kernel tcp:"
P "    rmem_max = $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
P "    wmem_max = $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
P "    rmem_default = $(cat /proc/sys/net/core/rmem_default 2>/dev/null)"
P "    congestion = $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
P "    available_congestion = $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
P "    tcp_fastopen = $(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)"
P "    default_qdisc = $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
# DNS / connectivity props ASB may touch
P "  connectivity props:"
for _p in net.dns1 net.dns2 persist.sys.use_dingtalk_dns ro.ril.disable.power.collapse; do
  P "    $_p = $(gp $_p)"
done

# =====================================================================
SEC "5a. THERMAL / NETWORK CHOICES"
NOTE "sustained_temp_enter = $(cfg sustained_temp_enter)°C (ASB's own throttle point; vendor limits sit below and are not raised)"
# auto now means "the value the device shipped with", so the captured stock is worth
# printing - without it there is no way to tell an auto that resolved correctly from an
# auto that silently fell through.
if [ -f /data/adb/asb/net_stock.env ]; then
  NOTE "captured stock: $(tr '\n' ' ' < /data/adb/asb/net_stock.env)"
else
  NOTE "net_stock.env missing - auto has no stock value to resolve to yet (captured on next boot)"
fi
_tcp_w="$(cfg net_congestion)"
case "$_tcp_w" in
  ''|auto)
    # auto keeps the device's own algorithm: name what that is instead of a blank "want".
    _tcp_stock="$(sed -n 's/^STOCK_TCP_CC=//p' /data/adb/asb/net_stock.env 2>/dev/null | head -1)"
    V "  tcp congestion in force (auto = stock ${_tcp_stock:-?})" "present" \
      "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" present ;;
  *)
    # Presence only: whether the requested algorithm took is the net_congestion verdict
    # line below, and judging it here as well would count one refusal twice.
    V "  tcp congestion in force" "$_tcp_w" \
      "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" present ;;
esac
NOTE "available congestion algorithms: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
NOTE "qdisc in force: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
# Which tc this report sees, and whether it is real iproute2. Boot contexts can resolve
# tc to a limited applet that rejects the qdisc grammar outright (field log, CPH2745:
# "invalid argument 'root' to 'command'") while /system/bin/tc works - the apply now
# prefers the system binary, and this line shows what the diag context got.
NOTE "tc binary: $(command -v tc 2>/dev/null || echo none) ($(tc -V 2>&1 | head -1))"
# RPS and tx_queue_len: requested versus live, per interface.
#
# Both settings were switched on by the user - net_rps=little, net_txqueue=short - and
# nothing in this report confirmed either one. A tweak that writes a sysfs node and is
# never read back is indistinguishable from one that silently does nothing, which is
# the failure mode this file has hit repeatedly: camera, Wi-Fi, audio and qdisc all
# looked applied while landing somewhere nothing reads.
_rps_want="$(grep -m1 '^net_rps=' "$CONF" 2>/dev/null | cut -d= -f2)"
_txq_want="$(grep -m1 '^net_txqueue=' "$CONF" 2>/dev/null | cut -d= -f2)"
if [ -n "$_rps_want" ] && [ "$_rps_want" != "stock" ]; then
  _rps_seen=""
  for _rd in /sys/class/net/*/queues/rx-0/rps_cpus; do
    [ -r "$_rd" ] || continue
    _rn="$(echo "$_rd" | cut -d/ -f5)"
    case "$_rn" in lo|dummy*) continue ;; esac
    _rv="$(cat "$_rd" 2>/dev/null | tr -d ' ,0')"
    [ -n "$_rv" ] && _rps_seen="$_rps_seen $_rn"
  done
  if [ -n "$_rps_seen" ]; then
    NOTE "net_rps=$_rps_want - live on:$_rps_seen"
  else
    NOTE "net_rps=$_rps_want - requested but NO interface has a non-zero rps_cpus"
  fi
fi
if [ -n "$_txq_want" ] && [ "$_txq_want" != "stock" ]; then
  # Report every real interface, not one hardcoded name.
  #
  # This read rmnet_data0 and fell back to wlan0, so a phone on Wi-Fi with the modem
  # idle reported the modem's untouched 1000 and looked like the tweak had failed.
  # Naming each interface with its own value says plainly which ones took the setting.
  _txq_seen=""
  for _td in /sys/class/net/*/tx_queue_len; do
    [ -r "$_td" ] || continue
    _tn="$(echo "$_td" | cut -d/ -f5)"
    case "$_tn" in lo|dummy*|ifb*|gre*|erspan*|*vti*|ovnet*|p2p*|sit*|ip6tnl*) continue ;; esac
    _tv="$(cat "$_td" 2>/dev/null)"
    [ -n "$_tv" ] && _txq_seen="$_txq_seen $_tn=$_tv"
  done
  NOTE "net_txqueue=$_txq_want - live:${_txq_seen:- unreadable}"
fi


# Requested vs accepted, per key.
#
# The live sysctl alone cannot separate "the kernel refused this" from "nobody asked" - both
# look like the previous value.
# asb_net_apply.sh records a verdict per key, and pairing the two is the whole point of a
# diagnostic: a report stating bbr is configured while cubic runs, with no reason given, sends
# someone hunting a bug that is really a missing kernel module.
_nvf="/data/adb/asb/net_apply_result"
if [ -f "$_nvf" ]; then
  for _nk in net_congestion net_qdisc net_congestion_wifi net_congestion_mobile \
             net_qdisc_wifi net_qdisc_mobile wifi_country wifi_scan_throttle; do
    _nw="$(cfg "$_nk")"
    case "$_nw" in ''|auto) _net_auto="${_net_auto:+$_net_auto }$_nk"; continue ;; esac
    _nv="$(grep -E "^$_nk=" "$_nvf" 2>/dev/null | head -1 | sed 's/.*=//')"
    case "$_nv" in
      ok)          V "  $_nk" "$_nw" "$_nw" eq ;;
      unavailable)
        # "unavailable" for a qdisc key now also means "no working tc binary anywhere"
        # (the apply emits qdisc=...-unavailable then); for congestion it still means
        # the kernel lacks the algorithm. Name the right one.
        case "$_nk" in
          net_qdisc*) V "  $_nk (no working tc binary found)" "$_nw" "unavailable" eq ;;
          *)          V "  $_nk (kernel lacks it)" "$_nw" "unavailable" eq ;;
        esac ;;
      failed)
        # Name the cause when we have it.
        #
        # "write refused" is true of six different situations, five of which are facts
        # about the device rather than defects: no qdisc in the kernel, no module, a vendor
        # stack holding the root qdisc, a down interface, or SELinux. asb_net_apply now
        # records which one, so print it instead of sending the reader to guess.
        _qraw="$(grep -m1 "want=${_nw} " /data/adb/asb/qdisc_failures.log 2>/dev/null)"
        _qw="$(printf '%s\n' "$_qraw" | sed -n 's/.*why=\([a-z_]*\).*/\1/p')"
        case "$_qw" in
          kernel_lacks_qdisc)    V "  $_nk (kernel has no such qdisc)" "$_nw" "failed" eq ;;
          module_missing)        V "  $_nk (qdisc module not loadable)" "$_nw" "failed" eq ;;
          permission_or_selinux) V "  $_nk (refused - permission/SELinux)" "$_nw" "failed" eq ;;
          iface_absent)          V "  $_nk (interface was not up)" "$_nw" "failed" eq ;;
          root_qdisc_owned)      V "  $_nk (root qdisc held by vendor stack)" "$_nw" "failed" eq ;;
          # Empty reason INSIDE the failed branch is still a failure.
          #
          # This case only runs when the apply reported result=failed, so the apply ran
          # and tc refused. An empty why means tc printed an error none of the five
          # patterns above recognise - an unclassified failure, not a missing verdict.
          #
          # A previous change turned this into a NOTE on the reasoning that an empty grep
          # meant "never ran". That was wrong: the outer case on $_nv already separates
          # "never ran" (the *) branch below) from "failed", so this line hid a real tc
          # error behind an info marker. Restored to FAIL, with honest wording.
          # The writer records an unrecognised tc error as why=unclassified, never empty.
          # Without this branch it fell through to the generic "tc error" line, which sent
          # the reader to qdisc_failures.log without saying the error text is IN it.
          # Two reasons the writer records that this list did not know, so both fell to
          # the generic "tc error" line below. fell_back_to_fq here means fq was tried and
          # did not take either - the successful fallback now reports as ok upstream.
          fell_back_to_fq)       V "  $_nk (fq_codel and fq fallback both refused)" "$_nw" "failed" eq ;;
          tc_binary_limited)     V "  $_nk (tc is a limited applet, not iproute2)" "$_nw" "failed" eq ;;
          tc_error)              V "  $_nk (tc refused - see err= in qdisc_failures.log)" "$_nw" "failed" eq ;;
          unclassified)          V "  $_nk (tc refused - see err= in qdisc_failures.log)" "$_nw" "failed" eq ;;
          "")                    V "  $_nk (tc refused - reason not classified)" "$_nw" "failed" eq ;;
          *)                     V "  $_nk (tc error - see qdisc_failures.log)" "$_nw" "failed" eq ;;
        esac
        # Show the raw line instead of only pointing at the file. The sentence tc
        # printed is the reason the log exists, and "see qdisc_failures.log" defers the
        # answer by one upload every time - the reader of this report cannot open it.
        # The line also names the interface, which the verdict alone never did.
        [ -n "$_qraw" ] && NOTE "  qdisc_failures.log: $_qraw" ;;
      unsupported)
        # An N/A device fact, not a failed write - but the reason differs by key class.
        # qdisc: the link is flagged noqueue (modem-owned rmnet on current Qualcomm
        # kernels), there is no root qdisc for ASB to replace. congestion: the kernel
        # has no per-route congctl, so one algorithm serves every link and a per-link
        # request that differs from the global value cannot be honoured. Printing the
        # qdisc wording under a congestion key described the wrong mechanism.
        NA=$((NA+1))
        case "$_nk" in
          net_congestion_*) P "  [N/A ] $_nk (no per-route congctl on this kernel - links share the global algorithm)" ;;
          *)                P "  [N/A ] $_nk (link has no queue - the driver owns this interface)" ;;
        esac ;;
      pending)     NOTE "$_nk = $_nw - stored, waiting for a link to apply it to" ;;
      *)           NOTE "$_nk = $_nw - no verdict recorded yet (apply has not run)" ;;
    esac
  done
  [ -n "${_net_auto:-}" ] && OFF "network keys on auto (system default, nothing to verify): $_net_auto" "net:auto"
else
  NOTE "net_apply_result missing - no network key applied through the WebUI yet"
fi

# Radio policy is deliberately independent of the power profile. Report the master first, so a
# device log distinguishes a stored handover preference from an allowed active modem policy.
_radio_policy="$(cfg radio_policy_enable)"
case "$_radio_policy" in
  1) NOTE "Cellular/radio controls: enabled by explicit user choice; LPM state: $(cat /dev/.asb/lpm_mode 2>/dev/null || echo not-written)" ;;
  *) NOTE "Cellular/radio controls: off — profiles leave Android mobile-data context and TCP keepalives untouched" ;;
esac
# Fast handover is owned by modem LPM rather than the route-tuning script. Report both the
# stored request and the master gate; save/night correctly defer it until the screen is awake.
# Both are derived from the net_wifi_leave ladder now (asb_lpm.sh / asb_wifi_fallback.sh);
# the old net_handover_fast / net_handover_active keys are no longer in governor.conf, so
# reading them reported "off" on a phone whose fallback watcher was plainly running.
_nwl_d="$(cfg net_wifi_leave)"
case "$_nwl_d" in
  weak|unusable) _ho_fast=1; _ho_active=0 ;;
  aggressive)    _ho_fast=1; _ho_active=1 ;;
  *)             _ho_fast="$(cfg net_handover_fast)"; _ho_active="$(cfg net_handover_active)" ;;
esac
NOTE "net_wifi_leave = ${_nwl_d:-off}"
case "${_ho_fast:-0}:$_radio_policy" in
  1:1) NOTE "Wi-Fi → mobile handover: fast requested; LPM state: $(cat /dev/.asb/lpm_mode 2>/dev/null || echo not-written)" ;;
  1:*) NOTE "Wi-Fi → mobile handover: stored but inactive (cellular/radio controls off)" ;;
  *) NOTE "Wi-Fi → mobile handover: stock/off" ;;
esac
case "${_ho_active:-0}:$_radio_policy" in
  1:1) NOTE "Wi-Fi fallback: active opt-in; $(MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}" sh "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_wifi_fallback.sh" status 2>/dev/null || echo status-unavailable)" ;;
  1:*) NOTE "Wi-Fi fallback: stored but inactive (cellular/radio controls off)" ;;
  *) NOTE "Wi-Fi fallback: off" ;;
esac
# Why it fired, not just whether it is armed.
#
# A user reported the phone leaving a good Wi-Fi network and rejoining a minute later. The
# status line says "armed" either way, so there was nothing to look at - the watcher writes
# its reasoning to its own log and the report never showed it.
if [ -s "${ASB_CONFIG_STATE:-/data/adb/asb}/wifi_fallback.log" ]; then
  NOTE "recent Wi-Fi fallback decisions:"
  tail -6 "${ASB_CONFIG_STATE:-/data/adb/asb}/wifi_fallback.log" 2>/dev/null |
    while IFS= read -r _wfl; do P "    $_wfl"; done
fi

# A strongly battery-lean Smart session must not negate its own economy choice by holding
# mobile_data_always_on during a feed/media HEAVY burst.  This is read-only explanation of the
# native policy; confirmed games and camera sessions retain fast LPM.
_smart_lpm_bias="$(cfg smart_battery_bias)"
case "$_smart_lpm_bias" in
  ''|*[!0-9]*) ;;
  *) if [ "$_prof" = "smart" ] && [ "$_smart_lpm_bias" -ge 400 ]; then
       NOTE "Smart battery-lean: HEAVY media uses normal LPM; gaming/camera retain fast"
     fi ;;
esac

# Per-interface reality. The global sysctls say nothing about what each link is doing, and
# here they can legitimately differ: congestion is set per route, the queue per interface.
# iproute2, not the root manager's BusyBox applet: BusyBox `ip` does not print initcwnd or
# congctl, so every link read "no-window-tuning" whatever was set.
# Screen-off LTE: how often it engaged and how long the phone stayed on LTE, so an A/B of
# the switch has numbers (external audit R-3).
if [ "$(cfg net_screen_off_lte)" = 1 ] && [ -f "$MODDIR/runtime/asb_lte_screenoff.sh" ]; then
  _lst="$(MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_lte_screenoff.sh" status 2>/dev/null)"
  NOTE "screen-off LTE: applied $(printf '%s\n' "$_lst" | sed -n 's/^applies=//p') time(s), restored $(printf '%s\n' "$_lst" | sed -n 's/^restores=//p'), $(printf '%s\n' "$_lst" | sed -n 's/^lte_minutes=//p') min on LTE in total; now applied=$(printf '%s\n' "$_lst" | sed -n 's/^applied=//p') unsupported=$(printf '%s\n' "$_lst" | sed -n 's/^unsupported=//p')"
  # Whether 5G is allowed on the data SIM right now - the thing that matters if a restore
  # ever failed. Read the same way the script reads it.
  _l5="$(sh /data/adb/modules/AutoSystemBoost/runtime/asb_lte_screenoff.sh nr 2>/dev/null)"
  case "$_l5" in
    yes) NOTE "5G allowed now: yes" ;;
    no)  NOTE "5G allowed now: NO$([ -f /data/adb/asb/lte_screenoff.saved ] && echo ' (parked by ASB, screen off)' || echo ' - and ASB holds no record of removing it: if you did not turn 5G off yourself, turn it back on in Settings')" ;;
  esac
  grep -E 'restore:|repair:' /data/adb/asb/lte_screenoff.log 2>/dev/null | tail -n 2 | while IFS= read -r _l5l; do P "    $_l5l"; done
fi
_dip=ip; for _ipb in /system/bin/ip /vendor/bin/ip; do [ -x "$_ipb" ] && { _dip="$_ipb"; break; }; done
if command -v ip >/dev/null 2>&1 || [ -x "$_dip" ]; then
  # table all: Android has no default route in main - one table per network.
  "$_dip" route show table all 2>/dev/null | grep '^default' | while IFS= read -r _dr; do
    _di="$(printf '%s' "$_dr" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    [ -n "$_di" ] || continue
    case "$_di" in lo|dummy*|ifb*|vgate*|sit*|ip6tnl*) continue ;; esac
    _dcc="$(printf '%s' "$_dr" | grep -oE 'congctl [a-z_]+' | cut -d' ' -f2)"
    _dw="$(printf '%s' "$_dr" | grep -oE 'initcwnd [0-9]+ initrwnd [0-9]+')"
    _dq="$(tc qdisc show dev "$_di" 2>/dev/null | head -1 | awk '{print $2}')"
    NOTE "link $_di: qdisc=${_dq:-?} congctl=${_dcc:-<global>} ${_dw:-no-window-tuning}"
  done
fi

# Route-window support is a kernel capability, not a setting, and it decides whether the
# per-link congestion choice is genuinely simultaneous or a global switch in disguise.
if "$_dip" route show table all 2>/dev/null | grep '^default' | grep -q 'congctl'; then
  NOTE "per-route congctl: SUPPORTED (Wi-Fi and mobile can differ at the same time)"
else
  NOTE "per-route congctl: not in use (per-link choice falls back to the global switch)"
fi

# The link watcher re-applies route windows when the network changes. Without it the
# tuning survives only until the next reconnect, and does so silently.
# Say WHY, not just whether.
#
# "NOT running" covers at least six different situations - the tweak is off, ip is absent,
# the process exited, it never started, it was blocked by the duplicate guard, or SELinux
# refused it - and they need opposite responses. A single negative sentence sent two people
# hunting for a runtime defect when the answer was a config value.
if pgrep -f "asb_net_routes.sh watch" >/dev/null 2>&1; then
  if [ "$(cat /data/adb/asb/net_routes_watch.mode 2>/dev/null)" = poll ]; then
    NOTE "route link watcher: running in fallback poll (1 check/min; ip monitor ended: $(cat /data/adb/asb/net_routes_watch.exit 2>/dev/null))"
  else
    NOTE "route link watcher: running (event-driven on ip monitor; no polling)"
  fi
else
  _rw_cfg="$(cfg net_route_tune)"
  case "$_rw_cfg" in
    ''|off)
      NOTE "route link watcher: disabled (net_route_tune=${_rw_cfg:-unset}) - nothing to run" ;;
    *)
      if ! command -v ip >/dev/null 2>&1; then
        NOTE "route link watcher: missing_ip - the ip binary is not on PATH for this shell"
      elif [ ! -f "$MODDIR/runtime/asb_net_routes.sh" ]; then
        NOTE "route link watcher: missing_script - runtime/asb_net_routes.sh is not installed"
      elif [ -f /data/adb/asb/net_routes_watch.exit ]; then
        NOTE "route link watcher: exited - last reason: $(cat /data/adb/asb/net_routes_watch.exit 2>/dev/null)"
      else
        NOTE "route link watcher: not_started (net_route_tune=$_rw_cfg) - the half-hour"
        NOTE "  maintenance pass restarts it; if this persists, ip monitor is being refused"
      fi ;;
  esac
fi

SEC "5a2. SMART LEARNING  (what the current bucket knows)"
_sb_t="$(grep -m1 '^smart_bucket_temp_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_sb_d="$(grep -m1 '^smart_bucket_drain_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  # The last banked session beside the bucket average.
  #
  # If the session carried 46 C and the bucket reads 30, the averaging is at fault; if the
  # session itself arrives at 30, sessions are closing while the phone is already cool and
  # the learner never sees the warm part of the day.
  _sl="$(grep -m1 "^ses_last_temp=" /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _sd="$(grep -m1 "^ses_last_dur=" /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _sr="$(grep -m1 "^ses_last_reason=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '"')"
  # "none" means nothing has been banked SINCE THE GOVERNOR STARTED, so it only says
  # something next to how long that has been. Three reports in a row showed "none" and I
  # read it as frozen learning each time - the logs from the same days carry banked
  # sessions with reasons smart_periodic and smart_bucket_rollover. The governor had
  # simply restarted, which a config save is enough to do.
  _sup="$(grep -m1 '^governor_uptime_s=' /dev/.asb/state 2>/dev/null | tr -dc '0-9')"
  case "$_sup" in ''|*[!0-9]*) _sup="" ;; esac
  if [ "$_sl" = "0" ] || [ -z "$_sl" ]; then
    if [ -n "$_sup" ] && [ "$_sup" -lt 1500 ] 2>/dev/null; then
      NOTE "last banked session: none yet (governor up ${_sup}s; first bank needs ~20 min)"
    else
      NOTE "last banked session: none (governor up ${_sup:-?}s - expected one by now)"
    fi
  else
    NOTE "last banked session: max ${_sl}C over ${_sd}s (${_sr}), governor up ${_sup:-?}s"
  fi
# What the learner is taught vs the raw single sample (fix110). A large gap means the
# session's "peak" was a launch / dexopt blip, which the learner now ignores.
_spr="$(grep -m1 '^ses_max_temp_raw=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_sps="$(grep -m1 '^ses_max_temp_smooth=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
[ -n "$_spr" ] && [ -n "$_sps" ] && \
  NOTE "current session peak: raw ${_spr}C, smoothed ${_sps}C (the learner uses the smoothed one)"
_vr="$(grep -m1 '^smart_thermal_veto_reason=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
case "$_vr" in
  1) NOTE "thermal veto: ON - skin at or above thermal_skin_c" ;;
  2) NOTE "thermal veto: ON - junction at or above thermal_junction_hard_c" ;;
  3) NOTE "thermal veto: ON - no skin sensor, junction fallback threshold" ;;
  4) NOTE "thermal veto: ON - vendor clamps in the last hour over the veto limit" ;;
  5) NOTE "thermal veto: ON - recovery window" ;;
esac
NOTE "bucket avg temp = ${_sb_t:-0} (tenths C)  ·  avg drain = ${_sb_d:-0} (tenths %/h)"
_tw="$(grep -m1 '^smart_therm_warm_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tc="$(grep -m1 '^smart_therm_cool_x10=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
# Learned from this device's own median, not hardcoded - a OnePlus 12 and a 15 idle at
# different temperatures, so an absolute threshold would be right for one and wrong for
# the other. 420/380 showing here means not enough buckets have history yet.
NOTE "thresholds in force: warm above ${_tw:-?}, cool below ${_tc:-?} (tenths C, learned from this device)"
case "${_tw:-0}" in
  420) NOTE "still using fallback thresholds - fewer than 4 buckets have enough history" ;;
esac
# These two drive the thermal lean added in V62. A bucket with zero here has not reached
# the observation floor yet, which is not a fault - it means the lean is not applied.
#
# Compared against the LEARNED marks, not the 420/380 fallbacks.
#
# The line above prints what the device worked out - warm above 53.9 C on one capture -
# and then this test used 42.0 regardless, so a bucket at 50.3 C was reported as "runs
# warm" while the engine, using the real threshold, treated it as neutral. The report
# contradicted itself two lines apart, and the wrong half is the one people read.
#
# The fallbacks stay as defaults for the case where no learned value is available.
case "${_sb_t:-0}" in
  0) NOTE "no learned thermal history for this bucket yet - lean inactive" ;;
  *) if [ "${_sb_t:-0}" -gt "${_tw:-420}" ] 2>/dev/null; then
       NOTE "-> leaning toward battery (this bucket historically runs warm)"
     elif [ "${_sb_t:-0}" -lt "${_tc:-380}" ] 2>/dev/null; then
       NOTE "-> allowing more headroom (this bucket historically runs cool)"
     else
       NOTE "-> neutral (between the warm and cool marks)"
     fi ;;
esac
NOTE "sessions learned = $(grep -m1 '^smart_sessions_total=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"

SEC "5a3. BATTERY BEHAVIOUR  (the governor-owned switches)"
# Is the governor actually quiet while the screen is off?
#
# The awake share is the number that matters and it is not visible anywhere else. Two field
# captures on BALANCED showed idle at 83% awake and charging-idle at 100%, against a <5%
# target - the profile ran full sensor polling with the anti-clamp armed because its plan
# branch never looked at the screen. Print the plan so the next report answers this on its
# own instead of needing a full-day capture.
_pl_cls="$(grep -E '^plan_class=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
_pl_deep="$(grep -E '^plan_deep=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
_pl_ac="$(grep -E '^plan_ac=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/.*=//')"
# screen_on is not in the state file; read the display the way metrics does.
_pl_scr="$(cat /sys/kernel/oplus_display/panel_power_status 2>/dev/null | head -1)"
case "$_pl_scr" in 1|2) _pl_scr=1 ;; 0) _pl_scr=0 ;; *) _pl_scr="" ;; esac
# OnePlus 15 has no panel_power_status node, so the plan line read "screen_on=?" on every
# report from it. The governor's own status JSON (a line of the state file) carries what
# its screen detector decided - the uevent/key/dumpsys chain - so use that answer.
[ -z "$_pl_scr" ] && _pl_scr="$(grep -o '"screen":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)"
if [ -n "$_pl_cls" ]; then
  # Compare the configured point with actual live CPU sensors, not with hardware
  # trip/setpoint zones. On this OP15, `cpu-hw-trip-*` is a constant 95C shutdown
  # threshold, not a measurement; treating it as idle temperature created a false FAIL.
  _tp_set="$(cfg sustained_temp_enter)"
  _tp_now=0
  _tp_n=0
  for _tz in /sys/class/thermal/thermal_zone*; do
    _tt="$(cat "$_tz/type" 2>/dev/null)"
    case "$_tt" in *cpu*|*CPU*) : ;; *) continue ;; esac
    case "$_tt" in *trip*|*limit*|*shutdown*|*crit*|*alarm*) continue ;; esac
    _tv="$(cat "$_tz/temp" 2>/dev/null)"
    case "$_tv" in ''|*[!0-9]*) continue ;; esac
    [ "$_tv" -gt 1000 ] && _tv=$(( _tv / 1000 ))
    # Values outside plausible live CPU sensor range are setpoints/faults, not
    # evidence that a 40..70C throttle slider is permanently active.
    [ "$_tv" -lt 20 ] && continue
    [ "$_tv" -gt 85 ] && continue
    _tp_n=$((_tp_n + 1))
    [ "$_tv" -gt "$_tp_now" ] && _tp_now="$_tv"
  done
_tp_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
case "$_tp_up" in ''|*[!0-9]*) _tp_up=99999 ;; esac
case "$_tp_set" in
  ''|*[!0-9]*) : ;;
  *)
    if [ "$_tp_now" -gt 0 ] && [ "$_tp_set" -lt "$_tp_now" ]; then
      # A manual point is the user's own informed choice: the phone being above it right
      # now is the clamp doing exactly what was asked, not a value ASB got wrong - WARN,
      # not FAIL. FAIL stays for the auto/smart path, where ASB picked the point itself.
      if [ "$(cfg sustained_temp_mode)" = "manual" ]; then
        P "  [WARN] throttle point below live CPU sensor (manual ${_tp_set}C, live ${_tp_now}C)"
        NOTE "  manual threshold, so the sustained clamp engaging is the requested behaviour."
        NOTE "  Raise the point or switch the mode to auto if the clamp is not what you want."
        if [ "${_tp_up:-99999}" -lt 600 ] 2>/dev/null; then NOTE "  phone booted ${_tp_up:-?}s ago: post-boot dexopt/indexing heat, not a steady-state reading - re-check after ~10 min."; fi
      else
      V "  throttle point below live CPU sensor" "< ${_tp_now}C" "${_tp_set}C" eq
      NOTE "  a real CPU sensor is already above the selected point; sustained policy may engage."
      NOTE "  Check workload/cooling before raising the threshold."
      if [ "${_tp_up:-99999}" -lt 600 ] 2>/dev/null; then NOTE "  phone booted ${_tp_up:-?}s ago: post-boot dexopt/indexing heat, not a steady-state reading - re-check after ~10 min."; fi
      fi
    elif [ "$_tp_now" -gt 0 ] && [ "$_tp_set" -eq "$_tp_now" ]; then
      NOTE "throttle point ${_tp_set}C equals live CPU max ${_tp_now}C across ${_tp_n} sensor(s) - boundary observed, not a failure"
      NOTE "  Equality is a transition edge; the operational policy remains strict-above to avoid threshold chatter."
    else
      NOTE "throttle point ${_tp_set}C vs live CPU max ${_tp_now}C across ${_tp_n} sensor(s) - headroom ok"
    fi
    ;;
esac
NOTE "governor plan: class=$_pl_cls deep_sleep=${_pl_deep:-?} anti_clamp=${_pl_ac:-?} screen_on=${_pl_scr:-?}"
  if [ "$_pl_scr" = "0" ] && [ "$_pl_deep" = "0" ]; then
    NOTE "  screen is OFF but the plan is not the quiet one - expect a 5s tick and full polling"
  fi
fi
# These live in governor.conf and are read by the native governor, which reloads only on
# command. A value here that the governor has not picked up looks applied and is not -
# the single most common way a setting appears to do nothing.
NOTE "auto_battery = $(cfg auto_battery_enable)  ·  charge_aware = $(cfg charge_aware_enable)"
if [ "$(cfg sustained_temp_mode)" = manual ] && [ "$(cfg sustained_temp_user_override)" != 1 ]; then
  P "  [WARN] throttle mode is manual but sustained_temp_user_override=$(cfg sustained_temp_user_override): on Smart/Balanced/Performance the profile preset still wins over the slider (republished at boot)"
fi
# Gauge scale: what current_now integrates to against the falling SOC, screen-on only.
_csx="$(_rget current_scale_x100 /dev/.asb/state)"; _csn="$(_rget current_scale_windows /dev/.asb/state)"
case "${_csx:--1}" in
  ''|-1|*[!0-9]*) NOTE "battery current gauge: scale not measured yet (needs 5% of screen-on discharge)" ;;
  *) NOTE "battery current gauge: current_now integrates to x$((_csx / 100)).$(printf '%02d' $((_csx % 100))) of the SOC-derived drain (${_csn:-0} window(s), screen-on)"
     if [ "$_csx" -lt 80 ] || [ "$_csx" -gt 125 ]; then
       NOTE "-> a gauge property, not a load: every mA figure and mA threshold on this phone is off by that factor"
     fi ;;
esac
NOTE "cool_gaming = $(cfg cool_gaming)  ·  suppress_gaming_on_battery = $(cfg bat_suppress_gaming)"
NOTE "night_quiet = $(cfg night_quiet_enable)  ·  bg_trim = $(cfg BG_TRIM_LEVEL)"
NOTE "throttle mode = $(cfg sustained_temp_mode) at $(cfg sustained_temp_enter)°C"
# The governor does not publish this key in its state file, so there is nothing to compare
# against - checked rather than assumed. What CAN be verified is that the governor read
# the config at all: it logs the reload, and a config newer than the last reload means the
# value on screen is not the one in force.
_conf_mtime="$(stat -c %Y /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null)"
_gov_start="$(stat -c %Y /dev/.asb/governor.pid 2>/dev/null)"
if [ -n "$_conf_mtime" ] && [ -n "$_gov_start" ]; then
  if [ "$_conf_mtime" -gt "$_gov_start" ] 2>/dev/null; then
    # The governor now reloads governor.conf by itself when the file changes, so this is
    # a timing note, not an instruction. Telling the user to reload by hand after that
    # was fixed would send them chasing a problem that resolves within one tick.
    NOTE "governor.conf changed after the governor started - it reloads automatically within a tick; reboot only if a value still looks unapplied a minute later"
  else
    NOTE "governor started after the last config edit - its values are current"
  fi
fi
[ -f /data/adb/asb/auto_battery_origin ] \
  && NOTE "auto-battery is currently active - will return to $(cat /data/adb/asb/auto_battery_origin 2>/dev/null) when charged"

SEC "5a3b. THERMAL SOURCE PROVENANCE  (which sensor controls the governor)"
_tcs="$(_rget thermal_control_source /dev/.asb/state | tr -d '\"')"
_tcz="$(_rget thermal_control_zone /dev/.asb/state)"
_tconf="$(_rget thermal_source_confidence /dev/.asb/state)"
_trej="$(_rget thermal_rejected_type /dev/.asb/state | tr -d '\"')"
_traw="$(_rget thermal_rejected_raw /dev/.asb/state)"
_sq="$(_rget startup_quarantined /dev/.asb/state)"
NOTE "control source: ${_tcs:-unknown}  zone: ${_tcz:--1}  confidence: ${_tconf:-0}/2"
case "${_tconf:-0}" in
  2) NOTE "-> cross-checked against CPU peers" ;;
  1) NOTE "-> LOW confidence: derived fallback or source not peer-validated" ;;
  *) NOTE "-> uninitialized or unavailable" ;;
esac
if [ -n "$_trej" ]; then
  NOTE "rejected source: $_trej (raw=${_traw:-?}; raw is not displayed as degrees because scale may differ)"
fi
case "$(_rget surface_source /dev/.asb/state)" in
  zone)  NOTE "surface (body) temperature: dedicated zone (sys-therm)" ;;
  board) NOTE "surface (body) temperature: board_temp zone" ;;
  skin)  NOTE "surface (body) temperature: shell sensor - this phone has no sys-therm/board zone, so the shell reading stands in" ;;
  none)  NOTE "surface (body) temperature: NOT AVAILABLE - surface-based heat trims cannot engage on this phone" ;;
esac
if [ "${_sq:-0}" -gt 0 ] 2>/dev/null; then
  NOTE "startup quarantine: $_sq sample(s) excluded from Smart learning during boot settle"
fi
_txn=/data/adb/asb/config_last_txn
if [ -r "$_txn" ]; then
  NOTE "last config transaction: class=$(_rget result_class "$_txn") key=$(_rget key "$_txn") pre_epoch=$(_rget pre_epoch "$_txn") post_epoch=$(_rget post_epoch "$_txn") reload=$(_rget reload_accepted "$_txn") recovery=$(_rget recovery "$_txn") lock_owner=$(_rget lock_owner "$_txn") lock_owner_state=$(_rget lock_owner_state "$_txn") lock_age=$(_rget lock_age "$_txn") lock_recovered=$(_rget lock_recovered "$_txn")"
else
  NOTE "last config transaction: none recorded yet"
fi
_install_state=/data/adb/asb/last_install_state
if [ -r "$_install_state" ]; then
  NOTE "last install: config=$(_rget config_mode "$_install_state") source=$(_rget config_source "$_install_state") keys=$(_rget config_keys "$_install_state") module=$(_rget module_version "$_install_state") profiles=$(_rget named_profiles "$_install_state") learning=$(_rget smart_learning "$_install_state") snapshot=$(_rget snapshot_state "$_install_state")"
else
  NOTE "last install: no migration record (older installation or first boot not completed)"
fi

SEC "5a4. SUSPEND  (is the phone actually sleeping?)"
# The single most useful overnight number, and the one nothing used to show.
# CLOCK_MONOTONIC stops during suspend, CLOCK_BOOTTIME does not - their ratio over a
# screen-off stretch is the share of it the CPU stayed awake. A capture showed 73% across
# nine hours where the target is under 5%, with drain to match, and no part of the module
# could say so.
_awk_pct="$(grep -m1 '^awake_pct_screenoff=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_awk_win="$(grep -m1 '^awake_window_min=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
case "${_awk_pct:--1}" in
  -1|'') NOTE "not measured yet - needs 10 minutes of continuous screen-off" ;;
  *)
    NOTE "awake ${_awk_pct}% of the last ${_awk_win:-0} min of screen-off  (target: under 5%)"
    if [ "${_awk_pct:-0}" -gt 15 ] 2>/dev/null; then
      NOTE "-> the phone is NOT suspending properly. This costs more than any tuning here can save."
      NOTE "   Something holds a wakelock: check 'dumpsys batterystats' for the holder,"
      NOTE "   or run tools/logkit/asb_log_full_day.sh for an attributed report."
      NOTE "   Common causes: a connected Bluetooth device, a sync-heavy app, a bad alarm."
    elif [ "${_awk_pct:-0}" -gt 5 ] 2>/dev/null; then
      NOTE "-> higher than ideal but not alarming; one chatty app can account for this."
    else
      NOTE "-> suspending normally."
    fi ;;
esac
# The measured screen-off drain the governor learns (windows of 60+ min on battery). This
# is what action and the WebUI now use for the idle forecast instead of a fixed guess.
_odx="$(grep -m1 '^offdrain_pctph_x100=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_odn="$(grep -m1 '^offdrain_windows=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
case "${_odx:--1}" in
  -1|''|0) NOTE "screen-off drain: not measured yet - needs one screen-off stretch of 60+ min on battery" ;;
  *) NOTE "screen-off drain: $((_odx / 100)).$(printf '%02d' $((_odx % 100)))%/h measured over ${_odn:-1} window(s)  (good night: 0.3-0.7%/h)" ;;
esac

SEC "5a6. SCREEN-OFF CLASS  (what the last screen-off stretch actually was)"
# Two identical-looking idle hours can be deep sleep or Bluetooth playback. Naming which
# one it was is the difference between a usable night reference and a conclusion drawn
# from a media session.
if [ -r /dev/.asb/screenoff_class ]; then
  _sc="$(grep -m1 '^class=' /dev/.asb/screenoff_class 2>/dev/null | cut -d= -f2)"
  _sr="$(grep -m1 '^reason=' /dev/.asb/screenoff_class 2>/dev/null | cut -d= -f2-)"
  NOTE "class: ${_sc:-unknown} - ${_sr:-no reason recorded}"
  case "$_sc" in
    quiet)    NOTE "-> usable as a night reference" ;;
    media|network)
              NOTE "-> current here reflects audio or the radio, not CPU policy" ;;
    charging) NOTE "-> excluded from drain adaptation" ;;
    noisy)    NOTE "-> unexplained wakefulness; see the wakelock section below" ;;
  esac
else
  NOTE "not classified yet - runs on the screen-off sampling cycle"
fi
# Battery measurement confidence sits here too: a %/h figure is only as good as the
# window behind it, and both are read together or not at all.
_bwc="$(grep -m1 '^battery_window_confidence=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_bwr="$(grep -m1 '^battery_window_reason=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '"')"
case "${_bwc:-}" in
  3) NOTE "battery window: high confidence - ${_bwr}" ;;
  2) NOTE "battery window: medium - ${_bwr}" ;;
  1) NOTE "battery window: LOW - ${_bwr} (treat any %/h as an estimate)" ;;
  0) NOTE "battery window: no valid window - ${_bwr}" ;;
esac

SEC "5a9. THERMAL CONSENSUS  (is the control sensor believable?)"
# One temperature with no provenance is a claim, not a measurement. This shows what it was
# cross-checked against and whether the sources agreed.
_tct="$(grep -m1 '^thermal_control_source=' /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '\"')"
_tsc="$(grep -m1 '^thermal_source_confidence=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tph="$(grep -m1 '^thermal_peer_hi=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tpl="$(grep -m1 '^thermal_peer_lo=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tpn="$(grep -m1 '^thermal_peer_n=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_tcn="$(grep -m1 '^thermal_consensus=' /dev/.asb/state 2>/dev/null | cut -d= -f2- | tr -d '\"')"
_trt="$(grep -m1 '^thermal_rejected_type=' /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '\"')"
NOTE "control source: ${_tct:-unknown}"
case "${_tsc:-0}" in
  3) NOTE "confidence: HIGH - cross-checked and agrees with independent sensors" ;;
  2) NOTE "confidence: good - validated against peer CPU zones" ;;
  1) NOTE "confidence: LOW - derived or disputed; see the note below" ;;
  *) NOTE "confidence: not established yet" ;;
esac
[ -n "$_tpn" ] && [ "${_tpn:-0}" -gt 0 ] 2>/dev/null && \
  NOTE "checked against ${_tpn} non-CPU peer sensor(s), range ${_tpl:-?}..${_tph:-?}C"
[ -n "$_tcn" ] && NOTE "consensus: ${_tcn}"
if [ -n "$_trt" ]; then
  # Raw, never with a degree sign: the whole point is that it is not degrees.
  _trr="$(grep -m1 '^thermal_rejected_raw=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  NOTE "rejected candidate: ${_trt} (raw ${_trr}, not a temperature)"
fi

SEC "5a8. TRIALS  (settings on probation)"
# A risky tweak that is being evaluated rather than trusted. Shown separately because
# "active" and "on trial until tonight" are different states and the user chose one.
_trd="${ASB_CONFIG_STATE:-/data/adb/asb}/trial"
if [ -d "$_trd" ] && ls "$_trd"/*.trial >/dev/null 2>&1; then
  for _t in "$_trd"/*.trial; do
    _tk="$(grep -m1 '^key=' "$_t" 2>/dev/null | cut -d= -f2)"
    _tv="$(grep -m1 '^trial_value=' "$_t" 2>/dev/null | cut -d= -f2)"
    _tp="$(grep -m1 '^previous_value=' "$_t" 2>/dev/null | cut -d= -f2)"
    _te="$(grep -m1 '^expires=' "$_t" 2>/dev/null | cut -d= -f2)"
    _left=$(( ${_te:-0} - $(date +%s 2>/dev/null || echo 0) ))
    [ "$_left" -lt 0 ] 2>/dev/null && _left=0
    NOTE "${_tk} = ${_tv} (was ${_tp:-stock}) - reverts in $(( _left / 3600 ))h unless confirmed"
  done
else
  NOTE "no settings on trial"
fi
if [ -d "$_trd" ] && ls "$_trd"/*.kept >/dev/null 2>&1; then
  NOTE "confirmed after trial: $(ls "$_trd"/*.kept 2>/dev/null | sed 's|.*/||;s|\.kept$||' | tr '\n' ' ')"
fi

SEC "5a7. APPLY LEDGER  (what the device actually accepted)"
# Scheduler ceilings that drifted and were put back.
#
# Recorded separately because the module CORRECTS them: a live reading always looks right,
  # What was ASKED for, beside what the node holds.
  _uw="$(grep -m1 "^uclamp_want=" /dev/.asb/state 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [ -n "$_uw" ] && NOTE "requested by governor (top,bg): $_uw"
# so this is the only trace that anything was wrong. top-app uclamp.max at 0 means the
# scheduler was forbidden from asking for performance for the app on screen - expensive,
# and invisible without this line.
_led_r="${ASB_CONFIG_STATE:-/data/adb/asb}/apply_ledger"
if [ -s "$_led_r" ]; then
  _rc=$(grep -c '^[0-9]*|reconcile|' "$_led_r" 2>/dev/null)
  case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
  if [ "$_rc" -gt 0 ]; then
    NOTE "scheduler ceilings restored ${_rc} time(s) since boot:"
    grep '^[0-9]*|reconcile|' "$_led_r" 2>/dev/null | cut -d'|' -f3,5 | sort | uniq -c |
      while read -r _n _kv; do
        P "    $(printf '%s' "$_kv" | cut -d'|' -f1) was $(printf '%s' "$_kv" | cut -d'|' -f2) (${_n}x)"
      done
    NOTE "-> all were corrected; frequent entries mean the ROM keeps overwriting ASB"
  else
    NOTE "no scheduler ceiling drift recorded"
  fi
fi

# "Enabled" in the UI and "the ROM took it" are different claims. Every writer records a
# read-back result here, so a tweak that reads back wrong is visible instead of silently
# looking fine.
_led="${ASB_CONFIG_STATE:-/data/adb/asb}/apply_ledger"
if [ -s "$_led" ]; then
  NOTE "last 8 write results:"
  tail -8 "$_led" 2>/dev/null | while IFS='|' read -r _t _dom _k _req _prev _now _res _why _ttl; do
    P "    ${_dom}/${_k}: ${_res}${_why:+  (${_why})}"
  done
  # A count by class is what tells you whether this device is fighting the module.
  NOTE "totals: $(awk -F'|' '{c[$7]++} END{for(k in c) printf "%s=%d ", k, c[k]}' "$_led" 2>/dev/null)"
  _bad="$(awk -F'|' '$7=="readback_mismatch"||$7=="not_writable"{n++} END{print n+0}' "$_led" 2>/dev/null)"
  if [ "${_bad:-0}" -gt 0 ] 2>/dev/null; then
    # Name them. A count says the device is fighting the module; only the keys say where.
    # The verdict is each key's LAST result, so a key that failed once at boot and was
    # applied later is not reported as broken - and repeated attempts count once.
    _badk="$(awk -F'|' '{ k = $2 "/" $3; last[k] = $7; why[k] = $8; req[k] = $4; now[k] = $6; n[k]++ }
      END { for (k in last) if (last[k] == "readback_mismatch" || last[k] == "not_writable")
              printf "%s|%s|%s|%s|%s|%d\n", k, last[k], why[k], req[k], now[k], n[k] }' "$_led" 2>/dev/null | sort)"
    if [ -n "$_badk" ]; then
      NOTE "-> $(printf '%s\n' "$_badk" | grep -c .) key(s) the device did not accept - not in effect (key: result - wanted -> device has):"
      printf '%s\n' "$_badk" | head -15 | while IFS='|' read -r _bk _br _bw _bq _bn _bc; do
        P "    ${_bk}: ${_br}${_bw:+ (${_bw})} - ${_bq:-?} -> ${_bn:-?}  [${_bc}x]"
      done
    else
      NOTE "-> ${_bad} earlier rejection(s), all applied on a later attempt - nothing is outstanding"
    fi
  fi
else
  NOTE "no writes recorded yet"
fi

SEC "5a5. WAKELOCKS  (what is keeping the phone awake)"
# The suspend figure above says the phone is not sleeping; this says who is doing it.
# Without the name, "awake 73%" is a fact the user can do nothing with.
if [ -s /data/adb/asb/wakelock_top ]; then
  NOTE "top sources holding the CPU (name | ms held | times taken):"
  while IFS='|' read -r _wn _wa _wc; do
    [ -n "$_wn" ] || continue
    # Arithmetic only on digits.
    #
    # The batterystats fallback writes human durations - "11m 2s 985ms" - while the
    # debugfs path writes plain microseconds. $(( )) on the first form aborts the whole
    # shell, which is why the report stopped dead at this section and nothing after it was
    # produced. One unparsed field silently truncated the entire diagnostic.
    case "${_wa:-}" in
      ''|*[!0-9]*) P "    $_wn  ·  ${_wa:-?}  ·  ${_wc:-0}x" ;;
      *)           P "    $_wn  ·  $(( _wa / 1000 ))s  ·  ${_wc:-0}x" ;;
    esac
  done < /data/adb/asb/wakelock_top
  NOTE "kernel sources (qup_uart, alarmtimer, wlan) are the hardware asking, not an app"
  NOTE "a package name here is an app you can restrict, uninstall or exempt yourself"
else
  NOTE "no snapshot yet - taken every 15 min, needs /sys/kernel/debug to be readable"
fi
# Apps, resolved by uid. The kernel list above names sources; this names who asked.
if [ -s /data/adb/asb/wakelock_apps ]; then
  NOTE "apps holding the CPU since the last unplug (package | held | verdict):"
  while IFS='|' read -r _ap _as _ah _av; do
    [ -n "$_ap" ] || continue
    case "$_as" in ''|*[!0-9]*) _as=0 ;; esac
    _al="$(( _as / 60 )) min"; [ "$_ah" = 1 ] && _al="$_al, holding now"
    case "$_av" in
      restricted) _avt="restricted by ASB (undone on uninstall)" ;;
      protected)  _avt="protected class (messenger/alarm/fitness) - never auto-restricted" ;;
      in_use)     _avt="visible or audible to you - left alone" ;;
      limited)    _avt="wakelocks ignored by your wakelock_fitness=limit (undone on protect/uninstall)" ;;
      limit_ignored) _avt="wakelock_fitness=limit is set, but this Android does not enforce the WAKE_LOCK app-op - the app still held the CPU (not DISABLED) after it was set" ;;
      *)          _avt="report only" ;;
    esac
    P "    $_ap  ·  $_al  ·  $_avt"
  done < /data/adb/asb/wakelock_apps
fi
if [ -s /data/adb/asb/wakelock_multicast ]; then
  _mct="$(sed -n 's/^total|//p' /data/adb/asb/wakelock_multicast | head -1)"
  case "$_mct" in ''|*[!0-9]*) _mct=0 ;; esac
  NOTE "Wi-Fi multicast held $(( _mct / 60 )) min since the last unplug (radio cannot use its packet filter while held)"
  grep -v '^total|' /data/adb/asb/wakelock_multicast | while IFS='|' read -r _mp _mv; do
    [ -n "$_mp" ] && P "    holding now: $_mp  ·  $_mv"
  done
fi
_vpn_if=""
for _vi in /sys/class/net/tun* /sys/class/net/wg* /sys/class/net/ppp*; do
  [ -e "$_vi" ] || continue
  [ "$(cat "$_vi/operstate" 2>/dev/null)" = "down" ] && continue
  _vpn_if="${_vi##*/}"; break
done
if [ -n "$_vpn_if" ] && [ -s /data/adb/asb/wakelock_top ] && \
   head -n 3 /data/adb/asb/wakelock_top | grep -qE '^(rmnet|IPA_CLIENT_APPS_WAN|qcom_rx_wakelock)'; then
  NOTE "VPN is up ($_vpn_if) and the mobile data path (rmnet/IPA) leads the wake sources: the tunnel's keepalives wake the modem and CPU through the night. Not something ASB can change - the VPN app's keepalive / always-on settings, split tunnelling or Wi-Fi at night can."
fi
NOTE "wakelock_action = $(cfg wakelock_action)  (0 = report only)"
NOTE "wakelock_fitness = $(cfg wakelock_fitness)  (protect = fitness/step apps never touched)"
if [ -s /data/adb/asb/wakelock_fitness_limited ]; then
  while IFS='|' read -r _fp _fo; do
    [ -n "$_fp" ] || continue
    # Proof, not the record: the app-op as Android reads it now, and whether PowerManager
    # actually marks this app's held locks disabled (it prints DISABLED on such a line).
    _fnow="$(appops get "$_fp" WAKE_LOCK 2>/dev/null | sed -n 's/.*WAKE_LOCK: \([a-z_]*\).*/\1/p' | head -1)"
    _fuid="$(pm list packages -U "$_fp" 2>/dev/null | sed -n "s/^package:$_fp uid:\([0-9]*\).*/\1/p" | head -1)"
    _fheld=""; _fdis=""
    if [ -n "$_fuid" ]; then
      _fheld="$(dumpsys power 2>/dev/null | grep -c "PARTIAL_WAKE_LOCK.*uid=$_fuid")"
      _fdis="$(dumpsys power 2>/dev/null | grep "PARTIAL_WAKE_LOCK.*uid=$_fuid" | grep -c DISABLED)"
    fi
    P "    WAKE_LOCK ignored: $_fp  (was: ${_fo:-default}; now: ${_fnow:-default}; held now: ${_fheld:-0}, of them disabled: ${_fdis:-0})"
    # No WAKE_LOCK entry means the op is back at default: the system reset it (app update,
    # permission reset, boot sweep). The wakelock watcher re-applies it on its next pass.
    [ "${_fnow:-default}" != ignore ] && NOTE "  limit lapsed - the system reset this app-op; the wakelock watcher re-applies it on its next pass"
  done < /data/adb/asb/wakelock_fitness_limited
fi
if [ -s /data/adb/asb/wakelock_restricted ]; then
  NOTE "$(wc -l < /data/adb/asb/wakelock_restricted) app(s) moved to restricted by ASB - undone on uninstall"
fi

SEC "5b. HAPTICS"
_h_lvl="$(cfg haptic_strength)"
case "$_h_lvl" in
  ''|-1|auto|stock) NOTE "haptic_strength = stock (not managed by ASB)" ;;
  *)
    NOTE "haptic_strength = ${_h_lvl}/10, touch = $(cfg haptic_touch_strength)"
    # The coarse Android keys are a gate, not a level: they were already at 3 on the
    # devices this was built for, which is why setting them alone did nothing. What is
    # felt is the OEM stepless value, so that is what gets verified.
    _h_want=$(( ${_h_lvl:-0} * 2400 / 10 ))
    V "  notification stepless amplitude" "$_h_want" \
      "$(settings get system notification_stepless_vibration_intensity 2>/dev/null)" eq
    V "  ring stepless amplitude" "$_h_want" \
      "$(settings get system ring_stepless_vibration_intensity 2>/dev/null)" eq
    V "  coarse gate open (notification_vibration_intensity)" "3" \
      "$(settings get system notification_vibration_intensity 2>/dev/null)" eq
    NOTE "a live value BELOW the wanted one means the vibrator service rejected it and the script stepped down"
    ;;
esac

SEC "6. CAMERA"
_cam_plat="$(gp ro.board.platform)"
[ -z "$_cam_plat" ] && _cam_plat="$(gp ro.hardware.chipname)"
_is_pineapple=0
case "$_cam_plat" in pineapple|sm8650*) _is_pineapple=1 ;; esac

# --- 6.0 Camera bind evidence: where the retouch list / tone table should come from ---
# The live view depends on the namespace you read it from, so name all three: the bind
# manifest, the payload it points at, and what init's namespace (the one the camera HAL
# lives in) shows at the live path.
_cbm=/data/adb/asb/odm_bind_manifest.txt
if [ -f "$_cbm" ]; then
  _cbn=0
  while IFS='|' read -r _cbt _cbp; do
    case "$_cbt" in */camera/*) : ;; *) continue ;; esac
    _cbn=$((_cbn + 1))
    _cbpa="$(grep -c '"packageName"' "$_cbp" 2>/dev/null)"
    _cbmnt=no; grep -qs " $_cbt " /proc/1/mountinfo && _cbmnt=yes
    _cbinit=""
    command -v nsenter >/dev/null 2>&1 && _cbinit="$(nsenter -t 1 -m -- grep -c '"packageName"' "$_cbt" 2>/dev/null)"
    case "$_cbt" in
      *video_beauty*) NOTE "camera bind: $_cbt  payload apps=${_cbpa:-?}  bound in init ns=$_cbmnt  init-ns apps=${_cbinit:-?}" ;;
      *) NOTE "camera bind: $_cbt  payload=$([ -f "$_cbp" ] && echo present || echo MISSING)  bound in init ns=$_cbmnt" ;;
    esac
  done < "$_cbm"
  [ "$_cbn" = 0 ] && NOTE "camera bind: none queued in odm_bind_manifest.txt (the camera reads stock files)"
else
  NOTE "camera bind: no odm_bind_manifest.txt"
fi
grep 'odm_bind' /data/adb/asb/vendor_mounts.log 2>/dev/null | tail -n 6 | while IFS= read -r _cbl; do P "    $_cbl"; done
# Read-back per manifest line (live = init's namespace reads the payload).
if [ -f /data/adb/modules/AutoSystemBoost/runtime/asb_odm_rebind.sh ]; then
  sh /data/adb/modules/AutoSystemBoost/runtime/asb_odm_rebind.sh status 2>/dev/null \
    | while IFS= read -r _cbl; do NOTE "bind read-back: $_cbl"; done
fi
# Every layer on the camera paths, as init sees them, and the module's own copies - if a
# root-manager layer (magic mount, NoMount, overlayfs) sits in front of the bind, this is
# the line that names it.
grep -s '/camera' /proc/1/mountinfo | awk '{print "    mount: " $5 "  fs=" $(NF-2) "  src=" $(NF-1)}' | head -n 8 \
  | while IFS= read -r _cbl; do P "$_cbl"; done
for _cbf in /data/adb/modules/AutoSystemBoost/odm/etc/camera/config/video_beauty_default_config \
            /data/adb/modules/AutoSystemBoost/odm/etc/camera/conf_tuning_params.json; do
  [ -f "$_cbf" ] || { NOTE "module copy absent: $_cbf"; continue; }
  case "$_cbf" in
    *video_beauty*) NOTE "module copy: video_beauty apps=$(grep -c '"packageName"' "$_cbf" 2>/dev/null)" ;;
    *) NOTE "module copy: conf_tuning BlendWeight=$(grep -m1 -o '"BlendWeight"[^]]*]' "$_cbf" 2>/dev/null | sed 's/.*\[//')" ;;
  esac
done
_cbmm="$(ls /data/adb/metamodule/module.prop 2>/dev/null && grep -m1 '^id=' /data/adb/metamodule/module.prop 2>/dev/null)"
NOTE "metamodule: ${_cbmm:-none}"

# --- 6a. Multicamera HAL props (the crash is in ChiMcxRoiTranslator) ---
P "  multicamera / HAL props:"
for _p in \
    ro.vendor.oplus.camera.isHasselbladCamera \
    ro.vendor.oplus.camera.isSupportExplorer \
    persist.vendor.camera.video.4k60.eis.enable \
    persist.vendor.camera.mfnr.enable \
    persist.vendor.camera.multiframe.nr.enable \
    persist.vendor.camera.dual_camera_sat \
    persist.vendor.camera.sat.fallback.dist \
    vendor.camera.aux.packagelist \
    ro.vendor.oplus.camera.backCamSize; do
  P "    $_p = $(gp $_p)"
done
# camera provider service health (the process that SIGABRTs on OP12)
P "  camera provider service: init.svc=$(gp init.svc.vendor.camera-provider) cameraserver=$(gp init.svc.cameraserver)"

# --- 6b. OP12 camera env: must MATCH the proven-working module, and /odm must
#     stay in sync with /vendor/odm (a desync between the two is the prime
#     multicamera-HAL crash suspect on APatch). ---
if [ "$_is_pineapple" = "1" ]; then
  NOTE "platform=$_cam_plat -> OP12: camera overlay should match the known-good module; /odm and /vendor/odm must agree"
  # CRITICAL: compare media_profiles on the real /odm partition vs /vendor/odm.
  _mp_odm="/odm/etc/camera/media_profiles.xml"
  _mp_vodm="/vendor/odm/etc/camera/media_profiles.xml"
  _sz_odm="$( [ -f "$_mp_odm" ] && wc -c < "$_mp_odm" 2>/dev/null | tr -d ' ' )"
  _sz_vodm="$( [ -f "$_mp_vodm" ] && wc -c < "$_mp_vodm" 2>/dev/null | tr -d ' ' )"
  P "  media_profiles sizes: /odm=${_sz_odm:-absent}  /vendor/odm=${_sz_vodm:-absent}"
  if [ -n "$_sz_odm" ] && [ -n "$_sz_vodm" ]; then
    if [ "$_sz_odm" = "$_sz_vodm" ]; then
      P "  [PASS] /odm and /vendor/odm media_profiles agree (no desync)"; PASS=$((PASS+1))
    else
      V "  /odm vs /vendor/odm media_profiles DESYNC (HAL crash suspect)" "in-sync" "odm=${_sz_odm}/vodm=${_sz_vodm}" eq
    fi
  fi
  # Owner/timestamp tell us whether the module wrote /vendor/odm directly (group
  # shell + recent date) vs a clean magic-mount. Informational, helps debugging.
  if [ -f "$_mp_vodm" ]; then
    _own="$(ls -l "$_mp_vodm" 2>/dev/null | awk '{print $3":"$4}')"
    P "  /vendor/odm media_profiles owner = ${_own:-?} (root:root = stock/mount, *:shell = module wrote it)"
  fi
  # conf_tuning / video_beauty presence (these SHOULD be present now — we apply
  # the same overlay as the working module, no longer a camera-off).
  for VB in /odm/etc/camera/config/video_beauty_default_config \
            /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    # A comment starts a line. "//" anywhere else is data.
    #
    # grep -c '//' counted every double slash in the file, including the ones inside string
    # values - a URL, a path, an escaped separator. That made this check fail on all six
    # devices in a cross-device sweep, including ones whose file ASB never touched, and a
    # red line that is always red tells you nothing.
    camera_json_comment_verdict "$VB"
  done
  # multicamera/HAL props that must be live for configure_streams to succeed.
  P "  multicamera props live:"
  for _p in persist.vendor.camera.mfnr.enable ro.vendor.oplus.camera.isSupportExplorer \
            persist.camera.dual_camera_sat persist.vendor.camera.sat.fallback.dist; do
    P "    $_p = $(gp $_p)"
  done
else
  # --- 6c. OP13/OP15: camera overlays SHOULD be applied ---
  for VB in /odm/etc/camera/config/video_beauty_default_config /vendor/odm/etc/camera/config/video_beauty_default_config; do
    [ -f "$VB" ] || continue
    P "  file: $VB"
    _ct_present="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
    if [ -n "$_ct_present" ]; then
      # When the overlay is not visible to us, these are not module failures.
      #
      # asbdiag runs outside the camera's mount namespace, so on a private-namespace mount
      # it reads the same stock file the camera does. Reporting FAIL there says the tweak
      # broke, when what actually happened is the overlay never reached either of us - and
      # five of ten failures in a field report came from this one cause, dragging pass_ratio
      # to 69% on a phone whose module was working as designed.
      #
      # The grade record is the evidence that ASB did its part: it is written when the
      # grader runs. Present grade + stock live file = a mount problem, and the report
      # should say so instead of blaming the tweak.
      _cam_graded="$(cat /data/adb/asb/grade_marks/*.mark 2>/dev/null | head -1)"
      if [ -n "$_cam_graded" ] && ! grep -q "org.telegram.messenger" "$VB" 2>/dev/null; then
        NOTE "camera overlay not visible from here - graded file exists but $VB is stock"
        NOTE "  (private-namespace mount: the camera reads the same stock file; not a tweak failure)"
      else
        V "  retouch app count >= 7" "7" "$(grep -c packageName "$VB" 2>/dev/null)" ge
        V "  Telegram present" "1" "$(grep -c org.telegram.messenger "$VB" 2>/dev/null)" ge
      fi
    else
      NA=$((NA+2))
      P "  [N/A ] retouch/Telegram content is OP15 camera-tone specific (no conf_tuning on this model)"
    fi
    camera_json_comment_verdict "$VB"
  done
  CT="$(firstf '/odm/etc/camera/conf_tuning_params.json' '/vendor/odm/etc/camera/conf_tuning_params.json')"
  # Judge the tone table as the camera HAL reads it: through init's namespace. asbdiag can
  # run in a namespace of its own where a bind made later in init's never shows - the field
  # diag read stock here while init's namespace held the bound, graded copy.
  if [ -n "$CT" ] && command -v nsenter >/dev/null 2>&1; then
    _ct_init="${TMPDIR:-/data/local/tmp}/asbdiag_ct_init.$$"
    if nsenter -t 1 -m -- cat "$CT" > "$_ct_init" 2>/dev/null && [ -s "$_ct_init" ]; then
      cmp -s "$_ct_init" "$CT" 2>/dev/null \
        || NOTE "tone table differs between this shell and init's namespace - checks below use init's (what the camera HAL reads)"
      CT_SHOWN="$CT"; CT="$_ct_init"
    else
      rm -f "$_ct_init" 2>/dev/null
    fi
  fi
  _ctp=/data/adb/asb/odm_patched/odm/etc/camera/conf_tuning_params.json
  [ -f "$_ctp" ] && NOTE "bind payload BlendWeight: $(grep -m1 -o '"BlendWeight"[^]]*]' "$_ctp" 2>/dev/null | sed 's/.*\[//;s/\]//')"
  if [ -n "$CT" ]; then
    P "  file: ${CT_SHOWN:-$CT}"
    # sunsetBrightScale is deliberately NOT written any more.
    #
    # The old sed grader pinned it to 0.9 so boosted warm skies would not clip.
    # The current grader is purely relative - it multiplies what the firmware ships and writes
    # no absolute tone values at all - so this check asserted behaviour that was removed on
    # purpose, and reported FAIL on a device where nothing was wrong.
    NOTE "sunsetBrightScale = $(grep -o '"sunsetBrightScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$') (informational: the relative grader does not set this)"
    # Camera grade is driven by CAMERA_LEVEL (0..4 slider).
    # Mirror the runtime value table (runtime/asb_tweaks.sh) so the expected
    # sunsetSatScale/blueSatParam match the user's actual level instead of false-FAILing
    # against the old fixed aggressive numbers.
    _clvl="$(cfg CAMERA_LEVEL)"
    _caggr="$(cfg CAMERA_AGGRESSIVE)"
    if [ -z "$_clvl" ] || [ "$_clvl" = "0" ]; then
      [ "${_caggr:-0}" = "1" ] && _clvl=3 || _clvl=0
    fi
    NOTE "CAMERA_LEVEL = ${_clvl} (legacy CAMERA_AGGRESSIVE=${_caggr:-0} maps to level 3)"
    if [ "${_clvl:-0}" -ge 1 ] 2>/dev/null; then
      _cam_soc="$(getprop ro.board.platform 2>/dev/null)"
      [ -z "$_cam_soc" ] && _cam_soc="$(getprop ro.hardware.chipname 2>/dev/null)"
      # Grading is a RATIO now, so there is no single expected number to compare against - the
      # result depends on what the device shipped.
      # Checking "does it differ from the stock file" is the honest test, and it is also the
      # one that would have caught the two ways this silently did nothing: rules that matched
      # no value, and a hook that graded a file something else overwrote.
      _cam_stock_bw="0.35, 0.5, 0.7"
      _cam_live_bw="$(grep -m1 -o '"BlendWeight"[^]]*]' "$CT" 2>/dev/null | sed 's/.*\[//;s/\]//')"
      V "  grade(lvl$_clvl) live file differs from stock" "not [$_cam_stock_bw]" \
        "$(if [ "$_cam_live_bw" = "$_cam_stock_bw" ]; then printf '[%s]' "$_cam_live_bw"; \
           else printf 'not [%s]' "$_cam_stock_bw"; fi)" eq
      NOTE "grain=$(cfg CAMERA_GRAIN) contrast=$(cfg CAMERA_CONTRAST) portrait=$(cfg CAMERA_PORTRAIT) lowlight=$(cfg CAMERA_LOWLIGHT)  (3/3/0/0 = stock)"
      # Portrait weights ship at zero and cannot be scaled, so they are set absolutely -
      # worth checking separately because a zero here means the setting did nothing.
      if [ "$(cfg CAMERA_PORTRAIT)" != "0" ] && [ -n "$(cfg CAMERA_PORTRAIT)" ]; then
        # Read FaceBlendWeight from a PORTRAIT block, and test for zero numerically.
        #
        # Face, not Skin: Skin already ships non-zero in two of the three portrait blocks
        # (0.15), so a check built on it passes on a completely untouched device and can never
        # tell you the setting did nothing.
        #
        # It also used to grep the whole file and take the first weight it saw - which lives in
        # a non-portrait block, where zero is correct and expected.
        # The all-zero filter matched the literal text "0.0, 0.0, 0.0" only, so once the grader
        # rewrote those zeros as "0, 0, 0" the filter stopped catching them, the zero row
        # survived, and the check reported PASS while printing "0, 0, 0" as its own evidence.
        _cam_skin="$(sed -n '/EnhanceNet[A-Za-z]*PortraitParams/,/}/p' "$CT" 2>/dev/null \
                     | grep -o '"FaceBlendWeight"[^]]*]' \
                     | sed 's/.*\[//;s/\]//' \
                     | awk -F, '{ for (i=1;i<=NF;i++) { gsub(/ /,"",$i); if ($i+0 != 0) { print; break } } }' \
                     | head -1)"
        V "  portrait AI weights are non-zero" "present" "${_cam_skin:-0, 0, 0}" present
      fi
      _row="$_clvl"
      case "$_cam_soc" in sun|sm8750*) _row=$((_clvl - 1)); [ "$_row" -lt 1 ] && _row=1 ;; esac
      _exp_sss=""; _exp_bsat=""
      if [ -n "$_exp_sss" ]; then
        V "  grade(lvl$_clvl) sunsetSatScale=$_exp_sss" "$_exp_sss" "$(grep -o '"sunsetSatScale": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        _inj="$(cfg CAMERA_AGGRESSIVE_INJECT)"; NOTE "inject mode = ${_inj:-safe}"
        if [ "${_inj:-safe}" = "aggressive" ]; then
          V "  grade(lvl$_clvl) blueSatParam=$_exp_bsat" "$_exp_bsat" "$(grep -o '"blueSatParam": *[0-9.]*' "$CT" 2>/dev/null | head -1 | grep -o '[0-9.]*$')" eq
        fi
      fi
    else
      OFF "camera grade checks - CAMERA_LEVEL=0, the tone table is left stock" "CAMERA_LEVEL"
    fi
  else
    NOTE "conf_tuning_params.json absent"
  fi
  # Read the bitrate from the file the recording pipeline actually uses AND that the module can
  # overlay.
  # On OP15 the camera's own /odm/etc/camera/media_profiles sits on a read-only opex partition
  # the module can't touch, so checking it reports stock and falsely fails — the media
  # framework reads the bitrate from /vendor/etc/media_profiles*.xml, which ASB DOES overlay
  # and lift.
  CMP="$(firstf '/vendor/etc/media_profiles.xml' '/vendor/etc/media_profiles_V1_0.xml' '/odm/etc/camera/media_profiles.xml' '/vendor/odm/etc/camera/media_profiles.xml')"
  if [ -n "$CMP" ]; then
    _br=$(awk '/quality="1080p"/{f=1} f&&/bitRate=/{match($0,/bitRate="[0-9]+"/);print substr($0,RSTART+9,RLENGTH-10);exit}' "$CMP" 2>/dev/null)
    case "$_cam_plat" in canoe|sm8850*) _bexp=40000000 ;; *) _bexp=37300000 ;; esac
    # Same overlay dependency as the mixer tweaks above: the media profile is patched
    # into the /vendor overlay, so with VENDOR_OVERLAY=0 the stock value is expected.
    _vov2="$(grep -E '^[[:space:]]*VENDOR_OVERLAY=' "$MODDIR/features.conf" 2>/dev/null \
             | head -1 | sed 's/.*=//' | tr -d ' \r' | cut -d'#' -f1)"
    if [ "${_vov2:-0}" = "1" ]; then
      V "  1080p video bitrate raised" "$_bexp" "$_br" eq
    else
      NOTE "  1080p bitrate needs the /vendor overlay (VENDOR_OVERLAY=0) - not checked"
    fi
  fi
fi
[ -n "${_ct_init:-}" ] && rm -f "$_ct_init" 2>/dev/null

# =====================================================================
SEC "7. PERFORMANCE / CPU / GPU"
P "  CPU policies (scaling max vs hardware max — shows how hard each cluster is capped):"
# Work out the topology so we can label little / mid / prime, matching the
# governor's own classification (first policy = little, last = prime, anything
# between on a 3+ cluster part = mid workhorse).
_pol_dirs="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n)"
_npol="$(echo "$_pol_dirs" | grep -c .)"
_first_pol="$(echo "$_pol_dirs" | head -1)"
_last_pol="$(echo "$_pol_dirs" | tail -1)"
for _pol in $_pol_dirs; do
  [ -d "$_pol" ] || continue
  _cl=$(basename "$_pol")
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _hmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  _pctmax="?"
  if [ -n "$_smax" ] && [ -n "$_hmax" ] && [ "$_hmax" -gt 0 ] 2>/dev/null; then
    _pctmax=$(( _smax * 100 / _hmax ))
  fi
  _tier="big/prime"
  if [ "$_pol" = "$_first_pol" ]; then
    _tier="little"
  elif [ "$_pol" = "$_last_pol" ]; then
    _tier="prime"
  elif [ "$_npol" -ge 3 ]; then
    _tier="mid"
  fi
  P "    $_cl ($_tier): max=${_smax}/${_hmax} kHz (${_pctmax}% of hw) gov=$_gov"
done
_gpu_gov="$(cat /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>/dev/null)"
_gpu_pwr="$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null)"
_gpu_floor="$(cat /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 2>/dev/null)"
[ "$_gpu_floor" = "0" ] && _gpu_floor=""
if [ -n "$_gpu_gov" ]; then
  P "  GPU: $_gpu_gov  max_pwrlevel=$_gpu_pwr (devfreq-capped)"
else
  # devfreq freq nodes empty (e.g. OP15 Adreno 840) -> ASB caps via pwrlevel.
  P "  GPU: pwrlevel-controlled  max_pwrlevel=$_gpu_pwr${_gpu_floor:+ (thermal limit=level $_gpu_floor)}"
fi
NOTE "tier shows the governor's cluster role; %-of-hw shows the active cap. In"
NOTE "performance every cluster should read ~100%; in battery the prime cluster"
NOTE "is capped low while little/mid keep enough headroom to stay smooth."
# Profile-aware sanity.
_prof_now="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
_prime_smax=$(cat "$_last_pol/scaling_max_freq" 2>/dev/null)
_prime_hmax=$(cat "$_last_pol/cpuinfo_max_freq" 2>/dev/null)
_prime_pct="?"
if [ -n "$_prime_smax" ] && [ -n "$_prime_hmax" ] && [ "$_prime_hmax" -gt 0 ] 2>/dev/null; then
  _prime_pct=$(( _prime_smax * 100 / _prime_hmax ))
fi
case "$_prof_now" in
  performance)
    NOTE "performance: prime live scaling_max=${_prime_pct}% of hw (the OEM governor varies this under load; ASB applies NO cap in performance)"
    ;;
  battery)
    # battery SHOULD cap prime. If the live value is already <=70% that confirms
    # ASB's cap; if higher, it may just be the governor sitting high momentarily,
    # so this is a soft check rather than a hard fail.
    if [ "$_prime_pct" != "?" ] && [ "$_prime_pct" -le 70 ] 2>/dev/null; then
      P "  [PASS] battery: prime cluster capped (${_prime_pct}% of hw)"; PASS=$((PASS+1))
    else
      NOTE "battery: prime live scaling_max=${_prime_pct}% of hw (expected <=70%; if this persists under idle, ASB's cap may not be sticking — check the write-test above)"
    fi ;;
  *)
    NOTE "profile=$_prof_now -> prime cluster at ${_prime_pct}% of hw (balanced/smart vary by load)" ;;
esac
# cool gaming
_cool="$(cfg cool_gaming)"; NOTE "cool_gaming toggle = ${_cool:-0}"
QAPE="$(firstf '/vendor/etc/perf/qapegameconfig.txt' '/odm/etc/perf/qapegameconfig.txt')"
[ -n "$QAPE" ] && NOTE "qapegameconfig present: $QAPE" || NOTE "qapegameconfig absent (normal on OP12)"
# thermal
P "  thermal: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) (zone0 raw)"

# =====================================================================
SEC "7b. MEMORY / LMKD / ZRAM"
# RAM overview
if [ -r /proc/meminfo ]; then
  _memtot=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')
  _memfree=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2}')
  P "  RAM: total=$((${_memtot:-0}/1024))MB available=$((${_memfree:-0}/1024))MB"
  # Detailed breakdown so we can see WHAT occupies RAM (the headline "available" number swings
  # with whatever apps are open at snapshot time, which makes cross-profile comparisons
  # misleading).
  _mi() { grep -m1 "^$1:" /proc/meminfo 2>/dev/null | awk '{print $2}'; }
  _mb() { echo "$(( ${1:-0} / 1024 ))MB"; }
  _free=$(_mi MemFree); _cached=$(_mi Cached); _buffers=$(_mi Buffers)
  _srecl=$(_mi SReclaimable); _sunrecl=$(_mi SUnreclaim); _shmem=$(_mi Shmem)
  _aanon=$(_mi 'Active(anon)'); _ianon=$(_mi 'Inactive(anon)')
  _afile=$(_mi 'Active(file)'); _ifile=$(_mi 'Inactive(file)')
  _swcached=$(_mi SwapCached); _mapped=$(_mi Mapped); _kreclaim=$(_mi KReclaimable)
  P "    MemFree=$(_mb $_free)  Cached=$(_mb $_cached)  Buffers=$(_mb $_buffers)  SwapCached=$(_mb $_swcached)"
  P "    Active(anon)=$(_mb $_aanon)  Inactive(anon)=$(_mb $_ianon)   <- real app (anon) memory"
  P "    Active(file)=$(_mb $_afile)  Inactive(file)=$(_mb $_ifile)   <- file cache (reclaimable)"
  P "    SReclaimable=$(_mb $_srecl)  SUnreclaim=$(_mb $_sunrecl)  KReclaimable=$(_mb $_kreclaim)  Shmem=$(_mb $_shmem)  Mapped=$(_mb $_mapped)"
  # Derived: reclaimable cache that the kernel can hand back under pressure, vs
  # genuinely committed memory. This is the apples-to-apples figure to compare
  # across profiles, not the raw "available".
  _reclaimable=$(( ${_cached:-0} + ${_buffers:-0} + ${_srecl:-0} ))
  _anon=$(( ${_aanon:-0} + ${_ianon:-0} ))
  P "    => reclaimable cache ~$(_mb $_reclaimable), committed app(anon) ~$(_mb $_anon)"
  NOTE "compare app(anon) across profiles, NOT 'available' — 'available' swings with whatever is open at snapshot time"
fi
# swap / zram
if [ -r /proc/swaps ]; then
  P "  swap devices:"
  tail -n +2 /proc/swaps 2>/dev/null | while read _sn _st _ssz _su _sp; do
    P "    $_sn ($_st) size=$((${_ssz:-0}/1024))MB used=$((${_su:-0}/1024))MB"
  done
fi
for _zr in /sys/block/zram0/comp_algorithm /sys/block/zram0/disksize /sys/block/zram0/mem_limit /sys/block/zram0/mm_stat /sys/block/zram0/io_stat; do
  [ -r "$_zr" ] && P "    zram $(basename $_zr): $(cat $_zr 2>/dev/null | tr '\n' ' ')"
done
if [ -r /proc/pressure/memory ]; then
  P "  memory PSI (read-only):"
  sed 's/^/    /' /proc/pressure/memory 2>/dev/null
  # avg10/avg60 straight after boot measure app restore and dexopt, not steady use.
  _psi_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  case "$_psi_up" in ''|*[!0-9]*) _psi_up=99999 ;; esac
  if [ "$_psi_up" -lt 600 ]; then
    NOTE "  phone booted ${_psi_up}s ago: avg10/avg60 reflect boot-time app restore - compare avg300 or re-run after ~10 min"
  fi
  # Screen-on memory stalls the Smart tuner reacted to (fix108/fix111): swappiness is
  # raised to profile+20 while PSI full avg10 >= 2.
  _msn="$(grep -m1 '^mem_stall_now=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  _mse="$(grep -m1 '^mem_stall_entries=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
  [ -n "$_mse" ] && NOTE "  screen-on memory stalls since governor start: ${_mse} (now: ${_msn:-0}) - swappiness raised while one lasts"
else
  NOTE "memory PSI unavailable on this kernel (no policy is changed)"
fi
# LMKD tunables ASB may touch. The two headers used to print back to back, so the lmk
# props appeared under "OEM toggles" and the LMKD header stood empty.
P "  LMKD / vmpressure props:"
for _p in ro.lmk.use_psi ro.lmk.thrashing_limit ro.lmk.swap_util_max \
          persist.device_config.lmkd_native.thrashing_limit \
          persist.sys.lmkd.camera_adaptive_lmk.enable; do
  P "    $_p = $(gp $_p)"
done
# OEM system toggles ASB can optionally manage (only when UX_MANAGE_OEM_TOGGLES=1).
P "  OEM toggles (managed only if UX_MANAGE_OEM_TOGGLES=1):"
for _ot in ram_expand_size adaptive_battery_management_enabled sem_low_heat_mode; do
  P "    settings global $_ot = $(settings get global $_ot 2>/dev/null)"
done
# kernel VM tunables
P "  kernel VM:"
for _vm in swappiness vfs_cache_pressure watermark_scale_factor; do
  [ -r "/proc/sys/vm/$_vm" ] && P "    vm.$_vm = $(cat /proc/sys/vm/$_vm 2>/dev/null)"
done
# memory cgroup presence (ASB BG_TRIM depends on memcg)
_memcg="$(firstf '/dev/memcg' '/sys/fs/cgroup/memory')"
# Say which half is missing, not that the whole tweak is limited.
#
# BG_TRIM has two mechanisms: memory cgroups, and standby buckets via am set-standby-bucket.
# Only the first needs memcg. The old wording - "BG_TRIM limited" - read as "this does not
# work here", and that is how a CPH2769 owner took it, on a device logging 2744 timer
# wakeups a session: exactly what buckets are for, and buckets were running the whole time.
if [ -n "$_memcg" ]; then
  NOTE "memcg present: $_memcg (BG_TRIM: memory limits + standby buckets)"
else
  NOTE "no memcg path (BG_TRIM: standby buckets only - memory limits unavailable here)"
fi
_bgtrim="$(cfg BG_TRIM_LEVEL)"; NOTE "BG_TRIM_LEVEL = ${_bgtrim:-safe}"
# Athena state. ASB never disables com.oplus.athena, but older builds did and did not
# record it, so uninstall could not restore it either. Surfacing it here means a tester
# who sees it disabled can tell at a glance whether the module is responsible.
if pm list packages -d 2>/dev/null | grep -q '^package:com.oplus.athena$'; then
  if grep -q "^pm|com.oplus.athena|" /data/adb/asb/baseline.txt 2>/dev/null; then
    NOTE "com.oplus.athena DISABLED by ASB (recorded in baseline; uninstall will restore it)"
  else
    NOTE "com.oplus.athena DISABLED, but NOT by this build - no baseline record. Likely a"
    NOTE "  leftover from an older ASB. Restore with: pm enable com.oplus.athena"
  fi
else
  NOTE "com.oplus.athena enabled (ASB does not disable it)"
fi

# =====================================================================
SEC "8. DISPLAY / UX"
for _p in vendor.display.enable_dpps_dynamic_fps debug.hwui.use_partial_updates persist.sys.hwui.enable_texture_optimize; do
  P "    $_p = $(gp $_p)"
done
P "  animation scales (settings):"
for _s in window_animation_scale transition_animation_scale animator_duration_scale; do
  P "    $_s = $(settings get global $_s 2>/dev/null)"
done

# =====================================================================
NOTE "log_level = $(cfg log_level)  ·  camera_hold = $(cfg camera_hold_enable)"

SEC "7c. UI SPEED / ANIMATION"
# anim_speed overrides the profile's own scale. Both write the same three settings, so
# the live value is the only way to tell which one won.
NOTE "anim_speed = $(cfg anim_speed)  ·  UX_MANAGE_TIMEOUTS = $(cfg UX_MANAGE_TIMEOUTS)"
for _as in window_animation_scale transition_animation_scale animator_duration_scale; do
  P "    live $_as = $(settings get global $_as 2>/dev/null)"
done
NOTE "force animation restart = $(cfg UX_ANIM_FORCE_RESTART) (SystemUI is never restarted on a profile switch since V62)"

SEC "8a. SLEEP / DOZE  (the subsystem nobody can observe directly)"
_dz="$(cfg doze_level)"
NOTE "doze_level = ${_dz:-stock}"
_dz_live="$(settings get global device_idle_constants 2>/dev/null)"
case "$_dz_live" in null) _dz_live="" ;; esac
case "${_dz:-stock}" in
  stock) OFF "device_idle_constants - doze_level=stock, Android's own timings" "doze_level" ;;
  night)
    # "night" sets the constants inside the learned sleep window only and is stock during
    # the day, so an empty value in the afternoon is the design, not a failed write.
    if [ -n "$_dz_live" ]; then
      V "  device_idle_constants in force (night window)" "present" "$_dz_live" present
    else
      OFF "device_idle_constants - doze_level=night is stock outside the sleep window" "doze_level(night,day)"
    fi ;;
  *) V "  device_idle_constants in force" "present" "$_dz_live" present ;;
esac
if [ -r /data/adb/asb/night_window.conf ]; then
  _ns="$(grep -E '^sleep_min=' /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  _nw="$(grep -E '^wake_min='  /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  _nn="$(grep -E '^samples='   /data/adb/asb/night_window.conf | head -1 | sed 's/.*=//')"
  # Printed as clock times: minutes-since-midnight is what the file stores and what
  # nobody can read at a glance.
  NOTE "learned sleep window: $(printf '%02d:%02d' $((_ns/60)) $((_ns%60)))-$(printf '%02d:%02d' $((_nw/60)) $((_nw%60))) from ${_nn} night(s)"
  _minsmp="$(cfg night_quiet_auto_min_samples)"; : "${_minsmp:=3}"
  if [ "${_nn:-0}" -lt "$_minsmp" ] 2>/dev/null; then
    NOTE "below ${_minsmp} samples - the configured hours are still being used instead"
  fi
else
  NOTE "no learned window yet (night_window.conf absent) - static hours in use"
fi
# AOD is borrowed, not disabled: the baseline file existing means it is currently paused,
# and its absence means either the window is closed or the user never had AOD on.
[ -f /data/adb/asb/aod_baseline ] \
  && NOTE "AOD currently paused by ASB (original: $(cat /data/adb/asb/aod_baseline 2>/dev/null))" \
  || NOTE "AOD not currently held by ASB (doze_always_on = $(settings get secure doze_always_on 2>/dev/null))"

# =====================================================================
SEC "8b. INTERFACE / SYSTEM TWEAKS"
V "  window blur disabled" "$(cfg disable_blur)" \
  "$(settings get global disable_window_blurs 2>/dev/null)" present
NOTE "ui_effects_level = $(cfg ui_effects_level)  ·  anim_level prop = $(gp persist.sys.oplus.anim_level)"
NOTE "phantom_procs = $(cfg phantom_procs)  ·  live: $(settings get global settings_enable_monitor_phantom_procs 2>/dev/null)"
NOTE "lockscreen_shortcuts = $(cfg lockscreen_shortcuts)"
# The property that caused a bootloop. Worth naming explicitly in every report: if it is
# ever back in system.prop, that is the first thing to look at.
_vdb="$(gp vendor.display.supports_background_blur)"
case "$_vdb" in
  0) BAD_NOTE="  vendor.display.supports_background_blur = 0 - this value bootloops the display stack"; P "$BAD_NOTE" ;;
  *) NOTE "vendor.display.supports_background_blur = ${_vdb:-<unset>} (0 would be a problem)" ;;
esac
[ -f /data/adb/asb/prop_blocks_disabled ] \
  && NOTE "BOOT SAFETY FIRED: $(cat /data/adb/asb/prop_blocks_disabled 2>/dev/null | tr '\n' ' ')"

# =====================================================================
SEC "9. WEBUI CONFIG  (governor.conf — what the user selected)"
if [ -f "$CONF" ]; then
  P "  $CONF :"
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$CONF" 2>/dev/null | while IFS= read -r _line; do P "    $_line"; done
else
  P "  governor.conf not found"
fi

# =====================================================================
SEC "10. HARDWARE PROFILE  (for per-SoC governor / profile tuning)"
P "  This section captures the full CPU/GPU/thermal topology so the governor,"
P "  profiles and Smart mode can be tuned individually per SoC (canoe/sun/"
P "  pineapple). The clusters and frequency tables differ per chip, which is why"
P "  one set of battery caps can feel sluggish on OP12 but fine on OP15."
P ""

# --- 10a. CPU cluster topology + full frequency tables ---
P "  CPU CLUSTERS (policy = a cluster; lists every available frequency):"
for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pol" ] || continue
  _pn=$(basename "$_pol")
  _cpus=$(cat "$_pol/affected_cpus" 2>/dev/null)
  _cmin=$(cat "$_pol/cpuinfo_min_freq" 2>/dev/null)
  _cmax=$(cat "$_pol/cpuinfo_max_freq" 2>/dev/null)
  _smin=$(cat "$_pol/scaling_min_freq" 2>/dev/null)
  _smax=$(cat "$_pol/scaling_max_freq" 2>/dev/null)
  _cur=$(cat "$_pol/scaling_cur_freq" 2>/dev/null)
  _gov=$(cat "$_pol/scaling_governor" 2>/dev/null)
  _drv="$(cat "$_pol/scaling_driver" 2>/dev/null)"
  # Writability of both cap nodes: a device can expose a frequency table while
  # rejecting writes, in which case ASB must report an OEM/kernel owner rather than claim control.
  if [ -w "$_pol/scaling_max_freq" ]; then _wf="writable"; else _wf="NOT-writable"; fi
  if [ -w "$_pol/scaling_min_freq" ]; then _minwf="writable"; else _minwf="NOT-writable"; fi
  _lowest="$(tr ' ' '\n' < "$_pol/scaling_available_frequencies" 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {print}' | sort -n | awk 'NF{print; exit}')"
  _prof_live="$(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
  _state_live="$(grep '^state=' /dev/.asb/state 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
  P "  [$_pn] cpus={$_cpus} gov=$_gov scaling_max=$_wf scaling_min=$_minwf"
  P "        hw_range : $_cmin .. $_cmax"
  P "        scaling  : min=$_smin max=$_smax cur=$_cur"
  P "        lowest_opp: ${_lowest:-unknown}"
  case "$_state_live" in DEEP_IDLE|LIGHT_IDLE|MODERATE|SUSTAINED) _smart_low_floor_state=1 ;; *) _smart_low_floor_state=0 ;; esac
  if [ "$_prof_live" = "smart" ] && [ "$_smart_low_floor_state" = "1" ] && [ -n "$_lowest" ]; then
    if [ "$_smin" = "$_lowest" ]; then
      P "        smart minimum: [PASS] Smart requested hardware lowest OPP"
    else
      case "$_drv:$_gov" in
        *scmi*|*walt*)
          # SCMI/walt enforces a vendor floor in firmware: the write lands, the driver
          # clamps it back. Naming the owner here ends the "did ASB fail to write?" hunt.
          P "        smart minimum: [WARN] want=$_lowest live=${_smin:-unknown} (vendor floor - $_drv/$_gov clamps the minimum, not a write failure)" ;;
        *)
          P "        smart minimum: [WARN] want=$_lowest live=${_smin:-unknown} (vendor/kernel override or write failure)" ;;
      esac
    fi
  else
    P "        smart minimum: not expected (profile=${_prof_live:-none} state=${_state_live:-unknown})"
  fi
  P "        available: $(cat "$_pol/scaling_available_frequencies" 2>/dev/null)"
  # governor tunables that shape responsiveness (schedutil / walt)
  for _t in schedutil/rate_limit_us schedutil/up_rate_limit_us \
            schedutil/down_rate_limit_us schedutil/hispeed_freq \
            walt/target_loads walt/up_rate_limit_us walt/down_rate_limit_us; do
    [ -r "$_pol/$_t" ] && P "        tunable $_t = $(cat "$_pol/$_t" 2>/dev/null)"
  done
  # boost / scaling driver
  [ -r "$_pol/scaling_driver" ] && P "        driver   = $(cat "$_pol/scaling_driver" 2>/dev/null)"
done
P ""
# how many distinct clusters -> tells us the topology class
_ncl=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | wc -l)
NOTE "cluster count = $_ncl  (canoe/sun usually 2 policies for a 6+2; pineapple 4: 1+3+2+1)"
# Show how ASB's governor maps physical policies -> logical slots (little/big/
# prime). On a 4-cluster OP12 the governor now assigns first->little, last->
# prime, all middles->big, and applies the big cap to BOTH middle clusters.
_pol_ids=""
for _pp in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_pp" ] && _pol_ids="$_pol_ids $(basename "$_pp" | sed 's/policy//')"
done
_pol_ids="$(echo $_pol_ids | tr ' ' '\n' | sort -n | tr '\n' ' ')"
P "  governor slot mapping (physical policy -> slot):"
# Read the map the governor publishes instead of re-deriving it.
#
# The old rule (first policy slot0, last policy slot2) disagreed with the governor on
# two-cluster phones, where the second policy is slot1 and slot2 is empty. The report
# said "policy6 -> slot2 (prime)" while the governor ran the prime as slot1 - the line
# that should explain the cap numbers contradicted them. The re-derivation stays only
# as a fallback for a governor too old to publish slot_policy_ids.
_spm="$(grep -m1 '^slot_policy_ids=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
case "$_spm" in
  *,*,*)
    _sn=0; _snames="little mid prime"
    _ncl=0; for _sp in $(echo "$_spm" | tr ',' ' '); do [ "$_sp" -ge 0 ] 2>/dev/null && _ncl=$((_ncl+1)); done
    for _sp in $(echo "$_spm" | tr ',' ' '); do
      if [ "$_sp" -ge 0 ] 2>/dev/null; then
        # Name by position among the populated slots: the highest populated slot is
        # always the prime, whatever its index.
        _role=little
        [ "$_sn" -gt 0 ] && _role=mid
        _hi=-1; _k=0; for _q in $(echo "$_spm" | tr ',' ' '); do [ "$_q" -ge 0 ] 2>/dev/null && _hi=$_k; _k=$((_k+1)); done
        [ "$_sn" -eq "$_hi" ] && [ "$_ncl" -gt 1 ] && _role=prime
        P "    policy$_sp -> slot$_sn ($_role)"
      else
        P "    slot$_sn -> (empty)"
      fi
      _sn=$((_sn+1))
    done ;;
  *)
    _first=""; _last=""
    for _id in $_pol_ids; do [ -z "$_first" ] && _first="$_id"; _last="$_id"; done
    for _id in $_pol_ids; do
      if [ "$_id" = "$_first" ]; then P "    policy$_id -> slot0 (little)"
      elif [ "$_id" = "$_last" ]; then P "    policy$_id -> slot2 (prime)"
      else P "    policy$_id -> slot1 (big)"; fi
    done
    P "    (reconstructed - governor did not publish slot_policy_ids)" ;;
esac
P "  PER-CORE map:"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpufreq/scaling_cur_freq" ] || continue
  P "    $_cn: online=$(cat "$_c/online" 2>/dev/null || echo 1) cur=$(cat "$_c/cpufreq/scaling_cur_freq" 2>/dev/null)"
done

# --- 10b. CPU capacity / EAS energy model (key for Smart scheduling) ---
P ""
P "  CPU CAPACITY (EAS energy model — relative core strength):"
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
  _cn=$(basename "$_c")
  [ -r "$_c/cpu_capacity" ] && P "    $_cn capacity = $(cat "$_c/cpu_capacity" 2>/dev/null)"
done

# --- 10c. sched / walt knobs ASB's governor reasons about ---
P ""
P "  SCHED / WALT globals:"
for _s in /proc/sys/kernel/sched_util_clamp_min /proc/sys/kernel/sched_util_clamp_max \
          /proc/sys/kernel/sched_schedstats; do
  [ -r "$_s" ] && P "    $(basename $_s) = $(cat $_s 2>/dev/null)"
done
for _wp in /sys/devices/system/cpu/walt/sched_boost \
           /proc/sys/walt/sched_boost; do
  [ -r "$_wp" ] && P "    $(echo $_wp|sed 's#.*/##') = $(cat $_wp 2>/dev/null)"
done
# msm_performance (governor writes cpu_max_freq here)
[ -r /sys/kernel/msm_performance/parameters/cpu_max_freq ] && \
  P "    msm_performance cpu_max_freq = $(cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)"

# --- 10d. GPU full profile ---
P ""
P "  GPU (Adreno):"
_kg=/sys/class/kgsl/kgsl-3d0
if [ -d "$_kg" ]; then
  P "    model          = $(cat $_kg/gpu_model 2>/dev/null)"
  P "    governor       = $(cat $_kg/devfreq/governor 2>/dev/null)"
  P "    cur_freq       = $(cat $_kg/devfreq/cur_freq 2>/dev/null)"
  P "    min/max_freq   = $(cat $_kg/devfreq/min_freq 2>/dev/null) / $(cat $_kg/devfreq/max_freq 2>/dev/null)"
  P "    available_freq = $(cat $_kg/devfreq/available_frequencies 2>/dev/null)"
  P "    max_pwrlevel   = $(cat $_kg/max_pwrlevel 2>/dev/null)  (num_pwrlevels=$(cat $_kg/num_pwrlevels 2>/dev/null))"
  P "    min_pwrlevel   = $(cat $_kg/min_pwrlevel 2>/dev/null)"
  P "    default_pwr    = $(cat $_kg/default_pwrlevel 2>/dev/null)"
  P "    busy_pct       = $(cat $_kg/gpubusy 2>/dev/null)"
  P "    throttling     = $(cat $_kg/throttling 2>/dev/null)"
  # GPU write-test: does ASB actually control the GPU ceiling, or does the vendor governor
  # (msm-adreno-tz) override it like walt does for CPU?
  _gdv="$_kg/devfreq"
  if [ "$WRITE_TEST" != "1" ]; then
    NOTE "GPU write-test skipped in safe read-only mode (rerun with --write-test while idle)"
  elif [ -w "$_gdv/max_freq" ] && [ -s "$_gdv/available_frequencies" ]; then
    _g_orig="$(cat "$_gdv/max_freq" 2>/dev/null)"
    _g_try="$(tr ' ' '\n' < "$_gdv/available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
    if [ -n "$_g_try" ] && [ "$_g_try" != "$_g_orig" ]; then
      echo "$_g_try" > "$_gdv/max_freq" 2>/dev/null
      _g_read="$(cat "$_gdv/max_freq" 2>/dev/null)"
      if [ "$_g_read" = "$_g_try" ]; then
        P "    [PASS] GPU max_freq write-test: wrote $_g_try, read back $_g_read (ASB CAN cap the GPU)"
      else
        P "    [FAIL] GPU max_freq write-test: wrote $_g_try but read back $_g_read (vendor governor OVERRIDES the GPU cap)"
      fi
      [ -n "$_g_orig" ] && echo "$_g_orig" > "$_gdv/max_freq" 2>/dev/null
    else
      P "    GPU write-test skipped (no distinct available freq)"
    fi
  elif [ -w "$_kg/max_pwrlevel" ]; then
    _p_orig="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    _p_try=$(( ${_p_orig:-0} + 1 ))
    echo "$_p_try" > "$_kg/max_pwrlevel" 2>/dev/null
    _p_read="$(cat "$_kg/max_pwrlevel" 2>/dev/null)"
    if [ "$_p_read" = "$_p_try" ]; then
      P "    [PASS] GPU max_pwrlevel write-test: wrote $_p_try, read back $_p_read (ASB CAN cap via pwrlevel)"
    else
      P "    [FAIL] GPU max_pwrlevel write-test: wrote $_p_try but read back $_p_read (vendor OVERRIDES pwrlevel)"
    fi
    [ -n "$_p_orig" ] && echo "$_p_orig" > "$_kg/max_pwrlevel" 2>/dev/null
  fi
else
  _gdev=""
  for _gd in /sys/class/devfreq/*gpu* /sys/class/devfreq/*mali* /sys/class/devfreq/*powervr* \
             /sys/class/devfreq/*xclipse* /sys/class/devfreq/*adreno* /sys/class/devfreq/*kgsl*; do
    [ -r "$_gd/max_freq" ] && { _gdev="$_gd"; break; }
  done
  if [ -n "$_gdev" ]; then
    P "    generic devfreq  = ${_gdev##*/}"
    P "    governor        = $(cat "$_gdev/governor" 2>/dev/null)"
    P "    cur_freq        = $(cat "$_gdev/cur_freq" 2>/dev/null)"
    P "    min/max_freq    = $(cat "$_gdev/min_freq" 2>/dev/null) / $(cat "$_gdev/max_freq" 2>/dev/null)"
    P "    available_freq  = $(cat "$_gdev/available_frequencies" 2>/dev/null)"
    [ -r "$_gdev/load" ] && P "    load             = $(cat "$_gdev/load" 2>/dev/null)"
    NOTE "generic GPU telemetry is capability-gated; no KGSL pwrlevel assumptions are made"
  else
    NOTE "no recognised GPU devfreq backend (CPU/thermal policy remains active; GPU telemetry is unavailable)"
  fi
fi

# --- 10e. Thermal zones + cooling (why OP12 throttles differently) ---
P ""
P "  THERMAL zones (live temps; governor reads these to back off):"
for _tz in /sys/class/thermal/thermal_zone*; do
  [ -d "$_tz" ] || continue
  _ty=$(cat "$_tz/type" 2>/dev/null)
  _tp=$(cat "$_tz/temp" 2>/dev/null)
  case "$_ty" in
    *cpu*|*gpu*|*skin*|*shell*|*soc*|*battery*|*modem*|*ddr*)
      P "    $(basename $_tz) [$_ty] = $_tp" ;;
  esac
done
# thermal config / mitigation
[ -d /sys/class/thermal/cooling_device0 ] && \
  P "  cooling devices present: $(ls -d /sys/class/thermal/cooling_device* 2>/dev/null | wc -l)"

# --- 10f. Battery state (affects what the battery profile should target) ---
P ""
P "  BATTERY:"
_bp=/sys/class/power_supply/battery
if [ -d "$_bp" ]; then
  P "    capacity   = $(cat $_bp/capacity 2>/dev/null)%"
  P "    status     = $(cat $_bp/status 2>/dev/null)"
  P "    temp       = $(cat $_bp/temp 2>/dev/null)"
  P "    current_now= $(cat $_bp/current_now 2>/dev/null)"
  P "    health     = $(cat $_bp/health 2>/dev/null)"
fi

# --- 10g. ASB governor live state (what it actually decided) ---
P ""
P "  ASB GOVERNOR live state:"
# WRITE-TEST: prove whether ASB can actually set scaling_max_freq on this device.
# If readback != what we wrote, the OEM/kernel is rejecting or overriding ASB's caps — which
# fully explains caps that never match ASB's intended per-device percentages (and battery-mode
# jank if caps don't apply).
_wt_pol="/sys/devices/system/cpu/cpufreq/policy0"
if [ "$WRITE_TEST" != "1" ]; then
  NOTE "CPU scaling_max write-test skipped in safe read-only mode (rerun with --write-test while idle)"
elif [ -w "$_wt_pol/scaling_max_freq" ]; then
  _wt_orig="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
  # pick a mid available freq distinct from current
  _wt_try="$(tr ' ' '\n' < "$_wt_pol/scaling_available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | awk 'NR==3{print}')"
  if [ -n "$_wt_try" ] && [ "$_wt_try" != "$_wt_orig" ]; then
    echo "$_wt_try" > "$_wt_pol/scaling_max_freq" 2>/dev/null
    sleep 1
    _wt_read="$(cat "$_wt_pol/scaling_max_freq" 2>/dev/null)"
    if [ "$_wt_read" = "$_wt_try" ]; then
      P "    [PASS] scaling_max write-test: wrote $_wt_try, read back $_wt_read (ASB CAN control caps)"
    else
      P "    [FAIL] scaling_max write-test: wrote $_wt_try but read back $_wt_read (OEM/kernel OVERRIDES ASB caps!)"
    fi
    # restore
    echo "$_wt_orig" > "$_wt_pol/scaling_max_freq" 2>/dev/null
  else
    P "    write-test skipped (no distinct available freq)"
  fi
else
  P "    [FAIL] scaling_max_freq is NOT writable on policy0 (ASB cannot cap CPU here!)"
fi
P "    current_profile = $(cat "$MODDIR/current_profile" 2>/dev/null || gp persist.asb.profile)"
# smart_mode flag decides whether the governor owns caps (smart) or the shell does (manual).
# If this is 1 while a manual profile is selected, the governor may be fighting
# apply_screen_aware_caps for the cap — the #1 thing to check when the live caps don't match
# the per-device percentages.
_smf="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"
P "    smart_mode_enabled flag = ${_smf:-<absent>}"
P "    smart_prev_profile = $(cat /data/adb/asb/smart_prev_profile 2>/dev/null || echo '<absent>')"
for _gp in persist.asb.profile persist.asb.smart.alpha persist.asb.last_plan \
           persist.asb.battery.session persist.asb.smart.state; do
  _gv="$(gp $_gp)"; [ -n "$_gv" ] && P "    $_gp = $_gv"
done
# governor's own log tail (decisions, throttle events). The persistent log is
# the authoritative one; check it plus the volatile copies.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" \
           /data/adb/asb/asb.log /data/local/tmp/asb.log; do
  [ -f "$_lg" ] && { P "    log tail ($_lg):"; tail -12 "$_lg" 2>/dev/null | while IFS= read -r _l; do P "      $_l"; done; break; }
done
# Pull the most recent screen_aware_caps decision (what the shell INTENDED to
# write) so it can be compared against the live %-of-hw readout above. A
# mismatch means something overwrote the shell caps after they were applied.
for _lg in /data/adb/asb/governor_persist.log "$MODDIR/asb.log" /data/adb/asb/asb.log; do
  [ -f "$_lg" ] || continue
  _sac="$(grep "screen_aware_caps:" "$_lg" 2>/dev/null | tail -1)"
  [ -n "$_sac" ] && P "    last screen_aware_caps: $_sac"
  break
done

# --- 10h. profile_bounds the module shipped (compare vs hardware above) ---
P ""
P "  SHIPPED battery rails (compare against hw freqs above):"
# The source profile_bounds.conf is intentionally NOT shipped in the installed module (it's a
# dev/source artifact); what ships is the generated .sh (and the values baked into the governor
# binary).
_pb=""
for _cand in "$MODDIR/config/profile_bounds.generated.sh" "$MODDIR/config/profile_bounds.conf"; do
  [ -f "$_cand" ] && { _pb="$_cand"; break; }
done
if [ -n "$_pb" ]; then
  P "    (source: $(basename "$_pb"))"
  grep -E '^(BATTERY|BALANCED|PERFORMANCE)_CPU_(MIN|MAX|CAP)_' "$_pb" 2>/dev/null | while IFS= read -r _l; do P "    $_l"; done
else
  NOTE "no shipped bounds file found (generated.sh expected in module/config)"
fi
P ""
P "  >>> TUNING HINT: compare BATTERY_CPU_MAX_* above with each cluster's real"
P "      'available' table. If a battery cap doesn't line up with an actual"
P "      frequency step for THIS SoC's clusters, the governor may be pinning the"
P "      wrong cluster low (the likely cause of OP12 battery-mode sluggishness)."

P "  PASS=$PASS   FAIL=$FAIL   N/A=$NA   OFF=$OFFN   info=$INFO"
[ "$OFFN" -gt 0 ] && P "  OFF = checks not run because the setting is off/auto here: $OFF_LIST"
# Normalized score so devices are comparable. Raw PASS counts mislead (a device
# with more applicable checks, e.g. bt_absvol=on + aggressive toggles, racks up
# more PASS without being "better optimized"). pass_ratio = PASS / applicable.
_applicable=$((PASS + FAIL))
if [ "$_applicable" -gt 0 ]; then
  _ratio=$(( PASS * 100 / _applicable ))
  P "  applicable=$_applicable   pass_ratio=${_ratio}%   (PASS/(PASS+FAIL); N/A & info excluded)"
  P "  >>> Compare devices by pass_ratio, NOT raw PASS — a higher PASS count"
  P "      usually just means more checks applied on that model."
fi
P ""
P "  How to read this:"
P "   - PASS  = ASB's change is live in the system."
P "   - FAIL  = a file exists but the value isn't what ASB intended"
P "             (or the camera reads a partition ASB can't overlay, e.g."
P "              /odm on OP12 — see notes by each item)."
P "   - N/A   = that file/feature doesn't exist on this model (often"
P "             expected: conf_tuning/qape are absent on OP12/Gen3)."
P "   - (i)   = informational (toggle states, live props, link info).
   - OFF   = not checked because your setting turns that feature off (or
             leaves it on auto). Two phones with different settings will
             show different PASS counts - compare pass_ratio, not PASS."
P ""
P "  Report saved to:"
[ -n "$OUT1" ] && P "    $OUT1"
[ -n "$OUT2" ] && P "    $OUT2"
P "################################################################"
