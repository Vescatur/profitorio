-- tolls.lua -- money is an ingredient, not just a research cost: making a thing costs
-- a coin, and the table below says which coin, one row per vanilla recipe. What the
-- toll really costs is working capital -- it comes back in the refund of whatever you
-- deliver.
local currency = require("services.economy.money.currency")

-- Cheapest denomination first, from currency.lua, which is where that order is
-- defined. Both are re-exported at the bottom: verify_orders.lua reads them from here.
local ladder = currency.ladder
local rank = currency.rank

-- Profitorio's three machines. Each name is both a crafting category and the recipe
-- that builds the machine, so this one list covers the buildings and everything they
-- craft. None of it is vanilla, so none of it is in the table below -- and none of it
-- may ever be tolled, since money must not be an ingredient of a recipe that makes
-- money.
--
-- `exchange` is the exception to that naming: a crafting category with no machine of
-- its own, crafted by the Import machine (money/exchange.lua). It is listed so the
-- completeness check below does not demand a toll row for a recipe whose only
-- ingredient is money already.
local own_machines = { entrance = true, import = true, export = true, exchange = true }

-- Every vanilla recipe, grouped by the technology that unlocks it and ordered by the
-- licence that technology invoices -- the coin the player had to have earned already
-- to be crafting this at all. A recipe unlocked by several technologies is charged the
-- cheapest of them, and grouped under it, because the cheapest is the one they paid.
--
-- `toll` names the coin and `amount` how many of them one craft costs -- both are
-- balance knobs, so both are written out on every row even while every amount is still
-- 1. `toll = false` is free to craft and says so out loud, and carries no amount.
--
-- A row that omits either field fails the load, and so does a vanilla recipe with no
-- row at all, so no Factorio update can slip a recipe past the toll booth.
local tolls = {
    -- === No licence to charge ===
    -- Named by no technology, so the player bought no licence and there is nothing
    -- to charge. This is the block that keeps a new game craftable with no money.
    { recipe = "burner-inserter", toll = false },
    { recipe = "iron-chest", toll = false },
    { recipe = "iron-gear-wheel", toll = false },
    { recipe = "stone-furnace", toll = false },
    { recipe = "transport-belt", toll= currency.penny, amount = 2 },
    { recipe = "wooden-chest", toll = false },
    -- Smelting is free and has to stay free: every furnace has
    -- `source_inventory_size = 1`, so a tolled smelting recipe is uncraftable in
    -- every furnace in the game, and the engine reports nothing.
    { recipe = "copper-plate", toll = false },
    { recipe = "iron-plate", toll = false },
    { recipe = "stone-brick", toll = false },
    -- Engine placeholders, never crafted. Listed only because the list has to be
    -- complete for the check below to mean anything.
    { recipe = "parameter-0", toll = false },
    { recipe = "parameter-1", toll = false },
    { recipe = "parameter-2", toll = false },
    { recipe = "parameter-3", toll = false },
    { recipe = "parameter-4", toll = false },
    { recipe = "parameter-5", toll = false },
    { recipe = "parameter-6", toll = false },
    { recipe = "parameter-7", toll = false },
    { recipe = "parameter-8", toll = false },
    { recipe = "parameter-9", toll = false },
    { recipe = "recipe-unknown", toll = false },

    -- A trigger technology has no invoice, so it sells no licence.
    -- electronics
    { recipe = "copper-cable", toll = false },
    { recipe = "electronic-circuit", toll = false },
    { recipe = "inserter", toll = false },
    { recipe = "lab", toll = false },
    -- steam-power
    { recipe = "offshore-pump", toll = false },
    { recipe = "pipe", toll = false },
    { recipe = "pipe-to-ground", toll = false },

    -- === Penny licences ===
    -- automation
    { recipe = "assembling-machine-1", toll = currency.penny, amount = 1 },
    { recipe = "long-handed-inserter", toll = currency.penny, amount = 1 },
    -- fast-inserter
    { recipe = "fast-inserter", toll = currency.penny, amount = 1 },
    -- lamp
    { recipe = "small-lamp", toll = currency.penny, amount = 1 },
    -- logistics
    { recipe = "loader", toll = currency.penny, amount = 1 },
    { recipe = "splitter", toll = currency.penny, amount = 1 },
    { recipe = "underground-belt", toll = currency.penny, amount = 1 },
    -- radar
    { recipe = "radar", toll = currency.penny, amount = 1 },
    -- repair-pack
    { recipe = "repair-pack", toll = currency.penny, amount = 1 },
    -- steel-processing
    { recipe = "steel-chest", toll = currency.penny, amount = 1 },
    -- Smelting again: a furnace has one ingredient slot, so this must stay free.
    { recipe = "steel-plate", toll = false },
    -- oil-processing
    { recipe = "chemical-plant", toll = currency.penny, amount = 1 },
    { recipe = "oil-refinery", toll = currency.penny, amount = 1 },
    { recipe = "solid-fuel-from-petroleum-gas", toll = currency.penny, amount = 1 },
    -- Fluid in, fluid out: a building fed only by pipes has nowhere to take a coin.
    -- Plastic, sulfur, batteries and solid fuel still pay -- they yield items.
    { recipe = "basic-oil-processing", toll = false },

    -- === Silver Coin licences ===
    -- advanced-material-processing
    { recipe = "steel-furnace", toll = currency.silver_coin, amount = 1 },
    -- automation-2
    { recipe = "assembling-machine-2", toll = currency.silver_coin, amount = 1 },
    -- circuit-network
    { recipe = "arithmetic-combinator", toll = currency.silver_coin, amount = 1 },
    { recipe = "constant-combinator", toll = currency.silver_coin, amount = 1 },
    { recipe = "decider-combinator", toll = currency.silver_coin, amount = 1 },
    { recipe = "display-panel", toll = currency.silver_coin, amount = 1 },
    { recipe = "iron-stick", toll = currency.silver_coin, amount = 1 },
    { recipe = "programmable-speaker", toll = currency.silver_coin, amount = 1 },
    -- engine
    { recipe = "engine-unit", toll = currency.silver_coin, amount = 1 },
    -- landfill
    { recipe = "landfill", toll = currency.silver_coin, amount = 1 },
    -- logistics-2
    { recipe = "fast-loader", toll = currency.silver_coin, amount = 1 },
    { recipe = "fast-splitter", toll = currency.silver_coin, amount = 1 },
    { recipe = "fast-transport-belt", toll = currency.silver_coin, amount = 1 },
    { recipe = "fast-underground-belt", toll = currency.silver_coin, amount = 1 },
    -- solar-energy
    { recipe = "solar-panel", toll = currency.silver_coin, amount = 1 },
    -- automobilism
    { recipe = "car", toll = currency.silver_coin, amount = 1 },
    -- concrete
    { recipe = "concrete", toll = currency.silver_coin, amount = 1 },
    { recipe = "hazard-concrete", toll = currency.silver_coin, amount = 1 },
    { recipe = "refined-concrete", toll = currency.silver_coin, amount = 1 },
    { recipe = "refined-hazard-concrete", toll = currency.silver_coin, amount = 1 },
    -- fluid-handling
    { recipe = "barrel", toll = currency.silver_coin, amount = 1 },
    { recipe = "pump", toll = currency.silver_coin, amount = 1 },
    { recipe = "storage-tank", toll = currency.silver_coin, amount = 1 },
    -- A coin per barrel taxes logistics rather than production, and charging to
    -- unbarrel can strand the oil chain outright.
    { recipe = "crude-oil-barrel", toll = false },
    { recipe = "empty-crude-oil-barrel", toll = false },
    { recipe = "empty-heavy-oil-barrel", toll = false },
    { recipe = "empty-light-oil-barrel", toll = false },
    { recipe = "empty-lubricant-barrel", toll = false },
    { recipe = "empty-petroleum-gas-barrel", toll = false },
    { recipe = "empty-sulfuric-acid-barrel", toll = false },
    { recipe = "empty-water-barrel", toll = false },
    { recipe = "heavy-oil-barrel", toll = false },
    { recipe = "light-oil-barrel", toll = false },
    { recipe = "lubricant-barrel", toll = false },
    { recipe = "petroleum-gas-barrel", toll = false },
    { recipe = "sulfuric-acid-barrel", toll = false },
    { recipe = "water-barrel", toll = false },
    -- railway
    { recipe = "cargo-wagon", toll = currency.silver_coin, amount = 1 },
    { recipe = "locomotive", toll = currency.silver_coin, amount = 1 },
    { recipe = "rail", toll = currency.silver_coin, amount = 1 },
    -- automated-rail-transportation
    { recipe = "rail-chain-signal", toll = currency.silver_coin, amount = 1 },
    { recipe = "rail-signal", toll = currency.silver_coin, amount = 1 },
    { recipe = "train-stop", toll = currency.silver_coin, amount = 1 },
    -- fluid-wagon
    { recipe = "fluid-wagon", toll = currency.silver_coin, amount = 1 },
    -- plastics
    { recipe = "plastic-bar", toll = currency.silver_coin, amount = 1 },
    -- sulfur-processing
    { recipe = "sulfur", toll = currency.silver_coin, amount = 1 },
    -- Fluid in, fluid out: nowhere to take a coin.
    { recipe = "sulfuric-acid", toll = false },
    -- advanced-circuit
    { recipe = "advanced-circuit", toll = currency.silver_coin, amount = 1 },
    -- battery
    { recipe = "battery", toll = currency.silver_coin, amount = 1 },
    -- explosives
    { recipe = "explosives", toll = currency.silver_coin, amount = 1 },
    -- bulk-inserter
    { recipe = "bulk-inserter", toll = currency.silver_coin, amount = 1 },
    -- cliff-explosives
    { recipe = "cliff-explosives", toll = currency.silver_coin, amount = 1 },
    -- electric-energy-accumulators
    { recipe = "accumulator", toll = currency.silver_coin, amount = 1 },
    -- modular-armor
    { recipe = "modular-armor", toll = currency.silver_coin, amount = 1 },
    -- efficiency-module
    { recipe = "efficiency-module", toll = currency.silver_coin, amount = 1 },
    -- productivity-module
    { recipe = "productivity-module", toll = currency.silver_coin, amount = 1 },
    -- solar-panel-equipment
    { recipe = "solar-panel-equipment", toll = currency.silver_coin, amount = 1 },
    -- speed-module
    { recipe = "speed-module", toll = currency.silver_coin, amount = 1 },
    -- battery-equipment
    { recipe = "battery-equipment", toll = currency.silver_coin, amount = 1 },
    -- belt-immunity-equipment
    { recipe = "belt-immunity-equipment", toll = currency.silver_coin, amount = 1 },
    -- night-vision-equipment
    { recipe = "night-vision-equipment", toll = currency.silver_coin, amount = 1 },

    -- === Banknote licences ===
    -- advanced-combinators
    { recipe = "selector-combinator", toll = currency.banknote, amount = 1 },
    -- advanced-material-processing-2
    { recipe = "electric-furnace", toll = currency.banknote, amount = 1 },
    -- advanced-oil-processing
    { recipe = "solid-fuel-from-heavy-oil", toll = currency.banknote, amount = 1 },
    { recipe = "solid-fuel-from-light-oil", toll = currency.banknote, amount = 1 },
    -- Fluid in, fluid out: nowhere to take a coin.
    { recipe = "advanced-oil-processing", toll = false },
    { recipe = "heavy-oil-cracking", toll = false },
    { recipe = "light-oil-cracking", toll = false },
    -- low-density-structure
    { recipe = "low-density-structure", toll = currency.banknote, amount = 1 },
    -- processing-unit
    { recipe = "processing-unit", toll = currency.banknote, amount = 1 },
    -- efficiency-module-2
    { recipe = "efficiency-module-2", toll = currency.banknote, amount = 1 },
    -- lubricant
    -- Fluid in, fluid out: nowhere to take a coin.
    { recipe = "lubricant", toll = false },
    -- productivity-module-2
    { recipe = "productivity-module-2", toll = currency.banknote, amount = 1 },
    -- rocket-fuel
    { recipe = "rocket-fuel", toll = currency.banknote, amount = 1 },
    -- speed-module-2
    { recipe = "speed-module-2", toll = currency.banknote, amount = 1 },
    -- electric-engine
    { recipe = "electric-engine-unit", toll = currency.banknote, amount = 1 },
    -- exoskeleton-equipment
    { recipe = "exoskeleton-equipment", toll = currency.banknote, amount = 1 },
    -- power-armor
    { recipe = "power-armor", toll = currency.banknote, amount = 1 },
    -- robotics
    { recipe = "flying-robot-frame", toll = currency.banknote, amount = 1 },
    -- battery-mk2-equipment
    { recipe = "battery-mk2-equipment", toll = currency.banknote, amount = 1 },
    -- construction-robotics
    { recipe = "construction-robot", toll = currency.banknote, amount = 1 },
    { recipe = "passive-provider-chest", toll = currency.banknote, amount = 1 },
    { recipe = "roboport", toll = currency.banknote, amount = 1 },
    { recipe = "storage-chest", toll = currency.banknote, amount = 1 },
    -- logistic-robotics
    { recipe = "logistic-robot", toll = currency.banknote, amount = 1 },
    -- personal-roboport-equipment
    { recipe = "personal-roboport-equipment", toll = currency.banknote, amount = 1 },

    -- === Bond licences ===
    -- coal-liquefaction
    -- Fluid in, fluid out: nowhere to take a coin.
    { recipe = "coal-liquefaction", toll = false },
    -- effect-transmission
    { recipe = "beacon", toll = currency.bond, amount = 1 },
    -- efficiency-module-3
    { recipe = "efficiency-module-3", toll = currency.bond, amount = 1 },
    -- logistics-3
    { recipe = "express-loader", toll = currency.bond, amount = 1 },
    { recipe = "express-splitter", toll = currency.bond, amount = 1 },
    { recipe = "express-transport-belt", toll = currency.bond, amount = 1 },
    { recipe = "express-underground-belt", toll = currency.bond, amount = 1 },
    -- productivity-module-3
    { recipe = "productivity-module-3", toll = currency.bond, amount = 1 },
    -- speed-module-3
    { recipe = "speed-module-3", toll = currency.bond, amount = 1 },
    -- automation-3
    { recipe = "assembling-machine-3", toll = currency.bond, amount = 1 },

    -- === Gold Bar licences ===
    -- fission-reactor-equipment
    { recipe = "fission-reactor-equipment", toll = currency.gold_bar, amount = 1 },
    -- logistic-system
    { recipe = "active-provider-chest", toll = currency.gold_bar, amount = 1 },
    { recipe = "buffer-chest", toll = currency.gold_bar, amount = 1 },
    { recipe = "requester-chest", toll = currency.gold_bar, amount = 1 },
    -- power-armor-mk2
    { recipe = "power-armor-mk2", toll = currency.gold_bar, amount = 1 },
    -- rocket-silo
    { recipe = "cargo-landing-pad", toll = currency.gold_bar, amount = 1 },
    { recipe = "rocket-part", toll = currency.gold_bar, amount = 1 },
    { recipe = "rocket-silo", toll = currency.gold_bar, amount = 1 },
    { recipe = "satellite", toll = currency.gold_bar, amount = 1 },
    -- personal-roboport-mk2-equipment
    { recipe = "personal-roboport-mk2-equipment", toll = currency.gold_bar, amount = 1 },

    -- No Diamond section, and nothing missing: no technology both invoices a Diamond
    -- and unlocks a recipe, so the top of the ladder is spent on research and on
    -- satellite launches, never on a craft.
}


local authored = {}
local coins = {}
local tolled = 0
local free = 0

for index, row in ipairs(tolls) do
    assert(row.recipe, "tolls: the row at position " .. index .. " has no `recipe`")
    assert(not authored[row.recipe], "tolls: '" .. row.recipe .. "' has two rows")
    authored[row.recipe] = true

    local recipe = data.raw.recipe[row.recipe]
    assert(recipe, "tolls: there is no recipe named '" .. row.recipe
        .. "'; fix the name or delete the row")
    assert(row.toll ~= nil, "tolls: '" .. row.recipe
        .. "' does not say what it costs; write `toll = false` if it is free to craft")

    if row.toll == false then
        -- An amount on a free row does nothing at all, which is what a half-finished
        -- edit looks like: the coin was left as `false` and only the amount was typed.
        assert(row.amount == nil, "tolls: '" .. row.recipe
            .. "' is free to craft but asks for " .. tostring(row.amount)
            .. " of nothing; name the coin in `toll` or drop the amount")
        free = free + 1
    else
        local at = rank[row.toll]
        assert(at, "tolls: '" .. row.recipe .. "' is priced in '" .. tostring(row.toll)
            .. "', which is not a denomination")

        for _, category in pairs(recipe.categories or { "crafting" }) do
            -- Keep this assertion. Every furnace has `source_inventory_size = 1`, so a
            -- smelting recipe cannot take a second ingredient: tolling one raises no
            -- error, it silently makes the item uncraftable in every furnace.
            assert(category ~= "smelting", "tolls: '" .. row.recipe
                .. "' is a smelting recipe, and a furnace has one ingredient slot. "
                .. "Tolling it makes the item uncraftable everywhere -- write `toll = false`")
            assert(not own_machines[category], "tolls: '" .. row.recipe
                .. "' is crafted by one of Profitorio's own machines, which must never "
                .. "take money as an ingredient")
        end

        for _, ingredient in pairs(recipe.ingredients or {}) do
            assert(not rank[ingredient.name], "tolls: '" .. row.recipe
                .. "' already asks for money and must not be tolled twice")
        end

        local amount = row.amount
        assert(amount, "tolls: '" .. row.recipe
            .. "' says which coin it costs but not how many; write `amount = 1`")
        -- The engine takes a uint16 here and rejects 0 outright, but says nothing about
        -- a fraction. Assert it whole, so a toll is never a number the engine settled on
        -- rather than one somebody authored.
        assert(amount == math.floor(amount) and amount >= 1, "tolls: '" .. row.recipe
            .. "' asks for " .. amount .. " coin(s); a toll is a whole number, at least one")

        recipe.ingredients = recipe.ingredients or {}
        table.insert(recipe.ingredients, { type = "item", name = row.toll, amount = amount })
        coins[at] = (coins[at] or 0) + amount
        tolled = tolled + 1
    end
end


-- The list has to stay complete: a recipe with no row would craft free of charge and
-- nothing would say so.
local function is_profitorios(recipe_name, recipe)
    if own_machines[recipe_name] then
        return true
    end
    for _, category in pairs(recipe.categories or { "crafting" }) do
        if own_machines[category] then
            return true
        end
    end
    return false
end

local unlisted = {}
for recipe_name, recipe in pairs(data.raw.recipe) do
    if not authored[recipe_name] and not is_profitorios(recipe_name, recipe) then
        table.insert(unlisted, recipe_name)
    end
end
table.sort(unlisted)

assert(#unlisted == 0, "tolls: " .. #unlisted .. " recipe(s) have no row in the toll table: "
    .. table.concat(unlisted, ", ") .. ". Add each one under the technology that unlocks "
    .. "it, with `toll = false` if it should be free to craft.")


-- Which coin a row should ask for is solvable -- it is the cheapest licence that
-- unlocks the recipe -- so solve it as a check rather than in place of the authored
-- value. A Factorio update that moves a recipe onto a dearer technology then reads
-- straight off the load instead of quietly undercharging forever. A `toll = false`
-- row is a deliberate exemption rather than drift, so it is not compared.
local function invoice_rank(tech)
    if not tech.unit then
        return nil                  -- a trigger technology, which has no invoice at all
    end
    local highest = nil
    for _, ingredient in pairs(tech.unit.ingredients or {}) do
        -- Both spellings are legal: {"name", amount} and {name = ..., amount = ...}.
        local name = ingredient[1] or ingredient.name
        local at = rank[name]
        if at and (not highest or at > highest) then
            highest = at
        end
    end
    return highest
end

local licence = {}
for _, tech in pairs(data.raw.technology) do
    local at = invoice_rank(tech)
    if at then
        for _, effect in pairs(tech.effects or {}) do
            if effect.type == "unlock-recipe" then
                local current = licence[effect.recipe]
                if not current or at < current then
                    licence[effect.recipe] = at
                end
            end
        end
    end
end

local drift = {}
for _, row in ipairs(tolls) do
    if row.toll and licence[row.recipe] ~= rank[row.toll] then
        local invoiced = licence[row.recipe]
        table.insert(drift, row.recipe .. " charges " .. row.toll .. ", its cheapest licence "
            .. (invoiced and ("invoices " .. ladder[invoiced]) or "has no invoice"))
    end
end
table.sort(drift)


-- The rocket client. A Diamond customer wants a satellite built around them; the
-- launch pays the vanilla 1000 space-science-pack, which is 1000 Diamonds. It lives
-- here to keep both edits to the satellite recipe in one place.
local customers = require("services.economy.customers.orders")
local satellite = data.raw.recipe["satellite"]
assert(satellite, "tolls: the satellite recipe is missing; the Diamond has no source")
table.insert(satellite.ingredients,
    { type = "item", name = customers.item.diamond, amount = 1 })


-- Coins per denomination rather than recipes, so raising an amount shows up here.
local summary = {}
for at = 1, #ladder do
    if coins[at] then
        table.insert(summary, coins[at] .. " " .. ladder[at])
    end
end

log("[tolls] Tolled " .. tolled .. " recipe(s) for " .. table.concat(summary, ", ")
    .. "; " .. free .. " free to craft.")

for _, line in ipairs(drift) do
    log("[tolls] DRIFT: " .. line)
end
if #drift > 0 then
    log("[tolls] " .. #drift .. " row(s) no longer match the licence they sit behind.")
end

return {
    ladder = ladder,
    rank = rank,
}
