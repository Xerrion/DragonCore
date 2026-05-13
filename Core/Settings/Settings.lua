-------------------------------------------------------------------------------
-- Settings.lua
-- DragonCore declarative settings registry. Library-global (NOT per-addon
-- instance): one schema per addon.name, picked up by the runtime-selected
-- renderer (Renderer_Modern vs Renderer_Legacy). Three public methods:
-- :Register, :Open, :Refresh -- no :On, no :Dispose, no Settings:New.
--
-- Public surface (ADR-0003 section B.4 / design note section 1):
--   :Register(addon, schema)  -> { ok, errors? }
--   :Open(addon)              -> ()  [raises if not registered]
--   :Refresh(addon)           -> { ok, errors? }
--
-- Argument-shape errors raise at error level 3 (validateAddon helper +
-- public method peeled off the stack, matching Listener / EventBus / Locale /
-- AddonChannel / Store). Schema-content errors return `{ok = false, errors}`
-- so the consumer can inspect and decide; argument-shape errors and
-- :Open / :Refresh "not registered" cases still raise.
--
-- Re-registration (ADR R-4 line 852): a second :Register for the same addon
-- forwards to the Refresh codepath. Blizzard's RegisterAddOnCategory is
-- one-shot per category; the panel frame and category handle are reused.
--
-- Slash commands (ADR line 476): v0 implements `<no-args>` and `open` as
-- aliases that call :Open, and `reset` which invokes every TOP-LEVEL value
-- node's `set(default)` (no recursion into nested groups -- conservative
-- per design note conflict log #3). `<subgroup>` navigation is deferred.
--
-- Pillar 5 (Atomic Predictability): Settings.lua is pure registry CRUD --
-- no frames, no events. Frame creation lives in Renderer_Modern.lua and
-- Renderer_Legacy.lua (ADR line 880 RISK acknowledged).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Synthetic addon for library chrome strings. Registered against by
-- Locales/enUS.lua at TOC-load time; Locale's per-addon registry keys on
-- addon.name so the same identity must be used at both sides.
-------------------------------------------------------------------------------

local SETTINGS_OWN_ADDON = { name = "DragonCore" }

-------------------------------------------------------------------------------
-- Lazy dependency resolution. Capabilities IS listed (design note section 2
-- enforces it as a layering hop even though v0 probes _G.Settings directly
-- because Capabilities.settingsAPI is not yet exposed by the frozen
-- Capabilities table -- see engineer Notes for the follow-up).
-------------------------------------------------------------------------------

local function resolveDeps()
    local caps = DragonCore.Capabilities
    local locale = DragonCore.Locale
    local secureCall = DragonCore.SecureCall
    local rendererModern = DragonCore._SettingsRendererModern
    local rendererLegacy = DragonCore._SettingsRendererLegacy
    if not caps then
        error("DragonCore.Settings: DragonCore.Capabilities is not loaded", 3)
    end
    if not locale then
        error("DragonCore.Settings: DragonCore.Locale is not loaded", 3)
    end
    if not secureCall then
        error("DragonCore.Settings: DragonCore.SecureCall is not loaded", 3)
    end
    if not rendererModern then
        error("DragonCore.Settings: DragonCore._SettingsRendererModern is not loaded", 3)
    end
    if not rendererLegacy then
        error("DragonCore.Settings: DragonCore._SettingsRendererLegacy is not loaded", 3)
    end
    return caps, locale, secureCall, rendererModern, rendererLegacy
end

-------------------------------------------------------------------------------
-- Node-type classification
-------------------------------------------------------------------------------

local VALID_NODE_TYPES = {
    group = true,
    toggle = true,
    slider = true,
    select = true,
    input = true,
    color = true,
    action = true,
    header = true,
    description = true,
}

-- Value nodes require both get and set. The deferred trio (color/input)
-- still validates as value-shaped per ADR R-1 line 849 -- schemas authored
-- against the v0 contract migrate cleanly when the renderer fills in.
local VALUE_NODE_TYPES = {
    toggle = true,
    slider = true,
    select = true,
    input = true,
    color = true,
}

-------------------------------------------------------------------------------
-- Validation -- argument-shape (raise) vs schema-content (return errors)
--
-- error(..., 3) so the reported source position is the consumer's call site
-- -- the helper and the public method are both peeled off the stack. Matches
-- Listener / EventBus / Locale / AddonChannel / Store verbatim.
-------------------------------------------------------------------------------

local function validateAddon(method, addon)
    if addon == nil then
        error("DragonCore.Settings:" .. method ..
            ": addon is required (DragonCore.Addon)", 3)
    end
    if type(addon) ~= "table" then
        error("DragonCore.Settings:" .. method ..
            ": addon must be a table (DragonCore.Addon), got " .. type(addon), 3)
    end
    if type(addon.name) ~= "string" or addon.name == "" then
        error("DragonCore.Settings:" .. method ..
            ": addon.name must be a non-empty string", 3)
    end
end

local function validateSchemaShape(schema)
    if schema == nil or type(schema) ~= "table" then
        error("DragonCore.Settings:Register: schema must be a table", 3)
    end
    if type(schema.name) ~= "string" or schema.name == "" then
        error("DragonCore.Settings:Register: schema.name must be a non-empty string", 3)
    end
    if type(schema.root) ~= "table" then
        error("DragonCore.Settings:Register: schema.root must be a table", 3)
    end
    if schema.slashCommands ~= nil then
        if type(schema.slashCommands) ~= "table" then
            error("DragonCore.Settings:Register: schema.slashCommands must be a " ..
                "string[] if provided", 3)
        end
        for i = 1, #schema.slashCommands do
            local cmd = schema.slashCommands[i]
            if type(cmd) ~= "string" or cmd:sub(1, 1) ~= "/" then
                error("DragonCore.Settings:Register: schema.slashCommands[" .. i ..
                    "] must be a '/'-prefixed string", 3)
            end
        end
    end
end

-- Internal helper: append per-node validation errors to `errors` keyed by a
-- dotted path (e.g. "root.children[2]"). Returns nothing; the caller checks
-- `#errors == 0` to decide ok-vs-not.
local function validateNode(node, path, errors)
    if type(node) ~= "table" then
        errors[#errors + 1] = path .. ": node must be a table, got " .. type(node)
        return
    end
    if not VALID_NODE_TYPES[node.type] then
        errors[#errors + 1] = path .. ": unknown node.type '" ..
            tostring(node.type) .. "'"
        -- Stop here; without a known type the per-type checks below are noise.
        return
    end
    if type(node.label) ~= "string" or node.label == "" then
        errors[#errors + 1] = path .. ": label must be a non-empty string"
    end

    if VALUE_NODE_TYPES[node.type] then
        if type(node.get) ~= "function" then
            errors[#errors + 1] = path .. ": " .. node.type ..
                " requires a get function"
        end
        if type(node.set) ~= "function" then
            errors[#errors + 1] = path .. ": " .. node.type ..
                " requires a set function"
        end
    end

    if node.type == "slider" then
        local minOk = type(node.min) == "number"
        local maxOk = type(node.max) == "number"
        local stepOk = type(node.step) == "number"
        if not minOk then
            errors[#errors + 1] = path .. ": slider requires numeric min"
        end
        if not maxOk then
            errors[#errors + 1] = path .. ": slider requires numeric max"
        end
        if not stepOk then
            errors[#errors + 1] = path .. ": slider requires numeric step"
        end
        if minOk and maxOk and node.min >= node.max then
            errors[#errors + 1] = path .. ": slider min must be < max"
        end
        if stepOk and node.step <= 0 then
            errors[#errors + 1] = path .. ": slider step must be > 0"
        end
    elseif node.type == "select" then
        if type(node.options) ~= "table" or next(node.options) == nil then
            errors[#errors + 1] = path .. ": select requires a non-empty options table"
        elseif type(node.optionsOrder) == "table" then
            for i = 1, #node.optionsOrder do
                local key = node.optionsOrder[i]
                if node.options[key] == nil then
                    errors[#errors + 1] = path .. ": select.optionsOrder[" .. i ..
                        "] key '" .. tostring(key) ..
                        "' is not present in options"
                end
            end
        end
    elseif node.type == "action" then
        if type(node.run) ~= "function" then
            errors[#errors + 1] = path .. ": action requires a run function"
        end
    elseif node.type == "group" then
        if type(node.children) ~= "table" then
            errors[#errors + 1] = path .. ": group requires a children table"
        else
            for i = 1, #node.children do
                validateNode(node.children[i],
                    path .. ".children[" .. i .. "]", errors)
            end
        end
    end
end

local function validateSchemaContent(schema)
    local errors = {}
    validateNode(schema.root, "root", errors)
    return errors
end

-------------------------------------------------------------------------------
-- Registry. File-private; keyed by addon.name (ADR line 471). The presence
-- of an entry is the "is registered?" check; absence => first-time Register.
--   registry[addon.name] = {
--       addon    = DragonCore.Addon,
--       schema   = DragonCore.Settings.Schema,
--       renderer = Renderer_Modern | Renderer_Legacy,
--       handle   = renderer-specific handle table (panel frame + category),
--       slashKey = uppercase addon.name (when slashCommands wired) or nil,
--   }
-------------------------------------------------------------------------------

local registry = {}

-- Internal helper: pick renderer at :Register time by probing _G.Settings.
-- Design note section 2 cites Capabilities.settingsAPI as the canonical
-- probe; the frozen Capabilities table does not expose that flag in v0, so
-- we inline the same probe (ADR section C line 613).
local function pickRenderer()
    local _, _, _, rendererModern, rendererLegacy = resolveDeps()
    if type(_G.Settings) == "table"
        and type(_G.Settings.RegisterAddOnCategory) == "function" then
        return rendererModern
    end
    return rendererLegacy
end

-------------------------------------------------------------------------------
-- Forward declaration of Settings so the slash handler can call back into
-- :Open / :Refresh by name. The handler is defined before Settings methods
-- so wireSlashCommands can close over it; the call sites resolve at slash
-- invocation time (well after module load), so the forward ref is safe.
-------------------------------------------------------------------------------

---@class DragonCore.Settings
local Settings = {}

-- Internal helper: iterate every TOP-LEVEL value node (direct children of
-- root). Conservative scope per design note conflict log #3 -- recursive
-- reset across nested groups is not in v0.
local function iterTopLevelValueNodes(root, fn)
    if type(root) ~= "table" or root.type ~= "group" then return end
    local children = root.children
    if type(children) ~= "table" then return end
    for i = 1, #children do
        local child = children[i]
        if type(child) == "table" and VALUE_NODE_TYPES[child.type] then
            fn(child)
        end
    end
end

-- Internal helper: slash command dispatcher. Bound once per addon when
-- wireSlashCommands runs at :Register first-time. Closes over the addon
-- handle so subsequent :Refresh calls do not need to rebind.
local function handleSlashCommand(addon, msg)
    local _, locale, secureCall = resolveDeps()
    local entry = registry[addon.name]
    if not entry then return end

    local rawVerb = (msg or ""):match("^%s*(%S*)") or ""
    local verb = rawVerb:lower()

    if verb == "" or verb == "open" then
        Settings:Open(addon)
        return
    end

    if verb == "reset" then
        iterTopLevelValueNodes(entry.schema.root, function(node)
            if node.default ~= nil and type(node.set) == "function" then
                secureCall:Invoke(node.set, node.default)
            end
        end)
        return
    end

    -- Unknown verb: print a help message resolved through Locale chrome.
    -- Fallback path returns the key itself when Locales/enUS.lua has not
    -- registered chrome strings (degraded harness), so the message is
    -- non-empty either way.
    local L = locale:Get(SETTINGS_OWN_ADDON)
    local template =
        L["DragonCore: unknown slash subcommand '%s'. Try '/<cmd>', '/<cmd> open', or '/<cmd> reset'."]
    if type(_G.print) == "function" then
        _G.print(template:format(rawVerb))
    end
end

local function wireSlashCommands(addon, slashCommands)
    if type(slashCommands) ~= "table" or #slashCommands == 0 then return nil end
    local upper = addon.name:upper()
    for i = 1, #slashCommands do
        _G["SLASH_" .. upper .. i] = slashCommands[i]
    end
    _G.SlashCmdList[upper] = function(msg) handleSlashCommand(addon, msg) end
    return upper
end

-------------------------------------------------------------------------------
-- Public surface
-------------------------------------------------------------------------------

---Register a schema for `addon`. On re-call for the same addon, forwards to
---the :Refresh codepath per ADR R-4. Returns a typed result; on `ok =
---false`, no registration takes place (or no re-render, in the re-call
---case) and `errors` enumerates the validation failures.
---
---Argument-shape errors (nil addon, missing schema, malformed
---slashCommands) raise at error level 3; schema-content errors (unknown
---node type, missing required field for a node type) return ok = false.
---@param addon DragonCore.Addon
---@param schema DragonCore.Settings.Schema
---@return DragonCore.Settings.RegisterResult
function Settings:Register(addon, schema)
    validateAddon("Register", addon)
    validateSchemaShape(schema)
    resolveDeps()  -- ensure deps present before mutating registry

    local errors = validateSchemaContent(schema)
    if #errors > 0 then
        return { ok = false, errors = errors }
    end

    local existing = registry[addon.name]
    if existing then
        -- R-4: re-register is refresh. Update stored schema, hand off to
        -- the renderer's Refresh path so RegisterAddOnCategory is NOT
        -- called a second time (Blizzard rejects re-registration).
        existing.schema = schema
        existing.renderer:Refresh(existing.handle, schema)
        return { ok = true }
    end

    local renderer = pickRenderer()
    local handle = renderer:Render(addon, schema)
    local slashKey = wireSlashCommands(addon, schema.slashCommands)

    registry[addon.name] = {
        addon = addon,
        schema = schema,
        renderer = renderer,
        handle = handle,
        slashKey = slashKey,
    }
    return { ok = true }
end

---Open the addon's settings panel. Raises if the addon has not been
---registered.
---@param addon DragonCore.Addon
function Settings:Open(addon)
    validateAddon("Open", addon)
    resolveDeps()
    local entry = registry[addon.name]
    if entry == nil then
        error("DragonCore.Settings:Open: addon '" .. addon.name ..
            "' is not registered", 3)
    end
    entry.renderer:Open(entry.handle)
end

---Re-render an already-registered addon's panel. Re-validates the stored
---schema (so a consumer who mutated `entry.schema` post-Register gets a
---typed result); if validation fails the prior rendering is left in place.
---Raises if `addon` has not been registered.
---@param addon DragonCore.Addon
---@return DragonCore.Settings.RegisterResult
function Settings:Refresh(addon)
    validateAddon("Refresh", addon)
    resolveDeps()
    local entry = registry[addon.name]
    if entry == nil then
        error("DragonCore.Settings:Refresh: addon '" .. addon.name ..
            "' is not registered", 3)
    end

    local errors = validateSchemaContent(entry.schema)
    if #errors > 0 then
        return { ok = false, errors = errors }
    end

    entry.renderer:Refresh(entry.handle, entry.schema)
    return { ok = true }
end

DragonCore.Settings = Settings
