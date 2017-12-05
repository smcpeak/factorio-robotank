Introduction
============
RoboTank is a mod for [Factorio](https://wiki.factorio.com/).  It adds
an entity called RoboTank that is like the stock tank except it will
follow and fight with the player.  It is possible to build a squad of
RoboTanks that will stay together, attempting to maintain formation.
This is meant as an alternative to the somewhat monotonous "turret
creep" tactic.

Installation
============
Copy the release zip file (RoboTank_X.Y.Z.zip) into the "mods" subfolder
of the [User Data Directory](https://wiki.factorio.com/Application_directory#User_Data_directory).
Then start (or restart) Factorio.  It should then appear in the Mods
list available from the Factorio main menu, initially enabled.

Usage
=====
First unlock the RoboTank technology.  It requires Robotics and Tanks
to be researched first.

Then create a RoboTank Transmitter and at least one RoboTank.  Both are
found in the Combat tab of the crafting menu (even though the normal
tank is under Logistics).

Next, place a normal tank in the world.  This will be the commander,
and you will drive it manually.  Near the commander, place your
RoboTank(s).  Where you put the RoboTanks in relation to the commander
matters, as they will remember it as their formation position.
Add fuel and ammo (bullets) to the RoboTanks.

Finally, put the RoboTank Transmitter into the inventory of the commander
and start driving it.  The RoboTanks will drive themselves to stay in
formation and will automatically fire at enemy units and structures.

If you remove the transmitter from the commander, it ceases to be the
commander.  The RoboTanks will halt and wait for another commander (tank
with transmitter in it) to come into existence.

Features
========
RoboTanks will try to avoid running into each other, with any other
vehicle, and with the player.

RoboTanks that become "stuck" will try to escape by reversing a
short distance and trying again.

You can get out of the commander tank and manually drive a wayward
RoboTank to help it get where it is going.

The logic has been fairly heavily optimized for speed.  On my test map
with 40 tanks, RoboTank uses about 1ms per game tick when there is a
commander, and about 20us per tick when there is no commander.  It is
fast enough to use on megabase maps.

Limitations
===========
RoboTank collision avoidance is far from perfect.  They will run into
each other and/or become stuck if you maneuver the commander too
aggressively.

This mod hasn't been tested with multiplayer.  Moreover, there can only
be one commander (per force) right now.

You should only have one transmitter.  Putting transmitters in multiple
vehicles will probably confuse the RoboTanks.

Gates do not open for RoboTanks.  For now, it's best to assemble the
squad outside your walls.

There is currently no limit on transmitter range.  Consequently, if you
make a RoboTank and forget about it, then later make a commander on the
other side of your base, the forgotten RoboTank might go on an inadvertent
rampage inside your base before you notice.

Links
=====
Factorio mod portal page: https://mods.factorio.com/mods/smcpeak/RoboTank

Forum discussion page: https://forums.factorio.com/viewtopic.php?f=93&t=54395
