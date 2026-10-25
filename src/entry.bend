# Module: Entry — resolved archive entry, pending overrides, parse states.
#
# Header is the raw 512-byte block; an Entry is what the listing driver
# holds after applying pending pax / GNU longname overrides. Pend holds the
# per-file overrides (x, L, K) applying to the next entry only. St is the
# single-driver state sum type (no mutual recursion). All transitions are
# pure functions returning the next St; only app/main.bend does IO.

import Base
import ./bytes.bend as B
import ./num.bend as N
import ./header.bend as H
import ./pax.bend as P

type Entry is Data:
  MkEntry{
    name: List<&2, U32>,
    linkname: Maybe<&2, List<&2, U32>>,
    tag: H.Tag,
    mode: U32,
    uid: U32,
    gid: U32,
    size: U32,
    mtime: U32,
    uname: List<&2, U32>,
    gname: List<&2, U32>,
    typeflag: U32
  }

type Pend is Data:
  MkPend{
    pax: Maybe<&2, P.Pax>,
    lname: Maybe<&2, List<&2, U32>>,
    llink: Maybe<&2, List<&2, U32>>
  }

type St is Type:
  StWant{off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax}
  StBlock{
    off: U32,
    zeros: U32,
    bm: B.Bytes & Maybe<B.Bytes>,
    pend: Pend,
    glob: P.Pax
  }
  StParsed{
    off: U32,
    zeros: U32,
    buf: B.Bytes,
    res: Result<&1, &1, String, H.Header>,
    pend: Pend,
    glob: P.Pax
  }
  StMeta{
    off: U32,
    next: U32,
    tag: H.Tag,
    buf: B.Bytes,
    pend: Pend,
    glob: P.Pax
  }
  StPayload{
    next: U32,
    tag: H.Tag,
    bm: B.Bytes & Maybe<B.Bytes>,
    pend: Pend,
    glob: P.Pax
  }
  StEmit{
    next: U32,
    buf: B.Bytes,
    pend: Pend,
    glob: P.Pax,
    line: Maybe<String>
  }
  StDone{}
  StFail{msg: String}

def empty_pend() -> Pend:
  MkPend{None{}, None{}, None{}}

# Driver state.  The StWant/StBlock and StMeta/StPayload pairs exist so the
# affine block bytes and archive Bytes hand off without duplicating arrays.
def pax_name_go(
  h: H.Header, path: Maybe<&2, List<&2, U32>>
) -> List<&2, U32>:
  match path:
    case Some{v}:
      v
    case None{}:
      H.full_name(h)

def pax_name(+h: H.Header, +p: P.Pax) -> List<&2, U32>:
  match p:
    case P.MkPax{path, _, _, _, _, _, _, _}:
      pax_name_go(h, path)

def name_pax(+h: H.Header, +pax: Maybe<&2, P.Pax>) -> List<&2, U32>:
  match pax:
    case None{}:
      H.full_name(h)
    case Some{p}:
      pax_name(h, p)

def name_l(
  h: H.Header,
  pax: Maybe<&2, P.Pax>,
  lname: Maybe<&2, List<&2, U32>>
) -> List<&2, U32>:
  match lname:
    case Some{v}:
      v
    case None{}:
      name_pax(h, pax)

def resolve_name(+h: H.Header, +pend: Pend) -> List<&2, U32>:
  match pend:
    case MkPend{pax, lname, _}:
      name_l(h, pax, lname)

def link_go(
  h: H.Header, linkpath: Maybe<&2, List<&2, U32>>
) -> Maybe<&2, List<&2, U32>>:
  match linkpath:
    case Some{v}:
      Some{v}
    case None{}:
      Some{H.h_linkname(h)}

def pax_link(+h: H.Header, +p: P.Pax) -> Maybe<&2, List<&2, U32>>:
  match p:
    case P.MkPax{_, linkpath, _, _, _, _, _, _}:
      link_go(h, linkpath)

def link_pax(
  h: H.Header, pax: Maybe<&2, P.Pax>
) -> Maybe<&2, List<&2, U32>>:
  match pax:
    case None{}:
      Some{H.h_linkname(h)}
    case Some{p}:
      pax_link(h, p)

def link_l(
  h: H.Header,
  pax: Maybe<&2, P.Pax>,
  llink: Maybe<&2, List<&2, U32>>
) -> Maybe<&2, List<&2, U32>>:
  match llink:
    case Some{v}:
      Some{v}
    case None{}:
      link_pax(h, pax)

def resolve_link(+h: H.Header, +pend: Pend) -> Maybe<&2, List<&2, U32>>:
  match pend:
    case MkPend{pax, _, llink}:
      link_l(h, pax, llink)

def size_pax_go(+h: H.Header, +size: Maybe<&2, List<&2, U32>>) -> U32:
  match size:
    case None{}:
      H.h_size(h)
    case Some{v}:
      N.or0(N.decode_decimal(v))

def size_in_pax(+h: H.Header, +p: P.Pax) -> U32:
  match p:
    case P.MkPax{_, _, size, _, _, _, _, _}:
      size_pax_go(h, size)

def size_pax(+h: H.Header, +pax: Maybe<&2, P.Pax>) -> U32:
  match pax:
    case None{}:
      H.h_size(h)
    case Some{p}:
      size_in_pax(h, p)

def resolve_size(+h: H.Header, +pend: Pend) -> U32:
  match pend:
    case MkPend{pax, _, _}:
      size_pax(h, pax)

# Metadata entries (pax `x`/`g`, GNU `L`/`K`) have no printed line.
def is_meta(+tag: H.Tag) -> Bool:
  match tag:
    case H.KPaxLocal{}:
      True{}
    case H.KPaxGlobal{}:
      True{}
    case H.KLongName{}:
      True{}
    case H.KLongLink{}:
      True{}
    case H.KRegular{}:
      False{}
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
    case H.KOther{}:
      False{}

# ---- block transitions ------------------------------------------------

def next_off_go(+off: U32, mb: Maybe<&2, U32>) -> U32:
  match mb:
    case None{}:
      U32.add(off, 512)
    case Some{n}:
      U32.add(U32.add(off, 512), U32.mul(n, 512))

# off + 512 header + payload blocks rounded to 512 (U32 math, v1 4 GiB cap).
def next_off(+off: U32, +size: U32) -> U32:
  next_off_go(off, B.blocks(size))

def want_go(
  +off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax, end: Bool
) -> St:
  match end:
    case True{}:
      StDone{}
    case False{}:
      StBlock{off, zeros, B.slice(buf, off, 512n), pend, glob}

def want(
  +off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax, len: U32
) -> St:
  want_go(off, zeros, buf, pend, glob, Bool.not(U32.is_lt(off, len)))

def block_zero_go(
  off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax, first: Bool
) -> St:
  match first:
    case True{}:
      StWant{U32.add(off, 512), 1, buf, pend, glob}
    case False{}:
      StDone{}

def block_zero(
  +off: U32, +zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax
) -> St:
  block_zero_go(off, zeros, buf, pend, glob, U32.is_zero(zeros))

def block_zeroed(
  off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax,
  blk: B.Bytes, zero: Bool
) -> St:
  match zero:
    case True{}:
      block_zero(off, zeros, buf, pend, glob)
    case False{}:
      StParsed{off, zeros, buf, H.parse(blk), pend, glob}

# One real header block: clone it, test for the all-zero end block, else parse.
def block_split(
  off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax,
  cc: B.Bytes & B.Bytes
) -> St:
  (bz, bf) = cc
  block_zeroed(off, zeros, buf, pend, glob, bf, B.is_zero(bz))

def block(
  off: U32, zeros: U32, buf: B.Bytes, pend: Pend, glob: P.Pax, blk: B.Bytes
) -> St:
  block_split(off, zeros, buf, pend, glob, B.clone(blk))

# ---- header transitions -----------------------------------------------

def meta(
  +off: U32, buf: B.Bytes, pend: Pend, glob: P.Pax, tag: H.Tag, size: U32
) -> St:
  StMeta{off, next_off(off, size), tag, buf, pend, glob}

def emit(off: U32, buf: B.Bytes, +h: H.Header, +pend: Pend, glob: P.Pax)
  -> St:
  StEmit{next_off(off, resolve_size(h, pend)), buf, empty_pend(), glob,
    Some{B.list_show(resolve_name(h, pend))}}

# ---- metadata payload -------------------------------------------------

# Payload bytes = all blocks between the header block and `next`.
def meta_payload(
  +off: U32, +next: U32, tag: H.Tag, buf: B.Bytes, pend: Pend, glob: P.Pax
) -> St:
  StPayload{next, tag,
    B.slice(buf, U32.add(off, 512),
      U32.to_nat(U32.sub(U32.sub(next, off), 512))),
    pend, glob}

def links_payload(blk: B.Bytes) -> List<&2, U32>:
  B.cstr(B.to_list(blk))

def payload_pax(
  buf: B.Bytes, next: U32, pend: Pend, glob: P.Pax, p: P.Pax
) -> St:
  match pend:
    case MkPend{_, lname, llink}:
      StWant{next, 0, buf, MkPend{Some{p}, lname, llink}, glob}

def payload_global(
  buf: B.Bytes, next: U32, pend: Pend, g: P.Pax
) -> St:
  StWant{next, 0, buf, pend, g}

def payload_lname(
  buf: B.Bytes, next: U32, pend: Pend, glob: P.Pax, v: List<&2, U32>
) -> St:
  match pend:
    case MkPend{pax, _, llink}:
      StWant{next, 0, buf, MkPend{pax, Some{v}, llink}, glob}

def payload_llink(
  buf: B.Bytes, next: U32, pend: Pend, glob: P.Pax, v: List<&2, U32>
) -> St:
  match pend:
    case MkPend{pax, lname, _}:
      StWant{next, 0, buf, MkPend{pax, lname, Some{v}}, glob}

def payload_tag(
  buf: B.Bytes, next: U32, tag: H.Tag, blk: B.Bytes, pend: Pend, glob: P.Pax,
  tag2: H.Tag
) -> St:
  match tag2:
    case H.KPaxLocal{}:
      payload_pax(buf, next, pend, glob, P.parse(B.to_list(blk)))
    case H.KPaxGlobal{}:
      payload_global(buf, next, pend, P.parse(B.to_list(blk)))
    case H.KLongName{}:
      payload_lname(buf, next, pend, glob, links_payload(blk))
    case H.KLongLink{}:
      payload_llink(buf, next, pend, glob, links_payload(blk))
    case H.KRegular{}:
      StDone{}
    case H.KHardlink{}:
      StDone{}
    case H.KSymlink{}:
      StDone{}
    case H.KOther{}:
      StDone{}
    case H.KChar{}:
      StDone{}
    case H.KBlock{}:
      StDone{}
    case H.KDir{}:
      StDone{}
    case H.KFifo{}:
      StDone{}
    case H.KContig{}:
      StDone{}
def payload_apply(
  buf: B.Bytes, next: U32, +tag: H.Tag, blk: B.Bytes, pend: Pend, glob: P.Pax
) -> St:
  payload_tag(buf, next, tag, blk, pend, glob, tag)



def parsed_kind(
  off: U32, zeros: U32, buf: B.Bytes, +h: H.Header, pend: Pend, glob: P.Pax,
  tag: H.Tag
) -> St:
  match tag:
    case H.KPaxLocal{}:
      meta(off, buf, pend, glob, tag, H.h_size(h))
    case H.KPaxGlobal{}:
      meta(off, buf, pend, glob, tag, H.h_size(h))
    case H.KLongName{}:
      meta(off, buf, pend, glob, tag, H.h_size(h))
    case H.KLongLink{}:
      meta(off, buf, pend, glob, tag, H.h_size(h))
    case H.KOther{}:
      StFail{"unsupported tar entry type"}
    case H.KChar{}:
      StFail{"unsupported tar entry type (character device)"}
    case H.KBlock{}:
      StFail{"unsupported tar entry type (block device)"}
    case H.KFifo{}:
      StFail{"unsupported tar entry type (fifo)"}
    case H.KContig{}:
      StFail{"unsupported tar entry type (contiguous file)"}
    case H.KRegular{}:
      emit(off, buf, h, pend, glob)
    case H.KHardlink{}:
      emit(off, buf, h, pend, glob)
    case H.KSymlink{}:
      emit(off, buf, h, pend, glob)
    case H.KDir{}:
      emit(off, buf, h, pend, glob)

def parsed_done(
  off: U32, zeros: U32, buf: B.Bytes, +h: H.Header, pend: Pend, glob: P.Pax
) -> St:
  parsed_kind(off, zeros, buf, h, pend, glob, H.classify_header(h))

def new_parsed(
  off: U32, zeros: U32, buf: B.Bytes, res: Result<&1, &1, String, H.Header>,
  pend: Pend, glob: P.Pax
) -> St:
  match res:
    case Fail{error}:
      StFail{error}
    case Done{value}:
      parsed_done(off, zeros, buf, value, pend, glob)
