import Base
import ../effs/effects.bend as Fx

def bytes_of(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{code}, rest}:
      code <> bytes_of(rest)

def result_dir(p: File & Result<&1, &1, U32 & String, Unit>) -> File:
  (f, _) = p
  f

def filedir(p: File & Result<&1, &1, U32 & String, File>) -> File:
  (f, _) = p
  f

def run() -> IO(Unit):
  do IO<Unit>:
    root : File <- IO.try(File, Fx.Fs.open_dir(bytes_of("/tmp")))
    made : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Fs.mkdirat(root, bytes_of("btar-m2-dir"), 493)
    root2 : File = result_dir(made)
    sub : File & Result<&1, &1, U32 & String, File> <-
      Fx.Fs.openat_dir(root2, bytes_of("btar-m2-dir"))
    sub2 : File = filedir(sub)
    IO.print("openat_dir ok")
    File.close(sub2)

def main() -> IO(Unit):
  do IO<Unit>:
    run()
