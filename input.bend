# input.bend: what a player does in one tick, and logs of it.
#
#   import ./input.bend as In
#   In.Input{keys, mx, my, mb}   # held key bits, mouse position and buttons
#   In.Input.none()              # nothing held
#   In.Input.feed(events, i)     # a frame's window events folded into i
#   In.Log.enc(xs, rest)         # a log as U32 words, before rest
#   In.Log.dec(ws)               # Some{Got{xs, rest}} back (LAWS: log_roundtrip)
#
# An Input is a state, not a list of events: which keys are down during
# the tick. Edges (a key going down) are the loop's business: loop.bend
# keeps the last tick's keys and computes keys & ~prev. A game reads the
# bits with In.Input.held(i, In.Key.fire()) and the like.
#
# The key bits are an abstract pad: four directions, fire, alt, pause,
# start and quit. In.Key.map sends window key codes to them (WASD and the
# arrows, space, x, p, enter, esc); a game with another layout writes its
# own map and calls In.Input.feed.with(~map, ..).
import Base

type Input is Data:
  Input{keys: U32, mx: U32, my: U32, mb: U32}

# The pad bits.
def Key.up() -> U32:
  1

def Key.down() -> U32:
  2

def Key.left() -> U32:
  4

def Key.right() -> U32:
  8

def Key.fire() -> U32:
  16

def Key.alt() -> U32:
  32

def Key.pause() -> U32:
  64

def Key.start() -> U32:
  128

def Key.quit() -> U32:
  256

def Input.none() -> Input:
  Input{0, 0, 0, 0}

def Input.keys(+i: Input) -> U32:
  Input{keys, mx, my, mb} = i
  keys

# Whether any bit of mask m is set in k.
def Key.has(+k: U32, +m: U32) -> Bool:
  U32.is_ne(U32.and(k, m), 0)

def Input.held(+i: Input, +m: U32) -> Bool:
  Key.has(Input.keys(i), m)

def Key.pick(c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

# Window key codes (as App events give them) to pad bits; 0 for others.
def Key.map(c: U32) -> U32:
  +code = c
  Key.pick(U32.is_eq(code, 119) || U32.is_eq(code, 63232), Key.up(),
  Key.pick(U32.is_eq(code, 115) || U32.is_eq(code, 63233), Key.down(),
  Key.pick(U32.is_eq(code, 97) || U32.is_eq(code, 63234), Key.left(),
  Key.pick(U32.is_eq(code, 100) || U32.is_eq(code, 63235), Key.right(),
  Key.pick(U32.is_eq(code, 32), Key.fire(),
  Key.pick(U32.is_eq(code, 120), Key.alt(),
  Key.pick(U32.is_eq(code, 112), Key.pause(),
  Key.pick(U32.is_eq(code, 13), Key.start(),
  Key.pick(U32.is_eq(code, 27), Key.quit(), 0)))))))))

# k with the bits m set (down) or cleared (up).
def Key.set(down: Bool, +m: U32, +k: U32) -> U32:
  match down:
    case True{}:
      U32.or(k, m)
    case False{}:
      U32.and(k, U32.not(m))

def Input.event(~map: U32 -> U32, e: Event, i: Input) -> Input:
  match e:
    case Key{code, down}:
      Input{keys, mx, my, mb} = i
      Input{Key.set(down, map(code), keys), mx, my, mb}
    case Mouse{x, y, button, down}:
      Input{keys, mx, my, mb} = i
      Input{keys, x, y, Key.set(down, U32.shln(1, U32.to_nat(U32.and(button, 31))), mb)}
    case Move{x, y}:
      Input{keys, mx, my, mb} = i
      Input{keys, x, y, mb}
    case Close{}:
      Input{keys, mx, my, mb} = i
      Input{U32.or(keys, Key.quit()), mx, my, mb}

# A frame's events, in order, folded into the input they change.
def Input.feed.with(~map: U32 -> U32, es: List<Event>, i: Input) -> Input:
  match es:
    case Nil{}:
      i
    case e <> t:
      Input.feed.with(~map, t, Input.event(~map, e, i))

def Input.feed(es: List<Event>, i: Input) -> Input:
  Input.feed.with(~Key.map, es, i)

# Logs
# ----
# A log is a List<&2, Input>, one entry per tick. Its words: a 1 and the
# four fields per entry, then a 0.

def Log.enc(xs: List<&2, Input>, rest: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      0 <> rest
    case Input{k, x, y, b} <> t:
      1 <> k <> x <> y <> b <> Log.enc(t, rest)

# A decoded log and the words after it.
type Log.Got is Data:
  Got{log: List<&2, Input>, rest: List<&2, U32>}

def Log.dec.cons(i: Input, r: Maybe<&2, Log.Got>) ->
  Maybe<&2, Log.Got>:
  match r:
    case None{}:
      None{}
    case Some{Got{xs, rest}}:
      Some{Got{i <> xs, rest}}

# The log at the head of ws and the words after it; None when ws is not
# one (a bad tag or a cut entry).
def Log.dec(ws: List<&2, U32>) -> Maybe<&2, Log.Got>:
  match ws:
    case 0 <> rest:
      Some{Got{Nil{}, rest}}
    case 1 <> k <> x <> y <> b <> rest:
      Log.dec.cons(Input{k, x, y, b}, Log.dec(rest))
    case _:
      None{}
