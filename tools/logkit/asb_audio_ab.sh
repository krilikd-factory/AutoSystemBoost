#!/system/bin/sh
# ASB audio A/B probe: captures the audio pipeline state while music is quiet,
# then again after you open the effect app (ViPER4Android), and reports exactly
# what changed. Run it, start music, then open ViperFX when told.
MODID="AutoSystemBoost"
OUT_DIR="${1:-/data/adb/asb/audio_ab}"
DUR="${2:-60}"
IVL="${3:-3}"
mkdir -p "$OUT_DIR" 2>/dev/null
rm -f "$OUT_DIR"/tick_* "$OUT_DIR"/before.txt "$OUT_DIR"/after.txt "$OUT_DIR"/audio_ab_report.txt "$OUT_DIR"/audio_ab_timeline.tsv 2>/dev/null

ab_prop() { getprop "$1" 2>/dev/null; }

ab_route() {
  _d=$(dumpsys audio 2>/dev/null | grep -iE '^[[:space:]]*Devices:' | tr 'A-Z' 'a-z')
  case "$_d" in
    *ble_headset*|*ble_broadcast*) echo "bt_le" ;;
    *bt_a2dp*) echo "bt" ;;
    *usb_headset*) echo "usb" ;;
    *headset*|*headphone*) echo "wired" ;;
    *speaker*) echo "speaker" ;;
    *) echo "none" ;;
  esac
}

ab_playing() {
  dumpsys audio 2>/dev/null | grep -q 'state:started' && echo 1 || echo 0
}

ab_capture() {
  _label="$1"; _file="$2"
  {
    echo "===== $_label  $(date '+%H:%M:%S') route=$(ab_route) playing=$(ab_playing) ====="
    echo "## offload props"
    echo "  a2dp_offload.disabled = $(ab_prop persist.bluetooth.a2dp_offload.disabled) / vendor = $(ab_prop persist.vendor.bluetooth.a2dp_offload.disabled)"
    echo "## dumpsys audio — routing + music volume"
    dumpsys audio 2>/dev/null | grep -iE '^[[:space:]]*Devices:|- STREAM_MUSIC:|Current:|Muted:|state:started|usage=' | head -18
    echo "## audio_flinger — output threads (standby / flags / format)"
    dumpsys media.audio_flinger 2>/dev/null | grep -iE 'Output thread|I/O handle|Standby|Flags|Format|sample rate|Channel|Latency|Frame|Output devices|Track Name|State:' | head -60
    echo "## audio_flinger — effects / sessions"
    dumpsys media.audio_flinger 2>/dev/null | grep -iE 'Effect|session|viper|v4a' | head -30
    echo "## bt codec"
    dumpsys bluetooth_manager 2>/dev/null | grep -iE 'current codec|sample_?rate|bits_?per|LHDC|LDAC|aptX|SBC|AAC' | head -12
    echo ""
  } > "$_file" 2>/dev/null
}

ab_indicators() {
  _af=$(dumpsys media.audio_flinger 2>/dev/null)
  _play=$(ab_playing)
  _route=$(ab_route)
  _fx=$(printf '%s\n' "$_af" | grep -ciE 'viper|v4a|Effect [0-9a-fx]|session [0-9]')
  _offload=$(printf '%s\n' "$_af" | grep -iE 'Output thread|Standby|Flags' | grep -ciE 'offload|direct_pcm|compress')
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$_play" "$_route" "$_fx" "$_offload"
}

echo "[ASB audio A/B] output -> $OUT_DIR"
echo "[1/3] Start playing music now (BT headphones). Waiting for playback..."
_w=0
while [ "$(ab_playing)" != "1" ] && [ "$_w" -lt 60 ]; do sleep 2; _w=$((_w+2)); done
if [ "$(ab_playing)" != "1" ]; then
  echo "  ! no playback detected in 60s — capturing current state anyway."
fi
sleep 2
ab_capture "BEFORE (quiet — before ViperFX)" "$OUT_DIR/before.txt"
echo "  captured BEFORE baseline (this should be the QUIET state)."
echo "[2/3] NOW open ViPER4Android so the volume jumps. Capturing ${DUR}s..."

printf 'elapsed\tplaying\troute\tfx\toffload_hits\n' > "$OUT_DIR/audio_ab_timeline.tsv"
_t=0; _n=0
while [ "$_t" -lt "$DUR" ]; do
  _n=$((_n+1))
  ab_indicators "$_t" >> "$OUT_DIR/audio_ab_timeline.tsv"
  ab_capture "TICK $_n (t=${_t}s)" "$OUT_DIR/tick_$(printf '%03d' "$_n").txt"
  sleep "$IVL"
  _t=$((_t+IVL))
done

_last=$(ls "$OUT_DIR"/tick_*.txt 2>/dev/null | tail -1)
[ -n "$_last" ] && cp "$_last" "$OUT_DIR/after.txt"
ab_capture "AFTER (loud — after ViperFX)" "$OUT_DIR/after.txt"
echo "  captured AFTER state (this should be the LOUD state)."

echo "[3/3] Building report..."
{
  echo "================ ASB AUDIO A/B REPORT ================"
  echo "Fill this in: did the volume get LOUD when you opened ViperFX? (expected yes)"
  echo ""
  echo "---- TIMELINE (watch fx and offload_hits flip when ViperFX opened) ----"
  cat "$OUT_DIR/audio_ab_timeline.tsv"
  echo ""
  echo "---- WHAT CHANGED  (BEFORE quiet  ->  AFTER loud) ----"
  if command -v diff >/dev/null 2>&1; then
    diff "$OUT_DIR/before.txt" "$OUT_DIR/after.txt" | grep -E '^[<>]' | sed 's/^</BEFORE:/; s/^>/AFTER :/'
  else
    echo "(no diff tool — compare before.txt and after.txt manually)"
  fi
  echo ""
  echo "Full per-tick captures are in $OUT_DIR/tick_*.txt ; before.txt / after.txt hold the two ends."
} > "$OUT_DIR/audio_ab_report.txt" 2>/dev/null

echo ""
echo "DONE. Send back the whole folder: $OUT_DIR"
echo "Key file: $OUT_DIR/audio_ab_report.txt"
