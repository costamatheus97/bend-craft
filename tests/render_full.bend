# tests/render_full.bend: tests/render.bend on the full 256 x 64 x 256 world (lc = 4), 320 x 180
# samples, on the native lanes and the GPU.
#lanes c1,c16,gpu,main
# - tiers 0 (flat), 1 (textures), 2 (+ occlusion), 3 (+ shadows) at fork depth 0 (one leaf), then tier 3 at
#   depths 4 and 11 (one sample a leaf): the framebuffer hash must not depend on the depth, and
#   the window Image (converted in the same bang) must hash the same on every lane;
# - the bounds pass: the frame with a counting writer writes every sample exactly once and
#   nothing past the frame (an index out of range would wrap onto some sample: a 2).
import Base
import ../world.bend as W
import ../render.bend as R
import ../rng.bend as Rng
import ../fx.bend as Fx

type Cfg is Data:
  Cfg{lc: Nat, ws: U32, hs: U32, px: U32, py: U32, pz: U32, yaw: U32, pitch: U32, vd: U32, k: Nat}

type Fr is Type:
  Fr{w: Array<U32>, fb: Array<U32>, hf: U32, hi: U32}

def ih(img: Image) -> U32:
  match img:
    case Pix{+c}:
      Rng.mix((c + 1 : U32))
    case Qua{a, b, c, d}:
      Rng.mix(U32.xor(ih(a), Rng.mix((ih(b) + Rng.mix((ih(c) * 3 + Rng.mix(ih(d)) : U32)) : U32))))

def fr.h(w: Array<U32>, +hi: U32, r: Array<U32> & U32) -> Fr:
  (fb, +hf) = r
  Fr{w, fb, hf, hi}

def fr.out(o: R.Out) -> Fr:
  R.Out{w, fb, img} = o
  fr.h(w, ih(img), W.hash(fb))

def cam(+g: Cfg, +tier: U32) -> R.Cam:
  Cfg{lc, ws, hs, px, py, pz, yaw, pitch, vd, k} = g
  R.cam(px, py, pz, yaw, pitch, ws, hs, vd, tier, 6000, 3000, lc)

def tier.of(+j: U32) -> U32:
  Fx.sel((j < 4 : U32), j, 3)

def d.of(+j: U32) -> Nat:
  U32.to_nat(Fx.sel((j < 4 : U32), 0, Fx.sel(U32.is_eq(j, 4), 4, 11)))

def frame(+g: Cfg, +j: U32, w: Array<U32>, fb: Array<U32>) -> Fr:
  Cfg{lc, ws, hs, px, py, pz, yaw, pitch, vd, k} = g
  fr.out(R.draw!(~W.Put.set, cam(g, tier.of(j)), d.of(j), k, w, fb, Pix{0}))

def line(+j: U32, +hf: U32, +hi: U32) -> String:
  "render tier " ++ U32.show(tier.of(j)) ++ " d " ++ Nat.show(d.of(j)) ++ " fb " ++ U32.show(hf)
    ++ " img " ++ U32.show(hi)

def go(n: Nat, +j: U32, +g: Cfg, fr: Fr) -> String:
  match n:
    case 0n:
      Fr{w, fb, hf, hi} = fr
      line(j, hf, hi)
    case 1n+m:
      Fr{w, fb, hf, hi} = fr
      line(j, hf, hi) ++ "\n" ++ go(m, (j + 1 : U32), g, frame(g, (j + 1 : U32), w, fb))

# The eye: 2.6 blocks over the ground (or the sea) at (x, z) (blocks), in 16.16.
def eye(+lc: Nat, +x: U32, +z: U32, r: Array<U32> & U32) -> U32:
  (hm, +h) = r
  +g = U32.and(h, 255)
  (U32.shln(Fx.sel((g < W.sea() : U32), W.sea(), g), 16n) + 170394 : U32)

def cfg.p(+lc: Nat, +ws: U32, +hs: U32, +x: U32, +z: U32, +yaw: U32, +pitch: U32, +vd: U32,
  +k: Nat, p: W.P2) -> String:
  W.P2{hm, w} = p
  +py = eye(lc, x, z, hm[W.col(lc, x, z)])
  go(5n, 0, Cfg{lc, ws, hs, (U32.shln(x, 16n) + 32768 : U32), py, (U32.shln(z, 16n) + 32768 : U32), yaw, pitch, vd, k},
    frame(Cfg{lc, ws, hs, (U32.shln(x, 16n) + 32768 : U32), py, (U32.shln(z, 16n) + 32768 : U32), yaw, pitch, vd, k},
      0, R.tex(lc, w), Array.new(U32, 16n, 0)))

def scene(+lc: Nat, +seed: U32) -> W.P2:
  W.gen!(~W.Put.set, 13n, lc, seed, W.hm.new(lc), W.new(lc))

# The bounds pass: (fb words other than 1 among the ws * hs) + (words past them other than 0).
def bad.fin(+n: U32, r: Array<U32> & U32, +a: U32) -> U32:
  (fb, +b) = r
  (a + b - n : U32)

def bad.cnt(+n: U32, r: Array<U32> & U32) -> U32:
  (fb, +a) = r
  bad.fin(n, W.ne(0, fb), a)

def bad.p(+n: U32, p: R.P2) -> U32:
  R.P2{w, fb} = p
  bad.cnt(n, W.ne.n(n, 1, fb))

def bad.s(+lc: Nat, +ws: U32, +hs: U32, +x: U32, +z: U32, p: W.P2) -> U32:
  W.P2{hm, w} = p
  bad.p((ws * hs : U32), R.fill!(~W.Put.count, R.cam(U32.shln(x, 16n), 3276800, U32.shln(z, 16n), 8192,
    63000, ws, hs, 48, 3, 6000, 3000, lc), 5n, R.tex(lc, w), Array.new(U32, 16n, 0)))

# The direct image (render.bend's direct: no framebuffer) against draw's,
# both with the hotbar and the crosshair on, compared as pictures (a hash
# that sees a Pix over a square as the square's pixels, so the trees may
# differ where they cut off-frame quadrants).
def cmb(+a: U32, +b: U32, +c: U32, +d: U32) -> U32:
  +h4 = Rng.mix(d)
  +h3 = Rng.mix((c * 3 + h4 : U32))
  +h2 = Rng.mix((b + h3 : U32))
  Rng.mix(U32.xor(a, h2))

def ch.pix(+c: U32, n: Nat) -> U32:
  match n:
    case 0n:
      Rng.mix((c + 1 : U32))
    case 1n+p:
      +h = ch.pix(c, p)
      cmb(h, h, h, h)

def ch(img: Image, +n: Nat) -> U32:
  match img:
    case Pix{+c}:
      ch.pix(c, n)
    case Qua{a, b, c, d}:
      cmb(ch(a, Nat.sub(n, 1n)), ch(b, Nat.sub(n, 1n)), ch(c, Nat.sub(n, 1n)), ch(d, Nat.sub(n, 1n)))

def same.fin(+n: Nat, +h1: U32, r: Array<U32> & Image) -> String:
  (w, img) = r
  +h2 = ch(img, n)
  "direct tier 3 ui same-picture " ++ U32.show(Fx.b2u(U32.is_eq(h1, h2))) ++ " " ++ U32.show(h2)

def same.out(+c: R.Cam, +kd: Nat, +n: Nat, o: R.Out) -> String:
  R.Out{w, fb, img} = o
  same.fin(n, ch(img, n), R.direct!(c, kd, w, Pix{0}))

def same(+lc: Nat, +ws: U32, +hs: U32, +x: U32, +z: U32, +k: Nat, +kd: Nat, +n: Nat, +fl: Nat,
  p: W.P2) -> String:
  W.P2{hm, w} = p
  +c = R.cam.ui(R.cam(U32.shln(x, 16n), 3276800, U32.shln(z, 16n), 8192, 63000, ws, hs, 48, 3, 6000,
    3000, lc), 4, 4294967295, 4294967295, 4294967295)
  same.out(c, kd, n, R.draw!(~W.Put.set, c, 5n, k, R.tex(lc, w), Array.new(U32, fl, 0), Pix{0}))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(cfg.p(4n, 320, 180, 200, 60, 8192, 63000, 64, 5n, scene(4n, 1)))
    IO.print("bounds tier 3 bad " ++ U32.show(bad.s(4n, 320, 180, 128, 128, scene(4n, 1))))
    IO.print(same(4n, 320, 180, 128, 128, 5n, 7n, 9n, 16n, scene(4n, 1)))
#|render tier 0 d 0 fb 1946779282 img 4227631818
#|render tier 1 d 0 fb 3986443912 img 452468023
#|render tier 2 d 0 fb 2162011840 img 3620368074
#|render tier 3 d 0 fb 2460147521 img 1916533954
#|render tier 3 d 4 fb 2460147521 img 1916533954
#|render tier 3 d 11 fb 2460147521 img 1916533954
#|bounds tier 3 bad 0
#|direct tier 3 ui same-picture 1 2676129964
