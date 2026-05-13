-------------------------------------------------------------------------------
-- EventBus_spec.lua
-- Busted spec for DragonCore.EventBus. Loads Subscription -> SecureCall -> EventBus.
-- EventBus has no Frame so most specs do not need the mock at all, but the
-- harness is installed for the "FrameCount stays zero" structural assertion.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.EventBus", function()
    local DragonCore
    local EventBus
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Dispatcher.lua")
        dofile("Core/EventBus.lua")

        DragonCore = LibStub("DragonCore-1.0")
        EventBus = DragonCore.EventBus

        mock = wow_mock.new()
        mock:Install()

        _G.securecallfunction = function(fn, ...) return fn(...) end
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :New validation
    ---------------------------------------------------------------------------

    describe(":New validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function() EventBus:New(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.EventBus:New: addon is required (DragonCore.Addon)", 1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() EventBus:New(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.EventBus:New: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function() EventBus:New({}) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.EventBus:New: addon.name must be a non-empty string", 1, true))

            local ok2 = pcall(function() EventBus:New({ name = "" }) end)
            assert.is_false(ok2)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :New frame contract: EventBus has NO Frame
    ---------------------------------------------------------------------------

    describe(":New frame contract", function()
        it("creates ZERO Frames (EventBus is frame-less)", function()
            assert.are.equal(0, mock:FrameCount())
            EventBus:New(wow_mock.fakeAddon())
            EventBus:New(wow_mock.fakeAddon("B"))
            assert.are.equal(0, mock:FrameCount())
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Subscribe + :Publish round-trip
    ---------------------------------------------------------------------------

    describe(":Subscribe + :Publish", function()
        it("returns a Subscription; :Publish invokes it with payload", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local received
            local sub = bus:Subscribe("loot.received", function(...) received = { ... } end)

            assert.is_function(sub.Cancel)
            bus:Publish("loot.received", "Hearthstone", 6948, 1)
            assert.are.same({ "Hearthstone", 6948, 1 }, received)
        end)

        it("dispatches through SecureCall", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local secureCalls = 0
            _G.securecallfunction = function(fn, ...)
                secureCalls = secureCalls + 1
                return fn(...)
            end

            bus:Subscribe("t", function() end)
            bus:Publish("t")
            assert.are.equal(1, secureCalls)
        end)

        it("multiple subscribers receive in registration order", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local order = {}
            bus:Subscribe("t", function() order[#order + 1] = "a" end)
            bus:Subscribe("t", function() order[#order + 1] = "b" end)
            bus:Subscribe("t", function() order[#order + 1] = "c" end)
            bus:Publish("t")
            assert.are.same({ "a", "b", "c" }, order)
        end)

        it("topics with no subscribers are a no-op", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            assert.has_no.errors(function() bus:Publish("nobody.listens") end)
        end)

        it("rejects non-string / empty topic on :Subscribe and :Publish", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            assert.has_error(function() bus:Subscribe("", function() end) end)
            assert.has_error(function() bus:Subscribe(nil, function() end) end)
            assert.has_error(function() bus:Publish("") end)
            assert.has_error(function() bus:Publish(nil) end)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Flat string equality (no wildcards in v0)
    ---------------------------------------------------------------------------

    describe("topic equality", function()
        it("is flat string == (no dotted-prefix or wildcard matching)", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local prefixFires = 0
            local wildcardFires = 0
            bus:Subscribe("loot", function() prefixFires = prefixFires + 1 end)
            bus:Subscribe("loot.*", function() wildcardFires = wildcardFires + 1 end)

            bus:Publish("loot.received")
            assert.are.equal(0, prefixFires)
            assert.are.equal(0, wildcardFires)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cancellation & snapshot-on-iterate
    ---------------------------------------------------------------------------

    describe("Subscription:Cancel", function()
        it("removes the subscriber; subsequent :Publish does not call it", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local fires = 0
            local sub = bus:Subscribe("t", function() fires = fires + 1 end)

            bus:Publish("t")
            assert.are.equal(1, fires)

            sub:Cancel()
            bus:Publish("t")
            assert.are.equal(1, fires)
            assert.is_true(sub:IsCancelled())
        end)

        it("double-cancel is a no-op", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local sub = bus:Subscribe("t", function() end)
            assert.has_no.errors(function() sub:Cancel() end)
            assert.has_no.errors(function() sub:Cancel() end)
        end)
    end)

    describe("snapshot-on-iterate dispatch", function()
        it("a subscriber registered mid-send does NOT fire in the same send", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local lateFires = 0
            bus:Subscribe("t", function()
                bus:Subscribe("t", function() lateFires = lateFires + 1 end)
            end)

            bus:Publish("t")
            assert.are.equal(0, lateFires)

            bus:Publish("t")
            assert.are.equal(1, lateFires)
        end)

        it("a cancel of another subscriber mid-send takes effect immediately", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local bFires = 0
            local subB
            bus:Subscribe("t", function() subB:Cancel() end)
            subB = bus:Subscribe("t", function() bFires = bFires + 1 end)

            bus:Publish("t")
            assert.are.equal(0, bFires)

            bus:Publish("t")
            assert.are.equal(0, bFires)
        end)

        it("a throwing subscriber does NOT prevent siblings from firing", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            _G.securecallfunction = nil
            _G.geterrorhandler = function() return function() end end

            local aFired, bFired = false, false
            bus:Subscribe("t", function() aFired = true; error("boom") end)
            bus:Subscribe("t", function() bFired = true end)

            assert.has_no.errors(function() bus:Publish("t") end)
            assert.is_true(aFired)
            assert.is_true(bFired)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Shared (Multiton)
    ---------------------------------------------------------------------------

    describe(":Shared", function()
        it("returns the same instance for the same channel string", function()
            local a = EventBus:Shared("dragoncore.loot")
            local b = EventBus:Shared("dragoncore.loot")
            assert.are.equal(a, b)
        end)

        it("returns distinct instances for different channels", function()
            local a = EventBus:Shared("alpha")
            local b = EventBus:Shared("beta")
            assert.are_not.equal(a, b)
        end)

        it("does not require an addon arg (per ADR-0003 line 260)", function()
            assert.has_no.errors(function() EventBus:Shared("c") end)
        end)

        it("rejects non-string / empty channel", function()
            assert.has_error(function() EventBus:Shared(nil) end)
            assert.has_error(function() EventBus:Shared("") end)
            assert.has_error(function() EventBus:Shared(42) end)
        end)

        it(":Dispose on a Shared instance evicts; next :Shared constructs fresh", function()
            local a = EventBus:Shared("c")
            a:Dispose()

            local b = EventBus:Shared("c")
            assert.are_not.equal(a, b)
            assert.is_false(b._disposed)
        end)

        it("supports :Subscribe / :Publish between consumers", function()
            local writer = EventBus:Shared("inter.addon")
            local reader = EventBus:Shared("inter.addon")
            assert.are.equal(writer, reader)

            local received
            reader:Subscribe("ping", function(payload) received = payload end)
            writer:Publish("ping", "hello")
            assert.are.equal("hello", received)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Dispose
    ---------------------------------------------------------------------------

    describe(":Dispose", function()
        it("cancels every subscription and rejects subsequent calls", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            local sub = bus:Subscribe("t", function() end)

            bus:Dispose()
            assert.is_true(sub:IsCancelled())
            assert.has_error(function() bus:Subscribe("t", function() end) end)
            assert.has_error(function() bus:Publish("t") end)
        end)

        it("is idempotent", function()
            local bus = EventBus:New(wow_mock.fakeAddon())
            bus:Dispose()
            assert.has_no.errors(function() bus:Dispose() end)
        end)
    end)
end)
