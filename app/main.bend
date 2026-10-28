# app/main.bend — btar CLI: option parsing glue and the operation runners.
#
# argv is handled as raw bytes end to end (IO.args_bytes): archive and -C paths never
# round-trip through String.  app/cli.bend parses the command line (GNU syntax, table
# driven); this file maps the parsed options onto create / append / update / list /
# extract / --delete / -A.  Format handling is the pure core in src/, the streaming
# driver is src/read_stream, and every syscall is an effect in effs/.
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
import ../src/rewrite.bend as Rw
import ../src/xform.bend as Xf
import ../src/upd.bend as U
import ../src/gzio.bend as Gzio
import ./cli.bend as Cl
import ./ovparse.bend as Op
import ../src/num.bend as N
import ./cli_types.bend as T
import ./cli_table.bend as Tb

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

# An option cluster (`-xvf`), not the bare `-` that names stdin/stdout.
def dash_opt(+tok: List<&2, U32>) -> Bool:
  Bool.and(starts(tok, bstr("-")), Bool.not(beq(tok, bstr("-"))))

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

# `rewind` fails on a pipe (stdin): the consumed magic bytes are then re-fed
# through a pipe (Gzio.feed_open) instead of seeking back.
def gz_started(pr: File & Result<&1, &1, U32 & String, Unit>,
  magic: List<&2, U32>) -> IO(File & Gzio.Dr):
  (f, r) = pr
  match r:
    case Done{u}:
      Gzio.inflate_open(f)
    case Fail{(code, msg)}:
      do IO<File & Gzio.Dr>:
        p : File <- Gzio.feed_open(f, magic)
        Gzio.inflate_open(p)

def gz_inflate(a: File, magic: List<&2, U32>) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, Unit> <- Fx.Stream.rewind(a)
    gz_started(pr, magic)

def rw_after(pr: File & Result<&1, &1, U32 & String, Unit>,
  magic: List<&2, U32>) -> IO(File & Gzio.Dr):
  (f, r) = pr
  match r:
    case Done{u}:
      IO.pure(File & Gzio.Dr, (f, Gzio.DrNone{}))
    case Fail{(code, msg)}:
      do IO<File & Gzio.Dr>:
        p : File <- Gzio.feed_open(f, magic)
        IO.pure(File & Gzio.Dr, (p, Gzio.DrNone{}))

def gz_keep(a: File, magic: List<&2, U32>) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Stream.rewind(a)
    rw_after(pr, magic)

def gz_no(a: File, given: Bool, magic: List<&2, U32>) -> IO(File & Gzio.Dr):
  match given:
    case True{}:
      IO.die(File & Gzio.Dr, 2, "btar: -z given but the input is not gzip data")
    case False{}:
      gz_keep(a, magic)

def gz_yes(yes: Bool, a: File, given: Bool, magic: List<&2, U32>) ->
  IO(File & Gzio.Dr):
  match yes:
    case True{}:
      gz_inflate(a, magic)
    case False{}:
      gz_no(a, given, magic)

def gz_magic_after(
  pr: File & Result<&1, &1, U32 & String, List<&2, U32>>, given: Bool
) -> IO(File & Gzio.Dr):
  (a, r) = pr
  match r:
    case Done{+bs}:
      gz_yes(gz_is_magic(bs), a, given, bs)
    case Fail{(code, msg)}:
      gz_no(a, given, Nil{})

def gz_prepare(a: File, given: Bool) -> IO(File & Gzio.Dr):
  do IO<File & Gzio.Dr>:
    pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
      Fx.Stream.read_exact(a, 2)
    gz_magic_after(pr, given)

# ---- M5 create gzip ----------------------------------------------------

# ---- M5 gzip CLI flag --------------------------------------------------

type COpts is Data:
  MkCOpts{
    archive: List<&2, U32>,
    root: Maybe<&2, List<&2, U32>>,
    verbose: Bool,
    preserve: Bool,
    fmt: U32,
    paths: List<&2, List<&2, U32>>
  }

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

def app_pl(xs: List<&2, List<&2, U32>>,
  ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> app_pl(t, ys)

def ys_ops(ys: List<&2, List<&2, U32>>) -> List<&1, List<&2, U32>>:
  match ys:
    case Nil{}:
      Nil{}
    case h <> t:
      h <> ys_ops(t)

# -T names become trailing operands (after every option has been lifted out).
def app_ops(xs: List<&1, List<&2, U32>>, ys: List<&2, List<&2, U32>>) ->
  List<&1, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys_ops(ys)
    case h <> t:
      h <> app_ops(t, ys)

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

# `-f -` means stdout when creating and stdin when reading (GNU).
def dash_map(isdash: Bool, std: String, +p: List<&2, U32>) -> List<&2, U32>:
  match isdash:
    case True{}:
      bstr(std)
    case False{}:
      p

def arch_out(+p: List<&2, U32>) -> List<&2, U32>:
  dash_map(beq(p, bstr("-")), "/dev/stdout", p)

def arch_in(+p: List<&2, U32>) -> List<&2, U32>:
  dash_map(beq(p, bstr("-")), "/dev/stdin", p)

# Verbose names go to stdout, or to stderr when the archive itself is on stdout.
def verb_code(+verbose: Bool, +archive: List<&2, U32>) -> U32:
  Bool.pick(U32, verbose, Bool.pick(U32, beq(archive, bstr("-")), 2, 1), 0)

def run_create(o: COpts, gz: Bool, +wo: Wr.Wo) -> IO(Unit):
  match o:
    case MkCOpts{+archive, root, verbose, preserve, fmt, paths}:
      cgate_gz(gz, c_root_bytes(root), arch_out(archive),
        Wr.MkCfg{fmt, preserve, verb_code(verbose, archive), Wr.wo_xf(wo), Wr.wo_ov(wo)}, paths, wo)

# ---- v1.2 append / update (-r / -u) -------------------------------------

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

def run_append(o: COpts, +wo: Wr.Wo, upd: Bool) -> IO(Unit):
  match o:
    case MkCOpts{+archive, root, verbose, preserve, fmt, paths}:
      append_go(c_root_bytes(root), archive,
        Wr.MkCfg{fmt, preserve, verb_code(verbose, archive), Wr.wo_xf(wo), Wr.wo_ov(wo)}, paths, wo, upd)

# -A / --delete: the archive operand is rewritten in place; operands are
# archives (-A) or member names (--delete), taken verbatim.
def rw_pick(del: Bool, +arch: List<&2, U32>,
  ops: List<&2, List<&2, U32>>) -> IO(Unit):
  match del:
    case True{}:
      Rw.delete_go(arch, ops)
    case False{}:
      Rw.concat_go(arch, ops)

def rw_go(del: Bool, +arch: List<&2, U32>,
  ops: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    g : Unit <- dash_guard(arch)
    rw_pick(del, arch, ops)

def rw_run(del: Bool, o: COpts) -> IO(Unit):
  match o:
    case MkCOpts{archive, root, verbose, preserve, fmt, paths}:
      rw_go(del, archive, paths)

def run_reader(ad: File & Gzio.Dr, rp: List<&2, U32>, s: File,
  cfg: R.Cfg) -> IO(Unit):
  (a2, d) = ad
  do IO<Unit>:
    r : Unit <- R.run(a2, rp, s, cfg, 134217728n)
    Gzio.inflate_finish(d)

def run_opts(o: Opts, gz: Bool, exc: List<&2, List<&2, U32>>,
  xf: List<&2, Xf.Xc>, ctl: U32, +mem: List<&2, List<&2, U32>>) -> IO(Unit):
  match o:
    case MkOpts{+archive, extract, to_stdout, root, +onetop, strip,
        verbose, preserve}:
      do IO<Unit>:
        +arch : List<&2, U32> = arch_in(archive)
        g : Unit <- arch_open_guard(arch)
        a : File <- IO.try(File, File.open_bytes(arch, "r"))
        ad : File & Gzio.Dr <- gz_prepare(a, gz)
        s : File <- IO.try(File, File.open("/dev/null", "w"))
        u : U32 <- Fx.Fs.euid()
        +rp : List<&2, U32> = root_path(root, onetop, arch)
        mk : Unit <- mk_root(onetop, rp)
        run_reader(ad, rp, s, R.MkCfg{extract, strip, verbose, preserve,
          to_stdout, u, 0, exc, mem, mem, xf, ctl, 19})

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

# `tr`: strip trailing whitespace (--exclude-from); -T names are taken verbatim.
def line_flush(+tr: Bool, +cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  line_keep(Bool.pick(List<&2, U32>, tr, trim_ws(B.list_rev(cur, Nil{})),
    B.list_rev(cur, Nil{})), acc)

# One pass over the file bytes; `cur` is the current line, reversed.
def split_nl(+tr: Bool, fuel: Nat, xs: List<&2, U32>, +cur: List<&2, U32>,
  +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fuel:
    case 0n:
      line_flush(tr, cur, acc)
    case 1n+p:
      match xs:
        case Nil{}:
          line_flush(tr, cur, acc)
        case +h <> t:
          +nl = U32.is_eq(h, 10)
          split_nl(tr, p, t, Bool.pick(List<&2, U32>, nl, Nil{}, h <> cur),
            Bool.pick(List<&2, List<&2, U32>>, nl, line_flush(tr, cur, acc), acc))

def rev_pl(xs: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev_pl(t, h <> acc)

# Lines come out of split_nl newest-first; restore file order (matters for -T).
def pf_lines(+tr: Bool, +data: List<&2, U32>) -> List<&2, List<&2, U32>>:
  rev_pl(split_nl(tr, Nat.add(List.length(&2, U32, data), 1n), data, Nil{},
    Nil{}), Nil{})

def pf_after(+tr: Bool, +lbl: String, pr: File & Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(List<&2, List<&2, U32>>):
  (f, r) = pr
  match r:
    case Fail{(code, msg)}:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: " ++ lbl ++ ": " ++ msg)
    case Done{data}:
      do IO<List<&2, List<&2, U32>>>:
        u : Unit <- File.close(f)
        IO.pure(List<&2, List<&2, U32>>, pf_lines(tr, data))

def pf_opened(+tr: Bool, +lbl: String, r: Result<&1, &1, U32 & String, File>,
  +path: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match r:
    case Fail{(code, msg)}:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: " ++ lbl ++ ": cannot open '" ++
        Wr.bytes_str(path) ++ "': " ++ msg)
    case Done{f}:
      do IO<List<&2, List<&2, U32>>>:
        pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
          Fx.Stream.read_file(f)
        pf_after(tr, lbl, pr)

def pf_read(+tr: Bool, +lbl: String, +path: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    r : Result<&1, &1, U32 & String, File> <- File.open_bytes(path, "r")
    pf_opened(tr, lbl, r, path)

def pf_all(+tr: Bool, +lbl: String, fuel: Nat, files: List<&2, List<&2, U32>>,
  acc: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match fuel:
    case 0n:
      IO.die(List<&2, List<&2, U32>>, 2, "btar: too many " ++ lbl ++ " files")
    case 1n+p:
      match files:
        case Nil{}:
          IO.pure(List<&2, List<&2, U32>>, acc)
        case h <> t:
          do IO<List<&2, List<&2, U32>>>:
            ls : List<&2, List<&2, U32>> <- pf_read(tr, lbl, h)
            pf_all(tr, lbl, p, t, app_pl(acc, ls))

def xf_one(pe: Xf.Pe) -> IO(Xf.Xc):
  match pe:
    case Xf.PeErr{msg}:
      IO.die(Xf.Xc, 2, "btar: " ++ msg)
    case Xf.PeOk{xc}:
      IO.pure(Xf.Xc, xc)

def xf_all(fuel: Nat, exprs: List<&2, List<&2, U32>>) ->
  IO(List<&2, Xf.Xc>):
  match fuel:
    case 0n:
      IO.die(List<&2, Xf.Xc>, 2, "btar: too many --transform expressions")
    case 1n+p:
      match exprs:
        case Nil{}:
          IO.pure(List<&2, Xf.Xc>, Nil{})
        case e <> t:
          do IO<List<&2, Xf.Xc>>:
            c : Xf.Xc <- xf_one(Xf.parse(e))
            rest : List<&2, Xf.Xc> <- xf_all(p, t)
            IO.pure(List<&2, Xf.Xc>, c <> rest)

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



# ---- command line -> operation -------------------------------------------------------
#
# app/cli.bend parses argv into ordered items (table driven, GNU syntax); this section
# turns them into the arguments of the operation runners above.

def usage() -> String:
  "Usage: btar [OPTION...] [FILE]...\n" ++
  "  btar -c|-r|-u -f ARCHIVE [-C DIR] [FILE...]   create / append / update\n" ++
  "  btar -t|-x -f ARCHIVE [-C DIR] [MEMBER...]    list / extract\n" ++
  "  btar -A -f DEST SRC...   |   btar --delete -f ARCHIVE MEMBER...\n" ++
  "Common: -v -z -O -p -T FILE -X FILE --exclude=PAT --transform=EXPR\n" ++
  "        --strip-components=N --one-top-level[=DIR] --sort=name --format=ustar|pax\n" ++
  "        --no-recursion;  -f - is stdin/stdout.  Other GNU options are parsed and\n" ++
  "        refused with exit status 2 until implemented (docs/format-support.md)."

def die_usage(msg: String) -> IO(Unit):
  IO.die(Unit, 2, "btar: " ++ msg ++
    "\nTry 'btar --help' or 'btar --usage' for more information.")

def print_exit(msg: String) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- IO.print(msg)
    IO.exit(0)

# Operation bits: 1 -A, 2 -c, 4 -d, 8 --delete, 16 -r, 32 -t, 64 -u, 128 -x, 256 --test-label.
def op_bit(+items: List<&2, T.Item>, +id1: U32, +id2: U32, +id3: U32,
  +bit: U32) -> U32:
  Bool.pick(U32, Bool.or(Cl.has_opt(items, id1),
    Bool.or(Cl.has_opt(items, id2), Cl.has_opt(items, id3))), bit, 0)

def op_mask(+items: List<&2, T.Item>) -> U32:
  U32.or(op_bit(items, Tb.o_catenate(), Tb.o_concat(), 0, 1),
  U32.or(op_bit(items, Tb.o_create(), 0, 0, 2),
  U32.or(op_bit(items, Tb.o_diff(), Tb.o_compare(), 0, 4),
  U32.or(op_bit(items, Tb.o_delete(), 0, 0, 8),
  U32.or(op_bit(items, Tb.o_append(), 0, 0, 16),
  U32.or(op_bit(items, Tb.o_list(), 0, 0, 32),
  U32.or(op_bit(items, Tb.o_update(), 0, 0, 64),
  U32.or(op_bit(items, Tb.o_extract(), Tb.o_get(), 0, 128),
    op_bit(items, Tb.o_test_label(), 0, 0, 256)))))))))

def refused_pick(hit: Bool, +id: U32, rest: Maybe<&2, String>) ->
  Maybe<&2, String>:
  match hit:
    case True{}:
      Some{"option '" ++ Tb.long_name(id) ++ "' is not implemented yet"}
    case False{}:
      rest

def first_refused(+items: List<&2, T.Item>) -> Maybe<&2, String>:
  match items:
    case Nil{}:
      None{}
    case T.IOpt{id, _} <> t:
      refused_pick(Tb.refused(id), id, first_refused(t))
    case _ <> t:
      first_refused(t)

def or_default(m: Maybe<&2, List<&2, U32>>, d: List<&2, U32>) ->
  List<&2, U32>:
  match m:
    case Some{v}:
      v
    case None{}:
      d

# --format: 0 default, 1 ustar, 2 pax; anything else is not implemented.
def fmt_code(m: Maybe<&2, List<&2, U32>>) -> U32:
  match m:
    case None{}:
      0
    case Some{+v}:
      Bool.pick(U32, beq(v, bstr("ustar")), 1,
        Bool.pick(U32, Bool.or(beq(v, bstr("pax")), beq(v, bstr("posix"))), 2,
          99))

def strip_of(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, U32>:
  match m:
    case None{}:
      Some{0}
    case Some{v}:
      parse_u32_bytes(v)

def onetop_of(m: Maybe<&2, Maybe<&2, List<&2, U32>>>) -> OneTop:
  match m:
    case None{}:
      OtNo{}
    case Some{a}:
      match a:
        case None{}:
          OtAuto{}
        case Some{d}:
          OtDir{d}

def any_gz(+items: List<&2, T.Item>) -> Bool:
  Bool.or(Cl.has_opt(items, Tb.o_gzip()),
    Bool.or(Cl.has_opt(items, Tb.o_gunzip()),
      Cl.has_opt(items, Tb.o_ungzip())))

# The pieces every runner needs, as one record.
type Run is Data:
  MkRun{mode: U32, gz: Bool, co: COpts, op: Opts, wo: Wr.Wo,
    ops: List<&2, List<&2, U32>>, xf: List<&2, Xf.Xc>, ctl: U32}

def go_gz(gz: Bool, upd_msg: String, k: IO(Unit)) -> IO(Unit):
  match gz:
    case True{}:
      IO.die(Unit, 2, "btar: " ++ upd_msg)
    case False{}:
      k

def run_mode2(mode: U32, gz: Bool, co: COpts, op: Opts, wo: Wr.Wo,
  ops: List<&2, List<&2, U32>>, xf: List<&2, Xf.Xc>, ctl: U32) -> IO(Unit):
  match mode:
    case 2:
      run_create(co, gz, wo)
    case 16:
      go_gz(gz, "cannot update a compressed archive (-r/-u do not work with -z)",
        run_append(co, wo, False{}))
    case 64:
      go_gz(gz, "cannot update a compressed archive (-r/-u do not work with -z)",
        run_append(co, wo, True{}))
    case 1:
      go_gz(gz, "cannot update a compressed archive (-r/-u do not work with -z)",
        rw_run(False{}, co))
    case 8:
      go_gz(gz, "cannot update a compressed archive (-r/-u do not work with -z)",
        rw_run(True{}, co))
    case _:
      run_opts(op, gz, Wr.wo_exc(wo), xf, U32.or(ctl, Bool.pick(U32, U32.is_eq(mode, 4), 256, 0)), ops)

def run_mode(r: Run) -> IO(Unit):
  match r:
    case MkRun{mode, gz, co, op, wo, ops, xf, ctl}:
      run_mode2(mode, gz, co, op, wo, ops, xf, ctl)

def mode_msg(mask: U32) -> String:
  match mask:
    case 0:
      "You must specify one of the '-Acdtrux', '--delete' or '--test-label' options"
    case 80:
      "you may not specify both -r and -u"
    case _:
      "You may not specify more than one '-Acdtrux', '--delete' or '--test-label' option"

def valid_mask(mask: U32) -> Bool:
  match mask:
    case 4:
      True{}
    case 1:
      True{}
    case 2:
      True{}
    case 8:
      True{}
    case 16:
      True{}
    case 32:
      True{}
    case 64:
      True{}
    case 128:
      True{}
    case _:
      False{}

# Extraction control bits: 0-3 overwrite policy (0 replace, 1 keep-old, 2 skip-old,
# 3 keep-newer), 16 --touch (-m).
def ctl_of(+items: List<&2, T.Item>) -> U32:
  U32.or(
    Bool.pick(U32, Cl.has_opt(items, Tb.o_keep_newer_files()), 3,
      Bool.pick(U32, Cl.has_opt(items, Tb.o_skip_old_files()), 2,
        Bool.pick(U32, Cl.has_opt(items, Tb.o_keep_old_files()), 1, 0))),
    U32.or(Bool.pick(U32, Cl.has_opt(items, Tb.o_touch()), 16, 0),
      U32.or(Bool.pick(U32, Cl.has_opt(items, Tb.o_numeric_owner()), 32, 0),
        U32.or(Bool.pick(U32, Cl.has_opt(items, Tb.o_full_time()), 64, 0),
          Bool.pick(U32, Cl.has_opt(items, Tb.o_utc()), 128, 0)))))

def launch4(badfmt: Bool, +n: U32, +fmt: U32, +items: List<&2, T.Item>,
  +mask: U32, +wo: Wr.Wo, +ops: List<&2, List<&2, U32>>,
  +xf: List<&2, Xf.Xc>) -> IO(Unit):
  match badfmt:
    case True{}:
      die_usage("unsupported archive format (--format=ustar or pax)")
    case False{}:
      +arch : List<&2, U32> = or_default(Cl.opt_last(items, Tb.o_file()), bstr("-"))
      +root : Maybe<&2, List<&2, U32>> = Cl.opt_last(items, Tb.o_directory())
      +verbose : Bool = Cl.has_opt(items, Tb.o_verbose())
      +preserve : Bool = Bool.or(Cl.has_opt(items, Tb.o_preserve_permissions()),
        Cl.has_opt(items, Tb.o_same_permissions()))
      +co : COpts = MkCOpts{arch, root, verbose, preserve, fmt, ops}
      +op : Opts = MkOpts{arch, U32.is_eq(mask, 128), Cl.has_opt(items, Tb.o_to_stdout()),
        root, onetop_of(Cl.opt_find(items, Tb.o_one_top_level())), n, verbose,
        preserve}
      run_mode(MkRun{mask, any_gz(items), co, op, wo, ops, xf, ctl_of(items)})

def launch3(strip: Maybe<&2, U32>, +fmt: U32, +items: List<&2, T.Item>,
  +mask: U32, +wo: Wr.Wo, +ops: List<&2, List<&2, U32>>,
  +xf: List<&2, Xf.Xc>) -> IO(Unit):
  match strip:
    case None{}:
      die_usage("invalid --strip-components value")
    case Some{n}:
      launch4(U32.is_eq(fmt, 99), n, fmt, items, mask, wo, ops, xf)

def launch2(+items: List<&2, T.Item>, +mask: U32, +wo: Wr.Wo,
  +ops: List<&2, List<&2, U32>>, +xf: List<&2, Xf.Xc>) -> IO(Unit):
  launch3(strip_of(Cl.opt_last(items, Tb.o_strip_components())),
    fmt_code(Cl.opt_last(items, Tb.o_format())), items, mask, wo, ops, xf)

def rev_cat(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  app_pl(xs, ys)

# ---- header overrides: --owner --group --mode --mtime --numeric-owner ----------------

type Idr is Data:
  MkIdr{id: U32, name: List<&2, U32>}

def ov_id3(r: Result<&1, &1, U32 & String, U32>, name: List<&2, U32>) -> IO(Idr):
  match r:
    case Done{id}:
      IO.pure(Idr, MkIdr{id, name})
    case Fail{_}:
      IO.die(Idr, 2, "btar: invalid owner or group name")

def ov_id2(kind: U32, idv: Op.Idv) -> IO(Idr):
  match idv:
    case Op.IdOk{id, name}:
      IO.pure(Idr, MkIdr{id, name})
    case Op.IdLook{+name}:
      do IO<Idr>:
        r : Result<&1, &1, U32 & String, U32> <- Fx.Fs.name_id(kind, name)
        ov_id3(r, name)
    case Op.IdBad{}:
      IO.die(Idr, 2, "btar: invalid owner or group value")

def ov_id(kind: U32, m: Maybe<&2, List<&2, U32>>) -> IO(Idr):
  match m:
    case None{}:
      IO.pure(Idr, MkIdr{4294967295, Nil{}})
    case Some{v}:
      ov_id2(kind, Op.parse_id(v))

def mt_stat(r: Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(U32):
  match r:
    case Done{st}:
      IO.pure(U32, N.nth(st, 6n))
    case Fail{(code, msg)}:
      IO.die(U32, 2, "btar: --mtime: " ++ msg)

def mt_file(v: List<&2, U32>) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, List<&2, U32>> <- Fx.Fs.stat_path(v)
    mt_stat(r)

# Dates without a zone are local time (GNU): subtract the zone offset at that time.
def mt_local(+t: U32) -> IO(U32):
  do IO<U32>:
    tz : U32 <- Fx.Fs.tzoff(t)
    IO.pure(U32, U32.sub(U32.add(t, 2147483648), tz))

def mt_date(d: Op.Dt, v: List<&2, U32>) -> IO(U32):
  match d:
    case Op.DtOk{t}:
      mt_local(t)
    case Op.DtBad{}:
      mt_file(v)

def mt_epoch(ok: Bool, rest: List<&2, U32>) -> IO(U32):
  match ok:
    case True{}:
      IO.pure(U32, Op.dec_acc(rest, 0))
    case False{}:
      IO.die(U32, 2, "btar: invalid --mtime value")

def mt_str(+v: List<&2, U32>) -> IO(U32):
  match v:
    case 64 <> rest:
      mt_epoch(Op.all_digits(rest), rest)
    case 48 <> _:
      mt_date(Op.parse_date(v), v)
    case 49 <> _:
      mt_date(Op.parse_date(v), v)
    case 50 <> _:
      mt_date(Op.parse_date(v), v)
    case _:
      mt_file(v)

def mt_of(m: Maybe<&2, List<&2, U32>>) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 4294967295)
    case Some{v}:
      mt_str(v)

def mm_of(m: Maybe<&2, List<&2, U32>>) -> Op.Mm:
  match m:
    case None{}:
      Op.MkMm{4294967295, 0, 0, True{}}
    case Some{v}:
      Op.parse_mode(v)

def ov_fin2(ok: Bool, ov: Wr.Ov) -> IO(Wr.Ov):
  match ok:
    case True{}:
      IO.pure(Wr.Ov, ov)
    case False{}:
      IO.die(Wr.Ov, 2, "btar: invalid --mode value")

def ov_fin(o: Idr, g: Idr, mt: U32, nw: U32, fl: U32, mm: Op.Mm, numeric: Bool) ->
  IO(Wr.Ov):
  match o:
    case MkIdr{uid, un}:
      match g:
        case MkIdr{gid, gn}:
          match mm:
            case Op.MkMm{mand, mor, mx, ok}:
              ov_fin2(ok, Wr.MkOv{uid, un, gid, gn, mand, mor, mx, mt, numeric, nw, fl})

# --newer, --newer-mtime and --after-date all reduce to one threshold here (0 = none; the
# oldest of the given dates wins, which is the loosest filter).
def nw_pick(+a: U32, +b: U32) -> U32:
  Bool.pick(U32, U32.is_zero(a), b, Bool.pick(U32, U32.is_zero(b), a, U32.min(a, b)))

def nw_of3(x: U32, y: U32, z: U32) -> IO(U32):
  IO.pure(U32, nw_pick(nw_pick(x, y), z))

def nw_one(m: Maybe<&2, List<&2, U32>>) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 0)
    case Some{v}:
      mt_str(v)

def nw_of(a: Maybe<&2, List<&2, U32>>, b: Maybe<&2, List<&2, U32>>,
  c: Maybe<&2, List<&2, U32>>) -> IO(U32):
  do IO<U32>:
    x : U32 <- nw_one(a)
    y : U32 <- nw_one(b)
    z : U32 <- nw_one(c)
    nw_of3(x, y, z)

# Ov flag bits: 1 --remove-files, 2 --one-file-system, 4 --ignore-failed-read.
def ov_flags(+items: List<&2, T.Item>) -> U32:
  U32.or(Bool.pick(U32, Cl.has_opt(items, Tb.o_remove_files()), 1, 0),
    U32.or(Bool.pick(U32, Cl.has_opt(items, Tb.o_one_file_system()), 2, 0),
      Bool.pick(U32, Cl.has_opt(items, Tb.o_ignore_failed_read()), 4, 0)))

def build_ov(+items: List<&2, T.Item>) -> IO(Wr.Ov):
  do IO<Wr.Ov>:
    o : Idr <- ov_id(0, Cl.opt_last(items, Tb.o_owner()))
    g : Idr <- ov_id(1, Cl.opt_last(items, Tb.o_group()))
    mt : U32 <- mt_of(Cl.opt_last(items, Tb.o_mtime()))
    nw : U32 <- nw_of(Cl.opt_last(items, Tb.o_newer()),
      Cl.opt_last(items, Tb.o_newer_mtime()), Cl.opt_last(items, Tb.o_after_date()))
    ov_fin(o, g, mt, nw, ov_flags(items), mm_of(Cl.opt_last(items, Tb.o_mode())),
      Cl.has_opt(items, Tb.o_numeric_owner()))

# --exclude-vcs / --exclude-backups are fixed exclusion patterns (GNU's lists).
def pat_list(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      bstr(h) <> pat_list(t)

def vcs_pats() -> List<&2, List<&2, U32>>:
  pat_list(["CVS", "RCS", "SCCS", ".git", ".gitignore", ".gitattributes",
    ".gitmodules", ".svn", ".arch-ids", "{arch}", "=RELEASE-ID", "=meta-update",
    "=update", ".bzr", ".bzrignore", ".bzrtags", ".hg", ".hgignore", ".hgtags",
    "_darcs", ".cvsignore"])

def bak_pats() -> List<&2, List<&2, U32>>:
  pat_list(["*~", "#*#", ".#*"])

def auto_pats(+items: List<&2, T.Item>) -> List<&2, List<&2, U32>>:
  app_pl(Bool.pick(List<&2, List<&2, U32>>, Cl.has_opt(items, Tb.o_exclude_vcs()),
    vcs_pats(), Nil{}), Bool.pick(List<&2, List<&2, U32>>,
    Cl.has_opt(items, Tb.o_exclude_backups()), bak_pats(), Nil{}))

def launch(+items: List<&2, T.Item>, mask: U32) -> IO(Unit):
  do IO<Unit>:
    +sortf : Bool = beq(or_default(Cl.opt_last(items, Tb.o_sort()), bstr("none")),
      bstr("name"))
    +fl : List<&2, List<&2, U32>> <- pf_all(True{}, "--exclude-from", 4096n,
      Cl.opt_args(items, Tb.o_exclude_from()), Nil{})
    +tl : List<&2, List<&2, U32>> <- pf_all(False{}, "--files-from", 4096n,
      Cl.opt_args(items, Tb.o_files_from()), Nil{})
    +xf : List<&2, Xf.Xc> <- xf_all(256n,
      Cl.opt_args2(items, Tb.o_transform(), Tb.o_xform()))
    +ov : Wr.Ov <- build_ov(items)
    +wo : Wr.Wo = Wr.MkWo{sortf, U.TNil{},
      app_pl(Cl.opt_args(items, Tb.o_exclude()), app_pl(fl, auto_pats(items))),
      Cl.has_opt(items, Tb.o_no_recursion()), xf, ov}
    +ops : List<&2, List<&2, U32>> = rev_cat(Cl.operands(items), tl)
    launch2(items, mask, wo, ops, xf)

def gate_mode(ok: Bool, +mask: U32, +items: List<&2, T.Item>) -> IO(Unit):
  match ok:
    case True{}:
      launch(items, mask)
    case False{}:
      die_usage(mode_msg(mask))

# -O only makes sense when extracting; it is refused for the archive-writing modes.
def o_conflict(+items: List<&2, T.Item>, mask: U32) -> Bool:
  Bool.and(Cl.has_opt(items, Tb.o_to_stdout()),
    Bool.not(U32.is_zero(U32.and(mask, 89))))

def gate_refused(r: Maybe<&2, String>, +items: List<&2, T.Item>) -> IO(Unit):
  match r:
    case Some{msg}:
      die_usage(msg)
    case None{}:
      gate_mode(Bool.and(valid_mask(op_mask(items)),
        Bool.not(o_conflict(items, op_mask(items)))), op_mask(items), items)

def gate_help(kind: U32, +items: List<&2, T.Item>) -> IO(Unit):
  match kind:
    case 1:
      print_exit("btar 1.3.0")
    case 2:
      print_exit(usage())
    case _:
      gate_refused(first_refused(items), items)

def info_kind(+items: List<&2, T.Item>) -> U32:
  Bool.pick(U32, Cl.has_opt(items, Tb.o_version()), 1,
    Bool.pick(U32, Bool.or(Cl.has_opt(items, Tb.o_help()),
      Cl.has_opt(items, Tb.o_usage())), 2, 0))

def gate_err(e: Maybe<&2, String>, +items: List<&2, T.Item>) -> IO(Unit):
  match e:
    case Some{msg}:
      die_usage(msg)
    case None{}:
      gate_help(info_kind(items), items)

def drop_prog(xs: List<&1, List<&2, U32>>) -> List<&1, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case _ <> t:
      t

def run_items(+items: List<&2, T.Item>) -> IO(Unit):
  gate_err(Cl.first_err(items), items)

def run_main() -> IO(Unit):
  do IO<Unit>:
    a : List<&1, List<&2, U32>> <- IO.args_bytes()
    run_items(Cl.parse(drop_prog(a)))

def main() -> IO(Unit):
  run_main()
