# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V41-16a34a?style=for-the-badge" alt="V41">
  <img src="https://img.shields.io/badge/Previous-V40-6b7280?style=for-the-badge" alt="V40">
  <img src="https://img.shields.io/badge/versionCode-410-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

> **V41 introduces the first round of vendor overlay modifications on OnePlus 15. Magisk magic-mount replaces three of Qualcomm's perf-hal config files at boot, reducing the thermal trigger temperature inside Qualcomm Adaptive Performance Engine (QAPE) from 48°C to 44°C across all 26 supported games, halving the per-cycle boost duration, and unifying full WiFi channel-bonding configuration across all four WCNSS chip variants. Real-device gaming sessions on V41 show peak temperatures 5°C lower than V40 (77°C vs 82°C) with markedly fewer GAMING↔SUSTAINED transitions per hour. The mods are gated by a boot-counter so three consecutive failed boots will auto-disable the overlay.**

---

## 🛡️ V41 — Vendor Overlay Phase 1 + WiFi mod

### 🔬 Qualcomm Performance Engine (QAPE) thermal trigger tune

V40 deploy data showed a consistent pattern: even with ASB declaring conservative CPU caps, vendor PowerHAL clamped the actual `scaling_max_freq` to ~1.0-1.2 GHz once temperature hit ~60°C in COD Mobile sessions. ASB correctly stopped fighting (the `clamp_hold` mechanism kicked in), but the user was left with sub-Class-0 frequencies for most of the gameplay session.

Reverse-engineering of the OnePlus 15 vendor blob revealed:

- `/vendor/etc/thermal-engine.conf` is **empty** — all thermal logic delegated to QAPE in perf-hal
- `/vendor/etc/perf/qapegameconfig.txt` is a plain-text file with format `GameID GameAPK MaxTemperature MaxCurrent AvgCurrent` per row
- Every game including COD Mobile had `MaxTemperature=48000` mC (48°C) as the trigger for QAPE class downgrade
- `/vendor/etc/perf/perfconfigstore.xml` exposes `ro.vendor.perf.qape.boost_duration=6` and `qape.max_boost_count=2` — knobs that control how aggressively QAPE issues short boost cycles

The new V41 vendor overlay (mounted via Magisk magic-mount over `/vendor/etc/perf/`):

```diff
qapegameconfig.txt:
- codm    48000   1150   1000
+ codm    44000    900    800
```

(Same treatment applied to all 26 game entries: hok, Genshin, WutheringWaves, StarRail, ZenlessZoneZero, NARAKA, Arena_Breakout, Tencent_LOL/DNF/PRacing/Spatula, Infinity_Nikki, JusticeOnline, Racing_Master, Tarisland, and the `Default` fallback.)

```diff
perfconfigstore.xml:
- <Prop Name="ro.vendor.perf.qape.boost_duration"   Value="6" />
- <Prop Name="ro.vendor.perf.qape.max_boost_count"  Value="2" />
+ <Prop Name="ro.vendor.perf.qape.boost_duration"   Value="3" />
+ <Prop Name="ro.vendor.perf.qape.max_boost_count"  Value="1" />
```

QAPE boost cycles last half as long and only one cycle per game session instead of two. Removes the heat-accumulation pattern from repeated short power spikes.

The resetprop fallback in `post-fs-data.sh` covers the case where perf-hal-service has already read `perfconfigstore.xml` before Magisk's overlay is active — these `ro.vendor.perf.qape.*` properties are then forced via `resetprop -n` to match the overlay values.

### 📶 WiFi mod configuration (unified across all chip variants)

OnePlus 15 ships with three WCNSS variants (kiwi_v2, wcn7750, peach_v2) plus an ODM-specific overlay. Vendor stock had `gChannelBondingMode5GHz=1` set on all four files but the other three relevant settings only on the ODM file, leaving the chip-specific configs incomplete.

V41 unifies all four `WCNSS_qcom_cfg.ini` files with the complete set:

```ini
gChannelBondingMode24GHz=1   # 40 MHz channel on 2.4 GHz (2× theoretical throughput)
gChannelBondingMode5GHz=1    # 40 MHz channel on 5 GHz (preserved)
gForce1x1Exception=0         # disables forced 1T1R fallback for MTK access points
sae_enabled=1                # enables WPA3 SAE authentication
```

Files updated:
- `system/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini`
- `system/vendor/etc/wifi/wcn7750/WCNSS_qcom_cfg.ini`
- `system/vendor/etc/wifi/peach_v2/WCNSS_qcom_cfg.ini`
- `system/vendor/odm/vendor/etc/wifi/WCNSS_qcom_cfg.ini`

### 🩹 Bootloop protection

The vendor overlay carries a non-zero risk on first deploy. V41 ships a boot counter mechanism:

```
/data/adb/asb_vendor_boot_counter
```

- `post-fs-data.sh` increments the counter before activating overlay
- `service.sh` clears the counter to 0 after `sys.boot_completed=1` (background task, 180s timeout)
- If counter reaches 3 (three failed boots), `post-fs-data.sh` deletes the overlay files from the module — Magisk's next mount cycle won't include them, vendor stock files become active on the next boot

Logs at `/data/adb/asb_vendor_mounts.log`. State files cleaned up by `uninstall.sh`.

### 🛠 Diagnostic tools preserved at install time

V40's `install.sh` ended with `rm -rf $MODPATH/tools` — historic cleanup of external install-time binaries that incorrectly took ASB's own diagnostic scripts with it. V41 replaces this with selective preservation:

```sh
if [ -d "$MODPATH/tools" ]; then
  find "$MODPATH/tools" -maxdepth 1 -type f \
    ! -name "asb_state_sampler.sh" \
    ! -name "asb_drain_analyzer.sh" \
    ! -name "asb_doctor.sh" \
    ! -name "asb_lint.sh" \
    ! -name "asb_session_report.py" \
    ! -name "asb_compare_sessions.py" \
    ! -name "asb_analyze.py" \
    -delete 2>/dev/null
fi
```

The seven user-facing diagnostic scripts now survive install. Sub-directory `tools/logkit/` was already preserved by the old `-maxdepth 1` flag and continues to be available.

### 📊 Real-device results

| Metric | V40 release | V41 release | Delta |
|---|---|---|---|
| COD Mobile peak temp (ses_max_temp transient) | 82°C | 77°C | **-5°C** |
| HEAVY state average temperature | 50°C | 41-49°C | **-5°C** |
| GAMING state average temperature | 58°C | 53-56°C | **-3°C** |
| Sustained transitions per gaming hour | 11 | 2 | **-80%** |
| `ses_auto_degraded` trigger reliability | working | working | stable |
| Boot success rate | baseline | baseline | unchanged |

The QAPE 44°C trigger lets the device enter Class 1 before vendor's reactive 60°C clamp fires, so the worst-case 1.0-1.2 GHz emergency clamps from V40 are encountered far less often. ASB's own FSM, profile system, and battery/balanced/performance switching are untouched from V40 — this is a purely vendor-side complement to the existing scheduling logic.

### 🚫 What V41 explicitly does NOT do

- **No vendor binary patching.** A `thermal-service.qti` binary patch was explored during V41 development (file offset `0x74dc` contains the CPU thermal threshold table) but the patched binary was rejected by Android Verified Boot at execve time, causing instant bootloop. The patch artifact is preserved in development history; deploying it requires bootloader unlock and AVB disable on the device side, outside Magisk/KSU module scope.
- **No kernel `cpu_cooling` modification.** OnePlus 15 trip points are already at 95-135°C and never trigger in normal operation; the vendor's reactive clamp lives in userspace daemons, not kernel drivers.
- **No QAPE Class 0/1/2 frequency table changes.** A `qapeboostsconfig.xml` modification was tested in V41 development but produced no measurable effect because vendor's second-layer clamp overrides QAPE Class 0 anyway. Reverted to vendor stock to minimize divergence from baseline.
- **No FSM, profile, or governor changes vs V40.** V40's profile recalibration, drift fixes, UI stutter elimination, and battery economy improvements all remain in effect.

### 📦 Upgrade from V40

1. Flash V41 zip over V40 (no uninstall required)
2. Reboot
3. Validation:

```bash
# Vendor overlay active
su -c 'cat /data/adb/asb_vendor_overlay_active'
# Expect: 1

# Boot counter cleared after successful boot
su -c 'cat /data/adb/asb_vendor_boot_counter'
# Expect: 0

# QAPE thermal trigger overlay applied
su -c 'grep codm /vendor/etc/perf/qapegameconfig.txt'
# Expect: 100002    codm                44000           900         800

# QAPE boost properties forced via resetprop
su -c 'getprop ro.vendor.perf.qape.boost_duration'    # 3
su -c 'getprop ro.vendor.perf.qape.max_boost_count'   # 1

# WiFi bonding active (sample one chip variant)
su -c 'grep "gChannelBondingMode24GHz\|sae_enabled" /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini'
# Expect: gChannelBondingMode24GHz=1, sae_enabled=1

# Diagnostic tools survived install
su -c 'ls /data/adb/modules/AutoSystemBoost/tools/'
# Expect: asb_state_sampler.sh, asb_drain_analyzer.sh, asb_doctor.sh, ..., logkit/

# Gaming session thermal envelope test (after switching to performance profile)
su -c 'sh /data/adb/modules/AutoSystemBoost/apply_profile.sh performance'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_state_sampler.sh 1800 &'
# Play COD 30+ minutes, then:
su -c 'grep ses_max_temp /dev/.asb/state'
# V40 baseline: 82°C  
# V41 target:   <75°C
```

### 📂 Files changed vs V40

- `module.prop` — V40→V41, versionCode 400→410
- `update.json` — version, versionCode, zipUrl bumped
- `action.sh` — installer banner V40→V41
- `webroot/index.html` — verBadge V40→V41
- `system/vendor/etc/perf/qapegameconfig.txt` — **NEW** overlay file (MaxTemperature/MaxCurrent/AvgCurrent lowered across all 26 game entries)
- `system/vendor/etc/perf/perfconfigstore.xml` — qape.boost_duration 6→3, qape.max_boost_count 2→1
- `system/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini` — added gChannelBondingMode24GHz=1, gForce1x1Exception=0, sae_enabled=1
- `system/vendor/etc/wifi/wcn7750/WCNSS_qcom_cfg.ini` — same additions
- `system/vendor/etc/wifi/peach_v2/WCNSS_qcom_cfg.ini` — same additions
- `system/vendor/odm/vendor/etc/wifi/WCNSS_qcom_cfg.ini` — added sae_enabled=1 (other three were already present in ODM stock)
- `post-fs-data.sh` — new `# ASB:VENDOR_OVERLAY:BEGIN` block (boot counter, bootloop protection, resetprop fallback for QAPE properties)
- `service.sh` — background task to clear boot counter after `sys.boot_completed=1`
- `common/install.sh` — features.conf now writes `VENDOR_OVERLAY=1`, boot counter initialized at 0, `rm -rf $MODPATH/tools` replaced with selective preservation
- `uninstall.sh` — cleans `/data/adb/asb_vendor_*` state files

---

<p align="center">
  <b>🛡️ V41 brings the first vendor-side complement to ASB's profile/governor system. The QAPE 44°C trigger, halved boost durations, and unified WCNSS WiFi configs work alongside V40's FSM and profile machinery to reduce thermal stress on long sessions without touching the proven scheduling logic.</b>
</p>

---
