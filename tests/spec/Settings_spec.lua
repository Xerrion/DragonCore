-------------------------------------------------------------------------------
-- Settings_spec.lua
-- Busted spec for DragonCore.Settings. Covers both renderer flavors (modern
-- _G.Settings + legacy InterfaceOptions) via Mock:SetSettingsAPI(true|false).
-- Load order (design note section 2): Subscription -> SecureCall ->
-- Capabilities -> Locale -> Renderer_Modern -> Renderer_Legacy -> Settings,
-- then Locales/enUS.lua so the chrome strings are registered against the
-- synthetic { name = "DragonCore" } addon.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

describe("DragonCore.Settings", function()
    local DragonCore
    local Settings
    local mock

    -- A minimal schema factory. Every spec that needs a schema can override
    -- specific fields via the overrides table.
    local function makeSchema(overrides)
        local schema = {
            name = "TestAddon Settings",
            root = {
                type = "group",
                label = "Root",
                children = {
                    {
                        type = "toggle",
                        label = "Enabled",
                        default = true,
                        get = function() return true end,
                        set = function(_v) end,
                    },
                },
            },
        }
        if overrides then
            for k, v in pairs(overrides) do schema[k] = v end
        end
        return schema
    end

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        mock = wow_mock.new()
        mock:Install()  -- installs _G.Settings AND legacy entry points by default

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Capabilities.lua")
        dofile("Core/Locale.lua")
        dofile("Core/Settings/Renderer_Modern.lua")
        dofile("Core/Settings/Renderer_Legacy.lua")
        dofile("Core/Settings/Settings.lua")
        dofile("Locales/enUS.lua")

        DragonCore = LibStub("DragonCore-1.0")
        Settings = DragonCore.Settings

        _G.securecallfunction = function(fn, ...) return fn(...) end
        _G.geterrorhandler = _G.geterrorhandler or function() return function() end end
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :Register argument-shape validation (raises at error level 3)
    ---------------------------------------------------------------------------

    describe(":Register argument-shape validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function() Settings:Register(nil, makeSchema()) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Settings:Register: addon is required (DragonCore.Addon)",
                1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() Settings:Register(bad, makeSchema()) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Settings:Register: addon must be a table", 1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1, err1 = pcall(function() Settings:Register({}, makeSchema()) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find(
                "DragonCore.Settings:Register: addon.name must be a non-empty string",
                1, true))
            local ok2 = pcall(function() Settings:Register({ name = "" }, makeSchema()) end)
            assert.is_false(ok2)
        end)

        it("rejects a non-table schema", function()
            local addon = wow_mock.fakeAddon()
            for _, bad in ipairs({ "schema", 42, true }) do
                local ok, err = pcall(function() Settings:Register(addon, bad) end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.Settings:Register: schema must be a table", 1, true))
            end
        end)

        it("rejects a schema with missing or empty name", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Settings:Register(addon, { root = { type = "group", label = "x", children = {} } })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Settings:Register: schema.name must be a non-empty string",
                1, true))
        end)

        it("rejects a schema with non-table root", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Settings:Register(addon, { name = "X", root = "not a table" })
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Settings:Register: schema.root must be a table", 1, true))
        end)

        it("rejects malformed slashCommands", function()
            local addon = wow_mock.fakeAddon()
            local ok, err = pcall(function()
                Settings:Register(addon, makeSchema({ slashCommands = "not a table" }))
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "schema.slashCommands must be a string[] if provided", 1, true))

            local ok2, err2 = pcall(function()
                Settings:Register(addon, makeSchema({ slashCommands = { "missing-slash" } }))
            end)
            assert.is_false(ok2)
            assert.is_truthy(err2:find(
                "schema.slashCommands[1] must be a '/'-prefixed string", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register schema-content validation (returns { ok = false, errors })
    ---------------------------------------------------------------------------

    describe(":Register schema-content validation", function()
        it("rejects an unknown node type", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = { type = "wat", label = "x" },
            })
            assert.is_false(result.ok)
            assert.is_table(result.errors)
            assert.is_truthy(result.errors[1]:find("unknown node.type 'wat'", 1, true))
        end)

        it("rejects a node missing label", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = { type = "group", children = {} },
            })
            assert.is_false(result.ok)
            assert.is_truthy(result.errors[1]:find(
                "label must be a non-empty string", 1, true))
        end)

        it("rejects a value node missing get/set", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = { { type = "toggle", label = "t" } },
                },
            })
            assert.is_false(result.ok)
            local joined = table.concat(result.errors, "\n")
            assert.is_truthy(joined:find("toggle requires a get function", 1, true))
            assert.is_truthy(joined:find("toggle requires a set function", 1, true))
        end)

        it("rejects a slider with min >= max", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "slider", label = "s",
                            min = 10, max = 5, step = 1,
                            get = function() return 5 end,
                            set = function(_v) end,
                        },
                    },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(table.concat(result.errors, "\n")
                :find("slider min must be < max", 1, true))
        end)

        it("rejects a slider with non-positive step", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "slider", label = "s",
                            min = 0, max = 10, step = 0,
                            get = function() return 5 end,
                            set = function(_v) end,
                        },
                    },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(table.concat(result.errors, "\n")
                :find("slider step must be > 0", 1, true))
        end)

        it("rejects a select with empty options", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "select", label = "s", options = {},
                            get = function() return "a" end,
                            set = function(_v) end,
                        },
                    },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(table.concat(result.errors, "\n")
                :find("select requires a non-empty options table", 1, true))
        end)

        it("rejects a select.optionsOrder with a key absent from options", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "select", label = "s",
                            options = { a = "A", b = "B" },
                            optionsOrder = { "a", "c" },
                            get = function() return "a" end,
                            set = function(_v) end,
                        },
                    },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(table.concat(result.errors, "\n")
                :find("optionsOrder[2] key 'c' is not present in options", 1, true))
        end)

        it("rejects an action without run", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = { { type = "action", label = "go" } },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(table.concat(result.errors, "\n")
                :find("action requires a run function", 1, true))
        end)

        it("emits a dotted path for nested errors", function()
            local result = Settings:Register(wow_mock.fakeAddon(), {
                name = "X",
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "group", label = "g",
                            children = { { type = "wat", label = "x" } },
                        },
                    },
                },
            })
            assert.is_false(result.ok)
            assert.is_truthy(result.errors[1]:find(
                "root.children[1].children[1]", 1, true))
        end)

        it("does NOT register when validation fails", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, { name = "X", root = { type = "wat", label = "x" } })
            local ok = pcall(function() Settings:Open(addon) end)
            assert.is_false(ok)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register happy path -- modern renderer
    ---------------------------------------------------------------------------

    describe(":Register happy path (modern renderer)", function()
        it("returns { ok = true } and calls Settings.RegisterAddOnCategory", function()
            local result = Settings:Register(wow_mock.fakeAddon(), makeSchema())
            assert.is_true(result.ok)
            local cats = mock:RegisteredCategories()
            assert.equals(1, #cats)
            assert.equals("Settings.RegisterAddOnCategory", cats[1].api)
            assert.equals("TestAddon Settings", cats[1].name)
        end)

        it("creates only unnamed frames (ADR taint contract)", function()
            local before = mock:FrameCount()
            Settings:Register(wow_mock.fakeAddon(), makeSchema())
            -- Panel + group root + toggle child = 3 unnamed frames. The
            -- CreateFrame mock raises if name is non-nil, so reaching this
            -- assertion proves every CreateFrame call passed nil.
            assert.is_true(mock:FrameCount() > before)
        end)

        it("invokes the value-node get through SecureCall during Render", function()
            local seen = 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "t",
                            get = function() seen = seen + 1; return true end,
                            set = function(_v) end,
                        },
                    },
                },
            }))
            assert.equals(1, seen)
        end)

        it("does NOT invoke get for ADR R-1 placeholder node types", function()
            local toggled, colored, inputted = 0, 0, 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "t",
                            get = function() toggled = toggled + 1; return true end,
                            set = function(_v) end,
                        },
                        {
                            type = "color", label = "c",
                            get = function() colored = colored + 1; return 1, 1, 1 end,
                            set = function() end,
                        },
                        {
                            type = "input", label = "i",
                            get = function() inputted = inputted + 1; return "" end,
                            set = function(_v) end,
                        },
                    },
                },
            }))
            assert.equals(1, toggled)
            assert.equals(0, colored)
            assert.equals(0, inputted)
        end)

        it("does not abort the render walk on a faulty get (SecureCall)", function()
            _G.securecallfunction = nil  -- exercise the real pcall path
            _G.geterrorhandler = function() return function() end end
            local secondSeen = 0
            local result = Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "boom",
                            get = function() error("kaboom") end,
                            set = function(_v) end,
                        },
                        {
                            type = "toggle", label = "ok",
                            get = function() secondSeen = secondSeen + 1; return true end,
                            set = function(_v) end,
                        },
                    },
                },
            }))
            assert.is_true(result.ok)
            assert.equals(1, secondSeen)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register happy path -- legacy renderer
    ---------------------------------------------------------------------------

    describe(":Register happy path (legacy renderer)", function()
        before_each(function()
            mock:SetSettingsAPI(false)
        end)

        it("falls through to InterfaceOptions_AddCategory when _G.Settings is nil",
            function()
                local result = Settings:Register(wow_mock.fakeAddon(), makeSchema())
                assert.is_true(result.ok)
                local cats = mock:RegisteredCategories()
                assert.equals(1, #cats)
                assert.equals("InterfaceOptions_AddCategory", cats[1].api)
                assert.equals("TestAddon Settings", cats[1].name)
            end)

        it("invokes the value-node get through SecureCall on legacy too", function()
            local seen = 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "slider", label = "s",
                            min = 0, max = 10, step = 1,
                            get = function() seen = seen + 1; return 5 end,
                            set = function(_v) end,
                        },
                    },
                },
            }))
            assert.equals(1, seen)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register re-call -> Refresh (ADR R-4)
    ---------------------------------------------------------------------------

    describe(":Register re-call (ADR R-4)", function()
        it("does not call RegisterAddOnCategory a second time", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema())
            local before = #mock:RegisteredCategories()
            local result = Settings:Register(addon, makeSchema({
                name = "TestAddon Settings (v2)",
            }))
            assert.is_true(result.ok)
            assert.equals(before, #mock:RegisteredCategories())
        end)

        it("re-runs the renderer's get to reflect new schema state", function()
            local addon = wow_mock.fakeAddon()
            local seen = 0
            local function buildSchema()
                return makeSchema({
                    root = {
                        type = "group", label = "r",
                        children = {
                            {
                                type = "toggle", label = "t",
                                get = function() seen = seen + 1; return true end,
                                set = function(_v) end,
                            },
                        },
                    },
                })
            end
            Settings:Register(addon, buildSchema())
            assert.equals(1, seen)
            Settings:Register(addon, buildSchema())
            assert.equals(2, seen)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Open
    ---------------------------------------------------------------------------

    describe(":Open", function()
        it("raises when the addon was never registered", function()
            local ok, err = pcall(function() Settings:Open(wow_mock.fakeAddon()) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Settings:Open: addon 'TestAddon' is not registered",
                1, true))
        end)

        it("calls Settings.OpenToCategory on the modern path", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema())
            mock:ClearOpenedCategory()
            Settings:Open(addon)
            assert.is_table(mock:OpenedCategory())
            assert.equals("TestAddon Settings", mock:OpenedCategory().name)
        end)

        it("calls InterfaceOptionsFrame_OpenToCategory on the legacy path", function()
            mock:SetSettingsAPI(false)
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema())
            mock:ClearOpenedCategory()
            Settings:Open(addon)
            assert.is_table(mock:OpenedCategory())
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Refresh
    ---------------------------------------------------------------------------

    describe(":Refresh", function()
        it("raises when the addon was never registered", function()
            local ok, err = pcall(function() Settings:Refresh(wow_mock.fakeAddon()) end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.Settings:Refresh: addon 'TestAddon' is not registered",
                1, true))
        end)

        it("re-runs the renderer's get without re-registering the category", function()
            local addon = wow_mock.fakeAddon()
            local seen = 0
            Settings:Register(addon, makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "t",
                            get = function() seen = seen + 1; return true end,
                            set = function(_v) end,
                        },
                    },
                },
            }))
            local before = #mock:RegisteredCategories()
            assert.equals(1, seen)
            local result = Settings:Refresh(addon)
            assert.is_true(result.ok)
            assert.equals(2, seen)
            assert.equals(before, #mock:RegisteredCategories())
        end)

        it("returns { ok = false } when the stored schema fails re-validation", function()
            local addon = wow_mock.fakeAddon()
            local schema = makeSchema()
            Settings:Register(addon, schema)
            -- Consumer mutates the stored schema into an invalid state.
            schema.root.children[1].type = "wat"
            local result = Settings:Refresh(addon)
            assert.is_false(result.ok)
            assert.is_truthy(result.errors[1]:find("unknown node.type 'wat'", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Slash commands
    ---------------------------------------------------------------------------

    describe("slash commands", function()
        it("wires SLASH_<NAME>1 and SlashCmdList entries when slashCommands set",
            function()
                Settings:Register(wow_mock.fakeAddon(), makeSchema({
                    slashCommands = { "/dctest", "/dct" },
                }))
                assert.equals("/dctest", _G["SLASH_TESTADDON1"])
                assert.equals("/dct", _G["SLASH_TESTADDON2"])
                assert.is_function(_G.SlashCmdList["TESTADDON"])
            end)

        it("opens the panel for an empty slash invocation", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema({ slashCommands = { "/dctest" } }))
            mock:ClearOpenedCategory()
            mock:SlashCommand("TESTADDON", "")
            assert.is_table(mock:OpenedCategory())
        end)

        it("opens the panel for 'open'", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema({ slashCommands = { "/dctest" } }))
            mock:ClearOpenedCategory()
            mock:SlashCommand("TESTADDON", "open")
            assert.is_table(mock:OpenedCategory())
        end)

        it("is case-insensitive on the verb", function()
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema({ slashCommands = { "/dctest" } }))
            mock:ClearOpenedCategory()
            mock:SlashCommand("TESTADDON", "OPEN")
            assert.is_table(mock:OpenedCategory())
        end)

        it("calls set(default) on every TOP-LEVEL value node for 'reset'", function()
            local resetValues = {}
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "a", default = true,
                            get = function() return false end,
                            set = function(v) resetValues.a = v end,
                        },
                        {
                            type = "slider", label = "b",
                            min = 0, max = 10, step = 1, default = 7,
                            get = function() return 0 end,
                            set = function(v) resetValues.b = v end,
                        },
                    },
                },
            }))
            mock:SlashCommand("TESTADDON", "reset")
            assert.equals(true, resetValues.a)
            assert.equals(7, resetValues.b)
        end)

        it("skips value nodes with nil default on reset", function()
            local seen = 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "a",  -- no default
                            get = function() return true end,
                            set = function(_v) seen = seen + 1 end,
                        },
                    },
                },
            }))
            mock:SlashCommand("TESTADDON", "reset")
            assert.equals(0, seen)
        end)

        it("does NOT recurse into nested groups on reset (top-level only)", function()
            local outerSeen, innerSeen = 0, 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "outer", default = true,
                            get = function() return false end,
                            set = function(_v) outerSeen = outerSeen + 1 end,
                        },
                        {
                            type = "group", label = "nested",
                            children = {
                                {
                                    type = "toggle", label = "inner", default = true,
                                    get = function() return false end,
                                    set = function(_v) innerSeen = innerSeen + 1 end,
                                },
                            },
                        },
                    },
                },
            }))
            mock:SlashCommand("TESTADDON", "reset")
            assert.equals(1, outerSeen)
            assert.equals(0, innerSeen)
        end)

        it("prints a help message for an unknown verb", function()
            local printed
            _G.print = function(s) printed = s end
            local addon = wow_mock.fakeAddon()
            Settings:Register(addon, makeSchema({ slashCommands = { "/dctest" } }))
            mock:SlashCommand("TESTADDON", "garblegarble")
            _G.print = nil
            assert.is_string(printed)
            assert.is_truthy(printed:find("garblegarble", 1, true))
        end)

        it("does not wire slash commands when none are declared", function()
            -- SLASH_<NAME>N globals are not wiped by reset_globals (the
            -- name is dynamic), so clear them locally before asserting.
            _G["SLASH_TESTADDON1"] = nil
            _G["SLASH_TESTADDON2"] = nil
            Settings:Register(wow_mock.fakeAddon(), makeSchema())
            assert.is_nil(_G.SlashCmdList["TESTADDON"])
            assert.is_nil(_G["SLASH_TESTADDON1"])
        end)
    end)
end)
