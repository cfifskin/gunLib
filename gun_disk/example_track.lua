-- Example: keep a cannon on the nearest structure seen by a radar. The gun
-- library itself does not need the radar: any function that returns
-- { x, y, z } works, the velocity is then estimated from the positions.
package.path = "/lib/?.lua;" .. package.path -- works even if the startup loader is missing or old
local gun = require("gun")
local radar = require("radar") -- only this example needs it

local sensor = peripheral.find("entity_radar") or error("No entity_radar attached", 0)
local mount = peripheral.find("cannon_mount") or peripheral.find("cbc_cannon_mount")
    or error("No cannon mount attached (CC:CBC, CBC Peripheral or CC Optical)", 0)

-- Positions relative to this computer: block - computer block, counted along
-- the structure's own blocks when the computer is on a Sable structure.
radar.setOffset(sensor, 0, 1, 0)
local cannon = gun.bigCannon({
    mount = mount,
    offset = { 2, 0, -3 },
    length = 8,
    muzzle = 5,
    charges = { "powder", "powder", "mk3" },
    shell = "he_shell",
})
if not cannon:assemble() then error("The cannon did not assemble", 0) end

local FIRE = false       -- true = fire whenever on target
local RELOAD_TICKS = 100 -- ticks between shots
local nextShot = 0

local function nearest()
    local ok, targets = pcall(radar.scan, sensor, "sublevel", true)
    if not ok then
        printError(targets)
        return nil
    end
    table.sort(targets, function(a, b) return a.distance < b.distance end)
    return targets[1]
end

cannon:follow(nearest, {
    onUpdate = function(state)
        if not state.ok then
            print("waiting: " .. state.reason)
            return
        end
        print(("yaw %.1f pitch %.1f miss %.1f flight %.0f"):format(state.yaw, state.pitch, state.miss, state.ticks))
        if FIRE and state.onTarget and os.clock() * 20 >= nextShot then
            local fired, why = cannon:fire()
            if not fired then printError(why) end
            nextShot = os.clock() * 20 + RELOAD_TICKS
        end
    end,
})
