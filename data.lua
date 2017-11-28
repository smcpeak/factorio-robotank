-- VehicleLeash data.lua
-- Extend the global data table to describe the mod elements.

-- Recipe to allow one to create the leash.
local leash_recipe = {
  type = "recipe",
  name = "vehicle-leash-recipe",
  enabled = true,
  ingredients = {
    {"steel-plate", 5},
    {"electronic-circuit", 2}
  },
  result = "vehicle-leash-item",
};

-- Inventory item corresponding to the leash.
local leash_item = table.deepcopy(data.raw.item["iron-plate"]);
leash_item.name = "vehicle-leash-item";
leash_item.icons = {
  {
    icon = "__base__/graphics/icons/tank.png",
  },
  {
    icon = "__base__/graphics/icons/iron-plate.png",
    tint = {r=0, g=1, b=0, a=0.5},
  },
};

-- Gunfire graphics and sound.
local gunfire_entity = table.deepcopy(data.raw.explosion["explosion-hit"]);
gunfire_entity.name = "gunfire-entity";
gunfire_entity.sound = table.deepcopy(data.raw.gun["tank-machine-gun"].attack_parameters.sound);

-- Push these new things into the main data table.
data:extend{
  leash_recipe,
  leash_item,
  gunfire_entity,
};


-- EOF
