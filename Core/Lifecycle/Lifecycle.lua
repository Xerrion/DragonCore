-------------------------------------------------------------------------------
-- Lifecycle.lua
-- DragonCore orchestration root: addon registration + load-state machine.
-- One library-scoped registry, one library-scoped unnamed bootstrap Frame
-- bridging ADDON_LOADED / PLAYER_LOGIN / PLAYER_LOGOUT to per-Addon state
-- transitions. State machine `Registered -> Loaded -> Ready -> Enabled` is
-- auto-driven by events; `Enabled <-> Disabled` is driven by explicit
-- `:Enable()` / `:Disable()` per the AceAddon precedent.
--
-- Public surface (ADR-0003 section B.1 / design note section 1):
--   Lifecycle:Register(name)        -> DragonCore.Addon
--   Addon:OnReady(fn)               -> DragonCore.Subscription
--   Addon:OnEnable(fn)              -> DragonCore.Subscription
--   Addon:OnDisable(fn)             -> DragonCore.Subscription
--   Addon:Attach(name, value?)      -> value  (namespace bag)
--   Addon:Get(name)                 -> any?
--   Addon:Track(sub)                -> sub    (resource bag; conflict log #3)
--   Addon:Enable()                  -> ()     (raises pre-Ready; idempotent)
--   Addon:Disable()                 -> ()     (raises pre-Ready; idempotent)
--   Addon:IsEnabled()               -> boolean
--
-- Two bags, never conflated:
--   * `:Attach` / `:Get` -- namespace bag for sub-module composition.
--   * `:Track`           -- Resource Bag for Subscriptions whose lifetime
--                            is bound to the Addon's Enabled state.
--
-- Dispatcher: snapshot-on-iterate + deferred-sweep copied from EventBus / Store.
-- Fifth in-process consumer of the pattern (the trigger Step 10 closes out).
-- All callback invocation routed through DragonCore.SecureCall:Invoke per
-- ADR Invariant D.3 (line 647).
--
-- LoD fast-forward (ADR OQ-4 line 844): `:Register` probes
-- `IsAddOnLoaded(name) and IsLoggedIn()`; when both true the new Addon
-- transitions Registered -> Loaded -> Ready -> Enabled synchronously inside
-- the `:Register` call. Hooks subscribed AFTER a state has passed fire
-- synchronously on subscribe (design note section 3.5).
--
-- PLAYER_LOGOUT: registered for forward-compat but a no-op. OnDisable is
-- NOT fired on logout (AceAddon precedent; design note conflict log #6).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution. Subscription + SecureCall only; Lifecycle is
-- the most upstream domain module (design note section 2).
-------------------------------------------------------------------------------

local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    local dispatcher = DragonCore.Dispatcher
    if not subscription then
        error("DragonCore.Lifecycle: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Lifecycle: DragonCore.SecureCall is not loaded", 3)
    end
    if not dispatcher then
        error("DragonCore.Lifecycle: DragonCore.Dispatcher is not loaded", 3)
    end
    return subscription, secureCall, dispatcher
end

-------------------------------------------------------------------------------
-- Validation (design note section 5)
--
-- error(..., 3) so the source position is pinned at the consumer's call
-- site -- helper and public method are both peeled off the stack. Mirrors
-- the verbatim shape of validateAddon in Listener / EventBus / Locale / Store /
-- Settings.
-------------------------------------------------------------------------------

local function validateName(method, name)
    if name == nil then
        error("DragonCore.Lifecycle:" .. method ..
            ": name is required (string)", 3)
    end
    if type(name) ~= "string" then
        error("DragonCore.Lifecycle:" .. method ..
            ": name must be a string, got " .. type(name), 3)
    end
    if name == "" then
        error("DragonCore.Lifecycle:" .. method ..
            ": name must be a non-empty string", 3)
    end
end

local function validateHookCb(method, fn)
    if type(fn) ~= "function" then
        error("DragonCore.Addon:" .. method ..
            ": fn must be a function", 3)
    end
end

local function validateNamespaceName(method, name)
    if type(name) ~= "string" or name == "" then
        error("DragonCore.Addon:" .. method ..
            ": name must be a non-empty string", 3)
    end
end

local function validateSubscription(sub)
    if sub == nil then
        error("DragonCore.Addon:Track: sub is required (DragonCore.Subscription)", 3)
    end
    if type(sub) ~= "table" then
        error("DragonCore.Addon:Track: sub must be a DragonCore.Subscription, " ..
            "got " .. type(sub), 3)
    end
    if type(sub.Cancel) ~= "function" or type(sub.IsCancelled) ~= "function" then
        error("DragonCore.Addon:Track: sub must be a DragonCore.Subscription " ..
            "(missing :Cancel/:IsCancelled)", 3)
    end
end

-------------------------------------------------------------------------------
-- Addon prototype
-------------------------------------------------------------------------------

---@class DragonCore.Addon
---@field name string
---@field state "Registered" | "Loaded" | "Ready" | "Enabled" | "Disabled"
---@field private _readyCbs table[]
---@field private _enableCbs table[]
---@field private _disableCbs table[]
---@field private _namespaces table<string, any>
---@field private _tracked DragonCore.Subscription[]
---@field private _depthBag DragonCore.Dispatcher.DepthBag
local Addon = {}
Addon.__index = Addon

-- Slot name -> Addon field. Keeps dispatcher helpers generic.
local SLOT_FIELDS = {
    OnReady = "_readyCbs",
    OnEnable = "_enableCbs",
    OnDisable = "_disableCbs",
}

-- Internal helper: rebuild self[<slotField>] dropping cancelled entries.
local function sweep(self, slot)
    local field = SLOT_FIELDS[slot]
    local list = self[field]
    if not list then return end
    local live = {}
    for i = 1, #list do
        if not list[i].cancelled then live[#live + 1] = list[i] end
    end
    self[field] = live
end

-- Internal helper: snapshot-on-iterate dispatch for one slot. Delegates to
-- the shared DragonCore.Dispatcher (design note Step 10; ADR-0003 §B). All
-- five inline copies (Listener / EventBus / AddonChannel / Store / Lifecycle)
-- route through the same primitive.
local function dispatch(self, slot)
    local field = SLOT_FIELDS[slot]
    local list = self[field]
    if not list or #list == 0 then return end

    local _, SecureCall, Dispatcher = resolveDeps()
    Dispatcher.Run(self._depthBag, slot, list, function(entry)
        SecureCall:Invoke(entry.cb, self)
    end, function(k) sweep(self, k) end)
end

-- Internal helper: build the Subscription handle whose onCancel flips
-- entry.cancelled and asks the Dispatcher to either sweep eagerly (outside
-- dispatch) or queue a deferred sweep (during dispatch).
local function buildSubscription(self, slot, entry)
    local Subscription, _, Dispatcher = resolveDeps()
    return Subscription.New(function()
        entry.cancelled = true
        Dispatcher.RequestSweep(self._depthBag, slot, function(k)
            sweep(self, k)
        end)
    end)
end

-- Internal helper: subscribe `fn` to a state-hook slot. Returns the handle
-- Subscription. If the Addon has already passed `triggeredAtState`, the
-- callback fires synchronously inside this call (deferred-fire rule, design
-- note section 3.5). Multiple subscribers permitted.
local function subscribeHook(self, slot, fn, fireImmediatelyWhen)
    validateHookCb(slot, fn)
    local _, SecureCall = resolveDeps()

    local list = self[SLOT_FIELDS[slot]]
    local entry = { cb = fn, cancelled = false }
    list[#list + 1] = entry
    local sub = buildSubscription(self, slot, entry)
    entry.sub = sub

    if fireImmediatelyWhen(self.state) then
        SecureCall:Invoke(fn, self)
    end

    return sub
end

local function isAtOrPastReady(state)
    return state == "Ready" or state == "Enabled" or state == "Disabled"
end

local function isEnabled(state)
    return state == "Enabled"
end

local function isDisabled(state)
    return state == "Disabled"
end

---Subscribe to the `Ready` transition. Fires exactly once when the Addon
---reaches `Ready`. If the Addon is ALREADY at or past `Ready` when
---`:OnReady` is called, the callback fires synchronously inside this call
---(still routed through SecureCall:Invoke).
---@param fn fun(addon: DragonCore.Addon)
---@return DragonCore.Subscription
function Addon:OnReady(fn)
    return subscribeHook(self, "OnReady", fn, isAtOrPastReady)
end

---Subscribe to every `Enabled` transition. Fires on the first Enabled-entry
---and on every subsequent `:Enable()` toggle. If the Addon is already
---`Enabled` when `:OnEnable` is called, the callback fires synchronously.
---@param fn fun(addon: DragonCore.Addon)
---@return DragonCore.Subscription
function Addon:OnEnable(fn)
    return subscribeHook(self, "OnEnable", fn, isEnabled)
end

---Subscribe to every `Disabled` transition. Fires on every `:Disable()`
---call. Does NOT fire on PLAYER_LOGOUT (design note conflict log #6).
---@param fn fun(addon: DragonCore.Addon)
---@return DragonCore.Subscription
function Addon:OnDisable(fn)
    return subscribeHook(self, "OnDisable", fn, isDisabled)
end

---Attach a named child namespace to this Addon. The **namespace bag**, NOT
---the Resource Bag (see `:Track`). Duplicate names raise. Nil value defaults
---to a new empty table per ADR line 161.
---@generic T
---@param name string
---@param value? T
---@return T
function Addon:Attach(name, value)
    validateNamespaceName("Attach", name)
    if self._namespaces[name] ~= nil then
        error("DragonCore.Addon:Attach: namespace '" .. name ..
            "' is already attached", 3)
    end
    if value == nil then value = {} end
    self._namespaces[name] = value
    return value
end

---Look up a previously-`:Attach`-ed namespace by name. Missing key returns
---nil (NOT raise) per ADR line 167 `any?`.
---@param name string
---@return any?
function Addon:Get(name)
    validateNamespaceName("Get", name)
    return self._namespaces[name]
end

---**Resource Bag.** Track a Subscription against this Addon. On `:Disable()`
---every tracked Subscription has `:Cancel()` called on it (design note
---conflict log #3). The argument is returned verbatim so call sites compose:
---`local s = addon:Track(listener:On("PLAYER_LOGIN", fn))`. Tracking after
---`:Disable` (Addon already in `Disabled` state) cancels the Subscription
---synchronously and does NOT add it to the bag (fast-path; design note
---section 4.2).
---@param sub DragonCore.Subscription
---@return DragonCore.Subscription
function Addon:Track(sub)
    validateSubscription(sub)
    if self.state == "Disabled" then
        pcall(sub.Cancel, sub)
        return sub
    end
    self._tracked[#self._tracked + 1] = sub
    return sub
end

-- Internal helper: walk a snapshot of tracked Subscriptions and Cancel
-- each. Errors are swallowed per Subscription contract (Subscription:Cancel
-- already pcalls the user onCancel; we additionally pcall the Cancel call
-- itself so a misbehaving Subscription cannot abort the disable walk).
local function cancelTrackedSnapshot(snapshot)
    for i = 1, #snapshot do
        pcall(snapshot[i].Cancel, snapshot[i])
    end
end

-- Internal helper: state transition. Single mutation point so the state
-- flips BEFORE callbacks fire (re-entrancy guard, design note section 4.3).
local function transition(self, nextState)
    self.state = nextState
end

---Transition to `Enabled`. No-op if already Enabled. Raises if state is
---`Registered` or `Loaded` (Addon has not yet reached `Ready`). Fires every
---`OnEnable` subscriber synchronously. Reciprocal of `:Disable()`.
function Addon:Enable()
    if self.state == "Enabled" then return end
    if self.state == "Registered" or self.state == "Loaded" then
        error("DragonCore.Addon:Enable: addon is not Ready yet (state=" ..
            self.state .. ")", 3)
    end
    -- state is Ready or Disabled; both legal Enabled-entries.
    transition(self, "Enabled")
    dispatch(self, "OnEnable")
end

---Transition to `Disabled`. No-op if already Disabled. Raises if state is
---`Registered` or `Loaded`. Fires every `OnDisable` subscriber synchronously,
---then walks the tracked Subscription bag and calls `:Cancel()` on each.
---Re-entrancy: an `OnDisable` handler may call `:Enable()` to abort the
---disable mid-flight; the cancel-walk over the ORIGINAL tracked bag still
---completes and the re-enabled Addon starts with an empty bag (design note
---section 4.4).
function Addon:Disable()
    if self.state == "Disabled" then return end
    if self.state == "Registered" or self.state == "Loaded" then
        error("DragonCore.Addon:Disable: addon is not Ready yet (state=" ..
            self.state .. ")", 3)
    end
    -- state is Ready or Enabled; both legal Disabled-entries.
    transition(self, "Disabled")
    -- Snapshot the tracked bag and reset to a fresh one BEFORE dispatch so
    -- subscriptions Track'd during an OnDisable handler land in the fresh
    -- bag and survive the cancel-walk (design note section 4.4: cancel-walk
    -- runs over the ORIGINAL tracked bag).
    local snapshot = self._tracked
    self._tracked = {}
    dispatch(self, "OnDisable")
    cancelTrackedSnapshot(snapshot)
end

---@return boolean  true iff state == "Enabled".
function Addon:IsEnabled()
    return self.state == "Enabled"
end

-------------------------------------------------------------------------------
-- Library-global state
-------------------------------------------------------------------------------

local addons = {}              -- name -> Addon
local addonOrder = {}          -- registration-order array (design note §3.6)
local bootstrapFrame           -- created at module load below

-- Internal helper: drive the Loaded -> Ready -> Enabled sequence for one
-- Addon. Used by both the LoD fast-forward in :Register and the
-- PLAYER_LOGIN handler in the bootstrap frame. Safe to call on an Addon
-- already at or past `Ready` (early-returns).
local function fastForwardToEnabled(addon)
    if addon.state == "Registered" then
        transition(addon, "Loaded")
    end
    if addon.state == "Loaded" then
        transition(addon, "Ready")
        dispatch(addon, "OnReady")
    end
    if addon.state == "Ready" then
        transition(addon, "Enabled")
        dispatch(addon, "OnEnable")
    end
end

---@class DragonCore.Lifecycle
local Lifecycle = {}

---Register an addon with DragonCore. Idempotent: the same `name` returns
---the same Addon object across calls (design note conflict log #5). If
---`IsAddOnLoaded(name)` AND `IsLoggedIn()` are both true at call time the
---returned Addon fast-forwards `Registered -> Loaded -> Ready -> Enabled`
---synchronously before returning (ADR OQ-4 / design note section 3.5).
---@param name string  Addon name; should match the TOC name. Non-empty.
---@return DragonCore.Addon
function Lifecycle:Register(name)
    validateName("Register", name)
    local _, _, Dispatcher = resolveDeps()

    local existing = addons[name]
    if existing then return existing end

    local addon = setmetatable({
        name = name,
        state = "Registered",
        _readyCbs = {},
        _enableCbs = {},
        _disableCbs = {},
        _namespaces = {},
        _tracked = {},
        _depthBag = Dispatcher.NewDepthBag(),
    }, Addon)
    addons[name] = addon
    addonOrder[#addonOrder + 1] = addon

    -- LoD fast-forward: if the addon is already loaded AND the player is
    -- already logged in, drive through to Enabled synchronously.
    local isLoaded = _G.IsAddOnLoaded and _G.IsAddOnLoaded(name)
    local isLoggedIn = _G.IsLoggedIn and _G.IsLoggedIn()
    if isLoaded and isLoggedIn then
        fastForwardToEnabled(addon)
    end

    return addon
end

DragonCore.Lifecycle = Lifecycle

-------------------------------------------------------------------------------
-- Bootstrap frame (one library-scoped unnamed Frame; design note section 3.1)
--
-- ADDON_LOADED  -> Registered -> Loaded for the named Addon (if known)
-- PLAYER_LOGIN  -> every Loaded Addon fast-forwards to Enabled (registration
--                  order via iteration over addons[]; deterministic enough
--                  for v0 -- design note section 3.6)
-- PLAYER_LOGOUT -> no-op in v0 (Conflict log #6; AceAddon precedent)
-------------------------------------------------------------------------------

local function onBootstrap(event, arg1)
    if event == "ADDON_LOADED" then
        local addon = addons[arg1]
        if addon and addon.state == "Registered" then
            transition(addon, "Loaded")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        -- Walk every registered Addon in registration order (design note
        -- §3.6); only those at Loaded transition. Addons in other states
        -- (Registered, Ready, Enabled, Disabled) are left alone -- Registered
        -- means ADDON_LOADED has not fired yet (will likely never, this
        -- session) and post-Loaded states have already been fast-forwarded
        -- via :Register's LoD path.
        for i = 1, #addonOrder do
            local addon = addonOrder[i]
            if addon.state == "Loaded" then
                fastForwardToEnabled(addon)
            end
        end
        return
    end

    -- PLAYER_LOGOUT: intentional no-op. Forward-compat registration only
    -- (design note section 3.4).
end

bootstrapFrame = _G.CreateFrame and _G.CreateFrame("Frame") or nil
if bootstrapFrame then
    bootstrapFrame:RegisterEvent("ADDON_LOADED")
    bootstrapFrame:RegisterEvent("PLAYER_LOGIN")
    bootstrapFrame:RegisterEvent("PLAYER_LOGOUT")
    bootstrapFrame:SetScript("OnEvent", function(_frame, event, ...)
        onBootstrap(event, ...)
    end)
end
