# Module: Listfmt — GNU-style long listing lines (`tar -tv`) and name quoting (pure).
#
#   drwxr-xr-x user/group     1234 2026-10-28 21:27 name -> target
#
# The "user/group size" block is right-aligned to a width that only grows during a
# run (GNU starts at 19), so the caller threads that width through the lines.
import Base
import ./bytes.bend as B

type Ln is Data:
  MkLn{line: List<&2, U32>, w: U32}

def cat(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  B.list_cat(xs, ys)

# 10 digits (zero padded), then the leading zeros are dropped.
def dig10(fuel: Nat, +n: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      dig10(p, U32.div(n, 10), U32.add(48, U32.mod(n, 10)) <> acc)

def strip0(ds: List<&2, U32>) -> List<&2, U32>:
  match ds:
    case 48 <> t:
      match t:
        case Nil{}:
          ds
        case _ <> _:
          strip0(t)
    case _:
      ds

def dec(+n: U32) -> List<&2, U32>:
  strip0(dig10(10n, n, Nil{}))

def len32(xs: List<&2, U32>) -> U32:
  U32.from_nat(List.length(&2, U32, xs))

def spaces(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      32 <> spaces(p)

# ---- mode string -------------------------------------------------------------------

def bit(+m: U32, +b: U32, +on: U32, +off: U32) -> U32:
  Bool.pick(U32, U32.is_zero(U32.and(m, b)), off, on)

# x position with a setid/sticky bit: lower-case when executable, upper otherwise.
def xbit(+m: U32, +xb: U32, +sb: U32, +lo: U32, +up: U32) -> U32:
  Bool.pick(U32, U32.is_zero(U32.and(m, sb)), bit(m, xb, 120, 45),
    bit(m, xb, lo, up))

def type_ch(+tf: U32) -> U32:
  match tf:
    case 49:
      104
    case 50:
      108
    case 51:
      99
    case 52:
      98
    case 53:
      100
    case 54:
      112
    case _:
      45

def mode_str(+tf: U32, +m: U32) -> List<&2, U32>:
  type_ch(tf) <> (bit(m, 256, 114, 45) <> (bit(m, 128, 119, 45) <>
    (xbit(m, 64, 2048, 115, 83) <> (bit(m, 32, 114, 45) <>
    (bit(m, 16, 119, 45) <> (xbit(m, 8, 1024, 115, 83) <>
    (bit(m, 4, 114, 45) <> (bit(m, 2, 119, 45) <>
    (xbit(m, 1, 512, 116, 84) <> Nil{})))))))))

# ---- name quoting (GNU "escape" style for control bytes) --------------------------

def oct3(+c: U32) -> List<&2, U32>:
  92 <> (U32.add(48, U32.shrn(c, 6n)) <> (U32.add(48, U32.and(U32.shrn(c, 3n), 7)) <>
    (U32.add(48, U32.and(c, 7)) <> Nil{})))

def quote_one(+c: U32) -> List<&2, U32>:
  match c:
    case 10:
      92 <> (110 <> Nil{})
    case 9:
      92 <> (116 <> Nil{})
    case 13:
      92 <> (114 <> Nil{})
    case 7:
      92 <> (97 <> Nil{})
    case 8:
      92 <> (98 <> Nil{})
    case 12:
      92 <> (102 <> Nil{})
    case 11:
      92 <> (118 <> Nil{})
    case _:
      Bool.pick(List<&2, U32>, Bool.or(U32.is_lt(c, 32), U32.is_eq(c, 127)),
        oct3(c), c <> Nil{})

def quote(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      cat(quote_one(h), quote(t))

def bs(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bs(t)

def link_part(+tf: U32, link: List<&2, U32>) -> List<&2, U32>:
  match tf:
    case 50:
      cat(bs(" -> "), link)
    case 49:
      cat(bs(" link to "), link)
    case _:
      Nil{}

def build(+w: U32, +tf: U32, +mode: U32, +ug: List<&2, U32>, +sz: List<&2, U32>,
  date: List<&2, U32>, name: List<&2, U32>, link: List<&2, U32>) -> Ln:
  +w2 = U32.max(w, U32.add(U32.add(len32(ug), 1), len32(sz)))
  MkLn{cat(mode_str(tf, mode), 32 <> cat(ug, cat(
    spaces(U32.to_nat(U32.sub(w2, U32.add(len32(ug), len32(sz))))),
    cat(sz, 32 <> cat(date, 32 <> cat(quote(name), link_part(tf, quote(link)))))))), w2}

def dev_or_size(+tf: U32, +size: U32, +maj: U32, +min: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.or(U32.is_eq(tf, 51), U32.is_eq(tf, 52)),
    cat(dec(maj), 44 <> dec(min)), dec(size))

# ---- line ------------------------------------------------------------------------------

def who(numeric: Bool, nm: List<&2, U32>, +id: U32) -> List<&2, U32>:
  match numeric:
    case True{}:
      dec(id)
    case False{}:
      match nm:
        case Nil{}:
          dec(id)
        case _ <> _:
          nm

def line(+w: U32, +tf: U32, +mode: U32, un: List<&2, U32>, gn: List<&2, U32>,
  +uid: U32, +gid: U32, +numeric: Bool, +size: U32, +dmaj: U32, +dmin: U32,
  date: List<&2, U32>, name: List<&2, U32>, link: List<&2, U32>) -> Ln:
  build(w, tf, mode,
    cat(who(numeric, un, uid), 47 <> who(numeric, gn, gid)),
    dev_or_size(tf, size, dmaj, dmin), date, name, link)


def spaces0(n: Nat, ds: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      ds
    case 1n+p:
      48 <> spaces0(p, ds)

def pad_to(+have: U32, +want: U32, ds: List<&2, U32>) -> List<&2, U32>:
  spaces0(U32.to_nat(U32.sub(want, U32.min(have, want))), ds)

# Left-pad with zeros to `width` digits.
def pad0_go(+width: Nat, +ds: List<&2, U32>) -> List<&2, U32>:
  spaces0(U32.to_nat(U32.sub(U32.from_nat(width), U32.min(
    U32.from_nat(List.length(&2, U32, ds)), U32.from_nat(width)))), ds)

def pad0(+n: U32, +width: Nat) -> List<&2, U32>:
  pad0_go(width, dec(n))

def secs_part(secs: Bool, +sod: U32) -> List<&2, U32>:
  match secs:
    case True{}:
      58 <> pad0(U32.mod(sod, 60), 2n)
    case False{}:
      Nil{}

def civil(+z: U32, +sod: U32, secs: Bool) -> List<&2, U32>:
  +era = U32.div(z, 146097)
  +doe = U32.mod(z, 146097)
  +yoe = U32.div(U32.sub(U32.add(U32.sub(doe, U32.div(doe, 1460)),
    U32.div(doe, 36524)), U32.div(doe, 146096)), 365)
  +doy = U32.sub(doe, U32.sub(U32.add(U32.mul(365, yoe), U32.div(yoe, 4)),
    U32.div(yoe, 100)))
  +mp = U32.div(U32.add(U32.mul(5, doy), 2), 153)
  +d = U32.add(U32.sub(doy, U32.div(U32.add(U32.mul(153, mp), 2), 5)), 1)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), U32.add(mp, 3), U32.sub(mp, 9))
  +y0 = U32.add(yoe, U32.mul(era, 400))
  +y = Bool.pick(U32, U32.is_le(m, 2), U32.add(y0, 1), y0)
  cat(pad0(y, 4n), 45 <> cat(pad0(m, 2n), 45 <> cat(pad0(d, 2n),
    32 <> cat(pad0(U32.div(sod, 3600), 2n), 58 <> cat(
      pad0(U32.div(U32.mod(sod, 3600), 60), 2n), secs_part(secs, sod))))))

def date2(+lt: U32, secs: Bool) -> List<&2, U32>:
  +days = U32.div(lt, 86400)
  +sod = U32.mod(lt, 86400)
  civil(U32.add(days, 719468), sod, secs)

# ---- time ----------------------------------------------------------------------------

# Local time = t + offset; `off` is the biased offset from Fs.tzoff (2^31 = UTC).
def date_str(+t: U32, +off: U32, secs: Bool) -> List<&2, U32>:
  date2(U32.sub(U32.add(t, off), 2147483648), secs)

def ln_line(l: Ln) -> List<&2, U32>:
  match l:
    case MkLn{line, _}:
      line

def ln_w(l: Ln) -> U32:
  match l:
    case MkLn{_, w}:
      w
