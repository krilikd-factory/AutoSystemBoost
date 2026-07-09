# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V58-16a34a?style=for-the-badge" alt="V58">
  <img src="https://img.shields.io/badge/Previous-V57-6b7280?style=for-the-badge" alt="V57">
  <img src="https://img.shields.io/badge/versionCode-580-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <img src="https://img.shields.io/badge/Ace%206-ktm%20·%20boots%20✓-22c55e?style=flat-square" alt="Ace 6">
  <img src="https://img.shields.io/badge/Ace%205-boots%20✓-22c55e?style=flat-square" alt="Ace 5">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V58 — *the one that boots everywhere*

The headline is simple: **Ace 6 and Ace 5 install, boot, and pass `asbdiag`.**

Getting there meant fixing the detection bug at its root instead of guarding
against its symptoms, and rebuilding how non-reference devices receive their
`/odm` audio. Around that, V58 lands a format-agnostic hi-res audio lifter, an
SoC-aware speaker-gain ceiling, resolution-aware media bitrates, a cooler
thermal envelope, lag-safe CPU bounds for 3/4-cluster SoCs, and an ad-identity
kill that finally cleans up after itself on uninstall.

---

### 🛸 Ace 6 bootloop — fixed at the root (issue #8)

**What actually went wrong.** The OnePlus Ace 6 (`ktm`, PLQ110 / OP6113) ships on
the *shared* SM8750 firmware with the OnePlus 13 — its fingerprint and property
set literally carry the `sun` codename. The installer's SM8750 branch matched
`*sun*` and concluded "this is an OP13", so Ace 6 was handed the full **OP13
reference overlay**, including a magic-mount graft of `system/odm`. On these
devices `/odm` is a real partition mount; grafting a directory over it makes the
audio HAL fail before the boot guard can ever run. Hard bootloop.

Earlier releases treated this as a *safety* problem — fuses, strike counters,
retries. Those helped users recover, but the device was still being
misidentified every single install. V58 fixes the identification itself.

**What changed:**

- **Explicit sibling exclusion, evaluated first.** `ktm` / `plq110` / `op6113` /
  `ace 6` are matched **before** the `sun` test, so Ace 6 can never fall into the
  OP13 reference branch no matter what its fingerprint claims. The same guard
  rail already keeps foreign SM8850 codenames (`macan`, `fairlady`, `15R`,
  `Ace 6T`, `15T`) out of the OP15 branch, and foreign SM8650 codenames out of
  OP12.
- **The generic path never grafts `/odm`.** `system/odm`, `system/vendor/odm` and
  `system/my_product` are hard-removed from the module tree on every
  non-reference device. Whatever the pipeline generates, an `/odm` graft cannot
  reach the mount namespace.
- **Real `/odm` audio is still delivered — as runtime binds.**
  `asb_generate_odm_binds` clones the device's own `/odm` audio and media files
  into `/data/adb/asb/odm_patched/`, patches them, copies the **live SELinux
  context** off each original target, and records a manifest. `post-fs-data.sh`
  replays it with `mount --bind` on the first boot, before zygote. The `/odm`
  partition itself is never modified.
- **The fuse can no longer be defeated.** The boot counter is now flushed with
  `sync` **before** the first bind is applied. Previously a hard early-boot crash
  could lose the cached counter write, turning a recoverable one-strike into a
  permanent loop. A tripped fuse now also clears `odm_patched/`, its manifest,
  and any staged `deferred_overlay`.

**Result:** Ace 6 and Ace 5 boot on the first try, with `asbdiag` reporting PASS
on the audio and media checks.

> **Scope, stated plainly.** Reference devices (OP15 / OP13 / OP12, matched by
> confirmed codename) keep the proven clone-and-patch pipeline and their
> 3-strike guard. Every other OnePlus gets the device-native `/vendor` overlay
> plus `/odm` runtime binds under a **1-strike fuse**: one failed boot tears the
> whole generated overlay out before the module mounts and writes
> `/data/adb/asb/vendor_overlay_blocked`, so the device comes up governor-only
> until that marker is deleted.

---

### 🏷️ The installer now knows which phone it is

Install logs used to say `OnePlus (generic)`. `asb_identify_device` resolves a
real name in three passes:

1. the OPPO/OnePlus retail marketing-name properties
   (`ro.vendor.oplus.market.enname` and friends) — no lookup needed;
2. a model / codename / project / fingerprint table — Ace 6, Ace 5, 15, 13, 13R,
   12, 12R;
3. SoC family (`OnePlus (SM8850 / SM8750 / SM8650)`), then bare model, then a
   safe default.

The resolved name is printed at install and used everywhere the log previously
said "generic".

---

### 🎧 Audio — hi-res that works on every layout, gain that never clips

- **`asb_lift_hires_policy` — format-agnostic.** V57 lifted
  `audio_policy_configuration.xml` with six exact-string `sed` rules. They
  matched OP15's comma-separated lists and silently skipped Ace 6's
  **space-separated** `44100 48000 88200 96000`. The new `awk` lifter walks every
  `samplingRates="…"` attribute and, where the list already reaches `96000` but
  stops short of `384000`, appends the missing hi-res steps
  (`176400 192000 352800 384000`) **in the separator that list already uses**.
  Idempotent, per-device `sed` rules gone, correct on OP15 / OP13 / OP12 / Ace and
  anything future.
- **SoC-aware Digital Volume ceiling.** SM8650 / `pineapple` WCD/WSA
  `Digital Volume` controls top out at **84 = 0 dB unity**; writing the OP15
  value of 88 clips and breaks the speaker path on those devices. The mixer
  patcher now caps at 84 on SM8650 and keeps 88 on `sun` / `canoe`.
- **`RX HPH Mode`** is lifted to `CLS_H_HIFI` from `CLS_H_LOHIFI` as well as from
  `CLS_H_ULP` — the runtime tweak layer previously only handled `ULP`.
- **Diag rewritten to match reality.** `asbdiag` no longer demands the literal
  string `88`. It reports the actual peak `RX/WSA Digital Volume` and fails only
  on an out-of-range value (`>88`, which would break the speaker path) — so the
  correct-and-different SM8650 tuning reads PASS instead of FAIL.

---

### 🎬 Media — bitrate lift by resolution, on the right feature gate

`asb_media_lift_file` replaces bracket-guessing with resolution-aware targets:

| Resolution | Target bitrate |
|:-----------|:---------------|
| 1920×1080 | **37.3 Mbps** (40 Mbps on `canoe`) |
| 3840×2160 | **100 Mbps** |
| 1280×720 | floor of **20 Mbps** |

Lines without an explicit `width`/`height` keep the conservative bracket bump for
back-compatibility, and a lift is never allowed to *lower* a stock bitrate.

The `media_profiles` patch is now gated on **`MEDIA`** rather than `CAMERA` —
`media_profiles.xml` controls video encoder bitrate, not the camera HAL, and
users who switched CAMERA off were silently losing it.

---

### 🌡️ Thermals — the envelope moves 65 °C → 60 °C

Three thresholds move together, so the governor, the Smart veto and the gaming
relax all agree on what "warm" means:

| Setting | V57 | V58 |
|:--------|:---:|:---:|
| `thermal_throttle_temp` (`governor.conf`, `asb_config.h`) | 65 | **60** |
| `ASB_SMART_VETO_CPU_TEMP_C` (`asb_smart_defs.h`) | 65 | **60** |
| Gaming heat-relax trigger (`asb_smart.h`) | `< 65 °C` | **`< 60 °C`** |

> **Trade-off:** this buys lower skin temperature and a calmer sustained curve at
> the cost of some peak clock during long hot sessions. To restore the old
> behaviour, set `thermal_throttle_temp=65` in `governor.conf`.

---

### 🧮 CPU bounds — lag-safe lean for 3- and 4-cluster SoCs

OP15/OP13 are 2-cluster parts, and the synthesized bounds derive from their
ratios. On a 3/4-cluster device (SM8650's 1+3+2+1) those raw ratios pin the
**main interactive cluster** low in battery mode (mid ≈ 41 %, prime ≈ 35 %),
which reads to the user as UI stutter: the scheduler parks interactive work on
the strongest middle cluster and it cannot clock up.

`asb_synthesize_bounds.sh` now leans every interactive cluster's BATTERY and
BALANCED ceiling upward **on >2-cluster devices only** (≈ 62–64 % battery,
≈ 82–86 % balanced; prime 62 / 86 / 92). The field-proven 2-cluster OP15/OP13
ratios are untouched. The direction is deliberately the safe one — a higher cap
can only reduce stutter. The cost is some battery, never smoothness.

---

### 🔒 Privacy — ad-identity actually silenced, and reverted on uninstall

Built from a full-day telemetry log rather than guesswork, and applied through
`device_config` — the namespace GMS actually reads:

```
gms          AdvertisingId__enable_ad_id_reconciliation   false
gms          AdsIdentity__enable_status_service           false
gms          AdsIdentity__enable_mendel_property_update   false
measurement  measurement.service.disable                  true
measurement  measurement.collection.enabled               false
```

- `com.oplus.oidt` joins the OPPO telemetry list.
- **`uninstall.sh` now deletes those `device_config` keys.** Overrides written
  through `device_config` survive module removal; before V58 they persisted
  forever. Removing ASB now genuinely restores the previous state.

---

### 🖥️ Panel LPM + kernel hygiene

- `display_panel_lpm = 1` — the pre-existing value is recorded to
  `tracking_restore.log` before it is touched.
- `subsystem_restart`: `enable_ramdumps` and `enable_mini_ramdumps` → `0`.
- `fs.inotify.max_user_watches = 262144`, `fs.inotify.max_user_instances = 512`.
- `vm.watermark_boost_factor = 0` — stops the kernel over-reclaiming into
  watermark boost on a device that already runs OxygenOS RAM expansion.

---

### 📈 Logkit — two numbers that actually mean something

- **`night(longest)`** — the longest continuous screen-off block of ≥ 3 h,
  reported as its own drain rate. Compare *this* against 0.3–0.7 %/h, not the
  mixed `idle` row that averages in screen-on gaps.
- **screen-off CPU sleep** — realtime vs uptime from `batterystats`, printed as
  `awake %` / `deep sleep %`. Healthy nights sit under 5 % awake; over 15 % means
  something is holding the CPU.

---

### 🩺 Diagnostics — no more false failures

The camera retouch checks (`retouch app count ≥ 7`, `Telegram present`) are
OP15-specific camera-tone content. On models without `conf_tuning_params.json`
they are now reported **N/A** instead of FAIL, so a correctly-tuned Ace 6 no
longer shows red on checks that never applied to it.

---

### 🧾 Housekeeping

Version strings bumped to V58 / `580` across `module.prop`, `action.sh`,
`asb_governor.c` and the three WebUI panels.

---

### ⬆️ Upgrading

Flash over any previous version — saved category choices carry over.

- **Coming from a bootlooping build?** The failed-boot counter persists in
  `/data/adb/asb`, so the fuse trips before the overlay mounts. If a device was
  permanently blocked, delete `/data/adb/asb/vendor_overlay_blocked` to let the
  next install try again.
- **Coming from a broken or partial flash?** A stale module directory can be left
  behind under the manager's overlayfs mount point
  (`…/modules/META-OVERLAYFS/mnt/AutoSystemBoost`). While it is there, *other*
  modules can stop working too. Remove that leftover directory before flashing a
  fresh build.

---

### 📌 Known notes

- `LPM` has no entry in `features.conf`, and `asb_feature_enabled` treats an
  unknown key as *enabled* — so Panel LPM currently always applies and is not
  user-toggleable. Functional, but not yet a real category.
- `cap_verify` can report DESYNC when frequency caps are applied through
  `msm_performance`: the governor publishes `perf_cap_p0/p6=0` while the cap is
  live. This is a **telemetry artefact only** — the cap is applied. Left alone on
  purpose; the fix carries more risk than the cosmetic benefit.

---

## V57 — *network for gamers*

Field telemetry from a full evening-night-day cycle on released V56 confirmed
the big fixes landed: idle drain **1.89 → 0.66 %/h**, active drain **10.1 →
6.4 %/h**, idle SoC peak **63 → 48 °C**, and the vendor-clamp write war fell
from 59% to 24% of ticks — the "boiler" is gone and nights are properly quiet
(7–37 mA in deep idle). V57 builds on that with a scenario-aware network layer
and a few targeted refinements — all within ASB's no-daemons, one-shot,
device-respecting philosophy.

### 🛠️ Ace 6 bootloop (issue #8): patched overlays for everyone, now with a fuse
The V52 "Ace 6 won't boot" bug came back in V55/V56: detection was still correct
(SM8750 siblings like ktm never match the OP13 overlay), but the unified
pipeline generated a device overlay for *every* OnePlus, and Ace 6's
ColorOS-based layout bootlooped on its own generated one — twice in the field.
The philosophy stays: **modifications are applied as patches to the device's
own files at install; ASB now ships ZERO static vendor files** (the last 49
OP15-shaped shipped statics are gone from the tree — they were being stripped
and regenerated on every supported device anyway). What changes is the safety
model on non-reference devices:
- Reference families (OnePlus 15 / 13 / 12 by confirmed codename) keep the
  proven pipeline and the 3-strike boot guard.
- Every other OnePlus still gets the full device-native patched overlay, but
  under a **1-strike boot fuse**: a single failed boot tears the whole
  generated overlay out before the module mounts (manifest replay + category
  sweep) and writes a persistent `/data/adb/asb/vendor_overlay_blocked`, so
  that device — and every future install on it — comes up governor-only until
  the user deliberately deletes the marker to retry. One bounce maximum,
  self-healing, remembered across updates.
- Upgrading straight from a bootlooping V55/V56 is clean: the failed-boot
  counter persisted in `/data/adb/asb`, so the very first V57 boot trips the
  fuse **before** the overlay ever mounts — zero bounces.
The old guard needed three failed boots and forgot everything on reinstall;
a hang (rather than a crash-loop) could defeat it entirely. The fuse fixes both.

### 🌐 TCP: scenario-aware — power-saving in sleep, low latency in games
ASB's network stack was already extensive; V57 fills the remaining gaps **and
makes the additions scenario-dependent**, riding ASB's per-profile network
engine (values re-apply on every profile change and on Smart's own internal
shifts):
- **Thin-stream retransmit mode** (`tcp_thin_linear_timeouts`/`tcp_thin_dupack`)
  — thin streams are exactly the small-packet flows of online games, so linear
  recovery cuts lag spikes after a lost packet. Enabled in balanced and
  performance; **disabled in battery**, where push connections are the thin
  streams and exponential backoff lets the radio sleep between retries.
- **`tcp_rto_max` per scenario**: 8 s in performance (fastest stall recovery for
  gaming), 15 s in balanced, kernel-default 120 s in battery so a stalled
  connection backs off instead of re-waking the modem all night.
- **Smart follows the day**: when Smart's learned battery-bias crosses into
  battery territory (α ≥ 0.8 — nights, low battery), the reconcile loop applies
  the full battery network set (5-hour keepalives, thin-stream off, small NAPI
  budgets) and restores the balanced set when the device wakes back up. Gaming
  under Smart keeps the low-latency set (the gaming heat-relax clamps α ≤ 0.4).
- **`tcp_mem` set dynamically** from the device's RAM (3% / 6% / 10% of pages)
  and the new **PLB** sysctls enabled where the kernel supports them — these two
  are scenario-independent by nature and stay static.
All one-shot guarded writes — no qdisc-watchdog or per-interface monitoring
daemons: a permanent polling loop would contradict the standby work that just
got idle drain to 0.66 %/h.

### 🎛️ Device-Adaptive Bounds toggle removed from the WebUI
Everything is decided at install now, so the toggle had no job left: the
installer sets `device_bounds_override` device-aware (ON on the OP15, where the
synthesized values equal the shipped hand-validated tuning; OFF elsewhere,
where OP15-derived ratios can under-clock UI clusters — the V55 OP12 lag),
the config carry-over deliberately never migrates it, and stale saved values
are scrubbed on upgrade. The WebUI writes config per-key, so removing the
control means the installer's choice simply persists. Power users can still
flip it by editing `governor.conf` directly.

### 🧠 Swappiness that actually sticks on OxygenOS
OxygenOS carries its own swappiness scene props
(`sys.mem.swappiness_on_launcher`, `sys.mem.swappiness_on_start`,
`sys.sysctl.swappiness`) and can re-assert them over `vm.swappiness`. ASB's
per-profile swappiness is now mirrored into those props — but only when they
already exist on the device, so nothing new is created on ROMs that don't use
them. A boot-time zram resize was deliberately avoided: it would fight
OxygenOS's own RAM-expansion management, which ASB already handles.
