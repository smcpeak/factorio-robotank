-- VehicleLeash control.lua
-- Actions that run while the user is playing the game.

require "util"             -- table.deepcopy
require "lua_util"         -- add_vec, etc.
require "factorio_util"    -- vehicle_velocity, etc.


script.on_init(function()
  log("VehicleLeash on_init called.");
end);

script.on_load(function()
  log("VehicleLeash on_load called.");
end);

-- True once we have scanned the world for vehicles after loading.
local found_vehicles = false;

-- When this is true, an invalid vehicle has been recently removed,
-- so we have to refresh the lists of nearby vehicles.
local nearby_vehicles_requires_refresh = false;

-- Map from force to its vehicles.  Each force's vehicles are a map
-- from unit_number to its vehicle_controller object.
local force_to_vehicles = {};

-- Control state for a vehicle.  All vehicles have control states,
-- including the commander vehicle (if any).
local function new_vehicle_controller(v)
  return {
    -- Reference to the Factorio vehicle entity we are controlling.
    vehicle = v,

    -- Associated turret entity that does the shooting.
    turret = nil,

    -- If this is a robotank that has a commander, this is an {x,y}
    -- position that this robotank should go to in its formation,
    -- relative to the commander, when the commander is facing East.
    formation_position = nil;

    -- Vehicle's position during the previous tick.
    previous_position = v.position,

    -- When not nil, this records the tick number when the vehicle
    -- became stuck, prevented from going the way it wants to by
    -- some obstacles.  If we are stuck long enough, the vehicle
    -- will try to reverse out.
    stuck_since = nil,

    -- When not nil, the vehicle has decided to reverse out of its
    -- current position until the indicated tick count.  When that
    -- tick passes, the vehicle will first brake until it is stopped,
    -- then clear the field and resume normal driving.
    reversing_until = nil,

    -- Array of other vehicles (on the same force) that are near
    -- enough to this one to be relevant for collision avoidance.
    nearby_vehicles = {},
  };
end;

-- Add a vehicle to our table and return its controller.
local function add_vehicle(v)
  local force_name = string_or_name_of(v.force);
  force_to_vehicles[force_name] = force_to_vehicles[force_name] or {}
  local controller = new_vehicle_controller(v);
  force_to_vehicles[force_name][v.unit_number] = controller;

  if (v.name == "robotank-entity") then
    -- Is there already an associated turret here?
    local p = controller.vehicle.position;
    local candidates = v.surface.find_entities_filtered{
      area = {{p.x-0.5, p.y-0.5}, {p.x+0.5, p.y+0.5}},
      --position = p,
      name = "robotank-turret-entity"
    };
    if (#candidates > 0) then
      controller.turret = candidates[1];
      log("Found existing turret with unit number " .. controller.turret.unit_number .. ".");

      -- Strangely, I have a saved game where if I try to find the turret
      -- by exact position, it fails, yet the reported position afterward
      -- is identical.  So I find using a small area instead.
      --log("Vehicle position: " .. serpent.line(p));
      --log("Turret position: " .. serpent.line(controller.turret.position));
      --log("Positions are equal: " .. (equal_vec(p, controller.turret.position) and "yes" or "no"));
    else
      controller.turret = v.surface.create_entity{
        name = "robotank-turret-entity",
        position = controller.vehicle.position,
        force = v.force};
      if (controller.turret) then
        log("Made new turret.");
      else
        log("Failed to create turret!");
      end;
    end;
  end;

  log("Vehicle " .. v.unit_number ..
      " with name " .. v.name ..
      " at (" .. v.position.x .. "," .. v.position.y .. ")" ..
      " added to force " .. force_name);

  return controller;
end;

-- Find the controller object associated with the given vehicle, if any.
local function find_robotank_controller(vehicle)
  local controllers = force_to_vehicles[string_or_name_of(vehicle.force)];
  if (controllers) then
    return controllers[vehicle.unit_number];
  else
    return nil;
  end;
end;

-- Scan the world for vehicles.
local function find_vehicles()
  log("VehicleLeash: find_vehicles");

  -- Scan the surface for all of our hidden turrets so that later we
  -- can get rid of any not associated with a vehicle.
  local turrets = {};
  for _, t in ipairs(game.surfaces[1].find_entities_filtered{name="robotank-turret-entity"}) do
    turrets[t.unit_number] = t;
  end;

  -- Add all vehicles to 'force_to_vehicles' table.
  for _, v in ipairs(game.surfaces[1].find_entities_filtered{type = "car"}) do
    --log("found vehicle: " .. serpent.block(entity_info(v)));
    local controller = add_vehicle(v);
    if (controller.turret ~= nil) then
      -- This turret is now accounted for (it might have existed before,
      -- or it might have just been created by 'add_vehicle).
      turrets[controller.turret.unit_number] = nil;
    end;
  end;

  -- Destroy any unassociated turrets.  There should never be any, but
  -- this will catch things that might be left behind due to a bug in
  -- my code.
  for unit_number, t in pairs(turrets) do
    log("WARNING: Should not happen: destroying unassociated turret " .. unit_number);
    t.destroy();
  end;
end;

-- Remove any vehicles (or turrets) that are in the vehicle table.  Entities
-- become invalid due to being destroyed or mined.
local function remove_invalid_vehicles()
  for force, vehicles in pairs(force_to_vehicles) do
    local num_vehicles = 0;
    for unit_number, controller in pairs(vehicles) do
      if (controller.vehicle.valid) then
        if (controller.turret ~= nil and
            not controller.turret.valid) then
          -- Turret was destroyed, kill the tank too.
          log("Turret of vehicle " .. unit_number .. " destroyed, killing tank too.");
          controller.vehicle.destroy();
          vehicles[unit_number] = nil;
          nearby_vehicles_requires_refresh = true;
        else
          num_vehicles = num_vehicles + 1;
        end;
      else
        if (controller.turret ~= nil and controller.turret.valid) then
          controller.turret.destroy();
          controller.turret = nil;
          log("Removed turret from invalid vehicle.");
        end;
        vehicles[unit_number] = nil;
        nearby_vehicles_requires_refresh = true;
        log("Removed invalid vehicle " .. unit_number .. ".");
      end;
    end;
    --log("Force " .. force .. " has " .. num_vehicles .. " vehicles.");
  end;
end;

-- Find the vehicle among 'vehicles' that is commanding them, if any.
local function find_commander_vehicle(vehicles)
  for unit_number, controller in pairs(vehicles) do
    local v = controller.vehicle;
    -- A robotank cannot be a commander.
    if (v.name ~= "robotank") then
      -- It must have the leash controller item in its trunk.
      local inv = v.get_inventory(defines.inventory.car_trunk);
      if (inv and inv.get_item_count("vehicle-leash-item") > 0) then
        --log("Commander vehicle is unit " .. v.unit_number);
        return v;
      end;
    end;
  end;
  return nil;
end;

-- Return a position that is 'distance' units in front of 'ent',
-- taking accouot of its current orientation.
local function pos_in_front_of(ent, distance)
  local orient_vec = orientation_to_unit_vector(ent.orientation);
  local displacement = multiply_vec(orient_vec, distance);
  return add_vec(ent.position, displacement);
end;

-- Get the name of some bullet ammo in the given inventory,
-- or nil if there is none.  If there are multiple kinds of
-- bullet ammo available, this gets one of them arbitrarily.
-- I expect users to only put their preferred kind of ammo
-- into the tank.
local function get_bullet_ammo(inv)
  for name, count in pairs(inv.get_contents()) do
    local proto = game.item_prototypes[name];
    if (proto) then
      if (proto.type == "ammo") then
        -- I do not know what effect the argument "turret" has here.
        local ammo_type = proto.get_ammo_type("turret");
        if (ammo_type.category == "bullet") then
          return name;
        end;
      end;
    else
      log("No prototype for item: " + name);
    end;
  end;
end;

-- Try to keep the turret stocked up on ammo by taking it from the tank.
local function maybe_load_robotank_turret_ammo(controller)
  -- See if the turret needs another ammo magazine.
  local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
  if (not turret_inv) then
    log("Failed to get turret inventory!");
    return;
  end;

  -- For speed, I only look at the inventory if it is completely empty.
  -- That means there is periodically a frame during which the turret
  -- ammo is empty, so the turret stops firing and shows the no-ammo icon
  -- briefly.
  if (turret_inv.is_empty()) then
    -- Check the vehicle's ammo slot.
    local car_inv = controller.vehicle.get_inventory(defines.inventory.car_ammo);
    if (not car_inv) then
      log("Failed to get car_ammo inventory!");
      return;
    end;
    local ammo_type = get_bullet_ammo(car_inv);
    if (not ammo_type) then
      -- Try the trunk.
      car_inv = controller.vehicle.get_inventory(defines.inventory.car_trunk);
      if (not car_inv) then
        log("Failed to get car_trunk inventory!");
        return;
      end;
      ammo_type = get_bullet_ammo(car_inv);
    end;

    if (ammo_type) then
      -- Move up to 10 ammo magazines into the turret.
      local got = car_inv.remove{name=ammo_type, count=10};
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

-- Do per-tick updates of robotanks.
local function update_robotanks(tick)
  for force, vehicles in pairs(force_to_vehicles) do
    for unit_number, controller in pairs(vehicles) do
      if (controller.vehicle.name == "robotank-entity") then
        if (controller.turret ~= nil) then
          -- Transfer any damage sustained by the turret to the tank.
          -- The max health must match what is in data.lua.
          local damage = 1000 - controller.turret.health;
          if (damage > 0) then
            if (controller.vehicle.health <= damage) then
              log("Fatal damage being transferred to robotank " .. unit_number .. ".");
              controller.turret.destroy();
              controller.vehicle.die();      -- Make an explosion.
              controller.turret = nil;
              vehicles[unit_number] = nil;
              break;
            else
              controller.vehicle.health = controller.vehicle.health - damage;
              controller.turret.health = 1000;
            end;
          end;

          -- Keep the turret centered on the tank.
          if (not equal_vec(controller.vehicle.position, controller.previous_position)) then
            controller.previous_position = table.deepcopy(controller.vehicle.position);
            if (not controller.turret.teleport(controller.vehicle.position)) then
              log("Failed to teleport turret!");
            end;
          end;

          maybe_load_robotank_turret_ammo(controller);
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
  if (mag_sq(p2) < 0.000001) then
    -- Already on top of each other.
    return 0, 0;
  end;

  -- Current angle from p2 to p1.
  local angle_p2_to_p1 = math.atan2(-p2.y, -p2.x);

  if (mag_sq(p2) < dist*dist) then
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

-- Return flags describing what is necessary for 'controller.vehicle'
-- to avoid colliding with one of the 'vehicles'.
local function collision_avoidance(tick, vehicles, controller)
  local cannot_turn = false;
  local must_brake = false;
  local cannot_accelerate = false;

  local v = controller.vehicle;

  -- Periodically refresh the list of other vehicles near enough
  -- to this one to be relevant.
  if (nearby_vehicles_requires_refresh or (tick % 60 == 0)) then
    controller.nearby_vehicles = {};
    for _, other in pairs(vehicles) do
      if (other.vehicle ~= v) then
        -- Maximum distance is a baseline of 10 plus additional margin
        -- for fast moving vehicles.
        local threshold = 10 + math.abs(v.speed) * 10 + math.abs(other.vehicle.speed) * 10;
        if (mag_sq(subtract_vec(other.vehicle.position, v.position)) < threshold * threshold) then
          table.insert(controller.nearby_vehicles, other);
        end;
      end;
    end;
  end;

  -- Scan nearby vehicles for collision potential.
  for _, other in ipairs(controller.nearby_vehicles) do
    -- Are we too close to turn?
    if (mag_sq(subtract_vec(other.vehicle.position, v.position)) < 11.5) then
      cannot_turn = true;
    end;

    -- At current velocities, how long (how many ticks) until we come
    -- within 4 units of the other unit, and in which direction would
    -- contact occur?
    local approach_ticks, approach_angle = predict_approach(
      other.vehicle.position,
      vehicle_velocity(other.vehicle),
      v.position,
      vehicle_velocity(v),
      4);
    local approach_orientation = radians_to_orientation(approach_angle);
    local relative_orientation = normalize_orientation(approach_orientation - v.orientation);
    if (approach_ticks ~= nil and (relative_orientation <= 0.25 or relative_orientation >= 0.75)) then
      -- Contact would occur in front, so if it is imminent, then we
      -- need to slow down.
      if (approach_ticks < v.speed * 1000) then
        must_brake = true;
      elseif (approach_ticks < (v.speed + 0.02) * 2000) then     -- speed+0.02: Presumed effect of acceleration.
        cannot_accelerate = true;
      end;
    end;

    --[[
    if (tick % 30 == 0) then
      log("approach_ticks=" .. serpent.line(approach_ticks) ..
          " approach_angle=" .. serpent.line(approach_angle) ..
          " approach_orientation=" .. serpent.line(approach_orientation) ..
          " relative_orientation=" .. serpent.line(relative_orientation) ..
          " speed=" .. v.speed ..
          " must_brake=" .. serpent.line(must_brake) ..
          " cannot_accelerate=" .. serpent.line(cannot_accelerate));
    end;
    --]]
  end;

  return cannot_turn, must_brake, cannot_accelerate;
end;

-- Is it safe for vehicle 'v' to reverse out of a stuck position?
local function can_reverse(tick, vehicles, controller)
  local v = controller.vehicle;

  for _, other in ipairs(controller.nearby_vehicles) do
    -- With this vehicle reversing at a nominal velocity, and the
    -- other vehicle at its current velocity, how long until we come
    -- close, and in which direction would contact occur?
    local approach_ticks, approach_angle = predict_approach(
      other.vehicle.position,
      vehicle_velocity(other.vehicle),
      v.position,
      vehicle_velocity_if_speed(v, -0.1),
      4);
    local approach_orientation = radians_to_orientation(approach_angle);
    local relative_orientation = normalize_orientation(approach_orientation - v.orientation);
    if (approach_ticks ~= nil and (0.25 <= relative_orientation and relative_orientation <= 0.75)) then
      -- Contact would occur in back; is it soon?
      if (approach_ticks < 100) then
        if (tick % 60 == 0) then
          log("Vehicle " .. v.unit_number ..
              " cannot reverse because it would hit vehicle " ..
              other.vehicle.unit_number ..
              " at orientation " .. relative_orientation ..
              " in " .. approach_ticks .. " ticks.");
        end;
        return false;
      end;
    end;
  end;

  return true;
end;


-- Get the number of robotanks in 'vehicles'.
local function num_robotanks(vehicles)
  local ct = 0;
  for _, controller in pairs(vehicles) do
    if (controller.vehicle.name == "robotank-entity") then
      ct = ct + 1;
    end;
  end;
  return ct;
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


-- Tell all the robotank vehicles how to drive themselves.  This means
-- setting their 'riding_state', which is basically programmatic control
-- of what the player can do with the WASD keys.
local function drive_vehicles(tick_num)
  for force, vehicles in pairs(force_to_vehicles) do
    local commander_vehicle = find_commander_vehicle(vehicles);
    if (commander_vehicle == nil) then
      --log("Force " .. force .. " does not have a commander vehicle.");
      for unit_number, controller in pairs(vehicles) do
        if (controller.vehicle.name == "robotank-entity") then
          -- Don't let the vehicles run away when there is no commander.
          controller.vehicle.riding_state = {
            acceleration =
              ((controller.vehicle.speed ~= 0) and
                 defines.riding.acceleration.braking or
                 defines.riding.acceleration.nothing),
            direction = defines.riding.direction.straight,
          };

          -- Also clear the formation position so when a commander
          -- arrives it will be reinitialized.
          controller.formation_position = nil;
        end;
      end;
    else
      local commander_velocity = vehicle_velocity(commander_vehicle);

      for unit_number, controller in pairs(vehicles) do
        local v = controller.vehicle;
        if (v.name == "robotank-entity") then
          if (controller.formation_position == nil) then
            -- This robotank is joining the formation.
            controller.formation_position =
              world_position_to_formation_position(commander_vehicle, controller.vehicle);
          end;

          -- Where does this vehicle want to be?
          local desired_position =
            formation_position_to_world_position(commander_vehicle, controller.formation_position);

          -- Calculate the displacement between where we are now and where
          -- we want to be.
          local displacement = subtract_vec(desired_position, v.position);

          -- Goal here is to decide how to accelerate and turn.
          local pedal = defines.riding.acceleration.nothing;
          local turn = defines.riding.direction.straight;

          -- Current vehicle velocity.
          local cur_velocity = vehicle_velocity(v);

          -- What will the displacement be if we stand still and the commander
          -- maintains speed and direction?
          local next_disp = add_vec(displacement, commander_velocity);

          -- What will be the displacement in one tick if we maintain speed
          -- and direction?
          local projected_straight_disp = subtract_vec(next_disp, cur_velocity);
          local projected_straight_dist = magnitude(projected_straight_disp);
          if (projected_straight_dist < 0.1) then
            -- We are or will be close to the target position.  Is the commander
            -- stopped?  (The test here is not for commander speed is zero because
            -- if the player jumps out and lets the vehicle coast to a stop, it
            -- takes about a minute for friction to get the speed to zero, even
            -- though all visible movement stops in a few seconds.)
            if ((math.abs(commander_vehicle.speed) < 1e-3) and v.speed > 0) then
              -- Hack: Commander is stopped, we should stop too.  (I would prefer that
              -- this behavior emerge naturally without making a special case.  But as
              -- things stand, without this, the tanks will slowly circle their target
              -- endlessly if I do not force them to stop.)
              pedal = defines.riding.acceleration.braking;
            else
              -- Just coast straight.  Among the situations this applies is when
              -- the tank is in its intended spot in the formation, moving at the
              -- same speed as the commander.
            end;

            -- Since we're basically at our destination, clear the stuck
            -- avoidance variables since we're not going down the other code
            -- path for a while now.
            controller.stuck_since = nil;
            controller.reversing_until = nil;

          else
            -- Compute orientation in [0,1] that will reduce displacement.
            local desired_orientation = vector_to_orientation(projected_straight_disp);

            -- Difference with current orientation.
            local diff_orient = v.orientation - desired_orientation;
            if (diff_orient > 0.5) then
              diff_orient = diff_orient - 1;
            elseif (diff_orient < -0.5) then
              diff_orient = diff_orient + 1;
            end;

            if (diff_orient > 0.1) then
              -- Coast and turn left.
              turn = defines.riding.direction.left;
            elseif (diff_orient < -0.1) then
              -- Coast and turn right.
              turn = defines.riding.direction.right;
            else
              -- Turn if we're not quite in line, then decide whether
              -- to accelerate.
              if (diff_orient > 0.01) then
                turn = defines.riding.direction.left;
              elseif (diff_orient < -0.01) then
                turn = defines.riding.direction.right;
              end;

              -- Desired speed as a function of projected distance to target.
              -- This has a quadratic component since stopping distance does
              -- as well (although I do not explicitly calculate that).  The
              -- coefficients were determined through crude experimentation.
              local desired_speed =
                projected_straight_dist * 0.01 +
                projected_straight_dist * projected_straight_dist * 0.001;

              if (desired_speed > v.speed) then
                pedal = defines.riding.acceleration.accelerating;
              elseif (desired_speed < v.speed - 0.001) then
                pedal = defines.riding.acceleration.braking;
              end;
            end;
          end;

          -- Having decided what we would want to do in the absence of
          -- obstacles, restrict behavior in order to avoid collisions.
          local cannot_turn, must_brake, cannot_accelerate =
            collision_avoidance(tick_num, vehicles, controller);

          -- Are we reversing out of a stuck position?  That overrides the
          -- decisions made above.
          local reversing = false;
          local stopping = false;
          if (controller.reversing_until ~= nil) then
            reversing = true;
            if (controller.reversing_until > tick_num) then
              -- Continue reversing.
            else
              if (v.speed ~= 0) then
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
          if (tick_num % 60 == 0) then
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
          if (math.abs(v.speed) < 0.005 and not reversing) then
            if (controller.stuck_since == nil) then
              -- Just became stuck, wait a bit to see if things clear up.
              -- We might not even really be stuck; speed sometimes drops
              -- quite low even when cruising.
              controller.stuck_since = tick_num;
            elseif (controller.stuck_since + 300 <= tick_num) then
              -- Have been stuck for a while.  Periodically check if we
              -- can safely reverse out of here.
              if (tick_num % 60 == 0) then
                if (can_reverse(tick_num, vehicles, controller)) then
                  log("Vehicle " .. unit_number .. " is stuck, trying to reverse out of it.");
                  controller.stuck_since = nil;
                  controller.reversing_until = tick_num + 60;
                  reversing = true;
                else
                  log("Vehicle " .. unit_number .. " is stuck and cannot reverse.");
                end;
              end;
            end;
          else
            -- Not stuck, reset stuck timer.
            controller.stuck_since = nil;
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
          if (tick_num % 60 == 0) then
            local pedal_string = riding_acceleration_string_table[pedal];
            local turn_string = riding_direction_string_table[turn];
            log("Vehicle " .. unit_number ..
                ": pedal=" .. pedal_string ..
                " turn=" .. turn_string ..
                " speed=" .. v.speed);
          end;
          --]]
        end;
      end;
    end;
  end;
end;

script.on_event(defines.events.on_tick, function(e)
  -- On the very first tick after loading, initialize the vehicle table.
  if (not found_vehicles) then
    found_vehicles = true;
    find_vehicles();
  end;

  remove_invalid_vehicles();

  update_robotanks(e.tick)

  -- Recalculate driving controls on every tick.  I experimented with
  -- doing this less frequently, but even when it is done on every other
  -- tick, there is a slight but noticeable sluggishness in the response
  -- of the robotanks when I turn left and right.  So, I'll do the
  -- overall routine on every tick, but perhaps do some parts less often.
  drive_vehicles(e.tick);

  -- Clear this flag only at the end of the tick so that all of the
  -- lists get refreshed.
  nearby_vehicles_requires_refresh = false;
end);

-- On built entity: add to tables.
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
  function(e)
    local ent = e.created_entity;
    --log("VehicleLeash: saw built event: " .. serpent.block(entity_info(ent)));
    if (ent.type == "car") then
      local controller = add_vehicle(ent);
    end;
  end
);

script.on_event({defines.events.on_player_mined_entity},
  function(e)
    if (e.entity.name == "robotank-entity") then
      -- When we pick up a robotank, also grab any unused ammo in
      -- the turret entity so it is not lost.  That doesn't matter
      -- much when cleaning up after a big battle, but it is annoying
      -- to lose ammo if I put down a robotank and then pick it up
      -- again without doing any fighting.
      local controller = find_robotank_controller(e.entity);
      if (controller and controller.turret) then
        local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
        if (turret_inv) then
          local res = copy_inventory_from_to(turret_inv, e.buffer);
          log("Grabbed " .. res .. " items from the turret before it was destroyed.");
        end;
      end;
    end;
  end
);


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
  print("Running unit tests for VehicleLeash control.lua ...");
  test_predict_approach();
  print("VehicleLeash unit tests passed");
end;


-- EOF
