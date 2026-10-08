#!/bin/sh
# Contract: every _helper called at command position in a device script is defined in that
# script (or, for the logkit, in its common library). smart_dynamic_tune.sh called an
# undefined _cfg, so wifi_powersave silently never applied.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP undefined-function contract (no python3)"; exit 0; }
python3 - "$ROOT" <<'PY'
import re,glob,os,sys
root=sys.argv[1]; os.chdir(root)
files=glob.glob('runtime/*.sh')+['action.sh','service.sh','post-fs-data.sh','apply_profile.sh','uninstall.sh','tools/asb_diag.sh']+glob.glob('tools/logkit/*.sh')
dre=re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)',re.M)
alld={f:set(dre.findall(open(f).read())) for f in files}
bad=[]
for f in files:
    d=alld[f]
    if 'logkit' in f: d=d|alld.get('tools/logkit/_asb_logkit_common.sh',set())
    for i,line in enumerate(open(f).read().split('\n'),1):
        t=line.strip()
        if t.startswith('#'): continue
        t=re.sub(r'\$\(\([^)]*\)\)','',t)
        for m in re.finditer(r'(?:^|;\s*|&&\s*|\|\|\s*|\|\s*|\$\(\s*|\b(?:then|do|else)\s+)(_[a-z][a-z0-9_]*)(?=\s|$|\)|;)',t):
            if re.match(r'\s*=', t[m.end():]): continue
            if m.group(1) not in d: bad.append('%s:%d %s'%(f,i,m.group(1)))
if bad:
    print('FAIL undefined shell functions:\n  '+'\n  '.join(bad), file=sys.stderr); sys.exit(1)
print('PASS undefined-function contract')
PY
