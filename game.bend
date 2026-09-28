# game.bend: the player and the world as a pure fixed-timestep game (loop.bend's contract).
#
#   import ./game.bend as G
#   G.new(lc, seed, x, z)            # a world (generated under !) with the player at column (x, z)
#   G.step(tick, game)               # one tick (60 a second): look, move, collide, break, place
#   G.Key.map(code)                  # window key codes to this game's key bits
#   G.aim(game)                      # (game, the block the player aims at, or none)
#   G.hash(game)                     # (game, a hash of the player and the voxels)
#
# All U32 fixed point (16.16 positions and velocities, turns of 65536),
# run on the host, never under a bang (a tick is a short serial chain):
# the same on every lane. The player is an axis-aligned box 0.6 x 1.8 x
# 0.6 blocks; the eye is 1.62 over the feet. Movement resolves one axis
# at a time (y, then x, then z), and no axis moves a block or more in a
# tick (walk 0.07, fall at most 0.9), so the box can only newly overlap
# the cells at its leading face: overlapping ones push it back flush with
# that face.
#
# Keys: WASD move, space jumps (swims up in water), the arrows turn and
# look, Q or the left button breaks, E or the right button places, 1-9
# pick the hotbar slot, P pauses, Esc quits. The mouse turns and looks by
# how far it moved since the last tick. In play.bend's window a click holds
# the pointer (mouse look) and Esc lets it go (blit.c).
import Base
import ./fx.bend as Fx
import ./world.bend as W
import ./render.bend as R
import ./input.bend as In
import ./loop.bend as Loop
import ./rng.bend as Rng

# Units
# -----

def half() -> U32:
  19661

def tall() -> U32:
  117965

def eye() -> U32:
  106168

def walk() -> U32:
  4697

def grav() -> U32:
  583

def jump() -> U32:
  9767

def fall() -> U32:
  58982

def none() -> U32:
  4294967295

# Keys
# ----

def Key.fwd() -> U32:
  1

def Key.back() -> U32:
  2

def Key.left() -> U32:
  4

def Key.right() -> U32:
  8

def Key.jump() -> U32:
  16

def Key.tl() -> U32:
  512

def Key.tr() -> U32:
  1024

def Key.lu() -> U32:
  2048

def Key.ld() -> U32:
  4096

def Key.brk() -> U32:
  8192

def Key.put() -> U32:
  16384

# Digits 1-9: bits 16 to 24.
def Key.digit(+c: U32) -> U32:
  Fx.sel(((c >= 49) && (c <= 57) : U32), U32.shln(65536, U32.to_nat((c - 49 : U32))), 0)

def Key.map(c: U32) -> U32:
  +k = c
  Fx.sel(U32.is_eq(k, 119), Key.fwd(),
  Fx.sel(U32.is_eq(k, 115), Key.back(),
  Fx.sel(U32.is_eq(k, 97), Key.left(),
  Fx.sel(U32.is_eq(k, 100), Key.right(),
  Fx.sel(U32.is_eq(k, 32), Key.jump(),
  Fx.sel(U32.is_eq(k, 112), In.Key.pause(),
  Fx.sel(U32.is_eq(k, 27), In.Key.quit(),
  Fx.sel(U32.is_eq(k, 63234), Key.tl(),
  Fx.sel(U32.is_eq(k, 63235), Key.tr(),
  Fx.sel(U32.is_eq(k, 63232), Key.lu(),
  Fx.sel(U32.is_eq(k, 63233), Key.ld(),
  Fx.sel(U32.is_eq(k, 113), Key.brk(),
  Fx.sel(U32.is_eq(k, 101), Key.put(), Key.digit(k))))))))))))))

def has(+k: U32, +m: U32) -> U32:
  Fx.b2u(U32.is_ne(U32.and(k, m), 0))

# The state
# ---------

# Feet (x, y, z) and velocity (vx, vy, vz) in 16.16; yaw and pitch
# (pitch signed, within +-85 degrees); ground: 1 when standing; slot: the
# hotbar's; lmx, lmy, lmb: last tick's mouse (lmx none(): no position yet).
type P is Data:
  P{x: U32, y: U32, z: U32, vx: U32, vy: U32, vz: U32, yaw: U32, pitch: U32, ground: U32,
    slot: U32, lmx: U32, lmy: U32, lmb: U32}

type Game is Type:
  Game{w: Array<U32>, p: P, lc: Nat}

# The block at a cell counts as solid for the player (outside the world
# in x or z is a wall; above it is air).
def sb.at(r: Array<U32> & U32) -> Array<U32> & U32:
  (w, +b) = r
  (w, Fx.b2u(U32.is_ne(b, 0) && U32.is_ne(b, 5)))

def sb.if(on: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  match on:
    case True{}:
      sb.at(W.get(lc, x, y, z, w))
    case False{}:
      (w, 1)

def sb(+lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  +s = W.side(lc)
  sb.if(((x < s) && (z < s) : U32), lc, x, y, z, w)

# The 12 cells a box can touch: 2 in x, 3 in y, 2 in z from its low
# corner cell (cx, cy, cz); d: how many more it spans on each axis.
def box.rd(+lc: Nat, +k: U32, +cx: U32, +cy: U32, +cz: U32, +dx: U32, +dy: U32, +dz: U32,
  w: Array<U32>) -> Array<U32> & U32:
  +iy = U32.shrn(k, 2n)
  sb(lc, (cx + U32.and(k, 1) * dx : U32), (cy + Fx.sel((iy < dy : U32), iy, dy) : U32),
    (cz + U32.and(U32.shrn(k, 1n), 1) * dz : U32), w)

def box.go(n: Nat, +lc: Nat, +cx: U32, +cy: U32, +cz: U32, +dx: U32, +dy: U32, +dz: U32,
  +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (w, +s) = r
      (w, (acc + s : U32))
    case 1n++p:
      (w, +s) = r
      box.go(p, lc, cx, cy, cz, dx, dy, dz, (acc + s : U32),
        box.rd(lc, U32.from_nat(p), cx, cy, cz, dx, dy, dz, w))

# The number of solid cells the player's box overlaps with its feet at (x, y, z).
def box(+lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  +cx = U32.shrn((x - half() : U32), 16n)
  +cy = U32.shrn(y, 16n)
  +cz = U32.shrn((z - half() : U32), 16n)
  +dx = (U32.shrn((x + half() - 1 : U32), 16n) - cx : U32)
  +dy = (U32.shrn((y + tall() - 1 : U32), 16n) - cy : U32)
  +dz = (U32.shrn((z + half() - 1 : U32), 16n) - cz : U32)
  box.go(11n, lc, cx, cy, cz, dx, dy, dz, 0, box.rd(lc, 11, cx, cy, cz, dx, dy, dz, w))

# One axis's result: position, velocity, whether it landed.
type Ax is Data:
  Ax{p: U32, v: U32, g: U32}

# y after moving by vy: flush on the cell below (landed) or above.
def ax.y(+vy: U32, +ny: U32, r: Array<U32> & U32) -> Array<U32> & Ax:
  (w, +n) = r
  +hit = U32.is_ne(n, 0)
  +down = Fx.isneg(vy)
  +up = (U32.shln(U32.shrn((ny + tall() - 1 : U32), 16n), 16n) - tall() : U32)
  (w, Ax{Fx.sel(hit, Fx.sel(down, U32.shln((U32.shrn(ny, 16n) + 1 : U32), 16n), up), ny),
    Fx.sel(hit, 0, vy), Fx.b2u(hit && down)})

# x or z after moving by v: flush on the cell ahead.
def ax.h(+v: U32, +np: U32, r: Array<U32> & U32) -> Array<U32> & Ax:
  (w, +n) = r
  +hit = U32.is_ne(n, 0)
  +lo = (U32.shln((U32.shrn((np - half() : U32), 16n) + 1 : U32), 16n) + half() : U32)
  +hi = (U32.shln(U32.shrn((np + half() - 1 : U32), 16n), 16n) - half() : U32)
  (w, Ax{Fx.sel(hit, Fx.sel(Fx.isneg(v), lo, hi), np), Fx.sel(hit, 0, v), 0})

# The tick
# --------

# Clamp a signed pitch to +-85 degrees.
def pclamp(+a: U32) -> U32:
  Fx.smax(Fx.smin(a, 15474), Fx.neg(15474))

# The mouse's move since last tick (0 without a last position).
def dmouse(+m: U32, +last: U32) -> U32:
  Fx.sel(U32.is_eq(last, none()), 0, (m - last : U32))

# The lowest digit pressed (bits 16..24) as a slot, or cur.
def slot.of(+d: U32, +cur: U32) -> U32:
  Fx.sel(U32.is_ne(U32.and(d, 1), 0), 0, Fx.sel(U32.is_ne(U32.and(d, 2), 0), 1,
  Fx.sel(U32.is_ne(U32.and(d, 4), 0), 2, Fx.sel(U32.is_ne(U32.and(d, 8), 0), 3,
  Fx.sel(U32.is_ne(U32.and(d, 16), 0), 4, Fx.sel(U32.is_ne(U32.and(d, 32), 0), 5,
  Fx.sel(U32.is_ne(U32.and(d, 64), 0), 6, Fx.sel(U32.is_ne(U32.and(d, 128), 0), 7,
  Fx.sel(U32.is_ne(U32.and(d, 256), 0), 8, cur)))))))))

# The player's look direction (16.16, unit).
def dir.x(+yaw: U32, +pitch: U32) -> U32:
  Fx.mul(Fx.cos(pitch), Fx.sin(yaw))

def dir.z(+yaw: U32, +pitch: U32) -> U32:
  Fx.mul(Fx.cos(pitch), Fx.cos(yaw))

# What the player's eye ray hits within 5 blocks.
def pick(+lc: Nat, +p: P, w: Array<U32>) -> Array<U32> & R.Hit:
  P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  R.cast(w, x, (y + eye() : U32), z, dir.x(yaw, pitch), Fx.sin(pitch), dir.z(yaw, pitch), 20480, 5,
    lc, 0)

# Whether cell (cx, cy, cz) overlaps the player's box.
def inbox(+p: P, +cx: U32, +cy: U32, +cz: U32) -> Bool:
  P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  +x0 = U32.shln(cx, 16n)
  +y0 = U32.shln(cy, 16n)
  +z0 = U32.shln(cz, 16n)
  ((x0 < x + half()) && (x0 + 65536 > x - half()) && (y0 < y + tall()) && (y0 + 65536 > y)
    && (z0 < z + half()) && (z0 + 65536 > z - half()) : U32)

# The cell in front of face f of (x, y, z) (face codes as render.bend's Hit).
def front(+f: U32, +ax: U32, +c: U32) -> U32:
  Fx.sel(U32.is_eq(U32.shrn(f, 1n), ax), Fx.sel(U32.is_eq(U32.and(f, 1), 0), (c + 1 : U32),
    (c - 1 : U32)), c)

def put.at(ok: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, +b: U32, r: Array<U32> & U32) ->
  Array<U32>:
  match ok:
    case True{}:
      (w, +o) = r
      W.set(lc, x, y, z, b, w)
    case False{}:
      (w, +o) = r
      w

def put.fin(ok: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, +b: U32, r: Array<U32> & U32) ->
  Array<U32>:
  (w, +o) = r
  put.at(ok && (U32.is_eq(o, 0) || U32.is_eq(o, 5)), lc, x, y, z, b, (w, o))

# Break (brk) or place (put: the slot's block into the air or water cell
# in front of the aimed face, unless the player stands in it).
def edit(brk: Bool, +put: U32, +lc: Nat, +p: P, r: Array<U32> & R.Hit) -> Array<U32>:
  match brk:
    case True{}:
      (w, +h) = r
      R.Hit{b, f, t, x, y, z, wt} = h
      put.at(U32.is_ne(b, 0) && U32.is_ne(b, 9), lc, x, y, z, 0, (w, 0))
    case False{}:
      P{px, py, pz, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
      (w, +h) = r
      R.Hit{b, f, t, x, y, z, wt} = h
      +tx = front(f, 0, x)
      +ty = front(f, 1, y)
      +tz = front(f, 2, z)
      +ok = U32.is_eq(put, 1) && U32.is_ne(b, 0) && Bool.not(inbox(p, tx, ty, tz))
      put.fin(ok, lc, tx, ty, tz, R.hot.blk(slot), W.get(lc, tx, ty, tz, w))

def step.edit(+brk: U32, +put: U32, +lc: Nat, +p: P, w: Array<U32>) -> Game:
  Game{edit(U32.is_eq(brk, 1), put, lc, p, pick(lc, p, w)), p, lc}

def step.z(+brk: U32, +put: U32, +lc: Nat, +p: P, r: Array<U32> & Ax) -> Game:
  P{x, y, z0, vx, vy, vz0, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  (w, +a) = r
  Ax{z, vz, g} = a
  step.edit(brk, put, lc, P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb}, w)

def step.x(+brk: U32, +put: U32, +lc: Nat, +p: P, r: Array<U32> & Ax) -> Game:
  P{x0, y, z, vx0, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  (w, +a) = r
  Ax{x, vx, g} = a
  +nz = (z + vz : U32)
  step.z(brk, put, lc, P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb},
    ax.h(vz, nz, box(lc, x, y, nz, w)))

def step.y(+brk: U32, +put: U32, +lc: Nat, +p: P, r: Array<U32> & Ax) -> Game:
  P{x, y0, z, vx, vy0, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  (w, +a) = r
  Ax{y, vy, g} = a
  +nx = (x + vx : U32)
  step.x(brk, put, lc, P{x, y, z, vx, vy, vz, yaw, pitch, g, slot, lmx, lmy, lmb},
    ax.h(vx, nx, box(lc, nx, y, z, w)))

# vy this tick: in water, sink slowly or swim up (jump); on the ground,
# jump; else fall faster, up to fall().
def vy.of(+wet: U32, +jmp: U32, +ground: U32, +vy: U32) -> U32:
  +sink = Fx.smax((vy - U32.shrn(grav(), 2n) : U32), Fx.neg(5243))
  +air = Fx.smax(Fx.sel(U32.is_eq((jmp + ground : U32), 2), jump(), (vy - grav() : U32)), Fx.neg(fall()))
  Fx.sel(U32.is_eq(wet, 1), Fx.sel(U32.is_eq(jmp, 1), 3277, sink), air)

def step.wet(+brk: U32, +put: U32, +jmp: U32, +lc: Nat, +p: P, r: Array<U32> & U32) -> Game:
  P{x, y, z, vx, vy0, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  (w, +b) = r
  +vy = vy.of(Fx.b2u(U32.is_eq(b, 5)), jmp, ground, vy0)
  +ny = (y + vy : U32)
  step.y(brk, put, lc, P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb},
    ax.y(vy, ny, box(lc, x, ny, z, w)))

# The walk: fwd and str are -1, 0 or 1 (signed); a diagonal is scaled by 1/sqrt 2.
def wish(+fwd: U32, +str: U32, +s: U32, +c: U32) -> U32:
  +v = (Fx.mul(U32.shln(fwd, 16n), s) + Fx.mul(U32.shln(str, 16n), c) : U32)
  +diag = U32.is_ne(fwd, 0) && U32.is_ne(str, 0)
  Fx.mul(Fx.sel(diag, Fx.mul(v, 46341), v), walk())

def step.p(+keys: U32, +pressed: U32, +mx: U32, +my: U32, +mb: U32, +lc: Nat, +p: P,
  w: Array<U32>) -> Game:
  P{x, y, z, vx, vy, vz, yaw0, pitch0, ground, slot0, lmx, lmy, lmb} = p
  +yaw = U32.and((yaw0 + dmouse(mx, lmx) * 40 + has(keys, Key.tr()) * 364 - has(keys, Key.tl()) * 364 : U32), 65535)
  +pitch = pclamp((pitch0 - dmouse(my, lmy) * 40 + has(keys, Key.lu()) * 364 - has(keys, Key.ld()) * 364 : U32))
  +fwd = (has(keys, Key.fwd()) - has(keys, Key.back()) : U32)
  +str = (has(keys, Key.right()) - has(keys, Key.left()) : U32)
  +sy = Fx.sin(yaw)
  +cy = Fx.cos(yaw)
  +edge = U32.and(mb, U32.not(lmb))
  +brk = Fx.b2u(U32.is_eq(has(pressed, Key.brk()), 1) || U32.is_ne(U32.and(edge, 1), 0))
  +put = Fx.b2u(U32.is_eq(has(pressed, Key.put()), 1) || U32.is_ne(U32.and(edge, 2), 0))
  step.wet(brk, put, has(keys, Key.jump()), lc, P{x, y, z, wish(fwd, str, sy, cy), vy,
    wish(fwd, Fx.neg(str), cy, sy), yaw, pitch, ground, slot.of(U32.shrn(pressed, 16n), slot0), mx,
    my, mb}, W.get(lc, U32.shrn(x, 16n), U32.shrn(y, 16n), U32.shrn(z, 16n), w))

# One tick of the game.
def step(t: Loop.Tick, g: Game) -> Game:
  Loop.Tick{n, seed, input, pressed} = t
  In.Input{keys, mx, my, mb} = input
  Game{w, p, +lc} = g
  step.p(keys, pressed, mx, my, mb, lc, p, w)

# Making, aiming, hashing
# -----------------------

def spawn(+lc: Nat, +x: U32, +z: U32, w: Array<U32>, r: Array<U32> & U32) -> Game:
  (hm, +h) = r
  +g = U32.and(h, 255)
  Game{w, P{(U32.shln(x, 16n) + 32768 : U32), U32.shln((Fx.sel((g < W.sea() : U32), W.sea(), g) + 1 : U32), 16n),
    (U32.shln(z, 16n) + 32768 : U32), 0, 0, 0, 8192, 0, 0, 0, none(), none(), 0}, lc}

def new.p(+lc: Nat, +x: U32, +z: U32, p: W.P2) -> Game:
  W.P2{hm, w} = p
  spawn(lc, x, z, R.tex(lc, w), hm[W.col(lc, x, z)])

def gen(+lc: Nat, +seed: U32) -> W.P2:
  W.gen!(~W.Put.set, 13n, lc, seed, W.hm.new(lc), W.new(lc))

# A new game: world seed, the player standing at column (x, z).
def new(+lc: Nat, +seed: U32, +x: U32, +z: U32) -> Game:
  new.p(lc, x, z, gen(lc, seed))

type Aim is Data:
  Aim{x: U32, y: U32, z: U32}

def aim.fin(+p: P, +lc: Nat, r: Array<U32> & R.Hit) -> Game & Aim:
  (w, +h) = r
  R.Hit{b, f, t, x, y, z, wt} = h
  +on = U32.is_ne(b, 0)
  (Game{w, p, lc}, Aim{Fx.sel(on, x, none()), Fx.sel(on, y, none()), Fx.sel(on, z, none())})

# The block the player aims at (none() when nothing within reach).
def aim(g: Game) -> Game & Aim:
  Game{w, +p, +lc} = g
  aim.fin(p, lc, pick(lc, p, w))

def mixin(+h: U32, +v: U32) -> U32:
  Rng.mix(U32.xor((h * 31 : U32), v))

def hash.fin(+p: P, +lc: Nat, r: Array<U32> & U32) -> Game & U32:
  P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  (w, +hv) = r
  (Game{w, p, lc},
    mixin(mixin(mixin(mixin(mixin(mixin(mixin(mixin(hv, x), y), z), vx), vy), vz), yaw),
      mixin(mixin(pitch, ground), slot)))

# (game, a hash of the player's state and the voxels).
def hash(g: Game) -> Game & U32:
  Game{w, p, +lc} = g
  hash.fin(p, lc, W.vhash(lc, w))

def show.p(+p: P) -> String:
  P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  "pos " ++ U32.show(x) ++ " " ++ U32.show(y) ++ " " ++ U32.show(z) ++ " v " ++ U32.show(vx) ++ " "
    ++ U32.show(vy) ++ " " ++ U32.show(vz) ++ " look " ++ U32.show(yaw) ++ " " ++ U32.show(pitch)
    ++ " ground " ++ U32.show(ground) ++ " slot " ++ U32.show(slot)

# The frame
# ---------

# What a frame looks like: samples, shading tier, view distance (blocks),
# the sun's elevation and azimuth, and how it is made (mode 0: straight
# into the window Image, render.bend's direct; 1: into the framebuffer,
# then converted, render.bend's draw: the framebuffer then holds the frame;
# 2: into the framebuffer only, render.bend's fill, for a window that shows
# the framebuffer itself (play.bend's Blit.frame): the image stays old),
# and skip: bit 0, render.bend's empty-space skipping; bit 1, the sun table
# for the shadow ray (world.bend's sun table, render.bend's sun.ensure). The
# same frames either way: both are faster on the CPU, slower on the GPU.
type View is Data:
  View{ws: U32, hs: U32, tier: U32, vd: U32, sel: U32, saz: U32, mode: U32, skip: U32}

type Shown is Type:
  Shown{g: Game, fb: Array<U32>, img: Image}

def view.fin(+p: P, +lc: Nat, o: R.Out) -> Shown:
  R.Out{w, fb, img} = o
  Shown{Game{w, p, lc}, fb, img}

def view.cam(+v: View, +p: P, +lc: Nat, +a: Aim) -> R.Cam:
  View{ws, hs, tier, vd, sel, saz, mode, skip} = v
  P{x, y, z, vx, vy, vz, yaw, pitch, ground, slot, lmx, lmy, lmb} = p
  Aim{ax, ay, az} = a
  R.cam.ui(R.cam.skip(R.cam(x, (y + eye() : U32), z, yaw, pitch, ws, hs, vd, tier, sel, saz, lc), skip),
    slot, ax, ay, az)

def view.fb(+p: P, +lc: Nat, old: Image, r: R.P2) -> Shown:
  R.P2{w, fb} = r
  Shown{Game{w, p, lc}, fb, old}

def view.direct(+p: P, +lc: Nat, fb: Array<U32>, r: Array<U32> & Image) -> Shown:
  (w, img) = r
  Shown{Game{w, p, lc}, fb, img}

def view.m(+mode: U32, +c: R.Cam, +d: Nat, +k: Nat, +p: P, +lc: Nat, w: Array<U32>, fb: Array<U32>,
  old: Image) -> Shown:
  match mode:
    case 0:
      view.direct(p, lc, fb, R.direct!(c, Nat.add(k, 2n), w, old))
    case 2:
      view.fb(p, lc, old, R.fill!(~W.Put.set, c, d, w, fb))
    case _:
      view.fin(p, lc, R.draw!(~W.Put.set, c, d, k, w, fb, old))

# The world's sun table for c when the view asks for it (skip bit 1).
def sun.if(on: Bool, +c: R.Cam, +d: Nat, w: Array<U32>) -> Array<U32> & U32:
  match on:
    case True{}:
      R.sun.ensure(c, d, w)
    case False{}:
      (w, 0)

# The frame with the world's sun table (render.bend's sun.ensure: built on
# the first frame, or when the sun changes; the same frame, faster).
def view.s(+mode: U32, +c: R.Cam, +d: Nat, +k: Nat, +p: P, +lc: Nat, fb: Array<U32>, old: Image,
  r: Array<U32> & U32) -> Shown:
  (w, +on) = r
  view.m(mode, R.cam.sun(c, on), d, k, p, lc, w, fb, old)

def view.go(+v: View, +d: Nat, +k: Nat, fb: Array<U32>, old: Image, r: Game & Aim) -> Shown:
  View{ws, hs, tier, vd, sel, saz, mode, skip} = v
  (g, +a) = r
  Game{w, +p, +lc} = g
  +c = view.cam(v, p, lc, a)
  view.s(mode, c, d, k, p, lc, fb, old, sun.if(U32.is_ne(U32.and(skip, 2), 0), c, d, w))

# The game's frame (render(state)): the view from the player's eye with the
# hotbar, the crosshair and the aimed block outlined, rendered into fb
# (fork depth d) and converted to the window Image over 2^(k + 4) samples,
# or (mode 0) rendered straight into that Image, in one bang (one GPU
# turn); the last frame's image old is dropped in it.
def view(+v: View, +d: Nat, +k: Nat, g: Game, fb: Array<U32>, old: Image) -> Shown:
  view.go(v, d, k, fb, old, aim(g))

def prep.fin(+p: P, +lc: Nat, r: Array<U32> & U32) -> Game:
  (w, +on) = r
  Game{w, p, lc}

# g ready for view v: its sun table built now (2^d leaves a pass), not on
# the first frame.
def prep(+v: View, +d: Nat, g: Game) -> Game:
  View{ws, hs, tier, vd, sel, saz, mode, skip} = v
  Game{w, +p, +lc} = g
  prep.fin(p, lc, sun.if(U32.is_ne(U32.and(skip, 2), 0), view.cam(v, p, lc, Aim{none(), none(), none()}), d, w))
