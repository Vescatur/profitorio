-- The orders to fill and what they pay. See services/economy/customers/orders.lua for the band
-- table, and services/economy/money/currency.lua for why the payout is really a science pack.
local prototypes = require("lib.prototypes")
local customers = require("services.economy.customers.orders")

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

local function payout_of(order)
    -- One coin, in the band's own denomination: the whole bill folded up plus the margin,
    -- both settled in orders.lua. What the tree owes in cheaper coins is got by breaking
    -- this one down (services/economy/money/exchange.lua).
    local results = {
        { type = "item", name = order.currency, amount = order.payout },
    }

    -- The bridge upward, from whichever grade is top rather than a hard-coded third. A
    -- recipe may not name the same item in two results, and a band whose neighbour deals
    -- in the same coin would do exactly that, so that one lands on the row above.
    local above = order.is_top and customers.bands[order.band + 1]
    if above then
        if above.currency == order.currency then
            results[1].amount = results[1].amount + 1
        else
            table.insert(results, { type = "item", name = above.currency, amount = 1 })
        end
    end

    for _, result in ipairs(results) do
        assert(result.amount == math.floor(result.amount)
            and result.amount > 0 and result.amount <= 65535,
            "export: '" .. order.item .. "' pays " .. result.amount .. " " .. result.name
                .. "; a result amount must be a positive integer below 65536")
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
    local results = payout_of(order)
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
            overload_multiplier = 1,
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
