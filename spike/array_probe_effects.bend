# M0 probe effect declarations: Array<U32> across the effect boundary.
def Probe.sum_words(a: Array<U32>) -> IO(U32):
  import "./array_probe.c"
  import "./array_probe.js"

def Probe.make_words(n: U32) -> IO(Array<U32>):
  import "./array_probe.c"
  import "./array_probe.js"
