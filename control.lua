-- RoboTank control.lua
-- Actions that run while the user is playing the game.

require "util"             -- table.deepcopy
require "lua_util"         -- add_vec, etc.
require "factorio_util"    -- vehicle_velocity, etc.


script.on_init(function()
  log("RoboTank on_init called.");
end);

script.on_load(function()
  log("RoboTank on_load called.");
end);

-- True when we need to examine the global data just loaded to
-- upgrade or validate it.
local must_initialize_loaded_global_data = true;

-- True when, on the next tick, we need to rescan the world to check
-- for consistency with our data structures.
local must_rescan_world = true;

-- Structure of 'global' is {
--   -- Data version number, bumped when I make a change that requires
--   -- special handling.
--   data_version = 3;
--
--   -- Map from force to its controllers.  Each force's controllers
--   -- are a map from unit_number to its entity_controller object.
--   force_to_controllers = {};
--
--   -- Map from force to its commander vehicle controller, if there is
--   -- such a commander.
--   force_to_commander_controller = {};
-- };

-- Control state for an entity that is relevant to this mod.  All
-- vehicles and player character entities have controller objects,
-- although we only "control" robotanks.
local function new_entity_controller(e)
  return {
    -- Reference to the Factorio entity we are controlling.  This is
    -- either a vehicle (type=="car") or player character
    -- (name=="player").
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

    -- Array of other entity controllers (on the same force) that are
    -- near enough to this one to be relevant for collision avoidance.
    -- When this is nil, it needs to be recomputed.
    nearby_controllers = nil,

    -- When this is non-nil, it is the number of ticks for which we
    -- want to keep turning, after which we will straighten the wheel.
    -- This is useful because, for speed, the driving algorithm does
    -- not run on every tick, but we still want to be able to turn
    -- for as little as one tick.  One reason why is, in a tightly
    -- packed formation of tanks, crude steering leads to unnecessary
    -- mutual interference as the tanks drift into each other.
    small_turn_ticks = nil,
  };
end;

-- Add an entity to our table and return its controller.
local function add_entity(e)
  local force_name = string_or_name_of(e.force);
  global.force_to_controllers[force_name] = global.force_to_controllers[force_name] or {}
  local controller = new_entity_controller(e);
  global.force_to_controllers[force_name][e.unit_number] = controller;

  if (e.name == "robotank-entity") then
    -- Is there already an associated turret here?
    local p = controller.entity.position;
    local candidates = e.surface.find_entities_filtered{
      area = {{p.x-0.5, p.y-0.5}, {p.x+0.5, p.y+0.5}},
      name = "robotank-turret-entity"
    };
    if (#candidates > 0) then
      controller.turret = candidates[1];
      log("Found existing turret with unit number " .. controller.turret.unit_number .. ".");
    else
      controller.turret = e.surface.create_entity{
        name = "robotank-turret-entity",
        position = controller.entity.position,
        force = e.force};
      if (controller.turret) then
        log("Made new turret.");
      else
        -- This unfortunately is not recoverable because I do not check
        -- for a nil turret elsewhere, both for simplicity of logic and
        -- speed of execution.
        error("Failed to create turret for robotank!");
      end;
    end;
  end;

  log("Entity " .. e.unit_number ..
      " with name " .. e.name ..
      " at (" .. e.position.x .. "," .. e.position.y .. ")" ..
      " added to force " .. force_name);

  return controller;
end;

-- Find the controller object associated with the given entity, if any.
local function find_entity_controller(entity)
  local controllers = global.force_to_controllers[string_or_name_of(entity.force)];
  if (controllers) then
    return controllers[entity.unit_number];
  else
    return nil;
  end;
end;


-- The mod just started running.  Some data may or may not have been
-- loaded from 'global' (depending on whether the mod was previously
-- part of the game, and what version it was if so).  Make sure it is
-- properly initialized.
local function initialize_loaded_global_data()
  log("Loaded data_version: " .. serpent.line(global.data_version));

  if (global.data_version == 1) then
    log("RoboTank: Upgrading data_version 1 to 2.");

    -- I renamed "force_to_vehicles" to "force_to_controllers".
    global.force_to_controllers = global.force_to_vehicles;
    global.force_to_vehicles = nil;

    -- I also renamed "nearby_vehicles" to "nearby_controllers".
    if (global.force_to_controllers ~= nil) then
      for _, controllers in pairs(global.force_to_controllers) do
        for _, controller in pairs(controllers) do
          controller.nearby_controllers = controller.nearby_vehicles;
          controller.nearby_vehicles = nil;
        end;
      end;
    end;
    global.data_version = 2;
  end;

  if (global.data_version == 2) then
    log("RoboTank: Upgrading data_version 2 to 3.");

    -- I renamed "vehicle" to "entity".
    if (global.force_to_controllers ~= nil) then
      for _, controllers in pairs(global.force_to_controllers) do
        for _, controller in pairs(controllers) do
          controller.entity = controller.vehicle;
          controller.vehicle = nil;
        end;
      end;
    end;
  end;

  global.data_version = 3;

  if (global.force_to_commander_controller == nil) then
    log("force_to_commander_controller was nil, setting it to empty.");
    global.force_to_commander_controller = {};
  else
    log("force_to_commander_controller has " ..
        table_size(global.force_to_commander_controller) .. " entries.");
  end;

  if (global.force_to_controllers == nil) then
    log("force_to_controllers was nil, setting it to empty.");
    global.force_to_controllers = {};
  else
    log("force_to_controllers has " ..
        table_size(global.force_to_controllers) .. " entries.");
    for force, controllers in pairs(global.force_to_controllers) do
      log("  force \"" .. force .. "\" has " ..
          table_size(controllers) .. " controllers.");
    end;
  end;
end;


-- If there is already a controller for 'entity', return it.  Otherwise,
-- make a new controller and return that.
local function find_or_create_entity_controller(entity)
  local controller = find_entity_controller(entity);
  if (controller ~= nil) then
    log("Found existing controller object for unit " .. entity.unit_number);
  else
    log("Unit number " .. entity.unit_number ..
        " has no controller, making a new one.");
    controller = add_entity(entity);
  end;
  return controller;
end;


-- Called during 'find_unassociated_entities' when one is found.
local function found_an_entity(e, turrets)
  --log("found entity: " .. serpent.block(entity_info(e)));

  -- See if we already know about this entity.
  local controller = find_or_create_entity_controller(e);

  if (controller.turret ~= nil) then
    -- This turret is now accounted for (it might have existed before,
    -- or it might have just been created by 'add_entity').
    turrets[controller.turret.unit_number] = nil;
  end;
end;


-- Scan the world for entities that should be tracked in my data
-- structures but are not.  They are then either added to my tables
-- or deleted from the world.
local function find_unassociated_entities()
  -- Scan the surface for all of our hidden turrets so that later we
  -- can get rid of any not associated with a vehicle.
  local turrets = {};
  for _, t in ipairs(game.surfaces[1].find_entities_filtered{name="robotank-turret-entity"}) do
    turrets[t.unit_number] = t;
  end;

  -- Add all vehicles to 'force_to_controllers' table.
  for _, v in ipairs(game.surfaces[1].find_entities_filtered{type = "car"}) do
    found_an_entity(v, turrets);
  end;

  -- And player characters, mainly so we can avoid running them over
  -- when driving the robotanks.
  for _, player in ipairs(game.surfaces[1].find_entities_filtered{name = "player"}) do
    found_an_entity(player, turrets);
  end;

  -- Destroy any unassociated turrets.  There should never be any, but
  -- this will catch things that might be left behind due to a bug in
  -- my code.
  for unit_number, t in pairs(turrets) do
    log("WARNING: Should not happen: destroying unassociated turret " .. unit_number);
    t.destroy();
  end;
end;


-- Find the vehicle controller among 'controllers' that is commanding
-- them, if any.
local function find_commander_controller(controllers)
  for unit_number, controller in pairs(controllers) do
    local v = controller.entity;
    -- A robotank cannot be a commander.
    if (v.name ~= "robotank") then
      -- It must have the transmitter item in its trunk.  (This
      -- implicitly excludes player characters from being commanders.
      -- I might change that at some point.)
      local inv = v.get_inventory(defines.inventory.car_trunk);
      if (inv and inv.get_item_count("robotank-transmitter-item") > 0) then
        --log("Commander vehicle is unit " .. v.unit_number);
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
    log("Failed to get turret inventory!");
    return;
  end;

  -- For speed, I only look at the inventory if it is completely empty.
  -- That means there is periodically a frame during which the turret
  -- ammo is empty, so the turret stops firing and shows the no-ammo icon
  -- briefly.
  if (turret_inv.is_empty()) then
    -- Check the vehicle's ammo slot.  The robotank vehicle ammo is not
    -- otherwise used, but I still check it because when I shift-click to
    -- put ammo into the robotank, the ammo slot gets populated first.
    local car_inv = controller.entity.get_inventory(defines.inventory.car_ammo);
    if (not car_inv) then
      log("Failed to get car_ammo inventory!");
      return;
    end;
    local ammo_type = get_insertable_item(car_inv, turret_inv);
    if (not ammo_type) then
      -- Try the trunk.
      car_inv = controller.entity.get_inventory(defines.inventory.car_trunk);
      if (not car_inv) then
        log("Failed to get car_trunk inventory!");
        return;
      end;
      ammo_type = get_insertable_item(car_inv, turret_inv);
    end;

    if (ammo_type) then
      -- Move up to 50 ammo magazines into the turret.  I originally
      -- had this as 10 to match the usual way that inserters load
      -- turrets, but then I reduced the frequency of the reload check
      -- to once per 5 ticks, so I want a correspondingly bigger buffer
      -- here.
      local got = car_inv.remove{name=ammo_type, count=50};
      if (got < 1) then
        log("Failed to remove ammo from trunk!");
      else
        local put = turret_inv.insert{name=ammo_type, count=got};
        if (put < 1) then
          log("Failed to add ammo to turret!");
        else
          log("Loaded " .. put .. " ammo magazines of type: " .. ammo_type);
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
-- to avoid colliding with one of the 'controllers'.  'controller' is
-- known to be controlling a robotank entity.
--
-- This function and its callees form the inner loop of this mod,
-- where 70% of time is spent.
local function collision_avoidance(tick, controllers, controller)
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
  if (controller.nearby_controllers == nil) then
    controller.nearby_controllers = {};
    for _, other in pairs(controllers) do
      if (other.entity ~= v) then
        table.insert(controller.nearby_controllers, other);
      end;
    end;
  end;
  --]]

  -- NORMAL MODE:
  -- Periodically refresh the list of other entities near enough
  -- to this one to be considered by the per-tick collision analysis.
  ---[[
  if (controller.nearby_controllers == nil or (tick % 60 == 0)) then
    controller.nearby_controllers = {};
    for _, other in pairs(controllers) do
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
          table.insert(controller.nearby_controllers, other);
        end;
      end;
    end;
  end;
  --]]

  -- Scan nearby entities for collision potential.
  for _, other in ipairs(controller.nearby_controllers) do
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
    if ((tick % 10 == 0) and (other.entity.type ~= "car" or other.entity.passenger == nil)) then
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
local function can_reverse(tick, controller)
  -- Hoist some variables.
  local v = controller.entity;
  local v_position = v.position;
  local v_velocity_if_speed = vehicle_velocity_if_speed(v, -0.1);
  local v_orientation = v.orientation;

  for _, other in ipairs(controller.nearby_controllers) do
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
          log("Vehicle " .. v.unit_number ..
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
-- 85% of time in this mod is spent in this function and its callees.
local function drive_vehicle(tick, controllers, commander_vehicle,
                             commander_velocity, unit_number, controller)
  local v = controller.entity;

  -- Number of ticks between invocations of the driving algorithm.
  -- We are deciding what to do for this many ticks.
  local DRIVE_FREQUENCY = 5;

  if (tick % DRIVE_FREQUENCY ~= 0) then
    -- Not driving on this tick.  But we might be completing a small turn.
    if (controller.small_turn_ticks ~= nil) then
      controller.small_turn_ticks = controller.small_turn_ticks - 1;
      if (controller.small_turn_ticks == 0) then
        -- Finished making a small turn, straighten the wheel.
        v.riding_state = {
          acceleration = v.riding_state.acceleration,
          direction = defines.riding.direction.straight;
        };
        controller.small_turn_ticks = nil;
      end;
    end;
    return;
  end;

  if (controller.formation_position == nil) then
    -- This robotank is joining the formation.
    controller.formation_position =
      world_position_to_formation_position(commander_vehicle, v);
  end;

  -- Skip driving any tank that has a passenger so it is possible for
  -- a player to jump in a robotank and help it get unstuck.  (The
  -- automatic turret will be disabled temporarily; see
  -- on_player_driving_changed_state.)
  if (v.passenger ~= nil) then
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

  if (desired_speed < 0.001) then
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
    if (orient_diff > 0.1) then
      -- Coast and turn left.
      turn = defines.riding.direction.left;
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
        pedal = defines.riding.acceleration.accelerating;
      elseif (desired_speed < v_speed - 0.001) then
        pedal = defines.riding.acceleration.braking;
      end;
    end;
  end;

  -- Having decided what we would want to do in the absence of
  -- obstacles, restrict behavior in order to avoid collisions.
  local cannot_turn, must_brake, cannot_accelerate =
    collision_avoidance(tick, controllers, controller);

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
        log("Vehicle " .. unit_number .. " finished reversing.");
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
  if (desired_speed < 0.001) then
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
          log("Vehicle " .. unit_number .. " is stopped but turning, so not really stuck.");
          controller.stuck_orientation = v.orientation;
        elseif (can_reverse(tick, controller)) then
          log("Vehicle " .. unit_number .. " is stuck, trying to reverse out of it.");
          controller.stuck_since = nil;
          controller.stuck_orientation = nil;
          controller.reversing_until = tick + 60;
          reversing = true;
        else
          log("Vehicle " .. unit_number .. " is stuck and cannot reverse.");
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

-- Find the current commander of 'force' and deal with changes.
local function refresh_commander(force, controllers)
  -- Get the old commander so I can detect changes.
  local old_cc = global.force_to_commander_controller[force];

  -- Find the new commander.
  local new_cc = find_commander_controller(controllers);

  if (new_cc ~= old_cc) then
    global.force_to_commander_controller[force] = new_cc;
    if (new_cc == nil) then
      log("Force " .. force .. " lost its commander.");

      -- Reset driving controls and formation positions.
      for unit_number, controller in pairs(controllers) do
        if (controller.entity.name == "robotank-entity") then
          controller.entity.riding_state = {
            acceleration = defines.riding.acceleration.nothing,
            direction = defines.riding.direction.straight,
          };
          controller.formation_position = nil;
        end;
      end;
    elseif (old_cc == nil) then
      log("Force " .. force .. " gained a commander: unit " .. new_cc.entity.unit_number);
    else
      -- TODO: This is not handled very well.  For example,
      -- we do not update formation positions.  (Should we?)
      log("Force " .. force .. " changed commander to unit " .. new_cc.entity.unit_number);
    end;
  end;
end;

-- The entity associated with this controller is going away or has
-- already done so.  Remove the turret if it is still valid, then
-- remove the controller from all data structures.  Beware that the
-- entity may be invalid here.
local function remove_entity_controller(force, controller)
  -- Make sure 'force' is a string since that is what my table use.
  local force = string_or_name_of(force);

  -- Destroy turret.
  if (controller.turret ~= nil and controller.turret.valid) then
    controller.turret.destroy();
    controller.turret = nil;
  end;

  -- Remove references in the main table.
  local controllers = global.force_to_controllers[force];
  for unit_number, other in pairs(controllers) do
    if (other == controller) then
      -- Remove the controller from the main table.
      controllers[unit_number] = nil;
      log("Entity " .. unit_number .. " removed from controllers table.");
    else
      -- Refresh the nearby entities since the removed one might
      -- be in that list.
      other.nearby_controllers = nil;
    end;
  end;

  -- Check commander.
  if (global.force_to_commander_controller[force] == controller) then
    refresh_commander(force, controllers);
  end;
end;

-- Remove from our tables for any references to invalid entities.
--
-- Normally, entity removal is handled through events, but I want
-- a backup procedure now that I am also tracking player characters
-- since I don't fully understand their lifecycle.
local function remove_invalid_entities()
  for force, controllers in pairs(global.force_to_controllers) do
    for unit_number, controller in pairs(controllers) do
      if (not controller.entity.valid) then
        log("Removing invalid entity " .. unit_number .. ".");
        remove_entity_controller(force, controller);
      end;
    end;
  end;

  for force, controller in pairs(global.force_to_commander_controller) do
    if (not controller.entity.valid) then
      -- This can only happen if somehow the commander was not among
      -- the controllers scanned in the loop above, since if it was,
      -- it would already have been removed from the commander table
      -- as well.
      log("Removing invalid commander of force \"" .. force .. "\".");
      remove_entity_controller(force, controller);
    end;
  end;
end;


-- Do all per-tick updates for an entire force.
--
-- This function does a lot of different things because the cost of
-- simply iterating through the tables is fairly high, so for speed
-- I combine everything I can into one iteration.
local function update_robotank_force_on_tick(tick, force, controllers)
  --- Some useful tick frequencies.
  local tick_1 = true;
  local tick_5 = ((tick % 5) == 0);
  local tick_10 = ((tick % 10) == 0);
  local tick_60 = ((tick % 60) == 0);

  -- Refresh the commander periodically.
  if (tick_60) then
    refresh_commander(force, controllers);
  end;

  -- Check if the force has a commander.
  local commander_controller = global.force_to_commander_controller[force];
  local has_commander = (commander_controller ~= nil);

  -- True if we should do certain checks.  Reduce frequency when there
  -- is no commander.
  local check_turret_damage = (has_commander and tick_5 or tick_60);
  local check_speed =         (has_commander and tick_1 or tick_10);
  local check_ammo =          (has_commander and tick_5 or tick_60);
  local check_driving =       (has_commander and tick_1 or false);
  if (not (check_turret_damage or check_speed or check_ammo or check_driving)) then
    return;
  end;

  -- Hoist a couple of variables out of the driving routine.
  local commander_vehicle = nil;
  local commander_velocity = nil;
  if (check_driving) then
    driving_commander_vehicle = commander_controller.entity;
    driving_commander_velocity = vehicle_velocity(driving_commander_vehicle);
  end;

  -- Iterate over robotanks to perform maintenance on them.
  local removed_vehicle = false;
  for unit_number, controller in pairs(controllers) do
    if (controller.turret ~= nil) then
      -- Transfer non-fatal damage sustained by the turret to the tank.
      -- The max health must match what is in data.lua.
      if (check_turret_damage) then
        local damage = 1000 - controller.turret.health;
        if (damage > 0) then
          if (controller.entity.health <= damage) then
            log("Fatal damage being transferred to robotank " .. unit_number .. ".");
            controller.turret.destroy();
            controller.entity.die();       -- Destroy game object and make an explosion.
            removed_vehicle = true;        -- Skip turret maintenance.

            -- The die() call will fire the on_entity_died event,
            -- whose handler will remove the controller from the
            -- tables.  So, let's just confirm that here.
            if (controllers[unit_number] ~= nil) then
              error("Killing the vehicle did not cause it to be removed from tables!");
            end;
          else
            controller.entity.health = controller.entity.health - damage;
            controller.turret.health = 1000;
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
            if (not controller.turret.teleport(controller.entity.position)) then
              log("Failed to teleport turret!");
            end;
          end;
        end;

        -- Replenish turret ammo.
        if (check_ammo) then
          maybe_load_robotank_turret_ammo(controller);
        end;

        -- Adjust driving controls.
        if (check_driving) then
          drive_vehicle(tick, controllers, driving_commander_vehicle,
            driving_commander_velocity, unit_number, controller);
        end;
      end;
    end;
  end;
end;

script.on_event(defines.events.on_tick, function(e)
  if (must_rescan_world) then
    if (must_initialize_loaded_global_data) then
      log("RoboTank: running first tick initialization on tick " .. e.tick);
      must_initialize_loaded_global_data = false;
      initialize_loaded_global_data();
    end;

    log("RoboTank: rescanning world");
    must_rescan_world = false;
    remove_invalid_entities();
    find_unassociated_entities();
  end;

  -- For each force, update the robotanks.
  for force, controllers in pairs(global.force_to_controllers) do
    update_robotank_force_on_tick(e.tick, force, controllers);
  end;
end);

-- On built entity: add to tables.
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
  function(e)
    local ent = e.created_entity;
    --log("RoboTank: saw built event: " .. serpent.block(entity_info(ent)));
    if (ent.type == "car") then
      local controller = add_entity(ent);
    end;
  end
);

-- Robots cannot currently mine vehicles, but I trigger on the robot
-- mined event anyway in case the game changes to allow that.
script.on_event({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity},
  function(e)
    if (e.entity.type == "car") then
      log("Player or robot mined vehicle " .. e.entity.unit_number .. ".");

      local controller = find_entity_controller(e.entity);
      if (controller) then
        if (controller.turret ~= nil) then
          -- When we pick up a robotank, also grab any unused ammo in
          -- the turret entity so it is not lost.  That doesn't matter
          -- much when cleaning up after a big battle, but it is annoying
          -- to lose ammo if I put down a robotank and then pick it up
          -- again without doing any fighting.
          local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
          if (turret_inv) then
            local res = copy_inventory_from_to(turret_inv, e.buffer);
            log("Grabbed " .. res .. " items from the turret before it was destroyed.");
          end;
        end;

        remove_entity_controller(e.entity.force, controller);
      else
        -- I am supposed to be keeping track of all vehicles.
        log("But the vehicle was not in my tables?");
      end;
    end;
  end
);


-- Evidently, when this is called, the entity is still valid.
script.on_event({defines.events.on_entity_died},
  function(e)
    if (e.entity.type == "car" or e.entity.type == "player") then
      log("Vehicle or player " .. e.entity.unit_number .. " died.");

      local controller = find_entity_controller(e.entity);
      if (controller) then
        remove_entity_controller(e.entity.force, controller);
      else
        -- I am supposed to be keeping track of all vehicles and players.
        log("But the vehicle or player was not in my tables?");
      end;

    elseif (e.entity.name == "robotank-turret-entity") then
      -- Normally this should not happen because the turret has 1000 HP
      -- and any damage it takes is quickly transferred to the tank, with
      -- the turret's health being then restored to full.  But it is
      -- conceivable (perhaps with mods) that something does 1000 damage
      -- in a short time, which will lead to this code running.
      log("A robotank turret was killed directly!");

      -- Find and remove the controller of the vehicle with this turret.
      local force = string_or_name_of(e.entity.force);
      for unit_number, controller in pairs(global.force_to_controllers[force]) do
        if (controller.turret == e.entity) then
          log("Killing the turret's owner, vehicle " .. unit_number .. ".");
          controller.entity.die();
          break;
        end;
      end;
    end;
  end
);


-- Called when an event fires that might change the set of player
-- characters in the world.  I say "might" because I do not understand
-- the lifecycle and don't have an easy way to test things like
-- multiplayer.
local function on_players_changed()
  log("RoboTank: on_players_changed");

  -- At this point, a removed player entity is not invalid yet.  We
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
  local character = game.players[event.player_index].character;
  if (character ~= nil) then
    if (character.vehicle ~= nil) then
      log("Player character " .. character.unit_number ..
          " has entered vehicle " .. character.vehicle.unit_number .. ".");

      local controller = find_entity_controller(character.vehicle);
      if (controller ~= nil and controller.turret ~= nil) then
        -- If the player jumps into a robotank, disable its turret.
        -- That prevents a minor exploit where both the turret and
        -- the player-controlled tank machine gun could fire, thus
        -- effectively doubling the firepower of one vehicle.
        log("Disabling turret of vehicle " .. controller.entity.unit_number .. ".");
        controller.turret.active = false;
      end;
    else
      log("Player character " .. character.unit_number ..
          " has exited a vehicle.");

      -- If I load my mod in a game where the player character is inside
      -- a vehicle, the initial scan does not see it, presumably because
      -- it is not considered to be on the surface.  So, I wait until the
      -- player jumps out and then I can make a controller for the
      -- character entity.
      find_or_create_entity_controller(character);

      -- Re-activate any disabled turrets.
      local controllers = global.force_to_controllers[string_or_name_of(character.force)];
      for unit_number, controller in pairs(controllers) do
        if (controller.turret ~= nil and
            controller.turret.active == false and
            controller.entity.passenger == nil) then
          log("Re-enabling turret of vehicle " .. controller.entity.unit_number .. ".");
          controller.turret.active = true;
        end;
      end;
    end;
  end;
end;

script.on_event({defines.events.on_player_driving_changed_state},
  on_player_driving_changed_state);


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
