-- Order is for reading, not for correctness: the modules that need another one
-- require it themselves and Lua caches the result. The list is complete so the
-- pure side-effect modules run even though nothing requires them.
require("services.removals.ore")
require("services.removals.electricity")
require("services.removals.enemies")
require("services.removals.military")
require("services.removals.uranium")
-- The two services that put vanilla content back rather than taking it away.
require("services.logistics.loaders")
require("services.economy.shop.recipes")
require("services.interface.item_groups")
require("services.economy.money.currency")
require("services.economy.customers.orders")
require("services.economy.customers.entrance")
require("services.economy.shop.import")
require("services.economy.money.exchange")
require("services.economy.customers.export")
require("services.economy.customers.satellite")
