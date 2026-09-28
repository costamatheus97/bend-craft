# tools/env.sh: paths shared by the build and run scripts (sourced, not run).
BC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PERF=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/perf
TREE_GPU=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/pr/gpu-profile      # f81948eb, the CUDA-over-HIP lane
TREE_L0=$PERF/gpu-profile/work/trees/L0                                      # the same + gprof L0 host timers
TREE_MAIN=/home/costamatheus97/vt/brainstorm-ai/bend2-hip/pr/main-229         # upstream main 574b6d39 (2.0.29)
LOCK=$PERF/.bench.lock
DRV=$PERF/gpu-profile/tools/drv.sh
tree_of() { case $1 in gpu) echo $TREE_GPU ;; L0) echo $TREE_L0 ;; main) echo $TREE_MAIN ;; *) echo "$1" ;; esac; }
