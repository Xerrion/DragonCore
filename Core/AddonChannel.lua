-------------------------------------------------------------------------------
-- AddonChannel.lua
-- DragonCore inter-addon wire channel. Replaces AceComm-3.0 with a leaner,
-- taint-free path: per-channel unnamed Frame, in-house Serializer (no
-- CallbackHandler dependency), honest discriminated SendResult, and a
-- snapshot-on-iterate dispatcher copied from EventBus.
--
-- Public surface (ADR-0003 section B.6 / design note section 1):
--   :Open(addon, prefix)              -> DragonCore.AddonChannel
--   :Send(msg, distribution, target)  -> SendResult { ok, error? }
--   :On(topic, fn)                    -> DragonCore.Subscription
--   :Dispose()                        -> ()
--
-- Five SendResult.error variants ship in v0: Lockdown, InvalidDistribution,
-- SerializationFailed, PrefixTooLong (never returned by :Send; raised at
-- :Open), Throttled. A sixth implicit variant -- DeserializationFailed --
-- is honoured on the INBOUND path by silently dropping malformed payloads
-- (design note conflict log #5).
--
-- Taint contract: one UNNAMED CreateFrame("Frame") per channel (design note
-- section 3.3 / ADR line 574). The wow_mock CreateFrame shim asserts
-- name == nil structurally; production code never passes a name.
--
-- Dispatcher: snapshot-on-iterate + deferred-sweep copied from EventBus.lua.
-- Pillar 3 inflection deliberately deferred (design note section 7).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local MAX_PREFIX_BYTES = 16  -- Blizzard hard cap; design note section 4.

local VALID_DISTRIBUTIONS = {
    PARTY = true, RAID = true, INSTANCE_CHAT = true,
    GUILD = true, WHISPER = true,
}

-------------------------------------------------------------------------------
-- Lazy dependency resolution (mirrors Schedule / Listener / EventBus).
-- Subscription / SecureCall / Capabilities / Serializer are captured per
-- call so spec dofile order stays flexible.
-------------------------------------------------------------------------------

local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    local capabilities = DragonCore.Capabilities
    local serializer = DragonCore._AddonChannelSerializer
    local dispatcher = DragonCore.Dispatcher
    if not subscription then
        error("DragonCore.AddonChannel: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.AddonChannel: DragonCore.SecureCall is not loaded", 3)
    end
    if not capabilities then
        error("DragonCore.AddonChannel: DragonCore.Capabilities is not loaded", 3)
    end
    if not serializer then
        error("DragonCore.AddonChannel: DragonCore._AddonChannelSerializer is not loaded", 3)
    end
    if not dispatcher then
        error("DragonCore.AddonChannel: DragonCore.Dispatcher is not loaded", 3)
    end
    return subscription, secureCall, capabilities, serializer, dispatcher
end

-------------------------------------------------------------------------------
-- Validation (design note section 6)
--
-- error(..., 3) so the reported source position is the consumer's call site
-- -- the helper and the public method are both peeled off the stack. The
-- distribution / target checks return a SendResult instead of raising
-- because they are RUNTIME conditions (caller may receive bad input from
-- elsewhere), not programmer errors.
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.AddonChannel:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.AddonChannel:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.AddonChannel:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

local function validatePrefix(prefix)
    if type(prefix) ~= "string" or prefix == "" then
        error("DragonCore.AddonChannel:Open: prefix must be a non-empty string", 3)
    end
    if #prefix > MAX_PREFIX_BYTES then
        error("DragonCore.AddonChannel:Open: PrefixTooLong (prefix is " ..
            #prefix .. " bytes, max " .. MAX_PREFIX_BYTES .. ")", 3)
    end
end

local function validateTopic(method, topic)
    if type(topic) ~= "string" or topic == "" then
        error("DragonCore.AddonChannel:" .. method ..
            ": topic must be a non-empty string", 3)
    end
end

local function validateMessage(msg)
    if type(msg) ~= "table" then
        error("DragonCore.AddonChannel:Send: msg must be a table", 3)
    end
    if type(msg.topic) ~= "string" or msg.topic == "" then
        error("DragonCore.AddonChannel:Send: msg.topic must be a non-empty string", 3)
    end
end

local function validateCb(method, cb)
    if type(cb) ~= "function" then
        error("DragonCore.AddonChannel:" .. method ..
            ": fn must be a function", 3)
    end
end

local function checkLive(self, method)
    if self._disposed then
        error("DragonCore.AddonChannel:" .. method ..
            ": instance has been disposed (prefix=" .. self._prefix .. ")", 3)
    end
end

-------------------------------------------------------------------------------
-- Process-wide state
-------------------------------------------------------------------------------

-- One AddonChannel per (addon.name, prefix). Idempotent :Open returns the
-- existing live instance. Distinct addon names with the same prefix produce
-- distinct channels that share the underlying Blizzard prefix slot (design
-- note section 1, line 60-65).
local channels = {}

-- Blizzard's RegisterAddonMessagePrefix is per-process one-shot. We track
-- which prefixes we have asked the client about so a second :Open on the
-- same prefix is a no-op at the Blizzard layer (design note section 3.1).
local registeredPrefixes = {}

-------------------------------------------------------------------------------
-- AddonChannel
-------------------------------------------------------------------------------

---@class DragonCore.AddonChannel
---@field private _frame table
---@field private _addon DragonCore.Addon
---@field private _prefix string
---@field private _subs table<string, table[]>
---@field private _disposed boolean
---@field private _depthBag DragonCore.Dispatcher.DepthBag
local AddonChannel = {}
AddonChannel.__index = AddonChannel

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

-- Internal helper: snapshot-on-iterate dispatch for `topic` via the shared
-- Dispatcher seam. Callback receives `(decoded, sender, distribution)` per
-- design note section 5.
local function dispatch(self, topic, ...)
    if self._disposed then return end
    local list = self._subs[topic]
    if not list then return end
    local _, SecureCall, _, _, Dispatcher = resolveDeps()
    local n = select("#", ...)
    local args = { ... }
    Dispatcher.Run(self._depthBag, topic, list, function(entry)
        SecureCall:Invoke(entry.cb, unpack(args, 1, n))
    end, function(k) sweep(self, k) end)
end

-- Internal helper: build the Subscription handle. onCancel flips
-- entry.cancelled and asks the Dispatcher to either sweep eagerly (outside
-- dispatch) or queue a deferred sweep (during dispatch).
local function buildSubscription(self, topic, entry)
    local Subscription, _, _, _, Dispatcher = resolveDeps()
    return Subscription.New(function()
        entry.cancelled = true
        Dispatcher.RequestSweep(self._depthBag, topic, function(k)
            sweep(self, k)
        end)
    end)
end

-- Internal helper: register the wire-level Blizzard prefix once per
-- process. Subsequent :Open calls for the same prefix re-use the existing
-- registration. Failure to register is recorded but does NOT raise (design
-- note section 3.1: inbound delivery may still work via another addon's
-- registration of the same prefix).
local function ensurePrefixRegistered(prefix)
    if registeredPrefixes[prefix] ~= nil then return end
    local chatInfo = _G.C_ChatInfo
    if not chatInfo or type(chatInfo.RegisterAddonMessagePrefix) ~= "function" then
        registeredPrefixes[prefix] = "unavailable"
        return
    end
    local ok = chatInfo.RegisterAddonMessagePrefix(prefix)
    registeredPrefixes[prefix] = ok and true or "rejected"
end

-- Internal helper: construct the Frame + bind OnEvent. Pulled out of :Open
-- so the OnEvent closure captures the channel via upvalue (not via `self`
-- on the frame instance, which would prevent GC after Dispose nils
-- self._frame).
local function attachFrame(instance, serializer)
    local frame = CreateFrame("Frame")  -- name=nil enforced by mock + ADR
    frame:SetScript("OnEvent", function(_, _event, prefix, payload, distribution, sender)
        if instance._disposed then return end
        if prefix ~= instance._prefix then return end
        local ok, topic, decoded = serializer.decode(payload)
        if not ok then return end  -- DeserializationFailed: silent drop
        dispatch(instance, topic, decoded, sender, distribution)
    end)
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
    instance._frame = frame
end

---Open a channel for `addon` on `prefix`. Idempotent within an addon:
---opening the same (addon, prefix) twice returns the same live channel.
---Cross-addon opens on the same prefix yield distinct channels that share
---the underlying Blizzard prefix slot.
---
---Raises on invalid prefix (`empty`, `> 16 bytes`); the latter is the
---`PrefixTooLong` enumerated error surfaced synchronously rather than as a
---deferred SendResult (design note conflict log #4).
---@param addon DragonCore.Addon
---@param prefix string  non-empty, <= 16 bytes
---@return DragonCore.AddonChannel
function AddonChannel:Open(addon, prefix)
    validateAddon("Open", addon)
    validatePrefix(prefix)
    local _, _, _, serializer, Dispatcher = resolveDeps()

    local addonChannels = channels[addon.name]
    if addonChannels then
        local existing = addonChannels[prefix]
        if existing and not existing._disposed then
            return existing
        end
    else
        addonChannels = {}
        channels[addon.name] = addonChannels
    end

    ensurePrefixRegistered(prefix)

    local instance = setmetatable({
        _addon = addon,
        _prefix = prefix,
        _subs = {},
        _disposed = false,
        _depthBag = Dispatcher.NewDepthBag(),
    }, AddonChannel)

    attachFrame(instance, serializer)
    addonChannels[prefix] = instance
    return instance
end

---Send a message. Returns a discriminated SendResult; runtime conditions
---(Lockdown, InvalidDistribution, SerializationFailed, Throttled) NEVER
---throw. Programmer errors (nil/non-table msg, missing topic) raise at
---error level 3 via the validation helpers.
---@nodiscard
---@param msg DragonCore.AddonChannel.Message
---@param distribution DragonCore.AddonChannel.Distribution
---@param target? string  whisper target (required when distribution == "WHISPER")
---@return DragonCore.AddonChannel.SendResult
function AddonChannel:Send(msg, distribution, target)
    checkLive(self, "Send")
    validateMessage(msg)
    -- distribution and target are RUNTIME inputs -- return a result rather
    -- than raise (design note section 6).
    if not VALID_DISTRIBUTIONS[distribution] then
        return { ok = false, error = "InvalidDistribution" }
    end
    if distribution == "WHISPER" and (type(target) ~= "string" or target == "") then
        return { ok = false, error = "InvalidDistribution" }
    end

    local _, _, Capabilities, serializer = resolveDeps()

    -- Lockdown circuit breaker (design note section 3.4). Per-call probe,
    -- retail-only via Capabilities.restrictedActions. Cheap; not cached
    -- because the state flips on combat / encounter transitions.
    if Capabilities.restrictedActions then
        local cra = _G.C_RestrictedActions
        if cra and type(cra.GetAddOnRestrictionState) == "function" then
            local state = cra.GetAddOnRestrictionState()
            if state ~= nil and state ~= 0 then
                return { ok = false, error = "Lockdown" }
            end
        end
    end

    local ok, encoded = serializer.encode(msg.topic, msg.payload)
    if not ok then
        return { ok = false, error = "SerializationFailed" }
    end

    local chatInfo = _G.C_ChatInfo
    if not chatInfo or type(chatInfo.SendAddonMessage) ~= "function" then
        return { ok = false, error = "Throttled" }
    end
    local sent = chatInfo.SendAddonMessage(self._prefix, encoded, distribution, target)
    if sent == false then
        return { ok = false, error = "Throttled" }
    end
    return { ok = true }
end

---Subscribe to a topic. Handlers receive `(payload, sender, distribution)`
---where `distribution` is the originating chat channel reported by Blizzard
---(`"WHISPER"`, `"PARTY"`, etc.).
---@param topic string                   non-empty
---@param fn fun(payload: any, sender: string, distribution: string)
---@return DragonCore.Subscription
function AddonChannel:On(topic, fn)
    checkLive(self, "On")
    validateTopic("On", topic)
    validateCb("On", fn)

    local list = self._subs[topic]
    if not list then
        list = {}
        self._subs[topic] = list
    end
    local entry = { cb = fn, cancelled = false }
    list[#list + 1] = entry
    local sub = buildSubscription(self, topic, entry)
    entry.sub = sub
    return sub
end

---Tear down the channel: cancel every subscription, unregister
---CHAT_MSG_ADDON / CHAT_MSG_ADDON_LOGGED, release the frame for GC. The
---Blizzard prefix registration is NOT released (Blizzard's API is one-way;
---design note section 9). Idempotent.
function AddonChannel:Dispose()
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
    local _, _, _, _, Dispatcher = resolveDeps()
    self._depthBag = Dispatcher.NewDepthBag()

    if self._frame then
        self._frame:UnregisterAllEvents()
        self._frame:SetScript("OnEvent", nil)
        self._frame = nil
    end

    -- Evict from the per-addon registry so the next :Open(addon, prefix)
    -- constructs a fresh channel rather than handing back the disposed one.
    local addonChannels = channels[self._addon.name]
    if addonChannels and addonChannels[self._prefix] == self then
        addonChannels[self._prefix] = nil
    end
end

DragonCore.AddonChannel = AddonChannel
