# AutoSystemBoost -- Changelog

---

## V37 -- Honest Thermal Telemetry + Release Discipline

> **V36 rebuilt the profiles around sustainable gaming and deeper battery saving.**
> **V37 makes the thermal telemetry honest, isolates broken sensors, and aligns versioning across every file in the module.**

The V37 release is not a profile rebalance. The profiles that landed in V36 (battery, balanced, performance) tested well across multi-hour sessions on real hardware and are kept untouched. V37's job is to make the module's diagnostics trustworthy enough for a public GitHub release.

---

### 🌡 Honest Thermal Telemetry

V37-r7/r8 dev iterations added separate `skin_temp` and `surface_hotspot` channels, but the fallback logic collapsed them back into a single value when the literal shell sensors went silent. V37 fixes that and adds a sanity gate around the SoC die hotspot sensor that was returning garbage on some firmwares.

#### `skin_temp` is now strictly literal shell

| | V36 / V37-r8 dev | V37 release |
|:--|:--|:--|
| `skin_temp_c` source | shell_front/frame/back, falling back to `sys-therm-6` if all zero | shell_front/frame/back **only**, returns 0 if all silent |
| `surface_hotspot_c` source | sys-therm-6 / board_temp | sys-therm-6 / board_temp (unchanged) |
| Result on OP15 (shell sensors silent) | skin and surface both report 40C from sys-therm-6 — taxonomy meaningless | skin reports 0 (with `thermal_skin_zone=-1`), surface reports 40C — clean separation |

The two channels were always meant to answer different questions: "what does the user's hand feel" vs "where's the body-adjacent hot spot". V37 stops conflating them.

#### `socd` sanity gate

The SoC die-hotspot sensor `socd` is the highest-priority CPU thermal source on Snapdragon 8 Elite Gen 5, but on at least one OP15 firmware revision it reports `raw=5` (effectively garbage) while real per-core sensors read 90–100C.

V37 adds an explicit sanity gate at two layers:

1. **Discovery time**: when `thermal_discover()` validates `socd`, it does an immediate live read. If the value is `<=10C`, the zone is rejected and discovery falls through to `cpu-1-1-*` (priority 2) and `cpu-0-5-*` (priority 3). The reason is logged at startup.
2. **Read time**: even if `socd` was selected, every per-tick read re-checks `c <= 10`. If true, the read is treated as invalid (`temp_valid=0`) with `temp_invalid_reason="raw_too_low"` while keeping the cached value. This prevents one broken read from cascading into FSM decisions.

#### `temp_invalid_reason` field

Status JSON and `session_history.jsonl` now carry a `temp_invalid_reason` string with these possible values:

| Value | Meaning |
|:--|:--|
| `ok` | Sensor read succeeded, temperature is fresh |
| `init` | First read hasn't completed yet |
| `read_fail` | sysfs read returned 0 or error |
| `raw_too_low` | Sensor returned an implausibly low value (likely broken socd) |
| `no_zone` | No thermal CPU zone bound at all |

This replaces the old "is `temp_valid` 0 because the sensor is dead, or because it just hasn't refreshed yet?" guessing game.

#### Session-level sensor health

`session_history.jsonl` schema bumped from `v:8` to `v:9`. New per-session fields:

```json
"temp_invalid_n": 12,
"temp_last_reason": "raw_too_low"
```

These let `tools/asb_session_report.py` and any future analysis tooling see at a glance which sessions ran with degraded thermal telemetry vs which had a healthy sensor stack.

#### `thermal_summary:` startup log line

The startup `tz_dump:` block prints all 96+ thermal zones for postmortem use, but reading 96 lines to learn which sensor was actually selected is annoying. V37 adds a single summary line right after `tz_dump:`:

```
thermal_summary: cpu=socd(z67,val=5,valid=0) skin=none(z-1,val=0) surface=sys-therm-6(z74,val=40)
```

One line tells you: which CPU sensor won, which skin sensor won, which surface sensor won, current readings, validity. Everything else is just for context.

---

### 🩺 Type-Resolved Thermal Diagnostics in `asb_doctor`

`tools/asb_doctor.sh` previously didn't dump thermal state at all — users had to chase sensors manually with `cat /sys/class/thermal/thermal_zone*/type`. V37 adds a `🌡 Thermal Sensors (type-resolved)` section that:

1. Walks every `/sys/class/thermal/thermal_zone*` directory
2. Reads each zone's `type` attribute
3. Looks for a fixed set of recognised types (`socd`, `cpu-1-1-0`, `shell_front`, `sys-therm-6`, `board_temp`, etc.)
4. Resolves each one to its current zone ID dynamically and prints `name → zone → temperature`

**Critically: zone IDs are never hardcoded.** Zone IDs renumber across kernel boots; any tool that hardcodes `thermal_zone57` is wrong on the very next reboot. Doctor now does the right thing.

---

### 📦 Release Discipline -- Versioning Sync

V37-r8 dev archives ended up shipping with mismatched version metadata across files. For a public GitHub release, that's a no-go. V37 normalises everything to `V37 / 370`:

| File | V36 | V37-r8 dev (broken) | V37 release |
|:--|:--|:--|:--|
| `module.prop` | V36 / 360 | V37 / 370 | **V37 / 370** |
| `update.json` | V36 / 360 | V36 / 360 (stale) | **V37 / 370** |
| `src/asb_governor.c` `ASB_VERSION` | "V36" | "V37-r8" | **"V37"** |
| `session_history.jsonl` `asb` field | "V36" | "V37-r8" | **"V37"** |
| Status JSON output | V36 | V37-r8 | **V37** |

A user installing V37 should never see "V36", "V37-r7", or "V37-r8" anywhere. They only see "V37". This is non-negotiable for a clean GitHub release.

`update.json` `zipUrl` updated to point at the V37 release artifact:

```json
{
  "version": "V37",
  "versionCode": 370,
  "zipUrl": "https://github.com/krilikd/AutoSystemBoost/releases/download/37/ASB-V37.zip",
  "changelog": "https://raw.githubusercontent.com/krilikd/AutoSystemBoost/main/CHANGELOG.md"
}
```

---

### What V37 deliberately does NOT change

- **Profile parameters**: battery / balanced / performance settings from V36 are kept verbatim. V36 was already validated across multi-hour sessions.
- **FSM state machine**: state transitions, anti-clamp ladder, session classifier — all unchanged.
- **Config schema**: `features.conf` and per-profile `*.conf` files are byte-compatible with V36.
- **Install path**: `customize.sh`, `service.sh`, `post-fs-data.sh` unchanged. Same Magisk/KernelSU lifecycle.

If you're upgrading from V36, no settings reset, no profile re-tuning, no behaviour surprises. You get cleaner thermal telemetry and consistent versioning.

---

### Files Changed in V37

| File | Change |
|:--|:--|
| `src/asb_metrics.h` | socd sanity gate (discovery + read time); skin fallback removed; `temp_invalid_reason` field added |
| `src/asb_governor.c` | `ASB_VERSION` "V37-r8" → "V37"; status JSON adds `temp_invalid_reason`; `thermal_summary:` startup log line; session_history schema v:8 → v:9 with new sensor-health fields |
| `src/asb_fsm.h` | new `ses_temp_invalid_count`, `ses_last_temp_reason` fields tracked per tick |
| `tools/asb_doctor.sh` | new "🌡 Thermal Sensors (type-resolved)" diagnostic section |
| `module.prop` | V37 / 370 (was already correct) |
| `update.json` | V36 / 360 → V37 / 370 with V37 zipUrl |
| `CHANGELOG.md` | this entry |

---


## V36 -- Long Gaming + Deeper Battery + Honest Status

> **V35 fixed the thermometer and calmed balanced down.**
> **V36 rebuilds the performance profile around sustainable 1-2 hour gaming sessions, pushes battery into deeper energy savings, exposes honest telemetry in status, and fixes a silent install error that was hiding since V27.**

---

### 🎮 Performance Profile -- Built for Long Gaming

V35 performance was optimized for peak 60-second bursts. Logs showed this caused early vendor ceiling collapse around 30s → low actual sustained performance over a 1-2 hour session.

V36 rebuilds performance around a **sustainable ceiling** philosophy: don't chase peaks, ride a stable plateau at 40-55C shell temperature that the vendor clamp never bites.

| Parameter | V35 | V36 | Why |
|:----------|:---:|:---:|:----|
| `CPU_CAP_BIG` | 3,456,000 | **3,264,000** | Soft cap -200 MHz keeps vendor clamp quiet |
| `CPU_CAP_LITTLE` | 3,072,000 | **2,995,200** | Matched ratio |
| `CPU_MIN_LITTLE` | 1,497,600 | **1,324,800** | Lower floor = heat bleed between frames |
| `WALT_ED_BOOST` | 55 → 40 | **35** | Less thermal spike, frames still hit 144fps |
| `WALT_TOPAPP_WEIGHT` | 190 → 170 | **160** | Calmer boost, game still prioritized |
| `WALT_BUSY_HYST` | 12 ms | **8 ms** | Faster downscale when frame is done |
| `SCHED_RATE` | 800 | **1,000** | Fewer unnecessary boost events mid-frame |
| `SCHED_UP_RATE` | 300 | **400** | Slightly slower up-scaling |
| `SCHED_HISPEED_LOAD` | 55 | **60** | Higher bar for hispeed entry |
| `GPU_IDLE_TIMER` | 48 | **64** | Less aggressive GPU nap transitions |
| `GPU_MAX_PCT` | 100 | **92** | Reserve 8% GPU headroom |
| `GPU_THERMAL_PWRLEVEL` | 1 | **2** | One step back from absolute max |
| `VM_DIRTY_EXPIRE` | 1000 | **1500** | Less kswapd pressure mid-session |
| `UCL_FG_MAX` | 100 | **95** | Foreground gets 95%, top-app 100% |

**Philosophy:** Don't cut sustained after the fire — don't start the fire. Lower opening punch → vendor clamp stays asleep → higher actual sustained frequencies over 1-2 hours of COD Mobile at 144fps.

Expected result: shell temperature 40-55C instead of 60-70C spikes, fewer SUSTAINED entries, stable frame pacing over 60+ minute sessions.

---

### 🔋 Battery Profile -- Deeper Energy Saving

V35 battery was already good for sleep (clean 8h nights). V36 goes further on screen-off and mixed-day energy drain.

| Parameter | V35 | V36 | Why |
|:----------|:---:|:---:|:----|
| `CPU_MIN_LITTLE` | 384,000 | **307,200** | Absolute minimum idle floor |
| `CPU_MIN_BIG` | 768,000 | **614,400** | Lower big-cluster floor |
| `CPU_MAX_BIG` | 1,132,800 | **998,400** | Cap big-cluster ceiling even harder |
| `CPU_CAP_LITTLE` | 729,600 | **614,400** | Soft cap matches min floor |
| `CPU_CAP_BIG` | 1,075,200 | **921,600** | No unnecessary big-cluster activity |
| `WALT_TOPAPP_WEIGHT` | 60 | **40** | Even foreground gets less priority |
| `WALT_BOOST_MIN_UTIL` | 150 | **200** | Harder to justify frequency boost |
| `SCHED_RATE` | 12,000 | **16,000** | Slower scheduler = fewer wake events |
| `UCL_FG_MAX` | 10 | **8** | Foreground apps capped at 8% utilization |
| `UCL_TOP_MAX` | 15 | **12** | Top-app capped at 12% |
| `GPU_IDLE_TIMER` | 16 | **12** | Faster GPU sleep |
| `GPU_MAX_PCT` | 18 | **15** | Minimal GPU ceiling |
| `GPU_THERMAL_PWRLEVEL` | 6 | **7** | One step lower than before |
| `VM_SWAPPINESS` | 180 | **200** | Maximum swap preference |
| `VM_DIRTY_EXPIRE` | 180,000 | **240,000** | Even lazier writeback |
| `NET_TCP_RMEM/WMEM` | 4M | **2M** | Smaller network buffers |
| `WIFI_TXQLEN` | 64 | **32** | Smallest viable TX queue |
| `NET_TCP_KEEPIDLE` | 14,400 | **18,000** | Longer keepalive = fewer radio wakes |
| `NET_TCP_FIN` | 45 | **30** | Faster connection cleanup |

**Expected result:** lower idle drain during mixed day use, unchanged clean sleep behavior (V35 was already near-optimal there).

---

### 🌡️ Balanced Thermal Ceiling (New)

V35 logs showed a real issue: under a 9-hour heavy workload, balanced hit **max_temp=81C** with 251s in SUSTAINED. Balanced was still using the global `sustained_temp_enter=65C`, which is too hot for a "daily use" profile.

V36 adds per-profile sustained thermal thresholds for balanced:

| Profile | sustained_temp_enter | sustained_temp_exit |
|:--------|:--------------------:|:-------------------:|
| Battery | 65C (global) | 52C (global) |
| **Balanced** | **58C** | **50C** |
| Performance | 62C | 54C |

**Expected:** balanced enters SUSTAINED earlier under prolonged heavy load, keeping surface temperatures more comfortable during long sessions.

---

### 🔧 Install Fix

`asb_install_prebuilt_governor` was called on line 12 of `common/install.sh` — **before the function was defined** (line 109). Shell executes sequentially → `not found` error on every install.

**Fix:** Removed premature call. Added proper call after all function definitions, right before `asb_big_banner`.

---

### 🏚️ Removed Legacy Headroom<50 Shortcut

V35 introduced the unified sustained entry path:

```
throttle_signal -> throttle_confirmed -> warmup_grace -> debounce -> SUSTAINED
```

But a legacy block from V29 remained in `asb_fsm.h`:

```c
if (headroom_pct > 0 && headroom_pct < 50) {
    desired = SUSTAINED;  // bypasses V35 logic entirely
}
```

This was a **second secret entrance** to SUSTAINED that skipped:
- soft_clamp / hard_clamp classification
- debounce (2-tick confirmation)
- warmup grace (45s protection)
- balanced thermal floor (48C)

**Fix:** Block removed. All SUSTAINED entries now go through the single V35 path.

---

### ⚙️ Fixed Global Load Thresholds

V35 had `heavy_load_enter=2.0` and `moderate_load_enter=10.0` — **inverted**. The safety guard silently clamped at runtime, but the config was logically wrong.

| Threshold | V35 (config) | V35 (runtime) | V36 |
|:----------|:------------:|:-------------:|:---:|
| `moderate_load_enter` | 10.0 | 10.0 | **3.0** |
| `heavy_load_enter` | 2.0 | 10.5 (clamped) | **5.0** |

Now performance has a proper ladder: MODERATE from load 3.0, HEAVY from load 5.0.

---

### 🔍 Honest Status JSON

In V35 heartbeat showed `temp=45(stale)` and `sc=1 hc=0`, but these fields were **only in heartbeat** (printed once every 15 minutes). A short diagnostic window never saw them.

V36 exposes the full thermal signal split in the status socket JSON:

```json
{
  "state": "HEAVY", "profile": "performance",
  "temp": 45, "temp_valid": 0, "temp_age_s": 912,
  "soft_clamp": 1, "hard_clamp": 0,
  "thermal": 0, "headroom_pct": 67,
  ...
}
```

Four new fields: `temp_valid`, `temp_age_s`, `soft_clamp`, `hard_clamp`. Now every `status` query sees the complete picture.

---

### 🛠️ Reload Path History Bug

The socket `reload` command silently discarded running sessions when a profile change was detected — `fsm_session_reset()` was called without first writing history. Sessions that crossed a reload boundary were lost.

**V36 fix:** If a profile change is detected on reload, `session_history_append_ex()` is called **before** the reset, preserving the outgoing session with correct profile attribution.

---

### 📈 By The Numbers

| Metric | V35 | V36 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 3,243 | 3,261 | +18 |
| FSM header | 725 | 752 | +27 |
| Metrics header | 456 | 472 | +16 |
| Config header | 288 | 342 | +54 |
| Total C code | 4,712 | 4,827 | +115 |
| Config parameters | 50 | **57** | +7 |
| Status JSON fields | 31 | **35** | +4 |
| Per-profile thermal tiers | 2 | **3** | +balanced |
| Performance CPU_CAP_BIG | 3,456 MHz | **3,264 MHz** | -200 MHz soft cap |
| Battery CPU_MAX_BIG | 1,132 MHz | **998 MHz** | -134 MHz hard cap |
| install.sh | broken | **fixed** | Error gone |

---

### 🏛️ Changed Files (from V35)

| File | What |
|:-----|:-----|
| `common/install.sh` | Moved `asb_install_prebuilt_governor` call after definitions |
| `profiles/performance.sh` | Rebuilt for sustainable 1-2h gaming (14 tuning changes) |
| `profiles/battery.sh` | Deeper energy saving (16 tuning changes) |
| `src/asb_fsm.h` | Removed legacy headroom<50 shortcut |
| `src/asb_config.h` | Added balanced_sustained_temp_enter/exit |
| `src/asb_governor.c` | Status JSON fields, reload history fix |
| `src/asb_metrics.h` | Thermal signal split (V35 carried forward) |
| `config/governor.conf` | moderate=3.0, heavy=5.0, balanced ceiling 58/50 |

### Unchanged

system.prop, audio/camera/GPS overlays, balanced profile shell (already optimal per V35 logs), install scripts structure.

---

> **V35 fixed the thermometer and stopped balanced from treating every headroom dip as a five-alarm fire.**
> **V36 rebuilt the gaming profile around 1-2h sustainable plateaus, pushed battery deeper into energy saving, gave balanced its own thermal ceiling, exposed honest telemetry everywhere, and fixed an install error that was hiding in plain sight since V27.**
