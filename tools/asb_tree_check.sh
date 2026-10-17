#!/bin/sh
set -u
ROOT="${ASB_TREE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
MAN="${ASB_TREE_MANIFEST:-$ROOT/tools/asb_tree.sha256}"

tree_list() {
  ( cd "$ROOT" && find . -type f \
      ! -path './.git/*' ! -path './.github/*' ! -path './src/DSP_AIDL/prebuilt/*' \
      ! -path '*/__pycache__/*' ! -name 'update.json' ! -name 'module.prop' \
      ! -path './tools/asb_tree.sha256' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort )
}

tree_hash() {
  tree_list | while IFS= read -r _f; do
    printf '%s  %s\n' "$(sha256sum "$ROOT/$_f" 2>/dev/null | cut -d' ' -f1)" "$_f"
  done
}

case "${1:-check}" in
  write)
    _tmp="$(mktemp)"
    tree_hash > "$_tmp" && mv -f "$_tmp" "$MAN" && chmod 0644 "$MAN"
    echo "tree manifest: $(wc -l < "$MAN") files"
    ;;
  check)
    if [ ! -s "$MAN" ]; then
      echo "tree manifest: none in this tree - nothing to compare"
      exit 0
    fi
    _now="$(mktemp)"; _miss="$(mktemp)"; _diff="$(mktemp)"
    tree_hash > "$_now"
    awk 'NR == FNR { have[$2] = $1; next } !($2 in have) { print $2 > "/dev/stderr"; next } have[$2] != $1 { print $2 }' \
      "$_now" "$MAN" > "$_diff" 2> "$_miss"
    _nm="$(grep -c . "$_miss")"; _nd="$(grep -c . "$_diff")"
    if [ "$_nm" = 0 ] && [ "$_nd" = 0 ]; then
      echo "tree manifest: every delivered file is here and unchanged ($(wc -l < "$MAN") files)"
    else
      echo "tree manifest: this tree is NOT the delivered one - $_nd file(s) differ, $_nm missing"
      echo "  A file uploaded late or not at all shows up here first; the test that trips over it later"
      echo "  is only a symptom. Upload these files from the delivered archive, then run again:"
      sed 's/^/    differs: /' "$_diff"
      sed 's/^/    missing: /' "$_miss"
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        while IFS= read -r _f; do echo "::warning file=$_f::differs from the delivered tree (not uploaded, or edited after delivery)"; done < "$_diff"
        while IFS= read -r _f; do echo "::warning::$_f is in the delivered tree but missing here"; done < "$_miss"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          { echo "### Tree differs from the delivered archive"; echo; sed 's/^/- differs: `/; s/$/`/' "$_diff"; sed 's/^/- missing: `/; s/$/`/' "$_miss"; } >> "$GITHUB_STEP_SUMMARY"
        fi
      fi
      rm -f "$_now" "$_miss" "$_diff"
      [ "${2:-}" = "--strict" ] && exit 1
      exit 0
    fi
    rm -f "$_now" "$_miss" "$_diff"
    ;;
esac
