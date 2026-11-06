-- One-command installer, downloads the library from GitHub:
--   wget run https://raw.githubusercontent.com/cfifskin/gunLib/main/gun_disk/get.lua
-- With a directory argument the files are kept there, e.g. to make an
-- installer floppy:
--   wget run https://raw.githubusercontent.com/cfifskin/gunLib/main/gun_disk/get.lua disk
local BASE = "https://raw.githubusercontent.com/cfifskin/gunLib/main/gun_disk/"
local FILES = {
    "ballistics.lua", "gun.lua", "install.lua", "uninstall.lua", "loader.lua", "startup.lua", "gunhelp.lua",
    "example_aim.lua", "example_track.lua",
}

local args = { ... }
local keep = args[1]
local dir
if keep then
    dir = fs.combine(keep, "")
    if not fs.isDir(dir) then
        printError(("No directory '%s' (is the disk inserted?)"):format(keep))
        return
    end
else
    dir = ".gunlib_tmp"
    fs.delete(dir)
    fs.makeDir(dir)
end

for _, name in ipairs(FILES) do
    write("Downloading " .. name .. "... ")
    local response, err = http.get(BASE .. name, nil, true)
    if not response then
        printError(err or "failed")
        if not keep then fs.delete(dir) end
        return
    end
    local data = response.readAll()
    response.close()
    local file = fs.open(fs.combine(dir, name), "wb")
    file.write(data)
    file.close()
    print("OK")
end

shell.run("/" .. fs.combine(dir, "install.lua"))
if not keep then fs.delete(dir) end

if not fs.exists("lib/gun.lua") then
    printError("Installation failed.")
elseif keep then
    print("Installer kept in /" .. dir)
end
