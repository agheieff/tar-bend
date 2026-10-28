# app/cli.bend — GNU-style command-line parser (table driven, one pass).
#
# argv (program name already dropped) -> ordered `Item`s: options with their values and
# operands.  Handles bundled short options (`-xvf FILE`, `-cTfoo` takes `foo` as the -T
# value), `--long[=value]` with unique-prefix abbreviations, `--` and old-style first
# arguments (`tar cf a.tar`).  Which option exists comes from cli_table.bend (generated).
# No semantics here: the queries below are what main uses.
import Base
import ./cli_types.bend as T
import ./cli_table.bend as Tb

# ---- lookup ----------------------------------------------------------------------

type Lk is Data:
  LkNone{}
  LkOne{sp: T.Sp}
  LkAmbig{}

def sp_long(sp: T.Sp) -> List<&2, U32>:
  match sp:
    case T.MkSp{lg, _, _, _}:
      lg

def sp_short(sp: T.Sp) -> U32:
  match sp:
    case T.MkSp{_, sh, _, _}:
      sh

def ex_pick(hit: Bool, +sp: T.Sp, ex: Maybe<&2, T.Sp>) -> Maybe<&2, T.Sp>:
  match hit:
    case True{}:
      Some{sp}
    case False{}:
      ex

def pf_pick(hit: Bool, +sp: T.Sp, pf: Maybe<&2, T.Sp>) -> Maybe<&2, T.Sp>:
  match hit:
    case True{}:
      Some{sp}
    case False{}:
      pf

def np_add(hit: Bool, +np: Nat) -> Nat:
  match hit:
    case True{}:
      Nat.add(np, 1n)
    case False{}:
      np

def lk_fin(ex: Maybe<&2, T.Sp>, pf: Maybe<&2, T.Sp>, np: Nat) -> Lk:
  match ex:
    case Some{sp}:
      LkOne{sp}
    case None{}:
      match pf:
        case None{}:
          LkNone{}
        case Some{sp}:
          match np:
            case 1n:
              LkOne{sp}
            case _:
              LkAmbig{}

# Exact match wins; otherwise a unique prefix.
def lk_go(fuel: Nat, tbl: List<&2, T.Sp>, +name: List<&2, U32>,
  ex: Maybe<&2, T.Sp>, pf: Maybe<&2, T.Sp>, np: Nat) -> Lk:
  match fuel:
    case 0n:
      LkNone{}
    case 1n+p:
      match tbl:
        case Nil{}:
          lk_fin(ex, pf, np)
        case +sp <> t:
          +hit_ex = T.beq(sp_long(sp), name)
          +hit_pf = T.starts(sp_long(sp), name)
          lk_go(p, t, name, ex_pick(hit_ex, sp, ex), pf_pick(hit_pf, sp, pf),
            np_add(hit_pf, np))

def find_long(+name: List<&2, U32>) -> Lk:
  lk_go(1024n, Tb.table(), name, None{}, None{}, 0n)

def short_go(fuel: Nat, tbl: List<&2, T.Sp>, +c: U32) -> Maybe<&2, T.Sp>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match tbl:
        case Nil{}:
          None{}
        case +sp <> t:
          ex_pick(U32.is_eq(sp_short(sp), c), sp, short_go(p, t, c))

def find_short(+c: U32) -> Maybe<&2, T.Sp>:
  short_go(1024n, Tb.table(), c)

# ---- tokens ------------------------------------------------------------------------

type Eq is Data:
  MkEq{name: List<&2, U32>, val: Maybe<&2, List<&2, U32>>}

def rev(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev(t, h <> acc)

# `name=value` -> (name, value); the name is built reversed, then flipped.
def eq_go(xs: List<&2, U32>, acc: List<&2, U32>) -> Eq:
  match xs:
    case Nil{}:
      MkEq{rev(acc, Nil{}), None{}}
    case 61 <> t:
      MkEq{rev(acc, Nil{}), Some{t}}
    case h <> t:
      eq_go(t, h <> acc)

def show_bytes(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      SCon{Char.from_u32(h), show_bytes(t)}

type Pr is Data:
  PrOk{acc: List<&2, T.Item>, want: U32}

type Cu is Data:
  CuGo{cs: List<&2, U32>, acc: List<&2, T.Item>}
  CuSp{m: Maybe<&2, T.Sp>, c: U32, t: List<&2, U32>, acc: List<&2, T.Item>}

def bad_short(+c: U32) -> T.Item:
  T.IErr{"invalid option -- '" ++ SCon{Char.from_u32(c), SNil{}} ++ "'"}

# One short-option cluster (without the leading '-').  An option taking a value
# consumes the rest of the cluster, or the next token when nothing is left.
def clu(fuel: Nat, st: Cu) -> Pr:
  match fuel:
    case 0n:
      PrOk{Nil{}, 0}
    case 1n+p:
      match st:
        case CuGo{cs, acc}:
          match cs:
            case Nil{}:
              PrOk{acc, 0}
            case +c <> t:
              clu(p, CuSp{find_short(c), c, t, acc})
        case CuSp{m, c, t, acc}:
          match m:
            case None{}:
              clu(p, CuGo{t, bad_short(c) <> acc})
            case Some{T.MkSp{_, _, tk, id}}:
              match tk:
                case 0:
                  clu(p, CuGo{t, T.IOpt{id, None{}} <> acc})
                case _:
                  match t:
                    case Nil{}:
                      PrOk{acc, id}
                    case _ <> _:
                      PrOk{T.IOpt{id, Some{t}} <> acc, 0}

type Pst is Type:
  PGo{acc: List<&2, T.Item>, want: U32, first: Bool,
    argv: List<&1, List<&2, U32>>}
  PCl{pr: Pr, argv: List<&1, List<&2, U32>>}
  PLg{lk: Lk, val: Maybe<&2, List<&2, U32>>, tok: List<&2, U32>,
    acc: List<&2, T.Item>, argv: List<&1, List<&2, U32>>}
  PEnd{acc: List<&2, T.Item>}

def rest_args(fuel: Nat, argv: List<&1, List<&2, U32>>,
  acc: List<&2, T.Item>) -> List<&2, T.Item>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match argv:
        case Nil{}:
          acc
        case h <> t:
          rest_args(p, t, T.IArg{h} <> acc)

def rev_items(xs: List<&2, T.Item>, acc: List<&2, T.Item>) ->
  List<&2, T.Item>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_items(t, h <> acc)

def eof_items(want: U32, acc: List<&2, T.Item>) -> List<&2, T.Item>:
  match want:
    case 0:
      rev_items(acc, Nil{})
    case _:
      rev_items(T.IErr{"option '" ++ Tb.long_name(want) ++
        "' requires an argument"} <> acc, Nil{})

# A long option applied to `acc`.
def lg_apply(lk: Lk, val: Maybe<&2, List<&2, U32>>, tok: List<&2, U32>,
  acc: List<&2, T.Item>) -> Pr:
  match lk:
    case LkNone{}:
      PrOk{T.IErr{"unrecognized option '" ++ show_bytes(tok) ++ "'"} <> acc, 0}
    case LkAmbig{}:
      PrOk{T.IErr{"option '" ++ show_bytes(tok) ++ "' is ambiguous"} <> acc, 0}
    case LkOne{T.MkSp{_, _, tk, id}}:
      match tk:
        case 0:
          match val:
            case None{}:
              PrOk{T.IOpt{id, None{}} <> acc, 0}
            case Some{_}:
              PrOk{T.IErr{"option '" ++ Tb.long_name(id) ++
                "' doesn't allow an argument"} <> acc, 0}
        case 1:
          match val:
            case None{}:
              PrOk{acc, id}
            case Some{v}:
              PrOk{T.IOpt{id, Some{v}} <> acc, 0}
        case _:
          PrOk{T.IOpt{id, val} <> acc, 0}

def tok_long(eq: Eq, tok: List<&2, U32>, acc: List<&2, T.Item>,
  argv: List<&1, List<&2, U32>>) -> Pst:
  match eq:
    case MkEq{name, val}:
      PLg{find_long(name), val, tok, acc, argv}

def tok_oldstyle(old: Bool, +tok: List<&2, U32>, acc: List<&2, T.Item>,
  argv: List<&1, List<&2, U32>>) -> Pst:
  match old:
    case True{}:
      PCl{clu(4096n, CuGo{tok, acc}), argv}
    case False{}:
      PGo{T.IArg{tok} <> acc, 0, False{}, argv}

def tok_short(dash: Bool, +tok: List<&2, U32>, +first: Bool,
  acc: List<&2, T.Item>, argv: List<&1, List<&2, U32>>) -> Pst:
  match dash:
    case True{}:
      PCl{clu(4096n, CuGo{T.drop_n(1n, tok), acc}), argv}
    case False{}:
      tok_oldstyle(first, tok, acc, argv)

def tok_long_or(long: Bool, +tok: List<&2, U32>, +first: Bool,
  acc: List<&2, T.Item>, argv: List<&1, List<&2, U32>>) -> Pst:
  match long:
    case True{}:
      tok_long(eq_go(T.drop_n(2n, tok), Nil{}), tok, acc, argv)
    case False{}:
      tok_short(T.starts(tok, T.bstr("-")), tok, first, acc, argv)

def tok_dd(dd: Bool, +tok: List<&2, U32>, +first: Bool,
  acc: List<&2, T.Item>, argv: List<&1, List<&2, U32>>) -> Pst:
  match dd:
    case True{}:
      PEnd{rest_args(1048576n, argv, acc)}
    case False{}:
      tok_long_or(T.starts(tok, T.bstr("--")), tok, first, acc, argv)

def tok_dash(d: Bool, +tok: List<&2, U32>, +first: Bool,
  acc: List<&2, T.Item>, argv: List<&1, List<&2, U32>>) -> Pst:
  match d:
    case True{}:
      PGo{T.IArg{tok} <> acc, 0, False{}, argv}
    case False{}:
      tok_dd(T.beq(tok, T.bstr("--")), tok, first, acc, argv)

def tok_state(acc: List<&2, T.Item>, first: Bool, +tok: List<&2, U32>,
  argv: List<&1, List<&2, U32>>) -> Pst:
  tok_dash(T.beq(tok, T.bstr("-")), tok, first, acc, argv)

def pstep(fuel: Nat, st: Pst) -> List<&2, T.Item>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match st:
        case PEnd{acc}:
          rev_items(acc, Nil{})
        case PCl{pr, argv}:
          match pr:
            case PrOk{acc, want}:
              pstep(p, PGo{acc, want, False{}, argv})
        case PLg{lk, val, tok, acc, argv}:
          pstep(p, PCl{lg_apply(lk, val, tok, acc), argv})
        case PGo{acc, want, first, argv}:
          match want:
            case 0:
              match argv:
                case Nil{}:
                  rev_items(acc, Nil{})
                case +tok <> t:
                  pstep(p, tok_state(acc, first, tok, t))
            case _:
              match argv:
                case Nil{}:
                  eof_items(want, acc)
                case +tok <> t:
                  pstep(p, PGo{T.IOpt{want, Some{tok}} <> acc, 0, False{}, t})

# ---- entry point and queries -------------------------------------------------------

def parse(argv: List<&1, List<&2, U32>>) -> List<&2, T.Item>:
  pstep(1048576n, PGo{Nil{}, 0, True{}, argv})

def has_opt(items: List<&2, T.Item>, +id: U32) -> Bool:
  match items:
    case Nil{}:
      False{}
    case T.IOpt{oid, _} <> t:
      Bool.or(U32.is_eq(oid, id), has_opt(t, id))
    case _ <> t:
      has_opt(t, id)

def count_opt(items: List<&2, T.Item>, +id: U32) -> Nat:
  match items:
    case Nil{}:
      0n
    case T.IOpt{oid, _} <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(oid, id), 1n, 0n), count_opt(t, id))
    case _ <> t:
      count_opt(t, id)

def opt_args_pick(hit: Bool, arg: Maybe<&2, List<&2, U32>>,
  rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hit:
    case False{}:
      rest
    case True{}:
      match arg:
        case Some{v}:
          v <> rest
        case None{}:
          rest

# Values of an option, in command-line order.
def opt_args(items: List<&2, T.Item>, +id: U32) -> List<&2, List<&2, U32>>:
  match items:
    case Nil{}:
      Nil{}
    case T.IOpt{oid, arg} <> t:
      opt_args_pick(U32.is_eq(oid, id), arg, opt_args(t, id))
    case _ <> t:
      opt_args(t, id)

def last_of(xs: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      None{}
    case h <> t:
      match t:
        case Nil{}:
          Some{h}
        case _ <> _:
          last_of(t)

def opt_last(items: List<&2, T.Item>, id: U32) -> Maybe<&2, List<&2, U32>>:
  last_of(opt_args(items, id))

def operands(items: List<&2, T.Item>) -> List<&2, List<&2, U32>>:
  match items:
    case Nil{}:
      Nil{}
    case T.IArg{tok} <> t:
      tok <> operands(t)
    case _ <> t:
      operands(t)

# First parse error, if any.
def first_err(items: List<&2, T.Item>) -> Maybe<&2, String>:
  match items:
    case Nil{}:
      None{}
    case T.IErr{msg} <> _:
      Some{msg}
    case _ <> t:
      first_err(t)

def find_pick(hit: Bool, arg: Maybe<&2, List<&2, U32>>,
  rest: Maybe<&2, Maybe<&2, List<&2, U32>>>) ->
  Maybe<&2, Maybe<&2, List<&2, U32>>>:
  match hit:
    case False{}:
      rest
    case True{}:
      match rest:
        case Some{_}:
          rest
        case None{}:
          Some{arg}

# Last occurrence of an option: its (possibly absent) attached value.
def opt_find(items: List<&2, T.Item>, +id: U32) ->
  Maybe<&2, Maybe<&2, List<&2, U32>>>:
  match items:
    case Nil{}:
      None{}
    case T.IOpt{oid, arg} <> t:
      find_pick(U32.is_eq(oid, id), arg, opt_find(t, id))
    case _ <> t:
      opt_find(t, id)

# Values of either of two options, in command-line order.
def opt_args2(items: List<&2, T.Item>, +id1: U32, +id2: U32) ->
  List<&2, List<&2, U32>>:
  match items:
    case Nil{}:
      Nil{}
    case T.IOpt{+oid, arg} <> t:
      opt_args_pick(Bool.or(U32.is_eq(oid, id1), U32.is_eq(oid, id2)), arg,
        opt_args2(t, id1, id2))
    case _ <> t:
      opt_args2(t, id1, id2)
