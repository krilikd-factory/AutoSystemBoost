# ASB V14 - Changelog

This update is intentionally small and low-risk: it keeps the same core tuning as V13.9(FINAL2),
and only adds a few targeted connectivity/standby refinements.

------------------------------------------------------------------------

## Network / Connectivity

- net.netfilter.nf_conntrack_tcp_timeout_established: 420 -> 600
  Keeps established TCP sessions longer to reduce unexpected reconnects.

- net.core.bpf_jit_enable: (not set) -> 1
  Enables BPF JIT when supported (can reduce CPU overhead for some network paths).

------------------------------------------------------------------------

## Standby / Background Activity

- Added: nearby_scanning_enabled=0
  Disables Android Nearby scanning to reduce background BLE/Wi‑Fi wakeups in standby.

- Added: network_recommendations_enabled=0
  Reduces background network suggestion activity.

------------------------------------------------------------------------

## System Logging

- dropbox_max_files: 8 -> 5
  Slightly reduces DropBox log retention.

------------------------------------------------------------------------

## Bluetooth

- Added: bluetooth_voip_support=1
  Enables BT VoIP support flag

------------------------------------------------------------------------
