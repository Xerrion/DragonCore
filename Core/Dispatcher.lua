-------------------------------------------------------------------------------
-- Dispatcher.lua
-- DragonCore internal seam: snapshot-on-iterate dispatch with deferred sweep.
-- Extracted from five inline copies in Listener / EventBus / AddonChannel / Store /
-- Lifecycle. Pure refactor; no public surface; zero behaviour change.
--
-- Three functions:
--   Dispatcher.NewDepthBag()                              -> DepthBag
--   Dispatcher.Run(bag, key, entries, invoke, sweepFn)    -> ()
--   Dispatcher.RequestSweep(bag, key, sweepFn)            -> ()
--
-- The consumer owns: storage (entries list), subscription wiring, validation,
-- callback arg-shaping, SecureCall routing, sweep side effects (e.g.
-- Listener's frame UnregisterEvent on empty).
--
-- The Dispatcher owns: depth-counting around the loop, snapshot-on-iterate
-- via captured `len = #entries`, deferred-sweep gating.
--
-- This module has ZERO DragonCore deps (no Subscription, no SecureCall).
-- It is a pure-function utility intended for internal use; consumers outside
-- `DragonCore.*` MUST NOT call it. The contract MAY change between DragonCore
-- minor versions if a sixth consumer surfaces honest evidence for a different
-- shape (design note section 1.4: internal seam, not a v0 stability surface).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

---@class DragonCore.Dispatcher.DepthBag
---@field depth table<any, integer>
---@field sweepQueued table<any, boolean>

---@class DragonCore.Dispatcher
local Dispatcher = {}

---Construct a fresh per-channel depth bag. Consumers store this on `self`
---under whatever private field name they prefer (the existing five all use
---`_depthBag`).
---@return DragonCore.Dispatcher.DepthBag
function Dispatcher.NewDepthBag()
    return { depth = {}, sweepQueued = {} }
end

---Run one snapshot-on-iterate dispatch over `entries`.
---
---Increments `bag.depth[key]`, captures `len = #entries`, iterates
---`i = 1..len` and calls `invoke(entry)` for every non-cancelled entry,
---then decrements depth. On return to depth zero, if a sweep was requested
---during the loop (via `RequestSweep`), runs `sweepFn(key)` exactly once
---and clears the queued flag.
---
---The consumer's `invoke` closure is responsible for SecureCall routing,
---arg-shaping (single arg / prepended `self` / varargs), and any
---domain-specific per-entry semantics (e.g. Listener's `OnceOnly` cancel).
---Errors raised inside `invoke` propagate; Dispatcher does NOT pcall.
---@generic E
---@param bag DragonCore.Dispatcher.DepthBag
---@param key any
---@param entries E[]
---@param invoke fun(entry: E)
---@param sweepFn fun(key: any)
function Dispatcher.Run(bag, key, entries, invoke, sweepFn)
    bag.depth[key] = (bag.depth[key] or 0) + 1
    local len = #entries
    for i = 1, len do
        local entry = entries[i]
        if not entry.cancelled then
            invoke(entry)
        end
    end
    bag.depth[key] = bag.depth[key] - 1
    if bag.depth[key] == 0 then
        bag.depth[key] = nil
        if bag.sweepQueued[key] then
            bag.sweepQueued[key] = nil
            sweepFn(key)
        end
    end
end

---Cancel-path helper. If a dispatch is currently in flight for `key`
---(depth > 0), records the sweep request so `Run` runs it on return to
---depth zero. Otherwise runs `sweepFn(key)` synchronously.
---@param bag DragonCore.Dispatcher.DepthBag
---@param key any
---@param sweepFn fun(key: any)
function Dispatcher.RequestSweep(bag, key, sweepFn)
    if (bag.depth[key] or 0) == 0 then
        sweepFn(key)
    else
        bag.sweepQueued[key] = true
    end
end

DragonCore.Dispatcher = Dispatcher
