-- factorio_util.lua
-- Utilities for Factorio mods.

-- Given something that could be a string or an object with
-- a name, yield it as a string.  I use this mainly for the
-- "force" attribute of entities.
function string_or_name_of(e)
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
function entity_info(e)
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

-- "Orientation" in Factor is a floating-point number in [0,1]
-- where 0 is North, 0.25 is East, 0.5 is South, and 0.75 is West.
-- Convert that to a unit vector where +x is East and +y is South.
function orientation_to_unit_vector(orientation)
  -- Angle measured from East toward South, in radians.
  local angle = (orientation - 0.25) / 1.00 * 2.00 * math.pi;
  return {x = math.cos(angle), y = math.sin(angle)};
end;

-- Given a Factorio "orientation", normalize it to [0,1).
function normalize_orientation(o)
  while o < 0 do
    o = o + 1;
  end;
  while o >= 1 do
    o = o - 1;
  end;
  return o;
end;

function orientation_to_radians(orientation)
  return (orientation - 0.25) * 2 * math.pi;
end;

-- Convert to radians in [-pi,pi] to orientation in [-0.25, 0.75].
function radians_to_orientation(radians)
  return radians / (2 * math.pi) + 0.25;
end;

function vector_to_orientation(v)
  local angle = vector_to_angle(v);
  local orientation = radians_to_orientation(angle);

  -- Raise to [0,1].
  orientation = normalize_orientation(orientation);

  return orientation;
end;

-- Get the velocity vector of a vehicle in meters (game units) per tick.
function vehicle_velocity(v)
  local direction = orientation_to_unit_vector(v.orientation);
  return multiply_vec(direction, v.speed);
end;

riding_acceleration_string_table = {
  [defines.riding.acceleration.accelerating] = "accelerating",
  [defines.riding.acceleration.nothing] = "nothing",
  [defines.riding.acceleration.braking] = "braking",
  [defines.riding.acceleration.reversing] = "reversing",
};
riding_direction_string_table = {
  [defines.riding.direction.straight] = "straight",
  [defines.riding.direction.left] = "left",
  [defines.riding.direction.right] = "right",
};

-- Copy all items from 'source' to 'dest', returning the total number
-- of items copied.  This duplicates the items, so should only be done
-- when the source inventory is about to be destroyed.
function copy_inventory_from_to(source, dest)
  local ret = 0
  for name, count in pairs(source.get_contents()) do
    ret = ret + dest.insert({name=name, count=count});
  end;
  return ret;
end;


-- EOF
