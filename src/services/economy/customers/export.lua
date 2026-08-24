-- The orders to fill and what they pay. See services/economy/customers/orders.lua for the band
-- table, and services/economy/money/currency.lua for why the payout is really a science pack.
local prototypes = require("lib.prototypes")
local customers = require("services.economy.customers.orders")
local currency = require("services.economy.money.currency")

local export_tint = {r=0.6, g=0.7, b=1}
local export_graphics = prototypes.tinted_machine_graphics("assembling-machine-1", export_tint)
local circuit_connector, circuit_wire_max_distance =
    prototypes.machine_circuit_connection("assembling-machine-1")

data:extend({
    {
        type = "recipe-category",
        name = "export",
    },
    {
        type = "item",
        name = "export",
        icons = {
            {
                icon = "__base__/graphics/icons/assembling-machine-1.png",
                icon_size = 64,
                tint = export_tint,
            }
        },
        subgroup = "production-machine",
        order = "a[export]",
        place_result = "export",
        stack_size = 50,
    },
    {
        type = "recipe",
        name = "export",
        enabled = true,
        ingredients = {
            { type = "item", name = "wood", amount = 10 },
        },
        results = {
            { type = "item", name = "export", amount = 1 },
        },
    },
    {
        type = "assembling-machine",
        name = "export",
        icons = {
            {
                icon = "__base__/graphics/icons/assembling-machine-1.png",
                icon_size = 64,
                tint = export_tint,
            }
        },
        flags = { "placeable-neutral", "placeable-player", "player-creation" },
        minable = { mining_time = 0.2, result = "export" },
        max_health = 300,
        collision_box = { { -1.2, -1.2 }, { 1.2, 1.2 } },
        selection_box = { { -1.5, -1.5 }, { 1.5, 1.5 } },
        graphics_set = export_graphics,
        icon_draw_specification = data.raw["assembling-machine"]["assembling-machine-1"].icon_draw_specification,
        circuit_connector = circuit_connector,
        circuit_wire_max_distance = circuit_wire_max_distance,
        crafting_categories = { "export" },
        crafting_speed = 1,
        energy_source = { type = "void" },
        energy_usage = "1kW",
    },
})


-- One delivery recipe per order: where money enters the game. The results list also
-- carries the customer who arrives behind this one, as contiguous shared_probability
-- bands so exactly one successor turns up.

-- A recipe may not name the same item in two results, and the refund and profit are
-- frequently the same denomination. Accumulate by item name first, emit once.
local function payout_of(order, band)
    local totals = {}
    local order_of_appearance = {}

    local function pay(currency_name, amount)
        if not amount or amount <= 0 then
            return
        end
        if not totals[currency_name] then
            table.insert(order_of_appearance, currency_name)
        end
        totals[currency_name] = (totals[currency_name] or 0) + amount
    end

    for denomination, amount in pairs(order.refund) do
        assert(currency[denomination],
            "export: '" .. order.item .. "' refunds '" .. denomination .. "', which is not a denomination")
        pay(currency[denomination], amount)
    end

    pay(band.currency, order.profit)

    -- The bridge upward, from whichever grade is top rather than a hard-coded third.
    if order.is_top then
        local above = customers.bands[order.band + 1]
        if above then
            pay(above.currency, 1)
        end
    end

    local results = {}
    for _, currency_name in ipairs(order_of_appearance) do
        local amount = totals[currency_name]
        assert(amount == math.floor(amount) and amount > 0 and amount <= 65535,
            "export: '" .. order.item .. "' pays " .. amount .. " " .. currency_name
                .. "; a result amount must be a positive integer below 65536")
        table.insert(results, { type = "item", name = currency_name, amount = amount })
    end
    return results
end


-- Contiguous bands over 0..1, built from cumulative integer weights so band k+1's
-- `min` is the same arithmetic as band k's `max` and no gap can open between them. A
-- gap is a delivery that produces no customer at all.
local function append_successors(results, order)
    local cumulative = 0
    for _, successor in ipairs(order.successors) do
        -- What arrives is the next CUSTOMER, never the goods they want: emitting the
        -- vanilla item would hand out free goods and drain the population at once.
        assert(customers.is_customer[successor.customer],
            "export: '" .. order.item .. "' would emit '" .. tostring(successor.customer)
                .. "', which is not a customer item")

        local from = cumulative
        cumulative = cumulative + successor.weight
        -- The missing `always_fresh` is load-bearing: without it the successor inherits
        -- the spoil percent of the customer just served, which is what keeps the five
        -- minutes a total. Setting the flag raises no error and makes customers
        -- immortal.
        table.insert(results, {
            type = "item", name = successor.customer, amount = 1,
            shared_probability = {
                min = from / customers.weight_total,
                max = cumulative / customers.weight_total,
            },
        })
    end
    assert(cumulative == customers.weight_total,
        "export: successor weights for '" .. order.item .. "' sum to " .. cumulative)
end


local gated = 0

for _, order in ipairs(customers.orders) do
    local band = customers.bands[order.band]
    local results = payout_of(order, band)
    append_successors(results, order)

    -- The denomination it pays in, with the goods overlaid, so the crafting menu
    -- reads as a price list.
    local icons = prototypes.icons_of(order.item)
    table.insert(icons, 1, {
        icon = "__profitorio__/graphics/icons/" .. band.icon .. ".png",
        icon_size = 64,
        icon_mipmaps = 4
    })
    for index = 2, #icons do
        icons[index].scale = 0.3
        icons[index].shift = { 6, 6 }
    end

    local recipe_name = customers.item[order.item] .. "_deliver"

    data:extend({
        {
            type = "recipe",
            name = recipe_name,
            -- An unlicensed band still gets customers; you just cannot serve them,
            -- so they run out their five minutes and leave a review. The penny band
            -- ships enabled because every technology is downstream of the first
            -- delivery.
            enabled = band.licence == nil,
            ingredients = {
                { type = "item", name = customers.item[order.item], amount = 1 },
                { type = "item", name = order.item, amount = order.amount }
            },
            results = results,
            icons = icons,
            categories = { "export" },
            energy_required = 0.1,
            subgroup = "customer-deliver",
            -- Zero-padded so the GUI still sorts a ladder of ten rungs or more: these
            -- strings compare as text, and "10" sorts before "2".
            order = string.char(string.byte("a") + order.band - 1)
                .. string.format("%02d", order.index) .. "[" .. order.item .. "]",
        }
    })

    -- These technologies were left effect-less when their science pack recipes were
    -- deleted; dealing in a denomination is what they unlock now.
    if band.licence then
        local tech = data.raw.technology[band.licence]
        assert(tech, "export: licence technology '" .. band.licence .. "' is missing")
        tech.effects = tech.effects or {}
        table.insert(tech.effects, { type = "unlock-recipe", recipe = recipe_name })
        gated = gated + 1
    end
end

log("[export] " .. #customers.orders .. " delivery recipes, " .. gated .. " behind a licence.")
