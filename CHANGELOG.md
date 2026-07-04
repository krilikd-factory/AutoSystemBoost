# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V57-16a34a?style=for-the-badge" alt="V57">
  <img src="https://img.shields.io/badge/Previous-V56-6b7280?style=for-the-badge" alt="V56">
  <img src="https://img.shields.io/badge/versionCode-570-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V57 — *network for gamers

Field telemetry from a full evening-night-day cycle on released V56 confirmed
the big fixes landed: idle drain **1.89 → 0.66 %/h**, active drain **10.1 →
6.4 %/h**, idle SoC peak **63 → 48 °C**, and the vendor-clamp write war fell
from 59% to 24% of ticks — the "boiler" is gone and nights are properly quiet
(7–37 mA in deep idle). V57 builds on that with a scenario-aware network layer
and a few targeted refinements — all within ASB's no-daemons, one-shot,
device-respecting philosophy.

### 🛠️ Ace 6 bootloop (issue #8): patched overlays for everyone, now with a fuse
The V52 "Ace 6 won't boot" bug came back in V55/V56: detection was still correct
(SM8750 siblings like ktm never match the OP13 overlay), but the unified
pipeline generated a device overlay for *every* OnePlus, and Ace 6's
ColorOS-based layout bootlooped on its own generated one — twice in the field.
The philosophy stays: **modifications are applied as patches to the device's
own files at install; ASB now ships ZERO static vendor files** (the last 49
OP15-shaped shipped statics are gone from the tree — they were being stripped
and regenerated on every supported device anyway). What changes is the safety
model on non-reference devices:
- Reference families (OnePlus 15 / 13 / 12 by confirmed codename) keep the
  proven pipeline and the 3-strike boot guard.
- Every other OnePlus still gets the full device-native patched overlay, but
  under a **1-strike boot fuse**: a single failed boot tears the whole
  generated overlay out before the module mounts (manifest replay + category
  sweep) and writes a persistent `/data/adb/asb/vendor_overlay_blocked`, so
  that device — and every future install on it — comes up governor-only until
  the user deliberately deletes the marker to retry. One bounce maximum,
  self-healing, remembered across updates.
- Upgrading straight from a bootlooping V55/V56 is clean: the failed-boot
  counter persisted in `/data/adb/asb`, so the very first V57 boot trips the
  fuse **before** the overlay ever mounts — zero bounces.
The old guard needed three failed boots and forgot everything on reinstall;
a hang (rather than a crash-loop) could defeat it entirely. The fuse fixes both.

### 🌐 TCP: scenario-aware — power-saving in sleep, low latency in games
ASB's network stack was already extensive; V57 fills the remaining gaps **and
makes the additions scenario-dependent**, riding ASB's per-profile network
engine (values re-apply on every profile change and on Smart's own internal
shifts):
- **Thin-stream retransmit mode** (`tcp_thin_linear_timeouts`/`tcp_thin_dupack`)
  — thin streams are exactly the small-packet flows of online games, so linear
  recovery cuts lag spikes after a lost packet. Enabled in balanced and
  performance; **disabled in battery**, where push connections are the thin
  streams and exponential backoff lets the radio sleep between retries.
- **`tcp_rto_max` per scenario**: 8 s in performance (fastest stall recovery for
  gaming), 15 s in balanced, kernel-default 120 s in battery so a stalled
  connection backs off instead of re-waking the modem all night.
- **Smart follows the day**: when Smart's learned battery-bias crosses into
  battery territory (α ≥ 0.8 — nights, low battery), the reconcile loop applies
  the full battery network set (5-hour keepalives, thin-stream off, small NAPI
  budgets) and restores the balanced set when the device wakes back up. Gaming
  under Smart keeps the low-latency set (the gaming heat-relax clamps α ≤ 0.4).
- **`tcp_mem` set dynamically** from the device's RAM (3% / 6% / 10% of pages)
  and the new **PLB** sysctls enabled where the kernel supports them — these two
  are scenario-independent by nature and stay static.
All one-shot guarded writes — no qdisc-watchdog or per-interface monitoring
daemons: a permanent polling loop would contradict the standby work that just
got idle drain to 0.66 %/h.

### 🎛️ Device-Adaptive Bounds toggle removed from the WebUI
Everything is decided at install now, so the toggle had no job left: the
installer sets `device_bounds_override` device-aware (ON on the OP15, where the
synthesized values equal the shipped hand-validated tuning; OFF elsewhere,
where OP15-derived ratios can under-clock UI clusters — the V55 OP12 lag),
the config carry-over deliberately never migrates it, and stale saved values
are scrubbed on upgrade. The WebUI writes config per-key, so removing the
control means the installer's choice simply persists. Power users can still
flip it by editing `governor.conf` directly.

### 🧠 Swappiness that actually sticks on OxygenOS
OxygenOS carries its own swappiness scene props
(`sys.mem.swappiness_on_launcher`, `sys.mem.swappiness_on_start`,
`sys.sysctl.swappiness`) and can re-assert them over `vm.swappiness`. ASB's
per-profile swappiness is now mirrored into those props — but only when they
already exist on the device, so nothing new is created on ROMs that don't use
them. A boot-time zram resize was deliberately avoided: it would fight
OxygenOS's own RAM-expansion management, which ASB already handles.
