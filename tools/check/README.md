# check/

Five ways of asking "does it still work", cheapest first. The first three are the ones `CLAUDE.md`
requires after every change; the last two are for behaviour, which has no load-time signal.

- `docs.py` — does the documentation still describe the code. Every backticked path exists, every
  link resolves, no heading is owned by two files, no file is past its word budget. Launches
  nothing, so it costs a second and goes first.
- `prototypes.ps1` — does the data stage load. Headless, no behaviour tested.
- `translations.py` — any prototype whose name or description resolves to nothing.
- `probe.ps1` + `probe_client.py` — a headless server on a **copy** of a save, driven with
  arbitrary Lua over RCON. `probe-settings.json` is what keeps it ticking with nobody connected:
  `--no-auto-pause` is not a command-line flag, and without `auto_pause: false` a harness waits
  forever for items that cannot move.
- `player.ps1` — the same idea in the real client, for the two things headless cannot do:
  anything needing a player (`build_from_cursor`, cursor stack, reach) and anything needing
  pixels.

All four take `-Instance <name>` and then run against `.factorio/<name>/` instead of the
standalone install in `factorio/`, so several can run at once. `probe_client.py` and
`translations.py` spell it `--instance`. Create the instance first with
`setup/dev-mode.ps1 -Instance <name>`, or the mod is not junctioned into it and the checks pass
against base game alone.

Two traps, both of which present as something else entirely:

- **A running `probe.ps1` holds Factorio's lock file.** `prototypes.ps1` then fails with
  "Couldn't create lock file", which reads exactly like a mod error. Always `-Action stop` when
  you are done. Two servers under different `-Instance` names hold different lock files, so this
  only bites within one instance.
- **`prototypes.ps1` validates the mods folder, not `src/`.** A mods folder holding a built zip
  where the junction should be passes the check for whatever code that zip froze. `zip.py` no
  longer installs one, so this only bites if you put it there — re-run `setup/dev-mode.ps1` after.

`.verify/rcon.json` carries the running server's port and password. All three scripts resolve it
relative to their own directory, so they have to stay in this folder together. Under `-Instance`
the same file moves to `.factorio/<name>/state/`, one per instance — which is also what stops two
of them refusing to start on each other's "a server is already tracked" guard. It is the one part
of an instance that does not follow the write-data directory, so it stays out of `factorio/`.
