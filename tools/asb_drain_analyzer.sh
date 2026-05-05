#!/system/bin/sh
# asb_drain_analyzer.sh — compute battery drain rate from 2 logkit captures
#
# Usage:
#   asb_drain_analyzer.sh <START_LOGKIT_DIR> <END_LOGKIT_DIR>
#
# Reads the governor.log from each capture, extracts heartbeat lines with
# bat=N (battery percentage) and timestamp. Computes:
#   - Total drain over the window
#   - Avg drain rate %/hour
#   - Drain rate by profile (estimated from time-in-profile share)
#   - Drain rate by state band (DEEP_IDLE / LIGHT_IDLE / MODERATE+ )
#
# Heuristic, not perfect: a capture window with mixed profiles/states
# attributes drain proportionally to time spent in each. Still useful for
# profile A vs profile B comparison if you control conditions.

START_DIR="$1"
END_DIR="$2"

if [ -z "$START_DIR" ] || [ -z "$END_DIR" ]; then
    echo "usage: $0 <start_logkit_dir> <end_logkit_dir>" >&2
    echo "Each dir must contain governor.log from logkit capture." >&2
    exit 1
fi

if [ ! -f "$START_DIR/governor.log" ] || [ ! -f "$END_DIR/governor.log" ]; then
    echo "ERROR: governor.log not found in one of the dirs." >&2
    exit 1
fi

# Combine both logs in time order. Heartbeats look like:
# [05-04 23:48:47] heartbeat: state=LIGHT_IDLE profile=0 ... bat=68 ...
# Timestamps are MM-DD HH:MM:SS (no year). For drain calc we need monotonic
# epoch — assume all entries are within current year.

YEAR=$(date +%Y)
TODAY_EPOCH=$(date +%s)

cat "$START_DIR/governor.log" "$END_DIR/governor.log" 2>/dev/null \
    | grep "heartbeat" \
    | sort -u \
    > /tmp/asb_drain_combined.txt

LINES=$(wc -l < /tmp/asb_drain_combined.txt 2>/dev/null || echo 0)
if [ "$LINES" -lt 2 ]; then
    echo "ERROR: need at least 2 heartbeat lines, got $LINES" >&2
    exit 1
fi

echo "Heartbeat samples: $LINES"

# Parse each line into: epoch_ts profile state bat
awk -v year="$YEAR" '
/heartbeat/ {
    # Extract [MM-DD HH:MM:SS]
    if (match($0, /\[[0-9]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+\]/)) {
        ts = substr($0, RSTART+1, RLENGTH-2)
        gsub(/[\[\]]/, "", ts)
        # ts = "MM-DD HH:MM:SS"
        split(ts, t1, " ")
        split(t1[1], d, "-")
        split(t1[2], h, ":")
        cmd = "date -d \"" year "-" d[1] "-" d[2] " " h[1] ":" h[2] ":" h[3] "\" +%s 2>/dev/null"
        epoch = ""
        cmd | getline epoch
        close(cmd)
    }
    profile = ""; state = ""; bat = ""
    if (match($0, /profile=[0-9]/)) profile = substr($0, RSTART+8, 1)
    if (match($0, /state=[A-Z_]+/))  state = substr($0, RSTART+6, RLENGTH-6)
    if (match($0, /bat=[0-9]+/))     bat = substr($0, RSTART+4, RLENGTH-4)
    if (epoch != "" && bat != "") print epoch, profile, state, bat
}
' /tmp/asb_drain_combined.txt | sort -n > /tmp/asb_drain_parsed.tsv

PARSED=$(wc -l < /tmp/asb_drain_parsed.tsv 2>/dev/null || echo 0)
echo "Parsed rows: $PARSED"

if [ "$PARSED" -lt 2 ]; then
    echo "ERROR: parsed less than 2 rows. Check log format." >&2
    head -3 /tmp/asb_drain_combined.txt
    exit 1
fi

awk '
BEGIN {
    state_band["DEEP_IDLE"] = "idle"
    state_band["LIGHT_IDLE"] = "idle"
    state_band["MODERATE"] = "active"
    state_band["HEAVY"] = "active"
    state_band["SUSTAINED"] = "active"
    state_band["GAMING"] = "active"
    profile_name[0] = "battery"
    profile_name[1] = "balanced"
    profile_name[2] = "performance"
}
NR==1 {
    first_ts = $1; first_bat = $4
    prev_ts = $1; prev_bat = $4
    next
}
{
    cur_ts = $1; cur_profile = $2; cur_state = $3; cur_bat = $4
    delta_t = cur_ts - prev_ts
    delta_b = prev_bat - cur_bat   # drain is positive when battery decreases
    if (delta_t > 0 && delta_t < 3600) {
        # Attribute this delta to current profile/state band
        pname = profile_name[cur_profile + 0]
        if (pname == "") pname = "?"
        time_in_profile[pname] += delta_t
        drain_in_profile[pname] += delta_b

        sband = state_band[cur_state]
        if (sband == "") sband = "?"
        time_in_band[sband] += delta_t
        drain_in_band[sband] += delta_b

        total_t += delta_t
        total_b += delta_b
    }
    prev_ts = cur_ts; prev_bat = cur_bat
    last_ts = cur_ts; last_bat = cur_bat
}
END {
    print ""
    print "===== BATTERY DRAIN ANALYSIS ====="
    printf "Window: %d seconds = %.1f hours\n", total_t, total_t/3600.0
    printf "Total drain: %d%%\n", total_b
    if (total_t > 0) printf "Avg drain rate: %.2f %%/hour\n", total_b * 3600.0 / total_t
    print ""
    print "BY PROFILE:"
    for (p in time_in_profile) {
        t = time_in_profile[p]
        d = drain_in_profile[p]
        if (t > 0) {
            printf "  %-12s time=%6ds (%.1f%%)  drain=%d%%  rate=%.2f %%/h\n", \
                p, t, t*100.0/total_t, d, d*3600.0/t
        }
    }
    print ""
    print "BY STATE BAND:"
    for (b in time_in_band) {
        t = time_in_band[b]
        d = drain_in_band[b]
        if (t > 0) {
            printf "  %-12s time=%6ds (%.1f%%)  drain=%d%%  rate=%.2f %%/h\n", \
                b, t, t*100.0/total_t, d, d*3600.0/t
        }
    }
}
' /tmp/asb_drain_parsed.tsv

rm -f /tmp/asb_drain_combined.txt /tmp/asb_drain_parsed.tsv
