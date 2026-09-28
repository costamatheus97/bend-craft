# bend-craft run log

Machine: AMD Ryzen 7 5800XT (8 cores / 16 threads), RX 7800 XT (gfx1101) through the CUDA lane over
HIP (the shim), WSL2 with WSLg (`DISPLAY=:0` exists; the shim env unsets it). Every GPU-touching
process ran through `tools/gx.sh` (the shared bench lock, a timeout, then `drv.sh`); every one is
also a line in `logs/gpu.log`.

## 2026-09-27 22:40-23:00 tooling and the window-path spike

- `tools/cbuild.sh` emits C with a Bend tree (`gpu` = pr/gpu-profile f81948eb, `L0` = its gprof L0
  copy, `main` = pr/main-229) and compiles it on the CPU only; `--gpu-build` then runs under gx.sh.
- `tools/hw_patch.py` splices `tools/hw.c` into *our* emitted C only (test harness, never a Bend
  tree): it times `window_fill` and the interval between `Window.frame` calls, and runs offscreen
  when there is no display.
- Mechanics found while writing the spike (`spike/win.bend`):
  - a destructuring let of a computed value is refused ("a match cannot scrutinize a computed
    value"): continuation helpers take the pair as a parameter (as bend-game's `R.img.*`);
  - a leaf of a range split must guard an empty range: `U32.to_nat(i1 - i - 1)` of an empty leaf
    is 2^32 - 1 iterations. The CPU lane caught it (hung under `timeout`); on the GPU that loop
    could not park and would have met the watchdog. Rule kept: every new kernel runs on the CPU
    lane first.
  - handle dups of an `@unsafe` `+arr` bump one refcount cell (`term_keep` on an RFC term), so a
    redirect is never chained: one extra dependent load per access, whatever the fork depth. Reads
    inside a leaf thread the handle linearly (no keep per read).

Spike: a per-pixel-varying picture (a hash and one read of a 2^20-word array per sample), 60 frames,
median of frames 3+. `bang` = the host clock around the one bang, `turn/up/wait/down` = gprof L0,
`fill` = window_fill (on the GPU lane the device `window_dev` walk + the copy down), `frame` = the
interval between Window.frame calls. Offscreen (no pump, pace or XPutImage) unless noted.

| lane | size | mode | bang ms | turn (up / wait / down) | fill ms | frame ms (p95) |
|-|-|-|-|-|-|-|
| CPU 16 thr | 1280x720 | 0 direct Image | 3.3 | - | 11.3 (per-pixel walk) | 14.6 (15.4) |
| CPU 16 thr | 1280x720 | 1 flat fb + convert, one bang | 6.4 | - | 11.6 | 18.0 (18.5) |
| GPU | 320x180 | 0 | 3.3 | 3.2 (0.9 / 1.25 / 0.86) | 0.84 | 4.4 |
| GPU | 1280x720 | 0 direct Image | 3.66 | 3.36 (0.86 / 1.45 / 0.87) | 1.86 | 5.5 (6.2) |
| GPU | 1280x720 | 1 flat fb + device convert | 4.45 | 4.44 (0.69 / 2.15 / 1.20), 2 passes | 1.74 | 6.3 (6.8) |
| GPU | 1280x720 | 2 flat fb, host convert | 9.2 | 3.64 | 3.45 (uploads the tree) | 12.7 (14.4) |
| GPU | 1920x1080 | 0 | 7.1 | 6.89 (0.80 / 4.93 / 0.89) | 2.42 | 9.6 (10.2) |
| GPU | 1920x1080 | 1 | 8.1 | 8.07 (0.68 / 5.64 / 1.30) | 2.46 | 10.6 (11.0) |
| GPU | 1920x1080 | 2 | 14.8 | 5.01 | 5.22 | 20.3 (25.8) |
| GPU, real WSLg window, no pace | 1280x720 | 1 | 4.69 | - | 1.92 (show 3.06 with XPutImage) | 7.8 (8.6) |
| GPU, real WSLg window, no pace | 1920x1080 | 1 | 8.42 | - | 2.66 (show 5.79) | 14.1 (16.7) |

Reading:
- The CUDA arm's device fill (`window_dev` when `io_gpu`) is what runs on this shim: 1.7-2.5 ms
  against 11.3 ms for the CPU arm's per-pixel walk at 720p.
- Converting on the host costs 5-7 ms more (the tree is built on the host, then uploaded for the
  device fill). Convert on the device, in the render's bang.
- The window path (turn, conversion, fill, XPutImage) with a trivial pixel is ~7.8 ms of a real
  720p frame and ~14 ms at 1080p. 720p leaves ~9 ms for the render kernel and the sim; 1080p at
  60 fps needs an internal-resolution upscale (2x2 leaves).

## 2026-09-27 23:00-23:10 M1: world and terrain

- `world.bend`: 16 << lc by 64 by 16 << lc blocks, one byte a block, four per U32 packed along y,
  columns of 16 words grouped in 16 x 16-column chunks (4096 words). Two passes per generation (a
  height map, then the columns by gather); both are fork trees over the column index.
- Name clash found: a module's defs are seen through its alias, so a def named `W.gen` inside
  world.bend is `W.W.gen` to the importer, and `W.gen(~t, ..)` parsed as "expected a term" at `~`.
- Tests (`run_tests.sh`): `tests/world.bend` (lc 2) passes check, js, c1, c16, main (upstream
  main-229) and gpu; `tests/world_full.bend` (lc 4) passes c1, c16, main and gpu. The hashes are
  the same at fork depths 0, 3, 8, 13 and 14, on every lane; the counting writer shows every word
  written exactly once (count-bad 0) and every column index round-trips.

Terrain generation, lc 4 (65536 columns, 4 MiB), ms, median of 7 (CPU) / 10 (GPU):

| lane | d=0 | 2 | 4 | 6 | 8 | 10 | 12 | 13 | 14 |
|-|-|-|-|-|-|-|-|-|-|
| CPU 1 thread | 10.5 | 11.2 | 11.0 | 11.3 | 11.2 | 11.8 | - | 11.5 | - |
| CPU 16 threads | 10.3 | 7.6 | 4.3 | 4.2 | 4.1 | 4.3 | - | 5.4 | - |
| GPU turn (wait) | - | - | - | - | 7.6 (5.1) | 4.9 (1.9) | 4.2 (1.3) | 4.4 (1.2) | 4.2 (1.2) |

- One CPU thread does ~6 M columns/s. 16 threads buy 2.5x: the fork tree's ~3 ms is most of it.
- The GPU turn is 4.2 ms of which the kernel is 1.2 ms; the rest is the up (1.4 ms, the fresh
  world) and down (1.1 ms). At this size the lanes tie; terrain runs once, so it is not a frame cost.
- GPU d 8 leaves lanes idle (256 leaves of 256 columns: 5.1 ms of kernel); d 12-14 fill them.

## 2026-09-27 23:20-00:10 M2: the renderer

`render.bend`: per-sample fixed-point DDA (16.16 positions, 20.12 t, step cap 3 vd + 3), one fork
tree over sample ranges writing a flat `Array<U32>` framebuffer, then the window Image built from
it in the same bang (tiles of 16 x 16, off-frame quadrants one Pix). The scene array carries the
voxels (lower half) and the 16 x 16 texture atlas (upper half), so a leaf reads one handle.

Tests (`tests/render.bend` lc 2 64 x 36 on js/c1/c16/main/gpu; `tests/render_full.bend` lc 4
320 x 180 on c1/c16/main/gpu): tiers 0-3 at fork depth 0 and tier 3 at depths 4 and 11 give the
same framebuffer and Image hashes on every lane; the counting-writer pass writes every sample
exactly once and nothing past the frame.

Bench (`bench/m2.sh`, `logs/bench-m2.txt`): one spot (200, 60) on the shore, pitch 0, a full turn
of yaw over 36 measured frames (5 warm-up), fork depth 14 on the GPU. `frame` is the host clock
around the one bang (render + Image conversion), ms; gprof L0 medians up / wait (kernel) / down.
No window fill here (the spike measured it: ~1.8 ms at 720p, ~2.5 at 1080p offscreen).

| lane | size | tier | vd | d | frame med / p95 / p99 | up / wait / down |
|-|-|-|-|-|-|-|
| gpu | 320x180 | 0 | 64 | 14 | 4.59 / 4.87 / 7.20 | 0.68 / 2.38 / 1.06 |
| gpu | 320x180 | 0 | 48 | 14 | 4.55 / 5.05 / 6.00 | 0.68 / 2.26 / 1.12 |
| gpu | 320x180 | 2 | 64 | 14 | 4.80 / 5.30 / 6.37 | 0.70 / 2.42 / 1.23 |
| gpu | 320x180 | 2 | 48 | 14 | 4.66 / 5.05 / 6.58 | 0.68 / 2.30 / 1.19 |
| gpu | 320x180 | 3 | 64 | 14 | 4.66 / 5.00 / 6.15 | 0.66 / 2.41 / 1.14 |
| gpu | 320x180 | 3 | 48 | 14 | 4.60 / 5.20 / 6.07 | 0.67 / 2.31 / 1.18 |
| gpu | 640x360 | 0 | 64 | 14 | 6.56 / 6.99 / 8.73 | 0.70 / 4.07 / 1.31 |
| gpu | 640x360 | 0 | 48 | 14 | 6.09 / 6.50 / 8.19 | 0.69 / 3.62 / 1.31 |
| gpu | 640x360 | 2 | 64 | 14 | 6.44 / 6.71 / 7.62 | 0.66 / 4.16 / 1.08 |
| gpu | 640x360 | 2 | 48 | 14 | 6.06 / 6.42 / 8.34 | 0.68 / 3.75 / 1.16 |
| gpu | 640x360 | 3 | 64 | 14 | 6.49 / 6.85 / 7.93 | 0.66 / 4.12 / 1.17 |
| gpu | 640x360 | 3 | 48 | 14 | 5.96 / 6.40 / 7.97 | 0.67 / 3.74 / 1.10 |
| gpu | 1280x720 | 0 | 64 | 14 | 9.96 / 12.27 / 12.46 | 0.67 / 7.68 / 1.11 |
| gpu | 1280x720 | 0 | 48 | 14 | 9.76 / 11.09 / 12.58 | 0.66 / 7.39 / 1.10 |
| gpu | 1280x720 | 2 | 64 | 14 | 10.25 / 13.06 / 13.08 | 0.68 / 7.95 / 1.19 |
| gpu | 1280x720 | 2 | 48 | 14 | 11.26 / 12.37 / 13.99 | 0.73 / 8.64 / 1.40 |
| gpu | 1280x720 | 3 | 64 | 14 | 10.86 / 12.75 / 12.78 | 0.71 / 8.35 / 1.22 |
| gpu | 1280x720 | 3 | 48 | 14 | 9.61 / 12.17 / 13.70 | 0.67 / 7.49 / 1.13 |
| gpu | 1920x1080 | 0 | 64 | 14 | 14.84 / 19.14 / 19.43 | 0.67 / 12.58 / 1.27 |
| gpu | 1920x1080 | 0 | 48 | 14 | 12.71 / 17.17 / 18.86 | 0.66 / 10.29 / 1.26 |
| gpu | 1920x1080 | 2 | 64 | 14 | 14.97 / 18.48 / 19.32 | 0.67 / 12.59 / 1.21 |
| gpu | 1920x1080 | 2 | 48 | 14 | 13.09 / 17.60 / 18.97 | 0.66 / 10.69 / 1.18 |
| gpu | 1920x1080 | 3 | 64 | 14 | 15.24 / 18.79 / 19.44 | 0.68 / 12.73 / 1.43 |
| gpu | 1920x1080 | 3 | 48 | 14 | 13.02 / 17.57 / 19.16 | 0.68 / 10.70 / 1.24 |
| c1 | 320x180 | 2 | 64 | 0 | 21.13 / 29.92 / 29.92 | - |
| c16 | 320x180 | 2 | 64 | 8 | 5.78 / 7.78 / 7.78 | - |
| c1 | 640x360 | 2 | 64 | 0 | 84.53 / 107.74 / 107.74 | - |
| c16 | 640x360 | 2 | 64 | 8 | 17.31 / 21.94 / 21.94 | - |
| c16 | 1280x720 | 2 | 64 | 8 | 67.49 / 80.86 / 80.86 | - |

Reading:
- On the GPU the tier hardly moves the time: tier 0 (flat) and tier 3 (textures, AO, a shadow ray
  per lit face) are within noise. Likely (not profiled per instruction) the kernel is bound by
  the primary ray's chain of dependent voxel loads, which 8192 lanes cannot hide, rather than by
  shading. So the top tier costs nothing measurable, and is the default candidate.
- The fixed part of a turn is ~1.8 ms (up 0.67 + down 1.1) plus the launch; the kernel scales
  with samples: ~2.3 ms at 320 x 180, ~4 at 640 x 360, ~7.5-8.5 at 720p, ~10.5-12.7 at 1080p.
- View distance 48 against 64 saves ~10% at 720p and ~15% at 1080p, within the run-to-run noise
  of the machine at 720p.
- Fork depth on the GPU (720p tier 3, d 12..17): d 12 is worse (11.1 ms median), 14-17 are the
  same within noise (8.9-10.2).
- CPU: 16 threads reach 60 fps (render only) at 320 x 180 (5.8 ms); 640 x 360 is 17 ms, 720p 67 ms.
  One thread: 21 ms at 320 x 180.
