# Module: Checksum — tar header checksum.
#
# Bytes 148..155 (the chksum field itself) count as 8 spaces while summing
# the 512-byte header: sum all bytes, then replace the field bytes with 256.

import Base
import ./bytes.bend as B

def sum_list(+xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      sum_list(t, U32.add(acc, h))

# Sum of the first n bytes (wrapping) and the rest.
type Sn is Data:
  MkSn{acc: U32, rest: List<&2, U32>}

def sum_n(n: Nat, +xs: List<&2, U32>, +acc: U32) -> Sn:
  match n:
    case 0n:
      MkSn{acc, xs}
    case 1n+p:
      match xs:
        case Nil{}:
          MkSn{acc, Nil{}}
        case +h <> t:
          sum_n(p, t, U32.add(acc, h))

def skip_n(n: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      xs
    case 1n+p:
      match xs:
        case Nil{}:
          Nil{}
        case _ <> t:
          skip_n(p, t)

def compute_tail(s: Sn) -> U32:
  match s:
    case MkSn{acc, rest}:
      sum_list(skip_n(8n, rest), U32.add(acc, 256))

# Checksum field (bytes 148..155) counts as eight spaces: 256.
def compute_list(+xs: List<&2, U32>) -> U32:
  compute_tail(sum_n(148n, xs, 0))

def compute(b: B.Bytes) -> U32:
  compute_list(B.to_list(b))
