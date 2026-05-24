# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V45-16a34a?style=for-the-badge" alt="V45">
  <img src="https://img.shields.io/badge/Previous-V44-6b7280?style=for-the-badge" alt="V44">
  <img src="https://img.shields.io/badge/versionCode-450-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## ⚡ V45 — Critical Bug Fixes + Field-Tuned Profiles

### 🐛 Critical bug #1 — Module card description stuck on "balanced"

**Reported by primary user with V44 battery-mixed deploy log.** The KSU/Magisk manager card displayed `status: balanced ⚖️ | active ✅` for an entire 81-minute battery session, despite the FSM correctly running the `battery` profile (verified in snapshots: `"profile":"battery"`, `"cap_source_p0":"shell_overridden_down"`, `"ses_max_temp":58°C`).

A follow-up report described a related race condition: when manually switching from `balanced` to `battery` via WebUI, the card briefly showed `battery` then reverted to `balanced` within seconds — while WebUI itself, `asb status` from termux, and the FSM all correctly showed `battery`.

**Root cause:** two layered issues.

First, `service.sh` never called `asb_update_desc` during boot. The function is defined in `runtime/profile_core.sh` and sourced at service.sh:21, but was invoked only by `apply_profile.sh` worker (on user-initiated switch), `runtime/asb_reconcile.sh` (only on `profile-change` / `screen-state` / `drift` reasons), and `runtime/profile_core.sh:asb_apply_profile_once` (called by `apply_runtime_profile_now()` which was never invoked from service.sh boot path). So on every reboot where the active profile was the same as last boot — the common case for daily users — description stayed at install-time default `balanced` until the user manually switched profile.

Second, `asb_update_desc` had **three different implementations** across the codebase (`runtime/profile_core.sh`, `runtime/asb_utils.sh`, `apply_profile.sh`). Two used `$PROFILE` shell variable as the source of truth, one used `cat "$MODDIR/current_profile"`. Because `service.sh` sourced `asb_utils.sh` first and then `profile_core.sh`, the second sourcing **overrode** the first's `asb_update_desc` definition. In the reconcile background subshell, `$PROFILE` could become stale or empty between loop iterations, causing the `*` default case (`balanced`) to fire — overwriting the correct description that a recent profile switch had just written.

**Fix:**

1. Added explicit `asb_update_desc` call in `service.sh` right after `asb_load_profile`:

   ```sh
   command -v asb_update_desc >/dev/null 2>&1 && asb_update_desc 2>/dev/null
   ```

   Now the module card shows the correct profile from the first second of boot.

2. Both `asb_update_desc` definitions in `runtime/profile_core.sh` and `runtime/asb_utils.sh` now read profile from the file (`cat "$MODDIR/current_profile"`) — a single source of truth instead of a shell variable that varies by subshell context. The fallback in `apply_profile.sh` takes the profile as an explicit argument.

After V45, the card description always matches the FSM-active profile regardless of how the profile was set (boot-time persistence, manual switch via WebUI, action.sh, or auto-battery), and stays correct across reconcile loop iterations.

### 🐛 Critical bug #2 — Installer wiping `/data/local/tmp` contents

**Reported by user keeping `targetlist.json` in `/data/local/tmp` for another module.** ASB's installer was silently deleting their file on every install/upgrade.

**Root cause:** `common/install.sh` line 1335 (in the LOG category cleanup block):

```sh
if [ "${ASB_LOG}" = "true" ]; then
  ...
  rm -rf /data/local/*trace*/*
  rm -rf /data/local/*tmp*/*   # ← this line wipes /data/local/tmp/* entirely
  rm -rf /data/mlog/*
  ...
fi
```

`/data/local/tmp` is the standard Android testing and development directory. Users keep all kinds of legitimate files there:
- Module configs from other Magisk/KSU modules (the reporting user's `targetlist.json`)
- adb-pushed scripts and binaries
- Custom configs from other system utilities
- Test artifacts from rooted-device development workflows

ASB had no business deleting that directory. The line was added during early development thinking it was a "log-like" temp directory — that assumption was wrong. The wildcard `/data/local/*tmp*/*` would also have matched any user directory named `tmpcache`, `tmpstore`, etc.

**Fix:** removed the line entirely. LOG=1 no longer touches `/data/local/tmp` in any form. A comment in `install.sh` now documents why this line must never be re-added.

**Workaround for users hit before V45:** files in `/data/local/tmp` deleted by previous installs cannot be recovered (no backup was taken). Affected users should reinstall their module configs.

This was a real data-loss bug that affected real users. The fix is one line removed, but the lesson is bigger — installer cleanup operations need explicit allowlists, not wildcards.

### 🐛 Critical bug #3 — Audio enhancement causing stereo widening with weak center

**Reported by user:**

> "меня еще смутила у тебя улучшалка аудио, она почему-то звук прям сильно в сайд уводит, в центре слабо все начинает играть"

**Root cause:** three properties were collectively responsible:

1. **`audio.matrix.limiter.enable=false` + `vendor.audio.matrix.limiter.enable=false`** in `apply_audio_runtime()` (service.sh) — matrix limiter is the Qualcomm HAL component that balances L/R/Center channels and applies dynamic range compression to keep center channel audible. Disabling it widens the stereo image at the cost of center channel strength — exactly what the user described. The default is enabled for a reason; ASB had no business turning it off.

2. **`ro.audio.audiozoom=true`** in `system.prop` AUDIO block — Qualcomm AudioZoom is intentional stereo widening for media playback. It's a vendor enhancement for users who want a wider soundstage, but it's not appropriate as an unconditional default because it shifts the mix away from how mastering engineers intended.

3. **`persist.bluetooth.spatial_audio_support=true`** in `apply_bt_runtime()` (BT category) — spatial audio on TWS earbuds requires head-tracking hardware to work correctly. Without it, the spatial processing produces stereo imbalance similar to the matrix.limiter issue: wide perceptual image, weakened phantom center. On Pixel Buds Pro 2 with head-tracking this works; on most other TWS it just sounds wrong.

**Fix:**

- **Matrix limiter writes** removed entirely. Qualcomm HAL default (enabled) restored. No code path in V45 disables matrix limiter.
- **AudioZoom** removed from `system.prop` AUDIO block. Stock vendor default restored.
- **BT spatial audio** moved from default BT runtime to `AUDIO_AGGRESSIVE=1` opt-in. Users with head-tracking-capable TWS who specifically want spatial audio can enable it; default behaviour leaves BT audio path untouched.

After V45, the VoIP-safe core in `apply_audio_runtime()` is down to **5 props**: `persist.audio.hifi.int_codec`, `persist.vendor.audio.hifi.int_codec`, `ro.audio.bt.connect.disable.mute`, `persist.vendor.audio.aec_ref.enable`, `vendor.audio.feature.aec_ref.enable`. None alter stereo balance. The aggressive layer (`AUDIO_AGGRESSIVE=1`) keeps the UHQA + hifi flags + offload tuning for users who explicitly want them.

### 🐛 Critical bug #4 — system_server deadlock on OnePlus Ace 5

**Reported by a OnePlus Ace 5 user (SM8635 Snapdragon 8s Gen 3, OxygenOS 16.0.7.200) running ASB V44 under SukiSU.** The reproduction is detailed and unambiguous:

> "v44 ломает system_server. cacheoptimizer кидает сервер в лок, а Athena и COSA пытаются его запустить, по итогу ЦПУ долбится в 100%. Я еле нашёл виновника — снимал лок через adb, смотрел в htop. Athena, COSA и ещё какой-то сервис долбят system_server, а system_server рушит CachedAppOptimizer. Потом system_server лихорадочно пытается запустить athena_optimize, а он в локе из-за CachedAppOptimizer. В htop процессов system просто дохулиард. По UID — это SukiSU. Снимаю лог с SukiSU — там модуль ASB циклично создаёт процессы system. Отключаю (не удаляю) — лаги на месте. Удаляю и чищу папку через рут — идеально всё работает."

**Root cause:** `service.sh:asb_bg_trim_oplus_tune()` in V44 set four persistent Oplus properties:

```sh
asb_persist_safe persist.sys.oplus.athena.reclaim_enable 1
asb_persist_safe persist.sys.oplus.athena.force_kill 0
asb_persist_safe persist.sys.oplus.athena.limit_count 120
asb_persist_safe persist.sys.oplus.deepthinker.reclaim_hint 1
```

On OnePlus 15 (SM8850 Snapdragon 8 Elite Gen 5), these activate older Athena code paths that work standalone. On OnePlus Ace 5 with OxygenOS 16.0.7.200, Athena's `reclaim_enable=1` triggers a newer reclaim daemon that calls into `system_server`'s `CachedAppOptimizer` API. Simultaneously, COSA (ColorOS adaptive auto-tuning) also queries `CachedAppOptimizer` for its own memory management. Both services compete for the same kernel cgroup write path, deadlocking `system_server`. The kernel respawns `athena_optimize` in a tight loop — 100% CPU on all eight cores, device unusable.

**Why disabling the module didn't help the user:** ASB used `asb_persist_safe` (V44 baseline-tracking) to set these. The wrapper writes to `/data/property/persist.sys.oplus.athena.*` files which survive across reboots AND survive module disable. The persist filesystem is independent of which modules are mounted. Only `resetprop --delete` or manual deletion of the files in `/data/property` removes them.

**V45 fix — three layers:**

1. **Removed the offending writes.** `asb_bg_trim_oplus_tune()` is now a no-op stub with a long comment explaining why the props were removed. memcg cgroup writes in `asb_bg_trim_apply_memcg` cover the same memory-reclaim use case via standard Linux APIs — no vendor daemon involvement, works on all OnePlus devices, no deadlock potential.

2. **One-shot cleanup on first boot of V45.** `service.sh` runs a guarded cleanup early in boot, before any background daemons spawn:

   ```sh
   if [ ! -f /data/adb/asb_v45_cleanup_done ]; then
     for _stale_p in \
         persist.sys.oplus.athena.reclaim_enable \
         persist.sys.oplus.athena.force_kill \
         persist.sys.oplus.athena.limit_count \
         persist.sys.oplus.deepthinker.reclaim_hint \
         ro.audio.audiozoom \
         persist.bluetooth.spatial_audio_support; do
       [ -n "$(getprop "$_stale_p" 2>/dev/null)" ] && resetprop --delete "$_stale_p"
     done
     touch /data/adb/asb_v45_cleanup_done
   fi
   ```

   Marker file prevents repeated work. Loop also catches the V44 audio widening props from bug #3 — single cleanup pass handles both regressions.

3. **Lint regression guards.** Three new rules in `tools/asb_lint.sh`:
   - Athena/COSA persist writes must not appear in service.sh non-comment lines
   - matrix.limiter disable / audiozoom enable must not appear in service.sh
   - matrix.limiter / audiozoom defaults must not appear in system.prop

   If any future version accidentally reintroduces these, lint fails before the build is packaged.

**`uninstall.sh` extension:** even though `asb_baseline_replay` should restore the props via the baseline file, V45's uninstall now also runs `resetprop --delete` on the six problematic props unconditionally — handles edge cases where baseline file was corrupted, deleted, or never captured the original value.

**Lesson:** vendor-specific tweaks (Athena, COSA, vendor.oplus.*) are dangerous across device families. Oplus changes these between ColorOS/OxygenOS releases. Standard Linux APIs (cgroup, settings, sysfs) are safer because they're identical on all Android devices.

### 🛡 Baseline tracking completion — 100% coverage

V44 introduced `runtime/asb_baseline.sh` with `asb_settings_put`, `asb_persist_safe`, and `asb_pm_disable` wrappers that capture original Android values before ASB modifies them, so `uninstall.sh` can replay the originals. V44 migrated 42 `settings put global` calls — that part was complete. But:

- **`setprop persist.*` calls** — 40 of them in service.sh, **none** baseline-tracked in V44
- **`pm disable-user` calls** — only 2 of 4 baseline-tracked

After V45 migration:

| Category | V44 raw | V44 tracked | V45 raw | V45 tracked |
|---|---:|---:|---:|---:|
| `settings put` | 2 (fallback) | 42 | 2 (fallback) | 42 |
| `setprop persist.*` | 40 | 0 | 0 | 36 |
| `pm disable-user` | 2 | 2 | 2 (fallback) | 4 |

The 4 remaining raw calls are all inside explicit `if asb_*_safe; then ... else fallback fi` blocks for the edge case where the helper isn't sourced yet (early boot before module helpers load).

**Coverage breakdown of new V45 baseline tracking:**

- **WLAN tuning:** `persist.vendor.wlan.scan_throttle`, `persist.vendor.wlan.powersave` (per-profile values, screen-on vs screen-off variants)
- **Audio VoIP-safe core:** `persist.audio.hifi.int_codec`, `persist.vendor.audio.hifi.int_codec`, `persist.vendor.audio.aec_ref.enable`
- **Audio aggressive (when AUDIO_AGGRESSIVE=1):** `persist.audio.hifi`, `persist.vendor.audio.hifi`, `persist.audio.uhqa`, `persist.vendor.audio.uhqa`, `persist.vendor.audio.power.save.setting`
- **Bluetooth audio stack:** `persist.bluetooth.a2dp_offload.disabled`, `persist.vendor.bluetooth.a2dp_offload.disabled`, `persist.bluetooth.a2dp.optional_codecs_enabled`, `persist.bluetooth.leaudio.enabled`, `persist.vendor.bt.enable.swb`, `persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled`, `persist.vendor.qcom.bluetooth.leaudio.enable`
- **Camera enhancements:** `persist.camera.tnr.preview`, `persist.camera.tnr.video`, `persist.vendor.camera.hdr.enable`, `persist.vendor.camera.video.hdr.enable`, `persist.vendor.camera.eis.enable`, `persist.vendor.camera.video.4k60.eis.enable`
- **Log size reduction (LOG category):** `persist.logd.size`, `persist.logd.size.radio`, `persist.logd.size.system`, `persist.logd.size.crash`, `persist.logd.size.kernel`, `persist.logd.size.security`, `persist.logd.statistics`, `persist.logd.logpersistd`
- **Power management:** `persist.sys.power.fuel.gauge`

**`com.android.traceur`** package disable (CPU category cleanup) — migrated from raw `pm disable-user` to `asb_pm_disable` with fallback. Now after uninstall, traceur is re-enabled if user had it enabled originally.

Final tally: **82 baseline-aware calls, 4 raw calls** (all in explicit fallback branches for early-boot before helper sourced).

### 🌡 Profile tuning — performance hot-guard widened

**Based on V45 performance profile log:**

```
Profile:              performance
ses_max_temp:         73°C
ses_t_sustained:      330s (5.5 min in sustained state)
ses_t_gaming:         145s
ses_t_heavy:          385s
cap_source_p0:        shell_overridden_down (ASB still controlling, no vendor_clamp)
hot_fail:             0
ses_auto_degraded:    0
```

The session held thermal line correctly — no vendor PowerHAL override, no hot-fail event. But `perf_hot_guard` triggered SUSTAINED transition at 63°C, exiting HEAVY/GAMING earlier than needed during sustained gaming. Vendor thermal HAL on OnePlus 15 SM8850 doesn't kick in until ~75°C.

**V45 change:** `perf_hot_guard_temp` raised from 63°C → 66°C in `config/governor.conf.shipped`. Gives performance profile more headroom during sustained gaming while still firing well before vendor HAL thermal clamp. `perf_hot_guard_ticks=2` unchanged.

Battery profile, balanced profile, and all other tunable thresholds bit-exact identical to V44 — no other tuning changes in V45.

### 📋 Verification

```
Compile (gcc -Wall -Wextra):  0 warnings, 0 errors
Shell syntax (32 files):      32/32 clean
Lint:                         0 errors, 5 warnings (4× RESERVED + 1 informational)
asb_settings_put calls:       42 (same as V44)
asb_persist_safe calls:       36 (was 0 in V44)
asb_pm_disable calls:         4 (was 2 in V44)
Raw setprop persist.*:        0 (was 40 in V44)
/data/local/tmp wipe:         REMOVED
Description boot init:        FIXED
asb_update_desc unified:      FIXED (single source of truth = current_profile file)
Athena/COSA persist writes:   0
Audio widening props:         0
perf_hot_guard_temp:          66°C (was 63°C in V44)
```

### 🚫 What V45 deliberately does NOT change

- **FSM scheduling logic, profile bounds, battery learner thresholds** — bit-exact identical to V44 apart from `perf_hot_guard_temp`. Reproducibility of V44 baseline behaviour preserved for battery and balanced profiles.
- **Italian NTP servers and Italian WIFI_COUNTRY=IT default** — kept by author's explicit choice. Both baseline-tracked so uninstall restores user's original values.
- **WebUI Live overlay layout** — unchanged from V44. Layout was already symmetric and minimal.
