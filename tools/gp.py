# gp.py [SKIP]: one summary line from a bench run's output on stdin: the frame time (from
# "frame <i> us <us>") as median / p95 / p99, and the medians of the gprof L0 turn fields
# (turn, up, run, down, wait), in ms, after SKIP warm-up frames and turns.
import sys, re, statistics as st
skip = int(sys.argv[1]) if len(sys.argv) > 1 else 5
fr, g = [], {}
for l in sys.stdin:
    m = re.match(r'frame \d+ us (\d+)', l)
    if m: fr.append(int(m.group(1)))
    if l.startswith('turn '):
        for k, v in re.findall(r'(\w+)=(\d+)', l):
            g.setdefault(k, []).append(int(v))
fr = fr[skip:]
def pct(v, p): s = sorted(v); return s[min(len(s) - 1, int(p * len(s)))]
out = []
if fr: out.append("frame med %.2f p95 %.2f p99 %.2f n %d" % (st.median(fr) / 1e3, pct(fr, .95) / 1e3, pct(fr, .99) / 1e3, len(fr)))
for k in ['turn', 'up', 'run', 'down', 'wait']:
    if k in g and len(g[k]) > skip: out.append("%s %.2f" % (k, st.median(g[k][skip:]) / 1e6))
if 'passes' in g: out.append("passes %d" % g['passes'][-1])
print(" | ".join(out))
