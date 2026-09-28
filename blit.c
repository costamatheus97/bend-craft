// Blit.frame: bend-craft's own window frame. It shows the flat framebuffer (ws x hs samples,
// row-major 0x00RRGGBB, each sample 2^u x 2^u pixels) in a window made by Window.open, so no
// Image quadtree is built for the frame and none is walked to fill the window:
//   - the CPU lane copies the samples into the X11 image (a memcpy when u = 0);
//   - the GPU lane copies them from the device heap with one cuMemcpyDtoH, straight into the
//     X11 image when u = 0.
// Then the 60 Hz pace and the put: XShmPutImage from a shared-memory image when the display
// has MIT-SHM (libXext opened at run time; PLAY_SHM=0 turns it off), else XPutImage as
// Window.frame does. The events come back as Window.frame
// gives them (the same five-word records, key codes and list), so input.bend reads either.
//
// It reads the leading fields of the runtime's window block (BendWin, which window_open.c,
// window_frame.c and window_close.c, or window.c on newer runtimes, share; blit.c's copy is BcWin) and, on the GPU lane, the device heap and the
// twin's chunk states (gpu_vram, gpu_twin, gpu_state, io_gpu): a package effect that leans on
// those internals. The twin path compiles only where the runtime has the twin heap (GPU_DIRTY
// defined: the CUDA-over-HIP tree); a CUDA runtime without it reads e.mem, as upstream's
// window_fill does. Off Linux (the Mac's Objective-C build, or no X11) this file is a stub and
// Blit.ok (blit_ok.c) answers 0, so play.bend shows frames with Window.frame instead.
//
// PLAY_NOPACE=1 skips the pace. PLAY_SHOT=path writes the window's last frame (P6) at exit. PLAY_HW=1 prints at exit the same "HW" lines as
// tools/hw.c (fill, frame interval, and on a display present / busy / missed, and the put), for
// tools/pp.py. A window without a display (tools/hw_patch.py's offscreen window_open) skips the
// pump, the pace and the blit.
#if defined(__linux__) && !defined(__OBJC__)   // X11, as window_open.c (the Mac build is Objective-C)

// BcWin mirrors the leading fields of the runtime's BendWin (newer runtimes append fields such as
// grab), so blit.c reads the same block without redefining the runtime's type.
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

typedef struct {
  Display* dpy;
  Window   win;
  Atom     del;
  XImage*  img;
  u32      n;
  u32      cap;
  u32*     evs;
} BcWin;

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <string.h>

// Events (as window_frame.c)
// ------

static Term bc_node(Env e, const u32* ev) {
  static const u32 cids[3] = { CID(Key), CID(Mouse), CID(Move) };
  if (ev[0] == 3) {
    return term_pak(CID(Close), 0);
  }
  u32 n = ev[0] == 1 ? 4 : 2;
  u64 l = heap_alloc(e, cls_fit(n));
  for (u32 j = 0; j < n; j += 1) {
    e.mem[l + j] = ev[1 + j];
  }
  return term_ctr(cids[ev[0]], l);
}

static Term bc_list(Env e, const u32* p, u64 n) {
  Term list = term_pak(CID(Nil), 0);
  for (u64 i = n; i > 0;) {
    i -= 1;
    u64 l = heap_alloc(e, 1);
    e.mem[l]     = io_seal(e, bc_node(e, p + 5 * i), CID(Con));
    e.mem[l + 1] = io_seal(e, list, CID(Con));
    list = term_ctr(CID(Con), l);
  }
  return list;
}

static const u32 bc_keys[][2] = {
  { XK_Escape,    27 },    { XK_Return,    13 },    { XK_KP_Enter,  13 },
  { XK_Tab,       9 },     { XK_BackSpace, 127 },   { XK_Up,        63232 },
  { XK_Down,      63233 }, { XK_Left,      63234 }, { XK_Right,     63235 },
  { XK_Insert,    63271 }, { XK_Delete,    63272 }, { XK_Home,      63273 },
  { XK_End,       63275 }, { XK_Page_Up,   63276 }, { XK_Page_Down, 63277 },
  { XK_Super_R,   65590 }, { XK_Super_L,   65591 }, { XK_Shift_L,   65592 },
  { XK_Caps_Lock, 65593 }, { XK_Alt_L,     65594 }, { XK_Control_L, 65595 },
  { XK_Shift_R,   65596 }, { XK_Alt_R,     65597 }, { XK_Control_R, 65598 },
};

static u32 bc_key(XKeyEvent* ev) {
  char   c[8];
  KeySym ks = 0;
  ev->state &= ShiftMask | LockMask;
  int n = XLookupString(ev, c, sizeof c, &ks, NULL);
  for (u32 i = 0; i < sizeof bc_keys / sizeof *bc_keys; i += 1) {
    if (bc_keys[i][0] == ks) {
      return bc_keys[i][1];
    }
  }
  if (ks >= XK_F1 && ks <= XK_F12) {
    return 63236 + (u32)(ks - XK_F1);
  }
  if (n == 1 && (u8)c[0] >= 32) {
    return (u8)c[0] >= 'A' && (u8)c[0] <= 'Z' ? (u8)c[0] + 32 : (u8)c[0];
  }
  return 65536 + ev->keycode;
}

static void bc_push(BcWin* win, u32 kind, u32 a, u32 b, u32 c, u32 d) {
  if (win->n == win->cap) {
    win->cap = win->cap == 0 ? 64 : win->cap * 2;
    win->evs = io_mem(realloc(win->evs, win->cap * 20));
  }
  u32 ev[5] = { kind, a, b, c, d };
  memcpy(win->evs + win->n * 5, ev, sizeof ev);
  win->n += 1;
}

static u32 bc_clip(int v, u32 most) {
  return v < 0 ? 0 : (u32)v < most ? (u32)v : most - 1;
}

static void bc_shm_ev(XEvent* ev);

// Mouse look (PLAY_GRAB=0 turns it off): a click in the window holds the pointer (hidden, kept in
// the window, put back at the centre after each pump) and Esc or a lost focus lets it go; the
// click and the Esc are not passed on. The positions the game sees are virtual in both states:
// each motion adds its move to (bc_mx, bc_my). The game turns by the move since the last tick, so
// the warp back to the centre, the grab and the release make no jump, and the look doesn't stop
// at the window's edge.
static int    bc_grab_ok = -1;
static int    bc_grab, bc_seen, bc_lx, bc_ly;
static u32    bc_mx = 1u << 30, bc_my = 1u << 30;
static Cursor bc_blank = None;

static void bc_grab_on(BcWin* win) {
  if (bc_blank == None) {
    char   z = 0;
    Pixmap pm = XCreateBitmapFromData(win->dpy, win->win, &z, 1, 1);
    XColor c = { 0 };
    bc_blank = XCreatePixmapCursor(win->dpy, pm, pm, &c, &c, 0, 0);
    XFreePixmap(win->dpy, pm);
  }
  if (XGrabPointer(win->dpy, win->win, True, ButtonPressMask | ButtonReleaseMask
      | PointerMotionMask, GrabModeAsync, GrabModeAsync, win->win, bc_blank, CurrentTime)
      == GrabSuccess) {
    bc_grab = 1;
  }
}

static void bc_grab_off(BcWin* win) {
  if (bc_grab) {
    XUngrabPointer(win->dpy, CurrentTime);
    bc_grab = 0;
  }
}

static void bc_pump(BcWin* win) {
  u32 w = win->img->width;
  u32 h = win->img->height;
  if (bc_grab_ok < 0) {
    const char* v = getenv("PLAY_GRAB");
    bc_grab_ok = !(v != NULL && v[0] == '0');
    XWindowAttributes a;
    XGetWindowAttributes(win->dpy, win->win, &a);
    XSelectInput(win->dpy, win->win, a.your_event_mask | EnterWindowMask | FocusChangeMask);
  }
  int moved = 0;
  while (XPending(win->dpy) > 0) {
    XEvent ev;
    XNextEvent(win->dpy, &ev);
    if (ev.type == KeyPress || ev.type == KeyRelease) {
      u32 k = bc_key(&ev.xkey);
      if (k == 27 && bc_grab && ev.type == KeyPress) {
        bc_grab_off(win);
      } else {
        bc_push(win, 0, k, ev.type == KeyPress, 0, 0);
      }
    } else if (ev.type == ButtonPress || ev.type == ButtonRelease) {
      u32 b = ev.xbutton.button;
      if (b >= 1 && b <= 3) {
        if (bc_grab_ok && !bc_grab && ev.type == ButtonPress) {
          bc_grab_on(win);
        } else {
          bc_push(win, 1, bc_mx, bc_my, b == 1 ? 0 : 4 - b, ev.type == ButtonPress);
        }
      }
    } else if (ev.type == MotionNotify) {
      int x = ev.xmotion.x, y = ev.xmotion.y;
      if (bc_seen) {
        bc_mx += (u32)(x - bc_lx);
        bc_my += (u32)(y - bc_ly);
        moved = 1;
      }
      bc_lx = x;
      bc_ly = y;
      bc_seen = 1;
    } else if (ev.type == EnterNotify) {
      bc_lx = ev.xcrossing.x;   // back in the window, maybe far from where it left: no move
      bc_ly = ev.xcrossing.y;
      bc_seen = 1;
    } else if (ev.type == FocusOut) {
      bc_grab_off(win);
    } else if (ev.type == ClientMessage && (Atom)ev.xclient.data.l[0] == win->del) {
      bc_push(win, 3, 0, 0, 0, 0);
    } else {
      bc_shm_ev(&ev);
    }
  }
  if (moved) {
    bc_push(win, 2, bc_mx, bc_my, 0, 0);
  }
  int cx = (int)(w / 2), cy = (int)(h / 2);
  if (bc_grab && (bc_lx != cx || bc_ly != cy)) {
    XWarpPointer(win->dpy, None, win->win, 0, 0, 0, 0, cx, cy);
    bc_lx = cx;
    bc_ly = cy;
  }
}

// Timing (PLAY_HW=1)
// ------

#define BC_MAX 100000
static u64 bc_fill_ns[BC_MAX], bc_frame_ns[BC_MAX], bc_pres_ns[BC_MAX], bc_busy_ns[BC_MAX], bc_put_ns[BC_MAX], bc_pump_ns[BC_MAX];
static u32 bc_nput, bc_nf, bc_nt, bc_np, bc_w, bc_h, bc_miss;
static u64 bc_last, bc_wake, bc_call;
static int bc_hw = -1;

static int bc_env(const char* k) {
  const char* v = getenv(k);
  return v != NULL && v[0] == '1';
}

static int bc_cmp(const void* a, const void* b) {
  u64 x = *(const u64*)a, y = *(const u64*)b;
  return x < y ? -1 : x > y;
}

static double bc_q(const u64* v, u32 n, u32 skip, double q) {
  if (n <= skip) return -1;
  u32 m = n - skip;
  u64* c = malloc(m * 8);
  memcpy(c, v + skip, m * 8);
  qsort(c, m, 8, bc_cmp);
  u32 i = (u32)(q * (m - 1) + 0.5);
  double r = c[i];
  free(c);
  return r / 1e6;
}

static void bc_report(void) {
  u32 s = bc_nf > 10 ? 3 : 0;
  fprintf(stderr, "HW frames=%u size=%ux%u fill_ms med %.3f p95 %.3f p99 %.3f | frame_ms med %.3f p95 %.3f p99 %.3f\n",
    bc_nf, bc_w, bc_h, bc_q(bc_fill_ns, bc_nf, s, 0.5), bc_q(bc_fill_ns, bc_nf, s, 0.95),
    bc_q(bc_fill_ns, bc_nf, s, 0.99), bc_q(bc_frame_ns, bc_nt, s, 0.5),
    bc_q(bc_frame_ns, bc_nt, s, 0.95), bc_q(bc_frame_ns, bc_nt, s, 0.99));
  if (bc_np > 0) {
    fprintf(stderr, "HW present_ms med %.3f p95 %.3f p99 %.3f max %.3f | busy_ms med %.3f p95 %.3f p99 %.3f | missed %u of %u\n",
      bc_q(bc_pres_ns, bc_np, s, 0.5), bc_q(bc_pres_ns, bc_np, s, 0.95), bc_q(bc_pres_ns, bc_np, s, 0.99),
      bc_q(bc_pres_ns, bc_np, s, 1.0), bc_q(bc_busy_ns, bc_np, s, 0.5), bc_q(bc_busy_ns, bc_np, s, 0.95),
      bc_q(bc_busy_ns, bc_np, s, 0.99), bc_miss, bc_np > s ? bc_np - s : 0);
    fprintf(stderr, "HW put_ms med %.3f p95 %.3f p99 %.3f | pump_ms med %.3f p95 %.3f p99 %.3f\n",
      bc_q(bc_put_ns, bc_nput, s, 0.5), bc_q(bc_put_ns, bc_nput, s, 0.95), bc_q(bc_put_ns, bc_nput, s, 0.99),
      bc_q(bc_pump_ns, bc_nf, s, 0.5), bc_q(bc_pump_ns, bc_nf, s, 0.95), bc_q(bc_pump_ns, bc_nf, s, 0.99));
  }
  fflush(stderr);
}

// The frame
// ---------

// The samples into pix (w x h pixels): sample (x >> u, y >> u) at each pixel.
static void bc_scale_rows(u32* pix, u32 w, u32 y0, u32 h, const u32* src, u32 ws, u32 u) {
  if (u == 0) {
    for (u32 y = y0; y < h; y += 1) {
      memcpy(pix + (u64)y * w, src + (u64)y * ws, (size_t)w * 4);
    }
    return;
  }
  // Each sample row is widened once, then its copies are memcpys of the widened row.
  for (u32 y = y0; y < h; y += 1u << u) {
    const u32* row = src + (u64)(y >> u) * ws;
    u32*       out = pix + (u64)y * w;
    if (u == 1) {
      u64* o2 = (u64*)out;
      for (u32 x = 0; x < w / 2; x += 1) {
        o2[x] = (u64)row[x] * 0x100000001ull;
      }
      if (w & 1) {
        out[w - 1] = row[(w - 1) >> 1];
      }
    } else {
      for (u32 x = 0; x < w; x += 1) {
        out[x] = row[x >> u];
      }
    }
    for (u32 k = 1; k < (1u << u) && y + k < h; k += 1) {
      memcpy(out + (u64)k * w, out, (size_t)w * 4);
    }
  }
}

// The upscale in bands of rows on a few threads (PLAY_BLIT_T, default 4) when the window is
// large: at 3840x2160 it writes 33 MB a frame, more than one core's store bandwidth in 2 ms.
typedef struct {
  u32* pix; u32 w; u32 y0; u32 y1; const u32* src; u32 ws; u32 u;
} BcBand;

static void* bc_band(void* a) {
  BcBand* b = (BcBand*)a;
  bc_scale_rows(b->pix, b->w, b->y0, b->y1, b->src, b->ws, b->u);
  return NULL;
}

static void bc_scale(u32* pix, u32 w, u32 h, const u32* src, u32 ws, u32 u) {
  static int nt = -1;
  if (nt < 0) {
    const char* v = getenv("PLAY_BLIT_T");
    nt = v != NULL ? atoi(v) : 4;
    nt = nt < 1 ? 1 : nt > 16 ? 16 : nt;
  }
  u32 t = (u64)w * h >= 2000000 ? (u32)nt : 1;
  if (t == 1) {
    bc_scale_rows(pix, w, 0, h, src, ws, u);
    return;
  }
  u32 step = 1u << u;
  u32 band = ((h + t - 1) / t + step - 1) / step * step;   // whole sample rows per band
  BcBand    b[16];
  pthread_t th[16];
  bool      ok[16];
  for (u32 i = 0; i < t; i += 1) {
    u32 y0 = i * band;
    u32 y1 = y0 + band < h ? y0 + band : h;
    b[i] = (BcBand){ pix, w, y0 < h ? y0 : h, y1, src, ws, u };
    ok[i] = i > 0 && pthread_create(&th[i], NULL, bc_band, &b[i]) == 0;
    if (i > 0 && !ok[i]) {
      bc_band(&b[i]);
    }
  }
  bc_band(&b[0]);
  for (u32 i = 1; i < t; i += 1) {
    if (ok[i]) {
      pthread_join(th[i], NULL);
    }
  }
}

#if BEND_CUDA && defined(GPU_DIRTY)   // the twin heap (the HIP lane's runtime, #1078)
// Whether the host wrote any of the corpus bytes [lo, hi) since the device last had them (a
// twin chunk in GPU_DIRTY): then they go up first (gpu_sync, as window_fill always does, 0.6 ms
// a frame at 720p). The frame the bang just wrote is on the device and its chunks are not dirty,
// so the copy down reads it as it is.
static bool bc_dirty(u64 lo, u64 hi) {
  if (gpu_state == NULL || lo < gpu_lo || hi > gpu_hi) {
    return true;
  }
  for (u64 c = (lo - gpu_lo) / GPU_CHUNK; c <= (hi - 1 - gpu_lo) / GPU_CHUNK; c += 1) {
    if (gpu_state[c] == GPU_DIRTY) {
      return true;
    }
  }
  return false;
}
#endif

#if BEND_CUDA && defined(GPU_DIRTY)   // the twin heap (the HIP lane's runtime, #1078)
// Page-locks a host buffer the device copies into (the shared-memory image, or the upscale's
// staging buffer), so cuMemcpyDtoH writes it directly rather than through a pageable bounce.
// Only buffers blit.c owns and never frees; a refusal (or PLAY_PIN=0) leaves it pageable.
static bool bc_pin(void* p, size_t n) {
  static void* done[4];
  static int   nd = -1;
  if (nd < 0) {
    const char* v = getenv("PLAY_PIN");
    nd = v != NULL && v[0] == '0' ? 4 : 0;
  }
  for (int i = 0; i < 4; i += 1) {
    if (done[i] == p) {
      return true;
    }
  }
  if (nd >= 4 || cuMemHostRegister(p, n, 0) != CUDA_SUCCESS) {
    return false;
  }
  done[nd++] = p;
  return true;
}
#endif

static void bc_fill(Env e, u32* pix, u32 w, u32 h, Term fb, u32 ws, u32 hs, u32 u, bool own) {
  u64 loc = blk_loc(e.mem, fb);
#if BEND_CUDA && defined(GPU_DIRTY)   // the twin heap (the HIP lane's runtime, #1078)
  if (io_gpu && gpu_twin) {
    if (bc_dirty(loc * 8, loc * 8 + (u64)ws * hs * 4)) {
      gpu_sync(true);
    }
    CUdeviceptr src = (CUdeviceptr)(gpu_vram + loc);
    if (u == 0 && ws == w) {
      if (own) {
        bc_pin(pix, (size_t)w * h * 4);
      }
      if (cuMemcpyDtoH(pix, src, (size_t)w * h * 4) != CUDA_SUCCESS) {
        err_fail("Blit.frame: the device copy failed");
      }
      return;
    }
    static u32* tmp;
    static u64  cap;
    u64 n = (u64)ws * hs;
    if (n > cap) {   // grows once in practice: the size is the window's; the old one stays pinned
      tmp = io_mem(aligned_alloc(4096, (n * 4 + 4095) / 4096 * 4096));
      cap = n;
      bc_pin(tmp, (n * 4 + 4095) / 4096 * 4096);
    }
    if (cuMemcpyDtoH(tmp, src, n * 4) != CUDA_SUCCESS) {
      err_fail("Blit.frame: the device copy failed");
    }
    bc_scale(pix, w, h, tmp, ws, u);
    return;
  }
#endif
  bc_scale(pix, w, h, (const u32*)(e.mem + loc), ws, u);
}

// PLAY_SHOT=path: the window's last frame (its pixels, not the samples) as a P6 at exit. A copy:
// Window.close frees the window's pixels before exit.
static u32* bc_shot;
static u32  bc_sw, bc_sh;
static bool bc_shot_on;

static void bc_shot_write(void) {
  const char* path = getenv("PLAY_SHOT");
  FILE* fp = path != NULL && bc_shot != NULL ? fopen(path, "wb") : NULL;
  if (fp == NULL) {
    return;
  }
  fprintf(fp, "P6\n%u %u\n255\n", bc_sw, bc_sh);
  for (u64 i = 0; i < (u64)bc_sw * bc_sh; i += 1) {
    u8 px[3] = { (u8)(bc_shot[i] >> 16), (u8)(bc_shot[i] >> 8), (u8)bc_shot[i] };
    fwrite(px, 1, 3, fp);
  }
  fclose(fp);
}

// PLAY_SHOT_SERVER=path (a check, slow): the window's pixels read back from the server after
// each frame, the last written as a P6 at exit, to compare with PLAY_SHOT's.
static u32* bc_srv;
static bool bc_srv_on;

static void bc_srv_write(void) {
  const char* path = getenv("PLAY_SHOT_SERVER");
  FILE* fp = path != NULL && bc_srv != NULL ? fopen(path, "wb") : NULL;
  if (fp == NULL) {
    return;
  }
  fprintf(fp, "P6\n%u %u\n255\n", bc_sw, bc_sh);
  for (u64 i = 0; i < (u64)bc_sw * bc_sh; i += 1) {
    u8 px[3] = { (u8)(bc_srv[i] >> 16), (u8)(bc_srv[i] >> 8), (u8)bc_srv[i] };
    fwrite(px, 1, 3, fp);
  }
  fclose(fp);
}

// The next 60 Hz tick (as window_frame.c's pace).
static void bc_pace(void) {
  static u64 due;
  u64 now = io_tick();
  if (due > now) {
    struct timespec ts = { 0, (long)(due - now) };
    nanosleep(&ts, NULL);
  }
  due = (due > now ? due : now) + 16666667;
}


// MIT-SHM: the window's pixels in shared-memory XImages, so XShmPutImage hands the server a
// segment it reads in place, not the 4 bytes a pixel XPutImage writes down the socket (4.7 ms a
// frame at 2560x1440 on WSLg). libXext is opened at run time (the game links only libX11); a
// display without the extension, a remote one, or PLAY_SHM=0 keeps XPutImage. The put is
// asynchronous, so there are two images: a frame fills the one the server has finished reading
// (its ShmCompletion event came back), and waits for that event only when the server is still on
// it (PLAY_SHM=1: one image, and an XSync before each fill).
typedef struct {
  unsigned long shmseg;
  int           shmid;
  char*         shmaddr;
  Bool          readOnly;
} BcShmSeg;

typedef struct {          // XShmCompletionEvent
  int           type;
  unsigned long serial;
  Bool          send_event;
  Display*      display;
  Drawable      drawable;
  int           major_code;
  int           minor_code;
  unsigned long shmseg;
  unsigned long offset;
} BcShmDone;

static int      bc_shm = -1;     // -1 untried, 0 off, 1 on
static int      bc_nimg;         // shared images: 1 or 2
static XImage*  bc_simg[2];
static BcShmSeg bc_seg[2];
static bool     bc_inuse[2];     // a put the server has not finished reading
static u32      bc_cur;          // the image this frame fills
static int      bc_evdone = -1;  // the ShmCompletion event type
static Bool     (*bc_xq)(Display*);
static int      (*bc_xev)(Display*);
static XImage*  (*bc_xci)(Display*, Visual*, unsigned int, int, char*, BcShmSeg*, unsigned int, unsigned int);
static Bool     (*bc_xat)(Display*, BcShmSeg*);
static Bool     (*bc_xput)(Display*, Drawable, GC, XImage*, int, int, int, int, unsigned int, unsigned int, Bool);
static int      bc_xerr;

static void bc_shm_ev(XEvent* ev) {
  if (ev->type == bc_evdone) {
    BcShmDone* d = (BcShmDone*)ev;
    for (int i = 0; i < bc_nimg; i += 1) {
      if (bc_seg[i].shmseg == d->shmseg) {
        bc_inuse[i] = false;
      }
    }
  }
}

static Bool bc_is_done(Display* d, XEvent* ev, XPointer arg) {
  return ev->type == bc_evdone;
}

static int bc_xerr_h(Display* d, XErrorEvent* ev) {
  bc_xerr = 1;
  return 0;
}

static XImage* bc_shm_img(BcWin* win, BcShmSeg* seg, u32 iw, u32 ih) {
  Display* d = win->dpy;
  int scr = DefaultScreen(d);
  XImage* src = win->img;
  XImage* im = bc_xci(d, DefaultVisual(d, scr), DefaultDepth(d, scr), ZPixmap, NULL, seg, iw, ih);
  if (im == NULL) {
    return NULL;
  }
  if (im->bits_per_pixel != 32 || im->byte_order != src->byte_order
      || im->bytes_per_line != (int)iw * 4 || im->red_mask != src->red_mask
      || im->green_mask != src->green_mask || im->blue_mask != src->blue_mask) {
    XDestroyImage(im);
    return NULL;
  }
  seg->shmid = shmget(IPC_PRIVATE, (size_t)im->bytes_per_line * im->height, IPC_CREAT | 0600);
  if (seg->shmid < 0) {
    XDestroyImage(im);
    return NULL;
  }
  seg->shmaddr = im->data = shmat(seg->shmid, NULL, 0);
  seg->readOnly = False;
  if (seg->shmaddr == (char*)-1) {
    shmctl(seg->shmid, IPC_RMID, NULL);
    im->data = NULL;
    XDestroyImage(im);
    return NULL;
  }
  XSync(d, False);
  int (*old)(Display*, XErrorEvent*) = XSetErrorHandler(bc_xerr_h);
  bc_xerr = 0;
  Bool ok = bc_xat(d, seg);
  XSync(d, False);
  XSetErrorHandler(old);
  shmctl(seg->shmid, IPC_RMID, NULL);   // freed once both sides detach (at exit at the latest)
  if (!ok || bc_xerr) {
    shmdt(seg->shmaddr);
    im->data = NULL;
    XDestroyImage(im);
    return NULL;
  }
  return im;
}

static void bc_shm_init(BcWin* win, u32 iw, u32 ih) {
  bc_shm = 0;
  const char* v = getenv("PLAY_SHM");
  if (v != NULL && v[0] == '0') {
    return;
  }
  void* lib = dlopen("libXext.so.6", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    return;
  }
  bc_xq   = (Bool (*)(Display*))dlsym(lib, "XShmQueryExtension");
  bc_xev  = (int (*)(Display*))dlsym(lib, "XShmGetEventBase");
  bc_xci  = (XImage* (*)(Display*, Visual*, unsigned int, int, char*, BcShmSeg*, unsigned int, unsigned int))
    dlsym(lib, "XShmCreateImage");
  bc_xat  = (Bool (*)(Display*, BcShmSeg*))dlsym(lib, "XShmAttach");
  bc_xput = (Bool (*)(Display*, Drawable, GC, XImage*, int, int, int, int, unsigned int, unsigned int, Bool))
    dlsym(lib, "XShmPutImage");
  if (!bc_xq || !bc_xev || !bc_xci || !bc_xat || !bc_xput || !bc_xq(win->dpy)) {
    return;
  }
  bc_simg[0] = bc_shm_img(win, &bc_seg[0], iw, ih);
  if (bc_simg[0] == NULL) {
    return;
  }
  bc_nimg = 1;
  if (!(v != NULL && v[0] == '1')) {
    bc_simg[1] = bc_shm_img(win, &bc_seg[1], iw, ih);
    bc_nimg = bc_simg[1] != NULL ? 2 : 1;
  }
  bc_evdone = bc_xev(win->dpy);   // + ShmCompletion (0)
  bc_shm = 1;
}

// XRender: with an upscale (u > 0) the server scales, not the host. The
// shared images hold the samples (ws x hs, a straight copy down); the put
// goes to a pixmap of that size, and a composite with a 1 / 2^u transform
// and the nearest filter draws it over the window: the same pixels as the
// host's upscale (a window pixel (x, y) samples (x >> u, y >> u)), without
// the host writing 4^u times the samples (33 MB a frame at 4K up4).
// libXrender is opened at run time; without it, or with PLAY_XR=0, the host
// upscales.
typedef struct {
  int matrix[3][3];     // XFixed, 16.16
} BcXform;

static int           bc_xr = -1;   // -1 untried, 0 off, 1 on
static Pixmap        bc_xpix;
static GC            bc_xgc;
static unsigned long bc_xsrc, bc_xdst;
static void*         (*bc_rfv)(Display*, Visual*);
static unsigned long (*bc_rcp)(Display*, Drawable, void*, unsigned long, void*);
static void          (*bc_rst)(Display*, unsigned long, BcXform*);
static void          (*bc_rsf)(Display*, unsigned long, const char*, int*, int);
static void          (*bc_rco)(Display*, int, unsigned long, unsigned long, unsigned long, int, int,
  int, int, int, int, unsigned int, unsigned int);

static void bc_xr_init(BcWin* win, u32 ws, u32 hs, u32 u) {
  bc_xr = 0;
  const char* v = getenv("PLAY_XR");
  if (u == 0 || u > 8 || (v != NULL && v[0] == '0')) {
    return;
  }
  void* lib = dlopen("libXrender.so.1", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    return;
  }
  bc_rfv = (void* (*)(Display*, Visual*))dlsym(lib, "XRenderFindVisualFormat");
  bc_rcp = (unsigned long (*)(Display*, Drawable, void*, unsigned long, void*))dlsym(lib, "XRenderCreatePicture");
  bc_rst = (void (*)(Display*, unsigned long, BcXform*))dlsym(lib, "XRenderSetPictureTransform");
  bc_rsf = (void (*)(Display*, unsigned long, const char*, int*, int))dlsym(lib, "XRenderSetPictureFilter");
  bc_rco = (void (*)(Display*, int, unsigned long, unsigned long, unsigned long, int, int, int, int, int,
    int, unsigned int, unsigned int))dlsym(lib, "XRenderComposite");
  if (!bc_rfv || !bc_rcp || !bc_rst || !bc_rsf || !bc_rco) {
    return;
  }
  Display* d = win->dpy;
  int scr = DefaultScreen(d);
  void* fmt = bc_rfv(d, DefaultVisual(d, scr));
  if (fmt == NULL) {
    return;
  }
  XSync(d, False);
  int (*old)(Display*, XErrorEvent*) = XSetErrorHandler(bc_xerr_h);
  bc_xerr = 0;
  bc_xpix = XCreatePixmap(d, win->win, ws, hs, DefaultDepth(d, scr));
  bc_xgc  = XCreateGC(d, bc_xpix, 0, NULL);
  bc_xsrc = bc_rcp(d, bc_xpix, fmt, 0, NULL);
  bc_xdst = bc_rcp(d, win->win, fmt, 0, NULL);
  BcXform t = { { { 65536 >> u, 0, 0 }, { 0, 65536 >> u, 0 }, { 0, 0, 65536 } } };
  bc_rst(d, bc_xsrc, &t);
  bc_rsf(d, bc_xsrc, "nearest", NULL, 0);
  XSync(d, False);
  XSetErrorHandler(old);
  bc_xr = bc_xerr ? 0 : 1;
}

// Waits until the server has read the image this frame fills (the events that come meanwhile
// are queued for the pump as they are).
static void bc_shm_wait(BcWin* win) {
  if (bc_nimg == 1) {
    if (bc_inuse[0]) {
      XSync(win->dpy, False);
      bc_inuse[0] = false;
    }
    return;
  }
  while (bc_inuse[bc_cur]) {
    XEvent ev;
    XIfEvent(win->dpy, &ev, bc_is_done, NULL);
    bc_shm_ev(&ev);
  }
}

static Term bc_frame(Env e, BcWin* win, Term fb, u32 ws, u32 hs, u32 u) {
  if (bc_hw < 0) {
    bc_hw = bc_env("PLAY_HW");
    if (bc_hw) {
      atexit(bc_report);
    }
    bc_srv_on = getenv("PLAY_SHOT_SERVER") != NULL;
    if (bc_srv_on) {
      atexit(bc_srv_write);
    }
    bc_shot_on = getenv("PLAY_SHOT") != NULL || bc_srv_on;
    if (bc_shot_on) {
      atexit(bc_shot_write);
    }
  }
  io_sync();
  u64 t0 = io_tick();
  if (bc_hw && bc_last != 0 && bc_nt < BC_MAX) {
    bc_frame_ns[bc_nt++] = t0 - bc_last;
  }
  bc_last = t0;
  if (win->dpy != NULL) {
    if (bc_shm < 0) {
      bc_shm_init(win, ws, hs);   // first at the samples' size, for the server's upscale
      if (bc_shm == 1) {
        bc_xr_init(win, ws, hs, u);
      }
      if (bc_shm == 1 && bc_xr != 1) {   // the host upscales: images of the window's size
        bc_shm_init(win, win->img->width, win->img->height);
      }
    }
    bc_pump(win);
    if (bc_shm == 1) {
      bc_shm_wait(win);
    }
  }
  u64 t1 = io_tick();
  u32 w = win->img->width;
  u32 h = win->img->height;
  bool xr = bc_xr == 1 && bc_shm == 1;
  u32 iw = xr ? ws : w;
  u32 ih = xr ? hs : h;
  XImage* img = bc_shm == 1 && bc_simg[bc_cur]->width == (int)iw && bc_simg[bc_cur]->height == (int)ih
    ? bc_simg[bc_cur] : win->img;
  if (img == win->img) {
    xr = false;
    iw = w;
    ih = h;
  }
  bc_fill(e, (u32*)img->data, iw, ih, fb, ws, hs, xr ? 0 : u, img != win->img);
  if (bc_hw) {
    bc_w = w;
    bc_h = h;
    if (bc_nf < BC_MAX) {
      bc_fill_ns[bc_nf] = io_tick() - t1;   // the copy (and upscale) only
      bc_pump_ns[bc_nf] = t1 - t0;          // the wait for the last put, and the events
    }
    bc_nf += 1;
  }
  if (win->dpy != NULL) {
    u64 call = io_tick();
    if (!bc_env("PLAY_NOPACE")) {
      bc_pace();
    }
    u64 wake = io_tick();
    if (bc_hw && bc_wake != 0 && bc_np < BC_MAX) {
      bc_pres_ns[bc_np] = wake - bc_wake;
      bc_busy_ns[bc_np] = call - bc_wake;
      bc_miss += wake - bc_wake > 25000000;
      bc_np += 1;
    }
    bc_wake = wake;
    GC gc = DefaultGC(win->dpy, DefaultScreen(win->dpy));
    if (xr) {
      bc_xput(win->dpy, bc_xpix, bc_xgc, img, 0, 0, 0, 0, iw, ih, bc_nimg == 2);
      bc_rco(win->dpy, 1, bc_xsrc, 0, bc_xdst, 0, 0, 0, 0, 0, 0, w, h);   // PictOpSrc
      bc_inuse[bc_cur] = true;
      bc_cur = (bc_cur + 1) % bc_nimg;
    } else if (img != win->img) {
      bc_xput(win->dpy, win->win, gc, img, 0, 0, 0, 0, w, h, bc_nimg == 2);
      bc_inuse[bc_cur] = true;
      bc_cur = (bc_cur + 1) % bc_nimg;
    } else {
      XPutImage(win->dpy, win->win, gc, img, 0, 0, 0, 0, w, h);
    }
    XFlush(win->dpy);
    if (bc_hw && bc_nput < BC_MAX) {
      bc_put_ns[bc_nput++] = io_tick() - wake;
    }
  }
  if (bc_shot_on) {
    if (bc_shot == NULL || bc_sw != w || bc_sh != h) {
      free(bc_shot);
      bc_shot = malloc((u64)w * h * 4);
    }
    if (xr) {
      bc_scale_rows(bc_shot, w, 0, h, (const u32*)img->data, ws, u);
    } else {
      memcpy(bc_shot, img->data, (u64)w * h * 4);
    }
    bc_sw = w;
    bc_sh = h;
  }
  if (bc_srv_on && win->dpy != NULL) {   // PLAY_SHOT_SERVER: the server's pixels of the window
    XImage* g = XGetImage(win->dpy, win->win, 0, 0, w, h, AllPlanes, ZPixmap);
    if (g != NULL) {
      if (bc_srv == NULL) {
        bc_srv = malloc((u64)w * h * 4);
      }
      for (u32 y = 0; y < h; y += 1) {
        for (u32 x = 0; x < w; x += 1) {
          bc_srv[(u64)y * w + x] = (u32)XGetPixel(g, x, y) & 0xffffff;
        }
      }
      XDestroyImage(g);
    }
  }
  Term list = bc_list(e, win->evs, win->n);
  win->n = 0;
  return list;
}

Term blit_frame_run(Env e, Term* f, IoWork* w) {
  Term events = bc_frame(e, (BcWin*)(intptr_t)io_hand_v(f[0]), f[1], (u32)f[2], (u32)f[3],
    (u32)f[4]);
  return io_tup(e, f[0], io_tup(e, f[1], events));
}

#else

Term blit_frame_run(Env e, Term* f, IoWork* w) {
  return io_tup(e, f[0], io_tup(e, f[1], term_pak(CID(Nil), 0)));
}

#endif

static void __attribute__((constructor)) blit_frame_use(void) {
  io_eff(CID(Blit.frame), blit_frame_run, 0);
}
