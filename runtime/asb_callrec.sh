#!/system/bin/sh
# Call-recording runtime owner: two independent, default-off WebUI tweaks.
#
#   callrec_line=1  - native line call recording on OPlus dialer stacks where the OEM
#                     region-hides it. The patch is derived from THIS device's own
#                     feature XMLs at every boot (prepare), never shipped as a static
#                     file: an OTA that rewrites /my_region, /my_product or /my_stock
#                     just gets re-patched on the next boot from whatever the OEM
#                     actually installed. Patched copies are bind-mounted over the
#                     stock files; stock is never written. Real devices carry ~80
#                     country XMLs under /my_product/etc/extension (observed: an
#                     82-entry manifest) - binding each file separately is a mount
#                     storm in init's namespace at post-fs-data, so the country half
#                     is staged as ONE full directory copy and bound as a single
#                     directory mount. Four to five mounts total, not 164.
#   callrec_apps=1  - call recording inside messengers (Telegram/WhatsApp/VK/...),
#                     by patching the auto-record shared_prefs of the VoiceScribe
#                     package the device ALREADY ships (com.coloros.accessibility-
#                     assistant). Nothing is installed: the two switch keys are flipped
#                     and the two app lists are rewritten in place, preserving every
#                     other key the app or the user set, and the lists merge the known
#                     messenger set with whatever messenger is actually installed - so
#                     a messenger added later is picked up on the next boot, and an app
#                     update that resets the keys is healed the same way. A device
#                     without the package is honestly reported as unsupported.
#
# No APK is bundled or installed by either tweak: everything above is a patch of
# files the device already carries. Both toggles also silence the in-call recording
# announcement by binding an empty file over /system_ext/etc/recording-prompt/*.pcm -
# a bind, not a delete, so stock sounds are one umount away.
#
# Fail-closed throughout: a malformed manifest, an out-of-allowlist target, an
# out-of-bounds payload or a structurally broken XML must never become a mount.
# Same contract as the LTPO and mmfeed bind owners.
#
# Bootloop fuse, OWN and independent (one strike): post-fs-data invokes apply with
# ASB_CALLREC_BOOT=1. Before the first mount of a boot the apply drops a pending
# marker; service.sh retires it (confirm) only 120s AFTER sys.boot_completed=1 -
# the stability window. A boot that finds its own marker still pending means the
# previous boot with these binds did not survive the window - the patch is the
# prime suspect, so everything is unbound, the payloads are deleted and
# callrec_blocked stays down until the user re-arms by switching the toggle off
# and on again. The window matters: this tweak's observed failure shape was a
# crash AFTER boot_completed (screen dies, reboot, repeat), which a plain
# boot_completed confirm can never catch - every boot "completed", retired the
# marker and bound again. Worst case now is ONE bad boot, never a loop. This fuse
# does NOT rely on the vendor overlay counter: that one only ticks when the
# VENDOR_OVERLAY feature gate passes, and a callrec-only device would otherwise
# re-bind the same files forever.
#
# Three timing/content rules make the fuse almost never needed:
#   - The XML binds land ONLY in post-fs-data (ASB_CALLREC_BOOT=1), while zygote and
#     system_server are not running yet. NEVER in the late pass and NEVER live: a
#     feature XML swapped under a RUNNING system is hot-reloaded by OPlus services
#     and crashes them on the spot (observed twice: screen dies at the toggle, and
#     a bootloop when the late pass re-bound at late_start). The module ships no
#     my_*/system_ext dirs, so magic mount never shadows these binds - no late
#     rebind is needed at all. Toggle OFF still unbinds live.
#   - The patch is REMOVALS ONLY. The oplus_dialer_enable feature insertions were
#     dropped: they switch phone/telecom (telecom runs INSIDE system_server) onto
#     OPlus dialer code paths that the or965-style modules can only afford because
#     they ALSO ship patched InCallUI/Contacts/Mms APKs. Patch-only on stock EU
#     APKs, those flags activate paths that are not fully there and the boot dies
#     after boot_completed - the persistent-bootloop mechanism. Removing a lock row
#     activates nothing and crashes nothing.
#   - The prompt-silence binds stay OUT of the boot window entirely: the prompt
#     .pcm files are read lazily when a recording starts, so the late pass asserts
#     the silence on the running system. The only mounts ever made at post-fs-data
#     are the feature-XML binds, with the plain nsenter bind the LTPO/mmfeed owners
#     use (no remount,ro,bind - the one operation both working references avoid).
#
# The fuse covers EVERYTHING this script can mount at boot - the XML binds AND the
# prompt-silence binds, for EITHER toggle: the pending marker is dropped before the
# first mount of a boot whenever a bind-owning toggle is on, so a boot killed by
# any of these mounts locks the whole tweak down on the next one. Re-arming takes
# both toggles off, so a half-off state cannot silently reset the guard.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" "/data/adb/modules/$MODID" "/data/adb/modules_update/$MODID"; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done

# Injectable roots for host-side fixtures, same pattern as the LTPO/mmfeed owners.
# On a device ASB_CALLREC_LIVE_ROOT is empty and the targets are the real partition
# paths; a fixture relocates the whole live tree under its sandbox.
STATE_DIR="${ASB_CALLREC_STATE_DIR:-/data/adb/asb}"
LIVE_ROOT="${ASB_CALLREC_LIVE_ROOT:-}"
PROC_MOUNTS="${ASB_CALLREC_PROC_MOUNTS:-/proc/mounts}"
MAN="$STATE_DIR/callrec_line_manifest.txt"
ACTIVE="$STATE_DIR/callrec_line.active"
PROMPT_ACTIVE="$STATE_DIR/callrec_prompt.active"
APPS_ACTIVE="$STATE_DIR/callrec_apps.active"
LINE_STATE="$STATE_DIR/callrec_line_state"
APPS_STATE="$STATE_DIR/callrec_apps_state"
BLOCK="$STATE_DIR/vendor_overlay_blocked"
CR_BLOCK="$STATE_DIR/callrec_blocked"
PENDING="$STATE_DIR/callrec_boot_pending"
MOUNTS_LOG="$STATE_DIR/vendor_mounts.log"
CONF="$MODDIR/config/governor.conf"
VS_PKG="com.coloros.accessibilityassistant"

_cfg() {
  [ -f "$CONF" ] || return 0
  _v="$(grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r')"
  printf '%s' "$_v"
}

_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "ts=$(date +%s 2>/dev/null || echo 0) $*" >> "$MOUNTS_LOG" 2>/dev/null
}

# --- prepare: derive the line patch from the CURRENT live files -------------------
# Every patcher copies the live file and edits the copy; a rule that matches nothing
# changes nothing, and a file the OEM already ships open produces a payload identical
# to the live file, which never enters the manifest (binding it would be a no-op
# mount). _cr_changed counts real edits across all targets.

_cr_n=0
_CR_DIALER=0

# Detects whether the device physically ships the OPlus dialer stack. Since V65-52
# this is INFORMATIONAL ONLY (diag prints it): the dialer-enable feature flags are
# no longer inserted anywhere (see _cr_patch_appfeatures_region), so nothing gates
# on the answer. Globs stay OPlus-flavored on purpose: a Google or AOSP dialer must
# not count as the OPlus stack.
_cr_dialer_stack_present() {
  for _d in "$LIVE_ROOT"/my_product/priv-app "$LIVE_ROOT"/my_product/app \
            "$LIVE_ROOT"/my_stock/priv-app "$LIVE_ROOT"/my_stock/app \
            "$LIVE_ROOT"/my_region/priv-app "$LIVE_ROOT"/my_region/app \
            "$LIVE_ROOT"/my_company/priv-app "$LIVE_ROOT"/my_company/app \
            "$LIVE_ROOT"/system_ext/priv-app "$LIVE_ROOT"/system_ext/app \
            "$LIVE_ROOT"/product/priv-app "$LIVE_ROOT"/product/app \
            "$LIVE_ROOT"/system/priv-app "$LIVE_ROOT"/system/app; do
    [ -d "$_d" ] || continue
    for _p in "$_d"/*[Ii]n[Cc]all[Uu][Ii]* \
              "$_d"/[Oo][Pp]*[Dd]ialer* \
              "$_d"/[Oo][Pp]*[Cc]ontacts* \
              "$_d"/[Cc]olor[Oo][Ss]*[Dd]ialer*; do
      [ -e "$_p" ] && return 0
    done
  done
  return 1
}

# /my_region/etc/extension/com.oplus.app-features.xml: the dialer feature gates.
_cr_patch_appfeatures_region() {
  _p="$1"
  grep -q 'name="com.oplus.soundrecorder.no_display_record"' "$_p" 2>/dev/null && {
    sed -i '/<app_feature name="com.oplus.soundrecorder.no_display_record"[^>]*\/>/d' "$_p" 2>/dev/null && _cr_n=$((_cr_n + 1)); }
  grep -q 'name="com.android.incallui.no_display_record"' "$_p" 2>/dev/null && {
    sed -i '/<app_feature name="com.android.incallui.no_display_record"[^>]*\/>/d' "$_p" 2>/dev/null && _cr_n=$((_cr_n + 1)); }
  grep -q 'name="com.android.phone.no_display_record"' "$_p" 2>/dev/null && {
    sed -i '/<app_feature name="com.android.phone.no_display_record"[^>]*\/>/d' "$_p" 2>/dev/null && _cr_n=$((_cr_n + 1)); }
  # NO feature insertions here, on purpose. The or965-style modules add
  # com.android.phone/com.android.server.telecom oplus_dialer_enable flags, but those
  # modules also SHIP patched InCallUI/Contacts/Mms APKs that implement the OPlus
  # dialer paths the flags switch on. We are patch-only: on a GLOBAL-EU build with
  # stock EU APKs the flags activate code paths that are not fully there, telecom
  # runs INSIDE system_server, and the boot dies after boot_completed - the observed
  # persistent bootloop (screen dies, reboot, repeat). Region-lock REMOVALS are
  # inert: they unhide a record entry and crash nothing.
}

# /my_product/etc/extension/<CC>/appfeature.country.dynamic_features.xml: the five
# region locks (record hidden, record unsupported, prompt mandated).
_cr_patch_country() {
  _p="$1"
  for _f in com.android.phone.no_display_record \
            com.android.incallui.no_display_record \
            com.oplus.soundrecorder.no_display_record \
            com.android.incallui.not_support_record \
            com.android.incallui.support_record_prompt; do
    grep -q "name=\"$_f\"" "$_p" 2>/dev/null || continue
    sed -i "/<app_feature name=\"$_f\"[^>]*\/>/d" "$_p" 2>/dev/null && _cr_n=$((_cr_n + 1))
  done
}

# app_v2.xml (my_stock/my_region config): package-level <disable> rows.
_cr_patch_appv2() {
  _p="$1"
  for _pkg in com.android.contacts com.android.incallui com.oplus.blacklistapp \
              com.oplus.phonenoareainquire com.android.mms; do
    grep -q "<disable[^>]*pkg=\"$_pkg\"" "$_p" 2>/dev/null || continue
    sed -i "/<disable[^>]*pkg=\"$_pkg\"[^>]*\/>/d" "$_p" 2>/dev/null && _cr_n=$((_cr_n + 1))
  done
}

# Structural well-formedness, fail-closed and toybox-safe: the root tag must open and
# close, the closing root must be the LAST tag of the document (a truncation never
# ends that way), and root open/close counts must match (a range-delete that ran to
# EOF breaks exactly this). grep -c '</' alone passed a file beheaded by a bad block
# delete - that is how a truncated XML could have reached a bind target.
_cr_xml_sane() {
  _x_f="$1"
  [ -s "$_x_f" ] || return 1
  grep -q '</' "$_x_f" 2>/dev/null || return 1
  _x_root="$(awk '
    /^[[:space:]]*<\?/ { next }
    /^[[:space:]]*<!--/ { next }
    match($0, /<[A-Za-z_][A-Za-z0-9_.-]*/) { print substr($0, RSTART + 1, RLENGTH - 1); exit }
  ' "$_x_f" 2>/dev/null)"
  [ -n "$_x_root" ] || return 1
  # The closing root must be the last TAG of the document: only blank lines or
  # trailing OEM comments may follow it (a truncation never ends that way).
  _x_close="$(awk -v r="</$_x_root>" 'index($0, r) { last = NR } END { print last + 0 }' "$_x_f" 2>/dev/null)"
  [ "$_x_close" -gt 0 ] || return 1
  _x_tail="$(awk -v n="$_x_close" 'NR > n && NF && $0 !~ /^[[:space:]]*<!--/ { bad = 1 } END { print bad + 0 }' "$_x_f" 2>/dev/null)"
  [ "$_x_tail" = "0" ] || return 1
  # Root open/close counts, anchored to line starts so an attribute value or a
  # comment mentioning the tag cannot skew them.
  [ "$(grep -c "^[[:space:]]*<$_x_root[ >]" "$_x_f" 2>/dev/null)" = "$(grep -c "^[[:space:]]*</$_x_root>" "$_x_f" 2>/dev/null)" ] || return 1
  return 0
}

# Delete ONE paired <app_feature name="X"> ... </app_feature> block, but only when its
# closing tag is actually found. A sed range-delete that never matches its end pattern
# silently deletes to EOF and ships a truncated XML; this awk version buffers the
# block, drops it only on a real close, prints the buffer back verbatim on a runaway
# or unterminated block (file stays unchanged, cmp later rejects it as a payload) and
# reports whether anything was deleted. $1 = file, $2 = feature name.
_cr_delete_block() {
  _db_f="$1"; _db_name="$2"
  awk -v name="$_db_name" '
    !inblk && index($0, "<app_feature name=\"" name "\">") { inblk=1; buf=$0; next }
    inblk {
      if (index($0, "</app_feature>")) { inblk=0; dropped=1; next }
      buf = buf "\n" $0
      if (length(buf) > 16384) { printf "%s\n", buf; inblk=0; buf="" }
      next
    }
    { print }
    END {
      if (inblk) printf "%s\n", buf
      exit (dropped ? 0 : 1)
    }
  ' "$_db_f" > "$_db_f.cr.tmp" 2>/dev/null || { rm -f "$_db_f.cr.tmp" 2>/dev/null; return 1; }
  mv -f "$_db_f.cr.tmp" "$_db_f" 2>/dev/null || { rm -f "$_db_f.cr.tmp" 2>/dev/null; return 1; }
  return 0
}

# /my_stock/etc/extension/com.oplus.app-features.xml: whole MCC blocks that hide the
# record entry or force the prompt for listed carrier codes.
_cr_patch_appfeatures_stock() {
  _p="$1"
  for _f in com.android.incallui.hide_call_record_mcc \
            com.android.incallui.support_call_record_prompt_mcc; do
    grep -q "name=\"$_f\"" "$_p" 2>/dev/null || continue
    _cr_delete_block "$_p" "$_f" && _cr_n=$((_cr_n + 1))
  done
}

# Stage one patched pair: $1 live path (fixture-rooted), $2 patcher. Writes the
# payload under STATE_DIR/callrec_patched<live> and appends target|payload to the
# manifest only when the patch actually changed something.
_cr_stage() {
  _s_live="$1"; _s_how="$2"
  [ -f "$_s_live" ] || return 1
  _s_pay="$STATE_DIR/callrec_patched$_s_live"
  mkdir -p "$(dirname "$_s_pay")" 2>/dev/null || return 1
  cp -f "$_s_live" "$_s_pay" 2>/dev/null || return 1
  "$_s_how" "$_s_pay"
  if cmp -s "$_s_pay" "$_s_live" 2>/dev/null; then
    rm -f "$_s_pay" 2>/dev/null
    return 1
  fi
  # Structural sanity, fail-closed: a truncated or non-XML payload must never bind.
  _cr_xml_sane "$_s_pay" || { rm -f "$_s_pay" 2>/dev/null; return 1; }
  chmod 0644 "$_s_pay" 2>/dev/null
  _s_ctx="$(ls -Zd "$_s_live" 2>/dev/null | awk '{print $1}')"
  case "$_s_ctx" in
    ?*:?*:?*:?*) chcon "$_s_ctx" "$_s_pay" 2>/dev/null || true ;;
  esac
  echo "$_s_live|$_s_pay" >> "$MAN.new" 2>/dev/null
  return 0
}

# Stage the whole my_product extension dir as ONE directory bind. Real devices carry
# ~80 country XMLs in it; binding each file separately was an 82-entry manifest and
# a mount storm in init's namespace at post-fs-data. One full copy, patched inside,
# bound once. Every country file is patched in the copy; a file whose patch breaks
# the XML is restored from the live original (that country simply stays stock), and
# the dir enters the manifest only when at least one file inside actually changed.
_cr_stage_dir() {
  # Stage each country file on its own - never bind the directory.
  #
  # This copied the whole of my_product/etc/extension, relabelled the entire copy with
  # the DIRECTORY's SELinux context (chcon -R) and bound it over the live directory.
  # Every other file in that tree then carried a label it was never meant to have;
  # system_server reads those files and SELinux denied it. That is the crash the
  # bootloop fuse caught: "a boot with the callrec binds did not survive".
  #
  # The working reference module binds one file per country and never the directory.
  # Each payload here inherits the context of the exact file it replaces, and files
  # that were not patched are not covered at all.
  _sd_live="$1"
  [ -d "$_sd_live" ] || return 1
  _sd_n=0
  for _sd_src in "$_sd_live"/*/appfeature.country.dynamic_features.xml; do
    [ -f "$_sd_src" ] || continue
    _sd_pay="$STATE_DIR/callrec_patched$_sd_src"
    mkdir -p "$(dirname "$_sd_pay")" 2>/dev/null || continue
    cp -f "$_sd_src" "$_sd_pay" 2>/dev/null || continue
    _cr_patch_country "$_sd_pay"
    if ! _cr_xml_sane "$_sd_pay" || cmp -s "$_sd_pay" "$_sd_src" 2>/dev/null; then
      rm -f "$_sd_pay" 2>/dev/null
      continue
    fi
    chmod 0644 "$_sd_pay" 2>/dev/null
    # Label from the file being replaced. If it has a real context and the payload
    # cannot take it, the bind would be mislabelled - skip the file, do not guess.
    _sd_ctx="$(ls -Z "$_sd_src" 2>/dev/null | awk '{print $1}')"
    case "$_sd_ctx" in
      ?*:?*:?*:?*) chcon "$_sd_ctx" "$_sd_pay" 2>/dev/null || { rm -f "$_sd_pay"; continue; } ;;
    esac
    echo "$_sd_src|$_sd_pay" >> "$MAN.new" 2>/dev/null
    _sd_n=$((_sd_n + 1))
  done
  [ "$_sd_n" -gt 0 ]
}

asb_callrec_prepare() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  rm -f "$MAN.new" 2>/dev/null
  # Full rebuild every time: no payload from a previous boot (or a previous release,
  # or a pre-OTA file set) can linger and get bound over fresh OEM files.
  rm -rf "$STATE_DIR/callrec_patched" 2>/dev/null
  _cr_n=0
  _cr_seen=0
  if _cr_dialer_stack_present; then
    _CR_DIALER=1
    echo 'present' > "$STATE_DIR/callrec_dialer_stack" 2>/dev/null
  else
    _CR_DIALER=0
    echo 'absent' > "$STATE_DIR/callrec_dialer_stack" 2>/dev/null
  fi

  _cr_f="$LIVE_ROOT/my_region/etc/extension/com.oplus.app-features.xml"
  if [ -f "$_cr_f" ]; then _cr_seen=1; _cr_stage "$_cr_f" _cr_patch_appfeatures_region || true; fi
  _cr_f="$LIVE_ROOT/my_stock/etc/extension/com.oplus.app-features.xml"
  if [ -f "$_cr_f" ]; then _cr_seen=1; _cr_stage "$_cr_f" _cr_patch_appfeatures_stock || true; fi
  _cr_d="$LIVE_ROOT/my_product/etc/extension"
  if [ -d "$_cr_d" ]; then _cr_seen=1; _cr_stage_dir "$_cr_d" || true; fi
  # app_v2.xml is deliberately NOT patched - this is what bootlooped the device.
  #
  # Removing its <disable pkg="..."> entries for com.android.incallui, com.android.contacts,
  # com.android.mms, com.oplus.blacklistapp and com.oplus.phonenoareainquire ENABLES those
  # packages at boot. On a global OxygenOS build they are disabled for a reason: the
  # stock copies are not wired to run as the device's dialer. InCallUI binds to the
  # Telecom service inside system_server, so enabling an incompatible one at boot takes
  # system_server down with it - the bootloop the fuse kept catching after the directory
  # bind was already fixed.
  #
  # The working reference module removes the same entries, but ships its own Contacts,
  # InCallUI, Mms and BlackListApp APKs in priv-app so the packages it enables are
  # working ones. This module ships no APKs by design, so it must not enable them.
  # Only the feature flags are patched; the stock in-call UI stays exactly as shipped.

  if [ -s "$MAN.new" ]; then
    mv -f "$MAN.new" "$MAN" 2>/dev/null
    echo 'ready' > "$LINE_STATE" 2>/dev/null
  else
    rm -f "$MAN.new" "$MAN" 2>/dev/null
    if [ "$_cr_seen" = "1" ]; then
      echo 'already' > "$LINE_STATE" 2>/dev/null
    else
      echo 'unsupported' > "$LINE_STATE" 2>/dev/null
    fi
  fi
  _prep_entries=0
  [ -f "$MAN" ] && _prep_entries="$(grep -c '|' "$MAN" 2>/dev/null)"
  _log "action=callrec_prepare state=$(cat "$LINE_STATE" 2>/dev/null) entries=${_prep_entries:-0} dialer=${_CR_DIALER:-0} patched=$_cr_n"
  return 0
}

# --- bind ownership ---------------------------------------------------------------

# Where a patched file may be bound. Only the real feature-XML paths in production;
# the fixture root relocates the same suffixes under its sandbox.
_cr_target_allowed() {
  case "$1" in
    # app_v2.xml is deliberately absent: binding it enabled the stock InCallUI and
    # Contacts at boot and crashed system_server. See the staging note above.
    /my_region/etc/extension/com.oplus.app-features.xml|\
    /my_stock/etc/extension/com.oplus.app-features.xml) return 0 ;;
    # One country file, never the directory. The directory used to be allowed here and
    # was bound whole; that relabelled every file under it and crashed system_server.
    # [A-Z][A-Z]* keeps this to a country code segment - a path that climbs out with ../
    # or names another file in the tree is still refused.
    /my_product/etc/extension/[A-Z][A-Z]*/appfeature.country.dynamic_features.xml)
      case "$1" in *..*) return 1 ;; esac
      return 0 ;;
  esac
  [ -n "$LIVE_ROOT" ] || return 1
  case "$1" in
    "$LIVE_ROOT"/my_region/etc/extension/com.oplus.app-features.xml|\
    "$LIVE_ROOT"/my_stock/etc/extension/com.oplus.app-features.xml) return 0 ;;
    "$LIVE_ROOT"/my_product/etc/extension/[A-Z][A-Z]*/appfeature.country.dynamic_features.xml)
      case "$1" in *..*) return 1 ;; esac
      return 0 ;;
  esac
  return 1
}

# Fail-closed manifest validation, mirroring the mmfeed owner. Every rejection
# names itself in _CR_GUARD_WHY: a silent guard is an undebuggable guard (observed:
# toggle on, zero binds, zero log lines).
_cr_guard() {
  _CR_GUARD_WHY='ok'
  [ -f "$MAN" ] || { _CR_GUARD_WHY='no_manifest'; return 1; }
  _g_n=0
  while IFS='|' read -r _g_t _g_p _g_x; do
    case "$_g_t$_g_p$_g_x" in ''|'#'*) continue ;; esac
    if [ -z "$_g_t" ] || [ -z "$_g_p" ] || [ -n "$_g_x" ]; then
      _CR_GUARD_WHY="malformed:$_g_t"; return 1
    fi
    _cr_target_allowed "$_g_t" || { _CR_GUARD_WHY="target_not_allowed:$_g_t"; return 1; }
    case "$_g_p" in "$STATE_DIR/callrec_patched/"*) ;; *)
      _CR_GUARD_WHY="payload_out_of_bounds:$_g_p"; return 1 ;;
    esac
    [ -e "$_g_t" ] || { _CR_GUARD_WHY="target_missing:$_g_t"; return 1; }
    if [ -d "$_g_p" ]; then
      # Directory payload (the country-XML tree): its files were validated one by
      # one at stage time; here the dir itself just has to exist and be ours.
      :
    else
      [ -s "$_g_p" ] || { _CR_GUARD_WHY="payload_empty:$_g_p"; return 1; }
      _cr_xml_sane "$_g_p" || { _CR_GUARD_WHY="payload_not_xml:$_g_p"; return 1; }
    fi
    _g_n=$((_g_n + 1))
  done < "$MAN"
  [ "$_g_n" -gt 0 ] || _CR_GUARD_WHY='empty_manifest'
  [ "$_g_n" -gt 0 ]
}

_is_bound() {
  grep -q " $1 " "$PROC_MOUNTS" 2>/dev/null
}

_bind_one() {
  _b_t="$1"; _b_p="$2"
  # Already bound: a directory payload cannot be cmp'd - take the mount table's word
  # and never stack a second bind over the first.
  _is_bound "$_b_t" && { [ -d "$_b_p" ] && return 0; cmp -s "$_b_t" "$_b_p" 2>/dev/null && return 0; }
  # Plain bind, exactly like the LTPO/mmfeed owners (proven on-device) and the
  # field-proven or965 module: NO remount,ro,bind afterwards. That extra remount was
  # the one mount operation both working references avoid - nobody legitimately
  # writes feature XMLs, so its protection was theoretical and its cost is one more
  # mount syscall in init's namespace during early boot.
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- mount --bind "$_b_p" "$_b_t" 2>/dev/null; then
    return 0
  fi
  mount --bind "$_b_p" "$_b_t" 2>/dev/null
}

_unbind_one() {
  _u_t="$1"
  _is_bound "$_u_t" || return 0
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- umount "$_u_t" 2>/dev/null; then
    return 0
  fi
  umount "$_u_t" 2>/dev/null
}

_cr_bind_all() {
  _a_any=0
  while IFS='|' read -r _a_t _a_p; do
    case "$_a_t" in ''|'#'*) continue ;; esac
    if _bind_one "$_a_t" "$_a_p"; then
      _a_any=1
      : > "$ACTIVE" 2>/dev/null
      # Per-target success line: if the boot dies under these binds, the surviving
      # log names exactly what was mounted before the crash.
      _log "action=callrec_bind result=bound target=$_a_t"
    else
      _log "action=callrec_bind result=fail target=$_a_t"
    fi
  done < "$MAN"
  [ "$_a_any" = "1" ]
}

_cr_unbind_all() {
  _r_any=0
  [ -f "$MAN" ] || { rm -f "$ACTIVE" 2>/dev/null; return 1; }
  while IFS='|' read -r _r_t _r_p; do
    case "$_r_t" in ''|'#'*) continue ;; esac
    _unbind_one "$_r_t" && _r_any=1
  done < "$MAN"
  rm -f "$ACTIVE" 2>/dev/null
  [ "$_r_any" = "1" ]
}

# --- recording announcement silence ------------------------------------------------
# The prompt .pcm is read when a recording starts, so the bind works live; it is
# re-asserted at every boot while either toggle is on.

_cr_silence_prompts() {
  _sp_empty="$STATE_DIR/callrec_empty.pcm"
  : > "$_sp_empty" 2>/dev/null || return 1
  chmod 0644 "$_sp_empty" 2>/dev/null
  # The payload inherits the prompt dir's SELinux label: a reader denied by context
  # would get avc noise instead of silence.
  _sp_ctx="$(ls -Zd "$LIVE_ROOT/system_ext/etc/recording-prompt" 2>/dev/null | awk '{print $1}')"
  case "$_sp_ctx" in
    ?*:?*:?*:?*) chcon "$_sp_ctx" "$_sp_empty" 2>/dev/null || true ;;
  esac
  : > "$PROMPT_ACTIVE.new" 2>/dev/null
  _sp_any=0
  for _sp_d in "$LIVE_ROOT/system_ext/etc/recording-prompt" \
               "$LIVE_ROOT/system/system_ext/etc/recording-prompt"; do
    [ -d "$_sp_d" ] || continue
    for _sp_f in "$_sp_d"/*; do
      [ -f "$_sp_f" ] || continue
      _is_bound "$_sp_f" && { echo "$_sp_f" >> "$PROMPT_ACTIVE.new"; _sp_any=1; continue; }
      if _bind_one "$_sp_f" "$_sp_empty"; then
        echo "$_sp_f" >> "$PROMPT_ACTIVE.new"
        _sp_any=1
      fi
    done
  done
  mv -f "$PROMPT_ACTIVE.new" "$PROMPT_ACTIVE" 2>/dev/null
  [ "$_sp_any" = "1" ]
}

_cr_unsilence_prompts() {
  _up_any=0
  if [ -f "$PROMPT_ACTIVE" ]; then
    while IFS= read -r _up_f; do
      case "$_up_f" in ''|'#'*) continue ;; esac
      _unbind_one "$_up_f" && _up_any=1
    done < "$PROMPT_ACTIVE"
  fi
  rm -f "$PROMPT_ACTIVE" "$PROMPT_ACTIVE.new" 2>/dev/null
  [ "$_up_any" = "1" ]
}

# --- messenger recording (VoiceScribe prefs patch) ---------------------------------

# Known messenger/voip packages, grown from the field-proven list; the apply step
# merges in anything installed that matches the same family, so coverage follows the
# device rather than a frozen table.
_CR_KNOWN_PKGS="org.telegram.messenger org.thoughtcrime.securesms org.telegram.messenger.web org.telegram.plus com.telegram.plus com.exteragram.messenger com.tgplus.messenger com.elegram.messenger com.telegram.fork com.telegram.alpha com.telegram.beta com.whatsapp com.whatsapp.w4b ru.yandex.telemost us.zoom.videomeetings com.zoom.mymeetings com.vkontakte.android com.vk.android com.microsoft.teams com.viber.voip nu.gpu.nagram ru.oneme.app com.oneme.app com.google.android.dialer"

_cr_pkgs_installed() {
  # Third-party only (-3). System theme overlays such as
  # com.android.systemui.PuiThemeSignalLOGO live in the full list and were showing up
  # as "supported apps" in the dialer's recording settings.
  pm list packages -3 2>/dev/null | sed 's/^package://' | tr -d '\r'
}

_cr_messenger_list() {
  {
    for _k in $_CR_KNOWN_PKGS; do echo "$_k"; done
    # Match a whole dot-separated segment, never a substring.
    #
    # The substring grep put a SystemUI theme overlay (PuiThemeSignalLOGO, via 'signal')
    # and Apktool M (ru.maximoff.apktool, via 'imo' inside 'maximoff') into the dialer's
    # list of supported recording apps. Real messengers use these words as a package
    # segment - com.whatsapp, com.imo.android.imoim, com.discord - so anchoring on the
    # dots keeps every real one and drops the accidental matches.
    _cr_pkgs_installed | grep -Ei '(^|\.)(telegram|whatsapp|viber|vkontakte|teams|zoom|securesms|wechat|mm|kakao|line|imo|botim|messenger|orca|oneme|telemost|skype|discord)(\.|$)' 2>/dev/null
  } | awk 'NF && !seen[$0]++'
}

# One-line JSON for the app lists: known messengers merged with installed ones.
# $1 = true|false for the per-entry isChecked flag.
_cr_apps_json() {
  _cj_sw="$1"
  _cj_out='['
  _cj_first=1
  for _cj_p in $(_cr_messenger_list); do
    [ "$_cj_first" = "1" ] && _cj_first=0 || _cj_out="$_cj_out,"
    _cj_out="$_cj_out{\"isBlacklist\":false,\"isChecked\":$_cj_sw,\"isInstall\":false,\"pkgName\":\"$_cj_p\"}"
  done
  printf '%s' "$_cj_out]"
}

# Full prefs file, written only when the app has none yet (first run never happened).
# Keys mirror the field-proven config so the app reads a familiar document; the two
# switches and the two lists are the only keys ASB owns. $1 = output, $2 = on|off.
_cr_write_prefs() {
  _w_out="$1"; _w_on="$2"
  _w_sw=false; [ "$_w_on" = "on" ] && _w_sw=true
  _w_json="$(_cr_apps_json "$_w_sw")"
  _w_tmp="$_w_out.asb.tmp"
  {
    echo "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"
    echo '<map>'
    echo '    <boolean name="subtitle_statement_v6" value="false" />'
    echo '    <int name="subtitle_font_size" value="0" />'
    echo '    <float name="subtitle_bg_alpha" value="1.0" />'
    echo '    <int name="device_support_summary_aigc_call_summaryRU" value="1" />'
    echo '    <int name="device_support_summary_aigc_call_summaryCN" value="1" />'
    echo '    <int name="device_support_summary_aigc_call_summaryMD" value="1" />'
    echo '    <boolean name="feedback_permission_status" value="true" />'
    echo '    <boolean name="subtitle_card_show_card_expand" value="false" />'
    echo '    <int name="device_support_call_summary_export" value="0" />'
    echo '    <int name="device_support_summary_aigc_call_summaryUA" value="0" />'
    echo '    <boolean name="subtitle_smooth_private_show" value="true" />'
    echo '    <int name="device_support_summary_audio_asr_expRU" value="0" />'
    echo '    <boolean name="subtitle_guide_show" value="true" />'
    echo '    <boolean name="subtitle_smooth_switch_status" value="true" />'
    echo '    <boolean name="support_two_language" value="false" />'
    echo '    <int name="device_support_summary" value="0" />'
    echo "    <boolean name=\"auto_record_switch_status\" value=\"$_w_sw\" />"
    echo "    <boolean name=\"auto_smart_voice_switch_status\" value=\"$_w_sw\" />"
    echo "    <string name=\"support_apps_auto_record\">$_w_json</string>"
    echo "    <string name=\"support_apps_smart_voice\">$_w_json</string>"
    echo '</map>'
  } > "$_w_tmp" 2>/dev/null || { rm -f "$_w_tmp" 2>/dev/null; return 1; }
  # Never let a truncated prefs file reach the app: the map must close.
  grep -q '</map>' "$_w_tmp" 2>/dev/null || { rm -f "$_w_tmp" 2>/dev/null; return 1; }
  mv -f "$_w_tmp" "$_w_out" 2>/dev/null
}

# In-place patch of an EXISTING prefs file: flip the two switches and replace the two
# app lists, leaving every other key - user choices, app state, keys a newer app
# version added - exactly as it was. This is what makes the tweak survive app
# updates: there is no frozen full file to go stale. $1 = prefs path, $2 = on|off.
_cr_patch_prefs() {
  _pp_f="$1"; _pp_on="$2"
  [ -f "$_pp_f" ] || return 1
  _pp_sw=false; [ "$_pp_on" = "on" ] && _pp_sw=true
  _pp_json="$(_cr_apps_json "$_pp_sw")"
  _pp_tmp="$_pp_f.asb.tmp"
  cp -f "$_pp_f" "$_pp_tmp" 2>/dev/null || { rm -f "$_pp_tmp" 2>/dev/null; return 1; }
  for _pp_key in auto_record_switch_status auto_smart_voice_switch_status; do
    if grep -q "name=\"$_pp_key\"" "$_pp_tmp" 2>/dev/null; then
      sed -i "s|<boolean name=\"$_pp_key\" value=\"[a-z]*\"[[:space:]]*/>|<boolean name=\"$_pp_key\" value=\"$_pp_sw\" />|g" "$_pp_tmp" 2>/dev/null
    else
      # Key absent (older/newer schema): insert before the map closes, awk not sed -
      # toybox sed does not honor \n in the replacement, and this runs on-device.
      awk -v line="    <boolean name=\"$_pp_key\" value=\"$_pp_sw\" />" \
        '{ if (!done && index($0, "</map>")) { print line; done=1 } print }' \
        "$_pp_tmp" > "$_pp_tmp.2" 2>/dev/null && mv -f "$_pp_tmp.2" "$_pp_tmp" 2>/dev/null
      rm -f "$_pp_tmp.2" 2>/dev/null
    fi
  done
  for _pp_key in support_apps_auto_record support_apps_smart_voice; do
    if grep -q "name=\"$_pp_key\"" "$_pp_tmp" 2>/dev/null; then
      # Replace from the opening tag through its </string> (the JSON may span lines).
      awk -v key="$_pp_key" -v json="$_pp_json" '
        index($0, "<string name=\"" key "\">") {
          print "    <string name=\"" key "\">" json "</string>"
          if (index($0, "</string>") == 0) skip=1
          next
        }
        skip && index($0, "</string>") { skip=0; next }
        skip { next }
        { print }
      ' "$_pp_tmp" > "$_pp_tmp.2" 2>/dev/null && mv -f "$_pp_tmp.2" "$_pp_tmp" 2>/dev/null
      rm -f "$_pp_tmp.2" 2>/dev/null
    else
      awk -v line="    <string name=\"$_pp_key\">$_pp_json</string>" \
        '{ if (!done && index($0, "</map>")) { print line; done=1 } print }' \
        "$_pp_tmp" > "$_pp_tmp.2" 2>/dev/null && mv -f "$_pp_tmp.2" "$_pp_tmp" 2>/dev/null
      rm -f "$_pp_tmp.2" 2>/dev/null
    fi
  done
  # Fail-closed: a patched file that lost its closing map or a switch must not ship.
  grep -q '</map>' "$_pp_tmp" 2>/dev/null || { rm -f "$_pp_tmp" 2>/dev/null; return 1; }
  grep -q "name=\"auto_record_switch_status\" value=\"$_pp_sw\"" "$_pp_tmp" 2>/dev/null || { rm -f "$_pp_tmp" 2>/dev/null; return 1; }
  grep -q "name=\"support_apps_auto_record\"" "$_pp_tmp" 2>/dev/null || { rm -f "$_pp_tmp" 2>/dev/null; return 1; }
  mv -f "$_pp_tmp" "$_pp_f" 2>/dev/null
}

# Patch-or-create: merge into existing prefs, generate a full file only when the app
# never wrote one. $1 = prefs path, $2 = on|off.
_cr_prefs_apply() {
  if [ -f "$1" ]; then
    _cr_patch_prefs "$1" "$2"
  else
    _cr_write_prefs "$1" "$2"
  fi
}

# Permissions this module granted, so they can be taken back.
#
# The messenger path grants VoiceScribe RECORD_AUDIO and storage. Settings are backed up
# (.asb.bak) and restored on off/uninstall, but the grants were not: after switching the
# tweak off, or removing the module entirely, an OEM package kept microphone access that
# the user never gave it. Only permissions that were NOT already granted are recorded, and
# only those are revoked - a grant the user made themselves before enabling this stays.
_cr_grant_tracked() {
  _gt_file="${APPS_ACTIVE}.grants"
  for _gt_perm in android.permission.RECORD_AUDIO \
                  android.permission.READ_EXTERNAL_STORAGE \
                  android.permission.WRITE_EXTERNAL_STORAGE; do
    if ! dumpsys package "$VS_PKG" 2>/dev/null | grep -q "${_gt_perm}: granted=true"; then
      pm grant "$VS_PKG" "$_gt_perm" >/dev/null 2>&1 \
        && { grep -qx "$_gt_perm" "$_gt_file" 2>/dev/null || echo "$_gt_perm" >> "$_gt_file"; }
    fi
  done
}
_cr_revoke_tracked() {
  _gt_file="${APPS_ACTIVE}.grants"
  [ -f "$_gt_file" ] || return 0
  while IFS= read -r _gt_perm; do
    case "$_gt_perm" in android.permission.*) pm revoke "$VS_PKG" "$_gt_perm" >/dev/null 2>&1 ;; esac
  done < "$_gt_file"
  rm -f "$_gt_file" 2>/dev/null
  _log 'action=callrec_apps result=grants_revoked'
}

_cr_apply_apps() {
  if [ "$(_cfg callrec_apps)" != "1" ] || [ -f "$BLOCK" ]; then
    # Toggle off: recordings stop, the app and its data stay - everything else in its
    # prefs is left exactly as it was.
    if [ -f "$APPS_ACTIVE" ]; then
      _off_dir="${ASB_CALLREC_USER_DIR:-/data/user/0}/$VS_PKG"
      if [ -d "$_off_dir" ]; then
        mkdir -p "$_off_dir/shared_prefs" 2>/dev/null
        _cr_prefs_apply "$_off_dir/shared_prefs/translatePreferences.xml" off 2>/dev/null
        _off_own="$(stat -c '%u:%g' "$_off_dir" 2>/dev/null)"
        [ -n "$_off_own" ] && chown "$_off_own" "$_off_dir/shared_prefs" "$_off_dir/shared_prefs/translatePreferences.xml" 2>/dev/null
        chmod 660 "$_off_dir/shared_prefs/translatePreferences.xml" 2>/dev/null
        restorecon "$_off_dir/shared_prefs" "$_off_dir/shared_prefs/translatePreferences.xml" 2>/dev/null
      fi
      am force-stop "$VS_PKG" 2>/dev/null
      _cr_revoke_tracked
      rm -f "$APPS_ACTIVE" 2>/dev/null
      echo 'off' > "$APPS_STATE" 2>/dev/null
      _log 'action=callrec_apps result=disabled'
    fi
    return 0
  fi

  # Patch-only: the VoiceScribe package must already be on the device. Nothing is
  # installed - a device without it is told so, not given a foreign APK.
  _aa_cur="$(pm path "$VS_PKG" 2>/dev/null | head -1 | sed 's/^package://' | tr -d '\r')"
  if [ -z "$_aa_cur" ]; then
    echo 'unsupported' > "$APPS_STATE" 2>/dev/null
    _log 'action=callrec_apps result=unsupported_no_package'
    return 0
  fi

  _aa_dir="${ASB_CALLREC_USER_DIR:-/data/user/0}/$VS_PKG"
  if [ ! -d "$_aa_dir" ]; then
    # First run creates the data dir; without it the prefs would land nowhere.
    am start -n "$VS_PKG/.subtitle.PrivacyPolicyActivity" >/dev/null 2>&1
    _aa_i=0
    while [ ! -d "$_aa_dir" ] && [ "$_aa_i" -lt 15 ]; do sleep 1; _aa_i=$((_aa_i + 1)); done
    am force-stop "$VS_PKG" 2>/dev/null
  fi
  if [ ! -d "$_aa_dir" ]; then
    echo 'apply_failed' > "$APPS_STATE" 2>/dev/null
    _log 'action=callrec_apps result=no_datadir'
    return 0
  fi

  mkdir -p "$_aa_dir/shared_prefs" 2>/dev/null
  _aa_prefs="$_aa_dir/shared_prefs/translatePreferences.xml"
  if [ -f "$_aa_prefs" ] && [ ! -f "$_aa_prefs.asb.bak" ]; then
    cp -f "$_aa_prefs" "$_aa_prefs.asb.bak" 2>/dev/null
  fi
  if _cr_prefs_apply "$_aa_prefs" on; then
    _aa_own="$(stat -c '%u:%g' "$_aa_dir" 2>/dev/null)"
    [ -n "$_aa_own" ] && chown "$_aa_own" "$_aa_dir/shared_prefs" "$_aa_prefs" 2>/dev/null
    chmod 771 "$_aa_dir/shared_prefs" 2>/dev/null
    chmod 660 "$_aa_prefs" 2>/dev/null
    restorecon "$_aa_dir/shared_prefs" "$_aa_prefs" 2>/dev/null
  else
    echo 'apply_failed' > "$APPS_STATE" 2>/dev/null
    _log 'action=callrec_apps result=prefs_failed'
    return 0
  fi
  _cr_grant_tracked
  am force-stop "$VS_PKG" 2>/dev/null
  : > "$APPS_ACTIVE" 2>/dev/null
  echo 'applied' > "$APPS_STATE" 2>/dev/null
  _log 'action=callrec_apps result=applied'
  return 0
}

# One-strike lockdown: the previous boot carried our binds and never reached
# boot_completed. Everything we own comes down, the payloads are deleted so a
# re-prepare cannot resurrect them silently, and the block file keeps the tweak
# inert until the user deliberately re-arms it (toggle off clears the block).
_cr_lockdown() {
  _cr_unbind_all >/dev/null 2>&1
  _cr_unsilence_prompts >/dev/null 2>&1
  rm -f "$MAN" "$ACTIVE" "$PROMPT_ACTIVE" "$PROMPT_ACTIVE.new" "$PENDING" 2>/dev/null
  rm -rf "$STATE_DIR/callrec_patched" 2>/dev/null
  : > "$CR_BLOCK" 2>/dev/null
  # Same reason as the pending marker: if the lockdown decision is lost to a crash, the
  # next boot repeats the mount that caused it.
  sync 2>/dev/null || true
  echo 'blocked_bootloop' > "$LINE_STATE" 2>/dev/null
  _log 'action=callrec_bind result=BLOCKED reason=bootloop_fuse strikes=1'
}

# --- entry points ------------------------------------------------------------------

case "${1:-apply}" in
  prepare)
    asb_callrec_prepare
    ;;
  apply)
    # The XML patch is re-derived on every apply: after an OTA the live files are the
    # new OEM ones, and the bind must shadow those, not last release's copy of them.
    asb_callrec_prepare
    _boot_apply="${ASB_CALLREC_BOOT:-0}"
    _line_on=0;  [ "$(_cfg callrec_line)" = "1" ] && _line_on=1
    _apps_on=0;  [ "$(_cfg callrec_apps)" = "1" ] && _apps_on=1
    # Re-arm: BOTH toggles off is the only gesture that resets the fuse - a half-off
    # state must not silently clear a block the other toggle may have caused.
    if [ "$_line_on" = "0" ] && [ "$_apps_on" = "0" ]; then
      rm -f "$CR_BLOCK" "$PENDING" 2>/dev/null
    fi
    _blocked=0
    if [ -f "$BLOCK" ] || [ -f "$CR_BLOCK" ]; then _blocked=1; fi

    # One-strike fuse over EVERYTHING this script mounts at boot (the XML binds):
    # a boot that finds its own marker never survived the stability window of the
    # previous one - lockdown, before anything is mounted this boot. The marker
    # retires 120s AFTER sys.boot_completed (see service.sh), so a crash that comes
    # late in the boot - after boot_completed, the exact shape this tweak's failures
    # had - still trips the fuse instead of looping forever.
    if [ "$_boot_apply" = "1" ] && [ "$_blocked" = "0" ] && [ -f "$PENDING" ] \
       && { [ "$_line_on" = "1" ] || [ "$_apps_on" = "1" ]; }; then
      _cr_lockdown
      _blocked=1
    fi
    # Lifecycle line first: every apply leaves a trace, so an empty log is itself
    # a diagnosis (the script never ran), not a mystery.
    _log "action=callrec_apply boot=$_boot_apply line=$_line_on apps=$_apps_on blocked=$_blocked"

    # XML binds: post-fs-data ONLY, while the runtime is not up. Never in the late
    # pass, never live - a running system hot-reloads feature XMLs and dies. The
    # module ships no my_* dirs, so magic mount never shadows these binds.
    # A non-boot apply with the toggle ON must leave the boot binds ALONE: the late
    # service.sh pass used to fall into the removal branch and unbind what
    # post-fs-data had just mounted (observed: toggle on, zero binds, zero logs).
    if [ "$_line_on" = "1" ] && [ "$_blocked" = "0" ]; then
      if [ "$_boot_apply" = "1" ]; then
        if _cr_guard; then
          # The marker goes down BEFORE the first mount: even a mount that wedges
          # the boot outright is caught by the next one.
          : > "$PENDING" 2>/dev/null
          # Force the marker to disk before mounting anything.
          #
          # ext4 commits metadata lazily, around every five seconds. The failure this
          # guards against kills the device faster than that: the marker was still only
          # in page cache, the reboot lost it, and the next boot saw a clean slate and
          # mounted again - a loop that ran until KernelSU's own safe mode broke it,
          # instead of stopping after one bad boot.
          sync 2>/dev/null || true
          _cr_bind_all && _log 'action=callrec_bind result=applied'
        else
          _log "action=callrec_guard result=reject why=${_CR_GUARD_WHY:-unknown}"
        fi
      fi
    else
      if [ -f "$ACTIVE" ]; then
        _cr_unbind_all && _log 'action=callrec_bind result=removed'
      fi
    fi

    # Prompt silence: audio assets, not hot-reloaded config - safe to assert on a
    # running system, so it deliberately stays OUT of the boot window: the only
    # mounts this script ever makes at post-fs-data are the feature-XML binds. The
    # late service.sh pass (and any live apply) asserts the silence instead; the
    # prompt files are read lazily when a recording starts, long after boot.
    # Prompt silencing is a MOUNT, so it belongs where every other mount here lives:
    # post-fs-data, before the runtime is up.
    #
    # This ran on a live system when the toggle was flipped - binding an empty file over
    # every file in recording-prompt, inside init's mount namespace, while the audio and
    # telecom services were running. The device froze within seconds, the screen went off
    # and it hard-rebooted. The XML binds were already boot-only for exactly this reason;
    # this one was the single live mount left, and it was the one being exercised.
    #
    # The cost is that the toggle now needs a reboot to take effect - which it needed
    # anyway: the feature XMLs are only read at boot.
    if [ "$_blocked" = "0" ] && [ "$_boot_apply" = "1" ] \
       && { [ "$_line_on" = "1" ] || [ "$_apps_on" = "1" ]; }; then
      _cr_silence_prompts && _log 'action=callrec_prompt result=silenced'
    elif [ "$_blocked" = "1" ] || { [ "$_line_on" = "0" ] && [ "$_apps_on" = "0" ]; }; then
      # Toggle off or fuse set: our silence binds must not survive the choice that
      # removed them - the stock announcement is what the file plays again. A boot
      # apply with a toggle ON falls through untouched: the late pass asserts the
      # silence once the runtime is up.
      [ -f "$PROMPT_ACTIVE" ] && _cr_unsilence_prompts && _log 'action=callrec_prompt result=restored'
    fi
    # The messenger half talks to pm/am, which do not exist at post-fs-data yet; the
    # late pass in service.sh owns it there. It mounts nothing itself.
    [ "$_boot_apply" = "1" ] || _cr_apply_apps
    ;;
  confirm)
    # service.sh calls this 120s AFTER sys.boot_completed=1: the binds survived a
    # full boot plus the stability window, so the one-strike trial marker retires.
    rm -f "$PENDING" 2>/dev/null
    ;;
  remove)
    # Uninstall path: drop whatever we own regardless of the toggle state.
    _cr_unbind_all && _log 'action=callrec_bind result=removed reason=uninstall'
    _cr_unsilence_prompts && _log 'action=callrec_prompt result=restored reason=uninstall'
    rm -f "$PENDING" "$CR_BLOCK" 2>/dev/null
    if [ -f "$APPS_ACTIVE" ]; then
      _rm_dir="${ASB_CALLREC_USER_DIR:-/data/user/0}/$VS_PKG"
      [ -d "$_rm_dir" ] && _cr_prefs_apply "$_rm_dir/shared_prefs/translatePreferences.xml" off 2>/dev/null
      am force-stop "$VS_PKG" 2>/dev/null
      _cr_revoke_tracked
      rm -f "$APPS_ACTIVE" 2>/dev/null
    fi
    ;;
  status)
    if [ -f "$CR_BLOCK" ]; then
      echo 'line=blocked'
    elif [ ! -f "$MAN" ]; then
      echo 'line=patch_absent'
    elif [ "$(_cfg callrec_line)" != "1" ]; then
      echo 'line=off'
    elif [ -f "$ACTIVE" ]; then
      echo 'line=active'
    else
      echo 'line=pending_boot'
    fi
    if [ "$(_cfg callrec_apps)" != "1" ]; then
      echo 'apps=off'
    elif [ -f "$APPS_ACTIVE" ]; then
      echo 'apps=active'
    else
      echo 'apps=pending'
    fi
    ;;
esac
exit 0
