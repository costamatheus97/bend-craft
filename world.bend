# world.bend: the voxel world in one flat Array<U32>, and its terrain.
#
#   import ./world.bend as W
#   W.new(lc)                      # an empty world of 16 << lc by 64 by 16 << lc blocks
#   W.hm.new(lc)                   # its height map (one word per column)
#   W.gen(~put, d, lc, seed, hm, w)   # terrain, 2^d leaves per pass (call it with !)
#   W.word(lc, x, y, z)            # the word of block (x, y, z); W.get / W.set a block
#   W.hash(w)                      # (w, an order-sensitive hash of every word)
#   W.occ.build(lc, w)             # the empty-space table (after gen; set keeps it)
#
# Layout. The world is 16 << lc blocks along x and z and 64 high. A block
# id is one byte, four per U32, packed along y: word (col << 4) | (y >> 2),
# byte y & 3. A column's 64 blocks are 16 consecutive words (64 B, one
# cache line), so a column is owned by one lane: terrain writes whole
# words, never a byte of a word another lane writes. Columns are grouped
# in chunks of 16 x 16 (col = (chunk << 8) | (z & 15) << 4 | (x & 15),
# chunk = (z >> 4) << lc | (x >> 4)), so a chunk is 4096 consecutive words
# (16 KiB) and a ray crossing nearby columns stays in one chunk. The
# array is exactly 2^(2 lc + 12) words: every in-range (x, y, z) has its
# own word, and nothing else does. An index past the end would wrap
# silently (Bend masks it), so every reader checks x, y, z first.
#
# Terrain is two passes, each a fork over columns in index order:
#   1. per column, its height (fixed-point value noise, four octaves) and
#      its tree (a trunk height, or 0), into the height map;
#   2. per column, its 16 words: bedrock, stone, dirt or sand, the top
#      (grass, sand or snow), water up to the sea, its own trunk, and the
#      leaves of every tree within 2 columns (a gather over 25 height-map
#      words, so no lane writes another lane's column).
# Everything is U32 arithmetic, so a world is a function of (lc, seed):
# the same on every lane and every fork depth.
import Base
import ./rng.bend as Rng

# Block ids
# ---------

def Blk.air() -> U32:
  0

def Blk.stone() -> U32:
  1

def Blk.dirt() -> U32:
  2

def Blk.grass() -> U32:
  3

def Blk.sand() -> U32:
  4

def Blk.water() -> U32:
  5

def Blk.log() -> U32:
  6

def Blk.leaves() -> U32:
  7

def Blk.planks() -> U32:
  8

def Blk.bedrock() -> U32:
  9

def Blk.snow() -> U32:
  10

def Blk.brick() -> U32:
  11

def Blk.cobble() -> U32:
  12

def Blk.glass() -> U32:
  13

def sel(c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

# Layout
# ------

def high() -> U32:
  64

def sea() -> U32:
  30

def side(+lc: Nat) -> U32:
  U32.shln(16, lc)

# log2 of the number of words and of columns.
def lw(+lc: Nat) -> Nat:
  Nat.add(Nat.add(lc, lc), 12n)

def lcols(+lc: Nat) -> Nat:
  Nat.add(Nat.add(lc, lc), 8n)

def col(+lc: Nat, +x: U32, +z: U32) -> U32:
  U32.or(U32.shln(U32.or(U32.shln(U32.shrn(z, 4n), lc), U32.shrn(x, 4n)), 8n),
    U32.or(U32.shln(U32.and(z, 15), 4n), U32.and(x, 15)))

def word(+lc: Nat, +x: U32, +y: U32, +z: U32) -> U32:
  U32.or(U32.shln(col(lc, x, z), 4n), U32.shrn(y, 2n))

# A column index back to x and z.
def cx(+lc: Nat, +c: U32) -> U32:
  U32.or(U32.shln(U32.and(U32.shrn(c, 8n), (U32.shln(1, lc) - 1 : U32)), 4n), U32.and(c, 15))

def cz(+lc: Nat, +c: U32) -> U32:
  U32.or(U32.shln(U32.shrn(c, Nat.add(8n, lc)), 4n), U32.and(U32.shrn(c, 4n), 15))

# Whether (x, y, z) is inside (x, z < side, y < 64; U32, so no negatives).
def inside(+lc: Nat, +x: U32, +y: U32, +z: U32) -> Bool:
  +s = side(lc)
  ((x < s) && (z < s) && (y < 64) : U32)

# The byte of block y in its word.
def byte(+wd: U32, +y: U32) -> U32:
  U32.and(U32.shrn(wd, U32.to_nat(U32.shln(U32.and(y, 3), 3n))), 255)

def get.at(+y: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (w, +wd) = r
  (w, byte(wd, y))

# The block at (x, y, z); air outside the world (no read).
def get.if(on: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  match on:
    case True{}:
      get.at(y, w[word(lc, x, y, z)])
    case False{}:
      (w, Blk.air())

def get(+lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32> & U32:
  get.if(inside(lc, x, y, z), lc, x, y, z, w)

# Occupancy
# ---------
# One word per 4 x 4 group of columns: bit j set when the 4 x 4 x 4 cells
# at y 4j .. 4j + 3 hold anything but air (water counts). The four blocks
# of a column at y 4j .. 4j + 3 are one word, so a group's cells at slab j
# are 16 words. It lives in the upper half at 3/2 of aux (after the
# atlas's room); set keeps it exact; occ.build makes it from the voxels
# (after gen, or after any write that skips set). A ray skips a group
# whose bit is clear (render.bend).

def occ.base(+lc: Nat) -> U32:
  +a = U32.shln(1, lw(lc))
  (a + U32.shrn(a, 1n) : U32)

# The occupancy word of the group of column (x, z).
def occ.at(+lc: Nat, +x: U32, +z: U32) -> U32:
  (occ.base(lc) + U32.or(U32.shln(U32.shrn(z, 2n), Nat.add(lc, 2n)), U32.shrn(x, 2n)) : U32)

# The word of slab s of column i (0 .. 15, x fastest) of the group at (x0, z0).
def occ.w(+lc: Nat, +x0: U32, +z0: U32, +s: U32, +i: U32) -> U32:
  U32.or(U32.shln(col(lc, (x0 + U32.and(i, 3) : U32), (z0 + U32.shrn(i, 2n) : U32)), 4n), s)

# The OR of a slab's 16 words (r: word n's read).
def occ.or(n: Nat, +lc: Nat, +x0: U32, +z0: U32, +s: U32, +m: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  match n:
    case 0n:
      (w, +v) = r
      (w, U32.or(m, v))
    case 1n++p:
      (w, +v) = r
      occ.or(p, lc, x0, z0, s, U32.or(m, v), w[occ.w(lc, x0, z0, s, U32.from_nat(p))])

def occ.slab(+lc: Nat, +x0: U32, +z0: U32, +s: U32, w: Array<U32>) -> Array<U32> & U32:
  occ.or(15n, lc, x0, z0, s, 0, w[occ.w(lc, x0, z0, s, 15)])

def occ.put(+i: U32, +j: U32, +on: U32, r: Array<U32> & U32) -> Array<U32>:
  (w, +o) = r
  w[i] <- U32.or(U32.and(o, U32.not(U32.shln(1, U32.to_nat(j)))), U32.shln(on, U32.to_nat(j)))

def occ.fix.at(+lc: Nat, +x: U32, +z: U32, +j: U32, r: Array<U32> & U32) -> Array<U32>:
  (w, +m) = r
  +i = occ.at(lc, x, z)
  occ.put(i, j, sel(U32.is_ne(m, 0), 1, 0), w[i])

# The bit of (x, y, z)'s group and slab, from the voxels.
def occ.fix(+lc: Nat, +x: U32, +y: U32, +z: U32, w: Array<U32>) -> Array<U32>:
  +j = U32.shrn(y, 2n)
  occ.fix.at(lc, x, z, j, occ.slab(lc, U32.and(x, 4294967292), U32.and(z, 4294967292), j, w))

# A group's mask (r: the OR of slab n).
def occ.mask(n: Nat, +lc: Nat, +x0: U32, +z0: U32, +m: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  match n:
    case 0n:
      (w, +v) = r
      (w, U32.or(m, sel(U32.is_ne(v, 0), 1, 0)))
    case 1n++p:
      (w, +v) = r
      +s = U32.from_nat(p)
      occ.mask(p, lc, x0, z0, U32.or(m, U32.shln(sel(U32.is_ne(v, 0), 1, 0), U32.to_nat((s + 1 : U32)))),
        occ.slab(lc, x0, z0, s, w))

def occ.store(+i: U32, r: Array<U32> & U32) -> Array<U32>:
  (w, +m) = r
  w[i] <- m

def occ.go(n: Nat, +lc: Nat, w: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      w
    case 1n++p:
      +g = U32.from_nat(p)
      +x0 = U32.shln(U32.and(g, (U32.shln(1, Nat.add(lc, 2n)) - 1 : U32)), 2n)
      +z0 = U32.shln(U32.shrn(g, Nat.add(lc, 2n)), 2n)
      occ.go(p, lc, occ.store((occ.base(lc) + g : U32), occ.mask(15n, lc, x0, z0, 0,
        occ.slab(lc, x0, z0, 15, w))))

# Every group's word from the voxels (host, once after gen).
def occ.build(+lc: Nat, w: Array<U32>) -> Array<U32>:
  occ.go(U32.to_nat(U32.shln(1, Nat.add(Nat.add(lc, lc), 4n))), lc, w)

def set.at(+i: U32, +y: U32, +b: U32, r: Array<U32> & U32) -> Array<U32>:
  (w, +wd) = r
  +sh = U32.to_nat(U32.shln(U32.and(y, 3), 3n))
  w[i] <- U32.or(U32.and(wd, U32.not(U32.shln(255, sh))), U32.shln(U32.and(b, 255), sh))

def set.if(on: Bool, +lc: Nat, +x: U32, +y: U32, +z: U32, +b: U32, w: Array<U32>) ->
  Array<U32>:
  match on:
    case True{}:
      +i = word(lc, x, y, z)
      occ.fix(lc, x, y, z, set.at(i, y, b, w[i]))
    case False{}:
      w

# Sets block (x, y, z) to b (and its group's occupancy bit); nothing outside the world.
def set(+lc: Nat, +x: U32, +y: U32, +z: U32, +b: U32, w: Array<U32>) -> Array<U32>:
  set.if(inside(lc, x, y, z), lc, x, y, z, b, w)

# The scene array: the voxels in the lower half, tables in the upper half
# (from aux(lc): the texture atlas, and room for more), so one handle
# carries everything a ray reads.
def new(+lc: Nat) -> Array<U32>:
  Array.new(U32, Nat.add(lw(lc), 1n), 0)

def aux(+lc: Nat) -> U32:
  U32.shln(1, lw(lc))

def hm.new(+lc: Nat) -> Array<U32>:
  Array.new(U32, lcols(lc), 0)

# Noise
# -----
# Value noise: a hashed 16-bit value per lattice point, smoothstep
# weights in 12-bit fixed point.

def N.lat(+seed: U32, +ix: U32, +iz: U32) -> U32:
  U32.and(Rng.at(seed, U32.xor((ix * 73856093 : U32), (iz * 19349663 : U32))), 65535)

# smoothstep, t in [0, 4096] to [0, 4096]
def N.sm(+t: U32) -> U32:
  +t2 = U32.shrn((t * t : U32), 12n)
  U32.shrn((t2 * (12288 - t * 2) : U32), 12n)

# a + (b - a) s for a, b < 65536 and s in [0, 4096]
def N.mix(+a: U32, +b: U32, +s: U32) -> U32:
  U32.shrn((a * (4096 - s) + b * s : U32), 12n)

# The noise at (x, z) blocks with lattice spacing 2^ls: 0 .. 65535.
def N.at(+seed: U32, +ls: Nat, +x: U32, +z: U32) -> U32:
  +ix = U32.shrn(x, ls)
  +iz = U32.shrn(z, ls)
  +m = (U32.shln(1, ls) - 1 : U32)
  +fx = N.sm(U32.shrn(U32.shln(U32.and(x, m), 12n), ls))
  +fz = N.sm(U32.shrn(U32.shln(U32.and(z, m), 12n), ls))
  +a = N.mix(N.lat(seed, ix, iz), N.lat(seed, (ix + 1 : U32), iz), fx)
  +b = N.mix(N.lat(seed, ix, (iz + 1 : U32)), N.lat(seed, (ix + 1 : U32), (iz + 1 : U32)), fx)
  N.mix(a, b, fz)

# Terrain
# -------

# The surface height of column (x, z): 17 .. 60. The widest octave is
# squared, so the land is mostly low with sharper peaks.
def T.height(+seed: U32, +x: U32, +z: U32) -> U32:
  +n1 = U32.shrn(N.at(Rng.mix(U32.xor(seed, 1)), 6n, x, z), 8n)
  +n2 = N.at(Rng.mix(U32.xor(seed, 2)), 5n, x, z)
  +n3 = N.at(Rng.mix(U32.xor(seed, 3)), 4n, x, z)
  +n4 = N.at(Rng.mix(U32.xor(seed, 4)), 3n, x, z)
  +m = U32.shrn((n1 * n1 : U32), 8n)
  (17 + U32.shrn((m * 30 : U32), 8n) + U32.shrn((n2 * 12 : U32), 16n)
    + U32.shrn((n3 * 6 : U32), 16n) + U32.shrn((n4 * 3 : U32), 16n) : U32)

# A tree's trunk height (4 .. 6) at column (x, z) of height h, or 0: on
# grass (above the beach, below the snow), two columns from the edge.
def T.trunk(+seed: U32, +lc: Nat, +x: U32, +z: U32, +h: U32) -> U32:
  +r = Rng.at(U32.xor(seed, 1953719668), U32.xor((x * 2654435761 : U32), (z * 40503 : U32)))
  +s = (side(lc) - 2 : U32)
  sel(((U32.and(r, 127) < 2) && (h > sea() + 1) && (h < 46) && (x >= 2) && (z >= 2)
    && (x < s) && (z < s) : U32), (4 + U32.mod(U32.shrn(r, 8n), 3) : U32), 0)

# The height-map word of a column: height | trunk << 8.
def T.info(+seed: U32, +lc: Nat, +x: U32, +z: U32) -> U32:
  +h = T.height(seed, x, z)
  U32.or(h, U32.shln(T.trunk(seed, lc, x, z, h), 8n))

# Leaves: a 64-bit mask over y as two words (lo: y < 32, hi: y >= 32).
type Msk is Data:
  Msk{lo: U32, hi: U32}

# The bits [a, b] of the word covering [base, base + 32).
def M.part(+a: U32, +b: U32, +base: U32) -> U32:
  +a1 = U32.max(a, base)
  +b1 = U32.min(b, (base + 31 : U32))
  sel((a1 > b1 : U32), 0,
    U32.shln(U32.shrn(4294967295, U32.to_nat((31 - (b1 - a1) : U32))), U32.to_nat((a1 - base : U32))))

def M.add(+a: U32, +b: U32, +m: Msk) -> Msk:
  Msk{lo, hi} = m
  Msk{U32.or(lo, M.part(a, b, 0)), U32.or(hi, M.part(a, b, 32))}

# The leaves a tree (info) at offset (ax, az) = |dx|, |dz| lays in this
# column: y from top - 2 up, top = h + trunk.
def M.tree.r(+r: U32, +corner: Bool, +top: U32, +m: Msk) -> Msk:
  match corner:
    case True{}:
      M.add(sel(U32.is_eq(r, 1), (top - 2 : U32), 1), sel(U32.is_eq(r, 1), top, 0), m)
    case False{}:
      M.add(sel(U32.is_eq(r, 0), (top + 1 : U32), (top - 2 : U32)),
        sel(U32.is_eq(r, 2), (top - 1 : U32), (top + 1 : U32)), m)

def M.tree.if(none: Bool, +top: U32, +ax: U32, +az: U32, +m: Msk) -> Msk:
  match none:
    case True{}:
      m
    case False{}:
      M.tree.r(U32.max(ax, az), U32.is_eq(ax, az) && (ax > 0 : U32), top, m)

def M.tree(+info: U32, +ax: U32, +az: U32, +m: Msk) -> Msk:
  +t = U32.and(U32.shrn(info, 8n), 255)
  M.tree.if(U32.is_eq(t, 0), (U32.and(info, 255) + t : U32), ax, az, m)

# |v - 2| for v in 0 .. 4.
def M.off(+v: U32) -> U32:
  sel((v < 2 : U32), (2 - v : U32), (v - 2 : U32))

# The height-map word of column (x, z) (0 outside the world: no tree).
def G.rd.if(on: Bool, +lc: Nat, +x: U32, +z: U32, hm: Array<U32>) -> Array<U32> & U32:
  match on:
    case True{}:
      hm[col(lc, x, z)]
    case False{}:
      (hm, 0)

def G.rd(+lc: Nat, +x: U32, +z: U32, hm: Array<U32>) -> Array<U32> & U32:
  G.rd.if(((x < side(lc)) && (z < side(lc)) : U32), lc, x, z, hm)

# Neighbour j of (x, z), j = 5 dz' + dx' for dx', dz' in 0 .. 4 (offset 2).
def G.nx(+x: U32, +j: U32) -> U32:
  (x + U32.mod(j, 5) - 2 : U32)

def G.nz(+z: U32, +j: U32) -> U32:
  (z + U32.div(j, 5) - 2 : U32)

type Gat is Type:
  Gat{hm: Array<U32>, m: Msk}

# The leaves of the 25 columns around (x, z): neighbour n, its word in r.
def G.leaves(n: Nat, +lc: Nat, +x: U32, +z: U32, +m: Msk, r: Array<U32> & U32) -> Gat:
  match n:
    case 0n:
      (hm, +info) = r
      Gat{hm, M.tree(info, 2, 2, m)}
    case 1n++p:
      (hm, +info) = r
      +k = U32.from_nat(p)
      +j = (k + 1 : U32)
      G.leaves(p, lc, x, z, M.tree(info, M.off(U32.mod(j, 5)), M.off(U32.div(j, 5)), m),
        G.rd(lc, G.nx(x, k), G.nz(z, k), hm))

# The block at height y of a column (height h, trunk t, leaf bit l).
def G.b4(+y: U32, +h: U32, +t: U32, l: Bool) -> U32:
  match l:
    case True{}:
      Blk.leaves()
    case False{}:
      sel((y <= sea() : U32), Blk.water(), Blk.air())

def G.b3(c: Bool, +y: U32, +h: U32, +t: U32, l: Bool) -> U32:
  match c:
    case True{}:
      Blk.log()
    case False{}:
      G.b4(y, h, t, l)

def G.top(+h: U32) -> U32:
  sel((h <= sea() + 1 : U32), Blk.sand(), sel((h >= 48 : U32), Blk.snow(), Blk.grass()))

def G.b2b(top: Bool, +y: U32, +h: U32, +t: U32, l: Bool) -> U32:
  match top:
    case True{}:
      G.top(h)
    case False{}:
      G.b3((y <= h + t : U32), y, h, t, l)

def G.b2(under: Bool, +y: U32, +h: U32, +t: U32, l: Bool) -> U32:
  match under:
    case True{}:
      sel((y + 3 < h : U32), Blk.stone(), sel((h <= sea() + 1 : U32), Blk.sand(), Blk.dirt()))
    case False{}:
      G.b2b(U32.is_eq(y, h), y, h, t, l)

def G.blk(bed: Bool, +y: U32, +h: U32, +t: U32, l: Bool) -> U32:
  match bed:
    case True{}:
      Blk.bedrock()
    case False{}:
      G.b2((y < h : U32), y, h, t, l)

def G.leaf(+y: U32, +m: Msk) -> Bool:
  Msk{lo, hi} = m
  U32.is_ne(U32.and(U32.shrn(sel((y < 32 : U32), lo, hi), U32.to_nat(U32.and(y, 31))), 1), 0)

def G.id(+y: U32, +h: U32, +t: U32, +m: Msk) -> U32:
  G.blk(U32.is_eq(y, 0), y, h, t, G.leaf(y, m))

# The word of blocks y .. y + 3.
def G.pack(+y: U32, +h: U32, +t: U32, +m: Msk) -> U32:
  U32.or(U32.or(G.id(y, h, t, m), U32.shln(G.id((y + 1 : U32), h, t, m), 8n)),
    U32.or(U32.shln(G.id((y + 2 : U32), h, t, m), 16n), U32.shln(G.id((y + 3 : U32), h, t, m), 24n)))

# The column's words k = n .. 0 (y = 4k), written through put.
def G.words(
  ~put: Array<U32> -> U32 -> U32 -> Array<U32>, n: Nat, +base: U32, +h: U32, +t: U32, +m: Msk,
  w: Array<U32>
) -> Array<U32>:
  match n:
    case 0n:
      put(w, base, G.pack(0, h, t, m))
    case 1n++p:
      +k = (U32.from_nat(p) + 1 : U32)
      G.words(~put, p, base, h, t, m, put(w, (base + k : U32), G.pack(U32.shln(k, 2n), h, t, m)))

type P2 is Type:
  P2{a: Array<U32>, b: Array<U32>}

def G.col.fin(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +c: U32, +own: U32, w: Array<U32>,
  g: Gat) -> P2:
  Gat{hm, m} = g
  P2{hm, G.words(~put, 15n, U32.shln(c, 4n), U32.and(own, 255), U32.and(U32.shrn(own, 8n), 255),
    m, w)}

def G.col.own(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +lc: Nat, +c: U32, +x: U32, +z: U32,
  w: Array<U32>, r: Array<U32> & U32) -> P2:
  (hm, +own) = r
  G.col.fin(~put, c, own, w, G.leaves(24n, lc, x, z, Msk{0, 0}, G.rd(lc, G.nx(x, 24), G.nz(z, 24), hm)))

# Column c: its own word, the leaves around it, its 16 words.
def G.col(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +lc: Nat, +c: U32, hm: Array<U32>,
  w: Array<U32>) -> P2:
  G.col.own(~put, lc, c, cx(lc, c), cz(lc, c), w, hm[c])

def G.cols(~put: Array<U32> -> U32 -> U32 -> Array<U32>, n: Nat, +lc: Nat, +c: U32, p: P2) -> P2:
  match n:
    case 0n:
      P2{hm, w} = p
      G.col(~put, lc, c, hm, w)
    case 1n+q:
      P2{hm, w} = p
      G.cols(~put, q, lc, (c + 1 : U32), G.col(~put, lc, c, hm, w))

# Pass 1 over columns [c, c1): the height map.
def H.cols(n: Nat, +seed: U32, +lc: Nat, +c: U32, hm: Array<U32>) -> Array<U32>:
  match n:
    case 0n:
      hm[c] <- T.info(seed, lc, cx(lc, c), cz(lc, c))
    case 1n+q:
      H.cols(q, seed, lc, (c + 1 : U32), hm[c] <- T.info(seed, lc, cx(lc, c), cz(lc, c)))

def H.leaf.if(e: Bool, +seed: U32, +lc: Nat, +c: U32, +c1: U32, hm: Array<U32>) -> Array<U32>:
  match e:
    case True{}:
      hm
    case False{}:
      H.cols(U32.to_nat((c1 - c - 1 : U32)), seed, lc, c, hm)

@unsafe
def H.node(+d: Nat, +seed: U32, +lc: Nat, +c: U32, +c1: U32, +hm: Array<U32>) -> Array<U32>:
  match d:
    case 0n:
      H.leaf.if((c >= c1 : U32), seed, lc, c, c1, hm)
    case 1n+e:
      +m = U32.shrn((c + c1 : U32), 1n)
      a b = H.node(e, seed, lc, c, m, hm) H.node(e, seed, lc, m, c1, hm)
      Array.join(U32, a, b)

def G.leaf.if(~put: Array<U32> -> U32 -> U32 -> Array<U32>, e: Bool, +lc: Nat, +c: U32, +c1: U32,
  hm: Array<U32>, w: Array<U32>) -> P2:
  match e:
    case True{}:
      P2{hm, w}
    case False{}:
      G.cols(~put, U32.to_nat((c1 - c - 1 : U32)), lc, c, P2{hm, w})

@unsafe
def P2.join(l: P2, r: P2) -> P2:
  P2{la, lb} = l
  P2{ra, rb} = r
  P2{Array.join(U32, la, ra), Array.join(U32, lb, rb)}

@unsafe
def G.node(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +d: Nat, +lc: Nat, +c: U32, +c1: U32,
  +hm: Array<U32>, +w: Array<U32>) -> P2:
  match d:
    case 0n:
      G.leaf.if(~put, (c >= c1 : U32), lc, c, c1, hm, w)
    case 1n+e:
      +m = U32.shrn((c + c1 : U32), 1n)
      a b = G.node(~put, e, lc, c, m, hm, w) G.node(~put, e, lc, m, c1, hm, w)
      P2.join(a, b)

def G.pass2(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +d: Nat, +lc: Nat, w: Array<U32>,
  hm: Array<U32>) -> P2:
  G.node(~put, d, lc, 0, U32.shln(1, lcols(lc)), hm, w)

# The terrain of (lc, seed) into w, with hm as scratch: 2^d leaves per pass
# (d <= 2 lc + 8). One call: under ! it is one GPU turn.
def gen(~put: Array<U32> -> U32 -> U32 -> Array<U32>, +d: Nat, +lc: Nat, +seed: U32,
  hm: Array<U32>, w: Array<U32>) -> P2:
  G.pass2(~put, d, lc, w, H.node(d, seed, lc, 0, U32.shln(1, lcols(lc)), hm))

# The writers: a plain write, and the bounds pass's count of writes per word.
def Put.set(a: Array<U32>, i: U32, v: U32) -> Array<U32>:
  Array.set(U32, a, i, v)

def Put.inc(+i: U32, r: Array<U32> & U32) -> Array<U32>:
  (a, +c) = r
  a[i] <- (c + 1 : U32)

def Put.count(a: Array<U32>, i0: U32, v: U32) -> Array<U32>:
  +i = i0
  Put.inc(i, a[i])

# Hashing and checks
# ------------------

def hash.go(n: Nat, +i: U32, +h: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (a, +v) = r
      (a, (h + Rng.mix(U32.xor((i * 2654435769 : U32), v)) : U32))
    case 1n+p:
      (a, +v) = r
      +i2 = (i + 1 : U32)
      hash.go(p, i2, (h + Rng.mix(U32.xor((i * 2654435769 : U32), v)) : U32), a[i2])

def hash.at(r: Array<U32> & U32) -> Array<U32> & U32:
  (a, +n) = r
  hash.go(U32.to_nat((n - 1 : U32)), 0, 0, a[0])

# (a, the sum over words i < n of mix(i * 2654435769 ^ a[i])).
def hash.n(+n: U32, a: Array<U32>) -> Array<U32> & U32:
  hash.go(U32.to_nat((n - 1 : U32)), 0, 0, a[0])

# (a, the hash of every word).
def hash(a: Array<U32>) -> Array<U32> & U32:
  hash.at(Array.size(U32, a))

# (w, the hash of the voxels: the lower half).
def vhash(+lc: Nat, w: Array<U32>) -> Array<U32> & U32:
  hash.n(aux(lc), w)

# (a, the number of words not equal to v).
def ne.go(n: Nat, +i: U32, +v: U32, +k: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (a, +x) = r
      (a, sel(U32.is_eq(x, v), k, (k + 1 : U32)))
    case 1n+p:
      (a, +x) = r
      +i2 = (i + 1 : U32)
      ne.go(p, i2, v, sel(U32.is_eq(x, v), k, (k + 1 : U32)), a[i2])

def ne.at(+v: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (a, +n) = r
  ne.go(U32.to_nat((n - 1 : U32)), 0, v, 0, a[0])

def ne(+v: U32, a: Array<U32>) -> Array<U32> & U32:
  ne.at(v, Array.size(U32, a))

# (a, the number of words i < n not equal to v).
def ne.n(+n: U32, +v: U32, a: Array<U32>) -> Array<U32> & U32:
  ne.go(U32.to_nat((n - 1 : U32)), 0, v, 0, a[0])

# The number of columns c whose (x, z) do not map back to c, or leave the world.
def roundtrip(n: Nat, +lc: Nat, +c: U32, +bad: U32) -> U32:
  match n:
    case 0n:
      bad
    case 1n+p:
      +x = cx(lc, c)
      +z = cz(lc, c)
      +ok = U32.is_eq(col(lc, x, z), c) && ((x < side(lc)) && (z < side(lc)) : U32)
      roundtrip(p, lc, (c + 1 : U32), sel(ok, bad, (bad + 1 : U32)))

# A histogram of the block ids 0 .. 15 over the world: counts[id].
def hist.word(+wd: U32, cs: Array<U32>) -> Array<U32>:
  Put.count(Put.count(Put.count(Put.count(cs, U32.and(wd, 15), 0), U32.and(U32.shrn(wd, 8n), 15), 0),
    U32.and(U32.shrn(wd, 16n), 15), 0), U32.and(U32.shrn(wd, 24n), 15), 0)

type Hist is Type:
  Hist{w: Array<U32>, cs: Array<U32>}

def hist.go(n: Nat, +i: U32, cs: Array<U32>, r: Array<U32> & U32) -> Hist:
  match n:
    case 0n:
      (w, +wd) = r
      Hist{w, hist.word(wd, cs)}
    case 1n+p:
      (w, +wd) = r
      +i2 = (i + 1 : U32)
      hist.go(p, i2, hist.word(wd, cs), w[i2])

# The histogram of the voxels.
def hist(+lc: Nat, w: Array<U32>) -> Hist:
  hist.go(U32.to_nat((aux(lc) - 1 : U32)), 0, Array.new(U32, 4n, 0), w[0])
