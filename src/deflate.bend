# Module: Deflate — pure DEFLATE (RFC 1951) compressor, segment based.
#
# `seg_compress(dict, seg)` compresses one independent segment (up to 128 KiB)
# given up to 32 KiB of preceding input as a read-only match dictionary, and
# returns whole bytes: dynamic/fixed/stored blocks followed by an empty stored
# block (sync flush), so segments concatenate on byte boundaries and can be
# computed in parallel (src/gzcomp.bend joins them).  Per segment: greedy
# LZ77 over hash chains, then per block (<= 16384 tokens) the cheapest of
# stored / fixed / dynamic Huffman (canonical codes, lengths <= 15, repeat
# codes 16/17/18).  All state lives in two flat arrays: `mem` (input window,
# hash heads/prev, token buffer) and `aux` (code and frequency tables).
#
# Layout of `mem` (2^18 words): input [0, 163840), head at 163840 (2^15 hash
# buckets, value = position + 1, 0 = empty), prev at 196608 (indexed by
# position & 32767), tokens at 229376.  Layout of `aux` (2^11 words): see aux_*.

import Base
import ./bytes.bend as B
import ./inflate.bend as I
import ./crc.bend as C

# ---- layout ----------------------------------------------------------------

type Bw is Data:
  MkBw{acc: U32, cnt: U32, out: List<&2, U32>}

type WS is Type:
  MkWS{nc: List<&2, U32>, aux: Array<U32>}

type Ml is Type:
  MlRun{mem: Array<U32>, len: U32}
  MlStop{mem: Array<U32>, len: U32}

type Sr is Type:
  SrRun{mem: Array<U32>, cand: U32, chain: U32, blen: U32, bdist: U32}
  SrStop{mem: Array<U32>, blen: U32, bdist: U32}

type Ms is Type:
  MsRun{mem: Array<U32>, p: U32, end: U32, ntok: U32, bstart: U32}
  MsFull{mem: Array<U32>, p: U32, end: U32, ntok: U32, bstart: U32}
  MsEnd{mem: Array<U32>, p: U32, end: U32, ntok: U32, bstart: U32}

type Sx is Type:
  MkSx{mem: Array<U32>, blen: U32, bdist: U32}

type Fc is Type:
  MkFc{mem: Array<U32>, aux: Array<U32>, xb: U32}

# Read n consecutive aux words into a list (in order).
type Rr is Type:
  MkRr{aux: Array<U32>, acc: List<&2, U32>}

type HT is Data:
  HLeaf{sym: U32}
  HNode{l: HT, r: HT}

type Qn is Data:
  MkQn{w: U32, t: HT}

type Hq is Data:
  MkHq{lv: List<&2, Qn>, iv: List<&2, Qn>}

type Pm is Data:
  MkPm{q: Qn, lv: List<&2, Qn>, iv: List<&2, Qn>}

type Bl is Data:
  BlTry{fr: List<&2, U32>}
  BlOk{lens: List<&2, U32>}

type Ro is Data:
  RoRun{xs: List<&2, U32>, n: U32}
  RoEnd{n: U32, rest: List<&2, U32>}

type Rs is Data:
  RsRun{lens: List<&2, U32>, acc: List<&2, U32>}
  RsEnd{acc: List<&2, U32>}

type Em is Type:
  MkEm{mem: Array<U32>, aux: Array<U32>, bw: Bw}

# Emit the RLE'd lengths with the code-length codes at aux[a_clc].
type Rh is Type:
  MkRh{aux: Array<U32>, bw: Bw}

type Dy is Data:
  MkDy{ll: List<&2, U32>, dl: List<&2, U32>, hlit: U32, hdist: U32,
    rle: List<&2, U32>, cll: List<&2, U32>, hclen: U32, cdyn: U32,
    cfix: U32}

type Sb is Type:
  MkSb{mem: Array<U32>, bw: Bw}

type Sg is Type:
  SgRun{mem: Array<U32>, p: U32, end: U32, ntok: U32, bstart: U32,
    aux: Array<U32>, bw: Bw}
  SgDone{bw: Bw}

# Result of compressing one segment: the DEFLATE bytes, the CRC-32 of the
# segment's input bytes and the segment length.
type Sres is Data:
  MkSres{out: List<&2, U32>, crc: U32, slen: U32}

# Load a segment into the input window while folding its CRC-32.
type Ld is Type:
  MkLd{mem: Array<U32>, cs: C.CrcSt, n: U32}

def m_head() -> U32:
  163840

def m_prev() -> U32:
  196608

def m_tok() -> U32:
  229376

def a_lenc() -> U32:
  0

def a_disc() -> U32:
  256

def a_flit() -> U32:
  768

def a_fdst() -> U32:
  1056

def a_clit() -> U32:
  1088

def a_cdst() -> U32:
  1376

def a_fixl() -> U32:
  1408

def a_fixd() -> U32:
  1696

# ---- bit writer (LSB first), output bytes accumulate reversed ------------------

def bw_new() -> Bw:
  MkBw{0, 0, Nil{}}

# Emit one byte when at least eight bits are buffered.
def bw_step2(+acc: U32, +cnt: U32, out: List<&2, U32>, ge: Bool) -> Bw:
  match ge:
    case True{}:
      MkBw{U32.shrn(acc, 8n), U32.sub(cnt, 8), U32.and(acc, 255) <> out}
    case False{}:
      MkBw{acc, cnt, out}

def bw_step(bw: Bw) -> Bw:
  match bw:
    case MkBw{acc, +cnt, out}:
      bw_step2(acc, cnt, out, U32.is_ge(cnt, 8))

# Append the low `n` bits (n <= 16) of `v`.
def bw_put(bw: Bw, +v: U32, +n: U32) -> Bw:
  match bw:
    case MkBw{+acc, +cnt, out}:
      bw_step(bw_step(bw_step(MkBw{U32.or(acc, U32.shln(v, U32.to_nat(cnt))),
        U32.add(cnt, n), out})))

def bw_align2(bw: Bw, +n: U32) -> Bw:
  bw_put(bw, 0, n)

def bw_align(bw: Bw) -> Bw:
  match bw:
    case MkBw{acc, +cnt, out}:
      bw_align2(MkBw{acc, cnt, out}, U32.and(U32.sub(8, cnt), 7))

def bw_bytes(bw: Bw) -> List<&2, U32>:
  match bw:
    case MkBw{_, _, out}:
      out

def bw_cnt(bw: Bw) -> U32:
  match bw:
    case MkBw{_, c, _}:
      c

# ---- aux tables ----------------------------------------------------------------

def lc_code2(+v: U32, +nb: Nat) -> U32:
  U32.add(U32.mul(4, U32.sub(U32.from_nat(nb), 1)),
    U32.and(U32.shrn(v, Nat.sub(nb, 2n)), 3))

# Length code for v = len - 3 (0..255): code | extra-bit count << 8.
def lc_code(+v: U32) -> U32:
  Bool.pick(U32, U32.is_lt(v, 8), v,
    Bool.pick(U32, U32.is_eq(v, 255), 28, lc_code2(v, U32.log2(v))))

def lc_entry(+v: U32) -> U32:
  +c = lc_code(v)
  U32.or(c, U32.shln(I.len_extra(c), 8n))

# Distance code for d = dist - 1 (0..32767).
def dc_code2(+d: U32, +nb: Nat) -> U32:
  U32.add(U32.mul(2, U32.from_nat(nb)),
    U32.and(U32.shrn(d, Nat.sub(nb, 1n)), 1))

def dc_code(+d: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 4), d, dc_code2(d, U32.log2(d)))

def dc_entry(+d: U32) -> U32:
  +c = dc_code(d)
  U32.or(c, U32.shln(I.dist_extra(c), 8n))

# DISC is indexed by d for d < 256 and by 256 + (d >> 7) beyond.
def dc_rep(+e: U32) -> U32:
  Bool.pick(U32, U32.is_lt(e, 256), e, U32.shln(U32.sub(e, 256), 7n))

def fill_lenc(k: Nat, +v: U32, aux: Array<U32>) -> Array<U32>:
  match k:
    case 0n:
      aux
    case 1n+p:
      fill_lenc(p, U32.inc(v), Array.set(U32, aux, U32.add(a_lenc(), v),
        lc_entry(v)))

def fill_disc(k: Nat, +e: U32, aux: Array<U32>) -> Array<U32>:
  match k:
    case 0n:
      aux
    case 1n+p:
      fill_disc(p, U32.inc(e), Array.set(U32, aux, U32.add(a_disc(), e),
        dc_entry(dc_rep(e))))

def wc_one3(
  nc: List<&2, U32>, aux: Array<U32>, +sym: U32, +base: U32, +h: U32,
  +code: U32
) -> WS:
  MkWS{I.inc_at(nc, U32.to_nat(U32.sub(h, 1))), Array.set(U32, aux,
    U32.add(base, sym), U32.or(U32.shln(I.code_rev(code, h), 4n), h))}

def wc_one2(
  +nc: List<&2, U32>, aux: Array<U32>, +sym: U32, +base: U32, +h: U32,
  zero: Bool
) -> WS:
  match zero:
    case True{}:
      MkWS{nc, Array.set(U32, aux, U32.add(base, sym), 0)}
    case False{}:
      wc_one3(nc, aux, sym, base, h, I.nth(nc, U32.to_nat(U32.sub(h, 1))))

def wc_one(
  ws: WS, +sym: U32, +base: U32, +h: U32, zero: Bool
) -> WS:
  match ws:
    case MkWS{nc, aux}:
      wc_one2(nc, aux, sym, base, h, zero)

# Reversed canonical codes for a length list, stored at aux[base + sym] as
# (revcode << 4) | len.  `nc` holds the first code of each length (index l-1).
def write_codes(
  lens: List<&2, U32>, +sym: U32, +base: U32, ws: WS
) -> WS:
  match lens:
    case Nil{}:
      ws
    case +h <> t:
      write_codes(t, U32.inc(sym), base, wc_one(ws, sym, base, h,
        U32.is_zero(h)))

def ws_aux(ws: WS) -> Array<U32>:
  match ws:
    case MkWS{_, aux}:
      aux

# Canonical first codes per length from the lens list.
def first_codes(+lens: List<&2, U32>) -> List<&2, U32>:
  I.nc_go(15n, 1n, 0, I.bl_fix(I.count_lens(lens, I.zeros(16n))))

def set_codes(+lens: List<&2, U32>, +base: U32, aux: Array<U32>) -> Array<U32>:
  ws_aux(write_codes(lens, 0, base, MkWS{first_codes(lens), aux}))

def fixed_lens_d() -> List<&2, U32>:
  I.zrep(5, 30n)

def aux_init() -> Array<U32>:
  set_codes(fixed_lens_d(), a_fixd(),
    set_codes(I.fixed_lit_lens(), a_fixl(),
      fill_disc(512n, 0, fill_lenc(256n, 0, Array.new(U32, 11n, 0)))))

# ---- LZ77 matcher ----------------------------------------------------------------
# Positions index the input region of `mem`.  head/prev store position + 1.

def tok_max() -> U32:
  16384

def raw_max() -> U32:
  65000

def max_chain() -> U32:
  24

def nice_len() -> U32:
  64

def max_ins() -> U32:
  32

def ml_pick(eq: Bool, mem: Array<U32>, +len: U32) -> Ml:
  match eq:
    case True{}:
      MlRun{mem, U32.inc(len)}
    case False{}:
      MlStop{mem, len}

def ml_cmp2(y: Array<U32> & U32, +len: U32, +x: U32) -> Ml:
  (mem, +yv) = y
  ml_pick(U32.is_eq(x, yv), mem, len)

def ml_y(
  r: Array<U32> & U32, +b: U32, +len: U32
) -> Ml:
  (mem, +x) = r
  ml_cmp2(Array.get(U32, mem, U32.add(b, len)), len, x)

def ml_step2(mem: Array<U32>, +a: U32, +b: U32, +len: U32, room: Bool) -> Ml:
  match room:
    case False{}:
      MlStop{mem, len}
    case True{}:
      ml_y(Array.get(U32, mem, U32.add(a, len)), b, len)

def ml_step(+a: U32, +b: U32, +maxl: U32, ml: Ml) -> Ml:
  match ml:
    case MlRun{mem, +len}:
      ml_step2(mem, a, b, len, U32.is_lt(len, maxl))
    case MlStop{mem, len}:
      MlStop{mem, len}

# Length of the common prefix of input[a..] and input[b..], capped at maxl.
def ml_loop(fuel: Nat, +a: U32, +b: U32, +maxl: U32, ml: Ml) -> Ml:
  match fuel:
    case 0n:
      ml
    case 1n+q:
      ml_loop(q, a, b, maxl, ml_step(a, b, maxl, ml))

def hash3(+b0: U32, +b1: U32, +b2: U32) -> U32:
  U32.shrn(U32.mul(U32.or(b0, U32.or(U32.shln(b1, 8n), U32.shln(b2, 16n))),
    2654435761), 17n)

# ---- hash insertion ----------------------------------------------------------------

# Insert position q (needs q + 3 <= end): prev[q & 32767] = head[h]; head[h] = q + 1.
def ins4(r: Array<U32> & U32, +q: U32, +h: U32) -> Array<U32>:
  (mem, +cand) = r
  Array.set(U32, Array.set(U32, mem, U32.add(m_prev(), U32.and(q, 32767)), cand),
    U32.add(m_head(), h), U32.inc(q))

def ins3(r: Array<U32> & U32, +q: U32, +b0: U32, +b1: U32) -> Array<U32>:
  (mem, +b2) = r
  +h = hash3(b0, b1, b2)
  ins4(Array.get(U32, mem, U32.add(m_head(), h)), q, h)

def ins2(r: Array<U32> & U32, +q: U32, +b0: U32) -> Array<U32>:
  (mem, +b1) = r
  ins3(Array.get(U32, mem, U32.add(q, 2)), q, b0, b1)

def ins1(r: Array<U32> & U32, +q: U32) -> Array<U32>:
  (mem, +b0) = r
  ins2(Array.get(U32, mem, U32.inc(q)), q, b0)

def ins_one2(mem: Array<U32>, +q: U32, ok: Bool) -> Array<U32>:
  match ok:
    case False{}:
      mem
    case True{}:
      ins1(Array.get(U32, mem, q), q)

def ins_one(mem: Array<U32>, +q: U32, +end: U32) -> Array<U32>:
  ins_one2(mem, q, U32.is_le(U32.add(q, 3), end))

def ins_loop(k: Nat, +q: U32, +end: U32, mem: Array<U32>) -> Array<U32>:
  match k:
    case 0n:
      mem
    case 1n+p:
      ins_loop(p, U32.inc(q), end, ins_one(mem, q, end))

# ---- chain search ------------------------------------------------------------------

def sr_prev(r: Array<U32> & U32, chain: U32, blen: U32, bdist: U32) -> Sr:
  (mem, nxt) = r
  SrRun{mem, nxt, chain, blen, bdist}

def ml_mem(ml: Ml) -> Array<U32> & U32:
  match ml:
    case MlRun{mem, +len}:
      (mem, len)
    case MlStop{mem, +len}:
      (mem, len)

def sr_after2(
  r: Array<U32> & U32, +cp: U32, +chain: U32, +blen: U32, +bdist: U32,
  +dist: U32
) -> Sr:
  (mem, +len) = r
  +better = U32.is_gt(len, blen)
  sr_prev(Array.get(U32, mem, U32.add(m_prev(), U32.and(cp, 32767))),
    U32.sub(chain, 1), Bool.pick(U32, better, len, blen),
    Bool.pick(U32, better, dist, bdist))

def sr_step3(
  mem: Array<U32>, +p: U32, +cp: U32, +chain: U32, +blen: U32, +bdist: U32,
  +maxl: U32
) -> Sr:
  sr_after2(ml_mem(ml_loop(U32.to_nat(maxl), cp, p, maxl, MlRun{mem, 0})), cp,
    chain, blen, bdist, U32.sub(p, cp))

def sr_step2(
  mem: Array<U32>, +p: U32, +cand: U32, +chain: U32, +blen: U32,
  +bdist: U32, +maxl: U32, ok: Bool
) -> Sr:
  match ok:
    case False{}:
      SrStop{mem, blen, bdist}
    case True{}:
      sr_step3(mem, p, U32.sub(cand, 1), chain, blen, bdist, maxl)

def sr_step(+p: U32, +maxl: U32, sr: Sr) -> Sr:
  match sr:
    case SrRun{mem, +cand, +chain, +blen, bdist}:
      sr_step2(mem, p, cand, chain, blen, bdist, maxl,
        Bool.and(U32.is_ne(cand, 0), Bool.and(U32.is_ne(chain, 0),
          Bool.and(U32.is_lt(blen, nice_len()),
            U32.is_le(U32.sub(p, U32.sub(cand, 1)), 32768)))))
    case SrStop{mem, blen, bdist}:
      SrStop{mem, blen, bdist}

def sr_loop(k: Nat, +p: U32, +maxl: U32, sr: Sr) -> Sr:
  match k:
    case 0n:
      sr
    case 1n+q:
      sr_loop(q, p, maxl, sr_step(p, maxl, sr))

# ---- greedy tokenizer ----------------------------------------------------------------
# Token words: literal = byte; match = 2^31 | (len - 3) << 16 | (dist - 1).

def sx_of(sr: Sr) -> Sx:
  match sr:
    case SrRun{mem, _, _, blen, bdist}:
      MkSx{mem, blen, bdist}
    case SrStop{mem, blen, bdist}:
      MkSx{mem, blen, bdist}

def tok_set(mem: Array<U32>, +ntok: U32, +t: U32) -> Array<U32>:
  Array.set(U32, mem, U32.add(m_tok(), ntok), t)

def match_tok(+len: U32, +dist: U32) -> U32:
  U32.or(2147483648, U32.or(U32.shln(U32.sub(len, 3), 16n), U32.sub(dist, 1)))

def ms_lit_tail(
  r: Array<U32> & U32, +p: U32, end: U32, +ntok: U32, bstart: U32
) -> Ms:
  (mem, +b) = r
  MsRun{tok_set(mem, ntok, b), U32.inc(p), end, U32.inc(ntok), bstart}

def ins_after2(mem: Array<U32>, +p: U32, +end: U32, +blen: U32, ok: Bool) -> Array<U32>:
  match ok:
    case True{}:
      ins_loop(U32.to_nat(U32.sub(blen, 1)), U32.inc(p), end, mem)
    case False{}:
      mem

def ins_after(
  mem: Array<U32>, +p: U32, +end: U32, +blen: U32
) -> Array<U32>:
  ins_after2(mem, p, end, blen, U32.is_le(blen, max_ins()))

def ms_emit(
  ok: Bool, mem: Array<U32>, +p: U32, +end: U32, +ntok: U32, bstart: U32,
  +b0: U32, +blen: U32, +bdist: U32
) -> Ms:
  match ok:
    case False{}:
      MsRun{tok_set(mem, ntok, b0), U32.inc(p), end, U32.inc(ntok), bstart}
    case True{}:
      MsRun{ins_after(tok_set(mem, ntok, match_tok(blen, bdist)), p, end, blen),
        U32.add(p, blen), end, U32.inc(ntok), bstart}

def ms_f(
  sx: Sx, +p: U32, +end: U32, +ntok: U32, bstart: U32, +b0: U32, +h: U32,
  +cand: U32
) -> Ms:
  match sx:
    case MkSx{mem, +blen, +bdist}:
      ms_emit(Bool.and(U32.is_ge(blen, 3),
        Bool.not(Bool.and(U32.is_eq(blen, 3), U32.is_gt(bdist, 4096)))),
        Array.set(U32, Array.set(U32, mem,
          U32.add(m_prev(), U32.and(p, 32767)), cand),
          U32.add(m_head(), h), U32.inc(p)),
        p, end, ntok, bstart, b0, blen, bdist)

def ms_e(
  r: Array<U32> & U32, +p: U32, +end: U32, +ntok: U32, bstart: U32,
  +b0: U32, +h: U32
) -> Ms:
  (mem, +cand) = r
  ms_f(sx_of(sr_loop(U32.to_nat(max_chain()), p, U32.min(258, U32.sub(end, p)),
    SrRun{mem, cand, max_chain(), 0, 0})), p, end, ntok, bstart, b0, h, cand)

def ms_d(
  r: Array<U32> & U32, +p: U32, +end: U32, +ntok: U32, bstart: U32,
  +b0: U32, +b1: U32
) -> Ms:
  (mem, +b2) = r
  +h = hash3(b0, b1, b2)
  ms_e(Array.get(U32, mem, U32.add(m_head(), h)), p, end, ntok, bstart, b0, h)

def ms_c(
  r: Array<U32> & U32, +p: U32, +end: U32, +ntok: U32, bstart: U32,
  +b0: U32
) -> Ms:
  (mem, +b1) = r
  ms_d(Array.get(U32, mem, U32.add(p, 2)), p, end, ntok, bstart, b0, b1)

def ms_b(
  r: Array<U32> & U32, +p: U32, +end: U32, +ntok: U32, bstart: U32
) -> Ms:
  (mem, +b0) = r
  ms_c(Array.get(U32, mem, U32.inc(p)), p, end, ntok, bstart, b0)

def ms_pos(
  mem: Array<U32>, +p: U32, +end: U32, +ntok: U32, bstart: U32, tail: Bool
) -> Ms:
  match tail:
    case True{}:
      ms_lit_tail(Array.get(U32, mem, p), p, end, ntok, bstart)
    case False{}:
      ms_b(Array.get(U32, mem, p), p, end, ntok, bstart)

def ms_gate3(
  mem: Array<U32>, +p: U32, +end: U32, ntok: U32, bstart: U32, full: Bool
) -> Ms:
  match full:
    case True{}:
      MsFull{mem, p, end, ntok, bstart}
    case False{}:
      ms_pos(mem, p, end, ntok, bstart, U32.is_lt(U32.sub(end, p), 3))

def ms_gate2(
  mem: Array<U32>, +p: U32, +end: U32, +ntok: U32, +bstart: U32, done: Bool,
  full: Bool
) -> Ms:
  match done:
    case True{}:
      MsEnd{mem, p, end, ntok, bstart}
    case False{}:
      ms_gate3(mem, p, end, ntok, bstart, full)

def ms_step(st: Ms) -> Ms:
  match st:
    case MsRun{mem, +p, +end, +ntok, +bstart}:
      ms_gate2(mem, p, end, ntok, bstart, U32.is_ge(p, end),
        Bool.or(U32.is_ge(ntok, tok_max()),
          U32.is_ge(U32.sub(p, bstart), raw_max())))
    case MsFull{mem, p, end, ntok, bstart}:
      MsFull{mem, p, end, ntok, bstart}
    case MsEnd{mem, p, end, ntok, bstart}:
      MsEnd{mem, p, end, ntok, bstart}

def ms_loop(k: Nat, st: Ms) -> Ms:
  match k:
    case 0n:
      st
    case 1n+q:
      ms_loop(q, ms_step(st))

# ---- frequencies -------------------------------------------------------------------

def a_clc() -> U32:
  1728

def aux_inc2(r: Array<U32> & U32, +idx: U32) -> Array<U32>:
  (aux, +v) = r
  Array.set(U32, aux, idx, U32.inc(v))

def aux_inc(aux: Array<U32>, +idx: U32) -> Array<U32>:
  aux_inc2(Array.get(U32, aux, idx), idx)

def aux_zero(k: Nat, +idx: U32, aux: Array<U32>) -> Array<U32>:
  match k:
    case 0n:
      aux
    case 1n+p:
      aux_zero(p, U32.inc(idx), Array.set(U32, aux, idx, 0))

def dindex(+d: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 256), d, U32.add(256, U32.shrn(d, 7n)))

def fc_dist(
  r: Array<U32> & U32, mem: Array<U32>, +xb: U32
) -> Fc:
  (aux, +dc) = r
  MkFc{mem, aux_inc(aux, U32.add(a_fdst(), U32.and(dc, 255))),
    U32.add(xb, U32.and(U32.shrn(dc, 8n), 255))}

def fc_len(
  r: Array<U32> & U32, mem: Array<U32>, +d: U32, +xb: U32
) -> Fc:
  (aux, +lc) = r
  fc_dist(Array.get(U32, aux_inc(aux, U32.add(a_flit(),
    U32.add(257, U32.and(lc, 255)))), U32.add(a_disc(), dindex(d))), mem,
    U32.add(xb, U32.and(U32.shrn(lc, 8n), 255)))

def fc_tok2(
  mem: Array<U32>, aux: Array<U32>, +xb: U32, +t: U32, lit: Bool
) -> Fc:
  match lit:
    case True{}:
      MkFc{mem, aux_inc(aux, U32.add(a_flit(), t)), xb}
    case False{}:
      fc_len(Array.get(U32, aux, U32.add(a_lenc(), U32.and(U32.shrn(t, 16n), 255))),
        mem, U32.and(t, 32767), xb)

def fc_tok(r: Array<U32> & U32, aux: Array<U32>, xb: U32) -> Fc:
  (mem, +t) = r
  fc_tok2(mem, aux, xb, t, U32.is_lt(t, 256))

def fc_step(+i: U32, fc: Fc) -> Fc:
  match fc:
    case MkFc{mem, aux, xb}:
      fc_tok(Array.get(U32, mem, U32.add(m_tok(), i)), aux, xb)

def fc_loop(k: Nat, +i: U32, fc: Fc) -> Fc:
  match k:
    case 0n:
      fc
    case 1n+p:
      fc_loop(p, U32.inc(i), fc_step(i, fc))

def rr_step2(r: Array<U32> & U32, acc: List<&2, U32>) -> Rr:
  (aux, v) = r
  MkRr{aux, v <> acc}

def rr_step(+i: U32, rr: Rr) -> Rr:
  match rr:
    case MkRr{aux, acc}:
      rr_step2(Array.get(U32, aux, i), acc)

def rd_loop(k: Nat, +i: U32, rr: Rr) -> Rr:
  match k:
    case 0n:
      rr
    case 1n+p:
      rd_loop(p, U32.inc(i), rr_step(i, rr))

def rr_done(rr: Rr) -> Array<U32> & List<&2, U32>:
  match rr:
    case MkRr{aux, acc}:
      (aux, I.rev(acc, Nil{}))

def rd_range(n: Nat, +i: U32, aux: Array<U32>) -> Array<U32> & List<&2, U32>:
  rr_done(rd_loop(n, i, MkRr{aux, Nil{}}))

# ---- sorting (merge sort on U32 keys) -------------------------------------------------

def le_h(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> _:
      match ys:
        case Nil{}:
          True{}
        case +y <> _:
          U32.is_le(x, y)

def merge(
  fuel: Nat, +xs: List<&2, U32>, +ys: List<&2, U32>, le: Bool
) -> List<&2, U32>:
  match fuel:
    case 0n:
      B.list_cat(xs, ys)
    case 1n+p:
      match xs:
        case Nil{}:
          ys
        case +x <> xt:
          match ys:
            case Nil{}:
              x <> xt
            case +y <> yt:
              match le:
                case True{}:
                  x <> merge(p, xt, y <> yt, le_h(xt, y <> yt))
                case False{}:
                  y <> merge(p, x <> xt, yt, le_h(x <> xt, yt))

def merge_go(fuel: Nat, +xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  merge(fuel, xs, ys, le_h(xs, ys))

def msort(+fuel: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case +x <> +t:
          match t:
            case Nil{}:
              x <> Nil{}
            case _ <> _:
              merge_go(Nat.add(List.length(&2, U32, x <> t), 1n),
                msort(p, List.take(&2, U32, x <> t,
                  Nat.div(List.length(&2, U32, x <> t), 2n))),
                msort(p, List.drop(&2, U32, x <> t,
                  Nat.div(List.length(&2, U32, x <> t), 2n))))

def sort_u32(+xs: List<&2, U32>) -> List<&2, U32>:
  msort(List.length(&2, U32, xs), xs)

# ---- Huffman code lengths ------------------------------------------------------------
# Two-queue Huffman over keys (freq << 9 | sym), then depths by tree walk.
# Lengths over the limit are fixed by flattening the frequencies and retrying.

def qn_w(q: Qn) -> U32:
  match q:
    case MkQn{w, _}:
      w

def mk_leaves(+keys: List<&2, U32>) -> List<&2, Qn>:
  match keys:
    case Nil{}:
      Nil{}
    case +k <> t:
      MkQn{U32.shrn(k, 9n), HLeaf{U32.and(k, 511)}} <> mk_leaves(t)

def app1(+xs: List<&2, Qn>, +x: Qn) -> List<&2, Qn>:
  match xs:
    case Nil{}:
      x <> Nil{}
    case +h <> t:
      h <> app1(t, x)

def pop_both(
  +x: Qn, +lt: List<&2, Qn>, +y: Qn, +it: List<&2, Qn>, le: Bool
) -> Pm:
  match le:
    case True{}:
      MkPm{x, lt, y <> it}
    case False{}:
      MkPm{y, x <> lt, it}

def pop_min(+lv: List<&2, Qn>, +iv: List<&2, Qn>) -> Pm:
  match lv:
    case Nil{}:
      match iv:
        case Nil{}:
          MkPm{MkQn{0, HLeaf{0}}, Nil{}, Nil{}}
        case x <> t:
          MkPm{x, Nil{}, t}
    case +x <> lt:
      match iv:
        case Nil{}:
          MkPm{x, lt, Nil{}}
        case +y <> it:
          pop_both(x, lt, y, it, U32.is_le(qn_w(x), qn_w(y)))

def qn_t(q: Qn) -> HT:
  match q:
    case MkQn{_, t}:
      t

def hs2(+a: Qn, pm: Pm) -> Hq:
  match pm:
    case MkPm{+b, lv, iv}:
      MkHq{lv, app1(iv, MkQn{U32.add(qn_w(a), qn_w(b)),
        HNode{qn_t(a), qn_t(b)}})}

def hs1(pm: Pm) -> Hq:
  match pm:
    case MkPm{a, lv, iv}:
      hs2(a, pop_min(lv, iv))

def huff_step(hq: Hq) -> Hq:
  match hq:
    case MkHq{lv, iv}:
      hs1(pop_min(lv, iv))

def huff_loop(k: Nat, hq: Hq) -> Hq:
  match k:
    case 0n:
      hq
    case 1n+p:
      huff_loop(p, huff_step(hq))

def hq_root2(iv: List<&2, Qn>, lv: List<&2, Qn>) -> HT:
  match iv:
    case Nil{}:
      match lv:
        case Nil{}:
          HLeaf{0}
        case q <> _:
          qn_t(q)
    case q <> _:
      qn_t(q)

def hq_root(hq: Hq) -> HT:
  match hq:
    case MkHq{lv, iv}:
      hq_root2(iv, lv)

# Depth of every leaf as (sym << 5 | depth).
def walk(t: HT, +d: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match t:
    case HLeaf{+sym}:
      U32.or(U32.shln(sym, 5n), U32.min(d, 31)) <> acc
    case HNode{l, r}:
      walk(l, U32.inc(d), walk(r, U32.inc(d), acc))

# Lengths by symbol (0 for unused) from the sorted (sym << 5 | depth) list.
def lf_val(+ps: List<&2, U32>, +sym: U32) -> U32:
  match ps:
    case Nil{}:
      0
    case +h <> _:
      Bool.pick(U32, U32.is_eq(U32.shrn(h, 5n), sym), U32.and(h, 31), 0)

def lf_rest(+ps: List<&2, U32>, +sym: U32) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(U32.shrn(h, 5n), sym), t, h <> t)

def lens_fill(k: Nat, +sym: U32, +ps: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      lf_val(ps, sym) <> lens_fill(p, U32.inc(sym), lf_rest(ps, sym))

def count_nz(+xs: List<&2, U32>, +n: U32) -> U32:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      count_nz(t, Bool.pick(U32, U32.is_zero(h), n, U32.inc(n)))

def set_at1(xs: List<&2, U32>, +i: Nat, +v: U32) -> List<&2, U32>:
  I.set_at(xs, i, v)

def force2b(+fr: List<&2, U32>, +n: U32) -> List<&2, U32>:
  match n:
    case 0:
      I.set_at(I.set_at(fr, 0n, 1), 1n, 1)
    case 1:
      Bool.pick(List<&2, U32>, U32.is_zero(I.nth(fr, 0n)),
        I.set_at(fr, 0n, 1), I.set_at(fr, 1n, 1))
    case _:
      fr

# Make sure at least two symbols are used (a complete tree needs two leaves).
def force2(+fr: List<&2, U32>) -> List<&2, U32>:
  force2b(fr, count_nz(fr, 0))

def mk_acc(+f: U32, +sym: U32, acc: List<&2, U32>, zero: Bool) -> List<&2, U32>:
  match zero:
    case True{}:
      acc
    case False{}:
      U32.or(U32.shln(f, 9n), sym) <> acc

# (freq << 9 | sym) for used symbols (order irrelevant: sorted afterwards).
def mk_keys(+fr: List<&2, U32>, +sym: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match fr:
    case Nil{}:
      acc
    case +f <> t:
      mk_keys(t, U32.inc(sym), mk_acc(f, sym, acc, U32.is_zero(f)))

def flatten(+fr: List<&2, U32>) -> List<&2, U32>:
  match fr:
    case Nil{}:
      Nil{}
    case +f <> t:
      Bool.pick(U32, U32.is_zero(f), 0, U32.shrn(U32.inc(f), 1n)) <> flatten(t)

def lens_of3(hq: Hq, +nsym: Nat) -> List<&2, U32>:
  lens_fill(nsym, 0, sort_u32(walk(hq_root(hq), 0, Nil{})))

def lens_of2(+keys: List<&2, U32>, +nsym: Nat) -> List<&2, U32>:
  lens_of3(huff_loop(Nat.sub(List.length(&2, U32, keys), 1n),
    MkHq{mk_leaves(keys), Nil{}}), nsym)

def lens_of(+fr: List<&2, U32>, +nsym: Nat) -> List<&2, U32>:
  lens_of2(sort_u32(mk_keys(fr, 0, Nil{})), nsym)

def bl_decide(ok: Bool, lens: List<&2, U32>, fr: List<&2, U32>) -> Bl:
  match ok:
    case True{}:
      BlOk{lens}
    case False{}:
      BlTry{flatten(fr)}

def bl_attempt2(+lens: List<&2, U32>, fr: List<&2, U32>, +limit: U32) -> Bl:
  bl_decide(U32.is_le(I.list_max(lens, 0), limit), lens, fr)

def bl_attempt(+fr: List<&2, U32>, +nsym: Nat, +limit: U32) -> Bl:
  bl_attempt2(lens_of(fr, nsym), fr, limit)

def bl_loop(k: Nat, +nsym: Nat, +limit: U32, st: Bl) -> List<&2, U32>:
  match k:
    case 0n:
      I.zeros(nsym)
    case 1n+p:
      match st:
        case BlOk{lens}:
          lens
        case BlTry{fr}:
          bl_loop(p, nsym, limit, bl_attempt(fr, nsym, limit))

# Code lengths (<= limit) for a frequency list of `nsym` symbols.
def build_lens(+fr: List<&2, U32>, +nsym: Nat, +limit: U32) -> List<&2, U32>:
  bl_loop(24n, nsym, limit, BlTry{force2(fr)})

# ---- code-length header (RLE with 16/17/18) -------------------------------------------
# RLE words: symbol | extra value << 8.

def ro_step3(
  v: U32, h: U32, t: List<&2, U32>, +n: U32, same: Bool
) -> Ro:
  match same:
    case True{}:
      RoRun{t, U32.inc(n)}
    case False{}:
      RoEnd{n, h <> t}

def ro_step(+v: U32, ro: Ro) -> Ro:
  match ro:
    case RoRun{xs, n}:
      match xs:
        case Nil{}:
          RoEnd{n, Nil{}}
        case +h <> t:
          ro_step3(v, h, t, n, U32.is_eq(h, v))
    case RoEnd{n, rest}:
      RoEnd{n, rest}

def ro_loop(k: Nat, +v: U32, ro: Ro) -> Ro:
  match k:
    case 0n:
      ro
    case 1n+p:
      ro_loop(p, v, ro_step(v, ro))

def ro_n(ro: Ro) -> U32:
  match ro:
    case RoRun{_, n}:
      n
    case RoEnd{n, _}:
      n

def ro_rest(ro: Ro) -> List<&2, U32>:
  match ro:
    case RoRun{xs, _}:
      xs
    case RoEnd{_, rest}:
      rest

def lit_rep(k: Nat, +v: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      lit_rep(p, v, v <> acc)

# Zero run of n: 18 for 11..138, then 17 for 3..10, then literals.
def rz_mid(+n: U32, acc: List<&2, U32>, mid: Bool) -> List<&2, U32>:
  match mid:
    case True{}:
      U32.or(17, U32.shln(U32.sub(n, 3), 8n)) <> acc
    case False{}:
      lit_rep(U32.to_nat(n), 0, acc)

def rz_acc(+n: U32, acc: List<&2, U32>, big: Bool) -> List<&2, U32>:
  match big:
    case True{}:
      U32.or(18, U32.shln(U32.sub(U32.min(n, 138), 11), 8n)) <> acc
    case False{}:
      rz_mid(n, acc, U32.is_ge(n, 3))

def rz_n(+n: U32, big: Bool) -> U32:
  match big:
    case True{}:
      U32.sub(n, U32.min(n, 138))
    case False{}:
      0

def rle_zero(fuel: Nat, +n: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match n:
        case 0:
          acc
        case _:
          rle_zero(p, rz_n(n, U32.is_ge(n, 11)),
            rz_acc(n, acc, U32.is_ge(n, 11)))

# Non-zero run: the value once, then repeats of 3..6 via 16, then literals.
def rr_acc(+v: U32, +rem: U32, acc: List<&2, U32>, big: Bool) -> List<&2, U32>:
  match big:
    case True{}:
      U32.or(16, U32.shln(U32.sub(U32.min(rem, 6), 3), 8n)) <> acc
    case False{}:
      lit_rep(U32.to_nat(rem), v, acc)

def rr_n(+rem: U32, big: Bool) -> U32:
  match big:
    case True{}:
      U32.sub(rem, U32.min(rem, 6))
    case False{}:
      0

def rle_rep(fuel: Nat, +v: U32, +rem: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      acc
    case 1n+p:
      match rem:
        case 0:
          acc
        case _:
          rle_rep(p, v, rr_n(rem, U32.is_ge(rem, 3)),
            rr_acc(v, rem, acc, U32.is_ge(rem, 3)))

def rle_emit2(
  +v: U32, +n: U32, acc: List<&2, U32>, zero: Bool
) -> List<&2, U32>:
  match zero:
    case True{}:
      rle_zero(40n, n, acc)
    case False{}:
      rle_rep(40n, v, U32.sub(n, 1), v <> acc)

def rle_emit(+v: U32, +n: U32, acc: List<&2, U32>) -> List<&2, U32>:
  rle_emit2(v, n, acc, U32.is_zero(v))

def rs_step2(+v: U32, +ro: Ro, acc: List<&2, U32>) -> Rs:
  RsRun{ro_rest(ro), rle_emit(v, ro_n(ro), acc)}

def rs_step(rs: Rs) -> Rs:
  match rs:
    case RsRun{lens, acc}:
      match lens:
        case Nil{}:
          RsEnd{acc}
        case +v <> t:
          rs_step2(v, ro_loop(138n, v, RoRun{t, 1}), acc)
    case RsEnd{acc}:
      RsEnd{acc}

def rs_loop(k: Nat, rs: Rs) -> Rs:
  match k:
    case 0n:
      rs
    case 1n+p:
      rs_loop(p, rs_step(rs))

def rs_acc(rs: Rs) -> List<&2, U32>:
  match rs:
    case RsRun{_, acc}:
      acc
    case RsEnd{acc}:
      acc

def rle_lens(+lens: List<&2, U32>) -> List<&2, U32>:
  I.rev(rs_acc(rs_loop(Nat.add(List.length(&2, U32, lens), 1n),
    RsRun{lens, Nil{}})), Nil{})

# Frequencies of the 19 code-length symbols.
def cl_freq(+rle: List<&2, U32>, fr: List<&2, U32>) -> List<&2, U32>:
  match rle:
    case Nil{}:
      fr
    case +w <> t:
      cl_freq(t, I.inc_at(fr, U32.to_nat(U32.and(w, 255))))

# Number of leading entries to keep: last non-zero index + 1, at least `min`.
def last_nz(+xs: List<&2, U32>, +i: U32, +last: U32) -> U32:
  match xs:
    case Nil{}:
      last
    case +h <> t:
      last_nz(t, U32.inc(i), Bool.pick(U32, U32.is_zero(h), last, U32.inc(i)))

def trim_n(+xs: List<&2, U32>, +min: U32) -> U32:
  U32.max(min, last_nz(xs, 0, 0))

# Code-length code lengths in transmission order.
def order_lens(+cll: List<&2, U32>, ord: List<&2, U32>) -> List<&2, U32>:
  match ord:
    case Nil{}:
      Nil{}
    case +o <> t:
      I.nth(cll, U32.to_nat(o)) <> order_lens(cll, t)

def dot(+fr: List<&2, U32>, +ls: List<&2, U32>, +acc: U32) -> U32:
  match fr:
    case Nil{}:
      acc
    case +f <> ft:
      match ls:
        case Nil{}:
          acc
        case +l <> lt:
          dot(ft, lt, U32.add(acc, U32.mul(f, l)))

# ---- token emission -------------------------------------------------------------------

def put_code(bw: Bw, +e: U32) -> Bw:
  bw_put(bw, U32.shrn(e, 4n), U32.and(e, 15))

def bits_mask(+n: U32) -> U32:
  U32.sub(U32.shln(1, U32.to_nat(n)), 1)

def em_d2(
  r: Array<U32> & U32, mem: Array<U32>, +bw: Bw, +d: U32, +dc: U32
) -> Em:
  (aux, +e) = r
  +eb = U32.and(U32.shrn(dc, 8n), 255)
  MkEm{mem, aux, bw_put(put_code(bw, e), U32.and(d, bits_mask(eb)), eb)}

def em_d1(
  r: Array<U32> & U32, mem: Array<U32>, +bw: Bw, +d: U32, +dbase: U32
) -> Em:
  (aux, +dc) = r
  em_d2(Array.get(U32, aux, U32.add(dbase, U32.and(dc, 255))), mem, bw, d, dc)

def em_m2(
  r: Array<U32> & U32, mem: Array<U32>, +bw: Bw, +v: U32, +d: U32,
  +lc: U32, +dbase: U32
) -> Em:
  (aux, +e) = r
  +eb = U32.and(U32.shrn(lc, 8n), 255)
  em_d1(Array.get(U32, aux, U32.add(a_disc(), dindex(d))), mem,
    bw_put(put_code(bw, e), U32.and(v, bits_mask(eb)), eb), d, dbase)

def em_m1(
  r: Array<U32> & U32, mem: Array<U32>, +bw: Bw, +v: U32, +d: U32,
  +lbase: U32, +dbase: U32
) -> Em:
  (aux, +lc) = r
  em_m2(Array.get(U32, aux, U32.add(lbase, U32.add(257, U32.and(lc, 255)))),
    mem, bw, v, d, lc, dbase)

def em_lit(r: Array<U32> & U32, mem: Array<U32>, bw: Bw) -> Em:
  (aux, +e) = r
  MkEm{mem, aux, put_code(bw, e)}

def em_t2(
  mem: Array<U32>, aux: Array<U32>, bw: Bw, +t: U32, +lbase: U32,
  +dbase: U32, lit: Bool
) -> Em:
  match lit:
    case True{}:
      em_lit(Array.get(U32, aux, U32.add(lbase, t)), mem, bw)
    case False{}:
      em_m1(Array.get(U32, aux, U32.add(a_lenc(), U32.and(U32.shrn(t, 16n), 255))),
        mem, bw, U32.and(U32.shrn(t, 16n), 255), U32.and(t, 32767), lbase,
        dbase)

def em_t1(
  r: Array<U32> & U32, aux: Array<U32>, bw: Bw, lbase: U32, dbase: U32
) -> Em:
  (mem, +t) = r
  em_t2(mem, aux, bw, t, lbase, dbase, U32.is_lt(t, 256))

def em_step(+i: U32, +lbase: U32, +dbase: U32, em: Em) -> Em:
  match em:
    case MkEm{mem, aux, bw}:
      em_t1(Array.get(U32, mem, U32.add(m_tok(), i)), aux, bw, lbase, dbase)

def em_loop(k: Nat, +i: U32, +lbase: U32, +dbase: U32, em: Em) -> Em:
  match k:
    case 0n:
      em
    case 1n+p:
      em_loop(p, U32.inc(i), lbase, dbase, em_step(i, lbase, dbase, em))

# End of block code (symbol 256) from the literal code table at lbase.
def em_eob2(r: Array<U32> & U32, mem: Array<U32>, bw: Bw) -> Em:
  (aux, +e) = r
  MkEm{mem, aux, put_code(bw, e)}

def em_eob(em: Em, +lbase: U32) -> Em:
  match em:
    case MkEm{mem, aux, bw}:
      em_eob2(Array.get(U32, aux, U32.add(lbase, 256)), mem, bw)

# ---- header emission -----------------------------------------------------------------

def put_order(+cll: List<&2, U32>, ord: List<&2, U32>, bw: Bw) -> Bw:
  match ord:
    case Nil{}:
      bw
    case +o <> t:
      put_order(cll, t, bw_put(bw, I.nth(cll, U32.to_nat(o)), 3))

# cl code lengths in transmission order, first `n` of them.
def put_cl_lens(+cll: List<&2, U32>, +n: U32, bw: Bw) -> Bw:
  put_order(cll, List.take(&2, U32, I.cl_order(), U32.to_nat(n)), bw)

def rle_extra(+w: U32) -> U32:
  Bool.pick(U32, U32.is_eq(U32.and(w, 255), 16), 2,
    Bool.pick(U32, U32.is_eq(U32.and(w, 255), 17), 3, 7))

def rh_put3(aux: Array<U32>, bw: Bw, +w: U32, ex: Bool) -> Rh:
  match ex:
    case True{}:
      MkRh{aux, bw_put(bw, U32.shrn(w, 8n), rle_extra(w))}
    case False{}:
      MkRh{aux, bw}

def rh_put2(r: Array<U32> & U32, bw: Bw, +w: U32) -> Rh:
  (aux, +e) = r
  rh_put3(aux, put_code(bw, e), w, U32.is_ge(U32.and(w, 255), 16))

def rh_step(+w: U32, rh: Rh) -> Rh:
  match rh:
    case MkRh{aux, bw}:
      rh_put2(Array.get(U32, aux, U32.add(a_clc(), U32.and(w, 255))), bw, w)

def rh_loop(+rle: List<&2, U32>, rh: Rh) -> Rh:
  match rle:
    case Nil{}:
      rh
    case +w <> t:
      rh_loop(t, rh_step(w, rh))

# ---- block planning ----------------------------------------------------------------

def sum_list(+xs: List<&2, U32>, +a: U32) -> U32:
  match xs:
    case Nil{}:
      a
    case +h <> t:
      sum_list(t, U32.add(a, h))

# Extra bits of the 16/17/18 symbols: 2*f16 + 3*f17 + 7*f18.
def cl_extra_bits(+clf: List<&2, U32>) -> U32:
  U32.add(U32.mul(2, I.nth(clf, 16n)), U32.add(U32.mul(3, I.nth(clf, 17n)),
    U32.mul(7, I.nth(clf, 18n))))

def plan5(
  +ll: List<&2, U32>, +dl: List<&2, U32>, hlit: U32, hdist: U32,
  rle: List<&2, U32>, +clf: List<&2, U32>, +cll: List<&2, U32>,
  +fl: List<&2, U32>, +fd: List<&2, U32>, +xb: U32
) -> Dy:
  +hclen = U32.max(4, last_nz(order_lens(cll, I.cl_order()), 0, 0))
  MkDy{ll, dl, hlit, hdist, rle, cll, hclen,
    U32.add(U32.add(17, U32.mul(3, hclen)),
      U32.add(U32.add(dot(clf, cll, 0), cl_extra_bits(clf)),
        U32.add(dot(fl, ll, 0), U32.add(dot(fd, dl, 0), xb)))),
    U32.add(U32.add(3, xb), U32.add(dot(fl, I.fixed_lit_lens(), 0),
      U32.mul(5, sum_list(fd, 0))))}

def plan4(
  +ll: List<&2, U32>, +dl: List<&2, U32>, +hlit: U32, +hdist: U32,
  +rle: List<&2, U32>, +fl: List<&2, U32>, +fd: List<&2, U32>, +xb: U32
) -> Dy:
  +clf = cl_freq(rle, I.zeros(19n))
  plan5(ll, dl, hlit, hdist, rle, clf, build_lens(clf, 19n, 7), fl, fd, xb)

def plan3(
  +ll: List<&2, U32>, +dl: List<&2, U32>, +hlit: U32, +hdist: U32,
  +fl: List<&2, U32>, +fd: List<&2, U32>, +xb: U32
) -> Dy:
  plan4(ll, dl, hlit, hdist,
    rle_lens(B.list_cat(List.take(&2, U32, ll, U32.to_nat(hlit)),
      List.take(&2, U32, dl, U32.to_nat(hdist)))), fl, fd, xb)

def plan2(
  +ll: List<&2, U32>, +dl: List<&2, U32>, +fl: List<&2, U32>,
  +fd: List<&2, U32>, +xb: U32
) -> Dy:
  plan3(ll, dl, trim_n(ll, 257), trim_n(dl, 1), fl, fd, xb)

def plan(+fl: List<&2, U32>, +fd: List<&2, U32>, +xb: U32) -> Dy:
  plan2(build_lens(fl, 286n, 15), build_lens(fd, 30n, 15), fl, fd, xb)

# Pieces of a plan.
def dy_cdyn(dy: Dy) -> U32:
  match dy:
    case MkDy{_, _, _, _, _, _, _, c, _}:
      c

def dy_cfix(dy: Dy) -> U32:
  match dy:
    case MkDy{_, _, _, _, _, _, _, _, c}:
      c

# 0 = stored, 1 = fixed, 2 = dynamic (cheapest; ties prefer the simpler type).
def choose2(+cs: U32, +cf: U32, +cd: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(cs, cf), U32.is_le(cs, cd)), 0,
    Bool.pick(U32, U32.is_le(cf, cd), 1, 2))

def choose(+cs: U32, +dy: Dy) -> U32:
  choose2(cs, dy_cfix(dy), dy_cdyn(dy))

# ---- emit one block ------------------------------------------------------------------

def emit_fixed(mem: Array<U32>, aux: Array<U32>, bw: Bw, +ntok: U32) -> Em:
  em_eob(em_loop(U32.to_nat(ntok), 0, a_fixl(), a_fixd(),
    MkEm{mem, aux, bw_put(bw_put(bw, 0, 1), 1, 2)}), a_fixl())

def emit_dyn3(
  rh: Rh, mem: Array<U32>, ll: List<&2, U32>, +ntok: U32
) -> Em:
  match rh:
    case MkRh{aux, bw}:
      em_eob(em_loop(U32.to_nat(ntok), 0, a_clit(), a_cdst(),
        MkEm{mem, aux, bw}), a_clit())

def emit_dyn2(
  mem: Array<U32>, aux: Array<U32>, bw: Bw, +ntok: U32, +dy: Dy
) -> Em:
  match dy:
    case MkDy{ll, dl, hlit, hdist, rle, cll, hclen, _, _}:
      emit_dyn3(rh_loop(rle, MkRh{set_codes(cll, a_clc(),
        set_codes(dl, a_cdst(), set_codes(ll, a_clit(), aux))),
        put_cl_lens(cll, hclen, bw_put(bw_put(bw_put(bw_put(bw_put(bw, 0, 1), 2, 2),
          U32.sub(hlit, 257), 5), U32.sub(hdist, 1), 5), U32.sub(hclen, 4), 4))}),
        mem, ll, ntok)

def bw_raw(bw: Bw, +b: U32) -> Bw:
  match bw:
    case MkBw{acc, cnt, out}:
      MkBw{acc, cnt, b <> out}

def sb_put(r: Array<U32> & U32, bw: Bw) -> Sb:
  (mem, +b) = r
  MkSb{mem, bw_raw(bw, b)}

def sb_step(+i: U32, sb: Sb) -> Sb:
  match sb:
    case MkSb{mem, bw}:
      sb_put(Array.get(U32, mem, i), bw)

def sb_loop(k: Nat, +i: U32, sb: Sb) -> Sb:
  match k:
    case 0n:
      sb
    case 1n+p:
      sb_loop(p, U32.inc(i), sb_step(i, sb))

def emit_stored2(sb: Sb, aux: Array<U32>) -> Em:
  match sb:
    case MkSb{mem, bw}:
      MkEm{mem, aux, bw}

def emit_stored(
  mem: Array<U32>, aux: Array<U32>, bw: Bw, +bstart: U32, +len: U32
) -> Em:
  emit_stored2(sb_loop(U32.to_nat(len), bstart, MkSb{mem,
    bw_put(bw_put(bw_align(bw_put(bw, 0, 3)), len, 16),
      U32.xor(len, 65535), 16)}), aux)

def emit_choice(
  c: U32, mem: Array<U32>, aux: Array<U32>, bw: Bw, +ntok: U32, bstart: U32,
  len: U32, dy: Dy
) -> Em:
  match c:
    case 0:
      emit_stored(mem, aux, bw, bstart, len)
    case 1:
      emit_fixed(mem, aux, bw, ntok)
    case _:
      emit_dyn2(mem, aux, bw, ntok, dy)

def eb4(
  +dy: Dy, mem: Array<U32>, aux: Array<U32>, bw: Bw, ntok: U32,
  bstart: U32, +len: U32
) -> Em:
  emit_choice(choose(U32.add(42, U32.mul(8, len)), dy), mem, aux, bw, ntok,
    bstart, len, dy)

def eb3(
  fl: List<&2, U32>, fd: List<&2, U32>, mem: Array<U32>, aux: Array<U32>,
  bw: Bw, +ntok: U32, +bstart: U32, +len: U32, +xb: U32
) -> Em:
  eb4(plan(fl, fd, xb), mem, aux, bw, ntok, bstart, len)

def eb2(
  r: Array<U32> & List<&2, U32>, fl: List<&2, U32>, mem: Array<U32>,
  bw: Bw, ntok: U32, bstart: U32, len: U32, xb: U32
) -> Em:
  (aux, fd) = r
  eb3(fl, fd, mem, aux, bw, ntok, bstart, len, xb)

def eb1(
  r: Array<U32> & List<&2, U32>, mem: Array<U32>, bw: Bw, ntok: U32,
  bstart: U32, len: U32, xb: U32
) -> Em:
  (aux, fl) = r
  eb2(rd_range(30n, a_fdst(), aux), fl, mem, bw, ntok, bstart, len, xb)

def eb0(fc: Fc, bw: Bw, ntok: U32, bstart: U32, len: U32) -> Em:
  match fc:
    case MkFc{mem, aux, xb}:
      eb1(rd_range(286n, a_flit(), aux_inc(aux, U32.add(a_flit(), 256))), mem,
        bw, ntok, bstart, len, xb)

# Encode the tokens [0, ntok) covering input [bstart, bstart + len).
def encode_block(
  mem: Array<U32>, aux: Array<U32>, bw: Bw, +ntok: U32, bstart: U32, len: U32
) -> Em:
  eb0(fc_loop(U32.to_nat(ntok), 0, MkFc{mem,
    aux_zero(320n, a_flit(), aux), 0}), bw, ntok, bstart, len)

# ---- segment driver ----------------------------------------------------------------------

# Empty stored block, byte aligned: the segment ends on a byte boundary.
def sync_flush(bw: Bw) -> Bw:
  bw_put(bw_put(bw_align(bw_put(bw, 0, 3)), 0, 16), 65535, 16)

def sg_fin(em: Em) -> Sg:
  match em:
    case MkEm{_, _, bw}:
      SgDone{sync_flush(bw)}

def sg_cont(em: Em, +p: U32, +end: U32) -> Sg:
  match em:
    case MkEm{mem, aux, bw}:
      SgRun{mem, p, end, 0, p, aux, bw}

def sg_end2(
  mem: Array<U32>, aux: Array<U32>, bw: Bw, +ntok: U32, +bstart: U32,
  +p: U32, more: Bool
) -> Sg:
  match more:
    case True{}:
      sg_fin(encode_block(mem, aux, bw, ntok, bstart, U32.sub(p, bstart)))
    case False{}:
      SgDone{sync_flush(bw)}

def sg_after(ms: Ms, aux: Array<U32>, bw: Bw) -> Sg:
  match ms:
    case MsFull{mem, +p, end, ntok, +bstart}:
      sg_cont(encode_block(mem, aux, bw, ntok, bstart, U32.sub(p, bstart)), p, end)
    case MsEnd{mem, p, end, +ntok, bstart}:
      sg_end2(mem, aux, bw, ntok, bstart, p, U32.is_ne(ntok, 0))
    case MsRun{mem, p, end, +ntok, bstart}:
      sg_end2(mem, aux, bw, ntok, bstart, p, U32.is_ne(ntok, 0))

def sg_step(st: Sg) -> Sg:
  match st:
    case SgRun{mem, +p, +end, ntok, bstart, aux, bw}:
      sg_after(ms_loop(Nat.add(U32.to_nat(U32.sub(end, p)), 8n),
        MsRun{mem, p, end, ntok, bstart}), aux, bw)
    case SgDone{bw}:
      SgDone{bw}

def sg_loop(k: Nat, st: Sg) -> Sg:
  match k:
    case 0n:
      st
    case 1n+p:
      sg_loop(p, sg_step(st))

def sg_bytes(st: Sg) -> List<&2, U32>:
  match st:
    case SgRun{_, _, _, _, _, _, bw}:
      I.rev(bw_bytes(bw), Nil{})
    case SgDone{bw}:
      I.rev(bw_bytes(bw), Nil{})

def load_list(xs: List<&2, U32>, +i: U32, mem: Array<U32>) -> Array<U32>:
  match xs:
    case Nil{}:
      mem
    case +h <> t:
      load_list(t, U32.inc(i), Array.set(U32, mem, i, h))

def seg_start(mem: Array<U32>, +dlen: U32, +end: U32) -> Sg:
  SgRun{ins_loop(U32.to_nat(dlen), 0, end, mem), dlen, end, 0, dlen,
    aux_init(), bw_new()}

def ld_step(+h: U32, +i: U32, ld: Ld) -> Ld:
  match ld:
    case MkLd{mem, cs, +n}:
      MkLd{Array.set(U32, mem, U32.add(i, n), h), C.crc_next(h, cs), U32.inc(n)}

def ld_loop(xs: List<&2, U32>, +i: U32, ld: Ld) -> Ld:
  match xs:
    case Nil{}:
      ld
    case +h <> t:
      ld_loop(t, i, ld_step(h, i, ld))

def seg_finish2(sg: Sg, +crc: U32, +n: U32) -> Sres:
  MkSres{sg_bytes(sg), C.crc_final(crc), n}

def seg_finish(ld: Ld, +dlen: U32) -> Sres:
  match ld:
    case MkLd{mem, cs, +n}:
      seg_finish2(sg_loop(Nat.add(U32.to_nat(n), 8n),
        seg_start(mem, dlen, U32.add(dlen, n))), C.crc_get(cs), n)

def seg_load(mem: Array<U32>, +dlen: U32, seg: List<&2, U32>) -> Sres:
  seg_finish(ld_loop(seg, dlen, MkLd{mem, C.crc_new(C.crc_init()), 0}), dlen)

# Compress `seg` (<= 131072 bytes) with `dict` (<= 32768 bytes) as history.
def seg_compress(+dict: List<&2, U32>, seg: List<&2, U32>) -> Sres:
  +dlen = U32.from_nat(List.length(&2, U32, dict))
  seg_load(load_list(dict, 0, Array.new(U32, 18n, 0)), dlen, seg)
