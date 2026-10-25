# tests/test_num.bend — numeric field decode/encode.
import Base
import ../src/num.bend as N
import ./lib.bend as T

def main() -> IO(Unit):
  do IO<Unit>:
    # octal: 0000644\0 -> 420; leading spaces; trailing space; "0\0" -> 0
    a : Unit <- T.some_u32(N.decode_octal([48, 48, 48, 48, 54, 52, 52, 0]),
      420, "decode 0000644")
    b : Unit <- T.some_u32(N.decode_octal([32, 32, 55, 53, 53, 0, 0, 0]),
      493, "decode leading spaces")
    c : Unit <- T.some_u32(N.decode_octal([48, 0]), 0, "decode zero")
    d : Unit <- T.some_u32(N.decode_octal([48, 48, 48, 0, 32]), 0,
      "decode zero with trailing padding")
    # malformed: digit 8, letters, empty, mid-field space
    e : Unit <- T.none_u32(N.decode_octal([56]), "reject digit 8")
    f : Unit <- T.none_u32(N.decode_octal([120, 0]), "reject letter")
    g : Unit <- T.some_u32(N.decode_octal([0]), 0, "NUL-only field is lenient zero")
    h : Unit <- T.none_u32(N.decode_octal([48, 32, 48]), "reject mid space")
    # overflow: 2^32 in octal (40000000000) rejected; 37777777777 = max ok
    i : Unit <- T.none_u32(N.decode_octal(
      [52, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48]), "reject octal overflow")
    j : Unit <- T.some_u32(N.decode_octal(
      [51, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55]), 4294967295,
      "decode octal max")
    # decimal (pax size)
    k : Unit <- T.some_u32(N.decode_decimal([49, 50, 51, 52]), 1234,
      "decode decimal 1234")
    l : Unit <- T.none_u32(N.decode_decimal([49, 120]), "reject decimal junk")
    # encode/decode round-trip
    m : Unit <- T.some_u32(N.decode_octal(N.encode_octal(420, 8n)), 420,
      "octal round-trip 420")
    n : Unit <- T.some_u32(N.decode_octal(N.encode_octal(0, 8n)), 0,
      "octal round-trip 0")
    o : Unit <- T.some_u32(N.decode_octal(N.encode_checksum(12167)), 12167,
      "checksum field round-trip")
    # base-256: 12-byte field, 0x80 marker, non-negative value 6
    p : Unit <- T.some_u32(N.decode_base256(
      [128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6]), 6, "base-256 value 6")
    q : Unit <- T.none_u32(N.decode_base256(
      [128, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6]), "base-256 negative rejected")
    r : Unit <- T.none_u32(N.decode_base256(
      [128, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6]), "base-256 >U32 rejected")
    s : Unit <- T.none_u32(N.decode_base256(
      [48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48]),
      "base-256 without marker rejected")
    IO.print("test_num: OK")
