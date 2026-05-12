-------------------------------------------------------------------------------
-- SecureCall.lua
-- DragonCore taint-isolation primitive: a thin wrapper around the WoW global
-- `securecallfunction` for dispatching consumer callbacks without leaking
-- caller taint. Shims to a `pcall` + `geterrorhandler()` equivalent when the
-- global is unavailable (test harness, Lua-only environments).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

-- Module-attach pattern (option a): mirrors Subscription / Capabilities. Any
-- DragonCore file may be loaded first; NewLibrary-or-GetLibrary keeps the
-- shared table alive across modules.
local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- SecureCall
--
-- Per ADR-0003 Invariant D.3 ("Every user-callback invocation is wrapped in
-- `securecallfunction`") and risk R-5, the shim resolves `securecallfunction`
-- lazily at every call site rather than at module-load. This lets test specs
-- inject the stub after `dofile`-ing the module and keeps production behaviour
-- equivalent (the global is set by the WoW client well before DragonCore code
-- runs).
--
-- Fallback semantics: when `securecallfunction` is absent, errors are routed
-- to `geterrorhandler()(err)` if defined, else swallowed silently. Either way,
-- the error never propagates to the caller, matching real-client behaviour
-- where `securecallfunction` traps errors via the default error handler.
-------------------------------------------------------------------------------

---@class DragonCore.SecureCall
local SecureCall = {}

---Dispatch `cb(...)` under `securecallfunction` so caller taint does not leak
---into the callback. Errors in `cb` are trapped (routed to the WoW error
---handler in production, to `geterrorhandler()` in the fallback path) and
---never propagate. Returns whatever `cb` returns on success; returns nothing
---when `cb` errors.
---@param cb fun(...):...  consumer callback to dispatch.
---@param ... any           arguments forwarded to `cb`.
---@return any ...          forwarded return values from `cb` on success.
function SecureCall:Invoke(cb, ...)
    if type(cb) ~= "function" then
        error("DragonCore.SecureCall:Invoke: cb must be a function", 2)
    end

    local secure = _G.securecallfunction
    if type(secure) == "function" then
        return secure(cb, ...)
    end

    -- Shim path: pcall and route errors. Production never reaches this branch
    -- because the WoW client always defines `securecallfunction`. Multi-return
    -- is preserved by capturing the pcall results into a sequence and
    -- forwarding via `unpack`.
    local results = { pcall(cb, ...) }
    if results[1] then
        return unpack(results, 2, #results)
    end

    local err = results[2]
    local handler = _G.geterrorhandler
    if type(handler) == "function" then
        local h = handler()
        if type(h) == "function" then
            pcall(h, err)
        end
    end
    -- error swallowed
end

DragonCore.SecureCall = SecureCall
