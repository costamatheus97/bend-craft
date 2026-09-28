# loop.bend: the fixed-timestep game loop as pure functions.
#
#   import ./loop.bend as Loop
#   Loop.Sim{tick, paused, prev, seed, game}   # the loop's state around a game
#   Loop.Tick{n, seed, input, pressed}         # what a game's step sees
#   Loop.tick(~S, ~step, sim, input)           # one tick
#   Loop.run(~S, ~step, xs, sim)               # one tick per input of a log
#   Loop.view(~S, ~F, ~render, sim)            # (sim, frame): render borrows
#   Loop.Clock.advance(rate, dt_ms, clock)     # ticks owed after dt ms
#   Loop.Rec.* / Loop.Hist.*                   # recording and rollback
#
# A game is a state type S (a Type: it may hold arrays), a pure
# step: Tick -> S -> S and a pure render: S -> S & F. The loop owns the
# rest: the tick counter, the pause, the key edges and the random seed.
# Nothing here reads a clock or a device, so a log of inputs is the whole
# story of a run: LAWS.bend proves that replaying, resuming and rolling
# back give the same state, and that a pause freezes the game.
#
# Pause: the pad's pause bit (input.bend) going down flips the pause. A
# paused tick keeps the game, the tick counter and the seed; only prev
# (the last keys, for edges) moves, so a press during the pause is seen.
# The step runs on every unpaused tick, with the tick number, the seed of
# this tick, the held input and the keys pressed this tick.
import Base
import ./input.bend as In
import ./rng.bend as Rng

type Tick is Data:
  Tick{n: U32, seed: U32, input: In.Input, pressed: U32}

type Sim<-S: Type> is Type:
  Sim{tick: U32, paused: Bool, prev: U32, seed: U32, game: S}

# A running sim at tick 0 with nothing held.
def Sim.new(-S: Type, +seed: U32, game: S) -> Sim<S>:
  Sim{0, False{}, 0, seed, game}

# The tick
# --------

def go(
  ~S: Type, ~step: Tick -> S -> S, run: Bool, +tick: U32, +keys: U32, +prev: U32,
  +seed: U32, input: In.Input, game: S
) -> Sim<S>:
  match run:
    case True{}:
      Sim{(tick + 1 : U32), False{}, keys, Rng.next(seed),
        step(Tick{tick, seed, input, U32.and(keys, U32.not(prev))}, game)}
    case False{}:
      Sim{tick, True{}, keys, seed, game}

# held: the pause bit is down this tick. It flips the pause when it was up
# last tick (prev); the sim runs when it ends up unpaused.
def hold(
  ~S: Type, ~step: Tick -> S -> S, held: Bool, paused: Bool, +prev: U32, +tick: U32,
  +keys: U32, +seed: U32, input: In.Input, game: S
) -> Sim<S>:
  match held:
    case False{}:
      go(~S, ~step, Bool.not(paused), tick, keys, prev, seed, input, game)
    case True{}:
      go(~S, ~step, Bool.not(Bool.xor(paused, Bool.not(In.Key.has(prev, In.Key.pause())))),
        tick, keys, prev, seed, input, game)

def tick(~S: Type, ~step: Tick -> S -> S, sim: Sim<S>, +input: In.Input) -> Sim<S>:
  Sim{tick, paused, +prev, seed, game} = sim
  +keys = In.Input.keys(input)
  hold(~S, ~step, In.Key.has(keys, In.Key.pause()), paused, prev, tick, keys, seed,
    input, game)

# One tick per input, in order.
def run(~S: Type, ~step: Tick -> S -> S, xs: List<&2, In.Input>, sim: Sim<S>) -> Sim<S>:
  match xs:
    case Nil{}:
      sim
    case +x <> t:
      run(~S, ~step, t, tick(~S, ~step, sim, x))

# n ticks with the same input held (a frame that owes n ticks). Only the
# first can see a press: prev holds the keys after it.
def ticks(~S: Type, ~step: Tick -> S -> S, n: Nat, +input: In.Input, sim: Sim<S>) -> Sim<S>:
  match n:
    case 0n:
      sim
    case 1n+p:
      ticks(~S, ~step, p, input, tick(~S, ~step, sim, input))

# The frame of a sim: render borrows the game and hands it back.
def view.fin(-S: Type, -F: Type, +tick: U32, paused: Bool, +prev: U32, +seed: U32,
  r: S & F) -> Sim<S> & F:
  (game, frame) = r
  (Sim{tick, paused, prev, seed, game}, frame)

def view(~S: Type, ~F: Type, ~render: S -> S & F, sim: Sim<S>) -> Sim<S> & F:
  Sim{tick, paused, prev, seed, game} = sim
  view.fin(S, F, tick, paused, prev, seed, render(game))

def Sim.tick(-S: Type, sim: Sim<S>) -> Sim<S> & U32:
  Sim{+tick, paused, prev, seed, game} = sim
  (Sim{tick, paused, prev, seed, game}, tick)

# The fixed timestep
# ------------------
# A clock turns wall time into ticks at `rate` ticks per second with no
# drift: it carries the remainder, in units of 1/1000 tick, from frame to
# frame. A window loop reads IO.now, calls advance with the ms since the
# last frame, and runs ticks for the ticks it owes.

type Clock is Data:
  Clock{acc: U32}

def Clock.new() -> Clock:
  Clock{0}

# (ticks owed, the clock after): acc + dt * rate, split into whole ticks
# (per 1000) and the rest. dt is capped at 250 ms, so a stall (a
# breakpoint, a suspended laptop) owes at most a quarter second of ticks.
def Clock.advance(+rate: U32, dt: U32, c: Clock) -> U32 & Clock:
  Clock{acc} = c
  +t = (acc + U32.min(dt, 250) * rate : U32)
  (U32.div(t, 1000), Clock{U32.mod(t, 1000)})

# Recording
# ---------
# A recorder runs a sim and keeps its inputs, newest first. Replaying the
# log from the start the recorder began at gives the live state
# (LAWS: replay_recorded).

type Rec<-S: Type> is Type:
  Rec{log: List<&2, In.Input>, now: Sim<S>}

def Rec.new(-S: Type, sim: Sim<S>) -> Rec<S>:
  Rec{Nil{}, sim}

def Rec.push(~S: Type, ~step: Tick -> S -> S, rec: Rec<S>, +x: In.Input) -> Rec<S>:
  Rec{log, now} = rec
  Rec{x <> log, tick(~S, ~step, now, x)}

def Rec.feed(~S: Type, ~step: Tick -> S -> S, xs: List<&2, In.Input>, rec: Rec<S>) -> Rec<S>:
  match xs:
    case Nil{}:
      rec
    case +x <> t:
      Rec.feed(~S, ~step, t, Rec.push(~S, ~step, rec, x))

def Rec.now(-S: Type, rec: Rec<S>) -> Sim<S>:
  Rec{log, now} = rec
  now

# xs reversed onto acc.
def Log.rev(xs: List<&2, In.Input>, acc: List<&2, In.Input>) -> List<&2, In.Input>:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      Log.rev(t, x <> acc)

# The recorded log, oldest first (what run and In.Log.enc take).
def Rec.log(-S: Type, rec: Rec<S>) -> List<&2, In.Input>:
  Rec{log, now} = rec
  Log.rev(log, Nil{})

# Rollback
# --------
# A history is the sim now and, newest first, a snapshot of the sim before
# each tick with that tick's input. Rewinding k ticks restores the
# snapshot k ticks back and hands back the inputs it undid, oldest first;
# redoing them gives the history back (LAWS: rollback). A netcode client
# rewinds to the tick a late input lands on, fixes that input and redoes
# the rest. Snapshots copy the game with ~dup (the game's arrays are
# copied: World.dup in world.bend); Hist.trim bounds how many are kept.

type Snap<-S: Type> is Type:
  Snap{before: Sim<S>, input: In.Input}

type Hist<-S: Type> is Type:
  Hist{now: Sim<S>, past: List<Snap<S>>}

def Hist.new(-S: Type, sim: Sim<S>) -> Hist<S>:
  Hist{sim, Nil{}}

def Sim.dup.fin(-S: Type, +tick: U32, +paused: Bool, +prev: U32, +seed: U32, r: S & S) ->
  Sim<S> & Sim<S>:
  (a, b) = r
  (Sim{tick, paused, prev, seed, a}, Sim{tick, paused, prev, seed, b})

def Sim.dup(~S: Type, ~dup: S -> S & S, sim: Sim<S>) -> Sim<S> & Sim<S>:
  Sim{tick, paused, prev, seed, game} = sim
  Sim.dup.fin(S, tick, paused, prev, seed, dup(game))

def Hist.push.fin(
  ~S: Type, ~step: Tick -> S -> S, past: List<Snap<S>>, +x: In.Input, r: Sim<S> & Sim<S>
) -> Hist<S>:
  (a, b) = r
  Hist{tick(~S, ~step, a, x), Snap{b, x} <> past}

# One tick, keeping a snapshot of the sim before it.
def Hist.push(~S: Type, ~step: Tick -> S -> S, ~dup: S -> S & S, h: Hist<S>, +x: In.Input) ->
  Hist<S>:
  Hist{now, past} = h
  Hist.push.fin(~S, ~step, past, x, Sim.dup(~S, ~dup, now))

def Hist.feed(
  ~S: Type, ~step: Tick -> S -> S, ~dup: S -> S & S, xs: List<&2, In.Input>, h: Hist<S>
) -> Hist<S>:
  match xs:
    case Nil{}:
      h
    case +x <> t:
      Hist.feed(~S, ~step, ~dup, t, Hist.push(~S, ~step, ~dup, h, x))

# A history rewound, and the inputs undone (oldest first) before acc.
type Undo<-S: Type> is Type:
  Undo{hist: Hist<S>, redo: List<&2, In.Input>}

def Hist.rewind.go(-S: Type, k: Nat, now: Sim<S>, past: List<Snap<S>>, acc: List<&2, In.Input>) ->
  Undo<S>:
  match k past:
    case 0n _:
      Undo{Hist{now, past}, acc}
    case 1n+j Nil{}:
      Undo{Hist{now, Nil{}}, acc}
    case 1n+j Snap{before, x} <> rest:
      Hist.rewind.go(S, j, before, rest, x <> acc)

# Rewinds k ticks (fewer if the history is shorter): the sim goes back to
# its snapshot k ticks ago; the undone inputs come back, oldest first.
def Hist.rewind(-S: Type, k: Nat, h: Hist<S>) -> Undo<S>:
  Hist{now, past} = h
  Hist.rewind.go(S, k, now, past, Nil{})

# Redoes the undone inputs (or any others: a corrected log) from the
# rewound history.
def Hist.redo(~S: Type, ~step: Tick -> S -> S, ~dup: S -> S & S, u: Undo<S>) -> Hist<S>:
  Undo{h, xs} = u
  Hist.feed(~S, ~step, ~dup, xs, h)

def Hist.now(-S: Type, h: Hist<S>) -> Sim<S>:
  Hist{now, past} = h
  now

# Keeps the newest n snapshots (a rewind reaches n ticks back at most).
def Hist.keep(-S: Type, n: Nat, past: List<Snap<S>>) -> List<Snap<S>>:
  match n past:
    case 0n _:
      Nil{}
    case 1n+p Nil{}:
      Nil{}
    case 1n+p s <> rest:
      s <> Hist.keep(S, p, rest)

def Hist.trim(-S: Type, n: Nat, h: Hist<S>) -> Hist<S>:
  Hist{now, past} = h
  Hist{now, Hist.keep(S, n, past)}

# Loading a save
# --------------

# A save is the words of an input log (In.Log.enc) and the sim it starts
# from (in practice Sim.new of the seed). Loading it replays the log from
# that sim; None when the words are not a log. LAWS.bend save_load: a
# saved log loads back as the state its run reached.
def load.got(~S: Type, ~step: Tick -> S -> S, r: Maybe<&2, In.Log.Got>, sim: Sim<S>) -> Maybe<Sim<S>>:
  match r:
    case None{}:
      None{}
    case Some{In.Got{xs, rest}}:
      Some{run(~S, ~step, xs, sim)}

def load(~S: Type, ~step: Tick -> S -> S, ws: List<&2, U32>, sim: Sim<S>) -> Maybe<Sim<S>>:
  load.got(~S, ~step, In.Log.dec(ws), sim)
