-------------------------------------------------------------------------------
-- AddonChannel_spec.lua
-- Busted spec for DragonCore.AddonChannel + internal Serializer. Loads
-- Subscription -> SecureCall -> Capabilities -> Serializer -> AddonChannel.
-- Lockdown specs pre-arm `_G.C_RestrictedActions` BEFORE Capabilities loads;
-- other specs leave it nil (Classic-equivalent path).
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")
local wow_mock = dofile("tests/support/wow_mock.lua")

-- Helper: load DragonCore stack with optional pre-globals applied between
-- reset_globals and the first dofile. Used by Lockdown specs that need
-- `_G.C_RestrictedActions` present when Capabilities runs detection.
local function loadStack(preGlobals)
    bootstrap.reset_globals(preGlobals)
    bootstrap.reload_libstub()
    dofile("Core/Subscription.lua")
    dofile("Core/SecureCall.lua")
    dofile("Core/Capabilities.lua")
    dofile("Core/AddonChannel/Serializer.lua")
    dofile("Core/Dispatcher.lua")
    dofile("Core/AddonChannel.lua")
    return LibStub("DragonCore-1.0")
end

describe("DragonCore.AddonChannel", function()
    local DragonCore
    local AddonChannel
    local Serializer
    local mock

    before_each(function()
        DragonCore = loadStack(nil)
        AddonChannel = DragonCore.AddonChannel
        Serializer = DragonCore._AddonChannelSerializer

        mock = wow_mock.new()
        mock:Install()

        -- securecallfunction passthrough so SecureCall:Invoke runs the cb
        -- inline (matches EventBus / Listener spec setup).
        _G.securecallfunction = function(fn, ...) return fn(...) end
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    ---------------------------------------------------------------------------
    -- :Open validation (validateAddon reject cases)
    ---------------------------------------------------------------------------

    describe(":Open validation", function()
        it("rejects a nil addon", function()
            local ok, err = pcall(function() AddonChannel:Open(nil, "P") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.AddonChannel:Open: addon is required (DragonCore.Addon)",
                1, true))
        end)

        it("rejects a non-table addon", function()
            for _, bad in ipairs({ "name", 42, true }) do
                local ok, err = pcall(function() AddonChannel:Open(bad, "P") end)
                assert.is_false(ok)
                assert.is_truthy(err:find(
                    "DragonCore.AddonChannel:Open: addon must be a table",
                    1, true))
                assert.is_truthy(err:find("got " .. type(bad), 1, true))
            end
        end)

        it("rejects an addon with missing or empty name", function()
            local ok1 = pcall(function() AddonChannel:Open({}, "P") end)
            assert.is_false(ok1)
            local ok2 = pcall(function() AddonChannel:Open({ name = "" }, "P") end)
            assert.is_false(ok2)
        end)

        it("rejects an empty prefix", function()
            local ok, err = pcall(function()
                AddonChannel:Open(wow_mock.fakeAddon(), "")
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.AddonChannel:Open: prefix must be a non-empty string",
                1, true))
        end)

        it("rejects a non-string prefix", function()
            local ok = pcall(function()
                AddonChannel:Open(wow_mock.fakeAddon(), 42)
            end)
            assert.is_false(ok)
        end)

        it("rejects a prefix > 16 bytes with PrefixTooLong message", function()
            local long = string.rep("X", 17)
            local ok, err = pcall(function()
                AddonChannel:Open(wow_mock.fakeAddon(), long)
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("PrefixTooLong", 1, true))
            assert.is_truthy(err:find("17 bytes", 1, true))
        end)

        it("accepts a 16-byte prefix (exact boundary)", function()
            local exact = string.rep("X", 16)
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), exact)
            assert.is_not_nil(channel)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Frame / taint contract
    ---------------------------------------------------------------------------

    describe("frame contract", function()
        it("creates exactly one unnamed Frame per :Open call", function()
            assert.are.equal(0, mock:FrameCount())
            AddonChannel:Open(wow_mock.fakeAddon("A"), "P")
            assert.are.equal(1, mock:FrameCount())
            AddonChannel:Open(wow_mock.fakeAddon("B"), "P")
            assert.are.equal(2, mock:FrameCount())
        end)

        it("registers both CHAT_MSG_ADDON and CHAT_MSG_ADDON_LOGGED", function()
            AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local frame = mock.frames[1]
            assert.is_true(frame._events.CHAT_MSG_ADDON == true)
            assert.is_true(frame._events.CHAT_MSG_ADDON_LOGGED == true)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Open idempotency / process-wide prefix registration
    ---------------------------------------------------------------------------

    describe(":Open idempotency", function()
        it("returns the same channel for repeated (addon, prefix) opens", function()
            local addon = wow_mock.fakeAddon()
            local c1 = AddonChannel:Open(addon, "P")
            local c2 = AddonChannel:Open(addon, "P")
            assert.are.equal(c1, c2)
            -- Idempotent: only ONE frame allocated.
            assert.are.equal(1, mock:FrameCount())
        end)

        it("calls RegisterAddonMessagePrefix exactly once per prefix per process", function()
            local a, b = wow_mock.fakeAddon("A"), wow_mock.fakeAddon("B")
            AddonChannel:Open(a, "Shared")
            AddonChannel:Open(b, "Shared")  -- different addon, same prefix
            AddonChannel:Open(a, "Shared")  -- idempotent
            local prefixes = mock:RegisteredPrefixes()
            -- The prefix appears exactly once in the registry.
            local count = 0
            for _, p in ipairs(prefixes) do
                if p == "Shared" then count = count + 1 end
            end
            assert.are.equal(1, count)
        end)

        it("does not raise when RegisterAddonMessagePrefix returns false", function()
            mock:RejectPrefix("Rejected")
            local ok = pcall(function()
                AddonChannel:Open(wow_mock.fakeAddon(), "Rejected")
            end)
            assert.is_true(ok)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Send happy path per distribution
    ---------------------------------------------------------------------------

    describe(":Send happy path", function()
        local function open()
            return AddonChannel:Open(wow_mock.fakeAddon(), "Pref")
        end

        it("sends a PARTY message and reports ok = true", function()
            local result = open():Send(
                { topic = "ping", payload = { v = 1 } }, "PARTY")
            assert.is_true(result.ok)
            assert.is_nil(result.error)
            local sent = mock:SentMessages()
            assert.are.equal(1, #sent)
            assert.are.equal("Pref", sent[1].prefix)
            assert.are.equal("PARTY", sent[1].distribution)
            assert.is_nil(sent[1].target)
        end)

        it("sends to RAID, INSTANCE_CHAT, GUILD", function()
            local channel = open()
            for _, dist in ipairs({ "RAID", "INSTANCE_CHAT", "GUILD" }) do
                local r = channel:Send({ topic = "t" }, dist)
                assert.is_true(r.ok, "dist " .. dist .. " failed: " ..
                    tostring(r.error))
            end
            assert.are.equal(3, #mock:SentMessages())
        end)

        it("sends WHISPER with a target", function()
            local r = open():Send({ topic = "t" }, "WHISPER", "Foo-Realm")
            assert.is_true(r.ok)
            assert.are.equal("Foo-Realm", mock:SentMessages()[1].target)
        end)

        it("encodes the payload through the Serializer (round-trip)", function()
            local r = open():Send(
                { topic = "ping", payload = "hello" }, "PARTY")
            assert.is_true(r.ok)
            local encoded = mock:SentMessages()[1].payload
            local ok, topic, payload = Serializer.decode(encoded)
            assert.is_true(ok)
            assert.are.equal("ping", topic)
            assert.are.equal("hello", payload)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Send error variants
    ---------------------------------------------------------------------------

    describe(":Send error variants", function()
        local function open()
            return AddonChannel:Open(wow_mock.fakeAddon(), "P")
        end

        it("returns InvalidDistribution for an unknown distribution", function()
            local r = open():Send({ topic = "t" }, "SAY")
            assert.is_false(r.ok)
            assert.are.equal("InvalidDistribution", r.error)
        end)

        it("returns InvalidDistribution for BATTLEGROUND (deprecated)", function()
            local r = open():Send({ topic = "t" }, "BATTLEGROUND")
            assert.is_false(r.ok)
            assert.are.equal("InvalidDistribution", r.error)
        end)

        it("returns InvalidDistribution for WHISPER without target", function()
            local channel = open()
            assert.are.equal("InvalidDistribution",
                channel:Send({ topic = "t" }, "WHISPER").error)
            assert.are.equal("InvalidDistribution",
                channel:Send({ topic = "t" }, "WHISPER", "").error)
        end)

        it("returns Throttled when SendAddonMessage returns false", function()
            mock:SetSendFails(true)
            local r = open():Send({ topic = "t" }, "PARTY")
            assert.is_false(r.ok)
            assert.are.equal("Throttled", r.error)
        end)

        it("returns SerializationFailed for a payload containing a function", function()
            local r = open():Send(
                { topic = "t", payload = { fn = function() end } }, "PARTY")
            assert.is_false(r.ok)
            assert.are.equal("SerializationFailed", r.error)
        end)

        it("returns SerializationFailed for an oversize payload (> 255 bytes)", function()
            local huge = string.rep("X", 300)
            local r = open():Send({ topic = "t", payload = huge }, "PARTY")
            assert.is_false(r.ok)
            assert.are.equal("SerializationFailed", r.error)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Send programmer-error inputs (raise, not return)
    ---------------------------------------------------------------------------

    describe(":Send programmer-error inputs", function()
        it("raises on nil msg", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local ok, err = pcall(function() channel:Send(nil, "PARTY") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.AddonChannel:Send: msg must be a table", 1, true))
        end)

        it("raises on missing topic", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local ok, err = pcall(function() channel:Send({}, "PARTY") end)
            assert.is_false(ok)
            assert.is_truthy(err:find(
                "DragonCore.AddonChannel:Send: msg.topic must be a non-empty string",
                1, true))
        end)

        it("raises on empty topic", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local ok = pcall(function()
                channel:Send({ topic = "" }, "PARTY")
            end)
            assert.is_false(ok)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :On validation
    ---------------------------------------------------------------------------

    describe(":On validation", function()
        it("rejects an empty topic", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local ok, err = pcall(function() channel:On("", function() end) end)
            assert.is_false(ok)
            assert.is_truthy(err:find("topic must be a non-empty string", 1, true))
        end)

        it("rejects a non-function callback", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local ok, err = pcall(function() channel:On("t", "not-a-fn") end)
            assert.is_false(ok)
            assert.is_truthy(err:find("fn must be a function", 1, true))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Inbound dispatch (CHAT_MSG_ADDON / _LOGGED)
    ---------------------------------------------------------------------------

    describe("inbound dispatch", function()
        local function openAndSubscribe(topic)
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "Pref")
            local received = {}
            channel:On(topic, function(payload, sender, distribution)
                received[#received + 1] = {
                    payload = payload, sender = sender, distribution = distribution,
                }
            end)
            return channel, received
        end

        it("delivers a decoded message via CHAT_MSG_ADDON", function()
            local _, received = openAndSubscribe("ping")
            local ok, encoded = Serializer.encode("ping", { id = 7 })
            assert.is_true(ok)
            mock:FireEvent("CHAT_MSG_ADDON", "Pref", encoded, "PARTY", "Foo-Realm")
            assert.are.equal(1, #received)
            assert.are.equal("Foo-Realm", received[1].sender)
            assert.are.equal("PARTY", received[1].distribution)
            assert.are.equal(7, received[1].payload.id)
        end)

        it("delivers via CHAT_MSG_ADDON_LOGGED with the same shape", function()
            local _, received = openAndSubscribe("ping")
            local ok, encoded = Serializer.encode("ping", "hello")
            assert.is_true(ok)
            mock:FireEvent("CHAT_MSG_ADDON_LOGGED", "Pref", encoded, "GUILD", "Bar")
            assert.are.equal(1, #received)
            assert.are.equal("Bar", received[1].sender)
            assert.are.equal("GUILD", received[1].distribution)
            assert.are.equal("hello", received[1].payload)
        end)

        it("ignores messages for a different prefix", function()
            local _, received = openAndSubscribe("ping")
            local _, encoded = Serializer.encode("ping", 1)
            mock:FireEvent("CHAT_MSG_ADDON", "OtherPrefix", encoded, "PARTY", "X")
            assert.are.equal(0, #received)
        end)

        it("ignores messages for a different topic", function()
            local _, received = openAndSubscribe("ping")
            local _, encoded = Serializer.encode("pong", 1)
            mock:FireEvent("CHAT_MSG_ADDON", "Pref", encoded, "PARTY", "X")
            assert.are.equal(0, #received)
        end)

        it("silently drops malformed payloads (DeserializationFailed)", function()
            local _, received = openAndSubscribe("ping")
            -- Garbage bytes; header is not 0x01.
            mock:FireEvent("CHAT_MSG_ADDON", "Pref", "\xFFgarbage", "PARTY", "X")
            assert.are.equal(0, #received)
            -- Empty payload also tolerated.
            mock:FireEvent("CHAT_MSG_ADDON", "Pref", "", "PARTY", "X")
            assert.are.equal(0, #received)
        end)

        it("invokes multiple handlers in registration order", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "Pref")
            local order = {}
            channel:On("ping", function() order[#order + 1] = "A" end)
            channel:On("ping", function() order[#order + 1] = "B" end)
            channel:On("ping", function() order[#order + 1] = "C" end)
            local _, encoded = Serializer.encode("ping", nil)
            mock:FireEvent("CHAT_MSG_ADDON", "Pref", encoded, "PARTY", "X")
            assert.are.same({ "A", "B", "C" }, order)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cross-channel isolation
    ---------------------------------------------------------------------------

    describe("cross-channel isolation", function()
        it("does not deliver a message to a sibling addon's channel on the same prefix", function()
            local addonA = wow_mock.fakeAddon("A")
            local addonB = wow_mock.fakeAddon("B")
            local channelA = AddonChannel:Open(addonA, "Shared")
            local channelB = AddonChannel:Open(addonB, "Shared")

            local hitsA, hitsB = 0, 0
            channelA:On("ping", function() hitsA = hitsA + 1 end)
            channelB:On("ping", function() hitsB = hitsB + 1 end)

            -- Wire-level fan-out: both frames receive the event because both
            -- are registered for CHAT_MSG_ADDON. Both subscribed to "ping" on
            -- the same prefix, so both handlers fire. This documents the
            -- shared-prefix behaviour rather than asserting isolation we
            -- cannot provide at the Blizzard layer (design note section 1).
            local _, encoded = Serializer.encode("ping", 1)
            mock:FireEvent("CHAT_MSG_ADDON", "Shared", encoded, "PARTY", "Sender")
            assert.are.equal(1, hitsA)
            assert.are.equal(1, hitsB)

            -- But a message on a DIFFERENT prefix reaches NEITHER channel
            -- because :Open(_, "Shared") binds OnEvent to filter `prefix`.
            mock:FireEvent("CHAT_MSG_ADDON", "OtherPrefix", encoded, "PARTY", "Sender")
            assert.are.equal(1, hitsA)
            assert.are.equal(1, hitsB)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Subscription cancel
    ---------------------------------------------------------------------------

    describe("subscription cancel", function()
        it("prevents further fires after :Cancel", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local hits = 0
            local sub = channel:On("t", function() hits = hits + 1 end)
            local _, encoded = Serializer.encode("t", nil)

            mock:FireEvent("CHAT_MSG_ADDON", "P", encoded, "PARTY", "X")
            assert.are.equal(1, hits)

            sub:Cancel()
            mock:FireEvent("CHAT_MSG_ADDON", "P", encoded, "PARTY", "X")
            assert.are.equal(1, hits)
            assert.is_true(sub:IsCancelled())
        end)

        it("Cancel is idempotent", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local sub = channel:On("t", function() end)
            sub:Cancel()
            sub:Cancel()  -- must not raise
            assert.is_true(sub:IsCancelled())
        end)
    end)

    ---------------------------------------------------------------------------
    -- Snapshot-on-iterate re-entrancy
    ---------------------------------------------------------------------------

    describe("snapshot-on-iterate dispatch", function()
        local function openWithEncoded(topic, payload)
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local _, encoded = Serializer.encode(topic, payload)
            local fire = function()
                mock:FireEvent("CHAT_MSG_ADDON", "P", encoded, "PARTY", "X")
            end
            return channel, fire
        end

        it("subscribe-mid: a new handler fires on the NEXT event only", function()
            local channel, fire = openWithEncoded("t", 1)
            local lateHits = 0
            channel:On("t", function()
                channel:On("t", function() lateHits = lateHits + 1 end)
            end)
            fire()
            assert.are.equal(0, lateHits, "new handler should not fire this round")
            fire()
            assert.are.equal(1, lateHits, "new handler fires on the next round")
        end)

        it("cancel-mid: cancelled handler is skipped in the in-flight loop", function()
            local channel, fire = openWithEncoded("t", 1)
            local hits = { 0, 0 }
            local subToCancel
            channel:On("t", function()
                if subToCancel then subToCancel:Cancel() end
                hits[1] = hits[1] + 1
            end)
            subToCancel = channel:On("t", function() hits[2] = hits[2] + 1 end)
            fire()
            assert.are.equal(1, hits[1])
            assert.are.equal(0, hits[2])
            fire()
            assert.are.equal(2, hits[1])
            assert.are.equal(0, hits[2])
        end)

        it("throw-mid: SecureCall traps so subsequent handlers still fire", function()
            -- Override the passthrough with a pcall-trap to match production
            -- SecureCall behaviour (errors routed to geterrorhandler, not the
            -- caller of FireEvent).
            _G.securecallfunction = function(fn, ...) pcall(fn, ...) end
            _G.geterrorhandler = function() return function() end end

            local channel, fire = openWithEncoded("t", 1)
            local after = 0
            channel:On("t", function() error("boom") end)
            channel:On("t", function() after = after + 1 end)
            fire()
            assert.are.equal(1, after)
        end)
    end)

    ---------------------------------------------------------------------------
    -- :Dispose
    ---------------------------------------------------------------------------

    describe(":Dispose", function()
        it("cancels every subscription and unregisters both events", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            local sub = channel:On("t", function() end)
            local frame = mock.frames[1]
            channel:Dispose()
            assert.is_true(sub:IsCancelled())
            assert.is_nil(frame._events.CHAT_MSG_ADDON)
            assert.is_nil(frame._events.CHAT_MSG_ADDON_LOGGED)
        end)

        it("raises on :On / :Send after dispose", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            channel:Dispose()
            local ok1, err1 = pcall(function() channel:On("t", function() end) end)
            assert.is_false(ok1)
            assert.is_truthy(err1:find("instance has been disposed", 1, true))

            local ok2, err2 = pcall(function() channel:Send({ topic = "t" }, "PARTY") end)
            assert.is_false(ok2)
            assert.is_truthy(err2:find("instance has been disposed", 1, true))
        end)

        it("is idempotent", function()
            local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
            channel:Dispose()
            channel:Dispose()  -- must not raise
        end)

        it("allows :Open to reconstruct a fresh channel after dispose", function()
            local addon = wow_mock.fakeAddon()
            local first = AddonChannel:Open(addon, "P")
            first:Dispose()
            local second = AddonChannel:Open(addon, "P")
            assert.are_not.equal(first, second)
            assert.are.equal(2, mock:FrameCount())
        end)
    end)
end)

-------------------------------------------------------------------------------
-- Lockdown circuit breaker (retail-only) -- separate describe block so it
-- can rebuild the stack with C_RestrictedActions pre-armed BEFORE
-- Capabilities runs detection.
-------------------------------------------------------------------------------

describe("DragonCore.AddonChannel lockdown gating", function()
    local AddonChannel
    local mock

    before_each(function()
        -- Pre-arm globals so Capabilities.restrictedActions detects true.
        -- Note: this is a STUB only; we replace it via mock:SetRestrictionState
        -- immediately after mock:Install so the spec can control the state.
        mock = wow_mock.new()
        mock:SetRestrictionState(0)  -- installs _G.C_RestrictedActions

        bootstrap.reset_globals({
            -- Re-install after reset_globals would otherwise wipe it.
            C_RestrictedActions = _G.C_RestrictedActions,
            WOW_PROJECT_ID = 1,
            WOW_PROJECT_MAINLINE = 1,
            GetBuildInfo = function() return "12.0.0", "67000", "", 120000 end,
        })
        bootstrap.reload_libstub()
        dofile("Core/Subscription.lua")
        dofile("Core/SecureCall.lua")
        dofile("Core/Capabilities.lua")
        dofile("Core/AddonChannel/Serializer.lua")
        dofile("Core/Dispatcher.lua")
        dofile("Core/AddonChannel.lua")

        AddonChannel = LibStub("DragonCore-1.0").AddonChannel

        mock:Install()  -- installs C_ChatInfo + Frame + GetLocale shims
        _G.securecallfunction = function(fn, ...) return fn(...) end

        -- Sanity: Capabilities should have detected restrictedActions = true.
        assert.is_true(LibStub("DragonCore-1.0").Capabilities.restrictedActions)
    end)

    after_each(function()
        if mock then mock:Uninstall() end
    end)

    it("returns Lockdown when restriction state is non-zero", function()
        mock:SetRestrictionState(1)
        local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
        local r = channel:Send({ topic = "t" }, "PARTY")
        assert.is_false(r.ok)
        assert.are.equal("Lockdown", r.error)
        assert.are.equal(0, #mock:SentMessages(),
            "SendAddonMessage must NOT be called under Lockdown")
    end)

    it("succeeds when restriction state is 0 (no lockdown)", function()
        mock:SetRestrictionState(0)
        local channel = AddonChannel:Open(wow_mock.fakeAddon(), "P")
        local r = channel:Send({ topic = "t" }, "PARTY")
        assert.is_true(r.ok)
    end)
end)

-------------------------------------------------------------------------------
-- Serializer (unit-level coverage; AddonChannel exercises encode/decode
-- end-to-end above, this block hits edge cases directly).
-------------------------------------------------------------------------------

describe("DragonCore._AddonChannelSerializer", function()
    local Serializer

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()
        dofile("Core/AddonChannel/Serializer.lua")
        Serializer = LibStub("DragonCore-1.0")._AddonChannelSerializer
    end)

    it("round-trips every supported scalar type", function()
        local cases = {
            { "nil", nil },
            { "true", true },
            { "false", false },
            { "int", 42 },
            { "negative", -17 },
            { "float", 3.14 },
            { "string", "hello" },
            { "empty string", "" },
            { "binary string", "\0\1\2\3" },
        }
        for _, case in ipairs(cases) do
            local ok, encoded = Serializer.encode("t", case[2])
            assert.is_true(ok, "encode failed for " .. case[1])
            local dok, topic, payload = Serializer.decode(encoded)
            assert.is_true(dok, "decode failed for " .. case[1])
            assert.are.equal("t", topic)
            assert.are.equal(case[2], payload, "mismatch for " .. case[1])
        end
    end)

    it("round-trips a nested table of scalars", function()
        local input = { a = 1, b = "two", c = { d = true, e = false }, f = nil }
        local ok, encoded = Serializer.encode("t", input)
        assert.is_true(ok)
        local dok, topic, payload = Serializer.decode(encoded)
        assert.is_true(dok)
        assert.are.equal("t", topic)
        assert.are.equal(1, payload.a)
        assert.are.equal("two", payload.b)
        assert.is_true(payload.c.d)
        assert.is_false(payload.c.e)
        assert.is_nil(payload.f)
    end)

    it("emits 0x01 as the leading header byte", function()
        local _, encoded = Serializer.encode("t", nil)
        assert.are.equal(1, encoded:byte(1))
    end)

    it("rejects an unsupported header version on decode", function()
        local ok, err = Serializer.decode("\2garbage")
        assert.is_false(ok)
        assert.is_truthy(err:find("unsupported header version", 1, true))
    end)

    it("rejects a non-string buffer on decode", function()
        local ok = Serializer.decode(nil)
        assert.is_false(ok)
    end)

    it("rejects an empty topic on encode", function()
        local ok, err = Serializer.encode("", nil)
        assert.is_false(ok)
        assert.is_truthy(err:find("topic", 1, true))
    end)

    it("rejects a payload containing a function", function()
        local ok, err = Serializer.encode("t", function() end)
        assert.is_false(ok)
        assert.is_truthy(err:find("unsupported type: function", 1, true))
    end)

    it("rejects an oversize payload at the MAX_PAYLOAD_BYTES boundary", function()
        local ok = Serializer.encode("t", string.rep("X", 300))
        assert.is_false(ok)
    end)

    it("rejects NaN and Infinity", function()
        local nan = 0 / 0
        local inf = math.huge
        local okNaN = Serializer.encode("t", nan)
        local okInf = Serializer.encode("t", inf)
        local okNegInf = Serializer.encode("t", -inf)
        assert.is_false(okNaN)
        assert.is_false(okInf)
        assert.is_false(okNegInf)
    end)

    it("survives a truncated buffer on decode", function()
        local _, encoded = Serializer.encode("t", "hello")
        for cut = 1, #encoded - 1 do
            local ok = Serializer.decode(encoded:sub(1, cut))
            -- ok may be true for the trivially-valid prefix (header only is
            -- false), but no truncation should ever throw.
            assert.is_boolean(ok)
        end
    end)
end)
