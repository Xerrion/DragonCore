-------------------------------------------------------------------------------
-- wow_mock.lua
-- Shared virtual-clock + frame mock for DragonCore busted specs. Per
-- ADR-0003 section F, this is the canonical mock harness; per-spec global
-- injection (Subscription_spec, Capabilities_spec, SecureCall_spec) remains
-- valid for modules that do not exercise C_Timer or CreateFrame.
--
-- Surface installed by mock:Install():
--   _G.C_Timer.After(delay, cb)              -- schedules a one-shot fire
--   _G.C_Timer.NewTicker(interval, cb, n?)   -- returns a FunctionContainer
--                                               with :Cancel() / :IsCancelled()
--   _G.CreateFrame(frameType, name?, parent?, template?)
--                                            -- returns a FrameMock; ASSERTS
--                                               frameType == "Frame" and
--                                               name == nil per ADR section F
--                                               line 750 (taint contract).
--   _G.GetLocale()                           -- returns the mock's current
--                                               locale (default "enUS"); set
--                                               per-spec via :SetLocale.
--   _G.C_ChatInfo.RegisterAddonMessagePrefix(prefix)
--                                            -- records to
--                                               self._registeredPrefixes; returns
--                                               true unless pre-rejected via
--                                               Mock:RejectPrefix(prefix).
--   _G.C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)
--                                            -- presence test against
--                                               self._registeredPrefixes.
--   _G.C_ChatInfo.SendAddonMessage(prefix, payload, distribution, target?)
--                                            -- appends to self._sentMessages;
--                                               returns true unless
--                                               Mock:SetSendFails(true).
--
-- Lockdown gating (per-spec opt-in):
--   _G.C_RestrictedActions is NOT installed by default. Mock:SetRestrictionState(s)
--   installs `{ GetAddOnRestrictionState = function() return self._restrictionState end }`
--   with `self._restrictionState = s`. Subsequent SetRestrictionState calls
--   only update the value the closure reads (no re-install). Pass nil to
--   uninstall.
--
-- Virtual clock semantics (mock:AdvanceTime(sec)):
--   * Callbacks fire in chronological order of their scheduled fireAt.
--   * Callbacks scheduled by callbacks during the advance ARE picked up if
--     their fireAt falls within the [now, now+sec] window (drain-to-fixed-
--     point loop).
--   * Tickers re-arm to fireAt + interval after each fire until cancelled or
--     iterations are exhausted.
--   * Cancelled entries are skipped, never fired.
--
-- Frame mock surface (per FrameMock instance):
--   :RegisterEvent(event)                    -- self._events[event] = true
--   :UnregisterEvent(event)                  -- clears _events AND _unitEvents
--   :UnregisterAllEvents()                   -- clears both
--   :RegisterUnitEvent(event, u1, u2?)       -- self._unitEvents[event] = {...}
--   :SetScript(handler, fn) / :GetScript     -- "OnEvent" is the only handler
--                                               DragonCore exercises in v0.
--
-- Test helpers on the mock instance:
--   :FireEvent(event, ...)                   -- invokes OnEvent on every frame
--                                               registered for `event` via
--                                               RegisterEvent.
--   :FireUnitEvent(event, unit, ...)         -- invokes OnEvent on every frame
--                                               registered for `event` via
--                                               RegisterUnitEvent for `unit`.
--   :Frames()                                -- iterator over every frame
--                                               created since :Install.
--   :FrameCount()                            -- count; for taint proxy assertion
--                                               (one frame per Listener:New).
--
-- Error policy (AdvanceTime / FireEvent / FireUnitEvent):
--   Callbacks are invoked raw -- exceptions propagate to the caller. Schedule
--   / Listener / Bus production code always wraps the consumer cb in
--   DragonCore.SecureCall:Invoke, which traps errors and routes them to
--   geterrorhandler(), so in well-formed specs an exception never reaches
--   the test harness. Tests that want to assert on raw behaviour can use
--   assert.has_error / pcall directly.
--
-- Out of scope for v0: C_Timer.NewTimer, non-"Frame" frame types,
-- secure-template surfaces, OnUpdate/OnShow/OnHide scripts.
-------------------------------------------------------------------------------

local M = {}

---@class WowMock
---@field now number                         virtual clock seconds since Install.
---@field scheduled table[]                  internal queue of pending fires.
---@field frames table[]                     every FrameMock created since Install.
local Mock = {}
Mock.__index = Mock

---Create a fresh, uninstalled mock. Call :Install() to expose globals.
---@return WowMock
function M.new()
    local self = setmetatable({}, Mock)
    self.now = 0
    self.scheduled = {}
    self.frames = {}
    self._locale = "enUS"
    self._registeredPrefixes = {}
    self._rejectPrefix = {}
    self._sentMessages = {}
    self._sendFails = false
    self._restrictionState = nil
    self._playerIdentity = {
        name = "TestChar",
        realm = "TestRealm",
        faction = "Horde",
        class = { "Warrior", "WARRIOR", 1 },
        race = { "Tauren", "Tauren", 6 },
    }
    self._trackedSavedVars = {}
    self._previousC_Timer = nil
    self._previousCreateFrame = nil
    self._previousGetLocale = nil
    self._previousC_ChatInfo = nil
    self._previousC_RestrictedActions = nil
    self._previousUnitName = nil
    self._previousGetRealmName = nil
    self._previousUnitFactionGroup = nil
    self._previousUnitClass = nil
    self._previousUnitRace = nil
    self._installed = false
    return self
end

-------------------------------------------------------------------------------
-- Addon stub (section 6.3 of LISTENER-BUS design note)
-------------------------------------------------------------------------------

---Construct a minimal DragonCore.Addon stub that satisfies the v0
---Listener:New / Bus:New validation contract (section 6.1 read-surface:
---one field, `name :: string`, non-empty). Lifecycle (Step 5+) will replace
---this with the real Addon object; specs that exercise Lifecycle must not
---use this helper.
---@param name? string  Defaults to "TestAddon" when omitted.
---@return table        { name = name }
function M.fakeAddon(name)
    return { name = name or "TestAddon" }
end

-------------------------------------------------------------------------------
-- C_Timer mock (virtual clock)
-------------------------------------------------------------------------------

-- Internal helper: build a FunctionContainer-shaped ticker object. The ticker
-- itself is the long-lived handle exposed to the consumer; per-fire pending
-- entries in `self.scheduled` reference it back via `entry.ticker`.
local function newTicker(interval, cb, iterations)
    local ticker = {
        _cancelled = false,
        _interval = interval,
        _cb = cb,
        _remaining = iterations,  -- nil = unlimited
    }
    function ticker:Cancel()
        self._cancelled = true
    end
    function ticker:IsCancelled()
        return self._cancelled
    end
    return ticker
end

-------------------------------------------------------------------------------
-- Frame mock
-------------------------------------------------------------------------------

local FrameMock = {}
FrameMock.__index = FrameMock

local function newFrame()
    return setmetatable({
        _events = {},
        _unitEvents = {},
        _scripts = {},
    }, FrameMock)
end

function FrameMock:RegisterEvent(event)
    if type(event) ~= "string" or event == "" then
        error("FrameMock:RegisterEvent: event must be a non-empty string", 2)
    end
    self._events[event] = true
    -- Per WoW semantics, RegisterEvent supersedes any prior RegisterUnitEvent
    -- filter for the same event (broadens to all units). Mirror that here.
    self._unitEvents[event] = nil
end

function FrameMock:RegisterUnitEvent(event, unit1, unit2)
    if type(event) ~= "string" or event == "" then
        error("FrameMock:RegisterUnitEvent: event must be a non-empty string", 2)
    end
    if type(unit1) ~= "string" or unit1 == "" then
        error("FrameMock:RegisterUnitEvent: unit1 must be a non-empty string", 2)
    end
    -- Per WoW semantics, RegisterUnitEvent acts as a filtered RegisterEvent.
    -- A subsequent RegisterEvent would broaden; we record both states.
    self._events[event] = true
    self._unitEvents[event] = { unit1, unit2 }
end

function FrameMock:UnregisterEvent(event)
    self._events[event] = nil
    self._unitEvents[event] = nil
end

function FrameMock:UnregisterAllEvents()
    self._events = {}
    self._unitEvents = {}
end

function FrameMock:SetScript(handler, fn)
    self._scripts[handler] = fn
end

function FrameMock:GetScript(handler)
    return self._scripts[handler]
end

-------------------------------------------------------------------------------
-- Install / Uninstall
-------------------------------------------------------------------------------

---Install the mock as `_G.C_Timer` and `_G.CreateFrame`. Records the previous
---values so :Uninstall() can restore them. Double-install is a programmer
---error.
function Mock:Install()
    if self._installed then
        error("wow_mock:Install called twice without Uninstall", 2)
    end
    self._previousC_Timer = _G.C_Timer
    self._previousCreateFrame = _G.CreateFrame
    self._previousGetLocale = _G.GetLocale
    self._previousC_ChatInfo = _G.C_ChatInfo
    self._previousUnitName = _G.UnitName
    self._previousGetRealmName = _G.GetRealmName
    self._previousUnitFactionGroup = _G.UnitFactionGroup
    self._previousUnitClass = _G.UnitClass
    self._previousUnitRace = _G.UnitRace
    local mock = self

    _G.C_Timer = {
        After = function(delay, cb)
            if type(delay) ~= "number" or delay < 0 then
                error("C_Timer.After: delay must be a non-negative number", 2)
            end
            if type(cb) ~= "function" then
                error("C_Timer.After: cb must be a function", 2)
            end
            table.insert(mock.scheduled, {
                fireAt = mock.now + delay,
                cb = cb,
                kind = "after",
                cancelled = false,
            })
        end,

        NewTicker = function(interval, cb, iterations)
            if type(interval) ~= "number" or interval <= 0 then
                error("C_Timer.NewTicker: interval must be a positive number", 2)
            end
            if type(cb) ~= "function" then
                error("C_Timer.NewTicker: cb must be a function", 2)
            end
            local ticker = newTicker(interval, cb, iterations)
            table.insert(mock.scheduled, {
                fireAt = mock.now + interval,
                cb = cb,
                kind = "ticker",
                ticker = ticker,
                cancelled = false,
            })
            return ticker
        end,
    }

    _G.CreateFrame = function(frameType, name, parent, template)
        -- Taint contract proxy assertions (ADR section F line 750).
        if frameType ~= "Frame" then
            error("CreateFrame mock: unsupported frameType " ..
                tostring(frameType) .. " (v0 scope: 'Frame' only)", 2)
        end
        if name ~= nil then
            error("CreateFrame mock: name must be nil (taint contract: no " ..
                "named frames in DragonCore). Got " .. tostring(name), 2)
        end
        local frame = newFrame()
        frame._parent = parent
        frame._template = template
        table.insert(mock.frames, frame)
        return frame
    end

    _G.GetLocale = function()
        return mock._locale or "enUS"
    end

    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix)
            if type(prefix) ~= "string" or prefix == "" then
                error("C_ChatInfo.RegisterAddonMessagePrefix: prefix must be a " ..
                    "non-empty string", 2)
            end
            if mock._rejectPrefix[prefix] then
                return false
            end
            mock._registeredPrefixes[prefix] = true
            return true
        end,
        IsAddonMessagePrefixRegistered = function(prefix)
            return mock._registeredPrefixes[prefix] == true
        end,
        SendAddonMessage = function(prefix, payload, distribution, target)
            if mock._sendFails then return false end
            table.insert(mock._sentMessages, {
                prefix = prefix,
                payload = payload,
                distribution = distribution,
                target = target,
            })
            return true
        end,
    }

    -- Player-identity stubs (design note section 8.1). The closures read
    -- self._playerIdentity so SetPlayerIdentity is reflected on the next
    -- call without re-installing the globals.
    _G.UnitName = function(_unit)
        return mock._playerIdentity.name, ""
    end
    _G.GetRealmName = function()
        return mock._playerIdentity.realm
    end
    _G.UnitFactionGroup = function(_unit)
        return mock._playerIdentity.faction
    end
    _G.UnitClass = function(_unit)
        local c = mock._playerIdentity.class
        return c[1], c[2], c[3]
    end
    _G.UnitRace = function(_unit)
        local r = mock._playerIdentity.race
        return r[1], r[2], r[3]
    end

    self._installed = true
end

---Restore the previous `_G.C_Timer`, `_G.CreateFrame`, `_G.GetLocale`,
---`_G.C_ChatInfo`, and `_G.C_RestrictedActions` (if installed via
---:SetRestrictionState). Safe when not installed.
function Mock:Uninstall()
    if not self._installed then return end
    _G.C_Timer = self._previousC_Timer
    _G.CreateFrame = self._previousCreateFrame
    _G.GetLocale = self._previousGetLocale
    _G.C_ChatInfo = self._previousC_ChatInfo
    _G.UnitName = self._previousUnitName
    _G.GetRealmName = self._previousGetRealmName
    _G.UnitFactionGroup = self._previousUnitFactionGroup
    _G.UnitClass = self._previousUnitClass
    _G.UnitRace = self._previousUnitRace
    if self._previousC_RestrictedActions ~= nil or _G.C_RestrictedActions ~= nil then
        _G.C_RestrictedActions = self._previousC_RestrictedActions
    end
    for name in pairs(self._trackedSavedVars) do
        _G[name] = nil
    end
    self._trackedSavedVars = {}
    self._previousC_Timer = nil
    self._previousCreateFrame = nil
    self._previousGetLocale = nil
    self._previousC_ChatInfo = nil
    self._previousC_RestrictedActions = nil
    self._previousUnitName = nil
    self._previousGetRealmName = nil
    self._previousUnitFactionGroup = nil
    self._previousUnitClass = nil
    self._previousUnitRace = nil
    self._installed = false
end

---Set the value `_G.GetLocale()` returns for this mock. Defaults to `"enUS"`
---on :Install; specs that exercise deDE / ruRU / esES paths call this before
---:Register or :Get. Safe to call before or after :Install.
---@param locale string
function Mock:SetLocale(locale)
    if type(locale) ~= "string" or locale == "" then
        error("wow_mock:SetLocale: locale must be a non-empty string", 2)
    end
    self._locale = locale
end

-------------------------------------------------------------------------------
-- AddonChannel test helpers (design note section 8.3)
-------------------------------------------------------------------------------

---Return a shallow copy of the recorded outbound SendAddonMessage queue.
---Each entry is `{ prefix, payload, distribution, target }`. The copy
---guards against in-place mutation by the spec.
---@return table[]
function Mock:SentMessages()
    local out = {}
    for i = 1, #self._sentMessages do out[i] = self._sentMessages[i] end
    return out
end

---Return a list of prefixes that have been passed to
---RegisterAddonMessagePrefix (including pre-rejected ones do NOT appear
---here; only successful registrations).
---@return string[]
function Mock:RegisteredPrefixes()
    local out = {}
    for prefix in pairs(self._registeredPrefixes) do out[#out + 1] = prefix end
    return out
end

---Pre-arm RegisterAddonMessagePrefix to return false for `prefix`. Models
---Blizzard's per-client prefix cap being hit.
---@param prefix string
function Mock:RejectPrefix(prefix)
    self._rejectPrefix[prefix] = true
end

---Pre-arm SendAddonMessage to return false for every subsequent call.
---Models the CTL throttle path. Toggle off by passing false.
---@param fails boolean
function Mock:SetSendFails(fails)
    self._sendFails = fails and true or false
end

---Install / update `_G.C_RestrictedActions`. Pass nil to uninstall.
---Pass any number (0 == no lockdown; non-zero == lockdown active). The
---installed `GetAddOnRestrictionState` closes over `self` so subsequent
---calls reflect the most recent SetRestrictionState value without
---re-installing the global. Capabilities.lua reads `C_RestrictedActions`
---at module-load time -- specs that exercise the Lockdown branch must call
---SetRestrictionState BEFORE dofile-ing Capabilities.
---@param state integer|nil
function Mock:SetRestrictionState(state)
    self._restrictionState = state
    if state == nil then
        self._previousC_RestrictedActions = self._previousC_RestrictedActions
            or _G.C_RestrictedActions
        _G.C_RestrictedActions = nil
        return
    end
    if _G.C_RestrictedActions == nil
        or type(_G.C_RestrictedActions.GetAddOnRestrictionState) ~= "function"
        or _G.C_RestrictedActions._dragonCoreMock ~= true then
        self._previousC_RestrictedActions = self._previousC_RestrictedActions
            or _G.C_RestrictedActions
        _G.C_RestrictedActions = {
            _dragonCoreMock = true,
            GetAddOnRestrictionState = function()
                return self._restrictionState
            end,
        }
    end
end

-------------------------------------------------------------------------------
-- Store test helpers (design note section 8.1 / 8.2)
-------------------------------------------------------------------------------

---Merge identity fields into the mock's player-identity record. Omitted
---fields keep their defaults (`name="TestChar"`, `realm="TestRealm"`,
---`faction="Horde"`, `class={"Warrior","WARRIOR",1}`,
---`race={"Tauren","Tauren",6}`). The globals installed by :Install close
---over `self._playerIdentity` so subsequent calls reflect the new value
---without re-install. Safe to call before or after :Install.
---@param t table
function Mock:SetPlayerIdentity(t)
    if type(t) ~= "table" then
        error("wow_mock:SetPlayerIdentity: t must be a table", 2)
    end
    for k, v in pairs(t) do
        self._playerIdentity[k] = v
    end
end

---Set `_G[name] = table or {}`. Tracked for cleanup so :Uninstall wipes
---every SavedVariable global written through this helper.
---@param name string
---@param tbl table|nil
function Mock:SetSavedVariable(name, tbl)
    if type(name) ~= "string" or name == "" then
        error("wow_mock:SetSavedVariable: name must be a non-empty string", 2)
    end
    _G[name] = tbl or {}
    self._trackedSavedVars[name] = true
end

---Return `_G[name]` for spec assertions on the post-write SV shape.
---@param name string
---@return any
function Mock:GetSavedVariable(name)
    return _G[name]
end

---Clear `_G[name]` and stop tracking it. Idempotent.
---@param name string
function Mock:ClearSavedVariable(name)
    if type(name) ~= "string" or name == "" then
        error("wow_mock:ClearSavedVariable: name must be a non-empty string", 2)
    end
    _G[name] = nil
    self._trackedSavedVars[name] = nil
end

-------------------------------------------------------------------------------
-- Virtual-clock advance
-------------------------------------------------------------------------------

-- Internal helper: find the index of the earliest-due, non-cancelled entry
-- whose fireAt is <= endTime. Returns nil when none match.
local function findNextDue(scheduled, endTime)
    local bestIdx, bestFireAt
    for i = 1, #scheduled do
        local e = scheduled[i]
        -- Ticker entries respect the ticker-level cancelled flag as well.
        local skipped = e.cancelled or (e.ticker and e.ticker._cancelled)
        if not skipped and e.fireAt <= endTime then
            if bestFireAt == nil or e.fireAt < bestFireAt then
                bestFireAt = e.fireAt
                bestIdx = i
            end
        end
    end
    return bestIdx
end

---Advance the virtual clock by `sec` seconds. Fires every due callback in
---chronological order. New callbacks scheduled during this call ARE drained
---if they become due within the same window. The clock is set to
---`now + sec` even when no callbacks fired.
---
---Callback exceptions propagate to the caller of AdvanceTime (see file
---header "Error policy").
---@param sec number  must be a non-negative number.
function Mock:AdvanceTime(sec)
    if type(sec) ~= "number" or sec < 0 then
        error("wow_mock:AdvanceTime: sec must be a non-negative number", 2)
    end

    local endTime = self.now + sec
    while true do
        local idx = findNextDue(self.scheduled, endTime)
        if not idx then break end

        local entry = self.scheduled[idx]
        self.now = entry.fireAt

        if entry.kind == "ticker" then
            local ticker = entry.ticker
            -- Pop the pending fire BEFORE invoking cb so re-entrant Cancel
            -- on the ticker observes a consistent queue. Re-arm only if the
            -- ticker is still live after the call.
            table.remove(self.scheduled, idx)

            entry.cb()  -- exceptions propagate; see Error policy

            if not ticker._cancelled then
                if ticker._remaining ~= nil then
                    ticker._remaining = ticker._remaining - 1
                    if ticker._remaining <= 0 then
                        ticker._cancelled = true
                    end
                end
                if not ticker._cancelled then
                    table.insert(self.scheduled, {
                        fireAt = entry.fireAt + ticker._interval,
                        cb = entry.cb,
                        kind = "ticker",
                        ticker = ticker,
                        cancelled = false,
                    })
                end
            end
        else
            -- One-shot After. Remove first, then fire.
            table.remove(self.scheduled, idx)
            entry.cb()  -- exceptions propagate
        end
    end

    self.now = endTime
end

-------------------------------------------------------------------------------
-- Frame event helpers
-------------------------------------------------------------------------------

---Invoke OnEvent on every frame currently registered for `event` via
---RegisterEvent. Unit-filtered frames (RegisterUnitEvent) are skipped --
---tests use :FireUnitEvent for those.
---@param event string
function Mock:FireEvent(event, ...)
    -- Snapshot the frame list so a handler creating a new frame mid-fire
    -- does not get its OnEvent invoked in the same fire (matches WoW).
    local snapshot = {}
    for i = 1, #self.frames do snapshot[i] = self.frames[i] end

    for i = 1, #snapshot do
        local frame = snapshot[i]
        if frame._events[event] and not frame._unitEvents[event] then
            local onEvent = frame._scripts.OnEvent
            if onEvent then onEvent(frame, event, ...) end
        end
    end
end

---Invoke OnEvent on every frame registered for `event` via RegisterUnitEvent
---whose unit filter includes `unit`. Plain RegisterEvent frames also receive
---the fire because in WoW a plain RegisterEvent supersedes unit filtering.
---@param event string
---@param unit string
function Mock:FireUnitEvent(event, unit, ...)
    local snapshot = {}
    for i = 1, #self.frames do snapshot[i] = self.frames[i] end

    for i = 1, #snapshot do
        local frame = snapshot[i]
        local unitFilter = frame._unitEvents[event]
        local matches = false
        if unitFilter then
            if unitFilter[1] == unit or unitFilter[2] == unit then matches = true end
        elseif frame._events[event] then
            -- Plain RegisterEvent: receives unit fires for every unit.
            matches = true
        end
        if matches then
            local onEvent = frame._scripts.OnEvent
            if onEvent then onEvent(frame, event, unit, ...) end
        end
    end
end

---Iterator over every frame created since :Install. Convenience for specs
---that want to assert per-frame state.
---@return fun():table?
function Mock:Frames()
    local i = 0
    local n = #self.frames
    return function()
        i = i + 1
        if i <= n then return self.frames[i] end
    end
end

---Count of frames created since :Install. The Listener-per-instance taint
---contract (one frame per :New) is asserted via this helper.
---@return integer
function Mock:FrameCount()
    return #self.frames
end

return M
