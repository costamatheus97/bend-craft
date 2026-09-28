// Monotonic microseconds (U32, wraps; differences are valid).
function clock_us() {
  return Math.floor(performance.now() * 1000) >>> 0;
}
io_eff(CID(Clock.us), clock_us);
