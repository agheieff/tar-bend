# tests/test_path.bend — pure path policy (Pth.safe / Pth.strip).
import Base
import ../src/path.bend as Pth
import ../src/bytes.bend as B
import ./lib.bend as T

def ok(
  r: Result<&1, &1, Pth.Err, List<&2, U32>>, want: List<&2, U32>, msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (rejected: " ++ Pth.err_show(e) ++ ")")
    case Done{v}:
      T.check(B.eq_list(v, want, True{}), msg)

def bad(
  r: Result<&1, &1, Pth.Err, List<&2, U32>>, msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.pure(Unit, Unit{})
    case Done{v}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (accepted: [" ++
        B.list_show(v) ++ "])")

def bad_abs(r: Result<&1, &1, Pth.Err, List<&2, U32>>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Pth.Absolute{}:
          IO.pure(Unit, Unit{})
        case Pth.Empty{}:
          IO.die(Unit, 1, "FAIL: expected Absolute, got Empty")
        case Pth.Parent{}:
          IO.die(Unit, 1, "FAIL: expected Absolute, got Parent")
        case Pth.TooLong{}:
          IO.die(Unit, 1, "FAIL: expected Absolute, got TooLong")
        case Pth.BadComponent{}:
          IO.die(Unit, 1, "FAIL: expected Absolute, got BadComponent")
    case Done{v}:
      IO.die(Unit, 1, "FAIL: expected Absolute, accepted path")

def bad_parent(r: Result<&1, &1, Pth.Err, List<&2, U32>>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Pth.Parent{}:
          IO.pure(Unit, Unit{})
        case Pth.Empty{}:
          IO.die(Unit, 1, "FAIL: expected Parent, got Empty")
        case Pth.Absolute{}:
          IO.die(Unit, 1, "FAIL: expected Parent, got Absolute")
        case Pth.TooLong{}:
          IO.die(Unit, 1, "FAIL: expected Parent, got TooLong")
        case Pth.BadComponent{}:
          IO.die(Unit, 1, "FAIL: expected Parent, got BadComponent")
    case Done{v}:
      IO.die(Unit, 1, "FAIL: expected Parent, accepted path")

def bad_comp(r: Result<&1, &1, Pth.Err, List<&2, U32>>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Pth.BadComponent{}:
          IO.pure(Unit, Unit{})
        case Pth.Empty{}:
          IO.die(Unit, 1, "FAIL: expected BadComponent, got Empty")
        case Pth.Absolute{}:
          IO.die(Unit, 1, "FAIL: expected BadComponent, got Absolute")
        case Pth.Parent{}:
          IO.die(Unit, 1, "FAIL: expected BadComponent, got Parent")
        case Pth.TooLong{}:
          IO.die(Unit, 1, "FAIL: expected BadComponent, got TooLong")
    case Done{v}:
      IO.die(Unit, 1, "FAIL: expected BadComponent, accepted path")

def bad_long(r: Result<&1, &1, Pth.Err, List<&2, U32>>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Pth.TooLong{}:
          IO.pure(Unit, Unit{})
        case Pth.Empty{}:
          IO.die(Unit, 1, "FAIL: expected TooLong, got Empty")
        case Pth.Absolute{}:
          IO.die(Unit, 1, "FAIL: expected TooLong, got Absolute")
        case Pth.Parent{}:
          IO.die(Unit, 1, "FAIL: expected TooLong, got Parent")
        case Pth.BadComponent{}:
          IO.die(Unit, 1, "FAIL: expected TooLong, got BadComponent")
    case Done{v}:
      IO.die(Unit, 1, "FAIL: expected TooLong, accepted path")

def paths() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- ok(Pth.safe(255, 4096, [97, 98, 99]), [97, 98, 99], "simple")
    b : Unit <- ok(Pth.safe(255, 4096, [97, 47, 98]), [97, 47, 98], "a/b")
    c : Unit <- ok(Pth.safe(255, 4096, [46, 47, 97]), [97], "./a")
    d : Unit <- ok(Pth.safe(255, 4096, [97, 47, 46, 47, 98]), [97, 47, 98],
      "a/./b")
    e : Unit <- ok(Pth.safe(255, 4096, [97, 47, 98, 47]), [97, 47, 98],
      "trailing slash")
    f : Unit <- ok(Pth.safe(255, 4096, [97, 47, 47, 98]), [97, 47, 98],
      "empty component")
    g : Unit <- ok(Pth.safe(255, 4096, Nil{}), Nil{}, "empty name")
    h : Unit <- ok(Pth.safe(255, 4096, [46]), Nil{}, "dot name")
    i : Unit <- ok(Pth.safe(255, 4096, [97, 46, 47, 98]), [97, 46, 47, 98],
      "dot inside component")
    IO.pure(Unit, Unit{})

def rejects() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- bad_abs(Pth.safe(255, 4096, [47, 97]))
    b : Unit <- bad_abs(Pth.safe(255, 4096, [47]))
    c : Unit <- bad_parent(Pth.safe(255, 4096, [46, 46]))
    d : Unit <- bad_parent(Pth.safe(255, 4096, [97, 47, 46, 46, 47, 98]))
    e : Unit <- bad_comp(Pth.safe(2, 4096, [97, 98, 99]))
    f : Unit <- bad_comp(Pth.safe(255, 4096, [97, 0, 98]))
    g : Unit <- bad_long(Pth.safe(255, 5, [97, 98, 47, 99, 100, 47, 101]))
    IO.pure(Unit, Unit{})

def strips() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.check(B.eq_list(Pth.strip(0, [97, 47, 98]), [97, 47, 98],
      True{}), "strip 0")
    b : Unit <- T.check(B.eq_list(Pth.strip(1, [97, 47, 98]), [98], True{}),
      "strip 1 of a/b")
    c : Unit <- T.check(B.eq_list(Pth.strip(2, [97, 47, 98]), Nil{}, True{}),
      "strip 2 of a/b")
    d : Unit <- T.check(B.eq_list(Pth.strip(9, [97, 47, 98]), Nil{}, True{}),
      "strip n>count")
    e : Unit <- T.check(B.eq_list(Pth.strip(1, [97]), Nil{}, True{}),
      "strip 1 of a")
    f : Unit <- T.check(B.eq_list(
      Pth.strip(1, [97, 47, 98, 47, 99]), [98, 47, 99], True{}),
      "strip 1 of a/b/c")
    g : Unit <- T.check(B.eq_list(Pth.strip(2, [97, 47, 47, 98]), [98],
      True{}), "strip 2 of a//b")
    IO.pure(Unit, Unit{})

def main() -> IO(Unit):
  do IO<Unit>:
    u0 : Unit <- paths()
    u1 : Unit <- rejects()
    u2 : Unit <- strips()
    IO.print("test_path: OK")
