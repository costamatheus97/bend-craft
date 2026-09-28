#!/bin/bash
# bench/sweep.sh BIN LANE [VAR=VAL ..]: one bench/render.bend run, summarized by tools/gp.py.
# LANE: gpu (BIN a CUDA build, run under tools/gx.sh: the lock, the timeout, the driver check)
# or c1 / c16 (BIN a CPU build). BR_* variables pass through (see bench/render.bend).
BC=$(cd "$(dirname "$0")/.." && pwd)
BIN=$1; LANE=$2; shift 2
if [ "$LANE" = gpu ]; then
  out=$($BC/tools/gx.sh ${GPU_TIMEOUT:-120} sweep "$@" BEND_GPROF=1 $BIN --threads 16 --gpu 3GB 2>&1)
  rc=$?
  [ $rc = 3 ] && { echo "$out" | tail -2; echo STOP; exit 3; }
else
  out=$(env "$@" nice timeout 300 $BIN --threads ${LANE#c} 2>&1)
fi
echo "$LANE $* :: $(echo "$out" | grep '^render' | sed 's/ fb .*//') :: $(echo "$out" | python3 $BC/tools/gp.py ${SKIP:-5})"
