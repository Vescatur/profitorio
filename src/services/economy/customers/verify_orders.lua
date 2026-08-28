-- verify_orders.lua -- the load-time check that the authored refunds still cover the bill.
-- Emits no prototypes; it is a smoke alarm.
--
-- The refunds in orders.lua are authored, and authored numbers rot: change a shop
-- price, move a toll, take a Factorio update that re-costs a vanilla recipe, and the
-- refund quietly stops covering the order. That is a leak, not a crash. So this
-- re-solves the recipe graph on every load and asserts nothing has fallen behind.
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
local resources = require("services.economy.shop.prices")

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


local function describe(vector)
    local parts = {}
    for at = 1, #ladder do
        if vector[at] and vector[at] > 0.0005 then
            table.insert(parts, string.format("%.2f %s", vector[at], ladder[at]))
        end
    end
    return #parts > 0 and table.concat(parts, " + ") or "nothing"
end

local shortfalls = 0

for _, order in ipairs(customers.orders) do
    local unit = cost_of(key_of("item", order.item), {})
    assert(unit, "cost: '" .. order.item .. "' cannot be made from anything the shop sells")

    local owed = {}
    for at = 1, #ladder do
        owed[at] = (unit[at] or 0) * order.amount
    end

    local refunded = {}
    for denomination, amount in pairs(order.refund) do
        local name = currency[denomination]
        assert(name, "cost: '" .. order.item .. "' refunds '" .. denomination
            .. "', which is not a denomination")
        refunded[rank[name]] = amount
    end

    -- Rung by rung, and no credit for change-making: a refund has to cover its bill in
    -- the denomination the bill is in, even though the exchange could break a dearer
    -- coin into it. Strict in the safe direction.
    for at = 1, #ladder do
        local due = owed[at] or 0
        local paid = refunded[at] or 0
        -- A hundredth of a coin of slack, so floating point cannot manufacture a
        -- shortfall out of an exact match.
        if paid + 0.01 < due then
            shortfalls = shortfalls + 1
            log("[cost] SHORT: " .. order.amount .. " x " .. order.item .. " costs "
                .. describe(owed) .. ", refund pays " .. describe(refunded))
            break
        end
    end

end

assert(shortfalls == 0, "cost: " .. shortfalls
    .. " order(s) refund less than they cost -- see the [cost] SHORT lines above. "
    .. "The authored refunds in services/economy/customers/orders.lua have gone stale.")

log("[cost] All " .. #customers.orders .. " refunds cover their order.")
