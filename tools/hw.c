// ---- HW: bend-craft's test-only window harness (spliced into emitted C by tools/hw_patch.py) ----
// Times window_fill and the interval between Window.frame calls; with no display (the shim env
// unsets DISPLAY) the window is an offscreen buffer and the pump, pace and XPutImage are skipped.
// HW_NOPACE=1 skips the 60 Hz pace on a real display too. At exit: medians, p95 and p99.
#include <stdio.h>
#include <string.h>
#define HW_MAX 100000
static u64 hw_fill_ns[HW_MAX], hw_frame_ns[HW_MAX];
static u32 hw_nf, hw_nt, hw_w, hw_h, hw_done;
static u64 hw_last;
static int hw_cmp(const void* a, const void* b) {
  u64 x = *(const u64*)a, y = *(const u64*)b;
  return x < y ? -1 : x > y;
}
static double hw_q(const u64* v, u32 n, u32 skip, double q) {
  if (n <= skip) return -1;
  u32 m = n - skip;
  u64* c = malloc(m * 8);
  memcpy(c, v + skip, m * 8);
  qsort(c, m, 8, hw_cmp);
  u32 i = (u32)(q * (m - 1) + 0.5);
  double r = c[i];
  free(c);
  return r / 1e6;
}
void hw_report(void) {
  if (hw_done) return;
  hw_done = 1;
  u32 s = hw_nf > 10 ? 3 : 0;
  fprintf(stderr, "HW frames=%u size=%ux%u fill_ms med %.3f p95 %.3f p99 %.3f | frame_ms med %.3f p95 %.3f p99 %.3f\n",
    hw_nf, hw_w, hw_h, hw_q(hw_fill_ns, hw_nf, s, 0.5), hw_q(hw_fill_ns, hw_nf, s, 0.95),
    hw_q(hw_fill_ns, hw_nf, s, 0.99), hw_q(hw_frame_ns, hw_nt, s, 0.5),
    hw_q(hw_frame_ns, hw_nt, s, 0.95), hw_q(hw_frame_ns, hw_nt, s, 0.99));
  fflush(stderr);
}
static void hw_fill(Env e, u32* pix, u32 w, u32 h, Term image, u32 k) {
  static int on;
  if (!on) { on = 1; atexit(hw_report); }
  hw_w = w; hw_h = h;
  u64 t0 = io_tick();
  window_fill(e, pix, w, h, image, k);
  u64 t1 = io_tick();
  if (hw_nf < HW_MAX) hw_fill_ns[hw_nf] = t1 - t0;
  hw_nf += 1;
}
static void hw_entry(void) {
  u64 now = io_tick();
  if (hw_last != 0 && hw_nt < HW_MAX) hw_frame_ns[hw_nt++] = now - hw_last;
  hw_last = now;
}
static int hw_nopace(void) {
  const char* p = getenv("HW_NOPACE");
  return p != NULL && p[0] == '1';
}
// ---- end HW ----
