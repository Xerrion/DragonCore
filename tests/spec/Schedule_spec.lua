-------------------------------------------------------------------------------
-- Schedule_spec.lua
-- Busted spec for DragonCore.Schedule. Loads the full foundation stack
-- (Subscription -> SecureCall -> Schedule) and runs against the shared
-- virtual-clock mock from tests/support/wow_mock.lua per ADR-0003 section F.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Schedule", function()
    local DragonCore
    local Schedule
    local mock

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        -- Foundation stack must load in dependency order: Subscription and
        -- SecureCall are resolved lazily by Schedule, but the lookup must
        -- succeed at call time.
        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Schedule.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Schedule = DragonCore.Schedule

        mock = wow_mock.new()
        mock:Install()

        -- Default SecureCall stub: production-equivalent pass-through. Specs
        -- that need to assert dispatch-through-SecureCall override locally.
        _G.securecallfunction = function(fn, ...) return fn(...) end
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :After
    ---------------------------------------------------------------------------

    describe(":After", function()
        it("fires the callback after the delay, not before", function()
            local fired = false
            Schedule:After(1.0, function() fired = true end)

            mock:AdvanceTime(0.5)
            assert.is_false(fired)

            mock:AdvanceTime(0.5)
            assert.is_true(fired)
        end)

        it("dispatches the callback through SecureCall", function()
            local secureCalls = 0
            _G.securecallfunction = function(fn, ...)
                secureCalls = secureCalls + 1
                return fn(...)
            end

            Schedule:After(0.1, function() end)
            mock:AdvanceTime(0.1)

            assert.are.equal(1, secureCalls)
        end)

        it("cancellation before fire prevents the callback", function()
            local fired = false
            local sub = Schedule:After(1.0, function() fired = true end)
            sub:Cancel()

            mock:AdvanceTime(2.0)
            assert.is_false(fired)
        end)

        it("cancellation after fire is a no-op (idempotent double-cancel)", function()
            local fired = false
            local sub = Schedule:After(0.1, function() fired = true end)

            mock:AdvanceTime(0.1)
            assert.is_true(fired)

            assert.has_no.errors(function() sub:Cancel() end)
            assert.has_no.errors(function() sub:Cancel() end)
            assert.is_true(sub:IsCancelled())
        end)

        it("routes callback errors to geterrorhandler via the SecureCall shim", function()
            -- Drop the per-test pass-through stub so SecureCall takes the
            -- shim path (pcall + geterrorhandler).
            _G.securecallfunction = nil
            local captured
            _G.geterrorhandler = function()
                return function(err) captured = err end
            end

            Schedule:After(0.1, function() error("boom") end)
            assert.has_no.errors(function() mock:AdvanceTime(0.1) end)
            assert.is_string(captured)
            assert.is_truthy(captured:find("boom", 1, true))
        end)

        it("rejects a negative delay", function()
            local ok, err = pcall(function()
                Schedule:After(-1, function() end)
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("delay must be >= 0", 1, true))
        end)

        it("rejects a non-function cb", function()
            local ok, err = pcall(function() Schedule:After(0.1, "nope") end)
            assert.is_false(ok)
            assert.is_truthy(err:find("cb must be a function", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Every
    ---------------------------------------------------------------------------

    describe(":Every", function()
        it("fires the callback at each interval boundary", function()
            local fires = 0
            Schedule:Every(1.0, function() fires = fires + 1 end)

            mock:AdvanceTime(3.5)
            assert.are.equal(3, fires)
        end)

        it("cancellation stops future fires", function()
            local fires = 0
            local sub = Schedule:Every(1.0, function() fires = fires + 1 end)

            mock:AdvanceTime(2.0)
            assert.are.equal(2, fires)

            sub:Cancel()
            mock:AdvanceTime(5.0)
            assert.are.equal(2, fires)
        end)

        it("a throwing callback does NOT stop subsequent fires", function()
            -- Route errors through the shim path so the throw is trapped.
            _G.securecallfunction = nil
            _G.geterrorhandler = function() return function() end end

            local fires = 0
            Schedule:Every(1.0, function()
                fires = fires + 1
                error("each-tick boom")
            end)

            assert.has_no.errors(function() mock:AdvanceTime(3.0) end)
            assert.are.equal(3, fires)
        end)

        it("re-entrant cancel from inside the callback is safe", function()
            local fires = 0
            local sub
            sub = Schedule:Every(1.0, function()
                fires = fires + 1
                sub:Cancel()
            end)

            mock:AdvanceTime(5.0)
            assert.are.equal(1, fires)
            assert.is_true(sub:IsCancelled())
        end)

        it("rejects a zero or negative interval", function()
            local ok1 = pcall(function() Schedule:Every(0, function() end) end)
            local ok2 = pcall(function() Schedule:Every(-1, function() end) end)
            assert.is_false(ok1)
            assert.is_false(ok2)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :NextFrame
    ---------------------------------------------------------------------------

    describe(":NextFrame", function()
        it("fires the callback on the next AdvanceTime(0)", function()
            local fired = false
            Schedule:NextFrame(function() fired = true end)

            mock:AdvanceTime(0)
            assert.is_true(fired)
        end)

        it("dispatches the callback through SecureCall", function()
            local secureCalls = 0
            _G.securecallfunction = function(fn, ...)
                secureCalls = secureCalls + 1
                return fn(...)
            end

            Schedule:NextFrame(function() end)
            mock:AdvanceTime(0)

            assert.are.equal(1, secureCalls)
        end)

        it("cancellation before the next advance prevents the callback", function()
            local fired = false
            local sub = Schedule:NextFrame(function() fired = true end)
            sub:Cancel()

            mock:AdvanceTime(0)
            assert.is_false(fired)
        end)

        it("rejects a non-function cb", function()
            local ok, err = pcall(function() Schedule:NextFrame("nope") end)
            assert.is_false(ok)
            assert.is_truthy(err:find("cb must be a function", 1, true))
        end)
    end)
end)
