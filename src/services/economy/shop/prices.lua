-- prices.lua -- one buy recipe per resource, crafted by the Import machine. The only
-- way raw material enters the factory, now that nothing can be mined.
--
-- Raw material only: ore, not plates, so smelting stays the player's job. Each good
-- is priced in the denomination of the era that needs it, which makes a resource
-- unbuyable before its era rather than merely expensive. Copper is the load-bearing
-- one: circuits need copper, a lab needs circuits, so the whole tech tree sits behind
-- the first Silver Coin.
--
-- The lot size grows with the denomination so unit prices stay in the same range
-- across the ladder -- you buy coal by the hundred, not by the ten.
--
-- Runs in data-updates because crude oil arrives barrelled and base generates every
-- barrel item in its OWN data-updates. The Import machine itself stays in import.lua
-- at the data stage; only the price list moved.
local prototypes = require("lib.prototypes")
local currency = require("services.economy.money.currency")

local resources = {
    {
        item = "wood",
        amount = 1,
        price = 1,
        currency = currency.penny
    },
    {
        item = "iron-ore",
        amount = 2,
        price = 1,
        currency = currency.penny
    },
    {
        item = "stone",
        amount = 1,
        price = 1,
        currency = currency.penny
    },
    {
        item = "copper-ore",
        amount = 4,
        price = 1,
        currency = currency.silver_coin
    },
    {
        item = "coal",
        amount = 100,
        price = 1,
        currency = currency.banknote
    },
    {
        -- Unbarrelling hands back a reusable empty barrel, so the only ongoing cost
        -- is the oil itself.
        item = "crude-oil-barrel",
        amount = 10,
        price = 1,
        currency = currency.banknote
    }
}

for _, resource in ipairs(resources) do
    data:extend({
        {
            type = "recipe",
            name = "buy_" .. resource.item,
            enabled = true,
            ingredients = {
                { type = "item", name = resource.currency, amount = resource.price }
            },
            results = {
                { type = "item", name = resource.item, amount = resource.amount }
            },
            icons = prototypes.icons_of(resource.item),
            categories = { "import" },
            energy_required = 0.1,
            subgroup = "currency-buy",
            order = "a[" .. resource.item .. "]",
        }
    })
end

return resources
