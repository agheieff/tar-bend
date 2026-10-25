import Base
import ../effs/effects.bend as Fx

def main() -> IO(Unit):
  do IO<Unit>:
    IO.try(Unit, Fx.Stdout.write([255, 0, 65, 10]))
