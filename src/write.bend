# src/write.bend — M4 create mode (`btar -cf`): filesystem -> tar archive.
#
# Phase 1 (`walk`, one fuel-bounded recursive event loop) collects a pure
# Ent list from the `-C` base dirfd using Fs.statx/readdir/readlinkat, in
# readdir/DFS order; the first occurrence of a multiply-linked inode is
# recorded and later occurrences become typeflag '1' entries.
# Phase 2 (`wlist`, one recursive loop) writes the Ent list: canonical ustar
# blocks from H.encode, or a POSIX pax 'x' header + payload when a header
# does not fit ustar (unless --format=ustar); payloads via Data.copy from
# Fs.openat_read; padding and the two end blocks via Stream.write_zeros.
import Base
import ../src/bytes.bend as B
import ../src/num.bend as N
import ../src/header.bend as H
import ../src/pax.bend as P
import ../src/limits.bend as Lim
import ../src/upd.bend as U
import ../src/glob.bend as Glob
import ../effs/effects.bend as Fx

# ---- pure helpers --------------------------------------------------------

type WCfg is Data:
  MkCfg{fmt: U32, preserve: Bool, verbose: Bool}

type Plan is Data:
  POk{blocks: List<&2, List<&2, U32>>}
  PFail{msg: String}

type Ent is Data:
  MkEnt{name: List<&2, U32>, kind: U32, mode: U32, uid: U32, gid: U32,
    sz: U32, mt: U32, link: List<&2, U32>}

type RS is Data:
  RGo{rest: List<&2, U32>}
  RFin{m: Maybe<&2, List<&2, U32>>}

type Stack is Type:
  StNil{}
  StCons{frame: Frame, rest: Stack}

type Frame is Type:
  MkFrame{dir: File, rel: List<&2, U32>, names: List<&2, List<&2, U32>>}

# ---- phase A: collect a pure manifest for create operands ----------------

# Cx is copyable: -C root bytes, remaining CLI operands, accumulated Ents,
# hardlink (dev,ino)->name registry, and the walk options.
# Walk options: --sort=name, the `-u` archive table (empty for create/append:
# nothing is skipped), --exclude patterns, --no-recursion.
type Wo is Data:
  MkWo{sort: Bool, upd: U.Tab, exc: List<&2, List<&2, U32>>, norec: Bool}

type Cx is Data:
  MkCx{
    root: List<&2, U32>,
    ops: List<&2, List<&2, U32>>,
    acc: List<&2, Ent>,
    refs: List<&2, U32>,
    wo: Wo
  }

type CSt is Type:
  CStart{cx: Cx}
  CNextOp{cx: Cx}
  COpStat{cx: Cx, full: List<&2, U32>, aname: List<&2, U32>}
  COpOpen{cx: Cx, full: List<&2, U32>, aname: List<&2, U32>}
  COpRead{cx: Cx, dir: File, prefix: List<&2, U32>}
  COpLink{cx: Cx, full: List<&2, U32>, aname: List<&2, U32>,
    st: List<&2, U32>}
  CCloseOp{cx: Cx, dir: File}
  CRootOpen{cx: Cx}
  CRootStat{cx: Cx, dir: File}
  CRootRead{cx: Cx, dir: File}
  CNames{cx: Cx, stack: Stack}
  CStat{cx: Cx, stack: Stack, rel: List<&2, U32>,
    fname: List<&2, U32>}
  CEntry{cx: Cx, stack: Stack, rel: List<&2, U32>,
    fname: List<&2, U32>, st: List<&2, U32>}
  CLink{cx: Cx, stack: Stack, rel: List<&2, U32>,
    fname: List<&2, U32>, st: List<&2, U32>}
  COpenDir{cx: Cx, stack: Stack, rel: List<&2, U32>,
    fname: List<&2, U32>, st: List<&2, U32>}
  CReadChild{cx: Cx, stack: Stack, child: File, crel: List<&2, U32>}
  CAscend{cx: Cx, stack: Stack}
  CNextName{cx: Cx, stack: Stack}
  CWarn{cx: Cx, name: List<&2, U32>, stack: Stack}
  CDone{acc: List<&2, Ent>}
  CErr{msg: String}

# ---- operand path helpers ------------------------------------------------

# True when a path component is exactly ".." (no escape above the -C root).
type DdSt is Data:
  DdGo{xs: List<&2, U32>, cur: List<&2, U32>, tok: U32}
  DdFin{bad: Bool}

type BcSt is Data:
  BcGo{a: List<&2, U32>, b: List<&2, U32>}
  BcFin{r: U32}

type DropSt is Data:
  DropGo{xs: List<&2, List<&2, U32>>, target: List<&2, U32>,
    out: List<&2, List<&2, U32>>}
  DropFin{out: List<&2, List<&2, U32>>}

type InsSt is Data:
  InsGo{x: List<&2, U32>, xs: List<&2, List<&2, U32>>,
    out: List<&2, List<&2, U32>>}
  InsFin{out: List<&2, List<&2, U32>>}

type PfSt is Data:
  PfGo{root: List<&2, U32>, ops: List<&2, List<&2, U32>>}
  PfCheck{root: List<&2, U32>, op: List<&2, U32>,
    rest: List<&2, List<&2, U32>>}
  PfBad{msg: String}

type Split is Data:
  MkSplit{dir: List<&2, U32>, last: List<&2, U32>}

# The writer is a state machine over the remaining entries: each step does the
# IO for one entry and returns the next state (only `write_all` recurses).
# `selfid` is [dev_lo, dev_hi, ino_lo, ino_hi] of the archive file ([] when
# unknown): a regular file with that identity is the archive itself and is not
# dumped (GNU tar behaves the same, without a failure status).
type WS is Type:
  WsRun{archive: File, base: List<&2, U32>, ents: List<&2, Ent>, cfg: WCfg,
    lim: Lim.State, warned: Bool, selfid: List<&2, U32>}
  WsEnd{warned: Bool}

def bstr(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bstr(t)

def blen(xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def with_slash(xs: List<&2, U32>) -> List<&2, U32>:
  B.list_cat(xs, 47 <> Nil{})

def take(xs: List<&2, U32>, n: Nat) -> List<&2, U32>:
  B.slice_list(xs, 0n, n)

def join_slash(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  B.list_cat(a, B.list_cat(47 <> Nil{}, b))

def pad512(+n: U32) -> U32:
  U32.sub(U32.mul(U32.div(U32.add(n, 511), 512), 512), n)

def disp_ch_go(ok: Bool, h: U32) -> Char:
  match ok:
    case True{}:
      Char.from_u32(h)
    case False{}:
      Char.from_u32(63)

def disp_ch(+h: U32) -> Char:
  disp_ch_go(Bool.and(U32.is_ge(h, 32), U32.is_le(h, 126)), h)

def disp(xs: List<&2, U32>, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      disp(t, SCon{disp_ch(h), acc})

def rev_str(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      rev_str(t, SCon{h, acc})

def bytes_str(xs: List<&2, U32>) -> String:
  rev_str(disp(xs, SNil{}), SNil{})

# ---- config / stat -------------------------------------------------------

def st_type(st: List<&2, U32>) -> U32:
  N.nth(st, 0n)

def st_mode(st: List<&2, U32>) -> U32:
  N.nth(st, 1n)

def st_nlink(st: List<&2, U32>) -> U32:
  N.nth(st, 2n)

def st_uid(st: List<&2, U32>) -> U32:
  N.nth(st, 3n)

def st_gid(st: List<&2, U32>) -> U32:
  N.nth(st, 4n)

def st_size(st: List<&2, U32>) -> U32:
  N.nth(st, 5n)

def st_mtime(st: List<&2, U32>) -> U32:
  N.nth(st, 6n)

def st_ino_lo(st: List<&2, U32>) -> U32:
  N.nth(st, 7n)

def st_ino_hi(st: List<&2, U32>) -> U32:
  N.nth(st, 8n)

def st_dev_lo(st: List<&2, U32>) -> U32:
  N.nth(st, 9n)

def st_dev_hi(st: List<&2, U32>) -> U32:
  N.nth(st, 10n)

def is_reg(t: U32) -> Bool:
  U32.is_eq(t, 8)

def is_dir(t: U32) -> Bool:
  U32.is_eq(t, 4)

def is_sym(t: U32) -> Bool:
  U32.is_eq(t, 10)

def is_sp2(c: Bool, t: U32) -> Bool:
  match c:
    case True{}:
      True{}
    case False{}:
      U32.is_eq(t, 12)

def is_sp(+t: U32) -> Bool:
  is_sp2(Bool.or(U32.is_eq(t, 1), Bool.or(U32.is_eq(t, 2),
    U32.is_eq(t, 6))), t)

def mode_it(p: Bool, m0: U32) -> U32:
  U32.and(m0, 4095)

# walk modes: 0 dispatch, 1 reg, 2 dir, 3 symlink, 4 special

def mode_of(+cfg: WCfg, m0: U32) -> U32:
  match cfg:
    case MkCfg{_, preserve, _}:
      mode_it(preserve, m0)

def mode_by4(sym: Bool) -> U32:
  match sym:
    case True{}:
      3
    case False{}:
      4

# Ent list append (accumulator order).

def mode_by3(dir: Bool, sym: Bool) -> U32:
  match dir:
    case True{}:
      2
    case False{}:
      mode_by4(sym)

def mode_by2(reg: Bool, dir: Bool, sym: Bool) -> U32:
  match reg:
    case True{}:
      1
    case False{}:
      mode_by3(dir, sym)

def mode_by(+t: U32) -> U32:
  mode_by2(is_reg(t), is_dir(t), is_sym(t))

def app_ent(xs: List<&2, Ent>, ys: List<&2, Ent>) -> List<&2, Ent>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> app_ent(t, ys)

# Entries accumulate newest-first during the walk and are reversed once.
def rev_ent(xs: List<&2, Ent>, +acc: List<&2, Ent>) -> List<&2, Ent>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rev_ent(t, h <> acc)

def ent_one(e: Ent) -> List<&2, Ent>:
  e <> Nil{}

def ent_reg(+st: List<&2, U32>, name: List<&2, U32>) -> Ent:
  MkEnt{name, 48, st_mode(st), st_uid(st), st_gid(st), st_size(st),
    st_mtime(st), Nil{}}

def ent_dir(+st: List<&2, U32>, name: List<&2, U32>) -> Ent:
  MkEnt{with_slash(name), 53, st_mode(st), st_uid(st), st_gid(st), 0,
    st_mtime(st), Nil{}}

def ent_sym(+st: List<&2, U32>, name: List<&2, U32>, link: List<&2, U32>) ->
  Ent:
  MkEnt{name, 50, st_mode(st), st_uid(st), st_gid(st), 0, st_mtime(st),
    link}

def ent_hard(+st: List<&2, U32>, name: List<&2, U32>, target: List<&2, U32>) ->
  Ent:
  MkEnt{name, 49, st_mode(st), st_uid(st), st_gid(st), 0, st_mtime(st),
    target}

# ---- hardlink registry (flat U32 list, single recursion) -----------------

def refs_eq(+xs: List<&2, U32>, dlo: U32, dhi: U32, ilo: U32, ihi: U32) ->
  Bool:
  Bool.and(U32.is_eq(N.nth(xs, 0n), dlo),
    Bool.and(U32.is_eq(N.nth(xs, 1n), dhi),
      Bool.and(U32.is_eq(N.nth(xs, 2n), ilo), U32.is_eq(N.nth(xs, 3n),
        ihi))))

def refs_next(hit: Bool, +xs: List<&2, U32>) -> RS:
  match hit:
    case True{}:
      +pl = U32.to_nat(N.nth(xs, 4n))
      RFin{Some{B.slice_list(xs, 5n, pl)}}
    case False{}:
      +pl = U32.to_nat(N.nth(xs, 4n))
      RGo{List.drop(&2, U32, xs, Nat.add(5n, pl))}

def refs_branch(empty: Bool, +rest: List<&2, U32>, dlo: U32, dhi: U32,
  ilo: U32, ihi: U32) -> RS:
  match empty:
    case True{}:
      RFin{None{}}
    case False{}:
      refs_next(refs_eq(rest, dlo, dhi, ilo, ihi), rest)

def refs_run(fuel: Nat, st: RS, +dlo: U32, +dhi: U32, +ilo: U32,
  +ihi: U32) -> Maybe<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case RFin{m}:
          m
        case RGo{+rest}:
          refs_run(p, refs_branch(U32.is_eq(U32.from_nat(blen(rest)), 0),
            rest, dlo, dhi, ilo, ihi), dlo, dhi, ilo, ihi)

def refs_of(+st: List<&2, U32>, +xs: List<&2, U32>) ->
  Maybe<&2, List<&2, U32>>:
  refs_run(4096n, RGo{xs}, st_dev_lo(st), st_dev_hi(st), st_ino_lo(st),
    st_ino_hi(st))

def ino_hdr(+st: List<&2, U32>, pl: U32) -> List<&2, U32>:
  st_dev_lo(st) <> (st_dev_hi(st) <> (st_ino_lo(st) <> (st_ino_hi(st) <>
    (pl <> Nil{}))))

def refs_keep2(hard: Bool, st: List<&2, U32>, +name: List<&2, U32>,
  xs: List<&2, U32>) -> List<&2, U32>:
  match hard:
    case True{}:
      B.list_cat(xs, B.list_cat(ino_hdr(st, U32.from_nat(blen(name))),
        name))
    case False{}:
      xs

# ---- header planning -----------------------------------------------------

def refs_keep(+st: List<&2, U32>, name: List<&2, U32>, xs: List<&2, U32>) ->
  List<&2, U32>:
  refs_keep2(U32.is_gt(st_nlink(st), 1), st, name, xs)

def mk_hdr(name: List<&2, U32>, mode: U32, uid: U32, gid: U32, size: U32,
  mtime: U32, tflag: U32, link: List<&2, U32>) -> H.Header:
  H.MkHeader{name, mode, uid, gid, size, mtime, tflag, link, 1, Nil{}, Nil{},
    0, 0, Nil{}}

def hdr_of(ent: Ent, +cfg: WCfg) -> H.Header:
  match ent:
    case MkEnt{+name, kind, mode, uid, gid, +sz, mt, link}:
      mk_hdr(name, mode_of(cfg, mode), uid, gid, sz, mt, kind, link)

def hdr_root(+cfg: WCfg) -> H.Header:
  mk_hdr(bstr("./"), 493, 0, 0, 0, 0, 53, Nil{})

def pax_bit(c: Bool, v: U32) -> U32:
  match c:
    case True{}:
      v
    case False{}:
      0

def pax_mask(+h: H.Header) -> U32:
  U32.add(pax_bit(Bool.not(H.enc_name_ok(H.h_name(h))), 1),
    U32.add(pax_bit(U32.is_gt(U32.from_nat(blen(H.h_linkname(h))), 100),
      2), U32.add(pax_bit(U32.is_gt(H.h_uid(h), 2097151), 4),
      pax_bit(U32.is_gt(H.h_gid(h), 2097151), 8))))

def rec_c(c: Bool, kv: P.Kv) -> List<&2, P.Kv>:
  match c:
    case True{}:
      kv <> Nil{}
    case False{}:
      Nil{}

def cat_kv(xs: List<&2, P.Kv>, ys: List<&2, P.Kv>) -> List<&2, P.Kv>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> cat_kv(t, ys)

def pax_recs(mask: U32, +h: H.Header, nb: Bool, lb: Bool, ub: Bool,
  gb: Bool) -> List<&2, P.Kv>:
  cat_kv(rec_c(nb, P.kv(P.key_path(), H.h_name(h))),
    cat_kv(rec_c(lb, P.kv(P.key_linkpath(), H.h_linkname(h))),
      cat_kv(rec_c(ub, P.kv(P.key_uid(), N.encode_decimal(H.h_uid(h)))),
        rec_c(gb, P.kv(P.key_gid(), N.encode_decimal(H.h_gid(h)))))))

def pax_recs_go(+mask: U32, +h: H.Header) -> List<&2, P.Kv>:
  pax_recs(mask, h, U32.is_gt(U32.and(mask, 1), 0),
    U32.is_gt(U32.and(mask, 2), 0), U32.is_gt(U32.and(mask, 4), 0),
    U32.is_gt(U32.and(mask, 8), 0))

def safe_u32(c: Bool, v: U32) -> U32:
  match c:
    case True{}:
      0
    case False{}:
      v

def pax_safe(+h: H.Header, +mask: U32) -> H.Header:
  mk_hdr(take(H.h_name(h), 100n), H.h_mode(h),
    safe_u32(U32.is_gt(U32.and(mask, 4), 0), H.h_uid(h)),
    safe_u32(U32.is_gt(U32.and(mask, 8), 0), H.h_gid(h)), H.h_size(h),
    H.h_mtime(h), H.h_typeflag(h), take(H.h_linkname(h), 100n))

def rev_u32(fuel: Nat, xs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case h <> t:
          rev_u32(p, t, h <> acc)

def seg_upd(is_slash: Bool, h: U32, cur: List<&2, U32>) -> List<&2, U32>:
  match is_slash:
    case True{}:
      Nil{}
    case False{}:
      h <> cur

def seg(fuel: Nat, xs: List<&2, U32>, cur: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      cur
    case 1n+p:
      match xs:
        case Nil{}:
          cur
        case +h <> t:
          seg(p, t, seg_upd(U32.is_eq(h, 47), h, cur))

def pax_hdr_name(name: List<&2, U32>) -> List<&2, U32>:
  take(B.list_cat(bstr("PaxHeaders/"), rev_u32(1024n, seg(1024n, name,
    Nil{}), Nil{})), 100n)

def pax_hdr(+h: H.Header, payload: List<&2, U32>) -> H.Header:
  mk_hdr(pax_hdr_name(H.h_name(h)), 420, 0, 0,
    U32.from_nat(blen(payload)), H.h_mtime(h), 120, Nil{})

def cat_blk(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> cat_blk(t, ys)

def pax_mk3(xb: List<&2, U32>, pl: List<&2, U32>,
  r: Result<&1, &1, H.EncErr, List<&2, U32>>) -> Plan:
  match r:
    case Fail{e}:
      PFail{"pax-covered header cannot encode: " ++ H.enc_err_show(e)}
    case Done{sb}:
      POk{cat_blk(xb <> Nil{}, cat_blk(pl <> Nil{}, sb <> Nil{}))}

def pax_mk2(+h: H.Header, mask: U32, pl: List<&2, U32>,
  xb: List<&2, U32>) -> Plan:
  pax_mk3(xb, pl, H.encode(pax_safe(h, mask)))

def pax_mk(+h: H.Header, mask: U32, raw: List<&2, U32>,
  pl: List<&2, U32>,
  r: Result<&1, &1, H.EncErr, List<&2, U32>>) -> Plan:
  match r:
    case Fail{e}:
      PFail{"pax header cannot encode: " ++ H.enc_err_show(e)}
    case Done{xb}:
      pax_mk2(h, mask, pl, xb)

def pax_fb(+h: H.Header, +e: H.EncErr) -> Plan:
  +mask = pax_mask(h)
  +raw = P.emit(pax_recs_go(mask, h))
  +pl = P.pad_payload(raw)
  pax_mk(h, mask, raw, pl, H.encode(pax_hdr(h, raw)))

def pax_plan(+h: H.Header, r: Result<&1, &1, H.EncErr,
  List<&2, U32>>) -> Plan:
  match r:
    case Done{blk}:
      POk{blk <> Nil{}}
    case Fail{e}:
      pax_fb(h, e)

def plan_ustar(r: Result<&1, &1, H.EncErr, List<&2, U32>>) -> Plan:
  match r:
    case Fail{e}:
      PFail{"ustar format cannot encode: " ++ H.enc_err_show(e)}
    case Done{blk}:
      POk{blk <> Nil{}}

# ---- IO wrappers ---------------------------------------------------------

def plan_fmt2(is_ustar: Bool, +h: H.Header,
  r: Result<&1, &1, H.EncErr, List<&2, U32>>) -> Plan:
  match is_ustar:
    case True{}:
      plan_ustar(r)
    case False{}:
      pax_plan(h, r)

def plan_fmt(+cfg: WCfg, +h: H.Header,
  r: Result<&1, &1, H.EncErr, List<&2, U32>>) -> Plan:
  match cfg:
    case MkCfg{fmt, _, _}:
      plan_fmt2(U32.is_eq(fmt, 1), h, r)

def plan(+h: H.Header, +cfg: WCfg) -> Plan:
  plan_fmt(cfg, h, H.encode(h))

def lim_msg(e: Lim.Err) -> String:
  match e:
    case Lim.Members{}:
      "member limit exceeded"
    case Lim.Total{}:
      "total size limit exceeded"
    case Lim.Member{}:
      "member size limit exceeded"
    case Lim.Name{}:
      "name length limit exceeded"
    case Lim.Pax{}:
      "pax payload limit exceeded"

def lim_io(e: Lim.Err) -> IO(Lim.State):
  IO.die(Lim.State, 2, "btar: " ++ lim_msg(e))

def lim_add2(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Lim.State):
  match r:
    case Done{st}:
      IO.pure(Lim.State, st)
    case Fail{e}:
      lim_io(e)

def lim_add(lim: Lim.State, size: U32) -> IO(Lim.State):
  do IO<Lim.State>:
    lim_add2(Lim.add_member(lim, size))

def lim_nm2(r: Result<&1, &1, Lim.Err, Lim.State>) -> IO(Lim.State):
  match r:
    case Done{st}:
      IO.pure(Lim.State, st)
    case Fail{e}:
      lim_io(e)

def lim_nm(lim: Lim.State, name: List<&2, U32>) -> IO(Lim.State):
  do IO<Lim.State>:
    lim_nm2(Lim.check_name(lim, U32.from_nat(blen(name))))

def cfg_of(w: WCfg) -> WCfg:
  w

def verb2(v: Bool, name: List<&2, U32>) -> IO(Unit):
  match v:
    case True{}:
      do IO<Unit>:
        u : Unit <- IO.print_err(bytes_str(name))
        IO.pure(Unit, Unit{})
    case False{}:
      IO.pure(Unit, Unit{})

def verb_io(+cfg: WCfg, name: List<&2, U32>) -> IO(Unit):
  match cfg:
    case MkCfg{_, _, verbose}:
      verb2(verbose, name)

def warn_io(name: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- IO.print_err("btar: skipping unsupported file type: " ++
      bytes_str(name))
    IO.pure(Unit, Unit{})

def fpair(pr: File & Result<&1, &1, U32 & String, File>) -> IO(File):
  (d, r) = pr
  match r:
    case Done{f}:
      IO.pure(File, f)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: handle: " ++ msg)

def rpair(r: Result<&1, &1, U32 & String, File>) -> IO(File):
  match r:
    case Done{f}:
      IO.pure(File, f)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: open: " ++ msg)

def f_open(path: List<&2, U32>, mode: String) -> IO(File):
  do IO<File>:
    IO.try(File, File.open_bytes(path, mode))

def d_root(path: List<&2, U32>) -> IO(File):
  do IO<File>:
    IO.try(File, Fx.Fs.open_dir(path))

def d_open(dir: File, name: List<&2, U32>) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, File> <-
      Fx.Fs.openat_dir(dir, name)
    fpair(pr)

def src_open(dir: File, name: List<&2, U32>) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, File> <-
      Fx.Fs.openat_read(dir, name)
    fpair(pr)

def names_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>
) -> IO(List<&2, List<&2, U32>>):
  (d, r) = pr
  match r:
    case Done{xs}:
      IO.pure(List<&2, List<&2, U32>>, xs)
    case Fail{(code, msg)}:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: " ++ msg)

def rd_names(dir: File) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    pr : File & Result<&1, &1, U32 & String,
      List<&2, List<&2, U32>>> <- Fx.Fs.readdir(dir)
    names_after(pr)

def st_after(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(List<&2, U32>):
  (d, r) = pr
  match r:
    case Done{st}:
      IO.pure(List<&2, U32>, st)
    case Fail{(code, msg)}:
      IO.die(List<&2, U32>, 2, "btar: " ++ msg)

def st_of(dir: File, name: List<&2, U32>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.statx(dir, name)
    st_after(pr)

def ln_after(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(List<&2, U32>):
  (d, r) = pr
  match r:
    case Done{t}:
      IO.pure(List<&2, U32>, t)
    case Fail{(code, msg)}:
      IO.die(List<&2, U32>, 2, "btar: " ++ msg)

def ln_of(dir: File, name: List<&2, U32>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.readlinkat(dir, name)
    ln_after(pr)

def wb2(pr: File & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (a, r) = pr
  match r:
    case Done{u}:
      IO.pure(File, a)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: " ++ msg)

def wb(archive: File, blk: List<&2, U32>) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Stream.write_bytes(archive, blk)
    wb2(pr)

def wz(archive: File, n: U32) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Stream.write_zeros(archive, n)
    wb2(pr)

def wtrunc(archive: File) -> IO(File):
  do IO<File>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Fs.trunc_cur(archive)
    wb2(pr)

def cp_after(pr: File & (File & Result<&1, &1, U32 & String, Unit>)) ->
  IO(File):
  (src, rest) = pr
  (archive, r) = rest
  match r:
    case Done{u}:
      do IO<File>:
        u2 : Unit <- File.close(src)
        IO.pure(File, archive)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: " ++ msg)

def cp_src(src: File, archive: File, size: U32) -> IO(File):
  do IO<File>:
    pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
      Fx.Data.copy(src, archive, size)
    cp_after(pr)

def wblk(fuel: Nat, archive: File,
  blocks: List<&2, List<&2, U32>>) -> IO(File):
  match fuel:
    case 0n:
      IO.die(File, 2, "btar: too many pax blocks")
    case 1n+p:
      match blocks:
        case Nil{}:
          IO.pure(File, archive)
        case h <> t:
          do IO<File>:
            a2 : File <- wb(archive, h)
            wblk(p, a2, t)

def emit2(archive: File, pl: Plan) -> IO(File):
  match pl:
    case POk{blocks}:
      wblk(64n, archive, blocks)
    case PFail{msg}:
      IO.die(File, 2, "btar: " ++ msg)

def emit(archive: File, +h: H.Header, +cfg: WCfg) -> IO(File):
  emit2(archive, plan(h, cfg))

def exit_w(warned: Bool) -> IO(Unit):
  match warned:
    case True{}:
      IO.exit(1)
    case False{}:
      IO.pure(Unit, Unit{})

# ---- entries ------------------------------------------------------------

def ent_root() -> Ent:
  MkEnt{bstr("./"), 53, 493, 0, 0, 0, 0, Nil{}}

def ent_root_of(+st: List<&2, U32>) -> Ent:
  MkEnt{bstr("./"), 53, st_mode(st), st_uid(st), st_gid(st), 0, st_mtime(st),
    Nil{}}

def ent_special(name: List<&2, U32>) -> Ent:
  MkEnt{name, 99, 0, 0, 0, 0, 0, Nil{}}

# ---- frame stack (Type: affine dir handles) ------------------------------

def op_head(op: List<&2, U32>) -> U32:
  match op:
    case Nil{}:
      0
    case h <> t:
      h

def strip_dot_slash(fuel: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case 46 <> (47 <> t):
          strip_dot_slash(p, t)
        case _:
          xs

def op_norm(op: List<&2, U32>) -> List<&2, U32>:
  strip_dot_slash(256n, op)

def op_root2(norm: List<&2, U32>) -> Bool:
  match norm:
    case Nil{}:
      True{}
    case h <> t:
      match t:
        case Nil{}:
          U32.is_eq(h, 46)
        case _ <> _:
          False{}

def op_root(op: List<&2, U32>) -> Bool:
  op_root2(op_norm(op))

def op_join(root: List<&2, U32>, name: List<&2, U32>) -> List<&2, U32>:
  match name:
    case Nil{}:
      root
    case _ <> _:
      B.list_cat(root, B.list_cat(47 <> Nil{}, name))

def dd_slash2(bad: Bool, t: List<&2, U32>, tok: U32) -> DdSt:
  match bad:
    case True{}:
      DdFin{True{}}
    case False{}:
      DdGo{t, Nil{}, tok}

def dd_is_dotdot(cur: List<&2, U32>) -> Bool:
  B.eq_list(cur, bstr(".."), True{})

def dd_slash(t: List<&2, U32>, cur: List<&2, U32>, tok: U32) -> DdSt:
  dd_slash2(dd_is_dotdot(cur), t, tok)

def dd_step2(is_slash: Bool, h: U32, t: List<&2, U32>,
  cur: List<&2, U32>, tok: U32) -> DdSt:
  match is_slash:
    case True{}:
      dd_slash(t, cur, tok)
    case False{}:
      DdGo{t, B.list_cat(cur, h <> Nil{}), tok}

def dd_step(is_slash: Bool, h: U32, t: List<&2, U32>,
  cur: List<&2, U32>, tok: U32) -> DdSt:
  dd_step2(is_slash, h, t, cur, tok)

def dd_final(st: DdSt) -> Bool:
  match st:
    case DdFin{bad}:
      bad
    case DdGo{xs, cur, tok}:
      dd_is_dotdot(cur)

def dd_run(fuel: Nat, st: DdSt) -> Bool:
  match fuel:
    case 0n:
      dd_final(st)
    case 1n+p:
      match st:
        case DdFin{bad}:
          bad
        case DdGo{xs, cur, tok}:
          match xs:
            case Nil{}:
              dd_is_dotdot(cur)
            case +h <> t:
              dd_run(p, dd_step(U32.is_eq(h, 47), h, t, cur, tok))

def op_bad(+op: List<&2, U32>) -> Bool:
  Bool.or(U32.is_eq(op_head(op), 47), dd_run(1024n, DdGo{op, Nil{}, 0}))

# ---- context helpers ----------------------------------------------------

def cx_acc(+cx: Cx, acc: List<&2, Ent>) -> Cx:
  match cx:
    case MkCx{root, ops, _, refs, wo}:
      MkCx{root, ops, acc, refs, wo}

def cx_acc_of(+cx: Cx) -> List<&2, Ent>:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      acc

def cx_refs(+cx: Cx, refs: List<&2, U32>) -> Cx:
  match cx:
    case MkCx{root, ops, acc, _, wo}:
      MkCx{root, ops, acc, refs, wo}

def cx_refs_of(+cx: Cx) -> List<&2, U32>:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      refs

def cx_root(+cx: Cx) -> List<&2, U32>:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      root

def cx_sort(+cx: Cx) -> Bool:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      match wo:
        case MkWo{sort, upd, exc, norec}:
          sort

def cx_upd(+cx: Cx) -> U.Tab:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      match wo:
        case MkWo{sort, upd, exc, norec}:
          upd

def cx_exc(+cx: Cx) -> List<&2, List<&2, U32>>:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      match wo:
        case MkWo{sort, upd, exc, norec}:
          exc

def cx_norec(+cx: Cx) -> Bool:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      match wo:
        case MkWo{sort, upd, exc, norec}:
          norec

def cx_add_if(skip: Bool, +cx: Cx, +ent: Ent) -> Cx:
  match skip:
    case True{}:
      cx
    case False{}:
      cx_acc(cx, ent <> cx_acc_of(cx))

# GNU `-u` never re-adds a directory whose name is already archived, however
# new its mtime (its members are still compared one by one): mtime 0 makes any
# archived copy count as "at least as new".
def dir_mt(+kind: U32, +mt: U32) -> U32:
  Bool.pick(U32, U32.is_eq(kind, 53), 0, mt)

# `-u`: an entry whose archived copy is at least as new is not appended
# (warning placeholders, kind 99, are never filtered).
def ent_skip(+cx: Cx, +ent: Ent) -> Bool:
  match ent:
    case MkEnt{name, kind, mode, uid, gid, sz, mt, link}:
      Bool.and(Bool.not(U32.is_eq(kind, 99)),
        U.skip(cx_upd(cx), name, dir_mt(kind, mt)))

def cx_add(+cx: Cx, +ent: Ent) -> Cx:
  cx_add_if(ent_skip(cx, ent), cx, ent)

# ---- --sort=name: stable sort of a directory's raw name byte lists ------

def bc_lt(is_lt: Bool) -> BcSt:
  match is_lt:
    case True{}:
      BcFin{1}
    case False{}:
      BcFin{2}

def bc_step2(is_eq: Bool, is_lt: Bool, ta: List<&2, U32>,
  tb: List<&2, U32>) -> BcSt:
  match is_eq:
    case True{}:
      BcGo{ta, tb}
    case False{}:
      bc_lt(is_lt)

def bc_step(is_eq: Bool, is_lt: Bool, ta: List<&2, U32>,
  tb: List<&2, U32>) -> BcSt:
  bc_step2(is_eq, is_lt, ta, tb)

def bc_run(fuel: Nat, st: BcSt) -> U32:
  match fuel:
    case 0n:
      0
    case 1n+p:
      match st:
        case BcFin{r}:
          r
        case BcGo{a, b}:
          match a:
            case Nil{}:
              match b:
                case Nil{}:
                  0
                case _ <> _:
                  1
            case +h <> ta:
              match b:
                case Nil{}:
                  2
                case +h2 <> tb:
                  bc_run(p, bc_step(U32.is_eq(h, h2), U32.is_lt(h, h2),
                    ta, tb))

def name_lt(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  U32.is_eq(bc_run(65536n, BcGo{a, b}), 1)

def min_pick(lt: Bool, h: List<&2, U32>,
  best: List<&2, U32>) -> List<&2, U32>:
  match lt:
    case True{}:
      h
    case False{}:
      best

def min_name(fuel: Nat, xs: List<&2, List<&2, U32>>,
  +best: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      best
    case 1n+p:
      match xs:
        case Nil{}:
          best
        case +h <> t:
          min_name(p, t, min_pick(name_lt(h, best), h, best))

def app_ll(xs: List<&2, List<&2, U32>>,
  ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> app_ll(t, ys)

def drop_step(hit: Bool, h: List<&2, U32>, t: List<&2, List<&2, U32>>,
  target: List<&2, U32>, out: List<&2, List<&2, U32>>) -> DropSt:
  match hit:
    case True{}:
      DropFin{app_ll(out, t)}
    case False{}:
      DropGo{t, target, app_ll(out, h <> Nil{})}

def drop_fin(st: DropSt) -> List<&2, List<&2, U32>>:
  match st:
    case DropFin{out}:
      out
    case DropGo{xs, target, out}:
      out

def drop_run(fuel: Nat, st: DropSt) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      drop_fin(st)
    case 1n+p:
      match st:
        case DropFin{out}:
          out
        case DropGo{xs, +target, out}:
          match xs:
            case Nil{}:
              out
            case +h <> t:
              drop_run(p, drop_step(B.eq_list(h, target, True{}), h, t,
                target, out))

def list_drop1(fuel: Nat, xs: List<&2, List<&2, U32>>,
  target: List<&2, U32>) -> List<&2, List<&2, U32>>:
  drop_run(fuel, DropGo{xs, target, Nil{}})

def ins_step(lt: Bool, x: List<&2, U32>, h: List<&2, U32>,
  t: List<&2, List<&2, U32>>, out: List<&2, List<&2, U32>>) -> InsSt:
  match lt:
    case True{}:
      InsFin{app_ll(out, x <> (h <> t))}
    case False{}:
      InsGo{x, t, app_ll(out, h <> Nil{})}

def ins_fin(st: InsSt) -> List<&2, List<&2, U32>>:
  match st:
    case InsFin{out}:
      out
    case InsGo{x, xs, out}:
      app_ll(out, x <> Nil{})

def ins_run(fuel: Nat, st: InsSt) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      ins_fin(st)
    case 1n+p:
      match st:
        case InsFin{out}:
          out
        case InsGo{+x, xs, out}:
          match xs:
            case Nil{}:
              app_ll(out, x <> Nil{})
            case +h <> t:
              ins_run(p, ins_step(name_lt(x, h), x, h, t, out))

def sort_run(fuel: Nat, pending: List<&2, List<&2, U32>>,
  acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match pending:
        case Nil{}:
          acc
        case h <> t:
          sort_run(p, t, ins_run(512n, InsGo{h, acc, Nil{}}))

def sort_names(fuel: Nat, xs: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  sort_run(fuel, xs, Nil{})



# ---- collect driver -----------------------------------------------------

def pf_valid2(bad: Bool, op: List<&2, U32>, root: List<&2, U32>,
  rest: List<&2, List<&2, U32>>) -> PfSt:
  match bad:
    case True{}:
      PfBad{"create operand refused (absolute path or '..' escaping the " ++
        "-C root): " ++ bytes_str(op)}
    case False{}:
      PfCheck{root, op, rest}

def pf_valid(bad: Bool, op: List<&2, U32>, root: List<&2, U32>,
  rest: List<&2, List<&2, U32>>) -> PfSt:
  pf_valid2(bad, op, root, rest)

def pf_after(r: Result<&1, &1, U32 & String, List<&2, U32>>,
  root: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> PfSt:
  match r:
    case Fail{(code, msg)}:
      PfBad{"create: cannot stat operand: " ++ msg}
    case Done{st}:
      PfGo{root, rest}

def pf_run(fuel: Nat, st: PfSt) -> IO(Unit):
  match fuel:
    case 0n:
      IO.die(Unit, 2, "btar: create preflight exceeded its budget")
    case 1n+p:
      match st:
        case PfBad{msg}:
          IO.die(Unit, 2, "btar: " ++ msg)
        case PfGo{+root, ops}:
          match ops:
            case Nil{}:
              IO.pure(Unit, Unit{})
            case +h <> t:
              pf_run(p, pf_valid(op_bad(h), h, root, t))
        case PfCheck{+root, op, rest}:
          do IO<Unit>:
            pr : Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Fs.stat_path(op_join(root, op_norm(op)))
            pf_run(p, pf_after(pr, root, rest))

def preflight(root: List<&2, U32>, ops: List<&2, List<&2, U32>>) ->
  IO(Unit):
  pf_run(256n, PfGo{root, ops})

def wo_exc(wo: Wo) -> List<&2, List<&2, U32>>:
  match wo:
    case MkWo{sort, upd, exc, norec}:
      exc

# An operand matched by --exclude is skipped whole (GNU: the root operand
# '.' is matched as ".").
def cx_next_kind2(skip: Bool, is_root: Bool, +root: List<&2, U32>,
  +op: List<&2, U32>, rest: List<&2, List<&2, U32>>, acc: List<&2, Ent>,
  refs: List<&2, U32>, wo: Wo) -> CSt:
  match skip:
    case True{}:
      CNextOp{MkCx{root, rest, acc, refs, wo}}
    case False{}:
      match is_root:
        case True{}:
          CRootOpen{MkCx{root, rest, acc, refs, wo}}
        case False{}:
          COpStat{MkCx{root, rest, acc, refs, wo},
            op_join(root, op), op}

def cx_next_kind(+is_root: Bool, +root: List<&2, U32>,
  +op: List<&2, U32>, rest: List<&2, List<&2, U32>>, acc: List<&2, Ent>,
  refs: List<&2, U32>, +wo: Wo) -> CSt:
  cx_next_kind2(Glob.excluded(wo_exc(wo),
    Bool.pick(List<&2, U32>, is_root, bstr("."), op)),
    is_root, root, op, rest, acc, refs, wo)

def cx_next_valid(bad: Bool, root: List<&2, U32>, +op: List<&2, U32>,
  rest: List<&2, List<&2, U32>>, acc: List<&2, Ent>,
  refs: List<&2, U32>, wo: Wo) -> CSt:
  match bad:
    case True{}:
      CErr{"create operand refused (absolute path or '..' escaping the -C root)"}
    case False{}:
      cx_next_kind(op_root(op), root, op, rest, acc, refs, wo)

def cx_next_ops(root: List<&2, U32>, ops: List<&2, List<&2, U32>>,
  acc: List<&2, Ent>, refs: List<&2, U32>, wo: Wo) -> CSt:
  match ops:
    case Nil{}:
      CDone{acc}
    case h <> t:
      +op = h
      cx_next_valid(op_bad(op), root, op, t, acc, refs, wo)

def cnext(+cx: Cx) -> CSt:
  match cx:
    case MkCx{root, ops, acc, refs, wo}:
      cx_next_ops(root, ops, acc, refs, wo)

def Cx_of_reg(c: Cx, refs: List<&2, U32>) -> Cx:
  cx_refs(c, refs)

def cx_keep_reg_if(skip: Bool, +cx: Cx, +st: List<&2, U32>,
  +aname: List<&2, U32>) -> Cx:
  match skip:
    case True{}:
      cx
    case False{}:
      Cx_of_reg(cx_acc(cx, ent_reg(st, aname) <> cx_acc_of(cx)),
        refs_keep(st, aname, cx_refs_of(cx)))

def cx_keep_reg(+cx: Cx, +st: List<&2, U32>, +aname: List<&2, U32>) -> Cx:
  cx_keep_reg_if(U.skip(cx_upd(cx), aname, st_mtime(st)), cx, st, aname)

def op_keep_reg2(hit: Maybe<&2, List<&2, U32>>, +cx: Cx,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match hit:
    case Some{target}:
      CNextOp{cx_add(cx, ent_hard(st, aname, target))}
    case None{}:
      CNextOp{cx_keep_reg(cx, st, aname)}

def op_keep_reg(hit: Maybe<&2, List<&2, U32>>, +cx: Cx,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  op_keep_reg2(hit, cx, aname, st)

def op_stat_leaf2(reg: Bool, +cx: Cx, +aname: List<&2, U32>,
  +st: List<&2, U32>) -> CSt:
  match reg:
    case True{}:
      op_keep_reg(refs_of(st, cx_refs_of(cx)), cx, aname, st)
    case False{}:
      cnext(cx_add(cx, ent_special(aname)))

def op_stat_leaf(sym: Bool, +cx: Cx, full: List<&2, U32>,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match sym:
    case True{}:
      COpLink{cx, full, aname, st}
    case False{}:
      op_stat_leaf2(is_reg(st_type(st)), cx, aname, st)

# --no-recursion: the directory entry itself, not its contents.
def op_dir(norec: Bool, +cx: Cx, full: List<&2, U32>,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match norec:
    case True{}:
      cnext(cx_add(cx, ent_dir(st, aname)))
    case False{}:
      COpOpen{cx_add(cx, ent_dir(st, aname)), full, aname}

def op_stat_kind(isd: Bool, sym: Bool, +cx: Cx, full: List<&2, U32>,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match isd:
    case True{}:
      op_dir(cx_norec(cx), cx, full, aname, st)
    case False{}:
      op_stat_leaf(sym, cx, full, aname, st)

def st_is_sym(st: List<&2, U32>) -> Bool:
  U32.is_eq(st_type(st), 10)

def op_stat_dispatch(+cx: Cx, full: List<&2, U32>,
  aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  op_stat_kind(is_dir(st_type(st)), st_is_sym(st), cx, full, aname, st)

def op_stat_after(r: Result<&1, &1, U32 & String, List<&2, U32>>,
  +cx: Cx, full: List<&2, U32>, aname: List<&2, U32>) -> CSt:
  match r:
    case Fail{(code, msg)}:
      CErr{"create: cannot stat operand: " ++ msg}
    case Done{st}:
      op_stat_dispatch(cx, full, aname, st)

def op_link_done(
  pr: Result<&1, &1, U32 & String, List<&2, U32>>, +cx: Cx,
  +aname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match pr:
    case Fail{(code, msg)}:
      CErr{"create: readlink operand failed: " ++ msg}
    case Done{target}:
      cnext(cx_add(cx, ent_sym(st, aname, target)))

def maybe_sort2(sort: Bool, names: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match sort:
    case True{}:
      sort_names(4096n, names)
    case False{}:
      names

def maybe_sort(sort: Bool, names: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  maybe_sort2(sort, names)

def frame_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>,
  +cx: Cx, prefix: List<&2, U32>
) -> CSt:
  (dir2, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: readdir failed: " ++ msg}
    case Done{names}:
      CNames{cx, StCons{MkFrame{dir2, prefix,
        maybe_sort(cx_sort(cx), names)}, StNil{}}}

def root_dir(norec: Bool, +cx: Cx, +st: List<&2, U32>, dir: File) -> CSt:
  match norec:
    case True{}:
      CCloseOp{cx_add(cx, ent_root_of(st)), dir}
    case False{}:
      CRootRead{cx_add(cx, ent_root_of(st)), dir}

def root_stat_done(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, +cx: Cx) -> CSt:
  (dir2, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: cannot stat root dir: " ++ msg}
    case Done{st}:
      root_dir(cx_norec(cx), cx, st, dir2)

def stack_is_nil(stack: Stack) -> Bool:
  match stack:
    case StNil{}:
      True{}
    case StCons{a, b}:
      False{}

def names_end(+cx: Cx, dir: File, rest: Stack) -> CSt:
  match rest:
    case StNil{}:
      CCloseOp{cx, dir}
    case StCons{f, r}:
      CAscend{cx, StCons{MkFrame{dir, Nil{}, Nil{}}, StCons{f, r}}}

# No patterns: no name is built (the common case stays allocation-free).
def names_excl(exc: List<&2, List<&2, U32>>, +rel: List<&2, U32>,
  +n: List<&2, U32>) -> Bool:
  match exc:
    case Nil{}:
      False{}
    case _ <> _:
      Glob.excluded(exc, B.list_cat(rel, n))

# --exclude: a matching entry is neither archived nor descended into.
def names_skip(skip: Bool, +cx: Cx, dir: File, +rel: List<&2, U32>,
  +n: List<&2, U32>, nt: List<&2, List<&2, U32>>, rest: Stack) -> CSt:
  match skip:
    case True{}:
      CNames{cx, StCons{MkFrame{dir, rel, nt}, rest}}
    case False{}:
      CStat{cx, StCons{MkFrame{dir, rel, nt}, rest}, rel, n}

def names_next(+cx: Cx, dir: File, +rel: List<&2, U32>,
  names: List<&2, List<&2, U32>>, rest: Stack) -> CSt:
  match names:
    case Nil{}:
      names_end(cx, dir, rest)
    case +n <> nt:
      names_skip(names_excl(cx_exc(cx), rel, n), cx, dir, rel, n, nt, rest)

def names_frame(+cx: Cx, frame: Frame, rest: Stack) -> CSt:
  match frame:
    case MkFrame{dir, rel, names}:
      names_next(cx, dir, rel, names, rest)

def names_state(+cx: Cx, stack: Stack) -> CSt:
  match stack:
    case StNil{}:
      CErr{"internal: empty frame stack"}
    case StCons{frame, rest}:
      names_frame(cx, frame, rest)

def stat_done(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, +cx: Cx,
  +rel: List<&2, U32>, names: List<&2, List<&2, U32>>,
  rest: Stack, fname: List<&2, U32>
) -> CSt:
  (dir2, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: stat failed: " ++ msg}
    case Done{st}:
      CEntry{cx, StCons{MkFrame{dir2, rel, names}, rest}, rel, fname, st}

def cx_keep_named(+cx: Cx, +st: List<&2, U32>,
  +nm: List<&2, U32>) -> Cx:
  cx_keep_reg_if(U.skip(cx_upd(cx), nm, st_mtime(st)), cx, st, nm)

def reg_go(hit: Maybe<&2, List<&2, U32>>, +cx: Cx, stack: Stack,
  +rel: List<&2, U32>, +fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match hit:
    case Some{target}:
      CNextName{cx_add(cx, ent_hard(st, B.list_cat(rel, fname), target)),
        stack}
    case None{}:
      +nm = B.list_cat(rel, fname)
      CNames{cx_keep_named(cx, st, nm), stack}

def entry_reg(hit: Maybe<&2, List<&2, U32>>, +cx: Cx, stack: Stack,
  +rel: List<&2, U32>, +fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  reg_go(hit, cx, stack, rel, fname, st)

def entry_bits3(sym: Bool, +cx: Cx, stack: Stack, rel: List<&2, U32>,
  fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match sym:
    case True{}:
      CLink{cx, stack, rel, fname, st}
    case False{}:
      CNextName{cx_add(cx, ent_special(B.list_cat(rel, fname))), stack}

def entry_bits2(isd: Bool, sym: Bool, +cx: Cx, stack: Stack,
  rel: List<&2, U32>, fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match isd:
    case True{}:
      COpenDir{cx, stack, rel, fname, st}
    case False{}:
      entry_bits3(sym, cx, stack, rel, fname, st)

def entry_bits(reg: Bool, isd: Bool, sym: Bool, +cx: Cx, stack: Stack,
  rel: List<&2, U32>, fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  match reg:
    case True{}:
      entry_reg(refs_of(st, cx_refs_of(cx)), cx, stack, rel, fname, st)
    case False{}:
      entry_bits2(isd, sym, cx, stack, rel, fname, st)

def entry_state(+cx: Cx, stack: Stack, rel: List<&2, U32>,
  fname: List<&2, U32>, +st: List<&2, U32>) -> CSt:
  entry_bits(is_reg(st_type(st)), is_dir(st_type(st)), st_is_sym(st), cx,
    stack, rel, fname, st)

def link_done(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, +cx: Cx,
  +rel: List<&2, U32>, names: List<&2, List<&2, U32>>,
  rest: Stack, fname: List<&2, U32>, st: List<&2, U32>
) -> CSt:
  (dir2, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: readlink failed: " ++ msg}
    case Done{target}:
      CNames{cx_add(cx, ent_sym(st, B.list_cat(rel, fname), target)),
        StCons{MkFrame{dir2, rel, names}, rest}}

def opendir_done(
  pr: File & Result<&1, &1, U32 & String, File>, +cx: Cx,
  rel: List<&2, U32>, names: List<&2, List<&2, U32>>, rest: Stack,
  +pfx: List<&2, U32>, +fname: List<&2, U32>, +st: List<&2, U32>
) -> CSt:
  (parent2, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: openat_dir failed: " ++ msg}
    case Done{child}:
      CReadChild{cx_add(cx, ent_dir(st, B.list_cat(pfx, fname))),
        StCons{MkFrame{parent2, rel, names}, rest}, child,
        with_slash(B.list_cat(pfx, fname))}

def child_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, List<&2, U32>>>,
  +cx: Cx, stack: Stack, crel: List<&2, U32>
) -> CSt:
  (dir, res) = pr
  match res:
    case Fail{(code, msg)}:
      CErr{"create: readdir failed: " ++ msg}
    case Done{names}:
      CNames{cx, StCons{MkFrame{dir, crel,
        maybe_sort(cx_sort(cx), names)}, stack}}

def cdrive(fuel: Nat, st: CSt) -> IO(List<&2, Ent>):
  match fuel:
    case 0n:
      IO.die(List<&2, Ent>, 2, "btar: create walk exceeded its step budget")
    case 1n+p:
      match st:
        case CErr{msg}:
          IO.die(List<&2, Ent>, 2, "btar: " ++ msg)
        case CDone{acc}:
          IO.pure(List<&2, Ent>, rev_ent(acc, Nil{}))
        case CStart{cx}:
          cdrive(p, CNextOp{cx})
        case CNextOp{+cx}:
          cdrive(p, cnext(cx))
        case COpStat{+cx, +full, aname}:
          do IO<List<&2, Ent>>:
            pr : Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Fs.stat_path(full)
            cdrive(p, op_stat_after(pr, cx, full, aname))
        case COpLink{+cx, full, aname, st}:
          do IO<List<&2, Ent>>:
            pr : Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Fs.readlink_path(full)
            cdrive(p, op_link_done(pr, cx, aname, st))
        case COpOpen{+cx, full, aname}:
          do IO<List<&2, Ent>>:
            dir : File <- d_root(full)
            cdrive(p, COpRead{cx, dir, with_slash(aname)})
        case COpRead{+cx, dir, prefix}:
          do IO<List<&2, Ent>>:
            pr : File & Result<&1, &1, U32 & String,
              List<&2, List<&2, U32>>> <- Fx.Fs.readdir(dir)
            cdrive(p, frame_after(pr, cx, prefix))
        case CCloseOp{+cx, dir}:
          do IO<List<&2, Ent>>:
            u : Unit <- File.close(dir)
            cdrive(p, CNextOp{cx})
        case CRootOpen{+cx}:
          do IO<List<&2, Ent>>:
            dir : File <- d_root(cx_root(cx))
            cdrive(p, CRootStat{cx, dir})
        case CRootStat{+cx, dir}:
          do IO<List<&2, Ent>>:
            pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Fs.fstatx(dir)
            cdrive(p, root_stat_done(pr, cx))
        case CRootRead{+cx, dir}:
          do IO<List<&2, Ent>>:
            pr : File & Result<&1, &1, U32 & String,
              List<&2, List<&2, U32>>> <- Fx.Fs.readdir(dir)
            cdrive(p, frame_after(pr, cx, bstr("./")))
        case CNames{+cx, stack}:
          cdrive(p, names_state(cx, stack))
        case CStat{+cx, stack, +rel, +fname}:
          match stack:
            case StNil{}:
              IO.die(List<&2, Ent>, 2, "btar: internal: empty frame stack")
            case StCons{frame, rest}:
              match frame:
                case MkFrame{dir, rel2, names}:
                  do IO<List<&2, Ent>>:
                    pr : File & Result<&1, &1, U32 & String,
                      List<&2, U32>> <- Fx.Fs.statx(dir, fname)
                    cdrive(p, stat_done(pr, cx, rel2, names, rest,
                      fname))
        case CEntry{+cx, stack, rel, fname, st}:
          cdrive(p, entry_state(cx, stack, rel, fname, st))
        case CLink{+cx, stack, +rel, +fname, st}:
          match stack:
            case StNil{}:
              IO.die(List<&2, Ent>, 2, "btar: internal: empty frame stack")
            case StCons{frame, rest}:
              match frame:
                case MkFrame{dir, rel2, names}:
                  do IO<List<&2, Ent>>:
                    pr : File & Result<&1, &1, U32 & String,
                      List<&2, U32>> <- Fx.Fs.readlinkat(dir, fname)
                    cdrive(p, link_done(pr, cx, rel2, names, rest,
                      fname, st))
        case COpenDir{+cx, stack, +rel, +fname, st}:
          match stack:
            case StNil{}:
              IO.die(List<&2, Ent>, 2, "btar: internal: empty frame stack")
            case StCons{frame, rest}:
              match frame:
                case MkFrame{dir, rel2, names}:
                  do IO<List<&2, Ent>>:
                    pr : File & Result<&1, &1, U32 & String, File> <-
                      Fx.Fs.openat_dir(dir, fname)
                    cdrive(p, opendir_done(pr, cx, rel2, names, rest,
                      rel, fname, st))
        case CReadChild{+cx, stack, child, crel}:
          do IO<List<&2, Ent>>:
            pr : File & Result<&1, &1, U32 & String,
              List<&2, List<&2, U32>>> <- Fx.Fs.readdir(child)
            cdrive(p, child_after(pr, cx, stack, crel))
        case CAscend{+cx, stack}:
          match stack:
            case StNil{}:
              IO.die(List<&2, Ent>, 2, "btar: internal: empty frame stack")
            case StCons{frame, rest}:
              match frame:
                case MkFrame{dir, rel2, names}:
                  do IO<List<&2, Ent>>:
                    u : Unit <- File.close(dir)
                    cdrive(p, CNames{cx, rest})
        case CNextName{+cx, stack}:
          cdrive(p, CNames{cx, stack})
        case CWarn{+cx, name, stack}:
          do IO<List<&2, Ent>>:
            u : Unit <- warn_io(name)
            cdrive(p, CNames{cx, stack})

def wo_tab(wo: Wo, tab: U.Tab) -> Wo:
  match wo:
    case MkWo{sort, upd, exc, norec}:
      MkWo{sort, tab, exc, norec}

def wo_plain() -> Wo:
  MkWo{False{}, U.TNil{}, Nil{}, False{}}

def collect(root: List<&2, U32>, ops: List<&2, List<&2, U32>>,
  wo: Wo) -> IO(List<&2, Ent>):
  cdrive(1048576n, CStart{MkCx{root, ops, Nil{}, Nil{}, wo}})

# ---- pure step builders -------------------------------------------------

# ---- phase B: write the manifest ----------------------------------------

def split_dir(is_slash: Bool, h: U32, dir: List<&2, U32>,
  last: List<&2, U32>) -> List<&2, U32>:
  match is_slash:
    case True{}:
      B.list_cat(dir, B.list_cat(last, 47 <> Nil{}))
    case False{}:
      dir

def split_last(is_slash: Bool, h: U32, last: List<&2, U32>) ->
  List<&2, U32>:
  match is_slash:
    case True{}:
      Nil{}
    case False{}:
      B.list_cat(last, h <> Nil{})

def path_split(fuel: Nat, xs: List<&2, U32>, dir: List<&2, U32>,
  +last: List<&2, U32>) -> Split:
  match fuel:
    case 0n:
      MkSplit{dir, last}
    case 1n+p:
      match xs:
        case Nil{}:
          MkSplit{dir, last}
        case +h <> t:
          +sl = U32.is_eq(h, 47)
          path_split(p, t, split_dir(sl, h, dir, last),
            split_last(sl, h, last))

def parent_join2(empty: Bool, base: List<&2, U32>, dir: List<&2, U32>) ->
  List<&2, U32>:
  match empty:
    case True{}:
      base
    case False{}:
      B.list_cat(base, B.list_cat(47 <> Nil{}, dir))

def parent_join(base: List<&2, U32>, sp: Split) -> List<&2, U32>:
  match sp:
    case MkSplit{+dir, last}:
      parent_join2(U32.is_eq(U32.from_nat(blen(dir)), 0), base, dir)

def parent_path(base: List<&2, U32>, relname: List<&2, U32>) ->
  List<&2, U32>:
  parent_join(base, path_split(8192n, relname, Nil{}, Nil{}))

def base_from(sp: Split) -> List<&2, U32>:
  match sp:
    case MkSplit{dir, last}:
      last

def base_of(relname: List<&2, U32>) -> List<&2, U32>:
  base_from(path_split(8192n, relname, Nil{}, Nil{}))

def src_after(pr: File & Result<&1, &1, U32 & String, File>) -> IO(File):
  (parent, r) = pr
  match r:
    case Done{src}:
      do IO<File>:
        u : Unit <- File.close(parent)
        IO.pure(File, src)
    case Fail{(code, msg)}:
      IO.die(File, 2, "btar: " ++ msg)

def open_src(base: List<&2, U32>, +relname: List<&2, U32>) -> IO(File):
  do IO<File>:
    parent : File <- d_root(parent_path(base, relname))
    pr : File & Result<&1, &1, U32 & String, File> <-
      Fx.Fs.openat_read(parent, base_of(relname))
    src_after(pr)

def selfid_of(+st: List<&2, U32>) -> List<&2, U32>:
  st_dev_lo(st) <> (st_dev_hi(st) <> (st_ino_lo(st) <> (st_ino_hi(st) <>
    Nil{})))

def is_self(+st: List<&2, U32>, +selfid: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(B.list_is_empty(selfid)),
    Bool.and(U32.is_eq(N.nth(selfid, 0n), st_dev_lo(st)),
      Bool.and(U32.is_eq(N.nth(selfid, 1n), st_dev_hi(st)),
        Bool.and(U32.is_eq(N.nth(selfid, 2n), st_ino_lo(st)),
          U32.is_eq(N.nth(selfid, 3n), st_ino_hi(st))))))

def warn_self(name: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- IO.print_err("btar: " ++ bytes_str(name) ++
      ": archive cannot contain itself; not dumped")
    IO.pure(Unit, Unit{})

def ws_regular(
  self: Bool, src: File, archive: File, base: List<&2, U32>,
  ents: List<&2, Ent>, +cfg: WCfg, lim: Lim.State, warned: Bool,
  selfid: List<&2, U32>, h: Ent, +name: List<&2, U32>, +sz: U32
) -> IO(WS):
  match self:
    case True{}:
      do IO<WS>:
        u : Unit <- File.close(src)
        w : Unit <- warn_self(name)
        IO.pure(WS, WsRun{archive, base, ents, cfg, lim, warned, selfid})
    case False{}:
      do IO<WS>:
        lim2 : Lim.State <- lim_add(lim, sz)
        lim3 : Lim.State <- lim_nm(lim2, name)
        v : Unit <- verb_io(cfg, name)
        a2 : File <- emit(archive, hdr_of(h, cfg), cfg)
        a3 : File <- cp_src(src, a2, sz)
        a4 : File <- wz(a3, pad512(sz))
        IO.pure(WS, WsRun{a4, base, ents, cfg, lim3, warned, selfid})

def ws_stat(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, archive: File,
  base: List<&2, U32>, ents: List<&2, Ent>, cfg: WCfg, lim: Lim.State,
  warned: Bool, +selfid: List<&2, U32>, h: Ent, name: List<&2, U32>, sz: U32
) -> IO(WS):
  (src, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(WS, 2, "btar: " ++ msg)
    case Done{st}:
      ws_regular(is_self(st, selfid), src, archive, base, ents, cfg, lim,
        warned, selfid, h, name, sz)

def ws_open(
  src: File, archive: File, base: List<&2, U32>, ents: List<&2, Ent>,
  cfg: WCfg, lim: Lim.State, warned: Bool, selfid: List<&2, U32>, h: Ent,
  name: List<&2, U32>, sz: U32
) -> IO(WS):
  do IO<WS>:
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.fstatx(src)
    ws_stat(pr, archive, base, ents, cfg, lim, warned, selfid, h, name, sz)

def ws_kind(
  kind: U32, archive: File, +base: List<&2, U32>, ents: List<&2, Ent>,
  +cfg: WCfg, lim: Lim.State, warned: Bool, selfid: List<&2, U32>,
  +h: Ent, +name: List<&2, U32>, +sz: U32
) -> IO(WS):
  match kind:
    case 99:
      do IO<WS>:
        u : Unit <- warn_io(name)
        IO.pure(WS, WsRun{archive, base, ents, cfg, lim, True{}, selfid})
    case 48:
      do IO<WS>:
        src : File <- open_src(base, name)
        ws_open(src, archive, base, ents, cfg, lim, warned, selfid, h, name, sz)
    case _:
      do IO<WS>:
        lim2 : Lim.State <- lim_nm(lim, name)
        v : Unit <- verb_io(cfg, name)
        a2 : File <- emit(archive, hdr_of(h, cfg), cfg)
        IO.pure(WS, WsRun{a2, base, ents, cfg, lim2, warned, selfid})

def ws_ent(
  +h: Ent, archive: File, base: List<&2, U32>, ents: List<&2, Ent>,
  cfg: WCfg, lim: Lim.State, warned: Bool, selfid: List<&2, U32>
) -> IO(WS):
  match h:
    case MkEnt{+name, kind, mode, uid, gid, +sz, mt, link}:
      ws_kind(kind, archive, base, ents, cfg, lim, warned, selfid, h, name, sz)

# Trailing zeros, then cut the file at the write position: for append this
# drops the stale old tail; for a fresh archive, pipe or device it is a no-op.
def ws_end(archive: File, warned: Bool) -> IO(WS):
  do IO<WS>:
    a2 : File <- wz(archive, 1024)
    a3 : File <- wtrunc(a2)
    u1 : Unit <- File.close(a3)
    IO.pure(WS, WsEnd{warned})

def ws_step(
  archive: File, base: List<&2, U32>, ents: List<&2, Ent>, cfg: WCfg,
  lim: Lim.State, warned: Bool, selfid: List<&2, U32>
) -> IO(WS):
  match ents:
    case Nil{}:
      ws_end(archive, warned)
    case h <> t:
      ws_ent(h, archive, base, t, cfg, lim, warned, selfid)

def write_all(fuel: Nat, ws: WS) -> IO(Bool):
  match fuel:
    case 0n:
      IO.die(Bool, 2, "btar: too many archive entries")
    case 1n+p:
      match ws:
        case WsEnd{warned}:
          IO.pure(Bool, warned)
        case WsRun{archive, base, ents, cfg, lim, warned, selfid}:
          do IO<Bool>:
            ws2 : WS <- ws_step(archive, base, ents, cfg, lim, warned, selfid)
            write_all(p, ws2)

# ---- entry point ---------------------------------------------------------

# `start` is the archive offset the writer begins at (append): it seeds the
# byte total so the 4 GiB v1 cap also covers the existing archive.
def write_from(archive: File, selfid: List<&2, U32>, base: List<&2, U32>,
  ents: List<&2, Ent>, cfg: WCfg, start: U32) -> IO(Bool):
  write_all(1048576n, WsRun{archive, base, ents, cfg,
    Lim.MkState{Lim.default_limits(), 0, start}, False{}, selfid})

def write_to(archive: File, selfid: List<&2, U32>, base: List<&2, U32>,
  ents: List<&2, Ent>, cfg: WCfg) -> IO(Bool):
  write_from(archive, selfid, base, ents, cfg, 0)

# Compatibility wrapper for a plain "." walk (used by older call sites/tests).
def create(+root: List<&2, U32>, archive: File, +cfg: WCfg) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- preflight(root, bstr(".") <> Nil{})
    ents : List<&2, Ent> <- collect(root, bstr(".") <> Nil{}, wo_plain())
    w : Bool <- write_to(archive, Nil{}, root, ents, cfg)
    exit_w(w)
