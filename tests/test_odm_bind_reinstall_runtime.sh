#!/bin/sh
# Runtime (fix146): an install over a running module keeps its /odm runtime binds.
#
# PLQ110 (Ace 6, non-reference): "effects config WITHOUT ASB: /odm/etc/audio_effects_config.xml",
# "library mapped into the audio HAL: absent", no "odm-side audio/media" line in the install
# log. The generator's reset ran after the audio stage and deleted the effects-config bind
# the DSP registration had just queued; its own copy of the live file - after an update, the
# previous install's bind - was then dropped as "identical to the live file". Each install
# over a running module lost every /odm audio bind, and the next one restored them.
# The REAL install functions run here on fake /odm paths, a fake mountinfo and stub patchers.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL odm bind reinstall: $*" >&2; fail=1; }

: > "$T/fns.sh"
for fn in asb_reset_odm_binds asb_odm_fingerprint asb_odm_bound_by_asb asb_generate_odm_binds asb_bind_register_odm_effects; do
  awk -v n="$fn" '$0 ~ "^" n "\\(\\) \\{" { f = 1 } f { print } f && /^}/ { exit }' "$I" >> "$T/fns.sh"
  grep -q "^$fn() {" "$T/fns.sh" || { echo "FAIL odm bind reinstall: $fn not found in install.sh" >&2; exit 1; }
done

L="$T/live"; P="$T/patched"; M="$T/man"; MI="$T/mountinfo"
mkdir -p "$L/odm/etc/audio" "$L/odm/etc/camera"
stock() {
  printf '<audioPolicyConfiguration rates="48000"/>\n' > "$L/odm/etc/audio/audio_policy_configuration.xml"
  printf '<mixer>\n<ctl name="RX Digital Volume" value="84"/>\n</mixer>\n' > "$L/odm/etc/mixer_paths.xml"
  printf '<audio_effects_conf>\n<libraries>\n</libraries>\n<effects>\n</effects>\n</audio_effects_conf>\n' > "$L/odm/etc/audio_effects_config.xml"
  printf '<MediaSettings unchanged="1"/>\n' > "$L/odm/etc/media_profiles_V1_0.xml"
}
cat > "$T/stubs.sh" <<'X'
ui_print() { echo "$*" >> "$UILOG"; }
getprop() { case "$1" in ro.odm.build.fingerprint) printf '%s\n' "$FP" ;; esac; }
chcon() { :; }
asb_lift_hires_policy() { sed -i 's/rates="48000"/rates="48000,96000,192000"/' "$1"; }
asb_patch_one_mixer() { sed -i 's/value="84"/value="88"/' "$1"; }
asb_media_lift_file() { :; }
asb_audio_ensure_volume_libs() { :; }
asb_register_dsp_effect() { sed -i '/asb_loudness/d' "$1"; sed -i 's#</effects>#<effect name="asb_loudness" library="asbdsp"/>\n</effects>#' "$1"; }
X
run() {   # one install: reset, the audio stage's DSP registration, the generator
  : > "$T/ui"
  UILOG="$T/ui" FP="$1" ASB_AUDIO=true ASB_MEDIA=true ASB_ODM_PATCHED="$P" ASB_ODM_MAN="$M" \
  ASB_ODM_LIVE_PREFIX="$L" ASB_ODM_MOUNTINFO="$MI" sh -c '
    . "$1"; . "$2"
    asb_reset_odm_binds
    asb_bind_register_odm_effects /odm/etc/audio_effects_config.xml >/dev/null
    asb_generate_odm_binds' x "$T/stubs.sh" "$T/fns.sh"
}
# The boot after an install: the rebind puts each payload in front of its target.
boot() {
  : > "$MI"
  while IFS='|' read -r _t _p; do
    [ -n "$_t" ] || continue
    cp -f "$_p" "$L$_t"
    printf '100 50 254:79 /adb/asb/odm_patched%s %s rw - f2fs /dev/block/dm-79 rw\n' "$_t" "$_t" >> "$MI"
  done < "$M"
}
queued() { grep -q "^$1|" "$M" 2>/dev/null; }

# 1. A first install over stock /odm.
stock; : > "$MI"; run FP1
queued /odm/etc/audio_effects_config.xml || f "fresh install: effects config not queued: $(cat "$M" 2>/dev/null)"
queued /odm/etc/mixer_paths.xml || f "fresh install: mixer not queued"
queued /odm/etc/audio/audio_policy_configuration.xml || f "fresh install: audio policy not queued"
queued /odm/etc/media_profiles_V1_0.xml && f "a file the patch left unchanged was queued"
[ "$(grep -c '^/odm/etc/audio_effects_config.xml|' "$M")" = 1 ] || f "effects config queued twice"
grep -q 'odm-side audio/media: 2 file(s) patched' "$T/ui" || f "install line: $(cat "$T/ui")"
grep -q 'value="84"' "$P/odm/etc/mixer_paths.xml.stock" || f "no stock snapshot of the mixer"
p1="$(cat "$P/odm/etc/mixer_paths.xml")"

# 2. Reboot, then install again over the running module - the case that lost every bind.
boot; run FP1
queued /odm/etc/audio_effects_config.xml || f "reinstall: effects config bind lost (the PLQ110 DSP): $(cat "$M" 2>/dev/null)"
queued /odm/etc/mixer_paths.xml || f "reinstall: mixer bind lost"
queued /odm/etc/audio/audio_policy_configuration.xml || f "reinstall: audio policy bind lost"
[ "$(cat "$P/odm/etc/mixer_paths.xml")" = "$p1" ] || f "reinstall: mixer payload not built from the stock snapshot"
grep -q 'value="84"' "$P/odm/etc/mixer_paths.xml.stock" || f "reinstall: stock snapshot overwritten by the bound copy"
[ "$(grep -c asb_loudness "$P/odm/etc/audio_effects_config.xml")" = 1 ] || f "reinstall: effects payload without exactly one ASB effect"
# and a third time
boot; run FP1
queued /odm/etc/audio_effects_config.xml && queued /odm/etc/mixer_paths.xml || f "third install lost a bind: $(cat "$M" 2>/dev/null)"

# 3. A device installed by a build before fix146: bound, no stock snapshot.
boot; rm -f "$P"/odm/etc/*.stock "$P"/odm/etc/audio/*.stock "$P/.base_fp"
run FP1
queued /odm/etc/mixer_paths.xml || f "pre-fix146 device: mixer bind lost"
[ "$(cat "$P/odm/etc/mixer_paths.xml")" = "$p1" ] || f "pre-fix146 device: re-patching the bound copy is not idempotent"
[ -e "$P/odm/etc/mixer_paths.xml.stock" ] && f "pre-fix146 device: the bound copy was saved as the stock snapshot"

# 4. A system update with the binds in front: the generator's own files are held back once.
boot; run FP2
queued /odm/etc/mixer_paths.xml && f "after an update a stale base was queued"
grep -q 'changed with a system update' "$T/ui" || f "update not said: $(cat "$T/ui")"
queued /odm/etc/audio_effects_config.xml || f "after an update the DSP bind was dropped"
# The reboot shows the new stock; the next install snapshots and queues it again.
boot; stock; sed -i 's/value="84"/value="84" new="1"/' "$L/odm/etc/mixer_paths.xml"; : > "$MI"; run FP2
queued /odm/etc/mixer_paths.xml || f "after the update's reboot the mixer was not queued again"
grep -q 'new="1"' "$P/odm/etc/mixer_paths.xml" || f "the new stock was not the base"

# 5. /odm a link to /vendor/odm: the kernel records the resolved mount point.
rm -rf "$L" "$P" "$M"; mkdir -p "$L/vendor/odm/etc/audio" "$L/vendor/odm/etc/camera"; ln -s vendor/odm "$L/odm"
stock; : > "$MI"; run FP1
sed 's#^/odm/#/vendor/odm/#' "$M" > "$M.r"; mv "$M.r" "$M.v"
boot_v() { : > "$MI"; while IFS='|' read -r _t _p; do printf '100 50 254:79 /adb/asb/odm_patched%s %s rw - f2fs /dev/block/dm-79 rw\n' "${_t#/vendor}" "$_t" >> "$MI"; done < "$M.v"; }
for _t in /odm/etc/mixer_paths.xml /odm/etc/audio_effects_config.xml; do cp -f "$P$_t" "$L$_t"; done
boot_v; run FP1
queued /odm/etc/mixer_paths.xml || f "/odm as a link: the bind in front was not recognised and the mixer was dropped"

# 6. Wiring: the reset runs before the audio stage of the non-reference path.
awk '/asb_reset_odm_binds$/ { r = NR } /asb_apply_device_native_tuning "\$ASB_DEVICE_NAME" "OnePlus"/ { if (!a) a = NR } END { exit !(r && a && r < a) }' "$I" \
  || f "asb_reset_odm_binds is not called before the non-reference audio stage"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q 'rm -rf "\$_ob_root"' && f "the generator still wipes the payload directory"
sed -n '/^asb_generate_odm_binds() {/,/^}/p' "$I" | grep -q '/odm/etc/audio_effects_config.xml \\' && f "the generator still writes the effects config"

[ "$fail" = 0 ] && echo "PASS odm bind reinstall: binds survive an install over a running module, stock snapshots kept, updates handled"
exit "$fail"
