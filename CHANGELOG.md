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

## V58 — *every OnePlus, patched natively*

The device-native overlay was proven on the OnePlus 15 reference; **V58 makes it
truly multi-device.** OnePlus 13 / 12, and now **OnePlus Ace 6** and **OnePlus
Ace 5**, build a correct overlay from their *own* stock files, activate in one
reboot, and pass diagnostics — while the OP15 daily-driver behaviour is left
exactly as it was.

### 🆔 The installer now knows what it's running on
Detection resolves the real marketing name (`ro.vendor.oplus.market.*`, with a
model/codename/project fallback) and prints it — `Device identified: OnePlus
Ace 6` — instead of a confusing "generic"/"OP15" label.

### 🔊 Ace 5 speaker-volume regression fixed
On the SM8650 codec the WCD/WSA *Digital Volume* controls top out at 0 dB = 84;
writing 88 put the speaker path out of range (full-blast speaker, BT volume knocked
out). The digital-gain ceiling is now **device-gated: 84 on SM8650/pineapple, 88
elsewhere.**

### 📶 Ace 6 Wi-Fi, HPH and hi-res landed
Nested-only WCNSS layouts (`kiwi_v2 / peach / peach_v2`) are detected with bounded
globs; HPH Mode promotion covers the whole Class-H family (`ULP/LOHIFI/LP/NORMAL →
CLS_H_HIFI`); and a **format-agnostic hi-res lifter** appends the missing
384000-class rates in the list's own separator — comma **or** space — so Ace 6's
space-separated `"44100 48000 88200 96000"` is finally covered. 1080p bitrate lift
is now gated on the media category so it lands here too.

### 🔁 One reboot, bootloop-safe — the /odm lesson
Everything the diagnostics read lives under `/vendor/etc` and activates via the
standard `/vendor` magic-mount overlay — one reboot, exactly like OP15. The Ace 6
hard-bootloop was traced to grafting `/odm` content (a bind-mount of another
partition) into the magic-mount tree, so every `/odm` graft is hard-removed and
real `/odm` audio is delivered by **fuse-guarded runtime binds** in post-fs-data
(boot counter synced to disk before any bind → at most one recoverable boot, never
a loop).

### 🎮 OnePlus 15 gaming thermals catch the ramp
The gaming thermal engage point moved 65 °C → 60 °C so the proactive GPU lean fires
before the vendor's reactive loop takes over. (Refined further in V59, above.)

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
