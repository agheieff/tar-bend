# Module: Pax — POSIX pax extended header record parsing (pure).
#
# A pax payload is `<len> <key>=<value>\n` records, `<len>` counting the
# whole record. Parsed into (key, value) byte pairs; exposed keys: path,
# linkpath, size, mtime, uid, gid, uname, gname. Unknown keys are kept in
# the pair list but not exposed by `Pax` in M1.

import Base
import ./bytes.bend as B
import ./num.bend as N

type Kv is Data:
  Kv{key: List<&2, U32>, val: List<&2, U32>}

type Pax is Data:
  MkPax{
    path: Maybe<&2, List<&2, U32>>,
    linkpath: Maybe<&2, List<&2, U32>>,
    size: Maybe<&2, List<&2, U32>>,
    mtime: Maybe<&2, List<&2, U32>>,
    uid: Maybe<&2, List<&2, U32>>,
    gid: Maybe<&2, List<&2, U32>>,
    uname: Maybe<&2, List<&2, U32>>,
    gname: Maybe<&2, List<&2, U32>>
  }

def none_list() -> Maybe<&2, List<&2, U32>>:
  None{}

def empty() -> Pax:
  MkPax{none_list(), none_list(), none_list(), none_list(), none_list(),
    none_list(), none_list(), none_list()}

# ---- key literals -----------------------------------------------------

def key_path() -> List<&2, U32>:
  112 <> (97 <> (116 <> (104 <> Nil{})))

def key_linkpath() -> List<&2, U32>:
  108 <> (105 <> (110 <> (107 <> (112 <> (97 <> (116 <> (104 <> Nil{})))))))

def key_size() -> List<&2, U32>:
  115 <> (105 <> (122 <> (101 <> Nil{})))

def key_mtime() -> List<&2, U32>:
  109 <> (116 <> (105 <> (109 <> (101 <> Nil{}))))

def key_uid() -> List<&2, U32>:
  117 <> (105 <> (100 <> Nil{}))

def key_gid() -> List<&2, U32>:
  103 <> (105 <> (100 <> Nil{}))

def key_uname() -> List<&2, U32>:
  117 <> (110 <> (97 <> (109 <> (101 <> Nil{}))))

def key_gname() -> List<&2, U32>:
  103 <> (110 <> (97 <> (109 <> (101 <> Nil{}))))

# ---- record scanning helpers (non-recursive except the two loops) -----

def rec_digits_next(+n: Nat, +dig: Bool) -> Nat:
  Bool.pick(Nat, dig, Nat.add(n, 1n), n)

def rec_digits(
  fuel: Nat, xs: List<&2, U32>, n: Nat, done: Bool
) -> Nat:
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
              rec_digits(p, t, rec_digits_next(n, N.dec_is_dig(h)),
                Bool.not(N.dec_is_dig(h)))

def rec_len_next(+acc: U32, +h: U32, +dig: Bool) -> U32:
  Bool.pick(U32, dig, U32.add(U32.mul(acc, 10), U32.sub(h, 48)), acc)

def rec_len(+fuel: Nat, +xs: List<&2, U32>, +acc: U32, +done: Bool) -> U32:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case +h <> t:
          match done:
            case True{}:
              acc
            case False{}:
              rec_len(p, t, rec_len_next(acc, h, N.dec_is_dig(h)),
                Bool.not(N.dec_is_dig(h)))

def rec_valid(
  +xs: List<&2, U32>, +digits: Nat, +rlen: U32
) -> Bool:
  +lenx = U32.from_nat(List.length(&2, U32, xs))
  +range = Bool.and(U32.is_gt(rlen, U32.from_nat(digits)),
    U32.is_le(rlen, lenx))
  +space = U32.is_eq(N.nth(xs, digits), 32)
  +nl = U32.is_eq(N.nth(xs, Nat.sub(U32.to_nat(rlen), 1n)), 10)
  Bool.and(Bool.and(range, space), nl)

def rec_tail(+xs: List<&2, U32>, +rlen: U32) -> List<&2, U32>:
  List.drop(&2, U32, xs, U32.to_nat(rlen))

def rec_body(+xs: List<&2, U32>, +digits: Nat) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.add(digits, 1n))

def rec_keylen_next(+n: Nat, +h: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(h, 61), n, Nat.add(n, 1n))

def kvkey_done(+h: U32) -> Bool:
  U32.is_eq(h, 61)

def rec_keylen(+fuel: Nat, +xs: List<&2, U32>, +n: Nat, +done: Bool) -> Nat:
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
              rec_keylen(p, t, rec_keylen_next(n, h), kvkey_done(h))

def rec_kv(
  +body: List<&2, U32>, +keylen: Nat, bodylen: Nat
) -> Kv:
  +key = List.take(&2, U32, body, keylen)
  +voff = Nat.add(keylen, 1n)
  +vlen = Nat.sub(bodylen, Nat.add(keylen, 2n))
  Kv{key, List.take(&2, U32, List.drop(&2, U32, body, voff), vlen)}

def records_add(
  +acc: List<&2, Kv>, +valid: Bool, body: List<&2, U32>, keylen: Nat,
  bodylen: Nat
) -> List<&2, Kv>:
  Bool.pick(List<&2, Kv>, valid, rec_kv(body, keylen, bodylen) <> acc, acc)

def records_stop(+digits: Nat, +rlen: U32) -> Bool:
  Bool.not(U32.is_gt(rlen, U32.from_nat(digits)))

# One record per iteration.  `stop` latches a malformed record: the record
# before it was already accepted, parsing just ends.
def records(
  fuel: Nat, +xs: List<&2, U32>, acc: List<&2, Kv>, stop: Bool
) -> List<&2, Kv>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case +h <> t:
          match stop:
            case True{}:
              acc
            case False{}:
              +xlen = Nat.add(List.length(&2, U32, xs), 1n)
              +rlen = rec_len(xlen, xs, 0, False{})
              +digits = rec_digits(xlen, xs, 0n, False{})
              +body = rec_body(xs, digits)
              +keylen = rec_keylen(Nat.add(U32.to_nat(rlen), 1n), body, 0n,
                False{})
              +bodylen = U32.to_nat(U32.sub(U32.sub(rlen,
                U32.from_nat(digits)), 1))
              +valid = rec_valid(xs, digits, rlen)
              records(p, rec_tail(xs, rlen),
                records_add(acc, valid, body, keylen, bodylen),
                Bool.not(valid))

def parse_all(+xs: List<&2, U32>) -> List<&2, Kv>:
  records(Nat.add(List.length(&2, U32, xs), 2n), xs, Nil{}, False{})

# ---- lookup -----------------------------------------------------------

def find_pick(
  eq: Bool, res: Maybe<&2, List<&2, U32>>, v: List<&2, U32>
) -> Maybe<&2, List<&2, U32>>:
  match eq:
    case True{}:
      Some{v}
    case False{}:
      res

def find_after(
  h: Kv, key: List<&2, U32>, res: Maybe<&2, List<&2, U32>>
) -> Maybe<&2, List<&2, U32>>:
  match h:
    case Kv{k, v}:
      find_pick(B.eq_list(k, key, True{}), res, v)

def find(
  fuel: Nat,
  pairs: List<&2, Kv>,
  +key: List<&2, U32>,
  res: Maybe<&2, List<&2, U32>>
) -> Maybe<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      res
    case 1n+p:
      match pairs:
        case Nil{}:
          res
        case +h <> t:
          find(p, t, key, find_after(h, key, res))

def lookup(
  +pairs: List<&2, Kv>, +key: List<&2, U32>
) -> Maybe<&2, List<&2, U32>>:
  find(Nat.add(List.length(&2, Kv, pairs), 1n), pairs, key, None{})

def parse(+xs: List<&2, U32>) -> Pax:
  +pairs = parse_all(xs)
  MkPax{
    lookup(pairs, key_path()),
    lookup(pairs, key_linkpath()),
    lookup(pairs, key_size()),
    lookup(pairs, key_mtime()),
    lookup(pairs, key_uid()),
    lookup(pairs, key_gid()),
    lookup(pairs, key_uname()),
    lookup(pairs, key_gname())
  }

# ---- encoder (M3) -----------------------------------------------------
#
# A pax payload is a sequence of `<len> <key>=<value>\n` records, where
# `<len>` counts the whole record (its own digits, the space, key, '=',
# value and newline).  `emit` writes canonical records; `pad_payload`
# appends NUL padding to the next 512-byte boundary so the payload can
# follow an `x`/`g` header as data blocks.

def pad_zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0 <> pad_zeros(p)

# Decimal digit count of a Nat (>= 1).
def dec_digits(fuel: Nat, n: Nat, cnt: Nat, small: Bool) -> Nat:
  match fuel:
    case 0n:
      cnt
    case 1n+p:
      match small:
        case True{}:
          Nat.add(cnt, 1n)
        case False{}:
          +q = Nat.div(n, 10n)
          dec_digits(p, q, Nat.add(cnt, 1n), Nat.is_lt(q, 10n))

def digits_of(+n: Nat) -> Nat:
  dec_digits(24n, n, 0n, Nat.is_lt(n, 10n))

# Fixed point of `total = digits(total) + 1 + keylen + 1 + vallen + 1`.
def rec_total_go(
  fuel: Nat, +x: Nat, +klen: Nat, +vlen: Nat, stable: Bool
) -> Nat:
  match fuel:
    case 0n:
      x
    case 1n+p:
      match stable:
        case True{}:
          x
        case False{}:
          +t = Nat.add(Nat.add(digits_of(x), klen), Nat.add(vlen, 3n))
          rec_total_go(p, t, klen, vlen, Nat.is_eq(t, x))

def rec_total(+klen: Nat, +vlen: Nat) -> Nat:
  rec_total_go(8n, Nat.add(klen, Nat.add(vlen, 4n)), klen, vlen, False{})

def emit_fields(
  +key: List<&2, U32>, +val: List<&2, U32>
) -> List<&2, U32>:
  +klen = List.length(&2, U32, key)
  +vlen = List.length(&2, U32, val)
  +total = rec_total(klen, vlen)
  +lenb = N.encode_decimal(U32.from_nat(total))
  B.list_cat(lenb, B.list_cat(32 <> Nil{},
    B.list_cat(key, B.list_cat(61 <> Nil{},
      B.list_cat(val, 10 <> Nil{})))))

def kv(key: List<&2, U32>, val: List<&2, U32>) -> Kv:
  Kv{key, val}
def emit_one(+kv: Kv) -> List<&2, U32>:
  match kv:
    case Kv{key, val}:
      emit_fields(key, val)

def emit_records(records: List<&2, Kv>) -> List<&2, U32>:
  match records:
    case Nil{}:
      Nil{}
    case h <> t:
      B.list_cat(emit_one(h), emit_records(t))

def emit(records: List<&2, Kv>) -> List<&2, U32>:
  emit_records(records)

# Append NUL padding so the payload length is a multiple of 512.
def pad_payload_go(
  xs: List<&2, U32>, rem: Nat, done: Bool
) -> List<&2, U32>:
  match done:
    case True{}:
      xs
    case False{}:
      B.list_cat(xs, pad_zeros(Nat.sub(512n, rem)))

def pad_payload(+xs: List<&2, U32>) -> List<&2, U32>:
  +rem = Nat.mod(List.length(&2, U32, xs), 512n)
  pad_payload_go(xs, rem, Nat.is_eq(rem, 0n))

# Convenience: one record from key/value byte lists.
