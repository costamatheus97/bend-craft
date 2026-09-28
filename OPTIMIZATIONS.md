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

| 20 | The upscale in bands on 4 threads when the window has 2 Mpixel or more (`PLAY_BLIT_T`) | the upscale at 3840x2160 up4: 33 MB of stores a frame, fill 6.1 ms | fill -3 ms at 4K | 3 rounds interleaved at 4K up4: fill 6.05-6.18 -> 3.64-3.71, busy p95 17.6-18.0 -> 14.8-15.2, p99 18.6-19.0 -> 15.8-16.4; 8 threads no faster (3.73-3.86: store bandwidth). Same pixels as mode 1 (odd sizes, u 1-3) | **kept** | c007ab0 |

### Rungs unlocked (shipping build, rule above)

| Rung | Samples | Rounds | busy p95 | busy p99 | missed / round | present p95 | Screenshot |
|-|-|-|-|-|-|-|-|
| 720p native | 1280x720 | 3 (after 15) + 1 (after 19) | 14.97-15.48 -> 12.53 | 15.46-16.27 -> 13.11 | 0 | 16.684-16.692 | `media/gpu-720p-paced.png` |
| 1080p up2 | 960x540 | 4 (after 15) + 1 (after 19) | 14.76-15.51 -> 10.33 | 15.52-16.56 -> 10.64 | 0 | 16.688-16.711 | `media/gpu-1080p-up2-paced.png` |
| **1080p native** | 1920x1080 | 5 (after 19) | 14.61-14.89 | 15.27-15.86 | 0-1 | 16.682-16.695 | `media/gpu-1080p-paced.png` |
| **1440p up2** | 1280x720 | 4 (after 19) | 15.22-15.37 | 16.06-16.31 | 0-1 | 16.685-16.693 | `media/gpu-1440p-up2-paced.png` |
| **4K up4** | 960x540 | 4 (after 20) | 14.79-15.16 | 15.75-16.35 | 0-1 | 16.697-16.722 | `media/gpu-4k-up4-paced.png` |

After 24 (3 rounds each, `playp`, 0 missed in every round): 1080p up2 busy p95 9.49-9.56 / p99
9.98-10.14; 1440p up2 13.66-13.93 / 14.42-14.56; 4K up4 11.35-11.47 / 12.09-12.23. The thin
margins above (1440p up2, 4K up4) are now 2.1-4.5 ms.

Frame 900 of the walk is byte-identical on the GPU and on c16 at 1080p up2, 1080p native,
1440p up2 and 4K up4. The 1440p-up2 margin at p99 is 0.4-0.6 ms: the thinnest of the four.

Not unlocked (1 round each, after 19): 1440p native (not run yet: 2560x1440 samples, render
alone is over the budget at 1080p's 12.9 ms busy scaled by 1.8x), 4K up2 (1920x1080 samples:
busy p95 22.0, fill 6.1 before 20); 4K up4 unlocked with 20.

## GPU ladder: the upscale on the X server (after the 4K-up4 rung)

At 4K up2 (1920x1080 samples) the host upscale writes 33 MB a frame: fill 4.3 ms med, busy
p95 20.1-20.2, p99 20.9-21.1, 2-4 frames missed a round (build `playo`, 3 rounds).

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 24 | **XRender upscale**: the shared images hold the samples only; XShmPutImage puts them into a pixmap, and XRenderComposite draws the pixmap onto the window through a 1/2^U transform with the "nearest" filter (libXrender opened at run time; the host upscale when it is missing, or `PLAY_XR=0`). The X server scales; the game copies samples only | fill: the host upscale's stores (33 MB a frame at 4K) | fill -3 ms at 4K up2 | shipping build, 3 rounds interleaved, `playo` -> `playp`: **4K up2** fill 4.3 -> 0.93, busy med 17.7 -> 14.0, p95 20.1-20.2 -> 16.49-16.57, p99 20.9-21.1 -> 17.26-17.93, missed 2-4 -> 0-2; **4K up4** busy p95 15.16-15.36 -> 11.35-11.47, p99 16.21-16.36 -> 12.09-12.23, missed 0-2 -> 0; **1440p up2** p95 15.08-15.23 -> 13.66-13.93, p99 15.75-16.08 -> 14.42-14.56; **1080p up2** p95 10.31-10.40 -> 9.49-9.56, p99 10.75-10.88 -> 9.98-10.14; 1440p up2 and 1080p up2 0 missed in every round. Pixels: the window read back from the server (`PLAY_SHOT_SERVER`, XGetImage) = the host upscale's frame = `PLAY_XR=0`'s readback = the previous build's frame, at 4K up2 and up4 on the GPU (frame 120), at 640x360 u1, 1283x717 u1 and 1280x720 u2 on the CPU build, and on upstream main's CPU build (640x360 u1, frame 17) | **kept** | bc53586 |
| 25 | Fork depth 13 / 15 / 16 at 4K up2 (vs 14) | lane fill at 2 M samples | ±0.5 ms | 2 rounds: busy p95 16.39-16.43 (d13), 16.44-16.55 (d14), 16.63-16.69 (d15), 16.76-16.80 (d16); p99 17.0-18.4 for all | rejected (no change) | - |
| 26 | Empty-space skipping on the GPU again (the committed `go.s`, `PLAY_SKIP=1`), at 4K up2 | steps per ray | -1 ms | 2 rounds: busy med 13.90-14.00 -> 14.70-14.80, p95 16.29-16.43 -> 17.43-17.52: slower, as in 6 | rejected | - |

**4K up2 is not unlocked**: after 24 the busy p95 passes (16.49-16.57) but p99 does not
(17.26-17.93), and it misses up to 2 frames a round. The rest of the frame is the render kernel
(1920x1080 samples, the same work as 1080p native). The same build at 1080p native, one round:
busy med 13.0 / p95 14.9 against 14.0 / 16.6 at 4K up2, with fill only 0.3 ms apart; the other
~0.7 ms we put down to the 4K window's compositing in WSLg, which shares the GPU (not verified).
25 and 26 failed in a row: the **GPU lane is blocked** at 4K up2 and 1440p native, on the render
kernel's voxel read chain (12, 13).

What the upstream hoist (12) is worth at these rungs, measured on a prototype that patches our
emitted C (`tools/loc_patch.py`, never shipped; build `playq`, 3 rounds interleaved with
`playp`, frames identical):

| Rung | `playp` busy p95 | `playq` busy p95 | `playp` p99 | `playq` p99 | missed |
|-|-|-|-|-|-|
| 4K up2 | 16.42-16.68 | **15.06-15.37** | 17.05-18.92 | **15.98-16.20** | 2-4 -> 0 |
| 1440p native (2 rounds) | 21.34-21.60 | 18.81-18.91 | 22.03-23.35 | 19.73-20.53 | 5-7 -> 4 |

With the hoist, 4K up2 passes every clause of the rule. 1440p native needs more than the hoist.

## CPU ladder (16 threads)

The CPU lane is `play` on a plain CPU build (no GPU code), 16 threads, the same shipping rule.
Before the ladder the render alone ran 320x180 at 5.8 ms and 640x360 at 17 ms (c16, bench).

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 21 | Chunked leaves: a leaf traces 2^g consecutive samples (`BR_G` 4 / 6 / 8) instead of one strided sample per turn, so a worker's rays share cache lines | cache misses per ray on the CPU pool | -10% | bench c16 640x360, 4 rounds interleaved: rA 16.5-17.3 ms med, rG g0 16.9-17.9, g4 17.1-17.4, g8 16.7-17.9: inside the noise | rejected | - |
| 22 | `Lane.gpu`: play's default fork depth 8 on the CPU (14 on the GPU), since a CPU turn pays per task and 2^8 leaves already cover 16 workers | pool overhead: 2^14 leaves for 16 threads | -2 ms | paced 640x360, shipping: busy med 18.1 -> 15.9, p95 21.3 -> 18.8, p99 23.0 -> 20.0 | **kept** | 82f2d13 |
| 23 | Empty-space skipping (6) on the CPU, where branches are cheap: `go.s` in render.bend, the occupancy words in world.bend, `PLAY_SKIP` (1 on the CPU, 0 on the GPU); frames identical | steps per ray (35 -> 22) | -15% | bench c16 640x360, 3 rounds: 16.9-17.8 -> 14.8-15.9 med, p95 20.0-21.6 -> 17.4-17.6; paced 640x360: busy med 15.9 -> 14.8, p95 18.8 -> 17.2, p99 20.0 -> 18.5; GPU unchanged (skip off: +0.1 ms, noise) | **kept** | b529d0d |
| 27 | Fewer workers (`--threads` 8 / 12 vs 16): less contention with the X server and the main thread | pool contention | ±1 ms | paced 640x360, 2 rounds: busy p95 17.2-17.8 (16), 18.7-19.4 (12), 19.3-22.2 (8) | rejected | - |
| 28 | A world ceiling: a ray that climbs dry past the highest occupied slab (from the occupancy words, each frame) stops; frames identical at 640x360 frames 300 and 900, skip on and off | sky rays walking to the view's end | -1 ms | bench c16 640x360, 3 rounds: 15.1-15.6 -> 16.3-17.2 med (skip + ceiling 16.2-16.9); paced 640x360: busy p95 17.1-17.2 -> 18.06-18.09. The extra parameter and test in the ray loop cost more than the few rays it ends early. Patch parked in `scratch/ceil/ceil.patch`; not tried on the GPU | rejected | - |

### CPU rungs (shipping build `playc`, 3 rounds, 900 frames, real window, paced)

upN means each sample is N x N pixels. The two upscaled CPU rungs run `PLAY_U=2`, so they are up4; they were
first logged as "up2", which is what the screenshot's name still says. Native 720p on the CPU, one
round, 900 frames, paced: busy med 51.7, p95 60.1, p99 63.4 ms (about 19 fps), and 49.7 / 57.6 / 60.1
with the pool change of 31. c1 renders 720p in 179-212 ms (230 ns a ray), so even the control's 8.2x
would leave 22-26 ms. Native CPU 720p at 60 fps needs about 3x, and nothing left gives that.

| Rung | Samples | busy p95 | busy p99 | missed / round | present p95 | Status |
|-|-|-|-|-|-|-|
| 320x180 native | 320x180 | 5.55-5.61 | 5.91-6.01 | 0 | 16.677-16.680 | **unlocked** |
| 720p up4 | 320x180 | 5.62-5.71 | 5.98-6.00 | 0 | 16.678 | **unlocked** (upscaled) |
| 1080p up4 | 480x270 | 10.58-10.69 | 11.18-11.34 | 0 | 16.677-16.678 | **unlocked** (upscaled), `media/cpu-1080p-up2-paced.png`: frame 900 identical to the GPU's and to the server's readback |
| 640x360 native | 640x360 | 17.07-18.18 | 18.14-19.57 | 0 | 17.1-18.2 | not unlocked |
| 640x360 native | 640x360 | 16.61-16.92 (17.07-18.18 before 29) | 17.70-18.26 (18.14-19.57 before 29) | 0 | 16.76-16.92 | not unlocked: p99 ~1-1.5 ms over (passes with the pool change in 31, which needs upstream) |

After 27 and 28 the coordinator asked for three more ideas before calling the CPU lane blocked:
precomputed lighting (b), a coarse-depth prepass (c), and the root cause of the pool's thread
scaling (d). Each is below, measured the same way.

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 29 | **Sun table** (b, the sun half): per column, the height from which a ray toward the sun meets nothing. A corridor of columns within 1.6 blocks of the sun's path, each with its top and the climb the ray makes to reach it, built once per sun and raised by `W.set` when a block is added (a removal leaves it high, which is only conservative). A shadow ray that starts at or above it is lit without a walk. `PLAY_SKIP` bit 1 (on by default on the CPU, off on the GPU); frames identical (tests/render.bend: towers and open ground, table on and off, same hashes; tests/game.bend a view with the table) | shadow rays: one walk per lit face, most of them through open sky | -1 ms on the CPU | paced 640x360, shipping, 3 rounds: busy p95 17.2-17.4 -> **16.61-16.64 (passes)**, p99 18.0-18.5 -> 17.70-17.96 (does not); 4 more rounds of the committed build (`playc5`) 16.61-16.92 / 17.83-18.26. GPU (table on): busy med +0.5 ms, fill p95 1.3 -> 2.2 (the host reads the table's world words each frame, which costs on the twin), so it is off there | **kept on the CPU**, rejected on the GPU | 29877ee |
| - | **Ambient occlusion precomputed** (b, the AO half): the per-face corner occupancy stored with the world, not read per ray | tier 2's AO reads (the neighbour cells of every hit) | at most the tier's cost | bound, not built: tier 1 -> tier 2 costs 0.3-0.6 ms at c16 640x360 (bench, interleaved), so a free AO would save at most that, below the 1.0-1.5 ms p99 gap. An exact table needs the 26 neighbour bits of every cell, a word a cell (16 MB at lc 4, twice the world array), so it cannot live in the array's upper half; a per-column or per-slab table would change the pixels (it would be a separate, flagged option) | not built (bound below the gap, no room for the exact table) | - |
| 30 | **Coarse-depth prepass** (c): a distance table per 4-block group (the Chebyshev distance in groups to the nearest occupied group, capped at 4, kept by `W.set`), then one cone-traced ray per 8x8 tile that finds the smallest t no ray of the tile can hit before; every ray of the tile resumes its DDA exactly at that t (the per-axis event counts, the face of the last event, the step cap less the steps skipped). `PLAY_SKIP` bit 2 | empty space in front of the camera | -2 ms | frames identical with it on and off (CPU bench at 5 cameras, eye 12-20 blocks over the ground, skip 0/4 and 1/5; GPU bench 64x36 and 1920x1080, the same hashes). **High eye**, where tiles resolve: CPU c16 640x360 13.1 -> 8.0 ms (up 16), 11.8 -> 6.0 (up 20); GPU 1920x1080 samples 9.7-11.0 -> 8.8-9.5 (up 16). **At the play height** (bench eye 2 blocks over the ground): 0 of 3600 tiles resolve (the eye's own group is next to occupied ground, so its distance is 0 or 1 and the cone cannot move), so the pass only costs: CPU +0.2 to +1.0 ms, GPU 1920x1080 +1.5 to +2.2 ms. A per-cell distance table would let the cone leave the ground; at 4 bits a cell it needs half the upper half (2 MB at lc 4), more than is left after the atlas, the sun table and the occupancy words, so it would need a second array. Not built | rejected at the play camera; the patch is parked in `scratch/pre/coarse.patch` | - |
| 31 | **The pool's thread scaling** (d, root cause): see below. The prototype fix grows the CPU frontier to 8 x the workers (`tools/grain_patch.py`, a patch to our emitted C) | the pool's fixed grain: 16 units a turn | -1 ms | bench c16 640x360, interleaved, 3 rounds: 12.8-13.4 -> 11.8-11.9 ms (d 8); c8 14.7-15.4 -> 13.8-14.1. **Paced 640x360, shipping build plus the patch, 4 rounds interleaved with the same build unpatched: busy p95 15.25-15.39 vs 16.61-16.92, p99 15.90-16.33 vs 17.83-18.26, 0 missed, present p95 16.68 vs 16.76-16.92: the rung passes in every round.** Frame 900 of both is the same bytes. Small frames (bench c16, 3 rounds): 320x180 4.3-5.0 -> 3.5-3.8, 480x270 7.6-7.9 -> 7.2-8.3 (noise), 64x36 1.01-1.07 -> 1.05-1.10 (+0.05) | **needs an upstream change** (a one-line change in `cube_run`'s grow target); the game does not ship a patched runtime | the harness tool with this log |

After 29-31 the two-failure count restarted on both lanes:

| # | Idea | Bottleneck | Expected | Measured | Verdict | Commit |
|-|-|-|-|-|-|-|
| 32 | CPU: empty-space skipping off with the sun table on (`PLAY_SKIP=2`). The bench's camera had bit 0 costing 9-18% (c1 47 -> 54 ms), and the sun table now ends most open-sky shadow walks, which is where the skip paid | the skip's per-cell test | -1 ms | paced 640x360, `playc5`, 3 rounds interleaved: busy p95 16.60-16.78 (skip 3) vs **18.65-18.88** (skip 2), p99 17.50-18.02 vs 20.31-20.56, 1 missed in 2 rounds. On the walk the skip still pays; the bench camera does not stand for the walk | rejected (1 of 2, CPU) | - |
| 33 | CPU: where the p99 frames are. One shipping-build round with the per-frame log (`PLAY_LOG=1`, a diagnosis run, not a rung run) | the tail | a targeted fix if the slow frames cluster on edits (`W.set`, the sun table's upkeep) | the sim never exceeds 0.05 ms, so edits cost nothing; 52 frames are over 16.4 ms and 29 of them fall in frames 200-300, where the walk turns and the whole stretch is heavier (median 15.5-16.1 ms, against 13-14 elsewhere). The tail is heavy views plus the pool's tail (31), not spikes. Program-side levers for long open views are 23 (kept), 28 and 30 (rejected) | no fix to try (2 of 2, CPU): the CPU lane is blocked on the shipping runtime; 31 and 12 need upstream | - |
| 34 | GPU 4K up2: where the p99 goes. One per-frame-log round of `playp` (a diagnosis run), plus the HW lines of the 10 shipping rounds | busy p99 17.1-17.9 | a host-side lever | render (the bang) med 12.55, p95 14.88, **p99 15.57**; busy med 14.0, p99 17.2: about 1.5 ms of host work is on every frame, most of it the copy down (fill med 0.93, p99 2.0-2.2); put p99 0.08 and pump p99 0.05 (the server's ShmCompletion is never waited on). The one lever is overlapping the copy with the next frame's render (a device-to-device snapshot, then an async copy on a second stream, shown one frame later): about -0.9 ms busy, which would pass p99 in most rounds. The shim has only synchronous `cuMemcpyDtoH` (no streams, no async copy, no device-to-device copy), so it needs a platform change; not built, bound only. The kernel's own tail needs the hoist (12) | **needs a platform change** (1 after the restart, GPU). With it, every lever left on the GPU lane needs upstream or the platform: the copy (this) and the kernel's tail (12) | - |
| 35 | **Upstream main ef66a7cc** (after 2.0.32: the hoist of 12 landed as #1155) for the CPU lane, and the pool's grain (31) again on it | the per-voxel location read; the pool's fixed grain | -0.6 ms (main), -1 ms more (grain) | paced 640x360, same source, 3 rounds interleaved: busy p95 16.75-16.98 -> 15.95-16.30, p99 18.23-18.73 -> 17.20-18.20 (`logs/main-ef66-ab.txt`); the p99 still misses. Plus grain K 8, 5 rounds interleaved: stock p95 16.6-18.2 / p99 17.7-20.5 (0 of 5 pass), K 8 15.2-15.7 / 16.0-19.3 (3 of 5), K 16 15.1-16.5 / 16.0-18.6 (1 of 5) (`logs/grain-ef66-640x360.txt`). K 8 on the other rungs, 3 rounds: 320x180 p99 5.6-5.8 -> 4.6-4.7, 1080p up4 11.1-11.3 -> 8.6-9.1 (`logs/grain-ef66-sweep.txt`). Frame 300 the same bytes on old main, new main and new main + K 8 | **kept** (main); grain still needs upstream | 4fdf0b3 |
| 36 | **S132, the skip walk rewritten** (`go.s` in render.bend): `ix` a `match`, not `Fx.sel` (which evaluates both arguments, so every step computed both indices); a solid cell freezes the ray, so no hit fields ride along; the bounds test one mask (`nsd = 0 - side`) instead of 4 compares. From the per-step investigation (`scratch/pergap/REPORT.md`): a C reference of the same renderer, pixel-identical in 48 of 48 cases, puts Bend at 1.6-1.8x the scalar C and 2.9-3.1x AVX2 C at c16; the gap is instruction count (IPC 4.4 vs 4.6), not stalls | instructions a step (192 vs the C port's 121) | -10% | callgrind: -12.9% instructions; bench c16 640x360 16.96 -> 15.24, 720p 59.61 -> 52.42 (`logs/s132-matrix.txt`); **paced 640x360, 3 rounds interleaved: busy med 13.4 -> 11.8-11.9, p95 15.9-16.2 -> 14.2-14.5, p99 16.9-18.0 -> 15.3-15.9, 0 missed: the rung passes in every round** (with grain on top: p99 13.4-13.6; `logs/s132-paced.txt`). Frames identical (vcmp 120/120, PLAY_SHOT N=900 at 640x360 and 720p); tests 21/21 CPU lanes, 5/5 gpu. Nat checks (-1.5% after S132), shift guards and `-march=native` measured and not worth it; SIMD needs a compiler feature | **kept** | 7b203f1 |

**Why 16 threads buy only ~4.7x (31).** Measured on the bench at c16 640x360 (d 8, skip 3,
BR_BANG=0), with patches to our emitted C that count and time (in `scratch/`, not shipped):

- **The VM is not the ceiling by itself.** A plain C control in this WSL2 VM scales 6.9x at 8
  threads and 8.2x at 16 (ALU), 6.2-7.5x and 6.6-8.5x (random reads over 256 KB to 256 MB), and 5.7x /
  8.1x in bursts of ~5 ms with a condvar between them, as the pool runs. Steal time 0. Bend
  gets 4.1x at c8 and 4.7-5.2x at c16 (c1 54-55 ms, c4 15.7-18.2, c8 13.4, c16 10.6-11.6).
- **Not allocation.** 819 `heap_alloc` calls a frame for 230,400 samples (0.0036 a sample, about
  3 a leaf), about 4 bank pops a frame; a ray's state never goes through the heap.
- **Not memory bandwidth or cache size.** The lc 2 world (a small fraction of lc 4's, well inside the 32 MB L3)
  scales the same as lc 4 at the same spot (c4 14.7-16.1, c8 13.1-13.7, c16 11.9-12.0 against
  c1 55.4-55.7).
- **Not false sharing on the framebuffer.** A writer that drops the store, and one that puts
  each sample on its own cache line, time the same as the real one at c1, c8 and c16 (c8
  12.8-13.5 for all three). This agrees with 21.
- **Not the shared array's refcount line.** The hoist (12) saves the same fraction at c1
  (-13.6%) as at c16 (-9 to -17%); contention would make it save more at c16.
- **Not the fixed cost of a turn.** A 16x16 frame takes 0.27 ms at c1 and 0.94 at c16; the
  grow turn is 0.3-0.55 ms at d 8.
- **The cause: a fixed grain on shared cores.** A render turn always has exactly 16 units with
  work (rows of 16 rings), at c8 or c16 and at fork depth 4 to 12: `cube_run` grows the
  frontier only to ceil(workers / 8) cube rows, and a unit runs its whole subtree. At c1 and c2
  the 16 units take 2.92-3.13 ms each. From c4 up some take up to 5.7 ms (1.9x). That is what two
  workers on one physical core look like (the host places the vCPUs, and the guest cannot prevent it (pinning inside WSL2 changes nothing: 4
  threads on 0,1,2,3 time the same as on 0,2,4,6, within the noise), and it means this loop gets almost nothing
  from SMT. With a
  fixed grain the turn waits for the slowest unit: at c16 the workers' busy time is 6.6 ms mean
  and 9.6 max, so 30% of the pool idles at the barrier; at c8 each worker runs exactly 2 units,
  with the slowest pair at 11.3 ms against a mean of 9.0. More workers than CPUs (24 to 64) do
  not help (more units, but more workers than cores too), and deeper trees do not either (still
  16 units: the grow sets the count, not the tree). Growing the frontier to 8 x the workers (128 units at c16) balances the workers (at d 12,
  7.5-8.3 ms busy each) and gives the -1 ms of 31. The rest of the gap to 8x is the shared cores themselves
  (total CPU a frame 49 ms at c1, 79 at c8, 105 at c16).
- The 2.6x quoted before 29 (c1 44.5 ms, c16 ~17) set a bench c1 frame against a paced c16 frame
  in the window; on the same bench and camera it is 4.7-5.2x.

**Where the CPU lane stands.** On upstream main ef66a7cc (35), which has the hoist, 640x360 native
is still not unlocked: p95 passes (15.95-16.30) and p99 is 0.5-1.5 ms over (17.20-18.20). With the
pool's grain on top it passes in 3 of 5 rounds (p99 16.0-19.3), so it is close but not reliable on
this machine. Before 35, on the shipping build: p95 16.61-16.92, p99 17.70-18.26, and two changes
would each take it, both needing upstream:

- the pool's grain (31): 640x360 passes in 4 of 4 rounds with it (p99 15.90-16.33);
  the pool fix measured before (#1092, tree pool-229: rows only, an early turn end, a yield before
  sleeping) keeps the grow target, which is why it measured the same as main;
- the hoist (12): -12 to -18% in the bench; with it on both walks the paced p99 was 17.72-17.91
  before 29, so it would need 29 too, which was not measured together.
