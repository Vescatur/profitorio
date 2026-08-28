-- verify_orders.lua -- solves what every order costs and prints the `orders` table back
-- with the answer. Emits no prototypes.
--
-- `cost` and `refund` in orders.lua are solved numbers living in an authored table, and
-- they rot: change a shop price, move a toll, retune an exchange rate, take a Factorio
-- update that re-costs a vanilla recipe, and they quietly stop matching. So this
-- re-solves the graph on every load and, when it disagrees, logs the whole corrected
-- block ready to paste over -- then stops the load, because a table nobody pasted is
-- still wrong.
--
-- Per ordered item it computes the cost of one unit as a vector over the six
-- denominations: raw materials at shop prices, plus one coin per toll anywhere in
-- the tree. Water is free. Where an item has several producing recipes the cheapest
-- wins, since that is the route a player takes.
--
-- It does NOT credit byproducts -- each output of a multi-output recipe is priced as
-- if the whole recipe ran for it, which overprices in the player's favour and cannot
-- mislead. Runs in data-updates, after prices.lua priced and tolls.lua charged.

local customers = require("services.economy.customers.orders")
local currency = require("services.economy.money.currency")
local exchange = require("services.economy.money.exchange")
local resources = require("services.economy.shop.prices")

-- Required for the side effect, not for a value: the toll coins have to be in the
-- recipes before the graph below is solved, or every order prices as untolled -- and a
-- refund is generated from that, so it would be silently wrong rather than missing.
require("services.economy.money.tolls")

local ladder = currency.ladder
local rank = currency.rank

-- Comparing two cost vectors needs a scalar, and this one is a design-time comparator,
-- deliberately not the game's exchange rate. money/exchange.lua breaks a coin at 1:5;
-- weighting each rung 100x the one below overprices the upper rungs against that, so
-- "cheapest" still prefers the route needing the lowest licence. That direction is the
-- safe one -- it can only overstate what an order costs.
local function scalarise(vector)
    local total = 0
    for at = 1, #ladder do
        total = total + (vector[at] or 0) * 100 ^ (at - 1)
    end
    return total
end

local function key_of(ingredient_type, name)
    return (ingredient_type or "item") .. ":" .. name
end


-- Seeds: everything the factory cannot make for itself.
local seeds = {}

for _, resource in ipairs(resources) do
    local at = rank[resource.currency]
    assert(at, "cost: the shop prices '" .. resource.item .. "' in '" .. resource.currency
        .. "', which is not a denomination")
    local vector = {}
    vector[at] = resource.price / resource.amount
    seeds[key_of("item", resource.item)] = vector
end

-- Water is free and unlimited, so the graph has no producer for it and anything past
-- a chemical plant would price as unreachable. In 2.1 the offshore pump has no fluid
-- of its own -- it takes whatever the tile holds -- so read the tiles.
local free_fluids = {}
for _, tile in pairs(data.raw.tile or {}) do
    if tile.fluid then
        free_fluids[tile.fluid] = true
    end
end
for fluid in pairs(free_fluids) do
    seeds[key_of("fluid", fluid)] = {}
end


-- Categories left out of the cost graph. `exchange` is here on purpose: money is
-- priced at face value and never resolved further, so a conversion recipe would hang a
-- producer on the graph for an item nothing ever asks the cost of -- and if anything
-- ever did, penny -> silver -> penny is a cycle that prices itself.
local own_categories = {
    entrance = true, import = true, export = true, parameters = true, exchange = true
}

local producers = {}

for _, recipe in pairs(data.raw.recipe) do
    local skip = false
    for _, category in pairs(recipe.categories or { "crafting" }) do
        if own_categories[category] then
            skip = true
        end
    end
    if not skip then
        for _, result in pairs(recipe.results or {}) do
            local amount = result.amount
            if not amount then
                amount = ((result.amount_min or 1) + (result.amount_max or 1)) / 2
            end
            -- 2.1 has no single `probability` on a product: the odds are the
            -- independent roll times the width of the shared band, which is what the
            -- recipe tooltip shows. Reading `result.probability` costs nothing and
            -- always yields nil, so a probabilistic recipe would price as certain.
            local chance = result.independent_probability or 1
            local shared = result.shared_probability
            if shared then
                chance = chance * (shared.max - shared.min)
            end
            amount = amount * chance
            if amount > 0 then
                local key = key_of(result.type, result.name)
                producers[key] = producers[key] or {}
                table.insert(producers[key], { recipe = recipe, amount = amount })
            end
        end
    end
end

-- Drop recipes nothing can ever unlock: disabled, and named by no technology.
-- Pricing through one would price a route the player has no access to, and the
-- cheapest route is usually exactly the unreachable one. Nothing in the current data
-- set trips this; keep it, because it is what makes adding a disabled recipe safe.
local unlockable = {}
for _, tech in pairs(data.raw.technology) do
    for _, effect in pairs(tech.effects or {}) do
        if effect.type == "unlock-recipe" then
            unlockable[effect.recipe] = true
        end
    end
end

for key, list in pairs(producers) do
    local kept = {}
    for _, producer in ipairs(list) do
        local recipe = producer.recipe
        if recipe.enabled ~= false or unlockable[recipe.name] then
            table.insert(kept, producer)
        end
    end
    producers[key] = kept
end


local money = {}
for _, name in ipairs(ladder) do
    money[name] = true
end

local solved = {}

local function cost_of(key, visiting)
    local seed = seeds[key]
    if seed then
        return seed
    end
    if solved[key] ~= nil then
        return solved[key] or nil
    end
    if visiting[key] then
        return nil          -- a cycle; this route prices itself
    end

    visiting[key] = true
    local best, best_score = nil, nil

    for _, producer in ipairs(producers[key] or {}) do
        local accumulated = {}
        local reachable = true

        for _, ingredient in pairs(producer.recipe.ingredients or {}) do
            if money[ingredient.name] then
                -- The toll. Money is never bought, only earned, so it is priced at
                -- face value rather than resolved any further.
                local at = rank[ingredient.name]
                accumulated[at] = (accumulated[at] or 0) + (ingredient.amount or 1)
            else
                local nested = cost_of(key_of(ingredient.type, ingredient.name), visiting)
                if not nested then
                    reachable = false
                    break
                end
                for at = 1, #ladder do
                    if nested[at] then
                        accumulated[at] = (accumulated[at] or 0) + nested[at] * (ingredient.amount or 1)
                    end
                end
            end
        end

        if reachable then
            local per_unit = {}
            for at = 1, #ladder do
                if accumulated[at] then
                    per_unit[at] = accumulated[at] / producer.amount
                end
            end
            local score = scalarise(per_unit)
            if not best_score or score < best_score then
                best, best_score = per_unit, score
            end
        end
    end

    visiting[key] = nil
    solved[key] = best or false
    return best
end


-- Below this a rung is noise rather than a price: a coin amortised over a big recipe
-- leaves a crumb many decimal places down. Nothing is forgiven -- the fold below reads
-- the whole vector -- this only decides what is worth printing.
local presence = 0.0005


-- Three decimals, so a fold never produces a number nobody can retype. Nudged before
-- the ceil: `value * 1000` can land one ULP above a whole number, and a bare math.ceil
-- would add a thousandth that the NEXT load takes straight back off. A table that never
-- settles is worse than one that is a thousandth light.
local function to_millis(value)
    return math.ceil(value * 1000 - 1e-6)
end


-- What the table already says, in the same units, so the comparison is between two
-- integers and a clean three-decimal literal can always be matched exactly.
local function authored_millis(value)
    return math.floor((value or 0) * 1000 + 0.5)
end


local function literal(value)
    if value == math.floor(value) then
        return string.format("%d", value)
    end
    -- %.3f pads, so 0.25 would come out as "0.250" -- three digits nobody chose.
    local text = string.format("%.3f", value):gsub("0+$", "")
    return (text:gsub("%.$", ""))
end


local function money(vector)
    local parts = {}
    for at = 1, #ladder do
        if (vector[at] or 0) > presence then
            parts[#parts + 1] = currency.key_at[at] .. " = "
                .. literal(to_millis(vector[at]) / 1000)
        end
    end
    return #parts > 0 and ("{ " .. table.concat(parts, ", ") .. " }") or "{}"
end


-- Ladder order, from the module that owns it, so the printed row and the successor walk
-- cannot disagree. `if spawn[key]` rather than a truth test: an authored 0 is a
-- deliberate "never take this step" and has to survive the round trip.
local function weights(spawn)
    local parts = {}
    for _, key in ipairs(customers.steps) do
        if spawn[key] then
            parts[#parts + 1] = key .. " = " .. literal(spawn[key])
        end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end


local comment_width = 92

local function wrap(text, into)
    local line = nil
    for word in text:gmatch("%S+") do
        if line and #line + 1 + #word > comment_width then
            into[#into + 1] = line
            line = nil
        end
        line = line and (line .. " " .. word) or ("    -- " .. word)
    end
    if line then
        into[#into + 1] = line
    end
end


-- Rendering the table rather than only complaining about it: `cost` and `refund` are
-- solved numbers, so the only sane way to edit them is to paste this over the block.
-- Idempotent by construction -- pasting the output and loading again prints the same
-- bytes, which is why every number goes through `literal` and every comparison through
-- the millis pair above.
--
-- A band's comment comes from bands[n].note, which sits outside the block and survives
-- a paste. A row's comes from `note` on the row, which is why that one is emitted as a
-- field rather than as a comment: a comment inside the block would be pasted away.
local function corrected_table(rows)
    local item_width, amount_width = 0, 0
    for _, row in ipairs(rows) do
        item_width = math.max(item_width, #row.item_text)
        amount_width = math.max(amount_width, #row.amount_text)
    end

    local lines = { "local orders = {" }
    local band_open = nil

    for _, row in ipairs(rows) do
        local order = row.order
        if order.band ~= band_open then
            if band_open then
                lines[#lines + 1] = ""
            end
            band_open = order.band
            wrap(customers.bands[order.band].note, lines)
        end

        lines[#lines + 1] = "    { band = " .. order.band .. ", "
            .. row.item_text .. string.rep(" ", item_width - #row.item_text) .. " "
            .. row.amount_text .. string.rep(" ", amount_width - #row.amount_text)
            .. " profit = " .. literal(order.profit) .. ","
        if order.note then
            lines[#lines + 1] = "      note = " .. string.format("%q", order.note) .. ","
        end
        lines[#lines + 1] = "      cost = " .. money(row.cost)
            .. ", refund = " .. literal(row.refund) .. ","
        lines[#lines + 1] = "      spawn = " .. weights(order.spawn) .. " },"
    end

    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end


local stale = 0
local rows = {}

for _, order in ipairs(customers.orders) do
    local unit = cost_of(key_of("item", order.item), {})
    assert(unit, "cost: '" .. order.item .. "' cannot be made from anything the shop sells")

    local owed = {}
    for at = 1, #ladder do
        owed[at] = (unit[at] or 0) * order.amount
    end

    -- The band's own coin, and the whole bill folded into it at the exchange rates.
    -- orders.lua refuses a bill reaching above that coin, so whatever is handed over can
    -- always be broken back down into what the recipe tree actually owes.
    local at = rank[order.currency]
    local solved = to_millis(exchange.value_at(owed, at))
    local refund = solved / 1000

    local drifted = authored_millis(order.refund) ~= solved

    local authored_cost = {}
    for denomination, amount in pairs(order.cost or {}) do
        authored_cost[rank[currency[denomination]]] = amount
    end
    for rung = 1, #ladder do
        local shown = owed[rung] > presence and to_millis(owed[rung]) or 0
        if shown ~= authored_millis(authored_cost[rung]) then
            drifted = true
        end
    end

    if drifted then
        stale = stale + 1
    end

    rows[#rows + 1] = {
        order = order,
        cost = owed,
        refund = refund,
        item_text = 'item = "' .. order.item .. '",',
        amount_text = "amount = " .. order.amount .. ",",
    }

    -- The balancing readout the `cost` column cannot be: what one delivery costs against
    -- what it hands back, with the margin actually paid once `ceil` has rounded up.
    local margin = refund > 0 and math.floor((order.payout / refund - 1) * 100 + 0.5) or 0
    log("[cost] " .. order.amount .. " x " .. order.item .. " costs " .. literal(refund) .. " "
        .. currency.key_at[at] .. ", pays " .. order.payout .. " (+" .. margin .. "%)")
end

if stale > 0 then
    -- One log call: Factorio prefixes only the first line of an entry, so the pasteable
    -- block starts on line two and comes out clean. tools/check/prototypes.ps1 prints all
    -- of stdout before it reads the exit code, so this survives the failure below.
    log("[cost] " .. stale .. " order(s) no longer match what they cost. Paste this over the "
        .. "`orders` table in services/economy/customers/orders.lua:\n\n"
        .. corrected_table(rows) .. "\n")
    -- error() rather than assert(): assert builds its message on the passing path too,
    -- and there is nothing to say when nothing drifted.
    error("cost: " .. stale .. " order(s) have a stale cost or refund -- the corrected `orders` "
        .. "table is in the [cost] block above", 0)
end

log("[cost] All " .. #customers.orders .. " orders match what they cost.")
