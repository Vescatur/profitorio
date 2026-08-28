---
name: add-customer-order
description: Add, remove, retune or reorder a customer order in Profitorio — the order ladder in src/services/economy/customers/orders.lua. Use when asked to add a new order or customer, change what a customer wants or how many, retune a profit margin or spawn weight, change who walks in after a delivery, move an order up or down the ladder, or when a load fails with a verify_orders stale-cost error or a spawn-row error naming a step, a sum or a band.
---

# Add or change a customer order

Orders live in the `orders` table in `services/economy/customers/orders.lua`, currently three per
band across five bands. **The table IS the ladder** — a row's position in the array is its rung —
and everything else about a customer is generated from that position.

## The authored fields

`band`, `item`, `amount`, `profit` and `spawn` are yours. A missing one fails the load by name
rather than taking a default. `cost` and `refund` sit in the row too, but they are **solved** —
see below.

- **`band`** — which denomination this order deals in; indexes the `bands` table (1 = penny). It
  does not place the order on the ladder, only names its currency, licence and payout icon. A band's
  rows must **sit together and climb by one**, which the load asserts.
- **`item`** — the vanilla item ordered. Finished goods only: never ore, plates, gears or circuits.
- **`amount`** — how many to deliver.
- **`profit`** — the margin, as a **fraction**: `0.25` pays 125%. A design knob like `spawn`;
  nothing solves it. The delivery hands over `ceil(refund × (profit + 1))` coins of the band's
  currency, and that ceiling is the only rounding in the chain — on a small order it can lift the
  real margin well above what you typed, which the `[cost]` log lines show.
- **`note`** — optional prose about the row. It is a *field* rather than a comment because
  `verify_orders.lua` reprints the table, and a comment written inside the block would be pasted
  away. Band-wide comments go in `bands[n].note`.
- **`spawn`** — who walks in when this order is served, as whole percent over steps **relative to
  this rung**: `same`, `up1`..`up9` and `down1`..`down9`. A missing key is 0, and the row must sum
  to `weight_total` (100). A step off either end of the ladder fails the load unless its weight is
  `0`, so a full nineteen-key template can be pasted into every row.

## What is generated — do not hand-write it

- **`cost` and `refund`** — solved by `verify_orders.lua`. See below; never reason them out by
  hand.
- **The payout currency**, from `band`, and the coin count, from `refund` and `profit`.
- **The successor list**, by resolving each step to the order standing on that rung, and **the
  band's licence**, from `band`.
- **`is_top`** — whether this is the last row of its band. **A band's last row is its bridge
  upward** and is what pays a coin of the next denomination. Ask `order.is_top`; never work the
  position out yourself.
- **The spoil target** — every customer alike leaves a `customer_review`, because the five minutes
  are its whole life and there is no lower rung to step down into.
- **The timer** — every customer item takes `total_life_seconds`, the one clock the ladder runs on,
  because a successor inherits a *percentage* of the timer it replaces and a second timer could only
  contradict the first. Retuning the life is a one-number edit at the top of the file.

The spawn percentages are the exception: authored per order, because they are a design choice rather
than a consequence of position.

## `cost` and `refund` — paste, never calculate

Both are solved. `cost` is what `amount × item` embeds, per denomination, and exists to be read
during a balance pass; nothing computes from it. `refund` is that same bill folded up into the
band's own coin at the exchange rates, to three decimals.

You do not work either out. Run the load, and when they have drifted `verify_orders.lua` logs the
**whole corrected `orders` table** and fails — paste that block over the old one and load again.
Adding a row means authoring it with any placeholder `cost = {}` and `refund = 1`, then pasting.

The same applies after a shop price, a toll or an exchange rate moves: the next load prints the
table with every affected row already fixed.

## Sizing a profit

Nothing enforces it, so it is judgement. Two things to know:

- **The ceiling dominates a small order.** An order whose refund is under a coin or two pays a
  margin far above the fraction. The `[cost]` line prints the margin actually paid; read that, not
  the number you typed.
- **A band pays one coin, and its tree owes cheaper ones.** The player breaks it down through the
  exchange, which costs Import throughput. A thin margin high up the ladder is thinner than it
  looks.

## Inserting, removing or moving a row

Every row after it shifts one rung, so every step that pointed across it now points somewhere else.
Re-read the `spawn` rows on both sides of where you cut, and the neighbours within nine rungs of it.

## Names come from the module

Like `currency.lua`, this module owns its prototype names.
`require("services.economy.customers.orders")` returns
`{ bands, orders, item = { ["wooden-chest"] = "customer_wooden-chest", ... }, is_customer, entry, weight_total, steps }`.
Ask it for a name rather than concatenating the `customer_` prefix somewhere else.

## Locale

Nothing generates locale. Add `item-name.customer_<item>`, `item-description.customer_<item>` and
`recipe-name.customer_<item>_deliver` to `src/locale/en/hello-world.cfg`.

## The constraints that bite

These are in CLAUDE.md as hard rules, repeated here because this is where they are broken:

- **The penny band is special.** Its orders must be craftable from recipes enabled at game start and
  need no copper, because copper costs Silver and the only source of Silver is the penny band's own
  top order. Anything else deadlocks a new game.
- **The penny band's top order must keep its Silver bridge** — without it the `electronics` trigger
  can never fire and no research is ever possible.
- **Spawn weights are integers, never decimals.** `0.1 + 0.2 + 0.7` is `1.0000000000000002` in IEEE
  doubles: it fails the sum assertion, and leaves a one-ULP gap between two `shared_probability`
  bands where a delivery emits no successor and silently drains the population. A `0` is fine and
  means "never take this step".
- **An order's cost may not reach above its band's coin.** The refund is one coin of that
  denomination and exchange runs downward only, so a dearer rung in the tree could never be earned
  back. The load refuses it by name.
- **Finished goods only** — never ore, plates, gears or circuits.

## Validate

```powershell
python tools\check\docs.py
.\tools\check\prototypes.ps1
python tools\check\translations.py
```

`prototypes.ps1` is where a stale `cost`/`refund` or a bad spawn row surfaces — and where the
corrected table to paste is printed. `translations.py` is where a
missing locale key does.
