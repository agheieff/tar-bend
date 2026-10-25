# tests/test_glob.bend — `--exclude` matcher vs the GNU tar 1.35 behaviour
# recorded in docs/format-support.md (expected values come from running GNU
# tar -c --exclude=PAT over these names).
import Base
import ../src/glob.bend as G
import ./lib.bend as T

def bs(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> bs(t)

def ck(+pat: String, +name: String, want: Bool) -> IO(Unit):
  match want:
    case True{}:
      T.check(G.excluded(bs(pat) <> Nil{}, bs(name)),
        "'" ++ pat ++ "' should exclude '" ++ name ++ "'")
    case False{}:
      T.check(Bool.not(G.excluded(bs(pat) <> Nil{}, bs(name))),
        "'" ++ pat ++ "' should not exclude '" ++ name ++ "'")

def main() -> IO(Unit):
  do IO<Unit>:
    +c0 : Unit <- ck("foo", "a/foo", True{})
    +c1 : Unit <- ck("foo", "a/foo/b/c.txt", True{})
    +c2 : Unit <- ck("foo", "a/foo.c", False{})
    +c3 : Unit <- ck("foo", "a/bar/foo.txt", False{})
    +c4 : Unit <- ck("*.o", "a/x.o", True{})
    +c5 : Unit <- ck("*.o", "a/foo/b/c.txt", False{})
    +c6 : Unit <- ck("a/foo", "a/foo", True{})
    +c7 : Unit <- ck("a/foo", "a/foo/b", True{})
    +c8 : Unit <- ck("a/foo", "./a/foo", True{})
    +c9 : Unit <- ck("foo/b", "a/foo/b", True{})
    +c10 : Unit <- ck("foo/b", "a/foo", False{})
    +c11 : Unit <- ck("fo?", "a/foo", True{})
    +c12 : Unit <- ck("fo?", "a/foo.c", False{})
    +c13 : Unit <- ck("a/*/foo", "a/foo/b", False{})
    +c14 : Unit <- ck("a/*/foo", "a/z/foo", True{})
    +c15 : Unit <- ck("./a/foo", "a/foo", False{})
    +c16 : Unit <- ck("./a/foo", "./a/foo", True{})
    +c17 : Unit <- ck("foo*", "a/foo.c", True{})
    +c18 : Unit <- ck("foo*", "a/bar/foo.txt", True{})
    +c19 : Unit <- ck("foo*", "a/x.o", False{})
    +c20 : Unit <- ck("[fb]a*", "a/bar", True{})
    +c21 : Unit <- ck("[fb]a*", "a", False{})
    +c22 : Unit <- ck("[fb]a*", "a/foo.c", False{})
    +c23 : Unit <- ck("a/[!f]*", "a/x.o", True{})
    +c24 : Unit <- ck("a/[!f]*", "a/foo.c", False{})
    +c25 : Unit <- ck("a/[!f]*", "a/bar", True{})
    +c26 : Unit <- ck("a/[^f]*", "a/bar", True{})
    +c27 : Unit <- ck("*/foo", "a/foo", True{})
    +c28 : Unit <- ck("*/foo", "a/bar/foo.txt", False{})
    +c29 : Unit <- ck("a\\*", "a/foo", False{})
    +c30 : Unit <- ck("a\\*", "a*", True{})
    +c31 : Unit <- ck("foo/", "a/foo", False{})
    +c32 : Unit <- ck("foo/", "a/foo/", False{})
    +c33 : Unit <- ck("a/foo*", "a/bar/foo.txt", False{})
    +c34 : Unit <- ck("a/foo*", "a/foo.c", True{})
    +c35 : Unit <- ck("*", "a/b", True{})
    +c36 : Unit <- ck("*", "", True{})
    +c37 : Unit <- ck("a", "a", True{})
    +c38 : Unit <- ck("a", "a/b", True{})
    +c39 : Unit <- ck("a", "ab", False{})
    +c40 : Unit <- ck("b", "a/foo/b", True{})
    +c41 : Unit <- ck("fo", "a/foo", False{})
    +c42 : Unit <- ck(".", ".", True{})
    +c43 : Unit <- ck(".", "./", True{})
    +c44 : Unit <- ck(".", "./x", True{})
    +c45 : Unit <- ck("[", "[", True{})
    +c46 : Unit <- ck("[", "a", False{})
    +c47 : Unit <- ck("a[", "a[", True{})
    +c48 : Unit <- ck("a[b", "a[b", True{})
    +c49 : Unit <- ck("[a-c]x", "bx", True{})
    +c50 : Unit <- ck("[a-c]x", "dx", False{})
    +c51 : Unit <- ck("[]]", "]", True{})
    +c52 : Unit <- ck("[!]]", "a", True{})
    +c53 : Unit <- ck("[!]]", "]", False{})
    +c54 : Unit <- ck("[a-]", "-", True{})
    +c55 : Unit <- ck("[a-]", "a", True{})
    +c56 : Unit <- ck("[a-]", "b", False{})
    +c57 : Unit <- ck("x[\\]]", "x]", True{})
    +c58 : Unit <- ck("*a*b*c", "xxaxxbxxc", True{})
    +c59 : Unit <- ck("*a*b*c", "xxaxxbxx", False{})
    +c60 : Unit <- ck("a*b", "a/x/b", True{})
    +c61 : Unit <- ck("**", "abc", True{})
    +c62 : Unit <- ck("?", "a", True{})
    +c63 : Unit <- ck("?", "ab", False{})
    +c64 : Unit <- ck("?", "", False{})
    +c65 : Unit <- ck("?", "x/y", True{})
    +c66 : Unit <- ck("x*", "dir/x1/y", True{})
    +c67 : Unit <- ck("y*", "dir/x1/y", True{})
    +c68 : Unit <- ck("dir", "dir//x", True{})
    +c69 : Unit <- ck("x", "a//x", True{})
    +z : Unit <- T.check(Bool.not(G.excluded(Nil{}, bs("a"))), "no patterns")
    IO.print("test_glob: OK")
