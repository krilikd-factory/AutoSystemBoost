# AutoSystemBoost — V66 build history

Build-by-build notes of the V66 line, newest first. The V65 release summary stays in
[`CHANGELOG.md`](../CHANGELOG.md) until V66 is released; the V65 line is in
[`V65_BUILD_HISTORY.md`](V65_BUILD_HISTORY.md).


## V66-test18 (second build) - LHDC helper reaches Bluetooth, every section as a console, scroll guard

Input: the owner's asbdiag of 22:45 on test18 (OnePlus 15, LHDC V5 48 kHz playing, rate set to
96 kHz): the helper still waited with `no_adapter` after 7 tries.

### Bluetooth sample rate (LDAC/LHDC)
- Root cause: since Android 13 the Bluetooth binder is resolved through
  `BluetoothFrameworkInitializer`, which ActivityThread fills in only for app processes and
  system_server. In a bare app_process it stays empty, so both BluetoothManager and
  `getDefaultAdapter()` return no adapter. The helper now gives the initializer the framework's
  own `BluetoothServiceManager` before asking for the adapter, and a missing adapter carries its
  cause (`no_adapter:<why>`) into the state file and asbdiag.

### WebUI: sections as consoles
- Every settings section with more than one tweak is now one console in the DSP engine's
  language: Playback & Bluetooth (output and volume, Bluetooth link, codec quality); Battery -
  Smart & profile (Smart profile, learning on the phone, prime core bursts), Charging, Sleep &
  background (deep sleep, wakelocks, location), Heat & performance (throttling, CPU ceiling,
  games), Memory & apps; Network - mobile, Wi-Fi, network stack; camera performance; interface
  speed and visual effects; system services and diagnostics. A chip row sums each console up,
  every group shows how many of its tweaks differ from stock, and a row keeps its status line
  only when it says something (unavailable, after reboot, a warning, Smart ownership).
  Kernel management keeps its own rows (they carry live kernel evidence).
- Long slider values (Wi-Fi scan rate) wrap inside the console instead of running off the edge.
- A segment row with long labels (Factory CPU ceiling: Off · Performance profile · Always) put
  its control over the name and covered the row's status line (owner's screenshot). Such a row
  now shows its control on a full-width line under the name; long single-word names hyphenate
  instead of running under a slider.

### WebUI: no settings changed by scrolling
- Sliders move only for a deliberate sideways drag: the first 8 px of the finger decide, a
  mostly vertical move is a scroll (the thumb snaps back, nothing is saved, and the page scrolls
  from the slider too), a tap on the track changes nothing, and a press while the page is still
  gliding after a fling is never a drag.
- Every other control (switches, segments, menus, buttons, tabs): a touch that lands while the
  page is still gliding only stops the glide, and a finger that travelled more than 12 px is a
  scroll, not a tap. Checked in Chromium with touch events: tap on a track, vertical swipe from
  a slider and a tap during a fling saved nothing; a sideways drag and a normal tap saved once.

### Logs from users
- "Send logs to Bugs" no longer trips over a pile of old logs: the infinite log being recorded is
  taken first, otherwise the newest folder touched in the last 3 days; asbdiag and reports older
  than 3 days are left out, and nothing at all is packed when only old logs exist.
- A capture too large for the bot (over 19 MB packed) is packed again without its files over
  4 MB; `asb_bundle.txt` in the archive says how many were left out.

## V66-test18 - LDAC/LHDC rate on Android 16, logs to Bugs, console panels

Input: the owner's asbdiag captures of 20:40 and 20:46 (OnePlus 15, LHDC link, 96 kHz picked by
hand) and the AnyKernel3 install log of the KRILIKD kernel.

### Bluetooth sample rate (LDAC/LHDC)
- The capture had `out_reason=no_adapter` and no watcher: on Android 16
  `BluetoothAdapter.getDefaultAdapter()` returns null inside app_process. The helper now takes
  the adapter from the system context's BluetoothManager, keeps waiting (30 s, later 5 min)
  instead of exiting when Bluetooth is not up yet, and names a refused profile proxy.
- The resident helper re-applies the rate on codec, active-device and connection broadcasts.
  `service.sh` only restarts it if it died: the existing 5-minute pass checks the helper's
  process (one read of /proc, no new shell, no app_process) and starts it again when a fixed
  rate is set. The helper's safety re-check runs every 30 min with broadcasts and every
  2 min (headphones) / 5 min (none) without them, on the uptime clock (no wakeups in sleep).
- The option is named "LDAC/LHDC sample rate" in all 13 locales and both advanced READMEs.

### Logs from users
- Log menu → "Send logs to Bugs": two taps; makes a fresh asbdiag when none is under two hours
  old, packs it with the newest infinite-log folder and report into
  `Download/ASB_logs_<time>.tar.gz` (19 MB ceiling, partial files skipped) and opens the group's
  Bugs topic. The module carries no token; the user attaches the file.
- Each archive has its own id (`YYYYMMDD_HHMMSS-<random>`, in the name and in
  `asb_bundle.txt` inside). While the logs are unchanged the button returns the same archive and
  id instead of a new one; the bot refuses a received id and a repack of logs it already has.
- A bot in the private log repository collects ASB logs from Bugs and General every 3 hours,
  checks them without extracting, stores them with a short summary (no sender identity) and
  replies in the thread.

### Fitness apps & wakelocks
- A lock taken before the restriction no longer counts as "the ROM ignores it": the verdicts
  `limit_ignored` and `strict_ignored` now need a lock younger than the moment the limit or the
  restriction was set (the time of each is kept in the ledgers).
- `com.ftband.mono` (a bank app) was taken for a band companion; the companion pattern now
  matches band apps by name only.
- The list of limited, restricted and companion apps opens with the description, on tap.

### WebUI
- Notification fix: the long description is folded behind the name like every other card.
- Console cards (DSP engine, parametric EQ, Screen & touch, Per-link transport, Photo grading,
  Zygisk): each group is a framed panel in the LSPosed card's style, with its name and a badge
  that counts changed controls; a tuned group gets a tinted frame and a chip row sums the card
  up. The EQ shows each band's gain as a chip and on the band's own panel; panel colours follow
  the category.
- The page content is 12 px from the screen edges and the floating bars are no wider than the
  content, so their edges line up.

## V66-test17 - fitness strict mode, option lists in console cards, LDAC rate on LHDC builds

Input: the owner's capture asb_log_full_day_9563 (OnePlus 15, Smart, 4 h, test16), two
screenshots of the Per-link transport card, a tester with Mi Fitness reading "no fitness apps".

### Fitness apps & wakelocks
- The capture had Samsung Health's `PedometerLib` held in 64 % of samples (longest 33 min) with
  `WAKE_LOCK=ignore` in force and never DISABLED in dumpsys power: this ROM does not enforce the
  app-op for it, and the card said "ROM ignores it" with nothing left to do.
- New option `strict`: limit, plus `RUN_ANY_IN_BACKGROUND=ignore` (Android's "Restricted" battery
  setting) for exactly the apps the ROM was seen ignoring; old mode recorded in
  `wakelock_fitness_bg`, read back, re-asserted after ROM resets, handed back on protect, limit
  or uninstall. A strict app still holding the CPU is reported as `strict_ignored`.
- Watch and band companions (Mi Fitness `com.xiaomi.wearable`, Zepp, Huawei/HeyTap Health,
  Fitbit, Garmin Connect and the like) are never limited; one already on the ledger (Fitbit)
  gets its WAKE_LOCK mode back. The card shows which apps are limited, restricted, ignored by
  the ROM or kept as companions; a phone with only a companion reads "watch apps only - kept".
- Config shape updated (new option value; old values keep their meaning).

### WebUI
- Option lists in console cards (Per-link transport, Photo grading, Screen & touch): every box
  between the list and the page is lifted while it is open, so the list is no longer covered by
  the next panel or cut by the next section, and the glass-theme list is opaque (the value boxes
  underneath read through it).

### Carried from the previous in-progress note

Input: the owner's OnePlus 15 (CPH2745, ColorOS 17): `bt_ldac_rate=96` did nothing; 96 kHz
had to be picked by hand in Developer options. asbdiag showed the active link named
`LHDC V5 96000 Hz / 24-bit` by the Bluetooth stack while Settings called it LDAC and greyed the
LDAC quality item - the ROM numbers its codecs differently from AOSP.

- `src/btcodec`: the helper compared the codec type with the AOSP number 4 and stopped with
  `not_ldac` on this ROM. It now finds LDAC by the framework's own codec name (the ROM's
  `SOURCE_CODEC_TYPE_LDAC` constant when there is no name), and a fixed sample rate is asked for
  on whatever codec is active (LDAC, LHDC, ...) when the headset lists that rate for it; the
  LDAC quality still applies only to LDAC. Every result names the codec; a helper that dies at
  start writes the reason to its state file, its output goes to `bt_ldac.out`.
- `runtime/asb_bt_codec.sh` status shows the helper output and log; asbdiag prints the helper
  status with a live probe whenever either LDAC key is set. Card text (13 locales) and the
  advanced guides say the rate works on other codecs too.
- `src/asb_fsm.h`: the idle GPU trim lowers the GPU ceiling, which raises the load percentage
  of the same work; a single 12 % "interactive" threshold could flip the trim every poll near
  it. Now 12 % enters, the work stays interactive until the load falls below 9 % or 10 s pass.
- Telegram: the run link uses 🔗; release posts take sections (`@title`, `## header`, bullets,
  `@footer`) from docs/TELEGRAM_RELEASE.txt and are fitted to the 1024 visible-character caption
  limit by dropping bullets, never by cutting text; test posts are fitted the same way.

## V66-test16 - vendor CPU ceiling, LDAC sample rate, built-in Zygisk providers, tidier repository

Input: the owner's requests on top of V66-test15 - take the best of a third-party "factory
performance lock" module that does not coexist with ASB (it lifts the same ceiling), keep LDAC at
96/192 kHz after reboots like the LDAC quality card, fix the empty "How the verdicts are made"
fold on the Zygisk page, and make the repository front page shorter - plus a OnePlus 13 report.

### Vendor CPU ceiling (`cpu_vendor_unlock`, new)

- The other module showed two vendor ceilings above the kernel's own thermal limits: the ROM's
  values in `msm_performance/parameters/cpu_max_freq` (rewritten every 10-25 s by a vendor
  service; the prime cores held near 58-60 % of their maximum on some models) and the OPlus
  game-scene ceiling switched by `/proc/game_opt/disable_cpufreq_limit`. ASB already owned the
  first one only during its own HEAVY/GAMING registration; outside it the vendor value won.
- `runtime/asb_vendor_cap.sh` (sync|restore|status): `off|perf|always`, default `perf` (the
  Performance profile only; `always` never in Stock). Lifts the node to each CPU's own
  `cpuinfo_max_freq` (not the module's 9999999, so the read-back is exact), sets it 0444 so the
  non-root vendor writer cannot pull it back, switches the game-scene ceiling off, records the
  original value, mode and switch and hands all three back unchanged. While the lock is held a
  root write (the governor's own registration) is never overwritten. Another enabled
  ceiling module (oplus-cloud-block) makes ASB step back entirely. Qualcomm only; the
  MediaTek un-pinning and the module's own thermal daemon were not taken - ASB's thermal rails
  write scaling_max_freq independently and the kernel's thermal limits stay in force.
- Called at the end of every profile switch (worker and Stock finish), 60 s after boot and on
  the five-minute service pass; uninstall hands everything back. WebUI card under Heat &
  Performance (13 locales), asbdiag section 10 prints mode, ownership and the last log lines.
- Not measured on a phone: no claim of a speed or heat change yet.

### LDAC sample rate (`bt_ldac_rate`, new)

- `auto|44|48|88|96|192`. The dex helper (`src/btcodec`) takes the rate as a fourth argument,
  asks for it only while the codec is LDAC and only when the headset lists it among its
  selectable LDAC rates (otherwise keeps the current one and reports `rate_unsupported`), then
  reads rate and quality back. A fixed rate alone starts the helper; boot starts it for either
  key. The helper dex is rebuilt in CI.

### Zygisk

- WebUI: the page compactor moved every long note into the section's "Explanation" fold, so
  "How the verdicts are made" (and the other How folds) opened onto nothing. Notes inside a How
  fold now stay there, and its open state survives the page re-rendering.
- Park step, OnePlus 13 with a root manager that has Zygisk built in:


Report: a OnePlus 13 (KernelSU fork with a built-in Zygisk, LSPosed installed) on
V66-test14 and V66-test15: the Zygisk page said "no provider", the companion stayed WAITING and
the diagnostic showed `libraries : parked provider=present`.

- Cause: the boot-time park step (post-fs-data) looked only for a Zygisk provider module. A
  root manager with Zygisk built in has no such module, so ASB set its libraries aside on every
  boot; the later service-stage unpark could not help, because the next boot parked them again
  before zygote loaded them.
- `runtime/asb_zygisk_park.sh`: a provider is also recognised by module id (zygisksu and the
  known forks), by a name containing a known provider, and by any other enabled module that
  ships `zygisk/*.so` (for example LSPosed), which only loads where Zygisk runs. A sighting is
  remembered in `/data/adb/asb/zygisk_provider_seen`, so the boot step keeps the libraries in
  place; the service pass clears the mark when no provider is found, and the next boot parks
  them again (one boot of delay, the WebUI-hiding protection stays).
- `service.sh`: the five-minute pass refreshes the mark on its first boot run whether the
  libraries are parked or not. `uninstall.sh` removes the mark.
- Diagnostic: the libraries line adds `seen_before=`.
- Tests: `t_zygisk_park_runtime` covers the id match, a Zygisk-using module as evidence, a
  disabled one not counted, the remembered sighting and its clearing.

### Repository layout

- The front page listed 31 entries before the README. Moved to `docs/`: `README.ru.md`,
  `README.advanced.md`, `README.advanced.ru.md`, `RELEASE_MANIFEST.json`, and `banner.png` to
  `docs/assets/`. Links, the banner URL, the issue template, the source-tree guide and the doc
  test follow. Kept in place on purpose: the module files the root managers look for,
  `update.json` and `CHANGELOG.md` (their URLs live on installed phones), `banner2.png`
  (named in module.prop), `current_profile` and `features.conf` (runtime paths).

## V66-test15 - root WebUI keeps its headroom, AppOps reads, component disable

Input: a OnePlus 15R report on V66-test14 (the WebUI host was the most janky app, 9.1 %,
janking more with the main cores at the ceiling; every explicit WAKE_LOCK limit read back
"unknown") and the owner's notes on the Activity/Service manager and light-theme toasts.
Base: V66-test14. Native code changed: CI rebuilds `bin/asb`.

- **Root manager / WebUI:** back in the ordinary app class, so Smart no longer gives it the
  light-work lean; a separate flag still keeps it from latching GAMING on GPU load.
- **AppOps:** `appops`/`cmd appops` read from /dev/null: inside a `while read` loop over a
  ledger they could take the loop's input, and asbdiag printed "unknown" for every explicit
  WAKE_LOCK limit.
- **Activity/Service disable:** read-back accepts the class-only form Android prints (see the
  V66-test14 rebuild notes); light Liquid Glass toasts; 5 min WebUI calm.
- **asbdiag:** says one routine-touch lift per 30 s.
- **Telegram:** the post can be pinned with a notification (`telegram_pin`).


## V66-test14 - fewer touch lifts, wake lift on a warm phone, no false GAMING, calm WebUI

Input: tester logs on V66-test12/13 (Ace 6 PLQ110, OnePlus 15, 15R, 13R) - 247-946 unlock
lifts a day, 209 wakes on the Ace 6 left unlifted as "warm" while SystemUI drew 11-14 %
janky frames at the wake, five GAMING latches inside the KernelSU Next manager, and the
manager hosting the WebUI among the costliest screen-on apps (about 4 W). Base: V66-test13.
Native code changed: CI rebuilds `bin/asb`.

- **Activity/Service disable:** Android lists disabled and enabled components by class name
  only, while the read-back looked for package/Class, so every disable of a declared
  component read back "not enforced" and was rolled back. Both forms are read now.
- **Light Liquid Glass toasts:** dark ink on the pale pane; good/ok/warn/bad/error got their own
  colours instead of the grey fallback.
- **WebUI animations** pause after 5 minutes without input (and while hidden), not 10 s.
- **Telegram:** a link to the run, the request for asbdiag and the Infinite Log; releases go to
  the topic of message 2472 (Last Release), found by a silent reply that is deleted at once.
- **Routine touches:** one lift per 30 s instead of 20 s; wakes, the first touch, app
  switches, cold starts and lock presses keep their immediate paths.
- **Warm wake:** the warm-die veto for a wake, first touch, cold start or app switch sits
  6 C above `bat_comfort_temp`; routine touches keep the plain mark.
- **GPU-bound GAMING:** apps the package table names as light work (messengers, feeds) and
  root managers/WebUI hosts no longer latch GAMING from a busy GPU.
- **WebUI:** looping animations pause after 10 s without input or when the page is hidden;
  loading scenes keep moving.
- **Telegram:** test builds post to topic 4 (Test) of @AutoSystemBoost by default; secrets
  override the chat and topic.


## V66-test13 (rebuild) - component picker, single dock, instant Infirmary, LDAC quality, log-driven fixes

Input: six requests on top of V66-test15 (Infirmary description fold, double dock on the Zygisk
page, choosing Activity/Service from the app list, an instant Infirmary, a forced LDAC quality,
then module improvements from the 22.11 logs). The owner asked for this build to be numbered
test13 again: a run is not a new test number unless the owner says so. Base: V66-test15.
Native code changed (Smart lab build id): CI rebuilds `bin/asb`. A new Java helper is built
to `bin/asb_btcodec.dex` by CI with the runner's Android SDK.

- **Activity/Service card:** a one-line summary, two status rows and two normal-size buttons
  (Choose an app, Saved changes) instead of one full-width button; the long text stays under More.
- **Zygisk page colours:** Switch on is green, Switch off and Undo all red, A/B test violet,
  Lighten amber; Read again is a dashed refresh button; evidence folds (ASB changes, What Smart
  learned) are tinted rows with a chevron, so they no longer look like the action buttons.
- **Installer banner:** no list of five models; it now says OnePlus phones and tablets,
  Snapdragon and Dimensity.
- **Telegram:** Build Test can post the flashable zip to a Telegram channel when the
  `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` secrets exist (input `telegram`, on by default).
- **Infirmary:** the Activity/Service card description sits under "More".
- **Components from the app list:** the component manager has "Choose from installed apps";
  an app opens its per-app list, where declared Activity/Service entries can now be disabled
  (second tap, read-back, the same restore ledger) through the manual path.
- **Docks:** only the top page shows its dock (Settings < report < device < Zygisk), and a
  second dock of the same kind is removed when a page renders again.
- **Infirmary opens at once:** the four status reads (cleanup, Battery Fix, SOTER, the log
  digest) were synchronous root calls inside the render; they now run one by one after the
  page is on screen, the digest last. Battery Fix polls only while the Infirmary is open and
  visible, every 15 s instead of 8 s when idle.
- **LDAC playback quality:** new `bt_ldac_quality` (auto|990|660|330|abr). A small
  `app_process` helper (`runtime/asb_bt_codec.sh`, `src/btcodec`) sets the same codec
  preference as Developer options, only while the active codec is already LDAC, and reads it
  back; it stays resident and re-applies after reconnect/codec events. Auto stops it.
- **Fitness ledger:** apps that are no longer installed are dropped from the WAKE_LOCK
  ledgers instead of being retried and reported as "appops transport unavailable".
- **Display/UI keys:** explicit values are re-asserted once more 90 s after boot, because the
  ROM resets `oost_navigation_handle_auto_hide` after ASB's early pass.
- **Smart lab:** a rebuilt kernel of the same version no longer reopens every decided
  setting; a new kernel version or ROM fingerprint still does. Stores written with the old
  id are migrated without a retest.


## V66-test15 - every OnePlus by model code, Zygisk and report panels

Input: the owner's list of OnePlus phones and tablets that must be recognised, the Zygisk
header dot that only animated from the second WebUI open, and design requests for the Zygisk
page, Settings -> Zygisk, the Infinite Log report and the Easter egg. Base: V66-test14.
No native code changed; no CI rebuild of native parts is needed.

- **Device table:** new `runtime/asb_device_db.sh` maps every retail OnePlus model code
  (198 codes: phones from the One to the 16 and Ace 7 series, Nord, Nord CE, N series,
  the Open, every Pad) to its name, codename and form factor, and the SoC (Snapdragon and
  Dimensity, by `ro.soc.model` or platform codename) to its name and class. Source of the
  codes: the MobileModels list. The installer prints device and chip, `service.sh` logs
  them and uses the class instead of "generic", the Device page shows model family, form
  factor, chipset and class, asbdiag prints both lines.
- **Detection fix:** `PJZ110` is the Chinese OnePlus 13, not a OnePlus 15. It selected the
  full OnePlus 15 overlay; it now selects the OnePlus 13 one. The OnePlus 15 patterns match
  only CPH2745/2747/2749 and PLK110 (the 15R's CPH276x never matched them).
- **Zygisk header dot:** the pulse is created once and only paused or resumed; creating it
  when the first verdict arrived during the startup slide could leave WebView on a frozen
  frame until the next open. A cached verdict is dimmed by colour, not by stopping the
  animation.
- **Dock shadow:** 36 px instead of 66 px, so it stays behind the lower half of the dock.
- **Zygisk page:** the guard, ART and engine cards use the LSPosed item panels (name,
  coloured badge, chips, actions) and fold their long explanations under one "How it works".
- **Settings -> Zygisk:** a console like DSP: master state in the header, the link verdict,
  the master switch and the three features in separate panels, a full-width ZYGISK button.
- **Report:** the dock has its own short labels without emoji and a different icon for every
  section; priority actions and wake holders are framed panels.
- **Easter egg:** the flying saucer starts at the size of the header saucer and grows up to
  about three times that in flight.

## V66-test14 - WebUI without a Zygisk provider, wider content

Input: the owner removed the Zygisk provider and could not open the ASB WebUI any more; the
content also looked narrow with empty space at both sides. Base: V66-test13 (`36ca527`).
No native code changed; no CI rebuild of native parts is needed.

- **Cause:** KernelSU-Next's manager treats a module whose `zygisk/` folder has files as
  "Zygisk required" and, while no Zygisk runs, hides its WebUI and action buttons and greys
  its switches (`filterZygiskModules` in its module screen). ASB ships its observer libraries
  in `zygisk/`, so without a provider the whole module UI was unreachable.
- **Fix:** new `runtime/asb_zygisk_park.sh`. At post-fs-data (before zygote and before the
  policy sync) it renames `zygisk/` to `zygisk.off/` when no Zygisk is enabled (no enabled
  module with `bin/zygiskd` or a known provider name, no Magisk built-in Zygisk) and back
  when one is. The once-after-boot service pass only brings the folder back, never sets it
  aside, so a provider still running before its removal keeps ASB's libraries. The Zygisk
  scripts follow the parked folder; the provider section shows "ASB Zygisk libraries"
  (4 keys, 13 locales); asbdiag prints a `libraries` line; the module card says
  "no provider". A provider installed while the libraries are parked may load ASB's part
  from the reboot after it.
- **Wider content:** pages fill the 440 px reference width and the side padding is 10 px
  instead of 20 px (cards gain about 40 px); the header keeps its former inset. The UI scale
  is unchanged.

## V66-test13 - honest screen drain, quick Zygisk header, LSPosed card, tweak consoles

Input: V66-test12 on the owner's OnePlus 15 and a user's asbdiag (V66-test11, Magisk,
CPH2769). Base: V66-test12 (`86686aa`). No native code changed; no CI rebuild of native
parts is needed.

- **Screen drain stuck at "<59.9%/h":** after charging, a 10-minute screen session with no
  battery-level step was shown as an upper bound and kept winning. The meter no longer
  stores a session without a step (`dm_on_finish` needs one), and the WebUI uses the latest
  session only with two steps, or one step over at least 30 minutes; otherwise it falls back
  to the history average or "measuring". Note text updated in 13 locales.
- **Zygisk header dot grey for long:** its probe ran at a priority that waits while any page
  is open. It now runs at priority 0, detached, and the last answer (up to 6 h old) is
  painted at once, dimmed until the fresh one arrives.
- **Bottom shadow:** the dock scrim is 66 px instead of 92 px with a shorter gradient.
- **LSPosed: modules and their cost:** rebuilt as per-module panels with a coloured verdict,
  chips for scopes, reach, background starts and crashes, and an actions row; the how-it-works
  text folds away (keys `lsp_how`, `lsp_chip_crash`).
- **Consoles:** the DSP console became a generic `cfgRenderConsole`; new consoles for camera
  processing, network channels and screen/touch, with a category-coloured rule and tinted
  group labels (16 new keys, 13 locales).
- **ART for the other user:** that asbdiag is V66-test11, the build with the parse problem
  fixed in V66-test12; updating is the fix.

## V66 dev66 buildfix46 - the ART script runs on the phone's shell

Input: buildfix45 (V66-test11) on the owner's OnePlus 15 and a user's phone: the Faster app
starts (ART) switch still failed and the card stayed unread. Base: buildfix45 (`2d06afd`).
No native code changed; no CI rebuild of native parts is needed.

- **Evidence:** the owner's asbdiag of V66-test11 (16:25, KernelSU, Android 17) prints
  `launch_art : enabled= charging= compiling= launches_recorded= apps=0` - every key empty.
  asbdiag runs `asb_zygisk_aot.sh status`, whose first line is an unconditional
  `version=1`, so the phone's `/system/bin/sh` produced no output at all from this script,
  while the guard and link scripts beside it answered in the same report. A script that
  prints nothing before its first command is one the shell refused to parse. The buildfix45
  change (answer at once) could not help: the result line never came.
- **Cause (most likely, not reproduced on the phone):** `_launch_scan` was the only place in
  the module with a quoted case pattern and a `${var%...}` pattern that span two lines
  (`*'<newline>#ev')` and `"${_new%<newline>}"`), and with `${_new%#ev}`. Host mksh R59c,
  dash and busybox accept it; Android ships mksh R59 2020/10/31, whose lexer for patterns
  and word ends was rewritten afterwards. Building Android's mksh on the host was not
  possible here, so this is the one construct that differs, not a confirmed parse error.
- **Fix:** the launch scan writes awk's output to a per-process file
  (`zygisk_aot_launch.scan.<pid>`), detects the events-buffer marker with `grep -x` and
  appends from the file; no multi-line pattern, no `%` trim and no large shell variable
  (the old `printf '%s\n' "$_new"` also passed the whole scan as one argument, the E2BIG
  case under mksh).
- **If it still fails, it says why:** asbdiag prints `NO ANSWER from asb_zygisk_aot.sh
  status` with the shell version and the first lines of `sh -n` (or of the run's stderr);
  the WebUI read-back after a failed switch keeps the script's stderr and shows its first
  line in the toast and on the card (new key `zy_aot_no_answer`, 13 locales).

## V66 dev66 buildfix45 - the ART switch answers at once

Input: a user report, "cannot turn on faster app starts": the Zygisk page's Faster app starts
(ART) switch showed "Could not change the mode" and the card stayed at "The compile state has
not been read yet." Base: buildfix44 (`e8f3a02`). No native code changed; no CI rebuild of
native parts is needed.

- **Cause:** `asb_zygisk_aot.sh enable` printed `result=enabled` only after a full pass:
  Android's launch log (`logcat -d` of the events buffer, the main buffer as a fallback),
  the start-ledger count and an ART state read (`dumpsys package`, then `pm art dump`) for up
  to eight apps. All of it ran inside the one `ksu.exec` call that holds the page, and the
  page read the result and the status from the same shell; when that shell ended without
  its marker lines, both came back empty, so the switch reported a failure and the card
  stayed unread even though the flag file may already have been written. Not reproduced on
  the owner's phone; the long synchronous pass is the only slow step on this path.
- **Fix:** `enable` writes the flag and answers at once; the launch scan, ledger count and ART
  reads run in a detached `refresh` (also reached by the five-minute service tick if a
  manager ends background jobs with its shell). `ASB_ZA_SYNC=1` keeps the old synchronous
  order for the host tests. A failed flag write now answers `result=failed`.
- **WebUI:** when the switch result is missing, the page reads the status once more and
  accepts the change if the saved state matches the request; only then does it report a
  failure. The success check now matches the requested direction (`enabled` for on,
  `disabled` for off).
- **Tests:** host regression for the detached enable (answers within 2 s while the launch log
  takes 3 s; the detached pass still fills the list).

## V66 dev66 buildfix44 - detached status reads, drain with charging, DSP console, docks

Input: owner review of buildfix43 on the phone (eight items plus the screen-on drain figure,
the loader emblem and the report dock). Base: buildfix43. No native code changed; no CI
rebuild of native parts is needed.

- **Camera exit and Kernel entry:** every `ksu.exec` call holds the page's JavaScript thread
  until its script ends. Camera ran `asb_camera_tools.sh status` (an ART dump of the camera
  app, `pm list packages -d`, `svc usb`, intent resolution) right after the entrance, so a
  Back tap waited for it; Kernel started `asb_kernel_controls.sh status` and the wakeup-source
  scan inside the first render, before the category was painted. Both reads (and the Active
  profile read) now run detached into a `/dev/.asb_ui_*` file; the page asks for the file in
  short spaced checks, so taps and the slide are served between them. Kernel starts its read
  after the entrance and shows "Checking…" until then. If a manager kills background jobs,
  two empty checks fall back to one direct read. Not timed on a phone.
- **Zygisk header dot:** the automatic jank fallback (`data-asb-effects="reduced"`) still set
  `animation:none` on it, so after three slow frames it stood still for the session, the same
  cause as the Smart halo in buildfix42. The fallback now only drops its glow ring; OS
  reduced motion still stops it.
- **Screen-on drain with charging:** the since-boot meter added charging time with the screen
  on to its divisor while the drop counter skipped it, so charging lowered the rate. The boot
  file gained five fields: discharging screen-on seconds (the new divisor) and the active
  profile's own this-boot seconds, hundredths, name and start; a profile switch restarts the
  profile part. A seven-field file from an older meter keeps its meaning.
- **Which figure is shown:** a 12-minute session that dropped two whole percent read
  10.4 %/h while the same profile had measured 6.8 %/h over 1 h 45 min in the Infinite Log;
  one battery-level step moves a short session by half. When the meter has the profile's own
  this-boot total (30 min and 3 % at least) and it covers at least as much time as the latest
  session, that total is shown, headed "since boot" or "since profile switch". Checked on
  the owner's capture of 12:30-14:37 (`battery_trace.txt`): the meter's own rule (screen-on
  intervals up to 90 s, steps of 1-5 %) gives 12 % over 92 min = 7.8 %/h there, while the
  stored 11.5-minute session read 10.4 %/h.
- **DSP console:** the twelve DSP controls are one card with three labelled panels (output,
  tone, dynamics and protection) of compact rows in the Parametric EQ's style; each row keeps
  its write path and opens its description on tap.
- **Active profile sheet:** the profile name is no longer repeated under the title; the loader
  stands on the sheet without a second frame, with outline-free stage pills, and its read is
  detached so the emblem keeps moving.
- **Icons and emblem:** the Infirmary "Activity and Service" card has its own component icon
  instead of the Zygisk one. The loader scene and the header emblem are drawn larger with a
  transform, so nothing under them moves; the emblem change applies to the header of every
  page (Home, Monitor, Settings, report, Device, Zygisk), compact fit modes included.
- **Bottom docks (report, Zygisk, Device, categories):** buttons share the dock width and wrap
  a long name to two lines instead of cutting it at the edge; they scroll sideways only when
  the minimum width no longer fits. A fixed fade under the dock hides cards scrolled beneath
  it. A tapped section keeps the highlight while the page jumps, and the indicator is
  re-measured on resize.
- **Locales:** 8 new keys and the updated drain note in all 13 locales.

## V66 dev66 buildfix43 - CI test fix, softer loader beam, since-boot drain after a reboot

Input: the failed "ASB · Build Test" run 44894672322 on buildfix42 (shard system-smart:
`io_scheduler_ab_runner_buildfix37`, "dm-0 restore after fio failure"). Base: buildfix42.
No runtime script or native code changed.

- **Cause:** the test emulates sysfs with a background loop that rewrites a plain scheduler
  name into the kernel's bracketed form every 10 ms. A read that fell between the runner's
  truncate and its write saw an empty file and wrote a line with no active scheduler, and on
  a loaded runner the loop could miss the runner's 200 ms readback window. Locally the test
  failed about one run in two under mksh and intermittently under bash; earlier CI runs
  passed by timing.
- **Fix:** the emulator skips empty reads, and the runner's readback budget can be raised
  from the environment (`ASB_IO_AB_READBACK_TRIES`, 1-1000, default 20 = 200 ms, unchanged
  on the phone); the test uses 500.
- **Verification:** 96 of 96 runs passed with eight copies in parallel, half under bash and
  half under mksh.
- **UFO loader beam:** the scan band of the loading screen (Active profile, Device, Zygisk)
  ended in a hard line (alpha .32 falling to 0 over 2 % of its height) with square sides, so
  it read as a green slab. It now peaks at .18 and fades out at the top, bottom and both
  sides (a horizontal mask), checked frame by frame in Chromium.
- **Screen-on drain after a reboot:** buildfix42 named the source correctly, but the figure
  itself stayed the 17.0 %/h, 123-minute Smart session recorded before the reboot, on the
  Monitor and on the Smart card, an hour after the reboot. For the active profile a mature
  since-boot figure (15 min with the screen on and 2 % of drop) now wins over a stored session
  that began before this boot (`on_last_at` against `/proc/uptime`) or over the all-time
  average. A session recorded during this boot still wins, because the boot meter is
  phone-wide and can include another profile's time; before maturity the stored sample covers
  the first minutes, as buildfix32 intended. Other profiles' cards keep their own samples.

## V66 dev66 buildfix42 - instant sheets and tabs, honest drain labels, EQ panel, Smart halo

Input: the owner's screenshots and seven requests. Base: buildfix41. WebUI only; no runtime
script, native source or binary changed.

- **Kernel category:** the summary line and "Hidden: N" now sit behind Details with the rest of
  the explanation; the card keeps only Details and the two actions.
- **Parametric EQ under Liquid Glass:** the theme's row material
  (`html:root[data-asb-glass] .cfg-row:not(.is-on)`) is more specific than the EQ editor's
  reset, so every slider row was repainted as a full-width card and the names (Frequency,
  Q × 10, Gain) and values touched its edges. The three sliders now sit in one inset panel
  with 12 px side padding and hairline separators, and the reset outranks the theme in both
  themes (checked in Chromium, dark and glass).
- **Active profile sheet:** it opened only after `asb_profile_details.sh` and
  `asb_effective_policy.sh` had finished, because the read started in the same task and
  `ksu.exec` blocks the page thread. The sheet now opens on the tap with the ASB UFO loader
  (the Zygisk page's), and the read starts after the loader has painted; a sheet closed
  before that never starts it.
- **"Current transaction not exposed · saved history":** the pill under the profile name read
  as an error. It now says where the figures come from: "From the apply log".
- **Tab switching:** every background read on Home blocks the page thread for its whole run,
  so a tap that arrived meanwhile waited for it. Home read the kernel controls together with
  every wakeup source and the camera flags 450 ms after start, outside the idle queue, only
  to label two Settings tiles. Those tiles now use the last answer this viewer saw (kept in
  its own storage) and the category refreshes it when opened; with no answer yet the read
  waits in the idle queue. Background jobs above priority 0 start only after 1.5 s without
  a touch (was 300 ms), the 30 s Home refresh likewise, and a Monitor poll waits 0.9 s after
  a touch. A browser model with a blocking bridge freed the page about 2 s earlier after
  start; the real gain depends on how long each script takes on the phone.
- **Battery drain sheet:** a mature profile session wins over the since-boot estimate
  (buildfix32), but it kept the "since this device boot" caption, so 30 minutes after a
  reboot the sheet showed "since boot: 123 min" (a session recorded before the reboot), next
  to a table of profile averages headed "the same measurement for each" (14.8 %/h against
  the 17.0 %/h above). The heading and sentence now name the source (latest session, since
  boot or profile average), the table is headed "average of each", and the footer explains
  the order and why the two can differ. The Russian footer had also claimed "since boot".
- **Smart halo:** it paused after ten idle seconds (calm) and under automatic reduced effects,
  and stood still as a half-lit ring that looked like a frozen icon. It now keeps turning
  while Home is visible; it still stops behind another page and under the OS reduced-motion
  setting.
- **i18n:** `lv_drain_on_avg_tip`, `lv_scr_on_avg`, `lv_drain_cmp_avg`, `lv_drain_note_src`,
  `pd_loading_title`, `pd_stage_intent`, `pd_stage_owner`, `pd_stage_readback`;
  `pd_epoch_unavailable` reworded. 13 languages.
- **Tests:** `t_webui_buildfix42_owner_review`; the profile-sheet test (the read now starts
  after the loader frame), the hub, battery-meter and dev61 harnesses follow the new structure.

## V66 dev66 buildfix41 - review fixes: large dumps under the Android shell, core components

Input: a review of the buildfix40 source archive. The full host regression passed, so the
review also ran it with `sh` resolved to mksh, the shell Android ships as `/system/bin/sh`.
Base: the buildfix40 source archive. No native source or binary changed.

- **Large dumps lost under mksh:** Android's mksh has no built-in `printf`; it runs the
  toybox binary, and one argument longer than 128 KiB fails with `Argument list too long`.
  Scripts started from the WebUI or by the governor (`system()`) normally run in that shell. Several readers
  stored a whole dump in a variable and handed it to `printf`: the batterystats cache of the
  wakelock watcher, `dumpsys package` for the component manager (state, declared
  components and the read-back after a disable), the LSPosed logs (up to 2 MiB) and the
  Zygisk launch scan's event log. Past the limit the reader saw nothing: a component of a
  big package (the dump of Google Play services can pass 1 MB) could not be disabled because the
  read-back came back empty and the change was rolled back, and the LSPosed log rate read
  `unknown`. These readers now go through a here-document or a pipe. asbdiag's dropbox
  listing and the full-day recorder's refresh-rate probe keep only the lines they parse.
- **Core framework components:** the component manager accepts system packages since
  buildfix28. A disable on the framework, SystemUI, telephony, the settings provider, the
  permission controller, the package installer, the network stack, Bluetooth, NFC or the
  root managers is now refused (`result=protected`) before `pm` is called; a disabled
  component there can leave the phone without a usable interface to undo it.
- **Small fixes:** the fitness note now records `appops transport unavailable` when the
  transport fails (the old fallback sat after a pipeline whose status is always zero); one
  mis-indented line in `service.sh`.
- **Tests:** `t_large_dump_argv_runtime` feeds 300 KB package and batterystats dumps and
  checks the protected refusal; under mksh it fails on the buildfix40 script and passes now.
  The log-report trend check accepted only `elapsed=2866`, a value that moves to 2867 when
  the suite runs about 20 s slower; it accepts both.
- **Repository:** the stray `config/V66_BUILD_HISTORY.md` copy (235 KB) is removed. The
  release workflow copies `config/` into the module, so it was shipped to the phone.

## V66 dev66 buildfix40 - evidence truth, report navigation and lighter Home startup

Input: the owner's nine-point screenshot/log review covering observed wakeup rules, the EQ outer card, Infinite Log references/order/spacing/activity context, false Home drain units/rates, startup responsiveness and the fresh OnePlus 15 captures. Base: the verified buildfix39 source archive.

- **Wakeup evidence separated by owner:** observed source rows now explicitly describe raw kernel event/activation/time deltas. A growing raw counter is not presented as proof that blocking failed. Saved Always/screen-off rules are compared with current kernel readback; active rules show their per-rule blocked count or `not exposed`, sleep-only rules are marked inactive while the screen is on/unknown, and a saved rule missing from readback is named as a mismatch. Exact-name matching, the 16-rule bound, screen-off window, Safe mode and the runtime blocker itself are unchanged.
- **EQ returned to a complete ASB row:** Parametric EQ uses the ordinary `cfg-row` outer material and bounded descendants. The seven editing outputs and atomic grouped writes from buildfix39 remain intact. Real Chromium measured the card exactly inside its list at 320, 392 and 440 CSS px with no descendant, page or document overflow.
- **Infinite Log navigation and hierarchy:** evidence references and dock buttons stop click propagation, so they navigate instead of opening the containing row's detail sheet. References use the containing page's scaled scroll geometry and synchronize the dock. Detailed sections are reordered by evidence domain, and the dock is generated from the sections actually rendered in that same order.
- **Boundary-only activity context:** the existing full-day recorder captures only Android's resumed/focused component when an active/post-wake phase opens and closes. Closed phases of at least five minutes with a positive drop and a rate of at least 8%/h are projected into at most five report rows. The report names start/end components, duration and measured phase drop, while explicitly stating that boundary correlation is not causal per-activity energy attribution and that freezing can break the app. Unknown/malformed components stay `unknown`; no account, intent, extras, title, persistent poller or new digest-time `dumpsys` call was added.
- **Consistent context spacing:** scenario, duration and current-capture pills now share one wrapping flex group with a 6 px gap and no per-chip margins. Similar report references retain the common chip/dock layout rather than local coordinate corrections.
- **Home truth and startup cost:** `on_last` is converted from accumulated hundredths of a percent over the completed session's seconds into the UI's x10 `%/h` value, eliminating the false `50.0%/h` example without clamping real high readings. The first cached paint selects the already-known language's unit before the locale dictionary resolves, including Russian `%/ч`. The once-per-boot intro warms only Home Live data instead of concurrently starting Config, Device, full Log and Zygisk collectors; duplicate meter reconstruction is avoided when a fresh meter was already painted. No persistent WebUI worker was introduced.
- **Fresh-log boundary:** the supplied capture shows 14% over 7 h 48 min (1.8%/h), 59 screen-on minutes at 9.1%/h, 6 h 49 min screen-off at 0.7%/h, 77% deep sleep, 1.5% janky frames and a 51°C CPU peak. It does not justify universal governor, thermal, scheduler, wakeup or frequency changes. The safe runtime change here is reduced WebUI startup contention; no unverified kernel tuning or improvement percentage is claimed.
- **Verification:** focused fixtures cover valid/malformed/threshold-filtered activity rows, the five-row cap, raw-versus-blocked wakeup states, screen-off-only inactivity, reference click propagation/scroll destination, semantic section order, initial Russian units and latest-session conversion. The complete UI suite passed 161 anchored PASS lines with zero FAILED. Real Chromium exercised EQ at three widths, seven outputs, report order/dock/reference scrolling, uniform context-pill spacing and Russian Home values with zero page/console errors. Browser/host evidence is not physical ColorOS WebView validation; the staged and exact-archive clean-unpack release gates are recorded in `RELEASE_MANIFEST.json`.

## V66 dev66 buildfix39 - native ASB EQ styling and seven editing outputs

Input: the owner's screenshot review rejecting the separate coral EQ appearance and clipped controls, and requesting the same output choice as the DSP routing selector. Base: the verified buildfix38 source archive.

- **Back inside the ASB design system:** the compact console now uses the active `--accent`, ordinary ASB surfaces, borders, radii and spacing. The coral colour and visually separate sub-card treatment are removed; the response preview and selected-band editor remain in one surface.
- **Clipping fixed at its owner:** the generic range row's 57 px left margin was still applied inside the EQ grid. It is now reset only for `.dsp-eq-editor .cfg-range`, leaving ordinary settings untouched. The editor remains `overflow: visible`; the fix does not conceal excess content with a clipping rule.
- **Seven editing outputs:** All, Speaker, Wired, BT, Speaker+Wired, Speaker+BT and Wired+BT use the existing `dsp_outputs` labels in a compact disclosure selector. `off` is deliberately absent because it is a DSP routing state, not an EQ profile. Combined outputs are editing groups, not new audio routes; the three physical Speaker/Wired/BT profiles remain independent and runtime routing still follows `persist.asb.dsp.route`.
- **Atomic grouped edits:** when a combined output is selected, changing frequency, Q or gain adds the corresponding keys for every selected physical profile to the existing `set-many --snapshot` transaction. The editor and preview show the group's first physical profile; no new writer, polling worker or sequential partial-write path was added.
- **Verification:** source contracts require the seven-target list, primary-route controls, atomic group fan-out, native styling and the scoped zero margin. Real Chromium exercised all seven outputs and all three bands at 320, 392 and 440 CSS px, plus All, Speaker+Wired, Wired+BT and Speaker+BT grouped gain writes. Every grouped write used one atomic command and changed only its selected profiles; no descendant/page overflow or JavaScript errors remained. Open and closed states were screenshot-reviewed. Browser/host evidence is not physical ColorOS WebView validation.

## V66 dev66 buildfix38 - compact parametric EQ console

Input: the owner's device screenshot showing the new per-output EQ split into a long stack of ordinary setting cards. Base: the verified buildfix37 source archive.

- **One working surface:** the output selector, static response preview, Low/Mid/High selector and the three controls of the selected band now share one compact console. The other bands remain independently stored and reachable through the band tabs instead of consuming nine separate cards.
- **Live response preview:** a static SVG curve is calculated from the three RBJ peaking filters of the selected output. During a drag it uses an explicit draft-only value map; it never mutates the saved configuration before the existing safe writer succeeds. There is no animation, timer, canvas, polling worker or additional root read.
- **Existing control ownership retained:** frequency, Q and gain still use the common drag-only slider and `cfgSet()` live-write path. Output changes immediately rebuild the console for that output. All 27 output/band values, snapshots, localization and DSP runtime behavior remain unchanged.
- **Post-reboot drain truth:** a since-boot screen-on figure now requires at least one observed battery-level step. The former no-drop upper bound could become a misleading 100%/h and a false time-to-empty forecast; both now wait for evidence. The meter's accumulated on/off duration is additionally rejected when it exceeds kernel `/proc/uptime` plus the sampling tolerance.
- **Verification:** dedicated contracts require the single console, both selectors, exactly three reused controls and draft-only plotting, reject a stale 43-minute boot file at five-minute uptime, retain a real one-percent measurement and reject the synthetic no-drop rate. Real Chromium at 392 CSS px exercised Speaker to Wired, High-band selection and a `dsp_eq_wired_b2_g` write, with one panel, no horizontal overflow and no JavaScript errors; both visual states were screenshot-reviewed. Browser/host evidence is not physical ColorOS WebView validation.

## V66 dev66 buildfix37 - advanced DSP, scheduler A/B evidence and clearer Zygisk wording

Input: the owner's request for the five proposed DSP improvements, one-shot I/O scheduler A/B, the recommended CPU-scheduler path, and clarification of the independent Zygisk profile and automatic-app-selection state. Base: the verified buildfix36 source archive.

- **Advanced-v1 shared DSP core:** the AIDL and legacy effects share a 4x eight-tap inter-sample peak detector, bounded fixed look-ahead (0–10 ms with an explicit insufficient-ring fallback), three independent three-band parametric EQs for Speaker/Wired/Bluetooth, and a 20 Hz second-order DC/infrasonic high-pass. Bypass, zero-gain PEQ, reset, ACCUMULATE and softclip paths are covered. Runtime property mirroring includes route-aware PEQ values and wakes the existing attacher without adding a polling worker. Diagnostics expose the capability marker, configuration and available counters; a marker is not runtime proof.
- **WebUI and persisted configuration:** the new DSP controls are live Audio settings, with independent output/band snapshots, ownership rows, defaults and 13 locales. Existing stored values are not reset. The native configuration reader's bound is raised to 1024 keys so the 278-key file retains headroom.
- **One-shot I/O scheduler A/B:** `tools/asb_io_scheduler_ab.sh` compares only physically exposed candidates under common exposure, interleaves new-file-only `fio` rounds, records p50/p95/p99, uses a bounded lock/readback, and restores each original scheduler exactly. It never selects a winner automatically and refuses unsafe paths, busy runs and failed measurements.
- **CPU scheduler boundary:** the existing measured-only BORE off-to-on comparator remains the supported comparison. It requires identical kernel/root/SusFS/ASB/workload identity and reports measured or not-measured evidence without improvement claims. No sched-ext or second interactive scheduler was added. No kernel patch is claimed without a kernel source tree and `git apply --check` validation.
- **Zygisk terminology:** Battery/Performance/Auto remains the selected profile. The separate card is now explicitly named Automatic app selection, its enabled/disable labels say the same, and the summary starts with Profile rather than Automatic profile. Mode selection and automation logic are unchanged.
- **Separator hierarchy:** decorative grey rules were removed from standalone Zygisk actions, the Device guide and metric-sheet current/history/source/pressure regions; spacing now carries those boundaries. Genuine report/list row separators remain. This changes presentation only and adds no runtime worker or root call.
- **Battery Fix package-scoped recovery:** a rejected forced `cmd package compile` now falls back to forced `pm compile`, then both ordinary package-scoped commands without force. Any explicit `Success` completes that package; a complete refusal retains the first sanitized Android response, and the UI actually substitutes it for `{err}`. Rejected/unprocessed packages are not counted as compiled. Aggregate `-a`, direct dex2oat, ART/Dalvik cleanup and fabricated success remain forbidden.
- **Verification:** numerical host fixtures cover true-peak reconstruction, exact/fallback delay, DC/PEQ responses, sample ceilings, counters and reset; runtime/UI contracts cover both ABIs, live mirroring, 13 locales, snapshots, ownership and the Zygisk wording. Scheduler fixtures cover failure, busy-lock and exact-restore paths. Focused contracts cover the four package-scoped compile variants, partial success, literal-token removal, decorative-line removal and retained semantic list boundaries. The full staged and exact-archive clean-unpack regressions are release gates recorded in `RELEASE_MANIFEST.json`; earlier intermediate PASS counts are not release proof. Browser/host results are not physical ColorOS WebView validation, shipped old DSP prebuilts are not represented as advanced-v1 rebuilds, and no universal performance or battery improvement is claimed.

## V66 dev66 buildfix36 - remove tweak-category subsection explanations

Input: the owner's request to remove the prose beneath subsection headings throughout the tweak categories, including Charging, Camera Tools, Photo Processing and Diagnostics. Base: the verified buildfix35 source archive.

- **One complete presentation removal:** all 23 `hintKey`/`hint` definitions are removed from `CFG_GROUP_SECTIONS`, covering Audio, Battery, Network, Zygisk, Display & Haptics, System Services, Diagnostics, Camera, Interface and Infirmary. `cfgRenderSection()` now emits only the icon and localized title; it no longer creates a `.cfg-section-hint` node. Existing locale resources are retained harmlessly for history compatibility, while per-setting descriptions, safety warnings, status evidence and custom repair/tool cards remain unchanged.
- **Regression boundary:** a dedicated source contract rejects subsection-hint definitions and their renderer while requiring the ordinary setting-row description path to remain. Existing buildfix35 and earlier UI contracts remain active. No runtime policy, native source, binary, workflow, audio processing, camera processing or kernel behavior changed; host/browser checks are not physical OnePlus 15/ColorOS validation.

## V66 dev66 buildfix35 - coherent metric sheets, compact docks and Binder recovery

Input: the owner's twelve-point WebUI follow-up, followed by a request to simplify the Slot sheet and remove the optional-DSP explanation from Audio. Base: the verified buildfix34 source archive.

- **Monitor information hierarchy:** all common metric sheets keep values, scales, pressure, history and sources visible, with the Explanation disclosure moved after the evidence and restyled without nested grey strips. Battery-drain basis text is always visible and no longer creates disclosure tabs. Slot is intentionally simpler: no scale bar and no folded explanation, just its current time-based value and direct prose. Smart's adaptive-policy paragraph has its own compact disclosure.
- **Compact navigation and consistent actions:** the Infinite Log dock retains only Summary, Actions, conditionally Battery, and Details. Zygisk has six top-level destinations; Unified engine and LSPosed share one card while the internal `zy-lsp` anchor remains. Device diagnostics receives the same Back, Logs and Telegram actions as Zygisk. Kernel has one shared Refresh action in its compact initial card, not a duplicate in wakeup rules.
- **Zygisk and Infirmary cleanup:** Automatic setup has one title and a state-aware badge instead of unconditionally claiming to follow the selected mode. The two final package repairs no longer carry the reversible-system-fix kicker. The Audio DSP section no longer renders `cfg_audio_section_dsp_hint`.
- **Stable initial drain:** a mature per-profile screen-on sample now takes priority over the coarse since-boot estimate; the latter remains only a fallback. No number is hardcoded and no display delay was added.
- **Battery Fix Binder recovery:** after the bounded package-scoped `cmd`/`pm compile` refusal streak, the worker tries Android's standard `cmd package bg-dexopt-job`, then `pm bg-dexopt-job`. Accepted scheduling is reported as scheduled, not as verified speed-profile compilation. If both refuse, the UI gives a concise honest refusal without raw Binder transaction text; unprocessed apps are never counted as compiled. Aggregate `-a`, direct dex2oat and ART/Dalvik cleanup remain forbidden.
- **Bounded transition compositing:** backdrop sampling and shadows are suspended only during the existing page slide through one bounded class/timer. No persistent worker, polling loop or speculative root call was added.
- **Verification boundary:** targeted shell/Node contracts cover both background recovery channels, final refusal honesty, source priority, Slot/Audio presentation and all changed structures. HTTP-served Chromium verified Zygisk order/dock, metric/disclosure order, always-visible drain prose, Device actions, one Kernel Refresh, no horizontal overflow and zero page/console errors. The staged canonical source-only regression passed 441 suites/test cases with 588 anchored PASS lines, zero FAILED, lint 0 errors/0 warnings, native strict warnings 48 against budget 62, and GCC new=0 / resolved=12 / baseline_sites=60. This is host/browser evidence, not physical OnePlus 15/ColorOS WebView validation and not a measured performance or energy improvement.

## V66 dev66 buildfix34 - Mode controls above Automatic setup

Input: the owner's device screenshots showing that buildfix33 placed the separate Mode card after the entire Connection card, leaving Automatic setup visually above the mode switches. Base: the verified buildfix33 source archive.

- **Actual visual order corrected:** Mode is now an internal `zy-merged-subsection` of the Connection and controls card. Its contents render between Controls and Automatic setup, followed by Activity and cost. There is no second standalone Mode card below the merged card; all jump anchors and mode actions remain intact.
- **Dock matches the card hierarchy:** Controls, Mode, Automatic and Activity no longer consume four separate top-level dock items for one visual card. A single Controls item targets `zy-status`; Guard, engine, LSPosed, Budgets, ART and Apps remain. The dock has seven working top-level links instead of ten, while internal section anchors remain available.
- **Verified in the real DOM:** focused rendering contracts require `zy-controls → zy-mode → zy-auto → zy-activity`. HTTP-served Chromium measured their visual top positions in that same strictly increasing order, with Mode visible, no deleted prose restored, no horizontal overflow and zero page/console/HTTP errors. This remains browser/host evidence, not physical ColorOS WebView validation.

## V66 dev66 buildfix33 - compact Monitor explanations and cold-start navigation

Input: the owner's request to collapse long explanations in every Monitor detail window, smooth the initial transitions between Home, Monitor and Settings, make the shared UFO initials larger and darker, simplify Zygisk, place its two package repairs last in Infirmary, and fix the reported CI failure. Base: the verified buildfix32 source archive.

- **Native on-demand explanations:** the common tile/data-driven sheet now keeps its prose inside a localized keyboard-operable `<details>` tab. Opening another tile resets it to collapsed; current values, scales, charts, pressure evidence and raw sources remain visible. Battery drain independently folds Screen-on, Right-now, Screen-off and battery-level methodology prose. Stable keys preserve each user's open tabs across background meter repaints.
- **Cold navigation work moved off the tap:** the existing post-first-frame startup primes the localized nine-tile Settings hub without a root call, before the root queue's input-quiet delay. `cfgLoad()` uses the same idempotent priming path. Navigation audio is coalesced through one bounded 32 ms timer so first-use AudioContext creation does not hold the tap task; no page-state mutation, persistent worker or polling owner was added.
- **Darker, larger shared engraving:** `ASB` grows from 11 to 13 SVG units with tighter tracking and a darker green-steel gradient. All static and dynamic UFO instances and the regenerated 512×512 RGB icon inherit the same symbol; the smooth hull and three-layer engraving remain unchanged.
- **Zygisk composition:** Mode is rendered immediately after Connection and controls. The selected Auto mode's long cold-start/lifecycle paragraph and the process-restart note no longer have render owners. Report-style title, row, embedded-controls, merged-subsection and long-evidence hairlines are not applied to Zygisk; functional cards, values, controls, disclosures and navigation remain.
- **Infirmary order:** SOTER stays in the Battery repair flow before System Fixes. Push notifications (`heytapFixCard`) and DocumentsUI / DSU Picker (`documentsuiFixCard`) are now the final two content cards on the page, in that order.
- **CI dependency fixed without skipping assertions:** PNG size, RGB colour type and the buildfix28 corner-pixel check now use Python's standard `struct`/`zlib` libraries. The three previous `ModuleNotFoundError: PIL` failures and the new buildfix33 icon contract no longer require a globally installed Pillow package.
- **Verification:** focused contracts cover all 31 LVI explanation variants, data-driven sheets, four stable drain disclosures, safe `textContent`, hidden hub priming, bounded audio, shared artwork, Zygisk ordering/prose/separators and Infirmary ordering. Real Chromium exercised all 31 variants and drain repaints, six Home/Monitor/Settings transitions, and collapsed/expanded visual states. A second HTTP-served Chromium pass confirmed Mode directly after Connection, both deleted paragraphs absent, zero title/controls/merged borders, Push then DocumentsUI as the final cards, and no page/console/HTTP errors or horizontal overflow. Browser/host evidence is not physical ColorOS WebView validation and no performance or energy improvement percentage is claimed.

## V66 dev66 buildfix32 - smooth UFO hull and larger centred engraving

Input: the owner's enlarged module-icon review identifying the grey horizontal band above the initials and requesting larger, optically centred lettering. Base: the verified buildfix31 source archive.

- **The band is removed at its actual sources:** the old six-stop diagonal hull gradient is replaced by a smooth three-stop vertical metal gradient, and the broad filled white highlight is replaced by a thin curved stroke. There is no rectangular patch or cover-up above the lettering.
- **Larger, higher and lighter ASB:** the shared initials grow from 7.8 to 11 SVG units and their baseline moves to `y=40`, placing the engraving optically in the hull rather than against the dark rim. The hull is one restrained silver tone darker and the engraved green-steel surface is lighter for legibility, without restoring the bright sticker-like fill. The three stroke-free engraving layers remain intact.
- **One artwork owner and verification boundary:** all eight static uses, the dynamic flying UFO and the re-rendered 512×512 RGB icon inherit the same symbol. Source contracts and real Chromium rendering cover the smooth hull and large/small/tiny instances. No runtime policy, power/performance behavior or native binary changed; browser/host evidence is not physical ColorOS WebView validation.

## V66 dev66 buildfix31 - ASB engraved into the shared UFO hull

Input: the owner's visual review rejecting the bright outlined wordmark and grey sticker-like appearance. Base: the verified buildfix30 source archive.

- **Engraving rather than an applied label:** one reusable `ASB` text definition is rendered as a dark upper recess, a restrained lower metallic glint and a muted green-steel inner surface. The bright mint fill, separate stroke and `paint-order` outline are removed; no overlay plate or additional background shape is added.
- **One artwork owner:** all eight static SVG uses and the dynamically created flying UFO still reference `#asbUfoArt`. The 512×512 RGB module icon is re-rendered from that exact symbol at 2048×2048 and downsampled, not edited independently.
- **Verification boundary:** focused source contracts require one shared initials definition, three stroke-free engraving layers, eight static shared-symbol uses and the dynamic UFO reference. Real Chromium rendering was visually checked at large, small and tiny sizes. No runtime policy, power/performance behavior or native binary changed; browser/host evidence is not physical ColorOS WebView validation.

## V66 dev66 buildfix30 - bright green ASB wordmark across every UFO

Input: the owner's follow-up on the shared UFO artwork. Base: the verified buildfix29 source archive.

- **The dark cross-line above the wordmark is removed** from the shared `#asbUfoArt` symbol, not covered by an icon-only bitmap edit.
- **ASB is larger and brighter:** a light-mint-to-emerald gradient, 7.6-unit heavier lettering and a thin dark-green readability outline replace the small dark text. Every SVG `<use>` and dynamically created UFO inherits the same artwork, including the module icon, header, splash, Zygisk/loading and animated scenes.
- **The clean buildfix29 background remains:** deep-green vertical gradient, one restrained glow, no orbit rings, clipped rectangles or transparency mask. No runtime policy or native binary changed.

## V66 dev66 buildfix29 - cleaner UFO lettering and artifact-free module icon

Input: the owner's visual review of the buildfix28 module icon. Base: the verified buildfix28 source archive.

- **Optically calmer branding:** the shared UFO `ASB` lettering is smaller, lighter and slightly raised, with tighter tracking and a less harsh ink colour. Header, splash, Zygisk/loading and dynamic instances inherit the same adjustment through `#asbUfoArt`.
- **Clean icon background:** `webroot/icon.png` is re-rendered at 512×512 RGB from the shared artwork. The previous orbit rings and clipped rectangular background shapes are removed. A plain deep-green vertical gradient and one restrained radial glow remain behind the unmodified saucer geometry; there is no transparent mask.

## V66 dev66 buildfix28 - retired ROM-owned Settings, shared component restoration and ASB artwork

Input: the owner's eight-point follow-up covering the remaining rejected Android Settings, evidence/Smart/Soter presentation, a cross-page Activity/Service manager, UFO branding and splash composition, plus another source audit. Base: the verified buildfix27 source archive.

- **Retired writers, not filtered symptoms:** the two active `cloud_dns_happy_eyeballs_priority_enabled` writers and the optional assisted-GPS, XTRA endpoint and NTP server policy were removed. Those vendor/network choices remain ROM-owned; no rejected value is called applied. Action ignores only historical ledger failures for the now-unmanaged keys. Supported actively managed Settings retain the common latest-result `unsupported`/`not_writable`/`readback_mismatch` reporting and ROM-scoped retry behavior.
- **Quieter, more informative evidence:** Live evidence is initially collapsed while retaining lazy construction and persistent disclosure state. The Smart explanation now names the existing foreground/learned app, CPU/GPU, screen/charging, drain/charging-window, network/camera, memory and thermal/vendor-throttling inputs in all 13 locales. Soter has one Details disclosure containing Last repair and Automatic repair this boot; status, actions, automatic control and physical-key warnings remain visible.
- **One exact component owner:** Infirmary → Battery now shows Activities/Services changed from Infinite Log together with explicitly added manual entries. Both views read `/data/adb/asb/wakelock_services` through the existing component manager. Manual input requires a full declared `package/full.Class`, Activity/Service kind, original-state proof, a second tap and exact disable read-back. Restore uses the recorded default/enabled state. Ordinary Infinite Log declared-only rows remain non-writable; no package freezer, Worker alias, screen-off automatic component mode or polling worker was introduced.
- **Consistent branding and splash:** the shared UFO symbol carries `ASB`, so header, splash, Zygisk/loading and dynamic instances inherit it. `webroot/icon.png` is a 512×512 RGB full-bleed rendering with a green module-style background and the same marked UFO. The splash progress track is 11 px high with a restrained border/glow; the visible `0 / 5`/`1 / 5` counter is removed while accessible progress remains.
- **Audit and verification boundary:** targeted shell fixtures cover every retired Settings key versus a still-active refusal, declared-only rejection, explicit manual disable, persistent ledger readback after volatile evidence disappears, exact restore and undeclared rejection. Static and Node WebUI contracts cover collapsed evidence, one Soter disclosure, all locale keys, strict component parsing, two-tap command construction, restore, artwork and icon format. Real headless Chromium at 360 and 440 CSS px checked the splash, Infirmary dialog, second-tap behavior, collapsed Live evidence, one Soter disclosure, horizontal overflow and page errors; screenshots were visually reviewed. The full staged and clean-unpack host regressions are release gates recorded in the manifest. None of this is physical ColorOS WebView validation or a measured energy/performance improvement.

## V66 dev66 buildfix27 - coherent repair cards, honest evidence epochs and lighter navigation

Input: the owner's ten-point follow-up covering Infirmary repairs, Zygisk composition, active-profile evidence, the Android Settings refusal, Kernel/wakeup presentation, GPU pressure and page transitions. Base: the verified buildfix26 source archive.

- **System Fixes:** HeyTap MCS / OPPO Push and DocumentsUI / DSU Picker Fix are rendered again as reversible repair cards next to SOTER, using their existing transactional apply owners and package-state readbacks. The custom Soter branch no longer suppresses those two cards.
- **One Zygisk overview:** Connection/controls, Automatic setup and Activity/cost share one host card with internal jump anchors and one Explanation disclosure. Mode, Guard, engine, LSPosed, ART, observed apps and the complete evidence remain separate and functional.
- **Evidence on every page:** all six active-profile headers use the same button pill and open the same read-only sheet; closing restores focus to the actual opener. Details and effective policy are collected in one marker-framed root shell. Epoch zero is labelled saved history/current transaction not exposed, never Transaction 0. The redundant read-only footer is removed.
- **Settings refusal fixed at source:** both active writes of the ROM-refused optional `global/network_recommendations_enabled=0` policy are removed. Historical ledger evidence is retained, but Action no longer treats that retired unmanaged key as outstanding; other `not_writable` and `readback_mismatch` results remain visible.
- **Compact Kernel/wakeup UI and first-readback correctness:** the two Kernel help actions share a compact row, wakeup spacing is reduced and its long summary removed. The first successful null-to-readback transition replaces only the empty pre-load draft, so saved Screen-off names appear immediately; genuine edits, busy state, explicit-refresh reconciliation and transactional `set && status` behavior remain protected.
- **Focused rendering work:** the Load sheet shows GPU pressure as percent only, while GPU clocks elsewhere and busy-times-clock scoring remain unchanged. Tab navigation no longer starts an unrelated lazy Zygisk probe, and navigation chrome synchronization is coalesced through the existing frame scheduler. Deferred reads, 160 ms motion, freshness gates, information content and no-worker behavior remain.
- **Verification boundary:** dedicated epoch-zero, first-wakeup-readback, merged-card, repair-card, profile-pill and Action tests were added. Real headless Chromium at 360 and 440 CSS px checked the merged compositions, immediate `pedometer_minute_lock`, zero-epoch presentation, cross-page focus return, repeated Home/Monitor/Config transitions and horizontal overflow. The external `mui.kernelsu.org/internal/insets.css` request remains an environmental sandbox resource error, not a page-script failure. This is not physical OnePlus 15/ColorOS WebView validation and establishes no energy or smoothness percentage.

## V66 dev66 buildfix26 - transactional wakeup editing and quieter evidence UI

Input: the owner's ten-point Infirmary, Zygisk, profile-evidence, I/O, wakeup-editor, battery-freshness, motion and icon revision, together with current and older field captures. Base: the verified buildfix25 source archive.

- **Information architecture:** SOTER Repair is rendered inside **System Fixes**, and the unified ZYGISK · GOVERNOR · LSPOSED engine card sits immediately before LSPosed with its own page-jump entry. All 13 locales carry the new navigation and busy-state strings.
- **Header-only profile evidence:** profile cards only select profiles. The green active-profile pill in the header opens the read-only evidence sheet. Blueprint and ledger sections are native, initially collapsed disclosures with lazy row construction; their open state survives filtering and repainting. Ledger rows are deduplicated by domain/key with only the latest outcome shown. `unsupported` and `not_writable` are omitted only from this user projection; `readback_mismatch`, `lease_denied`, `safety_veto`, raw logs and diagnostics remain visible.
- **Physical I/O evidence:** the collector excludes loop, RAM, zram and device-mapper nodes and requires a physical `/sys/block/<dev>/device`. It reports the active bracketed scheduler separately from the raw capability list, so virtual devices and repeated `[none] mq-deadline kyber adios bfq` text are not presented as ASB storage rails.
- **Transactional exact-name wakeup Save:** one owner invocation performs `set --always … --sleep … && status`; success requires an `applied` verdict and exact ordered readback of both saved lists. The editor preserves drafts on busy, errors and mismatches. A bounded mkdir/PID lock returns `busy` for a live owner and recovers stale locks. Sequence tickets reject stale panel responses, including obsolete/frozen-app source lists. First-try `pedometer_minute_lock`, split on/off/unknown policies, live busy and stale-PID recovery are covered.
- **Shared battery freshness and lighter motion:** fresh Monitor meter data updates the same cached snapshot and repaints Home when it is visible underneath, without another polling worker. Config opens after one presentation frame with a 160 ms shared page duration/fallback; modal backdrop blur is disabled. These are code-path improvements, not measured power or smoothness percentages.
- **Full-bleed icon:** `webroot/icon.png` is a 512×512 RGB rendering of the existing UFO artwork with edge-to-edge background, no transparent rounded mask and no lateral rails; Android supplies the launcher shape.
- **Capability-only uclamp handling:** TOP/BG/SYBG text readbacks remain integer-decimal/`max` aware. Three consecutive successful writes with persistent zero readback now produce `unsupported_readback` and a day-long capability backoff, never an applied/success claim. asbdiag prints recent `UNSUPPORTED` capability events separately from rejected writes; unchanged DSP prebuilts are not represented as new AOSP/AIDL builds.
- **Field-evidence boundary:** current and older captures motivated eliminating retry storms and misleading UI, not universal frequency increases, broad wakeup blocklists or automatic restrictions on Shealth, WhatsApp or Telegram. Sampled current and frame/jank figures remain capture-specific evidence rather than proof of a universal improvement.
- **Host and browser verification:** the canonical staged-tree regression passed 429 suites/test cases with 581 anchored PASS lines, zero failures, zero lint errors/warnings and 48 strict native warnings against the existing budget of 62. Focused first-Save/readback, live-busy, stale-lock, physical-I/O, ledger, freshness and navigation tests passed. Real headless Chromium checks at 360 and 440 CSS px verified header-only evidence, lazy disclosures, filter persistence, actionable mismatch visibility, Guard → Unified engine → LSPosed ordering and no horizontal overflow or JavaScript page errors; screenshots were visually reviewed. The sandbox could not resolve the external `mui.kernelsu.org/internal/insets.css` request, which is classified as an environmental resource error rather than a page-script failure. None of this is physical OnePlus 15/ColorOS WebView validation. The exact release ZIP additionally has to pass the clean-unpack gate recorded in `RELEASE_MANIFEST.json`.

## V66 dev66 buildfix25 - Zygisk hot-path hygiene and per-profile evidence

Input: the owner's request to reduce Zygisk overhead and improve lifecycle hygiene, make active profile cards explain their actual device-specific changes, and add the same UFO module icon used by the WebUI. Base: the verified buildfix24 source archive.

- **Companion policy cache:** unchanged policy is still checked by inode, size and nanosecond mtime, but is not opened, read and strictly parsed again for every spawn/exit. Missing, malformed and replaced policies fail closed rather than reusing an old allowlist. `policy_reads` and `policy_cache_hits` make the behavior inspectable.
- **Less filesystem and spawn work:** governor hints bind an abstract Unix datagram client instead of creating/unlinking a socket node; one spawn shares one lazy published-screen read, and `onLoad` no longer performs a redundant policy open/close probe. The one-shot SPAWN, `DLCLOSE_MODULE_LIBRARY`, exclusions, rate limits, Safe mode and governor veto remain intact.
- **No unchanged policy rewrite:** sync builds its candidate in the runtime tmpfs when available, compares semantic content without generation/version metadata, and leaves an unchanged policy's inode, mtime and generation alone. Changed content retains atomic replacement, permissions, context and rollback behavior.
- **Active-profile evidence sheet:** tapping the active Smart, Performance, Balanced or Battery card opens a localized read-only dialog; tapping an inactive card still switches profile. The sheet combines 76 intent values, Smart's Balanced baseline, live ownership/FSM/thermal/writer/network state, per-device I/O readback, and a filterable requested/previous/readback/result ledger bounded by the latest profile transaction. Missing evidence stays unavailable/unsupported rather than becoming an applied claim. Dynamic values use `textContent`; Enter/Space, stale-response rejection, error and close/focus paths are covered.
- **Module icon:** `webroot/icon.png` is rendered from the existing `#asbUfoArt` SVG symbol, with only a rounded-square module background added.
- **Native and verification:** both Zygisk shared libraries were rebuilt with Android NDK r28c and checked as AArch64/ARM ELF shared objects with both Zygisk entry exports. The complete canonical host regression passes; targeted collector/UI tests and real Chromium checks at 360 and 440 CSS px pass, with screenshots visually reviewed. These are not physical OnePlus 15/ColorOS WebView results and no power, latency or smoothness improvement percentage is claimed.

## V66 dev66 buildfix24 - mainline I/O choices and split idle policies

Input: the owner's request for modern I/O schedulers beyond Kyber on the OnePlus 15 and matching ASB policy. Base:
the verified buildfix23 ASB source and the paired android16-6.12 kernel source with ADIOS 3.3.0 already integrated.

- **Kernel exposure without a forced default:** the OnePlus 15 final config requests and verifies
  `CONFIG_IOSCHED_BFQ=y`, `CONFIG_MQ_IOSCHED_DEADLINE=y` and `CONFIG_MQ_IOSCHED_KYBER=y`. The existing conditional
  ADIOS action and stock default-elevator ownership remain. No legacy SIO/FIOPS/Zen port or private scheduler
  tunable was added.
- **Distinct screen-off policy:** Smart screen-off and Battery Auto try `none` first, then `mq-deadline`, Kyber and
  ADIOS only when exposed by each queue. Smart screen-on idle and Balanced Auto start with `mq-deadline`; ordinary
  interactive Smart work retains Kyber, and gaming/heavy plus Performance retain ADIOS/Kyber priority.
- **BFQ remains manual:** upstream BFQ is intended for interactivity/fairness, but that does not establish lower UFS
  energy use on this phone. Explicit BFQ and exact Stock restore remain covered; BFQ-only Auto stays `not_exposed`.
- **No new runtime owner:** selection still uses the existing bounded per-device discovery, preflight, readback,
  rollback and kernel-bound baseline. No arbitrary sysfs writer, polling worker or silent persisted-setting reset.
- **Verification scope:** focused fixtures cover full and reduced scheduler exposure, missing-none fallback,
  Balanced/Battery static orders, manual BFQ and invalid input. The kernel final-config guard rejects missing or
  wrong scheduler symbols. Host tests do not compile/boot the complete kernel or prove OnePlus 15 UFS, latency,
  throughput or battery improvements; same-device A/B remains required.

## V66 dev66 buildfix23 - flat Glass detail sheets and lightweight categorical graphics

Input: the owner's screenshots of grey nested cards and dense text in the FSM, limit-source, slot, slot-heat and
modem-mode sheets. Base: the fully verified buildfix22 source archive.

- **Glass cascade corrected at its actual strength:** current, history, raw-source and pressure regions inside
  live-info sheets now override Glass's own `!important` surface. They have transparent backgrounds, no nested
  shadow, backdrop filter, lateral border or radius; only quiet dividers remain. The sheet itself retains the
  single material surface. The selectors are expanded into bucketable equivalents rather than adding an
  every-element CSS cost.
- **Calmer information hierarchy:** the current value keeps a readable 26 px size, explanations wrap at natural
  word boundaries and raw source facts use the normal sans font rather than a dense monospace block.
- **Lightweight categorical graphics:** categorical history is a proportional colour strip with a compact legend
  and accessible textual distribution. FSM and limit-source categories use existing semantic colour tokens;
  remaining categorical sheets use the established palette. At most six primary categories are shown and the
  remainder is aggregated. Numeric slot-heat history retains its sparkline. Insufficient history remains an
  honest wait message rather than a fabricated chart.
- **Actual latest-night ownership:** the active profile no longer lets an older global `drain_meter.night` record
  shadow a newer per-profile night. Both global and per-profile records must belong to the most recent local
  04:00-11:59 morning; an indefinitely retained older qualifying window is not presented as last night. The
  regression fixture explicitly requires a newer profile-owned 0.20 %/h record to replace a stale shared
  2.83 %/h record on Home, Monitor and the shared ETA chooser.
- **No new runtime work:** graphics are ordinary DOM/CSS built by the existing sheet renderer. No canvas,
  animation, timer, polling owner or additional root read was added. Values and labels still enter through
  `textContent`; only numeric widths and known-token colours are assigned to bar segments.
- **Verification scope:** categorical runtime coverage checks segment/legend generation and accessibility.
  Twelve Chromium checks exercise the real sheet-opening function in Glass at 360 and 440 CSS px across FSM,
  limit source, modem mode, slot and slot heat, including computed material styles, overflow and console errors;
  all ten screenshots were visually reviewed. Host/browser checks are not physical OnePlus 15 or ColorOS WebView
  validation and no energy or performance improvement percentage is claimed.

## V66 dev66 buildfix22 - selected-profile battery truth and coherent compact WebUI

Input: the owner's eleven-point battery-evidence and visual revision. Base: the fully verified buildfix21
source archive.

- **Selected active profile:** Home and Monitor now use `_selectedProfile`, not the meter's potentially stale
  or empty runtime `current` publication, to decide which profile owns phone-wide since-boot screen-on drain
  and the latest qualifying night. Inactive profiles retain only their own latest completed session or valid
  aggregate and their own night. Both views share the same selection functions; visible `history`/`window`
  scope labels are removed while exact evidence remains in tooltips and detail sheets.
- **Live values and short labels:** Kernel badges show the actual readable value rather than a redundant
  `On` prefix. Monitor battery tiles use the existing short localized `Screen on`/`Screen off` labels and wrap
  without ellipsis. Fresh meter data is applied before an unchanged governor snapshot can return early.
- **Coherent disclosures:** Zygisk long notes are grouped into one native disclosure per section. Junk Cleanup
  categories and secondary SOTER diagnostics use the same quiet disclosure language. Junk categories follow
  the primary actions, Battery Fix details follow its complete operational flow, and SOTER keeps its physical
  key warning visible without claiming a physical PASS.
- **Report and detail sheets:** repeated generic `Application` labels are omitted from package rows without
  removing the package action or identity metadata; text export no longer creates a leading empty `: `. FSM,
  limit-source, slot-heat, modem-mode and slot sheets share a flatter value/explanation/source hierarchy with
  bounded wrapping and one Done action.
- **Bounded refresh:** visible Monitor starts at a five-second refresh and backs off through 10/15/20 seconds
  for unchanged snapshots. The existing single timeout owner, hidden-page cancellation and navigation defer
  remain; no persistent worker or second polling owner was added.
- **Verification scope:** the full host regression passes, including explicit active Home checks with stale
  and empty meter-current data. Thirty-six Chromium checks at 360 and 440 CSS px cover Home/Monitor ownership,
  short labels, five detail sheets, collapsed and expanded disclosures, Battery Fix ordering, compact SOTER,
  Junk actions and horizontal geometry; the screenshots were also visually reviewed. Host/browser checks are
  not physical OnePlus 15 or ColorOS WebView validation and no energy or performance improvement percentage
  is claimed.

## V66 dev66 buildfix21 - profile-scoped drain evidence, complete Battery Fix and compact controls

Input: the owner's fifteen-point Activity/Service, report, Kernel, wakeup, Zygisk, battery-metric and
Infirmary revision. Base: the fully verified buildfix20 source archive.

- **Activity/Service discovery:** explicit component APIs now accept installed system packages as well
  as user packages; package-wide WAKE_LOCK AppOps remains third-party-only. Both legacy Resolver and
  modern `Activity/Service Resolver Table` declarations are parsed. Current, declared, exact job-history
  and saved evidence stay distinct. Exact disable still requires original-state proof and read-back;
  refusal rolls back and Restore returns the recorded state. The modal is width-bounded and its copy is short.
- **Report and card hygiene:** actionable package rows show the application label when Android exposes it,
  retain the exact package as action metadata and survive text export. Long Infinite Log explanations are
  shorter. Kernel state and Smart ownership share one badge row and `On`/`Вкл.` wording; the obsolete Kernel
  introduction is removed. Zygisk no longer calls its control page read-only, and complete long notes use
  native on-demand disclosures without hiding root, Zygisk or memory evidence.
- **Exact wakeup persistence:** saved Always/Screen-off rules are applied again by the existing bounded
  `boot_completed` waiter after Android is up, covering kernels that expose `asb_wakeup` late. Early apply,
  five-minute reconciliation, fail-closed read-back and Safe mode are unchanged; no polling worker was added.
- **Battery metrics:** the active profile shows SOC-derived screen-on `%/h` since boot and the latest
  qualifying night. An inactive profile shows only its own latest completed screen-on session (at least ten
  minutes) and its own latest night, with the older aggregate only as a labelled fallback. Global active
  evidence is never borrowed for another profile. Charging, resets, implausible steps and long unverified
  screen-on gaps are excluded; a zero-step window is an upper bound, not a fabricated zero.
- **Complete Infirmary Battery Fix:** the ART stage is restored beside the one-shot statistics reset. At 100%
  on charge, the bounded worker compiles packages through Android's package-scoped `cmd package compile` or
  `pm compile` speed-profile API, exposes progress/stop and distinguishes done, partial, refused, scheduled,
  stopped and interrupted states. Android `bg-dexopt-job` is the recovery path. Direct `dex2oat`, ART/Dalvik
  wipe and aggregate all-package compilation are absent. Statistics are still reset only by the explicit
  pending flag on the next boot; neither operation proves added capacity or improved battery life.
- **Compact Infirmary:** repair summaries are shorter and Junk Cleanup categories are collapsed by default
  through native disclosure. The supported fixed category set, dry-run/readback, actions and ASB-report
  protections are unchanged.
- **Verification scope:** focused runtime/UI fixtures cover system Resolver Table rows, reversible component
  state, late wakeup restore, per-profile screen/night ownership, zero-step bounds and complete ART states.
  Chromium geometry checks at 360 and 440 CSS px cover the component close action, Kernel badges, ART card,
  Zygisk notes and Junk disclosure. Host/browser checks are not physical OnePlus 15 or ColorOS WebView
  validation and no energy or performance improvement percentage is claimed.

## V66 dev66 buildfix20 - active-drawing evidence, phase share and a repaired I/O read-back

Input: a second user's 894-minute Infinite Log capture and its `asbdiag`. Base: the fully verified
buildfix19 source archive. The longest on-battery night window was 303 minutes at 0.59 %/h with 3.6%
CPU-awake; active speaker/media and gaming phases accounted for more of this capture's battery-percent
steps. These are observations from this capture, not an improvement attributed to ASB or this release.

- **Comparable smoothness evidence:** the digest adds ordinary intervals drawing at least 20 FPS and
  excludes wake-spanning/near-still rows. The supplied capture has 1.0% late frames over 1,064,653
  active-drawing frames; the separate 30.2% `LIGHT_IDLE` figure covers only 354 frames and is not used
  as proof that a ceiling needs raising. Existing per-app, per-state and at-cap evidence remains intact.
- **Where the capture's charge went:** the phase table now shows each phase's share of all positive
  battery-percent steps alongside duration and rate. It is not causal per-component energy allocation;
  the known under-reporting `current_now` gauge remains explicitly a measurement-quality issue.
- **Honest LTPO engagement:** a zero capture delta remains visible instead of disappearing. Watching is
  labelled as watching, not as an active lower rate. No compatible-video window, saving or decision
  reason is inferred when the capture does not expose one. LTPO write/restore behavior is unchanged.
- **Actual diagnostic bug fixed:** the two I/O scheduler `sed` expressions used their separator inside
  the key, producing `bad pattern` and hiding the read-back. Exact literal-pipe matches now print both
  scheduler and exposed options; `tools/asb_diag.sh` and `system/bin/asbdiag` remain byte-identical.
- **No blind governor retuning:** this evidence does not justify new CPU/GPU/uclamp/scheduler/thermal
  restrictions. ASB cost is about 3.1 ms per timer wakeup in the capture, night behavior is healthy and
  at-cap jank is not worse. No native binary, persistent polling worker, universal frequency rule or
  measured battery/performance improvement percentage was added.

## V66 dev66 buildfix19 - evidence-scoped drain/heat, actionable report packages and component discovery

Input: overnight drain improved while active-use drain remained high, conflicting screen-on labels,
unsupported game/call/charging advice, a lone 45 °C CPU peak shown as danger, non-actionable report
packages, volatile RuStore component discovery and a cramped exact-wakeup editor. Base: the fully
verified buildfix18 source archive.

- **Measurement windows stay distinct:** Home/Monitor/profile history, the current Smart window and
  the whole Infinite Log capture now name their scope and duration instead of implying that different
  windows must show one number. The repetitive Smart no-help observation is removed from Other
  observations; the substantive Smart counters remain.
- **Continuous heat evidence:** summary, hero, diagnosis and priority actions share one helper based
  on the longest continuous warm run. Accumulated warm minutes and a 45 °C peak alone do not create
  a red sustained-load verdict. Scattered episodes and real sustained runs retain different advice;
  no games, video calls or charging activity is invented.
- **Real report actions:** the main night holder, valid screen-off application starts and package
  wakelock rows open the existing component manager for that exact package. Kernel tags, alarms and
  malformed strings remain non-actionable evidence; device values continue through `textContent`.
- **Component evidence without fabrication:** current Activity/Service records, Package Manager
  declarations, exact batterystats job components and ASB's restoration ledger are merged with explicit
  origins. RuStore job history exposes its real shared `SystemJobService`, never a Worker masquerading
  as a separate Service. Declared-only components are read only; original-state capture, read-back,
  rollback and Restore remain mandatory.
- **Cleaner Kernel controls:** observation, exact-name entry, Always/Screen-off drafts and apply/refresh
  actions have separate symmetric grids. MGLRU, timer-migration, LPM and related live explanations live
  inside the existing collapsed card description. Writable kernel state is labelled Active. No polling
  worker, broad blocklist, arbitrary writer, thermal bypass or automatic component freezer was added.

## V66 dev66 buildfix18 - concurrent Infinite Log starts join the verified live winner

Input: a GitHub Actions `debug_support_contract` failure at concurrent round 8 returned
`error=recorder_exited` from one request while the competing request returned `status=started`
and a recorder PID. No missing-file error was present. Base: the fully verified buildfix17 source archive.

- **Narrow exited-launcher repair:** when the request's token was replaced, the start path now performs
  the existing bounded recorder/launcher handoff lookup. A verified live replacement owner produces
  `status=already_running` and the winner PID; token replacement alone is not accepted as proof of life.
- **Failure and ownership semantics retained:** an exited same-token recorder still produces
  `error=recorder_exited`, and a changed token without a live owner remains an error. Only the request's
  own still-matching lock can be removed. The repaired branch launches no second recorder, deletes no
  foreign lock and adds no polling worker.
- **Deterministic regression, not a weaker assertion:** the handoff fixture publishes a live replacement
  PID and requires the loser to join it without altering the winner token/PID or lock directory. The
  adjacent same-token recorder failure and foreign-lock tests remain mandatory.

## V66 dev66 buildfix17 - aligned WebUI motion, retained hub DOM and clearer category icons

Input: make WebUI navigation and data display feel lighter without losing functionality or information,
and enlarge the nine Settings category icons while keeping their structural count pills harmonious.
Base: the fully verified buildfix16 source archive.

- **One visual/deferred-work deadline:** page entrances now use 180 ms of opacity/transform motion plus
  a 40 ms delay, matching the existing 220 ms navigation deadline and its bounded 24 ms fit/read margin.
  Home WAAPI uses the same 180+40 ms timing. The old CSS entrance could move for 320 ms while deferred
  root/layout work became eligible at 244 ms; that overlap is removed rather than merely accelerating
  every animation. Reduced-motion behavior, paint-before-motion and coalesced fitting remain.
- **Fresh data is still mandatory:** an expired or missing Monitor snapshot still causes a fresh read,
  now after a 240 ms open settle instead of 320 ms. `LIVE_OPEN_REUSE_MS` remains 1200 ms. Batched reads,
  Config freshness gates, V64/LTPO/MMFEED/LSPosed/package/nightcharge evidence and readback semantics
  were not weakened, and tap handlers still make no direct root call.
- **Bounded inner motion:** category rows retain their ordered entrance with 220 ms rows, a maximum
  120 ms delay and an 8 px vertical offset. The asynchronous repaint guard is 400 ms instead of 650 ms;
  search has no stagger and a same-screen repaint does not restart the entrance.
- **No unchanged-hub rebuild:** `cfgPaintAfterLoad()` preserves the actual nine-tile hub DOM after a
  Config read only when Config is open, no category/search is active, the hub exists and its structural
  signature is unchanged. Category/search screens still repaint because they show live values. Missing
  or stale hub DOM also repaints. Structural totals never depend on `_cfgVals`, `cfgLoadFresh()` or
  activation state, and no activity bar or fake cached live value was introduced.
- **Category visual balance:** base icon containers/glyphs grow to 40/25 px, with 38/24 px and 36/22 px
  steps in `asb-fit-c1`/`asb-fit-c2`. Count pills retain the full localized `{n} controls` text and
  centred alignment while using 30 px minimum width, 2 px 4 px padding and a 6 px radius. All nine
  totals, descriptions and controls remain unchanged.
- **Verification:** new and updated host fixtures cover timing alignment, Monitor freshness/reuse,
  unchanged and repeated hub retention, forced category/search/stale/missing/closed-state repaint
  behavior, all icon fit tiers and compact count pills. The full working-tree canonical regression
  passed with 448 anchored PASS lines, zero FAIL/FAILED, I/O errors or Broken pipe. Interactive Chromium
  with a bounded mocked root bridge passed at 412x915, 375x667, 360x560 and 320x480, including real tab
  clicks, category/back/search, forced Config refresh with hub node identity retention, Zygisk/Device/
  Report navigation and the complete seven-option I/O dropdown. Dark/light screenshots and explicit
  c1/c2 computed-layout checks found no horizontal overflow or clipped totals; console and local HTTP
  errors were zero in the navigation harness. These are host/source contracts, not a measured device
  responsiveness percentage or physical OnePlus 15/ColorOS WebView validation. No native binary,
  polling worker, settings reset or performance/energy claim was added.

## V66 dev66 buildfix16 - per-queue I/O fallback, transactional rollback and Interface field evidence

Input: reports that not every device exposes ADIOS, Kyber, mq-deadline and BFQ together, plus reports
that Recents corner radius, Recents memory and possibly other new Interface controls can save without
a visible effect. Base: the fully verified buildfix15 source archive. This release preserves the
Interface controls and adds read-only evidence before any support/removal decision.

- **Independent queue exposure:** Smart and non-Smart Auto retain the buildfix15 scenario orders, but
  every block queue is planned only from its own runtime `/sys/block/*/queue/scheduler` list. A queue
  without the preferred scheduler can select its next discovered fallback while another queue selects
  a different one; the live summary can therefore be `mixed`. `none`-only and ADIOS-only kernels get
  bounded results, custom-only Auto remains `not_exposed`, and BFQ remains manual-only. No scheduler
  is advertised or selected without runtime exposure, and no static device table was added.
- **Transactional apply:** all queues are preflighted and their active schedulers are snapshotted
  before the first write. A write or readback failure on any queue restores every changed queue to its
  pre-attempt value and confirms the restoration. Failure to confirm restoration is reported as
  `rollback_failed`; a failed Smart apply does not save a new Smart plan. Persistent per-device Stock
  baselines survive rollback and still restore their exact original values. Registered nodes,
  kernel-id invalidation, write-only-on-difference and readback remain mandatory.
- **Read-only Interface diagnostics:** `runtime/asb_display_ui_apply.sh diagnose [key]` covers all
  eight Interface/Display controls: Recents memory, Recents corner radius, smooth corners, navigation
  handle auto-hide, pointer speed, gesture mistouch, game MEMC and DC dimming. Each key reports
  configured, expected, live and baseline evidence separately. Recents radius includes both
  `global/oost_recent_task_radius` and `global/oost_recent_task_radius_dp`; Recents memory includes
  `secure/display_memory_information_recent_task`. The report also includes bounded resolved Home
  component/version evidence, never serial numbers, account, IMEI or network identifiers.
- **Truthful verdicts:** a matching Settings readback is `write_verified_visual_unverified`, not proof
  that a launcher or SystemUI renderer consumed it. A changed/non-retained value is
  `readback_mismatch_visual_unverified`; unavailable transport is `settings_unavailable`; unavailable
  Home evidence remains `unknown`. Stock baselines distinguish owned, observed and mismatch states.
  Values and transport errors are bounded/sanitized, `visual=verified` is never emitted, and diagnosis
  starts no worker. Host fixtures hash Settings files and baselines before/after diagnosis to verify
  that it changes nothing.
- **Collection and UI wording:** the same evidence is included in `tools/asb_diag.sh` and the identical
  `system/bin/asbdiag`; a standalone diagnose command and `su -c asbdiag` are documented. Successful
  WebUI applies now say that Settings were saved while the visible effect remains unverified, in the
  English source fallback and all 13 locales. Runtime Settings errors and readback mismatches remain
  failures rather than success toasts.
- **Verification scope:** new host fixtures cover heterogeneous queue sets, mixed live state, exact
  mixed-baseline Stock restore, none-only/ADIOS-only/custom-only exposure, second-queue write failure,
  first-queue rollback, preserved baselines and rejected rollback confirmation. Interface fixtures
  cover all key/target rows, Home evidence, Stock/ROM-overwrite/unavailable states, unknown-key
  rejection, read-only hashes, asbdiag integration and locale parity. Full working-tree and
  clean-source-ZIP regressions plus manifest/mode/hash verification remain release gates. Browser or
  host verification is not physical OnePlus 15/ColorOS WebView validation and does not establish that
  any Interface control has a visible effect on a particular ROM.

## V66 dev66 buildfix15 - scenario-driven Smart I/O, permanent category totals and faster page transitions

Input: the owner's OnePlus 15 custom-kernel scheduler exposure (`adios`, `kyber`, `mq-deadline`,
`bfq`), the request for active-Smart scenario ownership and manual-only BFQ, plus a WebUI revision
covering all nine category cards and still-faster initial navigation. Base: the fully verified
buildfix14 source archive.

- **Smart I/O policy:** active Smart + `io_scheduler=auto` now follows the existing bounded Smart
  `HINT`/`SCREEN` signature through `runtime/asb_io_scheduler.sh smart HINT SCREEN`. Gaming/heavy
  prefers ADIOS, ordinary screen-on work prefers Kyber, and idle/screen-off prefers mq-deadline.
  Screen-off takes precedence over a gaming/heavy hint. Each queue is preflighted independently,
  and only runtime-discovered fallbacks are eligible: `adios kyber mq-deadline none` for heavy,
  `kyber mq-deadline adios none` for ordinary work, and `mq-deadline kyber none adios` for
  idle/screen-off. No new worker, polling loop or arbitrary path/value writer was added.
- **Plan and ownership:** a successful Smart Auto apply saves `/data/adb/asb/io_scheduler/smart.plan`;
  generic reinforcement reuses that validated scenario rather than reverting to a static default.
  The dynamic branch is restricted to active Smart, Auto and non-manual mode. Explicit schedulers,
  per-device original baselines, kernel-id invalidation, write-only-on-difference, readback and exact
  Stock restoration remain. Stock also removes the Smart plan.
- **BFQ is experimental and manual-only:** it is removed from every automatic order, including
  non-Smart profiles. Explicit BFQ still works when every queue exposes it; Auto with only BFQ
  returns `not_exposed` and leaves the queues untouched. The previous always-ADIOS impression came
  from ADIOS leading the static orders. A live `Доступно · adios` row does not establish a drain
  cause, and no battery/FPS/latency/throughput improvement percentage is claimed.
- **Nine permanent totals:** every category footer now contains only one centred `{n} controls`
  label. The structural total is identical before and after Config loading; there is no pending or
  active/total phase and no bar node. Hidden kernel controls and the existing Camera/wakeup/
  notification extra cards still determine structural scope. `cfgHubSig()` no longer depends on
  Config values or freshness, avoiding unrelated hub repaints.
- **Faster bounded navigation:** the common page slide is 220 ms instead of 320 ms. The existing
  paint/fit lifecycle is preserved with a 24 ms navigation extra, 32 ms Settings entrance guard and
  16 ms deferred Config refresh. Tap handlers still avoid direct root-bridge calls; there is no
  busy wait or persistent worker. These are source/runtime timing contracts, not a claimed device
  responsiveness percentage.
- **Descriptions and verification:** the Smart scenario, manual-only BFQ, Stock semantics and absence
  of guaranteed gains are documented in the English source fallback and all 13 locales. New host
  fixtures cover all scenario mappings, screen-off precedence, discovered fallbacks, sequential plan
  reuse, BFQ-only fail-closed Auto, manual BFQ, invalid arguments, exact mixed-baseline restore and
  ownership guards. WebUI fixtures check nine unchanged totals with Config access poisoned, absence
  of bars, dynamic Smart I/O badge and the new bounded navigation timings. Full working-tree and
  clean-source-ZIP regressions plus manifest/mode/hash verification remain release gates. Host or
  Chromium checks are not physical OnePlus 15/ColorOS WebView validation.

## V66 dev66 buildfix14 - immediate Settings navigation, unified page exports and truthful repair states

Input: the owner's ten-item WebUI/backend revision and a new 977-minute Infinite Log, two asbdiag
snapshots and wakelock evidence. Base: the fully verified buildfix13 source archive.

- **Settings opening:** one existing bounded `asbStartupLater()` transaction starts the shared
  `cfgLoad()` immediately after the first frame. An immediate category tap joins that same
  `_cfgLoadRun` instead of queueing another ten-part read behind Live. All nine category bars remain
  available; pending tiles say how many controls they contain without inventing `0 / N`, then replace
  it with real active/total counts. Count pills and 5 px category bars improve legibility. No polling
  worker, repeated eager batch or fake readiness was added.
- **Zygisk and Infinite Log:** the controllable Zygisk page no longer calls its heading a read-only
  snapshot. Cached Infinite Log content stays at full opacity before/during Refresh, with timestamp
  and status communicating freshness; its existing Back chip now uses the same `has-back` layout as
  Zygisk. Saving either page does not trigger a fresh collector read.
- **Fixed page exports:** Zygisk, Infinite Log and Device Diagnostics now save through the bounded
  `runtime/asb_page_export.sh` begin/append/finish/abort protocol into `/sdcard/ASB/logs`. The browser
  supplies only kind, timestamp and base64 chunks, never an arbitrary path. Unicode/multichunk content,
  atomic rename, unsafe-input rejection and interrupted/decode cleanup are covered. Download is not a
  fallback. Direct asbdiag uses `ASB/logs/asb_diag_report.txt`; WebUI suppresses side copies and keeps
  one timestamped report. `P()` has explicit success status, completed collection exits zero, and a
  real collector execution failure remains an error. Repeating `diag-start` after `saved` is tested.
- **Activity/Service:** the existing exact `PACKAGE/CLASS` disable/restore owner remains unchanged.
  The modal adds full-component search, selected-first/running-first ordering and explicit wording
  that Disable persists until Restore. Discovery uses current Activity/Service records, package state
  and `/data/adb/asb/wakelock_services`; no process freezer, automatic screen-off component scheduler
  or package-wide SystemJobService rule was added.
- **Exact wakeups:** the main card has one context-sensitive Start/Update action; Clear moved into
  the source modal beside a compact refresh action. Search/filter state and already discovered names
  survive a non-destructive `status` refresh; only intentional observe start/clear reset the window.
  Saved Always/Screen-off rule count is now reported separately from currently active count, so a
  saved screen-off rule no longer appears as zero saved rules while the screen is on.
- **Repairs:** HeyTap descriptions and result handling now match its actual reversible package-state
  backend in the source fallback and all 13 locales; no ART path was reintroduced. Battery Fix remains
  reset-only and always publishes live level/charging evidence, including `reset=done`, so a real
  100% on charger remains eligible after an earlier reset.
- **Night evidence:** `night(longest)` is 410.0 minutes, 6%, 0.88%/h and 8.8% awake; `sleep` is a
  different 391.2-minute row at 7%, 1.07%/h and 9.9% awake. Android's screen-off CPU window and the
  recorder's idle row are different again. Application/kernel wakelock candidates overlap observation
  windows and cannot be assigned shares of the nightly six percent without timestamp cross-checks.
  Recorder awake periods bias sampled current. Relevant settings are unchanged between the two new
  asbdiag snapshots; unnormalised session totals do not prove a regression. No new ASB-side drain cause,
  logging/timer verdict or percentage improvement is claimed, and no broad app/kernel restriction was
  added.
- **Verification coverage:** updated WebUI fixtures retain full export-content/chunk/error assertions
  under the new helper protocol, bounded warm-up dedupe, honest pending counts and nine categories.
  Host fixtures cover Battery Fix none/pending/done and refusal states, page-export safety/Unicode/
  multichunk/cleanup, diagnostic terminal status/failure/repeat, and component search/order. Full
  working-tree and clean-source-ZIP canonical regressions plus manifest/mode/hash checks remain release
  gates. Host/browser checks are not physical OnePlus 15 ColorOS WebView validation and do not prove
  improved battery life.

## V66 dev66 buildfix13 - bounded routine-touch lifts, truthful writer metrics and unified support-log storage

Input: two capture epochs, two asbdiag snapshots and a full-day Infinite Log from a user reporting
heavy drain after an update, plus the owner's request to store exported asbdiag reports beside
Infinite Log in `ASB/logs`.

- **Evidence, not a single-cause verdict:** verbose logging was enabled only near the end of the
  current capture and cannot explain the earlier battery drop. The two epochs are not a controlled
  A/B: screen-on share, brightness, applications, radio activity and duration differ. High screen-off
  awake share, mobile radio/IPA/rmnet, RTC, Bluetooth and application jobs are corroborated external
  contributors to investigate. `ru.vk.store` is a repeated candidate, not evidence for an automatic
  package-wide or `SystemJobService` block. Instantaneous frequency caps, GPU busy share and ASB CPU
  time alone do not measure battery energy. ASB's own report says its timers do not use alarm clock
  wakeups or wake a suspended phone.
- **Routine-touch lift:** repeated ordinary touches can arm at most one new unlock lift per 20 seconds
  after the previous lift expires. App switches and lock presses retain their independent five-second
  anti-chatter path; wakes, first touch, cold starts and Battery continuous-touch hold keep their
  existing fast paths. Profile, thermal and warm-die vetoes remain mandatory. New
  `unlock_touch_lifts`/`unlock_touch_defers` state counters make accepted and deferred routine-touch
  requests visible. No persistent polling worker, permanent Performance governor, higher floor,
  thermal bypass or silent settings reset was added.
- **Writer accounting:** `governor_write_attempts`, `governor_writes`, `governor_already_set`,
  `governor_precheck_reads`, `governor_readbacks` and physical write batches now distinguish a request
  from an actual `sysfs_write_int()` call. An already-set confirmation is no longer reported as a
  physical write. asbdiag and Infinite Log expose attempts, physical writes, no-op confirmations,
  precheck/confirmation reads and nodes per physical batch; saved old reports retain their parser
  fallback. This corrects the old terminology instead of claiming a measured energy saving.
- **Support-log destination:** direct and asynchronous WebUI asbdiag exports both use the common
  `/sdcard/ASB/logs` writer. Download and `/sdcard` fallbacks were removed, so one successful export
  produces one report beside Infinite Log. Failure to create or use the destination returns
  `error=diag_outdir_failed` without a false `status=saved` or device path; collector failures remain
  explicit. The source-side host-output override remains available for tests.
- **Verification:** native fixtures cover routine-touch defer, independent app/lock/cold-start paths,
  thermal/profile gates and attempts/no-op/physical-I/O accounting. Shell/WebUI fixtures cover one-file
  export, destination failure, old/new report parsing and the localized report UI. The ARM64 governor
  is rebuilt with the pinned NDK workflow while unrelated Zygisk/DSP binaries remain unchanged. Full
  working-tree and clean-source-ZIP regressions are release gates. Host checks are not physical
  ColorOS WebView or OnePlus 15 validation and do not prove a battery-life improvement or percentage;
  that needs a subsequent controlled device capture.

## V66 dev66 buildfix12 - split wakeup policies, exact component limits and evidence-only repairs

Input: the owner's fourteen-item wakeup/component/GPU/repair/WebUI revision, including Android Back,
fresh Zygisk reads, Smart BORE ownership and navigation/layout corrections.

- **Wakeup dialog and policies:** Android Back joins the close button, backdrop and Escape for the
  exact-name source modal. *Open sources* and *Clear window* are visually separate. Source cards use
  short everyday explanations with full details on demand; `asb_logkit_<pid>` is identified as ASB's
  own Infinite Log collector. Always and Screen-off exact-name policies have separate files, lists,
  counters and confirmations. Screen on/unknown applies Always only; screen off applies the deduplicated
  union. At most 16 unique printable-ASCII names of 1–63 bytes are accepted. Exact readback, fail-closed
  rollback, the optional KRILIKD ABI and `not exposed` outcomes remain mandatory. Reconciliation uses
  the existing five-minute service pass, not a new worker.
- **Activity/Service controls:** package details discover components on demand and disable one explicit
  `PACKAGE/CLASS` after a warning. The four-field ledger retains original state and component kind;
  legacy service records remain compatible. Restore uses exact `default-state`/`enable` semantics with
  readback. Generic WorkManager `SystemJobService` receives a package-wide jobs warning. No process
  freezer, arbitrary component writer, broad package disable or polling worker was added.
- **GPU evidence:** the supplied captures show late YouTube/Instagram frames across multiple ceilings
  with `smart_media_guard=0`; high busy share at a low clock is not an energy measurement. No universal
  GPU cap/floor, OnePlus frequency table or cross-device media rule was added. Existing profile,
  activity, thermal and vendor guards are unchanged.
- **Infirmary repairs:** Infinite Log recommendation rows no longer overlap. Battery Fix is now only
  the eligible one-shot reboot battery-statistics reset with removed/absent/failed evidence and cancel;
  ART/dexopt/dex2oat, package lists, progress and stop state are gone. HeyTap retains reversible
  package-state control without an ART request. SOTER `done` means clear/service workflow completion,
  not a physical key PASS: the UI and notification explicitly leave the physical key unverified and
  name AfterSale → Key Status → SOTER key as the separate check.
- **Smart BORE:** the registered owner `/proc/sys/kernel/sched_bore` joins Smart Auto scenarios:
  light/heavy select 1, idle/conserve select 0. Kernel-bound baseline, readback, Safe/recovery gates,
  exact restore and degraded `not_exposed` remain. Performance Auto keeps its conservative native
  thermal/activity gates. The card shows the actual kernel-read value as `Smart · 0/1`.
- **WebUI freshness and layout:** Zygisk clears old evidence and rereads on every opening, retains Save,
  removes Refresh and never paints stale content after a failed read. Monitor opens immediately without
  temporary dimming; Settings counters and the bottom bar wait for fresh configuration evidence. A
  Screen-off-only wakeup rule also counts as an active Kernel tweak; empty split policies count as zero.
  ASB properties on Device Diagnostics are collapsed by default. Splash keeps only metric-preload text and
  an ordinary progress bar, without visible LIVE/CONFIG/DEVICE/LOG or duplicate ZYGISK stage labels.
  All 13 locales are synchronized.
- **Verification:** targeted shell/Node fixtures cover split screen-state unions, 16-rule bounds,
  rollback, Activity/Service restore, reset-only Battery Fix, HeyTap handback, SOTER wording/boot
  sequencing, fresh-only Zygisk, immediate navigation, BORE scenarios/badge and all locales. Full
  working-tree and clean-source-ZIP regressions are release gates. Host/browser checks are not physical
  OnePlus 15/ColorOS WebView validation and do not establish a SOTER PASS, GPU energy cause, battery
  saving, responsiveness gain or measured improvement percentage.

## V66 dev66 buildfix11 - protected ASB reports, preview TNR ownership and scenario-driven Smart kernel controls

Input: the owner's five-item revision covering Junk Cleanup, camera preview processing, Device Diagnostics
readability and the authority of the Smart profile over existing kernel interfaces.

- **Junk Cleanup:** the ASB temporary-report category and its complete `/data/local/tmp` mapping are
  removed from both scan and delete scope. None of the seven former report names can be deleted directly
  or through a parent-directory glob. Ten bounded categories remain; the existing installer-cache,
  tombstone and DropBox mappings are explicitly pinned to `/data/system/package_cache`,
  `/data/tombstones` and `/data/system/dropbox`. Preview, per-category counts/results, unreadable and
  partial states, the run lock and two-stage five-second confirmation are unchanged.
- **Camera preview:** `CAMERA_PREVIEW_TNR=stock|off|on` owns only the existing
  `persist.camera.tnr.preview` and `persist.vendor.camera.tnr.preview` properties. Off/On request 0/1,
  capture each original value once (including an originally unset property), verify read-back and retain
  baselines after failure. Stock and uninstall restore exactly; competing managed-property/service writes
  were removed. A successful property write does not prove that every camera HAL mode honours it and is
  not evidence of recorded-video quality or smoothness.
- **Device Diagnostics:** cached and newly collected snapshots stay fully readable. Freshness remains in
  the timestamp/status text, explicit Refresh still performs a live read, and failed refreshes preserve
  the previous content without dimming it.
- **Smart kernel scenarios:** the existing bounded Smart tuner now calls the single registered kernel
  owner once per scenario pass. In Smart, Auto values of timer migration, hrtimer migration, scheduler
  migration batch, scheduler debug accounting, LPM prediction and RT boost follow closed
  idle/light/heavy/conserve mappings. Warm heavy work is derated to light; hot or screen-off work selects
  conserve. Manual values are excluded. The saved scenario plan supports later reinforcement without
  restoring static Smart defaults; profile handoff and full restore remove it. Kernel-bound baselines,
  exact restoration, read-back, missing-node/degraded reporting, the hrtimer coverage rule, RT readiness,
  Safe mode and recovery gates remain authoritative. No arbitrary path/value writer or polling worker was
  added. Config schema remains 4: the camera key is additive, and existing Stock/Off values for
  scheduler debug accounting retain their meaning; only the shipped default and option set changed.
- **Verification:** targeted host fixtures cover cleanup scope and report survival, camera property
  baselines/failures/boot/uninstall, snapshot readability and locale coverage, plus Smart scenario
  transitions, thermal derating, manual exclusions, plan reinforcement and exact restore. Full
  working-tree and clean-source-ZIP regressions are release gates. These are not physical OnePlus 15 or
  ColorOS WebView/HAL results; no performance, battery, preview-FPS or recorded-video gain is claimed.

## V66 dev66 buildfix10 - paint-first Camera, continuous Zygisk controls and faster Monitor navigation

Input: the owner's four-item WebUI revision covering slow Camera category opening, unwanted
lines between the four Zygisk switches, Monitor opening cost and animation smoothness.

- **Camera:** the category and both Camera Tools cards are fully drawn before capabilities,
  camera-grade and USB/ART status evidence start. These are one-shot post-entrance reads, not
  pollers. If the page closes or the WebView is hidden before the deferred read, it does not run
  and the capability/grade state remains retryable. Both explicit Check again buttons and all
  post-write read-backs retain their immediate live reads.
- **Zygisk Settings:** the four switch rows remain in one continuous card. The generated
  `::before` hairlines between them are removed in ordinary and Liquid Glass themes; no spacing,
  state indication, control or evidence row was removed.
- **Monitor:** the bounded splash Live job now retains its complete Stock and non-Stock snapshot
  while Monitor is closed. An overlapping collector preserves that explicit prefetch request;
  ordinary closed-page reads, hidden-document reads and page-sequence stale guards remain in
  force. Opening paints the cached tiles before a two-frame, sequence-guarded entrance. A very
  recent successful sample can defer the duplicate opening read, but only within 1200 ms; the
  mandatory fresh visible read is not replaced by a cache.
- **Motion:** Monitor moves only after its restored layer has had a rendered frame. Profile card,
  icon, label and checkmark transitions now name their actual properties instead of `all`;
  letter-spacing no longer animates. No persistent worker, ambient timer or layout-animation
  loop was added.
- **Verification:** targeted source and Node fixtures cover deferral/retry, manual Camera refresh,
  both Monitor prefetch branches, overlap/freshness/stale behavior, two-frame entrance and CSS
  transition ownership. The lint group-membership checks no longer write into an early-closed
  `grep -q` pipe, removing an intermittent Broken pipe diagnostic without changing their verdict.
  Full working-tree and clean-source-ZIP regressions are release gates. These are host-side
  contracts, not measured ColorOS WebView latency/frame-time improvements or
  physical OnePlus 15 validation.

## V66 dev66 buildfix9 - applicable log evidence, complete startup snapshots and bounded Battery Fix

Input: the owner's four-item revision of Infinite Log, Device Diagnostics, startup page loading and
Battery Fix after ColorOS Package Manager repeatedly returned Binder `Failed transaction`.

- **Infinite Log → Infirmary:** sufficiently captured night drain, measured at-cap jank and
  sustained heat can now name a concrete current → recommended value. The closed operation list is
  limited to `night_modem_idle=1`, `doze_level=night`, `net_screen_off_lte=1` (only with independent
  long-night drain evidence), `perf_ceiling_pct=100`, `sustained_temp_mode=smart` and
  `sustained_temp_enter=65`. Existing evidence floors and ROM/fair-cap exclusions remain. The
  Infirmary card uses the same report snapshot, shows a preview and requires a second tap within
  six seconds. It re-reads `governor.conf` before writing, skips values changed since the preview,
  uses the existing validated/atomic `cfgSet()` owner and accepts success only after a separate
  saved-config read-back. A failed read or an optimistic in-memory value is not an applied result.
- **Device schema 6:** ADIOS build config, bounded symbol evidence, per-queue exposure, inactive /
  active / mixed selection and ASB's existing I/O owner are separate rows. Config or symbols alone
  do not prove runtime selection; absent evidence remains unknown/not runtime-discoverable. ASB
  writes no private ADIOS tunable. Static `system.prop`, validated managed properties and the
  conditional safe-media property show configured/live/readback values and their actual owner.
  Empty static `system.prop` is intentional. BT properties remain behind their separate opt-in;
  aggregate owner counters do not prove an individual write.
- **Startup snapshots:** the once-per-boot splash performs five bounded jobs: Live, Config, Device,
  Infinite Log and the complete Zygisk read. Device, Infinite Log and Zygisk open immediately from
  that snapshot (or a bounded persistent Device/Log cache), with the snapshot time/state visible.
  Navigation does not recollect; each explicit Refresh still performs a live read, and a missing
  snapshot retains one bounded fallback. Live/Monitor freshness rules are unchanged. No persistent
  polling worker was added.
- **Battery Fix:** the broken aggregate `compile ... -a` recovery path was removed. Compilation is
  package-scoped through `cmd package compile -m speed-profile -f PKG`, with package-scoped
  `pm compile` fallback. Three consecutive Binder refusals stop the run by default. Results are
  `scheduled`, `refused` or `partial` as applicable; only processed packages contribute to
  succeeded/failed counts, and unattempted apps are named separately. An accepted Android
  background job does not prove `speed-profile` compilation. The battery-statistics reset remains
  a distinct reboot-time operation. No Dalvik/ART wipe or direct `dex2oat` was introduced.
- **Verification:** host fixtures cover recommendation evidence/whitelist/locales, two-tap apply,
  changed-since-preview protection, final-read failure, repaint-safe per-setting readback, ADIOS
  states, property match/mismatch/selection, five-stage splash and snapshot navigation. Full
  working-tree and clean-source-ZIP regressions are release gates. These are not physical ColorOS
  WebView or OnePlus 15 field results, and no battery, heat, latency or smoothness gain is claimed.

## V66 dev66 buildfix8 - measured interaction headroom, honest Smart limits and multi-day capture epochs

Input: the owner's ten-item field/UI/workflow revision and a new 254-minute full-day capture,
asbdiag, screenshots and three GitHub Actions log sets. The capture is evidence about the tested
installed build, not physical validation of this source revision.

- **Performance complaint:** the strongest corroborated signal was LIGHT_IDLE YouTube work at the
  500 MHz GPU ceiling with long GPU/frame times, not a general governor-overhead or chattering
  finding. GPU idle trim now keeps its existing profile ceiling when visible GPU load reaches
  12% or recent touch evidence is present. Idle trim remains for genuinely idle content;
  Performance, video, thermal-cap, camera and screen-off guards are unchanged. No user setting
  was reset and no persistent worker or permanent Performance mode was added.
- **Settings/Zygisk:** four embedded toggles use subtle hairlines in dark Liquid Glass. A measured
  short-fit class suppresses only redundant scrolling; overflow is re-enabled whenever content,
  search, a small screen or enlarged text needs it.
- **Smart explanations and ownership:** long Auto/profile hints are concise, with the full meaning
  retained in tooltips. `SMART · PROFILE` means a profile-selected Auto value. The new
  `SMART · LIMIT` marks the user's fixed performance ceiling and prime burst/rest guards; the
  prime master switch receives AUTO only when the bounded mechanism is enabled. Manual thermal
  ceilings do not acquire a false AUTO badge.
- **DSP:** Smart no longer mirrors or claims ownership of DSP loudness/effects. DSP remains a
  manual audio setting. The separate profile-neutral loudspeaker battery-temperature safety
  guard remains; it is not presented as Smart control.
- **Presentation:** Fast Camera Start is immediately followed by USB Webcam. Battery Fix, SOTER
  and Junk Cleanup show short summaries with their complete explanations under Details. The
  Zygisk page folds additional long descriptions in place, with keyboard activation, while
  retaining evidence and actions. All 13 locales carry the new text.
- **Infinite Log:** charging remains in distinct phases and drain uses off-charger windows;
  reboot/restart gaps stay outside phases and process-local gfxstats baselines start fresh.
  In addition, the existing recorder loop now fingerprints the installed ASB build and kernel.
  An identity change closes and archives the old epoch, including its report and hidden counter
  baselines, then starts a clean epoch in the same capture bundle. `epoch_history.tsv` indexes
  separate reports; the current report never totals incompatible builds. A normal user stop
  still finalises and clears resume ownership, so a later start is a new capture directory.
- **NoMount:** the kernel Update Check compared known-good `master` pins with upstream `dev`,
  although Build resolves and integrates `master`. Update Check now uses `master` too. The 21
  commits in the supplied log were therefore cross-branch differences, not evidence that
  Mark known-good forgot the booted pin. Known-good attestation and fail-closed full-build
  classification are unchanged.
- **Verification:** 412 ASB host tests plus schema/lint/native/DSP static gates passed in
  source-only mode. Targeted fixtures cover the GPU activity guard, Smart badges, camera order,
  compact UI, identity rotation and legacy resume. No measured responsiveness or battery gain,
  physical ColorOS WebView result, or new kernel boot result is claimed.

## V66 dev66 buildfix7 - ADIOS runtime discovery, explicit Smart ownership and Binder-safe AppOps

Input: the owner's five-item ADIOS/Smart/audio/action/log request and the 16 November 2026 device,
report, Zygisk, asbdiag and full-day capture set. The captures came from V66-test7 (660), so they
are not physical validation of buildfix6 or this source revision.

- **ADIOS:** `io_scheduler=auto` prefers `adios` only when each targeted non-rotational queue
  actually exposes it. Existing `mq-deadline`/`kyber`/`none`/`bfq` fallbacks, explicit choices,
  per-device baselines, preflight, readback, kernel-id invalidation and exact Stock restore remain
  unchanged. ASB writes no ADIOS private tunables. The WebUI documents the new choice in all 13
  locales; `action.sh` and `asbdiag` report requested mode, live scheduler, baseline and exposure.
- **Smart ownership:** the former five badges were exactly the old `cfgSmartOwner()` list, not
  proof that nothing else was controlled. `auto_battery_enable=1` and Smart thermal mode now show
  dynamic/thermal ownership. Profile-dependent `auto` kernel/I/O/network cards show the distinct
  `SMART · PROFILE` badge; DSP keeps its specific thermal explanation. Manual values, user limits,
  doze policy and other guards are not mislabeled as Smart-owned.
- **Volume alert:** no duplicate setting was added. Existing `audio_remove_volume_limit=1` already
  sets `audio.safemedia.bypass=true` in post-fs-data and Android's safe-volume state in service;
  the uploaded device log confirms both. `action.sh` now distinguishes property presence, Android
  confirmation, a still-active limiter and a pending reboot.
- **AppOps transport:** a shared bounded wrapper detects the ColorOS Java client's
  `Failure calling service appops` even when it exits 0, retries the same operation through
  `cmd appops`, and fails honestly if both transports fail. Fitness/wakelock diagnostics report
  `unknown`, not a fabricated `default` or a proven lapse. No persistent poller was added.
- **Log conclusions left bounded:** the refused `network_recommendations_enabled` setting remains
  refused rather than fought; native crashes without ASB frames are not attributed to ASB; the
  current-gauge scale is retained as corrected gauge evidence; MGLRU's known clamp, mixed sleep
  phases and unavailable >=180-minute night verdict are not rewritten into successes. The existing
  reconcile passive vendor-ownership guard remains the owner for the observed uclamp drift.
- **Verification boundary:** source tests cover ADIOS discovery/fallback/restore, expanded Smart
  badges, action localization and AppOps fallback. No physical OnePlus 15/UFS responsiveness,
  throughput or battery gain is claimed; ADIOS requires same-kernel field A/B.

## V66 dev66 buildfix6 - trend truthfulness, bounded I/O discovery and companion-safe DSP headroom

Input: the owner's seven-item revision request plus a repeated visual field report covering the
UFO/orbit animation and ordinary/Liquid Glass backgrounds.

- **Trend:** the Stock badge and dashed line share one regression slope. In Smart, the badge and
  dashed control line use the same native `kv.smart_trend_slope`; the solid history remains the
  measured WebUI samples. A warming message can no longer be paired with a cooling dashed line.
- **Smart ownership:** conditional Smart indicators identify only actual dynamic/radio/thermal
  ownership. Manual `mglru_mode=on/off/stock` now reaches the existing bounded helper in Smart;
  only `mglru_mode=smart` remains dynamically owned. Failure/readback badges stay visible.
- **Block I/O scheduler:** `io_scheduler` discovers exposed scheduler names per bounded block
  device, supports custom kernel names, preflights the complete set, captures a per-device
  baseline, verifies readback and restores Stock only for the same kernel. Auto never invents an
  unavailable scheduler; an explicit unsupported request fails without substitution.
- **TCP congestion control:** all three route cards consume the existing read-only runtime
  algorithm discovery. BIC, Westwood and other exposed algorithms receive localized descriptions;
  custom names use an honest RTT/loss/buffer/qdisc caveat rather than a generic performance claim.
- **DSP +30 dB source ceiling:** UI, shared native core, apply, thermal, installer, diagnostics,
  tests and all 13 locales now agree on 3000 mB. Both wrappers expose `gain_cap_mb=3000`; the build
  and `asbdiag` identify old prebuilts. Existing prebuilt libraries still require replacement by a
  new user workflow build. The limiter remains sample-peak, not oversampled true-peak. Android 17 /
  ColorOS 17 AIDL V2/V3 source paths remain branch-matched; no physical runtime support is claimed.
- **Visual lifecycle:** automatic `ui-jank` no longer destroys UFO/orbit/wordmark animation clocks;
  real OS reduced-motion remains authoritative. Ordinary dark/light and both Liquid Glass canvases,
  page roots and status scrim use solid colors; card-level Glass material washes remain intact.
- **Evidence boundary:** host fixtures, native compilation and Chromium computed-style/timeline
  checks cover these source contracts. They do not establish physical ColorOS WebView smoothness,
  audible DSP quality, network throughput, storage latency or battery improvement on OnePlus 15.

## V66 dev66 buildfix5 - WebUI lifecycle, boot repair recovery and clearer diagnostics

Input: the owner's eight-item revision request for the WebUI header and dark canvas, SOTER and
Battery Fix recovery, Zygisk presentation, full-day capture placement, setting descriptions,
WebUI cost and wakeup-source explanations.

- **Native WebUI animation ownership:** visible page headers resume their existing CSS timelines
  when reopened; closed-page and reduced-motion pauses remain intact. The 100 ms
  `document.getAnimations()` ambient ticker and destructive wordmark animation resets are gone.
  Dark Liquid Glass now uses the same `var(--bg)` canvas instead of body-level green radial
  gradients. Calm mode retains one bounded timer and only pauses the Smart glow through CSS.
- **SOTER boot repair:** the existing opt-in asynchronous `service.sh` launcher is retained.
  CE-directory existence is no longer treated as first-unlock evidence: repair requires CE
  availability or `RUNNING_UNLOCKED`, validates it again after the settle delay and skips without
  clearing SOTER data if readiness was lost.
- **Battery Fix:** after Binder-specific aggregate compilation refusal, one official
  `cmd package bg-dexopt-job` is attempted when enabled. An accepted job is reported as
  `scheduled`, not as verified `speed-profile` compilation. A rejected job still fails closed;
  the existing 100%-and-charging gate and exact battery-reset file set are unchanged.
- **Diagnostics and logs:** the five Zygisk activity/cost cards gain decorative emoji without
  changing values or evidence semantics. New full-day captures live under
  `ASB/logs/asb_log_full_day_*`; resume and digest discovery still accept legacy root-level
  captures.
- **Explanations:** Interface and Screen/Feel descriptions now identify their Settings owner,
  read-back limits, Stock restoration and feature-specific trade-offs. Every observed wakeup
  source receives a conservative approximate purpose and graded blocking-risk explanation in all
  13 locales; unknown names explicitly remain unknown and are not declared safe to block.
- **Evidence boundary:** host fixtures and the full six-suite regression verify source behavior,
  lifecycle contracts, localization and recovery states. They do not establish physical OnePlus
  15/ColorOS WebView animation smoothness, SOTER repair, ART recovery or battery improvement.

## V66 dev66 buildfix4 - audit-driven strict TTL input and explicit pointer baseline semantics

Input: the owner's Russian diff-audit of buildfix2, re-checked item by item against the buildfix3
source. Only findings confirmed by that source were changed.

- **G3, strict MGLRU TTL vocabulary:** `kernel_mglru_min_ttl` accepts only `stock`, `1000` and
  `2000`. Legacy `5000` and other unsupported values now produce `invalid_value` from both apply
  and status, without a sysfs write or baseline replacement; the atomic config writer rejects them
  without changing `governor.conf`. The former silent `5000`→`2000` coercion and the stale English
  `5000 ms` option label are removed. Existing valid baseline capture and exact Stock restore stay
  unchanged.
- **G4, honest pointer-speed restore:** the Pointer Speed card now states in the fallback text and
  all 13 locales that Stock restores the value captured at ASB's first override, not necessarily a
  factory default. The Settings writer, bounded −7..7 mapping, read-back and exact restore logic
  are unchanged.
- **Audit items not requiring a patch:** both host tools from G1 already run inside the mandatory
  canonical regression used by both workflows. G2's reduced-effects tier already disables its blur
  layers; phone frame-time measurement remains field work. G5/G6 require no action, and G7's
  pre-publication OTA manifest check already exists as an intentional advisory step. The Smart Lab
  defaults stay enabled: the cited host/field observations do not establish harmful overhead or a
  failed memory-bus writer, and the existing ownership/yield gates remain in force.
- **Evidence boundary:** new fixtures prove rejection, non-mutation and localized wording on the
  host. They do not measure phone battery life, Liquid Glass frame time, physical ART recovery,
  BORE/RT transitions or ColorOS panel behaviour.

## V66 dev66 buildfix3 - continuous visible-header animation through idle calm

Input: the owner's field report that the WebUI header still froze about ten seconds after opening
on buildfix2. A real Chromium run reproduced the exact boundary: the UFO layers stayed on their
native clocks, but `html.asb-calm .app-name` still applied `animation: none !important` when the
ten-second idle timer fired. The previous repair had therefore left the wordmark sweep stopped.

- **Whole visible header stays alive:** both remaining calm selectors for `.app-name` are removed.
  The UFO shells, pulsing pod, wordmark sweep and header indicators now retain their native CSS
  animation clocks while their page is visible. No animation is manually restarted and no `rAF`
  loop, interval, worker or persistent poller was added.
- **Unchanged ownership boundaries:** closed/background pages still stop their decorative header
  loops; `prefers-reduced-motion` and the existing reduced-effects setting still disable them.
  Only the separate Smart-card glow uses the existing idle ambient ticker. Navigation, Battery
  Fix, profiles, thermal ownership and runtime scripts are untouched.
- **Regression and visual evidence:** source guards now reject every header layer, including the
  wordmark, in any calm selector while preserving closed-page rules and the single bounded calm
  timer. Across the six host suites, piped quiet-grep assertions now consume complete input
  instead of closing their producers at the first match; their patterns, status checks and the
  production helpers are unchanged. In Chromium with
  calm active, all four principal header layers remained `running` and their `currentTime`
  advanced at 11, 12 and 65 seconds; reduced-motion still returned `animation-name: none`. This
  is host-browser evidence, not physical ColorOS WebView validation.

## V66 dev66 buildfix2 - bounded Battery Fix ART recovery after Binder refusal

Input: the owner's Battery Fix screenshots from dev66 buildfix1. All twelve initial per-package
ART attempts returned `Failed transaction (2147483646)`, the per-package `pm` fallback did not
recover them, and no application was reported as recompiled. The separate battery-statistics reset
worked and remains unchanged.

- **Binder-specific aggregate recovery:** the first per-package Binder refusal now triggers one
  aggregate `cmd package compile -m speed-profile -f -a` operation, followed by aggregate `pm`
  only when `cmd` did not explicitly return `Success`. Ordinary per-package failures keep their
  existing path; there is no direct `dex2oat`, SELinux bypass or root-context switch.
- **Fail-closed reporting:** aggregate success is accepted only after Android's explicit
  `Success`. If both aggregate owners also fail, the worker enters `refused` after the first
  package instead of repeating twelve equivalent failures. It preserves Android's error text and
  does not infer that any application was recompiled. The existing final background-dexopt handoff
  and the one-shot reset of exactly the three battery-statistics files are unchanged.
- **Coherent WebUI:** the line-oriented protocol adds only the `bulk` phase. A dedicated running
  message and final refusal text describe all three rejected paths without claiming verified ART
  recovery; all 13 locale JSON files are synchronized.
- **Clean test pipelines:** the logkit capture-quality and jank-trace assertions consume their
  complete producer output rather than letting an early `grep -q`/`head` match close the pipe.
  The diagnostic helpers and their reports are unchanged.
- **Host-only evidence:** targeted fixtures cover aggregate `cmd` success, aggregate `pm` success,
  complete Binder refusal, exact call counts, cleared stale errors on success and preserved error
  provenance on refusal. These tests validate control flow and reporting, not physical ART or
  PackageManager recovery on the owner's OnePlus 15; field validation still requires rerunning
  Battery Fix on that device.

## V66 dev66 buildfix1 - deterministic module-card settle CI

Input: the owner's three host-regression shards. `system-smart` stopped in
`module_desc_zygisk_dev57`: the description still said Zygisk was waiting after the asynchronous
settle fixture. The other two shards completed; this was a host-test race, not a native build or
Zygisk runtime failure.

- **Deterministic settle fixture:** a scoped `sleep` stub now publishes the connected state on the
  second poll and records the number of waits. The bounded branch separately requires exactly five
  waits with no published connection. It no longer depends on a background writer and wall-clock
  scheduling on a loaded CI runner. The production helper and its default ten-second settle cadence
  are unchanged.
- **Clean pipeline assertion:** the Zygisk status fixture consumes its complete input instead of
  letting an early `grep -q` match close the pipe. No status field or runtime behaviour changed.
- **Scope:** only test/documentation metadata changed. No profile, governor, thermal, scheduler,
  Safe-mode or WebUI code was altered. Host CI remains distinct from physical device validation.

## V66 dev66 - foreground-game provenance and WebUI motion/read coherence

Input: the dev65 buildfix1 source, a full-day ASB capture and diagnostic report, and the owner's
six WebUI/runtime findings. The game finding is a code-level repair supported by the capture, not
a measured on-device smoothness result.

- **Foreground game provenance:** the capture showed Brawl Stars jank while Smart remained
  `MODERATE`, with `pkg_detect_ok=0` and `pkg_source=0`; Android's own snapshot simultaneously
  named the game in `topResumedActivity` / `ResumedActivity`. The top-app resolver now accepts an
  adj-0 group only when exactly one unique positively classified visible game is present. Two
  visible games stay ambiguous, and a non-adj-0 background game cannot outrank the visible app.
  The resumed-ActivityRecord fallback recognizes current ColorOS and legacy field names. New
  counters expose locally resolved game groups. No frequencies, thermal limits, vendor thermal
  ownership, Safe mode or static device tables changed.
- **Header motion:** visible UFO/header CSS animations remain on the native animation clock after
  the ten-second calm transition. The existing 100 ms ambient ticker now advances only `ai-spin`
  and defensively excludes boot/header elements; hidden-page, closed-page and reduced-effects
  ownership remains intact.
- **Navigation:** the existing Monitor and background root-read timers now defer around the
  existing page-transition deadline. No second poller, persistent worker or interval was added.
- **Monitor semantics and Trend:** the foreground-app Load sheet labels its pressure bar
  `System: {band}` so it cannot be read as a second app-class verdict. Trend now draws the existing
  measured temperature series plus a dashed least-squares overall-direction line for Smart and
  Stock, using their existing sample owners. Fewer than two valid readings produce an honest wait
  message, not a fabricated diagram.
- **Liquid Glass:** strong/popup surfaces use 0.90 opacity in dark and light themes; the existing
  blur/material structure and component geometry are unchanged.
- **Regressions:** targeted runtime tests cover current/legacy ActivityRecord parsing, ambiguous
  top-app groups, background-game exclusion, native-clock header ownership, navigation-timer
  deferral, Smart/Stock trend data, one-point no-chart behaviour, explicit system-load wording and
  all 13 locale files. Browser/host checks do not establish physical ColorOS WebView behaviour or
  improved game frame times.

## V66 dev65 buildfix1 - coherent WebUI/config metadata for CI

Input: the three failed GitHub Actions shards from the owner's build log. Every shard stopped in
`tools/asb_lint.sh` before its test selection ran. The failing checkout contained the eight dev64
WebUI cards together with the older 237-key configuration/registry state and shape
`928eea600217`; the coherent dev65 source archive already contained the matching 245-key state.

- **Root cause and repair boundary:** this was mixed source metadata, not a BORE, profile, thermal,
  Settings-writer or WebUI-runtime failure. The complete corrective set for the stale checkout is
  `config/governor.conf`, `config/governor.conf.shipped` and `config/key_ownership.tsv`. All eight
  affected cards are public `user` rows, both configuration copies are synchronized and record the
  actually computed `d672ad7af963` shape. No stored value changed meaning, so schema 4 and every
  shipped default remain unchanged; there is deliberately no artificial schema bump or runtime edit.
- **Targeted regression:** `t_config_metadata_coherence_buildfix1` checks all eight public rows,
  both 245-key configuration copies, the exact line-oriented lint fingerprint and schema 4. It then
  constructs the logged stale mixture in an isolated tree, requires the same two ownership/shape
  lint failures, restores only the three metadata files and requires zero lint errors. A future
  partial upload or mixed checkout therefore fails in the source gate rather than reaching a module
  package with incoherent metadata.
- **Reproduction and full host regression:** the isolated stale fixture returned lint status 1 with
  exactly two errors; after the three-file repair it returned status 0, zero errors and zero
  warnings. The complete source-only regression passed 554 `PASS` lines with zero failed tests,
  zero `I/O error` and only the established optional DSP-reference staging `SKIP`; no replacement
  binaries were created. Clean-unpack verification is recorded in `RELEASE_MANIFEST.json`. These
  are host/source results, not a physical OnePlus 15 or ColorOS WebView validation.

## V66 dev65 - conservative BORE Auto and measured-only scheduler A/B evidence

Input: the dev64 source and the owner's GKI 6.12/6.18 compatibility and scheduler-policy audit.
The audit's runtime part is implemented in the existing ASB kernel owner; the kernel-source,
KMI and patch-applicability parts remain in the companion kernel repository.

- **Conservative, opt-in BORE Auto:** `kernel_bore` now accepts `stock|auto|off|on` in the
  closed config vocabulary, safe writer, WebUI and all 13 locales. The shipped default remains
  `stock`; upgrades therefore do not change BORE policy. Auto is evaluated only by the existing
  boot/profile/reinforce calls, with no polling worker or second writer.
- **Fresh evidence and exact restore:** Auto can request `1` only in Performance, with Android
  battery saver explicitly off, a known charge above the configured low threshold, a zero native
  thermal cap and fresh `MODERATE` or `HEAVY` state. Both `temp_age_s` and the age derived from
  `temp_read_epoch` must be at most 120 s; CPU, skin, surface and board readings must be numeric
  and below the existing configured thermal boundaries. Other profiles, low/unknown charge,
  unavailable/unknown battery-saver state, idle/gaming/SUSTAINED, heat, missing/stale/malformed
  native status, Safe mode and watchdog recovery take the exact kernel-bound baseline restore
  path. With no owned baseline they write nothing. Missing, read-only, non-binary or mismatching
  BORE ABI never produces `applied`; baseline is removed only after successful restore readback.
- **Measured-only offline A/B:** `tools/asb_scheduler_ab.py` creates an explicitly
  `not_measured` template, validates declared field captures and compares a same-kernel BORE
  off/on pair. It rejects mismatched kernel commit/release/version/family, root, SUSFS, ASB,
  feature-set and workload identities. Only finite numeric leaves receive candidate-minus-
  baseline deltas; nulls stay `not_measured`, partial data become `not_comparable`, logs remain
  uncomputed evidence, and no improvement percentage or verdict is generated. This is a host
  source tool, not a new on-device polling collector or release-package user tool.
- **Tests:** targeted fixtures exercise Auto in both directions for every guard, exact zero/one
  baselines, stale epoch versus stale age, Safe mode/watchdog, unknown/missing/read-only/
  malformed ABI and readback cleanup. A/B fixtures cover template nulls, measured validation,
  nested numeric deltas and every identity rejection. These are host tests, not physical
  OnePlus 15 BORE responsiveness, thermal, battery-drain or ColorOS WebView validation.
- **Full host regression:** the complete source-only run passed 553 `PASS` lines with zero
  failed tests and zero `I/O error`. The single `SKIP` is the explicitly optional DSP reference
  staging gate because the reference prebuilt `.so` files are absent; no replacement binaries
  were created. A second clean-unpack run is part of the source-archive release check.

## V66 dev64 - bounded ColorOS interface and display controls

Input: the dev63 source and six SetEdit JSON exports from the owner's OnePlus 15. The exports
were used as device evidence and ideas, not as permission to write every discovered key.
Eight non-duplicating controls were added; adaptive-refresh, animation-scale and blur keys
were deliberately left with their existing ASB owners.

- **Interface:** Recents memory indicator (`secure/display_memory_information_recent_task`),
  paired Recents radius master/dp value (`global/oost_recent_task_radius` and
  `global/oost_recent_task_radius_dp`, bounded to stock/0/8/12/16/20/24/28/32), smooth screen
  corners (`global/smooth_corner_enabled`) and navigation-handle auto-hide
  (`global/oost_navigation_handle_auto_hide`).
- **Display & response:** pointer speed (`system/pointer_speed`, stock or -7..7 for an actual
  pointer rather than touchscreen polling), gesture mistouch prevention
  (`secure/gesture_mistouch_prevention_enable`), game MEMC
  (`secure/display_memc_game_enable`) and the DC-dimming system switch
  (`secure/display_dc_settings_switch`). MEMC/DC visual activation remains panel-, game- and
  ColorOS-dependent; a successful Settings write is not presented as proof of that activation.
- **One bounded runtime owner:** `runtime/asb_display_ui_apply.sh` maps only the closed values
  above through the existing Settings/content fallback. Every write is read back. `stock`
  writes nothing when ASB has no baseline, and otherwise restores the exact pre-ASB value.
  Boot re-asserts explicit overrides only. Uninstall continues through the common baseline
  replay; no polling worker, arbitrary namespace/key/value writer or SystemUI restart was added.
- **Two restore scopes:** a failed edit rolls back to a separate pre-attempt snapshot, while
  the long-lived pre-ASB baseline remains intact for the later explicit return to Stock. The
  paired Recents radius values roll back together if either half fails. WebUI distinguishes
  `applied`, `restored`, `stock_unowned`, `write_failed` and `restore_failed`; a saved config
  line alone never produces an applied toast.
- **Schema and package:** all eight cards have unique SVG icons, live apply semantics,
  snapshot/export coverage, safe-writer validation, update migration and installer/CI/boot
  wiring. The ownership registry is synchronized at 245 keys / 113 cards. Names, descriptions,
  per-option details and apply verdicts are present in all 13 locales.
- **Verification:** targeted runtime fixtures cover all mappings, exact restore, rejected
  writes, paired-radius rollback, pre-attempt versus pre-ASB restore, stock boot ownership and
  invalid-value rejection. The complete source-only host regression with
  `ASB_DSP_REFERENCE_OPTIONAL=1` passed all 561 PASS lines with zero failed commands and zero
  `I/O error`. Optional reference DSP `.so` files remain absent. These are host results, not a
  physical OnePlus 15/ColorOS WebView, launcher-radius, MEMC, DC-dimming or power measurement.

## V66 dev63 - WebUI scheduling, bounded kernel evidence and benchmark isolation

Input: the owner's dev62 source, the V66 WebUI acceleration audit and the phone log/archive
set. Ten requested items were implemented at source level; the existing config registry,
first-frame queue, batch bridge, event-driven LTPO watcher, kernel-bound writer and Safe mode
remain the owners of their respective operations. No persistent polling worker was added.

- **WebUI work and page lifecycle:** fitting/navigation paints share one animation-frame
  queue. Three slow visible frames select the reduced-effects presentation, which keeps
  colours, selected states and feedback but drops expensive blur/decorative perpetual motion.
  The existing batch bridge has an explicit opt-in TTL (`part[2]`, bounded to seven days),
  keyed by both part and command; two-element calls still execute and failed reads are not
  cached. Monitor uses one locked schedule with 3/5/8/12-second backoff only after unchanged
  complete successful snapshots. Hidden pages clear their timers; visibility restoration,
  stale-page sequence checks and one fresh follow-up paint remain covered by runtime tests.
- **BORE:** Device diagnostics reports `CONFIG_SCHED_BORE`, the fixed
  `/proc/sys/kernel/sched_bore` node and write access as different evidence classes. The
  `kernel_bore=stock|off|on` control accepts only 0/1, records a kernel-bound baseline,
  validates and reads back every write and restores the exact baseline. Stock is the shipped
  default, so upgrading does not change scheduler policy. A KRILIKD installation log alone
  is not treated as a runtime interface.
- **LTPO idle descent:** `ltpo_idle_speed=fast|balanced|gentle` maps to 1 s/1 s, 2 s/1 s and
  5 s/3 s initial/step delays in the existing blocking input watcher. It still descends only
  through advertised Android modes, restores the panel maximum on touch and preserves camera,
  game and external-owner guards. No synthetic `peak_refresh_rate=1.0`, static table from
  another panel or new polling worker was introduced; below the Android floor, descent toward
  1 Hz remains panel/ADFR-dependent.
- **Battery Fix and ART:** same-boot monotonic evidence rebuilds an invalid/missing RTC
  `done_at`, while a timestamp already close to that evidence is retained. A PackageManager
  Binder `Failed transaction` now tries the bounded `pm compile -m speed-profile -f` fallback
  and retains the original diagnostic if that also fails. One failed transaction is not
  reported as proof that every package rejected compilation.
- **SOTER:** a successful manual repair in the current boot suppresses a duplicate delayed
  automatic clear; switching automatic repair off during the settle is honoured. Completion
  records boot ID and uptime. The notification now says that server data were cleared and app
  functionality was not tested, rather than claiming that the service or payments work.
- **Monitor semantics:** the foreground app's class and whole-system PSI/CPU/GPU pressure are
  labelled as separate metrics before the detailed note, so a light foreground app no longer
  contradicts the system load bar.
- **Profiles and benchmark evidence:** a benchmark-intent session skips the per-profile
  memory update. Smart still normalizes to the Balanced store, but an AnTuTu Smart →
  Performance run can no longer teach that shared store. Battery was not relabelled from that
  evidence. In the FSM, saturated GPU load with quiet CPU reaches MODERATE before the
  LIGHT_IDLE shortcut; thermal exits and the existing GPU-bound latch remain downstream.
  SUSTAINED/HEAVY/MODERATE/LIGHT_IDLE thresholds, thermal ownership and Safe mode were not
  replaced with benchmark-specific static tables.
- **Zygisk provider identity:** the read-only collector recognizes NyaZygisk, NeoZygisk,
  BreZygisk, ReZygisk and Zygisk Next from bounded `module.prop` name/version metadata and
  disable/remove markers. Multiple enabled providers are a conflict, inactive ambiguity stays
  unknown, and module metadata is explicitly not proof of activity inside running Zygote
  processes. Values continue to reach the page through `textContent`.
- **Localization and package contracts:** BORE, LTPO, ART, Monitor and provider strings are
  complete in all 13 locales. The two new Config cards have unique SVG icons; the ownership
  registry is synchronized at 237 keys / 105 cards.
- **Verification:** the affected runtime fixtures were repaired without hiding production
  stderr or deleting assertions. The complete WebUI suite passed 131/131. The full source-only
  host regression with `ASB_DSP_REFERENCE_OPTIONAL=1` passed all 549 PASS lines with zero
  failed commands and zero `I/O error`. The optional reference DSP `.so` files remain absent;
  no replacement binaries were invented. These are host results, not physical ColorOS WebView,
  KRILIKD BORE, 1 Hz panel, SOTER payment or new AnTuTu validation.

## V66 dev62 - Liquid Glass retuned to the ColorOS 17 references (fix351)

Input: the dev61 source and three ColorOS 17 screenshots (the media platter, the stopwatch
and the compact media card): matte, strongly blurred dark glass with a soft light along the
lower inner edge and large radii. The request: bring the WebUI's Liquid Glass theme closer
to that material. Paint only - no native source, geometry, radius or behaviour changed.

- **Dark canvas:** keeps the genuinely black base (fix324). A faint neutral ambient of cool
  greys - no accent hue - now sits under it, so the stronger backdrop blur has real texture
  to work with instead of blurring a flat void into flat grey. Accent light still belongs
  to controls and the logo, never to a screen-sized wash; the fix324 rejection of a
  coloured full-screen wash stands, and the contract test still forbids any accent stop in
  the dark canvas.
- **Underlight:** new `--glass-underlight` token (dark `rgba(255,255,255,.055)`, light
  `rgba(255,255,255,.50)`), painted as `inset 0 -1px 0` on every painted surface family:
  the shared surface rule, floating chrome in both palettes, sheets, the toast, profile
  buttons (idle and selected), config rows (idle and on) and category tiles. This is the
  ColorOS "light leak" that makes a pill read as a thick translucent slab rather than a
  flat card. Header capsules keep `--cap-shadow` unchanged; inset controls, nested evidence
  regions and pressed states deliberately stay without it.
- **Clearer surfaces, stronger blur ladder:** dark surfaces .58→.52, quiet .46→.42, strong
  .78→.74, navigation .86→.84, controls .48→.44; light surfaces .44→.42, quiet .34→.32,
  strong .72→.70, controls .38→.36. Blur moves to 22 px / saturate 1.28 on content, 28 px /
  1.30 on floating chrome, 32 px / 1.28 on sheets, 20 px / 1.24 on header capsules, 26 px /
  1.28 on the toast and 16 px on the status scrim. Washes gain a cool tint
  (`rgba(196,214,255,.05)` dark, `rgba(244,248,255,.36)` light).
- **Not changed:** the light canvas gradient, the opaque no-blur / reduced-transparency /
  forced-colours fallbacks, all geometry and fit logic, and every navigation, profile,
  Smart and evidence behaviour contract.
- **Tests:** `t_webui_fix322_liquid_glass_material` asserts the new token values in both
  palettes and counts the underlight on all ten surface rules, so a silently dropped family
  fails the contract instead of the device; `t_webui_fix324_boot_intro` and
  `t_webui_fix323_glass_navigation_actions` follow the layered dark canvas (black base
  asserted, accent hue still forbidden there).
- **Verification limit:** source contract tests and a headless-Chromium render of both
  glass palettes. Whether the stronger blur ladder costs visible frame time in the phone's
  WebView was not measured; ColorOS draws its material with a different compositor path, so
  the resemblance is by eye from the references, not a metric.

## V66 dev61 - a quieter idle WebUI, GPU load with its clock, pressure from PSI, "Vendor ↑"

Input: the dev60 source, the owner's short export (1 h 17 min with the screen on: device page,
report, asbdiag, logs) and four screenshots. The requests: less energy and heat without losing
battery life; the Monitor said GPU 60-70 % and the Load sheet *moderate 40/100* with every app
closed; other readings looked contradictory; and kernel "super patches" from GitHub. No native
source or release binary changed.

- **What the screenshots showed:** the GPU figure was this WebUI drawing itself. In the log,
  with the WebUI closed, GPU busy had a median of 4 % (0.7 % weighted by clock); with the
  Monitor open the GPU sat at its lowest clock (160 MHz) and 60-70 % busy. Busy share at the
  lowest clock is light work, but the tile showed only the share.
- **Idle WebUI:** dev17 kept the header sphere and the status dots moving on the page in front
  so it does not look hung, which also meant a new frame on every vsync for as long as the page
  is open. Ten seconds after the last touch these loops now stand still in CSS and one 100 ms
  timer steps them (Web Animations `currentTime`), only those on screen; none run on a hidden
  page, after a touch (full-rate CSS takes over from the same position) or when nothing is on
  screen. A headless browser trace of the home screen: 60 DrawFrame/s active, 10/s calm. The
  effect on the phone's power draw was not measured.
- **GPU tile:** shows the clock beside the busy share (*62% 160 MHz*); the colour and the tooltip
  use busy × clock / top clock (*62 % busy at 160 of 1200 MHz: about 8 % of what the GPU can
  do*). The clock is read in the same root shell as the governor state, only while Monitor is
  visible; the frequency table once per page life. The Monitor snapshot keeps the clock apart.
- **Pressure (Device page, Load sheets):** `asb_pressure.sh` reads `/proc/pressure` when the
  kernel has it and then scores CPU wait (weight 30, `some avg10` × 2), memory stall (25, × 5)
  and storage stall (10, × 4) instead of loadavg per core (35) and memory in use (30); CPU busy
  (25) and GPU (10) stay. The GPU component is now busy × clock / top clock where a clock and a
  table are readable (kgsl devfreq or `/sys/kernel/gpu`). New rows: `basis`, `gpu_clock_mhz`,
  `gpu_work_pct`, `psi_*`. Without PSI, or with a partial PSI, the old formula is used and the
  sheet says that loadavg and the share of memory in use read high on an idle Android phone.
  The Load sheet adds that this is pressure on the whole phone (the WebUI included), while the
  load class above is what the foreground app asks for.
- **"Who set the limit":** `vendor_raised` (the vendor raised the ceiling above ASB's for a
  moment, a launch or touch boost) was labelled *Vendor* in the hot colour next to *Firmware
  limits 0*, which only counts clamps. It is *Vendor ↑* in the neutral colour with a tooltip,
  no longer marks the status chip as an issue, and a clamp or thermal overlay on the other
  cluster now outranks it on the tile (before, a boost on the main cluster hid a clamp on the
  prime).
- **Readings that are consistent:** the trend arrow, *To saving* moving between 89 % and 64 %
  and the *Basis* line change with the temperature trend and the situation by design; the FSM
  going MODERATE → HEAVY matched the load class going light → medium.
- **From the short log:** 7.4 %/h with the screen on, speaker music 38 min at 7.8 %/h, 601 MiB
  over mobile data with the screen on (491 MiB video), CPU peak 64 °C, 4 min above 45 °C,
  jank 3.1 %. The *before* snapshot caught a vendor launch boost (both clusters' minimum near
  1.78 GHz, WALT `sched_boost=2`) that ended by itself. A candidate for later, not changed:
  the FSM's MODERATE shortcut reads the raw GPU busy share, which at the lowest clock matched
  MODERATE in 7 of 49 polls; changing it needs an A/B run.
- **Kernel patches:** reviewed and not adopted (reasons in the kernel repository's status
  document): BORE and HZ=1000 branches, sched_ext ports for other kernels, LZ4 1.9.4 and lz4kd.
  None is a measured power improvement for this 6.12 GKI, several change the KMI.
- **i18n:** `unit_mhz`, `lv_gpu_work_tip`, `lvp_basis_psi`, `lvp_basis_load`, `lvp_vs_class`,
  twelve `dev_system_load_*` labels; `cap_tip_raised`, `lvi_gpu`, `lvi_capsrc` and
  `dev_guide_system_load` rewritten or extended. 13 languages.
- **Tests:** `t_webui_dev61_ambient_gpu_pressure`; `t_pressure_score_runtime` covers PSI, the
  GPU clock (kgsl, MHz table, override) and the partial-PSI fallback.
- **Kernel repository:** documentation only, no rebuild needed.

## V66 dev60 - compact kernel cards, honest hub counts, goal lines for battery/performance settings, SOTER after ten minutes

Input: the dev59 source, the owner's dev59 phone export (asbdiag, device page, report, one
day of logs) and six requests: the kernel help and wakeup-rules cards were too long, Refresh
status felt dead, *High-resolution Timer Migration* could not be changed while the tile said
9 / 11, the Camera tile said 6 / 6 although eight cards were shown and the new Camera Tools
cards were green, the kernel cards' per-goal explanations wanted for the other battery and
performance settings, and improvements from the logs. No native source or release binary changed.

- **Kernel cards:** the help card and *Wakeup rules with exact names* keep a one-line summary;
  the long text, limits and warning fold behind *Details*, which keeps its state across
  re-renders. *Refresh status* plays a sound and shows *Checking…* at once and ends with a
  toast (*Kernel status read: n of m controls can be changed*, or an error); *Open Device
  Diagnostics* scrolls to the Kernel group of the Device page.
- **HR timers:** this kernel has no separate high-resolution timer switch (Timer Migration
  moves those timers too, `covered_by_timer_migration`), so the row is hidden like a missing
  Autogroup and the help card says why; a hidden row is still disabled. Search no longer finds
  hidden kernel rows, and kernel rows it does find carry their state badge and are disabled when
  unavailable (before, search showed them as ordinary controls).
- **Hub counts:** a tile counts what the category screen shows. Kernel controls the running
  kernel hides are left out; cards that are not settings rows count (Camera: *USB Webcam*,
  *Fast Camera Start*; Kernel: wakeup rules; Battery: notification fix), on when in use. The hub
  repaints once the kernel status or the new `asb_camera_tools.sh flags` answer arrives
  (state files only, no probes).
- **Camera Tools** use the Camera hue (emblem, buttons, chips) and a short summary with the
  long text under *Details*; Camera tile description *Processing, webcam, fast start*.
- **Kernel facts:** a card says when the shipped kernel value makes several options equal
  (*This kernel ships 1: Stock, On give the same result here*). MGLRU: the dev59 export read
  `0x0001` after Smart and `0x0003` after On; the card explains that the kernel drops the
  `0x0004` flag (non-leaf young), so this is not a failed write.
- **Explanations:** 53 battery, performance, display, network and system settings now follow
  the kernel cards: a short description, three goal lines (battery / performance or the
  relevant trade-off / not sure) and a per-option table, switches included (*On* / *Off*
  rows). 13 languages.
- **SOTER:** in the dev59 export the boot repair ran 69 s after the unlock and the SOTER
  server generated keys again within three minutes; payments still failed until the owner
  pressed the button 12 minutes after boot. One data point: keys created in the first minutes
  after a reboot appear unusable on this phone. The boot repair now waits 600 s after the
  unlock (`ASB_SOTER_SETTLE`), texts in 13 languages.
- **Tests:** `t_webui_dev60_cards_hub_explanations`, `t_camera_tools_flags_dev60`; the SOTER
  boot, Camera Tools, kernel panel, kernel why, dev58, fix328 and fix138 tests follow the new
  layout (the fix137 wakelock rule now lives in the *Act* line of the option table).
  `t_camera_tools_dev59` waits for the finished compile worker to drop its lock before it
  creates one itself (a loaded runner failed with `mkdir: File exists`); `t_lte_bulk_runtime`
  uses a 4 s transfer hold, because its waits could use up a 2 s hold before the in-hold check.
- **Kernel repository:** no change; nothing in the export needs a kernel source change.

## V66 dev59 - SOTER boot evidence, Camera Tools (USB webcam, fast camera start), CI fixes

Input: the dev58 source, the owner's failed CI run and four requests (fix the module build,
kernel audio/video/photo work and new capabilities with ASB integration, noticeable camera
tweaks, SOTER still repaired only by the button). No native source or release binary changed.

- **CI (host regression):** `t_module_desc_zygisk_dev57` no longer pins the template line of
  `module.prop`, which is the owner's own file (back to its dev57 content);
  `t_lte_bulk_runtime` waits up to 3 s for the radio mask after the watcher's save, because on
  a loaded runner the check could land between the save and the write.
- **SOTER after a reboot:** the dev57 phone still needed the button, and nothing showed whether
  the boot run had happened. The boot sequence now lives in `asb_soter_fix.sh boot`: unlock
  detected by `sys.user.0.ce_available`, the SOTER server's credential-encrypted directory or
  `RUNNING_UNLOCKED` (once a minute), 60 s settle, one retry, a verification pass three minutes
  later (restarts a stopped SOTER service, keeps SOTER logcat lines), a per-boot record shown in
  the card (*Automatic repair, this boot*), a notification in the UI language, a persistent
  log of every run with before/after states, stale-lock recovery, and asbdiag section 8c. The
  cause is not proven yet: the next export will show which phase fails.
- **Camera Tools** (new section in Camera): *USB Webcam* uses Android's own webcam service and
  the kernel's UVC gadget function (`ro.usb.uvc.enabled` from post-fs-data, `uvc.0` with MJPEG
  1080p/720p/480p, start/stop with restore, readiness rows); *Fast Camera Start* keeps the camera
  app compiled with ART `speed`, re-checks after updates and measures cold starts
  (`am start -W -S`) so the effect is a number. asbdiag section 6a; Device page rows
  `usb_webcam_uvc` and `usb_webcam_service`. 88 strings in 13 languages.
- **Tests:** `t_soter_boot_sequence_dev59` (replaces the dev57 service.sh block test),
  `t_camera_tools_dev59`, `t_webui_camera_tools_soter_boot_dev59`; SOTER runtime/UI tests extended.
- **Kernel repository (paired):** the capability report lists `media.usb_webcam`
  (`CONFIG_USB_CONFIGFS_F_UVC`, `CONFIG_USB_F_UVC`) with DeviceAsWebcam and the gadget HAL as
  external owners, the build summary has an *ASB Camera Tools* section, and the docs say why no
  audio, camera or video driver patch ships: those drivers are vendor modules bound to the KMI.

## V66 dev58 - module card format, kernel companion modules, LPM and Autogroup cards

Input: the owner's dev57 phone export and asbdiag on the dev57-fix1 kernel, and four requests.
No native source or release binary changed.

- **Module card in the owner's format:** `[Smart Mode 🤖 active ✅]   [Zygisk 🧩 connected ✅]`.
  `runtime/asb_module_desc.sh` writes the whole line from `current_profile` (an old-format line
  is replaced, not parsed); every profile writer, the installer and the template use the same
  words. The install-time line has only the profile part.
- **"waiting" no longer lingers:** after boot the card was first re-checked after two minutes;
  it is now re-checked every 10 s while the state is `waiting` (at most 10 minutes), then 5, 20
  and 50 minutes later, and the WebUI refreshes it once per session. A root manager can still
  show the old text until it reloads its module list.
- **Kernel companion modules:** the Device page (Root and modules) and asbdiag list NoMount and
  the VPN Hide built-in module with version (no repeated versionCode), enabled/disabled/removal
  state, a pending update and the kernel side (`nomount` driver version, `/proc/vpnhide_ctl`).
  3 strings in 13 languages.
- **Idle Prediction (LPM):** the export shows `prediction_disabled=0`: the kernel ships prediction
  on, so Stock, Auto and On cannot change anything there. The card now says what the kernel
  ships (from the captured baseline or the live value), and its text no longer claims that
  prediction picks deeper sleep sooner: it avoids deep sleeps that would be left at once. Off
  is for diagnosis. 13 languages.
- **Scheduler Autogroup:** GKI has no `CONFIG_SCHED_AUTOGROUP` (it changes `signal_struct`, a
  KMI structure), and autogroup only regroups tasks in the root CPU cgroup, which Android apps
  are never in. The dead card is hidden when the kernel does not expose the switch; the Kernel
  management help card says why. 1 string in 13 languages.
- **Tests:** `t_webui_companion_lpm_autogroup_dev58`; `t_module_desc_zygisk_dev57` rewritten for
  the new format and the 10 s settle; install and Stock description cases updated.
- **Kernel repository (paired):** the VPN Hide job writes the module version, versionCode,
  commit and id into the run summary (a mismatch is a warning, never a failure); the NoMount
  summary line names its commit too.

## V66 dev57 - kernel controls follow the profile, an RT boost floor, SOTER after the first unlock

Input: the dev56 source and the owner's six requests (clearer kernel texts, a larger header
saucer, Zygisk in the module card, SOTER repair after reboot, kernel/ASB integration, a camera
and audio tweak). No native source or release binary changed.

- **Kernel controls follow the profile.** Before, Auto (LPM prediction, hrtimer) was resolved
  only at boot, and leaving Stock left every control at its restored value until the next boot.
  - `asb_kernel_controls.sh follow <profile>` re-applies every registered control in one process;
    `apply_profile.sh` calls it after a profile switch (also the automatic low-battery switch and
    leaving Stock). Smart with Smart MGLRU leaves the MGLRU mode to the governor.
  - New Auto values: Timer migration 0 only in Performance (1, the kernel default, elsewhere);
    the migration batch Battery 2 / Balanced and Smart 4 / Performance 8. The separate hrtimer
    switch (kernels that have one) follows the Timer migration rule instead of the old
    Battery-only 0. Under Stock, Auto restores. A release under Auto reports the `auto` mode.
  - Fresh installs default to Auto; an upgrade from schema 3 turns only the former shipped
    defaults (`off`, `4`) into Auto. `config_schema` is 4.
- **New control: real-time boost floor** (`kernel_rt_boost`,
  `/proc/sys/kernel/sched_util_clamp_min_rt_default`). The minimum utilisation every real-time
  thread requests: audio mixers and HAL threads, display composition, some camera HAL threads,
  threaded interrupts. Options stock/auto/0/128/256/512; Auto: Battery 0, Performance 256,
  the kernel's value in Balanced/Smart.
  - The kernel boots with 1024 and the Snapdragon post-boot script lowers it to 0 at
    `boot_completed`. A baseline captured before that would later restore 1024, so the capture
    waits for `boot_completed`, the vendor post-boot service and 60 s of uptime (`deferred`).
  - Device page and asbdiag show the live value. No audio, camera or battery gain is measured.
- **Kernel card texts.** Every kernel card now says what it does in plain words, which value to
  pick for battery life, for performance and when unsure, and explains each option in its own
  line (the per-option table with the current choice highlighted). The cards use one set of
  button labels per language. 13 languages.
- **SOTER repair after a reboot.** The opt-in boot run started 45 s after `boot_completed`,
  usually before the first unlock, when the SOTER server app (not direct-boot aware) and the
  credential-encrypted storage are not available; the manual button, pressed later, worked.
  It now waits for `sys.user.0.ce_available` (after 10 minutes also `RUNNING_UNLOCKED`; at most
  6 hours), settles 60 s and retries once after 120 s when the first result is not final. The
  log line says how long after boot the unlock came. Not verified on the phone yet.
- **Module card shows Zygisk:** `status: Smart Mode 🤖 | active ✅ | Zygisk ✅ connected` (off,
  not installed, safe mode, connected, idle, waiting). `runtime/asb_module_desc.sh` computes the
  suffix; it is refreshed 2, 5, 15, 30 and 60 minutes after boot and after a Zygisk change. The
  install-time line is unchanged.
- **Header:** the emblem is 106 px instead of 92 and the saucer 30 % larger; the extra height
  comes from the top gap, so the layout below does not move. The boot core keeps the same
  proportions for the hand-off.
- **Tests:** `t_kernel_profile_follow_dev57`, `t_soter_boot_waits_for_unlock_dev57`,
  `t_module_desc_zygisk_dev57`, `t_webui_kernel_cards_header_dev57`; updated hrtimer Auto cases.
- **Kernel repository (paired):** the capability report and the build summary describe the
  profile-linked Auto values and the new RT boost control (CONFIG_UCLAMP_TASK); the 5000 ms
  MGLRU request that ASB no longer writes is gone from the contract.

## V66 dev56 - LPM prediction on qcom-cpu-lpm kernels

Input: the dev55 source, the owner's device export and asbdiag on the KRILIKD kernel built from
it, and a screenshot of the kernel controls. No native source or release binary changed.

- **Idle prediction (LPM) works on qcom-cpu-lpm kernels.** The card only knew
  `/sys/module/lpm_levels/parameters/lpm_prediction` of the older lpm_levels driver. The phone
  runs the `qcom-cpu-lpm` governor, which has no module parameters (asbdiag found none) but
  creates `/sys/devices/system/cpu/qcom_lpm/parameters/prediction_disabled` (the same file in
  the 5.15 and 6.6 Qualcomm vendor trees of this governor).
  - The control uses that node when lpm_levels is absent. It is written inverted; status,
    readback and the baseline are reported in the card's terms (1 = prediction on), and Stock
    writes the captured raw value back.
  - asbdiag lists the governor's parameters; the Device page reports the same logical value.
  - The card and "not exposed" texts no longer claim that qcom-cpu-lpm has no such switch.
    13 languages.
- **Autogroup:** the "not exposed" reason now also says that, even when built in, autogroup
  regroups only tasks left in the root CPU cgroup, while Android places app tasks in its own CPU
  groups. Nothing else changes: the kernel still has no `CONFIG_SCHED_AUTOGROUP`.
- **HR timer migration** is unchanged: Linux 6.12 has one `timer_migration` switch for timers and
  high-resolution timers, and the card shows that it is covered by Timer Migration.
- **Tests:** `t_kernel_lpm_qcom_prediction_dev56`.
- **Kernel repository (paired):** the NoMount job checks the packaged version before upload.

## V66 dev55 - review fixes for dev54 and a faster WebUI

Input: the owner's dev54 source (host regression 525/525) and the dev54 review. No native source
or release binary changed.

- **Wakeup observation: sources that share a name.** `/sys/class/wakeup` names are not unique
  (several epoll sources are all `eventpoll`). The dev54 window keyed its snapshot by name, so the
  last same-named entry overwrote the others and a fresh window could show `eventpoll +95` at once.
  - One pass reads all four fields of every entry and keys it by its `wakeupN` entry; a reused
    entry with another name counts as new, a counter that went down as a reset.
  - Deltas are summed per name, and each line carries `shared=<n>` and `new=0|1`. The meta file
    is `format=2`; a dev54 window is cleared and reported idle instead of being misread.
- **Wakeup rules: a confirmation before Block.** The kernel rule matches the name, so it covers
  every source of that name. Block now opens an inline confirmation that says how many sources
  share the name and warns for alarm, power-manager, charging, input, key, RTC, thermal and
  watchdog sources; nothing is saved before it is confirmed. Rows are tagged new / shared /
  system source. A typed system-source name gets the same warning. 6 strings in 13 languages.
- **MGLRU generation protection.** A nonzero `min_ttl_ms` lets the kernel start the OOM killer
  when the protected working set does not fit; the kernel documentation recommends 1000 ms. The
  options are Stock, 1000 and 2000 ms; a saved 5000 is read as 2000. An update carries the retired
  `mglru_hold` intent over once (Hold -> 1000, Aggressive -> 2000, an explicit TTL wins) and sets
  the legacy key to stock. The dead WebUI handler and map entries for `mglru_hold` are gone.
- **Kernel baselines belong to one kernel build.** A captured baseline gets a `<key>.prev.kid`
  sidecar with `uname -r` and `uname -v`. After a kernel flash the old value is not written into
  the new kernel: the next apply captures this kernel's own value, and Stock with only a foreign
  baseline reports `stock_unowned` without a write. A pre-dev55 baseline is adopted.
- **Neutral texts.** The kernel card and "why unavailable" texts for timer and hrtimer
  migration, autogroup and LPM prediction no longer promise an effect; the autogroup reason
  describes GKI kernels in general. 13 languages.
- **Saucer and reduced motion.** With prefers-reduced-motion the ten-tap saucer still flies, but
  the cards no longer sway and there is no particle wake.
- **WebUI speed.** Measured in a host bench: headless Chromium, 4x CPU throttle, the root bridge
  modelled as a 25 ms blocking call, median of three runs of 16 page switches. These are host
  numbers, not phone measurements.
  - Fitted card/tile heights and the tab-bar space were inherited custom properties on `<html>`.
    Each write restyled the whole document (about 1000 elements), four times per page switch,
    twice behind a forced layout. They now live on `.profiles` / `#cfgList` and as a class.
  - Settings, Device, Zygisk and report pages are no longer unclamped and measured for a
    compaction tier they never take.
  - The UI scale is applied before the first element is styled (the parser's first full style
    and layout pass was redone before). Monitor resets its scroll before its classes change.
  - Long lists lay out only the rows near the viewport (`content-visibility`): category and
    search rows, Device/report/Zygisk sections and the wakeup-source list. A row with its option
    list open is an ordinary box again, so the list is not clipped.
  - 74 selectors whose rightmost part was a bare `:is()` list were tested against every element
    on every style recalc. `tools/asb_css_bucket.py` (host only, not shipped) rewrote them into
    441 equivalent plain selectors with the same specificity. Every computed property of every
    element and its `::before`/`::after` was compared before and after in 16 UI states x 4
    themes: no difference. Selector matching of a full recalc fell by about half.
  - Search keystrokes within 90 ms share one list rebuild.
  - Result over the 16 steps: long-task time 4222 ms -> 501 ms, style recalculation
    6123 ms -> 3280 ms, the sum of the longest frame per step 2783 ms -> 866 ms. Cold start
    long tasks 1083 ms -> 697 ms. Home <-> Monitor <-> Settings and opening or closing Zygisk
    and the report ran without a long task; a category, Device and Settings -> Home still have
    one (69-176 ms at 4x).
- **Tests:** `t_webui_wakeup_confirm_dev55_runtime`, `t_mglru_ttl_update_migration_dev55`,
  `t_kernel_controls_kernel_bound_baseline_dev55`, `t_webui_render_cost_dev55`; the wakeup,
  MGLRU TTL, fill-pages, saucer and Glass/light-theme contracts follow the new code and CSS.
- **Kernel repository (paired):** the KernelSU-Next/SUSFS guard honours the compat step's two
  removals only where that step makes them; the wakeup blocker fills its sysfs pages with
  `sysfs_emit_at()`. The kernel needs a CI build for the latter.

## V66 dev51-dev54 (owner builds)

Built by the owner; not recorded here at the time. Seen in the dev54 review: the explicit
wakeup observation window (start/update deltas), wakeup blocker ABI 2 (`abi_version`,
`rule_stats`), MGLRU `min_ttl_ms` moved under the kernel-control owner, and the timer, hrtimer,
LPM prediction and USB autosuspend controls.

## V66 dev50 - stable SOTER completion, faster WebUI reads and a cosmic saucer scene

Input: the dev49 source and five owner requests. No native source or release binary changed.

- **SOTER completion after one tap.** dev49 already made two clear/restart passes, but accepted
  the first `init.svc=running` sample as completion. Each pass now also requires six consecutive
  running samples at half-second intervals; a transient crash/restart returns `service_down`
  instead of a false `done`. This is bounded service stabilization, not a third blind `pm clear`
  and not a claim that a host fixture proves physical key reinitialization. The card is rendered
  immediately below Battery Fix and before the unrelated package repairs.
- **Fewer repeated WebUI reads.** Cold concurrent callers share one static `device_info.json`
  fetch, and a valid seven-day display-only device cache is painted without another fetch.
  Returning to Stock Monitor reuses a sample inside the existing ten-second telemetry window
  instead of forcing the same root collector again. No persistent worker was added and stale,
  failed or unknown metric states remain distinct.
- **Shorter, live boot preview.** The artificial minimum is 1.4 s (was 3.2 s), with a 6.5 s
  fail-safe cap (was 9 s). The active stage has a beacon/line animation, the core has a halo and
  the completed state gets a short ready transition. The four bars still represent only the real
  Live, Config, Device and Zygisk jobs; a timed-out job never produces a ready/100 % claim.
- **Twenty-second saucer Easter egg.** Ten quick logo taps keep the original detailed SVG for the
  entire flight; there is no emoji substitution. A fixed canvas adds a bounded cosmic trail,
  stars and at most 150 particles (DPR capped at 1.5). At most 18 visible cards sway/spill through
  an intensity envelope that reaches zero before landing. Their transform, opacity, transition
  and will-change inline values are restored on completion and on a hidden-page abort; canvas,
  overlay, animation frame and visibility listener are cleaned up. Repeated launches do not stack.

Host shell fixtures and Node runtime contracts cover the changed logic. The canonical source
regression passes with 523 PASS lines and no failed tests. They are not physical ColorOS WebView
validation and do not prove that SOTER keys or payment enrollment are ready.

## V66 dev49 - another user's export, the owner's kernel, SOTER on the first run

Input: the dev48 source (host regression 519/519), a user's asbdiag, full-day log and
screenshots from an older V66 test build (stock OnePlus kernel 6.12, Magisk), the owner's
14.11 exports and screenshots, and the kernel workflow's failed run.

- **LSPosed card: "unexpected_schema".** The helper only knew the standard module database
  layout, so any fork that renames a column or table read as a foreign database, with no
  further detail. Module and scope queries are now built from `PRAGMA table_info`
  (`mid`/`id`/`module_id`, `module_pkg_name`/`pkg_name`/..., `scope`/`scopes`, a scope keyed by
  id or by package) and read as `layout=adapted`; edits and the verbose switch stay limited to
  the standard layout. A database matching nothing names its tables and columns (identifiers
  only) in the card, the Device page and asbdiag; an empty file says it has no tables. What the
  user's database actually contains is still unknown until the next export - the card now asks
  for it with the evidence attached. Native change: CI rebuild of `asb`.
- **Night charge limit: "kernel does not expose the interface".** On a stock OnePlus kernel
  neither standard node exists. The OPlus charger switch `mmi_charging_enable` (1 = charge,
  0 = stop; under `oplus_chg/battery`, then `power_supply/battery`) is used like
  `charging_enabled`: the same baseline, read-back, ledger, boot scope and exact hand-back. Not
  verified on that phone - the write is read back every tick and an external change is reported.
  A switch-type hold is no longer released on "Discharging" while a charger is still online
  (a stopped charger may report that); a real unplug still releases it. asbdiag section 5a3
  lists every candidate node and its value.
- **Battery Fix: "succeeded 0, failed 560".** The compile output was discarded, so the reason
  was never recorded. The first refusal's text is kept and shown; after 12 refusals with no
  success the run stops (`refused`) instead of spending the battery on the rest; `pm compile`
  is tried when `cmd package compile` rejects its options. What Android answered on that phone
  is still to be seen in the next export.
- **Battery Fix: "30 May 13:09, 1 of 3 files removed".** The reset runs in post-fs-data, before
  the clock is set, so the stored time was the early-boot clock. A time behind the arm time is
  not stored; the boot step records uptime and boot id, and `settle` (status, and service.sh
  90 s after boot) derives the real time in the same boot. Until then the card says "at the
  last reboot". Files Android never created are counted as "not present on this Android", apart
  from files that could not be removed.
- **Kernel tweaks.** The owner's kernel is built with debugfs and scheduler debugging, yet
  "Scheduler migration batch" read "not exposed": Android does not mount debugfs on user builds.
  The control owner now mounts debugfs on a private root-only directory for the one read or
  write and unmounts it at once (the value stays in the kernel; nothing stays mounted); the
  Device page reads it the same way. Autogroup and LPM prediction say why they are missing:
  autogroup changes a structure vendor modules are built against, so a GKI kernel cannot have
  it; LPM prediction belongs to the older idle driver, and asbdiag lists the idle-driver
  parameters this kernel has.
- **Kernel and Audio text on AMOLED.** Badges, the chosen segment, slider values and section
  headings of these two categories take a lighter ink of the same hue on the dark and glass
  themes (about 8:1 instead of 4.3-4.7:1 on black); fills, edges and the light theme are
  unchanged.
- **SOTER Repair on the first run.** The owner saw it work only on the second run; the log does
  not show why. One run now makes both passes (force-stop the server, stop the SOTER services
  and wait until stopped, clear its data, start them and wait until running), stopping early on
  a refused clear or a service that does not come back, and starts on the first tap. A switch
  in the card makes service.sh run the same repair 45 s after every boot; the switch text says
  that fingerprint payment then has to be switched on again after each reboot.
- **Sustained entry reason.** The owner's log read "other actual_t=63degC (thresh=54)": the
  floor test used the global threshold while the line printed the profile's. Both use the
  profile threshold now. Native change: CI rebuild of `asb`.

Kernel workflow (separate repository): the failed run stopped after ten minutes because the
selected KernelSU-Next commit calls a function the pinned SUSFS release does
not have. A resolve-step check now compares the two in seconds and falls back to the
boot-attested known-good commit, or stops at once with the missing names. No source of either
component is patched.

Native code changed (`src/asb_lspd.h`, `src/asb_governor.c`): the `asb` binary needs a CI
rebuild. Host regression: every suite passes (523 PASS lines; dev48 had 518 by the same count).
Host fixtures and Node renderers are not device validation; the OPlus charge switch, the Battery
Fix refusal text and the LSPosed fork layout still need the next export from that phone.

## V66 dev48 - audit follow-up and fixes from the 14.11 asbdiag/device export

Input: the dev47 source (host regression 515/515), an external dev47 audit (F1-F8, P0) and the
owner's asbdiag and Device diagnostics export of 14.11.

- **MGLRU readback on arm64.** `lru_gen/enabled` shows only what the hardware keeps: arm64 has
  no non-leaf PMD young bit (0x4), so a request for 7 reads back 0x0003 (the export showed it).
  The helper called that `readback_mismatch`, so `mglru_mode=on` stayed a mismatch for good and
  the Smart tuner re-wrote 7 on every heavy pass (its memo only knew the 0x0001 clamp). A
  readback that is a subset of the request and keeps the core bit is now `applied`; a dropped
  core bit or a bit that was not asked for is still a mismatch.
- **Junk Cleanup's 24-hour journal barrier.** The WebUI shell's `find` is toybox, which compares
  `-mtime +0` as "older than 0 seconds" (N x 86400 against raw seconds); GNU and busybox round
  to whole days, so host tests passed. On the phone every backup journal was eligible, however
  fresh. Scan and delete now use `-mmin +1440` (toybox: more than 86 400 s; busybox/GNU: about
  the same minute). The audit's F3 asked for exactly this, for a different reason.
- **Wakeup blocker clear readback.** A sysfs attribute always reports a size, so the `[ ! -s ]`
  readback after `clear` failed every real clear as `readback_mismatch` (only Safe mode,
  watchdog and uninstall use it, with the result discarded). It now reads the content. With
  F2, an empty policy on an already empty kernel list writes nothing at boot.
- **Zygisk allowlist cut at 600 characters.** The Device diagnostics collector caps every value
  at 600 characters; the owner's 64-app list ended mid-name ("...,com.paypal."). That page also
  renders the manual allowlist editor, so Save could have written the cut list. The list is now
  emitted whole (package characters only), and the editor shows but never saves a list whose
  length disagrees with its own count.
- **Fitness WAKE_LOCK limit.** Every asbdiag the owner sent (30 min to 10 h after boot) read
  "limit lapsed" for all three fitness apps with the same "ASB puts it back 5-10 min after boot"
  sentence, and the card said Enabled. Whether ASB's re-apply ran and was reset later, or the
  ROM never kept the op, was not recorded. Each (re)apply now writes pkg, time, read-back and
  the raw appops line to `wakelock_fitness_reapply`; asbdiag says which case it is and prints
  what appops reads now; `fitness-status` reports `not_kept` (no extra appops client), and the
  card shows "ROM does not keep it" instead of Enabled. The root cause still needs the next
  export from the phone.
- **Device diagnostics page.** 26 collector keys had no label in any locale and showed as
  English key names ("Auto Mode", "Hints Throttled", "Smooth Log Status", "Oplus Sdp 900ma
  Node"); a regression now checks every literal collector key against all 13 locales. Last
  event age, CPU sample window and the automatic-list and logger epochs carry units/dates. The
  Zygisk IPC cost card no longer carries the observed apps' own RSS (3.3 GB in the export); it
  is a separate "Memory of observed apps" card. A full-charge value equal to the design value
  after 391 cycles is reported as "wear not reported by the firmware", not as 100% wear health.
- **asbdiag.** One readable line per kernel control instead of raw pipe records; the hrtimer row
  says it is the timer-migration mechanism with one write (F1). Section 10 marks the shipped
  rails as the fallback when device-adaptive bounds are live instead of offering the OP12 hint.

Audit items not taken: F4 (taro/lahaina envelope) - those SoCs already get the universal
capability baseline, and per-SoC numbers without a capture from such a phone would be guesses;
F5 (duplicate asbdiag) - CI already ships one copy and install links the other (V66 dev9); F6 -
the source stays readable, CI slims the package; F7 - Battery Fix's boot step deletes three files
before system_server reads them and an interrupted compile is already reported as such; F8 - the
export shows 0 GPU-bound latches that fell apart and a 3-tick need, nothing to tune yet; P0 - the
lab cost 68 ms of governor CPU in 4 h 54 min, with no winning setting yet: an owner decision for
the release, on more nights of data.

No native code changed. Host fixtures and Node renderers are not device validation.

## V66 dev47 - distinct category colours, one Zygisk connection card, a Load sheet with a scale, SOTER Repair

Input: the dev46 source (host regression 510/510 as received) and four owner requests.

- **Nine category colours that really differ.** Audio and Camera were two pinks, Kernel and
  Display & Haptics were cool blue and pale peach. Now Audio is a deep red towards burgundy
  (`#d4475f`, light `#9e2441`), Camera takes the former Kernel blue (`#82b8ff` / `#2f62b0`),
  Kernel is brown (`#b0704a` / `#7a3f24`), Display & Haptics is lime (`#b3d65a` / `#647800`) so
  it cannot be mistaken for the brown, Zygisk moves from blue-grey slate to neutral graphite
  (`#b1b6bc` / `#5d6167`) so it no longer sits next to the new blue Camera, and System moves from
  amber to gold (`#f0cd4e` / `#946400`): on the large hub tiles, where a hue is only a faint
  wash, the first draft's brown Kernel and amber System looked alike. Interface keeps the only
  lilac. Measured, not eyeballed: the closest pair of the nine hub hues is CIEDE2000 16.9 in the
  dark theme and 16.6 in the light theme (11.4 and 9.5 before; Interface/Camera and Kernel/Zygisk
  were the closest), and a regression keeps every pair at 15 or more, System at least 25 hue
  degrees away from Kernel, and exactly one pastel pink/magenta/lilac hue. Light-theme hues keep
  at least 4.5:1 contrast on white. Tiles, headings, tweak rows, icons, controls and Kernel's buttons share
  the hue as before. Toasts used the old fine-grained categories (a Kernel switch could toast in
  the colour of "motion" pink); they now follow the navigation category too, with new Kernel,
  Display & Haptics and Zygisk toast skins and a gold System skin.
- **ZYGISK: Connection and controls are one card.** The four switches sat two cards below the
  link they act on. They now live inside the Connection card, under a hairline, titled
  "Connection and controls"; the embedded block is a plain inner block, so the glass and light
  themes do not draw a card inside a card. When ASB Zygisk is off the card stays "Connection"
  with the Off card under it, as before. The section map lists Controls first.
- **Monitor → Load / System load sheet.** Tapping either now shows the Device diagnostics
  pressure scale: score, band in its colour, the four-colour bar with a marker, and one bar per
  measured component (load per core, memory used, CPU busy, GPU busy). It is measured on open by
  the same read-only collector (`runtime/asb_pressure.sh`) through a new standalone reader,
  `runtime/asb_pressure_snapshot.sh`; a component the phone does not expose is labelled so, a
  failed read says so, and a reply arriving after the sheet closed is dropped. The score on the
  Device page now also wears its band colour.
- **Infirmary → System Repairs → SOTER Repair.** Ported from the owner-supplied reference
  module's manual SOTER button and rebuilt on ASB's fixed-protocol pattern
  (`runtime/asb_soter_fix.sh status|run`). Status reads `/data/system/packages.list` (falling
  back to `pm path`) and the ROM's `init.svc.*soter*` services. Run takes an atomic lock, stops
  only the declared SOTER services, runs `pm clear com.tencent.soter.soterserver`, starts them
  and polls their state back for up to five seconds. Outcomes are separate: done, done without a
  declared service, service down, clear refused, not installed, busy. The reference stopped and
  started `vendor.soter` blindly and always reported success. Manual only: nothing at boot, no
  loop. The card states that the repair hides neither root nor an unlocked bootloader, and the
  second tap within five seconds confirms that fingerprint payment must then be switched on again
  in the payment apps. Thirteen locales.
- **Stale locks after a reboot.** A reboot during Junk Cleanup left `junk_cleanup/run.lock`, and
  every later cleanup answered "Another cleanup is already running" until the module was
  reinstalled. post-fs-data now removes that lock and the new SOTER lock, like Battery Fix's.
- Russian labels for two pressure components no longer mix English ("Load на online CPU",
  "CPU busy за замер").
- Both new helpers are in the two workflows' required-file and executable-mode lists, and
  README.advanced (EN/RU) gains section 11.20 for SOTER Repair.

No native code changed. Host fixtures and Node renderers are not device validation; the SOTER
service name and the payment-app behaviour after a reset are ROM-specific and were not measured
on a phone.

## V66 dev46 - owner exclusions are a real Zygisk compatibility boundary

Input: the dev45 source, a full-day capture, asbdiag and screenshots showing that an owner-excluded
application ran with the ASB Zygisk master switch off but stalled with it on. The capture does not
prove the native root cause: its final diagnostic snapshot was taken after Zygisk had been disabled.
It did prove that the old exclusion covered ART ranking/reset only, while ledger and launch policy
still allowed an app-side entry. The fix is generic; no bank package name or hiding rule was added.

- **One exclusion now covers all optional ASB Zygisk work for new processes.** The generated policy
  carries up to 64 `xpkg=` rows beside the 64 `pkg=` rows. Exclusion wins over the allowlist and
  returns before `connectCompanion()` for observation, ledger and cold-start assistance, including
  `:worker` processes. The companion independently rejects excluded `SPAWN` and legacy
  `PROCESS_START` frames before class lookup, ledger writes, pidfd tracking or governor IPC. An old
  native library rejects the unknown key and becomes dormant instead of partially observing.
  Duplicate package rows and more than 64 exclusions invalidate the complete policy.
- **Optional telemetry cannot wait on a full companion queue.** The one-shot app-side send uses
  `MSG_NOSIGNAL | MSG_DONTWAIT`. A full queue or partial send drops that small frame and closes the
  socket; the companion rejects truncated input. `DLCLOSE_MODULE_LIBRARY`, one-shot IPC, peer/start
  tick validation and event-driven pidfd reaping remain. No timer, retry loop or persistent polling
  worker was introduced. Losing one diagnostic frame is accepted; delaying app startup is not.
- **ART and native policy cannot silently diverge.** Exclude/include calls the existing policy sync
  with the explicit module directory and exclusion path. A failed or missing writer returns
  `observer_policy=failed|unavailable` plus `result=partial reason=observer_policy` and nonzero.
  The WebUI shows the saved-but-not-synchronized warning instead of a success toast; a later retry
  or boot can synchronize it. Restore-all retains only best-effort cleanup semantics.
- **The result is measurable without inflated claims.** `excluded_spawns` is emitted per companion,
  summed across ABI by observer/asbdiag and documented. It does not mean that root, other Zygisk
  modules or memory mappings are hidden. The advanced guides now describe the actual one-shot/
  `DLCLOSE` lifecycle rather than the removed resident-socket design.
- **LSPosed read failures are no longer guessed to be a foreign schema.** The read-only probe now
  executes the real `configs` query for verbose status, or both `modules` and `scope` queries for
  inventory. CANTOPEN/IOERR/READONLY/PERM on those statements retries from the existing private
  DB+WAL copy; SQL/schema mismatches stay fail-closed and busy/locked/I/O failures remain
  `read_failed`. Status performs one verbose read, preserving `sqlite_rc` and `read_from=copy`.
  The maintained Vector schema itself was not changed and LSPosed writes still require the known
  schema.
- **GPU inference is not reported as a played game.** A new capture contained an 18-second
  `gaming` report phase while its package-independent `app_hint=4` had `app_hint_inferred=1`.
  Logkit now requires `app_hint >= 4` together with explicit `app_hint_inferred=0`; missing
  provenance also stays `active`. The native GPU-bound GAMING latch is unchanged for unknown 3D
  workloads. `fsm_media_trace.tsv` appends `app_hint_inferred` without moving old columns, a zero
  `class|game|0.0|0|0` row is explicitly not a session, and game-specific jank advice requires a
  confirmed gaming phase.
- **The logs did not justify another performance or thermal writer.** The two captures came from
  different device/SoC runtimes and were not merged. In the new capture Smart already recorded
  three unhelpful app ceiling trials, the leading Kimi intervals were predominantly slow-draw,
  and raised vendor ceilings were not rejected ASB writes. Consequently no frequency increase,
  fixed CPU mask, IRQ affinity, thermal override or SoC-specific writer was added from correlation.

Regression drives the real native module through exclusion and suffix cases, a deliberately full
socket with an alarm around `preAppSpecialize()`, forged/legacy companion frames, duplicate and
65-row policies, shell-to-native `xpkg=` agreement, failed/missing sync recovery and WebUI partial
handling. LSPosed fixtures include a database whose legacy `sqlite_master` probe succeeds while
its real queries require the WAL-copy fallback. Logkit/UI fixtures cover inferred versus confirmed
games, zero game totals, appended provenance and neutral jank wording in 13 locales. The current
source release does not rebuild native libraries locally: both Zygisk ABIs and the governor must be
rebuilt by the owner's workflow because their sources changed. AOSP/AIDL DSP and attach prebuilts
are not described as rebuilt either.

Not proven: physical OnePlus 15/ColorOS loader behavior, the excluded application's next launch,
absence of conflicts with other Zygisk/LSPosed modules, physical Vector database access or better
battery/thermal/smoothness outcomes. Host fixtures are not bank-specific or on-device validation.
No root/Zygisk concealment, application-attestation bypass, per-bank exception, governor writer,
thermal change or battery/performance percentage was added.

## V66 dev45 - real Zygisk unloading and honest OP15 kernel pairing

Input: the dev44 source, the OP15 kernel-control screenshot, KRILIKD v13 source/build evidence and
read-only device diagnostics. The objective is a smaller app-side lifetime and a precise kernel
contract, not memory-name concealment or another owner for vendor charging/VPN policy.

- **The app-side observer now asks the loader to unload.** An allowlisted, observer-only or
  denylisted process sends one bounded `SPAWN` frame, closes its stream socket and returns
  `DLCLOSE_MODULE_LIBRARY`. It installs no hooks, calls no `exemptFd`, retains no package/socket
  field and sends no `PROCESS_START`. The companion validates peer credentials and process start
  ticks, creates a `pidfd` where allowed and uses the existing event-driven reaper. Legacy
  `PROCESS_START` remains accepted only for rolling-update compatibility with an older library.
  This is lifecycle hygiene; it does not make an already injected mapping invisible to a detector.
- **HR timers no longer acquire a second writer.** A separate vendor
  `/proc/sys/kernel/hrtimer_migration` keeps its previous bounded baseline/readback behavior when
  it actually exists. Standard Linux 6.12 does not expose that independent sysctl: with only
  `/proc/sys/kernel/timer_migration`, ASB reports `covered_by_timer_migration`, disables the row,
  captures no HR baseline and performs no second write. If neither interface exists, apply fails
  with `not_exposed`; status remains a read-only report. All thirteen locales distinguish this
  state from an applied tweak.
- **Kernel evidence follows the paired OP15 source.** Device Diagnostics reads the registered
  `/sys/kernel/debug/sched/nr_migrate` path and reports `CONFIG_DEBUG_FS`/`CONFIG_SCHED_DEBUG`
  separately. A missing path does not assert which of mount, SELinux, permissions or config is
  responsible. Autogroup is not force-enabled and the old Qualcomm `lpm_prediction` control is not
  replaced by an invented SM8850 writer.
- **SDP reporting is runtime-aware and read-only.** `/proc/sdp900ma`, its config and its bounded
  report are exposed in Device Diagnostics. `enabled=0`, `NOT APPLIED`, a mixed report, an
  unreadable/missing node and a positive `[OK]`/`enabled=1` report are different states. A positive
  report means only that the early-boot driver confirmed its configured SDP budget; it is not a
  physical current measurement. ASB exposes no USB current/voltage writer and no runtime toggle.
- **Native build evidence is real.** NDK r28c built both `arm64-v8a` and `armeabi-v7a` observer
  libraries with the existing `-Werror` gate and verified both exported Zygisk entry points. Host
  ABI fixtures check one-shot EOF, no `exemptFd`, unload requests for every lifecycle branch,
  legacy companion compatibility and synchronized diagnostics. The separate AOSP/AIDL DSP and
  attach prebuilts are not claimed as rebuilt by this NDK job.

Not added: hiding `zygisk/arm64-v8a.so` from `/proc/*/maps`, a `dl_iterate_phdr` interceptor,
interference with another hiding scheme, an ASB VPN policy owner, arbitrary sysfs/path writes,
thermal/SELinux/KMI bypasses or unsupported battery/performance percentages. Host/browser and NDK
verification do not prove physical ColorOS WebView behavior, actual USB input current, VPN hiding,
scheduler gains, boot success or battery life.

## V66 dev34 - real Linux 6.12 scheduler nodes and explicit trade-offs

Input: the dev33 source, device diagnostics, WebUI screenshots and the successful KRILIKD v13
build logs. Three controls were available on the device; two unnecessary `not exposed` verdicts
were caused by userspace bindings, not by a failed kernel build.

- **Correct fixed interfaces.** `kernel_sched_nr_migrate` now uses
  `/sys/kernel/debug/sched/nr_migrate`, where Linux 6.12 exposes the scheduler migration batch,
  and `kernel_sched_stats` uses `/proc/sys/kernel/sched_schedstats`. Device Diagnostics and the
  standalone diagnostic report use the same stats node. Debugfs mount, SELinux and access checks
  still happen on the device: a corrected path is not a promise of writability.
- **One stats owner, honest Stock.** Legacy unconditional `sysctlw kernel.sched_schedstats 0`
  calls in boot and reinforce paths were removed. They contradicted the visible `stock` default.
  Boot, profile and reinforce now use the registered helper; uninstall has no duplicate legacy
  writer and retains the helper's exact baseline/readback restore. Stock without a baseline does
  not write, while Off captures and restores the original 0/1.
- **Upgrade behavior is stated plainly.** The existing `kernel_sched_nr_migrate=4` request is
  preserved. After the path correction it can become a real write where debugfs is available;
  an earlier `not exposed` verdict did not mean it had been applied. `kernel_sched_stats=stock`
  no longer implies the old hidden automatic Off. Users who want stats disabled must select Off.
- **Explanations describe mechanisms, not invented gains.** All thirteen locales and the built-in
  English fallback explain memory reclaim, timer placement, balancing batches, scheduler debug
  accounting, session-group fairness and post-fork ordering. Each card distinguishes possible
  responsiveness/performance effects from power effects and names the opposing trade-off. No
  battery or performance percentage is claimed.
- **Autogroup remains evidence-led.** `/proc/sys/kernel/sched_autogroup_enabled` is unchanged. If
  it is not exposed, ASB reports that fact; the kernel's autogroup config is not forced on merely
  to make the sixth card operational.

Regression pins both corrected default paths, rejects the obsolete proc names in runtime,
diagnostics and restore code, verifies the existing `4` request can apply after upgrade, checks
that Stock is inert without ownership, and retains stable baseline, numeric readback, mismatch,
access-failure and exact-restore coverage. Host fixtures and browser checks remain separate from
physical debugfs/SELinux, scheduler, power and ColorOS WebView validation.

## V66 dev33 - kernel management inside System

Input: the dev32 source and Monitor screenshots. The separate Config hub tile **Kernel** is
removed. Its actionable content now opens under **Settings → System → Kernel management**;
read-only kernel capabilities are not rendered as a second diagnostics card.

- **Six registered controls in one existing owner.** MGLRU, timer migration, migration batch and
  scheduler statistics retain their previous defaults and behavior. New `kernel_sched_autogroup`
  and `kernel_sched_child_runs_first` controls default to `stock` and expose only stock/off/on.
  Both use fixed standard nodes, baseline capture, bounded 0/1 writes, numeric readback and exact
  Stock/uninstall restore. Neither claims a universal responsiveness, performance or battery gain.
- **No competing writer was added.** `vm.block_dump` was rejected as a new control because the
  Battery profile already writes it in `service.sh`; adding another owner or changing that default
  would violate the single-owner contract. `swappiness`, `stat_interval` and `sched_energy_aware`
  likewise remain with their existing profile owners.
- **Management is separate from evidence.** The management help explains Stock, availability and
  mismatch semantics. Refresh rereads both registered owners after apply and on demand; Open
  Device Diagnostics uses the real existing navigation handler. The Config panel no longer calls
  `asb_device_info.sh --kernel`. Device Diagnostics retains its independent kernel feature,
  origin, BTF, eBPF, FUSE-BPF, runtime, external-evidence and config sections.
- **Wakeup behavior is unchanged.** The exact-name editor moves with the subsection and retains
  its full-list validation, saved/current readback, blocked-event counter, empty default and
  explicit unsupported states. No polling worker or browser-provided sysfs path is introduced.
- **Upgrade and locale coverage.** Both new keys are present in shipped/default config, the
  ownership registry and both update/snapshot lists. Thirteen locales include section wording,
  management help, diagnostics navigation and both controls with per-option explanations.

Regression covers six-hub rendering, System subsection targets, six-control parsing and live mode,
absence of the old capabilities card/probe, all thirteen locales, safe-config acceptance and
rejection, stable baselines across mode changes, missing/unreadable/read-only/mismatch states,
exact restore, single-owner checks and unchanged wakeup set/clear. Host and browser verification
remain distinct from physical ColorOS WebView and kernel/device field validation.

## V66 dev32 - manual Infirmary junk cleanup

Input: the dev31 source and screenshots of diagnostic residue. The new **Infirmary → Cleanup →
Junk Cleanup** card is localized in all thirteen WebUI languages and uses one fixed shell owner,
`runtime/asb_junk_cleanup.sh`, with only `status` and `run` commands.

- **Bounded targets, not a blanket cleaner.** Eleven rows cover DropBox records, tombstones, ANR,
  environment and installer caches, fixed diagnostic logs, backup journals older than 24 hours,
  seven exact `/data/local/tmp` report names, Linux trash, trashed screenshots and ColorOS crash
  logs. Ordinary screenshots, recent tasks, unknown temporary files, OOST flags, controller
  settings and module working state survive. Symlinks are not followed and `-xdev` bounds roots.
- **Metadata preview and explicit deletion.** The scan reports file counts and bytes from `stat`,
  never reads file contents and creates no state. Deletion requires a second tap within five
  seconds. An atomic run lock rejects concurrent work. Cleaned, empty, partial, unreadable, busy
  and lock-error states are separate; the UI neither enables deletion while busy nor calls a lock
  error success.
- **No hidden worker or anti-lag promise.** Nothing is hooked into boot, service or a polling
  loop. The feature can recover storage and remove clutter, but does not claim a universal fix for
  lag, improved FPS, battery life or responsiveness.

Runtime regression exercises all eleven categories, exact count/byte accounting, recent-journal and
protected-file survival, idempotence, busy/lock/partial results, symlink rejection and unknown
commands. WebUI regression covers thirteen locales, the fixed command protocol, five-second
confirmation, result parsing, text-only rows and every visible failure state. Host and browser
verification remain distinct from physical ColorOS WebView and field validation.

## V66 dev31 - visible kernel controls and explicit unsupported states

Input: the dev30 source and the KRILIKD v9 build framework. The goal is one visible WebUI
location for the existing standard kernel controls and the optional wakeup policy without
turning saved configuration or build-time config evidence into a runtime success claim.

- **Settings → Kernel is a seventh configuration group.** It contains MGLRU mode, timer
  migration, scheduler migration batch and the newly visible scheduler debug accounting
  control. The four controls use the existing bounded owner, baseline capture, readback and
  exact Stock restore. `kernel_sched_stats` moved from the old independent system-tweak writer
  into `runtime/asb_kernel_controls.sh`; its legacy baseline path remains compatible.
- **Unavailable states stay visible.** Each control distinguishes applied/readback success from
  `not_exposed`, read-only, unreadable, failed and mismatched states. The Kernel page reads its
  controls, wakeup status and capability evidence on demand in one batch. It starts no polling
  worker and writes no sysfs or policy file directly from JavaScript.
- **The wakeup card has a transactional full-list command.** `asb_wakeup_blocker.sh set
  [NAME...]` validates and deduplicates at most 16 exact names, atomically replaces the saved
  policy, applies it through the existing owner and verifies current kernel readback. Invalid
  or excessive updates leave the previous policy untouched. Saved/current rules and the
  blocked-event counter are separate. Empty `set` and the Clear action remove both saved and
  live rules. A missing ABI remains `not_exposed`, never applied success.
- **Read-only support evidence, not dummy switches.** The capability card reports CAKE, IP
  sets, Re-Kernel and SDP 900 mA. CAKE control remains in Network; Re-Kernel remains a channel
  for a compatible external freezer; SDP has no writer without a confirmed OPlus ABI.
  `tools/asb_device_info.sh --kernel` stops before the full package/display/thermal collector,
  and `CONFIG_SCHEDSTATS` is now included in its bounded config whitelist so an explicit
  disabled state can actually be reported.
- **Thirteen locales cover the new page and verdicts.** Device, app and kernel values continue
  to be inserted through `textContent`; exact wakeup names are shell-quoted as separate
  arguments and validated again by the shell owner.

Regression covers the four-control ownership/apply contract, full-list wakeup replacement and
rollback, legacy scheduler baseline restore, all thirteen locales, seven-group navigation,
Kernel page parsers and interactions (including loaded-module evidence and dash-led exact
names), and the real short `--kernel` collector with node/config states. No native source
changed; existing native warning and DSP gates remain mandatory.
Host and browser fixtures do not prove physical ColorOS WebView behavior, safe blocking of a
particular wakeup source, charging behavior, battery savings or freezer compatibility.

## V66 dev30 - bounded kernel wakeup policy and a retryable MGLRU memo

Input: the dev29 source, the KRILIKD v8 build framework and current OnePlus 15 diagnostics. The
running kernel reported `CONFIG_NET_SCH_CAKE` and `CONFIG_IP_SET` as not set, with `fq_codel` in
force; ASB's `disabled` verdict was therefore correct. The kernel source requested those options,
but requested lines were not proof of the final resolved configuration. KRILIKD v9 adds a
fail-closed final-config gate; ASB still requires real runtime `tc`/`ipset` validation.

- **One bounded owner for the new KRILIKD wakeup ABI.** `runtime/asb_wakeup_blocker.sh` applies
  `config/wakeup_blocklist.conf` to `/sys/kernel/asb_wakeup/blocklist`. The file is empty by
  default and contains one exact wakeup-source name per line: no comments, whitespace, paths,
  glob/regex patterns or arbitrary values. At most 16 unique printable-ASCII names of 1–63 bytes
  are accepted; duplicates are removed before apply.
- **Apply is verified and failure-safe.** ASB clears the old list, adds the normalized policy,
  compares the kernel readback byte-for-byte and clears a partial or mismatched result. A missing
  node is `not_exposed`, not success. Boot performs one apply; Safe mode, level-3 recovery and
  uninstall clear the list. There is no polling worker, automatic rule generator or attempt to
  force-release a lock that is already active. `/sys/kernel/debug/wakeup_sources` remains
  read-only statistics and is not treated as a blocking interface.
- **The OP15 MGLRU memo no longer hides transient failures.** The Smart tuner saves a per-boot
  memo only after an applied result or the known stable `0x0001` readback clamp. `write_failed`,
  `baseline_failed` and other mismatches are retried on the next pass instead of being silently
  remembered as completed.
- **Diagnostics distinguish build evidence from runtime support.** The device report recognizes
  `CONFIG_REKERNEL`, its network transport and `CONFIG_ASB_WAKEUP_BLOCKER`, and reads the current
  rules/counter only when exposed. Re-Kernel compatibility with a particular third-party freezer
  remains unproven until an on-device event/unfreeze test.
- **No invented SDP charging control.** `oplus_sdp_900ma` is reported as `not exposed; no confirmed
  OPlus SDP current-control ABI`. No unknown vendor node is written and 900 mA charging is not
  claimed.

Regression adds a transient-first/successful-second MGLRU case and a stateful kernel-node fixture
covering empty default, exact apply/readback, dedupe, malformed and excess rules, mid-apply
rollback, clear/status/counter, missing ABI and lifecycle integration. No native source changed;
the existing two-ABI NDK gate is unchanged. Host fixtures do not prove physical suspend, modem,
Wi-Fi, alarm, call, charging, battery or freezer behavior.

## V66 dev29 - the Zygisk policy read without the dev23 cache, narrower kernel verdicts

Input: an external review of the dev27 findings. It confirmed the policy-cache analysis for
Magisk, asked to limit "never" to what is shown, and to word the kernel verdict by what the
helper actually checks.

- **The dev23 policy cache is removed.** `read_policy` runs from `preAppSpecialize`, which the
  Zygisk API defines as running in the app process just forked from zygote, so a copy stored
  there cannot reach the next fork with a loader that follows the API. Under Magisk the module is moreover dlopened and
  constructed anew in each app process (`ZygiskContext::app_specialize_pre` ->
  `run_modules_pre`). The fixture's 20 hits came from repeated calls in one process, which
  `preAppSpecialize` never makes. Each read is again one open and one parse with no `stat` or
  `fstat`; every failure still leaves an empty, inactive policy, and EACCES on the absolute
  path still falls back to the loader's module directory. The `onLoad` comment no longer says
  "runs once in zygote": under Magisk it runs per app process, under a loader that calls it in
  zygote it runs once; its probe is unchanged.
- **Kernel-control verdicts say what is known.** The helper checks one registered path per
  control, so `not_exposed` now reads "interface not exposed" instead of "not in this kernel",
  and `not_writable` "interface is read-only". For `sched_nr_migrate` the parameter may still
  exist as `/sys/kernel/debug/sched/nr_migrate` (Linux 5.13, commit 8a99b6833c88) or in a vendor
  backport; ASB does not write debugfs, which would need its own baseline, readback and device
  check.
- **History.** dev23 carries a correction note; the dev24 input line no longer names the
  settings-export app. VPN Hide (ownership boundary) and the dev23 reference module
  (attribution) stay named.

Regression: the policy-cache fixture is replaced by a policy-read fixture on the real Observer
with wrapped libc calls (one open and one parse per read, no stat/fstat, replacement, removal,
malformed and inactive policies, fail-closed errors, EACCES fallback, `-Werror=narrowing`), and a
static check rejects a returning cross-fork cache.

**Native code changed** (`src/zygisk/asb_observer.cpp`, comment in
`asb_observer_protocol.h`): both Zygisk ABIs need the CI NDK build before a binary module.
The read path is the dev22 one, which already built for both ABIs.

## V66 dev28 - the Infinite Log start race behind the dev27 CI failure

Input: the failed GitHub Actions run for dev27. Shards features and system-smart passed; the
ui-zygisk-package shard failed one test, `debug_support_contract`, at "concurrent start count
round=2": one start request answered `status=starting`, the other `error=recorder_exited`, and
no request answered `status=started`. No dev27 change touches that helper; the test passed in
every local full run because the window is narrow and opens mainly under the CI's eight
parallel jobs on four vCPUs.

- **A live launcher could look foreign.** `full_day_pid_owns_lock` read the launcher's command
  line twice: once inside `full_day_pid_matches_recorder`, then again for the "helper still
  forking" case. When the exec into `nohup setsid sh .../asb_log_full_day.sh` happened between
  the two reads, the first saw the helper (not a recorder), the second saw the recorder (not
  the helper), and the PID was declared not to own the lock. `lock_known_dead` then said "dead",
  the second tap renamed the winner's lock away and launched a second recorder. The second read
  now accepts the recorder's command line as well.
- **A failed start removed someone else's lock.** The request whose recorder exited before
  claiming ran `rm -rf` on the lock directory, which by then belonged to the other request;
  that request's recorder kept running without a lock, so it answered `status=starting` after
  its 10 s handshake. The lock is now removed only while it still carries the request's own
  token.
- On the phone the same pair needed two Infinite Log start taps within a few milliseconds;
  rare, but it could leave a recorder running outside the lock that Stop uses.
- **Test flakes under parallel load.** `debug_support_contract` and `net_verdict_contract`
  piped `echo "$x"` into `grep -q` under `pipefail`; grep exits at the first match and the
  writer can then fail with EPIPE (CI ignores SIGPIPE: its log shows "echo: write error:
  Broken pipe"). Measured 1 false failure in 20000 under load and 2 failures in 80 parallel
  runs of the test; after the change 0 in 80. Both tests use here-strings, the diag waits allow
  10 s instead of 3 s, and a static check rejects the pattern in any test that sets pipefail.

Regression: a deterministic test serves the two command-line reads in order (helper, then
recorder) and fails on the dev27 helper; a second case has a recorder hand the lock to another
token before it exits and checks that the lock survives. No native code changed.

## V66 dev27 - one MGLRU owner for real, localized kernel verdicts, 200+ translations

Input: the owner's dev26 source, reviewed file by file against dev20, plus the earlier
Infinite Log bundles. Host regression of dev26 as received: 493/493 PASS.

- **The dev24 single-owner contract had a second writer.** `apply_vm` in service.sh still ran
  `echo 7 > /sys/kernel/mm/lru_gen/enabled` at boot, on every profile apply and on the
  5-minute reinforce. It undid `mglru_mode=off` and `stock` within five minutes, fought
  Smart's 5, and at boot ran before `asb_system_tweaks.sh` (deferred core boot, then
  tweaks), so the helper's "pre-ASB" baseline was ASB's own 7 on every kernel that keeps
  that value; Stock and uninstall would then "restore" 7. The regression's grep looked for
  `sysctlw`/`writef` forms and missed `echo`. `apply_vm` now calls the helper and leaves
  Smart profile + `mglru_mode=smart` to the Smart tuner; `asb_system_tweaks.sh` does the
  same, so neither overwrites the tuner's 5/7 choice.
- **fix138 came back.** On the OP15 the node reads `0x0001` whatever is requested. dev20
  remembered each request's readback for the boot and skipped an unchanged node; dev24
  dropped that, so every Smart tuner pass started the helper and wrote the node again,
  only to log another readback mismatch. The per-boot readback memo is restored in front of
  the helper.
- **Smart without a load request asks for 7**, the value every non-Smart profile had until
  dev24, instead of quietly moving Battery/Balanced/Performance to 5. In the Smart profile
  the tuner still chooses 5 or 7 by load.
- **The kernel-control toast spoke machine words.** `not_exposed`, `readback_mismatch` and
  `live 0x0001` were shown raw and in English in all 13 locales. Every verdict the helper
  can return now has a phrase in every locale, and a clamped request says what the kernel
  kept.
- **Translations.** 186 strings (Infinite Log digest and its legends, the device and kernel
  pages, system load, wakelock freezer, Zygisk observer) were English in eleven locales, and
  about twenty short labels (Summary/Actions/Details, Safe mode, load bands, Restore, GPU
  busy) in all of them. All translated; the Russian "У потолка {cl}" sentence no longer breaks
  the case of the cluster name. A regression now fails on English prose left in any locale.
- **Crash line in the digest.** The latest crash showed `/system/bin/keystore2 /data/misc/keystor`:
  the command line with its arguments, cut at 40 characters. Only the process path is kept.
- **Shell comments** added in dev21-dev26 to module shell code were removed, per the
  project's rule; no code line changed with them.

Found and deliberately not changed:

- **The dev23 Zygisk policy cache cannot hit on a phone.** `preAppSpecialize` runs in the
  forked app process, and Magisk dlopens the module there and calls `onLoad` per process
  (`ZygiskContext::app_specialize_pre` -> `run_modules_pre`, child only). Each process starts
  with an empty cache and reads the policy once, so every fork still opens, reads and parses
  it, now with one extra `stat` and `fstat`. The host fixture's 20 hits come from one process
  calling `read_policy` repeatedly, which a phone never does. The code is correct and
  fail-closed, and the added cost is two syscalls, so native code is left as built;
  reverting it is optional at the next rebuild. The `onLoad` comment "runs once in zygote"
  is likewise not true under Magisk. (dev29: the cache is removed; the claim is narrowed to
  what holds for every loader, see there.)
- **`kernel_sched_nr_migrate` will most likely read "not in this kernel" on 6.x kernels**:
  since Linux 5.13 `sched_nr_migrate` lives in debugfs, not `/proc/sys/kernel`. The helper
  reports that honestly; no other path was added. (dev29: the phrase now says the interface
  is not exposed, which is what the helper actually knows.)
- **Stepped LTPO decay (dev22) costs time at high refresh.** This panel advertises
  60/90/120/144/165 Hz (display_config.txt), so after the 2 s quiet delay the panel passes
  144, 120 and 90 Hz for 1 s each: 60 Hz is reached after 5 s instead of 2 s, with four
  Settings writes instead of one per pause. Kept as the owner chose it; not measured here.

No native code changed: no CI rebuild needed beyond the one dev23's observer change already
requires. Host fixtures are not device validation.

## V66 dev26 - structured CI build summary

Input: the GitHub Actions Summary screenshot for the test build. The useful package information was
limited to log text, while the release workflow emitted OTA JSON separately from its build summary.

- Test and release workflows now use one package-derived Markdown report with build identity, real
  ZIP size/CRC/SHA-256, native payload hashes, all three regression shards, native warning/NDK/package
  gates, artifact upload outcome and a separate device-validation boundary.
- Release OTA JSON appears once inside that report. The advisory step still never gates building or
  publishing, but no longer appends a second summary block. Test builds show no release OTA manifest.
- DSP reference presence, AIDL package checks and runtime verification remain distinct. Staged DSP
  binaries are not described as rebuilt by the NDK job, and host success is not physical ColorOS,
  WebView, charging, LTPO or audioserver validation.

No module runtime, profile, kernel-control, native source, DSP payload or packaging policy changed.
GitHub's own action/runner annotations remain outside the custom Summary.

## V66 dev25 - 32-bit NDK observer build fix

Input: the failed GitHub Actions bundle for dev24. All three host-regression shards completed;
the separate NDK job built arm64-v8a and then stopped on armeabi-v7a. Bionic's 32-bit `stat`
fields are wider than `dev_t`, `ino_t` and `off_t`, so Clang rejected three narrowing conversions
in the dev23 policy-fingerprint aggregate. This was an ABI-specific compile failure, not a runtime
policy-cache failure.

- `PolicyStamp` now makes all five `stat`-to-fingerprint conversions explicit. No policy, cache,
  IPC, observer-selection or restore semantics changed.
- The policy-cache regression checks the 32-bit conversion boundary and compiles the real observer
  fixture with C++11 narrowing promoted to an error. The workflow's actual two-ABI NDK build remains
  the authoritative Android compile gate.

This source release contains no rebuilt observer `.so`; a successful two-ABI CI NDK build is still
required before packaging a binary module. Host tests do not claim a physical-device validation.

## V66 dev24 - bounded standard-kernel controls

Input: verified dev23 source, two fresh KRILIKD CI bundles and five settings-database exports. CI proves a
successful 6.12.69-android16-2026-03 build with VPN Hide 1.3.1 `full`, zero rejected patches and
`LTO=NONE`; it does not prove physical boot or runtime support. No account, serial, IMEI or
network identifier was read from the settings exports, and no new settings-database tweak was
inferred from key names alone.

- **ASB now controls three existing Linux interfaces**, not a invented KRILIKD ABI:
  `mglru_mode=stock|off|on|smart`, `kernel_timer_migration=stock|off|on` and
  `kernel_sched_nr_migrate=stock|1|2|4|8|16`. Defaults smart/off/4 preserve the previous Smart,
  timer=0 and balanced migration=4 policy. The former battery=2/performance=8 hidden overrides
  are intentionally replaced by the single user-visible value.
- **One bounded owner performs discovery, atomic baseline capture, allowlisted write and numeric
  readback.** Missing/read-only nodes and baseline/write/readback failures are distinct verdicts.
  MGLRU `0x0007` and decimal `7` are equivalent; a clamped `0x0001` is not reported as an applied
  5/7. Stock and uninstall replay the captured value and remove its state only after verified
  restore. Stock profile releases these controls as well.
- **Smart cannot fight manual MGLRU.** Its 5/7 requests run only in `mglru_mode=smart` and pass
  through the same helper. Service profile/reinforce no longer writes timer migration or
  `sched_nr_migrate` directly. BBR/qdisc/network ownership is unchanged; VPN Hide remains owned
  exclusively by its matching app/companion.
- **WebUI shows the helper's actual verdict** for the three controls instead of translating a
  saved config value into success. Config validation, snapshots/update carry-over, ownership,
  diagnostics and all 13 locale files include the new closed schemas. Kernel values enter UI as
  text. No persistent polling worker, arbitrary path/value writer or new native component exists.

Host fixtures use temporary nodes/state only. They do not establish physical OnePlus 15 support,
boot, battery/performance gains or ColorOS WebView validation. On an upgrade from a build that
already wrote these nodes without a ledger, the first newly captured value is the then-current
value; ASB cannot reconstruct an older factory value that was never recorded.

## V66 dev23 - metadata-cached Zygisk policy

Input: the verified dev22 source and the external `Force ltpo` v1.0.1 reference module.

- **The reference contains no separate 1 Hz writer.** It bind-mounts an
  `oplus_vrr_config.json`; that JSON is byte-identical to the previously captured live table.
  ASB already clones the current device's table and enables only flags exposed by that table.
  No foreign backlight/app rules, hardcoded 1/30 Hz mode or universal 1 Hz claim was added.
  Dev22's panel-advertised touch decay and video/camera/game ownership remain unchanged.
- **An unchanged Zygisk policy is no longer opened, read and parsed for every regular app
  fork.** The zygote side stats the small generated policy and reuses its parsed copy while
  device, inode, size and nanosecond mtime match. The runtime writer already uses temporary
  file + atomic rename, so a replacement has a new inode. The stamp cached after a reload is
  taken from the opened fd, not only from the earlier path lookup.
  *Correction (dev29): this did not hold on a phone. `read_policy` runs from
  `preAppSpecialize` in the forked app process, so the cached copy never reached the next
  fork; under Magisk the module object is new in every app process. The cache was removed.*
- **Policy failures remain fail-closed.** Removal, malformed input, stat/open/fstat/read/parse
  failure, or loss of the loader's module-directory fd withdraw the active policy for that
  read instead of returning a stale cached copy. Absolute-path EACCES retains the existing
  module-dir fallback. Valid but inactive policies are cached as inactive.
- **No profile numbers were changed.** Existing captures already showed low governor cost and
  96–98% unchanged-JSON suppression; they do not justify new frequency, boost, polling, thermal
  or per-app values. No persistent worker, hook, hardware writer or governor opcode was added.

The native fixture wraps the real Observer's libc calls and verifies 20 consecutive cache hits
with zero additional policy open/read/parse calls, same-size atomic replacement, generation /
flag / package changes, inactive caching, removal, malformed replacement, terminal I/O errors
and EACCES fallback. The existing ABI hot-path and companion suites remain in the full gate.

Native source changed: both Zygisk ABIs require the separate CI NDK build before a binary
module release. This source archive contains no rebuilt or newly added `.so`. Host fixtures do not prove a physical 1 Hz
panel mode, measured power savings, or field validation on every device/ROM.

## V66 dev22 - panel-advertised LTPO decay and fatal-input handling

Input: six older Infinite Log bundles, eight diagnostic/device exports and user reports about
abrupt 165-to-60 Hz switching. The reports predate this source; each repeated symptom was
checked against dev21 before changing code.

- **Stepped idle decay uses only modes advertised by the current panel.** After the existing
  quiet delay, the touch controller descends through unique advertised rates above the idle
  target, highest first, with one blocking input wait per step. A panel reporting
  60/90/120/165 can therefore follow 165 → 120 → 90 → 60; a panel reporting only 60/165 keeps
  the direct transition. No 90/120 Hz mode is invented. `ltpo_idle_step_s` is internal,
  defaults to one second and is bounded to 1–5 seconds. A touch at any step restores the panel
  maximum immediately. Video ownership, camera/game guards and SurfaceFlinger release are
  retained, including when camera/game state appears in the middle of decay.
- **A broken input command is not inactivity.** `timeout` is required before ASB publishes
  touch ownership. The watcher now distinguishes timeout status 124 from exec/device errors;
  the latter restore the active peak and terminate instead of causing a false idle write or a
  tight retry loop. Stop and cleanup still remove the PID, stop and heartbeat markers and
  release a forced SurfaceFlinger mode.
- **Old findings not patched again.** Repeated `60.0 -> 60 Hz` video records are already
  rejected by dev21's locked current-value guard. `REFUSED=1` in the reports names the ROM's
  non-writable `network_recommendations_enabled`, not an LTPO write failure. The aggregate
  `readback_mismatch=1` does not identify a separate live defect in these exports. Unknown
  screen-on refresh samples remain unknown rather than being filled with a guessed rate.

Regression covers stepped and flat panels, duplicate modes, touch during decay, stepped video
ownership, camera before and during decay, active/idle input errors, missing `timeout`,
SurfaceFlinger force/release, cleanup and portable sleep. No new service, polling worker,
mount, native component or per-app/SoC writer was added.

This is host/runtime-fixture verification, not proof of a physical 1 Hz mode, measured power
savings, or field validation on every ColorOS panel. No native source changed.

## V66 dev21 - Infirmary interruption cleanup and root-only observer policy files

Input: the dev20 source, current device/Zygisk/asbdiag exports and detector screenshots. The
source audit and host regression found a narrow file-lifecycle issue, not evidence that ASB
caused the external TEE or mount findings.

- **Battery Fix cleans up after interruption as well as after Stop.** The worker's EXIT path
  now removes its package-list and atomic-progress temporaries on normal exit, TERM, INT and
  HUP. The last complete progress record is retained and reads as interrupted; the lock is
  released. A missing lock also prevents a reused PID from keeping an old run visually alive.
  Post-fs-data removes only the same transient patterns after a reboot, while retaining the
  progress evidence and the pending-reset semantics.
- **Observer policy and launch classes are root-only.** Both are written `0600`, not `0644`;
  an unchanged launch-class pass also tightens a legacy file without rewriting its content.
  Only the root-side zygote/companion consumes them. The observer's DenyList behavior is
  unchanged: the flag is counted, not used to silence the allowlist, and ASB does not edit
  the root manager's DenyList or any separately installed hiding setup.
- **No new mount, service, polling worker, native component or app-specific policy.** The
  current field export's zero module-name mount entries and absent `skip_mount` are recorded
  as observations of that export, not as a universal guarantee for optional overlay features.

Not added: root/Zygisk/memory hiding, renaming or repacking the observer to evade detectors,
TEE/attestation manipulation, or suppression of another module's findings. The mapped
`zygisk/arm64-v8a.so` path is not made invisible by file-permission cleanup. Host tests and
Chromium checks are not physical ColorOS WebView, TEE or battery validation.

No native code changed: no CI rebuild needed.

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
