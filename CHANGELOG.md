# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V52-16a34a?style=for-the-badge" alt="V52">
  <img src="https://img.shields.io/badge/Previous-V51-6b7280?style=for-the-badge" alt="V51">
  <img src="https://img.shields.io/badge/versionCode-520-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## V52 — *three devices, one engine*

The big one: **full, first-class support for OnePlus 15, 13 and 12** — three SoC generations (SM8850 / SM8750 / SM8650), each device-tuned and tested on real hardware. Plus a long-standing OnePlus 12 + APatch camera bug solved at the root, a more autonomous Smart mode, and a round of fixes driven entirely by on-device logs.

> Cumulative on top of V51 — nothing removed. Every setting and all learned data carry across the update; reboot once after flashing.

### 📱 Tri-device support
- OnePlus 15 (`canoe` / SM8850), OnePlus 13 (`sun` / SM8750) and OnePlus 12 (`pineapple` / SM8650) are now all primary targets — per-device CPU/GPU topology, audio SKU, camera/media overlays and thermal shapes, validated on real units.

### 📷 OnePlus 12 + APatch camera — fixed at the root
- The multicamera HAL crash that broke the camera on OP12 under APatch (even with camera tweaks off) is solved. Root cause: the tweak engine touched the camera config at install **and** boot, which APatch's separate `/odm` mount couldn't tolerate.
- Now scoped precisely by reliable root-manager detection: **OP12 + APatch** keeps the camera byte-for-byte stock, while **OP12 + KernelSU** and **OP13/OP15** keep the full tweak set.

### 🔋 Smart mode — more autonomy, safely
- **New short screen-off tier (30–120 s):** reclaims the easy battery savings in brief "glance and put down" windows the logs showed Smart was missing — zero cost to responsiveness during active use.
- **New Smart Battery Bias slider** in the WebUI (under Aggressive Camera Tweaks): an optional dial to lean Smart further toward economy. Default off; scaled by confidence and clamped so it shifts the lean without flipping fully to battery.

### 🛰️ GPU & sensors
- **OP15 GPU caps now actually apply.** The Adreno 840 leaves devfreq frequency nodes empty and is driven by pwrlevel, so per-profile GPU caps were a silent no-op. A safe pwrlevel fallback fixes it — never overclocking past the vendor's thermal ceiling.
- **"Запас" (headroom) no longer stuck on n/a.** On SM8850 the kernel headroom signal latches as unreliable early in a boot and never recovered; it now re-validates once the signal proves trustworthy again.

### 🧪 Logkit (smart/gaming/sleep captures)
- Output lands on `/sdcard` next to the diag report instead of inside Termux's private dir.
- Trace now records real battery-current draw, GPU busy and live cluster frequencies; the summary adds a drain breakdown (screen on/off, per profile).
- A periodic wake-source snapshot lets standby drain be attributed instead of guessed — with an honest note that the capture holds a wakelock, so screen-off mA is an upper bound.

### 🌐 Battery / network
- **`network_stats_poll_interval`** stretched to 2 h in effective-battery states to trim wakeups — gated to the **LOG** category and applied in the battery profile (or Smart when strongly battery-leaning), fully reversible otherwise.

### 🩺 Diagnostics
- `asbdiag` now reports GPU control honestly on pwrlevel devices and runs a GPU write-test (does the cap stick, or does the vendor governor override it).
- Fixed a false OP13 camera FAIL (device-aware tone values) and a "GPU: n/a" display on OP15.

### 🧹 Housekeeping & pre-release audit
- Version string synced (governor reported V50 while everything else said V52) — triggers a clean one-time Smart relearn on update.
- Shipped-config parity restored, orphan tweak-baselines pruned, WebUI config descriptions shortened, history-narrative comments removed (markers/contracts kept).
- Verified: balanced section markers, up-to-date FSM bounds, valid CI workflows (NDK r28c), all `rm -rf` scoped, clean uninstall.

### 💾 Persistence
- All WebUI toggles and sliders (including the new Smart Battery Bias) carry over `governor.conf` on reinstall; active profile and everything Smart has learned live under `/data/adb/asb/`, outside the module — untouched by updates.
