#!/bin/sh
# Contract: every governor.conf key has one explicit ownership class, and public keys match WebUI.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONF="$ROOT/config/governor.conf"
REG="$ROOT/config/key_ownership.tsv"
LINT="$ROOT/tools/asb_lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL config ownership registry: $*" >&2; exit 1; }

[ -f "$CONF" ] || fail 'governor.conf missing'
[ -f "$REG" ] || fail 'key_ownership.tsv missing'
[ -f "$LINT" ] || fail 'asb_lint.sh missing'
sh -n "$LINT"

awk -F= '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/{k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k); print k}' "$CONF" | sort > "$TMP/conf"
awk -F'|' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
  NF != 3 {print "malformed row " NR > "/dev/stderr"; bad=1; next}
  $1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print "invalid key " $1 > "/dev/stderr"; bad=1}
  $2 !~ /^(user|advanced|internal)$/ {print "invalid class " $1 "=" $2 > "/dev/stderr"; bad=1}
  $3 !~ /^[a-z_][a-z0-9_]*$/ {print "invalid intent " $1 "=" $3 > "/dev/stderr"; bad=1}
  {print $1}
  END {exit bad}
' "$REG" | sort > "$TMP/registry" || fail 'registry row format/class vocabulary'
[ "$(wc -l < "$TMP/conf")" = "174" ] || fail "expected 174 config keys, got $(wc -l < "$TMP/conf")"
[ "$(wc -l < "$TMP/registry")" = "174" ] || fail "expected 174 registry keys, got $(wc -l < "$TMP/registry")"
[ "$(uniq -d "$TMP/registry" | wc -l)" = "0" ] || fail "duplicate registry keys: $(uniq -d "$TMP/registry" | tr '\n' ' ')"
diff -u "$TMP/conf" "$TMP/registry" >/dev/null || fail 'registry key set differs from governor.conf'

sed -n '/const CFG_ITEMS = \[/,/^\];/p' "$ROOT/webroot/index.html" \
  | grep -oE "key:'[A-Za-z_][A-Za-z0-9_]*'" | sed "s/key:'//;s/'//" | sort -u > "$TMP/cards"
[ "$(wc -l < "$TMP/cards")" = "61" ] || fail "expected 61 WebUI cards, got $(wc -l < "$TMP/cards")"
_card_bad="$(while IFS= read -r key; do
  cls="$(awk -F'|' -v k="$key" '$1==k {print $2; exit}' "$REG")"
  case "$cls" in user|advanced) : ;; *) printf '%s ' "$key" ;; esac
done < "$TMP/cards")"
[ -z "$_card_bad" ] || fail "card(s) internal or unregistered: $_card_bad"
_public="$(awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} ($2=="user" || $2=="advanced") {print $1}' "$REG" | sort)"
_public_stale="$(printf '%s\n' "$_public" | while IFS= read -r key; do grep -Fqx "$key" "$TMP/cards" || printf '%s ' "$key"; done)"
[ -z "$_public_stale" ] || fail "public registry key(s) without WebUI card: $_public_stale"

for cls in user advanced internal; do
  n="$(awk -F'|' -v c="$cls" '$2==c {n++} END{print n+0}' "$REG")"
  [ "$n" -gt 0 ] || fail "ownership class $cls is unused"
done

grep -Fq 'Config Key Ownership' "$LINT" || fail 'lint does not enforce ownership registry'
grep -Fq 'config ownership key-set drift' "$LINT" || fail 'lint lacks key-set drift failure'
grep -Fq 'WebUI/ownership drift' "$LINT" || fail 'lint lacks WebUI ownership boundary failure'

echo 'PASS config ownership registry contract (174 keys; 26 user, 35 advanced, 113 internal)'
