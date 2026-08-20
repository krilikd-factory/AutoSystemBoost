<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🛸 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="80%">
</p>

<p align="center"><b>Adaptive runtime engine for OnePlus — Snapdragon 8 Elite / Gen 3</b></p>
<p align="center"><i>A native C daemon that observes the device every two seconds, applies only justified policy, and records why a decision was made.</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/Audio-Own_DSP_engine-dc2626?style=for-the-badge" alt="DSP">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
  <img src="https://img.shields.io/badge/Root-KSU_%7C_KSUN_%7C_APATCH_%7C_MAGISK-16a34a?style=for-the-badge" alt="Root">
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/krilikd/AutoSystemBoost/total?style=for-the-badge&color=0969da&label=Downloads&logo=github" alt="Downloads">
  <img src="https://img.shields.io/github/v/release/krilikd/AutoSystemBoost?style=for-the-badge&color=16a34a&label=Latest&logo=github" alt="Release">
  <img src="https://img.shields.io/github/stars/krilikd/AutoSystemBoost?style=for-the-badge&color=f59e0b&label=Stars&logo=github" alt="Stars">
</p>

---

## ⚡ What it actually is

Most root modules write a static list of values once at boot. ASB is a **runtime
controller**. Its native daemon samples CPU, GPU, thermal, battery and workload evidence
every two seconds, selects one of six activity states, and derives a policy again from the
current device state. It does not treat a node being present as proof that it is safe to
write.

ASB uses a capability manifest, writer leases, a tiered thermal budget, thermal-source
validation and decision provenance. The practical goal is not a universal benchmark gain:
it is to reduce unnecessary work and heat without hiding the reason when ASB deliberately
backs off.

| | Layer | Component | What it does |
|:---:|:---|:---|:---|
| 🧠 | **Core** | `bin/asb` | Six-state governor · session plan · anti-clamp · camera hold · adaptive thermal budget |
| 🌡 | **Safety** | thermal selector + leases | Validates control temperature, respects platform thermal limits and coordinates writers |
| 🎚 | **Audio** | `libasbdsp` | Own DSP effect: loudness · compressor · limiter · bass shelf |
| 🔧 | **Runtime** | `service.sh` + `runtime/` | Capability probe, migration, reconciliation, watchdog and reversible policy writers |
| 🖥 | **UI** | WebUI + Action | Profiles, user controls, live status and explicit “not applied” evidence |
| 🩺 | **Diagnostics** | `asbdiag` + effective policy | Source confidence, applied policy, device capabilities and support evidence |

---

## 📱 Device support

ASB supports rooted OnePlus devices with a supported root manager. It is built around
**device-native discovery**, not copied frequency tables or a global vendor-property pack.
At installation, ASB inventories the current device and works from its own exposed CPU,
thermal, GPU and audio paths. Mutable vendor domains remain behind capability and exact
fingerprint gates.

| Tier | Devices | SoC |
|:---|:---|:---|
| 🥇 **Reference** — hand-validated | OnePlus 15 · 13 · 12 | SM8850 · SM8750 · SM8650 |
| 🥇 **Field-verified** | Ace 6 · Ace 5 · 13R | SM8750 · SM8650 |
| ✅ **Device-native / conservative** | Other OnePlus models — 15R, 13s/13T, 12R, 11/11R, Open, Ace 6T, Nord and Pad families | varies |

Reference devices can use their validated topology and audio/device data. Other devices
run the same capability-gated pipeline with a stricter boot guard. A failed boot removes
the generated overlay before the module mounts; unsupported or unreadable paths are
skipped rather than guessed.

> Similar firmware names are not treated as identical hardware. For example, the Ace 6
> shares `sun` firmware ancestry with OnePlus 13, so ASB resolves its exact fingerprint
> before the broader family match.

---

## 📦 Install

1. Download the **Release ZIP** for normal use. The **Debug ZIP** contains extra analysis
   and logkit tools and is intended for troubleshooting; do **not** install both builds at
   the same time.
2. Flash the ZIP in **KSU / KSUN / APatch / ReSuKiSu / Magisk** and reboot.
3. Open the module **WebUI** to select a profile and optional controls. Tap **Action** for
   live status and the “not applied” report.
4. Keep the existing configuration when updating: ASB migrates compatible settings
   additively, creates a backup first, and retains the active profile and existing choices.

> Battery, sleep and network controls are conservative by default. The
> performance ceiling starts at 100%; wakelock action, background GNSS trim and Quiet
> Radio at Night start off; RPS and transmit queue start at stock.

<p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download_Latest_Release-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Download">
  </a>
</p>

---

## 🎚 ASB DSP — our own audio engine

Volume curves only redistribute the gain the device already provides. ASB ships a real
effect for controlled processing above unity:

```
input → bass shelf (90 Hz) → soft-knee compressor → auto make-up → true-peak limiter → out
```

| | |
|:---|:---|
| 🔊 **`dsp_loudness`** | **+1 … +20 dB** processing gain above unity |
| 🥁 **`dsp_bass`** | **+1 … +10 dB** low shelf at 90 Hz |
| 🛡 **Output safety** | Compression and true-peak limiting protect the output after the boost |
| ⚡ **Live control** | Sliders communicate with the running effect; no `audioserver` restart is required |
| 🎧 **Route-aware evidence** | Records route and AudioFlinger evidence instead of claiming Bluetooth offload without proof |

Android 13+ effects use the AIDL effect contract, while older paths can require the legacy
interface. ASB ships compatible DSP variants from one shared core and uses an attach
helper because OxygenOS does not reliably instantiate a declared post-process effect by
itself. The available DSP path remains device and route dependent; diagnostics report the
observed evidence instead of promising an effect was attached when it was not.

> The bass shelf intentionally sits at the start of the chain. Putting it after the
> compressor and limiter would let extra low-frequency energy bypass those safeguards.

---

## 🎵 Audio — clear controls, no competing writers

| Setting | Options | What it does |
|:---|:---|:---|
| **`audio_profile`** | `stock` · `hifi` · `eq_compat` | `hifi` requests the high-fidelity path where the device exposes it. `eq_compat` lets ViPER/JamesDSP own the output instead of two effects competing for it. |
| **`audio_dac_hifi`** | on / off | Separately controls the compatible mixer/DAC tuning path. |
| **`media_loudness`** | `stock` · mild · strong · max | Adjusts volume curves; the added shaping targets the useful middle of slider travel rather than raising 100% volume. |

Audio behaviour is capability- and route-dependent. ASB preserves the output-safety rule:
100% volume is not raised past unity, and a conflicting external DSP is not silently
fought by ASB.

---

## 🧠 The governor

**Six states.** `DEEP_IDLE` → `LIGHT_IDLE` → `MODERATE` → `HEAVY` → `SUSTAINED` →
`GAMING`. Each state has its own caps, dwell time and entry/exit hysteresis. During genuine
screen-off idle, ASB avoids unnecessary governor work; the screen-off classifier first identifies audio,
charging, VPN/tunnel, GNSS and other screen-off activity so it does not call every dark
screen “sleep”.

**Adaptive thermal budget.** Before a hard thermal cap is needed, ASB can make a light,
moderate or severe proportional trim based on available thermal headroom, temperature
trend/rise and battery-current evidence. A 30-second dwell avoids rapid cap oscillation.
Hard platform thermal protection always wins.

**Thermal-source validation.** Some devices expose a misleading `socd` zone. ASB checks it
against usable CPU peers, rejects implausible high or low readings, falls back to a real
CPU thermal path when one exists, and periodically revalidates the primary source. The
actual control source and confidence are visible in diagnostics.

**Performance Ceiling.** The WebUI can apply a user-selected 60–100% ceiling to the current
profile’s device-correct CPU/GPU envelope. It is an explicit trade-off: 100% preserves the
profile baseline, while lower values can reduce unnecessary peaks for battery-first use.

**Smart Mode** is a fourth adaptive profile, not a fixed fourth frequency table. It blends
within the Battery ↔ Balanced envelope from time buckets, session history and confidence.
Thermal safety, low battery and night policy take priority over learned behaviour.

**Camera Hold and writer leases.** Camera capture, the selected profile, Smart Mode, user
limits and safety/platform thermal actions are coordinated through priorities rather than
blindly fighting over the same nodes. Camera activity receives a protected deadline; all
changes remain bounded by platform thermal safety.

---

## 🎯 Profiles — real policy envelopes

| Parameter | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:---|:---:|:---:|:---:|
| Intent | peak responsiveness | daily default | lower background cost |
| CPU/GPU envelope | highest validated profile envelope | balanced profile envelope | conservative profile envelope |
| `uclamp` top / background | 90 / 50 | 85 / 35 | 50 / 40 |
| RAVG window | 2 (8 ms) | 3 (12 ms) | 8 (32 ms) |
| Swappiness | 12 | 35 | 80 |
| VFS cache pressure | 30 | 80 | 120 |
| Dirty writeback | 10 s | 60 s | 600 s |
| Wi‑Fi power save | off | auto | on |
| GAMING state | ✅ | ✅ | 🚫 blocked |

> Exact available CPU/GPU frequencies come from the phone’s exposed policies and validated
> bounds. ASB does not assume that an OP15 frequency table is valid on an OP13, OP12 or
> Ace device. **Smart** is not shown as a fixed row because it blends only inside the
> Battery and Balanced envelopes at runtime.

---

## 📊 Stock vs ASB

ASB is designed to change decision quality, not to promise one battery percentage to every
phone. Display time, signal strength, apps, Bluetooth route, ambient temperature, charging
and the length of true screen-off periods all materially affect results.

| Area | Stock-style approach | ASB approach |
|:---|:---|:---|
| CPU/GPU policy | Static or vendor-driven limits | Six-state policy derived from current workload and profile |
| Sustained heat | React mainly at a hard thermal point | Bounded adaptive budget before a hard cap, always under platform thermal protection |
| Thermal input | A named sensor can be trusted blindly | `socd` is peer-checked; a real CPU zone is used as fallback when justified |
| Screen-off drain | A dark display can be mistaken for sleep | Audio, charging, VPN, GNSS and activity context are classified first |
| Device differences | Copying values can be tempting | Capability manifest, exact device domains and conservative fallback |
| Support evidence | “Applied” can be an assumption | State provenance, effective policy, `asbdiag` and Action status show the evidence |

The correct way to evaluate ASB is a comparable multi-hour use or overnight capture, then
inspect `asbdiag` and the relevant log evidence. A control that is not appropriate for a
phone is reported or skipped; it is not presented as a universal gain.

---

## 🛡 Safety

- **Reversible:** ASB stores baselines and restores owned values on uninstall; it does not
  write real system partitions.
- **Boot guard:** A generated overlay is removed before mounting after a failed boot; the
  threshold is tier-dependent.
- **Thermal priority:** ASB never overrides hard platform thermal protection. Invalid or
  untrusted thermal evidence is recorded, not rendered as a fake degree value.
- **Atomic configuration:** `asb_config_safe.sh` validates a complete staged configuration,
  writes atomically and records the transaction result, epoch and reload status.
- **Safe upgrades:** compatible configuration migration is additive, backed up and idempotent;
  retained user settings are not silently replaced by new defaults.
- **No competing ownership:** Leases coordinate baseline, profile, Smart, camera, user cap,
  safety and platform-thermal writers.

---

## 🩺 Diagnostics & commands

Tap **Action** in the module list for a live summary and a **NOT APPLIED** section. It is
an evidence report: it lists settings that did not land instead of claiming success because
a command was issued.

```bash
su -c 'asb status'                # native status JSON
su -c 'asb profile:performance'   # switch profile live
su -c 'asb reload'                # re-read active config
su -c 'asbdiag'                   # full report → /sdcard/asb_diag_report.txt
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_doctor.sh'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_intent.sh list'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh status'
```

| Release tool | Purpose |
|:---|:---|
| `asbdiag` | Full PASS/FAIL report: capability context, thermal source/confidence, audio/DSP evidence, policy and support data |
| `tools/asb_doctor.sh` | HEALTHY / DEGRADED / UNHEALTHY health check |
| `tools/asb_effective_policy.sh` | Machine-readable view of the policy, capabilities, energy state and transaction provenance |
| `tools/asb_intent.sh` | Safe presets: daily, camera, game, travel, charging and observe |
| `tools/asb_smart_mode.sh` | Smart Mode status, enable/disable and learner reset |
| `tools/asb_config_backup.sh` | Create a config backup or preview an import before applying it |

The **Debug ZIP** additionally carries logkit, field-report, state-sampling and source
validation tools. Use it when collecting a reproducible support report; use the normal
Release ZIP for ordinary daily use.

### Quality checks

The source and workflows include host-side contracts for thermal-source fallback and
recovery, atomic config writes, writer leases, device safety, DSP references, telemetry
provenance, schema synchronisation, package contents and compatible configuration migration.
Both distribution variants are checked for the runtime files they require before they are
published.

---

## ⭐ Support

- ⭐ Star the repository · 🐛 report reproducible issues on GitHub
- 💬 [Telegram](https://t.me/DKomsomol)

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-Donate-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate via PayPal">
  </a>
</p>

---

## ⚠️ Disclaimer

This module changes system behaviour on rooted devices. Use it at your own risk. ASB is
designed to be reversible, but kernel, firmware and app behaviour still differ by device.
Do not treat a diagnostic observation or a battery result from one phone as a guaranteed
outcome on another.

---

<p align="center"><i>Not magic — just measured policy, bounded writers and evidence for every important decision.</i></p>
