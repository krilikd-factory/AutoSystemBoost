#!/usr/bin/env python3
"""Evaluate one controlled profile experiment on one phone, ROM and kernel."""
import argparse
import hashlib
import json
import math
import re
import statistics
import subprocess
import sys
from pathlib import Path

SCENARIOS = {"screen_off_overhead": 3600, "screen_on_battery": 1800,
             "overnight_idle": 21600, "sustained_game": 1500,
             "scroll_launch": 1, "camera_app_switch": 1, "mixed_io": 1}


def template():
    return {
        "model": "", "rom_fingerprint": "", "kernel": "", "device_alias": "",
        "provenance": {"asb_commit": "", "asb_zip_sha256": "", "kernel_buildinfo_sha256": "", "config_sha256": ""},
        "scenario": "scroll_launch", "workload": "", "factor": "schedutil up rate",
        "A": "", "B": "", "primary": "frame_p95_ms",
        "metrics": {"frame_p95_ms": {"direction": "lower", "tolerance": 0},
                    "frame_p99_ms": {"direction": "lower", "tolerance": None},
                    "surface_peak_c": {"direction": "lower", "tolerance": None},
                    "energy_mah": {"direction": "lower", "tolerance": None}},
        "runs": [],
    }


def finite(value):
    return type(value) in (float, int) and math.isfinite(value)


def known(value):
    return isinstance(value, str) and value.strip().lower() not in {
        "", "?", "unknown", "n/a", "not_measured"}


def evaluate(spec, artifacts_match=False):
    for key in ("model", "rom_fingerprint", "kernel", "device_alias", "workload", "factor", "A", "B"):
        if not known(spec.get(key)):
            raise ValueError(f"missing experiment identity: {key}")
    minimum = SCENARIOS[spec["scenario"]]
    if spec["A"] == spec["B"]:
        raise ValueError("A and B must describe distinct settings")
    primary, metrics = spec["primary"], spec["metrics"]
    if primary not in metrics:
        raise ValueError("primary metric is missing")
    for name, rule in metrics.items():
        if rule["direction"] not in ("lower", "higher") or not finite(rule["tolerance"]) or rule["tolerance"] < 0:
            raise ValueError(f"set direction and absolute tolerance for {name}")

    pairs, seen, excluded = {}, set(), {}
    for run in spec["runs"]:
        pair, label, uid = run["pair"], run["variant"], run["id"]
        if not known(pair) or not known(uid) or uid in seen or label not in ("A", "B"):
            raise ValueError("invalid pair, duplicate run id or unknown variant")
        seen.add(uid)
        rows = pairs.setdefault(pair, [])
        rows.append(run)
        if not known(run.get("conditions")):
            excluded[pair] = "missing conditions"
        elif run.get("excluded_reason"):
            excluded[pair] = str(run["excluded_reason"])
        elif not finite(run.get("duration_s")) or run["duration_s"] < minimum:
            excluded[pair] = "duration below scenario minimum"
        elif any(not finite(run["values"].get(name)) for name in metrics):
            excluded[pair] = "missing metric"

    noise = {name: [] for name in metrics}
    deltas = {name: [] for name in metrics}
    orders = []
    for pair, rows in pairs.items():
        if len(rows) != 2:
            excluded[pair] = "pair requires two runs"
        if pair in excluded:
            continue
        x, y = rows
        order = x["variant"] + y["variant"]
        if x["conditions"] != y["conditions"] or x["duration_s"] != y["duration_s"]:
            excluded[pair] = "conditions or duration changed"
            continue
        if order not in ("AA", "AB", "BA"):
            raise ValueError(f"unsupported order in {pair}")
        if order != "AA":
            orders.append(order)
        for name, rule in metrics.items():
            delta = y["values"][name] - x["values"][name]
            if order == "AA":
                noise[name].append(abs(delta))
            else:
                if order == "BA":
                    delta = -delta
                deltas[name].append(delta if rule["direction"] == "higher" else -delta)

    result = {"status": "insufficient_data", "excluded_pairs": excluded, "orders": orders,
              "aa_pairs": len(noise[primary]), "metrics": {}}
    if not noise[primary] or len(orders) < 3 or any(a == b for a, b in zip(orders, orders[1:])):
        return result
    for name in metrics:
        result["metrics"][name] = {"aa_noise": max(noise[name]),
                                   "median_gain": statistics.median(deltas[name]),
                                   "worst_gain": min(deltas[name])}
    if any(min(deltas[name]) < -rule["tolerance"] for name, rule in metrics.items()):
        result["status"] = "regression"
    elif min(deltas[primary]) > max(noise[primary]):
        result["status"] = "repeatable_gain_in_this_cohort"
    else:
        result["status"] = "inconclusive"
    provenance = spec.get("provenance") or {}
    valid = isinstance(provenance, dict) and all(
        isinstance(provenance.get(key), str) and re.fullmatch(pattern, provenance[key])
        for key, pattern in (("asb_commit", r"[0-9a-fA-F]{40}"),
                             ("asb_zip_sha256", r"[0-9a-fA-F]{64}"),
                             ("kernel_buildinfo_sha256", r"[0-9a-fA-F]{64}"),
                             ("config_sha256", r"[0-9a-fA-F]{64}")))
    if not valid:
        result["artifact_evidence"] = "incomplete"
        if result["status"] == "repeatable_gain_in_this_cohort":
            result["observed_status"] = result["status"]
            result["status"] = "incomplete_provenance"
    elif not artifacts_match:
        result["artifact_evidence"] = "not_verified"
        if result["status"] == "repeatable_gain_in_this_cohort":
            result["observed_status"] = result["status"]
            result["status"] = "unverified_provenance"
    else:
        # Matching supplied files is not proof that this commit built the ZIP or
        # that the files were actually running during the measured session.
        result["artifact_evidence"] = "supplied_files_match_declared_hashes"
    return result


def verify_artifacts(provenance, archive, buildinfo, config, repository):
    def digest(path):
        h = hashlib.sha256()
        with path.open('rb') as src:
            for block in iter(lambda: src.read(1024 * 1024), b''):
                h.update(block)
        return h.hexdigest()
    for name, path in (("asb_zip_sha256", archive), ("kernel_buildinfo_sha256", buildinfo),
                       ("config_sha256", config)):
        if digest(path) != str(provenance.get(name, '')).lower():
            raise ValueError(f"{name} does not match supplied file")
    commit = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], text=True).strip()
    if commit.lower() != str(provenance.get('asb_commit', '')).lower():
        raise ValueError('asb_commit does not match supplied repository HEAD')
    if subprocess.check_output(['git', '-C', str(repository), 'status', '--porcelain'], text=True).strip():
        raise ValueError('supplied repository has uncommitted changes')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trial", nargs="?", type=Path, help="JSON trial; omit to print a blank template")
    parser.add_argument('--asb-zip', type=Path)
    parser.add_argument('--kernel-buildinfo', type=Path)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--repository', type=Path)
    args = parser.parse_args()
    try:
        artifacts = (args.asb_zip, args.kernel_buildinfo, args.config, args.repository)
        if any(artifacts) and (not args.trial or not all(artifacts)):
            raise ValueError('verification needs a trial and all four artifact arguments')
        if args.trial:
            spec = json.loads(args.trial.read_text())
            verified = verify_artifacts(spec.get('provenance') or {}, *artifacts) if all(artifacts) else False
            result = evaluate(spec, artifacts_match=verified)
        else:
            result = template()
    except (OSError, KeyError, TypeError, ValueError, AttributeError, subprocess.CalledProcessError) as exc:
        parser.exit(2, f"trial: {exc}\n")
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
