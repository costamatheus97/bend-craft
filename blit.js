// Blit.frame on the JS lane: no window here, so no pixels and no events.
function blit_frame(window, fb, ws, hs, u) {
  return { $: CID(Tuple), fst: window,
    snd: { $: CID(Tuple), fst: fb, snd: { $: CID(Nil) } } };
}

io_eff(CID(Blit.frame), blit_frame);
