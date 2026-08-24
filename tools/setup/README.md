# setup/

Run once per machine — plus `dev-mode.ps1` again after every release build.

- `dev-mode.ps1` — junctions `src/` into `factorio/mods`, and is what first writes
  `factorio/config/config.ini` and seeds the mod list. Run it once before any check.
- `dev-mode.ps1 -Instance <name>` — the same junction, into that instance's mods folder instead.
  Run it once per instance: it is also what creates the instance, so the checks have somewhere to
  point.
- `mod-list.json` — the seed every instance's mod list is copied from: `base` and `profitorio`
  enabled, the four DLC data dirs the expansion build ships explicitly disabled. Copied rather
  than generated, because Factorio writes one enabling everything it finds and the mod is then
  tested against a prototype set it never ships with.
- `requirements.txt` — the single pip dependency. Only `generate/icons.py` needs it; every other
  script in `tools/` is stdlib-only, which is why this is one line rather than a lockfile.
