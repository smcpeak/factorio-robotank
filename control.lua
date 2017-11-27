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

local function magnitude(v)
  return math.sqrt(v.x * v.x + v.y * v.y);
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

local function drive_vehicles()
  for force, vehicles in pairs(force_to_vehicles) do
    local player_vehicle = find_player_vehicle(vehicles);
    if (player_vehicle == nil) then
      --log("Force " .. force .. " does not have a player vehicle.");
    else
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
          local full_lateral = multiply_vec(lateral_vec, lateral_fact);
          lateral_fact = lateral_fact - 1;
          local displacement = subtract_vec(add_vec(desired_pos, full_lateral), v.position);
          local disp_mag = magnitude(displacement);
          if (disp_mag > 0.1) then
            v.orientation = unit_vector_to_orientation(normalize_vec(displacement));
            v.speed = math.min(0.2, disp_mag / 3.0 * 0.1);
            --log("For disp " .. serpent.line(displacement) ..
            --    ", setting orientation to " .. v.orientation ..
            --    " and speed to " .. v.speed .. ".");
          else
            v.speed = 0;
            --log("Stopping vehicle.");
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

  if not ((e.tick % 30) == 0) then return; end;
  --log("VehicleLeash once per half-second event called.");

  remove_invalid_vehicles();

  drive_vehicles();
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
