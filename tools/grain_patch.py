#!/usr/bin/env python3
# grain_patch.py OUT.c [K]: a harness-only patch (never shipped) that measures an upstream proposal for the CPU
# pool. cube_run grows the frontier to ceil(pool_size / 8) cube rows, so a render turn has exactly pool_size units
# (16 rings each), and a unit runs its whole subtree: a worker that lands on a shared core holds up the turn and
# nobody can take its work. This grows the frontier to K x pool_size units (K from the argument, else $GRAIN, else
# 4), so the others take the rest. The frames are the same; only the schedule changes.
import sys, os
p=sys.argv[1]; k=sys.argv[2] if len(sys.argv)>2 else os.environ.get('GRAIN','4'); s=open(p).read()
old='''      if (f * (CUBE_T / LINE) < pool_size) {
        row_grow((Env){ H, ALC[0] }, io_stk, 0, CUBE_G,
          (pool_size + CUBE_T / LINE - 1) / (CUBE_T / LINE));
      }'''
new='''      if (f * (CUBE_T / LINE) < %s * pool_size) {
        row_grow((Env){ H, ALC[0] }, io_stk, 0, CUBE_G,
          (%s * pool_size + CUBE_T / LINE - 1) / (CUBE_T / LINE));
      }''' % (k, k)
assert s.count(old)==1; s=s.replace(old,new); open(p,'w').write(s)
