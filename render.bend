# render.bend: a first-person view of the world by per-pixel voxel ray traversal.
#
#   import ./render.bend as R
#   R.cam(px, py, pz, yaw, pitch, ws, hs, vd, tier, lc)   # the frame's camera (host, once a frame)
#   R.tex(lc, w)                   # writes the texture atlas into the world's upper half (once)
#   R.fill(~W.Put.set, cam, d, w, fb)  # the frame into the flat framebuffer fb (row-major, ws x hs;
#                                      # W.Put.count counts the writes instead: the bounds pass)
#   R.draw(~W.Put.set, cam, d, k, w, fb, old)  # fill, then the window Image (bang it: one GPU turn)
#   R.ppm(ws, hs, fb)              # the frame as P6 bytes
#
# Everything is U32 fixed point, so a frame is the same on every lane:
# positions 16.16 (a block is 65536), ray directions 16.16 (signed), and
# the ray parameter t in 20.12. A ray is d = f + a r + b u, unnormalized
# with |f| = 1 and r, u orthogonal to f, so t is the planar depth: the fog
# and the view distance are depths, and no square root is needed.
#
# Traversal is Amanatides-Woo DDA: per axis, the t of the next boundary
# (tMax) and the t per cell (tDelta = 2^28 / |d|). A step is branch-free
# arithmetic (the axis of the smallest tMax), and a single flat loop: the
# read of the next cell is the loop's argument, and whether to stop is
# decided one iteration late (the last cell rides along as the hit
# candidate), because Bend cannot match a computed value inside a loop.
# The loop has a hard step cap (3 x the view distance + 3), so no ray can
# spin (a pure loop in a GPU turn cannot park).
#
# A pixel reads only the scene array (voxels in the lower half, the
# texture atlas in the upper half), threaded linearly through its reads.
# The fork tree hands every leaf a shared handle (@unsafe, one refcount
# bump per fork, never per read) and writes disjoint framebuffer slots.
import Base
import ./fx.bend as Fx
import ./rng.bend as Rng
import ./world.bend as W

# The camera
# ----------

# o: the eye (16.16); f: the ray of the frame's centre; a, b: the ray's
# change per two samples right and down (so a sample (sx, sy) looks along
# f + (a (2 sx + 1 - ws) + b (2 sy + 1 - hs)) / 2); ws, hs: the samples;
# tmax: the view distance as t (20.12); tier: the shading tier; l: the
# direction toward the sun (16.16, unit); snx, sny, snr: the sun's disc on
# the screen, in samples (signed; snr 0 when the sun is behind); lc: the
# world's size.
type Cam3 is Data:
  Cam3{a: U32, b: U32, c: U32}

type Cam is Data:
  Cam{ox: U32, oy: U32, oz: U32, fx: U32, fy: U32, fz: U32, ax: U32, ay: U32, az: U32, bx: U32,
    by: U32, bz: U32, ws: U32, hs: U32, tmax: U32, tier: U32, lx: U32, ly: U32, lz: U32, snx: U32,
    sny: U32, snr: U32, lc: Nat}

# v * 2 / ws, signed (v is 16.16 in [-1, 1]).
def per(+v: U32, +ws: U32) -> U32:
  +q = U32.div((Fx.abs(v) * 2 : U32), ws)
  Fx.sel(Fx.isneg(v), Fx.neg(q), q)

def dot(+ax: U32, +ay: U32, +az: U32, +bx: U32, +by: U32, +bz: U32) -> U32:
  (Fx.mul(ax, bx) + Fx.mul(ay, by) + Fx.mul(az, bz) : U32)

# a * h / z, signed a, z > 0.
def proj(+a: U32, +h: U32, +z: U32) -> U32:
  +q = U32.div((Fx.abs(a) * h : U32), z)
  Fx.sel(Fx.isneg(a), Fx.neg(q), q)

# The sun's disc on the screen from its direction in camera space (xr
# right, yu up, zf forward): none (radius 0) when it is behind or far aside.
def sun.at(+xr: U32, +yu: U32, +zf: U32, +ws: U32, +hs: U32) -> Cam3:
  +on = Fx.slt(6554, zf)
  +h = U32.shrn(ws, 1n)
  +z = Fx.sel(on, zf, 65536)
  Cam3{(h + proj(xr, h, z) : U32), (U32.shrn(hs, 1n) - proj(yu, h, z) : U32),
    Fx.sel(on, (U32.div(ws, 40) + 1 : U32), 0)}

def cam.fin(+px: U32, +py: U32, +pz: U32, +sy: U32, +cy: U32, +sp: U32, +cp: U32, +ws: U32,
  +hs: U32, +vd: U32, +tier: U32, +lx: U32, +ly: U32, +lz: U32, +lc: Nat, +sn: Cam3) -> Cam:
  Cam3{snx, sny, snr} = sn
  Cam{px, py, pz, Fx.mul(cp, sy), sp, Fx.mul(cp, cy), per(cy, ws), 0, per(Fx.neg(sy), ws),
    per(Fx.mul(sp, sy), ws), per(Fx.neg(cp), ws), per(Fx.mul(sp, cy), ws), ws, hs,
    U32.shln(vd, 12n), tier, lx, ly, lz, snx, sny, snr, lc}

# The camera at (px, py, pz), turned yaw and pitch (turns of 65536): yaw
# 0 looks along +z, yaw grows toward +x; pitch grows upward. The
# horizontal field of view is 90 degrees (tan 1). The sun stands at
# elevation sel and azimuth saz (the same turns as yaw).
def cam(+px: U32, +py: U32, +pz: U32, +yaw: U32, +pitch: U32, +ws: U32, +hs: U32, +vd: U32,
  +tier: U32, +sel: U32, +saz: U32, +lc: Nat) -> Cam:
  +sy = Fx.sin(yaw)
  +cy = Fx.cos(yaw)
  +sp = Fx.sin(pitch)
  +cp = Fx.cos(pitch)
  +ce = Fx.cos(sel)
  +lx = Fx.mul(ce, Fx.sin(saz))
  +ly = Fx.sin(sel)
  +lz = Fx.mul(ce, Fx.cos(saz))
  cam.fin(px, py, pz, sy, cy, sp, cp, ws, hs, vd, tier, lx, ly, lz, lc,
    sun.at(dot(lx, ly, lz, cy, 0, Fx.neg(sy)), dot(lx, ly, lz, Fx.neg(Fx.mul(sp, sy)), cp,
      Fx.neg(Fx.mul(sp, cy))), dot(lx, ly, lz, Fx.mul(cp, sy), sp, Fx.mul(cp, cy)), ws, hs))

# Colours
# -------

def rgb(+r: U32, +g: U32, +b: U32) -> U32:
  U32.or(U32.shln(r, 16n), U32.or(U32.shln(g, 8n), b))

def ch(+c: U32, +n: Nat) -> U32:
  U32.and(U32.shrn(c, n), 255)

# c scaled by k / 256 (k <= 256).
def scale(+c: U32, +k: U32) -> U32:
  rgb(U32.shrn((ch(c, 16n) * k : U32), 8n), U32.shrn((ch(c, 8n) * k : U32), 8n),
    U32.shrn((ch(c, 0n) * k : U32), 8n))

# a + (b - a) k / 256, per channel (k <= 256).
def lerp.ch(+a: U32, +b: U32, +k: U32) -> U32:
  U32.shrn((a * (256 - k) + b * k : U32), 8n)

def mix(+a: U32, +b: U32, +k: U32) -> U32:
  rgb(lerp.ch(ch(a, 16n), ch(b, 16n), k), lerp.ch(ch(a, 8n), ch(b, 8n), k),
    lerp.ch(ch(a, 0n), ch(b, 0n), k))

def clamp256(+v: U32) -> U32:
  Fx.sel(Fx.isneg(v), 0, Fx.sel((v > 256 : U32), 256, v))

# The sky
# -------

def Sky.zenith() -> U32:
  rgb(92, 146, 232)

def Sky.horizon() -> U32:
  rgb(178, 210, 246)

def Sky.sun() -> U32:
  rgb(255, 250, 228)

def Sky.glow() -> U32:
  rgb(255, 236, 190)

def near(+a: U32, +b: U32) -> U32:
  +d = Fx.abs((a - b : U32))
  Fx.sel((d > 16383 : U32), 16383, d)

# The sky at sample (sx, sy) whose ray climbs e / 256 (dy over the L1
# length of d): the horizon's colour at and below the horizon, the
# zenith's at the top, and the sun's disc and glow (radius r at (cx, cy)).
def sky(+e: U32, +sx: U32, +sy: U32, +cx: U32, +cy: U32, +r: U32) -> U32:
  +ex = near(sx, cx)
  +ey = near(sy, cy)
  +d2 = (ex * ex + ey * ey : U32)
  +r2 = (r * r : U32)
  +base = mix(Sky.horizon(), Sky.zenith(), clamp256((e * 2 : U32)))
  Fx.sel((d2 < r2 : U32), Sky.sun(), mix(base, Sky.glow(),
    U32.shrn(U32.div((r2 * 1024 : U32), (d2 + r2 * 4 + 1 : U32)), 1n)))

# The texture atlas
# -----------------
# 16 x 16 texels for each block and face class (0 top, 1 side, 2 bottom,
# 3 the block's flat colour), procedural and computed once on the host
# into the scene array's upper half: aux + (b * 4 + class) * 256 + v * 16 + u.

def T.hash(+k: U32) -> U32:
  Rng.mix((k * 2654435769 + 12345 : U32))

# c darkened by up to amp / 256 by noise n (8 bits).
def T.vary(+c: U32, +n: U32, +amp: U32) -> U32:
  scale(c, (256 - amp + U32.shrn((n * amp : U32), 8n) : U32))

def T.flat(+b: U32) -> U32:
  Fx.sel((b < 5 : U32),
    Fx.sel((b < 3 : U32),
      Fx.sel(U32.is_eq(b, 1), rgb(125, 125, 125), Fx.sel(U32.is_eq(b, 2), rgb(134, 96, 67), rgb(98, 164, 56))),
      Fx.sel(U32.is_eq(b, 3), rgb(98, 164, 56), rgb(220, 208, 160))),
    Fx.sel((b < 10 : U32),
      Fx.sel((b < 8 : U32),
        Fx.sel(U32.is_eq(b, 5), rgb(40, 84, 180), Fx.sel(U32.is_eq(b, 6), rgb(104, 82, 50), rgb(58, 122, 38))),
        Fx.sel(U32.is_eq(b, 8), rgb(168, 134, 82), rgb(80, 80, 80))),
      Fx.sel((b < 12 : U32),
        Fx.sel(U32.is_eq(b, 10), rgb(244, 248, 252), rgb(152, 70, 52)),
        Fx.sel(U32.is_eq(b, 12), rgb(110, 110, 110), rgb(190, 215, 228)))))

def T.dirt(+n: U32) -> U32:
  T.vary(rgb(134, 96, 67), n, 70)

# The grass side: dirt under a jagged green lip.
def T.grass.side(+u: U32, +v: U32, +n: U32) -> U32:
  +lip = (2 + U32.and(T.hash((u * 31 + 7 : U32)), 3) : U32)
  Fx.sel((v < lip : U32), T.vary(rgb(98, 164, 56), n, 70), T.dirt(n))

def T.grass(+fc: U32, +u: U32, +v: U32, +n: U32) -> U32:
  Fx.sel(U32.is_eq(fc, 0), T.vary(rgb(98, 164, 56), n, 70),
    Fx.sel(U32.is_eq(fc, 1), T.grass.side(u, v, n), T.dirt(n)))

# The log: rings on the ends, bark stripes on the sides.
def T.log(+fc: U32, +u: U32, +v: U32, +n: U32) -> U32:
  +du = Fx.abs((u * 2 - 15 : U32))
  +dv = Fx.abs((v * 2 - 15 : U32))
  +d = Fx.sel((du > dv : U32), du, dv)
  +ring = Fx.sel(U32.is_eq(U32.and(U32.shrn(d, 2n), 1), 1), rgb(176, 142, 90), rgb(150, 118, 72))
  +bark = Fx.sel(U32.is_eq(U32.and((u + U32.and(T.hash(u), 1) : U32), 3), 0), rgb(78, 60, 36), rgb(104, 82, 50))
  Fx.sel(U32.is_eq(fc, 1), T.vary(bark, n, 50), T.vary(Fx.sel((d > 13 : U32), rgb(104, 82, 50), ring), n, 24))

def T.leaves(+n: U32) -> U32:
  Fx.sel((n < 48 : U32), rgb(30, 70, 22), T.vary(rgb(62, 130, 42), n, 90))

def T.planks(+u: U32, +v: U32, +n: U32) -> U32:
  +line = U32.is_eq(U32.and(v, 3), 3)
  +seam = U32.is_eq(u, (U32.and(U32.shrn(v, 2n), 1) * 8 + 3 : U32))
  T.vary(Fx.sel(line || seam, rgb(118, 92, 54), rgb(168, 134, 82)), n, 30)

def T.brick(+u: U32, +v: U32, +n: U32) -> U32:
  +mortar = U32.is_eq(U32.and(v, 3), 3) || U32.is_eq(U32.and(u, 7), (U32.and(U32.shrn(v, 2n), 1) * 4 : U32))
  Fx.sel(mortar, T.vary(rgb(186, 180, 170), n, 20), T.vary(rgb(152, 70, 52), n, 40))

def T.cobble(+u: U32, +v: U32, +n: U32) -> U32:
  +su = (u + U32.and(U32.shrn(v, 2n), 3) * 3 : U32)
  +g = (84 + U32.and(T.hash((U32.shrn(su, 2n) * 17 + U32.shrn(v, 2n) : U32)), 63) : U32)
  +edge = U32.is_eq(U32.and(su, 3), 0) || U32.is_eq(U32.and(v, 3), 0)
  T.vary(Fx.sel(edge, rgb(62, 62, 62), rgb(g, g, g)), n, 30)

def T.glass(+u: U32, +v: U32) -> U32:
  +rim = ((u < 1) || (u > 14) || (v < 1) || (v > 14) : U32)
  +glint = U32.is_eq(u, v) && (u > 3 : U32) && (u < 8 : U32)
  Fx.sel(rim, rgb(225, 240, 245), Fx.sel(glint, rgb(236, 246, 250), rgb(172, 204, 220)))

# Texel i of the atlas.
def T.texel(+i: U32) -> U32:
  +b = U32.shrn(i, 10n)
  +fc = U32.and(U32.shrn(i, 8n), 3)
  +v = U32.and(U32.shrn(i, 4n), 15)
  +u = U32.and(i, 15)
  +n = U32.and(T.hash(i), 255)
  Fx.sel(U32.is_eq(fc, 3), T.flat(b),
    Fx.sel((b < 5 : U32),
      Fx.sel((b < 3 : U32),
        Fx.sel(U32.is_eq(b, 1), T.vary(rgb(128, 128, 128), n, 60), Fx.sel(U32.is_eq(b, 2), T.dirt(n), rgb(0, 0, 0))),
        Fx.sel(U32.is_eq(b, 3), T.grass(fc, u, v, n), T.vary(rgb(220, 208, 160), n, 36))),
      Fx.sel((b < 10 : U32),
        Fx.sel((b < 8 : U32),
          Fx.sel(U32.is_eq(b, 5), T.vary(rgb(40, 84, 180), n, 30),
            Fx.sel(U32.is_eq(b, 6), T.log(fc, u, v, n), T.leaves(n))),
          Fx.sel(U32.is_eq(b, 8), T.planks(u, v, n), T.vary(rgb(80, 80, 80), n, 200))),
        Fx.sel((b < 12 : U32),
          Fx.sel(U32.is_eq(b, 10), T.vary(rgb(244, 248, 252), n, 16), T.brick(u, v, n)),
          Fx.sel(U32.is_eq(b, 12), T.cobble(u, v, n), T.glass(u, v))))))

def T.count() -> U32:
  16384

# Texels n - 1 .. 0 into w at base.
def T.go(n: Nat, +base: U32, w: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      w
    case 1n++p:
      +i = U32.from_nat(p)
      T.go(p, base, w[(base + i : U32)] <- T.texel(i))

# The atlas into the scene array (host, once).
def tex(+lc: Nat, w: Array<U32>) -> Array<U32>:
  T.go(U32.to_nat(T.count()), W.aux(lc), w)

# The traversal
# -------------

type Hit is Data:
  Hit{b: U32, f: U32, t: U32, x: U32, y: U32, z: U32, wt: U32}

def none() -> U32:
  4294967295

# The word of cell (x, y, z), or 0 without a read when stop.
def rd(stop: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  match stop:
    case True{}:
      (w, 0)
    case False{}:
      w[W.word(lc, x, y, z)]

# One cell a step. r holds the word of cell (x, y, z), entered at t through
# face f. hb/hx/hy/hz/ht/hf: the last cell, the hit when stop comes (hb 0:
# no hit). wt: the t the ray entered water, or none().
def go(
  n: Nat, stop: Bool, +x: U32, +y: U32, +z: U32, +tx: U32, +ty: U32, +tz: U32, +t: U32, +f: U32,
  +wt: U32, +hb: U32, +hx: U32, +hy: U32, +hz: U32, +ht: U32, +hf: U32, +sx: U32, +sy: U32,
  +sz: U32, +ddx: U32, +ddy: U32, +ddz: U32, +fX: U32, +fY: U32, +fZ: U32, +tmax: U32, +side: U32,
  +lc: Nat, r: Array<U32> & U32
) -> Array<U32> & Hit:
  match n:
    case 0n:
      (w, +wd) = r
      (w, Hit{hb, hf, ht, hx, hy, hz, wt})
    case 1n+k:
      match stop:
        case True{}:
          (w, +wd) = r
          (w, Hit{hb, hf, ht, hx, hy, hz, wt})
        case False{}:
          (w, +wd) = r
          +b = W.byte(wd, y)
          +wet = U32.is_eq(b, 5)
          +solid = U32.is_ne(b, 0) && Bool.not(wet)
          +tm = Fx.sel((tx < ty : U32), Fx.sel((tx < tz : U32), tx, tz), Fx.sel((ty < tz : U32), ty, tz))
          +ax = U32.is_eq(tx, tm)
          +ay = Bool.not(ax) && U32.is_eq(ty, tm)
          +az = Bool.not(ax) && Bool.not(ay)
          +xn = (x + Fx.sel(ax, sx, 0) : U32)
          +yn = (y + Fx.sel(ay, sy, 0) : U32)
          +zn = (z + Fx.sel(az, sz, 0) : U32)
          +st = solid || ((xn >= side) || (yn >= 64) || (zn >= side) || (tm > tmax) : U32)
          go(k, st, xn, yn, zn, (tx + Fx.sel(ax, ddx, 0) : U32), (ty + Fx.sel(ay, ddy, 0) : U32),
            (tz + Fx.sel(az, ddz, 0) : U32), tm, Fx.sel(ax, fX, Fx.sel(ay, fY, fZ)),
            Fx.sel(wet && U32.is_eq(wt, none()), t, wt), Fx.sel(solid, b, 0), x, y, z, t, f, sx, sy,
            sz, ddx, ddy, ddz, fX, fY, fZ, tmax, side, lc, rd(st, lc, xn, yn, zn, w))

# t per cell along an axis of |d| = ad (2^27, beyond any view, when ad is tiny).
def ddt(+ad: U32) -> U32:
  Fx.sel((ad < 16 : U32), 134217728, U32.div(268435456, ad))

# t of the first boundary along an axis: the distance to it (16.16, cut to
# 12 bits) times ddt, split so nothing overflows.
def tmx(+o: U32, +d: U32, +dd: U32) -> U32:
  +fr = U32.and(o, 65535)
  +f12 = U32.shrn(Fx.sel(Fx.isneg(d), fr, (65536 - fr : U32)), 4n)
  (f12 * U32.shrn(dd, 12n) + U32.shrn((f12 * U32.and(dd, 4095) : U32), 12n) : U32)

def step(+d: U32) -> U32:
  Fx.sel(Fx.isneg(d), 4294967295, 1)

# The ray from o (16.16, inside the world or not) along d.
def cast(w: Array<U32>, +ox: U32, +oy: U32, +oz: U32, +dx: U32, +dy: U32, +dz: U32, +tmax: U32,
  +vd: U32, +lc: Nat) -> Array<U32> & Hit:
  +x = U32.shrn(ox, 16n)
  +y = U32.shrn(oy, 16n)
  +z = U32.shrn(oz, 16n)
  +side = W.side(lc)
  +ddx = ddt(Fx.abs(dx))
  +ddy = ddt(Fx.abs(dy))
  +ddz = ddt(Fx.abs(dz))
  +out = ((x >= side) || (y >= 64) || (z >= side) : U32)
  go(U32.to_nat((vd * 3 + 3 : U32)), out, x, y, z, tmx(ox, dx, ddx), tmx(oy, dy, ddy),
    tmx(oz, dz, ddz), 0, 2, none(), 0, x, y, z, 0, 2, step(dx), step(dy), step(dz), ddx, ddy, ddz,
    Fx.sel(Fx.isneg(dx), 0, 1), Fx.sel(Fx.isneg(dy), 2, 3), Fx.sel(Fx.isneg(dz), 4, 5), tmax, side,
    lc, rd(out, lc, x, y, z, w))

# Shading
# -------

# o + d t along one axis (o 16.16, d 16.16 signed, t 20.12): 16.16.
def at(+o: U32, +d: U32, +t: U32) -> U32:
  +ad = Fx.abs(d)
  +m = (ad * U32.shrn(t, 12n) + U32.shrn((ad * U32.and(t, 4095) : U32), 12n) : U32)
  Fx.sel(Fx.isneg(d), (o - m : U32), (o + m : U32))

# The face's light: top 256, the x sides 204, the z sides 172, bottom 128.
def face.light(+f: U32) -> U32:
  Fx.sel((f < 2 : U32), 204, Fx.sel(U32.is_eq(f, 2), 256, Fx.sel(U32.is_eq(f, 3), 128, 172)))

# The atlas row of a face: 0 top, 1 side, 2 bottom.
def face.cls(+f: U32) -> U32:
  Fx.sel(U32.is_eq(f, 2), 0, Fx.sel(U32.is_eq(f, 3), 2, 1))

# The fog: 0 up to 60% of the view distance, 256 at it.
def fog(+t: U32, +tmax: U32) -> U32:
  +t0 = U32.shrn((tmax * 3 : U32), 2n)
  Fx.sel((t <= t0 : U32), 0, clamp256(U32.div(U32.shln((t - t0 : U32), 8n), (U32.shrn(tmax, 2n) + 1 : U32))))

# Ambient occlusion: the 8 cells around the air cell in front of the face
# (c = the cell + the normal), in the face's plane, as a mask: bit k set
# when solid. k 0..3 the sides (-a, +a, -b, +b), 4..7 the corners
# (-a-b, +a-b, -a+b, +a+b), a and b the face's tangent axes.
def ao.oa(+k: U32) -> U32:
  Fx.sel((k < 2 : U32), Fx.sel(U32.is_eq(k, 0), 4294967295, 1), Fx.sel((k < 4 : U32), 0,
    Fx.sel(U32.is_eq(U32.and(k, 1), 0), 4294967295, 1)))

def ao.ob(+k: U32) -> U32:
  Fx.sel((k < 2 : U32), 0, Fx.sel((k < 4 : U32), Fx.sel(U32.is_eq(k, 2), 4294967295, 1),
    Fx.sel((k < 6 : U32), 4294967295, 1)))

def ao.solid(+b: U32) -> U32:
  Fx.sel(U32.is_ne(b, 0) && U32.is_ne(b, 5), 1, 0)

def ao.get(+lc: Nat, +ax: U32, +x: U32, +y: U32, +z: U32, +k: U32, w: Array<U32>) ->
  Array<U32> & U32:
  +oa = ao.oa(k)
  +ob = ao.ob(k)
  W.get(lc, (x + Fx.sel(U32.is_eq(ax, 0), 0, oa) : U32),
    (y + Fx.sel(U32.is_eq(ax, 1), 0, ob) : U32),
    (z + Fx.sel(U32.is_eq(ax, 0), oa, Fx.sel(U32.is_eq(ax, 1), ob, 0)) : U32), w)

def ao.go(n: Nat, +lc: Nat, +ax: U32, +x: U32, +y: U32, +z: U32, +m: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  match n:
    case 0n:
      (w, +b) = r
      (w, U32.or(m, ao.solid(b)))
    case 1n++p:
      (w, +b) = r
      +k = U32.from_nat(p)
      ao.go(p, lc, ax, x, y, z, U32.or(m, U32.shln(ao.solid(b), U32.to_nat((k + 1 : U32)))),
        ao.get(lc, ax, x, y, z, k, w))

# The occlusion of a vertex from its two sides and corner (bits of m): 0 .. 3.
def ao.v(+m: U32, +s1: Nat, +s2: Nat, +c: Nat) -> U32:
  +a = U32.and(U32.shrn(m, s1), 1)
  +b = U32.and(U32.shrn(m, s2), 1)
  +cc = U32.and(U32.shrn(m, c), 1)
  Fx.sel(U32.is_eq((a + b : U32), 2), 0, (3 - a - b - cc : U32))

# The light factor (out of 256) at face coordinates (u, v) in 12 bits:
# the four vertices' occlusion, interpolated.
def ao.light(+m: U32, +u: U32, +v: U32) -> U32:
  +v00 = ao.v(m, 0n, 2n, 4n)
  +v10 = ao.v(m, 1n, 2n, 5n)
  +v01 = ao.v(m, 0n, 3n, 6n)
  +v11 = ao.v(m, 1n, 3n, 7n)
  +lo = (v00 * (4096 - u) + v10 * u : U32)
  +hi = (v01 * (4096 - u) + v11 * u : U32)
  +a = U32.shrn((U32.shrn(lo, 4n) * (4096 - v) + U32.shrn(hi, 4n) * v : U32), 12n)
  (140 + U32.shrn((a * 38 : U32), 8n) : U32)

# The surface: its texel, the face's light and occlusion, the fog, the water.
type Surf is Data:
  Surf{b: U32, f: U32, t: U32, x: U32, y: U32, z: U32, wt: U32, u: U32, v: U32, fg: U32, sky: U32,
    fr: U32, wc: U32, sh: U32}

def water.col() -> U32:
  rgb(40, 84, 180)

# The water's colour where the ray entered it (at t = wt): its atlas
# texel's noise, computed in place (no read).
def water.at(+ox: U32, +oz: U32, +dx: U32, +dz: U32, +wt: U32) -> U32:
  +u = U32.and(U32.shrn(at(ox, dx, wt), 12n), 15)
  +v = U32.and(U32.shrn(at(oz, dz, wt), 12n), 15)
  T.vary(water.col(), U32.and(T.hash((5120 + v * 16 + u : U32)), 255), 40)

# The water between wt and t over colour c: a tint by depth, and the sky
# mirrored by fr / 256 (more at grazing angles).
def wet.if(dry: Bool, +c: U32, +wt: U32, +t: U32, +sky: U32, +fr: U32, +wc: U32) -> U32:
  match dry:
    case True{}:
      c
    case False{}:
      +k = (U32.shrn((t - wt : U32), 6n) + 96 : U32)
      mix(mix(c, wc, Fx.sel((k > 230 : U32), 230, k)), sky, fr)

def wet(+c: U32, +wt: U32, +t: U32, +sky: U32, +fr: U32, +wc: U32) -> U32:
  wet.if(U32.is_eq(wt, none()), c, wt, t, sky, fr, wc)

def surf.fin(+s: Surf, +light: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  Surf{b, f, t, x, y, z, wt, u, v, fg, sky, fr, wc, sh} = s
  (w, +texel) = r
  +k = U32.shrn((U32.shrn((light * face.light(f) : U32), 8n) * sh : U32), 8n)
  (w, mix(wet(scale(texel, k), wt, t, sky, fr, wc), sky, fg))

def surf.ao(+s: Surf, +tex: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  Surf{b, f, t, x, y, z, wt, u, v, fg, sky, fr, wc, sh} = s
  (w, +m) = r
  surf.fin(s, ao.light(m, u, Fx.sel(U32.is_eq(U32.shrn(f, 1n), 1), v, (4095 - v : U32))), w[tex])

def surf.if(ao: Bool, +tier: U32, +lc: Nat, +s: Surf, +tex: U32, +flat: U32, +ax: U32, +nx: U32,
  +ny: U32, +nz: U32, w: Array<U32>) -> Array<U32> & U32:
  match ao:
    case True{}:
      surf.ao(s, tex, ao.go(7n, lc, ax, nx, ny, nz, 0, ao.get(lc, ax, nx, ny, nz, 7, w)))
    case False{}:
      surf.fin(s, 256, w[Fx.sel((tier >= 1 : U32), tex, flat)])

# The texel of the surface, lit (tier 0: flat, 1: + atlas texels, 2: + occlusion).
def surf(+tier: U32, +lc: Nat, +s: Surf, w: Array<U32>) -> Array<U32> & U32:
  Surf{b, f, t, x, y, z, wt, u, v, fg, sky, fr, wc, sh} = s
  +tex = (W.aux(lc) + U32.shln((b * 4 + face.cls(f) : U32), 8n)
    + U32.shln(U32.shrn(v, 8n), 4n) + U32.shrn(u, 8n) : U32)
  +ax = U32.shrn(f, 1n)
  +nx = (x + Fx.sel(U32.is_eq(f, 0), 1, Fx.sel(U32.is_eq(f, 1), 4294967295, 0)) : U32)
  +ny = (y + Fx.sel(U32.is_eq(f, 2), 1, Fx.sel(U32.is_eq(f, 3), 4294967295, 0)) : U32)
  +nz = (z + Fx.sel(U32.is_eq(f, 4), 1, Fx.sel(U32.is_eq(f, 5), 4294967295, 0)) : U32)
  surf.if((tier >= 2 : U32), tier, lc, s, tex, (W.aux(lc) + U32.shln((b * 4 + 3 : U32), 8n) : U32),
    ax, nx, ny, nz, w)


# Sunlight on a face: 256, or 150 in shadow (the face turned from the
# sun, or a block between it and the sun within 24 blocks: tier 3).
def sh.lit() -> U32:
  256

def sh.dark() -> U32:
  150

def sh.fin(r: Array<U32> & Hit) -> Array<U32> & U32:
  (w, +h) = r
  Hit{b, f, t, x, y, z, wt} = h
  (w, Fx.sel(U32.is_eq(b, 0), sh.lit(), sh.dark()))

def sh.if(on: Bool, facing: Bool, +c: Cam, +px: U32, +py: U32, +pz: U32, w: Array<U32>) ->
  Array<U32> & U32:
  match on facing:
    case False{} _:
      (w, sh.lit())
    case True{} False{}:
      (w, sh.dark())
    case True{} True{}:
      Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
      sh.fin(cast(w, px, py, pz, lx, ly, lz, 98304, 24, lc))

# Whether face f looks toward the sun (the normal's component of l > 0).
def facing(+f: U32, +lx: U32, +ly: U32, +lz: U32) -> Bool:
  +ax = U32.shrn(f, 1n)
  +l = Fx.sel(U32.is_eq(ax, 0), lx, Fx.sel(U32.is_eq(ax, 1), ly, lz))
  U32.is_eq(Fx.sel(U32.is_eq(U32.and(f, 1), 0), Fx.b2u(Fx.slt(0, l)), Fx.b2u(Fx.isneg(l))), 1)

# p nudged 1/64 of a block off face f, along its normal.
def nudge(+f: U32, +ax: U32, +p: U32) -> U32:
  Fx.sel(U32.is_eq(U32.shrn(f, 1n), ax), Fx.sel(U32.is_eq(U32.and(f, 1), 0), (p + 1024 : U32),
    (p - 1024 : U32)), p)

def shade.surf(+tier: U32, +lc: Nat, +s: Surf, r: Array<U32> & U32) -> Array<U32> & U32:
  Surf{b, f, t, x, y, z, wt, u, v, fg, sky, fr, wc, sh} = s
  (w, +sh2) = r
  surf(tier, lc, Surf{b, f, t, x, y, z, wt, u, v, fg, sky, fr, wc, sh2}, w)

# u, v: the hit point's fractions (12 bits) along the face's tangent axes
# (x faces: z, y; y faces: x, z; z faces: x, y), v flipped on the sides so
# texel row 0 is the top.
def shade.hit(+c: Cam, +dx: U32, +dy: U32, +dz: U32, +sky: U32, +fr: U32, +wc: U32, +h: Hit,
  w: Array<U32>) ->
  Array<U32> & U32:
  Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
  Hit{b, f, t, x, y, z, wt} = h
  +hx = at(ox, dx, t)
  +hy = at(oy, dy, t)
  +hz = at(oz, dz, t)
  +px = U32.shrn(U32.and(hx, 65535), 4n)
  +py = U32.shrn(U32.and(hy, 65535), 4n)
  +pz = U32.shrn(U32.and(hz, 65535), 4n)
  +ax2 = U32.shrn(f, 1n)
  +u = Fx.sel(U32.is_eq(ax2, 0), pz, px)
  +v = Fx.sel(U32.is_eq(ax2, 1), pz, (4095 - py : U32))
  shade.surf(tier, lc, Surf{b, f, t, x, y, z, wt, u, v, fog(t, tmax), sky, fr, wc, 256},
    sh.if((tier >= 3 : U32), facing(f, lx, ly, lz), c, nudge(f, 0, hx), nudge(f, 1, hy),
      nudge(f, 2, hz), w))

def shade.pick(miss: Bool, +c: Cam, +dx: U32, +dy: U32, +dz: U32, +sky: U32, +fr: U32, +wc: U32, +h: Hit,
  w: Array<U32>) -> Array<U32> & U32:
  match miss:
    case True{}:
      Hit{b, f, t, x, y, z, wt} = h
      (w, wet(sky, wt, Fx.sel(U32.is_eq(wt, none()), t, (wt + 4096 : U32)), sky, fr, wc))
    case False{}:
      shade.hit(c, dx, dy, dz, sky, fr, wc, h, w)

# ea: how steeply the ray climbs or falls (|dy| over the L1 length of d, out of 256).
def shade.ea(+c: Cam, +sx: U32, +sy: U32, +dx: U32, +dy: U32, +dz: U32, +ea: U32, +h: Hit,
  w: Array<U32>) -> Array<U32> & U32:
  Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
  Hit{b, f, t, x, y, z, wt} = h
  +g = (256 - ea : U32)
  shade.pick(U32.is_eq(b, 0), c, dx, dy, dz, sky(Fx.sel(Fx.isneg(dy), 0, ea), sx, sy, snx, sny, snr),
    (20 + U32.shrn((g * g : U32), 10n) : U32), water.at(ox, oz, dx, dz, wt), h, w)

def shade(+c: Cam, +sx: U32, +sy: U32, +dx: U32, +dy: U32, +dz: U32, r: Array<U32> & Hit) ->
  Array<U32> & U32:
  (w, +h) = r
  +l1 = (Fx.abs(dx) + Fx.abs(dy) + Fx.abs(dz) : U32)
  shade.ea(c, sx, sy, dx, dy, dz, U32.div(U32.shln(Fx.abs(dy), 8n), (l1 + 1 : U32)), h, w)

# The colour of sample (sx, sy).
def pixel(w: Array<U32>, +sx: U32, +sy: U32, +c: Cam) -> Array<U32> & U32:
  Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
  +mx = (sx * 2 + 1 - ws : U32)
  +my = (sy * 2 + 1 - hs : U32)
  +dx = (fx + Fx.asr((ax * mx + bx * my : U32), 1n) : U32)
  +dy = (fy + Fx.asr((ay * mx + by * my : U32), 1n) : U32)
  +dz = (fz + Fx.asr((az * mx + bz * my : U32), 1n) : U32)
  shade(c, sx, sy, dx, dy, dz, cast(w, ox, oy, oz, dx, dy, dz, tmax, U32.shrn(tmax, 12n), lc))

# The framebuffer
# ---------------

type P2 is Type:
  P2{a: Array<U32>, b: Array<U32>}

# Samples i .. i + n (row-major from (x, y)) into fb; r: the colour of (x, y).
def put(~wr: Array<U32> -> U32 -> U32 -> Array<U32>, n: Nat, +x: U32, +y: U32, +c: Cam, fb: Array<U32>, r: Array<U32> & U32) -> P2:
  match n:
    case 0n:
      Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
      (w, +col) = r
      P2{w, wr(fb, (y * ws + x : U32), col)}
    case 1n+p:
      Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
      (w, +col) = r
      +e = U32.is_eq((x + 1 : U32), ws)
      +x2 = Fx.sel(e, 0, (x + 1 : U32))
      +y2 = Fx.sel(e, (y + 1 : U32), y)
      put(~wr, p, x2, y2, c, wr(fb, (y * ws + x : U32), col), pixel(w, x2, y2, c))

def leaf.if(~wr: Array<U32> -> U32 -> U32 -> Array<U32>, e: Bool, +i: U32, +i1: U32, +c: Cam, w: Array<U32>, fb: Array<U32>) -> P2:
  match e:
    case True{}:
      P2{w, fb}
    case False{}:
      Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
      +x = U32.mod(i, ws)
      +y = U32.div(i, ws)
      put(~wr, U32.to_nat((i1 - i - 1 : U32)), x, y, c, fb, pixel(w, x, y, c))

@unsafe
def P2.join(l: P2, r: P2) -> P2:
  P2{la, lb} = l
  P2{ra, rb} = r
  P2{Array.join(U32, la, ra), Array.join(U32, lb, rb)}

# d fork levels over samples [i, i1); a leaf is one flat loop (none when empty).
@unsafe
def node(~wr: Array<U32> -> U32 -> U32 -> Array<U32>, +d: Nat, +i: U32, +i1: U32, +c: Cam, +w: Array<U32>, +fb: Array<U32>) -> P2:
  match d:
    case 0n:
      leaf.if(~wr, (i >= i1 : U32), i, i1, c, w, fb)
    case 1n+e:
      +m = U32.shrn((i + i1 : U32), 1n)
      a b = node(~wr, e, i, m, c, w, fb) node(~wr, e, m, i1, c, w, fb)
      P2.join(a, b)

# The frame into fb (ws x hs, row-major): P2{w, fb}.
def fill(~wr: Array<U32> -> U32 -> U32 -> Array<U32>, +c: Cam, +d: Nat, w: Array<U32>, fb: Array<U32>) -> P2:
  Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
  node(~wr, d, 0, (ws * hs : U32), c, w, fb)

# The window image
# ----------------
# The Image of fb: a quadtree over 2^(k + 4) samples square, tiles of 16 x
# 16 samples written straight-line (a recursion costs a frame per square
# on the device), off-frame quadrants one black Pix. The last frame's
# image rides down the tree and each tile sinks its own quadrant.

type Four is Data:
  Four{a: Image, b: Image, c: Image, d: Image}

def Img.open(old: Image) -> Four:
  match old:
    case Pix{+c}:
      Four{Pix{c}, Pix{c}, Pix{c}, Pix{c}}
    case Qua{a, b, c, d}:
      Four{a, b, c, d}

def I.pix(r: Array<U32> & U32) -> Array<U32> & Image:
  (fb, +c) = r
  (fb, Pix{c})

def I.rd(on: Bool, fb: Array<U32>, +i: U32) -> Array<U32> & U32:
  match on:
    case True{}:
      fb[i]
    case False{}:
      (fb, 0)

# k packs ws (low 16 bits) and hs.
def I.b1(fb: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  +x = x0
  +y = y0
  +k = k0
  +ws = U32.and(k, 65535)
  +hs = U32.shrn(k, 16n)
  I.pix(I.rd(((x < ws) && (y < hs) : U32), fb, (y * ws + x : U32)))

def Q.fin(a: Image, b: Image, c: Image, r: Array<U32> & Image) -> Array<U32> & Image:
  (w, d) = r
  (w, Qua{a, b, c, d})

def Q.c(
  ~f: Array<U32> -> U32 -> U32 -> U32 -> Array<U32> & Image, +x: U32, +y: U32, +s: U32, +k: U32,
  a: Image, b: Image, r: Array<U32> & Image
) -> Array<U32> & Image:
  (w, c) = r
  Q.fin(a, b, c, f(w, (x + s : U32), (y + s : U32), k))

def Q.b(
  ~f: Array<U32> -> U32 -> U32 -> U32 -> Array<U32> & Image, +x: U32, +y: U32, +s: U32, +k: U32,
  a: Image, r: Array<U32> & Image
) -> Array<U32> & Image:
  (w, b) = r
  Q.c(~f, x, y, s, k, a, b, f(w, x, (y + s : U32), k))

def Q.a(
  ~f: Array<U32> -> U32 -> U32 -> U32 -> Array<U32> & Image, +x: U32, +y: U32, +s: U32, +k: U32,
  r: Array<U32> & Image
) -> Array<U32> & Image:
  (w, a) = r
  Q.b(~f, x, y, s, k, a, f(w, (x + s : U32), y, k))

def Q.go(
  ~f: Array<U32> -> U32 -> U32 -> U32 -> Array<U32> & Image, w: Array<U32>, +x: U32, +y: U32,
  +s: U32, +k: U32
) -> Array<U32> & Image:
  Q.a(~f, x, y, s, k, f(w, x, y, k))

def I.b2(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~I.b1, w, x0, y0, 1, k0)

def I.b4(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~I.b2, w, x0, y0, 2, k0)

def I.b8(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~I.b4, w, x0, y0, 4, k0)

def I.b16(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~I.b8, w, x0, y0, 8, k0)

@unsafe
def J.four(ra: Array<U32> & Image, rb: Array<U32> & Image, rc: Array<U32> & Image,
  rd: Array<U32> & Image) -> Array<U32> & Image:
  (wa, ia) = ra
  (wb, ib) = rb
  (wc, ic) = rc
  (wd, id) = rd
  (Array.join(U32, Array.join(U32, wa, wb), Array.join(U32, wc, wd)), Qua{ia, ib, ic, id})

def J.off(w: Array<U32>) -> Array<U32> & Image:
  (w, Pix{0})

@unsafe
def I.node(+k: Nat, on: Bool, +x: U32, +y: U32, +wh: U32, +fb: Array<U32>, old: Four) ->
  Array<U32> & Image:
  match k on:
    case _ False{}:
      J.off(fb)
    case 0n True{}:
      I.b16(fb, x, y, wh)
    case 1n+e True{}:
      Four{oa, ob, oc, od} = old
      +s = U32.shln(16, e)
      +x1 = (x + s : U32)
      +y1 = (y + s : U32)
      +ws = U32.and(wh, 65535)
      +hs = U32.shrn(wh, 16n)
      a b c d = I.node(e, True{}, x, y, wh, fb, Img.open(oa))
        I.node(e, (x1 < ws : U32), x1, y, wh, fb, Img.open(ob))
        I.node(e, (y1 < hs : U32), x, y1, wh, fb, Img.open(oc))
        I.node(e, ((x1 < ws) && (y1 < hs) : U32), x1, y1, wh, fb, Img.open(od))
      J.four(a, b, c, d)

# The frame and its image: Out{w, fb, img}.
type Out is Type:
  Out{w: Array<U32>, fb: Array<U32>, img: Image}

def O.fin(w: Array<U32>, r: Array<U32> & Image) -> Out:
  (fb, img) = r
  Out{w, fb, img}

def O.img(+k: Nat, +ws: U32, +hs: U32, old: Image, p: P2) -> Out:
  P2{w, fb} = p
  O.fin(w, I.node(k, True{}, 0, 0, U32.or(ws, U32.shln(hs, 16n)), fb, Img.open(old)))

# fill, then the Image of fb over 2^(k + 4) samples: both in one call (one
# GPU turn under !), the last image dropped inside it.
def draw(~wr: Array<U32> -> U32 -> U32 -> Array<U32>, +c: Cam, +d: Nat, +k: Nat, w: Array<U32>, fb: Array<U32>, old: Image) -> Out:
  Cam{ox, oy, oz, fx, fy, fz, ax, ay, az, bx, by, bz, ws, hs, tmax, tier, lx, ly, lz, snx, sny, snr, lc} = c
  O.img(k, ws, hs, old, fill(~wr, c, d, w, fb))

# Output
# ------

def ppm.bytes(s: String, acc: List<&2, U32>) -> List<&2, U32>:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{c}, t}:
      c <> ppm.bytes(t, acc)

# The samples n .. 0 as R G B bytes before acc (walks down: index order).
def ppm.go(n: Nat, acc: List<&2, U32>, r: Array<U32> & U32) -> Array<U32> & List<&2, U32>:
  match n:
    case 0n:
      (a, +v) = r
      (a, ch(v, 16n) <> ch(v, 8n) <> ch(v, 0n) <> acc)
    case 1n++p:
      (a, +v) = r
      ppm.go(p, ch(v, 16n) <> ch(v, 8n) <> ch(v, 0n) <> acc, a[U32.from_nat(p)])

def ppm.head(+ws: U32, +hs: U32, r: Array<U32> & List<&2, U32>) -> Array<U32> & List<&2, U32>:
  (a, px) = r
  (a, ppm.bytes("P6\n" ++ U32.show(ws) ++ " " ++ U32.show(hs) ++ "\n255\n", px))

# (fb, the frame as a binary PPM file's bytes).
def ppm(+ws: U32, +hs: U32, fb: Array<U32>) -> Array<U32> & List<&2, U32>:
  +n = (ws * hs - 1 : U32)
  ppm.head(ws, hs, ppm.go(U32.to_nat(n), Nil{}, fb[n]))
