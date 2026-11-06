-- Example: one shot at coordinates. No radar needed.
-- Usage: gun_aim_example <x> <y> <z>
package.path = "/lib/?.lua;" .. package.path -- works even if the startup loader is missing or old
local gun = require("gun")

local args = { ... }
local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
if not z then error("Usage: gun_aim_example <x> <y> <z>", 0) end

local mount = peripheral.find("cannon_mount") or peripheral.find("cbc_cannon_mount")
    or error("No cannon mount attached (CC:CBC, CBC Peripheral or CC Optical)", 0)

-- The computer's own block. Remove this line to get it from GPS, which is
-- required on a Sable structure.
-- gun.setHost(100, 64, 200)

local cannon = gun.bigCannon({
    mount = mount,
    offset = { 2, 0, -3 },                     -- mount block - computer block
    length = 8,                                -- cannon blocks in front of the breech
    muzzle = 5,                                -- block above the mount -> muzzle block
    charges = { "powder", "powder", "mk3" },   -- from the breech forward
    shell = "he_shell",
})
-- cannon = gun.autocannon({ mount = mount, offset = { 2, 0, -3 }, material = "steel", barrels = 4, muzzle = 3, round = "ap" })
-- cannon = gun.heavyAutocannon({ mount = mount, offset = { 2, 0, -3 }, material = "steel", barrels = 6, muzzle = 5, round = "apds", strong = true })
print(("muzzle speed %.2f blocks/tick"):format(cannon.speed))

if not cannon:assemble() then error("The cannon did not assemble", 0) end

local state = cannon:fireAt(x, y, z)
if state.fired then
    print(("Fired: yaw %.2f pitch %.2f, flight %.1f ticks"):format(state.yaw, state.pitch, state.ticks))
else
    print("No shot: " .. tostring(state.fireError or state.reason))
end
