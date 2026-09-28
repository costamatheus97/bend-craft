// Blit.ok on the JS lane: blit.c does not run here, so play.bend uses Window.frame.
function blit_ok() {
  return 0;
}
io_eff(CID(Blit.ok), blit_ok);
