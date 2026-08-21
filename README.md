<p align="center">
  <a href="README.md">English</a> · <a href="README.ru.md">Русский</a>
</p>

<h1 align="center">AutoSystemBoost</h1>

<p align="center">
  <img src="https://raw.githubusercontent.com/krilikd-factory/AutoSystemBoost/main/banner.png" alt="AutoSystemBoost banner" width="80%">
</p>

<p align="center"><strong>Adaptive root module for OnePlus devices</strong></p>
<p align="center">Profiles, runtime CPU/GPU policy, thermal protection, audio DSP, camera tuning and a built-in WebUI — with device capability checks and diagnostics.</p>

<p align="center">
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/releases"><img src="https://img.shields.io/github/downloads/krilikd-factory/AutoSystemBoost/total?style=for-the-badge&logo=github&label=Downloads" alt="Downloads"></a>
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/releases/latest"><img src="https://img.shields.io/github/v/release/krilikd-factory/AutoSystemBoost?style=for-the-badge&logo=github&label=Latest%20release" alt="Latest release"></a>
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/stargazers"><img src="https://img.shields.io/github/stars/krilikd-factory/AutoSystemBoost?style=for-the-badge&logo=github&label=Stars" alt="GitHub stars"></a>
</p>

---

## What ASB does

ASB is not a one-time collection of `sysfs` writes. Its native service observes available device signals, selects a workload state and applies only the policy that is relevant to that state. The module keeps the original value or skips a node when a feature is unsupported, a path is unavailable, or another component owns the decision.

The objective is practical: reduce unnecessary work, heat and battery drain during light use and idle time while preserving responsiveness when the phone is busy. It does **not** promise one benchmark result for every device, and it does not use copied frequency tables or universal voltage tweaks.

| Area | What ASB provides |
|---|---|
| **Runtime governor** | Six workload states: `DEEP_IDLE`, `LIGHT_IDLE`, `MODERATE`, `HEAVY`, `SUSTAINED` and `GAMING`; state-specific CPU/GPU caps, thermal budget and hysteresis. |
| **Profiles** | Smart, Balanced, Battery and Performance envelopes. Manual profiles are predictable; Smart adjusts to current activity and thermal evidence. |
| **Thermal safety** | Validates temperature sources, respects platform thermal policy and reduces work gradually before a hard limit is necessary. |
| **Audio** | Built-in DSP with loudness, bass shelf, compressor, limiter, output selection and route-aware diagnostics. |
| **Camera** | Reversible tuning built from the phone's own camera baseline: grade, contrast, grain, portrait and low-light controls. |
| **WebUI** | Profiles, settings, trial mode for selected changes, applied-value evidence, saved configurations and in-page reset choices. |
| **Diagnostics** | `asbdiag` and effective-policy telemetry show capabilities, ownership, requested values and real readback. |

---

## Supported devices and root managers

ASB is designed for rooted OnePlus devices. OnePlus 15, OnePlus 13, OnePlus 12 and Ace 5 are the main reference families; other OnePlus models use the same capability-gated path when their required interfaces are available. The module discovers the actual CPU policies, OPP tables, thermal paths, GPU backend and supported audio/camera locations on the installed device.

| Supported root managers | Notes |
|---|---|
| Magisk, KernelSU, KernelSU Next, APatch and ReSuKiSu | Install one ASB ZIP only. Do not install both a release and a debug build at the same time. |

A device outside the reference families is not treated as an automatic failure, but it is also not treated as identical hardware. Unsupported or unreadable paths are skipped rather than guessed.

---

## Installation and update

1. Download the normal **Release ZIP** from the [Releases page](https://github.com/krilikd-factory/AutoSystemBoost/releases/latest). Use a debug ZIP only when collecting diagnostics.
2. Flash it in your root manager and reboot.
3. Open the module WebUI. Choose a profile first, then enable only the optional controls you need.
4. During an update, keep the existing configuration. ASB migrates compatible settings, keeps a transaction record and preserves the active profile where possible.

> Battery, sleep and network changes are conservative by default. Optional features such as wakelock action, GNSS trimming and night modem behaviour remain opt-in.

---

## Profiles and CPU behaviour

| Profile | Intended use | Behaviour |
|---|---|---|
| **Smart** | Daily use | Selects a state from current activity, battery and thermal evidence. During genuine screen-off `DEEP_IDLE`, ASB can request the lowest OPP actually advertised by each physical CPU policy. |
| **Balanced** | General use | Keeps a responsive interactive floor and applies moderate caps when the device is idle or warm. |
| **Battery** | Maximum runtime | Reduces background and idle pressure while preserving essential phone functions. |
| **Performance** | Short high-performance tasks | Uses a higher responsive floor and relaxed caps; it is not the recommended choice for sustained heat-sensitive gaming. |

The lowest CPU OPP is **not** forced while the screen is on, during audio, camera, active work, games or thermal recovery. A low number in a CPU manager is not useful if it creates stutter or makes a short background task run longer. In Smart `DEEP_IDLE`, the target is read from the device's own frequency table; no universal kHz value is used.

---

## Main controls

### Battery, heat and background work

ASB provides screen-off policy, configurable Doze level, background-process policy, optional Google component trimming, wakelock action, charge-aware behaviour, Quiet Night and conservative modem/network controls. These controls are separated because saving battery must not silently trade away notifications, navigation or connectivity.

The WebUI exposes the requested value; trial and ledger status can also show whether the ROM accepted it. If a vendor component overrides a node, ASB reports the observed result instead of presenting the setting as successfully applied.

### Camera

Camera tuning starts from the phone's own stock tuning files. The controls are independent so one slider does not silently alter an unrelated image property.

| Control | Purpose |
|---|---|
| **Camera Grade** | Overall colour, contrast and detail character. Levels 7–10 are intentionally strong and can create an artificial look, banding or halos in difficult scenes. |
| **Contrast & Colour Depth** | Tone curve and saturation without requiring a global grade. |
| **Film Grain** | Restores texture after denoising. Higher values are deliberately more visible. |
| **Portrait AI** | Adjusts compatible face/skin processing paths. |
| **Macro and Low-light Sharpening** | Separate detail controls for close and high-ISO scenes. |
| **Hold Performance While Camera Runs** | Temporarily protects camera CPU availability for bursts and video at a small battery cost. |

Camera overlay changes take effect after a normal reboot. Return a control to its stock value and reboot to restore the stock-derived result.

### Audio and DSP

The built-in DSP chain is:

```text
input → bass shelf → soft-knee compressor → auto make-up → true-peak limiter → output
```

| Control | Purpose and boundary |
|---|---|
| **Audio Profile / Hi-Fi DAC** | Requests a compatible audio path when the device exposes it. It does not fight an external equalizer. |
| **Bluetooth Offload** | `Auto` leaves the ROM decision unchanged; the diagnostic result is route-dependent. |
| **Media Loudness** | Shapes useful media-volume steps; it does not raise the 100% system ceiling. |
| **DSP Loudness, Bass, Compressor** | Controls the integrated effect. Start with modest gain: bass consumes headroom. |
| **DSP Outputs** | Limits DSP to speaker, wired, Bluetooth or a selected combination. |
| **External DSP compatibility** | Use the compatible audio mode when ViPER4Android, JamesDSP or another effect should own the stream. |

### Network, interface and system

Network and Wi-Fi controls cover congestion control, queue discipline, optional RPS/transmit queue tuning, Wi-Fi scan policy and region-aware settings where supported. Interface controls include animation speed, UI effects and haptic strength. System controls include background policy, Athena handling, selected Google component trimming and logs. Each setting is capability-gated and may require reboot, SystemUI restart or a short reapply delay; WebUI states this next to the control.

---

## Saved configurations and reset

The Configuration page keeps profiles inside ASB and can create bounded backup copies in **Downloads** or **Documents**. There is no arbitrary filesystem picker: names are validated, external locations are fixed and imported configurations are checksum-verified.

The Reset button opens an in-page dialog with two separate actions:

| Action | Effect |
|---|---|
| **Reset all category settings** | Restores shipped ASB defaults through the transactional configuration writer. |
| **Reset Smart learning** | Clears only Smart's learned history and leaves category settings unchanged. |

Both actions require a second tap to prevent accidental reset.

---

## Diagnostics

Use diagnostics when a setting seems ineffective, a device becomes warm, or support needs evidence.

```sh
su -c '/data/adb/modules/AutoSystemBoost/system/bin/asbdiag'
```

`asbdiag` shows the discovered CPU topology and OPP tables, minimum/maximum write capability, thermal-source confidence, active policy owner, camera/audio evidence and whether a ROM override was observed. For Smart deep idle, it reports whether each CPU policy accepted the hardware lowest OPP.

```sh
su -c '/data/adb/modules/AutoSystemBoost/tools/asb_effective_policy.sh'
```

This command prints structured read-only policy telemetry. It does not change the phone.

---

## Source checks and project layout

The `tests/` directory intentionally contains small, independent contracts. They guard different risks: configuration transactions, native thermal behaviour, profiles, WebUI safety, package contents, installer migration, camera output and workflow integrity. Keeping them separate means a failure points to one subsystem instead of an opaque monolithic script.

For source users, the canonical complete check is version-independent and lives in `tools/`:

```sh
bash tools/asb_full_regression.sh
```

It is the same host-side regression entry point used to keep debug and release coverage aligned. No version-named runner is placed in the repository root.

---

## Safety and expectations

ASB is reversible where the underlying Android interface allows it. It avoids undervolting, guessed frequency tables, global property packs and forced writes to unsupported vendor nodes. The module cannot override hardware, ROM thermal protection or every vendor PowerHAL decision, and it deliberately reports those boundaries.

Use strong camera or audio settings gradually. Make a backup before broad configuration changes, test one group of controls at a time and provide `asbdiag` plus a full-day log when reporting an issue.

---

## Disclaimer

This project modifies root-level system behaviour. You are responsible for your device, data and local laws. Neither the project nor its contributors are responsible for damage, instability, data loss or unsupported combinations of modules and kernels.
