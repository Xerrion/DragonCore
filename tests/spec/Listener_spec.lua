-------------------------------------------------------------------------------
-- Listener_spec.lua
-- Busted spec for DragonCore.Listener. Loads the full foundation stack
-- (Subscription -> SecureCall -> Listener) and runs against the shared
-- mock from tests/support/wow_mock.lua. SecureCall is stubbed to a
-- pass-through wrapper unless a spec exercises the shim.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Listener", function()
    local DragonCore
    local Listener
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Dispatcher.lua")
        dofile("Core/Listener.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Listener = DragonCore.Listener

        mock = wow_mock.new()
        mock:Install()

        _G.securecallfunction = function(fn, ...) return fn(...) end
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :New validation (section 6.2 of design note)
    ---------------------------------------------------------------------------

    describe(":New validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function() Listener:New(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Listener:New: addon is required (DragonCore.Addon)", 1, true))
        end)

        it("rejects a non-table addon (string / number / boolean)", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() Listener:New(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Listener:New: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function() Listener:New({}) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Listener:New: addon.name must be a non-empty string", 1, true))

            local ok2, err2 = pcall(function() Listener:New({ name = "" }) end)
            assert.is_false(ok2)
            assert.is_truthy(err2:find(
                "addon.name must be a non-empty string", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :New frame contract (taint proxy assertions)
    ---------------------------------------------------------------------------

    describe(":New frame contract", function()
        it("creates exactly one unnamed Frame", function()
            assert.are.equal(0, mock:FrameCount())
            Listener:New(wow_mock.fakeAddon())
            assert.are.equal(1, mock:FrameCount())
        end)

        it("creates distinct frames per instance (Bulkhead grain)", function()
            local a = Listener:New(wow_mock.fakeAddon("A"))
            local b = Listener:New(wow_mock.fakeAddon("B"))
            assert.are.equal(2, mock:FrameCount())
            assert.are_not.equal(a._frame, b._frame)
        end)

        it("does NOT fire any user callback on :On registration", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local fired = false
            listener:On("PLAYER_LOGIN", function() fired = true end)
            assert.is_false(fired)  -- ADR Invariant D.2
        end)
    end)

    ---------------------------------------------------------------------------
    -- :On dispatch
    ---------------------------------------------------------------------------

    describe(":On", function()
        it("returns a Subscription; firing the event calls cb with payload", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local received
            local sub = listener:On("PLAYER_LOGIN", function(...) received = { ... } end)

            assert.is_function(sub.Cancel)
            assert.is_function(sub.IsCancelled)
            assert.is_false(sub:IsCancelled())

            mock:FireEvent("PLAYER_LOGIN", "arg1", 42, true)
            assert.are.same({ "arg1", 42, true }, received)
        end)

        it("dispatches through SecureCall", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local secureCalls = 0
            _G.securecallfunction = function(fn, ...)
                secureCalls = secureCalls + 1
                return fn(...)
            end

            listener:On("PLAYER_LOGIN", function() end)
            mock:FireEvent("PLAYER_LOGIN")

            assert.are.equal(1, secureCalls)
        end)

        it("invokes multiple handlers in registration order", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local order = {}
            listener:On("E", function() order[#order + 1] = 1 end)
            listener:On("E", function() order[#order + 1] = 2 end)
            listener:On("E", function() order[#order + 1] = 3 end)

            mock:FireEvent("E")
            assert.are.same({ 1, 2, 3 }, order)
        end)

        it("rejects non-string / empty event", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local ok1 = pcall(function() listener:On(nil, function() end) end)
            local ok2 = pcall(function() listener:On("", function() end) end)
            assert.is_false(ok1)
            assert.is_false(ok2)
        end)

        it("rejects non-function cb", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local ok = pcall(function() listener:On("E", "nope") end)
            assert.is_false(ok)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Unsubscribe & frame UnregisterEvent
    ---------------------------------------------------------------------------

    describe("Subscription:Cancel", function()
        it("removes the handler; subsequent fires do not call it", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local fires = 0
            local sub = listener:On("E", function() fires = fires + 1 end)

            mock:FireEvent("E")
            assert.are.equal(1, fires)

            sub:Cancel()
            mock:FireEvent("E")
            assert.are.equal(1, fires)
            assert.is_true(sub:IsCancelled())
        end)

        it("last-handler cancel triggers UnregisterEvent on the frame", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local sub = listener:On("E", function() end)

            assert.is_true(listener._frame._events["E"])

            sub:Cancel()
            assert.is_nil(listener._frame._events["E"])
        end)

        it("double-cancel is a no-op", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local sub = listener:On("E", function() end)
            assert.has_no.errors(function() sub:Cancel() end)
            assert.has_no.errors(function() sub:Cancel() end)
            assert.is_true(sub:IsCancelled())
        end)
    end)

    ---------------------------------------------------------------------------
    -- Snapshot-on-iterate
    ---------------------------------------------------------------------------

    describe("snapshot-on-iterate dispatch", function()
        it("a handler subscribing mid-dispatch does NOT fire in the same dispatch", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local lateFires = 0
            listener:On("E", function()
                listener:On("E", function() lateFires = lateFires + 1 end)
            end)

            mock:FireEvent("E")
            assert.are.equal(0, lateFires)

            mock:FireEvent("E")
            -- Second fire: the original handler runs again AND subscribes another
            -- handler; the previously-registered late handler fires once.
            assert.are.equal(1, lateFires)
        end)

        it("a handler cancelling another in-flight handler skips it on future fires", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local bFires = 0
            local subB
            listener:On("E", function() subB:Cancel() end)
            subB = listener:On("E", function() bFires = bFires + 1 end)

            -- First fire: handler A runs and cancels B BEFORE B's loop iteration
            -- reads its cancelled flag. With snapshot-on-iterate + cancel-flag
            -- check, B does NOT fire in this dispatch.
            mock:FireEvent("E")
            assert.are.equal(0, bFires)

            mock:FireEvent("E")
            assert.are.equal(0, bFires)
        end)

        it("a throwing handler does NOT prevent siblings from firing", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            -- Drop the per-test pass-through stub so SecureCall takes the
            -- shim path (pcall + geterrorhandler) and the throw is trapped.
            _G.securecallfunction = nil
            _G.geterrorhandler = function() return function() end end

            local aFired, bFired = false, false
            listener:On("E", function() aFired = true; error("boom") end)
            listener:On("E", function() bFired = true end)

            assert.has_no.errors(function() mock:FireEvent("E") end)
            assert.is_true(aFired)
            assert.is_true(bFired)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :OnceOnly
    ---------------------------------------------------------------------------

    describe(":OnceOnly", function()
        it("fires exactly once across multiple FireEvent calls", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local fires = 0
            listener:OnceOnly("E", function() fires = fires + 1 end)

            mock:FireEvent("E")
            mock:FireEvent("E")
            mock:FireEvent("E")
            assert.are.equal(1, fires)
        end)

        it("auto-unsubscribes after the first fire (UnregisterEvent when last)", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local sub = listener:OnceOnly("E", function() end)
            mock:FireEvent("E")
            assert.is_true(sub:IsCancelled())
            assert.is_nil(listener._frame._events["E"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- :OnUnit
    ---------------------------------------------------------------------------

    describe(":OnUnit", function()
        it("registers via RegisterUnitEvent (not plain RegisterEvent)", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            listener:OnUnit("UNIT_AURA", "player", nil, function() end)

            assert.is_table(listener._frame._unitEvents["UNIT_AURA"])
            assert.are.equal("player", listener._frame._unitEvents["UNIT_AURA"][1])
        end)

        it("fires only for the registered unit", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local received
            listener:OnUnit("UNIT_AURA", "player", nil, function(unit) received = unit end)

            mock:FireUnitEvent("UNIT_AURA", "target")
            assert.is_nil(received)

            mock:FireUnitEvent("UNIT_AURA", "player")
            assert.are.equal("player", received)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Off
    ---------------------------------------------------------------------------

    describe(":Off", function()
        it("with an event arg cancels every subscription for that event", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local fires = 0
            listener:On("E", function() fires = fires + 1 end)
            listener:On("E", function() fires = fires + 1 end)

            listener:Off("E")
            mock:FireEvent("E")
            assert.are.equal(0, fires)
            assert.is_nil(listener._frame._events["E"])
        end)

        it("without arg cancels every subscription on the Listener", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local eFires, fFires = 0, 0
            listener:On("E", function() eFires = eFires + 1 end)
            listener:On("F", function() fFires = fFires + 1 end)

            listener:Off()
            mock:FireEvent("E")
            mock:FireEvent("F")
            assert.are.equal(0, eFires)
            assert.are.equal(0, fFires)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Dispose
    ---------------------------------------------------------------------------

    describe(":Dispose", function()
        it("unregisters every event and cancels every subscription", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            local subE = listener:On("E", function() end)
            local subF = listener:On("F", function() end)

            listener:Dispose()
            assert.is_true(subE:IsCancelled())
            assert.is_true(subF:IsCancelled())
        end)

        it("makes subsequent :On / :Off raise", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            listener:Dispose()
            assert.has_error(function() listener:On("E", function() end) end)
            assert.has_error(function() listener:OnceOnly("E", function() end) end)
            assert.has_error(function() listener:OnUnit("E", "player", nil, function() end) end)
            assert.has_error(function() listener:Off("E") end)
        end)

        it("is idempotent (double dispose is a no-op)", function()
            local listener = Listener:New(wow_mock.fakeAddon())
            listener:Dispose()
            assert.has_no.errors(function() listener:Dispose() end)
        end)
    end)
end)
