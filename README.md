Introduction
============

RoboTank is a mod for [Factorio](https://wiki.factorio.com/).  It adds
an entity called RoboTank that is like the stock tank except it will
follow and fight with the player.  It is possible to build a squad of
RoboTanks that will stay together, attempting to maintain formation.
This is meant as an alternative to the somewhat monotonous "turret
creep" tactic.

Manual Installation
===================

Copy the release zip file (RoboTank_X.Y.Z.zip) into the "mods" subfolder
of the [User Data Directory](https://wiki.factorio.com/Application_directory#User_Data_directory).
Then start (or restart) Factorio.  It should then appear in the Mods
list available from the Factorio main menu, initially enabled.

Usage
=====

First unlock the RoboTank technology.  It requires Robotics, Tank,
and Advanced Electronics 2 ("Blue Circuits") to be researched first.

Then create a RoboTank Transmitter and at least one RoboTank.  Both are
found in the Combat tab of the crafting menu (even though the normal
tank is under Logistics).

Next, place a normal tank in the world.  This will be the commander,
and you will drive it manually.  Near the commander, place your
RoboTank(s).  Where you put the RoboTanks in relation to the commander
matters, as they will remember it as their formation position.
Add fuel and ammo (bullets or cannon shells) to the RoboTanks.

Finally, put the RoboTank Transmitter into the inventory of the commander tank
and start driving it.  The RoboTanks will drive themselves to stay in
formation and will automatically fire at enemy units and structures.

If you remove the transmitter from the commander, it ceases to be the
commander.  The RoboTanks will halt and wait for another commander (tank
with transmitter in it) to come into existence.

Any type of vehicle, including modded vehicles, can act as the
commander.  However, in practice, it works best if the commander vehicle
behaves similarly to the vanilla tank since the RoboTanks then have an
easier time matching the commander's movements.

Features
========

RoboTanks can fire either bullets or cannon shells, depending on
which is loaded into the ammo slot first.  Once that category is
exhausted, it will switch to the other category if available in an
ammo slot.  Otherwise it will try to take more ammo of the currently
active category from the vehicle trunk, but will not switch ammo
categories by taking from the trunk.

RoboTanks will try to avoid running into each other, with any other
vehicle on the same force (set of allied players), and with the player.

RoboTanks that become "stuck" will try to escape by reversing a
short distance and trying again.

You can get out of the commander tank and manually drive a wayward
RoboTank to help it get where it is going--or, in an emergency, to
escape from a battle gone horribly wrong!

Performance
-----------

The logic has been fairly heavily optimized for speed.  On my test map
with 40 tanks, RoboTank uses about 1.3ms per game tick when there is a
commander, and about 20us per tick when there is no commander.  It is
fast enough to use on megabase maps.

In multiplayer usage, each player can have their own squad of tanks
(but only one squad per player).  Allied tank squads will avoid running
into each other, so can be maneuvered in reasonably close proximity.
However, while the mod is intended to be usable in PvP scenarios, that
has not been tested.

Operation on multiple surfaces (planets)
----------------------------------------

RoboTanks on each surface (planet) operate independently of other
surfaces.  At any moment, there can only be one active commander vehicle
per player, but when the player changes surfaces (including by using the
map view), the active commander vehicle changes accordingly.
Consequently, one can have a deployed squad on each surface, each of
which will only self-drive when the commander is on the same surface.

Furthermore, remote driving works for both the commander vehicle and the
RoboTanks.  The RoboTanks even know to not run over the idle player
character!

Construction and deconstruction by robots
-----------------------------------------

RoboTanks can be put into a blueprint, and that will record the fuel,
equipment grid contents, and logistic requests.  This makes it possible
to quickly deploy a squad with all gear.

RoboTanks cannot be marked for deconstruction by robots using a
deconstruction planner; see forum post
[2.0.12 Cannot deconstruct Tank with deconstruction planner](https://forums.factorio.com/viewtopic.php?f=23&t=118929).
However, as noted in a reply on that post, it *is* possible to
right-click-and-hold from the map view to mark them one at a time for
deconstruction.  In that case, the ammo that was loaded into the
hidden turret entity spills out onto the ground, and the bots then
pick up that ammo, which is a bit inelegant but it works and no ammo
is lost in the process.

Firing cannon shells
--------------------

The vanilla cannon shells do friendly fire damage.  The RoboTank firing
logic is oblivious to this, and will therefore regularly damage and
destroy other squad members while trying to hit nearby enemies with
cannon shells.  You will almost certainly want to install
[Smart Cannon Shells](https://mods.factorio.com/mod/SmartCannonShells)
alongside RoboTank if you use cannon shells in RoboTanks (which is
recommended for dealing with high-evolution enemies).

However, if you decide to use vanilla shells rather than smart shells,
you must enable the startup configuration setting "Impose cannon minimum
range".  This sets the minimum range to 5 units, and starts the
projectile from that distance.  Otherwise, the projectile (which is
fired by the hidden turret entity) will hit the hull of the RoboTank
that fired it.  The main downside of this setting is it causes the
muzzle flash to appear in the wrong place, which is why it is not
enabled by default.

Balance issues
==============

RoboTanks do not know how to navigate around cliffs (or anything else).
In Factorio Space Age, cliff explosives are not unlocked for quite a
while, during which time it is consequently very difficult to make use
of RoboTanks due to them frequently getting stuck on cliffs.

Limitations
===========

There is no way to tell how much ammo a tank has in its hidden turret
entity; hovering the mouse over a RoboTank only shows what is in the
tank's visible inventory.

RoboTank collision avoidance is far from perfect.  They will run into
each other and/or become stuck if you maneuver the commander too
aggressively.

You should only have one transmitter (on each surface).  Putting
transmitters in multiple vehicles will probably confuse the RoboTanks.

Gates do not open for RoboTanks.  For now, it's best to assemble the
squad outside your walls.

There is currently no limit on transmitter range.  Consequently, if you
make a RoboTank and forget about it, then later make a commander on the
other side of your base, the forgotten RoboTank might go on an inadvertent
rampage inside your base before you notice.

The first stack of ammo placed in a RoboTank seems to disappear.  This
happens because, internally, it has been moved to a hidden turret entity
that does the firing.  You get any unfired ammo back when you pick up
the tank.

When a RoboTank exhausts the ammo stack it is using internally, an alert
is shown saying a turret ran out of ammo, even if it successfully
reloaded from the visible inventory and hence is not actually out of
ammo.  I'm not sure how to fix that.

RoboTanks cannot fire flamethrower ammo.

The RoboTank turrets do not return to the forward position when disengaged
with the enemy like the normal tank turret does.  Instead, they continue to
point in the direction they last fired.  That is because they are reflecting
the aim direction of the underlying hidden turret entity.

Additionally, when there is no commander, the RoboTank turrets visually return
to the forward position and stay there, not appearing to aim at their targets.
When a commander is created, the link between the visible turret and hidden
turret aim direction is re-established.

I have made no attempt to migrate RoboTank entities from the 1.x series.
I don't know what will happen if you load a world from Factorio 1.x that
had RoboTank installed into Factorio 2.x.

Other recommended mods
======================

If RoboTanks are to fire cannon shells (rather than only submachine gun
ammo), they must use
[Smart Cannon Shells](https://mods.factorio.com/mod/SmartCannonShells),
otherwise every shot will just hit the tank that fired it.

To avoid construction robots dying needlessly in combat while trying to
repair RoboTanks under fire, you can use
[Hide Repair Packs](https://mods.factorio.com/mod/HideRepairPacks).

If you like to mix in some nukes with your tanks, the
[Safety Nuke Launcher](https://mods.factorio.com/mod/SafetyNukeLauncher)
will help avoid accidentally nuking yourself.

[Faster Tank Turret](https://mods.factorio.com/mod/FasterTankTurret)
helps make the tank cannon weapon responsive.  That doesn't much affect
RoboTanks, but it does make your own commander tank more useful in
battle.

Adding
[Bulldozer Equipment](https://mods.factorio.com/mod/BulldozerEquipment)
to RoboTanks will clear trees, rocks, cliffs, and water out of the way
of the squad's advance, which is quite useful since RoboTanks are bad at
dealing with obstacles.

Links
=====

Factorio mod portal page: https://mods.factorio.com/mods/smcpeak/RoboTank

Github repo: https://github.com/smcpeak/factorio-robotank

Demo video on YouTube: https://www.youtube.com/watch?v=M64LyVkl6Ac
