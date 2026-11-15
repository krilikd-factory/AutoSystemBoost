#!/usr/bin/env python3
"""Validate and compare declared OnePlus 15 scheduler field captures.

This host tool checks JSON structure and A/B identity only. It does not collect device
metrics, independently attest a capture, or turn a numeric delta into an improvement claim.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

METRIC_NAMES = (
    "frame_time_p95_ms",
    "frame_time_p99_ms",
    "jank_percent",
    "cpu_residency",
    "temperature_c",
    "battery_current_ma",
    "battery_drain_percent_per_hour",
    "network_latency_ms",
    "network_jitter_ms",
    "thermal_throttling_duration_s",
    "kernel_logs",
    "asb_counters",
)
IDENTITY_KEYS = ("root", "susfs", "asb", "feature_set")
KERNEL_KEYS = ("release", "version", "source_commit", "family")
MAX_CAPTURE_BYTES = 8 * 1024 * 1024


class CaptureError(ValueError):
    pass


def _object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CaptureError(f"{where} must be an object")
    return value


def _text(value: Any, where: str, *, provenance: bool = False) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 240:
        raise CaptureError(f"{where} must be a non-empty bounded string")
    value = value.strip()
    if provenance and value.lower() in {"unknown", "not_recorded", "not measured", "not_measured"}:
        raise CaptureError(f"{where} has no recorded identity")
    return value


def _number(value: Any, where: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CaptureError(f"{where} must be numeric")
    if not math.isfinite(value):
        raise CaptureError(f"{where} must be finite")
    return value


def _is_number(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def _load(path: Path) -> dict[str, Any]:
    if path.stat().st_size > MAX_CAPTURE_BYTES:
        raise CaptureError(f"{path}: capture exceeds {MAX_CAPTURE_BYTES} bytes")

    def invalid_constant(value: str) -> None:
        raise CaptureError(f"{path}: non-finite JSON number {value}")

    try:
        data = json.loads(path.read_text(encoding="utf-8"), parse_constant=invalid_constant)
    except json.JSONDecodeError as exc:
        raise CaptureError(f"{path}: invalid JSON: {exc}") from exc
    return _object(data, str(path))


def _numeric_leaves(value: Any, prefix: str = "metrics") -> dict[str, int | float]:
    if _is_number(value):
        return {prefix: value}
    found: dict[str, int | float] = {}
    if isinstance(value, dict):
        for key in sorted(value):
            if not isinstance(key, str) or not key:
                raise CaptureError(f"{prefix} contains an invalid key")
            found.update(_numeric_leaves(value[key], f"{prefix}.{key}"))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.update(_numeric_leaves(item, f"{prefix}[{index}]"))
    return found


def _validate_json_value(value: Any, where: str, depth: int = 0) -> None:
    if depth > 24:
        raise CaptureError(f"{where} is nested too deeply")
    if value is None or isinstance(value, (str, bool)) or _is_number(value):
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not key:
                raise CaptureError(f"{where} contains an invalid key")
            _validate_json_value(item, f"{where}.{key}", depth + 1)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, f"{where}[{index}]", depth + 1)
        return
    raise CaptureError(f"{where} contains a non-JSON or non-finite value")


def validate_capture(data: dict[str, Any]) -> dict[str, Any]:
    if data.get("schema") != 1 or data.get("kind") != "asb_scheduler_capture":
        raise CaptureError("capture must use schema=1 and kind=asb_scheduler_capture")
    status = data.get("status")
    if status not in {"not_measured", "measured"}:
        raise CaptureError("capture status must be not_measured or measured")
    metrics = _object(data.get("metrics"), "metrics")
    if set(metrics) != set(METRIC_NAMES):
        missing = sorted(set(METRIC_NAMES) - set(metrics))
        extra = sorted(set(metrics) - set(METRIC_NAMES))
        raise CaptureError(f"metrics schema mismatch; missing={missing}, extra={extra}")
    _validate_json_value(metrics, "metrics")
    numeric = _numeric_leaves(metrics)
    if status == "not_measured":
        non_null = [key for key, value in metrics.items() if value is not None]
        if non_null:
            raise CaptureError(f"not_measured capture has non-null metrics: {non_null}")
        return {"status": status, "numeric_metric_count": 0}

    _text(data.get("label"), "label")
    kernel = _object(data.get("kernel"), "kernel")
    for key in ("release", "version", "family"):
        _text(kernel.get(key), f"kernel.{key}", provenance=True)
    commit = _text(kernel.get("source_commit"), "kernel.source_commit", provenance=True)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        raise CaptureError("kernel.source_commit must be an exact 40-hex commit")
    bore = _object(data.get("bore"), "bore")
    if bore.get("build_config") not in {"y", "n", "unknown"}:
        raise CaptureError("bore.build_config must be y, n or unknown")
    if bore.get("runtime") not in {"0", "1", "off", "on"}:
        raise CaptureError("a measured capture must record BORE runtime as 0/1 or off/on")
    identity = _object(data.get("identity"), "identity")
    for key in IDENTITY_KEYS:
        _text(identity.get(key), f"identity.{key}", provenance=True)
    workload = _object(data.get("workload"), "workload")
    _text(workload.get("name"), "workload.name")
    if _number(workload.get("duration_s"), "workload.duration_s") <= 0:
        raise CaptureError("workload.duration_s must be positive")
    if workload.get("screen") not in {"on", "off"}:
        raise CaptureError("a measured workload must record screen as on or off")
    thermal = _object(data.get("thermal_state"), "thermal_state")
    for key in ("start_skin_c", "start_cpu_c"):
        if thermal.get(key) is not None:
            _number(thermal[key], f"thermal_state.{key}")
    if thermal.get("throttled_at_start") not in {True, False, "unknown"}:
        raise CaptureError("thermal_state.throttled_at_start must be true, false or unknown")
    if not numeric:
        raise CaptureError("a measured capture must contain at least one numeric metric")
    return {"status": status, "numeric_metric_count": len(numeric)}


def capture_template(family: str = "", source_commit: str = "not_recorded",
                     feature_set: str = "") -> dict[str, Any]:
    return {
        "schema": 1,
        "kind": "asb_scheduler_capture",
        "status": "not_measured",
        "label": "",
        "kernel": {"release": "", "version": "", "source_commit": source_commit, "family": family},
        "bore": {"build_config": "unknown", "runtime": "unknown"},
        "identity": {"root": "", "susfs": "", "asb": "", "feature_set": feature_set},
        "workload": {"name": "", "duration_s": None, "screen": "unknown"},
        "thermal_state": {"start_skin_c": None, "start_cpu_c": None, "throttled_at_start": "unknown"},
        "metrics": {name: None for name in METRIC_NAMES},
    }


def _leaves(value: Any, prefix: str = "metrics") -> dict[str, Any]:
    if isinstance(value, dict) and value:
        result: dict[str, Any] = {}
        for key in sorted(value):
            result.update(_leaves(value[key], f"{prefix}.{key}"))
        return result
    if isinstance(value, list) and value:
        result = {}
        for index, item in enumerate(value):
            result.update(_leaves(item, f"{prefix}[{index}]"))
        return result
    return {prefix: value}


def _bore_on(value: str) -> bool:
    return value in {"1", "on"}


def compare_captures(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    validate_capture(baseline)
    validate_capture(candidate)
    if baseline["status"] != "measured" or candidate["status"] != "measured":
        raise CaptureError("comparison requires two measured captures; not_measured stays unmeasured")
    for key in KERNEL_KEYS:
        if baseline["kernel"].get(key) != candidate["kernel"].get(key):
            raise CaptureError(f"BORE A/B kernel identity differs: {key}")
    for key in IDENTITY_KEYS:
        if baseline["identity"].get(key) != candidate["identity"].get(key):
            raise CaptureError(f"BORE A/B identity differs: {key}")
    if baseline["workload"] != candidate["workload"]:
        raise CaptureError("BORE A/B workload identity differs (name, duration, screen or metadata)")
    if baseline["bore"].get("build_config") != candidate["bore"].get("build_config"):
        raise CaptureError("BORE build_config differs inside a runtime A/B pair")
    if _bore_on(baseline["bore"]["runtime"]) or not _bore_on(candidate["bore"]["runtime"]):
        raise CaptureError("comparison direction must be baseline BORE off -> candidate BORE on")

    b_leaves = _leaves(baseline["metrics"])
    c_leaves = _leaves(candidate["metrics"])
    compared: dict[str, Any] = {}
    for key in sorted(set(b_leaves) | set(c_leaves)):
        b_value = b_leaves.get(key)
        c_value = c_leaves.get(key)
        delta = None
        if _is_number(b_value) and _is_number(c_value):
            status = "measured"
            delta = c_value - b_value
        elif b_value is None and c_value is None:
            status = "not_measured"
        elif _is_number(b_value) or _is_number(c_value):
            status = "not_comparable"
        else:
            status = "recorded_not_compared"
        compared[key] = {"baseline": b_value, "candidate": c_value, "delta": delta, "status": status}

    b_thermal = baseline["thermal_state"]
    c_thermal = candidate["thermal_state"]
    thermal_deltas: dict[str, Any] = {}
    for key in ("start_skin_c", "start_cpu_c"):
        b_value, c_value = b_thermal.get(key), c_thermal.get(key)
        thermal_deltas[key] = (c_value - b_value) if _is_number(b_value) and _is_number(c_value) else None
    return {
        "schema": 1,
        "kind": "scheduler_ab_comparison",
        "status": "measured",
        "comparison": "same_kernel_bore_off_to_on",
        "baseline_label": baseline["label"],
        "candidate_label": candidate["label"],
        "kernel": baseline["kernel"],
        "identity": baseline["identity"],
        "workload": baseline["workload"],
        "bore": {
            "build_config": baseline["bore"]["build_config"],
            "baseline_runtime": baseline["bore"]["runtime"],
            "candidate_runtime": candidate["bore"]["runtime"],
        },
        "thermal_comparability": {
            "baseline": b_thermal,
            "candidate": c_thermal,
            "start_delta_c": thermal_deltas,
        },
        "metrics": compared,
        "improvement_claim": "not_computed",
        "evidence_scope": "Host schema/identity comparison of declared field captures; values are not independently attested and deltas are not verdicts.",
    }


def _emit(report: dict[str, Any], output: Path | None) -> None:
    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if output:
        output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    template = commands.add_parser("template", help="write an explicitly not_measured capture template")
    template.add_argument("--output", required=True, type=Path)
    template.add_argument("--family", default="")
    template.add_argument("--source-commit", default="not_recorded")
    template.add_argument("--feature-set", default="")
    validate = commands.add_parser("validate", help="validate one field capture without inventing values")
    validate.add_argument("capture", type=Path)
    validate.add_argument("--output", type=Path)
    compare = commands.add_parser("compare", help="compare a same-kernel BORE off/on field pair")
    compare.add_argument("baseline", type=Path)
    compare.add_argument("candidate", type=Path)
    compare.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "template":
            data = capture_template(args.family, args.source_commit, args.feature_set)
            validate_capture(data)
            _emit(data, args.output)
        elif args.command == "validate":
            data = _load(args.capture)
            result = validate_capture(data)
            _emit({"schema": 1, "kind": "scheduler_ab_capture_validation", **result,
                   "evidence_scope": "schema only; field values are not independently attested"}, args.output)
        else:
            _emit(compare_captures(_load(args.baseline), _load(args.candidate)), args.output)
        return 0
    except (OSError, CaptureError) as exc:
        print(f"scheduler A/B error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
