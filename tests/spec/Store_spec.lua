-------------------------------------------------------------------------------
-- Store_spec.lua
-- Busted spec for DragonCore.Store. Loads Subscription -> SecureCall -> Store.
-- No Capabilities, Listener, Bus, Schedule, Locale, or AddonChannel deps:
-- Store is the most self-contained domain module (design note section 2).
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Store", function()
    local DragonCore
    local Store
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Store.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Store = DragonCore.Store

        mock = wow_mock.new()
        mock:Install()

        _G.securecallfunction = function(fn, ...) return fn(...) end
    end)

    after_each(function()
        if mock then
            mock:ClearSavedVariable("DragonTestDB")
            mock:Uninstall()
        end
    end)

    ---------------------------------------------------------------------------
    -- :Open validation
    ---------------------------------------------------------------------------

    describe(":Open validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function()
                Store:Open(nil, { savedVariable = "DragonTestDB" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: addon is required (DragonCore.Addon)", 1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function()
                    Store:Open(bad, { savedVariable = "DragonTestDB" })
                end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Store:Open: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function()
                Store:Open({}, { savedVariable = "DragonTestDB" })
            end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Store:Open: addon.name must be a non-empty string", 1, true))

            local ok2 = pcall(function()
                Store:Open({ name = "" }, { savedVariable = "DragonTestDB" })
            end)
            assert.is_false(ok2)
        end)

        it("rejects a nil or non-table spec", function()
            local addon = wow_mock.fakeAddon()
            for _, bad in ipairs({ nil, "DragonTestDB", 42 }) do
                local ok, err = pcall(function() Store:Open(addon, bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Store:Open: spec must be a table", 1, true))
            end
        end)

        it("rejects a spec without savedVariable", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function() Store:Open(addon, {}) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: spec.savedVariable must be a non-empty string",
                1, true))

            local ok2 = pcall(function()
                Store:Open(addon, { savedVariable = "" })
            end)
            assert.is_false(ok2)
        end)

        it("rejects a non-table defaults", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Store:Open(addon, { savedVariable = "DragonTestDB", defaults = "bad" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: spec.defaults must be a table if provided",
                1, true))
        end)

        it("rejects a non-string or empty initialProfile", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Store:Open(addon, { savedVariable = "DragonTestDB", initialProfile = "" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: spec.initialProfile must be a non-empty string",
                1, true))

            local ok2 = pcall(function()
                Store:Open(addon, { savedVariable = "DragonTestDB", initialProfile = 42 })
            end)
            assert.is_false(ok2)
        end)

        it("rejects an unknown profileMode", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Store:Open(addon, { savedVariable = "DragonTestDB", profileMode = "Realm" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: spec.profileMode must be 'Default' or 'Character'",
                1, true))
        end)

        it("rejects an existing non-table SV global", function()
            local addon = wow_mock.fakeAddon()
            mock:SetSavedVariable("DragonTestDB")
            _G.DragonTestDB = "corrupt"
            local ok, err = pcall(function()
                Store:Open(addon, { savedVariable = "DragonTestDB" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:Open: _G[\"DragonTestDB\"] exists but is not a table",
                1, true))
            assert.is_truthy(err:find("got string", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Open happy paths
    ---------------------------------------------------------------------------

    describe(":Open happy path", function()
        it("creates the SV global when nil", function()
            local addon = wow_mock.fakeAddon()
            local store = Store:Open(addon, { savedVariable = "DragonTestDB" })
            assert.is_truthy(store)
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.is_table(sv)
            assert.is_table(sv.profiles)
            assert.is_table(sv.profileKeys)
            assert.is_table(sv.char)
            assert.is_table(sv.realm)
            assert.is_table(sv.faction)
            assert.is_table(sv.factionrealm)
            assert.is_table(sv.class)
            assert.is_table(sv.race)
            assert.is_table(sv.global)
            assert.is_table(sv.profiles.Default)
        end)

        it("preserves existing SV data", function()
            mock:SetSavedVariable("DragonTestDB", {
                profiles = { Default = { interrupts = { enabled = true } } },
            })
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            assert.is_true(store:Profile().interrupts.enabled)
            assert.is_table(mock:GetSavedVariable("DragonTestDB").char)
        end)

        it("uses initialProfile when profileMode is Default", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                initialProfile = "MyProfile",
            })
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.is_table(sv.profiles.MyProfile)
            assert.equals("MyProfile", sv.profileKeys["TestChar - TestRealm"])
            store:Profile().k = "v"
            assert.equals("v", sv.profiles.MyProfile.k)
        end)

        it("uses 'Default' when no initialProfile is given", function()
            Store:Open(wow_mock.fakeAddon(), { savedVariable = "DragonTestDB" })
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("Default",
                sv.profileKeys["TestChar - TestRealm"])
        end)

        it("respects an existing per-character profile pointer", function()
            mock:SetSavedVariable("DragonTestDB", {
                profiles = { Custom = { x = 1 } },
                profileKeys = { ["TestChar - TestRealm"] = "Custom" },
            })
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB", initialProfile = "Default" })
            assert.equals(1, store:Profile().x)
        end)

        it("uses '<name> - <realm>' as profile key when profileMode == Character",
            function()
                mock:SetPlayerIdentity({ name = "Alyx", realm = "Razorgore" })
                local store = Store:Open(wow_mock.fakeAddon(), {
                    savedVariable = "DragonTestDB",
                    profileMode = "Character",
                })
                local sv = mock:GetSavedVariable("DragonTestDB")
                assert.is_table(sv.profiles["Alyx - Razorgore"])
                assert.equals("Alyx - Razorgore",
                    sv.profileKeys["Alyx - Razorgore"])
                store:Profile().k = "v"
                assert.equals("v", sv.profiles["Alyx - Razorgore"].k)
            end)
    end)

    ---------------------------------------------------------------------------
    -- Defaults / scope behaviour
    ---------------------------------------------------------------------------

    describe("defaults fallthrough", function()
        it("reads defaults for un-set keys", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = { profile = { enabled = false, threshold = 5 } },
            })
            assert.is_false(store:Profile().enabled)
            assert.equals(5, store:Profile().threshold)
        end)

        it("materialises writes to the underlying SV table", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = { profile = { enabled = false } },
            })
            store:Profile().enabled = true
            assert.is_true(store:Profile().enabled)
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.is_true(sv.profiles.Default.enabled)
        end)

        it("does not copy defaults (mutation leaks; documented UB)", function()
            local defaults = { profile = { x = 1 } }
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = defaults,
            })
            defaults.profile.x = 2
            assert.equals(2, store:Profile().x)
        end)

        it("applies defaults to every scope", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = {
                    profile = { p = "p" },
                    char = { c = "c" },
                    realm = { r = "r" },
                    faction = { f = "f" },
                    factionrealm = { fr = "fr" },
                    class = { cl = "cl" },
                    race = { ra = "ra" },
                    global = { g = "g" },
                },
            })
            assert.equals("p", store:Profile().p)
            assert.equals("c", store:Char().c)
            assert.equals("r", store:Realm().r)
            assert.equals("f", store:Faction().f)
            assert.equals("fr", store:FactionRealm().fr)
            assert.equals("cl", store:Class().cl)
            assert.equals("ra", store:Race().ra)
            assert.equals("g", store:Global().g)
        end)
    end)

    describe("scope isolation", function()
        it("writes to one scope are invisible to another", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:Profile().key = "profile"
            assert.is_nil(rawget(store:Char(), "key"))
            assert.is_nil(rawget(store:Global(), "key"))
        end)

        it("partitions char/realm/faction by identity", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:Class().k = "warrior"
            mock:SetPlayerIdentity({ class = { "Mage", "MAGE", 8 } })
            local store2 = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            assert.is_nil(rawget(store2:Class(), "k"))
            store2:Class().k = "mage"
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("warrior", sv.class.WARRIOR.k)
            assert.equals("mage", sv.class.MAGE.k)
        end)

        it("partitions faction-realm by composite identity", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:FactionRealm().k = "horde-test"
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("horde-test", sv.factionrealm["Horde - TestRealm"].k)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Profile operations
    ---------------------------------------------------------------------------

    describe(":HasProfile", function()
        it("returns true for known profiles", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            assert.is_true(store:HasProfile("Default"))
            assert.is_false(store:HasProfile("Other"))
        end)

        it("rejects a non-string or empty name", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local ok, err = pcall(function() store:HasProfile("") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:HasProfile: name must be a non-empty string",
                1, true))
        end)
    end)

    describe(":UseProfile", function()
        it("creates the profile if missing and switches", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("Other")
            assert.is_true(store:HasProfile("Other"))
            store:Profile().k = "v"
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("v", sv.profiles.Other.k)
        end)

        it("fires ProfileChanged with (store, old, new)", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local fired = {}
            store:On("ProfileChanged", function(s, old, new)
                fired = { s = s, old = old, new = new }
            end)
            store:UseProfile("Other")
            assert.equals(store, fired.s)
            assert.equals("Default", fired.old)
            assert.equals("Other", fired.new)
        end)

        it("is a no-op when switching to the active profile", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local count = 0
            store:On("ProfileChanged", function() count = count + 1 end)
            store:UseProfile("Default")
            assert.equals(0, count)
        end)

        it("updates the per-character profile pointer", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("Other")
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("Other", sv.profileKeys["TestChar - TestRealm"])
        end)
    end)

    describe(":ListProfiles", function()
        it("returns every known profile name", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("A")
            store:UseProfile("B")
            local list = store:ListProfiles()
            table.sort(list)
            assert.same({ "A", "B", "Default" }, list)
        end)
    end)

    describe(":DeleteProfile", function()
        it("removes a non-active profile and fires ProfileDeleted", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("Other")
            store:UseProfile("Default")
            local fired
            store:On("ProfileDeleted", function(_, n) fired = n end)
            store:DeleteProfile("Other")
            assert.is_false(store:HasProfile("Other"))
            assert.equals("Other", fired)
        end)

        it("raises when deleting the active profile", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local ok, err = pcall(function() store:DeleteProfile("Default") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:DeleteProfile: cannot delete the active profile 'Default'",
                1, true))
        end)

        it("is a silent no-op for a missing profile", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local count = 0
            store:On("ProfileDeleted", function() count = count + 1 end)
            store:DeleteProfile("Nope")
            assert.equals(0, count)
        end)
    end)

    describe(":CopyFrom", function()
        it("deep-copies source profile contents into the active profile", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("Source")
            store:Profile().nested = { a = 1, b = { c = 2 } }
            store:UseProfile("Dest")
            store:CopyFrom("Source")
            assert.equals(1, store:Profile().nested.a)
            assert.equals(2, store:Profile().nested.b.c)
            -- Verify the copy is deep: mutating dest does not touch source.
            store:Profile().nested.b.c = 99
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals(2, sv.profiles.Source.nested.b.c)
        end)

        it("fires ProfileCopied with (store, source, dest)", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:UseProfile("Source")
            store:UseProfile("Dest")
            local fired = {}
            store:On("ProfileCopied", function(_, src, dst)
                fired = { src = src, dst = dst }
            end)
            store:CopyFrom("Source")
            assert.equals("Source", fired.src)
            assert.equals("Dest", fired.dst)
        end)

        it("raises on a missing source", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local ok, err = pcall(function() store:CopyFrom("Nope") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:CopyFrom: source profile 'Nope' does not exist",
                1, true))
        end)

        it("is a no-op when source == active", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local count = 0
            store:On("ProfileCopied", function() count = count + 1 end)
            store:CopyFrom("Default")
            assert.equals(0, count)
        end)
    end)

    describe(":ResetProfile", function()
        it("clears the active profile and re-applies defaults", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = { profile = { enabled = false } },
            })
            store:Profile().enabled = true
            store:Profile().extra = "x"
            store:ResetProfile()
            assert.is_false(store:Profile().enabled)
            assert.is_nil(store:Profile().extra)
        end)

        it("fires ProfileReset with the active profile name", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local fired
            store:On("ProfileReset", function(_, n) fired = n end)
            store:ResetProfile()
            assert.equals("Default", fired)
        end)
    end)

    describe(":ResetAll", function()
        it("clears every scope and fires ProfileReset for the active profile",
            function()
                local store = Store:Open(wow_mock.fakeAddon(), {
                    savedVariable = "DragonTestDB",
                    defaults = { profile = { enabled = false }, global = { g = 1 } },
                })
                store:Profile().enabled = true
                store:Char().x = 1
                store:Global().y = 2
                local fired
                store:On("ProfileReset", function(_, n) fired = n end)
                store:ResetAll()
                assert.is_false(store:Profile().enabled)
                assert.is_nil(rawget(store:Char(), "x"))
                assert.equals(1, store:Global().g)
                assert.is_nil(rawget(store:Global(), "y"))
                assert.equals("Default", fired)
            end)
    end)

    ---------------------------------------------------------------------------
    -- :On validation + dispatcher discipline
    ---------------------------------------------------------------------------

    describe(":On validation", function()
        it("rejects an unknown event", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local ok, err = pcall(function()
                store:On("Bogus", function() end)
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:On: event must be one of", 1, true))
        end)

        it("rejects a non-function fn", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local ok, err = pcall(function()
                store:On("ProfileChanged", "nope")
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Store:On: fn must be a function", 1, true))
        end)

        it("returns a Subscription that cancels cleanly", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local count = 0
            local sub = store:On("ProfileChanged", function() count = count + 1 end)
            store:UseProfile("A")
            sub:Cancel()
            store:UseProfile("B")
            assert.equals(1, count)
            assert.is_true(sub:IsCancelled())
        end)
    end)

    describe("re-entrant dispatch", function()
        it("does not invoke a handler subscribed mid-dispatch", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local outerCount, innerCount = 0, 0
            store:On("ProfileChanged", function()
                outerCount = outerCount + 1
                store:On("ProfileChanged", function()
                    innerCount = innerCount + 1
                end)
            end)
            store:UseProfile("A")
            assert.equals(1, outerCount)
            assert.equals(0, innerCount)
            store:UseProfile("B")
            assert.equals(2, outerCount)
            assert.equals(1, innerCount)
        end)

        it("honours self-cancel mid-dispatch without aborting siblings", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local subA
            local seenA, seenB = 0, 0
            subA = store:On("ProfileChanged", function()
                seenA = seenA + 1
                subA:Cancel()
            end)
            store:On("ProfileChanged", function() seenB = seenB + 1 end)
            store:UseProfile("X")
            assert.equals(1, seenA)
            assert.equals(1, seenB)
            store:UseProfile("Y")
            assert.equals(1, seenA)
            assert.equals(2, seenB)
        end)

        it("isolates handler errors via SecureCall", function()
            _G.securecallfunction = nil
            _G.geterrorhandler = function() return function() end end
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local seen = 0
            store:On("ProfileChanged", function() error("boom") end)
            store:On("ProfileChanged", function() seen = seen + 1 end)
            store:UseProfile("X")
            assert.equals(1, seen)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Dispose
    ---------------------------------------------------------------------------

    describe(":Dispose", function()
        it("cancels every subscription", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            local sub = store:On("ProfileChanged", function() end)
            store:Dispose()
            assert.is_true(sub:IsCancelled())
        end)

        it("does not touch the SV global", function()
            local store = Store:Open(wow_mock.fakeAddon(), {
                savedVariable = "DragonTestDB",
                defaults = { profile = { enabled = false } },
            })
            store:Profile().enabled = true
            store:Dispose()
            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.is_table(sv)
            assert.is_true(sv.profiles.Default.enabled)
        end)

        it("raises on subsequent non-Dispose calls", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:Dispose()
            for _, name in ipairs({ "Profile", "Char", "Global", "ListProfiles" }) do
                local ok, err = pcall(function() store[name](store) end)
                assert.is_false(ok)
                assert.is_truthy(err:find("instance has been disposed", 1, true))
            end
        end)

        it("is idempotent", function()
            local store = Store:Open(wow_mock.fakeAddon(),
                { savedVariable = "DragonTestDB" })
            store:Dispose()
            store:Dispose()  -- no raise
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cross-character profile lookup (design note section 8.5)
    ---------------------------------------------------------------------------

    describe("multi-identity behaviour", function()
        it("preserves per-character profile pointers across identities", function()
            local addon = wow_mock.fakeAddon()
            local s1 = Store:Open(addon, { savedVariable = "DragonTestDB" })
            s1:UseProfile("CharA")

            mock:SetPlayerIdentity({ name = "Other" })
            local s2 = Store:Open(addon, { savedVariable = "DragonTestDB" })
            -- Second character defaults to "Default" (no pre-existing pointer).
            assert.equals("Default", s2:ListProfiles()[1] or "")
            s2:UseProfile("CharB")

            local sv = mock:GetSavedVariable("DragonTestDB")
            assert.equals("CharA", sv.profileKeys["TestChar - TestRealm"])
            assert.equals("CharB", sv.profileKeys["Other - TestRealm"])
        end)

        it("does not touch frames (taint contract proxy)", function()
            Store:Open(wow_mock.fakeAddon(), { savedVariable = "DragonTestDB" })
            assert.equals(0, mock:FrameCount())
        end)
    end)
end)
