# M0 throughput probe: Data.copy (C read/write loop) vs the shell's cp on the
# same page-cached file. Build/run:
#   bend spike/copy_bench.bend -o /tmp/btar-copybench
#   rm -rf /tmp/btar-bench && /tmp/btar-copybench /path/to/src.bin copy.bin
# Wrapper defs exist because a do-block cannot destructure a tuple let (the
# same shape note as spike/fs_effects.bend).
import Base
import ./effects.bend as Fx

def bstr(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bstr(t)

def nth(xs: List<&1, List<&2, U32>>, k: Nat) -> List<&2, U32>:
  match xs k:
    case Nil{} _:
      Nil{}
    case h <> t 0n:
      h
    case _ <> t 1n+p:
      nth(t, p)

def open_root() -> IO(File):
  do IO<File>:
    u : Unit <- IO.try(Unit, Fx.Fs.mkdir_path(bstr("/tmp/btar-bench"), 493))
    IO.try(File, Fx.Fs.open_dir(bstr("/tmp/btar-bench")))

def copy_done(z: File & (File & Result<&1, &1, U32 & String, Unit>), d: File,
  n: U32) -> IO(File):
  (a, rest) = z
  (b, r) = rest
  match r:
    case Done{u}:
      do IO<File>:
        File.close(a)
        File.close(b)
        IO.print("copied " ++ U32.show(n) ++ " bytes byte-exactly")
        IO.pure(File, d)
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def copy_open(q: File & Result<&1, &1, U32 & String, File>, i: File, +n: U32)
  -> IO(File):
  (d, r) = q
  match r:
    case Done{o}:
      IO.bind(File & (File & Result<&1, &1, U32 & String, Unit>), File,
        Fx.Data.copy(i, o, n), z => copy_done(z, d, n))
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def copy_size(p: File & Result<&1, &1, U32 & String, U32>, d0: File,
  name: List<&2, U32>) -> IO(File):
  (i, r) = p
  match r:
    case Done{n}:
      IO.bind(File & Result<&1, &1, U32 & String, File>, File,
        Fx.Fs.openat_file(d0, name, 420), q => copy_open(q, i, n))
    case Fail{(code, msg)}:
      IO.die(File, code, msg)

def copy_rest(d0: File, in: File, name: List<&2, U32>) -> IO(File):
  IO.bind(File & Result<&1, &1, U32 & String, U32>, File,
    File.size(in), p => copy_size(p, d0, name))

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<&1, List<&2, U32>> <- IO.args_bytes()
    d0 : File <- open_root()
    in : File <- IO.try(File, File.open_bytes(nth(args, 1n), "r"))
    t0 : Nat <- IO.now()
    d1 : File <- copy_rest(d0, in, bstr("copy.bin"))
    t1 : Nat <- IO.now()
    File.close(d1)
    IO.print("Data.copy wall time: " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms")
