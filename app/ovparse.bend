# app/ovparse.bend — parsing of --owner / --group / --mode / --mtime values (pure).
import Base
import ../src/write.bend as Wr
import ./cli_types.bend as T






type Idv is Data:
  IdOk{id: U32, name: List<&2, U32>}
  IdLook{name: List<&2, U32>}
  IdBad{}

type Mm is Data:
  MkMm{mand: U32, mor: U32, mx: U32, ok: Bool}

type Ms is Data:
  MkMs{who: U32, op: U32, r: U32, w: U32, x: U32, s: U32, t: U32, mm: Mm}

type Pn is Data:
  MkPn{n: U32, digits: U32, rest: List<&2, U32>}

type Dt is Data:
  DtOk{t: U32}
  DtBad{}

def is_digit(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))

def all_digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      Bool.and(is_digit(h), all_digits(t))

def dec_acc(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      dec_acc(t, U32.add(U32.mul(acc, 10), U32.sub(h, 48)))

def oct_acc(xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      oct_acc(t, U32.add(U32.mul(acc, 8), U32.sub(h, 48)))

def is_oct(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 55))

def all_oct(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      Bool.and(is_oct(h), all_oct(t))

def rev(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev(t, h <> acc)

def split_colon(xs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32> & Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      (rev(acc, Nil{}), None{})
    case 58 <> t:
      (rev(acc, Nil{}), Some{t})
    case h <> t:
      split_colon(t, h <> acc)

def is_nil(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case _ <> _:
      False{}

def idv_pair(+nm: List<&2, U32>, rest: Maybe<&2, List<&2, U32>>) -> Idv:
  match rest:
    case Some{+ids}:
      Bool.pick(Idv, Bool.and(all_digits(ids), Bool.not(is_nil(ids))),
        IdOk{dec_acc(ids, 0), nm}, IdBad{})
    case None{}:
      IdLook{nm}

def parse_id3(p: List<&2, U32> & Maybe<&2, List<&2, U32>>) -> Idv:
  (nm, rest) = p
  idv_pair(nm, rest)

def parse_id2(digits: Bool, +xs: List<&2, U32>) -> Idv:
  match digits:
    case True{}:
      IdOk{dec_acc(xs, 0), Nil{}}
    case False{}:
      parse_id3(split_colon(xs, Nil{}))

# NAME, ID or NAME:ID.
def parse_id(+xs: List<&2, U32>) -> Idv:
  match xs:
    case Nil{}:
      IdBad{}
    case _ <> _:
      parse_id2(all_digits(xs), xs)

# Class bits: u = 1, g = 2, o = 4.
def cls_perms(+w: U32) -> U32:
  U32.or(Bool.pick(U32, U32.is_zero(U32.and(w, 1)), 0, 448),
    U32.or(Bool.pick(U32, U32.is_zero(U32.and(w, 2)), 0, 56),
      Bool.pick(U32, U32.is_zero(U32.and(w, 4)), 0, 7)))

def flag_mask(+f: U32, +m: U32) -> U32:
  Bool.pick(U32, U32.is_zero(f), 0, m)

# Permission bits selected by rwxst for the classes in `w`.
def bits_of(+w: U32, +r: U32, +wr: U32, +x: U32, +s: U32, +t: U32) -> U32:
  U32.or(U32.or(flag_mask(r, U32.and(cls_perms(w), 292)),
      flag_mask(wr, U32.and(cls_perms(w), 146))),
    U32.or(flag_mask(x, U32.and(cls_perms(w), 73)),
      U32.or(flag_mask(U32.and(s, w), 2048),
        U32.or(flag_mask(U32.mul(s, U32.and(U32.shrn(w, 1n), 1)), 1024), flag_mask(t, 512)))))

def compose(m1: Mm, m2: Mm) -> Mm:
  match m1:
    case MkMm{a1, o1, x1, k1}:
      match m2:
        case MkMm{+a2, o2, x2, k2}:
          MkMm{U32.and(a1, a2), U32.or(U32.and(o1, a2), o2),
            U32.or(U32.and(x1, a2), x2), Bool.and(k1, k2)}

# Bits an `=` clause clears first: all permission bits of the classes.
def eq_clear(+w: U32) -> U32:
  U32.or(cls_perms(w), U32.or(512, U32.or(flag_mask(U32.and(w, 1), 2048),
    flag_mask(U32.and(w, 2), 1024))))

def clause_map(+op: U32, +w: U32, +bits: U32, +cb: U32) -> Mm:
  match op:
    case 43:
      MkMm{4294967295, bits, cb, True{}}
    case 45:
      MkMm{U32.xor(U32.or(bits, cb), 4294967295), 0, 0, True{}}
    case _:
      MkMm{U32.xor(eq_clear(w), 4294967295), bits, cb, True{}}

def who_eff(+who: U32) -> U32:
  Bool.pick(U32, U32.is_zero(who), 7, who)

def flush2(none: Bool, +who: U32, +op: U32, +r: U32, +w: U32, +x: U32, +s: U32,
  +t: U32, mm: Mm) -> Ms:
  match none:
    case True{}:
      MkMs{who, 0, 0, 0, 0, 0, 0, mm}
    case False{}:
      MkMs{who, 0, 0, 0, 0, 0, 0, compose(mm,
        clause_map(op, who_eff(who), bits_of(who_eff(who), r, w, U32.and(x, 1), s, t),
          bits_of(who_eff(who), 0, 0, U32.shrn(x, 1n), 0, 0)))}

def flush(ms: Ms) -> Ms:
  match ms:
    case MkMs{who, +op, r, w, x, s, t, mm}:
      flush2(U32.is_zero(op), who, op, r, w, x, s, t, mm)

def comma2(ms: Ms) -> Ms:
  match ms:
    case MkMs{_, op, r, w, x, s, t, mm}:
      MkMs{0, op, r, w, x, s, t, mm}

def comma(ms: Ms) -> Ms:
  comma2(flush(ms))

# ---- --mode: octal or chmod symbolic ----------------------------------------------
#
# The result maps a mode m to (m & mand) | mor.  Symbolic clauses `[ugoa]*[-+=][rwxXst]*`
# (comma separated, several operator groups per clause) are composed left to right;
# a clause without a class letter means all classes (no umask, like GNU tar).


def bad_ms(ms: Ms) -> Ms:
  match ms:
    case MkMs{+who, +op, +r, +w, +x, +s, +t, +mm}:
      MkMs{who, op, r, w, x, s, t, MkMm{0, 0, 0, False{}}}

def who_add(+b: U32, ms: Ms) -> Ms:
  match ms:
    case MkMs{+who, +op, +r, +w, +x, +s, +t, +mm}:
      Bool.pick(Ms, U32.is_zero(op), MkMs{U32.or(who, b), op, r, w, x, s, t, mm},
        bad_ms(MkMs{who, op, r, w, x, s, t, mm}))

def set_op2(+o: U32, ms: Ms) -> Ms:
  match ms:
    case MkMs{who, _, r, w, x, s, t, mm}:
      MkMs{who, o, r, w, x, s, t, mm}

def set_op(+o: U32, ms: Ms) -> Ms:
  set_op2(o, flush(ms))

def perm_set(+pr: U32, +pw: U32, +px: U32, +ps: U32, +pt: U32, ms: Ms) -> Ms:
  match ms:
    case MkMs{+who, +op, +r, +w, +x, +s, +t, +mm}:
      Bool.pick(Ms, U32.is_zero(op), bad_ms(MkMs{who, op, r, w, x, s, t, mm}),
        MkMs{who, op, U32.or(r, pr), U32.or(w, pw), U32.or(x, px),
          U32.or(s, ps), U32.or(t, pt), mm})

def sym_step(+c: U32, ms: Ms) -> Ms:
  match c:
    case 117:
      who_add(1, ms)
    case 103:
      who_add(2, ms)
    case 111:
      who_add(4, ms)
    case 97:
      who_add(7, ms)
    case 43:
      set_op(43, ms)
    case 45:
      set_op(45, ms)
    case 61:
      set_op(61, ms)
    case 44:
      comma(ms)
    case 114:
      perm_set(1, 0, 0, 0, 0, ms)
    case 119:
      perm_set(0, 1, 0, 0, 0, ms)
    case 120:
      perm_set(0, 0, 1, 0, 0, ms)
    case 88:
      perm_set(0, 0, 2, 0, 0, ms)
    case 115:
      perm_set(0, 0, 0, 1, 0, ms)
    case 116:
      perm_set(0, 0, 0, 0, 1, ms)
    case _:
      bad_ms(ms)

def sym_go(xs: List<&2, U32>, ms: Ms) -> Ms:
  match xs:
    case Nil{}:
      flush(ms)
    case c <> t:
      sym_go(t, sym_step(c, ms))

def ms_mm(ms: Ms) -> Mm:
  match ms:
    case MkMs{_, _, _, _, _, _, _, mm}:
      mm

def parse_mode(+xs: List<&2, U32>) -> Mm:
  match xs:
    case Nil{}:
      MkMm{0, 0, 0, False{}}
    case _ <> _:
      Bool.pick(Mm, all_oct(xs), MkMm{0, oct_acc(xs, 0), 0, True{}},
        ms_mm(sym_go(xs, MkMs{0, 0, 0, 0, 0, 0, 0, MkMm{4294967295, 0, 0, True{}}})))

def read_num(xs: List<&2, U32>, +n: U32, +k: U32) -> Pn:
  match xs:
    case Nil{}:
      MkPn{n, k, Nil{}}
    case +h <> +t:
      Bool.pick(Pn, is_digit(h),
        read_num(t, U32.add(U32.mul(n, 10), U32.sub(h, 48)), U32.add(k, 1)),
        MkPn{n, k, h <> t})

def days_civil(+y0: U32, +m: U32, +d: U32) -> U32:
  +y = Bool.pick(U32, U32.is_le(m, 2), U32.sub(y0, 1), y0)
  +era = U32.div(y, 400)
  +yoe = U32.sub(y, U32.mul(era, 400))
  +mp = Bool.pick(U32, U32.is_gt(m, 2), U32.sub(m, 3), U32.add(m, 9))
  +doy = U32.add(U32.div(U32.add(U32.mul(153, mp), 2), 5), U32.sub(d, 1))
  +doe = U32.add(U32.sub(U32.add(U32.mul(yoe, 365), U32.div(yoe, 4)),
    U32.div(yoe, 100)), doy)
  U32.sub(U32.add(U32.mul(era, 146097), doe), 719468)

# Separator between date and time: space or 'T'.
def skip_sep(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case 32 <> t:
      t
    case 84 <> t:
      t
    case _:
      xs

def time3(+days: U32, +hh: U32, +mm: U32, s: Pn) -> Dt:
  match s:
    case MkPn{ss, k, rest}:
      match rest:
        case Nil{}:
          DtOk{U32.add(U32.mul(days, 86400), U32.add(U32.mul(hh, 3600),
            U32.add(U32.mul(mm, 60), ss)))}
        case _:
          DtBad{}

def time2(+days: U32, +hh: U32, m: Pn) -> Dt:
  match m:
    case MkPn{+mm, k, rest}:
      match rest:
        case Nil{}:
          DtOk{U32.add(U32.mul(days, 86400), U32.add(U32.mul(hh, 3600), U32.mul(mm, 60)))}
        case 58 <> r3:
          time3(days, hh, mm, read_num(r3, 0, 0))
        case _:
          DtBad{}

def time1(+days: U32, h: Pn) -> Dt:
  match h:
    case MkPn{+hh, k, rest}:
      match rest:
        case 58 <> r2:
          time2(days, hh, read_num(r2, 0, 0))
        case _:
          DtBad{}

def date_fin(+days: U32, tm: List<&2, U32>) -> Dt:
  match tm:
    case Nil{}:
      DtOk{U32.mul(days, 86400)}
    case _ <> _:
      time1(days, read_num(tm, 0, 0))

def date2(+y: U32, +m: U32, d: Pn) -> Dt:
  match d:
    case MkPn{+dd, k, rest}:
      date_fin(days_civil(y, m, dd), skip_sep(rest))

def date1(+y: U32, mo: Pn) -> Dt:
  match mo:
    case MkPn{+m, k, rest}:
      match rest:
        case 45 <> r2:
          date2(y, m, read_num(r2, 0, 0))
        case _:
          DtBad{}

def parse_date2(y: Pn) -> Dt:
  match y:
    case MkPn{yy, k, rest}:
      match rest:
        case 45 <> r2:
          date1(yy, read_num(r2, 0, 0))
        case _:
          DtBad{}

def parse_date(xs: List<&2, U32>) -> Dt:
  parse_date2(read_num(xs, 0, 0))
