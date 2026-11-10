#!/usr/bin/env python3
"""Make a packaged module smaller without changing what any of it does (V66 dev9).

Run by both packaging workflows on the staged package directory (never on the source tree):

  - webroot/i18n/*.json: re-written without indentation. The WebUI parses them with
    JSON.parse, so the objects are the same; a reader that loads both copies must get equal
    objects, or the file is left as it was.
  - webroot/index.html: comment LINES are removed from the <script> and <style> blocks - a
    line that is only a `// ...` comment, or a `/* ... */` block that starts a line and ends
    a line. Nothing that shares a line with code is touched, so no string, regex literal or
    URL can be cut. This is only safe because the page has no template literals and no
    line-continued strings (checked below: either one present makes this step a no-op); a
    block carrying a build marker (ASB_UI_BUILD) is kept. Every script block must still
    compile with `node --check` when node is there, and asbdiag's reading of the settings
    registry (CFG_ITEMS, CFG_GROUP_OF, APPLY_MODE lines) must come out the same.

Shell scripts are deliberately left alone: a comment line inside a here-document or a
multi-line quoted string is data there, and a boot script is the last place for a guess.

Usage: asb_slim_package.py <package-dir> [--check-only]
Exit 0 with a one-line summary; non-zero only when a check failed after a change, in which
case the files are restored.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MARKERS = ("ASB_UI_BUILD",)


def slim_json(path):
    raw = open(path, "rb").read()
    obj = json.loads(raw.decode("utf-8"))
    out = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if json.loads(out.decode("utf-8")) != obj or len(out) >= len(raw):
        return 0
    open(path, "wb").write(out)
    return len(raw) - len(out)


def strip_comment_lines(code, allow_line_comments):
    lines = code.split("\n")
    out = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if allow_line_comments and s.startswith("//"):
            i += 1
            continue
        if s.startswith("/*"):
            start = ln.find("/*") + 2
            j, pos = i, ln.find("*/", start)
            while pos < 0:
                j += 1
                if j >= len(lines):
                    break
                pos = lines[j].find("*/")
            if j >= len(lines):
                out.extend(lines[i:])
                break
            tail = lines[j][pos + 2:]
            block = "\n".join(lines[i:j + 1])
            if tail.strip() == "" and not any(m in block for m in MARKERS):
                i = j + 1
                continue
            out.extend(lines[i:j + 1])
            i = j + 1
            continue
        out.append(ln)
        i += 1
    return "\n".join(out)


def slim_html(path):
    html = open(path, encoding="utf-8").read()
    scripts = re.findall(r"<script[^>]*>([\s\S]*?)</script>", html)
    js = "".join(scripts)
    code_only = re.sub(r"/\*[\s\S]*?\*/", "", js)
    code_only = re.sub(r"(?m)^\s*//[^\n]*", "", code_only)
    code_only = re.sub(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"", "''", code_only)
    if "`" in code_only or re.search(r"\\\n", js):
        return 0, "skipped: template literal or continued string"

    def fix_script(m):
        return m.group(1) + strip_comment_lines(m.group(2), True) + m.group(3)

    def fix_style(m):
        return m.group(1) + strip_comment_lines(m.group(2), False) + m.group(3)

    out = re.sub(r"(<script[^>]*>)([\s\S]*?)(</script>)", fix_script, html)
    out = re.sub(r"(<style[^>]*>)([\s\S]*?)(</style>)", fix_style, out)
    if len(out) >= len(html):
        return 0, "nothing to strip"
    open(path, "w", encoding="utf-8").write(out)
    return len(html) - len(out), "ok"


def node_check(path):
    node = shutil.which("node")
    if not node:
        return True, "node not found - compile check skipped"
    html = open(path, encoding="utf-8").read()
    with tempfile.TemporaryDirectory() as td:
        for n, m in enumerate(re.findall(r"<script[^>]*>([\s\S]*?)</script>", html)):
            f = os.path.join(td, "s%d.js" % n)
            open(f, "w", encoding="utf-8").write(m)
            r = subprocess.run([node, "--check", f], capture_output=True, text=True)
            if r.returncode != 0:
                return False, "script %d: %s" % (n, (r.stderr or r.stdout).strip()[:300])
    return True, "node --check ok"


def registry_rows(html_text):
    """The same lines asbdiag's _ux_web_rows awk reads, in order."""
    rows = []
    zone = None
    for ln in html_text.split("\n"):
        if ln.startswith("const CFG_ITEMS = ["):
            zone = "it"
        elif ln.startswith("const CFG_GROUP_OF = {"):
            zone = "gr"
        elif ln.startswith("const APPLY_MODE = {"):
            zone = "am"
        if zone and (re.search(r"\{ key:'[A-Za-z0-9_]+'", ln) or re.search(r" name:'", ln)
                     or re.search(r"[A-Za-z0-9_]+:'(audio|camera|iface|net|battery|ui)'", ln)
                     or re.search(r"[A-Za-z0-9_]+:APPLY_REBOOT", ln)):
            rows.append(ln.strip())
        if ln.startswith("];") or ln.startswith("};"):
            zone = None
    return rows


def main():
    if len(sys.argv) < 2:
        print("usage: asb_slim_package.py <package-dir> [--check-only]", file=sys.stderr)
        return 2
    root = sys.argv[1]
    check_only = "--check-only" in sys.argv[2:]
    web = os.path.join(root, "webroot")
    idx = os.path.join(web, "index.html")
    i18n = os.path.join(web, "i18n")
    if not os.path.isfile(idx):
        print("asb_slim_package: no webroot/index.html under %s" % root, file=sys.stderr)
        return 2
    backup = tempfile.mkdtemp(prefix="asb_slim_")
    try:
        shutil.copy2(idx, os.path.join(backup, "index.html"))
        before_rows = registry_rows(open(idx, encoding="utf-8").read())
        saved_json = 0
        names = sorted(n for n in os.listdir(i18n) if n.endswith(".json")) if os.path.isdir(i18n) else []
        for n in names:
            shutil.copy2(os.path.join(i18n, n), os.path.join(backup, n))
        if check_only:
            ok, why = node_check(idx)
            print("asb_slim_package: check-only, %s" % why)
            return 0 if ok else 1
        for n in names:
            saved_json += slim_json(os.path.join(i18n, n))
        saved_html, why = slim_html(idx)
        ok, nwhy = node_check(idx)
        after_rows = registry_rows(open(idx, encoding="utf-8").read())
        if not ok or after_rows != before_rows:
            shutil.copy2(os.path.join(backup, "index.html"), idx)
            for n in names:
                shutil.copy2(os.path.join(backup, n), os.path.join(i18n, n))
            print("asb_slim_package: FAILED (%s; registry rows %s) - originals restored"
                  % (nwhy, "same" if after_rows == before_rows else "changed"), file=sys.stderr)
            return 1
        print("asb_slim_package: translations -%d bytes, page -%d bytes (%s; %s)"
              % (saved_json, saved_html, why, nwhy))
        return 0
    finally:
        shutil.rmtree(backup, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
