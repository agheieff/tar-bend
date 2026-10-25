# Module: Bytes — an affine byte string (packed little-endian Array<U32>).
#
# Byte i lives in word i/4 at bit offset (i%4)*8; words are a power-of-two
# Array<U32>, `len` is the real byte count. Every byte read goes through
# `byte_at`, which bounds-checks and returns the array beside the Maybe.
# Never index an array directly: Bend array indices wrap silently.
# Names/fields are reusable byte lists (`List<&2, U32>`, which is Data).

import Base

type Bytes is Type:
  MkBytes{words: Array<U32>, len: U32}

type Cnt is Data:
  C0{}
  C1{}
  C2{}
  C3{}

def list_cat(+xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> list_cat(t, ys)

def list_rev(+xs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      list_rev(t, h <> acc)

def slice_list(+xs: List<&2, U32>, +off: Nat, +width: Nat) -> List<&2, U32>:
  List.take(&2, U32, List.drop(&2, U32, xs, off), width)

# Length of the prefix before the first zero byte (C string semantics).
def cstr_len_next(+n: Nat, h: U32) -> Nat:
  Bool.pick(Nat, U32.is_zero(h), n, Nat.add(n, 1n))

def cstr_len(fuel: Nat, xs: List<&2, U32>, n: Nat, done: Bool) -> Nat:
  match fuel:
    case 0n:
      n
    case 1n+p:
      match xs:
        case Nil{}:
          n
        case +h <> t:
          match done:
            case True{}:
              n
            case False{}:
              cstr_len(p, t, cstr_len_next(n, h), U32.is_zero(h))

def cstr(+xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, xs,
    cstr_len(Nat.add(List.length(&2, U32, xs), 1n), xs, 0n, False{}))

# Byte-list equality. `same` is the equality of the prefix compared so far
# (callers pass True{}); at the end it must be returned, not assumed: the
# final element comparison is threaded through `same`, so [45,102] and
# [45,116] differ even though their prefixes are equal.
def eq_list(+xs: List<&2, U32>, +ys: List<&2, U32>, +same: Bool) -> Bool:
  match xs:
    case Nil{}:
      match ys:
        case Nil{}:
          same
        case _ <> _:
          False{}
    case +h <> t:
      match ys:
        case Nil{}:
          False{}
        case +h2 <> t2:
          match same:
            case False{}:
              False{}
            case True{}:
              eq_list(t, t2, U32.is_eq(h, h2))

def list_is_empty(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case _ <> _:
      False{}

# `ok` is the zero-ness of all previous bytes; the caller seeds it True.
def list_show(+xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      SCon{Chr{h}, list_show(t)}

# ---- construction -----------------------------------------------------

# 2^d is the smallest power of two >= need, using `fuel` as a hard bound.
def depth_go(+fuel: Nat, +need: Nat, +pow: Nat, +d: Nat, +done: Bool) -> Nat:
  match fuel:
    case 0n:
      d
    case 1n+p:
      match done:
        case True{}:
          d
        case False{}:
          depth_go(p, need, Nat.double(pow), 1n+d,
            Nat.is_le(need, Nat.double(pow)))

def leaf(+m: Maybe<&2, U32>) -> Array<U32>:
  match m:
    case None{}:
      ALeaf{0}
    case Some{v}:
      ALeaf{v}

# Power-of-two array of 2^d leaves; the list is padded with zeros if short.
def tree(+d: Nat, +xs: List<&2, U32>) -> Array<U32>:
  match d:
    case 0n:
      leaf(List.head(&2, U32, xs))
    case 1n+p:
      +half = Nat.pow(2n, p)
      ANode{tree(p, List.take(&2, U32, xs, half)),
        tree(p, List.drop(&2, U32, xs, half))}

def pack_cnt(n: Cnt) -> Cnt:
  match n:
    case C0{}:
      C1{}
    case C1{}:
      C2{}
    case C2{}:
      C3{}
    case C3{}:
      C0{}

def pack_cur(cur: U32, h: U32, n: Cnt) -> U32:
  match n:
    case C0{}:
      h
    case C1{}:
      U32.or(cur, U32.shln(h, 8n))
    case C2{}:
      U32.or(cur, U32.shln(h, 16n))
    case C3{}:
      U32.or(cur, U32.shln(h, 24n))

def pack_acc(acc: List<&2, U32>, nc: U32, n: Cnt) -> List<&2, U32>:
  match n:
    case C3{}:
      nc <> acc
    case C0{}:
      acc
    case C1{}:
      acc
    case C2{}:
      acc

def pack_flush(acc: List<&2, U32>, cur: U32, n: Cnt) -> List<&2, U32>:
  match n:
    case C0{}:
      acc
    case C1{}:
      cur <> acc
    case C2{}:
      cur <> acc
    case C3{}:
      cur <> acc

# Pack 4 little-endian bytes into each U32 word.
def pack(
  fuel: Nat, xs: List<&2, U32>, cur: U32, +n: Cnt, acc: List<&2, U32>
) -> List<&2, U32>:
  match fuel:
    case 0n:
      pack_flush(acc, cur, n)
    case 1n+p:
      match xs:
        case Nil{}:
          pack_flush(acc, cur, n)
        case +h <> t:
          +nc = pack_cur(cur, h, n)
          pack(p, t, nc, pack_cnt(n), pack_acc(acc, nc, n))

def from_list(+xs: List<&2, U32>) -> Bytes:
  +n = List.length(&2, U32, xs)
  +nu = U32.from_nat(n)
  +need = U32.to_nat(U32.div(U32.add(nu, 3), 4))
  +d = depth_go(64n, need, 1n, 0n, Nat.is_le(need, 1n))
  +words = list_rev(pack(Nat.add(n, 1n), xs, 0, C0{}, Nil{}), Nil{})
  MkBytes{tree(d, words), nu}

# ---- views ------------------------------------------------------------

def len(b: Bytes) -> Bytes & U32:
  match b:
    case MkBytes{words, +len}:
      (MkBytes{words, len}, len)
def clone_split(+len: U32, ac: Array<U32> & Array<U32>) -> Bytes & Bytes:
  (a, c) = ac
  (MkBytes{a, len}, MkBytes{c, len})

def clone(b: Bytes) -> Bytes & Bytes:
  match b:
    case MkBytes{words, +len}:
      clone_split(len, Array.clone(U32, words))

# ---- byte access (bounds-checked) -------------------------------------

def get_byte2(+len: U32, +off: Nat, wm: Array<U32> & U32) -> Bytes & Maybe<&2, U32>:
  (w2, w) = wm
  (MkBytes{w2, len}, Some{U32.and(U32.shrn(w, off), 255)})

def get_byte(b: Bytes, +i: U32, +ok: Bool) -> Bytes & Maybe<&2, U32>:
  match b:
    case MkBytes{words, +len}:
      match ok:
        case False{}:
          (MkBytes{words, len}, None{})
        case True{}:
          +wi = U32.shrn(i, 2n)
          +off = U32.to_nat(U32.mul(U32.and(i, 3), 8))
          get_byte2(len, off, Array.get(U32, words, wi))

def byte_at(b: Bytes, +i: U32) -> Bytes & Maybe<&2, U32>:
  match b:
    case MkBytes{words, +len}:
      get_byte(MkBytes{words, len}, i, U32.is_lt(i, len))

def u32_step3(
  v0: U32, v1: U32, v2: U32, bm3: Bytes & Maybe<&2, U32>
) -> Bytes & Maybe<&2, U32>:
  (b3, m3) = bm3
  match m3:
    case None{}:
      (b3, None{})
    case Some{v3}:
      +lo = U32.or(v0, U32.shln(v1, 8n))
      +hi = U32.or(U32.shln(v2, 16n), U32.shln(v3, 24n))
      (b3, Some{U32.or(lo, hi)})

def u32_step2(
  i: U32, v0: U32, v1: U32, bm2: Bytes & Maybe<&2, U32>
) -> Bytes & Maybe<&2, U32>:
  (b2, m2) = bm2
  match m2:
    case None{}:
      (b2, None{})
    case Some{v2}:
      u32_step3(v0, v1, v2, byte_at(b2, U32.inc(U32.inc(i))))

def u32_step1(
  +i: U32, v0: U32, bm1: Bytes & Maybe<&2, U32>
) -> Bytes & Maybe<&2, U32>:
  (b1, m1) = bm1
  match m1:
    case None{}:
      (b1, None{})
    case Some{v1}:
      u32_step2(U32.inc(i), v0, v1, byte_at(b1, U32.inc(U32.inc(i))))

def u32_step0(
  +i: U32, bm0: Bytes & Maybe<&2, U32>
) -> Bytes & Maybe<&2, U32>:
  (b0, m0) = bm0
  match m0:
    case None{}:
      (b0, None{})
    case Some{v0}:
      u32_step1(i, v0, byte_at(b0, U32.inc(i)))

def u32_at(b: Bytes, +i: U32) -> Bytes & Maybe<&2, U32>:
  u32_step0(i, byte_at(b, i))

# ---- slicing / block helpers ------------------------------------------

# Bytes for archive[off .. off+width), bounds-checked: None if it runs past
# the end. `bm` holds the byte at `off` for the current step.
def slice_go(
  n: Nat, +off: U32, acc: List<&2, U32>, bm: Bytes & Maybe<&2, U32>
) -> Bytes & Maybe<Bytes>:
  match n:
    case 0n:
      (b, mb) = bm
      (b, Some{from_list(list_rev(acc, Nil{}))})
    case 1n+p:
      (b, mb) = bm
      match mb:
        case None{}:
          (b, None{})
        case Some{v}:
          slice_go(p, U32.inc(off), v <> acc, byte_at(b, U32.inc(off)))

def slice(b: Bytes, +off: U32, +width: Nat) -> Bytes & Maybe<Bytes>:
  slice_go(width, off, Nil{}, byte_at(b, off))

# ceil(size / 512) blocks covering a payload; None past the U32-safe cap.
def blocks_go(+size: U32, +overflow: Bool) -> Maybe<&2, U32>:
  match overflow:
    case True{}:
      None{}
    case False{}:
      Some{U32.div(U32.add(size, 511), 512)}

def blocks(+size: U32) -> Maybe<&2, U32>:
  blocks_go(size, U32.is_gt(size, 4294966784))

def all_zero(xs: List<&2, U32>, ok: Bool) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      match ok:
        case False{}:
          False{}
        case True{}:
          all_zero(t, U32.is_zero(h))

def unpack4(+w: U32, acc: List<&2, U32>) -> List<&2, U32>:
  U32.and(w, 255) <> (U32.and(U32.shrn(w, 8n), 255) <>
    (U32.and(U32.shrn(w, 16n), 255) <>
      (U32.and(U32.shrn(w, 24n), 255) <> acc)))

def to_list_go(a: Array<U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match a:
    case ALeaf{+x}:
      unpack4(x, acc)
    case ANode{xs, ys}:
      to_list_go(xs, to_list_go(ys, acc))

def to_list(b: Bytes) -> List<&2, U32>:
  match b:
    case MkBytes{words, +len}:
      List.take(&2, U32, to_list_go(words, Nil{}), U32.to_nat(len))
def is_zero(b: Bytes) -> Bool:
  all_zero(to_list(b), True{})


