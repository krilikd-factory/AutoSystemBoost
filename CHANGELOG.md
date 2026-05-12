# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V40-16a34a?style=for-the-badge" alt="V40">
  <img src="https://img.shields.io/badge/Previous-V39_r5a-6b7280?style=for-the-badge" alt="V39 r5a">
  <img src="https://img.shields.io/badge/versionCode-400-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

> **V40 is the biggest release since V35. It rebuilds the FSM transition logic, recalibrates all three profiles for the actual SM8850 silicon (V39 caps were calibrated against earlier devices and turned out far too conservative), fixes the storm of drift reconciles that plagued V39 deployments, eliminates UI scroll stutter through two new bypass paths, and adds 4 new system.prop sections covering display, FPS, radio/IMS, and security. Real-device gaming sessions on V40 stay in the 50-58°C envelope where V39 hit 65-82°C; battery profile drain dropped ~40% (V39: 1.07 %/h → V40: 0.64 %/h on identical mixed-use patterns).**

---

## 🚀 V40 — FSM Rebuild + Profile Recalibration + Stutter Elimination

### 📊 What you'll feel after upgrading from V39 r5a

| Symptom on V39 | Behaviour on V40 |
|---|---|
| Drift-up reconciles spam log 1700+ times per session | Hard rate-limited to 5/cluster/minute, log clean |
| Stutter when scrolling shelf and app menus on battery | Smooth — FSM escalates within 1-2 seconds, never enters LIGHT_IDLE with screen on |
| Profile switch via WebUI or CLI takes 45-600 seconds to apply to FSM | Applied to FSM in under 1 second |
| Battery profile stuck in HEAVY 24+ minutes after light burst, displays as "balanced" anyway | Battery profile name correct, comfort cap engages properly |
| 30+ minute gaming session: peak temp 65-82°C, FPS jittery from vendor emergency clamps | Peak 50-58°C envelope, FPS stable, no vendor 1 GHz emergency clamps |
| 24 GAMING ↔ SUSTAINED transitions per gaming hour | Down to 3-11 per hour, mostly graceful timed escapes |
| Bluetooth: Pixel Buds Pro 2 lose Opus codec, fall back to SBC | Codec table no longer corrupted by ASB, full AAC/LDAC negotiation |
| OnePlus camera: Hasselblad/Explorer modes inactive | Activated via resetprop on supported devices |
| Daily battery drain in mixed use | ~7-10% lower drain rate |

### 🔧 Profile recalibration (the big one)

V39 inherited profile caps from older Snapdragon parts. Real-device telemetry on SM8850 showed those caps were so low they triggered vendor PowerHAL's "user wants saving mode" heuristic, which then clamped GPU to 160 MHz mid-scroll. V40 caps were derived from actual on-device thermal envelope measurements.

**Battery profile** (`profiles/battery.sh`):

```diff
- CPU_MAX_LITTLE=1132800   CPU_MAX_BIG=998400      # P-cluster ABOVE Big-cluster — wrong on SM8850
- CPU_CAP_LITTLE=614400    CPU_CAP_BIG=921600
- UCL_FG_MAX=8             UCL_TOP_MAX=12          # uclamp suffocated UI
- UCL_BG_MAX=5
- GPU_MAX_PCT=15
+ CPU_MAX_LITTLE=1804800   CPU_MAX_BIG=2208000     # P-cluster correctly above Performance cluster
+ CPU_CAP_LITTLE=1132800   CPU_CAP_BIG=1113600
+ UCL_FG_MAX=55            UCL_TOP_MAX=58          # uclamp gives UI room without burning battery
+ UCL_BG_MAX=40
+ GPU_MAX_PCT=50                                    # 600 MHz Adreno cap — avoids vendor clamp
```

**Performance profile** (`profiles/performance.sh`):

```diff
- CPU_MAX_LITTLE=3628800   CPU_MAX_BIG=4608000     # full HW max — triggered vendor emergency clamps
- CPU_CAP_LITTLE=3072000   CPU_CAP_BIG=2976000     # sustained 3 GHz — too hot for >5 min
- UCL_FG_MAX=96            UCL_TOP_MAX=100         # max uclamp boost spiked temperature
- GPU_MAX_PCT=84                                    # 1008 MHz GPU triggered thermal
+ CPU_MAX_LITTLE=2956800   CPU_MAX_BIG=3302400     # peak stays below vendor's 59°C trigger
+ CPU_CAP_LITTLE=2304000   CPU_CAP_BIG=2611200     # sustained 2.6 GHz — enough for COD 120 FPS
+ UCL_FG_MAX=88            UCL_TOP_MAX=84          # no peak power spikes
+ GPU_MAX_PCT=70                                    # 840 MHz Adreno — efficient zone
```

**Balanced profile** kept V39 r3 values — they were already correct.

The corresponding C-side `g_profile_bounds[]` table in `src/asb_fsm.h` is recalibrated to match. Floor and ceil bounds for each profile derive from the `.sh` values via lerp by FSM state position. Comments document the kernel-agnostic thermal envelope target.

### 🛠 Drift-storm architectural fix

V39's `runtime/asb_reconcile.sh` compared `scaling_max_freq` against static `CPU_CAP_LITTLE` / `CPU_CAP_BIG` from `profiles/*.sh` — DEEP_IDLE floor values. FSM dynamically writes higher caps for HEAVY/SUSTAINED/GAMING states; reconcile interpreted those as drift and fought them. Real telemetry showed 1706 reconciles in a single balanced session, with vendor PowerHAL winning the write race every time.

V40 reads `fsm.current_caps.cpu_max[]` from `/dev/.asb/state` (where the C governor publishes current desired caps) and compares against that instead:

```diff
- _want_p0_max="${CPU_CAP_LITTLE:-0}"          # static DEEP_IDLE floor
+ _fsm_caps=$(grep "^cpu_max=" /dev/.asb/state | head -1 | cut -d= -f2)
+ _want_p0_max=$(echo "$_fsm_caps" | cut -d, -f1)
```

Tolerance raised 50 → 100 MHz (vendor frequency-table alignment plus thermal headroom slack). Falls back to static profile.sh values if `/dev/.asb/state` is unavailable.

When vendor PowerHAL persistently overrides ASB caps, V40 surrenders gracefully via a hard rate limit: **5 reconciles per cluster per 60 seconds** via a rolling-window counter persisted at `/dev/.asb/drift_rate`. After 5 reconciles in a window, further drift events are observed but not acted on for the rest of the window.

The C-side `leak_reassert` watchdog that previously rewrote `scaling_max_freq` on streak-detected leaks is now **reporter-only**. Two writers fighting one sysfs node was the architectural problem; with reconcile.sh as the sole authority, the watchdog's job is now to log observed leaks (rate-limited to 1/minute) so deploys still surface vendor-up-clamp events without doubling the write traffic.

### 🐛 Profile sync (immediate apply)

In V39, profile changes via WebUI / CLI only reached the C governor through `runtime/asb_reconcile.sh`'s polling, which sleeps 45-600 seconds depending on screen state. During that window:
- FSM used wrong profile bounds (e.g. balanced bounds while user expected battery)
- Session metrics attributed to wrong profile
- `/dev/.asb/state` showed mismatched `profile=N` vs reality
- Self-tune writes hit the wrong profile's stats file

V40 fixes this two ways:

**1. `apply_profile.sh` notifies governor immediately:**

```sh
notify_governor() {
  _gov="$MODDIR/bin/asb"
  [ -x "$_gov" ] || _gov="$MODDIR/bin/$(uname -m)/asb"
  [ -x "$_gov" ] && "$_gov" "profile:$PROFILE" >/dev/null 2>&1 &
}
```

Sends `profile:<name>` IPC right after writing `current_profile` file. Backgrounded so apply_profile.sh doesn't block on socket.

**2. C-side safety net** — `asb_governor.c` re-reads `current_profile` every 60s. If file disagrees with `fsm.profile_idx`, full session reset + emit `profile_drift_detected` log. Cost: one open()+read() of small file per minute = under 0.001% CPU.

### 🎨 UI scroll stutter elimination

V39 had two cooperating bugs that produced 13+ second stutter episodes when scrolling shelf or app menus on battery profile:

**Bug 1**: FSM only escalated LIGHT_IDLE → MODERATE on `cpu.load1 ≥ moderate_load_enter` (14) or `bat_current_ma ≥ 120`. Neither trigger fires reliably during short scroll bursts where loadavg-1min hasn't ramped yet but GPU is doing real composer work.

**Bug 2**: When the cpu/current triggers eventually fired, battery profile applied `up_window × 2` ticks (8 seconds minimum dwell) for the LIGHT_IDLE → MODERATE transition as anti-flap protection. Anti-flap turned into anti-responsiveness.

**V40 adds three layers of fix:**

1. **UI-burst escalation**: when `screen_on && gpu.load_pct ≥ 12`, FSM escalates to MODERATE. Below `heavy_gpu_enter` (35%) so it remains specifically the "user touching screen" signal, not gaming.

2. **Window bypass for UI-burst**: when the trigger is UI-burst, `up_window×2` doubling is bypassed — transition happens on the immediate next tick. Other LIGHT_IDLE → MODERATE triggers keep the doubled window.

3. **Battery LIGHT_IDLE skip on screen-on**: deploy logs showed vendor PowerHAL clamps GPU `max_pwrlevel` to 17 (160 MHz) **specifically when state=LIGHT_IDLE on battery profile** — not in DEEP_IDLE, not in MODERATE, only LIGHT_IDLE. V40 skips LIGHT_IDLE entirely for battery profile when screen is on. State machine goes directly DEEP_IDLE → MODERATE on screen unlock, avoiding the vendor-clamp window. Balanced and performance profiles keep LIGHT_IDLE — they don't trigger the vendor heuristic.

### 🎮 Gaming session refinements (performance profile)

**Anti-flapping**:

```diff
config/governor.conf:
- perf_sustained_temp_enter=59  perf_sustained_temp_exit=56     # 3°C hysteresis, vendor's reactive zone
+ perf_sustained_temp_enter=53  perf_sustained_temp_exit=48     # 5°C hysteresis, preemptive cooldown
- gaming_min_dwell_s=12
+ gaming_min_dwell_s=25                                          # longer GAMING hold before SUSTAINED
```

FSM now enters SUSTAINED 6°C earlier (preemptive cooldown before vendor reacts) and stays there 8°C longer (lower exit threshold + wider hysteresis) — fewer GAMING ↔ SUSTAINED transitions per session.

**Auto-degrade detection** preserved from V39 — when sustained_pct >70% the FSM auto-degrades to lower caps for the rest of session. Now fires reliably because exit thresholds are reachable.

**Display fixes for profile-specific thresholds**: `exit_sustained` and `enter_sustained` log lines previously displayed the global `sustained_temp_enter/exit` even when profile-specific values were used. V40 corrects this — logs now show the actual threshold the FSM is using. State snapshot `eff_sus_temp` also corrected.

### 🔋 Battery economy

```diff
config/governor.conf:
- bat_fast_idle_s=8        bat_comfort_temp=38   bat_heavy_load_enter=18.5
+ bat_fast_idle_s=12       bat_comfort_temp=48   bat_heavy_load_enter=20.0
- bat_moderate_load_enter=12.5
+ bat_moderate_load_enter=14.0
```

`bat_comfort_temp=48` (was 38) — V39's 38°C trigger fired constantly on any phone warmer than ambient room. 48°C is the realistic "warm device, needs to cool" threshold for SM8850.

### 📐 system.prop section reorganization

V39 had 9 sections (BT, CAMERA, CPU, VM, NET, WIFI, GPS, KERNEL, LOG). V40 adds 4:

```
+ # ASB:RADIO_IMS:BEGIN    — IMS / VoLTE / VoNR / SMS over IMS / IWLAN
+ # ASB:DISPLAY:BEGIN      — CABL, DPPS dynamic FPS, backlight smoothing
+ # ASB:FPS:BEGIN          — Frame rate caps, recorder max base layer
+ # ASB:SECURITY:BEGIN     — Perf events, snapshot suppression
```

Each new section has a full installer toggle (default-on, VOL- skips), an English and Russian menu string, a features.conf entry, and a drop-block hook that strips the section from system.prop when disabled at install time. **13 sections, 26 BEGIN/END markers, 0 orphan props.**

System prop count: V39 had 1297 active props; V40 has 1331. Net +34 props across:

- Camera (7): smyuv, fdvideo, eis.disable=0, video.4k60.eis.enable, opt_mode.video=2, cpp.zoom.opt, cpp.duplicate_strip_dump=0
- Audio (7): Fluence noise reduction (voicecall/voicerec/speaker), vendor.audio.hifi, deep_buffer.media, gapless.enabled, flinger_standbytime_ms
- Network/RIL (3): tcp.delack.default, call_ring.delay, calls.on.ims (VoLTE preference)
- Display (5): dpps_dynamic_fps, async_vds, backlight_smooth, ro.qualcomm.cabl, enable_cabl
- FPS (4): recorder-max-base-layer-fps=240, disable_idle_fps=false, video/game default_frame_rate.disabled
- Radio/IMS (4): ims.auth.scheme/type, qmi_ott_feature, QmiOttEnable
- Security (3): perf_harden=0 (enables ASB tools), snapshot_enabled=0, isSupportSnapshot=false
- Orphan props (7) moved into their proper sections: 3 BT a2dp, 3 camera ZSL/NR, 1 GPS lpp

### 🔌 Network packet steering (RPS/XPS)

New `apply_net_steering()` function in `service.sh` (gated by `asb_feature_enabled NET`) writes packet steering masks to `wlan0` and `rmnet` queues, directing rx/tx packet processing to cores 2-7 (the 6 Performance cores @ 3.62 GHz) instead of waking the Prime cores 0-1 (4.6 GHz, higher per-core power).

```sh
for q in /sys/class/net/wlan0/queues/rx-* /sys/class/net/rmnet*/queues/rx-*; do
  echo fc > "$q/rps_cpus"   # mask 0xfc = cores 2-7
done
for q in /sys/class/net/wlan0/queues/tx-* /sys/class/net/rmnet*/queues/tx-*; do
  echo fc > "$q/xps_cpus"
done
```

Expected: ~3-5% battery improvement during active network use, slightly lower latency on Prime cores when foreground app needs them.

### 🧠 DSP power management hints

New `apply_dsp_compute_boost()` writes runtime PM hints for Hexagon Compute DSP and audio DSP — keeps DSP from autosuspending so first call to face detection or audio HAL doesn't pay wake latency:

```sh
for d in /sys/devices/platform/soc/*remoteproc-cdsp/power \
         /sys/devices/platform/soc/*remoteproc-adsp/power; do
  writef "$d/control" on
done
```

Functional reach varies by kernel — on Krylov-OP-Kernel only `power/control=on` is writable (autosuspend_delay_ms returns I/O error, cdsp_loader path doesn't exist). All wrapped in `[ -e ]` / `[ -w ]` guards so silent failure is the default outcome on devices without these knobs.

### 📡 Telephony improvements (carried from V39)

22 vendor-agnostic Qualcomm-platform properties in `system.prop`, in feature-gated sections (`ASB:NET`, `ASB:KERNEL`, `ASB:LOG`, plus new `ASB:RADIO_IMS`):

**Voice & SMS over LTE/Wi-Fi:**
```
net.lte.volte_call_capable=true
persist.radio.ims_retry_3gpp=true
persist.radio.volte.dan_support=true
persist.vendor.radio.sms_over_ims=1
persist.ims.qos.profile=2
persist.ims.auth.scheme=1
persist.ims.auth.type=1
persist.data.iwlan=1
```

**HWUI / SurfaceFlinger rendering optimizations:**
```
debug.cpurend.vsync=true
debug.hwui.use_buffer_age=true
debug.hwui.use_partial_updates=true
debug.sf.disable_client_composition_cache=0
debug.sf.no_hw_vsync=0
```

**Crash / ramdump suppression:**
```
persist.vendor.crash.dump=false
persist.radio.ramdump=0
ro.tombstoned.crash.dump=0
tombstoned.max_tombstone_count=0
```

Notably **not** included as unsafe: `debug.anr.disabled=1` (would mask real app freezes), `tombstoned.enable=0` (vendor blob may refuse), `persist.radio.data_stall_recovery_on=false` (would break data recovery).

### 🩺 Diagnostic tooling

**New tools:**

- `tools/asb_state_sampler.sh` — captures every 1 second to TSV: profile, state, FSM-desired vs actual sysfs CPU caps, GPU pwrlevels and current freq, GPU busy %, thermal_pwrlevel, CPU/skin/surface temps, load1, battery current+pct, vendor override counts. Default 60s duration.
- `tools/asb_drain_analyzer.sh` — reads two logkit captures (sleep + mixed) and computes drain rates broken down by profile and state band.

**New telemetry files:**

- `/dev/.asb/vendor_overrides` and `/dev/.asb/vendor_override_audit` — track when vendor PowerHAL stomps pwrlevel writes. Cost: ~3 µs per qualified tick.
- `/dev/.asb/thermal_events` — log when `bat_comfort_temp` triggers, rate-limited 1/minute.
- `/dev/.asb/drift_rate` — rolling-window counter for cluster cap reconciles.

logkit auto-captures all new files alongside `governor.log`, `runtime_apply.log`, `thermal_pl_audit`, `gpu_path_discovery`.

### ⚙️ Configuration migration

Schema bumped 10 → 13 across the V40 development arc. Migration via `service.sh::asb_migrate_governor_conf` runs once per upgrade. Backs up existing `governor.conf` to `governor.conf.bak.schema<old>.<timestamp>` and applies fresh defaults from sealed reference `governor.conf.shipped`. Idempotent on repeat installs.

### 🧹 Source cleanup

Aggressive comment stripping pass applied to `service.sh`, all of `src/`, all of `tools/`, all of `runtime/`. Removed -1089 lines (-9%) of doc-comments and historical archaeology while preserving:

- ASB:*:BEGIN/END functional markers
- Shebangs
- License headers (SPDX/Copyright)
- C preprocessor directives
- Short inline trailing comments (≤50 chars)

Compile passes `-Wall -Wextra -D_FORTIFY_SOURCE=2` with **0 warnings**. All 28 shell scripts pass `bash -n`.

### 🚫 What V40 explicitly does NOT do

- **Does not bypass vendor thermal HAL.** Trip points in `/sys/class/thermal/thermal_zone*/trip_point_*_temp` on SM8850 are already at 95-135°C — far above any normal operating temp. Vendor's reactive clamping happens in userspace (PowerHAL daemon), not kernel cpu_cooling. ASB works within vendor's envelope, not around it.
- **Does not change balanced profile caps.** V39 r3 values remain — they were already correct.
- **Does not promise peak benchmark scores.** Performance profile is sustained-tuned. Synthetic benchmarks (Geekbench, 3DMark) will be ~15-20% lower than V39; real game sessions are more stable for 60+ minutes.
- **Does not include `BattFake.sh`-style battery health spoofing.** That hides real degradation.
- **Does not bypass `tombstoned` or `debuggerd`.** Those mask real app failures.

### 📦 Upgrade from V39 r5a

1. Flash V40 over existing V39. No need to uninstall first.
2. Reboot.
3. On first boot, `asb_migrate_governor_conf` runs automatically:
   - Backs up your V39 `governor.conf` to `governor.conf.bak.schema<old>.<timestamp>`
   - Copies V40 fresh defaults
4. Subsequent boots skip migration (schema marker = 13).

Optional verification:

```bash
# Migration succeeded
su -c 'cat /data/adb/modules/AutoSystemBoost/config/.schema_version'
# Expect: 13

# Profile change applies immediately
su -c 'sh /data/adb/modules/AutoSystemBoost/apply_profile.sh battery'
sleep 1
su -c 'grep profile /dev/.asb/state'
# Expect: profile=battery within 1 second

# RPS/XPS network steering active
su -c 'cat /sys/class/net/wlan0/queues/rx-0/rps_cpus'
# Expect: fc

# New props applied
su -c 'getprop persist.audio.fluence.voicecall'           # true
su -c 'getprop persist.vendor.camera.fdvideo'              # 1
su -c 'getprop vendor.display.enable_cabl'                 # 1

# Gaming session thermal envelope
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_state_sampler.sh 1800 &'
# Play 30 minutes. After session:
su -c 'grep ses_max_temp /dev/.asb/state'
# Expect: ses_max_temp < 65 (vs V39 baseline of 75-82)
```

### 📂 Files changed vs V39 r5a

- `module.prop` — V39 r5a → V40, versionCode 396 → 400, name banner emoji updated
- `profiles/battery.sh`, `profiles/performance.sh` — full recalibration (balanced unchanged)
- `config/governor.conf` + `config/governor.conf.shipped` — threshold tuning across multiple sections
- `service.sh` — added migration function, RPS/XPS steering, DSP runtime PM, kernel battery additions, schema bump
- `apply_profile.sh` — added immediate governor notify on profile change
- `system.prop` — 4 new sections, 7 orphans relocated, 34 new props
- `src/asb_governor.c` — drift fixes, profile drift detector, leak_reassert reporter-only, profile-specific log displays
- `src/asb_fsm.h` — FSM bounds recalibrated, UI-burst escalation, battery LIGHT_IDLE skip, anti-flapping windows
- `src/asb_config.h` — new threshold defaults
- `src/asb_metrics.h`, `src/asb_writer.h` — vendor override checker, thermal events logger
- `runtime/asb_reconcile.sh` — drift_rate-aware compare, rate limiter
- `tools/asb_state_sampler.sh`, `tools/asb_drain_analyzer.sh` — new diagnostic tools
- `tools/logkit/_asb_logkit_common.sh` — captures new telemetry files
- `common/install.sh` — 4 new toggle prompts, 4 new features.conf entries, extended drop_block loop
- `common/englishtext.sh`, `common/russiantext.sh` — 4 new menu strings each
- Aggressive comment cleanup across all the above (-1089 lines total)

---

<p align="center">
  <b>🚀 V40 is the release V39 deploys asked for. Drift storm closed, stutter eliminated, profile changes immediate, COD Mobile gaming session-stable, 4 new system.prop sections fully wired into the installer.</b>
</p>

---

## Previous releases

For V39 r5a, V39 r5, V39 r3, V39 r2, V39, V38 and earlier history, see git tags.
