#!/usr/bin/env bash
# run_tests.sh [-l lanes] [test.bend ...]: runs every test (tests/*.bend by default) on each lane
# and compares its output with the #| lines at the end of the file.
#
# Lanes (-l, comma-separated; default check,js,c1,c16):
#   check    the checker (pr/gpu-profile) prints no error
#   js       the JS build (pr/gpu-profile), run by bun (one thread)
#   c1, c16  a plain CPU build (pr/gpu-profile, no GPU code) on 1 and 16 threads
#   gpu      the CUDA-over-HIP build (pr/gpu-profile): --gpu-build and the run each go through
#            tools/gx.sh (the bench lock, a timeout, the driver check); every ! runs on the GPU
#   main     a plain CPU build with upstream main (pr/main-ef66), 16 threads: no dependency on the fork
# A test may name its lanes in a line "#lanes js,c1,..." (the default is every lane).
set -u
cd "$(dirname "$0")"
. tools/env.sh
LANES=check,js,c1,c16
if [ "${1:-}" = "-l" ]; then LANES=$2; shift 2; fi
TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(tests/*.bend)
OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT"
export BUN_JSC_maxPerThreadStackUsage=33554432
has() { case ",$LANES," in *",$1,"*) return 0 ;; esac; return 1; }
pass=0; fail=0
report() {
  if [ "$3" = 1 ]; then pass=$((pass + 1)); printf 'PASS %-6s %s\n' "$1" "$2"
  else fail=$((fail + 1)); printf 'FAIL %-6s %s %s\n' "$1" "$2" "$4"; fi
}
same() { diff -q "$1" "$2" >/dev/null 2>&1 && echo 1 || echo 0; }
for t in "${TESTS[@]}"; do
  name=$(basename "$t" .bend); abs=$(realpath "$t")
  want=$OUT/$name.want
  grep '^#|' "$t" | sed 's/^#|//' >"$want"
  tl=$(grep '^#lanes ' "$t" | cut -d' ' -f2)
  ok_lane() { has $1 && { [ -z "$tl" ] || case ",$tl," in *",$1,"*) true ;; *) false ;; esac; }; }
  if ok_lane check; then
    out=$(tools/chk.sh "$t" 5 2>&1); ok=1
    echo "$out" | grep -q '^Error' && ok=0
    report check "$name" $ok "$(echo "$out" | head -3)"
  fi
  if ok_lane js; then
    (cd $TREE_GPU && nice bun bend2/main.ts $abs -o $OUT/$name.js >/dev/null 2>&1)
    (cd "$OUT" && nice timeout 900 bun "$OUT/$name.js") >"$OUT/$name.js.got" 2>&1
    report js "$name" "$(same "$want" "$OUT/$name.js.got")" "($OUT/$name.js.got)"
  fi
  if ok_lane c1 || ok_lane c16; then
    if tools/cbuild.sh gpu "$t" "$OUT/$name" cpu >"$OUT/$name.build" 2>&1; then
      for n in 1 16; do
        ok_lane c$n || continue
        nice timeout 900 "$OUT/$name" --threads $n >"$OUT/$name.c$n.got" 2>&1
        report c$n "$name" "$(same "$want" "$OUT/$name.c$n.got")" "($OUT/$name.c$n.got)"
      done
    else
      report c "$name" 0 "(build failed: $OUT/$name.build)"
    fi
  fi
  if ok_lane main; then
    if tools/cbuild.sh main "$t" "$OUT/$name.main" cpu >"$OUT/$name.main.build" 2>&1; then
      nice timeout 900 "$OUT/$name.main" --threads 16 >"$OUT/$name.main.got" 2>&1
      report main "$name" "$(same "$want" "$OUT/$name.main.got")" "($OUT/$name.main.got)"
    else
      report main "$name" 0 "(build failed: $OUT/$name.main.build)"
    fi
  fi
  if ok_lane gpu; then
    if tools/cbuild.sh gpu "$t" "$OUT/$name.g" cuda >"$OUT/$name.g.build" 2>&1 \
      && tools/gx.sh 120 "test-$name-build" "$OUT/$name.g" --gpu-build >>"$OUT/$name.g.build" 2>&1; then
      tools/gx.sh ${GPU_TIMEOUT:-120} "test-$name" "$OUT/$name.g" --threads 16 --gpu 3GB >"$OUT/$name.gpu.raw" 2>&1
      rc=$?
      [ $rc = 3 ] && { echo "STOP: driver status after the $name GPU run"; exit 3; }
      grep -v '^GX ' "$OUT/$name.gpu.raw" >"$OUT/$name.gpu.got"
      report gpu "$name" "$(same "$want" "$OUT/$name.gpu.got")" "($OUT/$name.gpu.got)"
    else
      grep -q STOP "$OUT/$name.g.build" && { echo "STOP: driver status after the $name GPU build"; exit 3; }
      report gpu "$name" 0 "(build failed: $OUT/$name.g.build)"
    fi
  fi
done
echo "passed $pass, failed $fail (outputs in $OUT)"
[ $fail -eq 0 ]
