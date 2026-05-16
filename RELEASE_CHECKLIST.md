# ASB Release Checklist

Every public release of ASB (any `V{N}` or `V{N}r{m}`) must pass every item in this checklist before publishing. If any item fails, fix or downgrade scope to prerelease.

This document is short on purpose. The point is **not to skip**, not to be exhaustive.

---

## 1. Build & static gates

- [ ] `gcc -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -c src/asb_governor.c` exits 0 with **zero warnings**
- [ ] All shell scripts pass `bash -n` (run for `find . -type f -name "*.sh" -not -path "./META-INF/*"`)
- [ ] `bin/arm64-v8a/asb` exists and is a fresh build matching current C source
- [ ] `tools/asb_lint.sh` (if present) exits 0 — checks `.sh` profile values against `g_profile_bounds` in `asb_fsm.h`

## 2. Version sync

- [ ] `module.prop:version` == `update.json:version` == `CHANGELOG.md` top heading
- [ ] `module.prop:versionCode` == `update.json:versionCode`
- [ ] `update.json:zipUrl` points to the actual GitHub release tag for this version
- [ ] `common/install.sh` `build_manifest.json` `schema_version` matches `service.sh` `_expected_schema`

## 3. Categories sync (14 categories: AUDIO, BT, CAMERA, CPU, VM, NET, WIFI, GPS, KERNEL, LOG, RADIO_IMS, DISPLAY, FPS, SECURITY)

- [ ] `common/install.sh` `ASB_*=true` defaults — all 14 present
- [ ] `common/install.sh` `asb_choose_cat` calls — all 14 in the same order
- [ ] `common/install.sh` `features.conf` template — all 14 keys
- [ ] `common/install.sh` `asb_prune_module` for-loop — all 14
- [ ] `common/russiantext.sh` `ASB_MENU_*` — all 14 strings present
- [ ] `common/englishtext.sh` `ASB_MENU_*` — all 14 strings present
- [ ] `features.conf` (default file in archive) — all 14 keys = 1

## 4. Section block integrity

For each category that emits a `# ASB:<CAT>:BEGIN/END` block:

- [ ] `system.prop` has matched BEGIN/END markers
- [ ] `service.sh` has matched BEGIN/END markers (if category needs runtime apply)
- [ ] `post-fs-data.sh` has matched BEGIN/END markers (if category needs early setprop)
- [ ] Stripping the block via the install-time `sedi` does **not** leave orphan function references
- [ ] Apply function (`apply_<cat>_runtime`) is fully contained inside the block

## 5. Profile bounds

- [ ] All 3 profiles `floor.cpu_max <= ceil.cpu_max` (LITTLE and BIG)
- [ ] All 3 profiles `floor.gpu_max_pct <= ceil.gpu_max_pct`
- [ ] `g_profile_bounds[]` in `src/asb_fsm.h` matches `profiles/*.sh` CPU_CAP/CPU_MAX/GPU_MAX_PCT for all 3
- [ ] `floor.cpu_max == CPU_CAP` and `ceil.cpu_max == CPU_MAX` per profile (uniform semantic)

## 6. Auto-battery persistence (V42+)

- [ ] Every line in `asb_governor.c` that mutates `fsm.auto_battery_active` or `fsm.auto_battery_restore_idx` is followed (within 5 lines) by `fsm_auto_battery_persist(&fsm)`
- [ ] `fsm_init()` in `asb_fsm.h` reads `/dev/.asb/auto_battery_state` and validates `restore_idx ∈ {1, 2}`
- [ ] `uninstall.sh` removes `/dev/.asb` (covers state file)

## 7. IPC `:auto` flag (V42+)

- [ ] `apply_profile.sh` parses second arg as `PROFILE_FLAG` in both direct and worker modes
- [ ] `notify_governor()` appends `:auto` to IPC when `PROFILE_FLAG=auto`
- [ ] C-side `profile:` IPC handler parses trailing `:auto` and sets `_is_auto`
- [ ] `_pbuf` size in IPC handler accommodates longest profile name + NUL (`performance` = 11 + 1)
- [ ] User-manual switches (no `:auto`) clear `auto_battery_active`; auto-switches do not

## 8. Schema migration

- [ ] `service.sh` `asb_migrate_governor_conf` is **additive** (keeps user values, only adds missing keys)
- [ ] `common/install.sh` writes `config/.schema_version=<N>` matching `_expected_schema`
- [ ] `governor.conf.shipped` is copied from `governor.conf` at install time (sealed reference)

## 9. Functional smoke test (on target device — OnePlus 15 SM8850)

Install on a device with fresh module slot. Reboot. Then verify:

- [ ] **VoLTE** — make and receive a TIM Italy call. Audio both directions, no dropout.
- [ ] **VoWiFi** — disable cellular, connect to Wi-Fi, make call. Same.
- [ ] **Bluetooth** — pair OnePlus Buds Pro 3, verify LHDC codec in developer options
- [ ] **Camera** — open stock camera, take photo, record 30s 4K60 video, playback OK
- [ ] **GPS** — open offline map app, verify lock within 30s outdoors
- [ ] **AUDIO category** — play music via internal speaker (5 min), verify no glitches, no clipping. Switch to Bluetooth, verify reconnect mute does not occur (V42-fixed adds `ro.audio.bt.connect.disable.mute=true`)

## 10. Profile smoke test

For each of `battery`, `balanced`, `performance`:

- [ ] Switch via WebUI or `apply_profile.sh <profile>`
- [ ] Within 10s, `/dev/.asb/state` shows `profile=<expected>`
- [ ] Within 30s, `scaling_max_freq` settles to values that match the profile (battery: ~614-1132 MHz, balanced: 1190-3302 MHz, performance: 2304-3628 MHz on LITTLE; values per-state)
- [ ] No bootloop. Reboot once with each profile active.

## 11. Logkit captures (target device)

Run all three logkit scenarios, each at least 5 minutes:

- [ ] `tools/logkit/asb_log_battery_mixed.sh` — produces full output dir with `cap_source_summary.txt`, `perf_trace.txt`, `cap_verify.txt`, `session_history.jsonl`, `_slice_info.txt`
- [ ] `tools/logkit/asb_log_battery_sleep.sh` — same files
- [ ] `tools/logkit/asb_log_perf.sh` — same files + populated `battery_trace.txt`
- [ ] Each `cap_source_summary.txt` shows realistic distribution (no 100% `policy_unknown` or `mismatch`)
- [ ] Each `session_history.jsonl` line has `"v":9` and parses as valid JSON

## 12. Auto-battery deploy test (optional, if changes to auto-battery)

- [ ] Set `auto_battery_enable=1` in `governor.conf`
- [ ] On `balanced` profile, drain battery below threshold (default 20%)
- [ ] Verify `apply_profile.sh battery auto` was called (in `asb_log`)
- [ ] Verify `/dev/.asb/auto_battery_state` contains `1 1` (active=1, restore_idx=balanced)
- [ ] Charge above 30%, verify restore to `balanced` (state file becomes `0 -1`)
- [ ] Repeat but manually switch profile while in low-battery — auto state should clear, no restore

## 13. Documentation

- [ ] `CHANGELOG.md` has section for this release at top
- [ ] `docs/log_schemas.md` updated if any log field changed
- [ ] If schema bumped: schema version history table in `docs/log_schemas.md` has new row
- [ ] `README.md` reflects current version badge

## 14. Packaging

- [ ] Zip created and sized reasonably (V42 = ~2.3MB with vendor overlay, ~1.4MB without)
- [ ] `META-INF/com/google/android/update-binary` and `updater-script` are present
- [ ] Zip installs cleanly in KernelSU/Magisk on a real device (not just emulator)
- [ ] First boot completes within 60s after install
- [ ] No SELinux denials in `dmesg` post-boot related to ASB paths

---

## Sign-off

Releaser: ___________________  
Date: ___________________  
Version: ___________________  
Device tested: OnePlus 15 (CPH2745, canoe) on OxygenOS 16  
All boxes checked: ___________________
