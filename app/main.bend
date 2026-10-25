# app/main.bend — btar CLI (M3): stream-list and stream-extract a tar archive.
#
#   btar -tf ARCHIVE [-v]
#   btar -xf ARCHIVE [-C DIR] [-v] [--strip-components=N] [-p] [-O]
#   btar -xf ARCHIVE --one-top-level[=DIR]
#   btar -t -f ARCHIVE / btar -x -f ARCHIVE / btar --list -f ARCHIVE
#
# argv is handled as raw bytes end to end (IO.args_bytes): archive and -C
# paths never round-trip through String.  Listing writes raw member-name bytes
# (Stdout effect) so non-UTF-8 names survive; extraction is dirfd-relative and
# never follows a symlink.  Format parsing is the pure core; src/read_stream is
# the streaming driver.
import Base
import ../src/bytes.bend as B
import ../src/read_stream.bend as R
import ../effs/effects.bend as Fx
import ../src/write.bend as Wr
import ../src/append.bend as Ap
import ../src/upd.bend as U
import ../src/gzio.bend as Gzio

# ---- byte helpers ---------------------------------------------------------

def bstr(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bstr(t)

# Local byte-list equality. (src/bytes.B.eq_list drops the final element's
# comparison and even its `same` flag at the Nil base case -- reported to
# tar-parser; do not use it for token/component equality until fixed.)
type Eqb is Data:
  EqbGo{xs: List<&2, U32>, ys: List<&2, U32>}
  EqbFin{b: Bool}

def eqb_step(same: Bool, t: List<&2, U32>, t2: List<&2, U32>) -> Eqb:
  match same:
    case True{}:
      EqbGo{t, t2}
    case False{}:
      EqbFin{False{}}

def eqb_run(fuel: Nat, st: Eqb) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match st:
        case EqbFin{b}:
          b
        case EqbGo{xs, ys}:
          match xs:
            case Nil{}:
              match ys:
                case Nil{}:
                  True{}
                case _ <> _:
                  False{}
            case +h <> t:
              match ys:
                case Nil{}:
                  False{}
                case +h2 <> t2:
                  eqb_run(p, eqb_step(U32.is_eq(h, h2), t, t2))

def beq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  eqb_run(8192n, EqbGo{xs, ys})

def starts(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      match ys:
        case Nil{}:
          True{}
        case +gy <> +yt:
          False{}
    case +hx <> +xt:
      match ys:
        case Nil{}:
          True{}
        case +gy <> +yt:
          Bool.and(U32.is_eq(hx, gy), starts(xt, yt))

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

def blen(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      (1n + blen(t) : Nat)

def usage() -> String:
  "usage: btar [-tf|-xf|-tzf|-xzf ARCHIVE] [-C DIR] [-v] [-p] [-O] " ++
  "[--strip-components=N] [--one-top-level[=DIR]] [-z]\n" ++
  "       [--exclude=PATTERN] [--exclude-from=FILE] [--version]\n" ++
  "gzip is streamed (no size caps). - is not supported as an archive."

def rev_b(fuel: Nat, xs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case h <> t:
          rev_b(p, t, h <> acc)

def slash() -> List<&2, U32>:
  47 <> Nil{}

def path_join(base: List<&2, U32>, comp: List<&2, U32>) -> List<&2, U32>:
  match base:
    case Nil{}:
      comp
    case _:
      B.list_cat(base, B.list_cat(slash(), comp))

type Bs is Data:
  BsGo{rest: List<&2, U32>, cur: List<&2, U32>}
  BsFin{out: List<&2, U32>}

def bn_step(is_slash: Bool, h: U32, t: List<&2, U32>,
  cur: List<&2, U32>) -> Bs:
  match is_slash:
    case True{}:
      BsGo{t, Nil{}}
    case False{}:
      BsGo{t, h <> cur}

def bn_run(fuel: Nat, st: Bs) -> List<&2, U32>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match st:
        case BsFin{out}:
          out
        case BsGo{rest, cur}:
          match rest:
            case Nil{}:
              cur
            case +h <> +t:
              bn_run(p, bn_step(U32.is_eq(h, 47), h, t, cur))

def basename(xs: List<&2, U32>) -> List<&2, U32>:
  rev_b(8192n, bn_run(8192n, BsGo{xs, Nil{}}), Nil{})

def suffix_case(is_tar: Bool, b: List<&2, U32>, r: List<&2, U32>) ->
  List<&2, U32>:
  match is_tar:
    case True{}:
      rev_b(8192n, drop_n(4n, r), Nil{})
    case False{}:
      b

def one_top_name(archive: List<&2, U32>) -> List<&2, U32>:
  +b : List<&2, U32> = basename(archive)
  +r : List<&2, U32> = rev_b(8192n, b, Nil{})
  +rs : List<&2, U32> = rev_b(8192n, bstr(".tar"), Nil{})
  suffix_case(starts(r, rs), b, r)

# ---- decimal parser (bytes -> U32, fail fast) ----------------------------

type Dg is Data:
  DgGo{rest: List<&2, U32>, acc: U32}
  DgFin{m: Maybe<&2, U32>}

def dg_step(is_dig: Bool, h: U32, t: List<&2, U32>, acc: U32) -> Dg:
  match is_dig:
    case True{}:
      DgGo{t, U32.add(U32.mul(acc, 10), U32.sub(h, 48))}
    case False{}:
      DgFin{None{}}

def dg_run(fuel: Nat, st: Dg) -> Maybe<&2, U32>:
  match fuel:
    case 0n:
      None{}
    case 1n+p:
      match st:
        case DgFin{m}:
          m
        case DgGo{rest, acc}:
          match rest:
            case Nil{}:
              Some{acc}
            case +h <> +t:
              dg_run(p,
                dg_step(Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57)), h, t,
                  acc))

def parse_u32_bytes(xs: List<&2, U32>) -> Maybe<&2, U32>:
  dg_run(8192n, DgGo{xs, 0})

# ---- token classes --------------------------------------------------------

def iftag(c: Bool, t: Unit -> Tag, f: Unit -> Tag) -> Tag:
  match c:
    case True{}:
      t(Unit{})
    case False{}:
      f(Unit{})

type Tag is Data:
  TTf{}
  TXf{}
  TT{}
  TX{}
  TF{}
  TC{}
  TV{}
  TP{}
  TPres{}
  TO{}
  TOneAuto{}
  TOneArg{dir: List<&2, U32>}
  TList{}
  TStrip{}
  TBad{}

def cls14(+tok: List<&2, U32>) -> Tag:
  iftag(starts(tok, bstr("--strip-components=")), u => TStrip{}, u => TBad{})

def cls13b(+tok: List<&2, U32>) -> Tag:
  iftag(starts(tok, bstr("--one-top-level=")),
    u => TOneArg{drop_n(16n, tok)}, u => cls14(tok))

def cls13(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("--one-top-level")), u => TOneAuto{},
    u => cls13b(tok))

def cls12(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-O")), u => TO{}, u => cls13(tok))

def cls11(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("--preserve-permissions")), u => TPres{},
    u => cls12(tok))

def cls10(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-p")), u => TP{}, u => cls11(tok))

def cls9(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("--list")), u => TList{}, u => cls10(tok))

def cls8(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-v")), u => TV{}, u => cls9(tok))

def cls7(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-C")), u => TC{}, u => cls8(tok))

def cls6(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-f")), u => TF{}, u => cls7(tok))

def cls5(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-x")), u => TX{}, u => cls6(tok))

def cls4(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-t")), u => TT{}, u => cls5(tok))

def cls3(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-xf")), u => TXf{}, u => cls4(tok))

def cls2(+tok: List<&2, U32>) -> Tag:
  iftag(beq(tok, bstr("-tf")), u => TTf{}, u => cls3(tok))

def cls(tok: List<&2, U32>) -> Tag:
  cls2(tok)

# ---- options and parser states -------------------------------------------

type OneTop is Data:
  OtNo{}
  OtAuto{}
  OtDir{dir: List<&2, U32>}

type Opts is Data:
  MkOpts{
    archive: List<&2, U32>,
    extract: Bool,
    to_stdout: Bool,
    root: Maybe<&2, List<&2, U32>>,
    onetop: OneTop,
    strip: U32,
    verbose: Bool,
    preserve: Bool
  }

type Ps is Data:
  PStart{
    list: Bool,
    extract: Bool,
    to_stdout: Bool,
    verbose: Bool,
    preserve: Bool,
    strip: U32,
    path: Maybe<&2, List<&2, U32>>,
    root: Maybe<&2, List<&2, U32>>,
    onetop: OneTop
  }
  PWantFile{
    list: Bool,
    extract: Bool,
    to_stdout: Bool,
    verbose: Bool,
    preserve: Bool,
    strip: U32,
    root: Maybe<&2, List<&2, U32>>,
    onetop: OneTop
  }
  PWantDir{
    list: Bool,
    extract: Bool,
    to_stdout: Bool,
    verbose: Bool,
    preserve: Bool,
    strip: U32,
    path: Maybe<&2, List<&2, U32>>,
    onetop: OneTop
  }
  PDone{
    list: Bool,
    extract: Bool,
    to_stdout: Bool,
    verbose: Bool,
    preserve: Bool,
    strip: U32,
    path: Maybe<&2, List<&2, U32>>,
    root: Maybe<&2, List<&2, U32>>,
    onetop: OneTop
  }
  PBad{}

# ---- token -> next state --------------------------------------------------

# Bundled short options ("-xO", "-xpf", "-xOf"): GNU-compatible single-dash
# clusters of flag letters; f/C must be the last letter (value = next argv).
type Bst is Data:
  BstGo{
    rest: List<&2, U32>,
    list: Bool,
    extract: Bool,
    to_stdout: Bool,
    verbose: Bool,
    preserve: Bool,
    strip: U32,
    path: Maybe<&2, List<&2, U32>>,
    root: Maybe<&2, List<&2, U32>>,
    onetop: OneTop
  }
  BstFile{rest: List<&2, U32>, flags: Ps}
  BstDir{rest: List<&2, U32>, flags: Ps}
  BstBad{}

def bch_cfin(t: List<&2, U32>, flags: Ps) -> Bst:
  match t:
    case Nil{}:
      BstDir{Nil{}, flags}
    case _ <> _:
      BstBad{}

def bch_c(
  is_c: Bool, h: U32, t: List<&2, U32>, list: Bool, extract: Bool,
  to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_c:
    case True{}:
      bch_cfin(t, PWantDir{list, extract, to_stdout, verbose, preserve, strip,
        path, onetop})
    case False{}:
      BstBad{}

def bch_fin(t: List<&2, U32>, flags: Ps) -> Bst:
  match t:
    case Nil{}:
      BstFile{Nil{}, flags}
    case _ <> _:
      BstBad{}

def bch_f(
  is_f: Bool, is_c: Bool, h: U32, t: List<&2, U32>, list: Bool,
  extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_f:
    case True{}:
      bch_fin(t, PWantFile{list, extract, to_stdout, verbose, preserve, strip,
        root, onetop})
    case False{}:
      bch_c(is_c, h, t, list, extract, to_stdout, verbose, preserve, strip,
        path, root, onetop)

def bch_v(
  is_v: Bool, is_f: Bool, is_c: Bool, h: U32, t: List<&2, U32>, list: Bool,
  extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_v:
    case True{}:
      BstGo{t, list, extract, to_stdout, True{}, preserve, strip, path, root,
        onetop}
    case False{}:
      bch_f(is_f, is_c, h, t, list, extract, to_stdout, verbose, preserve,
        strip, path, root, onetop)

def bch_o(
  is_o: Bool, is_v: Bool, is_f: Bool, is_c: Bool, h: U32,
  t: List<&2, U32>, list: Bool, extract: Bool, to_stdout: Bool,
  verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_o:
    case True{}:
      BstGo{t, False{}, True{}, True{}, verbose, preserve, strip, path, root,
        onetop}
    case False{}:
      bch_v(is_v, is_f, is_c, h, t, list, extract, to_stdout, verbose,
        preserve, strip, path, root, onetop)

def bch_p(
  is_p: Bool, is_o: Bool, is_v: Bool, is_f: Bool, is_c: Bool, h: U32,
  t: List<&2, U32>, list: Bool, extract: Bool, to_stdout: Bool,
  verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_p:
    case True{}:
      BstGo{t, list, extract, to_stdout, verbose, True{}, strip, path, root,
        onetop}
    case False{}:
      bch_o(is_o, is_v, is_f, is_c, h, t, list, extract, to_stdout, verbose,
        preserve, strip, path, root, onetop)

def bch_t(
  is_t: Bool, is_p: Bool, is_o: Bool, is_v: Bool, is_f: Bool, is_c: Bool,
  h: U32, t: List<&2, U32>, list: Bool, extract: Bool, to_stdout: Bool,
  verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_t:
    case True{}:
      BstGo{t, True{}, extract, to_stdout, verbose, preserve, strip, path,
        root, onetop}
    case False{}:
      bch_p(is_p, is_o, is_v, is_f, is_c, h, t, list, extract, to_stdout,
        verbose, preserve, strip, path, root, onetop)

def bch(
  is_x: Bool, is_t: Bool, is_p: Bool, is_o: Bool, is_v: Bool, is_f: Bool,
  is_c: Bool, h: U32, t: List<&2, U32>, list: Bool, extract: Bool,
  to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Bst:
  match is_x:
    case True{}:
      BstGo{t, list, True{}, to_stdout, verbose, preserve, strip, path, root,
        onetop}
    case False{}:
      bch_t(is_t, is_p, is_o, is_v, is_f, is_c, h, t, list, extract,
        to_stdout, verbose, preserve, strip, path, root, onetop)

def bundle_run(fuel: Nat, st: Bst) -> Ps:
  match fuel:
    case 0n:
      PBad{}
    case 1n+p:
      match st:
        case BstBad{}:
          PBad{}
        case BstFile{rest, flags}:
          flags
        case BstDir{rest, flags}:
          flags
        case BstGo{rest, list, extract, to_stdout, verbose, preserve, strip,
            path, root, onetop}:
          match rest:
            case Nil{}:
              PStart{list, extract, to_stdout, verbose, preserve, strip, path,
                root, onetop}
            case +h <> +t:
              bundle_run(p,
                bch(U32.is_eq(h, 120), U32.is_eq(h, 116), U32.is_eq(h, 112),
                  U32.is_eq(h, 79), U32.is_eq(h, 118), U32.is_eq(h, 102),
                  U32.is_eq(h, 67), h, t, list, extract, to_stdout, verbose,
                  preserve, strip, path, root, onetop))

def bundle_or_bad(
  rest: List<&2, U32>, list: Bool, extract: Bool, to_stdout: Bool,
  verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Ps:
  match rest:
    case Nil{}:
      PBad{}
    case r:
      bundle_run(64n,
        BstGo{r, list, extract, to_stdout, verbose, preserve, strip, path,
          root, onetop})

def nonopt_path(
  path: Maybe<&2, List<&2, U32>>, tok: List<&2, U32>, list: Bool,
  extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  root: Maybe<&2, List<&2, U32>>, onetop: OneTop
) -> Ps:
  match path:
    case None{}:
      PStart{list, extract, to_stdout, verbose, preserve, strip, Some{tok},
        root, onetop}
    case Some{p}:
      PBad{}

def nonopt(
  isdash: Bool, tok: List<&2, U32>, list: Bool, extract: Bool,
  to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> Ps:
  match isdash:
    case True{}:
      bundle_or_bad(drop_n(1n, tok), list, extract, to_stdout, verbose,
        preserve, strip, path, root, onetop)
    case False{}:
      nonopt_path(path, tok, list, extract, to_stdout, verbose, preserve,
        strip, root, onetop)

def strip_split(
  m: Maybe<&2, U32>, list: Bool, extract: Bool, to_stdout: Bool,
  verbose: Bool, preserve: Bool, path: Maybe<&2, List<&2, U32>>,
  root: Maybe<&2, List<&2, U32>>, onetop: OneTop
) -> Ps:
  match m:
    case Some{n}:
      PStart{list, extract, to_stdout, verbose, preserve, n, path, root,
        onetop}
    case None{}:
      PBad{}

def tag_split(
  tag: Tag, list: Bool, extract: Bool, to_stdout: Bool, verbose: Bool,
  preserve: Bool, strip: U32, path: Maybe<&2, List<&2, U32>>,
  root: Maybe<&2, List<&2, U32>>, onetop: OneTop, +tok: List<&2, U32>
) -> Ps:
  match tag:
    case TTf{}:
      PWantFile{True{}, False{}, to_stdout, verbose, preserve, strip, root,
        onetop}
    case TXf{}:
      PWantFile{False{}, True{}, to_stdout, verbose, preserve, strip, root,
        onetop}
    case TT{}:
      PStart{True{}, extract, to_stdout, verbose, preserve, strip, path,
        root, onetop}
    case TX{}:
      PStart{list, True{}, to_stdout, verbose, preserve, strip, path, root,
        onetop}
    case TF{}:
      PWantFile{list, extract, to_stdout, verbose, preserve, strip, root,
        onetop}
    case TC{}:
      PWantDir{list, extract, to_stdout, verbose, preserve, strip, path,
        onetop}
    case TV{}:
      PStart{list, extract, to_stdout, True{}, preserve, strip, path, root,
        onetop}
    case TP{}:
      PStart{list, extract, to_stdout, verbose, True{}, strip, path, root,
        onetop}
    case TPres{}:
      PStart{list, extract, to_stdout, verbose, True{}, strip, path, root,
        onetop}
    case TO{}:
      PStart{False{}, True{}, True{}, verbose, preserve, strip, path, root,
        onetop}
    case TOneAuto{}:
      PStart{list, extract, to_stdout, verbose, preserve, strip, path, root,
        OtAuto{}}
    case TOneArg{dir}:
      PStart{list, extract, to_stdout, verbose, preserve, strip, path, root,
        OtDir{dir}}
    case TList{}:
      PStart{True{}, extract, to_stdout, verbose, preserve, strip, path,
        root, onetop}
    case TStrip{}:
      strip_split(parse_u32_bytes(drop_n(19n, tok)), list, extract,
        to_stdout, verbose, preserve, path, root, onetop)
    case TBad{}:
      nonopt(starts(tok, bstr("-")), tok, list, extract, to_stdout, verbose,
        preserve, strip, path, root, onetop)

def token_step(
  list: Bool, extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool,
  strip: U32, path: Maybe<&2, List<&2, U32>>,
  root: Maybe<&2, List<&2, U32>>, onetop: OneTop, +tok: List<&2, U32>
) -> Ps:
  tag_split(cls(tok), list, extract, to_stdout, verbose, preserve, strip,
    path, root, onetop, tok)

# ---- scanner --------------------------------------------------------------

def done_root(
  extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  archive: List<&2, U32>, root: Maybe<&2, List<&2, U32>>, onetop: OneTop
) -> IO(Opts):
  IO.pure(Opts, MkOpts{archive, extract, to_stdout, root, onetop, strip,
    verbose, preserve})

def done_path(
  extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool, strip: U32,
  path: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  onetop: OneTop
) -> IO(Opts):
  match path:
    case None{}:
      IO.die(Opts, 2, usage())
    case Some{archive}:
      done_root(extract, to_stdout, verbose, preserve, strip, archive, root,
        onetop)

def done_opts(
  list: Bool, extract: Bool, to_stdout: Bool, verbose: Bool, preserve: Bool,
  strip: U32, path: Maybe<&2, List<&2, U32>>,
  root: Maybe<&2, List<&2, U32>>, onetop: OneTop
) -> IO(Opts):
  match list:
    case True{}:
      done_path(False{}, to_stdout, verbose, preserve, strip, path, root,
        onetop)
    case False{}:
      match extract:
        case True{}:
          done_path(True{}, to_stdout, verbose, preserve, strip, path, root,
            onetop)
        case False{}:
          IO.die(Opts, 2, usage())

def walk(fuel: Nat, ps: Ps, argv: List<&1, List<&2, U32>>) -> IO(Opts):
  match fuel:
    case 0n:
      IO.die(Opts, 2, "btar: argument list too long")
    case 1n+p:
      match ps:
        case PBad{}:
          IO.die(Opts, 2, usage())
        case PDone{list, extract, to_stdout, verbose, preserve, strip, path,
            root, onetop}:
          done_opts(list, extract, to_stdout, verbose, preserve, strip, path,
            root, onetop)
        case PStart{list, extract, to_stdout, verbose, preserve, strip, path,
            root, onetop}:
          match argv:
            case Nil{}:
              walk(p, PDone{list, extract, to_stdout, verbose, preserve,
                strip, path, root, onetop}, Nil{})
            case h <> t:
              walk(p,
                token_step(list, extract, to_stdout, verbose, preserve, strip,
                  path, root, onetop, h), t)
        case PWantFile{list, extract, to_stdout, verbose, preserve, strip,
            root, onetop}:
          match argv:
            case Nil{}:
              IO.die(Opts, 2, usage())
            case h <> t:
              walk(p, PStart{list, extract, to_stdout, verbose, preserve,
                strip, Some{h}, root, onetop}, t)
        case PWantDir{list, extract, to_stdout, verbose, preserve, strip,
            path, onetop}:
          match argv:
            case Nil{}:
              IO.die(Opts, 2, usage())
            case h <> t:
              walk(p, PStart{list, extract, to_stdout, verbose, preserve,
                strip, path, Some{h}, onetop}, t)

# ---- IO -------------------------------------------------------------------

def root_base(root: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match root:
    case Some{p}:
      p
    case None{}:
      bstr(".")

def root_path(root: Maybe<&2, List<&2, U32>>, onetop: OneTop,
  archive: List<&2, U32>) -> List<&2, U32>:
  match onetop:
    case OtNo{}:
      root_base(root)
    case OtAuto{}:
      path_join(root_base(root), one_top_name(archive))
    case OtDir{dir}:
      path_join(root_base(root), dir)

def mk_root(onetop: OneTop, rp: List<&2, U32>) -> IO(Unit):
  match onetop:
    case OtNo{}:
      IO.pure(Unit, Unit{})
    case OtAuto{}:
      IO.try(Unit, Fx.Fs.mkdir_path(rp, 493))
    case OtDir{dir}:
      IO.try(Unit, Fx.Fs.mkdir_path(rp, 493))

# ---- M7 release hardening: caps, version, archive guards ----------------

def dash_guard2(dash: Bool) -> IO(Unit):
  match dash:
    case True{}:
      IO.die(Unit, 2,
        "btar: archive '-' (stdin/stdout) is not supported in v1")
    case False{}:
      IO.pure(Unit, Unit{})

def dash_guard(+archive: List<&2, U32>) -> IO(Unit):
  dash_guard2(beq(archive, bstr("-")))

def arch_after(pr: Result<&1, &1, U32 & String, List<&2, U32>>,
  +archive: List<&2, U32>) -> IO(Unit):
  match pr:
    case Fail{(code, m)}:
      IO.die(Unit, 2, "btar: cannot open archive '" ++
        Wr.bytes_str(archive) ++ "': " ++ m)
    case Done{st}:
      IO.pure(Unit, Unit{})

def arch_open_guard(+archive: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- dash_guard(archive)
    pr : Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.stat_path(archive)
    arch_after(pr, archive)

# ---- M5 gzip plumbing --------------------------------------------------

def gz_is_magic(bs: List<&2, U32>) -> Bool:
  match bs:
    case 31 <> rest:
      match rest:
        case 139 <> t:
          True{}
        case _ <> _:
          False{}
        case Nil{}:
          False{}
    case _ <> _:
      False{}
    case Nil{}:
      False{}

def rw_after(pr: File & Result<&1, &1, U32 & String, Unit>) ->
  IO(File & Gzio.Dr):
  (f, r) = pr
  match r:
    case Done{u}:
      IO.pure(File & Gzio.Dr, (f, Gzio.DrNone{}))
    case Fail{(code, msg)}:
      IO.die(File & Gzio.Dr, 2, "btar: seek: " ++ msg)

# Gzip input: the decoder runs in a forked pump feeding a pipe (src/gzio.bend).
def gz_started(pr: File & Result<&1, &1, U32 & String, Unit>) ->
  IO(File & Gzio.Dr):
  (f, r) = pr
  match r:
    case Done{u}:
      Gzio.inflate_open(f)
    case Fail{(code, msg)}:
      IO.die(File & Gzio.Dr, 2, "btar: seek: " ++ msg)

def gz_inflate(a: File) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, Unit> <- Fx.Stream.rewind(a)
    gz_started(pr)

def gz_keep(a: File) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Stream.rewind(a)
    rw_after(pr)

def gz_no(a: File, given: Bool) -> IO(File & Gzio.Dr):
  match given:
    case True{}:
      IO.die(File & Gzio.Dr, 2, "btar: -z given but the input is not gzip data")
    case False{}:
      gz_keep(a)

def gz_yes(yes: Bool, a: File, given: Bool) -> IO(File & Gzio.Dr):
  match yes:
    case True{}:
      gz_inflate(a)
    case False{}:
      gz_no(a, given)

def gz_magic_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, given: Bool
) -> IO(File & Gzio.Dr):
  (a, r) = pr
  match r:
    case Done{bs}:
      gz_yes(gz_is_magic(bs), a, given)
    case Fail{(code, msg)}:
      gz_no(a, given)

def gz_prepare(a: File, given: Bool) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Stream.read_exact(a, 2)
    gz_magic_after(pr, given)

# ---- M5 create gzip ----------------------------------------------------

# ---- M5 gzip CLI flag --------------------------------------------------

def chas_z(fuel: Nat, xs: List<&2, U32>, found: Bool) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match xs:
        case Nil{}:
          found
        case +h <> t:
          chas_z(p, t, Bool.or(found, U32.is_eq(h, 122)))

def tok_is_z2(isdash: Bool, +tok: List<&2, U32>) -> Bool:
  match isdash:
    case True{}:
      chas_z(256n, tok, False{})
    case False{}:
      False{}

def tok_is_z(+tok: List<&2, U32>) -> Bool:
  tok_is_z2(starts(tok, bstr("-")), tok)

def has_z(fuel: Nat, found: Bool,
  argv: List<&1, List<&2, U32>>) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match found:
        case True{}:
          True{}
        case False{}:
          match argv:
            case Nil{}:
              False{}
            case h <> t:
              has_z(p, tok_is_z(h), t)

def drop_z_ch(is_z: Bool, h: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match is_z:
    case True{}:
      acc
    case False{}:
      B.list_cat(acc, h <> Nil{})

def drop_z(fuel: Nat, xs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case +h <> t:
          drop_z(p, t, drop_z_ch(U32.is_eq(h, 122), h, acc))

type FZ is Data:
  FZKeep{tok: List<&2, U32>}
  FZNew{tok: List<&2, U32>}
  FZDrop{}

def fz_short3(empty: Bool, out: List<&2, U32>) -> FZ:
  match empty:
    case True{}:
      FZDrop{}
    case False{}:
      FZNew{out}

def blen2(xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def fz_short2(dash: Bool, +out: List<&2, U32>) -> FZ:
  match dash:
    case True{}:
      FZDrop{}
    case False{}:
      fz_short3(U32.is_eq(U32.from_nat(blen2(out)), 0), out)

def fz_short(+out: List<&2, U32>) -> FZ:
  fz_short2(beq(out, bstr("-")), out)

def fz_tok3(isdash: Bool, +tok: List<&2, U32>) -> FZ:
  match isdash:
    case True{}:
      fz_short(drop_z(256n, tok, Nil{}))
    case False{}:
      FZKeep{tok}

def fz_tok2(long: Bool, +tok: List<&2, U32>) -> FZ:
  match long:
    case True{}:
      FZDrop{}
    case False{}:
      fz_tok3(starts(tok, bstr("-")), tok)

def fz_tok(+tok: List<&2, U32>) -> FZ:
  fz_tok2(beq(tok, bstr("--gzip")), tok)

def untag(fuel: Nat, xs: List<&1, FZ>) ->
  List<&1, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case FZDrop{}:
              untag(p, t)
            case FZKeep{tok}:
              tok <> untag(p, t)
            case FZNew{tok}:
              tok <> untag(p, t)

def tag_z(fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, FZ>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case h <> t:
          fz_tok(h) <> tag_z(p, t)

def filter_z(+fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  untag(fuel, tag_z(fuel, argv))

# ---- M6 --sort=name option ---------------------------------------------

type SOpt is Data:
  SKeep{tok: List<&2, U32>}
  SDrop{}

def s_token2(hit: Bool, +tok: List<&2, U32>) -> SOpt:
  match hit:
    case True{}:
      SDrop{}
    case False{}:
      SKeep{tok}

def s_token(+tok: List<&2, U32>) -> SOpt:
  s_token2(beq(tok, bstr("--sort=name")), tok)

def tag_s(fuel: Nat, argv: List<&1, List<&2, U32>>) -> List<&1, SOpt>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case h <> t:
          s_token(h) <> tag_s(p, t)

def untag_s(fuel: Nat, xs: List<&1, SOpt>) ->
  List<&1, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case SDrop{}:
              untag_s(p, t)
            case SKeep{tok}:
              tok <> untag_s(p, t)

def strip_sort(+fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  untag_s(fuel, tag_s(fuel, argv))

def any_drop(fuel: Nat, xs: List<&1, SOpt>) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match xs:
        case Nil{}:
          False{}
        case h <> t:
          match h:
            case SDrop{}:
              True{}
            case SKeep{tok}:
              any_drop(p, t)

# ---- M7 --version -------------------------------------------------------

def tok_version(+tok: List<&2, U32>) -> Bool:
  Bool.or(beq(tok, bstr("--version")), beq(tok, bstr("-V")))

def tag_ver(fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, Bool>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case h <> t:
          tok_version(h) <> tag_ver(p, t)

def any_true(fuel: Nat, xs: List<&1, Bool>) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match xs:
        case Nil{}:
          False{}
        case h <> t:
          match h:
            case True{}:
              True{}
            case False{}:
              any_true(p, t)

def has_version(+fuel: Nat, argv: List<&1, List<&2, U32>>) -> Bool:
  any_true(fuel, tag_ver(fuel, argv))

def tok_dash(+tok: List<&2, U32>) -> Bool:
  beq(tok, bstr("-"))

def tag_dash(fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, Bool>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case h <> t:
          tok_dash(h) <> tag_dash(p, t)

def has_dash(+fuel: Nat, argv: List<&1, List<&2, U32>>) -> Bool:
  any_true(fuel, tag_dash(fuel, argv))

def drop_prog(xs: List<&1, List<&2, U32>>) -> List<&1, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case _ <> t:
      t

# ---- M4 create mode (-cf) ------------------------------------------------

type COpts is Data:
  MkCOpts{
    archive: List<&2, U32>,
    root: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }

type CK is Data:
  CKGo{
    archive: Maybe<&2, List<&2, U32>>,
    root: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }
  CKWantFile{
    root: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }
  CKWantDir{
    archive: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }
  CKDone{
    archive: Maybe<&2, List<&2, U32>>,
    root: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }
  CKBad{}

# 0 = not create, 1 = create, 2 = bad

def chas_c(fuel: Nat, xs: List<&2, U32>, found: Bool) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match xs:
        case Nil{}:
          found
        case +h <> t:
          chas_c(p, t, Bool.or(found, U32.is_eq(h, 99)))

def tok_has_c2(isdash: Bool, tok: List<&2, U32>) -> Bool:
  match isdash:
    case True{}:
      chas_c(256n, tok, False{})
    case False{}:
      False{}

def tok_has_c(+tok: List<&2, U32>) -> Bool:
  tok_has_c2(Bool.and(starts(tok, bstr("-")),
    Bool.not(starts(tok, bstr("--")))), tok)

def scan_create(fuel: Nat, found: Bool,
  argv: List<&1, List<&2, U32>>) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match found:
        case True{}:
          True{}
        case False{}:
          match argv:
            case Nil{}:
              False{}
            case h <> t:
              scan_create(p, tok_has_c(h), t)

# token codes: 1 -f, 2 -C, 3 -v, 4 -p, 5 --format=ustar,
# 6 --format=pax, 7 bundled, 8 positional, 9 bad

def cusage() -> String:
  "usage: btar -cf|-rf|-uf ARCHIVE [PATH...] [-C DIR] [-v] [-p] [-z] " ++
  "[--sort=name] [--format=ustar|pax] [--no-recursion]\n" ++
  "       [--exclude=PATTERN] [--exclude-from=FILE] [--version]\n" ++
  "-r appends and -u updates an uncompressed archive (no -z).\n" ++
  "gzip is streamed (no size caps). - is not supported as an archive."

def cpath_def2(empty: Bool, paths: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match empty:
    case True{}:
      bstr(".") <> Nil{}
    case False{}:
      paths

def clen2(xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      (1n + clen2(t) : Nat)

def cpath_default(+paths: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  cpath_def2(U32.is_eq(U32.from_nat(clen2(paths)), 0), paths)

def cdone(archive: Maybe<&2, List<&2, U32>>, root: Maybe<&2, List<&2, U32>>,
  verbose: Bool, preserve: Bool, fmt: U32,
  paths: List<&2, List<&2, U32>>) -> IO(COpts):
  match archive:
    case None{}:
      IO.die(COpts, 2, cusage())
    case Some{ar}:
      IO.pure(COpts, MkCOpts{ar, root, verbose, preserve, fmt, paths})

def ck_root(st: CK) -> Maybe<&2, List<&2, U32>>:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      root
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      root
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      None{}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      root
    case CKBad{}:
      None{}

def ck_verbose(st: CK) -> Bool:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      verbose
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      verbose
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      verbose
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      verbose
    case CKBad{}:
      False{}

def ck_preserve(st: CK) -> Bool:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      preserve
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      preserve
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      preserve
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      preserve
    case CKBad{}:
      False{}

def ck_fmt(st: CK) -> U32:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      fmt
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      fmt
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      fmt
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      fmt
    case CKBad{}:
      0

def ck_paths(st: CK) -> List<&2, List<&2, U32>>:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      paths
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      paths
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      paths
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      paths
    case CKBad{}:
      Nil{}

def ck_fmt_set(st: CK, fmt: U32) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt0, paths}:
      CKGo{archive, root, verbose, preserve, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt0, paths}:
      CKWantFile{root, verbose, preserve, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt0, paths}:
      CKWantDir{archive, verbose, preserve, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt0, paths}:
      CKDone{archive, root, verbose, preserve, fmt, paths}
    case CKBad{}:
      CKBad{}

def ck_verbose_set(st: CK) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      CKGo{archive, root, True{}, preserve, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      CKWantFile{root, True{}, preserve, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      CKWantDir{archive, True{}, preserve, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      CKDone{archive, root, True{}, preserve, fmt, paths}
    case CKBad{}:
      CKBad{}

def ck_to_go2(st: CK) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      CKGo{archive, root, verbose, preserve, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      CKGo{None{}, root, verbose, preserve, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      CKGo{archive, None{}, verbose, preserve, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      CKDone{archive, root, verbose, preserve, fmt, paths}
    case CKBad{}:
      CKBad{}

def ck_to_go(st: CK) -> CK:
  ck_to_go2(st)

# Bundled create flags: c (create), v, p, f (must be last), C (must be last).

def ck_dir_from(st: CK) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      CKWantDir{archive, verbose, preserve, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      CKWantDir{None{}, verbose, preserve, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      CKWantDir{archive, verbose, preserve, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      CKWantDir{archive, verbose, preserve, fmt, paths}
    case CKBad{}:
      CKBad{}

def cbund_dir(t: List<&2, U32>, st: CK) -> CK:
  match t:
    case Nil{}:
      ck_dir_from(st)
    case _ <> _:
      CKBad{}

def ck_file_from(st: CK) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      CKWantFile{root, verbose, preserve, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      CKWantFile{root, verbose, preserve, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      CKWantFile{None{}, verbose, preserve, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      CKWantFile{root, verbose, preserve, fmt, paths}
    case CKBad{}:
      CKBad{}

def cbund_fin(t: List<&2, U32>, st: CK) -> CK:
  match t:
    case Nil{}:
      ck_file_from(st)
    case _ <> _:
      CKBad{}

def ck_preserve_set(st: CK) -> CK:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      CKGo{archive, root, verbose, True{}, fmt, paths}
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      CKWantFile{root, verbose, True{}, fmt, paths}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      CKWantDir{archive, verbose, True{}, fmt, paths}
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      CKDone{archive, root, verbose, True{}, fmt, paths}
    case CKBad{}:
      CKBad{}

def cbund(fuel: Nat, rest: List<&2, U32>, st: CK) -> CK:
  match fuel:
    case 0n:
      CKBad{}
    case 1n+p:
      match rest:
        case Nil{}:
          ck_to_go(st)
        case +h <> t:
          match h:
            case 99:
              cbund(p, t, st)
            case 118:
              cbund(p, t, ck_verbose_set(st))
            case 112:
              cbund(p, t, ck_preserve_set(st))
            case 102:
              cbund_fin(t, st)
            case 67:
              cbund_dir(t, st)
            case _:
              CKBad{}

def ck_archive(st: CK) -> Maybe<&2, List<&2, U32>>:
  match st:
    case CKGo{archive, root, verbose, preserve, fmt, paths}:
      archive
    case CKWantFile{root, verbose, preserve, fmt, paths}:
      None{}
    case CKWantDir{archive, verbose, preserve, fmt, paths}:
      archive
    case CKDone{archive, root, verbose, preserve, fmt, paths}:
      archive
    case CKBad{}:
      None{}

def app_pl(xs: List<&2, List<&2, U32>>,
  ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> app_pl(t, ys)

def one_p(tok: List<&2, U32>) -> List<&2, List<&2, U32>>:
  tok <> Nil{}

def cpaths_add(paths: List<&2, List<&2, U32>>, tok: List<&2, U32>) ->
  List<&2, List<&2, U32>>:
  app_pl(paths, one_p(tok))

def cpos(archive: Maybe<&2, List<&2, U32>>, +st: CK,
  tok: List<&2, U32>) -> CK:
  match archive:
    case Some{a}:
      CKGo{Some{a}, ck_root(st), ck_verbose(st), ck_preserve(st),
        ck_fmt(st), cpaths_add(ck_paths(st), tok)}
    case None{}:
      CKGo{Some{tok}, ck_root(st), ck_verbose(st), ck_preserve(st),
        ck_fmt(st), ck_paths(st)}

def cstep(code: U32, +st: CK, tok: List<&2, U32>) -> CK:
  match code:
    case 1:
      CKWantFile{ck_root(st), ck_verbose(st), ck_preserve(st), ck_fmt(st),
        ck_paths(st)}
    case 2:
      CKWantDir{ck_archive(st), ck_verbose(st), ck_preserve(st), ck_fmt(st),
        ck_paths(st)}
    case 3:
      ck_verbose_set(st)
    case 4:
      ck_preserve_set(st)
    case 5:
      ck_fmt_set(st, 1)
    case 6:
      ck_fmt_set(st, 2)
    case 7:
      cbund(256n, drop_n(1n, tok), st)
    case 8:
      cpos(ck_archive(st), st, tok)
    case _:
      CKBad{}

def ifc(c: Bool, t: Unit -> U32, f: Unit -> U32) -> U32:
  match c:
    case True{}:
      t(Unit{})
    case False{}:
      f(Unit{})

def ctok9(+tok: List<&2, U32>) -> U32:
  ifc(starts(tok, bstr("-")), u => 7, u => 8)

def ctok8(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("--format=pax")), u => 6, u => ctok9(tok))

def ctok7(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("--format=ustar")), u => 5, u => ctok8(tok))

def ctok6(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("-f")), u => 1, u => ctok7(tok))

def ctok5(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("-p")), u => 4, u => ctok6(tok))

def ctok4(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("-v")), u => 3, u => ctok5(tok))

def ctok3(+tok: List<&2, U32>) -> U32:
  ifc(beq(tok, bstr("-C")), u => 2, u => ctok4(tok))

def ctok(+tok: List<&2, U32>) -> U32:
  ctok3(tok)

def cscan(fuel: Nat, st: CK, argv: List<&1, List<&2, U32>>) -> IO(COpts):
  match fuel:
    case 0n:
      IO.die(COpts, 2, "btar: argument list too long")
    case 1n+p:
      match st:
        case CKBad{}:
          IO.die(COpts, 2, cusage())
        case CKDone{archive, root, verbose, preserve, fmt, paths}:
          cdone(archive, root, verbose, preserve, fmt, paths)
        case CKWantFile{root, verbose, preserve, fmt, paths}:
          match argv:
            case Nil{}:
              IO.die(COpts, 2, cusage())
            case h <> t:
              cscan(p, CKGo{Some{h}, root, verbose, preserve, fmt, paths}, t)
        case CKWantDir{archive, verbose, preserve, fmt, paths}:
          match argv:
            case Nil{}:
              IO.die(COpts, 2, cusage())
            case h <> t:
              cscan(p, CKGo{archive, Some{h}, verbose, preserve, fmt, paths},
                t)
        case CKGo{archive, root, verbose, preserve, fmt, paths}:
          match argv:
            case Nil{}:
              cscan(p, CKDone{archive, root, verbose, preserve, fmt, paths},
                Nil{})
            case +h <> t:
              cscan(p, cstep(ctok(h), st, h), t)

def ops_or_dot(paths: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match paths:
    case Nil{}:
      bstr(".") <> Nil{}
    case _ <> _:
      paths

# The archive file's identity keeps it out of its own archive (GNU behavior).
def cp_go(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  rootb: List<&2, U32>, ents: List<&2, Wr.Ent>, cfg: Wr.WCfg) -> IO(Unit):
  (a, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: " ++ msg)
    case Done{st}:
      do IO<Unit>:
        w : Bool <- Wr.write_to(a, Wr.selfid_of(st), rootb, ents, cfg)
        Wr.exit_w(w)

# -czf: the tar writer runs in a fork and feeds a pipe; the main computation
# compresses it (segments in parallel) into the archive file.
def cg_run(pp: File & File, selfid: List<&2, U32>, out: File,
  rootb: List<&2, U32>, ents: List<&2, Wr.Ent>, cfg: Wr.WCfg) -> IO(Unit):
  (r, w) = pp
  do IO<Unit>:
    ch : Chan(Bool) <- IO.fork(Bool,
      Wr.write_to(w, selfid, rootb, ents, cfg))
    u : Unit <- Gzio.deflate_pump(r, out)
    warned : Bool <- IO.join(Bool, ch)
    Wr.exit_w(warned)

def cg_go(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  pp: File & File, rootb: List<&2, U32>, ents: List<&2, Wr.Ent>,
  cfg: Wr.WCfg) -> IO(Unit):
  (out, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: " ++ msg)
    case Done{st}:
      cg_run(pp, Wr.selfid_of(st), out, rootb, ents, cfg)

def create_gz(+rootb: List<&2, U32>, archive: List<&2, U32>,
  +cfg: Wr.WCfg, +paths: List<&2, List<&2, U32>>, wo: Wr.Wo) ->
  IO(Unit):
  do IO<Unit>:
    +arch : List<&2, U32> = archive
    g : Unit <- dash_guard(arch)
    u : Unit <- Wr.preflight(rootb, ops_or_dot(paths))
    ents : List<&2, Wr.Ent> <- Wr.collect(rootb, ops_or_dot(paths), wo)
    out : File <- IO.try(File, File.open_bytes(arch, "w"))
    pp : File & File <- IO.try(File & File, Fx.Fs.pipe())
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.fstatx(out)
    cg_go(pr, pp, rootb, ents, cfg)

def create_plain(+rootb: List<&2, U32>, archive: List<&2, U32>,
  +cfg: Wr.WCfg, +paths: List<&2, List<&2, U32>>, wo: Wr.Wo) ->
  IO(Unit):
  do IO<Unit>:
    +arch : List<&2, U32> = archive
    g : Unit <- dash_guard(arch)
    u : Unit <- Wr.preflight(rootb, ops_or_dot(paths))
    ents : List<&2, Wr.Ent> <- Wr.collect(rootb, ops_or_dot(paths), wo)
    a : File <- IO.try(File, File.open_bytes(arch, "w"))
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.fstatx(a)
    cp_go(pr, rootb, ents, cfg)

def cgate_gz(gz: Bool, rootb: List<&2, U32>, archive: List<&2, U32>,
  +cfg: Wr.WCfg, +paths: List<&2, List<&2, U32>>, wo: Wr.Wo) -> IO(Unit):
  match gz:
    case True{}:
      create_gz(rootb, archive, cfg, paths, wo)
    case False{}:
      create_plain(rootb, archive, cfg, paths, wo)

def c_root_bytes(root: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match root:
    case Some{p}:
      p
    case None{}:
      bstr(".")

def run_create(o: COpts, gz: Bool, wo: Wr.Wo) -> IO(Unit):
  match o:
    case MkCOpts{archive, root, verbose, preserve, fmt, paths}:
      cgate_gz(gz, c_root_bytes(root), archive,
        Wr.MkCfg{fmt, preserve, verbose}, paths, wo)

# ---- v1.2 append / update (-r / -u) -------------------------------------

# Bits: 1 = -r / --append seen, 2 = -u / --update seen (letters only in
# single-dash bundles).
def chas_ch(fuel: Nat, xs: List<&2, U32>, found: Bool, +ch: U32) -> Bool:
  match fuel:
    case 0n:
      found
    case 1n+p:
      match xs:
        case Nil{}:
          found
        case +h <> t:
          chas_ch(p, t, Bool.or(found, U32.is_eq(h, ch)), ch)

def ru_bits2(single: Bool, +tok: List<&2, U32>) -> U32:
  match single:
    case True{}:
      U32.or(Bool.pick(U32, chas_ch(256n, tok, False{}, 114), 1, 0),
        Bool.pick(U32, chas_ch(256n, tok, False{}, 117), 2, 0))
    case False{}:
      0

def ru_bits(+tok: List<&2, U32>) -> U32:
  U32.or(ru_bits2(Bool.and(starts(tok, bstr("-")),
    Bool.not(starts(tok, bstr("--")))), tok),
    U32.or(Bool.pick(U32, beq(tok, bstr("--append")), 1, 0),
      Bool.pick(U32, beq(tok, bstr("--update")), 2, 0)))

def ru_scan(fuel: Nat, acc: U32, argv: List<&1, List<&2, U32>>) -> U32:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match argv:
        case Nil{}:
          acc
        case h <> t:
          ru_scan(p, U32.or(acc, ru_bits(h)), t)

def drop_ru(fuel: Nat, xs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match xs:
        case Nil{}:
          acc
        case +h <> t:
          drop_ru(p, t, drop_z_ch(
            Bool.or(U32.is_eq(h, 114), U32.is_eq(h, 117)), h, acc))

def ru_tok2(single: Bool, +tok: List<&2, U32>) -> FZ:
  match single:
    case True{}:
      fz_short(drop_ru(256n, tok, Nil{}))
    case False{}:
      FZKeep{tok}

def ru_tok3(long: Bool, +tok: List<&2, U32>) -> FZ:
  match long:
    case True{}:
      FZDrop{}
    case False{}:
      ru_tok2(Bool.and(starts(tok, bstr("-")),
        Bool.not(starts(tok, bstr("--")))), tok)

def ru_tok(+tok: List<&2, U32>) -> FZ:
  ru_tok3(Bool.or(beq(tok, bstr("--append")), beq(tok, bstr("--update"))),
    tok)

def tag_ru(fuel: Nat, argv: List<&1, List<&2, U32>>) -> List<&1, FZ>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case h <> t:
          ru_tok(h) <> tag_ru(p, t)

# -r / -u letters are consumed here; the rest of the cluster (-rf, -uvf) goes
# through the create option parser.
def filter_ru(+fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  untag(fuel, tag_ru(fuel, argv))

def ap_pos(pr: File & Result<&1, &1, U32 & String, U32>,
  selfid: List<&2, U32>, rootb: List<&2, U32>, ents: List<&2, Wr.Ent>,
  cfg: Wr.WCfg, start: U32) -> IO(Unit):
  (a, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: seek archive: " ++ msg)
    case Done{pos}:
      do IO<Unit>:
        w : Bool <- Wr.write_from(a, selfid, rootb, ents, cfg, start)
        Wr.exit_w(w)

def ap_seek(ok: Bool, a: File, +end: U32, selfid: List<&2, U32>,
  rootb: List<&2, U32>, ents: List<&2, Wr.Ent>, cfg: Wr.WCfg) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        pr : File & Result<&1, &1, U32 & String, U32> <-
          Fx.Stream.seek(a, end, 0)
        ap_pos(pr, selfid, rootb, ents, cfg, end)
    case False{}:
      IO.die(Unit, 2, "btar: archive changed while appending (shorter than " ++
        "its scanned end)")

def ap_write(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  +end: U32, rootb: List<&2, U32>, ents: List<&2, Wr.Ent>,
  cfg: Wr.WCfg) -> IO(Unit):
  (a, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: " ++ msg)
    case Done{+st}:
      ap_seek(U32.is_ge(Wr.st_size(st), end), a, end, Wr.selfid_of(st),
        rootb, ents, cfg)

# Order matters: operand validation, archive scan and manifest collection all
# finish before the archive is opened for writing, so any error leaves it
# untouched.
def append_go(+rootb: List<&2, U32>, archive: List<&2, U32>, +cfg: Wr.WCfg,
  +paths: List<&2, List<&2, U32>>, +wo: Wr.Wo, upd: Bool) -> IO(Unit):
  do IO<Unit>:
    +arch : List<&2, U32> = archive
    g : Unit <- dash_guard(arch)
    u : Unit <- Wr.preflight(rootb, paths)
    +sc : Ap.Scan <- Ap.scan(arch, upd)
    ents : List<&2, Wr.Ent> <- Wr.collect(rootb, paths,
      Wr.wo_tab(wo, Ap.scan_tab(sc)))
    rr : Result<&1, &1, U32 & String, File> <- Fx.Fs.open_rw(arch)
    a : File <- Wr.rpair(rr)
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Fs.fstatx(a)
    ap_write(pr, Ap.scan_end(sc), rootb, ents, cfg)

def run_append(o: COpts, wo: Wr.Wo, upd: Bool) -> IO(Unit):
  match o:
    case MkCOpts{archive, root, verbose, preserve, fmt, paths}:
      append_go(c_root_bytes(root), archive,
        Wr.MkCfg{fmt, preserve, verbose}, paths, wo, upd)

def ru_parse(wo: Wr.Wo, upd: Bool,
  argv: List<&1, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    o : COpts <- cscan(2048n,
      CKGo{None{}, None{}, False{}, False{}, 0, Nil{}}, argv)
    run_append(o, wo, upd)

def ru_gate(create: Bool, gz: Bool, wo: Wr.Wo, mode: U32,
  argv: List<&1, List<&2, U32>>) -> IO(Unit):
  match create:
    case True{}:
      IO.die(Unit, 2, "btar: you may not specify more than one of -c, -r, -u")
    case False{}:
      match gz:
        case True{}:
          IO.die(Unit, 2, "btar: cannot update a compressed archive " ++
            "(-r/-u do not work with -z)")
        case False{}:
          match mode:
            case 3:
              IO.die(Unit, 2, "btar: you may not specify both -r and -u")
            case _:
              ru_parse(wo, U32.is_eq(mode, 2), argv)

def run_reader(ad: File & Gzio.Dr, rp: List<&2, U32>, s: File,
  cfg: R.Cfg) -> IO(Unit):
  (a2, d) = ad
  do IO<Unit>:
    r : Unit <- R.run(a2, rp, s, cfg, 134217728n)
    Gzio.inflate_finish(d)

def run_opts(o: Opts, gz: Bool, exc: List<&2, List<&2, U32>>) -> IO(Unit):
  match o:
    case MkOpts{+archive, extract, to_stdout, root, +onetop, strip,
        verbose, preserve}:
      do IO<Unit>:
        +arch : List<&2, U32> = archive
        g : Unit <- arch_open_guard(arch)
        a : File <- IO.try(File, File.open_bytes(arch, "r"))
        ad : File & Gzio.Dr <- gz_prepare(a, gz)
        s : File <- IO.try(File, File.open("/dev/null", "w"))
        u : U32 <- Fx.Fs.euid()
        +rp : List<&2, U32> = root_path(root, onetop, arch)
        mk : Unit <- mk_root(onetop, rp)
        run_reader(ad, rp, s, R.MkCfg{extract, strip, verbose, preserve,
          to_stdout, u, False{}, exc})

def main_plain(create: Bool, gz: Bool, wo: Wr.Wo,
  argv: List<&1, List<&2, U32>>) -> IO(Unit):
  match create:
    case True{}:
      do IO<Unit>:
        o : COpts <- cscan(2048n,
          CKGo{None{}, None{}, False{}, False{}, 0, Nil{}}, argv)
        run_create(o, gz, wo)
    case False{}:
      do IO<Unit>:
        o : Opts <- walk(2048n,
          PStart{False{}, False{}, False{}, False{}, False{}, 0, None{},
            None{}, OtNo{}}, argv)
        run_opts(o, gz, Wr.wo_exc(wo))

def main_dispatch(create: Bool, gz: Bool, wo: Wr.Wo, mode: U32,
  argv: List<&1, List<&2, U32>>) -> IO(Unit):
  match mode:
    case 0:
      main_plain(create, gz, wo, argv)
    case _:
      ru_gate(create, gz, wo, mode, argv)

# ---- v1.2 --exclude / --exclude-from / -X / --no-recursion ----------------
#
# These tokens are lifted out of argv before every other scan (a pattern such
# as '*.zip' must not look like -z).  Patterns from the command line are kept
# verbatim; --exclude-from files are split into lines, trailing whitespace is
# stripped and empty lines are dropped (GNU behavior).  Not supported: -X
# inside a bundle (-cXf), --exclude-vcs, --anchored/--wildcards variants.

type Xo is Data:
  XKeep{tok: List<&2, U32>}
  XPat{tok: List<&2, U32>}
  XFrom{tok: List<&2, U32>}
  XNoRec{}
  XDrop{}

def xo_cls(+tok: List<&2, U32>) -> Xo:
  Bool.pick(Xo, starts(tok, bstr("--exclude=")), XPat{drop_n(10n, tok)},
    Bool.pick(Xo, starts(tok, bstr("--exclude-from=")),
      XFrom{drop_n(15n, tok)},
      Bool.pick(Xo, beq(tok, bstr("--no-recursion")), XNoRec{},
        Bool.pick(Xo, Bool.or(beq(tok, bstr("--exclude")),
          Bool.or(beq(tok, bstr("--exclude-from")), beq(tok, bstr("-X")))),
          XDrop{}, XKeep{tok}))))

# want: 0 = none, 1 = next token is a pattern, 2 = next token is a pattern file.
def xo_want(want: U32, +tok: List<&2, U32>) -> U32:
  match want:
    case 0:
      Bool.pick(U32, beq(tok, bstr("--exclude")), 1,
        Bool.pick(U32, Bool.or(beq(tok, bstr("--exclude-from")),
          beq(tok, bstr("-X"))), 2, 0))
    case _:
      0

def xo_tok(want: U32, +tok: List<&2, U32>) -> Xo:
  match want:
    case 0:
      xo_cls(tok)
    case 1:
      XPat{tok}
    case _:
      XFrom{tok}

def tag_x(fuel: Nat, +want: U32, argv: List<&1, List<&2, U32>>) ->
  List<&1, Xo>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match argv:
        case Nil{}:
          Nil{}
        case +h <> t:
          xo_tok(want, h) <> tag_x(p, xo_want(want, h), t)

def keep_x(fuel: Nat, xs: List<&1, Xo>) -> List<&1, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case XKeep{tok}:
              tok <> keep_x(p, t)
            case _:
              keep_x(p, t)

def pats_x(fuel: Nat, xs: List<&1, Xo>) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case XPat{tok}:
              tok <> pats_x(p, t)
            case _:
              pats_x(p, t)

def files_x(fuel: Nat, xs: List<&1, Xo>) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case h <> t:
          match h:
            case XFrom{tok}:
              tok <> files_x(p, t)
            case _:
              files_x(p, t)

def norec_x(fuel: Nat, xs: List<&1, Xo>) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+p:
      match xs:
        case Nil{}:
          False{}
        case h <> t:
          match h:
            case XNoRec{}:
              True{}
            case _:
              norec_x(p, t)

def filter_x(+fuel: Nat, argv: List<&1, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  keep_x(fuel, tag_x(fuel, 0, argv))

def ws_byte(+b: U32) -> Bool:
  Bool.or(U32.is_eq(b, 32), Bool.and(U32.is_ge(b, 9), U32.is_le(b, 13)))

def tw_run(fuel: Nat, xs: List<&2, U32>, run: Nat) -> Nat:
  match fuel:
    case 0n:
      run
    case 1n+p:
      match xs:
        case Nil{}:
          run
        case +h <> t:
          tw_run(p, t, Bool.pick(Nat, ws_byte(h), Nat.add(run, 1n), 0n))

def trim_ws(+xs: List<&2, U32>) -> List<&2, U32>:
  +n = List.length(&2, U32, xs)
  List.take(&2, U32, xs, Nat.sub(n, tw_run(Nat.add(n, 1n), xs, 0n)))

def line_keep(ln: List<&2, U32>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match ln:
    case Nil{}:
      acc
    case h <> t:
      (h <> t) <> acc

def line_flush(+cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  line_keep(trim_ws(B.list_rev(cur, Nil{})), acc)

# One pass over the file bytes; `cur` is the current line, reversed.
def split_nl(fuel: Nat, xs: List<&2, U32>, +cur: List<&2, U32>,
  +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      line_flush(cur, acc)
    case 1n+p:
      match xs:
        case Nil{}:
          line_flush(cur, acc)
        case +h <> t:
          +nl = U32.is_eq(h, 10)
          split_nl(p, t, Bool.pick(List<&2, U32>, nl, Nil{}, h <> cur),
            Bool.pick(List<&2, List<&2, U32>>, nl, line_flush(cur, acc), acc))

def pf_lines(+data: List<&2, U32>) -> List<&2, List<&2, U32>>:
  split_nl(Nat.add(List.length(&2, U32, data), 1n), data, Nil{}, Nil{})

def pf_after(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(List<&2, List<&2, U32>>):
  (f, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: --exclude-from: " ++ msg)
    case Done{data}:
      do IO<List<&2, List<&2, U32>>>:
        u : Unit <- File.close(f)
        IO.pure(List<&2, List<&2, U32>>, pf_lines(data))

def pf_opened(r: Result<&1, &1, U32 & String, File>,
  +path: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match r:
    case Fail{(code, msg)}:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: --exclude-from: cannot open '" ++
        Wr.bytes_str(path) ++ "': " ++ msg)
    case Done{f}:
      do IO<List<&2, List<&2, U32>>>:
        pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
          Fx.Stream.read_file(f)
        pf_after(pr)

def pf_read(+path: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    r : Result<&1, &1, U32 & String, File> <- File.open_bytes(path, "r")
    pf_opened(r, path)

def pf_all(fuel: Nat, files: List<&2, List<&2, U32>>,
  acc: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match fuel:
    case 0n:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: too many --exclude-from files")
    case 1n+p:
      match files:
        case Nil{}:
          IO.pure(List<&2, List<&2, U32>>, acc)
        case h <> t:
          do IO<List<&2, List<&2, U32>>>:
            ls : List<&2, List<&2, U32>> <- pf_read(h)
            pf_all(p, t, app_pl(acc, ls))

def run_main() -> IO(Unit):
  do IO<Unit>:
    a1 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +gz : Bool = has_z(256n, False{}, filter_x(256n, drop_prog(a1)))
    a2 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +sc : Bool = scan_create(256n, False{},
      filter_z(256n, filter_x(256n, drop_prog(a2))))
    a3 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +sortf : Bool = any_drop(256n,
      tag_s(256n, filter_z(256n, filter_x(256n, drop_prog(a3)))))
    a4 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +md : U32 = ru_scan(256n, 0,
      filter_z(256n, filter_x(256n, drop_prog(a4))))
    a6 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +pats : List<&2, List<&2, U32>> = pats_x(256n,
      tag_x(256n, 0, drop_prog(a6)))
    a7 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +files : List<&2, List<&2, U32>> = files_x(256n,
      tag_x(256n, 0, drop_prog(a7)))
    a8 : List<&1, List<&2, U32>> <- IO.args_bytes()
    +nr : Bool = norec_x(256n, tag_x(256n, 0, drop_prog(a8)))
    fl : List<&2, List<&2, U32>> <- pf_all(4096n, files, Nil{})
    a5 : List<&1, List<&2, U32>> <- IO.args_bytes()
    main_dispatch(sc, gz, Wr.MkWo{sortf, U.TNil{}, app_pl(pats, fl), nr}, md,
      filter_ru(256n, strip_sort(256n,
        filter_z(256n, filter_x(256n, drop_prog(a5))))))

def dash_gate(dash: Bool) -> IO(Unit):
  match dash:
    case True{}:
      do IO<Unit>:
        u : Unit <- IO.print_err(
          "btar: '-' (stdin/stdout) is not supported as an archive or " ++
          "operand in v1")
        IO.exit(2)
    case False{}:
      run_main()

def dash_or_run() -> IO(Unit):
  do IO<Unit>:
    a : List<&1, List<&2, U32>> <- IO.args_bytes()
    dash_gate(has_dash(256n, filter_x(256n, drop_prog(a))))

def gz_async(pr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, r) = pr
  match r:
    case Done{u}:
      do IO<Unit>:
        u2 : Unit <- File.close(f)
        IO.pure(Unit, Unit{})
    case Fail{(code, msg)}:
      IO.die(Unit, 2, "btar: write: " ++ msg)

def wbytes_pair(pr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  gz_async(pr)

def version_gate(v: Bool) -> IO(Unit):
  match v:
    case True{}:
      do IO<Unit>:
        u : Unit <- IO.print("btar 1.2.0")
        IO.pure(Unit, Unit{})
    case False{}:
      dash_or_run()

def main() -> IO(Unit):
  do IO<Unit>:
    a0 : List<&1, List<&2, U32>> <- IO.args_bytes()
    version_gate(has_version(256n, drop_prog(a0)))
