# Module: Glob — fnmatch-style matcher for `--exclude` (pure, byte based).
#
# GNU tar's default exclusion semantics: patterns are wildcards where `*`,
# `?` and `[...]` also match '/', a leading directory match counts
# (FNM_LEADING_DIR: pattern `foo` excludes `foo/bar`), and the pattern is not
# anchored: it may match the whole name or any suffix that follows a '/'.
# Supported: `*`, `?`, `[set]`, `[!set]`, `[^set]`, ranges `a-z`, `\x` escapes
# (also inside sets).  Not supported: POSIX classes `[:alpha:]`, `[=x=]`,
# `[.x.]`; an unterminated `[` is a literal.  Trailing slashes are ignored on
# the name, as GNU does.
#
# Every loop is one fuel-bounded recursion (no mutual recursion); matching is
# O(|pattern| * |name|) per candidate (greedy star with a single backtrack
# point), so hostile patterns cannot blow up.
import Base
import ./bytes.bend as B
import ./upd.bend as U

# ---- bracket expressions --------------------------------------------------

# Parse state: p = pattern after '[' (consumed so far), c = the byte tested.
type Br is Data:
  BrGo{p: List<&2, U32>, c: U32, neg: Bool, first: Bool, hit: Bool}
  BrFin{valid: Bool, ok: Bool, rest: List<&2, U32>}

# One set member starting at h <> t: (member byte, remaining pattern); a
# backslash escapes the next byte.
def br_member(+h: U32, +t: List<&2, U32>) -> U32 & List<&2, U32>:
  match h:
    case 92:
      match t:
        case Nil{}:
          (h, t)
        case e <> t2:
          (e, t2)
    case _:
      (h, t)

def br_in(+a: U32, +b: U32, +c: U32) -> Bool:
  Bool.and(U32.is_ge(c, a), U32.is_le(c, b))

def br_range_end(+a: U32, bm: U32 & List<&2, U32>, +c: U32) ->
  Bool & List<&2, U32>:
  (b, rest) = bm
  (br_in(a, b, c), rest)

# After member `a` (rest `r`): a range `a-b` when '-' is followed by a member
# that is not the closing ']'; otherwise just `a`.
def br_range(+a: U32, +r: List<&2, U32>, +c: U32) -> Bool & List<&2, U32>:
  match r:
    case Nil{}:
      (U32.is_eq(a, c), r)
    case h <> t:
      match h:
        case 45:
          match t:
            case Nil{}:
              (U32.is_eq(a, c), h <> t)
            case h2 <> t2:
              match h2:
                case 93:
                  (U32.is_eq(a, c), h <> (h2 <> t2))
                case _:
                  br_range_end(a, br_member(h2, t2), c)
        case _:
          (U32.is_eq(a, c), h <> t)

def br_item3(hr: Bool & List<&2, U32>, +c: U32, +neg: Bool, +hit: Bool) -> Br:
  (m, rest) = hr
  BrGo{rest, c, neg, False{}, Bool.or(hit, m)}

def br_item2(am: U32 & List<&2, U32>, +c: U32, +neg: Bool, +hit: Bool) -> Br:
  (a, r) = am
  br_item3(br_range(a, r, c), c, neg, hit)

def br_item(+c: U32, +neg: Bool, +hit: Bool, +h: U32, +t: List<&2, U32>) -> Br:
  br_item2(br_member(h, t), c, neg, hit)

def br_close(+first: Bool, +neg: Bool, +hit: Bool, +c: U32, +h: U32,
  +t: List<&2, U32>) -> Br:
  match first:
    case True{}:
      br_item(c, neg, hit, h, t)
    case False{}:
      BrFin{True{}, Bool.pick(Bool, neg, Bool.not(hit), hit), t}

def br_run(fuel: Nat, st: Br) -> Br:
  match fuel:
    case 0n:
      BrFin{False{}, False{}, Nil{}}
    case 1n+n:
      match st:
        case BrFin{valid, ok, rest}:
          BrFin{valid, ok, rest}
        case BrGo{p, c, neg, first, hit}:
          match p:
            case Nil{}:
              BrFin{False{}, False{}, Nil{}}
            case h <> t:
              match h:
                case 93:
                  br_run(n, br_close(first, neg, hit, c, h, t))
                case _:
                  br_run(n, br_item(c, neg, hit, h, t))

# `rest` starts right after '[': optional '!' or '^' negation, then members.
def br_start(+rest: List<&2, U32>, +c: U32) -> Br:
  match rest:
    case Nil{}:
      BrFin{False{}, False{}, Nil{}}
    case h <> t:
      match h:
        case 33:
          BrGo{t, c, True{}, True{}, False{}}
        case 94:
          BrGo{t, c, True{}, True{}, False{}}
        case _:
          BrGo{h <> t, c, False{}, True{}, False{}}

# ---- fnmatch ---------------------------------------------------------------

# p/s: remaining pattern/subject; sp/ss: pattern after the last '*' and the
# subject position to retry from; star: a '*' has been seen; ld: leading-dir.
type Gm is Data:
  GGo{p: List<&2, U32>, s: List<&2, U32>, sp: List<&2, U32>,
    ss: List<&2, U32>, star: Bool, ld: Bool}
  GFin{ok: Bool}

def g_back(+star: Bool, +ss: List<&2, U32>, +sp: List<&2, U32>, +ld: Bool) -> Gm:
  match star:
    case False{}:
      GFin{False{}}
    case True{}:
      match ss:
        case Nil{}:
          GFin{False{}}
        case _ <> t:
          GGo{sp, t, sp, t, True{}, ld}

def g_slash(+s: List<&2, U32>) -> Bool:
  match s:
    case Nil{}:
      False{}
    case h <> _:
      U32.is_eq(h, 47)

def g_end2(+done: Bool, +sp: List<&2, U32>, +ss: List<&2, U32>, +star: Bool,
  +ld: Bool) -> Gm:
  match done:
    case True{}:
      GFin{True{}}
    case False{}:
      g_back(star, ss, sp, ld)

# Pattern exhausted: match if the subject is too, or (leading-dir) the rest
# of the subject starts a path component.
def g_end(+s: List<&2, U32>, +sp: List<&2, U32>, +ss: List<&2, U32>,
  +star: Bool, +ld: Bool) -> Gm:
  match s:
    case Nil{}:
      GFin{True{}}
    case h <> t:
      g_end2(Bool.and(ld, U32.is_eq(h, 47)), sp, ss, star, ld)

def g_lit(+eq: Bool, +pt: List<&2, U32>, st: List<&2, U32>,
  +sp: List<&2, U32>, +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match eq:
    case True{}:
      GGo{pt, st, sp, ss, star, ld}
    case False{}:
      g_back(star, ss, sp, ld)

def g_one(+pc: U32, +pt: List<&2, U32>, +s: List<&2, U32>,
  +sp: List<&2, U32>, +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match s:
    case Nil{}:
      g_back(star, ss, sp, ld)
    case c <> st:
      g_lit(U32.is_eq(pc, c), pt, st, sp, ss, star, ld)

def g_any(+pt: List<&2, U32>, +s: List<&2, U32>, +sp: List<&2, U32>,
  +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match s:
    case Nil{}:
      g_back(star, ss, sp, ld)
    case _ <> st:
      GGo{pt, st, sp, ss, star, ld}

# '\x' consumes the escaped byte as a literal; a trailing '\' never matches.
def g_esc(+pt: List<&2, U32>, +s: List<&2, U32>, +sp: List<&2, U32>,
  +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match pt:
    case Nil{}:
      g_back(star, ss, sp, ld)
    case e <> pt2:
      g_one(e, pt2, s, sp, ss, star, ld)

# An unterminated '[' is a literal '[' (valid = False).
def g_set3(br: Br, +c: U32, +pt: List<&2, U32>, st: List<&2, U32>,
  +sp: List<&2, U32>, +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match br:
    case BrFin{valid, ok, rest}:
      match valid:
        case False{}:
          g_lit(U32.is_eq(91, c), pt, st, sp, ss, star, ld)
        case True{}:
          g_lit(ok, rest, st, sp, ss, star, ld)
    case BrGo{p, c2, neg, first, hit}:
      g_back(star, ss, sp, ld)

def g_set(+pt: List<&2, U32>, +s: List<&2, U32>, +sp: List<&2, U32>,
  +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match s:
    case Nil{}:
      g_back(star, ss, sp, ld)
    case +c <> st:
      g_set3(br_run(Nat.add(List.length(&2, U32, pt), 2n), br_start(pt, c)),
        c, pt, st, sp, ss, star, ld)

def g_step(+pc: U32, +pt: List<&2, U32>, +s: List<&2, U32>,
  +sp: List<&2, U32>, +ss: List<&2, U32>, +star: Bool, +ld: Bool) -> Gm:
  match pc:
    case 42:
      GGo{pt, s, pt, s, True{}, ld}
    case 63:
      g_any(pt, s, sp, ss, star, ld)
    case 91:
      g_set(pt, s, sp, ss, star, ld)
    case 92:
      g_esc(pt, s, sp, ss, star, ld)
    case _:
      g_one(pc, pt, s, sp, ss, star, ld)

def g_run(fuel: Nat, st: Gm) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+n:
      match st:
        case GFin{ok}:
          ok
        case GGo{p, s, sp, ss, star, ld}:
          match p:
            case Nil{}:
              g_run(n, g_end(s, sp, ss, star, ld))
            case pc <> pt:
              g_run(n, g_step(pc, pt, s, sp, ss, star, ld))

# fnmatch(pattern, subject) with FNM_LEADING_DIR (no PATHNAME/PERIOD).
def fnm(+pat: List<&2, U32>, +s: List<&2, U32>) -> Bool:
  g_run(Nat.mul(Nat.add(List.length(&2, U32, pat), 2n),
    Nat.add(List.length(&2, U32, s), 3n)),
    GGo{pat, s, Nil{}, Nil{}, False{}, True{}})

# ---- unanchored, suffix-after-slash matching ------------------------------

def sfx_cand(+fresh: Bool, +pat: List<&2, U32>, +rest: List<&2, U32>) -> Bool:
  match fresh:
    case True{}:
      fnm(pat, rest)
    case False{}:
      False{}

# The next position starts a candidate when this byte is '/' and the one
# after it is not (GNU: `*p == '/' && p[1] != '/'`).
def sfx_fresh(+h: U32, +t: List<&2, U32>) -> Bool:
  match t:
    case Nil{}:
      U32.is_eq(h, 47)
    case h2 <> _:
      Bool.and(U32.is_eq(h, 47), Bool.not(U32.is_eq(h2, 47)))

# Candidates: the whole name and every suffix that follows such a '/'.
# `fresh` marks `rest` as a candidate start.
def sfx(fuel: Nat, +found: Bool, +fresh: Bool, +pat: List<&2, U32>,
  +rest: List<&2, U32>) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+n:
      match found:
        case True{}:
          True{}
        case False{}:
          match rest:
            case Nil{}:
              sfx_cand(fresh, pat, Nil{})
            case h <> t:
              sfx(n, sfx_cand(fresh, pat, h <> t), sfx_fresh(h, t), pat, t)

# One pattern against a stored member name (trailing slashes ignored).
def match_one(+pat: List<&2, U32>, +name: List<&2, U32>) -> Bool:
  sfx(Nat.add(List.length(&2, U32, name), 2n), False{}, True{}, pat, name)

def exc_run(fuel: Nat, +found: Bool, +pats: List<&2, List<&2, U32>>,
  +name: List<&2, U32>) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+n:
      match found:
        case True{}:
          True{}
        case False{}:
          match pats:
            case Nil{}:
              False{}
            case p <> t:
              exc_run(n, match_one(p, name), t, name)

# True when any pattern excludes `name` (as stored in the archive).
def excluded(+pats: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Bool:
  match pats:
    case Nil{}:
      False{}
    case _ <> _:
      exc_run(Nat.add(List.length(&2, List<&2, U32>, pats), 1n), False{},
        pats, U.norm_cut(name))
