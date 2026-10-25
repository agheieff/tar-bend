# tests/test_checksum.bend — tar checksum over a canonical ustar header.
import Base
import ../src/checksum.bend as C
import ../src/bytes.bend as Bytes
import ./canon_ustar.bend as Canon
import ./lib.bend as T

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> = Canon.block()
    +sum : U32 = C.compute(Bytes.from_list(xs))
    T.check_u32(sum, 5239, "checksum of canonical ustar header")
    # the chksum field of the canonical header is 012167 octal = 5239
    T.check_u32(5239, sum, "checksum equals stored chksum")
    IO.print("test_checksum: OK")
