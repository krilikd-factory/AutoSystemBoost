# ðŸš€ AutoSystemBoost V16.6 STABLE RELEASE

Compared to V16.5  
Date: 2026-03-08

---

# ðŸ”§ Network Stack Refinement

| Area | V16.5 | V16.6 |
|-----|-----|-----|
| TCP recovery | Standard BBR + tuning | Improved retransmission recovery |
| Packet retransmission | Default behavior | tcp_retrans_collapse=0 |
| Mobile network stability | Good | Better recovery on unstable LTE / 5G |

âœ” Prevents collapsing retransmission segments  
âœ” Improves packet recovery when packet loss occurs  
âœ” Better behavior on mobile networks with unstable latency  

Result: cleaner TCP recovery and more stable data connections.

---

# ðŸ”µ Bluetooth / LE Audio Power Fix

| Area | V16.5 | V16.6 |
|-----|-----|-----|
| LE Audio allowâ€‘list bypass | Enabled | Removed |
| LE Audio idle call notifications | Enabled | Removed |
| Background BLE scan risk | Possible | Reduced |

Removed properties:

persist.bluetooth.leaudio.bypass_allow_list=true  
persist.bluetooth.leaudio.notify.idle.during.call=true  

These flags could allow applications to trigger BLE scans outside the normal allowâ€‘list, which may cause unnecessary Bluetooth activity during idle.

Result:

âœ” Reduced background BLE wakeups  
âœ” Lower chance of Bluetooth idle drain  
âœ” Cleaner LE Audio behavior

All important LE Audio optimizations remain active, including:

â€¢ LE Audio offload  
â€¢ codec switching support  
â€¢ SWB / Opus handling for modern TWS earbuds  

---

# ðŸ”‹ Battery & Idle Behaviour

The Bluetooth cleanup specifically targets background BLE scanning â€” a known source of idle battery drain when applications poll nearby devices.

Expected improvements:

| Scenario | V16.5 | V16.6 |
|------|------|------|
| Bluetooth idle activity | Normal | Reduced |
| Background BLE scanning | Possible | Restricted |
| Night battery drain | Normal | Potentially improved |

Result: cleaner idle behavior with less unnecessary Bluetooth activity.

---

# ðŸ“Š Summary

V16.6 is a refinement update focused on stability and power efficiency.

Main improvements:

âœ” improved TCP retransmission handling  
âœ” reduced background Bluetooth activity  
âœ” safer LE Audio configuration  
âœ” improved idle power behaviour  

No aggressive changes were introduced.

AutoSystemBoost continues to focus on:

â€¢ system stability  
â€¢ balanced performance  
â€¢ battery efficiency  
â€¢ highâ€‘quality audio and connectivity
