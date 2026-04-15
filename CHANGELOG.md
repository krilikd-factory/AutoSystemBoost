# AutoSystemBoost -- Changelog

---

## V37 -- Honest Thermal Telemetry + Release Discipline

> **V36 rebuilt the profiles around sustainable gaming and deeper battery saving.**
> **V37 makes the thermal telemetry honest, isolates broken sensors, and aligns versioning across every file in the module.**

The V37 release is not a profile rebalance. The profiles that landed in V36 (battery, balanced, performance) tested well across multi-hour sessions on real hardware and are kept untouched. V37's job is to make the module's diagnostics trustworthy enough for a public GitHub release.

---

### 🌡 Honest Thermal Telemetry

V37 dev iterations added separate `skin_temp` and `surface_hotspot` channels, but the fallback logic collapsed them back into a single value when the literal shell sensors went silent. V37 fixes that and adds a sanity gate around the SoC die hotspot sensor that was returning garbage on some firmwares.

#### `skin_temp` is now strictly literal shell

| | V36 / V37 release |
|:--|:--|:--|
| `skin_temp_c` source | shell_front/frame/back, falling back to `sys-therm-6` if all zero | shell_front/frame/back **only**, returns 0 if all silent |
| `surface_hotspot_c` source | sys-therm-6 / board_temp | sys-therm-6 / board_temp (unchanged) |
| Result on OP15 (shell sensors silent) | skin and surface both report 40C from sys-therm-6 — taxonomy meaningless | skin reports 0 (with `thermal_skin_zone=-1`), surface reports 40C — clean separation |

The two channels were always meant to answer different questions: "what does the user's hand feel" vs "where's the body-adjacent hot spot". V37 stops conflating them.

#### `socd` sanity gate

The SoC die-hotspot sensor `socd` is the highest-priority CPU thermal source on Snapdragon 8 Elite Gen 5, but on at least one OP15 firmware revision it reports `raw=5` (effectively garbage) while real per-core sensors read 90–100C.

V37 adds an explicit sanity gate at two layers:

1. **Discovery time**: when `thermal_discover()` validates `socd`, it does an immediate live read. If the value is `<=10C`, the zone is rejected and discovery falls through to `cpu-1-1-*` (priority 2) and `cpu-0-5-*` (priority 3). The reason is logged at startup.
2. **Read time**: even if `socd` was selected, every per-tick read re-checks `c <= 10`. If true, the read is treated as invalid (`temp_valid=0`) with `temp_invalid_reason="raw_too_low"` while keeping the cached value. This prevents one broken read from cascading into FSM decisions.

#### `temp_invalid_reason` field

Status JSON and `session_history.jsonl` now carry a `temp_invalid_reason` string with these possible values:

| Value | Meaning |
|:--|:--|
| `ok` | Sensor read succeeded, temperature is fresh |
| `init` | First read hasn't completed yet |
| `read_fail` | sysfs read returned 0 or error |
| `raw_too_low` | Sensor returned an implausibly low value (likely broken socd) |
| `no_zone` | No thermal CPU zone bound at all |

This replaces the old "is `temp_valid` 0 because the sensor is dead, or because it just hasn't refreshed yet?" guessing game.

#### Session-level sensor health

`session_history.jsonl` schema bumped from `v:8` to `v:9`. New per-session fields:

```json
"temp_invalid_n": 12,
"temp_last_reason": "raw_too_low"
```

These let `tools/asb_session_report.py` and any future analysis tooling see at a glance which sessions ran with degraded thermal telemetry vs which had a healthy sensor stack.

#### `thermal_summary:` startup log line

The startup `tz_dump:` block prints all 96+ thermal zones for postmortem use, but reading 96 lines to learn which sensor was actually selected is annoying. V37 adds a single summary line right after `tz_dump:`:

```
thermal_summary: cpu=socd(z67,val=5,valid=0) skin=none(z-1,val=0) surface=sys-therm-6(z74,val=40)
```

One line tells you: which CPU sensor won, which skin sensor won, which surface sensor won, current readings, validity. Everything else is just for context.

---

### 🩺 Type-Resolved Thermal Diagnostics in `asb_doctor`

`tools/asb_doctor.sh` previously didn't dump thermal state at all — users had to chase sensors manually with `cat /sys/class/thermal/thermal_zone*/type`. V37 adds a `🌡 Thermal Sensors (type-resolved)` section that:

1. Walks every `/sys/class/thermal/thermal_zone*` directory
2. Reads each zone's `type` attribute
3. Looks for a fixed set of recognised types (`socd`, `cpu-1-1-0`, `shell_front`, `sys-therm-6`, `board_temp`, etc.)
4. Resolves each one to its current zone ID dynamically and prints `name → zone → temperature`

**Critically: zone IDs are never hardcoded.** Zone IDs renumber across kernel boots; any tool that hardcodes `thermal_zone57` is wrong on the very next reboot. Doctor now does the right thing.

---
