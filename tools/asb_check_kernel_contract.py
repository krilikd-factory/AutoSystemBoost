#!/usr/bin/env python3
"""Compare the checked-in AWL fixture with ASB and a supplied kernel checkout."""
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
kernel = Path(sys.argv[1]).resolve()
a = json.loads((root / 'docs/field_baseline/asb-kernel-contract.json').read_text())
k = json.loads((kernel / 'docs/asb-kernel-contract.json').read_text())
if a != k:
    sys.exit('AWL contract fixtures differ')
source = (root / 'runtime/asb_wakeup_blocker.sh').read_text()
patch = (kernel / '.github/patches/android16-6.12/asb-wakeup-blocker-6.12.69.patch').read_text()
for path in a['paths']:
    if a['root'] + '/' + path not in source or '__ATTR(' + path + ',' not in patch:
        sys.exit('AWL path mismatch: ' + path)
for name, value in [('ASB_WAKEUP_ABI_VERSION', a['abi']), ('ASB_WAKEUP_MAX_RULES', a['max_rules']), ('ASB_WAKEUP_NAME_MAX', a['max_name_bytes'])]:
    if not re.search(r'#define\s+' + name + r'\s+' + str(value) + r'\b', patch):
        sys.exit('AWL kernel limit mismatch: ' + name)
if '[ "${#1}" -le ' + str(a['max_name_bytes']) + ' ]' not in source or '[ "$_wb_count" -le ' + str(a['max_rules']) + ' ]' not in source:
    sys.exit('AWL ASB limits differ')
print('AWL fixture, ASB paths and kernel limits agree; runtime discovery is still required')
