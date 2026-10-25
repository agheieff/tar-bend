# M0 effect declarations for tar-bend. Each body is the two imports; the twins
# in ../effs/fs.c and ../effs/fs.js register under these names. Bytes =
# List<&2, U32> until a Bytes module exists (docs/effects.md).
#
# Every handle-taking effect answers `handle & Result<...>` and the handle
# comes back on failure too (affine handles). A handle-producing effect
# (open_dir) answers only the Result.

def Fs.open_dir(path: List<&2, U32>) ->
  IO(Result<&1, &1, U32 & String, File>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.openat_file(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, File>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.mkdirat(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.symlinkat(dir: File, name: List<&2, U32>, target: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.linkat(dir: File, old: List<&2, U32>, new: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.fstatat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, U32 & U32>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.readlinkat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.readdir(dir: File) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.unlinkat(dir: File, name: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.fchmodat(dir: File, name: List<&2, U32>, mode: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.utimensat(dir: File, name: List<&2, U32>, mtime: U32) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.renameat(dir: File, from: List<&2, U32>, to: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Fs.mkdir_path(path: List<&2, U32>, mode: U32) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Data.copy(in: File, out: File, size: U32) ->
  IO(File & (File & Result<&1, &1, U32 & String, Unit>)):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Stream.read_exact(fd: File, n: U32) ->
  IO(File & Result<&1, &1, U32 & String, List<&2, U32>>):
  import "../effs/fs.c"
  import "../effs/fs.js"

def Stream.write_bytes(fd: File, bytes: List<&2, U32>) ->
  IO(File & Result<&1, &1, U32 & String, Unit>):
  import "../effs/fs.c"
  import "../effs/fs.js"
