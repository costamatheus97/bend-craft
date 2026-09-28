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
- **Rung unlock (coordinator's ruling, paced rungs).** On the shipping build (TREE_GPU, no hw
  splice, no gprof, no per-frame log), a real window, 900 frames, 3 rounds or more, every round:
  busy p95 <= 16.7 ms, busy p99 <= 16.7 ms, at most 1 missed frame (a present interval over
  25 ms), present p95 within 16.75 ms (a sanity check: it sits at the pace's floor). Unpaced
  rungs keep frame p95 <= 16.7, p99 <= 20.
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

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 6 | Empty-space skipping: an occupancy word per 4x4 group of columns (a bit per 4-high slab), kept by `W.set`; a ray in an empty 4x4x4 group jumps to the cell past it, in exactly the state the one-cell walk reaches (per-axis event counts, x before y before z at equal t), so frames are identical | steps per ray (35 on average at c1 320x180, tier 0) | -30 to -45% of the render | steps per ray 35 -> 22; c1 320x180 23.6 -> 20.1 ms (-15%); GPU 720p **slower**: 10.4 -> 11.8 ms (branching), 9.5 -> 11.6 ms (branch-free, 5 rounds) | rejected for the GPU. On the CPU it is a real gain; parked in `scratch/skip/` for the CPU ladder (see there) | - |
| 7 | Tile-shaped leaves (the fork tree halves the longer side of a rectangle) so a wave's lanes trace nearby rays | SIMT divergence: a wave's lanes each run a different leaf, and the wave's loop runs as long as its longest ray | -10 to -25% | 10.40 -> 9.63 ms median-of-medians, p95 unchanged; inside the noise | superseded by 9 | - |
| 8 | Read the next cell's word even when the ray stops there (Bend masks the index), so the read's address never waits on the last read's value | the chain read -> stop -> next read | -10 to -30% on the GPU | with 7: 9.4-9.7 vs 9.3-11.8, inside the noise alone; see 10 for its effect | kept (with 9) | f01f7f9 |
| 9 | Strided leaves: leaf i of 2^d takes samples i, i + 2^d, ...: every leaf gets rays from the whole frame (load balance), and neighbour leaves (neighbour lanes) trace neighbour samples side by side (coherence) | lane imbalance and divergence | -10 to -20% | GPU 720p, 5 rounds vs rA: median 10.07 -> 9.38 (-7%), **p95 14.5-15.1 -> 12.7-13.0 (-2 ms)**; paced window, 3 rounds: render p95 12.6-12.85 -> 12.3-12.4, busy p95 16.80-16.96 -> 16.45-16.73; CPU c1 320x180 +3% (24.0 -> 24.7), c16 720p equal (72.7 vs 73.2) | **kept** | f01f7f9 |
| 10 | Drop the hit bookkeeping (hx, hy, hz, ht, hf): a solid cell freezes the ray, so the last state is the hit | registers and moves per step | -5 to -10% | CPU equal; GPU slower in 5 of 5 rounds (e.g. 7.61 -> 9.65, 10.09 -> 11.14): freezing makes the next read's address wait on this read's value (the chain 8 removed), which also confirms 8 matters | rejected | - |
| 11 | Read one cell ahead: the next word's read issues before this cell's shading decision (`scratch/render.rL.bend`) | the chain read -> decide -> read | -10% | 6 rounds vs rS: 9.4-9.8 vs 9.2-10.9 median, p95 13.4-14.2 vs 12.1-13.6: p95 worse in 5 of 6 | rejected | - |
| 12 | Hoist the shared array's location out of the ray loop (`tools/loc_patch.py`: `blk_loc` once per leaf in our emitted C, not once per read) | every read of `w` goes through `blk_loc`, whose load of the refcount cell ends in `s_waitcnt vmcnt(0)`: the in-order counter makes each voxel read wait for every earlier load, so a lane never has two reads in flight | -10 to -20% | 6 rounds vs rS: median equal (9.0-10.5 vs 8.3-10.6), **p95 11.6-12.0 vs 12.0-13.2 (-1 ms)** | **needs an upstream change** (the compiler's redirect read; upstream draft #999 and our #1084 do this hoist). Not shipped: the game must not depend on a patched C | c56fe00 (the harness tool) |
| 13 | Two cells a step (the DDA advances twice per loop iteration, so two independent reads per iteration) | the same read chain | -10% | alone: equal (9.0-10.0 vs 8.7-10.3 median, p95 12.2-12.9 vs 12.0-13.4); **with 12**: p95 10.2-10.8 vs rS 12.1-12.9 and rP 11.7-12.0, median equal | rejected alone; with 12, **needs an upstream change** (the same hoist as 12: upstream draft #999, our #1084) | - |
| 14 | Direct tiles: leaves of 2^TL x 2^TL samples that build the window Image themselves (`BR_IMG=2`), no framebuffer, no conversion pass | the conversion pass | -2 ms | TL 2: 19.7 ms vs 7.6 (the bench at 64 x 36 tile leaves), TL 3 no better: the leaves allocate Image nodes, and allocation on the GPU is dear | rejected | - |
| 15 | **Blit.frame** (`blit.c`, `PLAY_MODE=2`, now the default): bend-craft's own foreign effect copies the flat framebuffer straight into the window's XImage (both 0x00RRGGBB): one device-to-host copy on the GPU lane (a `gpu_sync` only when a host write dirtied the framebuffer's chunks), a memcpy on the CPU, a nearest upscale when rendering below the window. No Image quadtree, no conversion pass, no `window_fill` walk | the show stage: conversion (inside the render bang) + `window_fill` (2.1 ms at 720p) + the twin's full `gpu_sync` | -2 to -3 ms busy | paced window 720p, 5 rounds interleaved vs mode 1: **busy p95 14.94-15.31 vs 16.52-16.76 (-1.4 ms, 5 of 5)**, busy med 13.2-13.6 vs 14.0-14.4, fill 1.62 vs 2.1; offscreen 720p frame 13.1 / p95 14.2 vs 13.1 / 15.7; CPU c16 720p show 0.3 ms vs 12.8. Pixels (P6 of the window's last frame): mode 2 = mode 1 at 320x180 on gpu (N = 1, 2, 3, 17) and on the CPU build at 4 threads (N = 17, plus several sizes and upscales before the commit); upstream main checked in mode 2 only (N = 17, same hash); at 720p N = 900 mode 2 on gpu = mode 2 on c16 (lanes, not modes, compared there) | **kept** | 85632ae |

### Rung 720p paced: unlocked (GPU, native 1280x720, default tier 3 / vd 48)

`bench/abp.sh 5 "PLAY_MODE=1@build/play2_l0 PLAY_MODE=2@build/play2_l0" DISPLAY_ON=1 PLAY_HW=1`,
real WSLg window, 900 frames of the scripted walk each:

| mode 2 (default), round | present p95 | present p99 | busy p95 | busy p99 | missed (> 25 ms) |
|-|-|-|-|-|-|
| 1 | 16.686 | 16.699 | 14.94 | 15.51 | 0 of 896 |
| 2 | 16.684 | 16.707 | 15.31 | 16.03 | 0 |
| 3 | 16.683 | 16.706 | 15.14 | 15.66 | 0 |
| 4 | 16.690 | 16.795 | 15.20 | 16.71 | 1 |
| 5 | 16.685 | 16.722 | 15.21 | 15.60 | 0 |

Mode 1 in the same rounds: present p95 16.745-16.789, p99 17.25-17.87, busy p95 16.52-16.76. Frame
900 is byte-identical on the GPU and on c16 (`media/gpu-720p-paced.png`).

The shipping build (TREE_GPU CUDA, no hw harness splice, no gprof, no per-frame log;
`build/playg`), 3 rounds, same walk: present p95 16.687-16.692 / p99 16.706-16.723, busy p95
14.97-15.48 / p99 15.46-16.27, 0 missed; frame 900 has the same hash. With `PLAY_SHOT` set (a
3.7 MB copy each frame) busy p95 rises to 15.7 and present p95 to 16.69-16.72: the present metric
sits at the pace's floor and moves on noise; busy p95 is the headroom. Metric caveat: the
present interval is the pace's nanosleep wake-to-wake, whose jitter alone is ~0.02 ms; mode 1 missed
p95 by 0.05-0.09 ms with 0 missed frames, so busy p95 (1.4-1.7 ms of headroom in mode 2) is the
robust number. Play's own `loop` (Bend's clock, iteration to iteration) reads p95 17.1-17.2: it
also counts the effect's return into Bend, which is not on the display's cadence.

## GPU ladder, rung 1080p native (1 round at the start)

Mode 2, paced, real window: render 11.7 med / 13.1 p95 (GPU wait 9.6, up 0.77, down 0.94), fill
2.2 / 2.8, busy med 16.7 / p95 18.6 / p99 21.1, present p95 18.6. Bottleneck: the render kernel
(the voxel read chain, 12 and 13 above) plus the fixed turn cost (up + down 1.7 ms).

## GPU ladder: the show stage (after the 720p rung)

With the render at 10-11 ms (720p samples), the rest of the frame is the show: the copy down,
the upscale and the put. Profile at 2560x1440 up2 (`PLAY_HW=1`, shipping build, after 15): sim
0.3, render 11.0 / 12.8 p95, fill 3.1 (copy down + upscale), **put 4.7 med / 7.7 p95** (XPutImage
writes 14.7 MB down the X socket), busy med 18.9 / p95 24.4, 23-36 frames missed a round.

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 16 | MIT-SHM: the window's pixels in a shared-memory XImage and XShmPutImage (libXext opened at run time; XPutImage when the display lacks it, or `PLAY_SHM=0`); the next frame XSyncs before it writes the segment again | the put | put 4.7 -> < 0.5 ms at 1440p, 1.3 -> < 0.1 at 720p | 3 rounds interleaved: put 1.29 -> 0.034 ms (720p), 4.71 -> 0.034 (1440p up2); busy p95 15.0-15.4 -> 13.6-13.8 (720p), 24.4-24.8 -> 17.9-18.1 (1440p up2), misses 23-36 -> 0. A server-side capture of the live window (`media/window-capture-720p-shm.png`) shows the frame | **kept** | e4691ff |
| 17 | Upscale: widen each sample row once (two pixels a 64-bit store at u = 1) and memcpy its copies, instead of one indexed load a pixel on every row | the upscale inside fill | -0.5 ms at 1440p up2 | 3 rounds: fill med -0.1 to -0.4 at 1440p up2, busy p95 -0.07 to -0.29; neutral at 1080p up2. Same pixels as mode 1 at u 1-3, odd sizes | kept (small) | 50572df |
| 18 | Page-lock the copy's host target (`cuMemHostRegister` on the shared image and on the upscale's staging buffer; `PLAY_PIN=0` turns it off) so the device-to-host copy is direct, not through a pageable bounce | the copy down (1.6 ms for 3.7 MB) | copy -1 ms at 720p | 3 rounds (same binary, `PLAY_PIN` 0 vs 1): fill 1.59-1.65 -> 0.48 (720p), 3.4-3.6 -> 1.8 (1440p up2); busy p95 13.6-13.7 -> 12.6-12.7 (720p), 17.8-17.9 -> 15.9-16.5 (1440p up2) | **kept** | 50572df |
| 19 | Two shared images, each reused on its ShmCompletion event: a frame fills the image the server is done with (`PLAY_SHM=1`: one image and an XSync) | the XSync of 16 (the server still reading the last frame): pump 1.5 ms p95, 2.1 p99 at 1440p up2 | busy p99 -1.5 ms at 1440p up2 | 3 rounds: pump p95 1.26-1.57 -> 0.03-0.05; busy p95 16.0-16.4 -> 15.2-15.4, **p99 17.1-17.7 -> 16.06-16.29** (1440p up2); 720p unchanged. Live-window capture `media/window-capture-1440p-up2-shm2.png` | **kept** | edf0d0a |

### Rungs unlocked (shipping build, rule above)

| Rung | Samples | Rounds | busy p95 | busy p99 | missed / round | present p95 | Screenshot |
|-|-|-|-|-|-|-|-|
| 720p native | 1280x720 | 3 (after 15) + 1 (after 19) | 14.97-15.48 -> 12.53 | 15.46-16.27 -> 13.11 | 0 | 16.684-16.692 | `media/gpu-720p-paced.png` |
| 1080p up2 | 960x540 | 4 (after 15) + 1 (after 19) | 14.76-15.51 -> 10.33 | 15.52-16.56 -> 10.64 | 0 | 16.688-16.711 | `media/gpu-1080p-up2-paced.png` |
| **1080p native** | 1920x1080 | 5 (after 19) | 14.61-14.89 | 15.27-15.86 | 0-1 | 16.682-16.695 | `media/gpu-1080p-paced.png` |
| **1440p up2** | 1280x720 | 4 (after 19) | 15.22-15.37 | 16.06-16.31 | 0-1 | 16.685-16.693 | `media/gpu-1440p-up2-paced.png` |

Frame 900 of the walk is byte-identical on the GPU and on c16 at 1080p up2, 1080p native and
1440p up2. The 1440p-up2 margin at p99 is 0.4-0.6 ms: the thinnest of the four.

Not unlocked (1 round each, after 19): 1440p native (not run yet: 2560x1440 samples, render
alone is over the budget at 1080p's 12.9 ms busy scaled by 1.8x), 4K up2 (1920x1080 samples:
busy p95 22.0, fill 6.1), 4K up4 (960x540 samples: busy p95 17.3, p99 18.3, fill 6.0 of which
the upscale into 33 MB is most).
