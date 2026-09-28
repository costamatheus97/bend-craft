# hw_patch.py OUT.c: splice tools/hw.c into a bend-craft program's emitted C (test-only; the Bend
# trees are never touched). The Linux window arm then times window_fill and the frame interval,
# runs offscreen when XOpenDisplay fails, and skips the pace with HW_NOPACE=1.
import sys, os
p = sys.argv[1]
c = open(p).read()
hw = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hw.c')).read()

def rep(s, a, b):
    n = s.count(a)
    assert n == 1, (a[:70], n)
    return s.replace(a, b)

END = '// A frame waits for the next 60 Hz tick'
c = rep(c, END, hw + END)
c = rep(c, '''  window_fill(e, (u32*)win->img->data, w, h, image, k);
  window_pace();''', '''  hw_fill(e, (u32*)win->img->data, w, h, image, k);
  if (win->dpy == NULL) {
    return;
  }
  hw_pace_begin();
  if (!hw_nopace()) {
    window_pace();
  }
  hw_present();''')
c = rep(c, '''  BendWin* win = (BendWin*)at;
  io_sync();
  window_pump(win);''', '''  BendWin* win = (BendWin*)at;
  io_sync();
  hw_entry();
  if (win->dpy != NULL) {
    window_pump(win);
  }''')
c = rep(c, '''  if (w < 1 || h < 1 || w > 16384 || h > 16384) {
    return EINVAL;
  }
  Display* dpy = XOpenDisplay(NULL);''', '''  if (w < 1 || h < 1 || w > 16384 || h > 16384) {
    return EINVAL;
  }
  Display* dpy = XOpenDisplay(NULL);
  if (dpy == NULL) {
    BendWin* win = io_mem(calloc(1, sizeof *win));
    win->img = io_mem(calloc(1, sizeof *win->img));
    win->img->width = w;
    win->img->height = h;
    win->img->data = io_mem(calloc((size_t)w * h, 4));
    *out = (intptr_t)win;
    return 0;
  }''')
CL = '  XDestroyImage(win->img);\n  XCloseDisplay(win->dpy);'
c = rep(c, CL, '  void hw_report(void);\n  hw_report();\n  if (win->dpy != NULL) {\n  '
        + CL.replace('\n', '\n  ') + '\n  }')
ST = '  XStoreName(win->dpy, win->win, text);'
if ST in c:
    c = rep(c, ST, '  if (win->dpy != NULL) {\n  ' + ST + '\n  }')
open(p, 'w').write(c)
print('hw_patch: patched', p)
