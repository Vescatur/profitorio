-- recipes.lua -- re-costs the penny band's goods onto one bought raw material
-- each. The other service that adds rather than removes, alongside loaders.lua.

local recosts = {
    ["burner-inserter"]      = { { type = "item", name = "wood",  amount = 2 } },
    ["assembling-machine-1"] = { { type = "item", name = "stone", amount = 5 } },
}

for recipe_name, ingredients in pairs(recosts) do
    local recipe = data.raw.recipe[recipe_name]
    assert(recipe, "starter-recipes: no recipe '" .. recipe_name .. "' to re-cost")
    recipe.ingredients = ingredients
    -- A penny order can never wait on research: every technology sits behind a lab,
    -- a lab behind copper, and copper behind the first Silver Coin only the penny
    -- band mints. `automation` still lists assembling-machine-1 -- unlocking an
    -- already-enabled recipe is a no-op, and it is where tolls.lua reads the Penny
    -- toll from, so dropping the effect would make the machine free.
    recipe.enabled = true
end

log("[starter-recipes] Re-costed burner-inserter onto wood and assembling-machine-1 onto stone.")
