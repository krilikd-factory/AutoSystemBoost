# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V44-16a34a?style=for-the-badge" alt="V44">
  <img src="https://img.shields.io/badge/Previous-V43-6b7280?style=for-the-badge" alt="V43">
  <img src="https://img.shields.io/badge/versionCode-440-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

## ⚡ V44 — Operational Maturity Release

This is the longest-running development cycle of the project — twenty-four prereleases, three external code reviews (ChatGPT, secondary AI agent, internal audit), two bootloop debugging cycles, and one Chinese-language bug report that took two iterations to fully diagnose. V44 doesn't ship a new governor — it ships everything around the governor finally being release-quality.

### 🐛 Critical bugs fixed

**KERNEL → audio glitches on Chinese OnePlus 15.** A user reported via 4PDA (machine-translated from Chinese): enabling KERNEL category caused intermittent audio in both speaker and Bluetooth. Root cause: the `# ASB:KERNEL:BEGIN/END` block in `system.prop` had accumulated **492 audio-related properties** over previous releases (DTS Eagle, Dolby DS2, spatializer, mbdrc, fluence, ULL paths). On Chinese OnePlus 15 ColorOS regional builds, the vendor audio HAL doesn't ship these code paths — the props referenced non-existent codec entries, triggering NULL dereferences in `audiohalservice.qti`. Fix: stripped all 492 props from KERNEL block. The block now contains only true kernel/perf/log tweaks (357 props). Removed props archived at `docs/removed_audio_props_v44.txt` for reference. Lint check `system.prop KERNEL block free of audio overrides` permanently enforces this boundary.

**Animation speed locked across profile switches.** Reported by primary user: switching performance → battery wrote new `animator_duration_scale` / `transition_animation_scale` / `window_animation_scale` to `settings global` but UI animations stayed at the performance-profile speed until reboot. Root cause is an Android framework limitation — `ValueAnimator.sDurationScale` is cached per-process at class init and never re-read from running activities. Three earlier fix attempts (PR, prerelease21, prerelease23) used WM service calls and CONFIGURATION_CHANGED broadcasts that *appeared* helpful but didn't actually flush the cache. V44 final ships the honest implementation: settings always written (new apps pick up new scale), plus opt-in `UX_ANIM_FORCE_RESTART=1` in `governor.conf` to `pkill com.android.systemui` on switch (instant effect but one screen flash). Default is passive (`=0`). Code now documents the limitation honestly rather than pretending it's fixed.

**TWS earbuds + VoIP call routing broken (Pixel Buds Pro 2 + Telegram).** Reported by OnePlus 13R user on SukiSU Ultra. With AUDIO category enabled, Telegram calls did not see the connected TWS earbuds — required mid-call reconnect. Removing the module fixed it. Disabling AUDIO at install fixed it. Root cause: aggressive props like `persist.audio.uhqa=1`, `persist.vendor.audio.power.save.setting=1`, `audio.offload.min.duration.secs=20`, large offload buffers — these conflict with TWS+VoIP call routing on some devices. Fix: split `apply_audio_runtime()` into VoIP-safe core (always applied when AUDIO=1) and aggressive enhancements (gated by `AUDIO_AGGRESSIVE=0` default in `governor.conf`). VoIP-safe core keeps only the seven essential props: int_codec hifi, BT connect mute fix, AEC reference disable, matrix limiter disable. Aggressive layer keeps UHQA, hifi flags, offload tuning, resampler quality — opt-in for users who don't use TWS for calls.

### 🩹 Operational hardening (this is the bulk of V44)

**Baseline tracking — every persistent change is now reversible.** This was the biggest gap in V43: 30+ persistent `settings put global`, `setprop persist.*`, and `pm disable-user` calls scattered across `service.sh`, with `uninstall.sh` restoring only camera HAL props. After uninstall, user's WiFi country code, NTP servers, Bluetooth codec priorities, GPS XTRA servers, device idle constants, activity logging settings — all stayed at ASB's values forever.

V44 introduces `runtime/asb_baseline.sh` — a 94-line helper exposing:
- `asb_settings_put <namespace> <key> <new_value>` — captures original on first write, then puts the new value
- `asb_persist_safe <prop> <new_value>` — same for `persist.*` props via getprop/setprop
- `asb_pm_disable <package>` — same for package enabled/disabled state
- `asb_baseline_replay` — used by uninstall.sh

The capture is **strictly idempotent**: each key gets snapshotted exactly once, on first modification, into `/data/adb/asb_baseline.txt`. Subsequent writes never overwrite the captured baseline. `uninstall.sh` reads this file in reverse and replays every entry, restoring the system to its pre-ASB state.

By release: **42 `asb_settings_put` calls, 2 raw `settings put`** (intentional fallback for early init before helper sourced). All 27 V43-era persistent writes converted: WIFI hygiene (4), WIFI country (2), GPS/NTP (8), BT settings (3), BT codec policy (7), BT volume (2), Doze constants (1), miscellaneous (9). BG_TRIM persistent writes (`wifi_scan_always_enabled`, `wifi_wakeup_enabled`) were the proof-of-concept and migrated first.

**`profile_core.sh` deduplication.** V43 shipped TWO copies — `common/profile_core.sh` and `runtime/profile_core.sh` — with the description-text section already diverging. This is exactly the V27-class bug that historically caused all profiles to display as "balanced" because installer overwrote the runtime copy. Deleted `common/profile_core.sh` entirely. `service.sh` sources only `runtime/`. Installer no longer copies. Lint errors immediately if `common/profile_core.sh` reappears in any future build.

**Soter repair loop: opt-in + non-destructive.** V43 ran a hardcoded 5-minute loop after every boot with `pm clear com.tencent.soter.soterserver` on every iteration. This wiped Soter's app data on every boot — destructive even when not needed. V44: gated behind `features.conf:SOTER_REPAIR=0` (off by default), retry logic is 3 attempts with exponential back-off (1s → 5s → 30s), exits early when `getprop init.svc.vendor.soter == running`. `pm clear` removed entirely. Lint errors if `pm clear com.tencent.soter` reappears in non-comment code.

**Debug-aware exec redirect.** V43's `service.sh` started with hardcoded `exec >/dev/null 2>&1` — silenced every `setprop`, `settings put`, AVC denial during early boot. Made the two V44 bootloop debugging cycles (test-2 → test-3 → test-4) far harder than necessary. V44: redirect only happens if neither `/data/adb/asb_debug` nor `persist.asb.debug=1` is set. Touch the file or set the prop to see early-boot output in KSU/Magisk logs.

**Real process discovery for BG_TRIM.** V43 used `pidof "$pkg"` which only matches exact package name. Apps with `:remote`, `:push`, webview subprocesses, or custom multiprocess names were silently skipped — exactly the apps with the most background memory (WhatsApp:push, Telegram:remote, etc.). V44 combines `pidof` exact match with `ps -A -o PID,NAME | awk '$2==pkg || index($2,pkg":")==1'`, deduplicates, and trims all. Net effect: BG_TRIM now actually reaches the subprocesses it was designed to trim.

**`BG_TRIM_LEVEL` two-tier configuration.** New `governor.conf` key with `safe` (default) or `aggressive`. Safe runs only buckets + memcg + WiFi sleep — minimal blast radius. Aggressive adds initial reclaim and 6-hour periodic reclaim cycles on screen-off. Lint validates the value.

**GMS wakeup throttle.** Field telemetry showed three GMS services generating 26–33 wakeups per battery session: `GlanceEventsReportService`, `NetworkLocationScanner`, `com.google.android.location.ALARM_WAKEUP`. V44 adds `asb_bg_trim_gms_wakelock_throttle()` (active when BG_TRIM=1): puts `com.google.android.gms` in `working_set` standby bucket, `googlequicksearchbox` in `rare`, reduces `location_background_throttle_interval_ms` to 30 minutes via `asb_settings_put` (so it's restored on uninstall). Critically: does **not** disable GMS itself — push notifications and Doze stay functional.

**`RESERVED` feature toggles.** V43 had `RADIO_IMS=1`, `DISPLAY=1`, `FPS=1`, `SECURITY=1` in `features.conf` but no runtime code paths for any of them. Deleting them would have forced users to re-select all categories on upgrade (the very thing V43 fixed with config persistence). V44 marks them inline with `# RESERVED — planned for V45+` comments and adds lint warning (`feature X is RESERVED — declared but no runtime code yet`) — not an error, because the declaration is intentional. Installer continues to honour previous user choices across upgrades.

**Audio enhancement safe-by-default.** Beyond the TWS+VoIP bug fix, the AUDIO category itself is now structured as two layers. Safe core (7 props) — int_codec hifi, BT mute fix, AEC reference, matrix limiter — applied whenever AUDIO=1. Aggressive layer (12 props) — UHQA, full hifi enablement, large offload buffers, resampler quality — gated by `AUDIO_AGGRESSIVE=0` (opt-in). New users get a safer default; power users who want maximum quality and don't use TWS for calls flip one variable.

### 📡 Live observability — three new JSON endpoints

**`/dev/.asb/state` — extended with auto-battery context.** Status JSON now includes `auto_bat_reason` (one of `"none"`, `"low_pct"`, `"high_pct_restore"`, `"manual_clear"`) and `auto_bat_since` (Unix timestamp of last transition). Diagnoses *why* the auto-battery switch fired and *when*, replacing V43's binary `auto_bat=0/1` field that left users guessing.

**`/dev/.asb/conflicts.json` — new per-tick atomic-write file.** Exposes cap-source telemetry that previously required parsing 30+ minutes of `governor.log`:

```json
{
  "last_cap_source": "vendor_clamp",
  "last_cap_source_ts": 1779470404,
  "vendor_clamp_total": 12,
  "vendor_raised_total": 3,
  "vendor_clamp_1h": 4
}
```

Counter rolls every hour. Reveals when vendor PowerHAL is overriding ASB caps and how often. Particularly useful on OnePlus 15 where `vendor_clamp` is the physics-driven thermal limit and ASB can't override it.

**`/dev/.asb/learner_state.json` — battery learner exposed.** Previously a black box. Now:

```json
{
  "trust_tier": "clean",
  "trust_tier_num": 2,
  "last_outcome": "clean",
  "sessions": { "battery": 14, "balanced": 7, "performance": 3, "night": 9, "day": 5 },
  "self_tuned": {
    "bat_fast_idle_s": 420,
    "bat_heavy_load_enter": 4500,
    "bat_moderate_load_enter": 1500,
    "bat_light_idle_gpu": 380
  },
  "battery_aggregates": {
    "avg_idle_q": 87.3,
    "avg_wph": 1.4,
    "night_avg_iq": 91.0,
    "day_avg_iq": 78.5,
    "clean_night_count": 5
  }
}
```

Diagnoses learner state without needing to read raw `pstats_battery.json` and infer trust tiers from counters.

### 🌐 WebUI — Live Status overlay page

V44 introduces a slide-in overlay page accessible from a small `📊 Live` chip button in the main page's status row (next to `Profile: balanced`). Tapping the chip slides the Live page in from the right; the Live page has the same header structure as main (logo + version badge + status row, with a `← Back` chip in the same position the Live chip occupies on main). Content vertically centered to match the position of the three profile buttons on main, so the transition main ⟷ Live feels symmetric — static elements stay put, only the middle band changes.

The Live page shows:
- Profile + FSM state (top row)
- CPU °C / Skin °C (thermal row)
- Estimated screen-on time and screen-off time at current draw (wide tiles, replacing the redundant battery percentage tile — battery is already in the status bar)
- Cap source (colour-coded: green for `asb`, red for `vendor_clamp`, orange for `vendor_raised`, cyan for `shell_*`)
- Active modes (auto-battery reason + night-quiet) or "No active modes"
- Battery learner summary (trust tier, session count, last outcome)

Polling cadence is smart:
- Live page open → poll `/dev/.asb/state` + `learner_state.json` + `asb status` every **3 seconds**
- Live page closed → poll only the cap-source field every **30 seconds**, used to colour the chip badge (green = normal, orange = vendor raised, red = vendor clamping)
- Governor not running → chip hidden entirely

The main page itself is unchanged — same logo, same three profile buttons, same Telegram link. The Live page is additive.

### 🛠 Diagnostics & audit tooling

**`tools/asb_audit_state.sh` — new dump tool.** Single command that prints: module info, active profile, features.conf, baseline tracker contents (every value ASB has captured for restore), current Android settings for ~30 keys ASB touches, disabled packages, ASB-related persist props, `/dev/.asb` state files, last 10 profile switches, conflict markers. Output is plain text, designed for sharing in bug reports. Run after install for a baseline snapshot; run after uninstall to verify clean removal.

**`/data/adb/asb_profile_switches.log` — append-only audit log.** Each successful profile change writes a TSV line: `<ISO8601>	<old> -> <new>	trigger=<user|auto|...>`. Reveals automatic switches the user might not have noticed (auto-battery firing on low %, restore on charge, night-quiet adjustments). Reading with `tail -f` shows the FSM's decisions live.

**`action.sh` cleanup.** V43 wrote to `module.prop description` on every button press — corrupted the module signature for KSU/Magisk integrity checks. V44 makes the script read-only: reads `/dev/.asb/state` if present to compute real-time ETA from the actual `current_now` mA reading, falls back to per-profile heuristic if state unavailable. Shows `(measured)` or `(heuristic)` label so the user always knows which calculation is being shown.

### 🔒 Defensive coding — V-002 integer overflow check

PR from an automated security scanner (OrbisAI) flagged `realloc(lines, new_cap * sizeof(char *))` at `src/asb_governor.c:478` as CWE-190 (integer overflow). On 32-bit Android, `new_cap * 4` would wrap at `new_cap > 0x3FFFFFFF`. OnePlus 15 is 64-bit so practical risk is near zero — but the fix is five lines of defensive code with no runtime cost, applied as hygiene:

```c
if (new_cap > SIZE_MAX / sizeof(char *)) {
    fclose(rf);
    for (size_t i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}
```

The accompanying pytest file from the PR was **not** applied — it tested abstract Python invariants, not the actual C code, and would have added a Python dependency to the build. Real C unit testing is a V45 candidate if it ever matters.

### 📋 Lint — eight new V44 health checks

`tools/asb_lint.sh` extended with a "🩺 V44 — Operational Health" section:

1. `common/profile_core.sh` must not exist (V27 regression guard)
2. `runtime/asb_baseline.sh` must exist (restore safety net)
3. `BG_TRIM_LEVEL` value validation (`safe` | `aggressive`)
4. KERNEL block audio prop count must be 0 (catches Chinese audio bug regression)
5. SOTER_REPAIR value validation, warns if set to `1` (loop runs on every boot)
6. `pm clear com.tencent.soter` must not appear in non-comment service.sh lines
7. RESERVED feature warning (not error) — declared but unwired
8. features.conf parser tolerates inline `# RESERVED — ...` comments on values

### ⚙️ Configuration — three new keys

```sh
# governor.conf additions
BG_TRIM_LEVEL=safe                # safe | aggressive
UX_ANIM_FORCE_RESTART=0           # 0 = passive, 1 = pkill SystemUI on switch
AUDIO_AGGRESSIVE=0                # 0 = VoIP-safe, 1 = full UHQA + offload
```

And `features.conf` gains `SOTER_REPAIR=0` (opt-in Soter restart loop).

### 🧪 Deploy validation — performance session log

On-device test of V44 final, performance profile, mixed gaming (COD Mobile) and general use:

```
Profile:               performance
Session duration:      ~85 minutes (3 snapshots, 2 sustained entries)
ses_max_temp:          67°C
ses_max_skin_temp:     40°C
ses_max_surface_temp:  49°C
ses_t_sustained:       1216s (20+ min in sustained throttle state)
ses_t_gaming:          137s
ses_t_heavy:           277s
ses_auto_degraded:     1 (auto-degrade fired correctly under load)
hot_fail:              0
cap_source:            shell_overridden_down (ASB controlling — no vendor_clamp)
```

Two sustained entries cleanly entered and exited via time-based escape, FSM transitioned through GAMING → SUSTAINED → LIGHT_IDLE correctly. The auto-degrade event indicates the learner adapted thresholds based on the thermal profile, exactly as designed. No bootloop, no crashes, no log noise. V44 ships with confidence on real-device sustained-load behaviour.

### 📊 Verification

```
Compile (gcc -Wall -Wextra):         0 warnings, 0 errors
Shell syntax (32 files):             32/32 clean
Lint:                                0 errors, 5 warnings (4× RESERVED + 1× informational)
KERNEL block audio props:            0  (was 477 in V43)
common/profile_core.sh:              absent (was diverging from runtime/ in V43)
SOTER_REPAIR default:                0 (opt-in, was hardcoded 5-min loop in V43)
pm clear in code:                    0 (was 1 in V43, destructive)
asb_settings_put calls:              42 (was 0 in V43 — no baseline tracking existed)
service.sh size:                     1709 lines (was 1600 in V43, +109)
asb_governor.c size:                 4069 lines (was 3895 in V43, +174)
WebUI index.html size:               1168 lines (was 793 in V43, +375)
system.prop size:                    905 lines (was 1416 in V43, -511 — KERNEL audio cleanup)
```

### 🚫 What V44 deliberately does NOT change

- **FSM scheduling logic, profile bounds, sysfs caps** — bit-exact identical to V43. Reproducibility of V42 baseline `ses_max_temp=58°C` on equivalent workloads preserved.
- **Italian NTP servers and Italian WIFI_COUNTRY=IT default** — kept by author's explicit choice. All are now baseline-tracked, so uninstall restores user's original values.
- **Per-app auto-profile switching** — deferred to V45+. A polling daemon checking foreground app every 10s would itself burn battery, potentially more than the per-app profile saves.
- **`ASB_REVERSIBLE` global mode and `ASB_DRYRUN`** — deferred. The cleaner architecture is the per-helper `asb_settings_put` family (already shipped in V44), not a top-level binary flag.
