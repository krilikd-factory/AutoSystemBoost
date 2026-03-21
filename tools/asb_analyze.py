#!/usr/bin/env python3
"""
ASB Log Analyzer — анализ и сравнение логов AutoSystemBoost
Использование:
    python3 asb_analyze.py log1.txt [log2.txt ...]
    python3 asb_analyze.py /sdcard/ASB_test_*.txt
"""

import re
import sys
import os
from collections import defaultdict

# ─── Парсинг ─────────────────────────────────────────────────────────────────

STATES = ["DEEP_IDLE", "LIGHT_IDLE", "MODERATE", "HEAVY", "GAMING", "SUSTAINED"]

def to_sec(ts):
    h, m, s = map(int, ts.split(':'))
    return h * 3600 + m * 60 + s

def parse_log(path):
    """Парсит один лог-файл, возвращает структуру с данными сессии."""
    with open(path, encoding='utf-8', errors='replace') as f:
        content = f.read()

    # Убираем дубли строк (логи часто повторяются в samples)
    lines, seen = [], set()
    for line in content.splitlines():
        if re.match(r'\[\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]', line) and line not in seen:
            seen.add(line)
            lines.append(line)

    result = {
        'filename':   os.path.basename(path),
        'highload_mode': 'unknown',
        'version':    'unknown',
        'restarts':   0,

        # FSM transitions
        'fsm_events': [],          # [(sec, state, temp, gap0, gpu)]
        'sustained_events': [],    # [(enter_sec, exit_sec, enter_t, exit_t, reason)]

        # Counters
        'gaming_entries':    0,
        'sustained_entries': 0,
        'thermal_entries':   0,
        'unreachable_entries': 0,
        'auto_degrade':      False,
        'auto_degrade_pct':  None,

        # Gap stats in GAMING
        'gaming_gaps': [],

        # Session telemetry (last snapshot)
        'ses': {},

        # Thermal escalation
        'temps_by_state': defaultdict(list),
    }

    # ── diag строка
    for line in lines:
        if 'diag:' in line and 'highload_mode' in line:
            m = re.search(r'highload_mode=(\w+)', line)
            if m:
                result['highload_mode'] = m.group(1)
            break

    # ── версия из первых строк лога или имени файла
    m = re.search(r'V22-r(\d+\w*)', path)
    if m:
        result['version'] = 'V22-r' + m.group(1)

    # ── перезапуски
    result['restarts'] = len([l for l in lines if 'initial state:' in l])

    # ── FSM события
    prev_sec = None
    for line in lines:
        m = re.search(r'\[(\d{2}-\d{2} (\d{2}:\d{2}:\d{2}))\].*FSM: (\w+)', line)
        if not m:
            continue
        sec   = to_sec(m.group(2))
        state = m.group(3)
        if state not in STATES:
            continue
        t_m   = re.search(r't=(\d+)°C', line)
        g0_m  = re.search(r'gap0=(-?\d+)', line)
        gpu_m = re.search(r'gpu=(\d+)%', line)
        temp  = int(t_m.group(1))  if t_m  else 0
        gap0  = int(g0_m.group(1)) if g0_m else 0
        gpu   = int(gpu_m.group(1))if gpu_m else 0
        result['fsm_events'].append((sec, state, temp, gap0, gpu))
        result['temps_by_state'][state].append(temp)

    # ── SUSTAINED эпизоды
    sus_enter = None
    for line in lines:
        m = re.search(r'\[(\d{2}-\d{2} (\d{2}:\d{2}:\d{2}))\]', line)
        if not m:
            continue
        sec = to_sec(m.group(2))

        if 'FSM: SUSTAINED' in line:
            t_m = re.search(r't=(\d+)°C', line)
            sus_enter = (sec, int(t_m.group(1)) if t_m else 0)

        elif 'exit_sustained' in line and sus_enter:
            t_m = re.search(r't=(\d+)°C', line)
            reason = 'no_longer_heavy' if 'no_longer_heavy' in line else 'temp_dropped'
            exit_t = int(t_m.group(1)) if t_m else 0
            result['sustained_events'].append(
                (sus_enter[0], sec, sus_enter[1], exit_t, reason))
            sus_enter = None

    # ── Счётчики
    result['gaming_entries']      = len([l for l in lines if 'FSM: GAMING' in l])
    result['sustained_entries']   = len([l for l in lines if 'FSM: SUSTAINED' in l])
    result['thermal_entries']     = len([l for l in lines if 'enter_sustained: thermal' in l])
    result['unreachable_entries'] = len([l for l in lines if 'gaming_unreachable' in l])

    for line in lines:
        if 'auto: degraded' in line:
            result['auto_degrade'] = True
            m = re.search(r'sus_pct=(\d+)', line)
            if m:
                result['auto_degrade_pct'] = int(m.group(1))

    # ── Intent (V28r2)
    result['intent'] = 'unknown'
    result['self_tune_events'] = []
    result['feedback_events'] = []
    for line in lines:
        if 'intent: classified as' in line:
            m = re.search(r'classified as (\w+)', line)
            if m:
                result['intent'] = m.group(1)
        elif 'intent: benchmark+thermal' in line:
            result['intent_action'] = 'immediate_stable'
        elif 'self_tune:' in line:
            m = re.search(r'self_tune: (.+)', line)
            if m:
                result['self_tune_events'].append(m.group(1).strip())
        elif 'feedback:' in line or 'profile:performance ->' in line:
            m = re.search(r'(?:feedback|profile:performance ->): ?(.+)', line)
            if not m:
                m = re.search(r'profile:performance -> (.+)', line)
            if m:
                result['feedback_events'].append(m.group(1).strip())

    # ── Gap в GAMING (из FSM строк)
    for line in lines:
        if 'FSM: GAMING' in line:
            m = re.search(r'gap0=(-?\d+)', line)
            if m and int(m.group(1)) > 0:
                result['gaming_gaps'].append(int(m.group(1)))

    # ── Session telemetry (последний state snapshot)
    state_snaps = []
    snap = {}
    for line in content.splitlines():
        m = re.match(r'(\w+)=(.*)', line.strip())
        if m:
            snap[m.group(1)] = m.group(2).strip()
        elif snap and 'ses_gaming' in snap:
            state_snaps.append(dict(snap))
            snap = {}
    if state_snaps:
        result['ses'] = state_snaps[-1]
        # Пересчитываем дельту если есть первый snapshot
        if len(state_snaps) > 1:
            first = state_snaps[0]
            last  = state_snaps[-1]
            result['ses_delta'] = {}
            for k in ['ses_gaming','ses_sustained','ses_thermal',
                      'ses_t_heavy','ses_t_gaming','ses_t_sustained',
                      'ses_avg_gap_p0','ses_max_temp']:
                try:
                    result['ses_delta'][k] = int(last.get(k,0)) - int(first.get(k,0))
                except:
                    pass

    return result


# ─── Расчёт производных метрик ────────────────────────────────────────────────

def compute_state_times(events):
    """Считает время в каждом state из FSM событий."""
    times = defaultdict(int)
    for i in range(len(events) - 1):
        sec1, state, _, _, _ = events[i]
        sec2 = events[i+1][0]
        dt = sec2 - sec1
        if 0 < dt < 600:  # игнорируем огромные gaps (перезапуски)
            times[state] += dt
    return times


def thermal_escalation_rate(events):
    """°C в минуту в начале сессии (первые 3 минуты в heavy/gaming/sustained)."""
    heavy_events = [(s, t) for s, state, t, _, _ in events
                    if state in ('HEAVY', 'GAMING', 'SUSTAINED') and t > 0]
    if len(heavy_events) < 2:
        return None
    start = heavy_events[0]
    end   = None
    for ev in heavy_events:
        if ev[0] - start[0] >= 180:
            end = ev
            break
    if not end:
        end = heavy_events[-1]
    dt_sec = end[0] - start[0]
    dt_t   = end[1] - start[1]
    if dt_sec < 10:
        return None
    return dt_t / (dt_sec / 60.0)


# ─── Форматирование ───────────────────────────────────────────────────────────

def fmt_sec(s):
    if s < 60:
        return f"{s}s"
    return f"{s//60}m{s%60:02d}s"

def bar(value, max_val, width=20, char='█'):
    if max_val == 0:
        return ' ' * width
    filled = int(round(value / max_val * width))
    return char * filled + '░' * (width - filled)

def pct(part, total):
    if total == 0:
        return 0
    return int(round(part * 100 / total))


# ─── Отчёт ───────────────────────────────────────────────────────────────────

def print_report(sessions):
    sep = '═' * 72

    print(f"\n{sep}")
    print("  ASB SESSION ANALYZER")
    print(sep)

    for s in sessions:
        print(f"\n{'─'*72}")
        print(f"  Файл:    {s['filename']}")
        print(f"  Версия:  {s['version']}   режим: {s['highload_mode']}")
        if s.get('intent', 'unknown') != 'unknown':
            act = s.get('intent_action', '')
            act_str = f" → {act}" if act else ""
            print(f"  Intent:  {s['intent']}{act_str}")
        print(f"  Перезапусков governor: {s['restarts']}")

        # ── Время в состояниях
        times = compute_state_times(s['fsm_events'])
        total_active = sum(times.get(st, 0) for st in
                           ('HEAVY', 'GAMING', 'SUSTAINED', 'MODERATE'))
        total_all = sum(times.values())

        if total_all == 0 and len(s['fsm_events']) < 3:
            print(f"\n  ⚠ Timeline incomplete: governor.log has insufficient FSM events")
            print(f"    State distribution unavailable — log may be truncated or from a short session")
        print(f"\n  ┌─ Распределение времени (активных: {fmt_sec(total_active)}) ─")
        max_t = max((times.get(st, 0) for st in STATES), default=1)
        for st in STATES:
            t = times.get(st, 0)
            p = pct(t, total_all)
            b = bar(t, max_t, width=18)
            print(f"  │  {st:<12} {fmt_sec(t):>8}  {p:>3}%  {b}")

        # Дополняем из ses_delta если есть
        sd = s.get('ses_delta', {})
        if sd:
            print(f"\n  ┌─ Session telemetry (дельта от reset до конца) ─")
            t_h = sd.get('ses_t_heavy', 0)
            t_g = sd.get('ses_t_gaming', 0)
            t_s = sd.get('ses_t_sustained', 0)
            total_ses = t_h + t_g + t_s
            if total_ses > 0:
                print(f"  │  HEAVY     {fmt_sec(t_h):>8}  {pct(t_h, total_ses):>3}%")
                print(f"  │  GAMING    {fmt_sec(t_g):>8}  {pct(t_g, total_ses):>3}%")
                print(f"  │  SUSTAINED {fmt_sec(t_s):>8}  {pct(t_s, total_ses):>3}%")
            avg_gap = sd.get('ses_avg_gap_p0', 0)
            max_t_  = sd.get('ses_max_temp', 0)
            print(f"  │  avg_gap_p0: {avg_gap} kHz"
                  + ("  ← caps OK" if avg_gap < 300000 else
                     "  ← caps частично срезаются" if avg_gap < 800000 else
                     "  ← caps сильно срезаются ⚠"))
            print(f"  │  max_temp:   {max_t_}°C")

        # ── SUSTAINED эпизоды
        sus = s['sustained_events']
        if sus:
            dwells = [e[1] - e[0] for e in sus]
            avg_dwell = sum(dwells) // len(dwells) if dwells else 0
            fast_cycles = sum(1 for i in range(len(sus) - 1)
                              if sus[i+1][0] - sus[i][1] < 20)
            print(f"\n  ┌─ SUSTAINED эпизоды ({len(sus)} входов, avg dwell {avg_dwell}s) ─")
            for i, (t_in, t_out, temp_in, temp_out, reason) in enumerate(sus[:8]):
                dwell = t_out - t_in
                flag  = ' ← short' if dwell < 20 else ''
                print(f"  │  #{i+1:02d}  вход t={temp_in:>3}°C  выход t={temp_out:>3}°C"
                      f"  dwell={dwell:>4}s  [{reason}]{flag}")
            if len(sus) > 8:
                print(f"  │  ... ещё {len(sus)-8} эпизодов")
            if fast_cycles:
                print(f"  │  ⚠ быстрых cycling (<20s): {fast_cycles}")

        # ── Gap в GAMING
        gaps = s['gaming_gaps']
        if gaps:
            avg_gap = sum(gaps) // len(gaps)
            max_gap = max(gaps)
            print(f"\n  ┌─ Gap в GAMING ({len(gaps)} samples) ─")
            print(f"  │  avg: {avg_gap:>8} kHz  max: {max_gap:>8} kHz")
            if avg_gap < 200000:
                print(f"  │  ✓ Caps применяются хорошо")
            elif avg_gap < 800000:
                print(f"  │  ~ Caps частично срезаются vendor")
            else:
                print(f"  │  ⚠ Caps сильно срезаются — GAMING малоэффективен")

        # ── Thermal escalation
        rate = thermal_escalation_rate(s['fsm_events'])
        if rate is not None:
            print(f"\n  ┌─ Thermal ─")
            all_temps = [t for _, _, t, _, _ in s['fsm_events'] if t > 0]
            if all_temps:
                print(f"  │  min/max: {min(all_temps)}°C / {max(all_temps)}°C")
            print(f"  │  скорость прогрева: {rate:+.1f}°C/мин")
            if rate > 5:
                print(f"  │  ⚠ Быстрый прогрев — thermal collapse неизбежен")
            elif rate > 2:
                print(f"  │  ~ Умеренный прогрев")
            else:
                print(f"  │  ✓ Медленный прогрев")

        # ── Auto degrade
        if s['auto_degrade']:
            pct_str = f" (sus_pct={s['auto_degrade_pct']}%)" if s['auto_degrade_pct'] else ""
            print(f"\n  ┌─ Auto ─")
            print(f"  │  ✓ Деградация burst→stable сработала{pct_str}")
        elif s['highload_mode'] == 'auto':
            print(f"\n  ┌─ Auto ─")
            print(f"  │  ~ Деградация не сработала (условия не набраны)")

        # ── Explain: why decisions were made
        explain_lines = []
        if s['auto_degrade']:
            da = s.get('deg_age', 0)
            if da and da > 0:
                bucket = "fast" if da < 120 else "normal" if da <= 300 else "late"
                explain_lines.append(f"Decision: auto-degrade burst→stable at {da}s ({bucket})")
            sp = s.get('auto_degrade_pct', 0)
            if sp:
                explain_lines.append(f"  Why: sus_pct={sp}% exceeded threshold")
        if s.get('intent', 'unknown') != 'unknown':
            explain_lines.append(f"Decision: intent classified as {s['intent']}")
            act = s.get('intent_action', '')
            if act:
                explain_lines.append(f"  Action: {act}")
        for evt in s.get('self_tune_events', []):
            explain_lines.append(f"Decision: self-tune {evt}")
        for fb in s.get('feedback_events', []):
            if any(kw in fb for kw in ('history says', 'degraded', 'thermal wall',
                    'avg_t2s', 'avg_degrade_age', 'auto-burst', 'burst futile',
                    'bat_fast_idle', 'bat_moderate', 'bat_heavy', 'MODERATE')):
                explain_lines.append(f"Decision: startup {fb}")
        if explain_lines:
            print(f"\n  ┌─ Explain ─")
            for el in explain_lines:
                print(f"  │  {el}")

    # ─── Сравнение (если несколько файлов) ──────────────────────────────────
    if len(sessions) > 1:
        print(f"\n{sep}")
        print("  СРАВНЕНИЕ СЕССИЙ")
        print(sep)

        # Заголовок
        col_w = 18
        header = f"  {'Метрика':<30}" + "".join(
            f"{s['filename'][:col_w]:>{col_w}}" for s in sessions)
        print(header)
        print("  " + "─" * (30 + col_w * len(sessions)))

        def row(label, values):
            line = f"  {label:<30}"
            line += "".join(f"{str(v):>{col_w}}" for v in values)
            print(line)

        # Время в состояниях
        all_times = [compute_state_times(s['fsm_events']) for s in sessions]
        for st in ('HEAVY', 'GAMING', 'SUSTAINED'):
            vals = [fmt_sec(t.get(st, 0)) for t in all_times]
            row(f"Время в {st}", vals)

        # Доля SUSTAINED от активного времени
        def sus_ratio(t):
            active = sum(t.get(st, 0) for st in ('HEAVY','GAMING','SUSTAINED'))
            if active == 0: return "—"
            return f"{pct(t.get('SUSTAINED',0), active)}%"
        row("SUSTAINED % от активного", [sus_ratio(t) for t in all_times])

        # Перезапуски
        row("Перезапусков governor", [s['restarts'] for s in sessions])

        # Gap
        def avg_gap_str(s):
            g = s['gaming_gaps']
            if not g: return "нет данных"
            return f"{sum(g)//len(g)} kHz"
        row("avg gap в GAMING", [avg_gap_str(s) for s in sessions])

        # SUSTAINED эпизоды
        row("Входов в SUSTAINED", [s['sustained_entries'] for s in sessions])

        # Средний dwell
        def avg_dwell_str(s):
            sus = s['sustained_events']
            if not sus: return "—"
            d = [e[1]-e[0] for e in sus]
            return fmt_sec(sum(d)//len(d))
        row("Avg SUSTAINED dwell", [avg_dwell_str(s) for s in sessions])

        # Max temp
        def max_temp(s):
            temps = [t for _, _, t, _, _ in s['fsm_events'] if t > 0]
            return f"{max(temps)}°C" if temps else "—"
        row("Max температура", [max_temp(s) for s in sessions])

        # Thermal rate
        def rate_str(s):
            r = thermal_escalation_rate(s['fsm_events'])
            return f"{r:+.1f}°C/мин" if r is not None else "—"
        row("Скорость прогрева", [rate_str(s) for s in sessions])

        # Auto degrade
        def degrade_str(s):
            if s['highload_mode'] != 'auto': return "N/A"
            if s['auto_degrade']:
                p = s['auto_degrade_pct']
                return f"да ({p}%)" if p else "да"
            return "нет"
        row("Auto degrade", [degrade_str(s) for s in sessions])

        # ── Вердикт
        print(f"\n  {'─'*72}")
        print("  ВЕРДИКТ:")
        sus_ratios = []
        for t in all_times:
            active = sum(t.get(st, 0) for st in ('HEAVY','GAMING','SUSTAINED'))
            sus_ratios.append(pct(t.get('SUSTAINED',0), active) if active else 0)

        gaming_times = [t.get('GAMING', 0) for t in all_times]
        max_gaming_idx = gaming_times.index(max(gaming_times)) if max(gaming_times) > 0 else None

        min_sus_idx = sus_ratios.index(min(sus_ratios))

        if max_gaming_idx is not None:
            print(f"  Больше всего времени в GAMING: "
                  f"{sessions[max_gaming_idx]['filename']} "
                  f"({fmt_sec(gaming_times[max_gaming_idx])})")

        print(f"  Меньше всего SUSTAINED давления: "
              f"{sessions[min_sus_idx]['filename']} "
              f"({sus_ratios[min_sus_idx]}%)")

        restart_counts = [s['restarts'] for s in sessions]
        min_restart_idx = restart_counts.index(min(restart_counts))
        print(f"  Наиболее стабильный governor: "
              f"{sessions[min_restart_idx]['filename']} "
              f"({restart_counts[min_restart_idx]} перезапусков)")

    print(f"\n{sep}\n")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Использование: python3 asb_analyze.py log1.txt [log2.txt ...]")
        sys.exit(1)

    paths = sys.argv[1:]
    sessions = []
    for path in paths:
        if not os.path.exists(path):
            print(f"Файл не найден: {path}", file=sys.stderr)
            continue
        try:
            s = parse_log(path)
            sessions.append(s)
            print(f"Прочитан: {os.path.basename(path)}", file=sys.stderr)
        except Exception as e:
            print(f"Ошибка при чтении {path}: {e}", file=sys.stderr)

    if not sessions:
        print("Нет данных для анализа.")
        sys.exit(1)

    print_report(sessions)


if __name__ == '__main__':
    main()
