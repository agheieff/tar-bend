// M0 probe: Array<U32> in an effect. There is no runtime helper for Array in
// the effect API (io_list/io_cbuf are List-only), so this reads the block
// layout directly: TAG_BUF, 2^cls packed u32 slots, base = blk_loc(e.mem, a).
Term probe_sum_words_run(Env e, Term* f, IoWork* w) {
  (void)w;
  Term a = f[0];
  if (term_tag(a) != TAG_BUF) {
    return (Term)0xFFFFFFFFu; // fail loud: not a flat U32 block
  }
  u32 cls = blk_cls(a);
  u64 loc = blk_loc(e.mem, a);
  u32* p = (u32*)(e.mem + loc);
  u32 sum = 0;
  for (u64 i = 0; i < (1ull << cls); i += 1) {
    sum += p[i];
  }
  term_drop(e, a); // the effect owns the affine Array argument
  return (Term)sum;
}

static Term probe_make_words_run(Env e, Term* f, IoWork* w) {
  (void)w;
  u32 n = (u32)f[0];
  u32 cls = 0;
  while ((1u << cls) < n && cls < 30) {
    cls += 1;
  }
  u64 loc = heap_alloc(e, cls == 0 ? 0 : cls - 1);
  u32* p = (u32*)(e.mem + loc);
  for (u64 i = 0; i < (1ull << cls); i += 1) {
    p[i] = (u32)(i * 3);
  }
  return term_blk(false, cls, loc);
}

static void __attribute__((constructor)) probe_array_use(void) {
  io_eff(CID(Probe.sum_words), probe_sum_words_run);
  io_eff(CID(Probe.make_words), probe_make_words_run);
}
