#!/usr/bin/env python3
"""
ASB Session Comparator — сравнение сессий ASB из governor logs или session_history.jsonl

Использование:
    python3 asb_compare_sessions.py log1.txt log2.txt [log3.txt ...]
    python3 asb_compare_sessions.py session_history.jsonl          (JSONL mode)
    python3 asb_compare_sessions.py /sdcard/ASB_*.txt
"""
import re, sys, os, json
from collections import OrderedDict

# ── JSONL mode ──────────────────────────────────────────────────────────────

def load_jsonl(path):
    sessions = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line[0] != '{':
                continue
            try:
                s = json.loads(line)
                # normalise field names to match log-parsed format
                r = {
                    'file':       s.get('ts', path),
                    'profile':    s.get('profile', 'unknown'),
                    'highload':   s.get('mode', 'unknown'),
                    'gaming':     s.get('gaming', 0),
                    'sustained':  s.get('sustained', 0),
                    'thermal':    s.get('thermal', 0),
                    'unreachable':s.get('unreachable', 0),
                    't_heavy':    s.get('t_heavy', 0),
                    't_gaming':   s.get('t_gaming', 0),
                    't_sustained':s.get('t_sustained', 0),
                    'avg_gap':    s.get('avg_gap', 0),
                    'max_temp':   s.get('max_temp', 0),
                    'auto_degraded': s.get('degraded', 0),
                    't2s':        s.get('t2s', 0),
                    't2thermal':  s.get('t2th', 0),
                    'efficiency': s.get('eff', -1),
                    'recovery':   s.get('recovery', 0),
                    'bat_deep_idle': s.get('bat_deep', 0),
                    'bat_wake':   s.get('bat_wake', 0),
                    'bat_ttd':    s.get('bat_ttd', 0),
                    'idle_q':     s.get('idle_q', -1),
                    'cap_eff':    s.get('cap_eff', -1),
                    'sus_pct':    s.get('sus_pct', 0),
                    'max_gpu':    0,
                    'max_load':   0.0,
                    'transitions':0,
                    'duration_s': s.get('dur', 0),
                    'intent':     s.get('intent', 'unknown'),
                }
                sessions.append(r)
            except json.JSONDecodeError:
                continue
    return sessions

# ── Log file mode ────────────────────────────────────────────────────────────

def parse_session_markers(path):
    result = {
        'file': os.path.basename(path),
        'profile': 'unknown', 'highload': 'unknown',
        'gaming': 0, 'sustained': 0, 'thermal': 0, 'unreachable': 0,
        't_heavy': 0, 't_gaming': 0, 't_sustained': 0,
        'avg_gap': 0, 'max_temp': 0, 'auto_degraded': 0,
        't2s': 0, 't2thermal': 0, 'efficiency': -1, 'recovery': 0,
        'bat_deep_idle': 0, 'bat_wake': 0, 'bat_ttd': 0,
        'idle_q': -1, 'cap_eff': -1, 'sus_pct': 0,
        'max_gpu': 0, 'max_load': 0.0,
        'transitions': 0, 'duration_s': 0,
    }
    fsm_times = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            m = re.search(r'session_start profile=(\w+) highload=(\w+)', line)
            if m: result['profile'] = m.group(1); result['highload'] = m.group(2)
            for key in ['ses_gaming', 'ses_sustained', 'ses_thermal', 'ses_unreachable',
                        'ses_t_heavy', 'ses_t_gaming', 'ses_t_sustained',
                        'ses_avg_gap_p0', 'ses_max_temp', 'ses_auto_degraded',
                        'ses_t2s', 'ses_t2thermal', 'ses_efficiency', 'ses_recovery',
                        'bat_deep_idle', 'bat_wake_cycles', 'idle_q', 'cap_eff', 'sus_pct']:
                m2 = re.search(rf'^{key}=(.+)', line)
                if m2:
                    mapped = {
                        'ses_gaming': 'gaming', 'ses_sustained': 'sustained',
                        'ses_thermal': 'thermal', 'ses_unreachable': 'unreachable',
                        'ses_t_heavy': 't_heavy', 'ses_t_gaming': 't_gaming',
                        'ses_t_sustained': 't_sustained', 'ses_avg_gap_p0': 'avg_gap',
                        'ses_max_temp': 'max_temp', 'ses_auto_degraded': 'auto_degraded',
                        'ses_t2s': 't2s', 'ses_t2thermal': 't2thermal',
                        'ses_efficiency': 'efficiency', 'ses_recovery': 'recovery',
                        'bat_deep_idle': 'bat_deep_idle', 'bat_wake_cycles': 'bat_wake',
                        'idle_q': 'idle_q', 'cap_eff': 'cap_eff', 'sus_pct': 'sus_pct',
                    }
                    tgt = mapped.get(key, key)
                    if tgt in result:
                        try: result[tgt] = int(m2.group(1))
                        except ValueError: pass
            m3 = re.search(r'\[(\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] FSM: (\w+)', line)
            if m3:
                result['transitions'] += 1
                try:
                    t = m3.group(1).split()[1].split(':')
                    fsm_times.append(int(t[0])*3600 + int(t[1])*60 + int(t[2]))
                except: pass
            m4 = re.search(r'gpu=(\d+)%', line)
            if m4:
                g = int(m4.group(1))
                if g > result['max_gpu']: result['max_gpu'] = g
            m5 = re.search(r'load=([\d.]+)', line)
            if m5:
                l = float(m5.group(1))
                if l > result['max_load']: result['max_load'] = l
            m6 = re.match(r'^profile=(\w+)', line)
            if m6 and result['profile'] == 'unknown': result['profile'] = m6.group(1)
    if len(fsm_times) >= 2:
        result['duration_s'] = fsm_times[-1] - fsm_times[0]
    return result

# ── Helpers ──────────────────────────────────────────────────────────────────

def fmt_time(sec):
    if not sec or sec <= 0: return '—'
    m, s = divmod(int(sec), 60)
    return f"{m}m{s:02d}s" if m > 0 else f"{s}s"

def avg(lst):
    lst = [x for x in lst if x is not None and x > 0]
    return sum(lst) / len(lst) if lst else 0

# ── Report ────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: asb_compare_sessions.py log1.txt [log2.txt ...] | session_history.jsonl")
        sys.exit(1)

    # Detect JSONL mode
    files = sys.argv[1:]
    if len(files) == 1 and files[0].endswith('.jsonl'):
        sessions = load_jsonl(files[0])
        jsonl_mode = True
    else:
        sessions = [parse_session_markers(f) for f in files]
        jsonl_mode = False

    W = 80
    print("=" * W)
    print("  ASB Session Comparison Report")
    if jsonl_mode:
        print(f"  Source: {files[0]}  ({len(sessions)} sessions)")
    print("=" * W)

    # ── Per-profile grouped summary ────────────────────────────────────────
    print("\n── Per-Profile Summary ─────────────────────────────────────────")
    for prof in ['performance', 'balanced', 'battery']:
        ps = [s for s in sessions if s.get('profile') == prof]
        if not ps: continue
        print(f"\n  {prof.upper()} ({len(ps)} sessions)")
        metrics = [
            ("Avg max temp",        avg([s['max_temp'] for s in ps]),          "°C"),
            ("Avg t2s",             avg([s['t2s'] for s in ps]),                "s", True),
            ("Avg efficiency",      avg([s['efficiency'] for s in ps
                                         if s.get('efficiency', -1) >= 0]),     "%"),
            ("Avg sus_pct",         avg([s.get('sus_pct', 0) for s in ps]),     "%"),
            ("Avg cap_eff",         avg([s.get('cap_eff', -1) for s in ps
                                         if s.get('cap_eff', -1) >= 0]),        "%"),
            ("Avg idle_q",          avg([s.get('idle_q', -1) for s in ps
                                         if s.get('idle_q', -1) >= 0]),         ""),
            ("Avg wake/hour",       avg([s.get('bat_wake', 0) * 3600
                                         / max(s.get('duration_s', 1), 1)
                                         for s in ps
                                         if s.get('duration_s', 0) > 300]),    "/h"),
            ("Avg settle time",     avg([s.get('bat_ttd', 0) for s in ps]),     "s", True),
        ]
        for row in metrics:
            label, val, unit = row[0], row[1], row[2]
            use_fmt = len(row) > 3 and row[3]
            if val <= 0: continue
            if use_fmt:
                print(f"    {label:<24} {fmt_time(val)}")
            elif unit == "%":
                print(f"    {label:<24} {val:.0f}{unit}")
            else:
                print(f"    {label:<24} {val:.1f}{unit}")

    # ── Full comparison table (log mode) ───────────────────────────────────
    if not jsonl_mode:
        print("\n── Full Comparison Table ───────────────────────────────────────")
        labels = OrderedDict([
            ('profile',      'Profile'),
            ('highload',     'Highload'),
            ('duration_s',   'Duration'),
            ('gaming',       'GAMING entries'),
            ('sustained',    'SUSTAINED entries'),
            ('t_heavy',      'Time HEAVY'),
            ('t_gaming',     'Time GAMING'),
            ('t_sustained',  'Time SUSTAINED'),
            ('sus_pct',      'sus_pct %'),
            ('avg_gap',      'Avg gap (kHz)'),
            ('cap_eff',      'cap_eff %'),
            ('max_temp',     'Max temp (°C)'),
            ('t2s',          'Time to 1st SUS'),
            ('efficiency',   'Efficiency'),
            ('recovery',     'Recovery count'),
            ('idle_q',       'idle_q'),
            ('bat_deep_idle','DEEP_IDLE time'),
            ('bat_wake',     'Wake cycles'),
            ('max_gpu',      'Peak GPU %'),
            ('max_load',     'Peak load1'),
        ])
        lw = max(len(v) for v in labels.values()) + 2
        cw = max(max(len(str(s['file'])) for s in sessions), 16)
        print(f"{'Metric':<{lw}}", end="")
        for s in sessions: print(f"  {str(s['file'])[:cw]:>{cw}}", end="")
        print()
        print("-" * (lw + (cw + 2) * len(sessions)))
        for key, label in labels.items():
            print(f"{label:<{lw}}", end="")
            for s in sessions:
                v = s.get(key, 0)
                if key in ('t_heavy','t_gaming','t_sustained','bat_deep_idle','duration_s','t2s','t2thermal'):
                    cell = fmt_time(v)
                elif key == 'auto_degraded':
                    cell = 'YES' if v else 'no'
                elif key in ('efficiency', 'sus_pct', 'cap_eff'):
                    cell = f"{v}%" if v >= 0 else '—'
                elif key == 'idle_q':
                    cell = str(v) if v >= 0 else '—'
                elif key == 'max_load':
                    cell = f"{v:.1f}"
                else:
                    cell = str(v)
                print(f"  {cell:>{cw}}", end="")
            print()

    # ── JSONL mode: per-session detail ─────────────────────────────────────
    if jsonl_mode:
        print("\n── Session Detail ───────────────────────────────────────────────")
        print(f"  {'#':>3}  {'Time':<18}  {'Prof':>11}  {'Mode':>7}  {'Intent':>10}  {'sus%':>5}  "
              f"{'idle_q':>6}  {'cap_eff':>7}  {'wake/h':>6}  {'t2s':>5}  {'eff':>4}")
        print("  " + "─" * 86)
        for i, s in enumerate(sessions, 1):
            ts   = s.get('file', '?')[:18]
            prof = s.get('profile', '?')
            mode = s.get('highload', '?')
            intt = s.get('intent', '?')[:10]
            sp   = s.get('sus_pct', 0)
            iq   = s.get('idle_q', -1);   iq_s = str(iq) if iq >= 0 else '—'
            ce   = s.get('cap_eff', -1);  ce_s = f"{ce}%" if ce >= 0 else '—'
            dur  = s.get('duration_s', 0)
            bw   = s.get('bat_wake', 0)
            wph  = f"{bw*3600/dur:.1f}" if dur > 300 else '—'
            t2s  = s.get('t2s', 0);       t2s_s = fmt_time(t2s) if t2s > 0 else '—'
            eff  = s.get('efficiency', -1); eff_s = f"{eff}%" if eff >= 0 else '—'
            print(f"  {i:>3}  {ts:<18}  {prof:>11}  {mode:>7}  {intt:>10}  {sp:>4}%  "
                  f"{iq_s:>6}  {ce_s:>7}  {wph:>6}  {t2s_s:>5}  {eff_s:>4}")

    # ── Battery ranking ────────────────────────────────────────────────────
    bat = [s for s in sessions if s.get('profile') == 'battery' and s.get('duration_s', 0) > 300]
    if len(bat) > 1:
        def bat_score(s):
            iq  = s.get('idle_q', -1)
            bw  = s.get('bat_wake', 0)
            dur = s.get('duration_s', 1)
            bd  = s.get('bat_deep_idle', 0)
            return (iq if iq >= 0 else 50) - bw * 2 + int(bd * 50 / dur)
        ranked = sorted(bat, key=bat_score, reverse=True)
        print("\n── Battery Ranking ──────────────────────────────────────────────")
        for rank, s in enumerate(ranked, 1):
            sc   = bat_score(s)
            iq   = s.get('idle_q', -1)
            wph  = s.get('bat_wake', 0) * 3600 / max(s.get('duration_s', 1), 1)
            dur  = fmt_time(s.get('duration_s', 0))
            lbl  = "🏆 BEST" if rank == 1 else ("💩 WORST" if rank == len(ranked) else f"  #{rank}")
            print(f"  {lbl}  {str(s.get('file','?'))[:20]:<20}  score={sc:>3}  "
                  f"idle_q={iq:>3}  wake/h={wph:.1f}  dur={dur}")

    # ── Recommendations ────────────────────────────────────────────────────
    print("\n── Recommendations ──────────────────────────────────────────────")
    tips = []
    for s in sessions:
        if s.get('max_temp', 0) >= 70:
            tips.append(f"  {s['file']}: max_temp={s['max_temp']}°C → consider stable mode")
        if s.get('efficiency', -1) >= 0 and s.get('efficiency', -1) < 50:
            tips.append(f"  {s['file']}: efficiency={s['efficiency']}% → burst not viable")
        if s.get('auto_degraded', 0):
            tips.append(f"  {s['file']}: auto degraded burst→stable")
        if s.get('intent', '') == 'benchmark' and s.get('auto_degraded', 0):
            tips.append(f"  {s['file']}: benchmark intent + degraded → stable is optimal for this workload")
        if s.get('t2s', 0) > 0 and s.get('t2s', 0) < 60:
            tips.append(f"  {s['file']}: t2s={s['t2s']}s — device throttles very fast")
    if tips:
        for t in tips: print(t)
    else:
        print("  All sessions within normal range ✓")

    print()
    print("=" * W)

if __name__ == '__main__':
    main()
