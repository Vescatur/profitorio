---
name: add-customer-order
description: Add, remove, retune or reorder a customer order in Profitorio — the order ladder in src/services/economy/customers/orders.lua. Use when asked to add a new order or customer, change what a customer wants or how many, retune a refund, profit or spawn weight, change who walks in after a delivery, move an order up or down the ladder, or when a load fails with a verify_orders refund assertion or a spawn-row error naming a step, a sum or a band.
---

# Add or change a customer order

Orders live in the `orders` table in `services/economy/customers/orders.lua`, currently three per
band across five bands. **The table IS the ladder** — a row's position in the array is its rung —
and everything else about a customer is generated from that position.

## The six authored fields

Every entry needs all six. A missing one fails the load by name rather than taking a default.

- **`band`** — which denomination this order deals in; indexes the `bands` table (1 = penny). It
  does not place the order on the ladder, only names its currency, licence and payout icon. A band's
  rows must **sit together and climb by one**, which the load asserts.
- **`item`** — the vanilla item ordered. Finished goods only: never ore, plates, gears or circuits.
- **`amount`** — how many to deliver.
- **`refund`** — a map of denomination key to amount, e.g. `{ penny = 48, silver_coin = 2 }`. Must
  cover the **full embedded cost** of `amount × item`, tolls included.
- **`profit`** — a plain number, paid in the band's own currency. A design knob like `spawn`, not a
  consequence of the refund: nothing enforces it.
- **`spawn`** — who walks in when this order is served, as whole percent over steps **relative to
  this rung**: `same`, `up1`..`up9` and `down1`..`down9`. A missing key is 0, and the row must sum
  to `weight_total` (100). A step off either end of the ladder fails the load unless its weight is
  `0`, so a full nineteen-key template can be pasted into every row.

## What is generated — do not hand-write it

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

## Sizing a refund

Do not solve it in the code — author it, and let `verify_orders.lua` tell you if it is short. To get
the number, read the `[cost]` lines the previous load already logged and round up. Changing a shop
price or a toll invalidates every authored refund downstream; the next load names each one that no
longer covers its cost.

## Sizing a profit

The current table pays a fifth of the refund's line in the band's **own denomination**, rounded up
and floored at one coin, so a refund edit is a prompt to re-read this number — but it stays whatever
you type.

That fifth is what makes bands 4 and 5 pay a single coin: their goods embed **no coin of their own
denomination** at all — nothing on the robot path pays a Bond toll — so a fifth of nothing floors at
1. Giving those bands a real margin means either typing a bigger number here or tolling something in
their recipe tree, which is the choice that ladder is still waiting on.

## Inserting, removing or moving a row

Every row after it shifts one rung, so every step that pointed across it now points somewhere else.
Re-read the `spawn` rows on both sides of where you cut, and the neighbours within nine rungs of it.

## Names come from the module

Like `currency.lua`, this module owns its prototype names.
`require("services.economy.customers.orders")` returns
`{ bands, orders, item = { ["wooden-chest"] = "customer_wooden-chest", ... }, is_customer, entry, weight_total }`.
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
- **Finished goods only** — never ore, plates, gears or circuits.

## Validate

```powershell
python tools\check\docs.py
.\tools\check\prototypes.ps1
python tools\check\translations.py
```

`prototypes.ps1` is where a short refund or a bad spawn row surfaces. `translations.py` is where a
missing locale key does.
