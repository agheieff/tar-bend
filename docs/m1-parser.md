# M1 — pure tar parser core + `btar -tf`

Status: **done (M1)**. Pure format core in `src/`, minimal lister CLI in `app/`.
Native build and JS lane both list v7/ustar/GNU/pax archives; differential lists
match GNU tar 1.35 on 20/21 generated valid fixtures (1 documented gap).

## Commands

```bash
export PATH=$PWD/.cache/toolchain/bin:$PATH   # Bend 2.0.39 pinned
bend version                                  # bend 2.0.39

# checker gate (all pure modules + app)
for f in src/*.bend app/main.bend; do bend --check-only "$f"; done

# pure-core self-checks (JS lane, fast)
./tests/run_tests.sh
# bend tests/test_num.bend  → assert via IO.die; failures exit non-zero

# lister, JS lane (small archives)
bend app/main.bend -- -tf ARCHIVE
bend app/main.bend -- -t -f ARCHIVE
bend app/main.bend -- --list -f ARCHIVE
bend app/main.bend -- -tf ARCHIVE -v     # -v accepted; M1 prints names only

# native build + differential listing harness
bend app/main.bend -o build/btar
./tests/list_fixtures.sh                 # builds build/btar if absent
BTAR_NATIVE=build/btar ./tests/list_fixtures.sh
```

Observed (native, `fixtures/generated/valid/`): `pass=20 fail=0 skip=1`
(skip = `non_utf8_name.tar`, see limitations). Sample:

```
$ ./build/btar -tf fixtures/generated/valid/dirs_nested.tar
d1/
d1/b.txt
d1/d2/
d1/d2/c.txt

$ diff <(./build/btar -tf fixtures/generated/valid/long_name_pax.tar | sort) \
       <(tar -tf fixtures/generated/valid/long_name_pax.tar | sort) && echo SAME
SAME
```

## Supported formats / fields

Reads (list): **v7**, **ustar**, POSIX **pax** per-file `x` and global `g`
(header pair retained; `path`, `linkpath`, `size` applied), GNU long name `L`
and long link `K`, GNU **base-256** numerics for size/mtime (non-negative,
must fit U32). Typeflags: regular, hardlink, symlink, dir are listed; pax/GNU
metadata is consumed; char/block device, fifo, contiguous, sparse/dumpdir and
unknown typeflags are rejected with a clear `btar: ...` error (exit 2).

Header validation: magic (`ustar\0`+`00`, GNU `ustar  \0`, or all-zero v7),
checksum (field 148..155 treated as spaces), numeric fields (octal with
leading spaces/zeros and trailing NUL/space; GNU base-256), ustar
`prefix + "/" + name`. Data skip is exactly `ceil(size/512)*512` blocks;
end of archive accepted at two zero blocks or clean EOF.

## Modules (all pure, no effects, no `@unsafe`)

| module | contents |
|---|---|
| `src/bytes.bend` | affine `Bytes` = packed LE `Array<U32>` + len; `from_list`/`to_list` (pack/unpack 4 bytes/word), bounds-checked `byte_at`/`u32_at`/`slice`, `clone`, `cstr`, `eq_list`, `blocks` (overflow-checked ceil), 512-block math |
| `src/num.bend` | octal decode (leading space/zero, trailing NUL/space, overflow→`None`), decimal decode (pax size, overflow-checked), GNU base-256 decode (marker bit, negative/over-range rejected), octal/checksum/decimal encode |
| `src/checksum.bend` | header checksum: sum all bytes, replace bytes 148..155 with 8 spaces (implemented as `total - field + 256`) |
| `src/header.bend` | `Header`, `Fmt` (v7/ustar/gnu), `Tag` (typeflag class), `parse(block) -> Result<String, Header>`, `full_name`, `data_blocks`, validity checks |
| `src/pax.bend` | `<len> key=value\n` record scan → `List<Kv>`, `Pax{path,linkpath,size,mtime,uid,gid,uname,gname}`, malformed records latched and dropped |
| `src/links.bend` | GNU L/K payload = data blocks, NUL-trimmed |
| `src/entry.bend` | `Entry`, `Pend` (per-file pax/L/K overrides), `St` parse states, pure transitions (`want`, `block`, `new_parsed`, `meta_payload`, `payload_apply`), name/link/size resolution |
| `app/main.bend` | CLI (`-tf`, `-t -f`, `--list -f`, `-v`), Base `File.open`/`File.size`/`File.read_bytes` whole-archive load, one tail-recursive fuel-bounded driver, `IO.die` on fatal errors. Bytes names never round-trip through `String` for matching; only `-t` output is converted (lossy for non-UTF-8). |

Design notes:
- Single recursive driver (`drive`, fuel first) with a state sum type; no
  mutual recursion, no loops/if, no raw array indexing.
- Affine handoffs: `StWant`/`StBlock` and `StMeta`/`StPayload` alternate so
  `Bytes` and `Bytes & Maybe<Bytes>` move without duplication; every byte
  read is bounds-checked.
- All sizes/offsets U32; overflow checks on octal/decimal/base-256 decode,
  checksum total, and block math. Archive >4 GiB / U32 cap is rejected.

## Tests

| file | covers |
|---|---|
| `tests/test_num.bend` | octal decode/malformed/overflow/max, decimal, encode round-trips, base-256 pos/neg/over-U32 |
| `tests/test_bytes.bend` | from_list/to_list round-trip, bounds-checked `byte_at`, LE `u32_at`, `slice`, `blocks` math incl. overflow, zero block |
| `tests/test_checksum.bend` | checksum of canonical ustar header = stored chksum (5239) |
| `tests/test_header.bend` | canonical ustar block parse (name/size/type/format/full name), corrupted block rejected |
| `tests/test_pax.bend` | `path=abc`, `size=42`, absent keys, unknown key ignored, malformed length dropped |
| `tests/test_links.bend` | L/K payload NUL trimming |
| `tests/canon_ustar.bend` | canonical 512-byte ustar header test data |
| `tests/lib.bend` | `IO.die` assertions |
| `tests/run_tests.sh` | check-only gate + all self-checks (PASS) |
| `tests/list_fixtures.sh` | native build, `btar -tf` vs `tar -tf`/`bsdtar -tf` normalized (PASS 20, SKIP 1) |

## Laws L1–L5 status (plan §6)

- **L1 checksum**: implemented and tested on a canonical header; full
  `checksum(encode_header(h)) == chksum_field(h)` proof NOT yet written
  (needs header encoder; M2/M3 `laws/LAWS.bend`). Status: partial.
- **L2 octal round-trip**: decode/encode implemented with overflow checks;
  unit-tested incl. max `0o37777777777`; law not yet stated/proven. Partial.
- **L3 base-256**: non-negative decode within U32, negative and >U32
  rejected; round-trip encoder not implemented yet (read-only). Partial.
- **L4 header round-trip**: decoder + validation done; encoder pending
  (writer milestone). Partial.
- **L5 pax record round-trip**: parse done; emit helper pending (M4 write
  side). Partial.
- Proof target untouched (`proofs/PROOF.bend` not in M1 scope); `src/` is
  pure and check-only clean, ready to be imported by laws.

## Limitations / known gaps

- **No streaming yet**: whole archive is read into memory (`File.read_bytes`
  + `Bytes`); M2 uses effects-based streaming with `read_exact`/`copy_data`.
- **No gzip** (`-z`) yet; no create/extract modes in M1 (list only).
- **`-v` is parsed but prints names only**; verbose metadata formatting is M4.
- **Non-UTF-8 names**: internal handling is byte-exact (`List<&2,U32>`), but
  `-t` output converts to Bend `String` (one codepoint per byte), so a byte
  `0xE9` prints as UTF-8 `é` rather than raw `\351`. Fix in M4 with a
  byte-writing output effect (`IO.print_bytes`) or an escape policy. The
  non-UTF-8 fixture is SKIPped by `tests/list_fixtures.sh`.
- **Global pax `g`**: parsed and retained, but M1 only applies per-file `x`
  overrides to names/sizes; global uid/gid/uname/gname/mtime are not applied
  to listing output (list output is names only).
- **pax keys applied**: `path`, `linkpath`, `size`. `mtime`, `uid`, `gid`,
  `uname`, `gname` are parsed into `Pax` for M4/explicit entries but not
  printed yet; unknown keys are preserved in the parsed `Kv` list but not
  exposed by `Pax`.
- **Large archives in JS lane**: the fast `bend app/main.bend` JS lane has a
  limited call stack; the 1 MiB fixture overflows it. Native `build/btar`
  handles it (harness builds native automatically).
- **Type limits**: 4 GiB / U32 cap (deliberate v1); `--strip-components`,
  path policy (`src/path.bend`) not implemented yet (M2); pax `mtime`
  decimal fractional values deferred; base-256 only 12-byte size/mtime
  fields, read-only.
- End of archive: a single zero block is *accepted as EOF* after one zero
  block (GNU-compatible leniency); trailing garbage after the end block is
  not diagnosed. Truncated archives that end cleanly at a block boundary are
  accepted (documented; M3 hardening adds strict end checks).

## Notes for M2 (effects-based streaming)

- Keep `src/` pure and byte-exact: `Bytes` already gives the byte-list view
  used by header/pax parsing; M2 driver should read one 512-byte block at a
  time via a `read_exact` effect and feed `Header.parse`.
- `src/entry.bend` state sum is ready for an effect driver: replace
  `StWant`/`StBlock` pair handoffs with `read_exact(off, 512)` results and
  keep the same transition table; `StPayload` becomes a bounded pax/longname
  read (≤64 KiB limit).
- Path policy (`src/path.bend`, laws L6–L7) and limits (`src/limits.bend`,
  L8) are the next pure modules; M1 deliberately has no extraction.
- Global pax scope (`St.glob`) is threaded through; when output grows, apply
  `g` records at the same point per-file `x` records are applied.
- Non-UTF-8 list output needs a byte-oriented output effect; do not change
  name matching to `String` (current code keeps matching byte-exact).
