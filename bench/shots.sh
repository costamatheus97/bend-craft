#!/bin/bash
# bench/shots.sh: the screenshots in media/ (1280 x 720, rendered by a CPU build of
# bench/render.bend, build/render; the same frames as the GPU lane: the tests hash them).
BC=$(cd "$(dirname "$0")/.." && pwd); cd $BC
T=$(mktemp -d)
shot() { name=$1; shift; env BR_W=1280 BR_H=720 BR_K=7 BR_N=1 BR_PPM=$T/$name.ppm "$@" nice timeout 120 build/render --threads 16 | tail -1
  python3 -c "from PIL import Image; Image.open('$T/$name.ppm').save('media/$name.png')"; }
V="BR_X=200 BR_Z=60 BR_PITCH=64000 BR_SEL=7000 BR_SAZ=34960"
shot tier0-flat $V BR_TIER=0
shot tier1-textures $V BR_TIER=1
shot tier2-ao $V BR_TIER=2
shot tier3-shadows $V BR_TIER=3
shot sun-shore BR_TIER=3 BR_X=60 BR_Z=200 BR_YAW=20000 BR_PITCH=65000 BR_SEL=4000 BR_SAZ=17000
shot peak BR_TIER=3 BR_X=128 BR_Z=128 BR_UP=6 BR_YAW=40000 BR_PITCH=62500 BR_SEL=6500 BR_SAZ=9000
rm -r "$T"
