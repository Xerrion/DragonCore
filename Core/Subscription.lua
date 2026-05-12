-------------------------------------------------------------------------------
-- Subscription.lua
-- DragonCore async primitive: a cancellable handle for scheduled callbacks
-- and registered event handlers. Pure Lua, no WoW-API dependency.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

-- Module-attach pattern (option a): each DragonCore file calls NewLibrary at
-- the shared MAJOR/MINOR and falls back to GetLibrary so any file can be
-- loaded first. This mirrors the AceEvent / AceDB family. A dedicated
-- bootstrap file may be introduced later; for v0 the get-or-create idiom is
-- sufficient.
local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Subscription
-------------------------------------------------------------------------------

---@class DragonCore.Subscription
---@field private _cancelled boolean
---@field private _onCancel fun()|nil
local Subscription = {}
Subscription.__index = Subscription

---Create a new Subscription.
---@param onCancel fun()|nil  optional callback invoked exactly once on the
---                           first :Cancel(); thrown errors are swallowed so
---                           a misbehaving callback cannot leave the
---                           subscription in an un-cancelled state.
---@return DragonCore.Subscription
function Subscription.New(onCancel)
    if onCancel ~= nil and type(onCancel) ~= "function" then
        error("DragonCore.Subscription.New: onCancel must be a function or nil", 2)
    end

    local self = setmetatable({}, Subscription)
    self._cancelled = false
    self._onCancel = onCancel
    return self
end

---Cancel the subscription. Idempotent: only the first call invokes onCancel
---and flips the internal flag; subsequent calls are no-ops.
---@return nil
function Subscription:Cancel()
    if self._cancelled then return end

    self._cancelled = true
    local onCancel = self._onCancel
    self._onCancel = nil  -- release the closure once it has run / been skipped
    if onCancel then
        pcall(onCancel)
    end
end

---@return boolean
function Subscription:IsCancelled()
    return self._cancelled
end

DragonCore.Subscription = Subscription
