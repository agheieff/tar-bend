# M0 probe: can an effect accept and return Array<U32> directly? The generated
# C is the evidence: Array<U32> is a TAG_BUF block of 2^cls packed u32 slots,
# element i at ((u32*)e.mem)[blk_loc + i]; there is no runtime helper for it
# (io_list/io_cbuf cover List only). These effects reach the block layout by
# hand, which is ABI-internal; see docs/effects.md for the recommendation.
import Base
import ./array_probe_effects.bend as P

def mk() -> Array<U32>:
  a = [0 : U32*8n]
  a[0] <- 10
  a[1] <- 11
  a[2] <- 12
  a[3] <- 13
  a[4] <- 14
  a[5] <- 15
  a[6] <- 16
  a[7] <- 17
  a

def main() -> IO(Unit):
  do IO<Unit>:
    a : Array<U32> = mk()
    s : U32 <- P.Probe.sum_words(a)
    IO.print("accept Array<U32> ok: sum(10..17) = " ++ U32.show(s))
    b : Array<U32> <- P.Probe.make_words(8)
    t : U32 <- P.Probe.sum_words(b)
    IO.print("return Array<U32> ok: sum = " ++ U32.show(t))
    IO.print("ARRAY PROBE OK: Array<U32> crosses an effect (flat class-3 block)")
