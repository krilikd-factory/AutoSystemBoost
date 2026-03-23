#!/bin/bash
# asb_release_pack.sh — Clean release builder for AutoSystemBoost
# Usage: bash tools/asb_release_pack.sh [output.zip]

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-AutoSystemBoost-release.zip}"

echo "=== ASB Release Packer ==="
echo "Source: $SCRIPT_DIR"

# Hygiene: remove artifacts
echo "[clean] Removing __pycache__, *.pyc, *.tmp..."
find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -name "*.tmp" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -name "*.bak" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -name "*.bak.json" -delete 2>/dev/null || true

# Remove stale runtime state (should not ship)
echo "[clean] Removing stale runtime state..."
rm -f "$SCRIPT_DIR/runtime/session_history.jsonl" 2>/dev/null || true
rm -f "$SCRIPT_DIR/runtime/session_stats.json" 2>/dev/null || true
rm -f "$SCRIPT_DIR/runtime/pstats_battery.json" 2>/dev/null || true
rm -f "$SCRIPT_DIR/runtime/pstats_balanced.json" 2>/dev/null || true
rm -f "$SCRIPT_DIR/runtime/pstats_performance.json" 2>/dev/null || true
rm -f "$SCRIPT_DIR/runtime/build_manifest.json" 2>/dev/null || true

# Reset current_profile to default
echo "balanced" > "$SCRIPT_DIR/current_profile"

# Verify key files exist
echo "[verify] Checking key files..."
MISSING=0
for f in module.prop service.sh customize.sh config/governor.conf \
         profiles/performance.sh profiles/battery.sh profiles/balanced.sh \
         src/asb_governor.c src/asb_config.h src/asb_fsm.h; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "  MISSING: $f"
        MISSING=$((MISSING + 1))
    fi
done

# Verify permissions
echo "[verify] Checking shell script permissions..."
find "$SCRIPT_DIR" -name "*.sh" ! -perm -u+x -exec chmod +x {} \; 2>/dev/null

# Check for test artifacts
echo "[verify] Checking for test artifacts..."
for pat in "test_*" "debug_*" "*.log" "*.old"; do
    found=$(find "$SCRIPT_DIR" -maxdepth 2 -name "$pat" 2>/dev/null | head -3)
    [ -n "$found" ] && echo "  WARNING: found $pat files: $found"
done

if [ $MISSING -gt 0 ]; then
    echo "ERROR: $MISSING key files missing, aborting"
    exit 1
fi

# Pack
echo "[pack] Creating $OUT..."
cd "$SCRIPT_DIR"
zip -r "$OUT" . \
    -x ".git/*" "*.zip" "__pycache__/*" "*.pyc" "*.tmp" "*.bak" \
    "*.bak.json" "tools/asb_release_pack.sh" 2>&1 | tail -3

echo "=== Done: $OUT ==="
echo "Size: $(du -h "$OUT" | cut -f1)"
