#!/bin/sh
# Contract: action.sh never calls a helper before the line that defines it.
# A fix44 block called _st above its definition and the report printed "_st: not found".
set -u
A="$(cd "$(dirname "$0")/.." && pwd)/action.sh"
fail=0
for h in _st _cfg _feat _s _f _join; do
  d="$(grep -n "^$h() *{" "$A" | head -1 | cut -d: -f1)"
  [ -n "$d" ] || continue
  u="$(grep -nE "(\\\$\\(|^[[:space:]]*|[;&|] *)$h " "$A" | grep -v "^$d:" | head -1 | cut -d: -f1)"
  [ -n "$u" ] && [ "$u" -lt "$d" ] && { echo "FAIL action helper order: $h used on line $u, defined on line $d" >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "PASS action helper order"
exit "$fail"
