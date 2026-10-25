# Proofs — M2/M3 (path, limits, pax encoder, header/checksum encoder laws)

Status: **17 laws proven in the main gate** (both `bend proofs/PROOF.bend` and
`--verdict` green) and **15 heavy M3/M4 laws proven by `bend proofs/PROOF_HEAVY.bend`**
(L1/L4 canonical encoder round-trips, L10 block layout, L9 writer-model
round-trips; excluded from the `--verdict` gate: the BendTT kernel reports
"out of fuel" normalising 512-byte block lists — toolchain limitation, not a
wrong proof; ~12 s run).  No law in `laws/LAWS.bend` is unproven (open claims
are prose TODOs, not `law` declarations, so the gate stays honest).

## Commands and results

```bash
export PATH=$PWD/.cache/toolchain/bin:$PATH   # Bend 2.0.39

bend proofs/PROOF.bend            # main gate (17 laws)
# → ALL PROOFS CHECK
bend proofs/PROOF.bend --verdict  # proven BendTT kernel re-check
# → ALL PROOFS CHECK
bend proofs/PROOF_HEAVY.bend      # heavy M3/M4 laws (15 laws, ~12 s)
# → ALL PROOFS CHECK   (not part of --verdict gate; kernel out of fuel)
bend --check-only laws/LAWS.bend  # open claims only: "SOME PROOFS FAIL: 5 TODOs"
                                  # (expected; the gate is proofs/PROOF.bend)
./tests/run_tests.sh              # includes the laws gate + all self-checks
```

Observed on Bend 2.0.39 / Linux x86-64: `ALL PROOFS CHECK` for both the normal
run and `--verdict` (no kernel rejection). `laws/LAWS.bend` on its own lists
the five claims as TODOs by design (open claims; they are closed by the proof
defs in `proofs/PROOF.bend`).

Test evidence for the same modules: `bend tests/test_path.bend` and
`bend tests/test_limits.bend` (JS lane) print `OK`; the boundary/overflow
cases listed in `tests/` cover the runtime behaviour the laws state.
At M2 handoff the shared `./tests/run_tests.sh` also check-onlys concurrently
written extractor files (`src/read_stream.bend`, `src/extract.bend`); those
were in-flight placeholders at that moment, so rerun the full script after the
extractor lands. The M2 suites, `src/path.bend`, `src/limits.bend`,
`laws/`, `proofs/` all pass as listed above.

## Proven laws (`laws/LAWS.bend`, `proofs/PROOF.bend`) — main gate

| law | statement | proof |
|---|---|---|
| `strip_zero` | `Pth.strip(0, name) == name` | induction on `name`; `zero` flag is `True`, loop returns the name |
| `strip_nil` | `Pth.strip(n, Nil{}) == Nil{}` | reflexivity: empty list matches first in every mode |
| `new_state_members` | `Lim.member_count(Lim.new_state(l)) == 0` | reflexivity (record projection of the `0` literal) |
| `new_state_bytes` | `Lim.byte_count(Lim.new_state(l)) == 0` | reflexivity (byte projection) |
| `default_members` | `Lim.max_members(Lim.default_limits()) == 1000000` | computation (literal record projection) |
| `pax_roundtrip_concrete` (L5) | `Pax.parse(Pax.emit([Kv{"path","abc"}])) == MkPax{path=Some{"abc"}, ...}` | both sides compute: forces the `<len>` fixed point (14) + parser lookups |
| `safe_dotdot_rejected` (L6) | `Pth.safe(255,4096,[46,46]) == Fail{Parent{}}` | computation through the real scan driver |
| `safe_absolute_rejected` (L6) | `Pth.safe(255,4096,[47,97]) == Fail{Absolute{}}` | computation through the real scan driver |
| `safe_relative_ok` (L6) | `Pth.safe(255,4096,[97,47,98]) == Done{[97,47,98]}` | computation; normal output has no `..` (instance of no-parent) |
| `strip_one` (L7) | `Pth.strip(1,[97,47,98,47,99]) == [98,47,99]` | computation through the strip loop |
| `blocks_zero/512/513/1023/1024` (L10) | `B.blocks(n) == Some{ceil(n/512)}` for n in {0,512,513,1023,1024} | computation: real overflow guard + U32 division block math |
| `pax_pad_multiple` / `pax_pad_grows` (L10) | `len(Pax.pad_payload(v)) mod 512 = 0` and `>= len(v)` (v = 3 bytes) | computation of the real padding helper |

## Heavy encoder laws (`proofs/PROOF_HEAVY.bend`, `bend` only)

| law | statement | proof | why not in --verdict |
|---|---|---|---|
| `checksum_canonical` (L1) | `decode_chksum(encode(h)) == C.compute_list(encode(h))` for the canonical header `h` | computation: encode the fixture (512 bytes), decode the emitted chksum field, sum the block | BendTT kernel: "out of fuel" normalising the block |
| `header_roundtrip_canonical` (L4) | `H.parse(B.from_list(H.encode_list(h))) == Done{h}` field-wise for the canonical `h` | computation: encoder emits, parser validates checksum/octal fields and rebuilds the record; both normalise to the same `MkHeader` | same kernel fuel limit |
| `encoded_block_len_512` (L10) | `len(H.encode_list(h)) == 512` | computation (matches writer block layout) | block normalisation fuel |
| `encoded_block_tail_zero` (L10) | last 12 bytes of an encoded block are zero | computation (encoder padding field) | block normalisation fuel |
| `model_write_len` / `..._multiple_512` (L10) | 4-entry writer model is 3584 bytes, a 512 multiple | computation of the pure model writer (real encoder + pax padding + EOF zeros) | model normalises a 3584-byte list |
| `model_first_block_512` (L10) | first reader slice is 512 bytes | computation | same |
| `model_reg/dir/sym/hard_header_roundtrip` (L9) | `header_at(model, off) == Some{h}` for the four canonical entries (regular size 6, dir, symlink, hardlink) | writer model emits real blocks, reader model runs the real parser on 512-byte slices; both sides normalise to the same `Maybe<Header>` | same |
| `model_names` (L9) | recovered names at offsets 0 and 1024 are `a.txt` and `dir/` | computation through encoder+parser | same |
| `model_data_blocks` (L9) | `B.blocks(size_at(model,0)) == Some{1}` (6-byte payload = one data block) | computation; links the writer's skip math to the encoder's size field | same |
| `model_eof_two_zero_blocks` (L10) | trailer slice `[2560,3584)` is all zero (two 512-byte blocks) | computation via `Bytes.is_zero` | same |
| `model_last_header_offset` (L10) | `512+512+512+512 == 2048` (offset of last header) | Nat computation | tiny |

These two are machine-checked by `bend proofs/PROOF_HEAVY.bend` (ALL PROOFS
CHECK, ~2.5 s), which exercises the real `H.encode` + `H.parse` and the
checksum module end-to-end.  They are deliberately NOT imported by
`proofs/PROOF.bend` so the `--verdict` gate stays green; the exact statements
are also recorded as prose TODOs in `laws/LAWS.bend`.

## TODO laws (stated in `laws/LAWS.bend` as prose; deferred, honestly not proven)

- **L6 `path_safe_no_parent`**: if `Pth.safe` succeeds its result has no `..`
  component (and no empty/`.` components). Feasible but needs an invariant
  over the scan state machine (flags: component class, accumulated output) and
  induction over `fuel`/name; the state is a sum type with a fuel argument, so
  the induction hypothesis needs a generalised invariant, not just the final
  goal. Deferred to M3 when the policy state is refactored to make the
  invariant small (e.g. prove the component-level `commit` helper correct, then
  lift to the driver).
- **L6 `path_safe_idempotent`**: `safe(safe(name)) == safe(name)` when the
  first succeeds. Needs (a) "output components are already normal" (from the
  no-parent invariant) and (b) a split/join round-trip lemma for the output
  list; both are list inductions. Deferred to M3.
- **L7 `strip_components`**: result equals dropping the first `n` components
  (a structural recursion on `name` when stated as `strip(n,name) ==
  strip_spec(n, split(name))`). Needs a `split` model; M3.
- **L8 `limits_boundaries`**: `add_member` answers `Member{}`/`Members{}`/
  `Total{}` exactly when the corresponding limit would be passed (and never
  wraps). Blocked on usable U32 ordering lemmas: `U32` is a Church `Word(32)`
  with `Cmp`-based `is_gt`/`is_ge`; proving `is_gt`/`is_ge` algebra over
  `Word(32)` is the current proof-language friction (see below). The
  implementation is guarded: the total add only happens after
  `bytes <= max_total - size`, so the U32 add cannot wrap; runtime tests cover
  `U32`-max member + one more byte → `Total{}`.
- **L1/L4 forall-header versions**: only concrete canonical instances are
  proven (heavy file); the `forall h` statement needs symbolic encoder lemmas
  (octal-field encode/decode round-trip for symbolic values is stuck because
  `U32.mod`/`U32.div` are opaque on variables). L2/L3 encode-direction
  round-trips are the enabling lemmas for M4.
- **L9/L10 general (forall-manifest) versions**: only a CONCRETE 4-entry
  writer-model round-trip is machine-checked (`PROOF_HEAVY.bend`), plus
  concrete block-math and padding instances in the main gate. A forall
  `model_parse(model_write(entries)) == entries` needs a recursive pure
  writer/reader model (not in src/ per M4 scope) and parametric U32 block
  math lemmas (`blocks(size)*512 >= size`, `< size+512`), which stay neutral
  symbolically today. The effectful writer itself (src/write.bend, C copy
  effects, dirfd traversal) is outside the proof target.
- **L8 limits boundaries**: unchanged (missing U32 `is_gt`/`is_ge` lemmas).

## Proof-language frictions found

- No tactics; only `{==}` (definitional computation), `match` refinement,
  `%e : P` rewrite, and recursive defs as induction hypotheses. For the path
  driver the induction is over a *fuel* `Nat` with a compound state, so a
  generalised invariant must be stated as its own law helper — doable but
  multi-hour, deferred rather than faked.
- Definitional reduction only unfolds opaque-looking calls when arguments are
  literals/constructors; e.g. `Pth.strip(0, name)` normalises to
  `strip_go(name, True{}, 0, ...)` and then needs the `match name` split to
  finish (hence induction on `name` in `strip_zero`).
- `U32` is Church-encoded `Word(32)`; arithmetic/ordering lemmas are proven in
  Base for `Word.add_comm` but not lifted to the `is_gt`/`is_ge` booleans used
  by limits, which is why L8's boundary law is deferred rather than hand-proved
  by case analysis over `Word(32)` terms.
- Zero-argument laws are proven by `def Laws.<name>():` (empty parens needed),
  and proof defs must live under the `Laws` namespace matching the `LAWS.bend`
  import alias.
- Concrete laws over the real encoders work well in `bend` (2.5 s for two
  512-byte-block laws), but the BendTT `--verdict` kernel has a small
  normalization fuel: summing/parsing 512-byte lists reports "out of fuel".
  Hence the split gate (main 10 laws under --verdict; heavy 2 laws under
  `bend` only), documented honestly above.
- Symbolic limits/headers do not normalise: `Nat`/`U32` comparisons on
  variables stay neutral, so `forall c t {safe(c,t,Nil) == Done{Nil}}` is
  stuck even though it is true. Concrete instances + runtime tests cover it
  until U32/Nat lemmas exist (`Word.cmp` algebra).

## Trusted base

`src/path.bend` and `src/limits.bend` are pure Bend (no effects, no
`@unsafe`), checked by `bend --check-only`. The trust base for extraction
remains the C effects (`effs/`), Linux syscall/VFS semantics, clang-generated C
and the Bend runtime; the proof target excludes `app/`, `effs/` and `tools/`.
The `--verdict` kernel re-checks the translation and accepted this proof set
(`ALL PROOFS CHECK`), relying on no `@unsafe`/foreign code.

## M4 trust boundary: proven layout vs effectful writer

Proven (this round): the pure byte layout of a ustar block (encoder output is
exactly 512 bytes, tail padding zero), block math `ceil(size/512)`
concrete instances, pax payload padding properties, and a concrete 4-entry
writer-model round-trip through the real encoder/parser (headers, names, data
block count, two-zero-block EOF, total length multiple of 512).

NOT proven (trusted/effectful, covered by differential tests instead): the
M4 writer's filesystem side — `src/write.bend`/`app/` manifest traversal,
`copy_data`/`write_bytes` syscall effects in `effs/`, real file sizes/mtimes
from `stat`, and error paths. Trust base stays: C effects + Linux syscalls +
clang-generated C + Bend runtime (docs/trusted-base.md); the pure core above
is what the writer composes, so a byte-layout regression is caught by these
laws, while IO/data-plane correctness is established differentially
(GNU tar/bsdtar) and by the M0 security harness.

## Next (M3/M4)

1. Refactor the path scan state to expose a component-level commit helper and
   prove L6 no-parent + idempotence over it (invariant helpers as laws).
2. Add `split`/`join` pure model and prove L7 strip.
3. Lift U32 ordering lemmas (or state limits laws over `Nat` counters in a
   pure model, keeping the U32 implementation as the extracted one) for L8.
4. Encoder lands with the writer: L2/L3 round-trips, L1 checksum, L4 header
   round-trip, L9 writer, L10 data-skip/end-of-archive.
