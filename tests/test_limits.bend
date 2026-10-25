# tests/test_limits.bend — pure limits and counters (Lim).
import Base
import ../src/limits.bend as Lim
import ./lib.bend as T

def small() -> Lim.Limits:
  Lim.MkLimits{2, 10, 4, 3, 2}

def done_state(
  r: Result<&1, &1, Lim.Err, Lim.State>, +want_members: U32,
  +want_bytes: U32, +msg: String
) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (unexpected Fail)")
    case Done{+s}:
      do IO<Unit>:
        a : Unit <- T.check_u32(Lim.member_count(s), want_members,
          msg ++ ": members")
        T.check_u32(Lim.byte_count(s), want_bytes, msg ++ ": bytes")

def fail_members(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Lim.Members{}:
          IO.pure(Unit, Unit{})
        case Lim.Total{}:
          IO.die(Unit, 1, "FAIL: expected Members, got Total")
        case Lim.Member{}:
          IO.die(Unit, 1, "FAIL: expected Members, got Member")
        case Lim.Name{}:
          IO.die(Unit, 1, "FAIL: expected Members, got Name")
        case Lim.Pax{}:
          IO.die(Unit, 1, "FAIL: expected Members, got Pax")
    case Done{s}:
      IO.die(Unit, 1, "FAIL: expected Members, accepted")

def fail_member(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Lim.Member{}:
          IO.pure(Unit, Unit{})
        case Lim.Members{}:
          IO.die(Unit, 1, "FAIL: expected Member, got Members")
        case Lim.Total{}:
          IO.die(Unit, 1, "FAIL: expected Member, got Total")
        case Lim.Name{}:
          IO.die(Unit, 1, "FAIL: expected Member, got Name")
        case Lim.Pax{}:
          IO.die(Unit, 1, "FAIL: expected Member, got Pax")
    case Done{s}:
      IO.die(Unit, 1, "FAIL: expected Member, accepted")

def fail_total(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Lim.Total{}:
          IO.pure(Unit, Unit{})
        case Lim.Members{}:
          IO.die(Unit, 1, "FAIL: expected Total, got Members")
        case Lim.Member{}:
          IO.die(Unit, 1, "FAIL: expected Total, got Member")
        case Lim.Name{}:
          IO.die(Unit, 1, "FAIL: expected Total, got Name")
        case Lim.Pax{}:
          IO.die(Unit, 1, "FAIL: expected Total, got Pax")
    case Done{s}:
      IO.die(Unit, 1, "FAIL: expected Total, accepted")

def fail_name(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Lim.Name{}:
          IO.pure(Unit, Unit{})
        case Lim.Members{}:
          IO.die(Unit, 1, "FAIL: expected Name, got Members")
        case Lim.Total{}:
          IO.die(Unit, 1, "FAIL: expected Name, got Total")
        case Lim.Member{}:
          IO.die(Unit, 1, "FAIL: expected Name, got Member")
        case Lim.Pax{}:
          IO.die(Unit, 1, "FAIL: expected Name, got Pax")
    case Done{s}:
      IO.die(Unit, 1, "FAIL: expected Name, accepted")

def fail_pax(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Unit):
  match r:
    case Fail{e}:
      match e:
        case Lim.Pax{}:
          IO.pure(Unit, Unit{})
        case Lim.Members{}:
          IO.die(Unit, 1, "FAIL: expected Pax, got Members")
        case Lim.Total{}:
          IO.die(Unit, 1, "FAIL: expected Pax, got Total")
        case Lim.Member{}:
          IO.die(Unit, 1, "FAIL: expected Pax, got Member")
        case Lim.Name{}:
          IO.die(Unit, 1, "FAIL: expected Pax, got Name")
    case Done{s}:
      IO.die(Unit, 1, "FAIL: expected Pax, accepted")

def defaults_ok() -> Bool:
  +l = Lim.default_limits()
  +s = Lim.new_state(l)
  +a = Bool.and(U32.is_eq(Lim.max_members(l), 1000000),
    U32.is_eq(Lim.max_total(l), 4294967295))
  +b = Bool.and(U32.is_eq(Lim.max_member(l), 4294967295),
    U32.is_eq(Lim.max_name(l), 4096))
  +c = Bool.and(U32.is_eq(Lim.max_pax(l), 65536),
    U32.is_eq(Lim.member_count(s), 0))
  Bool.and(Bool.and(a, b), Bool.and(c, U32.is_eq(Lim.byte_count(s), 0)))

def defaults() -> IO(Unit):
  T.check(defaults_ok(), "default limits/new_state")

def state_of(r: Result<&1, &1, Lim.Err, Lim.State>) -> Lim.State:
  match r:
    case Fail{e}:
      Lim.new_state(small())
    case Done{s}:
      s

def two_state() -> Lim.State:
  state_of(Lim.add_member(state_of(Lim.add_member(Lim.new_state(small()), 4)),
    3))

def full_total_state() -> Lim.State:
  state_of(Lim.add_member(state_of(Lim.add_member(Lim.new_state(small()), 4)),
    6))

def adds_ok() -> Bool:
  +s = two_state()
  Bool.and(U32.is_eq(Lim.member_count(s), 2), U32.is_eq(Lim.byte_count(s), 7))

def adds() -> IO(Unit):
  T.check(adds_ok(), "add members: count/bytes")

def total_limits() -> Lim.Limits:
  Lim.MkLimits{10, 10, 100, 3, 2}

def boundaries() -> IO(Unit):
  +s = two_state()
  do IO<Unit>:
    a : Unit <- fail_member(Lim.add_member(Lim.new_state(small()), 5))
    b : Unit <- fail_total(Lim.add_member(
      state_of(Lim.add_member(Lim.new_state(total_limits()), 8)), 4))
    c : Unit <- fail_members(Lim.add_member(s, 0))
    d : Unit <- T.check(
      Bool.and(U32.is_eq(Lim.member_count(two_state()), 2),
        U32.is_eq(Lim.byte_count(two_state()), 7)), "two members/7 bytes")
    e : Unit <- done_state(Lim.add_member(
      state_of(Lim.add_member(Lim.new_state(total_limits()), 8)), 2), 2, 10,
      "total at limit = 10 bytes")
    IO.pure(Unit, Unit{})

def big_limits() -> Lim.Limits:
  Lim.MkLimits{10, 4294967295, 4294967295, 4096, 65536}

def max_state() -> Lim.State:
  state_of(Lim.add_member(Lim.new_state(big_limits()), 4294967295))

def overflow() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.check(Bool.and(
      U32.is_eq(Lim.member_count(max_state()), 1),
      U32.is_eq(Lim.byte_count(max_state()), 4294967295)),
      "U32-max member accepted without wrap")
    b : Unit <- fail_total(Lim.add_member(max_state(), 1))
    IO.pure(Unit, Unit{})

def names_pax() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.check_u32(Lim.max_name(small()), 3, "small max_name")
    b : Unit <- done_state(Lim.check_name(Lim.new_state(small()), 3), 0, 0,
      "name at limit")
    c : Unit <- fail_name(Lim.check_name(Lim.new_state(small()), 4))
    d : Unit <- done_state(Lim.check_pax(Lim.new_state(small()), 2), 0, 0,
      "pax at limit")
    e : Unit <- fail_pax(Lim.check_pax(Lim.new_state(small()), 3))
    IO.pure(Unit, Unit{})

def main() -> IO(Unit):
  do IO<Unit>:
    u0 : Unit <- defaults()
    u1 : Unit <- adds()
    u2 : Unit <- boundaries()
    u3 : Unit <- overflow()
    u4 : Unit <- names_pax()
    IO.print("test_limits: OK")
