# AutoSystemBoost — V64 Release Notes

<p align="center">
  <img src="https://img.shields.io/badge/Release-V64-16a34a?style=for-the-badge" alt="Release V64">
  <img src="https://img.shields.io/badge/Previous-V63-6b7280?style=for-the-badge" alt="Previous V63">
  <img src="https://img.shields.io/badge/versionCode-640-0ea5e9?style=for-the-badge" alt="versionCode 640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OnePlus 15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OnePlus 13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OnePlus 12">
  <img src="https://img.shields.io/badge/Ace%205%20%2F%20Ace%206-SM8650%20%2F%20SM8750-14b8a6?style=flat-square" alt="Ace 5 and Ace 6">
  <img src="https://img.shields.io/badge/Delivery-verified-8b5cf6?style=flat-square" alt="Verified delivery">
</p>

> **V63 made the module tidier. V64 asked whether the tweaks reach the system at all.** The answer was unpleasant: several subsystems had been writing correct files to paths nothing reads, and whole installer sections were skipped in silence. Most of this release is repairing delivery — then using the freed confidence to cut real power draw with measurements instead of intuition.

> Battery results still depend on display time, signal quality, applications, Bluetooth route and ambient temperature. V64 reports what it measured on the reference device and names what it cannot fix.

---

## V63 → V64 at a glance

| Area | V63 | V64 |
|---|---|---|
| Internal check pass ratio | 69% | **97%** |
| WebUI tweaks | 55 | **63** |
| DEEP_IDLE current (measured) | 140 mA | **50 mA** |
| sysfs reads per governor tick | 19 | **2** |
| Foreground probe | up to 3 `popen`/tick | cached, activity-tiered TTL |
| Watchdog, screen off | every 300 s | every 1800 s |
| `fsync` on the tick path | 3 files | none |
| Files changed | — | 103 changed, 52 added |

---

## Delivery: tweaks that were never applied

This is the core of the release. Each item below was a tweak that built its file, verified it, passed every internal check — and was read by nobody.

- **Camera, Wi-Fi and audio overlays landed outside the live tree.** The destination was built as `system/<source>`, and `${src#/system}` strips a prefix that does not exist for `/vendor/etc/audio` or `/odm/etc/camera`. On these devices `/vendor` and `/odm` are separate mount points, not symlinks into `/system`. Four sites across three subsystems, all corrected to mirror the live path while keeping the `system/` variants for devices where `/odm` really is a symlink.
- **Feature flags were resolved 2000 lines after their first use.** The `ASB_*` block sat at line 2735; the first `[ "$ASB_CAMERA" = "true" ]` test runs at 711. Every category check was false, and whole sections — audio, camera, network, kernel — were skipped without a word. The installer then rewrote `features.conf` from the same empty variables, producing zeros that shipped in the next build and reproduced themselves on every install.
- **Camera tone grading: four defects in one chain**, each hiding the next — wrong destination, a per-file destination list consumed after its loop closed, the grading block running before that list was filled, and `_cam_get` defined inside a conditional so it did not exist at the call site.
- **The retouch app list broke when the camera path was corrected.** Two consumers still pointed at the old `system/...` location and silently injected into nothing.
- **qdisc never reached the mobile link.** The interface filter required `operstate = up`; `rmnet` is virtual over the modem and the kernel leaves it at `unknown` for its whole life. A single fallback to `fq` was added for kernels lacking the requested qdisc, instead of leaving the link on `pfifo_fast`.
- **The night modem gate targeted paths that do not exist.** Two releases of the IPA gate matched nothing; the lookup now follows `/sys/class/wakeup` by the name the kernel itself reports.
- **Bluetooth absolute-volume output had no section**, so its line printed under whichever heading came last — usually CAMERA.

---

## Correctness

- **GAMING fired without a game.** GPU load and a busy CPU describe video playback, map rendering and an animated feed just as well. The state carries the loosest rails in the ladder, so a false positive spends power on a workload that never asked for it. Entry now requires the Smart package table to agree; devices without package detection keep the old behaviour.
- **Thermal lean was inverted.** Warm buckets raised the ceiling instead of lowering it, so every thermal decision worked against its own purpose. The stored model is reset on upgrade because its conclusions point the wrong way; the measurements are kept.
- **Learner showed "no data" on non-English interfaces.** The profile was read from the visible label, which is translated, and compared against English tokens. Every comparison against that variable was affected, not only the learner.
- **A disputed thermal sensor now buys more confirmation, never less safety.** Where the control source is uncorroborated, load-driven transitions need one extra tick; thermal escalation still acts immediately.
- **LPM mode comparison used pointer equality** on string literals — a silent no-op that made mode changes invisible.
- **Debug log capture failed on first press.** A lock whose PID was never recorded could not be reclaimed, so the next attempt reported "already running".
- **A trial of a value already set** now refuses with a reason instead of a bare "could not start".

---

## Battery and heat

- **Background uclamp tier in DEEP_IDLE: 29% → 18%.** The GPU was already pinned and the CPU rails were low, but a waking sync job could still ask the scheduler for a third of peak capacity with the screen off. **Measured on device: 140 mA → 50 mA.** Top-app and foreground are untouched, so unlocking is exactly as fast as before.
- **The module stopped loading the CPU in its sleep.** Screen-off raised swappiness by 20 unconditionally, costing 3.2 GiB of zram compression in a single DEEP_IDLE phase — CPU work done while the phone should be asleep, decompressed again on wake. The gate is now memory PSI: swap when tasks actually stall on memory, not when the screen goes off.
- **Prime cluster during quiet screen-off background work: 1665 → 1401 MHz.** Gated on a quiet run queue, because the data showed this state also covers sync bursts that genuinely want prime cores.
- **Active cooldown clamp.** A phone that falls asleep warm is pulled to hardware minimum until it cools, with entry and exit both logged so the night capture shows how long it held.
- **DSP gain backs off with heat** — 1200 mB above 55 °C, 800 above 60. Two steps rather than a curve: continuous gain movement is audible as pumping.
- **Light thermal trim requires a sustained deficit.** Headroom is a vendor estimate that moves on its own; trimming on a single dip was an action taken on noise that then had to be undone.
- **FSM oscillation.** Confirmation windows for the `MODERATE↔HEAVY` and `MODERATE↔SUSTAINED` pairs; field transitions fell from 99 to 24 per capture.

### Module overhead

| | V63 | V64 |
|---|---|---|
| Watchdog, screen off | 300 s | 1800 s |
| Network loop, screen off | 120 s | 600 s |
| Doze helper | every 600 s always | screen-off only |
| Reconcile | fixed interval | backs off when nothing drifts |
| `fsync` per tick | state + conflicts + learner | none |
| sysfs reads per tick | 19 | 2 |
| Foreground probe | up to 3 forks/tick | cached, 8 s / 25 s / 120 s by activity |

Governor timers are disarmed with the screen off and re-armed on wake; the calm tick cadence now covers 50% of screen-on time instead of 3%.

---

## New controls

- **Keep Apps In Memory** (`mglru_hold`) — working-set protection via `min_ttl_ms` on MGLRU kernels. The one lever in this area the kernel actually honours: the `lru_gen_config` property a third-party module ships is already ignored here, and disabling the Android 14+ collector is a downgrade, not a tune.
- **Bluetooth link stability** (`bt_link_stability`) — codec and interval policy for unstable links.
- **Network handover controls** (`net_handover_fast`, `net_handover_active`, `net_wifi_leave_rssi`, `net_avoid_bad_wifi`) — Wi-Fi to mobile transition behaviour, off by default.
- **Radio policy switch** (`radio_policy_enable`) — explicit opt-in before any cellular control is touched.
- **Media guard** (`smart_media_guard`) — keeps Smart from treating playback as idle.
- **`vendor_passive_clamps`** — the clamp count after which the module stops fighting for the cap. Previously hardcoded at 20, tuned against a single ROM.
- **GMS freeze level `max`** — Icing, Fitness and Romanesco components; `checkin` deliberately excluded.
- **Automatic config reload** — the governor watches the file's mtime. A WebUI save of a governor-owned key used to sit inert until reboot, and the diagnostic had to print instructions to reload by hand.
- **Settings trials** — put a risky control on probation for 12 hours with automatic revert.
- **Named config profiles**, snapshot import validation and a separate Smart Learning reset.

---

## Diagnostics

- **Devices that refused to suspend** are reported separately from wake sources. A refusal is worse: a wake source did its job and let go, while a refusal means the phone never went down at all. In a tester's report this immediately named the culprit — the Wi-Fi chip, 49 refusals in one capture.
- **Wake sources say whether they can be gated.** One device had 28 radio sources and not one with a runtime-PM handle, which means the night modem gate cannot help there. Now stated plainly instead of left to inference.
- **Module cost is published**: transitions, physical writes, readbacks, vendor overrides, write batches, settled ticks and probe cache hit rate — all as per-hour rates against the governor's own uptime, not system uptime.
- **Desired versus effective caps**, so a report can distinguish "the vendor trimmed us by 5%" from "our writes are being discarded".
- **Boot timeline**, apply ledger, per-phase wakelock holders with app names, and a 1 Hz trace of the first seconds after wake.
- **False failures removed.** Thermally reduced DSP gain is no longer reported as a failed write; camera checks under a partially mounted overlay report the mount problem rather than blaming the tweak; unsupported kernel nodes are distinguished from refused writes.
- **The action log names a partial overlay.** If the mount meta-module delivered one domain and not another, the missing one is printed instead of a bare "NOT APPLIED".

---

## Interface

Bottom navigation bar with swipe support, log and channel buttons moved onto the profile island, density scaling for stock-DPI devices, modals centred instead of bottom-anchored, camera tweak status showing whether a reboot is actually pending, Doze labels that name the real obstacle, and a sliders icon for Config.

---

## Packaging and safety

Build manifest with version, config schema, toolchain and governor hash. Config ownership registry covering all 177 keys. Contract tests for migration, reversibility, workflow integrity, wakelock-watcher safety and package parity — 52 new files, most of them tests.

---

## Honest limits

- **Radio remains the dominant cost.** Measured: traffic adds 128 mA, +63% to current with the screen on. No CPU ceiling offsets that, and V64 does not pretend otherwise.
- **Some wake sources are not reachable from userspace.** On several devices the modem nodes expose no control file; the module says so instead of promising an effect it cannot deliver.
- **Overlays can mount partially**, and whether they mount at all is the meta-module's job, not ASB's.
- **The cooldown clamp is hard to observe** — it only fires on a night that began warm, so its effect is logged rather than claimed.
