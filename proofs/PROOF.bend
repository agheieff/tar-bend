# proofs/PROOF.bend — proofs for laws/LAWS.bend (M2).
#
# Run: bend proofs/PROOF.bend            (gate: ALL PROOFS CHECK)
#      bend proofs/PROOF.bend --verdict  (proven kernel, see docs/proofs.md)
#
# Proofs are by computation/reflexivity or structural induction; no tactics.
# Importing LAWS is mandatory (bend refuses a PROOF beside LAWS otherwise).

import Base
import ../laws/LAWS.bend as Laws
import ../src/path.bend as Pth
import ../src/limits.bend as Lim
import ../src/pax.bend as Pax

# strip(0, name) = name. Induction on name: strip's loop matches name first,
# and its `zero` flag is True for n = 0, so it returns the name unchanged.
def Laws.strip_zero(name):
  match name:
    case Nil{}:
      {==}
    case +h <> t:
      {==}

# strip(n, []) = []. strip_go matches the empty list first, in every mode.
def Laws.strip_nil(n):
  {==}

# new_state(l) = MkState{l, 0, 0}; both accessors project the 0 literal.
def Laws.new_state_members(l):
  {==}

def Laws.new_state_bytes(l):
  {==}

# default_limits() reduces to the literal limits record; projection computes.
def Laws.default_members():
  {==}

# ---- M3 proofs (all by computation/reflexivity; concrete instances) ---

# Pax emit/parse round-trip: both sides normalise to the same Pax record.
def Laws.pax_roundtrip_concrete():
  {==}

# Path scan concrete instances: the driver normalises to the same Result.
def Laws.safe_dotdot_rejected():
  {==}

def Laws.safe_absolute_rejected():
  {==}

def Laws.safe_relative_ok():
  {==}

# strip(1, "a/b/c") = "b/c": the loop consumes 'a' and the following '/'.
def Laws.strip_one():
  {==}

# ---- M4 L10 cheap layout laws (computation/reflexivity) ----------------

def Laws.blocks_zero():
  {==}

def Laws.blocks_512():
  {==}

def Laws.blocks_513():
  {==}

def Laws.blocks_1023():
  {==}

def Laws.blocks_1024():
  {==}

def Laws.pax_pad_multiple():
  {==}

def Laws.pax_pad_grows():
  {==}
