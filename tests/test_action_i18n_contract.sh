#!/bin/sh
# Contract: action.sh report translations.
#
# Every runtime/i18n/action_<lang>.sh must cover every T_* key action.sh defines, with
# the same printf placeholders in the same number - a missing %s shifts every value after
# it, and a bare % makes printf eat the rest of the line. No translation may contain a
# backslash, a backtick or "$(" - the files are sourced, not parsed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$ROOT/action.sh"
DIR="$ROOT/runtime/i18n"
fail=0
f() { echo "FAIL: $*" >&2; fail=1; }

# One awk pass per language: placeholder COUNTS (%s, %%, any other %), not order -
# Turkish writes the percent sign before the number ("%%%s").
_awk='
function sig(v,  r, n1, n2, n3) {
  r = v; n2 = gsub(/%%/, "", r); n1 = gsub(/%s/, "", r); n3 = gsub(/%/, "", r)
  return "s=" n1 " pct=" n2 " bare=" n3
}
function val(line,  v) { v = line; sub(/^[A-Z0-9_]+="/, "", v); sub(/"[[:space:]]*$/, "", v); return v }
FNR == NR { if ($0 ~ /^T_[A-Z0-9_]+="/) { k = $0; sub(/=.*/, "", k); if (!(k in en)) { en[k] = val($0); order[++n] = k } } next }
$0 ~ /^T_[A-Z0-9_]+="/ { k = $0; sub(/=.*/, "", k); tr[k] = val($0) }
END {
  if (n == 0) { print "no T_* defaults in action.sh"; exit }
  for (i = 1; i <= n; i++) { k = order[i]
    if (!(k in tr)) { print lang ": missing " k; continue }
    if (sig(tr[k]) != sig(en[k])) print lang ": " k " placeholders " sig(tr[k]) " != en " sig(en[k])
  }
  for (k in tr) if (!(k in en)) print lang ": unknown key " k
}'

for lang in ru uk de es pt tr id fr hy it ar zh; do
  file="$DIR/action_${lang}.sh"
  [ -f "$file" ] || { f "missing $file"; continue; }
  sh -n "$file" 2>/dev/null || f "$lang: syntax error"
  if grep -nE '\\|`|\$\(' "$file" | grep -v '^[0-9]*:#' >/dev/null; then f "$lang: shell-unsafe character"; fi
  _out="$(awk -v lang="$lang" "$_awk" "$ACTION" "$file")"
  [ -z "$_out" ] || { echo "$_out" | while IFS= read -r l; do echo "FAIL: $l" >&2; done; fail=1; }
  # Indonesian has no learning-block strings in action.sh itself; its file must carry them.
  if [ "$lang" = id ]; then
    for k in M_CONF_LOW M_SLOT M_DP0 M_WEEKDAY M_W_HOT; do
      grep -qE "(^|[; ])$k=" "$file" || f "id: missing $k"
    done
  fi
done

grep -q 'runtime/i18n/action_${_asb_lang}.sh' "$ACTION" || f "action.sh does not load the translation file"

[ "$fail" = 0 ] && echo "PASS: action i18n contract"
exit "$fail"
