# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V59-16a34a?style=for-the-badge" alt="V59">
  <img src="https://img.shields.io/badge/Previous-V58-6b7280?style=for-the-badge" alt="V58">
  <img src="https://img.shields.io/badge/versionCode-590-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <br>
  <img src="https://img.shields.io/badge/OnePlus%20Ace%206-SM8750-06b6d4?style=flat-square" alt="Ace 6">
  <img src="https://img.shields.io/badge/OnePlus%20Ace%205-SM8650-14b8a6?style=flat-square" alt="Ace 5">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V59 — *cooler thermals, quieter nights, leaner games*

Full-day field logs drove every change here. The headline is a thermal-decision
rework: ASB was reading a **junction sensor that sits at 85–95 °C under any load**
and treating it as "hot", so its veto fired constantly during normal use — while
the phone's actual surface was ~50 °C. V59 anchors thermal decisions to
user-facing skin temperature, stops asking the CPU for clocks the vendor clamps
away anyway, and fixes a batch of smaller diagnostics and Bluetooth issues.

### 🌡️ Skin-anchored thermal veto — no more false throttling on a hot die
The `cpu_max` sensor (`cpu-1-1-1`) is a junction/skin-hybrid that reads 85–95 °C
under load, so gating the Smart veto and throttle on it forced battery-lean bias
during ordinary bursts — defeating race-to-idle (which *costs* heat and drain, not
saves them). ASB now decides on the **shell/skin sensor** when one is present
(`thermal_skin_c`, default 47 °C) with a **junction hard-limit** as a silicon
safety net (`thermal_junction_hard_c`, default 95 °C). No skin sensor → it falls
back to the original junction gate, so behaviour is unchanged on devices without
one. Genuine skin heat and true silicon emergencies still throttle; a merely-hot
die during a light burst no longer does.

### 🎮 Gaming CPU ceiling — stop paying for clocks the vendor won't give
In gaming, the smart curve could declare scaling_max up to ~3 GHz, but the vendor
PowerHAL clamps the real clock to ~2.2 GHz regardless — so the extra request buys
**zero FPS** and only drives brief high-voltage OPP excursions (more heat + drain).
A new `gaming_cpu_max_ceiling_khz` (default 2.4 GHz, `0`=off) caps the *declared*
max during the GAMING state to just above the vendor's settle point. Applied
across representative and extra physical clusters (OP12's 4th cluster included).

### 🎧 Bluetooth volume: quiet-after-reboot fixed for every mode
Changing absolute-volume state left BT output quiet until an EQ/ViPER app
re-attached its effect. ASB now re-initialises the audio stack once at boot (waits
for the audio HAL, then restarts `audioserver`) for **all three** `bt_absvol_mode`
values, so the state is live from the first connection. The one-time `on → auto`
migration that overrode a deliberate choice was removed — your setting now persists
across updates.

### 📡 Mobile data no longer throttled during active use
The network layer no longer applies its screen-off battery bias while the screen is
on, so foreground data stays at full speed.

### ⚙️ WALT input-boost now matches the real CPU topology
`apply_walt_boost` was hard-coded to policies `0 4 7` (the old SM8550 layout);
OP15 (`0,6`) and SM8650 (`0,2,5,7`) never matched it, so some clusters were
silently skipped. It now discovers the device's actual cpufreq policies.

### 🔋 One more idle offender + cleaner diagnostics
`com.oplus.oidt` (an OPPO diagnostic hourly-timer seen in the wake logs) joins the
`rare` standby bucket. Diagnostics were tightened too: the full-day report no
longer hides most of the night, the screen-off metric measures the whole night
(not the last hour), a `sleep`/`post_wake` unreachable-code path was fixed, gaming
detection now uses a single reader with hysteresis, and `update.json` points at the
correct release.

### 💅 Installer & WebUI polish
A refreshed installer banner (multi-device, cleaner section rules) and an improved
WebUI. The ASB signature art stays.

---
