# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V46-16a34a?style=for-the-badge" alt="V46">
  <img src="https://img.shields.io/badge/Previous-V45-6b7280?style=for-the-badge" alt="V45">
  <img src="https://img.shields.io/badge/versionCode-460-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

> **V46 is the "make V45 mature" release. One critical user-reported memory bug is fixed (App Market + WhatsApp "недостаточно памяти" despite plenty of free RAM), and three reliability investments are added in observe-only mode following ChatGPT's framework evaluation: tiered crash recovery (P0), NOISY trust tier candidate logging (P1a), and multi-sensor hot-guard scoring (P2). The observe-only P1/P2 work collects field data so V47 can decide behavioral activation based on real distribution, not guesswork. Field validation over 5.7 hours of clean operation confirmed the OOM fix works (zero crashes, zero false-positive kills) and that the NOISY criteria capture ~12.5% of mixed-use sessions — right in the target range.**

---

## ⚡ V46 — Memory OOM Fix + Reliability Hardening

### 🐛 Critical bug — App Market and WhatsApp "недостаточно памяти"

**Reported by primary user:**

> "При попытке обновить приложение через App Market вылетает ошибка что недостаточно памяти, хотя по факту свободной памяти предостаточно. Так же не открывался WhatsApp из-за нехватки памяти, помогла отчистка кэша приложения WhatsApp."

**Root cause:** three settings in V45 combined to create false-positive OOM kills:

1. **`vm.oom_kill_allocating_task=1`** (unconditional in `apply_vm()`) — when OOM occurs, kill the **task that triggered the allocation** rather than the highest oom_score victim. This is the opposite of Android's stock behavior. Android default is `0` — kernel picks victim by `oom_score_adj` (background apps go first, foreground apps last). With this flag set, any app that happened to be allocating at the wrong moment got killed even if it had low oom_score.

2. **Battery profile `VM_SWAPPINESS=200`** — extreme (kernel default is 60). Aggressively swaps anonymous pages to ZRAM. When user opens an app, kernel must decompress + page back in. Under any concurrent allocation pressure, ZRAM gets bottlenecked.

3. **Battery profile `VM_MINFREE=114688` (112 MB) and `VM_WMARK=400`** — reserves a large always-free pool with high watermark scale factor. Even when system has 4-6 GB physically free, kernel treats anything below the reserve as critical pressure.

**The failure chain:**
- App Market downloads APK → needs ~50 MB allocation for buffer
- Allocation triggers `__alloc_pages_slowpath` because watermark is unhappy (`VM_MINFREE` + `VM_WMARK`)
- ZRAM is busy decompressing other apps' pages from `swappiness=200`
- Kernel decides to invoke OOM killer to free memory
- `oom_kill_allocating_task=1` → **kills App Market** (the task that just allocated)
- User sees "недостаточно памяти" despite 4+ GB free in `free -h`

WhatsApp had the same issue when loading chat database after long idle (when its working set was mostly swapped out). Cache clear "fixed" it because clearing the on-disk DB reduced the working-set restore size.

**V46 fix — four changes:**

1. **Removed `vm.oom_kill_allocating_task=1`** from `apply_vm()` in `service.sh`. Kernel now uses default behavior (kill by `oom_score`). The line is replaced with a permanent comment explaining why it must never return.

2. **Battery profile VM tuning relaxed:**
   - `VM_SWAPPINESS`: 200 → **150** (still aggressive for battery but not pathological)
   - `VM_MINFREE`: 114688 → **65536** (112 MB → 64 MB)
   - `VM_WMARK`: 400 → **150** (less reserved-pool pressure)

3. **One-shot cleanup on boot:** `service.sh` now explicitly writes `/proc/sys/vm/oom_kill_allocating_task = 0` every boot. This ensures users upgrading from V45 immediately get the safe default without waiting for VM profile re-apply (which could take seconds during which apps might already be running).

4. **Lint regression guards added:**
   - `vm.oom_kill_allocating_task=1` writes in service.sh → lint error
   - Battery `VM_SWAPPINESS > 175` → lint error

**Field validation:** 5.7 hours of post-fix operation, zero OOM kills, zero crashes, zero recovery events. The user-reported symptom is gone.

### 🛡 P0 — Crash Recovery v2 (tiered)

V45's watchdog had basic crash counting (3 fails → safe mode). V46 introduces a **tiered recovery model** with proper observability:

**Level 1 (single fault):**
- Detect: governor process dead OR `/dev/.asb/state` stale > 120s
- Action: kill stale governor process, restart binary
- Telemetry: `recovery_count++`, append to `/dev/.asb/recovery_history.log`

**Level 2 (2nd fault within 5-minute window):**
- Action: shell fallback applies safe balanced bounds while governor restart attempts continue
- Telemetry: `recovery_level=2`, governor restart still attempted but with longer cooldown

**Level 3 (3rd fault in same boot session):**
- Action: give up. Set `ASB_GOV_ENABLED=0`, touch `/data/adb/asb/recovery_disabled` marker, apply shell-fallback safe bounds permanently for this boot
- Telemetry: `recovery_level=3`, module.prop description shows `⚠️ recovery mode — governor disabled`
- Next boot: marker is honored, governor stays disabled. User can clear via `rm /data/adb/asb/recovery_disabled` or uninstall+reinstall.

**Lock file mechanism (`/dev/.asb/recovery.lock`)** prevents `runtime/asb_reconcile.sh` from competing with watchdog during recovery operations. Reconcile checks the lock at start of each iteration and yields if held. Stale lock (>60s old) is broken automatically.

**`/dev/.asb/recovery.json` endpoint** (mirrors V44 `conflicts.json` / `learner_state.json` pattern):

```json
{
  "recovery_count": 1,
  "current_level": 1,
  "last_recovery_ts": 1779820800,
  "last_recovery_reason": "process_dead",
  "governor_disabled": 0,
  "disabled_marker_exists": 0
}
```

**Tighter watchdog cadence:** V45 polled every 5 minutes. V46 polls every 60 seconds for faster fault detection. On healthy systems, this adds negligible CPU overhead (one process check + one stat call per minute). On unhealthy systems, recovery happens 5× faster.

### 🧪 P1 — BAT_TRUST_NOISY tier (observe-only in V46, behavior in V47)

V45 had three tiers: `CLEAN`, `PARTIAL`, `DIRTY`. Real-world data showed most users' sessions land in `DIRTY` because mixed daily use has high wake counts and only moderate idle quality. The learner refused to learn from these and stayed stuck in stale state.

**V46 — observe-only NOISY classification:**

The C governor now classifies sessions that would qualify for a future `BAT_TRUST_NOISY` tier:
- `iq` (idle quality) in `[8, 20)`
- `wph` (wakes per hour) in `[10, 25]`
- `wake_cycles` in `[12, 45]`
- `dur >= 1800` (at least 30 min)
- `bat_total >= 600` (some genuine idle time existed)

**Crucially: in V46, the classification only sets a flag (`would_be_noisy`). Learner behavior is unchanged from V45 — sessions still treated as DIRTY.**

This is by design. We need field data showing the actual distribution of `would_be_noisy` candidates before committing to a behavioral change. If 0% of real sessions qualify, the tier is useless. If 80% qualify, the criteria are too loose.

**Field validation:** 5.7-hour session captured 1 NOISY candidate out of 8 sessions = **12.5% capture rate**. Right in the target range — not too few, not too many.

**`tools/asb_field_report.py` and `tools/asb_field_report.sh`** (new in V46) — analyze `session_history.jsonl` to show:
- Distribution of `would_be_noisy` by profile
- Histograms of iq/wph/wake/duration
- Per-zone advisory scores (see P2 below)
- Recovery counts from `recovery.json`

Run via `sh tools/asb_field_report.sh` from termux or adb shell. Output is plain text, designed to share in bug reports.

**V47 plan:** if 2-3 weeks of field data confirm NOISY catches a meaningful slice of real sessions without polluting with noise, V47 will activate the tier with learner weight = 0.10 (vs PARTIAL's 0.25 and CLEAN's 1.0).

### 🌡 P2 — Multi-sensor hot guard (observe-only in V46, decision logic in V47)

V45's hot guard fired on CPU zone alone at `perf_hot_guard_temp=66°C`. V46 collects multi-sensor data to inform a future weighted policy:

**Cold baseline (per boot session):** first 30 ticks of governor startup, average skin/surface/board temps are captured as cold baseline. All subsequent zone readings are evaluated as **delta-from-cold** instead of absolute temp. This prevents false advisories when device starts in a warm pocket or warm room.

**Per-zone vote scoring (0-100):**
- Skin: weight 0.30 — score climbs as `(current - cold_baseline)` exceeds threshold
- Surface: weight 0.40 — same delta-based scoring
- Board: weight 0.20 — same delta-based scoring
- CPU primary remains weight 1.0 (unchanged)

**Weighted advisory score:** sum of weighted zone scores. When score > 50 for 20 consecutive ticks (5+ minutes sustained advisory), `thermal_advisory_active=1`.

**`would_bias_exit_gaming` flag** — if advisory active AND CPU is in moderate range (not hot enough for primary hot_guard), this would have biased the FSM to exit GAMING → HEAVY earlier. **In V46 this is only a flag. The FSM does NOT actually bias.** Data collection only.

**Field validation:** `adv_active=1` fired 11 times during the 5.7-hour session (during warm-but-idle device states). **`adv_would_bias=0` always** — current criteria for the bias trigger are too narrow. This is an important finding from observe-only mode: without telemetry we would have activated dead logic in V47. V47 will need to widen the bias criteria.

**Fields added to `session_history.jsonl`:**
- `adv_score_avg` — average advisory score across session
- `adv_active_ticks` — total ticks where advisory was active
- `adv_would_bias_count` — number of times `would_bias_exit_gaming` fired
- `vote_skin_max`, `vote_surface_max`, `vote_board_max` — peak per-zone scores

**V47 plan:** widen `would_bias_exit_gaming` criteria based on V46 field data before activating behavioral effect. Current narrow criteria (CPU moderate AND advisory active) never fire in practice.

### 📁 State namespace migration — `/data/adb/asb/`

V44 and V45 scattered state files across `/data/adb/` with `asb_*` prefix (e.g. `asb_baseline.txt`, `asb_active_profile`, `asb_v45_cleanup_done`). V46 migrates these to a clean `/data/adb/asb/` directory:

```
/data/adb/asb/
├── active_profile
├── baseline.txt
├── profile_switches.log
├── user_config
├── v45_cleanup_done
├── vendor_boot_counter
├── vendor_mounts.log
├── vendor_overlay_active
├── recovery_disabled       (V46 marker)
├── recovery_lock           (V46 lock file)
└── debug
```

**Migration is automatic and one-shot.** `service.sh` early-boot block moves legacy `/data/adb/asb_*` files to `/data/adb/asb/*` on first V46 boot, then removes leftover legacy paths. No user action needed.

This namespace makes uninstallation cleaner (`rm -rf /data/adb/asb`) and prevents accidental collisions with other modules that scan `/data/adb/` directly.

### 📋 Verification

```
Compile (gcc -Wall -Wextra):              0 warnings, 0 errors
Shell syntax (33 files):                  33/33 clean
Lint:                                     0 errors, 6 warnings (4× RESERVED + 2 informational)
Athena/COSA persist writes:               0 (V45 fix preserved)
Audio widening props:                     0 (V45 fix preserved)
vm.oom_kill_allocating_task in code:      0 (V46 fix, was 1 in V45)
Battery VM_SWAPPINESS:                    150 (was 200 in V45)
Battery VM_MINFREE:                       64 MB (was 112 MB in V45)
Battery VM_WMARK:                         150 (was 400 in V45)
Recovery v2:                              tiered L1/L2/L3 with lock + recovery.json
NOISY tier:                               observe-only data collection (P1a)
Multi-sensor hot guard:                   observe-only data collection (P2)
Field report tool:                        tools/asb_field_report.{sh,py}
/data/adb/asb/ namespace:                 migrated from legacy /data/adb/asb_*
```

### 📂 Files changed vs V45 release

| File | What changed |
|---|---|
| `service.sh` | Removed `vm.oom_kill_allocating_task=1`, added one-shot OOM cleanup at boot, V46 tiered recovery hooks, `/data/adb/asb/` state namespace migration, recovery_disabled marker handling |
| `profiles/battery.sh` | `VM_SWAPPINESS` 200→150, `VM_MINFREE` 112MB→64MB, `VM_WMARK` 400→150 |
| `runtime/asb_watchdog.sh` | Full rewrite — tiered Level 1/2/3 recovery, lock file, `recovery.json` endpoint, 60s polling cadence |
| `runtime/asb_reconcile.sh` | Recovery lock yield at start of each loop iteration |
| `runtime/asb_baseline.sh` | Moved state files from `/data/adb/asb_*` to `/data/adb/asb/*` namespace |
| `runtime/profile_core.sh` | Minor cleanup of inline comments |
| `apply_profile.sh` | Minor refinements to description-update path |
| `src/asb_governor.c` | NOISY classification logic (observe-only), multi-sensor advisory scoring (observe-only), cold baseline capture, `would_bias_exit_gaming` flag, expanded `session_history.jsonl` schema |
| `src/asb_fsm.h` | New fields: `cold_baseline_skin/surface/board`, `cold_baseline_ticks/sum_*`, `thermal_advisory_score/ticks/active`, `thermal_vote_skin/surface/board`, `would_bias_exit_gaming`, `would_be_noisy` |
| `src/asb_config.h`, `src/asb_metrics.h`, `src/asb_writer.h` | Internal struct additions for V46 observe-only telemetry |
| `tools/asb_lint.sh` | V46 regression guards for `oom_kill_allocating_task` and `VM_SWAPPINESS > 175` |
| `tools/asb_field_report.sh` | **NEW** — wrapper to run field report from termux/adb |
| `tools/asb_field_report.py` | **NEW** — Python analyzer of `session_history.jsonl` and `recovery.json` |
| `common/install.sh` | Version bump |
| `post-fs-data.sh` | State namespace migration support |
| `uninstall.sh` | Clean `/data/adb/asb/` directory on removal |
| `webroot/index.html`, `action.sh` | Version label V45→V46 |
| `module.prop`, `update.json`, `CHANGELOG.md` | Version metadata + this changelog |

### 🚫 What V46 deliberately does NOT change

- **Profile bounds for performance and balanced** — unchanged from V45
- **FSM scheduling logic** — bit-exact identical apart from new observation hooks
- **Per-app auto-profile switching** — still deferred (polling daemon would burn battery)
- **Idle quality predictor** — V47+ territory if ever
- **NOISY tier behavioral change** — collecting data first (P1b deferred to V47)
- **Multi-sensor hot guard behavioral change** — collecting data first (P2 decision deferred to V47)
- **All V45 critical bug fixes preserved bit-exact:** description boot-init, `/data/local/tmp` wildcard removal, Athena/COSA persist cleanup, audio widening props removal, audio matrix limiter removal
