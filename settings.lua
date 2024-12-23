-- settings.lua
-- Defines configuration settings for RoboTank.

data:extend({
  -- Time between checks for a tank being out of ammo.
  {
    type = "int-setting",
    name = "robotank-ammo-check-period-ticks",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 1,
    maximum_value = 60,
  },

  -- Diagnostic log verbosity level.  See 'diagnostic_verbosity' in
  -- control.lua.
  {
    type = "int-setting",
    name = "robotank-diagnostic-verbosity",
    setting_type = "runtime-global",
    default_value = 1,
    minimum_value = 0,
    maximum_value = 4,
  },

  -- Whether to push the cannon projectile start point away from the
  -- tank.
  {
    type = "bool-setting",
    name = "robotank-impose-cannon-minimum-range",
    setting_type = "startup",
    default_value = false,
  },

  -- Color of a RoboTank.
  {
    type = "color-setting",
    name = "robotank-color",
    setting_type = "startup",
    default_value = { r=0.7, g=0.7, b=1.0, a=1.0 },
  },
});

-- EOF
