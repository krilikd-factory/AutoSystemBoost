#!/usr/bin/env python3
"""
ASB Session Report — генерация Markdown-отчёта из session_history.jsonl

Использование:
    python3 asb_session_report.py /path/to/session_history.jsonl
    python3 asb_session_report.py /path/to/session_history.jsonl -o report.md

Читает session_history.jsonl (JSON Lines), строит сводку по всем сессиям,
тренды, рекомендации и экспортирует Markdown-отчёт.
"""
import json, sys, os
from datetime import datetime

def load_history(path):
    sessions = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line[0] != '{':
                continue
            try:
                sessions.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return sessions

def fmt_time(sec):
    if not sec or sec <= 0: return '—'
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    if h > 0: return f"{h}h{m:02d}m"
    return f"{m}m{s:02d}s" if m > 0 else f"{s}s"

def avg(lst):
    lst = [x for x in lst if x and x > 0]
    return sum(lst) / len(lst) if lst else 0

def generate_report(sessions):
    lines = []
    lines.append("# 📊 ASB Session History Report")
    lines.append(f"\nСгенерировано: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append(f"Сессий: **{len(sessions)}**\n")

    # Profiles breakdown
    profiles = {}
    for s in sessions:
        p = s.get('profile', 'unknown')
        profiles[p] = profiles.get(p, 0) + 1
    lines.append("## 📋 Профили")
    for p, c in sorted(profiles.items()):
        lines.append(f"- **{p}**: {c} сессий")
    lines.append("")

    # Main table
    lines.append("## 📈 Детали сессий\n")
    lines.append("| # | Время | Профиль | GAMING | SUSTAINED | Max T° | Avg Gap | Eff | Degraded | DEEP_IDLE | Wake |")
    lines.append("|---|-------|---------|--------|-----------|--------|---------|-----|----------|-----------|------|")
    for i, s in enumerate(sessions, 1):
        ts = s.get('ts', '?')
        profile = s.get('profile', '?')
        gaming = s.get('gaming', 0)
        sustained = s.get('sustained', 0)
        max_temp = s.get('max_temp', 0)
        avg_gap = s.get('avg_gap', 0)
        eff = s.get('eff', -1)
        eff_str = f"{eff}%" if eff >= 0 else '—'
        degraded = '⚠️' if s.get('degraded', 0) else '—'
        bat_deep = fmt_time(s.get('bat_deep', 0))
        bat_wake = s.get('bat_wake', 0)
        lines.append(f"| {i} | {ts} | {profile} | {gaming} | {sustained} | {max_temp}°C | {avg_gap} kHz | {eff_str} | {degraded} | {bat_deep} | {bat_wake} |")
    lines.append("")

    # Trends
    lines.append("## 📉 Тренды\n")
    temps = [s.get('max_temp', 0) for s in sessions if s.get('max_temp', 0) > 0]
    gaps = [s.get('avg_gap', 0) for s in sessions if s.get('avg_gap', 0) > 0]
    effs = [s.get('eff', -1) for s in sessions if s.get('eff', -1) >= 0]
    t2s_vals = [s.get('t2s', 0) for s in sessions if s.get('t2s', 0) > 0]
    degrade_count = sum(1 for s in sessions if s.get('degraded', 0))

    lines.append(f"| Метрика | Среднее | Мин | Макс |")
    lines.append(f"|---------|---------|-----|------|")
    if temps:
        lines.append(f"| Max температура | {avg(temps):.0f}°C | {min(temps)}°C | {max(temps)}°C |")
    if gaps:
        lines.append(f"| Avg cap gap | {avg(gaps):.0f} kHz | {min(gaps)} kHz | {max(gaps)} kHz |")
    if effs:
        lines.append(f"| Efficiency | {avg(effs):.0f}% | {min(effs)}% | {max(effs)}% |")
    if t2s_vals:
        lines.append(f"| Time to SUSTAINED | {fmt_time(avg(t2s_vals))} | {fmt_time(min(t2s_vals))} | {fmt_time(max(t2s_vals))} |")
    lines.append(f"| Auto degraded | {degrade_count} из {len(sessions)} сессий | | |")
    lines.append("")

    # Battery section
    bat_sessions = [s for s in sessions if s.get('profile') == 'battery']
    if bat_sessions:
        lines.append("## 🔋 Battery-сессии\n")
        bat_deeps = [s.get('bat_deep', 0) for s in bat_sessions]
        bat_wakes = [s.get('bat_wake', 0) for s in bat_sessions]
        bat_ttds = [s.get('bat_ttd', 0) for s in bat_sessions if s.get('bat_ttd', 0) > 0]
        bat_mods = [s.get('bat_mod', 0) for s in bat_sessions]

        lines.append(f"| Метрика | Среднее |")
        lines.append(f"|---------|---------|")
        lines.append(f"| DEEP_IDLE время | {fmt_time(avg(bat_deeps))} |")
        lines.append(f"| MODERATE время | {fmt_time(avg(bat_mods))} |")
        lines.append(f"| Wake cycles | {avg(bat_wakes):.1f} |")
        if bat_ttds:
            lines.append(f"| Time to first DEEP_IDLE | {fmt_time(avg(bat_ttds))} |")
        lines.append("")

    # Recommendations
    lines.append("## 💡 Рекомендации\n")
    recs = []
    if temps and avg(temps) >= 68:
        recs.append("🌡️ Средняя пиковая температура ≥ 68°C — рассмотри **stable** режим вместо burst")
    if effs and avg(effs) < 50:
        recs.append("📉 Средний efficiency < 50% — burst неэффективен, используй **stable** или **auto**")
    if degrade_count > len(sessions) * 0.6:
        recs.append(f"⚠️ Auto деградировал в {degrade_count}/{len(sessions)} сессий — burst часто недостижим")
    if t2s_vals and avg(t2s_vals) < 90:
        recs.append(f"⏱️ Среднее время до SUSTAINED < 90с — устройство быстро перегревается")
    if bat_sessions:
        if bat_wakes and avg(bat_wakes) > 5:
            recs.append("🔋 Слишком много wake cycles в battery — возможны шумные фоновые процессы")
    if not recs:
        recs.append("✅ Все метрики в норме")
    for r in recs:
        lines.append(f"- {r}")
    lines.append("")

    lines.append("---")
    lines.append("*Отчёт сгенерирован tools/asb_session_report.py*")
    return '\n'.join(lines)

def main():
    if len(sys.argv) < 2:
        print("Использование: asb_session_report.py session_history.jsonl [-o output.md]")
        sys.exit(1)

    path = sys.argv[1]
    output = None
    if '-o' in sys.argv:
        idx = sys.argv.index('-o')
        if idx + 1 < len(sys.argv):
            output = sys.argv[idx + 1]

    sessions = load_history(path)
    if not sessions:
        print(f"Нет данных в {path}")
        sys.exit(1)

    report = generate_report(sessions)

    if output:
        with open(output, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f"Отчёт записан: {output}")
    else:
        print(report)

if __name__ == '__main__':
    main()
