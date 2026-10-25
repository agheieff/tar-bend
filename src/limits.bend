# Module: Lim — pure extraction limits and counters (no effects, no @unsafe).
#
# Defaults from plan §5.7.  All counters are U32 and every transition is
# overflow-checked: a state can only be built through `new_state`/`add_member`
# and `add_member` checks the total before adding, so `bytes + size` cannot
# wrap.  Limits are checked exactly at the boundary: adding a member when the
# count is already at the limit, or a size that would pass the total, fails.

import Base

type Limits is Data:
  MkLimits{
    max_members: U32,
    max_total: U32,
    max_member: U32,
    max_name: U32,
    max_pax: U32
  }

# 1,000,000 members; U32 cap for total/member (4 GiB v1 limit documented);
# 4096-byte names/links; 64 KiB pax/longname payloads.
type State is Data:
  MkState{limits: Limits, members: U32, bytes: U32}

type Err is Data:
  Members{}
  Total{}
  Member{}
  Name{}
  Pax{}

# ---- add_member --------------------------------------------------------

def default_limits() -> Limits:
  MkLimits{1000000, 4294967295, 4294967295, 4096, 65536}

def new_state(+limits: Limits) -> State:
  MkState{limits, 0, 0}

def add_total(
  limits: Limits,
  members: U32,
  bytes: U32,
  size: U32,
  total_bad: Bool
) -> Result<&1, &1, Err, State>:
  match total_bad:
    case True{}:
      Fail{Total{}}
    case False{}:
      +members2 = U32.inc(members)
      +bytes2 = U32.add(bytes, size)
      Done{MkState{limits, members2, bytes2}}

# Check per-member size, member count and total bytes; on success add.
def add_count(
  limits: Limits,
  members: U32,
  bytes: U32,
  size: U32,
  count_bad: Bool,
  total_bad: Bool
) -> Result<&1, &1, Err, State>:
  match count_bad:
    case True{}:
      Fail{Members{}}
    case False{}:
      add_total(limits, members, bytes, size, total_bad)

def add_ok(
  limits: Limits,
  members: U32,
  bytes: U32,
  +size: U32,
  member_bad: Bool,
  count_bad: Bool,
  total_bad: Bool
) -> Result<&1, &1, Err, State>:
  match member_bad:
    case True{}:
      Fail{Member{}}
    case False{}:
      add_count(limits, members, bytes, size, count_bad, total_bad)

def max_members(limits: Limits) -> U32:
  match limits:
    case MkLimits{a, _, _, _, _}:
      a

def max_total(limits: Limits) -> U32:
  match limits:
    case MkLimits{_, a, _, _, _}:
      a

def max_member(limits: Limits) -> U32:
  match limits:
    case MkLimits{_, _, a, _, _}:
      a

def max_name(limits: Limits) -> U32:
  match limits:
    case MkLimits{_, _, _, a, _}:
      a

def max_pax(limits: Limits) -> U32:
  match limits:
    case MkLimits{_, _, _, _, a}:
      a
def add_go(
  +limits: Limits, +members: U32, +bytes: U32, +size: U32
) -> Result<&1, &1, Err, State>:
  match limits:
    case MkLimits{+max_members, +max_total, +max_member, +max_name, +max_pax}:
      +member_bad = U32.is_gt(size, max_member)
      +count_bad = U32.is_ge(members, max_members)
      +total_bad = Bool.or(U32.is_gt(size, max_total),
        U32.is_gt(bytes, U32.sub(max_total, size)))
      add_ok(MkLimits{max_members, max_total, max_member, max_name, max_pax},
        members, bytes, size, member_bad, count_bad, total_bad)

# ---- name / pax payload checks ----------------------------------------

def add_member(
  +st: State, +size: U32
) -> Result<&1, &1, Err, State>:
  match st:
    case MkState{limits, members, bytes}:
      add_go(limits, members, bytes, size)

def name_ok(
  st: State, len: U32, bad: Bool
) -> Result<&1, &1, Err, State>:
  match bad:
    case True{}:
      Fail{Name{}}
    case False{}:
      Done{st}

def check_name_go(
  st: State, limits: Limits, +len: U32
) -> Result<&1, &1, Err, State>:
  match limits:
    case MkLimits{max_members, max_total, max_member, max_name, max_pax}:
      name_ok(st, len, U32.is_gt(len, max_name))

def check_name(
  +st: State, +len: U32
) -> Result<&1, &1, Err, State>:
  match st:
    case MkState{limits, members, bytes}:
      check_name_go(st, limits, len)

def pax_ok(
  st: State, len: U32, bad: Bool
) -> Result<&1, &1, Err, State>:
  match bad:
    case True{}:
      Fail{Pax{}}
    case False{}:
      Done{st}

def check_pax_go(
  st: State, limits: Limits, +len: U32
) -> Result<&1, &1, Err, State>:
  match limits:
    case MkLimits{max_members, max_total, max_member, max_name, max_pax}:
      pax_ok(st, len, U32.is_gt(len, max_pax))
def check_pax(
  +st: State, +len: U32
) -> Result<&1, &1, Err, State>:
  match st:
    case MkState{limits, members, bytes}:
      check_pax_go(st, limits, len)


def member_count(st: State) -> U32:
  match st:
    case MkState{_, members, _}:
      members

def byte_count(st: State) -> U32:
  match st:
    case MkState{_, _, bytes}:
      bytes

