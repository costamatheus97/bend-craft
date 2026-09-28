# pp.py [SKIP]: a play.bend run (PLAY_LOG=1, gprof L0 on stderr, the hw harness) summarized:
# per stage median / p95 / p99 in ms (sim, render = the bang, show = Window.frame, loop = the
# three), the harness's fill and frame interval, and gprof medians (turn, up, wait, down).
import sys, re, statistics as st
skip = int(sys.argv[1]) if len(sys.argv) > 1 else 30
cols = {'sim': [], 'render': [], 'show': [], 'us': []}; g = {}; hw = ''
for l in sys.stdin:
    m = re.match(r'frame (\d+) sim (\d+) render (\d+) show (\d+) us (\d+)', l)
    if m and int(m.group(1)) >= skip:
        for k, i in (('sim', 2), ('render', 3), ('show', 4), ('us', 5)): cols[k].append(int(m.group(i)))
    if l.startswith('turn '):
        for k, v in re.findall(r'(\w+)=(\d+)', l): g.setdefault(k, []).append(int(v))
    if l.startswith('HW '): hw += ('\n  ' if hw else '') + l.strip()
def pct(v, p): s = sorted(v); return s[min(len(s) - 1, int(p * len(s)))]
out = []
for k in ('sim', 'render', 'show', 'us'):
    v = cols[k]
    if v: out.append("%s %.2f/%.2f/%.2f" % ('loop' if k == 'us' else k, st.median(v) / 1e3, pct(v, .95) / 1e3, pct(v, .99) / 1e3))
if g: out.append("gprof turn %.2f up %.2f wait %.2f down %.2f" % tuple(st.median(g[k][skip:]) / 1e6 for k in ('turn', 'up', 'wait', 'down')))
print(" | ".join(out) + ("\n  " + hw if hw else ''))
