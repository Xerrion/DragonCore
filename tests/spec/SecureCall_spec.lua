-------------------------------------------------------------------------------
-- SecureCall_spec.lua
-- Busted spec for DragonCore.SecureCall. Stubs `securecallfunction` and
-- `geterrorhandler` to exercise both the production-equivalent path and the
-- absent-global shim path. Per ADR-0003 R-5, the shim is the contract: tests
-- and production share the same wrapper.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")

describe("DragonCore.SecureCall", function()
    local SecureCall

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()
        dofile("Core/SecureCall.lua")
        SecureCall = LibStub("DragonCore-1.0").SecureCall
    end)

    it("invokes the callback and forwards its return value", function()
        _G.securecallfunction = function(fn, ...) return fn(...) end
        local result = SecureCall:Invoke(function(a, b) return a + b end, 2, 3)
        assert.are.equal(5, result)
    end)

    it("forwards multiple arguments and multiple return values", function()
        _G.securecallfunction = function(fn, ...) return fn(...) end
        local r1, r2, r3 = SecureCall:Invoke(function(a, b, c)
            return c, b, a
        end, "x", "y", "z")
        assert.are.equal("z", r1)
        assert.are.equal("y", r2)
        assert.are.equal("x", r3)
    end)

    it("dispatches through securecallfunction when the global is present", function()
        local called = false
        _G.securecallfunction = function(fn, ...)
            called = true
            return fn(...)
        end
        SecureCall:Invoke(function() end)
        assert.is_true(called)
    end)

    it("falls back to the shim and routes errors to geterrorhandler when securecallfunction is absent",
    function()
        -- _G.securecallfunction is nil at this point (reset_globals cleared it).
        local captured
        _G.geterrorhandler = function()
            return function(err) captured = err end
        end

        assert.has_no.errors(function()
            SecureCall:Invoke(function() error("boom") end)
        end)
        assert.is_string(captured)
        assert.is_truthy(captured:find("boom", 1, true))
    end)

    it("swallows errors silently when neither securecallfunction nor geterrorhandler is defined",
    function()
        -- Both globals nil after reset_globals.
        assert.has_no.errors(function()
            SecureCall:Invoke(function() error("nope") end)
        end)
    end)

    it("returns nothing when the callback errors on the shim path", function()
        _G.geterrorhandler = function() return function() end end
        local result = SecureCall:Invoke(function() error("x") end)
        assert.is_nil(result)
    end)

    it("rejects a non-function cb", function()
        _G.securecallfunction = function(fn, ...) return fn(...) end
        local function expectRejection(value)
            local ok, err = pcall(function() SecureCall:Invoke(value) end)
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_truthy(err:find(
                "DragonCore.SecureCall:Invoke: cb must be a function", 1, true))
        end
        expectRejection(nil)
        expectRejection(42)
        expectRejection("nope")
        expectRejection({})
    end)
end)
