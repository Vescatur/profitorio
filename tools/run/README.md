# run/

- `playtest.ps1` — launches `factorio/bin/x64/factorio.exe` on the dev save.

Play without `-Instance`. The point of instances is to keep agents off the install holding your
dev save, so the one session that should stay on it is yours. Neither reaches the Factorio you
play — that one is not in this repo.

One file, deliberately. Playing the mod is the only thing here that is not a check; the
verification scripts that also start Factorio live in `check/`, grouped with the checks they
belong to rather than with the other things that launch the game.
