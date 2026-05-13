-------------------------------------------------------------------------------
-- Locales/enUS.lua
-- DragonCore library's own user-facing chrome strings. Settings.lua resolves
-- these through DragonCore.Locale using a synthetic addon ({name = "DragonCore"})
-- so the per-addon registry can host them. Loaded AFTER Core/Locale.lua
-- and AFTER Core/Settings/Settings.lua per TOC order.
--
-- Workspace convention: enUS values are the boolean `true` sentinel; Locale
-- normalises at the registration boundary so reads of `L["X"]` resolve to
-- "X" without ever observing a `true` in the chain.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR = "DragonCore-1.0"
local DragonCore = LibStub(MAJOR)
if not DragonCore or not DragonCore.Locale then return end

DragonCore.Locale:Register({ name = "DragonCore" }, "enUS", {
    -- Renderer chrome.
    ["Reset to defaults"] = true,

    -- Settings.lua slash-handler chrome.
    ["DragonCore: unknown slash subcommand '%s'. Try '/<cmd>', '/<cmd> open', or '/<cmd> reset'."] = true,
})
