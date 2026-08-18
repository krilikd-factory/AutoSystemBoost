#!/usr/bin/env sh
# Keep the bootstrap baseline derived from the canonical active schema.
# governor.conf is the one source of keys/defaults; governor.conf.shipped is a
# generated bootstrap copy for installation/fallback and must never diverge.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CANONICAL="${ASB_SCHEMA_CANONICAL:-$ROOT/config/governor.conf}"
SHIPPED="${ASB_SCHEMA_SHIPPED:-$ROOT/config/governor.conf.shipped}"

keys() {
  awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {p=index($0,"="); if(!p)next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); print k}' "$1" | LC_ALL=C sort -u
}

case "${1:-check}" in
  sync)
    cp "$CANONICAL" "$SHIPPED.tmp.$$"
    chmod 0644 "$SHIPPED.tmp.$$" 2>/dev/null || true
    mv -f "$SHIPPED.tmp.$$" "$SHIPPED"
    echo "synced $(basename "$SHIPPED") from $(basename "$CANONICAL")"
    ;;
  check)
    if ! [ -r "$CANONICAL" ] || ! [ -r "$SHIPPED" ]; then
      echo 'schema source unavailable' >&2
      exit 1
    fi
    if ! cmp -s "$CANONICAL" "$SHIPPED"; then
      echo 'schema drift: config/governor.conf.shipped must be generated from config/governor.conf' >&2
      diff -u "$SHIPPED" "$CANONICAL" >&2 || true
      exit 1
    fi
    echo 'PASS schema sync'
    ;;
  *) echo "usage: $0 [check|sync]" >&2; exit 2 ;;
esac
