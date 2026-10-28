// tar-bend trusted effects: filesystem metadata/mutation, directory listing,
// and the data plane. This is the only trusted C in the project; effects are
// IO-only and ABI-coupled to Bend 2.0.39 (see tools/abi_check.sh).
//
// Conventions (docs/effects.md):
// - Bytes in = List<&2,U32> (CID_Con); io_cbuf validates each value is <= 255.
// - Bytes out = List<&2,U32> (CID_Con); io_list builds it.
// - A handle-taking effect returns io_tup(io_hand(h), result) on every path,
//   including validation failures; the fd is borrowed, never closed here.
// - A handle-producing effect (open_dir) gives the fd away open.
// - All *at names are one component: non-empty, no NUL, no '/', not "."/"..".
//   C never joins paths; Bend validates and walks component by component.
// - Failures are io_res: errno in code, strerror() as message.
#ifndef BTAR_EFFS_FS_C
#define BTAR_EFFS_FS_C

#include <dirent.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

// Linux x86-64 numbers; the project target (kernel >= 5.6, glibc) is fixed.
#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#ifndef SYS_fchmodat2
#define SYS_fchmodat2 452
#endif
#ifndef RESOLVE_BENEATH
#define RESOLVE_BENEATH 0x08
#define RESOLVE_NO_SYMLINKS 0x04
#endif

// linux/openat2.h's struct open_how, spelled out so the C has no kernel-header
// dependency: three u64 words.
struct btar_open_how {
  unsigned long long flags;
  unsigned long long mode;
  unsigned long long resolve;
};

static long btar_openat2(int dirfd, const char* path, unsigned long long flags,
  unsigned long long mode, unsigned long long resolve) {
  struct btar_open_how how;
  how.flags   = flags;
  how.mode    = mode;
  how.resolve = resolve;
  return syscall(SYS_openat2, (long)dirfd, path, &how, (long)sizeof how);
}

// One component, relative, no traversal. io_cbuf NUL-terminates at len.
static int fs_name_ok(const char* s, u64 len) {
  if (s == NULL || len == 0 || len > NAME_MAX) {
    return 0;
  }
  if (io_nul(s, len) || s[0] == '/') {
    return 0;
  }
  for (u64 i = 0; i < len; i += 1) {
    if (s[i] == '/') {
      return 0;
    }
  }
  return !(len == 1 && s[0] == '.')
    && !(len == 2 && s[0] == '.' && s[1] == '.');
}

// A path for open_dir/mkdir_path: non-empty, no interior NUL. Bend validates
// the policy; this only rejects what C cannot pass on.
static int fs_path_ok(const char* s, u64 len) {
  return s != NULL && len > 0 && !io_nul(s, len);
}

// An IoWork is reused across steps, so a pack always clears what it owns:
// stale pointers from an earlier effect would otherwise be freed twice.
static void fs_clear(IoWork* w) {
  free(w->data);
  free(w->text);
  w->data = NULL;
  w->text = NULL;
}


// Short local syscalls run inline on the event-loop thread: a helper-thread
// round trip (queue, wake pipe, poll) costs ~12 us, far more than the syscall
// itself.  Only operations that cannot wait on another computation qualify:
// path operations, and reads/writes whose descriptor is a regular file (or a
// character device such as /dev/null for writes).  Pipes and sockets stay on
// the helper pool so the decoder/compressor forks can keep running.
static Term fs_inline(Env e, IoWork* w, IoCall call, IoPack pack) {
  call(w);
  return pack(e, w);
}

static int fs_fd_reg(int fd) {
  struct stat st;
  return fstat(fd, &st) == 0 && S_ISREG(st.st_mode);
}

static int fs_fd_out_ok(int fd) {
  struct stat st;
  return fstat(fd, &st) == 0 && (S_ISREG(st.st_mode) || S_ISCHR(st.st_mode));
}

static Term fs_maybe_inline(Env e, IoWork* w, IoCall call, IoPack pack, int ok) {
  return ok ? fs_inline(e, w, call, pack) : io_work(w, call, pack);
}

static Term fs_unit_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, term_pak(CID(Unit), 0)));
}

static Term fs_unit_start(Env e, Term* f, IoWork* w, IoCall call, int ok) {
  return ok ? fs_inline(e, w, call, fs_unit_pack) : fs_unit_pack(e, w);
}

// Fs.open_dir(path) -> Result<..., File>. Absolute, Bend-validated path.
static void fs_open_dir_call(IoWork* w) {
  long n = btar_openat2(AT_FDCWD, w->data,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, 0);
  if (n < 0 && errno == ENOSYS) {
    // pre-openat2 kernel fallback: no RESOLVE filter; the path is the
    // Bend-validated destination root, so this only loses magic-link clarity.
    n = open(w->data, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  }
  w->made = (intptr_t)io_sys_end(w, n);
}

static Term fs_open_dir_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_res(e, w, io_hand(w->made));
}

Term fs_open_dir_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->data = io_cbuf(e, f[0], &len, CID(Con));
  w->code = fs_path_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_open_dir_pack(e, w)
    : fs_inline(e, w, fs_open_dir_call, fs_open_dir_pack);
}

// Fs.openat_file(dir, name, mode) -> dir & Result<..., File>.
static void fs_openat_file_call(IoWork* w) {
  int flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC;
  long n = btar_openat2((int)w->hand, w->data, (unsigned long long)flags,
    (unsigned long long)w->word, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
  if (n < 0 && errno == ENOSYS) {
    // pre-openat2 fallback: single-component O_NOFOLLOW|O_EXCL only, so no
    // traversal is possible from this name; RESOLVE_BENEATH is unavailable.
    n = openat((int)w->hand, w->data, flags, (mode_t)w->word);
  }
  w->made = (intptr_t)io_sys_end(w, n);
}

static Term fs_openat_file_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, io_hand(w->made)));
}

Term fs_openat_file_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[2] & 07777;
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_openat_file_pack(e, w)
    : fs_inline(e, w, fs_openat_file_call, fs_openat_file_pack);
}

// Fs.openat_dir(dir, name) -> dir & Result<..., File>. Opens a subdirectory
// relative to a borrowed dirfd, without following symlinks or escaping it.
static void fs_openat_dir_call(IoWork* w) {
  int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  long n = btar_openat2((int)w->hand, w->data, (unsigned long long)flags, 0,
    RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
  if (n < 0 && errno == ENOSYS) {
    n = openat((int)w->hand, w->data, flags);
  }
  w->made = (intptr_t)io_sys_end(w, n);
}

static Term fs_openat_dir_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, io_hand(w->made)));
}

Term fs_openat_dir_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_openat_dir_pack(e, w)
    : fs_inline(e, w, fs_openat_dir_call, fs_openat_dir_pack);
}

// Fs.mkdirat(dir, name, mode) -> dir & Result<..., Unit>.
static void fs_mkdirat_call(IoWork* w) {
  io_sys_end(w, mkdirat((int)w->hand, w->data, (mode_t)w->word));
}

Term fs_mkdirat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[2] & 07777;
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_mkdirat_call, w->code == 0);
}

// Fs.symlinkat(dir, name, target) -> dir & Result<..., Unit>.
static void fs_symlinkat_call(IoWork* w) {
  io_sys_end(w, symlinkat(w->text, (int)w->hand, w->data));
}

Term fs_symlinkat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0, tlen = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->text = io_cbuf(e, f[2], &tlen, CID(Con));
  w->code = fs_name_ok(w->data, len)
    && w->text != NULL && tlen > 0 && !io_nul(w->text, tlen) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_symlinkat_call, w->code == 0);
}

// Fs.linkat(dir, old, new) -> dir & Result<..., Unit>; flags 0: a hardlink to
// the entry itself (never through a symlink). Policy (same inode, previously
// extracted regular file) is Bend's; C only links two validated components.
static void fs_linkat_call(IoWork* w) {
  io_sys_end(w, linkat((int)w->hand, w->data, (int)w->hand, w->text, 0));
}

Term fs_linkat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0, nlen = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->text = io_cbuf(e, f[2], &nlen, CID(Con));
  w->code = fs_name_ok(w->data, len) && fs_name_ok(w->text, nlen) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_linkat_call, w->code == 0);
}

// Fs.fstatat(dir, name) -> dir & Result<..., meta & size>, lstat semantics.
// meta = (type << 12) | (mode & 0o7777), type = S_IFMT >> 12 (8 reg, 4 dir,
// 10 link, 1 fifo, 2 chr, 6 blk, 12 sock). size fails EOVERFLOW past U32.
static void fs_fstatat_call(IoWork* w) {
  struct stat st;
  int n = fstatat((int)w->hand, w->data, &st, AT_SYMLINK_NOFOLLOW);
  w->code = n != 0 ? (u32)errno : 0;
  if (n == 0) {
    if (st.st_size < 0 || st.st_size > (off_t)UINT32_MAX) {
      w->code = EOVERFLOW;
    } else {
      w->word = (uint32_t)(((u64)(st.st_mode & S_IFMT) >> 12) << 12)
        | (uint32_t)(st.st_mode & 07777);
      w->size = (u64)st.st_size;
    }
  }
}

static Term fs_fstatat_pack(Env e, IoWork* w) {
  fs_clear(w);
  Term v = io_tup(e, (Term)w->word, (Term)w->size);
  return io_tup(e, io_hand(w->hand), io_res(e, w, v));
}

Term fs_fstatat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  if (w->code) {
    return fs_fstatat_pack(e, w);
  }
  return fs_inline(e, w, fs_fstatat_call, fs_fstatat_pack);
}

// Fs.readlinkat(dir, name) -> dir & Result<..., Bytes>, target up to 64 KiB.
static void fs_readlinkat_call(IoWork* w) {
  u64 cap = 256;
  char* buf = io_mem(malloc(cap + 1));
  for (;;) {
    ssize_t n = readlinkat((int)w->hand, w->data, buf, cap);
    if (n < 0) {
      free(buf);
      io_sys_end(w, n);
      return;
    }
    if ((u64)n < cap) {
      w->text = buf;
      w->size = (u64)n;
      w->code = 0;
      return;
    }
    free(buf);
    if (cap >= 65536) {
      w->text = NULL;
      w->size = 0;
      w->code = ENAMETOOLONG;
      return;
    }
    cap *= 2;
    buf = io_mem(malloc(cap + 1));
  }
}

static Term fs_readlinkat_pack(Env e, IoWork* w) {
  Term v = io_list(e, w->text, w->size);
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, v));
}

Term fs_readlinkat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->text = NULL;
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  if (w->code) {
    return fs_readlinkat_pack(e, w);
  }
  return fs_inline(e, w, fs_readlinkat_call, fs_readlinkat_pack);
}

// Fs.readdir(dir) -> dir & Result<..., List<Bytes>>, names without . and ..
// Order is the host's; Bend sorts when determinism is wanted.
typedef struct {
  char* buf;
  u64 used;
  u64 count;
  u64 cap;
  u32 code;
} ReaddirCall;

static int fs_readdir_grow(ReaddirCall* p, u64 need) {
  while (need > p->cap) {
    p->cap *= 2;
  }
  p->buf = io_mem(realloc(p->buf, p->cap));
  return 0;
}

static void fs_readdir_call(IoWork* w) {
  ReaddirCall p = { io_mem(malloc(4096)), 0, 0, 4096, 0 };
  int fd = openat((int)w->hand, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) {
    p.code = (u32)errno;
    w->data = p.buf;
    w->code = p.code;
    return;
  }
  DIR* d = fdopendir(fd);
  if (d == NULL) {
    p.code = (u32)errno;
    close(fd);
    w->data = p.buf;
    w->code = p.code;
    return;
  }
  errno = 0;
  struct dirent* ent;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
      continue;
    }
    u64 len = strlen(ent->d_name);
    if (p.used + len + 1 > p.cap && fs_readdir_grow(&p, p.used + len + 1)) {
      break;
    }
    memcpy(p.buf + p.used, ent->d_name, len + 1);
    p.used += len + 1;
    p.count += 1;
  }
  p.code = (u32)errno;
  if (closedir(d) != 0 && p.code == 0) {
    p.code = (u32)errno;
  }
  w->data = p.buf;
  w->size = p.used;
  w->word = (u32)p.count;
  w->code = p.code;
}

// Names sit NUL-terminated in w->data, in readdir order. Parse forward into an
// (offset,length) table, then fold backwards so the Bend list keeps the order.
static Term fs_readdir_pack(Env e, IoWork* w) {
  u32 count = w->word;
  u64* offs = io_mem(malloc((count == 0 ? 1 : count) * sizeof(u64)));
  u64* lens = io_mem(malloc((count == 0 ? 1 : count) * sizeof(u64)));
  u64 pos = 0;
  for (u32 i = 0; i < count; i += 1) {
    offs[i] = pos;
    u64 len = 0;
    while (pos + len < w->size && w->data[pos + len] != '\0') {
      len += 1;
    }
    lens[i] = len;
    pos += len + 1;
  }
  Term xs = term_pak(CID_Nil, 0);
  for (u32 i = count; i > 0; i -= 1) {
    xs = io_node(e, CID_Con,
      io_list(e, w->data + offs[i - 1], lens[i - 1]), xs);
  }
  free(offs);
  free(lens);
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, xs));
}

Term fs_readdir_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  return fs_inline(e, w, fs_readdir_call, fs_readdir_pack);
}

// Fs.unlinkat(dir, name) -> dir & Result<..., Unit>; flags 0 (no rmdir).
static void fs_unlinkat_call(IoWork* w) {
  io_sys_end(w, unlinkat((int)w->hand, w->data, 0));
}

Term fs_unlinkat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_unlinkat_call, w->code == 0);
}

// Fs.fchmodat(dir, name, mode) -> dir & Result<..., Unit>. fchmodat2 with
// AT_SYMLINK_NOFOLLOW (kernel >= 6.5); pre-6.5 fallback fchmodat(2) follows
// symlinks, so callers must have validated the entry type immediately before.
static void fs_fchmodat_call(IoWork* w) {
  long n = syscall(SYS_fchmodat2, (long)w->hand, w->data,
    (long)(w->word & 07777), (long)AT_SYMLINK_NOFOLLOW);
  if (n < 0 && errno == ENOSYS) {
    n = fchmodat((int)w->hand, w->data, (mode_t)w->word, 0);
  }
  io_sys_end(w, n);
}

Term fs_fchmodat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[2] & 07777;
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_fchmodat_call, w->code == 0);
}

// Fs.utimensat(dir, name, mtime) -> dir & Result<..., Unit>. Sets atime and
// mtime to mtime (GNU tar's default: no atime preservation in v1).
static void fs_utimensat_call(IoWork* w) {
  // 0xFFFFFFFF leaves the times alone (btar -m / --touch).
  long ns = (uint32_t)w->word == UINT32_MAX ? UTIME_OMIT : 0;
  struct timespec ts[2] = {
    { (time_t)w->word, ns },
    { (time_t)w->word, ns },
  };
  io_sys_end(w, utimensat((int)w->hand, w->data, ts, AT_SYMLINK_NOFOLLOW));
}

Term fs_utimensat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[2];
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_utimensat_call, w->code == 0);
}

// Fs.renameat(dir, from, to) -> dir & Result<..., Unit>; same directory.
static void fs_renameat_call(IoWork* w) {
  io_sys_end(w, renameat((int)w->hand, w->data, (int)w->hand, w->text));
}

Term fs_renameat_run(Env e, Term* f, IoWork* w) {
  u64 len = 0, nlen = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->text = io_cbuf(e, f[2], &nlen, CID(Con));
  w->code = fs_name_ok(w->data, len) && fs_name_ok(w->text, nlen) ? 0 : EINVAL;
  return fs_unit_start(e, f, w, fs_renameat_call, w->code == 0);
}

// Fs.mkdir_path(path, mode) -> Result<..., Unit>; mkdir(2), EEXIST is success.
// Only for the extraction root (the one non-component path in the API).
static void fs_mkdir_path_call(IoWork* w) {
  long n = mkdir(w->data, (mode_t)w->word);
  w->code = n == 0 || errno == EEXIST ? 0 : (u32)errno;
}

static Term fs_mkdir_path_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_res(e, w, term_pak(CID(Unit), 0));
}

Term fs_mkdir_path_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->word = (uint32_t)f[1] & 07777;
  w->data = io_cbuf(e, f[0], &len, CID(Con));
  w->code = fs_path_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_mkdir_path_pack(e, w)
    : fs_inline(e, w, fs_mkdir_path_call, fs_mkdir_path_pack);
}

// Data.copy(in, out, size) -> in & out & Result<..., Unit>. Byte-exact:
// reads exactly size, writes all of it, EINTR-safe; premature EOF is EIO.
#define BTAR_COPY_CHUNK (256u * 1024u)

static void data_copy_call(IoWork* w) {
  char* buf = w->data;
  u64 want = w->size, done = 0;
  while (done < want) {
    u64 chunk = want - done < BTAR_COPY_CHUNK ? want - done : BTAR_COPY_CHUNK;
    ssize_t n = read((int)w->hand, buf, chunk);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      w->code = (u32)errno;
      return;
    }
    if (n == 0) {
      w->code = EIO; // source ended before size bytes: a broken archive/file
      return;
    }
    ssize_t at = 0;
    while (at < n) {
      ssize_t m = write((int)w->made, buf + at, (u64)(n - at));
      if (m < 0) {
        if (errno == EINTR) {
          continue;
        }
        w->code = (u32)errno;
        return;
      }
      if (m == 0) {
        w->code = EIO;
        return;
      }
      at += m;
    }
    done += (u64)n;
  }
  w->code = 0;
}

static Term data_copy_pack(Env e, IoWork* w) {
  fs_clear(w);
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  return io_tup(e, io_hand(w->hand), io_tup(e, io_hand(w->made), r));
}

Term data_copy_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->made = (intptr_t)io_hand_v(f[1]);
  w->size = (u32)f[2];
  w->data = io_mem(malloc(BTAR_COPY_CHUNK));
  return fs_maybe_inline(e, w, data_copy_call, data_copy_pack,
    fs_fd_reg((int)w->hand) && fs_fd_out_ok((int)w->made));
}

// Stream.read_exact(fd, n) -> fd & Result<..., Bytes>; up to n bytes, short
// only at EOF. Cap: 16 MiB (headers/pax are <= 64 KiB; a bigger request is a
// caller bug, fail fast).
#define BTAR_READ_MAX (16u * 1024u * 1024u)

static void stream_read_exact_call(IoWork* w) {
  u64 want = w->word, got = 0;
  while (got < want) {
    ssize_t n = read((int)w->hand, w->data + got, want - got);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      io_sys_end(w, n);
      return;
    }
    if (n == 0) {
      break;
    }
    got += (u64)n;
  }
  w->size = got;
  w->code = 0;
}

static Term stream_read_exact_pack(Env e, IoWork* w) {
  Term v = io_list(e, w->data, w->size);
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, v));
}

Term stream_read_exact_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[1];
  w->size = 0;
  w->code = w->word <= BTAR_READ_MAX ? 0 : EINVAL;
  if (w->code) {
    return stream_read_exact_pack(e, w);
  }
  w->data = io_mem(malloc(w->word == 0 ? 1 : w->word));
  return fs_maybe_inline(e, w, stream_read_exact_call, stream_read_exact_pack,
    fs_fd_reg((int)w->hand));
}


// Stream.read_seg(fd, n, tail) -> fd & Result<..., Bytes & Bytes>: like read_exact
// (up to n bytes, short only at EOF) but returns the bytes together with a second
// list holding the last min(tail, got) of them.  The compressor uses it to get a
// segment and its dictionary tail without slicing a long list in Bend.
static Term stream_read_seg_pack(Env e, IoWork* w) {
  u64 got = w->size;
  u64 t = (u64)w->made < got ? (u64)w->made : got;
  Term seg = io_list(e, w->data, got);
  Term tl = io_list(e, w->data + (got - t), t);
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, io_tup(e, seg, tl)));
}

Term stream_read_seg_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[1];
  w->made = (intptr_t)(uint32_t)f[2];
  w->size = 0;
  w->code = w->word <= BTAR_READ_MAX ? 0 : EINVAL;
  if (w->code) {
    return stream_read_seg_pack(e, w);
  }
  w->data = io_mem(malloc(w->word == 0 ? 1 : w->word));
  return fs_maybe_inline(e, w, stream_read_exact_call, stream_read_seg_pack,
    fs_fd_reg((int)w->hand));
}

// Stream.write_bytes(fd, bytes) -> fd & Result<..., Unit>; EINTR-safe.
static void stream_write_bytes_call(IoWork* w) {
  char* p = w->data;
  u64 left = w->size;
  while (left > 0) {
    ssize_t n = write((int)w->hand, p, left);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      io_sys_end(w, n);
      return;
    }
    if (n == 0) {
      w->code = EIO;
      return;
    }
    p += n;
    left -= (u64)n;
  }
  w->code = 0;
}

Term stream_write_bytes_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &w->size, CID(Con));
  w->code = w->data == NULL ? EINVAL : 0;
  return w->code ? fs_unit_pack(e, w)
    : fs_maybe_inline(e, w, stream_write_bytes_call, fs_unit_pack,
        fs_fd_out_ok((int)w->hand));
}

// Fs.linkat_at(from_dir, from_name, to_dir, to_name) -> both dirs &
// Result<..., Unit>. Cross-directory linkat(2): both names are single
// validated components, the caller walks both parents dirfd-relative. This
// is the M3 cross-directory hardlink step; policy (already-extracted regular
// target under the root) is Bend's, not C's.
static void fs_linkat_at_call(IoWork* w) {
  io_sys_end(w, linkat((int)w->hand, w->data, (int)w->made, w->text, 0));
}

static Term fs_linkat_at_pack(Env e, IoWork* w) {
  fs_clear(w);
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  return io_tup(e, io_hand(w->hand), io_tup(e, io_hand(w->made), r));
}

Term fs_linkat_at_run(Env e, Term* f, IoWork* w) {
  u64 len = 0, nlen = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->made = (intptr_t)io_hand_v(f[2]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->text = io_cbuf(e, f[3], &nlen, CID(Con));
  w->code = fs_name_ok(w->data, len) && fs_name_ok(w->text, nlen) ? 0 : EINVAL;
  if (w->code != 0) {
    return fs_linkat_at_pack(e, w);
  }
  return fs_inline(e, w, fs_linkat_at_call, fs_linkat_at_pack);
}

// Data.copy_stdout(in, size) -> in & Result<..., Unit>. Byte-exact raw copy
// to fd 1, for `btar -xO` (the JS lane is native-only here: ENOSYS).
static void data_copy_stdout_call(IoWork* w) {
  char* buf = w->data;
  u64 want = w->size, done = 0;
  while (done < want) {
    u64 chunk = want - done < BTAR_COPY_CHUNK ? want - done : BTAR_COPY_CHUNK;
    ssize_t n = read((int)w->hand, buf, chunk);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      w->code = (u32)errno;
      return;
    }
    if (n == 0) {
      w->code = EIO;
      return;
    }
    ssize_t at = 0;
    while (at < n) {
      ssize_t m = write(STDOUT_FILENO, buf + at, (u64)(n - at));
      if (m < 0) {
        if (errno == EINTR) {
          continue;
        }
        w->code = (u32)errno;
        return;
      }
      if (m == 0) {
        w->code = EIO;
        return;
      }
      at += m;
    }
    done += (u64)n;
  }
  w->code = 0;
}

Term data_copy_stdout_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->size = (u32)f[1];
  w->data = io_mem(malloc(BTAR_COPY_CHUNK));
  return fs_maybe_inline(e, w, data_copy_stdout_call, fs_unit_pack,
    fs_fd_reg((int)w->hand));
}

// Data.copy_eof(in, out) -> in & out & Result<..., Unit>. Copies until the source
// reports EOF (stdin pipes of unknown length); the pump that feeds a re-readable
// pipe for non-seekable archives.
static void data_copy_eof_call(IoWork* w) {
  char* buf = w->data;
  w->code = 0;
  for (;;) {
    ssize_t n = read((int)w->hand, buf, BTAR_COPY_CHUNK);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      w->code = (u32)errno;
      return;
    }
    if (n == 0) {
      return;
    }
    ssize_t at = 0;
    while (at < n) {
      ssize_t m = write((int)w->made, buf + at, (u64)(n - at));
      if (m < 0) {
        if (errno == EINTR) {
          continue;
        }
        w->code = (u32)errno;
        return;
      }
      if (m == 0) {
        w->code = EIO;
        return;
      }
      at += m;
    }
  }
}

Term data_copy_eof_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->made = (intptr_t)io_hand_v(f[1]);
  w->data = io_mem(malloc(BTAR_COPY_CHUNK));
  return io_work(w, data_copy_eof_call, data_copy_pack);
}

// Data.cmp(in, file, size) -> in & file & Result<..., U32>: compares `size` bytes of the
// archive stream with the start of `file` (btar -d).  Always consumes `size` archive
// bytes so the stream stays in sync; value 0 = equal, 1 = differs (or file shorter).
static void data_cmp_call(IoWork* w) {
  char* a = w->data;
  char* b = a + BTAR_COPY_CHUNK;
  u64 want = w->size, done = 0;
  w->word = 0;
  w->code = 0;
  while (done < want) {
    u64 chunk = want - done < BTAR_COPY_CHUNK ? want - done : BTAR_COPY_CHUNK;
    u64 got = 0;
    while (got < chunk) {
      ssize_t n = read((int)w->hand, a + got, chunk - got);
      if (n < 0 && errno == EINTR) {
        continue;
      }
      if (n <= 0) {
        w->code = n < 0 ? (u32)errno : EIO;
        return;
      }
      got += (u64)n;
    }
    u64 have = 0;
    while (w->word == 0 && have < chunk) {
      ssize_t n = read((int)w->made, b + have, chunk - have);
      if (n < 0 && errno == EINTR) {
        continue;
      }
      if (n < 0) {
        w->code = (u32)errno;
        return;
      }
      if (n == 0) {
        w->word = 1;
        break;
      }
      have += (u64)n;
    }
    if (w->word == 0 && memcmp(a, b, chunk) != 0) {
      w->word = 1;
    }
    done += chunk;
  }
}

static Term data_cmp_pack(Env e, IoWork* w) {
  u32 v = (u32)w->word;
  fs_clear(w);
  Term r = io_res(e, w, (Term)(uint32_t)v);
  return io_tup(e, io_hand(w->hand), io_tup(e, io_hand(w->made), r));
}

Term data_cmp_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->made = (intptr_t)io_hand_v(f[1]);
  w->size = (u32)f[2];
  w->data = io_mem(malloc(2 * BTAR_COPY_CHUNK));
  return io_work(w, data_cmp_call, data_cmp_pack);
}

// Fs.euid() -> U32. The effective uid decides whether -p may keep setuid/setgid.
Term fs_euid_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  return (Term)(uint32_t)geteuid();
}

// Fs.tzoff(t) -> U32. Local UTC offset in seconds at time t, biased by 2^31 so it
// stays unsigned (listing timestamps are printed in local time, like GNU).
Term fs_tzoff_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  time_t t = (time_t)(uint32_t)f[0];
  struct tm tm;
  long off = 0;
  if (localtime_r(&t, &tm) != NULL) {
    off = tm.tm_gmtoff;
  }
  return (Term)(uint32_t)((int64_t)off + 2147483648LL);
}

// Fs.id_name(kind, id) -> Result<..., Bytes>: user (kind 0) or group (kind 1) name.
static void fs_id_name_call(IoWork* w) {
  char buf[16384];
  const char* name = NULL;
  if (w->made == 0) {
    struct passwd pw, *res = NULL;
    if (getpwuid_r((uid_t)w->word, &pw, buf, sizeof buf, &res) == 0 && res) {
      name = res->pw_name;
    }
  } else {
    struct group gr, *res = NULL;
    if (getgrgid_r((gid_t)w->word, &gr, buf, sizeof buf, &res) == 0 && res) {
      name = res->gr_name;
    }
  }
  if (name == NULL) {
    w->code = ENOENT;
    w->data = NULL;
    w->size = 0;
    return;
  }
  w->size = strlen(name);
  w->data = io_mem(malloc(w->size + 1));
  memcpy(w->data, name, w->size);
  w->code = 0;
}

static Term fs_id_name_pack(Env e, IoWork* w) {
  Term v = io_list(e, w->data, w->size);
  fs_clear(w);
  return io_res(e, w, v);
}

Term fs_id_name_run(Env e, Term* f, IoWork* w) {
  w->made = (intptr_t)(uint32_t)f[0];
  w->word = (uint32_t)f[1];
  return fs_inline(e, w, fs_id_name_call, fs_id_name_pack);
}

// Fs.name_id(kind, name) -> Result<..., U32>: user/group id of a name.
static void fs_name_id_call(IoWork* w) {
  char buf[16384];
  w->code = ENOENT;
  if (w->made == 0) {
    struct passwd pw, *res = NULL;
    if (getpwnam_r((const char*)w->text, &pw, buf, sizeof buf, &res) == 0 && res) {
      w->word = res->pw_uid;
      w->code = 0;
    }
  } else {
    struct group gr, *res = NULL;
    if (getgrnam_r((const char*)w->text, &gr, buf, sizeof buf, &res) == 0 && res) {
      w->word = gr.gr_gid;
      w->code = 0;
    }
  }
}

static Term fs_name_id_pack(Env e, IoWork* w) {
  u32 v = (u32)w->word;
  fs_clear(w);
  return io_res(e, w, (Term)(uint32_t)v);
}

Term fs_name_id_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->made = (intptr_t)(uint32_t)f[0];
  w->text = io_cbuf(e, f[1], &len, CID(Con));
  if (w->text == NULL || len == 0) {
    w->code = EINVAL;
    return fs_name_id_pack(e, w);
  }
  return fs_inline(e, w, fs_name_id_call, fs_name_id_pack);
}

// Fs.statx(dir, name) -> dir & Result<..., List<U32>>; lstat fields in fixed
// order: [type, mode, nlink, uid, gid, size, mtime, ino_lo, ino_hi, dev_lo,
// dev_hi]. type matches fstatat meta (S_IFMT >> 12): 8 reg, 4 dir, 10 link,
// 1 fifo, 2 chr, 6 blk, 12 sock. Sizes past U32 fail EOVERFLOW (v1 cap).
#define BTAR_STATX_FIELDS 11u
static void fs_statx_call(IoWork* w) {
  struct stat st;
  int n = fstatat((int)w->hand, w->text, &st, AT_SYMLINK_NOFOLLOW);
  w->code = n != 0 ? (u32)errno : 0;
  if (n != 0) {
    return;
  }
  if (st.st_size < 0 || st.st_size > (off_t)UINT32_MAX) {
    w->code = EOVERFLOW;
    return;
  }
  u32* f = (u32*)w->data;
  u64 ino = (u64)st.st_ino;
  u64 dev = (u64)st.st_dev;
  f[0] = (u32)((u64)(st.st_mode & S_IFMT) >> 12);
  f[1] = (u32)(st.st_mode & 07777);
  f[2] = (u32)st.st_nlink;
  f[3] = (u32)st.st_uid;
  f[4] = (u32)st.st_gid;
  f[5] = (u32)st.st_size;
  f[6] = (u32)st.st_mtim.tv_sec;
  f[7] = (u32)(ino & 0xffffffffu);
  f[8] = (u32)(ino >> 32);
  f[9] = (u32)(dev & 0xffffffffu);
  f[10] = (u32)(dev >> 32);
}

static Term fs_statx_pack(Env e, IoWork* w) {
  u32* f = (u32*)w->data;
  Term xs = term_pak(CID_Nil, 0);
  for (u32 i = BTAR_STATX_FIELDS; i > 0; i -= 1) {
    xs = io_node(e, CID_Con, (Term)f[i - 1], xs);
  }
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, xs));
}

Term fs_statx_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->text = io_cbuf(e, f[1], &len, CID(Con));
  w->data = io_mem(calloc(BTAR_STATX_FIELDS, sizeof(u32)));
  w->code = fs_name_ok(w->text, len) ? 0 : EINVAL;
  if (w->code) {
    return fs_statx_pack(e, w);
  }
  return fs_inline(e, w, fs_statx_call, fs_statx_pack);
}

// Fs.openat_read(dir, name) -> dir & Result<..., File>. Read-only source fd for
// the create-mode payload copy: O_RDONLY|O_NOFOLLOW|O_CLOEXEC under openat2
// RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS.
static void fs_openat_read_call(IoWork* w) {
  int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC;
  long n = btar_openat2((int)w->hand, w->data, (unsigned long long)flags, 0,
    RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
  if (n < 0 && errno == ENOSYS) {
    n = openat((int)w->hand, w->data, flags);
  }
  w->made = (intptr_t)io_sys_end(w, n);
}

static Term fs_openat_read_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, io_hand(w->made)));
}

Term fs_openat_read_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cbuf(e, f[1], &len, CID(Con));
  w->code = fs_name_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_openat_read_pack(e, w)
    : fs_inline(e, w, fs_openat_read_call, fs_openat_read_pack);
}

// Stream.write_zeros(fd, n) -> fd & Result<..., Unit>. EINTR-safe zero writes
// for 512-byte padding and the two end blocks (bounded 64 KiB scratch).
#define BTAR_ZERO_CHUNK (64u * 1024u)
static void stream_write_zeros_call(IoWork* w) {
  char* buf = w->data;
  u64 left = w->word, chunk = 0;
  memset(buf, 0, BTAR_ZERO_CHUNK);
  while (left > 0) {
    chunk = left < BTAR_ZERO_CHUNK ? left : BTAR_ZERO_CHUNK;
    ssize_t n = write((int)w->hand, buf, chunk);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      io_sys_end(w, n);
      return;
    }
    if (n == 0) {
      w->code = EIO;
      return;
    }
    left -= (u64)n;
  }
  w->code = 0;
}

Term stream_write_zeros_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[1];
  if (w->word == 0) {
    return fs_unit_pack(e, w);
  }
  w->data = io_mem(malloc(BTAR_ZERO_CHUNK));
  return fs_maybe_inline(e, w, stream_write_zeros_call, fs_unit_pack,
    fs_fd_out_ok((int)w->hand));
}

// Stream.read_file(fd) -> fd & Result<..., Bytes>; lseek(0) then read the whole
// file to EOF in 256 KiB chunks. Cap: 64 MiB (M5 compressed-input cap; a larger
// compressed archive is refused EFBIG before any pure-Bend inflation).
#define BTAR_READ_FILE_MAX (64u * 1024u * 1024u)

static void stream_read_file_call(IoWork* w) {
  if (lseek((int)w->hand, 0, SEEK_SET) < 0) {
    io_sys_end(w, -1);
    return;
  }
  u64 cap = 256u * 1024u, size = 0;
  char* buf = io_mem(malloc(cap));
  for (;;) {
    if (size == cap) {
      if (cap >= BTAR_READ_FILE_MAX) {
        w->code = EFBIG;
        w->data = buf;
        w->size = size;
        return;
      }
      cap = cap * 2 > BTAR_READ_FILE_MAX ? BTAR_READ_FILE_MAX : cap * 2;
      buf = io_mem(realloc(buf, cap));
    }
    ssize_t n = read((int)w->hand, buf + size, cap - size);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      w->data = buf;
      w->size = size;
      w->code = (u32)errno;
      return;
    }
    if (n == 0) {
      break;
    }
    size += (u64)n;
  }
  w->data = buf;
  w->size = size;
  w->code = 0;
}

static Term stream_read_file_pack(Env e, IoWork* w) {
  Term v = io_list(e, w->data, w->size);
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, v));
}

Term stream_read_file_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = NULL;
  w->size = 0;
  return io_work(w, stream_read_file_call, stream_read_file_pack);
}

// Stream.rewind(fd) -> fd & Result<..., Unit>; lseek(0), used by the gzip
// auto-detect probe so a plain tar keeps streaming from the start.
static void stream_rewind_call(IoWork* w) {
  io_sys_end(w, lseek((int)w->hand, 0, SEEK_SET));
}

Term stream_rewind_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  return fs_inline(e, w, stream_rewind_call, fs_unit_pack);
}

// Fs.open_rw(path) -> Result<..., File>; v1.2 append/update: open an archive
// read-write without truncating (O_CREAT: `-rf` on a missing file creates it,
// like GNU). The path is the CLI archive operand, same trust as File.open_bytes.
static void fs_open_rw_call(IoWork* w) {
  w->made = (intptr_t)io_sys_end(w,
    open(w->data, O_RDWR | O_CREAT | O_CLOEXEC, 0666));
}

Term fs_open_rw_run(Env e, Term* f, IoWork* w) {
  u64 len = 0;
  w->data = io_cbuf(e, f[0], &len, CID(Con));
  w->code = fs_path_ok(w->data, len) ? 0 : EINVAL;
  return w->code ? fs_open_dir_pack(e, w)
    : fs_inline(e, w, fs_open_rw_call, fs_open_dir_pack);
}

// Stream.seek(fd, off, whence) -> fd & Result<..., U32>; lseek with whence
// 0/1/2 (SET/CUR/END); the resulting offset must fit U32 (v1 4 GiB cap).
static void stream_seek_call(IoWork* w) {
  if (w->size > 2) {
    w->code = EINVAL;
    return;
  }
  off_t r = lseek((int)w->hand, (off_t)(uint32_t)w->word, (int)w->size);
  if (r < 0) {
    w->code = (u32)errno;
  } else if ((u64)r > (u64)UINT32_MAX) {
    w->code = EOVERFLOW;
  } else {
    w->code = 0;
    w->word = (uint32_t)r;
  }
}

static Term stream_seek_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, (Term)(uint32_t)w->word));
}

Term stream_seek_run(Env e, Term* f, IoWork* w) {
  // The work item is recycled: a File.open_bytes pack frees w->data without
  // clearing it, and stream_seek_pack's fs_clear would free it again.
  w->data = NULL;
  w->text = NULL;
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (uint32_t)f[1];
  w->size = (uint32_t)f[2];
  return fs_inline(e, w, stream_seek_call, stream_seek_pack);
}

// Fs.trunc_cur(fd) -> fd & Result<..., Unit>; truncate a regular file to the
// current offset (drops the stale tail after an in-place append). Anything
// that is not a regular file (pipe, /dev/null, tty) is left alone: success.
static void fs_trunc_cur_call(IoWork* w) {
  struct stat st;
  int fd = (int)w->hand;
  w->code = 0;
  if (fstat(fd, &st) != 0) {
    w->code = (u32)errno;
  } else if (S_ISREG(st.st_mode)) {
    off_t pos = lseek(fd, 0, SEEK_CUR);
    if (pos < 0 || ftruncate(fd, pos) != 0) {
      w->code = (u32)errno;
    }
  }
}

Term fs_trunc_cur_run(Env e, Term* f, IoWork* w) {
  w->data = NULL; // see stream_seek_run
  w->text = NULL;
  w->hand = (intptr_t)io_hand_v(f[0]);
  return fs_inline(e, w, fs_trunc_cur_call, fs_unit_pack);
}

// Fs.memfd_write(data) -> Result<..., File>; memfd_create + write all +
// lseek(0), returning a File opened at offset 0 (Linux-only; ENOSYS
// documented for other platforms).
#ifndef SYS_memfd_create
#define SYS_memfd_create 319
#endif

static void fs_memfd_write_call(IoWork* w) {
  long fd = syscall(SYS_memfd_create, "btar-tar", 1u /* MFD_CLOEXEC */);
  if (fd < 0) {
    w->code = (u32)errno;
    return;
  }
  char* p = w->data;
  u64 left = w->size;
  while (left > 0) {
    ssize_t n = write((int)fd, p, left);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      w->code = (u32)errno;
      close((int)fd);
      return;
    }
    if (n == 0) {
      w->code = EIO;
      close((int)fd);
      return;
    }
    p += n;
    left -= (u64)n;
  }
  if (lseek((int)fd, 0, SEEK_SET) < 0) {
    w->code = (u32)errno;
    close((int)fd);
    return;
  }
  w->made = (intptr_t)fd;
  w->code = 0;
}

static Term fs_memfd_write_pack(Env e, IoWork* w) {
  fs_clear(w);
  if (w->code != 0) {
    return io_res(e, w, io_hand(0));
  }
  return io_res(e, w, io_hand(w->made));
}

Term fs_memfd_write_run(Env e, Term* f, IoWork* w) {
  w->data = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = w->data == NULL ? EINVAL : 0;
  if (w->code != 0) {
    return fs_memfd_write_pack(e, w);
  }
  return fs_inline(e, w, fs_memfd_write_call, fs_memfd_write_pack);
}

// Fs.dup_file(fd) -> fd & Result<..., File>; a close-independent duplicate of
// a handle (used so the create writer may close its memfd copy while the app
// still reads the bytes back).
static void fs_dup_file_call(IoWork* w) {
  long n = fcntl((int)w->hand, F_DUPFD_CLOEXEC, 3);
  w->made = (intptr_t)io_sys_end(w, n);
}

static Term fs_dup_file_pack(Env e, IoWork* w) {
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, io_hand(w->made)));
}

Term fs_dup_file_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  return fs_inline(e, w, fs_dup_file_call, fs_dup_file_pack);
}

// Fs.pipe() -> Result<..., File & File>: (read end, write end), both
// close-on-exec.  Used to stream a gzip decoder into the tar reader.
static void fs_pipe_call(IoWork* w) {
  int p[2];
  if (pipe2(p, O_CLOEXEC) != 0) {
    w->code = (u32)errno;
    w->hand = 0;
    w->made = 0;
    return;
  }
  w->code = 0;
  w->hand = p[0];
  w->made = p[1];
}

static Term fs_pipe_pack(Env e, IoWork* w) {
  return io_res(e, w, io_tup(e, io_hand(w->hand), io_hand(w->made)));
}

Term fs_pipe_run(Env e, Term* f, IoWork* w) {
  return fs_inline(e, w, fs_pipe_call, fs_pipe_pack);
}

// Fs.fstatx(fd) -> fd & Result<..., List<U32>>; fstat of the handle itself in
// the same fixed field order as Fs.statx (root-directory metadata for create).
static void fs_fstatx_call(IoWork* w) {
  struct stat st;
  if (fstat((int)w->hand, &st) != 0) {
    w->code = (u32)errno;
    return;
  }
  if (st.st_size < 0 || st.st_size > (off_t)UINT32_MAX) {
    w->code = EOVERFLOW;
    return;
  }
  u32* f = (u32*)w->data;
  u64 ino = (u64)st.st_ino;
  u64 dev = (u64)st.st_dev;
  f[0] = (u32)((u64)(st.st_mode & S_IFMT) >> 12);
  f[1] = (u32)(st.st_mode & 07777);
  f[2] = (u32)st.st_nlink;
  f[3] = (u32)st.st_uid;
  f[4] = (u32)st.st_gid;
  f[5] = (u32)st.st_size;
  f[6] = (u32)st.st_mtim.tv_sec;
  f[7] = (u32)(ino & 0xffffffffu);
  f[8] = (u32)(ino >> 32);
  f[9] = (u32)(dev & 0xffffffffu);
  f[10] = (u32)(dev >> 32);
  w->code = 0;
}

static Term fs_fstatx_pack(Env e, IoWork* w) {
  u32* f = (u32*)w->data;
  Term xs = term_pak(CID_Nil, 0);
  for (u32 i = BTAR_STATX_FIELDS; i > 0; i -= 1) {
    xs = io_node(e, CID_Con, (Term)f[i - 1], xs);
  }
  fs_clear(w);
  return io_tup(e, io_hand(w->hand), io_res(e, w, xs));
}

Term fs_fstatx_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_mem(calloc(BTAR_STATX_FIELDS, sizeof(u32)));
  return fs_inline(e, w, fs_fstatx_call, fs_fstatx_pack);
}

// Fs.stat_path(path) -> Result<..., List<U32>>; lstat of a whole path (create
// operands: Bend composes "<-C root>/<operand>"; absolute/.. operands are
// refused before calling). Same 11-field order as Fs.statx/Fs.fstatx.
static void fs_stat_path_call(IoWork* w) {
  struct stat st;
  int n = lstat((const char*)w->text, &st);
  w->code = n != 0 ? (u32)errno : 0;
  if (n != 0) {
    return;
  }
  if (st.st_size < 0 || st.st_size > (off_t)UINT32_MAX) {
    w->code = EOVERFLOW;
    return;
  }
  u32* f = (u32*)w->data;
  u64 ino = (u64)st.st_ino;
  u64 dev = (u64)st.st_dev;
  f[0] = (u32)((u64)(st.st_mode & S_IFMT) >> 12);
  f[1] = (u32)(st.st_mode & 07777);
  f[2] = (u32)st.st_nlink;
  f[3] = (u32)st.st_uid;
  f[4] = (u32)st.st_gid;
  f[5] = (u32)st.st_size;
  f[6] = (u32)st.st_mtim.tv_sec;
  f[7] = (u32)(ino & 0xffffffffu);
  f[8] = (u32)(ino >> 32);
  f[9] = (u32)(dev & 0xffffffffu);
  f[10] = (u32)(dev >> 32);
  w->code = 0;
}

static Term fs_stat_path_pack(Env e, IoWork* w) {
  u32* f = (u32*)w->data;
  Term xs = term_pak(CID_Nil, 0);
  for (u32 i = BTAR_STATX_FIELDS; i > 0; i -= 1) {
    xs = io_node(e, CID_Con, (Term)f[i - 1], xs);
  }
  fs_clear(w);
  return io_res(e, w, xs);
}

Term fs_stat_path_run(Env e, Term* f, IoWork* w) {
  w->text = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = (w->text == NULL || w->size == 0) ? EINVAL : 0;
  if (w->code != 0) {
    return fs_stat_path_pack(e, w);
  }
  w->data = io_mem(calloc(BTAR_STATX_FIELDS, sizeof(u32)));
  return fs_inline(e, w, fs_stat_path_call, fs_stat_path_pack);
}

// Fs.readlink_path(path) -> Result<..., Bytes>; readlink of a whole path
// (create-mode symlink operands; absolute/.. operands refused before this).
static void fs_readlink_path_call(IoWork* w) {
  u64 cap = 4096, got = 0;
  char* buf = io_mem(malloc(cap));
  for (;;) {
    ssize_t n = readlink((const char*)w->text, buf + got, cap - got);
    if (n < 0) {
      w->code = (u32)errno;
      w->data = buf;
      w->size = 0;
      return;
    }
    if ((u64)n < cap - got) {
      got += (u64)n;
      break;
    }
    got = cap;
    if (cap >= 65536) {
      w->code = ENAMETOOLONG;
      w->data = buf;
      w->size = 0;
      return;
    }
    cap *= 2;
    buf = io_mem(realloc(buf, cap));
  }
  w->data = buf;
  w->size = got;
  w->code = 0;
}

static Term fs_readlink_path_pack(Env e, IoWork* w) {
  Term v = io_list(e, w->data, w->size);
  fs_clear(w);
  return io_res(e, w, v);
}

Term fs_readlink_path_run(Env e, Term* f, IoWork* w) {
  w->text = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = (w->text == NULL || w->size == 0) ? EINVAL : 0;
  if (w->code != 0) {
    return fs_readlink_path_pack(e, w);
  }
  return fs_inline(e, w, fs_readlink_path_call, fs_readlink_path_pack);
}

// Registration: one constructor, each row guarded so a program that uses a
// Registration: one constructor, each row guarded so a program that uses a
// Registration: one constructor, each row guarded so a program that uses a
// subset still compiles (an unused effect has no CID in C).
static void __attribute__((constructor)) btar_fs_use(void) {
#ifdef CID(Fs.open_dir)
  io_eff(CID(Fs.open_dir), fs_open_dir_run);
#endif
#ifdef CID(Fs.openat_dir)
  io_eff(CID(Fs.openat_dir), fs_openat_dir_run);
#endif
#ifdef CID(Fs.openat_file)
  io_eff(CID(Fs.openat_file), fs_openat_file_run);
#endif
#ifdef CID(Fs.mkdirat)
  io_eff(CID(Fs.mkdirat), fs_mkdirat_run);
#endif
#ifdef CID(Fs.symlinkat)
  io_eff(CID(Fs.symlinkat), fs_symlinkat_run);
#endif
#ifdef CID(Fs.linkat)
  io_eff(CID(Fs.linkat), fs_linkat_run);
#endif
#ifdef CID(Fs.fstatat)
  io_eff(CID(Fs.fstatat), fs_fstatat_run);
#endif
#ifdef CID(Fs.readlinkat)
  io_eff(CID(Fs.readlinkat), fs_readlinkat_run);
#endif
#ifdef CID(Fs.readdir)
  io_eff(CID(Fs.readdir), fs_readdir_run);
#endif
#ifdef CID(Fs.unlinkat)
  io_eff(CID(Fs.unlinkat), fs_unlinkat_run);
#endif
#ifdef CID(Fs.fchmodat)
  io_eff(CID(Fs.fchmodat), fs_fchmodat_run);
#endif
#ifdef CID(Fs.utimensat)
  io_eff(CID(Fs.utimensat), fs_utimensat_run);
#endif
#ifdef CID(Fs.renameat)
  io_eff(CID(Fs.renameat), fs_renameat_run);
#endif
#ifdef CID(Fs.mkdir_path)
  io_eff(CID(Fs.mkdir_path), fs_mkdir_path_run);
#endif
#ifdef CID(Fs.linkat_at)
  io_eff(CID(Fs.linkat_at), fs_linkat_at_run);
#endif
#ifdef CID(Fs.statx)
  io_eff(CID(Fs.statx), fs_statx_run);
#endif
#ifdef CID(Fs.openat_read)
  io_eff(CID(Fs.openat_read), fs_openat_read_run);
#endif
#ifdef CID(Stream.write_zeros)
  io_eff(CID(Stream.write_zeros), stream_write_zeros_run);
#endif
#ifdef CID(Stream.read_file)
  io_eff(CID(Stream.read_file), stream_read_file_run);
#endif
#ifdef CID(Stream.rewind)
  io_eff(CID(Stream.rewind), stream_rewind_run);
#endif
#ifdef CID(Fs.open_rw)
  io_eff(CID(Fs.open_rw), fs_open_rw_run);
#endif
#ifdef CID(Stream.seek)
  io_eff(CID(Stream.seek), stream_seek_run);
#endif
#ifdef CID(Fs.trunc_cur)
  io_eff(CID(Fs.trunc_cur), fs_trunc_cur_run);
#endif
#ifdef CID(Fs.memfd_write)
  io_eff(CID(Fs.memfd_write), fs_memfd_write_run);
#endif
#ifdef CID(Fs.dup_file)
  io_eff(CID(Fs.dup_file), fs_dup_file_run);
#endif
#ifdef CID(Fs.pipe)
  io_eff(CID(Fs.pipe), fs_pipe_run);
#endif
#ifdef CID(Fs.fstatx)
  io_eff(CID(Fs.fstatx), fs_fstatx_run);
#endif
#ifdef CID(Fs.stat_path)
  io_eff(CID(Fs.stat_path), fs_stat_path_run);
#endif
#ifdef CID(Fs.readlink_path)
  io_eff(CID(Fs.readlink_path), fs_readlink_path_run);
#endif
#ifdef CID(Fs.tzoff)
  io_eff(CID(Fs.tzoff), fs_tzoff_run);
#endif
#ifdef CID(Fs.id_name)
  io_eff(CID(Fs.id_name), fs_id_name_run);
#endif
#ifdef CID(Fs.name_id)
  io_eff(CID(Fs.name_id), fs_name_id_run);
#endif
#ifdef CID(Fs.euid)
  io_eff(CID(Fs.euid), fs_euid_run);
#endif
#ifdef CID(Data.copy_stdout)
  io_eff(CID(Data.copy_stdout), data_copy_stdout_run);
#endif
#ifdef CID(Data.cmp)
  io_eff(CID(Data.cmp), data_cmp_run);
#endif
#ifdef CID(Data.copy_eof)
  io_eff(CID(Data.copy_eof), data_copy_eof_run);
#endif
#ifdef CID(Data.copy)
  io_eff(CID(Data.copy), data_copy_run);
#endif
#ifdef CID(Stream.read_exact)
  io_eff(CID(Stream.read_exact), stream_read_exact_run);
#endif
#ifdef CID(Stream.read_seg)
  io_eff(CID(Stream.read_seg), stream_read_seg_run);
#endif
#ifdef CID(Stream.write_bytes)
  io_eff(CID(Stream.write_bytes), stream_write_bytes_run);
#endif
}

#endif // BTAR_EFFS_FS_C
