# AutoSystemBoost — V65 build history

Build-by-build notes of the V65 line, newest first. The release summary is in [`CHANGELOG.md`](../CHANGELOG.md).

## V65 field-fix series (129-fix25 … fix339)

Test builds share the V65 base; since fix213 the `versionCode` is **monotonic** -
`major*1000 + fix number` (65339 for this build) - so a manager can order any two builds.
The OTA manifest agreement is enforced where it belongs since fix215: the release
pipeline that publishes it - never the build. Both CI workflows are pinned to exclude
`update.json` from the flashable zips - the manifest is
an OTA file, it can never interfere with a build. From fix235 the only build channels are
release and sequentially named `test1`, `test2`, … packages. Both channels stage the same
payload and native diagnostics; the separate debug flavor and prerelease/rc input are gone.

**fix339 — monotonic Infinite Log progress, stalled-capture honesty and bounded collectors**

- Infinite Log now publishes an atomic monotonic `recorder_heartbeat.env` from its existing loop: recorder PID, boot identity, tick, poll interval, current stage and timestamps. Stages cover sampling, phase/ledger work, reports, snapshots and individual `dumpsys` services; a wake-boundary heartbeat follows normal sleep without granting an unlimited suspend exception. No persistent polling worker was added.
- `dumpsys` collection is bounded by a 12-second default timeout (configurable only within 1–120 seconds), using Android/toybox `timeout` or a short-lived shell watchdog fallback. Timeout gaps are journaled in a 200-row `collector_events.tsv`; the failed sample stays absent rather than being replaced with reused or invented data, and all raw traces remain intact.
- The digest separates process ownership from actual progress. A live PID with a missing, malformed, wrong-PID, wrong-boot or expired heartbeat is `unknown`/`stale`, never a fresh green `running=1`; a `recorder` row reports state, age, stage, tick and collector timeouts. Live stalled captures do not enter finished history, while an independently fresh tombstone remains visible beside historical measurements. Reboot/resume can return to fresh progress, and a later stall is detected again.
- The WebUI report and log menu expose stale/unknown progress in all 13 locales, retain Stop, downgrade capture quality and turn every current analytical verdict into `unknown` with its previous state preserved as `historical_state`. Machine export includes recorder freshness and timeout evidence. The fix338 multi-window drain method and its `dm=3` history semantics remain unchanged.
- Regression covers live PID without progress, missing/malformed heartbeat, reboot/resume followed by a stall, fresh crashes mixed with stale measurements, real status-CLI `running/stale/unknown` responses, repeated Start, bounded collectors with and without `timeout`, and bounded event history. All 316 canonical host cases pass in the working tree and a clean source-ZIP extraction, including schema sync, lint, native warning and source-only DSP gates. Chromium verification passed 43 rendered states: all 13 locales in fresh/stale/unknown modes plus four viewport/RTL/injection fixtures, with exact warnings, historical verdicts, fresh-crash visibility, Stop priority, machine export, no horizontal overflow, no page errors and text-only device/stage insertion.
- **Release pass: the CI failure, Zygisk exit tracking, a cheaper heartbeat and two flaky tests.**
  - The CI failure of this build was a test fixture, not the recorder. `webui_log_report_runtime` built its "stale" heartbeat as the host's `/proc/uptime` minus ten minutes. A freshly booted CI runner had been up for less than that, so the stamp went negative and the digest correctly read it as malformed (`unknown`), while the test expected `stale`. A long-running workstation passed. The fixture now uses a fixed uptime file, and the recorder logic is unchanged.
  - Allowlisted Zygisk apps were never observed in the field. Both supplied devices reported `events_total=0` and `loaded_processes=0`, even though one-shot spawn, cold-start and ledger records arrived. That included a device where only 1 of 869 starts carried the root manager's unmount flag, so the fix287 explanation (that flag) was incomplete. Start and exit both depended on the app keeping its companion socket (`exemptFd()` plus a START frame after specialization), and that path never delivered.
  - The SPAWN frame now carries an `OBSERVE` flag. The companion records the start from that frame after the same peer-credential and start-ticks checks, then watches the exit through a process fd (`pidfd_open`, Linux 5.3+). One companion thread waits in `poll()` without a timeout on at most 64 such fds plus an eventfd, so nothing runs between app starts and exits. Where the loader does let the app keep the socket, the later START only confirms it, and an exit seen by both the socket and the fd is counted once. On a kernel without `pidfd_open` the start is counted as `observe_untracked`, and the earlier socket-only behaviour stays in place.
  - The companion state adds seven counters: `observe_requested`, `observe_retained`, `observe_pidfd`, `observe_untracked`, `observe_watching`, `exits_pidfd` and `exits_peer`. Device diagnostics label them in all 13 locales, and `asbdiag` prints them on a `tracking` line. A companion built before this change reads as `unknown`, not as zero. With lifecycle hints enabled, allowlisted starts and exits can now reach the governor as `zygisk-refresh`, within the existing budget: at least 2 seconds apart, at most 8 per minute, screen on only. No new opcode, cap or policy path was added.
  - The heartbeat cost was reduced. Each stage used to launch seven programs: `tr`, `cut`, `cat`, `tr`, `date`, `awk` and `mv`. Every poll publishes at least eight stages, and every `dumpsys` call adds one more. The boot identity is now read once per recorder, the uptime is read with a shell builtin, and constant stage and service names skip the `tr`/`cut` pipeline. That leaves two launches per stage: `date` and the atomic `mv`. The heartbeat content and its freshness rules are unchanged. No battery figure is claimed for this.
  - `dumpsys` was re-checked: Android's own `dumpsys` already ends each service dump after 10 seconds. The 12-second outer bound therefore only catches a hung binary or a blocked service lookup, and it does not truncate dumps that used to complete.
  - Regression for the native host harness now drives real child processes:
    - an app whose socket is gone after SPAWN is recorded, and its exit is seen through the fd;
    - an app that kept its socket is confirmed, and its exit is counted once;
    - a rate-limited start opens no watch;
    - a refused `exemptFd()` unloads the library after sending the OBSERVE frame.

    The heartbeat test counts program launches per stage, and the diagnostics test pins summed per-ABI counters and the `unknown` state of an older companion.
  - Two host tests failed only under load or after another user's run. The Wi-Fi leave test read the log before the watcher had written its line, which comes right after `svc` returns; it now waits for that line within a bound. The thermal-zone fixture used a fixed `/tmp` directory; it now uses the run's own directory.
  - **Native rebuild required:** the Zygisk libraries (`zygisk/arm64-v8a.so`, `zygisk/armeabi-v7a.so`) change, and the governor does not. None of this has been confirmed on a device yet. The next capture's `tracking` line will show whether the process-fd path delivers there.
- **Release pass 2: field logs from this build and from earlier test builds on three more phones.**
  - The Zygisk exit tracking works in the field. On the reference OP15 the companion recorded 145 allowlisted starts: 120 watched through a process fd, 25 rate-limited, none untracked and none that kept the socket. 109 exits came through the fd, and the observer showed 11 live processes where the previous build had `events_total=0`.
  - The report called every screen-off pause shorter than two minutes a "Capture gap", which read as a recording failure next to the new stalled-capture checks. It is now "Short pause, screen off" in all 13 locales; the phase itself is unchanged.
  - A capture zipped while the recorder was still running has no `after.txt`, so the Governor side of the Zygisk card showed start-only counters. The digest now uses the newest hourly snapshot as the latest point, as it already did for Smart.
  - The temperature tile took the larger of CPU and surface minutes, while its own detail line and the heat card in "Causes" used CPU minutes only. An OP15 capture showed "2 h 8 min, needs attention" next to "CPU above 45 °C: 15 min" and a "normal" heat card. The tile now follows the card's CPU rule; surface minutes (mostly on the charger in that capture) appear in the detail and keep the tile from "good".
  - A panel that runs above 120 Hz for most of the screen time (an OP15 at 165 Hz for 99% of it) gets a line in the smoothness card: a 165 Hz frame lasts 6.1 ms, so late-frame shares compare only between captures at the same rate. A jank share over fewer than 2000 frames (LIGHT_IDLE 10.4% over 212 frames) is no longer flagged.
  - SystemUI restarts without a crash record are attributed when SystemUI settings were written from a shell just before. An SM8650 capture had 16 restarts, one window led by twenty such writes from a customization tool. The verdict names the first key and the count, the report says that ASB does not restart SystemUI, and no ASB code path does.
  - asbdiag failed "throttle point below live CPU sensor" on a healthy install whenever a core passed the automatic point under the load of the report itself (65 °C point, 71 °C core, pass ratio 93%). With the screen on this is now a note; a hot phone at rest (screen off) remains a FAIL, and a manual point remains a WARN.
  - A reboot during an atomic write left `*.tmp.<pid>` files in the capture (two in a six-reboot capture). The shutdown path removes its own temporaries, and a resumed capture removes those of the recorder that died.
  - Tests: one new runtime case (the asbdiag throttle point over fake thermal zones) plus extended cases for the digest, the report, the SystemUI verdict and the resume. Each was checked to fail on the previous code. 317 canonical host cases.
  - The release run failed before building: its update.json check ran ahead of packaging and stopped on a manifest that, correctly, still named the published V64. The manifest can only name an asset that exists, so it is edited after the release is published. The check now runs after the zip is built and attached, never fails the run, and prints the manifest for this build in the run summary.
  - No native change in this pass: the Zygisk libraries and the governor are the ones from the previous pass.
- **Deliberately not implemented or claimed:** the supplied field incident proves stopped data progress, not which operation originally blocked it; the new stage/timeout evidence is diagnostic, not proof that `dumpsys` was the root cause. No automatic kill/restart of a live stalled recorder, fabricated gap filling, persistent worker, app-specific camera policy, thermal/Safe-mode weakening, ART automation, unverified SoC writer or battery/performance percentage is included. Host and Chromium checks are not physical OnePlus 15, ColorOS WebView, charging or observer A/B validation; those remain field work.

**fix338 — truthful multi-charge drain reports and event-driven camera PID refresh**

- Infinite Log now segments the ledger into off-charger windows instead of presenting their summed consumption as one battery charge. `drain` retains the normalized whole-capture rate and honest `total_drop` sum, and adds `segments`, `latest_drop`, `latest_hours` and `latest_pctph`. The brief, mixed verdict and drain detail name the multiple-window scope and latest window in all 13 WebUI locales; a single-window or legacy digest keeps its previous concise wording. Raw continuous evidence is not cleared or shortened, and the full-charge estimate remains only a projection of the measured average pace.
- A phase not named `charging*` can nevertheless contain a charger connection and a positive battery-level gain. Those mixed rows no longer subtract charging gain from consumption or contribute charging-contaminated elapsed time to the off-charger average. A level increase between rows also starts a new window. History method `dm=3` prevents numeric day-drain comparison with values produced by the older method; other compatible trend metrics remain available.
- Camera provider tracking now notices when any PID in the measured set disappears, even if `cameraserver` survives. Outside an active hold, that event requests a fresh process scan so a restarted vendor provider is not omitted until the five-minute refresh. The existing five-second screen-on cooldown bounds repeated scans for unreadable/zero-jiffies members, the survivors remain usable until the bounded refresh, screen-off behavior and busy thresholds are unchanged, and no foreground-package rule or new polling worker was added.
- Regression first reproduced the old behavior with a synthetic 181% multi-charge ledger, a hidden in-phase charge gain, WebUI brief/verdict/history checks and a partial camera PID-set loss. The real extended camera-user capture then projected 20 off-charger windows with a separate latest window rather than a one-charge 113% statement. Chromium verification passed 52 multi-window report states across all 13 locales and four viewports with exact localized briefs, no horizontal overflow and no page errors. All 314 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates.
- **Deliberately not implemented or claimed:** the exact 181% screenshot capture was not supplied and is not claimed to be reproduced. The early-boot camera-provider/cameraserver tombstones and SystemUI PID restarts in the supplied test17 logs are not proof of an ASB-caused camera freeze or SystemUI crash. This source fix does not claim to cure that user's camera complaint, guarantee a camera-hold activation or improve energy/performance by a percentage. No app-specific camera boost, higher frequency ceiling, weaker thermal ownership, Safe-mode bypass, ART automation, unverified SoC writer, native-binary rebuild or physical ColorOS WebView/charging validation is included; the edited native source still requires the separate native release build and field confirmation.

**fix337 — aligned subsection docks and a non-scrolling six-category Config hub**

- The main and internal navigation bars already shared the same bottom offset: the visible mismatch came from the internal dock's 68 px minimum target height. Report, Zygisk, Device and Config subsection targets now use the same 60 px minimum height as the main bar, with compact vertical padding, a 28 px icon/indicator zone and an 11 px label line-height. Full adaptive labels, horizontal dock scrolling, the active indicator and scroll-spy remain intact.
- The six-tile Config hub no longer reserves 102 px for a subsection dock that only exists inside a category. A `config-category-active` state owned by the existing visibility logic applies that bottom reserve only to real categories; the hub uses zero extra bottom padding, while Device/Report overlays and closed Config cannot leave the state behind. The measured fitter still handles genuinely short screens instead of hiding overflow with `overflow:hidden`.
- Source/Node regression covers the aligned geometry, category-only reserve and hub/category/overlay/close transitions. Chromium verification passed 65 Config dock states across all 13 locales, all four shared dock families and six viewports: normal phone hubs have no vertical scroll, their main/internal dock heights match exactly, and no mid-word split, label/page overflow or page error was found. The 360×640 and 800×600 fixtures retain 7 px and 102 px of genuine content overflow respectively, with compact fitting tiers active and scrolling preserved. All 314 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates.
- **Deliberately not implemented or claimed:** no fixed header padding, device-specific coordinate correction, hidden-overflow concealment, persistent worker, Config evidence/writer change, translation rewrite, governor/Smart/Zygisk/thermal/profile/ART/night-charging algorithm change, native-binary rebuild or energy/performance claim. Browser/host verification is not physical ColorOS WebView validation; final proprietary-WebView rendering still requires field confirmation on the user's device.

**fix336 — stable Config hub geometry and word-boundary dock labels**

- Returning from a long Config category to the hub no longer carries that category's vertical scroll offset into the shorter screen. A shared `cfgShowGroup()` transition resets the page only when entering a category or returning to the hub, including the Zygisk → System settings path; same-screen evidence repaints preserve the user's reading position. This removes the clipped UFO/header state without adding a device-specific top offset.
- Report, Zygisk, Device and Config dock buttons now size between 104 and 176 px from their actual labels instead of forcing every label through a 104 px column. Labels prefer word boundaries, retain full text without ellipsis and keep the existing horizontal track, active indicator and scroll-spy. Chromium checks covered 65 Config dock states across all 13 locales, all four shared dock families, category/hub round-trips and same-screen repaint scroll preservation, with no mid-word split, label overflow, page overflow or page error.
- The screenshot's Russian `DSP-движок ASB` label was checked against the actual locale and is already spelled correctly; no translation was changed. Source/Node regression covers the shared transition and the new wrapping contract. All 313 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates.
- **Deliberately not implemented or claimed:** no fixed header padding, device-specific coordinate correction, persistent worker, Config evidence/writer change, translation rewrite, governor/Smart/Zygisk/thermal/profile/ART/night-charging algorithm change, native-binary rebuild or energy/performance claim. Browser/host verification is not physical ColorOS WebView validation; final proprietary-WebView rendering still requires field confirmation on the user's device.

**fix335 — unique semantic icons for every Device destination**

- Hardware no longer reuses the Kernel CPU-die glyph. Its new inline SVG depicts the phone/board with component blocks and circuit traces, while Kernel retains the chip. Firmware/system, Root/modules and ASB keep their existing panel, shield and switches; all five Device dock destinations now have distinct fixed-registry artwork with no external assets or emoji-font dependence.
- The existing Device source/runtime contract now checks the exact five-glyph assignment and rejects duplicates, alongside the unchanged safe renderer, section order and real jump targets. Chromium rendering confirms five visible unique SVGs, correct active styling, intact horizontal dock geometry and no page errors or horizontal overflow. All 312 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates.
- **Deliberately not implemented or claimed:** no Device evidence collector, section ordering, navigation action, governor/Smart/Zygisk/thermal/profile/ART/night-charging algorithm or native-binary change, no new asset download or persistent worker, and no energy/performance claim. Browser/host verification is not physical ColorOS WebView validation; final proprietary-WebView appearance still requires field confirmation.

**fix334 — drawn UFO identity, complete dock labels and a leaner repeat-open path**

- Replaced the boot microchip and all six header emoji with one reusable, detailed multicolor SVG saucer: shaded glass, metallic hull, glowing core and five colored running lights. The boot wordmark reuses the header's `asbSweep` animation. The ten-tap Easter egg now crossfades drawing → emoji on takeoff and emoji → drawing on landing, while preserving the existing measured flight path, body-zoom compensation, sound, visibility shortcut and overlay/header cleanup.
- Report, Device, Config and Zygisk drill-in docks now give subsection buttons a 104 px basis and wrap complete labels instead of forcing 72 px ellipsis. The horizontal track, active indicator and scroll-spy remain intact. Every Zygisk evidence note now receives a 12 px logical inline-start gutter, not only the Controls card.
- Ordinary repeat startup no longer runs the eager ten-part Config batch and its follow-up evidence reads. Config still loads on demand in `openConfigPage()`, and the once-per-boot preview retains its own Config load; the shared startup snapshot, Live polling and Zygisk header refresh are unchanged. A synchronous bridge fixture confirms removal of that repeat-path work, not a physical WebView latency percentage.
- Source/Node contracts cover the shared artwork, both morph directions, cleanup, universal note spacing, full-label CSS and repeat-start call scope. Chromium verification covers all four dock families with long Russian labels, real Network/Battery docks, all Zygisk note gutters, the boot/header artwork, free flight, a mid-landing crossfade and final cleanup without page errors. All 312 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates.
- **Deliberately not implemented or claimed:** no physical ColorOS WebView validation, measured device-side opening-time improvement or energy/performance percentage, new prefetch cache, persistent worker, Config behavior removal, governor/Smart/Zygisk/thermal/profile/ART/night-charging algorithm change, native-binary rebuild or sensitive identifier read. Browser/host evidence establishes the edited code paths and geometry only; perceived repeat-open latency and proprietary WebView rendering still require field confirmation.

**fix333 — deterministic night-window reads and a load-tolerant debug launch handshake**

- Night Charge Limit now reads its three configuration keys synchronously in the shell instead of depending on a grep/head/sed/tr pipeline for each value. The previous grammar is preserved: first exact key, optional leading whitespace, and spaces/CR removed from values. A transient external-process read failure therefore no longer silently selects the default 22:00–06:00 window. Custom-window validation, exact ownership, read-back and handback are unchanged; focused lifecycle checks plus 60 boundary-suite repetitions pass.
- The synchronous debug full-day launcher retains its atomic directory lock and fail-closed timeout, but its one-shot recorder-claim handshake now allows a bounded 10 seconds at 100 ms intervals instead of three 1-second attempts. A live recorder delayed by a loaded CI scheduler no longer produces a premature `starting` answer; no persistent worker or polling loop was added. The concurrency assertion remains exactly one `started` and one `already_running`, with full answers/log output on failure. Debug lifecycle checks and 12 complete concurrency-suite repetitions pass.
- All 311 canonical host cases pass in the working tree and a clean source-ZIP extraction, including lint, native warning and source-only DSP gates. No Smart, governor, thermal, Zygisk, ART, WebUI presentation or native-binary change is included in this CI repair.
- **Deliberately not implemented or claimed:** no physical charging or ColorOS WebView validation, exact boundary-minute charging promise, native-binary rebuild, persistent worker, weakened concurrency assertion or claim that host stress tests eliminate every possible CI/environment failure. The repair addresses the two failures present in the supplied GitHub Actions logs.

**fix332 — custom night-charge windows, honest Zygisk resets and quieter Glass navigation**

- Dark Liquid Glass navigation docks now have their own darker, less reflective material across the main tab bar, Report, Zygisk, Device and all six Settings categories. Header capsules, dock geometry and light Glass keep their previous paints. Opaque no-blur/reduced-transparency variants follow the same navigation-only scope, forced-colors behavior is unchanged, and the Zygisk Controls note regains a 12 px logical gutter after the more specific report-note padding reset.
- A Zygisk counter reset no longer leaves useful hero cards as unexplained dashes when latest absolute counters are available. The report shows those real latest totals with an explicit `current total · capture delta unknown` scope; affected capture deltas remain `unknown`, independent known deltas stay independent, and no reset is called an injection failure. Runtime injection, allowlists, companion policy and native binaries were not changed.
- Night Charge Limit accepts arbitrary `HH:MM` start/end values in same-day or overnight windows, with inclusive start and exclusive end. Both native time controls use the locked atomic config writer and immediately reconcile an active hold after a boundary edit. Equal or malformed endpoints fail closed and release an old ASB hold; a prior restore failure remains more visible than an invalid-window badge. Defaults stay off at 22:00–06:00, existing boot-scoped exact-value ownership, read-back, unplug/disable/uninstall handback and the existing service maintenance loop remain intact. Installer preservation/summaries, key ownership and all 13 common/WebUI locales cover the new settings.
- A parser-local critical canvas now paints dark or saved-light before the main stylesheet, locale and root bridge can settle, removing ASB's dependence on the WebView host's initial light-grey canvas. Existing non-blocking inset loading, shared startup snapshot, post-paint warm-up and once-per-boot bounded preview are unchanged. The full-day digest now attributes native crashes to ASB only from Cmdline or the crashing-thread backtrace, not from an ASB library appearing only in a memory map.
- The supplied Smart capture was reviewed separately: six tracked contexts continued native learning, one log hint was accepted and twelve were suppressed by existing plateau/cooldown gates, and three completed app comparisons ruled out extra frequency headroom. Active-use drain occurred with 91% screen-on time and substantial mobile traffic; these observations do not isolate ASB as the cause or justify higher Smart ceilings. Smart learning, profile bounds, thermal ownership and A/B logic therefore remain unchanged rather than receiving an unverified tuning claim. Focused host tests cover custom windows, restore priority, reset/latest rendering and backtrace-only crash attribution. Chromium checks cover all navigation materials, both time controls, the Zygisk gutter, reset totals and delayed-locale/bridge startup; these are not physical ColorOS WebView or charging tests.
- **Deliberately not implemented or claimed:** no Smart frequency/energy percentage improvement, app-specific policy, higher ceiling from non-equivalent jank samples, automatic recommendation executor, persistent polling worker, new daemon, unverified SoC-specific writer, native source/binary rebuild, Zygisk runtime behavior change, ART automation, safe-mode bypass, exact boundary-minute charging promise or guaranteed 100% by window end. Equal start/end is rejected rather than interpreted as a hidden 24-hour hold. Browser/host checks are not physical ColorOS WebView validation, physical charging confirmation or proof of Zygisk injection on the device; final perceived latency, proprietary rendering and kernel charging-node support still require field confirmation.

**fix331 — honest installer payload summary and unified drill-in navigation**

- Removed the rejected duplicate prepared-components checklist from the final installer banner while retaining the detailed Audio, Camera, Performance, GPS, Wi-Fi, System, Display, Haptics, Battery and Memory sections. A new ZYGISK OBSERVER section reports only non-empty arm64/arm32 libraries actually present in the package, distinguishes both/one/neither ABI states in all 13 common locales, and explicitly assigns runtime activation checking to the WebUI after reboot. Category selection, stable numeric menu IDs, application order, installed files and the installation mechanism are unchanged.
- Enlarged the six Settings category icons to 54 px containers with 30 px vector glyphs, with matching 46/26 and 40/23 compact tiers. The 3 × 2 grid, counters, actions, adaptive fitting and previous geometry fixes remain intact. Language, sound and reboot now use the same 40 × 40 px SVG control geometry with cyan, pink and green accents; the sound glyph and `aria-pressed` still follow the real setting. A final Glass-safe ink/edge cascade prevents the shared material from erasing those accents.
- Device now uses the same floating, portalled dock component as Report and Zygisk: only collected groups appear, every destination has an icon and a real target, rendered-order scroll-spy maintains one current location, and closing the page removes the dock/listener before restoring the main tab bar. All six tweak categories also receive subsection docks built only from sections that actually rendered: Audio 3, Camera 2, Interface 2, Network 4, Battery 5 and System 4. Their existing Back, search, cards and writers are unchanged.
- Real Chromium verification covers dark/light Glass at 412 px, the unchanged 3 × 2 hub, computed toolbar colours and equal geometry, sound on/off, every category jump, Device navigation and cleanup, compact horizontal dock geometry and a 360 px viewport without horizontal overflow. Browser inspection caught and fixed two issues that static checks alone missed: overridden toolbar accents and vertically expanded new docks. The existing LTE bulk test now waits boundedly for the required give-back log line after the state handback, removing a parallel host-fixture race without changing LTE runtime behavior or weakening the assertion. All 311 canonical host cases pass in the working tree and a clean source-ZIP extraction; lint, native warning and source-only DSP gates remain enabled.
- **Deliberately not implemented or claimed:** no runtime Zygisk activation claim from packaged or staged libraries, no native source/binary rebuild, no new router, worker, polling loop or shell writer, no Device data collection expansion, no sensitive identifier read, and no governor/Smart/Zygisk/thermal/profile/ART/night-charging algorithm change. No installation-mechanism change or energy/performance percentage is claimed. Chromium fixtures and host tests are not physical ColorOS WebView validation; packaged-library reporting is not a field probe of Zygisk loading.

**fix330 — optional ownership-aware night charging and presentation-only installer polish**

- The reported loss of OEM Adaptive Charging is retained as a field report, not declared an ASB regression without evidence. Existing `charge_aware_enable` remains a performance policy and is unchanged. A separate, default-off `night_charge_enable` option covers 22:00–06:00: while charging, a runtime-discovered standard `charge_control_limit` is set to 80, or a writable binary `charging_enabled` is used when no suitable limit exists. No vendor/OnePlus/SoC path is guessed.
- Every write is read back and its exact original value plus boot ID are recorded. Disable, the post-06:00 window exit, explicit unplug and uninstall hand back only a node still containing ASB's exact value; an external change yields ownership instead of being overwritten. Ledger/write failures roll back new writes, restore failures stay visible, stale boot ownership is not replayed, a battery above 80% is never artificially discharged, and the binary switch is not released merely because its own hold reports `Not charging`.
- The WebUI card applies immediately through the safe config writer and reports actual `waiting`, `holding`, `released`, `not_exposed`, `write_failed`, `restore_failed`, `external_change` or `unknown` states rather than generic success. Its card, Charging subsection, badges and toasts are localized in all 13 WebUI languages. Boot apply and recurring ticks share the existing service maintenance loop (about 120 seconds screen-on and 600 seconds screen-off); no new daemon or persistent polling worker exists, so exact boundary-minute application is not promised.
- Installer presentation gains 15 numbered icon menu entries, 19 understandable category labels, a logically grouped selected-only component summary and an optional night-charge note in all 13 common locales. Numeric IDs, category flags, selection, application order, file installation and the installation mechanism are unchanged.
- The configuration writer, atomic snapshot, legacy migration, both sysfs strategies, midnight/boundary transitions, capacity/unplug cases, rollback, external ownership, restore failure, uninstall, WebUI apply and installer rendering have focused host coverage. All 310 canonical host cases pass in the working tree and a clean source-ZIP extraction; lint reports no errors or warnings, and native warning/DSP gates remain enabled.
- **Deliberately not implemented or claimed:** no proof that ASB caused the OEM Adaptive Charging report, no modification or replacement of that OEM setting, no OnePlus 15 interface/support claim without a field probe, no unverified vendor writer, exact 100%-by-06:00 guarantee, forced discharge, new daemon, native source/binary change, ART/profile/governor/Smart/Zygisk/thermal algorithm change, installation-mechanism change or invented energy/performance percentage. Host fixtures are not physical charging tests or physical ColorOS WebView validation; release after 06:00 permits charging to continue, while charger speed, temperature and ROM policy still determine when 100% is reached.

**fix329 — Monitor-matched Home reveal and a centred Settings category composition**

- Home now stays in a head-level pending state while local static localization and the fixed-width ZYGISK header control are prepared, preventing a visible English-to-localized label swap and late badge-driven header growth. Device JSON loading and the shared root snapshot still start immediately and in parallel; the ordinary reveal does not wait for root evidence, and the accepted black dark-Glass canvas, fix327 cascade and fix325 collector deduplication remain unchanged.
- The ordinary Home entrance uses the same 260 ms fade, 60 ms delay, easing and 0.985-to-1 scale as Monitor. Final unscaled page geometry is fitted before the compositor animation begins, so subsequent profile evidence does not resize the profile cards or header. Reduced motion skips WAAPI, while the `load` handler and bounded fail-safe guarantee an eventual reveal. Profile and Smart values retain honest subdued pending indicators with `aria-busy` until real evidence resolves them; no selection or activity state is invented.
- All six Settings category tiles now centre the icon, vector glyph, title, description and counter on one common axis. Their real open actions, active/total counts, full-width activity tracks, accessible names, compact tiers and 3 × 2 layout are preserved; no locale strings were changed in this revision.
- Real Chromium verification covers a delayed-profile cold open, localized first visible UI, ZYGISK presence at reveal, Monitor-matched animation timing, unchanged post-entrance geometry when profile evidence arrives, all six category navigation round-trips, four theme combinations, actual switching of all 13 locales including RTL, and a 360×640 viewport without clipping, overflow or page errors. All 305 canonical host cases pass in the working tree, including the native warning budget and source-only DSP gates.
- **Deliberately not implemented or claimed:** no root collector was added to the reveal path, no arbitrary presentation delay replaced the existing bounded fail-safe, no cached or pending profile/Smart value is promoted to fresh evidence, and no persistent worker, hardware/account/network identifier read, layout offset specific to one device, governor/Smart/Zygisk/thermal/profile/ART algorithm change, native-binary rebuild or energy/performance percentage was introduced. Chromium and host checks are not physical ColorOS WebView validation; perceived opening quality still requires confirmation on the user's device.

**fix328 — stable neutral Home startup and a coherent Settings category hub**

- Home no longer ships with a provisional Balanced selection, Smart activity claim or placeholder device identity. The first frame is neutral until the shared startup snapshot supplies real evidence; Stock is not preselected. A valid seven-day local header cache can synchronously repaint only the non-sensitive model, SoC and chip display fields on repeat openings, followed immediately by the ordinary local `device_info.json` refresh. Cached values are not presented as fresh live evidence.
- Local device-header loading starts before the awaited root snapshot, early page fitting runs on the already complete DOM, and bounded Config/ZYGISK warm-up no longer waits behind the external manager stylesheet's final `load` event. Static Home entrance transforms that moved the whole profile group after the first fit are removed. The fix326 final-viewport recalibration, fix327 non-blocking inset cascade and fix325 collector deduplication remain intact.
- The six Settings categories retain their real actions, active/total counts and 3 × 2 layout, but now share one start-aware component: centred 24 px vector icons in aligned 42 px containers, consistent title/description typography, unclipped three-line descriptions and full-width activity tracks. Accessible names include category scope and counts; decorative tracks are hidden from accessibility APIs. More specific descriptions are supplied in all 13 locales, and the accepted genuinely black dark-Glass canvas is unchanged.
- Real Chromium verification covers the interactive first frame and settled Home geometry, cached-to-fresh header replacement, all six category navigation round-trips, four dark/light/Glass combinations, actual switching of all 13 locales, long descriptions, RTL-aware alignment and a 360×640 viewport without horizontal overflow, clipping or page errors. All 304 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no cached profile/Smart/ZYGISK/live metric is promoted to current evidence, no serial number, IMEI, account or network identifier is read or cached, and no arbitrary startup delay, persistent worker, blocking shell addition or device-specific layout offset was introduced. No governor/Smart/Zygisk/thermal/profile/ART algorithm, native binary or energy/performance percentage changed. Browser/host verification is not physical ColorOS WebView validation; perceived latency and proprietary rendering still require field confirmation on the user's device.

**fix327 — non-blocking insets with the original cascade and page geometry**

- Fixed the remaining field regression that fix326's viewport recalibration did not address. Appending the manager's `insets.css` after the main stylesheet changed the cascade: its custom properties could override ASB's native safe-area fallbacks after loading and move the header plus content of every page downward. The stylesheet is now installed before the main style, preserving the old leading-`@import` precedence, while `media="print"` keeps its fetch non-render-blocking and its load handler only promotes the already ordered rule set.
- Added source/runtime contracts for immediate head installation, non-blocking initial media, load promotion and the authoritative later local `env(safe-area-inset-*)` rules. The fix326 final-viewport recalibration remains in place, but no new timer or fixed vertical offset was introduced.
- A delayed Chromium manager-stylesheet fixture reproduced fix326's 48 px external top inset and approximately 45 CSS px downward header shift on Home, Monitor, Settings, Report, Device and ZYGISK. With the same fixture fix327 restores the local inset and fix324 geometry while retaining fix326's startup request counts in ordinary and first-boot scenarios. All 303 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no hard-coded OnePlus-specific offset or zoom, removed manager stylesheet, restored render-blocking import, double safe-area compensation, layout redesign, governor/Smart/Zygisk/thermal/profile/ART algorithm change, persistent worker, native-binary rebuild or performance/energy percentage. The delayed host stylesheet is a controlled regression fixture, not a claim about current manager-server availability or physical ColorOS WebView validation; field confirmation on the user's device is still required.

**fix326 — final-viewport WebUI scale correction**

- Fixed the scale regression exposed by fix325's non-blocking inset stylesheet: the main script can now run while a WebView still reports a provisional width, and the early `--asb-ui-scale` value could remain frozen. The ordinary `load` handler re-reads the final viewport before page fitting, device-font setup and cache warming; resize/orientation handling and the non-blocking first-paint path remain intact.
- Added a real source/runtime contract that reproduces an early 980 px reading followed by a final 411 px viewport. The corrected scale is 0.93, the scaled-body state and diagnostic reading are updated, stale navigation geometry is cleared, and page fitting observes the new scale rather than the provisional one. A later 500 px viewport returns to unscaled rendering.
- Chromium verification with a 412 px final mobile viewport reproduces fix325's frozen `980px@1` state and fix326's corrected `412px@0.94` state, including the resulting tab-bar geometry. Ordinary and first-boot cold starts still perform 6 bridge calls each; Monitor, Settings, Device, honest no-capture Report and ZYGISK navigation checks still pass. All 302 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no fixed device-specific zoom, viewport-meta rewrite, restored render-blocking CSS import, layout redesign, governor/Smart/Zygisk/thermal/profile/ART algorithm change, persistent worker, native-binary rebuild or performance/energy percentage. Host Chromium geometry and request counts are not physical ColorOS WebView validation; the screenshot-reported field regression still requires confirmation on the user's device.

**fix325 — lower-latency WebUI startup and page collection**

- Replaced the separate cold-start profile, governor-state, Smart-pending and random boot-id shells with one shared `runBatch` snapshot. Home profile selection, the Smart subtitle and the once-per-boot preview consume the same Promise; post-switch Smart refreshes still read current state, but state and pending evidence now share one shell.
- Removed the arbitrary 250 ms ordinary-Live start delay, the duplicate forced Home-meter read at 1.8 seconds and the independent 2.5/4-second ZYGISK/Settings warm-up timers. After the first painted frame an ordinary opening starts the existing bounded Config and ZYGISK warmers; when the boot preview is shown, its own collectors remain the only warmers. No work is added to a hidden page and no persistent worker exists.
- Live collection is now visibility-aware and deduplicated: background/background and visible/visible overlaps share the active pass, while a visible Monitor opening during a background Home prime gets exactly one fresh visible follow-up. Stock background collection is covered by the same lifetime gate. The initial Live batch paints the Home meter directly instead of launching a second meter shell.
- Device opens its cached/loading state immediately; the existing `asbPaintYield()` still keeps the blocking collector behind a painted frame. KernelSU's optional external `insets.css` no longer blocks the head script or first paint through a CSS `@import`: native safe-area `env()` fallbacks apply at once and the manager stylesheet loads after the ordinary `load` event.
- Added executable source/runtime contracts for snapshot reuse, Smart pending/active semantics, ordinary versus intro warm-up, hidden-page behavior, Live overlap/follow-up/reset and Device navigation. Real Chromium checks cover ordinary and first-boot cold starts plus completed Monitor, Settings, Device, honest no-capture Report and ZYGISK openings. In the bounded host bridge fixture both cold-start scenarios fell from 10 to 6 bridge calls; this is a request-count observation, not a claimed on-device timing or energy percentage. All 301 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no persistent Config snapshot is presented as fresh, no stale cache is promoted to current evidence, no governor/Smart/Zygisk/thermal/profile/ART algorithm changed, and no new daemon, polling worker, native-binary rebuild, unverified SoC writer or battery/performance percentage was added. Browser/host measurements are not physical ColorOS WebView validation; actual device latency still depends on the manager bridge, storage and collector execution, and the external manager inset stylesheet may remain unavailable without affecting the safe-area fallbacks.

**fix324 — genuinely black dark Glass and a once-per-boot metric warm-up preview**

- Removed the screen-sized green ambient wash rejected on the reference phone. Dark Liquid Glass now uses a genuinely black root/body/report/Device/ZYGISK canvas and a black status scrim; the established light-Glass gradients, card materials, profile accents and navigation geometry remain unchanged.
- Added a localized hi-tech ASB boot preview with compositor-only orbit/core/scan animation, a real progress bar and four collector groups. It appears only on the first WebUI opening associated with a new `/proc/sys/kernel/random/boot_id`; the marker is written before collection starts, so reloading or reopening during the same boot cannot replay it. An unreadable boot id skips the preview rather than showing it on every ordinary opening.
- The preview runs the existing bounded Live, Settings, Device and ZYGISK loaders, including the full Monitor prime, Home meter paint, Settings batch, read-only Device cache and ZYGISK link snapshot. Device collection gained a background cache-only path that neither paints nor clears a closed page. Progress counts settled collector attempts, never invents successful readings; failures retain each collector's existing honest unknown/error state.
- The ordinary cold Live read is coordinated with warm-up to avoid a duplicate governor/ROM batch. The preview has a 3.2-second minimum presentation and a 9-second collection cap with unconditional interface cleanup. Reduced motion disables the animation, forced colors supplies system paints, and all 13 locales include the new status strings. No persistent worker was added.
- Browser verification covers the first/new/repeated boot cycle, black dark and unchanged light Glass, eight viewport/theme combinations, popup geometry, Report/ZYGISK docks, reduced motion and forced colors. All 300 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no repeating intro within one boot, fake metric success, automatic profile change, governor/Smart/Zygisk behavior change, new background daemon, persistent polling, log-digest generation, on-demand LSPosed hook-evidence collection, safe-mode bypass, native-binary rebuild or battery/performance percentage. Browser and host checks are not physical ColorOS WebView validation; the preview does not claim that every read succeeded or that every future page is instantaneous.

**fix323 — visible Glass canvas, unified drill-in docks and compact restart actions**

- Moved the Glass ambient canvas to the full-height root and made the fixed primary pages transparent, so dark and light palettes remain visible behind Home, Config, Report and ZYGISK instead of collapsing to the short body height. Report and ZYGISK navigation now share the floating dock material: their parent owns the background, blur and shadow, while inactive child buttons stay transparent.
- Replaced the oversized grey active-profile marker with a compact 22 px accent check. The six Settings category tiles retain the 3 × 2 layout but use the height freed by removing the three separate restart cards; compact tiers, adaptive fitting and existing category actions remain intact.
- Added a third circular Settings toolbar control beside language and sound. Its small three-item menu delegates only to the existing full reboot, guarded quick restart and SystemUI restart functions. Full and quick reboot retain independent four-second two-tap confirmations and capability checks; no new shell command path, polling worker or reboot backend was introduced.
- The restart popup is portalled above the Config overlay, converts viewport coordinates back through the global UI zoom, supports Arrow/Home/End/Escape and focus return, closes on outside tap/resize and mutually closes the language popup. Opaque no-blur, reduced-transparency and forced-colors fallbacks cover the new control.
- Browser verification covers eight Glass viewport/theme combinations from 360×800 through 1024×768, ordinary dark/light restart actions, popup geometry, keyboard/focus behavior and accessibility fallbacks. All 299 canonical host cases pass in the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** no governor, Smart, Zygisk, thermal or energy algorithm change; no automatic reboot, new persistent worker, safe-mode bypass, unverified SoC-specific writer, native-binary rebuild or battery/performance percentage. Chromium and host fixtures are not physical ColorOS 17 WebView validation, and exact proprietary ColorOS rendering is not claimed.

**fix322 — coherent ColorOS-style Liquid Glass materials**

- Audited the existing Glass cascade and the rendered Home, Monitor, Config, Infinite Log report, Device, ZYGISK, menu and dialog states in dark and light palettes. The former nearly opaque fills, repeated nested materials and accent-colored popup rims made the blur difficult to read and the material hierarchy inconsistent.
- Added a final paint-only material cascade with a lit canvas, translucent content cards, denser floating navigation/dialogs, neutral glass rims, restrained profile/category tints and quiet inset controls. Report evidence and loading states no longer need competing nested blur/shadow layers; header, logo and dock geometry are deliberately unchanged.
- Added opaque no-blur and reduced-transparency paints plus forced-colors rules. Light-Glass tertiary text was darkened after a real luminance check found its fallback contrast below 4.5:1. Existing keyboard focus, reduced motion, safe-area behavior, navigation and all profile/Smart/evidence semantics remain intact.
- Browser verification covers 24 theme/page/viewport combinations from 360×800 through 1024×768, active and pressed profiles, keyboard focus, dialogs, log menu and a real dynamically rendered light report. The focused source regression protects the material families, neutral floating chrome, quiet nesting, accessibility fallbacks, contrast and the no-geometry-change contract.
- **Deliberately not implemented or claimed:** no header/dock redesign, navigation geometry rewrite, governor or Zygisk behavior change, new polling, device-specific writer, or claim of battery/performance improvement. Chromium screenshots and host tests are not physical ColorOS 17 WebView validation; pixel-identical reproduction of a proprietary ColorOS component is not claimed, and native prebuilts are not represented as rebuilt in this source archive.

**fix321 — measured Zygisk launch classes and explicit Smart live evidence**

- Reviewed the supplied nine-hour Battery capture and the actual Zygisk/LSPosed/Smart paths. Its Smart smoothness records are stored governor-session history: `profile=battery`, `smart_mode=0` and all Infinite-Log feedback counters stayed at zero, so this capture does not demonstrate live Smart adaptation or justify changing Battery into Smart.
- A hooked application no longer receives the long cold-start class after one slow launch. LSPosed scope remains context, not causal evidence; the ordinary bounded lift remains, while `slow`/`fast` now require the same measured median (normally three valid cold starts) for hooked and unhooked applications. After the evidence threshold, the existing long/short behavior is unchanged.
- The full-day digest adds `smartlive`: running captures alone read the live governor state, saved captures use their own end/latest/start snapshots, and native feedback deltas require monotonic start/latest counters. `active`, `adapting`, `manual`, `disabled` and `unknown` are distinguished; resets and single snapshots never manufacture an in-capture delta.
- The localized WebUI report now separates real-time Infinite Log → Smart hints from stored Smart records, exposes accepted/suppressed/rejected capture deltas where available, and states that native GraphicsStats/A/B/plateau/cooldown ownership remains with the governor. All 13 locales are covered; dynamic values continue through `textContent` row APIs.
- **Deliberately not implemented or claimed:** no hidden LSPosed kill/freeze/throttle/scope change, per-hook energy attribution, automatic recommendation executor, second governor, persistent polling worker, Smart behavior on Battery, safe-mode bypass, static CPU/GPU raise from non-equivalent jank correlations, or unverified SoC-specific writer. `lsposed_verbose=keep/off` remains the explicit LSPosed logging control. Host fixtures are not on-device validation; no battery or performance percentage is claimed, and native prebuilts are not represented as rebuilt in this source archive.

**fix320 — truthful apply summaries, bounded multicast ownership and explicit DSP evidence**
- The Action summary no longer prints an unconditional all-OK beside asbdiag's `REFUSED=1`. It reads the latest result for every domain/key in the apply ledger, ignores reconcile-only rows, recovers cleanly after a later successful write and names up to three still-refused Android settings. The warning is localized in all twelve Action locale files; English defaults remain intact.
- The audio-route probe in both synchronized asbdiag copies no longer passes an entire `dumpsys audio` capture as one external `printf` argument. A host regression feeds the real parser more than 256 KiB and verifies the STREAM_MUSIC route, covering the field error `printf: Argument list too long` without reducing diagnostic coverage.
- Automatic multicast AppOps now use a versioned `package|first_seen|last_seen|original_mode` ledger. Existing watcher passes release foreground/visible/FGS apps and expire entries after twenty minutes without a qualifying current observation; a still-observed aged entry refreshes without a restore/restrict flap. Read-back is decisive, external pre-existing/changed modes are not adopted or overwritten, failed restoration retains ownership for a later retry, and policy-off/uninstall restore `allow` or `default` exactly. No timer, polling worker or collection process was added.
- Release and test manifests now separate `dsp_reference_present` and `dsp_aidl_built` host packaging evidence from `dsp_runtime_verified=false` / `not_run_on_host`. Both workflows shell-parse in regression and enforce these fields with jq. Strict release still requires both AIDL interface versions, 32/64-bit variants and the attacher; the source-only exception remains explicit and narrow.
- Packaging review retained both Zygisk process-bitness libraries and the versioned/legacy DSP variants used by VINTF selection, early-boot restoration and manual ABI recovery. Already-redundant generic DSP copies remain excluded from versioned release packages. No compatible library was deleted merely because the reference phone is arm64.
- All 295 canonical host cases pass in the working tree and a clean source-ZIP extraction, including large-dump, latest-ledger, locale, multicast failure/external-mode and deferred-uninstall fixtures. Native warning, DSP syntax, manifest and executable-mode gates remain enabled.
- **Deliberately not implemented or claimed:** no forced Zygisk mode change, second governor, profile/Battery tier rewrite, camera/ISP preset, invented multi-device capability matrix, LTPO/panel claim, persistent scheduler rewrite, unverified SoC writer, native-binary rebuild or automatic report-only threshold after two AppOps failures. Host packaging checks do not prove audioserver runtime loading; host fixtures are not on-device validation of fix320, and no battery/performance improvement percentage is inferred from the supplied non-equivalent capture.

**fix319 — unified drill-in controls, readable evidence popups and individual service components**
- ZYGISK retains Back and once again exposes Logs and Telegram/Channel in its actual header. Report and ZYGISK Back controls are no longer caught by the old page-chip hiding rule. Escape now closes the top Logs menu before the underlying drill-in, instead of closing both.
- Report/ZYGISK docks reuse the main tab bar's geometry, cap material, icon-over-label tabs and animated active pill in Dark, Light and Liquid Glass. Rendered-order scroll-spy, auto-centering, safe-area spacing, fixed-dock portaling and reading-position restoration remain intact.
- Hero numbers return to the normal sans UI font with normal tracking and tabular figures. The four ZYGISK capture cards now open detailed sheets for accepted process events, heard cold starts, lifecycle hints and observer IPC CPU. Values and counter lines come from the current capture, not hardcoded screenshots. Drain, idle, jank, thermal peaks and Smart verdicts also receive bounded plain-language explanations; Enter/Space, Escape and focus return are supported.
- Package/uid AppOps is now honestly named **Block wakelocks**, not an app/service freezer. A separate **Services** sheet can disable one currently running third-party Android service component with `pm disable --user 0`, then restore its ledger-recorded `default` or `enabled` state. Discovery and read-back are on demand; externally disabled components are not adopted, failed writes/read-backs roll back, uninstall restores only ASB-owned entries, and no process killing, package freezing, polling or reapply worker was added.
- The supplied `V65-test17` capture records 20% over three hours (6.6%/h), 7.2%/h screen-on and 5.9% jank over 311,718 frames. It is an observation from an older build, not controlled A/B evidence for fix319 or proof that a particular change improved autonomy. Telegram's 24 alarm wakeups did not trigger an automatic app restriction.
- Added stateful service runtime fixtures and real DOM interaction contracts. All 293 canonical host cases pass in the working tree and a clean source-ZIP extraction; 49 real Chromium checks pass for current-data popups, keyboard/focus behavior, dock materials/geometry, deep scrolling, service confirmation/disable/restore, overflow and error-free rendering.
- **Deliberately not implemented or claimed:** the Services list is limited to currently running records plus ASB-owned disabled entries; it is not a complete manifest-service inventory, proof of wakelock ownership or proof of energy cost/savings. No automatic Telegram/app restriction, persistent collector, polling worker, second governor, hidden LSPosed management, vendor-thermal bypass, profile/Battery policy change, unverified SoC writer, native-binary rebuild or performance/battery percentage is claimed. Host fixtures and Chromium are not on-device field validation of fix319.

**fix318 — shared drill-in header geometry and native-theme navigation materials**
- Removed the independent compact sizing and inverse zoom from Infinite Log and ZYGISK headers. Their logo, wordmark, device line, badges, spacing and border geometry now inherit the same shared rules as the main page instead of merely enforcing a smaller 46 px logo.
- The section dock now uses the main tab bar's own `cap` surface, edge and shadow variables in every theme. Dark Glass and Light Glass explicitly own the dock in their existing material cascades, including backdrop treatment; the active section uses the same tonal pill and inner edge as the main tab indicator. The separate opaque fill and decorative active dot are gone.
- Browser verification compares each drill-in directly with the main page and main tab bar rather than checking isolated constants. At 375/390/412/424/1100 px in Dark, Light and Liquid Glass with reduced motion, header geometry and typography have zero measured delta, computed dock materials and active-pill paint match, all jumps and deep scrolling work, active chips remain fully visible, and physical touch targets remain at least 44 px. The 424 px case mirrors the supplied 1272 px device screenshots at 3x scale.
- Refresh dedup/position preservation, ZYGISK Off cleanup, close restoration and asynchronous English locale fallback pass. DOM contracts reject renewed independent header scaling and pin the shared navigation materials; all 291 canonical host cases pass in both the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** presentation only. No Governor, Battery, Zygisk, LSPosed, guard, ART, thermal, profile, collector, device writer or native binary changed; no polling worker, hidden management target or new restriction was added. Host/Chromium checks and supplied screenshots are not a new on-device validation of fix318 and establish no performance, temperature or battery-life improvement.

**fix317 — finished drill-in dock and stable header scale**
- Infinite Log and ZYGISK navigation is now a complete two-row dock: a small navigation label and the current section name sit above the independently scrolling section track. The active destination uses a calm tonal background, border and dot; auto-centering keeps it fully visible, and every target retains a physical 44 px minimum touch size despite the global UI scale.
- The two drill-in headers now cancel only the global UI zoom instead of shrinking with it. Their 46 px logo and project typography remain stable at 375/390/412/1100 px; the home, Config and other page headers are unchanged.
- Scroll-spy now follows rendered section order rather than thumb-friendly button order. This fixes Details/Thermals mismatches in Infinite Log, keeps the current-section label synchronized, and selects the actual last rendered section at the bottom. Programmatic jumps still use the overlay's own scroll container; fixed-dock portaling, safe-area spacing, deep-scroll availability and reading-position restoration remain intact.
- Real Chromium verification passed all report and ZYGISK jumps in 12 width/theme combinations with reduced motion, including active-chip visibility, deep scrolling, physical header/touch geometry, overflow and main-tab exclusion. Refresh dedup/position preservation, ZYGISK Off cleanup, close restoration and asynchronous English locale fallback also passed. The DOM regression now executes the reordered scroll-spy and bottom cases; all 291 canonical host cases pass in both the working tree and a clean source-ZIP extraction.
- **Deliberately not implemented or claimed:** presentation and navigation state only. No Governor, Battery, Zygisk, LSPosed, guard, ART, thermal, profile, collector, device writer or native binary changed; no polling worker, hidden management target or new restriction was added. Host/Chromium checks are not on-device field validation and establish no performance, temperature or battery-life improvement.

**fix316 — non-blocking locale boot, interaction-gated Battery probes and thumb-zone drill-in navigation**
- Reviewed the supplied `V65-test17` field capture, report, diagnostics and the separate fix315 audit as different sources of evidence. The capture does not validate fix313–fix315 and does not support raising CPU ceilings, bypassing vendor thermal ownership, adding SoC-specific writers, restricting apps by traffic, or deleting ASB's resident loops. ASB's measured own cost is low; at-cap jank is not worse than below-cap jank in this capture.
- WebUI locale files now load asynchronously in parallel. Localized boot waits for both the DOM and the locale result; a missing or malformed selected locale retains the key-by-key English fallback. No `.gz`/`.br` assets or server-only content-encoding assumption was added to the source module.
- Battery scroll-hold retains its first baseline probe and 21-day recheck, but when touch input is readable it does not launch another passive probe until a new interaction follows the previous one. If touch is not exposed, the previous bounded 180-second cadence remains the explicit fallback. Charging/RAM gates, thermal spoil rules, app eligibility and kept/released evidence thresholds are unchanged.
- Infinite Log now publishes the latest snapshot's existing thermal-spike counters and the aggregate Battery hold counts in their relevant detail sections. When `governor.log.session` is already present, at most six recent per-app hold verdicts are shown with their measured without/with jank rates; no new collector, polling worker or identifier read was added.
- Infinite Log and ZYGISK section navigation is now a finished fixed bottom dock in the thumb zone, with safe-area padding, horizontal chip scrolling, one `aria-current` active section and physical 44 px minimum targets despite the global UI zoom. The dock is portaled out of the transformed scroll overlay so it cannot scroll away; the main tab bar is hidden only while these drill-ins are open. Overlay height measurement now preserves the reading offset instead of resetting it in Chromium.
- Real Chromium checks passed for report and ZYGISK at 375/390/412/1100 px in Dark, Light and Liquid Glass with reduced motion: deep scrolling, active-state tracking, real section clicks, locale loading/failure fallback, dock geometry, main-tab exclusion and page overflow. The REAL C learner fixture covers untouched screens, new interaction, touch-unavailable fallback and all previous kept/released/thermal/spoilt/persistence behavior. All 291 canonical host cases pass in the working tree.
- **Deliberately not implemented or claimed:** no unverified taro/lahaina/MTK writer, Zygisk Battery default, implicit/warm-launch ART, arbitrary RAM/charging gate, event-hint suppression, resident-loop removal, `asbdiag` symlink, precompressed locale or duplicate `batterystats` read was added. No persistent polling, hidden LSPosed management, vendor-thermal bypass, second governor or native-binary rebuild is claimed. Host and browser checks are not on-device validation; no percentage improvement in smoothness, temperature or battery life is claimed without comparable on-device A/B evidence.

**fix315 — atomic LTPO owner publication, including the acquisition path**
- The supplied TEST run lost one of 400 LTPO critical-section updates; the other two shards passed. Atomic release alone could not close the remaining race: acquisition used atomic `mkdir`, but published `pid` in a later write. A creator descheduled between those operations left a live ownerless directory that another writer could reclaim after the grace interval.
- A forced delay after successful `mkdir` reproduced the defect deterministically: the old writer subsequently found its lock directory gone. Acquisition now uses an atomic symlink whose numeric target is the owner PID, so ownership exists from the instant the lock appears. Release and known-dead recovery retain whole-lock atomic quarantine; missing, corrupt or ownerless evidence is never treated as permission to steal a lock.
- Legacy directory locks from the previous release remain readable during a live module update, with recovery only for a known-dead owner. The regression forces a delayed first publication, requires all 400 competing updates, and covers both symlink and legacy-directory stale recovery. Sixteen concurrent copies passed 6400 critical sections and 16 forced publication delays; neighboring LTPO range/video/touch/external-fallback paths and all 291 canonical host cases pass.
- **Deliberately not implemented or claimed:** no refresh-rate target, LTPO range/policy, vendor writer, Governor, Smart, Zygisk, LSPosed, guard, ART, thermal, profile, worker or native binary changed. Host locking fixtures do not prove on-device panel behavior, actual 1 Hz selection, energy savings or performance gains; field validation remains separate.

**fix314 — SIGPIPE-safe Infinite Log concurrent-start regression**
- The new TEST run had one primary failure: `ui: debug_support_contract`, round 12; the features and system + smart shards passed. Instrumented reproduction caught the same assertion failing even though both answer files contained exactly the required `status=started` and `status=already_running` with the same live recorder PID.
- The false failure came from the fixture's `printf ... | grep -q` pipelines under `set -o pipefail`: `grep -q` can exit immediately after finding a match while the producer is still writing, so a correct answer may randomly become a SIGPIPE failure on a loaded runner. The concurrent-start assertions now grep the two answer files directly, and winner-PID extraction is a single awk pass without a `head` pipeline. The required start count, loser state, live recorder and published winner PID are unchanged, not relaxed.
- A failing assertion now prints both answers, the recorder log tail and lock ownership files. The corrected fixture passed 24 concurrent copies covering 288 start-race rounds; all 291 canonical host cases then passed in both the complete working-tree and clean-source-ZIP regressions.
- **Deliberately not implemented or claimed:** no Infinite Log helper/recorder, WebUI, Governor, Smart, Zygisk, LSPosed, guard, ART, thermal, profile, collection worker, device writer or native binary changed. No test was removed or expected state weakened. These host fixtures are not on-device capture-lifecycle, energy or performance validation.

**fix313 — race-free LTPO lock release and deterministic restart classification**
- Fixed both primary failures in the supplied TEST run without disabling or weakening their assertions. LTPO normal release and dead-owner recovery previously removed `pid` before removing the lock directory, leaving an ownerless interval at the live path. Both paths now move the whole lock atomically to a per-process release/dead quarantine and clean it there; live or unreadable owners are still never deliberately stolen.
- The LTPO concurrency fixture now runs four competing workers through 400 critical sections and statically requires atomic whole-lock release. The repaired lock passes that stress contract, eight concurrent copies of it, and the neighboring video, touch and external-fallback runtime tests.
- Logkit restart classification now retains uptime milliseconds instead of truncating to whole seconds. Missing, malformed or contradictory evidence, including `system_server.start_elapsed` greater than uptime, returns `unknown`. The regression uses the explicit `ASB_LK_UPTIME_FILE` fixture instead of the host runner's changing `/proc/uptime`, and distinguishes `framework_restart`, `recorder_lost` and `unknown` deterministically.
- All 291 canonical host cases pass in the complete working-tree and clean-source-ZIP regressions with eight workers. No test was skipped and the existing schema, lint, native-warning and source-only DSP gates remain active.
- **Deliberately not implemented or claimed:** no Governor, Smart, Zygisk, LSPosed, guard, ART, thermal, profile, device writer, collection worker or native binary changed. No polling, hidden management target or performance/battery improvement is claimed. Host fixtures establish lock and classification behavior only; they are not on-device LTPO, Android restart, energy or performance field validation.

**fix312 — portable Ubuntu 26.04 regression fixtures and sharded CI validation**
- Fixed both failures from the supplied TEST log without changing governor/runtime policy: the writer-hold C harness now includes `stdlib.h` for `atoi` under the newer compiler default, and state-enum sorting uses the explicit portable form `sort -t '=' -k2,2n`. The same explicit separator is used by the full-day wakelock-source sorter.
- TEST and RELEASE now run the canonical regression as three independent matrix shards: `features`, `system + smart`, and `ui + zygisk + package_tweaks`. Every shard retains schema sync, lint, native warning and DSP gates; all 291 test cases remain covered exactly once, eight workers per shard remain, and packaging depends on every shard. TEST keeps its conditional source-only DSP reference handling; RELEASE remains strict.
- The canonical runner accepts whole-suite selection and rejects unknown suite names. Long timer/process-heavy tests start first without changing log order or pass/fail accounting. A measured twelve-worker experiment was rejected because it was slower on the two-CPU host; parallelism was not raised blindly.
- Local complete-shard measurements were 47.0 s for features, 54.0 s for system + smart, and 65.7 s for UI + Zygisk + package tweaks, all passing. The former complete eight-worker run took 155.8 s on the same host. These figures describe host regression structure only; checkout, NDK restore, native compilation, packaging and GitHub scheduling still add time, and no hosted-runner duration is guaranteed.
- Workflow contracts now execute all four real mode-normalization blocks, verify complete nonduplicated matrix coverage, require `fail-fast: false`, and gate both package jobs on the regression matrix. Both original failing fixtures pass after the correction. The debug-recorder abnormal-death fixture now waits for both recorder and launcher identities before asserting stale-lock reclamation, matching the helper's fail-closed ownership rule instead of timing only one PID.
- **Deliberately not implemented or claimed:** no test, native warning gate, DSP validation, required native artifact or source-only strictness was removed. No Governor, Smart, Zygisk, LSPosed, guard, ART, thermal, profile, worker or device writer changed. NDK r28c caching and native sources/artifacts are unchanged; no AOSP binary was rebuilt or claimed as rebuilt. Host timings and fixtures are not an actual GitHub run, on-device field validation, or evidence of performance/energy gains.

**fix311 — clearer ZYGISK and Infinite Log reading hierarchy**
- Reworked only the presentation of the two longest drill-ins: compact complete headers, stronger section separators, calmer evidence rows and tabular numeric emphasis. The existing palette, Dark/Light/Liquid Glass themes, reduced-motion behavior and every control remain in place.
- Infinite Log now opens with a capture-aware section map before the plain-words brief. Battery, Smoothness, Thermals and Zygisk appear only when the corresponding evidence exists; Summary, Actions and Details remain stable destinations. The strip sticks below the status area and scrolls horizontally inside itself rather than widening the page.
- ZYGISK groups Mode, Automatic setup and Controls in that order, followed by Activity, Guard, ART and Apps, with stable anchors and preserved reading position across refreshes. Loading and Off deliberately show no irrelevant section map. Long app lists, guard history and the 60-plus-value evidence table are collapsed by default and still open on demand; pending approvals and active restrictions remain visible.
- Added a runtime DOM contract for loading/Off/populated states, section order, all seven ZYGISK jumps, conditional report navigation, progressive disclosure and all 13 locales. Real Chromium verification covered 375/390/1100 px, sticky-anchor geometry, Dark/Light/Glass, reduced motion and lazy evidence expansion, with zero console errors, failed requests or page-level horizontal overflow. It also caught and fixed an initially insufficient anchor margin that placed headings beneath the sticky strip.
- **Deliberately not implemented or claimed:** no Zygisk, Governor, guard, ART, LSPosed, thermal, log-collection or metric-analysis mechanism changed; no polling worker, new restriction policy, performance/battery percentage or hidden management target was added. Browser and host tests are not on-device field validation and prove neither injection efficacy nor energy/performance gains.

**fix310 — safe Force-LTPO coexistence and exact refresh-range handback**
- Compared the supplied COS17 `V65-test15`/`V65-test16` captures with the newer `V65-test17` capture and inspected the actual standalone **Force ltpo** payload. The working external module uses an older static VRR schema with its own backlight/ambient strategies; ASB does not copy that foreign table or add absent keys to the newer COS17 schema. A live ASB JSON bind proves content delivery only, never that the panel actually selected 1 Hz.
- Reproduced and fixed same-target ownership: when `/proc/mounts` explicitly identifies another module's bind on `oplus_vrr_config.json`, ASB now leaves that table, its daemon and its refresh policy alone instead of stacking a second bind or unmounting it during Off/remove. Opaque root-manager mounts remain **unknown**, not guessed ownership. WebUI and `asbdiag` distinguish an external same-target bind from the separate external touch-writer state, with all 13 locales synchronized.
- Reproduced and fixed exact range restoration: when the original `min_refresh_rate` was unset, Off/remove now deletes a floor written by somebody else during ASB ownership instead of leaving it behind. Existing peak/video locks, touch ownership, external-writer fallback, boot loop fuse and fail-closed manifest guards are unchanged.
- Regression fixtures fail on fix309 and pass after the patch for external-bind preservation and unset-min handback. Existing LTPO runtime, range and external-fallback tests remain intact; diagnostics copies and all locale key sets are checked byte-for-byte/key-for-key.
- **Deliberately not implemented or claimed:** no Governor, Smart, Zygisk, guard, ART, LSPosed, thermal or native-binary change; no persistent collector, app restriction or unverified SoC-specific writer. The high-drain old capture is dominated by screen-on/media/mobile-traffic context and does not prove an ASB governor defect or justify new throttling. Host tests establish neither actual 1 Hz selection nor energy savings; COS17 field validation is still required.

**fix309 — evidence classification, honest diagnostics and status-bar-safe reporting**
- Fixed the full-day cap verifier classification: `ok`, `ok (shell-applied)` and `ok_asb_*` all count as successful readbacks. Known vendor and shell overrides occupy the external-override bucket, while unfamiliar verdicts remain visible as residual `other`. On the supplied capture the incorrect `0/4 · 4 other` becomes the evidence-supported `4/4 · 0 external · 0 other`; no CPU writer changed.
- `asbdiag` keeps Android settings ledger refusals in the final verdict. `FAIL=0` still describes live checks, but is now accompanied by `REFUSED=n` when requested system settings did not take effect; a genuinely clean ledger retains the original clean verdict. Zero, missing or malformed Smart thermal history is shown as **not learned**, not as an active 0/0 threshold.
- Corrected Wi-Fi multicast wording in Actions, `asbdiag` and all locales: historical held time with Wi-Fi currently off proves neither current radio cost nor past energy cost. Infinite Log no longer turns a screen-off CPU temperature into proof of heavy background work or an app, and low brightness alone no longer proves the panel's share of drain. Recommendations now ask for time-matched battery evidence before app-specific action.
- Added a fixed status-bar scrim above every self-scrolling page and below navigation/modals, with real safe-area height and a 28 px fallback for ROMs reporting zero. ZYGISK long values use lighter typography, and ART explicitly says that its observed-app list mixes waiting, compiled and unknown states rather than implying that every row is a waiting candidate.
- Regression fixtures cover every success/override form, refused and genuinely clean verdicts, zero and valid thermal states, all 13 locale key sets, the ART scope note and scrim layering. Real Chromium verification at 412×915 confirmed computed layering, safe-area height, lighter values, ART scope, no horizontal overflow and no JavaScript errors.
- **Deliberately not implemented or claimed:** no governor, Smart learning, profile, guard, ART gate, Zygisk event model, LSPosed ownership, vendor thermal policy, persistent collector or native binary changed. Host/Chromium verification is not on-device validation and establishes no performance or energy gain. Five short throttle periods, good deep sleep and one capture are not grounds for a new SoC-specific writer or app restriction.

**fix308 — semantically distinct icons across the ZYGISK page**
- Audited icon ownership across the complete page rather than changing only the reported duplicate. **Mode** now uses layered profiles while **ASB Zygisk controls** keeps sliders. **Connection** retains the Z cell, and the master switch plus Off state use a dedicated power glyph in both ZYGISK and Settings.
- Cold-start keeps its process-launch arrow, while ART gains a separate code-compilation glyph. **Open ZYGISK control panel** uses the control sliders rather than repeating the Connection symbol. Auto/Battery/Performance keep the fix307 mode icons, order, selection and all runtime semantics.
- DOM contracts pin section ownership, distinct glyph geometry and the master/ART call sites. Real Chromium verification covers 48 On/Off states across Russian/English, dark/light/Glass including light Glass, and 300/360/480 px; it checks all nine On-section icons, Off ownership, master/Cold-start geometry, Settings navigation, Glass materials, overflow and JavaScript errors.
- **Deliberately not implemented or claimed:** presentation only. No setting key, preset, runtime writer, worker/polling loop, guard, ART behavior, LSPosed policy, thermal gate or native binary changed. Host/Chromium checks are not on-device validation and do not establish performance or energy gains.

**fix307 — one Glass Zygisk surface, clearer Mode icons and overlapped CI validation**
- Settings → System → Zygisk now uses one parent Liquid Glass material in both dark and light palettes. The evidence row and embedded `zygisk_enabled` row stay transparent and unblurred children rather than becoming nested opaque/Glass cards; an explicit light-palette override prevents the generic ON/OFF rules from winning the cascade. Connection evidence, master ownership and navigation behavior are unchanged.
- Mode is ordered **Auto**, **Battery**, **Performance**, with Auto on the far left. Auto receives a dedicated adaptation-loop/sparkle glyph and Performance a speedometer. Cold-start and ART keep their existing independent icon. Internal IDs, profile names, values, Automatic setup, guard and ART semantics did not change.
- TEST and RELEASE schedule the canonical regression with eight workers in an isolated copy while independent NDK/native work proceeds. Duplicate serial schema/DSP/lint preflight executions were removed because the canonical regression still performs those checks; the strict native warning-budget step and all test functions remain. Packaging is gated by an atomic result file and fails on missing, malformed or nonzero status. TEST keeps conditional source-only DSP handling; RELEASE remains strict.
- Static/DOM regressions cover the Glass cascade, order, selected state and icon ownership. Real Chromium verification covers 48 On/Off states across Russian/English, dark/light/Glass including light Glass, and 300/360/480 px, with computed parent/child materials, overflow and JavaScript-error checks. Workflow YAML, run-block shell syntax and packaging-order contracts are checked.
- **Deliberately not implemented or claimed:** no runtime writer, persistent polling, second governor, hidden LSPosed management, vendor-thermal bypass, preset/ART behavior change or test removal. No particular GitHub hosted-runner duration is guaranteed, and host/Chromium checks are not on-device validation or evidence of performance/energy gains.

**fix306 — one Settings master, a complete ZYGISK panel and a non-destructive Off state**
- Settings → System → Zygisk now has exactly one real switch, `zygisk_enabled`, together with the existing evidence-based connection indicator and a direct **Open ZYGISK control panel** action. The preset summary and Lifecycle/Cold-start/Ledger switches were removed from Settings, including search results, so it is no longer a competing second panel.
- ZYGISK owns the master and all three feature switches. Every row is synchronized from current observer evidence and writes through the existing `cfgSet()` → `asb_config_safe.sh` → `asb_zygisk.sh sync` path; no runtime writer or worker was added. A manual feature deviation still becomes **Custom**. Zygisk writes now show the correct applied/restart-application toast instead of falling through to an inaccurate reboot message.
- With the master Off, ZYGISK keeps the connection verdict and shows a dedicated Off card instead of inactive Mode, Automatic setup, guard, ART or app controls. It offers Enable and Settings → System navigation, and states that existing app processes keep their prior state until restarted. Off → On writes only `zygisk_enabled=1`: the selected mode, automatic marker and app list, feature values, guard and ART are not reset. An unreadable master remains **Unknown**, never a false Off.
- All 13 locales and both advanced READMEs describe the single-owner navigation and preservation semantics. DOM regressions cover Settings/card ownership, all four panel controls, Off content, Off/On preservation, unknown-key refusal, shared-writer delegation, refresh/busy behavior and Custom conflicts. Browser verification covers Russian and English, dark/light/Glass and 300/360/480 px in both On and Off, plus real Enable/feature writes and two-way Settings navigation.
- **Deliberately not implemented or claimed:** no instant detachment from already running processes, forced app restart, new preset on re-enable, second governor, new runtime writer, persistent polling, hidden LSPosed management, vendor-thermal bypass or implicit ART compilation. Host and Chromium tests do not establish on-device injection reliability, faster starts, notification behavior or energy savings.

**fix305 — one Zygisk Mode choice with synchronized presets and honest Custom conflicts**
- Replaced the competing Mode, Automatic setup profile buttons and goal guide with one primary three-choice control above Automatic setup: **Battery**, **Performance** and **Auto**. Auto uses a magic-wand icon. Automatic setup now follows the selected mode; Settings → System → Zygisk shows the detected preset and the same four actual switches.
- Battery uses observer + ledger + evidence-gated `wakers` guard with cold-start and lifecycle requests off. Performance (`launch` internally) uses observer + ledger + cold-start assistance with guard off. Auto uses all four observer switches plus the evidence-gated guard. Existing package ranking, transactional backup/restore, Safe mode refusal, profile/thermal gates and per-package guard evidence/approval remain unchanged. ART is independent and is never implicitly enabled.
- A manual switch or guard deviation is reported as **Custom**, not silently rolled back or mislabeled as the previous preset. In particular, adding cold-start or lifecycle activity to Battery produces an explicit warning. An exact switch match with guard evidence still pending is **Unknown**; a known switch conflict can already be identified as Custom. `observe` remains a runtime compatibility profile, not a fourth WebUI preset.
- All 13 locales and the advanced documentation/state schema describe the unified model. Runtime and DOM regressions cover every preset, Settings synchronization, one-shell delegation, guard/switch conflicts, pending evidence, Safe mode and the Auto diagnostics marker. Browser verification covers Russian and English in dark/light/Glass at 300/360/480 px.
- **Deliberately not implemented or claimed:** no second governor, new worker/polling loop, hidden LSPosed management, vendor-thermal bypass, implicit ART compilation or automatic undo of manual settings. Auto does not guarantee maximum performance and battery life simultaneously. Host and browser tests do not establish on-device injection reliability, notification latency, faster starts or energy savings.

**fix304 — goal-oriented Zygisk choices and bounded zero-process evidence**
- The Zygisk page now places a **What to choose** guide directly before Automatic setup and the manual mode controls. It names the existing buttons for responsiveness (Launch assist, Response or Full), battery-oriented guarding (Battery guard, with the background-work/notification-delay trade-off) and minimal intervention (Observe only/Watch or Off). These are explanations of existing requests and evidence gates, not promised performance or energy gains.
- All 13 locales carry the guide. Manual mode buttons also expose their existing detailed descriptions as native `title` attributes; no setting, default, allowlist, guard gate, ART policy, writer or runtime command changed.
- Device diagnostics explains a current, enabled, non-safe `loaded_processes=0` snapshot as the absence of a validated resident observed app process, not an injection-failure count. Stale, disabled, safe-mode and nonzero snapshots do not receive that explanation. Channel confirmation and cold-start requests remain separate evidence.
- DOM regressions cover the three-goal guide, ordering before controls, all localized strings, mode titles, zero-process evidence boundaries and the single delayed lazy-header refresh. Browser checks cover Russian and English across dark/light/Glass and 300/360/480 px. Host fixtures and desktop rendering do not establish on-device injection reliability, faster starts or battery savings.

**fix303 — evidence-bounded report wording, Zygisk clarity and diagnostic read-back**
- The full-day report now shows neutral per-domain evidence coverage instead of a global High/Medium/Low confidence headline. Mobile traffic remains measured context: its volume no longer creates a red network verdict or a priority action, and screen-on drain text does not assign drain causality to the modem or the largest app. Existing optional app-specific remedies remain manual and do not change package, radio or LSPosed policy.
- The automatic Zygisk card separately displays the current Observer, Lifecycle hints, Cold-start lift and Process ledger switches. The allowlist editor is a wrapping multi-row field with unchanged validation and read-only automatic mode. Denylist/unmount flags are explained as pre-specialization one-shot cold-start records, not failed injections or a reason to prune the allowlist. Long evidence values and package names wrap instead of being truncated.
- `asbdiag` explains a Wi-Fi pending result while Wi-Fi is off without turning it into a failed apply; mobile pending semantics are unchanged. Camera read-back now explains that `state=live mounted=no` can mean content already matches through the live module/overlay path. Stale/missing payloads and historical crashes are not cleared or reclassified by this note.
- Added DOM and shell regressions for neutral traffic/coverage rendering, independent Zygisk state, the multi-row editor, Wi-Fi/mobile pending branches and live camera read-back. Host tests do not establish on-device energy savings, thermal behaviour, injection success or camera-HAL stability.

**fix302 — peer-confirmed one-tick CPU-spike deferral and explicit thermal-spike evidence**
- An isolated upward CPU candidate at least 25 °C above the hottest available independent CPU peer is now deferred for exactly one governor reading, even after a percentage-like `socd` source has been rejected and the old fallback cleared. The selected zone never corroborates itself; at least two independent peers are required, except for the pre-existing single-fallback compatibility path. The hottest valid peer is used rather than an average, so one corroborating hot core prevents a spike classification.
- A repeated high candidate is accepted on the next reading, shared CPU heating is accepted immediately, and insufficient peer evidence never suppresses heat evidence. A first extreme candidate without a cached baseline publishes `temp_valid=0` rather than a fictitious valid 0 °C. Peer reads happen only for an already-suspicious candidate; no worker or persistent polling was added. Vendor thermal ownership and thresholds are unchanged.
- `/dev/.asb/state`, native status JSON and `asbdiag` now expose session-local hold count, last candidate, hottest peer, independent-peer count and epoch. A hold means only that an isolated candidate was deferred once: it is not proof of a faulty sensor, a false original reading or an ASB-caused temperature. `temp_reason=spike` is now a documented diagnostic reason.
- Native fixtures cover a primary-core spike without fallback, mandatory acceptance of a repeated high value, immediate acceptance of shared heat, invalid first-extreme output followed by confirmation, and fail-open behavior with only one independent peer. These are host fixtures, not validation of Android thermal HAL behavior, firmware sensors or the reported on-device episode. The older V65-test16 capture cannot validate this source change. The native governor is not prebuilt in this source archive and must be rebuilt by the normal project toolchain. DSP reference staging remains optional only for source regression; no battery/performance improvement or sensor-fault verdict is claimed.

**fix301 — explicit automatic profiles, transactional native inputs and evidence-gated guard actions**
- Automatic setup is now three explicit choices instead of an implicit Full + guard + ART bundle: **Observe** (observer + ledger), **Launch** (cold-start assist + ledger) and **Battery** (observer + ledger + `wakers` guard). No profile enables ART. Before the first automatic enable ASB saves the previous package list, four observer settings, guard level and ART state; disable restores that state instead of blindly disabling features. Legacy automatic markers are reported as `legacy`, not mislabeled as a new profile.
- `zygisk/policy` and `zygisk/classes` are synchronized as one native input contract. A classes-generation failure after policy replacement restores both previous files byte-for-byte, removes temporary rollback files and returns failure. No partially replaced pair is treated as successful.
- Background guard automatic AppOps restrictions now require matching evidence in at least two separate screen sessions and explicit per-package approval. Proposals are dry-run rows and change nothing by themselves; approval alone also changes nothing. Positive exact-alarm, foreground-service and notification listener/policy-access evidence vetoes a write immediately before it. Empty or unreadable runtime output is not treated as proof that those protections are absent. **Give back now** restores one package's recorded mode and clears its pending/approval state; existing baseline, readback, protected-class and exact-restore mechanisms remain.
- ART temperature gating is fail-closed when the temperature is missing or malformed, and at most one package batch can run per charging session. The existing seven-day per-package retry remains; it does not bypass the charging-session batch bound. The WebUI and all 13 locales describe the new profiles, dry-run/approval/release flow, independent ART state and compilation cost without promising battery savings.
- The infinite-log WebUI report gains a **Tweak evidence** matrix built only from data the capture already contains: CPU-cap readback observations, at-cap/below-cap jank associations with frame populations, Zygisk/Governor action deltas, LTPO lowered time, Wi-Fi Leave actions, Smart learner decisions and ASB's own overhead. Direct actions, associations and cumulative snapshots are labeled separately. No tweak is assigned a battery, thermal or smoothness benefit without a comparable one-variable A/B; an absent row means not exposed in this capture, not unsupported or zero effect. The new `capcheck` and `wifileave` digest projections read existing files and add no worker or device collection.
- Regression coverage exercises all automatic transitions and exact state restoration, failing-classes rollback, two-session/approval/release behavior, positive FGS/alarm/notification safety checks, pending WebUI parsing and commands, unknown-temperature refusal and a new charging session. The evidence matrix is tested against digest fixtures, direct/unknown Zygisk deltas, readback categories, Wi-Fi counters, correlation frame counts, empty evidence and all 13 locales. Documentation now records the automatic marker, pending schema, charge-batch state and evidence semantics. These are host fixtures, not Android-framework, real-Zygisk-loader or on-device energy/performance validation.
- **Deliberately not implemented or claimed:** no notification-delay automatic rollback without a reliable universal signal; no active-VPN dynamic inspection or network-identifier collection; no broad profile/SIM/network/thermal fingerprint that would make old process-start records look like stronger evidence; no all-package HeyTap MCS compile mixed into per-package Zygisk ART; no invented fork/byte/wall-time overhead metrics beyond the existing `asbcost`; no new persistent polling worker, arbitrary Zygisk hook, second governor, hidden LSPosed management, vendor-thermal bypass or unsupported percentage. Context fingerprints, a generated ownership graph, a fuller parser/capability matrix, Evidence Graph/JSON v4 and real device-matrix/A/B work remain deferred rather than presented as done.

**fix300 — screen-off launch veto and Governor-side action evidence**
- A cold-start request received while the Governor has already published `screen=0` is now vetoed inside the companion. Its process-ledger entry and counters remain, but no guaranteed-to-be-vetoed Governor datagram is sent and the one-second/20-per-minute launch budget is left for the next real screen-on start. Unknown screen state still follows the normal fixed-opcode request path.
- Observer diagnostics and the infinite-log report now carry `launch_screen_off` as a subset of `launch_vetoed`. A new `zygov` projection reads only the existing `before.txt`/`after.txt` state blocks and distinguishes Governor request outcomes from actual changes to ASB’s own cold-start lift window: armed lifts, extensions, long-window coverage and early trims. One snapshot produces no delta; any decreasing included counter invalidates the whole Governor delta family.
- The report uses the stronger control-path wording only when a real lift-window action delta is present. It still does not claim a hardware ceiling write, total control of other Zygisk modules or LSPosed, improved performance or energy savings. All 13 locales carry the new labels and limitations.
- No arbitrary hooks, package/cap payload to the Governor, second governor, polling worker, hardware writer, hidden LSPosed management or profile/thermal-gate bypass was added. Native host tests prove the no-IPC/no-budget-consumption behavior and ledger preservation; digest/UI fixtures cover normal, zero, reset, single-snapshot, Governor-only and legacy-capture evidence. These host checks are not an on-device A/B validation.

**fix299 — cross-device capture compatibility and reset-safe Zygisk accounting**
- Compared older SM8750/sun and SM8650/pineapple captures against the current source instead of treating their old-build behavior as current defects. The SM8650 denylist behavior and unconfirmed-night accumulation were already corrected in newer runtime code; neither was reimplemented or reversed.
- A decreasing cold-start outcome now invalidates every `launch_*` delta for that snapshot interval. An unchanged total or an apparently rising accepted counter can be a coincidence across a companion restart, so the report no longer presents them as a zero-launch window or a partial outcome count. Independent monotonic spawn, ledger and IPC counters remain available.
- Microwake evidence now carries `nights` into the digest. `nights=0` renders as “no completed nights for an average yet”, rather than a misleading `0.0 per night`; legacy digests without the field retain the previous format. A positive denylist/unmount count gains an explicit bounded explanation: the flag alone does not prove failed injection or justify an allowlist change. All 13 locales include the new wording.
- No file under `src`, native writer, Governor/FSM, Smart learning, Zygisk runtime, thermal, battery, allowlist or LSPosed policy changed. On SM8750 all 1167 native write attempts were applied and read back successfully; the 146 re-sends through vendor hold accompanied changed requests/lifts, so reducing write counts would not be evidence-based. SM8650 jank was not worse at the main ceiling (3.9% at cap versus 5.0% below it), and vendor thermal ownership remains intact. No device-specific writer, polling worker or performance/battery-saving claim was added.
- Regression fixtures cover the real reset shape (`10→10` launches, `8→9` accepted, `2→1` unavailable), independent spawn deltas, `53` checks with zero completed nights, legacy microwake digests, denylist wording and localization placeholders. Both uploaded captures are also run through the production digest.

**fix298 — exact Smart outcomes, measured warm spells and reconciled Zygisk cold starts**
- Fixed an infinite-log digest parser defect where the suffix of `not_helped` was read as `helped`: a capture with zero retained headroom and three unsuccessful comparisons could therefore claim that three apps benefited. Pipe-delimited fields are now split by their exact names. The report distinguishes retained headroom, unsuccessful comparisons and records made on a manual profile, and explains the end-of-capture counter scope.
- Thermal evidence now measures the number of CPU spells above 45 °C and the longest continuous spell alongside the existing total. Total hot time is no longer presented as proof of sustained load, and the peak-temperature phase is not mislabeled as the phase with the most hot time. Google Play mobile-data advice no longer assumes that app updates caused the measured traffic; smoothness wording consistently uses “good” for the same verdict.
- Zygisk reporting names the accepted process start/exit channel precisely, carries memory, screen-off ledger leader and restart-loop facts into the digest, and reconciles cold-start accepted/vetoed/unavailable/throttled outcomes. A remainder is described as potentially in flight, not an error. Accepted requests are explicitly Governor acknowledgements, not proof of an armed lift or changed ceiling; zero lifecycle events remain distinct from spawn/ledger IPC and are not called injection failure.
- No Governor, Smart, Zygisk, thermal, battery, allowlist or LSPosed runtime policy changed: the supplied evidence showed successful native writes, bounded overhead and reconciled counters, so it did not justify new writers, polling or a second governor. All 13 locales carry the revised wording. Regression fixtures cover exact Smart parsing, multiple warm episodes, legacy digests, cold-start balance/remainder, ledger fields and localization placeholders; the complete host regression and real mobile Chromium rendering of the supplied capture pass.

**fix297 — a quieter, compact ZYGISK header wordmark**
- The custom six-letter vector wordmark is reduced from 48 × 9 to 42 × 8 px, bringing its visual weight closer to the adjacent `SM8850` and `V65` labels. The angular letter geometry is unchanged.
- All six headers retain the same status colours, breathing dot, accessible verdict, navigation and compact `asb-fit-c2` label hiding. Presentation only: no Zygisk, Governor, Smart or other runtime policy changed.
- Runtime contracts and real Chromium checks cover all six headers, connected-state colours, dark/light/Glass themes, widths from 300 to 480 px, compact hiding, no JavaScript errors and no capsule overflow.

**fix296 — a semantic audit of tweak descriptions in all 13 languages**
- Reviewed all 86 Config cards and rewrote 48 general descriptions, 18 option-description maps and eight section hints. The Wi-Fi scan-rate card now has a general description as well as its per-option details. English inline fallbacks and `en.json` are identical for every audited card, so the copy does not depend on which loading path the WebUI uses.
- Descriptions now state what actually changes, when it runs, defaults and prerequisites, reboot or restore behaviour, limitations and trade-offs. Removed universal smoothness/battery guarantees, one-capture anecdotes and unsupported percentages; retained exact camera multipliers, DSP gain/thermal limits, network timings, Doze and wakelock thresholds, thermal bounds and LSPosed Keep/Off ownership. Notification delay, hearing safety, background location, runaway-process and diagnostic-loss risks are explicit.
- No setting key, default, option value, handler or runtime policy changed. Added regression guards for complete localization, revised section hints, English/source parity and rejected absolute claims. The complete host regression passes; real Chromium mobile checks covered Russian, English, Chinese and Arabic RTL with expanded long descriptions and no horizontal overflow.

**fix295 — a processor-brain Smart mark, a custom vector ZYGISK wordmark and a themed Zygisk page**
- Smart is redrawn in the requested top-down circuit style: two rounded, mirrored brain hemispheres with gyri, a central processor core and four small circuit terminals. The bespoke inline SVG uses no lettering, third-party branding or raster asset, and the one registry entry updates both Home and Settings.
- The header still says exactly `ZYGISK`, but now uses six custom angular vector letterforms rather than a platform monospace font. It therefore keeps the same appearance with bundled and device fonts and needs no network font. Existing status colours, the breathing dot, accessibility verdict, navigation, idempotent six-header construction and `asb-fit-c2` hiding are preserved.
- The dedicated Zygisk page gains restrained thematic SVG icons for its eight sections and two existing actions, plus a subtle accent surface on Automatic setup. Titles, radio semantics, evidence text, commands and handlers are unchanged; repeated renders do not duplicate icons or add shell reads.
- Presentation only: no Smart, Governor, Zygisk, thermal, battery or Monitor policy changed. Runtime contracts and real Chromium checks cover both Smart consumers, all six wordmarks, every page icon, repeated rendering, dark/light/Glass, selected/unselected states, widths from 300 to 480 px, no JavaScript errors and no horizontal overflow.

**fix294 — an anatomical side-view Smart brain and a compact technical ZYGISK wordmark**
- The header label is simply `ZYGISK`, with no `// LINK` suffix. Its existing local monospace stack now uses a heavier 800 weight and tighter 0.06 em tracking for a compact technical wordmark; no font download or layout dependency was added.
- The Smart mark is redrawn as a side-view brain, not a mirrored top-down symbol: a large organic cerebrum with non-mirrored gyri, a separately outlined and hatched cerebellum, and a descending two-line brain stem. The 1.55 px stroke keeps all three structures legible at 19–26 px. Both registry-driven consumers use the same drawing.
- All status colours, navigation, animations, selected/unselected states and compact header hiding remain unchanged. Runtime and Chromium checks cover the revised anatomy, the short label on all six headers, dark/light/Glass, Settings, 300–480 px widths, no JavaScript errors and no horizontal overflow. No runtime policy changed.

**fix293 — a neural Smart mark and a protocol-style Zygisk header label**
- The shared Smart icon is now a purpose-drawn brain: two sculpted hemispheres, a gently offset central fissure, asymmetric gyri and one restrained neural terminal. A lighter 1.7 px stroke preserves those details at the actual 19–26 px WebUI sizes. The single registry entry updates both the profile card and the Smart & Auto Profile settings section; no raster asset, icon package or extra request was added.
- Every page header now reads `ZYGISK // LINK` in compact uppercase mono lettering. The existing status colours, breathing dot, verdict text, accessibility label, page navigation, idempotent construction and `asb-fit-c2` label hiding are unchanged.
- WebUI presentation only: no Governor, Smart classification, Monitor cache, Zygisk, thermal or battery policy changed. Runtime regression coverage checks the brain geometry and both consumers, all six labels, repeated header construction and compact hiding. Chromium mobile verification covered selected/unselected Smart, dark/light/Glass, the Battery settings section, widths from 300 to 480 px, no JavaScript errors and no horizontal overflow.

**fix292 — honest Smart load provenance and a complete first Monitor paint**
- The native Smart classifier still uses the same package table and heat/GPU/FSM inference for its performance policy, but now publishes whether GAMING came from a positively recognised package or from that heuristic. The same provenance is reset and published by the manual-profile foreground classifier. No frequency, thermal, Battery-suppression or Zygisk policy changed.
- Monitor no longer presents every hint 4 as a confirmed game. A heuristic result is shown as "high · GPU" in the heavy-load colour, with a tooltip explaining that it was estimated from CPU/GPU load and heat and that no game was positively identified. Package-confirmed games retain the gaming label and colour; warm-up and unknown values remain neutral.
- The existing display-only Monitor snapshot now includes the complete Smart card: drain and ETA values, slot, confidence, battery lean, load, basis, slot heat, trend, modem mode, rendered classes and tooltips, the bucket pill, card visibility, section placement and drain-strip home. It opens together with the nine live cells, dimmed until a fresh reading replaces it. The same 30-minute TTL, profile and language ownership apply; no raw source counters, package identity, new root shell, timer or persistent worker were added.
- Regression coverage exercises the real manual classifier for confirmed versus inferred games and reset on camera/media/screen-off, all three Smart inference branches and both state publications, confirmed/inferred/warm-up WebUI rendering, complete Smart-card capture/restoration, profile/language/TTL rejection and absence of raw Smart state in the view cache.

The entries below document field findings from an OnePlus 15 (CPH2745, SM8850), an
OnePlus 12 (CPH2691, SM8650) and an OnePlus Ace 6 (PLQ110, SM8750), together with
host-verified audit fixes. Behavioral changes are covered by a contract or runtime test.
Sections further down are the V63 → V64 notes, kept as history.

**fix291 — README technical notes without build numbers, unambiguous Safe mode actions and stricter report evidence**
- All README files now describe behavior without `fixNNN` references. Historical implementation comparisons remain where they explain a technical constraint; the changelog remains the version history.
- The Device page's Safe mode button now names the action it will perform — Enable or Clear — instead of repeating the current state. The underlying commands and Safe mode semantics are unchanged.
- Infinite-log Zygisk evidence now projects the existing vetoed/unavailable/throttled launch counters, slow/fast/fallback launch classes, denylist-flagged starts and screen-off hint suppression. The report shows their deltas where available. It distinguishes accepted start/exit events from spawn, cold-start and ledger channels, explains why zero events and a currently empty validated live set do not erase historical activity, and calls accepted cold-start hints requests rather than proven ceiling changes. Counter resets and one-snapshot captures still produce unknown deltas.
- Report precision: Smart measurements recorded during Battery or another manual profile no longer claim active Smart control; at-cap correlations no longer justify generic higher-ceiling advice when the measured split does not support it; a predominantly ROM-held prime cluster is not blamed on ASB; thin or missing HWUI samples receive an explicit unknown-evidence explanation; SystemUI native-stack attribution is a hypothesis to verify, not a sole-cause verdict; both current-sensor notes now describe battery-counter %/h values as resolution/window-bound estimates, not exact rates.
- No native Governor or Zygisk policy change was made: the supplied capture does not justify new frequency writers, a second governor, broader package policy or periodic polling. Regression fixtures cover the new observer channels, launch classes, resets, single snapshots, Safe mode commands, manual-profile Smart records, ROM-owned caps, thin frames and crash hypotheses. Chromium rendered the supplied capture in Russian with no JavaScript error or horizontal document overflow.

**fix290 — Monitor and the infinite-log report open from their last complete view**
- Monitor now restores all nine already-painted live cells, not just the drain meter and ROM card, as soon as the page opens. The snapshot is local to this WebView, expires after 30 minutes and belongs to one profile and language; it is dimmed until a fresh read replaces it. Only display text, metric classes, labels and tooltips are saved — never CPU-delta or thermal-trend source counters — so an old view cannot contaminate a new measurement. The existing start-up read now runs after 250 ms instead of 1.5 s and can prime that view in the same batched root shell; no timer, worker or extra shell was added.
- The infinite-log report opens the last complete digest at once (up to 7 days, this viewer only), marked as a snapshot with its timestamp while it refreshes. A first-ever opening gets the existing animated loading card, and the digest root call waits for a painted frame. Concurrent opens share one digest read. A failed refresh preserves the last good report; `no_capture` clears it, and a read completed after leaving the page updates only the cache.
- Tests cover display-only capture, profile/language/TTL ownership, absence of source counters, one-shell priming, cached and first-load report opening, refresh coalescing, failure preservation and no-capture/closed-page behaviour. A real Chromium run with a delayed root bridge checked cold and warm opening, all nine cells, fresh replacement, Russian mobile layout, dark/light themes, report-failure preservation, no JavaScript errors and no horizontal document overflow.

**fix289 — the green Zygisk dot breathes**
- The Zygisk dot in the header pill and on the link card pulses slowly (3.6 s) while the link is green (connected, confirmed, quiet), like the profile dot beside it; waiting, stale, safe mode and unknown stay still. Opacity and scale only, so the compositor animates it without a repaint; reduced motion stops it. WebUI only, no native change. Test: the green states pulse at that pace, the others do not, the keyframes touch only opacity and transform, and reduced motion stops both dots.

**fix288 — the capture says why a frame was late, a Battery lift releases the light-idle GPU step, and the hourly wakelock pass reads battery statistics once**
- Smoothness evidence: a Battery capture read 44 % janky frames in LIGHT_IDLE, and nothing in it could say whether ASB's ceilings held those frames. Its LIGHT_IDLE intervals were one app streaming text untouched (43 % of its frames late there, 26 % in MODERATE) and SystemUI's per-second redraw, which misses its deadline about once a second in every state. Another chat app streamed at 60 fps with under 0.1 % late frames under the same light-idle ceilings (GPU at 160 MHz) in an earlier capture, and a 6-second window with the CPU fully lifted still had 50 % late frames - so no ceiling change is made on this evidence. The recorder now keeps, per screen-on interval, the app with the most janky frames and SystemUI with Android's own per-frame data from the same graphicsstats dump it already reads: slow UI thread, slow draw commands, slow bitmap uploads, the interval's frame-time and GPU-time percentiles (histogram deltas), frames whose GPU work alone took 8/16 ms or more, and the GPU ceiling (kgsl level and MHz) - `jank_detail.tsv`. The report prints "why frames were late" per app and ASB state with a cause (GPU, UI thread, RenderThread, GPU at 120 Hz only, or the app pacing its own frames) and, for an app seen in two states, its GPU-over-a-frame share under each ceiling - the number that decides whether the light-idle GPU step costs frames. The per-poll file keeps histograms only for apps that drew since the last poll, so it stays a few kilobytes.
- WebUI report: the breakdown, a line in the smoothness cause naming the app with the most late frames and why, and - when one app pacing its own frames holds at least half of the late frames - advice that a profile with higher ceilings would not remove them, instead of sending a Battery day to Smart or Balanced.
- Battery lift and the GPU: Battery's light idle draws at `bat_light_idle_gpu`, the lowest GPU step, and every lift (wake, tap, app switch, lock press, cold start, jank guard) raised the CPU ceilings and the top-app uclamp only. Wakes and touches leave light idle by themselves (fix240), the jank guard's lift did not: in the capture it fired four times in LIGHT_IDLE for the streaming app, "ceilings to 64 %", and left the GPU on the light-idle step each time (the samples taken inside those windows read 160 MHz). For the length of a lift the GPU ceiling is now Battery's own light-idle envelope without that step (40 %, under every other profile); devfreq still picks the clock and the ordinary expiry hands the step back. Counted per lift (`unlock_gpu_lifts`, in asbdiag). Native change: the governor needs a CI rebuild.
- Load: the hourly screen-off wakelock pass read the full battery statistics up to four times (twice for the kernel-wakelock fallback where debugfs is absent, as on the OP15, once for the app ranking, once for Wi-Fi multicast), history included. It now reads them once per pass, since the last charge only (`--charged`, with a plain read where a ROM refuses the option), and every parser takes that one copy.
- 13 new WebUI strings in 13 locales. Tests: the Battery lift's GPU release (Battery only, never lowering, never managing an unmanaged GPU, once per lift, handed back), one battery-statistics read per pass and the plain fallback, the collector over graphicsstats dumps with histograms (percentiles, GPU over 8/16 ms, the ceiling, an idle app's "?" record, a pruned day, screen off, an older capture), the report and digest causes, and the WebUI breakdown, cause line and advice in Russian. No battery or speed figure is claimed.

**fix287 — the Zygisk allowlist works again where every app is flagged for module unmounting, automatic setup shows that it is on, the infinite log stops with one tap, the wakelock picker always has something to choose, and pages paint before their root calls**
- Zygisk observer: fix286 kept the library out of every app the root manager flags for module unmounting (`PROCESS_ON_DENYLIST`). A root manager can set that flag for every app without root by default - a field capture had 434 of 465 process starts flagged - so no allowlisted app kept the observer: `loaded_processes` and `events_total` stayed 0 over 3.5 h, with no exit record and no lifecycle refresh; only the one-shot start record and the cold-start lift still ran. The flag is counted only; observation is as in fix285. Native change: the Zygisk libraries need a CI rebuild.
- Launch classes: an app with hook modules but fewer than 3 measured cold starts is slow only once the median of its measured starts is a second or more. fix286 classed every hooked app - 27 on the field phone, most never opened - and gave each a 6-second lift.
- Zygisk page, header and Actions: `link-status` read its state from `/data/asb` instead of `/data/adb/asb`, so automatic setup, the observed-app count and safe mode always read off/0 there (and in the capture's Zygisk section). Pressing "Set up automatically" said it was on while the card still offered setup. Both collectors now read the same root. The setup, refresh, turn-off, mode, guard and ART buttons show their working state before the shell runs.
- Root calls through a synchronous WebUI bridge block the page's thread, so a loading state set just before one was never painted: the Device page was blank for seconds although its loading card was already in the page. `asbPaintYield` lets that frame through first (and finishes in a hidden page). The Device page also shows the last snapshot at once (kept for 7 days, this viewer only), dimmed and stamped, replaces it when the fresh read returns and keeps it on a failed refresh; Save stays off until the data is fresh.
- Monitor: the battery-and-system card waited for three root shells in a row on a page the WebView recreates on every visit. The drain meter and the ROM snapshot now ride the governor's shell (one shell per pass), and the last readings (30 minutes at most, this viewer only) draw the card at once, dimmed until fresh; counters measured between two reads (CPU busy, thermal trend) are never restored.
- Infinite log: after Stop, the recorder finishes its report (a minute or more on a long capture), but the status said "running" all that time, so the menu offered Stop again and the second signal cut the report short. The helper now reports `stopping` (with its start time) until the recorder exits, a repeated stop sends nothing, and the recorder ignores further signals while it finalises (the forced end after 240 s stays). The menu shows "Stopping · finishing the report…" and says no second tap is needed.
- Wakelock freeze picker: Android counts app wakelocks only on battery with the screen off and starts over after a charge, so after a night on the charger the picker was empty. The hourly screen-off pass and every opening of the picker add the held time to ASB's own 7-day history (`wakelock_hist`, a counter reset counts as new time), rows rank by the larger of "since unplug" and 7 days, and every other user app can be chosen from a searchable list (no wakelock evidence is claimed for those; the same confirmation, read-back and restore apply).
- 13 new and 5 changed WebUI strings in 13 locales (2 removed; `unit_s`, used by the wakelock picker since fix276, existed in none and printed "15м 23s"). Tests: the allowlist observed with the unmount flag set, hooked apps without a slow measured start left normal, link-status reading `/data/adb` without overrides (auto mode, observed apps, safe mode), the busy label during automatic setup, the stopping state and single signal against a slow finaliser, the recorder's uninterruptible finalisation, the Device page order (loading or snapshot before the collector, snapshot kept on failure, 7-day limit), the Monitor cache without between-read counters and one shell per pass, the paint yield in a hidden page, the wakelock history across a counter reset and a charger night, its 7-day window, the hourly pass feeding it and the other-apps list. No battery or speed figure is claimed.

**fix286 — one engine: per-app launch classes from measured cold starts and hook-framework scope, carried by Zygisk to the governor; the guard spares hook-module apps, apps hidden from root never keep the observer**
- Launch classes: `runtime/asb_zygisk_link.sh` joins Android's launch log with the hook framework's scope (read-only, through the governor's database reader). An app with 3+ measured cold starts and a median of 1000 ms or more is slow, 400 ms or less fast; before 3 starts are measured an app with an enabled hook module scoped to it is slow. Protected names are never classed, at most 64 a class, written to `zygisk/classes` only on change and withdrawn with the cold-start lift, the observer or safe mode. The policy sync builds it without reading logs; the half-hourly service pass refreshes it and reads the launch log itself when ART is off.
- Companion: a top-app cold start now names its package to the root companion, which looks up the class (the file is re-read only when its inode, size or mtime changes) and sends a fixed opcode, `zygisk-launch-long` or `zygisk-launch-short` beside the plain `zygisk-launch`; no package reaches the governor and a launch-only record's name is not stored. A governor that does not answer a class opcode gets the plain one. The classes are a separate file, so a library built before this change never meets an unknown policy key. An app the root manager hides root from (`PROCESS_ON_DENYLIST`) never keeps the library or a socket; its one-shot record is sent before specialization and counted (`denylist_spawns`). New companion counters: `launch_long`, `launch_short`, `launch_class_fallback`, `classes_loaded/slow/fast/reads`. With the screen off as the governor published it, the companion no longer sends a lifecycle refresh the governor would only wake up to veto (`hints_screen_off`); an unknown screen state still asks.
- Governor: a slow app's cold start carries the running lift to twice `unlock_lift_s` from its start (10 s at most) or arms a lift that long; a fast app's arms half (1 s at least) and ends early only a lift its own tap or app switch armed within 1.5 s - never a wake's, a first touch's or a lock press's. Two requests between passes: the longer need wins. Profile, thermal and warm-die gates are unchanged. Counters `zygisk_launch_long/short`, `unlock_cold_long`, `unlock_cold_trims`. Native change: the governor and the Zygisk libraries need a CI rebuild.
- Background guard: an app that is an enabled hook-framework module is never restricted (its own process may be what the module needs); the list is refreshed with the classes. ART compiles slow-starting apps first, and the launch count it shows is unchanged.
- The Zygisk page gains the "One engine" card and asbdiag `link_class` / `link_gov` / `link_hooks`: the classes in effect, the governor's class counters, the hook-framework inventory, other Zygisk modules (name and on/off, read-only), the cold-start median of hooked against unhooked apps (different apps, not the hooks' cost) and one row per app joining class and reason, hook modules, opens, background starts, guard, ART and protection lists. Collector keys `launch_long`, `launch_short`, `launch_class_fallback`, `launch_classes_loaded`, `launch_classes`, `denylist_spawns`, `hints_screen_off`. 43 new WebUI strings in 13 locales; the 15 automatic-setup strings from fix284, which were still English in 11 locales, are translated.
- Tests: the native classes parser (bounds, duplicates across classes, protected names, unknown keys, version), frame validation for named launch records and the denylist flag, the hot path (class opcodes, re-read only on change, nothing stored, old-governor fallback, a broken file = plain lift, denylisted apps not retained, no refresh round trip with the screen off), the governor lift lengths, the trim limited to a tap's lift, merge order and the thermal gate, the real link script against a stubbed hook-framework reader (classes accepted by the native parser, unchanged pass not rewritten, withdraw on lift off and safe mode, module list, per-app rows, the hooked/unhooked comparison, row order and cap, the launch-log scan without ART and not at boot), the guard sparing module apps, ART ordering by class, and the page's parser and per-app text. No smoothness or battery figure is claimed; the counters and per-app medians are there to measure it.

**fix285 — Zygisk ages on a suspend-aware clock, the infinite-log report stops contradicting itself, SystemUI's hook modules are named, ART ranks warm launches**
- Zygisk state age: the companion stamped its state with CLOCK_MONOTONIC and every reader compared it with /proc/uptime, which keeps counting through suspend. After a night of deep sleep the age grew by the whole suspended time: a field capture read "Channel confirmed · quiet - no app process has started for 282 min" in asbdiag, Device diagnostics and the report while the start counter went 337 → 369 → 376 within the same quarter of an hour. The companion now runs its windows (rate limits, hint and launch budgets, the 5-minute screen-off burst) on CLOCK_BOOTTIME and writes `updated_boottime_ms`; the collector compares that with /proc/uptime, and for a companion built before this change uses the state file's own modification time instead of the mismatched clocks. The burst window had the same flaw: on CLOCK_MONOTONIC a night's screen-off starts could fall into one "5-minute" window and read as a restart loop. `state_age_clock` names the clock used. Native change: the Zygisk libraries need a CI rebuild.
- Infinite-log report: a night that slept well (an hour or more, at most 5% awake, at most 1 %/h) no longer draws an awake or never-ending-sync action. The field report ranked "awake 3%: the contacts sync never finishes" first over a 0.5 %/h night with 97% deep sleep, because the gate read one 39-minute stretch and the figure the night. A wake holder is marked only when one of its holds lasted a minute or more ("held in 62% of checks · longest 0 min" was red). The battery section's screen-on/off durations come from the same split as its drain rows and the summary; the sampled coverage had printed 1 h / 5 h 6 min beside "screen on 1 h 21 min: 6.6 %/h".
- SystemUI redraw: the capture records which enabled hook-framework modules are scoped to SystemUI (read-only, through the governor's database reader), the digest carries them on the `sysuidraw` row, and when no per-second source is on the action and the smoothness verdict name those modules instead of a generic "a module". 1 new WebUI string in 13 locales.
- Faster app starts (ART): an app is ranked by the larger of its cold starts (summed across boots) and its launches in Android's launch log, so an app the user opens warm many times is no longer left out after one cold start.
- Tests: the collector's age on the file time and on the boottime stamp (including a deep-sleep case that used to read stale), the native contract for the suspend-aware clock, the good-night case, the one-minute holder mark, the screen durations, the SystemUI module record (enabled and SystemUI-scoped only) with its digest field, tip and verdict, and ART ranking by warm launches.

**fix284 — one-tap automatic Zygisk setup for non-experts, and a meaningful place for Zygisk in Actions**
- A prominent, explicitly opt-in **Automatic setup** card on the Zygisk page removes the need to understand four switches or fill in a package list. ASB selects up to 64 user-installed apps for observation, prioritised by top-app start history already kept for ART and by the current native start ledger, with package-name ordering as the deterministic fallback. It enables the existing Full preset, Background guard level **Loops + night wakers**, and charging/screen-off/temperature-gated ART optimization. The observation list itself never restricts an app: restrictions still require the guard's measured thresholds and retain its protected classes, original-mode records, read-back and restore.
- The previous manual list is saved and restored exactly when automatic setup is disabled; disable also turns off the guard and ART. Safe mode is never cleared automatically. Package-manager empty output is treated as unavailable evidence and preserves the last good list. Existing boot and hourly service passes refresh installed/removed membership — no new worker or polling timer — and an unchanged refresh does not rewrite policy or advance its generation. While automatic setup owns the list, the package editor is read-only and explains how to return to manual editing.
- Actions now places the unchanged read-only **Zygisk · ASB link** evidence after **Sleep** and immediately before **System**, instead of between the profile header and thermal/battery information. Automatic ownership is stated there as well. 15 new WebUI strings in 13 locales and the Actions line in all Action locales. Backend and WebUI runtime tests cover candidate filtering/ranking/bounds, Safe mode, guard/ART state, no-op and changed refreshes, exact restore, the single-shell UI flow, the read-only editor, card placement and Actions ordering. No native change; no performance or battery percentage is claimed without comparable on-device A/B evidence.

**fix283 — the Zygisk guard works with the screen on too: background restart loops, a start history across reboots and one-tap restriction of apps that run in the background but are never opened**
- Screen on: the guard samples the start ledger's background starts (screen-on starts minus top-app starts) on the five-minute tick. A user app whose background processes start 6 or more times in 5 minutes while none of its processes is visible (`dumpsys activity lru`: cached, plain background or not running; anything visible, audible or unknown is left alone) gets `RUN_ANY_IN_BACKGROUND=ignore` for 30 minutes, recorded and read back as before. It is given back early as soon as the app is in use, and on expiry, guard off or uninstall; the screen-on and screen-off edges do not end it. Screen-off restrictions are still lifted at screen-on. The app in front is never counted: its starts are top-app starts.
- Start history: with the guard on, the ledger's screen-off, screen-on and top-app counts are summed across reboots (boot id aware, 96 apps at most). The page and asbdiag list the eight apps with the most background starts since the guard was switched on, with how many were with the screen off and how often the app was opened.
- Apps you never open: after 3 days of history, a user app with 30 or more background starts, no top-app start in that time, Android's own `am get-inactive` saying idle and none of the guard's protections is suggested on the page. One tap (or "Restrict all") sets `RUN_ANY_IN_BACKGROUND=ignore` - the same as "Restricted" in the app's battery settings - with the previous mode recorded and read back. Opening the app (a new top-app start), "Give back", switching the guard off or uninstalling restores it. Each restricted app shows its background starts per day before and after the restriction from the same history.
- The card is now called "Background guard"; asbdiag prints the screen-on holds, the unused-app suggestions and restrictions with their before/after rates, and the background history. 24 new and 1 changed WebUI string in 13 locales. A runtime test covers screen-on loops (visible apps and top-app starts excluded, protected apps logged once, stale samples, the 30-minute hold not ended by screen edges, lifted on use and on expiry), the cross-boot history (no double count in one boot), suggestions (3-day minimum, idle check, protections, top-app starts), restrict and give-back requests (unsafe names, non-user apps, owner restrictions untouched), release on opening, guard off and uninstall, and the WebUI parser; the loop and night-waker tests follow the new record format. No native change; no battery figure is claimed - the before/after rates per app and the history are there to measure it.

**fix282 — the restart-loop guard also restrains night wakers, measures what each restriction held back and summarises every screen-off period**
- A second guard level on the Zygisk page, "Loops + night wakers": an app whose process starts 8 or more times during one screen-off period, at any pace, gets the same restriction as a restart loop (`RUN_ANY_IN_BACKGROUND=ignore`, previous mode recorded and read back) until the screen turns on. The count runs from the first screen-off sample of the period, so an app that starts every 20 minutes all night is caught after a few hours, which the 5-minute loop rate never did. Protected classes, the Doze keep list, notification-fix apps, user-exempted apps, apps the user already restricted and system apps stay untouched; "Restrain loops" behaves as before.
- Every restriction records the start ledger count at that moment. The page, the lift event and asbdiag show how many process starts still happened while the restriction was in place - a direct check that it held, per app.
- Every screen-off period of 15 minutes or more leaves a summary: from the first to the last screen-off sample, how many processes started (all apps, system ones included), how many apps were restricted and the three that started most. The last seven are kept, shown on the page and in asbdiag.
- A protected, refused or already-restricted app is logged once per screen-off period instead of on every tick. 10 new WebUI strings in 13 locales. Runtime tests cover the waker threshold and level, the loops level leaving slow wakers alone, starts while restricted, the period summary (duration from the samples, totals, top three, 15-minute floor, seven kept), once-per-period logging, uninstall and the WebUI parser with old and new status lines; the loop test now checks the starts while restricted too. No native change; no battery figure is claimed - the period summaries are there to compare nights with and without the level.

**fix281 — faster app starts from the Zygisk start ledger: ART compilation of the apps you open, with measured cold starts**
- New on the Zygisk page, off by default: "Faster app starts (ART)". `runtime/asb_zygisk_aot.sh` ranks the apps the user opens by their top-app process starts in the Zygisk start ledger (summed across boots; without the ledger, by the launches in Android's own launch log), reads each app's ART state (`dumpsys package` Dexopt state, `pm art dump` as fallback) and lists the eight most opened. An app running without ahead-of-time code (verify, quicken, run-from-apk and the like) is compiled with `pm compile -r bg-dexopt` - the reason Android's nightly maintenance uses, speed-profile at background priority - only while charging, with the screen off and the battery below 40 °C, at most four apps per run, one run at a time, each bounded by a 15-minute limit. Before each app the conditions are checked again; a screen-on, an unplugged charger or a warm battery stops the run. An app whose compile changes nothing (no usage profile yet) is tried again after 7 days; apps that already have compiled code are never recompiled.
- Measurement next to the action: the service tick reads `wm_activity_launch_time` and `am_proc_start` from Android's events buffer (the ActivityTaskManager "Displayed" lines as fallback), keeps the last 400 launches and marks a launch cold when Android started the app's process for it. The card and asbdiag show each listed app's cold-start median, and for an app ASB compiled the median before and after the compile.
- Compilation is the state Android's own maintenance produces, so there is nothing to give back on disable or uninstall; the feature's files are removed. 26 new WebUI strings in 13 locales. A runtime test runs the real script on stubbed Android tools: ranking and boot-safe counting, primary-ABI state, cold and warm launches from the events buffer and the main-log fallback, no compile with the screen on, without a charger, on a warm battery or beside a live run, a stale lock cleared, weak apps only, bg-dexopt reason, the no-profile retry window, before/after medians, the screen state from the power service when the governor is stopped, clean uninstall, and the WebUI parser. No native change; faster starts and lower JIT work are the documented effect of compiled code, and the card shows the measured result per app instead of a promised figure.

**fix280 — what inside a hook module crashed, and a restart-loop guard driven by the Zygisk start ledger**
- Native crash reports named only the module whose library held the first frame, and cut the frame at its offset note. asbdiag, the infinite-log report and Device diagnostics now read each tombstone further: the crashing thread, the Cause line, the failing function inside the injected library (offset and build id removed), the module's own Java classes on the crashing stack nearest first (platform frames dropped), and whether a hooked method was running. asbdiag adds one line per module: which processes it took down and how often, its failing function, its classes on the stack and, when the hook framework's database is readable, the apps it is enabled for. Device diagnostics gains a per-module count of native crashes (`tombstone_hooked`); two or more in one module become a finding. WebView and Chrome libraries are still named as shared browser code, never as a hook.
- Restart-loop guard (Zygisk page, off by default): with the screen off, a user app whose screen-off process starts in the Zygisk start ledger grow by 6 or more per 5 minutes between two service ticks gets `RUN_ANY_IN_BACKGROUND=ignore`, its previous mode recorded first and read back after the change. Screen-on (through the screen-transition tuner), switching the guard off or uninstalling gives every recorded mode back. Messaging, mail, alarm, navigation, wearable, VPN and authenticator classes, the Doze keep list, notification-fix apps, apps the user exempted from battery optimisation, apps the user already restricted and system apps are never touched; every decision lands in a bounded event log that the page shows. Without the start ledger (mode Off or Response) the guard does nothing and says so.
- The notification fix shows, per chosen app, how many times the Zygisk start ledger saw it start with the screen off since boot (a push, job or alarm waking it), when the ledger is on.
- Zygisk link "quiet": a field capture called the link "No fresh evidence" after 76 minutes without an app process start, although the companion had confirmed the current policy and recorded 438 starts. The companion only writes when a process starts, so a quiet phone is not a lost link. The collector, the Zygisk pill and page, Device diagnostics, the manager action, asbdiag and the infinite-log report now say "Channel confirmed · quiet" with the minutes since the last start; "No fresh evidence" stays for a companion that never confirmed the current policy. The report digest carries the state age.
- Infinite-log diagnosis: an app that restarts its own notification service on a wakeup alarm 30 times or more in Android's battery history (108 in the field capture) gets a Push notifications card with the app and the count. The advice is the app's own keep-alive switch, checked afterwards with the notification fix. With Google services trim on strict the card names that setting first, because it removes the Doze exemption push relies on; the freeze levels are not blamed, they leave push alone. When the screen-off verdict already names the same alarm, its advice becomes this specific one instead of a second card.
- The Zygisk icon was a dot with eight rays, next to the light-theme sun in the same header. It is now a hexagonal cell with a Z; a contract test keeps every icon glyph distinct.
- The Zygisk page reads the connection and the guard in one shell, as before one read. 27 new WebUI strings and 1 new action string in 13 locales. Runtime tests cover the tombstone details and module summary in asbdiag and the report, the per-module native-crash count and finding, the guard against stubbed AppOps and ledger files (sampling, rate threshold, stale samples, protected and owner-restricted apps, lift on screen-on, off and uninstall), the ledger join in the notification fix, the quiet and stale link states in the collector, asbdiag and the WebUI, and the self-push card (threshold, ordinary alarms, the strict-trim variant, merge into the screen-off verdict). No native change; no battery gain is claimed without on-device measurement.

**fix279 — the infinite log survives an Android framework restart, one battery-drain figure on every screen, and a per-app notification fix**
- A field capture stopped when the Android framework restarted under it (SystemUI, the launcher and Bluetooth came back within two seconds; the kernel, the governor and the boot-started workers kept running). The recorder shared the root manager's process session, was killed with the app processes before it could finalise, and the reboot-only resume never ran because the boot id had not changed. The recorder now starts in its own session (`setsid`; `_recorder_cgroup.txt` records `session=`). A recorder lost within the same boot reads `status=resuming reason=restart`, and the five-minute service tick or the next opening of the log menu continues it on the same folder (`full-day-revive`, once; a stop cancels it). The report and its digest count such restarts apart from reboots (framework restart or recorder lost, decided from `sys.system_server.start_elapsed` against the last sample); the gap counts in no phase. While running, the SystemUI watch records the framework start count and calls a whole-framework restart what it is instead of a SystemUI crash.
- asbdiag prints how many times the framework started this boot and when the running one started, counts `SYSTEM_RESTART`, `system_server_native_crash`, `system_app_crash` and `system_app_native_crash`, and lists the newest system-app Java crashes with their exception, a hook-frame flag and the first non-platform frame. The cause of the field restart itself is not in the exported evidence (no system_server crash, watchdog or tombstone record); it is reported as unknown.
- Battery drain: the Smart Monitor tile showed the governor's live window (10.9 %/h over 17 minutes) while the profile card, the comparison rows in the same sheet and the manager action showed the profile average (8.8 %/h), under a sheet title that called the live figure profile history. The tile, the card, the sheet headline, the time to empty and the manager action now use the profile average from the drain meter whenever it has one; the live window is a separate "right now" line with its own time to empty. The governor forecast still stands in where a profile has no average yet. The infinite-log report names the profile average beside the figure of its own recording, and the current-sensor scale reads "about N× low" everywhere, rounded the same way (the manager action printed ×0.42 where the report printed 2.6×).
- Notification fix (Battery → Sleep & Background): the user picks the apps whose notifications come late and taps Fix. For exactly those user apps ASB adds a Doze exemption where there was none, sets restrictive background and wakelock AppOps (package or uid mode) to allow, removes the uid from the background-data denylist and, under Data Saver, adds it to the allowlist, keeps the app on its own keep list (Doze trimming, the wakelock watcher and background trim skip it) and lifts its own per-app wakelock limit. Every original state is recorded first and read back after the change; unticking, an empty selection or uninstalling restores exactly what was there, and the early and half-hourly service ticks re-apply a selection the ROM reset. The notification permission and the ROM's own per-app switches are reported, never changed. Settings that delay push for every app (strict Google services trim, OEM push off, the ROM's own background killer) are listed with a one-tap change through the normal settings path; savers are shown as information.
- The hook-framework collector took a 1970 timestamp at the head of a log as the start of its window (`log_window_min 29879510` on the field phone). It now keeps only the latest continuous stretch of each log (pre-2015 stamps ignored; a jump of more than 6 h forward or 1 h back starts a new stretch); log volume still counts the whole file.
- 53 new WebUI strings, 2 new and 1 reworded action strings in 13 locales. Runtime tests cover the own-session start and the same-boot revive against the real helper, the framework-restart verdict and restart cause, the digest restart line, the unified drain figures in the real WebUI functions, the action priority, the notification fix against stubbed Android state (apply, read-back, re-apply after a reset, exact restore on untick, uninstall and package removal) and the log-window fixture. No native change; no battery or delivery-time gain is claimed without on-device measurement.

**fix278 — a dedicated Zygisk page with one mode control, and page switches that no longer wait for root shells**
- Root managers whose WebUI bridge runs a command synchronously block the page's JavaScript thread for every root shell they start. A browser bench with the bridge modelled that way counted 7 root calls on Home → Monitor, 16 on Monitor → Settings, 11 on Home → Settings, 13 on the Zygisk pill and 5 on every 3-second Monitor poll. Those are now 1, 2, 0, 1 and 1: no root call runs on the tap itself, reads that belong to one screen share one shell (`runBatch`, a per-session marker line between parts), a Settings load younger than 30 s is reused, an unchanged refresh repaints nothing, the config is read once in the background after start-up, and the Zygisk header pill refreshes on Zygisk actions and otherwise at most every two minutes. Call counts are from a desktop bench; the time each call costs on a phone is not claimed.
- Layout work moved out of the frames a page slide starts in: the page-fit measurement coalesces into one pass after the slide, the tab-indicator boxes are measured once (re-measured on resize, scale, language or fit-tier change), and an unchanged Settings hub is kept instead of rebuilt before every slide.
- The Zygisk pill opens its own page instead of Settings → System. It paints at once from the last snapshot and makes one read after its slide: connection verdict, one mode control (Off / Watch / Response / Full; any other combination is shown as a custom set), activity and cost with restart loops and cold-start counts, the observed-app list and safe mode, and the full evidence on request. A mode is one locked write of all four settings plus the policy sync in one shell; the four separate switches stay in Settings → System → Zygisk.
- Device diagnostics no longer waits for the hook-framework collector: its card offers the collection on request (`asb_device_info.sh --lsposed`); asbdiag still collects it in full.
- 31 new WebUI strings in 13 locales. Runtime tests check the batch shape against a real shell (missing trailing newlines, empty and failed parts, a look-alike marker), the deferred and coalesced fit, the absence of root calls on navigation taps, the mode presets and their single write, the Zygisk page's back-navigation level and the on-request hook collection. No native change; no performance or battery gain on a phone is claimed without on-device measurement.

**fix277 — hook-framework evidence, screen-off restart loops and wakelock-manager fixes**
- Device diagnostics gains a read-only card for the installed hook framework: problems and battery evidence per hooked app. The governor binary reads the framework's own module/scope database read-only (`asb --lspd modules`); the collector joins it with the framework's own logs (volume, write rate per hour, error stacks that name a module), crash/ANR records whose stack passes through a hook, CPU time of hooked apps and the Zygisk start ledger. Individual hook calls and their energy are not exposed by the framework and are not estimated; ASB adds no hook of its own. A finding is a correlation to confirm by disabling one module for one app. asbdiag prints the same block with a verdict. The collector runs only when the Device page or asbdiag is opened and writes nothing.
- The Zygisk process-start ledger now records, per package, the peak number of screen-off starts inside any 5-minute window, in a fixed 32-slot ring (no growing container, no timer). Packages with 6 or more appear as `ledger_restart_loops` in Device diagnostics and asbdiag, and the Device page raises an insight. Nothing is restricted automatically.
- The Zygisk companion no longer re-reads `/proc/<pid>/status` of every observed process on each state rewrite: RSS is cached per PID and process start time for 30 s, so a burst of process starts no longer multiplies those reads. The Device page still reads live RSS itself; `rss_reads` in the companion state file counts the real reads.
- Wakelock manager: Freeze now asks for a second tap on the same row within 5 s and shows the risk in the page; the browser confirmation it replaced could return false without being shown in some WebView hosts, which made Freeze a silent no-op. A package already ignored outside the list reports `external_ignore` instead of a failure; an uninstalled package is dropped from the ledger by Restore and by the reapply pass instead of leaving a Restore that can never succeed; one reapply pass lists packages once instead of once per entry.
- The shared LTPO ownership lock treated a lock as ownerless after a waiter had polled five times in total, even when its holder had created it a moment earlier and was about to publish its PID. The holder's PID write then failed (a spurious failure; 2 of 30 runs of the host contention test on fix276), and in the worst interleaving two writers could both hold the lock. Reclaiming now needs five consecutive ownerless observations (about 250 ms); the contention test passed 80 of 80 runs.
- 40 new WebUI strings in 13 locales. Runtime tests cover the read-only inventory (database unchanged), the collector against fixture logs/crash records/process times/ledger, the burst ring, the restart-loop field and each wakelock fix. Native changes need a CI rebuild of the governor and of both Zygisk ABIs. No performance or battery gain is claimed without comparable on-device A/B evidence.

**fix276 — explicit Battery evidence windows and reversible user-app wakelock limits**
- Device diagnostics now opens in the navigation gesture and paints a readable System/Kernel/Battery loading state before the existing on-demand read-only collector starts. Closing or reopening cannot leave a collector worker behind; reduced-motion preferences remain respected.
- Battery drain figures now identify their actual windows: accumulated per-profile screen-on history, the latest complete screen-off window, or long-term screen-off history. The current infinite-log capture carries its own badge, screen-off rates keep two decimal places in every WebUI path, and tooltips state the measured duration. These are presentation fixes, not a claim that separate windows should produce the same rate.
- Battery settings include an on-demand ranked list of qualifying wakelocks from user-installed apps. An explicit, risk-confirmed action sets Android AppOps `WAKE_LOCK=ignore` for only the chosen package; kernel and system wake sources are not management targets. Held time since unplug is ranking evidence, not proven energy cost, and critical communication, alarm, fitness, VPN and foreground-work classes carry a prominent warning.
- Every selection records the original package and uid modes, requires read-back before reporting success, rolls back refused writes, reapplies lapsed restrictions through existing boot/hourly passes, and restores exact original modes on Restore or uninstall. No persistent polling worker, automatic app freeze, APK payload, SoC-specific writer or app-specific governor policy was added. Existing Battery caps, adaptive lift/jank mechanisms, thermal ownership and LSPosed/Zygisk ownership are unchanged; no autonomy or smoothness improvement is claimed without comparable on-device A/B evidence.

**fix275 — Zygisk evidence in Actions, diagnostics, infinite-log reports and asbdiag**
- The common read-only collector now publishes one shared link verdict. Root-manager Actions shows a compact localized summary that separates enabled configuration and staged ABI files from validated live injection, current companion events and acknowledged policy. It performs no sync, starts no worker and changes no Zygisk policy.
- Device diagnostics presents current evidence as four metric cards plus four independent feature states, while retaining the complete raw evidence and allowlist editor. The infinite-log report instead interprets bounded start/latest capture snapshots: it shows counter deltas, policy acknowledgement and coverage limits, marks counter resets honestly and never invents deltas for legacy or single-snapshot captures. Snapshots ride the existing capture/interim/finalization path; no polling worker was added.
- `asbdiag` now leads with a concise human-readable verdict and keeps the complete raw support evidence. Missing evidence remains `unknown`; installed ABI files alone never prove injection, and observed activity is not presented as a cap change, performance gain or energy saving.
- All new WebUI strings are present in 13 locales and all Actions strings in 12 locales. Runtime tests cover shared verdicts, Actions/asbdiag rendering, capture deltas, reset/single/legacy capture cases and localized report fallbacks. Real Chromium checks passed at 360 px in dark and light themes for both new cards without page errors or horizontal overflow. Governor, thermal, vendor and LSPosed ownership are unchanged.

**fix274 — immediate profile status after update and a unified Zygisk surface**
- The installer now restores the human-readable `module.prop` status from the already preserved profile before the update finishes. It changes presentation only: no profile is reapplied and no governor/service starts early. Fresh-install behaviour remains unchanged. The production helper is tested with every supported profile, `none`, malformed state and the snapshot-only update path.
- Zygisk is now the first System subsection. One visual card contains all four existing controls — observer, lifecycle hints, cold-start lift and process-start ledger — plus the detailed evidence verdict. Registry keys, migrations, ownership, apply modes and opt-in defaults are unchanged.
- Every page header has a compact ASB ↔ Zygisk button that opens the unified card. A new read-only `link-status` helper reuses the existing evidence collector; initial load, navigation, setting changes and diagnostics trigger coalesced one-shot reads, never a recurring poller. Sequence checks prevent stale responses from replacing newer evidence. Configuration or installed ABI files alone still cannot claim a connection.
- All new section strings are present in 13 locales. Runtime tests cover five headers, four switches, stale-response ordering, read-only helper output and the exact empty-selection state; real Chromium checks passed at 360 px in dark and light themes without page errors or horizontal overflow. No native Zygisk, governor, thermal or LSPosed policy changed.

**fix273 — an evidence-bounded ASB ↔ Zygisk link indicator**
- Device diagnostics now opens the Zygisk observer card with a compact `ASB ↔ Zygisk` badge. `Connected` requires current state plus validated live PID/start-tick process rows; `Channel confirmed` requires current companion lifecycle/spawn evidence or a nonzero acknowledged policy generation. Installed ABI files and enabled configuration alone never produce either state.
- Disabled, safe mode, empty selection, waiting for selected work, stale state and malformed/missing evidence have distinct labels. A stale capture is historical evidence, not a live connection; missing evidence never becomes proof that Zygisk is unsupported. The indicator consumes the existing on-demand read-only snapshot and adds no worker, timer or polling loop.
- Labels and short explanations are present in all 13 locales. Runtime tests cover the exact fix272 capture shape (enabled, installed ABIs, empty allowlist, launch/ledger off and zero events → `Enabled · nothing selected`), live/recent/stale/safe/disabled/unknown states and rejection of malformed counters. No collector, policy, governor or native Zygisk source changed in fix273; the fix272 native rebuild requirement remains.

**fix272 — Zygisk: a dormant hot path, a cold-start lift and a process-start ledger**
- App processes no longer parse the 40 KB `governor.conf`, read the allowlist or touch `/data/adb/asb`. `runtime/asb_zygisk.sh sync` - run by every helper command, every WebUI Zygisk switch and post-fs-data before zygote - writes one small validated file, `zygisk/policy`, inside the module directory; it is absent when the master switch is off, safe mode is on or nothing is selected. The hot path first rejects isolated, SDK-sandbox, system and app-zygote processes by uid with no syscall, then makes one `open()`: absent policy means `DLCLOSE`. When zygote may not traverse `/data/adb` (EACCES seen once at load), the loader's module-directory fd is used instead of repeating a denied open; a malformed policy observes nothing. Host measurement through the real Zygisk ABI: ≈0.8 µs per fork dormant against ≈70 µs for the previous config parse (x86-64 build host, not a phone figure).
- Companion state moved to `/dev/.asb/zygisk` (tmpfs, this boot only) and is no longer `fsync`ed to flash on every event; it reads the small policy instead of re-parsing `governor.conf` for every hint decision; governor round trips run outside the state lock. Protocol v2 adds a one-shot spawn frame and flags; peer-credential and start-tick validation are unchanged.
- `zygisk_launch` (opt-in, default 0): when zygote starts a new process flagged top-app for an ordinary app, one package-free frame reaches the companion, which sends the fixed opcode `zygisk-launch` (≥1 s apart, ≤20 per minute). The governor checks the opt-ins, safe mode and the screen and feeds the existing unlock lift: a lift armed by the tap is carried `unlock_lift_s` past the process start, and with none running a new one is armed even inside the 5 s anti-chatter gap that refuses a touch. Profile, thermal and warm-die gates are unchanged; nothing writes a cap. Faster cold starts are expected, not measured; the advanced README gives an `am start -W` A/B procedure. New state keys `zygisk_launch_accepted`, `zygisk_launch_vetoed`, `unlock_cold_lifts`, `unlock_cold_extends`, and an asbdiag line.
- `zygisk_ledger` (opt-in, default 0): process starts per package with the screen off and on for this boot, bounded to 128 packages, shown in Device diagnostics as the top screen-off starters. Diagnostics only; nothing is restricted automatically. Costs one short companion connection per app process start while enabled.
- WebUI: two cards in Diagnostics with dependency notes on the master switch, 13-locale card and Device-diagnostics texts, and the master switch description now states the dormant behaviour. Config registry 215 keys, 86 WebUI cards. Host tests drive the real module and companion through a fake loader table (dormant, uid/app-zygote filter, cold start, ledger, allowlist fd, spoofed PID, throttle, missing policy), cross-check the shell-written policy with the native parser and cover the cold-start lift in the unlock-lift fixture. The Zygisk libraries and the governor binary changed; a CI rebuild is required.

**fix271 — early-boot uninstall handback, charger-gated ART compile, per-app Battery scroll hold**
- Uninstall: root managers run `uninstall.sh` early in the boot after removal, before PackageManager, Settings, AppOps and the activity manager answer. Every framework restore without its own deferred waiter failed there silently, and its record was deleted with `/data/adb/asb` right after: standby buckets, location / multicast / wakelock app-ops, frozen GMS components, Doze exemptions, AOD, the tracking / OEM / haptics Settings ledgers, `mobile_data_always_on`, the safe-volume state and avoid-bad-Wi-Fi. These calls now go through `_fw`: they run at once when boot is complete, otherwise they are queued with their values as arguments and replayed by one detached waiter after `boot_completed`, with the Settings wrapper staged beside them. The `heytap_mcs` and `documentsui_fix` baselines are staged with their helpers under `/data/local/tmp` and handed back after boot (three tries); before, removing the module with the push-service card on left that service disabled for good. A runtime test runs the real uninstall blocks against a fake early boot.
- The one-shot `pm compile -m speed-profile -a` requested by `heytap_mcs=off` no longer starts ten seconds after a reboot on battery. It waits for the charger (Charging or Full, checked every two minutes for at most 24 h); with no charger the request stays pending for the next boot, a cancel while waiting is honoured, and a compile cut short by a reboot is recorded as `failed reason=interrupted` instead of reading "running" forever. post-fs-data clears the ART and LTPO locks of the previous boot: a PID reused after a reboot could otherwise keep the ART worker or every LTPO writer locked out. Card, badge and toast texts updated in 13 locales.
- Battery scroll hold, measured per app (`battery_hold_learn=1`, internal). The fix223 hold keeps the Battery lift up while a finger stays on the glass; a 3 h Battery evening showed it halving one feed's janky frames (14.8 % → 7.6 %) while two other apps were as smooth either way, and the lifted intervals drew 1.4-1.8× the current. Windows of Android's frame statistics now alternate hold / no hold per app; the hold is kept where it removes a quarter of the janky frames and at least 1.5 points after three windows and 4000 frames a side, released after six windows a side without that, and kept when frames are too few or absent. A released app still gets every armed lift (wake, app open/close, first touch, lock press), only not the finger extension. Thermal caps and jank-guard lifts spoil a window; SystemUI, launchers, games and the camera stay out; probes run only while the app in front is under test (every 3 min). Verdicts persist in `/data/adb/asb/battery_hold.tsv` (24 apps, LRU), are retested after 21 days and are cleared by the Smart reset. New state keys `battery_hold*`, an asbdiag line, a digest `bhold` row and a log-report line in 13 locales. `battery_hold_learn=0` restores the previous behaviour.
- Battery jank guard: its SystemUI window never had data, because the frame probe wrote only the package it was asked for. `asb_gfx_probe.sh` now answers up to four packages from one dump (one line each, never summed) and the guard asks for SystemUI beside the app in front. The guard does not lift an app whose hold was released.
- Route windows: the VPN check also catches per-app VPNs that do not cover uid 0 and IKEv2 / PPP tunnels - any `tun*`, `ipsec*` or `ppp*` default route in any table now leaves the physical route windows stock.
- Log report: the steady-redraw verdict names the app that janked in at least 80 % of the screen-on intervals, not only the app with the most janky frames; a bursty foreground app no longer hides a steady SystemUI redraw.
- Pressure scale: an idle Adreno `gpu_busy` of `0 0` reads as 0 % instead of dropping the GPU weight.
- The governor binary changed (no new gcc/clang warnings at debug 0/1); a CI rebuild is required. Config registry 213 keys; the WebUI control count is unchanged.

**fix270 — Smart-summary success colour and verdict-marker spacing**
- Replaced the undefined `--ok` custom property with the established `--bat` success colour everywhere it was used: report evidence segments, verdict labels and markers, device snapshot borders and the pressure scale. Dark and light themes therefore use their existing green success palette instead of an unresolved declaration. Normal, attention and unknown semantics are unchanged.
- The verdict grid now changes only block padding; it no longer erases the inline-start gutter and places the status dot over the first Cyrillic letter. Regression covers the resolved success colour and both padding rules. No diagnostic threshold, verdict or measurement changed. Metadata agrees on V65 / 65270.

**fix269 — CI executable-mode restoration and workflow safety-baseline synchronization**
- Both module-build workflows now restore the executable mode of all four package-tweak helpers before regression: `asb_package_state.sh`, `asb_heytap_mcs.sh`, `asb_art_compile.sh` and `asb_documentsui_fix.sh`. A browser upload can turn git mode 100755 into 100644 even though the source ZIP is correct. The regression checks every CI entry point, and the extracted workflow step was executed against mode-0644 fixtures before the package contract passed again.
- The CI failure for `asb_aosp_mutable.before` came from an older `.github/workflows/build-dsp-attach.yml` in the repository, not from Zygisk or the fix268 archive. The required pre-mutation AOSP evidence gate remains mandatory and is now documented at the snapshot itself. When importing this source archive, replace the whole tree including `.github/workflows`; keeping an older workflow intentionally fails the safety contract rather than silently building without mutation evidence.
- Deleted-folder resume cancellation now writes `resume=dir_missing` before removing the resume marker. A loaded host can therefore no longer observe a completed cancellation with its recovery note not yet published; the existing no-wait runtime assertion remains strict. Metadata agrees on V65 / 65269.

**fix268 — deterministic native-warning CI and bounded Zygisk lifecycle refresh**
- Fixed the fix266 GitHub Actions failure without raising the warning budget or weakening the site ratchet. GCC changes diagnostic apostrophes to Unicode quotes under a UTF-8 locale, so all 60 reviewed sites were falsely reported as new and resolved together. The compiler now runs under `LC_ALL=C`; real GCC passes from a UTF-8 caller, and a fake-compiler regression proves that a genuinely different warning still fails with the same total count.
- Added separately opt-in `zygisk_hints=0`. Accepted allowlisted process start/disconnect events may send only the fixed `zygisk-refresh` opcode to the existing governor, with a 100 ms bounded round trip, 2-second spacing and 8 requests/minute per active companion. Screen-off, safe-mode, disabled and malformed paths do not refresh. The governor invalidates stale foreground evidence and schedules fresh metrics without forcing writes, selecting a profile or bypassing dwell, thermal or vendor gates. There is no Zygisk frequency writer, application killer or LSPosed kill/freeze/hide/throttle policy.
- Device diagnostics now expose attempted, acknowledged, vetoed, unavailable and locally throttled hint counters. Acknowledgement means fresh-evidence evaluation only, not a cap change or measured energy saving. Documentation includes a repeatable on-device A/B procedure that accounts for the additional refresh/probe cost; no universal performance or battery percentage is claimed. The registry now has 212 keys and WebUI has 84 controls. Metadata agrees on V65 / 65268.

**fix267 — opt-in Zygisk Process Observer and an evidence-bounded system-pressure scale**
- Stage 1 adds real arm64/arm32 Zygisk process-lifecycle observation, disabled by default with an empty allowlist. Only newly started,
  explicitly allowlisted ordinary app processes are selected; protected system/root/vendor processes are excluded and existing apps are
  never killed to apply configuration. A bounded versioned companion protocol validates peer PID and process start ticks, suppresses
  duplicates, rate-limits events, caps live/rate state and records peer-disconnect exits. Safe mode fail-opens the app path, and no JNI/PLT
  hooks, application/LSPosed/Zygisk/module management, governor connection, frequency writes or policy opcodes were added.
- Device schema 5 adds a detailed 0–100 pressure heuristic with measured values and component weights: load 35, memory 30, a 0.20-second
  on-demand CPU sample 25 and supported `gpu_busy` evidence 10. Missing components lose their weight and the remainder is renormalised;
  below 40% measured coverage the score is `unknown`. Bands are 0–24 light, 25–49 moderate, 50–74 high and 75–100 very high. Swap/zRAM
  occupancy is supporting evidence only. This single snapshot is not a device-health score, trend, battery/performance-saving estimate or
  persistent sampler.
- Device diagnostics and `asbdiag` expose observer configuration separately from installed ABI and validated live process events, plus
  bounded drops, IPC wakeups/CPU and freshness. RSS is the sum of current application VmRSS for validated PIDs, not pure observer overhead;
  crash/ANR attribution and foreground/media/camera/audio/navigation events remain `unknown`/`not exposed`. All 13 locales include the new
  scale and observer editor; allowlist and safe-mode commands are documented. The registry now has 211 keys and WebUI has 83 controls.
- A sixth host regression suite exercises native aggregation/protocol rejection, allowlist/safe mode, formula/coverage, stale state, PID
  reuse and WebUI command validation. Existing five suites and lint remain mandatory. These host checks do not prove Zygisk injection or
  companion compatibility on a particular physical device; that still requires an on-device test. Metadata agrees on V65 / 65267.

**fix266 — independent HeyTap MCS and DocumentsUI patches with one-shot ART**
- Two separate opt-in WebUI controls replace the need to embed third-party module ZIPs or APKs. HeyTap disables
  `com.heytap.mcs` through PackageManager without a `.replace` overlay; DocumentsUI independently enables/unhides the system
  picker, resets its picker/files activities and disables ColorOS File Manager for user 0. Both preserve exact pre-ASB states,
  restore only fields ASB owns, and are restored on uninstall. Pre-disabled packages are not claimed or re-enabled.
- HeyTap alone creates an ART request. After the next completed boot, the root service consumes it with
  `pm compile -m speed-profile -a`, bounded by a lock and a default 1800-second timeout. Reapplying Off is idempotent, a
  completed or failed request is not re-armed, cancel before boot prevents compilation, and failure has no automatic retry.
  DocumentsUI has no ART or boot writer. Uninstall never performs a mass ART reset.
- Android-like fixtures cover enabled states 0–4, short/full component names, unknown dumps, rejected writes, readback
  rollback, changed-fields-only restore, exactly-once ART, cancellation and WebUI badges. All 13 locales carry both cards;
  asbdiag reports their status read-only. The registry now contains 209 keys (30 user, 52 advanced, 127 internal) and WebUI
  has 82 controls. `CONFIG_SHAPE` changed only by those two additive cards; every pre-existing stored value keeps its meaning,
  so schema 3 needs no migration. Metadata agrees on V65 / 65266.

**fix265 — VPN-safe route windows and reconnect-exact handback**
- A CPH2769 field report lost Internet with adaptive network buffers while a VPN owned the default route through `tun0`. Its
  before/after evidence keeps `tcp_mtu_probing=1` in both states, so MTU recovery is not the changing parameter; the visible
  ASB delta is `initcwnd/initrwnd` on the underlying Wi-Fi/mobile routes. While a VPN owns the default, the route-window writer
  now leaves those physical routes stock and removes only window attributes it installed earlier. Congestion, qdisc, global TCP
  buffers and the independent MTU helper are unchanged.
- Route originals are tracked per address family, interface and table. A reconnect with a new gateway captures a fresh baseline;
  off and uninstall restore only the original window values on the current route rather than replaying a stale route line or
  erasing another owner's `congctl`. Legacy state is accepted without ever replaying `tun*` routes.
- The Android-like runtime fixture covers VPN-first apply, VPN entry after tuning, physical-route replacement, off, uninstall,
  pre-existing window values and tunnel exclusion. Source tests verify ownership and restore behavior; field connectivity still
  needs confirmation on the reporter's device. Metadata agrees on V65 / 65265.

**fix264 — serialized LTPO ownership, explicit config consumers and stronger native/CI evidence**
- Touch, video and range LTPO operations now share an atomic `mkdir` ownership lock. Their Settings writes and `orig=` metadata
  updates are serialized, unrelated record fields are preserved, dead-owner recovery is bounded, and failed restores remain
  retryable. Touch gains transition-only heartbeat evidence without misclassifying a healthy blocking `getevent` as stale; a
  one-time probe falls back to integer sleep where fractional delays are unsupported.
- MTU probing keeps its exact original `0/1/2` baseline and uninstall handback but no longer rewrites an already-correct live
  value. All 207 shipped configuration keys now declare `shell`, `native` or `both` consumption, checked against the real native
  parser and shell references by lint and regression contracts.
- The GCC warning-count ratchet is joined by a 60-site inventory that rejects new warning sites independently of the total;
  test and release CI exercise both GCC and clang. DSP AOSP workflows publish before/after hashes and changed-file artifacts
  without claiming that source-only validation proves DSP runtime or release compatibility.
- A deterministic native property fixture performs 433,334 checks over randomized 2/3/4-policy mappings and cap compositions:
  stricter ceilings cannot raise results, thermal emergency can bypass the ordinary floor, enumerated results stay on real OPPs,
  effective minima remain bounded by maxima, and non-enumerable tables retain the documented kernel-rounding path.
  Metadata agrees on V65 / 65264.

**fix263 — presentation-grade documentation and the full Smart decision model**
- All four READMEs now use large GitHub-style button badges for four-way navigation instead of ordinary inline documentation links.
  The quick-start guides present ASB as a coordinated OnePlus control layer and expand Smart with readable signal, decision,
  learning and real-life scenario tables while keeping installation and everyday guidance simple and release-neutral.
- Both advanced guides gain thematic emoji throughout all 21 main sections, 63 subsections and nested technical blocks. Their
  Smart chapter now contains 13 matching technical subsections: 12 scenario buckets, five-level fallback, confidence and time
  decay, learned policy outputs, device-relative thermal/drain history, screen-off/night/low-battery layers, charge-aware
  protection, per-app heat, thermal trends, session debt, evidence processing, checked feedback I/O and bounded prime escape.
- Language structure, local links, Markdown tables and the complete 80-control index were checked in parallel. Runtime,
  native, WebUI and policy code are unchanged; metadata agrees on V65 / 65263.

**fix262 — two-level documentation for users, testers and developers**
- English and Russian quick-start READMEs were rebuilt around the complete product surface: five profiles, native governor,
  Smart, thermal and battery policy, every audio/DSP group, camera, network, interface, haptics, system controls, WebUI,
  reports, privacy, compatibility and troubleshooting. Parallel tables, clear trade-offs and four-way navigation keep the
  normal entry point accessible without version- or changelog-specific content.
- New `README.advanced.md` and `README.advanced.ru.md` provide matching 21-section technical guides: ownership and
  evidence semantics, six governor states, bounds schema 3 and complete policy provenance, Smart feedback/gates/counters,
  thermal coexistence, all 80 WebUI controls, DSP/AIDL boundaries, diagnostics, comparable A/B methodology, source layout,
  build/regression workflows and field-test playbooks. Each advanced guide is about 3.3 times its quick-start counterpart.
- Release and test packaging exclude both advanced guides just like the existing READMEs, so repository documentation
  does not become flashable payload. Runtime, native, WebUI and policy code are unchanged; metadata agrees on V65 / 65262.

**fix261 — product documentation rewritten for current ASB**
- English and Russian README files now present the current product in clear, parallel, version-independent language: five profiles,
  Smart, battery and sleep tools, thermal behaviour, DSP, camera, network, WebUI, reports, privacy, safety and installation.
  Obsolete Debug-ZIP instructions, internal implementation tables and changelog-like release details were removed from both READMEs.
- Developer validation remains available in a compact collapsible section. Runtime, native, WebUI and policy code are unchanged;
  metadata agrees on V65 / 65261.

**fix260 — complete CPU-policy provenance, bounded feedback I/O and darker Liquid Glass**
- Device-adaptive bounds schema 3 now proves every physical 2/3/4-policy CPU cluster, not only the little/mid/big representatives.
  The canonical policy map records each numeric policy ID, native writer slot, hardware maximum and exposed OPP count/min/max.
  Shell and native independently reject a changed fourth policy, logical role, writer mapping or OPP table before importing a bound.
- Discovery and both diagnostic commands expose the full physical map; missing evidence remains `not exposed`, never proof that the
  hardware is unsupported. The existing native writer is reused, with no new SoC-specific policy, persistent worker or background
  device collection. Old schema-2 files fail closed until fresh synthesis.
- Smart log-feedback counters use checked 64-bit parsing and bounds before arithmetic. The governor still uses the existing
  ten-second gate, but avoids re-reading an unchanged body by comparing device, inode, size and nanosecond mtime/ctime; atomic
  replacement is always noticed. State JSON exposes check/read/change/unchanged counters for future field cost measurements.
- Source-only validation now has the explicit `bash tools/asb_source_regression.sh` entry point. The full runner prints its mode
  and whether DSP reference prebuilts are optional, strict or absent; release strictness and the native warning ratchet are unchanged.
- Shared and active dark Liquid Glass surfaces are slightly darker and denser. The exact approved inactive-profile/OFF-tweak
  materials, neutral icon wells and switch tracks are unchanged, as are ordinary Dark/Light and light Liquid Glass.
- Regressions cover complete topology/OPP rejection, overflow inputs, unchanged and atomically replaced feedback, source-only
  mode, protected Glass tokens and native `-Werror`. Chromium exercised all five profiles at 320, 360 and 412 CSS px in all four
  themes, plus real Config OFF/ON cards, without JavaScript errors or horizontal overflow. Metadata agrees on V65 / 65260.

**fix259 — consistent Liquid Glass OFF cards and clearer Monitor scales**
- Disabled tweak cards in dark Liquid Glass now use exactly the same quiet, nearly black material, neutral border and inset
  highlight as inactive profile cards. Their icon wells and switch tracks use the same restrained neutral shades. Enabled
  tweaks, ordinary dark/light themes and light Liquid Glass retain their existing materials.
- The “who set the limit” detail sheet now preserves source colours as well as the Monitor tile: ASB is the theme green and
  Shell remains blue in all four palettes. Vendor clamp/raised semantics are unchanged, and Stock still reuses the element
  for battery temperature without retaining an ASB owner class.
- Battery & Smart detail scales now use the same seven-step semantic palette as their tiles. Confidence, headroom, battery
  level and CPU ceiling remain reverse scales; activity states, charging, uptime, battery lean and other plain facts do not
  become quality grades. Verified/stable Smart evidence is positive, fallback/warning evidence is visibly a warning, and
  unknown or warming-up values stay neutral. Confidence has dedicated labels in all 13 locales.
- Battery current is normalized to `%/h` using charge capacity, while GPU and per-policy CPU clocks are normalized against
  their exposed hardware maxima before a scale is drawn. A missing denominator hides the scale instead of inventing a
  severity. Stock's die-max fallback uses the CPU temperature scale rather than the board scale.
- Runtime and static regressions cover source colours, scale/tile agreement, normalization, all seven confidence labels and
  Stock fallbacks. Chromium exercised Smart, Battery, Balanced, Performance and Stock at 320, 360 and 412 CSS px in all
  four themes, then compared real Config OFF cards with inactive profiles, without JavaScript errors or horizontal overflow.
  Metadata agrees on V65 / 65259.

**fix258 — Smart V6 log-assisted learning, per-device profile ranges and kernel BPF evidence**
- Device collection schema 4 adds separate read-only BTF, eBPF and FUSE-BPF evidence. Kernel configuration, standard runtime
  interfaces and verified active behaviour are not conflated: generic FUSE or BPF never proves FUSE-BPF, an exposed `not set`
  configuration is not positive evidence, and an absent standard path remains unknown rather than proof of unsupported hardware.
  Kernel origin is only an indicative stock-like/custom-like classification, never provenance proof. Device diagnostics explains
  these distinctions in all 13 locales without collecting serial numbers, account data or network identifiers.
- Smart V6 consumes bounded, fresh, deduplicated jank hints from the existing infinite log to schedule an earlier native
  smoothness A/B window. The log does not write settings or become a second parameter owner: the governor re-reads real
  GraphicsStats, counts every window once and applies scenario, freshness, cooldown, charging/thermal and plateau gates. A
  concluded plateau remains closed until the existing 21-day recheck. V4/V5 learned outputs migrate to V6 without being reset,
  and the home Smart badge now displays the native engine version as V6.
- Battery, Balanced and Performance synthesis now emits complete per-policy MIN/CAP/MAX ranges from measured hardware ceilings
  and reference ratios, with 2/3/4-policy topology handling and snap-down to an exposed OPP table. Shell and native import the
  same ranges, reject stale identity/topology evidence and clamp inverted values. Profiles keep distinct policies: Battery's
  jank guard remains bounded insurance rather than Smart learning, Stock still restores the ROM baseline without profile
  management, and Performance receives no universal literal-kHz limit. No new SoC-specific writer or persistent polling worker
  was added; field outcomes still depend on the device, firmware and workload.
- Regressions cover BTF/eBPF/FUSE-BPF evidence and old snapshots, bounded log feedback and plateau suppression, V4/V5/V3 store
  migration, native `-Werror`, 2/4-policy full ranges, OPP snap-down, shell/native parity, Stock and Battery ownership, and the
  live V6 badge. Metadata agrees on V65 / 65258.

**fix257 — exact KSU variants, evidence-led Device insights and working report references**
- Device collection schema 3 separates the KSU interface family from the exact root implementation. When a KSU backend is
  present, the read-only, on-demand collector tries only `ksud --version`, keeps a sanitized first line of at most 160
  characters and names KernelSU, KernelSU Next or SukiSU Ultra only when that response explicitly names the variant. A
  generic `ksu` backend or version-only response remains a KSU-compatible family with an exact variant not exposed and a
  fork explicitly possible; empty or malformed evidence never becomes proof of an unsupported or original implementation.
- Device diagnostics adds an evidence-reading card with links to the measurements behind each observation. It explains
  positive root-variant evidence, current CPU ceilings without guessing their writer, one-shot memory pressure without
  diagnosing a leak and fuel-gauge capacity without presenting it as a direct cell measurement. Early and older snapshots
  keep safe fallbacks, while unknown, not exposed and not runtime-discoverable retain their existing meaning.
- Infinite-log conclusions no longer depend on whether their evidence is above or below the text. Directional wording was
  corrected in all 13 locales, and summary verdicts, diagnoses and priority actions now link to the relevant Smoothness,
  Drain, Night, Thermal, ASB-cost or other technical section. Unknown verdicts do not invent links. Next-capture guidance
  recommends one controlled change at a time and does not call a second observation an A/B test; text export excludes
  screen-only navigation.
- Regressions cover exact and generic KSU responses, sanitization and bounded collection, old/partial snapshots, working
  references, directionless wording, locale parity and clean exports. Chromium exercised Device and Report at 320, 360
  and 412 CSS px in all four themes, including KernelSU Next, an old KSU-only snapshot, 9.3% jank, an early capture and
  real navigation clicks, without page errors or horizontal overflow. Metadata agrees on V65 / 65257.

**fix256 — clearly recessed inactive profiles in dark Liquid Glass**
- Inactive profile cards now use a substantially darker, nearly black material with a restrained neutral border. Smart's
  decorative turquoise sheen is hidden while that profile is inactive, so it no longer competes with the selected card.
  The active profile keeps its accent border, tinted material, glow and selected checkmark.
- Only the inactive card surface and its decorative pseudo-element changed: names, descriptions, profile glyphs and the
  neutral `%/h` drain-rate values retain their foreground colours and full opacity. Ordinary dark/light themes, light
  Liquid Glass and the approved neutral OFF tweak cards are untouched; profile switching and drain behaviour are unchanged.
- Focused regression coverage checks the dark-Glass-only cascade, the hidden idle sheen, full card opacity, the preserved
  active/tweak materials and the light-theme guard. Chromium compared computed styles and screenshots against fix255 in
  all four themes, then exercised every active profile at 320, 360, 412 and 440 CSS px without horizontal overflow.
  Metadata agrees on V65 / 65256.

**fix255 — evidence-led infinite-log report and a clearer Device diagnostics page**
- The report's Smart summary now opens with evidence quality and five independent domain segments. It states how many
  of the five areas have enough data, how many need attention and how many remain without a verdict. This is not a
  health score: an early capture still yields five explicit “not enough data” verdicts, and a long capture cannot
  override any domain's evidence floor. A plain-language legend, cause/owner guide and a Technical evidence heading
  separate the answer from the measurements behind it; working jump buttons reach Summary, Actions and Details.
- Device diagnostics adds a compact At a glance dashboard for available memory, current battery evidence, ASB runtime
  and collection coverage, followed by the complete technical tables. Five numbered group headings, group guides and
  working jump buttons make the long page navigable. CPU policy, memory, kernel feature, external/UV and ASB capability
  cards now explain how their evidence should be read.
- Unknown, not exposed, not runtime-discoverable and not observable values have a neutral style and an explicit caveat:
  they are collection limits, never proof of missing hardware support or stock voltage. No capability, writer-health or
  battery-saving conclusion was added. The read-only, on-demand collector, privacy whitelist, multi-device behaviour,
  governor, profiles, native/DSP code and drain analysis remain unchanged.
- All 13 locales carry the new interface strings. Runtime regressions cover early/partial evidence, five report domains,
  safe device rendering, group order, neutral unknowns and saved-page text. Mobile Chromium verification exercised both
  pages, working navigation, long-value wrapping and no new horizontal overflow in dark, light and both Liquid Glass
  palettes. Metadata agrees on V65 / 65255.

**fix254 — source-specific cap-owner colours, rail-free priority actions and unambiguous Liquid Glass OFF states**
- Monitor's “who set the limit” value now identifies its source by colour: ASB uses the module green, Shell uses a soft
  blue in every palette, a vendor clamp is red and a vendor-raised cap is orange. Thermal ownership stays a hot warning
  and unreadable ownership stays neutral. The owner colours follow the broad metric rules so they cannot collapse back
  to white; Stock still clears those classes before reusing the element for battery temperature.
- Priority actions in the infinite-log report are a properly aligned numbered grid without the vertical rail through
  the numbers. Recommendation analysis, ordering, wording and evidence gates are unchanged.
- Liquid Glass now separates OFF from ON in both palettes: disabled cards, icon wells and switch tracks use neutral
  glass without an accent rim or category wash, while enabled rows retain their category/accent treatment. Ordinary
  dark and light themes keep their previous materials.
- Regression coverage executes the real cap-owner painter, checks source colours and contrast, Stock class cleanup,
  the rail-free action layout and scoped Glass ON/OFF rules. Mobile Chromium computed-style verification covered all
  four themes. No governor, profile, drain-meter, native or DSP code changed. Metadata agrees on V65 / 65254.

**fix253 — the latest complete idle window on every drain surface, seven readable quality steps, lower ASB background cost and a bounded Battery scheduler refinement**
- A full-day Battery capture exposed two different truths on Monitor: the fresh five-hour screen-off stretch was about
  0.40 %/h, while the card still led with the older 1.28 %/h aggregate. The drain meter now records the latest complete
  qualifying window beside the long-term aggregate. Monitor, the profile card, action sheet and diagnostics prefer that
  fresh window and name its basis; the aggregate remains available. A zero-step result stays a conservative upper bound,
  and the previous six-field files remain valid. Sustained playback still excludes an idle window, but a short
  notification or audio-thread blip no longer discards a whole night.
- Monitor subdivides the quality scale into seven intuitive steps - good, fair, mild, warm, hot, severe and bad - with
  metric-specific thresholds for temperatures, load, RAM, current, clocks, headroom, confidence, trend, clamps, ceiling
  and battery. Text and graphical scales share the same class in dark, light and both Liquid Glass themes, at 4.5:1
  contrast or better. The independent FSM/activity palette and the neutral numeric `%/h` and ETA values are preserved.
  All 13 locales carry the added scale and drain-basis wording.
- Battery gives foreground tasks a small scheduler preference (top-app weight 105, still below Balanced's 110) without
  changing its CPU/GPU floors or ceilings. This addresses interactive response without turning Battery into Smart or
  Balanced. No application- or SoC-specific writer was added, and vendor thermal ownership remains untouched.
- Noisy screen-off re-evaluation now runs every 30 seconds instead of 20, bounding that governor tier to 120 timer
  wakeups an hour rather than 180. Display, input and socket events remain epoll-driven; no polling worker was added.
  The capture already showed low ASB CPU cost and excellent deep sleep, so no broad frequency or network retune and no
  unmeasured battery-saving percentage is claimed.
- Tests cover latest-window parsing and presentation, six-field fallback, zero-step bounds, short versus sustained
  audio, action/diagnostic agreement, all seven quality classes and all four themes, the Battery scheduler ladder and
  the reduced screen-off cadence. `module.prop`, `update.json` and these notes agree on V65 / 65253.

**fix252 — one quality scale on Monitor, an activity palette that never reads as a grade, a Device page in reading order**
- Green meant two things on Monitor. Temperatures, the battery current, the trend, the slot heat and the app load used a
  six-step scale whose best step was blue, so a green CPU or board read as "second best", while on headroom, battery and
  confidence green was the best. Every graded reading now uses one five-step scale - green, lime, yellow, orange, red -
  with green always the best end; the blue step is gone from the helpers, the CSS and the sheets' scale bars.
  Temperatures fold the old blue and green ranges into green (CPU under 45 °C, shell 35, board 38, battery 35).
- Plain facts take the text colour on every card. The banner's plain values (slot, battery lean, slot heat, a steady
  trend, both `%/h` rates, a modem at its default) were mint in the dark theme and green-teal in the light one - almost
  the light theme's "good" green - and fix251's Moderate colour was exactly that value colour. ASB or the profile
  script holding the CPU ceiling is a plain fact too, no longer the brand mint or the cyan of an idle state.
- The activity palette (FSM state, and now the app load with the same words) keeps fix251's idea - blue/cyan at rest,
  turquoise for ordinary work, violet to pink for heavy work - with the colours spread so rest and work never look
  alike: Deep Idle sat 11 ΔE00 from Heavy in both themes. Every rest/work pair is now at least 15 ΔE00 apart, every
  activity colour at least 15 from each quality step and from the text, all at 4.5:1 contrast or more.
- Device diagnostics reads top-down in five labelled groups: hardware (the phone's identity, chip, CPU, GPU, memory,
  battery), firmware and system, kernel (build, custom features, live facilities, external/UV evidence, configuration),
  root and modules, and ASB itself (runtime, capabilities, collection metadata). The firmware section is split: the
  identity opens the hardware group, and the ROM version and build number follow the Android version instead of
  coming after the fingerprint. The Unicode-bypass evidence row sits under its feature, saved pages carry the group
  headings, and a future collector key still shows in the last card of its section.
- Tests: every graded helper is swept over its range and must start at green and step monotonically; perceptual
  distance and contrast for both palettes; the Device page groups, order, identity/firmware split and saved headings.
  13 locales gain the group and identity-card names; the unused cool step name is removed. No governor, profile,
  native or DSP code changed.

**fix251 — neutral Monitor drain figures and a separate FSM activity palette**
- Both numeric screen-on and screen-off `%/h` figures now stay neutral, like the modem's ordinary state, instead of
  turning yellow, orange or red as the rate changes. Their duration/ETA lines are neutral too. The explicit charging
  state keeps its existing shimmer, and temperature, load, current, trend and all other severity metrics are unchanged.
- FSM no longer borrows the thermal/severity scale: Deep Idle and Light Idle use blue/cyan, Moderate turquoise, and
  Heavy, Sustained and Gaming use distinct violet/pink activity colours. The palette covers the Monitor cell and its
  expanded detail sheet in dark, light, Liquid Glass dark and Liquid Glass light; unknown states remain neutral.
- The UI contract checks neutral `%/h`, all six FSM mappings, class replacement without stale colours, both palettes,
  expanded-sheet coverage and at least 4.5:1 contrast. Mobile Chromium verification covered every FSM state in all four
  themes with no horizontal overflow or JavaScript errors. `module.prop`, `update.json` and these notes agree on 65251.
  No governor, profile, native or DSP code changed.

**fix250 — the repository receives the whole fix248 delivery, including its action and WebUI strings**
- The next CI failure was reproduced against the exact tested commit, not only against a local source archive. That commit
  contained the source-only workflow correction and newly built AIDL references, but still had 15 files from the older
  tree: `action.sh`, these release notes and all 13 WebUI locales. The action therefore lacked the honest idle 5G-watcher
  status, and the WebUI lacked the uptime, report, Bluetooth and Monitor-sheet strings its code and tests expected.
- The delivered action and locales are restored intact. The five AIDL reference binaries collected by the tested AOSP
  workflow are included, so the strict byte-for-byte DSP reference staging contract runs without the source-only switch.
  No test is weakened and no governor or DSP binary is represented as a new local build.
- `module.prop`, `update.json` and these notes agree on V65 / 65250. Tests: all six failures from the repeated CI log,
  strict DSP reference staging, strict tree manifest, lint, and the full canonical regression from a clean archive
  extraction.

**fix249 — source-only DSP checkouts reach the test package build; release metadata stays monotonic**
- The test workflow now detects the five AIDL reference files before the canonical host regression. In a source-only
  checkout it sets `ASB_DSP_REFERENCE_OPTIONAL=1`, which skips only the byte-for-byte prebuilt staging check: all static
  DSP source/runtime gates and every other regression still run. When all five files are present the strict reference
  staging check is mandatory again. The release workflow is unchanged and still refuses to skip the DSP reference.
- The source snapshot already contained corrections for the Uptime, action-locale, manual-screen-switch and three WebUI
  failures named by the preceding CI log; those paths were left intact and rechecked individually and in the full suite.
- `module.prop`, `update.json` and these notes again agree on V65 / 65249 instead of regressing the manager-visible
  version to 650 / V64. The OTA URL once more names release 65 and the factory changelog.
- Tests: the source-only workflow branch has a contract pin; the full canonical regression passes with the explicit
  source-only DSP switch, and strict DSP reference staging remains required whenever the prebuilts are present.

**fix248 — the LTE switches run on every profile, a held Battery lift keeps the clusters level; mobile data and Bluetooth in the report; Monitor colours, sheets and Liquid Glass**
- LTE while the screen is off, 5G only when needed and Wi-Fi power save with the screen off are switches the
  user turns on, but the tuner that drives them was only started from the Smart tick, which returns at once on
  Battery, Balanced and Performance. On those profiles the three switches did nothing: on an OP15 on Battery the
  LTE log stopped the evening Smart was switched off, and two days, two captures and 1.9 GiB of mobile data later
  every snapshot still read the same applies count with the 5G watcher not running. The governor now runs the
  tuner at every screen change on a manual profile, in a "manual" mode that does these switches and writes none
  of Smart's read-ahead, swappiness, dirty-limit, MGLRU or watermark nodes - those stay the profile's - and does
  not turn off a power save the profile itself forces on. When Smart comes back its tuner runs at once. Native
  change: the governor needs a rebuild.
- The action report no longer says "5G in use, watching the traffic" when the watcher is not running; it says so,
  and when the switch stopped itself it shows why.
- Battery: a lift held up only by a finger keeps the clusters level. The lift raises every cluster to the same
  share of its own maximum, and on a 6+2 part the prime's capacity is a third above the main cores', so at 64 %
  of each the two prime cores become the bigger cluster and ordinary foreground work moves there - the imbalance
  fix130 removed from Smart. On Battery the touch hold keeps that lift up through a whole scroll: in an OP15
  Battery day the samples with the main ceiling more than 10 % under the prime's had the prime working in 20 % of
  them against 7-8 % with the two level. Once a Battery lift outlives its own window and is only held by the
  finger, the prime is lifted no further than the step whose capacity is within 10 % of the lifted main ceiling.
  The main lift, the top-app uclamp raise, the first seconds of every wake, first touch, app switch and lock press
  (the animations) and the jank guard's lift are unchanged. Two clusters only, from each device's own capacities
  and frequency tables; never below the prime's ceiling before the lift; main_capacity_parity=0 turns it off.
  asbdiag counts the levelled holds. Native change: the governor needs a rebuild.
- Report, mobile data: the digest adds the screen-on share of the traffic, the apps that moved it (Android's
  per-app history over the capture window, mobile networks only, with the time it covers), the radio network at
  each check (LTE, LTE + 5G NSA, 5G SA), the screen-on current with and without data moving, and whether the LTE
  switches ran between the first and last snapshot. A "Mobile data" card names the heaviest app and the setting
  for its kind - app updates over mobile data, messenger media auto-download, video quality, or a plain check -
  states the NSA share and the current split as measured correlations, and says when a switch ran. A switch that
  was on and never ran gets its own card as an ASB fault fixed in this build, and leads the priority actions.
- Report, screen on: the card lists what the screen time went on - the modem's traffic per hour, the average
  brightness, the app in front by its share of frames - and a day where mobile data explains the drain no longer
  asks for the log as unexplained.
- Report, ASB itself: its CPU time is also shown as a share of one core (4977 ms/h is 0.14 %), with the wakeups
  split by screen state and the note that none of them wakes a sleeping phone.
- Report, noise removed: under an hour of screen-off time (or no quiet stretch of an hour) the brief no longer
  quotes a screen-off rate ("21 min: 0 %/h"), and the screen-off row shows a dash under half an hour. The display
  table no longer stops at a refresh row the build could not read ("?"), so the refresh split appears again.
  The trend compares with the latest comparable capture instead of only the latest one.
- Report, Bluetooth: a section tells link drops (lost link, ended by the device, ended by the phone) and audio
  profile disconnects with their times from the stream simply pausing while the headphones stay connected, which
  feels the same in the ear.
- Monitor sheets: every reading's sheet shows where the value sits on its own colour scale (the bar uses the
  tile's exact thresholds, with the name of the step), how it moved while Monitor was open - minimum, average
  and maximum with a sparkline, or the share of each state for a state tile - and the raw facts behind it where
  the phone exposes them: the CPU zones' spread, the shell and board zones, the GPU clock against its maximum,
  the battery current as power and as %/h, corrected by the measured gauge factor where the sensor under-reads,
  and zRAM in use.
- Liquid Glass reaches the surfaces it had missed: the report and device pages sit on the lit backdrop instead of
  flat black or grey, and the drain halves, the drain and reading sheets' inner cards, the sheets' primary
  button, the toast (still tinted by its category) and the dialog backdrops take the material, in both bases.
- Monitor: every metric value is coloured by what it means, on six steps from cool to bad, in the dark, light and
  Liquid Glass themes and on the Smart and Battery layouts; "normal" modem state matches the uptime colour;
  "charging" on the battery-current tile shimmers (still for reduced motion). Tapping Uptime shows screen-on and
  screen-off time since boot, counted by the drain meter (a sample interval that began with the screen on and
  lasted over two minutes gives 30 s to the screen and the rest to the dark). The ROM telemetry reads the GPU's
  maximum clock as well.
- Every new string in all 13 languages. Tests: the manual-profile hook and the tuner's manual mode against fake
  nodes, the action line (t_manual_screen_switches_runtime); the new digest lines (t_fullday_digest_network_runtime);
  the mobile-data day, the fault card, the screen-on and ASB lines, the trend choice (t_webui_log_report_runtime);
  the boot screen counters (t_drain_meter_runtime); the Monitor colours (monitor_semantics and related UI tests);
  the levelled Battery hold (t_unlock_lift_runtime); the sheets' scale against the tiles' own colours, the raw
  facts and the Liquid Glass coverage (t_webui_live_info_insight_runtime); Bluetooth in the digest and the
  report (t_fullday_digest_network_runtime, t_webui_log_report_runtime).

**fix247 — the report names the causes and says whose side each one is on**
- "Causes and what to do" right under "In short", one card per area: battery with the screen off and on,
  smoothness, heat and throttling, background work, stability, ASB itself and the measurement. Each card
  says how it went (fine / normal / needs attention), the cause in a sentence with the numbers behind it,
  what to do, and the source: an app, a phone setting, the firmware, the load itself, ASB's tuning for this
  device, or not identified. Problems come first, healthy areas last.
- Causes the cards tell apart: a sync that never finishes, a background task, the always-on display, an app
  holding the CPU (with the "Act on Wakelocks" switch when it is off), background mobile data (with the
  screen-off LTE switch), drain while the phone actually slept, a frequent alarm; a status bar that redraws
  every second and why (network-speed meter, clock seconds, live wallpaper, code loaded into SystemUI); one
  heavy app; heat from games or the load; heavy work with the screen off; SystemUI restarts caused by an
  injecting app.
- Whether the ASB frequency ceilings cost frames is now measured, not guessed: the digest reads the report's
  janky share with the main and prime cores at the ASB ceiling and below it (`jcap_main`, `jcap_prime`), the
  jank floor (`jfloor`) and who held each cluster under the ceiling (`vcap`). Ceilings that clearly cost
  frames on Smart, Balanced or Performance, stutter concentrated at unlocks, screen-on drain with no load to
  explain it, an unexplained restless idle or drain while asleep, ASB crashes and an ASB overhead past its
  budget are marked as ASB's side or unidentified and ask for the log, with a "Save for the developer"
  button on the card. On Battery, tight ceilings are named as the profile's choice instead. A capture where
  the ceilings add nothing says so, and one where the firmware held the prime cores says that too.
- The terse "evidence and likely causes" chains are replaced by the cards; the brief and the new cards quote
  the same screen-off awake share (the longest idle chain, as the deep-sleep verdict does).
- Every new string in all 13 languages. Tests: the new digest lines (t_fullday_digest_trace_truth_runtime)
  and the cards for the owner's morning, a Smart day with tight ceilings, a Battery day, an unexplained idle
  and drain while asleep, the button and the saved text (t_webui_log_report_runtime).

**fix246 — the infinite log stops on the first confirm, the report speaks plainly, pages save as text**
- Stop: the helper looked for the recorder's children by forking one `cat` per process - thousands on a
  phone with ~9000 threads - inside the manager app's own cgroup, before it sent TERM. The WebUI froze, the
  phone stuttered and nothing stopped, and the recorder itself only reacted once its current `sleep` ended.
  The scan is now a single pass over /proc, the helper leaves the app's cgroup and clears the resume marker
  first, and the recorder sleeps in the background so a TERM ends it at once; it also runs at a lower CPU
  priority. The WebUI confirms the request at once ("Stopping the infinite log…"), says so when an earlier
  request is still running instead of swallowing the tap, and waits up to four minutes for a slow stop.
- Temperatures: for idle phases the recorder read the hotter of sys-therm-6 and the board zone. On SM8850
  sys-therm-6 sits at 40-41 °C whatever the phone does, so every quiet phase read 40 °C and the report showed
  41 minutes of skin above 40 °C over a night at 33 °C. The recorder now reads the governor's own surface
  zone first. The digest takes the peaks and the hot minutes from the battery trace (real samples) when it
  has enough of them, and the night card's peak CPU and skin from the samples inside the night: a night
  that read "CPU 37°" while it ran at 57 °C with the screen off now says 57.
- Live holders in words: a sync adapter, a WorkManager task, a scheduled job and an alarm are recognised and
  named ("contacts sync", "background task <name>"), the two records of one sync are merged, and the wake
  section says under an app what it held and in what share of the screen-off checks. A sync held in 30 % of
  the checks or more gets its own advice - turn that sync off for the account or add the account again; ASB
  never stops a sync itself - and a background task in 15 % or more gets the app's background-activity
  switch. The awake chain states the sync loop as a fact.
- "In short": the report opens with the day in sentences - the drop and the pace with the time a full charge
  lasts, what screen-on and screen-off cost, whether idle was healthy, the main screen-off cause with its
  holder named, heavy work with the screen off, smoothness and a status bar that never stops redrawing,
  heat - before the verdicts and the numbers.
- Save instead of JSON: on the report and on the device page the JSON button is replaced by Save. It writes
  the whole page as readable text - every section, row, note, table and verdict, warnings marked "(!)" -
  followed by the raw data the page was built from, to /sdcard/Download/asb_report_<time>.txt or
  asb_device_<time>.txt, in chunks that each fit one shell argument.
- Device page: on an Adreno driven by power levels (no devfreq node) the GPU row read "— · now — · range —–—".
  The collector falls back to the kgsl clock files and the available-frequency table and names the GPU model;
  the page names the power-level backend. External-kernel verdicts read as words instead of tokens.
- asbdiag: the "protected" wakelock verdict also covers apps on the battery-optimisation whitelist and says so.
- Every new string in all 13 languages. Tests: the one-pass child scan against `ps`, the stop order and the
  interruptible sleep (t_debug_support_stop_fast_runtime); trace-based peaks, hot minutes, night peaks, holder
  kinds and the surface zone (t_fullday_digest_trace_truth_runtime); the brief, the holder advice and the
  saved text (t_webui_log_report_runtime); the device save and the power-level GPU row
  (t_webui_device_page_runtime, t_device_info_runtime).

**fix245 — the session log is the infinite log**
- Since fix244 a capture started from the WebUI records across reboots until it is stopped there, so it
  is named for what it is: "Infinite log" in the Logs menu, its Stop item, every toast and the wait sheet
  (whose title was an untranslated "Session log"), and "Infinite log report" for the report page and its
  menu entry, in all 13 languages. The start toast no longer says the capture runs until shutdown (twelve
  translations still did). The Monitor drain tip and the vendor-hold tip point to the infinite log and its
  report instead of a "full-day log" and a "24h report". The text report reads "ASB INFINITE LOG REPORT"
  and the recorder says it runs until it is stopped. Capture folders keep their `asb_log_full_day_*` names,
  so captures recorded by earlier builds still open in the report.

**fix244 — the session log survives reboots, the WALT window is left to the ROM, Smart packs work again**
- Session log across reboots: a capture started from the WebUI now records until it is stopped there. The
  recorder leaves a resume marker (its folder, start and boot); only the WebUI stop or a deleted capture
  folder clears it. At boot the helper waits for boot completion, the unlocked storage (the folder lives on
  /sdcard, which stays encrypted until the first unlock) and 90 s of uptime, then starts the recorder on the
  SAME folder. Android may SIGKILL anything at shutdown, so the open phase is kept on disk at every poll and
  folded into the ledger on resume; the time the phone was off belongs to no phase. A shutdown TERM only
  marks the timeline, any other TERM finalises the report as before. Trace headers, the environment and
  start snapshots of the capture are kept; each resume adds its own state snapshot and a `reboots.txt` row
  (time off, module build, ROM). While the resume waits the status reads `resuming` and the menu offers
  Stop, which cancels it. The digest emits `reboot n=… mod=…`; the report says how many reboots the capture
  spans and names the module build after the last one when it changed (a capture across a flash). The
  WebUI says "until you stop it" instead of "until shutdown". `t_debug_support_resume_runtime` drives the
  real helper through two reboots (one with a late unlock), a cancelled resume and a deleted folder;
  `t_logkit_resume_runtime` runs the real recorder functions and the digest.
- Report status: a capture read "recording" long after it ended - the digest trusted any live PID in the
  lock. A lock from an earlier boot, or a PID that is not the recorder (PIDs are reused after a reboot), no
  longer reads as running. The open phase of a running capture now reaches the report at once.
- SystemUI restart attribution (correction of fix243): the dropbox keeps only the latest native crash,
  and logcat keeps hours. Capture 549's first restart carried the record of a crash four minutes BEFORE
  the capture started, which fix243 attributed to the restart. Evidence older than five minutes before a
  restart was seen (dropbox record, crash-buffer tombstone, the system's crash report, a low-memory kill)
  is no longer taken for that restart, in the recorder's verdict and in the digest. Re-read with this rule,
  capture 549 names no module for its restarts; the code loaded into SystemUI is still listed.
- WALT window: every OnePlus capture on file (OP12, OP13, OP15, Ace 6; every profile) shows
  `sched_ravg_window_nr_ticks` moving between 2, 3 and 4 by itself - the ROM sizes the window to the frame
  time of the refresh rate - while ASB wrote its profile value back on every forced apply (116 physical
  writes in one Battery evening) and that value held only until the next refresh change. The fix243
  Battery window therefore applied only in those gaps. The native writer now hands the node to the ROM
  after three new values it did not write within ten minutes, stops writing it for the session and leaves
  a marker the shell profile apply honours; a kernel where nothing else touches the window keeps the
  profile value. Reconcile no longer re-applies a whole profile because the window moved. The state file
  says who owns the window (`walt_window_owner`), asbdiag and the action screen name it.
  `t_walt_window_runtime` runs the real observer. Native change - needs a CI rebuild.
- Smart packing: the Smart blend set every rail but two - `ravg_ticks` and `idle_enough` stayed at the
  zero of a memset, so Smart wrote `sched_idle_enough=0` on every device (every Smart capture on file):
  no CPU short of a fully idle one counted as idle enough to take work, so screen-off background work woke
  idle cores the other profiles pack onto a busy one. Both are blended from the Battery and Balanced rails
  now. With the screen on Smart is held at 30, WALT's own default, instead of jumping to the rail, so
  its on-screen behaviour moves the least. Native change.
- Battery packing by state: the flat 75 of fix243 becomes 85 at deep idle (screen off, more packing) and
  45 at the top of the ladder, so LIGHT_IDLE lands near 79, MODERATE near 67 and HEAVY near 56. Native
  rails. No battery figure is claimed; a Battery and a Smart capture are the measurement.
- Action screen: the governor line names a ROM-owned scheduler window; the component list prints no empty
  heading; the DSP clarity line uses one decimal style in every language.
- WebUI: the stutter advice names the profile the capture ran on (a Battery day was told what the Smart
  learner is doing); a screen-off time-to-empty estimate past three days keeps its "~" ("~72h+"); a value
  too long for its quarter of the Monitor card shrinks a little before it is cut ("↓ cooling" read
  "↓ cool…" in Russian); the module build in the report no longer breaks at its hyphen.
- Capture compare reads the elapsed time of open-ended captures too.

**fix243 — a smoother and leaner Battery profile on every OnePlus, a fuller action screen, SystemUI restarts traced to their cause**
- Battery profile, scheduler: two owner captures on Battery (3 h and 2 h 11 min) put the stutter in the
  scheduler, not in the frequency ceilings. The big and prime cores sat at their ceiling in 1-2 % of the
  screen-on intervals, the unlock/interaction lift was active in about half of them and still moved
  janky frames only from 8.0 to 6.5 % and from 11.7 to 9.7 %, and slow UI-thread frames ran at 3.6 %
  where Smart days measured 0.7-1.2 %. Battery ran WALT with a 32 ms window (8 ticks), so a touch burst
  was learned after it had ended and the raised frequency then lingered for the same 32 ms; foreground
  demand counted at 80 %; and `sched_idle_enough` at 95-99 packed new work onto CPUs that were already
  busy. Battery now uses a 16 ms window (4 ticks), counts foreground demand at 100 % and packs at 75
  (Balanced 45-50, the kernel default 30). The shell profile and the native rails
  (`profile_bounds.conf` → `asb_fsm_bounds.generated.h`) carry the same values, so the governor does not
  rewrite them back. These are WALT sysctls every WALT kernel has; nothing is keyed to a model, and the
  ceilings stay percentages of each device's own maximum.
- Battery profile, lift: with the scheduler reacting in time, the unlock/interaction lift no longer has
  to cover for it. Battery lifts each cluster to 4/5 of `unlock_lift_pct` (64 % at the default 80, never
  below 50 %) instead of the full share Smart and Balanced use; the lift still holds while the finger is
  on the screen. The jank guard (recorder live) arms the same reduced lift. Native change - needs a CI
  rebuild. No battery figure is claimed: a new Battery capture is the measurement.
  `t_unlock_lift_runtime` pins the Battery share, its 50 % floor and Smart's unchanged lift.
- Action screen: settings added since the screen was last reworked now show where they act. The governor
  block adds an "also" line - the lift share per cluster (Battery's 4/5 included; not on Performance or
  Stock, not when the lift is off), a performance ceiling below 100 %, the ROM's own throttling point,
  prime-lift off or a non-default burst/pause, Smart's media guard, charge-aware or auto-Battery off,
  game mode allowed on Battery. Audio adds the DSP filter line (clarity in dB above 6.5 kHz, the sub-bass
  cut, the output headroom) only while the DSP runs, and the Bluetooth handling. Camera says when its
  performance hold is off, memory names the MGLRU mode and interface the animation scale (read live).
  Network (MTU, RPS, transmit queue), sleep (wakelock actions, GMS and Fit limits, GNSS, Doze whitelist,
  night modem) and system (log level, scheduler stats, LTPO and the other OEM switches) each gain the
  same "also" line. 45 new strings in all 12 translations; the
  i18n contract checks every key and placeholder. `t_action_also_lines_runtime` runs the real blocks in
  English and Russian.
- SystemUI restarts: the owner's 2-hour Battery evening had 7 restarts, every one read "no SystemUI crash
  in the crash buffer", while the system's own native-crash record held SIGABRT inside a library loaded
  from another installed app's package. The restart block now keeps that record's header and process
  line and hands it to the verdict, which names the library and the package when a crash frame sits in
  an installed app's code (`/data/app/...`), in the crash buffer or in the record. The system's crash
  report for SystemUI corroborates a record that does not name its process; a record of another process
  names nobody. Code other apps load into SystemUI is listed from their own log lines. The digest adds
  `sysuiinj` (package, restarts it accounts for, loaded hooks); the log report raises an action and a
  cause chain naming that package and lists the loaded hooks in the crash section, in all 13 languages.
  `t_logkit_sysui_verdict_runtime` and `t_webui_log_report_runtime` cover the verdict, the digest line
  and the report.

**fix242 — stop the session log from its own menu, honest report figures, a readable device page, Wi-Fi that lets go**
- Session log: the open-ended capture had a start in the small Logs menu and no stop. While a capture
  runs, the same item now reads "Stop session log" with a red recording dot; the first tap arms it
  ("Tap again to stop", amber, four seconds), the second sends `full-day-stop`. The helper finds the
  recorder through the WebUI lock (the legacy pid file as fallback), refuses to touch a pid that is not
  a verified recorder, sends TERM to it and to its `sleep` children (the recorder's trap writes the
  final report and releases the lock itself) and leaves a detached waiter that kills only a recorder
  that is still alive and still the same process after `ASB_DEBUG_SUPPORT_STOP_WAIT_S` (120 s), then
  removes the lock only if it still names that dead pid. The page polls until the helper reports idle
  and names the saved folder. `t_debug_support_stop_runtime` drives the real helper against a stub
  recorder: a graceful stop finalises, an unresponsive one is killed after the wait, an idle helper
  says so.
- Log report, average drain: the digest divided the whole drop by the time of only those phases whose
  whole-percent level happened to move. Most short phases read 0 %, so the owner's 3-hour Battery
  capture showed 16.6 %/h where the level fell 19 % in 3 h (6.3 %/h). Every discharging phase now counts
  and charging phases are excluded by name (smart charging can hold the level still on the cable). The
  history line carries the method (`dm=2`); a line from an older digest is not compared as day drain,
  so the trend cannot fake an improvement. A zero-length ledger row (the instant a phase opened, the
  recorder's own start-up sample) no longer sets the temperature peak: the same capture showed CPU 55°
  and skin 49° where no real phase passed 46°.
- Log report, judgement: a mixed day (screen on 26-49 % of the time) is judged on the whole discharge
  against a budget blended by its own screen share, with how long a full charge lasts at that pace
  (≈16 h for the owner's day). The screen-off figure is idle alone - music with the screen off is
  counted apart and explained - and it is red only when the capture had a quiet stretch of an hour;
  a day of short pauses between uses says so instead of painting 3.4 %/h "idle" red. Phases shorter than
  20 minutes or 2 % show the drop without a rate, the worst-idle row needs 20 minutes, the speaker row
  10 minutes, `*launch*` and `*vibrator*` counts are never red, throttle periods without sustained heat
  are neutral with a note, temperatures are labelled as peaks, the Smart learner card is shown only on
  a day Smart actually ran, and units in the summary (%/h, ms) follow the interface language.
- Log report, SystemUI: when SystemUI misses frames in at least 80 % of screen-on intervals whatever
  app is open (the owner's day: 81 of 81, 13.8 % of its frames), the digest reads the status-bar
  settings the capture recorded and the report names the one that is on - the network-speed meter,
  seconds on the clock or a live wallpaper - as a priority action, with a fact line and a Smoothness
  row. The capture itself already listed `show_network_speed=1`; the report never used it.
- Device diagnostics: the System section printed the raw `/proc/uptime` and `/proc/loadavg` lines
  ("508.51 2724.42", "7.18 7.95 4.97 3/11967 8744"). Uptime is now a duration with the CPU idle share
  (idle seconds over uptime × cores), load is "1 / 5 / 15 min · N of M threads running" with a note that
  Android load counts tasks waiting on storage. Memory reads in GB/MB, battery in °C, mA, V and mAh,
  CPU policies and the GPU as one line each (cores, governor, current clock, limit, hardware range).
- Device diagnostics, "ASB device capabilities": the section repeated Android API, kernel and model.
  The collector now reports what ASB actually found on the phone - frequency tables per cluster with
  step count and floor control, GPU control path (power levels or devfreq), thermal sensors, uclamp,
  battery current sensor, cgroup v2, memcg, msm_performance, camera CPU set, the audio DSP effect,
  vendor overlays, the Wi-Fi queue and the subsystems with a tunable - from `device_caps.env`,
  `capabilities.env` and the install probe. A new "At a glance" card leads the page (processor,
  memory, battery with capacity against design and cycle count, running time, root manager), and the
  sections run from what a user needs to kernel internals.
- Battery chemistry: a user with a silicon-carbon battery read "Li-ion" and took it for an error. The
  kernel reports only the chemistry class through `technology`; Si/C cells are lithium-ion cells with a
  silicon-carbon anode, and no sysfs node exposes the anode. The row stays truthful and a note under it
  says so; the battery card adds capacity against design (amber below 80 %) and the cycle count.
- Wi-Fi leave between two weak access points: the watcher kept a dead link. Behind a VPN the Wi-Fi
  default route is not in the rule table the watcher read, so it believed Wi-Fi was not the default and
  never acted (the user's capture: tun0 default, no leave event in 19 hours). It now falls back to
  `dumpsys connectivity` (cached 30 s) to see that the underlying default network is Wi-Fi. On every
  rung that watches the signal, a marginal signal releases on 3 of the last 4 readings below the
  threshold instead of a strict run that one good reading reset. On unusable and aggressive, a link
  whose gateway stopped answering at a marginal signal is released after two silent probes - only once
  the gateway has answered on that link, so a router that ignores ping is never judged. The leave
  summary counts these releases.
- Monitor, ROM thermal trend on Battery/Balanced/Performance: the tile is computed by the page itself
  from two ROM reads ten seconds apart (Smart's comes from the governor), and every Monitor visit starts
  a fresh page, so most glances landed before a verdict. It now shows the current temperature while
  measuring, falls back to the hottest die zone and then the battery when a snapshot has no CPU zone
  (one series never mixes sources), and shows a dash only when no temperature is known at all.
- Tests: `t_wifi_leave_marginal_runtime`, `t_debug_support_stop_runtime`; the log-report, device-page,
  device-info and stock-monitor runtime tests cover the new figures, rows and fallbacks. Shell and WebUI
  only - **no native change; the arm64 governor from fix241 stays as built.**

**fix241 — Battery: the first seconds of a swipe are no longer drawn at the lowest GPU step**
- OP15 on ColorOS 17 / Android 17, Battery: the first seconds of a launcher page swipe, the shade and
  control panel, the app drawer and app open/close stuttered, then the phone ran smoothly. Root cause:
  in Battery's LIGHT_IDLE the governor itself writes a GPU ceiling of `bat_light_idle_gpu` (10 % of
  the GPU maximum, which every OnePlus GPU table resolves to its lowest pwrlevel - 160 MHz on SM8850),
  and Battery was the one profile excluded from the fix117 touch floor and first-touch lift. A swipe that
  started from a calm screen was drawn at that step until a later metrics tick left light idle: one tick
  when the GPU load already read 12 %, four ticks on Battery's doubled up window otherwise (2-8 s). The
  earlier "vendor PowerHAL clamps GPU max_pwrlevel to 17 in LIGHT_IDLE on Battery" note was this write;
  the 4-second screen-on grace covered a wake only. The unlock/touch lift raises CPU ceilings and
  top-app uclamp, never the GPU, and on this phone it was vetoed for 7 of 8 taps (die at
  `bat_comfort_temp`), so the lift could not hide it either.
- The FSM now treats a finger on the glass as interaction on Battery as on the other profiles: a fresh
  touch leaves LIGHT_IDLE in the same update, the touch floor holds MODERATE while touches continue (3 s
  after the last one), and a sampled touch without a fresh kick skips Battery's doubled up window.
  Battery's MODERATE is its own envelope (GPU ceiling ~42 %, top-app uclamp ~42, CPU ceilings still
  the shell's static Battery caps), under every other profile. Quiet reading returns to light idle and
  its lowest GPU step through Battery's usual down window once the touches stop; the camera stays
  excluded, the CPU pin escalation stays off on Battery, the unlock-lift gates (warm die, thermal cap,
  5-second gap) are unchanged, and Smart/Balanced/Performance behave as before. The touch panel is found
  by evdev capabilities, not by a model list, so OP12/13/15 and the Ace phones are handled alike; a
  phone without a detected panel keeps the previous behaviour.
- `t_battery_touch_light_idle_runtime` compiles the real governor translation unit and drives its FSM:
  a quiet Battery screen stays in light idle, a touch leaves it at once and holds, quiet reading idles
  again, a sampled touch is not delayed, the Battery MODERATE GPU ceiling stays inside 40-44 % and
  Smart keeps its lift. Against the fix240 source the same fixture fails on all four Battery steps.
  The fix223 and fix117 source contracts now pin the narrower exclusion. **Native change - the arm64
  governor must be rebuilt by CI.**

**fix240 — every Config card in every language, and device bounds that read the whole fingerprint**
- Device bounds never applied on the OnePlus 15: every governor start logged
  `device_bounds: stale/fingerprint` and ran the compiled reference rails, although asbdiag showed a valid
  `device_bounds.env`. The shell writes the fingerprint with `getprop`; the native loader read it with
  `__system_property_get`, which stops at 91 characters and returns a "Must use
  __system_property_read_callback()" placeholder for a longer value. This build's fingerprint is 92
  characters, so the comparison could never match. The loader now reads through
  `__system_property_read_callback` (resolved at run time, the NDK target is API 24) with the old call as
  fallback, and its buffers take a 255-character fingerprint. A host test compiles the real loader against a
  92-character fingerprint: applied with the callback, stale/fingerprint without it. **Native change - the
  arm64 governor must be rebuilt by CI.**
- DSP Clarity, DSP Sub-bass Filter and DSP Output Headroom were stored as plain strings in all 13 locale
  files and their descriptions sat in a top-level table nothing reads, so every language showed the English
  name and text; uk.json carried Russian and the Russian text called the high-pass a low-pass. All three are
  now name/description objects in every language, the headroom options are labelled in dB with the
  language's decimal separator, and the sub-bass "off" uses each language's own word.
- Six newer cards (Athena Background Killer, Spread Network Load, Transmit Queue, Quiet Radio at Night, Keep
  Apps In Memory, Wi-Fi Power Save) kept English names in 11 languages and Leave Bad Wi-Fi in two; the options
  of Athena, RPS and Transmit Queue were English in 11 languages and the French and Armenian option labels of
  15-18 older cards were English. Scheduler Debug Accounting got its per-option text in 12 languages, worded
  with the label its buttons show. The log report, device diagnostics and smoothness strings (about 200 per
  language) are translated in 12 languages; the toasts "applies after reboot", asbdiag saved/failed and
  "could not read the list" too. Arabic used the word for warehouse stock in two places. A failed profile
  delete or restore no longer says "Could not read the backup".
- Value badges keep the case of a number with a unit: "−0,50 дБ", "35 Hz" and "+3 dB" no longer read "ДБ",
  "HZ" and "DB".
- `t_webui_card_i18n_coverage_runtime` parses CFG_ITEMS and fails on a card without a name or description in
  any language, a stray description table, a card name or detail table left in English, an option English
  labels but a language does not, and Russian words in uk.json.
- The settings snapshot that survives an update now includes `mglru_hold`, `net_wifi_leave`,
  `wifi_powersave`, `bt_link_stability` and `lsposed_verbose`; the ownership test checks that list against
  every card.
- `bt_a2dp_offload` shipped as `on` while the WebUI default and a fresh install use `auto`, so Reset
  re-imported `on`. The shipped config now says `auto`.
- asbdiag notes a profile switch in progress: the Wi-Fi transmit-queue WARN taken during a Battery switch
  (wlan0 still 32, before the switch's final network re-apply) is a note during a switch. The window-blur
  line reports OFF when `disable_blur` is not set instead of comparing a value ASB never wrote.

**fix239 — short-window Battery insurance, delivered camera grain and reversible generic tweaks**
- Battery jank insurance keeps its live-recorder, Battery-only, camera/thermal/game gates and existing
  300-frame/12-janky/8% primary window, but no longer ignores a rough app/launcher transition that ends
  before 300 frames. A separate 120–299-frame window requires at least 8 janky frames and 12% jank. Both
  paths use the same 60-second on-demand dump, independent SystemUI window, 10-second ceiling-only lift
  and exact handback: no Smart learner, frequency floor, persistent app table or polling worker. The
  shipped arm64 governor is rebuilt from this source; host runtime fixtures exercise both window types.
- Camera Grain level 10 now scales stock additive grain by 16× instead of 10×, with the existing numeric
  ceiling and non-compounding stock-source marker. Scalar and bracket-list `addNoiseWeight*` values are
  both patched; lists no longer pass through the scalar parser. WebUI reads every `.mark.stats` sidecar,
  sums actual changed-key coverage, and shows **not exposed** when the applied firmware source offered no
  usable grain value. Missing coverage remains unknown rather than proof of missing support.
- Wi-Fi Scan Rate adds an explicit 30-minute rung (`wifi_scan_throttle=5`) with the existing boolean and
  interval write/readback pair. The default remains 5 minutes; the cost is slower discovery of new networks.
- New default-stock `kernel_sched_stats=stock|off` is a generic opt-in, not an SoC-specific writer. Off is
  attempted only when `/proc/sys/kernel/sched_stats` is readable/writable and the original 0/1 baseline was
  saved. Repeated apply cannot replace that baseline; Stock and uninstall restore it exactly, while a
  missing node is reported as not exposed. No fixed battery-life percentage is claimed.
- Dynamic TCP selectors, DSP tone filters, LTPO priority/fallback, SuSFS uname wording, neutral modem
  normal, persistent thermal trend and supported-userspace quick reboot retain focused regression coverage.
  AIDL/attacher and DSP libraries still require the user's AOSP workflow rebuild from current sources;
  older prebuilts are not represented as containing new effects. No APK, hidden writer,
  persistent worker or unmeasured battery/audible improvement claim was added.

**fix238 — new measured DSP tone filters, truthful DSP state and source-complete workflow build**
- Added **DSP Clarity** (`dsp_clarity=0..8`): a 6.5 kHz high shelf with 0.5 dB per level, capped at +4 dB.
  Added **DSP Sub-bass Filter** (`dsp_rumble=off|35|50|70`): a fourth-order Butterworth high-pass at
  24 dB/octave. Both live in the shared realtime-safe core and are wired into AIDL and legacy sources,
  float and PCM16 paths, live properties, attach-daemon change detection, configuration migration,
  diagnostics and all 13 WebUI locales. The processing order is rumble → bass → voice → clarity → width →
  compressor → sample-peak limiter; bypass remains bit-exact. Host fixtures measure the responses and
  ceiling rather than claiming an unmeasured audible or battery percentage.
- DSP cards now use one engine-state rule: zero loudness, `dsp_outputs=off` and `audio_profile=eq_compat`
  cannot leave bass, tone, dynamics or headroom looking active. EQ compatibility has its own explicit
  badge. “True-Peak Headroom” was renamed to the accurate **Output Headroom**: the limiter is sample-peak,
  not an oversampled true-peak detector.
- Runtime mirroring validates and publishes clarity/rumble to both ASB property namespaces and wakes the
  existing attacher on tone/headroom changes; no polling worker was added. Release freshness gates reject
  AIDL/legacy/attacher artifacts that lack the new markers after the workflow rebuild.
- `asbdiag` reports live clarity/rumble values and uses `support unknown` / `not runtime-discoverable`
  when binary evidence is unavailable. The display-property waiter now resolves both API-26 property
  functions dynamically, preserving the API-24 release build and existing fallback.
- The AIDL and attacher binaries are intentionally left for the user's AOSP workflow to rebuild from
  these sources; this source archive does not claim that the older prebuilts already contain the effects.

**fix237 — SystemUI-aware Battery smoothness, safe LTPO fallback and opt-in TCP MTU recovery**
- Battery jank insurance now evaluates independent foreground and `com.android.systemui` windows from
  the same on-demand graphicsstats dump. This covers launcher, shade and recents rendering without a
  second probe, cross-application frame aggregation, a Smart learner, a frequency floor or a polling
  worker. The existing capture gate, 300-frame/12-janky/8% thresholds, 10-second ceiling-only lift and
  exact handback are unchanged; runtime fixtures cover a low-jank foreground with a triggering SystemUI.
- Integrated LTPO publishes its watcher PID only after successful touchscreen and panel discovery, and
  the apply path waits for bounded watcher readiness before pausing the verified external writer. A
  failed startup leaves or resumes the external writer instead of suspending all refresh-rate control.
- Camera grading now leaves a separate apply-coverage sidecar with the number of actually changed
  `addNoiseWeight*` keys and contrast rules plus their requested percentages. The existing `ASBGRADE`
  marker, stock-source rule and non-compounding behavior are unchanged; diagnostics expose the evidence.
- Network Stack adds default-off TCP PMTUD black-hole recovery. `net_mtu_probing=on` writes only Linux
  mode 1, which probes after a suspected black hole rather than reducing MSS on healthy routes. The
  original 0/1/2 value is saved once, apply requires readback, Stock and uninstall restore it exactly,
  and failure never discards the saved baseline. The setting has localized WebUI, diag and runtime tests.
- Source, browser and clean-unzip host regressions cover the new behavior. No APK is embedded or
  installed, no persistent worker was added, and no unmeasured battery-life improvement is claimed.

**fix236 — Measured Battery smoothness, stronger camera grading and explicit LTPO ownership**
- Battery keeps its own energy-saving policy and gains no Smart learner, frequency floor or persistent
  per-app offsets. While the user-owned session recorder is verifiably live in the current boot, an
  on-demand graphicsstats window with at least 300 frames, 12 janky frames and 8% jank can arm the
  existing ceiling-only unlock lift for 10 seconds. Probes are at most 60 seconds apart; camera,
  thermal, game, screen-off and profile gates force exact handback, and no resident polling worker
  was added. Host runtime tests exercise the capture gate, measured window, TTL and profile handback.
- Camera film grain now discovers every firmware `addNoiseWeight*` variant instead of patching only
  a fixed key list. The 0–10 scale reaches 10× at level 10 without compounding repeated grades:
  stock-source hashing and the `ASBGRADE` sidecar remain mandatory. No APK is embedded or installed.
- Audio/DSP exposes a live true-peak limiter headroom choice (−0.15/−0.30/−0.50/−1.00 dB) through
  the existing native limiter and property mirror. Network congestion selectors read the algorithms
  actually advertised by `tcp_available_congestion_control`; runtime apply-side validation remains.
- Integrated LTPO is default-off when OnePlus15-165HZ-LTPO owns the display. Explicit `ltpo_force=1`
  gives ASB priority, pauses only a PID/cmdline-verified external writer and never edits that module.
  ASB's independent controller uses blocking input events for peak/active and configurable idle
  refresh, preserves camera/game/video ownership, and writes Settings only on transitions.
- Modem `normal` is neutral rather than green; the real thermal trend can appear after two samples
  spanning eight seconds without inventing a one-sample slope. SuSFS `SPOOF_UNAME` evidence adds an
  expected-possible-cause explanation for Wild GKI release mismatches without claiming provenance.
  Post-boot settle polling is shortened while all deferred ASB policy operations remain ordered.
- New runtime contracts cover Battery jank insurance and LTPO active/idle, camera and video guards.
  Browser verification covers live TCP choices, DSP headroom, the LTPO badge and SuSFS wording.

**fix235 — Unified diagnostics, session-length capture and clearer device/Monitor exports**
- Device diagnostics now has a JSON action beside the existing export controls. It serializes only
  the latest successfully parsed read-only snapshot, disables stale exports during refresh/error,
  and writes `/sdcard/Download/device.json`; exporting never reruns the collector or starts a worker.
  No serial number, IMEI, account or network identifier collection was added.
- Release and `testN` builds now compile and stage the unified diagnostic feature set that was
  previously gated to debug packages. Boot timeline, support actions and native diagnostic state are
  available in both channels. The standalone debug workflow was removed, the test workflow publishes
  `testN` artifacts without a GitHub Release, and a regression compares release/test staging blocks.
- The support recorder now defaults to an open-ended session capture until device shutdown rather
  than expiring after 24 hours. Positive numeric arguments still provide bounded manual captures;
  digest/report metadata preserves old `target_h=24` captures and represents open-ended sessions as
  `target_h=0`. WebUI labels use Session log / Лог сессии across all 13 bundled locales.
- Monitor slot heat uses primary text for `typical`, accent blue for `cool`, warm for `warm` and
  neutral for unknown/malformed values. Modem `normal` now uses primary text, while `save`/`night`
  remain green, `fast` remains red and unknown remains neutral, in ordinary and Glass themes.
- Browser tests cover real JSON snapshot export, exactly one collector call, all four theme variants
  and the new labels. Shell/native contracts cover unified builds, open-ended and legacy bounded
  capture behavior. No governor, frequency, cpuset, DSP, LTPO, network or power/performance policy
  changed in this fix, and no persistent polling worker was added.

**fix234 — Battery lift now includes foreground launcher/SystemUI work**
- The follow-up Battery-only capture confirms that fix233 is active (`foreground cpus=0-7`), so the
  old prime-placement restriction is not the remaining limit. SystemUI is again the largest aggregate
  jank contributor, while ordinary Battery foreground uclamp stays at 50 even during the short lift.
  The native lift raised CPU ceilings and top-app uclamp only; the separate foreground owner had no
  interaction-lift path for launcher/SystemUI threads that are not in top-app.
- During an already armed, thermally permitted Battery interaction lift, the single native foreground
  owner now saves the current ordinary ceiling and temporarily raises it to `unlock_lift_pct` (80 by
  default). Expiry, screen-off or lift cancellation restores the exact saved value. A higher vendor
  ceiling is never lowered; camera guard remains exclusive; a profile switch never restores a stale
  Battery value over the new profile. No frequency, cpuset, governor, DSP, LTPO, network or background
  policy changed, and Smart/Balanced do not gain this Battery-only path.
- The executable native fixture covers 50→80→50 handback, continuous touch at 100 without a max-guard
  fight, screen-off, higher vendor ceilings, camera exclusion, profile switching and unchanged
  Smart/Balanced behaviour. No polling worker or repeated lift reassert was added.

**fix233 — Battery interaction can finally use the lifted prime cores**
- A new Smart → Battery field capture switched at 16:48:23 and immediately showed the placement
  difference behind the remaining launcher/swipe and app open/close stutter: Smart foreground used
  `0-7`, while Battery foreground/top-app stayed on `0-5`. The unlock/launch lift ran 268 times and
  writer readbacks were healthy, but on this 6+2 device its raised prime ceilings were unreachable
  by the visible app, launcher and SystemUI.
- Battery foreground and top-app now use every present CPU, like Smart and Balanced. This is a
  placement fix, not a new performance policy: Battery's static per-cluster frequency ceilings,
  top-app/foreground uclamp rails, governor and unlock-lift timing are unchanged. Background and
  system-background remain on the little/main cluster, and camera-guard ownership is untouched.
- Both profile-apply paths were changed together (`profile_core.sh` and `service.sh`), so a profile
  switch and a later re-apply cannot restore different cpusets. Multi-cluster runtime fixtures cover
  OP12, OP15 and SM8550 Battery placement, unchanged background placement and unchanged Smart;
  service contracts prevent the removed Battery-only restriction from returning. The canonical host
  regression, clean lint and native warning budget pass.

**fix232 — explicit metamodule evidence and truthful modem-mode colours**
- Device now has a dedicated Metamodule section. The read-only collector reads the standard
  `/data/adb/metamodule/module.prop` and reports its status, ID, name, version and version code.
  Missing version fields say `not exposed`; an unreadable or absent standard path is described
  precisely instead of becoming universal proof that no metamodule exists.
- The same section repeats NoMount driver state and its sysfs-exposed driver version, using the
  exact evidence already shown under Custom kernel features. Kernel config/sysfs evidence remains
  independent and does not claim that a detected metamodule owns the driver. NoMount information
  stays visible even when no metamodule is found at the standard path.
- Modem `normal` is the stock baseline and is neutral again; only actual saving states (`save` and
  `night`) are green, `fast` remains limiting, and unknown/unavailable states remain neutral.
- Runtime fixtures cover complete, incomplete, unreadable and absent metamodule metadata, built-in
  and loaded NoMount with exposed/missing versions, safe rendering and all 13 locale key sets.
  Chromium verification covers 254 checks across fullscreen navigation, all four themes, the new
  Device section and modem colours; all four canonical host regression suites pass. No writer,
  governor, frequency, DSP, LTPO, network or power/performance policy was changed.

**fix231 — opaque fullscreen drill-ins and calibrated report drain verdicts**
- Report and Device now keep an opaque palette background even under Liquid Glass. Opening
  either page from Home, Monitor, Config or Report no longer exposes the page underneath;
  Glass cards and the selected dark/light palette remain intact.
- Screen-on battery drain no longer turns red solely above 8%/h. Ordinary use, sustained
  gaming and speaker playback have separate budgets, with one shared classifier for the
  executive summary, detailed drain row and phase table. In particular, 10.1%/h during
  ordinary screen use is `normal`, while insufficient screen-off evidence keeps its separate
  stricter rules. Thermal, smoothness and deep-sleep verdicts are unchanged.
- Custom kernel feature groups are reversed: SuSFS and its version lead, followed by BBG,
  BBRv2/v1, LTO, TMPFS, Unicode, Droidspaces, NTSync and NoMount. Unknown future keys remain
  visible after the known order.
- A known `normal` modem state is green instead of neutral grey; only unknown or unavailable
  modes remain neutral. Browser verification covers 243 checks across Report/Device origins,
  all four themes, feature order and modem colours; the canonical host regression passes.

**fix230 — Device kernel evidence and state-aware Monitor colours**
- DSP Outputs is now the first Audio/DSP card. The global Smart, Performance and Liquid Glass
  glyphs use cleaner silhouettes without the former inner flame/droplet details.
- Every SoC capsule opens a dedicated Device page with firmware, device, SoC, kernel, custom
  kernel evidence and read-only diagnostics. The on-demand collector reports NoMount and its
  exposed driver version, NTSync, Droidspaces, specialized Unicode Bypass evidence, TMPFS
  XATTR/POSIX ACL, LTO, BBRv1/BBRv2, Baseband Guard and SuSFS without changing device state.
  Missing evidence stays `unknown`, `not exposed` or `not runtime-discoverable`; it is never
  presented as proof that support is absent. No serial number, IMEI, account or network
  identifier is collected.
- Monitor values now use explicit good/warm/limiting/neutral colours for Basis, slot heat,
  confidence, modem mode, available RAM, battery current, CPU clock/load, body/board/GPU
  temperature/load and thermal headroom in Stock and ASB profiles. Cool/typical and warm slot
  states differ; missing data and warm-up remain neutral. Per-policy clock ceilings prevent a
  low individual policy ratio from being misclassified against another policy's maximum.
- The page and collector are covered by parser, renderer, injection-safety, fake procfs/sysfs,
  missing-config and read-only SuSFS fixtures. All four themes and five profiles passed 368
  Chromium checks; the canonical host regression, clean lint and native warning budget pass.
  No governor, frequency, DSP, LTPO, network or power/performance writer policy was changed.

**fix229 — fail-closed device-bounds validity and auditable shell import**
- Both native and shell consumers now require schema 2, measured high-confidence provenance,
  the current `ro.build.fingerprint`, the current 2/3/4-policy count and an exact
  little/mid/big policy-ID + hardware-maximum signature before applying `device_bounds.env`.
  Native validates the whole file before a second-pass import, so stale data cannot leave a
  partially applied profile. Mismatches preserve the file for diagnosis and keep compiled
  defaults; no arbitrary age TTL was added.
- Synthesis now orders policies by measured hardware capability like native discovery, rejects
  1- and 5+-policy layouts instead of forcing them into three logical slots, and still resolves
  the strongest middle for supported 3/4-policy devices. Frequency ratios, profile ceilings,
  governors and all other power/performance policy values are unchanged.
- The shell importer uses a shared validator and explicit per-key assignments instead of `eval`.
  `asbdiag` reports `applied/stale/skipped` plus the exact reason and no longer labels stale
  values active. Native state and critical logging carry the same result.
- Executable fixtures cover current valid 2/4-policy files, stale fingerprint, changed policy
  count and `hw_max`, missing provenance, unsupported 1/5-policy synthesis and eval-free import.
  All 213 host regression sections pass; native strict warnings remain 60/62 and lint is clean.

**fix228 — semantic Monitor colours, clearer category Glass and single-owner foreground uclamp**
- Smart app load now has the same explicit green/orange/red scale as Stock system load:
  idle/light, medium and heavy/gaming respectively. Unknown and warm-up stay neutral.
  Cooling, warming, basis warnings/vetoes and both load renderers keep those semantic colours
  in Dark, Light and either Liquid Glass palette instead of being flattened by the material.
- The six Settings categories retain bounded Glass blur and neutral readable copy, but their
  translucent bodies, edges, icon pills and counters now carry a stronger category tint in
  both dark and light Glass. Layout, category order and ordinary Dark/Light materials remain.
- Analytical-report observations now use the same stable severity ordering as priority actions.
- Smart screen-off foreground uclamp and wake restore moved from the shell tuner into the
  existing native guard, alongside max correction and camera exclusion. The policy values are
  unchanged (35 while off; last-good or 88/70/55 profile fallback); manual Balanced/Battery do
  not inherit Smart's sleep cap. State-file formats and uninstall restoration are preserved.
- Chromium exercised every theme/material pair and the real Smart renderer; the native fixture
  covers sleep/wake, max fallback, profile scope and camera exclusion. Full host regressions
  and release ZIP validation follow. No APK, resident worker, frequency/governor ceiling,
  network, DSP, LTPO or other power/performance policy was added or changed.

**fix227 — clearer Glass popups, DSP-first Audio and truthful unsupported-writer evidence**
- Dark Glass is slightly deeper, with a subtler green ambient wash and a finer reflective
  double contour. The log menu now uses that material too, instead of remaining an opaque
  dark-blue panel. Profile/reset dialogs, the file manager and their relevant controls share
  the same bounded blur and stronger floating-surface edge in both dark and light Glass.
- Audio keeps one category and one renderer, but ASB DSP Engine is now its first subsection.
  DSP Loudness is the first card, followed by Outputs and the rest of the DSP chain; Playback
  & Bluetooth and Listening Safety remain intact below. No setting, default or audio policy
  was removed, duplicated or reordered internally.
- The supplied OnePlus 15 / ColorOS 17 `/data/adb/asb` and `/dev/.asb` snapshots were checked:
  structured files parse, profile hashes and the DSP helper match, native writer failures are
  zero, arbiter leases are applied and route-watch has no logged error. The only `FAIL` row was
  the kernel's unsupported WALT readback sentinel, despite the writer correctly reporting zero
  failures. Such absent/invalid nodes now record `UNSUPPORTED`, and both asbdiag copies count
  only genuine `FAIL` rows as rejected writes. The day-long capability backoff is unchanged.
- Chromium checks cover dark/light log, file-manager and reset surfaces, DSP-first DOM order,
  blur, borders, reduced motion and horizontal overflow. The complete WebUI suite and three
  full host regressions pass, followed by a release regression. No CPU/GPU ceiling, DSP gain,
  network, LTPO, power/performance policy, APK or resident worker was changed.

**fix226 — Liquid Glass now follows either palette and keeps ASB green**
- Liquid Glass is now a material layered over Dark or Light rather than a separate dark-only
  colour theme. Entering Glass from Light produces a light translucent interface; entering it
  from Dark produces the black variant. The last palette is remembered across cold starts,
  while legacy Glass preferences safely default to the dark base.
- Dark Glass uses ASB green `#00f0b4`; Light Glass uses the darker accessible green `#007c63`.
  The previous blue Glass accents are removed. Existing Light contrast rules remain active,
  with translucent cards, sheets, controls, navigation and report surfaces for both palettes.
- All four theme switches stay synchronized, including the correct browser `theme-color`.
  Runtime and Chromium checks cover every page, cold-start restoration, LTR/RTL, reduced motion,
  final blur values and horizontal overflow. Three full host regressions plus the release
  regression pass; no governor, power/performance policy, APK or resident worker was changed.

**fix225 — the log report now synthesizes evidence instead of merely listing sections**
- A new analytical layer produces an executive summary for drain, thermals, smoothness, deep
  sleep and ASB overhead. It classifies the capture by usage scenario, reports qualitative
  evidence confidence and keeps domain-specific duration/sample floors: a short idle chain,
  fewer than 20,000 frames or absent thermal data produce `unknown`, not a healthy verdict.
- Weighted evidence chains distinguish measured facts from hypotheses. AOD, modem traffic,
  holders and alarms remain possible contributors rather than proven sole causes. Priority
  actions are ranked by severity, limited to three and no longer duplicated among the other
  observations. ASB overhead is reported per wakeup where possible and is never presented as
  proof of net battery savings.
- Capture history now carries device, ROM, module, duration and screen coverage context.
  Numeric trends require the same device/ROM and scenario family plus at least thirty minutes
  in both captures; legacy or incompatible rows show an explanation instead of a fictitious
  improvement. Even compatible trends remain observations, not controlled A/B tests.
- The new JSON action writes a structured schema-2 `report.json` beside the selected capture,
  including capture/device context, quality, scenario, verdicts, facts, hypotheses, actions and
  ASB overhead. Export is UTF-8 safe and shell-quoted. Analysis still reads only files already
  written by the existing recorder: no dumpsys/batterystats calls or resident polling workers
  were added.
- Runtime tests cover evidence floors, scenario selection, causal labels, action ranking,
  legacy history, JSON export and DOM ordering. Chromium checks cover dark/light/Liquid Glass,
  mobile overflow, RTL and reduced motion; the full host regression passes repeatedly. No
  governor ceilings or other runtime power/performance policy were changed.

**fix224 — audit hardening, Liquid Glass, stable Stock thermal history and external LTPO coexistence**
- **The network writer ownership is now unambiguous.** `profile_core.sh` no longer issues a
  second direct `tc qdisc replace`: the capability-aware, read-back and cooldown path in
  `runtime/asb_net_apply.sh` is the sole qdisc owner. Other profile sysctl/settings writes
  are unchanged.
- **A broken route netlink monitor no longer creates another permanent worker.** Its fallback
  is limited to fifteen one-minute polls, is skipped when no active default route exists and
  stops immediately if that route disappears. The existing half-hour reconcile remains the
  retry path; mode and reason are recorded for `asbdiag`.
- **The fictitious `auto_degrade_time_gate` setting is gone from lint.** Diagnostics instead
  expose the effective built-in behavior: classified thermal load needs 120 seconds, while
  gap/ratio and hard-gap degradation remain event-driven. No new public config key was added.
- **Synthesized device bounds are explicitly fail-closed.** Generation now records schema,
  confidence, measured source, policy count, cluster signature and build fingerprint. Both
  native and shell consumers apply overrides only with explicit `confidence=high`; low or
  unknown confidence keeps compiled defaults. Existing generated legacy-high files remain
  compatible, and allow-list/range/post-validation checks remain intact.
- **Liquid Glass is a third opt-in WebUI theme**, beside Dark and Light on Home, Monitor,
  Settings and Report. It uses translucent surfaces and a bounded blur, persists across a
  cold start, synchronizes all four switches and supports LTR/RTL and reduced motion. Dark
  remains the default; no Canvas, WebGL, APK or separate theme engine was introduced.
- **A transient Stock telemetry read no longer erases the last good ROM snapshot.** The last
  thermal trend and its samples/verdict stay visible while a poll fails or returns no data,
  and the next successful poll refreshes them. This proves the reproduced host failure case;
  it is not a claim that every possible device-side disappearance has one cause.
- **Force-LTPO now yields to an active `OnePlus15-165HZ-LTPO` installation.** ASB removes only
  its own previous bind, restores its saved peak/min range and reports the external owner
  instead of fighting the other module's daemon or patching its files. Once that module is
  disabled or removed, the next ASB apply resumes normal ownership. ASB's independent video
  minimum-frequency behavior remains available. Host fixtures cover handoff, cleanup and
  resume; physical OnePlus 15 / ColorOS coexistence still needs a field check.
- Static profile frequencies, the fix223 Battery interaction lift and Smart learning policy
  were not retuned. No unmeasured battery-saving percentage is claimed.

**fix223 — Battery keeps its brief responsiveness lift through a continuous scroll**
- **A second review of every post-fix219 screenshot and capture found a manual-Battery
  responsiveness gap, not a safe reason to move the static profile ceilings.** CPH2745
  Battery touch intervals showed 9.7 % janky frames in LIGHT_IDLE versus 7.1 % in
  MODERATE; on the same CPH2747, Telegram showed 8.1 % under Battery versus 3.7 % under
  Smart, and TikTok 15.6 % versus 6.8 %. These are interaction-specific comparisons,
  not a claim that every jank is caused by CPU frequency.
- Merely letting Battery enter the touch-MODERATE FSM state would not solve the real
  problem: Battery is a manual profile whose ordinary ceilings belong to the shell.
  Instead, sampled active touch now extends an **already armed** three-second unlock /
  launch lift while the finger remains active. The existing writer temporarily borrows
  the manual ceilings at the same 80 % of each device's detected hardware maximum, then
  hands the shell values back after the interaction ends.
- Touch-active alone cannot start a lift. Screen-off, camera, warm-die, thermal-cap and
  profile-change vetoes remain in force, and extending the window does not count as a
  new lift. Smart and Balanced deliberately keep their previous fixed-duration lift.
- Quiet reading, static Battery / Balanced / Performance bounds, GPU limits, screen-off
  and night behaviour are unchanged. No absolute frequencies, ROM APIs, APKs or
  Android-version-specific branches were added; the lift remains hardware-relative.
- Covered by executable long-scroll, expiry, no-arm, thermal, warm-start and other-profile
  runtime cases in `unlock_lift_runtime`, the existing sampled-touch watch test, and a
  fix223 source/writer contract.

**fix222 — the day report stops inventing a night, names AOD when AOD is the holder, and advises on background mobile traffic**
- **Found on the owner's screenshots (CPH2745, ColorOS 17, a running Smart capture at
  19:57):** the report called a 40-minute daytime stretch "the night" — red "1.5 %/h"
  rows, a verdict and a night advice card, before any night had happened. fix220 had
  already disarmed the verdict and the tip; the rows, the card title and the
  "main holder at night" line still treated the stretch as a night. Now, under two
  hours, the card is titled "Longest idle stretch in detail", the spent/awake/deep rows
  stay neutral, and the capture-wide holder is no longer named as the night's holder
  (it was SystemUI's AOD — blamed for a night that never happened).
- **The awake verdict got the same duration floor** (twenty minutes): a five-minute gap
  fully awake used to fire the red tip over pure noise.
- **When the top idle holder is SystemUI and the panel was lit in a tenth or more of the
  screen-off checks, the awake tip names the real cause — the always-on display** — with
  the lit/of counts and the remedy (turn AOD off in the display settings), instead of
  blaming a system app the user cannot and should not rein in. The owner's day: awake
  64 %, holder com.android.systemui, AOD 14 of 67 — the red AOD line sat one card away
  with no connection drawn.
- **The red background-mobile-data line finally has advice next to it** (the owner's
  Smart day: 214.7 MiB with the screen off): over 50 MiB the card names the
  "LTE While Screen Off" switch while it is off; already on, or modest traffic, it stays
  quiet. An old capture without the cfg snapshot reads as the shipped default.
- **The profile table no longer prints "0.0 %/h" over a handful of counted minutes** —
  under twenty counted (charging-excluded) minutes a rate cannot be told apart from one
  battery-percent step, so the cell shows a dash. And the Smart section's "this capture
  ran under a different profile" note no longer fires when the capture merely STARTED
  elsewhere but then ran Smart for hours (the mid-day profile switch).
- No governor, profile or cap numbers moved — these are report-honesty repairs; the
  practical levers the log named (AOD, background traffic) are routed to the switches
  the module already ships.
- Covered by t_webui_log_report_runtime (the AOD and duration-floor tips, the traffic
  tip's switch naming and its quiet cases, 13 locales in key-set parity) and a fix222
  contract.

**fix221 — asbdiag stops calling an absent setting a refusal**
- **Found in other users' diag reports** (six reports, five devices: CPH2747, CPH2653,
  CPH2769 and CPH2691 on ColorOS 16, PLQ110 on ColorOS 17; every one FAIL=0): on
  ColorOS 16
  the report listed `network_recommendations_enabled` — and on the CPH2747 also
  `cloud_dns_happy_eyeballs_priority_enabled` — as "refused, not in effect … the ROM
  blocks this write". But the read-back was empty before AND after the write: these keys
  simply do not exist on those ROMs (the ColorOS 16 SettingsProvider refuses to create
  unknown keys). A refusal is a permission problem a user could chase; an absent key is
  not, and naming it one sent people looking for a ghost.
- The ledger now files the empty-before-and-after signature as **unsupported** — its own
  class for "the key or node does not exist on this device" — with the note "key absent
  on this ROM". The key is remembered in the same per-ROM-build rejected list on BOTH
  failure shapes (write error and silently-ignored write), so it is still never retried:
  nothing about the writes themselves changed.
- asbdiag lists such keys apart: the summary gains "· not on this ROM N" (only when N is
  not zero — a device without absent keys prints exactly the line it always did), and the
  refusal list is followed by a calm "not on this ROM: … nothing is wrong" line. Only
  settings keys count; an unsupported sysfs node never leaks into the settings list.
- The same logs confirmed the health of the rest: six full-day captures across the five
  devices show zero ASB-attributed crashes, night idle at 0.2–1.6 %/h, and the wake-jank
  pattern fix220 targets (wake intervals jankier than the day's ordinary ones on every
  capture — 13.8 % vs 6.7 % on the Bluetooth-headphones day) on every pre-fix220 build.
- Covered by t_settings_rejected_runtime (absent key → unsupported and remembered; a key
  that exists but refuses is still not_writable), t_asbdiag_settings_summary_runtime (the
  new count and line over a fixture, sysfs nodes excluded) and a fix221 contract.

**fix220 — ColorOS 17 / Android 17: the interaction lift hears the tap and the lock press, and the day report learned to show the wakes**
- **Found on the owner's OnePlus 15 (CPH2745, SM8850) after the move to ColorOS 17 /
  Android 17** (two full-day captures, Smart and Battery): app open/close and
  lock/unlock animations visibly janked on both capped profiles. The captures named the
  mechanism: the fix212 app-switch arm is detected on the governor's next metrics tick —
  up to 2 s after the tap, when the animation's critical frames have already rendered —
  and the lock press had no arm at all, so the fade-out ran on whatever ceilings the idle
  moment had (Battery wake rows in LIGHT_IDLE: 8–22 % janky; SystemUI the top wake janker
  at every unlock: 13.6 % of its wake frames on Battery, 7.3 % on Smart).
- Two earlier signals now arm the same 3 s ceilings-only lift (unlock_lift_pct of the
  hardware maximum, uclamp top-app to the same share). **The first touch after a calm
  spell** — the tap that starts every open/close/switch; the touchscreen is already in
  epoll, so the lift lands before the animation's first frames. **The power key with the
  screen on** — the lock press; the fade-out renders before Android publishes the display
  state. Both share the app switch's 5 s gap and all its gates (off / Performance /
  thermal / warm die), so a reading session buys one short lift per burst of interaction,
  not an unbroken boost. To hear the lock press the wake keys stay in epoll while the
  screen is on — except the touch panel's own gesture node, which would wake the loop on
  every frame of a scroll. The profiles' static caps are UNTOUCHED: Battery stays
  50/38 %, the lift is a short ceiling-only burst that costs nothing when nothing moves.
- **The day report grew the part the owner asked for.** New digest lines, rendered by the
  sheet: wake smoothness (N wakes, jank at the wakes against the day's ordinary
  intervals, the top wake janker with its share), smoothness by moment of the day
  (post_wake / audio / active) and by the governor's own state (a janky LIGHT_IDLE next
  to a calm MODERATE is ceilings too tight for the moment, not a slow phone), and the
  current-sensor gauge check — on the OP15 current_now integrates to ×0.34 of the
  battery's own count, so every mA figure is now labelled a lower bound where it shows.
  A new advice card fires when the wakes clearly stutter above the day and names the app
  doing it.
- **Two precision repairs in the same sheet, both from the owner's screenshots:** the
  night verdict (hero, advice card and the detail verdict) no longer turns red under two
  hours — one battery-percent step over 40 idle minutes reads as 1.5 %/h and painted an
  "expensive night" over pure noise (fix211 had taught the screen-off row the same
  lesson); and the speaker row follows its own advice rule — red from half an hour of
  loud playback, not from one 6-minute video at 27 %/h.
- Covered by t_unlock_lift_runtime (the tap and the lock press arm once per 5 s, gated
  like a wake; a press in the dark stays a wake hint), t_webui_log_report_runtime (new
  digest lines over a fixture, the parser, the guards, 13 locales in key-set parity) and
  a fix220 contract.

**fix219 — the report blamed every throttle period on whoever clamped last**
- **Found on the same field capture (full-day log 6969), after a profile-health review of
  the whole day.** The profiles and the module came out healthy: the ceilings held all
  day (two uncapped rows, both in the capture's first minute), the vendor thermal engine
  owned the stricter prime clamp in 89 of 100 throttle samples and ASB accepted it
  without a fight, the day's jank was not cap-correlated (10.6 % of frames janky while
  at a cap against 18.4 % while not — the caps are not what stutters), the night cost
  0.7 %/h at 91 % deep sleep, and ASB's own cost was 1361 ms of CPU per hour. One thing
  was genuinely wrong — and it was in the report, not the runtime: the thermal section
  read "Throttling periods: 16 (asb)". The digest counted the periods correctly but kept
  only the LAST period's owner, so whoever clamped last took the blame for the whole
  day — the trace actually shows 3 ASB periods, 6 vendor, 6 shell (the profile's own
  static ceilings) and 1 unknown.
- The throttle line now reports the dominant owner (the one with the most periods; the
  more recent one wins a tie) and carries the full per-owner split along, and the sheet
  names every owner: "Throttling periods: 16 (ROM 6 · profile 6 · ASB 3 · ? 1)". The
  display uses the existing clamp string — no new locale keys.
- **Test hygiene, found while proving the above:** the deleted-folder recovery runtime
  test could fail once in a full-suite run when the host, under the suite's fork
  pressure, misread a tiny lock file as empty — the helper then (correctly) fails
  closed with "already running" instead of recovering the slot. The test now checks the
  fixture's output_dir actually read and deleted, and retries the idempotent start once:
  a transient empty read recovers on the retry, a helper that genuinely lost orphan
  recovery answers "already running" to both attempts and still fails. Module code is
  unchanged — on a device the fail-closed answer is the safe one.

**fix218 — the day report no longer names a recording gap the hottest phase**
- **Found on a field capture (full-day log 6969).** The report's thermal section read
  "Hottest phase: Recording gap" — a sub-two-minute screen-off pause happened to hold
  the day's peak reading (52 °C), and the digest attributed the peak to it. A pause
  inherits the heat of whatever surrounded it; naming it tells the user nothing. The
  peak is now attributed to the hottest *named* phase (the gap minutes still count in
  the minutes-above-45 °C totals — those were and stay correct), and the Hottest-phase
  row shows that phase's own peak temperature next to the name: "Music, speaker · 51°".
- **Cosmetic, same sheet:** the phase table could wrap the drain cell between the
  slash and the unit ("−28% · 11.4%/" / "ч"). A word joiner after the slash forbids
  the break; the cell may still wrap at the "·" before the number.

**fix217 — enabled tweak cards wear the hub-tile look**
- **Purely cosmetic.** The six tweak-category tiles on the Settings hub glow in their
  category hue; enabled tweak cards now do the same. Every tweak row carries its
  `cat-*` class (one render site, `cfgRenderRow`), the category hue map feeds the icon
  *and* the row, and an enabled card takes the tile's exact recipe — the category
  gradient, the tinted border and the soft category-coloured glow — in both the dark
  and the light theme (light shares the deepened light hues with the tiles). Cards
  that are off keep the neutral Monitor-cell material, and the old teal `is-on` rules
  stay as the fallback for rows without a category. No behaviour change: state,
  persistence and live toggling are untouched.

**fix216 — the flaky CI failure: a font filter that matched directories**
- **The debug build failed on `webui_device_font_runtime` — and the cause was a real bug,
  not just a test flake.** The device-font discovery (the WebUI test variant that draws in
  the phone's own font) filtered the font list with family/exclusion tokens
  (`kr`, `mono`, `hans`, …) against the *whole path*. The CI run's mktemp fixture dir was
  named `tmp.5wIeilzKrt` — the "kr" in the random suffix matched the Korean-face
  exclusion, every path under it died, and the test failed. On a device the same shape
  silently drops a user's applied font the moment a directory in its path contains one of
  the tokens. All patterns are anchored to the file name now (`/[^/]*…[^/]*$`), and the
  runtime test reproduces the exact CI layout: a fixture directory named with the
  exclusion tokens must still yield the OnePlus family fallback.
- **CI log noise cleaned up along the way.** The telemetry script's
  `read … < file 2>/dev/null` reported a missing input file on the original stderr
  (redirections apply left to right — the suppression came too late), and the
  settings-wrapper contract piped `grep | grep -q`, whose upstream died with
  "write error: Broken pipe" three times per run. The reads suppress stderr first now,
  and the contract answers with awk's exit code.

**fix215 — metadata files no longer gate the build**
- **The CI debug build failed on `module.prop`/`update.json`, not on code.** The fix213
  audit had pinned the OTA identity *in the always-run host test suite*: an absolute
  `versionCode=65214`, a `> 650` floor, and an exact update.json↔module.prop match. Any
  checkout whose metadata simply had not merged the bump yet (the owner's repo still at
  650, a fork, a debug run) failed the build - a metadata file was deciding whether code
  compiles, which is exactly what must never happen.
- **The check moved to the pipeline that publishes the manifest.** "ASB · Build Release"
  now validates update.json against module.prop (version, versionCode, the zip URL's
  release dir) in a dedicated step before packaging - a stale manifest still cannot
  ship, but no debug or local build can fail on it. The host tests keep only the
  *format* checks (`version=V<number>`, decimal `versionCode`) and pin that both
  workflows keep `update.json` out of the flashable zips and that the release gate
  itself stays in place.
- **Verified end to end:** the whole test battery passes with `versionCode=650` in
  module.prop - the exact state the failing CI run had. `CHANGELOG.md`/`README*` were
  never build gates (lint only reports the identity; the tree checker is not part of CI
  and its manifest ignores module.prop/update.json); this is now covered by contract.

**fix214 — FSM HEAVY at light use, the thermal trend that kept measuring, an honest load figure**
- **FSM sat at HEAVY with two light apps open.** Three causes, from the field trace:
  1. `bat_suppress_gaming` landed on HEAVY *instantly* - one tick with the GPU past the
     gaming gate (an app launch, a scroll fling) held HEAVY's looser rails for a whole
     ~48 s tick. Gaming is still suppressed on Battery, but the escalation now passes the
     same two-tick, CPU-backed gate as every other GPU-led HEAVY.
  2. The "CPU participates" bars were fixed per-core constants (load1 1.2/2.0 on eight
     cores), calibrated on a phone idling near zero. OP15-class devices idle at load1
     6-9, so the bars were true essentially always and every GPU flicker qualified -
     HEAVY at GPU 36% while music played with the screen on. The gate is now the
     device's own learned quiet floor with the burst margin (`asb_cpu_participates`);
     the constants remain the pre-learning fallback.
- **The thermal trend sat at "…" far too often.** Switching to Stock wiped the samples,
  the verdict and the persisted copy - and a profile switch is exactly when the Monitor
  gets opened. The trend is ROM-zone data, profile-agnostic, so the reset keeps it now;
  and the last verdict is restored for ten minutes (samples still two), so a revisit
  shows the last measured direction at once instead of re-measuring for half a minute.
- **"System load 9.4 · 118%" read as an overload that was not there.** The load average
  counts tasks waiting on storage, so its per-core share passes 100% on a phone doing
  almost nothing. The telemetry now publishes the aggregate /proc/stat line and the tile
  shows the *real* CPU-busy share between two readings ("9.4 · 14%"); the loadavg share
  moved to the tooltip, and the info sheet explains both figures in all 13 languages.
- **The report's "recording · N min" could disagree with its own sections by up to
  fifteen minutes.** The elapsed figure came from the interim report, rewritten every
  15 min, while the sections below are computed live; a running capture now derives the
  elapsed time from the ledger and the clock.

**fix213 — the audit build: OTA identity, the GPU thermal node, and a much richer log report**
- **K1/K2 (P0/P1): update.json described V64/640 for three builds.** Managers offered
  users on V65 a "downgrade" whose asset does not exist (404). The manifest now matches
  the module exactly (V65/65213, the 65/ release URL) and a contract test fails the build
  if the two ever drift again: version, versionCode and the zip URL's major are pinned to
  module.prop. versionCode is monotonic from now on (650 was frozen since fix25).
- **K3: the profiles no longer write GPU thermal_pwrlevel.** Battery wrote a static 7,
  Balanced/Performance a static 2 - and the governor reads that node as a *vendor* thermal
  cap, so the shell's own write looked like one (false "vendor clamp" diagnostics, plus a
  static cap fighting the governor's pwrlevel ceiling). The GPU ceiling intent is
  `GPU_MAX_PCT` alone, which the governor already translates into the pwrlevel index. The
  shell releases a stale static level once per boot (writes 0); the vendor thermal engine
  owns the node from then on and re-asserts it the moment it needs to.
- **K4a: asbdiag probes the Smart meter directly.** The recorder's summary only exists
  once the governor has loaded, so a phone without a usable charge_counter stayed silently
  blind - "a week of Smart taught nothing" with no explanation. The report now says which
  of the three it is: no node, a node with no usable figure, or a working node (and then
  the recorder's state says whether it moves).
- **K8: the LSPosed answer names the schema it parsed** (`format=v1`); the WebUI badge for
  an unreadable database now says *why* (`no_sqlite`, `unexpected_schema`, …) instead of a
  bare "set in LSPosed".
- **Log report, four additions (audit 8.1/8.2/8.3/8.8):**
  - *Device context* - the page names the device, SoC, ROM and the module build the capture
    ran on (`meta2` from env.txt, zero extra cost).
  - *Trend* - a finished capture leaves one compact line in `report_history.tsv` (keyed by
    its start minute, last 12 kept, strictly best-effort), and the next report shows the
    delta against earlier days: "Night: 0.6 %/h → 0.4 %/h". The answer to "did what I
    changed actually help?" - the audit's top-priority gap.
  - *Heat durations* - a peak temperature says nothing about cost; the report now shows the
    hottest phase and the minutes spent above 45 °C CPU / 40 °C skin, and the advice speaks
    about heat for the first time: a long hot stretch advises (naming the Throttling Point
    switch when the protection is on Stock), a cool day without a single throttle says so.
  - *Night habits* - the microwake learner's summary ("14 checks · 2.6 a night · ~38 s
    each"), a calm row in the night section instead of an alarm.
- All 13 locales carry the 13 new keys; the report runtime test exercises the new digest
  sections, the history write/dedupe, the heat advice and the trend parsing end to end.

**fix212 — wakes and app switches stop janking on Battery and Balanced**
- The owner's report: small stutters opening and closing apps and at unlock on the Battery
  profile, visible in the log report too. The captures had the number already: his OP15
  Battery day janked **32 % of SystemUI frames** (6476 of 20244) against 3.5-4.4 % on the
  two Smart testers' days. Root cause: the fix150 unlock lift was Smart-only, so on the
  manual profiles a wake ran entirely on the shell's static screen-on ceilings (OP15
  Battery: 50 % main / 38 % prime) with WALT boost off - exactly the seconds SystemUI,
  the launcher and the just-opened app need a burst.
- The unlock lift now covers every capped profile: Battery and Balanced lift the ceilings
  to unlock_lift_pct of the hardware maximum for unlock_lift_s after a wake (and once more
  at the lock-screen swipe), exactly as Smart always has; Performance is never capped and
  skips. A foreground-app switch arms the same short window too - opening, closing or
  switching apps is the same burst as a wake - rate-limited to one arm per 5 s and never
  extending a lift already running.
- While the lift runs on a manual profile the writer deliberately lets the borrowed
  ceilings through above the shell's caps (that is the lift's whole point), marks the
  paths held and hands the shell's values back on the first pass after the window -
  the existing fix183 hand-back, nothing new invented. The cap-ownership diagnostics
  yield during the window, so the lifted ceilings never read as a vendor clamp.
- Identity preserved: the profiles' static values are untouched (Battery stays Battery),
  and the lift is ceilings only - no floor is raised, so the clocks climb only if the
  wake or the launch actually asks, and the vendor's own boost is honoured again the rest
  of the time. A thermal cap or a warm die still refuses the lift.
- New runtime coverage: Battery/Balanced wakes lift, Performance skips with "profile",
  an app switch arms once per 5 s and never during a running lift, a mid-lift switch to
  Performance ends it, thermal/warm gates apply to launches too, and the shell-ownership
  rule yields while the governor holds the ceilings.

**fix211 — the Battery profile really did leak into Smart's learning; the own-cost tip stops crying wolf**
- The owner's suspicion - "Экономия in that number influences Смарт" - was correct, and
  three captures (his OP15 on Battery, two testers on Smart) pinned it. Session banking
  gated on the smart_mode_enabled flag alone, and a live profile switch over the socket
  never re-read that flag: after Smart → Battery the governor kept the stale in-memory
  1, and whole manual-policy sessions were banked into Smart's buckets (the per-app
  records already refused them - they check the profile). The banking gate now also
  requires fsm.profile_idx == PROFILE_SMART, and the profile-change handler re-syncs
  the in-memory flag from the file on every switch. The drain carry/reset that lived
  inside the banked block got an unconditional fallback for non-Smart sessions, so the
  accumulators cannot leak into the next Smart session either.
- The asbcost tip read ms/h against an absolute 2500: a busy Smart day (3627 ms/h)
  told the owner to mail the developer, at 3.0 ms per wake - the same per-wake price
  as the healthy captures (3.2 and 3.9). The tip now judges the per-wake price
  (cheap at or under 8 ms a wake) and keeps the absolute figure only for a capture
  with no wake count.
- Two noise gates from the same captures: the screen-off drain warns only with 30+
  minutes of off data (an 11-minute window read a red 5.2 %/h), and the AOD verdict
  needs 20+ checks before it can go red (1 of 4 lit checks is not an AOD problem).
- Files: src/asb_governor.c, webroot/index.html, tests/asb_system.sh, tests/asb_ui.sh.

**fix210 — GAMING on the manual profiles was a guess with no package table; the wake section finally names what woke the phone**
- The owner's Balanced capture showed FSM=GAMING at GPU 57 % and load 7.1 while he was
  scrolling a feed. Root cause: the foreground-package classification ran only inside
  asb_smart_tick, which returns early unless Smart is active - so on Battery, Balanced
  and Performance the app hint stayed 0 all day, and the FSM's GAMING gate counts
  "no package information" as agreement. Any busy GPU next to a busy CPU read as a game.
  asb_fg_classify_tick now mirrors Smart's classification on the manual profiles - the
  same detector, the same ten-second cache, the same stale-cache demotion, the same heat
  inference with the camera (fix120) and media guards, the same wake-edge re-read
  (fix186) - and runs before BOTH app_hint publishes (startup and the main loop). The
  no-signal fallback keeps Smart's load heuristic and, like Smart's, never invents
  GAMING. With Smart active the function is a no-op: Smart owns the classification.
  A feed under that exact load now reads MEDIUM; a known game keeps GAMING; a paused
  game steps down; a hot GPU-busy unlisted app is still inferred as a game, exactly as
  Smart does it.
- The Monitor's thermal trend kept showing "…": the verdict needs three samples over a
  30 s span, and a recreated WebView threw them away - on a real phone that is every
  visit. The samples and the last verdict now persist in localStorage (fresh to 115 s,
  so the oldest restored sample still counts at the next 10 s read), and the monitor
  reset drops the persisted entry.
- The wake section said "holders not recorded" next to a restless 30 %-awake idle while
  the capture plainly knew the causes. Held-time counters stay flat while charging and
  on some ROM builds never move - but the wakelock report counts OCCURRENCES, and those
  existed all along. The digest now surfaces them: the top partial-wakelock holders by
  count (wlt), the top alarm/wakeup sources by count (wla), and the idle/sleep mobile
  traffic split off the day-wide total (sradio). The sheet renders all three in "What
  woke the phone" and the awake tip names the loudest alarm, else the loudest holder,
  instead of the generic "something prevents deep sleep".
- The drain percentages that looked contradictory between Monitor and the log report
  are not a bug - four different windows, four right answers (verified numerically on
  three field captures). The sheet now says so itself, right under the screen rows:
  the Monitor tiles count only calm stretches of an hour or more, the report rows cover
  the whole capture.
- Files: `src/asb_governor.c`, `webroot/index.html`, `tools/logkit/asb_fullday_digest.sh`,
  all 13 `webroot/i18n/*.json` (7 new keys), runtime test
  `fg_classify_manual_gaming_runtime`, the fix210 contract, the fix120 contract count
  (2 -> 4 guarded heat branches), the log-report UI test extended with a wakelock-report
  fixture.


**fix209 — Smart teaches heat against THIS device; a night nobody confirmed still counts as one**
- The session learner's heat thresholds were absolute: a session with a peak under 70 C
  taught nothing about heat, 80 C was "very hot", under 55 C taught "clean and cool".
  Those are the reference OP15's numbers - a phone whose sensors sit ten degrees warmer
  would be taught "hot" by a perfectly normal session, and one that runs cooler would
  never learn anything about heat at all. The thresholds now ride on the device's OWN
  learned median temperature (the same per-bucket median the warm/cool boundaries
  already use, fix-verified across devices): hot = median + 25 C, very hot = +35 C,
  clean-cool = +10 C, each clamped to a sane band so a phone with too little history
  or a wild median still teaches sensibly. With no median learned yet the absolute
  thresholds apply exactly as before, and a median of 45 C reproduces the old numbers
  to the degree - so nothing changes on the reference device and every other device
  stops being measured by its ruler.
- The night-check learner had a hole a capture showed plainly: twenty checks banked,
  nights=0. A night whose morning never confirmed (an irregular wake, a rejected
  sample) never received night_end, so tonight kept counting across days, the
  half-hour slot weights never faded - and the first morning that finally confirmed
  would have folded all of it into one "night" of twenty checks, and per_night would
  have read every later night screen-on as a check for weeks (the modem held in night
  mode through real mornings). A note landing ten or more hours after the previous one
  now closes the pending night first: tonight folds into the per-night average, the
  habits fade their 3 %, and the fold counts at most four checks, because an
  accumulation of unknown length is not one night's habit. A night that confirmed
  normally is never folded twice.
- Files: `src/asb_smart.h`, `src/asb_governor.c`, `src/asb_record.h`, tests
  `test_bucket_learn_relative_thresholds` (seven cases incl. both phone temperaments
  and the no-median fallback), lazy-fold assertions in `t_smart_records_runtime`,
  the fix209 contract.

**fix208 — a night of its own, and advice from measured profiles**
- New "Night in detail" section, right after the drain hero (when the capture holds a
  night chain of 15+ minutes): what the night cost and at what pace, the deep-sleep and
  awake shares, the weighted average current, the rmnet radio traffic over the chain
  (a modem that talks all night is the classic night drain), peak CPU and skin
  temperatures, the loudest live wakelock holder, the always-on display's share - and
  a plain three-tier verdict, so a good night says so and a bad one says why.
- The profile comparison now talks back: when two or more profiles each held the screen
  for half an hour in one capture, a tip quotes the measured cheapest against the
  measured priciest screen-on drain (one tester day: battery 1.6 %/h vs performance
  6.1 %/h) - the phone's own numbers, not generic advice. Fires only on a real 2x gap.
- Log follow-up: the 91/99-minute "owner=asb" clamps one tester saw at night on
  Performance with a wireless pad are the thermal-budget/idle system working as designed
  (cap_owner=asb, DEEP_IDLE, mild temperatures) - not a governor bug, so no governor
  change; the report now shows the evidence instead.

**fix207 — the report explains its own numbers**
- The wake section could print "no wakelocks - excellent" under a tip saying the idle
  was restless: batterystats had recorded nothing, and the sheet treated silence as
  cleanliness. It now says the counters stayed flat and points at the full report,
  and lists the kernel wakelock holders sampled on the charger (the only named holders
  on a charging day).
- "Самый долгий простой 0.7 %/ч" vs Monitor's "Экран выкл 1.3 %/ч": three windows, three
  right answers. The night hero is one deep-sleep-heavy chain, the Monitor meter averages
  clean hour-plus stretches without music, and the sheet now also shows the whole-ledger
  screen on/off drain split next to the durations. The night hero carries the deep-sleep
  share. New "Phase breakdown" section: every stretch of the day with its time, signed
  drop (a plus is charge gained) and drain rate.

**fix206 — Profiles scrolls everywhere; the log report reads the day properly**
- "Монитор листается, Профили не листаются": a KernelSU-family WebView host
  gesture-scrolls overflowing elements but not the document, and Home was the last
  document-scrolled page. It is now a self-scrolling fixed overlay exactly like the
  Monitor page (element scroll works in every host), centered with margin:auto - a
  translateX centering would break under prefers-reduced-motion. asbFitPages measures it
  through the overlay path and sizes the cards against the overlay's own scroll offset.
- The log report learned from three field captures. It hid the real wake story whenever
  batterystats counted nothing (a flat per-uid delta printed "no wakelocks - excellent"
  while the power manager saw MountServiceIdler in 23% of screen-off samples); the wake
  section now also lists the live holders the report samples directly, and the "awake"
  advice names the top one. A day on the charger was invisible: the sheet now shows
  charging time, gain and sessions (one tester: +62% over ~400 min of 5W wireless).
  A day spent switching profiles gets a per-profile comparison table (screen/idle %/h,
  active minutes only - from the battery trace's profile field). The display section
  reports the LTPO video drop when it engaged, the drain section names the always-on
  display's share of screen-off time, and the Smart section notes that usage records
  only learn under the Smart profile.

**fix205 — the log report keeps its header**
- Every page back to normal after fix204 except the log report: its header (logo,
  title, capsules) sat squashed. The report is a long list BY DESIGN and scrolls; its
  content sections are not tier-styled at all, so the compaction tiers there compressed
  only the shared header and bought zero room. The tiers now apply only where their
  styled content lives (Profiles, Monitor, the Settings hub): the report and an open
  tweak category never take a tier, and a tier carried over from another page comes off
  while they are open. Covered by t_webui_fill_pages_runtime (the report never compacts
  even 2380 px past the fit line, a carried-over tier resets, an open category is
  exempt, the hub still compacts) and the fix205 contract.

**fix204 — the report's crash counter no longer changes under your eyes**
- A live capture at "0 min of 24 h" counted four native crashes (latest
  com.oplus.screenshot - the system screenshot tool that had crashed BEFORE the
  recording); a few minutes later the same section read "no crashes". A capture that
  just started has neither the phase ledger nor the interim report (the first snapshot
  lands after fifteen minutes), so the digest's crash window fell back to "the last
  24h" and counted pre-capture tombstones - which then fell out of the window the
  moment the first ledger row landed. The window of a running capture with no ledger
  yet now opens at the capture's own launch (stamped on the WebUI lock's pid file),
  and the ledger's leading comment line no longer poses as the first data row. The
  sheet also names WHEN the latest crash happened ("latest: proc, HH:MM"), so an entry
  can be placed ("that was when I took the screenshot") instead of raising "who
  crashed and why". Covered by t_webui_log_report_runtime (fixture captures, including
  a fresh running one with a live lock) and the fix204 contract.

**fix203 — the compaction stops misfiring on screens that fit**
- The day after fix202 the owner's OnePlus 15 showed Config, Monitor and Profiles
  squeezed into the top of the screen with a void above the navigation bar - "the first
  paint is fine, a second later it looks like this". Four causes, all in the measurement.
  The overflow reading counted the floating bar's reserved bottom padding, so a page that
  fit exactly read a full bar's height too tall. The overlays were measured through
  scrollHeight, which never reads below a fixed box's own clientHeight - Monitor and
  Settings reported the bar's height of overflow even with short content. The measurement
  ran AFTER the cards had grown into the freed space, so every tier read "just fits" and
  the hysteresis trial latched it forever. And the cards can only shrink to their natural
  height (min-height only), so the compaction freed space nothing re-absorbed - hence the
  void. The decision is now taken from the page as it asks to be: the fitted card heights
  are zeroed for the measurement and restored after, a fixed overlay is unclamped
  (bottom/height auto) for one synchronous layout, and the reading is the content's own
  bottom edge against a fit line 20 px above the bar, the reserved padding excluded. And
  compaction is the heavy tool, not the first one: an overflow within a fifth of the
  screen (at least 56 px) keeps the normal look and simply scrolls (the fix201 fallback);
  the tiers go on only past that. A tier comes off when the lighter tier fits within the
  same allowance minus an 8 px margin.
- t_webui_fill_pages_runtime drives the real asbFitPages against the new measurement:
  the owner's tall-screen case stays tier 0 with a touch of scrolling, escalation still
  reaches tier 2 on a genuinely short screen, the floors step down (68/58/48 px cards,
  104/92/80 px tiles), the hysteresis keeps a tier that would flip back, and the
  Settings tiles compact the same way. A fix203 contract pins the structure.

**fix202 — the pages fit one screen, the way they were meant to**
- The design intent was always "no scrolling needed": every page visible whole, at any
  screen density. fix168 went halfway - it measured the free height and GREW the profile
  cards and Settings tiles into it, but on a short or dense screen it simply hit its
  floors and the page clipped (the fix201 reports). The missing half is in: asbFitPages
  now measures how far the page the user is looking at runs past its viewport (the
  document for Home, the scrolling overlay itself for Monitor, Settings and the log
  report) and compacts in two measured tiers, asb-fit-c1 and asb-fit-c2 on <html>: the
  top gap, the logo, the wordmark and the capsule rows shrink first, then the cards,
  the Monitor cells, the Smart banner and the support rail. The card/tile floors step
  down with the tier (68/58/48 px, 104/92/80 px), so most screens that needed a scroll
  now fit whole. A tier comes off only when a trial fit leaves real slack, so the layout
  cannot flip-flop at a boundary - and if even tier 2 overflows, the fix201 scroll
  remains as the fallback: nothing is ever clipped away.
- The check runs on resize and rotation, when Monitor/Settings/the report open or close,
  when a Settings category returns to the hub, and after the report's content lands -
  the header wraps differently in each language, so it is measured, never assumed.
  t_webui_fill_pages_runtime drives the real asbFitPages in node against measured boxes:
  escalation tier by tier while the page overflows, the hysteresis (a 2 px fit does not
  take the lighter tier back), de-compaction when the room returns, and the tiered floors
  on both Home and Settings. A fix202 contract pins the structure.

**fix201 — the pages that would not scroll, and the installer's bash parse**
- Two users reported "can't scroll down, there are more cards" (an OP15 Monitor screenshot
  cut mid-card, an Ace 5 confirming). Two causes. html/body were height:100%, which with
  overflow-x:hidden computes overflow-y to auto: BODY became the scroll container while
  the document had nothing to scroll - and WebViews that gesture-scroll only the document
  showed a page that does not move. They are min-height:100% now: the page grows, the
  document scrolls, and short content still fills exactly one viewport via .page's
  min-height, so the no-jelly property is unchanged. And .live-page carried
  overflow-y:hidden in portrait (only landscape media queries re-enabled it), clipping the
  Monitor page below the fold; portrait scrolls now. Pinned by t_webui_page_scroll.
- The fix192-era static audit's P0 was real: common/install.sh failed bash -n with the
  error pointing at line 551. The actual cause sits at line 259's default string
  ("...module's WebUI..."): an apostrophe inside ${var:-...} inside double quotes is
  literal text for POSIX sh/mksh but OPENS a single quote for bash, whose quote parity
  then flips for the rest of the file. mksh on device always parsed it right - nothing
  user-facing was broken - but the installer must be clean under every shell a developer
  or CI touches. Reworded the default; lint now parse-checks the whole installer family
  (install/customize/service/post-fs-data/uninstall/action/apply_profile) under BOTH sh
  and bash, and a fix201 contract re-parses them.
- The same audit asked for a locale key-parity check: added - every locale must carry
  exactly the English key set. It immediately caught a real drift: t_cfg_video existed in
  12 locales but not in en.json. Fixed; all 13 locales now carry the same 692 keys.

**fix200 — the log report reads like a day review, not a battery note**
- The "Log report" sheet grew from one drain summary into the full picture of the day.
  New sections: Smoothness (janky-frame share and stutter rate with the real per-app
  frame table, up to four apps), Display (how long the panel spent at each refresh rate
  and what each rate drew), Smart learner (verdicts reached, apps watched, tests running),
  ASB's own cost (governor CPU ms/h, writes and timer wakeups per hour), speaker playback
  and the charge types seen. All numbers are mined from the recorder's own interim report
  and smart_records - no dumpsys, no extra battery cost, works identically in every
  profile.
- A saved capture is now usable on its own: the digest resolves the newest
  asb_log_full_day_* folder when no capture is running, and the sheet names what it shows
  - "saved capture · 2026-10-21 15:10 · Smart" - instead of pretending it is live.
- The advice engine learned to point at the fix: when a finding maps to one switch, the
  tip names it exactly as the Settings screen names it, in the UI language ("…turn on
  «Act on Wakelocks»…"). Advice follows the CURRENT settings, so a week-old saved log
  still suggests what helps today. Worst findings first, at most six cards.
- Everything renders via textContent with per-cell warning accents; the per-app and
  per-rate tables ellipsize long package names instead of breaking the layout. All new
  strings live in the 13 locale files. The runtime test drives the real digest over a
  fixture capture plus the real parser/tips in node, and a fix200 contract pins the
  digest lines, the tables and the advice engine.

**fix199 — the build no longer reads the changelog**
- A CI run failed on "CHANGELOG is silent about fix198": the fix198 contract pinned the
  changelog, and lint warned when it had no heading for the version. The changelog is kept
  by hand in the owner's repo, so a stale or missing one must never gate a build. Both
  readers are gone - no test, no lint check, nothing in the regression may consult
  CHANGELOG.md any more. The file stays in the delivery and in the tree manifest as what
  it is: release notes for people, not a gate for the build. (fix198's own note: the two
  pins above were the only failure in that CI run - every code, runtime and UI check
  passed.)

**fix198 — the smoothness check actually engages, and its test always ends**
- Two full-day captures (OP12 23514, Ace 6 25880) showed Smart's smoothness learner
  watching six / three apps for the whole day and never testing one: the entry bar was
  "8 % janky of 3000+ frames", above anything a healthy flagship's apps reach - the
  jankiest app of the OP12's day sat at 7.0 % of 122k frames, and the Ace 6's day was
  1.0 % overall. The bar is now 5 %, where missed frames become visible (six a second at
  120 fps). Nothing changes on a phone that is simply smooth: with no app over the bar no
  test ever runs, and the A/B test itself still decides whether the clocks are the cause.
- The same review found the test's bound broken: an app that draws little while it is
  watched (a chat left on screen, short bursts over days) could collect six windows per
  arm without the 4000-frame floor and would then stay in the test forever - half its
  foreground time at more headroom, all of it excluded from the records. A full test now
  always ends: headroom is kept only with the full evidence behind it, otherwise the app
  is marked "not helped by clocks" and left exactly as it was.

**fix197 — capsule controls, a clean LSPosed modules log, back from the report**
- The segment control (the option buttons on the tweak cards) and the toggle switch were
  the last flat controls in Settings: a plain bordered box with the selected half painted
  solid, and a grey slab track. Both now wear the navigation bar's own floating-capsule
  material (fix192) - the wash over the opaque base, the thin teal edge, the lit top line -
  with the selected option's tonal pill floating inside the segment the way the bar's tab
  indicator does, and the switch pouring the accent wash into the capsule when on. Light
  theme gets the same white-capsule treatment as the light bar.
- The "LSPosed Verbose Log" card now keeps the MODULES log clean as well. That log - what
  the LSPosed modules themselves write - has no switch in LSPosed and grew to 40 MB on the
  owner's OP15 with the verbose log already off. Setting the card to off empties it at once
  (truncated in place, exactly what LSPosed's own manager does on "clear log" - the daemon
  appends, so the log simply grows again from empty), and a low-frequency loop in
  service.sh sweeps it every ten minutes while the card says off. The sweep writes no
  setting and keeps no record; "keep" still leaves LSPosed completely alone, and the
  LSPosed setting itself is still never written at boot. The card's description says so in
  all 13 languages.
- The back gesture on the log report page closed the whole WebUI. The report is a page in
  the WebUI's back history now, like Monitor, Settings and every window: back from the
  report returns to the page it was opened from (Escape does the same), and only back on
  Home leaves. Covered by the node back-navigation runtime test with the report layered
  over Home and over Settings.
**fix196 — field-report pass over the first tester diags (OP15 fix192 + OP12 debug10)**
- Two asbdiag reports from the field (an OP15 on Smart and an OP12) both read healthy
  (FAIL=0) but carried one corrupted line each: the LTPO range diagnostic printed
  "refresh range: max_mode=120 peak=120.0 min= recorded=peak=120.0 min=__unset". The
  floor key is deleted on purpose once the range is open, so the empty `min=` is the
  open range - and the recorded originals glued straight onto it. The diagnostic now
  prints `min=none (floor open) original: peak=… min=…`, pinned by the ltpo range
  runtime test in all three baseline shapes (recorded, unset, video-held peak).
- The action sheet's idle line disagreed with the WebUI on the same phone in the same
  minute: "idle measured 0.63 %/h (6 windows)" against the Smart card's 0.42 %/h. The
  sheet read the phone-wide figure while the cards show the current profile's own
  measurement (fix189). The action page now prefers the active profile's figure with
  its own window count and falls back to the phone-wide one for a profile with no
  clean screen-off window yet - covered by a runtime test that cuts the real block out
  of action.sh and feeds it both scopes.
- The prime-ceiling line on the action sheet read "efficient minimum (asked 1497 MHz)"
  next to a 1862 MHz ceiling: the number it called "asked" was the efficiency rail's
  wish, while the writer's actual request is the race-to-idle floor (1862). The label
  now says what happened - the efficiency rail asked X, the responsiveness floor keeps
  the ceiling higher - in all 12 action locales, with the %s placeholder pinned.
- The OP12 report carried a WARN for the little-cluster minimum held at 672000 for the
  whole 3 s watch. That is the platform's touch boost on uag/qcom-cpufreq-hw doing
  exactly what walt does on SM8850 - and running asbdiag is itself a touch. The uag
  and qcom-cpufreq-hw stacks now take the NOTE branch like scmi/walt instead of a WARN
  that blames nobody actionable. system/bin/asbdiag re-synced (fix191 contract).
- What the reports also showed, no code change needed: the OP12's prime at 51% of hw
  below ASB's written 2035200 is the vendor thermal clamp (all four clusters pinned at
  1708800 at the snapshot), already detected and reported; its 3.42 %/h screen-off
  drain traces to an always-on VPN's keepalives and a 90-minute Wi-Fi multicast hold
  by uid u0a137 - the report names both, and night_modem_idle is off by that user's
  own choice.

**fix195 — the log report becomes a full page; the Settings tiles get their colour back**
- The report from fix194 was a bottom sheet; there is too much in a 24h capture for a
  sheet. It is now its own page - the same floating header (device line, chip and
  version capsules, theme switch, the profile island with Logs and Channel) and the
  same tab bar as every other screen, with a Refresh chip that re-reads the capture
  without leaving the page. It opens over whichever page the Logs menu was on and a
  tab tap or the back chip closes back to exactly there. Each section leads with an
  emoji marker, the headline numbers sit on big "hero" tiles in the Monitor material
  (average drain with mA, the longest idle stretch, peak CPU and skin temperatures),
  and a capture that has not been started yet gets a proper empty state instead of an
  error.
- The fix193 Settings surfaces read as flat grey slabs next to Monitor - the wash
  gradients sat on a near-black base that swallowed them. The tiles and tweak rows are
  back on the fix192 recipe: the category hue as a three-stop gradient over a
  transparent base with a soft hue glow, and the rows in Monitor's own material - a
  faint white gradient, the shared border, a lit inner top edge. The `--cat` token
  architecture from fix193 is unchanged; only what the tokens paint was restored.
  Light theme is untouched (it always overrode these rules).
- Two readability fixes in the report itself. The app font stack now ends in the colour
  emoji families, so the section markers render as emoji on WebView builds that skip
  system fallback for the requested weight instead of showing boxes. And wakelock
  holds under a minute printed "0 min" next to an app that did hold the phone -
  sub-minute holds now read in seconds (new `lr_secs` key in all 13 locales).
- Both behaviours pinned in `t_webui_log_report_runtime`: `logReportDurSec` exercised
  in node in ru and en, the seconds key and its `{n}` placeholder checked across all
  13 locales, the emoji fallback pinned in the font stack, and
  `t_webui_fill_pages_runtime` guards the restored tile/row gradients (including that
  the grey base colour does not return, comments stripped before the check).

**fix194 — the Logs menu reads the 24h capture back to you, in plain words**
- The 24h log always collected everything worth knowing - drain per phase, the night
  stretch, which apps held the phone awake, native crashes, SystemUI restarts, thermal
  clamps - but the report it wrote was a developer's text file. The Logs menu now has a
  third entry, "Log report": a sheet that answers "how is my phone doing" in plain
  words. It works on the RUNNING capture too - the digest folds in the still-open phase,
  so the numbers move as the day goes on - and it is not behind the debug-build gate,
  because reading what the phone already wrote harms nothing.
- The data path is a new `tools/logkit/asb_fullday_digest.sh`: awk over the recorder's
  own artifacts (phase ledger, battery trace, wakelock deltas, tombstones, the throttle
  trace), no dumpsys, so the sheet opens instantly even at hour twenty. It finds the
  capture on its own - the running one via the WebUI launch lock, else the newest
  capture directory - and prints one TAB-separated line per fact.
- The sheet renders five sections in the capsule material: Battery drain (average %/h,
  screen on/off split, the longest idle stretch, mobile data), What kept the phone
  awake (top five apps by held wakelock time), Errors & crashes (native crashes inside
  the capture window, with an explicit flag when ASB's own code is involved, plus
  SystemUI restarts), Thermals & throttling, and What it means - advice in one line per
  finding: an idle stretch over 0.8 %/h, a phase that stayed awake, an app that held
  the phone for over an hour. All 13 locales; device data (package names, crash
  cmdlines) goes in via textContent only.
- Guarded by `t_webui_log_report_runtime`: the real digest against a fixture capture
  (night chain, wakelock attribution, tombstone window, clamp periods), the real parser
  and tip logic in node against the shipped ru/en locales, placeholder parity across
  all 13 locales, and the workflow packaging pins so the script cannot silently fall
  out of the zips.

**fix193 — the Settings page joins the capsule design; the category palette reworked**
- Asked to carry the new tab-bar/header style onto the Settings page and to rework the
  category colours (and with them the colours of the tweaks inside). The six hub tiles
  are no longer saturated colour slabs: they are capsules in the bar's own material -
  near-black base, faint wash, thin edge, lit inner top line - with the category hue as
  a whisper over it and the icon on a tonal pill of the same hue. The tweak cards, the
  search field, the toolbar buttons and the three restart tiles share the same capsule
  surface, and the selected option of a segment control wears the bar's tonal pill, so
  "this one is chosen" looks identical everywhere in the app.
- One hue token per category (`--cat`) now feeds the hub tile, the section heading, the
  tweak icons and the toast through color-mix: the fourteen hand-tuned rgba pairs that
  drifted a notch with every edit collapsed into single rules. The palette itself is a
  quieter family - rose Audio, azure Camera, mint Battery, honey System tweaks, cyan
  Network, lilac Interface, steel for the neutral sections - pastel over the near-black
  instead of neon. The light theme deepens the same tokens once for every consumer.
- WebUI only: no binary change. The fix174/175 tile pins in `t_webui_fill_pages_runtime`
  became the capsule-recipe contract (token per category, generic active-icon pill,
  pill on the selected segment option).

**fix192 — the header in the navigation bar's style, on all three pages**
- Asked for the header to match the new bottom bar. The header is now made of the bar's own
  floating capsules - the same near-black base, faint teal-to-cyan wash, thin teal edge and lit
  inner top line - defined once as shared tokens (`--cap-*`, `--pill-*`) that the bar uses too,
  so the two cannot drift apart again. Chip and version share one capsule as plain text split by
  a hairline (information, not buttons); the theme switch is a two-segment capsule with the
  bar's tonal pill sliding behind the chosen icon (it follows the attribute that actually themes
  the page, mirrored for Arabic); the current profile sits on the same pill, and Logs/Channel
  are plain icon-and-label buttons after a hairline, like the tabs. The open Logs menu marks its
  button with the pill. Light theme: white capsules with the pale teal pill.
- The island no longer breaks onto a second line. Inside a Settings category Back used to drop
  onto its own lopsided row (every language); Monitor's "SMART → PERFORMANCE" and the Armenian
  labels wrapped as well. Back is now an outlined accent button in the row, and Logs/Channel fold
  to their icons inside a category or whenever the row would otherwise wrap - measured at
  runtime, so font, UI scale and locale are all covered. The header is no taller than before
  (the Settings hub still fits one screen).
- WebUI only: no binary change. New test `t_webui_header_capsules` (static checks plus the fit
  logic run in node), updated theme-switch pins, the fix192 contract.

**fix191 — Battery and Balanced: app launches no longer capped harder than ordinary use; asbdiag on Performance**
- Asked to look over the other profiles. In Battery and Balanced the shell owns the CPU
  ceilings, but in HEAVY, GAMING and SUSTAINED the governor's reassert still registered its own
  FSM rail in msm_performance (a second ceiling the kernel obeys) and, under a vendor clamp,
  wrote it to scaling_max_freq. On an OP15 that rail sits under the profile: Balanced has no
  screen-on cap (3628800/4608000) and a rail of 2611200/3974400; Battery's shell holds
  1785600/1747200 over a rail of 1670400/1632000. So HEAVY - app launches and heavy pages - ran
  capped harder than ordinary use, the fix186 bug on the manual profiles. The Balanced capture
  of fix189 shows it once: cap_verify found msm_performance holding 2361600 on the main cores,
  exactly the governor's declared rail. Now, in a manual profile, HEAVY and GAMING never ask for
  less than the profile's own ceiling and SUSTAINED (the cooling state) never for more; the
  values are snapped and floored like every other ceiling. Smart and Performance own their
  ceilings and keep their rail.
- asbdiag said "ASB applies NO cap in performance". The governor owns the ceilings in
  Performance and runs its state ladder on the Performance rails (lower in light use, the rail's
  top under load, gaming_cpu_max_ceiling_khz in GAMING); only the shell writes no cap there.
  The line now says that, and names a live ceiling under what ASB wrote as someone else's.
- Files: `src/asb_writer.h`, `src/asb_governor.c`, `tools/asb_diag.sh`, `system/bin/asbdiag`,
  test `t_reassert_manual_ceiling_runtime`, the fix191 contract.

**fix190 — Monitor tiles from screenshots taken on the charger a few minutes after a boot**
- Six OP15 screenshots (Balanced, Smart, home, Stock, Battery, Performance), on the charger, 3-5
  minutes after boot. Balanced now runs uncapped (3398 MHz, headroom 75 %) - fix189 holds.
- "Who set the limit" read the main cluster only: Performance - which caps nothing - and
  Battery said "ASB" beside "Headroom 35 %", a figure from the most limited cluster, the prime
  held at 1632000 by the vendor's clamp while charging after a boot. A foreign owner on either
  cluster is now the one shown, and the tooltip names the owner of each.
- "38/ч · 38 всего" broke over two lines once both counts had two digits, the only tile that
  did; where it does not fit, the word after the total goes (the tooltip says what both are).
- The Smart slot tile was cut to "вечер…" where the day part and the weekday pill did not fit;
  the pill goes there, the tooltip keeps it.
- Basis on the charger: "⚡ charging" instead of "own slot", with what Smart does there - the
  records and the drain learning pause, and Smart gives a little more headroom while cool or
  holds the CPU back while the battery warms.
- "сес" -> "сес." in Russian and Ukrainian.
- Files: `webroot/index.html`, `webroot/i18n/*.json`, tests `t_webui_monitor_binding_tiles_contract`,
  an addition to `t_webui_smart_basis_runtime`, the fix190 contract.

**fix189 — Balanced and Battery get their own ceilings back after a hot boot; each profile card shows its own screen-off drain; the Monitor on manual profiles; LSPosed's modules log named**
- From an OP15 on Balanced: three screenshots, a 108-minute full-day capture, asbdiag, and the
  contents of /dev/.asb and /data/adb/asb.
- Balanced ran capped the whole capture: the main cores at 1555200 (43 %) in all 115 samples
  and the prime at 1632000-1862400 (35-40 %) in 114, where Balanced on an OP15 has no
  screen-on cap.
  At boot the vendor's thermal clamp held every ceiling lower, the shell's writes of the
  hardware maximum read back lower and were dropped, and the record of what it wrote for
  Balanced was empty; the governor, looking up Balanced's ceilings there, found the empty
  record and never handed back the ceilings it had written under a thermal cap or the
  screen-off cooldown. Two fixes: a write the
  kernel takes but holds lower is recorded as the profile's request, and a record with no
  value for a cluster no longer hides the precomputed one. Battery is affected the same way
  after a hot boot (its prime cap is above the boot clamp); Smart and Performance own their
  ceilings and were not.
- Screen-off drain on the profile cards. fix187 put the governor's screen-off figure on the
  running profile's card; it is one figure for all profiles together, so after a switch to
  Balanced the 0.70 %/h measured mostly in Smart appeared on Balanced's card and left Smart's.
  The governor now also keeps the figure per profile (a window one profile held from
  screen-off to screen-on: `offdrain_by_profile`, `/data/adb/asb/offdrain_profiles`), and every
  card, the Monitor's drain tiles and its sheet show only what was measured in that profile.
  The phone-wide figure stays for the time to empty, marked "~" with a tip saying so - the
  Balanced tile read "measuring..." above "61 h 25 m" taken from it. Smart's per-profile figure
  starts empty: the earlier windows were not recorded per profile.
- The drain meter had no screen-off figure for Smart, the profile this phone runs most, while
  the governor counted five windows, and nothing said why. The meter now keeps the windows of
  10+ minutes it did not count - with playback, under an hour, ended on the charger - and
  asbdiag shows them.
- Monitor on Battery/Balanced/Performance: the Learner tile read "unknown · 2" on Balanced -
  Battery's session count on every profile, and an untranslated rating of Battery's last
  session. It counts the running profile's sessions (Balanced: 10); the rating shows on Battery,
  translated, once it is known; its sheet describes the profile learner, not Smart's.
- System load shows its share of the online cores beside the figure, green under 50 %, amber,
  red from 80 % (asked for): "9.1 · 113%".
- LSPosed: the card's badge added every LSPosed log together, so "log off · 20 MB" and
  growing read as the switch not working. The verbose log was off (37 KiB); the 20 MB, written
  in about an hour, is the modules log - what LSPosed modules write themselves, which LSPosed
  has no switch for. The badge names the two apart ("verbose log off · modules log 19 MB"), and
  asbdiag names the app and the message that fill the modules log. Old verbose logs of the
  running boot are now emptied rather than deleted: LSPosed deletes the eldest of its own list
  once there are ten, and a file already gone stalls that for the rest of the boot.
- Files: `src/asb_governor.c`, `src/asb_writer.h`, `service.sh`, `runtime/asb_drain_meter.sh`,
  `runtime/asb_rom_telemetry.sh`, `runtime/asb_lsposed.sh`, `webroot/index.html`,
  `webroot/i18n/*.json`, `tools/asb_diag.sh`, `system/bin/asbdiag`, `docs/log_schemas.md`, tests
  `t_offdrain_by_profile_runtime`, `t_webui_monitor_manual_tiles_runtime`,
  `t_asbdiag_lsposed_modlog_runtime`, reworked `t_webui_home_offdrain_runtime`, additions to
  `t_shell_cap_owner_runtime`, `t_shell_caps_publish_runtime`, `t_drain_meter_runtime`,
  `t_lsposed_verbose_runtime`, `t_webui_lsposed_badge_runtime`, the monitor card/compact/stock
  tests, the fix189 contract.

**fix188 — what two OP15 asbdiag reports (before and after the LSPosed card) got wrong**
- Two reports of the same phone a minute after a reboot, the first with the LSPosed card on
  keep, the second after switching it to off and rebooting. The helper read LSPosed's
  setting on the phone (libsqlite.so opened at run time, as designed): the log was already
  off - switched off in LSPosed's own manager earlier.
- The card then recorded "off" as LSPosed's earlier value, and asbdiag said "ASB switched it
  off" although ASB wrote nothing. The earlier value is now recorded only when ASB actually
  switches the log off; the stale "off" record is discarded; keep after such a record says
  "ASB leaves LSPosed alone" instead of "setting put back".
- Every boot rewrote governor.conf a few seconds after the governor read it, with the
  throttle-override flag it already held: one more reload, "governor.conf changed after the
  governor started" in every boot report, and this write standing as the "last config
  transaction" over the user's own last change. It is written only when it changes.
- msm_performance held 0:2227200 / 6:1632000 in the second report - the prime at 35 % while
  ASB's own ceiling was 1862400 - and the report said "profile=smart -> prime cluster at
  35%". ASB holds nothing in that node outside HEAVY/GAMING; the governor now publishes what
  it holds there (`msm_asb_hold`, `msm_asb`) and asbdiag says whether the node's values are
  ASB's, ASB's left behind, or the vendor's, and that a live ceiling below what ASB wrote is
  not the profile's.
- A com.booking crash in Android System WebView was reported as "a hook / Xposed module - its
  hooks are the first thing to switch off". WebView (and Chrome/Trichrome) is shared code
  apps load for web pages; such crashes are now named as WebView crashes.
- "current session peak: smoothed 0C" a minute after boot now says the smoothed peak has not
  formed yet.
- Files: `runtime/asb_lsposed.sh`, `service.sh`, `src/asb_governor.c`, `tools/asb_diag.sh`,
  `system/bin/asbdiag`, `docs/log_schemas.md`, tests `t_asbdiag_msm_owner_runtime`,
  `t_boot_override_noop_runtime`, additions to `t_lsposed_verbose_runtime` and
  `t_native_crash_names_runtime`, the fix188 contract.

**fix187 — LSPosed's verbose log can be switched off from ASB; the home card shows the screen-off drain the Monitor shows; a new tab bar with a "Profiles" tab**
- LSPosed writes a detailed log of its own: 31 MB on the reporting OP15. Settings › System ›
  Diagnostics has a new card, *LSPosed Verbose Log* (keep / off, ships as keep). Off writes
  LSPosed's own setting - the row its manager's Settings › Verbose log writes in
  `/data/adb/lspd/config/modules_config.db`, a Java-serialised Boolean, layout and default (no
  row = on) taken from LSPosed's source - remembers what LSPosed had, and deletes all verbose logs
  but the newest, which the daemon holds open. LSPosed reads the setting when it starts, so it
  takes effect after a reboot (its running daemon accepts the stop command only from its own
  process); the card's badge says "off after a reboot" until then, and afterwards shows LSPosed's
  real state and log size. Keep puts LSPosed's earlier value back; uninstalling ASB does the same.
  Applied once, when the card changes - never at boot, and a log turned back on in LSPosed stays
  on. Android has no sqlite3 binary, so the governor binary opens the system's libsqlite.so at
  run time (`asb --lspd verbose-get|verbose-set|verbose-unset`); a database of another layout,
  or a phone where the library cannot be opened, is left untouched and the LSPosed manager opens
  instead. Not yet run on a phone: the first device run is the check.
- The home card of the running profile showed only the screen-on figure while the Monitor sheet
  printed "~0.70 %/h" with the screen off: the card read only the drain meter, which had no
  screen-off hour in that profile yet; the sheet also takes the governor's own screen-off
  measurement. The card now uses the same rules - the meter's figure, "<x" for an hour that did
  not move the level, and for the running profile the governor's figure marked "~".
- Tab bar: the first tab is the profile picker and is now called "Profiles" (all 13 languages)
  with a gauge icon; Monitor has a pulse on a screen, Settings a gear. The active tab is marked by
  a tonal pill that slides behind its icon, a filled icon and a heavier label instead of the thin
  line on the top edge; inactive labels are brighter (about 2.5:1 before). The bar is a capsule,
  centred and capped at 460 px on wide screens, placed correctly right to left. The tab buttons
  lost their English aria-labels, so screen readers read the translated names.
- Files: `src/asb_lspd.h` (new), `src/asb_governor.c`, `runtime/asb_lsposed.sh` (new),
  `uninstall.sh`, `common/install.sh`, `config/governor.conf(.shipped)`,
  `config/key_ownership.tsv`, `webroot/index.html`, `webroot/i18n/*.json`, `tools/asb_diag.sh`,
  `system/bin/asbdiag`, `docs/log_schemas.md`, `.github/workflows/build-*.yml`, tests
  `t_lsposed_verbose_runtime`, `t_webui_home_offdrain_runtime`, `t_webui_navbar_profiles`,
  `t_webui_lsposed_badge_runtime`, the fix187 contract.

**fix186 — HEAVY no longer caps the prime harder than MODERATE; one drain figure the screens agree on; the Basis tile says what steers Smart**
- From an OP15 Smart capture (V65-debug10, 154 min, 72 % screen on) with three Monitor screenshots,
  the action screen and asbdiag taken at the same minute.
- msm_performance got the ceiling before the race-to-idle floor. In HEAVY the writer also
  registers its ceilings there - a second ceiling the kernel obeys - and it registered the
  profile's raw prime value, 1497600 or 1632000, while scaling_max_freq held the floor-lifted
  1862400. All 20 throttle samples of the capture are this, all in HEAVY (app launches, heavy
  pages): the prime ran lower in HEAVY than in MODERATE, and the report blamed the vendor. msm
  now gets the same final number (snap, floor, manual clamp) - `writer_slot_final_max`. The
  capture names ASB's own registration `asb_msm` instead of `vendor` from now on.
- The "recent" screen-on drain (forecast, time to 0 %, the battery budget) left out the sessions
  in which the battery level did not drop a whole percent, and kept the ones that caught a step
  at full rate: 12.5 %/h (7 h to empty) against 8-10 %/h measured in every screen-on phase of
  the capture and 8.2 %/h in the drain meter. It is now the level drop summed over sessions
  divided by the screen-on time summed over them, older sessions fading by a quarter each; the
  20 minutes after the charger are left out. The budget that trims the phone when the forecast
  looks short runs on the same figure.
- The action screen printed "drain now: 9.9 %/h" from 6 minutes of screen-on time, two lines
  under the forecast that does not trust anything under 10 minutes. Under 10 minutes it now says
  "measuring - N of 10 min with the screen on". It also printed "thermal headroom 75 %" (the
  msm_performance read-back of one cluster) beside the Monitor's "Headroom 40 %": it now prints the
  Monitor's figure (`headroom_real_pct`, published in the state) as "CPU headroom".
- The Monitor's Load tile said "idle" over a MODERATE phone for the first seconds after a wake:
  the app in front was last read with the screen off. It is read again the moment the screen
  comes on.
- The smoothness probe ran once a minute instead of at most every three minutes (91 probes in
  about 85 minutes of screen time, 7 complete windows): it probed at once on every app switch
  and wake. It now keeps strictly to its three-minute turn.
- Smart records decide at t >= 2.5 instead of 1.7. The verdict is looked at after every pair,
  and each look is a chance for a setting that is no better to win by luck - simulated, about
  one time in seven; now about one in twenty, while a real 8 % saving still wins nine times in
  ten. The capture's first screen-on pair differed by 36 % between neighbouring blocks.
- Monitor, Smart card: the Basis tile showed "own slot" around the clock once a slot had history
  (correct and uninformative). It now shows what steers Smart's lean right now: the records'
  result for the situation you are in ("🏆 −8 %", "record ✓"), a trial in progress ("trial 3/8"),
  the smoothness check ("🎞 test" / "🎞 smooth"), and the overrides first ("❄ cold", "🔋 low",
  "🌙 brief", night, guard); while a slot is still young it keeps saying where Smart borrows from.
  Its sheet lists every situation's record, what was set aside and why, the night check-ins and
  the smoothness check. A word that does not fit a language's tile gives way to an icon.
- The full-day report advised switching off SystemUI's per-second redraws under its own
  evidence that all three were already off; it now says so and points at what is left (an
  animated element, an overlay, a module hooking SystemUI).
- Files: `src/asb_writer.h`, `src/asb_governor.c`, `src/asb_record.h`, `action.sh`,
  `runtime/i18n/action_*.sh`, `webroot/index.html`, `webroot/i18n/*.json`,
  `tools/logkit/asb_log_full_day.sh`, `tools/logkit/_asb_logkit_common.sh`, `docs/log_schemas.md`,
  tests `t_msm_final_ceiling_runtime`, `t_webui_smart_basis_runtime`, additions to
  `t_logkit_shell_cap_reference_runtime` and `t_logkit_sysui_redraw_runtime`, the fix186 contract.

**fix185 — Smart V5: weather and the charger are no longer credited to a setting; Smart finds stutter per app and fixes it only where clocks help; a cold-battery guard**
- Power, not current: the records multiply the charge counter by the battery voltage averaged
  over the block. The same work draws more current at 20 % (about 3.6 V) than at 90 % (4.3 V),
  so in milliamps a setting measured in the evening looked dearer than one measured in the
  morning.
- Side by side: each challenger block is compared with the champion block next to it, and only
  when the two were within four hours, 2.5 C of battery temperature and 25 points of charge of
  each other. A cold street, a warm flat, the charge level and battery ageing then change both
  sides of a pair alike; a block pair across a change of climate simply does not count. The
  decision uses the paired differences (mean at least 3 % cheaper, t >= 1.7), the display keeps
  the plain averages. The test proves it: with two equally good settings where every champion
  block ran 2.8 C colder and 10 % dearer, block-by-block averages show the challenger about
  9 % cheaper - the pairs never form, and nothing is promoted.
- Set aside, with the reason counted (`rejected|meter=|charge=|radio=|busy=|climate=|other=` in
  `smart_records.txt`, shown by asbdiag and the full-day report): the first 20 minutes after the
  charger (warm pack, relaxing voltage, the percentage parked at the top), a battery under 10 %,
  and a block in which the battery warmed or cooled by 3 C with the screen off (in from the cold,
  out into it) or cooled by 3 C in use (use only heats it).
- The bucket learner had the same blind spot through the battery percentage, whose model moves
  with temperature: a session with the pack under 5 C, a cold pack warming or cooling by 3 C,
  a pack ending 3 C below where it started, or a session right after the charger no longer
  teaches anything about drain, in either direction; heat and everything else still teach. The
  governor logs which reason applied (`smart: session drain set aside - ...`).
- Smoothness: the obvious signal does not work. Across fifteen Smart captures the janky-frame
  share is HIGHER in intervals that spent little time at the CPU ceiling (OP15 25131: 8.4 %
  under 20 % of the time at the ceiling, 3.4 % / 3.1 % above it), so "the cores are pinned,
  give more" would spend battery on jank the clocks do not cause. Smart now reads the frames:
  Android's GraphicsStatsService counters for the app in front (`dumpsys graphicsstats` -
  system_server reads a buffer the app shares with it, the app is never called), at most every
  three minutes of screen-on time, in the background (`runtime/asb_gfx_probe.sh`, one dumpsys
  and one awk at low priority, skipped while a previous one runs). An app that misses its
  deadline on 8 % or more of 3000+ frames is tested: three-minute windows alternate the normal
  lean with 0.15 more headroom. Only if the headroom cuts its janky share by a quarter and by at
  least 1.5 points is it kept, for that app; otherwise the app is marked as not helped by clocks
  and left alone. Both verdicts are re-checked after 21 days, 24 apps are remembered, games, the
  camera and the system UI are left out, and the records leave test windows out of their
  measurements. The WebUI's Smart line says "checking smoothness" / "smoother for this app".
  The governor log names the app by its hash, as the rest of Smart does, unless it is a debug
  build or `smart_pkg_plaintext=1`.
- Cold-battery guard: with the pack under 5 C and under 40 % (not charging), Smart's lean is held
  at 0.8 or more - lower CPU peaks - until it warms up or goes on a charger. A cold Li-ion cell
  has two to three times its usual internal resistance and sags under bursts, the usual way a
  phone switches itself off in the cold with charge still showing. This is battery physics, not
  a capture: no log so far was taken in the cold. The WebUI shows "cold battery · gentler peaks".
- Smart V5 (`smart_engine_ver=5`, the badge in the WebUI): a V4 bucket store is carried over as
  it is - nothing a V4 bucket learned was computed differently. The records store changed layout
  (power and pairs): a fix184 store keeps its night checks and re-measures the situations.
- New keys, on by default: `smart_smooth`, `smart_cold_guard`. State: `smooth_lean`,
  `smooth_testing`, `smooth_probes`, `smooth_windows`, `smart_cold_guard`, `ses_climate`,
  `unplug_age_s`.
- Files: `src/asb_record.h`, `src/asb_governor.c`, `src/asb_smart.h`, `src/asb_smart_defs.h`,
  `src/asb_config.h`, `runtime/asb_gfx_probe.sh` (new), `config/governor.conf(.shipped)`,
  `config/key_ownership.tsv`, `common/install.sh` (probe permissions), `.github/workflows/build-*.yml`
  (probe in the required list), `tools/asb_diag.sh` (+ `system/bin/asbdiag`),
  `tools/logkit/asb_log_full_day.sh`, `webroot/index.html`, `webroot/i18n/*.json`,
  `docs/log_schemas.md`, tests `t_smart_records_runtime` (rewritten), `t_smart_smoothness_runtime`,
  `test_bucket_learn_climate`, the V4 -> V5 migration check, the fix185 contract.

**fix184 — Smart records: Smart measures what each situation costs and keeps trying to beat its best; night wakes are learned**
- Smart learned by direction only: a hot or drainy session nudged a bucket toward economy, a
  clean one back, and nothing ever checked whether the new setting was cheaper. The drain it
  learned from was the battery percentage - 1 % steps over 20-minute sessions. Now it measures:
  the fuel gauge's charge counter (1 mAh steps, readable on every OnePlus in the captures -
  OP15 CPH2745/2747/2769, OP13, OP12 CPH2691) gives the real average current of a stretch,
  suspend included.
- Six situations, each with its own best setting: screen off at night and by day (40-minute
  blocks), screen on with light apps and with ordinary ones, dim and bright (10-minute
  blocks). Set aside, not counted: charging, a busy radio with the screen off (>= 15 KiB/s),
  screen-off music or syncs keeping the CPU awake, heavy work, games, the camera, the thermal
  veto, low battery, a thermal cap, the cooldown.
- Each situation alternates its best setting with one neighbour, block by block, so both see
  the same nights and days. The neighbour takes over only when it is at least 3 % cheaper and
  the gap clears the block-to-block noise (Welch t >= 1.7); screen on it must also not make the
  cores sit at their ceiling more often (+8 points at most) - cheaper by being slower does not
  count. One that is clearly dearer is dropped after three blocks each. A win carries on in the
  same direction, a loss turns round, and when neither neighbour beats the best the situation
  has reached its plateau: exploring stops, the best setting stays in force, and it is
  re-checked after 21 days because apps, the battery and the ROM change.
- The settings are few and one step from today's behaviour: screen off, the quiet deep-idle CPU
  ceilings x0.75 / x0.875 / x1 / x1.25 / x1.5 (below x1 the writer's race-to-idle floor drops to
  25 % for that write only; music keeps x1); screen on, Smart's economy lean -0.2 .. +0.2, applied
  before the safety layers, so the thermal veto, low battery and the charge guard still win.
- Night wakes: a screen-on of under ten minutes after at least an hour of darkness, inside the
  learned night, is a night check. Its half hour, its length and how many a night are
  remembered (old habits fade 3 % a night). When a screen-on looks like one, the modem stays in
  its night mode instead of switching to day mode and back; a check that outlasts twice its
  usual length (3-10 min) is a real wake. Night checks are also kept out of the screen-on
  records.
- asbdiag prints each situation's status, best setting, record and the change against the
  original setting, plus the night-wake habit; the full-day report has a SMART RECORDS section
  and copies /dev/.asb/smart_records.txt. Saved to /data/adb/asb/smart_records.bin at most every
  15 minutes, at once after a decision and on shutdown; the Smart learning reset clears it.
- governor.conf: smart_records, smart_records_explore and smart_microwake, all on.
- What to expect, honestly: a decision needs 6-16 blocks per setting screen off (about a week of
  nights per step) and 8-20 screen on, so the first results take days and a plateau weeks. Gains
  under 3 % are not taken - the meter cannot tell them from noise - and a situation whose best is
  today's setting will show exactly that.
- Native governor change: needs the CI build.

**fix183 — Switching into Battery or Balanced finally applies their ceilings; cooldown and thermal cap work there too (CPH2747 capture 22454, CPH2745 capture 25307; every device)**
- With the governor running, nothing applied a manual profile's CPU ceilings after a switch.
  The governor stays off them in battery/balanced, the profile worker does not write them, and
  the shell's reconcile loop - the only place that would - runs only when the governor was
  missing at boot. CPH2747 (OP15, V65-debug6) switched from Smart to Battery at 11:25 and stayed
  there 5.5 h: every sample kept Smart's last 1555200 on the main cores and 1862400 / 1632000 /
  1497600 on the prime; the Battery caps (1785600/1747200) never reached the hardware. The
  same happens Smart -> Balanced (OP15 Balanced is uncapped on screen-on and kept Smart's
  caps), Performance -> Battery (Performance's ceilings) and Battery -> Balanced (Battery's caps);
  only a reboot fixed it.
- service.sh now precomputes the screen-on rung of Battery and Balanced on every pass, whatever
  profile runs (Smart included), without writing a ceiling: /dev/.asb/shell_cpu_caps.battery
  and .balanced, per policy, so OP12's four clusters and the MID rung are covered. On a switch
  into a manual profile the governor writes that profile's own values on every policy at once;
  what the shell later writes itself (shell_cpu_caps) takes over as the reference.
- The screen-off cooldown never reached a manual profile's CPU: its log said "ceilings lowered
  toward the hw minimum" while the OP15 on Battery held 1785600/1747200 through it (23:48, die
  50 C). In Battery and Balanced the governor now takes the ceilings during the cooldown, as it
  already did under a thermal cap.
- While it overrides a manual profile it never goes above the profile's own ceiling. A thermal
  cap could RAISE the Battery prime: the writer's race-to-idle floor alone is 1862400 on OP15,
  the Battery prime 1747200. Every override value is now held at or under the shell's value
  for that policy, and when the override ends - and when the Balanced anti-clamp's direct write
  outlives HEAVY - the shell's values go back. Before, whatever the governor wrote last simply
  stayed.
- asbdiag lists the three records (missing ones too); the full-day logkit copies them; the
  cooldown line no longer claims "caps at hw minimum" (the race-to-idle floor applies, and in a
  manual profile the profile's caps). The fallback reconcile loop applies manual caps on a
  profile change as well.
- Not covered: the scaling_min floors of a manual profile after a runtime switch stay where
  the previous profile left them until the shell's next pass (boot). Smart leaves the lowest
  step there, which costs Balanced a little responsiveness and nothing on Battery.
- Native governor change: needs the CI build.

**fix182 — Battery and Balanced: the profile's own ceilings stop counting as vendor clamps (CPH2745 capture 25307, Battery)**
- In Battery and Balanced service.sh writes the CPU ceilings (a per-device share of each
  cluster's maximum) and the governor only adds a thermal clamp - but it never knew what the
  shell had written. It judged the live ceiling against msm_performance and its own unsent
  rail, so an OP15 day holding exactly the Battery caps (1785600/1747200, 50/38 %) read
  cap_source vendor_clamp, vendor_clamp_1h up to 441, the ceiling watch logged "clock ABOVE our
  limit" against a 1555200 nothing had sent, the throttle report logged all 224 samples and
  called it "foreign cap ownership", and cap_verify compared against a legacy 921600 that
  nothing writes.
- That count is not only a label. The governor keeps running across a profile switch, and
  Smart's thermal veto fires on vendor_clamp_1h >= 300 once the skin is within 8 C of
  thermal_skin_c, then holds alpha_battery at 700 or more: for up to an hour after leaving
  Battery, Smart could lean on the battery rail because of the Battery profile's own caps.
- service.sh now records what it wrote (/dev/.asb/shell_cpu_caps: profile, screen rung,
  policyN=kHz - the read-back when the kernel rounds up, the request when a clamp is already
  there). In a manual profile without a thermal cap the governor classifies against it: equal
  is shell_applied, above shell_overridden_up, below vendor_clamp - only a ceiling under the
  profile's own cap is a vendor clamp now. In this capture that leaves the 76 samples with the
  prime at 1632000 under the shell's 1747200, which are real. The ceiling watch compares with
  the same record ([shell cap] in its log line) and counts nothing when there is none. The
  state file shows cap_writer=shell|asb and shell_cpu_max0 / shell_cpu_max_prime.
- Full-day logkit: in a manual profile the throttle trace measures against the shell's cap
  (a writer= field marks those rows), the ownership verdict counts "shell" as ASB's own instead
  of foreign, and cap_verify expects the recorded values. asbdiag prints "cap profile/effective"
  with the shell's values instead of the governor rail in that mode.
- The screen-off rung is written only where something will lift it again. With the governor
  running, reconcile does not re-apply manual caps on a screen change (the screen-off side is
  the governor's cooldown clamp) and the governor never writes them itself in a manual profile,
  so a screen-off rung written at boot with the screen already off stayed after the screen
  came on - the prime at 1152000 (25 %) on a phone in use. With the governor up the screen-on
  rung is kept and the log line says so; without it, reconcile still follows the screen. The
  capture shows the other half: every screen-off sample already held the screen-on caps.
- Found while tracing the ownership: in battery/balanced the main loop's reassert registers the
  FSM rail in msm_performance during HEAVY, GAMING and SUSTAINED (in SUSTAINED that rail
  deepens with temperature - it is the cooling), but the only release sits in the cap path a
  manual profile never reaches. The registration outlived the episode as a hidden second
  ceiling under the shell's own. The writer now hands msm_performance back once those states
  are over (a no-op unless ASB wrote the node last); the SUSTAINED cooling itself is
  unchanged. This capture does not prove it fired: the prime's 1632000 there is also a known
  OPlus step and is counted as the vendor's.
- Looked at and not changed: in Battery light idle the GPU sits at its lowest step (160 MHz,
  bat_light_idle_gpu=10). It looked like a cause of jank, but GPU busy was 8-11 % in those
  intervals and the same apps in the CPH2745 Smart captures ran at the same 160-222 MHz. The
  Claude app's 37.8 % janky is one six-minute untouched stretch (40-60 % per interval, the slow
  UI-thread share small, neither cluster near its ceiling) - not something the caps explain.
  Those Smart captures ran other kernels (BeastMode, Wild) against the stock kernel here, so
  their jank figures are not a like-for-like comparison.
- Native governor change: needs the CI build.

**fix181 — SUSTAINED stops ping-ponging, the OP12 prime is managed with the screen off (CPH2691 capture 8952)**
- The SUSTAINED re-entry and gaming-retry cooldowns were never armed. The hook sat before the
  ladder transition in fsm_update, where state_changed (reset at the top of the tick) could not
  yet be set, so it never fired: an OP12 re-entered SUSTAINED 16 s after leaving it under a 24 s
  cooldown. They are armed now after every transition of the tick, the forced screen-on/off
  moves included.
- SUSTAINED that keeps coming back stays longer. The same capture, messaging on mobile data
  with the battery at 38-40 C: eight entries in 22 minutes, each left after 20-153 s (median
  under 40) - the die drops under the exit mark half a minute after the ceilings fall while skin
  (38-42 C) and battery stay hot, then MODERATE heats it again and the trend path re-enters.
  Re-entered within five minutes of the last exit, the minimum dwell doubles (24, 48, 96, at
  most 180 s) and resets after five quiet minutes; a single entry is held as before, and screen
  off still releases at once. The state file shows sustained_repeat and
  sustained_reentry_left_s; exit_sustained logs the repeat and judges "temp_dropped" against
  the profile's own exit mark (it printed "temp_dropped t=51degC (exit_thresh=48)" for an exit
  the screen going off had made).
- Smart on a 3/4-cluster phone (OP12, 13R, Ace) managed the separate prime only in LIGHT_IDLE
  (screen on), MODERATE, HEAVY and SUSTAINED; elsewhere it returned 0 = "unmanaged", and the
  writer skips an unmanaged slot instead of giving it back. In 106 of 126 screen-off DEEP_IDLE
  samples the prime ceiling was the 2035200 MODERATE had written (62%) - the screen-off prime
  cap and the screen-off cooldown only ever lower a non-zero cap, so neither touched it - and
  GAMING kept the last MODERATE ceiling instead of running free. Screen off is now a defined 55%
  that the screen-off cap and the cooldown lower further; GAMING and a busy game get the whole
  prime back (the gaming cool-clamp still applies).
- The writer gives an unmanaged slot back once: a slot ASB wrote earlier and now holds nothing
  for (a Balanced or Performance prime after Smart) is set to its hardware maximum instead of
  keeping the old cap; the vendor's own lower ceiling still wins in the kernel.
- Full-day report, AudioMix holders: data rows only - the second header line was counted as a
  holder ("uid|package=worksource_uid|package") - and a shared system uid is "system", not the
  list of every package sharing uid 1000.

**fix180 — the deferred Smart questions measured, not guessed (CPH2769 / CPH2747 / CPH2691 field logs)**
- GPU-led HEAVY was checked and left as it is. Its CPU gate (0.15 load per core) is always
  true on an OP15 idling at load 7, so a busy GPU alone enters HEAVY - Duolingo moved
  MODERATE <-> HEAVY six times in five minutes. But HEAVY held 4.6% of screen-on time, and in
  every HEAVY sample of two CPH2769 captures the prime ran under 1.4 GHz: the higher ceiling
  was never used, so there was nothing to save, while the GPU ceiling it brings is what an
  animated app needs.
- The screen-off race-to-idle floor is now measurable instead of argued: the capture writes
  energy_model.txt - the kernel's power and cost for every CPU step, where debugfs exposes it
  (read-only, nothing is mounted). The floor (40% of a cluster's maximum) sets the screen-off
  clock - a CPH2769 night asked for ~0.95 GHz on the main cores and ran up to 1.4 GHz, at that
  ceiling in 19% of screen-off samples - and whether that costs more per unit of work is a
  fact about the silicon, which this table records.
- Wi-Fi multicast is named: the capture's batterystats snapshot and asbdiag list who held it
  since the unplug, from the per-uid blocks. A CPH2769 total read 3 h 49 min, screen-off
  stretches were awake half the time, and no holder appeared anywhere - the watcher only sees
  the lock at the moment it looks.
- asbdiag, writes per transition: judged against what one transition writes on the phone's
  own cpufreq slots (2 x slots + 3), with the writer's other work listed - unlock lifts, prime
  bursts, re-sends through a vendor hold - and chatter judged by state changes an hour. A
  CPH2691 read "13 (8+ ... suggests the ladder is chattering)" with three slots, 65 lifts, 63
  bursts, 296 re-sends and one state change every 101 s.
- Full-day report, CURRENT / SOC CONSISTENCY: the governor's own gauge check is printed when
  it is off - a CPH2747 integrates current_now to x0.35 of the SOC drain over 61 screen-on
  windows, so its "CHECK low" rows are the gauge, not the modem.

**fix179 — Smart relaxes on an idle screen of a busy-idling phone (CPH2769 / CPH2747 field logs)**
- Smart (and every profile using the same state machine): the battery-current shortcut to
  MODERATE - "over 250 mA and load1 at 60% of the MODERATE threshold" - is measured from the
  phone's own idle level. 60% of 14 is 8.4, a bar set on a phone that idles near zero; a
  CPH2769 idles with the screen on at 6.3-8.3 and draws more than 250 mA showing anything, so
  the pair alone held MODERATE in 240 of 535 quiet screen-on samples (load under 14, GPU under
  12%) of capture 30423 and in 157 of 439 of capture 13290 - Smart was in MODERATE for 87% of
  screen-on time. A CPH2747 gauge reads a third to a half of that current, so there the rule
  fired twice in 247: the same profile behaved differently on two OP15 variants because of a
  sensor scale. The bar is now 60% of the way from the learned screen-on quiet floor (the one
  the GPU and burst gates already use) to the threshold - about 10.6-10.9 on the CPH2769, 25
  of the 535 samples - and never lower than the old 8.4, so no phone gains MODERATE from it.
  Touch, the GPU branch and the pinned-core escalation still lift LIGHT_IDLE at once. The
  difference on the CPH2769 is one main-core step (1747 -> 1651 MHz) and the background
  uclamp tier (32 -> 27) while nothing is being driven; the next capture shows what it saves.
- Full-day report, AudioMix attribution: only the AudioMix lock's own WorkSource is credited.
  The live row joined up to three held locks and credited every WorkSource in it - capture
  30423 listed ru.vk.store with 95 "AudioMix" samples and ru.yandex.weatherplugin with 13,
  from WorkManager job locks held beside the audio lock.
- Full-day report, NIGHT / SCREEN-OFF CPU SLEEP needs ten minutes of Android's screen-off
  window: a CPH2747 report ended seconds after an unplug and printed "0.0h realtime, CPU awake
  0m -> awake 100.0%"; it now says how short the window was.

**fix178 — the screen-off meter measures, Bluetooth drops get a cause (CPH2747, CPH2691, CPH2769 field logs)**
- The per-profile screen-off drain was never measured. Two faults in runtime/asb_drain_meter.sh:
  the audio-thread probe compares with its previous call and is only called with the screen
  off, so the first screen-off sample counted everything the audio threads did while the phone
  was in use and every window was dropped as "music" (the ROMs without readable PCM status,
  the OP15 among them, measured nothing); and the first screen-on sample closed the window, so
  one look at the clock split a night into pieces under the hour. The probe now starts afresh
  at screen-off, playback needs two audio samples in a row (one notification is not music), and
  a screen-on shorter than 2 min is a glance that the window continues through - as the
  governor's own screen-off meter does. The Stock "screen off" tile and the per-profile compare
  read this meter.
- asbdiag: the wake-path total left out the "display" path, so a phone whose screen-ons were
  all caught there showed a false "4 of 4 screen-ons missed" WARN (CPH2691). The status-bar
  settings line matched any key containing "speed" and printed the smart-5G app list as a
  setting; it now takes only the net-speed indicator and clock-seconds keys, values cut to 24
  characters. When the top-app lookup finds no host, a terminal drawing the most janky frames
  is taken as the host: com.termux, scrolling the report itself, was called "a redraw that runs
  by itself". A native crash whose first frame outside libc is in
  another app's /data/app code is named as an injected hook (CPH2691: com.oplus.battery
  aborting in a hook module's library) - the first thing to switch off. The Bluetooth section
  names the codec of the active A2DP link; on LHDC / LDAC / aptX HD or Adaptive it adds that a
  dual-connection headset dropping near its other device is worth a test on AAC or a lower
  quality (a high-bitrate codec needs the most airtime, which the second link shares).
- Bluetooth link drops get a cause. The logcat recorder now keeps the ACL disconnect with its
  HCI reason (8/34 lost link, 19/21 ended by the headset, 22 ended by this phone), the
  A2dpStateMachine/HeadsetStateMachine transitions and the one-step 2->0 of a lost link; the
  report prints the drops by reason. The service's own state history (the last 20 changes of
  every profile, in each snapshot) is read back too: CPH2769 capture 30423 had four media drops
  in the user's "three or four" window that the logcat stream never saw - all reported by the
  stack, none asked for on the phone, back after 18 min, 2 s, 7 min and not at all. Each drop
  says whether the call profile went with it (whole device) or stayed (media only - what a
  multipoint headset does when it hands media to its other device), where the kept rows can
  tell. Devices are A, B..., never addresses.
- The snapshots printed the AVRCP volume table with the device names (a headphone model, a
  car) under "addresses redacted"; the name column is redacted now. They hit their 120-line cap
  every time, some halfway through the call profile's history, while 41% of the bytes were codec
  lists repeated inside single rows: 200 lines of at most 360 characters.
- Android 16 audio dumps: the mode is read from "Actual mode =" and the mode owner from the
  line after "Mode owner:" - every snapshot of capture 30423 printed an empty owner.
- The Wi-Fi link is read at all: every capture and report so far had an empty "# wifi link" and
  a state-machine row as asbdiag's "live wifi link" - the patterns matched nothing in the
  OxygenOS 15/16 wifi dump, and the line they asked for carried the SSID and BSSID. Both now
  read `cmd wifi status` and the dump for the first line with a frequency and an RSSI and print
  the band, signal, link speed and standard - never the network's name. asbdiag notes 2.4 GHz
  as the first thing to change when a Bluetooth headset drops.
- The capture's watcher-state copy includes the wakelock-fitness and drain-meter files.

**fix177 — Stock as quick as any profile, Monitor sheets in the tile's own words (fix169 field logs)**
- Stock switches at once. apply_profile.sh ran the whole profile ledger inside the WebUI's
  root call, and every setting in it is a `settings` process: the owner's OP15 sat frozen for
  about 30 s on "Stock selected - restoring ROM baseline..." with the Smart and Stock cards
  both half lit (their transition stopped mid-way). The direct switch now stops the governor,
  releases the leases and puts every sysfs value back, then returns; the settings and the
  network re-apply follow in a detached pass that holds the apply lock and stops between keys
  as soon as a newer profile is chosen - the ledger, with the original values, is then kept.
  Boot and the worker keep the complete synchronous transaction.
- Monitor on Stock opens at once and stays light: the page slides in first and reads after;
  the ROM snapshot is runtime/asb_rom_telemetry.sh (builtin reads, only the thermal zones the
  Monitor shows) instead of an inline command that forked two `cat`s per zone and started the
  settings client every 10 s; that value is refreshed in the background once a minute.
- Stock thermal trend: a least-squares slope of the mean CPU-zone temperature over the last
  two minutes, kept between reads. It compared the hottest core of two consecutive reads, so
  every repaint without a new read (most of them) showed "—" and single-core spikes flipped
  it. The eight Stock-banner readings open the explanation sheet too, with sources (current
  as %/h, the rate behind the trend, mobile_data_always_on, per-cluster clocks, boot time).
- Every Monitor sheet in the tile's words and colour. The sheet copied the tile's class,
  and the same class is green in the Smart banner and amber in the grid ("cooling" opened in
  amber; "above normal" in white) - it now takes the colour the tile is drawn in. The texts
  listed English values ("idle, light, medium, heavy or gaming" under "средняя", "normal /
  save / fast / night" under "обычно") - the words now come from the tiles' own strings via
  placeholders in all 13 languages. The slot text said "twelve two-hour slots"; it is six
  parts of the day (0-6, 6-9, 9-12, 12-17, 17-21, 21-24) for weekdays and weekends. Basis
  lists all five values and the source shows the slot and its confidence instead of
  repeating the text. "Usual heat: above normal" on a cold phone is now "Slot heat: warm",
  the sheet says "usually in this slot" and puts the CPU temperature now beside it. The
  modem's night mode no longer reads "normal"; "Modem LPM" and "Клампы vendor" got plain
  names; the Stock battery-temperature tile no longer shares its name with the battery tile.
- Drain sheet: no dash under the moon. A screen-off hour whose level did not move counted
  as 0 and printed "—" beside a card measuring 0.56 %/h; it reads "< x %/h" now, the current
  profile borrows the card's own figure ("~") until the meter has an hour of its own, and the
  rest say they are still measuring.
- Fitness badge: "no fitness apps" on a phone with Samsung Health and Renpho. The badge
  counted ledger lines; the watcher now answers `fitness-status` (installed, limit in force
  as Android reads it, recorded, ignored, refused). The WAKE_LOCK reader took whichever line
  came first, and `appops get` prints a "Uid mode:" line above the package's own - a uid mode
  also wins over the package mode, which may be what the fix176 "ROM ignores it" verdicts
  were. The package line is read now, an overriding uid mode is set too (own ledger, handed
  back on protect and uninstall), and a limit Android refuses is rolled back and said.
  More step/run trackers are recognised (Runtastic, Nike Run Club, Pacer, Komoot...).
- Wakelock watcher: a VPN, a proxy or a DNS filter and any app running a foreground service
  are never restricted, and those an earlier pass restricted are given back. Capture 3970:
  a Telegram WebSocket proxy held its service wakelock in 78% of the screen-off samples and
  was restricted, under a report line promising "a proxy, a VPN" is left alone.
- Full-day captures on Stock: the battery trace had no profile, screen or temperature (no
  governor status), so the report said "screen on for 0%" and cpuT 0 for every phase of a
  77-minute capture with the screen on most of the time. They come from the capture's own
  reads now.
- CI: the "Tree differs from the delivered archive" step is gone from both workflows; the
  tree check stays as a local tool without CI annotations.

**fix173–fix176 — WebUI clarity (banner explanations and visual hierarchy)**
- fix176 (field logs from the fix169 build): the Fitness wakelock setting now admits
  when the ROM ignores it. On ColorOS/OxygenOS 16 the WAKE_LOCK app-op is not enforced,
  so wakelock_fitness=limit set the op and a fitness app still held the CPU all day
  (a full-day capture showed a pedometer library awake 93+ min straight). asbdiag and
  the action screen already reported the "limit set but ignored" verdict; now the
  WebUI does too - the Settings badge reads "ROM ignores it" (warn) instead of
  "Enabled", distinguishes "no fitness apps" / "pending", the toast after switching
  to limit says the same, and all thirteen locales carry the strings.
- fix175: the sheets' primary button ("Готово" / "Применить") is no longer a full-bleed
  bright green slab - it is a tonal dark surface with a quiet teal border and label
  (a pale teal wash in the light theme). The six Settings category tiles are filled a
  step stronger in their category hue, both themes.
- fix173: the eight Smart-banner readings (slot, confidence, lean, load, basis, heat,
  trend, LPM) open the same tap-to-explain sheet as the nine Monitor tiles, with texts
  in all thirteen languages.
- fix174: the slot popup no longer glues the weekday/weekend pill onto the slot name
  ("вечервых") - the sheet reads only the value's own text, the pill still shows in the
  source line. The six Settings category tiles now carry a quiet tint of their category
  hue (both themes) so they lift off the neutral restart row, and the nine Monitor
  tiles are filled a notch stronger.

**fix170–fix172 — audit follow-up (packaging honesty and recovery coordination)**
- fix170: the callrec experiment was retired completely - the installer asks the previous
  copy to undo its own work and wipes its state. Test suites were consolidated into four
  parallel suites with a shared `--list`/`--source` interface, and a tree-integrity
  manifest (`tools/asb_tree_check.sh` + `tools/asb_tree.sha256`) now proves a delivered
  archive is complete and unchanged.
- fix171: the full-day recorder's orphan cleanup gained a third grace pass before giving
  up on a process that still reads alive, and the "still live" note now carries the
  process state - a KILLed process exiting through D-state under load read as alive long
  enough to flake the contract test once in a 12-way parallel run.
- fix172 (three external audits, triaged; what was confirmed got fixed, what was not is
  answered in the review):
  - **Release tools manifest.** CI shipped seven tools the installer's whitelist then
    deleted on every device - `asb_effective_policy.sh`, `asb_verify_device.sh`,
    `asb_audit_state.sh`, `asb_vendor_thermal_probe.sh`, `asb_intent.sh`,
    `asb_smart_mode.sh`, `asb_install_probe.sh` among them - while install.sh went on
    chmod'ing files it had just removed. The shipped-and-kept set now has ONE source of
    truth (`tools/release_tools.list`): the release workflow copies from it, the
    installer's prune keeps exactly it, and a contract test fails the build if the
    workflow, the manifest, the installer's inline fallback and the ZIP validator ever
    disagree again.
  - **Governor recovery ownership.** service.sh had two restart paths for one governor:
    the 5-minute liveness check (fix144) and the resident watchdog loop started when the
    governor is missing 95 s after boot. Both would race on the same death. The watchdog
    fallback now marks its ownership (`/dev/.asb/watchdog_resident`) and liveness defers
    to it - the watchdog keeps the recovery ledger and L2/L3 escalation, liveness alone
    did not.
  - **Governor spawns its scripts honestly.** The LPM and Smart-tuner spawns hardcoded
    the module path and discarded every failure (a missing script was invisible by
    construction). The governor now resolves its own install directory from
    /proc/self/exe with the standard path as fallback, checks the script is readable
    before spawning, and logs when it is not. Source-only: the shipped binary picks this
    up at the next CI build.
  - **README platform honesty.** The support section now says out loud that reference
    tuning is Qualcomm SM8xxx field data; MediaTek models get discovery and fallbacks,
    not miracles.
  - **update.json** keeps pointing at the latest PUBLIC release (V64) - that is the OTA
    scheme, not staleness - but its changelog link pointed at the retired repository and
    now points at krilikd-factory.

**Features that were silently not working**
- Wakelock and Wi-Fi multicast watcher: holders are resolved by uid (current `dumpsys power`
  / `batterystats` formats); an app ranking is always written and shown in action/asbdiag;
  turning the switch off releases what it restricted.
- Route windows and per-route congctl: Android keeps default routes in per-network tables
  (`table all`), and the root manager's BusyBox `ip` has no `monitor`/`initcwnd`/`congctl` -
  `/system/bin/ip` is used. The watcher ignores its own route events (no re-apply loop) and
  falls back to a 1/min poll when `ip monitor` is unavailable.
- GNSS trim: Android 12+ caller format, real process state from `dumpsys activity lru`.
- Background trim: memory protection uid lookup (`appId=`), standby buckets recorded and
  restored (uninstall, level off, WebUI); heavy apps are demoted only when Android itself
  says they are out of daily use.
- Settings fallback wrapper in every standalone script; action no longer falls back to
  English when `settings` answers with an error string.
- Surface temperature on phones without sys-therm/board zones (OP12) taken from the shell
  sensor, so surface-based heat trims engage there.
- Throttling slider, phantom-process stock restore, GMS strict -> lite/stock, Doze
  exemptions on stock, WebUI keys that claimed "applied" but needed a reboot.

**New WebUI tweaks (fix48)**
- Fitness Apps & Wakelocks (`wakelock_fitness`, protect | limit): app-op WAKE_LOCK ignore for
  step/fitness apps seen holding the CPU 2+ min (Samsung Health PedometerLib was the largest
  night holder in three captures). Watch/band companions excluded; previous mode recorded and
  restored on protect/uninstall; independent of `wakelock_action`.
- Prime Core Lift (`heavy_prime_escape`) with Lift Length (`prime_escape_burst_s`, 5-60 s,
  default 20) and Pause Between Lifts (`prime_escape_rest_s`, 10-300 s, default 40), live via
  governor reload. Smart Battery Bias sits next to them.
- Force LTPO now also opens the Android range live: no `min_refresh_rate` floor, peak =
  highest panel mode; recorded and restored. The low end stays the VRR table's job.
- Lowest Refresh for Video (`ltpo_video`): during quiet 30/60 fps playback the peak drops
  to the smallest exact-multiple mode (60 Hz); first touch, end of playback, video gone,
  a High frame-rate category, gaming or screen off restore it at once. 24/25/50 fps left alone.

**fix93** - Full-day logs record the panic policy
- The kernel parameters block of every full-day capture now includes kernel.panic,
  kernel.panic_on_oops and kernel.hung_task_timeout_secs, so a capture taken on a phone that
  later hangs shows whether a crash would have rebooted it. The OP12 capture that followed
  the morning hang (2026-10-09 22:14 - 10-10 08:20: music over Bluetooth in bed, a VPN on
  mobile data, charging) shows no hang, no SystemUI restart and normal governor behaviour;
  the panic values were not yet recorded there.

**fix94** - Honest screen forecast, tombstones really kept, board cell relabelled
- Live drain rate: the previous session's rate was an `else` of the two-hour halving, so it
  replaced the live figure whenever the rolling window was under two hours - mid-session,
  with 31 min of real data. An OP15 went 53 -> 44 % in an hour while the state said 3.3 %/h
  and the WebUI printed "13h 56m · measured". The old rate is now only a fallback when no
  current one exists, and is published with window 0 so both screens call it "average".
- runtime/asb_managed.props no longer sets tombstoned.max_tombstone_count=0 and
  ro.tombstoned.crash.dump=0. fix91 removed the post-fs-data write, but this file set it
  again every boot (asbdiag: "tombstones kept: 0" next to three SYSTEM_TOMBSTONE entries).
- WebUI Monitor: under ASB profiles the "Die · max" cell shows surface_hotspot, which is
  the board/body temperature (39 C next to a 42 C CPU). It is now labelled "Board" with a
  tooltip in all 13 languages; the Stock path, which really is max(cpu, gpu, ddr), keeps
  the die label.

**fix95** - The 40% ceiling floor really is 40%; asbdiag reads the screen on OP15
- cpu_floor_ceiling rounded its own guard DOWN to the step below 40% of hardware max, so
  the "never below 40%" floor published 1747200 of 4608000 (37.9%) on the OP15 prime and
  1440000 of 3628800 (39.7%) on the little cluster - held for ten minutes at 41-46 C with
  no thermal cap in the 24770 capture. The guard now takes the first real OPP at or above
  40% (1900800 / 1555200 on that table). Thermal emergencies remain exempt.
- asbdiag "governor plan" printed screen_on=? on every OP15 report: there is no
  panel_power_status node there. It now falls back to the governor's own screen verdict.
- The "throttle point below live CPU sensor" warning adds a note when the phone booted
  less than 10 minutes ago (the 66 C in the debug6 report was read 70 s after boot).

**fix96** - Budget self-correction pointed the wrong way; one forecast per screen
- Budget accuracy grading predicted the window's drop as elapsed/pred_h x 100, but pred_h
  is hours to empty FROM THE CURRENT LEVEL (pct / drain). Every window was over-predicted
  by 100/pct, the grade sat at error 100, and the self-correction streak built in the -1
  direction, nudging the drain fed to the budget DOWN by up to 12 % on a phone measured at
  9-12 %/h (24770: budget_error_pct=100, budget_bias_dir=-1). Now scaled by the anchor level.
- Screen forecast (action.sh + WebUI): after live and smoothed drain comes the slot's
  learned drain (smart_bucket_drain_x10, confidence >= 35 %), before the fixed per-profile
  mA. debug6 printed "~9 h 20 min" from a fixed 500 mA in the header and "3.3 h" from the
  slot's 19.1 %/h in the Smart card of the same report. New label in 13 languages; the
  Smart card budget line now also prints the slot rate it used.
- asbdiag: ro.lmk.* props printed under "OEM toggles" with the LMKD header empty - fixed;
  memory PSI gets a note when the phone booted under 10 minutes ago.
- action: "state: ... for 0 s" is shown without the duration when under 5 s.

**fix97** - Faster regression, no switch.mp3
- tools/asb_full_regression.sh queues every test script and runs them in parallel
  (ASB_REGRESSION_JOBS, default = CPU count, 4..12; 1 = sequential). Output is buffered per
  test and printed in order; a failure names the test and fails the run. Host run time
  1 min 52 s -> 50 s; three timer-bound runtime tests were 60 % of the old total.
- The per-fix contracts fix90/94/95/96 are merged into tests/test_field_fixes_contract.sh;
  new field fixes add a section there instead of a new file.
- webroot/switch.mp3 removed. It was only a fallback for a WebView without WebAudio, yet it
  was fetched and decoded on every WebUI open; all UI sounds are synthesised.

**fix98** - tests/ down from 125 to 87 files
- 39 source-pin contracts (10-200 ms each, referenced by no workflow, tool or doc) are
  bundled verbatim into tests/test_contract_bundle.sh, one subshell section per former
  file, so their variables, traps and early skips stay local and a failing section is named.
  Runtime tests that wait on real timers stay separate files, so the parallel runner can
  still overlap them. Every contract the workflows list by name is untouched.
- asb_lint.sh: the "C comment inside awk" check skips tests/, like the escaped-quote check
  already did - a test that embeds a C fixture and also calls awk is not an awk comment.

**fix99** - Russian and Ukrainian counts read correctly
- action.sh gets _npl, a one/few/many plural helper used only when a language defines the
  _1/_2 forms (ru, uk): "1 сессия изучена", "2 сессии", "579 сессий" instead of
  "1 сессий изучено". Applied to sessions learned, sessions banked and sessions discarded.
- ru/uk "vendor ceiling above ASB's in N checks" and "video refresh lowered N times" are
  reworded around the count ("проверок: 1") so no form is ever wrong.

**fix100** - App-op limits that the system reset are re-applied, not trusted
- wakelock_fitness=limit: _wl_fit_limit returned success on the record alone, so once an
  app update, a permission reset or the ROM's boot-time sweep put WAKE_LOCK back to
  default, the limit stayed lapsed for good while action/WebUI kept saying "limited".
  debug6 asbdiag: "now: ?" (no WAKE_LOCK entry) for Samsung Health and Renpho, with
  PedometerLib holding the CPU 16 min. The op is now re-asserted every pass, the ORIGINAL
  mode stays on record for restore, and a lock held while the op had lapsed is no longer
  taken as proof that "this Android does not enforce the app-op".
- The same for the multicast denial: a restricted app seen holding multicast gets its
  WIFI_MULTICAST ignore re-applied when the system reset it.
- asbdiag prints "now: default" instead of "?" and flags the lapse.

**fix101** - Smart on every OnePlus: three device-independent defects
- Memory pressure no longer leans Smart toward Battery while the screen is on. Reclaim
  (kswapd, lmkd, zram lz4/zstd) is CPU-bound; lowering the ceilings exactly then lengthens
  the stall the user is waiting on - the shape of the CPH2769 "freezes after the cinema"
  report and of the OP15 debug6 boot (PSI some 7.4 / full 4.8, alpha 876). Screen-off
  behaviour is unchanged.
- Refresh-rate modifier: Qualcomm SDE prints measured_fps as "fps: 59.9 duration:...", which
  fscanf("%d") never parsed, so the modifier was dead on every OnePlus. Parsed now; LTPO
  idle rates under 50 fps (OP12/13/15 drop to 1-30 on a static screen) are ignored instead
  of being read as a 60 Hz setting that cuts the touch bonus.
- Wake hints: OPlus touch panels report double-tap-to-wake and the other off-screen gestures
  as KEY_F4 / KEY_WAKEUP on the touchscreen's own input device, which the fix86 listener
  skipped for having absolute axes. Such a device is now admitted for those gesture keys
  only (a touch press never counts); it is parked with the others while the screen is on.

**fix102** - Camera guard measures every camera process
- Camera detection took the FIRST process /proc listed that matched cameraserver, the
  vendor provider or OPlus camerahalext - pid order, which differs per model and per boot.
  When that was cameraserver (a few % while recording) or an idle secondary provider, the
  provider doing the work was never measured and the camera hold (uclamp, cores, Smart
  camera relax) never engaged on that phone. The load is now the sum over all matching
  processes (up to 8); the set is rescanned when all of them exit, and refreshed every
  five minutes outside a camera session so a restarted provider is picked up.

**fix103** - Battery no longer pins the foreground to two efficiency cores on 4-cluster parts
- profile_core.sh gave the Battery foreground/top-app cpuset the FIRST cpufreq policy. On
  OP13/OP15 that is cpus 0-5 (six full cores), so the effect was just "no prime pair". On
  SM8650 phones - OP12, Ace 3, Ace 5, 13R (policies 0/2/5/7) - the first policy is the two
  A520 cores, and the app on screen ran on cpus 0-1. The prime cluster is now found by its
  hardware ceiling and the foreground gets every core below it: OP12 0-6, SM8550 0-6,
  OP13/OP15 unchanged at 0-5. Background cpusets are unchanged. The sysfs root is
  overridable (ASB_CPU_SYSFS) so the three topologies are checked on the host.

**fix104** - The same Battery cpuset bug in service.sh
- service.sh has its own copy of the cpuset pass (apply_cpuset_groups and the cgroup-v2
  pass), run at boot and on every runtime re-apply, and it too gave the Battery foreground
  0-$little_end - cpus 0-1 on SM8650 parts. fix103 alone would have been undone by it. It
  now uses bat_fg_end: every core below the first cpu with the highest cpuinfo_max_freq
  (OP12 0-6, OP13/OP15 0-5 as before). Background cpusets unchanged.

**fix105** - Prime lift in MODERATE too (Smart): fewer clipped touches on a cool phone
- The HEAVY-only prime escape missed where screen time goes. In the OP15 24770 capture the
  prime sat AT its 1747 MHz Smart ceiling in nearly every MODERATE sample at 36-48 C, and
  the main cores at theirs in about half - the scheduler asking for more on a cool phone,
  i.e. the "Smart is a bit laggy" reports (OP12/OP13/OP15). The escape now also runs in
  MODERATE: three pinned ticks (HEAVY keeps two), lifted only to Balanced's own MODERATE
  rail for that slot (HEAVY keeps the HEAVY rail), same 20 s burst / 40 s rest budget,
  and every refusal unchanged - thermal cap, die at the sustained-exit mark, skin inside
  the 8 C pre-lean band, charging, camera, games, heavy_prime_escape=0. Work that finishes
  at a higher clock lets the cores, panel and radio idle sooner (race to idle).
- WebUI description of "Prime Core Lift" updated in all 13 languages (fix106 added the ten
  that fix105 missed: ar, de, es, fr, hy, id, it, pt, tr, zh).

**fix107** - Memory stalls with the screen on: zram over the file cache
- smart_dynamic_tune.sh lowered swappiness by 10 for HEAVY/GAMING apps whatever the memory
  state. On a stalling system (PSI full avg10 >= 2 - every runnable task waiting on memory
  that share of the time) low swappiness makes the kernel drop file pages: app code and dex
  the next frame needs, re-read from storage while the UI waits. With 12-16 GB of lz4 zram
  on current OnePlus phones, parking idle anon pages in zram is far cheaper. Screen on +
  stall now lifts swappiness to profile base + 20; a calm phone keeps the profile value.
  (OP15 debug6: full avg10 4.78 at swappiness 25.)
- Governor log names the state a prime lift fired in (MODERATE / HEAVY).

**fix108** - The tuner hears about a memory stall when it starts
- fix107's swappiness rule lives in smart_dynamic_tune.sh, which the governor runs only
  when its signature (app tier, heat band, screen) changes - so a stall that began inside
  an app never reached it. The signature now has a memory-stall bit from PSI "full" avg10
  (on at 2.00, off below 1.00, screen on only), so the tuner runs when a stall starts and
  again when it clears. One small read of /proc/pressure/memory per screen-on tick; the
  usual 30 s debounce still applies.

**fix109** - Light-idle pin escalation watches the cores that carry the UI on 4-cluster parts
- The fix90 escalation (LIGHT_IDLE -> MODERATE when the cores sit at the light-idle ceiling
  for two ticks) read slot 0 only. On 2-cluster parts (OP13/OP15/Ace 5 Pro) that is the six
  main cores - correct. On SM8650 parts (OP12, 13R, Ace 3/5: policies 0/2/5/7) slot 0 is the
  pair of A520 efficiency cores, where UI threads do not run. Cross-device check of the
  captures: CPH2691 (13R, 2798) had the PRIME at its light-idle ceiling in 85% of screen-on
  LIGHT_IDLE samples and the little pair in 36%, so the escalation never fired for the
  cores that mattered. On 3/4-cluster parts it now watches the mid cluster and the prime;
  2-cluster parts are unchanged. The hold follows the slot that pinned.

**fix110** - Smart learns heat that lasts, not one-tick spikes
- A slot's "typical peak" was the average of each session's single hottest sample. On
  current OnePlus dies that sample is usually a launch or dexopt spike lasting one tick (an
  OP15 session opened at 94 C right after boot; 24770 read 61-66 C for its first minute
  only). The slot then learned 63.6 C against a phone norm of 46-54 C and Smart sat at a
  876/1000 battery lean in ordinary use - clipped ceilings for the whole slot, earned by a
  few seconds of heat. The learner (bucket update and session quality) now gets the session
  peak of a ~4-tick moving average: a single 94 C tick on a 45 C session registers as 57 C,
  heat that holds for ~12 ticks still registers in full. Every safety threshold (90/100 C
  hot-fail, thermal classification, reports) keeps the raw peak. The state file publishes
  both (ses_max_temp_raw / ses_max_temp_smooth). Old slot averages converge at the learner's
  usual 1/5 per session.

**fix111** - The new memory and heat signals are visible in reports
- Governor publishes mem_stall_now / mem_stall_entries (screen-on memory stalls the Smart
  tuner reacted to, counted on the rising edge). asbdiag prints them under memory PSI, and
  prints the current session's raw vs smoothed peak under Smart learning - so the next
  capture shows directly whether fix107/108/110 fired and how much of a "peak" was a blip.

**fix112** - Honest install advice for the camera, two blank asbdiag lines
- "camera colour is graded from a previous build" asked to disable ASB, reboot and install
  again. Not needed: that install ships no tone file and wipes /data/adb/asb/odm_patched and
  the bind manifest, so after its own reboot nothing of ASB covers the partition file and one
  more install clones real stock. Under KernelSU's NoMount metainstall the installer cannot
  unmount the old overlay itself, which is why the warning showed on every update until the
  detour. All 13 installer languages now say "after the reboot just install ASB once more".
- asbdiag: "tombstones kept:" printed blank for an unset prop (getprop exits 0 with an empty
  line, so "|| echo default" never fired) - now "platform default", with a note if it is 0;
  the timeline's "boot reason" is blank on current OnePlus builds (ro.boot.bootreason is
  empty) and now points to the "last boot reason" line.

**fix113** - From the first capture on fix112 (OP15 24817)
- Action screen, Audio: the DSP voice tone (dsp_voice) was the one DSP control never shown.
  Now "voice tone: level N (+x dB @ 350 Hz, -y dB @ 3 kHz)" while the DSP is on, 13 languages.
- Smart learning ignores the first five minutes after the governor starts: the session that
  began at boot carried a 74 C boot peak (raw = smoothed, the heat lasted) into the slot;
  the startup quarantine only drops sessions that END inside the window.
- Light-idle pin hold 20 -> 40 s. The escalation works (51 in ~100 min of screen-on) but the
  short hold let the state drop and re-escalate about every two minutes; ASB's own writes
  went 265 -> 363/h and transitions 21 -> 50/h.
- Governor publishes screen_on=0/1 in the state file; asbdiag's plan line still read
  "screen_on=?" because the "screen" JSON comes from `asb status`, not the state file.
- wakelock_fitness=limit on a ROM that ignores the WAKE_LOCK app-op (Samsung Health kept
  PedometerLib up to 5.5 min per hold with the screen off): the "limit_ignored" verdict now
  says what does work - the app's own setting, or Battery -> Restricted (13 languages).
- Confirmed working in the capture: budget grading error 16% (was pinned at 100), smoothed
  vs raw session peak 49/55 and 45/51 C, MODERATE prime pinned 13% (was 51%), 11 screen-on
  memory stalls with swappiness raised to 55 during one, forecast and Smart card agree.

**fix169** - a lift no longer trims on its own heat, Stock is reported as Stock, the
forecast after a governor start, Settings labels in the UI language
- Smart lifted the prime and then trimmed on the heat of that lift. Capture 8689:
  prime_escape lifted at a 41 C die, the burst ended a few seconds later at 48-50 C, and on
  that same tick screenon_comfort_smart_medium cut the ceilings by 9% with the shell at
  28-31 C; the die was back at 39 C on the next tick, the dwell held the trim for 30 s, and the
  round repeated four times in eight minutes. The screen-on comfort trims now enter only on a
  die that stays warm for 10 s (two readings at least that far apart); a trim in force keeps
  its exit band, and the headroom, skin, trend and surface stages are unchanged. asbdiag
  counts the entries held back. Native change: the governor needs a CI rebuild.
- asbdiag said "[PASS] ASB governor process alive" on Stock, ten minutes after the governor
  stopped: the fallback pattern '/asb' matched any process with that in its command line,
  asbdiag itself included, so the check could not fail - after a crash either. The governor
  is now looked up by its own binary; on Stock the check expects it stopped, and a dead
  governor elsewhere is a FAIL rather than N/A. On Stock the Smart learning and thermal
  source sections say why they are empty instead of "expected a session by now" and
  "uninitialized". The device verification tool looked for a process name the governor
  never had and always printed "no/unknown"; it uses the binary too.
- The action screen on Stock listed the Smart tilt, the throttling temperature and night
  quiet as if in force - all three belong to the governor that Stock stops. The profile line
  now says the governor is stopped and the ROM sets the limits, and those three lines are
  left out (13 languages).
- After a governor start - every boot, every switch to and from Stock, every config save -
  the screen-on forecast came from this hour's learned drain, an average of whole sessions
  with their screen-off part included: the owner's phone read "18 h 48 min with the screen
  on" at 5.0 %/h after a restart, against 9-11 %/h the drain meter measured in Smart later
  that morning. Until the governor has its own measurement, the drain the meter measured in
  this profile with the screen on (10 minutes or more, kept across restarts) now stands in for
  the slot figure, on the action screen, the Monitor drain tile, the time to empty and the
  drain sheet; a live measurement and recent screen-on windows still come first, and with
  nothing measured in the profile yet the slot figure stays, marked as an estimate.
- Settings: Wi-Fi power save offered "screen_off / always" under a badge reading "OFF", Leave
  Bad Wi-Fi listed "weak / unusable", Act on Wakelocks and Trim Background GPS showed bare
  "0 / 1", Keep Apps In Memory "hold" and Bluetooth stability "stable". All are labelled in
  the 13 languages, and value badges show the option's label instead of the stored value.
  The Wi-Fi scan slider reads "every 10 min" instead of "1". On narrow screens a slider on its
  own row uses the row instead of a 116 px track.
- Stock Monitor: socd is a state-of-charge level (it reads 5-8), not a temperature, and is
  no longer read as one.
- Log kit: the status-bar settings under a steady SystemUI redraw printed
  oplus.radio.smart5g_apk_cfg - two kilobytes of 5G app lists - because its value contains
  "Internetspeed". Keys are matched, not values; the hidden status-bar icons and the
  wallpaper service are recorded beside them.

**fix168** - Stock shows real readings on Monitor, every live tile explains itself, Home and
Settings fill the screen, the network settings survive a profile switch
- Stock showed CPU 95 C on a phone at 43 C: the OP15 publishes cpu-hw-trip-0/1 as thermal
  zones that read a constant 95000 (the hardware trip point) and the CPU filter matched "cpu".
  Trip, BCL and limit zones are no longer read as temperatures.
- Monitor on Stock emptied itself on a second visit: opening the page cleared every cell and
  hid the battery card, then the 10-second throttle skipped the read as too recent. The last
  ROM sample is now painted on open and a fresh one is read at once; the header no longer
  stays on the "OnePlus Device" placeholder (it was copied only from the governor's poll, and
  the UI-scale reading was glued to it as "427px @ 0.97x").
- The nine Stock tiles are nine ROM readings instead of ASB placeholders: CPU, shell, board,
  CPU ceiling (most limited cluster, per-cluster lines in the sheet), GPU load and clock,
  battery temperature, zRAM in use, and Smart learning "paused". The ROM sample no longer
  repaints the governor's grid on Battery and Balanced. System load shows the number alone,
  the 1/5/15-minute triplet stays in the tooltip.
- The slot line on the Smart card reads as a name and a pill (weekday / weekend) instead of
  "morning wkend" run together.
- A tap on any of the nine live tiles opens a sheet: the current value in the tile's colour,
  what the reading means and how to judge it, and where it comes from (the core sensor in
  use, time in the current state, the live ceilings in GHz). Stock has its own five texts for
  its ROM tiles. 13 languages, mirrored in Arabic.
- Home and Settings fill the screen the way Monitor does. Profile cards are taller, carry a
  one-line description and the screen-on / screen-off drain the meter measured for that
  profile; category tiles carry a short description, the number of enabled tweaks and a fill
  bar. The free height above the tab bar is measured and shared out within limits (cards
  68-104 px, tiles 104-176 px), so a small or dense screen scrolls as before and a tall one
  stops before the cards look stretched; checked at 360, 412 and 442 px wide, dark and light,
  Russian, German, Arabic and Chinese.
- After switching Smart -> Stock -> Smart the capture showed "queue (other networks):
  requested fq_codel, running pfifo_fast" and the Wi-Fi transmit queue at the profile's 1024
  instead of the chosen 256. The Stock baseline restore also returned default_qdisc (boot had
  captured it), and on the way back the profile wrote its own transmit queue over
  net_txqueue. The WebUI network appliers now run again after the Stock restore and after
  every profile switch.
- The action screen no longer lists a stopped governor as a problem on Stock, where stopping
  it is the point.
- Test variant AutoSystemBoost-V65-129-fix168-devicefont.zip: the same build with the WebUI
  text, the monospace labels included, in the phone's own font. A WebView only knows the
  families in fonts.xml and never sees a font applied through the font settings or a font
  app, so the variant takes the font files the system UI process has mapped - one applied
  from /data first, otherwise the OnePlus system family - copies them next to the page when
  they change and draws with them. The normal build carries the code but never runs it.
- Confirmed working in the capture: temperature reads in deep sleep (therm_keepalive_reads in
  every snapshot), the screen-off cooldown released after 52 s, the boot session banked at
  its 20-minute mark.

**fix167** - Smart learns from the first session after a boot again, a screen-off no longer
counts a session twice, a night is one night in the report
- After every governor start there was no session: fsm_init cleared the FSM and nothing gave
  the boot session a start time, so until the first profile change or reset command the
  session age read 0 - and Smart's 20-minute bank, the deep-idle session boundary, intent
  classification, the session history line and the bank on shutdown are all gated on it. The
  fix163 capture booted at 01:49 and learned nothing until it ended at 08:49
  (smart_sessions_total 726 and smart_quality_last -1 in every snapshot). The boot session now
  starts with the governor, with its sentinels (sustained efficiency -1, headroom minimum
  100); the zero minimum had also read as a vendor clamp ("cause_streak: vendor_clamp x3
  consecutive" with no vendor clamp in sight).
- Both screen-off paths ran the full per-profile stats save, and that save is also the
  learning step: session count, the max-temperature and efficiency averages, hot-fail and
  degrade counters, cause streaks, the battery night/day split. The session itself ends later
  and is saved again there, so each screen-off inside a session counted it once more - one
  hot Performance session with two screen-offs read as two thermal-wall hits, and two of
  those switch Performance to stable. A screen-off now keeps only the context the next
  session needs (thermal debt, clean-night reward, environment); the learning runs once, at
  the session's end.
- Shutdown appended the session twice - once unconditionally, once behind Smart's 20-minute
  floor - so a long Smart session was banked twice and a short one, the noise the floor
  exists to keep out, once. One call now, behind the floor when Smart is on.
- Log kit: the night row and the night verdict took the longest single idle or sleep phase,
  and a night is several of them - the recorder starts a new phase when idle turns into sleep
  or the screen-off class changes. The fix163 night (screen off 03:10, a one-minute glance at
  03:50 that never became a phase) was idle 4 + idle 23 + sleep 164 minutes, and the report
  said "night verdict: unavailable" with no night row. Idle and sleep phases back to back
  (gap up to 2 minutes) are now one night: 190 minutes, 0.63 %/h, 3.7% awake for that capture.
  A phase with the screen on still ends it.

**fix166** - the temperature stays live in deep sleep, the night window learns whole nights,
a wake is not judged warm on its own burst
- Deep-idle economy skipped every thermal read for as long as the phone slept, and the
  screen-off cooldown releases only on a reading. In the fix163 capture a 9 s face unlock at
  06:20 left the die at 46 C, the cooldown engaged on that reading, and until the capture
  ended at 08:25 the governor published temp=46 with temp_age_s=0 and thermal_cooldown=1
  while the zones read 30-39 C. The zones are now read at least every 5 minutes in any skip
  mode and every minute while the cooldown holds - on ticks that run anyway, so no extra
  wakeup. A skipped tick publishes the true age of the reading; the state file carries
  temp_read_epoch and therm_keepalive_reads, and asbdiag shows how old the temperature is.
- The night-window learner took a bedtime from any screen-off that lasted an hour and a wake
  from any screen-on after three hours of darkness summed since the last wake. A one-minute
  glance at 03:50 was learned as bedtime (23:46 moved to 00:47), older captures carry two or
  three bedtimes in one night, and "wake sample 13:06 -> learned 12:42" came from a phone on a
  desk - on the OP15 the learned wake reads 08:52 against mornings of 06:43-08:10. A night is
  now one dark chain: screen-off periods joined by checks under 10 minutes. It counts with
  three hours of darkness and a dark period that began between 19:00 and 05:00; bedtime (the
  chain's first screen-off) and wake are learned together once the wake has lasted 10
  minutes, a glance neither rejects nor restarts the night, and a desk day teaches nothing.
- Unlock lift: the screen-on tick reads the die in the middle of the wake burst, and one wake
  of the capture went unlifted as "warm" with every zone at 27-37 C. Warm is now the lower of
  that reading and the last one taken with the screen off (up to 30 minutes old), so a phone
  that went to sleep hot is still skipped and a cool one is not.

**fix165** - the governor reads your settings again, the drain meter measures on the OP15,
and the three page titles line up
- Since fix160 the governor ignored governor.conf. Its reader stopped at 192 keys and
  dsp_width made the file 193, so every load - at boot and at every WebUI save - was refused
  ("config_reject: startup load failed rc=-4", "auto-reload refused rc=-4") and the governor
  ran its built-in defaults: in the fix163 capture gaming_gpu 65, throttling 65/55 and
  highload default against a file of 55, 64/52 and stable, Smart battery bias 0 instead of
  600, the device-adaptive bounds off ("override=1 but the governor loaded 0 values"). The
  bound is now 512 with its own error code (-16); a host test loads the shipped file through
  the governor's reader. The governor publishes cfg_load_rc; asbdiag fails when it is not 0
  and the action screen says so in 13 languages. A config change picked up from disk now
  starts from the defaults and applies the high-load preset, as the reload command does.
- The drain meter took any battery status but "Discharging" for a charger. On the OP15 the
  status reads "Unknown" in every state, so in the fix163 capture it measured nothing in seven
  hours and every profile but Smart showed "measuring". A charger is now Charging/Full or a
  supply online, as the governor and the log kit read it; a new test runs the real loop with
  a fake clock and an Unknown status.
- Action screen: the prime ceiling line printed the thermal budget's wish (1382 MHz) while
  1862 MHz - the efficient minimum - was written; it shows what is written and what was asked.
- Home's "Power profile" title sat 14 px under "Battery & Smart" and "Configuration"; all
  three now sit 22 px under the header with the content 12 px under the title. A duplicate
  Monitor rule that overrode the fix163 spacing is gone.

**fix164** - the host tests are four files instead of 161
- tests/ held 152 shell scripts, 7 C fixtures and 2 Python checks. They are now four suites:
  `tests/asb_smart.sh` (Smart, governor, thermal, CPU/GPU and the native fixtures),
  `tests/asb_features.sh` (audio and DSP, network, doze, wakelocks, display, battery),
  `tests/asb_ui.sh` (WebUI, log kit, asbdiag) and `tests/asb_system.sh` (install, config,
  updates, packaging, CI, field-fix contracts). Each former script is a function `t_<name>`
  whose body runs unchanged in its own subshell - its exit, trap, set -e and variables stay its
  own - and each C fixture is a function `_c_<name>`; the Python checks run from heredocs.
  `bash tests/asb_<suite>.sh` runs a suite, `... NAME` one test, `--list` names them,
  `--source NAME` prints a C fixture. All 157 tests give the same result as before, and a new
  one checks the runner itself.
- `tools/asb_full_regression.sh` queues every test of every suite on its own, so they still
  run in parallel and a failure still names the test; lint builds the Smart fixtures from the
  suite; the CI workflows require the four suites instead of the test files they listed.
- `tools/asb_tree_check.sh` also names files the delivered tree does not have ("extra"), so
  the old test files left in a repository show up in CI as files to delete.

**fix163** - the Monitor fills the screen and reads as one piece
- fix162's title row inside the card made it lopsided, and a third of the screen stayed empty
  under the tiles. The Monitor now follows Home and Settings: a section title under the profile
  row ("Battery & Smart", or "Battery & system" on the other profiles), the card, the live
  title, the tiles.
- The card opens with two equal battery tiles - screen-on and screen-off drain, each with its
  time to empty under it (the two forecasts that had a row of their own further down); a tap on
  either opens the drain sheet. Smart shows the governor's forecast. Every other profile divides
  the battery level by the drain the meter measured in that profile and falls back to the
  governor's forecast until it has one; Stock, with no governor, waits for its own measurement
  instead of putting the battery current there.
- No chips on the card: what they said is the "Basis" reading - own slot, neighbour, similar,
  overall, cold start, or night / guard while those override, with the full meaning in the
  tooltip (13 languages). The session count moved to the Learner tile, which repeated the
  confidence before.
- The live grid is three rows of three taller tiles with equal columns even under a long label,
  sized for the reference phone (442 x 963 CSS px) so the last row ends just above the tab bar.
- Shorter clamp totals in German, Spanish, French, Portuguese and Armenian, which wrapped.

**fix162** - the Monitor card's chips move inside the card, and the card speaks the UI language
- The fix161 chips sat on the card's top border, half on its gradient and half on the page.
  Both Monitor cards (Smart, and the ROM card of every other profile) now open with a slim title
  row - "Smart learning" / "Battery & system" - with the chips at its right, the way the Home
  card carries its version chip beside the name; the drain strip follows it.
- English left in a localized card: Bucket, Conf, "#1 sleep·we", "medium", "42% bat", the
  "exact" / "daypart fallback" chip and the Home line "evening · 77% ...". They read Slot
  ("evening" with the day type beside it, slot number in the tooltip), Confidence, Battery lean
  77%, the load class and the slot source - exact slot, other day type, similar hours, best slot,
  cold start, with a tooltip on what that means (13 languages). Stock uptime uses the localized
  units; the drain-strip captions are no longer clipped at the top.
- Stock: an explicit "Discharging" from the battery is trusted over the current's sign, so a
  phone that reports discharge as negative current no longer reads "charging".
- Shorter strings where a tile cut them off: German trend and units, Ukrainian and Italian
  trend, Armenian day type.

**fix161** - a Monitor that fits, drain measured on every profile, lighter Settings, and CI
names the files a delivery left behind
- The fix160 debug build failed on "legacy effect does not apply the width". The test was right:
  the repository still held the fix159 `src/DSP/asb_dsp.c` (and an older CHANGELOG.md - the
  lint's "no section heading for V65"), so the legacy library CI builds from it would have
  shipped without Stereo Width. `tools/asb_tree_check.sh` compares the tree with the manifest of
  the delivered archive (`tools/asb_tree.sha256`; module.prop, update.json, workflows and DSP
  prebuilts excluded) as the first CI step and names every file that differs or is missing, as
  annotations and in the job summary - a warning, so a deliberate edit never blocks a build.
- Drain on every profile: `runtime/asb_drain_meter.sh` measures screen-on drain (battery
  level steps over sampled screen-on time) and screen-off drain (stretches of an hour or more
  without charging or music) with one method for every profile, Stock included, and keeps it
  per profile. Screen-on drain used to be counted only inside the Smart tick, and Stock runs no
  governor at all. Screen state comes from Android's display state (an always-on display is
  off), the backlight where that is missing; a 30 s / 60 s file-read loop, no binder call. The
  Monitor's drain pair now shows on every profile, and its sheet compares the profiles.
- Monitor: the drain pair is the first row of the card and half as tall, the tags sit on the
  card's top edge, the header gap is smaller and the live grid is four rows of compact tiles
  instead of five - about 150 px handed back above the tab bar. "Usual peak 51.8 C" became
  "Usual heat: normal / below / above norm" against this phone's own learned band; the figure
  is in the tooltip. The learner tile reads "100% · 726".
- Stock: the battery-current tile always read "-" while discharging - "discharging" matched the
  /charg/ test for charging. It shows the current now; the rate is in the drain pair.
- Settings: Reboot, Soft reboot and Restart SystemUI are one row of three small tiles in the
  categories' style instead of three full-width bars.
- Installer: removing the headphone volume limiter is an ordinary info line, no longer a
  "worth reading" warning - it is the user's own choice.
- asbdiag: the per-check list in section 11 drops repeated checks and indentation; drain per
  profile from the meter.

**fix160** - DSP Stereo Width, Media Volume Steps as a slider, and Smart stops cutting
ceilings on a cool phone
- DSP Stereo Width (`dsp_width`, 0-10): mid/side widening in the shared DSP core. The side
  signal above 180 Hz is raised 10% per step (level 10 = twice as wide); the centre - vocals,
  dialogue, mono recordings - and the bass are not touched, and a stereo-only stage runs before
  the limiter, so it cannot clip. Host test on the real core: x1.98 on the side at 2 kHz at level
  10, x1.10 at 50 Hz, a centred signal and level 0 bit-identical, the ceiling held at +25 dB.
  Needs the DSP library and the attach daemon rebuilt (build-dsp-aidl, build-dsp-attach); until
  then asbdiag says the library predates it. 13 languages.
- Media Volume Steps is a slider: far left is stock, then 20 to 100 in steps of 5. Stored
  values keep their meaning (stock, 30, 50); post-fs-data, the action screen and asbdiag accept
  any count from 16 to 100. Resampler Quality stays three choices: its stopband, filter length
  and cutoff move together, and past "max" there is nothing audible left to buy.
- Smart: a fast thermal trend no longer cuts the ceilings while the body is cool. Every trend
  trim in the log tails of the owner's OP15 day came at a skin of 28-31 C with the HAL headroom
  at 83-100% - stage 3, CPU and GPU ceilings 34% lower, "cool" again 30-60 s later. The trend
  follows the hottest CPU sensor, which an app launch or a camera start lifts in two ticks, so
  the trim landed exactly while the burst needed the speed. It now also needs the skin within
  8 C of thermal_skin_c (the band the light headroom stage uses). SUSTAINED, the hot guard, the
  junction guard and the headroom stages are untouched; no usable skin keeps the old rule.
  asbdiag counts the trims held.
- Smart: a CPU ceiling ASB asked for itself is no longer counted as a vendor raise. The action
  screen read "vendor ceiling above ASB's in 100 checks, clock above our limit in 59", and both
  log lines behind it carried the writer's own request of 3648000 - the 80% unlock lift. A
  ceiling at or under what the writer last requested is ASB's own (unlock lift, prime burst, a
  lowering write not landed yet) and is counted apart; asbdiag shows both.

**fix159** - Bluetooth DSP from the first second, back gesture inside the WebUI, drain with
the screen on and off, a calmer light theme, and asbdiag separates your choices from what is live
- DSP route on phones whose kernel publishes no PCM state (OP15, AudioReach: the ALSA status
  section of the capture is empty in all 22 audio snapshots, speaker playback included). That
  state was the route watcher's only cheap playback signal, so with the screen off it never
  looked at the audio service, and after the screen came on it slept out its 60 s nap and a
  30 s back-off. Bluetooth music played unboosted for about 80 s - asbdiag at 19:13:57 and the
  action screen at 19:14:45 read "playing on speaker, not processed" while STREAM_MUSIC was on
  bt_a2dp - and then jumped +25 dB mid-track. Now, where there is no PCM state, the watcher
  reads the activity of audioserver's AudioOut threads (schedstat run counts, context switches
  as a fallback: file reads, no binder call); the screen-off nap is cut into 5 s slices that end
  as soon as the governor publishes screen on; and a route overwritten by the settings applier
  is published again. The real loop in virtual time: Bluetooth published 5 s after playback
  starts with the screen off (was: not until the screen came on), screen on noticed in 7 s (37 s
  with the same timing before), and an idle screen-on minute costs no audio-service dump on OP15
  (two before). asbdiag prints "route lag" when the published route and the music disagree.
- Back gesture: the WebUI keeps one history entry per open level (a page other than Home, a
  category, each popup). Back closes the top popup, then the category, then the page; only on
  Home does it leave the WebUI. Levels closed by a tap or a tab switch keep the history in step.
- Monitor: the Smart card shows the drain with the screen on and with the screen off side by
  side (the usual peak temperature for this hour took the freed tile); a tap opens a sheet with
  what each figure is based on and the time to 0%. 13 languages.
- Light theme: neutral ink and borders instead of green-grey, Monitor values no longer in the
  accent, each category title in its own colour as in the dark theme instead of one red for all,
  a crisp wordmark without the glow. Green stays on the Smart card and on what is selected or on.
- asbdiag section 11 "your settings vs what is live": every WebUI setting that differs from the
  shipped default (name, default -> value, by category), one line per live check, the system
  settings Android refused, what waits for a reboot (post-fs-data keeps the config this boot
  used) and a verdict that reads FAIL. A phone with fewer tweaks on shows fewer PASS lines, not
  a worse install.
- Captures record the status-bar settings that redraw every second (network speed meter,
  seconds on the clock, battery percent) and name them under a steady SystemUI redraw; the
  capture comparison notes that ASB CPU per hour grows with the screen-on share.

**fix158** - the Doze picker explains itself, and ticked apps stay exempt by day on night
- Deep Sleep on night: outside the sleep window every trimmed app is given back (as before),
  but the same path also withdrew the exemptions ASB had given to ticked apps - a ticked
  messenger Android did not exempt was exempt at night and dozed by day, against what the
  card says. Out of the window the trimmed apps come back and the ticked ones keep their
  exemption; turning the trim off, Deep Sleep to stock or moderate, or uninstalling still
  withdraws them. The night window is one shared function, used by the applier and by `list`.
- The picker by day on night said the trim was working and showed an empty Trimmed with no
  reason. `list` now says whether the window is open and when it is, and the picker shows
  "trims only inside the sleep window (23:15-06:40), it is closed now".
- Labels follow the tick: a trimmed app ticked reads "returns on Done", ASB's exemption
  unticked "exemption removed on Done", a new tick "exempt on Done", an exempt app unticked
  while the trim is live "trimmed on Done". A "What the labels mean" section explains
  exempt / exempt via ASB / trimmed by ASB / never trimmed and the Ticked / Trimmed filters.
- French and Armenian: the Deep Sleep option labels were English.

**fix157** - DSP Outputs is the first card of the DSP section
- It switches the whole DSP on and off since fix155, so it now sits above DSP Loudness instead
  of below the compressor - the choice that decides whether the sliders under it do anything
  comes first.

**fix156** - Smart stops handing the work to the prime cores when it cools the phone
- Main cores kept level with the prime under the comfort trim, in HEAVY and in SUSTAINED. On a
  6+2 phone the trim and SUSTAINED's 49% rail took the main ceiling to 1555200-1785600 kHz
  while the prime could not follow (its 40% floor holds it at 1862400), so the two prime cores
  became the bigger cluster exactly when the phone was warm and the scheduler moved the work
  there. Nine captures from two OP15s (fix150 round and later), warm MODERATE screen-on samples (surface
  40 C and above): main level with the prime - prime working in 9%, 337 mA, die 44.1 C; main
  more than 10% below it - prime working in 67%, 456 mA, die 47.7 C (the heavier moments sit
  in the second group too, so part of the gap is load, not all of it). SUSTAINED: 73-86% of
  the work on the prime at 52-56 C. The level kept with the prime (fix130/fix132) now holds in
  those states as well; the trim still lowers the GPU and the background tier, a real thermal
  cap (throttling, hard vendor clamp) and GAMING keep their own path. The state file says when
  the raise is the one held while cooling (`main_parity_cooling`, `main_parity_cool_lifts`),
  and asbdiag prints it.
- Full-day report, SCREEN-ON WORK BY CLUSTER: the mean sampled current per row and a warm
  split (surface 40 C and above), where this change shows.
- `tools/asb_capture_compare.py`: three new figures per capture computed from the raw traces -
  warm screen-on samples with the main ceiling under the prime's, how often the prime worked
  then, and the mean current - so the fix150 round compares with the next one. The fix150
  baseline carries them (CPH2745 24% / 41% / 451 mA, CPH2747 14% / 31% / 412 mA).
- Read and left as it is: YouTube watched without touching the screen keeps missing 2x the
  UI frames in LIGHT_IDLE on the OP15 (5.1 against 2.8 janky frames a second in MODERATE on
  one phone, 2.1 against 1.3 on another; the CPH2769, SM8845, does not show it). Every lever ASB has
  is identical in the two states there - both ceilings (1996800 / 1862400), top-app uclamp 50,
  GPU ceiling and floor - only the clocks the load itself asks for differ (main ~1.0 against
  ~1.3 GHz). No cause in ASB's writes.

**fix155** - the DSP switches off in one tap, two audio tweaks set before Android starts
- DSP Outputs has an `off` position: the whole DSP is switched off (enable 0, no route, reason
  `outputs_off`) while loudness, bass, voice tone and compressor keep their positions and come
  back as they were when an output is picked again - no need to pull every slider to zero.
  Their cards show "DSP off" instead of looking active; the action screen and asbdiag say the
  DSP is off because of the outputs choice.
- Resampler Quality (`audio_resampler`, stock | high | max, reboot): Android's mixer converts
  tracks whose sample rate differs from the output's (44.1 kHz music on a 48 kHz output).
  high sets `ro.audio.resampler.psd.*` to a 140 dB stopband and 160 taps per side from 44.1 kHz
  up (stock: 90 dB and 32 taps, from 48 kHz); max to 179 dB, 320 taps, cutoff 99%. Set before
  Android starts; offloaded playback and matching rates are untouched, `af.resampler.quality`
  stays 0 as before. The card says plainly that the gain is measurable and for most people
  inaudible, and what it costs in CPU.
- Media Volume Steps (`media_vol_steps`, stock | 30 | 50, reboot): `ro.config.media_vol_steps`,
  read by the audio service when it starts. The loudest step stays as loud; the saved step
  number is kept, so the first playback after the reboot is quieter. Some ROMs keep their own
  scale - asbdiag and the action screen compare the steps Android uses (STREAM_MUSIC Max)
  with the setting and say live, after the next reboot, or ignored by this ROM.
- French and Armenian: the generic option labels (auto, on, off, stock, max ...) were Russian
  words in both files, and two Armenian Wi-Fi texts had a Cyrillic word inside. Fixed; lint
  now fails on Cyrillic text in any language file other than ru and uk.

**fix154** - pages fade, 5G stops flapping, the limiter switch tells the truth, kept apps stay kept
- WebUI: moving between Home, Monitor and Settings is a fade instead of a slide from the
  right - the page being left fades out in 0.16 s, the next one fades in over 0.26 s with a
  slight scale, so the two never sit half on screen together. Reduced-motion settings keep
  the fade and drop the scale.
- 5G only when needed (`net_lte_light`): two OP15 days show the watcher choosing LTE as soon
  as a 10-minute hold ran out and three quiet minutes passed, then giving 5G back 40 s to
  5.5 min later while feeds were scrolled - a network-type switch each way every 12-15
  minutes for nothing. A give-back that ends an LTE stint shorter than 5 minutes now doubles
  the next hold (600 -> 1200 -> 2400 s); a stint that lasted resets it to 600 s. The log line
  says how long LTE lasted.
- Headphone volume limit: the card said "applies immediately" and the toast "applied", but
  since fix151 the limiter is switched by `audio.safemedia.bypass`, which Android reads when it
  starts. The card and the toast now say a reboot is needed; the switch sets or clears the
  property at once, so the next start of the audio service picks it up. The settings write it
  replaced did nothing - Android records its own decision there. The action screen says
  whether Android confirms the limiter is off, or that one reboot is still needed.
- Apps ticked in the Doze picker are also left alone by the wakelock watcher (restricted
  bucket) when the trim is off, and by background trimming (the "rare" bucket and memory
  trims of heavy apps such as Facebook or Instagram).
- `tools/asb_capture_compare.py`: a phase shorter than 30 minutes or marked '~' is not
  compared (its awake share was), the Wi-Fi queue is read from the fix151 asbdiag line, and
  the context line gives both capture lengths.
- Read and left as it is: the OP15 capture of this round (fix153, 2.5 h) shows the limiter
  disabled by Android, the Wi-Fi queue at 256, the trim working (7 apps). YouTube untouched
  again misses 34-43% of its own UI frames in LIGHT_IDLE against 15-18% in MODERATE; the GPU
  sits at 4-8% busy near 190 MHz in both, and ASB's own GPU ceilings differ by 4% between the
  two states (max_pwrlevel 9 against 8; the lower levels seen in MODERATE are the vendor's
  touch boost). No cause in ASB's writes is established.

**fix153** - the next round of field logs can be measured against this one
- Wi-Fi leave in the full-day capture: the watcher's own log keeps 80 lines and no capture
  copied it, so "still holds a dead access point for about 10 s" could not be measured. Its
  events are now kept for the whole capture (`wifi_leave_events.log`, each line once) and the
  report has a WI-FI LEAVE section: releases by reason, the time from the first failing
  reading to the release (median, longest), streaks that recovered on their own.
- asbdiag puts ASB's own CPU time per hour next to the total since the governor started.
- `tools/asb_capture_compare.py` (host): reads captures and asbdiag reports from folders or
  zips, counts a capture sent twice once, and compares a new set with a saved one per phone
  model - overnight rate and awake share, idle and screen-on drain, janky frames per second
  (overall, floor, LIGHT_IDLE, MODERATE), prime use, ASB CPU, Wi-Fi leave time, the headphone
  limiter, the Wi-Fi queue and the Doze trim. The fix150 field logs are saved as
  `docs/field_baseline/fix150.json`.

**fix152** - the apps the Doze trim must leave alone are picked in the WebUI, with a search
- Testers on the Doze exemption trim: "the best tweak against night drain - GPS, fitness and
  wakelock together did not do what trimming the exemptions did", and the wish to choose the
  apps it leaves alone right in the WebUI. The button under the switch now opens a window with
  every user-installed app, a search by name or package (names and icons come from the root
  manager when it gives them; otherwise the package is searched), and filters for ticked apps
  and for what ASB has trimmed. Each app says where it stands: trimmed by ASB, exempt, exempt
  via ASB, never trimmed (authenticators, watch companions, caller ID). The old list showed
  only apps Android still exempted, so an app ASB had already trimmed was not there to tick.
- A ticked app is kept out of Doze for real and at once: closing the window applies. An app
  ASB trimmed earlier is given back; an app Android dozes gets the exemption from ASB - before,
  ticking it changed nothing and the screen could only say "grant it in Settings". What ASB
  grants is recorded (`doze_whitelist_added`) and withdrawn when the app is unticked, when the
  trim is turned off or Deep Sleep leaves aggressive/night, and on uninstall; with "night" the
  trim, and the grants with it, hold inside the sleep window only, as before.
- Wakelock watcher and the trim together: the watcher never restricts an app on Android's
  exemption list, because the user put it there - and the trim removes exactly those apps.
  With both on, a VPN or mail client marked unrestricted lost that protection and could be put
  in the restricted standby bucket. The trim's record now counts as the user's exemption there,
  and such a restriction made earlier is given back.
- asbdiag (8a) prints the trim's state: how many apps it removed, kept from the WebUI list and
  made exempt, with the package names.
- Corrected reading of fix151 (YouTube in LIGHT_IDLE): ASB's ceilings, the top-app uclamp
  ceiling (50) and the requested floors are the same in LIGHT_IDLE and MODERATE on that phone,
  untouched MODERATE intervals earlier the same day missed 25-30% of YouTube's frames too, and
  video apps on a CPH2691 show 15% in MODERATE. The deadline misses belong to the video apps'
  own UI drawing more than to the state; the governor is not changed for it.

**fix151** - the Wi-Fi transmit queue really changes, the volume limiter stays off, Wi-Fi is
left sooner, and an install under one more Magisk build is clean
- "Transmit queue" (`net_txqueue`): five asbdiag reports with short or shorter, one of them
  on Wi-Fi, all read wlan0=1024. The script ran `ip link set dev wlan0 txqueuelen N` with the
  first `ip` on PATH, which in a module script is the root manager's BusyBox applet - it knows
  the keyword only as "qlen" - and the error went to /dev/null. The queue is written in sysfs
  (`tx_queue_len`, read back), with Android's own iproute2 as the fallback; the restore uses
  the same path, so turning it back to stock now gives 1024 back too. The 2-minute network
  loop also re-applies when the Wi-Fi driver resets the queue, not only when an interface
  appears. asbdiag says the target ("256 on Wi-Fi"), lists the mobile links apart as left to
  the platform, and warns when wlan0 is not at the target.
- Headphone volume limit: with `audio_remove_volume_limit=1` two of the field phones (13R,
  15R) still had the safe media volume ACTIVE for whole captures. ASB wrote
  `audio_safe_volume_state` at boot, but that setting is only Android's record of its own
  decision - the audio service decides at boot from the region and its config, and arms the
  limiter again after 20 hours of listening. The switch now sets `audio.safemedia.bypass`
  before Android starts, which makes that decision "disabled". asbdiag prints the property and
  tells a missing reboot apart from a ROM that ignores it. Applies at the next boot, as the
  card already said for every non-live key.
- "Leave bad Wi-Fi": "leaves about 10 s sooner than before, but still holds a dead access point
  for about 10 s". The watcher confirms with three readings in a row 8 s apart, 16-24 s from the
  first weak one. Once a streak has begun it now looks again after 3 s - the release lands
  about 6 s after the first reading below the threshold. The same on "aggressive" for a link
  that lost its internet; "unusable" keeps 8 s between such readings, the grace a captive
  portal sign-in needs.
- Install: one Magisk build runs module installs without `NVBASE` in the environment, and its
  log ended in "can't create /modules/.AutoSystemBoost-files" and "can't create directory
  '/service.d': Read-only file system". The template builds its file list, the uninstall
  helper and the service.d path from that variable, and install.sh looks for the previous
  config under it (the snapshot kept the settings). customize.sh sets /data/adb when it is
  empty, before anything reads it.
- asbdiag, frames while the report ran: run from a terminal, the terminal is the report's own
  window - "com.termux 663 of 676 frames (20.72/s)" and a "steady" verdict were read by an
  outside audit as 90% UI lag. The app in front when the report starts (top-app group, a
  regular app uid, oom_score_adj 0) is now named as "the window this report is printed in",
  and gets no steady verdict.
- Read and left as they are: YouTube playing untouched draws its own UI at about 12 frames a
  second, and on two OP15s 21-31% of those miss their deadline in LIGHT_IDLE against 1-12% in
  MODERATE at the same 60 Hz panel rate and the same ceilings (never reached); the main cores
  run at 0.7-1.0 GHz there against 1.4-1.8 GHz in MODERATE, whose floor is about 1 GHz. The
  video itself is not affected. Night on the OP15 reference phone 0.56 %/h, 4% awake over 538
  minutes; the prime did the work in 14% of screen-on samples; ASB's own cost 1.65 s of CPU an
  hour.

**fix150** - the unlock, and Smart up late
- Unlock lift (Smart). "Slideshow at unlock after a short idle, then smooth again", from several
  users of the same build. Capture 28442 (OP15) could not show the unlock itself (see the
  recorder item below), but the first recorded interval after two wakes drew the launcher with
  31 of 262 and 18 of 39 frames janky, against 1.7% over the capture, and every wake landed on
  Smart's MODERATE ceilings - main 1996800 of 3628800, prime 1862400 of 4608000, top-app uclamp
  50 - with a raised floor held at them (policy0 min 1785600 / max 1996800, policy6 min = max).
  For `unlock_lift_s` seconds (default 3) after the screen comes on, and once more at the first
  touch within 20 s of it (the swipe that dismisses the lock screen), every managed CPU ceiling
  is lifted to `unlock_lift_pct` (default 80) of its cluster's maximum and the top-app uclamp
  ceiling to the same share. Ceilings only, no floor: the clocks climb only if the unlock asks.
  Not in Battery/Balanced (the shell owns the ceilings there), not with a thermal cap, not on a
  die at `bat_comfort_temp` or above; the tick that ends it keeps the 2 s cadence. State file
  `unlock_lift`, `unlock_lifts`, `unlock_lift_skips`, `unlock_lift_skip_why`; asbdiag, the
  action screen and the capture report show it. `unlock_lift_s=0` turns it off.
- Smart up late with the screen on. The night slots are seeded for a sleeping phone - 00-06 at
  alpha 950 with no touch bonus, 21-24 at 750 with 20, against the evening's 400 and 80 - and
  learning moves a slot by a few thousandths per session, so the seeds rule for months, screen
  on included ("when I stay up late the animations get less smooth"). With the screen on, a
  night slot now leans no harder toward economy than this phone's own evening slot (same
  weekday/weekend half) and gets at least its touch bonus; the user's bias, low battery and the
  thermal veto still apply on top, and screen-off is unchanged. `smart_night_awake=0` turns it
  off; state `smart_night_awake`, `_from`, `_to`, `_ticks`.
- Captures, the wake itself: a screen-off poll dropped the jank baseline, so the first
  screen-on poll after a wake only set a new one - the unlock and the first seconds of use were
  in no row. The last screen-on baseline is now kept through the screen-off stretch and the
  first poll after it writes one row marked `wake` (column 18). The report gives the wakes
  apart ("the wake itself: N wake(s) ... janky X% (ordinary screen-on intervals: Y%)", by app);
  their seconds are mostly screen-off, so they stay out of every per-second figure.
- asbdiag: the cap line called the six main cores of a 6+2 part "little" ("cap desired/
  effective : little 1996800"); main there, little only on a 3+ cluster part.
- Action screen: the Wi-Fi leave watcher's status was printed as its internal token
  ("наблюдение за Wi-Fi: waiting_for_wifi_default_route"); it is said in words now - waiting
  (Wi-Fi is not the default route), watching with signal and threshold, Wi-Fi without
  internet, pause or release with minutes left - in all 13 languages.
- Read and left as they are: the SUSTAINED state and 69 C two minutes after the install
  (post-update dexopt); the panel at 90/120 Hz in every screen-on sample (no stuck 60 Hz); the
  GPU at its lowest clock while busy is the vendor's DCVS under a 1.2 GHz ceiling ASB leaves
  open; deep sleep "aggressive" (owner's choice) idles after 2 minutes, so most wakes leave
  Doze and run its deferred work at once - the first seconds of that now run under the lift.

**fix149** - a second, file-by-file pass over CPH2769 capture 13290
- "Leave bad Wi-Fi" under a VPN: the watcher took Wi-Fi as the default only when the route to
  the internet named wlan. A proxy app held the default all day ("1.1.1.1 dev tun0 table
  tun0"), Wi-Fi up beneath it in 19 of 21 hourly samples, and the watcher sat at
  "waiting_for_wifi_default_route" the whole capture - the feature could not act for anyone
  with a VPN on. Behind a tunnel it now reads what the tunnel rides on: netd's rule for unmarked
  local traffic with no uid range ("fwmark 0x0/0xffff iif lo lookup <table>"), the system
  default network. The "5G only when needed" / screen-off LTE check asks the same rule first:
  a Wi-Fi that is connected but not the default keeps a default route in its own table, which
  read as "on Wi-Fi".
- Captures, screen-off traffic: only mobile bytes were measured, so on Wi-Fi every phase read
  "0.0 MiB - the radio was idle" while the Wi-Fi chip woke the phone 3893 times (the wakelock
  report's top kernel wake reason). Wi-Fi is measured beside mobile now - the 161-minute night
  stretch moved 3.0 MiB over mobile and 70.1 MiB over Wi-Fi - and "nothing to attribute" needs
  both under 1 MiB. A Wi-Fi counter that went backwards (interface restarted) adds nothing.
- Captures, Bluetooth evidence: Android 16's bluetooth_manager dump starts with its feature
  flags ("[■]: a2dp_lhdc_api") and a connection-policy line per bonded device. They matched
  the codec grep and filled the kept lines - 44 of the 120 in a lifecycle snapshot, all 20 in
  every "# bt codec" block - so the codec in use never showed. Both are filtered out first,
  in the full-day capture and in the audio A/B tool.
- Governor, hour-of-week learner: every tick added the battery current's magnitude as drain,
  charging included - the log read "learner updated: drain=2317.0mA screen=0%" for an hour of
  3.4 A charging. A charging tick carries no drain now; an hour on the charger still teaches
  the screen share (what the prediction uses) and leaves the drain as it was.
- Captures, cap_verify: policy0 of a 6+2 part was labelled LITTLE - the same mislabel fix146
  took out of asbdiag. MAIN there.
- LTPO video: two layers asking for 30 and 60 fps broke the log line in two ("for 30" /
  "60 fps video"); the rates are joined.
- Read and found in order: the thermal service's cached CPU temperatures (99.6 C on every
  snapshot) are a stale cache, the trace peaked at 54 C; GPU at wake sat at its usual level;
  memory PSI low; HFP opened 46 times (calls and voice notes), A2DP never dropped.

**fix148** - a charge paused by battery protection is the charger, not a night on battery
- CPH2769 (15R) capture 13290: OnePlus battery protection parked the level at 80% with the
  cable in for 161 and then 48 minutes (status "Not charging", 0 mA, the kernel's charger
  wakeup source "wired wakelock" held the whole time). The recorder read only Charging and Full
  as the charger, so both stretches were filed as "sleep": 99.3% awake and 0 %/h in the sleep
  row, and "night verdict: valid (226 min)" with no night row under it - the longest on-battery
  stretch was much shorter. A charger online at "Not charging" is now the charger in the phase
  classifier, the battery trace and the charge trace; the charging block counts the held
  samples and says why; the night verdict comes from the longest idle/sleep phase - the one
  the night(longest) row is built from - and says when the screen-off time was on the cable.
- The governor read "Not charging" as on battery too, so such a hold was a screen-off window
  with no drain for the off-screen learner, which averages windows like it into its idle
  figure. It now asks the supplies, as it already did for a status the driver leaves empty.
- Charging-idle phases get the kernel holders the screen-off phases have (batterystats counts
  no app wakelock on the charger), and the charging-idle verdict names them: a charger/USB
  wakeup source holding the CPU while the cable is in is the phone's design, not an app.
- Action screen: "on charger, charging paused (battery protection)" next to the level, and
  no time-to-empty then (13 languages).
- Also in this capture: YouTube untouched 1.49 janky/s in LIGHT_IDLE against 1.77 in
  MODERATE - with PLQ110's 2.66 / 1.95 there is no consistent LIGHT_IDLE penalty; RuStore
  (ru.vk.store) jobs were the top app holder in the screen-off phases (wakelock_action=0,
  report only), Bluetooth wakeups (qup_uart, hal_bluetooth_lock, qcom_rx_wakelock) the top
  kernel ones with a Xiaomi wearable paired.

**fix147** - the CI build of fix146 failed on a timing test; the cancel it measures waits longer
- "debug support: removed output dir did not recover capture slot" on the GitHub runner, not
  reproducible here (17 runs, 8 of them in parallel under CPU load). The path: the user deletes
  the folder of a running full-day capture, the helper kills that recorder and waits for it
  to be gone before freeing the slot. It waited 1.2 s, KILLed again and waited 0.5 s more;
  on a loaded machine that read a dying recorder as alive, kept the lock and answered
  "already running" to a cancellation that had worked. Now 3 s, then 2 s after the second
  KILL, and a process in state X (dead, not yet removed) counts as gone like a zombie. The
  test prints the helper's answer, the recovery log and the recorder's state when it fails,
  so another failure names its cause. The recorder in that test is a mock: none of the
  fix146 changes run there.

**fix146** - an update no longer drops the /odm audio binds on non-reference phones; captures judge the right cores
- Install, non-reference OnePlus (Ace 6 / PLQ110, 15R / CPH2769 and the other phones on the
  device-native generator): every install over a running module lost the /odm runtime binds -
  the DSP's effects config, the mixer, the hi-res audio policy, the media profiles - and the
  next install brought them back. The generator's reset ran after the audio stage and deleted
  the effects-config bind the DSP registration had just queued; its own copy of each live file
  was then dropped as "identical to the live file", and after an update the live file is the
  previous install's bind. PLQ110 on debug7: "effects config WITHOUT ASB:
  /odm/etc/audio_effects_config.xml" while the /vendor copies listed it, "library mapped into
  the audio HAL: absent", no "odm-side audio/media" line in the install log; its debug4 and
  debug6 captures had the DSP live. fix145 tied that to the new aidl_v2 library; the /odm
  config - which AOSP reads before /vendor/etc - simply never named it. CPH2769's install log
  lacks the "odm-side audio/media" line too (its DSP is off). Now the reset runs once, before the
  audio stage; the generator no longer touches the effects config (one writer for it); each
  file it patches is compared with a stock snapshot of the partition, kept across installs,
  instead of with the live path; an ASB bind in front of the target (read from init's
  mountinfo, /odm links resolved) means the live path is ours, so the file is queued. After a
  system update a snapshot is stale while our bind still hides the new file: that file is held
  back once (said in the install log), the reboot shows the new stock and the next install
  snapshots it. asbdiag says, for a stock /odm effects config, whether its bind was never
  queued or queued and not live. Run on fake /odm paths across five installs, a pre-fix146
  device, a system update and /odm as a link (test_odm_bind_reinstall_runtime).
- Captures, 1+3+2+1 parts (CPH2691 / OP12 / Ace 3 and 5, SM8650): the jank trace's "main
  cores" were policy0 - the pair of A520 efficiency cores, which run no UI - so every "main
  cores at the ASB ceiling" line from those phones described the wrong cores, the mistake
  fix109 took out of the light-idle escalation. Main and prime now come from the governor's
  own slot map (slot_policy_ids): policy2, whose ceiling the writer also puts on policy5, and
  policy7. The capture records the map in cluster_layout.txt and the report names it; the
  throttle split calls the first cluster "little" there, since that trace still reads policy0.
- Captures, per-app table: it went to the app with the most frames only. PLQ110 capture
  28616 showed the app store there (0.8% janky) while "LIGHT_IDLE 25.6% janky" above it was
  YouTube playing untouched. The app in front with the most janky frames now gets its own
  table: YouTube untouched 2.66 janky/s in LIGHT_IDLE, 1.95 in MODERATE, 1.79 in mixed, with
  the main cores at their light-idle ceiling 5% of the time - not the ceiling, and not yet
  explained. The touch column is explained: the governor counts a touch that begins after 3 s
  without one, so steady typing reads "no" (the CPH2691 "untouched" Nagram rows were typing).
- Report: "modem LPM mode:" printed nothing where asb_lpm.sh publishes no mode (the LPM
  feature or the cellular power policy off - CPH2691); it says so now.
- asbdiag: policy0 of a 6+2 part (OP15, 15R, Ace 6) was labelled "little" in the cluster list
  and the slot map - six of eight cores, carrying most of the phone's work. It reads "main".

**fix145** - Settings no longer twitch on opening; interface sounds switchable and quiet over music; Bluetooth level visible
- Settings: "the six category cards twitch every time I open Settings". The hub was painted
  before the page slid in, again by the slide-in, and again when the saved values and the
  device grade arrived - with the row entrance animation each time, so the cards jumped two or
  three times. The entrance now runs on a change of screen only (opening Settings, entering a
  category, going back to the hub), and a repaint that lands while an entrance is still
  playing waits until it has finished. Checked in a browser with the module's page: opening
  Settings animated each card once (was twice or three times), a same-screen repaint animates
  nothing, entering a category animates each row once.
- Interface sounds: a CPH2691 user heard his Bluetooth music dip in loudness and bass for
  about a second each time he opened the Audio category, and asked whether the engine
  restarts. It does not - opening a category writes nothing and restarts nothing. The click
  the page plays on navigation does: each cue opens the WebView's own audio stream for about
  1.5 s (fix135 releases it after that), and on many phones a second stream starting makes
  the mixer and the Bluetooth codec duck and re-level the music already playing. Two changes:
  a switch next to the language button in Settings (stored per phone, 13 languages), and no
  cue at all while another app is playing - the page asks the audio service (one dumpsys,
  at most every 15 s, never while its own stream could be the one counted).
- asbdiag, Bluetooth: the same user reports Bluetooth much quieter since the previous
  builds - maximum barely audible, two headsets and a car. The cause is not established;
  nothing in the logs showed what Android did to the level. asbdiag now prints the audio
  service's safe-media-volume, sound-dose (CSD) and absolute-volume lines, and says so when
  audio_remove_volume_limit=1 but Android reports the limiter ACTIVE again (the switch writes
  the setting at boot; the system can arm it again later). The full-day capture's audio
  snapshot carries the same lines. bt_absvol_mode=disabled was printed as "auto - no forced
  expectation" (only the legacy on/off were matched); it is checked now, stock gets its own
  line.
- DSP, PLQ110: the fix139 aidl_v2 library (362072 bytes) is not mapped into the audio HAL,
  where the earlier v2 builds were; by the time asbdiag ran the boot log with the loader's
  error had rotated away. service.sh looks once, 45 s after the attach starts: with the
  library mapped nothing is kept, otherwise the HAL's name and pid, the installed ABI and size
  and the HAL's own lines about the library go into /data/adb/asb/dsp_load_check.txt, which
  asbdiag prints in the DSP section with the attach daemon's last lines.
- asbdiag, DSP: the published output rate/route line says, with dsp_outputs=all, that it is the
  last value published and not the live route.
- asbdiag, lags: SystemUI is the steady jank floor on the OP15 (1.10 janky frames a second in
  every one of 367 screen-on intervals, 65% of the janky frames in quiet intervals) and on the
  CPH2691. Next to the smoothness table asbdiag now lists the status-bar settings found on
  the phone that make SystemUI redraw every second (network speed meter, clock seconds) - the
  first thing to try switching off; not yet confirmed as the cause here.
- CHANGELOG: the fix142 note said ASB writes no ro.* property; it does (short values, see
  there). The conclusion about the FORTIFY crashes is unchanged - and the new logs place that
  wave only on boots with the custom kernel.

**fix144** - a dead governor is restarted; two background jobs that did nothing are gone
- The governor started "asb_reconcile.sh --once" every 2-16 minutes and "asb_watchdog.sh
  --once" every 5-30. Both were no-ops, checked by running them: reconcile's --once break sits
  ahead of its pass, so it left the loop before the first check (and outside service.sh none of
  the helpers the pass calls exist); the watchdog exited on its first line, because
  ASB_GOV_ENABLED is a service.sh variable that never reaches the governor's environment. Two
  shells forked each time for nothing - and the watchdog, scheduled by the process it was
  meant to watch, could never have seen that process die. Both spawns are removed.
- What the watchdog was for now exists: service.sh's housekeeping loop checks the governor's
  pid on its 5-minute tick (read and kill -0, no process started). A clean stop - Stock,
  restore, Smart reset, SIGTERM - removes the pid file, so a pid file whose process is gone is
  a crash; the governor is restarted and the restart logged. Not under Stock, in safe mode or
  with the CPU feature off; at most three restarts in 30 minutes, then one log line and it is
  left alone. Before, a crash kept the last ceilings until a reboot - a LIGHT_IDLE prime cap is
  a sluggish phone, a HEAVY one a warm one.
- The governor's persistent log now says how long after boot each start was and records a
  clean stop; asbdiag counts starts at boot, after a clean stop and after a crash. The tail in
  the 10:35 asbdiag listed twelve starts and could not say which were reboots.
- asbdiag, global uclamp ceiling: "ASB target: profile floor" sat beside 1024 in 23 of 24 field
  reports. With the native governor nothing sets it at boot (the legacy shell policy is skipped
  by design) and the reconcile pass meant to watch it never ran. The line now says so; the
  value is left as the ROM sets it - no field evidence says lowering it helps, and a lower
  ceiling caps every boost that asks the scheduler for a minimum utilisation.

**fix143** - a steady stutter told apart from lag; who held each screen-off phase awake
- UI smoothness: capture 26147 had about 1.5 janky frames a second in every ASB state
  (MODERATE 1.64/s, LIGHT_IDLE 1.44/s, mixed 1.52/s) and at every frame rate (1.46/s under 5
  frames a second, 1.79/s at 20-60) - so LIGHT_IDLE, drawing 3.4 frames a second, read "42.0%
  janky" next to MODERATE's 3.0%. The share counted how few frames there were. The report now
  prints janky/s beside every share (phases, states, the ceiling splits, the app in front, the
  app-by-state table) and the four frame-rate bands; when the quiet intervals miss deadlines
  about as often per second as the busy ones it calls it a steady floor and names the states
  whose high share comes from it. Capture 2830 (fix140's "LIGHT_IDLE 34.8%") had the same
  floor: 1.25/s under 5 frames a second.
- Who draws it: the trace adds the four apps with the most janky frames per interval
  (jank_trace column 17) and the report lists them, names the app behind the floor, and says
  so when one app misses deadlines in nearly every interval whatever is in front. asbdiag reads
  the same per-app counters at its start and again in 7c and prints who drew janky frames while
  it ran. Not proven yet: in the 10:35 asbdiag, two minutes after boot, SystemUI had 133 janky
  frames of 1344 - about one a second - which fits; the next capture will name it.
- Wakelock report, alarms: the list took every "*walarm*:" in the dump - the release of a lock
  counted it twice, and the per-app summary lines came out as two alarms called
  "*job.deadline*: 0 times" and "*job.deadline*: 1 times". Only acquisitions in the history
  count now. "Refused to suspend" listed the summary line as one more device ("...error -16:
  40s 561ms (17 times) realtime"); history only now.
- alarmtimer error -16 is not a driver fault: the kernel's alarmtimer refuses suspend when the
  next wake-up alarm is due within two seconds. In capture 26147 those refusals sat on the same
  history line as the always-on display's HIDE_TIME and Samsung Health's swpedometer alarms.
  The report said "driver-level, no policy can change that"; it now says an alarm was due.
- phase_wakeholders.txt printed batterystats' running totals under each screen-off phase
  ("PowerManagerService 15m 2s" under a two-minute gap) with a header saying they were not the
  phase's - idle phases at 47-64% awake got no culprit. It now prints the time gained inside
  the phase: per app from batterystats' screen-off-only timers since the previous screen-off
  close, per kernel source from /sys/class/wakeup at open and close (the capture's own lock left
  out). The interim report's snapshot of the open phase no longer appends a block (the "gap
  dur=2s awake=100%" entries) or runs two batterystats dumps; a "gap" that lasted minutes is
  labelled idle in its header as in the table.
- Fitness limit after a reboot: OPlus' boot sweep resets the WAKE_LOCK app-op, and the hourly
  screen-off pass was the first to set it again - no sooner than an hour after boot. The 10:35
  asbdiag read "limit lapsed"; in the capture that followed, PedometerLib was held in half the
  screen-off samples, up to 21 minutes at a stretch. The limit is now put back on the first two
  housekeeping ticks (about 5 and 10 minutes after boot) - appops for the fitness apps, nothing
  measured - and an earlier "this Android ignores it" verdict is checked again by the next full
  pass with the op in force.
- asbdiag: "uevents handled: 0 (?)" before the first uevent reads "0".

**fix142** - saving and applying a configuration say what happened; first logs on fix141
- WebUI, saved configurations: "it is not clear whether the backup was saved or applied - the
  window does not close until I close it myself". Saving to a folder left the dialog exactly as
  it was, opening a file only selected it (a toast said "press Apply" for two seconds), and the
  apply answer was a two-second toast. The window itself now turns into the outcome: what was
  written or applied, the name, how many settings (and, on apply, how many it changed), the
  file and folder, what happened to Smart learning, and that a reboot finishes it - with
  Reboot and Done. A clean save closes itself after six seconds with a visible countdown; a
  warning or an error stays until read. A file just opened is marked "checked and added - not
  applied yet" above the list and the Apply button is outlined. An apply whose settings were
  written but whose Smart learning could not be restored was reported as "could not restore"
  - it now says the settings are applied and the learning was kept as it was (13 languages;
  the helper's restore prints keys= and changed=).
- Full-day report written aside and renamed: capture 26147 was zipped at 13:41 while the
  15-minute report rebuild was inside its batterystats dump, and carried a 261-byte report
  that stopped at its first heading. The report, the phase summary and its two companions are
  now written to a .part file and renamed, so a folder taken at any instant holds a whole one.
- fix140 correction: batterystats charges a partial wakelock only on battery with the screen
  off, and the "batterystats disagrees" check compared it with whole holds - capture 26147
  flagged Samsung Health's PedometerLib "21 min held, 367 s counted" for a hold that began with
  the screen on. Only the screen-off part of a hold is compared now, and the "not one app's
  total moved" verdict needs an hour of screen-off time in the window. Capture 2830's verdict
  stands (463 min screen off, AudioMix 20 min in the dark, 0 s counted).
- asbdiag, native crashes: the first listing (fix141) showed eight app processes dying at boot
  with one message, "FORTIFY: memcpy: prevented 99-byte write into 92-byte buffer", none with
  ASB code in the crashing thread. Each crash now names its first frame outside libc - whose
  code asked for the abort - and one message across many processes is called one cause. ASB
  does set ro.* properties - 127 from runtime/asb_managed.props and a few in service.sh and
  post-fs-data.sh (corrected in fix145: this line said it set none) - but every value is 7
  characters or shorter, nowhere near 92 bytes; a 99-byte copy into a 92-byte (PROP_VALUE_MAX)
  buffer points at code reading a long property into a short buffer, which the next asbdiag
  will name.
- asbdiag, DSP library: says whether the installed AIDL library is the fix139 build (re-tunes
  when the output's rate or channels change) or an older one - the byte size was the only clue.
- Action screen and asbdiag, Wi-Fi multicast: "held 207 min - the Wi-Fi radio cannot doze" on
  a phone with Wi-Fi off; the total went 207 -> 337 min in three hours with wlan0 down
  (batterystats keeps counting a held lock). With Wi-Fi off it now says the lock costs nothing.
- Confirmed in the first capture on fix141 (26147, OP15, 3 h, mostly screen on): the recorder
  left the app's cgroups (cgroup_escape=moved:5, all groups at the root); the governor reads
  the zones with the screen on (the last status: temp_age_s=0); the camera guard engaged only
  with Android's display state on; the old idle figure was dropped (offdrain -1, nothing
  skipped yet); the live effect line shows rate=48000 on the Bluetooth output; congestion and
  qdisc for Wi-Fi read "waiting for a link".

**fix141** - a second, file-by-file pass over capture 2830 and the 22:45 asbdiag
- Camera guard with the screen off: all three camera_hold=1 samples of the night had the screen
  off or in always-on doze (23:10:44, 00:42:09, 00:42:55); the earlier OP15 capture and the
  CPH2747 one show the same. A face-unlock burst at a wake that ran past the 5 s unlock window
  armed the 20 s grace, and the guard - uclamp 100 on every tier, all cores open, swappiness 10
  - ran on into the dark. The guard now drops the moment the screen is off, and the camera
  provider is not sampled at all then. With the screen on it works as before.
- Thermal reading at screen-on: deep-idle economy and the quiet-night wake ramp skip the zones
  on the tick that sees the screen come on (they look at the previous tick's screen state).
  The night's last read was at 01:03 (43 C); the 08:02:41 screen-on decided with "t=43degC"
  after seven hours in which the capture's own zone reads were 26-35 C, and the state file
  published 43/34/37 C all night. A screen-on tick now reads the zones when the last reading is
  over a minute old.
- Idle forecast: "простой замерен 1.48 %/ч" on the action screen at 22:47, against 0.59 %/h
  measured over the night that followed. Every screen-off hour counted, and screen-off YouTube
  over Bluetooth (100% awake in this capture) is music, not idle. The governor now reads the kernel's PCM state on
  screen-off ticks and leaves a window with playback (music, a call) out of the idle figure;
  asbdiag shows how many were left out. The stored figure from before this build had music
  mixed in and is dropped once - until the next clean screen-off hour the forecast uses its
  fallback estimate. Where /proc/asound cannot be read, every window counts as before.
- Watchers started from the WebUI: the capture recorded its own cgroups as "cpuset:/top-app
  cpu:/top-app memory:/apps" all night and called that "not_needed" (the pattern wanted
  "/apps/"). The video-refresh watcher, the Wi-Fi fallback watcher and the LTE light-traffic
  loop are started from the WebUI the same way when their switch is turned on: top-app's cores
  and uclamp boost for every wake-up, and on a manager whose WebUI commands run inside the app
  (seen with KernelSU without -Next, fix67) the app freezer and the app's death take them
  along - a video-refresh watcher frozen while it holds the panel at 60 Hz keeps it there until
  the manager is opened again. They, and the recorder, now move to the root groups where the
  boot-started daemons already are (runtime/asb_cgroup.sh).
- Native crashes: the 22:45 asbdiag counted 18 tombstones, the latest about a minute after the
  reboot, and the 17:33 one 3 - counts only. asbdiag now lists the newest crashes with
  process, signal and abort message, and says when ASB code is in one (the crashed process, or the crashing thread's
  backtrace - not the memory map, where every audio HAL lists libasbdsp whatever crashed it).
  The full-day report lists the ones written during the capture. Which processes the 18 were
  is not known from these logs.
- Full-day report: the per-phase cpuT/surfT took the governor's status temperature, which
  deep-idle economy leaves untouched for hours - the sleep row read "cpuT 41 surfT 36". A
  reading older than two minutes is replaced by the capture's own zone reads.
- Wakelock watcher, never restricted: Wickr and Truecaller (installed on the OP15 of this
  capture, matched by nothing), Telegram clients without "telegram" in their id (exteraGram,
  AyuGram, Nekogram, Nagram, Cherrygram) and other "*messenger*" ids, the Samsung wearable
  accessory service, Sony's headphone app, Moovit and other transit apps.
- Governor log: "cooldown: enter (clamping to hw minimum)" - on the OP15 the writer's
  race-to-idle floor holds the night ceilings at 1555/1862 MHz, and the line now says so.

**fix140** - captures and asbdiag: three readings that pointed the wrong way, one dead line
- Full-day report, wakelocks: capture 2830 printed "no app held a partial wakelock for 5 s or
  more" for 9.5 hours in which the live power-manager samples saw YouTube's AudioMix held for
  20 minutes at a stretch. Every batterystats total was the one recorded at the start (AudioMix
  1m 52s at 22:45 and at 08:03, PedometerLib, the kernel wakelocks alike): Android's accounting
  did not move during the capture. A phone in use for hours always adds time somewhere, so an
  all-zero window on battery (no charge row, level down 2+ points - the OP15's status node reads
  "Unknown" while discharging, so the level is the proof) is now named as batterystats not
  updating, not as "no app". The live-holder section checks each app holder seen for 10+ minutes
  against batterystats and says when batterystats counted under half of one continuous hold.
  Settings > Battery usage reads the same counters. Why it stalled on that boot is not known.
- Full-day report, smoothness: "LIGHT_IDLE 34.8% janky, MODERATE 4.1%" read as the light-idle
  state causing jank. YouTube playing untouched was most of LIGHT_IDLE; inside YouTube untouched
  it was 43.8% in LIGHT_IDLE and 42.3% in mixed - about the same, so the app set the share, not the
  state (the earlier OP15 capture 25131: 46.8% and 40.7%). The app with the most frames is now
  broken down by state and touch, so states are compared inside one app.
- Full-day report: "Bluetooth evidence:  is an HFP/SCO audio-link detach" - the two event names
  were in backticks inside double quotes, so the capture ran them as commands on the phone and
  printed nothing. Plain quotes now; the contract fails on a backtick in an echo there.
- asbdiag: "smart minimum: [WARN] ... vendor floor - scmi/walt clamps the minimum" on SM8850,
  where the OP15 read min=384000 (PASS) in another asbdiag and the CPH2747 787200 - a minimum
  raised for a moment by a touch or launch boost (running asbdiag is a touch), not a floor.
  asbdiag now looks again for up to 3 s: back at the lowest OPP is a PASS that says it was a
  short boost; still higher is a NOTE that the platform holds the minimum (a longer boost or a
  vendor floor) and ASB's write is not the limit. The non-SCMI/walt WARN stays.

**fix139** - DSP: the AIDL effect follows a new stream format; the live line shows the rate
- AIDL effect (every phone on libasbdsp_v2/v3 - PLQ110, CPH2769 among testers): the framework hands a
  live instance a new Parameter::common when the session-0 effect follows music to another
  output or that output changes rate or channels. The instance ignored it and kept the format it
  was created with - created at 48 kHz and moved to a 96 kHz output, the 90 Hz bass shelf sat at
  180 Hz and the voice bands (350 Hz / 3.2 kHz) an octave high; moved to a 44.1 kHz Bluetooth
  link, every corner and time constant sat about 8 % low. Whether a given phone ever moves the
  effect between rates was not seen in a capture - nothing showed the rate until this build.
  The legacy effect (OP12) re-reads everything on EFFECT_CMD_SET_CONFIG and was right all along. Now the new format
  is queued on the binder thread and applied at the top of the next process() call, on the audio
  thread, with the gain last pushed over binder kept (not the property, which the vendor HAL may
  not be allowed to read). A settings push and a buffer no longer touch the core at the same
  time: process() takes the core with a try-lock and passes one buffer through untouched in the
  rare instant a push holds it, instead of waiting on the audio thread. AudioFlinger already
  serialises its own calls, so this is a guarantee in the library rather than a fix for an
  observed fault.
- **Needs the library rebuilt** - run the build-dsp-aidl workflow and put the new
  libasbdsp_v2.so / libasbdsp_v3.so in src/DSP_AIDL/prebuilt. Until then the old library keeps
  working exactly as before (the release gate does not require the new "ASB reconfigure"
  literal); asbdiag says when the effect is on an output that is not 48 kHz and the installed
  AIDL library predates this change.
- Live effect line: carries the output thread's sample rate (rate=48000). Input threads are
  skipped: a call's echo canceller and noise suppressor are enabled on capture sessions, which
  the dump lists after the outputs, and they were counted against the last output thread as
  "others_enabled" - an output with no app effect at all could read others_enabled=2 in a call.

**fix138** - smaller things from the same night: network verdicts, MGLRU, card text
- Network: a per-link qdisc (net_qdisc_wifi) whose link was never up printed "no verdict
  recorded yet (apply has not run)" on a phone that applies on every boot and route change.
  The apply ran; Wi-Fi was off. A per-link qdisc or congestion choice with no verdict yet and no
  live link is now filed as "waiting for a link"; a verdict from an earlier link session is kept
  as before. asbdiag's fallback line says what it means.
- MGLRU: the Smart tuner wrote 7 or 5 to /sys/kernel/mm/lru_gen/enabled on every run - dozens a
  day - and the OP15 kernel keeps only bit 0x1 of either (asbdiag after boot: 0x0001). The
  read-back of each request is remembered for the boot and the node is written again only when
  it moved. asbdiag explains the
  bits: "0x0001 (0x7 = fully on)" read as MGLRU half-off; it is on whenever 0x1 is set.
- Captures: every snapshot lists who held Wi-Fi multicast (wakelock_multicast) - the day log
  had 3 h 27 min of it and no name - and whether ASB recorded the avoid-bad-Wi-Fi value or ran
  the fix137 hand-back.
- WebUI: the "Act on Wakelocks" card describes the fix137 rule - ten minutes held or a long lock
  now, not used today, never apps exempted from battery optimisation, mail, navigation or
  keyboards (13 languages).

**fix137** - first night on fix136: what it confirmed, and three things it found
- Confirmed on the OP15 (capture 2830, asbdiag 22:45): the gain's heat rule ("step 0, battery
  35.9 C, cool" - +25 dB held all evening); the live effect line ("AudioOut_7D MIXER ACTIVE
  enabled=y suspended=n", and "released on purpose" on the speaker with outputs=bt);
  net_congestion_wifi "waiting for a link" instead of the false "unsupported"; Signal handed back
  from the restricted bucket on the first watcher pass after midnight; the video refresh no
  longer lowering and restoring in the same second (lowers 30 s - 4 min apart). Night: 409 min
  at 0.59 %/h, 6 % awake. ASB itself: 1077 ms CPU/h, 253 timer wakeups/h, 48 writes/h.
- Wakelock watcher: the same night restricted com.anthropic.claude - one WorkManager job,
  3 m 27 s, while the awake share that opened the gate was Bluetooth audio (bluetooth_timer and
  YouTube AudioMix in 53 % of screen-off samples). Two minutes is where an app gets named, it
  is no longer where it gets restricted: acting needs ten minutes held since the unplug or a
  lock held past the LONG mark right now - JobScheduler already caps a job at ten minutes. An
  app Android itself rates as used today (bucket active or working_set) is never restricted,
  the rule background trimming already follows. Restrictions made under the old rule are handed
  back once (recorded, so it happens once); a later pass restricts again only on new evidence.
- DSP route while nothing plays: the watcher stops asking when no stream runs, so the route
  published while the headphones were on stayed "bt" from 22:46 to 08:00 although the audio
  service was back on the speaker. With outputs=bt the attach daemon held the effect all night;
  the next speaker stream would have started with an enabled global effect - off the offload
  path - and boosted until the watcher caught up. Now one dump a minute into every idle stretch
  (screen on or off, only where the kernel shows PCM state): headphones taken off - usually what
  stopped the music - release the effect; still on Bluetooth, it stays attached and the next
  track resumes boosted at once.
- Full-day report: "sleep ... rmnetMiB 168.7" above "measured screen-off mobile traffic 45.7 MiB"
  - both right: 122.9 MiB moved in the interval in which the morning screen came on, which the
  table counts and the measured line dropped without a word. It is printed apart now ("in the
  interval the screen changed state - the counters cannot place it on either side").
- asbdiag: the avoid-bad-Wi-Fi line says whose value it is - "1 (ASB sets 1 on
  unusable/aggressive)" on the weak rung read as ASB holding it. With no restore record ASB has
  not changed it since fix134: the device's value, or one an earlier build left behind.

**fix136** - Signal is no longer restricted; calmer video refresh; honest network and cap reports
- Wakelock watcher: the OP15 capture of this round carries org.thoughtcrime.securesms in
  wakelock_restricted - Signal, moved to the restricted standby bucket by ASB. Its package id
  has no "signal" in it, so the protected-name list never matched, and a messenger lost timely
  delivery (background trimming meanwhile listed the same package as a messenger to keep
  active - two parts of ASB pulling one app opposite ways). Now:
  - the protected list names messengers, calling and mail apps by their real ids (Signal,
    Molly, Telegram X, WeChat, QQ, Messenger, Skype, Teams, Zoom, Element, Conversations,
    SimpleX, Session, Wire, VK, MAX, TamTam, ICQ, Meet, Gmail, *mail*), plus navigation and
    keyboards; every package background trimming treats as a messenger is covered;
  - an app on Android's battery-optimisation exemption list (the user's own "not optimised"
    choice, or the system's) is never restricted - Signal asks for exactly that at setup;
  - a package an earlier pass restricted that would not be restricted today is put back in the
    active bucket on the next pass, acting or not; asbdiag names every restricted app instead
    of only counting them.
- Video refresh (ltpo_video): the log had "lowered 165 -> 60 Hz ... restored (video_gone)" and
  "... restored (playback_stopped)" in the same second - the lower used a SurfaceFlinger pick
  taken before the 3 s touch-quiet wait, and the first re-check after lowering ran at once.
  A pick older than the quiet wait is re-read before lowering, the audio is checked again, and
  the first re-check comes one interval later. After a touch gave the rate back, the next lower
  waits for 10 s of quiet instead of 3 within the following minute: reading comments under a
  video switched the panel at every pause (319 lowers, 319 touch restores in ~3.5 h), and an
  LTPO panel can show each switch as a short brightness step.
- Network: per-route congctl is decided on evidence. One `ip route change` probe on one route
  decided for the whole kernel; when that route refused, Wi-Fi was filed as "no per-route
  congctl" while asbdiag listed rmnet_data2 with congctl=bbr two sections later. A default route
  already carrying congctl now counts as proof, up to three routes are tried (active link
  first), and a stale "unsupported" on a link that is down becomes "waiting for the link".
  asbdiag says so instead of N/A; the action screen marks a per-link choice that is not
  supported or waits for its link (13 languages).
- Capture cap_verify: a ceiling equal to what ASB asked for was printed as
  "DESYNC_asb_dynamic" whenever Smart's own ceiling differed from the static profile baseline -
  i.e. on every working phone, and the fix130 audit listed it as a defect. It reads
  "ok_asb_dynamic" now; the other DESYNC classes are unchanged.
- Tests: the debug-support stale-lock check waits for the killed recorder to be gone (it failed
  once on a loaded host; never on a device).
- Checked and not changed: wakelock_fitness=limit on OxygenOS 16 - the WAKE_LOCK app-op is reset
  by the system and not enforced (Samsung Health kept PedometerLib 28 min); asbdiag and the
  action screen already say so, and the stronger lever - background restriction - stops the
  app's foreground service and step counting with it. The CPU minimum held at the ceiling in
  one screen-off snapshot is a vendor floor ("kernel_floor_higher"); ASB does not fight it.

**fix135** - the DSP gain no longer sinks when the volume is changed
- Field report: "loudness, gain and voice only work after I open the WebUI; when I change the
  volume the sound sinks and goes flat; open the WebUI again and it is all back". The gain's
  heat back-off (+25 dB -> +12 dB at 55 C, +8 dB at 60 C) was decided from cpu_max_c - the
  hottest CPU core at that instant - and only when the Smart tuner ran: on a CPU heat band
  crossing 50/60 C, an app-tier change or a screen change. Those are exactly the moments the
  core sensor has just spiked (the volume panel animating, a WebView starting), and the answer
  was kept until the next tuner run - opening the WebUI rolled the dice again. The OP15 asbdiag
  of this round shows it on a cool phone: "1200mB (requested 2500) - thermal back-off" with
  skin and battery at 27 C; asbdiag had already counted seven captures with the gain held down
  on a die back under 55 C.
- New rule, one place (runtime/asb_dsp_thermal.sh), used by every gain writer - the WebUI
  apply, the slider fast path, the tuner's mirror and a once-a-minute check in the DSP route
  watcher:
  - battery temperature, which follows the heat of the phone's body and does not jump with a
    burst of UI work;
  - hysteresis: one step (+12 dB max) at 42 C, two (+8 dB max) at 45 C; back to one step under
    43 C, full gain under 40 C;
  - loudspeaker only: on Bluetooth the amplifier is in the headphones, a wired output drives
    milliwatts, and the effect costs the same CPU at +8 dB as at +25 dB - only the speaker's
    amplifier turns more gain into more heat inside the phone. An unknown route counts as the
    speaker;
  - an unreadable temperature never reduces; a cool check costs one sysfs and one file read;
  - a changed gain wakes the attach daemon at once (mirror used to leave it to the 30 s poll).
- The apply path reads the route from the STREAM_MUSIC block like the route watcher does; it
  took the first "Devices:" line of the dump, which belongs to whichever stream is listed first.
- Diagnostics for the other ways the sound goes flat: asbdiag and every audio snapshot of a
  capture now show the live effect - output thread, state, enabled, and whether AudioFlinger
  SUSPENDED it (when any app enables an effect on its own session, global effects on that output
  yield until it is released) - plus the heat decision (step, battery, route, reason). The
  action screen says when the gain is lowered for heat and when the effect is suspended
  (13 languages). The DSP card and governor.conf describe the rule.
- Not changed: the attach daemon and the effect library (prebuilts). A gain push resets the
  bass/voice filters, so nothing re-pushes on a timer - the gain moves only when the decision
  does.

**fix134** - "leave bad Wi-Fi" works on every rung; older backups open; Smart learning optional in a save
- Leave bad Wi-Fi. Field report (OP15 CPH2747, V65-debug6): "it holds the Wi-Fi to the last,
  whatever the setting". It did: the watcher that actually releases a link ran only on
  "aggressive" AND only with the cellular master (radio_policy_enable) on. "weak" - the card's
  "leave below -80 dBm" - never left anything; "unusable" relied on Android's
  network_avoid_bad_wifi, which the card never wrote (only a boot apply did, and boot skipped
  it unless another network tweak was on). Now:
  - weak, unusable and aggressive all run the watcher, with or without the cellular master
    (the master only decides whether mobile data is kept warm in advance);
  - weak watches the signal only; unusable also releases an attachment that validated and
    then lost validation (read every second pass); aggressive reads it every pass;
  - the threshold is read on every pass - a new dBm value no longer needs a reboot;
  - a link the phone keeps coming back to gets a longer release each time (30 s, 60 s ...
    up to 5 min) instead of a flip every 30 s;
  - changing the rung on the card re-applies network settings at once; network_avoid_bad_wifi
    keeps the device's own value in avoid_bad_wifi.prev and gets it back when the rung drops
    below unusable and on uninstall.
- The watcher is cheaper: with the screen off it decides nothing and polls every 30 s instead
  of 8; screen state comes from the governor's state file (fresh within 5 min) instead of
  `dumpsys power` every pass; weak never dumps the Wi-Fi validation state.
- asbdiag / action: "Wi-Fi leave watch (rung, below dBm): status" and the Android switch value.
- Backups: an older multi-file copy (NAME.conf + .sha256 + .smart) still opens on the strict
  path, learning included. A copy that lost its checksum or learning folder, or was renamed
  ("daily (1).conf"), or a pre-V64 asb_settings_backup.conf, used to be refused; it is now read
  line by line: known keys only, inline comments stripped, each value through the current
  validator, a value this build rejects left out and named (skipped_keys=). Not ours: refused.
- Save dialog: when the phone has Smart learning, a choice "with Smart learning" (on by default).
  Without it the profile holds settings only (smart_learning=skipped_by_choice) and a replaced
  profile drops its old learning. Export stays one .asb file either way.
- Checked and NOT changed:
  - Governor timer wakeups (~578/h on the OP15 day). Each costs ~1.3 ms of CPU, ~4 s of CPU an
    hour - about 0.01% of the battery - and none of the timers can wake a sleeping phone (no
    alarm clock). Slower ticks would delay boosts and deep-idle entry (tick-counted logic) for
    no measurable gain, so the cadence stays.
  - The "old_" captures that showed the Wi-Fi complaint are V65-debug6 (built 2026-10-12
    00:59 +07), i.e. before fix131-fix133 - their CPU-ceiling hold lines are already fixed.
  - YouTube jank without touch: 41-48% of frames at 90 Hz, 12-25% at 60 Hz - HWUI overlay
    frames, not the CPU ceiling.

**fix133** - a new CPU ceiling is no longer held back for five minutes; clearer capture reports
- Writer: after three readbacks above ASB's request (a vendor boost holding the minimum up,
  so the ceiling reads back higher) a CPU node backs off for five minutes. That is right for
  the request that was held - it stays in the kernel's QoS set and applies when the boost
  ends - but the back-off also swallowed every OTHER value. Found in four captures:
  PLQ110 in MODERATE with desired 1785600 / requested 1555200 / live 1555200 and the node
  backed off for another 160 s - 43 of its 48 throttle samples were this, labelled "ASB's own
  trim" at 35-40 C; OP15 (cpu_max0 requested 1555200, read back 1996800, backed off); OP12
  (its capture has cpu_max0 backed off after reading back 1132800, and its asbdiag the
  matching gaps: little 1132800 -> 1017600, prime 2035200 -> 1593600, while the second mid
  cluster - written by the extra-cluster path, which has no back-off - did reach 1824000);
  CPH2769 (prime 1382400 read back 2476800). A changed request on a held node is now written at once; the held value still
  waits, and a failing node (holddown, unsupported) still waits. A clean write also ends the
  run of holds - only the already-set path reset it, so after one hold every later hold,
  however far apart, started the back-off at once. asbdiag counts "sent through a vendor
  hold"; state: writer_hold_bypass.
- Full-day report, ASB COST: rates divide by the governor's real uptime instead of whole
  hours (17.9 h counted as 17, a 1.9 h capture as 1). Timer wakeups are split by screen
  state, with the fact an audit missed: the governor's timers have no alarm clock, so none
  of them wakes a sleeping phone (an OP15 day: ~480/h screen on, ~150/h screen off).
- Full-day report, SystemUI restarts: each one gets a verdict line from the crash buffer.
  The block led with the latest crash of ANY system app - a Contacts crash, twice, on an
  OP15 whose SystemUI actually died of SIGSEGV in libart.so (ProfileSaver). Native, Java,
  low-memory kill or "no SystemUI crash recorded".
- DSP reference test: a source-only archive (no src/DSP_AIDL/prebuilt) fails as before,
  unless ASB_DSP_REFERENCE_OPTIONAL=1 is set explicitly - then the static gates still run
  and only the staging half is skipped, with a SKIP line. The release workflow never sets
  it (pinned by a contract).
- Test fixtures build without warnings: path buffer in the thermal fixture, _GNU_SOURCE
  defined once in the Smart session tests, g_asb_appheat_hot marked unused for builds
  without the FSM.
- Checked against the audit and NOT changed: network settings are applied on route events
  (ip monitor), not re-tried every minute - the Wi-Fi "unsupported/not_applied" lines in
  25429 were a link that was down for the whole capture (fix131 already reports "unknown"
  there). Screen-off BT playback runs in DEEP_IDLE (102 of 116 audio_bt samples); the 99%
  awake is the audio path. The release zip already leaves out src, docs, tests and tools.
  Shipped defaults for doze, wakelock/fitness, GNSS, Athena and GMS are stock or protect;
  the aggressive values in that capture are the owner's own choices.

**fix132** - the main cores level with the prime on the PLQ110 too; honest install and BT lines
- Smart main/prime parity (fix130) never engaged on a PLQ110 (SM8750): 153 of 159 screen-on
  samples in its capture had the main ceiling under the prime's, while asbdiag said "not
  needed right now" right under "the prime looks bigger". 40% of its 4320000 prime is 1728000;
  the step under that is 1689600 (39.1%), so the race-to-idle floor takes 1958400 (45%,
  capacity 464), and the main step that matches it, 2227200, is 63% of 3532800 - over the
  60% limit, so the raise was refused. When the level step is over the limit, Smart now takes
  the highest main step inside it if that reaches 90% of the prime's capacity: 1996800 there
  (447 of 464) - the same kHz an OP15 is lifted to. A truly little first cluster, or a prime
  raised well above its floor, still gets nothing. The floor itself is unchanged (fix95).
- asbdiag says which: "held at ... the nearest step inside 60%", or "not raised - level needs
  N kHz, over 60%" instead of "not needed"; a main ceiling within 10% of the prime reads
  "nearly level". State: main_parity_near, main_parity_over_khz. The full-day report gets a
  "within 10% of the prime's" bucket between "level" and "more than 10% below".
- Installer, stock Bluetooth absolute volume (official KernelSU log, OP15): the "BLUETOOTH"
  heading printed with nothing under it. It now says "BT absolute volume: stock (headset and
  phone share one scale)" (13 languages).
- Full-day capture, Bluetooth lifecycle: logcat repeats one profile change 2-3 times within a
  second (a CPH2769 capture: three a2dp_profile_connect rows at 05:29:18), which inflated the
  reconnect counts. The same event within 5 s of the previous one is written once; the raw
  line is still kept, tagged "dup".
- Checked and NOT changed: the OP15 "headphone volume limiter removed" install note sits
  under SYSTEM because it is written by the kernel/settings step; it carries the AUDIO prefix
  and is repeated in the "worth reading" summary. The action screen's battery current scale
  (x0.33 in the OP15 action log, from 72 screen-on windows) is a measurement, shown as such;
  nothing is rescaled by it.

**fix131** - downloads over mobile data keep 5G; the Monitor drain tile shows a figure
- "5G only when needed" held a download on LTE. An OP15 evening (25429) sat on LTE for
  4368 s, 1284 s, 4345 s and 5432 s with the screen on, through a 17-minute download at
  2-7 Mbit/s; its owner reported slow downloads over mobile data. The give-back wanted one
  30 s window over 12 Mbit/s, measured on LTE - which on that cell tops out near 12-15 Mbit/s:
  every give-back in the log sits at 12.3-14.5 Mbit/s. While LTE is held the watcher now
  samples every 10 s, and two windows in a row at 3 Mbit/s or more give 5G back within about
  20 s (one window over 12 Mbit/s still does it at once). The drop to LTE needs traffic under
  2 Mbit/s (was 4), so the two marks no longer overlap.
- "LTE while screen off" switched in the middle of a 5-9 Mbit/s download (21:59 the same
  evening). A screen-off window at 3 Mbit/s or more is a transfer, not a stream: LTE is not
  chosen for it, and once LTE is held the timer keeps watching (monotonic sleep - no wakes
  while suspended) and gives 5G back for at least 10 minutes when a transfer starts. A light
  record kept at screen-off is watched the same way. asbdiag counts both, and both cards
  say so (13 languages).
- Battery profile: the per-CPU receive backlog was 128 packets, a quarter of the kernel's
  own default. With "Spread Network Load" every received packet passes that queue, and a 5G
  burst on capped Battery cores overflowed it into TCP retransmits - a slower download that
  keeps the modem up longer. Now 1000 (the default; an empty queue costs nothing).
- Monitor, Smart card, "Drain": it showed only the measured rate, which needs ten minutes of
  screen-on with the level moving and restarts at every screen-off - so in short everyday
  use it read "measuring..." nearly always, while the action screen printed the governor's
  estimate ("estimate from this hour 10.8 %/h"). The tile now shows that same estimate,
  marked "~", until the measured figure replaces it; "charging" on the charger (13 languages).
- Network verdicts: with no route to probe (early boot, airplane mode) the per-route congctl
  capability is now "unknown" instead of "no" - an OP15 asbdiag printed "[N/A]
  net_congestion_wifi (no per-route congctl)" next to "per-route congctl: SUPPORTED".
- governor.conf: the dsp_loudness comment said 1..18; the range is 1..25 everywhere else.
- Checked and NOT changed: YouTube shows 2-3x more janky frames in LIGHT_IDLE than in
  MODERATE on all three captured phones, but like for like (playback, no touches) the gap
  mostly disappears (OP12 51% vs 54%) - it is the playback overlay, not the ceiling.

**fix130** - everyday work back on the main cores; the capture names who keeps a charging
phone awake
- Smart on 6+2 phones (OnePlus 13 / 15 class). The scheduler sends a task to the cluster with
  more capacity at its CURRENT ceiling, and in light idle and moderate use both clusters sit on
  the 40% race-to-idle floor: on an OP15 the main cores at 1555200 of 3628800 (capacity
  762 -> 327) against the prime at 1862400 of 4608000 (1024 -> 414). The two prime cores then
  look like the bigger cluster and ordinary screen-on work moves to them. An OP15 on
  V65-debug5 had the prime above a quarter of its top clock in 90% of screen-on samples and
  the main cores in 32%; with the main ceiling level with the prime that fell to 14%. Five
  earlier OP15 captures, moderate use with the prime at 1862400: main at 1555200 - prime
  working in 27-100% of samples, 412 mA mean gauge reading; main at 1900800 - 9-36%, 274 mA,
  at similar load and GPU. Smart now raises the main ceiling in light idle and moderate to the
  first step that matches the prime's capacity (1996800 on the OP15; a prime held lower by the
  vendor lowers the target). The prime keeps its floor, nothing else moves. Two clusters only, never
  above 60% of the main cluster's hardware - a phone whose first cluster is truly little never
  qualifies - and not under a thermal cap or a thermal budget trim, with the camera open or in
  a game. A prime burst keeps the level it found. `main_capacity_parity=0` turns it off.
- State file: `main_parity_khz`, `main_parity_lifts`, `main_parity_capacity`;
  `desired_cpu_max0` includes the raise, so the vendor-ceiling log and asbdiag do not read it
  as a leak. asbdiag prints the capacity of both ceilings and which cluster the scheduler sees
  as bigger - that line also works on older builds.
- Full-day report: "SCREEN-ON WORK BY CLUSTER" (the split above, by whether the main ceiling
  was level with the prime) and "LIVE WAKELOCK HOLDERS" from the power-manager samples with
  the screen off. batterystats counts nothing while the phone is plugged in, so a charging
  capture said "charging idle stayed awake - inspect the ranking below" over an empty ranking,
  while every sample showed a proxy app's partial wakelock (held 24 minutes at a stretch) and
  an analytics job holding one for 29.
- WebUI: the UI sounds kept their AudioContext running for the life of the page - an output
  stream rendering silence, with AudioMix held for the root manager's WebView in that capture.
  It is suspended 1.5 s after the last sound (the 10 s saucer holds it) and when the page is
  hidden; the next tap resumes it.

**fix129** - the thermal sensor is trusted once the cores agree, refused settings are not
asked again, and the apply ledger stops costing seconds of boot
- Thermal source confidence. When socd is rejected as "not a temperature" (every OnePlus in
  the captures), a core zone takes over and earns full confidence if it is within 6 C of
  the CPU peers' median - checked once, at discovery, during boot. One prime core 10 C over
  the median at that moment left it at 1/2 for the whole session (OP15 diag two minutes
  after a boot: cpu-1-1-0, confidence 1/2, peers 32..45 C; the boot before had passed), and
  confidence 1 adds a confirmation tick to every load-driven state change: the phone
  ramped up 2-6 s later all day, decided by how busy the boot happened to be. The same
  check now repeats every 30 s on the zones discovery recorded until it passes; a socd that
  reads like a real temperature and disagrees is still a dispute and keeps the tick.
  `thermal_conf_promotions` and asbdiag say when it happened.
- Settings the ROM refuses. network_recommendations_enabled was "write rejected" 16 times
  and cloud_dns_happy_eyeballs_priority_enabled 7 times in the OP15 ledger - three
  `settings` calls each, on every boot and reinforce pass. A refusal (the value did not
  move) is now remembered per ROM build in `settings_rejected` and the next attempt is
  recorded and skipped; a different value, an OTA or a new install tries again. A value
  the ROM stored in another form is not taken for a refusal.
- Apply ledger cost. Every recorded write cleaned its eight fields with `$(printf | tr |
  cut)` - about 25 processes per entry, ~20 ms each even on a desktop CPU - and a boot
  records some 400 entries (357 "already set" in the diag). Fields are cleaned only when
  they contain a separator or a line break, and the trim reuses the entry's timestamp:
  about 6x cheaper, same file format.
- The profile baseline no longer reads a setting from Android when it is already recorded
  (one `settings get` per key per profile apply).

**fix128** - the battery figures show what the phone is actually doing; ASB stops fighting
the user's animation scale
- Monitor (OP15, fix127): "Usual this hour 7.9 %/h" above "2 h 23 m · recent drain 17.1 %/h" -
  two long labels, and neither said how the battery was doing now. The Smart tile is now
  "Drain": the ACTUAL screen-on drain, from the battery level falling over the last ten minutes
  or more ("measuring..." until then). The forecast is built from that same figure first and
  says so in one word - "3 h 34 m · actual"; only without a measurement does it fall back to
  the recent sessions or this hour's history, and then it says "estimate" (the rate is in
  the tooltip). The governor publishes the basis as `forecast_basis` = now | recent | slot;
  the action header and the Smart card print the same time with "(actual 15.4 %/h)" or
  "(estimate ... )". This hour's learned drain stays where it belongs - in the learning
  section of the action sheet. The battery budget Smart acts on is unchanged.
- Animations (field report, OP15 on V64): "Remove animations" set in Android, ASB's
  animation options tried and switched off - and the scale went back to 1.0x again and again,
  through reboots. With UI speed management off, the profile pass restored its saved pre-ASB
  scales on EVERY run whenever the live value differed - and a saved 0.8/0.9 (a profile
  value) was rewritten as 1.0, so the user's own 0 was "corrected" forever. The no-baseline
  cleanup did the same to anyone choosing 0.8 or 0.9 in developer options. Now the restore
  happens once: only if the live scale is still the one ASB wrote (recorded in
  `ux_anim_written`), then the saved file is deleted and the scales are the user's; the
  legacy cleanup runs once (`ux_anim_legacy_checked`); touch timeouts are given back once
  too. An explicit Animation Speed now wins over the profile scale - the author's own diag
  showed anim_speed=3 (0.85x) with the live scale at the profile's 0.9. asbdiag says who owns
  the scales.

**fix127** - V65 pre-release: one battery forecast on every screen, and every drain figure
with its own name
- Monitor printed "Forecast (screen) 5 h 44 m · average" under "Average drain 12.9 %/h", and
  the action sheet "5.7 h at an average drain of 9.4 %/h" beside "this hour usually 12.9 %/h"
  (OP15, fix126). Three different rates - the live window, the smoothed recent drain, this
  hour's history - and two of them were called "average"; each screen also divided by a
  different one. The governor now publishes ONE forecast: the battery budget Smart already
  acts on, with the rate it divided by and where that rate came from (`forecast_rate_x10`,
  `forecast_basis` = recent | slot). The Monitor card, the action header and the Smart card
  all print it the same way - "5 h 51 m · recent drain 9.4 %/h" - and compute minutes with the
  same arithmetic (battery % / rate), so they agree to the minute.
- The names, in all 13 languages: "drain now" (the live window), "recent drain" (what the
  forecast uses), "usual for this hour" (the learned slot). The Monitor tile that showed the
  slot's figure as "Average drain" is now "Usual this hour" with a tooltip; the WebUI
  percent-per-hour unit is localised.
- asbdiag "UI smoothness today": high input latency is a count of events, not a share of
  frames (it read 46.6 % next to 1.2 % janky), and the app list says it is ranked by janky
  frames, with the count.
- Full-day report: the cap ownership verdict now says when the prime sat under a ceiling ASB
  did not write in most samples - the fix126 capture: 88 of 107, the vendor's 1632000.
- Camera: "camera colour on this device is graded from a previous build - install again"
  appeared on every second update (OP15 install logs alternate exactly so). The installer
  runs the baseline saver in the audio section, before it clones the camera files; in the
  fresh staging directory there was no camera copy yet, so the orphan prune deleted the
  stored stock camera baseline, the clone fell back to the live file - the previous build's
  graded overlay, which KernelSU's NoMount cannot take down - and the camera was skipped. A
  stock camera baseline now survives the prune. Because it now lives across installs, it is
  stamped with the ROM build it was taken from and dropped after an OTA, so a new ROM's table
  is never replaced with the old one's.
- Release workflow: optional `prerelease` input (rc1 .. rc99) for a manual run - the release
  flavor under `V65-rcN`, versionCode unchanged.

**fix126** - the prime burst opens only where it can help, and the reports stop blaming the
vendor for ASB's own trims (and vice versa)
- Smart prime escape, two new entry gates. (1) It opens only 3 C or more under the
  sustained-exit mark that closes it: the OP15 fix124 capture has a lift at 46 C and its
  release at 48 C in the same second (Smart exits at 48), the prime sent to 3.13 GHz on a
  rising die and then chased back down. The pinned streak is kept, so the burst opens on the
  first cooler tick. (2) It opens only when the cores are pinned at ASB's OWN ceiling: for the
  last 25 minutes of that capture the prime sat under a 1632000 vendor ceiling against ASB's
  1862400, and lifting ASB's request there changes nothing but costs two writes and a rest
  period. Both refusals are counted (`prime_escape_skip_warm`, `prime_escape_skip_foreign`)
  and shown by asbdiag.
- The governor publishes what it actually wrote (`requested_cpu_max0`,
  `requested_cpu_max_prime` - after the thermal budget and the 40% floor) and the prime's own
  figures on every topology (`prime_slot`, `desired_cpu_max_prime`,
  `effective_cpu_max_prime`). The slot-1 figures were snapped with table index 1, which is
  not slot 1 on a 1+3+2+1 part (OP12, Ace 5); they now use the slot's own policy.
- Full-day capture: throttle rows say per cluster who held the ceiling under the rail -
  `asb_trim` (ASB's own budget trim) or `vendor` (a ceiling ASB did not write) - and the
  report sums them. The fix124 capture called 20 minutes "owner=asb" while the prime was on
  the vendor's 1632000. The prime column is now compared with the prime's own request; it was
  compared with slot 1, a middle cluster on OP12/Ace 5.
- asbdiag: "hardware is stricter than ASB asked" is no longer printed for ASB's own trim (the
  boot diag blamed the vendor for 1670400 -> 1555200, which was surface comfort), and "prime
  ceiling" shows what was written when the 40% race-to-idle floor lifted the stage's wish -
  it read "1017600 (surface_comfort)" while the prime was held at 1862400. On 3+ cluster
  parts it also prints the prime's own desired/effective pair.
- Screen-off is credited to the path that saw it: every screen-off the display-state waiter
  reported was logged as "screen OFF (tick)". `screen_off_detect` in the state file and
  asbdiag now count uevent / display / tick.

**fix125** - one file per saved configuration, a forecast card that fits its text, and
measurements that answer "is the cap causing the stutter"
- A configuration saved to a folder from the WebUI is now ONE file, `NAME.asb`: the
  settings, their checksum and the whole Smart learning payload (buckets, app heat, night
  window, session history) in a compressed archive. It used to be three entries - `NAME.conf`,
  `NAME.conf.sha256` and a `NAME.smart/` folder - and moving one without the others broke the
  copy. Opening a `.asb` lists the archive first and refuses anything that is not exactly one
  profile's files (extra names, a second profile, `..`, links, special files, more than
  32 MiB), unpacks into a private folder that is always removed, and then goes through the
  same checksum and key checks as before. The name comes from inside the archive, so a
  renamed copy opens as what it is. Older three-part copies still open; saving over one
  replaces it only when its `.conf` carries the ASB profile header, so a user's own file of
  the same name is never touched. The file browser lists `.asb`, and the save toast names the
  file actually written.
- MONITOR, "Forecast (screen)": the cells were a fixed 54 px high, so a two-line value such
  as "Typical for this hour" pushed up into the card's own label. The cells now grow with
  their text (min-height) and the label never shrinks.
- Audio: `persist.*` mirrors were written on every tuner call even when unchanged - and each
  `persist.*` set makes init rewrite and fsync `/data/property/persistent_properties`. A value
  that already matches is no longer written; the DSP reads these on ENABLE only.
- Foreground app (fix124 follow-up): the top-app probe answered 190 times against 16 dumpsys
  fallbacks in the OP15 capture. The state file now says why a fallback happened
  (`probe_topapp_empty`, `probe_topapp_ambiguous`), and on a phone where the cgroup answers
  as a rule a miss (lock screen, split screen) serves the last answer for up to 60 s before
  a dumpsys is spent on it.
- Full-day capture, jank trace: three more columns - the share of each interval the main and
  prime cores spent AT the ceiling (from `time_in_state`, not one sample at the end) and the
  app in front. The report splits janky% by that share and by app, and counts HWUI
  "high input latency" as events per screen-on minute: it is counted per event, not per
  frame, so the old "62% of frames" was a unit error. OP15 fix124: janky 4.0% with the main
  cores at their ceiling vs 3.9% without, prime 2.5% vs 4.2% - the caps are not what
  stutters, so prime_escape stays prime-only.
- asbdiag "frames today" printed "no frame counters" on real phones: it kept only the blocks
  whose "Stats since" equalled the newest one, but every process starts its own block when
  it first draws. It now keeps every block from the newest block's UTC day.
- `vendor_ceiling` log lines now carry the writer's status for the leaking node (status, last
  request, hold count, remaining backoff). The capture has one such line 4 s after a
  prime_escape lift and release in the same second, with the prime still on the escape rail;
  the next one will say whether the lowering write was deferred or read back higher.

**fix124** - ASB no longer stalls the app in front to find out which app is in front
- Smart learns which app is in the foreground (games, media, heavy apps), and the first
  source it asked was `dumpsys activity top`. That is not a lookup: for the resumed activity
  Android calls into the app and has it dump its whole view hierarchy - on the app's main
  thread, the one that draws the frames. The pipe closed after one line, but the request was
  already queued, so the UI thread walked every view of the feed or game the user was
  scrolling. OP15 24123: 129 such probes in 64 minutes of screen-on, one every ~30 s (the
  cache TTL), on whatever app was in front - a stutter on a timer, plus a shell, a dumpsys
  and a few hundred KiB of text each time.
- The foreground app now comes from the top-app cpuset/cpuctl group, where Android itself
  puts it: the pids in top-app/cgroup.procs, regular app uids only (no system_server
  threads, no isolated WebView renderers), the package from the process name, and
  oom_score_adj 0 to step past a visible keyboard or a bound service. A handful of small
  file reads, no fork, no binder, nothing asked of the app - cheap enough to ask on every
  refresh, so an app switch is seen sooner than before. Split screen (two apps in front)
  falls back to the dumpsys chain, now without `activity top`: both remaining sources stay
  inside system_server. asbdiag shows how many answers came from the cgroup.
- The current-user poll (multi-user quarantine) ran `cmd user get-current-user` every 6
  ticks with the screen on - every 12-36 s, a fork, an exec and a binder call blocking the
  governor loop. Every 2 minutes now; a switch is still caught at once on a screen-on edge.

**fix123** - MediaTek OnePlus phones: the governor gets its temperature and GPU load
- Every CPU thermal-zone name the governor knew was Qualcomm's (socd, cpu-1-1-*, cpu-0-5-*,
  cpuss-0, cpullc-0, and "cpu-" with a hyphen as the last resort). A Dimensity kernel calls
  the same sensors cpu_big0 / cpu_mid0 / cpu_little0 and adds soc_max; Helio parts have one
  mtktscpu. None matched, so on an MTK OnePlus (Nord CE5, Ace 5 Racing/Ultra, Pad Go) the
  governor ran with no CPU thermal source - temp_valid=0, and every thermal rule, the
  sustained clamp included, stood down. They are recognised now on the same ladder (big
  cores, then mid, then the SoC aggregate, then little), plus ap_ntc as the surface
  fallback. Snapdragon zones keep their priorities; three new fixture cases check MTK, Helio
  and that a Snapdragon table cannot be taken over by a generic cpu_ zone.
- GPU load: a Mali devfreq node has no load file, so the GPU read 0% busy forever on MTK -
  no HEAVY or GAMING from the GPU, a game held on the CPU-only ladder. MediaTek's GED driver
  publishes the busy share (/sys/kernel/ged/hal/gpu_utilization, or the gpu_loading module
  parameter); both are read after the Adreno node.

**fix122** - Screen-off LTE only when there is something to save; mobile data counted on every link
- Screen-off LTE (net_screen_off_lte) switched after 90 s of screen-off whether or not
  anything was moving. An idle phone sits in RRC idle on the LTE anchor - the 5G NSA leg is
  not up and dropping it saves nothing - yet every cycle cost two network-type changes, the
  second at the unlock, where the re-registration is a data stall the user sees. OP15
  24817/24123: 9 of 14 cycles were back on 5G within a minute (2, 4, 6, 12, 16, 33, 39, 45,
  49 s). Each 90 s window is now judged by the mobile data it moved per second of wall time:
  a stream or a download (the case the mode exists for - 47 MiB in 11 minutes) switches at
  once, a phone asleep in a pocket keeps 5G. asbdiag counts the windows that kept it.
- The wake race: the timer sleeps on the monotonic clock, which stops in suspend, so it
  often ran out in the first moments of a wake - usually the user's. "apply" at 18:59:45,
  "screen ON" the same second, "restore" two seconds later. Android's display state is now
  checked first, the switch waits 3 s and asks the power manager again, and a switch the
  screen interrupted is given back at once.
- Governor: mobile data was read from a fixed rmnet_data0..2 + rmnet_ipa0 list. The OP15
  in 24123 moved its internet PDN to rmnet_data3 overnight, and from then on the radio was
  invisible to the DEEP_IDLE download gate, the screen-off radio ticks and the learner's
  radio share; rmnet_ipa0 (the transport underneath) counted part of the traffic twice; and
  MediaTek's ccmni* links were never counted. Every rmnet_data* and ccmni* link is found by
  name now (list refreshed once a minute), ipa0 is left out, and a vanished link cannot make
  the rate negative.
- MediaTek in the scripts: the light-traffic mode (fix114) and the screen-off classifier
  counted rmnet only, so on a Dimensity phone the light mode read 0 kbit/s forever - it
  dropped 5G under any download and never gave it back. ccmni* is counted there too.

**fix121** - Lags become measurable: UI smoothness in the full-day capture and in asbdiag
- Every trace recorded what ASB did (state, ceilings, clocks) and none what the user saw, so
  "it lags" could not be confirmed, located or ruled out. Android already counts it: each
  HWUI app keeps frame statistics in a buffer shared with GraphicsStatsService (frames
  rendered, janky = missed the deadline, slow UI thread, high input latency).
- Full-day capture: new jank_trace.tsv - one row per interval between two screen-on polls,
  the frame deltas of every app (dumpsys graphicsstats, no package detection, nothing
  enabled or reset), tagged with the ASB state at both ends ("mixed" if it changed), whether
  the main and prime clusters sat at the ASB ceiling, and the touch count. The report gets a
  "UI SMOOTHNESS" section: janky% overall, by phase, by ASB state and with/without a cluster
  at the ceiling. That answers the open question from OP15 24817 - the main cores at the cap
  in 52% of screen-on samples: stretched frames, or exactly enough.
- asbdiag (7c): "UI smoothness today" - frames, janky%, slow-UI%, input-latency% for the
  current day and the five apps with the most janky frames. Run right after a lag.
- Games drawing on their own GL/Vulkan surface are not HWUI frames and are not counted.
- Governor: the screen-on comfort trims (Smart's light 9% trim for a warm phone drawing a lot)
  read a single current_now sample - the instantaneous draw of one frame or radio burst.
  OP15 24817, a warm feed: on at 391 mA, off at 258, on at 437, off at 328, on at 384 eight
  seconds later - 13 budget changes in 21 minutes, each a ceiling rewrite, with nothing in
  the workload changing. The gates now read a running mean over ~4 ticks (restarted on the
  charger, with the screen off and after a gap), and a trim in force stays while the draw is
  above 80% of its entry gate and the die within 2 C of its entry temperature - the band the
  surface comfort already had. Entry thresholds are unchanged; the 1800 mA spike
  tie-breaker stays on the raw sample.

**fix120** - The camera is no longer taken for a game; the heartbeat names the right state
- Smart guesses "game" for an app it does not recognise from heat plus GPU load (SUSTAINED
  at 60 C with the GPU at 30%+, or HEAVY at 45%+ with gaming suppressed on battery). A camera
  session matches that exactly - ISP pipeline, HDR merge and preview render. OP15 24817:
  SUSTAINED at 60 C, camera=1 eleven seconds later, and that minute's Smart row carries
  app_hint=4 (game) with the GPU back at 0-6%. A game hint lifts Smart's proactive ceiling,
  relaxes the GPU gate and opens the GAMING entry - the loosest rails, in the hand, for a
  workload that already has its own HEAVY floor and camera QoS. The heat guess is now skipped
  while the camera streams; a package the table names as a game (AR) keeps its hint.
- The 15-minute heartbeat line had its own copy of the state names with GAMING and
  SUSTAINED swapped, so every thermal hold was logged as "state=GAMING" (the same capture:
  "heartbeat: state=GAMING ... gpu=5" between "FSM: SUSTAINED" and "exit_sustained", no
  GAMING transition anywhere). It uses the FSM's table now, and a contract keeps that table
  in the enum's order.

**fix119** - "5G only when needed" for VPN and IPv6-only networks; a pointer to it
- The light-traffic watcher (fix114) decided "on mobile data" from the IPv4 route. Behind a
  VPN that route is tun0, and the fallback read the main routing table - where Android keeps
  no default route (each network has its own table) - so for VPN users the mode never
  engaged. Two of the six field phones run a VPN over mobile data all day (CPH2769, CPH2691).
  It now reads every table: mobile underneath when a cellular default exists and a Wi-Fi one
  does not (with the handover keeping mobile up next to Wi-Fi, Wi-Fi still wins).
- On an IPv6-only mobile network the IPv4 route is the 464XLAT interface (v4-rmnet_dataN):
  read as mobile now, here and in the per-link congestion/route-window classifiers.
- Action screen, Network: with the switch off, on mobile data and 5G allowed, one line says
  what it would do and where it is (13 languages). Silent on Wi-Fi.
- Governor log: the return to the calm cadence after a touch-driven spell (fix117) is logged
  only at the verbose level; at the normal level it filled the 50-line tail the captures keep.

**fix118** - From the first capture on fix117 (OP15 24123): the night gets quieter
- The display-state waiter gave up after ten minutes, and Android creates the property only
  at the first display transition after boot: the phone stayed on for 12 minutes after the
  reboot, the waiter stopped seconds before the property appeared (display_waiter=-1 all
  night, display:0 wakes). It now looks every 30 s for as long as it takes.
- With the waiter live the uevent socket stays parked with the screen off too. It woke the
  governor for every kernel uevent - 162 an hour that night, up to 500 in AOD-heavy hours
  (display 229, power_supply 76, "other" 1096 in one capture) - only to discard them. The
  wake keys keep listening as the backstop and still leave epoll while the screen is on.
  Without the waiter the old behaviour is exact; if it ever goes away the socket comes back.
- A resume that Android reports as off or doze no longer arms the wake re-check chain: 163
  chains in that night, up to four extra governor ticks after each maintenance wake.
- Confirmed working in the capture: the touch watch (40 touches after a calm spell, 8 lifted
  light idle on the spot) took light-idle pin escalations from 51 to 3; screen-on drain
  7.5 %/h active and 4.5 %/h with BT audio; night 0.70 %/h.

**fix117** - A touch on a calm screen is answered at once
- With the screen on, the governor learnt about interaction only from load and GPU sampled
  every 2 s - or 6 s once the screen had been calm - and light idle was left only after two
  ticks agreed. A scroll that started after reading therefore ran up to ~12 s on light-idle
  ceilings; an OP15 day counted 51 escalations out of that state, each one a stretch of
  clipped frames first.
- The touchscreen node (direct-touch, multitouch axes; never grabbed - Android gets every
  event as before) is watched while the screen is on and sampled: after a touch it leaves
  epoll until the next active tick, so a long scroll costs one extra wakeup per tick, not
  one per frame. Touches that arrive while it is out still count.
- The first touch after a calm spell: an immediate tick, the 2 s cadence, and LIGHT_IDLE
  lifted to MODERATE on the spot. While touches continue (and 3 s after the last) the floor
  is MODERATE; leaving it uses the normal down window. Battery profile and the camera path
  are unchanged; with the screen off the panel is not watched (gesture keys stay as before).
- State file touch_watch / touch_starts / touch_lifts; asbdiag prints them.

**fix116** - Every wake is seen the moment the display turns on
- The display uevent misses wakes on some panels and the backups behind it (wake keys, a
  re-check after a resume) miss the rest: OnePlus 15 captures found 6 of 31 and 14 of 35
  wakes only on the next idle tick, the OnePlus 13R 19 of 30 - up to 45 s of unlock and app
  launch on deep-idle ceilings, the "slow right after unlock" users describe.
- A small thread now blocks in __system_property_wait on Android's display state (fix115)
  - a futex, no polling and nothing while the phone sleeps - and wakes the governor only
  when the display enters or leaves ON. The always-on display's doze flips (about one a
  minute) never reach the main loop. A fresh ON is trusted for 3 s while the backlight is
  still dark; after that the panel nodes decide, as before. Resolved with dlsym (the binary
  targets API 24, the call is API 26) and signals stay on the main thread; where it is
  missing nothing starts and the old paths work unchanged.
- screen_on_detect gains "display:N"; the state file says whether the waiter runs and how
  many transitions it delivered, and asbdiag prints both.

**fix115** - An always-on display is a screen that is OFF
- Every OnePlus capture (OP15, 15R, 13, 13R, Ace 5) answered "screen on?" from
  panel0-backlight - the oplus_display nodes are absent. The always-on display keeps that
  backlight lit, so ASB ran screen-ON rails while Android was dozing: an OnePlus 13R spent
  43 minutes of one night (and its whole overnight charge) in LIGHT_IDLE instead of deep
  idle, on the 2-6 s active tick (+394 governor wakeups in that hour), with no quiet night,
  the tuner's screen-on branch and Smart learning those hours as screen time - 247 of its
  379 screen-off samples, sleep phase 64% awake.
- The governor now reads Android's own display state first (debug.tracing.screen_state,
  Display.STATE_*, the property perfetto reads; a shared-memory read, no fork): DOZE and
  DOZE_SUSPEND count as screen-off. Only doze decides and only towards "off"; with the
  property missing, OFF or ON, the panel nodes answer exactly as before, so no phone can
  get screen-off ceilings while it is in someone's hand.
- service.sh's screen check follows the same rule, and no longer trusts the DRM connector's
  "connected" (true whenever a panel exists), which made it answer "on" for good and kept
  the reconcile loop's screen-off battery network profile from ever engaging.
- State file: display_state and screen_aod_s; asbdiag names the source and the AOD minutes;
  full-day captures record wakefulness and the display state per sample and count lit
  screen-off samples, so the next capture shows the fix directly.

**fix114** - "5G only when needed": less modem power with the screen on
- New opt-in switch (WebUI -> Mobile network, `net_lte_light`, live). With the screen on and
  data over the cellular link, a 30 s watcher sums rmnet traffic; after 3 min below 4 Mbit/s
  it removes the NR leg (LTE preferred, same save/verify/restore as screen-off LTE). Above
  12 Mbit/s in one window 5G comes back at once and stays at least 10 min. Not during a call,
  tethering or a game in front; nothing on Wi-Fi. On 5G NSA the phone otherwise keeps two
  radios up for traffic one LTE carrier handles: music, podcasts, chat and maps (the OP15
  capture: BT audio + mobile data, 512 MiB in 80 min = ~0.9 Mbit/s, 12 %/h).
- The tuner calls `screen_on` instead of `restore` on every screen-on tick: it still gives
  back a screen-off record, but keeps a light-traffic one (the plain restore would have undone
  it within minutes - the tuner also runs on app-tier, heat and memory changes).
- Screen off over a light record: kept when the screen-off LTE mode is on, given back
  otherwise. Turning the switch off gives 5G back at once.
- Records carry the reason (`sub|mask|off|light`); two-field records read as screen-off.
  Action screen and asbdiag show which one is active and how often each engaged.
- Removed fix113's `screen_on=` state key: the state file already has `screen=`, and asbdiag's
  plan line now reads that (fallback: `asb status`).

**fix92** - Hang detectors and crash dumps left to the platform
- Ten managed properties removed (applied with resetprop -n, so the platform values are back
  after one reboot): persist.sys.crash_dumps, pstore_dumps, mdlog_dumpback,
  oom_crash_on_watchdog, and persist.sys.stability.nativehang.enable, nativehangII.enable /
  .resume, qcom_hang_task.enable, scout.enable - the system's own native-hang and hung-task
  detectors and the dumps they leave - plus enable_res_leak_abort=true, which turned ON
  aborting on a resource leak. None of them changes power draw; together they mean a stuck
  system stays stuck and records nothing.

**fix91** - Keep the evidence a hang leaves behind
- tombstoned.max_tombstone_count is no longer forced to 0: native crash records were thrown
  away, and tombstoned only writes when something has already crashed, so it saved nothing.
- bg_trim no longer stops minidump/minidump32/minidump64, mtdoopslog (kernel oops log) or
  bootstat (boot reason). They sleep until something goes wrong and are what separates a
  ROM bug from a module bug after the reboot that cleared it. The other debug daemons are
  still stopped as before.
- asbdiag prints the live kernel panic policy (panic / panic_on_oops) and the tombstone
  limit, with a warning when a crash would leave the phone hanging instead of rebooting
  (another module or the kernel may still set 0).

**fix90** - Never wedge a crashed phone; light idle that is not idle
- ASB no longer writes kernel.panic=0 / kernel.panic_on_oops=0. panic=0 means "after a
  panic, never reboot", and panic_on_oops=0 lets the kernel run on after an oops with a
  driver in an undefined state: a crash the phone would have rebooted out of in seconds
  becomes a hang that needs a forced restart. It saves nothing. The OP12 morning report
  (black launcher with only the clock, power key clicks but the screen stays on, alarm
  never rang, a reboot fixed it) is exactly that shape. Vendor values apply from the next
  boot.
- LIGHT_IDLE -> MODERATE when the main cores sit at the light-idle ceiling with the screen
  on: two consecutive pinned ticks (live clock >= 98% of the live limit), held while they
  still run at that ceiling and 20 s after. OP15 day: 169 of 323 screen-on LIGHT_IDLE
  samples (52%) had the six main cores at their 1440 MHz cap - every touch boost clipped -
  while load1 (~7 against a threshold of 14) kept the state down. Not on Battery, not with
  the camera. asbdiag: "light idle -> moderate because the main cores sat at the light-idle
  ceiling: N time(s)".

**fix89** - What the Smart battery bias actually means
- The bias is a share of the remaining way from the learned lean to pure Battery, not a
  target: the action screen showed "lean now 79% (your setting: 60%)" and read like a
  mismatch. Action report (all 12 languages + English) now says "+60% of the remaining way
  to Battery"; the WebUI description (en/ru/uk) gives worked numbers (learned 50% -> 65% at
  300, 80% at 600; from 400 Smart behaves almost like Battery in ordinary use; halved in
  heavy work and games).
- Action report and asbdiag name the commonest screen-off drain ASB cannot fix: a VPN
  interface (tun/wg/ppp) up while rmnet/IPA wakelocks lead the wake sources. A CPH2769 and
  an OP12 that both reported worse battery had an hour of rmnet/IPA wakefulness with a VPN
  app running; the line points at the VPN's keepalive / always-on settings, split
  tunnelling or Wi-Fi at night (all 12 languages).

**fix88** - Findings from an OP15 /data/adb/asb snapshot
- Doze exemption trimming: third-party check is a whole-name match. The substring test let
  the system Gboard (com.google.android.inputmethod.latin) through because a third-party
  fork is named dev.jason.com.google.android.inputmethod.latin. Wearable companions (watch
  plugins, Fitbit/Garmin/Amazfit/Zepp/Huawei/HeyTap health...) and caller-ID / call
  blockers (Truecaller...) are protected like authenticators and the Bluetooth stack; the
  OP15 had com.samsung.wearable.watch7plugin and com.truecaller trimmed. Apps an earlier run
  trimmed that are now protected, on the keep-list, or not user apps are given back.
- GPU pwrlevel cap in profile applies: the "vendor floor" was a one-time snapshot of
  max_pwrlevel (OP15: 9 of 18 - ASB's own earlier write) kept forever and applied to every
  profile, Performance included. The live kgsl thermal_pwrlevel is the limit now; the stale
  file is removed. asbdiag shows "thermal limit=level N" only when one is active.
- Screen-off LTE marks a device unsupported only after three failures in a row. One failed
  read at 01:21 (phone service mid-restart) disabled it until the next reinstall, 18 h later.
- dropbox_max_files 5 -> 50: five entries is minutes of routine traffic, so crash, ANR and
  watchdog records were gone before anyone looked (OP12 hang left nothing to read).
- capabilities.env: dsp_soundfx counts the module's staged library (the probe runs before
  the overlay is mounted - OP15 said 0 with the effect audible).
- Smart sessions get a confidence and signature (were "low"/"mixed" for 500 of 500): judged
  by the battery rules when mostly screen-off, by duration/headroom when mostly screen-on;
  new signature active_burst.

**fix87** - Screen transitions always reach the state file
- The governor rewrote /dev/.asb/state only when it applied caps; in deep idle - write
  backoff, vendor detente, nothing changed - that could be many minutes after the screen
  went off. Shell helpers that read `screen=` from it acted on the stale value: screen-off
  LTE found screen=1 when its 90 s timer fired and silently skipped. OP15 evening: applies
  7, 7.5 and 37 minutes after screen-off instead of 90 s. Every screen transition (uevent
  and tick paths, on and off) now publishes the state file at once.
- Screen-off LTE double-checks with the power manager (mWakefulness Asleep/Dozing) when the
  state file still says the screen is on, so an older or stalled governor cannot block it.

**fix86** - Faster wake detection, screen-off LTE retries
- Wake keys are a screen-on hint. On the OP15 a third of wakes came without a display
  uevent and were found by the display re-check or only by the next idle tick - up to 45 s
  on screen-off rails (GPU 15%, sleep CPU caps) while the phone was being unlocked. Input
  devices that report KEY_POWER or KEY_WAKEUP (no touchscreens: EV_ABS devices are skipped)
  are read, never grabbed, while the screen is off; a press arms the same short re-check
  chain a display event arms, and sysfs still decides. Parked with the uevent socket while
  the screen is on. asbdiag: "wake keys watched: N device(s) · M press(es)".
- Screen-off LTE: an apply skipped for a call or tethering now re-arms every 5 min while
  the screen stays off (max 2 h) instead of giving up. OP15 night: "skipped, call in
  progress" at 03:12, then 5G until 11:10. Only the first skip of a run is logged. The
  timer's sleep is now killed together with the timer on screen-on (no orphan sleeps).

**fix85** - Smart thermal trim on warm-running phones, battery-current scale
- Smart thermal-trend trim (18% / 32% off CPU and GPU ceilings) starts counting at the
  phone's learned warm mark (bucket peak median + 4 C) instead of the fixed 48 C exit mark.
  CPH2769 (normal 45-53 C): prime cut 1248 -> 1018 MHz in HEAVY at 49 C; OP15 (learned
  warm 54 C): eleven 20-34% trims in one evening at 29-37 C skin, several in LIGHT_IDLE.
  Unlearned devices keep the fixed mark.
- Thermal-budget current gates (250/350/450/600/1800 mA) read the battery current on the
  OP15 reference scale. They were tuned on OP15 readings (gauge x0.38 of real drain); a
  CPH2769 gauge reads x0.88, so ordinary use crossed them 2.3x early - 27 comfort trims in
  one evening against 3 on the OP15. Uses the phone's own measured ratio once 5+ windows
  are on record; raw reading before that.
- The Smart top-app uclamp floor added in fix84 is removed again: the governor already
  floors top-app at 50 whenever the screen is on (any profile), so it never changed what was
  written. The 35 seen in the CPH2769 capture was a screen-off value.

**fix84** - Smart after a long screen-off, game SUSTAINED ping-pong, GMS freeze list
- Smart re-blends its rails when its lean actually moves (alpha or interactive bonus by
  50/1000 or more). The slot gate only watched bucket/daypart/confidence/charging/app tier,
  so the screen-off floors (alpha 850, bonus 20) stayed baked into the bounds after wake.
  CPH2769: two hours screen-off, then 30 min of MODERATE at 1267/3322 MHz (main cores) and
  1248/3802 MHz (prime) - pure Battery rails - reported as freezes across the whole UI.
- A busy known game leaves SUSTAINED only 3 C under the entry point (was 1 C), and the
  early trend path no longer pulls it in below the entry point. PLQ110: 20+ GAMING <->
  SUSTAINED round trips in 40 min at 49-52 C, a cap rewrite every ~30 s mid-game.
- gms_freeze: a comment block had been pasted inside the "safe" list's quotes; word
  splitting made ~100 words of it into "components" - two pm calls (JVM starts) each on
  every apply, and junk rows in the state file. List repaired, only GMS component names
  are acted on, old junk rows are dropped on the next apply.
- asbdiag: ro.cutoff_voltage_mv (stock battery shutdown voltage) and other battery/charger/
  radio props no longer count as "external UV" evidence. New "last boot reason" line and
  dropbox counts (system_server watchdog/crash/ANR, tombstones, last_kmsg) for diagnosing a
  hang after the reboot that cleared it.
- Lint: the update.json vs module.prop version comparison is removed (the manifest points
  at the published release and is legitimately behind a test build).

**fix83** - CI: no paid attacher-only runs on push
- "Build DSP attacher only" started on every push touching asb_dsp_attach.cpp. It syncs the
  same Android 16 tree as Build DSP AIDL and runs the same soong analysis on the larger
  runner; the 2026-10-09 run healed three unrelated Android.bp errors and then thrashed
  31 GB RAM + 32 GB swap for 23 minutes until the runner shut down (exit 143). Build DSP
  AIDL already builds asb_dsp_attach in the same invocation, so the attacher-only workflow
  is now manual (workflow_dispatch) only.
- Build DSP AIDL pre-neutralizes the cuttlefish module that references the missing
  "trendy_team_desktop_display", one fewer full analysis pass.

**fix82** - module builds no longer depend on a DSP rebuild being possible
- The AIDL library and the attach daemon need a soong/AOSP build (32 GB+ RAM, 120 GB+
  disk). GitHub's larger runners are Team/Enterprise only, and the standard free runner
  runs out of memory in soong's analysis phase. fix75/fix77 had made the freshness gate
  REQUIRE their new markers, which would have stopped every module build until a rebuild
  was possible. Those two markers are now a build WARNING; the older markers stay hard
  errors. Without the rebuild, voice tone (AIDL phones) and the route release are simply
  absent - asbdiag reports the library as predating them. The legacy library (NDK, built by
  the normal workflow) has voice tone either way.
- build-dsp-aidl / build-dsp-attach can run on a self-hosted runner (free on every plan):
  the "Reclaim disk space" and "Add swap" steps - which delete preinstalled toolchains and
  turn off swap - now run only on GitHub-hosted machines. Point ASB_RUNNER_LABEL at
  "self-hosted".

**fix81** - quoting bugs that blanked diagnostics; the lint can fail a build again
- Inside "$( ... )" quoting starts over, so \"$f\" passes the variable with two literal
  quote characters. Three places did that: asbdiag's "stock thermal" line (empty on every
  field diag - source= zone= trip= ... resolved=C - plus a false "no passive CPU trip was
  confirmed"), and the Wi-Fi fallback status in asbdiag and on the action screen, which ran
  the helper with MODDIR set to a quoted path and always printed "unavailable".
- tools/asb_lint.sh: new check for escaped quotes that start an argument inside $( ); and
  the lint now exits non-zero on an error. It printed "FIX REQUIRED" and exited 0, so CI and
  the full regression stayed green over two real findings this round (the config-shape
  fingerprint not moved for dsp_voice - updated, no stored value changed meaning - and C
  comments in two new test fixtures).

**fix80** - Smart keeps the prime core's floor at its lowest step (OnePlus 12 / Ace 5)
- Smart's minimum is "each cluster's lowest OPP", but the writer skipped any slot whose
  profile floor is 0 - and every profile table has 0 for the prime slot. On a 6+2 part that
  slot does not exist; on a 1+3+2+1 part it is the prime core alone, so its floor was never
  written or repaired. Field OP12 diag: policy7 min=672000 against a lowest step of 480000
  ("smart minimum: WARN"), the only cluster above its lowest step. In Smart below HEAVY the
  prime floor is now the lowest OPP and is put back when something raises it (with the
  writer's existing kernel_floor_higher backoff). Manual profiles and HEAVY/GAMING keep
  their floors as before.

**fix79** - the DSP route follows Bluetooth connecting with the screen off
- The route watcher skipped every pass while the screen was off, so a headset connecting
  in the pocket left the published route on the old output for the whole listening
  session: with a dsp_outputs filter the effect kept boosting the wrong output (or, since
  fix77, stayed released on the one that was selected). With the screen off it now reads
  the kernel's PCM state once a minute (a file read, no binder call, no device wake: the
  sleep does not run in suspend) and runs one normal pass only when the set of running
  playback streams changed.

**fix78** - the DSP costs less CPU per second of music
- The compressor gain is a log10f + powf. It was evaluated on every frame - 48000 times a
  second per stream - although it follows an envelope smoothed over 8 / 180 ms. It is now
  evaluated every 16 frames (0.33 ms) and skipped below the knee, where it is exactly 1; the
  limiter still runs per frame, so the ceiling holds sample-exactly. Host measurement at
  +12 dB on a 60 s music-like signal: 101 -> 45 ms CPU, output difference -55 dB relative.
  On the phone's little cores (no fast log/pow) the saving is larger, and every millisecond
  less per buffer is time the core spends idle during screen-off listening. Both effects
  share the core (legacy and AIDL).
- AIDL effect: the "ASB process" trace logged every 500th buffer - a logcat write every few
  seconds for the whole of every playback, from inside the audio HAL. Now three lines after
  creation and then one a minute.
- Needs the same build-dsp-aidl run as fix75/fix77.

**fix77** - the DSP lets go of outputs it is not set to process
- With dsp_outputs limited (speaker / bt / wired - set on three of the five field phones),
  the attach daemon kept the effect attached on the other outputs and pushed gain 0. That is
  a bit-exact pass-through, but an ENABLED effect on the global mix still counts as
  non-offloadable to the audio policy: music kept off the DSP offload path and the CPU awake
  for every buffer, e.g. Bluetooth listening with the screen off on a speaker-only setting.
  The daemon now releases the effect when the live route is not selected and re-attaches on
  the route-change signal service.sh already sends. Voice-tone edits also trigger a push.
- asbdiag: a released effect off the selected outputs is reported as intended, not as
  "effect registered with audioflinger: FAIL".
- The attach daemon is a prebuilt: rebuild it with the build-dsp-aidl workflow (same run as
  the fix75 library); the freshness gate refuses an older binary.

**fix76** - msm_performance follows the real CPU layout; ASB's own boost cap is not "kernel throttling"
- The HEAVY/GAMING path registers ceilings with msm_performance, a node indexed by CPU. It
  wrote cpus 0-5 with the little cap and 6-7 with the big one - a 6+2 layout. On a 1+3+2+1
  part (OnePlus 12 / Ace 5: 0-1, 2-4, 5-6, 7) that held four mid cores at the LITTLE ceiling
  and the prime at the MID ceiling exactly when the phone was asked to work hard. Each CPU
  now gets its own slot's value (from every policy's related_cpus); an unmanaged slot gets
  the hardware maximum; no topology, no write. 6+2 parts (OP15, OP13) are unchanged.
- The headroom reader took that same node back as "lost headroom": an OP12 capture logged
  "enter_sustained: headroom=34% (perf_cap p0=787200 p6=1075200) - kernel thermal cap
  detected before temp threshold" at 49 C, three times in an hour - hard_clamp, thermal_cap
  and SUSTAINED caused by ASB's own registration. A cap equal to what ASB wrote is now
  skipped (headroom_invalid_reason=own_cap).
- Leaving HEAVY/GAMING releases the registration (hardware maximum) instead of leaving the
  last boost-time ceilings in the node as a second, hidden limit under scaling_max_freq.

**fix75** - DSP Voice Tone
- User report from an Ace 6: with bass at 10 the low end is there, but voices in videos sound
  "much higher than on an iPhone 15 Pro Max - like a squeaker". The 90 Hz bass shelf sits
  mostly below what a phone speaker reproduces; the thin, shrill voice is the 2..5 kHz edge
  over too little 200..600 Hz body. New card dsp_voice (0..10, needs DSP Loudness): two broad
  peaking bands in the shared core, +0.5 dB/step at 350 Hz (Q 0.7) and -0.6 dB/step at
  3.2 kHz (Q 1.0), level 10 = +5 / -6 dB, placed with the bass shelf ahead of the
  compressor and limiter so it cannot clip. Live like the other DSP cards (vendor prop +
  attach-daemon push, no audioserver restart); DSP Outputs keeps it on the speaker only.
  Measured through the real legacy effect: +4.9 dB at 350 Hz, -5.9 dB at 3.2 kHz, 60 Hz
  untouched.
- The AIDL library must be rebuilt (build-dsp-aidl workflow): the freshness gate now
  requires the " voice=" marker, so an older prebuilt stops the build instead of shipping a
  slider that does nothing. asbdiag says whether the installed library supports it.

**fix74** - ASB stops mistaking its own CPU caps for the vendor's; legacy DSP on the shared core
- Every capture from this round (OP15, OP15R, OP12, Ace 5) published cap_source
  "vendor_clamp" on both clusters while scaling_max_freq held exactly what ASB had written
  (OP15 LIGHT_IDLE at 35 C: cpu_max 1440000/1747200, vendor_clamp_1h=424, holddown active;
  logkit cap_verify said asb_dynamic for the same samples). The classifier compared the live
  ceiling with the msm_performance cap, which the writer only uses in HEAVY/GAMING. A ceiling
  equal to ASB's last write is now ASB's. Knock-on fixes: the governor no longer backs off
  from its own writes, the vendor-war anomaly and the thermal veto's clamp count see only
  real clamps, the throttle-owner split and "foreign cap ownership dominated" verdict in the
  full-day report stop blaming the vendor, and cap_detente ("foreign-owned deep idle,
  freezing cap writes", 19 times in one OP15 evening, 159 skipped writes) no longer freezes
  the DEEP_IDLE caps on every screen-off.
- GPU: KGSL clamps max_pwrlevel to min_pwrlevel at write time, so lowering the ceiling past
  the live floor (ceiling 17 written while the floor was 8, then floor 17) left max=8 min=17.
  The override check blamed the vendor and held GPU writes for 15 s - OP15: 323 overrides,
  492 backoffs in an evening. The ceiling is re-asserted once the floor has followed, only
  when the pair is consistent (a vendor floor above our ceiling is still left alone).
- Legacy (HIDL / AELI) DSP effect, i.e. OnePlus 12 / Ace 5 now that fix73 makes the HAL load
  it: runs the shared core (softclip/saturation, bass shelf, bit-exact bypass), reads
  persist.vendor.asb.dsp.* first (the default_prop copy is not readable from the vendor HAL),
  accepts the attach daemon's Loudness Enhancer gain push (including the 0 it sends when the
  live route is not selected), declares the Loudness Enhancer type the daemon creates it by,
  and passes through streams with more channels than the core's state holds. The 16-bit
  softclip path honours ACCUMULATE. Executable test: the real asb_dsp.c driven through AELI.
- Full-day report: kernel wake reasons are also summed by subsystem ("291 hs_uart_wakeup"
  x406 on an OP15R was the Bluetooth chip and a paired watch, not the module).

**fix73** - the DSP reaches the HAL on OnePlus 12 / Ace 5 (SM8650)
- Field OP12 diag: DSP on (+4 dB), library present in /vendor/lib64/soundfx, yet "library
  mapped into the audio HAL: absent" and the capture read "DSP live 0.0%" - stock sound.
  The SM8650 audio HAL is the HIDL one and reads audio_effects.xml; the stock image ships
  /odm/etc/audio_effects.xml (the richer copy with the OEM haptic / music-separation
  effects), which AOSP resolves before every /vendor copy. ASB registered the effect only in
  the /vendor SKU copies and in /odm/etc/audio_effects_config.xml (the AIDL name), so no
  file the HAL reads named the library. A stock Ace 5 dump shows the same picture: the SKU
  copy carries asbdsp, /odm/etc/audio_effects.xml does not.
- The installer now also patches /odm/etc/audio_effects.xml, /vendor/odm/etc/audio_effects.xml
  and the /odm SKU dir of ro.boot.product.vendor.sku, delivered through the same checked
  runtime bind. A registered copy the HAL does not read stays inert.
- Crash fuse: this is the first time that HAL generation loads the library, so for three
  minutes after boot asb_odm_rebind.sh effects-guard watches audioserver and the audio HAL.
  Three or more restarts with an effects config bound -> every effects bind is unmounted and
  dropped from the manifest, audioserver restarts on stock configs, and the flag
  dsp_effects_blocked keeps the next install from registering it again (asbdiag says so
  and how to retry).
- asbdiag names, per file name, the effects config that is FIRST in AOSP's lookup order and
  whether it lists ASB, and the not-attached evidence covers the audio_effects.xml copies.
- asbdiag no longer calls 23 writes over 2 transitions "chattering": fewer than 10
  transitions is reported as too few to judge (the boot pass writes every node once).

**fix72** - Contradicting tweaks can no longer both be on
- WebUI: choosing one side of a real contradiction switches the other side off in the same
  locked write (asb_config_safe set-many), redraws its card and says which one and why.
  Only pairs the runtime already resolves are listed: Audio Profile = EQ-friendly and DSP
  Loudness > 0 (asb_audio_apply.sh turns the DSP off under that profile, so the slider
  showed a gain that was never applied). Picking EQ-friendly sets DSP Loudness to 0;
  raising DSP Loudness under EQ-friendly returns the profile to Stock.
- Dependencies are explained, never auto-enabled: Quiet Radio at Night without Cellular /
  radio controls, Trim Doze Exemptions without Deep Sleep night/aggressive, DSP Bass with
  DSP Loudness at 0, Prime Lift length/pause with Prime Core Lift off. Turning a master off
  under a configured dependent says the dependent now has no effect.

**fix71** - asbdiag names modules that fight ASB over the same properties
- New section "0a0. MODULE OVERLAP": every other enabled module whose system.prop sets a
  property from ASB's managed list, how many, which ones at a different value, and what
  the phone holds now. One audio module seen in the field shares 141 keys with ASB, 16 at other values (codec ABR
  off, Bluetooth sniff intervals, BLE power class, LPA), and its service script deletes
  persist.bluetooth.a2dp_offload.disabled after ASB's boot pass - with both installed the
  boot order decides and a Bluetooth complaint can come from either.

**fix70** - Smart restrains the prime core on 3/4-cluster phones
- On a 1+3+2+1 part (OnePlus 12, Ace 5 class) the prime is a single core in its own slot,
  and nothing in Smart held it: Balanced/Performance leave it unmanaged on purpose, so the
  blend yielded "run to the vendor limit". Field OP12 diag in Smart: "prime ceiling: none
  from ASB", policy7 at 2496000 of 3302400 while little and middle cores sat at 40-57%.
  Smart now caps it as a share of its own maximum, above the middle cores' 58% so it stays
  the fastest core: LIGHT_IDLE with the screen on 55%, MODERATE/HEAVY 62%, SUSTAINED 50%.
  DEEP_IDLE keeps the screen-off prime cap, GAMING and a busy known game are untouched,
  2-cluster parts (OP15/OP13, where slot 1 is the prime) are unchanged.
- HEAVY prime escape can lift that core: where Balanced leaves a slot unmanaged its HEAVY
  rail is the hardware maximum (it computed 0 and never lifted).

**fix69** - video refresh and DSP route watchers stop polling for nothing
- ltpo_video dumped SurfaceFlinger every 10 s during any playback, touched or not. SF
  serves that dump from the thread that composes frames, so an hour of scrolling Reels /
  Shorts - never quiet, nothing ever lowered - paid ~360 dumps exactly where smoothness is
  decided. The touchscreen now has to be quiet for QUIET_S before the dump is considered;
  the peak setting (a `settings` spawn + binder call) is cached for 30 s instead of read on
  every touch; while lowered the content re-check runs every 30 s instead of 15 s
  (playback end, screen off and touch are noticed without it).
- The DSP route watcher (dsp_outputs filter set) dumped the audio service every 30 s with
  the screen on even when nothing played. With the kernel's PCM state unchanged and empty
  it now skips the dump; a stream opening still forces one at once. Kernels without PCM
  state files keep the timed back-off.

**fix68** - fewer governor wakes with the screen on
- The governor listened to every kernel uevent all the time. A field OP15 capture: 29298
  display uevents in ~7 h (brightness / refresh / DRM chatter, ~1.1 per second), each an
  epoll wake plus a sysfs read of the panel - 37735 event wakes against ~3800 active ticks.
  The socket is only needed to catch the screen turning ON, so it is now taken out of epoll
  while the screen is on (the active tick watches the panel then) and put back, with the
  queue dropped, by the tick that sees the screen go off.
- That tick now runs the screen-off work the uevent path runs (stats save, screen-off
  session plan and prearm); before, a screen-off seen first by a tick skipped it.
- asbdiag: uevents handled / skipped while the screen was on; the "screen wakes found by
  the idle tick" warning is a share (over 10 %), not an absolute count - 5 of 201 wakes
  over a day is an AOD/pocket wake, not a ROM without display events.
- asbdiag: when the DSP is on but not attached, it now lists which effects configs name
  ASB, the library's SELinux label, and the HAL's own log lines about loading it.

**fix67** - captures that survive, a call is not a song, limits that are checked
- Full-day capture stopped after ~10 minutes on KernelSU (non-Next) while the user kept it
  "running" for hours: a recorder started from the WebUI stays in the manager app's cgroup,
  which Android freezes or kills with the app. The recorder now moves itself to the root
  cgroups at start (v2, /acct, v1 freezer) and records where it ended up
  (`_recorder_cgroup.txt`).
- Bluetooth "reconnect" while listening: the capture showed the headset switched to
  bt_sco (the call link, HFP) at that moment with media playing - an app opened a voice
  channel. The logkit printed that as route=none; it is now `bt_sco` with the audio mode and
  its owner. The DSP route publishers called SCO "bt", so a Bluetooth music boost (+25 dB
  in that config) processed whatever reached the mix during a call; SCO is now route
  `call`, which no dsp_outputs filter names.
- SystemUI restarts are recorded during a capture (one pidof per poll); on a PID change the
  dropbox crash/ANR/native-crash entries and the crash log are saved to
  `sysui_restarts.txt`, and the report lists them.
- wakelock_fitness=limit is verified: a lock PowerManager still honours (LONG, not
  DISABLED) after the op was set is reported as `limit_ignored` - the field capture had
  Samsung Health holding PedometerLib 17 minutes after "limited". DISABLED locks no longer
  count as holders.
- Camera payload: the installer strips // comments from the module-root camera copy too
  (it came back unstripped through asb_normalize_module_layout); the boot-time payload
  sync strips them on the way.

**fix66** - the bound tone table is the graded one
- fix65 settled it: the bind works, init's namespace reads the payload - and the payload
  was the stock table (BlendWeight 0.35, 0.5, 0.7) while the module's own copy was graded
  (1, 1, 1). The payload was written once at install and never refreshed.
  `asb_odm_rebind.sh` now syncs every camera payload from the module copy before binding
  (in place, so an existing bind updates too; unbalanced JSON is refused and logged), and a
  change under an existing bind restarts the camera stack at boot like a new bind does.
- The module copy itself is now re-graded at every boot (post-fs-data) from the stock
  baseline with the current settings, so WebUI camera changes reach the camera after the
  reboot the card asks for. Before, only the system/ variants were re-graded - files this
  phone never reads.
- Baselines: the install's dynamic pass force-saved the camera "baseline" right after the
  installer had graded the file, so boot passes graded a graded table. Camera baselines are
  saved only when absent and only from a file with the stock chroma matrix; a graded one is
  dropped and stock is captured again. Module-root and system/ copies share one baseline
  name, from the staging dir and the installed module alike (the root copy's baseline used
  to embed the module path: never found at boot, pruned on the next install).
- The install-time dynamic pass reads camera settings from the running module's config,
  not the staging dir's shipped one.

**fix65** - camera judged where the camera reads it
- fix64 field result: retouch list live (19 apps) and the tone table bound in init's
  namespace (`result=ok`, read-back = payload), yet action/asbdiag still read stock values.
  They read /odm from their own su namespace, where a bind made later in init's never
  appears. action, asbdiag and the WebUI camera badge now read the camera files through
  init's namespace (the camera HAL's), asbdiag says when the two views differ and prints
  the bind payload's BlendWeight.
- A camera file newly bound at boot restarts the running camera provider and cameraserver
  once, so a HAL that read the table at start picks up the graded one (boot passes only;
  the action screen never restarts anything; nothing changed = nothing restarted).

**fix64** - camera binds checked, not assumed
- Camera tweaks did nothing on a OnePlus 15 (V65-debug4): the boot log said
  `odm_bind_late result=applied`, yet init's namespace read the stock retouch list (4 apps,
  payload 19) and the stock tone table. "Applied" meant "some mount in the manifest returned
  0" - the audio effects bind did, the camera ones did not reach the camera.
  `runtime/asb_odm_rebind.sh` now binds each line, reads it back through init's namespace,
  peels a stale layer on that exact path once and binds again, and logs a verdict per file
  (`ok / already / retry_ok / hidden / failed / missing`, a hidden one with its mountinfo).
- A second camera-only pass runs a minute after boot_completed (a root-manager layer added
  at its own late stage can land in front of the first bind); the action screen re-applies
  a camera bind that is not live before reporting.
- The installer queues every staged camera payload, with no comparison against the live
  file: what that path shows mid-install (stock, the old bind, a layer just taken down)
  says nothing about the next boot, and both guesses so far cost the camera its payload.
- asbdiag: per-file read-back, every mount layer on the camera paths, the module's own
  copies (apps / BlendWeight), the metamodule id; the "tone keys in live file" lines read
  conf_tuning_params.json (they read the retouch list and were always empty).

**fix63** - more mksh evidence (asbdiag, action and the runtime scripts executed under a built mksh)
- Wi-Fi power save never applied: the Smart tuner called `_cfg`, which it never defined, so
  `wifi_powersave` read as empty. Defined; a contract test now checks every `_helper` call in
  device scripts. action says when the ROM has no `iw` to apply the setting at all.
- `: > file` is a special builtin: when the redirect fails (a missing dir, /sdcard not yet
  mounted) mksh and POSIX shells abort the whole script - asbdiag died on its first line on a
  host without /sdcard. 42 sites now use `true > file`, which only fails the command.

**fix62**
- Same awake-time trap in the aggressive background-trim pass ("every 6 h" was `sleep 21600`,
  i.e. days on a phone that sleeps well): now gated on the wall clock, checked every 10 min
  of awake time. The governor watchdog's screen-off wait drops from 1800 to 600 s - the long
  wait saved no wakeups (sleep never wakes the phone) and only delayed noticing a dead
  governor after the user picked the phone up.

**fix61**
- The screen-off maintenance pass (wakelock watcher, screen-off classifier, GNSS trim, plus
  the 30-min watchdogs) waited with `sleep 1800`, which counts only awake time: on a phone
  that sleeps well (4 % awake overnight) a "30 min" pass took ~12 h, so none of it ran at
  night - the 27846 night capture has an empty screen-off class trace and the fitness limit
  set at 00:53 never got its pass. It now wakes every 5 min of awake time and gates on the
  wall clock: watchdogs every 30 min, the screen-off pass at most hourly, at the first wake
  after the hour.

**fix60**
- "Camera colour on the device was graded by a previous build - skipping it" repeated on
  every install: the graded file the installer saw was ASB's own odm bind, re-applied on
  every boot, so the advised "reboot and install again" met it again. The installer now
  takes that bind down (it would not survive the post-install reboot anyway) and checks the
  partition's real file, so the stock baseline is captured. If the file is still graded the
  advice now reads: disable ASB in the root manager, reboot, install again (13 languages).

**fix59**
- action no longer says "5G allowed (screen is on)" by assumption: it asks the modem
  (`asb_lte_screenoff.sh nr`, the same parser restore uses) and says plainly when 5G is
  not allowed and ASB holds no record of removing it. asbdiag uses the same check.

**fix58** - mksh arithmetic is 32-bit
- Android's sh (mksh) does 32-bit signed arithmetic: `$((2147483647+1))` is negative and
  `[ 3000000000 -gt 2000000000 ]` is false. Fixed where values pass 2^31: the screen-off
  class summed rmnet rx bytes and stopped detecting "network" after 2 GiB since boot; the
  logkit mobile-bytes sums and per-phase deltas; the action route-traffic line; the opt-in
  zram rebuild (8 GiB never matched, so it rebuilt every boot); the BDP window product above
  ~286 Mbit/s; the free-memory share on 24 GB phones; the boot timing. Byte math goes
  through awk; a contract test guards the known sites.

**fix57** - Android's shell (mksh) - verified against a built mksh R59
- A bare `|` inside `${var#pat}` / `${var%pat}` is an alternation in mksh:
  `${l%%|*}` on "0|916479" gives "" and `${l#*|}` gives the whole string. Host shells
  split as expected, so every host test passed. 34 sites fixed (`\|`), among them: the
  screen-off LTE restore (root cause of fix56), the retouch-app injector (with "" as the
  package every app counted as present, so nothing was added when it ran under mksh),
  GNSS-trim and uninstall restores, the phantom-process stock restore, the Wi-Fi fallback
  expiry and the DSP ABI selector. A contract test now rejects the pattern.
- `( ...$(...)... ) >/dev/null 2>&1 &` does not release the caller's stdout under mksh, so
  the WebUI's "collect diag" waited for the whole export (1066 ms vs 19 ms under dash for
  a 1 s fake export). Background bodies now detach with `exec` inside the subshell
  (asbdiag async start, video-refresh touch guard, LTE arm timer, uninstall waiters).

**fix56**
- Screen-off LTE never gave 5G back: every restore since 10-06 logged "bad save file
  dropped" right after an apply that wrote a well-formed record, and deleted the record,
  so the modem stayed without NR with the screen on (and after reboots - the setting is
  persistent). The record is now read with IFS; an unreadable one still returns the NR
  bit on the current mask; a phone whose earlier restore dropped its record gets 5G back
  once. asbdiag shows whether 5G is allowed right now and the last restore lines.

**fix55** (from the OP15 night capture 27846: 0.49 %/h, 4 % awake)
- Fitness wakelock limit now applies to the installed step/fitness apps when chosen. It
  waited to see a hold, and the OP15 batterystats dump carries no per-app durations - the
  pedometer held the CPU for 35 min after the switch was set and was never limited.
  asbdiag shows, per limited app, the app-op as Android reads it and whether its held
  locks are marked DISABLED.
- Screen-off tick on CLOCK_BOOTTIME: it never wakes the phone, but after a suspend the
  first resume delivers it at once (CLOCK_MONOTONIC stalled through suspend, so a 07:12
  wake was found up to 45 s of awake time later). A tick right after a resume with the
  screen still off runs the short re-check chain (no wakelock held).
- Captures record the watchers' own state files (wakelock list, fitness limits, video
  refresh counters, screen-on detection) in every snapshot.

**fix54**
- Camera retouch list fell back to stock (4 apps instead of 19) after reinstalling over a
  running module: the installer skipped queuing a camera bind whose payload equalled the
  live file - but the live file was the previous build's own bind. Equality now skips only
  when the live path is not a mount point. asbdiag shows each camera bind (payload app
  count, mounted in init's namespace, what init's namespace reads) and the last bind log lines.

**fix53**
- The full-day capture no longer runs `dumpsys batterystats --reset` (at start and every
  hour). That wiped the phone's own battery-usage history for the whole capture and cut
  the wakelock watcher's "since unplug" window to under an hour - during night captures,
  when it matters most. Per-app wakelock time is now a difference against a baseline taken
  at the start ("during this capture"); `ASB_LK_BSTATS_RESET=1` restores the old behaviour.

**fix52**
- Hour-of-week learner: predicted from milliamps against 30/70 mA bars no real hour meets
  (awake-only samples; an OP15 night hour read 502 mA) - every slot would have become
  ACTIVE. It now predicts from screen-on share, and no prediction slows a ramp-up below the
  FSM default of 2 ticks (the idle row used to wait 5, the light row 3).
- learn.bin, per-profile pstats, session_stats.json and the OTA-quarantine fingerprint
  lived in the module directory and were wiped by every update (the quarantine therefore
  never fired, and the learning reset deleted paths where nothing was). They now live in
  /data/adb/asb, with a one-time read of the old location.

**fix51**
- Quiet Night now runs at night on every profile. It required a "battery-like" profile, and
  Smart only counts as one while its learned battery weight is >= 0.8: a full OP15 night on
  Smart (weight 0.45-0.79) never entered it, while two daytime screen-offs did. Inside the
  night window (learned or static hours) with `night_quiet_enable=1`, any profile is
  eligible; outside it the old rule is unchanged.

**fix50**
- Screen wake detection: 22 of 54 wakes in two OP15 captures were noticed only by the 45 s
  idle tick (deep-idle rails and frozen cap writes while the phone was in use - one of them
  an unlock straight into the camera). A display event inside the 30 s follow-up budget now
  still arms one single re-check 1 s later (spaced >= 10 s, never a chain). How each wake
  was noticed is published (`screen_on_detect=uevent/recheck/tick`) and shown in asbdiag.

**fix49**
- Video-refresh card shows what the watcher is doing ("now 60 Hz", on, not running), not
  just the stored toggle; action and the full-day report print its counters.
- The watcher reads the current peak before the SurfaceFlinger dump and skips the dump when
  nothing lower is possible; the half-hourly service pass restarts a dead watcher and
  repairs a peak it left lowered.

**Diagnostics (fix47)**
- LTE screen-off applies/restores/minutes, total prime-lift seconds, a warning when a
  device-bounds override loads nothing.

**Lighter**
- DSP route watcher: adaptive 5 -> 30 s back-off, pulled forward by `/proc/asound` PCM state
  instead of a `dumpsys audio` every 5 s.
- WebUI stops polling while hidden.

**Measured, not assumed**
- Screen-off drain (`offdrain_pctph_x100`) and the battery-current gauge scale
  (`current_scale_x100`) are measured per device. OP15 `current_now` reads ~0.5 of the
  SOC-derived drain; OP12 reads ~1.0 - milliamp thresholds are not yet rescaled.
- Logkit: per-app wakelock time, current/SOC consistency per phase type, policy-agnostic
  prime frequency, empty snapshot sections fixed.

**Build hygiene**
- Native strict warnings 80 -> 61 (explicit casts on read/write/recv); host regression no
  longer hard-codes clang.
