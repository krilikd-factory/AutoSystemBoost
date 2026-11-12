# AutoSystemBoost — V66 build history

Build-by-build notes of the V66 line, newest first. The V65 release summary stays in
[`CHANGELOG.md`](../CHANGELOG.md) until V66 is released; the V65 line is in
[`V65_BUILD_HISTORY.md`](V65_BUILD_HISTORY.md).

## V66 dev20 - the kernel page reads the kernel, an honest video-refresh count, a correct sensor after boot

Input: an 11 h 11 min capture with a night, active use and seven reboots in 25 minutes at the
end, plus the device, Zygisk, report and asbdiag exports, on the owner's new kernel
(6.12.69-android16-6-krilikd, with VPN Hide and USB Arsenal built in).

- **Kernel configuration was never read on a phone.** Every device export since the page
  existed (stock, Wild and this kernel; six exports checked) said `/proc/config.gz: yes` and
  listed not one `CONFIG_` line, so LTO, BTF, BPF, NTSync, BBG, the Droidspaces namespaces and
  the kernel's origin all fell back to "unknown" or "missing". Cause: a GKI config is
  200-300 KB decompressed, Android's shell has no `printf` builtin, and the kernel refuses a
  single argument over 128 KB, so every `printf "$config" | sed` lookup got nothing. A host
  shell's builtin `printf` hid it from the tests. Now the collector keeps only the whitelisted
  lines in one pass, checks that the decoder really produced a kernel config (else tries the
  next one), and reports how many options it read and with what.
- **New kernel features on the device page**, read-only, from the configuration and sysfs:
  VPN Hide (built-in, network only or network and filesystem), USB Arsenal's gadget functions
  (mass storage, HID, NCM, NAT), BBRv3, WireGuard, CAKE, OverlayFS, CIFS/SMB and IP sets.
  ASB does not switch any of them.
- **Video refresh lowering counted no-ops.** The capture's log had "lowered peak 60.0 -> 60 Hz":
  the watcher caches the peak setting for 30 s, another writer had already set 60 Hz, and the
  lower still counted, logged and armed a touch guard. It now re-reads the peak under the
  lock and does nothing when it is already at or below the target. The report's "5 times ·
  0 min" was the watcher's lifetime counter shown in the table of numbers measured in this
  capture; the logger now records the counters at capture start, the table shows only this
  capture's delta, and the lifetime figure is labelled as such.
- **The wrong temperature source for the first minute after boot.** After the reboots the
  governor started on `socd` in one session ("cpu=socd ... 46C") while the cores read 80 C,
  and switched only at the next rescan a minute later. On these phones `socd` is a percentage,
  not degrees; the existing scale check needed three readable core zones, and right after boot
  fewer exist. Now a percentage `socd` is rejected whenever the board, skin or surface zone of
  the same pass reports millidegrees and a live core zone can take over, and while the source is
  still provisional in the first five minutes the zones are rescanned every 10 s instead of 60 s.
  The heat after those boots itself came from Android's start-up work (load average 35-53) on
  a phone rebooted seven times in 25 minutes; the governor's own start cost 109 ms of CPU.
- **Checked and left alone**, with the reason: SystemUI's late frames on unlock come with three
  LSPosed modules loaded into it (the report already names them); the prime cluster was held by
  the firmware in 10 of 17 checks, which ASB does not override; the night (0.3 %/h, deep sleep
  96 %) and ASB's own cost (2046 ms CPU per hour) need nothing; the memory-bus lab has one
  comparison pair and keeps testing.

Native code changed (`src/asb_metrics.h`): the governor needs a CI rebuild.

## V66 dev19 - Home cards the right height from the first frame

Input: the owner's two screenshots of Home on an OP15, nine seconds apart: just after opening
the profile cards were taller, the last one running under the tab bar; later they were back
to normal.

- **Cause.** The tab bar's markup comes after the main script. The locale file is requested
  at the top of the page and can arrive while the parser is still on that script, so the
  Home reveal ran before the bar existed. Its fit found no bar, measured down to the window
  bottom and gave each of the five cards a fifth of the bar's height too much; a later fit
  put them right. A fit queued before the reveal could also run inside the entrance
  animation and measure its scale (a 1 px change on small screens).
- **Fix.** Home is revealed and fitted once the document is parsed (it stays hidden until
  then, as before); a fit that finds no bar while the page is still loading waits for it; a
  queued fit re-checks for a transition that started in the meantime. In Chromium at
  424x924 the cards were 100 px for the first moments and then 86 px; now they are 86 px from
  the first frame, and on 360x640, 412x760, 424x924 and 800x1280 the card size is set exactly
  once. On a small screen the compact header tier is now also set at the first frame; before,
  it switched on about half a second after Home appeared. Home still appears about 150 ms
  after loading starts, as before.

No native code changed: no CI rebuild needed.

## V66 dev18 - one sphere from the preview to the header, a Battery Fix you can follow

Input: the owner found the Battery Fix silent (no way to tell whether the recompile ran or the
fix worked), the Infirmary button unfinished, the preview hand-off late and jerky with the
saucer shown twice, and asked for the preview's spinning sphere to become the header.

- **The header is the preview's sphere.** All six page headers now carry the same sphere as
  the boot preview: two counter-rotating shells (7 s and 10 s) with their marker dots, the two
  square frames, the pulsing pod and the saucer. Both are drawn from one geometry (172 px times
  a scale), so the header is the preview sphere at a smaller scale, set per size tier (phone,
  tablet, compact, very compact, landscape). The old glow and ring layers are gone. Closed and
  backgrounded pages pause the new layers like the old ones; the ten-second idle rule still
  pauses only the wordmark sweep. Reduced motion stops the spin, forced colours draw outlines.
- **Hand-off rebuilt.** Causes of the dev17 jerk and double saucer, as found in the code:
  - the flight animated the orbit spheres with their own transforms, which replaced their CSS
    rotation, so they snapped to a new angle at the start and again at the end;
  - the pod's pulse was switched off for the flight;
  - the overlay's full-screen background faded by a colour transition (a repaint per frame) and
    only at the end, so the home screen appeared late;
  - the flight was cancelled before the overlay was hidden, so for a frame the saucer jumped
    back to the centre while the header copy was already visible: the doubled saucer.

  Now the sphere flies as one block on a curved transform-only path (1.15 s), its shells keep
  their CSS spin and the pod keeps its pulse. The backdrop is its own layer and fades by
  opacity from the first frames of the flight, so the home screen forms under the sphere
  instead of after it. It lands exactly on the header sphere; their rotation phase is handed
  over and the two cross-fade in place (0.22 s). Every end state is held until the overlay is
  hidden. Reduced motion, a missing piece or a header out of view fall back to the old fade.
  Checked frame by frame in headless Chromium; not timed on a phone.
- **Infirmary button.** A green glass button with a pharmacy-cross emblem in a slightly wider
  fourth column. The light and Glass themes restyled every action button with `!important`,
  which turned it into a plain white button there; it now keeps its own paint in dark, light
  and both Glass themes. Its accessible name is the localized label (it was a fixed English
  `aria-label`). The Infirmary screen opens with a header card.
- **Battery Fix you can follow.** dev17 started one `cmd package compile ... -a` for all apps in
  the background with its output discarded, so nothing could say whether it ran, how far it
  was or whether it finished. Now:
  - ASB runs the recompile itself, one app at a time (`cmd package compile -m speed-profile
    -f <app>`; an app counts as done only when the command answers "Success"), and records
    total, done, succeeded, failed, the current app and the start/end time. One run at a time;
    Stop ends it after the current app; a run cut by a reboot or a dead worker shows as
    interrupted; an unreadable app list shows as failed. The background dexopt job still runs
    at the end. A lock left by a reboot mid-run is cleared at boot.
  - The card is a three-step checklist under one status chip: the condition (charge level and
    charger), the recompile (n of total, failures, an estimate of the minutes left, the app
    being compiled, a progress bar, then the result and how long it took) and the statistics
    reset (scheduled, then when it ran, how many of the three files were removed and whether
    Android has written a new record since). The button follows the state: Run, Stop while
    compiling, Reboot to finish while the reset is pending; a pending reset can still be
    cancelled. The card refreshes every 2 s while compiling and every 8 s otherwise, only while
    it is on screen.
  - The description says plainly what each step does; it still claims no capacity or runtime.
- **Texts.** 31 new strings and 2 rewritten ones in all 13 languages; 6 strings of the old
  card removed.
- **Shell comments.** dev17 added comment blocks to module shell code (the Battery Fix
  runtime, `post-fs-data.sh`, `uninstall.sh`, the LTPO apply script); they are removed.

No native code changed: no CI rebuild needed.

## V66 dev17 - no idle freeze, the saucer flies into the header, the Infirmary

- **WebUI no longer freezes after ten seconds.** The dev6 "calm" rule stopped every
  decorative loop ten seconds after the last touch, the header logo and the status/record/
  charge/link indicators included, so the open interface looked hung until it was tapped. On
  the page in front the logo glow and ring (composited rotations) and the indicator dots now
  keep moving; only the wordmark's specular sweep, which repaints its text every frame and was
  the measured cost behind the rule, still pauses while idle. Closed and backgrounded pages
  stop everything as before.
- **Boot preview hands off into the header.** At the end of the once-per-boot preview the
  saucer flies a wobbling, shrinking arc into the header logo, the orbit spheres lift toward
  the header and dissolve, and the overlay turns transparent so the home screen forms under
  it; the header logo pops in on landing. Transform/opacity only; reduced motion and any
  missing piece fall back to the old fade.
- **Panel Maximum on Touch.** The OP15's own display dump lists 60/90/120/144/165 Hz and
  nothing above, so 165 is the ceiling there; a rate the panel does not list cannot be
  selected and ASB does not invent one. The tweak still asks for the highest listed mode, and
  now also unlocks OnePlus's own extreme-refresh availability globals
  (`oost_settings_unlock_refresh_rate`, `oost_extreme_refresh_165`) so that mode is reachable
  past the ROM's 120 Hz app cap. It never writes a force-always-high key, so the panel still
  drops on idle. Values found are recorded and restored on Off, master Off or uninstall.
  Effect not measured on device.
- **Infirmary.** A pharmacy button right of Reset opens a separate Infirmary screen (not a
  seventh hub tile). It holds:
  - **Battery Fix**, offered only at 100% on a charger. It arms a one-shot that deletes
    `batterystats.bin`, `batterystats-checkin.bin` and `batterystats-daily.xml` from
    `/data/system` at post-fs-data on the next boot, and starts an in-place speed-profile
    recompile with the background dexopt job. Unlike a wipe-and-recompile it does not delete
    dalvik-cache or `.odex/.art`. This resets Android's usage record and learned estimate; it
    adds no capacity or runtime. A pending reset can be cancelled.
  - The HeyTap/OPPO push and DocumentsUI/DSU picker repairs, moved out of System Services.

Not added: a fix that hides root, Zygisk or memory traces from TEE attestation or app checks.

No native code changed: no CI rebuild needed.

## V66 dev16 - the ZYGISK page saves, the lab shares its screen-on time

Input: the owner asked for the ZYGISK page to save like Device diagnostics and the log report,
and for further work on Smart, the Zygisk integration and the fit to other OnePlus phones and
kernels. The evidence used is the owner's OP15 day log and diagnostics and two other owners'
reports (a CPH2769 on its stock 6.12 kernel, a PLQ110 on a custom 6.6 kernel), all on V66-test1.

- **ZYGISK page: Save.** A Save button beside Refresh writes the page to
  `/sdcard/Download/asb_zygisk_<date>_<time>.txt` the same way as the other two pages: the page as
  shown, then the raw outputs it was painted from (link status, link classes, guard, ART, LSPosed,
  budgets, night charge and the Smart learning files, each under its own heading, a failed read
  marked with its exit code). Rows folded behind "show N more" and the evidence list that is
  built only when it is opened are written out in full. A switch row is written as its name and
  state, the mode control as its choices with the active one in brackets. Saving reads nothing
  new. The button stays disabled until the page has read the state once.
- **Smart lab: screen-on time shared between the knobs.** With no lab app in front, the first
  undecided knob in a fixed order (radio, then the memory bus) always took the next block. On
  mobile data the radio knob qualifies nearly all the time, so the bus knob waited: the OP15 day
  ran the radio 5 blocks and the bus 1. Now the knob that ran last gets one more block when its
  last block is waiting for the other setting (the pair is made while conditions are still
  alike); otherwise the undecided knob that started longest ago runs. In a simulated 8 h on
  mobile data the radio and the bus ran 24 and 23 blocks (12 and 11 pairs), never more than two
  in a row; the old order ran the radio 32 blocks in a row and the bus 15 after it. The now line
  of `smart_lab.txt` counts these follow-up blocks (`followups=`). Effect on drain: not measured.
- **Zygisk observer: sibling processes are kept.** The companion took one process start per
  package per second, so an app's second process started in the same second (`:push`,
  `:remote`) was dropped as rate-limited: 15 of 144 events in the OP15 diagnostics, with no
  duplicates and no capacity drops. Up to three starts per package per second are now taken; the
  64-per-minute cap still bounds a restart storm. These processes are now in the observed set
  (their memory and their exit). The start ledger was never affected.
- **asbdiag on other kernels.**
  - The GPU block read only devfreq nodes, which the OP15's Adreno 840 does not have: governor,
    clocks and the frequency list came out empty. It now falls back to the kgsl nodes (`gpuclk`,
    `min_gpuclk`, `max_gpuclk`, `gpu_available_frequencies`) and names the pwrlevel backend, as the
    Device page already did.
  - The cluster section lists more walt policy tunables (`hispeed_load`, `hispeed_freq`,
    `rtg_boost_freq`, `pl`, `boost`, the adaptive frequencies, `target_load_thresh`) where the
    kernel has them, and says that on a walt cluster the profiles' schedutil rate limits have no
    node. All three phones above run walt with both rate limits at 0, stock and custom kernel
    alike. ASB does not write walt's per-policy rate limits: the values the vendor ships are
    tuned for walt, and nothing measured says another value is better.

Not changed: the CPH2769 report was taken minutes after its governor started (15 forks since
start) and shows no lab block yet; the PLQ110 report is healthy (FAIL=0) and its lab had one
membus pair. Neither shows a device-specific fault.

Native code changed (governor lab, Zygisk companion): CI rebuild needed.

## V66 dev15 - the dev14 audit: what it could not measure, now measured

Input: a diff audit of dev14 against fix315 (score 9.5/10, findings R1-R7, and a list of what
"needs a runtime check"). The owner asked to take the right items and keep improving.

Taken:

- **R3 and "check the GPU latch on real video": both made visible in a log.** The lab summary
  lists every bus voter it may cap, by domain and name, with its state (free, capped, yielded),
  and asbdiag and the day log print them. A log from another SoC then shows exactly which
  clients the name filter let through. The state names the app the GPU-bound latch last fired
  for (`gpu_bound_pkg`), and asbdiag says a video player or a feed named there is a false latch.
- **The GPU latch guarded against its own failure mode.** A video composited at the lowest GPU
  step could, in principle, read 90 % busy, latch GAMING, drop under the exit mark once the
  ceiling lifts, and do it again half a minute later, swinging the GPU for as long as it plays.
  A latch that clears within two ticks now doubles the saturated ticks the next one needs (3,
  6, 12, up to 24). One that holds, or ten minutes without one, sets it back to 3. A game or a
  benchmark scene holds and is not affected. Published as `gpu_bound_need` and
  `gpu_bound_backoffs`.
- **"Cost of the energy sampling and the lab blocks per tick": measured.** The governor thread's
  own CPU time is taken around the lab and the energy table each tick and published as
  `lab_cpu_ms` and `energy_cpu_ms`; asbdiag prints both next to the lab.

Not taken:

- R1 (update.json on V65/650): the owner's rule - update.json follows the published release
  until V66 is published.
- R2 (the lab on by default): unchanged for the dev series. The decision belongs to the release,
  and the measurements above are what it should be made on.
- R4 (pre-compressed webroot): the module WebUI is served by the root manager's own local
  server, which nothing shows to send Content-Encoding for .gz/.br. The packaged page and
  translations are already slimmed in CI, and the download is a zip.
- R5 (envelopes for lahaina/taro/MediaTek): a SoC outside the named families already gets the
  capability baseline (the smallest percent/uclamp envelope, no fixed clocks), and inactive
  without topology/GPU/thermal capability. Tuned values need a log from such a phone. (The audit
  also pairs the names with the wrong phones: lahaina is the OnePlus 9 series, taro the 10 Pro.)
- R6 (two copies of asbdiag): the source tree keeps both on purpose; since dev9 the packaging
  leaves `tools/asb_diag.sh` out when it matches `system/bin/asbdiag` byte for byte, and the
  installer links it.
- R7: information only.

Native code changed: CI rebuild needed.

## V66 dev14 - the dev12 audit, item by item

Input: the owner sent the dev12 audit again (the same document as in the dev13 bundle) and
asked which items are right, which are not, and to implement the right ones. dev13 had already
taken the first part of P1 (the pinned zone bound to the kernel and the thermal map).

Taken:

- **P1 thermal pin binding, finished.** The build hash behind `surface_pinned` now also covers
  the ROM fingerprint. It is a long property on OnePlus builds, so the governor hands the
  callback reader from `asb_fsm.h` to the metrics code. A dev13 pin file is learned once more.
  Not taken from the same item: an expiry after 7-14 days. A pinned zone is checked on every
  tick (3 C away and it counts again), and every boot checks its value, so age adds nothing but
  hours of wrong surface readings each time it runs out.
- **P1 memory bus confidence (in part).** Voters named for another client (GPU, display, video,
  camera, DSP/NPU, modem) are never added; none exist under bus_dcvs on the OP15. A write that
  is taken but reads back as another value now puts the earlier value back and leaves that
  voter alone for the session. Until now an unowned voter was left at the moved value and
  never given back.
- **P2 external undo as its own result.** The WebUI already shows it. Now `undo-all` also counts
  `external=` apart from `undone=`, and asbdiag summarises the background/data journal: active
  by kind, undone by ASB, left because another component had already changed it.
- **P2 Smart Lab hardening (in part).** Every verdict is bound to the build: after an OTA or a
  kernel swap each decided knob is tested again against its neighbour (the best setting stays
  in force meanwhile). A trial under way restarts its pairs, and the drift reference is
  dropped. A store from before dev14 adopts the current build quietly. The hash lives in the
  header's spare word, so the layout and the version stay.
- **Stage 2 global experiment budget (in part).** No screen-on block starts in the first 90 s of
  a screen-on spell. Those seconds may be a glance, which is what the wake-lift trial measures:
  a bus cap or an app lean in force there was counted as the lift's. A block started there was
  cut short by the glance ending anyway. The governor starting with the screen on is not a
  glance.
- **Stage 2 reason codes, 8.6 Smart Lab fields.** Each knob keeps the reason for its last
  decision (`won_energy`, `lost_dearer`, `lost_jank`, `lost_ceiling`, `lost_heat`,
  `no_clear_saving`, `retest_cost`, `retest_age`, `retest_build`) and the days to its 21-day
  re-test; the summary carries both as fields 19 and 20 (the WebUI, asbdiag and the day log
  accept 18 or 20 fields). The day log's lab lines now show the ceiling, jank and heat deltas
  as asbdiag already did.
- **8.5 vendor against ASB ownership.** The day log's ownership verdict now states the shares of
  the samples under a ceiling: ASB, ASB's manual profile, vendor.

Already in place (no change): uninstall removes `/data/adb/asb` as a whole and `/dev/.asb` is
tmpfs; the release workflow runs the regression without `ASB_DSP_REFERENCE_OPTIONAL`; the
lab never runs during the camera, games or HEAVY (`heavy_state` includes the camera); app slots
are limited to three, go stale after 14 days unused, are re-tested after 21 days or when their
cost rises 15 %; two pairs with 2 points more janky frames end a trial (dev11); the log report
already opens with a verdict, separates facts from possible causes and actions, grades
measurement quality, and compares with the previous log.

Not taken:

- `smart_lab_mem=0` by default: on the OP15 the bus writer made 47 writes and 47 give-backs with no
  yields or failures, and it reads back, yields and gives back at shutdown; the change above
  closes the one hole found.
- Invalidating an app verdict on an app update: it needs a package manager query per app,
  and the cost-drift re-test catches an update that matters.
- A capability confidence score, portable/device/build stores, a native snapshot exporter,
  batched telemetry, power-normalised metrics, confidence intervals, five health scores: each
  is a redesign, not a fix, and none answers a fault seen in a log; the build binding above is
  the part of the store split that a log could show to matter.
- Fixtures for 5 CPU policies and MediaTek rules: no OnePlus part has 5 policies. The 2-, 3- and
  4-policy fixtures exist, and the policies are mapped from what the kernel lists rather than
  assumed. Rules for a MediaTek part need a log from one.

Native code changed: CI rebuild needed.

## V66 dev13 - a saturated GPU, LSPosed in WAL mode, lab blocks that survive an app switch

Input: the owner's dev12 day log and diags around an AnTuTu run on a OnePlus 15 (Smart, the
owner's economy bias +60 %, ROM CPH2745_17.0.1.201), two other users' reports on a CPH2769
(Android 17) whose LSPosed card read "unexpected_schema", and an audit of dev12.

What the benchmark log shows:

- **GPU part, ASB's own doing.** The 3D scenes held the GPU at 93-99 % busy, pinned at
  500-646 MHz of its 1200 MHz, for minutes, with load1 6-8: this phone's resting level. GAMING
  needed the package table's agreement and a CPU above the quiet floor, so the FSM read
  "GPU busy, CPU idle = video" and sat in MODERATE (once HEAVY, then SUSTAINED, then MODERATE).
- **CPU part, mostly not ASB.** During the CPU/MEM/UX tests the ceilings were 1113600 /
  1017600 kHz (31 % / 22 % of hardware) at a 39-44 C die, below ASB's own 1785600-1996800 /
  1862400 request; the owner trace marks them vendor-held, and section 10 of asbdiag shows the
  vendor's perf service writing msm_performance (2361600 / 1632000 in ordinary use). ASB does
  not write that node outside HEAVY/GAMING and does not fight a vendor ceiling. Smart's own
  MODERATE-HEAVY guard (55 % main, 35 % prime on a 6+2 part) and the +60 % economy bias would
  have held the CPU well under the stock score even without it.
- **Heat before the runs.** Six reboots between 14:06 and 15:17 (a mainline update among them),
  each followed by a boot storm: the governor's first ticks read the die at 64-86 C with load1
  26-45, and SUSTAINED took over within seconds each time. The kernel command line starts every
  CPU on the performance governor until the ROM switches to walt. ASB's ART compile runs only
  on the charger (compiling=0 in the log).

Changes:

- **A saturated GPU is a game-like workload (`asb_fsm.h`).** Three ticks in a row at 90 % busy
  or more latch GAMING without the package table or a busy CPU. The latch holds while the GPU
  stays above `gaming_gpu_exit`, so a game whose busy share falls once its clock is lifted
  keeps its state. The first drop below that mark clears it. The camera, an unreadable GPU and
  Battery's `suppress_gaming` stay out. GAMING brings its own limits with it: the gaming CPU
  ceiling, cool_gaming, and the gap and temperature exits to SUSTAINED. Video never gets
  there: a feed with autoplay reaches about 60 %. Published as `gpu_bound_streak` /
  `gpu_bound_entries`, and asbdiag names it.
- **LSPosed's database read from a private copy when it cannot be read in place
  (`asb_lspd.h`).** The maintained fork (Vector) keeps the same tables but runs the database in
  WAL mode. A read-only connection then needs a -shm index next to the file. Where the
  module's domain may not create one, every statement failed (SQLITE_READONLY / CANTOPEN,
  reproduced on the host), and anything that was not BUSY/LOCKED was printed as
  "unexpected_schema". Now the file is tried first; on CANTOPEN, IOERR, READONLY or PERM the
  database and its -wal are copied under `/dev/.asb`, the copy is read, and it is removed
  afterwards. LSPosed's directory is never written by a read. BUSY/LOCKED stay "read_failed",
  since a copy taken during LSPosed's own write could be torn. The SQLite code is printed
  (`sqlite_rc=`, `read_from=copy`).
- **Lab blocks pause instead of ending (`asb_lab.h`).** The dev12 day kept 3 lab blocks and cut
  26 short over two long screen-on stretches: a block ended at every app switch, a HEAVY spell
  or a veto, even when the user came straight back. A screen-on block now pauses for up to 60
  s when its conditions lapse with the screen on, and resumes when they return. Running time
  only counts towards its limits; energy and time are not measured during the pause; its
  setting is not in force meanwhile (the radio's is, so the network does not switch for a
  minute and back). A pause that runs out ends the block, which is kept if it already ran long
  enough. Another lab app coming to the front takes over at once. The summary counts short
  blocks by kind and the pauses.
- **The pinned surface verdict is bound to the build (`asb_metrics.h`, from the audit).** The
  file now also holds the number of thermal zones and a hash of the kernel release. A verdict
  from another kernel, another thermal map or in dev12's two-field form is learned again
  instead of applied on the first tick.

Audit items not taken: an uninstall cleanup of `surface_pinned` (uninstall already removes
`/data/adb/asb` as a whole, and `/dev/.asb` is tmpfs); turning `smart_lab_mem` off by default
(the OP15 logs show 47 writes, 47 give-backs, no yields or failures, with read-back and yield
already in place); a separate verdict for an undo that found the setting changed by someone
else (the WebUI already shows it as "already changed by another component"); a strict DSP gate
for releases (the release workflow already runs the regression without
`ASB_DSP_REFERENCE_OPTIONAL`).

Native code changed: CI rebuild needed.

## V66 dev12 - re-checks that run, a surface sensor learned once

Input: the owner asked to keep improving after dev11. No new logs; the work comes from a
second pass over the dev10 day log and a review of the lab code.

Bugs fixed:

- **Lab re-checks that could not run.** A converged knob is tested again after 21 days, or at
  once when its best setting's cost climbs 15 %. For the memory bus with its deepest cap as the
  best setting, and for an app whose changed lean had won, the re-check found nothing left to
  try: only the step further was considered, never the step back. The knob converged again
  in the same tick and the re-test never happened. A champion away from the base setting is now
  tried against the step back toward it. The first exploration is unchanged, since the step
  back has always been tried by then.
- **A surface sensor that never moves, learned again every boot.** On the OnePlus 15
  sys-therm-6 reads 40 C whatever the phone does. ASB already dropped such a zone, but only
  after 300 ticks. Screen-off ticks are sparse, so the dev10 day log read "surface 40 C" from
  04:17 to 09:16 beside a board at 24-27 C. The report counted that as warm time ("body above
  40 C"), and the CPU-peer check saw a hot peer at night. The verdict now also comes after 60
  ticks over 90 minutes, and it is kept in `/data/adb/asb/surface_pinned` (zone type and
  value). The next start drops the zone from the first tick while it reads that value. A zone
  that moves 3 C away from it counts again, and the file is removed.
- **The surface's cold baseline after that verdict.** The baseline was averaged while the
  zone still read 40 C. With the surface then following the board, the surface vote of the
  thermal advisory (40 % of its score) could not rise until the board passed 40 C. A change of
  verdict now takes the board's baseline.

Improvements:

- Screen-off bus blocks in the lab carry their mobile traffic, and two of them are compared
  only when the traffic is alike: within a factor of two, above 1 KiB/s. Under the 15 KiB/s
  cut a 40-minute block could still move 30 MiB.
- The lab summary reported the radio knob "off" whenever the screen was off. It now says
  "off" only when the light-traffic watcher is not running.
- asbdiag: a settings key skipped because it was refused on an earlier boot reads "wanted X,
  not asked this boot" instead of "X -> ?". The surface line says when the dedicated zone is
  pinned, at what value, and whether that came from an earlier boot.

Native code changed: CI rebuild needed.

## V66 dev11 - fixes from the first day with the lab

Input: the owner installed dev10 on a OnePlus 15 and sent a full-day log, a report, an asbdiag
and a screenshot of the monitor page.

What the logs show working: the memory-bus writer found 10 voters under `bus_dcvs` and made 47
writes with 47 give-backs, 0 yields and 0 failures. The lab ran blocks on every knob. The night
measured 0.77 %/h with the phone awake 12.6 % of the time.

Bugs found and fixed:

- **membus_off measured the radio.** A screen-off bus block that overlapped a burst of mobile
  data (one app moved about 146 MiB overnight) counted the modem's drain against the bus
  setting. The lab showed the 50 % cap "29.8 % cheaper" after two pairs, which is not a bus
  effect. A screen-off bus block that moved 15 KiB/s or more of mobile data is now set aside
  (`radio_set_aside=` in the summary). The store goes to version 2; a version-1 store is loaded
  with only its membus_off knob started again, the other knobs keep what they learned.
- **The Smart session counter ran ahead of the learning.** A session was counted before the
  bucket decided whether to take it; quarantined and unreliable sessions were counted and then
  vanished at the next start, when the total is rebuilt from the stored observations (932 in
  the evening, 928 the next morning after the night's reboots). A session now counts only
  when the bucket's observation count actually changed.
- **Two settings shown as "refused by the ROM" that were not.** A key refused on an earlier boot
  is not asked again on the same ROM build, but the skip was always filed as `not_writable`,
  including for a key that does not exist on this ROM. The remembered line now carries its
  class (`unsupported` or `not_writable`, a fifth field; a four-field line from an older build
  still means refused), the skip reports the same class, and asbdiag words a skipped refusal as
  "refused on an earlier boot of this ROM build" instead of quoting a device value it did not read.

Improvement:

- **Early stops in the lab.** A challenger that is plainly worse to use no longer runs to the
  full count (up to 14-16 pairs). Two pairs with janky frames 2 points or more above the
  champion, three pairs with the cores at their ceiling 15 points more often, or three pairs
  warming 30 dC/h faster (screen-on knobs) end the trial at once (`early_stops=`). The
  ordinary guards (+1 pt, +8 pt, +15 dC/h) still decide at the normal count.
- The day log copies `smart_lab.txt` and prints the lab knobs, the bus line and the now line.

Observed, not changed:

- The red "Vendor" owner on the monitor during HEAVY is one status reading in which a live
  ceiling sat below ASB's request. The clamp counter beside it comes from the state file read
  just before that status was built, so it still said 0. The day log found no foreign owner:
  cap checks 8 of 8 on ASB's value, owner verdict "no foreign-owner dominance"; the governor's
  tick accounting saw the ROM raise a ceiling in 6 ticks and counted no slow clamps.
- The 67 °C screen-off CPU peak in the report is the first sample of the capture, two minutes
  after a reboot, with a load average of 18 (boot work).

Native code changed: CI rebuild needed.

## V66 dev10 - a lab test that depended on directory order

CI failed `t_smart_lab_native_runtime`: "external value overwritten or own cap not given back:
2092000 4224000". The engine did the right thing. The test wrote the "external" value to the
first voter the bus probe found, then checked a fixed path for it, and the probe lists voters
in readdir order. That order is creation order on one filesystem and reversed on another (the
CI runner's, and tmpfs here).

The harness now reports the two voters by the index the engine uses. The check passes with
both orders, and the old check fails on tmpfs exactly as in CI. No module code changed.

## V66 dev9 - a smaller package, the ZYGISK note gutter

Input: the owner asked for a smaller module with nothing lost, an opinion on pruning old Smart
sessions, and noticed notes on the ZYGISK page sitting against their green line.

**Smaller package, same behaviour.** A host build of the release tree came to 7.4 MB unpacked,
2.25 MB zipped, without the native binaries.
- `tools/asb_slim_package.py` runs on the staged package in both workflows:
  - translations are written without indentation (-181 KB): each file must parse to the same
    object;
  - comment lines come out of the page's script and style blocks (-264 KB): only lines that
    are nothing but a comment, so no string, regex or URL can be cut. The step is skipped if
    the page ever gains a template literal or a continued string;
  - every script block must still compile;
  - asbdiag's own settings-registry reader must read the same rows. If anything differs, the
    originals are restored and the build fails.
  - In a browser, 3 locales show the same DOM, the same CSSOM hash and the same global
    functions, with no page errors.
- `tools/asb_diag.sh` was shipped next to the byte-identical `system/bin/asbdiag` (316 KB).
  The package now carries it once, and the installer links `tools/asb_diag.sh` to it after the
  tool prune, so both paths still run.
- The Zygisk observer is linked with section GC and `--exclude-libs,ALL`. The static C++
  runtime it carried was whole and exported from inside every observed app process. On the
  host compiler the same flags took the library from 1.46 MB to 0.61 MB and the dynamic table
  from 4128 symbols to 9, with both Zygisk entries still exported. The NDK figure will show in
  the CI log (`ls -lh` added); the existing `llvm-nm` export check still gates the build.
- Expected effect without the binaries: about -760 KB unpacked and about -230 KB zipped. The
  observer libraries come on top of that.

**ZYGISK page.** dev4's two-line clamp set `padding: 0` on folded notes. That also took the
12 px gutter from the notes with an accent line, so their text touched the line again; this
had been fixed once before. The clamp now resets only the block padding, and folded evidence
notes keep `padding-inline-start: 12px`. Measured in Chromium: before 0 px, after 12 px.

**Sessions.** Nothing was changed, so old sessions are not pruned. Each of the 12 slots learns
from a session at 8 %, so a session 50 sessions back weighs 1.5 %. Full confidence is reached at
8 effective sessions. A slot not seen for 7 days loses confidence, down to 30 % at 37 days.
Unreliable sessions are already dropped, and the history file is rotated at 500 entries.
Dropping "inefficient" sessions would teach Smart only from good outcomes and hide the bad
settings it must avoid.

**Native**: `src/build_ndk_release.sh` (Zygisk flags), so a CI rebuild is needed for the
smaller observer libraries. No C source changed.

**Tests**: `t_webui_slim_package_runtime` (tool equivalence, template-literal no-op, workflow
and build pins); the installer prune test now checks the restored `tools/asb_diag.sh`.

## V66 dev8 - Smart lab, memory bus, panel maximum, audit items

Input: the owner's request to implement the four dev7 proposals plus memory-bus control, more
control points and adaptation to how the metrics move, to let forced LTPO reach 165 Hz on
panels that have it, and to act on an external audit of dev7.

**Smart lab** (`src/asb_lab.h`, `smart_lab=1`, Smart only). It runs paired experiments for
seven knobs:
- `radio` - 5G only when needed against 5G allowed;
- `wake_lift` - the unlock lift against 15 points less, over glances, with SystemUI frames;
- `membus_on` - CPU bus votes free / 75 % / 55 % while the screen is calm;
- `membus_off` - free / 50 % / the lowest step on quiet deep idle;
- `app1`..`app3` - its own lean for the three apps that cost the most with the screen on.

How it decides:
- Rules shared with the records: neighbouring pairs, at least 3 % and t >= 2.5 to win,
  15 % dearer is dropped, no verdict means no change.
- New guards: at-ceiling share (+8 pt), janky frames (+1 pt where counted), battery warming
  (+1.5 C/h).
- One screen-on experiment at a time, and none while the records still test the same
  situation. Lab apps are left out of the records' situations (`lab_owned`).
- Dynamics: a champion is still measured after its verdict; 15 % above its winning cost for
  four blocks re-opens the knob at once. A verdict drops any block of the knob still under
  way, and a sample whose arm no longer matches is discarded.

**Memory bus**:
- Discovery covers every voter directory under `bus_dcvs/DDR` and `bus_dcvs/LLCC` with a
  writable `max_freq`, or a DDR devfreq device.
- A cap is the lowest listed step at or above the share, written only under the voter's own
  value and read back. It is given back when it ends and at shutdown.
- A value someone else wrote is left to them: a readback every 30 s while capped.
- Display, GPU, video and modem paths are never written.
- Nothing has been measured on a device yet. The lab keeps a cap only if it measures cheaper.

**Records**: screen-off blocks of 20 instead of 40 minutes once three or more pairs sit
within 4 % and the drain is at least 75 mA. With 1 mAh gauge steps, a 26 mA night would draw
under 9 mAh in 20 minutes, so it keeps 40-minute blocks.

**Forced LTPO, panel maximum on touch** (`ltpo_peak_force=0` by default):
- While touched, `service call SurfaceFlinger 1035 i32 <mode>` asks for the panel's highest
  reported mode at the resolution in use. An FHD setting picks the FHD 165 Hz mode, never the
  1.5K one.
- It is released with an invalid id when the watcher goes idle or stops.
- Three refusals mark the ROM unsupported.
- On OP15 the 165 Hz modes are listed (ids 5 and 11). On other models it depends on what
  the panel reports, so it is untested there.

**Audit items implemented**:
- strict warnings 60 -> 48 (headroom 14 under the 62 budget);
- the DSP fixture's misleading indentation fixed;
- an hourly budget of 240 optional forks (app-lookup dumpsys fallbacks, frame probes), with
  none while the camera runs (`fork_budget_*`);
- energy meter confidence (`windows=`, `confidence=`, `basis=`);
- WebUI cards for `profile_class_auto` and `smart_records_balanced` (now user keys);
- Smart V7 undo reports `restored` / `external` / `failed`, and a change someone else already
  reversed is journaled `external` instead of `undone`;
- the night-charge switch hold releases charging when the charge level cannot be read, and the
  WebUI names it "charging paused (charge switch, not a charge limit)".

**Audit items not taken, with reasons** (in the reply to the owner):
- the DSP prebuilts are excluded from the review archive on purpose;
- a unified evidence scheduler (each refresh is already TTL-bound to 6 h);
- a separate radio/screen/CPU drain split (no per-rail meter on these phones);
- fixed minimum A/B durations (pairs are the unit);
- user energy budgets (that is what the profiles are);
- a report.json schema rewrite;
- a freeze on new writers (the owner asked for more control points; the new writer is owned,
  read back and A/B-gated).

**Native**: `asb_lab.h` (new), `asb_record.h`, `asb_energy.h`, `asb_smart.h`, `asb_config.h`,
`asb_writer.h`, `asb_metrics.h` and `asb_governor.c` changed, so the governor needs a CI rebuild.

**Tests**:
- `t_smart_lab_native_runtime` - a simulated phone:
  - the radio wins and is re-opened by a cost rise;
  - a bus cap that pins the cores loses;
  - a cheaper wake lift wins, and the same lift with jankier SystemUI frames loses;
  - app slots and records exclusion;
  - bus voters found, capped, given back and yielded;
  - the store reloads.
- `t_ltpo_peak_force_runtime`;
- external undo cases in `t_smart7_budget_data_runtime`;
- the lab file in `t_lte_bulk_runtime`;
- the unreadable charge level in `t_night_charge_sysfs_runtime`.

## V66 dev7 - 5G stays off for feed bursts

Input: the same OnePlus 15 day (CPH2745, SM8850, dev5), with the request to review the V66 Smart
and Zygisk work, fix what is wrong, and make ASB itself cut the drain further.

Review of dev1-dev6: no new native fault was found in the writer, FSM, records, energy or
config changes, nor in the Smart V7, LSPosed, night-charge and launch-compile scripts or their
uninstall hooks. On this phone the Smart records measure on_light_dim 13.1 % below the original
setting, side by side; the other situations are still testing or sit on their old setting.

**5G only when needed: a feed burst is not a download.** The day's "5G only when needed" log
gave 5G back 9 times with the screen on.
- 7 of the 9 came from two busy 10 s windows at 3.4-9.5 Mbit/s. LTE carried 15.8 and
  21.4 Mbit/s in single windows the same day, so LTE was not what held those apps back.
- Four of the LTE stints before them lasted 61-203 s, and that doubled the 5G holds to 20 and
  40 minutes. Roughly 4 of the 9 logged hours ran with 5G allowed.
- A feed loads its next videos in bursts of 10-30 s and then waits. A download keeps the link
  busy.

Change:
- 5G now comes back for demand in 4 of the last 6 windows (3 Mbit/s or more), or for two
  windows in a row over 12 Mbit/s.
- A download still gets 5G back within 40 s, against 20 s before.
- When the watcher stops, the log says how many busy windows stayed on LTE, and asbdiag
  sums them.
- What this saves on a given network is not measured: the modem's own draw is not readable.
  Fewer switches and fewer long 5G holds is what the change guarantees.

**The keyboard is not the app in front.** Typing in a system window (a notification reply,
Settings, the lock screen) leaves the keyboard as the only app process in the top-app
cgroup. The lookup took it: this phone's per-app energy table billed 16 screen-on minutes to
the keyboard.
- Keyboards are now left out by name: `inputmethod`, `keyboard`, `swiftkey`, `honeyboard`,
  `baidu.input`, `.ime`.
- A cgroup holding only a keyboard goes to the dumpsys chain, which names the real window.
- A keyboard at adj 0 beside the app no longer makes the answer ambiguous.
- New state key `probe_topapp_keyboard_only`.

**Night charge learning** wrote its plug flag to /data on every tick (every 2-10 minutes). It
now writes it only when the flag changes.

**Native:** `src/asb_smart.h` and `src/asb_governor.c` changed (the keyboard rule and its
counter), so the governor needs a CI rebuild. The 5G rule and the night-charge write are
shell and need none.

**Tests:**
- `t_lte_bulk_runtime`, `t_lte_light_runtime` and `t_lte_light_flap_runtime` drive the real
  `_light_tick`: a 20 s burst and single fast windows stay on LTE, 4 of 5 busy windows and
  two fast windows give 5G back, and kept windows are counted;
- keyboard cases in `t_topapp_pkg_runtime`;
- the no-rewrite case in `t_night_charge_learn_runtime`.

## V66 dev6 - a WebUI that stops drawing when nobody looks

Input: the owner's 7 h 46 min Infinite Log, three asbdiag runs and the action screen of a
OnePlus 15 (CPH2745, SM8850) on dev5, with the request to cut heat and drain and to improve
performance and smoothness on every supported model.

What the capture shows:
- **The day's costs are mostly the use itself.**
  - Screen on was 7.5 %/h, with 1.5 GiB of mobile data (1.3 GiB with the screen on) and video
    feeds in front.
  - Bluetooth audio with the screen on was 12.1 %/h while 274 MiB moved in 44 minutes.
- **The caps are not what janks.** 2.3 % of frames were late: 1.7 % with the main cores at
  ASB's ceiling against 2.5 % below it. The late frames were the apps' own UI threads.
- **SystemUI** missed deadlines in 264 of 283 screen-on intervals because the status-bar
  network-speed meter redraws every second. That is a phone setting, and the report already
  names it.
- **The heat episode.** The 67 C peak came from 7 minutes of a feed loading every core. The
  surface comfort trim engaged at 48 C, as designed.

**ASB's own page was the dearest thing on screen per minute.**
- The manager hosting the WebUI drew 4.1 W while in front, against 2.3-3.3 W for the feeds.
- 52-59 % of its frames spent 8 ms or more on the GPU, against 2-6 % for every other app.
- In the browser model the idle home screen ran 31 endless animations and drew 60 frames a
  second. Five of the animated headers belonged to closed pages. The rotating glows are
  blurred, and the wordmark sweep repaints text on every frame.

**Change.** The decorative loops now stop on closed pages, under an open page, and ten
seconds after the last touch. The next touch starts them again.
- The loops are the logo glow and ring, the wordmark sweep, the status dots, the Smart glow,
  the Zygisk link pulse, the charge shimmer and the recording pulse.
- The sweep and the dot stop at rest, not mid-stroke.
- Progress spinners are never paused.
- Same model, after the calm: 0 running animations and 0 frames a second, against 31 and 60.
  The phone's own figure will differ.

**Smaller fixes:**
- **The usual-charge drain (dev4 bug).** The screen-on share counted only gaps of 30 s or less
  between governor ticks. With the screen off the ticks are rarer than that, so this phone
  read 96-97 % screen on for a day with 60 %. The whole gap now counts, in the state the phone
  was in during it. The energy store is version 3; a version 2 store keeps its per-app figures
  and restarts only the share.
- **The action screen** called a lifted prime ceiling "the responsiveness floor" when a lift
  or burst had just ended (3648 MHz on the CPH2745, where the floor is 40 % of 4608). Above
  half the hardware maximum it now says that a lift or burst has just ended and the ceiling
  comes down on the next pass. It does this in all 13 languages.
- **The memory-bus figure.** asbdiag and the WebUI now say that each DDR read is taken at the
  governor's own wake. That makes it an upper bound, not the residency while asleep.
- **Native:** `src/asb_energy.h` changed, so the governor needs a CI rebuild for the share fix.
  The WebUI and the action screen need none.
- **Tests:**
  - `t_webui_v66_calm_decor_runtime` (the real calm timer over fake timers, and what the CSS
    rule pauses and never pauses);
  - the long-gap case in `t_smart_v7_native_runtime`;
  - the lift-tail line in the fix196 contract.

## V66 dev5 - the V7 badge, real milliwatts per app

Input: the owner's asbdiag of a OnePlus 15 (CPH2745, SM8850) on the dev4 build, and his
report that the Smart badge on the home screen still said V6.

- **The badge.** It shows `smart_engine_ver`, the version of the learned store
  (`ASB_SMART_VER`), and dev4 added Smart V7 without raising it. It is 7 now. V4-V6 stores
  carry over with everything they learned, as V4 and V5 did before; only V3 and older still
  have their learned outputs reset.
- **Cost per app was about 40 % of the real figure on that phone.** dev4 credited the apps with
  the current on the reference scale the thresholds use (the OP15 gauge, x0.38 of the real
  drain). That is right for a threshold, but a figure in mW needs the real drain. The same
  asbdiag has this phone's gauge at x0.42.
  - The reading is now divided by the phone's own ratio.
  - Nothing is credited until that ratio is on record (5 screen-on windows).
  - The store version is 2, so dev4's figures are dropped once.
  - The summary prints `meter|gauge_x100=`; asbdiag and the WebUI say when the gauge is not
    checked yet.
- **The usual charge line** prints `-` until a half hour holds about three charges (dev4 printed
  a guess behind a dash, `-10:00`).
- **Native:** `src/asb_smart_defs.h`, `asb_smart.h`, `asb_record.h`, `asb_energy.h` and
  `asb_governor.c` changed, so the governor needs a CI rebuild.
- **Tests:**
  - the store migration cases (V6 -> V7 keeps the outputs);
  - the badge test (V7);
  - `t_smart_v7_native_runtime` (the real `asb_ma_real` on a x0.42 gauge, before the ratio is
    known and with a nonsense ratio, the gauge line in the WebUI parser).

## V66 dev4 - Smart V7, faster page switches, a shorter ZYGISK page

The owner's requests:
- implement the Smart V7 ideas and the profile ideas, except per-app refresh rate (idea 4);
- switching from the home screen to MONITOR or SETTINGS had become slower in dev2/dev3;
- the ZYGISK page had become too long: shorter at first, with buttons that open the rest,
  and no information removed.

**Page switches (WebUI).** The background reads queued after the first frame (the first Live
pass at +340 ms, the Zygisk header and the other-audio look at +700 ms) ran while the user was
already opening MONITOR or SETTINGS. The KernelSU bridge blocks the page during each of them,
and MONITOR's own first poll waited behind the Live pass. Changes:
- the Live pass now runs right after the first frame and is skipped when MONITOR is open;
- the other background reads wait while any page is open;
- the queue waits 300 ms after a touch;
- a tap no longer triggers the other-audio look; it runs at startup and on return only.

**ZYGISK page.**
- Explanations longer than 90 characters show two lines and open on tap.
- A list with more than four rows shows three and a **Show N more** button.
- Action buttons sit inside their rows.
- Each LSPosed module's reasons and apps are under a **Why** fold.

Nothing is removed. In the browser model with the test fixture the page is 4747 px instead
of 6904 px.

**Smart V7 - scripts (no rebuild needed):**
- **Background budgets (idea 6), soft on Battery (B):** `runtime/asb_smart7.sh`.
  - A rarely opened app that keeps starting in the background goes to Android's `rare` standby
    bucket.
  - Automatic (opt-in): unused 7+ days and 6+ background starts a day. On Battery also without
    the switch, at 14+ days and 10+ starts.
- **Modem wakers (idea 12):** an unopened app moving mobile data in the background loses
  background data on metered networks (Android's per-app switch). Automatic (opt-in) from
  10 MB a day.
- **Both:** protected classes are never touched; every change is journaled, undone by tap and
  given back on uninstall.
- **Learned unplug time (idea 9):** `runtime/asb_night_charge.sh learn on`. The night charge
  hold ends 90 minutes before the usual unplug: the median of the last 4 weeks, weekdays and
  weekends apart, clamped to 03:00-10:00.

**Smart V7 - governor (CI rebuild of `bin/asb` needed):**
- **Second check and rollback (idea 8).**
  - A new records champion is measured once more against the setting it beat. If the old one
    comes out significantly cheaper, it is put back and the trials turn to the other side;
    otherwise the win is confirmed.
  - Each verdict keeps an interval (± 2.5 standard errors).
  - The counts are in `smart_records_v7.bin`, beside the V65 store, which loads unchanged.
- **Priors (idea 11).** A first trial starts on the side the sibling situation already won on
  this phone (night/day, dim/bright). No per-SoC table: two OnePlus 15 (SM8850) captures
  disagree, ×1.0 against ×1.25 for the screen-off night.
- **Balanced (A).** It replays the screen-off setting Smart won and confirmed, on quiet deep
  idle; nothing is measured or tried (`smart_records_balanced=1`). Only a setting below ×1 is
  used: the profile script owns Balanced's ceilings, so the writer multiplies those by it and
  hands them back on wake, and never raises them.
- **Cost per app and per kind of use (ideas 1 and 10).** `src/asb_energy.h`: screen on and off
  the charger, current × voltage per app in front. A stretch is a glance, light, media,
  heavy or game. The figures fade by 3 % a day (`smart_energy=1`).
- **Prediction (idea 2).** The usual charge time, learned by half hour. The budget compares
  the hours left at a drain mixed from screen-on and screen-off with the hours to that charge.
  - Short of it under 50 %: the warning lean.
  - Half as much again in hand: no warning lean.
  - The emergency level is never relaxed.
- **Thermal model (idea 3, C).**
  - Smart's soft pre-lean is judged on the reading two minutes ahead.
  - Performance's SUSTAINED trip point moves down by the projected rise, at most 4 °C, when the
    die heats at 1.5 °C/min or faster near it.
- **Profiles by kind of use (D, `profile_class_auto=1`).**
  - Performance holds a light app at 80 % of the CPU maximum.
  - Battery lifts a game to 70 % where its own ceilings are lower; the writer hands Battery's
    values back afterwards, as it does after the unlock lift.
  - Heavy work, launches, touches, the camera, the unlock lift, thermal caps and the cooldown
    are untouched.
  - The effect has not been measured on a phone yet.
- **LSPosed link (idea 7).** `asb_lsposed_lite.sh` writes the apps scoped by a costly module
  to `/dev/.asb/lsp_heavy_apps`, and Smart's smoothness test skips them.
- **Memory bus (idea 5), measured only.** The DDR clock on quiet screen-off is read and compared
  with its lowest step. Nothing is written to the bus until captures show where it is held.

All of it is in the Smart card on the ZYGISK page (**What Smart learned**), in asbdiag and in
the full-day report, in 13 languages. The Smart learning reset clears the new stores.

**Tests:**
- `t_smart_v7_native_runtime`: the real records, energy, budget, Performance-lead,
  hooked-app and class code, plus the WebUI parser on the governor's own summaries;
- `t_smart7_budget_data_runtime`, `t_night_charge_learn_runtime`;
- `t_lsposed_lite_runtime` (hooked-app list);
- `t_webui_zygisk_compact_contract`;
- `t_webui_v66_startup_queue_runtime` (page-busy rule).

## V66 dev3 - a lighter LSPosed

The owner's request:
- ASB should understand LSPosed modules: which ones are on, what they hook and which ones cost
  battery or smoothness;
- users should see this;
- the setup should get lighter, by tap with confirmation and as an automatic variant;
- one module should be measurable with an A/B test.

Smart V7 ideas are proposed separately for the owner to choose from; Smart and the profiles are
unchanged in this build.

- **Native (`src/asb_lspd.h`, CI rebuild of the governor needed):** three edits next to the
  read-only inventory:
  - `asb --lspd scope-del|scope-add MOD APP USER`;
  - `asb --lspd module-set MOD 0|1`.

  They write the same rows LSPosed's own manager writes. Each runs in one immediate
  transaction, is checked against the expected columns first and read back after. Names are
  plain package identifiers before they reach a statement, and LSPosed's own `lspd` row is
  refused.
- **`runtime/asb_lsposed_lite.sh`:**
  - **Per module:** its reach (framework, SystemUI or apps), a verdict (costly, worth checking,
    light, off) and the reasons for it. The sources are:
    - Android's usage history (last opened);
    - the Zygisk start ledger (background starts per day);
    - crash/ANR records whose stack passes through the module.
  - **Lightening candidates:**
    - apps not opened for 21 days that still start in the background;
    - apps the module's hooks crash.

    The framework, SystemUI, the module itself, uninstalled apps and disabled modules are never
    candidates.
  - **By tap:** Lighten, Switch off/on, Undo, Undo all, all with a second-tap confirmation.
  - **Automatic, opt-in, daily:**
    - removes only scopes of unused apps with 4+ background starts a day, or of crash loops
      (5+);
    - never touches protected classes (messengers, mail, 2FA, wearables, alarms, navigation,
      the Doze keep list, notification-fixed apps);
    - never switches a module off.
  - **A/B test of one module:**
    - a day with it, with 6 h screen off and 1 h on;
    - the module switched off, then a reboot;
    - a day without it;
    - the module given back.

    It compares screen-off and screen-on drain from the drain meter and the CPU time of the
    hooked apps (`/proc/uid_cputime`). A difference counts above 15 % and a fixed floor. The
    result reaches the verdict.
  - **Bookkeeping:** every change is journaled and reversible, takes effect after a reboot
    (`pending_reboot`) and is undone on uninstall.
  - **Cost:** the evidence (usagestats, dropbox, package list) is read in the background at
    most every 6 h. That happens only after the card was first used; the service tick runs only
    then.
- **WebUI:** an **LSPosed** section on the ZYGISK page, also shown while the observer is off, in
  13 languages. asbdiag prints the same rows.
- **Test:** `t_lsposed_lite_runtime` exercises the real C helper on a database laid out like
  LSPosed's, the real script with stubbed Android tools, the A/B test across a fake reboot and
  the WebUI parser on the script's own output.

## V66 dev2 - a faster WebUI opening

Input: the owner's report that opening the WebUI takes too long, even right after closing
it; an Infinite Log (22 h) and an asbdiag of a OnePlus 13 (CPH2649, SM8750) on the V65
release.

- **The OnePlus 13 capture shows nothing on ASB's side to fix.** 1.7 %/h over 22 h, 0.2 %/h
  over a 5 h night, 1.6 % late frames, ASB's own cost 1.3 s CPU per hour, asbdiag 100 % (18
  of 18). The screen-off wake time came from Android's motion detector and from media
  playback. No module setting changed for it.
- **Measured first.** A browser model of the opening was used: Chromium at 4x CPU slowdown,
  the files streamed at 4 KB/ms, and every root call blocking the page for its estimated run,
  as the KernelSU bridge does. Its medians over five openings:
  - before, the first frame of the home screen came at 1304 ms and 275 ms of root calls had
    blocked the page before it;
  - after, 976 ms (-25 %) and one root call (77 ms) before it.

  The phone's own numbers will differ; the order of the work is what changed.
- **One locale file, requested from `<head>`.** The opening read `en.json` (200 KB) and the
  chosen locale (up to 340 KB) after the whole 1.3 MB page was parsed, and the home screen
  waited for both. Every shipped locale carries every key path of `en.json`, so English is
  now read only when it is the language, or when the chosen file cannot be read. The request
  starts in `<head>`, while the rest of the page is still being read.
- **Background reads after the first frame, one at a time.** The Zygisk header, the first Live
  pass and the other-audio look used to block the page before its first frame. They now:
  - wait for that frame and run in that order, with gaps between them;
  - step aside while a finger is on the screen.

  The same applies when the page comes back from the background. What they read and how
  often is unchanged.
- **No `dumpsys audio` inside a tap.** A sound cue more than 15 s after the last look used to
  run the look inside the tap. The look now runs after the tap, once the page's own sound
  stream has closed. Until the first look has finished, no cue plays.
- **Tests:**
  - `t_webui_v66_startup_locale_runtime` (real head loader and `loadI18N` over a fake XHR,
    plus nested key paths of all 13 locales);
  - `t_webui_v66_startup_queue_runtime` (real queue over fake timers);
  - the sound cases in `t_webui_quiet_ui_runtime`.

  Each fails on the dev1 page.

## V66 start (versionCode 660)

Base: the published V65 release (`V65`, versionCode 650). `module.prop` is `V66` / `660`, the
governor reports `V66`, and the WebUI badges and the release-tag tests follow. `update.json`
stays on the published V65 release (`V65`, 650, release 65) until the V66 zip is attached to
release 66.

Input: four Infinite Log captures and five asbdiag runs of the V65 release from four phones
(two OnePlus 15, a CPH2769 and an Ace 5), plus user reports.

- **Launch ART: an app can be excluded, and ASB's compile undone.** On a CPH2769 a banking app
  hung on its logo after the nights the launch-ART feature compiled it on the charger
  (`last result compiled`, bg-dexopt). A reinstall fixed it until the next night. The capture
  cannot prove why the app rejects the compiled code (the compile is the same `bg-dexopt` Android
  runs itself), but the timeline points at that compile, and the owner asked how to take one app
  out.
  - `runtime/asb_zygisk_aot.sh exclude <pkg>` puts the app on an owner list
    (`/data/adb/asb/zygisk_aot_exclude`). An excluded app is never ranked, never a candidate and
    never compiled again, and a batch that is already running skips it.
  - If ASB compiled the app (its row says `compiled`, or the event log has the compile), its
    compile state is reset to the one Android installed it with (`pm compile --reset`), in the
    background so the WebUI does not wait. The result is a `reset` or `reset_failed` event with
    the filter before and after. An app Android compiled itself is left alone.
  - `include <pkg>` allows the app again. Package names are validated before any of this.
  - The Zygisk page has an **Exclude** button on every listed app and an **Allow again** button
    on every excluded one. asbdiag lists the excluded apps and the resets. Uninstall removes the
    list.
  - Android's own nightly maintenance can still compile the app. If the app breaks again with
    ASB's compile excluded, the cause is outside ASB.
- **Day report: wake stutter under firmware caps is not called ASB's fault.** Two OnePlus 15
  captures flagged stutter at unlocks and app opens as an ASB problem and asked for the
  developer log (7.5 % of frames late there against 4.5 % over the day, and 6.1 % against 3.3 %).
  In the same captures the firmware held the prime cores below ASB's ceiling in 92 of 140 and
  143 of 146 checks, so ASB's touch boost could not lift them.
  - With the prime cluster vendor-held in most of at least 10 checks, the card is now a ROM-side
    finding (`normal`, no log request) that gives the share of checks.
  - The smoothness tile no longer turns red for it.
  - Under ASB's own caps the old card is unchanged.
- **asbdiag: no false FAIL for a stock audio policy.** One OnePlus 15 read 92 % because of
  "Hi-res 384000 present in audio policy: want 1, live 0" on an install with the audio tweaks
  off: ASB had never delivered that file. The check is now a verdict only where ASB delivers the
  policy: an odm bind queued for `audio_policy_configuration*.xml` (that bound file is checked),
  or the `/vendor` overlay with the file in the module. Otherwise it is a note with the stock
  count.
- **Native:** only the version string in `src/asb_governor.c` changed. The governor binary needs
  a CI rebuild to report `V66`.
- **Tests:**
  - `t_zygisk_aot_exclude_runtime` (real script and WebUI parser);
  - wake-stutter attribution cases in `t_webui_log_report_runtime`;
  - `t_asbdiag_hires_owner_runtime` (real asbdiag block over fake paths).

  Each new case fails on the V65 code it guards.
