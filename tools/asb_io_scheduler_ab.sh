#!/system/bin/sh
# One-shot, restoring I/O-scheduler A/B runner. It never chooses or persists a winner.
# fio runs only against a NEW regular test file; raw devices and existing files are refused.
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ROOT="${ASB_IO_BLOCK_ROOT:-/sys/block}"
LOCK="${ASB_IO_AB_LOCK:-/data/adb/asb/io_scheduler_ab.lock}"
CANDIDATES="adios kyber mq-deadline bfq none"
SECS=8; SIZE=64M; ROUNDS=2; TEST_FILE=""; DEVS=""; OUTS=""
TEST_ROOT="${ASB_IO_AB_TEST_ROOT:-/data/local/tmp}"

usage() {
  cat <<'EOF'
Usage:
  asb_io_scheduler_ab.sh status
  asb_io_scheduler_ab.sh recover
  asb_io_scheduler_ab.sh run --file /data/local/tmp/asb-io-ab.fio [--seconds 8] [--size 64M] [--rounds 2]

Runs interleaved fio randrw passes only on schedulers exposed by every physical queue,
prints clat p50/p95/p99, restores every original scheduler and removes its new test file.
No winner is selected and no setting is persisted. Existing files/raw devices are refused.
EOF
}
_name() { case "$1" in ''|[!a-z0-9]*|*[!a-z0-9_-]*) return 1;; esac; [ "${#1}" -le 32 ]; }
_dev() { case "$1" in sd[a-z]*|mmcblk[0-9]*|nvme[0-9]*n[0-9]*|dm-[0-9]*) case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac;; *) return 1;; esac; }
_node() { _dev "$1" || return 1; printf '%s/%s/queue/scheduler\n' "$ROOT" "$1"; }
_options() { cat "$1" 2>/dev/null | tr '[]' '  '; }
_active() { _options "$1" | awk '{for(i=1;i<=NF;i++)if($i!=""){print $i;exit}}'; }
# The bracket-removing _options helper loses the active marker, so read it separately.
_current() { cat "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i~/^\[.*\]$/){gsub(/[][]/,"",$i);print $i;exit}}'; }
_readback() {
  _rb_i=0
  _rb_n="${ASB_IO_AB_READBACK_TRIES:-20}"
  case "$_rb_n" in ''|*[!0-9]*) _rb_n=20 ;; esac
  [ "$_rb_n" -ge 1 ] && [ "$_rb_n" -le 1000 ] || _rb_n=20
  while [ "$_rb_i" -lt "$_rb_n" ]; do
    [ "$(_current "$1")" = "$2" ] && return 0
    sleep 0.01
    _rb_i=$((_rb_i+1))
  done
  return 1
}
_has_opt() { printf '%s\n' "$(_options "$1")" | awk -v n="$2" '{for(i=1;i<=NF;i++)if($i==n)ok=1}END{exit !ok}'; }
_discover() {
  DEVS=""
  for d in "$ROOT"/*; do
    [ -d "$d/queue" ] || continue; n=${d##*/}; _dev "$n" || continue
    [ "$(cat "$d/queue/rotational" 2>/dev/null)" = 1 ] && continue
    [ -r "$d/queue/scheduler" ] || continue
    [ -f "$d/device" ] || [ -d "$d/device" ] || [ -L "$d/device" ] || continue
    DEVS="$DEVS $n"
  done
  [ -n "$DEVS" ]
}
status() {
  _discover || { echo 'status=not_exposed'; return 0; }
  for n in $DEVS; do node=$(_node "$n"); printf 'queue=%s active=%s available=%s\n' "$n" "$(_current "$node")" "$(_options "$node" | tr -s ' ')"; done
}
_bootid() { cat "${ASB_IO_AB_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null; }
_restore() {
  [ -f "$LOCK/ready" ] || { echo 'restore_failed reason=incomplete_baseline'; return 1; }
  _restore_failed=0
  for _entry in "$LOCK"/*.orig; do
    [ -f "$_entry" ] || continue
    n=${_entry##*/}; n=${n%.orig}
    _dev "$n" || { _restore_failed=1; continue; }
    orig="$(cat "$_entry" 2>/dev/null)"; node=$(_node "$n") || { _restore_failed=1; continue; }
    _name "$orig" || { _restore_failed=1; continue; }
    if ! printf '%s\n' "$orig" > "$node" 2>/dev/null || ! _readback "$node" "$orig"; then
      printf 'restore_failed queue=%s wanted=%s actual=%s\n' "$n" "$orig" "$(_current "$node")"
      _restore_failed=1
    fi
  done
  [ "$_restore_failed" = 0 ] || return 1
  for _entry in "$LOCK"/*.orig; do [ ! -f "$_entry" ] || rm -f -- "$_entry"; done
  rm -f -- "$LOCK/boot_id" "$LOCK/pid" "$LOCK/ready"
  return 0
}
_finish() {
  _exit=$1
  trap - EXIT HUP INT TERM
  [ -z "${_cur_file:-}" ] || rm -f -- "$_cur_file" 2>/dev/null || true
  for o in $OUTS; do rm -f -- "$o" 2>/dev/null || true; done
  if _restore; then
    rmdir "$LOCK" 2>/dev/null || true
    if [ "$_exit" = 0 ] && [ "${_run_failed:-0}" = 0 ]; then
      echo 'verdict=complete_no_auto_selection original_schedulers_restored=1'
      exit 0
    fi
    echo 'verdict=degraded original_schedulers_restored=1'
    [ "$_exit" -ne 0 ] || _exit=1
    exit "$_exit"
  fi
  echo 'verdict=restore_failed original_schedulers_restored=0 recovery_ledger_retained=1'
  exit 1
}
recover() {
  [ -d "$LOCK" ] || { echo 'error=no_recovery_ledger'; return 1; }
  _saved_boot="$(cat "$LOCK/boot_id" 2>/dev/null)"; _current_boot="$(_bootid)"
  [ -n "$_saved_boot" ] && [ "$_saved_boot" = "$_current_boot" ] || { echo 'error=boot_identity_mismatch'; return 1; }
  _pid="$(cat "$LOCK/pid" 2>/dev/null)"
  case "$_pid" in ''|*[!0-9]*) ;; *) kill -0 "$_pid" 2>/dev/null && { echo 'error=worker_running'; return 1; } ;; esac
  if _restore; then
    for _result in "$LOCK"/fio.*.json; do [ ! -f "$_result" ] || rm -f -- "$_result"; done
    if rmdir "$LOCK" 2>/dev/null; then
      echo 'verdict=recovered original_schedulers_restored=1'
    else
      echo 'verdict=recovered original_schedulers_restored=1 lock_retained=1'
    fi
  else echo 'error=restore_failed recovery_ledger_retained=1'; return 1; fi
}
_fail() { echo "error=$*"; return 1; }
_pct() {
  # fio JSON clat_ns percentile object; awk needs no jq/Python on the phone.
  awk '/"clat_ns"[[:space:]]*:/ {inclat=1} inclat && /"percentile"/ {p=1} p && /"(50|95|99)\.0+"/ {
    gsub(/[",:]/," "); for(i=1;i<=NF;i++) if($i+0==$i) v[($i+0)]=$(i+1)
  } inclat && /^[[:space:]]*}[,]?[[:space:]]*$/ && p {exit} END {printf "p50=%s p95=%s p99=%s",v[50],v[95],v[99]}' "$1"
}
run() {
  while [ "$#" -gt 0 ]; do case "$1" in
    --file) TEST_FILE=${2:-}; shift 2;; --seconds) SECS=${2:-}; shift 2;;
    --size) SIZE=${2:-}; shift 2;; --rounds) ROUNDS=${2:-}; shift 2;; *) usage; return 2;; esac; done
  case "$SECS" in ''|*[!0-9]*) return 2;; esac; [ "$SECS" -ge 2 ] && [ "$SECS" -le 60 ] || return 2
  case "$ROUNDS" in ''|*[!0-9]*) return 2;; esac; [ "$ROUNDS" -ge 1 ] && [ "$ROUNDS" -le 4 ] || return 2
  case "$SIZE" in [1-9][0-9]*[MG]) ;; *) return 2;; esac
  case "$TEST_FILE" in "$TEST_ROOT"/*|/data/media/0/*) ;; *) _fail unsafe_test_path; return 1;; esac
  [ -n "$TEST_FILE" ] && [ ! -e "$TEST_FILE" ] && [ ! -L "$TEST_FILE" ] || { _fail test_file_must_be_new; return 1; }
  command -v fio >/dev/null 2>&1 || { _fail fio_not_installed; return 1; }
  _discover || { _fail no_physical_queues; return 1; }
  mkdir "$LOCK" 2>/dev/null || { _fail busy; return 1; }
  _boot="$(_bootid)"; [ -n "$_boot" ] || { rmdir "$LOCK" 2>/dev/null || true; _fail boot_identity_unknown; return 1; }
  printf '%s\n' "$_boot" > "$LOCK/boot_id" && printf '%s\n' "$$" > "$LOCK/pid" || {
    # No scheduler write or baseline has happened yet; only remove our own fresh lock.
    rm -f "$LOCK/boot_id" "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    _fail ledger_write_failed; return 1;
  }
  _run_failed=0; _cur_file=""
  trap '_finish $?' EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  for n in $DEVS; do node=$(_node "$n"); orig=$(_current "$node"); _name "$orig" || { _fail invalid_baseline; return 1; }
    printf '%s\n' "$orig" > "$LOCK/$n.orig" || { _fail baseline_save_failed; return 1; }; done
  printf '%s\n' ready > "$LOCK/ready" || { _fail baseline_save_failed; return 1; }
  usable=""
  for s in $CANDIDATES; do ok=1; for n in $DEVS; do _has_opt "$(_node "$n")" "$s" || ok=0; done
    [ "$ok" = 1 ] && usable="$usable $s" || printf 'skip scheduler=%s reason=not_exposed_on_every_queue\n' "$s"; done
  [ -n "$usable" ] || { _fail no_common_schedulers; return 1; }
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    for s in $usable; do
      ok=1; for n in $DEVS; do node=$(_node "$n"); printf '%s\n' "$s" > "$node" 2>/dev/null || ok=0
        _readback "$node" "$s" || ok=0; done
      [ "$ok" = 1 ] || { _run_failed=1; printf 'run scheduler=%s round=%s verdict=write_or_readback_failed\n' "$s" "$r"; continue; }
      _cur_file="$(mktemp "${TEST_FILE}.r${r}.${s}.XXXXXX")" || { _run_failed=1; continue; }
      o="$LOCK/fio.$r.$s.json"; OUTS="$OUTS $o"
      if fio --name=asb_scheduler_ab --filename="$_cur_file" --rw=randrw --rwmixread=70 \
          --bs=128k --size="$SIZE" --runtime="$SECS" --time_based=1 --direct=1 \
          --ioengine=psync --numjobs=1 --group_reporting=1 --output-format=json --output="$o" >/dev/null 2>&1; then
        printf 'run scheduler=%s round=%s %s\n' "$s" "$r" "$(_pct "$o")"
      else _run_failed=1; printf 'run scheduler=%s round=%s verdict=fio_failed\n' "$s" "$r"; fi
      rm -f -- "$_cur_file"; _cur_file=""
    done; r=$((r+1)); done
}
case "${1:-}" in status) status;; recover) recover;; run) shift; run "$@";; *) usage; exit 2;; esac
