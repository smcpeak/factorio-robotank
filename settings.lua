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
  -- The ammo in the turret is not visible anywhere in the UI because the
  -- turret is hidden, but when the tank is picked up, the turret ammo is
  -- returned to the player.
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
  
  -- Color of a RoboTank.
  --
  -- Since there is no setting type for a color, I have to make this
  -- three different settings.
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
