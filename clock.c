// Monotonic microseconds (U32, wraps after ~71 minutes; differences are valid).
Term clock_us_run(Env e, Term* f, IoWork* w) {
  return (Term)(uint32_t)(io_tick() / 1000ull);
}

static void __attribute__((constructor)) clock_us_use(void) {
  io_eff(CID(Clock.us), clock_us_run, 0);
}
