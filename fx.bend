# fx.bend: signed fixed-point arithmetic on U32 (two's complement), the same on every lane.
#
#   import ./fx.bend as Fx
#   Fx.sel(c, a, b)       # c ? a : b on words (a typed pick: no boxing)
#   Fx.neg / Fx.abs / Fx.isneg / Fx.slt / Fx.asr
#   Fx.mul(a, b)          # 16.16 x 16.16 -> 16.16, signed
#   Fx.sin(a) / Fx.cos(a) # a in 1/65536 of a turn; 16.16 result in [-1, 1]
#
# Positions and velocities are 16.16 (1.0 = 65536 = one block). Angles are
# U32 turns: 65536 is 360 degrees, so they wrap by masking.
import Base

def sel(c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

def b2u(c: Bool) -> U32:
  match c:
    case True{}:
      1
    case False{}:
      0

def neg(+a: U32) -> U32:
  (0 - a : U32)

def isneg(+a: U32) -> Bool:
  (a >= 2147483648 : U32)

def abs(+a: U32) -> U32:
  sel(isneg(a), neg(a), a)

# a < b as signed words.
def slt(+a: U32, +b: U32) -> Bool:
  (U32.xor(a, 2147483648) < U32.xor(b, 2147483648) : U32)

def smin(+a: U32, +b: U32) -> U32:
  sel(slt(a, b), a, b)

def smax(+a: U32, +b: U32) -> U32:
  sel(slt(a, b), b, a)

# Arithmetic shift right.
def asr(+a: U32, +n: Nat) -> U32:
  sel(isneg(a), U32.not(U32.shrn(U32.not(a), n)), U32.shrn(a, n))

# |a| * |b| >> 16 for words below 2^32, split in 16-bit halves (no overflow
# while the result fits).
def umul(+a: U32, +b: U32) -> U32:
  +ah = U32.shrn(a, 16n)
  +al = U32.and(a, 65535)
  +bh = U32.shrn(b, 16n)
  +bl = U32.and(b, 65535)
  (U32.shln((ah * bh : U32), 16n) + ah * bl + al * bh + U32.shrn((al * bl : U32), 16n) : U32)

# Signed 16.16 product.
def mul(+a: U32, +b: U32) -> U32:
  +p = umul(abs(a), abs(b))
  sel(Bool.xor(isneg(a), isneg(b)), neg(p), p)

# sin of a half turn h in [0, 32768] (Bhaskara I, error < 0.2%): 16.16.
def sin.half(+h: U32) -> U32:
  +p = U32.shrn((h * (32768 - h) : U32), 4n)
  U32.div(U32.shln(p, 4n), U32.shrn((335544320 - p * 4 : U32), 16n))

# sin of a turn angle a (65536 a turn): 16.16, signed.
def sin(+a0: U32) -> U32:
  +a = U32.and(a0, 65535)
  sel((a < 32768 : U32), sin.half(a), neg(sin.half((a - 32768 : U32))))

def cos(+a: U32) -> U32:
  sin((a + 16384 : U32))
