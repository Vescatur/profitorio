# Development Setup

## Prerequisites

- **Factorio 2.1.14**, installed and copied into `factorio/` — see [Install Factorio](#1-install-factorio).
  Every script in `tools/` launches `factorio/bin/x64/factorio.exe` and keeps its mods and saves
  inside `factorio/`, so there is nothing else to install and no Steam involved
- **VSCode** with [Factorio Mod Debug](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug) extension (provides Lua intellisense for Factorio API)

## Initial Setup

### 1. Install Factorio

Download the installer, run it, then copy the installed game into the repo:

```powershell
# 1. Download — needs a factorio.com account that owns the game
Start-Process "https://www.factorio.com/get-download/2.1.14/expansion/win64"

# 2. Run the downloaded installer, accepting the default location

# 3. Copy the install into the repo
Copy-Item "C:\Program Files\Factorio" ".\factorio" -Recurse
```

`factorio/` is gitignored: it is a local copy of the game, not part of the mod.

The version is pinned rather than `stable` so an engine upgrade is a deliberate act. The API
reference cannot fall behind it either way: `factorio-docs/markdown/` is generated from
`factorio/doc-html`, the docs bundle shipped by this very install.

`expansion` is the build that includes Space Age. It bundles `space-age`, `elevated-rails`,
`quality` and `recycler` into `factorio/data/`, and **all four must stay disabled** — the mod is base
game only (see [Testing Changes](#testing-changes)). `tools/setup/mod-list.json`, the seed every
instance's mod list is copied from, already says so. Swap `expansion` for `alpha` to get the
base-game-only installer instead, which ships none of them.

Then put the dev save in place:

```powershell
New-Item -ItemType Directory factorio\saves -Force
Copy-Item "$env:APPDATA\Factorio\saves\dev.zip" factorio\saves\dev.zip
```

That copy is the only read of `$env:APPDATA` here, and it is you doing it. **Development never
touches the Factorio you play**: the installer build would put mods and saves in that game's own
directory, and `tools/lib/instance.ps1` is what keeps them in `factorio/`
([why](architecture.md#running-several-instances-at-once)).

### 2. Enter Dev Mode

Run `tools/setup/dev-mode.ps1` to create a junction from the Factorio mods folder to `src/`:

```powershell
.\tools\setup\dev-mode.ps1
```

This creates: `factorio\mods\profitorio_<version>` → `./src`

Changes in `src/` are immediately visible to Factorio — no copy step needed.

It also writes `factorio/config/config.ini` and seeds the mod list, so run it before any check. Nothing installs a built zip: to test one, copy it into `factorio/mods` and remove the
junction first — with both present the folder wins and the zip is silently ignored.

### 3. Launch for Development

Run `tools/run/playtest.ps1` to start the repo's own Factorio on the dev save:

```powershell
.\tools\run\playtest.ps1
```

This launches Factorio with:
- `--load-game` on `factorio\saves\dev.zip` (the dev save file)
- `--disable-audio` (faster startup)

## Project Structure

The one-clause-per-file map is in [CLAUDE.md](../CLAUDE.md#project-map); the reasoning behind the
layout is in [architecture.md](architecture.md). Two local additions this file owns:

- `factorio/` — the local 2.1.14 install copied in by [Install Factorio](#1-install-factorio), and
  its own write-data directory: mods, saves, config and script-output (gitignored)
- `.vscode/settings.json` — Lua workspace config for Factorio API intellisense

## VSCode Configuration

The `.vscode/settings.json` configures the Lua language server to:
- Include Factorio's data directory for API autocompletion
- Load the Factorio Mod Debug third-party definitions
- Ignore `factorio-data/` and `factorio-docs/` so only our code is analysed

### The Problems panel must stay empty

**VSCode's Problems panel should show zero entries.** It is a real signal — a typo'd field name or an
undefined global shows up there long before `prototypes.ps1` gets a chance to fail — but only while
it is empty. One permanently-red panel and nobody reads it again.

Keeping it empty means every entry is either fixed or deliberately silenced:

- **Fix it** — the default. Unused locals, trailing whitespace, undefined globals, genuinely wrong
  field names.
- **Silence it, narrowly** — when the warning is wrong. The Factorio type definitions ship by
  [Factorio Mod Debug](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug)
  are generated and imperfect: they mark optional fields required, so correct code gets flagged.
  Verify against `factorio-docs/markdown/types/` and the base game's own usage in `factorio-data/`
  first, then suppress at the exact line with a comment saying why:

  ```lua
  -- text_color is optional in the real API (and vanilla omits it), but the
  -- bundled type definitions mark it required.
  ---@diagnostic disable-next-line: missing-fields
  item.color_hint = { text = denomination.hint }
  ```

  Line-scoped `disable-next-line`, never a file-wide or workspace-wide disable of the rule — a rule
  that is wrong once is still worth running everywhere else.

`factorio-data/` and `factorio-docs/` are excluded wholesale via `Lua.workspace.ignoreDir`, plus
`Lua.diagnostics.ignoredFiles` and `Lua.diagnostics.libraryFiles` set to `"Disable"` (without those
two, the warnings come straight back the moment you open one of those files). Base game reference
data is not ours to fix, and it alone produced ~1900 warnings.

Settings changes need **`Lua: Restart Server`** from the command palette before the panel reflects them.

## Testing Changes

Always test with **only `base` and `profitorio` enabled**. The mod does not support other mods or the
Space Age expansion, so any issue that only reproduces with extra mods enabled is out of scope —
see [game-design.md](game-design.md#scope-and-non-goals).

1. Edit files in `src/`
2. Check the Problems panel is still empty (see [above](#the-problems-panel-must-stay-empty))
3. Run `python tools\check\docs.py` to catch documentation drift — it needs no Factorio, so it is the cheapest rung and must come back empty (see [below](#the-docs-check-must-come-back-empty))
4. Run `.\tools\check\prototypes.ps1` to validate mod loading (catches prototype errors without launching the GUI)
5. Run `python tools\check\translations.py` to catch prototypes with no translation — it must come back empty (see [below](#the-report-must-come-back-empty))
6. Run `.\tools\run\playtest.ps1` to playtest in-game
7. For runtime/control-stage behaviour, drive the real engine — see [Verifying behaviour](#verifying-behaviour)

### Verifying behaviour

Steps 3 and 4 prove the mod *loads*. They say nothing about whether it *works*, and
`src/control.lua` and the control-stage modules under `src/services/` are behaviour with no load-time signal at all.

The `verify-in-engine` skill (`.claude/skills/verify-in-engine/`) covers that, with two
harnesses behind it:

- `tools/check/probe.ps1` + `tools/check/probe_client.py` — a headless server on a **copy** of
  a save, driven with arbitrary Lua over RCON. Fastest way to probe state, run a
  simulation, count items, or inspect a save a bug was reported against.
- `tools/check/player.ps1` — the same idea in the real client, for the two things headless
  cannot do: anything needing a player (`build_from_cursor`, cursor stack, reach) and
  anything needing pixels (screenshots).

The rule the skill exists to enforce: **assert the observable effect, not the API
readback.** Loaders once shipped past a suite scoring 10/10 on `loader_type` while moving
zero items. Count what arrives.

Optional, not a gate — steps 2 to 4 are the required ones.

### Checking the docs

`tools/check/docs.py` reads CLAUDE.md, `docs/` and the skills and checks five things: every
backticked path exists, every link and `#anchor` resolves, no heading is owned by two files, no file
is past its word budget, and no source file is undocumented or doc unlinked. It launches nothing and
finishes in under a second, which is why it sits first in the ladder.

#### The docs check must come back empty

Same rule as the [Problems panel](#the-problems-panel-must-stay-empty) and the
[locale report](#the-report-must-come-back-empty).

The budget is the part that bites. CLAUDE.md is loaded into every context window, so its length is a
cost paid on every turn, and `BUDGETS` at the top of the script caps it — making the file
**append-hostile**: a new section fails the check until something is removed, moved into `docs/`, or
moved into a skill.

**Raising a budget is a decision, not a fix.** Say why in the table. The failure mode this exists to
prevent is a file growing 200 words at a time, each addition individually reasonable; a number that
quietly follows the content prevents nothing.

```powershell
python tools\check\docs.py                   # the check
python tools\check\docs.py --strict          # fail on orphans and unused suppressions too
python tools\check\docs.py --show-suppressed # list the absent paths that are filtered out
```

- **Exit 0** — no drift
- **Exit 1** — drift found
- **Exit 2** — the check could not run

Stdlib only, and it never launches Factorio.

### Checking prototypes

`tools/check/prototypes.ps1` starts Factorio as a headless server, waits for the map to load, then exits. It prints all Factorio output and returns:

- **Exit 0** — mod loaded successfully
- **Exit 1** — Factorio crashed or exited with an error (prototype/data error)
- **Exit 2** — timed out (60s) without finishing load

### Checking translations

`tools/check/translations.py` asks Factorio for both halves of the problem — `--dump-data` lists every
prototype that exists, `--dump-prototype-locale` lists every prototype whose name and description
resolve to real text. Anything in the first dump but not the second renders as `Unknown key` in game.
The customer items and delivery recipes are generated in a loop, so this is the only reliable way to
notice when a new one ships without a translation.

It also dumps a base-only baseline, so base game internals that have no locale on purpose (projectiles,
explosions, stickers) stay out of the report, and runs three static checks over `src/locale/`: stale
keys naming a prototype that no longer exists, `{"profitorio.foo"}` strings in Lua that no `.cfg` defines,
and keys the reference language has but another language is missing.

#### The report must come back empty

**A clean run prints one line and nothing else** — no `MISSING`, `STALE`, `UNTRANSLATED` or
`UNUSED SUPPRESSIONS` block above it:

```
OK: no missing translations (N description(s) intentionally left out).
```

(The count is whatever the suppression list currently covers.)

Same rule as the [Problems panel](#the-problems-panel-must-stay-empty), for the same reason: a report
that always lists something is a report nobody reads. Advisories are not "just advisories" — every
line in the output is either fixed or deliberately silenced, and there are only two ways to clear one:

- **Write the description** — the default. If a player would wonder what the thing does, it needs a
  sentence in `src/locale/en/hello-world.cfg`.
- **Suppress it, deliberately** — when the name already says everything, as with a building called
  Import. Paste the reported line into `INTENTIONALLY_UNDESCRIBED` at the top of
  `tools/check/translations.py`, under the comment group that explains why, and add a new group if
  none fits. Use `*` for prototypes generated in a loop, so future ones are covered too:
  `recipe-description.customer_*_deliver`.

Never silence a whole category, and never suppress a missing *name* — those render as
`Unknown key: ...` in game and are always a bug.

The suppression list cannot rot: an entry that stops matching anything is reported as an unused
suppression, so a rename leaves the report dirty until the entry is deleted.

```powershell
python tools\check\translations.py             # full check (runs Factorio three times, ~5s)
python tools\check\translations.py --skip-dump # reuse the cached dumps
python tools\check\translations.py --all       # include the base game's own gaps
python tools\check\translations.py --show-suppressed  # list the intentional description gaps
python tools\check\translations.py --strict    # also fail on missing descriptions, stale keys and unused suppressions
```

- **Exit 0** — every prototype and runtime key is translated
- **Exit 1** — missing translations found (listed as ready-to-paste `.cfg` lines)
- **Exit 2** — the check could not run (Factorio or the API docs not found)

Stdlib only, no `pip install` needed. Override the executable with `--factorio` or `FACTORIO_EXE`.

## Releasing

`tools/release/publish.py update` is the whole release: it bumps the version in `src/info.json`, builds
the zip through `zip.py`, and uploads it to the portal.

```powershell
python tools\release\publish.py update                 # patch bump, build, upload
python tools\release\publish.py update --bump minor     # or major, or none to re-use this version
python tools\release\publish.py update --version 2.0.0  # set the version outright
python tools\release\publish.py update --zip export\profitorio_1.4.2.zip   # upload as-is
```

`publish` creates the mod page and is run once, ever; it builds the zip too but never bumps, since
there is no earlier release to move past. Without `--yes` it prints what it would do and builds
nothing.

Two consequences worth knowing:

- **The bump is a working-tree edit.** `src/info.json` is left at the new version — commit and tag it
  yourself. A failed upload keeps the bump rather than rolling it back, because a failure after the
  portal accepted the release is indistinguishable from one before it; retry with `--bump none`.
- **The zip lands in the export folder and nowhere else.** Building installs nothing and leaves
  the dev junction alone, so there is no dev mode to get back to.
