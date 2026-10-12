#!/system/bin/sh
# asb_dsp_live.sh - sourced, not run. What AudioFlinger is doing with ASB's effect right now
# (fix135).
#
# The reports said "effect registered with audioflinger" and nothing else, so "the sound went
# flat" could be four different things with one symptom: the gain was lowered, the attach
# daemon let go of the effect (route not selected), the effect is attached but disabled, or
# AudioFlinger SUSPENDED it. The last one is a platform rule: when any app enables an effect
# on its own audio session, every effect of the global mix on that output is suspended until
# that app's effect goes away ("well behaved effect control panels" win). A suspended effect
# still shows as registered and enabled from the client side.
#
# asb_dsp_live_state [dump file] prints one line:
#   found=1 thread=AudioOut_1D type=MIXER session=0 state=ACTIVE enabled=y suspended=n others_enabled=0
#   found=0
# others_enabled counts effects enabled on per-app sessions on the same output - the ones
# that suspend global effects. The column names are read from the dump's own header line,
# so a platform that adds or drops a column is still parsed by name.
asb_dsp_live_state() {
  if [ -n "${1:-}" ]; then
    cat "$1" 2>/dev/null
  else
    dumpsys media.audio_flinger 2>/dev/null
  fi | awk '
    /Output thread / {
      t = $0; sub(/.*name /, "", t)
      nm = t; sub(/,.*/, "", nm)
      ty = t; sub(/.*\(/, "", ty); sub(/\).*/, "", ty)
      cur = nm; curty = ty; next
    }
    /Effect ID [0-9]+:/ { hdr = ""; vals = ""; next }
    /Session .*State/ {
      hdr = $0; gsub(/:/, "", hdr)
      if ((getline line) > 0) vals = line
      next
    }
    /- UUID: / {
      n = split(hdr, H, " "); split(vals, V, " ")
      ses = ""; st = ""; en = "?"; su = "?"
      for (i = 1; i <= n; i++) {
        if (H[i] == "Session") ses = V[i]
        else if (H[i] == "State") st = V[i]
        else if (H[i] == "Enabled") en = V[i]
        else if (H[i] == "Suspended") su = V[i]
      }
      u = $NF
      if (u ~ /^a5b10001-7e55-4c60-9f21-/) {
        if (!(found && fst + 0 == 3)) {
          found = 1; fth = cur; fty = curty; fses = ses; fst = st; fen = en; fsu = su
        }
      } else if (ses != "" && ses + 0 != 0 && en == "y") {
        oth[cur]++
      }
      hdr = ""; vals = ""
    }
    END {
      if (!found) { print "found=0"; exit }
      s = fst + 0
      nmx = "?"
      if (fst != "") {
        nmx = (s == 0) ? "IDLE" : (s == 1) ? "RESTART" : (s == 2) ? "STARTING" : (s == 3) ? "ACTIVE" : \
              (s == 4) ? "STOPPING" : (s == 5) ? "STOPPED" : (s == 6) ? "DESTROYED" : "?"
      }
      printf "found=1 thread=%s type=%s session=%d state=%s enabled=%s suspended=%s others_enabled=%d\n", \
             (fth == "" ? "?" : fth), (fty == "" ? "?" : fty), fses + 0, nmx, fen, fsu, oth[fth] + 0
    }'
}

# One human line for asbdiag and the action screen.
asb_dsp_live_explain() {
  case "$1" in
    found=0*) echo "no live instance - the attach daemon is not holding the effect now (nothing playing on a selected output, or audioserver just restarted)" ;;
    *suspended=y*) echo "SUSPENDED by AudioFlinger - an app has its own effect enabled on this output, and global effects yield to it until that effect is released" ;;
    *state=ACTIVE*) echo "processing" ;;
    *enabled=n*) echo "attached but disabled" ;;
    *) echo "attached, idle (nothing playing through this output)" ;;
  esac
}
