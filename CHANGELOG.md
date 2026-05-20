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

## ⚡ V42 — Automation, Audio, and Source-of-Truth

### 🔋 Auto-battery low-percentage switch

When the battery drops below `auto_battery_low_pct` (default 20%) on any non-battery profile, the governor automatically switches to PROFILE_BATTERY and remembers the previous profile. When charging brings the level back to `auto_battery_high_pct` (default 30%), the original profile is restored.

The implementation lives entirely inside the existing FSM tick loop. No new polling, no new threads, no new wakeups — the trigger is a single integer comparison against `m->bat.capacity_pct` (already collected by `metrics_read_all`). A `fork()` is invoked only on the exact threshold-crossing event. **Battery-cost-neutral by construction.**

Hysteresis of 10 points (20→30%) prevents flapping near the threshold. A `min_gap_s=300` rate-limit prevents repeated switches on noisy capacity readings. State persists across same-boot governor restarts via `/dev/.asb/auto_battery_state` (tmpfs file with `active` and `restore_idx` integers, validated on read).

User-manual profile switches clear the auto state so the module doesn't fight the user on next recharge. The IPC handler distinguishes module-internal switches from user-manual ones via an explicit `:auto` suffix in the `profile:NAME[:auto]` protocol carried by `apply_profile.sh` — no timing heuristics, no race conditions.

Configuration knobs in `governor.conf`:

```ini
auto_battery_enable=1        # 0 to disable feature entirely
auto_battery_low_pct=20      # trigger threshold (%)
auto_battery_high_pct=30     # restore threshold (must be > low_pct)
auto_battery_min_gap_s=300   # min seconds between auto-switches
```

Status JSON exposes `auto_bat` (0/1), `auto_bat_restore` (-1/0/1/2 profile index), and `qn_active` (0/1) for diagnostics.

### 🌙 Night-window quiet_night acceleration

Between local hours `night_quiet_hour_start` (default 23) and `night_quiet_hour_end` (default 6), `quiet_night` mode enters fast threshold (5 minutes) regardless of clean-night reward state. Outside the window, normal 10-minute threshold applies.

Cost: one `time()` + one `localtime_r()` call per tick when already inside the quiet_night entry branch, which itself only runs on battery profile with screen off. Total added overhead per tick: negligible.

Real-device verification — 9-hour overnight deploy:

| Metric | Value |
|---|---|
| Duration | 8.99 h (overnight) |
| Drain | 45% → 42% = **0.334 %/h** |
| DEEP_IDLE coverage | 29 of 30 samples (96.7%) |
| `bat_wake` | 0 |
| `idle_q` | 100 (perfect) |
| Skin temp | constant 32°C |
| Board temp | 33-34°C |

Drain rate progression: V39 1.07 %/h → V40 0.64 %/h → **V42 0.334 %/h**. Each step closes about half the remaining gap to the theoretical floor (~0.25 %/h for SM8850 in modem-suspend deep-sleep).

### 🎵 ASB:AUDIO installer category (14th)

Audio quality tuning integrated as a proper ASB category, gated by the existing `features.conf` toggle infrastructure (clean implementation, no third-party attribution carried). Adds ~40 declarative properties to `system.prop` under `# ASB:AUDIO:BEGIN/END`, plus 11 runtime setprops in `service.sh`'s `apply_audio_runtime()` for properties that vendor processes re-read after boot:

- A2DP codec preferences and offload capabilities
- BT audio HAL configuration (LHDC, LDAC, aptX-HD selection)
- HAL routing hints for vendor audio parser/buffer
- Spatial-audio gating (`ro.audio.spatializer_enabled`)
- `ro.audio.bt.connect.disable.mute=true` — fixes the mute glitch on Bluetooth reconnect
- Pulse-shaping for music apps (`af.fast_track_multiplier`, `af.dynamic.high_latency`)

All ~40 props remain coupled by the single `features.conf:AUDIO=0/1` toggle — users who skip AUDIO at install time get the vendor-stock audio stack with zero runtime override. The `system.prop` block is `sedi`-stripped at install when toggle is 0, and `apply_audio_runtime()` is gated by `asb_feature_enabled AUDIO`.

Verified compatible with VoLTE calls, Bluetooth headset audio (OnePlus Buds Pro 3 LHDC codec), and stock camera 4K60 recording — no regression with AUDIO=1.

### 🏗 Single source of truth for FSM profile bounds

`config/profile_bounds.conf` (kept in repo, dev-only — not shipped in release zip) is now the only file where numeric values for `CPU_MIN/CPU_CAP/CPU_MAX/GPU_MAX_PCT` (per profile, per cluster) and FSM-shape parameters (uclamp ranges, ravg ticks, idle-enough thresholds) are hand-edited. Two derived artefacts get regenerated by `tools/gen_bounds.sh`:

```
config/profile_bounds.conf  (dev tree only)
            │
            ▼  tools/gen_bounds.sh
            │
            ├─→  config/profile_bounds.generated.sh   (shipped — sourced by profiles/*.sh)
            │
            └─→  src/asb_fsm_bounds.generated.h       (compiled into bin/asb)
```

`gen_bounds.sh` validates invariants (`CPU_MIN ≤ CPU_CAP ≤ CPU_MAX` per cluster, `GPU_MAX_PCT ∈ [1, 100]`, `FLOOR_UCLAMP_TOP ≤ CEIL_UCLAMP_TOP`, cross-profile hierarchy `BATTERY ≤ BALANCED ≤ PERFORMANCE` for `CPU_CAP`) and writes atomically (temp + `mv`, with `cmp -s` skip for idempotency).

`src/asb_fsm.h`'s `g_profile_bounds[3]` initializer now references macros (`ASB_BATTERY_FLOOR_CPU_MAX_LITTLE` etc.) instead of numeric literals. Preprocessor expansion produces a bit-exact binary; runtime behavior is identical to having hand-edited literals — but kills the class of bugs where `.sh` profile files and C bounds drift apart (V39 r3, V40, V41 each had one such divergence caught after deployment).

Profiles' shell side: `profiles/{battery,balanced,performance}.sh` source the generated include via a `MODDIR` lookup chain (`$MODDIR` → `/data/adb/modules/AutoSystemBoost` → `modules_update`), with `${VAR:-fallback}` expansions so the scripts produce sensible defaults if the generated file is somehow absent.

`tools/asb_lint.sh` (user-runnable diagnostic, shipped in zip) enforces the property in both contexts: in the dev tree it regenerates and compares md5 to detect stale artefacts; in a deployed module it validates that `profile_bounds.generated.sh` is well-formed.

### 🛠 Operational refinements

- **Additive `governor.conf` migration**: `service.sh:asb_migrate_governor_conf` now preserves user-edited values on schema bumps and only appends missing keys. Logs `kept N user values, added M new keys`. Atomic write via temp file + `mv`; on failure, user's original config is preserved untouched.
- **IPC `:auto` flag passthrough**: `apply_profile.sh` carries the auto-switch intent explicitly through the `profile:NAME:auto` IPC suffix. C-side handler parses the suffix and uses an explicit `_is_auto=1` flag instead of timing heuristics on `auto_battery_last_action`. Removes a 5-second race window that existed in earlier auto-battery code.
- **Buffer growth**: `g_thermal_cpu_reason` 160→256 bytes for safety margin on long thermal-source-resolution reason strings (multi-tier fallback with full zone names).
- **Schema corrections**: `common/install.sh build_manifest.json schema_version` 10→14 to match `service.sh _expected_schema`. Linter now enforces this via the Version Sync section.
- **Linter coverage**: `tools/asb_lint.sh` knows all 15 features (14 categories + VENDOR_OVERLAY); enforces 6-point version sync on every run (module.prop ↔ update.json ↔ CHANGELOG ↔ WebUI verBadge ↔ action.sh banner ↔ schema_version).

### 🛡️ Carried forward unchanged from V41

- **Vendor overlay via Magisk magic-mount**: `qapegameconfig.txt MaxTemp 48→44°C` for all 26 games, `perfconfigstore.xml qape.boost_duration 6→3 / qape.max_boost_count 2→1`
- **WiFi bonding unified** across 4 WCNSS variants (kiwi_v2, wcn7750, peach_v2, ODM): `gChannelBondingMode24GHz=1`, `gChannelBondingMode5GHz=1`, `gForce1x1Exception=0`, `sae_enabled=1`
- **Bootloop protection** via `/data/adb/asb_vendor_boot_counter` (3 fails → overlay auto-disabled)
- **`resetprop -n` fallback** for `ro.vendor.perf.qape.*` properties (force-applied if perf-hal read the XML before Magisk overlay activated)
- **Diagnostic tools** preserved at install: 7 user-facing scripts (`asb_state_sampler.sh`, `asb_drain_analyzer.sh`, `asb_doctor.sh`, `asb_lint.sh`, `asb_session_report.py`, `asb_compare_sessions.py`, `asb_analyze.py`) plus `logkit/`

### 🚫 What V42 explicitly does NOT change

- **No FSM scheduling logic changes vs V41.** All profile, drift, clamp, and session-classification code identical.
- **No vendor overlay changes vs V41.** QAPE 44°C trigger and WiFi bonding configs are bit-exact carry-overs.
- **No new polling loops.** The two new automation features run inside the existing FSM tick — single integer comparison for auto-battery, single `time()` call for night-window. Both gated by the existing main loop, no separate threads.
- **No vendor binary patching.** AVB rejects substituted `thermal-service.qti` (tested in V41 development). The patch artifact is preserved in dev history for a possible future "ASB Vendor Pack" (unlocked-bootloader-only flashable).
- **No QAPE Class 0 frequency table changes.** Tested in V41 development, produced no measurable effect (vendor's secondary clamp overrides Class 0 regardless). Reverted to vendor stock for minimum overlay divergence.

### 📊 Deploy results vs V40 / V41

| Metric | V40 release | V41 release | V42 release | Delta vs V40 |
|---|---|---|---|---|
| COD Mobile peak temp (30 min performance) | 82°C | 77°C | **58°C** | **-24°C** |
| HEAVY average temperature | 50°C | 41-49°C | 41-49°C | -5°C |
| Sustained transitions per gaming hour | 11 | 2 | **0-2** | -80 to -100% |
| Overnight battery drain (sleep profile) | 0.64 %/h | ~0.55 %/h | **0.334 %/h** | **-48%** |
| `idle_q` (sleep quality score, 0-100) | ~70 | ~85 | **100** | perfect |
| `bat_wake` overnight | 5-10 | 2-4 | **0** | clean |
| Boot success rate | baseline | baseline | baseline | unchanged |
| Functional (VoLTE/BT/Camera/GPS) | working | working | working | unchanged |

### 📦 Upgrade from V41

1. Flash V42 zip over V41 (no uninstall required)
2. Reboot
3. Validation:

```bash
# New automation features visible in state (auto-battery defaults active)
su -c 'cat /dev/.asb/state | tr "," "\n" | grep -E "auto_bat|qn_active"'
# Expect: auto_bat":0  auto_bat_restore":-1  qn_active":0

# AUDIO category active (no mute on Bluetooth reconnect)
su -c 'getprop ro.audio.bt.connect.disable.mute'
# Expect: true

# Schema migration successful (additive — preserves user edits)
su -c 'cat /data/adb/modules/AutoSystemBoost/config/.schema_version'
# Expect: 14

# All seven new V42 config keys present
su -c 'grep -cE "auto_battery|night_quiet" /data/adb/modules/AutoSystemBoost/config/governor.conf'
# Expect: 7

# Single-source-of-truth bounds active
su -c 'ls /data/adb/modules/AutoSystemBoost/config/profile_bounds*'
# Expect: profile_bounds.generated.sh

# Optional: lint from device
su -c 'MODDIR=/data/adb/modules/AutoSystemBoost sh /data/adb/modules/AutoSystemBoost/tools/asb_lint.sh' | tail -10
# Expect: 0 errors, 1 informational warning (auto_degrade_time_gate — pre-existing)

# Gaming envelope test (performance profile, 30+ min COD Mobile)
su -c 'sh /data/adb/modules/AutoSystemBoost/apply_profile.sh performance'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_state_sampler.sh 1800 &'
# Play game, then:
su -c 'grep ses_max_temp /dev/.asb/state'
# V41 baseline:  77°C    V42 target: <70°C    V42 best observed: 58°C
```

### 📂 Files changed vs V41

- `module.prop` — V41→V42, versionCode 410→420
- `update.json` — version and versionCode bumped, zipUrl updated
- `action.sh` — installer banner V41→V42
- `webroot/index.html` — verBadge V41→V42
- `src/asb_config.h` — +7 config keys (`auto_battery_*`, `night_quiet_*`), defaults, parser entries
- `src/asb_fsm.h` — +3 FSM state fields (auto-battery), init in `fsm_init()`, **macro-based `g_profile_bounds[]` initializer** (numeric literals replaced by `ASB_<PROFILE>_<FIELD>` macros), `#include "asb_fsm_bounds.generated.h"`
- `src/asb_governor.c` — +50 lines auto-battery main-loop check, +15 lines night-window quiet_night branch, +3 fields in status JSON, IPC `:auto` parsing in profile handler, `fsm_auto_battery_persist()` calls at 3 sites
- `src/asb_metrics.h` — `g_thermal_cpu_reason` buffer 160→256 bytes
- `service.sh` — `asb_migrate_governor_conf` rewritten as additive merge; schema 13→14; AUDIO runtime block
- `apply_profile.sh` — `PROFILE_FLAG="auto"` carried as `profile:NAME:auto` IPC suffix; cleaner if/else for argument parsing
- `profiles/{battery,balanced,performance}.sh` — source `config/profile_bounds.generated.sh` via MODDIR lookup
- `config/profile_bounds.generated.sh` — **NEW** (generated at build, sourced by profiles at runtime)
- `config/governor.conf` + `.shipped` — +7 new keys with defaults
- `common/install.sh` — AUDIO 14th category (`ASB_AUDIO=true` default, choose_cat call, features.conf entry, prune loop), `build_manifest.json schema_version` 10→14, tools preservation list (7 user-facing scripts)
- `common/englishtext.sh` + `russiantext.sh` — 14 category strings (added AUDIO)
- `system.prop` — `# ASB:AUDIO:BEGIN/END` block with ~40 audio props
- `features.conf` — `AUDIO=1` (default on)
- `tools/asb_lint.sh` — 15-feature whitelist, Bounds Source-of-Truth section (3 checks: stale/regen/parity), Version Sync section (6 checks)

---

<p align="center">
  <b>⚡ V42 unifies automation (auto-battery + night-quiet), audio quality tuning, and architectural cleanup (single source of truth for bounds) into the most polished release yet. Sleep drain at 0.334 %/h and gaming peak at 58°C are both project-best numbers. All V41 vendor overlay and WiFi bonding functionality preserved unchanged.</b>
</p>

---

## 🛡️ V41 — Vendor Overlay Phase 1 + WiFi Bonding Integration

### 🔬 Qualcomm Performance Engine (QAPE) thermal trigger tune

V40 deploy data showed a consistent pattern: even with ASB declaring conservative CPU caps, vendor PowerHAL clamped the actual `scaling_max_freq` to ~1.0-1.2 GHz once temperature hit ~60°C in COD Mobile sessions. ASB correctly stopped fighting (the `clamp_hold` mechanism kicked in), but the user was left with sub-Class-0 frequencies for most of the gameplay session.

Reverse-engineering of the OnePlus 15 vendor blob revealed:

- `/vendor/etc/thermal-engine.conf` is **empty** — all thermal logic delegated to QAPE in perf-hal
- `/vendor/etc/perf/qapegameconfig.txt` is a plain-text file with format `GameID GameAPK MaxTemperature MaxCurrent AvgCurrent` per row
- Every game including COD Mobile had `MaxTemperature=48000` mC (48°C) as the trigger for QAPE class downgrade
- `/vendor/etc/perf/perfconfigstore.xml` exposes `ro.vendor.perf.qape.boost_duration=6` and `qape.max_boost_count=2` — knobs that control how aggressively QAPE issues short boost cycles

V41 ships a vendor overlay via Magisk magic-mount: all 26 game entries in `qapegameconfig.txt` set to `MaxTemperature=44000 / MaxCurrent=900 / AvgCurrent=800` (down from 48000/1150/1000), and `perfconfigstore.xml` `qape.boost_duration=3 / qape.max_boost_count=1` (halved). QAPE boost cycles last half as long and only one cycle per game session instead of two — removes the heat-accumulation pattern from repeated short power spikes.

The resetprop fallback in `post-fs-data.sh` covers the case where perf-hal-service has already read `perfconfigstore.xml` before Magisk's overlay is active — these `ro.vendor.perf.qape.*` properties are then forced via `resetprop -n` to match the overlay values.

### 📶 WiFi bonding configuration (unified across all chip variants)

OnePlus 15 ships with three WCNSS variants (kiwi_v2, wcn7750, peach_v2) plus an ODM-specific overlay. Vendor stock had `gChannelBondingMode5GHz=1` set on all four files but the other three relevant settings only on the ODM file, leaving the chip-specific configs incomplete.

V41 unifies all four `WCNSS_qcom_cfg.ini` files with the complete set:

```ini
gChannelBondingMode24GHz=1   # 40 MHz channel on 2.4 GHz (2× theoretical throughput)
gChannelBondingMode5GHz=1    # 40 MHz channel on 5 GHz (preserved)
gForce1x1Exception=0         # disables forced 1T1R fallback for MTK access points
sae_enabled=1                # enables WPA3 SAE authentication
```

### 🩹 Bootloop protection

V41 ships a boot counter mechanism at `/data/adb/asb_vendor_boot_counter`. `post-fs-data.sh` increments the counter before activating overlay; `service.sh` clears the counter to 0 after `sys.boot_completed=1`. If counter reaches 3 (three failed boots), `post-fs-data.sh` deletes the overlay files from the module — Magisk's next mount cycle won't include them, vendor stock files become active on the next boot.

### 🛠 Diagnostic tools preserved at install time

`install.sh` `rm -rf $MODPATH/tools` from V40 replaced with selective preservation of 7 user-facing scripts and the `tools/logkit/` subdirectory.

### 📊 Real-device results

| Metric | V40 release | V41 release | Delta |
|---|---|---|---|
| COD Mobile peak temp | 82°C | 77°C | -5°C |
| Sustained transitions per gaming hour | 11 | 2 | -80% |
| Boot success rate | baseline | baseline | unchanged |

---

## Previous releases

For V40, V39 r5a, V39 r5, V39 r3, V39 r2, V39, V38 and earlier history, see git tags.
