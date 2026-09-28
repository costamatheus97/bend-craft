#!/bin/bash
# cbuild.sh TREE PROG.bend OUT [cpu|cuda] [patch.py]: emit OUT.c from PROG with the Bend tree TREE
# (gpu | L0 | main | a path), optionally run patch.py OUT.c on it (a test-only harness), then
# compile it on the CPU only. cpu (default): a plain CPU binary (no GPU code at all). cuda: the
# CUDA-over-HIP lane (BEND_CUDA=1, shim headers); its GPU program is built later by
# `OUT --gpu-build` under tools/gx.sh (that step opens a GPU context). Nothing here touches the GPU.
set -e
. "$(dirname "$0")/env.sh"
T=$(tree_of $1); PROG=$(realpath $2); OUT=$(realpath -m $3); MODE=${4:-cpu}; PATCH=${5:-}
S=$PERF/ports/shim
CPUCC=${CPUCC:-/opt/rocm-7.2.1/lib/llvm/bin/clang}
( cd $T && env -u CUDA_HOME BUN_JSC_maxPerThreadStackUsage=33554432 nice timeout 900 bun bend2/main.ts $PROG -o $OUT.c 2>&1 \
  | grep -v -e '^- ' -e 'rely on unsafe' -e '^All terms check' ) || true
[ -s $OUT.c ] || { echo "cbuild: no C emitted for $PROG" >&2; exit 1; }
[ -n "$PATCH" ] && python3 $PATCH $OUT.c
LIBS=""; grep -q '#include <X11/' $OUT.c && LIBS="$LIBS -lX11"
if grep -q '#include <alsa/' $OUT.c; then LIBS="$LIBS -lasound"; fi
export CPATH=$PERF/engine/resident/alsa-stub/include LIBRARY_PATH=$PERF/engine/resident/alsa-stub/lib
rm -f $OUT.gpu
if [ "$MODE" = cuda ]; then
  CUDA_HOME=$S/cuda
  nice $CPUCC -DBEND_CUDA=1 -I$CUDA_HOME/include -L$CUDA_HOME/lib64 -L$CUDA_HOME/lib -L$CUDA_HOME/lib64/stubs \
    -std=c11 -O3 -w $OUT.c -lpthread -lm $LIBS -o $OUT -lcuda -lnvrtc
else
  nice $CPUCC -std=c11 -O3 -w $OUT.c -lpthread -lm $LIBS -o $OUT
fi
echo "cbuild: $OUT ($MODE, tree $1)"
