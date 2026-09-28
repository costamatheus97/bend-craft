# med.py KEY [SKIP]: median / min / p95 of the number after KEY on stdin's lines (after SKIP lines)
import sys, re, statistics as st
k = sys.argv[1]; skip = int(sys.argv[2]) if len(sys.argv) > 2 else 1
v = [int(m.group(1)) for l in sys.stdin for m in [re.search(r'\b' + re.escape(k) + r' (\d+)', l)] if m][skip:]
if not v: print("n=0"); sys.exit()
s = sorted(v)
print("n=%d med=%.3f min=%.3f p95=%.3f" % (len(v), st.median(v) / 1000, s[0] / 1000, s[min(len(s) - 1, int(0.95 * len(s)))] / 1000))
