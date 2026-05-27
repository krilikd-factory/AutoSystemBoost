#!/usr/bin/env python3
"""
ASB V47 Field Report — aggregate analysis of session_history.jsonl.

Focuses on V47 schema v11 fields collected for V47 decisions:
  - would_be_noisy candidate flag (P1a)
  - adv_score / adv_active / adv_would_bias / per-zone votes (P2)
  - recovery.json state (P0)

Outputs per-profile distributions, percentiles, histograms.
Does NOT make recommendations — pure data presentation.

Usage:
  asb_field_report.py [--input PATH] [--recovery PATH]
                      [--text-out FILE] [--json-out FILE]
                      [--bands] [--quiet]

Defaults:
  --input    /data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl
  --recovery /dev/.asb/recovery.json
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime


DEFAULT_INPUT = "/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl"
DEFAULT_RECOVERY = "/dev/.asb/recovery.json"

TRUST_LABELS = {0: "DIRTY", 1: "PARTIAL", 2: "CLEAN", 3: "NOISY", -1: "no-data"}
INTENT_NAMES = ["benchmark", "gaming", "sleep_idle", "mixed", "video", "unknown"]


def load_sessions(path):
    if not os.path.exists(path):
        return []
    sessions = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                sessions.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return sessions


def load_recovery(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.loads(f.read())
    except (json.JSONDecodeError, OSError):
        return None


def pct(num, denom):
    if denom == 0:
        return 0.0
    return (num * 100.0) / denom


def percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def hist_bins(values, edges):
    """Return [(label, count)] for values bucketed by edges."""
    if not values:
        return []
    counts = [0] * (len(edges) + 1)
    for v in values:
        placed = False
        for i, e in enumerate(edges):
            if v < e:
                counts[i] += 1
                placed = True
                break
        if not placed:
            counts[-1] += 1
    labels = []
    prev = None
    for e in edges:
        labels.append(f"{prev if prev is not None else 0}-{e}" if prev is not None else f"<{e}")
        prev = e
    labels.append(f">={edges[-1]}" if edges else "all")
    return list(zip(labels, counts))


def session_dur_band(dur_s):
    """Classify session by duration."""
    if dur_s < 600:
        return "<10m"
    if dur_s < 1800:
        return "10-30m"
    if dur_s < 3600:
        return "30-60m"
    if dur_s < 10800:
        return "1-3h"
    return ">=3h"


def avg(vals):
    if not vals:
        return None
    return sum(vals) / len(vals)


def fmt_n(x, decimals=1):
    if x is None:
        return "—"
    if isinstance(x, int):
        return str(x)
    return f"{x:.{decimals}f}"


def fmt_pct(num, denom):
    if denom == 0:
        return "—"
    return f"{pct(num, denom):.1f}%"


def fmt_hms(sec):
    if sec is None or sec <= 0:
        return "—"
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}h{m:02d}m"
    return f"{m}m{s:02d}s" if m > 0 else f"{s}s"


def aggregate(sessions):
    """Build per-profile aggregates."""
    by_profile = defaultdict(list)
    for s in sessions:
        prof = s.get("profile", "unknown")
        by_profile[prof].append(s)

    result = {
        "total_sessions": len(sessions),
        "profiles": {},
        "schema_versions": Counter(s.get("v", "?") for s in sessions),
        "asb_versions": Counter(s.get("asb", "?") for s in sessions),
    }

    for prof, sl in by_profile.items():
        result["profiles"][prof] = profile_summary(prof, sl)

    return result


def profile_summary(prof, sessions):
    """Compute aggregate stats for one profile's sessions."""
    out = {
        "profile": prof,
        "session_count": len(sessions),
    }

    durs = [s.get("dur", 0) for s in sessions if s.get("dur", 0) > 0]
    out["total_duration_s"] = sum(durs)
    out["avg_duration_s"] = avg(durs)
    out["median_duration_s"] = percentile(durs, 50) if durs else None
    out["p90_duration_s"] = percentile(durs, 90) if durs else None

    band_counts = Counter(session_dur_band(s.get("dur", 0)) for s in sessions)
    out["duration_bands"] = dict(band_counts)

    trust_counts = Counter(s.get("bat_trust", -1) for s in sessions)
    out["trust_distribution"] = {TRUST_LABELS.get(k, str(k)): v for k, v in trust_counts.items()}

    intent_counts = Counter(s.get("intent", "unknown") for s in sessions)
    out["intent_distribution"] = dict(intent_counts)

    if prof == "battery":
        out.update(battery_specific(sessions))

    if prof == "performance":
        out.update(performance_specific(sessions))

    out.update(thermal_summary(sessions))
    out.update(advisory_summary(sessions))

    return out


def battery_specific(sessions):
    """Battery-only aggregates."""
    out = {}

    iq_values = [s["idle_q"] for s in sessions if s.get("idle_q", -1) >= 0]
    if iq_values:
        out["idle_q_avg"] = avg(iq_values)
        out["idle_q_median"] = percentile(iq_values, 50)
        out["idle_q_p90"] = percentile(iq_values, 90)
        out["idle_q_histogram"] = hist_bins(iq_values, [10, 20, 30, 50, 70])

    wph_values = []
    for s in sessions:
        wakes = s.get("bat_wake", 0)
        dur = s.get("dur", 0)
        if dur > 0:
            wph_values.append(wakes * 3600.0 / dur)
    if wph_values:
        out["wph_avg"] = avg(wph_values)
        out["wph_median"] = percentile(wph_values, 50)
        out["wph_histogram"] = hist_bins(wph_values, [5, 10, 15, 25, 40])

    wake_counts = [s.get("bat_wake", 0) for s in sessions]
    if wake_counts:
        out["wake_cycles_avg"] = avg(wake_counts)
        out["wake_cycles_histogram"] = hist_bins(wake_counts, [5, 10, 25, 50])

    bat_totals = []
    for s in sessions:
        t = s.get("bat_deep", 0) + s.get("bat_light", 0) + s.get("bat_mod", 0)
        if t > 0:
            bat_totals.append(t)
    if bat_totals:
        out["bat_total_avg_s"] = avg(bat_totals)
        out["bat_total_median_s"] = percentile(bat_totals, 50)

    deep_pct = []
    for s in sessions:
        deep = s.get("bat_deep", 0)
        total = s.get("bat_deep", 0) + s.get("bat_light", 0) + s.get("bat_mod", 0)
        if total > 0:
            deep_pct.append(100.0 * deep / total)
    if deep_pct:
        out["deep_idle_pct_avg"] = avg(deep_pct)
        out["deep_idle_pct_median"] = percentile(deep_pct, 50)

    outcomes = Counter(s.get("bat_outcome", "none") for s in sessions)
    out["bat_outcome_distribution"] = dict(outcomes)

    noisy_total = sum(1 for s in sessions if s.get("would_be_noisy", 0) == 1)
    out["would_be_noisy_count"] = noisy_total
    out["would_be_noisy_pct"] = pct(noisy_total, len(sessions))

    if noisy_total > 0:
        noisy_examples = []
        for s in sessions:
            if s.get("would_be_noisy", 0) == 1:
                noisy_examples.append({
                    "ts": s.get("ts", "?"),
                    "noisy_dim": s.get("noisy_dim", ""),
                })
        out["would_be_noisy_examples"] = noisy_examples[:10]

    learn_skip = Counter()
    for s in sessions:
        if s.get("learn_exempt", 0):
            learn_skip["benchmark_exempt"] += 1
        elif s.get("bat_trust", 0) == 0:
            learn_skip["dirty_trust"] += 1
    if learn_skip:
        out["learner_skip_breakdown"] = dict(learn_skip)

    return out


def performance_specific(sessions):
    """Performance-only aggregates."""
    out = {}

    outcomes = Counter(s.get("perf_outcome", "none") for s in sessions)
    out["perf_outcome_distribution"] = dict(outcomes)

    durs_high_load = []
    for s in sessions:
        t_active = s.get("t_heavy", 0) + s.get("t_gaming", 0) + s.get("t_sustained", 0)
        if t_active > 0:
            durs_high_load.append(t_active)
    if durs_high_load:
        out["high_load_time_avg_s"] = avg(durs_high_load)
        out["high_load_time_max_s"] = max(durs_high_load)

    return out


def thermal_summary(sessions):
    """Per-zone thermal peaks across all sessions."""
    cpu_peaks = [s["max_temp"] for s in sessions if s.get("max_temp", 0) > 0]
    skin_peaks = [s["skin_max_temp"] for s in sessions if s.get("skin_max_temp", 0) > 0]
    surf_peaks = [s["surface_max_temp"] for s in sessions if s.get("surface_max_temp", 0) > 0]
    board_peaks = [s["board_max_temp"] for s in sessions if s.get("board_max_temp", 0) > 0]

    out = {}
    if cpu_peaks:
        out["cpu_peak_avg"] = avg(cpu_peaks)
        out["cpu_peak_p95"] = percentile(cpu_peaks, 95)
        out["cpu_peak_max"] = max(cpu_peaks)
    if skin_peaks:
        out["skin_peak_avg"] = avg(skin_peaks)
        out["skin_peak_p95"] = percentile(skin_peaks, 95)
        out["skin_peak_max"] = max(skin_peaks)
    if surf_peaks:
        out["surface_peak_avg"] = avg(surf_peaks)
        out["surface_peak_p95"] = percentile(surf_peaks, 95)
        out["surface_peak_max"] = max(surf_peaks)
    if board_peaks:
        out["board_peak_avg"] = avg(board_peaks)
        out["board_peak_p95"] = percentile(board_peaks, 95)
        out["board_peak_max"] = max(board_peaks)
    return out


def advisory_summary(sessions):
    """V46 P2 advisory observe-only stats."""
    out = {}

    sessions_with_adv = [s for s in sessions if "adv_score" in s]
    if not sessions_with_adv:
        return out

    out["adv_active_count"] = sum(1 for s in sessions_with_adv if s.get("adv_active", 0) == 1)
    out["adv_active_pct"] = pct(out["adv_active_count"], len(sessions_with_adv))

    would_bias_count = sum(1 for s in sessions_with_adv if s.get("adv_would_bias", 0) == 1)
    out["would_bias_exit_count"] = would_bias_count
    out["would_bias_exit_pct"] = pct(would_bias_count, len(sessions_with_adv))

    mode_a_total = sum(s.get("bias_mode_a_count", 0) for s in sessions_with_adv)
    mode_b_total = sum(s.get("bias_mode_b_count", 0) for s in sessions_with_adv)
    mode_a_sessions = sum(1 for s in sessions_with_adv if s.get("bias_mode_a_count", 0) > 0)
    mode_b_sessions = sum(1 for s in sessions_with_adv if s.get("bias_mode_b_count", 0) > 0)
    out["bias_mode_a_total_fires"] = mode_a_total
    out["bias_mode_b_total_fires"] = mode_b_total
    out["bias_mode_a_session_count"] = mode_a_sessions
    out["bias_mode_b_session_count"] = mode_b_sessions
    out["bias_mode_a_session_pct"] = pct(mode_a_sessions, len(sessions_with_adv))
    out["bias_mode_b_session_pct"] = pct(mode_b_sessions, len(sessions_with_adv))

    scores = [s.get("adv_score", 0) for s in sessions_with_adv]
    nonzero = [v for v in scores if v > 0]
    out["adv_score_nonzero_pct"] = pct(len(nonzero), len(scores))
    if nonzero:
        out["adv_score_avg_nonzero"] = avg(nonzero)
        out["adv_score_p95"] = percentile(nonzero, 95)
        out["adv_score_max"] = max(nonzero)

    zone_active = {"skin": 0, "surface": 0, "board": 0}
    for s in sessions_with_adv:
        if s.get("adv_active", 0) == 1:
            if s.get("adv_vote_skin", 0) > 0:
                zone_active["skin"] += 1
            if s.get("adv_vote_surface", 0) > 0:
                zone_active["surface"] += 1
            if s.get("adv_vote_board", 0) > 0:
                zone_active["board"] += 1
    out["advisory_zone_contribution"] = zone_active

    return out


def format_report(agg, recovery, show_bands=True):
    """Produce human-readable report."""
    lines = []
    push = lines.append

    push("=" * 72)
    push("  ASB V47 Field Report")
    push("=" * 72)
    push(f"  Generated:           {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    push(f"  Total sessions:      {agg['total_sessions']}")

    if agg["total_sessions"] == 0:
        push("")
        push("  (no sessions found — module may be freshly installed)")
        push("=" * 72)
        return "\n".join(lines)

    ver_str = ", ".join(f"{v}={c}" for v, c in agg["asb_versions"].most_common())
    schema_str = ", ".join(f"v{v}={c}" for v, c in agg["schema_versions"].most_common())
    push(f"  ASB versions seen:   {ver_str}")
    push(f"  Schema versions:     {schema_str}")
    push("")

    if recovery:
        push("─" * 72)
        push("  Recovery (V46 P0)")
        push("─" * 72)
        push(f"  recovery_count:       {recovery.get('recovery_count', 0)}")
        push(f"  last_recovery_reason: {recovery.get('last_recovery_reason', '—') or '—'}")
        push(f"  gov_disabled:         {'YES (safe mode)' if recovery.get('gov_disabled', 0) == 1 else 'no'}")
        last_ts = recovery.get("last_recovery_ts", 0)
        if last_ts > 0:
            push(f"  last_recovery_ts:     {datetime.fromtimestamp(last_ts).strftime('%Y-%m-%d %H:%M:%S')}")
        push("")

    for prof_name in ("battery", "balanced", "performance"):
        p = agg["profiles"].get(prof_name)
        if not p:
            continue

        push("=" * 72)
        push(f"  Profile: {prof_name.upper()}")
        push("=" * 72)
        push(f"  Sessions:            {p['session_count']}")
        push(f"  Total duration:      {fmt_hms(p['total_duration_s'])}")
        push(f"  Avg duration:        {fmt_hms(p['avg_duration_s'])}")
        push(f"  Median / p90:        {fmt_hms(p['median_duration_s'])} / {fmt_hms(p['p90_duration_s'])}")
        push("")

        if show_bands and p.get("duration_bands"):
            push("  Duration bands:")
            for band in ("<10m", "10-30m", "30-60m", "1-3h", ">=3h"):
                c = p["duration_bands"].get(band, 0)
                push(f"    {band:<10}  {c:>4}   {fmt_pct(c, p['session_count']):>7}")
            push("")

        if p.get("trust_distribution"):
            push("  Trust tier distribution:")
            for tier in ("CLEAN", "PARTIAL", "DIRTY", "no-data"):
                c = p["trust_distribution"].get(tier, 0)
                if c > 0:
                    push(f"    {tier:<10}  {c:>4}   {fmt_pct(c, p['session_count']):>7}")
            push("")

        if p.get("intent_distribution"):
            push("  Intent distribution:")
            for intent, c in sorted(p["intent_distribution"].items(), key=lambda x: -x[1]):
                push(f"    {intent:<14}  {c:>4}   {fmt_pct(c, p['session_count']):>7}")
            push("")

        if prof_name == "battery":
            _format_battery(p, push)

        if prof_name == "performance":
            _format_performance(p, push)

        _format_thermal(p, push)

        _format_advisory(p, push)

    push("=" * 72)
    push("  Notes")
    push("=" * 72)
    push("  - This report does NOT include subjective UI smoothness data.")
    push("    For battery responsiveness changes, human A/B feel-test required.")
    push("  - would_be_noisy field is OBSERVE-ONLY in V46 (no behavior change).")
    push("  - adv_* fields are OBSERVE-ONLY in V46 (no FSM bias applied yet).")
    push("=" * 72)

    return "\n".join(lines)


def _format_battery(p, push):
    if p.get("idle_q_avg") is not None:
        push("  Idle quality:")
        push(f"    avg / median / p90:  {fmt_n(p['idle_q_avg'])} / {fmt_n(p['idle_q_median'])} / {fmt_n(p['idle_q_p90'])}")
        if p.get("idle_q_histogram"):
            push("    Distribution:")
            for label, c in p["idle_q_histogram"]:
                push(f"      iq {label:<8}  {c:>4}   {fmt_pct(c, p['session_count']):>7}")
        push("")

    if p.get("wph_avg") is not None:
        push("  Wakes per hour:")
        push(f"    avg / median:        {fmt_n(p['wph_avg'])} / {fmt_n(p['wph_median'])}")
        if p.get("wph_histogram"):
            push("    Distribution:")
            for label, c in p["wph_histogram"]:
                push(f"      wph {label:<8} {c:>4}   {fmt_pct(c, p['session_count']):>7}")
        push("")

    if p.get("wake_cycles_avg") is not None:
        push("  Wake cycles:")
        push(f"    avg:                 {fmt_n(p['wake_cycles_avg'])}")
        if p.get("wake_cycles_histogram"):
            push("    Distribution:")
            for label, c in p["wake_cycles_histogram"]:
                push(f"      wake {label:<8} {c:>4}   {fmt_pct(c, p['session_count']):>7}")
        push("")

    if p.get("deep_idle_pct_avg") is not None:
        push(f"  Deep idle %:           avg {fmt_n(p['deep_idle_pct_avg'])}  median {fmt_n(p['deep_idle_pct_median'])}")
        push("")

    if p.get("bat_outcome_distribution"):
        push("  Battery outcome distribution:")
        for k, v in sorted(p["bat_outcome_distribution"].items(), key=lambda x: -x[1]):
            push(f"    {k:<16}  {v:>4}   {fmt_pct(v, p['session_count']):>7}")
        push("")

    push("  V46 P1a NOISY candidate (observe-only):")
    push(f"    would_be_noisy:      {p.get('would_be_noisy_count', 0)} / {p['session_count']}  ({fmt_pct(p.get('would_be_noisy_count', 0), p['session_count'])})")
    if p.get("would_be_noisy_examples"):
        push("    Recent examples:")
        for ex in p["would_be_noisy_examples"][:5]:
            push(f"      {ex['ts']}: {ex['noisy_dim']}")
    push("")

    if p.get("learner_skip_breakdown"):
        push("  Learner skip breakdown:")
        for k, v in p["learner_skip_breakdown"].items():
            push(f"    {k:<20}  {v:>4}   {fmt_pct(v, p['session_count']):>7}")
        push("")


def _format_performance(p, push):
    if p.get("perf_outcome_distribution"):
        push("  Performance outcome distribution:")
        for k, v in sorted(p["perf_outcome_distribution"].items(), key=lambda x: -x[1]):
            push(f"    {k:<20}  {v:>4}   {fmt_pct(v, p['session_count']):>7}")
        push("")

    if p.get("high_load_time_avg_s") is not None:
        push(f"  High-load time:        avg {fmt_hms(p['high_load_time_avg_s'])}  max {fmt_hms(p['high_load_time_max_s'])}")
        push("")


def _format_thermal(p, push):
    have_any = any(k in p for k in ("cpu_peak_avg", "skin_peak_avg", "surface_peak_avg", "board_peak_avg"))
    if not have_any:
        return
    push("  Thermal peaks:")
    push("    zone        avg    p95    max")
    for zone, prefix in (("CPU", "cpu"), ("Skin", "skin"), ("Surface", "surface"), ("Board", "board")):
        if f"{prefix}_peak_avg" not in p:
            continue
        push(f"    {zone:<10}  {fmt_n(p[f'{prefix}_peak_avg'], 0):>4}   {fmt_n(p[f'{prefix}_peak_p95'], 0):>4}   {fmt_n(p[f'{prefix}_peak_max'], 0):>4}")
    push("")


def _format_advisory(p, push):
    if "adv_active_count" not in p:
        return
    push("  Multi-sensor advisory (observe-only):")
    push(f"    adv_active sessions:    {p['adv_active_count']} ({fmt_n(p.get('adv_active_pct', 0))}%)")
    push(f"    V46 would_bias (perf+gaming): {p.get('would_bias_exit_count', 0)} ({fmt_n(p.get('would_bias_exit_pct', 0))}%)")
    push(f"    V47 Mode A (adv>=70 + gaming>5m): {p.get('bias_mode_a_session_count', 0)} sessions, {p.get('bias_mode_a_total_fires', 0)} total fires")
    push(f"    V47 Mode B (skin+surface hot, cpu cool): {p.get('bias_mode_b_session_count', 0)} sessions, {p.get('bias_mode_b_total_fires', 0)} total fires")
    push(f"    Sessions with adv>0:    {fmt_n(p.get('adv_score_nonzero_pct', 0))}%")
    if p.get("adv_score_avg_nonzero") is not None:
        push(f"    Score avg (nonzero):    {fmt_n(p['adv_score_avg_nonzero'])}")
        push(f"    Score p95 / max:        {fmt_n(p.get('adv_score_p95', 0))} / {fmt_n(p.get('adv_score_max', 0))}")
    if p.get("advisory_zone_contribution"):
        push("    Zone contribution (when adv_active=1):")
        zc = p["advisory_zone_contribution"]
        denom = max(p.get("adv_active_count", 1), 1)
        for zone in ("skin", "surface", "board"):
            c = zc.get(zone, 0)
            push(f"      {zone:<10}  {c} ({fmt_pct(c, denom)})")
    push("")


def main():
    ap = argparse.ArgumentParser(
        description="ASB Field Report — aggregates session_history.jsonl",
    )
    ap.add_argument("--input", "-i", default=DEFAULT_INPUT,
                    help=f"Path to session_history.jsonl (default: {DEFAULT_INPUT})")
    ap.add_argument("--recovery", "-r", default=DEFAULT_RECOVERY,
                    help=f"Path to recovery.json (default: {DEFAULT_RECOVERY})")
    ap.add_argument("--text-out", "-o", help="Write text report to FILE")
    ap.add_argument("--json-out", help="Write structured JSON report to FILE")
    ap.add_argument("--no-bands", action="store_true",
                    help="Skip duration band breakdown")
    ap.add_argument("--quiet", "-q", action="store_true",
                    help="Suppress stdout (use with --text-out or --json-out)")
    args = ap.parse_args()

    sessions = load_sessions(args.input)
    if not sessions and not os.path.exists(args.input):
        print(f"ERROR: session log not found: {args.input}", file=sys.stderr)
        sys.exit(2)

    recovery = load_recovery(args.recovery)

    agg = aggregate(sessions)

    text_report = format_report(agg, recovery, show_bands=not args.no_bands)

    if not args.quiet:
        print(text_report)

    if args.text_out:
        with open(args.text_out, "w", encoding="utf-8") as f:
            f.write(text_report)
        if not args.quiet:
            print(f"\n[wrote text report: {args.text_out}]", file=sys.stderr)

    if args.json_out:
        payload = {
            "generated_at": datetime.now().isoformat(),
            "input_path": args.input,
            "recovery": recovery,
            "aggregate": agg,
        }
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, default=str)
        if not args.quiet:
            print(f"[wrote json report: {args.json_out}]", file=sys.stderr)


if __name__ == "__main__":
    main()
