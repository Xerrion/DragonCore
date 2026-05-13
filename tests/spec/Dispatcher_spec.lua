-------------------------------------------------------------------------------
-- Dispatcher_spec.lua
-- Busted spec for DragonCore.Dispatcher. Pure-function utility -- no
-- Subscription, no SecureCall, no Frame. Tests target the three-function
-- surface (NewDepthBag / Run / RequestSweep) directly with hand-built
-- entry lists.
-------------------------------------------------------------------------------

local bootstrap = dofile("tests/spec/bootstrap.lua")

describe("DragonCore.Dispatcher", function()
    local Dispatcher

    before_each(function()
        bootstrap.reset_globals(nil)
        bootstrap.reload_libstub()

        dofile("Core/Dispatcher.lua")

        Dispatcher = LibStub("DragonCore-1.0").Dispatcher
    end)

    describe("NewDepthBag", function()
        it("returns a fresh table with empty depth and sweepQueued sub-tables", function()
            local bag = Dispatcher.NewDepthBag()
            assert.is_table(bag)
            assert.is_table(bag.depth)
            assert.is_table(bag.sweepQueued)
            assert.is_nil(next(bag.depth))
            assert.is_nil(next(bag.sweepQueued))
        end)

        it("returns independent bags per call (no shared state)", function()
            local a = Dispatcher.NewDepthBag()
            local b = Dispatcher.NewDepthBag()
            a.depth.x = 1
            assert.is_nil(b.depth.x)
        end)
    end)

    describe("Run", function()
        it("invokes the closure for every non-cancelled entry in order", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = {
                { id = 1, cancelled = false },
                { id = 2, cancelled = false },
                { id = 3, cancelled = false },
            }
            local seen = {}
            Dispatcher.Run(bag, "k", entries, function(e)
                seen[#seen + 1] = e.id
            end, function() end)
            assert.are.same({ 1, 2, 3 }, seen)
        end)

        it("skips entries with `cancelled = true`", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = {
                { id = 1, cancelled = false },
                { id = 2, cancelled = true },
                { id = 3, cancelled = false },
            }
            local seen = {}
            Dispatcher.Run(bag, "k", entries, function(e)
                seen[#seen + 1] = e.id
            end, function() end)
            assert.are.same({ 1, 3 }, seen)
        end)

        it("returns the depth bag to a clean state when dispatch ends at depth 0", function()
            local bag = Dispatcher.NewDepthBag()
            Dispatcher.Run(bag, "k", {}, function() end, function() end)
            assert.is_nil(bag.depth.k)
            assert.is_nil(bag.sweepQueued.k)
        end)

        it("captures snapshot length at top of loop (entries appended mid-Run are NOT visible)", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = {
                { id = 1, cancelled = false },
                { id = 2, cancelled = false },
            }
            local seen = {}
            Dispatcher.Run(bag, "k", entries, function(e)
                seen[#seen + 1] = e.id
                -- Append a new entry mid-iteration; must NOT be visible this run.
                entries[#entries + 1] = { id = 99, cancelled = false }
            end, function() end)
            assert.are.same({ 1, 2 }, seen)
        end)

        it("supports re-entrant Run on the SAME key (depth tracks nested calls)", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = { { id = 1, cancelled = false } }
            local observedDepth
            local invocations = 0
            local function invoke(_e)
                invocations = invocations + 1
                if invocations == 1 then
                    observedDepth = bag.depth.k
                    -- Nested Run on the same key.
                    Dispatcher.Run(bag, "k", entries, function() end, function() end)
                end
            end
            Dispatcher.Run(bag, "k", entries, invoke, function() end)
            assert.equals(1, observedDepth)
            assert.is_nil(bag.depth.k)
        end)
    end)

    describe("RequestSweep", function()
        it("runs sweepFn synchronously when depth is 0", function()
            local bag = Dispatcher.NewDepthBag()
            local sweptKey
            Dispatcher.RequestSweep(bag, "k", function(k) sweptKey = k end)
            assert.equals("k", sweptKey)
            assert.is_nil(bag.sweepQueued.k)
        end)

        it("defers sweepFn when depth > 0; runs it once on return to depth 0", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = {
                { id = 1, cancelled = false },
                { id = 2, cancelled = false },
            }
            local sweepCalls = {}
            local function sweepFn(k) sweepCalls[#sweepCalls + 1] = k end

            Dispatcher.Run(bag, "k", entries, function()
                -- Request a sweep from inside the dispatch; must be deferred.
                Dispatcher.RequestSweep(bag, "k", sweepFn)
                assert.equals(0, #sweepCalls)
            end, sweepFn)

            -- Sweep ran exactly once at the depth-zero boundary.
            assert.are.same({ "k" }, sweepCalls)
            assert.is_nil(bag.sweepQueued.k)
        end)

        it("coalesces multiple RequestSweep calls during a single dispatch into one sweep", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = {
                { id = 1, cancelled = false },
                { id = 2, cancelled = false },
                { id = 3, cancelled = false },
            }
            local sweepCount = 0
            local function sweepFn() sweepCount = sweepCount + 1 end

            Dispatcher.Run(bag, "k", entries, function()
                Dispatcher.RequestSweep(bag, "k", sweepFn)
            end, sweepFn)

            assert.equals(1, sweepCount)
        end)

        it("does NOT trigger sweepFn at end of dispatch if no RequestSweep was made", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = { { id = 1, cancelled = false } }
            local sweepCalls = 0
            Dispatcher.Run(bag, "k", entries, function() end, function()
                sweepCalls = sweepCalls + 1
            end)
            assert.equals(0, sweepCalls)
        end)

        it("keys depth and sweep state per `key` (independent channels)", function()
            local bag = Dispatcher.NewDepthBag()
            local entriesA = { { id = 1, cancelled = false } }
            local sweepCalls = {}
            local function sweepFn(k) sweepCalls[#sweepCalls + 1] = k end

            -- Run on A; from inside, request sweep on B (depth for B is 0, so
            -- sweepFn fires synchronously for B and NOT for A).
            Dispatcher.Run(bag, "a", entriesA, function()
                Dispatcher.RequestSweep(bag, "b", sweepFn)
            end, sweepFn)

            assert.are.same({ "b" }, sweepCalls)
        end)

        it("RequestSweep on key X during Run on key Y defers sweep for X only if X is also dispatching", function()
            local bag = Dispatcher.NewDepthBag()
            -- Simulate an in-flight X by manually bumping depth.
            bag.depth.x = 1
            local sweepCalls = {}
            Dispatcher.RequestSweep(bag, "x", function(k)
                sweepCalls[#sweepCalls + 1] = k
            end)
            assert.equals(0, #sweepCalls)
            assert.is_true(bag.sweepQueued.x)
        end)
    end)

    describe("error propagation", function()
        it("does NOT pcall invoke; errors raised inside invoke propagate to the caller", function()
            local bag = Dispatcher.NewDepthBag()
            local entries = { { id = 1, cancelled = false } }
            assert.has.errors(function()
                Dispatcher.Run(bag, "k", entries, function()
                    error("boom")
                end, function() end)
            end)
        end)
    end)
end)
