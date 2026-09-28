# rng.bend: a counter-based random generator, deterministic on every lane.
#
#   import ./rng.bend as Rng
#   Rng.at(seed, k)        # the k-th draw of stream `seed`: a hash, no state
#   Rng.below(seed, k, n)  # the same draw in [0, n) (n = 0 gives 0; slightly biased)
#   Rng.next(seed)         # the seed of the next tick
#
# A draw is a pure hash of (seed, k), not a step of a hidden state. The
# loop (loop.bend) advances the seed once per running tick and hands it to
# the game; within a tick, entity i draws Rng.at(seed, id_i * m + j). So a
# draw never depends on the order entities are visited in, the fork depth,
# or the thread count, and the parallel update needs no shared generator.
import Base

# The lowbias32 integer hash (Wellons): two xor-shift-multiply rounds.
def mix(+x: U32) -> U32:
  +a = (U32.xor(x, U32.shrn(x, 16n)) * 2146121005 : U32)
  +b = (U32.xor(a, U32.shrn(a, 15n)) * 2221713035 : U32)
  U32.xor(b, U32.shrn(b, 16n))

# Draw k of stream seed.
def at(+seed: U32, +k: U32) -> U32:
  mix(U32.xor(mix(seed), (k * 2654435769 : U32)))

# Draw k of stream seed, reduced to [0, n) by the modulo (n = 0 gives 0).
def below.if(+x: U32, +n: U32, zero: Bool) -> U32:
  match zero:
    case True{}:
      0
    case False{}:
      U32.mod(x, n)

def below(+seed: U32, +k: U32, +n: U32) -> U32:
  below.if(at(seed, k), n, U32.is_eq(n, 0))

# The next tick's seed (a Weyl step, then the hash: never stuck at 0).
def next(+seed: U32) -> U32:
  mix((seed + 2654435769 : U32))
