# ASB DSP — AIDL port (libasbdsp_aidl.so)

This is the AIDL replacement for the legacy `libasbdsp.so`. It exists because on
Android 13+ (your OxygenOS 16 / SM8850) audioserver loads effects through the
`android.hardware.audio.effect` **AIDL** contract, not the legacy
`AUDIO_EFFECT_LIBRARY_INFO_SYM` path. A legacy `.so` in a v2.0
`audio_effects_config.xml` is never bound to the stream — which is exactly why
`dsp_loudness=+18 dB` produced no audible change.

## Two bugs this port fixes

1. **Wrong ABI.** The old lib exported the legacy HAL symbol; the AIDL factory
   dlsym's `createEffect` / `queryEffect` / `destroyEffect`. Those are now
   implemented in `asb_effect_aidl.cpp`.
2. **Missing `type` UUID.** The old registration wrote
   `<effect name="asb_loudness" library="asbdsp" uuid="..."/>` with **no `type`**.
   The AIDL factory matches effects to streams by `type` UUID, so a typeless
   effect is ignored. `install.sh` now writes both `uuid` and `type` (constants
   `ASB_DSP_UUID` / `ASB_DSP_TYPE`, byte-identical to the C++ UUIDs).

## The DSP math is unchanged

`asb_dsp_core.h` is the loudness engine (soft-knee compressor + auto make-up +
true-peak limiter + make-up gain) lifted verbatim from `../DSP/asb_dsp.c`. Both the
legacy effect and this AIDL wrapper share it, so loudness is identical. It reads the
same `persist.asb.dsp.*` properties the WebUI already writes, so no runtime/UI
change is needed.

## Building — this needs soong, not plain NDK

The effect AIDL stubs (`android.hardware.audio.effect-V2-ndk`) and the FMQ headers
(`libfmq`, `AidlMessageQueue.h`) ship with the **AOSP tree**, not the standalone
NDK. `src/build_ndk_release.sh` builds the *legacy* `.so` with plain
`aarch64-linux-android-clang` — that toolchain cannot resolve the AIDL/binder
headers, so it can **not** build this file. Build it one of these ways:

- In an AOSP checkout: drop this folder under e.g.
  `vendor/asb/libasbdsp_aidl/`, then `mm libasbdsp_aidl` (uses `Android.bp`).
- Or add a soong step to CI that has the effect-AIDL + libfmq prebuilts available.

## Building on GitHub Actions

`.github/workflows/build-dsp-aidl.yml` builds this on a GitHub runner by bringing up a
**minimal** AOSP/soong tree (only the projects in `manifest/asb_aidl_min.xml`), then
running `m libasbdsp_aidl`. Trigger it manually from the Actions tab
(workflow_dispatch); it uploads `libasbdsp_aidl.so` for both ABIs as an artifact.

Read these caveats first — they are real, not boilerplate:

- **GitHub does not provide a soong environment.** The workflow syncs and bootstraps one.
  A full AOSP tree is ~200 GB and will not fit; the minimal manifest keeps it small, but
  soong resolves link deps at build time, so the **first runs may fail on a missing
  module**. The build log names it; find its git project on https://cs.android.com, add a
  `<project>` line to `manifest/asb_aidl_min.xml`, re-run. Budget 1–3 iterations. This is
  expected for a from-scratch bring-up, not a sign the port is wrong.
- **Disk is the binding constraint.** The free runner has ~14 GB free; the workflow's
  cleanup step reclaims ~25–30 GB more. The minimal tree + clang toolchain + `out/` is on
  the edge. If you hit "no space left on device", move `runs-on:` to a larger or
  self-hosted runner with 120 GB+ free — that is the reliable path.
- **The manifest pins Android 15** (`android-15.0.0_r1`), matching the
  `audio.effect-V2` / `audio.common.types-V3` surface this module targets. Change the tag
  (workflow input + manifest revision together) if your platform differs.

Once the artifact is produced, drop the two `.so` files into
`prebuilt/arm64-v8a/` and `prebuilt/armeabi-v7a/`, then run the release build with
`ASB_DSP_AIDL=1` so `build_ndk_release.sh` picks them up.

Then drop the soong output into the prebuilt folders and build the release with the
opt-in flag:

    src/DSP_AIDL/prebuilt/arm64-v8a/libasbdsp_aidl.so
    src/DSP_AIDL/prebuilt/armeabi-v7a/libasbdsp_aidl.so
    ASB_DSP_AIDL=1 bash src/build_ndk_release.sh

With `ASB_DSP_AIDL=1`, build_ndk_release.sh skips the legacy compile, copies the
prebuilt AIDL `.so` to `bin/<abi>/libasbdsp.so` (the on-disk name the installer
registers) and verifies the `createEffect` factory symbol instead of `AELI`.

Without the flag (the CI default) nothing changes: the legacy `libasbdsp.so` is
built from `../DSP/asb_dsp.c` exactly as before. Nothing in post-fs-data.sh,
asb_audio_apply.sh or the workflow YAML needs editing — they key off the on-disk
`libasbdsp.so` filename and the `persist.asb.dsp.*` properties, both unchanged.

## Status / testing

The core math is unit-verified on the build host (+18 dB → ×7.94 linear gain, quiet
input measurably lifted, limiter holds the ceiling, gain=0 → bypass). The AIDL
binder wrapper is written against the documented contract but **must be validated on
device** — build it, install, play music, and confirm the level rises with the
slider without opening any EQ app. If audioserver rejects it, `logcat -s
AudioFlinger AudioPolicyEffects EffectFactory` at boot is the log to capture.
