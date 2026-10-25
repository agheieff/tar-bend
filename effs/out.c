// Stdout
// ======

// Raw byte output on fd 1. Used for non-UTF-8 member names in `btar -t`, where
// going through Base's String path would replace invalid bytes (U+FFFD).
// Native only; out.js fails with ENOSYS so the JS lane cannot lose bytes.
Term stdout_write_run(Env e, Term* f, IoWork* w) {
  w->data = io_cbuf(e, f[0], &w->size, CID(Con));
  if (w->data == NULL) {
    return io_fail(e, EINVAL, NULL);
  }
  io_out(stdout, w->data, w->size);
  free(w->data);
  return io_done(e, term_pak(CID(Unit), 0));
}

static void __attribute__((constructor)) stdout_write_use(void) {
  io_eff(CID(Stdout.write), stdout_write_run);
}
