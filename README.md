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
First unlock the RoboTank technology.  It requires Robotics, Tanks,
and Advanced Electronics 2 ("Blue Circuits") to be researched first.

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
RoboTank to help it get where it is going--or, in an emergency, to
escape from a battle gone horribly wrong!

The logic has been fairly heavily optimized for speed.  On my test map
with 40 tanks, RoboTank uses about 1ms per game tick when there is a
commander, and about 20us per tick when there is no commander.  It is
fast enough to use on megabase maps.

In multiplayer usage, each player can have their own squad of tanks
(but only one squad per player).  Allied tank squads will avoid running
into each other, so can be maneuvered in reasonably close proximity.
However, while the mod is intended to be usable in PvP scenarios, that
has not been tested.

Limitations
===========
RoboTank collision avoidance is far from perfect.  They will run into
each other and/or become stuck if you maneuver the commander too
aggressively.

You should only have one transmitter.  Putting transmitters in multiple
vehicles will probably confuse the RoboTanks.

Gates do not open for RoboTanks.  For now, it's best to assemble the
squad outside your walls.

There is currently no limit on transmitter range.  Consequently, if you
make a RoboTank and forget about it, then later make a commander on the
other side of your base, the forgotten RoboTank might go on an inadvertent
rampage inside your base before you notice.

A portion of the ammo placed in a RoboTank seems to disappear.  This
happens because, internally, it has been moved to a hidden turret entity
that does the firing.  You get the ammo back when you pick up the tank.

The new worm and spitter mechanics in Factorio 0.17 cause a balance issue
because they are unable to properly lead RoboTanks due to the fact that
the worms are actually shooting at the hidden turret entity, and turrets do not
have a velocity attribute (the mod moves them via teleportation).  Thus,
RoboTanks take less damage than a normal tank in similar circumstances.

Links
=====
Factorio mod portal page: https://mods.factorio.com/mods/smcpeak/RoboTank

Forum discussion page: https://forums.factorio.com/viewtopic.php?f=93&t=55411

Demo video on YouTube: https://www.youtube.com/watch?v=M64LyVkl6Ac
