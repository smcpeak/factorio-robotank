-- VehicleLeash control.lua
-- Actions that run while the user is playing the game.

require "util"               -- table.deepcopy

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
-- from unit_number to the vehicle entity.
local force_to_vehicles = {};

-- Add a vehicle to our table.
local function add_vehicle(v)
  local force_name = string_or_name_of(v.force);
  force_to_vehicles[force_name] = force_to_vehicles[force_name] or {};
  force_to_vehicles[force_name][v.unit_number] = v;
  log("Vehicle " .. v.unit_number ..
      " with name " .. v.name ..
      " at (" .. v.position.x .. "," .. v.position.y .. ")" ..
      " added to force " .. force_name);
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
    for unit_number, v in pairs(vehicles) do
      if (v.valid) then
        num_vehicles = num_vehicles + 1;
      else
        vehicles[unit_number] = nil;
        log("Removed invalid vehicle " .. unit_number .. ".");
      end;
    end;
    --log("Force " .. force .. " has " .. num_vehicles .. " vehicles.");
  end;
end;

local function find_player_vehicle(vehicles)
  for unit_number, v in pairs(vehicles) do
    if ((v.passenger ~= nil) and (v.passenger.type == "player")) then
      --log("Player vehicle is unit " .. v.unit_number);
      return v;
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

local function unit_vector_to_orientation(v)
  -- Angle South of East, in radians.
  local angle = math.atan2(v.y, v.x);

  -- Convert to orientation in [-0.25, 0.75].
  local orientation = angle / (2 * math.pi) + 0.25;

  -- Raise to [0,1].
  if (orientation < 0) then
    orientation = orientation + 1;
  end;

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

local function drive_vehicles(tick_num)
  for force, vehicles in pairs(force_to_vehicles) do
    local player_vehicle = find_player_vehicle(vehicles);
    if (player_vehicle == nil) then
      --log("Force " .. force .. " does not have a player vehicle.");
      for unit_number, v in ordered_pairs(vehicles) do
        -- Don't let the vehicles run away when I jump out.
        v.riding_state = {
          acceleration = defines.riding.acceleration.nothing;
          direction = defines.riding.direction.straight;
        };
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

      for unit_number, v in ordered_pairs(vehicles) do
        if (v ~= player_vehicle) then
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
            local desired_orientation = unit_vector_to_orientation(normalize_vec(projected_straight_disp));

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

          -- Apply the desired controls to the vehicle.
          v.riding_state = {
            acceleration = pedal,
            direction = turn,
          };

          if (tick_num % 60 == 0) then
            log("pedal=" .. pedal_string .. ", turn=" .. turn_string);
          end;
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

  drive_vehicles(e.tick);
end);

-- On built entity: add to tables.
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
  function(e)
    local ent = e.created_entity;
    --log("VehicleLeash: saw built event: " .. serpent.block(entity_info(ent)));
    if (ent.type == "car") then
      add_vehicle(ent);
    end;
  end
);


-- EOF
