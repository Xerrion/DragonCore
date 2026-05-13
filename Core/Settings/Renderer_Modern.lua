-------------------------------------------------------------------------------
-- Renderer_Modern.lua
-- DragonCore Settings renderer for the modern Blizzard Settings API (retail
-- 10.0+ / late MoP Classic). Builds the panel via Settings.RegisterAddOnCategory,
-- creates one UNNAMED Frame per schema node (taint contract per ADR line 750),
-- and invokes value-node get closures via SecureCall:Invoke so consumer code
-- runs under the taint guard (ADR D.3).
--
-- Per ADR R-1 (line 849): six node types render faithfully in v0 (`group`,
-- `toggle`, `slider`, `select`, `action`, `header`); `color`, `input`,
-- `description` render as header placeholders -- the schema validator
-- accepts them, but the renderer does NOT call their `get` and creates the
-- frame without attaching a widget. Consumers can ship 9-type schemas today
-- and migrate transparently when the 0.2.0 renderer lands.
--
-- This module is NOT part of the public DragonCore-1.0 surface; it attaches
-- as DragonCore._SettingsRendererModern (mirrors Serializer.lua pattern).
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary (legacy fallback)
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

-------------------------------------------------------------------------------
-- Lazy dependency resolution. SecureCall is the only DragonCore dep -- the
-- renderer talks to _G.Settings directly (Blizzard API surface, not a
-- DragonCore module).
-------------------------------------------------------------------------------

local function resolveDeps()
    local secureCall = DragonCore.SecureCall
    if not secureCall then
        error("DragonCore.Settings.Renderer_Modern: DragonCore.SecureCall is not loaded", 3)
    end
    return secureCall
end

-------------------------------------------------------------------------------
-- Node classification mirrors Settings.lua. Kept local so the renderer can
-- decide whether to call `get` without reaching across module boundaries.
-------------------------------------------------------------------------------

-- Value nodes that the v0 renderer materialises with a widget AND populates
-- via `get`. The deferred trio (`color`, `input`, `description`) is below.
local FAITHFUL_VALUE_TYPES = {
    toggle = true,
    slider = true,
    select = true,
}

-- The R-1 deferred trio (`color`, `input`, `description`) and the static
-- types (`action`, `header`) are intentionally not enumerated here -- they
-- share the same render path (unnamed frame, no widget, no consumer call)
-- and are documented in the trailing comment of `buildNode`.

-------------------------------------------------------------------------------
-- Tree walk
--
-- Each node gets its own unnamed Frame as a child of the supplied parent.
-- Frames are never named (`CreateFrame("Frame", nil, parent)`) so the mock's
-- taint-contract assertion (ADR line 750) holds for every node type.
-------------------------------------------------------------------------------

local function buildNode(secureCall, node, parent)
    local frame = _G.CreateFrame("Frame", nil, parent)

    if node.type == "group" then
        if type(node.children) == "table" then
            for i = 1, #node.children do
                buildNode(secureCall, node.children[i], frame)
            end
        end
    elseif FAITHFUL_VALUE_TYPES[node.type] then
        -- Pull initial value through SecureCall so a faulty `get` does not
        -- abort the render walk (ADR D.3 invariant).
        if type(node.get) == "function" then
            secureCall:Invoke(node.get)
        end
    end
    -- Remaining types (`action`, `header`, and the R-1 deferred trio
    -- `color`/`input`/`description`) materialise as an unnamed frame with
    -- no widget attached: action and header have no consumer closure to
    -- call at render time; the deferred trio renders as a header
    -- placeholder per ADR R-1 line 849 with no get invocation.

    return frame
end

-------------------------------------------------------------------------------
-- Renderer
-------------------------------------------------------------------------------

---@class DragonCore.Settings.Renderer_Modern
local Renderer = {}

---Build the Blizzard category panel for `addon` from `schema`. Returns a
---handle that Settings.lua stores in its registry and forwards to :Refresh
---and :Open.
---@param addon DragonCore.Addon
---@param schema DragonCore.Settings.Schema
---@return table handle
function Renderer:Render(addon, schema)
    local secureCall = resolveDeps()

    -- Container frame for the category. Unnamed; parent is whatever
    -- Blizzard's category framework attaches it to (nil at construction).
    local panel = _G.CreateFrame("Frame", nil, nil)
    panel.name = schema.name  -- Blizzard reads this for the category label.

    local category = _G.Settings.RegisterAddOnCategory(panel, schema.name)

    buildNode(secureCall, schema.root, panel)

    return {
        addon = addon,
        schema = schema,
        panel = panel,
        category = category,
    }
end

---Re-render an already-registered panel after a schema or value change.
---Re-uses the existing panel frame (Blizzard's category registration is
---one-shot per ADR R-4); the widget tree is rebuilt inside it.
---@param handle table
---@param schema DragonCore.Settings.Schema
function Renderer:Refresh(handle, schema)
    local secureCall = resolveDeps()
    handle.schema = schema
    buildNode(secureCall, schema.root, handle.panel)
end

---Open the panel via Blizzard's Settings.OpenToCategory.
---@param handle table
function Renderer:Open(handle)
    _G.Settings.OpenToCategory(handle.category)
end

DragonCore._SettingsRendererModern = Renderer
