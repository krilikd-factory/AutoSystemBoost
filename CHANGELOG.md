# AutoSystemBoost — Changelog

## V58 (versionCode 580)

**Headline: full, verified support for additional OnePlus models.** Up to now the
device-native overlay was validated mainly on the OnePlus 15 reference. This
release generalises the whole pipeline so OnePlus 13 / 12, OnePlus Ace 6 and
OnePlus Ace 5 build a correct, device-native overlay from their *own* stock files
and pass diagnostics — while keeping the OP15 daily-driver behaviour untouched.

Everything below was derived from real on-device stock files, install logs and
full-day battery/thermal captures, not guesswork.

---

### Multi-device support

- **Device self-identification at install.** The installer now resolves the real
  marketing name (via `ro.vendor.oplus.market.*`, with a model/codename/project
  fallback table) and prints it — e.g. `Device identified: OnePlus Ace 6` — instead
  of the confusing generic “OnePlus (generic)” / bare “OP15” wording. The “OP15”
  label now only appears where it honestly describes the *tuning source* (the sound
  profile is portable from OP15), not the device.

- **OnePlus Ace 6 (SM8750 sibling).** Fixes the four things that used to read stock
  on this model:
  - **Wi-Fi:** nested-only WCNSS layouts (`kiwi_v2/`, `peach/`, `peach_v2/` with no
    top-level file) are now detected via bounded shell globs and patched. The old
    `ls glob glob` guard skipped them entirely, and a recursive `find` variant could
    stall on `/vendor/odm` bind-mount loops — both fixed.
  - **Audio HPH Mode:** promotion to `CLS_H_HIFI` now covers the whole Class-H family
    (`ULP / LOHIFI / LP / NORMAL`) instead of only ULP/LOHIFI, leaving the dedicated
    `CLS_AB` path untouched.
  - **Hi-res + 1080p:** now landed (see below).

- **OnePlus Ace 5 (SM8650 / pineapple).**
  - **Speaker-volume regression fixed.** On this codec the WCD/WSA “Digital Volume”
    controls top out at 0 dB = 84; writing 88 put the speaker path out of range so the
    framework slider stopped attenuating (speaker at full, and BT volume knocked out).
    The digital-gain ceiling is now device-gated: **84 on SM8650/pineapple, 88
    elsewhere.**
  - **Battery-mode lag reduced.** On the 1+3+2+1 topology the primary interactive
    cluster was pinned low by the OP15-shaped rails. The per-device bound synthesis now
    leans the interactive-cluster BATTERY/BALANCED ceilings up (lag-safe direction),
    snapped to this device’s real frequency steps; the 2-cluster OP15/OP13 path is
    unchanged.

- **OnePlus 13 / 12** continue to build the device-native overlay from their own
  `sku_*` trees.

### Overlay activation — one reboot, bootloop-safe

- The files diagnostics read (mixer `mixer_paths_*_cdp.xml`, `media_profiles.xml`,
  hi-res `audio_policy_configuration.xml`) all live under `/vendor/etc` and now
  activate via the standard **`/vendor` magic-mount overlay — one reboot, exactly
  like OP15**, with the correct SELinux context.
- The Ace 6 hard-bootloop was traced to grafting **`/odm`** content into the
  magic-mount tree (`/odm` is a bind-mount of another partition on these devices and
  breaks early boot before the fuse can run). Every `/odm` graft is now **hard-removed**;
  real `/odm` audio is delivered instead by **fuse-guarded runtime binds** in
  `post-fs-data`, where the boot counter is `sync`-flushed to disk *before* any bind —
  so a bad file can only ever cost one recoverable boot, never a loop.

### Audio

- **Format-agnostic hi-res lifter** (`asb_lift_hires_policy`). For any
  `samplingRates="…"` list that already reaches 96000 but stops short of 384000, it
  appends the missing hi-res steps using the list’s *own* separator — comma **or**
  space. Replaces a pile of exact-string seds that silently missed Ace 6’s
  space-separated `"44100 48000 88200 96000"` format. Applied to both the `/vendor`
  overlay and the `/odm` runtime bind; idempotent.
- Device-gated digital-volume ceiling and Class-H HPH promotion (see per-device notes).

### Media / Wi-Fi / camera

- **1080p video bitrate lift** is now gated on the **media** category (was camera), so
  it lands on devices where camera-tone tuning is correctly left stock. Covers the
  `/vendor/etc/media_profiles*.xml` the framework reads.
- **Wi-Fi** clone is minimal (only the patched `WCNSS_qcom_cfg*.ini` files) and never
  walks the full `/vendor/etc/wifi` tree — no stalls on firmware blobs or bind loops.
- Camera video_beauty `//` on the `/odm` tree is intentionally left stock on models
  where that path is not safely reachable at install (a benign JSON5 comment the
  camera HAL accepts); all functional camera/media patches apply normally.

### OnePlus 15 — thermals & battery

- **Gaming thermal engage lowered 65 °C → 60 °C.** A full-day log showed gaming
  peaking at 64 °C — one degree under the old engage point — so the proactive lean
  (GPU ceiling −18 %, stop the gaming battery-relax) never fired and all clamping was
  left to the vendor’s reactive loop. 60 °C catches the ramp; normal active bursts
  (which peak ~58 °C) are unaffected.
- **Standby:** `com.oplus.oidt` (OPPO diagnostic hourly-timer, a recurring idle
  wakeup source in the logs) added to the `rare` standby bucket, alongside the
  existing GMS activity-recognition / location-throttle tuning.

### Robustness (install)

- Recursive live-filesystem walks are depth-bounded and the risky ones timeout-guarded,
  so a stalled or bind-looping mount can no longer hang the installer.
- Per-stage progress checkpoints in the device-native and odm-bind phases make any
  future stall self-locating from the flash log.

### Unchanged / preserved

- Ad-identity & measurement silencing in `apply_tracking_block`, and its clean revert
  on uninstall (`device_config` reset), are preserved.
- The OnePlus 15 reference path is behaviourally unchanged.

---

> **Note for KernelSU Next users:** if a *previous* broken build left a stale folder at
> `/data/adb/modules/meta-overlayfs/mnt/AutoSystemBoost`, remove it (or reinstall
> cleanly) before flashing — a leftover there can break this and other modules’ mounts.
