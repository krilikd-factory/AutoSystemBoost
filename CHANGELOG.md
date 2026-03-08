# 🚀 AutoSystemBoost V16.6 STABLE RELEASE

Compared to V16.5  
Date: 2026-03-08

---

# 🔧 Network Stack Refinement

| Area | V16.5 | V16.6 |
|-----|-----|-----|
| TCP recovery | Standard BBR + tuning | Improved retransmission recovery |
| Packet retransmission | Default behavior | tcp_retrans_collapse=0 |
| Mobile network stability | Good | Better recovery on unstable LTE / 5G |

✔ Prevents collapsing retransmission segments  
✔ Improves packet recovery when packet loss occurs  
✔ Better behavior on mobile networks with unstable latency  

Result: cleaner TCP recovery and more stable data connections.

---

# 🔵 Bluetooth / LE Audio Power Fix

| Area | V16.5 | V16.6 |
|-----|-----|-----|
| LE Audio allow‑list bypass | Enabled | Removed |
| LE Audio idle call notifications | Enabled | Removed |
| Background BLE scan risk | Possible | Reduced |

Removed properties:

persist.bluetooth.leaudio.bypass_allow_list=true  
persist.bluetooth.leaudio.notify.idle.during.call=true  

These flags could allow applications to trigger BLE scans outside the normal allow‑list, which may cause unnecessary Bluetooth activity during idle.

Result:

✔ Reduced background BLE wakeups  
✔ Lower chance of Bluetooth idle drain  
✔ Cleaner LE Audio behavior

All important LE Audio optimizations remain active, including:

• LE Audio offload  
• codec switching support  
• SWB / Opus handling for modern TWS earbuds  

---

# 🔋 Battery & Idle Behaviour

The Bluetooth cleanup specifically targets background BLE scanning — a known source of idle battery drain when applications poll nearby devices.

Expected improvements:

| Scenario | V16.5 | V16.6 |
|------|------|------|
| Bluetooth idle activity | Normal | Reduced |
| Background BLE scanning | Possible | Restricted |
| Night battery drain | Normal | Potentially improved |

Result: cleaner idle behavior with less unnecessary Bluetooth activity.

---

# 📊 Summary

V16.6 is a refinement update focused on stability and power efficiency.

Main improvements:

✔ improved TCP retransmission handling  
✔ reduced background Bluetooth activity  
✔ safer LE Audio configuration  
✔ improved idle power behaviour  

No aggressive changes were introduced.

AutoSystemBoost continues to focus on:

• system stability  
• balanced performance  
• battery efficiency  
• high‑quality audio and connectivity
