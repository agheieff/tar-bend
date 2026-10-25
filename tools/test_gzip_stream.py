#!/usr/bin/env python3
"""Streaming-gzip checks for btar (stdlib only).

Usage: test_gzip_stream.py BTAR [--keep]

Prints one `PASS name: detail` / `FAIL name: detail` line per check and exits
non-zero when any check fails.  Covers what the v1.0 caps used to forbid and the
properties of the v1.1 codec: large archives both ways, GNU interop at scale,
deterministic output independent of the thread count, ratio vs GNU gzip, the
self-archive guard and bounded memory.
"""
import gzip
import hashlib
import os
import random
import resource
import shutil
import subprocess
import sys
import tempfile
import time

BTAR = os.path.abspath(sys.argv[1])
KEEP = "--keep" in sys.argv
ROOT = os.path.dirname(os.path.abspath(__file__))
COMPARE = os.path.join(ROOT, "compare_tree.py")
work = tempfile.mkdtemp(prefix="tar-bend-gzs.")
fails = 0


def report(name, ok, detail):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ": " + detail, flush=True)
    if not ok:
        fails += 1


LAST_PEAK = [0.0]


def run(args, **kw):
    """Run a command, return (rc, seconds, stdout, stderr); records the child's own peak RSS."""
    t0 = time.monotonic()
    out_path = os.path.join(work, "run.out")
    err_path = os.path.join(work, "run.err")
    with open(out_path, "wb") as fo, open(err_path, "wb") as fe:
        p = subprocess.Popen(args, stdout=fo, stderr=fe, **kw)
        _, status, ru = os.wait4(p.pid, 0)
        p.returncode = os.waitstatus_to_exitcode(status)
    LAST_PEAK[0] = ru.ru_maxrss / 1024.0
    return (p.returncode, time.monotonic() - t0, open(out_path, "rb").read(),
            open(err_path, "rb").read().decode(errors="replace").strip())


def peak_mb():
    return LAST_PEAK[0]


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def make_tree(root, mib_text, mib_rand, mib_zero, files=40, seed=3):
    """Deterministic mixed tree: word-like text, random bytes, zero runs."""
    rnd = random.Random(seed)
    vocab = [bytes(rnd.choices(b"abcdefghijklmnopqrstuvwxyz", k=rnd.randint(2, 9)))
             for _ in range(4000)]
    os.makedirs(root, exist_ok=True)
    kinds = (["text"] * mib_text) + (["rand"] * mib_rand) + (["zero"] * mib_zero)
    per = max(1, len(kinds) // files)
    for i in range(0, len(kinds), per):
        group = kinds[i:i + per]
        sub = os.path.join(root, "d%02d" % (i // per % 7))
        os.makedirs(sub, exist_ok=True)
        buf = bytearray()
        for k in group:
            if k == "text":
                n = 0
                while n < (1 << 20):
                    w = rnd.choice(vocab) + b" "
                    buf += w
                    n += len(w)
            elif k == "rand":
                buf += rnd.randbytes(1 << 20)
            else:
                buf += bytes(1 << 20)
        path = os.path.join(sub, "f%03d.bin" % (i // per))
        with open(path, "wb") as f:
            f.write(buf)
        os.utime(path, (1700000000, 1700000000))
    for dp, dn, fn in os.walk(root):
        os.utime(dp, (1700000000, 1700000000))
    return root


try:
    # 1. > old caps: ~28 MiB tree through btar -czf / -xzf, GNU reads it back.
    src = make_tree(os.path.join(work, "src"), 12, 4, 12)
    tgz = os.path.join(work, "big.tgz")
    rc, t, _, err = run([BTAR, "-czf", tgz, "--sort=name", "-C", src, "."])
    size_in = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(src) for f in fs)
    report("create-large", rc == 0, f"rc={rc} {size_in >> 20} MiB in {t:.1f}s peak={peak_mb():.0f} MiB {err[:60]}")
    rc2, _, _, err2 = run(["gzip", "-t", tgz])
    rcl, _, out, _ = run(["tar", "-tzf", tgz])
    report("create-large-gnu-reads", rc2 == 0 and rcl == 0, f"gzip -t rc={rc2} tar -tzf rc={rcl}")
    ex = os.path.join(work, "ex")
    os.makedirs(ex)
    rc, t, _, err = run([BTAR, "-xzf", tgz, "-C", ex])
    cmp_rc, _, cmp_out, cmp_err = run([sys.executable, "-I", COMPARE, src, ex])
    report("extract-large", rc == 0 and cmp_rc == 0, f"rc={rc} in {t:.1f}s tree-compare rc={cmp_rc} {err[:40]}{cmp_err[:60]}")

    # 2. ratio vs GNU gzip -6 on the same tar (mixed data)
    tarf = os.path.join(work, "plain.tar")
    run(["tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner", "-cf", tarf, "-C", src, "."])
    ref = os.path.join(work, "ref.tgz")
    with open(tarf, "rb") as f, open(ref, "wb") as o:
        o.write(gzip.compress(f.read(), compresslevel=6))
    ours = os.path.getsize(tgz)
    gnu = os.path.getsize(ref)
    report("ratio-vs-gnu", ours <= gnu * 1.15, f"ours={ours} gnu(-6)={gnu} ratio={ours / gnu:.3f} (limit 1.15)")

    # 3. determinism: identical bytes for 1 and 8 threads
    outs = []
    for th in ("1", "8"):
        o = os.path.join(work, f"det{th}.tgz")
        rc, t, _, err = run([BTAR, "-czf", o, "--sort=name", "-C", src, ".", "+RTS", "--threads", th])
        outs.append((rc, sha(o) if rc == 0 else err))
    report("deterministic-threads", outs[0][0] == 0 and outs[0] == outs[1], f"1 thread == 8 threads: {outs[0][1][:16]}")

    # 4. GNU-made archive read at scale (listing and extraction)
    gnu_tgz = os.path.join(work, "gnu.tgz")
    run(["tar", "-czf", gnu_tgz, "-C", src, "."])
    rc, t, ours_list, err = run([BTAR, "-tzf", gnu_tgz])
    rcg, _, gnu_list, _ = run(["tar", "-tzf", gnu_tgz])
    report("list-gnu-large", rc == 0 and ours_list == gnu_list, f"rc={rc} {len(ours_list.splitlines())} names in {t:.1f}s {err[:40]}")
    ex2 = os.path.join(work, "ex2")
    os.makedirs(ex2)
    rc, t, _, err = run([BTAR, "-xzf", gnu_tgz, "-C", ex2])
    cmp_rc, _, _, cmp_err = run([sys.executable, "-I", COMPARE, src, ex2])
    report("extract-gnu-large", rc == 0 and cmp_rc == 0, f"rc={rc} in {t:.1f}s tree-compare rc={cmp_rc} {cmp_err[:60]}")

    # 5. bounded memory on a >100 MiB expansion (zeros): well under 128 MiB
    z = os.path.join(work, "zeros.gz")
    with gzip.open(z, "wb", compresslevel=9) as f:
        for _ in range(160):
            f.write(bytes(1 << 20))
    rc, t, _, err = run([BTAR, "-tzf", z])
    report("bounded-memory", rc == 0 and peak_mb() < 128, f"rc={rc} 160 MiB expansion in {t:.1f}s peak={peak_mb():.0f} MiB")

    # 6. archive inside the source tree is not dumped into itself
    st = os.path.join(work, "selftree")
    os.makedirs(st)
    open(os.path.join(st, "f.txt"), "w").write("hello\n")
    for flags, name in ((["-cf"], "a.tar"), (["-czf"], "a.tgz")):
        arch = os.path.join(st, name)
        run([BTAR] + flags + [arch, "-C", st, "."])
        rc, t, _, err = run([BTAR] + flags + [arch, "-C", st, "."])  # second run: archive exists in the tree
        rcl, _, listing, _ = run(["tar", "-tf" if name.endswith(".tar") else "-tzf", arch])
        names = listing.decode().split()
        report("self-archive-" + name, rc == 0 and "archive cannot contain itself" in err and ("./" + name) not in names,
               f"rc={rc} names={names} msg={err[:60]}")
finally:
    if KEEP:
        print("artifacts:", work)
    else:
        shutil.rmtree(work, ignore_errors=True)

sys.exit(1 if fails else 0)
