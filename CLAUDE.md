# Profitorio — Factorio 2.1 Total Overhaul Mod

Instead of mining and expanding, players serve customers to earn money — the only way to acquire
resources. No ores, no electricity, no enemies. Six science packs are re-skinned into currency, so
research is what you spend profit on.

Vision and design principles: [game-design](docs/game-design.md). Why each file is shaped the way
it is: [architecture](docs/architecture.md).

## Rules

### These break the mod

- **Never modify `factorio-data/`** — it's base game reference data
- **Never re-add ore *patches* or electricity** — the entire mod design depends on their absence.
  Ore *items* are a different thing: they are shop goods, and smelting them is how plates are made.
  What stays banned is anything on the map to mine and anything that generates or distributes power.
  The mining drills and the pumpjack are deleted for the same reason — there is nothing to point
  them at
- **Never re-add enemies or combat content** — there is nothing to defend, so weapons, ammo,
  turrets, walls and combat vehicles have no function. Most of the tree was already unreachable
  anyway: `explosives` needs coal and sulfur needs crude oil, and `removals/ore.lua` deletes both.
  Radar, `modular-armor`/`power-armor` (equipment-grid carriers) and the car are kept on purpose and
  are not combat content. Enemies are **hidden and stripped of autoplace, not deleted** — the engine
  refuses to load a `unit`, `unit-spawner` or `turret` type with no members
- **Never delete `loader-1x2-stub`** — Profitorio's loaders are all `loader-1x1`, which leaves the
  `loader` type with nothing in it, and the engine refuses to load: `'entity' prototype type
  'loader' requires at least 1 prototype be defined so save files can be loaded`. The same rule that
  keeps the enemies hidden rather than deleted. The stub in `services/logistics/loaders.lua` is that
  one prototype: hidden in both senses, with its minable result, upgrade target and fast-replace
  group stripped so nothing can reach it. It looks like dead code and is not
- **Never toll a smelting recipe** — every furnace has `source_inventory_size = 1`, so a smelting
  recipe cannot take a second ingredient. Adding one raises no error; it just makes the item
  uncraftable in every furnace in the game. `services/economy/money/tolls.lua` guards this, and the
  guard must stay
- **Customer orders are finished goods only** — never ore, plates, gears or circuits; a customer
  wants something you would build anyway
- **Never gate the penny band behind a technology** — its delivery recipes ship `enabled = true`
  because every technology in the game is downstream of a lab, a lab needs copper, and copper costs
  Silver that only the penny band can pay. Gating it deadlocks a new game in the first minute
- **The penny band's top order must keep its Silver bridge** — it is the only source of the first
  Silver Coin, and without it the `electronics` trigger can never fire and no research is ever
  possible
- **Money is earned, never printed** — the science pack recipes are deleted, not hidden: red and
  green are craftable from purchased plates and would print money. Never restore a recipe producing a
  currency item. The one exception is exchange, **down the ladder only**: a coin breaks into smaller
  ones, never the reverse, or the factory mints the coin gating the next research tier
- **A customer's five minutes never reset** — `orders.lua` gives every customer item one
  `total_life_seconds` timer, and a delivery's successor carries **no `always_fresh`** so it inherits
  the spoil percentage of the customer it replaced. That absence is the whole rule: re-adding the
  flag in `services/economy/customers/export.lua` raises no error and quietly makes customers
  immortal. Crafting time is inside the five minutes for free — `spoil_tick` is an absolute tick, so
  the clock runs in an ingredient slot and during a craft. Nothing may hand a customer more time
- **Reviews are a permanent dead end** — `customer_review` has no spoil timer and no recipe, on
  purpose. Every customer leaves one when its five minutes are up, so the pile grows at the
  Entrance's rate for the whole save, and one spoiling inside a machine's ingredient slot jams that
  machine for good. That hazard is the challenge; never add a spoil timer, disposal recipe, or any
  other way to get rid of reviews
- **Only one Entrance may exist** — it's the sole source of customers, so its count is what bounds
  the whole economy. `services/logistics/entrance_limit.lua` refuses extra placements, registered
  from `src/control.lua`. Retune throughput via `energy_required` on `customer-new` or the
  Entrance's `crafting_speed` — both in `services/economy/customers/entrance.lua` — never by
  allowing more buildings. Those two knobs also set how many customers are alive at once: nothing
  refreshes a customer's five minutes, so the population settles at the arrival rate times that
  life, and the review pile grows at the arrival rate too. A satellite launch is the one other place
  a customer leaves the population: it consumes its Diamond client and emits no successor
- **Customer spawn weights are integers, never decimals** — an order's `spawn` row is whole percent
  over relative ladder steps summing to `weight_total`; there's a load assertion. Decimals
  are the trap: `0.1 + 0.2 + 0.7` is `1.0000000000000002` in IEEE doubles, which fails the assertion
  outright and, worse, leaves a one-ULP gap between two `shared_probability` bands where a delivery
  emits no successor and silently drains the population. A `0` means "never take this step" and is
  dropped rather than emitted as a zero-width slice
- **One `script.on_event` call per event, ever** — a second registration for the same event
  *replaces* the first and raises no error, so the concern registered earlier just stops working.
  `src/control.lua` is the only place that calls `script.on_event`: runtime modules export a handler
  and it composes them, which is why `logistics/entrance_limit.lua` and
  `logistics/loader_binding.lua` share one registration per build event with the union of their
  filters. Filter entries are OR-ed. Add a runtime module the same way — never call
  `script.on_event` from inside one
- **A loader's bound side is intrinsic — `loader_type` does not move it** — the side a loader
  loads/unloads is the tile it faces in `input` mode and the tile behind it in `output`, and both
  `rotate()` and assigning `loader_type` *preserve* that side by flipping the direction to
  compensate. So `loader.loader_type = "input"` is not a mode switch: the arrow swings 180° and the
  loader stays bound to the same neighbour. Writing `direction` is the only lever that moves the
  binding. Any code changing a loader's mode must set the mode and then write the intended direction
  back — `services/logistics/loader_binding.lua` documents the measured truth table. Verify such a
  change by asserting **items actually moved**, never by reading `loader_type` back
- **A loader may only ever be bound to an Import or an Export** — those are the item-heavy machines:
  a shop lot and a customer order are both bulk deliveries. The Entrance is excluded on purpose,
  because it crafts one customer at a time and an inserter handles that. Anything else — a chest, a
  furnace, an assembler — is refused and the item handed back. Do not re-add container support to be
  helpful: the whitelist is `binding.machines` in `services/logistics/loader_binding.lua`. `import`
  and `export` carry no `fast_replaceable_group` and no `next_upgrade`, so a bound machine cannot be
  swapped out without a mining event — that absence is load-bearing, not an oversight
- **R on a loader is not a 90° rotation, and needs no handler** — measured: it swings `direction`
  180° and flips `loader_type` together, so the bound side never moves and there is no way for a
  player to rotate a loader sideways. Every state R can produce is one `bind` already accepts, which
  is why `src/control.lua` deliberately does not register `on_player_rotated_entity`. What R does
  change is the *function* — a loader becomes an unloader — and that is legitimate

### Scope

- **Target Factorio version: 2.1** — uses features not available in earlier versions
- **Never depend on Space Age** — base game only; don't reference Space Age prototypes or add it to
  `dependencies`. `src/info.json` depends on `base` only
- **Never add mod-compatibility code** — no soft dependencies, no `if mods["..."]` branches, no shims
  for other mods. The mod removes ores and electricity wholesale, so most other mods will break;
  that is expected and acceptable
- **Mod internal name is `profitorio`** — referenced in paths, icon prefixes (`__profitorio__`), the
  symlink, and the `[profitorio]` locale namespace. `dev-mode.ps1` and `zip.py` read it from
  `src/info.json` rather than hardcoding it, so a rename follows that file

### Working agreements

- **Development never touches the Factorio you play** — `%APPDATA%\Factorio` is the human's Steam
  install. Everything mutable lives in `factorio/` or `.factorio/<name>/`, seeds included. Junction
  a mod, install a build or dump prototypes into the system directory and nothing errors; you have
  silently edited a game somebody plays
- **Tuning happens in config, not code** — see [below](#tuning-happens-in-config-not-code)
- **Comments say what the code cannot** — see [below](#comments)
- **Always validate after changes** — `python tools\check\docs.py` first (no Factorio needed),
  then `.\tools\check\prototypes.ps1` after any mod file change, then
  `python tools\check\translations.py` after adding or renaming a prototype
- **Keep the docs check empty** — `tools/check/docs.py` enforces a **word budget** on this file and
  every doc, and fails on a backticked path that does not exist, a broken link, or one heading owned
  by two files. Adding a section means removing one, or moving it to `docs/` or a skill. **Raising a
  budget is a decision, not a fix** — if you raise one, say why in the table
- **Leave the locale report empty** — `translations.py` must print only its `OK:` line, advisories
  included. Clear an entry by writing the description in `src/locale/en/hello-world.cfg`, or, when
  the name already says everything, pasting the reported line into `INTENTIONALLY_UNDESCRIBED` in
  `tools/check/translations.py` under the comment group that explains why (`*` globs, for prototypes
  generated in a loop). Never suppress a missing *name* — those render as `Unknown key` in game.
  [More](docs/dev-setup.md#the-report-must-come-back-empty)
- **Leave the VSCode Problems panel empty** — zero entries, so the next one that appears is worth
  reading. Fix the code, or, when the bundled Factorio type definitions are wrong (they mark
  optional fields required — check `factorio-docs/markdown/types/` and vanilla's own usage first),
  suppress that one line with `---@diagnostic disable-next-line: <code>` and a comment saying why.
  Never disable a rule file-wide or workspace-wide.
  [More](docs/dev-setup.md#the-problems-panel-must-stay-empty)

## Working in parallel

Several Claude sessions work this repo at once. Each is a peer that merges its own work; there is
no coordinator, so the rules below are the only thing keeping them from colliding.

**Never work in the primary worktree** — it holds `main`, and the human plays there.
`tools/agent/start.ps1 -Task <name>` gives you a worktree beside the repo, a branch `agent/<name>`
and a Factorio instance. Every `tools/` call you make from then on carries `-Instance <name>`
(`--instance` for the Python ones), or you collide with another agent on Factorio's lock file.

1. Do the work. **Leave it uncommitted**, run the three checks, and ask for review.
2. Rework until approved. Then `tools/agent/integrate.ps1 -Message "<terse one-liner>"` — it
   commits, pulls `main` in and re-runs the checks.
3. If the merge brought anything in, ask for review again: the integrated tree, still uncommitted,
   where a change that was fine alone but breaks in combination shows up. When `main` had not moved
   the script says so -- nothing was merged, nothing new to read, land it.
4. `tools/agent/land.ps1`, then `cd` to the primary and `tools/agent/finish.ps1 -Task <name>`.

- **Both review gates are on uncommitted code.** Nothing reaches `main` unread. Never commit past
  a gate to make progress.
- **Resolve your own conflicts, in your own worktree.** Never in the primary one.
- **If the primary worktree is dirty, stop and say so.** Never stash, commit or revert work that
  is not yours. Both scripts refuse on their own; do not work around them.
- **On failure, leave everything in place.** The worktree is the evidence. Cleanup is for success.
- **Never hold the merge lock across a review** — it stalls every other agent. The scripts release
  it for you.
- **Do not push.** `main` stays local; the human publishes.

Mechanics, exit codes and the junction hazard: `tools/agent/README.md`.

## Project map

One clause per file. The reasoning is in [docs/architecture.md](docs/architecture.md).

- `src/data.lua` — every data-stage service
- `src/data-updates.lua` — `prices` → `tolls` → `verify_orders`; the order is correctness
- `src/control.lua` — composition only; owns every `script.on_event`
- `src/lib/prototypes.lua` — delete/hide/re-link helpers, plus `find_item`/`icons_of`
- `services/economy/customers/orders.lua` — the band and order tables, the shared five-minute life
- `services/economy/customers/entrance.lua` — the machine that mints customers, and `customer-new`
- `services/economy/customers/export.lua` — the delivery payouts, and each band's licence
- `services/economy/customers/verify_orders.lua` — emits nothing; prints the solved costs
- `services/economy/money/currency.lua` — the denomination ladder, and the names it owns
- `services/economy/money/exchange.lua` — breaks a coin downward; folds bills up
- `services/economy/money/tolls.lua` — one row per vanilla recipe: what a craft costs
- `services/economy/shop/prices.lua` — the `buy_*` price list
- `services/economy/shop/import.lua` — the machine that crafts them
- `services/economy/shop/recipes.lua` — re-costs penny-band goods onto one bought material each
- `services/economy/shop/starter_inventory.lua` — control stage; the six-item starting kit
- `services/logistics/loaders.lua` — un-hides the vanilla loaders and retypes them to `loader-1x1`
- `services/logistics/loader_binding.lua` — control stage; binds a loader to an Import or Export
- `services/logistics/entrance_limit.lua` — control stage; refuses a second Entrance
- `services/logistics/refuse.lua` — the refund ladder both rules share
- `services/removals/` — `ore`, `electricity`, `enemies`, `military`, `uranium`
- `services/interface/item_groups.lua` — the Profitorio tab and its subgroup ordering
- `art/icons/` — SVG sources. **Edit these, not the generated `src/graphics/icons/` PNGs**
- `factorio/` — the 2.1.14 install every script launches, and its write-data (gitignored)
- `tools/` — dev scripts by purpose; every folder carries a README

## Money

`services/economy/money/currency.lua` **re-skins six of the vanilla science packs in place** into a
denomination ladder, so every technology's existing `unit.ingredients` becomes its price and the lab
is where profit is spent.

| Prototype | Denomination |
| --- | --- |
| `automation-science-pack` | Penny |
| `logistic-science-pack` | Silver Coin |
| `chemical-science-pack` | Banknote |
| `production-science-pack` | Bond |
| `utility-science-pack` | Gold Bar |
| `space-science-pack` | Diamond |

Never spell those prototype names out elsewhere: `require("services.economy.money.currency")`
returns a map by denomination, plus `technology` (each band's licence) and `ladder`/`rank` (the
order).

`military-science-pack` is **not** money and must not be re-added to the ladder
([why](docs/customer-system.md#the-seventh-pack-why-there-is-no-war-chest)).

## Common tasks

- **Add or change a customer order** → the `add-customer-order` skill
- **Change a shop price or a crafting toll** → the `tune-economy` skill
- **Verify behaviour in-engine** → the `verify-in-engine` skill
- **Add or edit an icon** — edit the SVG in `art/icons/`, then `python tools/generate/icons.py
  --all` (needs `pip install -r tools/setup/requirements.txt` once). Never hand-edit the PNGs

## Conventions

### Comments

**A comment earns its place by saying something the code cannot.** Everything else buries the
comments that matter, and a file annotated evenly throughout stops being skimmable.

Write one for:

- **An engine constraint that fails silently or reports something misleading.** These are the reason
  the convention exists. Tolling a smelting recipe raises no error, it just makes the item
  uncraftable in every furnace; a second `script.on_event` silently replaces the first. Say what
  breaks and how it presents. If a plausible "fix" is what causes the failure, say that too.
- **A deliberate absence.** A missing field, a guard that looks removable, a prototype that looks
  like dead code (`loader-1x2-stub`). Without a note these read as oversights and get "tidied".
- **A non-obvious "why" next to the code it explains**, in one to three lines.
- **A short header** — one line, three at the outside — saying what the file does.

Never for design rationale (that belongs in `docs/`), history (git knows), anything already in
`CLAUDE.md` or `docs/`, a restatement of the next line, or a `====` banner used as decoration.

Two habits that keep it honest:

- **Put the note next to the code it guards, not in the file header.** The smelting warning belongs
  on the `if category == "smelting"` line in `services/economy/money/tolls.lua`, where someone
  editing the exemption list will actually meet it.
- **Prefer a good assertion message to a comment.** An `assert` naming the offending prototype and
  saying what was expected documents the constraint *and* enforces it.

`services/logistics/loader_binding.lua` is the reference style. Treat a file past ~20% comment
lines, or any block over ~20 lines, as a prompt to re-read this section.

### Tuning happens in config, not code

**Default to an explicit table: one row per subject, every field written out, even when every row
currently holds the same value.** These are balance knobs and they change often. A row that states
its amount is retuned in a diff of digits; a value the code computes can only be retuned by editing
the computation, and the person retuning it is mid-balance-pass, not mid-refactor.

So a rule must never *be* the config. Deriving which price, timer or amount applies from position in
a list, from a name pattern, from a category, or from what a neighbouring prototype happens to
contain reads as clever and is a ceiling: the first subject needing a different number has nowhere
to say so. Same for exemptions — a predicate excludes only what its author anticipated, where a list
of names can be appended to by anyone. A one-off belongs in the table as a row, not as a special
case bolted on after the loop.

A computed value is welcome as the **default a row overrides**, never as the decision itself.

Better still, compute it as a **check**. Where a number genuinely can be solved, solve it at load and
`assert` the authored number still holds. That catches the failure mode authored numbers actually
have: a price moves three files away and the old number is quietly wrong rather than loudly broken.
Such a check should name the offending entry, log what it computed alongside what was authored, and
may overestimate in the safe direction.

Generate a field outright only where an authored value could **contradict** another — a link that
must agree with a position on a ladder. Everything else is authored, and a required field is
`assert`ed present rather than defaulted, so a missing one fails the load by name.

The litmus test: could the next balance change be a diff of numbers only? If it needs new Lua, the
config is too thin.

## API reference

`factorio-docs/markdown/` holds the full Factorio 2.1.14 API, generated by
`tools/generate/api_docs.py`. **Far too large to read in full — navigate it, never load it.** Open
the file directly if you know the name; otherwise grep the relevant `index.md` first.

| Looking for | Go to |
| --- | --- |
| A prototype definition (data stage) | `prototypes/index.md` |
| A property type (`Sound`, `IconData`, ...) | `types/index.md` |
| A runtime `Lua*` class (control stage) | `classes/index.md` |
| Runtime concepts / events | `concepts/index.md`, `events/index.md` |
| `defines.*` enums | `defines/defines.md` |
| Prose guides (data lifecycle, mod structure, migrations) | `auxiliary/` |

Regenerate after a Factorio update with `python tools/generate/api_docs.py --clean`. The source is
`factorio/doc-html`, which ships inside the install, so the reference cannot drift from the engine.

## Dev setup

Full steps in [docs/dev-setup.md](docs/dev-setup.md). Quick start:

1. Install Factorio 2.1.14 into `factorio/` — see [Install Factorio](docs/dev-setup.md#1-install-factorio)
2. `.\tools\setup\dev-mode.ps1` — symlink `src/` into `factorio/mods`, and write the config
3. `.\tools\run\playtest.ps1` — launch with the dev save

## Further reading

- [game-design](docs/game-design.md) — vision, Ultracube inspiration, design principles
- [architecture](docs/architecture.md) — why each file is shaped the way it is
- [customer-system](docs/customer-system.md) — the customer/currency economy spec
- [dev-setup](docs/dev-setup.md) — environment, testing workflow, releasing
