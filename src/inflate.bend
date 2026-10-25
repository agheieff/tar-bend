# Module: Inflate — resumable, table-driven DEFLATE (RFC 1951) block decoder.
#
# Pure Bend, no effects, no @unsafe.  The decoder is a state machine (`Eng`)
# fed by byte lists and stopped by one of: needs more input, output threshold,
# final block done, error.  Bytes are packed LSB-first into a 32-bit
# accumulator (`Br`); Huffman codes decode through a flat `Array<U32>` table
# indexed by the next `bits` input bits (entry = code length | kind | payload,
# see `ent_*`); the 32 KiB window is a ring `Array<U32>`.  A symbol is only
# decoded while at least `GUARD` input bytes remain, so no mid-symbol
# underrun can happen; callers append zero padding at end of stream and check
# that the padding was not consumed.  Every loop is fuel/structure bounded.

import Base
import ./bytes.bend as B
import ./crc.bend as C

type GzErr is Data:
  GzMagic{}
  GzMethod{}
  GzHeader{}
  GzCorrupt{}
  GzSize{}
  GzTruncated{}
  GzUnsupported{}

# ---- bit reader -------------------------------------------------------
# `inp` holds `rem` bytes; `acc` holds `cnt` valid bits, LSB first.

type Br is Data:
  MkBr{acc: U32, cnt: U32, inp: List<&2, U32>, rem: U32}

type Tab is Type:
  MkTab{tab: Array<U32>, bits: U32, ok: Bool}

type TS is Type:
  MkTS{tab: Array<U32>, nc: List<&2, U32>}

type Wc is Data:
  MkWc{wpos: U32, wfill: U32, olen: U32}

type Wp is Type:
  MkWp{win: Array<U32>, wc: Wc}

type Hw is Data:
  HEob{}
  HNeed{}
  HFlush{}
  HErr{e: GzErr}

type Hs is Type:
  HsRun{br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
    dst: Array<U32>, dtb: U32}
  HsStop{br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
    dst: Array<U32>, dtb: U32, how: Hw}

type Ss is Type:
  SsRun{n: U32, br: Br, wc: Wc, win: Array<U32>}
  SsStop{n: U32, br: Br, wc: Wc, win: Array<U32>, how: Hw}

type Md is Data:
  MBlk{}
  MCodes{}
  MStored{n: U32}
  MFin{}

type Sp is Data:
  SpRun{}
  SpNeed{}
  SpFlush{}
  SpDone{}
  SpErr{e: GzErr}

type Eng is Type:
  MkEng{br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
    dst: Array<U32>, dtb: U32, md: Md, bfin: Bool, sp: Sp}

type Clr is Data:
  MkClr{br: Br, cl: List<&2, U32>}

type Ls is Type:
  LsRun{br: Br, ctab: Array<U32>, ctb: U32, acc: List<&2, U32>, n: U32,
    total: U32, prev: U32}
  LsEnd{br: Br, acc: List<&2, U32>}
  LsErr{e: GzErr}

# Read the staged output back: fold its CRC-32 forward, then build the list.
type Ob is Type:
  MkOb{win: Array<U32>, cs: C.CrcSt}

type Ol is Type:
  MkOl{win: Array<U32>, acc: List<&2, U32>}

def br_new(+inp: List<&2, U32>, +rem: U32) -> Br:
  MkBr{0, 0, inp, rem}

def br_add2(+acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>) -> Br:
  match inp:
    case Nil{}:
      MkBr{acc, cnt, Nil{}, rem}
    case +h <> t:
      MkBr{U32.or(acc, U32.shln(h, U32.to_nat(cnt))), U32.add(cnt, 8), t,
        U32.sub(rem, 1)}

def br_add(+acc: U32, +cnt: U32, inp: List<&2, U32>, +rem: U32, fits: Bool) -> Br:
  match fits:
    case False{}:
      MkBr{acc, cnt, inp, rem}
    case True{}:
      br_add2(acc, cnt, rem, inp)

def br_fill1(br: Br) -> Br:
  match br:
    case MkBr{+acc, +cnt, inp, +rem}:
      br_add(acc, cnt, inp, rem, U32.is_le(cnt, 24))

# Byte-wise top-up to more than 24 valid bits (or until the input is
# exhausted); the wide path below falls back to it near the end of the list.
def br_fill_slow(br: Br) -> Br:
  br_fill1(br_fill1(br_fill1(br_fill1(br))))

def br_fill4(
  +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>
) -> Br:
  match inp:
    case +a <> (+b <> (+c <> (+d <> t))):
      MkBr{U32.or(acc, U32.shln(U32.or(U32.or(a, U32.shln(b, 8n)),
        U32.or(U32.shln(c, 16n), U32.shln(d, 24n))), U32.to_nat(cnt))),
        U32.add(cnt, 32), t, U32.sub(rem, 4)}
    case _:
      br_fill_slow(MkBr{acc, cnt, inp, rem})

def br_fill3(
  +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>
) -> Br:
  match inp:
    case +a <> (+b <> (+c <> t)):
      MkBr{U32.or(acc, U32.shln(U32.or(U32.or(a, U32.shln(b, 8n)),
        U32.shln(c, 16n)), U32.to_nat(cnt))), U32.add(cnt, 24), t,
        U32.sub(rem, 3)}
    case _:
      br_fill_slow(MkBr{acc, cnt, inp, rem})

def br_fill2(
  +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>
) -> Br:
  match inp:
    case +a <> (+b <> t):
      MkBr{U32.or(acc, U32.shln(U32.or(a, U32.shln(b, 8n)), U32.to_nat(cnt))),
        U32.add(cnt, 16), t, U32.sub(rem, 2)}
    case _:
      br_fill_slow(MkBr{acc, cnt, inp, rem})

def br_fill1w(
  +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>
) -> Br:
  match inp:
    case +a <> t:
      MkBr{U32.or(acc, U32.shln(a, U32.to_nat(cnt))), U32.add(cnt, 8), t,
        U32.sub(rem, 1)}
    case _:
      MkBr{acc, cnt, inp, rem}

def br_fill_n(
  +n: U32, +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>
) -> Br:
  match n:
    case 0:
      MkBr{acc, cnt, inp, rem}
    case 1:
      br_fill1w(acc, cnt, rem, inp)
    case 2:
      br_fill2(acc, cnt, rem, inp)
    case 3:
      br_fill3(acc, cnt, rem, inp)
    case _:
      br_fill4(acc, cnt, rem, inp)

# Top up so that more than 24 bits are valid (input permitting): add the
# (32 - cnt) / 8 whole bytes that fit.
def br_fill(br: Br) -> Br:
  match br:
    case MkBr{+acc, +cnt, inp, +rem}:
      br_fill_n(U32.shrn(U32.sub(32, cnt), 3n), acc, cnt, rem, inp)

def br_acc(br: Br) -> U32:
  match br:
    case MkBr{a, _, _, _}:
      a

def br_cnt(br: Br) -> U32:
  match br:
    case MkBr{_, c, _, _}:
      c

def br_rem(br: Br) -> U32:
  match br:
    case MkBr{_, _, _, r}:
      r

def br_inp(br: Br) -> List<&2, U32>:
  match br:
    case MkBr{_, _, i, _}:
      i

def br_drop(br: Br, +n: U32) -> Br:
  match br:
    case MkBr{+acc, +cnt, inp, rem}:
      MkBr{U32.shrn(acc, U32.to_nat(n)), U32.sub(cnt, n), inp, rem}

def mask_of(+n: U32) -> U32:
  U32.sub(U32.shln(1, U32.to_nat(n)), 1)

# Next `n` bits (n <= 16), not consumed.
def br_peek(br: Br, +n: U32) -> U32:
  U32.and(br_acc(br), mask_of(n))

# Read `n` bits and consume them: returns (value) with the reader advanced by
# the caller via br_drop (kept separate so callers hold both).

# Whole bytes held in the accumulator go back in front of the input list.
def unpack_acc(fuel: Nat, +acc: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      rest
    case 1n+p:
      U32.and(acc, 255) <> unpack_acc(p, U32.shrn(acc, 8n), rest)

# Discard the partial byte, push whole buffered bytes back: byte-aligned reader.
def br_align2(+acc: U32, +nb: U32, inp: List<&2, U32>, +rem: U32) -> Br:
  MkBr{0, 0, unpack_acc(U32.to_nat(nb), acc, inp), U32.add(rem, nb)}

def br_align(br: Br) -> Br:
  match br:
    case MkBr{+acc, +cnt, inp, +rem}:
      br_align2(U32.shrn(acc, U32.to_nat(U32.and(cnt, 7))),
        U32.shrn(cnt, 3n), inp, rem)

# ---- small list helpers ------------------------------------------------

def nth(xs: List<&2, U32>, i: Nat) -> U32:
  match xs i:
    case Nil{} _:
      0
    case +h <> _ 0n:
      h
    case _ <> t 1n+p:
      nth(t, p)

def inc_at(xs: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  match xs i:
    case Nil{} _:
      Nil{}
    case +h <> t 0n:
      U32.inc(h) <> t
    case h <> t 1n+p:
      h <> inc_at(t, p)

def zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0 <> zeros(p)

def list_max(+xs: List<&2, U32>, +m: U32) -> U32:
  match xs:
    case Nil{}:
      m
    case +h <> t:
      list_max(t, U32.max(m, h))

def rev(+xs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rev(t, h <> acc)

# ---- Huffman tables ----------------------------------------------------
# Entry layout (all alphabets):  bits 0-3 code length (0 = invalid code),
# bits 4-5 kind, bits 8-15 payload a, bits 16-30 payload b.
#   lit/len kind 0 literal (a = byte), 1 length (a = extra bits, b = base),
#           2 end of block, 3 invalid symbol (286/287)
#   dist    kind 0 distance (a = extra bits, b = base), 3 invalid (30/31)
#   plain   (code-length alphabet) a = symbol

def len_extra(+c: U32) -> U32:
  Bool.pick(U32, U32.is_lt(c, 8), 0,
    Bool.pick(U32, U32.is_lt(c, 28), U32.sub(U32.shrn(c, 2n), 1), 0))

def len_base(+c: U32) -> U32:
  +e = len_extra(c)
  Bool.pick(U32, U32.is_lt(c, 8), U32.add(c, 3),
    Bool.pick(U32, U32.is_lt(c, 28),
      U32.add(U32.shln(U32.add(4, U32.and(c, 3)), U32.to_nat(e)), 3), 258))

def dist_extra(+d: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 4), 0, U32.sub(U32.shrn(d, 1n), 1))

def dist_base(+d: U32) -> U32:
  +e = dist_extra(d)
  Bool.pick(U32, U32.is_lt(d, 4), U32.add(d, 1),
    U32.add(U32.shln(U32.add(2, U32.and(d, 1)), U32.to_nat(e)), 1))

def ent_len(+sym: U32, +l: U32) -> U32:
  +c = U32.sub(sym, 257)
  U32.or(U32.or(l, 16), U32.or(U32.shln(len_extra(c), 8n),
    U32.shln(len_base(c), 16n)))

def ent_lit_sym(+sym: U32, +l: U32) -> U32:
  Bool.pick(U32, U32.is_lt(sym, 256), U32.or(l, U32.shln(sym, 8n)),
    Bool.pick(U32, U32.is_eq(sym, 256), U32.or(l, 32),
      Bool.pick(U32, U32.is_lt(sym, 286), ent_len(sym, l), U32.or(l, 48))))

def ent_dist_sym(+d: U32, +l: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 30),
    U32.or(l, U32.or(U32.shln(dist_extra(d), 8n), U32.shln(dist_base(d), 16n))),
    U32.or(l, 48))

# mode 0 = lit/len, 1 = dist, 2 = plain
def ent_make(+mode: U32, +sym: U32, +l: U32) -> U32:
  Bool.pick(U32, U32.is_eq(mode, 0), ent_lit_sym(sym, l),
    Bool.pick(U32, U32.is_eq(mode, 1), ent_dist_sym(sym, l),
      U32.or(l, U32.shln(sym, 8n))))

def count_lens(+lens: List<&2, U32>, +bl: List<&2, U32>) -> List<&2, U32>:
  match lens:
    case Nil{}:
      bl
    case +h <> t:
      count_lens(t, inc_at(bl, U32.to_nat(h)))

# Kraft sum check over lengths 1..15: False when the code is over-subscribed.
def kraft_go(fuel: Nat, +l: Nat, +left: U32, +bl: List<&2, U32>) -> Bool:
  match fuel:
    case 0n:
      True{}
    case 1n+p:
      +left2 = U32.shln(left, 1n)
      +c = nth(bl, Nat.add(l, 1n))
      Bool.and(U32.is_ge(left2, c),
        kraft_go(p, Nat.add(l, 1n), U32.sub(left2, c), bl))

# First code of each length: nc[l] for l = 1..15 (index 0 unused).
def nc_go(fuel: Nat, +l: Nat, +code: U32, +bl: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      +code2 = U32.shln(U32.add(code, nth(bl, Nat.sub(l, 1n))), 1n)
      code2 <> nc_go(p, Nat.add(l, 1n), code2, bl)

# 16-bit reversal of `x`, then keep the top `n` bits: bit-reversed code of n bits.
def rev16(+x: U32) -> U32:
  +a = U32.or(U32.shln(U32.and(x, 21845), 1n), U32.and(U32.shrn(x, 1n), 21845))
  +b = U32.or(U32.shln(U32.and(a, 13107), 2n), U32.and(U32.shrn(a, 2n), 13107))
  +c = U32.or(U32.shln(U32.and(b, 3855), 4n), U32.and(U32.shrn(b, 4n), 3855))
  U32.or(U32.shln(U32.and(c, 255), 8n), U32.and(U32.shrn(c, 8n), 255))

def code_rev(+code: U32, +n: U32) -> U32:
  U32.shrn(rev16(code), U32.to_nat(U32.sub(16, n)))

def fill_loop(
  k: Nat, tab: Array<U32>, +idx: U32, +stride: U32, +entry: U32
) -> Array<U32>:
  match k:
    case 0n:
      tab
    case 1n+p:
      fill_loop(p, Array.set(U32, tab, idx, entry), U32.add(idx, stride), stride,
        entry)

def ts_assign2(
  tab: Array<U32>, +code: U32, +l: U32, +tb: U32, +entry: U32
) -> Array<U32>:
  fill_loop(U32.to_nat(U32.shln(1, U32.to_nat(U32.sub(tb, l)))), tab,
    code_rev(code, l), U32.shln(1, U32.to_nat(l)), entry)

def ts_assign3(
  tab: Array<U32>, +nc: List<&2, U32>, +h: U32, +sym: U32, +mode: U32, +tb: U32
) -> TS:
  MkTS{ts_assign2(tab, nth(nc, U32.to_nat(U32.sub(h, 1))), h, tb,
    ent_make(mode, sym, h)), inc_at(nc, U32.to_nat(U32.sub(h, 1)))}

def ts_assign(
  ts: TS, +h: U32, +sym: U32, +mode: U32, +tb: U32
) -> TS:
  match ts:
    case MkTS{tab, nc}:
      ts_assign3(tab, nc, h, sym, mode, tb)

def assign_one(
  ts: TS, +h: U32, +sym: U32, +mode: U32, +tb: U32, zero: Bool
) -> TS:
  match zero:
    case True{}:
      ts
    case False{}:
      ts_assign(ts, h, sym, mode, tb)

def assign_loop(
  lens: List<&2, U32>, +sym: U32, +mode: U32, +tb: U32, ts: TS
) -> TS:
  match lens:
    case Nil{}:
      ts
    case +h <> t:
      assign_loop(t, U32.inc(sym), mode, tb,
        assign_one(ts, h, sym, mode, tb, U32.is_zero(h)))

def tab_of(ts: TS, +tb: U32, ok: Bool) -> Tab:
  match ts:
    case MkTS{tab, _}:
      MkTab{tab, tb, ok}

def bl_fix(bl: List<&2, U32>) -> List<&2, U32>:
  match bl:
    case Nil{}:
      Nil{}
    case _ <> t:
      0 <> t

def build_tab3(
  lens: List<&2, U32>, +mode: U32, +tb: U32, nc: List<&2, U32>, ok: Bool
) -> Tab:
  tab_of(assign_loop(lens, 0, mode, tb,
    MkTS{Array.new(U32, U32.to_nat(tb), 0), nc}), tb, ok)

def build_tab2(
  +lens: List<&2, U32>, +mode: U32, +tb: U32, +bl: List<&2, U32>, ok: Bool
) -> Tab:
  build_tab3(lens, mode, tb, nc_go(15n, 1n, 0, bl_fix(bl)), ok)

# Build a decode table from code lengths (symbols 0..n-1), table index width =
# longest code.  ok = False for over-subscribed codes.  Incomplete codes leave
# zero (invalid) entries that fail only if actually used.
def build_tab(+lens: List<&2, U32>, +mode: U32) -> Tab:
  +bl = count_lens(lens, zeros(16n))
  +tb = list_max(lens, 0)
  build_tab2(lens, mode, tb, bl, kraft_go(15n, 0n, 1, bl))

# ---- window + output ---------------------------------------------------
# One flat array holds the 32 KiB ring window at [0, 32768) (index = wpos &
# 32767) and, behind it, the output staged for the current run (`olen` bytes at
# 32768 + i).  The counters live in the reusable record `Wc`: `wfill` counts
# valid window bytes (saturating) so distances past the start are rejected.
# `eng_flush` reads the staged output back (CRC fold + list for the pipe).

def out_base() -> U32:
  32768

def win_new() -> Array<U32>:
  Array.new(U32, 19n, 0)

def wc_new() -> Wc:
  MkWc{0, 0, 0}

def wc_olen(wc: Wc) -> U32:
  match wc:
    case MkWc{_, _, o}:
      o

def wc_wfill(wc: Wc) -> U32:
  match wc:
    case MkWc{_, f, _}:
      f

def wc_wpos(wc: Wc) -> U32:
  match wc:
    case MkWc{p, _, _}:
      p

# Account one output byte (the array writes are done by the caller).
def wc_put(wc: Wc) -> Wc:
  match wc:
    case MkWc{+wpos, +wfill, +olen}:
      MkWc{U32.inc(wpos), U32.min(U32.inc(wfill), 32768), U32.inc(olen)}

def put1(win: Array<U32>, +wc: Wc, +b: U32) -> Wp:
  MkWp{Array.set(U32, Array.set(U32, win, U32.and(wc_wpos(wc), 32767), b),
    U32.add(out_base(), wc_olen(wc)), b), wc_put(wc)}

def cp_put(r: Array<U32> & U32, +wc: Wc) -> Wp:
  (win, +v) = r
  put1(win, wc, v)

def cp_step(win: Array<U32>, +wc: Wc, +dist: U32) -> Wp:
  cp_put(Array.get(U32, win, U32.and(U32.sub(wc_wpos(wc), dist), 32767)), wc)

def cp_wp(wp: Wp, +dist: U32) -> Wp:
  match wp:
    case MkWp{win, wc}:
      cp_step(win, wc, dist)

# LZ77 copy of n bytes from `dist` back; overlapping copies repeat naturally.
def copy_loop(n: Nat, +dist: U32, wp: Wp) -> Wp:
  match n:
    case 0n:
      wp
    case 1n+p:
      copy_loop(p, dist, cp_wp(wp, dist))

# ---- Huffman data block loop --------------------------------------------
# One iteration = one symbol (a whole match for length/distance pairs).

def hs_back(wp: Wp, br: Br, lit: Array<U32>, ltb: U32, dst: Array<U32>,
  dtb: U32) -> Hs:
  match wp:
    case MkWp{win, wc}:
      HsRun{br, wc, win, lit, ltb, dst, dtb}

def hs_copy(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, +len: U32, +dist: U32, ok: Bool
) -> Hs:
  match ok:
    case False{}:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HErr{GzCorrupt{}}}
    case True{}:
      hs_back(copy_loop(U32.to_nat(len), dist, MkWp{win, wc}), br, lit, ltb,
        dst, dtb)

# Distance extra bits, then the copy.
def hs_dextra(
  +br: Br, +wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, +len: U32, +dent: U32
) -> Hs:
  +n = U32.and(U32.shrn(dent, 8n), 255)
  +dist = U32.add(U32.shrn(dent, 16n), br_peek(br, n))
  hs_copy(br_drop(br, n), wc, win, lit, ltb, dst, dtb, len, dist,
    U32.is_le(dist, wc_wfill(wc)))

def hs_dchk(
  +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, +len: U32, +dent: U32, ok: Bool
) -> Hs:
  match ok:
    case False{}:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HErr{GzCorrupt{}}}
    case True{}:
      hs_dextra(br_fill(br_drop(br, U32.and(dent, 15))), wc, win, lit, ltb,
        dst, dtb, len, dent)

def hs_dent(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32, dtb: U32,
  +len: U32, r: Array<U32> & U32
) -> Hs:
  (dst, +dent) = r
  hs_dchk(br, wc, win, lit, ltb, dst, dtb, len, dent,
    Bool.and(U32.is_zero(U32.and(dent, 48)),
      U32.is_ne(U32.and(dent, 15), 0)))

# Length symbol: extra bits, then look up the distance code.
def hs_len(
  +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, +dtb: U32, +ent: U32
) -> Hs:
  +n = U32.and(U32.shrn(ent, 8n), 255)
  +len = U32.add(U32.shrn(ent, 16n), br_peek(br, n))
  +br2 = br_fill(br_drop(br, n))
  hs_dent(br2, wc, win, lit, ltb, dtb, len,
    Array.get(U32, dst, br_peek(br2, dtb)))

def hs_kind(
  +br: Br, +wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, +ent: U32, +l: U32, +kind: U32
) -> Hs:
  match kind:
    case 0:
      hs_back(put1(win, wc, U32.and(U32.shrn(ent, 8n), 255)), br_drop(br, l),
        lit, ltb, dst, dtb)
    case 1:
      hs_len(br_drop(br, l), wc, win, lit, ltb, dst, dtb, ent)
    case 2:
      HsStop{br_drop(br, l), wc, win, lit, ltb, dst, dtb, HEob{}}
    case _:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HErr{GzCorrupt{}}}

def hs_sym2(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, +ent: U32, +l: U32
) -> Hs:
  match l:
    case 0:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HErr{GzCorrupt{}}}
    case _:
      hs_kind(br, wc, win, lit, ltb, dst, dtb, ent, l,
        U32.and(U32.shrn(ent, 4n), 3))

def hs_sym(
  br: Br, wc: Wc, win: Array<U32>, ltb: U32, dst: Array<U32>, dtb: U32,
  r: Array<U32> & U32
) -> Hs:
  (lit, +ent) = r
  hs_sym2(br, wc, win, lit, ltb, dst, dtb, ent, U32.and(ent, 15))

def hs_room(
  +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, +ltb: U32,
  dst: Array<U32>, dtb: U32, room: Bool
) -> Hs:
  match room:
    case False{}:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HFlush{}}
    case True{}:
      +b2 = br_fill(br)
      hs_sym(b2, wc, win, ltb, dst, dtb, Array.get(U32, lit, br_peek(b2, ltb)))

def hs_gate2(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, rem_ok: Bool, room: Bool
) -> Hs:
  match rem_ok:
    case False{}:
      HsStop{br, wc, win, lit, ltb, dst, dtb, HNeed{}}
    case True{}:
      hs_room(br, wc, win, lit, ltb, dst, dtb, room)

def hs_gate(
  +br: Br, +wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32
) -> Hs:
  hs_gate2(br, wc, win, lit, ltb, dst, dtb, U32.is_ge(br_rem(br), 8),
    U32.is_lt(wc_olen(wc), 262144))

def codes_loop(fuel: Nat, st: Hs) -> Hs:
  match fuel:
    case 0n:
      st
    case 1n+p:
      match st:
        case HsRun{br, wc, win, lit, ltb, dst, dtb}:
          codes_loop(p, hs_gate(br, wc, win, lit, ltb, dst, dtb))
        case HsStop{br, wc, win, lit, ltb, dst, dtb, how}:
          HsStop{br, wc, win, lit, ltb, dst, dtb, how}

# ---- stored blocks -------------------------------------------------------
# After alignment the reader's accumulator is empty; bytes come straight from
# the input list (`MStored{n}` = bytes still to copy).

def ss_put(wp: Wp, +n: U32, +acc: U32, +cnt: U32, t: List<&2, U32>, +rem: U32) -> Ss:
  match wp:
    case MkWp{win, wc}:
      SsRun{U32.sub(n, 1), MkBr{acc, cnt, t, U32.sub(rem, 1)}, wc, win}

def ss_step2(
  +n: U32, +acc: U32, +cnt: U32, +rem: U32, inp: List<&2, U32>, +wc: Wc,
  win: Array<U32>
) -> Ss:
  match inp:
    case Nil{}:
      SsStop{n, MkBr{acc, cnt, Nil{}, rem}, wc, win, HNeed{}}
    case +b <> t:
      ss_put(put1(win, wc, b), n, acc, cnt, t, rem)

def ss_step(+n: U32, br: Br, wc: Wc, win: Array<U32>) -> Ss:
  match br:
    case MkBr{acc, cnt, inp, +rem}:
      ss_step2(n, acc, cnt, rem, inp, wc, win)

def ss_gate2(+n: U32, br: Br, wc: Wc, win: Array<U32>, nz: Bool, room: Bool) -> Ss:
  match nz:
    case True{}:
      SsStop{n, br, wc, win, HEob{}}
    case False{}:
      match room:
        case False{}:
          SsStop{n, br, wc, win, HFlush{}}
        case True{}:
          ss_step(n, br, wc, win)

def ss_gate(+n: U32, br: Br, +wc: Wc, win: Array<U32>) -> Ss:
  ss_gate2(n, br, wc, win, U32.is_zero(n), U32.is_lt(wc_olen(wc), 262144))

def ss_loop(fuel: Nat, st: Ss) -> Ss:
  match fuel:
    case 0n:
      st
    case 1n+p:
      match st:
        case SsRun{n, br, wc, win}:
          ss_loop(p, ss_gate(n, br, wc, win))
        case SsStop{n, br, wc, win, how}:
          SsStop{n, br, wc, win, how}

# ---- engine ----------------------------------------------------------------

def eng_new() -> Eng:
  MkEng{br_new(Nil{}, 0), wc_new(), win_new(), Array.new(U32, 0n, 0), 0,
    Array.new(U32, 0n, 0), 0, MBlk{}, False{}, SpRun{}}

# A dead engine carrying an error (everything else is dropped).
def eng_fail(e: GzErr) -> Eng:
  MkEng{br_new(Nil{}, 0), wc_new(), Array.new(U32, 0n, 0),
    Array.new(U32, 0n, 0), 0, Array.new(U32, 0n, 0), 0, MBlk{}, False{},
    SpErr{e}}

def eng_how3(
  +md: Md, +sp: Sp, br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>,
  ltb: U32, dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}

def eng_eob(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match bfin:
    case True{}:
      MkEng{br, wc, win, lit, ltb, dst, dtb, MFin{}, True{}, SpDone{}}
    case False{}:
      MkEng{br, wc, win, lit, ltb, dst, dtb, MBlk{}, False{}, SpRun{}}

# Map the reason a data/stored loop stopped onto the engine mode.
def eng_how(
  how: Hw, md: Md, br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>,
  ltb: U32, dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match how:
    case HEob{}:
      eng_eob(br, wc, win, lit, ltb, dst, dtb, bfin)
    case HNeed{}:
      eng_how3(md, SpNeed{}, br, wc, win, lit, ltb, dst, dtb, bfin)
    case HFlush{}:
      eng_how3(md, SpFlush{}, br, wc, win, lit, ltb, dst, dtb, bfin)
    case HErr{e}:
      eng_fail(e)

def eng_of_hs(hs: Hs, bfin: Bool) -> Eng:
  match hs:
    case HsRun{br, wc, win, lit, ltb, dst, dtb}:
      eng_fail(GzCorrupt{})
    case HsStop{br, wc, win, lit, ltb, dst, dtb, how}:
      eng_how(how, MCodes{}, br, wc, win, lit, ltb, dst, dtb, bfin)

def run_codes(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, bfin: Bool, fuel: Nat
) -> Eng:
  eng_of_hs(codes_loop(fuel, HsRun{br, wc, win, lit, ltb, dst, dtb}), bfin)

def eng_of_ss2(
  ss: Ss, lit: Array<U32>, ltb: U32, dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match ss:
    case SsRun{n, br, wc, win}:
      eng_fail(GzCorrupt{})
    case SsStop{n, br, wc, win, how}:
      eng_how(how, MStored{n}, br, wc, win, lit, ltb, dst, dtb, bfin)

def run_stored(
  +n: U32, br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, bfin: Bool, fuel: Nat
) -> Eng:
  eng_of_ss2(ss_loop(fuel, SsRun{n, br, wc, win}), lit, ltb, dst, dtb, bfin)

# ---- block headers ---------------------------------------------------------

def stored4(
  ok: Bool, +len: U32, +acc: U32, +cnt: U32, t: List<&2, U32>, +rem: U32,
  wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32, dst: Array<U32>,
  dtb: U32, bfin: Bool
) -> Eng:
  match ok:
    case False{}:
      eng_fail(GzCorrupt{})
    case True{}:
      MkEng{MkBr{acc, cnt, t, U32.sub(rem, 4)}, wc, win, lit, ltb, dst, dtb,
        MStored{len}, bfin, SpRun{}}

def stored3(
  +len: U32, +nlen: U32, +acc: U32, +cnt: U32, t: List<&2, U32>, +rem: U32,
  wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32, dst: Array<U32>,
  dtb: U32, bfin: Bool
) -> Eng:
  stored4(U32.is_eq(U32.xor(len, nlen), 65535), len, acc, cnt, t, rem, wc,
    win, lit, ltb, dst, dtb, bfin)

def stored2(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match br:
    case MkBr{acc, cnt, inp, rem}:
      match inp:
        case +l0 <> (+l1 <> (+l2 <> (+l3 <> t))):
          stored3(U32.or(l0, U32.shln(l1, 8n)), U32.or(l2, U32.shln(l3, 8n)),
            acc, cnt, t, rem, wc, win, lit, ltb, dst, dtb, bfin)
        case _:
          eng_fail(GzTruncated{})

def zrep(+v: U32, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      v <> zrep(v, p)

def fixed_lit_lens() -> List<&2, U32>:
  B.list_cat(zrep(8, 144n), B.list_cat(zrep(9, 112n),
    B.list_cat(zrep(7, 24n), zrep(8, 8n))))

def tabs_ok(
  lok: Bool, dok: Bool, br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>,
  ltb: U32, dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match lok:
    case False{}:
      eng_fail(GzCorrupt{})
    case True{}:
      match dok:
        case False{}:
          eng_fail(GzCorrupt{})
        case True{}:
          MkEng{br, wc, win, lit, ltb, dst, dtb, MCodes{}, bfin, SpRun{}}

def tabs_eng(
  tl: Tab, td: Tab, br: Br, wc: Wc, win: Array<U32>, bfin: Bool
) -> Eng:
  match tl:
    case MkTab{lit, ltb, lok}:
      match td:
        case MkTab{dst, dtb, dok}:
          tabs_ok(lok, dok, br, wc, win, lit, ltb, dst, dtb, bfin)

def fixed_blk(br: Br, wc: Wc, win: Array<U32>, bfin: Bool) -> Eng:
  tabs_eng(build_tab(fixed_lit_lens(), 0), build_tab(zrep(5, 32n), 1), br, wc,
    win, bfin)

# Dynamic header: code-length alphabet, then the literal/distance lengths.
def cl_order() -> List<&2, U32>:
  [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

def set_at(xs: List<&2, U32>, +i: Nat, +v: U32) -> List<&2, U32>:
  match xs i:
    case Nil{} _:
      Nil{}
    case _ <> t 0n:
      v <> t
    case h <> t 1n+p:
      h <> set_at(t, p, v)

def cl_loop(k: Nat, +i: Nat, +br: Br, cl: List<&2, U32>) -> Clr:
  match k:
    case 0n:
      MkClr{br, cl}
    case 1n+p:
      +b = br_fill(br)
      cl_loop(p, Nat.add(i, 1n), br_drop(b, 3),
        set_at(cl, U32.to_nat(nth(cl_order(), i)), br_peek(b, 3)))

def repl(k: Nat, +v: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      repl(p, v, v <> acc)

def ls_rep(
  br: Br, ctab: Array<U32>, ctb: U32, acc: List<&2, U32>, +n: U32,
  total: U32, +v: U32, +rep: U32, ok: Bool
) -> Ls:
  match ok:
    case False{}:
      LsErr{GzCorrupt{}}
    case True{}:
      LsRun{br, ctab, ctb, repl(U32.to_nat(rep), v, acc), U32.add(n, rep),
        total, v}

def ls_sym2(
  +b: Br, ctab: Array<U32>, ctb: U32, acc: List<&2, U32>, +n: U32,
  +total: U32, +prev: U32, +sym: U32
) -> Ls:
  match sym:
    case 16:
      ls_rep(br_drop(b, 2), ctab, ctb, acc, n, total, prev,
        U32.add(3, br_peek(b, 2)),
        Bool.and(U32.is_ne(n, 0),
          U32.is_le(U32.add(n, U32.add(3, br_peek(b, 2))), total)))
    case 17:
      ls_rep(br_drop(b, 3), ctab, ctb, acc, n, total, 0,
        U32.add(3, br_peek(b, 3)),
        U32.is_le(U32.add(n, U32.add(3, br_peek(b, 3))), total))
    case 18:
      ls_rep(br_drop(b, 7), ctab, ctb, acc, n, total, 0,
        U32.add(11, br_peek(b, 7)),
        U32.is_le(U32.add(n, U32.add(11, br_peek(b, 7))), total))
    case _:
      LsRun{b, ctab, ctb, sym <> acc, U32.inc(n), total, sym}

def ls_ent2(
  +l: U32, +ent: U32, +b: Br, ctab: Array<U32>, ctb: U32,
  acc: List<&2, U32>, +n: U32, total: U32, prev: U32
) -> Ls:
  match l:
    case 0:
      LsErr{GzCorrupt{}}
    case _:
      ls_sym2(br_drop(b, l), ctab, ctb, acc, n, total, prev,
        U32.and(U32.shrn(ent, 8n), 255))

def ls_ent(
  +b: Br, ctb: U32, acc: List<&2, U32>, +n: U32, total: U32, prev: U32,
  r: Array<U32> & U32
) -> Ls:
  (ctab, +ent) = r
  ls_ent2(U32.and(ent, 15), ent, b, ctab, ctb, acc, n, total, prev)

def ls_go2(
  +b: Br, ctab: Array<U32>, +ctb: U32, acc: List<&2, U32>, n: U32,
  total: U32, prev: U32
) -> Ls:
  ls_ent(b, ctb, acc, n, total, prev, Array.get(U32, ctab, br_peek(b, ctb)))

def ls_go(
  br: Br, ctab: Array<U32>, +ctb: U32, acc: List<&2, U32>, n: U32,
  total: U32, prev: U32, done: Bool
) -> Ls:
  match done:
    case True{}:
      LsEnd{br, acc}
    case False{}:
      ls_go2(br_fill(br), ctab, ctb, acc, n, total, prev)

def ls_loop(fuel: Nat, st: Ls) -> Ls:
  match fuel:
    case 0n:
      LsErr{GzCorrupt{}}
    case 1n+p:
      match st:
        case LsRun{br, ctab, ctb, acc, +n, +total, prev}:
          ls_loop(p, ls_go(br, ctab, ctb, acc, n, total, prev,
            U32.is_eq(n, total)))
        case LsEnd{br, acc}:
          LsEnd{br, acc}
        case LsErr{e}:
          LsErr{e}

def dyn_tabs2(
  eob_ok: Bool, ll: List<&2, U32>, dl: List<&2, U32>, br: Br, wc: Wc,
  win: Array<U32>, bfin: Bool
) -> Eng:
  match eob_ok:
    case False{}:
      eng_fail(GzCorrupt{})
    case True{}:
      tabs_eng(build_tab(ll, 0), build_tab(dl, 1), br, wc, win, bfin)

# After the lengths: split, validate, build both tables.
def dyn_tabs(
  +lens: List<&2, U32>, +hlit: U32, +hdist: U32, br: Br, wc: Wc,
  win: Array<U32>, bfin: Bool
) -> Eng:
  +ll = B.slice_list(lens, 0n, U32.to_nat(hlit))
  +dl = B.slice_list(lens, U32.to_nat(hlit), U32.to_nat(hdist))
  dyn_tabs2(U32.is_ne(nth(ll, 256n), 0), ll, dl, br, wc, win, bfin)

def dyn_ls(
  ls: Ls, hlit: U32, hdist: U32, wc: Wc, win: Array<U32>, bfin: Bool
) -> Eng:
  match ls:
    case LsRun{br, ctab, ctb, acc, n, total, prev}:
      eng_fail(GzCorrupt{})
    case LsErr{e}:
      eng_fail(e)
    case LsEnd{br, acc}:
      dyn_tabs(rev(acc, Nil{}), hlit, hdist, br, wc, win, bfin)

def dyn_cl3(
  ok: Bool, br: Br, ctab: Array<U32>, ctb: U32, +hlit: U32, +hdist: U32,
  wc: Wc, win: Array<U32>, bfin: Bool
) -> Eng:
  match ok:
    case False{}:
      eng_fail(GzCorrupt{})
    case True{}:
      dyn_ls(ls_loop(U32.to_nat(U32.add(U32.add(hlit, hdist), 8)),
        LsRun{br, ctab, ctb, Nil{}, 0, U32.add(hlit, hdist), 0}), hlit, hdist,
        wc, win, bfin)

def dyn_cl2(
  tab: Tab, +br: Br, +hlit: U32, +hdist: U32, wc: Wc, win: Array<U32>,
  bfin: Bool
) -> Eng:
  match tab:
    case MkTab{ctab, ctb, ok}:
      dyn_cl3(ok, br, ctab, ctb, hlit, hdist, wc, win, bfin)

def dyn_cl(
  c: Clr, +hlit: U32, +hdist: U32, wc: Wc, win: Array<U32>, bfin: Bool
) -> Eng:
  match c:
    case MkClr{br, cl}:
      dyn_cl2(build_tab(cl, 2), br, hlit, hdist, wc, win, bfin)

def dyn2(
  br: Br, +hlit: U32, +hdist: U32, +hclen: U32, wc: Wc, win: Array<U32>,
  bfin: Bool, ok: Bool
) -> Eng:
  match ok:
    case False{}:
      eng_fail(GzCorrupt{})
    case True{}:
      dyn_cl(cl_loop(U32.to_nat(hclen), 0n, br, zeros(19n)), hlit, hdist, wc,
        win, bfin)

def dyn1(
  +br: Br, wc: Wc, win: Array<U32>, bfin: Bool
) -> Eng:
  +hlit = U32.add(br_peek(br, 5), 257)
  +b1 = br_drop(br, 5)
  +hdist = U32.add(br_peek(b1, 5), 1)
  +b2 = br_drop(b1, 5)
  +hclen = U32.add(br_peek(b2, 4), 4)
  dyn2(br_drop(b2, 4), hlit, hdist, hclen, wc, win, bfin,
    Bool.and(U32.is_le(hlit, 286), U32.is_le(hdist, 30)))

def blk_kind(
  +ty: U32, +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, bfin: Bool
) -> Eng:
  match ty:
    case 0:
      stored2(br_align(br), wc, win, lit, ltb, dst, dtb, bfin)
    case 1:
      fixed_blk(br, wc, win, bfin)
    case 2:
      dyn1(br_fill(br), wc, win, bfin)
    case _:
      eng_fail(GzCorrupt{})

def blk_hdr2(
  +b: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32
) -> Eng:
  +b1 = br_drop(b, 1)
  blk_kind(br_peek(b1, 2), br_drop(b1, 2), wc, win, lit, ltb, dst, dtb,
    U32.is_eq(br_peek(b, 1), 1))

# Block header: BFINAL, BTYPE (needs >= BLKGUARD bytes buffered).
def blk_hdr(
  br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32
) -> Eng:
  blk_hdr2(br_fill(br), wc, win, lit, ltb, dst, dtb)

def eng_blk(
  +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, ok: Bool
) -> Eng:
  match ok:
    case True{}:
      blk_hdr(br, wc, win, lit, ltb, dst, dtb)
    case False{}:
      MkEng{br, wc, win, lit, ltb, dst, dtb, MBlk{}, False{}, SpNeed{}}

# One engine transition by mode.
def eng_step(
  +br: Br, wc: Wc, win: Array<U32>, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, md: Md, bfin: Bool
) -> Eng:
  match md:
    case MBlk{}:
      eng_blk(br, wc, win, lit, ltb, dst, dtb, U32.is_ge(br_rem(br), 400))
    case MCodes{}:
      run_codes(br, wc, win, lit, ltb, dst, dtb, bfin,
        Nat.add(Nat.mul(8n, U32.to_nat(br_rem(br))), 64n))
    case MStored{n}:
      run_stored(n, br, wc, win, lit, ltb, dst, dtb, bfin,
        Nat.add(U32.to_nat(br_rem(br)), 8n))
    case MFin{}:
      MkEng{br, wc, win, lit, ltb, dst, dtb, MFin{}, True{}, SpDone{}}

def eng_loop(fuel: Nat, e: Eng) -> Eng:
  match fuel:
    case 0n:
      e
    case 1n+p:
      match e:
        case MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}:
          match sp:
            case SpRun{}:
              eng_loop(p, eng_step(br, wc, win, lit, ltb, dst, dtb, md, bfin))
            case _:
              MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}

# ---- engine accessors for the container --------------------------------------

def eng_take_br(e: Eng) -> Eng & Br:
  match e:
    case MkEng{+br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}:
      (MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}, br)

# Install the reader and resume (a stopped engine runs again).
def eng_set_br(e: Eng, br: Br) -> Eng:
  match e:
    case MkEng{_, wc, win, lit, ltb, dst, dtb, md, bfin, _}:
      MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, SpRun{}}

def eng_sp(e: Eng) -> Eng & Sp:
  match e:
    case MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, +sp}:
      (MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}, sp)

def eng_wpos(e: Eng) -> Eng & U32:
  match e:
    case MkEng{br, +wc, win, lit, ltb, dst, dtb, md, bfin, sp}:
      (MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}, wc_wpos(wc))

# New member: block mode, nothing in the window yet (distances may not reach
# into the previous member).
def eng_member(e: Eng) -> Eng:
  match e:
    case MkEng{br, MkWc{wpos, _, olen}, win, lit, ltb, dst, dtb, _, _, _}:
      MkEng{br, MkWc{wpos, 0, olen}, win, lit, ltb, dst, dtb, MBlk{},
        False{}, SpRun{}}

def ob_crc2(r: Array<U32> & U32, cs: C.CrcSt) -> Ob:
  (win, +b) = r
  MkOb{win, C.crc_next(b, cs)}

def ob_crc_step(+i: U32, ob: Ob) -> Ob:
  match ob:
    case MkOb{win, cs}:
      ob_crc2(Array.get(U32, win, U32.add(out_base(), i)), cs)

def ob_crc(k: Nat, +i: U32, ob: Ob) -> Ob:
  match k:
    case 0n:
      ob
    case 1n+p:
      ob_crc(p, U32.inc(i), ob_crc_step(i, ob))

def ob_list2(r: Array<U32> & U32, acc: List<&2, U32>) -> Ol:
  (win, +b) = r
  MkOl{win, b <> acc}

def ob_list_step(+i: U32, ol: Ol) -> Ol:
  match ol:
    case MkOl{win, acc}:
      ob_list2(Array.get(U32, win, U32.add(out_base(), i)), acc)

# Build the list back to front (index n-1 down to 0).
def ob_list(k: Nat, +i: U32, ol: Ol) -> Ol:
  match k:
    case 0n:
      ol
    case 1n+p:
      ob_list(p, U32.sub(i, 1), ob_list_step(i, ol))

def eng_flush4(
  ol: Ol, cs: C.CrcSt, br: Br, wc: Wc, lit: Array<U32>, ltb: U32,
  dst: Array<U32>, dtb: U32, md: Md, bfin: Bool, sp: Sp, +n: U32
) -> Eng & (C.CrcSt & (List<&2, U32> & U32)):
  match ol:
    case MkOl{win, acc}:
      (MkEng{br, wc, win, lit, ltb, dst, dtb, md, bfin, sp}, (cs, (acc, n)))

def eng_flush3(
  ob: Ob, br: Br, wc: Wc, lit: Array<U32>, ltb: U32, dst: Array<U32>,
  dtb: U32, md: Md, bfin: Bool, sp: Sp, +n: U32
) -> Eng & (C.CrcSt & (List<&2, U32> & U32)):
  match ob:
    case MkOb{win, cs}:
      eng_flush4(ob_list(U32.to_nat(n), U32.sub(n, 1),
        MkOl{win, Nil{}}), cs, br, wc, lit, ltb, dst, dtb, md, bfin, sp, n)

def eng_flush2(
  br: Br, win: Array<U32>, lit: Array<U32>, ltb: U32, dst: Array<U32>,
  dtb: U32, md: Md, bfin: Bool, sp: Sp, +wpos: U32, +wfill: U32, +olen: U32,
  cs: C.CrcSt
) -> Eng & (C.CrcSt & (List<&2, U32> & U32)):
  eng_flush3(ob_crc(U32.to_nat(olen), 0, MkOb{win, cs}), br,
    MkWc{wpos, wfill, 0}, lit, ltb, dst, dtb, md, bfin, sp, olen)

# Take the output produced so far (forward order) and its length, folding its
# CRC-32 into `cs`.
def eng_flush(e: Eng, cs: C.CrcSt) -> Eng & (C.CrcSt & (List<&2, U32> & U32)):
  match e:
    case MkEng{br, MkWc{wpos, wfill, olen}, win, lit, ltb, dst, dtb, md, bfin,
        sp}:
      eng_flush2(br, win, lit, ltb, dst, dtb, md, bfin, sp, wpos, wfill, olen,
        cs)

def eng_run(e: Eng, fuel: Nat) -> Eng:
  eng_loop(fuel, e)
