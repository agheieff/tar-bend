# tests/test_upd.bend — `-u` name normalisation and newer-than logic.
import Base
import ../src/upd.bend as U
import ../src/bytes.bend as B
import ./lib.bend as T

def tab() -> U.Tab:
  U.tab_add(U.tab_add(U.tab_add(U.tab_add(U.TNil{},
    U.am_new([100, 47], 100)), U.am_new([46, 47, 100, 47, 97], 200)),
    U.am_new([98], 50)), U.am_new([98], 70))

def main() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- T.check(B.eq_list(U.norm([46, 47, 46, 47, 100, 47, 47]),
      [100], True{}), "norm strips ./ and trailing slashes")
    +b : Unit <- T.check(B.eq_list(U.norm([46, 47]), Nil{}, True{}),
      "norm of ./ is empty")
    +c : Unit <- T.check(B.eq_list(U.norm([46, 98]), [46, 98], True{}),
      "norm keeps dotfiles")
    +d : Unit <- T.check(U.skip(tab(), [100], 100), "same mtime skips dir")
    +e : Unit <- T.check(Bool.not(U.skip(tab(), [100], 101)),
      "newer disk dir is appended")
    +f : Unit <- T.check(U.skip(tab(), [100, 47, 97], 200),
      "d/a equal mtime skips")
    +g : Unit <- T.check(Bool.not(U.skip(tab(), [100, 47, 97], 201)),
      "d/a newer appended")
    +h : Unit <- T.check(U.skip(tab(), [98], 70),
      "any archived copy >= disk skips")
    +i : Unit <- T.check(Bool.not(U.skip(tab(), [98], 71)),
      "all archived copies older appends")
    +j : Unit <- T.check(Bool.not(U.skip(tab(), [122], 1)),
      "unknown name appends")
    +k : Unit <- T.check(Bool.not(U.skip(U.TNil{}, [100], 1)),
      "empty table never skips")
    IO.print("test_upd: OK")
