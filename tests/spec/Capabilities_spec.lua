-------------------------------------------------------------------------------
-- Capabilities_spec.lua
-- Busted spec for DragonCore.Capabilities. Stands up a per-test WoW global
-- mock, reloads LibStub, then dofiles Core/Capabilities.lua so detection runs
-- against the simulated client.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")

-- Canonical retail Midnight client (Interface 120005, build 67235).
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
        -- No retail-only namespaces.
        Enum = {},
    }
end

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

    it("detects MoP Classic: projectClassic, no retail surfaces", function()
        local caps = loadCapabilities(mopClassicGlobals())
        assert.is_false(caps.cleuRestricted)
        assert.is_false(caps.restrictedActions)
        assert.is_false(caps.frameEventCallback)
        assert.is_false(caps.addonMessageLockdown)
        assert.is_false(caps.projectMainline)
        assert.is_true(caps.projectClassic)
        assert.are.equal(55000, caps.buildNumber)
        assert.are.equal(50503, caps.interfaceVersion)
    end)

    it("detects TBC Anniversary: projectClassic, no retail surfaces", function()
        local caps = loadCapabilities(tbcAnniversaryGlobals())
        assert.is_false(caps.cleuRestricted)
        assert.is_false(caps.projectMainline)
        assert.is_true(caps.projectClassic)
        assert.are.equal(22000, caps.buildNumber)
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
