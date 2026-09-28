# tests/game.bend: the player (game.bend) on every lane.
# - a hand-built scene (a stone floor, top at y = 10, a wall at x = 14, a slab over (6, 12, 6) and
#   a hole at (20, z = 10)): landing flush on the floor, walking flush into the wall and into the
#   world's edge, a jump bumping the slab, falling into a one-wide hole;
# - break and place: breaking the floor block in front and placing stone back gives the scene's
#   voxels back; placing into the player's own box is refused;
# - a scripted run over generated terrain (walk, turn by mouse and keys, jump, swim, break,
#   place), then the same log encoded to words, decoded and replayed: the same state and voxels;
# - render(state): the frame after the run (hotbar, crosshair, outline) hashes the same everywhere.
import Base
import ../world.bend as W
import ../game.bend as G
import ../input.bend as In
import ../loop.bend as Loop
import ../fx.bend as Fx
import ../rng.bend as Rng

def inp(+k: U32, +mx: U32, +my: U32, +mb: U32) -> In.Input:
  In.Input{k, mx, my, mb}

# n ticks of the same input before rest.
def seg(n: Nat, +k: U32, +mx: U32, +my: U32, +mb: U32, rest: List<&2, In.Input>) ->
  List<&2, In.Input>:
  match n:
    case 0n:
      rest
    case 1n+p:
      inp(k, mx, my, mb) <> seg(p, k, mx, my, mb, rest)

# The mouse moving by (dx, dy) a tick for n ticks from (x, y).
def drag(n: Nat, +x: U32, +y: U32, +dx: U32, +dy: U32, rest: List<&2, In.Input>) ->
  List<&2, In.Input>:
  match n:
    case 0n:
      rest
    case 1n+p:
      inp(0, x, y, 0) <> drag(p, (x + dx : U32), (y + dy : U32), dx, dy, rest)

def game.of(s: Loop.Sim<G.Game>) -> G.Game:
  Loop.Sim{tick, paused, prev, seed, game} = s
  game

def run(xs: List<&2, In.Input>, g: G.Game) -> G.Game:
  game.of(Loop.run(~G.Game, ~G.step, xs, Loop.Sim.new(G.Game, 1, g)))

# The scene
# ---------

# Stone from y = 0 to 9 in every column (three words a column: y 0-7 whole, 8-9 half).
def floor.go(n: Nat, w: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      w
    case 1n++p:
      +c = U32.shln(U32.from_nat(p), 4n)
      floor.go(p, ((w[c] <- 16843009)[(c + 1 : U32)] <- 16843009)[(c + 2 : U32)] <- 257)

def set(+lc: Nat, +x: U32, +y: U32, +z: U32, +b: U32, w: Array<U32>) -> Array<U32>:
  W.set(lc, x, y, z, b, w)

# The wall: x = 14, y 10-11, z 0-63.
def wall.go(n: Nat, w: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      w
    case 1n++p:
      +z = U32.from_nat(p)
      wall.go(p, set(2n, 14, 11, z, 1, set(2n, 14, 10, z, 1, w)))

def scene() -> Array<U32>:
  set(2n, 20, 9, 10, 0, set(2n, 20, 8, 10, 0, set(2n, 6, 12, 6, 1, wall.go(64n, floor.go(4096n, W.new(2n))))))

def at.y(+x: U32, +y: U32, +z: U32, +yaw: U32, w: Array<U32>) -> G.Game:
  G.Game{w, G.P{(U32.shln(x, 16n) + 32768 : U32), U32.shln(y, 16n), (U32.shln(z, 16n) + 32768 : U32), 0, 0, 0, yaw, 0, 0, 2,
    G.none(), G.none(), 0}, 2n}

# The player at column (x, z), feet at y = 11 (falls to the floor at 10).
def at(+x: U32, +z: U32, +yaw: U32, w: Array<U32>) -> G.Game:
  at.y(x, 11, z, yaw, w)

def pline(g: G.Game) -> String:
  G.Game{w, p, lc} = g
  G.show.p(p)

def vh.at(r: Array<U32> & U32) -> U32:
  (w, +h) = r
  h

def vh.fin(g: G.Game) -> U32:
  G.Game{w, p, +lc} = g
  vh.at(W.vhash(lc, w))

def vh(g: G.Game) -> U32:
  vh.fin(g)

def ih(img: Image) -> U32:
  match img:
    case Pix{+c}:
      Rng.mix((c + 1 : U32))
    case Qua{a, b, c, d}:
      Rng.mix(U32.xor(ih(a), Rng.mix((ih(b) + Rng.mix((ih(c) * 3 + Rng.mix(ih(d)) : U32)) : U32))))

# Cases
# -----

def fwd() -> U32:
  1

def land() -> String:
  "land " ++ pline(run(seg(40n, 0, 0, 0, 0, Nil{}), at(10, 10, 16384, scene())))

def wall() -> String:
  "wall " ++ pline(run(seg(120n, fwd(), 0, 0, 0, Nil{}), at(10, 10, 16384, scene())))

def edge() -> String:
  "edge " ++ pline(run(seg(200n, fwd(), 0, 0, 0, Nil{}), at(10, 10, 49152, scene())))

# Under the slab at (6, 12, 6): the second tick of a jump meets it, and
# the head stops flush under it (feet at 12 - 1.8 = 668467, vy 0).
def bump() -> String:
  "bump " ++ pline(run(seg(2n, G.Key.jump(), 0, 0, 0, Nil{}), run(seg(10n, 0, 0, 0, 0, Nil{}),
    at.y(6, 10, 6, 0, scene()))))

# Walk +x from (18.5, 10.5) over the hole at x = 20: fall in and stay in it.
def hole() -> String:
  "hole " ++ pline(run(seg(60n, fwd(), 0, 0, 0, Nil{}), at(18, 10, 16384, scene())))

# Look down 66 degrees, break the floor block in front of the feet (the
# ray meets its top), then pick slot 3 (stone) and place: the ray now
# meets the top of the block under the hole, so the stone fills the hole:
# the scene again.
def dig.s() -> List<&2, In.Input>:
  seg(10n, 0, 0, 0, 0, seg(33n, G.Key.ld(), 0, 0, 0, seg(1n, G.Key.brk(), 0, 0, 0, seg(10n, 0, 0, 0, 0,
  seg(1n, 262144, 0, 0, 0, seg(1n, 0, 0, 0, 0, seg(1n, G.Key.put(), 0, 0, 0, seg(1n, 0, 0, 0, 0,
  Nil{}))))))))

def dig() -> String:
  "dig broke-then-placed scene-back "
    ++ U32.show(Fx.b2u(U32.is_eq(vh(run(dig.s(), at(10, 10, 16384, scene()))), vh(at(10, 10, 16384, scene())))))
    ++ " " ++ pline(run(dig.s(), at(10, 10, 16384, scene())))

# Look straight down and place: the cell is the player's own: refused.
def self.s() -> List<&2, In.Input>:
  seg(10n, 0, 0, 0, 0, seg(45n, G.Key.ld(), 0, 0, 0, seg(1n, G.Key.put(), 0, 0, 0, seg(3n, 0, 0, 0, 0,
    Nil{}))))

def self() -> String:
  "self-place refused "
    ++ U32.show(Fx.b2u(U32.is_eq(vh(run(self.s(), at(10, 10, 16384, scene()))), vh(at(10, 10, 16384, scene())))))

# The scripted run over terrain
# -----------------------------

def script() -> List<&2, In.Input>:
  seg(30n, 0, 0, 0, 0, seg(90n, 17, 0, 0, 0, drag(20n, 100, 100, 7, 1, seg(60n, 1, 240, 120, 0,
  seg(30n, 1025, 240, 120, 0, seg(1n, 262145, 240, 120, 1, seg(5n, 1, 240, 120, 0,
  seg(1n, 1, 240, 120, 2, seg(40n, 5, 240, 120, 0, seg(12n, 4096, 240, 120, 0, seg(1n, 0, 240, 120, 1,
  seg(3n, 0, 240, 120, 0, seg(1n, 0, 240, 120, 2, seg(120n, 17, 240, 120, 0, Nil{}))))))))))))))

def hash.show(r: G.Game & U32) -> String:
  (g, +h) = r
  "hash " ++ U32.show(h) ++ " " ++ pline(g)

def terrain() -> String:
  "terrain " ++ hash.show(G.hash(run(script(), G.new(2n, 1, 20, 12))))

def replay.got(m: Maybe<&2, In.Log.Got>) -> String:
  match m:
    case None{}:
      "replay decode failed"
    case Some{In.Got{xs, rest}}:
      "replay " ++ hash.show(G.hash(run(xs, G.new(2n, 1, 20, 12))))

def replay() -> String:
  replay.got(In.Log.dec(In.Log.enc(script(), Nil{})))

# The frame after the scripted run (64 x 36, tier 3, hotbar, crosshair, the aimed block outlined).
def shown.h(img: Image, r: Array<U32> & U32) -> String:
  (fb, +h) = r
  "view fb " ++ U32.show(h) ++ " img " ++ U32.show(ih(img))

def shown(s: G.Shown) -> String:
  G.Shown{g, fb, img} = s
  shown.h(img, W.hash(fb))

def view() -> String:
  shown(G.view(G.View{64, 36, 3, 24, 7000, 30000, 1}, 6n, 2n, run(script(), G.new(2n, 1, 20, 12)),
    Array.new(U32, 12n, 0), Pix{0}))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(land())
    IO.print(wall())
    IO.print(edge())
    IO.print(bump())
    IO.print(hole())
    IO.print(dig())
    IO.print(self())
    IO.print(terrain())
    IO.print(replay())
    IO.print(view())
#|land pos 688128 655360 688128 v 0 0 0 look 16384 0 ground 1 slot 2
#|wall pos 897843 655360 688128 v 0 0 0 look 16384 0 ground 1 slot 2
#|edge pos 19661 655360 688128 v 0 0 0 look 49152 0 ground 1 slot 2
#|bump pos 425984 668467 425984 v 0 0 0 look 0 0 ground 0 slot 2
#|hole pos 1356595 524288 688128 v 0 0 0 look 16384 0 ground 1 slot 2
#|dig broke-then-placed scene-back 1 pos 688128 655360 688128 v 0 0 0 look 16384 4294955284 ground 1 slot 2
#|self-place refused 1
#|terrain hash 2276724248 pos 1939021 2040050 454310 v 1785 4294965909 4294962953 look 28712 4294958128 ground 0 slot 2
#|replay hash 2276724248 pos 1939021 2040050 454310 v 1785 4294965909 4294962953 look 28712 4294958128 ground 0 slot 2
#|view fb 679483341 img 2849042313
