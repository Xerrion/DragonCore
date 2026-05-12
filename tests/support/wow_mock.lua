-------------------------------------------------------------------------------
-- wow_mock.lua
-- Shared virtual-clock WoW-API mock for DragonCore busted specs. Per
-- ADR-0003 section F, this is the canonical mock harness; per-spec global
-- injection (Subscription_spec, Capabilities_spec, SecureCall_spec) remains
-- valid for modules that do not exercise C_Timer.
--
-- Surface installed by mock:Install():
--   _G.C_Timer.After(delay, cb)              -- schedules a one-shot fire
--   _G.C_Timer.NewTicker(interval, cb, n?)   -- returns a FunctionContainer
--                                               with :Cancel() / :IsCancelled()
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
-- Error policy (AdvanceTime):
--   Callbacks are invoked raw -- exceptions propagate to the caller of
--   AdvanceTime. Schedule production code always wraps the consumer cb in
--   DragonCore.SecureCall:Invoke, which traps errors and routes them to
--   geterrorhandler(), so in well-formed specs an exception never reaches
--   AdvanceTime. Tests that want to assert on raw scheduler behaviour can
--   use assert.has_error / pcall directly.
--
-- Out of scope for v0: C_Timer.NewTimer, CreateFrame, FireEvent helpers,
-- secure-template surfaces. Add them when a consuming module needs them.
-------------------------------------------------------------------------------

local M = {}

---@class WowMock
---@field now number                 virtual clock seconds since Install.
---@field scheduled table[]          internal queue of pending fires.
local Mock = {}
Mock.__index = Mock

---Create a fresh, uninstalled mock. Call :Install() to expose _G.C_Timer.
---@return WowMock
function M.new()
    local self = setmetatable({}, Mock)
    self.now = 0
    self.scheduled = {}
    self._previousC_Timer = nil
    self._installed = false
    return self
end

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

---Install the mock as `_G.C_Timer`. Records the previous value (if any) so
---:Uninstall() can restore it cleanly. Calling :Install() twice on the same
---mock without an intermediate :Uninstall() is a programmer error and raises.
function Mock:Install()
    if self._installed then
        error("wow_mock:Install called twice without Uninstall", 2)
    end
    self._previousC_Timer = _G.C_Timer
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

    self._installed = true
end

---Restore the previous `_G.C_Timer`. Safe to call when not installed.
function Mock:Uninstall()
    if not self._installed then return end
    _G.C_Timer = self._previousC_Timer
    self._previousC_Timer = nil
    self._installed = false
end

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

return M
