# bench/render.bend: frame time of the renderer, and screenshots.
# Env (defaults in brackets):
#   BR_LC [4] world size; BR_SEED [1]; BR_W, BR_H [320, 180] samples; BR_TIER [2]; BR_VD [64]
#   view distance (blocks); BR_X, BR_Z [128, 128] eye column; BR_UP [2] eye height over the
#   ground (blocks); BR_YAW [8192], BR_PITCH [63000] (65536 a turn); BR_SPIN [0] yaw per frame;
#   BR_D [13] fork depth; BR_K [5] Image quadtree levels over 16 x 16 tiles (2^(k+4) >= W, H);
#   BR_N [10] frames; BR_BANG [1] (0: a plain call, the CPU lane); BR_IMG [1] (0: the flat
#   framebuffer only, no window Image); BR_PPM [none] write the last frame there (P6).
# Prints: frame <i> us <us> per frame, then: render ... fb <hash> img <hash>.
import Base
import ../world.bend as W
import ../render.bend as R
import ../rng.bend as Rng
import ../fx.bend as Fx

def Clock.us() -> IO(U32):
  import "../clock.c"
  import "../clock.js"

type Cfg is Data:
  Cfg{lc: Nat, ws: U32, hs: U32, tier: U32, vd: U32, px: U32, py: U32, pz: U32, yaw: U32,
    pitch: U32, spin: U32, d: Nat, k: Nat, bang: U32, img: U32}

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

def num(name: String, +default: U32) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    IO.pure(U32, Env.num(r, default))

def ih(img: Image) -> U32:
  match img:
    case Pix{+c}:
      Rng.mix((c + 1 : U32))
    case Qua{a, b, c, d}:
      Rng.mix(U32.xor(ih(a), Rng.mix((ih(b) + Rng.mix((ih(c) * 3 + Rng.mix(ih(d)) : U32)) : U32))))

def cam(+g: Cfg, +i: U32) -> R.Cam:
  Cfg{lc, ws, hs, tier, vd, px, py, pz, yaw, pitch, spin, d, k, bang, img} = g
  R.cam(px, py, pz, (yaw + spin * i : U32), pitch, ws, hs, vd, tier, lc)

def draw.bang(+c: R.Cam, +d: Nat, +k: Nat, w: Array<U32>, fb: Array<U32>, old: Image) -> R.Out:
  R.draw!(~W.Put.set, c, d, k, w, fb, old)

def fill.bang(+c: R.Cam, +d: Nat, w: Array<U32>, fb: Array<U32>) -> R.P2:
  R.fill!(~W.Put.set, c, d, w, fb)

def keep(old: Image, p: R.P2) -> R.Out:
  R.P2{w, fb} = p
  R.Out{w, fb, old}

def frame.img(img: U32, +bang: U32, +c: R.Cam, +d: Nat, +k: Nat, w: Array<U32>, fb: Array<U32>,
  old: Image) -> R.Out:
  match img bang:
    case 0 0:
      keep(old, R.fill(~W.Put.set, c, d, w, fb))
    case 0 _:
      keep(old, fill.bang(c, d, w, fb))
    case _ 0:
      R.draw(~W.Put.set, c, d, k, w, fb, old)
    case _ _:
      draw.bang(c, d, k, w, fb, old)

def frame(+g: Cfg, +i: U32, o: R.Out) -> R.Out:
  Cfg{lc, ws, hs, tier, vd, px, py, pz, yaw, pitch, spin, d, k, bang, img} = g
  R.Out{w, fb, old} = o
  frame.img(img, bang, cam(g, i), d, k, w, fb, old)

def write.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, res) = r
  do IO<Unit>:
    Unit <- IO.pass(Unit, res)
    File.close(f)

def write(path: String, xs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "w"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    write.fin(r)

def ppm.fin(path: String, r: Array<U32> & List<&2, U32>) -> IO(Unit):
  (fb, bytes) = r
  write(path, bytes)

def ppm(r: Result<&1, &1, U32 & String, String>, +ws: U32, +hs: U32, fb: Array<U32>) -> IO(Unit):
  match r:
    case Fail{_}:
      IO.pure(Unit, Unit{})
    case Done{path}:
      ppm.fin(path, R.ppm(ws, hs, fb))

def fin.h(+g: Cfg, +hi: U32, r: Array<U32> & U32) -> IO(Unit):
  Cfg{lc, ws, hs, tier, vd, px, py, pz, yaw, pitch, spin, d, k, bang, img} = g
  (fb, +hf) = r
  do IO<Unit>:
    Unit <- IO.print("render lc " ++ Nat.show(lc) ++ " " ++ U32.show(ws) ++ "x" ++ U32.show(hs)
      ++ " tier " ++ U32.show(tier) ++ " vd " ++ U32.show(vd) ++ " d " ++ Nat.show(d) ++ " bang "
      ++ U32.show(bang) ++ " img " ++ U32.show(img) ++ " fb " ++ U32.show(hf) ++ " img "
      ++ U32.show(hi))
    p : Result<&1, &1, U32 & String, String> <- IO.get_env("BR_PPM")
    ppm(p, ws, hs, fb)

def fin(+g: Cfg, o: R.Out) -> IO(Unit):
  R.Out{w, fb, img} = o
  fin.h(g, ih(img), W.hash(fb))

def loop(n: Nat, +i: U32, +g: Cfg, o: R.Out) -> IO(Unit):
  match n:
    case 0n:
      fin(g, o)
    case 1n+p:
      do IO<Unit>:
        +t0 : U32 <- Clock.us()
        o2 : R.Out <- IO.pure(R.Out, frame(g, i, o))
        +t1 : U32 <- Clock.us()
        IO.print("frame " ++ U32.show(i) ++ " us " ++ U32.show((t1 - t0 : U32)))
        loop(p, (i + 1 : U32), g, o2)

def eye(+up: U32, r: Array<U32> & U32) -> U32:
  (hm, +h) = r
  +g = U32.and(h, 255)
  (U32.shln((Fx.sel((g < W.sea() : U32), W.sea(), g) + up : U32), 16n) + 32768 : U32)

def start(+n: Nat, +g0: Cfg, +up: U32, p: W.P2) -> IO(Unit):
  Cfg{lc, ws, hs, tier, vd, px, py, pz, yaw, pitch, spin, d, k, bang, img} = g0
  W.P2{hm, w} = p
  +x = U32.shrn(px, 16n)
  +z = U32.shrn(pz, 16n)
  loop(n, 0, Cfg{lc, ws, hs, tier, vd, px, eye(up, hm[W.col(lc, x, z)]), pz, yaw, pitch, spin, d,
    k, bang, img}, R.Out{R.tex(lc, w), Array.new(U32, 22n, 0), Pix{0}})

def scene(+lc: Nat, +seed: U32) -> W.P2:
  W.gen!(~W.Put.set, 13n, lc, seed, W.hm.new(lc), W.new(lc))

def main() -> IO(Unit):
  do IO<Unit>:
    +lc : U32 <- num("BR_LC", 4)
    +seed : U32 <- num("BR_SEED", 1)
    +ws : U32 <- num("BR_W", 320)
    +hs : U32 <- num("BR_H", 180)
    +tier : U32 <- num("BR_TIER", 2)
    +vd : U32 <- num("BR_VD", 64)
    +x : U32 <- num("BR_X", 128)
    +z : U32 <- num("BR_Z", 128)
    +up : U32 <- num("BR_UP", 2)
    +yaw : U32 <- num("BR_YAW", 8192)
    +pitch : U32 <- num("BR_PITCH", 63000)
    +spin : U32 <- num("BR_SPIN", 0)
    +d : U32 <- num("BR_D", 13)
    +k : U32 <- num("BR_K", 5)
    +n : U32 <- num("BR_N", 10)
    +bang : U32 <- num("BR_BANG", 1)
    +img : U32 <- num("BR_IMG", 1)
    start(U32.to_nat(n), Cfg{U32.to_nat(lc), ws, hs, tier, vd, (U32.shln(x, 16n) + 32768 : U32), 0,
      (U32.shln(z, 16n) + 32768 : U32), yaw, pitch, spin, U32.to_nat(d), U32.to_nat(k), bang, img},
      up, scene(U32.to_nat(lc), seed))
