# Module: Gzcomp — streaming gzip (RFC 1952) writer around Deflate segments.
#
# `gc_run(g, segs, last)` takes the next input segments and returns the
# compressed pieces they produced.  A segment is up to 128 KiB of input together
# with its last 32 KiB (`Stream.read_seg` delivers both, built in C); every
# segment is compressed independently with the preceding 32 KiB of input as
# match dictionary (src/deflate.bend), and the segments of one call run in
# parallel (Bend's parallel let, one task per segment).  Segment CRC-32s are
# computed inside the tasks and combined (`Crc.crc_combine`), so no long list
# is traversed serially.  Output is deterministic and independent of the
# thread count.  Segment boundaries are byte aligned (sync flush), so
# concatenation is a valid DEFLATE stream; the last call (`last = True`)
# appends the final block and the CRC-32/ISIZE trailer.

import Base
import ./bytes.bend as B
import ./crc.bend as C
import ./deflate.bend as D

type GC is Data:
  MkGC{dict: List<&2, U32>, crc: U32, isz: U32, started: Bool, done: Bool}

# Pieces to write, in order.
type GO is Data:
  MkGO{g: GC, outs: List<&2, List<&2, U32>>}

# One input segment and its 32 KiB tail (the next segment's dictionary).
type Seg is Data:
  MkSeg{seg: List<&2, U32>, tail: List<&2, U32>}

type Job is Data:
  MkJob{dict: List<&2, U32>, seg: List<&2, U32>}

type Jr is Data:
  MkJr{jobs: List<&2, Job>, dict: List<&2, U32>, n: Nat}

# Fold results in order: pieces (newest first), combined CRC, total size.
type Fr is Data:
  MkFr{outs: List<&2, List<&2, U32>>, crc: U32, isz: U32}

def gc_new() -> GC:
  MkGC{Nil{}, 0, 0, False{}, False{}}

def jr_cons(j: Job, jr: Jr) -> Jr:
  match jr:
    case MkJr{jobs, dict, n}:
      MkJr{j <> jobs, dict, Nat.add(n, 1n)}

# Job i's dictionary is the tail of segment i - 1 (the carried dictionary for
# i = 0); the tail of the last segment becomes the carried dictionary.
def mk_jobs(fuel: Nat, segs: List<&2, Seg>, dict: List<&2, U32>) -> Jr:
  match fuel:
    case 0n:
      MkJr{Nil{}, dict, 0n}
    case 1n+p:
      match segs:
        case Nil{}:
          MkJr{Nil{}, dict, 0n}
        case MkSeg{seg, tail} <> rest:
          jr_cons(MkJob{dict, seg}, mk_jobs(p, rest, tail))

def job_run(j: Job) -> D.Sres:
  match j:
    case MkJob{dict, seg}:
      D.seg_compress(dict, seg)

def cat_res(+xs: List<&2, D.Sres>, ys: List<&2, D.Sres>) -> List<&2, D.Sres>:
  match xs:
    case Nil{}:
      ys
    case +h <> t:
      h <> cat_res(t, ys)

# Compress all jobs; halves run in parallel (a balanced fork-join tree).
def comp_jobs(+fuel: Nat, +n: Nat, +js: List<&2, Job>) -> List<&2, D.Sres>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match n:
        case 0n:
          Nil{}
        case 1n:
          match js:
            case Nil{}:
              Nil{}
            case +j <> _:
              job_run(j) <> Nil{}
        case _:
          x y = comp_jobs(p, Nat.div(n, 2n),
            List.take(&2, Job, js, Nat.div(n, 2n))) comp_jobs(p,
            Nat.sub(n, Nat.div(n, 2n)), List.drop(&2, Job, js, Nat.div(n, 2n)))
          cat_res(x, y)

def fold1(fr: Fr, out: List<&2, U32>, +rcrc: U32, +slen: U32) -> Fr:
  match fr:
    case MkFr{outs, crc, isz}:
      MkFr{out <> outs, C.crc_combine(crc, rcrc, slen), U32.add(isz, slen)}

def fold_res(+rs: List<&2, D.Sres>, fr: Fr) -> Fr:
  match rs:
    case Nil{}:
      fr
    case D.MkSres{out, rcrc, slen} <> t:
      fold_res(t, fold1(fr, out, rcrc, slen))

def rev_outs(
  xs: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>
) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rev_outs(t, h <> acc)

def cat_lists(+xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case +h <> t:
      h <> cat_lists(t, ys)

def gz_header() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 0, 255]

def u32_le(+v: U32) -> List<&2, U32>:
  U32.and(v, 255) <> (U32.and(U32.shrn(v, 8n), 255) <>
    (U32.and(U32.shrn(v, 16n), 255) <> (U32.shrn(v, 24n) <> Nil{})))

# Final empty block (BFINAL = 1, fixed Huffman, end of block) and the trailer.
def tail_bytes(+crc: U32, +isz: U32) -> List<&2, U32>:
  B.list_cat([3, 0], B.list_cat(u32_le(crc), u32_le(isz)))

def with_header(started: Bool, outs: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match started:
    case True{}:
      outs
    case False{}:
      gz_header() <> outs

def with_tail(
  last: Bool, +crc: U32, +isz: U32, outs: List<&2, List<&2, U32>>
) -> List<&2, List<&2, U32>>:
  match last:
    case True{}:
      cat_lists(outs, tail_bytes(crc, isz) <> Nil{})
    case False{}:
      outs

def gc_fin(fr: Fr, dict: List<&2, U32>, started: Bool, +last: Bool) -> GO:
  match fr:
    case MkFr{outs, +crc, +isz}:
      MkGO{MkGC{dict, crc, isz, True{}, last},
        with_tail(last, crc, isz, with_header(started, rev_outs(outs, Nil{})))}

def gc_run3(jr: Jr, started: Bool, last: Bool, fr0: Fr) -> GO:
  match jr:
    case MkJr{jobs, dict, +n}:
      gc_fin(fold_res(comp_jobs(Nat.add(n, 8n), n, jobs), fr0), dict, started,
        last)

def gc_run(g: GC, segs: List<&2, Seg>, last: Bool) -> GO:
  match g:
    case MkGC{dict, crc, isz, started, done}:
      gc_run3(mk_jobs(64n, segs, dict), started, last, MkFr{Nil{}, crc, isz})

# ---- whole-buffer convenience (tests, small inputs) ------------------------------

def cat_all(+xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      B.list_cat(h, cat_all(t))

def out_all(go: GO) -> List<&2, U32>:
  match go:
    case MkGO{_, outs}:
      cat_all(outs)

def min_nat(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(a, b), a, b)

# The last 32 KiB of a segment (a copy: segments in tests are small).
def tail_of(+seg: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, seg, Nat.sub(List.length(&2, U32, seg),
    min_nat(List.length(&2, U32, seg), 32768n)))

# Cut `data` into 128 KiB segments with their 32 KiB tails.
def cut_segs(fuel: Nat, +data: List<&2, U32>, +n: Nat) -> List<&2, Seg>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      match n:
        case 0n:
          Nil{}
        case _:
          +seg = List.take(&2, U32, data, min_nat(n, 131072n))
          MkSeg{seg, tail_of(seg)} <> cut_segs(p,
            List.drop(&2, U32, data, 131072n), Nat.sub(n, min_nat(n, 131072n)))

def compress(+data: List<&2, U32>) -> List<&2, U32>:
  out_all(gc_run(gc_new(), cut_segs(64n, data, List.length(&2, U32, data)),
    True{}))
