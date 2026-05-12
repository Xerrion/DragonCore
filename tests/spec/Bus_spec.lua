-------------------------------------------------------------------------------
-- Bus_spec.lua
-- Busted spec for DragonCore.Bus. Loads Subscription -> SecureCall -> Bus.
-- Bus has no Frame so most specs do not need the mock at all, but the
-- harness is installed for the "FrameCount stays zero" structural assertion.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Bus", function()
    local DragonCore
    local Bus
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Bus.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Bus = DragonCore.Bus

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
            local ok, err = pcall(function() Bus:New(nil) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Bus:New: addon is required (DragonCore.Addon)", 1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() Bus:New(bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Bus:New: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function() Bus:New({}) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Bus:New: addon.name must be a non-empty string", 1, true))

            local ok2 = pcall(function() Bus:New({ name = "" }) end)
            assert.is_false(ok2)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :New frame contract: Bus has NO Frame
    ---------------------------------------------------------------------------

    describe(":New frame contract", function()
        it("creates ZERO Frames (Bus is frame-less)", function()
            assert.are.equal(0, mock:FrameCount())
            Bus:New(wow_mock.fakeAddon())
            Bus:New(wow_mock.fakeAddon("B"))
            assert.are.equal(0, mock:FrameCount())
        end)
    end)

    ---------------------------------------------------------------------------
    -- :On + :Send round-trip
    ---------------------------------------------------------------------------

    describe(":On + :Send", function()
        it("returns a Subscription; :Send invokes it with payload", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local received
            local sub = bus:On("loot.received", function(...) received = { ... } end)

            assert.is_function(sub.Cancel)
            bus:Send("loot.received", "Hearthstone", 6948, 1)
            assert.are.same({ "Hearthstone", 6948, 1 }, received)
        end)

        it("dispatches through SecureCall", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local secureCalls = 0
            _G.securecallfunction = function(fn, ...)
                secureCalls = secureCalls + 1
                return fn(...)
            end

            bus:On("t", function() end)
            bus:Send("t")
            assert.are.equal(1, secureCalls)
        end)

        it("multiple subscribers receive in registration order", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local order = {}
            bus:On("t", function() order[#order + 1] = "a" end)
            bus:On("t", function() order[#order + 1] = "b" end)
            bus:On("t", function() order[#order + 1] = "c" end)
            bus:Send("t")
            assert.are.same({ "a", "b", "c" }, order)
        end)

        it("topics with no subscribers are a no-op", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            assert.has_no.errors(function() bus:Send("nobody.listens") end)
        end)

        it("rejects non-string / empty topic on :On and :Send", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            assert.has_error(function() bus:On("", function() end) end)
            assert.has_error(function() bus:On(nil, function() end) end)
            assert.has_error(function() bus:Send("") end)
            assert.has_error(function() bus:Send(nil) end)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Flat string equality (no wildcards in v0)
    ---------------------------------------------------------------------------

    describe("topic equality", function()
        it("is flat string == (no dotted-prefix or wildcard matching)", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local prefixFires = 0
            local wildcardFires = 0
            bus:On("loot", function() prefixFires = prefixFires + 1 end)
            bus:On("loot.*", function() wildcardFires = wildcardFires + 1 end)

            bus:Send("loot.received")
            assert.are.equal(0, prefixFires)
            assert.are.equal(0, wildcardFires)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cancellation & snapshot-on-iterate
    ---------------------------------------------------------------------------

    describe("Subscription:Cancel", function()
        it("removes the subscriber; subsequent :Send does not call it", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local fires = 0
            local sub = bus:On("t", function() fires = fires + 1 end)

            bus:Send("t")
            assert.are.equal(1, fires)

            sub:Cancel()
            bus:Send("t")
            assert.are.equal(1, fires)
            assert.is_true(sub:IsCancelled())
        end)

        it("double-cancel is a no-op", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local sub = bus:On("t", function() end)
            assert.has_no.errors(function() sub:Cancel() end)
            assert.has_no.errors(function() sub:Cancel() end)
        end)
    end)

    describe("snapshot-on-iterate dispatch", function()
        it("a subscriber registered mid-send does NOT fire in the same send", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local lateFires = 0
            bus:On("t", function()
                bus:On("t", function() lateFires = lateFires + 1 end)
            end)

            bus:Send("t")
            assert.are.equal(0, lateFires)

            bus:Send("t")
            assert.are.equal(1, lateFires)
        end)

        it("a cancel of another subscriber mid-send takes effect immediately", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local bFires = 0
            local subB
            bus:On("t", function() subB:Cancel() end)
            subB = bus:On("t", function() bFires = bFires + 1 end)

            bus:Send("t")
            assert.are.equal(0, bFires)

            bus:Send("t")
            assert.are.equal(0, bFires)
        end)

        it("a throwing subscriber does NOT prevent siblings from firing", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            _G.securecallfunction = nil
            _G.geterrorhandler = function() return function() end end

            local aFired, bFired = false, false
            bus:On("t", function() aFired = true; error("boom") end)
            bus:On("t", function() bFired = true end)

            assert.has_no.errors(function() bus:Send("t") end)
            assert.is_true(aFired)
            assert.is_true(bFired)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Shared (Multiton)
    ---------------------------------------------------------------------------

    describe(":Shared", function()
        it("returns the same instance for the same channel string", function()
            local a = Bus:Shared("dragoncore.loot")
            local b = Bus:Shared("dragoncore.loot")
            assert.are.equal(a, b)
        end)

        it("returns distinct instances for different channels", function()
            local a = Bus:Shared("alpha")
            local b = Bus:Shared("beta")
            assert.are_not.equal(a, b)
        end)

        it("does not require an addon arg (per ADR-0003 line 260)", function()
            assert.has_no.errors(function() Bus:Shared("c") end)
        end)

        it("rejects non-string / empty channel", function()
            assert.has_error(function() Bus:Shared(nil) end)
            assert.has_error(function() Bus:Shared("") end)
            assert.has_error(function() Bus:Shared(42) end)
        end)

        it(":Dispose on a Shared instance evicts; next :Shared constructs fresh", function()
            local a = Bus:Shared("c")
            a:Dispose()

            local b = Bus:Shared("c")
            assert.are_not.equal(a, b)
            assert.is_false(b._disposed)
        end)

        it("supports :On / :Send between consumers", function()
            local writer = Bus:Shared("inter.addon")
            local reader = Bus:Shared("inter.addon")
            assert.are.equal(writer, reader)

            local received
            reader:On("ping", function(payload) received = payload end)
            writer:Send("ping", "hello")
            assert.are.equal("hello", received)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Dispose
    ---------------------------------------------------------------------------

    describe(":Dispose", function()
        it("cancels every subscription and rejects subsequent calls", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            local sub = bus:On("t", function() end)

            bus:Dispose()
            assert.is_true(sub:IsCancelled())
            assert.has_error(function() bus:On("t", function() end) end)
            assert.has_error(function() bus:Send("t") end)
        end)

        it("is idempotent", function()
            local bus = Bus:New(wow_mock.fakeAddon())
            bus:Dispose()
            assert.has_no.errors(function() bus:Dispose() end)
        end)
    end)
end)
