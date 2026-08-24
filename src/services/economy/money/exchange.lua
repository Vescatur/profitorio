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
-- 1:5 is a deliberate loss. The refund table pays around 8 Pennies for the work that
-- earns one Silver Coin, so breaking a coin is always worse than earning the lower
-- one directly -- change-making is a convenience, not an income. The top three rungs
-- have no refund ratio to read a fair rate off and are first guesses.
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

log("[exchange] " .. #exchanges .. " conversion(s): " .. table.concat(summary, ", ") .. ".")

return exchanges
