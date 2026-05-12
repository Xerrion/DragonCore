-------------------------------------------------------------------------------
-- Store.lua
-- DragonCore typed SavedVariables store with profiles, identity-discriminated
-- scopes, and metatable-default fall-through. Replaces AceDB-3.0.
--
-- Public surface (ADR-0003 section B.3 / design note section 1):
--   :Open(addon, spec)        -> DragonCore.Store
--   :Profile() / :Char() / :Realm() / :Faction() / :FactionRealm() /
--   :Class()   / :Race() / :Global()
--                             -> scope view (defaults via __index)
--   :HasProfile(name)         -> boolean
--   :UseProfile(name)         -> () [fires ProfileChanged]
--   :ListProfiles()           -> string[]
--   :DeleteProfile(name)      -> () [fires ProfileDeleted; raises on active]
--   :CopyFrom(sourceName)     -> () [fires ProfileCopied; raises on missing]
--   :ResetProfile()           -> () [fires ProfileReset]
--   :ResetAll()               -> () [clears every scope; fires ProfileReset]
--   :On(event, fn)            -> DragonCore.Subscription
--   :Dispose()                -> ()
--
-- Dispatcher: snapshot-on-iterate + deferred-sweep copied from Bus.lua. The
-- fourth such copy in DragonCore -- design note section 6 deliberately
-- defers extraction of `DragonCore.Dispatcher` until trigger fires (fifth
-- consumer, shared bug, or uniform capability need).
--
-- Defaults are referenced by identity (NOT copied). Mutating
-- `spec.defaults.<scope>` after `:Open` is documented undefined behaviour.
-- The view returned by each scope accessor is the underlying SV scope
-- table with `setmetatable(__index = defaults[scope])` applied; reads of
-- un-set keys fall through to defaults, writes go straight into the SV
-- table. Reads from defaults are free, writes materialise (ADR line 399).
--
-- `:Dispose` does NOT touch `_G[svName]`. Blizzard owns SavedVariables
-- persistence; Store is a view.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution (mirrors Schedule / Listener / Bus /
-- AddonChannel). Capabilities is intentionally NOT a dep (design note
-- section 2 / ADR line 401: SavedVariables is bedrock).
-------------------------------------------------------------------------------

local function resolveDeps()
    local subscription = DragonCore.Subscription
    local secureCall = DragonCore.SecureCall
    if not subscription then
        error("DragonCore.Store: DragonCore.Subscription is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Store: DragonCore.SecureCall is not loaded", 3)
    end
    return subscription, secureCall
end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local VALID_EVENTS = {
    ProfileChanged = true,
    ProfileCopied = true,
    ProfileReset = true,
    ProfileDeleted = true,
}

local VALID_PROFILE_MODES = { Default = true, Character = true }

-------------------------------------------------------------------------------
-- Validation (design note section 4)
--
-- error(..., 3) so the reported source position is the consumer's call site
-- -- the helper and the public method are both peeled off the stack. Pattern
-- matches Listener / Bus / Locale / AddonChannel verbatim.
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.Store:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.Store:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.Store:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

local function validateSpec(spec)
    if spec == nil or type(spec) ~= "table" then
        error("DragonCore.Store:Open: spec must be a table", 3)
    end
    if type(spec.savedVariable) ~= "string" or spec.savedVariable == "" then
        error("DragonCore.Store:Open: spec.savedVariable must be a non-empty string", 3)
    end
    if spec.defaults ~= nil and type(spec.defaults) ~= "table" then
        error("DragonCore.Store:Open: spec.defaults must be a table if provided", 3)
    end
    if spec.initialProfile ~= nil then
        if type(spec.initialProfile) ~= "string" or spec.initialProfile == "" then
            error("DragonCore.Store:Open: spec.initialProfile must be a non-empty string", 3)
        end
    end
    if spec.profileMode ~= nil and not VALID_PROFILE_MODES[spec.profileMode] then
        error("DragonCore.Store:Open: spec.profileMode must be 'Default' or 'Character'", 3)
    end
end

local function validateProfileName(method, name)
    if type(name) ~= "string" or name == "" then
        error("DragonCore.Store:" .. method ..
            ": name must be a non-empty string", 3)
    end
end

local function validateEvent(event)
    if type(event) ~= "string" or not VALID_EVENTS[event] then
        error("DragonCore.Store:On: event must be one of " ..
            "'ProfileChanged', 'ProfileCopied', 'ProfileReset', 'ProfileDeleted'", 3)
    end
end

local function validateCb(cb)
    if type(cb) ~= "function" then
        error("DragonCore.Store:On: fn must be a function", 3)
    end
end

local function checkLive(self, method)
    if self._disposed then
        error("DragonCore.Store:" .. method ..
            ": instance has been disposed", 3)
    end
end

-------------------------------------------------------------------------------
-- Identity discriminators (design note section 1 conflict log #2)
--
-- Captured once at :Open via UnitName/GetRealmName/UnitFactionGroup/UnitClass/
-- UnitRace. The character cannot change class/race mid-session and faction
-- changes require a reload; the snapshot is correct for the session's
-- lifetime. Falls back to "Unknown" so a missing API on a stub harness does
-- not produce a nil table key. Production callers always have these globals
-- present after ADDON_LOADED.
-------------------------------------------------------------------------------

local function readIdentity()
    local name = _G.UnitName and _G.UnitName("player") or nil
    local realm = _G.GetRealmName and _G.GetRealmName() or nil
    local faction = _G.UnitFactionGroup and _G.UnitFactionGroup("player") or nil
    local classKey = _G.UnitClass and select(2, _G.UnitClass("player")) or nil
    local raceKey = _G.UnitRace and select(2, _G.UnitRace("player")) or nil
    return {
        name = name or "Unknown",
        realm = realm or "Unknown",
        faction = faction or "Neutral",
        class = classKey or "UNKNOWN",
        race = raceKey or "Unknown",
    }
end

local function makeCharKey(identity)
    -- AceDB-compatible per-character key (design note conflict log #4):
    -- "<name> - <realm>".
    return identity.name .. " - " .. identity.realm
end

local function makeFactionRealmKey(identity)
    return identity.faction .. " - " .. identity.realm
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ensureSubtable(parent, key)
    local v = parent[key]
    if v == nil then
        v = {}
        parent[key] = v
    end
    return v
end

-- Internal helper: deep copy for :CopyFrom. SV data is required to be
-- Lua-table-shaped scalars without cycles per ADR; the recursive walk is
-- safe under that contract.
local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = deepCopy(v)
    end
    return out
end

-- Internal helper: attach the defaults __index metatable to a scope table.
-- Idempotent: setmetatable on an already-metatabled table simply replaces
-- the previous metatable (cheap, no observable side effect because the
-- target defaults table is the same identity).
local function applyDefaultMeta(tbl, defaults)
    if defaults ~= nil then
        setmetatable(tbl, { __index = defaults })
    end
    return tbl
end

-------------------------------------------------------------------------------
-- Store
-------------------------------------------------------------------------------

---@class DragonCore.Store
---@field private _addon DragonCore.Addon
---@field private _svName string
---@field private _sv table
---@field private _defaults table|nil
---@field private _identity table
---@field private _charKey string
---@field private _profileKey string
---@field private _profileMode string
---@field private _subs table<string, table[]>
---@field private _disposed boolean
---@field private _dispatchDepth table<string, integer>
---@field private _sweepQueued table<string, boolean>
local Store = {}
Store.__index = Store

-- Internal helper: rebuild self._subs[event] dropping cancelled entries.
local function sweep(self, event)
    local list = self._subs[event]
    if not list then return end
    local live = {}
    for i = 1, #list do
        if not list[i].cancelled then live[#live + 1] = list[i] end
    end
    if #live == 0 then
        self._subs[event] = nil
    else
        self._subs[event] = live
    end
end

-- Internal helper: snapshot-on-iterate dispatch (copied from Bus.lua;
-- design note section 6 deliberately defers extraction to Dispatcher).
-- Callbacks receive `(store, ...)` per design note section 5.
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
            SecureCall:Invoke(entry.cb, self, ...)
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

-- Internal helper: build the Subscription handle (mirrors Bus).
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

---Open a Store for `addon` over the SavedVariables global `spec.savedVariable`.
---The global MUST exist (table) or be `nil` (Store creates an empty table)
---at call time. Production callers wire this inside `addon:OnReady` so
---ADDON_LOADED has fired; tests pre-set `_G[spec.savedVariable]` before
---calling.
---
---Opening is NOT idempotent: two `:Open` calls construct two independent
---handles over the same underlying SV table. Convention is one Store per
---addon -- each addon opens once and shares the handle.
---@param addon DragonCore.Addon
---@param spec DragonCore.Store.Spec
---@return DragonCore.Store
function Store:Open(addon, spec)
    validateAddon("Open", addon)
    validateSpec(spec)
    resolveDeps()  -- ensure deps present before constructing

    local svName = spec.savedVariable
    local sv = _G[svName]
    if sv == nil then
        sv = {}
        _G[svName] = sv
    elseif type(sv) ~= "table" then
        error("DragonCore.Store:Open: _G[\"" .. svName .. "\"] exists but is " ..
            "not a table (got " .. type(sv) .. ")", 3)
    end

    -- Ensure every top-level scope bucket exists. Idempotent over re-Open.
    ensureSubtable(sv, "profiles")
    ensureSubtable(sv, "profileKeys")
    ensureSubtable(sv, "char")
    ensureSubtable(sv, "realm")
    ensureSubtable(sv, "faction")
    ensureSubtable(sv, "factionrealm")
    ensureSubtable(sv, "class")
    ensureSubtable(sv, "race")
    ensureSubtable(sv, "global")

    local identity = readIdentity()
    local charKey = makeCharKey(identity)

    local profileMode = spec.profileMode or "Default"
    local profileKey
    if profileMode == "Character" then
        -- Conflict log #4: AceDB-compatible "<name> - <realm>" shape.
        profileKey = charKey
    else
        -- Respect existing per-character pointer if a previous session set
        -- one; otherwise fall back to initialProfile or "Default".
        profileKey = sv.profileKeys[charKey] or spec.initialProfile or "Default"
    end

    sv.profileKeys[charKey] = profileKey
    ensureSubtable(sv.profiles, profileKey)

    return setmetatable({
        _addon = addon,
        _svName = svName,
        _sv = sv,
        _defaults = spec.defaults,
        _identity = identity,
        _charKey = charKey,
        _profileKey = profileKey,
        _profileMode = profileMode,
        _subs = {},
        _disposed = false,
        _dispatchDepth = {},
        _sweepQueued = {},
    }, Store)
end

-------------------------------------------------------------------------------
-- Scope accessors (design note section 1 / ADR line 358)
--
-- Each returns the underlying SV scope table with `setmetatable(__index =
-- defaults[scope])` applied so reads of un-set keys hit defaults. Writes
-- materialise on the underlying table directly (no __newindex needed). The
-- metatable is (re-)applied on every call -- cheap, idempotent, ensures the
-- defaults link survives ResetProfile / ResetAll which replace the
-- underlying table identity.
-------------------------------------------------------------------------------

function Store:Profile()
    checkLive(self, "Profile")
    local t = ensureSubtable(self._sv.profiles, self._profileKey)
    return applyDefaultMeta(t, self._defaults and self._defaults.profile)
end

function Store:Char()
    checkLive(self, "Char")
    local t = ensureSubtable(self._sv.char, self._charKey)
    return applyDefaultMeta(t, self._defaults and self._defaults.char)
end

function Store:Realm()
    checkLive(self, "Realm")
    local t = ensureSubtable(self._sv.realm, self._identity.realm)
    return applyDefaultMeta(t, self._defaults and self._defaults.realm)
end

function Store:Faction()
    checkLive(self, "Faction")
    local t = ensureSubtable(self._sv.faction, self._identity.faction)
    return applyDefaultMeta(t, self._defaults and self._defaults.faction)
end

function Store:FactionRealm()
    checkLive(self, "FactionRealm")
    local t = ensureSubtable(self._sv.factionrealm, makeFactionRealmKey(self._identity))
    return applyDefaultMeta(t, self._defaults and self._defaults.factionrealm)
end

function Store:Class()
    checkLive(self, "Class")
    local t = ensureSubtable(self._sv.class, self._identity.class)
    return applyDefaultMeta(t, self._defaults and self._defaults.class)
end

function Store:Race()
    checkLive(self, "Race")
    local t = ensureSubtable(self._sv.race, self._identity.race)
    return applyDefaultMeta(t, self._defaults and self._defaults.race)
end

function Store:Global()
    checkLive(self, "Global")
    return applyDefaultMeta(self._sv.global, self._defaults and self._defaults.global)
end

-------------------------------------------------------------------------------
-- Profile operations (design note section 5)
-------------------------------------------------------------------------------

---@param name string
---@return boolean
function Store:HasProfile(name)
    checkLive(self, "HasProfile")
    validateProfileName("HasProfile", name)
    return self._sv.profiles[name] ~= nil
end

---Switch the active profile. Creates the profile if it does not exist.
---Fires "ProfileChanged" synchronously before return, with payload
---`(store, oldName, newName)`. A switch to the already-active profile is a
---no-op and does not fire the event.
---@param name string
function Store:UseProfile(name)
    checkLive(self, "UseProfile")
    validateProfileName("UseProfile", name)
    local old = self._profileKey
    if old == name then
        ensureSubtable(self._sv.profiles, name)
        self._sv.profileKeys[self._charKey] = name
        return
    end
    ensureSubtable(self._sv.profiles, name)
    self._profileKey = name
    self._sv.profileKeys[self._charKey] = name
    dispatch(self, "ProfileChanged", old, name)
end

---@return string[]
function Store:ListProfiles()
    checkLive(self, "ListProfiles")
    local out = {}
    for n in pairs(self._sv.profiles) do
        out[#out + 1] = n
    end
    return out
end

---Delete a profile. Raises on the active profile. Fires "ProfileDeleted"
---with payload `(store, name)`. Deleting a non-existent profile is a
---silent no-op (matches AceDB).
---@param name string
function Store:DeleteProfile(name)
    checkLive(self, "DeleteProfile")
    validateProfileName("DeleteProfile", name)
    if name == self._profileKey then
        error("DragonCore.Store:DeleteProfile: cannot delete the active profile '" ..
            name .. "'", 3)
    end
    if self._sv.profiles[name] == nil then return end
    self._sv.profiles[name] = nil
    dispatch(self, "ProfileDeleted", name)
end

---Copy `sourceName`'s profile contents into the active profile, overwriting.
---Raises on missing source. Fires "ProfileCopied" with payload
---`(store, sourceName, destName)` where `destName` is the active profile.
---@param sourceName string
function Store:CopyFrom(sourceName)
    checkLive(self, "CopyFrom")
    validateProfileName("CopyFrom", sourceName)
    local source = self._sv.profiles[sourceName]
    if source == nil then
        error("DragonCore.Store:CopyFrom: source profile '" .. sourceName ..
            "' does not exist", 3)
    end
    local dest = self._profileKey
    if sourceName == dest then return end
    self._sv.profiles[dest] = deepCopy(source)
    dispatch(self, "ProfileCopied", sourceName, dest)
end

---Reset the active profile to defaults (clear all non-default keys). Fires
---"ProfileReset" with payload `(store, name)`.
function Store:ResetProfile()
    checkLive(self, "ResetProfile")
    self._sv.profiles[self._profileKey] = {}
    dispatch(self, "ProfileReset", self._profileKey)
end

---Reset ALL scopes (every profile and every identity-discriminated bucket)
---to defaults. Fires "ProfileReset" for the active profile only.
function Store:ResetAll()
    checkLive(self, "ResetAll")
    self._sv.profiles = {}
    self._sv.profileKeys = {}
    self._sv.char = {}
    self._sv.realm = {}
    self._sv.faction = {}
    self._sv.factionrealm = {}
    self._sv.class = {}
    self._sv.race = {}
    self._sv.global = {}
    -- Re-establish the active profile pointer + table so the next :Profile()
    -- access does not silently re-create whatever was wiped.
    self._sv.profiles[self._profileKey] = {}
    self._sv.profileKeys[self._charKey] = self._profileKey
    dispatch(self, "ProfileReset", self._profileKey)
end

-------------------------------------------------------------------------------
-- Subscriptions (private dispatcher per design note section 6)
-------------------------------------------------------------------------------

---Subscribe to a Store event. Handlers receive `(store, ...payload)` where
---the payload shape is event-specific (see design note section 5).
---@param event DragonCore.Store.Event
---@param fn fun(store: DragonCore.Store, ...)
---@return DragonCore.Subscription
function Store:On(event, fn)
    checkLive(self, "On")
    validateEvent(event)
    validateCb(fn)

    local list = self._subs[event]
    if not list then
        list = {}
        self._subs[event] = list
    end
    local entry = { cb = fn, cancelled = false }
    list[#list + 1] = entry
    local sub = buildSubscription(self, event, entry)
    entry.sub = sub
    return sub
end

---Tear down the Store handle: cancel every subscription, clear internal
---state. Does NOT clear `_G[svName]` (Blizzard owns persistence). Subsequent
---non-:Dispose method calls raise. Idempotent.
function Store:Dispose()
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
    self._addon = nil
    self._sv = nil
    self._defaults = nil
end

DragonCore.Store = Store
