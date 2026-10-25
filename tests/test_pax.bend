# tests/test_pax.bend — pax extended header records.
import Base
import ../src/pax.bend as P
import ../src/bytes.bend as B
import ./lib.bend as T

def expect_none(m: Maybe<&2, List<&2, U32>>, msg: String) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{v}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected None)")

def expect_some(
  m: Maybe<&2, List<&2, U32>>, want: List<&2, U32>, msg: String
) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected Some)")
    case Some{v}:
      T.check(B.eq_list(v, want, True{}), msg)

def show2(
  path: Maybe<&2, List<&2, U32>>,
  linkpath: Maybe<&2, List<&2, U32>>,
  size: Maybe<&2, List<&2, U32>>,
  mtime: Maybe<&2, List<&2, U32>>
) -> IO(Unit):
  do IO<Unit>:
    a : Unit <- expect_some(path, [97, 98, 99], "path=abc")
    b : Unit <- expect_none(linkpath, "linkpath absent")
    c : Unit <- expect_some(size, [52, 50], "size=42")
    d : Unit <- expect_none(mtime, "mtime absent")
    IO.pure(Unit, Unit{})

def show(p: P.Pax) -> IO(Unit):
  match p:
    case P.MkPax{path, linkpath, size, mtime, uid, gid, uname, gname}:
      show2(path, linkpath, size, mtime)

def show_bad(p: P.Pax) -> IO(Unit):
  match p:
    case P.MkPax{path, linkpath, size, mtime, uid, gid, uname, gname}:
      expect_none(path, "malformed record path ignored")

def show_unknown(p: P.Pax) -> IO(Unit):
  match p:
    case P.MkPax{path, linkpath, size, mtime, uid, gid, uname, gname}:
      expect_none(path, "unknown key does not set path")

# path=abc and size=42 records
def payload() -> List<&2, U32>:
  49 <> (50 <> (32 <> (112 <> (97 <> (116 <> (104 <> (61 <> (97 <> (98 <> (99 <> (10 <> (49 <> (49 <> (32 <> (115 <> (105 <> (122 <> (101 <> (61 <> (52 <> (50 <> (10 <> (Nil{})))))))))))))))))))))))

# unknown key only
def unknown_payload() -> List<&2, U32>:
  49 <> (49 <> (32 <> (102 <> (111 <> (111 <> (61 <> (98 <> (97 <> (114 <> (10 <> (Nil{})))))))))))

# malformed length prefix
def bad_payload() -> List<&2, U32>:
  57 <> (57 <> (32 <> (112 <> (97 <> (116 <> (104 <> (61 <> (97 <> (98 <> (99 <> (10 <> (Nil{}))))))))))))

def main() -> IO(Unit):
  +p = P.parse(unknown_payload())
  +bad = P.parse(bad_payload())
  do IO<Unit>:
    u0 : Unit <- show(P.parse(payload()))
    u1 : Unit <- show_unknown(p)
    u2 : Unit <- show_bad(bad)
    IO.print("test_pax: OK")
