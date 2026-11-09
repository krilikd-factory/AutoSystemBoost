# AutoSystemBoost — V66 build history

Build-by-build notes of the V66 line, newest first. The V65 release summary stays in
[`CHANGELOG.md`](../CHANGELOG.md) until V66 is released; the V65 line is in
[`V65_BUILD_HISTORY.md`](V65_BUILD_HISTORY.md).

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
