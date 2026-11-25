# Field validation: ASB V66 test / release candidate

Host tests and ZIP verification do not establish runtime safety, energy savings, or camera/audio behavior on a phone. Record evidence per device, ROM and kernel before making such claims. This is a protocol, not a record of completed validation.

## Inventory

For each result record the device/model and SoC, ROM build/fingerprint, kernel and version, root manager/version, ASB version and exact ZIP SHA-256, profiles, installed modules, date, ambient conditions and major configuration changes. Avoid publishing serials, account names, package usage, location, or other personal data.

## Installation and recovery

Use a recoverable test device and known recovery procedure. Across supported root managers, exercise fresh installation, upgrade, reboot, disable, reboot, re-enable and uninstall. Record boot success, root availability, service status, safe-mode behavior, residual mounts/properties and before/after readbacks; mark unsupported or unreadable values as unknown. Capture exceptions and check stock recovery after safe mode. OTA/ROM upgrades need their own run and a recovery plan. Do not label this matrix passed until it has actually been run on the relevant device.

## Paired measurements

Change one variable between control and treatment; match ROM, kernel, brightness, radio, ambient temperature, charging, applications and scenario. Alternate order, allow stabilization, and perform at least three independent runs per condition. Report each run, median and spread, coverage and missing data. Do not infer mAh saved from frequency or short samples.

Scenarios: overnight screen-off idle, mixed usage, scrolling, navigation, Wi-Fi and mobile data, games, camera preview, photo, HDR and sustained recording, with relevant audio and Bluetooth paths. Record battery energy or charge per time only when the source and sampling quality permit it; record temperature, frame times/jank, radio conditions and relevant service restarts. Treat these as observations, not proof of cause.

## ASB overhead and ownership

Separately record resident ASB process counts, CPU time and wakeups during matched screen-on/off intervals, measurement method, timestamps and missing permissions. Fork counts and per-feature energy cannot be derived from process count alone; do not assign a cost without instrumentation. Record ASB versus OEM/game/thermal control, attempted and accepted writes, readback, conflict/holdoff and unknown ownership. Do not run persistent high-frequency tracing in a battery test without measuring the tracer itself.

## Decision

Keep a finding as observed, inferred or unknown, link raw evidence only where authorized, note the trade-off and rollback. Compare across OnePlus 12/13/15 and a supported Ace/R variant where available, different SoCs, supported ROMs, root environments, stock/custom kernels and profiles. Unsupported combinations remain unverified; completing one combination does not certify the others.
