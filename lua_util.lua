-- lua_util.lua
-- General Lua utilities.


-------------------------- Tables -----------------------

-- Keys of a table, as an unordered array.
function table_keys_array(t)
  local a = {};
  for n in pairs(t) do
    table.insert(a, n);
  end;
  return a;
end;

-- The pairs of a table, ordered by key.
-- Based on: https://www.lua.org/pil/19.3.html
function ordered_pairs (t, f)
  local a = table_keys_array(t);
  table.sort(a, f);
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
function table_size(t)
  local ct = 0;
  for _, _ in pairs(t) do
    ct = ct + 1;
  end;
  return ct;
end;


------------------------- 2D Vectors ---------------------
function equal_vec(v1, v2)
  return v1.x == v2.x and v1.y == v2.y;
end;

-- Add two 2D vectors.
function add_vec(v1, v2)
  return { x = v1.x + v2.x, y = v1.y + v2.y };
end;

function subtract_vec(v1, v2)
  return { x = v1.x - v2.x, y = v1.y - v2.y };
end;

-- Multiply a 2D vector by a scalar.
function multiply_vec(v, scalar)
  return {x = v.x * scalar, y = v.y * scalar};
end;

function mag_sq(v)
  return v.x * v.x + v.y * v.y;
end;

function magnitude(v)
  return math.sqrt(mag_sq(v));
end;

-- Magnitude squared of a difference between vectors.  This is
-- measurably faster than mag_sq(subtract_vec(p1, p2)) because,
-- I think, it avoids the overhead of creating an intermediate
-- table.
function mag_sq_subtract_vec(p1, p2)
  local dx = p1.x - p2.x;
  local dy = p1.y - p2.y;
  return dx*dx + dy*dy;
end;

function normalize_vec(v)
  if ((v.x == 0) and (v.y == 0)) then
    return v;
  else
    return multiply_vec(v, 1.0 / magnitude(v));
  end;
end;

-- Return the angle this vector makes with the horizontal, in
-- radians.  In the standard coordinate system, this is measured
-- counterclockwise; in Factorio, it is measured counterclockwise
-- (South of East).
function vector_to_angle(v)
  return math.atan2(v.y, v.x);
end;

-- Rotate a vector by a given angle.  This works for the standard coordinate
-- system with +y up and counterclockwise angles, as well as the Factorio
-- coordinate system with +y down and clockwise angles.
function rotate_vec(v, radians)
  local s = math.sin(radians);
  local c = math.cos(radians);
  return {
    x = v.x * c - v.y * s,
    y = v.x * s + v.y * c,
  };
end;

-- Normalize radians to [-pi,pi).
function normalize_radians(r)
  while r < -math.pi do
    r = r + (math.pi * 2);
  end;
  while r >= math.pi do
    r = r - (math.pi * 2);
  end;
  return r;
end;


-- EOF
