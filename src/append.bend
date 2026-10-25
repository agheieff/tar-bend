# src/append.bend — `btar -r` / `-u`: locate the logical end of an existing
# uncompressed tar archive and (for `-u`) tabulate its members.
#
# One read-only pass: a header block per Stream.read_exact, payloads skipped
# with Stream.seek.  The logical end is the offset of the first all-zero block
# (or EOF when the end blocks are missing, like GNU).  Anything that is not a
# valid archive prefix — bad checksum/numerics, data running past EOF,
# unsupported types — is a hard error *before* the file is opened for writing,
# so a corrupt archive is never modified.  Policy only; the syscalls are the
# Fx.* effects.
import Base
import ./bytes.bend as B
import ./num.bend as N
import ./header.bend as H
import ./pax.bend as P
import ./entry.bend as E
import ./read_stream.bend as R
import ./upd.bend as U
import ../effs/effects.bend as Fx

type Scan is Data:
  MkScan{end: U32, tab: U.Tab}

def scan_end(s: Scan) -> U32:
  match s:
    case MkScan{end, tab}:
      end

def scan_tab(s: Scan) -> U.Tab:
  match s:
    case MkScan{end, tab}:
      tab

# One effect per state; pure helpers build the next state and only `drive`
# recurses (project rule: no mutual recursion).
type Ss is Type:
  SHdr{fd: File, off: U32, flen: U32, pend: E.Pend, glob: P.Pax,
    tab: U.Tab, upd: Bool}
  SMeta{fd: File, off: U32, next: U32, body: U32, size: U32, flen: U32,
    tag: H.Tag, pend: E.Pend, glob: P.Pax, tab: U.Tab, upd: Bool}
  SSeek{fd: File, next: U32, flen: U32, glob: P.Pax, tab: U.Tab,
    upd: Bool}
  SEnd{fd: File, end: U32, tab: U.Tab}
  SDie{msg: String}

def die_at(msg: String, +off: U32) -> Ss:
  SDie{"btar: " ++ msg ++ " at offset " ++ U32.show(off)}

def tab_add(+upd: Bool, +h: H.Header, +pend: E.Pend, +glob: P.Pax,
  +tab: U.Tab) -> U.Tab:
  match upd:
    case True{}:
      U.tab_add(tab, U.am_new(E.resolve_name(h, pend), R.eff_mtime(h, pend, glob)))
    case False{}:
      tab

# ---- data entries: skip the payload ---------------------------------------

def data_fits(
  ok: Bool, fd: File, +next: U32, +flen: U32, +glob: P.Pax,
  +tab: U.Tab, +upd: Bool, +off: U32
) -> Ss:
  match ok:
    case True{}:
      SSeek{fd, next, flen, glob, tab, upd}
    case False{}:
      die_at("truncated archive: member data runs past the end of the file",
        off)

def data_next(
  m: Maybe<&2, U32>, fd: File, +off: U32, +flen: U32, +h: H.Header,
  +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match m:
    case None{}:
      die_at("member size overflows the 4 GiB archive limit", off)
    case Some{n}:
      +next = U32.add(U32.add(off, 512), U32.mul(n, 512))
      data_fits(Bool.and(U32.is_gt(next, off), U32.is_le(next, flen)), fd,
        next, flen, glob, tab_add(upd, h, pend, glob, tab), upd, off)

def data_entry(
  fd: File, +off: U32, +flen: U32, +h: H.Header, +pend: E.Pend, +glob: P.Pax,
  +tab: U.Tab, +upd: Bool, +size: U32
) -> Ss:
  data_next(B.blocks(size), fd, off, flen, h, pend, glob, tab, upd)

# Entries that carry no data must say so: GNU and btar's reader disagree about
# a size field on links/devices, so such an archive has no safe logical end.
def nodata_ok(
  ok: Bool, fd: File, +off: U32, +flen: U32, +h: H.Header, +pend: E.Pend,
  +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match ok:
    case True{}:
      data_entry(fd, off, flen, h, pend, glob, tab, upd, 0)
    case False{}:
      die_at("unexpected data blocks on a link/device/directory entry", off)

def nodata(
  fd: File, +off: U32, +flen: U32, +h: H.Header, +pend: E.Pend,
  +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  nodata_ok(U32.is_zero(E.resolve_size(h, pend)), fd, off, flen, h, pend,
    glob, tab, upd)

# ---- metadata entries (pax x/g, GNU L/K) ---------------------------------

def meta_read(
  m: Maybe<&2, U32>, fd: File, +off: U32, +flen: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match m:
    case None{}:
      die_at("metadata size overflows", off)
    case Some{n}:
      +body = U32.mul(n, 512)
      SMeta{fd, off, U32.add(U32.add(off, 512), body), body, size, flen, tag,
        pend, glob, tab, upd}

def meta_gate(
  ok: Bool, fd: File, +off: U32, +flen: U32, +size: U32,
  +tag: H.Tag, +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match ok:
    case True{}:
      meta_read(B.blocks(size), fd, off, flen, size, tag, pend, glob, tab,
        upd)
    case False{}:
      die_at("pax/longname header larger than 64 KiB", off)

def meta_set(+tag: H.Tag, payload: List<&2, U32>, +pend: E.Pend,
  +glob: P.Pax) -> E.Pend & P.Pax:
  match tag:
    case H.KPaxLocal{}:
      match pend:
        case E.MkPend{_, ln, lk}:
          (E.MkPend{Some{P.parse(payload)}, ln, lk}, glob)
    case H.KPaxGlobal{}:
      (pend, P.parse(payload))
    case H.KLongName{}:
      match pend:
        case E.MkPend{px, _, lk}:
          (E.MkPend{px, Some{B.cstr(payload)}, lk}, glob)
    case H.KLongLink{}:
      match pend:
        case E.MkPend{px, ln, _}:
          (E.MkPend{px, ln, Some{B.cstr(payload)}}, glob)
    case _:
      (pend, glob)

def meta_next(pg: E.Pend & P.Pax, fd: File, +next: U32, +flen: U32,
  +tab: U.Tab, +upd: Bool) -> Ss:
  (pend, glob) = pg
  SHdr{fd, next, flen, pend, glob, tab, upd}

def meta_done(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  +flen: U32, +next: U32, +size: U32, +tag: H.Tag, +pend: E.Pend, +glob: P.Pax,
  +tab: U.Tab, +upd: Bool
) -> Ss:
  (fd, r) = pr
  match r:
    case Fail{(code, msg)}:
      SDie{"btar: read archive: " ++ msg}
    case Done{payload}:
      meta_next(meta_set(tag, List.take(&2, U32, payload,
        U32.to_nat(size)), pend, glob), fd, next, flen, tab, upd)

# ---- header dispatch -----------------------------------------------------

def hdr_tag(
  +tag: H.Tag, fd: File, +off: U32, +flen: U32, +h: H.Header,
  +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match tag:
    case H.KPaxLocal{}:
      meta_gate(U32.is_le(H.h_size(h), 65536), fd, off, flen,
        H.h_size(h), tag, pend, glob, tab, upd)
    case H.KPaxGlobal{}:
      meta_gate(U32.is_le(H.h_size(h), 65536), fd, off, flen,
        H.h_size(h), tag, pend, glob, tab, upd)
    case H.KLongName{}:
      meta_gate(U32.is_le(H.h_size(h), 65536), fd, off, flen,
        H.h_size(h), tag, pend, glob, tab, upd)
    case H.KLongLink{}:
      meta_gate(U32.is_le(H.h_size(h), 65536), fd, off, flen,
        H.h_size(h), tag, pend, glob, tab, upd)
    case H.KRegular{}:
      data_entry(fd, off, flen, h, pend, glob, tab, upd,
        E.resolve_size(h, pend))
    case H.KContig{}:
      data_entry(fd, off, flen, h, pend, glob, tab, upd,
        E.resolve_size(h, pend))
    case H.KHardlink{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KSymlink{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KDir{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KChar{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KBlock{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KFifo{}:
      nodata(fd, off, flen, h, pend, glob, tab, upd)
    case H.KOther{}:
      die_at("unsupported tar entry type (sparse/dumpdir/other)", off)

def hdr_parsed(
  res: Result<&1, &1, String, H.Header>, fd: File, +off: U32,
  +flen: U32, +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match res:
    case Fail{msg}:
      die_at("not a valid tar archive (" ++ msg ++ ")", off)
    case Done{+h}:
      hdr_tag(H.classify_header(h), fd, off, flen, h, pend, glob, tab, upd)

def blk_full(
  zero: Bool, fd: File, +off: U32, +flen: U32, +blk: List<&2, U32>,
  +pend: E.Pend, +glob: P.Pax, +tab: U.Tab, +upd: Bool
) -> Ss:
  match zero:
    case True{}:
      SEnd{fd, off, tab}
    case False{}:
      hdr_parsed(H.parse_block(blk), fd, off, flen, pend, glob, tab, upd)

def blk_len(
  empty: Bool, short: Bool, fd: File, +off: U32, +flen: U32,
  +blk: List<&2, U32>, +pend: E.Pend, +glob: P.Pax, +tab: U.Tab,
  +upd: Bool
) -> Ss:
  match empty:
    case True{}:
      SEnd{fd, off, tab}
    case False{}:
      match short:
        case True{}:
          die_at("truncated archive: partial header block", off)
        case False{}:
          blk_full(B.all_zero(blk, True{}), fd, off, flen, blk, pend, glob,
            tab, upd)

# gzip magic at offset 0: a clear refusal instead of a header parse error.
def gz_magic(+off: U32, blk: List<&2, U32>) -> Bool:
  match blk:
    case 31 <> rest:
      match rest:
        case 139 <> _:
          U32.is_zero(off)
        case _:
          False{}
    case _:
      False{}

def blk_gz(
  gz: Bool, fd: File, +off: U32, +flen: U32, +blk: List<&2, U32>,
  +pend: E.Pend, +glob: P.Pax, tab: U.Tab, +upd: Bool
) -> Ss:
  match gz:
    case True{}:
      SDie{"btar: cannot append to or update a compressed archive " ++
        "(gzip data found; -r/-u need an uncompressed tar)"}
    case False{}:
      +n = U32.from_nat(List.length(&2, U32, blk))
      blk_len(U32.is_zero(n), U32.is_lt(n, 512), fd, off, flen, blk, pend,
        glob, tab, upd)

def blk_state(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  +off: U32, +flen: U32, +pend: E.Pend, +glob: P.Pax, tab: U.Tab,
  +upd: Bool
) -> Ss:
  (fd, r) = pr
  match r:
    case Fail{(code, msg)}:
      SDie{"btar: read archive: " ++ msg}
    case Done{+blk}:
      blk_gz(gz_magic(off, blk), fd, off, flen, blk, pend, glob, tab, upd)

def seek_state(pr: File & Result<&1, &1, U32 & String, U32>, +flen: U32,
  +glob: P.Pax, +tab: U.Tab, +upd: Bool) -> Ss:
  (fd, r) = pr
  match r:
    case Fail{(code, msg)}:
      SDie{"btar: seek archive: " ++ msg}
    case Done{pos}:
      SHdr{fd, pos, flen, E.empty_pend(), glob, tab, upd}

def drive(fuel: Nat, st: Ss) -> IO(Scan):
  match fuel:
    case 0n:
      IO.die(Scan, 2, "btar: archive has too many members")
    case 1n+p:
      match st:
        case SDie{msg}:
          IO.die(Scan, 2, msg)
        case SEnd{fd, end, tab}:
          do IO<Scan>:
            u : Unit <- File.close(fd)
            IO.pure(Scan, MkScan{end, tab})
        case SHdr{fd, +off, flen, pend, glob, tab, upd}:
          +pf : Nat = p
          do IO<Scan>:
            pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Stream.read_exact(fd, 512)
            drive(pf, blk_state(pr, off, flen, pend, glob, tab, upd))
        case SMeta{fd, off, next, body, size, flen, tag, pend, glob, tab,
            upd}:
          +pf : Nat = p
          do IO<Scan>:
            pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Stream.read_exact(fd, body)
            drive(pf, meta_done(pr, flen, next, size, tag, pend, glob, tab,
              upd))
        case SSeek{fd, next, flen, glob, tab, upd}:
          +pf : Nat = p
          do IO<Scan>:
            pr : File & Result<&1, &1, U32 & String, U32> <-
              Fx.Stream.seek(fd, next, 0)
            drive(pf, seek_state(pr, flen, glob, tab, upd))

# ---- entry points --------------------------------------------------------

def start_reg(reg: Bool, fd: File, +flen: U32, +upd: Bool) -> IO(Scan):
  match reg:
    case True{}:
      drive(1048576n, SHdr{fd, 0, flen, E.empty_pend(), P.empty(), U.TNil{},
        upd})
    case False{}:
      IO.die(Scan, 2, "btar: archive is not a regular file")

def start(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, +upd: Bool)
  -> IO(Scan):
  (fd, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(Scan, 2, "btar: stat archive: " ++ msg)
    case Done{+st}:
      start_reg(U32.is_eq(N.nth(st, 0n), 8), fd, N.nth(st, 5n), upd)

def scan_file(path: List<&2, U32>, +upd: Bool) -> IO(Scan):
  do IO<Scan>:
    fd : File <- IO.try(File, File.open_bytes(path, "r"))
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.fstatx(fd)
    start(pr, upd)

def exists_after(
  pr: Result<&1, &1, U32 & String, List<&2, U32>>, missing: Bool,
  path: List<&2, U32>, +upd: Bool
) -> IO(Scan):
  match pr:
    case Done{st}:
      scan_file(path, upd)
    case Fail{(code, msg)}:
      match missing:
        case True{}:
          IO.pure(Scan, MkScan{0, U.TNil{}})
        case False{}:
          IO.die(Scan, 2, "btar: cannot open archive: " ++ msg)

def scan(+path: List<&2, U32>, +upd: Bool) -> IO(Scan):
  do IO<Scan>:
    pr : Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.stat_path(path)
    exists_after(pr, True{}, path, upd)
