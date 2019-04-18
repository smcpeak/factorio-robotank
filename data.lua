-- RoboTank data.lua
-- Extend the global data table to describe the mod elements.

-- Debug option: Show the "hidden" turret.
local show_hidden_turret = false;

-- Tint to apply to robotanks to distinguish them visually from
-- other vehicles.
local robotank_tint = {
  r = settings.startup["robotank-color-red"].value;
  g = settings.startup["robotank-color-green"].value;
  b = settings.startup["robotank-color-blue"].value;

  -- The alpha value is not configurable.  If this is less than
  -- one, the tank is partially transparent, which looks wrong.
  a = 1.0,
};

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
  icon_size = 128,
  order = "e-c-c-2",                   -- Right after "tanks".
  prerequisites = {
    "advanced-electronics-2",          -- Processing unit.
    "robotics",                        -- Flying robot frame.
    "tanks"                            -- Ordinary tank.
  },
  unit = data.raw["technology"].tanks.unit,   -- Same cost as tanks.
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
  icon_size = 32,
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
  energy_required = 2,            -- 2 seconds to build.
  ingredients = {
    {"tank", 1},                  -- Base vehicle.
    {"processing-unit", 20},      -- Computer for driving and shooting algorithms.
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
    icon_size = 32,
    tint = robotank_tint,
  },
};

-- World entity for the robotank.
local robotank_entity = table.deepcopy(data.raw.car.tank);
robotank_entity.name = "robotank-entity";
robotank_entity.icons = robotank_item.icons;
robotank_entity.minable = {
  mining_time = 0.25,          -- Short time to easily pick up a squad.
  result = "robotank-item",
};

-- Make it visually distinct from the normal tank.
for _, layer in pairs(robotank_entity.animation.layers) do
  layer.tint = robotank_tint;
  if (layer.hr_version) then
    layer.hr_version.tint = robotank_tint;
  end;
end;


-- World entity for the robotank turret.  Conceptually, I want the tank
-- to attack with its own, normal machine gun.  But it is somewhat
-- difficult to replicate all of the attack behavior, and seems to be
-- impossible to replicate the enemy aggro behavior.  So I attach a turret
-- entity to the tank to perform those functions.
--
-- I *think* that my turret entity does *not* benefit from gun turret
-- damage upgrades because those appear to be tied to the entity name.
-- But, it should benefit from bullet damage and shooting speed.  All
-- of that is what I intend.  I have not carefully tested any of it,
-- however.
local robotank_turret_entity = table.deepcopy(data.raw["ammo-turret"]["gun-turret"]);

-- This should ideally be renamed to "robotank-gun-turret-entity", but
-- I don't know how to do that in a backward compatible way yet.
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
robotank_turret_entity.attack_parameters =
  table.deepcopy(data.raw.gun["tank-machine-gun"].attack_parameters);

-- Also match its resistances to those of the tank, since in most
-- cases it is the turret that will be taking damage from enemies.
robotank_turret_entity.resistances = table.deepcopy(robotank_entity.resistances);

-- Raise the turret's max health to ensure it won't be one-shot by anything.
--
-- Note that other mods might change this value afterward.  I know that the
-- walls-block-spitters mod does so.
robotank_turret_entity.max_health = 1000;

robotank_turret_entity.flags = {
  "hide-alt-info",          -- Do not show the ammo type icon on the turret.
  "player-creation",        -- Supposedly this factors into enemy aggro.
  "placeable-off-grid",     -- Allow initial placement to be right where I put it.
  "not-on-map",             -- Do not draw the turret on the minimap.
  "not-repairable",         -- Bots cannot repair the turret (any damage is moved to the tank).
  "not-deconstructable",    -- Cannot flag it for deconstruction by bots.
  "not-blueprintable",      -- Cannot put this turret into a blueprint.
};

-- This affects what is shown when you hover the mouse over
-- the alert for something taking damage.
robotank_turret_entity.icons = robotank_item.icons;

-- Place the no-ammo alert icon for the turret at the same place as the
-- no-fuel icon for the tank.
robotank_turret_entity.alert_icon_shift = robotank_entity.alert_icon_shift;

-- Typically the robotanks are fighting right next to the player, so the
-- alert related to attacking is just useless noise.
robotank_turret_entity.alert_when_attacking = false;

-- Match turret rotation to the vehicle.
robotank_turret_entity.rotation_speed = robotank_entity.turret_rotation_speed;

-- "Folding" should happen virtually instantaneously, since the vehicle
-- turret does not actually retract.  I do not know the units of this
-- "speed", but the default is 0.08, and experimentally I determined that
-- smaller numbers make it slower.
robotank_turret_entity.folding_speed = 100;
robotank_turret_entity.preparing_speed = 100;


-- A blank image to substitute away certain graphics.
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

-- Always hide the turret base image.
robotank_turret_entity.base_picture = blank_layers;

if (not show_hidden_turret) then
  -- Remove the turret graphics.
  robotank_turret_entity.attacking_animation = blank_layers;
  robotank_turret_entity.folded_animation    = blank_layers;
  robotank_turret_entity.folding_animation   = blank_layers;
  robotank_turret_entity.prepared_animation  = blank_layers;
  robotank_turret_entity.preparing_animation = blank_layers;

else
  -- When showing the turret, push the RoboTank into a lower render
  -- layer.  This is the same layer as biter corpses, so it does not
  -- look good, but it ensures I can always see the turret.  (It is
  -- not possible to raise the turret render layer.)
  robotank_entity.render_layer = "lower-object-above-shadow";

end;


-- Make a hidden cannon turret as well so that RoboTanks have the option
-- to fire cannon shells.
local robotank_cannon_turret_entity = table.deepcopy(robotank_turret_entity);
robotank_cannon_turret_entity.name = "robotank-cannon-turret-entity";
robotank_cannon_turret_entity.attack_parameters =
  table.deepcopy(data.raw.gun["tank-cannon"].attack_parameters);

-- This prevents the RoboTank from damaging itself when using the cannon.
--
-- It hits itself sometimes with min_range of 4, even though that seems
-- like it should be well beyond the danger zone.
robotank_cannon_turret_entity.attack_parameters.min_range = 5;
robotank_cannon_turret_entity.attack_parameters.projectile_creation_distance = 5;


-- Push the RoboTank things into the main data table.
data:extend{
  robotank_technology,
  transmitter_recipe,
  transmitter_item,
  robotank_recipe,
  robotank_item,
  robotank_entity,
  robotank_turret_entity,
  robotank_cannon_turret_entity,
};


-- ====================================================================
-- ========================= Smart Shells =============================
-- ====================================================================

-- Smart shells are conceptually separable from RoboTank, but in
-- practice, firing dumb shells from RoboTanks causes too much
-- friendly fire, so smart shells are a necessary addition.  I might
-- split this out as its own mod at some point.

-- Technology to make smart cannon shells.
local smart_cannon_shell_technology = {
  type = "technology",
  name = "smart-cannon-shell-technology",
  effects = {
    {
      type = "unlock-recipe",
      recipe = "smart-cannon-shell-recipe",
    },
    {
      type = "unlock-recipe",
      recipe = "smart-explosive-cannon-shell-recipe",
    },
  },
  icon = "__RoboTank__/graphics/technology/smart-cannon-shell-technology.png",
  icon_size = 64,
  order = "e-c-c-3",                   -- After RoboTanks.
  prerequisites = {
    "tanks"                            -- Ordinary tank, which implies red circuit.
  },
  unit = data.raw["technology"].tanks.unit,   -- Same cost as tanks.
};

local smart_uranium_cannon_shell_technology = {
  type = "technology",
  name = "smart-uranium-cannon-shell-technology",
  effects = {
    {
      type = "unlock-recipe",
      recipe = "smart-uranium-cannon-shell-recipe",
    },
    {
      type = "unlock-recipe",
      recipe = "smart-explosive-uranium-cannon-shell-recipe",
    },
  },
  icon = "__RoboTank__/graphics/technology/smart-uranium-cannon-shell-technology.png",
  icon_size = 64,
  order = "e-a-b-2",                   -- After Uranium Ammunition.
  prerequisites = {
    "uranium-ammo"
  },
  unit = data.raw["technology"]["uranium-ammo"].unit,
};


-- Extend the data table with a recipe, item, and projectile for a
-- smart shell based on 'base_prefix'.
local function add_smart_shell(base_prefix)
  local base_shell_name      = base_prefix .. "-shell";
  local base_projectile_name = base_prefix .. "-projectile";

  local recipe_name     = "smart-" .. base_shell_name .. "-recipe";
  local item_name       = "smart-" .. base_shell_name .. "-item";
  local projectile_name = "smart-" .. base_shell_name .. "-projectile";

  -- The recipe is one base shell and one red circuit.
  local recipe = {
    type = "recipe",
    name = recipe_name,
    enabled = false,
    energy_required = 2,               -- 2 seconds to build.
    ingredients = {
      {base_shell_name, 1},
      {"advanced-circuit", 1},
    },
    result = item_name,
  };

  -- Smart shell is basically the same as an ordinary shell
  -- except we override the projectile.
  local base_item = data.raw.ammo[base_shell_name];
  local item = {
    type = "ammo",
    name = item_name,
    description = item_name,
    icon = "__RoboTank__/graphics/icons/" .. item_name .. ".png",
    icon_size = 32,
    ammo_type = table.deepcopy(base_item.ammo_type),
    magazine_size = base_item.magazine_size,
    subgroup = "ammo",
    order = base_item.order .. "-s[smart]",
    stack_size = base_item.stack_size,
  };
  item.ammo_type.action.action_delivery.projectile = projectile_name;

  -- The smart projectile is the same except we eliminate friendly fire.
  local projectile = table.deepcopy(data.raw.projectile[base_projectile_name]);
  projectile.name = projectile_name;

  -- https://wiki.factorio.com/Prototype/Projectile
  -- https://wiki.factorio.com/Types/ForceCondition
  --
  -- There is a bug here: with "not-friend", I cannot shoot rocks and
  -- trees.  With "not-same", rocks and trees can be shot, but so can
  -- allies.
  projectile.force_condition = "not-friend";

  data:extend{recipe, item, projectile};
end;

add_smart_shell("cannon");
add_smart_shell("explosive-cannon");
add_smart_shell("uranium-cannon");
add_smart_shell("explosive-uranium-cannon");

data:extend{
  smart_cannon_shell_technology,
  smart_uranium_cannon_shell_technology,
};


-- EOF
