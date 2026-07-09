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
  <img src="https://img.shields.io/badge/Ace%206-ktm%20·%20fully%20supported-22c55e?style=flat-square" alt="Ace 6">
  <img src="https://img.shields.io/badge/Ace%205-fully%20supported-22c55e?style=flat-square" alt="Ace 5">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V58 — *full support for the Ace family*

The headline is simple: **Ace 6 and Ace 5 are now fully supported — the same
tuning pipeline as the OnePlus 13 and 12, `asbdiag` PASS, first-boot clean.**

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
on the audio and media checks. They are no longer "compatibility mode" devices:
both run the **same `asb_apply_device_native_tuning` pipeline** as the OnePlus 13
and 12 — identical audio, camera, media, GPS, perf and Wi-Fi stages, built from
their own stock files. Ace 5 additionally gets device-adaptive CPU bounds enabled
by default (the SM8650 interactive-cluster lean); on Ace 6 they stay opt-in via
the WebUI. The only structural differences left are *how* `/odm` is delivered
(runtime binds instead of a magic-mount overlay) and the stricter 1-strike fuse.

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
