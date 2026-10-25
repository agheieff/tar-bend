# Module: Pth — pure byte-path policy (no effects, no @unsafe).
#
# `safe` normalises an untrusted archive member name:
#   - leading '/' is rejected (Absolute);
#   - the name is split on '/', empty and "." components are dropped;
#   - ".." components are rejected (Parent);
#   - a NUL byte or a component longer than `max_component` is rejected
#     (BadComponent);
#   - the joined normalised path longer than `max_total` is rejected (TooLong).
# The result is a relative, '/'-joined byte list; an empty result (for "",
# "." or "dir/") is allowed, the caller decides by entry type.  Names are
# bytes (`List<&2,U32>`): never routed through String.
#
# `strip` drops the first `n` '/'-components (n > count -> empty); it runs
# before `safe` per plan §5 (`--strip-components` before validation).
#
# Termination: one recursive driver with a Nat fuel argument first; all
# recursive calls shrink it.  No mutual recursion; every byte is compared
# numerically (bounds are structural list traversal).

import Base
import ./bytes.bend as B

type Err is Data:
  Empty{}
  Absolute{}
  Parent{}
  TooLong{}
  BadComponent{}

type St is Data:
  # Scanning a byte of the current component.
  SS{
    name: List<&2, U32>,
    cur: List<&2, U32>,
    clen: U32,
    total: Nat,
    empt: Bool,
    out: List<&2, U32>,
    maxc: U32,
    maxt: U32,
    atstart: Bool
  }
  # Deciding what a just-read byte means.
  SC{
    h: U32,
    name: List<&2, U32>,
    cur: List<&2, U32>,
    clen: U32,
    total: Nat,
    empt: Bool,
    out: List<&2, U32>,
    maxc: U32,
    maxt: U32,
    atstart: Bool,
    slash: Bool,
    nul: Bool
  }
  # Committing the current component (after '/' or at end of name).
  SCm{
    name: List<&2, U32>,
    cur: List<&2, U32>,
    clen: U32,
    total: Nat,
    empt: Bool,
    out: List<&2, U32>,
    maxc: U32,
    maxt: U32,
    nul: Bool,
    badlen: Bool,
    empty: Bool,
    isdot: Bool,
    isdotdot: Bool
  }
  # Pushing the component into the output; checks the total length.
  SP{
    name: List<&2, U32>,
    cur: List<&2, U32>,
    clen: U32,
    total: Nat,
    empt: Bool,
    out: List<&2, U32>,
    maxc: U32,
    maxt: U32,
    toolong: Bool
  }
  SDone{out: List<&2, U32>}
  SFail{err: Err}

# ---- small pure helpers (non-recursive except where noted) ------------

def has_nul(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(U32.is_zero(h), has_nul(t))

def head_or(xs: List<&2, U32>, d: U32) -> U32:
  match xs:
    case Nil{}:
      d
    case +h <> _:
      h

def head2_or(xs: List<&2, U32>, d: U32) -> U32:
  match xs:
    case Nil{}:
      d
    case _ <> t:
      head_or(t, d)

def is_dot_comp(cur: List<&2, U32>, clen: U32) -> Bool:
  Bool.and(U32.is_eq(clen, 1), U32.is_eq(head_or(cur, 0), 46))

def is_dotdot_comp(+cur: List<&2, U32>, clen: U32) -> Bool:
  +two = U32.is_eq(clen, 2)
  +d1 = U32.is_eq(head_or(cur, 0), 46)
  +d2 = U32.is_eq(head2_or(cur, 0), 46)
  Bool.and(two, Bool.and(d1, d2))

def sep_nat(empt: Bool) -> Nat:
  match empt:
    case True{}:
      0n
    case False{}:
      1n

def push_total(total: Nat, clen: U32, empt: Bool) -> Nat:
  Nat.add(total, Nat.add(U32.to_nat(clen), sep_nat(empt)))

def push_out(
  cur: List<&2, U32>, out: List<&2, U32>, empt: Bool
) -> List<&2, U32>:
  match empt:
    case True{}:
      cur
    case False{}:
      B.list_cat(cur, 47 <> out)

# Resume scanning after a committed component: SDone at end of name.
def resume(
  name: List<&2, U32>,
  out: List<&2, U32>,
  total: Nat,
  empt: Bool,
  maxc: U32,
  maxt: U32
) -> St:
  match name:
    case Nil{}:
      SDone{out}
    case _ <> _:
      SS{name, Nil{}, 0, total, empt, out, maxc, maxt, False{}}

# ---- the single driver (one def: no mutual recursion) -------------------

def commit_state(
  name: List<&2, U32>,
  +cur: List<&2, U32>,
  +clen: U32,
  total: Nat,
  empt: Bool,
  out: List<&2, U32>,
  +maxc: U32,
  maxt: U32
) -> St:
  SCm{name, cur, clen, total, empt, out, maxc, maxt, has_nul(cur),
    U32.is_gt(clen, maxc), U32.is_zero(clen), is_dot_comp(cur, clen),
    is_dotdot_comp(cur, clen)}
def scan(fuel: Nat, +st: St) -> Result<&1, &1, Err, List<&2, U32>>:
  match fuel:
    case 0n:
      Fail{TooLong{}}
    case 1n+p:
      match st:
        case SDone{out}:
          Done{B.list_rev(out, Nil{})}
        case SFail{err}:
          Fail{err}
        case SS{name, cur, clen, total, empt, out, maxc, maxt, atstart}:
          match name:
            case Nil{}:
              +emit : St = SCm{name, cur, clen, total, empt, out, maxc, maxt,
                has_nul(cur), U32.is_gt(clen, maxc), U32.is_zero(clen),
                is_dot_comp(cur, clen), is_dotdot_comp(cur, clen)}
              scan(p, emit)
            case h <> t:
              +emit : St = SC{h, t, cur, clen, total, empt, out, maxc, maxt,
                atstart, U32.is_eq(h, 47), U32.is_zero(h)}
              scan(p, emit)
        case SC{h, name, cur, clen, total, empt, out, maxc, maxt, atstart,
            slash, nul}:
          match atstart:
            case True{}:
              match slash:
                case True{}:
                  scan(p, SFail{Absolute{}})
                case False{}:
                  match nul:
                    case True{}:
                      scan(p, SFail{BadComponent{}})
                    case False{}:
                      +clen2 = U32.inc(clen)
                      scan(p, SS{name, h <> cur, clen2, total, empt, out,
                        maxc, maxt, False{}})
            case False{}:
              match slash:
                case True{}:
                  +emit : St = commit_state(name, cur, clen, total, empt, out,
                    maxc, maxt)
                  scan(p, emit)
                case False{}:
                  match nul:
                    case True{}:
                      scan(p, SFail{BadComponent{}})
                    case False{}:
                      +clen2 = U32.inc(clen)
                      scan(p, SS{name, h <> cur, clen2, total, empt, out,
                        maxc, maxt, False{}})
        case SCm{name, cur, clen, total, empt, out, maxc, maxt, nul, badlen,
            empty, isdot, isdotdot}:
          match nul:
            case True{}:
              scan(p, SFail{BadComponent{}})
            case False{}:
              match badlen:
                case True{}:
                  scan(p, SFail{BadComponent{}})
                case False{}:
                  match empty:
                    case True{}:
                      scan(p, resume(name, out, total, empt, maxc, maxt))
                    case False{}:
                      match isdot:
                        case True{}:
                          scan(p, resume(name, out, total, empt, maxc, maxt))
                        case False{}:
                          match isdotdot:
                            case True{}:
                              scan(p, SFail{Parent{}})
                            case False{}:
                              +nt = push_total(total, clen, empt)
                              scan(p, SP{name, cur, clen, total, empt, out,
                                maxc, maxt, Nat.is_gt(nt, U32.to_nat(maxt))})
        case SP{name, cur, clen, total, empt, out, maxc, maxt, toolong}:
          match toolong:
            case True{}:
              scan(p, SFail{TooLong{}})
            case False{}:
              +nt = push_total(total, clen, empt)
              +no = push_out(cur, out, empt)
              scan(p, resume(name, no, nt, False{}, maxc, maxt))

# ---- strip-components --------------------------------------------------

def head_slash(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> _:
      U32.is_eq(h, 47)

# Drop the first n '/'-components. `name` first so termination shrinks it.
def strip_go(
  name: List<&2, U32>, zero: Bool, n: U32, slash: Bool
) -> List<&2, U32>:
  match name:
    case Nil{}:
      Nil{}
    case +h <> +t:
      match zero:
        case True{}:
          h <> t
        case False{}:
          match slash:
            case True{}:
              +n2 = U32.sub(n, 1)
              strip_go(t, U32.is_zero(n2), n2, head_slash(t))
            case False{}:
              strip_go(t, False{}, n, head_slash(t))

def strip(+n: U32, +name: List<&2, U32>) -> List<&2, U32>:
  strip_go(name, U32.is_zero(n), n, head_slash(name))


# ---- API ---------------------------------------------------------------

# Normalise an untrusted member name; see the module comment.
def safe(
  +max_component: U32, +max_total: U32, +name: List<&2, U32>
) -> Result<&1, &1, Err, List<&2, U32>>:
  +start : St = SS{name, Nil{}, 0, 0n, True{}, Nil{}, max_component,
    max_total, True{}}
  scan(Nat.add(Nat.mul(4n, List.length(&2, U32, name)), 8n), start)

def err_show(e: Err) -> String:
  match e:
    case Empty{}:
      "empty"
    case Absolute{}:
      "absolute"
    case Parent{}:
      "parent"
    case TooLong{}:
      "too-long"
    case BadComponent{}:
      "bad-component"
