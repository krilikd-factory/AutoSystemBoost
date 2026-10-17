#!/bin/sh
# Runtime (fix155): "DSP Outputs = off" switches the whole DSP off in one step.
#
# Asked for: turning the DSP off meant pulling loudness, bass and voice tone to zero one by
# one, and setting them up again afterwards. The REAL asb_audio_apply.sh runs on a mocked
# property store: with dsp_outputs=off the engine is disabled and says why, the slider
# values stay in the config, the Smart tuner's mirror pass does not switch it back on, and
# the WebUI, action screen and asbdiag treat it as off.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL dsp outputs off: $*" >&2; exit 1; }
MOD="$T/mod"; BIN="$T/bin"
mkdir -p "$MOD/config" "$MOD/runtime" "$BIN"
cp "$ROOT/runtime/asb_audio_apply.sh" "$ROOT/runtime/asb_dsp_thermal.sh" "$ROOT/runtime/asb_dsp_live.sh" "$MOD/runtime/"
printf 'dsp_loudness=25\ndsp_bass=2\ndsp_voice=4\ndsp_outputs=off\naudio_profile=hifi\n' > "$MOD/config/governor.conf"
PROPS="$T/props"; : > "$PROPS"
cat > "$BIN/getprop" <<'X'
#!/bin/sh
grep -m1 "^$1=" "$PROPS" 2>/dev/null | cut -d= -f2-
X
cat > "$BIN/resetprop" <<'X'
#!/bin/sh
[ "$1" = "-n" ] && shift
grep -v "^$1=" "$PROPS" > "$PROPS.t" 2>/dev/null || true
printf '%s=%s\n' "$1" "$2" >> "$PROPS.t"; mv "$PROPS.t" "$PROPS"
X
cp "$BIN/resetprop" "$BIN/setprop"
printf '#!/bin/sh\nexit 0\n' > "$BIN/pkill"
printf '#!/bin/sh\nexit 0\n' > "$BIN/dumpsys"
chmod 0755 "$BIN"/*
export PATH="$BIN:$PATH" PROPS ASB_DSP_TH_STATE="$T/th" ASB_DSP_TH_BAT="$T/bat"
prop() { grep -m1 "^$1=" "$PROPS" | cut -d= -f2-; }
resetprop -n persist.asb.dsp.enable 1
MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" dsp > "$T/out" 2>&1 || true
[ "$(prop persist.asb.dsp.enable)" = 0 ] || fail "the DSP is still enabled: $(prop persist.asb.dsp.enable)"
[ "$(prop persist.asb.dsp.inactive_reason)" = outputs_off ] || fail "no reason given: $(prop persist.asb.dsp.inactive_reason)"
grep -q 'dsp=off(outputs)' "$T/out" || fail "the run does not say why: $(cat "$T/out")"
grep -qx 'dsp_loudness=25' "$MOD/config/governor.conf" && grep -qx 'dsp_bass=2' "$MOD/config/governor.conf" \
  || fail "the sliders were touched"
MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" mirror >/dev/null 2>&1 || true
[ "$(prop persist.asb.dsp.enable)" = 0 ] || fail "the mirror pass switched the DSP back on"
UI="$ROOT/webroot/index.html"
grep -q "key:'dsp_outputs', type:'seg', def:'all', stock:'all', opts:\['off','all'," "$UI" || fail "no off in the WebUI"
grep -q "_cfgVals\['dsp_outputs'\] === 'off' &&" "$UI" || fail "the DSP cards do not show off"
for l in ar de en es fr hy id it pt ru tr uk zh; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['optFor']['dsp_outputs']['off']" "$ROOT/webroot/i18n/$l.json" \
    || fail "$l.json has no label for off"
done
grep -q '\[ "$(_cfg dsp_outputs)" = "off" \] && \[ "$_a_dsp" != "off" \]' "$ROOT/action.sh" || fail "action screen still lists the DSP as on"
grep -q '^\[ "$(cfg dsp_outputs)" = "off" \] && _dsp_g=outputs_off$' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still checks the gain"
echo "PASS dsp outputs off: one switch turns the DSP off, sliders kept, mirror keeps it off"
