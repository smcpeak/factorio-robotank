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

  -- Amount of ammo to move into the turret when it runs out.
  --
  -- I originally had this as 10 to match the usual way that inserters load
  -- turrets, but then I reduced the frequency of the reload check
  -- to once per 5 ticks, so I want a correspondingly bigger buffer
  -- here, so the current default is 50.
  {
    type = "int-setting",
    name = "robotank-ammo-move-magazine-count",
    setting_type = "runtime-global",
    default_value = 50,
    minimum_value = 1,
    maximum_value = 200,
  },
});

-- EOF
