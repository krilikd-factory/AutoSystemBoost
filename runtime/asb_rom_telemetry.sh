#!/system/bin/sh
# asb_rom_telemetry.sh - the read-only ROM snapshot the Monitor shows on Stock (fix177).
#
# The WebUI's root call holds the page until the command returns: nothing is drawn, no tap is
# answered. The inline command this replaces forked a `cat` for every value - two per thermal
# zone, and an OP15 publishes over a hundred zones - and started the Java settings client on
# every 10-second pass. Opening Monitor on Stock waited for all of it before the page slid in,
# which is the "Monitor takes long to open on Stock" report.
#
# Here every read is the shell's own `read` (no process), only thermal zones whose type the
# Monitor shows are read at all (some PMIC/ADC zones take milliseconds per read), and the one
# value that needs the settings client is refreshed in the background into a tmpfs cache:
#   sh asb_rom_telemetry.sh            print the snapshot (cached settings value)
#   sh asb_rom_telemetry.sh refresh    the same, and refresh the cache detached
# Output: key=value lines, the format parseStockTelemetry() in the WebUI reads.

CACHE="${ASB_ROM_TEL_CACHE:-/dev/.asb_rom_mdao}"
SYS="${ASB_ROM_TEL_SYS:-/sys}"
PROC="${ASB_ROM_TEL_PROC:-/proc}"

_r() {
  _v=""
  [ -r "$1" ] && read -r _v < "$1" 2>/dev/null
  printf '%s=%s\n' "$2" "$_v"
}

_up=""; read -r _up _x < "$PROC/uptime" 2>/dev/null
echo "uptime=$_up"
_l1=""; _l5=""; _l15=""; read -r _l1 _l5 _l15 _x < "$PROC/loadavg" 2>/dev/null
echo "loadavg=$_l1 $_l5 $_l15"
# Online CPUs (fix189), so the Monitor can give the load as a share of the cores: the file
# reads "0-7", or "0-3,6-7" with cores parked.
_on=""; read -r _on < "$SYS/devices/system/cpu/online" 2>/dev/null
_nc=0; _rest="${_on:+$_on,}"
while [ -n "$_rest" ]; do
  _r="${_rest%%,*}"; _rest="${_rest#*,}"
  case "$_r" in *-*) _a="${_r%-*}"; _b="${_r#*-}" ;; *) _a="$_r"; _b="$_r" ;; esac
  case "$_a$_b" in ''|*[!0-9]*) continue ;; esac
  _nc=$((_nc + _b - _a + 1))
done
echo "cpus_online=$_nc"

_b="$SYS/class/power_supply/battery"
for _f in capacity current_now voltage_now temp status charge_full; do
  _r "$_b/$_f" "battery.$_f"
done

# The settings wrapper (asb_settings.sh) falls back to the content provider on builds where
# `settings` answers "Failure calling service" and exits 0; the background reader loads it.
if [ "${1:-}" = refresh ] && command -v settings >/dev/null 2>&1; then
  nohup sh -c '[ -r "$1/asb_settings.sh" ] && . "$1/asb_settings.sh"
    v="$(settings get global mobile_data_always_on 2>/dev/null)"
    printf "%s\n" "$v" > "$0.tmp" && mv -f "$0.tmp" "$0"' \
    "$CACHE" "$(dirname "$0")" </dev/null >/dev/null 2>&1 &
fi
_md=""; [ -r "$CACHE" ] && read -r _md < "$CACHE" 2>/dev/null
echo "settings.global.mobile_data_always_on=$_md"

while read -r _k _v _u; do
  case "$_k" in
    MemTotal:|MemAvailable:|MemFree:|Cached:|SwapTotal:|SwapFree:) echo "$_k $_v kB" ;;
  esac
done < "$PROC/meminfo"

for _d in "$SYS"/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_d" ] || continue
  _n="${_d##*/}"
  for _f in scaling_min_freq scaling_max_freq scaling_cur_freq scaling_governor cpuinfo_max_freq; do
    _r "$_d/$_f" "cpu.$_n.$_f"
  done
done

_g="$SYS/class/kgsl/kgsl-3d0"
if [ -d "$_g" ]; then
  for _f in gpuclk gpu_busy_percentage gpubusy max_pwrlevel min_pwrlevel thermal_pwrlevel; do
    _r "$_g/$_f" "gpu.$_f"
  done
fi

# The zones the Monitor reads: CPU, GPU, DDR, board, shell/skin. Trip points and current or
# voltage alarms are not temperatures (fix168) and are skipped before their temp is read.
for _z in "$SYS"/class/thermal/thermal_zone*; do
  _t=""
  { read -r _t < "$_z/type" || [ -n "$_t" ]; } 2>/dev/null || continue
  case "$_t" in
    *[Tt][Rr][Ii][Pp]*|*[Bb][Cc][Ll]*|*[Ll][Vv][Ll]*|*[Ll][Ii][Mm][Ii][Tt]*|*[Ii][Bb][Aa][Tt]*|*[Vv][Bb][Aa][Tt]*|*[Ss][Oo][Cc][Dd]*) continue ;;
    *[Cc][Pp][Uu]*|*[Gg][Pp][Uu]*|*[Dd][Dd][Rr]*|[Bb][Oo][Aa][Rr][Dd]*|*[Ss][Hh][Ee][Ll][Ll]*|*[Ss][Kk][Ii][Nn]*|\
    *[Ss][Uu][Rr][Ff][Aa][Cc][Ee]*|*[Ff][Rr][Aa][Mm][Ee]*|*[Bb][Aa][Cc][Kk]*|*[Ff][Rr][Oo][Nn][Tt]*) : ;;
    *) continue ;;
  esac
  _v=""
  { read -r _v < "$_z/temp" || [ -n "$_v" ]; } 2>/dev/null || continue
  [ -n "$_v" ] && echo "thermal.$_t=$_v"
done
exit 0
