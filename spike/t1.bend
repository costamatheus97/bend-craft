import Base

def Clock.us() -> IO(U32):
  import "./clock.c"
  import "./clock.js"

def mix(+x: U32) -> U32:
  +a = (U32.xor(x, U32.shrn(x, 16n)) * 2146121005 : U32)
  +b = (U32.xor(a, U32.shrn(a, 15n)) * 2221713035 : U32)
  U32.xor(b, U32.shrn(b, 16n))

# a computed pair destructured by a let
def two(+x: U32) -> U32 & U32:
  (x, (x + 1 : U32))

def use(+x: U32) -> U32:
  (a, b) = two(x)
  (a2, b2) = two(b)
  (a + b + a2 + b2 : U32)

def main() -> IO(Unit):
  do IO<Unit>:
    +t0 : U32 <- Clock.us()
    IO.print(U32.show(use(5)))
