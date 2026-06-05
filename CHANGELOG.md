# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V48-16a34a?style=for-the-badge" alt="V48">
  <img src="https://img.shields.io/badge/Previous-V47-6b7280?style=for-the-badge" alt="V47">
  <img src="https://img.shields.io/badge/versionCode-480-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

## V48

### Smart Mode learning fixed

In V47, Smart Mode learning was effectively dead. The confidence gate dropped `eff_scale` to zero below 350/1000 confidence, mathematically erasing every seeded daypart prior to a neutral 500. Confidence accumulated slowly (~7 sessions just to reach the low gate), and learning fired only on profile switches. Users got no Smart Mode benefit for weeks.

V48 introduces **seed_baseline mode**: minimum 25% influence at zero confidence, scaling up as learning accumulates:

| Confidence | V47 influence | V48 influence |
|:--|:--|:--|
| < low (350) | 0% (neutral 500) | **25%** (seed honored) |
| low → high | 0% → 40% | **25% → 60%** |
| high → max | 40% → 100% | **60% → 100%** |

`EFF_OBS_FULL` lowered 2000 → 800 (full confidence in ~8 sessions vs ~20). `LEARN_RATE` raised 50 → 80.

### Continuous learning without profile switches

V47 fed bucket learning only on profile changes and 30-minute deep-idle boundaries. Users on permanent Smart Mode got zero learning during the day.

V48 adds two new learning triggers:
- **Bucket rollover** — when the time-of-day bucket changes (day → eve, eve → late), the previous bucket gets a session update.
- **Periodic** — every 20 minutes of active Smart use with non-trivial heavy time, a soft session fires.

Reasons appear in `session_history.jsonl` as `smart_bucket_rollover` and `smart_periodic`.

### Foreground package detection rebuilt

V47 detected packages via load heuristics only — `app_hint` stuck at MEDIUM even during 6-hour Call of Duty sessions, `pkg_hash` stayed at zero. Half of Smart Mode's design value was erased.

V48 uses a cascading detector: `dumpsys activity top` → `mResumedActivity` → `mCurrentFocus`. Each source has its own SELinux/availability characteristics; the cascade survives any one failing. A 60-second last-known-good cache rides out transient denies. System UI and launcher packages are filtered. Status reported per tick:
- `smart_pkg_detect_ok` — 1 if real package detected
- `smart_pkg_source` — which source (1/2/3) succeeded
- `smart_pkg_status` — OK / MISSING / STALE / SYS_UI

The mapping table covers known publishers (Activision, Tencent, miHoYo, HoYoverse, NetEase, Riot, EA, Gameloft, Supercell, Epic Games) plus substring fallback (`callofduty`, `.shooter`, `.cod`, `.codm`, `.pubg`, `freefire`, `genshin`, `fortnite`, `warzone`). Unknown packages that the FSM has independently classified as GAMING or SUSTAINED with CPU ≥ 58 °C are auto-upgraded to GAMING hint, so regional CODM variants and beta builds work without a table entry.

### Cap ownership and anti-thrash

V47 had no model of who actually controls cpufreq caps. ASB and vendor PowerHAL fought every tick — `cap_verify.txt` showed three sources (ASB declared, shell overridden, vendor clamped) racing, generating thousands of `DESYNC_shell_overridden_up` events per hour.

V48 introduces an effective cap owner model with two-mode anti-thrash:

- **Burst mode**: 3+ vendor clamps within 60 seconds → 15-second hold-down.
- **Slow-thrash mode**: 8+ vendor clamps within 5 minutes → same hold-down.

During hold-down, `asb_reconcile.sh` reads `cap_vendor_holddown=1` from `/dev/.asb/state` and skips re-applying caps. ASB and vendor stop fighting per tick. Owner state visible in both `state` and `conflicts.json` as `asb` / `shell` / `vendor` / `unknown`.

### Smart session accounting

V47 mapped Smart sessions silently into balanced counters. `learner_state.json` reported `trust_tier: unknown, balanced: 10` and zero Smart-specific anything — even when Smart was the active profile.

V48 adds a dedicated `smart_sessions` block:
- `total`, `day`, `night`, `gaming`
- `bucket_updates`
- `last_bucket_id`, `last_daypart`, `last_confidence`, `last_update_ts`

### Headroom trust on SM8850

On Snapdragon 8 Elite Gen 5, `msm_performance` returns optimistic headroom under thermal pressure — readings of 100% while CPU sits at 65 °C. V47's `stuck_100` detector required 10 consecutive max readings, which the oscillating signal never tripped.

V48 adds an `implausible_hot_100` detector: 3+ ticks of `headroom_pct ≥ 95 && cpu_max_c ≥ 60` immediately invalidates the signal with reason `implausible_hot`. Doesn't false-positive on actually-cool devices.

### Night-safe and idle-screen overrides

V47's night-safe override only fired for SLEEP and LATE dayparts, and required `battery_pct ≤ 60` (backwards logic — it's supposed to save battery overnight, not skip when battery is low).

V48 fixes both:
- `NIGHT_BAT_PCT_MAX` 60 → 100 (no battery threshold gating).
- WAKE daypart (06:00–09:00) included in night-safe condition when screen is off and not charging.
- New idle-screen override: after 30 minutes of screen-off + no heavy app + not charging, force alpha ≥ 850 regardless of daypart. Universal idle saver for daytime when the phone is left on a desk.

WAKE seed alpha raised 500 → 650 (early morning trends idle, not active).

### Dynamic system tuning

V48 re-applies lightweight system tweaks whenever the (foreground app hint, thermal bucket, screen state) signature changes. Rate-limited to once per 30 seconds:

| Setting | Idle | Light | Medium | Heavy | Gaming | Hot |
|:--|:--|:--|:--|:--|:--|:--|
| Block I/O read-ahead (KB) | 64 | 96 | 192 | 384 | 512 | 64 |
| `nr_requests` per device | 64 | 64 | 128 | 192 | 256 | 64 |
| `lru_gen/enabled` (MGLRU) | 5 | 5 | 5 | 7 | 7 | — |
| `vm.swappiness` | 100 | 100 | 100 | 80 | 60 | — |

Screen-off triggers `vm.laptop_mode=1` plus aggressive dirty ratios for fast writeback during idle. Screen-on heavy/gaming uses tight dirty ratios (5/2) to prevent writeback stalls.

### Animation scale and input timeouts

V47 unconditionally pushed each profile's `UX_ANIM_SCALE` into Android Settings on every profile apply, silently clobbering user-set values like 0.5 from Developer Options. Reported by an OP15 user whose `window_animation_scale` reset to 1.0 after every reboot and on charging events.

V48 makes these opt-in only. Default: ASB does not touch `window_animation_scale`, `transition_animation_scale`, `animator_duration_scale`, `long_press_timeout`, or `multi_press_timeout`. To restore V47 behaviour set `UX_MANAGE_ANIM_SCALE=1` or `UX_MANAGE_TIMEOUTS=1` in `governor.conf`.

### WebUI

Responsive layout added: phone-portrait by default, two-column metric grid on tablets and desktop, compact header on phone landscape. Smart Mode banner shows when active.

### Migration

V47 → V48 is in-place. Bucket store format unchanged (`ASB_SMART_VER = 1`); existing buckets carry over. Confidence values reset visually (`EFF_OBS_FULL` decreased) but real influence is larger thanks to seed_baseline.

Fresh installs: Smart Mode enabled by default. Existing V47 installs: previous behaviour preserved (Smart Mode flag respects the existing setting).

## File locations

| Path | Purpose |
|:--|:--|
| `/data/adb/asb/smart_mode_enabled` | Master on/off flag (0 or 1) |
| `/data/adb/asb/buckets.bin` | Persistent learned per-daypart store |
| `/data/adb/asb/session_history.jsonl` | Append-only session log (rotated at 5 MB) |
| `/dev/.asb/state` | Live key=value status, refreshed every tick |
| `/dev/.asb/learner_state.json` | Summary including `smart_sessions` block |
| `/dev/.asb/conflicts.json` | Vendor clamp and cap owner observability |
