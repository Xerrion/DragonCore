-------------------------------------------------------------------------------
-- Settings_spec.lua
-- Busted spec for DragonCore.Settings. Exercises the single Modern renderer
-- (ADR-0002 collapsed the two-renderer model). Load order (design note
-- section 2): Subscription -> SecureCall -> Capabilities -> Locale ->
-- Renderer_Modern -> Settings, then Locales/enUS.lua so the chrome strings
-- are registered against the synthetic { name = "DragonCore" } addon.
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

    -- Nil the modern Settings API and re-detect Capabilities so the
    -- caps.settingsAPI flag flips false; the next :Register call must
    -- fast-error at the precondition gate (ADR-0002). Re-running
    -- Capabilities.lua reassigns DragonCore.Capabilities to a fresh frozen
    -- table; Settings.lua reads it lazily on every dispatch, so no Settings
    -- reload is required.
    local function useStubbedSettingsAPI()
        _G.Settings = nil
        dofile("Core/Capabilities.lua")
    end

    -- Install a Settings table where one of the three required functions
    -- raises when called. Exercises the renderer's pcall soft-failure path.
    -- Capabilities.settingsAPI must still report true (the symbols exist as
    -- functions); the throw happens when Blizzard-side code actually runs.
    local function installThrowingSettings(which)
        local function throwing() error("boom") end
        _G.Settings.RegisterCanvasLayoutCategory =
            which == "canvas" and throwing
            or _G.Settings.RegisterCanvasLayoutCategory
        _G.Settings.RegisterAddOnCategory =
            which == "addon" and throwing
            or _G.Settings.RegisterAddOnCategory
        -- RegisterVerticalLayoutCategory must remain a function so the
        -- capability probe stays true; the renderer never calls it.
    end

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        mock = wow_mock.new()
        mock:Install()  -- installs _G.Settings with the three modern functions

        -- Default environment: Mainline retail with the modern Settings API
        -- complete. RegisterVerticalLayoutCategory is the third function the
        -- capability probe requires; the mock omits it because production
        -- code never calls it, so we install a stub here. Set BEFORE
        -- Capabilities.lua dofile so the frozen caps.settingsAPI evaluates
        -- true.
        _G.WOW_PROJECT_ID = 1
        _G.WOW_PROJECT_MAINLINE = 1
        _G.GetBuildInfo = function()
            return "12.0.5", "60000", "Nov 13 2026", 120005
        end
        _G.Settings.RegisterVerticalLayoutCategory = function() end

        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Capabilities.lua")
        dofile("Core/Locale.lua")
        dofile("Core/Settings/Renderer_Modern.lua")
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

        it("raises when slashHandlers is not a table", function()
            local ok, err = pcall(function()
                Settings:Register(wow_mock.fakeAddon(), makeSchema({ slashHandlers = "bad" }))
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("slashHandlers must be a table", 1, true))
        end)

        it("raises when slashHandlers has a non-string key", function()
            local ok, err = pcall(function()
                Settings:Register(wow_mock.fakeAddon(), makeSchema({ slashHandlers = { [42] = function() end } }))
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("slashHandlers keys must be strings", 1, true))
        end)

        it("raises when slashHandlers value is not a function", function()
            local ok, err = pcall(function()
                Settings:Register(wow_mock.fakeAddon(), makeSchema({ slashHandlers = { toggle = "notafunc" } }))
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("must be a function", 1, true))
        end)

        it("raises when slashHandlers keys collide after case normalization", function()
            local ok, err = pcall(Settings.Register, Settings, wow_mock.fakeAddon(), makeSchema({
                slashHandlers = {
                    toggle = function() end,
                    Toggle = function() end,
                },
            }))
            assert.is_false(ok)
            assert.is_truthy(err:find("have the same key after case normalization", 1, true))
        end)

        it("raises when both colliding keys are non-lowercase", function()
            local ok, err = pcall(Settings.Register, Settings, wow_mock.fakeAddon(), makeSchema({
                slashHandlers = {
                    FOO = function() end,
                    fOO = function() end,
                },
            }))
            assert.is_false(ok)
            assert.is_truthy(err:find("have the same key after case normalization", 1, true))
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
        it("returns { ok = true } and registers via the modern Settings API", function()
            local result = Settings:Register(wow_mock.fakeAddon(), makeSchema())
            assert.is_true(result.ok)
            local cats = mock:RegisteredCategories()
            -- Modern path is two calls in order: wrap the renderer-owned
            -- Frame as a canvas category, then install that category under
            -- the AddOns group. RegisterAddOnCategory is single-argument
            -- (the category object from the previous call), so its recorded
            -- `name` is nil and its `panel` is the prior call's category.
            -- See Renderer_Modern.lua + ADR-0003 ("Handle shape").
            assert.equals(2, #cats)
            assert.equals("Settings.RegisterCanvasLayoutCategory", cats[1].api)
            assert.equals("TestAddon Settings", cats[1].name)
            assert.equals("Settings.RegisterAddOnCategory", cats[2].api)
            assert.equals(cats[1].category, cats[2].panel)
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

        it("does NOT invoke get for ADR-0003 placeholder node types", function()
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
    -- :Register precondition (ADR-0002): when Capabilities.settingsAPI is
    -- false the call must fast-error at our boundary rather than fall
    -- through to a deleted legacy renderer.
    ---------------------------------------------------------------------------

    describe(":Register precondition (caps.settingsAPI = false)", function()
        before_each(function()
            useStubbedSettingsAPI()
        end)

        it("raises with the precondition error message when _G.Settings is nil",
            function()
                local ok, err = pcall(function()
                    Settings:Register(wow_mock.fakeAddon(), makeSchema())
                end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "this client does not expose the modern Settings API",
                    1, true))
            end)

        it("does not register the addon when the precondition fails", function()
            local addon = wow_mock.fakeAddon()
            pcall(function() Settings:Register(addon, makeSchema()) end)
            local opened = pcall(function() Settings:Open(addon) end)
            assert.is_false(opened)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Renderer soft-failure (ADR-0002 Risk Mitigation): even when the
    -- capability probe is true, the renderer wraps Settings.* in pcall so
    -- a partial-stub Classic flavor where Blizzard's side throws degrades
    -- to a soft failure rather than crashing the addon.
    ---------------------------------------------------------------------------

    describe(":Register soft-failure (renderer pcall)", function()
        it("marks the entry failed when RegisterCanvasLayoutCategory throws",
            function()
                installThrowingSettings("canvas")
                local printed
                _G.print = function(s) printed = s end
                local result = Settings:Register(wow_mock.fakeAddon(), makeSchema())
                _G.print = nil
                -- :Register returns ok = true: the addon survives, just
                -- without a panel. The warning is the user-visible signal.
                assert.is_true(result.ok)
                assert.is_string(printed)
                assert.is_truthy(printed:find("DragonCore", 1, true))
                assert.is_truthy(printed:find("Slash commands remain available", 1, true))
            end)

        it("marks the entry failed when RegisterAddOnCategory throws", function()
            installThrowingSettings("addon")
            local printed
            _G.print = function(s) printed = s end
            local result = Settings:Register(wow_mock.fakeAddon(), makeSchema())
            _G.print = nil
            assert.is_true(result.ok)
            assert.is_string(printed)
            assert.is_truthy(printed:find("Slash commands remain available", 1, true))
        end)

        it(":Open is a no-op for a failed entry (no panel to open)", function()
            installThrowingSettings("canvas")
            local addon = wow_mock.fakeAddon()
            _G.print = function() end
            Settings:Register(addon, makeSchema())
            mock:ClearOpenedCategory()
            local opened
            _G.print = function(s) opened = s end
            -- Must NOT raise; must NOT call Settings.OpenToCategory.
            assert.has_no_errors(function() Settings:Open(addon) end)
            _G.print = nil
            assert.is_nil(mock:OpenedCategory())
            assert.is_string(opened)
            assert.is_truthy(opened:find("unavailable", 1, true))
        end)

        it(":Refresh returns ok = true and warns for a failed entry", function()
            installThrowingSettings("canvas")
            local addon = wow_mock.fakeAddon()
            _G.print = function() end
            Settings:Register(addon, makeSchema())
            local warned
            _G.print = function(s) warned = s end
            local result = Settings:Refresh(addon)
            _G.print = nil
            assert.is_true(result.ok)
            assert.is_string(warned)
            assert.is_truthy(warned:find("unavailable", 1, true))
        end)

        it("keeps slash commands wired through soft-failure", function()
            installThrowingSettings("canvas")
            _G.print = function() end
            Settings:Register(wow_mock.fakeAddon(),
                makeSchema({ slashCommands = { "/dctest" } }))
            _G.print = nil
            assert.equals("/dctest", _G["SLASH_TESTADDON1"])
            assert.is_function(_G.SlashCmdList["TESTADDON"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Register re-call -> Refresh (ADR-0003 re-register-as-refresh)
    ---------------------------------------------------------------------------

    describe(":Register re-call (ADR-0003)", function()
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

        it("does not call Settings.OpenToCategory when the entry is failed",
            function()
                installThrowingSettings("canvas")
                local addon = wow_mock.fakeAddon()
                _G.print = function() end
                Settings:Register(addon, makeSchema())
                mock:ClearOpenedCategory()
                _G.print = function() end
                Settings:Open(addon)
                _G.print = nil
                assert.is_nil(mock:OpenedCategory())
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

        it("calls a custom slashHandler for a matching verb", function()
            local called = false
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = {
                    toggle = function() called = true end,
                },
            }))
            mock:SlashCommand("TESTADDON", "toggle")
            assert.is_true(called)
        end)

        it("passes addon, msg, and verb to the custom handler", function()
            local captured = {}
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = {
                    toggle = function(addon, msg, verb)
                        captured.addon = addon
                        captured.msg = msg
                        captured.verb = verb
                    end,
                },
            }))
            mock:SlashCommand("TESTADDON", "toggle on")
            assert.equals("TestAddon", captured.addon.name)
            assert.equals("toggle on", captured.msg)
            assert.equals("toggle", captured.verb)
        end)

        it("built-in verbs still work when slashHandlers is present", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = {
                    toggle = function() end,
                },
            }))
            mock:ClearOpenedCategory()
            mock:SlashCommand("TESTADDON", "open")
            assert.is_table(mock:OpenedCategory())

            local resetValue
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = {
                    toggle = function() end,
                },
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "a", default = true,
                            get = function() return false end,
                            set = function(v) resetValue = v end,
                        },
                    },
                },
            }))
            mock:SlashCommand("TESTADDON", "reset")
            assert.equals(true, resetValue)
        end)

        it("unknown verb still prints help when slashHandlers present", function()
            local printed
            _G.print = function(s) printed = s end
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = {
                    toggle = function() end,
                },
            }))
            mock:SlashCommand("TESTADDON", "garble")
            _G.print = nil
            assert.is_string(printed)
            assert.is_truthy(printed:find("garble", 1, true))
        end)

        it("works without slashHandlers in the schema", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
            }))
            mock:ClearOpenedCategory()
            mock:SlashCommand("TESTADDON", "open")
            assert.is_table(mock:OpenedCategory())
        end)

        it("resolves custom handlers case-insensitively after normalization", function()
            local called
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                slashCommands = { "/dctest" },
                slashHandlers = { Toggle = function() called = true end },
            }))
            mock:SlashCommand("TESTADDON", "toggle")
            assert.is_true(called)

            called = false
            mock:SlashCommand("TESTADDON", "TOGGLE")
            assert.is_true(called)
        end)
    end)

    ---------------------------------------------------------------------------
    -- v0 widget contract (ADR-0003, 2026-05-13-dragoncore-v0-widget-contract)
    --
    -- The renderer materialises five faithful types (group, header, toggle,
    -- slider, action) with real widgets, and four placeholder types
    -- (select, input, color, description) as a "[deferred: <type>]" label
    -- so consumers can ship full 9-type schemas before each deferred type
    -- lands its real widget.
    ---------------------------------------------------------------------------

    -- Helper: locate the renderer handle for `addon` so per-widget specs can
    -- reach into the nodes map. The handle is stored on the registry entry
    -- inside Settings.lua; we access it via the same closures Settings.lua
    -- uses. Because the registry is file-private we read through the public
    -- side-effects (mock:Frames(), the mock's FontString records) wherever
    -- possible, and only reach into the handle for re-pull assertions where
    -- there is no other observation channel.
    local function lastRegisteredHandle()
        -- The Modern renderer's handle is stashed on the panel as a
        -- closure-free reference: panel itself is not the handle, but
        -- Settings.lua keeps the handle in its registry. We reach it by
        -- re-invoking the renderer directly with a dedicated addon. For
        -- tests that need the handle, register through Settings:Register
        -- and then call this helper which queries the renderer module.
        return rawget(_G, "__lastDragonCoreHandle")
    end

    -- Internal renderer probe: returns the handle the modern renderer
    -- last produced. Implemented by spying on Renderer:Render via the
    -- DragonCore module attach point.
    local function installRenderSpy()
        local renderer = DragonCore._SettingsRendererModern
        local realRender = renderer.Render
        renderer.Render = function(self, addon, schema)
            local handle = realRender(self, addon, schema)
            _G.__lastDragonCoreHandle = handle
            return handle
        end
        return function()
            renderer.Render = realRender
            _G.__lastDragonCoreHandle = nil
        end
    end

    describe("panel sizing (first-OnShow SetAllPoints)", function()
        it("installs an OnShow script on the panel", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema())
            local cats = mock:RegisteredCategories()
            local panel = cats[1].panel
            assert.is_function(panel:GetScript("OnShow"))
        end)

        it("calls SetAllPoints on the panel parent the first time OnShow fires",
            function()
                Settings:Register(wow_mock.fakeAddon(), makeSchema())
                local panel = mock:RegisteredCategories()[1].panel
                local fakeParent = { _id = "Blizzard.Settings.ContentFrame" }
                panel._parent = fakeParent
                panel:GetScript("OnShow")(panel)
                assert.equals(fakeParent, panel._allPointsOf)
                assert.is_true(panel.__dragoncoreSized)
            end)

        it("does not re-call SetAllPoints on subsequent OnShow fires", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema())
            local panel = mock:RegisteredCategories()[1].panel
            panel._parent = { _id = "Parent1" }
            panel:GetScript("OnShow")(panel)
            local firstParent = panel._allPointsOf
            panel._parent = { _id = "Parent2" }
            panel:GetScript("OnShow")(panel)
            -- Sticky: the one-shot flag prevented a re-anchor against the
            -- new parent. SetAllPoints was called exactly once.
            assert.equals(firstParent, panel._allPointsOf)
        end)

        it("skips SetAllPoints when parent is still nil", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema())
            local panel = mock:RegisteredCategories()[1].panel
            panel._parent = nil
            panel:GetScript("OnShow")(panel)
            assert.is_nil(panel._allPointsOf)
            assert.is_nil(panel.__dragoncoreSized)
        end)
    end)

    describe("header widget", function()
        it("creates a FontString with the node label text", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = { { type = "header", label = "POC settings" } },
                },
            }))
            -- The header's container frame is the second Frame created
            -- (panel is first). Its FontString carries the label text.
            local headerFrame
            for f in mock:Frames() do
                if f._fontStrings[1]
                    and f._fontStrings[1]._text == "POC settings" then
                    headerFrame = f
                    break
                end
            end
            assert.is_table(headerFrame)
            assert.equals("POC settings", headerFrame._fontStrings[1]._text)
            assert.equals("GameFontNormalLarge", headerFrame._fontStrings[1]._font)
        end)

        it("anchors the first child to the panel TOPLEFT", function()
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = { { type = "header", label = "POC settings" } },
                },
            }))
            local panel = mock:RegisteredCategories()[1].panel
            local headerFrame
            for f in mock:Frames() do
                if f._fontStrings[1]
                    and f._fontStrings[1]._text == "POC settings" then
                    headerFrame = f
                    break
                end
            end
            local firstPoint = headerFrame._points[1]
            assert.equals("TOPLEFT", firstPoint.point)
            assert.equals(panel, firstPoint.relativeTo)
        end)
    end)

    describe("placeholder widgets", function()
        local function schemaWithPlaceholder(t)
            local node
            if t == "select" then
                node = {
                    type = "select", label = "S",
                    options = { a = "A" },
                    get = function() return "a" end,
                    set = function() end,
                }
            elseif t == "input" then
                node = {
                    type = "input", label = "I",
                    get = function() return "" end,
                    set = function() end,
                }
            elseif t == "color" then
                node = {
                    type = "color", label = "C",
                    get = function() return 1, 1, 1 end,
                    set = function() end,
                }
            else
                node = { type = "description", label = "D" }
            end
            return makeSchema({
                root = {
                    type = "group", label = "r",
                    children = { node },
                },
            })
        end

        for _, ptype in ipairs({ "select", "input", "color", "description" }) do
            it("renders a '[deferred: " .. ptype .. "]' FontString", function()
                Settings:Register(wow_mock.fakeAddon(), schemaWithPlaceholder(ptype))
                local found
                for f in mock:Frames() do
                    if f._fontStrings[1] then
                        local text = f._fontStrings[1]._text or ""
                        if text:find("[deferred: " .. ptype .. "]", 1, true) then
                            found = text
                        end
                    end
                end
                assert.is_string(found)
                assert.is_truthy(found:find(ptype, 1, true))
            end)
        end

        it("does NOT invoke get for placeholder types", function()
            local seen = 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "color", label = "c",
                            get = function() seen = seen + 1; return 1, 1, 1 end,
                            set = function() end,
                        },
                    },
                },
            }))
            assert.equals(0, seen)
        end)
    end)

    describe("toggle widget", function()
        local function toggleSchema(getFn, setFn)
            return makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "toggle", label = "Enable feature flag",
                            get = getFn,
                            set = setFn,
                        },
                    },
                },
            })
        end

        it("creates an unnamed CheckButton with the UICheckButtonTemplate", function()
            Settings:Register(wow_mock.fakeAddon(),
                toggleSchema(function() return true end, function() end))
            local cb
            for f in mock:Frames() do
                if f._frameType == "CheckButton" then cb = f end
            end
            assert.is_table(cb)
            assert.equals("UICheckButtonTemplate", cb._template)
        end)

        it("pulls the initial value via SecureCall and calls SetChecked", function()
            local getCalls = 0
            Settings:Register(wow_mock.fakeAddon(),
                toggleSchema(function() getCalls = getCalls + 1; return true end,
                             function() end))
            assert.equals(1, getCalls)
            local cb
            for f in mock:Frames() do
                if f._frameType == "CheckButton" then cb = f end
            end
            assert.is_true(cb:GetChecked())
        end)

        it("coerces non-boolean initial values to boolean for SetChecked",
            function()
                Settings:Register(wow_mock.fakeAddon(),
                    toggleSchema(function() return nil end, function() end))
                local cb
                for f in mock:Frames() do
                    if f._frameType == "CheckButton" then cb = f end
                end
                assert.is_false(cb:GetChecked())
            end)

        it("routes OnClick through SecureCall to node.set", function()
            local setValue
            Settings:Register(wow_mock.fakeAddon(),
                toggleSchema(function() return false end,
                             function(v) setValue = v end))
            local cb
            for f in mock:Frames() do
                if f._frameType == "CheckButton" then cb = f end
            end
            cb._checked = true  -- simulate user click flipping the state
            cb:GetScript("OnClick")(cb)
            assert.is_true(setValue)
        end)

        it("attaches a label FontString with the node label", function()
            Settings:Register(wow_mock.fakeAddon(),
                toggleSchema(function() return true end, function() end))
            local labelText
            for f in mock:Frames() do
                if f._frameType == "Frame" then
                    for _, fs in ipairs(f._fontStrings) do
                        if fs._text == "Enable feature flag" then
                            labelText = fs._text
                        end
                    end
                end
            end
            assert.equals("Enable feature flag", labelText)
        end)
    end)

    describe("slider widget", function()
        local function sliderSchema(getFn, setFn)
            return makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        {
                            type = "slider", label = "Login count",
                            min = 0, max = 100, step = 1,
                            get = getFn,
                            set = setFn,
                        },
                    },
                },
            })
        end

        it("creates an unnamed Slider with OptionsSliderTemplate (Path A)",
            function()
                Settings:Register(wow_mock.fakeAddon(),
                    sliderSchema(function() return 42 end, function() end))
                local slider
                for f in mock:Frames() do
                    if f._frameType == "Slider" then slider = f end
                end
                assert.is_table(slider)
                assert.equals("OptionsSliderTemplate", slider._template)
            end)

        it("sets min/max/step from node fields", function()
            Settings:Register(wow_mock.fakeAddon(),
                sliderSchema(function() return 0 end, function() end))
            local slider
            for f in mock:Frames() do
                if f._frameType == "Slider" then slider = f end
            end
            assert.equals(0, slider._minValue)
            assert.equals(100, slider._maxValue)
            assert.equals(1, slider._valueStep)
            assert.is_true(slider._obeyStepOnDrag)
        end)

        it("pulls the initial value through SecureCall and calls SetValue",
            function()
                local seen = 0
                Settings:Register(wow_mock.fakeAddon(),
                    sliderSchema(function() seen = seen + 1; return 42 end,
                                 function() end))
                assert.equals(1, seen)
                local slider
                for f in mock:Frames() do
                    if f._frameType == "Slider" then slider = f end
                end
                assert.equals(42, slider:GetValue())
            end)

        it("falls back to node.min when get returns a non-number", function()
            Settings:Register(wow_mock.fakeAddon(),
                sliderSchema(function() return nil end, function() end))
            local slider
            for f in mock:Frames() do
                if f._frameType == "Slider" then slider = f end
            end
            assert.equals(0, slider:GetValue())
        end)

        it("routes OnValueChanged through SecureCall to node.set", function()
            local setValue
            Settings:Register(wow_mock.fakeAddon(),
                sliderSchema(function() return 0 end,
                             function(v) setValue = v end))
            local slider
            for f in mock:Frames() do
                if f._frameType == "Slider" then slider = f end
            end
            slider:GetScript("OnValueChanged")(slider, 73)
            assert.equals(73, setValue)
        end)

        it("attaches a label FontString carrying node.label", function()
            Settings:Register(wow_mock.fakeAddon(),
                sliderSchema(function() return 0 end, function() end))
            local labelFound = false
            for f in mock:Frames() do
                for _, fs in ipairs(f._fontStrings) do
                    if fs._text == "Login count" then labelFound = true end
                end
            end
            assert.is_true(labelFound)
        end)
    end)

    describe("action widget", function()
        local function actionSchema(runFn)
            return makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        { type = "action", label = "Reset", run = runFn },
                    },
                },
            })
        end

        it("creates an unnamed Button with UIPanelButtonTemplate", function()
            Settings:Register(wow_mock.fakeAddon(), actionSchema(function() end))
            local btn
            for f in mock:Frames() do
                if f._frameType == "Button" then btn = f end
            end
            assert.is_table(btn)
            assert.equals("UIPanelButtonTemplate", btn._template)
        end)

        it("sets the button text from node.label", function()
            Settings:Register(wow_mock.fakeAddon(), actionSchema(function() end))
            local btn
            for f in mock:Frames() do
                if f._frameType == "Button" then btn = f end
            end
            assert.equals("Reset", btn._text)
        end)

        it("routes OnClick through SecureCall to node.run", function()
            local runCalls = 0
            Settings:Register(wow_mock.fakeAddon(),
                actionSchema(function() runCalls = runCalls + 1 end))
            local btn
            for f in mock:Frames() do
                if f._frameType == "Button" then btn = f end
            end
            btn:GetScript("OnClick")(btn)
            assert.equals(1, runCalls)
        end)
    end)

    describe(":Refresh re-pulls values in place (does not rebuild)", function()
        it("re-pulls toggle get and updates SetChecked on the same widget",
            function()
                local current = false
                local restore = installRenderSpy()
                local addon = wow_mock.fakeAddon()
                Settings:Register(addon, makeSchema({
                    root = {
                        type = "group", label = "r",
                        children = {
                            {
                                type = "toggle", label = "t",
                                get = function() return current end,
                                set = function(v) current = v end,
                            },
                        },
                    },
                }))
                local handle = lastRegisteredHandle()
                local toggleEntry
                for _, entry in pairs(handle.nodes) do
                    if entry.type == "toggle" then toggleEntry = entry end
                end
                local checkButton = toggleEntry.checkButton
                local framesBefore = mock:FrameCount()
                assert.is_false(checkButton:GetChecked())

                current = true
                Settings:Refresh(addon)

                assert.is_true(checkButton:GetChecked())
                -- No new frames were created during Refresh (no rebuild).
                assert.equals(framesBefore, mock:FrameCount())
                restore()
            end)

        it("re-pulls slider get and updates SetValue on the same widget",
            function()
                local current = 0
                local restore = installRenderSpy()
                local addon = wow_mock.fakeAddon()
                Settings:Register(addon, makeSchema({
                    root = {
                        type = "group", label = "r",
                        children = {
                            {
                                type = "slider", label = "s",
                                min = 0, max = 100, step = 1,
                                get = function() return current end,
                                set = function(v) current = v end,
                            },
                        },
                    },
                }))
                local handle = lastRegisteredHandle()
                local sliderEntry
                for _, entry in pairs(handle.nodes) do
                    if entry.type == "slider" then sliderEntry = entry end
                end
                local framesBefore = mock:FrameCount()
                assert.equals(0, sliderEntry.slider:GetValue())

                current = 64
                Settings:Refresh(addon)

                assert.equals(64, sliderEntry.slider:GetValue())
                assert.equals(framesBefore, mock:FrameCount())
                restore()
            end)

        it("is a no-op for action / header / placeholder entries", function()
            local restore = installRenderSpy()
            local actionRuns = 0
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "r",
                    children = {
                        { type = "header", label = "h" },
                        {
                            type = "action", label = "a",
                            run = function() actionRuns = actionRuns + 1 end,
                        },
                        {
                            type = "color", label = "c",
                            get = function() return 1, 1, 1 end,
                            set = function() end,
                        },
                    },
                },
            }))
            -- Action's run must NOT fire during Refresh.
            Settings:Refresh(wow_mock.fakeAddon())
            assert.equals(0, actionRuns)
            restore()
        end)
    end)

    describe("nodes map walk-order indexing", function()
        it("assigns a depth-first preorder index covering every node", function()
            local restore = installRenderSpy()
            Settings:Register(wow_mock.fakeAddon(), makeSchema({
                root = {
                    type = "group", label = "root",
                    children = {
                        { type = "header", label = "H" },
                        {
                            type = "toggle", label = "T",
                            get = function() return false end,
                            set = function() end,
                        },
                    },
                },
            }))
            local handle = lastRegisteredHandle()
            -- 1: root group, 2: header, 3: toggle.
            assert.equals("group", handle.nodes[1].type)
            assert.equals("header", handle.nodes[2].type)
            assert.equals("toggle", handle.nodes[3].type)
            restore()
        end)
    end)
end)

