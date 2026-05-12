-------------------------------------------------------------------------------
-- Schedule.lua
-- DragonCore time-scheduling primitive: one-shot, recurring, and next-frame
-- callbacks, each returning a cancellable Subscription. Every user callback
-- is dispatched through DragonCore.SecureCall:Invoke per ADR-0003 Invariant
-- D.3 so taint cannot leak through scheduled fires and a throwing callback
-- cannot kill a ticker.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

-- Module-attach pattern (option a): mirrors Subscription / Capabilities /
-- SecureCall. Any DragonCore file may be loaded first; NewLibrary-or-
-- GetLibrary keeps the shared table alive across modules.
local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Schedule
--
-- Subscription and SecureCall are resolved lazily inside each method rather
-- than captured at module load. This matches SecureCall's `_G.securecallfunction`
-- pattern: it lets specs `dofile` modules in any order, and the cost is one
-- table lookup per dispatch. Production load order is controlled, so the
-- lookup is never observed to fail.
-------------------------------------------------------------------------------

---@class DragonCore.Schedule
local Schedule = {}

-- Internal helper: resolve foundation dependencies at call time. Raises a
-- clear error if either is missing (programmer error; production never hits
-- this branch because the TOC loads Subscription + SecureCall before Schedule).
local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    if not subscription then
        error("DragonCore.Schedule: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Schedule: DragonCore.SecureCall is not loaded", 3)
    end
    return subscription, secureCall
end

-- Internal helper: validate the (delay, cb) shape used by :After and the
-- (interval, cb) shape used by :Every. The error message names the caller
-- via `label`; the level=3 jump targets the consumer call site, not this
-- helper or the public method that delegated to it.
local function validateNumberAndFunction(label, paramName, value, cb, allowZero)
    if type(value) ~= "number" then
        error(label .. ": " .. paramName .. " must be a number", 3)
    end
    if allowZero then
        if value < 0 then
            error(label .. ": " .. paramName .. " must be >= 0", 3)
        end
    else
        if value <= 0 then
            error(label .. ": " .. paramName .. " must be > 0", 3)
        end
    end
    if type(cb) ~= "function" then
        error(label .. ": cb must be a function", 3)
    end
end

---Schedule a one-shot callback to fire after `delay` seconds. Cancellation
---before the fire prevents the callback; cancellation after the fire is a
---safe no-op.
---@param delay number              non-negative seconds.
---@param cb fun()                  consumer callback; dispatched through SecureCall.
---@return DragonCore.Subscription
function Schedule:After(delay, cb)
    validateNumberAndFunction("DragonCore.Schedule:After", "delay", delay, cb, true)
    local Subscription, SecureCall = resolveDeps()

    local cancelled = false
    local sub = Subscription.New(function() cancelled = true end)

    C_Timer.After(delay, function()
        if cancelled then return end
        SecureCall:Invoke(cb)
    end)

    return sub
end

---Schedule a repeating callback to fire every `interval` seconds. The ticker
---is owned by the returned Subscription; cancellation stops all future fires.
---A throwing `cb` does NOT stop the ticker -- errors are trapped by SecureCall
---and routed to `geterrorhandler()`.
---@param interval number           positive seconds.
---@param cb fun()                  consumer callback; dispatched through SecureCall.
---@return DragonCore.Subscription
function Schedule:Every(interval, cb)
    validateNumberAndFunction("DragonCore.Schedule:Every", "interval", interval, cb, false)
    local Subscription, SecureCall = resolveDeps()

    local ticker = C_Timer.NewTicker(interval, function()
        SecureCall:Invoke(cb)
    end)

    return Subscription.New(function() ticker:Cancel() end)
end

---Schedule a one-shot callback to fire on the next frame tick. Implemented
---as `C_Timer.After(0, cb)` per ADR-0003 (no private OnUpdate frame; the
---next-tick semantics of C_Timer with delay 0 are sufficient and avoid a
---taint surface).
---@param cb fun()                  consumer callback; dispatched through SecureCall.
---@return DragonCore.Subscription
function Schedule:NextFrame(cb)
    if type(cb) ~= "function" then
        error("DragonCore.Schedule:NextFrame: cb must be a function", 2)
    end
    local Subscription, SecureCall = resolveDeps()

    local cancelled = false
    local sub = Subscription.New(function() cancelled = true end)

    C_Timer.After(0, function()
        if cancelled then return end
        SecureCall:Invoke(cb)
    end)

    return sub
end

DragonCore.Schedule = Schedule
