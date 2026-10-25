# Sanitizers: ASan/UBSan build, run and header fuzz harness (M2)

Sanitizer coverage of `btar` (Bend-generated C runtime + `app/main.bend` + any C effect bodies
compiled in) plus a deterministic header fuzzer. Native lane only; the JS lane is not covered.

| file | purpose |
|---|---|
| `tools/build_asan.sh` | emit `build/btar.c`, apply the Stiff preserve_none patch, compile `build/btar_asan` |
| `tools/run_asan.sh` | run the ASan binary over `fixtures/generated/valid/` (`-tf`, and `-xf` when available) |
| `tools/fuzz_headers.py` | deterministic header mutations against the ASan binary |
| `build/btar` | the normal (non-sanitizer) binary — **never written by these scripts** |

Artifacts live under `build/` (gitignored: `build/**`). Toolchain pin: **Bend 2.0.39**, clang 23.1.3
on this host (clang 19+ is required for the `preserve_*` attributes).

## 1. Build

```console
$ export PATH=$PWD/.cache/toolchain/bin:$PATH
$ ./tools/build_asan.sh
build_asan: bend 2.0.39 (<repo>/.cache/toolchain/bin/bend)
build_asan: clang version 23.1.3
build_asan: ABI ok; preserve_none uses 2 -> 0 (PRESERVE define kept for preserve_most)
build_asan: emitted build/btar.c (584052 bytes)
build_asan: patched build/btar.sanitized.c (584006 bytes)
build_asan: binary build/btar_asan (4653560 bytes)
build_asan: done (build/btar untouched)
```

What it does, in order:

1. Pin/ABI checks: `bend version` must be exactly `bend 2.0.39`; the emitted C must contain
   `static void io_eff(u32 cid, Effect run) {` and
   `typedef Term (*Effect)(Env e, Term* f, IoWork* w);` (private compiler ABI, no stability
   promise). A mismatch exits 2/1 with the expected contract instead of a cascade of clang errors.
2. Emits C: `BEND_NO_TELEMETRY=1 bend app/main.bend -o build/btar.c` (the generated C embeds the
   app, the Bend runtime work-loop, and the C bodies of any effects the app imports — e.g.
   `effs/fs.c` once the M2 extractor imports the effect module).
3. **Stiff sanitizer ABI patch.** Bend marks the work-loop trampolines `preserve_none`
   (tail-call convention); Clang ASan does not preserve its own shadow/instrumentation state across
   `preserve_none` calls, so an instrumented build is UB/false-positive prone there. The generated C
   contains (Bend 2.0.39) exactly two textual uses and one definition:

   ```
   #define PRESERVE(A) __attribute__((A))
   #define WL_FN      FAR PRESERVE(preserve_none) Term          // use 1
   typedef Term (PRESERVE(preserve_none) *WlFn)(WL_SIG);       // use 2
   ```

   Asserted: exactly 2 `PRESERVE(preserve_none)` uses, exactly 1
   `#define PRESERVE(A) __attribute__((A))`; then `sed 's/PRESERVE(preserve_none)//g'` into
   `build/btar.sanitized.c` and assert 0 uses remain. `PRESERVE`/`preserve_most` stays (it is
   compatible with ASan). If the layout changes (compiler bump), the build **fails loudly** —
   review the patch, do not force it.
4. Compiles:

   ```console
   clang -std=c11 -fbracket-depth=1024 -O1 -g \
     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
     build/btar.sanitized.c -lpthread -lm -o build/btar_asan
   ```

   `-O1 -g`: instrumented but with usable frames; `-fno-sanitize-recover=all`: first UBSan finding
   aborts (fail fast, no warning-only runs); `-fbracket-depth=1024` is Stiff-proven hardening for
   Bend's deeply nested generated match chains (harmless on clang 19+).

**ABI coupling notes.** The patch and the ABI greps are coupled to the Bend release, not to this
repo's sources: regenerate/rebuild after every compiler change and after every `app/`/`effs/`
change (the C is emitted, not linked). If `build_asan.sh` reports `unexpected preserve_none layout`
or an `ABI mismatch`, stop and update the patch/contract consciously after reviewing the emitted C.

## 2. Run over the fixture corpus

```console
$ ./tools/run_asan.sh
run_asan: binary=<repo>/build/btar_asan
run_asan: fixtures=<repo>/fixtures/generated/valid (21 archives)
run_asan: ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 timeout=20s
run_asan: extraction SKIP (M1 lister / -xf unsupported: -xf probe rc=2: usage: btar -tf ARCHIVE ...)
[ 1/21] PASS base256_numeric              list=ok extract=-
...
[21/21] PASS trailing_slash_dir           list=ok extract=-

run_asan: list   21/21 clean
run_asan: extract SKIP (M1 lister: -xf unsupported)
RESULT: PASS
```

Flags: `--keep` (keep logs/extraction dirs; always kept on failure), `--regen` (regenerate
fixtures), `--no-extract`, `--timeout SECONDS` (default 20). Requires `build/btar_asan`; exits 2
with a hint if missing.

PASS means **process health only**: exit status in the btar contract (`0` success, `2` refused via
`IO.die`) and no sanitizer report. Output/tree correctness is covered by `./tools/run.sh list`
(differential listing) and `./tools/run_diff.sh` (extraction), not here.

**Extraction auto-detection.** `run_asan.sh` probes `-xf` against
`fixtures/generated/valid/single_file.tar`, first in `-C DIR` style then in cwd style, and checks
that `hello.txt` appeared. On the M1 lister both probes fail (rc=2 usage) and the extract phase is
skipped with the observed reason; once the M2 extractor lands the same script runs
`-xf` into fresh temp dirs per fixture with no edits. Deleted/renamed fixture layout stops the
extract probe (reported, not silently ignored).

**Sanitizer options.** `ASAN_OPTIONS=detect_leaks=0:abort_on_error=1`,
`UBSAN_OPTIONS=halt_on_error=1` (overridable from the environment). Leak detection is off because
the Bend runtime intentionally keeps process-lifetime state/allocations alive until exit; a CLI
that exits after one command is not a leak-detection target. **No suppressions are needed or used** —
all 21 valid fixtures and the fuzz corpus run report-free. If a future intentional runtime
allocation does trip ASan, add a *targeted* suppression/annotation for that symbol with a linked
explanation; never blanket-suppress (`detect_leaks=0` is the only global relaxation and is scoped to
leaks).

## 3. Header fuzzer

```console
$ python3 tools/fuzz_headers.py                 # 200 iterations, seed 0, ~3 s
fuzz_headers: bin=<repo>/build/btar_asan
fuzz_headers: iterations=200 seed=0 fixtures=21 list=-tf extract=SKIP timeout=5s
fuzz_headers: extraction -xf unsupported (probe status=ok detail=2)
fuzz_headers: runs=200 clean=200 findings=0 elapsed=2.6s
fuzz_headers: corpus_sha256=90ab73cdbc3979b869003e2b836cc94df59440ead56ef675fbcddb7ca611c2cc
fuzz_headers: record_dir=/tmp/btar-fuzz-0
RESULT: PASS
```

Flags: `--iterations N` (default 200), `--seed N` (default 0), `--deterministic` (forces seed 0;
the default is already deterministic), `--bin PATH`, `--timeout SECONDS` (default 5), `--no-extract`,
`--record-dir DIR` (default `/tmp/btar-fuzz-<seed>`).

Mutation classes (one per iteration, seeded `random.Random("seed:iteration")`):

| class | what it does |
|---|---|
| `field` | flips 1–3 random bytes in a random header field (name/mode/uid/gid/size/mtime/chksum/typeflag/linkname/magic/version/uname/gname/devmajor/devminor/prefix), checksum left stale |
| `field_fixed_checksum` | same, then recomputes the header checksum so the parser reads the mutated field |
| `truncate` | cuts the archive at a random (possibly unaligned) offset |
| `random_block` | replaces a random non-empty 512-byte block with random bytes |
| `append` | appends 1–1024 random bytes after the archive tail |
| `size_bomb` | writes base-256 size `1 TiB` into a header and fixes the checksum (skip-math probe) |
| `typeflag` | substitutes `0 d 2 1 5 7 S 4 D 3 M K L x g` into a header and fixes the checksum |
| `checksum_only` | flips a byte in the checksum field only |

`--deterministic`/default: same seed + fixture set ⇒ identical bytes; `corpus_sha256` lets two runs
be compared (`90ab73cd…` observed on both runs here). Each case is one `-tf` run (plus one `-xf`
run into a temp dir when extraction is detected). Findings are saved as
`/tmp/btar-fuzz-0/case-NNN.bin` + `case-NNN.json` (mutation descriptor, source fixture, commands,
status, stderr tail) and `run.json` records seed/iterations/corpus hash/binary. Classification:

| status | meaning | verdict |
|---|---|---|
| `ok` | exit 0 or 2 (listed/extracted or cleanly refused) and no sanitizer text | pass |
| `sanitizer` | stderr matches `ERROR: AddressSanitizer` / `AddressSanitizer:DEADLYSIGNAL` / `SUMMARY: *Sanitizer` / `runtime error:` / `UndefinedBehaviorSanitizer` | **FAIL** |
| `signal` | killed by a signal (negative `returncode`) | **FAIL** |
| `timeout` | exceeded `--timeout` | **FAIL** |
| `unexpected-exit` | any exit status outside 0/2 (btar contract) | **FAIL** |

Reproduce a finding directly:

```console
$ ASAN_OPTIONS='detect_leaks=0:abort_on_error=1' UBSAN_OPTIONS='halt_on_error=1' \
    ./build/btar_asan -tf /tmp/btar-fuzz-0/case-007.bin
```

The harness itself was validated with negatives: `--bin /bin/false --iterations 2` produces 2
`unexpected-exit` findings, saves cases, and exits 1; the extraction code path was smoke-tested with
`--bin /usr/bin/tar` (extract style detected as `argc`, `runs=12` clean).

## 4. Observed results (2026-10-25, M1 lister)

| check | result |
|---|---|
| build (`bend 2.0.39`, `clang 23.1.3`) | OK; ABI assertions pass; preserve_none 2 → 0; binary 4.65 MB |
| `run_asan.sh` over 21 valid fixtures (`-tf`) | **21/21 clean**, no ASan/UBSan reports, 0 timeouts |
| `-xf` extraction phase | SKIP — `app/main.bend` is still the M1 lister (probe rc=2 usage); auto-detected |
| `fuzz_headers.py` (200 iterations, seed 0) | **200/200 clean runs**, 0 crashes, 0 sanitizer reports, 0 timeouts, ~2.6 s |
| determinism | two runs produced identical `corpus_sha256=90ab73cd…c2cc` |
| extraction fuzz path | code path validated with GNU tar stand-in (12 runs); btar extractor not present yet |

No sanitizer findings to reproduce. The only runtime constraints seen: none (no mmap/heap false
positives from the Bend runtime); leaks are off by policy as described above.

## 5. M2 extraction integration

- After `app/` or `effs/` changes: `./tools/build_asan.sh && ./tools/run_asan.sh`. The build is
  cheap (~0.5 s emission + ~7 s clang) and always regenerates the C from the current app.
- Once `app/main.bend` implements `-xf`: `run_asan.sh` auto-enables extraction per fixture into
  temp dirs (`-C` style first, cwd fallback), and `fuzz_headers.py` auto-enables the extract run per
  case. Nothing needs to be edited; verify the header line changes from
  `extraction SKIP (...)` to `extraction enabled (-xf style: argc)`.
- When the extractor imports the effect module, `bend app/main.bend -o build/btar.c` embeds
  `effs/fs.c` C bodies into the same translation unit, so ASan/UBSan instrument the trusted effect
  layer automatically. Syscall args/path policy are then exercised by extraction and by the
  fixture corpus; the separate differential/security gates (`tools/run_diff.sh`,
  `tools/run_security.sh`) still own tree/policy correctness.
- Suggested gate wiring (Lead/run.sh scope): add an `asan` command that runs
  `build_asan.sh && run_asan.sh`, and a `fuzz` command for a short `fuzz_headers.py
  --iterations 200` run; keep both out of the fast JS-lane loop.

## 6. Limitations / honest notes

- **M1-only at the time of writing.** The extraction paths in `run_asan.sh`/`fuzz_headers.py` are
  implemented and smoke-tested against a stand-in, but have not yet run against a real btar `-xf`.
- Only the native C lane is instrumented; the JS lane (`bend tests/...`) is not, so a JS-only
  divergence is invisible to this gate.
- Fuzzing targets headers/metadata (the parser surface) with a 200-case budget; it is a smoke gate,
  not exhaustive/proof. Payload contents are not mutated (lister ignores them); compression is M5.
- The sanitizer build is inherently slower than `build/btar`; use it for tests, not benchmarks.
- `build/btar.c`/`btar.sanitized.c`/`btar_asan` are generated and gitignored; the patch is
  reproducible from the pinned Bend/clang versions. Regenerate per compiler release, never commit.
- Exit-status contract (0/2) is hard-coded in the fuzzer and run harness; if the CLI taxonomy
  changes, update `OK_EXIT_CODES`/`classify()` and this document.
