#!/system/bin/sh
# Binder-safe AppOps transport. Some ColorOS builds let the Java appops client
# print "Failure calling service appops" and still exit 0. Never parse that as
# an empty/default op: retry through the native cmd bridge and fail honestly.
asb_appops() {
  _aso_out="$(appops "$@" 2>&1)"; _aso_rc=$?
  if [ "$_aso_rc" -eq 0 ]; then
    case "$_aso_out" in
      *'Failure calling service appops'*|*'Failed transaction'*|*'Exception occurred while executing'*) : ;;
      *) printf '%s\n' "$_aso_out"; return 0 ;;
    esac
  fi
  if command -v cmd >/dev/null 2>&1; then
    _aso_out2="$(cmd appops "$@" 2>&1)"; _aso_rc2=$?
    if [ "$_aso_rc2" -eq 0 ]; then
      case "$_aso_out2" in
        *'Failure calling service appops'*|*'Failed transaction'*|*'Exception occurred while executing'*) : ;;
        *) printf '%s\n' "$_aso_out2"; return 0 ;;
      esac
    fi
  fi
  return 1
}
