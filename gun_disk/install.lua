-- Installs the gun library from this disk.
-- Usage: install              install or update
--        install remove       uninstall (same as uninstall)
--        install remove all   uninstall together with the examples
local args = { ... }
local here = fs.getDir(shell.getRunningProgram())

local BALLISTICS = "lib/ballistics.lua"
local GUN = "lib/gun.lua"
local LOADER = "startup/00_gunlib.lua"
local HELP = "help/gunLib.md"
local AIM_EXAMPLE = "gun_aim_example.lua"
local TRACK_EXAMPLE = "gun_track_example.lua"

if args[1] == "remove" then
    shell.run("/" .. fs.combine(here, "uninstall.lua"), args[2] or "")
    return
end

if fs.exists("startup") and not fs.isDir("startup") then
    printError("/startup is a file. Rename it to /startup.lua and run install again.")
    return
end

local function copy(from, to)
    if fs.exists(to) then fs.delete(to) end
    local dir = fs.getDir(to)
    if dir ~= "" then fs.makeDir(dir) end
    fs.copy(fs.combine(here, from), to)
end

copy("ballistics.lua", BALLISTICS)
copy("gun.lua", GUN)
copy("loader.lua", LOADER)
copy("gunLib.md", HELP)
if fs.exists("gunhelp.lua") then fs.delete("gunhelp.lua") end -- replaced by help gunLib
if not fs.exists(AIM_EXAMPLE) then copy("example_aim.lua", AIM_EXAMPLE) end
if not fs.exists(TRACK_EXAMPLE) then copy("example_track.lua", TRACK_EXAMPLE) end

-- Register right away, so no reboot is needed.
shell.run("/" .. LOADER)

print("gun library installed:")
print("  /" .. BALLISTICS)
print("  /" .. GUN)
print("  /" .. LOADER)
print("  /" .. HELP)
print("  /" .. AIM_EXAMPLE .. ", /" .. TRACK_EXAMPLE .. " (examples)")
print('Use: local gun = require("gun")')
print("Help: help gunLib")
print("You can remove the disk now.")
