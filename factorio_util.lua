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
    surface = e.surface.name,
    --bounding_box = e.bounding_box,
    valid = e.valid,
    force = string_or_name_of(e.force),
    unit_number = e.unit_number,
  };
end;

-- "Orientation" in Factorio is a floating-point number in [0,1]
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

-- Given two orientations in [0,1], compute o1-o2, then normalize
-- the result to [-0.5, 0.5].
function orientation_difference(o1, o2)
  local orient_diff = o1 - o2;
  if (orient_diff > 0.5) then
    orient_diff = orient_diff - 1;
  elseif (orient_diff < -0.5) then
    orient_diff = orient_diff + 1;
  end;
  return orient_diff;
end;

-- Absolute value of orientation difference, useful for testing whether
-- two orientations are close to one another.  Result is in [0, 0.5].
function absolute_orientation_difference(o1, o2)
  return math.abs(orientation_difference(o1, o2));
end;

-- Convert orientation in [0,1] where 0 is North, 0.25 is East, etc.,
-- to radians in [-pi/2, 3*pi/2] where 0 is East, pi/2 is South, etc.
function orientation_to_radians(orientation)
  return (orientation - 0.25) * 2 * math.pi;
end;

-- Convert to radians in [-pi, pi] to orientation in [-0.25, 0.75].
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

-- Get the velocity vector of a vehicle in meters (game units) per tick
-- if its speed is 'speed'.
function vehicle_velocity_if_speed(v, speed)
  local direction = orientation_to_unit_vector(v.orientation);
  return multiply_vec(direction, speed);
end;

-- Get the velocity vector of a vehicle in meters (game units) per tick.
function vehicle_velocity(v)
  return vehicle_velocity_if_speed(v, v.speed);
end;

-- Get the velocity of an arbitrary entity.
function entity_velocity(e)
  if (e.type == "car") then
    return vehicle_velocity(e);
  else
    return {x=0, y=0};
  end;
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

-- Copy all items from `source` to `dest` LuaInventory, returning the
-- total number of items copied.  This duplicates the items, so should
-- only be done when the source inventory is about to be destroyed.
--
-- Note: It is often better to use `LuaItemStack.swap_stack` on empty
-- stacks (to avoid duplication issues, etc.), but the way this function
-- is called, `dest` is the `buffer` element of the event object for
-- `on_player_mined_entity`, and that inventory does not have any empty
-- stacks initially.
--
function copy_inventory_from_to(source, dest)
  local num_items_copied = 0;

  -- Copy slot by slot in order to preserve quality, freshness, etc.
  for source_slot_num = 1, #source do
    local source_stack = source[source_slot_num];
    if (source_stack.count > 0) then
      local copy_count = dest.insert(source_stack);
      num_items_copied = num_items_copied + copy_count;
    end;
  end;

  return num_items_copied;
end;


-- EOF
