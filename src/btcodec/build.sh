#!/bin/sh
# Builds bin/asb_btcodec.dex from src/btcodec/asb/*.java.
# Uses the Android SDK that GitHub's Ubuntu runners ship (ANDROID_HOME / ANDROID_SDK_ROOT):
# the newest platforms/android-*/android.jar and build-tools/*/d8. Only public classes are
# referenced at compile time; every hidden or system API is reached through reflection, so any
# platform jar works. A missing SDK is an error here; the workflow decides whether it is fatal.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || { echo "btcodec: Android SDK not found" >&2; exit 1; }
JAR="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
D8="$(ls -d "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)"
[ -n "$JAR" ] && [ -f "$JAR" ] || { echo "btcodec: android.jar not found" >&2; exit 1; }
[ -n "$D8" ] && [ -x "$D8" ] || { echo "btcodec: d8 not found" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/classes" "$TMP/dex" "$ROOT/bin"
javac --release 8 -nowarn -cp "$JAR" -d "$TMP/classes" "$ROOT"/src/btcodec/asb/*.java
"$D8" --release --min-api 26 --lib "$JAR" --output "$TMP/dex" $(find "$TMP/classes" -name '*.class')
install -m 0644 "$TMP/dex/classes.dex" "$ROOT/bin/asb_btcodec.dex"
echo "btcodec: bin/asb_btcodec.dex ($(wc -c < "$ROOT/bin/asb_btcodec.dex") bytes) from $(basename "$(dirname "$JAR")"), d8 $(basename "$(dirname "$D8")")"
