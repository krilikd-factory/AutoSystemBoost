#!/usr/bin/env bash
# Source checks for the AIDL DSP effect.
#
# Named dsp_stubs for historical reasons: this started as a full -fsyntax-only pass
# against hand-written AIDL stubs. Those stubs are gone. Reproducing the effect framework
# by hand needed five headers and was still growing, and a stub tree that drifts from AOSP
# reports failures the real build does not have - which is worse than no check, because
# people learn to ignore it. Nothing here includes or compiles anything now.
#
# The native governor is compiled on every push; libasbdsp_aidl.so is not, because it
# needs an AOSP tree and a soong workflow that takes an hour. The gap is not theoretical:
# a revision of asb_effect_aidl.cpp reached main with three compile errors in it -
# AudioDeviceType used without its namespace, a member access on an enum as though it
# were a struct, and an override whose signature did not match the base class. None of
# them needed a device, an AOSP tree or a linker to find. They needed a parser.
#
# What is left is a fixed list of mistakes that have actually reached main, each visible
# in the text of the file. This is a smaller claim than "it compiles" and it will not
# catch the next new class of error - the honest fix for that is running the soong
# workflow on every PR, and until that happens the window stays open.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp"
STUBS="$ROOT/tools/dsp_stubs"

[ -f "$SRC" ] || { echo "::error::asb_effect_aidl.cpp not found"; exit 1; }

# Two checks, deliberately narrow.
#
# Full -fsyntax-only needs stubs for the entire AIDL effect surface - Range, Capability,
# LoudnessEnhancer parameter tables, the lot - and chasing that produces a second copy of
# AOSP that drifts out of date and then reports failures the real build does not have. A
# stub tree that lies is worse than no stub tree.
#
# So instead: grep for the specific mistakes that reached main, each of which is visible
# in the text of the file. This is a smaller claim than "it compiles", and it is one that
# stays true without maintenance.

fail=0

# 1. AudioDeviceType used without its namespace. This file has no using-declaration for
#    it, so a bare mention cannot compile - the exact error from the last DSP build.
_code_ns="$(grep -vE '^\s*(\*|//|/\*)' "$SRC")"
if printf '%s' "$_code_ns" | grep -E '(^|[^:[:alnum:]_])AudioDeviceType::' \
     | grep -v 'common::AudioDeviceType::' | grep -q .; then
  echo "::error::AudioDeviceType used without ::aidl::android::media::audio::common:: qualification"
  printf '%s' "$_code_ns" | grep -nE '(^|[^:[:alnum:]_])AudioDeviceType::' | grep -v 'common::AudioDeviceType::' | head -5
  fail=1
fi

# 2. AudioDeviceDescription::type is the enum itself. Writing d.type.type treats it as a
#    struct - it compiled in my head and not in clang.
# Comments are stripped first: the run that caught this was flagging the comment that
# explains the bug, which is the check being right about the wrong line.
_code="$(grep -vE '^\s*(\*|//|/\*)' "$SRC")"
if printf '%s' "$_code" | grep -qE '\.type\.(type|connection)'; then
  echo "::error::AudioDeviceDescription::type is an enum - use d.type and d.connection"
  printf '%s' "$_code" | grep -nE '\.type\.(type|connection)' | head -5
  fail=1
fi

# 3. setParameterCommon takes a const Parameter&, not a Parameter::Common&. An override
#    with the wrong signature hides the base method instead of overriding it.
if grep -nE 'setParameterCommon\s*\(\s*const\s+Parameter::Common' "$SRC" | grep -q .; then
  echo "::error::setParameterCommon(const Parameter::Common&) hides the base method - it takes const Parameter&"
  fail=1
fi

# 4. Everything the effect calls on the context must be public.
#
# setDevices was added inside the private block and the soong build was the first thing to
# say so - another hour spent on a mistake visible in the text. Access control is exactly
# the kind of thing a parser catches and a human reading a diff does not.
_ctx_calls="$(grep -oE 'mContext->[A-Za-z_]+' "$SRC" | sed 's/mContext->//' | sort -u)"
for _c in $_ctx_calls; do
  # Walk the class, tracking the current access section, and record where the member is
  # declared. Only the context class matters here, which is everything before the effect
  # class starts.
  _sec="$(awk -v want="$_c" '
    /^  (public|private|protected):/ { sec = $1; sub(":", "", sec); next }
    $0 ~ ("[ \t*&]" want "[ \t]*\\(") { if (!found) { print sec; found = 1 } }
  ' "$SRC" | head -1)"
  case "$_sec" in
    public|'') : ;;
    *) echo "::error::AsbLoudnessContext::${_c}() is ${_sec} but the effect class calls it"
       fail=1 ;;
  esac
done

# 5. Balanced braces: a truncated or badly merged file fails here before anything else.
_open="$(tr -cd '{' < "$SRC" | wc -c)"
_close="$(tr -cd '}' < "$SRC" | wc -c)"
if [ "$_open" != "$_close" ]; then
  echo "::error::brace mismatch in asb_effect_aidl.cpp ($_open open, $_close close)"
  fail=1
fi

[ "$fail" = "0" ] || exit 1
echo "asb_effect_aidl.cpp passes the DSP source checks"
