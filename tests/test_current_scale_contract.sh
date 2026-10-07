#!/bin/sh
# Contract + simulation: the governor measures the battery-current gauge scale.
# A gauge that reports half the real current (OnePlus 15) must come out near 0.5; screen-off
# time and charging must not contaminate the window.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL current scale: $*" >&2; fail=1; }
grep -q 'current_scale_x100=%d' "$G" || f "scale not published"
[ "$(grep -c 'asb_curscale_track(metrics.misc.screen_on' "$G")" -ge 2 ] || f "not called on both tick paths"
command -v gcc >/dev/null 2>&1 || { [ "$fail" = 0 ] && echo "PASS current scale (contract only, no gcc)"; exit "$fail"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 - "$G" "$T" <<'PY' || { echo "FAIL current scale: extraction" >&2; exit 1; }
import sys
s=open(sys.argv[1]).read(); t=sys.argv[2]
a=s.index('#define ASB_CURSCALE_FILE'); b=s.index('/* Called once per tick. screen_on resets the window')
code=s[a:b].replace('"/data/adb/asb/current_scale_x100"','"%s/cs"' % t)
main=r'''
int main(int argc,char**argv){ double gauge=atof(argv[1]); int pct; int t;
 for(t=0;t<5*3600;t+=5){ g_now=t*1000L;
   double used=700.0*t/3600.0; pct=85-(int)(used*100/7300);
   int scr=(t/600)%3!=2;
   int chg=(t>=3*3600 && t<3*3600+600);    /* a charger plugged in briefly */
   asb_curscale_track(scr,pct,chg,(int)(700.0*gauge)); }
 printf("%d %d\n",g_curscale_x100,g_curscale_n); return 0;}
'''
open(t+'/t.c','w').write('#include <stdio.h>\n#include <stdlib.h>\n#include <time.h>\nstatic long g_now=0;\nstatic long asb_clock_ms(int c){(void)c;return g_now;}\nstatic long sysfs_read_long(const char*p,long d){(void)p;(void)d;return 7300000;}\n'+code+main)
PY
gcc -Wall -Werror -o "$T/t" "$T/t.c" || { echo "FAIL current scale: compile" >&2; exit 1; }
set -- $("$T/t" 0.5); [ "$1" -ge 42 ] && [ "$1" -le 58 ] && [ "$2" -ge 2 ] || f "half-reading gauge measured as $1 ($2 windows)"
rm -f "$T/cs"
set -- $("$T/t" 1.0); [ "$1" -ge 88 ] && [ "$1" -le 112 ] || f "true gauge measured as $1"
[ "$fail" = 0 ] && echo "PASS current scale"
exit "$fail"
