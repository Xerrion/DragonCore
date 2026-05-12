-------------------------------------------------------------------------------
-- Bus.lua
-- DragonCore in-process pub/sub: per-addon-instance (:New) or process-wide
-- shared (:Shared) message bus. Pure Lua table -- ZERO `CreateFrame` calls.
-- A module with no frame cannot leak frame state; this is the structural
-- generalisation of Listener's unnamed-Frame primitive (workspace
-- AGENTS.md "Known Gotchas -> Ace3 AceEvent30Frame is a shared global").
--
-- Every consumer callback dispatched through DragonCore.SecureCall:Invoke
-- per ADR-0003 Invariant D.3. Snapshot-on-iterate dispatch mirrors
-- Listener's; the duplication is accepted in v0 -- a shared dispatcher
-- helper would be a Pillar 3 violation until a third consumer (Store, Step
-- 6) wants the same shape.
--
-- Topic equality is flat string `==`. No wildcards, no hierarchical
-- matching. Documented v0 non-goal.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution (mirrors Schedule / Listener).
-------------------------------------------------------------------------------

local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    if not subscription then
        error("DragonCore.Bus: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Bus: DragonCore.SecureCall is not loaded", 3)
    end
    return subscription, secureCall
end

-------------------------------------------------------------------------------
-- Validation (section 6.2 of LISTENER-BUS design note)
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.Bus:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.Bus:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.Bus:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

local function validateTopic(method, topic)
    if type(topic) ~= "string" or topic == "" then
        error("DragonCore.Bus:" .. method ..
            ": topic must be a non-empty string", 3)
    end
end

local function validateCb(method, cb)
    if type(cb) ~= "function" then
        error("DragonCore.Bus:" .. method ..
            ": cb must be a function", 3)
    end
end

local function validateChannel(channel)
    if type(channel) ~= "string" or channel == "" then
        error("DragonCore.Bus:Shared: channel must be a non-empty string", 3)
    end
end

local function checkLive(self, method)
    if self._disposed then
        error("DragonCore.Bus:" .. method ..
            ": Bus has been disposed (label=" .. self._label .. ")", 3)
    end
end

-------------------------------------------------------------------------------
-- Shared registry (Multiton: one Bus per channel string, process-wide)
--
-- The registry is file-private. Each spec dofiles this module fresh, so the
-- registry resets between specs by construction. In production this table is
-- the single source of truth for shared Buses across the Lua state.
-------------------------------------------------------------------------------

local sharedBuses = {}

-------------------------------------------------------------------------------
-- Bus
-------------------------------------------------------------------------------

---@class DragonCore.Bus
---@field private _subs table<string, table[]>
---@field private _label string
---@field private _addon DragonCore.Addon|nil
---@field private _sharedChannel string|nil
---@field private _disposed boolean
---@field private _dispatchDepth table<string, integer>
---@field private _sweepQueued table<string, boolean>
local Bus = {}
Bus.__index = Bus

-- Internal helper: shared constructor. `label` is what appears in error
-- messages; `addon` may be nil for Shared Buses.
local function construct(addon, label, sharedChannel)
    return setmetatable({
        _addon = addon,
        _label = label,
        _sharedChannel = sharedChannel,
        _subs = {},
        _disposed = false,
        _dispatchDepth = {},
        _sweepQueued = {},
    }, Bus)
end

-- Internal helper: rebuild self._subs[topic] dropping cancelled entries.
local function sweep(self, topic)
    local list = self._subs[topic]
    if not list then return end
    local live = {}
    for i = 1, #list do
        if not list[i].cancelled then live[#live + 1] = list[i] end
    end
    if #live == 0 then
        self._subs[topic] = nil
    else
        self._subs[topic] = live
    end
end

-- Internal helper: snapshot-on-iterate dispatch for `topic`. Same shape as
-- Listener's dispatch: entries cancelled mid-send are skipped; entries
-- added mid-send are NOT visible until the next Send.
local function dispatch(self, topic, ...)
    if self._disposed then return end
    local list = self._subs[topic]
    if not list then return end

    self._dispatchDepth[topic] = (self._dispatchDepth[topic] or 0) + 1
    local _, SecureCall = resolveDeps()
    local len = #list
    for i = 1, len do
        local entry = list[i]
        if not entry.cancelled then
            SecureCall:Invoke(entry.cb, ...)
        end
    end
    self._dispatchDepth[topic] = self._dispatchDepth[topic] - 1

    if self._dispatchDepth[topic] == 0 then
        self._dispatchDepth[topic] = nil
        if self._sweepQueued[topic] then
            self._sweepQueued[topic] = nil
            sweep(self, topic)
        end
    end
end

-- Internal helper: build the Subscription handle for an entry. onCancel
-- flips entry.cancelled and either sweeps eagerly (outside Send) or queues
-- a deferred sweep (during Send).
local function buildSubscription(self, topic, entry)
    local Subscription = resolveDeps()
    return Subscription.New(function()
        entry.cancelled = true
        if (self._dispatchDepth[topic] or 0) == 0 then
            sweep(self, topic)
        else
            self._sweepQueued[topic] = true
        end
    end)
end

---Construct a new per-addon-instance Bus. No frame, no global state.
---@param addon DragonCore.Addon  required; must have a non-empty `name` field.
---@return DragonCore.Bus
function Bus:New(addon)
    validateAddon("New", addon)
    return construct(addon, addon.name, nil)
end

---Return a process-wide named Bus shared across DragonCore consumers. The
---first call for a given `channel` constructs the Bus; subsequent calls
---return the same instance. Explicit opt-in for cross-addon coordination
---(e.g. DragonLoot <-> DragonToast).
---
---ADR-0003 line 260 specifies `:Shared(channel)` with NO addon arg. The
---shared instance is process-wide and intentionally NOT owned by any one
---Addon; Resource Bag (R-3) tracking on Shared Buses is therefore NOT
---available via this factory in v0. Consumers who want per-addon lifecycle
---tracking on a shared channel should retain Subscriptions explicitly and
---cancel them in their :OnDisable.
---@param channel string  non-empty channel name.
---@return DragonCore.Bus
function Bus:Shared(channel)
    validateChannel(channel)
    local existing = sharedBuses[channel]
    if existing and not existing._disposed then
        return existing
    end
    local bus = construct(nil, "Shared:" .. channel, channel)
    sharedBuses[channel] = bus
    return bus
end

---Subscribe to a topic. Returns a cancellable Subscription.
---@param topic string  non-empty
---@param cb fun(...)   receives the payload as varargs.
---@return DragonCore.Subscription
function Bus:On(topic, cb)
    checkLive(self, "On")
    validateTopic("On", topic)
    validateCb("On", cb)

    local list = self._subs[topic]
    if not list then
        list = {}
        self._subs[topic] = list
    end
    local entry = { cb = cb, cancelled = false }
    list[#list + 1] = entry
    local sub = buildSubscription(self, topic, entry)
    entry.sub = sub
    return sub
end

---Publish to a topic. Every live subscriber for `topic` is invoked with the
---supplied varargs, in registration order, through SecureCall:Invoke. Fire
---and forget; topics with no subscribers are a no-op.
---@param topic string
---@param ... any
function Bus:Send(topic, ...)
    checkLive(self, "Send")
    validateTopic("Send", topic)
    dispatch(self, topic, ...)
end

---Cancel every subscription on this Bus and mark it unusable. Per-instance
---Buses are released; Shared Buses are evicted from the process-wide
---registry so the next `:Shared(channel)` constructs fresh. Idempotent.
function Bus:Dispose()
    if self._disposed then return end
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

    if self._sharedChannel and sharedBuses[self._sharedChannel] == self then
        sharedBuses[self._sharedChannel] = nil
    end
end

DragonCore.Bus = Bus
