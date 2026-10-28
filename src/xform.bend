# Module: Xform — `--transform=s/REGEXP/REPLACEMENT/[gi]` (pure, byte based).
#
# GNU applies sed-style substitutions to member names and link targets while
# creating and extracting.  Supported subset of POSIX BRE: literals, `.`,
# `[set]` / `[^set]` with ranges, `*`, `\+`, `\?` on a single atom, `^` / `$`
# anchors, `\(...\)` groups (not quantifiable).  Replacement: literals, `&`,
# `\0`-`\9`, `\n`.  Flags: `g` (all matches), `i` (ASCII case-insensitive).
# Not supported: back-references inside the regexp, `\|`, `\{m,n\}`, POSIX
# classes, the `x`, `r`, `s`, `h` flags.  Matching is a backtracking search
# with an explicit step budget (no mutual recursion; one function per loop).
import Base
import ./bytes.bend as B

type Pt is Data:
  PAtom{kind: U32, c: U32, neg: Bool, items: List<&2, U32>, lo: U32, hi: U32}
  PBol{}
  PEol{}
  POpen{n: U32}
  PClose{n: U32}

type Rp is Data:
  RLit{c: U32}
  RRef{n: U32}

type Xc is Data:
  MkXc{pat: List<&2, Pt>, rep: List<&2, Rp>, glob: Bool, ic: Bool}

type Cap is Data:
  MkCap{n: U32, text: List<&2, U32>, done: Bool}

type Res is Data:
  MkRes{rest: List<&2, U32>, caps: List<&2, Cap>}

# ---- character helpers ---------------------------------------------------

def inf() -> U32:
  4294967295

def lower(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_ge(c, 65), U32.is_le(c, 90)), U32.add(c, 32), c)

def upper(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_ge(c, 97), U32.is_le(c, 122)), U32.sub(c, 32), c)

def in_items(+items: List<&2, U32>, +c: U32) -> Bool:
  match items:
    case Nil{}:
      False{}
    case +lo <> rest:
      match rest:
        case Nil{}:
          False{}
        case +hi <> t:
          Bool.or(Bool.and(U32.is_ge(c, lo), U32.is_le(c, hi)), in_items(t, c))

def set_ok(ic: Bool, +items: List<&2, U32>, +c: U32) -> Bool:
  Bool.or(in_items(items, c),
    Bool.and(ic, Bool.or(in_items(items, lower(c)), in_items(items, upper(c)))))

def xor(+a: Bool, +b: Bool) -> Bool:
  Bool.pick(Bool, a, Bool.not(b), b)

def atom_ok(ic: Bool, +kind: U32, +c: U32, +neg: Bool,
  +items: List<&2, U32>, +ch: U32) -> Bool:
  match kind:
    case 0:
      Bool.or(U32.is_eq(c, ch), Bool.and(ic, U32.is_eq(lower(c), lower(ch))))
    case 1:
      True{}
    case _:
      xor(neg, set_ok(ic, items, ch))

# ---- matcher ------------------------------------------------------------------

type Ms is Data:
  MGo{pat: List<&2, Pt>, s: List<&2, U32>, atstart: Bool,
    caps: List<&2, Cap>}
  MAlt{first: Maybe<&2, Res>, skip: Bool, pat: List<&2, Pt>,
    s: List<&2, U32>, atstart: Bool, caps: List<&2, Cap>}
  MAtom{takes: Bool, atom2: Pt, lozero: Bool, t: List<&2, Pt>,
    s: List<&2, U32>, s1: List<&2, U32>, atstart: Bool, caps: List<&2, Cap>}

def dec_lo(+lo: U32) -> U32:
  Bool.pick(U32, U32.is_zero(lo), 0, U32.sub(lo, 1))

def dec_hi(+hi: U32) -> U32:
  Bool.pick(U32, U32.is_eq(hi, inf()), hi, U32.sub(hi, 1))

def head_ok(ic: Bool, +kind: U32, +c: U32, +neg: Bool, items: List<&2, U32>,
  +hi: U32, s: List<&2, U32>) -> Bool:
  match s:
    case Nil{}:
      False{}
    case ch <> _:
      Bool.and(Bool.not(U32.is_zero(hi)), atom_ok(ic, kind, c, neg, items, ch))

def tail_of(s: List<&2, U32>) -> List<&2, U32>:
  match s:
    case Nil{}:
      Nil{}
    case _ <> t:
      t

def mk_atom(ic: Bool, a: Pt, t: List<&2, Pt>, +s: List<&2, U32>,
  atstart: Bool, caps: List<&2, Cap>) -> Ms:
  match a:
    case PAtom{+kind, +c, +neg, +items, +lo, +hi}:
      MAtom{head_ok(ic, kind, c, neg, items, hi, s),
        PAtom{kind, c, neg, items, dec_lo(lo), dec_hi(hi)}, U32.is_zero(lo),
        t, s, tail_of(s), atstart, caps}
    case _:
      MGo{Nil{}, s, atstart, caps}

def m(+fuel: Nat, +ic: Bool, st: Ms) -> Maybe<&2, Res>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case MAlt{first, skip, pat, s, atstart, caps}:
          match first:
            case Some{r}:
              Some{r}
            case None{}:
              match skip:
                case True{}:
                  m(p, ic, MGo{pat, s, atstart, caps})
                case False{}:
                  None{}
        case MAtom{takes, +atom2, lozero, +t, +s, +s1, +atstart, +caps}:
          match takes:
            case True{}:
              m(p, ic, MAlt{m(p, ic, MGo{atom2 <> t, s1, False{}, caps}),
                lozero, t, s, atstart, caps})
            case False{}:
              match lozero:
                case True{}:
                  m(p, ic, MGo{t, s, atstart, caps})
                case False{}:
                  None{}
        case MGo{pat, +s, +atstart, +caps}:
          match pat:
            case Nil{}:
              Some{MkRes{s, caps}}
            case PBol{} <> t:
              match atstart:
                case True{}:
                  m(p, ic, MGo{t, s, atstart, caps})
                case False{}:
                  None{}
            case PEol{} <> t:
              match s:
                case Nil{}:
                  m(p, ic, MGo{t, s, atstart, caps})
                case _ <> _:
                  None{}
            case POpen{n} <> t:
              m(p, ic, MGo{t, s, atstart, MkCap{n, s, False{}} <> caps})
            case PClose{n} <> t:
              m(p, ic, MGo{t, s, atstart, MkCap{n, s, True{}} <> caps})
            case a <> t:
              m(p, ic, mk_atom(ic, a, t, s, atstart, caps))

# ---- regexp compiler (BRE subset) ----------------------------------------------

type SetRes is Data:
  SetRes{ok: Bool, items: List<&2, U32>, rest: List<&2, U32>}

# Set body after '[' (and an optional '^'): items collected newest-first as
# (hi, lo) so that reversing yields lo,hi pairs.  A leading ']' is literal;
# `c-d` is a range unless '-' ends the set.
def set_parse(+fuel: Nat, re: List<&2, U32>, acc: List<&2, U32>,
  first: Bool) -> SetRes:
  match fuel:
    case 0n:
      SetRes{False{}, Nil{}, Nil{}}
    case 1n+p:
      match re:
        case Nil{}:
          SetRes{False{}, Nil{}, Nil{}}
        case +c <> t:
          match c:
            case 93:
              match first:
                case True{}:
                  set_parse(p, t, c <> (c <> acc), False{})
                case False{}:
                  SetRes{True{}, B.list_rev(acc, Nil{}), t}
            case _:
              match t:
                case 45 <> t2:
                  match t2:
                    case 93 <> _:
                      set_parse(p, t, c <> (c <> acc), False{})
                    case +d <> t3:
                      set_parse(p, t3, d <> (c <> acc), False{})
                    case Nil{}:
                      SetRes{False{}, Nil{}, Nil{}}
                case _:
                  set_parse(p, t, c <> (c <> acc), False{})

type Cs is Data:
  CsGo{re: List<&2, U32>, ng: U32, stack: List<&2, U32>, acc: List<&2, Pt>}
  CsSet{sr: SetRes, neg: Bool, ng: U32, stack: List<&2, U32>,
    acc: List<&2, Pt>}

type Cr is Data:
  CrOk{pts: List<&2, Pt>}
  CrErr{msg: String}

def lit(+c: U32) -> Pt:
  PAtom{0, c, False{}, Nil{}, 1, 1}

def rev_pt(xs: List<&2, Pt>, acc: List<&2, Pt>) -> List<&2, Pt>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_pt(t, h <> acc)

# `*`, `\+`, `\?` act on the preceding atom; with none, they are literals.
def quant(+lo: U32, +hi: U32, +c: U32, acc: List<&2, Pt>) -> List<&2, Pt>:
  match acc:
    case PAtom{kind, ac, neg, items, _, _} <> r:
      PAtom{kind, ac, neg, items, lo, hi} <> r
    case _:
      lit(c) <> acc

def at_open(acc: List<&2, Pt>) -> Bool:
  match acc:
    case Nil{}:
      True{}
    case POpen{_} <> _:
      True{}
    case _:
      False{}

def dollar_end(re: List<&2, U32>) -> Bool:
  match re:
    case Nil{}:
      True{}
    case 92 <> t:
      match t:
        case 41 <> _:
          True{}
        case _:
          False{}
    case _:
      False{}

def anchor_bol(at: Bool, acc: List<&2, Pt>) -> List<&2, Pt>:
  match at:
    case True{}:
      PBol{} <> acc
    case False{}:
      lit(94) <> acc

def anchor_eol(at: Bool, acc: List<&2, Pt>) -> List<&2, Pt>:
  match at:
    case True{}:
      PEol{} <> acc
    case False{}:
      lit(36) <> acc

def esc_lit(+e: U32) -> U32:
  Bool.pick(U32, U32.is_eq(e, 110), 10, e)

def is_digit19(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 49), U32.is_le(c, 57))

# Back-references inside the regexp are not supported (refused up front).
def has_backref(fuel: Nat, re: List<&2, U32>) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match re:
        case Nil{}:
          False{}
        case 92 <> t:
          match t:
            case Nil{}:
              False{}
            case e <> t2:
              Bool.or(is_digit19(e), has_backref(p, t2))
        case _ <> t:
          has_backref(p, t)

def comp(+fuel: Nat, st: Cs) -> Cr:
  match fuel:
    case 0n:
      CrErr{"transform: regexp too long"}
    case 1n+p:
      match st:
        case CsSet{sr, neg, ng, stack, acc}:
          match sr:
            case SetRes{ok, items, rest}:
              match ok:
                case True{}:
                  comp(p, CsGo{rest, ng, stack,
                    PAtom{2, 0, neg, items, 1, 1} <> acc})
                case False{}:
                  CrErr{"transform: unterminated ["}
        case CsGo{re, +ng, stack, +acc}:
          match re:
            case Nil{}:
              match stack:
                case Nil{}:
                  CrOk{rev_pt(acc, Nil{})}
                case _ <> _:
                  CrErr{"transform: unmatched \\("}
            case 92 <> +t:
              match t:
                case Nil{}:
                  CrErr{"transform: trailing backslash"}
                case 40 <> t2:
                  comp(p, CsGo{t2, U32.add(ng, 1), U32.add(ng, 1) <> stack,
                    POpen{U32.add(ng, 1)} <> acc})
                case 41 <> t2:
                  match stack:
                    case Nil{}:
                      CrErr{"transform: unmatched \\)"}
                    case n <> st2:
                      comp(p, CsGo{t2, ng, st2, PClose{n} <> acc})
                case 43 <> t2:
                  comp(p, CsGo{t2, ng, stack, quant(1, inf(), 43, acc)})
                case 63 <> t2:
                  comp(p, CsGo{t2, ng, stack, quant(0, 1, 63, acc)})
                case 124 <> _:
                  CrErr{"transform: \\| is not supported"}
                case 123 <> _:
                  CrErr{"transform: \\{ is not supported"}
                case e <> t2:
                  comp(p, CsGo{t2, ng, stack, lit(esc_lit(e)) <> acc})
            case 42 <> t:
              comp(p, CsGo{t, ng, stack, quant(0, inf(), 42, acc)})
            case 46 <> t:
              comp(p, CsGo{t, ng, stack, PAtom{1, 0, False{}, Nil{}, 1, 1} <> acc})
            case 94 <> +t:
              comp(p, CsGo{t, ng, stack, anchor_bol(at_open(acc), acc)})
            case 36 <> +t:
              comp(p, CsGo{t, ng, stack, anchor_eol(dollar_end(t), acc)})
            case 91 <> +t:
              match t:
                case 94 <> t2:
                  comp(p, CsSet{set_parse(p, t2, Nil{}, True{}), True{}, ng,
                    stack, acc})
                case _:
                  comp(p, CsSet{set_parse(p, t, Nil{}, True{}), False{}, ng,
                    stack, acc})
            case c <> t:
              comp(p, CsGo{t, ng, stack, lit(c) <> acc})

# ---- replacement and expression parsing ---------------------------------------

def is_digit09(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))

def rp_esc(+e: U32) -> Rp:
  Bool.pick(Rp, is_digit09(e), RRef{U32.sub(e, 48)}, RLit{esc_lit(e)})

def rev_rp(xs: List<&2, Rp>, acc: List<&2, Rp>) -> List<&2, Rp>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_rp(t, h <> acc)

def rep_comp(fuel: Nat, xs: List<&2, U32>, acc: List<&2, Rp>) -> List<&2, Rp>:
  match fuel:
    case 0n:
      rev_rp(acc, Nil{})
    case 1n+p:
      match xs:
        case Nil{}:
          rev_rp(acc, Nil{})
        case 92 <> t:
          match t:
            case Nil{}:
              rev_rp(RLit{92} <> acc, Nil{})
            case e <> t2:
              rep_comp(p, t2, rp_esc(e) <> acc)
        case 38 <> t:
          rep_comp(p, t, RRef{0} <> acc)
        case c <> t:
          rep_comp(p, t, RLit{c} <> acc)

# Push the escaped byte `e` (reversed accumulator): `\<delim>` is the bare
# delimiter, every other escape pair is kept.
def un_acc(hit: Bool, e: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match hit:
    case True{}:
      e <> acc
    case False{}:
      e <> (92 <> acc)

type Seg is Data:
  SegOk{text: List<&2, U32>, rest: List<&2, U32>}
  SegNo{}

def seg(+fuel: Nat, +d: U32, xs: List<&2, U32>, +acc: List<&2, U32>) -> Seg:
  match fuel:
    case 0n:
      SegNo{}
    case 1n+p:
      match xs:
        case Nil{}:
          SegNo{}
        case 92 <> t:
          match t:
            case Nil{}:
              SegNo{}
            case +e <> t2:
              seg(p, d, t2, un_acc(U32.is_eq(e, d), e, acc))
        case +h <> +t:
          Bool.pick(Seg, U32.is_eq(h, d), SegOk{B.list_rev(acc, Nil{}), t},
            seg(p, d, t, h <> acc))

type Fl is Data:
  FlOk{g: Bool, i: Bool}
  FlErr{}

def flags(fuel: Nat, xs: List<&2, U32>, +g: Bool, +i: Bool) -> Fl:
  match fuel:
    case 0n:
      FlErr{}
    case 1n+p:
      match xs:
        case Nil{}:
          FlOk{g, i}
        case 103 <> t:
          flags(p, t, True{}, i)
        case 105 <> t:
          flags(p, t, g, True{})
        case 73 <> t:
          flags(p, t, g, True{})
        case _ <> _:
          FlErr{}

type Pe is Data:
  PeOk{xc: Xc}
  PeErr{msg: String}

def pe_build(cr: Cr, rep: List<&2, Rp>, fl: Fl) -> Pe:
  match cr:
    case CrErr{msg}:
      PeErr{msg}
    case CrOk{pts}:
      match fl:
        case FlErr{}:
          PeErr{"transform: unsupported flags (only g and i)"}
        case FlOk{g, i}:
          PeOk{MkXc{pts, rep, g, i}}

def pe_flags(cr: Cr, rep: List<&2, Rp>, fl: List<&2, U32>) -> Pe:
  pe_build(cr, rep, flags(64n, fl, False{}, False{}))

def pe_rep(+re: List<&2, U32>, sg: Seg) -> Pe:
  match sg:
    case SegNo{}:
      PeErr{"transform: expression must be s/REGEXP/REPLACEMENT/[FLAGS]"}
    case SegOk{+rep, fl}:
      pe_flags(comp(Nat.add(List.length(&2, U32, re), 2n),
        CsGo{re, 0, Nil{}, Nil{}}), rep_comp(
        Nat.add(List.length(&2, U32, rep), 1n), rep, Nil{}), fl)

def pe_checked(bad: Bool, +d: U32, +re: List<&2, U32>, +rest: List<&2, U32>) -> Pe:
  match bad:
    case True{}:
      PeErr{"transform: back-references in the regexp are not supported"}
    case False{}:
      pe_rep(re, seg(Nat.add(List.length(&2, U32, rest), 1n), d, rest, Nil{}))

def pe_re(+d: U32, sg: Seg) -> Pe:
  match sg:
    case SegNo{}:
      PeErr{"transform: expression must be s/REGEXP/REPLACEMENT/[FLAGS]"}
    case SegOk{+re, +rest}:
      pe_checked(has_backref(Nat.add(List.length(&2, U32, re), 1n), re), d,
        re, rest)

# Parse `s<d>REGEXP<d>REPLACEMENT<d>[gi]`.
def parse(expr: List<&2, U32>) -> Pe:
  match expr:
    case 115 <> +d <> +t:
      pe_re(d, seg(Nat.add(List.length(&2, U32, t), 1n), d, t, Nil{}))
    case _:
      PeErr{"transform: expression must be s/REGEXP/REPLACEMENT/[FLAGS]"}

# ---- substitution ---------------------------------------------------------------

def cap_find(caps: List<&2, Cap>, +n: U32, +done: Bool) ->
  Maybe<&2, List<&2, U32>>:
  match caps:
    case Nil{}:
      None{}
    case MkCap{+cn, text, +cd} <> t:
      Bool.pick(Maybe<&2, List<&2, U32>>,
        Bool.and(U32.is_eq(cn, n), Bool.not(xor(cd, done))), Some{text},
        cap_find(t, n, done))

def cap_join(op: Maybe<&2, List<&2, U32>>, cl: Maybe<&2, List<&2, U32>>) ->
  List<&2, U32>:
  match op:
    case None{}:
      Nil{}
    case Some{+o}:
      match cl:
        case None{}:
          Nil{}
        case Some{+c}:
          List.take(&2, U32, o,
            Nat.sub(List.length(&2, U32, o), List.length(&2, U32, c)))

def cap_text(+caps: List<&2, Cap>, +n: U32) -> List<&2, U32>:
  cap_join(cap_find(caps, n, False{}), cap_find(caps, n, True{}))

def cat(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  B.list_cat(xs, ys)

def ref_text(+n: U32, +text: List<&2, U32>, +caps: List<&2, Cap>) ->
  List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_zero(n), text, cap_text(caps, n))

def expand(fuel: Nat, rep: List<&2, Rp>, +text: List<&2, U32>,
  +caps: List<&2, Cap>) -> List<&2, U32>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match rep:
        case Nil{}:
          Nil{}
        case RLit{c} <> t:
          c <> expand(p, t, text, caps)
        case RRef{n} <> t:
          cat(ref_text(n, text, caps), expand(p, t, text, caps))

type Ss is Data:
  SGo{s: List<&2, U32>, atstart: Bool, acc: List<&2, U32>, fin: Bool,
    noempty: Bool}
  SRes{res: Maybe<&2, Res>, s: List<&2, U32>, atstart: Bool,
    acc: List<&2, U32>, noempty: Bool}
  SAdv{empty: Bool, noempty: Bool, glob: Bool, s: List<&2, U32>,
    rest: List<&2, U32>, acc0: List<&2, U32>, acc2: List<&2, U32>}

# sed does not accept an empty match right after a previous match (noempty).
def adv_state(res: Maybe<&2, Res>, +s: List<&2, U32>, +fuel: Nat,
  rep: List<&2, Rp>, +glob: Bool, +noempty: Bool, +acc: List<&2, U32>) -> Ss:
  match res:
    case Some{MkRes{+rest, +caps}}:
      +mlen = Nat.sub(List.length(&2, U32, s), List.length(&2, U32, rest))
      SAdv{U32.is_zero(U32.from_nat(mlen)), noempty, glob, s, rest, acc,
        B.list_rev(expand(fuel, rep, List.take(&2, U32, s, mlen), caps), acc)}
    case None{}:
      SGo{s, False{}, acc, True{}, False{}}

def sub(+fuel: Nat, +fm: Nat, +fe: Nat, +pat: List<&2, Pt>, +rep: List<&2, Rp>,
  +glob: Bool, +ic: Bool, st: Ss) -> List<&2, U32>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match st:
        case SGo{+s, +atstart, acc, fin, noempty}:
          match fin:
            case True{}:
              B.list_rev(acc, s)
            case False{}:
              sub(p, fm, fe, pat, rep, glob, ic,
                SRes{m(fm, ic, MGo{pat, s, atstart, Nil{}}), s, atstart, acc,
                  noempty})
        case SRes{res, +s, atstart, acc, noempty}:
          match res:
            case None{}:
              match s:
                case Nil{}:
                  B.list_rev(acc, Nil{})
                case h <> t:
                  sub(p, fm, fe, pat, rep, glob, ic,
                    SGo{t, False{}, h <> acc, False{}, False{}})
            case Some{r}:
              sub(p, fm, fe, pat, rep, glob, ic,
                adv_state(res, s, fe, rep, glob, noempty, acc))
        case SAdv{empty, noempty, gl, +s, rest, +acc0, +acc2}:
          match empty:
            case True{}:
              match noempty:
                case True{}:
                  match s:
                    case Nil{}:
                      B.list_rev(acc0, Nil{})
                    case h <> t:
                      sub(p, fm, fe, pat, rep, glob, ic,
                        SGo{t, False{}, h <> acc0, False{}, False{}})
                case False{}:
                  match gl:
                    case True{}:
                      match s:
                        case Nil{}:
                          B.list_rev(acc2, Nil{})
                        case h <> t:
                          sub(p, fm, fe, pat, rep, glob, ic,
                            SGo{t, False{}, h <> acc2, False{}, False{}})
                    case False{}:
                      sub(p, fm, fe, pat, rep, glob, ic,
                        SGo{s, False{}, acc2, True{}, False{}})
            case False{}:
              sub(p, fm, fe, pat, rep, glob, ic,
                SGo{rest, False{}, acc2, Bool.not(gl), True{}})

def apply_one(xc: Xc, +name: List<&2, U32>) -> List<&2, U32>:
  match xc:
    case MkXc{+pat, +rep, +glob, +ic}:
      +n = List.length(&2, U32, name)
      sub(Nat.mul(Nat.add(n, 2n), 8n),
        Nat.mul(Nat.mul(Nat.add(n, 2n),
          Nat.add(List.length(&2, Pt, pat), 2n)), 2n),
        Nat.add(List.length(&2, Rp, rep), 1n), pat, rep, glob, ic,
        SGo{name, True{}, Nil{}, False{}, False{}})

# Apply every expression, in command-line order.
def apply_all(fuel: Nat, cmds: List<&2, Xc>, name: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      name
    case 1n+p:
      match cmds:
        case Nil{}:
          name
        case c <> t:
          apply_all(p, t, apply_one(c, name))

def apply(+cmds: List<&2, Xc>, name: List<&2, U32>) -> List<&2, U32>:
  match cmds:
    case Nil{}:
      name
    case _ <> _:
      apply_all(Nat.add(List.length(&2, Xc, cmds), 1n), cmds, name)
