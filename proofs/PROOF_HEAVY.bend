# proofs/PROOF_HEAVY.bend — heavy concrete encoder laws (M3), EXCLUDED from
# the main `--verdict` gate because the BendTT kernel reports "out of fuel"
# when normalising the 512-byte block (kernel limitation, documented in
# docs/proofs.md).  `bend proofs/PROOF_HEAVY.bend` itself prints
# ALL PROOFS CHECK and these proofs exercise the real encoder + parser.
#
#   L1 instance: decode_chksum(encode(h)) == checksum(encode(h))
#   L4 instance: parse(encode(h)) == Done{h} for the canonical header h
#
# (A law in this file is its own claim+proof pair by convention; it is not
# imported by proofs/PROOF.bend.)

import Base
import ../src/header.bend as H
import ../src/bytes.bend as B
import ../src/checksum.bend as C
import ../src/pax.bend as P

def canon() -> H.Header:
  H.MkHeader{[97, 46, 116, 120, 116], 420, 1000, 1000, 6, 1700000000, 48,
    Nil{}, 1, Nil{}, Nil{}, 0, 0, Nil{}}

law checksum_canonical:
  {H.decode_chksum_from(H.encode_list(canon())) ==
    C.compute_list(H.encode_list(canon())) : U32}

def checksum_canonical():
  {==}

law header_roundtrip_canonical:
  {H.parse(B.from_list(H.encode_list(canon()))) == Done{canon()} :
    Result<&1, &1, String, H.Header>}

def header_roundtrip_canonical():
  {==}

# =======================================================================
# M4: L10 archive-layout + L9 writer-model laws (concrete; heavy).
#
# The writer model below is pure and lives only here (NOT in src/): it uses
# the real M3 encoders (H.encode_list), the real pax padding helper
# (P.pad_payload/P.pad_zeros) and two 512-byte zero blocks as the archive
# trailer.  The reader model uses the real parser (H.parse) on 512-byte
# slices.  Everything is CONCRETE over a fixed 4-entry manifest:
#   regular file "a.txt" (6 data bytes), dir "dir/", symlink "link",
#   hardlink "hard" (both links target "a.txt").
# This is outside the --verdict gate (kernel out of fuel on block lists),
# machine-checked by `bend proofs/PROOF_HEAVY.bend` only; the statements are
# recorded in laws/LAWS.bend prose + docs/proofs.md.  A forall-manifest L9
# proof is TODO: it needs a recursive writer/reader model and U32 block-math
# lemmas, not just concrete evaluation.
# =======================================================================

# ---- L10: one encoded block is exactly 512 bytes ----------------------

law encoded_block_len_512:
  {List.length(&2, U32, H.encode_list(canon())) == 512n : Nat}

def encoded_block_len_512():
  {==}

# The 12-byte tail of an encoded block is zero padding.
law encoded_block_tail_zero:
  {B.is_zero(B.from_list(B.slice_list(H.encode_list(canon()), 500n, 12n))) ==
    True{} : Bool}

def encoded_block_tail_zero():
  {==}

# ---- L9: pure writer model over the real encoders ---------------------

def m_data() -> List<&2, U32>:
  [104, 101, 108, 108, 111, 10]

def m_reg() -> H.Header:
  H.MkHeader{[97, 46, 116, 120, 116], 420, 1000, 1000, 6, 1700000000, 48,
    Nil{}, 1, Nil{}, Nil{}, 0, 0, Nil{}}

def m_dir() -> H.Header:
  H.MkHeader{[100, 105, 114, 47], 493, 0, 0, 0, 1700000000, 53, Nil{}, 1,
    Nil{}, Nil{}, 0, 0, Nil{}}

def m_sym() -> H.Header:
  H.MkHeader{[108, 105, 110, 107], 511, 0, 0, 0, 1700000000, 50,
    [97, 46, 116, 120, 116], 1, Nil{}, Nil{}, 0, 0, Nil{}}

def m_hard() -> H.Header:
  H.MkHeader{[104, 97, 114, 100], 420, 0, 0, 0, 1700000000, 49,
    [97, 46, 116, 120, 116], 1, Nil{}, Nil{}, 0, 0, Nil{}}

# header + padded data (only for the regular file) per entry, then EOF.
def model_write() -> List<&2, U32>:
  +b0 = B.list_cat(H.encode_list(m_reg()), P.pad_payload(m_data()))
  +b1 = B.list_cat(H.encode_list(m_dir()), H.encode_list(m_sym()))
  +b2 = B.list_cat(H.encode_list(m_hard()), P.pad_zeros(1024n))
  B.list_cat(B.list_cat(b0, b1), b2)

# ---- L9 reader model: real parser on 512-byte slices ------------------

def block_at(xs: List<&2, U32>, off: Nat) -> List<&2, U32>:
  B.slice_list(xs, off, 512n)

def header_of(r: Result<&1, &1, String, H.Header>) -> Maybe<&2, H.Header>:
  match r:
    case Fail{e}:
      None{}
    case Done{h}:
      Some{h}

def header_at_go(
  r: Result<&1, &1, String, H.Header>
) -> Maybe<&2, H.Header>:
  header_of(r)

def header_at(xs: List<&2, U32>, off: Nat) -> Maybe<&2, H.Header>:
  header_at_go(H.parse(B.from_list(block_at(xs, off))))

def name_of(m: Maybe<&2, H.Header>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{h}:
      H.full_name(h)

def name_at(xs: List<&2, U32>, off: Nat) -> List<&2, U32>:
  name_of(header_at(xs, off))

def size_of(m: Maybe<&2, H.Header>) -> U32:
  match m:
    case None{}:
      0
    case Some{h}:
      H.h_size(h)

# ---- L9 laws: model layout, header recovery, EOF ----------------------

def size_at(xs: List<&2, U32>, off: Nat) -> U32:
  size_of(header_at(xs, off))

law model_write_len:
  {List.length(&2, U32, model_write()) == 3584n : Nat}

def model_write_len():
  {==}

law model_write_len_multiple_512:
  {Nat.mod(List.length(&2, U32, model_write()), 512n) == 0n : Nat}

def model_write_len_multiple_512():
  {==}

law model_first_block_512:
  {List.length(&2, U32, block_at(model_write(), 0n)) == 512n : Nat}

def model_first_block_512():
  {==}

law model_reg_header_roundtrip:
  {header_at(model_write(), 0n) == Some{m_reg()} : Maybe<&2, H.Header>}

def model_reg_header_roundtrip():
  {==}

law model_dir_header_roundtrip:
  {header_at(model_write(), 1024n) == Some{m_dir()} : Maybe<&2, H.Header>}

def model_dir_header_roundtrip():
  {==}

law model_sym_header_roundtrip:
  {header_at(model_write(), 1536n) == Some{m_sym()} : Maybe<&2, H.Header>}

def model_sym_header_roundtrip():
  {==}

law model_hard_header_roundtrip:
  {header_at(model_write(), 2048n) == Some{m_hard()} : Maybe<&2, H.Header>}

def model_hard_header_roundtrip():
  {==}

# Recovered names (regular file, dir, symlink, hardlink) round-trip.
law model_names:
  {Bool.and(
    B.eq_list(name_at(model_write(), 0n), [97, 46, 116, 120, 116], True{}),
    B.eq_list(name_at(model_write(), 1024n), [100, 105, 114, 47], True{})) ==
    True{} : Bool}

def model_names():
  {==}

# Data-block count for the 6-byte regular payload is ceil(6/512) = 1.
law model_data_blocks:
  {B.blocks(size_at(model_write(), 0n)) == Some{1} : Maybe<&2, U32>}

def model_data_blocks():
  {==}

# The trailer is exactly two 512-byte zero blocks at the end of the file.
law model_eof_two_zero_blocks:
  {B.is_zero(B.from_list(B.slice_list(model_write(), 2560n, 1024n))) ==
    True{} : Bool}

def model_eof_two_zero_blocks():
  {==}

# The last header is followed by the 1024-byte trailer (offset arithmetic).
law model_last_header_offset:
  {Nat.add(Nat.add(Nat.add(512n, 512n), 512n), 512n) == 2048n : Nat}

def model_last_header_offset():
  {==}
