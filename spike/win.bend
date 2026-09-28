# spike/win.bend: the window path, measured before any graphics.
#
# A frame is a per-pixel-varying picture of ws x hs samples (each sample
# reads the "world" array SPK_R + 1 times, threaded linearly), shown in a
# window of SPK_W x SPK_H px through an Image whose leaves cover
# 2^SPK_U x 2^SPK_U px (an upscale when SPK_U > 0).
#
#   SPK_MODE 0  direct: the bang builds the Image quadtree (tiles of 16 x 16 samples)
#   SPK_MODE 1  flat: the bang writes a flat Array<U32> framebuffer (a fork over rows),
#               then converts it into the Image in the same bang (a second fork tree)
#   SPK_MODE 2  flat, and the conversion runs on the host (its own fork tree)
#
# Each frame prints: f <n> bang_us <us> conv_us <us> show_us <us> (show = Window.frame:
# the fill, the pace and the blit; the offscreen harness times the fill alone).
import Base

def Clock.us() -> IO(U32):
  import "./clock.c"
  import "./clock.js"

type Four is Data:
  Four{a: Image, b: Image, c: Image, d: Image}

type P2 is Type:
  P2{a: Array<U32>, b: Array<U32>}

def Img.open(old: Image) -> Four:
  match old:
    case Pix{+c}:
      Four{Pix{c}, Pix{c}, Pix{c}, Pix{c}}
    case Qua{a, b, c, d}:
      Four{a, b, c, d}

def mix(+x: U32) -> U32:
  +a = (U32.xor(x, U32.shrn(x, 16n)) * 2146121005 : U32)
  +b = (U32.xor(a, U32.shrn(a, 15n)) * 2221713035 : U32)
  U32.xor(b, U32.shrn(b, 16n))

def word(c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

# The world: 2^20 words.
def Wmask() -> U32:
  1048575

# n more reads of the world, each at an index mixed from the last value.
def Px.rd(n: Nat, +i: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (w, +v) = r
      (w, U32.xor(acc, v))
    case 1n+p:
      (w, +v) = r
      +j = mix((i + v : U32))
      Px.rd(p, j, U32.xor(acc, v), w[U32.and(j, Wmask())])

# The color of sample (x, y); k = frame << 8 | reads.
def Px.col(w: Array<U32>, +x: U32, +y: U32, +k: U32) -> Array<U32> & U32:
  +s = mix(U32.xor(U32.xor((x * 73856093 : U32), (y * 19349663 : U32)), U32.shrn(k, 8n)))
  Px.rd(U32.to_nat(U32.and(k, 255)), s, s, w[U32.and(s, Wmask())])

def Px.pix(r: Array<U32> & U32) -> Array<U32> & Image:
  (w, +c) = r
  (w, Pix{U32.and(c, 16777215)})

def Px.b1(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  +x = x0
  +y = y0
  +k = k0
  Px.pix(Px.col(w, x, y, k))

# Four squares of side s, threading the world through them in order.
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

def Px.b2(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~Px.b1, w, x0, y0, 1, k0)

def Px.b4(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~Px.b2, w, x0, y0, 2, k0)

def Px.b8(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~Px.b4, w, x0, y0, 4, k0)

def Px.b16(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~Px.b8, w, x0, y0, 8, k0)

# Four (array, image) pairs joined: one array handle back, one Qua.
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

# Mode 0: a node of side 16 << k samples at (x, y); off the frame it is one
# black Pix; a tile (k = 0) sinks the last frame's tile.
@unsafe
def D.node(+k: Nat, on: Bool, +x: U32, +y: U32, +ws: U32, +hs: U32, +kk: U32, +w: Array<U32>,
  old: Four) -> Array<U32> & Image:
  match k on:
    case _ False{}:
      J.off(w)
    case 0n True{}:
      Px.b16(w, x, y, kk)
    case 1n+e True{}:
      Four{oa, ob, oc, od} = old
      +s = U32.shln(16, e)
      +x1 = (x + s : U32)
      +y1 = (y + s : U32)
      a b c d = D.node(e, True{}, x, y, ws, hs, kk, w, Img.open(oa))
        D.node(e, (x1 < ws : U32), x1, y, ws, hs, kk, w, Img.open(ob))
        D.node(e, (y1 < hs : U32), x, y1, ws, hs, kk, w, Img.open(oc))
        D.node(e, ((x1 < ws) && (y1 < hs) : U32), x1, y1, ws, hs, kk, w, Img.open(od))
      J.four(a, b, c, d)

# Mode 1/2: the flat framebuffer. A leaf: rows [y, y1) of ws samples, one flat loop.
def F.put(n: Nat, +x: U32, +y: U32, +ws: U32, +kk: U32, fb: Array<U32>, r: Array<U32> & U32) ->
  P2:
  match n:
    case 0n:
      (w, +c) = r
      P2{w, fb[(y * ws + x : U32)] <- U32.and(c, 16777215)}
    case 1n+p:
      (w, +c) = r
      +i = (y * ws + x : U32)
      +e = U32.is_eq((x + 1 : U32), ws)
      +x2 = word(e, 0, (x + 1 : U32))
      +y2 = word(e, (y + 1 : U32), y)
      F.put(p, x2, y2, ws, kk, fb[i] <- U32.and(c, 16777215), Px.col(w, x2, y2, kk))

def F.leaf.if(e: Bool, +i: U32, +i1: U32, +ws: U32, +kk: U32, w: Array<U32>, fb: Array<U32>) -> P2:
  match e:
    case True{}:
      P2{w, fb}
    case False{}:
      +x = U32.mod(i, ws)
      +y = U32.div(i, ws)
      F.put(U32.to_nat((i1 - i - 1 : U32)), x, y, ws, kk, fb, Px.col(w, x, y, kk))

# A leaf: samples [i, i1) in row-major order, one flat loop (none when empty).
def F.leaf(+i: U32, +i1: U32, +ws: U32, +kk: U32, w: Array<U32>, fb: Array<U32>) -> P2:
  F.leaf.if(U32.is_ge(i, i1), i, i1, ws, kk, w, fb)

@unsafe
def P2.join(l: P2, r: P2) -> P2:
  P2{la, lb} = l
  P2{ra, rb} = r
  P2{Array.join(U32, la, ra), Array.join(U32, lb, rb)}

# d fork levels over samples [i, i1).
@unsafe
def F.node(+d: Nat, +i: U32, +i1: U32, +ws: U32, +kk: U32, +w: Array<U32>, +fb: Array<U32>) -> P2:
  match d:
    case 0n:
      F.leaf(i, i1, ws, kk, w, fb)
    case 1n+e:
      +m = ((i + i1) / 2 : U32)
      a b = F.node(e, i, m, ws, kk, w, fb) F.node(e, m, i1, ws, kk, w, fb)
      P2.join(a, b)

# The conversion: the Image of the framebuffer, tiles of 16 x 16 samples;
# a sample off the frame is black (never read: a wrapped index is silent).
def C.rd(on: Bool, fb: Array<U32>, +i: U32) -> Array<U32> & U32:
  match on:
    case True{}:
      fb[i]
    case False{}:
      (fb, 0)

def C.b1(fb: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  +x = x0
  +y = y0
  +k = k0
  +ws = U32.and(k, 65535)
  +hs = U32.shrn(k, 16n)
  Px.pix(C.rd(((x < ws) && (y < hs) : U32), fb, (y * ws + x : U32)))

def C.b2(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~C.b1, w, x0, y0, 1, k0)

def C.b4(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~C.b2, w, x0, y0, 2, k0)

def C.b8(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~C.b4, w, x0, y0, 4, k0)

def C.b16(w: Array<U32>, x0: U32, y0: U32, k0: U32) -> Array<U32> & Image:
  Q.go(~C.b8, w, x0, y0, 8, k0)

@unsafe
def C.node(+k: Nat, on: Bool, +x: U32, +y: U32, +wh: U32, +fb: Array<U32>, old: Four) ->
  Array<U32> & Image:
  match k on:
    case _ False{}:
      J.off(fb)
    case 0n True{}:
      C.b16(fb, x, y, wh)
    case 1n+e True{}:
      Four{oa, ob, oc, od} = old
      +s = U32.shln(16, e)
      +x1 = (x + s : U32)
      +y1 = (y + s : U32)
      +ws = U32.and(wh, 65535)
      +hs = U32.shrn(wh, 16n)
      a b c d = C.node(e, True{}, x, y, wh, fb, Img.open(oa))
        C.node(e, (x1 < ws : U32), x1, y, wh, fb, Img.open(ob))
        C.node(e, (y1 < hs : U32), x, y1, wh, fb, Img.open(oc))
        C.node(e, ((x1 < ws) && (y1 < hs) : U32), x1, y1, wh, fb, Img.open(od))
      J.four(a, b, c, d)

# The state: the world, the framebuffer, the frame counter.
type St is Type:
  St{w: Array<U32>, fb: Array<U32>}

type Out is Type:
  Out{w: Array<U32>, fb: Array<U32>, img: Image}

def O.d(fb: Array<U32>, r: Array<U32> & Image) -> Out:
  (w, img) = r
  Out{w, fb, img}

def O.c(w: Array<U32>, r: Array<U32> & Image) -> Out:
  (fb, img) = r
  Out{w, fb, img}

def O.conv(+k: Nat, +ws: U32, +hs: U32, old: Image, p: P2) -> Out:
  P2{w, fb} = p
  O.c(w, C.node(k, True{}, 0, 0, U32.or(ws, U32.shln(hs, 16n)), fb, Img.open(old)))

# Mode 0, one bang.
def S.direct(+k: Nat, +ws: U32, +hs: U32, +kk: U32, s: St, old: Image) -> Out:
  St{w, fb} = s
  O.d(fb, D.node!(k, True{}, 0, 0, ws, hs, kk, w, Img.open(old)))

# Mode 1, one bang: fill then convert.
def S.flat.go(+k: Nat, +d: Nat, +ws: U32, +hs: U32, +kk: U32, w: Array<U32>, fb: Array<U32>,
  old: Image) -> Out:
  O.conv(k, ws, hs, old, F.node(d, 0, (ws * hs : U32), ws, kk, w, fb))

def S.flat(+k: Nat, +d: Nat, +ws: U32, +hs: U32, +kk: U32, s: St, old: Image) -> Out:
  St{w, fb} = s
  S.flat.go!(k, d, ws, hs, kk, w, fb, old)

# Mode 2: the fill in a bang; the conversion is S.host, on the host.
def S.fill(+d: Nat, +ws: U32, +hs: U32, +kk: U32, s: St) -> P2:
  St{w, fb} = s
  F.node!(d, 0, (ws * hs : U32), ws, kk, w, fb)

def S.host(+k: Nat, +ws: U32, +hs: U32, old: Image, p: P2) -> Out:
  O.conv(k, ws, hs, old, p)

# Hash of the framebuffer's first n samples (a cross-lane check).
def H.go(n: Nat, +i: U32, +h: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (a, +v) = r
      (a, (h + mix(U32.xor((i * 2654435769 : U32), v)) : U32))
    case 1n+p:
      (a, +v) = r
      +i2 = (i + 1 : U32)
      H.go(p, i2, (h + mix(U32.xor((i * 2654435769 : U32), v)) : U32), a[i2])

# Environment numbers
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

type Cfg is Data:
  Cfg{mode: U32, k: Nat, d: Nat, ws: U32, hs: U32, r: U32, frames: U32}

def St.split(o: Out) -> St & Image:
  Out{w, fb, img} = o
  (St{w, fb}, img)

def Show.line(+f: U32, +a: U32, +b: U32, +c: U32, +d: U32) -> String:
  "f " ++ U32.show(f) ++ " bang_us " ++ U32.show((b - a : U32)) ++ " conv_us "
    ++ U32.show((c - b : U32)) ++ " show_us " ++ U32.show((d - c : U32))

def Run.shown(shown: Window & Image & List<Event>, s: St, rest: Window -> St -> Image -> IO(Unit))
  -> IO(Unit):
  (window, img, events) = shown
  rest(window, s, img)

def Run.after(+cfg: Cfg, +f: U32, +t0: U32, +t1: U32, window: Window, o: Out,
  rest: Window -> St -> Image -> IO(Unit)) -> IO(Unit):
  Out{w, fb, img} = o
  do IO<Unit>:
    +t2 : U32 <- Clock.us()
    shown : Window & Image & List<Event> <- Window.frame(window, img)
    +t3 : U32 <- Clock.us()
    Unit <- IO.print(Show.line(f, t0, t1, t2, t3))
    Run.shown(shown, St{w, fb}, rest)

def Run.kk(+cfg: Cfg, +f: U32) -> U32:
  Cfg{mode, k, d, ws, hs, r, frames} = cfg
  U32.or(U32.shln(f, 8n), r)

def Run.host(+k: Nat, +ws: U32, +hs: U32, old: Image, p: P2) -> IO(Out):
  do IO<Out>:
    +now : Nat <- IO.now()
    IO.pure(Out, S.host(k, ws, hs, old, p))

def Run.bang.m(+mode: U32, +k: Nat, +d: Nat, +ws: U32, +hs: U32, +kk: U32, s: St, old: Image) ->
  IO(Out):
  match mode:
    case 0:
      IO.pure(Out, S.direct(k, ws, hs, kk, s, old))
    case 1:
      IO.pure(Out, S.flat(k, d, ws, hs, kk, s, old))
    case _:
      IO.bind(P2, Out, IO.pure(P2, S.fill(d, ws, hs, kk, s)), p => Run.host(k, ws, hs, old, p))

def Run.bang(+cfg: Cfg, +f: U32, s: St, old: Image) -> IO(Out):
  Cfg{mode, k, d, ws, hs, r, frames} = cfg
  Run.bang.m(mode, k, d, ws, hs, Run.kk(cfg, f), s, old)

@unsafe
def Run.loop(+cfg: Cfg, n: Nat, +f: U32, window: Window, s: St, old: Image) -> IO(Unit):
  match n:
    case 0n:
      Window.close(window)
    case 1n+p:
      do IO<Unit>:
        +t0 : U32 <- Clock.us()
        o : Out <- Run.bang(cfg, f, s, old)
        +t1 : U32 <- Clock.us()
        Run.after(cfg, f, t0, t1, window, o, w => s2 => i => Run.loop(cfg, p, (f + 1 : U32), w, s2, i))

def main() -> IO(Unit):
  do IO<Unit>:
    m : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_MODE")
    ww : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_W")
    hh : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_H")
    uu : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_U")
    rr : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_R")
    dd : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_D")
    nn : Result<&1, &1, U32 & String, String> <- IO.get_env("SPK_N")
    +nf : U32 = Env.num(nn, 60)
    +w : U32 = Env.num(ww, 1280)
    +h : U32 = Env.num(hh, 720)
    +u : U32 = Env.num(uu, 0)
    +ws : U32 = U32.shrn((w + U32.shln(1, U32.to_nat(u)) - 1 : U32), U32.to_nat(u))
    +hs : U32 = U32.shrn((h + U32.shln(1, U32.to_nat(u)) - 1 : U32), U32.to_nat(u))
    +lk : Nat = Nat.sub(U32.log2((U32.max(w, h) * 2 - 1 : U32)), Nat.add(U32.to_nat(u), 4n))
    +cfg : Cfg = Cfg{Env.num(m, 0), lk, U32.to_nat(Env.num(dd, 13)), ws, hs, Env.num(rr, 0),
      0}
    window : Window <- IO.try(Window, Window.open("spike", w, h))
    Unit <- IO.print("cfg ws " ++ U32.show(ws) ++ " hs " ++ U32.show(hs) ++ " k " ++ Nat.show(lk))
    Run.loop(cfg, U32.to_nat(nf), 0, window,
      St{Array.new(U32, 20n, 7), Array.new(U32, 22n, 0)}, Pix{0})
