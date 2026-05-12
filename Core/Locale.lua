-------------------------------------------------------------------------------
-- Locale.lua
-- DragonCore per-addon locale registry. Replaces the AceLocale-3.0 path the
-- workspace's Dragon* addons use today with a thin, taint-free module whose
-- contract is stricter and whose dependency graph is empty (no DragonCore
-- siblings, no Frame, no Subscription, no SecureCall, no Capabilities).
--
-- Storage: file-private `locales` keyed by addon.name.
--     locales[name] = {
--         default = { ... },   -- enUS strings, key-normalised at register
--         active  = { ... },   -- strings for the active client locale
--         proxy   = <table>,   -- read-only metatable proxy, lazy on :Get
--     }
--
-- enUS-sentinel handling: workspace convention writes `[key] = true` in the
-- enUS locale file (the key IS the English string). Locale normalises that
-- at the registration boundary (design note section 2.2, path a): a `true`
-- value becomes the key itself in `default`. Reads then run
-- `active[k] or default[k] or k` without ever observing a `true` mid-chain.
--
-- Resolution order at read time: active -> default -> key. Always returns a
-- string for a string index. The proxy is the single source of truth.
--
-- Non-goals (ADR-0003 section B.5 / design note section 2.6):
--   * No :Unregister / :Dispose. Locale data is process-lifetime.
--   * No event/callback fan-out. Locale changes require UI reload.
--   * No SecureCall wrap. Locale never invokes consumer callbacks.
--   * No pluralisation, no typed-L codegen.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Validation (copy-pasted shape from Listener.lua lines 61-74 with the
-- module name swapped; see design note section 6 / "Locked items").
--
-- error(..., 3) so the reported source position is the consumer's call site
-- -- the helper and the public method are both peeled off the stack.
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.Locale:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.Locale:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.Locale:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

-- File-private registry. Keyed by addon.name (string) per design note section
-- 2.1: aligns with the future Lifecycle invariant `addons[name] = AddonObject`
-- and means a fakeAddon-shaped stub and a real Lifecycle addon resolve to the
-- same entry.
local locales = {}

-- Internal helper: read-only proxy error. Matches Capabilities' frozen-table
-- discipline (Capabilities.lua:98).
local function rejectWrite()
    error("DragonCore.Locale: strings table is read-only", 2)
end

-- Internal helper: lazily construct (or return cached) per-addon registry
-- entry. Called by :Register and :Get; the proxy is built on first :Get.
local function entryFor(name)
    local entry = locales[name]
    if entry == nil then
        entry = { default = {}, active = {} }
        locales[name] = entry
    end
    return entry
end

-- Internal helper: build (once) the read-only proxy for an entry. The proxy
-- is the stable handle returned by :Get; section 2.1 of the design note.
local function proxyFor(entry)
    if entry.proxy == nil then
        local default = entry.default
        local active = entry.active
        entry.proxy = setmetatable({}, {
            __index = function(_, k)
                return active[k] or default[k] or k
            end,
            __newindex = rejectWrite,
            __metatable = false,
        })
    end
    return entry.proxy
end

-- Internal helper: merge `strings` into `slot` with enUS normalisation. When
-- `normaliseTrue` is true, a `true` value is rewritten to the key itself; non-
-- string / non-true values in the workspace convention should not occur but
-- are passed through unchanged for honest behaviour under unexpected input.
local function mergeInto(slot, strings, normaliseTrue)
    for k, v in pairs(strings) do
        if v == true and normaliseTrue then
            slot[k] = k
        else
            slot[k] = v
        end
    end
end

-------------------------------------------------------------------------------
-- Locale
-------------------------------------------------------------------------------

---@class DragonCore.Locale
local Locale = {}

---Register a locale table for an addon.
---
---Slot selection (design note section 2.3):
---   * locale == "enUS"           -> populate `default` (key-normalised).
---   * locale == GetLocale()      -> populate `active`.
---   * Both apply (enUS client)   -> populate both slots.
---   * Other locales              -> dropped (no active client).
---
---Safety net: if no enUS table has been registered yet when a non-enUS
---register arrives, the non-enUS strings ALSO seed `default` so that :Get
---never returns nil for a string index. A later enUS register overwrites the
---placeholder. Preserves the "never nil for a string index" invariant under
---any registration order.
---
---Repeated registers for the same (addon, locale) pair merge into the
---existing slot; later keys win on collision. Matches AceLocale semantics
---and supports splitting an addon's locale table across files.
---@param addon DragonCore.Addon
---@param locale string
---@param strings table<string, string|true>
function Locale:Register(addon, locale, strings)
    validateAddon("Register", addon)
    if type(locale) ~= "string" or locale == "" then
        error("DragonCore.Locale:Register: locale must be a non-empty string", 2)
    end
    if type(strings) ~= "table" then
        error("DragonCore.Locale:Register: strings must be a table", 2)
    end

    local entry = entryFor(addon.name)
    local clientLocale = _G.GetLocale and _G.GetLocale() or "enUS"
    -- enUS values may use the workspace `true` sentinel (key IS the English
    -- string). Normalise at the registration boundary so neither slot ever
    -- stores `true` for an enUS-sourced register; reads then run
    -- `active[k] or default[k] or k` without a type check (design note 2.2).
    local normaliseTrue = (locale == "enUS")

    if locale == "enUS" then
        mergeInto(entry.default, strings, normaliseTrue)
    end
    if locale == clientLocale then
        mergeInto(entry.active, strings, normaliseTrue)
    end
    if locale ~= "enUS" and locale ~= clientLocale then
        -- Other locales are dropped. The safety net below only applies when
        -- `default` is still empty so the addon does not register an enUS
        -- table at all -- highly unusual but kept honest per ADR line 523.
        return
    end

    -- Safety net (design note section 2.3): if `default` is still empty after
    -- this register, seed it from `strings` (key-normalised) so :Get never
    -- returns nil for a string index. The next enUS register overwrites.
    if next(entry.default) == nil then
        mergeInto(entry.default, strings, true)
    end
end

---Return the active strings proxy for an addon. The proxy is stable across
---calls (`:Get(addon) == :Get(addon)`) and read-only (`L["X"] = "Y"` raises).
---Reads resolve `active[k] or default[k] or k`; never returns nil for a
---string index.
---@param addon DragonCore.Addon
---@return DragonCore.Locale.Strings
function Locale:Get(addon)
    validateAddon("Get", addon)
    return proxyFor(entryFor(addon.name))
end

---Format a localised template. Resolves `template` through the same chain as
---:Get -- active template -> enUS template -> key-as-template -- and feeds
---the result to `string.format(resolved, ...)`. Format errors propagate.
---@param addon DragonCore.Addon
---@param template string
---@param ... any
---@return string
function Locale:Format(addon, template, ...)
    validateAddon("Format", addon)
    if type(template) ~= "string" then
        error("DragonCore.Locale:Format: template must be a string", 2)
    end

    local entry = entryFor(addon.name)
    -- `type(...) == "string"` guards prevent stray non-string sentinels from
    -- reaching string.format (defence in depth; normalisation at register
    -- already strips enUS `true` from `default`).
    local active = entry.active[template]
    local default = entry.default[template]
    local resolved
    if type(active) == "string" then
        resolved = active
    elseif type(default) == "string" then
        resolved = default
    else
        resolved = template
    end
    return string.format(resolved, ...)
end

DragonCore.Locale = Locale
