# gunLib

Cannon control for Create Big Cannons. Works without the radar.
Scroll with up/down, jump between sections with left/right, press Q to exit.

    local gun = require("gun")
    local cannon = gun.bigCannon({
        mount = peripheral.find("cannon_mount"),
        offset = { 2, 0, -3 },
        length = 8, muzzle = 5,
        charges = { "powder", "powder", "mk3" },
        shell = "he_shell",
    })
    cannon:assemble()
    cannon:fireAt(100, 70, -20)

Examples on this computer: `gun_aim_example`, `gun_track_example`.

## Cannon

Constructors:

* `gun.bigCannon`: `length`, `muzzle`, `charges`, `shell`, `muzzleBrakes`, `speed`.
* `gun.autocannon`: `material`, `barrels`, `muzzle`, `round`.
* `gun.heavyAutocannon`: the same plus `strong = true`.

For all of them: `mount`, `offset` or `position` (see Position), `arc` ("auto", "low", "high"), `tolerance` in blocks, `limits` as {min, max}, `pivotOffset`.

* `length`: blocks in front of the breech, muzzle included.
* `muzzle`: blocks from the block above the mount to the muzzle block.
* `charges`: from the breech forward: "powder", "mk1" to "mk5", "cartridge1" to "cartridge4" or a number.

Only the calculation, nothing moves:

    local s = cannon:solve(target)
    local points = cannon:trajectory(s)

## Aim

Single aiming at coordinates.

    cannon:aimAt(x, y, z)

Commands the mount and returns at once.

    cannon:aimAt(x, y, z, { wait = true })

Returns when the cannon is on target.

    cannon:fireAt(x, y, z)

Aims, waits and fires. `state.fired` tells if the shot went.

    cannon:fire()

Fires now. Returns true, or false and the reason.

Instead of x, y, z pass a target: {x=, y=, z=}. With `velocity` as {x, y, z} in blocks per tick `fireAt` leads it.

Last argument, a table: `arc`, `latency`, `timeout` in ticks.

## Track

Following a moving target.

    cannon:follow(target, {
        onUpdate = function(state)
            if state.onTarget then
                cannon:fire()
            end
        end,
    })

Runs until `cannon:stop()`, until `onUpdate` returns false or for `timeout` ticks. It blocks: use `parallel` for other work.

`target` is a function returning {x, y, z} or nil, or a table another program keeps updating. Optional fields:

* `velocity`: {x, y, z} in blocks per tick. Without it the speed is estimated from the positions.
* `uuid`: a new one forgets the previous target.

Your own loop, one step:

    local state = cannon:update(target)
    if state.onTarget then cannon:fire() end
    sleep(0.05)

Fire right after `update`: `onTarget` is about that moment.

With the radar use world coordinates:

    radar.scan(sensor, "sublevel", true)

## State

What `update`, `aimAt`, `fireAt` and `follow` return.

* `ok`: there is a solution the cannon can follow.
* `reason`: why not.
* `onTarget`: a shot fired right now would hit.
* `miss`: expected miss of that shot, blocks.
* `error`: barrel error now, degrees.
* `slew`: ticks left to turn.
* `yaw`, `pitch`: mount angles, structure axes on a structure.
* `ticks`: flight time.
* `aimPoint`: where the target will be.
* `target`: predicted target with velocity.
* `mode`: "ground", "structure" or "manual".
* `fired`, `fireError`: `fireAt` only.

Values of `reason`: no target, not assembled, out of range, pitch outside limits, projectile expires before reaching the target, mount shaft is not turning, timeout, or the text of a peripheral or GPS error.

## Position

* `offset = {dx, dy, dz}`: mount block minus computer block. On a Sable structure these are its own axes. The computer block comes from GPS, on a structure GPS is required.
* `position = {x, y, z}`: mount block from F3 instead of `offset`, ground only, no GPS.

`gun.setHost(x, y, z)` sets the computer block by hand, ground only.

`cannon:pivot()` returns {x, y, z} and the mode: compare with F3.

`cannon:setOffset(dx, dy, dz)` moves the mount.

`gun.calibrate()` measures the computer again, for example after moving it. After "structure calibration failed" slow the structure down and call it.

## Mounts

* `cannon_mount` (CC:CBC): turns by itself at RPM * 0.0375 degrees per tick, 256 RPM = 9.6. At 0 RPM it does not move: "mount shaft is not turning". `cannon:setFiring(true)` holds the trigger.
* `cbc_cannon_mount` (CBC Peripheral, CC Optical): angles apply at once, single shots only.

A mount turns only when assembled: `cannon:assemble()`. `cannon:disassemble()` turns it back into blocks.

`compact_cannon_mount` is not supported: pitch only.

## Settings

`gun.config`: `tolerance`, `latency`, `aimTimeout`, `velocityWindow`, `maxTargetSpeed`, `staleTicks`, `maxAge`, `gpsTimeout`, `structureCheck`.

Mount delays are measured. `latency` adds extra ticks of lead for fine tuning: raise it if shells land behind the target.

`gun.ballistics.config`: `inheritVelocity`, `physicsRework`, `gravityMultiplier`, `dragMultiplier`, `maxTicks`. Set them to match the server config and the dimension.

Check a cannon with a shot at a still target first. If it misses, compare `length`, `muzzle` and the server config.

Full manual: github.com/cfifskin/gunLib
