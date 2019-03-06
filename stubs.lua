-- stubs.lua
-- Stubs that will allow control.lua to be loaded by the stand-alone Lua interpreter

serpent = require "serpent";

function log(s)
  print(s);
end;

script = {};

function script.on_event()
end;

function script.on_init()
end;

function script.on_load()
end;

defines = {};

defines.events = {};
defines.events.on_player_mined_entity = 1;
defines.events.on_robot_built_entity = 2;
defines.events.on_tick = 3;

defines.inventory = {};
defines.inventory.car_ammo = 4;
defines.inventory.car_trunk = 5;
defines.inventory.turret_ammo = 6;

defines.riding = {};
defines.riding.acceleration = {};
defines.riding.acceleration.accelerating = 7;
defines.riding.acceleration.braking = 8;
defines.riding.acceleration.nothing = 9;
defines.riding.acceleration.reversing = 13;

defines.riding.direction = {};
defines.riding.direction.left = 10;
defines.riding.direction.right = 11;
defines.riding.direction.straight = 12;

settings = {};
settings.global = {};
settings.global["robotank-ammo-check-period-ticks"] = { value=1 };
settings.global["robotank-ammo-move-magazine-count"] = { value=1 };

-- EOF
