# bench/gen.bend: terrain generation time. Env: BC_LC (4), BC_D (fork depth, 8), BC_R (reps, 5),
# BC_BANG (1: under !, the GPU lane when there is one; 0: a plain call, the CPU lane).
# Prints one line per rep: gen lc <lc> d <d> bang <b> us <us> hash <h>.
import Base
import ../world.bend as W

def Clock.us() -> IO(U32):
  import "../clock.c"
  import "../clock.js"

def gen.bang(+d: Nat, +lc: Nat, +seed: U32, hm: Array<U32>, w: Array<U32>) -> W.P2:
  W.gen!(~W.Put.set, d, lc, seed, hm, w)

def gen.cpu(+d: Nat, +lc: Nat, +seed: U32, hm: Array<U32>, w: Array<U32>) -> W.P2:
  W.gen(~W.Put.set, d, lc, seed, hm, w)

def gen(+b: U32, +d: Nat, +lc: Nat, +seed: U32, hm: Array<U32>, w: Array<U32>) -> W.P2:
  match b:
    case 0:
      gen.cpu(d, lc, seed, hm, w)
    case _:
      gen.bang(d, lc, seed, hm, w)

def hash.fin(r: Array<U32> & U32) -> U32:
  (w, +h) = r
  h

def hash(p: W.P2) -> U32:
  W.P2{hm, w} = p
  hash.fin(W.hash(w))

def Env.u32(m: Maybe<&2, U32>, +default: U32) -> U32:
  match m:
    case None{}:
      default
    case Some{v}:
      v

def Env.num(r: Result<&1, &1, U32 & String, String>, +default: U32) -> U32:
  match r:
    case Fail{_}:
      default
    case Done{text}:
      Env.u32(U32.read(text), default)

def loop(n: Nat, +b: U32, +d: Nat, +lc: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        hm : Array<U32> <- IO.pure(Array<U32>, W.hm.new(lc))
        w : Array<U32> <- IO.pure(Array<U32>, W.new(lc))
        +t0 : U32 <- Clock.us()
        r : W.P2 <- IO.pure(W.P2, gen(b, d, lc, 1, hm, w))
        +t1 : U32 <- Clock.us()
        IO.print("gen lc " ++ Nat.show(lc) ++ " d " ++ Nat.show(d) ++ " bang " ++ U32.show(b)
          ++ " us " ++ U32.show((t1 - t0 : U32)) ++ " hash " ++ U32.show(hash(r)))
        loop(p, b, d, lc)

def main() -> IO(Unit):
  do IO<Unit>:
    lc : Result<&1, &1, U32 & String, String> <- IO.get_env("BC_LC")
    d : Result<&1, &1, U32 & String, String> <- IO.get_env("BC_D")
    r : Result<&1, &1, U32 & String, String> <- IO.get_env("BC_R")
    b : Result<&1, &1, U32 & String, String> <- IO.get_env("BC_BANG")
    loop(U32.to_nat(Env.num(r, 5)), Env.num(b, 1), U32.to_nat(Env.num(d, 8)), U32.to_nat(Env.num(lc, 4)))
