// Lane.gpu on the JS lane: no GPU.
function lane_gpu() {
  return 0;
}
io_eff(CID(Lane.gpu), lane_gpu);
