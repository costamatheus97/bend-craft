#!/usr/bin/env python3
# loc_patch.py OUT.c: a harness-only patch (never shipped) that measures what hoisting a shared
# array's location out of a read loop is worth (an upstream proposal, not a change we ship).
# Bend reads a shared (@unsafe, refcounted) array through blk_loc, which loads the refcount cell
# for the location on every read; on AMD the wait for that load (vmcnt counts in order) also
# waits for every earlier read, so a lane can never have two reads in flight. In render.bend's
# ray loop (the FAR spin function whose calls read the scene array) the handle never changes,
# so the patch loads the location once before the loop and passes it down to copies of the
# read helpers (suffix L) that use it instead of blk_loc.
import re, sys
p = sys.argv[1]; s = open(p).read()
fun = {}
for m in re.finditer(r'^(INLINE|FAR) Term (spin_\d+)\((Env e, THR Term\* o[^)]*)\) \{\n(.*?)\n\}\n', s, re.M | re.S):
    fun[m.group(2)] = m
calls = lambda body: set(re.findall(r'\b(spin_\d+)\(e, ', body))
reads = set()
changed = True
while changed:
    changed = False
    for n, m in fun.items():
        if n in reads or m.group(1) != 'INLINE': continue
        b = m.group(4)
        if 'blk_write' in b: continue
        if 'blk_loc(e.mem' in b or calls(b) & reads:
            reads.add(n); changed = True
# the target: a FAR loop over the scene (self tail call) whose body calls a read helper with its handle var
tgt = None
for n, m in fun.items():
    b = m.group(4)
    if m.group(1) == 'FAR' and ('WL_AGAIN(%s,' % n) in b and 'blk_write' not in b and calls(b) & reads:
        h = re.search(r'if \((spin_\d+)\(e, _o_\d+, [^;]*?(_r_\d+)\) == 0\)', b)
        if h and h.group(1) in reads and re.search(r'Term %s = r\d+;' % h.group(2), b):
            tgt = (n, h.group(2)); break
assert tgt, 'no target loop'
need = set(); todo = [c for c in calls(fun[tgt[0]].group(4)) if c in reads]
while todo:
    c = todo.pop()
    if c in need: continue
    need.add(c); todo += [d for d in calls(fun[c].group(4)) if d in reads]
def lcall(body):
    for c in need:
        body = re.sub(r'\b%s\(e, ([^;]*?)\) == 0\)' % c, lambda m: '%sL(e, %s, loc) == 0)' % (c, m.group(1)), body)
    return body
out = s
for c in need:
    m = fun[c]
    body = re.sub(r'blk_loc\(e\.mem, _\w+\)', 'loc', m.group(4))
    cp = 'INLINE Term %sL(%s, u64 loc) {\n%s\n}\n' % (c, m.group(3), lcall(body))
    out = out.replace(m.group(0), m.group(0) + cp, 1)
n, hv = tgt
m = fun[n]
b = lcall(m.group(4))
b = re.sub(r'(Term %s = r\d+;)' % hv, r'\1\n  u64 loc = blk_loc(e.mem, %s);' % hv, b, count=1)
out = out.replace(m.group(4), b, 1)
open(p, 'w').write(out)
print('loc_patch: %s (handle %s) reads through %s' % (n, hv, ', '.join(sorted(c + 'L' for c in need))))
