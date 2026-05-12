-------------------------------------------------------------------------------
-- Locale_spec.lua
-- Busted spec for DragonCore.Locale. Locale has zero DragonCore deps so the
-- harness only needs LibStub + the wow_mock GetLocale shim (no Subscription,
-- no SecureCall, no Frame).
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Locale", function()
    local DragonCore
    local Locale
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Locale.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Locale = DragonCore.Locale

        mock = wow_mock.new()
        mock:Install()  -- default GetLocale() == "enUS"
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :Register validation
    ---------------------------------------------------------------------------

    describe(":Register validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function() Locale:Register(nil, "enUS", {}) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale:Register: addon is required (DragonCore.Addon)", 1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() Locale:Register(bad, "enUS", {}) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Locale:Register: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function() Locale:Register({}, "enUS", {}) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Locale:Register: addon.name must be a non-empty string", 1, true))

            local ok2 = pcall(function() Locale:Register({ name = "" }, "enUS", {}) end)
            assert.is_false(ok2)
        end)

        it("rejects a non-string or empty locale", function()
            local addon = wow_mock.fakeAddon()
            local ok1, err1 = pcall(function() Locale:Register(addon, nil, {}) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Locale:Register: locale must be a non-empty string", 1, true))

            local ok2 = pcall(function() Locale:Register(addon, "", {}) end)
            assert.is_false(ok2)

            local ok3 = pcall(function() Locale:Register(addon, 42, {}) end)
            assert.is_false(ok3)
        end)

        it("rejects a non-table strings arg", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function() Locale:Register(addon, "enUS", "oops") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale:Register: strings must be a table", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Get validation
    ---------------------------------------------------------------------------

    describe(":Get / :Format validation", function()
        it(":Get rejects a nil addon", function()
            local ok, err = pcall(function() Locale:Get(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale:Get: addon is required (DragonCore.Addon)", 1, true))
        end)

        it(":Format rejects a nil addon", function()
            local ok, err = pcall(function() Locale:Format(nil, "x") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale:Format: addon is required (DragonCore.Addon)", 1, true))
        end)

        it(":Format rejects a non-string template", function()
            local ok, err = pcall(function()
                Locale:Format(wow_mock.fakeAddon(), nil)
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale:Format: template must be a string", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- enUS sentinel normalisation
    ---------------------------------------------------------------------------

    describe("enUS sentinel (true) normalisation", function()
        it("rewrites true to the key in default at registration", function()
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true })
            local L = Locale:Get(addon)
            assert.are.equal("Hello", L["Hello"])
        end)

        it("falls back to the key for unregistered strings", function()
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true })
            local L = Locale:Get(addon)
            assert.are.equal("Unregistered", L["Unregistered"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Active-locale matching
    ---------------------------------------------------------------------------

    describe("active locale selection", function()
        it("returns deDE translations when GetLocale() == deDE", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true })
            Locale:Register(addon, "deDE", { ["Hello"] = "Hallo" })
            assert.are.equal("Hallo", Locale:Get(addon)["Hello"])
        end)

        it("falls back to enUS when active locale lacks a key", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true, ["Bye"] = true })
            Locale:Register(addon, "deDE", { ["Hello"] = "Hallo" })  -- Bye missing
            local L = Locale:Get(addon)
            assert.are.equal("Hallo", L["Hello"])
            assert.are.equal("Bye", L["Bye"])  -- enUS fallback (key-normalised)
        end)

        it("drops non-active non-enUS locales silently", function()
            mock:SetLocale("enUS")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true })
            Locale:Register(addon, "deDE", { ["Hello"] = "Hallo" })  -- inactive
            assert.are.equal("Hello", Locale:Get(addon)["Hello"])
        end)

        it("under enUS client, registers both default and active for enUS", function()
            mock:SetLocale("enUS")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Hello"] = true })
            -- Either slot can answer; "active[Hello] or default[Hello] or k"
            -- must produce "Hello" regardless.
            assert.are.equal("Hello", Locale:Get(addon)["Hello"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Safety net: non-enUS before enUS
    ---------------------------------------------------------------------------

    describe("safety net (non-enUS first)", function()
        it("seeds default from deDE when registered before enUS, then enUS overwrites", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            -- deDE first, no enUS registered -> default seeded from deDE.
            Locale:Register(addon, "deDE", { ["Hello"] = "Hallo" })
            -- No enUS registered yet; default[Hello] should be "Hallo" so
            -- the consumer never observes nil.
            assert.are.equal("Hallo", Locale:Get(addon)["Hello"])

            -- Now register enUS; default is overwritten with the (key-
            -- normalised) enUS table.
            Locale:Register(addon, "enUS", { ["Hello"] = true, ["Bye"] = true })
            local L = Locale:Get(addon)
            assert.are.equal("Hallo", L["Hello"])  -- active still deDE
            assert.are.equal("Bye", L["Bye"])      -- enUS fallback for missing
        end)
    end)

    ---------------------------------------------------------------------------
    -- Merge semantics
    ---------------------------------------------------------------------------

    describe("merge on repeat register", function()
        it("merges keys into the same slot; later wins", function()
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["A"] = true, ["B"] = true })
            Locale:Register(addon, "enUS", { ["B"] = true, ["C"] = true })
            local L = Locale:Get(addon)
            assert.are.equal("A", L["A"])
            assert.are.equal("B", L["B"])
            assert.are.equal("C", L["C"])
        end)

        it("merges active-locale keys across files", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "deDE", { ["Hello"] = "Hallo" })
            Locale:Register(addon, "deDE", { ["Bye"] = "Tschuss" })
            local L = Locale:Get(addon)
            assert.are.equal("Hallo", L["Hello"])
            assert.are.equal("Tschuss", L["Bye"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Proxy stability and isolation
    ---------------------------------------------------------------------------

    describe("proxy stability", function()
        it("returns the same proxy across :Get calls for the same addon", function()
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["X"] = true })
            assert.are.equal(Locale:Get(addon), Locale:Get(addon))
        end)

        it("returns distinct proxies per addon", function()
            local a = wow_mock.fakeAddon("A")
            local b = wow_mock.fakeAddon("B")
            Locale:Register(a, "enUS", { ["X"] = true })
            Locale:Register(b, "enUS", { ["X"] = true })
            assert.are_not.equal(Locale:Get(a), Locale:Get(b))
        end)

        it("returns a proxy for an addon that never registered (key-as-value)", function()
            local addon = wow_mock.fakeAddon()
            local L = Locale:Get(addon)
            assert.are.equal("Never registered", L["Never registered"])
        end)

        it("keys two addons with the same name to the same registry entry", function()
            local a1 = wow_mock.fakeAddon("Same")
            local a2 = wow_mock.fakeAddon("Same")
            Locale:Register(a1, "enUS", { ["Hello"] = true })
            assert.are.equal("Hello", Locale:Get(a2)["Hello"])
            -- And the proxy is the same object across the two handles.
            assert.are.equal(Locale:Get(a1), Locale:Get(a2))
        end)
    end)

    describe("cross-addon isolation", function()
        it("does not bleed strings from one addon to another", function()
            local a = wow_mock.fakeAddon("A")
            local b = wow_mock.fakeAddon("B")
            Locale:Register(a, "enUS", { ["Secret"] = true })
            -- Addon B never registered "Secret"; resolves to key fallback.
            assert.are.equal("Secret", Locale:Get(b)["Secret"])
            -- Addon A's value comes from the (key-normalised) default slot.
            assert.are.equal("Secret", Locale:Get(a)["Secret"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Read-only proxy
    ---------------------------------------------------------------------------

    describe("read-only proxy", function()
        it("raises on direct write", function()
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["X"] = true })
            local L = Locale:Get(addon)
            local ok, err = pcall(function() L["X"] = "mutated" end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Locale: strings table is read-only", 1, true))
        end)

        it("raises on write to a key that has never been registered", function()
            local addon = wow_mock.fakeAddon()
            local L = Locale:Get(addon)
            local ok = pcall(function() L["new"] = "x" end)
            assert.is_false(ok)
        end)

        it("hides the metatable via __metatable = false", function()
            local addon = wow_mock.fakeAddon()
            local L = Locale:Get(addon)
            assert.are.equal(false, getmetatable(L))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Format
    ---------------------------------------------------------------------------

    describe(":Format", function()
        it("formats using the active-locale template", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            Locale:Register(addon, "enUS", { ["Greet"] = true })
            Locale:Register(addon, "deDE", { ["Greet"] = "Hallo, %s!" })
            assert.are.equal("Hallo, Foo!", Locale:Format(addon, "Greet", "Foo"))
        end)

        it("falls back to enUS template when active lacks the key", function()
            mock:SetLocale("deDE")
            local addon = wow_mock.fakeAddon()
            -- enUS sentinel becomes the key itself; "Hi, %s" is the key.
            Locale:Register(addon, "enUS", { ["Hi, %s"] = true })
            assert.are.equal("Hi, Bar", Locale:Format(addon, "Hi, %s", "Bar"))
        end)

        it("falls back to key-as-template when neither locale has the key", function()
            local addon = wow_mock.fakeAddon()
            assert.are.equal("plain", Locale:Format(addon, "plain"))
            assert.are.equal("Hello, World",
                Locale:Format(addon, "Hello, %s", "World"))
        end)

        it("propagates string.format errors", function()
            local addon = wow_mock.fakeAddon()
            local ok = pcall(function() Locale:Format(addon, "%d", "not a number") end)
            assert.is_false(ok)
        end)
    end)
end)
