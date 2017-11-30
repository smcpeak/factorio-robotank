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

-- World entity for the robotank turret.  Conceptually, I want the tank
-- to attack with its own, normal machine gun.  But it is somewhat
-- difficult to replicate all of the attack behavior, and seems to be
-- impossible to replicate the enemy aggro behavior.  So I attach a turret
-- entity to the tank to perform those functions.
local robotank_turret_entity = table.deepcopy(data.raw["ammo-turret"]["gun-turret"]);
robotank_turret_entity.name = "robotank-turret-entity";

-- Do not collide with parent tank.
robotank_turret_entity.collision_mask = {};

-- Also empty the turret collision box, which otherwise interferes with
-- an inserter trying to put items into the tank.
robotank_turret_entity.collision_box = {{0,0}, {0,0}};

-- Do not allow the turret to be individually selected.  This also
-- causes its health bar to not appear.
robotank_turret_entity.selection_box = {{0,0}, {0,0}};

-- This is probably irrelevant with no selection box, but just in case,
-- make sure the turret cannot be mined.  (It gets destroyed automatically
-- when the tank is destroyed or mined.)
robotank_turret_entity.minable = nil;

-- Copy the damage characteristics of the tank machine gun to
-- the robotank turret.
local tank_machine_gun = data.raw.gun["tank-machine-gun"];
robotank_turret_entity.attack_parameters.cooldown        = tank_machine_gun.attack_parameters.cooldown;
robotank_turret_entity.attack_parameters.range           = tank_machine_gun.attack_parameters.range;
robotank_turret_entity.attack_parameters.damage_modifier = tank_machine_gun.attack_parameters.damage_modifier;

-- Also match its resistances to those of the tank, since in most
-- cases it is the turret that will be taking damage from enemies.
robotank_turret_entity.resistances = table.deepcopy(robotank_entity.resistances);

-- Raise the turret's max health to ensure it won't be one-shot by
-- anything, and also ensure its max health is what my script
-- expects in order to properly calculate damage taken to transfer
-- it to the tank.
robotank_turret_entity.max_health = 1000;

robotank_turret_entity.flags = {
  "player-creation",        -- Supposedly this factors into enemy aggro.
  "placeable-off-grid",     -- Allow initial placement to be right where I put it.
  "not-on-map",             -- Do not draw the turret on the minimap.
  "not-repairable",         -- Bots cannot repair the turret (any damage is moved to the tank).
};

-- Remove all of the graphics associated with the turret since they
-- overlay weirdly on the tank and aren't needed since the tank itself
-- provides more or less adequate visuals.
local blank_layers = {
  layers = {
    {
      axially_symmetrical = false,
      direction_count = 1,
      filename = "__VehicleLeash__/graphics/empty16x16.png",
      frame_count = 1,
      height = 16,
      width = 16
    },
  },
};
robotank_turret_entity.attacking_animation = blank_layers;
robotank_turret_entity.base_picture = blank_layers;
robotank_turret_entity.folded_animation = blank_layers;
robotank_turret_entity.folding_animation = blank_layers;
robotank_turret_entity.prepared_animation = blank_layers;
robotank_turret_entity.preparing_animation = blank_layers;

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
