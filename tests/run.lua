-- Tests for the gun library. Run on a CC computer with /lib/ballistics.lua and
-- /lib/gun.lua in place: tests/run [result file]
-- Mounts and CC: Sable are simulated here; the shell is flown by this file's own
-- integrator, so a passing test means "the shell hits", not "the code agrees
-- with itself".
-- Time is virtual: os.clock and sleep are replaced, a simulated server-thread
-- call costs an exact number of ticks. Timing then does not depend on how fast
-- the machine runs (a GameTestServer ticks about ten times too fast).
package.path = "/lib/?.lua;" .. package.path

local outPath = ({ ... })[1]

local virtualTicks, realSleep, realClock, sleeps = 0, _G.sleep, os.clock, 0
os.clock = function() return virtualTicks * 0.05 end
_G.sleep = function(seconds)
    virtualTicks = virtualTicks + math.max(1, math.floor((seconds or 0) * 20 + 0.5))
    sleeps = sleeps + 1
    if sleeps % 100 == 0 then realSleep(0) end -- keep CC happy about yielding
end
local lines, failed, passed = {}, 0, 0
local function log(text)
    lines[#lines + 1] = text
    print(text)
end
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        log("ok   " .. name .. (detail and (" (" .. detail .. ")") or ""))
    else
        failed = failed + 1
        log("FAIL " .. name .. (detail and (" (" .. detail .. ")") or ""))
    end
end

local radarFound = package.searchpath and package.searchpath("radar", package.path) or nil
local gun = require("gun")
local ballistics = require("ballistics")
check("works without radar", radarFound == nil and package.loaded.radar == nil)

local function tick() return math.floor(os.clock() * 20 + 0.5) end

-- Independent flight model: returns the closest approach to targetAt(n), the
-- target position n ticks after the shot.
local function fly(p, v, gravity, drag, quadratic, ticks, targetAt)
    local best, bestN = math.huge, 0
    p, v = { p[1], p[2], p[3] }, { v[1], v[2], v[3] }
    -- A shell covers many blocks per tick: measure along the whole segment, in
    -- the target's frame.
    local function relative(n)
        local t = targetAt(n)
        return { p[1] - t[1], p[2] - t[2], p[3] - t[3] }
    end
    local previous = relative(0)
    local function miss(n)
        local r = relative(n)
        local s = { r[1] - previous[1], r[2] - previous[2], r[3] - previous[3] }
        local ss = s[1] ^ 2 + s[2] ^ 2 + s[3] ^ 2
        local k = 0
        if ss > 0 then
            k = -(previous[1] * s[1] + previous[2] * s[2] + previous[3] * s[3]) / ss
            k = math.max(0, math.min(1, k))
        end
        local c = { previous[1] + s[1] * k, previous[2] + s[2] * k, previous[3] + s[3] * k }
        local d = math.sqrt(c[1] ^ 2 + c[2] ^ 2 + c[3] ^ 2)
        if d < best then best, bestN = d, n end
        previous = r
    end
    for n = 1, ticks do
        local sp = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)
        local dr = quadratic and drag * sp * sp or drag * sp
        if dr > sp then dr = sp end
        local a = { -v[1] / sp * dr, gravity - v[2] / sp * dr, -v[3] / sp * dr }
        for i = 1, 3 do
            p[i] = p[i] + v[i] + a[i] / 2
            v[i] = v[i] + a[i]
        end
        miss(n)
    end
    return best, bestN
end

local function direction(yaw, pitch)
    local y, p = math.rad(yaw), math.rad(pitch)
    return { -math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p) }
end

local function solutionMiss(profile, s, target, velocity)
    local d = { s.direction.x, s.direction.y, s.direction.z }
    local u = s.carrierVelocity
    local v = { d[1] * profile.speed + u.x, d[2] * profile.speed + u.y, d[3] * profile.speed + u.z }
    local w = velocity or { 0, 0, 0 }
    return fly({ s.muzzle.x, s.muzzle.y, s.muzzle.z }, v, profile.gravity, profile.drag, profile.quadratic,
        math.ceil(s.ticks) + 5, function(n)
            return { target[1] + w[1] * n, target[2] + w[2] * n, target[3] + w[3] * n }
        end)
end

---------------------------------------------------------------------------
-- Pure calculator

local big = ballistics.bigCannon({ length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" } })
local site = { pivot = { 0.5, 65.5, 0.5 } }

do
    local s = big:solve({ x = 120, y = 70, z = -80 }, site)
    check("big cannon low arc hits", s.ok and solutionMiss(big, s, { 120, 70, -80 }) < 0.8, s.reason)

    local high = big:solve({ x = 120, y = 70, z = -80 }, site, { arc = "high", })
    check("high arc is steeper", high.yaw and high.pitch > s.pitch + 5 and high.ticks > s.ticks,
        high.pitch and ("%.1f vs %.1f"):format(high.pitch, s.pitch))
    if high.ok then check("high arc hits", solutionMiss(big, high, { 120, 70, -80 }) < 0.8) end

    local v = { 0.8, 0, 0.3 }
    local lead = big:solve({ x = 100, y = 66, z = 60, velocity = v }, site)
    local missed = solutionMiss(big, lead, { 100, 66, 60 }, v)
    check("lead on a moving target hits", lead.ok and missed < 0.8, ("%.2f"):format(missed))

    local heavy = ballistics.heavyAutocannon({ material = "steel", barrels = 6, muzzle = 5, round = "apds", strong = true })
    local hs = heavy:solve({ x = 60, y = 72, z = 40 }, site)
    check("quadratic drag hits", hs.ok and solutionMiss(heavy, hs, { 60, 72, 40 }) < 0.8, hs.reason)

    local far = big:solve({ x = 200000, y = 70, z = 0 }, site)
    check("out of range is reported", far.ok == false and far.reason == "out of range", far.reason)

    local up = big:solve({ x = 1, y = 300, z = 1 }, site)
    check("pitch limit is reported", up.ok == false and tostring(up.reason):find("pitch") ~= nil, up.reason)

    local carried = big:solve({ x = 100, y = 66, z = 0 }, {
        pivot = { 0.5, 65.5, 0.5 },
        velocity = function() return { 0, 0, 1 } end,
    })
    local dr = carried.carrierVelocity
    check("carrier velocity is inherited", carried.ok and dr.z == 1 and solutionMiss(big, carried, { 100, 66, 0 }) < 0.8)
    check("bad target is an error", not pcall(big.solve, big, "here", site))
    local t0 = os.epoch("utc")
    for _ = 1, 20 do big:solve({ x = 120, y = 70, z = -80, velocity = v }, site) end
    log(("info 20 solutions took %d ms"):format(os.epoch("utc") - t0))
end

---------------------------------------------------------------------------
-- Simulated mounts. Calls on the server thread cost a tick, as in the game.

-- CC:CBC: turns towards the target angles at rpm * 0.0375 degrees per tick.
-- lag = ticks one server-thread call takes (1).
local function smoothMount(rpm, onShot, lag)
    local mount = { yaw = 0, pitch = 0, tyaw = 0, tpitch = 0, control = false, assembled = false, level = false, last = tick() }
    local function advance()
        local t = tick()
        local step = (t - mount.last) * rpm * 0.0375
        mount.last = t
        if not mount.control or not mount.assembled then return end
        local dy = (mount.tyaw - mount.yaw + 180) % 360 - 180
        mount.yaw = (mount.yaw + math.max(-step, math.min(step, dy))) % 360
        local dp = mount.tpitch - mount.pitch
        mount.pitch = mount.pitch + math.max(-step, math.min(step, dp))
    end
    local function mainThread()
        for _ = 1, lag or 1 do sleep(0) end
        advance()
    end
    function mount.getInfo()
        mainThread()
        return {
            computerControl = mount.control, assembled = mount.assembled, yaw = mount.yaw, pitch = mount.pitch,
            yawShaftSpeed = rpm, pitchShaftSpeed = -rpm,
        }
    end
    function mount.setComputerControl(on) mainThread() mount.control = on mount.tyaw, mount.tpitch = mount.yaw, mount.pitch end
    function mount.setTargetAngles(y, p) mainThread() mount.tyaw, mount.tpitch = y, p end
    function mount.assemble(on) mainThread() mount.assembled = on return on end
    function mount.fire(on)
        mainThread()
        if on and not mount.level and onShot then onShot(mount.yaw, mount.pitch) end
        mount.level = on
        mount.levels = (mount.levels or "") .. (on and "1" or "0")
        return on
    end
    return mount
end

-- CBC Peripheral: angles apply at once.
local function directMount(onShot)
    local mount = { y = 0, p = 0, running = false }
    function mount.isRunning() return mount.running end
    function mount.getYaw() return mount.y end
    function mount.getPitch() return mount.p end
    -- the library calls these two in parallel: one tick for both, as in the game
    function mount.setYaw(v) mount.y = v end
    function mount.setPitch(v) sleep(0) mount.p = v end
    function mount.assemble() sleep(0) mount.running = true return true end
    function mount.disassemble() sleep(0) mount.running = false return true end
    function mount.fire() sleep(0) if onShot then onShot(mount.y, mount.p) end end
    return mount
end

local SPEC = { length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" }, position = { 0, 64, 0 } }
local function cannonWith(mount, extra)
    local spec = { mount = mount }
    for k, v in pairs(SPEC) do spec[k] = v end
    for k, v in pairs(extra or {}) do spec[k] = v end
    return gun.bigCannon(spec)
end

-- Flies a shell from a real barrel position; returns the miss.
local function shoot(cannon, yaw, pitch, targetAt, carrier, pivot)
    local d = direction(yaw, pitch)
    local p = pivot or { 0.5, 65.5, 0.5 }
    local u = carrier or { 0, 0, 0 }
    local from = { p[1] + d[1] * 5, p[2] + d[2] * 5, p[3] + d[3] * 5 }
    local v = { d[1] * cannon.speed + u[1], d[2] * cannon.speed + u[2], d[3] * cannon.speed + u[3] }
    return fly(from, v, cannon.profile.gravity, cannon.profile.drag, false, 400, targetAt)
end

---------------------------------------------------------------------------
-- Single shots at coordinates

do
    local missed
    local cannon
    local mount = smoothMount(256, function(y, p)
        missed = shoot(cannon, y, p, function() return { 120, 70, -80 } end)
    end)
    cannon = cannonWith(mount)
    check("assemble", cannon:assemble())
    local state = cannon:fireAt(120, 70, -80)
    check("smooth mount: fireAt", state.fired == true and state.onTarget, state.reason)
    check("smooth mount: shell hits", missed and missed < 1.5, missed and ("%.2f"):format(missed))
    check("fire is a pulse", mount.levels == "10", mount.levels)
    check("mount delays are measured", cannon.commandTicks >= 1 and cannon.fireTicks >= 1,
        ("command %.1f, fire %.1f ticks"):format(cannon.commandTicks or -1, cannon.fireTicks or -1))
    check("takes computer control", mount.control)
end

do
    local missed
    local cannon
    local mount = directMount(function(y, p)
        missed = shoot(cannon, y, p, function() return { -90, 60, 110 } end)
    end)
    cannon = cannonWith(mount)
    cannon:assemble()
    local state = cannon:fireAt({ x = -90, y = 60, z = 110 })
    check("direct mount: fireAt", state.fired == true, state.reason)
    check("direct mount: shell hits", missed and missed < 1.5, missed and ("%.2f"):format(missed))
end

do
    local mount = smoothMount(256)
    local cannon = cannonWith(mount)
    local state = cannon:aimAt(120, 70, -80)
    check("not assembled is reported", state.ok == false and state.reason == "not assembled", state.reason)
    check("not assembled does not move", mount.tyaw == 0 and not mount.control)
    state = cannon:fireAt(120, 70, -80)
    check("no shot when not assembled", state.fired == false and mount.levels == nil)

    cannon:assemble()
    state = cannon:fireAt(200000, 70, 0)
    check("out of range: no shot, no wait", state.fired == false and state.reason == "out of range", state.reason)
end

do
    local mount = smoothMount(0)
    local cannon = cannonWith(mount)
    cannon:assemble()
    local state = cannon:fireAt(120, 70, -80)
    check("standing shaft is reported", state.fired == false and state.reason == "mount shaft is not turning", state.reason)
end

do
    local mount = smoothMount(8) -- 0.3 degrees per tick
    local cannon = cannonWith(mount)
    cannon:assemble()
    local state = cannon:aimAt(120, 70, -80, { wait = true, timeout = 10 })
    check("timeout", state.ok == false and state.reason == "timeout", state.reason)
    local quick = cannon:aimAt(120, 70, -80)
    check("aimAt without wait returns at once", quick.ok and not quick.onTarget and quick.slew > 1)
end

do
    local bad = {}
    function bad.setTargetAngles() end
    function bad.getInfo() error("peripheral detached", 0) end
    local cannon = cannonWith(bad)
    local state = cannon:update({ x = 120, y = 70, z = -80 })
    check("mount errors become a reason", state.ok == false and state.reason:find("detached") ~= nil, state.reason)
    check("unsupported mount is refused", not pcall(gun.bigCannon, { mount = {}, position = { 0, 0, 0 }, charges = { "powder" } }))
    local noMount = gun.bigCannon({ position = { 0, 64, 0 }, length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" } })
    local s = noMount:solve({ x = 120, y = 70, z = -80 })
    check("calculator works without a mount", s.ok == true, s.reason)
end

---------------------------------------------------------------------------
-- Moving targets

-- Target crossing in front of the cannon, position by tick.
local function crossing(start, speed)
    return function(t)
        local n = t - start
        return { 100 + 0.2 * speed * n, 70, -60 + speed * n }
    end
end

-- Tracks for a while, fires once when settled, measures the real miss.
local function engage(name, mount, speedOf, make)
    local start = tick()
    local path = speedOf(start)
    local cannon, fired, missed, firedAt
    local function onShot(y, p)
        firedAt = tick()
        missed = shoot(cannon, y, p, function(n) return path(firedAt + n) end)
    end
    local m = mount(onShot)
    cannon = cannonWith(m)
    cannon:assemble()
    local onTargetCount, steps = 0, 0
    local state = cannon:follow(make(path, cannon), {
        timeout = 90,
        onUpdate = function(s)
            steps = steps + 1
            if s.onTarget then onTargetCount = onTargetCount + 1 end
            if s.onTarget and not fired and tick() - start > 40 then
                fired = cannon:fire()
                return false
            end
        end,
    })
    check(name .. ": on target", onTargetCount > 0, ("%d of %d steps"):format(onTargetCount, steps))
    check(name .. ": shell hits", fired and missed and missed < 2.5,
        ("miss %s, reason %s"):format(missed and ("%.2f"):format(missed) or "-", tostring(state.reason)))
end

engage("function, known velocity", function(f) return smoothMount(256, f) end, function(s) return crossing(s, 1) end,
    function(path)
        return function()
            local p = path(tick())
            return { x = p[1], y = p[2], z = p[3], velocity = { x = 0.2, y = 0, z = 1 } }
        end
    end)

engage("function, velocity estimated", function(f) return smoothMount(256, f) end, function(s) return crossing(s, 1) end,
    function(path)
        return function()
            local p = path(tick())
            return { x = p[1], y = p[2], z = p[3] }
        end
    end)

engage("slow mount", function(f) return smoothMount(64, f) end, function(s) return crossing(s, 0.6) end,
    function(path)
        return function()
            local p = path(tick())
            return { x = p[1], y = p[2], z = p[3] }
        end
    end)

engage("direct mount", function(f) return directMount(f) end, function(s) return crossing(s, 1) end,
    function(path)
        return function()
            local p = path(tick())
            return { x = p[1], y = p[2], z = p[3] }
        end
    end)

engage("laggy server", function(f) return smoothMount(256, f, 4) end, function(s) return crossing(s, 1) end,
    function(path)
        return function()
            local p = path(tick())
            return { x = p[1], y = p[2], z = p[3], velocity = { x = 0.2, y = 0, z = 1 } }
        end
    end)

-- A table that another program refreshes once a second: between refreshes
-- the position is carried forward by the velocity.
do
    local start = tick()
    local path = crossing(start, 1)
    local shared, refreshed = {}, -math.huge
    local function refresh()
        if tick() - refreshed < 20 then return end
        refreshed = tick()
        local p = path(refreshed)
        shared.x, shared.y, shared.z = p[1], p[2], p[3]
        shared.velocity = { x = 0.2, y = 0, z = 1 }
    end
    refresh()
    local cannon, missed
    local mount = smoothMount(256, function(y, p)
        local at = tick()
        missed = shoot(cannon, y, p, function(n) return path(at + n) end)
    end)
    cannon = cannonWith(mount)
    cannon:assemble()
    local fired
    cannon:follow(shared, {
        timeout = 90,
        onUpdate = function(s)
            refresh()
            -- fire between refreshes, when the position is the oldest
            if s.onTarget and tick() - start > 50 and tick() - refreshed > 10 then
                fired = cannon:fire()
                return false
            end
        end,
    })
    check("shared table: shell hits", fired and missed and missed < 2.5, missed and ("%.2f"):format(missed))
end

-- The target turns: the cannon must keep following it.
do
    local start = tick()
    local function path(t)
        local a = (t - start) * 0.02
        return { 110 * math.cos(a), 70, 110 * math.sin(a) }
    end
    local cannon, misses = nil, {}
    local mount = smoothMount(256, function(y, p)
        local at = tick()
        misses[#misses + 1] = shoot(cannon, y, p, function(n) return path(at + n) end)
    end)
    cannon = cannonWith(mount)
    cannon:assemble()
    local nextShot = start + 30
    cannon:follow(function()
        local p = path(tick())
        return { x = p[1], y = p[2], z = p[3] }
    end, {
        timeout = 240,
        onUpdate = function(s)
            if s.onTarget and tick() >= nextShot then
                cannon:fire()
                nextShot = tick() + 30
            end
        end,
    })
    local worst = 0
    for _, v in ipairs(misses) do worst = math.max(worst, v) end
    check("circling target: every shell hits", #misses >= 5 and worst < 3,
        ("%d shots, worst miss %.2f"):format(#misses, worst))
end

do
    local start = tick()
    local path = crossing(start, 1)
    local cannon, missed
    local mount = smoothMount(256, function(y, p)
        local at = tick()
        missed = shoot(cannon, y, p, function(n) return path(at + n) end)
    end)
    cannon = cannonWith(mount)
    cannon:assemble()
    local p = path(tick())
    local state = cannon:fireAt({ x = p[1], y = p[2], z = p[3], velocity = { x = 0.2, y = 0, z = 1 } })
    -- fireAt with a constant table: the prediction carries it forward
    check("fireAt on a moving target", state.fired == true and missed and missed < 2.5,
        missed and ("%.2f"):format(missed) or tostring(state.reason))
end

do
    local mount = smoothMount(256)
    local cannon = cannonWith(mount)
    cannon:assemble()
    local points = { { x = 100, y = 70, z = 0 }, { x = 101, y = 70, z = 0 }, { x = 102, y = 70, z = 0 } }
    for _, p in ipairs(points) do
        cannon:update({ x = p.x, y = p.y, z = p.z, uuid = "a" })
    end
    local moving = cannon:update({ x = 103, y = 70, z = 0, uuid = "a" })
    local fresh = cannon:update({ x = 0, y = 70, z = 100, uuid = "b" })
    check("velocity estimated for a target", moving.target.velocity.x > 0.05, ("%.3f"):format(moving.target.velocity.x))
    check("new uuid forgets the old target", fresh.target.velocity.x == 0 and fresh.target.z == 100)
    local jump = cannon:update({ x = -100, y = 70, z = -100, uuid = "b" })
    check("a jump is not a velocity", jump.target.velocity.x == 0, ("%.3f"):format(jump.target.velocity.x))

    local lost = cannon:update(function() return nil end)
    check("lost target keeps the mount", lost.ok == false and lost.reason == "no target")

    local stopper = 0
    local last = cannon:follow({ x = 100, y = 70, z = 0 }, {
        onUpdate = function()
            stopper = stopper + 1
            if stopper == 3 then cannon:stop() end
        end,
    })
    check("stop() ends follow", stopper == 3 and last ~= nil)
end

---------------------------------------------------------------------------
-- Sable structure, simulated: turned 90 degrees, flying along +X

do
    local q = { x = 0, y = math.sqrt(0.5), z = 0, w = math.sqrt(0.5) }
    local origin = { 500, 100, 500 }
    local savedGps, savedSublevel = gps.locate, _G.sublevel
    local start = tick()
    local speed = 0.5 -- blocks per tick along world +X
    local function shifted() return (tick() - start) * speed end
    _G.sublevel = {
        isInPlotGrid = function() return true end,
        getUniqueId = function() return "ship" end,
        getLogicalPose = function()
            return {
                position = { x = origin[1] + shifted(), y = origin[2], z = origin[3] },
                orientation = q,
                scale = { x = 1, y = 1, z = 1 },
                rotationPoint = { x = 0, y = 0, z = 0 },
            }
        end,
        getVelocity = function() return { x = speed * 20, y = 0, z = 0 } end,
        getAngularVelocity = function() return { x = 0, y = 0, z = 0 } end,
    }
    -- The computer sits at structure block (0, 0, 0): the world point of its corner.
    gps.locate = function() return origin[1] + shifted(), origin[2], origin[3] end
    gun.calibrate()

    local cannon, missed
    local mount = smoothMount(256, function(y, p)
        -- barrel direction from structure axes to world axes
        local d = direction(y, p)
        local r = ballistics.math.rotate(q, d)
        local pivotWorld = ballistics.math.rotate(q, { 2.5, 1.5, 3.5 })
        local at = shifted()
        local from = { origin[1] + at + pivotWorld[1] + r[1] * 5, origin[2] + pivotWorld[2] + r[2] * 5, origin[3] + pivotWorld[3] + r[3] * 5 }
        local v = { r[1] * cannon.speed + speed, r[2] * cannon.speed, r[3] * cannon.speed }
        missed = fly(from, v, cannon.profile.gravity, cannon.profile.drag, false, 400, function() return { 640, 90, 420 } end)
    end)
    cannon = gun.bigCannon({ mount = mount, offset = { 2, 0, 3 }, length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" } })
    cannon:assemble()
    local state = cannon:fireAt(640, 90, 420)
    check("on a flying structure: shot", state.fired == true, state.reason)
    check("on a flying structure: mode", state.mode == "structure", state.mode)
    check("on a flying structure: shell hits", missed and missed < 2.5, missed and ("%.2f"):format(missed))
    local wrong = pcall(function() end)
    local onShip = gun.bigCannon({ position = { 0, 0, 0 }, length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" } })
    local ok = pcall(onShip.solve, onShip, { x = 1, y = 2, z = 3 })
    check("position is refused on a structure", wrong and not ok)

    -- back on the ground; calibrate() also drops the "on a structure" cache
    _G.sublevel.isInPlotGrid = function() return false end
    gun.calibrate()
    gps.locate, _G.sublevel = savedGps, savedSublevel
end

---------------------------------------------------------------------------
-- Ground with an offset from the computer

do
    gun.setHost(10, 64, 20)
    local cannon = gun.bigCannon({ offset = { 2, 0, -3 }, length = 8, muzzle = 5, charges = { "powder", "powder", "mk3" } })
    local pivot, mode = cannon:pivot()
    check("offset from the computer", pivot.x == 12.5 and pivot.y == 65.5 and pivot.z == 17.5 and mode == "ground")
    gun.setHost(nil)
end

log(("done: %d passed, %d failed"):format(passed, failed))
os.clock, _G.sleep = realClock, realSleep
if outPath then
    local tmp = outPath .. ".tmp"
    local f = fs.open(tmp, "w")
    for _, line in ipairs(lines) do f.writeLine(line) end
    f.close()
    fs.move(tmp, outPath)
end
