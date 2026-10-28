# Module: Header — ustar / GNU / v7 512-byte header parse.
#
# Fields are byte lists (List<&2, U32>), never Strings. Parsing validates
# magic, numeric fields and the tar checksum, then classifies the typeflag.

import Base
import ./bytes.bend as B
import ./num.bend as N
import ./checksum.bend as C

type Fmt is Data:
  FV7{}
  FUstar{}
  FGnu{}
  FUnknown{}

type Tag is Data:
  KRegular{}
  KHardlink{}
  KSymlink{}
  KChar{}
  KBlock{}
  KDir{}
  KFifo{}
  KContig{}
  KPaxLocal{}
  KPaxGlobal{}
  KLongName{}
  KLongLink{}
  KOther{}

type Header is Data:
  MkHeader{
    name: List<&2, U32>,
    mode: U32,
    uid: U32,
    gid: U32,
    size: U32,
    mtime: U32,
    typeflag: U32,
    linkname: List<&2, U32>,
    format: U32,
    uname: List<&2, U32>,
    gname: List<&2, U32>,
    devmajor: U32,
    devminor: U32,
    prefix: List<&2, U32>
  }

type EncErr is Data:
  EncName{}
  EncLink{}
  EncField{}

type Cut is Data:
  MkCut{h: List<&2, U32>, t: List<&2, U32>}

type Ca is Data:
  MkCa{ws: List<&2, U32>, xs: List<&2, U32>, acc: List<&2, List<&2, U32>>}

def ustar_magic() -> List<&2, U32>:
  117 <> (115 <> (116 <> (97 <> (114 <> (0 <> (48 <> (48 <> Nil{})))))))

def gnu_magic() -> List<&2, U32>:
  117 <> (115 <> (116 <> (97 <> (114 <> (32 <> (32 <> (0 <> Nil{})))))))

def magic_class_pick3(+z: Bool) -> Fmt:
  match z:
    case True{}:
      FV7{}
    case False{}:
      FUnknown{}

def magic_class_pick2(+g: Bool, +z: Bool) -> Fmt:
  match g:
    case True{}:
      FGnu{}
    case False{}:
      magic_class_pick3(z)

def magic_class_pick(+u: Bool, +g: Bool, +z: Bool) -> Fmt:
  match u:
    case True{}:
      FUstar{}
    case False{}:
      magic_class_pick2(g, z)

def magic_class(+xs: List<&2, U32>) -> Fmt:
  magic_class_pick(B.eq_list(xs, ustar_magic(), True{}),
    B.eq_list(xs, gnu_magic(), True{}), B.all_zero(xs, True{}))

def fmt_code(f: Fmt) -> U32:
  match f:
    case FV7{}:
      0
    case FUstar{}:
      1
    case FGnu{}:
      2
    case FUnknown{}:
      9

# ---- typeflag classification ------------------------------------------

def kind_pick13(+ll: Bool) -> Tag:
  match ll:
    case True{}:
      KLongLink{}
    case False{}:
      KOther{}

def kind_pick12(+ln: Bool, +ll: Bool) -> Tag:
  match ln:
    case True{}:
      KLongName{}
    case False{}:
      kind_pick13(ll)

def kind_pick11(+g: Bool, +ln: Bool, +ll: Bool) -> Tag:
  match g:
    case True{}:
      KPaxGlobal{}
    case False{}:
      kind_pick12(ln, ll)

def kind_pick10(+x: Bool, +g: Bool, +ln: Bool, +ll: Bool) -> Tag:
  match x:
    case True{}:
      KPaxLocal{}
    case False{}:
      kind_pick11(g, ln, ll)

def kind_pick9(+ct: Bool, +x: Bool, +g: Bool, +ln: Bool, +ll: Bool) -> Tag:
  match ct:
    case True{}:
      KContig{}
    case False{}:
      kind_pick10(x, g, ln, ll)

def kind_pick8(
  fi: Bool, ct: Bool, x: Bool, g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match fi:
    case True{}:
      KFifo{}
    case False{}:
      kind_pick9(ct, x, g, ln, ll)

def kind_pick7(
  d: Bool, fi: Bool, ct: Bool, x: Bool, g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match d:
    case True{}:
      KDir{}
    case False{}:
      kind_pick8(fi, ct, x, g, ln, ll)

def kind_pick6(
  bl: Bool, d: Bool, fi: Bool, ct: Bool, x: Bool, g: Bool, ln: Bool,
  ll: Bool
) -> Tag:
  match bl:
    case True{}:
      KBlock{}
    case False{}:
      kind_pick7(d, fi, ct, x, g, ln, ll)

def kind_pick5(
  ch: Bool, bl: Bool, d: Bool, fi: Bool, ct: Bool, x: Bool, g: Bool,
  ln: Bool, ll: Bool
) -> Tag:
  match ch:
    case True{}:
      KChar{}
    case False{}:
      kind_pick6(bl, d, fi, ct, x, g, ln, ll)

def kind_pick4(
  sy: Bool, ch: Bool, bl: Bool, d: Bool, fi: Bool, ct: Bool, x: Bool,
  g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match sy:
    case True{}:
      KSymlink{}
    case False{}:
      kind_pick5(ch, bl, d, fi, ct, x, g, ln, ll)

def kind_pick3(
  h: Bool, sy: Bool, ch: Bool, bl: Bool, d: Bool, fi: Bool, ct: Bool,
  x: Bool, g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match h:
    case True{}:
      KHardlink{}
    case False{}:
      kind_pick4(sy, ch, bl, d, fi, ct, x, g, ln, ll)

def kind_pick2(
  r: Bool, h: Bool, sy: Bool, ch: Bool, bl: Bool, d: Bool, fi: Bool,
  ct: Bool, x: Bool, g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match r:
    case True{}:
      KRegular{}
    case False{}:
      kind_pick3(h, sy, ch, bl, d, fi, ct, x, g, ln, ll)

def kind_pick(
  z: Bool, r: Bool, h: Bool, sy: Bool, ch: Bool, bl: Bool, d: Bool,
  fi: Bool, ct: Bool, x: Bool, g: Bool, ln: Bool, ll: Bool
) -> Tag:
  match z:
    case True{}:
      KRegular{}
    case False{}:
      kind_pick2(r, h, sy, ch, bl, d, fi, ct, x, g, ln, ll)

def classify(+t: U32) -> Tag:
  kind_pick(U32.is_eq(t, 0), U32.is_eq(t, 48), U32.is_eq(t, 49),
    U32.is_eq(t, 50), U32.is_eq(t, 51), U32.is_eq(t, 52), U32.is_eq(t, 53),
    U32.is_eq(t, 54), U32.is_eq(t, 55), U32.is_eq(t, 120),
    U32.is_eq(t, 103), U32.is_eq(t, 76), U32.is_eq(t, 75))

# ---- header record ----------------------------------------------------

def h_size(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, _, size, _, _, _, _, _, _, _, _, _}:
      size

def h_typeflag(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, _, _, _, typeflag, _, _, _, _, _, _, _}:
      typeflag

def h_name(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{name, _, _, _, _, _, _, _, _, _, _, _, _, _}:
      name

def h_linkname(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{_, _, _, _, _, _, _, linkname, _, _, _, _, _, _}:
      linkname

def h_prefix(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{_, _, _, _, _, _, _, _, _, _, _, _, _, prefix}:
      prefix

# ustar full name: prefix + "/" + name when a prefix is present.
def full_name_pick(prefix: List<&2, U32>, +name: List<&2, U32>, ustar: Bool)
  -> List<&2, U32>:
  match ustar:
    case False{}:
      name
    case True{}:
      B.list_cat(prefix, 47 <> name)

def full_name(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{+name, _, _, _, _, _, _, _, _, _, _, _, _, +prefix}:
      full_name_pick(prefix, name, Bool.not(B.list_is_empty(prefix)))

def data_blocks(h: Header) -> Maybe<&2, U32>:
  B.blocks(h_size(h))

def classify_header(h: Header) -> Tag:
  classify(h_typeflag(h))

# ---- parse ------------------------------------------------------------
#
# One pass over the block: the 15 header fields are cut off the list in order
# (`split_flds`), then validated and decoded from their own short lists.
# Validation order is fixed: magic, numeric fields, checksum, size.

def cut_cons(+h: U32, c: Cut) -> Cut:
  match c:
    case MkCut{a, b}:
      MkCut{h <> a, b}

# First n elements and the rest, in one traversal.
def cut(n: Nat, +xs: List<&2, U32>) -> Cut:
  match n:
    case 0n:
      MkCut{Nil{}, xs}
    case 1n+p:
      match xs:
        case Nil{}:
          MkCut{Nil{}, Nil{}}
        case +h <> t:
          cut_cons(h, cut(p, t))

def ca_step2(
  wt: List<&2, U32>, c: Cut, acc: List<&2, List<&2, U32>>
) -> Ca:
  match c:
    case MkCut{h, t}:
      MkCa{wt, t, h <> acc}

def ca_step(ca: Ca) -> Ca:
  match ca:
    case MkCa{ws, xs, acc}:
      match ws:
        case Nil{}:
          MkCa{Nil{}, xs, acc}
        case +w <> wt:
          ca_step2(wt, cut(U32.to_nat(w), xs), acc)

def ca_loop(k: Nat, ca: Ca) -> Ca:
  match k:
    case 0n:
      ca
    case 1n+p:
      ca_loop(p, ca_step(ca))

# name, mode, uid, gid, size, mtime, chksum, typeflag, linkname, magic,
# uname, gname, devmajor, devminor, prefix
def field_widths() -> List<&2, U32>:
  [100, 8, 8, 8, 12, 12, 8, 1, 100, 8, 32, 32, 8, 8, 155]

def list_rev_l(
  xs: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>
) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      list_rev_l(t, h <> acc)

def ca_fields(ca: Ca) -> List<&2, List<&2, U32>>:
  match ca:
    case MkCa{_, _, acc}:
      list_rev_l(acc, Nil{})

def split_flds(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  ca_fields(ca_loop(15n, MkCa{field_widths(), xs, Nil{}}))

def dec_oct(+f: List<&2, U32>) -> Maybe<&2, U32>:
  N.decode_octal(f)

def dec_num(+f: List<&2, U32>) -> Maybe<&2, U32>:
  N.decode_number(f)

def first_byte(+f: List<&2, U32>) -> U32:
  N.nth(f, 0n)

def parse_size(
  h: Header, mb: Maybe<&2, U32>
) -> Result<&1, &1, String, Header>:
  match mb:
    case None{}:
      Fail{"size field overflows the 4 GiB block math"}
    case Some{v}:
      Done{h}

def mk_header(
  name: List<&2, U32>, mode: List<&2, U32>, uid: List<&2, U32>,
  gid: List<&2, U32>, +size: U32, mtime: List<&2, U32>, typ: List<&2, U32>,
  link: List<&2, U32>, +f: U32, uname: List<&2, U32>, gname: List<&2, U32>,
  dmaj: List<&2, U32>, dmin: List<&2, U32>, prefix: List<&2, U32>
) -> Result<&1, &1, String, Header>:
  parse_size(MkHeader{B.cstr(name), N.or0(dec_oct(mode)), N.or0(dec_oct(uid)),
    N.or0(dec_oct(gid)), size, N.or0(dec_num(mtime)), first_byte(typ),
    B.cstr(link), f, B.cstr(uname), B.cstr(gname), N.or0(dec_oct(dmaj)),
    N.or0(dec_oct(dmin)), B.cstr(prefix)}, B.blocks(size))

def chk_ok(
  ok: Bool, name: List<&2, U32>, mode: List<&2, U32>, uid: List<&2, U32>,
  gid: List<&2, U32>, size: List<&2, U32>, mtime: List<&2, U32>,
  typ: List<&2, U32>, link: List<&2, U32>, f: U32, uname: List<&2, U32>,
  gname: List<&2, U32>, dmaj: List<&2, U32>, dmin: List<&2, U32>,
  prefix: List<&2, U32>
) -> Result<&1, &1, String, Header>:
  match ok:
    case False{}:
      Fail{"checksum mismatch"}
    case True{}:
      mk_header(name, mode, uid, gid, N.or0(dec_num(size)), mtime, typ, link, f,
        uname, gname, dmaj, dmin, prefix)

def nums_ok(
  ok: Bool, sum: U32, chk: List<&2, U32>, name: List<&2, U32>,
  mode: List<&2, U32>, uid: List<&2, U32>, gid: List<&2, U32>,
  size: List<&2, U32>, mtime: List<&2, U32>, typ: List<&2, U32>,
  link: List<&2, U32>, f: U32, uname: List<&2, U32>, gname: List<&2, U32>,
  dmaj: List<&2, U32>, dmin: List<&2, U32>, prefix: List<&2, U32>
) -> Result<&1, &1, String, Header>:
  match ok:
    case False{}:
      Fail{"malformed numeric header field"}
    case True{}:
      chk_ok(U32.is_eq(sum, N.or0(dec_oct(chk))), name, mode, uid, gid, size,
        mtime, typ, link, f, uname, gname, dmaj, dmin, prefix)

def fmt_ok2(
  +f: U32, sum: U32, +chk: List<&2, U32>, name: List<&2, U32>,
  +mode: List<&2, U32>, +uid: List<&2, U32>, +gid: List<&2, U32>,
  +size: List<&2, U32>, +mtime: List<&2, U32>, typ: List<&2, U32>,
  link: List<&2, U32>, uname: List<&2, U32>, gname: List<&2, U32>,
  dmaj: List<&2, U32>, dmin: List<&2, U32>, prefix: List<&2, U32>
) -> Result<&1, &1, String, Header>:
  nums_ok(Bool.and(Bool.and(Bool.and(N.is_some(dec_oct(mode)),
    N.is_some(dec_oct(uid))), Bool.and(N.is_some(dec_oct(gid)),
    N.is_some(dec_num(size)))), Bool.and(N.is_some(dec_num(mtime)),
    N.is_some(dec_oct(chk)))), sum, chk, name, mode, uid, gid, size, mtime,
    typ, link, f, uname, gname, dmaj, dmin, prefix)

def fmt_ok(
  fmt: Fmt, sum: U32, chk: List<&2, U32>, name: List<&2, U32>,
  +mode: List<&2, U32>, +uid: List<&2, U32>, +gid: List<&2, U32>,
  +size: List<&2, U32>, +mtime: List<&2, U32>, typ: List<&2, U32>,
  link: List<&2, U32>, uname: List<&2, U32>, gname: List<&2, U32>,
  dmaj: List<&2, U32>, dmin: List<&2, U32>, prefix: List<&2, U32>
) -> Result<&1, &1, String, Header>:
  match fmt:
    case FUnknown{}:
      Fail{"unsupported tar magic (not v7/ustar/gnu)"}
    case FV7{}:
      fmt_ok2(fmt_code(FV7{}), sum, chk, name, mode, uid, gid, size, mtime,
        typ, link, uname, gname, dmaj, dmin, prefix)
    case FUstar{}:
      fmt_ok2(fmt_code(FUstar{}), sum, chk, name, mode, uid, gid, size, mtime,
        typ, link, uname, gname, dmaj, dmin, prefix)
    case FGnu{}:
      fmt_ok2(fmt_code(FGnu{}), sum, chk, name, mode, uid, gid, size, mtime,
        typ, link, uname, gname, dmaj, dmin, prefix)

def parse_flds(
  fs: List<&2, List<&2, U32>>, sum: U32
) -> Result<&1, &1, String, Header>:
  match fs:
    case +name <> (+mode <> (+uid <> (+gid <> (+size <> (+mtime <> (+chk <>
        (+typ <> (+link <> (+magic <> (+uname <> (+gname <> (+dmaj <> (+dmin <>
        (+prefix <> Nil{})))))))))))))):
      fmt_ok(magic_class(magic), sum, chk, name, mode, uid, gid, size, mtime,
        typ, link, uname, gname, dmaj, dmin, prefix)
    case _:
      Fail{"truncated header block"}

def parse_list(
  +xs: List<&2, U32>, sum: U32
) -> Result<&1, &1, String, Header>:
  parse_flds(split_flds(xs), sum)

# One 512-byte block (list form) -> Header; validates magic, numerics and
# checksum.
def parse_block(+xs: List<&2, U32>) -> Result<&1, &1, String, Header>:
  parse_list(xs, C.compute_list(xs))

def parse_split(cc: B.Bytes & B.Bytes) -> Result<&1, &1, String, Header>:
  (bz, bf) = cc
  parse_list(B.to_list(bf), C.compute(bz))

# One 512-byte block -> Header; validates magic, numerics and checksum.
def parse(blk: B.Bytes) -> Result<&1, &1, String, Header>:
  parse_split(B.clone(blk))

# ---- encoder (M3) ------------------------------------------------------
#
# `encode` produces exactly one canonical ustar block (512 bytes):
#   name(100) mode(8) uid(8) gid(8) size(12) mtime(12) chksum(8)
#   typeflag(1) linkname(100) magic+version(8) uname(32) gname(32)
#   devmajor(8) devminor(8) prefix(155) pad(12)
# Octal fields use `num.encode_octal` (width-1 digits + NUL); the chksum
# field is 6 octal digits + NUL + space.  Names longer than 100 bytes are
# split at a '/' into ustar prefix/name (prefix <= 155, name <= 100); when
# no split fits ustar, or a numeric field overflows its octal width, encode
# fails with an EncErr (the M4 writer falls back to a pax header).  This is
# the provable canonical writer path: octal only, never base-256.

def enc_zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0 <> enc_zeros(p)

def enc_len(xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

# Left-take/pad to exactly `width` bytes with NULs (input may be shorter).
def enc_pad(+xs: List<&2, U32>, +width: Nat) -> List<&2, U32>:
  +n = enc_len(xs)
  +k = Nat.min(n, width)
  +tail = B.slice_list(xs, 0n, k)
  B.list_cat(tail, enc_zeros(Nat.sub(width, k)))

# Replace [off, off+width) of xs with field (field length must be width).
def enc_splice(
  +xs: List<&2, U32>, +off: Nat, +width: Nat, field: List<&2, U32>
) -> List<&2, U32>:
  +head = B.slice_list(xs, 0n, off)
  +tail = List.drop(&2, U32, xs, Nat.add(off, width))
  B.list_cat(B.list_cat(head, field), tail)

# Octal width 8: 7 digits + NUL; values above 0o7777777 do not fit.
def enc_oct8_go(n: U32, big: Bool) -> Maybe<&2, List<&2, U32>>:
  match big:
    case True{}:
      None{}
    case False{}:
      Some{N.encode_octal(n, 8n)}

# Octal width 12: 11 digits + NUL; every U32 fits 11 octal digits.
def enc_oct8(+n: U32) -> Maybe<&2, List<&2, U32>>:
  enc_oct8_go(n, U32.is_gt(n, 2097151))

def enc_oct12(n: U32) -> Maybe<&2, List<&2, U32>>:
  Some{N.encode_octal(n, 12n)}

def enc_get(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{v}:
      v

def enc_is_some(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{v}:
      True{}

# A ustar name split: index of the '/' (prefix before it, name after it),
# or None when the name needs a pax header.  Prefers the last fitting split.
def enc_split_ok(+i: Nat, total: Nat) -> Bool:
  +pre = Nat.is_le(i, 155n)
  +post = Nat.is_le(Nat.sub(total, Nat.add(i, 1n)), 100n)
  Bool.and(pre, post)

def enc_split_next(+best: Maybe<&2, Nat>, +i: Nat, total: Nat) -> Maybe<&2, Nat>:
  Bool.pick(Maybe<&2, Nat>, enc_split_ok(i, total), Some{i}, best)

def enc_split_scan(
  xs: List<&2, U32>, +i: Nat, +total: Nat, +best: Maybe<&2, Nat>
) -> Maybe<&2, Nat>:
  match xs:
    case Nil{}:
      best
    case h <> t:
      +slash = U32.is_eq(h, 47)
      +best2 = Bool.pick(Maybe<&2, Nat>, slash,
        enc_split_next(best, i, total), best)
      enc_split_scan(t, Nat.add(i, 1n), total, best2)

# For names <= 100 there is no prefix (unless a fitting split is preferred:
# we keep the canonical "no prefix" form for short names).
def enc_split_go(
  name: List<&2, U32>, total: Nat, short: Bool
) -> Maybe<&2, Nat>:
  match short:
    case True{}:
      None{}
    case False{}:
      enc_split_scan(name, 0n, total, None{})

def enc_split(+name: List<&2, U32>) -> Maybe<&2, Nat>:
  +n = enc_len(name)
  enc_split_go(name, n, Nat.is_le(n, 100n))

def enc_split_find(name: List<&2, U32>) -> Maybe<&2, Nat>:
  enc_split(name)

def enc_prefix_of(name: List<&2, U32>, k: Nat) -> List<&2, U32>:
  B.slice_list(name, 0n, k)

def enc_name_of(name: List<&2, U32>, k: Nat) -> List<&2, U32>:
  List.drop(&2, U32, name, Nat.add(k, 1n))

def enc_split_state_go(
  name: List<&2, U32>, m: Maybe<&2, Nat>
) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      Some{Nil{}}
    case Some{k}:
      Some{enc_prefix_of(name, k)}

def enc_split_state(+name: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  enc_split_state_go(name, enc_split(name))

def enc_name_part_go(
  name: List<&2, U32>, m: Maybe<&2, Nat>
) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      Some{name}
    case Some{k}:
      Some{enc_name_of(name, k)}

# The name fits ustar iff <= 100 bytes, or a prefix/name split exists.
def enc_name_part(+name: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  enc_name_part_go(name, enc_split(name))

def enc_split_ok_bool(m: Maybe<&2, Nat>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{k}:
      True{}

# Chksum field decodes through the normal octal decoder (used by tests/law).
def enc_name_ok_go(
  name: List<&2, U32>, total: Nat, short: Bool
) -> Bool:
  match short:
    case True{}:
      True{}
    case False{}:
      enc_split_ok_bool(enc_split_scan(name, 0n, total, None{}))

def enc_name_ok(+name: List<&2, U32>) -> Bool:
  +n = enc_len(name)
  enc_name_ok_go(name, n, Nat.is_le(n, 100n))

def decode_chksum_from(+xs: List<&2, U32>) -> U32:
  N.or0(N.decode_octal(B.slice_list(xs, 148n, 8n)))

# ---- header field accessors needed by the encoder ----------------------

def h_mode(h: Header) -> U32:
  match h:
    case MkHeader{_, mode, _, _, _, _, _, _, _, _, _, _, _, _}:
      mode

def h_uid(h: Header) -> U32:
  match h:
    case MkHeader{_, _, uid, _, _, _, _, _, _, _, _, _, _, _}:
      uid

def h_gid(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, gid, _, _, _, _, _, _, _, _, _, _}:
      gid

def h_mtime(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, _, _, mtime, _, _, _, _, _, _, _, _}:
      mtime

def h_uname(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{_, _, _, _, _, _, _, _, _, uname, _, _, _, _}:
      uname

def h_gname(h: Header) -> List<&2, U32>:
  match h:
    case MkHeader{_, _, _, _, _, _, _, _, _, _, gname, _, _, _}:
      gname

def h_devmajor(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, _, _, _, _, _, _, _, _, devmajor, _, _}:
      devmajor

def h_devminor(h: Header) -> U32:
  match h:
    case MkHeader{_, _, _, _, _, _, _, _, _, _, _, _, devminor, _}:
      devminor

def enc_repeat(+v: U32, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      v <> enc_repeat(v, p)

def enc_type_go(t: U32, ok: Bool) -> Maybe<&2, List<&2, U32>>:
  match ok:
    case True{}:
      Some{t <> Nil{}}
    case False{}:
      None{}

def enc_type_byte(+h: Header) -> Maybe<&2, List<&2, U32>>:
  enc_type_go(h_typeflag(h), U32.is_le(h_typeflag(h), 255))

def enc_link_ok(+h: Header) -> Bool:
  Nat.is_le(enc_len(h_linkname(h)), 100n)

def enc_magic() -> List<&2, U32>:
  ustar_magic()

def enc_fits_name(+h: Header) -> Bool:
  enc_name_ok(h_name(h))

def enc_fits_fields(+h: Header) -> Bool:
  +a = Bool.and(enc_is_some(enc_oct8(h_mode(h))),
    enc_is_some(enc_oct8(h_uid(h))))
  +b = Bool.and(enc_is_some(enc_oct8(h_gid(h))),
    enc_is_some(enc_oct8(h_devmajor(h))))
  +c = Bool.and(enc_is_some(enc_oct8(h_devminor(h))),
    enc_link_ok(h))
  +d = Bool.and(enc_is_some(enc_type_byte(h)), enc_fits_name(h))
  Bool.and(Bool.and(a, b), Bool.and(c, d))

# True when the header can be written as a plain ustar block (M4 uses this
# to decide between ustar and pax).
def fits(+h: Header) -> Bool:
  enc_fits_fields(h)

# ---- block assembly ---------------------------------------------------

def enc_block(
  name: List<&2, U32>,
  mode: List<&2, U32>,
  uid: List<&2, U32>,
  gid: List<&2, U32>,
  size: List<&2, U32>,
  mtime: List<&2, U32>,
  chksum: List<&2, U32>,
  tflag: List<&2, U32>,
  link: List<&2, U32>,
  uname: List<&2, U32>,
  gname: List<&2, U32>,
  devmajor: List<&2, U32>,
  devminor: List<&2, U32>,
  prefix: List<&2, U32>
) -> List<&2, U32>:
  +f00 = B.list_cat(name, B.list_cat(mode, B.list_cat(uid, B.list_cat(gid,
    B.list_cat(size, B.list_cat(mtime, B.list_cat(chksum, tflag)))))))
  +f08 = B.list_cat(link, B.list_cat(enc_magic(), B.list_cat(uname,
    B.list_cat(gname, B.list_cat(devmajor, B.list_cat(devminor, prefix))))))
  B.list_cat(f00, B.list_cat(f08, enc_repeat(0, 12n)))

def enc_build(+h: Header) -> List<&2, U32>:
  +name = enc_get(enc_name_part(h_name(h)))
  +prefix = enc_get(enc_split_state(h_name(h)))
  +block0 = enc_block(
    enc_pad(name, 100n),
    enc_get(enc_oct8(h_mode(h))),
    enc_get(enc_oct8(h_uid(h))),
    enc_get(enc_oct8(h_gid(h))),
    enc_get(enc_oct12(h_size(h))),
    enc_get(enc_oct12(h_mtime(h))),
    enc_repeat(0, 8n),
    enc_get(enc_type_byte(h)),
    enc_pad(h_linkname(h), 100n),
    enc_pad(h_uname(h), 32n),
    enc_pad(h_gname(h), 32n),
    enc_get(enc_oct8(h_devmajor(h))),
    enc_get(enc_oct8(h_devminor(h))),
    enc_pad(prefix, 155n))
  +sum = C.compute_list(block0)
  +chk = N.encode_checksum(sum)
  enc_splice(block0, 148n, 8n, chk)

# ---- validation chain --------------------------------------------------

def enc_errs8(
  +h: Header, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match type_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      Done{enc_build(h)}

# Encode one canonical ustar header block (512 bytes) or fail for pax.
def enc_errs7(
  +h: Header, link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match link_ok:
    case False{}:
      Fail{EncLink{}}
    case True{}:
      enc_errs8(h, type_ok)

def enc_errs6(
  +h: Header, dmin_ok: Bool, link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match dmin_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      enc_errs7(h, link_ok, type_ok)

def enc_errs5(
  +h: Header, dmaj_ok: Bool, dmin_ok: Bool, link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match dmaj_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      enc_errs6(h, dmin_ok, link_ok, type_ok)

def enc_errs4(
  +h: Header, gid_ok: Bool, dmaj_ok: Bool, dmin_ok: Bool, link_ok: Bool,
  type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match gid_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      enc_errs5(h, dmaj_ok, dmin_ok, link_ok, type_ok)

def enc_errs3(
  +h: Header, uid_ok: Bool, gid_ok: Bool, dmaj_ok: Bool, dmin_ok: Bool,
  link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match uid_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      enc_errs4(h, gid_ok, dmaj_ok, dmin_ok, link_ok, type_ok)

def enc_errs2(
  +h: Header, mode_ok: Bool, uid_ok: Bool, gid_ok: Bool, dmaj_ok: Bool,
  dmin_ok: Bool, link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match mode_ok:
    case False{}:
      Fail{EncField{}}
    case True{}:
      enc_errs3(h, uid_ok, gid_ok, dmaj_ok, dmin_ok, link_ok, type_ok)

def enc_errs(
  +h: Header, name_ok: Bool, mode_ok: Bool, uid_ok: Bool, gid_ok: Bool,
  dmaj_ok: Bool, dmin_ok: Bool, link_ok: Bool, type_ok: Bool
) -> Result<&1, &1, EncErr, List<&2, U32>>:
  match name_ok:
    case False{}:
      Fail{EncName{}}
    case True{}:
      enc_errs2(h, mode_ok, uid_ok, gid_ok, dmaj_ok, dmin_ok, link_ok,
        type_ok)

def encode(+h: Header) -> Result<&1, &1, EncErr, List<&2, U32>>:
  +name_ok = enc_name_ok(h_name(h))
  +mode_ok = enc_is_some(enc_oct8(h_mode(h)))
  +uid_ok = enc_is_some(enc_oct8(h_uid(h)))
  +gid_ok = enc_is_some(enc_oct8(h_gid(h)))
  +dmaj_ok = enc_is_some(enc_oct8(h_devmajor(h)))
  +dmin_ok = enc_is_some(enc_oct8(h_devminor(h)))
  enc_errs(h, name_ok, mode_ok, uid_ok, gid_ok, dmaj_ok, dmin_ok,
    enc_link_ok(h), enc_is_some(enc_type_byte(h)))

def enc_err_show(e: EncErr) -> String:
  match e:
    case EncName{}:
      "name does not fit ustar prefix/name"
    case EncLink{}:
      "linkname longer than 100 bytes"
    case EncField{}:
      "numeric/typeflag field overflows its ustar width"

# Result-erasing view of encode for tests/laws: Nil on failure.
def encode_list_go(
  r: Result<&1, &1, EncErr, List<&2, U32>>
) -> List<&2, U32>:
  match r:
    case Fail{e}:
      Nil{}
    case Done{blk}:
      blk

def encode_list(+h: Header) -> List<&2, U32>:
  encode_list_go(encode(h))

def set_names(h: Header, un: List<&2, U32>, gn: List<&2, U32>) -> Header:
  match h:
    case MkHeader{name, mode, uid, gid, size, mtime, typeflag, linkname, format, _, _, devmajor, devminor, prefix}:
      MkHeader{name, mode, uid, gid, size, mtime, typeflag, linkname, format, un, gn, devmajor, devminor, prefix}
