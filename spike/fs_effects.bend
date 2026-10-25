# M0 demo: the tar filesystem/data-plane effect layer, native. Build:
#   bend spike/fs_effects.bend -o /tmp/btar-spike
#   rm -rf /tmp/btar-spike-root && /tmp/btar-spike
# then inspect /tmp/btar-spike-root with find/stat/readlink/cmp (docs/effects.md).
# Reset is the caller's job: openat_file is O_CREAT|O_EXCL, so leftovers fail.
#
# Shape note: a do-block in Bend 2.0.39 cannot destructure a tuple let or bind
# a `handle & Result` pair, and a `match` may only head a def body. So every
# pair-returning effect goes through a small helper def here; the effect API
# itself stays the affine `handle & Result` shape (docs/effects.md).
import Base
import ./effects.bend as Fx

# ---- pure helpers ----------------------------------------------------------

def bstr(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bstr(t)

def eqb(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Nil{} _:
      False{}
    case _ Nil{}:
      False{}
    case h1 <> t1 h2 <> t2:
      Bool.and(U32.is_eq(h1, h2), eqb(t1, t2))

def app(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  match a:
    case Nil{}:
      b
    case h <> t:
      h <> app(t, b)

def rootp() -> List<&2, U32>:
  bstr("/tmp/btar-spike-root/")

def path(name: String) -> List<&2, U32>:
  app(rootp(), bstr(name))

# 512-byte header pattern: byte(index) = (index * 37 + 11) mod 256. The Nat is
# recursion fuel only; the byte counter is a reusable U32.
def mkhead(i: Nat, +j: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match i:
    case 0n:
      acc
    case 1n+p:
      mkhead(p, U32.add(j, 1),
        U32.mod(U32.add(U32.mul(j, 37), 11), 256) <> acc)

def reps(k: Nat, +xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      reps(p, xs, app(xs, acc))

def ncount(xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      (1n + ncount(t) : Nat)

def blen(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      (1n + blen(t) : Nat)

def assert_ok(cond: Bool, msg: String) -> IO(Unit):
  match cond:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, msg)

# ---- single-handle Result helpers -----------------------------------------

def unit_ok(r: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match r:
    case Done{u}:
      IO.pure(Unit, Unit{})
    case Fail{(code, msg)}:
      IO.die(Unit, code, msg)

def file_ok(r: Result<&1, &1, U32 & String, File>) -> IO(File):
  match r:
    case Done{f}:
      IO.pure(File, f)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def keep(p: File & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (f, r) = p
  do IO<File>:
    u : Unit <- unit_ok(r)
    IO.pure(File, f)

# An IO action that takes a handle and returns `handle & Result` flows through
# these one-line wrappers; the underlying effect keeps the affine pair shape.
def unit_op(act: IO(File & Result<&1, &1, U32 & String, Unit>)) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, Unit>, File, act, p => keep(p))

# ---- pair-returning effect handlers ---------------------------------------

def write_new_got(p: File & Result<&1, &1, U32 & String, File>,
  bs: List<&2, U32>) -> IO(File):
  (d, r) = p
  match r:
    case Done{f}:
      do IO<File>:
        f2 : File <- unit_op(Fx.Stream.write_bytes(f, bs))
        File.close(f2)
        IO.pure(File, d)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def write_new(d0: File, name: List<&2, U32>, mode: U32, bs: List<&2, U32>)
  -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, File>, File,
    Fx.Fs.openat_file(d0, name, mode), p => write_new_got(p, bs))

def read_exact_got(p: File & Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(List<&2, U32>):
  (f, r) = p
  match r:
    case Done{bs}:
      do IO<List<&2, U32>>:
        File.close(f)
        IO.pure(List<&2, U32>, bs)
    case Fail{(code, msg)}:
      IO.die(List<&2, U32>, code, msg)

def read_exact_close(f: File, n: U32) -> IO(List<&2, U32>):
  IO.bind(File & Result<&1, &1, U32 & String, List<&2, U32>>, List<&2, U32>,
    Fx.Stream.read_exact(f, n), p => read_exact_got(p))

def copy_got(q: File & (File & Result<&1, &1, U32 & String, Unit>),
  d: File) -> IO(File):
  (i, rest) = q
  (o, r) = rest
  match r:
    case Done{u}:
      do IO<File>:
        File.close(i)
        File.close(o)
        IO.pure(File, d)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def copy_open_got(p: File & Result<&1, &1, U32 & String, File>, in: File,
  size: U32) -> IO(File):
  (d, r) = p
  match r:
    case Done{out}:
      IO.bind(File & (File & Result<&1, &1, U32 & String, Unit>), File,
        Fx.Data.copy(in, out, size), q => copy_got(q, d))
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def copy_close(d0: File, in: File, name: List<&2, U32>, size: U32) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, File>, File,
    Fx.Fs.openat_file(d0, name, 420), p => copy_open_got(p, in, size))

# ---- observation handlers --------------------------------------------------

def check_readlink(p: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  want: List<&2, U32>) -> IO(File):
  (d, r) = p
  match r:
    case Done{bs}:
      do IO<File>:
        u : Unit <- assert_ok(eqb(bs, want), "readlink target wrong")
        IO.pure(File, d)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def readlink_op(act: IO(File & Result<&1, &1, U32 & String, List<&2, U32>>),
  want: List<&2, U32>) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, List<&2, U32>>, File,
    act, p => check_readlink(p, want))

# meta = (type << 12) | mode; regular = type 8, 0640 = 416, 0644 = 420.
def stat_check(d: File, v: U32 & U32, want_size: U32, want_mode: U32) ->
  IO(File):
  (meta0, size0) = v
  +meta : U32 = meta0
  +size : U32 = size0
  do IO<File>:
    u0 : Unit <- assert_ok(U32.is_eq(U32.div(meta, 4096), 8), "not regular")
    u1 : Unit <- assert_ok(U32.is_eq(U32.and(meta, 4095), want_mode),
      "mode mismatch")
    u2 : Unit <- assert_ok(U32.is_eq(size, want_size), "size mismatch")
    IO.pure(File, d)

def stat_ok(p: File & Result<&1, &1, U32 & String, U32 & U32>, want_size: U32,
  want_mode: U32) -> IO(File):
  (d, r) = p
  match r:
    case Done{v}:
      stat_check(d, v, want_size, want_mode)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def noent_ok(p: File & Result<&1, &1, U32 & String, U32 & U32>) -> IO(File):
  (d, r) = p
  match r:
    case Fail{(code, msg)}:
      do IO<File>:
        u : Unit <- assert_ok(U32.is_eq(code, 2), "want ENOENT(2)")
        IO.pure(File, d)
    case Done{v}:
      IO.die(File, 1, "fstatat should have failed with ENOENT")

def noent_op(act: IO(File & Result<&1, &1, U32 & String, U32 & U32>)) ->
  IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, U32 & U32>, File,
    act, p => noent_ok(p))

def check_names(p: File & Result<&1, &1, U32 & String,
  List<&2, List<&2, U32>>>, want: Nat) -> IO(File):
  (d, r) = p
  match r:
    case Done{ns}:
      do IO<File>:
        u : Unit <- assert_ok(Nat.is_eq(ncount(ns), want), "readdir count wrong")
        IO.pure(File, d)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def stat_op(act: IO(File & Result<&1, &1, U32 & String, U32 & U32>),
  want_size: U32, want_mode: U32) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, U32 & U32>, File,
    act, p => stat_ok(p, want_size, want_mode))

def names_op(act: IO(File & Result<&1, &1, U32 & String,
  List<&2, List<&2, U32>>>), want: Nat) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>, File,
    act, p => check_names(p, want))

# ---- scenario stages (each threads the destination dir handle) -------------

def open_root() -> IO(File):
  do IO<File>:
    u : Unit <- IO.try(Unit, Fx.Fs.mkdir_path(bstr("/tmp/btar-spike-root"), 493))
    IO.try(File, Fx.Fs.open_dir(bstr("/tmp/btar-spike-root")))

def make_tree(d0: File, hdr: List<&2, U32>) -> IO(File):
  do IO<File>:
    d1 : File <- unit_op(Fx.Fs.mkdirat(d0, bstr("sub"), 493))
    d2 : File <- write_new(d1, bstr("file.bin"), 420, hdr)
    d3 : File <- unit_op(Fx.Fs.fchmodat(d2, bstr("file.bin"), 416))
    d4 : File <- unit_op(Fx.Fs.utimensat(d3, bstr("file.bin"), 1234567890))
    d5 : File <- unit_op(Fx.Fs.symlinkat(d4, bstr("link"), bstr("file.bin")))
    d6 : File <- unit_op(Fx.Fs.linkat(d5, bstr("file.bin"), bstr("hard.bin")))
    IO.print("mkdirat/openat_file/write_bytes/fchmodat/utimensat ok")
    IO.print("symlinkat/linkat ok")
    IO.pure(File, d6)

def observe(d0: File) -> IO(File):
  do IO<File>:
    d1 : File <- readlink_op(Fx.Fs.readlinkat(d0, bstr("link")),
      bstr("file.bin"))
    IO.print("readlinkat ok: link -> file.bin")
    d2 : File <- stat_op(Fx.Fs.fstatat(d1, bstr("file.bin")), 512, 416)
    IO.print("fstatat ok: regular, mode 0640, size 512")
    d3 : File <- names_op(Fx.Fs.readdir(d2), 4n)
    IO.print("readdir ok: 4 entries (sub, file.bin, link, hard.bin)")
    IO.pure(File, d3)

def write_payload(d0: File, pay: List<&2, U32>) -> IO(File):
  do IO<File>:
    d1 : File <- write_new(d0, bstr("payload.bin"), 420, pay)
    IO.print("write_bytes ok: payload.bin = 4096 bytes")
    IO.pure(File, d1)

def copy_payload(d0: File, size: U32) -> IO(File):
  do IO<File>:
    in : File <- IO.try(File, File.open_bytes(path("payload.bin"), "r"))
    d1 : File <- copy_close(d0, in, bstr("copy.bin"), size)
    IO.print("Data.copy ok: payload.bin -> copy.bin, 4096 bytes")
    IO.pure(File, d1)

def header_roundtrip(d0: File, +hdr: List<&2, U32>) -> IO(File):
  do IO<File>:
    d1 : File <- write_new(d0, bstr("expected.bin"), 420, hdr)
    in : File <- IO.try(File, File.open_bytes(path("file.bin"), "r"))
    +back : List<&2, U32> <- read_exact_close(in, 512)
    u0 : Unit <- assert_ok(Nat.is_eq(blen(back), 512n), "read_exact short")
    u1 : Unit <- assert_ok(eqb(back, hdr), "512-byte header round trip differs")
    IO.print("header round trip ok: 512 bytes written, read_exact == input")
    IO.pure(File, d1)

def verify_payload(d0: File, +pay: List<&2, U32>) -> IO(File):
  do IO<File>:
    f1 : File <- IO.try(File, File.open_bytes(path("payload.bin"), "r"))
    src : List<&2, U32> <- read_exact_close(f1, 4096)
    f2 : File <- IO.try(File, File.open_bytes(path("copy.bin"), "r"))
    cpy : List<&2, U32> <- read_exact_close(f2, 4096)
    u0 : Unit <- assert_ok(eqb(src, pay), "payload bytes differ from expected")
    u1 : Unit <- assert_ok(eqb(cpy, pay), "copy bytes differ (not byte-exact)")
    IO.print("read_exact ok: payload and copy both match expected 4096 bytes")
    IO.pure(File, d0)

def mutate(d0: File) -> IO(File):
  do IO<File>:
    d1 : File <- unit_op(Fx.Fs.unlinkat(d0, bstr("hard.bin")))
    d2 : File <- noent_op(Fx.Fs.fstatat(d1, bstr("hard.bin")))
    IO.print("unlinkat ok: hard.bin gone, fstatat gives ENOENT")
    d3 : File <- unit_op(Fx.Fs.renameat(d2, bstr("copy.bin"), bstr("renamed.bin")))
    d4 : File <- stat_op(Fx.Fs.fstatat(d3, bstr("renamed.bin")), 4096, 420)
    IO.print("renameat ok: copy.bin -> renamed.bin")
    d5 : File <- names_op(Fx.Fs.readdir(d4), 6n)
    IO.print("readdir ok: 6 entries after mutation")
    IO.pure(File, d5)

def main() -> IO(Unit):
  do IO<Unit>:
    +hdr : List<&2, U32> = mkhead(512n, 0, Nil{})
    +pay : List<&2, U32> = reps(8n, hdr, Nil{})
    d0 : File <- open_root()
    d1 : File <- make_tree(d0, hdr)
    d2 : File <- observe(d1)
    d3 : File <- write_payload(d2, pay)
    d4 : File <- copy_payload(d3, 4096)
    d5 : File <- header_roundtrip(d4, hdr)
    d6 : File <- verify_payload(d5, pay)
    d7 : File <- mutate(d6)
    File.close(d7)
    IO.print("SPIKE OK: fs + data-plane effects verified")
