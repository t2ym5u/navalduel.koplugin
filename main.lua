local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

-- Shared modules (common/) are cached by name for every plugin at once: the
-- guard makes sure an outdated copy, loaded by an old plugin still installed,
-- is not the one this plugin gets (see common/module_guard.lua). Loaded by
-- path, so no other plugin's copy can stand in for it.
local function noop() end
local guard_chunk = loadfile(_dir .. "common/module_guard.lua")
local guard = guard_chunk and guard_chunk()(_dir .. "common/", "game_common_version.lua")
    or { enter = noop, leave = noop }
guard.enter()

-- The game screen -- and the boards, word lists and puzzle banks it pulls
-- in -- loads the first time the game is opened, not when KOReader starts:
-- KOReader loads every plugin at startup and keeps it all session, so a
-- top-level require here costs memory even if the game is never played.
-- KOReader has put package.path back by then, so our directories are added
-- again while the module loads (common/ stays as a fallback for the shared
-- modules the game requires later on).
local function lazyrequire(name)
    local saved = package.path
    package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. saved
    guard.enter()
    local ok, mod = pcall(lrequire, name)
    guard.leave()
    package.path = saved
    if not package.path:find(_dir .. "common/?.lua", 1, true) then
        package.path = package.path .. ";" .. _dir .. "common/?.lua"
    end
    if not ok then error(mod, 0) end
    return mod
end

local GamesMenu  = require("games_menu")
local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))

local NavalDuel = PluginBase:extend{
    name      = "navalduel",
    menu_text = _("Naval Duel"),
    menu_hint = "tools",
}

function NavalDuel:createScreen()
    return lazyrequire("screen"):new{ plugin = self }
end

-- Listed under Two readers whatever game_categories.lua copy a device
-- loaded first: that table is one shared module, and an older copy from
-- another game would not know this plugin and file it under "Other".
function NavalDuel:addToMainMenu(menu_items)
    GamesMenu.add(menu_items, {
        id       = self:getPluginId(),
        label    = self.menu_text,
        category = "duo",
        launch   = function() self:showGame() end,
    })
end

guard.leave()

return NavalDuel
