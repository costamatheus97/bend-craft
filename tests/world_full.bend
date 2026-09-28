#lanes c1,c16,gpu,main
# tests/world_full.bend: the full 256 x 64 x 256 world (lc = 4) on the native lanes (the JS lane
# is sequential and slow at this size; tests/world.bend covers it at lc = 2).
# - the same hash at fork depths 0, 8 and 13 (one leaf, 256 leaves, 8192 leaves) and a
#   different one for another seed;
# - the bounds pass: the generator run with a counting writer writes every word exactly once
#   (so no index is out of range or shared), and every column index maps back to itself;
# - the block histogram (air, stone, dirt, grass, sand, water, log, leaves, ...).
import Base
import ../world.bend as W

def gen(+d: Nat, +lc: Nat, +seed: U32) -> W.P2:
  W.gen!(~W.Put.set, d, lc, seed, W.hm.new(lc), W.new(lc))

def count(+d: Nat, +lc: Nat, +seed: U32) -> W.P2:
  W.gen!(~W.Put.count, d, lc, seed, W.hm.new(lc), W.new(lc))

def show.hashes(r: Array<U32> & U32, +hh: U32) -> String:
  (w, +h) = r
  "hash " ++ U32.show(h) ++ " hm " ++ U32.show(hh)

def show.hm(w: Array<U32>, r: Array<U32> & U32) -> String:
  (hm, +hh) = r
  show.hashes(W.hash(w), hh)

def line.p(p: W.P2) -> String:
  W.P2{hm, w} = p
  show.hm(w, W.hash(hm))

def line(+d: Nat, +lc: Nat, +seed: U32) -> String:
  "world lc " ++ Nat.show(lc) ++ " seed " ++ U32.show(seed) ++ " d " ++ Nat.show(d) ++ " "
    ++ line.p(gen(d, lc, seed))

def bad.fin(r: Array<U32> & U32) -> U32:
  (w, +n) = r
  n

def bad.p(p: W.P2) -> U32:
  W.P2{hm, w} = p
  bad.fin(W.ne(1, w))

def bad(+d: Nat, +lc: Nat, +seed: U32) -> U32:
  bad.p(count(d, lc, seed))

def cnt.show(n: Nat, +i: U32, r: Array<U32> & U32) -> String:
  match n:
    case 0n:
      (cs, +v) = r
      U32.show(v)
    case 1n+p:
      (cs, +v) = r
      +i2 = (i + 1 : U32)
      U32.show(v) ++ " " ++ cnt.show(p, i2, cs[i2])

def hist.h(h: W.Hist) -> String:
  W.Hist{w2, cs} = h
  "hist " ++ cnt.show(13n, 0, cs[0])

def hist.p(p: W.P2) -> String:
  W.P2{hm, w} = p
  hist.h(W.hist(w))

def hist(+lc: Nat, +seed: U32) -> String:
  hist.p(gen(13n, lc, seed))

def main() -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.now()
    IO.print(line(0n, 4n, 1))
    +t2 : Nat <- IO.now()
    IO.print(line(8n, 4n, 1))
    +t3 : Nat <- IO.now()
    IO.print(line(13n, 4n, 1))
    +t4 : Nat <- IO.now()
    IO.print(line(13n, 4n, 2026))
    +t5 : Nat <- IO.now()
    IO.print("bounds lc 4 count-bad " ++ U32.show(bad(8n, 4n, 2026)) ++ " roundtrip-bad "
      ++ U32.show(W.roundtrip(U32.to_nat(65536), 4n, 0, 0)))
    +t6 : Nat <- IO.now()
    IO.print(hist(4n, 2026))

#|world lc 4 seed 1 d 0 hash 1576650492 hm 524395407
#|world lc 4 seed 1 d 8 hash 1576650492 hm 524395407
#|world lc 4 seed 1 d 13 hash 1576650492 hm 524395407
#|world lc 4 seed 2026 d 13 hash 3424874218 hm 2424778818
#|bounds lc 4 count-bad 0 roundtrip-bad 0
#|hist 1799408 1957419 95940 26438 134224 90737 1783 17277 0 65536 5542 0 0 0
