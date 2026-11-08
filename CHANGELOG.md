# AutoSystemBoost — V65 Release Notes

<p align="center">
  <img src="https://img.shields.io/badge/Release-V65-16a34a?style=for-the-badge" alt="Release V65">
  <img src="https://img.shields.io/badge/Previous-V64-6b7280?style=for-the-badge" alt="Previous V64">
  <img src="https://img.shields.io/badge/versionCode-65339-0ea5e9?style=for-the-badge" alt="versionCode 650">
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
