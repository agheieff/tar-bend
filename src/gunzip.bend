# Module: Gunzip — streaming gzip (RFC 1952) container around the Inflate engine.
#
# `gz_run` is one resumable step: the driver feeds input chunks (byte lists) and
# calls again until the status is Done or Err:
#   GNeed  -> read another chunk (or, at end of file, call with `last = True`)
#   GMore  -> output was produced and/or a member just finished; call again
#             with an empty chunk
# Header, trailer and member boundaries are handled byte-wise here; the DEFLATE
# body is run by the engine (src/inflate.bend).  At end of input the driver
# passes `last`: 512 zero bytes are appended so the engine's lookahead never
# stalls, and any consumption of that padding is reported as truncation.
# Every member's CRC32 and ISIZE are verified.  Memory is bounded by the chunk
# size, the 32 KiB window and one output flush (about 256 KiB).

import Base
import ./bytes.bend as B
import ./inflate.bend as I
import ./crc.bend as C

# ---- member phases (byte level) -------------------------------------------

type Ph is Data:
  PHdr{k: U32, flg: U32, hc: U32}
  PXl{k: U32, flg: U32, xl: U32, hc: U32}
  PXd{n: U32, flg: U32, hc: U32}
  PNm{flg: U32, hc: U32}
  PCm{flg: U32, hc: U32}
  PHc{k: U32, v: U32, hc: U32}
  PBodyNew{}
  PBody{}
  PTrl{k: U32, wc: U32, wi: U32, gc: U32, gi: U32}
  PNext{}
  PEnd{}

type Why is Data:
  WNeed{}
  WBody{}
  WEnd{}
  WErr{e: I.GzErr}

type Bst is Data:
  BsRun{br: I.Br, ph: Ph, pad: U32, nmem: U32}
  BsStop{br: I.Br, ph: Ph, pad: U32, nmem: U32, why: Why}

type GS is Type:
  MkGS{eng: I.Eng, br: I.Br, ph: Ph, pad: U32, nmem: U32, cs: C.CrcSt,
    mstart: U32}

type Gst is Data:
  GNeed{}
  GMore{}
  GDone{}
  GErr{e: I.GzErr}

type GR is Type:
  MkGR{g: GS, out: List<&2, U32>, n: U32, st: Gst}

def hc_byte(+hc: U32, +b: U32) -> U32:
  C.crc_entry(8n, U32.xor(hc, b))

def after_comm(+flg: U32, +hc: U32) -> Ph:
  Bool.pick(Ph, U32.is_zero(U32.and(flg, 2)), PBodyNew{}, PHc{0, 0, hc})

def after_name(+flg: U32, +hc: U32) -> Ph:
  Bool.pick(Ph, U32.is_zero(U32.and(flg, 16)), after_comm(flg, hc),
    PCm{flg, hc})

def after_extra(+flg: U32, +hc: U32) -> Ph:
  Bool.pick(Ph, U32.is_zero(U32.and(flg, 8)), after_name(flg, hc),
    PNm{flg, hc})

def after_fixed(+flg: U32, +hc: U32) -> Ph:
  Bool.pick(Ph, U32.is_zero(U32.and(flg, 4)), after_extra(flg, hc),
    PXl{0, flg, 0, hc})

def stop(br: I.Br, ph: Ph, pad: U32, nmem: U32, why: Why) -> Bst:
  BsStop{br, ph, pad, nmem, why}

def run(br: I.Br, ph: Ph, pad: U32, nmem: U32) -> Bst:
  BsRun{br, ph, pad, nmem}

def bad(br: I.Br, ph: Ph, pad: U32, nmem: U32, e: I.GzErr) -> Bst:
  BsStop{br, ph, pad, nmem, WErr{e}}

def magic_err(+nmem: U32) -> I.GzErr:
  Bool.pick(I.GzErr, U32.is_zero(nmem), I.GzMagic{}, I.GzCorrupt{})

# Fixed 10-byte header: magic, CM, FLG, then MTIME/XFL/OS (6 bytes skipped).
def hdr_ok(
  br: I.Br, ph: Ph, pad: U32, nmem: U32, ok: Bool, e: I.GzErr
) -> Bst:
  match ok:
    case True{}:
      run(br, ph, pad, nmem)
    case False{}:
      bad(br, ph, pad, nmem, e)

def hdr_byte(
  +k: U32, +flg: U32, +hc2: U32, +b: U32, br: I.Br, pad: U32, +nmem: U32
) -> Bst:
  match k:
    case 0:
      hdr_ok(br, PHdr{1, flg, hc2}, pad, nmem, U32.is_eq(b, 31), magic_err(nmem))
    case 1:
      hdr_ok(br, PHdr{2, flg, hc2}, pad, nmem, U32.is_eq(b, 139), magic_err(nmem))
    case 2:
      hdr_ok(br, PHdr{3, flg, hc2}, pad, nmem, U32.is_eq(b, 8), I.GzMethod{})
    case 3:
      hdr_ok(br, PHdr{4, b, hc2}, pad, nmem,
        U32.is_zero(U32.and(b, 224)), I.GzHeader{})
    case 9:
      run(br, after_fixed(flg, hc2), pad, nmem)
    case _:
      run(br, PHdr{U32.inc(k), flg, hc2}, pad, nmem)

def xl_byte(
  +k: U32, +flg: U32, +xl: U32, +hc2: U32, +b: U32, br: I.Br, pad: U32,
  nmem: U32
) -> Bst:
  match k:
    case 0:
      run(br, PXl{1, flg, b, hc2}, pad, nmem)
    case _:
      +n = U32.or(xl, U32.shln(b, 8n))
      run(br, Bool.pick(Ph, U32.is_zero(n), after_extra(flg, hc2),
        PXd{n, flg, hc2}), pad, nmem)

def xd_byte(
  +n: U32, +flg: U32, +hc2: U32, +b: U32, br: I.Br, pad: U32, nmem: U32
) -> Bst:
  +n2 = U32.sub(n, 1)
  run(br, Bool.pick(Ph, U32.is_zero(n2), after_extra(flg, hc2),
    PXd{n2, flg, hc2}), pad, nmem)

def nm_byte(
  +flg: U32, +hc2: U32, +b: U32, br: I.Br, pad: U32, nmem: U32
) -> Bst:
  run(br, Bool.pick(Ph, U32.is_zero(b), after_name(flg, hc2), PNm{flg, hc2}),
    pad, nmem)

def cm_byte(
  +flg: U32, +hc2: U32, +b: U32, br: I.Br, pad: U32, nmem: U32
) -> Bst:
  run(br, Bool.pick(Ph, U32.is_zero(b), after_comm(flg, hc2), PCm{flg, hc2}),
    pad, nmem)

def hc_chk(
  br: I.Br, pad: U32, nmem: U32, ok: Bool
) -> Bst:
  match ok:
    case True{}:
      run(br, PBodyNew{}, pad, nmem)
    case False{}:
      bad(br, PBodyNew{}, pad, nmem, I.GzHeader{})

def hcrc_byte(
  +k: U32, +v: U32, +hc: U32, +b: U32, br: I.Br, pad: U32, nmem: U32
) -> Bst:
  match k:
    case 0:
      run(br, PHc{1, b, hc}, pad, nmem)
    case _:
      hc_chk(br, pad, nmem, U32.is_eq(U32.or(v, U32.shln(b, 8n)),
        U32.and(U32.not(hc), 65535)))

# Trailer: CRC32 then ISIZE, little endian, compared with the member's values.
def trl_done(
  br: I.Br, pad: U32, nmem: U32, ok: Bool
) -> Bst:
  match ok:
    case True{}:
      run(br, PNext{}, pad, U32.inc(nmem))
    case False{}:
      bad(br, PNext{}, pad, nmem, I.GzCorrupt{})

def trl_byte(
  +k: U32, +wc: U32, +wi: U32, +gc: U32, +gi: U32, +b: U32, br: I.Br,
  pad: U32, nmem: U32
) -> Bst:
  match k:
    case 7:
      +gi2 = U32.or(gi, U32.shln(b, 24n))
      trl_done(br, pad, nmem, Bool.and(U32.is_eq(gc, wc), U32.is_eq(gi2, wi)))
    case 6:
      run(br, PTrl{7, wc, wi, gc, U32.or(gi, U32.shln(b, 16n))}, pad, nmem)
    case 5:
      run(br, PTrl{6, wc, wi, gc, U32.or(gi, U32.shln(b, 8n))}, pad, nmem)
    case 4:
      run(br, PTrl{5, wc, wi, gc, b}, pad, nmem)
    case 3:
      run(br, PTrl{4, wc, wi, U32.or(gc, U32.shln(b, 24n)), 0}, pad, nmem)
    case 2:
      run(br, PTrl{3, wc, wi, U32.or(gc, U32.shln(b, 16n)), 0}, pad, nmem)
    case 1:
      run(br, PTrl{2, wc, wi, U32.or(gc, U32.shln(b, 8n)), 0}, pad, nmem)
    case _:
      run(br, PTrl{1, wc, wi, b, 0}, pad, nmem)

def apply_byte(
  ph: Ph, +b: U32, br: I.Br, pad: U32, nmem: U32
) -> Bst:
  match ph:
    case PHdr{k, flg, hc}:
      hdr_byte(k, flg, hc_byte(hc, b), b, br, pad, nmem)
    case PXl{k, flg, xl, hc}:
      xl_byte(k, flg, xl, hc_byte(hc, b), b, br, pad, nmem)
    case PXd{n, flg, hc}:
      xd_byte(n, flg, hc_byte(hc, b), b, br, pad, nmem)
    case PNm{flg, hc}:
      nm_byte(flg, hc_byte(hc, b), b, br, pad, nmem)
    case PCm{flg, hc}:
      cm_byte(flg, hc_byte(hc, b), b, br, pad, nmem)
    case PHc{k, v, hc}:
      hcrc_byte(k, v, hc, b, br, pad, nmem)
    case PTrl{k, wc, wi, gc, gi}:
      trl_byte(k, wc, wi, gc, gi, b, br, pad, nmem)
    case _:
      bad(br, ph, pad, nmem, I.GzCorrupt{})

def take_byte2(
  ph: Ph, +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>, pad: U32,
  nmem: U32
) -> Bst:
  match inp:
    case Nil{}:
      bad(I.MkBr{acc, cnt, Nil{}, rem}, ph, pad, nmem, I.GzTruncated{})
    case +b <> t:
      apply_byte(ph, b, I.MkBr{acc, cnt, t, U32.sub(rem, 1)}, pad, nmem)

# Pop one input byte (the caller checked that a real byte is available).
def take_byte(ph: Ph, br: I.Br, pad: U32, nmem: U32) -> Bst:
  match br:
    case I.MkBr{acc, cnt, inp, +rem}:
      take_byte2(ph, acc, cnt, rem, inp, pad, nmem)

# Not enough real bytes: wait for more input, or truncated at end of file.
def starve(br: I.Br, ph: Ph, pad: U32, nmem: U32) -> Bst:
  match pad:
    case 0:
      stop(br, ph, pad, nmem, WNeed{})
    case _:
      bad(br, ph, pad, nmem, I.GzTruncated{})

def next_empty2(br: I.Br, pad: U32, nmem: U32, first: Bool) -> Bst:
  match first:
    case True{}:
      bad(br, PNext{}, pad, nmem, I.GzTruncated{})
    case False{}:
      stop(br, PEnd{}, pad, nmem, WEnd{})

def next_empty(br: I.Br, pad: U32, +nmem: U32) -> Bst:
  match pad:
    case 0:
      stop(br, PNext{}, pad, nmem, WNeed{})
    case _:
      next_empty2(br, pad, nmem, U32.is_zero(nmem))

def byte_gate(
  ph: Ph, br: I.Br, pad: U32, nmem: U32, avail: Bool
) -> Bst:
  match avail:
    case True{}:
      take_byte(ph, br, pad, nmem)
    case False{}:
      starve(br, ph, pad, nmem)

def next_go(br: I.Br, pad: U32, nmem: U32, avail: Bool) -> Bst:
  match avail:
    case False{}:
      next_empty(br, pad, nmem)
    case True{}:
      run(br, PHdr{0, 0, 4294967295}, pad, nmem)

def bs_go(ph: Ph, br: I.Br, pad: U32, nmem: U32, avail: Bool) -> Bst:
  match ph:
    case PBodyNew{}:
      stop(br, ph, pad, nmem, WBody{})
    case PBody{}:
      stop(br, ph, pad, nmem, WBody{})
    case PEnd{}:
      stop(br, ph, pad, nmem, WEnd{})
    case PNext{}:
      next_go(br, pad, nmem, avail)
    case _:
      byte_gate(ph, br, pad, nmem, avail)

def bs_step(ph: Ph, +br: I.Br, +pad: U32, nmem: U32) -> Bst:
  bs_go(ph, br, pad, nmem, U32.is_gt(I.br_rem(br), pad))

def bs_loop(fuel: Nat, st: Bst) -> Bst:
  match fuel:
    case 0n:
      st
    case 1n+p:
      match st:
        case BsRun{br, ph, pad, nmem}:
          bs_loop(p, bs_step(ph, br, pad, nmem))
        case BsStop{br, ph, pad, nmem, why}:
          BsStop{br, ph, pad, nmem, why}

# ---- member state + one step ---------------------------------------------------

def gs_new() -> GS:
  MkGS{I.eng_new(), I.br_new(Nil{}, 0), PNext{}, 0, 0,
    C.crc_new(C.crc_init()), 0}

def pad_len() -> U32:
  512

def gs_err(e: I.GzErr) -> GR:
  MkGR{gs_new(), Nil{}, 0, GErr{e}}

# Append a chunk (and the end-of-file padding once, when `last`).
def feed_cat(
  eng: I.Eng, ph: Ph, +pad: U32, nmem: U32, cs: C.CrcSt, mstart: U32,
  +acc: U32, +cnt: U32, inp: List<&2, U32>, +rem: U32,
  chunk: List<&2, U32>, +clen: U32, add_pad: Bool
) -> GS:
  match add_pad:
    case True{}:
      MkGS{eng, I.MkBr{acc, cnt, B.list_cat(inp, B.list_cat(chunk,
        I.zeros(U32.to_nat(pad_len())))),
        U32.add(U32.add(rem, clen), pad_len())},
        ph, pad_len(), nmem, cs, mstart}
    case False{}:
      MkGS{eng, I.MkBr{acc, cnt, B.list_cat(inp, chunk), U32.add(rem, clen)},
        ph, pad, nmem, cs, mstart}

def feed_gate(
  eng: I.Eng, ph: Ph, pad: U32, nmem: U32, cs: C.CrcSt, mstart: U32,
  acc: U32, cnt: U32, inp: List<&2, U32>, rem: U32,
  chunk: List<&2, U32>, clen: U32, skip: Bool, add_pad: Bool
) -> GS:
  match skip:
    case True{}:
      MkGS{eng, I.MkBr{acc, cnt, inp, rem}, ph, pad, nmem, cs, mstart}
    case False{}:
      feed_cat(eng, ph, pad, nmem, cs, mstart, acc, cnt, inp, rem, chunk,
        clen, add_pad)

def feed2(
  eng: I.Eng, ph: Ph, +pad: U32, nmem: U32, cs: C.CrcSt, mstart: U32,
  acc: U32, cnt: U32, inp: List<&2, U32>, rem: U32,
  chunk: List<&2, U32>, +clen: U32, +last: Bool
) -> GS:
  feed_gate(eng, ph, pad, nmem, cs, mstart, acc, cnt, inp, rem, chunk, clen,
    Bool.and(U32.is_zero(clen), Bool.not(Bool.and(last, U32.is_zero(pad)))),
    Bool.and(last, U32.is_zero(pad)))

def gs_feed(
  g: GS, chunk: List<&2, U32>, clen: U32, last: Bool
) -> GS:
  match g:
    case MkGS{eng, I.MkBr{acc, cnt, inp, rem}, ph, pad, nmem, cs, mstart}:
      feed2(eng, ph, pad, nmem, cs, mstart, acc, cnt, inp, rem, chunk, clen,
        last)

# ---- body --------------------------------------------------------------------

def body_done4(
  eng: I.Eng, br: I.Br, nmem: U32, pad: U32, +mstart: U32, +wpos: U32,
  out: List<&2, U32>, n: U32, r: C.CrcSt & U32
) -> GR:
  (cs, +c) = r
  MkGR{MkGS{eng, br, PTrl{0, C.crc_final(c), U32.sub(wpos, mstart), 0, 0},
    pad, nmem, cs, mstart}, out, n, GMore{}}

def body_done3(
  eng: I.Eng, br: I.Br, nmem: U32, pad: U32, cs: C.CrcSt, mstart: U32,
  wpos: U32, out: List<&2, U32>, n: U32
) -> GR:
  body_done4(eng, br, nmem, pad, mstart, wpos, out, n, C.crc_peek(cs))

def body_done2(
  r: I.Eng & U32, br: I.Br, nmem: U32, pad: U32, cs: C.CrcSt, mstart: U32,
  out: List<&2, U32>, n: U32
) -> GR:
  (eng, +wpos) = r
  body_done3(eng, br, nmem, pad, cs, mstart, wpos, out, n)

def body_done_ok(
  ok: Bool, eng: I.Eng, br: I.Br, nmem: U32, pad: U32, cs: C.CrcSt,
  mstart: U32, out: List<&2, U32>, n: U32
) -> GR:
  match ok:
    case False{}:
      gs_err(I.GzTruncated{})
    case True{}:
      body_done2(I.eng_wpos(eng), br, nmem, pad, cs, mstart, out, n)

def body_done(
  eng: I.Eng, +br: I.Br, nmem: U32, +pad: U32, cs: C.CrcSt, mstart: U32,
  out: List<&2, U32>, n: U32
) -> GR:
  body_done_ok(U32.is_ge(I.br_rem(br), pad), eng, br, nmem, pad, cs, mstart,
    out, n)

def body_need(
  pad: U32, eng: I.Eng, br: I.Br, nmem: U32, cs: C.CrcSt, mstart: U32,
  out: List<&2, U32>, n: U32
) -> GR:
  match pad:
    case 0:
      MkGR{MkGS{eng, br, PBody{}, pad, nmem, cs, mstart}, out, n, GNeed{}}
    case _:
      gs_err(I.GzTruncated{})

def body_fin(
  sp: I.Sp, eng: I.Eng, br: I.Br, nmem: U32, pad: U32, cs: C.CrcSt,
  mstart: U32, out: List<&2, U32>, n: U32
) -> GR:
  match sp:
    case I.SpErr{e}:
      gs_err(e)
    case I.SpNeed{}:
      body_need(pad, eng, br, nmem, cs, mstart, out, n)
    case I.SpFlush{}:
      MkGR{MkGS{eng, br, PBody{}, pad, nmem, cs, mstart}, out, n, GMore{}}
    case I.SpDone{}:
      body_done(eng, I.br_align(br), nmem, pad, cs, mstart, out, n)
    case I.SpRun{}:
      gs_err(I.GzCorrupt{})

def body_flush4(
  sp: I.Sp, r: I.Eng & I.Br, nmem: U32, pad: U32, out: List<&2, U32>,
  n: U32, cs: C.CrcSt, mstart: U32
) -> GR:
  (e3, br) = r
  body_fin(sp, e3, br, nmem, pad, cs, mstart, out, n)

def body_flush3(
  r: I.Eng & I.Sp, nmem: U32, pad: U32, out: List<&2, U32>, n: U32,
  cs: C.CrcSt, mstart: U32
) -> GR:
  (e2, sp) = r
  body_flush4(sp, I.eng_take_br(e2), nmem, pad, out, n, cs, mstart)

def body_flush2(
  r: I.Eng & (C.CrcSt & (List<&2, U32> & U32)), nmem: U32, pad: U32,
  mstart: U32
) -> GR:
  (e1, cn) = r
  (cs, on) = cn
  (out, n) = on
  body_flush3(I.eng_sp(e1), nmem, pad, out, n, cs, mstart)

def fuel_of(+br: I.Br) -> Nat:
  Nat.add(Nat.mul(8n, U32.to_nat(I.br_rem(br))), 256n)

def body_run(
  eng: I.Eng, +br: I.Br, pad: U32, nmem: U32, cs: C.CrcSt, mstart: U32
) -> GR:
  body_flush2(I.eng_flush(I.eng_run(I.eng_set_br(eng, br), fuel_of(br)), cs),
    nmem, pad, mstart)

def body_new(
  r: I.Eng & U32, br: I.Br, pad: U32, nmem: U32, cs: C.CrcSt
) -> GR:
  (eng, wpos) = r
  body_run(eng, br, pad, nmem, C.crc_reset(cs), wpos)

def body_start(
  ph: Ph, eng: I.Eng, br: I.Br, pad: U32, nmem: U32, cs: C.CrcSt, mstart: U32
) -> GR:
  match ph:
    case PBodyNew{}:
      body_new(I.eng_wpos(I.eng_member(eng)), br, pad, nmem, cs)
    case _:
      body_run(eng, br, pad, nmem, cs, mstart)

# After the byte-phase loop: rebuild the state, or hand over to the body.
def after_why(
  why: Why, eng: I.Eng, br: I.Br, ph: Ph, pad: U32, nmem: U32,
  cs: C.CrcSt, mstart: U32
) -> GR:
  match why:
    case WNeed{}:
      MkGR{MkGS{eng, br, ph, pad, nmem, cs, mstart}, Nil{}, 0, GNeed{}}
    case WEnd{}:
      MkGR{MkGS{eng, br, ph, pad, nmem, cs, mstart}, Nil{}, 0, GDone{}}
    case WErr{e}:
      gs_err(e)
    case WBody{}:
      body_start(ph, eng, br, pad, nmem, cs, mstart)

def after_bytes(
  eng: I.Eng, cs: C.CrcSt, mstart: U32, bs: Bst
) -> GR:
  match bs:
    case BsRun{br, ph, pad, nmem}:
      gs_err(I.GzCorrupt{})
    case BsStop{br, ph, pad, nmem, why}:
      after_why(why, eng, br, ph, pad, nmem, cs, mstart)

def gz_run2(g: GS) -> GR:
  match g:
    case MkGS{eng, +br, ph, pad, nmem, cs, mstart}:
      after_bytes(eng, cs, mstart, bs_loop(Nat.add(U32.to_nat(I.br_rem(br)),
        64n), BsRun{br, ph, pad, nmem}))

# One step: feed a chunk (`clen` bytes; empty when resuming), advance.
def gz_run(g: GS, chunk: List<&2, U32>, clen: U32, last: Bool) -> GR:
  gz_run2(gs_feed(g, chunk, clen, last))

# ---- whole-buffer convenience (tests, small inputs) ------------------------------

def cat_chunks(xs: List<&2, List<&2, U32>>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      cat_chunks(t, B.list_cat(h, acc))

def dec_loop(
  fuel: Nat, r: GR, acc: List<&2, List<&2, U32>>
) -> Result<&1, &1, I.GzErr, List<&2, U32>>:
  match fuel:
    case 0n:
      Fail{I.GzCorrupt{}}
    case 1n+p:
      match r:
        case MkGR{g, out, n, st}:
          match st:
            case GNeed{}:
              Fail{I.GzTruncated{}}
            case GMore{}:
              dec_loop(p, gz_run(g, Nil{}, 0, True{}), out <> acc)
            case GDone{}:
              Done{cat_chunks(out <> acc, Nil{})}
            case GErr{e}:
              Fail{e}

def decompress(+data: List<&2, U32>) -> Result<&1, &1, I.GzErr, List<&2, U32>>:
  +n = List.length(&2, U32, data)
  dec_loop(Nat.add(Nat.mul(4n, n), 64n),
    gz_run(gs_new(), data, U32.from_nat(n), True{}), Nil{})

# gzip magic (1f 8b) at the start of the data.
def is_gzip(+data: List<&2, U32>) -> Bool:
  match data:
    case Nil{}:
      False{}
    case +h <> t:
      match t:
        case Nil{}:
          False{}
        case +g <> _:
          Bool.and(U32.is_eq(h, 31), U32.is_eq(g, 139))
