--[[
gun - cannon control for Create Big Cannons mounts. Works on its own: it needs
only the ballistics library next to it, no radar.

    local gun = require("gun")

    local cannon = gun.bigCannon({
        mount = peripheral.find("cannon_mount"),
        offset = { 2, 0, -3 },          -- mount block - computer block
        length = 8, muzzle = 5,
        charges = { "powder", "powder", "mk3" },
        shell = "he_shell",
    })
    cannon:assemble()

    -- Single shot at coordinates: turns, waits until on target, fires.
    cannon:fireAt(100, 70, -20)

    -- Moving target: a function or a table that somebody keeps updating.
    cannon:follow(function() return getTarget() end, {
        onUpdate = function(state)
            if state.onTarget then cannon:fire() end
        end,
    })

Both modes are the same step, cannon:update(target): predict the target, read
the cannon, solve, command the mount.
]]

local ballistics = require("ballistics")
local m = ballistics.math
local vec, add, sub, scale, len, cross, rotate, wrap180 =
    m.vec, m.add, m.sub, m.scale, m.len, m.cross, m.rotate, m.wrap180

local gun = { version = "1.0.0", ballistics = ballistics }

gun.config = {
    gpsTimeout = 2,       -- seconds to wait for gps.locate
    structureCheck = 2,   -- seconds between checks whether the computer is on a structure
    tolerance = 1,        -- on target = the barrel misses by at most this many blocks
    latency = 0,          -- extra ticks of lead on top of the measured mount delays
    aimTimeout = 600,     -- ticks aimAt with wait = true and fireAt keep trying
    velocityWindow = 20,  -- ticks of positions used to estimate a target's velocity
    maxTargetSpeed = 10,  -- blocks/tick; a faster jump means a different target
    staleTicks = 30,      -- an unchanged position counts as a new sample after this long
    maxAge = 40,          -- ticks an old target position is extrapolated at most
}

-- Mount turn rate in degrees per tick for one RPM on its shaft (CBC
-- getAngularSpeed: convertToAngular(rpm) * 0.125, convertToAngular = rpm * 0.3).
local DEGREES_PER_RPM = 0.0375

-- Server ticks since the computer started; os.clock counts them in 0.05 steps.
local function now() return math.floor(os.clock() * 20 + 0.5) end

---------------------------------------------------------------------------
-- Position of this computer

-- host.ground = world block; host.structure = { uuid, block } in structure coordinates.
local host = {}

-- GPS returns the lower corner of the block the wireless modem is attached to,
-- i.e. the computer block. On a Sable structure the point is already in world
-- space (Sable patches wireless distances).
local function locate()
    local x, y, z = gps.locate(gun.config.gpsTimeout)
    if not x then
        error("gun: GPS unavailable - set up GPS hosts or use gun.setHost", 0)
    end
    return { x, y, z }
end

-- CC: Sable calls run on the server thread and cost a game tick each, so
-- whether the computer is on a structure (and which one) is cached for
-- config.structureCheck seconds.
local structureCache = { time = -math.huge }

local function onStructure()
    if os.clock() - structureCache.time < gun.config.structureCheck then
        return structureCache.value
    end
    local value = type(sublevel) == "table" and type(sublevel.isInPlotGrid) == "function"
        and sublevel.isInPlotGrid() or false
    structureCache.value = value
    structureCache.uuid = value and sublevel.getUniqueId() or nil
    structureCache.time = os.clock()
    return value
end

-- Reads the structure pose. CC: Sable wraps orientation into a quaternion
-- object ({ v, a }); the raw table has x/y/z/w, so accept both.
local function readPose()
    local p = sublevel.getLogicalPose()
    local q = p.orientation
    if q.v then q = { x = q.v.x, y = q.v.y, z = q.v.z, w = q.a } end
    return {
        position = vec(p.position),
        q = { x = q.x, y = q.y, z = q.z, w = q.w },
        scale = vec(p.scale),
        pivot = vec(p.rotationPoint),
    }
end

-- Same maths as Sable's Pose3d.transformPosition / transformPositionInverse.
local function toWorld(pose, p)
    local s, c = pose.scale, pose.pivot
    local r = rotate(pose.q, { (p[1] - c[1]) * s[1], (p[2] - c[2]) * s[2], (p[3] - c[3]) * s[3] })
    return add(r, pose.position)
end

local function toStructure(pose, g)
    local r = rotate(pose.q, sub(g, pose.position), true)
    local s, c = pose.scale, pose.pivot
    return { r[1] / s[1] + c[1], r[2] / s[2] + c[2], r[3] / s[3] + c[3] }
end

local function nearest(v) return math.floor(v + 0.5) end

-- Finds the computer block in structure coordinates. The structure keeps moving
-- while GPS waits for replies, so the result is accepted only if poses read
-- before and after GPS agree and the point lands on a block corner.
local function calibrateStructure()
    local uuid = sublevel.getUniqueId()
    for _ = 1, 3 do
        local before = readPose()
        local g = locate()
        local after = readPose()
        local a, b = toStructure(before, g), toStructure(after, g)
        local block, ok = {}, true
        for i = 1, 3 do
            local mid = (a[i] + b[i]) / 2
            block[i] = nearest(mid)
            if math.abs(a[i] - b[i]) > 0.3 or math.abs(mid - block[i]) > 0.3 then ok = false end
        end
        if ok then
            host.structure = { uuid = uuid, block = block }
            return
        end
    end
    error("gun: structure calibration failed - slow the structure down and call gun.calibrate()", 0)
end

local function calibrateGround()
    local g = locate()
    host.ground = { nearest(g[1]), nearest(g[2]), nearest(g[3]) }
end

--- Set the computer block by hand (ground only, replaces GPS). nil returns to GPS.
function gun.setHost(x, y, z)
    if x == nil then
        host.ground = nil
        return
    end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        error("gun.setHost: x, y, z must be numbers", 2)
    end
    host.ground = { x, y, z }
end

--- Measure the computer position again with GPS (after moving the computer, or
-- if calibration on a structure failed).
function gun.calibrate()
    host.ground, host.structure = nil, nil
    structureCache.time = -math.huge
    if onStructure() then calibrateStructure() else calibrateGround() end
end

---------------------------------------------------------------------------
-- Mount drivers. Detected by their methods: on one pack the same block can be
-- served by CC:CBC, CBC Peripheral or CC Optical, and the last two share a type.

-- CC:CBC: setTargetAngles, the mount turns by itself at the speed of its shafts.
local function smoothDriver(mount)
    local d = { name = "smooth" }
    function d.read()
        local i = mount.getInfo()
        return {
            assembled = i.assembled, yaw = i.yaw, pitch = i.pitch,
            control = i.computerControl,
            yawRate = math.abs(i.yawShaftSpeed or 0) * DEGREES_PER_RPM,
            pitchRate = math.abs(i.pitchShaftSpeed or 0) * DEGREES_PER_RPM,
        }
    end
    function d.point(yaw, pitch, state)
        if not state.control then mount.setComputerControl(true) end
        mount.setTargetAngles(yaw, pitch)
    end
    function d.assemble() return mount.assemble(true) end
    function d.disassemble() return not mount.assemble(false) end
    -- fire() is a redstone level: the shot comes on its rising edge.
    function d.pull() return mount.fire(true) end
    function d.release() mount.fire(false) end
    function d.setFiring(on) mount.fire(on) end
    return d
end

-- CBC Peripheral / CC Optical: angles are set directly and apply at once.
local function directDriver(mount)
    local d = { name = "direct" }
    function d.read()
        return {
            assembled = mount.isRunning(), yaw = mount.getYaw(), pitch = mount.getPitch(),
            yawRate = math.huge, pitchRate = math.huge,
        }
    end
    function d.point(yaw, pitch)
        -- each costs a tick: together they land in the same one
        parallel.waitForAll(function() mount.setYaw(yaw) end, function() mount.setPitch(pitch) end)
    end
    function d.assemble() return mount.assemble() or mount.isRunning() end
    function d.disassemble() return mount.disassemble() end
    function d.pull() return mount.fire() ~= false end
    function d.setFiring() error("gun: this mount can only fire single shots", 0) end
    return d
end

local function makeDriver(mount)
    if mount == nil then return nil end
    if type(mount) == "string" then
        local wrapped = peripheral.wrap(mount)
        if not wrapped then error(("gun: no peripheral named '%s'"):format(mount), 4) end
        mount = wrapped
    end
    if type(mount) ~= "table" then error("gun: mount must be a peripheral or its name", 4) end
    if mount.setTargetAngles and mount.getInfo then return smoothDriver(mount) end
    if mount.setYaw and mount.setPitch then return directDriver(mount) end
    error("gun: unsupported mount peripheral (needs setTargetAngles or setYaw/setPitch)", 4)
end

---------------------------------------------------------------------------
-- Target prediction

local function emptyTrack(id) return { id = id, samples = {} } end

-- Least-squares velocity over the samples, blocks per tick.
local function fitVelocity(samples)
    local n = #samples
    if n < 2 then return { 0, 0, 0 } end
    local st = 0
    for _, s in ipairs(samples) do st = st + s[1] end
    local tm, stt, v = st / n, 0, { 0, 0, 0 }
    for _, s in ipairs(samples) do
        local dt = s[1] - tm
        stt = stt + dt * dt
        for i = 1, 3 do v[i] = v[i] + dt * s[i + 1] end
    end
    if stt <= 0 then return { 0, 0, 0 } end
    return scale(v, 1 / stt)
end

-- Turns what the caller gave into { x, y, z, velocity } for this tick. Velocity
-- comes from the target or is estimated from its positions. A position that
-- did not change yet is carried forward by that velocity.
local function predict(cannon, target)
    local cfg = gun.config
    local p = vec(target)
    if type(p[1]) ~= "number" or type(p[2]) ~= "number" or type(p[3]) ~= "number" then
        error("gun: target needs numeric x, y, z", 0)
    end
    local t, id = now(), target.uuid or target.id
    local track = cannon.track
    if not track or (id ~= nil and id ~= track.id) then
        track = emptyTrack(id)
        cannon.track = track
    end

    local last = track.samples[#track.samples]
    local moved = not last or p[1] ~= last[2] or p[2] ~= last[3] or p[3] ~= last[4]
    if last and moved then
        local dt = math.max(1, t - last[1])
        if len(sub(p, { last[2], last[3], last[4] })) / dt > cfg.maxTargetSpeed then
            track = emptyTrack(id) -- jumped: somebody else's coordinates
            cannon.track = track
            last = nil
        end
    end
    if moved then track.changed = t end
    if moved or t - last[1] >= cfg.staleTicks then
        local sample = { t, p[1], p[2], p[3] }
        if last and last[1] == t then
            track.samples[#track.samples] = sample
        else
            track.samples[#track.samples + 1] = sample
        end
    end
    local samples = track.samples
    while #samples > 2 and t - samples[1][1] > cfg.velocityWindow do
        table.remove(samples, 1)
    end

    local v = vec(target.velocity) or fitVelocity(samples)
    local at = add(p, scale(v, math.min(t - track.changed, cfg.maxAge)))
    return { x = at[1], y = at[2], z = at[3], velocity = { x = v[1], y = v[2], z = v[3] } }
end

---------------------------------------------------------------------------
-- Cannons

local Cannon = {}
Cannon.__index = Cannon

-- World-space description of the cannon right now, for ballistics. Pose and
-- velocities are read in one tick, otherwise they would not match.
local function readSite(cannon)
    local o = cannon.position and vec(cannon.position) or vec(cannon.offset)
    if not o or type(o[1]) ~= "number" or type(o[2]) ~= "number" or type(o[3]) ~= "number" then
        error("gun: offset must be {dx, dy, dz} (mount block - computer block)", 0)
    end
    local top = vec(cannon.pivotOffset)
    local block = add(o, { top[1] + 0.5, top[2] + 0.5, top[3] + 0.5 })

    if onStructure() then
        if cannon.position then
            error("gun: position is for ground cannons, on a structure use offset", 0)
        end
        if not host.structure or host.structure.uuid ~= structureCache.uuid then
            calibrateStructure()
        end
        local pose, v, w
        parallel.waitForAll(
            function() pose = readPose() end,
            function() v = vec(sublevel.getVelocity()) end,   -- blocks/s at the computer
            function()
                local ok, r = pcall(sublevel.getAngularVelocity) -- rad/s, structure axes
                if ok and type(r) == "table" then w = vec(r) end
            end
        )
        local b = host.structure.block
        local computer = toWorld(pose, { b[1] + 0.5, b[2] + 0.5, b[3] + 0.5 })
        local omega = w and rotate(pose.q, w)
        return {
            pivot = toWorld(pose, add(b, block)),
            orientation = pose.q,
            mode = "structure",
            velocity = function(p)
                local at = v
                if omega then at = add(v, cross(omega, sub(p, computer))) end
                return scale(at, 0.05)
            end,
        }
    end

    if cannon.position then return { pivot = block, mode = "manual" } end
    if not host.ground then calibrateGround() end
    return { pivot = add(host.ground, block), mode = "ground" }
end

--- World position of the barrel's pivot: {x, y, z}, mode.
function Cannon:pivot()
    local site = readSite(self)
    return { x = site.pivot[1], y = site.pivot[2], z = site.pivot[3] }, site.mode
end

--- Change the mount position. Same as changing cannon.offset.
function Cannon:setOffset(dx, dy, dz)
    self.offset = { dx, dy, dz }
end

--- Just the calculation: no mount needed, nothing moves.
function Cannon:solve(target, opts)
    opts = opts or {}
    return self.profile:solve(target, readSite(self), {
        arc = opts.arc or self.arc, latency = opts.latency or 0,
    })
end

--- Where the shell goes after a solution, tick by tick.
function Cannon:trajectory(solution, ticks)
    return self.profile:trajectory(solution, ticks)
end

--- Forget the target's history. update() does it by itself when target.uuid
-- changes or the position jumps.
function Cannon:reset()
    self.track = nil
end

local function driverOf(cannon)
    return cannon.driver or error("gun: this cannon has no mount", 0)
end

--- Assemble the cannon; a mount turns only when assembled. Returns true if it is.
function Cannon:assemble()
    return driverOf(self).assemble() == true
end

--- Disassemble the cannon back into blocks.
function Cannon:disassemble()
    return driverOf(self).disassemble()
end

-- Moving average of a delay in ticks, at least one.
local function average(old, ticks)
    ticks = math.max(1, ticks)
    return old and (old + ticks) / 2 or ticks
end

--- Fire one shot. Returns true, or false and the reason.
function Cannon:fire()
    local driver = driverOf(self)
    local t = now()
    local ok, res = pcall(driver.pull)
    if not ok then return false, tostring(res) end
    self.fireTicks = average(self.fireTicks, now() - t)
    if driver.release then
        sleep(0)
        driver.release()
    end
    if res == false then return false, "not assembled" end
    return true
end

--- Hold the trigger: an autocannon keeps firing while on. CC:CBC mounts only.
function Cannon:setFiring(on)
    driverOf(self).setFiring(on == true)
end

-- Barrel error left against a solution after turning for some ticks, in
-- degrees of real angle (0 ticks = the error now).
local function angleError(info, s, turnTicks)
    local function left(angle, rate)
        if turnTicks > 0 and rate == math.huge then return 0 end
        return math.max(0, math.abs(angle) - rate * turnTicks)
    end
    local dyaw = left(wrap180(s.yaw - info.yaw), info.yawRate) * math.cos(math.rad(info.pitch))
    local dpitch = left(s.pitch - info.pitch, info.pitchRate)
    return math.sqrt(dyaw * dyaw + dpitch * dpitch)
end

-- Ticks the mount needs to reach a solution; inf when a shaft that has to move stands.
local function slewTicks(info, s)
    local function ticks(angle, rate)
        if math.abs(angle) < 0.01 then return 0 end
        return math.abs(angle) / rate
    end
    return math.max(ticks(wrap180(s.yaw - info.yaw), info.yawRate), ticks(s.pitch - info.pitch, info.pitchRate))
end

local function step(self, target, opts)
    local driver = driverOf(self)
    if type(target) == "function" then target = target() end
    if target == nil then return { ok = false, reason = "no target", onTarget = false } end
    if type(target) ~= "table" then error("gun: target must be a table or a function", 0) end
    local aimed = predict(self, target)
    local t0 = now()

    local site, info
    parallel.waitForAll(
        function() site = readSite(self) end,
        function() info = driver.read() end
    )
    -- The cannon was read later than the target: bring the target up to it.
    local read = now() - t0
    aimed = {
        x = aimed.x + aimed.velocity.x * read,
        y = aimed.y + aimed.velocity.y * read,
        z = aimed.z + aimed.velocity.z * read,
        velocity = aimed.velocity,
    }

    -- A shot fired right after this call leaves once the command and the
    -- trigger have gone through. Both cost game ticks, how many depends on the
    -- server, so they are measured.
    local commandTicks = self.commandTicks or 1
    local fireTicks = self.fireTicks or commandTicks
    local latency = opts.latency or (commandTicks + fireTicks + gun.config.latency)
    local arc = opts.arc or self.arc
    local s = self.profile:solve(aimed, site, { arc = arc, latency = latency })

    -- The shot cannot leave before the barrel gets there: lead the target for
    -- that moment.
    if s.yaw then
        local slew = slewTicks(info, s)
        if commandTicks + slew > latency and slew < math.huge then
            local later = self.profile:solve(aimed, site, { arc = arc, latency = commandTicks + slew })
            if later.ok then s = later end
        end
    end
    s.mode, s.target, s.onTarget = site.mode, aimed, false
    if not info.assembled then
        s.ok, s.reason = false, "not assembled"
    end
    if not s.ok then return s end

    -- The barrel is compared with where it will be when such a shot leaves. Its
    -- position now would always trail a moving target by one step and never
    -- count as on target.
    local range = len(sub(vec(s.aimPoint), vec(s.muzzle)))
    s.error = angleError(info, s, 0)
    s.miss = math.rad(angleError(info, s, fireTicks)) * range
    s.slew = slewTicks(info, s)
    s.onTarget = s.miss <= self.tolerance
    if s.slew == math.huge and not s.onTarget then
        s.reason = "mount shaft is not turning"
    end
    local t1 = now()
    driver.point(s.yaw, s.pitch, info)
    -- taking over control is one more call, only the first time
    if info.control ~= false then
        self.commandTicks = average(self.commandTicks, now() - t1)
    end
    return s
end

--- One tracking step: predict the target, solve, turn the mount. Call it as
-- often as you like, or use follow().
-- target: {x, y, z[, velocity][, uuid]} or a function returning one (nil = no
-- target this time). A table may be changed by another program between calls.
-- opts: arc, latency (ticks).
-- Returns the solution from ballistics plus: onTarget (a shot fired right after
-- this call hits), miss (blocks at the target for such a shot), error (degrees
-- off now), slew (ticks to turn), target (the predicted one). On failure
-- ok = false and reason says why; the mount stays where it is.
function Cannon:update(target, opts)
    local ok, res = pcall(step, self, target, opts or {})
    if not ok then res = { ok = false, reason = tostring(res), onTarget = false } end
    self.last = res
    return res
end

local function asTarget(x, y, z, opts)
    if type(x) == "number" then return { x = x, y = y, z = z }, opts or {} end
    return x, y or {}
end

local function isStatic(target)
    return type(target) == "table" and target.velocity == nil
end

--- Turn to a point or a target: aimAt(x, y, z, opts) or aimAt(target, opts).
-- opts.wait = true: keep correcting until on target, then return.
-- opts.timeout: how long to wait, ticks (config.aimTimeout).
function Cannon:aimAt(x, y, z, o)
    local target, opts = asTarget(x, y, z, o)
    self:reset()
    self.stopped = false
    local state = self:update(target, opts)
    if not opts.wait then return state end

    local deadline = now() + (opts.timeout or gun.config.aimTimeout)
    while not state.onTarget and not self.stopped do
        if state.reason and (isStatic(target) or state.reason == "mount shaft is not turning") then
            return state -- will not get better by waiting
        end
        if now() >= deadline then
            state.ok, state.reason = false, "timeout"
            return state
        end
        sleep(0)
        state = self:update(target, opts)
    end
    return state
end

--- Aim and fire one shot; same arguments as aimAt, it always waits. A moving
-- target works too. state.fired tells if the shot went.
function Cannon:fireAt(x, y, z, o)
    local target, opts = asTarget(x, y, z, o)
    local waiting = {}
    for k, v in pairs(opts) do waiting[k] = v end
    waiting.wait = true
    local state = self:aimAt(target, waiting)
    if state.onTarget then
        state.fired, state.fireError = self:fire()
    else
        state.fired = false
    end
    return state
end

--- Keep tracking until stop() or the end of a callback. Blocks, so run it in
-- parallel with the rest of the program.
-- opts: interval (ticks between steps, 1), timeout (ticks), arc, latency,
-- onUpdate = function(state): return false to stop.
-- Returns the last state.
function Cannon:follow(target, opts)
    opts = opts or {}
    self.stopped = false
    local interval = math.max(1, opts.interval or 1)
    local deadline = opts.timeout and now() + opts.timeout
    local state
    while true do
        state = self:update(target, opts)
        if opts.onUpdate and opts.onUpdate(state) == false then break end
        if self.stopped or (deadline and now() >= deadline) then break end
        sleep(interval * 0.05)
    end
    return state
end

--- Stop follow() and a waiting aimAt() / fireAt().
function Cannon:stop()
    self.stopped = true
end

local function newCannon(spec, make)
    if type(spec) ~= "table" then error("gun: bad argument #1 (table expected)", 3) end
    local profile = make(spec)
    return setmetatable({
        profile = profile,
        kind = profile.kind,
        speed = profile.speed,
        driver = makeDriver(spec.mount),
        offset = spec.offset,
        position = spec.position,
        pivotOffset = spec.pivotOffset or { 0, 1, 0 },
        arc = spec.arc or "auto",
        tolerance = spec.tolerance or gun.config.tolerance,
    }, Cannon)
end

-- Common spec: mount (peripheral or name), offset = {dx, dy, dz} (mount block -
-- computer block, structure axes on a Sable structure) or position = {x, y, z}
-- (mount block in the world, ground only, no GPS needed), pivotOffset ({0, 1, 0}),
-- arc ("auto"), tolerance (blocks), limits. The rest is as in ballistics.

--- Big cannon: see ballistics.bigCannon.
function gun.bigCannon(spec) return newCannon(spec, ballistics.bigCannon) end

--- Autocannon: see ballistics.autocannon.
function gun.autocannon(spec) return newCannon(spec, ballistics.autocannon) end

--- Heavy autocannon: see ballistics.heavyAutocannon.
function gun.heavyAutocannon(spec) return newCannon(spec, ballistics.heavyAutocannon) end

return gun
