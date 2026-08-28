---
name: tune-economy
description: Change what something costs in Profitorio — a shop price in src/services/economy/shop/prices.lua, a crafting toll in src/services/economy/money/tolls.lua, or an exchange rate in src/services/economy/money/exchange.lua. Use when asked to add or reprice a purchasable resource, change what a recipe costs to craft, make something free or more expensive, add a toll row for a new vanilla recipe, retune what breaking a coin pays out or add a conversion between two denominations, or when a load fails naming an untolled recipe or fails a verify_orders stale-cost check.
---

# Tune a price or a toll

Three tables, one verification loop. Both change what a good embeds, so both invalidate the authored
refunds in `orders.lua` — and `verify_orders.lua` re-solves the whole recipe graph at the next load
and names every order that no longer covers its cost. That shared failure is why these live
together.

## Shop prices — `services/economy/shop/prices.lua`

Add an entry to the `resources` table with `item`, `amount`, `price`, and `currency` (a field from
the `currency` module, e.g. `currency.penny`).

Price it in the denomination of the era that needs it, and grow the lot size with the denomination
so unit prices stay in the same range across the ladder. A resource is not merely expensive before
its era — it is unbuyable.

## Crafting tolls — `services/economy/money/tolls.lua`

Every vanilla recipe has a row, and each row states:

- **`recipe`** — the vanilla recipe name.
- **`toll`** — the denomination a craft costs (a field from the `currency` module), or `false` for
  free. Omitting it fails the load; there is no default.
- **`amount`** — how many of that coin one craft costs, a whole number of at least one. Written out
  on every tolled row even though every one of them is currently `1`, because it is the knob that
  makes a recipe expensive without moving it up the ladder. A free row carries no `amount`, and one
  that does fails the load — that is what a half-finished edit looks like.

Rows are grouped by the technology that unlocks the recipe and ordered by the licence that
technology invoices, so the toll column reads down the file in ladder order. Put a new row in its
technology's group. A recipe unlocked by several technologies is charged the **cheapest** of them,
because that is the one the player actually paid for.

### The two load-time checks

Any vanilla recipe with no row **fails the load naming it**, so no Factorio update can slip one
past the toll booth. Which coin a row asks for is not checked against the licence it sits behind —
that is your judgement.

Nothing solves the `amount`. It is a design knob like `profit` in `orders.lua`.

### Free is a real answer

Say why beside the row. The six groups already in the table:

- **no unlocking technology** — the player bought no licence, which is what keeps a new game
  craftable with no money
- **trigger technologies** — a trigger has no invoice, so it sells no licence (`electronics`,
  `steam-power`)
- **smelting** — see below
- **engine placeholders** — `parameter-0` .. `parameter-9`, `recipe-unknown`
- **fluid-in/fluid-out recipes** — nowhere to hand a coin to
- **barrel fill and empty** — that taxes logistics, not production

## Exchange rates — `services/economy/money/exchange.lua`

One row per conversion: `from` and `to` (denomination keys, not pack names), plus `spend`, `receive`
and `seconds`. All five are written out on every row even though the rate is 1:5 on all of them.

- **Direction is asserted, not tuned.** `to` has to sit below `from` on the ladder, and an upward or
  sideways row fails the load naming the pair — it would let the factory mint the coin that gates
  the next tier of research.
- **The rate should stay a loss.** The refund table pays around 8 Pennies for the work that earns
  one Silver Coin, so 5 keeps change-making a convenience rather than an income. Nothing enforces
  that: there is no reference rate to solve against, so it is judgement, not a check.
- **A rate change re-denominates every refund.** `verify_orders.lua` still leaves these recipes out
  of the cost graph, by category — but the rates themselves are the ruler it folds a
  multi-denomination bill up with, so the next load prints a corrected `orders` table. Paste it.
- **`seconds` is the throughput knob that matters now.** An order pays one coin of its band, and the
  cheaper coins its tree owes are got by breaking that down, so exchange time is on the critical
  path of the whole economy.
- **Raising `spend` above 1 is a trap.** It strands a player holding fewer coins than a row spends,
  and a pair may only have one row, so there is no small-change fallback to offer alongside it.

A non-adjacent pair — Diamond straight to Penny — is a new row and nothing else. The schema already
takes any pair that goes down.

## The constraint that bites

**Never toll a smelting recipe.** Every furnace has `source_inventory_size = 1`, so a smelting
recipe cannot take a second ingredient. Adding one raises no error; it just makes the item
uncraftable in every furnace in the game. `tolls.lua` guards this with an assertion, and the guard
must stay.

## Validate

```powershell
python tools\check\docs.py
.\tools\check\prototypes.ps1
```

`prototypes.ps1` is where a short refund surfaces — `verify_orders.lua` names the order, what it
computed, and what was authored, so the fix reads straight off the load. Round up and write it into
`orders.lua`.
