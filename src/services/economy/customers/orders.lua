-- orders.lua -- who walks in, what they order, and how long they last.
--
-- Owns the band table and the order ladder, and the item prototype for each order. The
-- recipes that consume them live with the machine that crafts them: `customer-new` in
-- entrance.lua, `customer_<x>_deliver` in export.lua.
--
-- The `cost` and `refund` numbers are solved, not authored: verify_orders.lua re-solves
-- the recipe graph on every load and prints this whole table back with corrected numbers
-- when it disagrees. See docs/customer-system.md for the ladder and the probability trees.
local currency = require("services.economy.money.currency")

-- A customer's whole life: from the Entrance that mints it to the review it leaves
-- behind. One clock for the whole ladder, because a delivery hands its successor a
-- PERCENTAGE of the timer it consumed (see export.lua): with two timers in play, one
-- inherited 60% would mean two different numbers of seconds.
local total_life_seconds = 5 * 60

-- Integers over this total, never decimal chances. 0.1 + 0.2 + 0.7 is
-- 1.0000000000000002 in IEEE doubles, which fails the sum assertion and, worse,
-- leaves a one-ULP gap between two shared_probability bands where a delivery
-- produces no successor at all and silently leaks a customer.
--
-- 100 so that every `spawn` number below is a whole percent and reads as one.
local weight_total = 100


-- `licence` is the technology that unlocks this band's delivery recipes. The penny
-- band has none and ships enabled: every technology sits behind a lab, a lab behind
-- copper, and copper behind the first Silver Coin that only the penny band can pay.
--
-- `note` is the comment printed above the band's rows. It lives here rather than in the
-- file because verify_orders.lua reprints the whole table: a comment written straight
-- into the block below would be deleted by the first paste.
local bands = {
    { key = "penny",    currency = currency.penny,       icon = "penny",       licence = nil,
      note = "Penny -- wood, stone and iron, all hand-craftable, no research at all." },
    { key = "silver",   currency = currency.silver_coin, icon = "silver-coin", licence = currency.technology.silver_coin,
      note = "Silver -- the first copper, and the first machines built out of it." },
    { key = "banknote", currency = currency.banknote,    icon = "banknote",    licence = currency.technology.banknote,
      note = "Banknote -- nothing here exists without coal and crude oil." },
    { key = "bond",     currency = currency.bond,        icon = "bond",        licence = currency.technology.bond,
      note = "Bond -- the robot era." },
    { key = "gold",     currency = currency.gold_bar,    icon = "gold-bar",    licence = currency.technology.gold_bar,
      note = "Gold -- everything here pays a Bond toll of its own to be built at all." },
}


-- The array below IS the ladder: one rung per row, in order. `band` does not place a
-- row any more, it only says which currency, licence and icon that row deals in -- so a
-- band's rows have to sit together and climb by one, which the loop after the table
-- checks.
--
-- `spawn` is whole percent over rungs RELATIVE to this one: `same`, `up1`..`up9` and
-- `down1`..`down9`. A missing key is 0, and every row sums to `weight_total`. The rung
-- above the last order is the diamond client, so an `up` landing there brings in the
-- rocket customer -- from any row that can reach it, not only the last one. A step off
-- either end of the ladder fails the load unless its weight is 0; that one tolerance is
-- what lets a full nineteen-key template be pasted into every row.
--
-- `cost` is what `amount` of `item` embeds: raw materials at shop prices plus every toll
-- buried in the recipe tree, one entry per denomination. It is here to be read during a
-- balance pass and is used by no calculation.
--
-- `refund` is that same bill folded up into the band's own coin at the exchange rates,
-- to three decimals. Both are SOLVED -- verify_orders.lua recomputes them on every load
-- and prints this table back with the corrections, ready to paste over.
--
-- `profit` is the margin on top, as a fraction: 0.25 pays 125%. A delivery hands over
-- ceil(refund * (profit + 1)) coins, which is the only rounding in the chain.
--
-- Penny orders must be craftable from recipes enabled at game start and need no
-- copper: copper costs Silver, and only the penny band mints one.
local orders = {
    -- Penny -- wood, stone and iron, all hand-craftable, no research at all.
    { band = 1, item = "burner-inserter",        amount = 2,  profit = 0.25,
      cost = { penny = 4 }, refund = 4,
      spawn = { same = 80, up1 = 20 } },
    { band = 1, item = "assembling-machine-1",   amount = 2,  profit = 0.25,
      cost = { penny = 12 }, refund = 12,
      spawn = { down1 = 30, same = 40, up1 = 30 } },
    { band = 1, item = "transport-belt",         amount = 5,  profit = 0.25,
      cost = { penny = 8.75 }, refund = 8.75,
      spawn = { down2 = 10, down1 = 20, same = 40, up1 = 30 } },

    -- Silver -- the first copper, and the first machines built out of it.
    { band = 2, item = "inserter",               amount = 1,  profit = 0.25,
      cost = { penny = 2, silver_coin = 0.375 }, refund = 0.775,
      spawn = { same = 25, up1 = 50, up2 = 25 } },
    { band = 2, item = "splitter",               amount = 2,  profit = 0.25,
      cost = { penny = 26, silver_coin = 3.75 }, refund = 8.95,
      spawn = { down1 = 25, same = 25, up1 = 50 } },
    { band = 2, item = "assembling-machine-2",   amount = 3,  profit = 0.25,
      cost = { penny = 52.5, silver_coin = 6.375 }, refund = 16.875,
      spawn = { down2 = 25, down1 = 25, same = 25, up1 = 25 } },

    -- Banknote -- nothing here exists without coal and crude oil.
    { band = 3, item = "bulk-inserter",          amount = 5,  profit = 0.25,
      cost = { penny = 142.5, silver_coin = 55, banknote = 0.414 }, refund = 17.114,
      spawn = { same = 25, up1 = 50, up2 = 25 } },
    { band = 3, item = "electric-furnace",       amount = 5,  profit = 0.25,
      cost = { penny = 250, silver_coin = 81.25, banknote = 7.069 }, refund = 33.319,
      spawn = { down1 = 25, same = 25, up1 = 50 } },
    { band = 3, item = "productivity-module",    amount = 10, profit = 0.25,
      cost = { penny = 75, silver_coin = 191.25, banknote = 4.137 }, refund = 45.387,
      spawn = { down2 = 25, down1 = 25, same = 25, up1 = 25 } },

    -- Bond -- the robot era.
    { band = 4, item = "construction-robot",     amount = 10, profit = 0.25,
      cost = { penny = 119, silver_coin = 81.25, banknote = 33.382 }, refund = 10.879,
      spawn = { same = 25, up1 = 50, up2 = 25 } },
    { band = 4, item = "logistic-robot",         amount = 10, profit = 0.25,
      cost = { penny = 129, silver_coin = 138.75, banknote = 35.037 }, refund = 13.59,
      spawn = { down1 = 25, same = 25, up1 = 50 } },
    { band = 4, item = "roboport",               amount = 2,  profit = 0.25,
      cost = { penny = 405, silver_coin = 292.5, banknote = 9.446 }, refund = 16.83,
      spawn = { down2 = 25, down1 = 25, same = 25, up1 = 25 } },

    -- Gold -- everything here pays a Bond toll of its own to be built at all.
    { band = 5, item = "express-transport-belt", amount = 20, profit = 0.25,
      cost = { penny = 335, silver_coin = 20, banknote = 3.2, bond = 20 }, refund = 4.824,
      spawn = { same = 25, up1 = 50, up2 = 25 } },
    { band = 5, item = "beacon",                 amount = 5,  profit = 0.25,
      cost = { penny = 275, silver_coin = 368.75, banknote = 8.273, bond = 5 }, refund = 4.721,
      spawn = { down1 = 25, same = 25, up1 = 50 } },
    { band = 5, item = "productivity-module-3",  amount = 2,  profit = 0.25,
      note = "The last rung. Its `up1` steps off the ladder onto the diamond client, which is the only way one enters the population.",
      cost = { penny = 892.5, silver_coin = 1487, banknote = 85.01, bond = 2 }, refund = 17.125,
      spawn = { down2 = 25, down1 = 25, same = 25, up1 = 25 } },
}


-- Customer items that are not orders: neither gets a delivery recipe, so the
-- generator skips both and their prototypes are written by hand.
--
--   review   -- what every customer leaves behind once its five minutes are up. No
--              recipe and no spoil timer, so reviews only ever pile up. One spoiling
--              inside a machine's ingredient slot jams that machine for good.
--   diamond  -- the client who wants a rocket launched. The satellite recipe consumes
--              them (see tolls.lua) and the launch pays 1000 Diamonds. The only way a
--              customer leaves without leaving a review.
local terminal_tokens = { review = true, diamond = true }


-- Built before the generator so the spoil chain resolves against it: a typo fails
-- at load instead of producing an unknown-item reference.
local item_by_key = {}
for token in pairs(terminal_tokens) do
    item_by_key[token] = "customer_" .. token
end
for _, order in ipairs(orders) do
    -- One item is one customer prototype, so two rows naming it would leave the second
    -- delivery recipe emitting that name twice in one `results` list, which the engine
    -- refuses. Not an assert: Lua builds the message argument whether or not the
    -- condition holds, and there is nothing to name on the passing path.
    if item_by_key[order.item] then
        error("customers: '" .. order.item .. "' is ordered twice; one item is one customer", 0)
    end
    item_by_key[order.item] = "customer_" .. order.item
end


-- A band's rows sit together and climb by one. `is_top` below means "last row of its
-- band" and is where the bridge coin hangs, so a band split in two would hang it
-- mid-ladder and run the payout currency up and then back down again.
for index, order in ipairs(orders) do
    order.index = index
    local band = bands[order.band]
    assert(band, "customers: '" .. order.item .. "' has no band " .. tostring(order.band))

    -- Derived, never authored: the coin a delivery pays in follows the band, and an
    -- authored copy could disagree with the row it sits on.
    order.currency = band.currency

    assert(type(order.refund) == "number" and order.refund >= 0,
        "customers: '" .. order.item .. "' refunds " .. tostring(order.refund)
            .. "; that is one number of " .. band.key .. ", not a map")
    assert(type(order.profit) == "number" and order.profit >= 0,
        "customers: '" .. order.item .. "' takes a profit of " .. tostring(order.profit)
            .. "; that is a fraction of the refund, so 0.25 pays 125% and 0 breaks even")

    -- ceil is the only rounding between the shop price and the coin handed over.
    order.payout = math.ceil(order.refund * (order.profit + 1))

    local dearest = 0
    for denomination in pairs(order.cost or {}) do
        local name = currency[denomination]
        assert(name, "customers: '" .. order.item .. "' costs '" .. tostring(denomination)
            .. "', which is not a denomination")
        dearest = math.max(dearest, currency.rank[name])
    end
    -- Nothing runs back up the ladder, so a band paying a coin cheaper than something
    -- its own recipe tree needs can never fund that need: the order looks solvent and is
    -- unservable. Not an assert -- Lua builds the message argument whether or not the
    -- condition holds, and `dearest` is 0 on a row whose `cost` is still the placeholder.
    if dearest > currency.rank[band.currency] then
        error("customers: '" .. order.item .. "' is paid in " .. band.key .. " but its cost "
            .. "reaches " .. currency.key_at[dearest] .. "; a refund breaks downward only, so "
            .. "that coin could never be earned back. Move the order up a band, or drop the toll", 0)
    end

    local previous = orders[index - 1]
    if previous then
        assert(order.band == previous.band or order.band == previous.band + 1,
            "customers: '" .. order.item .. "' is band " .. order.band .. " at ladder position "
                .. index .. ", under '" .. previous.item .. "' in band " .. previous.band
                .. "; a band's rows sit together, and the only band that may follow is the next one up")
    else
        assert(order.band == 1,
            "customers: the ladder starts with '" .. order.item .. "' in band " .. order.band
                .. "; position 1 is what the Entrance mints, so it is band 1")
    end
end

assert(orders[#orders].band == #bands,
    "customers: the ladder stops in band " .. orders[#orders].band .. " ('"
        .. bands[orders[#orders].band].key .. "'), but band " .. #bands .. " ('"
        .. bands[#bands].key .. "') is the last one; every band needs at least one order")

-- Where the next denomination's coin hangs. Derived, never authored, so it follows a
-- band that gains or loses a row.
for index, order in ipairs(orders) do
    local above = orders[index + 1]
    order.is_top = above == nil or above.band ~= order.band
end


-- The nineteen keys a `spawn` row may use, and the rung each one counts to. Built
-- rather than pattern-matched so the check and the walk cannot drift apart, and walked
-- in ladder order so the successor list -- and the shared_probability bands export.lua
-- lays end to end from it -- comes out the same on every load. Reading `pairs(spawn)`
-- here instead would make those bands load-order dependent and two players' saves
-- disagree.
local steps = {}
local step_offset = {}
for offset = -9, 9 do
    local key
    if offset < 0 then
        key = "down" .. -offset
    elseif offset == 0 then
        key = "same"
    else
        key = "up" .. offset
    end
    steps[#steps + 1] = key
    step_offset[key] = offset
end


-- What the row actually says, in ladder order, for the assertion that has to show it.
local function authored_row(spawn)
    local parts = {}
    for _, key in ipairs(steps) do
        if spawn[key] then
            parts[#parts + 1] = key .. "=" .. tostring(spawn[key])
        end
    end
    return table.concat(parts, " ")
end


-- Decides nothing itself: turns each authored step into the rung it points at and the
-- customer standing there. The rung above the last order is the diamond client, and the
-- ladder ends there because the diamond has no delivery recipe to step off it again.
local function successors_of(order)
    local spawn = order.spawn
    assert(spawn, "customers: order '" .. order.item .. "' has no spawn row")

    local unknown = {}
    local authored = 0
    for key, weight in pairs(spawn) do
        if step_offset[key] == nil then
            unknown[#unknown + 1] = tostring(key)
        else
            assert(type(weight) == "number" and weight >= 0 and weight == math.floor(weight),
                "customers: '" .. order.item .. "' spawns " .. tostring(weight) .. " at '" .. key
                    .. "'; every entry is a whole percent of 0 or more")
            authored = authored + weight
        end
    end
    if #unknown > 0 then
        -- Collected and sorted rather than raised where it was found: pairs() has no
        -- order, so which of two typos got named would vary between loads.
        table.sort(unknown)
        error("customers: '" .. order.item .. "' has unknown spawn key(s) '"
            .. table.concat(unknown, "', '")
            .. "' -- expected 'same', 'up1'..'up9' or 'down1'..'down9'", 0)
    end

    local last_rung = #orders + 1
    local successors = {}
    for _, key in ipairs(steps) do
        local weight = spawn[key]
        -- A 0 drops out rather than becoming a successor: keeping it would emit a
        -- shared_probability slice whose min equals its max, which can never fire. It is
        -- also the only weight allowed to point off the ladder, which is what lets one
        -- nineteen-key template be pasted into every row.
        if weight and weight > 0 then
            local rung = order.index + step_offset[key]
            assert(rung >= 1 and rung <= last_rung,
                "customers: '" .. order.item .. "' sits at ladder position " .. order.index
                    .. ", so its '" .. key .. "' points at position " .. rung .. "; the ladder runs 1 to "
                    .. last_rung .. " (" .. #orders .. " orders plus the diamond client)."
                    .. " Only a 0 may point off it")
            -- What a delivery emits is the CUSTOMER, never the goods -- `order.item` in a
            -- result would hand out free machines and drain the population at once.
            local ahead = orders[rung]
            successors[#successors + 1] = {
                customer = ahead and item_by_key[ahead.item] or item_by_key.diamond,
                weight = weight,
            }
        end
    end

    assert(authored == weight_total,
        "customers: spawn row for '" .. order.item .. "' sums to " .. authored .. ", expected "
            .. weight_total .. " -- authored: " .. authored_row(spawn))

    return successors
end


data:extend({
    {
        type = "item",
        name = item_by_key.review,
        icon = "__profitorio__/graphics/icons/review.png",
        icon_size = 64,
        -- Every customer ends as one of these and no recipe takes them, so the pile
        -- grows at the Entrance's rate for the whole save. Stacking keeps that a
        -- logistics problem rather than an arithmetic one -- it is still a dead end.
        stack_size = 100,
    },
    {
        type = "item",
        name = item_by_key.diamond,
        icons = {
            {
                icon = "__profitorio__/graphics/icons/customer.png",
                icon_size = 64,
                icon_mipmaps = 4
            },
            {
                icon = "__profitorio__/graphics/icons/diamond.png",
                icon_size = 64,
                icon_mipmaps = 4,
                scale = 0.3,
                shift = { 6, 6 }
            }
        },
        stack_size = 1,
        spoil_ticks = total_life_seconds * 60,
        spoil_result = item_by_key.review,
    }
})

for _, order in ipairs(orders) do
    order.successors = successors_of(order)

    data:extend({
        {
            type = "item",
            name = item_by_key[order.item],
            icons = {
                {
                    icon = "__profitorio__/graphics/icons/customer.png",
                    icon_size = 64,
                    icon_mipmaps = 4
                },
                {
                    icon = "__base__/graphics/icons/" .. order.item .. ".png",
                    icon_size = 64,
                    icon_mipmaps = 4,
                    scale = 0.3,
                    shift = { 6, 6 }
                }
            },
            stack_size = 1,
            spoil_ticks = total_life_seconds * 60,
            -- The whole life, not this rung's share of it: there is no lower rung to
            -- step down into, only the review.
            spoil_result = item_by_key.review,
        }
    })
end


-- The bottom rung, and so what the Entrance mints (entrance.lua).
local entry = orders[1].item

log("[customers] " .. #orders .. " orders across " .. #bands .. " bands, plus review and diamond.")

-- Anything a delivery recipe emits has to be in here; the one thing that must never
-- end up in a result is the vanilla item the customer is asking for.
local is_customer = {}
for _, name in pairs(item_by_key) do
    is_customer[name] = true
end

return {
    bands = bands,
    orders = orders,
    item = item_by_key,
    is_customer = is_customer,
    entry = entry,
    weight_total = weight_total,
    -- verify_orders.lua reprints the `spawn` rows and has to walk them in the same order
    -- the successor list does, or the block it emits reorders keys on every load.
    steps = steps,
}
