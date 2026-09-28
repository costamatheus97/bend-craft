#!/bin/bash
# bench/abp.sh ROUNDS "BIN.." [VAR=VAL ..]: interleaved A/B of play builds on the GPU lane (each a
# CUDA build with the hw harness, --gpu-build done), the scripted walk (PLAY_DEMO=1, PLAY_N=900
# unless set), each run under tools/gx.sh (the lock, a timeout, the driver check). DISPLAY_ON=1
# in the VARs shows it in the real window; HW_NOPACE=1 drops the 60 Hz pace. One line a run
# (tools/pp.py: frame med/p95/p99 over the frames after 30 warm-up, the stages, HW present/busy).
# A BIN may carry its own settings: "PLAY_MODE=1,PLAY_U=1@build/x" runs build/x with them.
BC=$(cd "$(dirname "$0")/.." && pwd); cd $BC
R=$1; BINS=$2; shift 2
D=0; for a in "$@"; do [ "$a" = DISPLAY_ON=1 ] && D=1; done
for r in $(seq $R); do for e in $BINS; do
  b=${e##*@}; v=; [ "$b" != "$e" ] && v=$(echo ${e%@*} | tr , ' ')
  out=$(DISPLAY_ON=$D tools/gx.sh 150 abp-$(basename $b) PLAY_DEMO=1 PLAY_N=900 PLAY_LOG=1 BEND_GPROF=1 "$@" $v $b --threads 16 --gpu 3GB 2>&1)
  [ $? = 3 ] && { echo "$out" | tail -2; echo STOP; exit 3; }
  echo "r$r $(basename $b)${v:+ [$v]} :: $(echo "$out" | python3 tools/pp.py)"
done; done
