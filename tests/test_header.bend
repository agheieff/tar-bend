# tests/test_header.bend — canonical ustar header parse + validation.
import Base
import ../src/header.bend as H
import ../src/bytes.bend as B
import ./canon_ustar.bend as Canon
import ./lib.bend as T

def is_regular(t: H.Tag) -> Bool:
  match t:
    case H.KRegular{}:
      True{}
    case H.KHardlink{}:
      False{}
    case H.KSymlink{}:
      False{}
    case H.KChar{}:
      False{}
    case H.KBlock{}:
      False{}
    case H.KDir{}:
      False{}
    case H.KFifo{}:
      False{}
    case H.KContig{}:
      False{}
    case H.KPaxLocal{}:
      False{}
    case H.KPaxGlobal{}:
      False{}
    case H.KLongName{}:
      False{}
    case H.KLongLink{}:
      False{}
    case H.KOther{}:
      False{}

def show_header(+h: H.Header) -> IO(Unit):
  do IO<Unit>:
    +name : Unit <- T.check(
      B.eq_list(H.h_name(h), [97, 46, 116, 120, 116], True{}),
      "name = a.txt")
    +size : Unit <- T.check_u32(H.h_size(h), 6, "size")
    +typef : Unit <- T.check_u32(H.h_typeflag(h), 48, "typeflag '0'")
    +tag : Unit <- T.check(is_regular(H.classify_header(h)), "classify regular")
    +full : Unit <- T.check(
      B.eq_list(H.full_name(h), [97, 46, 116, 120, 116], True{}),
      "full_name without prefix")
    IO.pure(Unit, Unit{})

def expect_ok(r: Result<&1, &1, String, H.Header>) -> IO(Unit):
  match r:
    case Fail{msg}:
      IO.die(Unit, 1, "FAIL: header parse rejected: " ++ msg)
    case Done{h}:
      show_header(h)

def expect_fail(r: Result<&1, &1, String, H.Header>) -> IO(Unit):
  match r:
    case Fail{msg}:
      IO.pure(Unit, Unit{})
    case Done{h}:
      IO.die(Unit, 1, "FAIL: expected rejected header, got a Header")

def corrupt(xs: List<&2, U32>) -> List<&2, U32>:
  List.set(&2, U32, xs, 0n, 122)

def main() -> IO(Unit):
  +xs = Canon.block()
  +bad = corrupt(xs)
  do IO<Unit>:
    u0 : Unit <- expect_ok(H.parse(B.from_list(xs)))
    u1 : Unit <- expect_fail(H.parse(B.from_list(bad)))
    IO.print("test_header: OK")
