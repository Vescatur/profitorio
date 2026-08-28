-- exchange.lua -- change-making: one recipe per conversion, always down the ladder.
-- A high denomination breaks into a lower one at an authored rate, minus the cut the
-- shop keeps. Crafted by the Import machine and nothing else.
local prototypes = require("lib.prototypes")
local currency = require("services.economy.money.currency")

-- Required for the side effect, not for a value: the Import machine has to exist
-- before the loop below can hand it the `exchange` category. data.lua's own ordering
-- is for reading, so a module needing another one requires it itself.
require("services.economy.shop.import")

-- One row per conversion, keyed by denomination rather than by pack name, so the
-- recipe names and the locale keys read as money. `spend`, `receive` and `seconds`
-- are balance knobs, so all three are written out on every row even while the rate
-- is the same on all five.
--
-- Any pair is legal as long as `to` sits below `from`; only the adjacent rungs are
-- authored, so breaking a Diamond down into Pennies is four crafts.
--
-- These rates are also the ruler `value_at` below folds a bill up with, and a customer
-- order is refunded in its band's coin alone -- so a rate change re-denominates every
-- refund in the game, and the next load prints a corrected `orders` table.
--
-- That makes change-making mandatory rather than a convenience: a band pays one coin
-- and the tolls underneath it are owed in cheaper ones. `seconds` is the throughput
-- knob for that, and raising `spend` above 1 is the trap -- it strands a player holding
-- fewer coins than a row spends, and a pair may only have one row.
local exchanges = {
    { from = "silver_coin", to = "penny",       spend = 1, receive = 5, seconds = 0.5 },
    { from = "banknote",    to = "silver_coin", spend = 1, receive = 5, seconds = 0.5 },
    { from = "bond",        to = "banknote",    spend = 1, receive = 5, seconds = 0.5 },
    { from = "gold_bar",    to = "bond",        spend = 1, receive = 5, seconds = 0.5 },
    { from = "diamond",     to = "gold_bar",    spend = 1, receive = 5, seconds = 0.5 },
}

-- Its own category rather than `import`: import.lua hands the character the `import`
-- category, and a coin broken in the player's pocket needs no factory at all. This
-- one goes to the Import machine only, so change-making needs the building.
data:extend({
    {
        type = "recipe-category",
        name = "exchange",
    },
})

local machine = data.raw["assembling-machine"]["import"]
assert(machine, "exchange: there is no Import machine to craft an exchange recipe")
table.insert(machine.crafting_categories, "exchange")


local authored = {}
local summary = {}

for index, row in ipairs(exchanges) do
    local from = currency[row.from]
    local to = currency[row.to]
    assert(from, "exchange: the row at position " .. index .. " spends '" .. tostring(row.from)
        .. "', which is not a denomination")
    assert(to, "exchange: the row at position " .. index .. " pays out '" .. tostring(row.to)
        .. "', which is not a denomination")

    local pair = row.from .. " -> " .. row.to
    assert(not authored[pair], "exchange: '" .. pair .. "' has two rows")
    authored[pair] = true

    -- The guard the whole file rests on. An exchange running up the ladder, or across
    -- one rung, would let the factory mint the coin that gates the next tier of
    -- research, which is the one property the customer economy is built on. Down only.
    assert(currency.rank[to] < currency.rank[from], "exchange: '" .. pair
        .. "' does not go down the ladder; a higher denomination breaks into a lower one, "
        .. "never the other way and never sideways")

    for _, field in ipairs({ "spend", "receive" }) do
        local amount = row[field]
        assert(amount, "exchange: '" .. pair .. "' does not say how many coins it "
            .. field .. "s; write `" .. field .. " = 1`")
        -- The engine takes a uint16 here and rejects 0 outright, but says nothing at all
        -- about a fraction: it settles on a number nobody authored.
        assert(amount == math.floor(amount) and amount >= 1, "exchange: '" .. pair .. "' "
            .. field .. "s " .. amount .. " coin(s); that is a whole number, at least one")
    end
    assert(row.seconds and row.seconds > 0, "exchange: '" .. pair
        .. "' does not say how long the craft takes; write `seconds = 0.5`")

    -- What you get is the icon; what you paid rides in the top-left corner, because
    -- the bottom-right one is where the game draws the item count.
    local icons = prototypes.icons_of(to)
    local paid = prototypes.icons_of(from)[1]
    paid.scale = 0.25
    paid.shift = { -8, -8 }
    table.insert(icons, paid)

    data:extend({
        {
            type = "recipe",
            name = "exchange_" .. row.from .. "_" .. row.to,
            -- Never gated behind a technology. The coin in hand is the only gate that
            -- means anything -- you cannot break one you have not earned -- so a licence
            -- would buy nothing and add one more way to deadlock a new game.
            enabled = true,
            ingredients = {
                { type = "item", name = from, amount = row.spend },
            },
            results = {
                { type = "item", name = to, amount = row.receive },
            },
            icons = icons,
            categories = { "exchange" },
            energy_required = row.seconds,
            subgroup = "currency-exchange",
            order = "a[" .. row.from .. "]",
        }
    })

    table.insert(summary, row.spend .. " " .. row.from .. " -> " .. row.receive .. " " .. row.to)
end


-- What one coin of each rung breaks into, read off the rows rather than assumed. Only
-- the adjacent chain is used: a longer row is legal, and pricing through it would
-- disagree with pricing through the steps it skips.
local factor = {}
for _, row in ipairs(exchanges) do
    local from = currency.rank[currency[row.from]]
    if currency.rank[currency[row.to]] == from - 1 then
        factor[from] = row.receive / row.spend
    end
end

-- Each rung's worth in the cheapest coin on the ladder. Cumulative, so it follows a
-- retuned rate instead of restating one.
local worth = { 1 }
for at = 2, #currency.ladder do
    assert(factor[at], "exchange: nothing breaks a " .. currency.ladder[at] .. " into a "
        .. currency.ladder[at - 1] .. ", so a bill spanning those two rungs can be priced in "
        .. "neither. Every adjacent pair needs its own row, even where a longer one already "
        .. "skips past it")
    -- A rung worth no more than the one below makes "the dearer coin" meaningless, and
    -- folding a bill upward would shrink it. The engine takes such a recipe happily; it
    -- is only the money that stops making sense.
    assert(factor[at] > 1, "exchange: one " .. currency.ladder[at] .. " breaks into only "
        .. factor[at] .. " " .. currency.ladder[at - 1]
        .. "; a coin has to be worth more than the coin below it")
    worth[at] = worth[at - 1] * factor[at]
end


-- A bill spread over several rungs, as a single number of rung-`at` coins: 250 Penny is
-- 50 Silver Coin, and 50 Silver Coin is 250 Penny again. `vector` is indexed by rung.
--
-- Fractional on purpose -- rounding is the caller's decision, not the ladder's. Because
-- the fold and the recipes above use the same rates, a payout folded up covers the bill
-- exactly: whatever rung the bill wants, breaking down from the top reaches it, so long
-- as no rung of the bill sits ABOVE `at`. Nothing runs back up the ladder.
local function value_at(vector, at)
    local total = 0
    for rung = 1, #currency.ladder do
        total = total + (vector[rung] or 0) * worth[rung]
    end
    return total / worth[at]
end


log("[exchange] " .. #exchanges .. " conversion(s): " .. table.concat(summary, ", ") .. ".")

return {
    rows = exchanges,
    worth = worth,
    value_at = value_at,
}
