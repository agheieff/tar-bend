# Module: Num — tar numeric field decode/encode (pure).
#
# Octal fields: leading spaces and zeros, digits, then NUL/space padding.
# GNU base-256: byte 0 has the high bit set, the rest is big-endian
# two's-complement; only non-negative values fitting U32 are accepted.
# All arithmetic is overflow-checked; values are U32 only.

import Base

type Cls is Data:
  CSpace{}
  CDigit{}
  CNul{}
  CBad{}

type Nst is Data:
  Lead{}
  Dig{}
  Tail{}
  Bad{}

type Dst is Data:
  DLead{}
  DDig{}
  DBad{}

def cls_of_go(
  h: U32, sp: Bool, nul: Bool, ge48: Bool, le55: Bool
) -> Cls:
  Bool.pick(Cls, sp, CSpace{},
    Bool.pick(Cls, nul, CNul{},
      Bool.pick(Cls, ge48, Bool.pick(Cls, le55, CDigit{}, CBad{}), CBad{})))

def cls_of(+h: U32) -> Cls:
  cls_of_go(h, U32.is_eq(h, 32), U32.is_eq(h, 0), U32.is_ge(h, 48),
    U32.is_le(h, 55))

def is_digit(c: Cls) -> Bool:
  match c:
    case CDigit{}:
      True{}
    case CSpace{}:
      False{}
    case CNul{}:
      False{}
    case CBad{}:
      False{}

def is_space(c: Cls) -> Bool:
  match c:
    case CDigit{}:
      False{}
    case CSpace{}:
      True{}
    case CNul{}:
      False{}
    case CBad{}:
      False{}

def is_nul(c: Cls) -> Bool:
  match c:
    case CDigit{}:
      False{}
    case CSpace{}:
      False{}
    case CNul{}:
      True{}
    case CBad{}:
      False{}

def is_term(c: Cls) -> Bool:
  match c:
    case CDigit{}:
      False{}
    case CSpace{}:
      True{}
    case CNul{}:
      True{}
    case CBad{}:
      False{}

def digit_val(+h: U32) -> U32:
  U32.and(h, 7)

def dec_is_dig(+h: U32) -> Bool:
  Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57))

# ---- octal transitions (non-recursive) --------------------------------

def oct_next_lead2(
  cls: Cls, val: U32, +dig: Bool, +sp: Bool, +nul: Bool, +zero: Bool
) -> Nst:
  Bool.pick(Nst, dig, Bool.pick(Nst, zero, Lead{}, Dig{}),
    Bool.pick(Nst, nul, Tail{}, Bool.pick(Nst, sp, Lead{}, Bad{})))

def oct_next_lead(+cls: Cls, +val: U32) -> Nst:
  oct_next_lead2(cls, val, is_digit(cls), is_space(cls), is_nul(cls),
    U32.is_zero(val))

def oct_next_dig2(cls: Cls, +dig: Bool, +term: Bool, +over: Bool) -> Nst:
  Bool.pick(Nst, dig, Bool.pick(Nst, over, Bad{}, Dig{}),
    Bool.pick(Nst, term, Tail{}, Bad{}))

def oct_next_dig(+cls: Cls, +acc: U32) -> Nst:
  oct_next_dig2(cls, is_digit(cls), is_term(cls), U32.is_gt(acc, 536870911))

def oct_next_tail(cls: Cls) -> Nst:
  Bool.pick(Nst, is_term(cls), Tail{}, Bad{})

def oct_next(st: Nst, cls: Cls, +val: U32, +acc: U32) -> Nst:
  match st:
    case Lead{}:
      oct_next_lead(cls, val)
    case Dig{}:
      oct_next_dig(cls, acc)
    case Tail{}:
      oct_next_tail(cls)
    case Bad{}:
      Bad{}

def oct_acc_lead(cls: Cls, +val: U32, +acc: U32) -> U32:
  Bool.pick(U32, is_digit(cls), val, acc)

def oct_acc_dig(+cls: Cls, +val: U32, +acc: U32) -> U32:
  Bool.pick(U32, is_digit(cls), U32.add(U32.mul(acc, 8), val), acc)

def oct_acc(st: Nst, cls: Cls, +val: U32, +acc: U32) -> U32:
  match st:
    case Lead{}:
      oct_acc_lead(cls, val, acc)
    case Dig{}:
      oct_acc_dig(cls, val, acc)
    case Tail{}:
      acc
    case Bad{}:
      acc

# ---- octal decode loop ------------------------------------------------

def octal(+fuel: Nat, +st: Nst, +xs: List<&2, U32>, +acc: U32) -> Maybe<&2, U32>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case Bad{}:
          None{}
        case Tail{}:
          match xs:
            case Nil{}:
              Some{acc}
            case +h <> t:
              octal(p, oct_next(st, cls_of(h), digit_val(h), acc), t, acc)
        case Lead{}:
          match xs:
            case Nil{}:
              None{}
            case +h <> t:
              +c = cls_of(h)
              octal(p, oct_next(st, c, digit_val(h), acc), t,
                oct_acc(st, c, digit_val(h), acc))
        case Dig{}:
          match xs:
            case Nil{}:
              Some{acc}
            case +h <> t:
              +c = cls_of(h)
              octal(p, oct_next(st, c, digit_val(h), acc), t,
                oct_acc(st, c, digit_val(h), acc))

def decode_octal(+xs: List<&2, U32>) -> Maybe<&2, U32>:
  octal(Nat.add(List.length(&2, U32, xs), 1n), Lead{}, xs, 0)

# ---- decimal transitions / decode loop --------------------------------

def dec_next_fit(acc: U32, +over: Bool) -> Dst:
  Bool.pick(Dst, over, DBad{}, DDig{})

def dec_next_lead2(h: U32, +acc: U32, +dig: Bool, +zero: Bool) -> Dst:
  Bool.pick(Dst, dig,
    Bool.pick(Dst, zero, DLead{},
      dec_next_fit(acc, U32.is_gt(acc, 429496729))),
    DLead{})

def dec_next_lead(+h: U32, +acc: U32) -> Dst:
  dec_next_lead2(h, acc, dec_is_dig(h), U32.is_zero(U32.sub(h, 48)))

def dec_next_dig2(h: U32, +dig: Bool, +acc: U32) -> Dst:
  Bool.pick(Dst, dig,
    dec_next_fit(acc, U32.is_gt(acc, 429496729)), DBad{})

def dec_next_dig(+h: U32, +acc: U32) -> Dst:
  dec_next_dig2(h, dec_is_dig(h), acc)

def dec_next(st: Dst, +h: U32, +acc: U32) -> Dst:
  match st:
    case DLead{}:
      dec_next_lead(h, acc)
    case DDig{}:
      dec_next_dig(h, acc)
    case DBad{}:
      DBad{}

def dec_acc_lead(+h: U32, +acc: U32) -> U32:
  Bool.pick(U32, dec_is_dig(h), U32.sub(h, 48), acc)

def dec_acc_dig2(+h: U32, +acc: U32, +dig: Bool) -> U32:
  Bool.pick(U32, dig, U32.add(U32.mul(acc, 10), U32.sub(h, 48)), acc)

def dec_acc_dig(+h: U32, +acc: U32) -> U32:
  dec_acc_dig2(h, acc, dec_is_dig(h))

def dec_acc(st: Dst, +h: U32, +acc: U32) -> U32:
  match st:
    case DBad{}:
      acc
    case DLead{}:
      dec_acc_lead(h, acc)
    case DDig{}:
      dec_acc_dig(h, acc)

def dec(+fuel: Nat, +st: Dst, +xs: List<&2, U32>, +acc: U32) -> Maybe<&2, U32>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case DBad{}:
          None{}
        case DLead{}:
          match xs:
            case Nil{}:
              None{}
            case +h <> t:
              dec(p, dec_next(st, h, acc), t, dec_acc(st, h, acc))
        case DDig{}:
          match xs:
            case Nil{}:
              Some{acc}
            case +h <> t:
              dec(p, dec_next(st, h, acc), t, dec_acc(st, h, acc))

def decode_decimal(+xs: List<&2, U32>) -> Maybe<&2, U32>:
  dec(Nat.add(List.length(&2, U32, xs), 1n), DLead{}, xs, 0)

# ---- list helpers -----------------------------------------------------

def nth(+xs: List<&2, U32>, +i: Nat) -> U32:
  match xs i:
    case Nil{} _:
      0
    case +h <> _ 0n:
      h
    case _ <> t 1n+p:
      nth(t, p)

def slice_list(+xs: List<&2, U32>, +off: Nat, +width: Nat) -> List<&2, U32>:
  List.take(&2, U32, List.drop(&2, U32, xs, off), width)

# ---- base-256 decode (GNU, 12-byte size/mtime fields) -----------------

def be32(+xs: List<&2, U32>) -> U32:
  +hi = U32.or(U32.shln(nth(xs, 8n), 24n), U32.shln(nth(xs, 9n), 16n))
  +lo = U32.or(U32.shln(nth(xs, 10n), 8n), nth(xs, 11n))
  U32.or(hi, lo)

def fits32_rest(+xs: List<&2, U32>) -> Bool:
  +ok = Bool.and(U32.is_zero(nth(xs, 1n)), U32.is_zero(nth(xs, 2n)))
  +mid = Bool.and(U32.is_zero(nth(xs, 3n)), U32.is_zero(nth(xs, 4n)))
  +mid2 = Bool.and(U32.is_zero(nth(xs, 5n)), U32.is_zero(nth(xs, 6n)))
  Bool.and(Bool.and(ok, mid), Bool.and(mid2, U32.is_zero(nth(xs, 7n))))

def fits32(+xs: List<&2, U32>) -> Bool:
  +ok0 = U32.is_zero(U32.and(nth(xs, 0n), 127))
  Bool.and(ok0, fits32_rest(xs))

def base_negative(+xs: List<&2, U32>) -> Bool:
  U32.is_ne(U32.and(nth(xs, 1n), 64), 0)

def decode_base256_fit(+xs: List<&2, U32>, +fits: Bool) -> Maybe<&2, U32>:
  match fits:
    case True{}:
      Some{be32(xs)}
    case False{}:
      None{}

def decode_base256_neg(
  xs: List<&2, U32>, neg: Bool, fits: Bool
) -> Maybe<&2, U32>:
  match neg:
    case True{}:
      None{}
    case False{}:
      decode_base256_fit(xs, fits)

def decode_base256_go(
  xs: List<&2, U32>, marker: Bool, neg: Bool, fits: Bool
) -> Maybe<&2, U32>:
  match marker:
    case False{}:
      None{}
    case True{}:
      decode_base256_neg(xs, neg, fits)

def decode_base256(+xs: List<&2, U32>) -> Maybe<&2, U32>:
  decode_base256_go(xs, U32.is_ge(nth(xs, 0n), 128), base_negative(xs),
    fits32(xs))

def decode_number_go(+xs: List<&2, U32>, +binary: Bool) -> Maybe<&2, U32>:
  match binary:
    case True{}:
      decode_base256(xs)
    case False{}:
      decode_octal(xs)

def decode_number(+xs: List<&2, U32>) -> Maybe<&2, U32>:
  decode_number_go(xs, U32.is_ge(nth(xs, 0n), 128))

def or0(+m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{v}:
      v

def field_num(+xs: List<&2, U32>, +off: Nat, +width: Nat) -> U32:
  or0(decode_number(slice_list(xs, off, width)))

# ---- encode -----------------------------------------------------------

def list_cat(+xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> list_cat(t, ys)

def enc_digits(+fuel: Nat, +n: U32, +acc: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      +d = U32.add(48, U32.mod(n, 8))
      enc_digits(p, U32.div(n, 8), d <> acc)

def nul_byte() -> List<&2, U32>:
  0 <> Nil{}

def nul_space() -> List<&2, U32>:
  0 <> (32 <> Nil{})

# `width - 1` zero-padded octal digits followed by one NUL byte.
def encode_octal(+n: U32, +width: Nat) -> List<&2, U32>:
  list_cat(enc_digits(Nat.sub(width, 1n), n, Nil{}), nul_byte())

# tar header checksum field: 6 octal digits, NUL, space.
def encode_checksum(+n: U32) -> List<&2, U32>:
  list_cat(enc_digits(6n, n, Nil{}), nul_space())

def dec_digits(
  fuel: Nat, +n: U32, acc: List<&2, U32>, zero: Bool
) -> List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match zero:
        case True{}:
          acc
        case False{}:
          +d = U32.add(48, U32.mod(n, 10))
          +q = U32.div(n, 10)
          dec_digits(p, q, d <> acc, U32.is_zero(q))

def nil_digit() -> List<&2, U32>:
  48 <> Nil{}

def encode_decimal_go(+n: U32) -> List<&2, U32>:
  dec_digits(10n, n, Nil{}, U32.is_zero(n))

def encode_decimal(+n: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_zero(n), nil_digit(), encode_decimal_go(n))

def is_some(+m: Maybe<&2, U32>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{v}:
      True{}

def field_octal(+xs: List<&2, U32>, +off: Nat, +width: Nat) -> U32:
  or0(decode_octal(slice_list(xs, off, width)))
