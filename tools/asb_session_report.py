#!/usr/bin/env python3
"""
ASB Session Report — генерация Markdown-отчёта из session_history.jsonl

Использование:
    python3 asb_session_report.py /path/to/session_history.jsonl
    python3 asb_session_report.py /path/to/session_history.jsonl -o report.md
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
    lst = [x for x in lst if x is not None and x > 0]
    return sum(lst) / len(lst) if lst else 0

# ── Battery helper functions ────────────────────────────────────────────────

def battery_classify(s):
    """
    Classify battery session into one of four scenario types.
    Returns (class_label, emoji)

    Priority order:
    1. screen-on moderate-heavy  — device was being used actively
    2. screen-off efficient      — device rested well
    3. screen-off noisy          — screen off but too many wakes
    4. mixed unstable            — unclear pattern
    """
    dur = s.get('dur', 0)
    iq  = s.get('idle_q', -1)
    bw  = s.get('bat_wake', 0)
    bd  = s.get('bat_deep', 0)
    t_h = s.get('t_heavy', 0)

    if dur < 120:
        return ('too short', '⏱')

    wph       = bw * 3600 / dur if dur > 0 else 0
    deep_pct  = bd / dur if dur > 0 else 0
    heavy_pct = t_h / dur if dur > 0 else 0

    # 1. Screen-on: heavy load dominated OR very poor idle quality OR no deep idle
    if iq >= 0 and iq < 40 and heavy_pct > 0.3:
        return ('screen-on moderate-heavy', '📱')
    if heavy_pct > 0.5 and deep_pct < 0.05:
        return ('screen-on moderate-heavy', '📱')

    # 2. Screen-off efficient: device rested well
    #    Either deep%=100% or (wake/h <= 1 and deep%>=10%) or idle_q>=85
    if deep_pct >= 0.99 and wph <= 1.0:
        return ('screen-off efficient', '🌙')
    if wph <= 1.0 and deep_pct >= 0.1:
        return ('screen-off efficient', '🌙')
    if iq >= 85 and wph <= 2.5:
        return ('screen-off efficient', '🌙')
    if iq >= 60 and wph <= 5 and heavy_pct < 0.5:
        return ('screen-off efficient', '🌙')

    # 3. Screen-off noisy: wake rate too high
    if wph > 8:
        return ('screen-off noisy', '🔔')

    return ('mixed unstable', '⚠️')

def battery_stability_score(s):
    """
    Composite battery stability score 0-100.
    Higher = better battery behaviour.
    Components:
      deep_share (40pts): share of time in DEEP_IDLE
      settle_speed (20pts): how fast device settled (ttd)
      wake_discipline (25pts): wakes per hour
      idle_quality (15pts): raw idle_q
    """
    dur = s.get('dur', 0)
    if dur < 60:
        return -1

    iq   = s.get('idle_q', -1)
    bw   = s.get('bat_wake', 0)
    bd   = s.get('bat_deep', 0)
    ttd  = s.get('bat_ttd', 0)

    # deep_share component (0-40)
    # If idle_q is excellent, deep% is less relevant — device was clearly idle
    deep_share = bd / dur if dur > 0 else 0
    if iq >= 85:
        pts_deep = min(40, max(20, int(deep_share * 40) + 15))
    else:
        pts_deep = min(40, int(deep_share * 40))

    # settle speed component (0-20)
    # If idle_q is excellent, device clearly settled — don't penalize bat_ttd
    if iq >= 85:
        pts_settle = 18  # device settled well, proven by idle_q
    elif ttd <= 0:
        pts_settle = 10  # no data, neutral
    elif ttd <= 60:
        pts_settle = 20
    elif ttd <= 300:
        pts_settle = 15
    elif ttd <= 600:
        pts_settle = 8
    else:
        pts_settle = 2

    # wake discipline component (0-25)
    wph = bw * 3600 / dur if dur > 0 else 0
    if wph <= 1:
        pts_wake = 25
    elif wph <= 3:
        pts_wake = 20
    elif wph <= 6:
        pts_wake = 12
    elif wph <= 12:
        pts_wake = 5
    else:
        pts_wake = 0

    # idle_quality component (0-15)
    if iq < 0:
        pts_iq = 7  # no data, neutral
    elif iq >= 80:
        pts_iq = 15
    elif iq >= 60:
        pts_iq = 11
    elif iq >= 40:
        pts_iq = 7
    elif iq >= 20:
        pts_iq = 3
    else:
        pts_iq = 0

    return pts_deep + pts_settle + pts_wake + pts_iq

def battery_verdict(s):
    """Hierarchical verdict string."""
    iq  = s.get('idle_q', -1)
    bw  = s.get('bat_wake', 0)
    bd  = s.get('bat_deep', 0)
    bm  = s.get('bat_mod', 0)
    dur = s.get('dur', 0)

    if dur < 120:
        return 'too short'
    if iq >= 0 and iq < 20:
        return 'failed to settle'
    if 0 <= iq < 40 and bm > 0 and bm > bd:
        return 'moderate-heavy'
    if iq >= 40 and bw > 6:
        return 'noisy'
    if iq >= 70 and bw <= 3:
        return 'healthy'
    if iq < 0 and dur < 300:
        return 'too short'
    return 'mixed'

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
        ts      = s.get('ts', '?')
        profile = s.get('profile', '?')
        gaming  = s.get('gaming', 0)
        sus     = s.get('sustained', 0)
        mt      = s.get('max_temp', 0)
        ag      = s.get('avg_gap', 0)
        eff     = s.get('eff', -1)
        eff_str = f"{eff}%" if eff >= 0 else '—'
        deg     = '⚠️' if s.get('degraded', 0) else '—'
        bd      = fmt_time(s.get('bat_deep', 0))
        bw      = s.get('bat_wake', 0)
        lines.append(f"| {i} | {ts} | {profile} | {gaming} | {sus} | {mt}°C | {ag} kHz | {eff_str} | {deg} | {bd} | {bw} |")
    lines.append("")

    # Trends
    lines.append("## 📉 Тренды\n")
    temps   = [s.get('max_temp', 0) for s in sessions if s.get('max_temp', 0) > 0]
    gaps    = [s.get('avg_gap', 0)  for s in sessions if s.get('avg_gap', 0) > 0]
    effs    = [s.get('eff', -1)     for s in sessions if s.get('eff', -1) >= 0]
    t2s_v   = [s.get('t2s', 0)     for s in sessions if s.get('t2s', 0) > 0]
    deg_cnt = sum(1 for s in sessions if s.get('degraded', 0))

    lines.append("| Метрика | Среднее | Мин | Макс |")
    lines.append("|---------|---------|-----|------|")
    if temps: lines.append(f"| Max температура | {avg(temps):.0f}°C | {min(temps)}°C | {max(temps)}°C |")
    if gaps:  lines.append(f"| Avg cap gap | {avg(gaps):.0f} kHz | {min(gaps)} kHz | {max(gaps)} kHz |")
    if effs:  lines.append(f"| Efficiency | {avg(effs):.0f}% | {min(effs)}% | {max(effs)}% |")
    if t2s_v: lines.append(f"| Time to SUSTAINED | {fmt_time(avg(t2s_v))} | {fmt_time(min(t2s_v))} | {fmt_time(max(t2s_v))} |")
    lines.append(f"| Auto degraded | {deg_cnt} из {len(sessions)} сессий | | |")
    lines.append("")

    # ── Battery deep section ────────────────────────────────────────────────
    bat_sessions = [s for s in sessions if s.get('profile') == 'battery']
    if bat_sessions:
        lines.append("## 🔋 Battery Executive Summary\n")

        # Compute stability scores
        scored = []
        for s in bat_sessions:
            sc = battery_stability_score(s)
            cls, emo = battery_classify(s)
            scored.append((s, sc, cls, emo))

        valid = [(s, sc, cls, emo) for s, sc, cls, emo in scored if sc >= 0]
        if valid:
            best  = max(valid, key=lambda x: x[1])
            worst = min(valid, key=lambda x: x[1])

        # Per-session battery report
        lines.append("| # | Время | Dur | Класс | Stability | Verdict | Wake/h | deep% | settle | idle_q |")
        lines.append("|---|-------|-----|-------|-----------|---------|--------|-------|--------|--------|")
        for i, (s, sc, cls, emo) in enumerate(scored, 1):
            dur  = s.get('dur', 0)
            ts   = s.get('ts', '?')
            bd   = s.get('bat_deep', 0)
            bw   = s.get('bat_wake', 0)
            ttd  = s.get('bat_ttd', 0)
            iq   = s.get('idle_q', -1)
            verd = battery_verdict(s)
            wph  = f"{bw * 3600 / dur:.1f}" if dur > 300 else "—"
            dpct = f"{bd * 100 // dur}%" if dur > 0 else "—"
            sc_s = str(sc) if sc >= 0 else "—"
            iq_s = str(iq) if iq >= 0 else "—"
            sett = fmt_time(ttd) if ttd > 0 else "—"
            dur_m = f"{dur // 60}m" if dur > 0 else "—"
            lines.append(f"| {i} | {ts} | {dur_m} | {emo} {cls} | {sc_s}/100 | {verd} | {wph} | {dpct} | {sett} | {iq_s} |")
        lines.append("")

        # Best / worst
        if valid:
            b_s, b_sc, b_cls, b_emo = best
            w_s, w_sc, w_cls, w_emo = worst
            lines.append(f"**Лучшая сессия:** {b_s.get('ts')} — {b_emo} {b_cls} ({b_sc}/100)  ")
            lines.append(f"**Худшая сессия:** {w_s.get('ts')} — {w_emo} {w_cls} ({w_sc}/100)\n")

        # Grouping
        groups = {}
        for s, sc, cls, emo in scored:
            groups.setdefault(cls, []).append((s, sc))

        lines.append("### Группировка по сценарию\n")
        for cls in ['screen-off efficient', 'screen-off noisy', 'screen-on moderate-heavy', 'mixed unstable', 'too short']:
            if cls not in groups: continue
            g = groups[cls]
            _, emo = battery_classify(g[0][0])
            avg_sc = avg([sc for _, sc in g if sc >= 0])
            avg_iq_v = avg([s.get('idle_q', -1) for s, _ in g if s.get('idle_q', -1) >= 0])
            avg_wph  = avg([s.get('bat_wake', 0) * 3600 / s.get('dur', 1)
                            for s, _ in g if s.get('dur', 0) > 300])
            lines.append(f"- {emo} **{cls}** ({len(g)} сессий) — stability avg={avg_sc:.0f}/100,"
                         f" idle_q avg={avg_iq_v:.0f}, wake/h avg={avg_wph:.1f}")
        lines.append("")

        # Normalized battery metrics table
        lines.append("### Нормализованные метрики\n")
        lines.append("| # | Время | Duration | Wake/h | Moderate/h | deep% | settle_norm |")
        lines.append("|---|-------|----------|--------|------------|-------|-------------|")
        for i, s in enumerate(bat_sessions, 1):
            dur = s.get('dur', 0)
            if dur < 60: continue
            bw  = s.get('bat_wake', 0)
            bm  = s.get('bat_mod', 0)
            bd  = s.get('bat_deep', 0)
            ttd = s.get('bat_ttd', 0)
            wph    = f"{bw * 3600 / dur:.1f}"
            mph    = f"{bm * 3600 / dur:.0f}s/h"
            dpct   = f"{bd * 100 // dur}%"
            snorm  = f"{ttd * 100 // dur}%" if ttd > 0 and dur > 0 else "—"
            dur_m  = f"{dur // 60}m"
            lines.append(f"| {i} | {s.get('ts','?')} | {dur_m} | {wph} | {mph} | {dpct} | {snorm} |")
        lines.append("")

    # ── Per-profile summary ─────────────────────────────────────────────────
    lines.append("## 📊 Сводка по профилям\n")
    for prof in ['performance', 'balanced', 'battery']:
        psess = [s for s in sessions if s.get('profile') == prof]
        if not psess: continue
        lines.append(f"### {prof.capitalize()} ({len(psess)} сессий)\n")
        # Common metrics
        m_iq  = avg([s.get('idle_q', -1)  for s in psess if s.get('idle_q', -1) >= 0])
        m_ce  = avg([s.get('cap_eff', -1) for s in psess if s.get('cap_eff', -1) >= 0])
        m_sp  = avg([s.get('sus_pct', 0)  for s in psess if s.get('sus_pct', 0) > 0])
        m_wph = avg([s.get('bat_wake', 0) * 3600 / s.get('dur', 1)
                     for s in psess if s.get('dur', 0) > 300])
        m_ttd = avg([s.get('bat_ttd', 0)  for s in psess if s.get('bat_ttd', 0) > 0])
        m_mt  = avg([s.get('max_temp', 0) for s in psess if s.get('max_temp', 0) > 0])
        m_t2s = avg([s.get('t2s', 0)      for s in psess if s.get('t2s', 0) > 0])
        m_eff = avg([s.get('eff', -1)     for s in psess if s.get('eff', -1) >= 0])

        rows = []
        if m_mt  > 0:   rows.append(("Avg max temp",   f"{m_mt:.0f}°C"))
        if m_t2s > 0:   rows.append(("Avg time to SUSTAINED", fmt_time(m_t2s)))
        if m_eff > 0:   rows.append(("Avg efficiency",  f"{m_eff:.0f}%"))
        if m_sp  > 0:   rows.append(("Avg sus_pct",     f"{m_sp:.0f}%"))
        if m_ce  > 0:   rows.append(("Avg cap_eff",     f"{m_ce:.0f}%"))
        if m_iq  > 0:   rows.append(("Avg idle_q",      f"{m_iq:.0f}"))
        if m_wph > 0:   rows.append(("Avg wake/hour",   f"{m_wph:.1f}"))
        if m_ttd > 0:   rows.append(("Avg settle time", fmt_time(m_ttd)))

        if rows:
            lines.append("| Метрика | Среднее |")
            lines.append("|---------|---------|")
            for k, v in rows:
                lines.append(f"| {k} | {v} |")
        lines.append("")

    # ── Anomaly detection ───────────────────────────────────────────────────
    anomalies = []
    for i, s in enumerate(sessions, 1):
        flags = []
        if s.get('profile') == 'battery':
            iq = s.get('idle_q', -1)
            if 0 <= iq < 30: flags.append(f"idle_q={iq} (poor)")
            bw = s.get('bat_wake', 0)
            if bw > 8: flags.append(f"wake={bw} (excessive)")
            bd, bm = s.get('bat_deep', 0), s.get('bat_mod', 0)
            if bm > 0 and bd > 0 and bm > bd * 2: flags.append(f"MODERATE={bm}s >> DEEP={bd}s")
        if s.get('profile') in ('performance', 'balanced'):
            ce = s.get('cap_eff', -1)
            if 0 <= ce < 50: flags.append(f"cap_eff={ce}% (low)")
            mt = s.get('max_temp', 0)
            if mt > 95: flags.append(f"max_temp={mt}°C (extreme)")
        if flags:
            anomalies.append((i, s.get('ts', '?'), s.get('profile', '?'), flags))

    if anomalies:
        lines.append("## ⚠️ Anomalies\n")
        for idx, ts, prof, flags in anomalies:
            sev = "**CRITICAL**" if len(flags) >= 2 else "warning"
            lines.append(f"- [{sev}] #{idx} ({ts}, {prof}): {', '.join(flags)}")
        lines.append("")

    # ── Normalized metrics table ────────────────────────────────────────────
    if any(s.get('dur', 0) > 300 for s in sessions):
        lines.append("## 📐 Normalized Metrics\n")
        lines.append("| # | Profile | Duration | Sustained/10min | Thermal/10min | Wake/hour |")
        lines.append("|---|---------|----------|-----------------|---------------|-----------|")
        for i, s in enumerate(sessions, 1):
            d = s.get('dur', 0)
            if d < 60: continue
            prof  = s.get('profile', '?')
            dm    = f"{d // 60}m"
            s10   = f"{s.get('sustained', 0) * 600 / d:.1f}" if d > 0 else "—"
            t10   = f"{s.get('thermal', 0) * 600 / d:.1f}" if d > 0 else "—"
            wph   = f"{s.get('bat_wake', 0) * 3600 / d:.1f}" if d > 0 and prof == 'battery' else "—"
            lines.append(f"| {i} | {prof} | {dm} | {s10} | {t10} | {wph} |")
        lines.append("")

    # ── Recommendations ─────────────────────────────────────────────────────
    lines.append("## 💡 Рекомендации\n")
    recs = []
    if temps and avg(temps) >= 68:
        recs.append("🌡️ Средняя пиковая температура ≥ 68°C — рассмотри **stable** режим")
    if effs and avg(effs) < 50:
        recs.append("📉 Средний efficiency < 50% — burst неэффективен")
    if deg_cnt > len(sessions) * 0.6:
        recs.append(f"⚠️ Auto деградировал в {deg_cnt}/{len(sessions)} сессий")
    if t2s_v and avg(t2s_v) < 90:
        recs.append("⏱️ Среднее время до SUSTAINED < 90с — устройство быстро перегревается")
    if bat_sessions:
        bat_wakes = [s.get('bat_wake', 0) for s in bat_sessions]
        if bat_wakes and avg(bat_wakes) > 5:
            recs.append("Battery: слишком много wake cycles — проверь фоновые приложения")
        bat_iqs = [s.get('idle_q', -1) for s in bat_sessions if s.get('idle_q', -1) >= 0]
        if bat_iqs and avg(bat_iqs) < 40:
            recs.append(f"Battery: idle_q avg={int(avg(bat_iqs))} — MODERATE доминирует")
    # Never say "all normal" if there are warnings or anomalies
    if not recs:
        if anomalies:
            recs.append("⚠️ See anomalies section above")
        else:
            recs.append("All metrics within normal range ✓")
    elif anomalies and "anomalies" not in " ".join(recs):
        recs.append("⚠️ See anomalies section above")
    for r in recs:
        lines.append(f"- {r}")
    lines.append("")

    # ── Executive summary ───────────────────────────────────────────────────
    lines.append("## 📋 Summary\n")
    if bat_sessions:
        stab_scores = [battery_stability_score(s) for s in bat_sessions if battery_stability_score(s) >= 0]
        avg_stab = int(avg(stab_scores)) if stab_scores else -1
        cls_counts = {}
        for s in bat_sessions:
            c, _ = battery_classify(s)
            cls_counts[c] = cls_counts.get(c, 0) + 1
        dominant = max(cls_counts, key=cls_counts.get) if cls_counts else "unknown"
        bat_anom = sum(1 for _, _, p, _ in anomalies if p == 'battery')
        grade = "excellent" if avg_stab >= 80 else "good" if avg_stab >= 60 else "fair" if avg_stab >= 40 else "poor"
        lines.append(f"- **Battery**: stability={avg_stab}/100 ({grade}), "
                     f"dominant={dominant}, {bat_anom} anomal{'y' if bat_anom == 1 else 'ies'}")
    hl = [s for s in sessions if s.get('profile') in ('performance', 'balanced')
          and s.get('gaming', 0) + s.get('sustained', 0) > 0]
    if hl:
        avg_ce = avg([s.get('cap_eff', -1) for s in hl if s.get('cap_eff', -1) >= 0])
        avg_sp = avg([s.get('sus_pct', 0)  for s in hl if s.get('sus_pct', 0) > 0])
        hlsum  = f"cap_eff={int(avg_ce)}%" if avg_ce > 0 else "no cap data"
        if avg_sp > 50: hlsum += ", sustained-dominant (thermal limited)"
        elif avg_sp > 0: hlsum += ", balanced workload"
        lines.append(f"- **High-load**: {hlsum}")
    deg = sum(1 for s in sessions if s.get('degraded', 0))
    auto_s = [s for s in sessions if s.get('mode') == 'auto']
    if auto_s:
        lines.append(f"- **Auto**: degraded in {deg}/{len(auto_s)} sessions")
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
