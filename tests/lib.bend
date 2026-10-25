# tests/lib.bend — tiny assertion helpers (no test framework: IO.die on fail).

import Base
import ../src/bytes.bend as Bytes

def check(ok: Bool, msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "FAIL: " ++ msg)

def check_u32(+got: U32, +want: U32, msg: String) -> IO(Unit):
  check(U32.is_eq(got, want),
    msg ++ " (got " ++ U32.show(got) ++ ", want " ++ U32.show(want) ++ ")")

def some_u32(m: Maybe<&2, U32>, +want: U32, msg: String) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected Some{" ++
        U32.show(want) ++ "}, got None)")
    case Some{v}:
      check_u32(v, want, msg)

def none_u32(m: Maybe<&2, U32>, msg: String) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{v}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected None, got " ++
        U32.show(v) ++ ")")

def some_list(
  m: Maybe<&2, List<&2, U32>>, +want: List<&2, U32>, msg: String
) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected Some, got None)")
    case Some{v}:
      check(Bytes.eq_list(v, want, True{}), msg)

def none_list(m: Maybe<&2, List<&2, U32>>, msg: String) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{v}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected None)")

def check_nat(+got: Nat, +want: Nat, msg: String) -> IO(Unit):
  check(Nat.is_eq(got, want),
    msg ++ " (got " ++ Nat.show(got) ++ ", want " ++ Nat.show(want) ++ ")")
