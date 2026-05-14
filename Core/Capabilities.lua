-------------------------------------------------------------------------------
-- Capabilities.lua
-- DragonCore client capability detection. Detection runs exactly once at
-- module-load time; the resulting table is frozen and exposed read-only via
-- DragonCore.Capabilities. Pure detection: no frames, no events, no timers.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

-- Module-attach pattern (option a): mirrors Subscription. Any DragonCore file
-- may be loaded first; NewLibrary-or-GetLibrary keeps the shared table alive.
local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Detection
--
-- Canonical mechanism is namespace-presence probing. Build-number checks are
-- used only where a feature has no presence-probable surface (the Midnight
-- CLEU restriction is the v0 example). High-risk capabilities AND both signals
-- as belt-and-braces.
-------------------------------------------------------------------------------

---@return number|nil version, number|nil build, number|nil tocVersion
local function readBuildInfo()
    if type(GetBuildInfo) ~= "function" then return nil, nil, nil end
    local _version, build, _date, tocVersion = GetBuildInfo()
    return _version, tonumber(build), tonumber(tocVersion)
end

local function detect()
    local projectId = WOW_PROJECT_ID
    local mainline = WOW_PROJECT_MAINLINE
    local _version, buildNumber, interfaceVersion = readBuildInfo()

    local projectMainline = (projectId ~= nil and mainline ~= nil and projectId == mainline)

    -- "Classic" groups every non-retail flavor the addon family supports:
    -- TBC / Wrath / Cata / MoP Classic plus Classic Era / Anniversary
    -- (WOW_PROJECT_CLASSIC). Comparing against a nil constant is harmless
    -- because `nil ~= nil` is false, so the per-flavor probes self-disable in
    -- clients that never defined the constant.
    local projectClassic = projectId ~= nil and (
        projectId == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
        or projectId == WOW_PROJECT_WRATH_CLASSIC
        or projectId == WOW_PROJECT_CATACLYSM_CLASSIC
        or projectId == WOW_PROJECT_MISTS_CLASSIC
        or projectId == WOW_PROJECT_CLASSIC
    )

    -- Midnight (12.0+) restricts COMBAT_LOG_EVENT_UNFILTERED for addons.
    -- Probe C_RestrictedActions (the namespace Blizzard shipped for the
    -- migration) AND require interfaceVersion >= 120000. Both signals must
    -- hold. Note: GetBuildInfo()'s 2nd return is the client build counter
    -- (~67000 on Midnight), NOT the TOC interface version -- the 4th return
    -- is what tracks the 120000+ threshold.
    local cleuRestricted = C_RestrictedActions ~= nil
        and projectMainline
        and type(interfaceVersion) == "number"
        and interfaceVersion >= 120000

    -- Frame:RegisterEventCallback has been retail-only since introduction.
    -- We use WOW_PROJECT_MAINLINE as a proxy rather than instantiating a
    -- throwaway frame: instantiation requires the real WoW client, would
    -- pollute the GC roots, and the proxy is correct for every supported
    -- flavor today. Revisit if Blizzard ever back-ports the API.
    local frameEventCallback = projectMainline

    local addonMessageLockdown = type(Enum) == "table"
        and type(Enum.SendAddonMessageResult) == "table"
        and Enum.SendAddonMessageResult.AddOnMessageLockdown ~= nil

    -- Modern Settings API (Patch 10.0.0+ engine). All currently-shipped
    -- flavors -- Retail Mainline 10.0+, MoP Classic 5.5+, TBC Anniversary
    -- 2.5.5+, Vanilla Classic 1.15+ -- run on the modern UI engine and
    -- expose this namespace at runtime; the pre-10.0 InterfaceOptions
    -- category API was removed in Patch 10.0.0 and is nil everywhere.
    --
    -- This flag detects *capability*, not *flavor*: it AND-s presence of
    -- the three Settings functions the Modern renderer actually calls.
    -- It does not gate on WOW_PROJECT_ID or interfaceVersion. The honest
    -- meaning is "the calls the renderer will make resolve to functions"
    -- -- mixin completeness on Classic flavors is a separate, runtime-only
    -- concern handled by the pcall in Renderer_Modern:Render.
    --
    -- A frozen pre-10.0 Classic flavor would fail this probe; Settings:
    -- Register fast-errors at our boundary with a clear precondition
    -- message rather than crashing inside Blizzard code. That is the
    -- intended failure mode.
    local settingsAPI = type(_G.Settings) == "table"
        and type(_G.Settings.RegisterCanvasLayoutCategory) == "function"
        and type(_G.Settings.RegisterVerticalLayoutCategory) == "function"
        and type(_G.Settings.RegisterAddOnCategory) == "function"

    return {
        cleuRestricted        = cleuRestricted or false,
        restrictedActions     = C_RestrictedActions ~= nil,
        frameEventCallback    = frameEventCallback or false,
        addonMessageLockdown  = addonMessageLockdown or false,
        settingsAPI           = settingsAPI or false,
        projectMainline       = projectMainline or false,
        projectClassic        = projectClassic or false,
        buildNumber           = buildNumber or 0,
        interfaceVersion      = interfaceVersion or 0,
    }
end

-------------------------------------------------------------------------------
-- Freeze
--
-- Full read-only: the public table is an empty proxy whose __index forwards
-- reads to the populated detection table and whose __newindex rejects every
-- write (including overwrites of existing keys). __metatable = false prevents
-- callers from removing or replacing the lock via getmetatable / setmetatable.
-------------------------------------------------------------------------------

local function freeze(source)
    return setmetatable({}, {
        __index = source,
        __newindex = function() error("DragonCore.Capabilities is read-only", 2) end,
        __metatable = false,
    })
end

---@class DragonCore.Capabilities
---@field cleuRestricted boolean        Retail Midnight (Interface >= 120000): CLEU is restricted for addons.
---@field restrictedActions boolean     C_RestrictedActions namespace is present.
---@field frameEventCallback boolean    Frame:RegisterEventCallback is available (retail).
---@field addonMessageLockdown boolean  Enum.SendAddonMessageResult.AddOnMessageLockdown is present.
---@field settingsAPI boolean           Modern Settings API entry points
---                                     (Register{Canvas,Vertical}LayoutCategory + RegisterAddOnCategory)
---                                     are all callable.
---@field projectMainline boolean       WOW_PROJECT_ID == WOW_PROJECT_MAINLINE.
---@field projectClassic boolean        WOW_PROJECT_ID is any classic flavor (Era/TBC/Wrath/Cata/MoP).
---@field buildNumber number            Client build counter (e.g. 67235); 0 when unavailable.
---@field interfaceVersion number       TOC interface version (e.g. 120005); 0 when unavailable.

DragonCore.Capabilities = freeze(detect())
