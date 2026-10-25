# tests/test_bytes.bend — packed Bytes abstraction.
import Base
import ../src/bytes.bend as B
import ./lib.bend as T

def roundtrip_pair(p: B.Bytes & U32) -> IO(Unit):
  (blk, n) = p
  do IO<Unit>:
    +u : Unit <- T.check_u32(n, 7, "len")
    xs : List<&2, U32> = B.to_list(blk)
    T.check(B.eq_list(xs, [104, 101, 108, 108, 111, 0, 255], True{}),
      "to_list round-trip")

def roundtrip() -> IO(Unit):
  roundtrip_pair(B.len(B.from_list([104, 101, 108, 108, 111, 0, 255])))

def go4(p: B.Bytes & Maybe<&2, U32>) -> IO(Unit):
  (blk, m) = p
  T.none_u32(m, "byte_at(5) out of bounds")

def go3(blk: B.Bytes, m: Maybe<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- T.some_u32(m, 5, "byte_at(4)")
    go4(B.byte_at(blk, 5))

def go2(p: B.Bytes & Maybe<&2, U32>) -> IO(Unit):
  (blk, m) = p
  go3(blk, m)

def access() -> IO(Unit):
  go2(B.byte_at(B.from_list([1, 2, 3, 4, 5]), 4))

def u32le_pair(p: B.Bytes & Maybe<&2, U32>) -> IO(Unit):
  (blk, m) = p
  T.some_u32(m, 67305985, "u32_at little-endian 0x04030201")

def u32le() -> IO(Unit):
  u32le_pair(B.u32_at(B.from_list([1, 2, 3, 4]), 0))

def slicing_pair(p: B.Bytes & Maybe<B.Bytes>) -> IO(Unit):
  (blk, m) = p
  match m:
    case None{}:
      IO.die(Unit, 1, "FAIL: slice None")
    case Some{v}:
      xs : List<&2, U32> = B.to_list(v)
      T.check(B.eq_list(xs, [20, 30, 40], True{}), "slice 1..4")

def slicing() -> IO(Unit):
  slicing_pair(B.slice(B.from_list([10, 20, 30, 40, 50]), 1, 3n))

def blocks_math() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.some_u32(B.blocks(0), 0, "blocks(0)")
    b : Unit <- T.some_u32(B.blocks(1), 1, "blocks(1)")
    c : Unit <- T.some_u32(B.blocks(512), 1, "blocks(512)")
    d : Unit <- T.some_u32(B.blocks(513), 2, "blocks(513)")
    e : Unit <- T.some_u32(B.blocks(1024), 2, "blocks(1024)")
    f : Unit <- T.none_u32(B.blocks(4294967295), "blocks overflow rejected")
    IO.pure(Unit, Unit{})

def zero() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.check(B.is_zero(B.from_list([0, 0, 0])), "is_zero zeros")
    T.check(Bool.not(B.is_zero(B.from_list([0, 1, 0]))), "is_zero nonzero")

# Regression: eq_list must compare every byte and honour the `same` flag at
# the Nil base case ("-f" vs "-t" used to compare equal: [45,102] == [45,116]).
def eq_cases() -> IO(Unit):
  do IO<Unit>:
    a : Unit <- T.check(B.eq_list([45, 102], [45, 102], True{}),
      "eq_list equal lists")
    b : Unit <- T.check(Bool.not(B.eq_list([45, 102], [45, 116], True{})),
      "eq_list differing last byte (45,102) vs (45,116)")
    c : Unit <- T.check(Bool.not(B.eq_list([1, 2], [9, 2], True{})),
      "eq_list differing first byte")
    d : Unit <- T.check(Bool.not(B.eq_list(Nil{}, [1], True{})),
      "eq_list [] vs [1]")
    e : Unit <- T.check(Bool.not(B.eq_list([1], Nil{}, True{})),
      "eq_list [1] vs []")
    f : Unit <- T.check(Bool.not(B.eq_list([1, 2], [1, 2], False{})),
      "eq_list same=False short-circuits")
    g : Unit <- T.check(B.eq_list(Nil{}, Nil{}, True{}),
      "eq_list empty/empty True")
    h : Unit <- T.check(Bool.not(B.eq_list([1, 2, 3], [1, 9, 3], True{})),
      "eq_list differing middle byte")
    i : Unit <- T.check(Bool.not(B.eq_list([1, 2, 3], [1, 2], True{})),
      "eq_list prefix of longer list")
    IO.pure(Unit, Unit{})

def main() -> IO(Unit):
  do IO<Unit>:
    u0 : Unit <- roundtrip()
    u1 : Unit <- access()
    u2 : Unit <- u32le()
    u3 : Unit <- slicing()
    u4 : Unit <- blocks_math()
    u5 : Unit <- zero()
    u6 : Unit <- eq_cases()
    IO.print("test_bytes: OK")
