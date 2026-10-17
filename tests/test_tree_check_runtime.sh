#!/bin/sh
# Runtime (fix161): CI names every file that differs from the delivered tree.
#
# The fix160 debug build failed with "FAIL dsp stereo width: legacy effect does not apply the
# width". The test was right: src/DSP/asb_dsp.c in the repository was still the fix159 file - it
# had not been uploaded with the rest of the delivery (CHANGELOG.md neither, hence the lint
# warning "no section heading for V65"). The real tools/asb_tree_check.sh is run on a made-up
# tree: unchanged, one file edited, one missing, the files it must ignore, CI annotations and
# the --strict exit.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/asb_tree_check.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL tree check: $*" >&2; fail=1; }
for w in build-debug build-release; do
  grep -q 'run: sh tools/asb_tree_check.sh check' "$ROOT/.github/workflows/$w.yml" || f "$w.yml does not check the tree"
done
mkdir -p "$T/r/src/DSP" "$T/r/tools" "$T/r/.github/workflows" "$T/r/src/DSP_AIDL/prebuilt"
echo a > "$T/r/src/DSP/asb_dsp.c"; echo b > "$T/r/CHANGELOG.md"; echo c > "$T/r/service.sh"
echo v > "$T/r/module.prop"; echo u > "$T/r/update.json"; echo w > "$T/r/.github/workflows/x.yml"; echo p > "$T/r/src/DSP_AIDL/prebuilt/lib.so"
export ASB_TREE_ROOT="$T/r"
out="$(sh "$C" write)"; printf '%s\n' "$out" | grep -q 'tree manifest: 3 files' || f "manifest should hold the 3 source files: $out"
grep -q 'module.prop\|update.json\|\.github\|prebuilt' "$T/r/tools/asb_tree.sha256" && f "manifest lists files the owner edits or CI builds"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'every delivered file is here and unchanged (3 files)' || f "clean tree not recognised: $out"
echo v2 > "$T/r/module.prop"; echo w2 > "$T/r/.github/workflows/x.yml"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'unchanged' || f "edits to module.prop or a workflow were reported: $out"
echo old > "$T/r/src/DSP/asb_dsp.c"; rm "$T/r/CHANGELOG.md"
out="$(sh "$C" check)"; rc=$?
[ "$rc" = 0 ] || f "a differing tree failed the step without --strict"
printf '%s\n' "$out" | grep -q 'this tree is NOT the delivered one - 1 file(s) differ, 1 missing' || f "summary line: $out"
printf '%s\n' "$out" | grep -qx '    differs: src/DSP/asb_dsp.c' || f "the stale file is not named: $out"
printf '%s\n' "$out" | grep -qx '    missing: CHANGELOG.md' || f "the missing file is not named: $out"
out="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/sum" sh "$C" check)"
printf '%s\n' "$out" | grep -q '^::warning file=src/DSP/asb_dsp.c::' || f "no CI annotation: $out"
grep -q 'differs: `src/DSP/asb_dsp.c`' "$T/sum" || f "no job summary"
sh "$C" check --strict >/dev/null 2>&1 && f "--strict passed a differing tree"
rm -f "$T/r/tools/asb_tree.sha256"
out="$(sh "$C" check)"; printf '%s\n' "$out" | grep -q 'none in this tree' || f "no manifest should be said, not failed: $out"
[ "$fail" = 0 ] && echo "PASS tree check: files that differ from the delivered tree are named in CI before any test trips over them"
exit "$fail"
