#!/bin/bash
# chk.sh FILE [LINES] [TREE]: check a Bend file with a tree (default gpu), print the first LINES.
. "$(dirname "$0")/env.sh"
F=$(realpath $1)
cd $(tree_of ${3:-gpu}) && bun bend2/main.ts $F --check-only 2>&1 | grep -v "is available: run bend update" | head -${2:-25}
