# Module: ReadStream — streaming tar reader / lister / extractor driver (M2).
#
# One effectful driver (`drive`) over one fuel Nat.  Every state performs at
# most one effect call; a pure helper then builds the next D record, and only
# `drive` calls itself (there is no mutual recursion).  All format parsing is
# the pure M1 modules; this file is IO plumbing plus extraction dispatch.
#
# Stream contract: exactly one 512-byte header per Stream.read_exact, then
# skip/copy exactly ceil(size/512)*512 payload bytes with Data.copy (sink =
# /dev/null for -t, the destination fd for -x).  Payload bytes never enter
# Bend; headers/pax records (<= 64 KiB) do.
import Base
import ./bytes.bend as B
import ./header.bend as H
import ./pax.bend as P
import ./entry.bend as E
import ./path.bend as Pth
import ./limits.bend as Lim
import ./extract.bend as X
import ./glob.bend as Glob
import ../effs/effects.bend as Fx

type Cfg is Data:
  MkCfg{
    extract: Bool,
    strip: U32,
    verbose: Bool,
    preserve: Bool,
    to_stdout: Bool,
    euid: U32,
    warned: Bool,
    exc: List<&2, List<&2, U32>>
  }

# ---- next action after a printed name --------------------------------------

type Next is Type:
  NWant{next: U32}
  NSkip{off: U32, next: U32, size: U32}
  NWalk{
    anc: List<&1, List<&2, U32>>,
    last: List<&2, U32>,
    kind: U32,
    mode: U32,
    mtime: U32,
    size: U32,
    next: U32,
    +target: List<&2, U32>,
    tanc: List<&1, List<&2, U32>>,
    newpath: List<&2, U32>
  }

# ---- state ----------------------------------------------------------------

type Ev is Type:
  EvWant{off: U32, +pend: E.Pend}
  EvMeta{off: U32, next: U32, size: U32, +tag: H.Tag, +pend: E.Pend}
  EvPad{next: U32, pad: U32, +pend: E.Pend}
  EvApply{off: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend}
  EvPrint{name: List<&2, U32>, nxt: Next}
  EvSkipData{off: U32, next: U32, size: U32}
  EvWalk{
    anc: List<&1, List<&2, U32>>,
    last: List<&2, U32>,
    kind: U32,
    mode: U32,
    mtime: U32,
    size: U32,
    next: U32,
    +target: List<&2, U32>,
    tanc: List<&1, List<&2, U32>>,
    newpath: List<&2, U32>
  }
  EvDir{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    next: U32
  }
  EvOpen{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    size: U32,
    next: U32
  }
  EvCopy{
    opened: List<&1, File>,
    dest: File,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    size: U32,
    next: U32
  }
  EvCopyPad{
    opened: List<&1, File>,
    dest: File,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    next: U32,
    pad: U32
  }
  EvClose{
    opened: List<&1, File>,
    dest: File,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    next: U32,
    fail: Maybe<&1, U32 & String>
  }
  EvFMeta{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mode: U32,
    mtime: U32,
    next: U32
  }
  EvSymlink{
    opened: List<&1, File>,
    last: List<&2, U32>,
    +target: List<&2, U32>,
    +mtime: U32,
    next: U32
  }
  EvHardlink{
    opened: List<&1, File>,
    last: List<&2, U32>,
    +target: List<&2, U32>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHWalkT{
    opened: List<&1, File>,
    last: List<&2, U32>,
    tanc: List<&1, List<&2, U32>>,
    tlast: List<&2, U32>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHStatT{
    opened: List<&1, File>,
    last: List<&2, U32>,
    topened: List<&1, File>,
    tlast: List<&2, U32>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHLink{
    opened: List<&1, File>,
    last: List<&2, U32>,
    topened: List<&1, File>,
    tlast: List<&2, U32>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHClosT{
    topened: List<&1, File>,
    opened: List<&1, File>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHClosD{
    opened: List<&1, File>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvHStat{
    opened: List<&1, File>,
    last: List<&2, U32>,
    target: List<&2, U32>,
    next: U32,
    newpath: List<&2, U32>
  }
  EvToStd{off: U32, next: U32, size: U32}
  EvWarn{msg: String, off: U32, next: U32, size: U32}
  EvSymMeta{
    opened: List<&1, File>,
    last: List<&2, U32>,
    mtime: U32,
    next: U32
  }
  EvCloseAll{opened: List<&1, File>, next: U32}
  EvDone{}
  EvFail{opened: List<&1, File>, code: U32, msg: String}

# ---- M3 config/policy helpers ---------------------------------------------

# Global pax (`g`) mtime, per-file pax mtime overriding it, header last.
type Gl is Data:
  GlGo{rest: List<&2, U32>, acc: U32}
  GlFin{m: Maybe<&2, U32>}

type D is Type:
  MkD{
    archive: File,
    sink: File,
    root: List<&2, U32>,
    +cfg: Cfg,
    +lim: Lim.State,
    seen: List<&1, List<&2, U32>>,
    +glob: P.Pax,
    st: Ev
  }

# ---- small pure helpers ---------------------------------------------------

# A match cannot scrutinize a computed value in Bend 2.0.39, so computed
# conditions go through this helper: only one thunk runs.
def ifu(-A: Type, c: Bool, t: Unit -> A, f: Unit -> A) -> A:
  match c:
    case True{}:
      t(Unit{})
    case False{}:
      f(Unit{})

def block_size() -> U32:
  512

def max_pax() -> U32:
  65536

def max_component() -> U32:
  255

def max_total() -> U32:
  4096

def mode_mask() -> U32:
  511

# ---- config ----------------------------------------------------------------

def warn_cfg(+cfg: Cfg) -> Cfg:
  match cfg:
    case MkCfg{extract, strip, verbose, preserve, to_stdout, euid, _, exc}:
      MkCfg{extract, strip, verbose, preserve, to_stdout, euid, True{}, exc}

def mode_root(is_root: Bool, +mode0: U32) -> U32:
  match is_root:
    case True{}:
      U32.and(mode0, 4095)
    case False{}:
      U32.and(mode0, 511)

def mode_preserve(preserve: Bool, euid: U32, +mode0: U32) -> U32:
  match preserve:
    case True{}:
      mode_root(U32.is_zero(euid), mode0)
    case False{}:
      U32.and(mode0, 511)

def mode_policy(+cfg: Cfg, +mode0: U32) -> U32:
  match cfg:
    case MkCfg{_, _, _, preserve, _, euid, _, _}:
      mode_preserve(preserve, euid, mode0)

def gl_dig(dig: Bool, h: U32, t: List<&2, U32>, acc: U32) -> Gl:
  match dig:
    case True{}:
      GlGo{t, U32.add(U32.mul(acc, 10), U32.sub(h, 48))}
    case False{}:
      GlFin{None{}}

def bstr_nl(xs: List<&2, U32>) -> List<&2, U32>:
  B.list_cat(xs, 10 <> Nil{})

def len_nat(xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def split_fuel(xs: List<&2, U32>) -> Nat:
  Nat.add(len_nat(xs), 2n)

def clen(xs: List<&1, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      (1n + clen(t) : Nat)

def h_mode(+h: H.Header) -> U32:
  match h:
    case H.MkHeader{_, mode, _, _, _, _, _, _, _, _, _, _, _, _}:
      mode

def h_mtime(+h: H.Header) -> U32:
  match h:
    case H.MkHeader{_, _, _, _, _, mtime, _, _, _, _, _, _, _, _}:
      mtime

def pth_msg(e: Pth.Err) -> String:
  match e:
    case Pth.Empty{}:
      "empty path"
    case Pth.Absolute{}:
      "absolute path refused"
    case Pth.Parent{}:
      "parent traversal refused"
    case Pth.TooLong{}:
      "path too long"
    case Pth.BadComponent{}:
      "bad path component"

def lim_msg(e: Lim.Err) -> String:
  match e:
    case Lim.Members{}:
      "member limit exceeded"
    case Lim.Total{}:
      "total extracted size limit exceeded"
    case Lim.Member{}:
      "member size limit exceeded"
    case Lim.Name{}:
      "member name too long"
    case Lim.Pax{}:
      "pax payload too long"

# off + 512 + ceil(size/512)*512, U32-safe.

def blocks_off(m: Maybe<&2, U32>, +off: U32) ->
  Result<&1, &1, String, U32>:
  match m:
    case None{}:
      Fail{"size overflows the block math"}
    case Some{n}:
      +base = U32.add(off, 512)
      +nxt = U32.add(base, U32.mul(n, 512))
      ifu(Result<&1, &1, String, U32>, U32.is_lt(nxt, off),
        u => Fail{"archive offset overflow"}, u => Done{nxt})

def next_off(+off: U32, +size: U32) -> Result<&1, &1, String, U32>:
  blocks_off(B.blocks(size), off)

def blocks_pad(m: Maybe<&2, U32>, +size: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{n}:
      U32.sub(U32.mul(n, 512), size)

# The first pax record length prefix must be a small U32 followed by a space;
# a prefix past U32 (pax_length_overflow) or above the pax cap is refused.

def pax_digits(fuel: Nat, xs: List<&2, U32>, +acc: U32, any: Bool) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match xs:
        case Nil{}:
          False{}
        case +h <> +t:
          ifu(Bool, U32.is_eq(h, 32),
            u => Bool.and(any, U32.is_le(acc, max_pax())),
            u => ifu(Bool, Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57)),
              v => ifu(Bool, U32.is_gt(acc, 429496729),
                w => False{},
                w => pax_digits(p, t,
                  U32.add(U32.mul(acc, 10), U32.sub(h, 48)), True{})),
              v => False{}))

def pax_len_ok(+xs: List<&2, U32>) -> Bool:
  pax_digits(Nat.add(len_nat(xs), 2n), xs, 0, False{})

def tag_kind(+tag: H.Tag) -> U32:
  match tag:
    case H.KRegular{}:
      1
    case H.KHardlink{}:
      2
    case H.KSymlink{}:
      3
    case H.KDir{}:
      4
    case H.KChar{}:
      5
    case H.KBlock{}:
      6
    case H.KFifo{}:
      7
    case H.KContig{}:
      8
    case H.KPaxLocal{}:
      9
    case H.KPaxGlobal{}:
      10
    case H.KLongName{}:
      11
    case H.KLongLink{}:
      12
    case H.KOther{}:
      13

# ---- shared builders ------------------------------------------------------

def fail_d(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  opened: List<&1, File>, +code: U32, msg: String
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvFail{opened, code, "btar: " ++ msg}}

def skip_d(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvSkipData{off, next, size}}

def pend_set_pax(inherit: E.Pend, p: P.Pax) -> E.Pend:
  match inherit:
    case E.MkPend{_, lname, llink}:
      E.MkPend{Some{p}, lname, llink}

def pend_set_lname(inherit: E.Pend, v: List<&2, U32>) -> E.Pend:
  match inherit:
    case E.MkPend{pax, _, llink}:
      E.MkPend{pax, Some{v}, llink}

def pend_set_llink(inherit: E.Pend, v: List<&2, U32>) -> E.Pend:
  match inherit:
    case E.MkPend{pax, lname, _}:
      E.MkPend{pax, lname, Some{v}}

# ---- EvWant / header

def meta_next(
  res: Result<&1, &1, String, U32>, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +pend: E.Pend, fuel: Nat, +tag: H.Tag, +sz: U32
) -> D:
  match res:
    case Fail{msg}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2, msg)
    case Done{nxt}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvMeta{off, nxt, sz, tag, pend}}

def pax_size_case(
  c: Bool, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32,
  +pend: E.Pend, fuel: Nat, +tag: H.Tag, +sz: U32
) -> D:
  match c:
    case True{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "pax payload over the 64 KiB cap")
    case False{}:
      meta_next(next_off(off, sz), archive, sink, root, cfg, lim, seen, glob,
        off, pend, fuel, tag, sz)

# ---- EvMeta ---------------------------------------------------------------

def pad_of(+size: U32) -> U32:
  blocks_pad(B.blocks(size), size)

def meta_fin(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, next: U32, size: U32,
  fuel: Nat, +pend: E.Pend
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvPad{next, pad_of(size), pend}}

def pad_after(
  pr: File & (File & Result<&1, &1, U32 & String, Unit>),
  fuel: Nat, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, next: U32, +pend: E.Pend
) -> D:
  (archive, rest) = pr
  (sink, r) = rest
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvWant{next, pend}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}

# ---- EvApply: pure dispatch ----------------------------------------------

def apply_list(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  +name = E.resolve_name(h, pend)
  +skip = U32.add(size, pad_of(size))
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvPrint{name, NSkip{off, next, skip}}}

def walk_plan(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, kind: U32,
  +mode: U32, +mtime: U32, +size: U32, +next: U32,
  ends: X.Ends, +target: List<&2, U32>,
  tanc: List<&1, List<&2, U32>>,
  newpath: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  match ends:
    case X.MkEnds{anc, last}:
      match verbose:
        case True{}:
          MkD{archive, sink, root, cfg, lim, seen, glob,
            EvPrint{raw, NWalk{anc, last, kind, mode, mtime, size, next,
              target, tanc, newpath}}}
        case False{}:
          MkD{archive, sink, root, cfg, lim, seen, glob,
            EvWalk{anc, last, kind, mode, mtime, size, next, target, tanc,
              newpath}}

# ---- EvPrint --------------------------------------------------------------

def print_routed(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, nxt: Next
) -> D:
  match nxt:
    case NWant{next}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvWant{next, E.empty_pend()}}
    case NSkip{off, next, size}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvSkipData{off, next, size}}
    case NWalk{anc, last, kind, mode, mtime, size, next, target, tanc,
        newpath}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvWalk{anc, last, kind, mode, mtime, size, next, target, tanc,
          newpath}}

# ---- EvSkipData -----------------------------------------------------------

def skip_after(
  pr: File & (File & Result<&1, &1, U32 & String, Unit>),
  fuel: Nat, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32
) -> D:
  (archive, rest) = pr
  (sink, r) = rest
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvWant{next, E.empty_pend()}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}

# ---- EvWalk ---------------------------------------------------------------

def walk_kind3(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, kind: U32, +mode: U32,
  +mtime: U32, +size: U32, +next: U32, +target: List<&2, U32>,
  tanc: List<&1, List<&2, U32>>, newpath: List<&2, U32>,
  last: List<&2, U32>, opened: List<&1, File>
) -> D:
  match kind:
    case 3:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvSymlink{opened, last, target, mtime, next}}
    case _:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvHWalkT{opened, last, tanc, target, next, newpath}}

def dir_after(
  mr: X.MetaRes, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32
) -> D:
  match mr:
    case X.MOk{opened}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvCloseAll{opened, next}}
    case X.MErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, "btar: " ++ msg}}

def open_after(
  cr: X.Cre, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, last: List<&2, U32>,
  +mode: U32, +mtime: U32, +size: U32, +next: U32
) -> D:
  match cr:
    case X.CrFile{opened, file}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvCopy{opened, file, last, mode, mtime, size, next}}
    case X.CrUnit{opened}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, 2, "btar: unexpected unit create for a regular file"}}
    case X.CrErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, msg}}

def copy_pad_after(
  pr: File & (File & Result<&1, &1, U32 & String, Unit>),
  fuel: Nat, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, opened: List<&1, File>,
  dest: File, last: List<&2, U32>, mode: U32, mtime: U32, next: U32
) -> D:
  (archive, rest) = pr
  (sink, r) = rest
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvClose{opened, dest, last, mode, mtime, next, None{}}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvClose{opened, dest, last, mode, mtime, next,
          Some{(code, "btar: " ++ msg)}}}

def copy_after(
  pr: File & (File & Result<&1, &1, U32 & String, Unit>),
  fuel: Nat, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, opened: List<&1, File>,
  last: List<&2, U32>, +mode: U32, +mtime: U32, +size: U32, +next: U32
) -> D:
  (archive, rest) = pr
  (dest, r) = rest
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvCopyPad{opened, dest, last, mode, mtime, next, pad_of(size)}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvClose{opened, dest, last, mode, mtime, next,
          Some{(code, "btar: " ++ msg)}}}

def close_fail(
  f: U32 & String, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, opened: List<&1, File>,
  last: List<&2, U32>, mode: U32, mtime: U32, next: U32
) -> D:
  (code, msg) = f
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvFail{opened, code, msg}}

def fmeta_after(
  mr: X.MetaRes, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32
) -> D:
  match mr:
    case X.MOk{opened}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvCloseAll{opened, next}}
    case X.MErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, "btar: " ++ msg}}

def symlink_after(
  cr: X.Cre, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +last: List<&2, U32>,
  +mtime: U32, +next: U32
) -> D:
  match cr:
    case X.CrUnit{opened}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvSymMeta{opened, last, mtime, next}}
    case X.CrFile{opened, file}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, 2, "btar: unexpected file create for a symlink"}}
    case X.CrErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, msg}}

def hardlink_after(
  cr: X.Cre, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32,
  newpath: List<&2, U32>
) -> D:
  match cr:
    case X.CrUnit{opened}:
      MkD{archive, sink, root, cfg, lim, newpath <> seen, glob,
        EvCloseAll{opened, next}}
    case X.CrFile{opened, file}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, 2, "btar: unexpected file create for a hardlink"}}
    case X.CrErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, msg}}

def fst_u32(v: U32 & U32) -> U32:
  (a, b) = v
  a

def hstat_case(
  c: Bool, opened: List<&1, File>, last: List<&2, U32>,
  target: List<&2, U32>, +next: U32, +newpath: List<&2, U32>, fuel: Nat,
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax
) -> D:
  match c:
    case True{}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvHardlink{opened, last, target, next, newpath}}
    case False{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, opened, 2,
        "hardlink target is not a regular file")

def close_tail(opened: List<&1, File>) -> List<&1, File>:
  match opened:
    case Nil{}:
      Nil{}
    case _ <> t:
      t

def stdout_after(
  pr: File & Result<&1, &1, U32 & String, Unit>, fuel: Nat, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32
) -> D:
  (archive, r) = pr
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvPad{next, pad_of(size), E.empty_pend()}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}

def warn_after(
  u: Unit, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32
) -> D:
  MkD{archive, sink, root, warn_cfg(cfg), lim, seen, glob,
    EvSkipData{off, next, U32.add(size, pad_of(size))}}

def finish_warned(warned: Bool) -> IO(Unit):
  match warned:
    case True{}:
      IO.exit(1)
    case False{}:
      IO.pure(Unit, Unit{})

def finish_cfg(+cfg: Cfg) -> IO(Unit):
  match cfg:
    case MkCfg{_, _, _, _, _, _, +warned, _}:
      finish_warned(warned)

def hwt_after(
  w: X.Walk, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  opn: List<&1, File>, last: List<&2, U32>, tlast: List<&2, U32>,
  +next: U32, +newpath: List<&2, U32>
) -> D:
  match w:
    case X.WOk{opened}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvHStatT{opn, last, opened, tlast, next, newpath}}
    case X.WErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, "btar: hardlink target: " ++ msg}}

def hstatT_case(
  c: Bool, opn: List<&1, File>, last: List<&2, U32>,
  topened: List<&1, File>, tlast: List<&2, U32>, +next: U32,
  +newpath: List<&2, U32>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax
) -> D:
  match c:
    case True{}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvHLink{opn, last, topened, tlast, next, newpath}}
    case False{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, topened, 2,
        "hardlink target is not a regular file")

def hstatT_after(
  pr: File & Result<&1, &1, U32 & String, U32 & U32>,
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  opn: List<&1, File>, last: List<&2, U32>, ttail: List<&1, File>,
  tlast: List<&2, U32>, +next: U32, +newpath: List<&2, U32>
) -> D:
  (tparent, r) = pr
  match r:
    case Fail{(code, msg)}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, opn, code,
        "hardlink target: " ++ msg)
    case Done{v}:
      hstatT_case(U32.is_eq(U32.div(fst_u32(v), 4096), 8), opn, last,
        tparent <> ttail, tlast, next, newpath, fuel, archive, sink, root,
        cfg, lim, seen, glob)

def hlink_after(
  pr: File & (File & Result<&1, &1, U32 & String, Unit>), fuel: Nat,
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  dtail: List<&1, File>, ttail: List<&1, File>, +tlast: List<&2, U32>,
  +next: U32, +newpath: List<&2, U32>
) -> D:
  (from, rest) = pr
  (to, r) = rest
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvHClosT{from <> ttail, to <> dtail, next, newpath}}
    case Fail{(code, msg)}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob,
        from <> ttail, code, "hardlink: " ++ msg)

def hclosT_after(
  u: Unit, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  opn: List<&1, File>, +next: U32, +newpath: List<&2, U32>
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvHClosD{opn, next, newpath}}

def hclosD_after(
  u: Unit, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +next: U32, +newpath: List<&2, U32>
) -> D:
  MkD{archive, sink, root, cfg, lim, newpath <> seen, glob,
    EvWant{next, E.empty_pend()}}

def closeall_after(
  u: Unit, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvWant{next, E.empty_pend()}}

# ---- the one driver -------------------------------------------------------

def meta_split(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +pend: E.Pend,
  fuel: Nat, +tag: H.Tag, +sz: U32
) -> D:
  pax_size_case(U32.is_gt(sz, max_pax()), archive, sink, root, cfg, lim,
    seen, glob, off, pend, fuel, tag, sz)

def meta_case(
  c: Bool, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +pend: E.Pend,
  fuel: Nat, +tag: H.Tag, +sz: U32, +h: H.Header
) -> D:
  match c:
    case True{}:
      meta_split(archive, sink, root, cfg, lim, seen, glob, off, pend, fuel,
        tag, sz)
    case False{}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvApply{off, h, tag, pend}}

def comps_case(
  comps: List<&1, List<&2, U32>>, kind: U32, fuel: Nat,
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, off: U32, +next: U32,
  +size: U32, +mode: U32, +mtime: U32, +target: List<&2, U32>,
  tanc: List<&1, List<&2, U32>>, newpath: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool
) -> D:
  match comps:
    case Nil{}:
      skip_d(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        U32.add(size, pad_of(size)))
    case _:
      walk_plan(fuel, archive, sink, root, cfg, lim, seen, glob, kind, mode,
        mtime, size, next, X.ends(comps), target, tanc, newpath, raw, verbose)

def print_after(
  pr: Result<&1, &1, U32 & String, Unit>,
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, nxt: Next
) -> D:
  match pr:
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}
    case Done{u}:
      print_routed(fuel, archive, sink, root, cfg, lim, seen, glob, nxt)

def walk_kind2(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, kind: U32, +mode: U32,
  +mtime: U32, +size: U32, +next: U32, +target: List<&2, U32>,
  tanc: List<&1, List<&2, U32>>, newpath: List<&2, U32>,
  last: List<&2, U32>, opened: List<&1, File>
) -> D:
  match kind:
    case 1:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvOpen{opened, last, mode, mtime, size, next}}
    case _:
      walk_kind3(fuel, archive, sink, root, cfg, lim, seen, glob, kind, mode,
        mtime, size, next, target, tanc, newpath, last, opened)

def close_done(
  u: Unit, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, opened: List<&1, File>,
  last: List<&2, U32>, +mode: U32, +mtime: U32, +next: U32,
  fail: Maybe<&1, U32 & String>
) -> D:
  match fail:
    case Some{f}:
      close_fail(f, fuel, archive, sink, root, cfg, lim, seen, glob, opened,
        last, mode, mtime, next)
    case None{}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFMeta{opened, last, mode, mtime, next}}

def want_parsed(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +pend: E.Pend,
  fuel: Nat, res: Result<&1, &1, String, H.Header>
) -> D:
  match res:
    case Fail{error}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        error)
    case Done{+h}:
      +tag = H.classify_header(h)
      meta_case(E.is_meta(tag), archive, sink, root, cfg, lim, seen, glob,
        off, pend, fuel, tag, H.h_size(h), h)

def zero_case(
  c: Bool, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32,
  +pend: E.Pend, fuel: Nat, blk: List<&2, U32>
) -> D:
  match c:
    case True{}:
      MkD{archive, sink, root, cfg, lim, seen, glob, EvDone{}}
    case False{}:
      want_parsed(archive, sink, root, cfg, lim, seen, glob, off, pend, fuel,
        H.parse_block(blk))

def walk_made(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, kind: U32, +mode: U32,
  +mtime: U32, +size: U32, +next: U32, +target: List<&2, U32>,
  tanc: List<&1, List<&2, U32>>, newpath: List<&2, U32>,
  last: List<&2, U32>, opened: List<&1, File>
) -> D:
  match kind:
    case 4:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvDir{opened, last, mode, mtime, next}}
    case _:
      walk_kind2(fuel, archive, sink, root, cfg, lim, seen, glob, kind, mode,
        mtime, size, next, target, tanc, newpath, last, opened)

def walk_after(
  w: X.Walk, fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, kind: U32,
  +mode: U32, +mtime: U32, +size: U32, +next: U32,
  +target: List<&2, U32>, tanc: List<&1, List<&2, U32>>,
  newpath: List<&2, U32>, last: List<&2, U32>
) -> D:
  match w:
    case X.WOk{opened}:
      walk_made(fuel, archive, sink, root, cfg, lim, seen, glob, kind, mode, mtime,
        size, next, target, tanc, newpath, last, opened)
    case X.WErr{opened, code, msg}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, msg}}

def meta_apply(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, next: U32, size: U32,
  +tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  match tag:
    case H.KPaxLocal{}:
      meta_fin(archive, sink, root, cfg, lim, seen, glob, next, size, fuel,
        pend_set_pax(pend, P.parse(bs)))
    case H.KPaxGlobal{}:
      meta_fin(archive, sink, root, cfg, lim, seen, P.parse(bs), next, size,
        fuel, pend)
    case H.KLongName{}:
      meta_fin(archive, sink, root, cfg, lim, seen, glob, next, size, fuel,
        pend_set_lname(pend, E.links_payload(B.from_list(bs))))
    case H.KLongLink{}:
      meta_fin(archive, sink, root, cfg, lim, seen, glob, next, size, fuel,
        pend_set_llink(pend, E.links_payload(B.from_list(bs))))
    case _:
      meta_fin(archive, sink, root, cfg, lim, seen, glob, next, size, fuel,
        pend)

def pax_case(
  r: Result<&1, &1, Lim.Err, Lim.State>, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>,
  +glob: P.Pax, +next: U32, +size: U32, +tag: H.Tag, +pend: E.Pend, fuel: Nat,
  +bs: List<&2, U32>
) -> D:
  match r:
    case Fail{e}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        lim_msg(e))
    case Done{lim2}:
      meta_apply(archive, sink, root, cfg, lim2, seen, glob, next, size, tag,
        pend, fuel, bs)

def pax_capped(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  pax_case(Lim.check_pax(lim, U32.from_nat(len_nat(bs))), archive, sink,
    root, cfg, lim, seen, glob, next, size, tag, pend, fuel, bs)

def pax_len_case(
  c: Bool, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  match c:
    case True{}:
      pax_capped(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)
    case False{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "malformed pax record length")

def pax_checked(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  pax_len_case(pax_len_ok(bs), archive, sink, root, cfg, lim, seen, glob,
    next, size, tag, pend, fuel, bs)

def meta_kind_case(
  c: Bool, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  match c:
    case True{}:
      pax_checked(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)
    case False{}:
      meta_apply(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)

def meta_checked(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +next: U32, +size: U32,
  tag: H.Tag, +pend: E.Pend, fuel: Nat, +bs: List<&2, U32>
) -> D:
  match tag:
    case H.KPaxLocal{}:
      pax_checked(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)
    case H.KPaxGlobal{}:
      pax_checked(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)
    case _:
      meta_apply(archive, sink, root, cfg, lim, seen, glob, next, size, tag,
        pend, fuel, bs)

def meta_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  fuel: Nat, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +next: U32, +size: U32, +tag: H.Tag, +pend: E.Pend
) -> D:
  (archive, r) = pr
  match r:
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}
    case Done{bs}:
      meta_checked(archive, sink, root, cfg, lim, seen, glob, next, size,
        tag, pend, fuel, bs)

def want_block(
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +pend: E.Pend,
  fuel: Nat, +blk: List<&2, U32>
) -> D:
  zero_case(B.all_zero(blk, True{}), archive, sink, root, cfg, lim, seen,
    glob, off, pend, fuel, blk)

def want_len(
  n: Nat, +bs: List<&2, U32>, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32,
  +pend: E.Pend, fuel: Nat
) -> D:
  match n:
    case 512n:
      want_block(archive, sink, root, cfg, lim, seen, glob, off, pend, fuel,
        bs)
    case _:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "truncated header block")

def want_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  fuel: Nat, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +pend: E.Pend
) -> D:
  (archive, r) = pr
  match r:
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{Nil{}, code, "btar: " ++ msg}}
    case Done{+bs}:
      want_len(512n, bs, archive, sink, root, cfg, lim, seen, glob,
        off, pend, fuel)

def hard_parent_case(
  tanc: List<&1, List<&2, U32>>, tlast: List<&2, U32>,
  nlast: List<&2, U32>, +nparent: List<&2, U32>, +norm: List<&2, U32>,
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32,
  +next: U32, +h: H.Header, raw: List<&2, U32>, verbose: Bool
) -> D:
  walk_plan(fuel, archive, sink, root, cfg, lim, seen, glob, 2,
    h_mode(h), h_mtime(h), 0, next,
    X.MkEnds{X.split(split_fuel(nparent), nparent), nlast}, tlast, tanc, norm,
    raw, verbose)

def hard_pair(
  pt: List<&2, U32> & List<&2, U32>,
  pn: List<&2, U32> & List<&2, U32>,
  +norm: List<&2, U32>, fuel: Nat, archive: File,
  sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +h: H.Header, raw: List<&2, U32>, verbose: Bool
) -> D:
  (+tparent, tlast) = pt
  (nparent, nlast) = pn
  tanc : List<&1, List<&2, U32>> =
    X.split(split_fuel(tparent), tparent)
  hard_parent_case(tanc, tlast, nlast, nparent, norm, fuel, archive, sink,
    root, cfg, lim, seen, glob, off, next, h, raw, verbose)

# A name stripped away entirely (--strip-components) is skipped, like GNU.
def hard_gate(
  empty: Bool, nt: List<&2, U32>, +norm: List<&2, U32>, fuel: Nat,
  archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +h: H.Header, raw: List<&2, U32>, verbose: Bool
) -> D:
  match empty:
    case True{}:
      skip_d(fuel, archive, sink, root, cfg, lim, seen, glob, off, next, 0)
    case False{}:
      hard_pair(X.split_last(nt), X.split_last(norm), norm, fuel,
        archive, sink, root, cfg, lim, seen, glob, off, next, h, raw,
        verbose)

def hard_norm2(
  r: Result<&1, &1, Pth.Err, List<&2, U32>>, fuel: Nat, archive: File,
  sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +h: H.Header, +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  match r:
    case Fail{pe}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "hardlink target unsafe: " ++ pth_msg(pe))
    case Done{nt}:
      hard_gate(U32.is_zero(U32.from_nat(len_nat(norm))), nt, norm, fuel,
        archive, sink, root, cfg, lim, seen, glob, off, next, h, raw,
        verbose)

def cfg_strip(+cfg: Cfg) -> U32:
  match cfg:
    case MkCfg{_, strip, _, _, _, _, _, _}:
      strip

# Hardlink targets are archive paths: strip the same leading components as
# the member name (GNU), then normalise them through Pth.safe (drop
# empty/"." components, reject absolute/parent/overlong) before split_last,
# the seen lookup and the dirfd walk. Symlink targets stay literal.
def hard_norm(
  +target: List<&2, U32>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +h: H.Header, +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  hard_norm2(Pth.safe(max_component(), max_total(),
    Pth.strip(cfg_strip(cfg), target)), fuel, archive,
    sink, root, cfg, lim, seen, glob, off, next, h, norm, raw, verbose)

def hard_target(
  m: Maybe<&2, List<&2, U32>>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +h: H.Header, +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  match m:
    case None{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "hardlink without a target")
    case Some{target}:
      hard_norm(target, fuel, archive, sink, root, cfg, lim, seen, glob,
        off, next, h, norm, raw, verbose)

def apply_stdout(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +tag: H.Tag
) -> D:
  match tag:
    case H.KRegular{}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvToStd{off, next, size}}
    case _:
      skip_d(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        U32.add(size, pad_of(size)))

def hstat_after(
  pr: File & Result<&1, &1, U32 & String, U32 & U32>,
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  tail: List<&1, File>, last: List<&2, U32>, target: List<&2, U32>,
  +next: U32, +newpath: List<&2, U32>
) -> D:
  (parent, r) = pr
  match r:
    case Fail{(code, msg)}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob,
        parent <> tail, code, "hardlink target: " ++ msg)
    case Done{v}:
      hstat_case(U32.is_eq(U32.div(fst_u32(v), 4096), 8), parent <> tail,
        last, target, next, newpath, fuel, archive, sink, root, cfg, lim,
        seen, glob)

def gl_step(term: Bool, dig: Bool, h: U32, t: List<&2, U32>, acc: U32) ->
  Gl:
  match term:
    case True{}:
      GlFin{Some{acc}}
    case False{}:
      gl_dig(dig, h, t, acc)

def gl_run(fuel: Nat, st: Gl) -> Maybe<&2, U32>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case GlFin{m}:
          m
        case GlGo{rest, acc}:
          match rest:
            case Nil{}:
              Some{acc}
            case +h <> +t:
              gl_run(p,
                gl_step(U32.is_eq(h, 46),
                  Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57)), h, t, acc))

# pax mtime may carry fractional seconds: use the integer part.

def pax_u32(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, U32>:
  match m:
    case None{}:
      None{}
    case Some{v}:
      gl_run(8192n, GlGo{v, 0})

def mtime_or2(m: Maybe<&2, U32>, h: H.Header) -> U32:
  match m:
    case Some{u}:
      u
    case None{}:
      h_mtime(h)

def mtime_glob(glob: P.Pax, h: H.Header) -> U32:
  match glob:
    case P.MkPax{_, _, _, mtime, _, _, _, _}:
      mtime_or2(pax_u32(mtime), h)

def mtime_or_go(pm: Maybe<&2, U32>, glob: P.Pax, h: H.Header) -> U32:
  match pm:
    case Some{u}:
      u
    case None{}:
      mtime_glob(glob, h)

def mtime_or(m: Maybe<&2, List<&2, U32>>, glob: P.Pax, h: H.Header)
  -> U32:
  mtime_or_go(pax_u32(m), glob, h)

def mtime_pend(p: P.Pax, glob: P.Pax, h: H.Header) -> U32:
  match p:
    case P.MkPax{_, _, _, mtime, _, _, _, _}:
      mtime_or(mtime, glob, h)

def eff_mtime(+h: H.Header, +pend: E.Pend, +glob: P.Pax) -> U32:
  match pend:
    case E.MkPend{pax, _, _}:
      match pax:
        case Some{p}:
          mtime_pend(p, glob, h)
        case None{}:
          mtime_glob(glob, h)

# ---- driver record --------------------------------------------------------

def symmeta_after(
  p2: File & Result<&1, &1, U32 & String, Unit>, fuel: Nat, archive: File,
  sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, opened: List<&1, File>,
  +next: U32
) -> D:
  (parent, r) = p2
  match r:
    case Done{u}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvCloseAll{parent <> close_tail(opened), next}}
    case Fail{(code, msg)}:
      MkD{archive, sink, root, cfg, lim, seen, glob,
        EvFail{opened, code, "btar: " ++ msg}}

# The utimensat effect returns the dir handle; keep the chain shape (it is
# always the head that was passed in).

def link_plan(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +h: H.Header, +norm: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool, +target: List<&2, U32>,
  +pend: E.Pend
) -> D:
  comps = X.split(split_fuel(norm), norm)
  comps_case(comps, 3, fuel, archive, sink, root, cfg, lim, seen, glob,
    off, next, 0, mode_policy(cfg, h_mode(h)), eff_mtime(h, pend, glob),
    target, Nil{}, norm, raw, verbose)

def apply_regular(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  comps = X.split(split_fuel(norm), norm)
  comps_case(comps, 1, fuel, archive, sink, root, cfg, lim, seen, glob,
    off, next, size, mode_policy(cfg, h_mode(h)), eff_mtime(h, pend, glob),
    Nil{}, Nil{}, norm, raw, verbose)

def apply_dir(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  comps = X.split(split_fuel(norm), norm)
  comps_case(comps, 4, fuel, archive, sink, root, cfg, lim, seen, glob,
    off, next, size, mode_policy(cfg, h_mode(h)), eff_mtime(h, pend, glob),
    Nil{}, Nil{}, norm, raw, verbose)

def link_target(
  m: Maybe<&2, List<&2, U32>>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>,
  +glob: P.Pax, +off: U32, +next: U32, +h: H.Header, +norm: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool, +pend: E.Pend
) -> D:
  match m:
    case None{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "symlink without a target")
    case Some{target}:
      link_plan(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        h, norm, raw, verbose, target, pend)

def link_by_kind(
  +kind: U32, fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +h: H.Header, +pend: E.Pend, +norm: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool
) -> D:
  match kind:
    case 3:
      link_target(E.resolve_link(h, pend), fuel, archive, sink, root, cfg,
        lim, seen, glob, off, next, h, norm, raw, verbose, pend)
    case _:
      hard_target(E.resolve_link(h, pend), fuel, archive, sink, root, cfg,
        lim, seen, glob, off, next, h, norm, raw, verbose)

def link_size_case(
  c: Bool, +kind: U32, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  match c:
    case True{}:
      link_by_kind(kind, fuel, archive, sink, root, cfg, lim, seen, glob,
        off, next, h, pend, norm, raw, verbose)
    case False{}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        "unexpected data blocks on a link entry: " ++ U32.show(size))

def apply_link(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  link_size_case(U32.is_zero(size), 3, fuel, archive, sink, root, cfg, lim,
    seen, glob, off, next, size, h, pend, norm, raw, verbose)

def apply_hard(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  link_size_case(U32.is_zero(size), 2, fuel, archive, sink, root, cfg, lim,
    seen, glob, off, next, size, h, pend, norm, raw, verbose)

def tag_plan(
  +tag: H.Tag, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +size: U32, +h: H.Header, +pend: E.Pend, +norm: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool
) -> D:
  match tag:
    case H.KRegular{}:
      apply_regular(fuel, archive, sink, root, cfg, lim, seen, glob, off,
        next, size, h, pend, norm, raw, verbose)
    case H.KHardlink{}:
      apply_hard(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        size, h, pend, norm, raw, verbose)
    case H.KSymlink{}:
      apply_link(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        size, h, pend, norm, raw, verbose)
    case H.KDir{}:
      apply_dir(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        size, h, pend, norm, raw, verbose)
    case _:
      MkD{archive, sink, root, warn_cfg(cfg), lim, seen, glob,
        EvWarn{"btar: skipping unsupported entry type in archive", off, next,
          size}}

def member_case(
  r: Result<&1, &1, Lim.Err, Lim.State>, fuel: Nat, archive: File,
  sink: File, root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State,
  seen: List<&1, List<&2, U32>>, +glob: P.Pax, +off: U32, +next: U32,
  +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend, +norm: List<&2, U32>,
  +raw: List<&2, U32>, verbose: Bool
) -> D:
  match r:
    case Fail{e}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        lim_msg(e))
    case Done{lim2}:
      tag_plan(tag, fuel, archive, sink, root, cfg, lim2, seen, glob, off,
        next, size, h, pend, norm, raw, verbose)

def apply_checked(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend,
  +norm: List<&2, U32>, +raw: List<&2, U32>, verbose: Bool
) -> D:
  member_case(Lim.add_member(lim, size), fuel, archive, sink, root, cfg, lim,
    seen, glob, off, next, size, h, tag, pend, norm, raw, verbose)

def safe_case(
  r: Result<&1, &1, Pth.Err, List<&2, U32>>, lim1: Lim.State,
  +stripped: List<&2, U32>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>,
  +glob: P.Pax, +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag,
  +pend: E.Pend, +raw: List<&2, U32>, verbose: Bool
) -> D:
  match r:
    case Fail{pe}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        pth_msg(pe))
    case Done{norm}:
      apply_checked(fuel, archive, sink, root, cfg, lim1, seen, glob, off,
        next, size, h, tag, pend, norm, raw, verbose)

def name_case(
  r: Result<&1, &1, Lim.Err, Lim.State>, +stripped: List<&2, U32>,
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend,
  +raw: List<&2, U32>, verbose: Bool
) -> D:
  match r:
    case Fail{e}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2,
        lim_msg(e))
    case Done{lim1}:
      safe_case(Pth.safe(max_component(), max_total(), stripped), lim1,
        stripped, fuel, archive, sink, root, cfg, lim, seen, glob, off,
        next, size, h, tag, pend, raw, verbose)

def apply_extract(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend,
  +strip: U32, verbose: Bool
) -> D:
  +raw = E.resolve_name(h, pend)
  +stripped = Pth.strip(strip, raw)
  name_case(Lim.check_name(lim, U32.from_nat(len_nat(stripped))), stripped,
    fuel, archive, sink, root, cfg, lim, seen, glob, off, next, size, h, tag,
    pend, raw, verbose)

def extract_mode(
  ts: Bool, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend,
  +strip: U32, verbose: Bool
) -> D:
  match ts:
    case True{}:
      apply_stdout(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        size, tag)
    case False{}:
      apply_extract(fuel, archive, sink, root, cfg, lim, seen, glob, off,
        next, size, h, tag, pend, strip, verbose)

# -O: only regular-file payloads go to stdout; nothing is created on disk.

def apply_cfg2(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  match cfg:
    case MkCfg{extract, strip, verbose, _, to_stdout, _, _, _}:
      match extract:
        case False{}:
          apply_list(fuel, archive, sink, root, cfg, lim, seen, glob, off,
            next, size, h, tag, pend)
        case True{}:
          extract_mode(to_stdout, fuel, archive, sink, root, cfg, lim, seen,
            glob, off, next, size, h, tag, pend, strip, verbose)

# --exclude: a matching member (by its stored name, before --strip-components)
# is skipped: not listed, not extracted, its payload is read past.
def cfg_exc(+cfg: Cfg) -> List<&2, List<&2, U32>>:
  match cfg:
    case MkCfg{_, _, _, _, _, _, _, exc}:
      exc

def cfg_excl(exc: List<&2, List<&2, U32>>, +h: H.Header, +pend: E.Pend) ->
  Bool:
  match exc:
    case Nil{}:
      False{}
    case _ <> _:
      Glob.excluded(exc, E.resolve_name(h, pend))

def apply_cfg_skip(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32
) -> D:
  MkD{archive, sink, root, cfg, lim, seen, glob,
    EvSkipData{off, next, U32.add(size, pad_of(size))}}

def apply_cfg_gate(
  skip: Bool, fuel: Nat, archive: File, sink: File, root: List<&2, U32>,
  +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  match skip:
    case True{}:
      apply_cfg_skip(fuel, archive, sink, root, cfg, lim, seen, glob, off,
        next, size)
    case False{}:
      apply_cfg2(fuel, archive, sink, root, cfg, lim, seen, glob, off, next,
        size, h, tag, pend)

def apply_cfg(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +next: U32, +size: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  apply_cfg_gate(cfg_excl(cfg_exc(cfg), h, pend), fuel,
    archive, sink, root, cfg, lim, seen, glob, off, next, size, h, tag, pend)

def apply_next(
  res: Result<&1, &1, String, U32>, fuel: Nat, archive: File, sink: File,
  root: List<&2, U32>, +cfg: Cfg, +lim: Lim.State, seen: List<&1, List<&2, U32>>,
  +glob: P.Pax, +off: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  match res:
    case Fail{msg}:
      fail_d(fuel, archive, sink, root, cfg, lim, seen, glob, Nil{}, 2, msg)
    case Done{nxt}:
      apply_cfg(fuel, archive, sink, root, cfg, lim, seen, glob, off, nxt,
        E.resolve_size(h, pend), h, tag, pend)

def apply(
  fuel: Nat, archive: File, sink: File, root: List<&2, U32>, +cfg: Cfg,
  +lim: Lim.State, seen: List<&1, List<&2, U32>>, +glob: P.Pax,
  +off: U32, +h: H.Header, +tag: H.Tag, +pend: E.Pend
) -> D:
  apply_next(next_off(off, E.resolve_size(h, pend)), fuel, archive, sink,
    root, cfg, lim, seen, glob, off, h, tag, pend)

def drive(fuel: Nat, d: D) -> IO(Unit):
  match fuel:
    case 0n:
      IO.die(Unit, 2, "btar: reader fuel exhausted (corrupt archive?)")
    case 1n+p:
      match d:
        case MkD{archive, sink, +root, cfg, lim, seen, glob, st}:
            match st:
              case EvWant{+off, pend}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
                    Fx.Stream.read_exact(archive, block_size())
                  drive(pf, want_after(pr, 0n, sink, root, cfg, lim, seen, glob,
                    off, pend))
              case EvMeta{+off, +next, +size, tag, pend}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
                    Fx.Stream.read_exact(archive, size)
                  drive(pf, meta_after(pr, 0n, sink, root, cfg, lim, seen, glob,
                    next, size, tag, pend))
              case EvPad{+next, +pad, pend}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
                    Fx.Data.copy(archive, sink, pad)
                  drive(pf, pad_after(pr, 0n, root, cfg, lim, seen, glob, next,
                    pend))
              case EvApply{+off, h, tag, pend}:
                +pf : Nat = p
                drive(pf, apply(pf, archive, sink, root, cfg, lim, seen, glob, off,
                  h, tag, pend))
              case EvPrint{name, nxt}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : Result<&1, &1, U32 & String, Unit> <-
                    Fx.Stdout.write(bstr_nl(name))
                  drive(pf, print_after(pr, 0n, archive, sink, root, cfg, lim, seen,
                    glob, nxt))
              case EvSkipData{+off, +next, +size}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
                    Fx.Data.copy(archive, sink, size)
                  drive(pf, skip_after(pr, 0n, root, cfg, lim, seen, glob, next))
              case EvWalk{anc, last, kind, mode, mtime, size, next, target,
                  tanc, newpath}:
                +pf : Nat = p
                do IO<Unit>:
                  w : X.Walk <- X.walk_dirs(pf, root, anc)
                  drive(pf, walk_after(w, 0n, archive, sink, root, cfg, lim, seen, glob,
                    kind, mode, mtime, size, next, target, tanc, newpath,
                    last))
              case EvDir{opened, +last, +mode, +mtime, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  mr : X.MetaRes <- X.make_dir(pf, opened, last, mode, mtime)
                  drive(pf, dir_after(mr, 0n, archive, sink, root, cfg, lim,
                    seen, glob, next))
              case EvOpen{opened, +last, +mode, +mtime, +size, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  cr : X.Cre <- X.create_file_run(pf, opened, last, mode)
                  drive(pf, open_after(cr, 0n, archive, sink, root, cfg, lim, seen, glob,
                    last, mode, mtime, size, next))
              case EvCopy{opened, dest, +last, +mode, +mtime, +size, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
                    Fx.Data.copy(archive, dest, size)
                  drive(pf, copy_after(pr, 0n, sink, root, cfg, lim, seen,
                    glob, opened, last, mode, mtime, size, next))
              case EvCopyPad{opened, dest, +last, +mode, +mtime, +next,
                  +pad}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
                    Fx.Data.copy(archive, sink, pad)
                  drive(pf, copy_pad_after(pr, 0n, root, cfg, lim, seen,
                    glob, opened, dest, last, mode, mtime, next))
              case EvClose{opened, dest, +last, +mode, +mtime, +next, fail}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- File.close(dest)
                  drive(pf, close_done(u, 0n, archive, sink, root, cfg, lim, seen, glob,
                    opened, last, mode, mtime, next, fail))
              case EvFMeta{opened, +last, +mode, +mtime, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  mr : X.MetaRes <- X.set_file_meta(pf, opened, last, mode, mtime)
                  drive(pf, fmeta_after(mr, 0n, archive, sink, root, cfg, lim, seen, glob,
                    next))
              case EvSymlink{opened, +last, +target, +mtime, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  cr : X.Cre <- X.create_symlink_run(pf, opened, last, target)
                  drive(pf, symlink_after(cr, 0n, archive, sink, root, cfg,
                    lim, seen, glob, last, mtime, next))
              case EvHardlink{opened, +last, +target, +next, +newpath}:
                +pf : Nat = p
                do IO<Unit>:
                  cr : X.Cre <- X.create_hardlink_run(pf, opened, last, target)
                  drive(pf, hardlink_after(cr, 0n, archive, sink, root, cfg, lim, seen,
                    glob, next, newpath))
              case EvHStat{opened, +last, +target, +next, +newpath}:
                match opened:
                  case Nil{}:
                    IO.die(Unit, 2,
                      "btar: internal error: empty directory chain")
                  case h <> t:
                    +pf : Nat = p
                    do IO<Unit>:
                      pr : File & Result<&1, &1, U32 & String, U32 & U32> <-
                        Fx.Fs.fstatat(h, target)
                      drive(pf, hstat_after(pr, 0n, archive, sink, root, cfg,
                        lim, seen, glob, t, last, target, next, newpath))
              case EvSymMeta{opened, +last, +mtime, +next}:
                match opened:
                  case Nil{}:
                    IO.die(Unit, 2,
                      "btar: internal error: empty directory chain")
                  case h <> t:
                    +pf : Nat = p
                    do IO<Unit>:
                      pr : File & Result<&1, &1, U32 & String, Unit> <-
                        Fx.Fs.utimensat(h, last, mtime)
                      drive(pf, symmeta_after(pr, 0n, archive, sink, root,
                        cfg, lim, seen, glob, t, next))
              case EvToStd{+off, +next, +size}:
                +pf : Nat = p
                do IO<Unit>:
                  pr : File & Result<&1, &1, U32 & String, Unit> <-
                    Fx.Data.copy_stdout(archive, size)
                  drive(pf, stdout_after(pr, 0n, sink, root, cfg, lim, seen,
                    glob, next, size))
              case EvWarn{+msg, +off, +next, +size}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- IO.print_err(msg)
                  drive(pf, warn_after(u, 0n, archive, sink, root, cfg, lim,
                    seen, glob, off, next, size))
              case EvHWalkT{opened, +last, tanc, tlast, +next, +newpath}:
                +pf : Nat = p
                do IO<Unit>:
                  w : X.Walk <- X.walk_dirs(pf, root, tanc)
                  drive(pf, hwt_after(w, 0n, archive, sink, root, cfg, lim,
                    seen, glob, opened, last, tlast, next, newpath))
              case EvHStatT{opened, +last, topened, +tlast, +next, +newpath}:
                match topened:
                  case Nil{}:
                    IO.die(Unit, 2,
                      "btar: internal error: empty target chain")
                  case h <> t:
                    +pf : Nat = p
                    do IO<Unit>:
                      pr : File & Result<&1, &1, U32 & String, U32 & U32> <-
                        Fx.Fs.fstatat(h, tlast)
                      drive(pf, hstatT_after(pr, 0n, archive, sink, root,
                        cfg, lim, seen, glob, opened, last, t, tlast, next,
                        newpath))
              case EvHLink{opened, +last, topened, +tlast, +next, +newpath}:
                match opened:
                  case Nil{}:
                    IO.die(Unit, 2,
                      "btar: internal error: empty destination chain")
                  case dh <> dt:
                    match topened:
                      case Nil{}:
                        IO.die(Unit, 2,
                          "btar: internal error: empty target chain")
                      case th <> tt:
                        +pf : Nat = p
                        do IO<Unit>:
                          pr : File & (File & Result<&1, &1, U32 & String,
                            Unit>) <- Fx.Fs.linkat_at(th, tlast, dh, last)
                          drive(pf, hlink_after(pr, 0n, archive, sink, root,
                            cfg, lim, seen, glob, dt, tt, tlast, next,
                            newpath))
              case EvHClosT{topened, opened, +next, +newpath}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- X.close_all(pf, topened)
                  drive(pf, hclosT_after(u, 0n, archive, sink, root, cfg, lim,
                    seen, glob, opened, next, newpath))
              case EvHClosD{opened, +next, +newpath}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- X.close_all(pf, opened)
                  drive(pf, hclosD_after(u, 0n, archive, sink, root, cfg, lim,
                    seen, glob, next, newpath))
              case EvCloseAll{opened, +next}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- X.close_all(pf, opened)
                  drive(pf, closeall_after(u, 0n, archive, sink, root, cfg, lim,
                    seen, glob, next))
              case EvDone{}:
                +pf : Nat = p
                do IO<Unit>:
                  u1 : Unit <- File.close(archive)
                  u2 : Unit <- File.close(sink)
                  finish_cfg(cfg)
              case EvFail{opened, code, msg}:
                +pf : Nat = p
                do IO<Unit>:
                  u : Unit <- X.close_all(pf, opened)
                  # CLI contract (plan §2.1): 0 ok, 1 warnings, 2 fatal. Driver
                  # failures are fatal; the errno stays in the message.
                  IO.die(Unit, 2, msg)

# Streaming entry point: handles are opened by the caller (app/main.bend).

def run(
  archive: File, root: List<&2, U32>, sink: File, +cfg: Cfg, fuel: Nat
) -> IO(Unit):
  drive(fuel, MkD{archive, sink, root, cfg,
    Lim.new_state(Lim.default_limits()), Nil{}, P.empty(),
    EvWant{0, E.empty_pend()}})
