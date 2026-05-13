-------------------------------------------------------------------------------
-- Lifecycle_spec.lua
-- Busted spec for DragonCore.Lifecycle. Loads Subscription -> SecureCall ->
-- Lifecycle. The mock is :Install()-ed BEFORE Lifecycle.lua is dofile-d
-- because Lifecycle creates its bootstrap Frame at module-load time
-- (design note section 3.1) and needs `_G.CreateFrame` already wired.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Lifecycle", function()
    local DragonCore
    local Lifecycle
    local mock

    -- Helper: load Lifecycle with the current mock + global state. Some
    -- specs need to set IsLoggedIn / mark addons loaded BEFORE the module
    -- attaches its bootstrap frame; others want the default fresh boot.
    local function loadLifecycle()
        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Dispatcher.lua")
        dofile("Core/Lifecycle/Lifecycle.lua")
        DragonCore = LibStub("DragonCore-1.0")
        Lifecycle = DragonCore.Lifecycle
    end

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        mock = wow_mock.new()
        mock:Install()

        _G.securecallfunction = function(fn, ...) return fn(...) end

        loadLifecycle()
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :Register validation
    ---------------------------------------------------------------------------

    describe(":Register validation", function()
        it("rejects a nil name", function()
            local ok, err = pcall(function() Lifecycle:Register(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Lifecycle:Register: name is required (string)",
                1, true))
        end)

        it("rejects a non-string name", function()
            for _, bad in ipairs({ 42, true, {} }) do
                local ok, err = pcall(function() Lifecycle:Register(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Lifecycle:Register: name must be a string",
                    1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an empty-string name", function()
            local ok, err = pcall(function() Lifecycle:Register("") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Lifecycle:Register: name must be a non-empty string",
                1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register idempotency + initial state
    ---------------------------------------------------------------------------

    describe(":Register", function()
        it("returns an Addon at state 'Registered' on first call", function()
            local addon = Lifecycle:Register("TestAddon")
            assert.is_table(addon)
            assert.equals("TestAddon", addon.name)
            assert.equals("Registered", addon.state)
        end)

        it("is idempotent: same name returns the same Addon", function()
            local a = Lifecycle:Register("TestAddon")
            local b = Lifecycle:Register("TestAddon")
            assert.equals(a, b)
        end)

        it("distinct names yield distinct Addons", function()
            local a = Lifecycle:Register("AddonA")
            local b = Lifecycle:Register("AddonB")
            assert.is_not.equals(a, b)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Fresh-login bootstrap: ADDON_LOADED -> Loaded, PLAYER_LOGIN -> Enabled
    ---------------------------------------------------------------------------

    describe("fresh-login bootstrap", function()
        it("ADDON_LOADED transitions matching Addon to Loaded", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            assert.equals("Loaded", addon.state)
        end)

        it("ADDON_LOADED for an unknown name is a no-op", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("OtherAddon")
            assert.equals("Registered", addon.state)
        end)

        it("PLAYER_LOGIN drives every Loaded Addon to Enabled", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            assert.equals("Enabled", addon.state)
        end)

        it("PLAYER_LOGIN leaves still-Registered Addons untouched", function()
            local addon = Lifecycle:Register("TestAddon")
            -- ADDON_LOADED never fires -- addon stays Registered.
            mock:FirePlayerLogin()
            assert.equals("Registered", addon.state)
        end)

        it("fires OnReady then OnEnable in that order on first boot", function()
            local addon = Lifecycle:Register("TestAddon")
            local order = {}
            addon:OnReady(function() order[#order + 1] = "ready" end)
            addon:OnEnable(function() order[#order + 1] = "enable" end)

            mock:FireAddonLoaded("TestAddon")
            assert.same({}, order)  -- only Loaded; neither has fired yet.

            mock:FirePlayerLogin()
            assert.same({ "ready", "enable" }, order)
        end)

        it("PLAYER_LOGOUT is a no-op in v0", function()
            local addon = Lifecycle:Register("TestAddon")
            local disabled = false
            addon:OnDisable(function() disabled = true end)

            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            assert.equals("Enabled", addon.state)

            mock:FirePlayerLogout()
            assert.equals("Enabled", addon.state)
            assert.is_false(disabled)
        end)
    end)

    ---------------------------------------------------------------------------
    -- LoD fast-forward (/reload, on-demand load while logged in)
    ---------------------------------------------------------------------------

    describe("LoD fast-forward", function()
        it("transitions Registered -> Enabled synchronously inside :Register " ..
            "when IsAddOnLoaded and IsLoggedIn are both true", function()
            mock:MarkAddOnLoaded("TestAddon")
            mock:SetIsLoggedIn(true)

            local addon = Lifecycle:Register("TestAddon")
            assert.equals("Enabled", addon.state)
        end)

        it("stays Registered when only IsAddOnLoaded is true", function()
            mock:MarkAddOnLoaded("TestAddon")
            local addon = Lifecycle:Register("TestAddon")
            assert.equals("Registered", addon.state)
        end)

        it("stays Registered when only IsLoggedIn is true", function()
            mock:SetIsLoggedIn(true)
            local addon = Lifecycle:Register("TestAddon")
            assert.equals("Registered", addon.state)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Subscription validation
    ---------------------------------------------------------------------------

    describe("hook validation", function()
        it("OnReady rejects non-function fn", function()
            local addon = Lifecycle:Register("TestAddon")
            for _, bad in ipairs({ nil, 42, "x", {} }) do
                local ok, err = pcall(function() addon:OnReady(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Addon:OnReady: fn must be a function", 1, true))
            end
        end)

        it("OnEnable rejects non-function fn", function()
            local addon = Lifecycle:Register("TestAddon")
            local ok, err = pcall(function() addon:OnEnable(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Addon:OnEnable: fn must be a function", 1, true))
        end)

        it("OnDisable rejects non-function fn", function()
            local addon = Lifecycle:Register("TestAddon")
            local ok, err = pcall(function() addon:OnDisable(42) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Addon:OnDisable: fn must be a function", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Deferred-fire semantics
    ---------------------------------------------------------------------------

    describe("deferred fire", function()
        it("OnReady subscribed before Ready fires exactly once at Ready", function()
            local addon = Lifecycle:Register("TestAddon")
            local count = 0
            addon:OnReady(function() count = count + 1 end)

            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            assert.equals(1, count)
        end)

        it("OnReady subscribed AFTER Ready fires synchronously on subscribe", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            assert.equals("Enabled", addon.state)

            local count = 0
            addon:OnReady(function() count = count + 1 end)
            assert.equals(1, count)
        end)

        it("OnEnable subscribed AFTER Enabled fires synchronously on subscribe", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local count = 0
            addon:OnEnable(function() count = count + 1 end)
            assert.equals(1, count)
        end)

        it("OnDisable subscribed while Enabled does NOT fire immediately", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local count = 0
            addon:OnDisable(function() count = count + 1 end)
            assert.equals(0, count)

            addon:Disable()
            assert.equals(1, count)
        end)

        it("OnDisable subscribed while in Disabled state fires immediately", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            addon:Disable()

            local count = 0
            addon:OnDisable(function() count = count + 1 end)
            assert.equals(1, count)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Multiple subscribers + dispatch order
    ---------------------------------------------------------------------------

    describe("multiple subscribers", function()
        it("dispatches OnReady to every subscriber in registration order", function()
            local addon = Lifecycle:Register("TestAddon")
            local order = {}
            addon:OnReady(function() order[#order + 1] = "a" end)
            addon:OnReady(function() order[#order + 1] = "b" end)
            addon:OnReady(function() order[#order + 1] = "c" end)

            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            assert.same({ "a", "b", "c" }, order)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Snapshot-on-iterate + cancel-mid-dispatch
    ---------------------------------------------------------------------------

    describe("snapshot-on-iterate dispatcher", function()
        it("cancellation mid-dispatch still allows remaining subscribers " ..
            "to run; cancelled entry is swept after dispatch", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            addon:Disable()  -- subscribe while Disabled so fire-on-subscribe
                             -- (isEnabled(state)) does NOT trigger.

            local fires = {}
            local subB
            addon:OnEnable(function() fires[#fires + 1] = "a" end)
            subB = addon:OnEnable(function()
                fires[#fires + 1] = "b"
                subB:Cancel()
            end)
            addon:OnEnable(function() fires[#fires + 1] = "c" end)

            addon:Enable()
            assert.same({ "a", "b", "c" }, fires)

            -- Re-cycle: B is gone from the live list now.
            while fires[1] do table.remove(fires) end
            addon:Disable()
            addon:Enable()
            assert.same({ "a", "c" }, fires)
        end)
    end)

    ---------------------------------------------------------------------------
    -- SecureCall isolation
    ---------------------------------------------------------------------------

    describe("SecureCall isolation", function()
        it("a throwing OnReady callback does not abort the remaining " ..
            "subscribers and does not abort the state transition", function()
            -- Unset the pass-through securecallfunction so SecureCall falls
            -- through to its pcall + geterrorhandler shim. Production WoW
            -- traps the error via securecallfunction; the shim mirrors that.
            _G.securecallfunction = nil
            local handled = 0
            _G.geterrorhandler = function()
                return function() handled = handled + 1 end
            end

            local addon = Lifecycle:Register("TestAddon")
            local tail = 0
            addon:OnReady(function() error("boom") end)
            addon:OnReady(function() tail = tail + 1 end)

            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            assert.equals(1, tail)
            assert.equals(1, handled)
            assert.equals("Enabled", addon.state)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Enable / Disable / IsEnabled
    ---------------------------------------------------------------------------

    describe(":Enable / :Disable / :IsEnabled", function()
        it("raises if :Enable is called before Ready", function()
            local addon = Lifecycle:Register("TestAddon")
            local ok, err = pcall(function() addon:Enable() end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Addon:Enable: addon is not Ready yet", 1, true))
        end)

        it("raises if :Disable is called before Ready", function()
            local addon = Lifecycle:Register("TestAddon")
            local ok, err = pcall(function() addon:Disable() end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Addon:Disable: addon is not Ready yet", 1, true))
        end)

        it("IsEnabled tracks state transitions", function()
            local addon = Lifecycle:Register("TestAddon")
            assert.is_false(addon:IsEnabled())
            mock:FireAddonLoaded("TestAddon")
            assert.is_false(addon:IsEnabled())
            mock:FirePlayerLogin()
            assert.is_true(addon:IsEnabled())
            addon:Disable()
            assert.is_false(addon:IsEnabled())
            addon:Enable()
            assert.is_true(addon:IsEnabled())
        end)

        it("double :Disable is idempotent (no extra OnDisable fires)", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local count = 0
            addon:OnDisable(function() count = count + 1 end)
            addon:Disable()
            addon:Disable()
            assert.equals(1, count)
        end)

        it("double :Enable is idempotent (no extra OnEnable fires)", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local count = 0
            addon:OnEnable(function() count = count + 1 end)
            -- Already Enabled after PLAYER_LOGIN: subscriber fired once on
            -- subscribe. Re-calling :Enable must be a no-op.
            assert.equals(1, count)
            addon:Enable()
            assert.equals(1, count)
        end)

        it("OnDisable handler may call :Enable to abort the disable; " ..
            "final state is Enabled and the tracked bag is cleared", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local cancelled = 0
            local sub = DragonCore.Subscription.New(function()
                cancelled = cancelled + 1
            end)
            addon:Track(sub)

            addon:OnDisable(function()
                addon:Enable()
            end)

            addon:Disable()

            -- Cancel walk over the ORIGINAL bag still ran -- the tracked
            -- sub got Cancel'd. The bag is now empty; the re-enabled Addon
            -- starts fresh.
            assert.equals(1, cancelled)
            assert.equals("Enabled", addon.state)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Attach / :Get (namespace bag)
    ---------------------------------------------------------------------------

    describe(":Attach / :Get (namespace bag)", function()
        it("validates the name", function()
            local addon = Lifecycle:Register("TestAddon")
            for _, bad in ipairs({ nil, "", 42, {} }) do
                local ok, err = pcall(function() addon:Attach(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Addon:Attach: name must be a non-empty string",
                    1, true))
            end
            for _, bad in ipairs({ nil, "", 42, {} }) do
                local ok, err = pcall(function() addon:Get(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Addon:Get: name must be a non-empty string",
                    1, true))
            end
        end)

        it("defaults value to a fresh empty table when omitted", function()
            local addon = Lifecycle:Register("TestAddon")
            local ns = addon:Attach("Inventory")
            assert.is_table(ns)
            assert.equals(ns, addon:Get("Inventory"))
        end)

        it("stores the provided value verbatim", function()
            local addon = Lifecycle:Register("TestAddon")
            local payload = { greet = function() return "hi" end }
            local returned = addon:Attach("Greeter", payload)
            assert.equals(payload, returned)
            assert.equals(payload, addon:Get("Greeter"))
        end)

        it("raises on duplicate name", function()
            local addon = Lifecycle:Register("TestAddon")
            addon:Attach("Inventory")
            local ok, err = pcall(function() addon:Attach("Inventory") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Addon:Attach: namespace 'Inventory' is already attached",
                1, true))
        end)

        it(":Get returns nil for an unknown name", function()
            local addon = Lifecycle:Register("TestAddon")
            assert.is_nil(addon:Get("Nonexistent"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Track (resource bag)
    ---------------------------------------------------------------------------

    describe(":Track (resource bag)", function()
        it("validates the subscription", function()
            local addon = Lifecycle:Register("TestAddon")
            local ok1, err1 = pcall(function() addon:Track(nil) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Addon:Track: sub is required", 1, true))

            for _, bad in ipairs({ "x", 42, true }) do
                local ok, err = pcall(function() addon:Track(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Addon:Track: sub must be a DragonCore.Subscription",
                    1, true))
            end

            local ok2, err2 = pcall(function() addon:Track({}) end)
            assert.is_false(ok2)
            assert.is_truthy(err2:find(
                "missing :Cancel/:IsCancelled", 1, true))
        end)

        it("returns the subscription verbatim for chaining", function()
            local addon = Lifecycle:Register("TestAddon")
            local sub = DragonCore.Subscription.New(function() end)
            assert.equals(sub, addon:Track(sub))
        end)

        it(":Disable cancels every tracked subscription", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local count = 0
            for _ = 1, 3 do
                addon:Track(DragonCore.Subscription.New(function()
                    count = count + 1
                end))
            end

            addon:Disable()
            assert.equals(3, count)
        end)

        it(":Track on a Disabled Addon cancels the sub immediately and " ..
            "does NOT retain it in the bag", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()
            addon:Disable()

            local cancelled = 0
            local sub = DragonCore.Subscription.New(function()
                cancelled = cancelled + 1
            end)
            addon:Track(sub)
            assert.equals(1, cancelled)
            assert.is_true(sub:IsCancelled())

            -- Re-enabling and disabling must not cancel the sub a second time.
            addon:Enable()
            addon:Disable()
            assert.equals(1, cancelled)
        end)

        it("subscriptions Track'd during the cancel walk land in the fresh bag, " ..
            "not the snapshot being walked", function()
            local addon = Lifecycle:Register("TestAddon")
            mock:FireAddonLoaded("TestAddon")
            mock:FirePlayerLogin()

            local late
            addon:OnDisable(function()
                -- Re-enable so :Track does not auto-cancel, then track a
                -- new subscription. It must NOT be cancelled by the
                -- in-flight walk over the original snapshot.
                addon:Enable()
                late = DragonCore.Subscription.New(function() end)
                addon:Track(late)
            end)

            addon:Disable()
            assert.is_not_nil(late)
            assert.is_false(late:IsCancelled())
        end)
    end)

    ---------------------------------------------------------------------------
    -- PLAYER_LOGIN deterministic order (design note section 3.6)
    ---------------------------------------------------------------------------

    describe("PLAYER_LOGIN order", function()
        it("drives Loaded Addons to Enabled in registration order", function()
            local order = {}
            local a = Lifecycle:Register("AddonA")
            local b = Lifecycle:Register("AddonB")
            local c = Lifecycle:Register("AddonC")
            a:OnEnable(function() order[#order + 1] = "A" end)
            b:OnEnable(function() order[#order + 1] = "B" end)
            c:OnEnable(function() order[#order + 1] = "C" end)

            mock:FireAddonLoaded("AddonA")
            mock:FireAddonLoaded("AddonB")
            mock:FireAddonLoaded("AddonC")
            mock:FirePlayerLogin()

            assert.same({ "A", "B", "C" }, order)
        end)
    end)
end)
