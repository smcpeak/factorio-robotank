-- RoboTank control.lua
-- Actions that run while the user is playing the game.

require "lua_util"         -- add_vec, etc.
require "factorio_util"    -- vehicle_velocity, etc.


-- True when we need to examine the storage data just loaded to
-- upgrade or validate it.
local must_initialize_loaded_storage_data = true;

-- True when, on the next tick, we need to rescan the world to check
-- for consistency with our data structures.
local must_rescan_world = true;

-- How much to log, from among:
--
--   0: Nothing.
--   1: Only things that indicate a serious problem.  These suggest a
--      bug in the RoboTank mod, but are recoverable.
--   2: Relatively infrequent things possibly of interest to the user,
--      such as changes to the formation of tanks, tanks complaining
--      about being stuck, loading ammo, etc.
--   3: Changes to internal data structures.
--   4: Details of algorithms.
--
-- The initial value here is overwritten by a configuration setting
-- during initialization, but takes effect until that happens.
local diagnostic_verbosity = 4;    -- TODO: Change to 1.

-- Debug option to log all damage taken.
local log_all_damage = false;

-- Ticks between ammo checks.  Set during initialization.
local ammo_check_period_ticks = 0;

-- Number of ammo magazines to load into a turret when it is out.
-- Set during initialization.
local ammo_move_magazine_count = 0;


-- Structure of 'storage' is {
--   -- Data version number, bumped when I make a change that requires
--   -- special handling.
--   data_version = 6;
--
--   -- Map from force to its controllers.  Each force's controllers
--   -- are a map from unit_number to its entity_controller object.
--   --
--   -- When a value of this map is stored in a local variable, we use
--   -- the name 'force_controllers'.
--   force_to_controllers = {};
--
--   -- Map from player_index to controllers associated with that
--   -- player.  player_index is LuaPlayer.index.  For a given player,
--   -- its controllers are a subset of those associated with that
--   -- player's force.
--   --
--   -- When a value of this map is stored in a local variable, we use
--   -- the name 'pi_controllers' to distinguish it from
--   -- 'force_controllers'.
--   player_index_to_controllers = {};
--
--   -- Map from player_index to its commander vehicle controller, if
--   -- there is such a commander.
--   player_index_to_commander_controller = {};
-- };

-- Control state for an entity that is relevant to this mod.  All
-- vehicles and player character entities have controller objects,
-- although we only "control" robotanks.
local function new_entity_controller(e)
  return {
    -- Reference to the Factorio entity we are controlling.  This is
    -- either a vehicle (type=="car"), which itself might be a robotank
    -- (name=="robotank-entity"), or a player character (name=="character").
    entity = e,

    -- Associated turret entity that does the shooting.  It is always
    -- non-nil once 'add_entity' does its job for any robotank
    -- vehicle, and nil for any other kind of entity.
    turret = nil,

    -- If this is a robotank that has a commander, this is an {x,y}
    -- position that this robotank should go to in its formation,
    -- relative to the commander, when the commander is facing East.
    formation_position = nil;

    -- When not nil, this records the tick number when the vehicle
    -- became stuck, prevented from going the way it wants to by
    -- some obstacles.  If we are stuck long enough, the vehicle
    -- will try to reverse out.
    stuck_since = nil,

    -- If stuck_since is not nil, then this records the vehicle
    -- orientation at the time we became stuck.  This is used to
    -- avoid cases where the vehicle decides it is stuck even
    -- though it is in the midst of turning.
    stuck_orientation = nil;

    -- When not nil, the vehicle has decided to reverse out of its
    -- current position until the indicated tick count.  When that
    -- tick passes, the vehicle will first brake until it is stopped,
    -- then clear the field and resume normal driving.
    reversing_until = nil,

    -- When this is non-nil, it is the number of ticks for which we
    -- want to keep turning, after which we will straighten the wheel.
    -- This is useful because, for speed, the driving algorithm does
    -- not run on every tick, but we still want to be able to turn
    -- for as little as one tick.  One reason why is, in a tightly
    -- packed formation of tanks, crude steering leads to unnecessary
    -- mutual interference as the tanks drift into each other.
    small_turn_ticks = nil,

    -- When non-nil, we are accelerating for this many ticks, then
    -- will coast.
    short_acceleration_ticks = nil,
  };
end;

-- Map from unit number to array of other entity controllers (on the
-- same force) that are near enough to this one to be relevant for
-- collision avoidance.  When the entry for a given unit number is nil,
-- it needs to be recomputed.
--
-- This data is *not* stored in 'storage' because it would take a lot of
-- space in the save file.  The data is inherently quadratic in size,
-- and the way Factorio serializes mod data adds another factor, such
-- that the serialized size is cubic in the number of tanks.  That in
-- turn causes the Lua interpreter to choke on the data when the save
-- file is loaded ("function or expression too complex") when there are
-- on the order of 40 tanks on the map.
--
-- Fortunately, it is easy to recompute after a load.
local unit_number_to_nearby_controllers = {};


-- Map from hidden turret entity name to true.
local robotank_turret_entity_name_set = {
  ["robotank-turret-entity"]        = true,
  ["robotank-cannon-turret-entity"] = true,
};

-- Map from ammo_category to hidden turret entity name that can fire
-- that kind of ammo.
--
-- Eventually I'd like to expand this to handle more ammo types.
local ammo_category_to_turret_name = {
  ["bullet"]              = "robotank-turret-entity",
  ["cannon-shell"]        = "robotank-cannon-turret-entity",
};


-- Forward declarations of functions.
local remove_invalid_entities;
local remove_entity_controller;
local find_unassociated_entities;


-- Log 'str' if we are at verbosity 'v' or higher.
local function diag(v, str)
  if (v <= diagnostic_verbosity) then
    log(str);
  end;
end;


-- Re-read the configuration settings.
local function read_configuration_settings()
  diag(3, "read_configuration_settings started");
  ammo_check_period_ticks = settings.global["robotank-ammo-check-period-ticks"].value;
  ammo_move_magazine_count = settings.global["robotank-ammo-move-magazine-count"].value;
  diagnostic_verbosity = settings.global["robotank-diagnostic-verbosity"].value;
  diag(3, "read_configuration_settings finished");
end;

-- Do it once on startup, then afterward in response to the
-- on_runtime_mod_setting_changed event.
read_configuration_settings();
script.on_event(defines.events.on_runtime_mod_setting_changed, read_configuration_settings);


-- Return the (string) name of the force associated with 'e'.
local function force_of_entity(e)
  return string_or_name_of(e.force);
end;


-- Get the player index associated with entity 'e', or -1 if this
-- entity is not associated with a player.
local function player_index_of_entity(e)
  if (e.type == 'car') then
    -- Vehicle.
    --
    -- Normally vehicles always have a last_user, but with mods it is
    -- evidently possible for last_user to be nil:
    -- https://mods.factorio.com/mod/RoboTank/discussion/5cb114b4a07570000cfc3762
    if (e.last_user == nil) then
      return -1;
    else
      return e.last_user.index;
    end;
  elseif (e.type == 'character') then
    -- Character.
    if (e.player ~= nil) then
      return e.player.index;
    else
      return -1;
    end;
  else
    return -1;
  end;
end;


-- Check that our data invariants hold.  If not, log a message at
-- level 1 and return false.
local function check_invariants()
  -- Check that everything in 'player_index_to_controllers' is also
  -- in 'force_to_controllers'.
  for player_index, pi_controllers in pairs(storage.player_index_to_controllers) do
    for unit_number, controller in pairs(pi_controllers) do
      local entity = controller.entity;
      local entity_pi = player_index_of_entity(entity);
      if (player_index ~= entity_pi) then
        diag(1, "WARNING: Entity " .. entity.unit_number ..
                " has player index " .. entity_pi ..
                " but was found in the table for PI " .. player_index ..
                ".");
        return false;
      end;

      local force = force_of_entity(entity);
      if (storage.force_to_controllers[force][unit_number] ~= controller) then
        diag(1, "WARNING: Controller for entity " .. entity.unit_number ..
                ", with force " .. force ..
                ", was not found in its force table.");
        return false;
      end;
    end;
  end;

  -- Check the maps in the opposite direction.
  for force, force_controllers in pairs(storage.force_to_controllers) do
    for unit_number, controller in pairs(force_controllers) do
      local entity = controller.entity;
      local entity_force = force_of_entity(entity);
      if (force ~= entity_force) then
        diag(1, "WARNING: Entity " .. entity.unit_number ..
                " has force \"" .. entity_force ..
                "\" but was found in the table for \"" .. force .. "\".");
        return false;
      end;

      -- One concern I have here is the association between vehicles
      -- and players.  The GUI information panel for a vehicle labels
      -- the "Last user", but (at least in Factorio 0.17.14)
      -- it does not change when another player uses it.  Instead, the
      -- association seems to never change after placement.  If Factorio
      -- changes that behavior, then my invariants will break, and this
      -- code will have to repair them.
      local player_index = player_index_of_entity(entity);
      if (player_index < 0) then
        diag(1, "WARNING: Entity " .. entity.unit_number ..
                " does not have a player index.");
        return false;
      end;
      if (storage.player_index_to_controllers[player_index][unit_number] ~= controller) then
        diag(1, "WARNING: Controller for entity " .. entity.unit_number ..
                ", with player index " .. player_index ..
                ", was not found in its PI table.");
        return false;
      end;
    end;
  end;

  return true;
end;


-- Clear the storage data structures and rebuild them from the world.
-- This is done in response to discovering a broken invariant as a
-- method of fault tolerance.
local function reset_storage_data()
  diag(1, "RoboTank: resetting storage data");
  must_rescan_world = false;

  -- Clear the data structures so we can rebuild them.
  storage.force_to_controllers = {};
  storage.player_index_to_controllers = {};
  storage.player_index_to_commander_controller = {};

  -- This will re-add all the entities we keep track of.
  find_unassociated_entities();
end;


local function check_or_fix_invariants()
  if (not check_invariants()) then
    reset_storage_data();

    if (not check_invariants()) then
      error("Invariants are still broken even after attempting repair.");
    end;
  end;
end;


-- Return an array of turret entity names.
local function robotank_turret_entity_name_array()
  return table_keys_array(robotank_turret_entity_name_set);
end;

-- True if the given string is the name of a robotank turret entity.
local function is_robotank_turret_entity_name(s)
  return robotank_turret_entity_name_set[s] == true
end;


-- Add an entity to our tables and return its controller.
--
-- Some entities cannot have controllers, in which case return nil.
local function add_entity(e)
  local force_name = force_of_entity(e);
  storage.force_to_controllers[force_name] =
    storage.force_to_controllers[force_name] or {};

  local player_index = player_index_of_entity(e);
  if (player_index < 0) then
    diag(3, "Cannot add entity due to lack of player index:" ..
          " unit=" .. e.unit_number ..
          " type=" .. e.type ..
          " name=" .. e.name ..
          " pos=(" .. e.position.x .. "," .. e.position.y .. ")" ..
          " force=" .. force_name);
    return nil;
  end;
  storage.player_index_to_controllers[player_index] =
    storage.player_index_to_controllers[player_index] or {};

  local controller = new_entity_controller(e);
  storage.force_to_controllers[force_name][e.unit_number] = controller;
  storage.player_index_to_controllers[player_index][e.unit_number] = controller;

  if (e.name == "robotank-entity") then
    -- Is there already an associated turret here?
    local p = controller.entity.position;
    local candidates = e.surface.find_entities_filtered{
      area = {{p.x-0.5, p.y-0.5}, {p.x+0.5, p.y+0.5}},
      name = robotank_turret_entity_name_array(),
    };
    if (#candidates > 0) then
      controller.turret = candidates[1];
      diag(3, "Found existing turret with unit number " .. controller.turret.unit_number .. ".");
    else
      controller.turret = e.surface.create_entity{
        -- Initially, create it as a gun turret.  It may be changed
        -- once we load some ammo.
        name = "robotank-turret-entity",
        position = controller.entity.position,
        force = e.force};
      if (controller.turret) then
        diag(3, "Made new turret: " .. controller.turret.name .. ".");
      else
        -- This unfortunately is not recoverable because I do not check
        -- for a nil turret elsewhere, both for simplicity of logic and
        -- speed of execution.
        error("Failed to create turret for robotank!");
      end;
    end;
  end;

  diag(3, "Added entity: unit=" .. e.unit_number ..
          " type=" .. e.type ..
          " name=" .. e.name ..
          " player_index=" .. player_index_of_entity(e) ..
          " pos=(" .. e.position.x .. "," .. e.position.y .. ")" ..
          " force=" .. force_name);

  return controller;
end;


-- Search the entire data structure for a controller for 'entity',
-- ignoring its force or player_index.
local function find_entity_controller_slow_search(entity)
  for force, force_controllers in pairs(storage.force_to_controllers) do
    for unit_number, controller in pairs(force_controllers) do
      if (controller.entity == entity) then
        return controller;
      end;
    end;
  end;

  return nil;
end;


-- Find the controller object associated with the given entity, if any.
local function find_entity_controller(entity)
  local player_index = player_index_of_entity(entity);
  if (player_index < 0) then
    -- This happens when the player dies.  Resort to a slow search of
    -- the entire data structure to find the controller.  We are about
    -- to remove the controller, so the invariant about controllers being
    -- in the table of their player_index being temporarily broken should
    -- not cause a problem.
    diag(3, "find_entity_controller: player_index < 0, resorting to slow search");
    return find_entity_controller_slow_search(entity);
  end;
  local pi_controllers = storage.player_index_to_controllers[player_index];
  if (pi_controllers) then
    return pi_controllers[entity.unit_number];
  else
    return nil;
  end;
end;


-- The mod just started running.  Some data may or may not have been
-- loaded from 'storage' (depending on whether the mod was previously
-- part of the game, and what version it was if so).  Make sure it is
-- properly initialized.
local function initialize_loaded_storage_data()
  diag(3, "Loaded data_version: " .. serpent.line(storage.data_version));

  if (storage.data_version == 1) then
    diag(2, "RoboTank: Upgrading data_version 1 to 2.");

    -- I renamed "force_to_vehicles" to "force_to_controllers".
    storage.force_to_controllers = storage.force_to_vehicles;
    storage.force_to_vehicles = nil;

    -- I also renamed "nearby_vehicles" to "nearby_controllers".
    if (storage.force_to_controllers ~= nil) then
      for _, force_controllers in pairs(storage.force_to_controllers) do
        for _, controller in pairs(force_controllers) do
          controller.nearby_controllers = controller.nearby_vehicles;
          controller.nearby_vehicles = nil;
        end;
      end;
    end;
    storage.data_version = 2;
  end;

  if (storage.data_version == 2) then
    diag(2, "RoboTank: Upgrading data_version 2 to 3.");

    -- I renamed "vehicle" to "entity".
    if (storage.force_to_controllers ~= nil) then
      for _, force_controllers in pairs(storage.force_to_controllers) do
        for _, controller in pairs(force_controllers) do
          controller.entity = controller.vehicle;
          controller.vehicle = nil;
        end;
      end;
    end;
    storage.data_version = 3;
  end;

  if (storage.data_version == 3) then
    diag(2, "RoboTank: Upgrading data_version 3 to 4.");

    -- I removed "nearby_controllers", instead storing that outside
    -- of 'storage'.
    if (storage.force_to_controllers ~= nil) then
      for _, force_controllers in pairs(storage.force_to_controllers) do
        for _, controller in pairs(force_controllers) do
          controller.nearby_controllers = nil;
        end;
      end;
    end;
    storage.data_version = 4;
  end;

  if (storage.data_version == 4) then
    diag(2, "RoboTank: Upgrading data_version 4 to 5.");

    -- I added 'player_index_to_controllers'.
    storage.player_index_to_controllers = {};
    for force, force_controllers in pairs(storage.force_to_controllers) do
      for unit_number, controller in pairs(force_controllers) do
        local entity = controller.entity;
        if (entity.valid) then
          local player_index = player_index_of_entity(entity);
          if (player_index < 0) then
            -- I do not know if this can happen.
            diag(3, "unit " .. unit_number .. " has no player index, removing it");
            force_controllers[unit_number] = nil;
          else
            storage.player_index_to_controllers[player_index] =
              storage.player_index_to_controllers[player_index] or {}
            storage.player_index_to_controllers[player_index][unit_number] = controller;
            diag(3, "added unit " .. unit_number .. " to player_index " .. player_index);
          end;
        else
          -- One way this happens is if the loaded map was saved with
          -- multiple players in it, but is then loaded with only one
          -- player.
          diag(3, "unit " .. unit_number .. " is invalid, removing it");
          force_controllers[unit_number] = nil;
        end;
      end;
    end;

    -- I replaced 'force_to_commander_controller' with
    -- 'player_index_to_commander_controller'.  I will simply remove
    -- the old map and initialize the new one to empty, in anticipation
    -- that commander refresh will populate it.
    storage.force_to_commander_controller = nil;
    storage.player_index_to_commander_controller = {};
    storage.data_version = 5;
  end;

  if (storage.data_version == 5) then
    diag(2, "RoboTank: Upgrading data_version 5 to 6.");

    -- For the moment, there is nothing to do.  5 was the last version
    -- for Factorio 1.x, and 6 is the first for Factorio 2.x, so I am
    -- creating this as a placeholder for that transition.

    storage.data_version = 6;
  end;

  storage.data_version = 6;

  if (storage.player_index_to_commander_controller == nil) then
    diag(3, "player_index_to_commander_controller was nil, setting it to empty.");
    storage.player_index_to_commander_controller = {};
  else
    diag(3, "player_index_to_commander_controller has " ..
            table_size(storage.player_index_to_commander_controller) .. " entries.");
  end;

  if (storage.force_to_controllers == nil) then
    diag(3, "force_to_controllers was nil, setting it to empty.");
    storage.force_to_controllers = {};
  else
    diag(3, "force_to_controllers has " ..
            table_size(storage.force_to_controllers) .. " entries.");
    for force, force_controllers in pairs(storage.force_to_controllers) do
      diag(3, "  force \"" .. force .. "\" has " ..
              table_size(force_controllers) .. " controllers.");
    end;
  end;

  if (storage.player_index_to_controllers == nil) then
    diag(3, "player_index_to_controllers was nil, setting it to empty.");
    storage.player_index_to_controllers = {};
  else
    diag(3, "player_index_to_controllers has " ..
            table_size(storage.player_index_to_controllers) .. " entries.");
    for player_index, pi_controllers in pairs(storage.player_index_to_controllers) do
      diag(3, "  player_index " .. player_index .. " has " ..
              table_size(pi_controllers) .. " controllers.");
    end;
  end;

  -- Deal with loading a map that had players in it when saved
  -- but the players are now gone.
  remove_invalid_entities();

  check_or_fix_invariants();
end;


-- If there is already a controller for 'entity', return it.  Otherwise,
-- make a new controller and return that.
--
-- If this entity cannot have a controller, return nil.
local function find_or_create_entity_controller(entity)
  local controller = find_entity_controller(entity);
  if (controller ~= nil) then
    diag(3, "Found existing controller object for unit " .. entity.unit_number);
  else
    diag(3, "Unit number " .. entity.unit_number ..
            " has no controller, making a new one.");
    controller = add_entity(entity);
  end;
  return controller;
end;


-- Called during 'find_unassociated_entities' when one is found.
local function found_an_entity(e, turrets)
  --diag(4, "found entity: " .. serpent.block(entity_info(e)));

  -- See if we already know about this entity.
  local controller = find_or_create_entity_controller(e);
  if (controller ~= nil and controller.turret ~= nil) then
    -- This turret is now accounted for (it might have existed before,
    -- or it might have just been created by 'add_entity').
    turrets[controller.turret.unit_number] = nil;
  end;
end;


-- Scan the world for entities that should be tracked in my data
-- structures but are not.  They are then either added to my tables
-- or deleted from the world.
find_unassociated_entities = function()
  -- Scan the surface for all of our hidden turrets so that later we
  -- can get rid of any not associated with a vehicle.
  local turrets = {};
  for _, t in ipairs(game.surfaces[1].find_entities_filtered{name=robotank_turret_entity_name_array()}) do
    turrets[t.unit_number] = t;
  end;

  -- Add all vehicles to 'force_to_controllers' table.
  for _, v in ipairs(game.surfaces[1].find_entities_filtered{type = "car"}) do
    found_an_entity(v, turrets);
  end;

  -- And player characters, mainly so we can avoid running them over
  -- when driving the robotanks.
  for _, character in ipairs(game.surfaces[1].find_entities_filtered{name = "character"}) do
    found_an_entity(character, turrets);
  end;

  -- Destroy any unassociated turrets.  There should never be any, but
  -- this will catch things that might be left behind due to a bug in
  -- my code.
  for unit_number, t in pairs(turrets) do
    diag(1, "WARNING: Should not happen: destroying unassociated turret " .. unit_number);
    t.destroy();
  end;
end;


-- Find the vehicle controller among 'pi_controllers' that is commanding
-- them, if any.
local function find_commander_controller(pi_controllers)
  for unit_number, controller in pairs(pi_controllers) do
    local v = controller.entity;

    -- It is possible for another mod to delete a vehicle without
    -- triggering one of the events I am monitoring.
    if (not v.valid) then
      diag(3, "find_commander_controller: Removing invalid entity " .. unit_number .. ".");
      remove_entity_controller(controller);

    elseif (v.speed == nil) then
      -- The commander must be a vehicle, and hence will have a speed.
      -- This entity does not, so skip it.
      --
      -- This check prevents player characters from being commanders.
      -- I would have thought that checking the "car_trunk" inventory
      -- would suffice, but in fact the quick bar counts as the "trunk"
      -- for a player!  (As of Factorio 0.17, that is probably no longer
      -- true.)

    elseif (v.name == "robotank") then
      -- A robotank cannot be a commander.

    else
      -- It must have the transmitter item in its trunk.
      local inv = v.get_inventory(defines.inventory.car_trunk);
      if (inv and inv.get_item_count("robotank-transmitter-item") > 0) then
        return controller;
      end;
    end;
  end;
  return nil;
end;

-- Get the name of some item in the source inventory that can be
-- added to the destination inventory.  If there are more than one,
-- returns one arbitrarily.  Otherwise return nil.
local function get_insertable_item(source, dest)
  for name, _ in pairs(source.get_contents()) do
    if (dest.can_insert(name)) then
      return name;
    end;
  end;
  return nil;
end;

-- Try to keep the turret stocked up on ammo by taking it from the tank.
local function maybe_load_robotank_turret_ammo(controller)
  -- See if the turret needs another ammo magazine.
  local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
  if (turret_inv == nil) then
    diag(1, "Failed to get turret inventory!");
    return;
  end;

  -- For speed, I only look at the inventory if it is completely empty.
  -- That means there is periodically a frame during which the turret
  -- ammo is empty, so the turret stops firing and shows the no-ammo icon
  -- briefly.
  if (turret_inv.is_empty()) then
    -- Check the vehicle's ammo slot.
    local car_inv = controller.entity.get_inventory(defines.inventory.car_ammo);
    if (not car_inv) then
      diag(1, "Failed to get car_ammo inventory!");
      return;
    end;

    -- Is there ammo in an ammo slot that fits in the turret?
    local ammo_item_name = get_insertable_item(car_inv, turret_inv);

    if (not ammo_item_name) then
      -- No ammo fits in the current turret.  Is there ammo
      -- compatible with a different robotank turret entity?
      for k, n in pairs(car_inv.get_contents()) do
        -- I'm not sure what effect passing "turret" here has.
        local ammo_type = game.item_prototypes[k].get_ammo_type("turret");
        if (ammo_type ~= nil) then
          local new_turret_name = ammo_category_to_turret_name[ammo_type.category];
          if (new_turret_name ~= nil) then
            diag(2, "Changing turret on vehicle " .. controller.entity.unit_number ..
                    " from " .. controller.turret.name ..
                    " to " .. new_turret_name ..
                    " due to loading ammo " .. k ..
                    " with category " .. ammo_type.category .. ".");

            -- Remove the old turret.
            if (not controller.turret.destroy()) then
              diag(1, "WARNING: Failed to destroy turret while changing ammo type!");
            end;

            -- Add the new turret.
            controller.turret = controller.entity.surface.create_entity{
              name = new_turret_name,
              position = controller.entity.position,
              force = controller.entity.force};
            if (not controller.turret) then
              error("Failed to create turret (" .. new_turret_name ..
                    ") for robotank!");
            end;

            -- Refresh the reference to its inventory.
            turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
            if (turret_inv == nil) then
              -- This will leave us in a state where we have an attached
              -- turret but can never fill it or change it...
              diag(1, "Failed to get turret inventory after creating " ..
                      " a new turret with name " .. new_turret_name .. "!");
              return;
            end;

            -- Stop looping over the ammo slots.  Set ammo_item_name
            -- so we will skip checking the trunk and go straight to
            -- inserting the ammo into the new turret.
            ammo_item_name = k;
            break;
          end;
        end;
      end; -- for loop over inventory contents
    end;

    if (not ammo_item_name) then
      -- Try the trunk.
      car_inv = controller.entity.get_inventory(defines.inventory.car_trunk);
      if (not car_inv) then
        diag(1, "Failed to get car_trunk inventory!");
        return;
      end;
      ammo_item_name = get_insertable_item(car_inv, turret_inv);

      -- Here, if 'ammo_item_name' is nil, we do not try changing the turret type.
      -- The rationale is that, since a given tank can only fire one kind
      -- of ammo as long as it has any, the player ought to explicitly
      -- choose one.  They do that by loading ammo into a tank ammo
      -- slot, as opposed to its trunk, which might get used as extra
      -- storage of random stuff (perhaps including other kinds of ammo)
      -- while in the field.
    end;

    if (ammo_item_name) then
      -- TODO: Rewrite this to use "swap" primitive.

      -- Move up to 'ammo_move_magazine_count' ammo magazines into the turret.
      local got = car_inv.remove{name=ammo_item_name, count=ammo_move_magazine_count};
      if (got < 1) then
        diag(1, "Failed to remove ammo from trunk!");
      else
        local put = turret_inv.insert{name=ammo_item_name, count=got};
        if (put < 1) then
          diag(1, "Failed to add ammo to turret!");
        else
          diag(2, "Loaded " .. put ..
               " ammo magazines of type " .. ammo_item_name ..
               " into turret of unit " .. controller.entity.unit_number .. ".");

          if (put < got) then
            -- We could not fit all of the ammo into the turret.  Put the
            -- remainder back into the car inventory.  This can happen if
            -- 'ammo_move_magazine_count' is set to something larger than
            -- one ammo stack.  I don't think that is possible with vanilla
            -- ammo though.
            local remainder = got - put;
            local putback = car_inv.insert{name=ammo_item_name, count=remainder};
            if (putback ~= remainder) then
              -- I could spill the extras onto the ground, but this
              -- should be impossible (since I just removed the items
              -- from the inventory, so there is space).
              diag(1, "WARNING: Tried to return " .. remainder ..
                      " items of type " .. ammo_item_name ..
                      " to unit " .. controller.entity.unit_number ..
                      ", but only " .. putback ..
                      " were returned, thus destroying " .. (remainder-putback) ..
                      " items!");
            else
              diag(2, "Returned " .. remainder .. " items to the vehicle inventory.");
            end;
          end;
        end;
      end;
    end;
  end;
end;

-- Predict how long it will take for particles at p1 and p2,
-- moving with velocities v1 and v2, to come within 'dist'
-- units of each other ("contact").  Also return an angle,
-- in radians, from p2 at the moment of contact to the contact
-- point.  If they will not come that close, ticks is nil.
-- If they are already within 'dist', ticks is 0.  In either of
-- those cases, the returned angle is the current p2 to p1 angle.
local function predict_approach(p1, v1, p2, v2, dist)
  -- Move p1 to the origin.
  p2 = subtract_vec(p2, p1);
  local mag_sq_p2 = mag_sq(p2);
  if (mag_sq_p2 < 0.000001) then
    -- Already on top of each other.
    return 0, 0;
  end;

  -- Current angle from p2 to p1.
  local angle_p2_to_p1 = math.atan2(-p2.y, -p2.x);

  if (mag_sq_p2 < dist*dist) then
    -- Already in contact.
    return 0, angle_p2_to_p1;
  end;

  -- Compute movement of p2 relative to p1.
  v2 = subtract_vec(v2, v1);

  if (mag_sq(v2) < 0.000001) then
    -- Not moving relative to each other, will not be in contact.
    return nil, angle_p2_to_p1;
  end;

  -- Rotate the system so the velocity (v) is pointing East (+x),
  -- obtaining a new point (p) that is the rotated location of p2.
  local v2angle = vector_to_angle(v2);
  local v = rotate_vec(v2, -v2angle);
  local p = rotate_vec(p2, -v2angle);

  if (p.x > 0) then
    -- Moving in same direction as displacement, so the
    -- separation distance will only increase.
    return nil, angle_p2_to_p1;
  end;

  -- Compute the vertical separation at contact.  This is the sine
  -- of the contact angle from p1 to p2, in the rotated frame.
  local s = math.abs(p.y);
  if (s > dist) then
    -- No contact.
    return nil, angle_p2_to_p1;
  end;

  -- Call the rotated p1p2 contact angle theta.  It is always
  -- in the second or third quadrant, since p2 is approaching
  -- from the left, hence the angle complement with pi.
  local theta = math.pi - math.asin(s / dist);
  if (p.y < 0) then
    theta = -theta;
  end;

  -- From that, compute the horizontal separation at contact,
  -- which is negative due to theta's quadrant.
  local c = math.cos(theta) * dist;

  -- Distance from p2 to contact point is current horizontal
  -- separation minus that at contact.
  local distance_to_contact = -p.x + c;

  -- Divide by speed to get ticks.
  local ticks = distance_to_contact / v.x;

  -- Finally, the p2 to p1 contact angle is 180 opposite to p1p2,
  -- then we have to undo the earlier rotation.
  local angle = normalize_radians(theta + math.pi + v2angle);

  return ticks, angle;
end;

-- Return flags describing what is necessary for 'controller.entity'
-- to avoid colliding with one of the 'force_controllers', which are
-- associated with all entities with the same force.  'controller' is
-- known to be controlling a robotank entity and 'unit_number' is its
-- unit number.
--
-- This function and its callees form the inner loop of this mod,
-- where 70% of time is spent.
local function collision_avoidance(tick, force_controllers, unit_number, controller)
  local cannot_turn = false;
  local must_brake = false;
  local cannot_accelerate = false;

  -- Hoist several quantities out of the loops below.  This significantly
  -- improves speed, in part (I think) because crossing into C++ to get
  -- attributes of C++ objects is slow.
  local v = controller.entity;
  local v_position = v.position;
  local v_velocity = vehicle_velocity(v);
  local v_orientation = v.orientation;
  local v_speed = v.speed;

  -- PERFORMANCE TESTING MODE:
  -- When I am doing performance testing, I want to disable the nearby
  -- controller refresh because it causes the per-tick time to have a
  -- lot of noise.  I also want all controllers to be included so that
  -- too is eliminated as a source of measurement variability.
  --[[
  if (unit_number_to_nearby_controllers[unit_number] == nil) then
    unit_number_to_nearby_controllers[unit_number] = {};
    for _, other in pairs(force_controllers) do
      if (other.entity ~= v) then
        table.insert(unit_number_to_nearby_controllers[unit_number], other);
      end;
    end;
  end;
  --]]

  -- NORMAL MODE:
  -- Periodically refresh the list of other entities near enough
  -- to this one to be considered by the per-tick collision analysis.
  ---[[
  if (unit_number_to_nearby_controllers[unit_number] == nil or (tick % 60 == 0)) then
    unit_number_to_nearby_controllers[unit_number] = {};
    for _, other in pairs(force_controllers) do
      if (other.entity ~= v) then
        -- The other entity is considered nearby if it is or will be
        -- within a certain, relatively large, distance before we next
        -- refresh the list of nearby entities.
        local approach_ticks, approach_angle = predict_approach(
          other.entity.position,
          entity_velocity(other.entity),
          v_position,
          v_velocity,
          20);
        if (approach_ticks ~= nil and approach_ticks < 60) then
          table.insert(unit_number_to_nearby_controllers[unit_number], other);
        end;
      end;
    end;
  end;
  --]]

  -- Scan nearby entities for collision potential.
  for _, other in ipairs(unit_number_to_nearby_controllers[unit_number]) do
    -- Are we too close to turn?
    local other_entity_position = other.entity.position;
    local dist_sq = mag_sq_subtract_vec(other_entity_position, v_position);
    if (dist_sq < 11.5) then      -- about 3.4 squared
      cannot_turn = true;
    end;

    -- At current velocities, how long (how many ticks) until we come
    -- within 4 units of the other unit, and in which direction would
    -- contact occur?
    local approach_ticks, approach_angle = predict_approach(
      other_entity_position,
      entity_velocity(other.entity),
      v_position,
      v_velocity,
      4);
    local approach_orientation = radians_to_orientation(approach_angle);
    local abs_orient_diff = absolute_orientation_difference(approach_orientation, v_orientation);
    if (approach_ticks ~= nil and abs_orient_diff <= 0.25) then
      -- Contact would occur in front, so if it is imminent, then we
      -- need to slow down.
      if (approach_ticks < v_speed * 1000) then
        must_brake = true;
      elseif (approach_ticks < (v_speed + 0.02) * 2000) then     -- speed+0.02: Presumed effect of acceleration.
        cannot_accelerate = true;
      end;
    end;

    --[[
    if ((tick % 10 == 0) and (other.entity.type ~= "car" or other.entity.get_driver() == nil)) then
      log("" .. controller.entity.unit_number ..
          " approaching " .. other.entity.unit_number ..
          ": dist=" .. math.sqrt(dist_sq) ..
          " ticks=" .. serpent.line(approach_ticks) ..
          " angle=" .. serpent.line(approach_angle) ..
          --" approach_orientation=" .. serpent.line(approach_orientation) ..
          " adorient=" .. serpent.line(abs_orient_diff) ..
          " speed=" .. v.speed ..
          " cannot_turn=" .. serpent.line(cannot_turn) ..
          " must_brake=" .. serpent.line(must_brake) ..
          " cannot_accelerate=" .. serpent.line(cannot_accelerate));
    end;
    --]]
  end;

  return cannot_turn, must_brake, cannot_accelerate;
end;

-- Is it safe for vehicle 'v' to reverse out of a stuck position?
local function can_reverse(tick, unit_number, controller)
  -- Hoist some variables.
  local v = controller.entity;
  local v_position = v.position;
  local v_velocity_if_speed = vehicle_velocity_if_speed(v, -0.1);
  local v_orientation = v.orientation;

  for _, other in ipairs(unit_number_to_nearby_controllers[unit_number]) do
    -- With this vehicle reversing at a nominal velocity, and the
    -- other entity at its current velocity, how long until we come
    -- close, and in which direction would contact occur?
    local approach_ticks, approach_angle = predict_approach(
      other.entity.position,
      entity_velocity(other.entity),
      v_position,
      v_velocity_if_speed,
      4);
    local approach_orientation = radians_to_orientation(approach_angle);
    local abs_orient_diff = absolute_orientation_difference(approach_orientation, v_orientation);
    if (approach_ticks ~= nil and abs_orient_diff > 0.25) then
      -- Contact would occur in back; is it soon?
      if (approach_ticks < 100) then
        if (tick % 60 == 0) then
          diag(4, "Vehicle " .. v.unit_number ..
                  " cannot reverse because it would hit entity " ..
                  other.entity.unit_number ..
                  " at abs_orient_diff " .. abs_orient_diff ..
                  " in " .. approach_ticks .. " ticks.");
        end;
        return false;
      end;
    end;
  end;

  return true;
end;


-- Given a commander vehicle and a robotank vehicle, where the robotank
-- is joining the commander's squad, determine the position of the
-- robotank vehicle relative to the commander.  That will become its
-- position in the formation.
local function world_position_to_formation_position(commander_vehicle, vehicle)
  local offset = subtract_vec(vehicle.position, commander_vehicle.position);
  local commander_angle = orientation_to_radians(commander_vehicle.orientation);

  -- Rotate *against* the commander when we first join.
  return rotate_vec(offset, -commander_angle);
end;


-- Given a commander vehicle and a formation position relative to that
-- commander, calculate the proper world position for a robotank with
-- that formation position.
local function formation_position_to_world_position(commander_vehicle, formation_position)
  local commander_angle = orientation_to_radians(commander_vehicle.orientation);

  -- Rotate *with* the commander when part of the squad.
  return add_vec(commander_vehicle.position, rotate_vec(formation_position, commander_angle));
end;


-- Tell the robotank vehicle associated with 'controller' how to drive.
-- This means setting its 'riding_state', which is basically programmatic
-- control of what the player can do with the WASD keys.  This is only
-- called when we know there is a commander.
--
-- 85% of time in this mod is spent in this function and its callees (of
-- which the bulk is 'collision_avoidance').
local function drive_vehicle(tick, force_controllers, commander_vehicle,
                             commander_velocity, unit_number, controller)
  local v = controller.entity;

  -- Number of ticks between invocations of the driving algorithm.
  -- We are deciding what to do for this many ticks.
  local DRIVE_FREQUENCY = 5;

  -- If our desired speed is below this, conclude we are at the
  -- destination.
  local LOW_DESIRED_SPEED = 0.0013;

  if (tick % DRIVE_FREQUENCY ~= 0) then
    -- Not driving on this tick.  But we might be completing a small turn.
    if (controller.small_turn_ticks ~= nil) then
      controller.small_turn_ticks = controller.small_turn_ticks - 1;
      if (controller.small_turn_ticks == 0) then
        -- Finished making a small turn, straighten the wheel.
        v.riding_state = {
          acceleration = v.riding_state.acceleration,
          direction = defines.riding.direction.straight,
        };
        controller.small_turn_ticks = nil;
      end;
    end;

    -- And/or could be completing a limited duration acceleration.
    if (controller.short_acceleration_ticks ~= nil) then
      controller.short_acceleration_ticks = controller.short_acceleration_ticks - 1;
      if (controller.short_acceleration_ticks == 0) then
        -- Stop accelerating.
        v.riding_state = {
          acceleration = defines.riding.acceleration.nothing,
          direction = v.riding_state.direction,
        };
        controller.short_acceleration_ticks = nil;
      end;
    end;

    return;
  end;

  if (controller.formation_position == nil) then
    -- This robotank is joining the formation.
    controller.formation_position =
      world_position_to_formation_position(commander_vehicle, v);
  end;

  -- Skip driving any tank that has a driver so it is possible for
  -- a player to jump in a robotank and help it get unstuck, or to
  -- use it for emergency escape if the player's tank gets destroyed.
  -- (The automatic turret will be disabled temporarily; see
  -- on_player_driving_changed_state.)
  if (v.get_driver() ~= nil) then
    return;
  end;

  -- Where does this vehicle want to be?
  local desired_position =
    formation_position_to_world_position(commander_vehicle, controller.formation_position);

  -- Calculate the displacement between where we are now and where
  -- we want to be.
  local displacement = subtract_vec(desired_position, v.position);

  -- The overall goal here is to decide how to accelerate and turn.
  -- We will put the decision into these two variables.
  local pedal = defines.riding.acceleration.nothing;
  local turn = defines.riding.direction.straight;

  -- Current vehicle velocity.
  local cur_velocity = vehicle_velocity(v);

  -- What will the displacement be if we stand still and the commander
  -- maintains speed and direction for LOOKAHEAD ticks?
  local LOOKAHEAD = 100;
  local next_disp = add_vec(displacement, multiply_vec(commander_velocity, LOOKAHEAD));

  -- The desired velocity is that which will bring the displacement
  -- to zero in LOOKAHEAD ticks.
  local desired_velocity = multiply_vec(next_disp, 1 / LOOKAHEAD);
  local desired_speed = magnitude(desired_velocity);

  -- Copy vehicle speed into a local for better performance.
  local v_speed = v.speed;

  if (desired_speed < LOW_DESIRED_SPEED) then
    -- Regard this as a desire to stop.
    if (v_speed > 0) then
      pedal = defines.riding.acceleration.braking;
    else
      -- We are stopped and pedal is already 'nothing'.
    end;

  else
    -- Compute orientation in [0,1].
    local desired_orientation = vector_to_orientation(desired_velocity);

    -- Difference with current orientation, in [-0.5, 0.5].
    local orient_diff = orientation_difference(v.orientation, desired_orientation);
    if (orient_diff > 0.25) then
      -- Brake and turn left.
      pedal = defines.riding.acceleration.braking;
      turn = defines.riding.direction.left;
    elseif (orient_diff > 0.1) then
      -- Coast and turn left.
      turn = defines.riding.direction.left;
    elseif (orient_diff < -0.25) then
      -- Brake and turn right.
      pedal = defines.riding.acceleration.braking;
      turn = defines.riding.direction.right;
    elseif (orient_diff < -0.1) then
      -- Coast and turn right.
      turn = defines.riding.direction.right;
    else
      -- This number comes from the tank's data definition.  It is the
      -- change in orientation per tick when turning.
      local ROTATION_RATE = 0.0035;

      -- Turn if we're not quite in line, but avoid oversteering.
      if (orient_diff > ROTATION_RATE * DRIVE_FREQUENCY) then
        turn = defines.riding.direction.left;
      elseif (orient_diff > ROTATION_RATE) then
        turn = defines.riding.direction.left;
        controller.small_turn_ticks = math.floor(orient_diff / ROTATION_RATE);
      elseif (orient_diff < -(ROTATION_RATE * DRIVE_FREQUENCY)) then
        turn = defines.riding.direction.right;
      elseif (orient_diff < -ROTATION_RATE) then
        turn = defines.riding.direction.right;
        controller.small_turn_ticks = math.floor(orient_diff / -ROTATION_RATE);
      end;

      -- Decide whether to accelerate, coast, or brake.
      if (desired_speed > v_speed) then
        if (desired_speed < 0.05) then
          -- At low speed, we need to avoid overshooting.  From my
          -- experiments, at low speed, the tank accelerates at a rate
          -- of about 0.01 per tick.
          local accel_ticks = math.floor((desired_speed - v_speed) / 0.01);
          if (v_speed == 0 and accel_ticks == 0) then
            -- If not moving at all, force acceleration for one tick.
            accel_ticks = 1;
          end;

          diag(4, "low speed vehicle " .. unit_number ..
                  ": desired_speed=" .. desired_speed ..
                  " v_speed=" .. v_speed ..
                  " accel_ticks=" .. accel_ticks);

          if (accel_ticks == 0) then
            -- Coast.
          else
            -- Accelerate.
            pedal = defines.riding.acceleration.accelerating;
            if (accel_ticks < DRIVE_FREQUENCY) then
              -- Accelerate for a limited number of ticks, then coast.
              controller.short_acceleration_ticks = accel_ticks;
            end;
          end;
        else
          -- At high speed, we accelerate slowly enough that it should
          -- suffice to take actions for DRIVE_FREQUENCY ticks.
          pedal = defines.riding.acceleration.accelerating;
        end;
      elseif (desired_speed < v_speed - 0.001) then
        pedal = defines.riding.acceleration.braking;
      end;
    end;
  end;

  -- Having decided what we would want to do in the absence of
  -- obstacles, restrict behavior in order to avoid collisions.
  local cannot_turn, must_brake, cannot_accelerate =
    collision_avoidance(tick, force_controllers, unit_number, controller);

  -- Are we reversing out of a stuck position?  That overrides the
  -- decisions made above.
  local reversing = false;
  local stopping = false;
  if (controller.reversing_until ~= nil) then
    reversing = true;
    if (controller.reversing_until > tick) then
      -- Continue reversing.
    else
      if (v_speed ~= 0) then
        -- Brake until we are stopped.
        stopping = true;
      else
        -- We have come to a stop, we can leave this state.
        diag(2, "Vehicle " .. unit_number .. " finished reversing.");
        controller.reversing_until = nil;
      end;
    end;
  end;

  --[[
  if (tick % 60 == 0) then
    log("Vehicle " .. unit_number ..
        ": cannot_turn=" .. serpent.line(cannot_turn) ..
        " must_brake=" .. serpent.line(must_brake) ..
        " cannot_accelerate=" .. serpent.line(cannot_accelerate) ..
        " reversing=" .. serpent.line(reversing) ..
        " stopping=" .. serpent.line(stopping));
  end;
  --]]

  -- Are we stuck?  This tests for low speed rather than zero speed
  -- because when a tank is stuck against water, it has a speed of
  -- about 0.003 once every 300 ticks (coincidentally the same as my
  -- stuck timer duration), even though it is not moving.  I think that
  -- is an artifact of Factorio collision mechanics.
  if (desired_speed < LOW_DESIRED_SPEED) then
    -- At destination, not stuck.
    controller.stuck_since = nil;
    controller.stuck_orientation = nil;
    controller.reversing_until = nil;
  elseif (math.abs(v_speed) < 0.005 and not reversing) then
    if (controller.stuck_since == nil) then
      -- Just became stuck, wait a bit to see if things clear up.
      -- We might not even really be stuck; speed sometimes drops
      -- quite low even when cruising.
      controller.stuck_since = tick;
      controller.stuck_orientation = v.orientation;
    elseif (controller.stuck_since + 300 <= tick) then
      -- Have been stuck for a while.  Periodically check if we
      -- can safely reverse out of here.
      if (tick % 60 == 0) then
        -- Double-check that we really are stuck by comparing the
        -- orientation.
        local orient_diff =
          absolute_orientation_difference(controller.stuck_orientation, v.orientation);
        if (orient_diff > 0.01) then
          -- We have successfully turned since becoming stopped, so
          -- we are not really stuck.  Reset the reference orientation
          -- and wait another 60 ticks.
          diag(2, "Vehicle " .. unit_number .. " is stopped but turning, so not really stuck.");
          controller.stuck_orientation = v.orientation;
        elseif (can_reverse(tick, unit_number, controller)) then
          diag(2, "Vehicle " .. unit_number .. " is stuck, trying to reverse out of it.");
          controller.stuck_since = nil;
          controller.stuck_orientation = nil;
          controller.reversing_until = tick + 60;
          reversing = true;
        else
          -- Log something periodically, but avoid spamming.
          local s = math.floor((tick - controller.stuck_since) / 60);
          if (s == 5 or
              s == 30 or
              s == 60 or
              s == 300 or
              (s >= 600 and (s % 600) == 0)) then   -- every 10 minutes
            diag(2, "For " .. s ..
                    " seconds, vehicle " .. unit_number ..
                    " has been stuck and cannot reverse.");
          end;
        end;
      end;
    end;
  else
    -- Moving or reversing, not stuck.
    controller.stuck_since = nil;
    controller.stuck_orientation = nil;
  end;

  -- Apply the collision and stuck avoidance flags to the driving
  -- controls, overriding the ordinary navigation decisions.
  if (reversing) then
    turn = defines.riding.direction.straight;
    if (stopping) then
      pedal = defines.riding.acceleration.braking;
    else
      pedal = defines.riding.acceleration.reversing;
    end;

  else
    if (must_brake) then
      pedal = defines.riding.acceleration.braking;
    elseif (cannot_accelerate and pedal == defines.riding.acceleration.accelerating) then
      pedal = defines.riding.acceleration.nothing;
    end;

    if (cannot_turn) then
      turn = defines.riding.direction.straight;
    end;
  end;

  -- Apply the desired controls to the vehicle.
  v.riding_state = {
    acceleration = pedal,
    direction = turn,
  };

  --[[
  if (tick % 60 == 0) then
    local pedal_string = riding_acceleration_string_table[pedal];
    local turn_string = riding_direction_string_table[turn];
    log("Vehicle " .. unit_number ..
        ": pedal=" .. pedal_string ..
        " turn=" .. turn_string ..
        " speed=" .. v_speed);
  end;
  --]]
end;

-- Find the current commander of 'player_index' and deal with changes.
local function refresh_commander(player_index, pi_controllers)
  -- Get the old commander so I can detect changes.
  local old_cc = storage.player_index_to_commander_controller[player_index];

  -- Find the new commander.
  local new_cc = find_commander_controller(pi_controllers);

  if (new_cc ~= old_cc) then
    storage.player_index_to_commander_controller[player_index] = new_cc;
    if (new_cc == nil) then
      diag(2, "Player index " .. player_index .. " lost its commander.");

      -- Reset driving controls and formation positions.
      for unit_number, controller in pairs(pi_controllers) do
        if (controller.entity.name == "robotank-entity") then
          controller.entity.riding_state = {
            acceleration = defines.riding.acceleration.nothing,
            direction = defines.riding.direction.straight,
          };
          controller.formation_position = nil;
        end;
      end;
    elseif (old_cc == nil) then
      diag(2, "Player index " .. player_index .. " gained a commander: unit " .. new_cc.entity.unit_number);
      diag(3, "Commander vehicle: " .. serpent.block(entity_info(new_cc.entity)));
    else
      -- TODO: This is not handled very well.  For example,
      -- we do not update formation positions.  (Should we?)
      diag(2, "Player index " .. player_index .. " changed commander to unit " .. new_cc.entity.unit_number);
    end;
  end;
end;

-- The entity associated with this controller is going away or has
-- already done so.  Remove the turret if it is still valid, then
-- remove the controller from all data structures.  Beware that the
-- entity may be invalid here.
remove_entity_controller = function(controller)
  -- Destroy turret.
  if (controller.turret ~= nil and controller.turret.valid) then
    controller.turret.destroy();
    controller.turret = nil;
  end;

  -- Remove references from 'force_to_controllers'.  Since the entity
  -- might not be valid, we resort to the slow method of scanning all
  -- player indices.  (At some call sites I know the force, and/or that
  -- the entity is valid, but I choose to make this as general as
  -- possible despite the performance cost.)
  for force, force_controllers in pairs(storage.force_to_controllers) do
    for unit_number, other in pairs(force_controllers) do
      if (other == controller) then
        force_controllers[unit_number] = nil;
        diag(3, "Entity " .. unit_number .. " removed from force->controllers table.");
      else
        -- Refresh the nearby entities since the removed one might
        -- be in that list.  We only do this for the force->controllers
        -- loop, not PI->controllers, because the scope of nearby units
        -- is the force.
        unit_number_to_nearby_controllers[unit_number] = nil;
      end;
    end;
  end;

  -- Remove references from 'player_index_to_controllers'.
  for player_index, pi_controllers in pairs(storage.player_index_to_controllers) do
    for unit_number, other in pairs(pi_controllers) do
      if (other == controller) then
        pi_controllers[unit_number] = nil;
        diag(3, "Entity " .. unit_number .. " removed from PI->controllers table.");
      end;
    end;

    -- Check commander.
    if (storage.player_index_to_commander_controller[player_index] == controller) then
      refresh_commander(player_index, pi_controllers);
    end;
  end;
end;

-- Remove from our tables any references to invalid entities.
--
-- Normally, entity removal is handled through events, but I want
-- a backup procedure now that I am also tracking player characters
-- since I don't fully understand their lifecycle.
remove_invalid_entities = function()
  for force, force_controllers in pairs(storage.force_to_controllers) do
    for unit_number, controller in pairs(force_controllers) do
      if (not controller.entity.valid) then
        diag(3, "Removing invalid entity " .. unit_number .. ".");
        remove_entity_controller(controller);
      end;
    end;
  end;

  for player_index, controller in pairs(storage.player_index_to_commander_controller) do
    if (not controller.entity.valid) then
      -- This can only happen if somehow the commander was not among
      -- the controllers scanned in the loop above, since if it was,
      -- it would already have been removed from the commander table
      -- as well.
      diag(3, "Removing invalid commander of player_index " .. player_index .. ".");
      remove_entity_controller(controller);
    end;
  end;
end;


-- Do all per-tick updates for a player index.
--
-- This function does a lot of different things because the cost of
-- simply iterating through the tables is fairly high, so for speed
-- I combine everything I can into one iteration.
--
-- NOTE: On entry to this function, it may be that 'pi_controllers' has
-- references to invalid vehicles due to the actions of other mods,
-- so we have to be careful.  I choose not to fully scan the tables
-- on every tick due to the performance impact of that.
local function update_robotank_player_index_on_tick(tick, player_index, pi_controllers)
  --- Some useful tick frequencies.
  local tick_1 = true;
  local tick_5 = ((tick % 5) == 0);
  local tick_ammo_check = ((tick % ammo_check_period_ticks) == 0);
  local tick_10 = ((tick % 10) == 0);
  local tick_60 = ((tick % 60) == 0);

  -- Refresh the commander periodically.
  if (tick_60) then
    refresh_commander(player_index, pi_controllers);
  end;

  -- Check if the player index has a commander.
  local commander_controller = storage.player_index_to_commander_controller[player_index];
  local has_commander = (commander_controller ~= nil);

  -- True if we should do certain checks.  Reduce frequency when there
  -- is no commander.
  local check_turret_damage = (has_commander and tick_5 or tick_60);
  local check_speed =         (has_commander and tick_1 or tick_10);
  local check_ammo =          (has_commander and tick_ammo_check or tick_60);
  local check_driving =       (has_commander and tick_1 or false);
  if (not (check_turret_damage or check_speed or check_ammo or check_driving)) then
    return;
  end;

  -- Hoist a couple of variables out of the driving routine.
  local commander_vehicle = nil;
  local commander_velocity = nil;
  if (check_driving) then
    driving_commander_vehicle = commander_controller.entity;

    -- Double-check that the commander vehicle is valid.
    if (driving_commander_vehicle ~= nil and
        not driving_commander_vehicle.valid) then
      diag(2, "on_tick: Commander vehicle is invalid!");
      remove_entity_controller(commander_controller);
      commander_controller = nil;
      has_commander = false;
      driving_commander_vehicle = nil;
    else
      driving_commander_velocity = vehicle_velocity(driving_commander_vehicle);
    end;
  end;

  -- Iterate over robotanks to perform maintenance on them.
  for unit_number, controller in pairs(pi_controllers) do
    if (controller.turret ~= nil) then
      local removed_vehicle = false;

      -- Double-check vehicle validity.
      if (not controller.entity.valid) then
        diag(2, "on_tick: Vehicle " .. unit_number .. " is invalid!");
        remove_entity_controller(controller);
        removed_vehicle = true;

      -- Transfer non-fatal damage sustained by the turret to the tank.
      elseif (check_turret_damage) then
        local max_health = game.entity_prototypes[controller.turret.name].max_health;
        local damage = max_health - controller.turret.health;
        if (damage > 0) then
          local entity_health = controller.entity.health;
          if (entity_health <= damage) then
            diag(2, "Fatal damage being transferred to robotank " .. unit_number .. ".");
            controller.turret.destroy();
            controller.entity.die();       -- Destroy game object and make an explosion.
            removed_vehicle = true;        -- Skip turret maintenance.

            -- The die() call will fire the on_entity_died event,
            -- whose handler will remove the controller from the
            -- tables.  So, let's just confirm that here.
            assert(pi_controllers[unit_number] == nil);
          else
            if (log_all_damage) then
              log("Transferring " .. damage ..
                  " damage to vehicle " .. unit_number ..
                  " from its turret.");
            end;
            controller.entity.health = entity_health - damage;
            controller.turret.health = max_health;
          end;
        end;
      end;

      if (not removed_vehicle) then
        -- Keep the turret centered on the tank.  If this is not done
        -- on every tick then the ammo overlay shown when detailed
        -- view is on will jiggle as the tank moves.  In addition, there
        -- is a risk of not moving the turret before the tank completely
        -- stops, for example because it hits a wall.  That said, when
        -- there is no commander, I do it less frequently and simply
        -- accept the problems since just iterating and checking the
        -- speed has measurable cost.
        if (check_speed) then
          local moved = (controller.entity.speed ~= 0);

          if (tick_60 and not moved) then
            -- If the vehicle is on a transport belt, its speed is zero
            -- but it still moves.  So, check for movement by comparing
            -- positions too, but less frequently.
            moved = not equal_vec(controller.turret.position, controller.entity.position);
          end;

          if (moved) then
            -- In my main performance test case with 40 tanks, once the
            -- squad is moving, about 10% of the time in the mod is spent
            -- in this line of code, teleporting turrets.
            if (not controller.turret.teleport(controller.entity.position)) then
              diag(1, "Failed to teleport turret!");
            end;
          end;
        end;

        if (has_commander and controller.turret.active) then
          -- Match vehicle turret orientation to the hidden turret.
          --
          -- This has to be done on every tick, since otherwise the vehicle
          -- turret tries to return to its default position, causing
          -- oscillation as the two effects fight.
          --
          -- I disable this when there is no commander because the logic
          -- above causes this code to only run every 5 ticks with no
          -- commander.  The turret is still active without a commander,
          -- and therefore can fire in a direction different from the
          -- visible vehicle turret, but I accept that minor infidelity.
          --
          -- I would like to be able to detect when the hidden turret
          -- "folds" itself due to inactivity, and in that case slave the
          -- hidden turret to the visible turret, but I do not know of any
          -- way to detect turret inactivity.
          --
          -- Around 10% of run time is spent doing this on a large map with
          -- 40 tanks and a commander.
          controller.entity.relative_turret_orientation =
            normalize_orientation(controller.turret.orientation -
                                  controller.entity.orientation);
        end;

        -- Replenish turret ammo.
        if (check_ammo) then
          maybe_load_robotank_turret_ammo(controller);
        end;

        -- Adjust driving controls.
        if (check_driving) then
          -- Once we know the commander for a player_index, driving
          -- considers all entities with the same force so that allies
          -- will coordinate regarding not running into each other.
          local force_controllers =
            storage.force_to_controllers[force_of_entity(controller.entity)];
          drive_vehicle(tick, force_controllers, driving_commander_vehicle,
            driving_commander_velocity, unit_number, controller);
        end;
      end;
    end;
  end;
end;

-- This is called either when we start a brand new game, or when we
-- load a map that previously did not have RoboTank enabled.  In
-- either case, we are transitioning from a storage state in which
-- RoboTank was absent to one where it is present.
script.on_init(function()
  diag(3, "RoboTank on_init called.");

  -- When I originally wrote
  -- the mod, I was confused about initialization events, so ended up
  -- putting it all into on_tick.  But that fails for the case of
  -- loading a game that had been used for multiplayer, and in which
  -- one of the other players was inside a vehicle when the game was
  -- saved.  (In that case, when the map is loaded, we get events
  -- saying the player has left the vehicle before any on_tick.)
  --
  -- There is also the consideration of the map editor, where on_tick
  -- never runs at all.
  must_initialize_loaded_storage_data = false;
  initialize_loaded_storage_data();
end);

-- This is called when we load a map that previously had RoboTank.
-- According to the docs, there is a very limited set of actions that
-- can be performed here, none of which seem to apply to this mod:
-- https://lua-api.factorio.com/latest/classes/LuaBootstrap.html#on_load
script.on_load(function()
  diag(3, "RoboTank on_load called.");
end);

script.on_event(defines.events.on_tick, function(e)
  if (must_rescan_world) then
    if (must_initialize_loaded_storage_data) then
      diag(3, "RoboTank: running first tick initialization on tick " .. e.tick);
      must_initialize_loaded_storage_data = false;
      initialize_loaded_storage_data();
    end;

    diag(3, "RoboTank: rescanning world");
    must_rescan_world = false;
    remove_invalid_entities();
    find_unassociated_entities();
  end;

  -- For each player index, update the robotanks.
  for player_index, pi_controllers in pairs(storage.player_index_to_controllers) do
    update_robotank_player_index_on_tick(e.tick, player_index, pi_controllers);
  end;

  -- Possibly check invariants.
  if ((e.tick % 600) == 0) then
    -- This is not currently very expensive to run.  Even if run on
    -- every tick, the cost of the mod merely doubles.  But I will
    -- run it infrequently anyway.
    check_or_fix_invariants();
  end;

  -- This is something I manually enable when I want to force the
  -- invariant repair code to run.
  --if ((e.tick % 600) == 0) then
  --  reset_storage_data();
  --end;
end);

script.on_configuration_changed(
  function(ccd)
    if (must_initialize_loaded_storage_data) then
      diag(3, "RoboTank: on_configuration_changed: " .. serpent.block(ccd));

      -- This is necessary because we need our tables updated sooner
      -- than it happens via on_tick.  (Doing it in on_tick at all is
      -- a mistake that I have yet to fully correct.)
      diag(2, "RoboTank: on_configuration_changed: initializing storage data");
      must_initialize_loaded_storage_data = false;
      initialize_loaded_storage_data();
    end;
  end
);

-- On built entity: add to tables.
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
  function(e)
    local ent = e.created_entity;
    if (ent.type == "car") then
      add_entity(ent);
    end;
  end
);

-- Robots cannot currently mine vehicles, but I trigger on the robot
-- mined event anyway in case the game changes to allow that.
script.on_event({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity},
  function(e)
    if (e.entity.type == "car") then
      diag(2, "Player or robot mined vehicle " .. e.entity.unit_number .. ".");

      local controller = find_entity_controller(e.entity);
      if (controller) then
        if (controller.turret ~= nil) then
          -- When we pick up a robotank, also grab any unused ammo in
          -- the turret entity so it is not lost.
          local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
          if (turret_inv) then
            -- TODO: Use swap instead.
            local res = copy_inventory_from_to(turret_inv, e.buffer);
            diag(2, "Grabbed " .. res .. " items from the turret before it was destroyed.");
          end;
        end;

        remove_entity_controller(controller);
      else
        -- I am supposed to be keeping track of all vehicles by keeping
        -- track of the on_built event (which happens normally when the
        -- player puts the vehicle down into the world).  But mods can
        -- create vehicles without placing them, leading to this code.
        diag(2, "But the vehicle was not in my tables.");
      end;
    end;
  end
);


-- Evidently, when this is called, the entity is still valid.
--
-- However, if the entity is a player character, it has already been
-- disassociated from the player, so its player_index is -1.
script.on_event({defines.events.on_entity_died},
  function(e)
    if (e.entity.type == "car" or e.entity.name == "character") then
      diag(2, "Vehicle or character " .. e.entity.unit_number .. " died.");

      local controller = find_entity_controller(e.entity);
      if (controller) then
        remove_entity_controller(controller);
      else
        -- I am supposed to be keeping track of all vehicles and
        -- characters, but might miss some due to mods.
        diag(2, "But the vehicle or character was not in my tables.");
      end;

    elseif (is_robotank_turret_entity_name(e.entity.name)) then
      -- Normally this should not happen because the turret has 1000 HP
      -- and any damage it takes is quickly transferred to the tank, with
      -- the turret's health being then restored to full.  But it is
      -- conceivable (perhaps with mods) that something does 1000 damage
      -- in a short time, which will lead to this code running.
      diag(2, "A robotank turret was killed directly!");

      -- Find and remove the controller of the vehicle with this turret.
      local force = force_of_entity(e.entity);
      for unit_number, controller in pairs(storage.force_to_controllers[force]) do
        if (controller.turret == e.entity) then
          diag(2, "Killing the turret's owner, vehicle " .. unit_number .. ".");
          controller.entity.die();
          break;
        end;
      end;
    end;
  end
);


-- Called when an event fires that might change the set of player
-- characters in the world.  I say "might" because I do not understand
-- the lifecycle.
local function on_players_changed()
  diag(2, "RoboTank: on_players_changed");

  -- At this point, a removed character entity is not invalid yet.  We
  -- need to wait for the start of the next tick to detect that it is
  -- invalid.
  --
  -- Note that the scan is quite slow, so I only want to do this for
  -- things that are infrequent.
  must_rescan_world = true;
end;

script.on_event(
  {
    -- Events that seem like they might be relevant.
    defines.events.on_player_changed_surface,
    defines.events.on_player_created,
    defines.events.on_player_died,
    defines.events.on_player_joined_game,
    defines.events.on_player_left_game,
    defines.events.on_player_removed,
    defines.events.on_player_respawned,
  },
  on_players_changed);


local function on_player_driving_changed_state(event)
  diag(3, "RoboTank: on_player_driving_changed_state: index=" .. event.player_index);

  local character = game.players[event.player_index].character;
  if (character ~= nil) then
    if (character.vehicle ~= nil) then
      diag(2, "Player character " .. character.unit_number ..
              " has entered vehicle " .. character.vehicle.unit_number .. ".");

      local controller = find_entity_controller(character.vehicle);
      if (controller ~= nil and controller.turret ~= nil) then
        -- If the player jumps into a robotank, disable its turret.
        -- That prevents a minor exploit where both the turret and
        -- the player-controlled tank machine gun could fire, thus
        -- effectively doubling the firepower of one vehicle.
        diag(2, "Disabling turret of vehicle " .. controller.entity.unit_number .. ".");
        controller.turret.active = false;
      end;
    else
      diag(2, "Player character " .. character.unit_number ..
              " has exited a vehicle.");

      -- If I load my mod in a game where the player character is inside
      -- a vehicle, the initial scan does not see it, presumably because
      -- it is not considered to be on the surface.  So, I wait until the
      -- player jumps out and then I can make a controller for the
      -- character entity.
      find_or_create_entity_controller(character);

      -- Re-activate any disabled turrets.
      local pi_controllers = storage.player_index_to_controllers[event.player_index];
      if (pi_controllers == nil) then
        -- I do not know how this happens.  'character' is obtained by
        -- lookup in game.players[].  But if its player index matched
        -- event.player_index, then find_or_create should have already
        -- populated the PITC table.  And yet I have a bug report showing
        -- this can happen.  So I guess just ignore the event?
        diag(1, "pi_controllers is nil? " ..
             " event.player_index=" .. event.player_index ..
             " char_pi=" .. player_index_of_entity(character));
        return;
      end;
      for unit_number, controller in pairs(pi_controllers) do
        if (controller.turret ~= nil and
            controller.turret.active == false and
            controller.entity.get_driver() == nil) then
          diag(2, "Re-enabling turret of vehicle " .. controller.entity.unit_number .. ".");
          controller.turret.active = true;
        end;
      end;
    end;
  end;
end;

script.on_event({defines.events.on_player_driving_changed_state},
  on_player_driving_changed_state);


-- Experimental addition so I can see damage effects.
if (log_all_damage) then
  script.on_event({defines.events.on_entity_damaged},
    function(event)
      if (event.entity ~= nil) then
        local attacker = "nil";
        if (event.cause ~= nil and event.cause.unit_number ~= nil) then
          attacker = "{num=" .. event.cause.unit_number ..
                     " name=" .. event.cause.name .. "}";
        end;
        -- The unit number is nil for things like trees.  'tostring'
        -- allows printing 'nil'.
        log("Entity num=" .. tostring(event.entity.unit_number) ..
            " type=" .. event.entity.type ..
            " name=" .. event.entity.name ..
            " took " .. event.final_damage_amount ..
            " damage of type " .. event.damage_type.name ..
            " from attacker=" .. attacker ..
            ".");
      end;
    end
  );
end;


----------------------------- Test code ------------------------------

-- Return true if two floating-point values (or nil) are almost equal.
local function almost_equal(x, y)
  if (x == nil and y == nil) then
    return true;
  elseif (x == nil or y == nil) then
    return false;
  else
    return math.abs(x-y) < 1e-10;
  end;
end;

-- Test a single input to 'predict_approach'.
local function test_one_predict_approach(p1, v1, p2, v2, dist,
    expect_ticks, expect_angle)
  local actual_ticks, actual_angle = predict_approach(p1, v1, p2, v2, dist);
  if (not (almost_equal(actual_ticks, expect_ticks) and
           almost_equal(actual_angle, expect_angle))) then
    print("predict approach failed:");
    print("  p1: " .. serpent.line(p1));
    print("  v1: " .. serpent.line(v1));
    print("  p2: " .. serpent.line(p2));
    print("  v2: " .. serpent.line(v2));
    print("  dist: " .. dist);
    print("  expect_ticks: " .. serpent.line(expect_ticks));
    print("  actual_ticks: " .. serpent.line(actual_ticks));
    print("  expect_angle: " .. serpent.line(expect_angle));
    print("  actual_angle: " .. serpent.line(actual_angle));
    error("failed test");
  end;
end;

-- Test an input to 'predict_approach' and a couple simple variations.
local function test_multi_predict_approach(p1, v1, p2, v2, dist,
    expect_ticks, expect_angle)
  -- Original test.
  test_one_predict_approach(p1, v1, p2, v2, dist, expect_ticks, expect_angle);

  -- Offsetting the positions by the same amount should not affect anything.
  local ofs = {x=1, y=1};
  test_one_predict_approach(add_vec(p1,ofs), v1, add_vec(p2,ofs), v2, dist,
    expect_ticks, expect_angle);

  -- Similarly for adding the same value to both velocities.
  test_one_predict_approach(p1, add_vec(v1,ofs), p2, add_vec(v2,ofs), dist,
    expect_ticks, expect_angle);

  -- And for rotating the entire system, except that the angle changes
  -- unless the points are coincident.
  local angle = math.pi / 2;
  local expect_angle_factor = (equal_vec(p1, p2) and 0 or 1);
  test_one_predict_approach(
    rotate_vec(p1, angle),
    rotate_vec(v1, angle),
    rotate_vec(p2, angle),
    rotate_vec(v2, angle),
    dist, expect_ticks, expect_angle + angle * expect_angle_factor);
  angle = math.pi / 4;
  test_one_predict_approach(
    rotate_vec(p1, angle),
    rotate_vec(v1, angle),
    rotate_vec(p2, angle),
    rotate_vec(v2, angle),
    dist, expect_ticks, expect_angle + angle * expect_angle_factor);

end;

local function test_predict_approach()
  local v0 = {x=0, y=0};

  -- On top of each other: contact already, no useful angle.
  test_multi_predict_approach(
    v0,
    v0,
    v0,
    v0,
    1,
    0,
    0);

  -- On top but with relative velocity: same thing.
  test_multi_predict_approach(
    v0,
    v0,
    v0,
    {x=1,y=1},
    1,
    0,
    0);

  -- Within contact distance but with non-trivial angle.
  test_multi_predict_approach(
    {x=1, y=1},
    v0,
    v0,
    v0,
    2,
    0,
    math.pi / 4);

  -- Approaching along a tangent.
  test_multi_predict_approach(
    v0,
    v0,
    {x=-4, y=1},
    {x=1, y=0},
    1,
    4,
    - math.pi / 2);

  -- Non-degenrate intersection, contact angle 45 degrees.
  test_multi_predict_approach(
    v0,
    v0,
    {x=-4, y = 1 / math.sqrt(2)},
    {x=1, y=0},
    1,
    4 - 1 / math.sqrt(2),
    - math.pi / 4);

  -- Same except v1 in opposite direction so no intersection.
  test_multi_predict_approach(
    v0,
    v0,
    {x=-4, y = 1 / math.sqrt(2)},
    {x=-1, y=0},
    1,
    nil,
    math.atan2(-1 / math.sqrt(2), 4));

  -- Intersection case but mirrored horizontally.
  test_multi_predict_approach(
    v0,
    v0,
    {x=4, y = 1 / math.sqrt(2)},
    {x=-1, y=0},
    1,
    4 - 1 / math.sqrt(2),
    - 3 * math.pi / 4);

  -- p1 is too high so it misses by a fair bit.
  test_multi_predict_approach(
    v0,
    v0,
    {x=-4, y = 2},
    {x=1, y=0},
    1,
    nil,
    math.atan2(-2, 4));

  -- Non-degenrate intersection but p2 has negative y.
  test_multi_predict_approach(
    v0,
    v0,
    {x=-4, y = - 1 / math.sqrt(2)},
    {x=1, y=0},
    1,
    4 - 1 / math.sqrt(2),
    math.pi / 4);

  print("test_predict_approach passed");
end;


-- Unit tests, meant to be run using the stand-alone Lua interpreter.
-- See unit-tests.sh.
function unit_tests()
  print("Running unit tests for RoboTank control.lua ...");
  test_predict_approach();
  print("RoboTank unit tests passed");
end;


-- EOF
