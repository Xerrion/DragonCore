-------------------------------------------------------------------------------
-- Listener.lua
-- DragonCore game-event dispatcher: one unnamed Frame per Listener instance,
-- snapshot-on-iterate dispatch, every consumer callback routed through
-- DragonCore.SecureCall:Invoke. This module exists to make the
-- AceEvent30Frame failure mode structurally impossible in DragonCore.
--
-- The failure mode (workspace AGENTS.md, "Known Gotchas -> Ace3
-- AceEvent30Frame is a shared global"): AceEvent-3.0 uses a single named
-- global frame shared by every Ace3 consumer. A tainted upstream consumer
-- triggering RegisterEvent through CallbackHandler-1.0's `OnUsed` lazy path
-- (which is NOT wrapped in securecallfunction) poisons that shared frame.
-- Subsequent clean addons inherit the taint and crash with
-- ADDON_ACTION_FORBIDDEN. The "honey taste test" then blames whoever touched
-- the stack last.
--
-- DragonCore.Listener answers that with four structural primitives:
--   (a) CreateFrame("Frame") with NO `name` argument: per-instance unnamed
--       frame, no shared global to poison.
--   (b) SecureCall:Invoke wraps every dispatch: caller taint stays out of
--       the consumer callback (ADR-0003 Invariant D.3).
--   (c) No user callback fires on the registration path (ADR Invariant D.2):
--       :On / :OnceOnly / :OnUnit are pure registry mutations.
--   (d) Snapshot-on-iterate dispatch: a handler that subscribes or cancels
--       another handler from inside its body cannot corrupt the in-flight
--       iteration (ADR OQ-5).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution (mirrors Schedule's resolveDeps pattern).
-- Production load order is controlled by the TOC (Subscription / SecureCall
-- load before Listener); the lookup is never observed to fail. The lazy
-- shape keeps spec dofile order flexible.
-------------------------------------------------------------------------------

local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    if not subscription then
        error("DragonCore.Listener: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Listener: DragonCore.SecureCall is not loaded", 3)
    end
    return subscription, secureCall
end

-------------------------------------------------------------------------------
-- Validation (section 6.2 of LISTENER-BUS design note)
--
-- error(..., 3) so the reported source position is the consumer's call
-- site -- the helper and the public method are both peeled off the stack.
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.Listener:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.Listener:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.Listener:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

local function validateEvent(method, event)
    if type(event) ~= "string" or event == "" then
        error("DragonCore.Listener:" .. method ..
            ": event must be a non-empty string", 3)
    end
end

local function validateCb(method, cb)
    if type(cb) ~= "function" then
        error("DragonCore.Listener:" .. method ..
            ": cb must be a function", 3)
    end
end

local function checkLive(self, method)
    if self._disposed then
        error("DragonCore.Listener:" .. method ..
            ": Listener has been disposed (addon=" .. self._addon.name .. ")", 3)
    end
end

-------------------------------------------------------------------------------
-- Listener
-------------------------------------------------------------------------------

---@class DragonCore.Listener
---@field private _frame table
---@field private _subs table<string, table[]>
---@field private _addon DragonCore.Addon
---@field private _disposed boolean
---@field private _dispatchDepth table<string, integer>
---@field private _sweepQueued table<string, boolean>
local Listener = {}
Listener.__index = Listener

-- Internal helper: rebuild self._subs[event], dropping cancelled entries.
-- When the resulting list is empty, unregister the event from the frame and
-- drop the slot entirely. Called outside dispatch or queued for end-of-
-- dispatch via self._sweepQueued (see :_dispatch below).
local function sweep(self, event)
    local list = self._subs[event]
    if not list then return end
    local live = {}
    for i = 1, #list do
        if not list[i].cancelled then live[#live + 1] = list[i] end
    end
    if #live == 0 then
        self._subs[event] = nil
        if not self._disposed then
            self._frame:UnregisterEvent(event)
        end
    else
        self._subs[event] = live
    end
end

-- Internal helper: snapshot-on-iterate dispatch for `event`. Iterates the
-- list captured at the top of the loop; entries cancelled mid-dispatch are
-- skipped; entries added mid-dispatch are NOT visible until the next fire.
local function dispatch(self, event, ...)
    if self._disposed then return end
    local list = self._subs[event]
    if not list then return end

    self._dispatchDepth[event] = (self._dispatchDepth[event] or 0) + 1
    local _, SecureCall = resolveDeps()
    local len = #list
    for i = 1, len do
        local entry = list[i]
        if not entry.cancelled then
            -- `:OnceOnly` semantics: cancel the Subscription BEFORE invoking
            -- so once-ness holds even if the handler errors AND so the
            -- consumer-visible `sub:IsCancelled()` reports true after the
            -- single fire. Subscription:Cancel is idempotent; its onCancel
            -- flips entry.cancelled and queues a sweep (we are inside
            -- dispatch, so the sweep is deferred to end-of-dispatch).
            if entry.once and entry.sub then
                entry.sub:Cancel()
            end
            SecureCall:Invoke(entry.cb, ...)
        end
    end
    self._dispatchDepth[event] = self._dispatchDepth[event] - 1

    if self._dispatchDepth[event] == 0 then
        self._dispatchDepth[event] = nil
        if self._sweepQueued[event] then
            self._sweepQueued[event] = nil
            sweep(self, event)
        end
    end
end

-- Internal helper: add a sub entry to self._subs[event] and register the
-- event on the frame if this is the first sub for it. `kind` selects between
-- plain RegisterEvent and RegisterUnitEvent.
local function addEntry(self, event, entry, kind, unit1, unit2)
    local list = self._subs[event]
    local firstForEvent = (list == nil)
    if firstForEvent then
        list = {}
        self._subs[event] = list
    end
    list[#list + 1] = entry

    if firstForEvent then
        if kind == "unit" then
            self._frame:RegisterUnitEvent(event, unit1, unit2)
        else
            self._frame:RegisterEvent(event)
        end
    end
end

-- Internal helper: build the Subscription handle for a given entry. Its
-- onCancel flips entry.cancelled and either sweeps eagerly (outside dispatch)
-- or queues a deferred sweep (during dispatch) to keep snapshot-on-iterate
-- consistent.
local function buildSubscription(self, event, entry)
    local Subscription = resolveDeps()
    return Subscription.New(function()
        entry.cancelled = true
        if (self._dispatchDepth[event] or 0) == 0 then
            sweep(self, event)
        else
            self._sweepQueued[event] = true
        end
    end)
end

---Construct a new Listener bound to its own private unnamed Frame. Per
---ADR-0003 Invariant D.6 (Bulkhead) the frame is the per-instance
---taint-isolation grain: a tainted upstream consumer cannot poison a sibling
---Listener's frame because the frames are not shared.
---@param addon DragonCore.Addon  required; must have a non-empty `name` string field.
---@return DragonCore.Listener
function Listener:New(addon)
    validateAddon("New", addon)

    local instance = setmetatable({
        _addon = addon,
        _subs = {},
        _disposed = false,
        _dispatchDepth = {},
        _sweepQueued = {},
    }, Listener)

    -- Unnamed frame: the structural answer to AceEvent30Frame. The second
    -- argument is intentionally omitted (Lua's `nil` default).
    instance._frame = CreateFrame("Frame")
    instance._frame:SetScript("OnEvent", function(_frame, event, ...)
        dispatch(instance, event, ...)
    end)

    return instance
end

---Register a handler for a frame event. Returns a cancellable Subscription.
---The handler receives the event payload as varargs (no `self`, no event
---name).
---@param event string
---@param cb fun(...)
---@return DragonCore.Subscription
function Listener:On(event, cb)
    checkLive(self, "On")
    validateEvent("On", event)
    validateCb("On", cb)

    local entry = { cb = cb, cancelled = false, once = false }
    addEntry(self, event, entry, "event")
    local sub = buildSubscription(self, event, entry)
    entry.sub = sub
    return sub
end

---As `:On`, but the handler is cancelled automatically after its first fire.
---The cancellation flip happens BEFORE the handler runs, so once-semantics
---hold even if the handler errors.
---@param event string
---@param cb fun(...)
---@return DragonCore.Subscription
function Listener:OnceOnly(event, cb)
    checkLive(self, "OnceOnly")
    validateEvent("OnceOnly", event)
    validateCb("OnceOnly", cb)

    local entry = { cb = cb, cancelled = false, once = true }
    addEntry(self, event, entry, "event")
    local sub = buildSubscription(self, event, entry)
    entry.sub = sub
    return sub
end

---Register a unit-scoped handler via Frame:RegisterUnitEvent. `unit2` may be
---nil. The handler receives the unit token as its first vararg followed by
---the event payload (matching the frame OnEvent signature minus `self` and
---`event`).
---@param event string
---@param unit1 string
---@param unit2 string|nil
---@param cb fun(unit: string, ...)
---@return DragonCore.Subscription
function Listener:OnUnit(event, unit1, unit2, cb)
    checkLive(self, "OnUnit")
    validateEvent("OnUnit", event)
    if type(unit1) ~= "string" or unit1 == "" then
        error("DragonCore.Listener:OnUnit: unit1 must be a non-empty string", 2)
    end
    if unit2 ~= nil and (type(unit2) ~= "string" or unit2 == "") then
        error("DragonCore.Listener:OnUnit: unit2 must be a non-empty string or nil", 2)
    end
    validateCb("OnUnit", cb)

    local entry = {
        cb = cb,
        cancelled = false,
        once = false,
        unit1 = unit1,
        unit2 = unit2,
    }
    addEntry(self, event, entry, "unit", unit1, unit2)
    local sub = buildSubscription(self, event, entry)
    entry.sub = sub
    return sub
end

---Cancel subscriptions in bulk. With `event` omitted, cancels every
---subscription on this Listener. With `event` set, cancels every
---subscription for that event. Idempotent.
---@param event string|nil
function Listener:Off(event)
    checkLive(self, "Off")

    if event == nil then
        -- Cancel every subscription on every event. Iterate over a snapshot
        -- of the keys because sweep() mutates self._subs.
        local events = {}
        for ev in pairs(self._subs) do events[#events + 1] = ev end
        for i = 1, #events do
            local list = self._subs[events[i]]
            if list then
                for j = 1, #list do
                    if list[j].sub then list[j].sub:Cancel() end
                end
            end
        end
        return
    end

    validateEvent("Off", event)
    local list = self._subs[event]
    if not list then return end
    for i = 1, #list do
        if list[i].sub then list[i].sub:Cancel() end
    end
end

---Tear down the Listener: cancel every subscription, unregister every event
---from the frame, release the frame for GC. Idempotent; subsequent calls to
---:On / :OnceOnly / :OnUnit / :Off raise.
function Listener:Dispose()
    if self._disposed then return end

    -- Cancel every live Subscription so consumer-held handles report
    -- :IsCancelled() == true after Dispose. Flip _disposed FIRST so
    -- sweep() does not call UnregisterEvent on a frame we are about to
    -- release.
    self._disposed = true

    for _, list in pairs(self._subs) do
        for i = 1, #list do
            local entry = list[i]
            if not entry.cancelled and entry.sub then
                entry.sub:Cancel()
            end
        end
    end

    self._subs = {}
    self._dispatchDepth = {}
    self._sweepQueued = {}
    self._frame:UnregisterAllEvents()
    self._frame:SetScript("OnEvent", nil)
    self._frame = nil
end

DragonCore.Listener = Listener
