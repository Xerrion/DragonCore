-------------------------------------------------------------------------------
-- Capabilities_spec.lua
-- Busted spec for DragonCore.Capabilities. Stands up a per-test WoW global
-- mock, reloads LibStub, then dofiles Core/Capabilities.lua so detection runs
-- against the simulated client.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")

-- Canonical retail Midnight client (Interface 120005, build 67235). The
-- Settings stub includes all three functions Renderer_Modern will call;
-- caps.settingsAPI is a pure presence probe (ADR-0002).
local function retailMidnightGlobals()
    return {
        WOW_PROJECT_ID = 1,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "12.0.5", "67235", "20251023", 120005 end,
        C_RestrictedActions = {},
        Enum = { SendAddonMessageResult = { AddOnMessageLockdown = 0 } },
        Settings = {
            RegisterCanvasLayoutCategory = function() end,
            RegisterVerticalLayoutCategory = function() end,
            RegisterAddOnCategory = function() end,
        },
    }
end

-- Retail pre-Midnight (TWW 11.x): mainline but no C_RestrictedActions and
-- interface version well below 120000.
local function retailPreMidnightGlobals()
    return {
        WOW_PROJECT_ID = 1,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "11.0.7", "60000", "20250101", 110007 end,
        -- C_RestrictedActions absent
        Enum = { SendAddonMessageResult = { AddOnMessageLockdown = 0 } },
    }
end

-- MoP Classic 5.5.x: non-mainline project ID with the modern Settings API
-- present (TBC Anniversary shipping Edit Mode confirms Classic flavors run
-- the modern UI engine). ADR-0002 relaxed the settingsAPI probe to drop
-- the projectMainline / interfaceVersion gates, so this must evaluate
-- true.
local function mopClassicGlobals()
    return {
        WOW_PROJECT_ID = 15,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "5.5.3", "55000", "20250901", 50503 end,
        Enum = {},
        Settings = {
            RegisterCanvasLayoutCategory = function() end,
            RegisterVerticalLayoutCategory = function() end,
            RegisterAddOnCategory = function() end,
        },
    }
end

-- TBC Anniversary 2.5.5+: non-mainline project ID, modern Settings API
-- present. Same relaxed-gate semantics as MoP Classic.
local function tbcAnniversaryGlobals()
    return {
        WOW_PROJECT_ID = 5,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "2.5.5", "22000", "20250601", 20505 end,
        Enum = {},
        Settings = {
            RegisterCanvasLayoutCategory = function() end,
            RegisterVerticalLayoutCategory = function() end,
            RegisterAddOnCategory = function() end,
        },
    }
end

-- Regression guard for the buildNumber-vs-interfaceVersion bug:
-- realistic Midnight client build (~67235) paired with a pre-Midnight
-- interface version. C_RestrictedActions is present AND project is
-- mainline, so the only thing preventing cleuRestricted is the
-- interfaceVersion < 120000 check. If detection mistakenly compared
-- buildNumber against 120000, this would flip true and the test would
-- fail -- which is exactly what we want.
local function midnightBuildPreMidnightInterfaceGlobals()
    return {
        WOW_PROJECT_ID = 1,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "11.9.9", "67235", "20251020", 110000 end,
        C_RestrictedActions = {},
        Enum = { SendAddonMessageResult = { AddOnMessageLockdown = 0 } },
    }
end

-- Partial-stub Classic: _G.Settings is present with only RegisterAddOnCategory
-- (the pre-relaxed signal). With ADR-0002's three-function AND, this must
-- fail closed because the canvas/vertical functions are missing.
local function partialStubSettingsGlobals()
    return {
        WOW_PROJECT_ID = 5,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "2.5.5", "22000", "20250601", 20505 end,
        Enum = {},
        Settings = { RegisterAddOnCategory = function() end },
    }
end

-- Build a globals factory that omits exactly one of the three Settings
-- functions Renderer_Modern requires, leaving the other two present. Used
-- to assert that the relaxed probe still fails closed on missing-function
-- partial stubs.
local function settingsMissingOne(omit)
    local s = {
        RegisterCanvasLayoutCategory = function() end,
        RegisterVerticalLayoutCategory = function() end,
        RegisterAddOnCategory = function() end,
    }
    s[omit] = nil
    return {
        WOW_PROJECT_ID = 1,
        WOW_PROJECT_MAINLINE = 1,
        WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5,
        WOW_PROJECT_WRATH_CLASSIC = 11,
        WOW_PROJECT_CATACLYSM_CLASSIC = 14,
        WOW_PROJECT_MISTS_CLASSIC = 15,
        WOW_PROJECT_CLASSIC = 2,
        GetBuildInfo = function() return "12.0.5", "67235", "20251023", 120005 end,
        C_RestrictedActions = {},
        Enum = { SendAddonMessageResult = { AddOnMessageLockdown = 0 } },
        Settings = s,
    }
end

local function loadCapabilities(globals)
    bootstrap.reset_globals(globals)
    bootstrap.reload_libstub()
    dofile("Core/Capabilities.lua")
    return LibStub("DragonCore-1.0").Capabilities
end

describe("DragonCore.Capabilities", function()
    it("detects retail Midnight: cleuRestricted and full retail surface", function()
        local caps = loadCapabilities(retailMidnightGlobals())
        assert.is_true(caps.cleuRestricted)
        assert.is_true(caps.restrictedActions)
        assert.is_true(caps.frameEventCallback)
        assert.is_true(caps.addonMessageLockdown)
        assert.is_true(caps.projectMainline)
        assert.is_false(caps.projectClassic)
        assert.is_true(caps.settingsAPI)
        assert.are.equal(67235, caps.buildNumber)
        assert.are.equal(120005, caps.interfaceVersion)
    end)

    it("detects retail pre-Midnight: mainline but CLEU not restricted", function()
        local caps = loadCapabilities(retailPreMidnightGlobals())
        assert.is_false(caps.cleuRestricted)
        assert.is_false(caps.restrictedActions)
        assert.is_true(caps.frameEventCallback)
        assert.is_true(caps.addonMessageLockdown)
        assert.is_true(caps.projectMainline)
        assert.is_false(caps.projectClassic)
        assert.are.equal(60000, caps.buildNumber)
    end)

    it("detects MoP Classic: projectClassic + relaxed settingsAPI accepts it",
        function()
            local caps = loadCapabilities(mopClassicGlobals())
            assert.is_false(caps.cleuRestricted)
            assert.is_false(caps.restrictedActions)
            assert.is_false(caps.frameEventCallback)
            assert.is_false(caps.addonMessageLockdown)
            assert.is_false(caps.projectMainline)
            assert.is_true(caps.projectClassic)
            -- ADR-0002: relaxed probe is pure three-function presence; Classic
            -- flavors that ship the modern Settings namespace qualify.
            assert.is_true(caps.settingsAPI)
            assert.are.equal(55000, caps.buildNumber)
            assert.are.equal(50503, caps.interfaceVersion)
        end)

    it("detects TBC Anniversary: projectClassic + relaxed settingsAPI accepts it",
        function()
            local caps = loadCapabilities(tbcAnniversaryGlobals())
            assert.is_false(caps.cleuRestricted)
            assert.is_false(caps.projectMainline)
            assert.is_true(caps.projectClassic)
            assert.is_true(caps.settingsAPI)
            assert.are.equal(22000, caps.buildNumber)
        end)

    it("rejects settingsAPI when _G.Settings is absent", function()
        -- retailPreMidnightGlobals does not include _G.Settings; the
        -- type check on _G.Settings must fail closed.
        local caps = loadCapabilities(retailPreMidnightGlobals())
        assert.is_true(caps.projectMainline)
        assert.is_false(caps.settingsAPI)
    end)

    it("rejects settingsAPI on a partial-stub Classic (only RegisterAddOnCategory)",
        function()
            -- Mirrors the original TBC Anniversary crash signal: the legacy
            -- pre-relaxed disambiguator was RegisterVerticalLayoutCategory.
            -- The relaxed three-function AND still rejects this case
            -- because the canvas/vertical functions are missing.
            local caps = loadCapabilities(partialStubSettingsGlobals())
            assert.is_true(caps.projectClassic)
            assert.is_false(caps.settingsAPI)
        end)

    it("rejects settingsAPI when RegisterCanvasLayoutCategory is missing",
        function()
            local caps = loadCapabilities(settingsMissingOne("RegisterCanvasLayoutCategory"))
            assert.is_false(caps.settingsAPI)
        end)

    it("rejects settingsAPI when RegisterVerticalLayoutCategory is missing",
        function()
            local caps = loadCapabilities(settingsMissingOne("RegisterVerticalLayoutCategory"))
            assert.is_false(caps.settingsAPI)
        end)

    it("rejects settingsAPI when RegisterAddOnCategory is missing", function()
        local caps = loadCapabilities(settingsMissingOne("RegisterAddOnCategory"))
        assert.is_false(caps.settingsAPI)
    end)

    it("regression: midnight client build with pre-Midnight interface does NOT trigger cleuRestricted", function()
        -- Guards against the buildNumber-vs-interfaceVersion mix-up: a real
        -- Midnight client has a build counter (~67235) that has NEVER been
        -- >= 120000. Only interfaceVersion crosses that threshold. If this
        -- assertion flips, detection is reading the wrong GetBuildInfo()
        -- selector.
        local caps = loadCapabilities(midnightBuildPreMidnightInterfaceGlobals())
        assert.is_false(caps.cleuRestricted)
        assert.is_true(caps.restrictedActions)
        assert.is_true(caps.projectMainline)
        assert.are.equal(67235, caps.buildNumber)
        assert.are.equal(110000, caps.interfaceVersion)
    end)

    it("rejects writes to existing fields (read-only)", function()
        local caps = loadCapabilities(retailMidnightGlobals())
        local ok, err = pcall(function() caps.cleuRestricted = "lol" end)
        assert.is_false(ok)
        assert.is_string(err)
        assert.is_truthy(err:find("read-only", 1, true))
    end)

    it("rejects writes to new fields (no key creation)", function()
        local caps = loadCapabilities(retailMidnightGlobals())
        local ok, err = pcall(function() caps.newField = true end)
        assert.is_false(ok)
        assert.is_string(err)
        assert.is_truthy(err:find("read-only", 1, true))
    end)

    it("locks the metatable so it cannot be replaced", function()
        local caps = loadCapabilities(retailMidnightGlobals())
        assert.is_false(getmetatable(caps))
        assert.has_errors(function() setmetatable(caps, {}) end)
    end)
end)
