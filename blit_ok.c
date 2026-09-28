// Blit.ok: 1 where blit.c shows frames (Linux with X11, under the same guard as
// window_open.c), else 0, so play.bend falls back to Window.frame (mode 1) by default.
Term blit_ok_run(Env e, Term* f, IoWork* w) {
#if defined(__linux__) && !defined(__OBJC__)
  return (Term)1u;
#else
  return (Term)0u;
#endif
}

static void __attribute__((constructor)) blit_ok_use(void) {
  io_eff(CID(Blit.ok), blit_ok_run, 0);
}
