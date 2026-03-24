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

def median(lst):
    lst = sorted([x for x in lst if x is not None and x > 0])
    if not lst: return 0
    n = len(lst)
    if n % 2 == 1: return lst[n // 2]
    return (lst[n // 2 - 1] + lst[n // 2]) / 2

def p90(lst):
    lst = sorted([x for x in lst if x is not None and x > 0])
    if not lst: return 0
    idx = int(len(lst) * 0.9)
    if idx >= len(lst): idx = len(lst) - 1
    return lst[idx]

# ── Session quality helpers ─────────────────────────────────────────────────

def session_trust(s):
    dur = s.get('dur', 0)
    iq  = s.get('idle_q', -1)
    bd  = s.get('bat_deep', 0)
    bw  = s.get('bat_wake', 0)
    prof = s.get('profile', '')
    intent = s.get('intent', '')

    if dur < 120:
        return 'dirty'
    if prof == 'battery' and intent == 'sleep_idle':
        return 'partial'
    if prof == 'battery' and dur > 3600 and bd < 120 and iq < 0 and bw <= 2:
        return 'partial'
    if iq == -1 and prof == 'battery' and dur > 300:
        return 'partial'
    return 'clean'

def battery_fail_reason(s):
    """
    For bad battery sessions, return specific reason tag.
    Returns None if session is not considered failed.
    """
    dur = s.get('dur', 0)
    iq  = s.get('idle_q', -1)
    bw  = s.get('bat_wake', 0)
    bd  = s.get('bat_deep', 0)
    bm  = s.get('bat_mod', 0)
    t_h = s.get('t_heavy', 0)

    if dur < 120:
        return None
    wph = bw * 3600 / dur if dur > 0 else 0
    heavy_pct = t_h / dur if dur > 0 else 0

    # Telemetry incomplete — not a real failure
    if dur > 3600 and bd < 120 and iq < 0 and bw <= 2:
        return 'incomplete_telemetry'
    if 0 <= iq < 20:
        return 'failed_to_settle'
    if heavy_pct > 0.5:
        return 'failed_by_screen_on'
    if wph > 8:
        return 'failed_by_wake_noise'
    if 0 <= iq < 40 and bm > bd:
        return 'moderate_dominated'
    return None

# ── Battery helper functions ────────────────────────────────────────────────

def battery_classify(s):
    """
    Classify battery session into one of five scenario types.
    Returns (class_label, emoji)

    Priority order:
    0. sleep_idle intent (from governor) — long uninterrupted sleep
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
    intent = s.get('intent', 'unknown')

    if dur < 120:
        return ('too short', '⏱')

    wph       = bw * 3600 / dur if dur > 0 else 0
    deep_pct  = bd / dur if dur > 0 else 0
    heavy_pct = t_h / dur if dur > 0 else 0

    # 0. Governor classified as sleep_idle — trust it
    if intent == 'sleep_idle':
        return ('screen-off efficient', '🌙')

    # 0b. Long uninterrupted deep: dur>=2h, wake/h<=1, deep_share>=70%
    if dur >= 7200 and wph <= 1.0 and deep_pct >= 0.70:
        return ('screen-off efficient', '🌙')

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


    # V29: Session closure warning
    if sessions:
        last = sessions[-1]
        if last.get("profile") == "performance" and last.get("end", "") not in ("profile_change", "idle_boundary", "shutdown"):
            lines.append("> ⚠️ **Last performance session may not be finalized.** Switch profile to flush history.\n")

    # V29: Benchmark/learn_exempt count
    bench_count = sum(1 for s in sessions if s.get("intent") == "benchmark" or s.get("learn_exempt", 0))
    if bench_count:
        lines.append(f"> 🎯 Benchmark sessions (learn_exempt): **{bench_count}**\n")

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
    lines.append("| # | Время | Профиль | Intent | GAMING | SUSTAINED | Max T° | Avg Gap | Eff | Degraded | DEEP_IDLE | Wake |")
    lines.append("|---|-------|---------|--------|--------|-----------|--------|---------|-----|----------|-----------|------|")
    for i, s in enumerate(sessions, 1):
        ts      = s.get('ts', '?')
        profile = s.get('profile', '?')
        intent  = s.get('intent', 'unknown')
        gaming  = s.get('gaming', 0)
        sus     = s.get('sustained', 0)
        mt      = s.get('max_temp', 0)
        ag      = s.get('avg_gap', 0)
        eff     = s.get('eff', -1)
        eff_str = f"{eff}%" if eff >= 0 else '—'
        deg     = '⚠️' if s.get('degraded', 0) else '—'
        bd      = fmt_time(s.get('bat_deep', 0))
        bw      = s.get('bat_wake', 0)
        lines.append(f"| {i} | {ts} | {profile} | {intent} | {gaming} | {sus} | {mt}°C | {ag} kHz | {eff_str} | {deg} | {bd} | {bw} |")
    lines.append("")

    # Trends
    lines.append("## 📉 Тренды\n")
    temps   = [s.get('max_temp', 0) for s in sessions if s.get('max_temp', 0) > 0]
    gaps    = [s.get('avg_gap', 0)  for s in sessions if s.get('avg_gap', 0) > 0]
    effs    = [s.get('eff', -1)     for s in sessions if s.get('eff', -1) >= 0]
    t2s_v   = [s.get('t2s', 0)     for s in sessions if s.get('t2s', 0) > 0]
    deg_cnt = sum(1 for s in sessions if s.get('degraded', 0))

    lines.append("| Метрика | Среднее | Медиана | P90 | Мин | Макс |")
    lines.append("|---------|---------|---------|-----|-----|------|")
    if temps: lines.append(f"| Max температура | {avg(temps):.0f}°C | {median(temps):.0f}°C | {p90(temps):.0f}°C | {min(temps)}°C | {max(temps)}°C |")
    if gaps:  lines.append(f"| Avg cap gap | {avg(gaps):.0f} kHz | {median(gaps):.0f} kHz | {p90(gaps):.0f} kHz | {min(gaps)} kHz | {max(gaps)} kHz |")
    if effs:  lines.append(f"| Efficiency | {avg(effs):.0f}% | {median(effs):.0f}% | | {min(effs)}% | {max(effs)}% |")
    if t2s_v: lines.append(f"| Time to SUSTAINED | {fmt_time(avg(t2s_v))} | {fmt_time(median(t2s_v))} | {fmt_time(p90(t2s_v))} | {fmt_time(min(t2s_v))} | {fmt_time(max(t2s_v))} |")
    lines.append(f"| Auto degraded | {deg_cnt} из {len(sessions)} сессий | | | | |")
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
        lines.append("| # | Время | Dur | Класс | Stability | Verdict | Reason | Trust | Wake/h | deep% | settle | idle_q |")
        lines.append("|---|-------|-----|-------|-----------|---------|--------|-------|--------|-------|--------|--------|")
        for i, (s, sc, cls, emo) in enumerate(scored, 1):
            dur  = s.get('dur', 0)
            ts   = s.get('ts', '?')
            bd   = s.get('bat_deep', 0)
            bw   = s.get('bat_wake', 0)
            ttd  = s.get('bat_ttd', 0)
            iq   = s.get('idle_q', -1)
            verd = battery_verdict(s)
            fr   = battery_fail_reason(s) or '—'
            tr   = session_trust(s)
            wph  = f"{bw * 3600 / dur:.1f}" if dur > 300 else "—"
            dpct = f"{bd * 100 // dur}%" if dur > 0 else "—"
            sc_s = str(sc) if sc >= 0 else "—"
            iq_s = str(iq) if iq >= 0 else "—"
            sett = fmt_time(ttd) if ttd > 0 else "—"
            dur_m = f"{dur // 60}m" if dur > 0 else "—"
            lines.append(f"| {i} | {ts} | {dur_m} | {emo} {cls} | {sc_s}/100 | {verd} | {fr} | {tr} | {wph} | {dpct} | {sett} | {iq_s} |")
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
            dur = s.get('dur', 0)
            bd = s.get('bat_deep', 0)
            bw = s.get('bat_wake', 0)
            bm = s.get('bat_mod', 0)
            # V28r3: detect telemetry incomplete (long session, tiny counters)
            if dur > 3600 and bd < 120 and iq < 0 and bw <= 2:
                flags.append(f"telemetry incomplete: dur={dur//60}m but bat_deep={bd}s (likely deep accounting bug on older build)")
            elif 0 <= iq < 30:
                flags.append(f"idle_q={iq} (poor)")
            if bw > 8: flags.append(f"wake={bw} (excessive)")
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
    # Intent-aware recommendations
    bench_sess = [s for s in sessions if s.get('intent') == 'benchmark']
    bench_deg  = sum(1 for s in bench_sess if s.get('degraded', 0))
    if bench_sess and bench_deg == len(bench_sess):
        recs.append("🎯 Все benchmark-сессии деградировали — burst бесполезен для бенчмарков на этом устройстве")
    bal_sess = [s for s in sessions if s.get('profile') == 'balanced']
    if len(bal_sess) >= 2:
        bal_temps = [s.get('max_temp', 0) for s in bal_sess if s.get('max_temp', 0) > 0]
        bal_sus   = [s.get('sus_pct', 0)  for s in bal_sess if s.get('sus_pct', 0) > 0]
        if bal_temps and avg(bal_temps) > 95:
            recs.append(f"⚖️ Balanced avg temp={avg(bal_temps):.0f}°C > 95°C — профиль слишком горячий")
        if bal_sus and avg(bal_sus) > 75:
            recs.append(f"⚖️ Balanced avg sus_pct={avg(bal_sus):.0f}% > 75% — слишком много времени в SUSTAINED")
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

    # ── Battery root-cause dashboard ──────────────────────────────────────
    if bat_sessions:
        cause_counts = {}
        for s in bat_sessions:
            r = battery_fail_reason(s)
            if r and r != 'incomplete_telemetry':
                cause_counts[r] = cause_counts.get(r, 0) + 1
        if cause_counts:
            lines.append("## 🔬 Battery Root Cause\n")
            total_bad = sum(cause_counts.values())
            dominant_cause = max(cause_counts, key=cause_counts.get)
            for reason, cnt in sorted(cause_counts.items(), key=lambda x: -x[1]):
                lines.append(f"- **{reason}**: {cnt} session{'s' if cnt > 1 else ''}")
            lines.append(f"\nDominant problem: **{dominant_cause}** ({cause_counts[dominant_cause]}/{total_bad})")
            lines.append("")

    # ── Performance hot_fail classification ────────────────────────────────
    perf_s = [s for s in sessions if s.get('profile') == 'performance' and s.get('max_temp', 0) >= 90]
    if perf_s:
        hf_reasons = {'early_thermal_spike': 0, 'early_sustained_entry': 0, 'efficiency_collapse': 0}
        for s in perf_s:
            t2s = s.get('t2s', 0)
            t2th = s.get('t2th', 0)
            eff = s.get('eff', 100)
            if t2th > 0 and t2th < 120:
                hf_reasons['early_thermal_spike'] += 1
            elif t2s > 0 and t2s < 90:
                hf_reasons['early_sustained_entry'] += 1
            elif eff >= 0 and eff < 60:
                hf_reasons['efficiency_collapse'] += 1
        active = {k: v for k, v in hf_reasons.items() if v > 0}
        if active:
            lines.append("## 🔥 Performance Heat Analysis\n")
            for reason, cnt in sorted(active.items(), key=lambda x: -x[1]):
                lines.append(f"- **{reason}**: {cnt} session{'s' if cnt > 1 else ''}")
            lines.append("")

    # ── Vendor Clamp / Headroom ───────────────────────────────────────────
    def classify_headroom(s):
        hr_n = s.get('hr_n', 0)
        hr_avg = s.get('hr_avg', -1)
        hr_min = s.get('hr_min', 100)
        ce = s.get('cap_eff', 100) if s.get('cap_eff', -1) >= 0 else 100
        mt = s.get('max_temp', 0)
        if hr_avg < 0 or hr_n <= 0:
            return "no_data", False, "low"
        if hr_n < 10:
            return "low_confidence", False, "low"
        conf = "high" if hr_n >= 30 else "medium"
        b70_pct = 100.0 * s.get('hr_b70', 0) / hr_n
        b50_pct = 100.0 * s.get('hr_b50', 0) / hr_n
        prof = s.get('profile', '')
        thermal_hot = mt >= (90 if prof == 'performance' else 80)
        early = (hr_min < 50 and b50_pct >= 10) or (hr_avg < 65 and b70_pct >= 25)
        if ce >= 70 and b70_pct < 10 and hr_min >= 70:
            return "reachable", early, conf
        if ce < 55 and (b50_pct >= 15 or hr_min < 50) and not thermal_hot:
            return "vendor_clamp", early, conf
        if thermal_hot and (b70_pct >= 20 or ce < 60):
            return "thermal", early, conf
        if ce < 70 or b70_pct >= 10 or hr_min < 70:
            return "mixed_limited", early, conf
        return "reachable", early, conf

    hr_sessions = [s for s in sessions
                   if s.get('profile') in ('performance', 'balanced')
                   and s.get('hr_avg', -1) >= 0
                   and session_trust(s) == 'clean']
    if hr_sessions:
        lines.append("## 🏭 Vendor Clamp / Headroom\n")
        for prof_name in ('performance', 'balanced'):
            prof_hr = [s for s in hr_sessions if s.get('profile') == prof_name]
            if not prof_hr:
                continue
            lines.append(f"### {prof_name.capitalize()} ({len(prof_hr)} session{'s' if len(prof_hr) != 1 else ''})\n")
            verdicts = {}
            weighted = {}  # verdict -> total duration
            for s in prof_hr:
                ts_s = s.get('ts', '?')
                ha = s.get('hr_avg', -1)
                hm = s.get('hr_min', -1)
                ce = s.get('cap_eff', -1)
                dur = s.get('dur', 0)
                dur_m = int(dur / 60) if dur > 0 else 0
                hr_n = s.get('hr_n', 0)
                b70_pct = int(100 * s.get('hr_b70', 0) / hr_n) if hr_n > 0 else 0
                b50_pct = int(100 * s.get('hr_b50', 0) / hr_n) if hr_n > 0 else 0
                verdict, early, conf = classify_headroom(s)
                verdicts[verdict] = verdicts.get(verdict, 0) + 1
                w = hr_n if hr_n > 0 else max(dur, 1)
                weighted[verdict] = weighted.get(verdict, 0) + w
                early_s = ", early collapse" if early else ""
                lines.append(f"- {ts_s} ({dur_m}min): avg={ha}% worst={hm}% "
                             f"<70={b70_pct}% <50={b50_pct}% cap_eff={ce}% "
                             f"**{verdict}**{early_s}")
            # Duration-weighted aggregate for this profile
            total_w = sum(weighted.values()) or 1
            vc_w = weighted.get('vendor_clamp', 0) / total_w
            th_w = weighted.get('thermal', 0) / total_w
            re_w = weighted.get('reachable', 0) / total_w
            avg_ha = int(sum(s.get('hr_avg', 0) for s in prof_hr) / len(prof_hr))
            min_hm = min(s.get('hr_min', 100) for s in prof_hr)
            if vc_w >= 0.5:
                dom = "vendor_clamp"
            elif th_w >= 0.5:
                dom = "thermal"
            elif re_w >= 0.6:
                dom = "reachable"
            else:
                dom = "mixed"
            lines.append(f"\n> Dominant limiter: **{dom}** (avg_headroom={avg_ha}%, worst={min_hm}%)\n")
        lines.append("")

    # ── Data Quality (per-profile trust) ──────────────────────────────────
    trust_by_profile = {}
    for s in sessions:
        p = s.get('profile', 'unknown')
        t = session_trust(s)
        if p not in trust_by_profile:
            trust_by_profile[p] = {'clean': 0, 'partial': 0, 'dirty': 0}
        trust_by_profile[p][t] = trust_by_profile[p].get(t, 0) + 1
    total_partial = sum(v.get('partial', 0) for v in trust_by_profile.values())
    total_dirty = sum(v.get('dirty', 0) for v in trust_by_profile.values())
    total_clean = sum(v.get('clean', 0) for v in trust_by_profile.values())
    lines.append("## 🔍 Data Quality\n")
    lines.append(f"- **clean**: {total_clean} — **partial**: {total_partial} — **dirty**: {total_dirty}")
    if len(trust_by_profile) > 1:
        for prof in ('battery', 'balanced', 'performance'):
            tc = trust_by_profile.get(prof)
            if tc:
                parts = [f"{k}={v}" for k, v in tc.items() if v > 0]
                lines.append(f"  - {prof}: {', '.join(parts)}")
    if total_partial > 0:
        lines.append(f"- partial sessions excluded from learning/tuning")
    if total_dirty > 0:
        lines.append(f"- dirty sessions excluded from scoring")
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
        if avg_sp > 50: hlsum += ", sustained-dominant"
        elif avg_sp > 0: hlsum += ", balanced workload"
        # Add headroom summary if available (hr_n weighted)
        hl_hr = [s for s in hl if s.get('hr_avg', -1) >= 0 and session_trust(s) == 'clean']
        if hl_hr:
            w_sum = 0; w_den = 0
            w_verdicts = {}
            for s in hl_hr:
                v, _, _ = classify_headroom(s)
                if v in ('no_data', 'low_confidence'): continue
                hr_n = s.get('hr_n', 0)
                dur_s = s.get('dur', 0)
                w = hr_n if hr_n > 0 else max(dur_s, 1)
                w_sum += w * s.get('hr_avg', 0)
                w_den += w
                w_verdicts[v] = w_verdicts.get(v, 0) + w
            if w_den > 0:
                avg_hr = int(w_sum / w_den)
                total_w = sum(w_verdicts.values()) or 1
                if w_verdicts.get('vendor_clamp', 0) / total_w >= 0.4:
                    hlsum += f" (vendor-clamped, headroom={avg_hr}%)"
                elif w_verdicts.get('thermal', 0) / total_w >= 0.4:
                    hlsum += f" (thermal-limited, headroom={avg_hr}%)"
                elif avg_hr < 80:
                    hlsum += f" (mixed-limited, headroom={avg_hr}%)"
        lines.append(f"- **High-load**: {hlsum}")
    deg = sum(1 for s in sessions if s.get('degraded', 0))
    auto_s = [s for s in sessions if s.get('mode') == 'auto']
    if auto_s:
        lines.append(f"- **Auto**: degraded in {deg}/{len(auto_s)} sessions")
    deg_ages = [s.get('deg_age', 0) for s in sessions if s.get('deg_age', 0) > 0]
    if deg_ages:
        avg_da = sum(deg_ages) / len(deg_ages)
        lines.append(f"- **Degrade speed**: avg {avg_da:.0f}s from session start "
                     f"(min {min(deg_ages)}s, max {max(deg_ages)}s)")
        fast = sum(1 for d in deg_ages if d < 120)
        normal = sum(1 for d in deg_ages if 120 <= d <= 300)
        late = sum(1 for d in deg_ages if d > 300)
        lines.append(f"- **Degrade buckets**: fast(<120s)={fast}, normal(120-300s)={normal}, late(>300s)={late}")
    intents = {}
    for s in sessions:
        it = s.get('intent', 'unknown')
        intents[it] = intents.get(it, 0) + 1
    if any(k != 'unknown' for k in intents):
        intent_parts = [f"{k}={v}" for k, v in sorted(intents.items()) if k != 'unknown']
        lines.append(f"- **Intent**: {', '.join(intent_parts)}")
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
