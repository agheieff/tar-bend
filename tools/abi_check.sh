#!/bin/sh
# tar-bend ABI gate (Stiff pattern). Effects are compiler-pinned private ABI:
# this script fails before clang with a clear message when the generated C no
# longer matches the contract effs/fs.c is written against. Run it before any
# native build; CI runs it first (AGENTS.md gate 1).
#
# Checks:
#   1. `bend version` is exactly the pinned 2.0.39.
#   2. a tiny effect program generates C (type-checks, splices effects);
#   3. the generated C has the exact effect ABI lines: io_eff(u32, Effect),
#      typedef Term (*Effect)(Env e, Term* f, IoWork* w), the run signature,
#      the request-processing call site that invokes effects, and the runtime
#      helpers effs/fs.c uses (io_hand/io_cbuf/io_list/io_res/io_tup/io_work).
set -eu

bend_pin='bend 2.0.39'
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bend=${BEND:-$root/.cache/toolchain/bin/bend}
tmp=
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

fail() {
  echo "abi_check: $*" >&2
  echo "abi_check: Bend's effect ABI moved; re-read .cache/toolchain/guide/EFFECTS.md" >&2
  echo "abi_check: and update effs/fs.c before shipping a native build." >&2
  exit 1
}

command -v "$bend" >/dev/null 2>&1 || fail "no bend binary at $bend"
got=$("$bend" version)
[ "$got" = "$bend_pin" ] || fail "wanted compiler pin '$bend_pin', got '$got'"

tmp=$(mktemp -d)
cat > "$tmp/abi.bend" <<'BEND'
import Base

def Abi.tick() -> IO(U32):
  import "./abi.c"
  import "./abi.js"

def Abi.eat(xs: List<&2, U32>) -> IO(U32):
  import "./abi.c"
  import "./abi.js"

def main() -> IO(Unit):
  do IO<Unit>:
    t : U32 <- Abi.tick()
    n : U32 <- Abi.eat([1, 2, 3])
    # Force Base's reference process_run.c body into the generated C so the
    # "effective process_run signature" is asserted, not just our own effect.
    _ : U32 & (String & String) <- IO.try(U32 & (String & String),
      Process.run("/bin/true", [], "", 4096, 5000))
    IO.print(U32.show(U32.add(t, n)))
BEND
cat > "$tmp/abi.c" <<'C'
// ABI probe body: one plain value effect and one List<U32> (Bytes) effect,
// both registered in one constructor, exactly like effs/fs.c.
#include <errno.h>

Term abi_tick_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  return (Term)(uint32_t)7;
}

static Term abi_eat_run(Env e, Term* f, IoWork* w) {
  u64 n = 0;
  char* p = io_cbuf(e, f[0], &n, CID(Con));
  Term xs = io_list(e, p, n);
  free(p);
  (void)xs; (void)w;
  return (Term)(uint32_t)n;
}

static void __attribute__((constructor)) abi_use(void) {
  io_eff(CID(Abi.tick), abi_tick_run);
  io_eff(CID(Abi.eat), abi_eat_run);
}
C
cat > "$tmp/abi.js" <<'JS'
function abi_tick() { return 7; }
function abi_eat(xs) {
  let n = 0;
  for (; xs.$ === "Con"; xs = xs.tail) { n += 1; }
  return n;
}
io_eff(CID(Abi.tick), abi_tick);
io_eff(CID(Abi.eat), abi_eat);
JS

c=$tmp/abi.out.c
BEND_NO_TELEMETRY=1 "$bend" "$tmp/abi.bend" -o "$c" >/dev/null 2>&1 \
  || fail "the ABI probe program failed to build to C (bend $got)"

# The lines effs/fs.c is written against. grep -F: exact text, no regex.
check() {
  n=$1
  shift
  grep -qF "$*" "$c" || fail "generated C lacks ABI line $n: $*"
}
check 1 'typedef Term (*Effect)(Env e, Term* f, IoWork* w);'
check 2 'static void io_eff(u32 cid, Effect run) {'
check 3 'Term abi_tick_run(Env e, Term* f, IoWork* w) {'
check 4 'io_eff(CID_Abi_tick, abi_tick_run);'
# The effective request-processing signature: io_step evaluates the IO request,
# then calls the registered effect as run(e, args, work).
check 5 'static void io_step(Env e, IoWork* a) {'
check 6 'Term process_run_run(Env e, Term* f, IoWork* w) {'
check 7 'io_eff_rows[c](e, fs, a)'
check 8 '#define io_hand_v(t) ((term_aux(t) << 40) | term_loc(t))'
check 9 '#define io_res(e, w, v) ((w)->code ? io_fail(e, (w)->code, NULL) \'
check 10 '#define io_tup(e, a, b) io_node(e, CID_Tuple, a, b)'
check 11 'OUTLINE char* io_cbuf(Env e, Term s, u64* len, u64 cons) {'
check 12 'static Term io_list(Env e, const char* p, u64 n) {'
check 13 'static u64 io_sys_end(IoWork* w, ssize_t n) {'
check 14 'static Term io_work(IoWork* w, IoCall call, IoPack pack) {'

echo "ABI OK: $bend_pin effect ABI matches effs/fs.c ($tmp/abi.c.out)"
