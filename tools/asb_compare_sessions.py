#!/usr/bin/env python3
"""
ASB Session Comparator — сравнение нескольких тестовых сессий ASB.

Использование:
    python3 asb_compare_sessions.py log1.txt log2.txt [log3.txt ...]
    python3 asb_compare_sessions.py /sdcard/ASB_*.txt

Выводит сводную таблицу: время в каждом состоянии, температуры,
cap gap, efficiency, и рекомендацию по режиму.
"""
import re, sys, os
from collections import OrderedDict

def parse_session_markers(path):
    """Extract session_start/session_end markers and key=value state dumps."""
    result = {
        'file': os.path.basename(path),
        'profile': 'unknown', 'highload': 'unknown',
        'gaming': 0, 'sustained': 0, 'thermal': 0, 'unreachable': 0,
        't_heavy': 0, 't_gaming': 0, 't_sustained': 0,
        'avg_gap': 0, 'max_temp': 0, 'auto_degraded': 0,
        't2s': 0, 't2thermal': 0, 'efficiency': -1, 'recovery': 0,
        'bat_deep_idle': 0, 'bat_wake': 0,
        'max_gpu': 0, 'max_load': 0.0,
        'transitions': 0, 'duration_s': 0,
    }
    fsm_times = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            # Session markers
            m = re.search(r'session_start profile=(\w+) highload=(\w+)', line)
            if m:
                result['profile'] = m.group(1)
                result['highload'] = m.group(2)
            m = re.search(r'session_end (.+)', line)
            if m:
                kv = m.group(1)
                for pair in kv.split():
                    if '=' in pair:
                        k, v = pair.split('=', 1)
                        k = k.strip()
                        v = v.rstrip('%')
                        if k in result:
                            try:
                                if '.' in v: result[k] = float(v)
                                else: result[k] = int(v)
                            except ValueError:
                                result[k] = v
            # Key=value state dumps (from SAMPLE blocks)
            for key in ['ses_gaming', 'ses_sustained', 'ses_thermal', 'ses_unreachable',
                         'ses_t_heavy', 'ses_t_gaming', 'ses_t_sustained',
                         'ses_avg_gap_p0', 'ses_max_temp', 'ses_auto_degraded',
                         'ses_t2s', 'ses_t2thermal', 'ses_efficiency', 'ses_recovery',
                         'bat_deep_idle', 'bat_wake_cycles']:
                m2 = re.search(rf'^{key}=(.+)', line)
                if m2:
                    short = key.replace('ses_', '').replace('bat_', 'bat_')
                    mapped = {
                        'gaming': 'gaming', 'sustained': 'sustained',
                        'thermal': 'thermal', 'unreachable': 'unreachable',
                        't_heavy': 't_heavy', 't_gaming': 't_gaming',
                        't_sustained': 't_sustained', 'avg_gap_p0': 'avg_gap',
                        'max_temp': 'max_temp', 'auto_degraded': 'auto_degraded',
                        't2s': 't2s', 't2thermal': 't2thermal',
                        'efficiency': 'efficiency', 'recovery': 'recovery',
                        'deep_idle': 'bat_deep_idle', 'wake_cycles': 'bat_wake',
                    }
                    target = mapped.get(short)
                    if target:
                        try:
                            result[target] = int(m2.group(1))
                        except ValueError:
                            pass
            # FSM transitions
            m3 = re.search(r'\[(\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] FSM: (\w+)', line)
            if m3:
                result['transitions'] += 1
                ts_str = m3.group(1)
                try:
                    parts = ts_str.split()
                    t = parts[1].split(':')
                    sec = int(t[0])*3600 + int(t[1])*60 + int(t[2])
                    fsm_times.append(sec)
                except (IndexError, ValueError):
                    pass
            # GPU/load peaks
            m4 = re.search(r'gpu=(\d+)%', line)
            if m4:
                g = int(m4.group(1))
                if g > result['max_gpu']: result['max_gpu'] = g
            m5 = re.search(r'load=([\d.]+)', line)
            if m5:
                l = float(m5.group(1))
                if l > result['max_load']: result['max_load'] = l
            # Profile from state dump
            m6 = re.match(r'^profile=(\w+)', line)
            if m6 and result['profile'] == 'unknown':
                result['profile'] = m6.group(1)
            m7 = re.match(r'^highload_mode=(\w+)', line)
            if m7 and result['highload'] == 'unknown':
                result['highload'] = m7.group(1)
    if len(fsm_times) >= 2:
        result['duration_s'] = fsm_times[-1] - fsm_times[0]
    return result

def fmt_time(sec):
    if sec <= 0: return '-'
    m, s = divmod(sec, 60)
    return f"{m}m{s:02d}s" if m > 0 else f"{s}s"

def recommend(sessions):
    """Simple recommendation based on session data."""
    tips = []
    for s in sessions:
        if s['max_temp'] >= 70:
            tips.append(f"{s['file']}: max temp {s['max_temp']}°C — consider stable mode")
        if s['efficiency'] >= 0 and s['efficiency'] < 50:
            tips.append(f"{s['file']}: efficiency={s['efficiency']}% — burst not viable, use stable")
        if s['auto_degraded']:
            tips.append(f"{s['file']}: auto degraded burst→stable during session")
        if s['t2s'] > 0 and s['t2s'] < 60:
            tips.append(f"{s['file']}: first SUSTAINED in {s['t2s']}s — device throttles fast")
    return tips

def main():
    if len(sys.argv) < 2:
        print("Usage: asb_compare_sessions.py log1.txt [log2.txt ...]")
        sys.exit(1)

    files = sys.argv[1:]
    sessions = [parse_session_markers(f) for f in files]

    # Header
    print("=" * 80)
    print("  ASB Session Comparison Report")
    print("=" * 80)
    print()

    # Table
    labels = OrderedDict([
        ('profile',     'Profile'),
        ('highload',    'Highload mode'),
        ('duration_s',  'Duration'),
        ('gaming',      'GAMING entries'),
        ('sustained',   'SUSTAINED entries'),
        ('thermal',     'Thermal entries'),
        ('t_heavy',     'Time HEAVY'),
        ('t_gaming',    'Time GAMING'),
        ('t_sustained', 'Time SUSTAINED'),
        ('avg_gap',     'Avg cap gap (kHz)'),
        ('max_temp',    'Max temp (°C)'),
        ('t2s',         'Time to 1st SUSTAINED'),
        ('t2thermal',   'Time to 1st thermal'),
        ('efficiency',  'Efficiency score'),
        ('recovery',    'Recovery count'),
        ('auto_degraded','Auto degraded'),
        ('max_gpu',     'Peak GPU %'),
        ('max_load',    'Peak load1'),
        ('transitions', 'FSM transitions'),
        ('bat_deep_idle','DEEP_IDLE time'),
        ('bat_wake',    'Wake cycles'),
    ])

    # Column widths
    lw = max(len(v) for v in labels.values()) + 2
    cw = max(max(len(s['file']) for s in sessions), 16)

    # Print header row
    print(f"{'Metric':<{lw}}", end="")
    for s in sessions:
        name = s['file'][:cw]
        print(f"  {name:>{cw}}", end="")
    print()
    print("-" * (lw + (cw + 2) * len(sessions)))

    # Print rows
    for key, label in labels.items():
        print(f"{label:<{lw}}", end="")
        for s in sessions:
            v = s[key]
            if key in ('t_heavy', 't_gaming', 't_sustained', 'bat_deep_idle', 'duration_s', 't2s', 't2thermal'):
                cell = fmt_time(v)
            elif key == 'auto_degraded':
                cell = 'YES' if v else 'no'
            elif key == 'efficiency':
                cell = f"{v}%" if v >= 0 else '-'
            elif key == 'max_load':
                cell = f"{v:.1f}"
            else:
                cell = str(v)
            print(f"  {cell:>{cw}}", end="")
        print()

    # Recommendation
    tips = recommend(sessions)
    if tips:
        print()
        print("Recommendations:")
        for t in tips:
            print(f"  • {t}")

    # Best session
    if len(sessions) > 1:
        print()
        scored = [(s, (s['t_gaming'] - s['t_sustained'] * 2 + (s['efficiency'] if s['efficiency'] >= 0 else 50)))
                  for s in sessions]
        best = max(scored, key=lambda x: x[1])
        print(f"Best gaming session: {best[0]['file']} (score={best[1]})")

    print()
    print("=" * 80)

if __name__ == '__main__':
    main()
