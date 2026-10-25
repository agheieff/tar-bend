# laws/LAWS.bend — machine-checked laws for the pure core (M2).
#
# Each `law` is an open claim; proofs/PROOF.bend proves it with a def of the
# same name under the `Laws` namespace. The gate is `bend proofs/PROOF.bend`
# (ALL PROOFS CHECK), then `--verdict` for the proven kernel.
#
# TODO laws (stated here as prose, NOT as `law`, so the gate stays honest):
#  L6 path_safe_no_parent: for all names, if Pth.safe succeeds the result has
#     no ".." component. Needs induction over the safe state machine and an
#     invariant lemma; deferred to M3 (documented in docs/proofs.md).
#  L6 path_safe_idempotent: Pth.safe (Pth.safe name) = Pth.safe name. Needs
#     a normalisation-fixed-point lemma over the component scan; deferred.
#  L8 limits_boundaries: add_member answers Member{}/Members{}/Total{} exactly
#     when a limit would be passed. Needs U32 ordering lemmas (Word.cmp);
#     deferred to M3.
#  L1/L4/L9/L10: checksum/header/writer laws need the encoder (M3/M4).

import Base
import ../src/path.bend as Pth
import ../src/limits.bend as Lim
import ../src/pax.bend as Pax
import ../src/bytes.bend as B

# strip(0, name) = name: dropping zero components is the identity.
law strip_zero:
  for name: List<&2, U32>
  {Pth.strip(0, name) == name : List<&2, U32>}

# strip(n, []) = []: an empty name has no components to drop.
law strip_nil:
  for n: U32
  {Pth.strip(n, Nil{}) == Nil{} : List<&2, U32>}

# A fresh state has no members.
law new_state_members:
  for l: Lim.Limits
  {Lim.member_count(Lim.new_state(l)) == 0 : U32}

# A fresh state has no counted bytes.
law new_state_bytes:
  for l: Lim.Limits
  {Lim.byte_count(Lim.new_state(l)) == 0 : U32}

# The default member limit is the plan's 1,000,000.
law default_members:
  {Lim.max_members(Lim.default_limits()) == 1000000 : U32}

# ---- M3: pax encoder round-trip (L5 instance) -------------------------
#
# `emit` writes "<len> key=value\n"; the existing parser reads it back to
# the same exposed fields.  This is a concrete, non-vacuous instance: it
# forces the length computation (14 = "path"+"abc" record) and the parser.
law pax_roundtrip_concrete:
  {Pax.parse(Pax.emit([Pax.Kv{[112, 97, 116, 104], [97, 98, 99]}])) ==
    Pax.MkPax{Some{[97, 98, 99]}, None{}, None{}, None{}, None{}, None{},
      None{}, None{}} : Pax.Pax}

# ---- M3: path policy concrete instances (L6 partial) ------------------
#
# Full forall-name L6 no-parent is a TODO (see docs/proofs.md): the scan
# driver's fuel is data-dependent (2*len+...), so the induction hypothesis
# needs a generalised invariant over the St sum type.  These concrete
# instances are machine-checked end-to-end through the real scan driver.

law safe_dotdot_rejected:
  {Pth.safe(255, 4096, [46, 46]) == Fail{Pth.Parent{}} :
    Result<&1, &1, Pth.Err, List<&2, U32>>}

law safe_absolute_rejected:
  {Pth.safe(255, 4096, [47, 97]) == Fail{Pth.Absolute{}} :
    Result<&1, &1, Pth.Err, List<&2, U32>>}

# safe("a/b") = "a/b": a normalised relative path is accepted unchanged,
# hence contains no ".." component (no-parent on this instance).
law safe_relative_ok:
  {Pth.safe(255, 4096, [97, 47, 98]) == Done{[97, 47, 98]} :
    Result<&1, &1, Pth.Err, List<&2, U32>>}

# ---- M3: strip-components instance (L7 partial) -----------------------

law strip_one:
  {Pth.strip(1, [97, 47, 98, 47, 99]) == [98, 47, 99] : List<&2, U32>}

# ---- TODO (prose only; NOT law claims) --------------------------------
#
# L1 `checksum_canonical`: for the canonical header,
#     decode_chksum(encode(h)) == C.compute_list(encode(h)).
#   The statement + proof ARE machine-checked by `bend` (ALL PROOFS CHECK)
#   in `proofs/PROOF_HEAVY.bend`, but that file is kept OUT of the main
#   gate: summarising the 512-byte block makes the BendTT kernel report
#   "out of fuel" on `--verdict` (a kernel limitation, not a wrong proof).
# L4 `header_roundtrip_canonical`: parse(encode(h)) == Done{h} for the
#   canonical header -- same situation (429-byte block normalisation:
#   checksum over 512 bytes + field decodes exceed the kernel fuel).
# L6 `path_safe_no_parent` (forall names) and `path_safe_idempotent`:
#   deferred; need a generalised invariant over Pth's fuel+St scan.
# L8 limits boundaries: deferred (missing U32 is_gt/is_ge lemmas).
# L1/L4 forall-header versions: need symbolic encoder lemmas; deferred.

# ---- M4: L10 layout / block-math laws (cheap, kernel-checked) ---------
#
# B.blocks(size) is ceil(size/512) for in-range sizes (None past the U32
# cap).  These concrete instances are non-vacuous: they exercise the real
# overflow guard + U32 division in the block math shared by reader/writer.
# Parametric versions need U32 division lemmas (see TODO in docs/proofs.md).

law blocks_zero:
  {B.blocks(0) == Some{0} : Maybe<&2, U32>}

law blocks_512:
  {B.blocks(512) == Some{1} : Maybe<&2, U32>}

law blocks_513:
  {B.blocks(513) == Some{2} : Maybe<&2, U32>}

law blocks_1023:
  {B.blocks(1023) == Some{2} : Maybe<&2, U32>}

law blocks_1024:
  {B.blocks(1024) == Some{2} : Maybe<&2, U32>}

# Pax payload padding: pad_payload(v) has a 512-multiple length and is at
# least as long as v (here |v| = 3).
law pax_pad_multiple:
  {Nat.mod(List.length(&2, U32, Pax.pad_payload([1, 2, 3])), 512n) == 0n :
    Nat}

law pax_pad_grows:
  {Nat.is_ge(List.length(&2, U32, Pax.pad_payload([1, 2, 3])), 3n) == True{} :
    Bool}
