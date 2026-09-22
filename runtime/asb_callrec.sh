#!/system/bin/sh
# Call-recording runtime owner: two independent, default-off WebUI tweaks.
#
#   callrec_line=1  - native line call recording on OPlus dialer stacks where the OEM
#                     region-hides it. The patch is derived from THIS device's own
#                     feature XMLs at every boot (prepare), never shipped as a static
#                     file: an OTA that rewrites /my_region, /my_product or /my_stock
#                     just gets re-patched on the next boot from whatever the OEM
#                     actually installed. Patched copies are bind-mounted over the
#                     stock files; stock is never written.
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
# marker; service.sh retires it (confirm) only after sys.boot_completed=1. A boot
# that finds its own marker still pending means the previous boot with these binds
# never completed - the patch is the prime suspect, so everything is unbound, the
# payloads are deleted and callrec_blocked stays down until the user re-arms by
# switching the toggle off and on again. This fuse does NOT rely on the vendor
# overlay counter: that one only ticks when the VENDOR_OVERLAY feature gate passes,
# and a callrec-only device would otherwise re-bind the same files forever.
#
# Two timing rules make the fuse almost never needed:
#   - The XML binds land ONLY at boot (ASB_CALLREC_BOOT=1 from post-fs-data) or in
#     the late boot pass (ASB_CALLREC_LATE=1 from service.sh). A live WebUI apply
#     never mounts them: the card is labeled reboot-to-apply, and a feature XML the
#     RUNNING system hot-reloads can crash it on the spot (observed: screen dies
#     the moment the toggle flips, then a bootloop). Toggle OFF still unbinds live.
#   - The oplus_dialer_enable features are added only when the device physically
#     ships the OPlus dialer stack. Telecom runs INSIDE system_server: enabling
#     OPlus dialer code paths on a build without the dialer APKs takes the whole
#     system_server down. The region-lock removals stay unconditional - unhiding a
#     record entry crashes nothing.

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

# Does this device physically ship the OPlus dialer stack? The oplus_dialer_enable
# features switch Phone and Telecom (telecom runs INSIDE system_server) onto OPlus
# dialer code paths; on a build without the dialer APKs those paths have nothing to
# run and can take system_server down with them - exactly the "screen dies the
# moment the toggle flips" failure. Globs stay OPlus-flavored on purpose: a Google
# or AOSP dialer must NOT count as the stack these features drive.
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
  # The dialer-enable features are added only when the OPlus dialer stack is
  # physically present (see _cr_dialer_stack_present); the lock removals above are
  # unconditional - unhiding a record entry crashes nothing.
  [ "$_CR_DIALER" = "1" ] || return 0
  # Insert after <extend_features> with awk, not sed: toybox sed does not honor \n in
  # the replacement, and this runs on-device. No <extend_features> line means this XML
  # is not the feature list we know - then nothing is inserted and nothing is counted.
  grep -q 'name="com.android.phone.oplus_dialer_enable"' "$_p" 2>/dev/null || {
    awk '{ print } /^[[:space:]]*<extend_features>[[:space:]]*$/ { print "\t<app_feature name=\"com.android.phone.oplus_dialer_enable\"/>" }' \
      "$_p" > "$_p.cr.tmp" 2>/dev/null && mv -f "$_p.cr.tmp" "$_p" 2>/dev/null \
      && grep -q 'com.android.phone.oplus_dialer_enable' "$_p" && _cr_n=$((_cr_n + 1))
    rm -f "$_p.cr.tmp" 2>/dev/null; }
  grep -q 'name="com.android.server.telecom.oplus_dialer_enable"' "$_p" 2>/dev/null || {
    awk '{ print } /^[[:space:]]*<extend_features>[[:space:]]*$/ { print "\t<app_feature name=\"com.android.server.telecom.oplus_dialer_enable\"/>" }' \
      "$_p" > "$_p.cr.tmp" 2>/dev/null && mv -f "$_p.cr.tmp" "$_p" 2>/dev/null \
      && grep -q 'com.android.server.telecom.oplus_dialer_enable' "$_p" && _cr_n=$((_cr_n + 1))
    rm -f "$_p.cr.tmp" 2>/dev/null; }
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
  _x_last="$(awk 'NF { last = $0 } END { print last }' "$_x_f" 2>/dev/null | tr -d ' \t\r')"
  case "$_x_last" in
    *"</$_x_root>"*) ;; *) return 1 ;;
  esac
  [ "$(grep -c "<$_x_root[ >]" "$_x_f" 2>/dev/null)" = "$(grep -c "</$_x_root>" "$_x_f" 2>/dev/null)" ] || return 1
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

asb_callrec_prepare() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  rm -f "$MAN.new" 2>/dev/null
  _cr_n=0
  _cr_seen=0
  if _cr_dialer_stack_present; then _CR_DIALER=1; else _CR_DIALER=0; fi

  _cr_f="$LIVE_ROOT/my_region/etc/extension/com.oplus.app-features.xml"
  if [ -f "$_cr_f" ]; then _cr_seen=1; _cr_stage "$_cr_f" _cr_patch_appfeatures_region || true; fi
  _cr_f="$LIVE_ROOT/my_stock/etc/extension/com.oplus.app-features.xml"
  if [ -f "$_cr_f" ]; then _cr_seen=1; _cr_stage "$_cr_f" _cr_patch_appfeatures_stock || true; fi
  for _cr_d in "$LIVE_ROOT"/my_product/etc/extension/*/; do
    _cr_f="${_cr_d}appfeature.country.dynamic_features.xml"
    [ -f "$_cr_f" ] || continue
    _cr_seen=1
    _cr_stage "$_cr_f" _cr_patch_country || true
  done
  for _cr_f in "$LIVE_ROOT/my_stock/etc/config/app_v2.xml" \
               "$LIVE_ROOT/my_region/etc/config/app_v2.xml"; do
    [ -f "$_cr_f" ] || continue
    _cr_seen=1
    _cr_stage "$_cr_f" _cr_patch_appv2 || true
  done

  # A payload staged for a file that no longer exists (or no longer needs a patch)
  # must not linger: the next apply would bind stale content over a fresh OTA file.
  if [ -d "$STATE_DIR/callrec_patched" ]; then
    find "$STATE_DIR/callrec_patched" -type f 2>/dev/null | while IFS= read -r _cr_p; do
      grep -qF "|$_cr_p" "$MAN.new" 2>/dev/null || rm -f "$_cr_p" 2>/dev/null
    done
  fi

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
  return 0
}

# --- bind ownership ---------------------------------------------------------------

# Where a patched file may be bound. Only the real feature-XML paths in production;
# the fixture root relocates the same suffixes under its sandbox.
_cr_target_allowed() {
  case "$1" in
    /my_region/etc/extension/com.oplus.app-features.xml|\
    /my_stock/etc/extension/com.oplus.app-features.xml|\
    /my_stock/etc/config/app_v2.xml|\
    /my_region/etc/config/app_v2.xml) return 0 ;;
    /my_product/etc/extension/*/appfeature.country.dynamic_features.xml) return 0 ;;
  esac
  [ -n "$LIVE_ROOT" ] || return 1
  case "$1" in
    "$LIVE_ROOT"/my_region/etc/extension/com.oplus.app-features.xml|\
    "$LIVE_ROOT"/my_stock/etc/extension/com.oplus.app-features.xml|\
    "$LIVE_ROOT"/my_stock/etc/config/app_v2.xml|\
    "$LIVE_ROOT"/my_region/etc/config/app_v2.xml) return 0 ;;
    "$LIVE_ROOT"/my_product/etc/extension/*/appfeature.country.dynamic_features.xml) return 0 ;;
  esac
  return 1
}

# Fail-closed manifest validation, mirroring the mmfeed owner.
_cr_guard() {
  [ -f "$MAN" ] || return 1
  _g_n=0
  while IFS='|' read -r _g_t _g_p _g_x; do
    case "$_g_t$_g_p$_g_x" in ''|'#'*) continue ;; esac
    [ -n "$_g_t" ] && [ -n "$_g_p" ] && [ -z "$_g_x" ] || return 1
    _cr_target_allowed "$_g_t" || return 1
    case "$_g_p" in "$STATE_DIR/callrec_patched/"*) ;; *) return 1 ;; esac
    [ -s "$_g_p" ] || return 1
    [ -e "$_g_t" ] || return 1
    _cr_xml_sane "$_g_p" || return 1
    _g_n=$((_g_n + 1))
  done < "$MAN"
  [ "$_g_n" -gt 0 ]
}

_is_bound() {
  grep -q " $1 " "$PROC_MOUNTS" 2>/dev/null
}

_bind_one() {
  _b_t="$1"; _b_p="$2"
  _is_bound "$_b_t" && { cmp -s "$_b_t" "$_b_p" 2>/dev/null && return 0; }
  if command -v nsenter >/dev/null 2>&1 \
     && nsenter -t 1 -m -- mount --bind "$_b_p" "$_b_t" 2>/dev/null; then
    # Best effort: the payload lives on writable /data, the view of it must not be.
    nsenter -t 1 -m -- mount -o remount,ro,bind "$_b_t" 2>/dev/null || true
    return 0
  fi
  mount --bind "$_b_p" "$_b_t" 2>/dev/null \
    && { mount -o remount,ro,bind "$_b_t" 2>/dev/null || true; }
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
  pm list packages 2>/dev/null | sed 's/^package://' | tr -d '\r'
}

_cr_messenger_list() {
  {
    for _k in $_CR_KNOWN_PKGS; do echo "$_k"; done
    _cr_pkgs_installed | grep -Ei 'telegram|whatsapp|viber|vkontakte|vk\.android|teams|zoom|securesms|wechat|tencent\.mm|kakao|naver\.line|jp\.line|imo|botim|messenger|orca|oneme|telemost|signal|skype|discord' 2>/dev/null
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
  pm grant "$VS_PKG" android.permission.RECORD_AUDIO >/dev/null 2>&1
  pm grant "$VS_PKG" android.permission.READ_EXTERNAL_STORAGE >/dev/null 2>&1
  pm grant "$VS_PKG" android.permission.WRITE_EXTERNAL_STORAGE >/dev/null 2>&1
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
    _late_apply="${ASB_CALLREC_LATE:-0}"
    # XML binds are a boot-time act only. A live WebUI apply prepares the patch and
    # reports pending_boot, but never mounts over files the RUNNING system may
    # hot-reload - that is the observed instant-crash vector. Unbinding stays live.
    _may_bind=0
    if [ "$_boot_apply" = "1" ] || [ "$_late_apply" = "1" ]; then _may_bind=1; fi
    if [ "$(_cfg callrec_line)" = "1" ] && [ ! -f "$BLOCK" ] && [ ! -f "$CR_BLOCK" ]; then
      if [ "$_boot_apply" = "1" ] && [ -f "$PENDING" ]; then
        # We bound these files last boot and boot_completed never came: lockdown.
        _cr_lockdown
      elif [ "$_may_bind" = "1" ] && _cr_guard; then
        # The marker goes down BEFORE the first mount: even a mount that wedges the
        # boot outright is caught by the next one.
        [ "$_boot_apply" = "1" ] && : > "$PENDING" 2>/dev/null
        _cr_bind_all && _log 'action=callrec_bind result=applied'
      fi
    else
      if [ -f "$ACTIVE" ]; then
        _cr_unbind_all && _log 'action=callrec_bind result=removed'
      fi
      # Toggle off is the re-arm gesture: the fuse and the trial marker reset, so the
      # next enable is a fresh, guarded trial.
      [ "$(_cfg callrec_line)" != "1" ] && rm -f "$CR_BLOCK" "$PENDING" 2>/dev/null
    fi
    if [ ! -f "$BLOCK" ] && [ ! -f "$CR_BLOCK" ] && { [ "$(_cfg callrec_line)" = "1" ] || [ "$(_cfg callrec_apps)" = "1" ]; }; then
      _cr_silence_prompts && _log 'action=callrec_prompt result=silenced'
    else
      # Toggle off or fuse set: our silence binds must not survive the choice that
      # removed them - the stock announcement is what the file plays again.
      [ -f "$PROMPT_ACTIVE" ] && _cr_unsilence_prompts && _log 'action=callrec_prompt result=restored'
    fi
    # The messenger half talks to pm/am, which do not exist at post-fs-data yet; the
    # late pass in service.sh owns it there. It also cannot bootloop anything: it
    # mounts nothing, so it stays outside the fuse by design.
    [ "$_boot_apply" = "1" ] || _cr_apply_apps
    ;;
  confirm)
    # service.sh calls this once sys.boot_completed=1: the binds survived a full
    # boot, so the one-strike trial marker retires.
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
