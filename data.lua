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

-- Recipe to allow one to create the robotank.
local robotank_recipe = {
  type = "recipe",
  name = "robotank-recipe",
  enabled = true,
  ingredients = {
    {"iron-plate", 2},
    {"electronic-circuit", 2}
  },
  result = "robotank-item",
};

-- Inventory item corresponding to the robotank.
local robotank_item = table.deepcopy(data.raw["item-with-entity-data"].tank);
robotank_item.name = "robotank-item";
robotank_item.place_result = "robotank-entity";
robotank_item.icons = {
  {
    icon = "__base__/graphics/icons/tank.png",
  },
  {
    icon = "__base__/graphics/icons/iron-plate.png",
    tint = {r=1, g=0, b=0, a=0.5},
  },
};

-- World entity for the robotank.
local robotank_entity = table.deepcopy(data.raw.car.tank);
robotank_entity.name = "robotank-entity";
robotank_entity.minable = {
  mining_time = 1,
  result = "robotank-item",
};

-- World entity for the robotank turret.
local robotank_turret_entity = table.deepcopy(data.raw["ammo-turret"]["gun-turret"]);
robotank_turret_entity.name = "robotank-turret-entity";

-- Do not collide with parent tank.
robotank_turret_entity.collision_mask = {};

-- Also empty the turret collision box, which otherwise interferes with
-- an inserter trying to put items into the tank.
robotank_turret_entity.collision_box = {{0,0}, {0,0}};

-- Do not allow the turret to be individually selected.  This also
-- cause its health bar to not appear.
robotank_turret_entity.selection_box = {{0,0}, {0,0}};

-- This is probably irrelevant with no selection box, but just in case,
-- make sure this cannot be mined.
robotank_turret_entity.minable = nil;

robotank_turret_entity.flags = {
  "player-creation",        -- Supposedly this factors into enemy aggro.
  "placeable-off-grid",     -- Allow initial placement to be right where I put it.
  "not-on-map",             -- Do not draw the turret on the minimap.
  "not-repairable",         -- Bots cannot repair the turret.
};

-- Push these new things into the main data table.
data:extend{
  leash_recipe,
  leash_item,
  gunfire_entity,
  robotank_recipe,
  robotank_item,
  robotank_entity,
  robotank_turret_entity,
};


-- EOF
