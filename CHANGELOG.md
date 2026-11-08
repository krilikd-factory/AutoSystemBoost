# AutoSystemBoost — V65 Release Notes

<p align="center">
  <img src="https://img.shields.io/badge/Release-V65-16a34a?style=for-the-badge" alt="Release V65">
  <img src="https://img.shields.io/badge/Previous-V64-6b7280?style=for-the-badge" alt="Previous V64">
  <img src="https://img.shields.io/badge/versionCode-65339-0ea5e9?style=for-the-badge" alt="versionCode 65339">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OnePlus 15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OnePlus 13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OnePlus 12">
  <img src="https://img.shields.io/badge/Ace%205%20%2F%20Ace%206-SM8650%20%2F%20SM8750-14b8a6?style=flat-square" alt="Ace 5 and Ace 6">
  <img src="https://img.shields.io/badge/Reports-evidence--bounded-8b5cf6?style=flat-square" alt="Evidence-bounded reports">
</p>

> **V64 made sure the tweaks reach the system. V65 asks what each one is worth on *this* phone, and answers on the phone itself.** Smart stopped following fixed rules and started measuring: what a situation costs, whether extra clock speed actually removes stutter, when the phone really wakes at night. The session log became an Infinite Log that survives reboots and turns a day into a review of causes, each with the side it belongs to. An optional Zygisk observer adds per-app evidence (cold starts, restart loops, launch classes) without installing a single hook.

> Battery life still depends on screen time, signal, apps, Bluetooth and temperature. V65 reports what it measured and on which phone. It names what userspace cannot fix, and it never turns a correlation into a battery percentage.

---

## V64 → V65 at a glance

| Area | V64 | V65 |
|---|---|---|
| asbdiag pass ratio, reference OnePlus 15 | 97% | **100%** (33 of 33 live checks) |
| WebUI tweaks (Config cards) | 63 | **89** |
| Config keys under the ownership registry | 177 | **218** |
| Smart | thermal and load rules, per-bucket history | **measured power records, side-by-side headroom tests, learned night wakes** |
| Session capture | fixed-length log | **Infinite Log**: survives reboots and framework restarts, progress heartbeat |
| Day report | list of sections | **verdicts, causes with their owner, at most three priority actions** |
| Zygisk | — | **optional observer**: dormant hot path, cold-start lift, start ledger, exit tracking |
| `versionCode` | 640 | **65339**, monotonic (`major × 1000 + build`) |
| Host regression | separate scripts | **317 cases in 6 suites**, sharded CI |

### Measured on the reference phone

One Infinite Log capture of this build on a OnePlus 15 (Smart, 13 h 18 min off the charger). These are observations of one day, not a comparison with V64:

| Measurement | Value |
|---|---|
| Whole capture | 1.9%/h, screen on 3 h 23 min |
| Night | 0.6%/h over 9 h, 91% deep sleep |
| Smoothness | 2.4% late frames out of 407 377 |
| ASB governor's own cost | 1.6 s CPU per hour: 0.04% of one core, 3.4 ms per wakeup |
| Zygisk companion | 184 ms of CPU in about 13 h; 145 allowlisted starts: 120 watched to their exit, 25 merged by the rate limit, none untracked |

---

## Smart: learning from this phone

- **Records instead of nudges.** Smart used to move a bucket toward economy after a hot or drainy session and never checked whether the new setting was cheaper. It now measures the energy of each situation as charge counter × battery voltage over the block, not in 1% battery steps. It then keeps trying to beat its best setting. Weather and the charger are no longer credited to a setting.
- **Thresholds from this device.** The warm and cool points come from the phone's own history. Heat that lasts is learned, one-tick spikes are not. An isolated hot reading on one sensor is deferred once, while a repeated reading or heat its peers share is accepted at once.
- **Stutter fixed only where clocks help.** Smart reads Android's frame statistics per app and tests extra headroom side by side, with plateau and cooldown rules. It keeps the extra headroom only when it removed late frames. On the reference phone it found three apps where it did not, and left them alone.
- **Night wakes are learned**, and a busy-idling phone with an idle screen gets relaxed ceilings.
- **Live evidence, not claims.** Every decision is shown as a count (kept, rejected, still testing), never as a saving.

## Battery profile: smooth where you look, lean where you don't

- **The interaction lift hears the tap and the lock press** on ColorOS 17 / Android 17. It lasts through a continuous scroll, reaches the lifted prime cores, and covers launcher and SystemUI work as well as the app.
- **A Battery lift also releases the light-idle GPU step** for its duration, so a swipe is never drawn at the lowest GPU level.
- **Wakes and app switches stop janking** on Battery and Balanced. Profile ceilings apply the moment you switch, and app launches are no longer capped harder than ordinary use.
- **Per-app scroll hold** keeps the lift only for apps whose frames showed they need it.

## Zygisk observer (optional)

An opt-in module part with no JNI or PLT hooks. Apps that are not selected pass through a dormant path that only records the start. Everything it reports is evidence, never proof of control.

- **Process start and exit for the allowlisted apps**, checked against peer credentials and process start ticks. Exits are watched through a process fd by one companion thread that waits without a timer. On the reference phone, of 145 allowlisted starts, 120 were watched to their exit, 25 were merged by the rate limit and none went untracked.
- **Cold-start lift.** A top-app process start feeds the existing unlock lift. The lift is shaped by **per-app launch classes** measured from the phone's own cold starts.
- **Restart-loop guard on the start ledger.** It catches screen-off restart loops, night wakers and apps that start in the background but are never opened. Each restriction is the same "Restricted" setting Android offers, with the previous mode recorded, read back and restored.
- **Compilation of the apps you actually open**, on the charger only, with cold-start medians before and after.
- **One-tap automatic setup**, a dedicated page, and the same evidence in asbdiag and the day report.

## Infinite Log and the day report

- **One log, any length.** It survives reboots and Android framework restarts, resumes the same capture, and stops from its own menu.
- **Honest progress.** A heartbeat names the current stage, and every slow collector has a time limit. A stalled capture is reported as stalled, not as a quiet day.
- **A day review, not a dump.** Every area gets a verdict only above its own evidence threshold. Causes say whose side they are on (the app, the ROM, your settings or ASB), and at most three priority actions come first. Facts and hypotheses are kept apart.
- **What the report now explains:**
  - which app moved the mobile data;
  - why Bluetooth dropped;
  - who held the phone awake and which alarm woke it;
  - SystemUI restarts with their stack or the settings write that caused them;
  - why frames were late, from Android's own per-frame GPU and UI-thread times;
  - drain across several off-charger windows;
  - the night in detail, the refresh rates used, Smart's live state and ASB's own cost.
- **Pages save as text**, so a report can be sent as it was seen.

## Diagnostics

- **asbdiag separates your choices from what is live and from what Android refused.** A setting the ROM rejects is reported as refused, not as a failed install. Framework restarts, app crashes, hook-framework inventory and the Zygisk verdict all have their own sections.
- **A false FAIL is gone.** The throttle-point check no longer fails while the report itself is loading the CPU with the screen on.
- **Device page** in reading order (Hardware, Kernel, Firmware, Root, ASB), each line backed by what was read.

## Network

- **5G only when needed.** With the screen on, a slow link (under 4 Mbit/s for 3 minutes) drops the 5G leg and gets it back as soon as traffic rises. Downloads keep 5G.
- **Screen-off LTE only when data is moving.** An idle phone already sits on the LTE anchor, so switching there saved nothing. 5G no longer flaps, and the LTE switches work on every profile.
- **Leaving bad Wi-Fi works on every rung.** Route windows are VPN-safe and handed back exactly, and TCP MTU recovery is available as an opt-in.

## Night, charging and background

- **Night Charge Limit** (opt-in). While charging inside a window (22:00–06:00 or any custom `HH:MM` pair), the standard charge-control node holds the charge at 80%. ASB hands back only a value it still owns; an external change wins.
- **Doze keep-list editor** with search; kept apps stay kept.
- **Reversible wakelock limits for user apps**, for the chosen package only. Kernel and system wake sources are never touched.
- **Notification fix per app**, plus independent push-service and file-picker repairs.
- **A dead governor is restarted**, and two background jobs that did nothing were removed.

## Audio, camera and display

- **DSP:**
  - an Outputs **off** position that keeps every slider;
  - Stereo Width, Clarity and a Sub-bass filter;
  - Media Volume Steps as a slider, and resampler quality;
  - the Bluetooth route from the first second on AudioReach phones;
  - a gain that no longer sinks when the volume changes.
- **Camera:**
  - stronger tone grading and grain that is actually delivered;
  - the camera is no longer taken for a game;
  - camera processes are found by event instead of polling.
- **Display:** ASB coexists with another module's refresh-rate table instead of stacking over it, and gives back the exact original range. The LTPO video drop reports how often it engaged.

## Interface

- **Liquid Glass** in dark and light, and a redesigned Monitor whose colours describe activity, never a grade.
- **A Settings hub of six categories**, drill-in pages with docks, page fades and a back gesture inside the WebUI.
- **Faster startup** and page switches that no longer wait for root shells.
- **All 13 languages audited** for meaning, not only for missing keys.

## Correctness (selection)

- Battery-profile sessions leaked into Smart's learning. HEAVY fired at light use, and SUSTAINED ping-ponged.
- An always-on display was counted as a screen that was on.
- MediaTek OnePlus phones got no temperature or GPU load.
- The governor had stopped reading some settings.
- Device bounds now fail closed when a fingerprint does not match.
- Uninstall hands everything back from early boot.
- The Zygisk observer had seen no allowlisted process in the field: the start and exit depended on a socket the loader never let the app keep.

## Packaging and engineering

- **Monotonic `versionCode`** (`major × 1000 + build`), so any two builds order correctly. Release and sequential test channels share one payload.
- **317 host regression cases in 6 suites**, sharded in CI and run as a non-root user. New cases are checked to fail on the code they guard.
- The governor builds with **zero warnings** under gcc and clang, and the Zygisk library is compiled and exercised with real child processes on the host. A tree manifest proves that every delivered file arrived unchanged.
- Build metadata never gates a build, and `update.json` never ships inside a flashable zip.

## Honest limits

- **No tweak is credited with a battery percentage.** The report shows correlations and says so; only a paired A/B capture shows a net effect.
- **Zygisk evidence is not control.** Exit tracking needs Linux 5.3 or newer (`pidfd_open`); an older kernel counts such starts as untracked.
- **The ROM can override ASB's caps.** On stock kernels the vendor power HAL often holds the prime cluster itself. ASB reports this and does not fight it.
- **SystemUI customization tools restart SystemUI** when they apply options. ASB can name the restart, not prevent it.
- **Late frames depend on the refresh rate.** At 165 Hz a frame lasts 6.1 ms, so compare captures only at the same rate.
- **Radio remains the dominant cost** on a busy day, and the night modem gate cannot reach every modem wake source.
- **Field validation** comes from the reference OnePlus 15 and testers' captures on V65 test builds. Other phones may show different numbers.

Build-by-build notes of the V65 line: [`docs/V65_BUILD_HISTORY.md`](docs/V65_BUILD_HISTORY.md).

---

# AutoSystemBoost — V64 Release Notes (previous release)

> **V63 made the module tidier. V64 asked whether the tweaks reach the system at all.** The answer was unpleasant: several subsystems had been writing correct files to paths nothing reads, and whole installer sections were skipped in silence. Most of this release is repairing delivery — then using the freed confidence to cut real power draw with measurements instead of intuition.

> Battery results still depend on display time, signal quality, applications, Bluetooth route and ambient temperature. V64 reports what it measured on the reference device and names what it cannot fix.


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
