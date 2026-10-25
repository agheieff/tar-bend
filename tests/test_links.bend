# tests/test_links.bend — GNU L/K payload NUL trimming.
import Base
import ../src/links.bend as L
import ../src/bytes.bend as B
import ./lib.bend as T

def main() -> IO(Unit):
  do IO<Unit>:
    +a : Unit <- T.check(B.eq_list(
      L.payload(B.from_list([104, 105, 0, 0, 0])), [104, 105], True{}),
      "longname payload trims NULs")
    +b : Unit <- T.check(B.eq_list(
      L.payload(B.from_list([97, 98, 99])), [97, 98, 99], True{}),
      "longlink payload without NUL")
    +c : Unit <- T.check(B.eq_list(L.payload(B.from_list([0])), Nil{}, True{}),
      "empty longname payload")
    IO.print("test_links: OK")
