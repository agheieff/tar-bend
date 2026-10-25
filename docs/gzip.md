# Gzip codec (v1.1) — streaming gunzip, segment-parallel gzip

Pure-Bend gzip (RFC 1952 / DEFLATE RFC 1951) in `src/`, plus a small effectful glue module.
v1.0 buffered whole streams in `List<U32>` (caps 8 / 8 / 16 MiB, 300–556 MiB RSS, 200–880× slower
than GNU); v1.1 replaces it with chunk-resumable table-driven decoding and a parallel
dynamic-Huffman encoder. No size caps remain; memory is bounded by chunk sizes.

| module | role | effects? |
|---|---|---|
| `src/crc.bend` | table-driven CRC-32 (`crc32`, running `CrcSt`) | no |
| `src/inflate.bend` | DEFLATE decode engine: bit reader, Huffman tables, window, block loop | no |
| `src/gunzip.bend` | gzip container: header/trailer/multi-member state machine, `gz_run` chunk API | no |
| `src/deflate.bend` | DEFLATE encoder for one segment: hash-chain LZ77, Huffman, block choice | no |
| `src/gzcomp.bend` | gzip writer: segmenting, parallel fork-join, CRC/ISIZE, `gc_run` chunk API | no |
| `src/gzio.bend` | pumps: file → decoder → pipe, pipe → compressor → file, drain/join | yes (`Fx.*`) |

Everything except `gzio.bend` is `bend --check-only` clean, `@unsafe`-free and structurally
terminating (fuel/shrinking-argument recursion, no mutual recursion).

## Reading (`-tzf`, `-xzf`, auto-detected `.tar.gz`)

```
archive file --read_exact(256 KiB)--> Gunzip.gz_run --write_bytes--> pipe --> tar reader (R.run)
        (forked decoder pump)                                  (main computation, unchanged)
```

- The decoder runs in an `IO.fork`ed computation and feeds an anonymous pipe (`Fs.pipe` effect);
  the unchanged tar reader consumes the pipe's read end. Nothing larger than one input chunk
  (256 KiB), one output flush (≈256 KiB) and the 32 KiB window is buffered, whatever the archive
  size: a 230 MiB `.tar.gz` (777 MB of tar) lists/extracts at ~26 MiB peak RSS.
- After the tar reader returns, the caller drains the pipe and joins the decoder, so the *whole*
  gzip stream — including the last member's CRC-32 and ISIZE — is always verified. Any gzip error
  anywhere ends the process with exit 2 and a `btar: gzip: …` message (the decoder's `IO.die`).
  Entries already extracted before a late error stay on disk (same as GNU tar).
- Multi-member streams are decoded member by member; each member's CRC-32/ISIZE is checked;
  trailing bytes that are not another member are rejected. Reserved FLG bits, bad CM, bad FHCRC,
  truncation at *any* byte, bad CRC/ISIZE and invalid DEFLATE data (bad Huffman tables, distance
  past the start of the member, invalid codes/lengths, stored-block LEN/NLEN mismatch) are errors.
- Decoder design: `Br` keeps a 32-bit accumulator; the engine decodes only while ≥ 8 input bytes
  remain (≥ 400 at a block header) so a symbol never underruns mid-way; at end of file the driver
  passes `last` and 512 zero bytes are appended — if the padding is consumed the stream was
  truncated. Huffman tables are flat `Array<U32>` indexed by the next `maxlen` bits (entry = code
  length | kind | extra-bit count/base), built per block; the 32 KiB window is a ring `Array`.
- `Gunzip.decompress(list)` is the whole-buffer convenience used by the unit tests.

## Writing (`-czf`)

```
tar writer (forked) --> pipe --> Gzcomp.gc_run (1 MiB rounds, 8 parallel segments) --> archive file
```

- The tar writer runs in a fork and feeds a pipe; the main computation reads 1 MiB rounds and
  compresses them. Each round is cut into 128 KiB **segments**; every segment is compressed
  independently with the last 32 KiB of the preceding input as its match dictionary, and the
  segments of a round run in parallel (Bend's parallel `let`, one task per segment, native
  threads — `+RTS --threads N` bounds the CPU count and the memory that comes with it).
- Per segment: greedy LZ77 over hash chains (3-byte hash, 2^15 buckets, chain ≤ 24, stop at
  length ≥ 64, length-3 matches only within 4 KiB); tokens collect into blocks of ≤ 16384 tokens
  / 65000 input bytes; each block is emitted as the cheapest of **stored / fixed Huffman /
  dynamic Huffman** (canonical codes, lengths ≤ 15 by frequency flattening, code-length alphabet
  with repeats 16/17/18, lengths ≤ 7). Segments end with an empty stored block (sync flush), so
  concatenating segments is a valid DEFLATE stream; the last call appends the final block and the
  CRC-32/ISIZE trailer.
- Output is **deterministic and independent of the thread count** (checked by 1- vs 8-thread
  runs); with `--sort=name` the archive bytes are reproducible.
- GNU gzip/zlib/Python read everything btar writes; `btar -czf` output is ~2–7 % larger than
  `gzip -6` on the benchmark data (see `bench/RESULTS.md`).
- The archive file is created once the walk has been collected; a failure while writing leaves a
  partial archive (like GNU tar). `btar` refuses to dump an archive into itself.

## Limits

- Input size is unlimited for reading; each member's tar entries obey the tar limits
  (members ≤ 4 GiB, total ≤ 4 GiB in `Lim`, ≤ 1 000 000 members).
- Whole-archive buffering exists nowhere; the extraction memory is the same as for plain tar.
- Compression memory ≈ 25 MiB per concurrently compressed segment on top of ~30 MiB; with a
  24-thread machine a large `-czf` peaks around 240 MiB (use `+RTS --threads 4` for ~60 MiB).
- Not implemented: `-z` on stdin/stdout (`-` archives), `--no-gzip`, deflate levels, bzip2/xz/zstd.

## Evidence

```bash
export PATH=$PWD/.cache/toolchain/bin:$PATH
bend tests/test_gzip.bend              # unit: CRC vectors, external fixed/dynamic/stored/multi-member
                                       # streams, 1-byte..64-byte chunking, every proper prefix rejected,
                                       # round trips of the own compressor, ratio spot checks
BTAR=$PWD/build/btar ./tools/test_gzip.sh   # 27 fixture checks + 10 streaming checks
python3 tools/test_gzip_stream.py build/btar # large create/extract, GNU interop, determinism, memory, self-archive
./tools/test_release.sh                # section 15: bombs, multi-member, 20 000 members, corrupt CRC
```
