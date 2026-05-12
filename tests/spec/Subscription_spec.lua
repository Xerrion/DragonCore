-------------------------------------------------------------------------------
-- Subscription_spec.lua
-- Busted spec for DragonCore.Subscription. Pure Lua; no WoW mock required.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")

describe("DragonCore.Subscription", function()
    local Subscription

    before_each(function()
        -- Clean LibStub + WoW global state, then rebuild Subscription from
        -- source. Subscription itself is pure Lua, but we still wipe WoW
        -- globals so a prior spec's mock cannot leak in.
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()
        dofile("Core/Subscription.lua")
        Subscription = LibStub("DragonCore-1.0").Subscription
    end)

    it("constructs a fresh subscription that is not cancelled", function()
        local sub = Subscription.New()
        assert.is_false(sub:IsCancelled())
    end)

    it("supports a Subscription with no onCancel (Cancel never errors)", function()
        local sub = Subscription.New()
        assert.has_no.errors(function() sub:Cancel() end)
        assert.is_true(sub:IsCancelled())
    end)

    it("invokes onCancel exactly once on the first Cancel", function()
        local calls = 0
        local sub = Subscription.New(function() calls = calls + 1 end)
        sub:Cancel()
        sub:Cancel()
        sub:Cancel()
        assert.are.equal(1, calls)
        assert.is_true(sub:IsCancelled())
    end)

    it("is idempotent: re-Cancel leaves the cancelled flag stable", function()
        local sub = Subscription.New(function() end)
        sub:Cancel()
        assert.is_true(sub:IsCancelled())
        sub:Cancel()
        assert.is_true(sub:IsCancelled())
    end)

    it("flips the cancelled flag even when onCancel throws", function()
        local sub = Subscription.New(function() error("boom") end)
        assert.has_no.errors(function() sub:Cancel() end)
        assert.is_true(sub:IsCancelled())
        -- Second Cancel is still a no-op and must not re-raise.
        assert.has_no.errors(function() sub:Cancel() end)
        assert.is_true(sub:IsCancelled())
    end)

    it("does not re-invoke a throwing onCancel on subsequent Cancels", function()
        local calls = 0
        local sub = Subscription.New(function()
            calls = calls + 1
            error("boom")
        end)
        sub:Cancel()
        sub:Cancel()
        assert.are.equal(1, calls)
    end)

    it("rejects a non-function onCancel at construction", function()
        local function expectRejection(value)
            local ok, err = pcall(Subscription.New, value)
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_truthy(err:find(
                "DragonCore.Subscription.New: onCancel must be a function or nil", 1, true))
        end
        expectRejection(42)
        expectRejection("nope")
        expectRejection({})
    end)

    it("returns distinct instances with independent cancellation state", function()
        local a = Subscription.New()
        local b = Subscription.New()
        a:Cancel()
        assert.is_true(a:IsCancelled())
        assert.is_false(b:IsCancelled())
    end)
end)
