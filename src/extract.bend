# Module: Extract — dirfd-relative extraction primitives (M2).
#
# Path policy is pure and lives here: Pth normalisation (reject absolute / ".."
# / overlong), component splitting, hardlink target checks.  Effect steps are
# dirfd-relative: Fs.open_dir / Fs.openat_dir / Fs.mkdirat / Fs.openat_file /
# Fs.symlinkat / Fs.linkat / Fs.unlinkat / Fs.fchmodat / Fs.utimensat with
# O_NOFOLLOW and openat2 RESOLVE_NO_SYMLINKS: no symlink is ever followed.
#
# Handles: one entry costs one `opened` list, head = current parent directory,
# tail = its ancestors.  The chain is opened from the root path at entry start
# and closed when the entry completes; no handle is ever duplicated, so every
# effect returns exactly the chain/result it was given (affine-clean).
#
# No mutual recursion: every loop is one def with `fuel` first that calls only
# itself.  Bend 2.0.39 matches only parameters/fields, so computed conditions
# go through helpers taking a Bool.
import Base
import ./bytes.bend as B
import ./path.bend as Pth
import ../effs/effects.bend as Fx

# Only one thunk runs; affine captures in the other branch are dropped.
def ifu(-A: Type, c: Bool, t: Unit -> A, f: Unit -> A) -> A:
  match c:
    case True{}:
      t(Unit{})
    case False{}:
      f(Unit{})

# ---- pure path helpers -----------------------------------------------------

# Split a Pth.safe-normalised relative path into components. One recursive
# step machine (fuel first) because a match cannot scrutinise a computed pair.
type Ss is Type:
  SsScan{
    rest: List<&2, U32>,
    cur: List<&2, U32>,
    acc: List<&1, List<&2, U32>>
  }
  SsFin{out: List<&1, List<&2, U32>>}

def split_add(cur: List<&2, U32>, acc: List<&1, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  match cur:
    case Nil{}:
      acc
    case _ <> _:
      B.list_rev(cur, Nil{}) <> acc

def split_byte(
  c: Bool, h: U32, rest: List<&2, U32>, cur: List<&2, U32>,
  acc: List<&1, List<&2, U32>>
) -> Ss:
  match c:
    case True{}:
      SsScan{rest, Nil{}, split_add(cur, acc)}
    case False{}:
      SsScan{rest, h <> cur, acc}

def rev_comps(
  fuel: Nat, xs: List<&1, List<&2, U32>>,
  acc: List<&1, List<&2, U32>>
) -> List<&1, List<&2, U32>>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case h <> t:
          rev_comps(p, t, h <> acc)

def split_fin(
  fuel: Nat, cur: List<&2, U32>, acc: List<&1, List<&2, U32>>
) -> List<&1, List<&2, U32>>:
  rev_comps(8192n, split_add(cur, acc), Nil{})

def split_step(fuel: Nat, st: Ss) -> List<&1, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match st:
        case SsFin{out}:
          out
        case SsScan{rest, cur, acc}:
          match rest:
            case Nil{}:
              split_fin(p, cur, acc)
            case +h <> +t:
              split_step(p,
                split_byte(U32.is_eq(h, 47), h, t, cur, acc))

def split(fuel: Nat, name: List<&2, U32>) -> List<&1, List<&2, U32>>:
  split_step(fuel, SsScan{name, Nil{}, Nil{}})

def no_last(comps: List<&1, List<&2, U32>>) -> List<&1, List<&2, U32>>:
  match comps:
    case Nil{}:
      Nil{}
    case h <> t:
      match t:
        case Nil{}:
          Nil{}
        case _:
          h <> no_last(t)

def last_comp(comps: List<&1, List<&2, U32>>) -> List<&2, U32>:
  match comps:
    case Nil{}:
      Nil{}
    case h <> t:
      match t:
        case Nil{}:
          h
        case _:
          last_comp(t)

def same_go(
  fuel: Nat, a: List<&1, List<&2, U32>>, b: List<&1, List<&2, U32>>
) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match a b:
        case Nil{} Nil{}:
          True{}
        case Nil{} _:
          False{}
        case _ Nil{}:
          False{}
        case ha <> ta hb <> tb:
          Bool.and(B.eq_list(ha, hb, True{}), same_go(p, ta, tb))

# 8192 components is past the 4096-byte total-path limit: a safe fuel bound.

def same_parent(
  a: List<&1, List<&2, U32>>, b: List<&1, List<&2, U32>>
) -> Bool:
  same_go(8192n, a, b)

def seen_go(
  fuel: Nat, +path: List<&2, U32>, seen: List<&1, List<&2, U32>>, hit: Bool
) -> Bool:
  match fuel:
    case 0n:
      hit
    case 1n+p:
      match seen:
        case Nil{}:
          hit
        case h <> t:
          seen_go(p, path, t, Bool.or(hit, B.eq_list(path, h, True{})))

# Previously extracted regular file (only those may be hardlink targets).

def seen_has(
  +path: List<&2, U32>, seen: List<&1, List<&2, U32>>
) -> Bool:
  seen_go(8192n, path, seen, False{})


# Ancestors + final component of a component list (used by the driver's walk
# plan; one recursive def, so the input is consumed exactly once).
type Ends is Type:
  MkEnds{anc: List<&1, List<&2, U32>>, last: List<&2, U32>}

def ends_prev(
  fuel: Nat, prev: List<&2, U32>, rest: List<&1, List<&2, U32>>,
  acc: List<&1, List<&2, U32>>
) -> Ends:
  match fuel:
    case 0n:
      MkEnds{rev_comps(8192n, acc, Nil{}), prev}
    case 1n+p:
      match rest:
        case Nil{}:
          MkEnds{rev_comps(8192n, acc, Nil{}), prev}
        case h <> t:
          ends_prev(p, h, t, prev <> acc)

def ends(comps: List<&1, List<&2, U32>>) -> Ends:
  match comps:
    case Nil{}:
      MkEnds{Nil{}, Nil{}}
    case h <> t:
      match t:
        case Nil{}:
          MkEnds{Nil{}, h}
        case _:
          ends_prev(8192n, h, t, Nil{})


# Split at the LAST '/': (parent bytes, final component bytes). A name without
# '/' has an empty parent (the root chain dir).
type Sl is Data:
  SlGo{rest: List<&2, U32>, pacc: List<&2, U32>, lacc: List<&2, U32>}
  SlFin{parent: List<&2, U32>, last: List<&2, U32>}

def sl_byte(
  c: Bool, h: U32, rest: List<&2, U32>, pacc: List<&2, U32>,
  lacc: List<&2, U32>
) -> Sl:
  match c:
    case True{}:
      SlGo{rest,
        B.list_cat(pacc, B.list_cat(B.list_rev(lacc, Nil{}), 47 <> Nil{})),
        Nil{}}
    case False{}:
      SlGo{rest, pacc, h <> lacc}

def sl_fin(pacc: List<&2, U32>, lacc: List<&2, U32>) -> Sl:
  SlFin{pacc, B.list_rev(lacc, Nil{})}

def sl_pair(st: Sl) -> List<&2, U32> & List<&2, U32>:
  match st:
    case SlFin{parent, last}:
      (parent, last)
    case SlGo{rest, pacc, lacc}:
      (pacc, lacc)

def split_last_go(fuel: Nat, st: Sl) -> List<&2, U32> & List<&2, U32>:
  match fuel:
    case 0n:
      sl_pair(st)
    case 1n+p:
      match st:
        case SlFin{parent, last}:
          (parent, last)
        case SlGo{rest, pacc, lacc}:
          match rest:
            case Nil{}:
              sl_pair(sl_fin(pacc, lacc))
            case +h <> +t:
              split_last_go(p, sl_byte(U32.is_eq(h, 47), h, t, pacc, lacc))

def split_last(name: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  split_last_go(8192n, SlGo{name, Nil{}, Nil{}})

# ---- close a directory chain (one close per recursive step) ----------------

def close_all(fuel: Nat, hs: List<&1, File>) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      match hs:
        case Nil{}:
          IO.pure(Unit, Unit{})
        case h <> t:
          do IO<Unit>:
            u : Unit <- File.close(h)
            close_all(p, t)

# ---- walk: open the root + ancestor components (create missing, 0755) -----

type Walk is Type:
  WOk{opened: List<&1, File>}
  WErr{opened: List<&1, File>, code: U32, msg: String}

type Ws is Type:
  WOpenRoot{rootpath: List<&2, U32>, comps: List<&1, List<&2, U32>>}
  WOpen{
    opened: List<&1, File>,
    head: List<&2, U32>,
    rest: List<&1, List<&2, U32>>
  }
  WMk{
    opened: List<&1, File>,
    head: List<&2, U32>,
    rest: List<&1, List<&2, U32>>
  }
  WRetry{
    opened: List<&1, File>,
    head: List<&2, U32>,
    rest: List<&1, List<&2, U32>>
  }
  WFin{opened: List<&1, File>}
  WBad{opened: List<&1, File>, code: U32, msg: String}

def next_open(
  opened: List<&1, File>, comps: List<&1, List<&2, U32>>
) -> Ws:
  match comps:
    case Nil{}:
      WFin{opened}
    case h <> t:
      WOpen{opened, h, t}

def open_fail_case(
  c: Bool, opened: List<&1, File>, head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>, code: U32, msg: String
) -> Ws:
  match c:
    case True{}:
      WMk{opened, head, rest}
    case False{}:
      WBad{opened, code, msg}

def open_fail(
  opened: List<&1, File>, head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>, +code: U32, msg: String
) -> Ws:
  open_fail_case(U32.is_eq(code, 2), opened, head, rest, code, msg)

def walk_root_after(
  pr: Result<&1, &1, U32 & String, File>,
  comps: List<&1, List<&2, U32>>
) -> Ws:
  match pr:
    case Fail{(code, msg)}:
      WBad{Nil{}, code, "open root dir: " ++ msg}
    case Done{root}:
      next_open(root <> Nil{}, comps)

def walk_open_after(
  pr: File & Result<&1, &1, U32 & String, File>,
  tail: List<&1, File>,
  +head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>
) -> Ws:
  (parent, r) = pr
  match r:
    case Done{child}:
      next_open(child <> tail, rest)
    case Fail{(code, msg)}:
      open_fail(parent <> tail, head, rest, code, msg)

def mk_fail_case(
  c: Bool, opened: List<&1, File>, head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>, code: U32, msg: String
) -> Ws:
  match c:
    case True{}:
      WRetry{opened, head, rest}
    case False{}:
      WBad{opened, code, "mkdirat: " ++ msg}

def mk_fail(
  opened: List<&1, File>, head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>, +code: U32, msg: String
) -> Ws:
  mk_fail_case(U32.is_eq(code, 17), opened, head, rest, code, msg)

def walk_mk_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, +head: List<&2, U32>,
  rest: List<&1, List<&2, U32>>
) -> Ws:
  (parent, r) = pr
  match r:
    case Done{u}:
      WRetry{parent <> tail, head, rest}
    case Fail{(code, msg)}:
      mk_fail(parent <> tail, head, rest, code, msg)

def walk_retry_after(
  pr: File & Result<&1, &1, U32 & String, File>,
  tail: List<&1, File>, rest: List<&1, List<&2, U32>>
) -> Ws:
  (parent, r) = pr
  match r:
    case Done{child}:
      next_open(child <> tail, rest)
    case Fail{(code, msg)}:
      WBad{parent <> tail, code, "openat_dir retry: " ++ msg}

def walk(fuel: Nat, ws: Ws) -> IO(Walk):
  match fuel:
    case 0n:
      IO.die(Walk, 2, "btar: extract walk fuel exhausted")
    case 1n+p:
      match ws:
        case WFin{opened}:
          IO.pure(Walk, WOk{opened})
        case WBad{opened, code, msg}:
          IO.pure(Walk, WErr{opened, code, msg})
        case WOpenRoot{rootpath, comps}:
          do IO<Walk>:
            pr : Result<&1, &1, U32 & String, File> <-
              Fx.Fs.open_dir(rootpath)
            walk(p, walk_root_after(pr, comps))
        case WOpen{opened, +head, rest}:
          match opened:
            case Nil{}:
              IO.die(Walk, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<Walk>:
                pr : File & Result<&1, &1, U32 & String, File> <-
                  Fx.Fs.openat_dir(h, head)
                walk(p, walk_open_after(pr, t, head, rest))
        case WMk{opened, +head, rest}:
          match opened:
            case Nil{}:
              IO.die(Walk, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<Walk>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.mkdirat(h, head, 493)
                walk(p, walk_mk_after(pr, t, head, rest))
        case WRetry{opened, +head, rest}:
          match opened:
            case Nil{}:
              IO.die(Walk, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<Walk>:
                pr : File & Result<&1, &1, U32 & String, File> <-
                  Fx.Fs.openat_dir(h, head)
                walk(p, walk_retry_after(pr, t, rest))

# Open the root and every ancestor component (creating missing ones 0755);
# answers the chain with the parent directory at its head.

def walk_dirs(
  fuel: Nat, rootpath: List<&2, U32>,
  anc: List<&1, List<&2, U32>>
) -> IO(Walk):
  walk(fuel, WOpenRoot{rootpath, anc})

# ---- create one entry (regular file / symlink / hardlink) -----------------

type Cre is Type:
  CrFile{opened: List<&1, File>, file: File}
  CrUnit{opened: List<&1, File>}
  CrErr{opened: List<&1, File>, code: U32, msg: String}

# kind: 0 = O_CREAT|O_EXCL file, 1 = symlink(target), 2 = hardlink(target is a
# component name in the same parent dir).
type Cs is Type:
  CsTry{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mode: U32,
    kind: U32,
    target: List<&2, U32>
  }
  CsUnlink{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mode: U32,
    kind: U32,
    target: List<&2, U32>
  }
  CsFinFile{opened: List<&1, File>, file: File}
  CsFinUnit{opened: List<&1, File>}
  CsFinErr{opened: List<&1, File>, code: U32, msg: String}

def cs_next(
  opened: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>
) -> Cs:
  CsTry{opened, last, mode, kind, target}

def cs_unlink(
  opened: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>
) -> Cs:
  CsUnlink{opened, last, mode, kind, target}

def create_eexist_case(
  c: Bool, opened: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>, code: U32, msg: String
) -> Cs:
  match c:
    case True{}:
      cs_unlink(opened, last, mode, kind, target)
    case False{}:
      CsFinErr{opened, code, msg}

def create_eexist(
  opened: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>, +code: U32, msg: String
) -> Cs:
  create_eexist_case(U32.is_eq(code, 17), opened, last, mode, kind, target,
    code, msg)

def create_file_after(
  pr: File & Result<&1, &1, U32 & String, File>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>
) -> Cs:
  (parent, r) = pr
  match r:
    case Done{file}:
      CsFinFile{parent <> tail, file}
    case Fail{(code, msg)}:
      create_eexist(parent <> tail, last, mode, kind, target, code, msg)

def create_unit_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>
) -> Cs:
  (parent, r) = pr
  match r:
    case Done{u}:
      CsFinUnit{parent <> tail}
    case Fail{(code, msg)}:
      create_eexist(parent <> tail, last, mode, kind, target, code, msg)

def create_unlink_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, kind: U32,
  target: List<&2, U32>
) -> Cs:
  (parent, r) = pr
  match r:
    case Done{u}:
      cs_next(parent <> tail, last, mode, kind, target)
    case Fail{(code, msg)}:
      CsFinErr{parent <> tail, code, msg}

def create(fuel: Nat, cs: Cs) -> IO(Cre):
  match fuel:
    case 0n:
      IO.die(Cre, 2, "btar: create fuel exhausted")
    case 1n+p:
      match cs:
        case CsFinFile{opened, file}:
          IO.pure(Cre, CrFile{opened, file})
        case CsFinUnit{opened}:
          IO.pure(Cre, CrUnit{opened})
        case CsFinErr{opened, code, msg}:
          IO.pure(Cre, CrErr{opened, code, msg})
        case CsTry{opened, +last, +mode, +kind, +target}:
          match opened:
            case Nil{}:
              IO.die(Cre, 2, "btar: internal error: empty directory chain")
            case h <> t:
              match kind:
                case 0:
                  do IO<Cre>:
                    pr : File & Result<&1, &1, U32 & String, File> <-
                      Fx.Fs.openat_file(h, last, mode)
                    create(p, create_file_after(pr, t, last, mode, kind,
                      target))
                case 1:
                  do IO<Cre>:
                    pr : File & Result<&1, &1, U32 & String, Unit> <-
                      Fx.Fs.symlinkat(h, last, target)
                    create(p, create_unit_after(pr, t, last, mode, kind,
                      target))
                case _:
                  do IO<Cre>:
                    pr : File & Result<&1, &1, U32 & String, Unit> <-
                      Fx.Fs.linkat(h, target, last)
                    create(p, create_unit_after(pr, t, last, mode, kind,
                      target))
        case CsUnlink{opened, +last, mode, kind, target}:
          match opened:
            case Nil{}:
              IO.die(Cre, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<Cre>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.unlinkat(h, last)
                create(p, create_unlink_after(pr, t, last, mode, kind,
                  target))

def create_file_run(
  fuel: Nat, opened: List<&1, File>, last: List<&2, U32>, mode: U32
) -> IO(Cre):
  create(fuel, cs_next(opened, last, mode, 0, Nil{}))

def create_symlink_run(
  fuel: Nat, opened: List<&1, File>, last: List<&2, U32>,
  target: List<&2, U32>
) -> IO(Cre):
  create(fuel, cs_next(opened, last, 511, 1, target))

def create_hardlink_run(
  fuel: Nat, opened: List<&1, File>, last: List<&2, U32>,
  target: List<&2, U32>
) -> IO(Cre):
  create(fuel, cs_next(opened, last, 0, 2, target))

# ---- directory create + chmod + mtime -------------------------------------

type MetaRes is Type:
  MOk{opened: List<&1, File>}
  MErr{opened: List<&1, File>, code: U32, msg: String}

type Ds is Type:
  DMk{opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32}
  DChmod{opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32}
  DUtime{opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32}
  DFin{opened: List<&1, File>}
  DBad{opened: List<&1, File>, code: U32, msg: String}

def ds_mk_fail_case(
  c: Bool, opened: List<&1, File>, last: List<&2, U32>, mode: U32,
  mtime: U32, code: U32, msg: String
) -> Ds:
  match c:
    case True{}:
      DChmod{opened, last, mode, mtime}
    case False{}:
      DBad{opened, code, "mkdir: " ++ msg}

def ds_mk_fail(
  opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32,
  +code: U32, msg: String
) -> Ds:
  ds_mk_fail_case(U32.is_eq(code, 17), opened, last, mode, mtime, code, msg)

def ds_mk_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32
) -> Ds:
  (parent, r) = pr
  match r:
    case Done{u}:
      DChmod{parent <> tail, last, mode, mtime}
    case Fail{(code, msg)}:
      ds_mk_fail(parent <> tail, last, mode, mtime, code, msg)

def ds_chmod_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32
) -> Ds:
  (parent, r) = pr
  match r:
    case Done{u}:
      DUtime{parent <> tail, last, mode, mtime}
    case Fail{(code, msg)}:
      DBad{parent <> tail, code, "chmod: " ++ msg}

def ds_utime_after(
  pr: File & Result<&1, &1, U32 & String, Unit>, tail: List<&1, File>
) -> Ds:
  (parent, r) = pr
  match r:
    case Done{u}:
      DFin{parent <> tail}
    case Fail{(code, msg)}:
      DBad{parent <> tail, code, "utime: " ++ msg}

def dir_meta(fuel: Nat, ds: Ds) -> IO(MetaRes):
  match fuel:
    case 0n:
      IO.die(MetaRes, 2, "btar: dir metadata fuel exhausted")
    case 1n+p:
      match ds:
        case DFin{opened}:
          IO.pure(MetaRes, MOk{opened})
        case DBad{opened, code, msg}:
          IO.pure(MetaRes, MErr{opened, code, msg})
        case DMk{opened, +last, +mode, mtime}:
          match opened:
            case Nil{}:
              IO.die(MetaRes, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<MetaRes>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.mkdirat(h, last, mode)
                dir_meta(p, ds_mk_after(pr, t, last, mode, mtime))
        case DChmod{opened, +last, +mode, mtime}:
          match opened:
            case Nil{}:
              IO.die(MetaRes, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<MetaRes>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.fchmodat(h, last, U32.and(mode, 4095))
                dir_meta(p, ds_chmod_after(pr, t, last, mode, mtime))
        case DUtime{opened, +last, mode, mtime}:
          match opened:
            case Nil{}:
              IO.die(MetaRes, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<MetaRes>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.utimensat(h, last, mtime)
                dir_meta(p, ds_utime_after(pr, t))

def make_dir(
  fuel: Nat, opened: List<&1, File>, last: List<&2, U32>, mode: U32,
  mtime: U32
) -> IO(MetaRes):
  dir_meta(fuel, DMk{opened, last, mode, mtime})

# ---- file chmod + mtime after its data is written -------------------------

type Fm is Type:
  FmChmod{opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32}
  FmUtime{opened: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32}
  FmFin{opened: List<&1, File>}
  FmBad{opened: List<&1, File>, code: U32, msg: String}

def fm_chmod_after(
  pr: File & Result<&1, &1, U32 & String, Unit>,
  tail: List<&1, File>, last: List<&2, U32>, mode: U32, mtime: U32
) -> Fm:
  (parent, r) = pr
  match r:
    case Done{u}:
      FmUtime{parent <> tail, last, mode, mtime}
    case Fail{(code, msg)}:
      FmBad{parent <> tail, code, msg}

def fm_utime_after(
  pr: File & Result<&1, &1, U32 & String, Unit>, tail: List<&1, File>
) -> Fm:
  (parent, r) = pr
  match r:
    case Done{u}:
      FmFin{parent <> tail}
    case Fail{(code, msg)}:
      FmBad{parent <> tail, code, msg}

def file_meta(fuel: Nat, fm: Fm) -> IO(MetaRes):
  match fuel:
    case 0n:
      IO.die(MetaRes, 2, "btar: file metadata fuel exhausted")
    case 1n+p:
      match fm:
        case FmFin{opened}:
          IO.pure(MetaRes, MOk{opened})
        case FmBad{opened, code, msg}:
          IO.pure(MetaRes, MErr{opened, code, msg})
        case FmChmod{opened, +last, +mode, mtime}:
          match opened:
            case Nil{}:
              IO.die(MetaRes, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<MetaRes>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.fchmodat(h, last, U32.and(mode, 4095))
                file_meta(p, fm_chmod_after(pr, t, last, mode, mtime))
        case FmUtime{opened, +last, mode, mtime}:
          match opened:
            case Nil{}:
              IO.die(MetaRes, 2, "btar: internal error: empty directory chain")
            case h <> t:
              do IO<MetaRes>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Fs.utimensat(h, last, mtime)
                file_meta(p, fm_utime_after(pr, t))

def set_file_meta(
  fuel: Nat, opened: List<&1, File>, last: List<&2, U32>, mode: U32,
  mtime: U32
) -> IO(MetaRes):
  file_meta(fuel, FmChmod{opened, last, mode, mtime})
