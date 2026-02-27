# ASB V13.5 - Changelog

## CPU and Thermal Safety (Wild Kernel)

-   Added Wild-kernel detection to avoid applying risky CPU group / cpuset tweaks that can cause constant boosting on some custom kernels.
-   Kept performance stable on stock kernel while improving thermal stability on Wild.

Result:
- More stable scaling on Wild
- Less unnecessary heat in background
- No impact to gaming behavior expected

------------------------------------------------------------------------

## Uclamp Compatibility and Balance

-   Reduced foreground uclamp minimum (less persistent UI boosting).
-   Added support for alternative uclamp paths (cpu.uclamp.* and uclamp.*).
-   Removed hard uclamp.max forcing (left to kernel/ROM policy).

------------------------------------------------------------------------

## Memory Management

-   Updated VM writeback timings for smoother background behavior.
-   Slightly increased compaction proactiveness to reduce fragmentation stalls.
-   Tuned stat interval and min_free_kbytes for a more balanced idle/active behavior.

------------------------------------------------------------------------

## Network

-   Removed forced TCP keepalive values (keeps ROM defaults for better standby battery).
-   Removed security-sensitive BPF JIT and rp_filter overrides (left to ROM/kernel policy).
-   Kept low-latency queue discipline configuration.

------------------------------------------------------------------------

## Summary

ASB V13.5 compared to V13.4 focuses on:

-   Improving thermal safety on Wild kernel (avoids risky CPU group tweaks)
-   Better uclamp compatibility and less persistent boosting
-   More balanced VM + network sysctl tuning for stability and standby

Recommended for daily use.
