-- RoboTank data.lua
-- Extend the global data table to describe the mod elements.

-- Technology to make robotanks and transmitters.
local robotank_technology = {
  type = "technology",
  name = "robotank-technology",
  effects = {
    {
      type = "unlock-recipe",
      recipe = "robotank-recipe",
    },
    {
      type = "unlock-recipe",
      recipe = "robotank-transmitter-recipe",
    },
  },
  icon = "__RoboTank__/graphics/technology/robotank-technology.png",
  icon_size = 128,       -- Subtle!  This is needed for icons not in the "base" mod!
  order = "e-c-c-2",     -- I want it after "tanks", but this does not work and I do not see why.
  prerequisites = {
    "robotics",
    "tanks"
  },
  unit = {               -- Same cost as tanks.
    count = 75,
    ingredients = {
      {
        "science-pack-1",
        1
      },
      {
        "science-pack-2",
        1
      },
      {
        "science-pack-3",
        1
      },
      {
        "military-science-pack",
        1
      }
    },
    time = 30
  }
};

-- Recipe to allow one to create the transmitter that controls robotanks.
local transmitter_recipe = {
  type = "recipe",
  name = "robotank-transmitter-recipe",
  enabled = false,
  ingredients = {
    {"iron-plate", 6},            -- Six sides of a metal box.
    {"processing-unit", 1},       -- Raise tech requirements.
    {"copper-cable", 1},          -- Antenna.
    {"battery", 1},               -- Power source.
  },
  result = "robotank-transmitter-item",
};

-- Inventory item corresponding to the transmitter.
local transmitter_item = {
  name = "robotank-transmitter-item",
  flags = {},
  icon = "__RoboTank__/graphics/icons/transmitter.png",
  order = "x[transmitter]",
  stack_size = 5,
  subgroup = "defensive-structure",
  type = "item"
};

-- Recipe to allow one to create the robotank.
local robotank_recipe = {
  type = "recipe",
  name = "robotank-recipe",
  enabled = false,
  ingredients = {
    {"tank", 1},                  -- Base vehicle.
    {"processing-unit", 1},       -- Computer for driving and shooting algorithms.
    {"flying-robot-frame", 1},    -- The robot "driver", with its implicit radio receiver.
  },
  result = "robotank-item",
};

-- Inventory item corresponding to the robotank.
local robotank_item = table.deepcopy(data.raw["item-with-entity-data"].tank);
robotank_item.name = "robotank-item";
robotank_item.place_result = "robotank-entity";
robotank_item.stack_size = 5;    -- Like train cars, etc.
robotank_item.subgroup = "defensive-structure";
robotank_item.order = "x[robotank]";
robotank_item.icons = {
  {
    icon = "__base__/graphics/icons/tank.png",
    tint = {r=0.7, g=0.7, b=1, a=1},
  },
};

-- World entity for the robotank.
local robotank_entity = table.deepcopy(data.raw.car.tank);
robotank_entity.name = "robotank-entity";
robotank_entity.icons = robotank_item.icons;
robotank_entity.minable = {
  mining_time = 0.25,          -- Less annoying to pick up a squad.
  result = "robotank-item",
};

-- Make it a little blue so it is visually distinct from the
-- normal tank.
for _, layer in pairs(robotank_entity.animation.layers) do
  layer.tint = {r=0.7, g=0.7, b=1, a=1};
end;

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

-- This affects what is shown when you hover the mouse over
-- the alert for something taking damage.
robotank_turret_entity.icons = robotank_item.icons;


-- Remove all of the graphics associated with the turret since they
-- overlay weirdly on the tank and aren't needed since the tank itself
-- provides more or less adequate visuals.
local blank_layers = {
  layers = {
    {
      axially_symmetrical = false,
      direction_count = 1,
      filename = "__RoboTank__/graphics/empty16x16.png",
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
  robotank_technology,
  transmitter_recipe,
  transmitter_item,
  robotank_recipe,
  robotank_item,
  robotank_entity,
  robotank_turret_entity,
};


-- EOF
