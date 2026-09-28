# tools/env.sh: paths shared by the build and run scripts (sourced, not run).
BC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PERF=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/perf
TREE_GPU=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/pr/gpu-profile      # f81948eb, the CUDA-over-HIP lane
TREE_L0=$PERF/gpu-profile/work/trees/L0                                      # the same + gprof L0 host timers
TREE_MAIN=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/pr/main-ef66         # upstream main ef66a7cc (after 2.0.32)
LOCK=$PERF/.bench.lock
DRV=$PERF/gpu-profile/tools/drv.sh
tree_of() { case $1 in gpu) echo $TREE_GPU ;; L0) echo $TREE_L0 ;; main) echo $TREE_MAIN ;; *) echo "$1" ;; esac; }
