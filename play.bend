# play.bend: bend-craft in a window.
#
#   WASD move, space jumps (swims up), the mouse or the arrows turn and look, left button or Q
#   breaks, right button or E places, 1-9 pick the block, P pauses, Esc or closing quits.
#
# Env (defaults in brackets): PLAY_W, PLAY_H [1280, 720] the window; PLAY_U [0] upscale (the
# frame is rendered at W / 2^U x H / 2^U samples, each shown as 2^U x 2^U pixels); PLAY_TIER [3]
# (0 flat, 1 textures, 2 + occlusion, 3 + shadows); PLAY_VD [48] view distance (blocks);
# PLAY_D [14] fork depth; PLAY_SEED [1]; PLAY_X, PLAY_Z [150, 100] the spawn column; PLAY_N
# [0: until quit] frames; PLAY_DEMO [0] (1: a scripted walk instead of the keyboard and mouse,
# one tick a frame: a reproducible run for the benchmark); PLAY_MODE [2, or 1 where Blit.ok is 0: off Linux, JS] (0: render straight
# into the window Image; 1: into a framebuffer, then convert it, in the same bang; 2: into a
# framebuffer only, shown by blit.c's Blit.frame, no Image at all);
# PLAY_PPM [none] the last frame's samples there (P6; modes 1 and 2: mode 0 keeps no framebuffer); PLAY_LOG [0] (1: one line a frame: sim, render (the one bang: the render
# and the Image conversion), show (Window.frame: the fill, the pace, the blit), in us).
#
# A frame: the window's events fold into the held input; the clock owes ticks at 60 a second
# (at most a quarter second's after a stall); the game steps that many ticks on the host (a
# pure step, never under a bang); the view renders in one bang (one GPU turn on the GPU lane,
# the last frame's image dropped inside it); Window.frame shows the image.
import Base
import ./world.bend as W
import ./render.bend as R
import ./game.bend as G
import ./input.bend as In
import ./loop.bend as Loop
import ./fx.bend as Fx

def Clock.us() -> IO(U32):
  import "./clock.c"
  import "./clock.js"

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

type Cfg is Data:
  Cfg{view: G.View, d: Nat, k: Nat, u: U32, demo: U32, log: U32}

# Everything a frame carries but the window and the image.
type St is Type:
  St{sim: Loop.Sim<G.Game>, fb: Array<U32>, clk: Loop.Clock, inp: In.Input, last: U32, f: U32}

# The scripted walk: forward, turning right a quarter of the time, a jump every 1.5 s.
def script(+f: U32) -> In.Input:
  +turn = Fx.sel((U32.mod(f, 240) < 60 : U32), G.Key.tr(), 0)
  +hop = Fx.sel((U32.mod(f, 90) < 8 : U32), G.Key.jump(), 0)
  In.Input{U32.or(U32.or(G.Key.fwd(), turn), hop), 0, 0, 0}

# The sim after this frame's ticks: n owed by the clock (demo: one tick of the scripted input).
def sim.of(+demo: U32, +n: U32, +f: U32, +inp: In.Input, sim: Loop.Sim<G.Game>) -> Loop.Sim<G.Game>:
  match demo:
    case 0:
      Loop.ticks(~G.Game, ~G.step, U32.to_nat(n), inp, sim)
    case _:
      Loop.tick(~G.Game, ~G.step, sim, script(f))

def tick.fin(+cfg: Cfg, +now: U32, +inp: In.Input, +f: U32, sim: Loop.Sim<G.Game>, fb: Array<U32>,
  r: U32 & Loop.Clock) -> St:
  Cfg{view, d, k, u, demo, log} = cfg
  (+n, clk) = r
  St{sim.of(demo, n, f, inp, sim), fb, clk, inp, now, f}

# The ticks owed since the last frame (now and last in us).
def tick(+cfg: Cfg, +now: U32, st: St) -> St:
  St{sim, fb, clk, +inp, +last, +f} = st
  tick.fin(cfg, now, inp, f, sim, fb, Loop.Clock.advance(60, U32.div((now - last : U32), 1000), clk))

# The frame: the game's view in one bang.
type Mid is Type:
  Mid{sim: Loop.Sim<G.Game>, fb: Array<U32>, img: Image, clk: Loop.Clock, inp: In.Input, last: U32,
    f: U32}

def draw.fin(+tick: U32, paused: Bool, +prev: U32, +seed: U32, clk: Loop.Clock, +inp: In.Input,
  +last: U32, +f: U32, s: G.Shown) -> Mid:
  G.Shown{g, fb, img} = s
  Mid{Loop.Sim{tick, paused, prev, seed, g}, fb, img, clk, inp, last, f}

def draw(+cfg: Cfg, st: St, old: Image) -> Mid:
  Cfg{view, d, k, u, demo, log} = cfg
  St{sim, fb, clk, +inp, +last, +f} = st
  Loop.Sim{+tick, paused, +prev, +seed, game} = sim
  draw.fin(tick, paused, prev, seed, clk, inp, last, f, G.view(view, d, k, game, fb, old))

def line(+f: U32, +t0: U32, +t1: U32, +t2: U32, +t3: U32) -> String:
  "frame " ++ U32.show(f) ++ " sim " ++ U32.show((t1 - t0 : U32)) ++ " render "
    ++ U32.show((t2 - t1 : U32)) ++ " show " ++ U32.show((t3 - t2 : U32)) ++ " us "
    ++ U32.show((t3 - t0 : U32))

def say(+on: U32, s: String) -> IO(Unit):
  match on:
    case 0:
      IO.pure(Unit, Unit{})
    case _:
      IO.print(s)

# The end: the last frame's samples to PLAY_PPM, if set.
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

def fin(+cfg: Cfg, window: Window, st: St) -> IO(Unit):
  Cfg{view, d, k, u, demo, log} = cfg
  G.View{ws, hs, tier, vd, sel, saz, mode} = view
  St{sim, fb, clk, inp, last, f} = st
  do IO<Unit>:
    Unit <- Window.close(window)
    p : Result<&1, &1, U32 & String, String> <- IO.get_env("PLAY_PPM")
    ppm(p, ws, hs, fb)

def quit(+inp: In.Input) -> Bool:
  In.Input.held(inp, In.Key.quit())

# The frame shown: the window, the framebuffer, the image, the events.
type Sh is Type:
  Sh{win: Window, fb: Array<U32>, img: Image, evs: List<Event>}

# 1 where Blit.frame shows frames (Linux, X11), else 0: the default mode is then 1 (Window.frame).
def Blit.ok() -> IO(U32):
  import "./blit_ok.c"
  import "./blit_ok.js"

def Blit.frame(window: Window, fb: Array<U32>, ws: U32, hs: U32, u: U32) ->
  IO(Window & Array<U32> & List<Event>):
  import "./blit.c"
  import "./blit.js"

def sh.blit(img: Image, r: Window & Array<U32> & List<Event>) -> IO(Sh):
  (win, fb, evs) = r
  IO.pure(Sh, Sh{win, fb, img, evs})

def sh.img(fb: Array<U32>, r: Window & Image & List<Event>) -> IO(Sh):
  (win, img, evs) = r
  IO.pure(Sh, Sh{win, fb, img, evs})

# Mode 2: the framebuffer straight into the window (Blit.frame); else the image (Window.frame).
def present(+mode: U32, +ws: U32, +hs: U32, +u: U32, window: Window, fb: Array<U32>, img: Image) ->
  IO(Sh):
  match mode:
    case 2:
      do IO<Sh>:
        r : Window & Array<U32> & List<Event> <- Blit.frame(window, fb, ws, hs, u)
        sh.blit(img, r)
    case _:
      do IO<Sh>:
        r : Window & Image & List<Event> <- Window.frame(window, img)
        sh.img(fb, r)

def shown(sim: Loop.Sim<G.Game>, clk: Loop.Clock, +inp: In.Input, +last: U32, +f: U32, s: Sh,
  rest: Window -> St -> Image -> IO(Unit)) -> IO(Unit):
  Sh{window, fb, img, events} = s
  rest(window, St{sim, fb, clk, In.Input.feed.with(~G.Key.map, events, inp), last, (f + 1 : U32)}, img)

def show(+cfg: Cfg, +t0: U32, +t1: U32, +t2: U32, window: Window, m: Mid,
  rest: Window -> St -> Image -> IO(Unit)) -> IO(Unit):
  Cfg{view, d, k, u, demo, log} = cfg
  G.View{ws, hs, tier, vd, sel, saz, mode} = view
  Mid{sim, fb, img, clk, +inp, +last, +f} = m
  do IO<Unit>:
    s : Sh <- present(mode, ws, hs, u, window, fb, img)
    +t3 : U32 <- Clock.us()
    Unit <- say(log, line(f, t0, t1, t2, t3))
    shown(sim, clk, inp, last, f, s, rest)

@unsafe
def run(+cfg: Cfg, n: Nat, stop: Bool, window: Window, st: St, old: Image) -> IO(Unit):
  match n stop:
    case 0n _:
      fin(cfg, window, st)
    case _ True{}:
      fin(cfg, window, st)
    case 1n+p False{}:
      do IO<Unit>:
        +t0 : U32 <- Clock.us()
        s2 : St <- IO.pure(St, tick(cfg, t0, st))
        +t1 : U32 <- Clock.us()
        m : Mid <- IO.pure(Mid, draw(cfg, s2, old))
        +t2 : U32 <- Clock.us()
        show(cfg, t0, t1, t2, window, m, w => s3 => i => run.next(cfg, p, w, s3, i))

@unsafe
def run.next(+cfg: Cfg, n: Nat, window: Window, st: St, old: Image) -> IO(Unit):
  St{sim, fb, clk, +inp, last, f} = st
  run(cfg, n, quit(inp), window, St{sim, fb, clk, inp, last, f}, old)

def start(+cfg: Cfg, +n: U32, +w: U32, +h: U32, g: G.Game) -> IO(Unit):
  do IO<Unit>:
    window : Window <- IO.try(Window, Window.open("bend-craft", w, h))
    +now : U32 <- Clock.us()
    run(cfg, U32.to_nat(n), False{}, window, St{Loop.Sim.new(G.Game, 1, g), Array.new(U32, 22n, 0),
      Loop.Clock.new(), In.Input.none(), now, 0}, Pix{0})

def main() -> IO(Unit):
  do IO<Unit>:
    +w : U32 <- num("PLAY_W", 1280)
    +h : U32 <- num("PLAY_H", 720)
    +u : U32 <- num("PLAY_U", 0)
    +tier : U32 <- num("PLAY_TIER", 3)
    +vd : U32 <- num("PLAY_VD", 48)
    +d : U32 <- num("PLAY_D", 14)
    +seed : U32 <- num("PLAY_SEED", 1)
    +x : U32 <- num("PLAY_X", 150)
    +z : U32 <- num("PLAY_Z", 100)
    +n : U32 <- num("PLAY_N", 0)
    +demo : U32 <- num("PLAY_DEMO", 0)
    +log : U32 <- num("PLAY_LOG", 0)
    +ok : U32 <- Blit.ok()
    +mode : U32 <- num("PLAY_MODE", Fx.sel((ok > 0 : U32), 2, 1))
    +ws : U32 = U32.shrn((w + U32.shln(1, U32.to_nat(u)) - 1 : U32), U32.to_nat(u))
    +hs : U32 = U32.shrn((h + U32.shln(1, U32.to_nat(u)) - 1 : U32), U32.to_nat(u))
    +k : Nat = Nat.sub(U32.log2((Fx.sel((w > h : U32), w, h) * 2 - 1 : U32)), Nat.add(U32.to_nat(u), 4n))
    Unit <- IO.print("play " ++ U32.show(w) ++ "x" ++ U32.show(h) ++ " samples " ++ U32.show(ws) ++ "x"
      ++ U32.show(hs) ++ " tier " ++ U32.show(tier) ++ " vd " ++ U32.show(vd) ++ " k " ++ Nat.show(k) ++ " mode " ++ U32.show(mode))
    start(Cfg{G.View{ws, hs, tier, vd, 7000, 34960, mode}, U32.to_nat(d), k, u, demo, log},
      Fx.sel(U32.is_eq(n, 0), 2147483647, n), w, h, G.new(4n, seed, x, z))
