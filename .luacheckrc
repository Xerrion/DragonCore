std = "lua51"
max_line_length = 120
codes = true
exclude_files = {
    "Libs/",
    ".release/",
    ".deliverables/",
}

ignore = {
    "212/self",
    "211/_.*",  -- unused variables prefixed with underscore
    "212/_.*",  -- unused arguments prefixed with underscore
    "213/_.*",  -- unused loop variables prefixed with underscore
}

read_globals = {
    -- Libraries
    "LibStub",

    -- WoW API (anticipated by other DragonCore modules)
    "CreateFrame", "C_Timer", "GetBuildInfo", "GetLocale",
    "C_RestrictedActions", "C_ChatInfo",

    -- WoW API - Player identity (Store discriminators)
    "UnitName", "GetRealmName", "UnitFactionGroup", "UnitClass", "UnitRace",

    -- WoW API - Settings panel (Renderer_Modern / Renderer_Legacy)
    "Settings", "InterfaceOptions_AddCategory",
    "InterfaceOptionsFrame_OpenToCategory", "SlashCmdList",

    -- WoW taint-isolation surface (SecureCall)
    "securecallfunction", "geterrorhandler",

    -- WoW Globals - Version detection
    "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE",
    "WOW_PROJECT_BURNING_CRUSADE_CLASSIC", "WOW_PROJECT_WRATH_CLASSIC",
    "WOW_PROJECT_CATACLYSM_CLASSIC", "WOW_PROJECT_MISTS_CLASSIC",
    "WOW_PROJECT_CLASSIC",

    -- WoW Globals - Enums
    "Enum",
}

-----------------------------------------------------------------------
-- Tests
-----------------------------------------------------------------------
files["tests/"] = {
    read_globals = {
        -- Busted DSL
        "describe", "it", "before_each", "after_each", "setup", "teardown",
        "pending", "assert", "spy", "stub", "mock", "match",
        -- LibStub is loaded into the global namespace by the spec bootstrap.
        "LibStub",
    },
    globals = {
        -- strmatch shim so the vendored LibStub loads under stock Lua 5.1.
        "strmatch",
    },
}
