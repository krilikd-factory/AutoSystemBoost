#!/usr/bin/env python3
"""Render one evidence-bounded GitHub Actions summary for an ASB package.

The report reads the actual ZIP and its embedded release manifest. Missing or
broken optional evidence is shown as unavailable; the always-run summary step
must not hide the original build failure with a second failure.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from zipfile import BadZipFile, ZipFile


def md(value: object) -> str:
    text = str(value if value not in (None, "") else "N/A")
    return text.replace("|", "\\|").replace("\n", " ").strip()


def table(lines: list[str], headers: tuple[str, ...], rows: list[tuple[object, ...]]) -> None:
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join("---" for _ in headers) + "|")
    for row in rows:
        lines.append("| " + " | ".join(md(value) for value in row) + " |")
    lines.append("")


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{int(value)} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024
    return f"{size} B"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def properties(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def package_evidence(workspace: Path, zip_value: str) -> dict:
    if not zip_value:
        return {"error": "not generated; the package step did not provide a ZIP"}
    path = Path(zip_value)
    if not path.is_absolute():
        path = workspace / path
    if not path.is_file():
        return {"error": f"not found: {path.name}"}
    result: dict = {"path": path, "name": path.name, "size": path.stat().st_size,
                    "sha256": file_sha256(path), "native": []}
    try:
        with ZipFile(path) as archive:
            bad = archive.testzip()
            if bad:
                result["error"] = f"CRC check failed at {bad}"
                return result
            result["crc"] = "passed"
            result["entries"] = len([item for item in archive.infolist() if not item.is_dir()])
            try:
                result["manifest"] = json.loads(archive.read("release-manifest.json"))
            except (KeyError, UnicodeDecodeError, ValueError) as exc:
                result["manifest_error"] = str(exc)
            try:
                result["module"] = properties(archive.read("module.prop").decode("utf-8"))
            except (KeyError, UnicodeDecodeError) as exc:
                result["module_error"] = str(exc)
            native_names = [
                name for name in archive.namelist()
                if name in ("bin/asb", "bin/asb_dsp_attach")
                or (name.startswith("bin/") and name.endswith(".so"))
                or (name.startswith("zygisk/") and name.endswith(".so"))
            ]
            for name in sorted(native_names):
                data = archive.read(name)
                result["native"].append({"name": name, "size": len(data),
                                         "sha256": hashlib.sha256(data).hexdigest()})
    except (BadZipFile, OSError) as exc:
        result["error"] = f"unreadable ZIP: {exc}"
    return result


def gate(job_status: str, passed: str) -> str:
    if job_status == "success":
        return f"✅ {passed}"
    return "⚠️ Not established by this incomplete/failed run; inspect the failed step"


def yes_no(value: object) -> str:
    return "✅ yes" if value is True else ("❌ no" if value is False else "⚠️ unknown")


def ota_block(lines: list[str], workspace: Path, package: dict, env: dict[str, str], job_status: str) -> None:
    lines += ["## 🔄 OTA manifest", ""]
    if job_status != "success" or package.get("error"):
        lines += ["Not generated for an incomplete or invalid package.", ""]
        return
    module_path = workspace / "module.prop"
    try:
        base = properties(module_path.read_text(encoding="utf-8"))
    except OSError as exc:
        lines += [f"⚠️ Cannot read `module.prop`: {md(exc)}", ""]
        return
    version = base.get("version", "").split("-", 1)[0]
    code = base.get("versionCode", "")
    match = re.fullmatch(r"V([0-9]+)", version)
    repository = env.get("GITHUB_REPOSITORY", "")
    if not match or not code.isdecimal() or not repository:
        lines += ["⚠️ OTA JSON not generated: release version, versionCode or repository is unavailable.", ""]
        return
    release = match.group(1)
    changelog = f"https://raw.githubusercontent.com/{repository}/main/CHANGELOG.md"
    candidate = {
        "version": version,
        "versionCode": int(code),
        "zipUrl": f"https://github.com/{repository}/releases/download/{release}/{package['name']}",
        "changelog": changelog,
    }
    current = None
    try:
        current = json.loads((workspace / "update.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        pass
    state = "✅ Current `update.json` already matches this build" if current == candidate else "⚠️ Publish the release asset first, then update `update.json`"
    lines += [state, "", "```json", json.dumps(candidate, ensure_ascii=False, indent=2), "```", ""]


def render(args: argparse.Namespace, env: dict[str, str]) -> str:
    workspace = Path(args.workspace).resolve()
    package = package_evidence(workspace, args.zip)
    is_release = args.mode == "release"
    title = "Release build" if is_release else "Test build"
    manifest = package.get("manifest") if isinstance(package.get("manifest"), dict) else {}
    module = package.get("module") if isinstance(package.get("module"), dict) else {}
    version = manifest.get("version") or module.get("version") or env.get("ASB_VER") or "unknown"
    code = manifest.get("versionCode") or module.get("versionCode") or "unknown"
    repository = env.get("GITHUB_REPOSITORY", "")
    run_id = env.get("GITHUB_RUN_ID", "")
    server = env.get("GITHUB_SERVER_URL", "https://github.com")
    run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else "not available"
    result_icon = "✅ Success" if args.job_status == "success" else ("⚠️ Cancelled" if args.job_status == "cancelled" else "❌ Failed / incomplete")

    lines = [
        "# ⚡ AutoSystemBoost",
        f"## {'🚀' if is_release else '🧪'} {title} · `{md(version)}`",
        "",
        "> **Evidence boundary:** this page reports CI and host-side checks for the exact package. It does not prove physical ColorOS WebView behavior, charging, panel modes or DSP loading on a device.",
        "",
        "### 🧱 Build identity",
        "",
    ]
    table(lines, ("Field", "Value"), [
        ("Result", result_icon),
        ("Module", module.get("id") or "AutoSystemBoost"),
        ("Version / versionCode", f"{version} / {code}"),
        ("Workflow", "ASB · Build Release" if is_release else "ASB · Build Test"),
        ("Trigger", env.get("GITHUB_EVENT_NAME") or "unknown"),
        ("Ref", env.get("GITHUB_REF_NAME") or "unknown"),
        ("Source commit", manifest.get("source_commit") or env.get("GITHUB_SHA") or "unknown"),
        ("Run", run_url),
    ])

    lines += ["### 📦 Flashable artifact", ""]
    if package.get("error"):
        lines += [f"⚠️ {md(package['error'])}", ""]
    else:
        if is_release:
            if env.get("GITHUB_EVENT_NAME") == "release" and args.job_status == "success":
                publication = "✅ Release-event attach step completed"
            else:
                publication = "Artifact only; no release-asset attach for this trigger"
        else:
            publication = "Test artifact only; never published as a release"
        table(lines, ("Field", "Value"), [
            ("GitHub artifact", f"ASB-{version}"),
            ("Flashable ZIP", package["name"]),
            ("ZIP size", f"{human_size(package['size'])} ({package['size']} bytes)"),
            ("Files / CRC", f"{package.get('entries', 'unknown')} / {package.get('crc', 'unknown')}"),
            ("Distribution", manifest.get("distribution") or "manifest unavailable"),
            ("Publication", publication),
        ])
        lines += ["**ZIP SHA-256**", "", "```text", package["sha256"], "```", ""]

    lines += ["### 🧪 Verification and evidence", ""]
    if args.regression_result == "success":
        regression = "✅ All 3 shards passed: features · system+smart · ui+zygisk+package_tweaks"
    elif args.regression_result:
        regression = f"❌ Regression result: {args.regression_result}"
    else:
        regression = "⚠️ Regression result not recorded"
    if args.upload_outcome == "success":
        upload = "✅ Flashable artifact uploaded"
    elif args.upload_outcome:
        upload = f"⚠️ Artifact upload outcome: {args.upload_outcome}"
    else:
        upload = "⚠️ Not uploaded or outcome unavailable"
    table(lines, ("Gate / evidence", "Result"), [
        ("Host regression", regression),
        ("Native warning budget", gate(args.job_status, "Clang + GCC strict-warning gates passed")),
        ("NDK + ABI checks", gate(args.job_status, "Governor and both Zygisk ABIs built and checked")),
        ("Package validation", gate(args.job_status, "Required files, exclusions and manifest checks passed")),
        ("Artifact upload", upload),
        ("DSP reference payload", yes_no(manifest.get("dsp_reference_present"))),
        ("DSP AIDL package check", yes_no(manifest.get("dsp_aidl_built"))),
        ("DSP runtime on Android", "⚠️ Not run on host; verify audioserver/effect attachment on device"),
    ])

    lines += ["### 🧬 Native package contents", ""]
    native = package.get("native", [])
    if native:
        table(lines, ("Payload", "Size", "SHA-256 prefix"), [
            (item["name"], human_size(item["size"]), item["sha256"][:16]) for item in native
        ])
        lines += ["<details>", "<summary>Full payload SHA-256 values</summary>", "", "```text"]
        lines += [f"{item['sha256']}  {item['name']}" for item in native]
        lines += ["```", "", "</details>", "",
                  "Governor/Zygisk entries are CI NDK outputs. Versioned DSP libraries are staged reference payloads; their presence is not a claim that this run rebuilt them from AOSP.", ""]
    else:
        lines += ["No native payload inventory is available because the ZIP was not generated or read successfully.", ""]

    if is_release:
        ota_block(lines, workspace, package, env, args.job_status)

    lines += [
        "### 📱 Device validation remains separate",
        "",
        "After flashing, verify the selected profile, WebUI, stock/uninstall restore, LTPO behavior, charging and DSP attachment. Report only measured results; host success does not establish a battery or performance percentage.",
        "",
    ]
    return "\n".join(lines).rstrip() + "\n"


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("test", "release"), required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--zip", default="")
    ap.add_argument("--output", required=True)
    ap.add_argument("--job-status", required=True)
    ap.add_argument("--regression-result", default="")
    ap.add_argument("--upload-outcome", default="")
    return ap


def main() -> int:
    args = parser().parse_args()
    output = Path(args.output)
    output.write_text(render(args, dict(os.environ)), encoding="utf-8")
    print(f"ASB build summary written: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
