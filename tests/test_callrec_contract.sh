#!/usr/bin/env bash
# Call-recording contract: both tweaks default off, the line patch is device-local and
# re-derived from the live XMLs on every boot (OTA-proof), every lifecycle owner
# (install, boot, late boot, uninstall, WebUI) reaches the one runtime script, the
# bind guard is fail-closed, payloads are structurally validated XML, the XML binds
# land only at boot (never live from the WebUI), the dialer-enable features are
# gated on the OPlus dialer stack being physically present, a one-strike bootloop
# fuse (pending marker at post-fs-data, confirm after boot_completed) can lock the
# tweak down by itself, and the messenger half patches the device-shipped
# VoiceScribe prefs in place - no APK is bundled or installed anywhere.
# Same shape as the force-LTPO and mmfeed contracts.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_callrec.sh"
WEB="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL callrec contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_callrec.sh missing'
sh -n "$SRC"

# --- WebUI wiring: cards, default-off, groups, icons, honest apply labels ---
grep -q "key:'callrec_line', type:'bool', def:'0'" "$WEB" || fail 'callrec_line card missing or default not off'
grep -q "key:'callrec_apps', type:'bool', def:'0'" "$WEB" || fail 'callrec_apps card missing or default not off'
grep -q "callrec_line:'ui'" "$WEB" || fail 'callrec_line not in the System category group'
grep -q "callrec_apps:'ui'" "$WEB" || fail 'callrec_apps not in the System category group'
grep -q "callrec_line:'system'" "$WEB" || fail 'callrec_line missing category colour mapping'
grep -q "callrec_apps:'system'" "$WEB" || fail 'callrec_apps missing category colour mapping'
grep -q "callrec_line:'callrec'" "$WEB" || fail 'callrec_line missing its icon mapping'
grep -q "callrec_apps:'callrec_msg'" "$WEB" || fail 'callrec_apps missing its icon mapping'
grep -q "callrec: '<path" "$WEB" || fail 'callrec icon glyph missing from TECH_ICON_PATHS'
grep -q "callrec_msg: '<path" "$WEB" || fail 'callrec_msg icon glyph missing from TECH_ICON_PATHS'
grep -q "callrec_line:APPLY_REBOOT" "$WEB" || fail 'callrec_line must honestly label as reboot-to-apply'
grep -q "callrec_apps:APPLY_LIVE" "$WEB" || fail 'callrec_apps must honestly label as live'
grep -q "'callrec_line'," "$WEB" || fail 'callrec_line missing from SNAP_KEYS (export/restore)'
grep -q "'callrec_apps'," "$WEB" || fail 'callrec_apps missing from SNAP_KEYS (export/restore)'
grep -q "runtime/asb_callrec.sh apply" "$WEB" || fail 'cfgSet never calls the apply script'
grep -q "loadCallrecStatus" "$WEB" || fail 'status loader missing'

# --- i18n: every shipped locale carries name + desc for both cards ---
for f in "$ROOT"/webroot/i18n/*.json; do
  python3 -c "
import json,sys
d=json.load(open('$f'))
c=d.get('cfg',{})
ok = all(c.get(k,{}).get('name') and c.get(k,{}).get('desc') for k in ('callrec_line','callrec_apps'))
sys.exit(0 if ok else 1)
" || fail "callrec i18n missing in $(basename "$f")"
done

# --- config surface: defaults, registry, update-surviving key lists ---
grep -q '^callrec_line=0' "$ROOT/config/governor.conf" || fail 'callrec_line default missing from governor.conf'
grep -q '^callrec_apps=0' "$ROOT/config/governor.conf" || fail 'callrec_apps default missing from governor.conf'
grep -q '^callrec_line=0' "$ROOT/config/governor.conf.shipped" || fail 'callrec_line default missing from shipped conf'
grep -q '^callrec_apps=0' "$ROOT/config/governor.conf.shipped" || fail 'callrec_apps default missing from shipped conf'
grep -q 'callrec_line|user|webui_standard' "$ROOT/config/key_ownership.tsv" || fail 'callrec_line missing from ownership registry'
grep -q 'callrec_apps|user|webui_standard' "$ROOT/config/key_ownership.tsv" || fail 'callrec_apps missing from ownership registry'
grep -q 'callrec_line callrec_apps' "$INSTALL" || fail 'new keys missing from install.sh update-survival lists'

# --- install-time staging ---
grep -q 'asb_callrec.sh" prepare' "$INSTALL" || fail 'install never runs prepare'
grep -q 'ASB_L_CALLREC_READY' "$ROOT/common/englishtext.sh" || fail 'English install string missing'
grep -q 'ASB_L_CALLREC_READY' "$ROOT/common/russiantext.sh" || fail 'Russian install string missing'
# Patch-only contract: no APK is bundled anywhere in the tree, and the runtime script
# never installs a package - both tweaks patch files the device already carries.
if find "$ROOT" -name '*.apk' 2>/dev/null | grep -q .; then
  fail 'APK found in the module tree - the callrec tweaks are patch-only by contract'
fi
! grep -q 'pm install' "$SRC" || fail 'runtime script installs packages - patch-only contract broken'
! grep -q 'cmd package install' "$SRC" || fail 'runtime script installs packages - patch-only contract broken'
grep -q '_cr_patch_prefs()' "$SRC" || fail 'in-place prefs merge patcher missing'
grep -q 'com.coloros.accessibilityassistant' "$SRC" || fail 'VoiceScribe package constant missing'

# --- lifecycle owners ---
grep -q 'asb_callrec.sh" apply' "$ROOT/post-fs-data.sh" || fail 'post-fs-data never applies'
grep -q 'asb_callrec.sh" apply' "$ROOT/service.sh" || fail 'service.sh never rebinds late'
grep -q 'asb_callrec.sh" remove' "$ROOT/uninstall.sh" || fail 'uninstall never drops the binds'
grep -q 'callrec_line_manifest.txt' "$ROOT/post-fs-data.sh" || fail 'bootloop fuse does not clear the callrec manifest'

# --- one-strike bootloop fuse: armed at post-fs-data, confirmed after boot_completed ---
grep -q 'ASB_CALLREC_BOOT=1' "$ROOT/post-fs-data.sh" || fail 'post-fs-data does not arm the callrec boot fuse'
grep -q 'asb_callrec.sh" confirm' "$ROOT/service.sh" || fail 'service.sh never confirms a completed boot'
grep -q '_cr_xml_sane()' "$SRC" || fail 'structural XML validation missing'
grep -q '_cr_delete_block()' "$SRC" || fail 'bounded block delete missing'
grep -q 'callrec_blocked' "$SRC" || fail 'one-strike bootloop fuse missing from the engine'
grep -q 'callrec_boot_pending' "$ROOT/post-fs-data.sh" || fail 'vendor fuse cleanup misses the callrec trial marker'

# --- runtime guard pins: fail-closed allowlist, payload prefix, toggle gates ---
grep -q '/my_region/etc/extension/com.oplus.app-features.xml|' "$SRC" || fail 'target allowlist missing my_region app-features'
# The extension DIRECTORY must never be an allowed target. Allowing it is what let the
# whole tree be bound and relabelled, which crashed system_server on device. Only single
# country files are allowed, pinned to a country-code segment.
grep -q '/my_product/etc/extension)' "$SRC" && fail 'the extension directory must not be an allowed bind target'
grep -q 'extension/\[A-Z\]\[A-Z\]\*/appfeature.country.dynamic_features.xml' "$SRC" || fail 'per-country allowlist entry missing' 
grep -q '_cr_stage_dir()' "$SRC" || fail 'directory staging missing (mount-storm fix)'
grep -q '"\$STATE_DIR/callrec_patched/"\*)' "$SRC" || fail 'payload prefix check missing'
grep -q '_cfg callrec_line)' "$SRC" || fail 'line toggle gate missing'
grep -q '_cfg callrec_apps)' "$SRC" || fail 'apps toggle gate missing'
grep -q 'nsenter -t 1 -m -- mount --bind' "$SRC" || fail 'global-namespace bind missing'
! grep -q 'mount -o remount,ro,bind' "$SRC" || fail 'remount,ro,bind crept back in (the one mount op both working references avoid)'
grep -q '_cr_dialer_stack_present()' "$SRC" || fail 'dialer-stack detection missing (diag info)'
! grep -q 'oplus_dialer_enable"' "$SRC" || fail 'dialer-enable insertions crept back in (post-boot_completed crash vector)'
! grep -q 'ASB_CALLREC_LATE' "$ROOT/service.sh" || fail 'service.sh must not late-bind the XMLs (hot-reload crash vector)'
! grep -q 'ASB_CALLREC_LATE' "$SRC" || fail 'engine must not late-bind the XMLs (hot-reload crash vector)'
grep -q 'sleep 120' "$ROOT/service.sh" || fail 'fuse stability window missing from service.sh (post-boot_completed crashes loop forever without it)'
grep -q 'ASB_CALLREC_PROC_MOUNTS:-/proc/mounts' "$SRC" || fail 'mounts table not injectable for fixtures'
grep -q 'ASB_CALLREC_LIVE_ROOT' "$SRC" || fail 'live root not injectable for fixtures'

# --- observability pins: every rejection path must name itself in the log ---
# (observed on device: toggle on, zero binds, zero log lines - an undebuggable guard)
grep -q '_CR_GUARD_WHY' "$SRC" || fail 'guard rejections carry no reason code'
grep -q 'action=callrec_apply boot=' "$SRC" || fail 'apply lifecycle log line missing'
grep -q 'action=callrec_prepare state=' "$SRC" || fail 'prepare outcome log line missing'
grep -q 'action=callrec_guard result=reject why=' "$SRC" || fail 'guard reject log line missing'
grep -q 'result=fail target=' "$SRC" || fail 'per-target bind failure log line missing'
grep -q 'result=bound target=' "$SRC" || fail 'per-target bind success log line missing (a crashing boot must name its mounts)'
! grep -q '^  *cp -a ' "$SRC" || fail 'cp -a crept back in (toybox xattr EROFS fragility)'
grep -q 'not bound:' "$ROOT/system/bin/asbdiag" || fail 'diag does not list unbound manifest entries'
grep -q 'last callrec log lines' "$ROOT/system/bin/asbdiag" || fail 'diag does not tail the callrec log'

# --- runtime fixture: mocked mount/pm/am, no real radio, package manager or mount ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mod/config" "$TMP/bin" "$TMP/state" \
         "$TMP/live/my_region/etc/extension" \
         "$TMP/live/my_stock/etc/extension" "$TMP/live/my_stock/etc/config" \
         "$TMP/live/my_product/etc/extension/RU" "$TMP/live/my_product/etc/extension/GB" \
         "$TMP/live/system_ext/etc/recording-prompt" \
         "$TMP/live/my_product/priv-app/OplusInCallUI" \
         "$TMP/user"
# The fixture device ships the OPlus dialer stack, so the dialer-enable features are
# expected in the region payload; a later case removes it and expects them gone.
printf 'apk' > "$TMP/live/my_product/priv-app/OplusInCallUI/OplusInCallUI.apk"
printf 'name=AutoSystemBoost\n' > "$TMP/mod/module.prop"

# Live feature XMLs with the region locks present, like a GLOBAL-EU build ships them.
cat > "$TMP/live/my_region/etc/extension/com.oplus.app-features.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<features>
	<extend_features>
	<app_feature name="com.android.phone.some_other_feature"/>
	<app_feature name="com.oplus.soundrecorder.no_display_record"/>
	<app_feature name="com.android.incallui.no_display_record"/>
	<app_feature name="com.android.phone.no_display_record"/>
</features>
EOF
cat > "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<features>
	<app_feature name="com.android.incallui.hide_call_record_mcc">
		<string-array name="mcc_list"><item>250</item></string-array>
	</app_feature>
	<app_feature name="com.android.incallui.support_call_record_prompt_mcc">
		<string-array name="mcc_list"><item>250</item></string-array>
	</app_feature>
	<app_feature name="com.android.incallui.unrelated_feature"/>
</features>
EOF
for cc in RU GB; do
cat > "$TMP/live/my_product/etc/extension/$cc/appfeature.country.dynamic_features.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<features>
	<app_feature name="com.android.phone.no_display_record"/>
	<app_feature name="com.android.incallui.no_display_record"/>
	<app_feature name="com.oplus.soundrecorder.no_display_record"/>
	<app_feature name="com.android.incallui.not_support_record"/>
	<app_feature name="com.android.incallui.support_record_prompt"/>
	<app_feature name="com.android.phone.keep_this_one"/>
</features>
EOF
done
cat > "$TMP/live/my_stock/etc/config/app_v2.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<config>
	<disable type="black" pkg="com.android.contacts"/>
	<disable type="black" pkg="com.android.incallui"/>
	<disable type="black" pkg="com.oplus.blacklistapp"/>
	<disable type="black" pkg="com.oplus.phonenoareainquire"/>
	<disable type="black" pkg="com.android.mms"/>
	<disable type="black" pkg="com.unrelated.app"/>
</config>
EOF
printf 'pcm-data' > "$TMP/live/system_ext/etc/recording-prompt/record_start.pcm"
printf 'pcm-data' > "$TMP/live/system_ext/etc/recording-prompt/record_stop.pcm"

# --- mocks ---
cat > "$TMP/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_CR_LOG"
EOF
cat > "$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$ASB_CR_LOG"
EOF
cat > "$TMP/bin/pm" <<'EOF'
#!/bin/sh
case "$1" in
  path)
    [ -f "$ASB_CR_VS_PRESENT" ] && { echo "package:/data/app/~~ab/com.coloros.accessibilityassistant-cd==/base.apk"; exit 0; }
    exit 1 ;;
  list)
    if [ "$2" = "packages" ]; then
      printf 'package:org.telegram.messenger\npackage:com.fake.messenger\npackage:com.whatsapp\n'
    fi ;;
  grant) exit 0 ;;
esac
exit 0
EOF
cat > "$TMP/bin/am" <<'EOF'
#!/bin/sh
# First app run is what creates the data dir on a real device.
[ "$1" = "start" ] && mkdir -p "$ASB_CALLREC_USER_DIR/com.coloros.accessibilityassistant"
exit 0
EOF
cat > "$TMP/bin/restorecon" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export ASB_CR_LOG="$TMP/mount.log"
export ASB_CALLREC_STATE_DIR="$TMP/state"
export ASB_CALLREC_PROC_MOUNTS="$TMP/mounts"
export ASB_CALLREC_LIVE_ROOT="$TMP/live"
export ASB_CALLREC_USER_DIR="$TMP/user"
export ASB_CR_VS_PRESENT="$TMP/vs.present"
: > "$TMP/mounts"

run() { MODDIR="$TMP/mod" sh "$SRC" "$@"; }
PAYROOT="$TMP/state/callrec_patched$TMP/live"

# === prepare: patch derived from the live files ===
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
run prepare
[ "$(cat "$TMP/state/callrec_line_state")" = 'ready' ] || fail 'prepare did not reach ready'
[ -f "$TMP/state/callrec_line_manifest.txt" ] || fail 'manifest not written'
# One entry per patched country file, never the extension directory as a whole.
# Binding the directory relabelled every file in it with the directory's SELinux context
# and crashed system_server on device - the bootloop fuse caught it. Each country file is
# now its own entry with its own label: RU and GB here, plus region, stock and app_v2.
# 4 entries: region, stock, RU, GB. app_v2.xml is never staged - removing its disable
# entries enabled the stock InCallUI and Contacts at boot and bootlooped the device.
[ "$(grep -c . "$TMP/state/callrec_line_manifest.txt")" = "4" ] || fail 'expected 4 manifest entries (region, stock, RU, GB)'
grep -q 'app_v2.xml|' "$TMP/state/callrec_line_manifest.txt" && fail 'app_v2.xml must never be bound - it enables the stock dialer' 
grep -q '/extension|' "$TMP/state/callrec_line_manifest.txt" && fail 'the extension directory must never be bound as a whole' 

R_PAY="$PAYROOT/my_region/etc/extension/com.oplus.app-features.xml"
# The patch is REMOVALS ONLY: the dialer-enable insertions activated OPlus dialer
# code paths inside system_server that stock EU APKs do not ship - the observed
# post-boot_completed crash. They must never come back, dialer stack or not.
! grep -q 'oplus_dialer_enable' "$R_PAY" || fail 'dialer-enable feature inserted (post-boot_completed crash vector)'
! grep -q 'no_display_record' "$R_PAY" || fail 'region no_display_record locks not removed'
grep -q 'some_other_feature' "$R_PAY" || fail 'unrelated region feature lost'

S_PAY="$PAYROOT/my_stock/etc/extension/com.oplus.app-features.xml"
! grep -q 'hide_call_record_mcc' "$S_PAY" || fail 'MCC hide block not removed'
! grep -q 'support_call_record_prompt_mcc' "$S_PAY" || fail 'MCC prompt block not removed'
grep -q 'unrelated_feature' "$S_PAY" || fail 'unrelated stock feature lost'

C_PAY="$PAYROOT/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml"
! grep -q 'no_display_record\|not_support_record\|support_record_prompt' "$C_PAY" || fail 'country locks not removed'
grep -q 'keep_this_one' "$C_PAY" || fail 'unrelated country feature lost'

# app_v2.xml is never staged, so no payload may exist for it at all.
V_PAY="$PAYROOT/my_stock/etc/config/app_v2.xml"
[ ! -e "$V_PAY" ] || fail 'app_v2.xml payload was staged - it enables the stock dialer at boot'

# Stock files untouched: only payloads carry the patch.
grep -q 'no_display_record' "$TMP/live/my_region/etc/extension/com.oplus.app-features.xml" || fail 'live region file was modified'

# Idempotence: a second prepare yields the same manifest.
sha1sum "$TMP/state/callrec_line_manifest.txt" > "$TMP/man.sha"
run prepare
sha1sum -c "$TMP/man.sha" >/dev/null || fail 'second prepare changed the manifest (not idempotent)'

# Prepare is a full rebuild: a payload planted by hand must not survive it.
mkdir -p "$TMP/state/callrec_patched/stale"
printf 'stale' > "$TMP/state/callrec_patched/stale/leftover"
run prepare
[ ! -e "$TMP/state/callrec_patched/stale" ] || fail 'prepare kept a stale payload'

# OTA simulation: the OEM rewrites a country file (new content AND the lock back) -
# the next prepare must re-derive from THAT file, not replay the old payload.
cat > "$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<features>
	<app_feature name="com.android.phone.no_display_record"/>
	<app_feature name="com.android.phone.brand_new_ota_feature"/>
</features>
EOF
run prepare
grep -q 'brand_new_ota_feature' "$C_PAY" || fail 'OTA content not picked up on re-prepare'
! grep -q 'no_display_record' "$C_PAY" || fail 'OTA lock not re-removed on re-prepare'

# Unterminated MCC block: a block whose closing tag never comes must NOT become a
# truncated payload. The bounded block-delete keeps the file byte-identical, cmp
# rejects it, and the stock file simply leaves the manifest.
cp "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml" "$TMP/stock.good"
cat > "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<features>
	<app_feature name="com.android.incallui.hide_call_record_mcc">
		<string-array name="mcc_list"><item>250</item></string-array>
	<app_feature name="com.android.incallui.unrelated_feature"/>
</features>
EOF
cp "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml" "$TMP/stock.unterm"
run prepare
! grep -q 'my_stock/etc/extension' "$TMP/state/callrec_line_manifest.txt" || fail 'unterminated MCC block produced a payload'
grep -q 'my_region/etc/extension' "$TMP/state/callrec_line_manifest.txt" || fail 'sibling entries lost over the unterminated block'
cmp -s "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml" "$TMP/stock.unterm" || fail 'live stock file was modified by prepare'
cp "$TMP/stock.good" "$TMP/live/my_stock/etc/extension/com.oplus.app-features.xml"
run prepare

# The dialer-stack detection is informational only: with or without the stack, the
# payload is identical removals-only content (the detection result is still recorded
# for diag and the prepare log).
mv "$TMP/live/my_product/priv-app" "$TMP/privapp.saved"
run prepare
[ "$(cat "$TMP/state/callrec_dialer_stack")" = 'absent' ] || fail 'dialer stack absence not recorded'
! grep -q 'oplus_dialer_enable' "$R_PAY" || fail 'dialer-enable inserted without a dialer stack'
! grep -q 'no_display_record' "$R_PAY" || fail 'lock removals must still apply without a dialer'
grep -q 'some_other_feature' "$R_PAY" || fail 'unrelated region feature lost'
mv "$TMP/privapp.saved" "$TMP/live/my_product/priv-app"
run prepare
[ "$(cat "$TMP/state/callrec_dialer_stack")" = 'present' ] || fail 'dialer stack presence not recorded'
! grep -q 'oplus_dialer_enable' "$R_PAY" || fail 'dialer-enable inserted with the stack present'

# _cr_xml_sane unit: valid passes, truncated and trailing-garbage fail closed.
sed -n '/^_cr_xml_sane()/,/^}/p' "$SRC" > "$TMP/sane.sh"
( . "$TMP/sane.sh"
  printf '<features>\n<a/>\n</features>\n' > "$TMP/ok.xml"
  _cr_xml_sane "$TMP/ok.xml" ) || fail 'xml_sane rejected a valid file'
( . "$TMP/sane.sh"
  printf '<features>\n<a/>\n' > "$TMP/bad.xml"
  ! _cr_xml_sane "$TMP/bad.xml" ) || fail 'xml_sane accepted a truncated file'
( . "$TMP/sane.sh"
  printf '<features>\n<a/>\n</features>\n<extra/>\n' > "$TMP/trail.xml"
  ! _cr_xml_sane "$TMP/trail.xml" ) || fail 'xml_sane accepted content after the root close'
# A trailing OEM comment after the root close is legal and must pass.
( . "$TMP/sane.sh"
  printf '<features>\n<a/>\n</features>\n<!-- oem trailing comment -->\n' > "$TMP/cmt.xml"
  _cr_xml_sane "$TMP/cmt.xml" ) || fail 'xml_sane rejected a trailing OEM comment'

# === apply: toggle gating, binds, prompt silence, staging ===
: > "$ASB_CR_LOG"
run apply
[ ! -s "$ASB_CR_LOG" ] || fail 'mounted while both toggles were off'

# Live (WebUI) apply: NOTHING may be mounted on a running system.
#
# The XML binds were already excluded here. The prompt silence was allowed to stay live
# on the reasoning that it is "just an audio asset" - but it is still a bind mount, made
# with nsenter into init's namespace while audio and telecom are running, and that is
# what the field failure hit: seconds after the toggle the device froze, the screen went
# off and it hard-rebooted. The asset being harmless does not make the mount harmless.
#
# Both mounts now happen at post-fs-data only, which is also the only time the feature
# XMLs are read. The card is reboot-to-apply either way.
printf 'callrec_line=1\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
: > "$ASB_CR_LOG"
run apply
! grep -q -- "--bind $TMP/state/callrec_patched" "$ASB_CR_LOG" || fail 'live apply bound XML payloads - reboot-to-apply contract broken'
[ ! -f "$TMP/state/callrec_line.active" ] || fail 'live apply marked the line active without binding'
! grep -q -- "--bind $TMP/state/callrec_empty.pcm" "$ASB_CR_LOG" || fail 'live apply mounted the prompt silence - must be boot-only'
out="$(run status)"
echo "$out" | grep -q '^line=pending_boot' || fail 'live apply should report line=pending_boot'

# A plain late/live apply still must not bind: XML binds are an EARLY-BOOT act only.
# The module ships no my_* dirs, so magic mount never shadows the early binds and no
# late rebind exists - rebinding at late_start hot-swaps configs under a running
# system_server, which is the exact crash vector this tweak had.
run apply
! grep -q -- "--bind $TMP/state/callrec_patched" "$ASB_CR_LOG" || fail 'late/live apply bound XML payloads'

# The post-fs-data pass (ASB_CALLREC_BOOT=1) is the only one that binds the XMLs -
# and it binds BOTH the XMLs and the prompt silence: every mount this feature makes now
# belongs in the boot window, because a bind on a running system is what froze a device
# in the field.
: > "$TMP/mounts"
: > "$ASB_CR_LOG"
rm -f "$TMP/state/callrec_prompt.active"   # isolate: earlier live applies asserted it
ASB_CALLREC_BOOT=1 run apply
grep -q -- "--bind $R_PAY $TMP/live/my_region/etc/extension/com.oplus.app-features.xml" "$ASB_CR_LOG" || fail 'region XML not bound at boot'
# Each country file is bound on its own; the directory never is.
for _cc in RU GB; do
  _cf="my_product/etc/extension/$_cc/appfeature.country.dynamic_features.xml"
  grep -q -- "--bind $TMP/state/callrec_patched$TMP/live/$_cf $TMP/live/$_cf" "$ASB_CR_LOG" \
    || fail "country file $_cc not bound at boot"
done
grep -q -- " $TMP/live/my_product/etc/extension\$" "$ASB_CR_LOG" && fail 'the extension directory was bound whole'
grep -q -- "--bind $TMP/state/callrec_empty.pcm" "$ASB_CR_LOG" || fail 'prompt silence not mounted at boot - it is boot-only now'
[ -f "$TMP/state/callrec_line.active" ] || fail 'line active marker not written'
[ -f "$TMP/state/callrec_prompt.active" ] || fail 'prompt marker not written at post-fs-data'
[ -f "$TMP/state/callrec_boot_pending" ] || fail 'boot apply did not drop the trial marker'
# The late pass (plain apply, runtime already up) asserts the silence instead.
run apply
grep -q -- "--bind $TMP/state/callrec_empty.pcm $TMP/live/system_ext/etc/recording-prompt/record_start.pcm" "$ASB_CR_LOG" || fail 'late pass did not assert the prompt silence'
: # the boot pass owns the prompt marker now
run confirm
[ ! -f "$TMP/state/callrec_boot_pending" ] || fail 'confirm did not retire the trial marker'
# Patch-only: the module's magic-mountable tree must stay untouched.
[ ! -e "$TMP/mod/system" ] || fail 'module system/ tree was touched - patch-only contract broken'

# An already-bound target is never stacked with a second bind. Checked on a country
# file now, since the directory is no longer a target at all.
: > "$TMP/mounts"
printf '%s %s f2fs rw 0 0\n' "$TMP/state/callrec_patched$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml" "$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml" > "$TMP/mounts"
# A real bind makes the live path READ as the payload; the fake mount table alone does
# not, so mirror that here or _bind_one's content check cannot see the bind.
cp -f "$TMP/state/callrec_patched$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml" "$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml"
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
! grep -q -- "--bind $TMP/state/callrec_patched$TMP/live/my_product/etc/extension/RU/appfeature.country.dynamic_features.xml " "$ASB_CR_LOG" || fail 'an already-bound country file was stacked'
grep -q -- "--bind $R_PAY" "$ASB_CR_LOG" || fail 'fresh file bind missing'
run confirm
: > "$TMP/mounts"

# A late/live apply with the toggle ON must NEVER unbind what the boot pass mounted
# (the regression: the removal branch fired on every non-boot apply and tore the
# fresh boot binds down at late_start - toggle on, zero binds, zero log lines).
printf '%s %s f2fs rw 0 0\n' "$R_PAY" "$TMP/live/my_region/etc/extension/com.oplus.app-features.xml" > "$TMP/mounts"
[ -f "$TMP/state/callrec_line.active" ] || fail 'setup: line active marker missing'
: > "$ASB_CR_LOG"
run apply
! grep -q 'umount' "$ASB_CR_LOG" || fail 'late apply with toggle ON unbound the boot binds'
[ -f "$TMP/state/callrec_line.active" ] || fail 'late apply with toggle ON dropped the active marker'
# ...and every apply leaves its lifecycle trace in the log.
grep -q 'action=callrec_apply boot=0 line=1 apps=0 blocked=0' "$TMP/state/vendor_mounts.log" || fail 'apply lifecycle line not logged'
grep -q 'action=callrec_prepare state=ready' "$TMP/state/vendor_mounts.log" || fail 'prepare outcome line not logged'
: > "$TMP/mounts"

# Toggle off: binds and silence removed, staging pulled back.
printf '%s %s f2fs rw 0 0\n' "$R_PAY" "$TMP/live/my_region/etc/extension/com.oplus.app-features.xml" > "$TMP/mounts"
printf '%s %s f2fs rw 0 0\n' "$TMP/state/callrec_empty.pcm" "$TMP/live/system_ext/etc/recording-prompt/record_start.pcm" >> "$TMP/mounts"
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
: > "$ASB_CR_LOG"
run apply
grep -q "umount $TMP/live/my_region/etc/extension/com.oplus.app-features.xml" "$ASB_CR_LOG" || fail 'toggle-off did not unbind the XML'
grep -q "umount $TMP/live/system_ext/etc/recording-prompt/record_start.pcm" "$ASB_CR_LOG" || fail 'toggle-off did not restore the prompt'
[ ! -e "$TMP/mod/system" ] || fail 'module system/ tree appeared after toggle-off'

# === one-strike bootloop fuse ===
# A boot apply drops the trial marker BEFORE mounting; confirm retires it; a boot
# that finds its own marker still pending tears everything out and blocks the tweak.
printf 'callrec_line=1\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
: > "$TMP/mounts"   # fresh boot: nothing is bound yet
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
[ -f "$TMP/state/callrec_boot_pending" ] || fail 'boot apply did not drop the trial marker'
grep -q -- "--bind $R_PAY" "$ASB_CR_LOG" || fail 'boot apply did not bind on a fresh trial'
run confirm
[ ! -f "$TMP/state/callrec_boot_pending" ] || fail 'confirm did not retire the trial marker'

# Next boot: fresh trial again, marker down, binds on. Then the boot "dies" (no
# confirm) and the following boot must lock down instead of binding again.
: > "$TMP/mounts"
ASB_CALLREC_BOOT=1 run apply
[ -f "$TMP/state/callrec_boot_pending" ] || fail 'second boot did not re-arm the trial marker'
: > "$TMP/mounts"   # the failed boot: nothing survived, marker still down
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
! grep -q -- '--bind' "$ASB_CR_LOG" || fail 'fuse tripped but binds still landed'
[ -f "$TMP/state/callrec_blocked" ] || fail 'fuse did not write callrec_blocked'
[ "$(cat "$TMP/state/callrec_line_state")" = 'blocked_bootloop' ] || fail 'lockdown state not recorded'
[ ! -f "$TMP/state/callrec_line_manifest.txt" ] || fail 'lockdown left the manifest behind'
[ ! -d "$TMP/state/callrec_patched" ] || fail 'lockdown left the payloads behind'
out="$(run status)"
echo "$out" | grep -q '^line=blocked' || fail 'status does not report line=blocked'

# While blocked, further boots stay inert; only the user switching the toggle off
# re-arms the guard for a fresh trial.
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
! grep -q -- '--bind' "$ASB_CR_LOG" || fail 'blocked tweak bound again'
[ -f "$TMP/state/callrec_blocked" ] || fail 'block cleared itself without the user'
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -f "$TMP/state/callrec_blocked" ] || fail 'toggle-off did not re-arm the fuse'
[ ! -f "$TMP/state/callrec_boot_pending" ] || fail 'toggle-off left a stale trial marker'
: > "$TMP/mounts"
printf 'callrec_line=1\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
grep -q -- "--bind $R_PAY" "$ASB_CR_LOG" || fail 're-armed trial did not bind'
[ -f "$TMP/state/callrec_boot_pending" ] || fail 're-armed trial did not drop the marker'
# Back to a clean slate for the sections below.
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
run apply
run confirm
: > "$TMP/mounts"
: > "$ASB_CR_LOG"

# The APPS toggle alone mounts NOTHING at boot: the prompt silence moved to the
# late pass, so an apps-only boot apply drops no trial marker. It does silence the
# prompts, because that mount is boot-only for both toggles now; the fuse still only
# covers the line toggle's XML binds, which are the ones that can wedge a boot.
printf 'callrec_line=0\ncallrec_apps=1\n' > "$TMP/mod/config/governor.conf"
: > "$ASB_CR_LOG"
ASB_CALLREC_BOOT=1 run apply
[ ! -f "$TMP/state/callrec_boot_pending" ] || fail 'apps-only boot apply dropped a trial marker (nothing to fuse)'
! grep -q -- "--bind $TMP/state/callrec_patched" "$ASB_CR_LOG" || fail 'apps-only boot apply bound XML payloads'
: > "$ASB_CR_LOG"   # isolate the late pass from the boot pass above
run apply
! grep -q -- "--bind $TMP/state/callrec_empty.pcm" "$ASB_CR_LOG" || fail 'apps-only late pass mounted prompts - boot-only now'
# Back to a clean slate for the sections below.
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
run apply
run confirm
: > "$TMP/mounts"
: > "$ASB_CR_LOG"

# === fail-closed guards ===
# apply re-derives the manifest on every run (that is the OTA-proofing), so a hostile
# manifest cannot be planted through apply itself - the guard is what stands between a
# bad manifest and a mount. Exercise the REAL guard function against hostile input.
sed -n '/^_cr_xml_sane()/,/^}/p; /^_cr_target_allowed()/,/^}/p; /^_cr_guard()/,/^}/p' "$SRC" > "$TMP/guard.sh"
guard_ok() {
  ( STATE_DIR="$TMP/state" MAN="$TMP/state/callrec_line_manifest.txt" LIVE_ROOT="$TMP/live"
    . "$TMP/guard.sh"; _cr_guard )
}
guard_why() {
  ( STATE_DIR="$TMP/state" MAN="$TMP/state/callrec_line_manifest.txt" LIVE_ROOT="$TMP/live"
    . "$TMP/guard.sh"; _cr_guard; printf '%s' "$_CR_GUARD_WHY" )
}
MANF="$TMP/state/callrec_line_manifest.txt"
guard_ok || fail 'guard rejected the valid manifest'
[ "$(guard_why)" = 'ok' ] || fail 'guard did not report ok on the valid manifest'
cp "$MANF" "$TMP/man.good"
printf '%s|%s|extra\n' "$TMP/live/x" "$TMP/state/callrec_patched/x" > "$MANF"
guard_ok && fail 'guard accepted a malformed manifest'
[ "$(guard_why)" = "malformed:$TMP/live/x" ] || fail 'guard did not name the malformed entry'
printf '%s|%s\n' "$TMP/live/x" "/etc/passwd" > "$MANF"
guard_ok && fail 'guard accepted an out-of-bounds payload'
case "$(guard_why)" in target_not_allowed:*) ;; *) fail 'guard did not name the out-of-bounds target' ;; esac
printf '%s|%s\n' "/system/etc/hosts" "$R_PAY" > "$MANF"
guard_ok && fail 'guard accepted an out-of-allowlist target'
[ "$(guard_why)" = 'target_not_allowed:/system/etc/hosts' ] || fail 'guard did not name the rejected target'
printf '%s|%s\n' "$TMP/live/my_region/etc/extension/com.oplus.app-features.xml" "$TMP/state/elsewhere.xml" > "$MANF"
printf '<x/>\n' > "$TMP/state/elsewhere.xml"
guard_ok && fail 'guard accepted a payload outside callrec_patched/'
case "$(guard_why)" in payload_out_of_bounds:*) ;; *) fail 'guard did not name the out-of-bounds payload' ;; esac
rm -f "$MANF"
guard_ok && fail 'guard accepted a missing manifest'
[ "$(guard_why)" = 'no_manifest' ] || fail 'guard did not report no_manifest'
: > "$MANF"
guard_ok && fail 'guard accepted an empty manifest'
[ "$(guard_why)" = 'empty_manifest' ] || fail 'guard did not report empty_manifest'
cp "$TMP/man.good" "$MANF"
guard_ok || fail 'guard rejected the restored valid manifest'

# === messenger half: in-place patch of the device-shipped VoiceScribe prefs ===
# Package absent: honestly unsupported, nothing created, nothing installed.
printf 'callrec_line=0\ncallrec_apps=1\n' > "$TMP/mod/config/governor.conf"
rm -f "$ASB_CR_VS_PRESENT"
run apply
[ "$(cat "$TMP/state/callrec_apps_state")" = 'unsupported' ] || fail 'missing VoiceScribe package not reported unsupported'
[ ! -e "$TMP/user/com.coloros.accessibilityassistant" ] || fail 'prefs created for a package that is not installed'

# Package present: prefs generated, both switches on, known + installed messengers merged.
: > "$ASB_CR_VS_PRESENT"
run apply
[ "$(cat "$TMP/state/callrec_apps_state")" = 'applied' ] || fail 'apps apply did not reach applied'
PREFS="$TMP/user/com.coloros.accessibilityassistant/shared_prefs/translatePreferences.xml"
[ -f "$PREFS" ] || fail 'prefs not written'
python3 - "$PREFS" <<'PY' || fail 'prefs XML invalid or content wrong'
import sys, json, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
m = {e.get('name'): e for e in t}
assert m['auto_record_switch_status'].get('value') == 'true', 'auto record switch not on'
assert m['auto_smart_voice_switch_status'].get('value') == 'true', 'smart voice switch not on'
for k in ('support_apps_auto_record', 'support_apps_smart_voice'):
    pkgs = [e['pkgName'] for e in json.loads(m[k].text)]
    assert 'org.telegram.messenger' in pkgs, f'{k}: known messenger missing'
    assert 'com.fake.messenger' in pkgs, f'{k}: installed messenger not merged in'
    assert len(pkgs) == len(set(pkgs)), f'{k}: duplicate entries'
PY
[ -f "$TMP/state/callrec_apps.active" ] || fail 'apps active marker not written'

# In-place merge: pre-existing prefs carrying the app's own custom keys must survive
# the patch - only the two switches and the two app lists are touched.
cat > "$PREFS" <<'EOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="user_custom_theme" value="true" />
    <string name="user_custom_note">keep me</string>
    <boolean name="auto_record_switch_status" value="false" />
    <string name="support_apps_auto_record">[{"isBlacklist":false,"isChecked":false,"isInstall":false,"pkgName":"com.stale.app"}]</string>
</map>
EOF
run apply
python3 - "$PREFS" <<'PY' || fail 'in-place merge broke existing prefs'
import sys, json, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
m = {e.get('name'): e for e in t}
assert m['user_custom_theme'].get('value') == 'true', 'custom boolean lost'
assert m['user_custom_note'].text == 'keep me', 'custom string lost'
assert m['auto_record_switch_status'].get('value') == 'true', 'switch not flipped on'
pkgs = [e['pkgName'] for e in json.loads(m['support_apps_auto_record'].text)]
assert 'com.stale.app' not in pkgs, 'stale list entry not replaced'
assert 'org.telegram.messenger' in pkgs, 'merged list missing known messenger'
assert 'com.fake.messenger' in pkgs, 'merged list missing installed messenger'
PY
[ -f "$PREFS.asb.bak" ] || fail 'one-time prefs backup not taken'

# Toggle off: switch flipped back, every other key still preserved, marker cleared.
printf 'callrec_line=0\ncallrec_apps=0\n' > "$TMP/mod/config/governor.conf"
run apply
python3 - "$PREFS" <<'PY' || fail 'toggle-off broke prefs'
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
m = {e.get('name'): e for e in t}
assert m['auto_record_switch_status'].get('value') == 'false', 'switch not flipped off'
assert m['user_custom_theme'].get('value') == 'true', 'custom key lost on toggle-off'
assert m['user_custom_note'].text == 'keep me', 'custom string lost on toggle-off'
PY
[ ! -f "$TMP/state/callrec_apps.active" ] || fail 'apps active marker not cleared'

# status vocabulary stays stable for the WebUI/diag readers.
out="$(run status)"
echo "$out" | grep -q '^line=off' || fail 'status line=off vocabulary changed'
echo "$out" | grep -q '^apps=off' || fail 'status apps=off vocabulary changed'
printf 'callrec_line=1\ncallrec_apps=1\n' > "$TMP/mod/config/governor.conf"
rm -f "$TMP/state/callrec_line.active" "$TMP/state/callrec_apps.active"
out="$(run status)"
echo "$out" | grep -q '^line=pending_boot' || fail 'status line=pending_boot vocabulary changed'
echo "$out" | grep -q '^apps=pending' || fail 'status apps=pending vocabulary changed'

# --- unsupported device: no OPlus feature XMLs at all ---
rm -rf "$TMP/live" "$TMP/state"
mkdir -p "$TMP/live" "$TMP/state"
: > "$TMP/mounts"
run prepare
[ "$(cat "$TMP/state/callrec_line_state")" = 'unsupported' ] || fail 'device without feature XMLs not reported unsupported'
[ ! -f "$TMP/state/callrec_line_manifest.txt" ] || fail 'unsupported device still wrote a manifest'

# Microphone/storage grants given to VoiceScribe must be taken back on off and uninstall,
# and only the ones this module actually granted.
_CR="$ROOT/runtime/asb_callrec.sh"
[ -n "${ROOT:-}" ] || _CR="$(dirname "$0")/../runtime/asb_callrec.sh"
grep -q '^_cr_grant_tracked() {' "$_CR"  || fail "tracked grant helper missing"
grep -q '^_cr_revoke_tracked() {' "$_CR" || fail "tracked revoke helper missing"
[ "$(grep -c '^ *_cr_revoke_tracked$' "$_CR")" -ge 2 ] || fail "revoke not wired into both off and uninstall paths"
grep -q 'granted=true' "$_CR" || fail "grant helper no longer checks prior state - would revoke user grants"
[ "$(grep -c 'pm grant' "$_CR")" -le 1 ] || fail "untracked pm grant reintroduced"

echo 'PASS: call-recording contract'
