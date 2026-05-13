-------------------------------------------------------------------------------
-- Renderer_Legacy.lua
-- DragonCore Settings renderer for the legacy InterfaceOptions API (Classic
-- Era / early Classic flavors). Same surface as Renderer_Modern: :Render,
-- :Refresh, :Open. Builds the panel via InterfaceOptions_AddCategory, opens
-- via InterfaceOptionsFrame_OpenToCategory.
--
-- Same R-1 placeholder discipline as the modern renderer: `color`, `input`,
-- `description` render as header placeholders (no widget, no `get` call);
-- the other six node types render faithfully.
--
-- Frames are unnamed throughout per ADR taint contract line 750.
--
-- Attaches as DragonCore._SettingsRendererLegacy (private surface).
--
-- Supported versions: Classic Era, TBC Anniversary, Wrath/Cata/MoP Classic
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution.
-------------------------------------------------------------------------------

local function resolveDeps()
    local secureCall = DragonCore.SecureCall
    if not secureCall then
        error("DragonCore.Settings.Renderer_Legacy: DragonCore.SecureCall is not loaded", 3)
    end
    return secureCall
end

-------------------------------------------------------------------------------
-- Node classification (mirrors Renderer_Modern; deliberately duplicated --
-- the renderers are independent codepaths per Pillar 3, and a shared helper
-- module is not justified for two consumers).
-------------------------------------------------------------------------------

local FAITHFUL_VALUE_TYPES = {
    toggle = true,
    slider = true,
    select = true,
}

-- The R-1 deferred trio (`color`, `input`, `description`) and the static
-- types (`action`, `header`) share the same render path: an unnamed frame
-- with no widget and no consumer closure call. They are not enumerated
-- because the `else` arm of `buildNode` is sufficient.

local function buildNode(secureCall, node, parent)
    local frame = _G.CreateFrame("Frame", nil, parent)

    if node.type == "group" then
        if type(node.children) == "table" then
            for i = 1, #node.children do
                buildNode(secureCall, node.children[i], frame)
            end
        end
    elseif FAITHFUL_VALUE_TYPES[node.type] then
        if type(node.get) == "function" then
            secureCall:Invoke(node.get)
        end
    end
    -- All other node types render as an unnamed frame with no widget per
    -- ADR R-1 line 849 (placeholder trio) and the static-node contract
    -- (action/header have no render-time consumer closure).

    return frame
end

-------------------------------------------------------------------------------
-- Renderer
-------------------------------------------------------------------------------

---@class DragonCore.Settings.Renderer_Legacy
local Renderer = {}

---Build the InterfaceOptions panel for `addon`. The container frame's
---`.name` field is Blizzard's category label on the legacy API.
---@param addon DragonCore.Addon
---@param schema DragonCore.Settings.Schema
---@return table handle
function Renderer:Render(addon, schema)
    local secureCall = resolveDeps()

    local panel = _G.CreateFrame("Frame", nil, nil)
    panel.name = schema.name

    _G.InterfaceOptions_AddCategory(panel)

    buildNode(secureCall, schema.root, panel)

    return {
        addon = addon,
        schema = schema,
        panel = panel,
        -- Legacy API has no separate category handle; the panel itself is
        -- the OpenToCategory argument.
        category = panel,
    }
end

---@param handle table
---@param schema DragonCore.Settings.Schema
function Renderer:Refresh(handle, schema)
    local secureCall = resolveDeps()
    handle.schema = schema
    buildNode(secureCall, schema.root, handle.panel)
end

---@param handle table
function Renderer:Open(handle)
    _G.InterfaceOptionsFrame_OpenToCategory(handle.category)
end

DragonCore._SettingsRendererLegacy = Renderer
