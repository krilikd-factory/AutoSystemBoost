#!/usr/bin/env python3
"""ASB capture comparison - field logs of one build against another, per phone model.

Reads full-day captures (folders with _full_day_report.txt) and asbdiag reports, from
folders or zip files (zips inside zips too), and prints the figures that say whether a
build is better: the overnight rate and awake share, idle and screen-on drain, UI
smoothness, how hard the prime cores were used, Wi-Fi leave timing, the headphone limiter,
the Wi-Fi transmit queue and ASB's own CPU cost.

    python3 asb_capture_compare.py LOGS...                       table of every capture
    python3 asb_capture_compare.py LOGS... --json base.json      also save the figures
    python3 asb_capture_compare.py LOGS... --baseline base.json  compare with saved figures

A capture sent twice (same phone, same start) is counted once. Figures marked '~' in the
report (too short to mean anything) are not used for a comparison.
"""
import argparse
import io
import json
import os
import re
import statistics
import sys
import tempfile
import zipfile

SCREEN_ON = {"active", "post_wake", "gaming", "audio_spk_scr", "audio_bt_scr", "audio_wired_scr"}
SCREEN_OFF = {"idle", "sleep", "audio_spk", "audio_bt", "audio_wired"}
DIAG_MARK = "AutoSystemBoost — GLOBAL SYSTEM DIAGNOSTIC"


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _extract_zip(data, dest, depth=0):
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        return
    for info in zf.infolist():
        name = info.filename
        if info.is_dir() or name.startswith("/") or ".." in name.split("/"):
            continue
        blob = zf.read(info)
        target = os.path.join(dest, name)
        if name.lower().endswith(".zip") and depth < 3:
            sub = target[:-4] + "__zip"
            os.makedirs(sub, exist_ok=True)
            _extract_zip(blob, sub, depth + 1)
            continue
        os.makedirs(os.path.dirname(target) or dest, exist_ok=True)
        with open(target, "wb") as f:
            f.write(blob)


def collect(paths, tmp):
    roots = []
    for i, p in enumerate(paths):
        if os.path.isfile(p) and p.lower().endswith(".zip"):
            d = os.path.join(tmp, "in%d" % i)
            os.makedirs(d, exist_ok=True)
            with open(p, "rb") as f:
                _extract_zip(f.read(), d)
            roots.append(d)
        else:
            roots.append(p)
    captures, diags = [], []
    for r in roots:
        if os.path.isfile(r):
            if _is_diag(r):
                diags.append(r)
            continue
        for dirpath, _dirs, files in os.walk(r):
            if "_full_day_report.txt" in files:
                captures.append(dirpath)
            for fn in files:
                if fn.endswith(".txt") and fn != "_full_day_report.txt":
                    fp = os.path.join(dirpath, fn)
                    if _is_diag(fp):
                        diags.append(fp)
    return captures, diags


def _is_diag(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(600)
    except OSError:
        return False
    return DIAG_MARK in head


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def parse_capture(d):
    rep = _read(os.path.join(d, "_full_day_report.txt"))
    env = _read(os.path.join(d, "env.txt"))
    m = {"kind": "capture", "path": d}
    for key, pat in (("model", r"^model:\s+(\S+)"), ("version", r"^module_version:\s+(\S+)"),
                     ("oem_build", r"^oem_build:\s+(.+)$")):
        mm = re.search(pat, env, re.M)
        m[key] = mm.group(1).strip() if mm else "?"
    try:
        man = json.loads(_read(os.path.join(d, "build_manifest.json")) or "{}")
        m["build_date"] = man.get("build_date", "?")
    except ValueError:
        m["build_date"] = "?"
    mm = re.search(r"^(\d+)\|", _read(os.path.join(d, "phase_timeline.txt")), re.M)
    m["start_epoch"] = int(mm.group(1)) if mm else 0
    mm = re.search(r"capture: \S+ target, (\d+) min elapsed", rep)
    m["elapsed_min"] = int(mm.group(1)) if mm else 0

    phases = {}
    in_tab = False
    for line in rep.splitlines():
        if line.startswith("phase ") and "awake%" in line and "pct/h" in line:
            in_tab = True
            continue
        if in_tab:
            if line.startswith("Legend") or line.startswith("====="):
                break
            cols = line.split()
            if len(cols) >= 12 and re.match(r"^[a-z_()]+$", cols[0]):
                rough = cols[3].endswith("~")
                phases[cols[0]] = {
                    "min": _num(cols[1]), "d_pct": _num(cols[2]), "pct_h": _num(cols[3].rstrip("~")),
                    "rough": rough, "mA": _num(cols[4]), "rmnet_mib": _num(cols[5]),
                    "awake": _num(cols[-1]),
                }
    m["phases"] = phases
    night = phases.get("night(longest)")
    m["night"] = night
    on_min = sum(p["min"] or 0 for k, p in phases.items() if k in SCREEN_ON)
    on_pct = sum(p["d_pct"] or 0 for k, p in phases.items() if k in SCREEN_ON)
    m["screen_on_min"] = round(on_min, 1)
    m["screen_on_pct_h"] = round(on_pct * 60.0 / on_min, 2) if on_min >= 30 else None
    off = [p for k, p in phases.items() if k in SCREEN_OFF]
    off_min = sum(p["min"] or 0 for p in off)
    m["screen_off_min"] = round(off_min, 1)
    m["mobile_mib"] = round(sum(p["rmnet_mib"] or 0 for p in phases.values() if p is not night), 1)
    idle = phases.get("idle")
    m["idle"] = idle

    best = None
    for fn in os.listdir(d):
        if fn.startswith("snapshot_") and fn.endswith(".txt"):
            st = _read(os.path.join(d, fn))
            a, b = re.search(r"^governor_cpu_ms=(\d+)", st, re.M), re.search(r"^governor_uptime_s=(\d+)", st, re.M)
            if a and b and int(b.group(1)) > 0 and (best is None or int(b.group(1)) > best[1]):
                best = (int(a.group(1)), int(b.group(1)))
    m["asb_cpu_s_h"] = round(best[0] * 3.6 / best[1], 2) if best and best[1] >= 10800 else None
    mm = re.search(r"all screen-on intervals: (\d+)\s+frames (\d+)\s+janky ([\d.]+)%", rep)
    m["ui_janky_pct"] = _num(mm.group(3)) if mm else None
    mm = re.search(r"janky frames per second on screen: ([\d.]+)", rep)
    m["ui_janky_s"] = _num(mm.group(1)) if mm else None
    mm = re.search(r"steady floor: ([\d.]+) janky frames a second.*?\n([\d.]+) a second in the busy", rep, re.S)
    m["ui_floor_s"] = _num(mm.group(1)) if mm else None
    m["ui_busy_s"] = _num(mm.group(2)) if mm else None
    mm = re.search(r"^\s+com\.android\.systemui\s+\d+\s+\d+\s+([\d.]+)\s+\d+ of \d+", rep, re.M)
    m["ui_sysui_s"] = _num(mm.group(1)) if mm else None
    states = {}
    mm = re.search(r"^ASB state\s+intervals\s+frames\s+janky\s+janky/s\n((?:[A-Z_a-z]+\s+\d+\s+\d+\s+[\d.]+%\s+[\d.]+\n)+)", rep, re.M)
    if mm:
        for row in mm.group(1).splitlines():
            c = row.split()
            states[c[0]] = {"frames": int(c[2]), "janky_pct": _num(c[3].rstrip("%")), "janky_s": _num(c[4])}
    m["ui_states"] = states
    mm = re.search(r"screen-on samples (\d+): prime cores working in (\d+)%, main cores in (\d+)%", rep)
    m["prime_work_pct"] = int(mm.group(2)) if mm else None
    owners = {}
    mm = re.search(r"by cap owner:\n((?:\s+\d+ \S+\n)+)", rep)
    if mm:
        for row in mm.group(1).splitlines():
            c = row.split()
            owners[c[1]] = int(c[0])
    m["throttle"] = owners
    mm = re.search(r"releases: (\d+) \(out of range (\d+), no internet (\d+)\)", rep)
    m["wifi_releases"] = int(mm.group(1)) if mm else None
    mm = re.search(r"first failing reading to the release: median (\d+) s, longest (\d+) s", rep)
    m["wifi_leave_median_s"] = int(mm.group(1)) if mm else None
    m["wifi_leave_max_s"] = int(mm.group(2)) if mm else None
    return m


def parse_diag(path):
    t = _read(path)
    m = {"kind": "diag", "path": path}
    mm = re.search(r"^ device\s*: \S+ (\S+)", t, re.M)
    m["model"] = mm.group(1) if mm else "?"
    mm = re.search(r"^ version : (\S+)", t, re.M)
    m["version"] = mm.group(1) if mm else "?"
    mm = re.search(r"^ date\s*: (.+)$", t, re.M)
    m["date"] = mm.group(1).strip() if mm else "?"
    mm = re.search(r"^\s+audio_remove_volume_limit=(\d)", t, re.M)
    m["vol_limit_off"] = mm.group(1) if mm else None
    mm = re.search(r"mSafeMediaVolumeState=(\S+)", t)
    m["safe_media"] = mm.group(1) if mm else None
    mm = re.search(r"audio\.safemedia\.bypass = (\S+)", t)
    m["safemedia_bypass"] = mm.group(1) if mm else None
    mm = re.search(r"net_txqueue=(\S+)[^\n]*? - live: [^\n]*?\bwlan0=(\d+)", t)
    m["txqueue"] = (mm.group(1), int(mm.group(2))) if mm else None
    mm = re.search(r"cpu_ms=\d+ over .*? = ([\d.]+) s of CPU per hour", t)
    m["asb_cpu_s_h"] = _num(mm.group(1)) if mm else None
    mm = re.search(r"doze_trim_whitelist = (\S*) · trimmed by ASB: (\d+) · kept \(WebUI list\): (\d+) · made exempt by ASB: (\d+)", t)
    m["doze_trim"] = {"on": mm.group(1), "trimmed": int(mm.group(2)), "kept": int(mm.group(3)),
                      "granted": int(mm.group(4))} if mm else None
    return m


def dedupe(caps):
    best = {}
    for c in caps:
        key = (c["model"], c["start_epoch"]) if c["start_epoch"] else (c["model"], c["path"])
        if key not in best or c["elapsed_min"] > best[key]["elapsed_min"]:
            best[key] = c
    return list(best.values())


def _fmt(v, suffix="", nd=2):
    if v is None:
        return "-"
    if isinstance(v, float):
        return ("%." + str(nd) + "f%s") % (v, suffix)
    return "%s%s" % (v, suffix)


def row_of(c):
    n = c.get("night") or {}
    i = c.get("idle") or {}
    li = (c.get("ui_states") or {}).get("LIGHT_IDLE", {})
    mo = (c.get("ui_states") or {}).get("MODERATE", {})
    return [
        c["model"], c["version"], str(c["elapsed_min"]),
        _fmt(n.get("pct_h")) + ("~" if n.get("rough") else ""), _fmt(n.get("awake"), "%", 1), _fmt(n.get("min"), "", 0),
        (_fmt(i.get("pct_h")) + ("~" if i.get("rough") else "")) if i else "-", _fmt(i.get("awake"), "%", 1) if i else "-",
        _fmt(c.get("screen_on_pct_h")), _fmt(c.get("screen_on_min"), "", 0),
        _fmt(c.get("ui_janky_s")), _fmt(c.get("ui_floor_s")), _fmt(li.get("janky_s")), _fmt(mo.get("janky_s")),
        _fmt(c.get("prime_work_pct"), "%"), _fmt(c.get("mobile_mib"), "", 0),
        _fmt(c.get("asb_cpu_s_h"), "", 1),
        "-" if c.get("wifi_releases") is None else "%s/%s" % (c["wifi_releases"], _fmt(c.get("wifi_leave_median_s"), "s")),
    ]


HEAD = ["model", "version", "min", "night%/h", "n.awake", "n.min", "idle%/h", "i.awake", "on%/h", "on.min",
        "jank/s", "floor/s", "LI/s", "MOD/s", "prime", "mobMiB", "asbCPU", "wifi rel/med"]


def table(rows, head):
    w = [max(len(str(x)) for x in col) for col in zip(head, *rows)] if rows else [len(h) for h in head]
    out = ["  ".join(str(h).ljust(w[k]) for k, h in enumerate(head))]
    for r in rows:
        out.append("  ".join(str(x).ljust(w[k]) for k, x in enumerate(r)))
    return "\n".join(out)


def diag_rows(diags):
    rows = []
    for d in diags:
        dz = d.get("doze_trim")
        rows.append([d["model"], d["version"], d["date"][:24], d.get("safe_media") or "-",
                     d.get("safemedia_bypass") or "-",
                     "-" if not d.get("txqueue") else "%s:wlan0=%d" % d["txqueue"],
                     _fmt(d.get("asb_cpu_s_h"), " s/h", 1),
                     "-" if not dz else "%s/%s/%s" % (dz["trimmed"], dz["kept"], dz["granted"])])
    return rows


DHEAD = ["model", "version", "date", "safe media", "bypass", "txqueue", "ASB CPU", "doze trim/kept/granted"]

def _solid(ph, key):
    if not ph or ph.get("rough") or (ph.get("min") or 0) < 30:
        return None
    return ph.get(key)


METRICS = [
    ("night %/h", lambda c: None if not c.get("night") or c["night"].get("rough") else c["night"].get("pct_h"), True),
    ("night awake %", lambda c: _solid(c.get("night"), "awake"), True),
    ("idle %/h", lambda c: _solid(c.get("idle"), "pct_h"), True),
    ("idle awake %", lambda c: _solid(c.get("idle"), "awake"), True),
    ("screen-on %/h", lambda c: c.get("screen_on_pct_h"), True),
    ("janky frames/s", lambda c: c.get("ui_janky_s"), True),
    ("janky floor/s", lambda c: c.get("ui_floor_s"), True),
    ("LIGHT_IDLE janky/s", lambda c: (c.get("ui_states") or {}).get("LIGHT_IDLE", {}).get("janky_s"), True),
    ("MODERATE janky/s", lambda c: (c.get("ui_states") or {}).get("MODERATE", {}).get("janky_s"), True),
    ("prime working %", lambda c: c.get("prime_work_pct"), True),
    ("ASB CPU s/h", lambda c: c.get("asb_cpu_s_h"), True),
    ("Wi-Fi leave median s", lambda c: c.get("wifi_leave_median_s"), True),
]


def _median(vals):
    vals = [v for v in vals if v is not None]
    return round(statistics.median(vals), 2) if vals else None


def compare_diags(base, new):
    bd = base.get("diags", [])
    models = sorted({d["model"] for d in new} | {d["model"] for d in bd})
    out = []
    for mdl in models:
        parts = []
        for label, ds in (("baseline", [d for d in bd if d["model"] == mdl]),
                          ("new", [d for d in new if d["model"] == mdl])):
            if not ds:
                parts.append("%s: no report" % label)
                continue
            want = [d for d in ds if d.get("vol_limit_off") == "1"]
            act = sum(1 for d in want if (d.get("safe_media") or "").endswith("_ACTIVE"))
            q = sorted({"%s:%s" % tuple(d["txqueue"]) for d in ds if d.get("txqueue")})
            cpu = _median([d.get("asb_cpu_s_h") for d in ds])
            dz = [d["doze_trim"] for d in ds if d.get("doze_trim")]
            parts.append("%s: %d report(s), headphone limiter on although switched off: %d of %d, Wi-Fi queue %s, ASB CPU %s%s" % (
                label, len(ds), act, len(want), ",".join(q) or "-", _fmt(cpu, " s/h", 1),
                "" if not dz else ", doze trim %d/kept %d/granted %d" % (dz[-1]["trimmed"], dz[-1]["kept"], dz[-1]["granted"])))
        out.append("%s - %s" % (mdl, "; ".join(parts)))
    return "\n".join(out)


def compare(base, new):
    bcap = [c for c in base.get("captures", [])]
    models = sorted({c["model"] for c in new} | {c["model"] for c in bcap})
    out = []
    for mdl in models:
        b = [c for c in bcap if c["model"] == mdl]
        n = [c for c in new if c["model"] == mdl]
        if not b or not n:
            out.append("%s: %s" % (mdl, "only in the new logs" if n else "only in the baseline"))
            continue
        out.append("%s: baseline %d capture(s) %s, new %d capture(s) %s" % (
            mdl, len(b), sorted({c["version"] for c in b}), len(n), sorted({c["version"] for c in n})))
        rows = []
        for name, get, lower_better in METRICS:
            bv, nv = _median([get(c) for c in b]), _median([get(c) for c in n])
            if bv is None and nv is None:
                continue
            if bv is None or nv is None:
                rows.append([name, _fmt(bv), _fmt(nv), "-", "not in both"])
                continue
            delta = nv - bv
            rel = (delta / bv * 100.0) if bv else 0.0
            verdict = "same"
            if abs(rel) >= 10 and abs(delta) > 0.05:
                verdict = "better" if (delta < 0) == lower_better else "worse"
            rows.append([name, _fmt(bv), _fmt(nv), "%+.2f (%+.0f%%)" % (delta, rel), verdict])
        ctx = []
        for label, get in (("capture min", lambda c: c.get("elapsed_min")),
                           ("night length min", lambda c: (c.get("night") or {}).get("min")),
                           ("screen-on min", lambda c: c.get("screen_on_min")),
                           ("mobile MiB", lambda c: c.get("mobile_mib"))):
            ctx.append("%s %s -> %s" % (label, _fmt(_median([get(c) for c in b]), "", 0),
                                         _fmt(_median([get(c) for c in n]), "", 0)))
        out.append(table(rows, ["metric", "baseline", "new", "change", "verdict"]))
        out.append("  context: " + "; ".join(ctx))
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", help="save the figures of these logs to this file")
    ap.add_argument("--baseline", help="compare with figures saved earlier by --json")
    ap.add_argument("--label", default="", help="a name for this set, kept in --json")
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        cap_dirs, diag_files = collect(a.paths, tmp)
        caps = dedupe([parse_capture(d) for d in cap_dirs])
        diags = [parse_diag(p) for p in diag_files]
    caps.sort(key=lambda c: (c["model"], c["start_epoch"]))
    diags.sort(key=lambda d: (d["model"], d["date"]))
    if a.json:
        slim = []
        for c in caps:
            s = dict(c)
            s["path"] = os.path.basename(s["path"].rstrip("/"))
            slim.append(s)
        dslim = []
        for d in diags:
            s = dict(d)
            s["path"] = os.path.basename(s["path"])
            dslim.append(s)
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"label": a.label, "captures": slim, "diags": dslim}, f, ensure_ascii=False, indent=1)
    print("FULL-DAY CAPTURES (%d)" % len(caps))
    print(table([row_of(c) for c in caps], HEAD))
    print("")
    print("ASBDIAG REPORTS (%d)" % len(diags))
    print(table(diag_rows(diags), DHEAD))
    print("")
    if a.json:
        print("saved: %s" % a.json)
    if a.baseline:
        with open(a.baseline, encoding="utf-8") as f:
            base = json.load(f)
        print("COMPARISON WITH %s (medians per model)" % (base.get("label") or a.baseline))
        print(compare(base, caps))
        print("ASBDIAG, BASELINE AGAINST NEW")
        print(compare_diags(base, diags))
        print("")
        print("UI figures follow the apps used; drain follows screen time, signal and traffic - read the context lines.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
