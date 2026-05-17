# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V42-16a34a?style=for-the-badge" alt="V42">
  <img src="https://img.shields.io/badge/Previous-V41-6b7280?style=for-the-badge" alt="V41">
  <img src="https://img.shields.io/badge/versionCode-420-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

> **V42 brings two automation features (auto-battery low-pct switch, night-window quiet_night acceleration), a 14th installer category (ASB:AUDIO) for audio quality tuning, and an architectural cleanup that puts all FSM profile bounds behind a single source of truth. Real-device sleep deploy on V42 showed 0.334 %/h overnight drain — 2× better than V40, near the SM8850 modem-suspend theoretical floor. Gaming deploy showed ses_max_temp=58°C on a 30-minute performance session, the best thermal envelope in the project's history. All V41 vendor overlay (QAPE 44°C trigger, perfconfigstore boost cuts, WiFi bonding across 4 chip variants) and bootloop protection carry forward unchanged.**

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
