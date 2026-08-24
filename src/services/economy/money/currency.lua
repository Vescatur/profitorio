-- currency.lua -- re-skin six vanilla science packs in place into a denomination
-- ladder, so every technology's existing `unit.ingredients` becomes its price.
-- Research costs keep their vanilla numbers. See docs/customer-system.md.
local prototypes = require("lib.prototypes")

-- Vanilla's science pack stack size, so a fortune is a logistics problem rather
-- than one chest slot (the base game coin stacked to 100k). Tune here.
local stack_size = 200

local denominations = {
    { key = "penny",       pack = "automation-science-pack", icon = "penny",       hint = "P" },
    { key = "silver_coin", pack = "logistic-science-pack",   icon = "silver-coin", hint = "S" },
    { key = "banknote",    pack = "chemical-science-pack",   icon = "banknote",    hint = "N" },
    { key = "bond",        pack = "production-science-pack", icon = "bond",        hint = "B" },
    { key = "gold_bar",    pack = "utility-science-pack",    icon = "gold-bar",    hint = "G" },
    { key = "diamond",     pack = "space-science-pack",      icon = "diamond",     hint = "D" },
}

-- Presentation only: the name and every reference to the prototype stay as
-- vanilla left them, which is what re-prices the tech tree for free.
for index, denomination in ipairs(denominations) do
    local item = data.raw.item[denomination.pack]
    assert(item, "currency: base game item '" .. denomination.pack .. "' is missing")

    item.icon = "__profitorio__/graphics/icons/" .. denomination.icon .. ".png"
    item.icon_size = 64
    item.icons = nil

    -- Vanilla shares one "used by labs to research" blurb; ours is per
    -- denomination, from the locale file.
    item.localised_description = nil

    -- Vanilla randomly tints each pack sprite so a belt of them shimmers, which
    -- would mangle flat currency art.
    item.random_tint_color = nil

    -- text_color is optional in the real API (and vanilla omits it), but the
    -- bundled type definitions mark it required.
    ---@diagnostic disable-next-line: missing-fields
    item.color_hint = { text = denomination.hint }
    item.subgroup = "currency"
    item.order = string.char(string.byte("a") + index - 1) .. "[" .. denomination.icon .. "]"
    item.stack_size = stack_size
end

local pack_names = {}
for _, denomination in ipairs(denominations) do
    table.insert(pack_names, denomination.pack)
end

-- Deleted, not hidden: red is copper plate plus a gear and green is an inserter
-- plus a belt, all craftable from purchased plates, so leaving the recipes in
-- would let the factory print its own money. space-science-pack has no vanilla
-- recipe, so the call simply finds nothing for it.
--
-- The technologies stay, and five are now effect-less on purpose: they remain
-- prerequisites and read as a licence to deal in that denomination.
local _, removed_recipe_count = prototypes.delete_recipes(pack_names)

-- Otherwise these keep a science bottle for an icon, fighting the name the locale
-- file gives them. 64px art upscaled into a much larger frame, so it is soft.
for _, denomination in ipairs(denominations) do
    local tech = data.raw.technology[denomination.pack]
    if tech then
        tech.icon = "__profitorio__/graphics/icons/" .. denomination.icon .. ".png"
        tech.icon_size = 64
        tech.icons = nil
    end
end

-- The Penny took the coin's job. The prototype stays, since others name it, but
-- goes back to hidden as it is in vanilla.
data.raw.item.coin.hidden = true
data.raw.item.coin.hidden_in_factoriopedia = true

log("[currency] Re-skinned " .. #denominations .. " science packs into currency and deleted "
    .. removed_recipe_count .. " pack recipe(s).")

-- Item names by denomination, so the rest of the mod never spells out which
-- science pack backs which coin. `technology` holds the same strings again:
-- vanilla names each pack's technology after the pack, and a band's licence is a
-- technology rather than an item, so the two roles are named separately.
-- A denomination key maps to a pack name, but `technology` maps to a nested table,
-- so the value type is only as narrow as `any`.
---@type table<string, any>
local currency = { technology = {} }
for _, denomination in ipairs(denominations) do
    currency[denomination.key] = denomination.pack
    currency.technology[denomination.key] = denomination.pack
end

-- `ladder` is the same six names cheapest-first and `rank` their positions on it, so a
-- rung comparison reads off the table that defines the order rather than a second copy
-- of it. tolls.lua re-exports both; exchange.lua needs them at the data stage, before
-- tolls has run.
currency.ladder = {}
currency.rank = {}
for index, denomination in ipairs(denominations) do
    currency.ladder[index] = denomination.pack
    currency.rank[denomination.pack] = index
end

return currency
