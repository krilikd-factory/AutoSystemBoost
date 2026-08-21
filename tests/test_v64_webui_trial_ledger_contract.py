#!/usr/bin/env python3
"""Host contract for the V64 Trial/Ledger WebUI safety surface."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
HTML = (ROOT / 'webroot/index.html').read_text(encoding='utf-8')
TRIAL = (ROOT / 'runtime/asb_trial.sh').read_text(encoding='utf-8')
errors = []

def require(needle: str, message: str) -> None:
    if needle not in HTML:
        errors.append(message)

def before(first: str, second: str, message: str) -> None:
    a, b = HTML.find(first), HTML.find(second)
    if a < 0 or b < 0 or a >= b:
        errors.append(message)

# WebUI bridge contract: ksu.exec resolves {errno, stdout, stderr}; a shell failure does not
# reject the Promise. Trial/Ledger must therefore never treat a result object as a string.
require("ok({errno:e, stdout:o||'', stderr:r||''})", 'run() result object contract missing')
require("function runText(result)", 'missing safe bridge output helper')
require("function runOk(result)", 'missing bridge errno helper')
require("const raw = (result && result.stdout) || '';", 'ledger/trial loader does not use run().stdout')
require("if (!runOk(pv))", 'preview failure is not checked before confirmation')
require("if (!runOk(out))", 'trial start/action does not check run().errno')
require("const text = runText(out);", 'trial command output is not normalized from stdout/stderr')

# UI Trial keys must exactly match the runtime allowlist. A button without backend support is a
# release blocker because it promises a transaction that the device will always reject.
ui_match = re.search(r"const TRIAL_KEYS\s*=\s*\[([^]]*)\]", HTML, re.S)
ui_keys = set(re.findall(r"'([A-Za-z][A-Za-z0-9_]*)'", ui_match.group(1) if ui_match else ''))
backend_match = re.search(r"_trial_key_allowed\(\) \{.*?case .*? in\s*(.*?)\)\s*return 0", TRIAL, re.S)
backend_text = (backend_match.group(1) if backend_match else '').replace('\\\n', ' ')
backend_keys = set(re.findall(r"[A-Za-z][A-Za-z0-9_]*", backend_text))
if ui_keys != backend_keys:
    errors.append(f'Trial key mismatch: UI-only={sorted(ui_keys-backend_keys)}, backend-only={sorted(backend_keys-ui_keys)}')
if 'perf_ceiling_pct' in ui_keys:
    errors.append('perf_ceiling_pct shown as Trial without backend semantic contract')

# Device rejection is factual outcome and must outrank an informational active-trial badge.
before('const _lb = ledgerBadge(it.key);', 'const _tl = trialHoursLeft(it.key);',
       'ledger rejection must outrank active trial in cfgStatus')
require("if (trialExpired(it.key)) return { cls:'warn', text: T('trial_expired_wait'", 'missing expired Trial status')
before('} else if (trialExpired(it.key)) {', "b.textContent = T('trial_try'", 
       'expired record can still expose a second Trial start button')

# First render must wait for safety evidence, preventing a false successful-looking card.
require('await cfgLoadV64State();\n  cfgRender();', 'V64 evidence is not awaited before first cfgRender')

# All user-facing V64 Trial/Ledger terms need every shipped locale and valid JSON.
keys = sorted(set(re.findall(r"T\('(trial_[A-Za-z0-9_]+|st_[A-Za-z0-9_]+|ledger_[A-Za-z0-9_]+)'", HTML)))
locales = sorted((ROOT / 'webroot/i18n').glob('*.json'))
if len(locales) != 13:
    errors.append(f'expected 13 locale files, found {len(locales)}')
for locale in locales:
    try:
        data = json.loads(locale.read_text(encoding='utf-8'))
    except Exception as exc:
        errors.append(f'{locale.name}: invalid JSON: {exc}')
        continue
    missing = [key for key in keys if key not in data]
    if missing:
        errors.append(f'{locale.name}: missing V64 keys {missing}')

if errors:
    print('FAIL V64 WebUI Trial/Ledger contract')
    for error in errors:
        print(' -', error)
    sys.exit(1)
print('PASS V64 WebUI Trial/Ledger contract')
print('trial keys:', ', '.join(sorted(ui_keys)))
print('locale files:', len(locales))
