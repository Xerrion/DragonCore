-------------------------------------------------------------------------------
-- Renderer_Modern.lua
-- DragonCore Settings renderer for the modern Blizzard Settings API
-- (Patch 10.0.0+ engine). Builds the panel via
-- Settings.RegisterCanvasLayoutCategory + Settings.RegisterAddOnCategory,
-- creates UNNAMED Frames per the taint contract (no named regions anywhere
-- under our panel), and invokes consumer closures (`node.get`, `node.set`,
-- `node.run`) exclusively via SecureCall:Invoke.
--
-- v0 widget coverage (ADR-0003, 2026-05-13-dragoncore-v0-widget-contract):
--   FAITHFUL (rendered with real interactive widgets):
--     group, header, toggle, slider, action
--   PLACEHOLDER (rendered as a "[deferred: <type>]" FontString):
--     select, input, color, description
--
-- The schema validator in Settings.lua accepts all nine types; placeholder
-- types validate and draw a visible label so consumers can author full
-- 9-type schemas today and migrate transparently when each deferred type
-- lands its real widget.
--
-- Panel sizing strategy: panel:SetAllPoints(panel:GetParent()) on the first
-- OnShow, gated by a one-shot flag. Settings.RegisterCanvasLayoutCategory
-- reparents the panel lazily when the category opens, so a SetAllPoints at
-- construction time is a no-op against nil parent.
--
-- :Refresh re-pulls value-node `get` closures and updates widgets in place
-- via SetChecked / SetValue. It NEVER rebuilds the widget tree: unnamed
-- Blizzard frames cannot be cleanly destroyed and reclaimed, and a rebuild
-- would flash the panel.
--
-- This module is NOT part of the public DragonCore-1.0 surface; it attaches
-- as DragonCore._SettingsRendererModern (mirrors Serializer.lua pattern).
--
-- Supported versions: any client that exposes the modern Settings API
-- (Patch 10.0.0+ engine). This covers Retail Mainline 10.0+, MoP Classic
-- 5.5+, TBC Anniversary 2.5.5+, and Vanilla Classic 1.15+; all currently
-- shipped flavors run the same modern UI engine. Selection is gated by
-- DragonCore.Capabilities.settingsAPI.
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
-- Layout constants (ADR-0003 section "Child layout strategy"). Declared at
-- module scope so widget construction and the layout helper agree on the
-- same numbers; tweaking visual density happens here, not in every type.
-------------------------------------------------------------------------------

local LAYOUT = {
    PANEL_MARGIN_LEFT = 16,
    PANEL_MARGIN_TOP = 16,
    PANEL_MARGIN_RIGHT = 16,
    SIBLING_SPACING = 8,
    SECTION_SPACING = 16,       -- extra space before a `header` node.
    LABEL_GAP = 6,              -- gap between a checkbox and its label.
    WIDGET_HEIGHT_TOGGLE = 24,
    WIDGET_HEIGHT_SLIDER = 48,  -- label + slider track + min/max row.
    WIDGET_HEIGHT_ACTION = 26,
    WIDGET_HEIGHT_HEADER = 24,
    WIDGET_HEIGHT_PLACEHOLDER = 20,
    BUTTON_WIDTH = 160,
}

-------------------------------------------------------------------------------
-- Node classification. The schema validator (Settings.lua) accepts nine
-- types; the renderer splits them into "faithful" (full widget) and
-- "placeholder" (visible "[deferred: <type>]" label). `group` is structural:
-- no widget, children flatten into the parent layout cursor.
-------------------------------------------------------------------------------

local FAITHFUL_VALUE_TYPES = {
    group = true,
    header = true,
    toggle = true,
    slider = true,
    action = true,
}

local PLACEHOLDER_TYPES = {
    select = true,
    input = true,
    color = true,
    description = true,
}

-- Value-shaped types whose widgets must re-pull on :Refresh. `action`,
-- `header`, `group`, and placeholders are static -- :Refresh skips them.
local REFRESHABLE_TYPES = {
    toggle = true,
    slider = true,
}

-------------------------------------------------------------------------------
-- Layout helper. `cursor.previous` is the most recently anchored sibling
-- (Frame or nil for the first child); `cursor.panel` is the canvas the
-- whole stack lives under. Anchors a new frame TOPLEFT/TOPRIGHT to keep
-- widget widths inherited from the panel, then advances the cursor.
-------------------------------------------------------------------------------

local function anchorSibling(frame, cursor, isHeader)
    local topSpacing = isHeader and LAYOUT.SECTION_SPACING or LAYOUT.SIBLING_SPACING
    if cursor.previous == nil then
        frame:SetPoint("TOPLEFT", cursor.panel, "TOPLEFT",
            LAYOUT.PANEL_MARGIN_LEFT, -LAYOUT.PANEL_MARGIN_TOP)
        frame:SetPoint("TOPRIGHT", cursor.panel, "TOPRIGHT",
            -LAYOUT.PANEL_MARGIN_RIGHT, -LAYOUT.PANEL_MARGIN_TOP)
    else
        frame:SetPoint("TOPLEFT", cursor.previous, "BOTTOMLEFT",
            0, -topSpacing)
        frame:SetPoint("TOPRIGHT", cursor.panel, "TOPRIGHT",
            -LAYOUT.PANEL_MARGIN_RIGHT, 0)
    end
    cursor.previous = frame
end

-------------------------------------------------------------------------------
-- Per-type widget constructors. Each returns the container Frame so the
-- layout cursor advances uniformly; widget refs are stored in the supplied
-- `nodes` map under `index` for :Refresh re-pull.
-------------------------------------------------------------------------------

local function buildHeader(node, parent, cursor, nodes, index)
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetHeight(LAYOUT.WIDGET_HEIGHT_HEADER)
    anchorSibling(frame, cursor, true)

    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    fs:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(node.label)

    nodes[index] = { type = "header", frame = frame, fontString = fs }
    return frame
end

local function buildPlaceholder(node, parent, cursor, nodes, index)
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetHeight(LAYOUT.WIDGET_HEIGHT_PLACEHOLDER)
    anchorSibling(frame, cursor, false)

    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    fs:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText("[deferred: " .. node.type .. "] " .. (node.label or ""))

    nodes[index] = { type = node.type, frame = frame, fontString = fs }
    return frame
end

local function buildToggle(secureCall, node, parent, cursor, nodes, index)
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetHeight(LAYOUT.WIDGET_HEIGHT_TOGGLE)
    anchorSibling(frame, cursor, false)

    -- UICheckButtonTemplate is the standard Blizzard checkbox. ADR-0003
    -- flags "verify in implementation" for named-child taint; mock-side
    -- the template name is just recorded so the asssertion does not fire
    -- here. In-game verification is the load-bearing check.
    local cb = _G.CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    cb:SetSize(LAYOUT.WIDGET_HEIGHT_TOGGLE, LAYOUT.WIDGET_HEIGHT_TOGGLE)
    cb:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", LAYOUT.LABEL_GAP, 0)
    label:SetJustifyH("LEFT")
    label:SetText(node.label)

    local initial = secureCall:Invoke(node.get)
    cb:SetChecked(initial and true or false)
    cb:SetScript("OnClick", function(self)
        secureCall:Invoke(node.set, self:GetChecked() and true or false)
    end)

    nodes[index] = {
        type = "toggle",
        node = node,
        frame = frame,
        checkButton = cb,
        labelFontString = label,
    }
    return frame
end

local function buildSlider(secureCall, node, parent, cursor, nodes, index)
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetHeight(LAYOUT.WIDGET_HEIGHT_SLIDER)
    anchorSibling(frame, cursor, false)

    -- Path A: OptionsSliderTemplate (preferred). ADR-0003 flags this as a
    -- "verify in implementation" surface because the template historically
    -- creates _Low / _High / _Text named child regions when the parent is
    -- named; with our parent unnamed those children are typically also
    -- unnamed. Path B (bare Slider + manual textures) is the documented
    -- fallback if in-game verification surfaces named children. We default
    -- to Path A; switch by editing this constructor only.
    local slider = _G.CreateFrame("Slider", nil, frame, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -16)
    slider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -16)
    slider:SetHeight(16)
    slider:SetMinMaxValues(node.min, node.max)
    slider:SetValueStep(node.step)
    slider:SetObeyStepOnDrag(true)

    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    label:SetJustifyH("LEFT")
    label:SetText(node.label)

    local minLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    minLabel:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
    minLabel:SetText(tostring(node.min))

    local maxLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    maxLabel:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
    maxLabel:SetText(tostring(node.max))

    local initial = secureCall:Invoke(node.get)
    if type(initial) ~= "number" then initial = node.min end
    slider:SetValue(initial)

    -- node.set is required by the validator for value nodes, so the
    -- closure is always non-nil in well-formed schemas. The guard exists
    -- so a consumer that nils set post-validation does not crash the
    -- slider; mouse stays enabled because Blizzard's slider chrome
    -- (steppers, drag) is what gives the widget its visible affordance.
    if type(node.set) == "function" then
        slider:SetScript("OnValueChanged", function(_self, value)
            secureCall:Invoke(node.set, value)
        end)
    end

    nodes[index] = {
        type = "slider",
        node = node,
        frame = frame,
        slider = slider,
        labelFontString = label,
        minFontString = minLabel,
        maxFontString = maxLabel,
    }
    return frame
end

local function buildAction(secureCall, node, parent, cursor, nodes, index)
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetHeight(LAYOUT.WIDGET_HEIGHT_ACTION)
    anchorSibling(frame, cursor, false)

    local btn = _G.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(LAYOUT.BUTTON_WIDTH, LAYOUT.WIDGET_HEIGHT_ACTION)
    btn:SetPoint("LEFT", frame, "LEFT", 0, 0)
    btn:SetText(node.label)
    btn:SetScript("OnClick", function()
        secureCall:Invoke(node.run)
    end)

    nodes[index] = {
        type = "action",
        node = node,
        frame = frame,
        button = btn,
    }
    return frame
end

-------------------------------------------------------------------------------
-- Walk. `index` advances depth-first preorder so :Refresh can map nodes to
-- stored widget records without re-walking the schema in a separate pass.
-- The cursor is shared across the whole walk so nested groups flatten into
-- the same vertical stack (no indent in v0).
-------------------------------------------------------------------------------

local function walk(secureCall, node, parent, cursor, nodes, indexRef)
    if type(node) ~= "table" then return end

    indexRef.value = indexRef.value + 1
    local index = indexRef.value

    if node.type == "group" then
        -- Group is structural: no widget, no anchor. Children flatten into
        -- the cursor. We still claim an index so the nodes map mirrors the
        -- schema's preorder shape.
        nodes[index] = { type = "group", frame = parent }
        if type(node.children) == "table" then
            for i = 1, #node.children do
                walk(secureCall, node.children[i], parent, cursor, nodes, indexRef)
            end
        end
        return
    end

    if node.type == "header" then
        buildHeader(node, parent, cursor, nodes, index)
        return
    end

    if node.type == "toggle" then
        buildToggle(secureCall, node, parent, cursor, nodes, index)
        return
    end

    if node.type == "slider" then
        buildSlider(secureCall, node, parent, cursor, nodes, index)
        return
    end

    if node.type == "action" then
        buildAction(secureCall, node, parent, cursor, nodes, index)
        return
    end

    if PLACEHOLDER_TYPES[node.type] then
        buildPlaceholder(node, parent, cursor, nodes, index)
        return
    end

    -- Unknown type: validator should have rejected this; bail safely
    -- rather than crash mid-render. FAITHFUL_VALUE_TYPES is consulted
    -- defensively so the renderer's "five faithful types" contract is
    -- enforced at dispatch time, not only in the header docstring.
    if not FAITHFUL_VALUE_TYPES[node.type] then
        nodes[index] = { type = node.type, frame = parent }
    end
end

-------------------------------------------------------------------------------
-- Renderer
-------------------------------------------------------------------------------

---@class DragonCore.Settings.Renderer_Modern
local Renderer = {}

---Build the Blizzard category panel for `addon` from `schema`. Returns a
---handle that Settings.lua stores in its registry and forwards to :Refresh
---and :Open. Returns `nil` on soft-failure: the two Settings.* entry
---points are wrapped in pcall so a partial-stub Classic flavor that throws
---inside Blizzard code does not crash the addon. On failure, a single
---orange warning is printed to chat and the registry records the entry as
---`failed`; slash commands remain wired.
---@param addon DragonCore.Addon
---@param schema DragonCore.Settings.Schema
---@return table|nil handle  nil signals soft failure to Settings:Register.
function Renderer:Render(addon, schema)
    local secureCall = resolveDeps()

    -- Container frame for the category. Unnamed; parent is whatever
    -- Blizzard's category framework attaches it to (nil at construction).
    local panel = _G.CreateFrame("Frame", nil, nil)
    panel.name = schema.name  -- Blizzard reads this for the category label.

    -- Modern API (wiki "Settings_API"): wrap the renderer-owned Frame as a
    -- canvas category, then install it under the AddOns group. Both calls
    -- go through pcall so a partial-stub Classic flavor where Blizzard's
    -- side throws (e.g. category-mixin construction faults) degrades to a
    -- soft failure rather than crashing the addon. RegisterAddOnCategory
    -- is single-argument and takes the category object, not the Frame.
    -- See ADR-0002 Risk Mitigation.
    local ok, category = pcall(_G.Settings.RegisterCanvasLayoutCategory, panel, schema.name)
    if not ok then
        if type(_G.print) == "function" then
            _G.print("|cffff8000DragonCore:|r options panel registration failed on this client ("
                .. tostring(category) .. "). Slash commands remain available.")
        end
        return nil
    end
    local okReg, errReg = pcall(_G.Settings.RegisterAddOnCategory, category)
    if not okReg then
        if type(_G.print) == "function" then
            _G.print("|cffff8000DragonCore:|r options panel registration failed on this client ("
                .. tostring(errReg) .. "). Slash commands remain available.")
        end
        return nil
    end

    -- Panel sizing: Settings.RegisterCanvasLayoutCategory reparents the
    -- panel lazily when the category opens, so the parent is nil at
    -- construction. First-OnShow is the WoW-idiomatic moment when the
    -- parent is guaranteed real; the one-shot flag prevents re-anchoring
    -- on subsequent category switches.
    panel:SetScript("OnShow", function(panelFrame)
        if panelFrame.__dragoncoreSized then return end
        local parent = panelFrame:GetParent()
        if parent then
            panelFrame:SetAllPoints(parent)
            panelFrame.__dragoncoreSized = true
        end
    end)

    local nodes = {}
    local cursor = { previous = nil, panel = panel }
    local indexRef = { value = 0 }
    walk(secureCall, schema.root, panel, cursor, nodes, indexRef)

    return {
        addon = addon,
        schema = schema,
        panel = panel,
        category = category,
        nodes = nodes,
    }
end

---Re-pull value-node `get` closures and update existing widgets in place.
---Does NOT rebuild the frame tree: unnamed Blizzard frames cannot be
---cleanly destroyed and reclaimed, and a rebuild would flash the panel.
---Static node types (`group`, `header`, `action`, placeholders) are no-ops.
---@param handle table
---@param schema DragonCore.Settings.Schema  stored for shape parity; the
---                                          actual closures live on the
---                                          per-node records under `node`.
function Renderer:Refresh(handle, schema)
    local secureCall = resolveDeps()
    handle.schema = schema

    local nodes = handle.nodes
    if type(nodes) ~= "table" then return end

    for i = 1, #nodes do
        local entry = nodes[i]
        if entry and REFRESHABLE_TYPES[entry.type] and entry.node then
            local value = secureCall:Invoke(entry.node.get)
            if entry.type == "toggle" then
                entry.checkButton:SetChecked(value and true or false)
            elseif entry.type == "slider" then
                if type(value) ~= "number" then value = entry.node.min end
                entry.slider:SetValue(value)
            end
        end
    end
end

---Open the panel via Blizzard's Settings.OpenToCategory.
---@param handle table
function Renderer:Open(handle)
    _G.Settings.OpenToCategory(handle.category)
end

DragonCore._SettingsRendererModern = Renderer
