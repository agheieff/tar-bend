# Module: Gzio — effectful glue that streams gzip through pipes.
#
# Reading: a forked decoder pumps `compressed file -> Gunzip -> pipe`; the tar
# reader consumes the pipe's read end like any archive file.  Nothing larger
# than one chunk (256 KiB in, ~256 KiB out) plus the 32 KiB window is ever
# buffered, and there is no size cap.  A gzip error anywhere ends the process
# with exit 2 (IO.die from the decoder).  After the tar reader returns the
# caller drains the pipe (`inflate_finish`) so the whole stream, including the
# final CRC32/ISIZE, is verified.

import Base
import ./gunzip.bend as U
import ./inflate.bend as I
import ./gzcomp.bend as Z
import ../effs/effects.bend as Fx

type PS is Type:
  PsWrite{inp: File, out: File, g: U.GS, olist: List<&2, U32>, st: U.Gst}
  PsRead{inp: File, out: File, g: U.GS}
  PsFeed{inp: File, out: File, g: U.GS, chunk: List<&2, U32>, clen: U32,
    last: Bool}
  PsEnd{inp: File, out: File}
  PsFail{inp: File, out: File, msg: String}

# Drain handle kept by the caller while the tar reader runs.
type Dr is Type:
  DrNone{}
  DrPipe{r: File, ch: Chan(Unit)}

type DS is Type:
  DsRead{r: File}
  DsDone{r: File}
  DsFail{r: File, msg: String}

type PC is Type:
  PcRead{inp: File, out: File, g: Z.GC, got: List<&2, Z.Seg>, k: Nat}
  PcFeed{inp: File, out: File, g: Z.GC, segs: List<&2, Z.Seg>, last: Bool}
  PcWrite{inp: File, out: File, g: Z.GC, outs: List<&2, List<&2, U32>>,
    last: Bool}
  PcEnd{inp: File, out: File}
  PcFail{inp: File, out: File, msg: String}

def chunk_size() -> U32:
  262144

def err_msg(e: I.GzErr) -> String:
  match e:
    case I.GzMagic{}:
      "bad gzip magic"
    case I.GzMethod{}:
      "unsupported gzip method"
    case I.GzHeader{}:
      "bad gzip header"
    case I.GzCorrupt{}:
      "corrupt or invalid gzip data"
    case I.GzSize{}:
      "decompressed data too large"
    case I.GzTruncated{}:
      "truncated gzip stream"
    case I.GzUnsupported{}:
      "unsupported gzip feature"

def after_st(inp: File, out: File, g: U.GS, st: U.Gst) -> PS:
  match st:
    case U.GNeed{}:
      PsRead{inp, out, g}
    case U.GMore{}:
      PsFeed{inp, out, g, Nil{}, 0, False{}}
    case U.GDone{}:
      PsEnd{inp, out}
    case U.GErr{e}:
      PsFail{inp, out, err_msg(e)}

def after_write(pr: File & Result<&1, &1, U32 & String, Unit>, inp: File,
  g: U.GS, st: U.Gst) -> PS:
  (out, r) = pr
  match r:
    case Fail{(c, m)}:
      PsFail{inp, out, "write: " ++ m}
    case Done{u}:
      after_st(inp, out, g, st)

def after_read2(inp: File, out: File, g: U.GS, bs: List<&2, U32>,
  +n: U32) -> PS:
  PsFeed{inp, out, g, bs, n, U32.is_zero(n)}

def after_read(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  out: File, g: U.GS) -> PS:
  (inp, r) = pr
  match r:
    case Fail{(c, m)}:
      PsFail{inp, out, "read: " ++ m}
    case Done{+bs}:
      after_read2(inp, out, g, bs, U32.from_nat(List.length(&2, U32, bs)))

def feed_to_write(inp: File, out: File, r: U.GR) -> PS:
  match r:
    case U.MkGR{g, olist, n, st}:
      PsWrite{inp, out, g, olist, st}

def pump(fuel: Nat, p: PS) -> IO(Unit):
  match fuel:
    case 0n:
      IO.die(Unit, 2, "btar: gzip: internal step limit")
    case 1n+q:
      match p:
        case PsWrite{inp, out, g, olist, st}:
          do IO<Unit>:
            pr : File & Result<&1, &1, U32 & String, Unit> <-
              Fx.Stream.write_bytes(out, olist)
            pump(q, after_write(pr, inp, g, st))
        case PsRead{inp, out, g}:
          do IO<Unit>:
            pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Stream.read_exact(inp, chunk_size())
            pump(q, after_read(pr, out, g))
        case PsFeed{inp, out, g, chunk, clen, last}:
          pump(q, feed_to_write(inp, out, U.gz_run(g, chunk, clen, last)))
        case PsEnd{inp, out}:
          do IO<Unit>:
            u1 : Unit <- File.close(inp)
            u2 : Unit <- File.close(out)
            IO.pure(Unit, Unit{})
        case PsFail{inp, out, msg}:
          IO.die(Unit, 2, "btar: gzip: " ++ msg)

# ---- pipe plumbing ---------------------------------------------------------------

def ds_after2(r: File, +n: Nat) -> DS:
  match n:
    case 0n:
      DsDone{r}
    case _:
      DsRead{r}

def ds_after(pr: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> DS:
  (r, res) = pr
  match res:
    case Fail{(c, m)}:
      DsFail{r, "read: " ++ m}
    case Done{bs}:
      ds_after2(r, List.length(&2, U32, bs))

def drain(fuel: Nat, d: DS) -> IO(Unit):
  match fuel:
    case 0n:
      IO.die(Unit, 2, "btar: gzip: internal step limit")
    case 1n+q:
      match d:
        case DsRead{r}:
          do IO<Unit>:
            pr : File & Result<&1, &1, U32 & String, List<&2, U32>> <-
              Fx.Stream.read_exact(r, 1048576)
            drain(q, ds_after(pr))
        case DsDone{r}:
          do IO<Unit>:
            u : Unit <- File.close(r)
            IO.pure(Unit, Unit{})
        case DsFail{r, msg}:
          IO.die(Unit, 2, "btar: gzip: " ++ msg)

def steps() -> Nat:
  4294967295n

# After the tar reader: read the pipe to EOF (the decoder may still be
# verifying the tail) and wait for the decoder to finish.
def inflate_finish(d: Dr) -> IO(Unit):
  match d:
    case DrNone{}:
      IO.pure(Unit, Unit{})
    case DrPipe{r, ch}:
      do IO<Unit>:
        u : Unit <- drain(steps(), DsRead{r})
        IO.join(Unit, ch)

def start_pump(w: File, a: File, r: File, r2: File) -> IO(File & Dr):
  do IO<File & Dr>:
    ch : Chan(Unit) <- IO.fork(Unit, pump(steps(), PsRead{a, w, U.gs_new()}))
    IO.pure(File & Dr, (r2, DrPipe{r, ch}))

def dup_done(pr: File & Result<&1, &1, U32 & String, File>, w: File,
  a: File) -> IO(File & Dr):
  (r, res) = pr
  match res:
    case Fail{(c, m)}:
      IO.die(File & Dr, 2, "btar: gzip: pipe dup: " ++ m)
    case Done{r2}:
      start_pump(w, a, r, r2)

def pipe_done(pp: File & File, a: File) -> IO(File & Dr):
  (r, w) = pp
  do IO<File & Dr>:
    pr : File & Result<&1, &1, U32 & String, File> <- Fx.Fs.dup_file(r)
    dup_done(pr, w, a)

# `a`: the compressed archive, positioned at offset 0.  Returns the file the tar
# reader should consume plus the drain handle for `inflate_finish`.
def inflate_open(a: File) -> IO(File & Dr):
  do IO<File & Dr>:
    pp : File & File <- IO.try(File & File, Fx.Fs.pipe())
    pipe_done(pp, a)

# ---- non-seekable input (e.g. `btar -xf -`) --------------------------------------
# The two magic bytes were already consumed, so a forked feeder rebuilds the
# stream in a pipe: `magic`, then the rest of `a` up to EOF.  The read end is
# then consumed like a regular archive (or handed to the inflater).

def feed_close(pr: File & (File & Result<&1, &1, U32 & String, Unit>)) ->
  IO(Unit):
  (a, rest) = pr
  (w, r) = rest
  do IO<Unit>:
    u1 : Unit <- File.close(a)
    u2 : Unit <- File.close(w)
    IO.pure(Unit, Unit{})

def feed_copy(w: File, a: File) -> IO(Unit):
  do IO<Unit>:
    pr : File & (File & Result<&1, &1, U32 & String, Unit>) <-
      Fx.Data.copy_eof(a, w)
    feed_close(pr)

def feed_wrote(a: File, pr: File & Result<&1, &1, U32 & String, Unit>) ->
  IO(Unit):
  (w, r) = pr
  match r:
    case Done{u}:
      feed_copy(w, a)
    case Fail{(code, msg)}:
      do IO<Unit>:
        u1 : Unit <- File.close(a)
        u2 : Unit <- File.close(w)
        IO.pure(Unit, Unit{})

def feed_run(a: File, w: File, magic: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    pr : File & Result<&1, &1, U32 & String, Unit> <-
      Fx.Stream.write_bytes(w, magic)
    feed_wrote(a, pr)

def feed_forked(pp: File & File, a: File, magic: List<&2, U32>) -> IO(File):
  (r, w) = pp
  do IO<File>:
    ch : Chan(Unit) <- IO.fork(Unit, feed_run(a, w, magic))
    IO.pure(File, r)

def feed_open(a: File, magic: List<&2, U32>) -> IO(File):
  do IO<File>:
    pp : File & File <- IO.try(File & File, Fx.Fs.pipe())
    feed_forked(pp, a, magic)

# ---- compression pump ----------------------------------------------------------------
# `r` (a pipe fed by the tar writer) -> Gzcomp -> `out`.  Each round reads up to
# `lanes` segments of 128 KiB (each delivered with its 32 KiB tail by
# Stream.read_seg) and compresses them in parallel; memory grows with `lanes`
# and with the thread count.

def lanes() -> Nat:
  16n

def seg_bytes() -> U32:
  131072

def tail_bytes() -> U32:
  32768

def rev_segs(xs: List<&2, Z.Seg>, acc: List<&2, Z.Seg>) -> List<&2, Z.Seg>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rev_segs(t, h <> acc)

def pc_written2(inp: File, out: File, g: Z.GC, last: Bool) -> PC:
  match last:
    case True{}:
      PcEnd{inp, out}
    case False{}:
      PcRead{inp, out, g, Nil{}, lanes()}

def pc_written(pr: File & Result<&1, &1, U32 & String, Unit>, inp: File,
  g: Z.GC, outs: List<&2, List<&2, U32>>, last: Bool) -> PC:
  (out, r) = pr
  match r:
    case Fail{(c, m)}:
      PcFail{inp, out, "write: " ++ m}
    case Done{u}:
      PcWrite{inp, out, g, outs, last}

def pc_got2(seg: List<&2, U32>, tail: List<&2, U32>, inp: File, out: File,
  g: Z.GC, got: List<&2, Z.Seg>, k: Nat) -> PC:
  match seg:
    case Nil{}:
      PcFeed{inp, out, g, rev_segs(got, Nil{}), True{}}
    case +h <> t:
      PcRead{inp, out, g, Z.MkSeg{h <> t, tail} <> got, Nat.sub(k, 1n)}

def pc_got(pr: File & Result<&1, &1, U32 & String,
  List<&2, U32> & List<&2, U32>>, out: File, g: Z.GC,
  got: List<&2, Z.Seg>, k: Nat) -> PC:
  (inp, r) = pr
  match r:
    case Fail{(c, m)}:
      PcFail{inp, out, "read: " ++ m}
    case Done{(seg, tail)}:
      pc_got2(seg, tail, inp, out, g, got, k)

def pc_fed(inp: File, out: File, r: Z.GO, last: Bool) -> PC:
  match r:
    case Z.MkGO{g, outs}:
      PcWrite{inp, out, g, outs, last}

def pc_read(inp: File, out: File, g: Z.GC, got: List<&2, Z.Seg>, k: Nat) ->
  IO(PC):
  match k:
    case 0n:
      IO.pure(PC, PcFeed{inp, out, g, rev_segs(got, Nil{}), False{}})
    case _:
      do IO<PC>:
        pr : File & Result<&1, &1, U32 & String,
          List<&2, U32> & List<&2, U32>> <-
          Fx.Stream.read_seg(inp, seg_bytes(), tail_bytes())
        IO.pure(PC, pc_got(pr, out, g, got, k))

def deflate_loop(fuel: Nat, p: PC) -> IO(Unit):
  match fuel:
    case 0n:
      IO.die(Unit, 2, "btar: gzip: internal step limit")
    case 1n+q:
      match p:
        case PcRead{inp, out, g, got, k}:
          do IO<Unit>:
            p2 : PC <- pc_read(inp, out, g, got, k)
            deflate_loop(q, p2)
        case PcFeed{inp, out, g, segs, +last}:
          deflate_loop(q, pc_fed(inp, out, Z.gc_run(g, segs, last), last))
        case PcWrite{inp, out, g, outs, last}:
          match outs:
            case Nil{}:
              deflate_loop(q, pc_written2(inp, out, g, last))
            case h <> t:
              do IO<Unit>:
                pr : File & Result<&1, &1, U32 & String, Unit> <-
                  Fx.Stream.write_bytes(out, h)
                deflate_loop(q, pc_written(pr, inp, g, t, last))
        case PcEnd{inp, out}:
          do IO<Unit>:
            u1 : Unit <- File.close(inp)
            u2 : Unit <- File.close(out)
            IO.pure(Unit, Unit{})
        case PcFail{inp, out, msg}:
          IO.die(Unit, 2, "btar: gzip: " ++ msg)

# Compress everything readable from `inp` into `out` (both are closed).
def deflate_pump(inp: File, out: File) -> IO(Unit):
  deflate_loop(steps(), PcRead{inp, out, Z.gc_new(), Nil{}, lanes()})
