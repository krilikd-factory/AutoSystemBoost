# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V43-16a34a?style=for-the-badge" alt="V43">
  <img src="https://img.shields.io/badge/Previous-V42-6b7280?style=for-the-badge" alt="V42">
  <img src="https://img.shields.io/badge/versionCode-430-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

> **V43 ships a properly engineered Smart Reclaim Engine (new opt-in category `BG_TRIM`), config persistence so categories survive uninstall and reinstall, profile persistence across module reinstall, an integrated diagnostics readout in the Action button with a one-tap Telegram redirect, screen-aware VM compaction, Multi-Gen LRU when supported, a Tencent Soter auto-fix for WeChat/Alipay/Chinese banks, an `/system/bin/asb` wrapper so commands work from any terminal, and conflict resolution between `profiles/*.sh` startup values and `config/profile_bounds.conf` bounds. The Smart Reclaim Engine uses `am send-trim-memory` selectively on a curated allowlist (never trim-all-PIDs), assigns standby buckets correctly (active for messengers, working_set for camera/gallery, rare for heavy social media — and explicitly does NOT throttle GMS/Play Store), and applies cgroup v2 memcg `memory.low` protection / `memory.high` soft-throttle when available. VM tuning now has a single write path with screen-aware `compaction_proactiveness` (0/10/20). One audio property regression from V42 that kept the kernel awake after Bluetooth sessions is also fixed and auto-cleaned for upgraders.**

---

## ⚡ V43 — Smart Reclaim, Persistence, Recovery Engine

### 💾 Config Persistence — the most-requested user feature

V42 forced users to re-select all 15 categories every time they flashed an update. V43 fixes this.

`common/install.sh` writes your category choices to `/data/adb/asb_user_config` at the end of every install. The file lives **outside** the module directory, so it survives module uninstall + reinstall.

On every subsequent install or update, the installer detects the saved set and prompts:

```
================================================
  Saved configuration found
    from: 2026-05-20 12:30:00
    ver:  V43
  VOL+ = use saved  |  VOL- = re-select categories
================================================
```

- **VOL+** — apply saved choices, skip all 15 prompts (~3 seconds)
- **VOL-** — re-run interactive flow, save new choices
- **timeout (10s)** — defaults to saved (conservative outcome)

The active profile (`performance` / `balanced` / `battery`) is also mirrored to `/data/adb/asb_active_profile` — so your profile choice survives a module reinstall too. Previously, any reinstall reset the profile to the shipped default of `balanced`.

### 🧠 BG_TRIM — Smart Reclaim Engine (new opt-in category #15, default OFF)

The single new V43 category. Flashing V42 → V43 changes nothing unless you opt in.

**Design principles:**

1. **Selective trim only.** `am send-trim-memory` fires only on allowlisted background apps, checked against the current top app and screen state. Only `HIDDEN` (level 20) and `BACKGROUND` (level 40) — deprecated `MODERATE` / `COMPLETE` / `RUNNING_*` levels aren't delivered to apps on Android 14+ and would be wasted work.

2. **Explicit package groups, no wildcards.** Five groups by intended treatment:
   - **NEVER_TRIM**: launcher, keyboard, dialer, camera, maps, SystemUI — protected by memcg `memory.low`.
   - **MESSENGER**: WhatsApp, Telegram, Signal, Viber, Messenger, Discord, Teams, WeChat — bucket=`active`, no trim, memcg protection. Push notifications arrive instantly.
   - **RECENT_WORKSET**: gallery apps, photo editors, music players — bucket=`working_set`, HIDDEN trim only when screen is off.
   - **HEAVY**: Facebook, Instagram, Snapchat, TikTok, Netflix, AliExpress — bucket=`rare`, BACKGROUND trim, memcg `memory.high` soft-throttle (256MB).
   - **DISABLE**: 4 pure telemetry uploaders only (`midas`, `olc`, `crashbox`, `logkit`) — no ContentProviders, no IPC dependencies, no widgets, no user-visible features.

3. **GMS, GSF, Play Store, Quick Search NOT throttled.** Earlier prototypes placed them in `active` (wasted battery) or `rare` (broke push notifications). V43 leaves them at their system-assigned bucket — they self-schedule fine.

4. **OxygenOS Athena tuning, no `high_performance`.** `athena.reclaim_enable=1` allows reclaim. `athena.force_kill=0` prevents outright kills. `athena.limit_count=120` caps concurrent reclaim. `persist.sys.oplus.high_performance=1` is deliberately not set — it contradicts BG_TRIM's purpose.

5. **Memcg v2 (cgroup v2) when writable.** Probes `/sys/fs/cgroup/cgroup.controllers` presence. When available:
   - `memory.low=64MB` for NEVER_TRIM + MESSENGER groups (gentle protection)
   - `memory.high=256MB` for HEAVY group (soft reclaim pressure, not kill)
   - `memory.max` is **never** touched

6. **Top-app exclusion.** Before any trim, `dumpsys activity activities` resolves the current top app and BG_TRIM skips it. Launcher, keyboard, dialer, and any active media player stay safe.

7. **No aggressive Doze.** Stock Android Doze is sufficient. Custom `device_idle_constants` can delay notifications by up to 30 minutes — surprising the user is worse than the battery gain.

### 🔇 V42 audio HAL kernel-awake fix

A V42 user reported ~20% drain in a 10h workday with kernel held active for 8h41m. Root cause traced to two AUDIO category props set in V42:

```
audio.hal.output.suspend.supported=false
vendor.qc2audio.suspend.enabled=false
```

These prevent the audio HAL from suspending after Bluetooth audio sessions end — pipeline holds a wakelock, kernel stays awake.

V43 fix:
- Both props removed from `apply_audio_runtime()`
- Recovery hook explicitly `resetprop -p --delete`s both on every boot — V42 upgraders get cleanup automatically
- Hi-Fi codec, UHQA, AEC ref, matrix limiter — all preserved (these are audio quality, not power)

### 🔑 Tencent Soter Auto-Fix

WeChat, Alipay, and several Chinese banks use the Tencent Soter biometric protocol. On OnePlus global ROMs (CPH2745 in particular), the `vendor.soter` daemon often misbehaves after boot — users lose fingerprint authentication in those apps.

V43 ships an automatic background repair that runs once `sys.boot_completed=1`:

```
stop vendor.soter
pm clear com.tencent.soter.soterserver
start vendor.soter
```

Repeated continuously for 5 minutes. Pattern matches the proven SoterFix module by piska. Devices without Tencent apps are unaffected — the loop becomes a no-op when the package isn't present.

### 🎯 Action button — live status + Telegram redirect

Tap **Action** in the module list (Magisk / KSU) for an instant readout:

```
  ASB · battery

  🌡  CPU      : 39°C
  🔋 Battery  : 31.5°C   78%

  Estimated time to 0%:
    📱 screen on  : ~9h 22m
    💤 screen off : ~75h 0m

  Opening Telegram channel...
```

CPU temperature, battery temperature + level, time-to-empty estimates calibrated per profile (performance / balanced / battery). Then automatically opens the support Telegram channel.

### 🌡 VM tuning — single write path

V43-prereleases had bugs where new VM values were set then immediately overwritten by profile defaults. V43-release has a single final write path:

- `compaction_proactiveness` is profile-aware: **0** on performance, **10** on balanced, **20** on battery
- `lru_gen.enabled=7` when `/sys/kernel/mm/lru_gen/enabled` is writable (Android 14+, kernel 6.1+)

### ⚙️ Profile vs config bounds — 5 conflicts resolved

`config/profile_bounds.conf` is documented as the single source of truth for FSM bounds. Audit found 5 places where `profiles/*.sh` shipped values that violated config bounds:

| Profile | Variable | Was | Bounds (floor..ceil) | Fixed to |
|:--|:--|:--:|:--:|:--:|
| battery | `RAVG_TICKS` | 10 | 8..8 | 8 |
| battery | `UCL_TOP_MAX` | 58 | 35..50 | 50 |
| balanced | `UCL_TOP_MAX` | 90 | 50..85 | 85 |
| balanced | `UCL_BG_MAX` | 40 | 25..35 | 35 |
| performance | `GPU_MIN_PCT` | 10 | 8..20 | 8 |

The C governor at runtime clamped these into bounds anyway, so end behavior was correct — but the shell startup state held briefly-wrong values until the C governor reconciled. Now correct from the moment of boot.

### 🎯 Profile retuning from field telemetry

Three field captures analyzed (sleep 7.3h, mixed-use 5h+, gaming COD Mobile 144 fps). Performance and battery profiles re-tuned for less heat and lower drain without performance loss:

| Setting | Was | Now | Effect |
|:--|:--:|:--:|:--|
| `BATTERY_CPU_CAP_LITTLE` | 1132800 | 921600 | -19% — lower ceiling in HEAVY/MODERATE |
| `BATTERY_CPU_CAP_BIG` | 1113600 | 921600 | Aligned. Vendor already operates near this. |
| `BATTERY_CEIL_UCLAMP_TOP` | 58 | 50 | UI still snappy, less scheduler push |
| `PERFORMANCE_FLOOR_GPU_MIN_PCT` | 10 | 8 | Vendor reactive boost handles GPU on demand |
| `PERFORMANCE_CEIL_GPU_MIN_PCT` | 26 | 20 | Less idle GPU power between frames |
| `PERFORMANCE_FLOOR_UCLAMP_BG` | 45 | 35 | Game doesn't need background tasks at 45% |

BALANCED unchanged — field log shows it well-tuned already.

### 🧹 Code cleanup

`service.sh`, `common/install.sh`, all `runtime/*.sh`, all `profiles/*.sh`, all `tools/*.sh`, `apply_profile.sh`, `post-fs-data.sh`, `customize.sh`, `uninstall.sh`, and `action.sh` have been stripped of historical version markers (`# V39:`, `# V40:`, etc.) and decorative comment blocks. Only `#!/system/bin/sh` shebangs and `# ASB:CATEGORY:BEGIN/END` markers remain in shell sources. Multi-blank line runs squashed everywhere.

### ❌ What V43 deliberately does NOT do

- `persist.sys.oplus.high_performance=1` — contradicts BG_TRIM purpose
- `persist.sys.oplus.bg_limit` — vendor-state-fragile, varies between OxygenOS builds
- `memory.max` cgroup limits — too aggressive, kills apps
- Aggressive `device_idle_constants` — delays notifications by up to 30 min
- Wildcard `am set-standby-bucket` for `*gms*`, `*vending*`, `*messenger*` — wastes battery gain or breaks notifications
- Trim-all-PIDs loop — risks foreground apps, launcher, keyboard, active media
- `direct_compaction` knob tuning — no reliable cross-device path
- Disabling DeepThinker / Athena / customize.* / trafficmonitor — breaks AI widget, 3D wallpaper, Health steps widget, themes

### 📐 Lint

`tools/asb_lint.sh` now recognises `BG_TRIM` in `KNOWN_FEATURES`. The V42 bounds-source-of-truth check (`.sh` ↔ C header consistency) carries forward unchanged.

---
