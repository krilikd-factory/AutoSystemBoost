# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V61-16a34a?style=for-the-badge" alt="V61">
  <img src="https://img.shields.io/badge/Previous-V60-6b7280?style=for-the-badge" alt="V60">
  <img src="https://img.shields.io/badge/versionCode-610-0ea5e9?style=for-the-badge" alt="versionCode">
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

## V61 — *settings you can see*

Installs over V60 the usual way — your settings carry across.

V60 had **16** settings. V61 has **41**, spread over six categories instead of four. Several
things the module used to change quietly now either ask you first or are not done at all.

---

### 🌐 New category: Network

Nine settings that did not exist before.

**Download Ramp** — how the phone builds up speed while downloading. On mobile data and on
weak Wi-Fi `bbr` usually wins: it paces to the speed actually available, whereas the classic
`cubic` reads radio interference as congestion and throws away speed for nothing.

You can set it **separately for Wi-Fi and for mobile**, and both apply at the same time
rather than taking turns: the algorithm is attached to the route itself, so there is nothing
to switch when the network changes.

**Packet Queue** — how the phone shares the connection between apps. `fq_codel` suits most
people: video stops stuttering when something is downloading in the background.

**Network Buffers** — how much data goes out in one burst before the first reply. The
*smart* mode measures your link — negotiated speed, MTU, radio type — and sizes it for you:
larger on a fast link, left at the factory value on a weak one, because a big burst there
only causes the losses it was meant to avoid.

**Wi-Fi Region** — decides which channels your phone may use, and that sets the ceiling on
link speed. `CR` opens the widest set.
*Using channels not permitted where you are is your own call.*

**Wi-Fi Scan Rate** — for when Wi-Fi clings to a weak access point as you move around.

If your kernel cannot do something — stock kernels usually lack `bbr` — the card says
**"not supported"** rather than pretending it applied.

---

### 🎨 New category: Interface

In V60 the System section mixed two unrelated things: what you *see* and what the system
*does*. Everything visual moved into its own category.

**Skip Lockscreen While Unlocked** — when Android's "Lock after screen timeout" is set, the
phone is already unlocked for those seconds, yet OxygenOS still asks for a swipe. Now it can
wake straight back to where you were.

Done carefully: the setting **changes neither whether the device locks nor when** — that
stays Android's decision. It refuses to run if you have no secure lock, or if your lock is
immediate.

---

### 📷 Camera: real control instead of one slider

V60 had a single processing setting. There are now six: **grain**, **contrast**,
**portrait AI**, **low light**, and **hold performance while the camera runs** — the last
one stops a dropped frame in the middle of a burst or a video.

The processing scale is twice as long. The old maximum was the middle of what the engine can
do, which is why the effect was hard to notice.

---

### 🔋 Battery and heat

**Throttling Point** — when the module starts holding performance back for temperature.
*Stock* uses **your** device's own trip point, read from the CPU thermal zone at boot, not a
number guessed for phones in general. *Smart* starts from the same place and adjusts itself.
*Manual* pins exactly what you set, and nothing moves it.

**Quiet Night** — overnight the module stops polling and lets the device sleep deeper.

**No Game Mode on Battery Profile** — on that profile a game counts as ordinary load rather
than a reason to raise clocks.

**Auto Battery profile** now switches at exactly 20% and returns at 21%, instead of 19% and
30%: the number in the setting matches the number on the battery icon.

---

### 🔊 Audio

**DSP Compressor**, **Bluetooth Audio Offload**, and DSP loudness now up to **+25 dB**
instead of 20.

About Bluetooth: if your headphone equaliser does nothing, move encoding to the CPU — then
the equaliser can see the stream. It costs a little battery.

Raising the gain is safe: the output is bounded by construction rather than by that number.
The soft limiter cannot mathematically exceed its ceiling, so the extra decibels change how
dense the sound is, not how clean.

---

### 📳 Vibration

Separate strength for alerts and for touch feedback — V60 had neither.

---

### 📝 Logging, and a way to switch it off entirely

**Log Detail** was a developer knob; it is now a real choice, and the numbers moved.

- **Stock** — the module does not touch your phone's logging at all. This is the only value
  that leaves it exactly as the ROM set it, and the card stays dim to say so.
- **0 — extreme.** Cuts device logging and debug output as far as it goes: log buffers
  shrunk, tag levels silenced, vendor debug traces off. It saves the disk writes and the
  wakeups logging costs. It also makes almost any bug report from the phone useless,
  including one you might send us — so it is for people who have finished troubleshooting,
  not for people about to start.
- **1** — normal. Exactly what the module always did; this is what used to be called 0.
- **2** — detailed. Learner updates and screen transitions. Turn this on *before* sending a
  log about battery behaviour.
- **3** — verbose. Fills the log quickly; only while reproducing something specific.

Extreme mode is reversible: everything it changes is recorded before the first change and
put back the moment you leave it. Nothing here is a one-way door.

---

### 🩹 What stopped breaking

**"Cards" and "Simple" in Recent Tasks Manager.** The module disabled task snapshots — which
are exactly the thumbnails the Cards style draws. Without them OxygenOS hid the whole
selector. It happened unconditionally, whatever settings you had chosen, so the only way to
get the option back was to remove the module. Snapshots are left alone now, and anyone
already affected is repaired automatically — it takes two reboots.

**Turning blur off no longer flattens Recents.** They were two separate settings tied
together for historical reasons.

**Simplified effects are offered on the OnePlus 15 only.** On other models that setting
removes the Cards/Simple selector from Recent Tasks Manager and the phone does not put it
back on its own - a OnePlus 13 owner lost the option and could not work out where it had
gone. The setting still exists where its effect is reversible; elsewhere the button is
simply not shown, and anyone already on it is moved back to normal automatically.

**Settings no longer vanish on update.** Some of them — the whole camera section, vibration,
the whole network section — were saved in one place and restored from another, so updating
the module quietly reverted them to defaults.

**Profiles were applied only partly:** an internal profile variable stayed empty, so some of
the profile's settings never reached the system.

**Camera processing compounded with itself** when installing over an existing copy —
saturation grew with every install until the picture went lurid.

**Audio disappeared after a reboot** for some users: the volume tables were delivered by two
mechanisms at once and the two fought.

**SystemUI restarted on its own** about a minute into every boot — the screen blinked, the
lock screen came back, and status-bar theming from other modules was torn down. It now
restarts only when you press the button.

**Throttling temperature did not work everywhere:** the value from settings was read on the
Battery profile alone and silently replaced by a built-in one on the other three.

**OnePlus 15 was detected as a generic device** and given conservative limits.

**The diagnostic never shipped in release builds** — the script users are asked to run when
reporting a problem existed only in debug versions.

---

### 🎛 Smaller things you will notice

- Six categories instead of four, in less space than the old four took
- **Soft reboot** and **restart SystemUI** buttons beside the normal one
- **Modem LPM**, drain, thermal trend and session count on the Smart card
- Toasts wrap instead of running off the screen, and match their category colour
- A card is highlighted only when the module is actually changing something
- The install screen no longer reports settings you did not enable

---

### ⚠️ Worth knowing

- Network settings apply immediately; a few need a reboot, and the card says so
- **Wi-Fi Region** re-associates Wi-Fi when changed
- Camera changes show up after the camera app is restarted
- **Log Detail 0** silences the phone's logs. If you later report a problem, set it back to
  2 first, reproduce, and send the log then
- A setting that your kernel or ROM cannot do says **"not supported"** on its card instead
  of pretending to work
