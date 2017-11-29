-- VehicleLeash control.lua
-- Actions that run while the user is playing the game.

require "util"               -- table.deepcopy

local function equal_vec(v1, v2)
  return v1.x == v2.x and v1.y == v2.y;
end;

-- Given something that could be a string or an object with
-- a name, yield it as a string.
local function string_or_name_of(e)
  if type(e) == "string" then
    return e;
  else
    return e.name;
  end;
end;

-- Get various entity attributes as a table that can be converted
-- to an informative string using 'serpent'.  The input object, 'e',
-- is a Lua userdata object which serpent cannot usefully print,
-- even though it otherwise appears to be a normal Lua table.
local function entity_info(e)
  return {
    name = e.name,
    type = e.type,
    active = e.active,
    health = e.health,
    position = e.position,
    --bounding_box = e.bounding_box,
    valid = e.valid,
    force = string_or_name_of(e.force),
    unit_number = e.unit_number,
  };
end;

script.on_init(function()
  log("VehicleLeash on_init called.");
end);

script.on_load(function()
  log("VehicleLeash on_load called.");
end);

-- True once we have scanned the world for vehicles after loading.
local found_vehicles = false;

-- Map from force to its vehicles.  Each force's vehicles are a map
-- from unit_number to its vehicle_controller object.
local force_to_vehicles = {};

-- Control state for a vehicle.  All vehicles have control states,
-- including the player vehicle (if any).
local function new_vehicle_controller(v)
  return {
    -- Reference to the Factorio vehicle entity we are controlling.
    vehicle = v,

    -- Associated turret entity that does the shooting.
    turret = nil,

    -- Vehicle's position during the previous tick.
    previous_position = v.position,

    -- Do not activate automatic driving until this tick.
    automatic_drive_min_tick = 0,
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

  local vehicles = game.surfaces[1].find_entities_filtered{
    type = "car",
  };
  for _, v in ipairs(vehicles) do
    --log("found vehicle: " .. serpent.block(entity_info(v)));
    add_vehicle(v);
  end;
end;

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
        log("Removed invalid vehicle " .. unit_number .. ".");
      end;
    end;
    --log("Force " .. force .. " has " .. num_vehicles .. " vehicles.");
  end;
end;

local function find_player_vehicle(vehicles)
  for unit_number, controller in pairs(vehicles) do
    local v = controller.vehicle;
    -- It must be a vehicle that the player is riding in.
    if ((v.passenger ~= nil) and (v.passenger.type == "player")) then
      -- And it must have the leash controller item in its trunk.
      local inv = v.get_inventory(defines.inventory.car_trunk);
      if (inv and inv.get_item_count("vehicle-leash-item") > 0) then
        --log("Player vehicle is unit " .. v.unit_number);
        return v;
      end;
    end;
  end;
end;

-- "Orientation" in Factor is a floating-point number in [0,1]
-- where 0 is North, 0.25 is East, 0.5 is South, and 0.75 is West.
-- Convert that to a unit vector where +x is East and +y is South.
local function orientation_to_unit_vector(orientation)
  -- Angle measured from East toward South, in radians.
  local angle = (orientation - 0.25) / 1.00 * 2.00 * math.pi;
  return {x = math.cos(angle), y = math.sin(angle)};
end;

-- Multiply a 2D vector by a scalar.
local function multiply_vec(v, scalar)
  return {x = v.x * scalar, y = v.y * scalar};
end;

-- Add two 2D vectors.
local function add_vec(v1, v2)
  return { x = v1.x + v2.x, y = v1.y + v2.y };
end;

local function pos_in_front_of(ent, distance)
  local orient_vec = orientation_to_unit_vector(ent.orientation);
  local displacement = multiply_vec(orient_vec, distance);
  return add_vec(ent.position, displacement);
end;

local function mag_sq(v)
  return v.x * v.x + v.y * v.y;
end;

local function magnitude(v)
  return math.sqrt(mag_sq(v));
end;

local function normalize_vec(v)
  if ((v.x == 0) and (v.y == 0)) then
    return v;
  else
    return multiply_vec(v, 1.0 / magnitude(v));
  end;
end;

local function subtract_vec(v1, v2)
  return { x = v1.x - v2.x, y = v1.y - v2.y };
end;

-- Given a Factorio "orientation", normalize it to [0,1).
local function normalize_orientation(o)
  while o < 0 do
    o = o + 1;
  end;
  while o >= 1 do
    o = o - 1;
  end;
  return o;
end;

-- Normalize radians to [-pi,pi).
local function normalize_radians(r)
  while r < -math.pi do
    r = r + (math.pi * 2);
  end;
  while r >= math.pi do
    r = r - (math.pi * 2);
  end;
  return r;
end;

local function vector_to_angle(v)
  -- Angle South of East, in radians.
  return math.atan2(v.y, v.x);
end;

local function orientation_to_radians(orientation)
  return (orientation - 0.25) * 2 * math.pi;
end;

-- Convert to radians in [-pi,pi] to orientation in [-0.25, 0.75].
local function radians_to_orientation(radians)
  return radians / (2 * math.pi) + 0.25;
end;

local function vector_to_orientation(v)
  local angle = vector_to_angle(v);
  local orientation = radians_to_orientation(angle);

  -- Raise to [0,1].
  orientation = normalize_orientation(orientation);

  return orientation;
end;

-- https://www.lua.org/pil/19.3.html
local function ordered_pairs (t, f)
  local a = {}
  for n in pairs(t) do table.insert(a, n) end
  table.sort(a, f)
  local i = 0      -- iterator variable
  local iter = function ()   -- iterator function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end;

-- Number of table entries.  How is this not built in to Lua?
local function table_size(t)
  local ct = 0;
  for _, _ in pairs(t) do
    ct = ct + 1;
  end;
  return ct;
end;

-- Get the velocity vector of a vehicle in meters (game units) per tick.
local function vehicle_velocity(v)
  local direction = orientation_to_unit_vector(v.orientation);
  return multiply_vec(direction, v.speed);
end;

-- Rotate a vector by a given angle.  This works for the standard coordinate
-- system with +y up and counterclockwise angles, as well as the Factorio
-- coordinate system with +y down and clockwise angles.
local function rotate_vec(v, radians)
  return {
    x = v.x * math.cos(radians) - v.y * math.sin(radians),
    y = v.x * math.sin(radians) + v.y * math.cos(radians),
  };
end;

-- Get the name of some bullet ammo in the given inventory,
-- or nil if there is none.
local function get_bullet_ammo(inv)
  for name, count in pairs(inv.get_contents()) do
    local proto = game.item_prototypes[name];
    if (proto) then
      --log("ammo type: " .. serpent.block(proto.get_ammo_type("turret")));
      if (proto.type == "ammo") then
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

local function maybe_load_robotank_turret_ammo(controller)
  -- See if the turret needs another ammo magazine.
  local turret_inv = controller.turret.get_inventory(defines.inventory.turret_ammo);
  if (not turret_inv) then
    log("Failed to get turret inventory!");
    return;
  end;
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
    for unit_number, controller in ordered_pairs(vehicles) do
      if (controller.vehicle.name == "robotank-entity") then
        if (controller.turret ~= nil) then
          -- Transfer any damage sustained by the turret to the tank.
          -- (This effectively uses the turret's resistances as those of
          -- the tank.)
          local damage = 400 - controller.turret.health;
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
              controller.turret.health = 400;
            end;
          end;

          -- Keep the turret with the tank.
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

-- Return flags describing what is necessary for 'v' to avoid colliding
-- with one of the 'vehicles'.
local function collision_avoidance(tick, vehicles, v)
  local cannot_turn = false;
  local must_brake = false;
  local cannot_accelerate = false;

  for _, controller in pairs(vehicles) do
    if (controller.vehicle ~= v) then
      -- Are we too close to turn?
      if (mag_sq(subtract_vec(controller.vehicle.position, v.position)) < 11.5) then
        cannot_turn = true;
      end;

      -- At current velocities, how long (how many ticks) until we come
      -- within 4 units of the other unit, and in which direction would
      -- contact occur?
      local approach_ticks, approach_angle = predict_approach(
        controller.vehicle.position,
        vehicle_velocity(controller.vehicle),
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
  end;

  return cannot_turn, must_brake, cannot_accelerate;
end;

local function drive_vehicles(tick_num)
  for force, vehicles in pairs(force_to_vehicles) do
    local player_vehicle = find_player_vehicle(vehicles);
    if (player_vehicle == nil) then
      --log("Force " .. force .. " does not have a player vehicle.");
      for unit_number, controller in ordered_pairs(vehicles) do
        if (controller.vehicle.name == "robotank-entity") then
          -- Don't let the vehicles run away when I jump out.
          controller.vehicle.riding_state = {
            acceleration = defines.riding.acceleration.nothing;
            direction = defines.riding.direction.straight;
          };
        end;
      end;
    else
      local player_velocity = vehicle_velocity(player_vehicle);

      -- Compute a desired slave vehicle position in front of the player vehicle.
      local desired_pos = pos_in_front_of(player_vehicle, 15);
      --log("PV is at " .. serpent.line(player_vehicle.position) ..
      --     " with orientation " .. player_vehicle.orientation ..
      --     ", desired_pos is " .. serpent.line(desired_pos));

      -- Size the formation based on the number of vehicles, assuming that
      -- one is the player vehicle.
      local formation_size = table_size(vehicles) - 1;

      -- Side-to-side offset for each additional unit.
      local lateral_vec = orientation_to_unit_vector(player_vehicle.orientation + 0.25);
      lateral_vec = multiply_vec(lateral_vec, 5);     -- 5 is the spacing.
      local lateral_fact = formation_size / 2;

      for unit_number, controller in ordered_pairs(vehicles) do
        local v = controller.vehicle;
        if (v ~= player_vehicle and
            v.name == "robotank-entity" and
            controller.automatic_drive_min_tick <= tick_num) then
          -- Calculate the displacement between where we are now and where
          -- we want to be in formation in front of the player's vehicle.
          local full_lateral = multiply_vec(lateral_vec, lateral_fact);
          lateral_fact = lateral_fact - 1;
          local displacement = subtract_vec(add_vec(desired_pos, full_lateral), v.position);

          -- Goal here is to decide how to accelerate and turn.
          local pedal = defines.riding.acceleration.nothing;
          local pedal_string = "nothing";
          local turn = defines.riding.direction.straight;
          local turn_string = "straight";

          -- Current vehicle velocity.
          local cur_velocity = vehicle_velocity(v);

          -- What will the displacement be if we stand still and the player
          -- maintains speed and direction?
          local next_disp = add_vec(displacement, player_velocity);

          -- What will be the displacement in one tick if we maintain speed
          -- and direction?
          local projected_straight_disp = subtract_vec(next_disp, cur_velocity);
          local projected_straight_dist = magnitude(projected_straight_disp);
          if (projected_straight_dist < 0.1) then
            -- We will be close to the target position.
            if ((player_vehicle.speed == 0) and v.speed > 0) then
              -- Hack: player is stopped, we should stop too.  (I would prefer that
              -- this behavior emerge naturally without making a special case.)
              pedal = defines.riding.acceleration.braking;
              pedal_string = "braking";
            else
              -- Just coast straight.
            end;

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
              turn_string = "left";
            elseif (diff_orient < -0.1) then
              -- Coast and turn right.
              turn = defines.riding.direction.right;
              turn_string = "right";
            else
              -- Turn if we're not quite in line, then decide whether
              -- to accelerate.
              if (diff_orient > 0.01) then
                turn = defines.riding.direction.left;
                turn_string = "left";
              elseif (diff_orient < -0.01) then
                turn = defines.riding.direction.right;
                turn_string = "right";
              end;

              -- Desired speed as a function of projected distance to target.
              local desired_speed =
                projected_straight_dist * 0.01 +
                projected_straight_dist * projected_straight_dist * 0.001;

              if (desired_speed > v.speed) then
                pedal = defines.riding.acceleration.accelerating;
                pedal_string = "accelerating";
              elseif (desired_speed < v.speed - 0.001) then
                pedal = defines.riding.acceleration.braking;
                pedal_string = "braking";
              end;
            end;
          end;

          -- Having decided what we want to do, restrict it in order to
          -- avoid collisions.
          local cannot_turn, must_brake, cannot_accelerate = collision_avoidance(tick_num, vehicles, v);
          --[[
          if (tick_num % 60 == 0) then
            log("cannot_turn=" .. serpent.line(cannot_turn) ..
                " must_brake=" .. serpent.line(must_brake) ..
                " cannot_accelerate=" .. serpent.line(cannot_accelerate));
          end;
          --]]
          if (must_brake) then
            pedal = defines.riding.acceleration.braking;
            pedal_string = "braking";
          elseif (cannot_accelerate and pedal == defines.riding.acceleration.accelerating) then
            pedal = defines.riding.acceleration.nothing;
            pedal_string = "nothing";
          end;

          if (cannot_turn) then
            turn = defines.riding.direction.straight;
            turn_string = "nothing";
          end;

          -- Apply the desired controls to the vehicle.
          v.riding_state = {
            acceleration = pedal,
            direction = turn,
          };

          --[[
          if (tick_num % 60 == 0) then
            log("pedal=" .. pedal_string .. ", turn=" .. turn_string);
          end;
          --]]
        end;
      end;
    end;
  end;
end;

script.on_event(defines.events.on_tick, function(e)
  if (not found_vehicles) then
    found_vehicles = true;
    find_vehicles();
  end;

  --if not ((e.tick % 30) == 0) then return; end;
  --log("VehicleLeash once per half-second event called.");

  remove_invalid_vehicles();

  update_robotanks(e.tick)
  drive_vehicles(e.tick);
end);

-- On built entity: add to tables.
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
  function(e)
    local ent = e.created_entity;
    --log("VehicleLeash: saw built event: " .. serpent.block(entity_info(ent)));
    if (ent.type == "car") then
      local controller = add_vehicle(ent);

      -- When a new robotank is placed, delay its automatic drive for 5s.
      -- This gives it time to get loaded with fuel and ammo by inserters
      -- before it drives away from the placement spot.
      controller.automatic_drive_min_tick = e.tick + 120;
    end;
  end
);

-- Copy all items from 'source' to 'dest', returning the total number
-- of items copied.  This duplicates the items, so should only be done
-- when the source inventory is about to be destroyed.
local function copy_inventory_from_to(source, dest)
  local ret = 0
  for name, count in pairs(source.get_contents()) do
    ret = ret + dest.insert({name=name, count=count});
  end;
  return ret;
end;

script.on_event({defines.events.on_player_mined_entity},
  function(e)
    if (e.entity.name == "robotank-entity") then
      -- When we pick up a robotank, also grab any unused ammo in
      -- the turret entity so it is no lost.
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


-- Unit tests, meant to be run via Lua command line:
--
--  $ LUA_PATH='/d/SteamLibrary/steamapps/common/Factorio/data/core/lualib/?.lua;/d/dist/factorio/?.lua;?.lua' lua -l stubs -l control -e 'unit_tests()'
--
-- /d/dist/factorio is where I put serpent.lua.
function unit_tests()
  print("Running unit tests for VehicleLeash control.lua ...");
  test_predict_approach();
  print("VehicleLeash unit tests passed");

end;






















-- EOF
