#!/usr/bin/env python3
"""Quiet Night must never leave the metrics-skip flag set after the mode ends.

The first implementation cleared the flag in the else branch of the "is this a skipping
tick" test, which sits inside `if (g_quiet_night_active)`. So the reset only ran while the
mode was still active: if Quiet Night ended on a skipping tick, the flag stayed set and
metrics_read_battery() returned immediately for the rest of the session.

That is worse than the economy it buys. Current, voltage, temperature and level feed
auto-battery switching, charge awareness, the drain the learner banks and the
time-to-empty estimates - all of which would silently run on values read hours earlier.

This test reads the source rather than running the daemon, because the bug is structural:
it is about WHERE the reset lives, and that is exactly what a behavioural test on a
short run would miss.
"""
import re
import sys
import pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / "src" / "asb_governor.c"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def main():
    text = SRC.read_text(encoding="utf-8", errors="replace")

    if "g_qn_skip_this_tick" not in text:
        print("SKIP: Quiet Night skip flag not present in this build")
        return

    # Per-tick resets only. `int g_qn_skip_this_tick = 0;` is the definition, not a
    # reset - counting it made the first version of this test pass against the very bug it
    # was written for, because a definition at the top of the file is trivially "before
    # the guard".The check is done on the whole line: a definition carries a type, a reset
    # does not.
    reset = []
    for m in re.finditer(r"g_qn_skip_this_tick\s*=\s*0\s*;", text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line = text[line_start:m.end()]
        if re.match(r"\s*(static\s+)?int\s+", line):
            continue          # definition
        reset.append(m.start())

    setit = [m.start() for m in re.finditer(r"g_qn_skip_this_tick\s*=\s*1\s*;", text)]

    if not reset:
        fail("the flag is set but never cleared - it would stay on for the whole session")
    if not setit:
        fail("the flag is cleared but never set - Quiet Night saves nothing")

    # The relevant guard is the one that owns the skip flag, not the first
    # `if (g_quiet_night_active)` in the file - there are three, and anchoring on the
    # wrong one made this test report a failure on correct code. Locate it by the line
    # that sets the flag and walk back.
    set_pos = setit[0]
    guard = text.rfind("if (g_quiet_night_active)", 0, set_pos)
    if guard < 0:
        fail("cannot locate the Quiet Night guard that owns the skip flag")

    # The reset must belong to THIS block, not merely appear earlier in the file.
    #
    # The first version asked only `any(pos < guard)`, which a mutation defeats trivially:
    # delete the real per-tick reset, add a meaningless one next to the global definition,
    # and the test still passes while the bug is fully restored. File order is not
    # ownership.
    #
    # Scope is bounded by the enclosing metrics block. Anything outside it is in a
    # different control-flow path and cannot clear the flag on the ticks that matter -
    # the ones after Quiet Night has ended.
    block_start = text.rfind("if (need_metrics)", 0, guard)
    if block_start < 0:
        block_start = text.rfind("\n\n", 0, guard)

    local = [pos for pos in reset if block_start < pos < guard]
    if len(local) != 1:
        fail("expected exactly one per-tick reset between the metrics block and the "
             "Quiet Night guard, found %d - a reset elsewhere in the file does not run "
             "on the ticks after the mode ends" % len(local))

    # And nothing may close a scope between the reset and the guard: a reset that sits
    # inside a brace that ends before the guard is in a different block again.
    between = text[local[0]:guard]
    if between.count("}") > between.count("{"):
        fail("the reset is separated from the guard by a closing brace - it is in a "
             "different scope and will not run every tick")

    if any(pos < guard for pos in setit):
        fail("the flag is set outside the Quiet Night guard - reads would be skipped "
             "during normal operation")

    print("PASS: skip flag is cleared unconditionally before the Quiet Night guard")


if __name__ == "__main__":
    main()
