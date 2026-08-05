# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V62-16a34a?style=for-the-badge" alt="V62">
  <img src="https://img.shields.io/badge/Previous-V61-6b7280?style=for-the-badge" alt="V61">
  <img src="https://img.shields.io/badge/versionCode-620-0ea5e9?style=for-the-badge" alt="versionCode">
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

## V62 — *nothing is on until you turn it on*

Nine new settings, a per-device CPU rework, a scheduler that stops asking for maximum, and
a first install that finally does nothing until you ask it to.

### Nothing is on until you turn it on

A clean install applies **no power profile at all** and leaves every switch at stock. Eleven
settings used to ship enabled, so the module had opinions about your phone before you had
opened its interface once. The home screen shows *not selected* until you choose.

Upgrades are unaffected: your profile and every setting carry across, including through an
uninstall-and-reinstall.

### CPU limits that fit the device

The frequency caps were OnePlus 15 numbers applied to every model. On a OnePlus 13 — whose
`policy0` covers six cores and whose frequency table contains no 1190400 at all — the cap
could not hold, six cores ran unrestrained, and the phone ran hot. Owners of the 15 and Ace 6
saw nothing wrong, which is why it took field reports to find.

Caps are now scaled to each device's own frequency table and snapped to steps it really has.
The half that writes them reads that file too, which it previously did not.

**And a cap of "45%" now means 45%.** Turning a percentage into a frequency picked the
nearest step *below* the target, and frequency tables have gaps: on a OnePlus 13 prime
cluster, 45% landed on 39%. Those percentages were tuned from field feedback, so a sixth
harder than the tuned number is a different setting wearing its name — and a prime pinned
below what the work needs pushes that work onto the little cluster for longer.

Related: when something outside ASB raises a cap back up, that is now recognised as a
conflict and backed off from, instead of being counted as ASB's own work and fought all day.

### Scheduler no longer pinned to maximum

`sched_util_clamp_min` ships at 1024 on OxygenOS — every task may demand full capacity, and
the vendor boost framework does. Frequencies stayed high regardless of real load. ASB now
caps that ceiling at the running profile's own top-app minimum. Idle, reading and music are
where you will notice; genuine load still gets what it needs.

### Heat and battery: three causes found in field captures

**With the screen off, the governor now goes quiet on every profile.** It used to do that
only for Battery: on Balanced and Performance it kept polling sensors every five seconds
with the anti-clamp armed, screen off or not. Two captures show the cost — idle at 83%
CPU-awake and charging-idle at 100%, against a 5% target, with 274 of 416 throttle events
landing while charging. That last part is the module and the vendor thermal engine writing
over each other, and on a OnePlus 13 it was enough for OxygenOS to disable its own display
enhancement with "device overheated".

**Camera hold is bounded now.** Holding the clocks up while the camera streams stops a
dropped frame in a burst or in 4K60 — those last seconds to minutes. A video call streams
the camera identically for forty minutes, and the hold had no limit at all. It releases
after three minutes, or as soon as the CPU reaches the profile's own throttle point,
whichever comes first. Real load still raises the clocks on its own, so a recording that
needs them keeps them.

**Video playback has its own GPU ceiling.** It was the single highest-drain phase in a
capture — 25.4 %/h against 14.2 %/h for gaming on the same phone, with the CPU nearly idle
and the GPU at 55%. It was also the one high-GPU case with no ceiling of its own. The
decode block does the work and the GPU only composites, so a ceiling above what compositing
needs still saves a ramp to maximum that nothing asked for.

### New settings

| | |
|---|---|
| **Freeze Google Components** | Disables telemetry, reporting and ads components inside Play services. GMS itself stays enabled — push, sign-in and payments keep working. Reversible per component. |
| **Google Services Trim** | Narrows what Play services may do in the background, without freezing anything. |
| **Deep Sleep** | Doze tuning that covers the light phase as well as deep — the phase that actually runs while a phone is in a pocket. |
| **Trim Doze Exemptions** | Removes user-installed apps from the list that lets them ignore Doze. Never touches the dialer, SMS, clock or your root manager. |
| **Animation Speed** | A real setting instead of a side effect of the power profile. |
| **DSP Outputs** | Restricts the audio effect to chosen outputs, so headphone gain stops boosting the loudspeaker. |
| **Headphone Volume Limit** | The EU volume cap is no longer removed silently. Off by default, with the hearing warning stated plainly. |
| **Background Process Limit** | Android's phantom-process killer, controllable. |
| **Athena Background Killer** | OxygenOS has its own background app killer, and it is why a messenger left in the background stops delivering notifications until you reopen it — no battery whitelist fixes that, because it is not Android's Doze. Disables the deciding component only; the rest of the package keeps running. Costs RAM and a little drain. |

### Fixes

- **Throttling temperature** stayed where you put it. Two separate boot paths rewrote it, so
  a deliberate 55 came back as 70 — and on a hot-idling device the correction could produce
  values outside the slider's own range. The slider also allowed points a phone can never be
  below: a OnePlus 15 idles at 48 °C on the hottest CPU zone, so a 36 °C point meant
  throttling was permanently on — which makes a phone hotter, not cooler. The floor is 52 °C,
  and a value stored by an older build is raised to something this device can actually sit
  below.
- **DSP output routing** never worked: the effect runs inside the vendor audio HAL, which
  cannot read the module's properties. The decision moved to the component that can.
- **Camera grading** no longer compounds across installs.
- **The module card** said "Balanced" while the app said "not selected". Two copies of the
  function that writes the card exist, and the one that wins was missing the not-selected
  case.
- **Settings that could not be applied now say so.** On some devices the `settings` command
  fails while still reporting success, so writes looked fine and read-backs returned the
  error text as a value: Bluetooth volume, WiFi scan rate, blur, haptics and the OEM toggles
  were all quietly doing nothing. The module falls back to the content provider and verifies
  every write by reading it back.
- **Values from Android 15 and newer parse correctly.** Settings started returning
  `1, is_preserved_in_restore=true` instead of `1`, which silently broke every comparison in
  the module.
- **Skip lockscreen has been removed.** It could only ever work below Android 11 — above that
  the keyguard ignores the setting it wrote, so it stored perfectly and did nothing. Anyone
  who had it on gets their original setting back automatically.
- **Installs from CI failed** with a missing-file error that pointed at the wrong file
  entirely. There were two copies of the installer and the dead one was being packaged over
  the live one.
- **Blur** no longer flashes off for a moment the first time the app drawer opens.
- **OEM toggles** are recorded before install and put back once afterwards, so RAM expansion
  stops re-enabling itself on machines where the user keeps it off.
- **Network `auto`** now means the value your phone shipped with, captured before ASB touches
  anything, rather than a value ASB picked.
- **Two failed boots** remove ASB's display properties automatically.
- `config.disable_rtt` removed. It disabled Real-Time Text — an accessibility feature for
  deaf and hard-of-hearing users — for no measurable saving. Inherited from a build.prop list
  that has circulated since the early 2010s.
- `db.log.slow_query_threshold` set to a large positive value. At `-1` logging was off by
  accident of implementation; at `0` it logged every query.

### Interface

- **11 languages**, up from 2: English, Russian, Ukrainian, German, Spanish, Portuguese,
  Turkish, Indonesian, Italian, Arabic, Chinese. Translations live in `webroot/i18n/*.json`,
  so contributing one no longer means editing a 4700-line file.
- Every card states when it takes effect, and the confirmation that appears agrees with it.
- Aggressive settings say what will stop working, next to the switch rather than in a wiki.
- **DSP Outputs** reads `USB` and `BT` in English instead of `wired` and `bt` — these phones
  have no headphone jack, so "wired" meant the USB-C port all along.
- The Smart panel is shown only while Smart is the running profile.

### Under the hood

- The learner reads the temperature and drain history it had been recording and ignoring, and
  compares against **this device's** own median rather than absolute degrees.
- `action` explains what Smart has learned, what it concluded and what it is watching.
- `asbdiag` covers all 49 settings, including the DSP chain end to end. It also names the
  Android version, prints what the governor is actually doing rather than what it was asked
  to do, warns when the throttle point is one this phone can never sit below, and says once —
  at the top — when settings cannot be written at all.
- `asb_diag.sh` ships in release builds now. It never did: the one script users are asked to
  run when reporting a problem existed only in debug versions.
- The linter checks config-schema drift, migration coverage, translation completeness and the
  DSP source; CI builds the DSP library and attacher on every relevant change.

---

### Worth knowing

- A first install does nothing until you open the app and choose — this is deliberate
- **Freeze Google Components** is reversible, but check anything you depend on after enabling it
- **Deep Sleep** on aggressive can delay notifications from apps that poll on their own;
  high-priority push always gets through
- **Headphone Volume Limit** is off by default for a reason — sustained high volume damages hearing
- Camera changes show up after the camera app is restarted
