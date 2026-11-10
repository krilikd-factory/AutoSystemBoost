# AutoSystemBoost — V66 build history

Build-by-build notes of the V66 line, newest first. The V65 release summary stays in
[`CHANGELOG.md`](../CHANGELOG.md) until V66 is released; the V65 line is in
[`V65_BUILD_HISTORY.md`](V65_BUILD_HISTORY.md).

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
