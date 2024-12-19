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

  -- Color of a RoboTank.
  --
  -- Since there is no setting type for a color, I have to make this
  -- three different settings.
  --
  -- TODO: There now is a color setting type, so I should use that.
  --
  {
    type = "double-setting",
    name = "robotank-color-red",
    order = "c1",
    setting_type = "startup",
    default_value = 0.7,
    minimum_value = 0,
    maximum_value = 1.0,
  },
  {
    type = "double-setting",
    name = "robotank-color-green",
    order = "c2",
    setting_type = "startup",
    default_value = 0.7,
    minimum_value = 0,
    maximum_value = 1.0,
  },
  {
    type = "double-setting",
    name = "robotank-color-blue",
    order = "c3",
    setting_type = "startup",
    default_value = 1.0,
    minimum_value = 0,
    maximum_value = 1.0,
  },
});

-- EOF
