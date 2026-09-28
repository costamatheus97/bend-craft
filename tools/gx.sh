#!/bin/bash
# gx.sh TIMEOUT LABEL [VAR=VAL ..] CMD ARGS..: one GPU-touching process (a --gpu-build or a GPU
# run) under the shared bench lock, with a timeout, then the Windows driver check (drv.sh).
# Its output goes to stdout and to logs/gx/<stamp>-LABEL.txt; one line per run goes to
# logs/gpu.log. Exits 3 and prints STOP when the driver status is not 0: stop all GPU work.
# DISPLAY_ON=1 re-exports DISPLAY=:0 after the shim env (which unsets it).
. "$(dirname "$0")/env.sh"
. $PERF/ports/shim/env.sh
[ "${DISPLAY_ON:-0}" = 1 ] && export DISPLAY=:0
TO=$1; LABEL=$2; shift 2
mkdir -p $BC/logs/gx
F=$BC/logs/gx/$(date +%m%d-%H%M%S)-$LABEL.txt
t0=$(date '+%F %T'); l0=$(cut -d' ' -f1 /proc/loadavg); s0=$(date +%s%N)
flock $LOCK timeout $TO env "$@" > $F 2>&1 < /dev/null
rc=$?
ms=$(( ($(date +%s%N) - s0) / 1000000 ))
ds=$($DRV)
cat $F
line="$t0 $LABEL rc=$rc ms=$ms load=$l0 drv=$ds | $*"
echo "$line" >> $BC/logs/gpu.log
echo "GX $line"
if [ "$ds" != "0" ]; then
  echo "STOP: driver status '$ds' after: $line at $(date -Is)" | tee -a $BC/logs/gpu.log
  exit 3
fi
exit $rc
