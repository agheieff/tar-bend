# Canonical effect declarations for tar-bend (M2+). Each body is the two imports; the twins
# in ../effs/fs.c and ../effs/fs.js register under these names. Bytes =
# List<&2, U32> until a Bytes module exists (docs/effects.md).
#
# Every handle-taking effect answers `handle & Result<...>` and the handle
# comes back on failure too (affine handles). A handle-producing effect
# (open_dir) answers only the Result.

def Fs.open_dir(path: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Fs.openat_dir(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Fs.openat_file(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Fs.mkdirat(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.symlinkat(dir: File, name: List<&2, U32>, target: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.linkat(dir: File, old: List<&2, U32>, new: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.fstatat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, U32 & U32>):
  import "./fs.c"
  import "./fs.js"

def Fs.readlinkat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.readdir(dir: File) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>):
  import "./fs.c"
  import "./fs.js"

def Fs.unlinkat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.fchmodat(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.utimensat(dir: File, name: List<&2, U32>, mtime: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.renameat(dir: File, from: List<&2, U32>, to: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.mkdir_path(path: List<&2, U32>, mode: U32) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.linkat_at(from_dir: File, from_name: List<&2, U32>, to_dir: File,
  to_name: List<&2, U32>) ->
  IO(File & (File & Result<&1, &1, U32 & String, Unit>)):
  import "./fs.c"
  import "./fs.js"

def Fs.tzoff(t: U32) -> IO(U32):
  import "./fs.c"
  import "./fs.js"

def Fs.id_name(kind: U32, id: U32) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.name_id(kind: U32, name: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, U32>):
  import "./fs.c"
  import "./fs.js"

def Fs.euid() -> IO(U32):
  import "./fs.c"
  import "./fs.js"

def Fs.statx(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.fstatx(fd: File) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.stat_path(path: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.readlink_path(path: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Fs.memfd_write(data: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Fs.dup_file(fd: File) ->
  IO(File & Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Fs.open_rw(path: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Stream.seek(fd: File, off: U32, whence: U32) ->
  IO(File & Result<&1, &1, U32 & String, U32>):
  import "./fs.c"
  import "./fs.js"

def Fs.trunc_cur(fd: File) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Fs.pipe() ->
  IO(Result<&1, &1, U32 & String, File & File>):
  import "./fs.c"
  import "./fs.js"

def Fs.openat_read(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, File>):
  import "./fs.c"
  import "./fs.js"

def Data.copy(in: File, out: File, size: U32) ->
  IO(File & (File & Result<&1, &1, U32 & String, Unit>)):
  import "./fs.c"
  import "./fs.js"

def Data.cmp(in: File, file: File, size: U32) ->
  IO(File & (File & Result<&1, &1, U32 & String, U32>)):
  import "./fs.c"
  import "./fs.js"

def Data.copy_eof(in: File, out: File) ->
  IO(File & (File & Result<&1, &1, U32 & String, Unit>)):
  import "./fs.c"
  import "./fs.js"

def Data.copy_stdout(in: File, size: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Stream.read_exact(fd: File, n: U32) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Stream.read_seg(fd: File, n: U32, tail: U32) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32> & List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Stream.write_bytes(fd: File, bytes: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Stream.write_zeros(fd: File, n: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Stream.read_file(fd: File) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./fs.c"
  import "./fs.js"

def Stream.rewind(fd: File) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./fs.c"
  import "./fs.js"

def Stdout.write(data: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./out.c"
  import "./out.js"
