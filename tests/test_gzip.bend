# tests/test_gzip.bend — gzip codec: streaming gunzip (src/inflate, gunzip),
# segment-parallel compressor (src/deflate, gzcomp), CRC (src/crc).
import Base
import ../src/crc.bend as C
import ../src/inflate.bend as I
import ../src/gunzip.bend as U
import ../src/gzcomp.bend as Z
import ../src/bytes.bend as B
import ./lib.bend as T

def eqbytes(got: List<&2, U32>, want: List<&2, U32>, msg: String) -> IO(Unit):
  T.check(B.eq_list(got, want, True{}), msg)

def done_ok(
  r: Result<&1, &1, I.GzErr, List<&2, U32>>, want: List<&2, U32>,
  msg: String
) -> IO(Unit):
  match r:
    case Done{v}:
      eqbytes(v, want, msg)
    case Fail{_e}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (decompress failed)")

def any_err(
  r: Result<&1, &1, I.GzErr, List<&2, U32>>, msg: String
) -> IO(Unit):
  match r:
    case Fail{_e}:
      IO.pure(Unit, Unit{})
    case Done{_v}:
      IO.die(Unit, 1, "FAIL: " ++ msg ++ " (expected an error)")

def bget(xs: List<&2, U32>, i: Nat) -> U32:
  match xs i:
    case Nil{} _:
      0
    case +h <> _ 0n:
      h
    case _ <> t 1n+p:
      bget(t, p)

def bset(xs: List<&2, U32>, i: Nat, v: U32) -> List<&2, U32>:
  match xs i:
    case Nil{} _:
      Nil{}
    case _ <> t 0n:
      v <> t
    case h <> t 1n+p:
      h <> bset(t, p, v)

def cycles(+xs: List<&2, U32>, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      B.list_cat(xs, cycles(xs, p))

def rep(+v: U32, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      v <> rep(v, p)


# ---- external streams (generated with Python zlib/GNU gzip) ------------

def fixed_stream() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 203, 72, 205, 201, 201, 87, 72, 203, 172, 72, 77, 81, 200, 40, 77, 75, 203, 77, 204, 83, 40, 207, 47, 202, 73, 1, 0, 148, 254, 73, 91, 25, 0, 0, 0]

def dynamic_stream() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 75, 76, 74, 78, 4, 35, 67, 35, 227, 196, 81, 246, 40, 123, 148, 61, 202, 30, 101, 143, 178, 71, 217, 163, 236, 81, 246, 40, 123, 148, 61, 40, 217, 0, 105, 254, 249, 106, 184, 11, 0, 0]

def multi_stream() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 203, 44, 42, 46, 81, 200, 77, 205, 77, 74, 45, 226, 2, 0, 167, 244, 133, 10, 13, 0, 0, 0, 31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 43, 78, 77, 206, 207, 75, 81, 200, 77, 205, 77, 74, 45, 226, 2, 0, 54, 24, 75, 14, 14, 0, 0, 0]

def longrep_stream() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 115, 116, 28, 5, 163, 96, 20, 140, 130, 81, 48, 10, 70, 193, 80, 7, 0, 87, 0, 204, 255, 208, 7, 0, 0]

def mixed_stream() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 1, 200, 0, 55, 255, 3, 10, 17, 24, 31, 38, 45, 52, 59, 66, 73, 80, 87, 94, 101, 108, 115, 122, 129, 136, 143, 150, 157, 164, 171, 178, 185, 192, 199, 206, 213, 220, 227, 234, 241, 248, 4, 11, 18, 25, 32, 39, 46, 53, 60, 67, 74, 81, 88, 95, 102, 109, 116, 123, 130, 137, 144, 151, 158, 165, 172, 179, 186, 193, 200, 207, 214, 221, 228, 235, 242, 249, 5, 12, 19, 26, 33, 40, 47, 54, 61, 68, 75, 82, 89, 96, 103, 110, 117, 124, 131, 138, 145, 152, 159, 166, 173, 180, 187, 194, 201, 208, 215, 222, 229, 236, 243, 250, 6, 13, 20, 27, 34, 41, 48, 55, 62, 69, 76, 83, 90, 97, 104, 111, 118, 125, 132, 139, 146, 153, 160, 167, 174, 181, 188, 195, 202, 209, 216, 223, 230, 237, 244, 0, 7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98, 105, 112, 119, 126, 133, 140, 147, 154, 161, 168, 175, 182, 189, 196, 203, 210, 217, 224, 231, 238, 245, 1, 8, 15, 22, 29, 36, 43, 50, 57, 64, 71, 78, 85, 92, 99, 106, 113, 120, 127, 134, 141, 188, 24, 74, 251, 200, 0, 0, 0]

def mixed_data() -> List<&2, U32>:
  [3, 10, 17, 24, 31, 38, 45, 52, 59, 66, 73, 80, 87, 94, 101, 108, 115, 122, 129, 136, 143, 150, 157, 164, 171, 178, 185, 192, 199, 206, 213, 220, 227, 234, 241, 248, 4, 11, 18, 25, 32, 39, 46, 53, 60, 67, 74, 81, 88, 95, 102, 109, 116, 123, 130, 137, 144, 151, 158, 165, 172, 179, 186, 193, 200, 207, 214, 221, 228, 235, 242, 249, 5, 12, 19, 26, 33, 40, 47, 54, 61, 68, 75, 82, 89, 96, 103, 110, 117, 124, 131, 138, 145, 152, 159, 166, 173, 180, 187, 194, 201, 208, 215, 222, 229, 236, 243, 250, 6, 13, 20, 27, 34, 41, 48, 55, 62, 69, 76, 83, 90, 97, 104, 111, 118, 125, 132, 139, 146, 153, 160, 167, 174, 181, 188, 195, 202, 209, 216, 223, 230, 237, 244, 0, 7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98, 105, 112, 119, 126, 133, 140, 147, 154, 161, 168, 175, 182, 189, 196, 203, 210, 217, 224, 231, 238, 245, 1, 8, 15, 22, 29, 36, 43, 50, 57, 64, 71, 78, 85, 92, 99, 106, 113, 120, 127, 134, 141]

def dynamic_data() -> List<&2, U32>:
  cycles([97, 98, 99, 97, 98, 99, 97, 98, 99, 49, 50, 51], 250n)

def fixed_data() -> List<&2, U32>:
  [104, 101, 108, 108, 111, 32, 102, 105, 120, 101, 100, 32, 104, 117, 102,
    102, 109, 97, 110, 32, 119, 111, 114, 108, 100]

def multi_data() -> List<&2, U32>:
  [102, 105, 114, 115, 116, 32, 109, 101, 109, 98, 101, 114, 10, 115, 101,
    99, 111, 110, 100, 32, 109, 101, 109, 98, 101, 114, 10]

# Feed `data` in chunks of `k` bytes through the streaming engine (the same
# loop the app's pump runs), collecting the output.
def dc_next2(g: U.GS, +chunk: List<&2, U32>, last: Bool) -> U.GR:
  U.gz_run(g, chunk, U32.from_nat(List.length(&2, U32, chunk)), last)

def dc_next(g: U.GS, +rest: List<&2, U32>, +k: Nat) -> U.GR:
  dc_next2(g, List.take(&2, U32, rest, k),
    Nat.is_eq(List.length(&2, U32, rest), 0n))

def dc_step(
  fuel: Nat, r: U.GR, +rest: List<&2, U32>, +k: Nat,
  acc: List<&2, List<&2, U32>>
) -> Result<&1, &1, I.GzErr, List<&2, U32>>:
  match fuel:
    case 0n:
      Fail{I.GzCorrupt{}}
    case 1n+p:
      match r:
        case U.MkGR{g, out, n, st}:
          match st:
            case U.GNeed{}:
              dc_step(p, dc_next(g, rest, k), List.drop(&2, U32, rest, k), k,
                out <> acc)
            case U.GMore{}:
              dc_step(p, U.gz_run(g, Nil{}, 0, Nat.is_eq(List.length(&2, U32,
                rest), 0n)), rest, k, out <> acc)
            case U.GDone{}:
              Done{U.cat_chunks(out <> acc, Nil{})}
            case U.GErr{e}:
              Fail{e}

def decompress_k(+data: List<&2, U32>, +k: Nat) ->
  Result<&1, &1, I.GzErr, List<&2, U32>>:
  dc_step(Nat.add(Nat.mul(8n, List.length(&2, U32, data)), 64n),
    dc_next(U.gs_new(), data, k), List.drop(&2, U32, data, k), k, Nil{})

def hello_world() -> List<&2, U32>:
  [104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]

# A gzip stream written by GNU gzip (stored mode) for "hello world".
def stored_fixture() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 1, 11, 0, 244, 255, 104, 101, 108,
    108, 111, 32, 119, 111, 114, 108, 100, 133, 17, 74, 13, 11, 0, 0, 0]

def external_huffman() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- done_ok(U.decompress(fixed_stream()), fixed_data(),
      "external fixed-Huffman stream")
    +b : Unit <- done_ok(U.decompress(dynamic_stream()), dynamic_data(),
      "external dynamic-Huffman stream (multi-block, LZ77)")
    +c : Unit <- done_ok(U.decompress(longrep_stream()), rep(65, 2000n),
      "external long back-references (2000 x A)")
    +d : Unit <- done_ok(U.decompress(mixed_stream()), mixed_data(),
      "external mixed literals/matches")
    +e : Unit <- done_ok(U.decompress(multi_stream()), multi_data(),
      "external two-member gzip stream")
    +f : Unit <- done_ok(U.decompress(stored_fixture()), hello_world(),
      "GNU-gzip stored stream")
    IO.pure(Unit, Unit{})

# Chunk boundaries anywhere (1, 2, 3, 7, 64 byte feeds) give the same output.
def chunked() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- done_ok(decompress_k(dynamic_stream(), 1n), dynamic_data(),
      "dynamic stream, 1-byte chunks")
    +b : Unit <- done_ok(decompress_k(dynamic_stream(), 3n), dynamic_data(),
      "dynamic stream, 3-byte chunks")
    +c : Unit <- done_ok(decompress_k(multi_stream(), 1n), multi_data(),
      "two members, 1-byte chunks")
    +d : Unit <- done_ok(decompress_k(multi_stream(), 7n), multi_data(),
      "two members, 7-byte chunks")
    +e : Unit <- done_ok(decompress_k(mixed_stream(), 2n), mixed_data(),
      "stored+fixed mix, 2-byte chunks")
    +f : Unit <- done_ok(decompress_k(stored_fixture(), 5n), hello_world(),
      "stored stream, 5-byte chunks")
    +g : Unit <- done_ok(decompress_k(longrep_stream(), 64n), rep(65, 2000n),
      "long back-references, 64-byte chunks")
    IO.pure(Unit, Unit{})

# Every proper prefix of a valid stream is rejected (never accepted, never loops).
def prefixes(+data: List<&2, U32>, +n: Nat) -> IO(Unit):
  match n:
    case 0n:
      any_err(U.decompress(Nil{}), "empty input rejected")
    case 1n+p:
      do IO<Unit>:
        +a : Unit <- any_err(U.decompress(B.slice_list(data, 0n, n)),
          "truncated prefix rejected")
        prefixes(data, p)

def all_prefixes(+data: List<&2, U32>) -> IO(Unit):
  prefixes(data, Nat.sub(List.length(&2, U32, data), 1n))

def truncation() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- all_prefixes(dynamic_stream())
    +b : Unit <- all_prefixes(B.slice_list(multi_stream(), 0n, 33n))
    +b2 : Unit <- any_err(U.decompress(B.slice_list(multi_stream(), 0n, 40n)),
      "second member cut short is rejected")
    +c : Unit <- all_prefixes(stored_fixture())
    IO.pure(Unit, Unit{})

def huffman_malformed() -> IO(Unit):
  +dyn : List<&2, U32> = dynamic_stream()
  +corrupt : List<&2, U32> = bset(dyn, 11n, U32.xor(bget(dyn, 11n), 255))
  do IO<Unit>:
    +a : Unit <- any_err(U.decompress(corrupt),
      "corrupt dynamic Huffman header")
    IO.pure(Unit, Unit{})

def crc_cases() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- T.check_u32(C.crc32(0, Nil{}), 0, "crc32 empty")
    +b : Unit <- T.check_u32(C.crc32(0,
      [49, 50, 51, 52, 53, 54, 55, 56, 57]), 3421780262, "crc32 123456789")
    +c : Unit <- T.check_u32(C.crc32(0, [97]), 3904355907, "crc32 a")
    +d : Unit <- T.check_u32(C.crc32(C.crc32(0, [104, 105]),
      [32, 121, 111]), C.crc32(0, [104, 105, 32, 121, 111]),
      "crc32 chaining")
    IO.pure(Unit, Unit{})

# Pseudo-random bytes (LCG) and word-like text for round trips.
def lcg(k: Nat, +s: U32) -> List<&2, U32>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      +s2 = U32.add(U32.mul(s, 1664525), 1013904223)
      U32.and(U32.shrn(s2, 16n), 255) <> lcg(p, s2)

def words(k: Nat, +s: U32) -> List<&2, U32>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      +s2 = U32.add(U32.mul(s, 1664525), 1013904223)
      U32.add(97, U32.and(U32.shrn(s2, 20n), 7)) <> words(p, s2)

def crc_combine_cases() -> IO(Unit):
  +a : List<&2, U32> = words(300n, 5)
  +b : List<&2, U32> = lcg(1000n, 9)
  +ca : U32 = C.crc32(0, a)
  +cb : U32 = C.crc32(0, b)
  do IO<Unit>:
    +x : Unit <- T.check_u32(C.crc_combine(ca, cb, 1000),
      C.crc32(0, B.list_cat(a, b)), "crc_combine(A, B) == crc(A ++ B)")
    +y : Unit <- T.check_u32(C.crc_combine(ca, 0, 0), ca,
      "crc_combine with an empty tail")
    +z : Unit <- T.check_u32(C.crc_combine(0, cb, 1000), cb,
      "crc_combine with an empty head")
    IO.pure(Unit, Unit{})

def magic_cases() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- T.check(U.is_gzip([31, 139, 8]), "is_gzip true")
    +b : Unit <- T.check(U.is_gzip([31, 139]), "is_gzip short ok")
    +c : Unit <- T.check(Bool.not(U.is_gzip([31, 138])), "is_gzip false")
    +d : Unit <- T.check(Bool.not(U.is_gzip(Nil{})), "is_gzip empty")
    IO.pure(Unit, Unit{})

def roundtrips() -> IO(Unit):
  +empty : List<&2, U32> = Nil{}
  +tiny : List<&2, U32> = [120]
  +rep : List<&2, U32> = rep(65, 1000n)
  +mix : List<&2, U32> = [0, 1, 2, 3, 250, 251, 252, 253, 254, 255]
  +rnd : List<&2, U32> = lcg(3000n, 7)
  +txt : List<&2, U32> = words(20000n, 11)
  +ce : List<&2, U32> = Z.compress(empty)
  +ct : List<&2, U32> = Z.compress(tiny)
  +cr : List<&2, U32> = Z.compress(rep)
  +cm : List<&2, U32> = Z.compress(mix)
  +cn : List<&2, U32> = Z.compress(rnd)
  +cx : List<&2, U32> = Z.compress(txt)
  do IO<Unit>:
    +a : Unit <- done_ok(U.decompress(ce), empty, "roundtrip empty")
    +b : Unit <- done_ok(U.decompress(ct), tiny, "roundtrip tiny")
    +c : Unit <- done_ok(U.decompress(cr), rep, "roundtrip repetitive 1000")
    +d : Unit <- done_ok(U.decompress(cm), mix, "roundtrip mixed bytes")
    +e : Unit <- T.check(U.is_gzip(ce), "compress emits gzip magic")
    +f : Unit <- T.check_u32(U32.from_nat(List.length(&2, U32, ce)),
      20, "empty compressed length = header + sync flush-free final block + trailer")
    +g : Unit <- done_ok(U.decompress(cn), rnd, "roundtrip pseudo-random")
    +h : Unit <- done_ok(U.decompress(cx), txt, "roundtrip 20000-byte text")
    +i : Unit <- done_ok(decompress_k(cx, 13n), txt,
      "own dynamic output, 13-byte chunks")
    +j : Unit <- T.check(Nat.is_lt(List.length(&2, U32, cx), 12000n),
      "text compresses below 60%")
    IO.pure(Unit, Unit{})

def malformed() -> IO(Unit):
  +fx : List<&2, U32> = stored_fixture()
  +badmagic : List<&2, U32> = B.list_cat([31, 138], B.slice_list(fx, 2n, 32n))
  +badmethod : List<&2, U32> = B.list_cat([31, 139, 9],
    B.slice_list(fx, 3n, 31n))
  +badflag : List<&2, U32> = bset(fx, 3n, 224)
  +badcrc : List<&2, U32> = bset(fx, 26n, U32.add(bget(fx, 26n), 1))
  +badsize : List<&2, U32> = bset(fx, 30n, U32.add(bget(fx, 30n), 1))
  +garbage : List<&2, U32> = B.list_cat(fx, [1, 2, 3])
  do IO<Unit>:
    +a : Unit <- any_err(U.decompress(badmagic), "bad magic rejected")
    +b : Unit <- any_err(U.decompress(badmethod), "bad CM rejected")
    +c : Unit <- any_err(U.decompress(badflag), "reserved FLG bits rejected")
    +d : Unit <- any_err(U.decompress(badcrc), "bad CRC rejected")
    +e : Unit <- any_err(U.decompress(badsize), "bad ISIZE rejected")
    +f : Unit <- any_err(U.decompress(garbage), "trailing garbage rejected")
    IO.pure(Unit, Unit{})

# Compression ratio on small inputs (larger ones are covered by the native
# harness).
def ratio_cases() -> IO(Unit):
  +zeros4k : List<&2, U32> = rep(0, 4000n)
  +text : List<&2, U32> = cycles([104, 101, 108, 108, 111, 32, 119, 111, 114,
    108, 100, 10], 40n)
  +cz : List<&2, U32> = Z.compress(zeros4k)
  +ct : List<&2, U32> = Z.compress(text)
  +nz : Nat = List.length(&2, U32, cz)
  +nt : Nat = List.length(&2, U32, ct)
  do IO<Unit>:
    +a : Unit <- T.check(Nat.is_lt(nz, 120n),
      "4000 zeros compress to < 3% (LZ77 runs)")
    +b : Unit <- T.check(Nat.is_lt(nt, 100n),
      "480-byte repetitive text compresses to < 21%")
    +c : Unit <- done_ok(U.decompress(cz), zeros4k, "zeros roundtrip")
    +d : Unit <- done_ok(U.decompress(ct), text, "text roundtrip")
    IO.pure(Unit, Unit{})

# A trailer claiming a huge ISIZE is rejected (not silently accepted).
def cap_claims() -> IO(Unit):
  +bomb : List<&2, U32> = [31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 1, 11, 0, 244,
    255, 104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100, 133, 17, 74,
    13, 255, 255, 255, 255]
  any_err(U.decompress(bomb), "huge-ISIZE claim rejected")

def main() -> IO(Unit):
  do IO<Unit>:
    u0 : Unit <- crc_cases()
    uc : Unit <- crc_combine_cases()
    u1 : Unit <- magic_cases()
    u2 : Unit <- external_huffman()
    u3 : Unit <- chunked()
    u4 : Unit <- truncation()
    u5 : Unit <- malformed()
    u6 : Unit <- huffman_malformed()
    u7 : Unit <- roundtrips()
    u8 : Unit <- ratio_cases()
    u9 : Unit <- cap_claims()

    IO.print("test_gzip: OK")
