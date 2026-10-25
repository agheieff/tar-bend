# Module: Crc — table-driven CRC-32 (gzip/zlib polynomial 0xEDB88320).
#
# `CrcSt` threads the 256-entry table beside the running register so streaming
# code can fold byte lists chunk by chunk.  The register holds the raw value
# (start with `crc_init()`, finish with `crc_final`); the table is built once.
# Arrays are affine, so every lookup hands the table back (Array.get).

import Base

type CrcSt is Type:
  MkCrc{tab: Array<U32>, crc: U32}

def crc_init() -> U32:
  4294967295

def crc_final(+c: U32) -> U32:
  U32.not(c)

def crc_one(+c: U32) -> U32:
  +s = U32.shr(c)
  Bool.pick(U32, U32.is_ne(U32.and(c, 1), 0), U32.xor(s, 3988292384), s)

def crc_entry(k: Nat, +c: U32) -> U32:
  match k:
    case 0n:
      c
    case 1n+p:
      crc_entry(p, crc_one(c))

def crc_tab_go(+k: Nat, +i: U32, tab: Array<U32>) -> Array<U32>:
  match k:
    case 0n:
      tab
    case 1n+p:
      crc_tab_go(p, U32.inc(i), Array.set(U32, tab, i, crc_entry(8n, i)))

def crc_table() -> Array<U32>:
  crc_tab_go(256n, 0, [0 : U32^8n])

def crc_new(+crc: U32) -> CrcSt:
  MkCrc{crc_table(), crc}

def crc_get(s: CrcSt) -> U32:
  match s:
    case MkCrc{_, c}:
      c

def crc_fold(r: Array<U32> & U32, +crc: U32) -> CrcSt:
  (tab, e) = r
  MkCrc{tab, U32.xor(e, U32.shrn(crc, 8n))}

def crc_next(+b: U32, s: CrcSt) -> CrcSt:
  match s:
    case MkCrc{tab, +crc}:
      crc_fold(Array.get(U32, tab, U32.and(U32.xor(crc, b), 255)), crc)

def crc_list(+xs: List<&2, U32>, s: CrcSt) -> CrcSt:
  match xs:
    case Nil{}:
      s
    case +h <> t:
      crc_list(t, crc_next(h, s))

def crc_reset(s: CrcSt) -> CrcSt:
  match s:
    case MkCrc{tab, _}:
      MkCrc{tab, 4294967295}

# The register beside the (returned) state, for callers that keep threading it.
def crc_peek(s: CrcSt) -> CrcSt & U32:
  match s:
    case MkCrc{tab, +c}:
      (MkCrc{tab, c}, c)

# One-shot CRC-32 of a byte list; `init` is the previous final value (0 to start).
def crc32(+init: U32, +data: List<&2, U32>) -> U32:
  crc_final(crc_get(crc_list(data, crc_new(U32.not(init)))))

# ---- combining CRCs of consecutive pieces ------------------------------------
# crc32(A ++ B) from crc32(A), crc32(B) and len(B) (the zlib construction:
# multiplication modulo the CRC polynomial, in the reflected bit order).

def mulp_next(+b: U32) -> U32:
  Bool.pick(U32, U32.is_ne(U32.and(b, 1), 0), U32.xor(U32.shr(b), 3988292384),
    U32.shr(b))

def mulp_step(
  k: Nat, +a: U32, +b: U32, +p: U32
) -> U32:
  match k:
    case 0n:
      p
    case 1n+q:
      mulp_step(q, U32.shl(a), mulp_next(b),
        Bool.pick(U32, U32.is_ne(U32.and(a, 2147483648), 0), U32.xor(p, b), p))

# a * b modulo the polynomial (32 steps, most significant bit of `a` first).
def mulp(+a: U32, +b: U32) -> U32:
  mulp_step(32n, a, b, 0)

# x^(8 * n) modulo the polynomial: square-and-multiply on the bits of n,
# starting from x^8 (the table entry for 2^3).
def x8n(k: Nat, +n: U32, +pw: U32, +p: U32) -> U32:
  match k:
    case 0n:
      p
    case 1n+q:
      x8n(q, U32.shr(n), mulp(pw, pw),
        Bool.pick(U32, U32.is_ne(U32.and(n, 1), 0), mulp(pw, p), p))

# x^8 in reflected order: the polynomial "x" is 0x40000000, x^2 0x20000000, ...
# x^8 = 0x00800000.
def crc_combine(+c1: U32, +c2: U32, +len2: U32) -> U32:
  U32.xor(mulp(x8n(32n, len2, 8388608, 2147483648), c1), c2)
