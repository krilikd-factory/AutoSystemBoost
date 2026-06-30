#!/system/bin/sh
ME="${0##*/}"
DIR="${0%/*}"
[ "$DIR" = "$ME" ] && DIR="."

PY="$DIR/asb_field_report.py"
if [ ! -r "$PY" ]; then
  for _alt in /data/adb/modules/AutoSystemBoost/tools/asb_field_report.py \
              /data/adb/modules_update/AutoSystemBoost/tools/asb_field_report.py; do
    [ -r "$_alt" ] && PY="$_alt" && break
  done
fi
if [ ! -r "$PY" ]; then
  echo "ERROR: asb_field_report.py not found near $DIR or in module paths" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install Termux 'python' package or run with /usr/bin/python3." >&2
  exit 3
fi

DEFAULT_INPUT="/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl"
DEFAULT_RECOVERY="/dev/.asb/recovery.json"

USAGE() {
  cat <<EOF
ASB  Field Report

Usage: $ME [options]

Options:
  -i, --input FILE       session_history.jsonl path
                         (default: $DEFAULT_INPUT)
  -r, --recovery FILE    recovery.json path
                         (default: $DEFAULT_RECOVERY)
  -o, --text-out FILE    Write text report to FILE
      --json-out FILE    Write JSON report to FILE
      --no-bands         Skip duration band breakdown
  -q, --quiet            Suppress stdout (use with -o or --json-out)
  -h, --help             This help

Examples:
  $ME
  $ME -o /sdcard/asb_field_report.txt
  $ME -i /sdcard/session_history.jsonl --json-out /sdcard/asb.json
EOF
}

case "${1:-}" in
  -h|--help) USAGE; exit 0 ;;
esac

exec python3 "$PY" "$@"
