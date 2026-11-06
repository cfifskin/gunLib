-- Installed as /startup/00_gunlib.lua.
-- CC:Tweaked gives every program its own package.path, but copies
-- debug.getregistry()._LOADED into each program's package.loaded. Registering
-- the libraries there makes require("gun") and require("ballistics") work from
-- any directory.
local MODULES = {
    { "ballistics", "/lib/ballistics.lua" },
    { "gun", "/lib/gun.lua" },
}

local registry = debug and debug.getregistry and debug.getregistry()
if type(registry) ~= "table" then
    printError("gunlib: debug.getregistry is unavailable.")
    printError('Use: package.path = "/lib/?.lua;" .. package.path')
    return
end
if type(registry._LOADED) ~= "table" then registry._LOADED = {} end

-- Modules load in order and may require the ones before them.
local function libRequire(name)
    local lib = registry._LOADED[name]
    if lib == nil then error(("module '%s' not found"):format(name), 2) end
    return lib
end

for _, module in ipairs(MODULES) do
    local name, path = module[1], module[2]
    if fs.exists(path) then
        local env = setmetatable({ require = libRequire }, { __index = _G })
        local fn, err = loadfile(path, nil, env)
        if not fn then
            printError("gunlib: " .. err)
        else
            local ok, lib = pcall(fn, name)
            if ok then
                registry._LOADED[name] = lib
            else
                printError("gunlib: " .. tostring(lib))
            end
        end
    end
end

-- "gunhelp" works from any directory.
if shell and fs.exists("/gunhelp.lua") then shell.setAlias("gunhelp", "/gunhelp.lua") end
