# Optimizations

Every attempt at making a frame faster, kept or not. Each entry names the bottleneck it went for,
the gain expected before measuring, the gain measured, and the verdict. Frames must stay identical
(every change below passed tests/*.bend on check, c16 and the render hashes; the kept ones on every
lane before their commit).

How things are measured, unless an entry says otherwise:

- **GPU render.** `bench/render.bend` on the L0 profiling build (`bench/sweep.sh BIN gpu`), 720p,
  tier 3, vd 48, the play camera (x 150, z 100, pitch 0, sun 7000 / 34960), turning 1092 a frame,
  61 frames, the first 5 dropped. Reported: frame median / p95 over the rest, and gprof L0's GPU
  `wait`. Variants run interleaved, 5 rounds or more; the verdict uses the median over rounds of
  each round's median.
- **CPU render.** The same bench on a plain CPU build: c1 at 320x180 (20 frames), c16 at 720p (16
  frames), interleaved.
- **Paced window.** `bench/abp.sh` (play.bend, the scripted walk, 900 frames, the real WSLg window,
  paced at 60 Hz, hw harness): `busy_ms` (the frame's work, everything but the pace's sleep) and
  `present_ms` (the interval between two presents).
- Machine noise is large: the same GPU binary gives medians from 8.4 to 11.3 ms at 720p across
  rounds, and the first run after a pause is often the fastest. Nothing below is called a gain
  unless it holds round by round.

## Before the ladder (M2-M4)

| # | Idea | Bottleneck | Expected | Measured | Verdict |
|-|-|-|-|-|-|
| 1 | Render straight into the window Image (`R.direct`: the fork tree is the quadtree, no framebuffer, no conversion pass) | the conversion pass (1.3-3 ms at 720p) | -2 ms at 720p | 21.7 vs 11.0 ms at 720p, 72 vs 16 at 1080p (GPU); tiles of 4x4 samples are leaf tasks, far more tasks and allocations | rejected, kept as `PLAY_MODE=0` (tested picture-identical) |
| 2 | Conversion tiles of 4 / 8 / 16 samples (`BR_TL`) | conversion | ±1 ms | tl2 8.67 / 10.34, tl4 9.63 / 9.76, no conversion 8.02 / 8.50: inside the noise | no change (16) |
| 3 | Skip reads above y 40 | voxel reads | 5-10% | 5-10%, inside the noise | rejected |
| 4 | Fork depth d 12..17 (GPU) | lane fill | - | d 12 worse (11.1), d 14-17 equal (8.9-10.2) | d 14 |
| 5 | View distance 48 vs 64 | ray length | - | -10% at 720p, -15% at 1080p | vd 48 is the default tier |

## GPU ladder, rung 720p paced (busy p95 17.1 ms at the start)

Profile at the start (paced, real window, 900 frames): sim 0.27, render 10.2 (GPU wait 8.1, up 0.75,
down 0.77), show 6.2 of which the fill 2.1 and the rest the pace's sleep and XPutImage; busy med
14.1 / p95 16.8-17.0; present p95 16.81-16.96, 0 frames missed. Unpaced, the same render is ~8 ms:
the GPU clocks down during the 2.5 ms sleep. Bottleneck: the render kernel (GPU wait).

What the kernel is bound by (bench, rA = the M4 renderer):

| 720p rA, no conversion | GPU wait |
|-|-|
| vd 8, tier 0 | 2.5 ms |
| vd 48, tier 0 | 7.0 ms |
| vd 48, tier 3 | 7.5 ms |
| vd 96, tier 3 | 8.7 ms |

The primary ray's length sets the time; shading and the shadow ray (tier 3) add 0.4 ms. The lanes
(8192, one ray at a time each) wait on their voxel reads: the kernel is latency bound.

| # | Idea | Bottleneck | Expected | Measured | Verdict |
|-|-|-|-|-|-|
| 6 | Empty-space skipping: an occupancy word per 4x4 group of columns (a bit per 4-high slab), kept by `W.set`; a ray in an empty 4x4x4 group jumps to the cell past it, in exactly the state the one-cell walk reaches (per-axis event counts, x before y before z at equal t), so frames are identical | steps per ray (35 on average at c1 320x180, tier 0) | -30 to -45% of the render | steps per ray 35 -> 22; c1 320x180 23.6 -> 20.1 ms (-15%); GPU 720p **slower**: 10.4 -> 11.8 ms (branching), 9.5 -> 11.6 ms (branch-free, 5 rounds) | rejected for the GPU. On the CPU it is a real gain; parked in `scratch/skip/` for the CPU ladder (see there) |
| 7 | Tile-shaped leaves (the fork tree halves the longer side of a rectangle) so a wave's lanes trace nearby rays | SIMT divergence: a wave's lanes each run a different leaf, and the wave's loop runs as long as its longest ray | -10 to -25% | 10.40 -> 9.63 ms median-of-medians, p95 unchanged; inside the noise | superseded by 9 |
| 8 | Read the next cell's word even when the ray stops there (Bend masks the index), so the read's address never waits on the last read's value | the chain read -> stop -> next read | -10 to -30% on the GPU | with 7: 9.4-9.7 vs 9.3-11.8, inside the noise alone; see 10 for its effect | kept (with 9) |
| 9 | Strided leaves: leaf i of 2^d takes samples i, i + 2^d, ...: every leaf gets rays from the whole frame (load balance), and neighbour leaves (neighbour lanes) trace neighbour samples side by side (coherence) | lane imbalance and divergence | -10 to -20% | GPU 720p, 5 rounds vs rA: median 10.07 -> 9.38 (-7%), **p95 14.5-15.1 -> 12.7-13.0 (-2 ms)**; paced window, 3 rounds: render p95 12.6-12.85 -> 12.3-12.4, busy p95 16.80-16.96 -> 16.45-16.73; CPU c1 320x180 +3% (24.0 -> 24.7), c16 720p equal (72.7 vs 73.2) | **kept** |
| 10 | Drop the hit bookkeeping (hx, hy, hz, ht, hf): a solid cell freezes the ray, so the last state is the hit | registers and moves per step | -5 to -10% | CPU equal; GPU slower in 5 of 5 rounds (e.g. 7.61 -> 9.65, 10.09 -> 11.14): freezing makes the next read's address wait on this read's value (the chain 8 removed), which also confirms 8 matters | rejected |
