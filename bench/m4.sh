#!/bin/bash
# bench/m4.sh: end-to-end frame time of play.bend (the scripted walk, PLAY_DEMO=1, one tick a
# frame) on the GPU lane (build/play_l0: a CUDA build of the L0 profiling tree with the hw
# harness) and the CPU lane (build/play: a CPU build with the harness), offscreen without the
# 60 Hz pace (HW_NOPACE=1) unless noted, 30 warm-up frames. Output: logs/bench-m4.txt.
BC=$(cd "$(dirname "$0")/.." && pwd); cd $BC
O=logs/bench-m4.txt; N=${N:-900}
g() { label=$1; shift; D=0; for a in "$@"; do [ "$a" = DISPLAY_ON=1 ] && D=1; done
  out=$(DISPLAY_ON=$D tools/gx.sh 150 m4-$label PLAY_DEMO=1 PLAY_N=$N PLAY_LOG=1 BEND_GPROF=1 "$@" build/play_l0 --threads 16 --gpu 3GB 2>&1)
  rc=$?; [ $rc = 3 ] && { echo STOP; exit 3; }
  echo "gpu $label $* :: $(echo "$out" | python3 tools/pp.py)" | tee -a $O; }
c() { label=$1; th=$2; shift 2
  out=$(env -u DISPLAY PLAY_DEMO=1 PLAY_N=${CN:-300} PLAY_LOG=1 HW_NOPACE=1 "$@" nice timeout 300 build/play --threads $th 2>&1)
  echo "c$th $label $* :: $(echo "$out" | python3 tools/pp.py)" | tee -a $O; }
case ${1:-all} in
gpu|all)
  g 720p-default HW_NOPACE=1
  g 720p-vd64 HW_NOPACE=1 PLAY_VD=64
  g 720p-tier2 HW_NOPACE=1 PLAY_TIER=2
  g 720p-up2 HW_NOPACE=1 PLAY_U=1 PLAY_VD=64
  g 1080p HW_NOPACE=1 PLAY_W=1920 PLAY_H=1080
  g 1080p-up2 HW_NOPACE=1 PLAY_W=1920 PLAY_H=1080 PLAY_U=1
  g 640x360 HW_NOPACE=1 PLAY_W=640 PLAY_H=360
  g 320x180 HW_NOPACE=1 PLAY_W=320 PLAY_H=180
  ;;&
display|all)
  g 720p-display-nopace DISPLAY_ON=1 HW_NOPACE=1
  g 720p-display-paced DISPLAY_ON=1
  g 1080p-up2-display-nopace DISPLAY_ON=1 HW_NOPACE=1 PLAY_W=1920 PLAY_H=1080 PLAY_U=1
  ;;&
cpu|all)
  c 320x180 16 PLAY_W=320 PLAY_H=180
  c 320x180 1 PLAY_W=320 PLAY_H=180 PLAY_D=0
  c 640x360 16 PLAY_W=640 PLAY_H=360
  c 1280x720-up4 16 PLAY_U=2
  c 1280x720 16
  ;;
esac
