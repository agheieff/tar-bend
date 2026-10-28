# src/rewrite.bend — `btar --delete` and `btar -A`: in-place archive rewrites.
#
# Both work on raw archive bytes, never re-encoding a member: --delete moves
# the kept byte runs down inside the file, -A copies the logical contents of
# other archives (up to their first zero block) onto the end of the first.
# All validation (scans) happens before the archive is opened for writing.
# Effectful (trusted-adjacent), outside the proof core.
import Base
import ./bytes.bend as B
import ./upd.bend as U
import ./glob.bend as Glob
import ./append.bend as Ap
import ./read_stream.bend as R
import ./write.bend as Wr
import ../effs/effects.bend as Fx

# ---- seek / copy helpers --------------------------------------------------

def seek_ok(pr: File & Result<&1, &1, U32 & String, U32>) -> IO(File):
  (f, r) = pr
  match r:
    case Done{pos}:
      IO.pure(File, f)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: seek archive: " ++ msg)

def seek_to(f: File, off: U32) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, U32> <- Fx.Stream.seek(f, off, 0)
    seek_ok(pr)

# Closes the source, hands the destination back.
def copy_done(pr: File & (File & Result<&1, &1, U32 & String, Unit>)) ->
  IO(File):
  (src, rest) = pr
  (dst, r) = rest
  match r:
    case Done{u}:
      do IO<File>:
        u2 : Unit <- File.close(src)
        IO.pure(File, dst)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: copy: " ++ msg)

def copy_fds(s: File, d: File, len: U32) -> IO(File):
  do IO<File>:
    pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
      Fx.Data.copy(s, d, len)
    copy_done(pr)

def copy_open(src: File, dst: File, from: U32, to: U32, len: U32) -> IO(File):
  do IO<File>:
    s : File <- seek_to(src, from)
    d : File <- seek_to(dst, to)
    copy_fds(s, d, len)

# Copy `len` bytes from offset `from` of the file at `path` to offset `to` of
# `dst`; the source is opened and closed here.
def copy_path(path: List<&2, U32>, dst: File, from: U32, to: U32, len: U32) ->
  IO(File):
  do IO<File>:
    r : File <- IO.try(File, File.open_bytes(path, "r"))
    copy_open(r, dst, from, to, len)

# Zero blocks + cut at the write position, then close.
def finish_archive(w: File, pos: U32) -> IO(Unit):
  do IO<Unit>:
    w1 : File <- seek_to(w, pos)
    w2 : File <- Wr.wz(w1, 1024)
    w3 : File <- Wr.wtrunc(w2)
    File.close(w3)

def finish_wp(wp: File & U32) -> IO(Unit):
  (w, pos) = wp
  finish_archive(w, pos)

# ---- --delete ---------------------------------------------------------------

type Run is Data:
  MkRun{start: U32, len: U32}

# Plan state: kept runs (newest first), the open run, operands not yet matched
# and the number of deleted members.
type Plan is Data:
  MkPlan{runs: List<&2, Run>, rs: U32, rl: U32, left: List<&2, List<&2, U32>>,
    ndel: U32}

def close_run2(zero: Bool, +rs: U32, +rl: U32, runs: List<&2, Run>) ->
  List<&2, Run>:
  match zero:
    case True{}:
      runs
    case False{}:
      MkRun{rs, rl} <> runs

def close_run(+rs: U32, +rl: U32, runs: List<&2, Run>) -> List<&2, Run>:
  close_run2(U32.is_zero(rl), rs, rl, runs)

def plan_del(del: Bool, +prev: U32, +e: U32, pl: Plan, +raw: List<&2, U32>) ->
  Plan:
  match del:
    case True{}:
      match pl:
        case MkPlan{runs, rs, rl, left, ndel}:
          MkPlan{close_run(rs, rl, runs), 0, 0, Glob.unmatched(left, raw),
            U32.add(ndel, 1)}
    case False{}:
      match pl:
        case MkPlan{runs, rs, +rl, left, ndel}:
          MkPlan{runs, Bool.pick(U32, U32.is_zero(rl), prev, rs),
            U32.add(rl, U32.sub(e, prev)), left, ndel}

def plan_step(+pl: Plan, +prev: U32, +a: U.Am,
  +ops: List<&2, List<&2, U32>>) -> Plan:
  plan_del(Glob.selected(ops, U.am_raw(a)), prev, U.am_end(a), pl,
    U.am_raw(a))

def plan_all(fuel: Nat, spans: List<&2, U.Am>, prev: U32, pl: Plan,
  +ops: List<&2, List<&2, U32>>) -> Plan:
  match fuel:
    case 0n:
      pl
    case 1n+p:
      match spans:
        case Nil{}:
          pl
        case +a <> t:
          plan_all(p, t, U.am_end(a), plan_step(pl, prev, a, ops), ops)

def plan_fin(pl: Plan) -> Plan:
  match pl:
    case MkPlan{runs, +rs, rl, left, ndel}:
      MkPlan{close_run(rs, rl, runs), rs, 0, left, ndel}

def plan_ndel(pl: Plan) -> U32:
  match pl:
    case MkPlan{_, _, _, _, n}:
      n

def plan_left(pl: Plan) -> List<&2, List<&2, U32>>:
  match pl:
    case MkPlan{_, _, _, l, _}:
      l

def plan_runs(pl: Plan) -> List<&2, Run>:
  match pl:
    case MkPlan{r, _, _, _, _}:
      r

def rev_runs(xs: List<&2, Run>, acc: List<&2, Run>) -> List<&2, Run>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_runs(t, h <> acc)

def move_one(inplace: Bool, arch: List<&2, U32>, w: File, s: U32, wpos: U32,
  l: U32) -> IO(File):
  match inplace:
    case True{}:
      IO.pure(File, w)
    case False{}:
      copy_path(arch, w, s, wpos, l)

# Move each kept run down to the write position; a run already in place needs
# no copy.  wpos <= start always, so the in-file move never overwrites unread
# data.  Returns the file and the final write position.
def move_runs(fuel: Nat, +arch: List<&2, U32>, w: File, +wpos: U32,
  runs: List<&2, Run>) -> IO(File & U32):
  match fuel:
    case 0n:
      IO.die(File & U32, 2, "btar: archive has too many members")
    case 1n+p:
      match runs:
        case Nil{}:
          IO.pure(File & U32, (w, wpos))
        case MkRun{+s, +l} <> t:
          do IO<File & U32>:
            w2 : File <- move_one(U32.is_eq(s, wpos), arch, w, s, wpos, l)
            move_runs(p, arch, w2, U32.add(wpos, l), t)

def apply_plan(+arch: List<&2, U32>, runs: List<&2, Run>) -> IO(Unit):
  do IO<Unit>:
    rr : Result<&1, &1, U32 & String, File> <- Fx.Fs.open_rw(arch)
    w : File <- Wr.rpair(rr)
    wp : File & U32 <- move_runs(1048576n, arch, w, 0, runs)
    finish_wp(wp)

def delete_apply2(none: Bool, +arch: List<&2, U32>, runs: List<&2, Run>) ->
  IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      apply_plan(arch, runs)

def delete_apply(n: U32, +arch: List<&2, U32>, runs: List<&2, Run>) -> IO(Unit):
  delete_apply2(U32.is_zero(n), arch, runs)

def delete_plan(+arch: List<&2, U32>, +pl: Plan) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- delete_apply(plan_ndel(pl), arch, rev_runs(plan_runs(pl), Nil{}))
    R.finish_left(plan_left(pl), 0)

def delete_ops(+arch: List<&2, U32>, +sc: Ap.Scan,
  +ops: List<&2, List<&2, U32>>) -> IO(Unit):
  delete_plan(arch, plan_fin(plan_all(
    Nat.add(U32.to_nat(Ap.scan_end(sc)), 1n), U.tab_spans(Ap.scan_tab(sc)), 0,
    MkPlan{Nil{}, 0, 0, ops, 0}, ops)))

# `ops` empty deletes nothing (and does not touch the archive).
def delete_go(+arch: List<&2, U32>, ops: List<&2, List<&2, U32>>) -> IO(Unit):
  match ops:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case _ <> _:
      do IO<Unit>:
        sc : Ap.Scan <- Ap.scan(arch, True{})
        delete_ops(arch, sc, ops)

# ---- -A / --concatenate ------------------------------------------------------

type Src is Data:
  MkSrc{path: List<&2, U32>, end: U32}

# GNU -A needs both archives to exist (Ap.scan alone would treat a missing
# file as an empty archive).
def must_exist2(pr: Result<&1, &1, U32 & String, List<&2, U32>>,
  path: List<&2, U32>) -> IO(Unit):
  match pr:
    case Done{st}:
      IO.pure(Unit, Unit{})
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: " ++ B.list_show(path) ++ ": " ++ msg)

def must_exist(+path: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    pr : Result<&1, &1, U32 & String, List<&2, U32>> <- Fx.Fs.stat_path(path)
    must_exist2(pr, path)

def scan_srcs(fuel: Nat, srcs: List<&2, List<&2, U32>>, acc: List<&2, Src>) ->
  IO(List<&2, Src>):
  match fuel:
    case 0n:
      IO.die(List<&2, Src>, 2, "btar: too many archives")
    case 1n+p:
      match srcs:
        case Nil{}:
          IO.pure(List<&2, Src>, acc)
        case +s <> t:
          do IO<List<&2, Src>>:
            u : Unit <- must_exist(s)
            sc : Ap.Scan <- Ap.scan(s, False{})
            scan_srcs(p, t, MkSrc{s, Ap.scan_end(sc)} <> acc)

def rev_srcs(xs: List<&2, Src>, acc: List<&2, Src>) -> List<&2, Src>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_srcs(t, h <> acc)

def cat_srcs(fuel: Nat, w: File, +pos: U32, srcs: List<&2, Src>) ->
  IO(File & U32):
  match fuel:
    case 0n:
      IO.die(File & U32, 2, "btar: too many archives")
    case 1n+p:
      match srcs:
        case Nil{}:
          IO.pure(File & U32, (w, pos))
        case MkSrc{path, +end} <> t:
          do IO<File & U32>:
            w2 : File <- copy_path(path, w, 0, pos, end)
            cat_srcs(p, w2, U32.add(pos, end), t)

def cat_write(+arch: List<&2, U32>, dend: U32, srcs: List<&2, Src>) ->
  IO(Unit):
  do IO<Unit>:
    rr : Result<&1, &1, U32 & String, File> <- Fx.Fs.open_rw(arch)
    w : File <- Wr.rpair(rr)
    wp : File & U32 <- cat_srcs(1048576n, w, dend, rev_srcs(srcs, Nil{}))
    finish_wp(wp)

def cat_dest(+arch: List<&2, U32>, scanned: List<&2, Src>) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- must_exist(arch)
    sc : Ap.Scan <- Ap.scan(arch, False{})
    cat_write(arch, Ap.scan_end(sc), scanned)

# Every archive is scanned (and so validated) before the destination is opened
# for writing.
def concat_go(+arch: List<&2, U32>, srcs: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    scanned : List<&2, Src> <- scan_srcs(1048576n, srcs, Nil{})
    cat_dest(arch, scanned)
