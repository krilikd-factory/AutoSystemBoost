# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V39-16a34a?style=for-the-badge" alt="V39">
  <img src="https://img.shields.io/badge/Previous-V38-6b7280?style=for-the-badge" alt="V38">
  <img src="https://img.shields.io/badge/versionCode-390-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## 🚀 V39 — Battery Profile Recalibrated + GPU Ownership + Honest Defaults

> **V38 made thermal telemetry honest. V39 makes battery profile actually usable on Snapdragon 8 Elite Gen 5, closes the GPU control gap that was silently failing on this SoC, and recalibrates default thresholds based on weeks of real-device telemetry from V38 deploys.**

V39 is the product of extended on-device validation across battery / balanced / performance profiles, full-day mixed usage, overnight sleep, and gaming sessions. Every change below is grounded in deploy data, not theory. Where V38 captured ground truth, V39 acts on it.

---

### 📊 What you'll feel after upgrading from V38

| Symptom on V38 | Behaviour on V39 |
|---|---|
| Battery profile UI lags noticeably during scrolling | Smooth at 144Hz |
| AdGuard VPN service randomly stops protecting | Stays alive — VPN service has working CPU budget |
| Phone hangs / requires reset to free memory | GC and LMKD have headroom to do their job |
| `state=HEAVY` stuck for hours on idle phone | FSM correctly returns to IDLE during low-load periods |
| Comfort cap demotes UI on warm device | Activates only above 50°C, doesn't interfere with typical browsing |
| GPU caps writes silently fail on Snapdragon 8 Elite Gen 5 | GPU control works correctly via pwrlevel interface |
| Bluetooth Pixel Buds Pro 2 hangs on "loading" with Opus codec | Codec table no longer corrupted, AAC/SBC negotiate cleanly |
| OnePlus camera Hasselblad/Explorer modes inactive | Enabled via resetprop on supported devices |

Battery life trade-off: ~5-10% higher drain vs V38 in exchange for usable UX. Most users will gain back what they lost from V38's CPU-cap-too-aggressive idle thrash.

---

### 🔬 What Actually Changed

#### Battery profile recalibrated for Snapdragon 8 Elite Gen 5

V38 inherited cap values calibrated for older Qualcomm SoCs. On 4.6 GHz Oryon P-cluster + 1.2 GHz Adreno 840 GPU, those values produce caps an order of magnitude too low for basic Android UX:

```diff
profiles/battery.sh:
- CPU_MAX_LITTLE=1132800   CPU_MAX_BIG=998400      # 998 MHz P-cluster max!
- CPU_CAP_LITTLE=614400    CPU_CAP_BIG=921600
- UCL_TOP_MAX=12           UCL_FG_MAX=8            UCL_BG_MAX=5
- GPU_MAX_PCT=15           # = 180 MHz GPU on a 1200 MHz device
+ CPU_MAX_LITTLE=1804800   CPU_MAX_BIG=2400000
+ CPU_CAP_LITTLE=1132800   CPU_CAP_BIG=1113600
+ UCL_TOP_MAX=65           UCL_FG_MAX=55           UCL_BG_MAX=40
+ GPU_MAX_PCT=55           # = 660 MHz GPU, smooth UI composer
```

`uclamp` is the scheduler's hint about maximum allowed frequency for each cgroup tier, applied **before** the cpufreq governor. With `top-app uclamp.max=12` (V38), UI tasks were physically capped at ~552 MHz of P-cluster headroom regardless of `scaling_max_freq`. V39 raises this to ~3 GHz, which is what 144 Hz UI scheduling actually needs.

`UCL_FG_MAX=8` (V38) is the killer for VPN apps. AdGuard's VPN service runs in `foreground` cgroup. At 8% × 4608 MHz = 368 MHz, the service can't keep up with packet inspection deadlines. Android's watchdog kills it. After V39's bump to 55%, it stays alive.

`UCL_BG_MAX=5` was strangling GC and LMKD. After V39's bump to 40%, memory management catches up to allocation rate, no more "phone freezes, need to reset to free memory" reports.

The corresponding C-side `g_profile_bounds[BATTERY]` table in `src/asb_fsm.h` was also recalibrated to match.

#### Default thresholds raised (configuration migration)

V38's `governor.conf` shipped with `heavy_load_enter=5.4`. Linux loadavg-1min on Snapdragon 8 Elite Gen 5 with NeoZygisk + LSPosed + Vector + AdGuard + GMS routinely sits at 6-12 even when phone is genuinely idle. V38's threshold caused the FSM to enter HEAVY state on background activity. Real telemetry showed `ses_heavy=7747s` (2 hours 9 minutes continuous HEAVY) at temp=27-32°C and gpu=0%.

```diff
config/governor.conf:
- heavy_load_enter=5.4         moderate_load_enter=3.2
- bat_heavy_load_enter=18.5    bat_moderate_load_enter=12.5
- balanced_heavy_load_enter=6.2  balanced_moderate_load_enter=3.2
- bat_fast_idle_s=8
- bat_comfort_temp=38
+ heavy_load_enter=20.0        moderate_load_enter=14.0
+ bat_heavy_load_enter=20.0    bat_moderate_load_enter=14.0
+ balanced_heavy_load_enter=20.0 balanced_moderate_load_enter=14.0
+ bat_fast_idle_s=15
+ bat_comfort_temp=50
```

After V39, FSM only enters HEAVY on real CPU pressure, not background noise. `ses_heavy_sec` drops from ~30% of session to typically <5%.

#### Battery comfort cap fixed

V38 had `bat_comfort_temp=38` which combined with logic that demoted any HEAVY/SUSTAINED/GAMING desire down to MODERATE. On Snapdragon 8 Elite Gen 5, 38°C is below pocket temperature — phone literally never went above this threshold during normal use, so the cap fired constantly. Each demotion was a state transition + cap write storm + missed UI frame.

```diff
src/asb_config.h:    c->bat_comfort_temp = 38   →   c->bat_comfort_temp = 50
src/asb_fsm.h:       desired = MODERATE         →   desired = HEAVY  (when desired was > HEAVY)
```

Two fixes together: the comfort threshold is now where modern silicon actually starts to thermally stress (50°C), AND it caps to HEAVY (preserves UI burst frequencies) instead of MODERATE. Result: battery profile UI feels smooth in mixed use.

#### GPU control on Qualcomm KGSL — pwrlevel mode

V38 wrote GPU caps to `/sys/class/kgsl/kgsl-3d0/devfreq/max_freq`. This path **does not exist on Snapdragon 8 Elite Gen 5** — the modern KGSL driver exposes a different control surface entirely. V38's GPU writes were silently failing with `ENOENT`. No GPU caps were actually being enforced.

V39's GPU writer:

1. **Path discovery** at startup probes the writable control node:
   ```
   /sys/class/kgsl/kgsl-3d0/devfreq/max_freq             (legacy Qualcomm)
   /sys/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq     (modern GKI)
   /sys/class/devfreq/3d00000.qcom,gpu/max_freq          (newer naming)
   /sys/class/kgsl/kgsl-3d0/max_pwrlevel                 (KGSL-native, used on SM8850)
   ```
   Discovery uses real round-trip write probes, not just `open(O_WRONLY)`, because some nodes accept open but reject actual writes (e.g. `max_gpuclk` is a status node).

2. **Pwrlevel mode** when no Hz path is writable. `max_pwrlevel` and `min_pwrlevel` take integer indices (0 = highest freq, N-1 = lowest). The writer reads `gpu_available_frequencies` at discovery, builds a frequency table, and translates Hz targets into the closest pwrlevel.

3. **Failure logging.** Previously silent failures now log to `/dev/.asb/write_errors`. Discovery details available in `/dev/.asb/gpu_path_discovery`.

#### thermal_pwrlevel monitoring (vendor cap visibility)

On Qualcomm KGSL, the kernel maintains a separate `thermal_pwrlevel` cap that overrides ASB's `max_pwrlevel` write when GPU thermal limits trip. V39 monitors this signal so ASB can know when vendor is throttling above its cap.

The implementation is **deliberately frugal**:
- File descriptor cached at discovery (one `open()` per module lifetime)
- Reads use `pread()` instead of seek+read (one syscall)
- Skipped entirely when screen off, in DEEP_IDLE state, or within 2 seconds of last read
- In LIGHT_IDLE/MODERATE: rate-limited to every Nth qualified tick (configurable, default 3)
- In HEAVY/SUSTAINED/GAMING: read each qualified tick

Self-reporting audit counter writes hourly summaries to `/dev/.asb/thermal_pl_audit` so users can verify cost themselves with real numbers. Real measured cost on V39 deploy: ~10-50ms CPU per hour = below 0.001% CPU usage = below battery measurement noise.

#### HEAVY-stickiness fix

V38's FSM had no upper-side guard against vendor raising `scaling_max_freq` above ASB's write. On battery and balanced profiles a vendor "raise above" event (e.g. perf_cap kicking in for an app) would persistently leak the configured profile cap. V39 adds a leak-reassert watchdog: if sysfs `scaling_max_freq` exceeds ASB's desired cap by >100 MHz for 2+ consecutive ticks on a non-perf profile, ASB rewrites the cap directly, with a 4-second cooldown and a 5-per-minute rate limit. Surrenders if vendor wins persistently — won't fight thermal-headroom-aware kernel policy.

#### Dead msm_performance interface detection

On SM8850, `/sys/kernel/msm_performance/parameters/cpu_max_freq` always reports HW max regardless of actual cap state. V38 trusted this signal and made decisions on it. V39 detects when headroom reads are stuck at 100% for 60+ consecutive samples (~10 minutes) and latches `headroom_invalid_reason="dead_iface"` for the rest of the boot session. Other code paths that depend on headroom now correctly skip making decisions on this signal when it's known dead.

#### Cap source classifier corrected

V38's `cap_source_classify()` was passed FSM's *intended* write (`fsm->current_caps.cpu_max[]`) as `runtime_declared`, instead of what actually registered with the kernel via msm_performance (`m->therm.perf_cap_*`). On battery profile where `perf_cap_*=0` (msm_performance disabled by design for power), the shell-only branch never fired, and battery state was misreported as `vendor_clamp`/`vendor_raised` instead of the correct `shell_applied`/`shell_overridden_*`. V39 passes the correct argument; classifier now produces honest values.

#### Bluetooth codec corruption fix

V38's installer ran vendor BT XML and config files through:

```
sedi 's/.../<<!--.*-->>//; .../; /<!--/,/-->/d; /^ *#/d; /^ *$/d'
```

The `/<!--/,/-->/d` range delete was destructive on multi-line codec disabled-blocks like:

```xml
<!-- Opus codec is OEM-specific (Pixel only)
<a2dp_codec name="opus" priority="1000" ... />
-->
```

`sed` is line-oriented; depending on layout it could delete only the opening `<!--` line and leave codec metadata as syntactically-valid-looking-but-functionally-broken XML elements. Result: codec parser advertised Opus on Qualcomm devices that don't have Opus encoder, A2DP handshake hung, audio stayed in speakers. Confirmed cause of Pixel Buds Pro 2 connection failures on OnePlus 13R and similar non-Pixel hardware.

V39 replaces the dangerous `sedi` invocations on `a2dp.xml`, `bluetooth_qti.xml`, `bt_configstore.conf`, `bt_stack.conf` with blank-line-trim only. Vendor codec definitions stay intact. Codec negotiation sees what the vendor intended.

(Note: Opus over A2DP cannot work on non-Pixel devices regardless of fix — Qualcomm vendor blob has no Opus encoder. The fix ensures other codecs negotiate cleanly.)

#### OnePlus camera enable props

`service.sh::apply_camera_runtime` now sets:

```sh
resetprop -n ro.vendor.oplus.camera.isSupportExplorer 1
resetprop -n ro.vendor.oplus.camera.isHasselbladCamera 1
```

These are `ro.vendor.*` (read-only via `setprop`), so `resetprop` is required. Gated by `asb_feature_enabled CAMERA && has resetprop`.

#### Configuration auto-migration

Because V39 raises default thresholds substantially over V38, an automatic migration is needed. Otherwise users upgrading from V38 keep their on-disk `governor.conf` (correct policy: never silently overwrite user files) and get none of V39's tuning improvements.

V39 ships a sealed reference copy `config/governor.conf.shipped` set at install time. `service.sh::asb_migrate_governor_conf` runs at every boot:

1. Reads schema marker `config/.schema_version` (default 0 if missing)
2. If marker < current expected schema (10): backup current `governor.conf` to `governor.conf.bak.schema<old>.<timestamp>` and copy fresh from sealed reference
3. Updates schema marker
4. Subsequent boots see schema=current, skip entirely

Result: V38 users get V39's improved defaults on first boot, with full backup of their previous config preserved indefinitely. Power users who customized V38's settings can find their previous values in the backup file and merge them in manually.

To preserve current settings against future schema bumps: edit `.schema_version` to a higher number after migration. To revert to V38 behavior: copy backup file over current `governor.conf`.

#### Other improvements

- All compile warnings cleared. V38 had 8 legacy `read`/`write`/`fgets`/`fscanf` ignored-return + `strncpy` truncation warnings. V39 builds clean with `-O2 -Wall -Wextra -D_FORTIFY_SOURCE=2`.
- Self-tune logic for `bat_heavy_load_enter` / `bat_moderate_load_enter` now uses 10.0/8.0 floors and 20.0/15.0 ceilings consistent with new defaults.
- Status JSON includes additional thermal source visibility: `gpu_thermal_pwrlevel`, `gpu_thermal_pwrlevel_active`.
- Cosmetic cleanups in `common/install.sh` (duplicate `if`/`fi` removed).

---

### 🚫 What V39 explicitly does NOT do

- **Does not change performance profile caps.** Performance profile is for users who explicitly want raw output; recalibration there would change semantics. Untouched.
- **Does not auto-overwrite balanced profile.** Only `UCL_TOP_MAX=85→90` and the C-side balanced ceil `uclamp_top_max=80→85` for slightly more UI burst headroom. Other balanced values intact.
- **Does not promise Opus codec works on non-Pixel hardware.** Vendor blob limitation; outside any user-space module's control.
- **Does not tighten any sustained / gaming thresholds.** `sustained_temp_enter`, `gaming_gpu_enter`, `heavy_min_dwell_s` unchanged — these were already well-calibrated in V38.
- **Does not reduce battery capacity in DEEP_IDLE.** New caps engage only when screen-on or load is real. Overnight sleep behaviour identical to V38.

---

### 📁 File change summary

```
src/asb_config.h           tunable defaults raised, 2 new fields for thermal_pwrlevel
src/asb_fsm.h              g_profile_bounds[BATTERY] + [BALANCED] recalibrated
src/asb_writer.h           +330 lines: GPU path discovery, pwrlevel mode, thermal_pwrlevel reader
src/asb_metrics.h          +71 lines: GPU path probing in metrics, thermal struct extensions
src/asb_governor.c         leak-reassert watchdog, classifier fix, dead_iface latch,
                           thermal_pwrlevel monitoring with 3 caution gates + audit
profiles/battery.sh        CPU/GPU/uclamp caps recalibrated for Snapdragon 8 Elite Gen 5
profiles/balanced.sh       UCL_TOP_MAX 85 → 90
service.sh                 governor.conf migration, OnePlus camera resetprops
common/install.sh          BT XML safety fix, governor.conf.shipped seal at install,
                           build_manifest schema 8 → 10
config/governor.conf       defaults raised (see "Default thresholds" above)
config/governor.conf.shipped  NEW: sealed reference copy used by migration
```

---

### 📦 Upgrade from V38

1. Flash V39 over existing V38. No need to uninstall first.
2. Reboot.
3. On first boot, `service.sh::asb_migrate_governor_conf` runs automatically:
   - Backs up your V38 `governor.conf` to `governor.conf.bak.schema0.<timestamp>`
   - Copies V39 fresh defaults
4. Subsequent boots skip migration (schema marker present).

Optional verification:

```bash
# After first boot — confirm migration ran
su -c 'cat /data/adb/modules/AutoSystemBoost/config/.schema_version'
# Expect: 10

# Find your V38 backup if you want to recover any customizations
su -c 'ls /data/adb/modules/AutoSystemBoost/config/governor.conf.bak.*'

# Verify GPU control is working
su -c 'cat /dev/.asb/gpu_path_discovery'
# Expect: max=/sys/class/kgsl/kgsl-3d0/max_pwrlevel (or similar valid path)
#         mode=pwrlevel (on SM8850)

# Verify thermal_pwrlevel monitoring is honest
su -c 'cat /dev/.asb/thermal_pl_audit'
# After ~1 hour: reads should be a few hundred to a few thousand depending
# on activity, total_us should be a few thousand. Cost calculation:
# total_us / 1e6 / 3600 * 100 = % CPU usage, should be << 0.001%
```

---

<p align="center">
  <b>🚀 V39 turns V38's measurements into action: usable battery profile, working GPU control, honest defaults.</b>
</p>

---

