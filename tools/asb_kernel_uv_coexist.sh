#!/system/bin/sh
# ASB external kernel / UV coexistence diagnostic.
#
# Read-only evidence collector. It never writes sysfs, properties, OPP tables, modules,
# governors or voltage controls. A frequency, a temperature, or a custom-kernel name is NOT
# proof of undervolt, so this report deliberately uses evidence-level verdicts only.

ASB_SYSROOT="${ASB_SYSROOT:-/sys}"
ASB_MODULES_ROOT="${ASB_MODULES_ROOT:-/data/adb/modules}"
ASB_PROP_FILE="${ASB_PROP_FILE:-}"

_emit() { printf '%s=%s\n' "$1" "$2"; }
_trim() { printf '%s' "$1" | tr '\r\n' ' ' | cut -c1-180; }

_props() {
  if [ -r "$ASB_PROP_FILE" ]; then
    cat "$ASB_PROP_FILE" 2>/dev/null
  elif command -v getprop >/dev/null 2>&1; then
    getprop 2>/dev/null
  fi
}

# Record at most three opaque locations/names. Values are intentionally never parsed or
# compared to a hard-coded "stock" voltage: they are platform, binning and regulator specific.
_evidence=""
_count=0
_add() {
  [ -n "$1" ] || return 0
  [ "$_count" -ge 3 ] && return 0
  case "|$_evidence|" in *"|$1|"*) return 0 ;; esac
  _evidence="${_evidence}${_evidence:+ | }$1"
  _count=$((_count + 1))
}

# 1) Explicit external root-module names/metadata. The name is a hint, not proof that the
# module successfully changed a voltage table on this boot.
for _mod in "$ASB_MODULES_ROOT"/*; do
  [ -f "$_mod/module.prop" ] || continue
  _id="$(grep -E '^id=' "$_mod/module.prop" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')"
  [ "$_id" = "AutoSystemBoost" ] && continue
  _meta="$(cat "$_mod/module.prop" 2>/dev/null | tr '\n' ' ' | tr '[:upper:]' '[:lower:]')"
  case "$_id $_meta" in
    *undervolt*|*under-volt*|*" uv"*|*"uv_"*|*voltage*|*overclock*)
      _add "module:${_id:-$(basename "$_mod")}" ;;
  esac
done

# 2) Explicit property names. Only the property key is reported; values are intentionally not
# treated as proof and are not printed into user diagnostics.
_prop_keys="$(_props | sed -n 's/^\[\([^]]*\)\]:.*$/\1/p' | grep -iE 'undervolt|under.?volt|(^|[._-])uv([._-]|$)|voltage|overclock' | head -3)"
for _pk in $_prop_keys; do _add "property:${_pk}"; done

# 3) Readable kernel surfaces whose names explicitly expose voltage/UV data. Generic OPP
# names describe operating-point metadata (and occur in unrelated Bluetooth properties), not
# a non-stock voltage policy, so they are intentionally not UV evidence.
for _node in \
  "$ASB_SYSROOT"/devices/system/cpu/cpufreq/policy*/*volt* \
  "$ASB_SYSROOT"/devices/system/cpu/cpufreq/policy*/*uv* \
  "$ASB_SYSROOT"/class/kgsl/kgsl-3d0/*volt* \
  "$ASB_SYSROOT"/class/kgsl/kgsl-3d0/*uv* \
  "$ASB_SYSROOT"/kernel/debug/*volt* \
  "$ASB_SYSROOT"/kernel/debug/*uv*; do
  [ -r "$_node" ] || continue
  _add "node:${_node#$ASB_SYSROOT/}"
done

_kernel="$(uname -r 2>/dev/null | tr -d '\r\n')"
_status="not_observable"
_confidence="none"
_reason="no_explicit_external_voltage_or_uv_evidence"
if [ "$_count" -gt 0 ]; then
  case "$_evidence" in
    *node:*)
      _status="voltage_surface_observed"
      _confidence="observed_surface"
      _reason="readable_external_voltage_or_uv_surface"
      ;;
    *)
      _status="external_uv_hint"
      _confidence="name_or_property_hint"
      _reason="external_module_or_property_mentions_uv_voltage_or_overclock"
      ;;
  esac
fi

_emit "status" "$_status"
_emit "confidence" "$_confidence"
_emit "reason" "$_reason"
_emit "kernel_release" "$(_trim "$_kernel")"
_emit "evidence_count" "$_count"
_emit "evidence" "$(_trim "$_evidence")"
_emit "asb_voltage_owner" "external_or_vendor"
_emit "asb_action" "diagnostics_only"
_emit "warning" "ASB does not own, write, validate, disable or revert external voltage policy"
_emit "limit" "frequency_temperature_or_kernel_name_alone_do_not_prove_undervolt"
