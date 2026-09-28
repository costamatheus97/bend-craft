#!/bin/bash
# bench/m2.sh: the renderer table (bench/render.bend over a full turn at one spot, 5 warm-up
# frames): GPU (build/render_l0, a CUDA build of the L0 profiling tree) and CPU 1 / 16 threads
# (build/render, a CPU build), by resolution, tier and view distance. Output: logs/bench-m2.txt.
BC=$(cd "$(dirname "$0")/.." && pwd); cd $BC
O=logs/bench-m2.txt; : > $O
V="BR_N=41 BR_SPIN=1638 BR_PITCH=0 BR_X=200 BR_Z=60"
k() { case $1 in 320) echo 5;; 640) echo 6;; *) echo 7;; esac; }
for r in "320 180" "640 360" "1280 720" "1920 1080"; do set -- $r
  for t in 0 2 3; do for vd in 64 48; do
    bench/sweep.sh build/render_l0 gpu $V BR_W=$1 BR_H=$2 BR_K=$(k $1) BR_TIER=$t BR_VD=$vd BR_D=14 | tee -a $O
    [ ${PIPESTATUS[0]} = 3 ] && exit 3
  done; done
done
for r in "320 180" "640 360" "1280 720"; do set -- $r
  for lane in c1 c16; do
    [ $lane = c1 ] && [ $1 = 1280 ] && continue
    bench/sweep.sh build/render $lane $V BR_N=21 BR_SPIN=3276 BR_W=$1 BR_H=$2 BR_K=$(k $1) BR_TIER=2 BR_VD=64 BR_D=$([ $lane = c1 ] && echo 0 || echo 8) | tee -a $O
  done
done
