# app/cli_types.bend — option spec type and byte helpers shared by the CLI modules.
import Base

type Sp is Data:
  MkSp{long: List<&2, U32>, short: U32, takes: U32, id: U32}

def bstr(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bstr(t)

# Items of a parsed command line, in order.  `arg` of an option is its value.
type Item is Data:
  IOpt{id: U32, arg: Maybe<&2, List<&2, U32>>}
  IArg{tok: List<&2, U32>}
  IErr{msg: String}

def starts(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      match ys:
        case Nil{}:
          True{}
        case _ <> _:
          False{}
    case +hx <> +xt:
      match ys:
        case Nil{}:
          True{}
        case +hy <> +yt:
          Bool.and(U32.is_eq(hx, hy), starts(xt, yt))

def beq(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      match ys:
        case Nil{}:
          True{}
        case _ <> _:
          False{}
    case +hx <> +xt:
      match ys:
        case Nil{}:
          False{}
        case +hy <> +yt:
          Bool.and(U32.is_eq(hx, hy), beq(xt, yt))

def drop_n(n: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case _ <> t:
          drop_n(p, t)
