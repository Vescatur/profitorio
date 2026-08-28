-- satellite.lua -- the rocket client rides inside the satellite. A Diamond customer
-- wants one built around them, and the launch pays the vanilla 1000 space-science-pack,
-- which is 1000 Diamonds.
local customers = require("services.economy.customers.orders")

-- The CLIENT, not a Diamond coin. Consuming the customer is the only way one leaves the
-- population without leaving a review, so a coin here would quietly turn the launch into
-- something the factory can buy and leave the client with no consumer at all.
--
-- Its own file rather than a row in tolls.lua: that table charges money for a craft, and
-- this is a customer being served.
local satellite = data.raw.recipe["satellite"]
assert(satellite, "satellite: the recipe is missing; the Diamond client has no consumer")
table.insert(satellite.ingredients,
    { type = "item", name = customers.item.diamond, amount = 1 })

log("[satellite] The rocket client is an ingredient of the satellite.")
