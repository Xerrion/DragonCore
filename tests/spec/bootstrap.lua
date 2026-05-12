-------------------------------------------------------------------------------
-- bootstrap.lua
-- Shared test harness for DragonCore specs. NOT a spec file (no `_spec`
-- suffix) so busted's pattern-based discovery skips it.
--
-- Responsibilities:
--   * Provide the `strmatch` shim required by the vendored LibStub under
--     stock Lua 5.1.
--   * Reload LibStub from source so every test starts with a clean library
--     registry (no leftover DragonCore-1.0 entry from a prior spec).
--   * Expose `reset_globals(overrides)` for specs that need to simulate a
--     specific WoW client flavor: every known WoW global is nilled, then
--     the caller-supplied overrides are applied.
-------------------------------------------------------------------------------

local M = {}

-- WoW globals any DragonCore module is permitted to read. Listed here so the
-- harness can wipe them in one place between tests. Keep in sync with the
-- `read_globals` list in .luacheckrc.
local WOW_GLOBALS = {
    "CreateFrame", "C_Timer", "GetBuildInfo", "GetLocale",
    "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE",
    "WOW_PROJECT_BURNING_CRUSADE_CLASSIC", "WOW_PROJECT_WRATH_CLASSIC",
    "WOW_PROJECT_CATACLYSM_CLASSIC", "WOW_PROJECT_MISTS_CLASSIC",
    "WOW_PROJECT_CLASSIC",
    "C_RestrictedActions", "C_ChatInfo", "Enum",
    "UnitName", "GetRealmName", "UnitFactionGroup", "UnitClass", "UnitRace",
    "securecallfunction", "geterrorhandler",
}

---Reload LibStub from source. Wipes any prior LibStub state so library
---registrations from earlier tests do not leak.
function M.reload_libstub()
    _G.strmatch = _G.strmatch or string.match
    _G.LibStub = nil
    dofile("Libs/LibStub/LibStub.lua")
end

---Reset every known WoW global to nil, then apply the supplied overrides.
---Call before `reload_libstub` + module dofile to simulate a specific client.
---@param overrides table<string, any>|nil  name -> value table; nil clears only.
function M.reset_globals(overrides)
    for _, name in ipairs(WOW_GLOBALS) do
        _G[name] = nil
    end
    if overrides == nil then return end
    for name, value in pairs(overrides) do
        _G[name] = value
    end
end

return M
