// tar-bend effects: JS-lane twin of fs.c. Fast inner-loop tests run this lane
// (`bend prog.bend`); the native build is the release artifact. Linux only:
// dirfd-relative calls go through /proc/self/fd/<fd>/<name>. This lane cannot
// express openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS, and fchmod follows
// symlinks; M0 semantics are equivalent on trusted fixture trees only.
// (docs/effects.md)
//
// Byte helpers come from the JS runtime: io_unlist(List) -> Uint8Array|null,
// io_list(Uint8Array, n) -> List. io_fail(code) carries a host errno.

const fs_lane = require("fs");
const O = fs_lane.constants;

function fs_bytes(xs) {
  const b = io_unlist(xs);
  return b === null ? null : Buffer.from(b);
}

// One component, no '/', not "."/"..", or null. Same rule as fs.c.
function fs_component(b) {
  if (b === null || b.length === 0 || b.length > 255 || b.includes(0)) {
    return null;
  }
  if (b.includes(47) || b.equals(Buffer.from(".")) || b.equals(Buffer.from(".."))) {
    return null;
  }
  return b;
}

// Node has no *at(2); /proc/self/fd resolves the dirfd for this lane.
function fs_proc(fd, name) {
  return Buffer.concat([Buffer.from(`/proc/self/fd/${fd}/`), name]);
}

function fs_errno(e) {
  return Math.abs(e.errno ?? 5);
}

function fs_fail(e) {
  return io_fail(fs_errno(e));
}

function fs_catch(e, out) {
  return out ?? io_fail(fs_errno(e));
}

// Fs.open_dir(path) -> Result<..., File>.
function fs_open_dir(path) {
  const b = fs_bytes(path);
  if (b === null || b.length === 0 || b.includes(0)) {
    return io_fail(22);
  }
  try {
    return io_done(fs_lane.openSync(b,
      O.O_RDONLY | O.O_DIRECTORY | O.O_CLOEXEC));
  } catch (e) {
    return fs_fail(e);
  }
}

// Fs.openat_file(dir, name, mode) -> File & Result<..., File>.
function fs_openat_file(dir, name, mode) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    const fd = fs_lane.openSync(fs_proc(dir, b),
      O.O_WRONLY | O.O_CREAT | O.O_EXCL | O.O_NOFOLLOW | O.O_CLOEXEC,
      mode & 0o7777);
    return io_tup(dir, io_done(fd));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

function fs_unit(op) {
  try {
    op();
    return io_done({ $: CID(Unit) });
  } catch (e) {
    return fs_fail(e);
  }
}

// Fs.openat_dir(dir, name) -> File & Result<..., File>.
function fs_openat_dir(dir, name) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    const fd = fs_lane.openSync(fs_proc(dir, b),
      O.O_RDONLY | O.O_DIRECTORY | O.O_NOFOLLOW | O.O_CLOEXEC);
    return io_tup(dir, io_done(fd));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

// Fs.mkdirat(dir, name, mode).
function fs_mkdirat(dir, name, mode) {
  const b = fs_component(fs_bytes(name));
  return io_tup(dir, b === null ? io_fail(22)
    : fs_unit(() => fs_lane.mkdirSync(fs_proc(dir, b), { mode: mode & 0o7777 })));
}

// Fs.symlinkat(dir, name, target).
function fs_symlinkat(dir, name, target) {
  const b = fs_component(fs_bytes(name));
  const t = fs_bytes(target);
  if (b === null || t === null || t.length === 0 || t.includes(0)) {
    return io_tup(dir, io_fail(22));
  }
  return io_tup(dir, fs_unit(() => fs_lane.symlinkSync(t, fs_proc(dir, b))));
}

// Fs.linkat(dir, old, new): hardlink to the entry itself (not through a
// symlink); policy is Bend's.
function fs_linkat(dir, oldname, newname) {
  const a = fs_component(fs_bytes(oldname));
  const b = fs_component(fs_bytes(newname));
  return io_tup(dir, a === null || b === null ? io_fail(22)
    : fs_unit(() => fs_lane.linkSync(fs_proc(dir, a), fs_proc(dir, b))));
}

// Fs.fstatat(dir, name): lstat, value (meta, size); meta = type<<12 | mode.
function fs_fstatat(dir, name) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    const st = fs_lane.lstatSync(fs_proc(dir, b));
    if (st.size > 4294967295) {
      return io_tup(dir, io_fail(75));
    }
    const meta = (((st.mode & 0o170000) >> 12) << 12) | (st.mode & 0o7777);
    return io_tup(dir, io_done(io_tup(meta, st.size)));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

// Fs.readlinkat(dir, name) -> File & Result<..., Bytes>.
function fs_readlinkat(dir, name) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    const t = fs_lane.readlinkSync(fs_proc(dir, b), { encoding: "buffer" });
    return io_tup(dir, io_done(io_list(t, t.length)));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

// Fs.readdir(dir) -> File & Result<..., List<Bytes>>.
function fs_readdir(dir) {
  try {
    const names = fs_lane.readdirSync(`/proc/self/fd/${dir}`,
      { encoding: "buffer" });
    let xs = { $: CID(Nil) };
    for (let i = names.length; i > 0; i -= 1) {
      const n = names[i - 1];
      xs = { $: CID(Con), head: io_list(n, n.length), tail: xs };
    }
    return io_tup(dir, io_done(xs));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

// Fs.unlinkat(dir, name).
function fs_unlinkat(dir, name) {
  const b = fs_component(fs_bytes(name));
  return io_tup(dir, b === null ? io_fail(22)
    : fs_unit(() => fs_lane.unlinkSync(fs_proc(dir, b))));
}

// Fs.fchmodat(dir, name, mode); note: follows symlinks in this lane.
function fs_fchmodat(dir, name, mode) {
  const b = fs_component(fs_bytes(name));
  return io_tup(dir, b === null ? io_fail(22)
    : fs_unit(() => fs_lane.chmodSync(fs_proc(dir, b), mode & 0o7777)));
}

// Fs.utimensat(dir, name, mtime): atime = mtime = mtime, seconds.
function fs_utimensat(dir, name, mtime) {
  const b = fs_component(fs_bytes(name));
  return io_tup(dir, b === null ? io_fail(22)
    : fs_unit(() => (mtime >>> 0) === 0xFFFFFFFF ? undefined
      : fs_lane.utimesSync(fs_proc(dir, b), mtime, mtime)));
}

// Fs.renameat(dir, from, to).
function fs_renameat(dir, from, to) {
  const a = fs_component(fs_bytes(from));
  const b = fs_component(fs_bytes(to));
  return io_tup(dir, a === null || b === null ? io_fail(22)
    : fs_unit(() => fs_lane.renameSync(fs_proc(dir, a), fs_proc(dir, b))));
}

// Fs.mkdir_path(path, mode): mkdir(2), EEXIST is success.
function fs_mkdir_path(path, mode) {
  const b = fs_bytes(path);
  if (b === null || b.length === 0 || b.includes(0)) {
    return io_fail(22);
  }
  try {
    fs_lane.mkdirSync(b, { mode: mode & 0o7777 });
  } catch (e) {
    if (e.errno !== -17) {
      return fs_fail(e);
    }
  }
  return io_done({ $: CID(Unit) });
}

// Data.copy(in, out, size) -> in & out & Result<..., Unit>; byte-exact.
function data_copy(input, output, size) {
  const buf = Buffer.alloc(256 * 1024);
  let done = 0;
  try {
    while (done < size) {
      const want = Math.min(256 * 1024, size - done);
      const n = fs_lane.readSync(input, buf, 0, want, null);
      if (n === 0) {
        return io_tup(input, output, io_fail(5));
      }
      let at = 0;
      while (at < n) {
        at += fs_lane.writeSync(output, buf, at, n - at, null);
      }
      done += n;
    }
    return io_tup(input, output, io_done({ $: CID(Unit) }));
  } catch (e) {
    return io_tup(input, output, fs_fail(e));
  }
}

// Stream.read_exact(fd, n) -> File & Result<..., Bytes>; short only at EOF.
function stream_read_exact(fd, n) {
  if (n > 16 * 1024 * 1024) {
    return io_tup(fd, io_fail(22));
  }
  const b = Buffer.alloc(n > 0 ? n : 1);
  try {
    let got = 0;
    while (got < n) {
      const r = fs_lane.readSync(fd, b, got, n - got, null);
      if (r === 0) {
        break;
      }
      got += r;
    }
    return io_tup(fd, io_done(io_list(b.subarray(0, got), got)));
  } catch (e) {
    return io_tup(fd, fs_fail(e));
  }
}

// Stream.write_bytes(fd, bytes) -> File & Result<..., Unit>.
function stream_write_bytes(fd, xs) {
  const b = fs_bytes(xs);
  if (b === null) {
    return io_tup(fd, io_fail(22));
  }
  let at = 0;
  try {
    while (at < b.length) {
      at += fs_lane.writeSync(fd, b, at, b.length - at, null);
    }
    return io_tup(fd, io_done({ $: CID(Unit) }));
  } catch (e) {
    return io_tup(fd, fs_fail(e));
  }
}

// Unused-effect rows are harmless: the runtime never looks them up.
io_eff(CID(Fs.open_dir), fs_open_dir);
io_eff(CID(Fs.openat_dir), fs_openat_dir);
io_eff(CID(Fs.openat_file), fs_openat_file);
io_eff(CID(Fs.mkdirat), fs_mkdirat);
io_eff(CID(Fs.symlinkat), fs_symlinkat);
io_eff(CID(Fs.linkat), fs_linkat);
io_eff(CID(Fs.fstatat), fs_fstatat);
io_eff(CID(Fs.readlinkat), fs_readlinkat);
io_eff(CID(Fs.readdir), fs_readdir);
io_eff(CID(Fs.unlinkat), fs_unlinkat);
io_eff(CID(Fs.fchmodat), fs_fchmodat);
io_eff(CID(Fs.utimensat), fs_utimensat);
io_eff(CID(Fs.renameat), fs_renameat);
io_eff(CID(Fs.mkdir_path), fs_mkdir_path);

// Fs.linkat_at: cross-directory hardlink (JS lane via /proc/self/fd).
function fs_linkat_at(from_dir, from_name, to_dir, to_name) {
  const a = fs_component(fs_bytes(from_name));
  const b = fs_component(fs_bytes(to_name));
  const r = a === null || b === null ? io_fail(22)
    : fs_unit(() => fs_lane.linkSync(fs_proc(from_dir, a),
      fs_proc(to_dir, b)));
  return io_tup(from_dir, io_tup(to_dir, r));
}

io_eff(CID(Fs.linkat_at), fs_linkat_at);

// Fs.euid: effective uid (the JS lane may not expose it; 0 is the safe case:
// setuid/setgid are never kept).
function fs_euid() {
  return typeof process.geteuid === "function" ? process.geteuid() >>> 0 : 0;
}

io_eff(CID(Fs.euid), fs_euid);

// Fs.tzoff: local offset at time t, biased by 2^31 (JS lane: Date's view).
function fs_tzoff(t) {
  return (-new Date((t >>> 0) * 1000).getTimezoneOffset() * 60 + 2147483648) >>> 0;
}

io_eff(CID(Fs.tzoff), fs_tzoff);

// Fs.id_name / Fs.name_id: no passwd database in the JS lane.
function fs_id_name(kind, id) {
  return io_fail(2);
}

function fs_name_id(kind, name) {
  return io_fail(2);
}

io_eff(CID(Fs.id_name), fs_id_name);
io_eff(CID(Fs.name_id), fs_name_id);

// Data.copy_stdout is native-only: the JS lane cannot guarantee byte-exact
// raw fd 1 writes (and must not corrupt non-UTF-8 payloads).
function data_copy_stdout(file, size) {
  return io_tup(file, io_fail(38)); // ENOSYS
}

io_eff(CID(Data.copy_stdout), data_copy_stdout);

// Data.copy_eof is native-only (stdin pump).
function data_copy_eof(inp, out) {
  return io_tup(inp, io_tup(out, io_fail(38))); // ENOSYS
}

io_eff(CID(Data.copy_eof), data_copy_eof);

// Data.cmp is native-only (archive stream vs file contents).
function data_cmp(inp, file, size) {
  return io_tup(inp, io_tup(file, io_fail(38))); // ENOSYS
}

io_eff(CID(Data.cmp), data_cmp);
io_eff(CID(Data.copy), data_copy);
io_eff(CID(Stream.read_exact), stream_read_exact);
io_eff(CID(Stream.write_bytes), stream_write_bytes);
// Fs.statx(dir, name) -> File & Result<..., List<U32>>; fixed lstat order
// [type, mode, nlink, uid, gid, size, mtime, ino_lo, ino_hi, dev_lo, dev_hi].
function fs_statx(dir, name) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    const st = fs_lane.lstatSync(fs_proc(dir, b));
    if (st.size > 4294967295) {
      return io_tup(dir, io_fail(75)); // EOVERFLOW
    }
    const t = (st.mode & 0o170000) >> 12;
    const ino = BigInt(st.ino);
    const dev = BigInt(st.dev);
    const f = [
      t, st.mode & 0o7777, st.nlink, st.uid, st.gid, st.size,
      st.mtimeMs / 1000 >> 0,
      Number(ino & 0xffffffffn), Number(ino >> 32n),
      Number(dev & 0xffffffffn), Number(dev >> 32n),
    ];
    let xs = { $: CID(Nil) };
    for (let i = f.length - 1; i >= 0; i -= 1) {
      xs = { $: CID(Con), head: f[i] >>> 0, tail: xs };
    }
    return io_tup(dir, io_done(xs));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

io_eff(CID(Fs.statx), fs_statx);

// Fs.openat_read(dir, name) -> File & Result<..., File>; read-only source fd.
function fs_openat_read(dir, name) {
  const b = fs_component(fs_bytes(name));
  if (b === null) {
    return io_tup(dir, io_fail(22));
  }
  try {
    return io_tup(dir, io_done(fs_lane.openSync(fs_proc(dir, b),
      O.O_RDONLY | O.O_NOFOLLOW | O.O_CLOEXEC)));
  } catch (e) {
    return io_tup(dir, fs_fail(e));
  }
}

io_eff(CID(Fs.openat_read), fs_openat_read);

// Stream.write_zeros(fd, n) -> File & Result<..., Unit>; EINTR-safe zeros.
function stream_write_zeros(file, n) {
  try {
    const buf = Buffer.alloc(64 * 1024);
    let left = n >>> 0;
    while (left > 0) {
      const k = Math.min(left, buf.length);
      const w = fs_lane.writeSync(file, buf, 0, k);
      if (w <= 0) {
        return io_tup(file, io_fail(5));
      }
      left -= w;
    }
    return io_tup(file, io_done({ $: CID(Unit) }));
  } catch (e) {
    return io_tup(file, fs_fail(e));
  }
}

io_eff(CID(Stream.write_zeros), stream_write_zeros);

// M5 gzip plumbing (native-only for memfd/dup/rewind; JS lane documented as
// ENOSYS so gzip (-z) paths require the native binary).
function stream_read_file(fd) {
  try {
    const chunks = [];
    let total = 0;
    const cap = 64 * 1024 * 1024;
    for (;;) {
      const buf = Buffer.alloc(256 * 1024);
      const n = fs_lane.readSync(fd, buf, 0, buf.length, total);
      if (n <= 0) {
        break;
      }
      chunks.push(buf.subarray(0, n));
      total += n;
      if (total > cap) {
        return io_tup(fd, io_fail(27)); // EFBIG
      }
    }
    const all = Buffer.concat(chunks, total);
    return io_tup(fd, io_done(io_list(all, all.length)));
  } catch (e) {
    return io_tup(fd, fs_fail(e));
  }
}

io_eff(CID(Stream.read_file), stream_read_file);

function stream_rewind(file) {
  return io_tup(file, io_fail(38)); // ENOSYS: JS lane cannot lseek
}

io_eff(CID(Stream.rewind), stream_rewind);

// v1.2 append/update plumbing: native-only (JS lane answers ENOSYS).
function fs_open_rw(path) {
  return io_fail(38);
}

io_eff(CID(Fs.open_rw), fs_open_rw);

function stream_seek(file, off, whence) {
  return io_tup(file, io_fail(38));
}

io_eff(CID(Stream.seek), stream_seek);

function fs_trunc_cur(file) {
  return io_tup(file, io_fail(38));
}

io_eff(CID(Fs.trunc_cur), fs_trunc_cur);

function fs_memfd_write(data) {
  return io_fail(38); // ENOSYS: Linux memfd_create is native-only
}

io_eff(CID(Fs.memfd_write), fs_memfd_write);

function fs_dup_file(file) {
  return io_tup(file, io_fail(38));
}

io_eff(CID(Fs.dup_file), fs_dup_file);

function stream_read_seg(file, n, tail) {
  return io_tup(file, io_fail(38)); // ENOSYS: native-only
}

io_eff(CID(Stream.read_seg), stream_read_seg);

function fs_pipe() {
  return io_fail(38); // ENOSYS: pipes are native-only
}

io_eff(CID(Fs.pipe), fs_pipe);

function fs_fstatx(file) {
  try {
    const st = fs_lane.fstatSync(file);
    if (st.size > 4294967295) {
      return io_tup(file, io_fail(75));
    }
    const t = (st.mode & 0o170000) >> 12;
    const ino = BigInt(st.ino);
    const dev = BigInt(st.dev);
    const f = [
      t, st.mode & 0o7777, st.nlink, st.uid, st.gid, st.size,
      st.mtimeMs / 1000 >> 0,
      Number(ino & 0xffffffffn), Number(ino >> 32n),
      Number(dev & 0xffffffffn), Number(dev >> 32n),
    ];
    let xs = { $: CID(Nil) };
    for (let i = f.length - 1; i >= 0; i -= 1) {
      xs = { $: CID(Con), head: f[i] >>> 0, tail: xs };
    }
    return io_tup(file, io_done(xs));
  } catch (e) {
    return io_tup(file, fs_fail(e));
  }
}

io_eff(CID(Fs.fstatx), fs_fstatx);

// Fs.stat_path(path) -> Result<..., List<U32>>; lstat of a whole path
// (create operands compose "<-C root>/<operand>" in Bend).
function fs_stat_path(path) {
  const b = fs_bytes(path);
  if (b === null || b.length === 0 || b.includes(0)) {
    return io_fail(22);
  }
  try {
    const st = fs_lane.lstatSync(b);
    if (st.size > 4294967295) {
      return io_fail(75);
    }
    const t = (st.mode & 0o170000) >> 12;
    const ino = BigInt(st.ino);
    const dev = BigInt(st.dev);
    const f = [
      t, st.mode & 0o7777, st.nlink, st.uid, st.gid, st.size,
      st.mtimeMs / 1000 >> 0,
      Number(ino & 0xffffffffn), Number(ino >> 32n),
      Number(dev & 0xffffffffn), Number(dev >> 32n),
    ];
    let xs = { $: CID(Nil) };
    for (let i = f.length - 1; i >= 0; i -= 1) {
      xs = { $: CID(Con), head: f[i] >>> 0, tail: xs };
    }
    return io_done(xs);
  } catch (e) {
    return fs_fail(e);
  }
}

io_eff(CID(Fs.stat_path), fs_stat_path);

// Fs.readlink_path(path) -> Result<..., Bytes>; readlink of a whole path.
function fs_readlink_path(path) {
  const b = fs_bytes(path);
  if (b === null || b.length === 0 || b.includes(0)) {
    return io_fail(22);
  }
  try {
    const target = fs_lane.readlinkSync(b);
    return io_done(io_list(target, target.length));
  } catch (e) {
    return fs_fail(e);
  }
}

io_eff(CID(Fs.readlink_path), fs_readlink_path);
