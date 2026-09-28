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
