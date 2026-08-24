-- orders.lua -- who walks in, what they order, and how long they last.
--
-- Owns the band table and the item prototype for each order. The recipes that
-- consume them live with the machine that crafts them: `customer-new` in
-- entrance.lua, `customer_<x>_deliver` in export.lua.
--
-- The `refund` numbers are authored, not solved. verify_orders.lua re-solves the recipe
-- graph on every load and asserts none has fallen behind what its order costs.
-- See docs/customer-system.md for the ladder and the probability trees.
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
local bands = {
    { key = "penny",    currency = currency.penny,       icon = "penny",       licence = nil },
    { key = "silver",   currency = currency.silver_coin, icon = "silver-coin", licence = currency.technology.silver_coin },
    { key = "banknote", currency = currency.banknote,    icon = "banknote",    licence = currency.technology.banknote },
    { key = "bond",     currency = currency.bond,        icon = "bond",        licence = currency.technology.bond },
    { key = "gold",     currency = currency.gold_bar,    icon = "gold-bar",    licence = currency.technology.gold_bar },
}


-- `band` and `grade` place the order on the ladder; `refund` is a map of
-- denomination key -> amount and `profit` a plain number in the band's currency.
-- `spawn` is whole percent, indexed BY GRADE: `spawn[g]` is the chance a delivery
-- brings back a grade-`g` customer of the same band, so a row has exactly as many
-- numbers as its band has grades. A literal 0 means "never spawn this grade". The
-- one named key is `up`, the drip that bridges to the band above -- today only top
-- orders carry one, and that is the single route up the ladder. Every row must sum
-- to `weight_total`.
--
-- Grades must run 1..N with no gaps; nothing here assumes N is 3.
--
-- Penny orders must be craftable from recipes enabled at game start and need no
-- copper: copper costs Silver, and only the penny band mints one.
local orders = {
    -- Penny -- wood, stone and iron, all hand-craftable, no research at all.
    { band = 1, grade = 1, item = "burner-inserter",        amount = 2, refund = { penny = 4 }, profit = 4,
      spawn = { 80, 20, 0 } },
    { band = 1, grade = 2, item = "assembling-machine-1",   amount = 2, refund = { penny = 12 }, profit = 8,
      spawn = { 30, 40, 30 } },
    { band = 1, grade = 3, item = "transport-belt",         amount = 5, refund = { penny = 9 },  profit = 4,
      spawn = { 10, 20, 40, up = 30 } },

    -- Silver -- the first copper, and the first machines built out of it.
    { band = 2, grade = 1, item = "inserter",               amount = 1,  refund = { penny = 2, silver_coin = 1 },  profit = 1,
      spawn = { 25, 50, 25 } },
    { band = 2, grade = 2, item = "splitter",               amount = 2,  refund = { penny = 26, silver_coin = 4 }, profit = 2,
      spawn = { 25, 25, 50 } },
    { band = 2, grade = 3, item = "assembling-machine-2",   amount = 3,   refund = { penny = 53, silver_coin = 7 }, profit = 3,
      spawn = { 25, 25, 25, up = 25 } },

    -- Banknote -- nothing here exists without coal and crude oil.
    { band = 3, grade = 1, item = "bulk-inserter",          amount = 5,   refund = { penny = 143, silver_coin = 55, banknote = 1 }, profit = 1,
      spawn = { 25, 50, 25 } },
    { band = 3, grade = 2, item = "electric-furnace",       amount = 5,   refund = { penny = 250, silver_coin = 82, banknote = 8 }, profit = 2,
      spawn = { 25, 25, 50 } },
    { band = 3, grade = 3, item = "productivity-module",    amount = 10,  refund = { penny = 75, silver_coin = 192, banknote = 5 }, profit = 1,
      spawn = { 25, 25, 25, up = 25 } },

    -- Bond -- the robot era.
    { band = 4, grade = 1, item = "construction-robot",     amount = 10,  refund = { penny = 119, silver_coin = 82, banknote = 34 },  profit = 1,
      spawn = { 25, 50, 25 } },
    { band = 4, grade = 2, item = "logistic-robot",         amount = 10,  refund = { penny = 129, silver_coin = 139, banknote = 36 }, profit = 1,
      spawn = { 25, 25, 50 } },
    { band = 4, grade = 3, item = "roboport",               amount = 2,   refund = { penny = 405, silver_coin = 293, banknote = 10 }, profit = 1,
      spawn = { 25, 25, 25, up = 25 } },

    -- Gold -- everything here pays a Bond toll of its own to be built at all.
    { band = 5, grade = 1, item = "express-transport-belt", amount = 20,  refund = { penny = 335, silver_coin = 20, banknote = 4, bond = 20 },   profit = 1,
      spawn = { 25, 50, 25 } },
    { band = 5, grade = 2, item = "beacon",                 amount = 5,   refund = { penny = 275, silver_coin = 369, banknote = 9, bond = 5 },   profit = 1,
      spawn = { 25, 25, 50 } },
    { band = 5, grade = 3, item = "productivity-module-3",  amount = 2,   refund = { penny = 893, silver_coin = 1487, banknote = 86, bond = 2 }, profit = 1,
      spawn = { 25, 25, 25, up = 25 } },
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
    item_by_key[order.item] = "customer_" .. order.item
end


-- `top_grade` is how many grades each band has. The second loop checks the grades
-- run 1..N unbroken: a gap leaves a rung nothing spoils into and an index no spawn
-- row lines up with.
local by_position = {}
local top_grade = {}
for index, order in ipairs(orders) do
    order.index = index
    local position = order.band .. ":" .. order.grade
    -- Not an assert: Lua builds the message argument whether or not the condition
    -- holds, and there is nothing to name on the passing path.
    local clash = by_position[position]
    if clash then
        error("customers: '" .. order.item .. "' and '" .. clash.item
            .. "' both sit at band " .. order.band .. " grade " .. order.grade, 0)
    end
    assert(bands[order.band], "customers: '" .. order.item .. "' has no band " .. tostring(order.band))
    assert(order.grade >= 1 and order.grade == math.floor(order.grade),
        "customers: '" .. order.item .. "' has grade " .. tostring(order.grade)
            .. "; grades are whole numbers counting up from 1")
    by_position[position] = order
    top_grade[order.band] = math.max(top_grade[order.band] or 0, order.grade)
end

local function at(band, grade)
    return by_position[band .. ":" .. grade]
end

for band_index = 1, #bands do
    local count = top_grade[band_index]
    assert(count, "customers: band " .. band_index .. " ('" .. bands[band_index].key
        .. "') has no orders; every band needs at least one")
    for grade = 1, count do
        assert(at(band_index, grade), "customers: band " .. band_index .. " ('"
            .. bands[band_index].key .. "') jumps from grade " .. (grade - 1) .. " to " .. count
            .. "; grade " .. grade .. " is missing")
    end
end

-- Where the `up` drip and the next denomination's coin hang. Derived, never
-- authored, so it follows a band that gains or loses a grade.
for _, order in ipairs(orders) do
    order.is_top = order.grade == top_grade[order.band]
end


-- Decides nothing itself: walks the grades the band has, resolves each into the
-- customer item at that position, and checks the row's length and sum. The
-- percentages are authored per order above, which is the one place to tune them.
local function successors_of(order)
    local weights = {}

    -- What a delivery emits is the CUSTOMER, never the goods -- `order.item` in a
    -- result would hand out free chests and drain the population at once.
    local function give(customer, weight)
        weights[customer] = (weights[customer] or 0) + weight
    end

    local spawn = order.spawn
    local count = top_grade[order.band]
    assert(spawn, "customers: order '" .. order.item .. "' has no spawn row")

    -- Length first: it is the failure a band that gained or lost a grade actually
    -- produces, and saying so beats reporting the sum that follows.
    assert(#spawn == count,
        "customers: '" .. order.item .. "' has a spawn row of " .. #spawn .. " number(s), but band "
            .. order.band .. " ('" .. bands[order.band].key .. "') has " .. count
            .. " grade(s); write one percentage per grade, 0 included")

    for key in pairs(spawn) do
        assert(key == "up" or (type(key) == "number" and key >= 1 and key <= count),
            "customers: '" .. order.item .. "' has unknown spawn key '" .. tostring(key)
                .. "' -- expected a grade from 1 to " .. count .. ", or 'up'")
    end

    for grade = 1, count do
        local weight = spawn[grade]
        assert(type(weight) == "number" and weight >= 0 and weight == math.floor(weight),
            "customers: '" .. order.item .. "' spawns " .. tostring(weight) .. " at grade " .. grade
                .. "; every entry is a whole percent of 0 or more")
        -- A 0 drops out rather than becoming a successor: keeping it would emit a
        -- shared_probability slice whose min equals its max, which can never fire.
        if weight > 0 then
            give(item_by_key[at(order.band, grade).item], weight)
        end
    end

    -- Above the top band there is no band left, so the climb leads to the rocket
    -- client instead.
    if spawn.up ~= nil then
        assert(type(spawn.up) == "number" and spawn.up >= 0 and spawn.up == math.floor(spawn.up),
            "customers: '" .. order.item .. "' spawns " .. tostring(spawn.up)
                .. " upward; every entry is a whole percent of 0 or more")
        if spawn.up > 0 then
            local above = at(order.band + 1, 1)
            give(above and item_by_key[above.item] or item_by_key.diamond, spawn.up)
        end
    end

    local successors = {}
    local total = 0
    for customer, weight in pairs(weights) do
        table.insert(successors, { customer = customer, weight = weight })
        total = total + weight
    end
    -- pairs() has no defined order and the shared_probability bands built from this
    -- list have to be stable across loads, or two players' saves disagree.
    table.sort(successors, function(a, b) return a.customer < b.customer end)

    assert(total == weight_total,
        "customers: successor weights for '" .. order.item .. "' sum to " .. total
            .. ", expected " .. weight_total)

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
            -- The whole life, not this rung's share of it: there is no lower grade to
            -- step down into, only the review.
            spoil_result = item_by_key.review,
        }
    })
end


-- What the Entrance spawns, and so the bottom of the economy: by position rather
-- than by row, for the same reason as the diamond.
local entry = at(1, 1).item
assert(item_by_key[entry], "customers: entry order '" .. entry .. "' is not an order")

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
}
