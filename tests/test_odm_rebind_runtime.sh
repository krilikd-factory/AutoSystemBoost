#!/bin/sh
# Runtime: the /odm rebind judges every manifest line by what the path reads back after the
# bind, peels a stale layer in front of it once, and logs a verdict per target - the field
# case was "odm_bind_late result=applied" on a boot where neither camera file was live.
# mount/umount are stubbed: a bind copies the payload over the target and records a layer;
# a "shadow" target swallows binds until the layer on it is peeled; a "stuck" target
# swallows them for good.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL odm rebind: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/odm/camera" "$T/odm/audio" "$T/p"
S="$ROOT/runtime/asb_odm_rebind.sh"

cat > "$T/bin/mount" <<'X'
#!/bin/sh
[ "$1" = --bind ] || exit 1
p="$2"; t="$3"
echo "$t" >> "$CALLS"
[ -f "$t.stuck" ] && { echo "1 1 0:1 / $t rw - overlay KSU rw" >> "$MI"; exit 0; }
if [ -f "$t.shadow" ]; then echo "1 1 0:1 / $t rw - overlay KSU rw" >> "$MI"; exit 0; fi
cp "$t" "$t.under.$(grep -c " $t " "$MI")"
cp "$p" "$t"
echo "1 1 0:1 / $t rw - f2fs /dev/block/dm-50 rw" >> "$MI"
X
cat > "$T/bin/umount" <<'X'
#!/bin/sh
t="$1"
grep -q " $t " "$MI" || exit 1
rm -f "$t.shadow"
grep -v " $t " "$MI" > "$MI.n"; mv "$MI.n" "$MI"
exit 0
X
cat > "$T/bin/getprop" <<'X'
#!/bin/sh
printf '%s\n' '[init.svc.cameraserver]: [running]' '[init.svc.vendor.camera-provider]: [running]' '[init.svc.vendor.camera-provider-ext]: [stopped]'
X
cat > "$T/bin/setprop" <<'X'
#!/bin/sh
echo "$*" >> "$PROPS"
X
chmod +x "$T/bin/"*
export PROPS="$T/props" PATH="$T/bin:$PATH" CALLS="$T/calls" MI="$T/mi" ASB_ODM_NS=none \
       ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_MOUNTINFO="$T/mi"
true > "$T/mi"; true > "$T/calls"

echo stock4 > "$T/odm/camera/vb";   echo apps19 > "$T/p/vb"
echo stockT > "$T/odm/camera/ct";   echo graded > "$T/p/ct"
echo same   > "$T/odm/audio/fx";   echo same   > "$T/p/fx"
echo stockM > "$T/odm/audio/mx";   echo patched > "$T/p/mx"
{
  echo "$T/odm/camera/vb|$T/p/vb"
  echo "$T/odm/camera/ct|$T/p/ct"
  echo "$T/odm/audio/fx|$T/p/fx"
} > "$T/man"
# ct has a stale layer in front that swallows the first bind.
touch "$T/odm/camera/ct.shadow"; echo "1 1 0:1 / $T/odm/camera/ct rw - overlay KSU rw" >> "$T/mi"

sh "$S" apply; rc=$?
[ "$(cat "$T/odm/camera/vb")" = apps19 ] || f "retouch list not bound"
[ "$(cat "$T/odm/camera/ct")" = graded ] || f "shadowed tone table not bound after peeling"
grep -q "target=$T/odm/camera/vb result=ok" "$T/log" || f "no ok verdict for vb: $(cat "$T/log")"
grep -q "target=$T/odm/camera/ct result=retry_ok" "$T/log" || f "no retry_ok verdict for ct"
grep -q "target=$T/odm/audio/fx result=already" "$T/log" || f "unchanged file not reported as already"
grep -q "$T/odm/audio/fx" "$T/calls" && f "mounted over a file that already read the payload"
[ "$rc" = 0 ] || f "camera-only change must not ask for an audioserver restart (rc=$rc)"

[ -s "$T/props" ] && f "camera stack restarted without being asked: $(cat "$T/props")"
# Boot asks for it: a newly bound camera file restarts the running provider + cameraserver.
echo stock9 > "$T/odm/camera/vb"; true > "$T/mi"; true > "$T/props"
ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
grep -q '^ctl.restart vendor.camera-provider$' "$T/props" || f "provider not restarted after a new camera bind: $(cat "$T/props")"
grep -q '^ctl.restart cameraserver$' "$T/props" || f "cameraserver not restarted"
grep -q 'camera-provider-ext' "$T/props" && f "restarted a stopped service"
true > "$T/props"; ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
[ -s "$T/props" ] && f "camera restarted although nothing changed"
# Payload sync: the bound payload follows the module's own (boot-graded) copy, in place,
# and a change under an existing bind still counts as a camera change.
mkdir -p "$T/odm/etc/camera" "$T/mod/odm/etc/camera" "$T/p/odm/etc/camera"
echo '{ "BlendWeight": [0.35, 0.5, 0.7] }' > "$T/odm/etc/camera/tune"
echo '{ "BlendWeight": [0.35, 0.5, 0.7] }' > "$T/p/odm/etc/camera/tune"
echo '{ "BlendWeight": [1, 1, 1] }' > "$T/mod/odm/etc/camera/tune"
cp "$T/man" "$T/man.keep"
echo "$T/odm/etc/camera/tune|$T/p/odm/etc/camera/tune" > "$T/man"
# Simulate "already bound": the stub's mount copies, so bind once and then change the module copy.
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q 'BlendWeight": \[1, 1, 1\]' "$T/p/odm/etc/camera/tune" || f "payload not synced from the module copy"
grep -q 'BlendWeight": \[1, 1, 1\]' "$T/odm/etc/camera/tune" || f "synced payload not live"
grep -q "action=odm_payload_sync target=$T/odm/etc/camera/tune result=updated" "$T/log" || f "payload sync not logged"
echo '{ "BlendWeight": [0.9, 0.9, 0.9] }' > "$T/mod/odm/etc/camera/tune"
cp "$T/mod/odm/etc/camera/tune" "$T/odm/etc/camera/tune"   # in-place payload = live bind content
true > "$T/props"
ASB_ODM_MODDIR="$T/mod" ASB_ODM_RESTART_CAM=1 sh "$S" apply camera
grep -q 'ctl.restart cameraserver' "$T/props" || f "a payload rewritten under a live bind did not restart the camera stack"
echo '{ "broken": [' > "$T/mod/odm/etc/camera/tune"
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q '0.9, 0.9, 0.9' "$T/p/odm/etc/camera/tune" || f "an unbalanced module copy replaced the payload"
grep -q 'result=rejected_unbalanced' "$T/log" || f "unbalanced copy not reported"
# A module copy with whole-line // comments reaches the payload stripped.
mkdir -p "$T/mod/odm/etc/camera/config" "$T/p/odm/etc/camera/config" "$T/odm/etc/camera/config"
printf '{\n// vendor note\n"a": 1\n}\n' > "$T/mod/odm/etc/camera/config/vb"
echo '{ "a": 0 }' > "$T/p/odm/etc/camera/config/vb"; echo '{ "a": 0 }' > "$T/odm/etc/camera/config/vb"
echo "$T/odm/etc/camera/config/vb|$T/p/odm/etc/camera/config/vb" > "$T/man"
ASB_ODM_MODDIR="$T/mod" sh "$S" apply camera
grep -q '//' "$T/p/odm/etc/camera/config/vb" && f "comments copied into the payload"
grep -q '"a": 1' "$T/p/odm/etc/camera/config/vb" || f "commented module copy not synced"
ls "$T/p/odm/etc/camera/config/" | grep -q 'sync\.' && f "sync temp file left behind"
grep -Fq 'find "$MODPATH/odm" "$MODPATH/system" "$MODPATH/deferred_overlay"' "$ROOT/common/install.sh" \
  || f "installer does not strip comments from the module-root camera copy"
mv "$T/man.keep" "$T/man"
# Second run: everything live, nothing mounted.
true > "$T/calls"
sh "$S" apply
[ -s "$T/calls" ] && f "re-run mounted again over live files: $(cat "$T/calls")"

# An audio file change asks for the audioserver restart (exit 10); camera scope skips it.
echo "$T/odm/audio/mx|$T/p/mx" >> "$T/man"
sh "$S" apply camera
[ "$(cat "$T/odm/audio/mx")" = stockM ] || f "camera scope touched an audio file"
sh "$S" apply; rc=$?
[ "$rc" = 10 ] || f "audio change did not return 10 (rc=$rc)"

# A layer that never yields: reported as hidden with its mountinfo, not as applied.
echo stockZ > "$T/odm/camera/zz"; echo want > "$T/p/zz"; touch "$T/odm/camera/zz.stuck"
echo "$T/odm/camera/zz|$T/p/zz" >> "$T/man"
true > "$T/log"
sh "$S" apply camera
grep -q "target=$T/odm/camera/zz result=hidden mountinfo=.*overlay" "$T/log" || f "stuck layer not reported hidden: $(cat "$T/log")"
grep -q "result=incomplete" "$T/log" || f "incomplete pass not summarised"
grep -q "result=applied" "$T/log" && f "a pass with nothing newly bound claimed applied"

# Missing payload.
echo "$T/odm/camera/vb|$T/p/nope" >> "$T/man"
true > "$T/log"; sh "$S" apply camera
grep -q "target=$T/odm/camera/vb result=missing" "$T/log" || f "missing payload not reported"

# status
st="$(sh "$S" status)"
echo "$st" | grep -q "$T/odm/camera/vb state=live" || f "status: vb should be live: $st"
echo "$st" | grep -q "$T/odm/camera/zz state=NOT_LIVE mounted=yes" || f "status: zz should be NOT_LIVE: $st"

# Wiring: boot uses it (with a later camera pass), action self-heals, install queues always.
grep -q 'asb_odm_rebind.sh" apply' "$ROOT/service.sh" || f "service.sh does not use the checked rebind"
grep -q 'asb_odm_rebind.sh" apply camera' "$ROOT/service.sh" || f "no second camera pass at boot"
grep -q 'asb_odm_rebind.sh" apply camera' "$ROOT/action.sh" || f "action does not self-heal the camera bind"
grep -q 'odm_bind_late result=applied" >>' "$ROOT/service.sh" && f "service.sh still logs applied on any mount rc"
sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$ROOT/common/install.sh" | grep -q 'cmp -s' \
  && f "install still skips a camera bind on a live-file comparison"
grep -q 'runtime/asb_odm_rebind.sh' "$ROOT/.github/workflows/build-release.yml" || f "release workflow misses the script"

# Verdicts read the camera files through init's namespace (where the HAL reads them).
grep -q '_c_bw="$(_camg ' "$ROOT/action.sh" || f "action judges the tone table in its own namespace"
grep -q '_vb_try_n="$(_camg ' "$ROOT/action.sh" || f "action counts retouch apps in its own namespace"
grep -q 'nsenter -t 1 -m -- cat "$CT"' "$ROOT/tools/asb_diag.sh" || f "asbdiag judges the tone table in its own namespace"
grep -q 'nsenter -t 1 -m -- cat \$_f' "$ROOT/webroot/index.html" || f "WebUI camera badge reads its own namespace"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag out of sync"

[ "$fail" = 0 ] && echo "PASS odm rebind runtime"
exit "$fail"
