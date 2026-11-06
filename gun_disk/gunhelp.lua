-- Help for the gun library, right on the computer.
--   gunhelp          list of topics
--   gunhelp <topic>  one topic
-- The full manual is the README of the repository.

local TOPICS = {
    { "cannon", "describing a cannon", [[
local gun = require("gun")
local cannon = gun.bigCannon({
    mount = peripheral.find("cannon_mount"),
    offset = { 2, 0, -3 },
    length = 8, muzzle = 5,
    charges = { "powder", "powder", "mk3" },
    shell = "he_shell",
})
cannon:assemble()

gun.bigCannon: length, muzzle, charges, shell,
  muzzleBrakes, speed.
gun.autocannon: material, barrels, muzzle, round.
gun.heavyAutocannon: the same plus strong = true.

For all: mount, offset or position (see: position),
arc ("auto", "low", "high"), tolerance (blocks), limits
{min, max}, pivotOffset.

length: blocks in front of the breech, muzzle included.
muzzle: blocks from the block above the mount to the
  muzzle block.
charges: from the breech forward: "powder", "mk1".."mk5",
  "cartridge1".."cartridge4" or a number.]] },

    { "aim", "single aiming at coordinates", [[
cannon:aimAt(x, y, z)
  command the mount and return at once.
cannon:aimAt(x, y, z, { wait = true })
  return when the cannon is on target.
cannon:fireAt(x, y, z)
  aim, wait, fire. state.fired tells if the shot went.
cannon:fire()
  fire now. Returns true or false, reason.

Instead of x, y, z pass a target: {x=, y=, z=}. With
velocity = {x, y, z} (blocks/tick) fireAt leads it.

Last argument, a table: arc, latency, timeout (ticks).
All return a state (see: state).]] },

    { "track", "following a moving target", [[
cannon:follow(target, {
    onUpdate = function(state)
        if state.onTarget then cannon:fire() end
    end,
})

Runs until cannon:stop(), until onUpdate returns false or
for timeout ticks. It blocks: use parallel for other work.

target is a function returning {x, y, z} or nil, or a
table another program keeps updating.
Optional fields:
  velocity {x, y, z}, blocks/tick. Without it the speed is
    estimated from the positions.
  uuid: a new one forgets the previous target.

Your own loop, one step:
local state = cannon:update(target)
if state.onTarget then cannon:fire() end
sleep(0.05)

Fire right after update: onTarget is about that moment.
With the radar use global coordinates:
radar.scan(sensor, "sublevel", true)]] },

    { "state", "what update, aimAt and fireAt return", [[
ok        there is a solution the cannon can follow
reason    why not
onTarget  a shot fired right now would hit
miss      expected miss of that shot, blocks
error     barrel error now, degrees
slew      ticks left to turn
yaw, pitch   mount angles (structure axes on a structure)
ticks     flight time
aimPoint  where the target will be
target    predicted target with velocity
mode      "ground", "structure" or "manual"
fired, fireError   fireAt only

reason: no target, not assembled, out of range,
pitch ... outside ..., projectile expires before reaching
the target, mount shaft is not turning, timeout, or the
text of a peripheral or GPS error.]] },

    { "position", "where the cannon is", [[
offset = {dx, dy, dz}: mount block minus computer block.
  On a Sable structure these are its own axes. The computer
  block comes from GPS, on a structure GPS is required.
gun.setHost(x, y, z): computer block by hand, ground only.
position = {x, y, z}: mount block from F3 instead of
  offset, ground only, no GPS.

cannon:pivot() returns {x, y, z}, mode: compare with F3.
cannon:setOffset(dx, dy, dz) moves the mount.
gun.calibrate() measures the computer again, for example
after "structure calibration failed": slow it down first.]] },

    { "mounts", "supported mounts", [[
cannon_mount (CC:CBC): turns by itself at the speed of its
  shafts: RPM * 0.0375 degrees per tick, 256 RPM = 9.6.
  At 0 RPM it does not move: "mount shaft is not turning".
  cannon:setFiring(true/false) holds the trigger.
cbc_cannon_mount (CBC Peripheral, CC Optical): angles apply
  at once, single shots only.

A mount turns only when assembled: cannon:assemble().
cannon:disassemble() turns it back into blocks.
compact_cannon_mount is not supported: pitch only.]] },

    { "config", "settings", [[
gun.config: tolerance, latency (extra ticks of lead),
  aimTimeout, velocityWindow, maxTargetSpeed, staleTicks,
  maxAge, gpsTimeout, structureCheck.
  Mount delays are measured, latency is only for fine
  tuning: raise it if shells land behind the target.

ballistics.config (gun.ballistics.config): inheritVelocity,
  physicsRework, gravityMultiplier, dragMultiplier,
  maxTicks. Set them to match the server config and
  dimension.

Check a cannon with a shot at a still target first. If it
misses, compare length, muzzle and the server config.]] },
}

local args = { ... }
local name = args[1]

local function list()
    print("gunhelp <topic>")
    for _, topic in ipairs(TOPICS) do
        print(("  %-9s %s"):format(topic[1], topic[2]))
    end
    print("Examples: gun_aim_example, gun_track_example")
end

if not name then
    list()
    return
end

for _, topic in ipairs(TOPICS) do
    if topic[1] == name:lower() then
        textutils.pagedPrint(topic[3])
        return
    end
end
printError(("No topic '%s'"):format(name))
list()
