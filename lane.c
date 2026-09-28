// Lane.gpu: 1 when this run's ! calls go to the GPU (--gpu), else 0. play.bend picks its fork
// depth by it: the GPU wants 2^14 leaves to fill its lanes, the CPU's pool fewer.
Term lane_gpu_run(Env e, Term* f, IoWork* w) {
  return (Term)(io_gpu ? 1u : 0u);
}

static void __attribute__((constructor)) lane_gpu_use(void) {
  io_eff(CID(Lane.gpu), lane_gpu_run, 0);
}
