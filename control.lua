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

local function drive_vehicles()
  for force, vehicles in pairs(force_to_vehicles) do
    local player_vehicle = find_player_vehicle(vehicles);
    if (player_vehicle == nil) then
      --log("Force " .. force .. " does not have a player vehicle.");
    else
      for unit_number, v in pairs(vehicles) do
        if (v ~= player_vehicle) then
          local old_speed = v.speed;
          local old_orientation = v.orientation;
          v.speed = player_vehicle.speed;
          v.orientation = player_vehicle.orientation;
          --log("Changed vehicle " .. v.unit_number ..
          --    " speed from " .. old_speed .. " to " .. v.speed ..
          --    " and orientation from " .. old_orientation .. " to " .. v.orientation);
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

  --if not ((e.tick % 60) == 0) then return; end;
  --log("VehicleLeash once per second event called.");

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
