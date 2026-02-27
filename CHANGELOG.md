# ASB V13.6 - Changelog

## Standby Battery (VM)

-   vm.dirty_expire_centisecs: 4000 -> 6000
-   vm.dirty_writeback_centisecs: 3000 -> 5000
-   vm.compaction_proactiveness: 1 -> 0
-   vm.stat_interval: 10 -> 15

Why:
- More time for cache coalescing means fewer storage controller wakeups during idle/background.
- Disables proactive compaction work that can create unnecessary background CPU load on high-RAM devices.

Note:
- Longer dirty writeback windows slightly increase the amount of unsynced data during sudden power loss.

------------------------------------------------------------------------

## Network Stability

-   net.ipv4.tcp_slow_start_after_idle: 0 -> 1

Why:
- More predictable behavior after short pauses on mobile networks (better re-probing of available bandwidth).

------------------------------------------------------------------------

## GPU Idle Tuning (Restored)

-   Added GPU idle tuning back into apply_idle():
    -   sleep_disabled=0 (allows deep sleep)
    -   min_pwrlevel=6 (prefers lowest power state in idle, if supported)
    -   bus_split=1 (power-gates unused bus segments, if supported)
-   apply_idle is now included in the reapply loop to survive system resets.

------------------------------------------------------------------------

## Wild Kernel Safety Fix

-   Fixed a bug where cpu_groups were skipped on Wild at boot, but still re-applied later by the background reapply loop.
-   cpu_groups are now consistently skipped on Wild kernel in both boot and tail loop.

Result:
- Less risk of constant boosting / unnecessary heat on Wild kernel
- Better standby behavior without reducing real-world performance

------------------------------------------------------------------------

## Summary

ASB V13.6 focuses on:

-   Better idle/standby battery through VM writeback + reduced background kernel work
-   More stable mobile networking. 
-   Restored GPU idle power saving with safe re-application
-   Correct Wild-kernel handling to avoid reapply regressions

Recommended for daily use.
