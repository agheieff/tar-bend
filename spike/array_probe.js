// M0 probe: JS lane Array<U32> is a plain JS array; summation is direct.
function probe_sum_words(a) {
  let sum = 0;
  for (let i = 0; i < a.length; i++) {
    sum = (sum + a[i]) >>> 0;
  }
  return sum;
}

function probe_make_words(n) {
  let cls = 0;
  while (2 ** cls < n) {
    cls += 1;
  }
  const a = new Array(2 ** cls);
  for (let i = 0; i < a.length; i++) {
    a[i] = (i * 3) >>> 0;
  }
  return a;
}

io_eff(CID(Probe.sum_words), probe_sum_words);
io_eff(CID(Probe.make_words), probe_make_words);
