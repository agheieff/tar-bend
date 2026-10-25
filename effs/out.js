// Stdout — raw bytes are native-only for now: fail loudly instead of corrupting
// non-UTF-8 names in the JS lane.
function stdout_write(data) {
  return io_fail(38); // ENOSYS
}

io_eff(CID(Stdout.write), stdout_write);
