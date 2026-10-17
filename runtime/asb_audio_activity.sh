_aa_sig=""
_aa_mode=""
_aa_pid=""
_aa_tasks=""
_aa_outs=""
_aa_prev=""
_aa_s=""

_aa_runs() {
  _aa_rv=""
  if [ -r "$1/schedstat" ]; then
    read -r _aa_x _aa_y _aa_rv < "$1/schedstat" || _aa_rv=""
  elif [ -r "$1/status" ]; then
    _aa_rv=0
    while IFS= read -r _aa_l; do
      case "$_aa_l" in
        voluntary_ctxt_switches:*|nonvoluntary_ctxt_switches:*)
          _aa_n="${_aa_l#*:}"; _aa_n="${_aa_n#"${_aa_n%%[!	 ]*}"}"
          case "$_aa_n" in ''|*[!0-9]*) ;; *) _aa_rv=$((_aa_rv + _aa_n)) ;; esac ;;
      esac
    done < "$1/status"
  fi
  case "$_aa_rv" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

_aa_find_server() {
  _aa_c=""
  if [ -n "$_aa_pid" ] && [ -r "$_aa_proc/$_aa_pid/comm" ]; then
    IFS= read -r _aa_c < "$_aa_proc/$_aa_pid/comm" || _aa_c=""
  fi
  [ "$_aa_c" = audioserver ] && return 0
  _aa_pid=""; _aa_tasks=""; _aa_outs=""; _aa_prev=""
  for _aa_d in "$_aa_proc"/[0-9]*; do
    [ -r "$_aa_d/comm" ] || continue
    IFS= read -r _aa_c < "$_aa_d/comm" || continue
    if [ "$_aa_c" = audioserver ]; then _aa_pid="${_aa_d##*/}"; return 0; fi
  done
  return 1
}

asb_audio_sig() {
  _aa_snd="${ASB_AUDIO_ASOUND:-/proc/asound}"
  _aa_proc="${ASB_AUDIO_PROC:-/proc}"
  _aa_sig=""
  for _aa_f in "$_aa_snd"/card*/pcm*p/sub*/status; do
    [ -e "$_aa_f" ] || continue
    _aa_mode=pcm
    _aa_sig="$(grep -l RUNNING "$_aa_snd"/card*/pcm*p/sub*/status 2>/dev/null | tr '\n' ' ')"
    return 0
  done
  if ! _aa_find_server; then _aa_mode=""; return 0; fi
  _aa_list=""
  for _aa_t in "$_aa_proc/$_aa_pid"/task/[0-9]*; do _aa_list="$_aa_list ${_aa_t##*/}"; done
  if [ "$_aa_list" != "$_aa_tasks" ]; then
    _aa_tasks="$_aa_list"; _aa_outs=""
    for _aa_id in $_aa_list; do
      [ -r "$_aa_proc/$_aa_pid/task/$_aa_id/comm" ] || continue
      IFS= read -r _aa_c < "$_aa_proc/$_aa_pid/task/$_aa_id/comm" || continue
      case "$_aa_c" in AudioOut_*) _aa_outs="$_aa_outs $_aa_id:$_aa_c" ;; esac
    done
  fi
  _aa_next=""; _aa_seen=""
  for _aa_e in $_aa_outs; do
    _aa_id="${_aa_e%%:*}"; _aa_c="${_aa_e#*:}"
    _aa_runs "$_aa_proc/$_aa_pid/task/$_aa_id" || continue
    _aa_seen=1
    _aa_next="$_aa_next $_aa_id:$_aa_rv"
    [ -n "$_aa_prev" ] || continue
    case "$_aa_prev " in
      *" $_aa_id:"*) _aa_o="${_aa_prev#* $_aa_id:}"; _aa_o="${_aa_o%% *}" ;;
      *) _aa_o=0 ;;
    esac
    case "$_aa_o" in ''|*[!0-9]*) _aa_o=0 ;; esac
    [ $((_aa_rv - _aa_o)) -ge "${ASB_AUDIO_RUNS_MIN:-2}" ] && _aa_sig="$_aa_sig$_aa_c "
  done
  if [ -z "$_aa_seen" ]; then _aa_mode=""; _aa_prev=""; return 0; fi
  if [ -n "$_aa_prev" ]; then _aa_mode=threads; else _aa_mode=""; fi
  _aa_prev="$_aa_next"
  return 0
}

asb_audio_screen() {
  _aa_s=""
  _aa_st="${ASB_AUDIO_STATE:-/dev/.asb/state}"
  [ -r "$_aa_st" ] || return 0
  while IFS= read -r _aa_l; do
    case "$_aa_l" in screen=*) _aa_s="${_aa_l#screen=}"; return 0 ;; esac
  done < "$_aa_st"
  return 0
}
