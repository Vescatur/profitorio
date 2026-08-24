# Architecture

Why each part of the mod is shaped the way it is. The one-clause-per-file map lives in
[CLAUDE.md](../CLAUDE.md); this is the reasoning behind it.

`src/services/` is grouped **by domain, not by stage**: one folder per part of the mod, holding
everything about it — data stage and control stage side by side. `control.lua` is composition only.

## Entry points

- **`data.lua`** — requires every data-stage service. Order is for reading, not correctness: a
  module that needs another requires it itself and Lua caches the result. The list is complete so
  the pure side-effect modules run even though nothing requires them.
- **`data-updates.lua`** — requires `prices.lua`, then `tolls.lua`, then `verify_orders.lua`, **in
  that order**. The order is correctness, not readability, and the file says why. This stage exists
  at all because base generates the fluid barrel items in *its* data-updates, so neither the shop
  nor the toll injector can see a complete recipe list any earlier.
- **`control.lua`** — runtime entry point, and **composition only**: it requires the runtime
  modules, dispatches `on_built_entity` between them by entity name, and owns every
  `script.on_event` call. It holds no domain logic of its own — the concerns live in
  `logistics/entrance_limit.lua`, `logistics/loader_binding.lua` and
  `economy/shop/starter_inventory.lua`.

## `lib/prototypes.lua`

The four moves every removal service makes: delete recipes (and strip the unlock effects naming
them), hide items, delete technologies, re-link the prerequisites and dependents left dangling.
Also `add_unlock`, `hide_item` and `unhide_item`, and `find_item`/`icons_of` — the type-agnostic
item lookup. Reach for those instead of `data.raw.item[name]`, which is nil for armor, modules,
rail planners and item-with-entity-data.

Two helpers here are not removal-related at all: `tinted_machine_graphics` and
`machine_circuit_connection`, used by the Entrance, Export and Import machines.

Not a service; required by the ones below.

## `services/economy/customers/`

Who walks in, what they order, and the machines that make and pay them.

- **`orders.lua`** — the band table and the order ladder, the customer items, the one five-minute
  life they all share, and the successor each authored step resolves to. Returns the bands, the
  orders and each order's item name; the recipes that consume them live with the machine that
  crafts them.
- **`entrance.lua`, `export.lua`** — two of the three machines the whole loop runs through (the
  third is `economy/shop/import.lua`), plus the recipes they craft: `customer-new` and the
  `customer_*_deliver` payouts. `export.lua` also wires each band's licence onto its technology.
- **`verify_orders.lua`** — emits no prototypes. Re-solves the recipe graph and asserts the authored
  refunds still cover what each order costs, so the numbers in `orders.lua` cannot rot silently.
  Runs in `data-updates.lua`, after `prices.lua` and `tolls.lua`.

## `services/economy/money/`

The denomination ladder, and what everything costs.

- **`currency.lua`** — re-skins six science packs into currency denominations, and is the module the
  rest of the mod asks for currency item names. Its return table also carries a `technology` key: a
  nested map from denomination to pack name, which `orders.lua` reads to find each band's licence.
- **`tolls.lua`** — charges a coin to craft. One row per **vanilla recipe** — every one of them —
  naming the denomination and how many coins it costs, or `toll = false` for free, grouped by the
  technology that unlocks it and ordered by the licence that technology invoices. The list must stay
  complete: a vanilla recipe with no row fails the load by name, so no Factorio update can slip one
  past the toll booth. It also re-solves the cheapest licence per recipe and logs any row that has
  drifted off it. Also puts the Diamond client into the `satellite` recipe.

## `services/economy/shop/`

Buying goods, and what a new game opens with.

- **`prices.lua`** — the `buy_*` price list the Import machine crafts, each good priced in the
  denomination of the era that needs it. Separate from `import.lua` because it runs a stage later.
  Returns its `resources` table, which `verify_orders.lua` uses as the solver's seeds.
- **`import.lua`** — the machine that crafts those `buy_*` recipes, turning currency into goods.
- **`recipes.lua`** — re-costs the penny band's goods onto one bought raw material each:
  `burner-inserter` onto 10 wood, `assembling-machine-1` onto 5 stone. Both ship `enabled = true`,
  because a penny order cannot wait on research — every technology sits behind a lab, a lab behind
  copper, and copper behind the Silver Coin only the penny band mints. `automation` keeps its unlock
  effect for `assembling-machine-1`: that is where `tolls.lua` reads its Penny toll from.
- **`starter_inventory.lua`** — control stage. The six-item kit a new game opens with. Replaces
  freeplay's list through its remote interface rather than extending it, because the vanilla kit's
  burner mining drill has nothing to work with.

## `services/logistics/`

What may be placed where: the loaders in both stages, and the two rules that police a placement and
hand the item back when it is refused.

- **`loaders.lua`** — the one service that adds rather than removes. Un-hides the three vanilla
  loaders — entity, item and recipe are all `hidden` in base and no technology names them —
  **retypes them from `loader` to `loader-1x1`** so they take one tile, and hangs each off the
  logistics technology that unlocks its belt tier. Attaching them to a technology rather than
  setting `enabled = true` is what prices them: `tolls.lua` reads the denomination off the unlocking
  technology, so they cost a Penny, a Silver and a Bond without a line of pricing code. The retype
  is why the three tiers need no new prototypes — `place_result` and `minable.result` name a
  prototype, not a type, so the items, recipes and icons carry over untouched. The one prototype
  this file does add is `loader-1x2-stub`, which exists solely to keep the `loader` type non-empty.
- **`loader_binding.lua`** — control stage. Enforces that a loader is bound to an Import or an
  Export and nothing else, on every path that can create or move one: hand and robot builds, script
  revives, blueprint paste, the machine being mined, the machine going away, and a load-time sweep.
  `bind` is **preserve-first** — an already-valid binding returns before anything is written — which
  is what makes it safe to run on paths no hand triggers. Setting a mode takes **two writes**:
  assigning `loader_type` preserves the bound side by swinging the arrow 180°, so the aimed
  direction has to be written back afterwards. Owns `storage.loader_watch`, and exports `machines` —
  the `{ "import", "export" }` table `control.lua` generates its machine filter from. The build and
  entrance filters are hand-written alongside it.
- **`entrance_limit.lua`** — control stage. Refuses a second Entrance and hands the item back, and
  reconciles a save that already holds several. Owns `storage.entrance`; exports `name`, `on_built`
  and `adopt` for `control.lua` to register — it never registers an event itself.
- **`refuse.lua`** — the refund ladder both rules share: flying text and `cannot_build` into the
  player's hands, else the robot's cargo, else the ground, plus the shapes for a mined-entity buffer
  and a bare spill. Names the item off the entity, and `assert`s that item exists — a refusal that
  refunds nothing reads in game as the building vanishing.

The measured engine behaviour behind all of this is recorded as a truth table in
`logistics/loader_binding.lua` itself.

## `services/removals/`

The content the design takes away.

- **`ore.lua`** — strips ore/resource generation, deletes the mining drills and pumpjack, stops
  rocks dropping coal, and prices `oil-processing` in money since its "mine crude oil" trigger can
  never fire.
- **`electricity.lua`** — removes electric infrastructure, converts every electric *and burner*
  energy source to void.
- **`enemies.lua`** — stops enemies generating and hides them.
- **`military.lua`** — deletes the combat recipes and technologies.
- **`uranium.lua`** — deletes the uranium chain and re-costs `fission-reactor-equipment` off uranium
  fuel.

These run from `data.lua` like every other service — there is no `data-final-fixes.lua`. They touch
prototypes base declares in its own `data.lua` (`main_menu_simulations` is filled in there), and
base's `data-updates.lua` only generates fluid barrels, so nothing they remove gets added back
afterwards.

Enemies are **hidden and stripped of autoplace, not deleted**. That is an engine limit, not a
preference: `'entity' prototype type 'unit' requires at least 1 prototype be defined so save files
can be loaded`, and the same holds for `unit-spawner` and `turret` (whose only vanilla members are
the four worms — the player-built turrets are all subtypes). Nothing spawns and nothing is listed,
so the result is the same in play. Don't attempt the deletion again; it fails at load.

Military items follow the `electricity.lua` trade-off — **recipe deleted, item hidden, item and
entity prototypes kept** — so `car.guns`, `lab.inputs` and the spidertron tips-and-tricks entries
still resolve. Radar is deliberately kept craftable: `satellite` needs five of them.

## `services/interface/item_groups.lua`

The Profitorio tab and its subgroup ordering. Deliberately not distributed into the domains: the
`order` letters only make sense read side by side.

## Running several instances at once

Factorio admits one process per write-data directory. That one `.lock` file is why the checks were
serial: a running `probe.ps1` made `prototypes.ps1` fail with `Couldn't create lock file`, which
reads exactly like a mod error.

`tools/lib/instance.ps1` breaks the tie. Given `-Instance <name>` it writes a `config.ini` whose
`[path] write-data` is `.factorio/<name>/data`, and hands the launcher a `--config` argument.
Everything mutable follows the write-data directory — the lock, the mods folder, saves, scenarios,
`script-output`, the log — so instances neither see nor block each other. The 4.3 GB `read-data`
stays shared, which is why an instance costs about 3.5 MB rather than a copy of the install.

Three shapes here are deliberate.

**The default is an instance too, not a passthrough.** It resolves to `factorio/` — write-data at
the install root beside `factorio/data`, which is Factorio's own portable layout — and it
carries a `--config` like any other. The installer build this repo copies in ships
`use-system-read-write-data-directories=true`, which sends mods, saves and `script-output` to
`%APPDATA%\Factorio` however far from Program Files the copy sits. That is the directory the
Factorio you *play* uses, so the old default junctioned the mod under development into a live game
and dumped prototype JSON beside real saves. Development stays inside the repo instead, reads
included: an instance seeds from `factorio/` and from a committed `tools/setup/mod-list.json`, never
from the system directory. `Set-PortableInstall` pins `config-path.cfg` for the one launch a
`--config` cannot reach — double-clicking `factorio.exe`.

**Playing still means no `-Instance`.** Agents move off the dev save; the player never does.

**The instance name is authored, not derived** — a name maps to a directory, so a stray one is
visible on disk and removable, where an index derived from a worktree or a PID would be neither.

Ports are the part write-data does not cover: `--start-server` binds UDP 34197 unless told
otherwise, so both launchers ask the OS for a free port instead of defaulting to a fixed one.

## Outside `src/`

- **`art/icons/`** — editable SVG sources for the custom sprites, kept out of `src/` so only shipped
  assets are symlinked into the mods folder. `src/graphics/icons/` is generated from them.
- **`tools/`** — dev scripts, grouped by what you are trying to do rather than by what they use.
  Every folder carries a README. See [dev-setup.md](dev-setup.md) for how to run them.
- **`.factorio/<name>/`** — per-instance Factorio state, one per `-Instance` name. Gitignored,
  disposable: delete a directory and the next run seeds it again.
- **`factorio-data/`** — base game prototype data. Read-only reference.
- **`factorio-docs/markdown/`** — the Factorio API reference. Generated; do not edit by hand.
