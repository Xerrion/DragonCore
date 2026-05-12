-------------------------------------------------------------------------------
-- Serializer.lua
-- Internal serialiser for DragonCore.AddonChannel. Binary-safe encoding of
-- (topic, payload) into a single byte string suitable for
-- C_ChatInfo.SendAddonMessage. NOT part of the public DragonCore-1.0 surface;
-- attached as DragonCore._AddonChannelSerializer per design note section 10
-- (option a).
--
-- Wire format (design note section 4):
--   byte 0       : header / version byte. 0x01 for v0.
--   byte 1..n    : encoded topic (always tag 'S' string).
--   byte n+1..m  : encoded payload (any supported scalar or table).
--
-- Per-value encoding:
--   'N'                                    nil
--   'T' / 'F'                              boolean
--   'D' + uint16(len) + tostring(number)   number (textual; round-trips via tonumber)
--   'S' + uint16(len) + bytes              string (binary-safe)
--   'M' + uint16(count) + (key value)*N    table (count is pairs() count;
--                                          keys may be any supported value)
--
-- The encode path checks total length against MAX_PAYLOAD_BYTES (Blizzard's
-- ~255-byte CTL wire ceiling) and returns a failure result if exceeded; the
-- caller surfaces this as SendResult.error == "SerializationFailed". No
-- chunking, no cycle detection (programmer-error per design note section 4).
--
-- Decode is total: every malformed input returns `ok = false, err = <reason>`;
-- exceptions never escape decode.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary
-------------------------------------------------------------------------------

local MAJOR, MINOR = "DragonCore-1.0", 1
local DragonCore = LibStub:NewLibrary(MAJOR, MINOR) or LibStub(MAJOR)
if not DragonCore then return end

local HEADER_VERSION = "\1"
local MAX_PAYLOAD_BYTES = 255

local Serializer = {}

-------------------------------------------------------------------------------
-- Length / integer helpers (big-endian uint16; 0..65535 covers any field we
-- could fit under MAX_PAYLOAD_BYTES anyway).
-------------------------------------------------------------------------------

local function encodeUint16(n)
    -- Caller guarantees 0 <= n <= 65535 (lengths are bounded by string size).
    return string.char(math.floor(n / 256), n % 256)
end

local function decodeUint16(buf, i)
    -- Returns value, nextIndex. Caller checks bounds via the (buf, i+1) reads.
    local hi = buf:byte(i)
    local lo = buf:byte(i + 1)
    if hi == nil or lo == nil then return nil, nil end
    return hi * 256 + lo, i + 2
end

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

-- forward decl so encodeValue can recurse into itself for tables.
local encodeValue

local function encodeString(s)
    if #s > 65535 then return nil, "string too long (> 65535 bytes)" end
    return "S" .. encodeUint16(#s) .. s
end

local function encodeNumber(n)
    -- tostring(number) is locale-independent in Lua 5.1 for finite floats and
    -- integers within the float range. NaN / Inf serialise to "nan" / "inf"
    -- which tonumber on Lua 5.1 rejects -- we reject them up front so the
    -- decode side cannot encounter them.
    if n ~= n then return nil, "cannot serialise NaN" end
    if n == math.huge or n == -math.huge then
        return nil, "cannot serialise infinity"
    end
    local s = tostring(n)
    return "D" .. encodeUint16(#s) .. s
end

encodeValue = function(v)
    local t = type(v)
    if t == "nil" then return "N" end
    if t == "boolean" then return v and "T" or "F" end
    if t == "number" then return encodeNumber(v) end
    if t == "string" then return encodeString(v) end
    if t == "table" then
        -- Two-pass: collect parts, count entries, prepend the count tag once
        -- the count is known. pairs() implicit-skips nil values so the count
        -- matches the actual key/value pairs we emit.
        local parts, count = {}, 0
        for k, val in pairs(v) do
            local ek, errK = encodeValue(k)
            if not ek then return nil, errK end
            local ev, errV = encodeValue(val)
            if not ev then return nil, errV end
            parts[#parts + 1] = ek
            parts[#parts + 1] = ev
            count = count + 1
        end
        return "M" .. encodeUint16(count) .. table.concat(parts)
    end
    -- function, userdata, thread: structurally unrepresentable.
    return nil, "unsupported type: " .. t
end

---Encode (topic, payload) into a single wire-format string. Returns
---`true, encoded` on success and `false, errMessage` on failure. The
---caller maps any failure to `SendResult.error == "SerializationFailed"`.
---@param topic string
---@param payload any
---@return boolean ok
---@return string  encodedOrError
function Serializer.encode(topic, payload)
    if type(topic) ~= "string" or topic == "" then
        return false, "topic must be a non-empty string"
    end
    local et, errT = encodeString(topic)
    if not et then return false, errT end
    local ep, errP = encodeValue(payload)
    if not ep then return false, errP end
    local out = HEADER_VERSION .. et .. ep
    if #out > MAX_PAYLOAD_BYTES then
        return false, "payload too large (" .. #out .. " bytes, max " ..
            MAX_PAYLOAD_BYTES .. ")"
    end
    return true, out
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

-- forward decl so decodeValue can recurse into itself for tables.
local decodeValue

local function decodeStringAt(buf, i)
    if buf:byte(i) ~= 83 then  -- 'S' == 83
        return nil, nil, "expected 'S' tag at offset " .. i
    end
    local len, j = decodeUint16(buf, i + 1)
    if not len then return nil, nil, "truncated length at offset " .. (i + 1) end
    if j + len - 1 > #buf then
        return nil, nil, "truncated string body at offset " .. j
    end
    return buf:sub(j, j + len - 1), j + len
end

decodeValue = function(buf, i)
    if i > #buf then return nil, nil, "truncated value at offset " .. i end
    local tag = buf:byte(i)
    if tag == 78 then       -- 'N'
        return nil, i + 1
    elseif tag == 84 then   -- 'T'
        return true, i + 1
    elseif tag == 70 then   -- 'F'
        return false, i + 1
    elseif tag == 68 then   -- 'D'
        local len, j = decodeUint16(buf, i + 1)
        if not len then return nil, nil, "truncated number length" end
        if j + len - 1 > #buf then return nil, nil, "truncated number body" end
        local n = tonumber(buf:sub(j, j + len - 1))
        if n == nil then return nil, nil, "malformed number literal" end
        return n, j + len
    elseif tag == 83 then   -- 'S'
        return decodeStringAt(buf, i)
    elseif tag == 77 then   -- 'M'
        local count, j = decodeUint16(buf, i + 1)
        if not count then return nil, nil, "truncated table count" end
        local out = {}
        for _ = 1, count do
            local k, j2, errK = decodeValue(buf, j)
            if errK then return nil, nil, errK end
            local val, j3, errV = decodeValue(buf, j2)
            if errV then return nil, nil, errV end
            out[k] = val
            j = j3
        end
        return out, j
    end
    return nil, nil, "unknown tag byte " .. tostring(tag) .. " at offset " .. i
end

---Decode a wire-format byte string into (topic, payload). Total function:
---every malformed input returns `false, err`; exceptions never escape. The
---caller (the OnEvent dispatcher) silently drops failed decodes per the
---DeserializationFailed inbound contract (design note section 5, conflict
---log #5).
---@param buf string
---@return boolean ok
---@return string|nil topicOrError   topic on success; error message on failure.
---@return any payload                payload on success; nil on failure.
function Serializer.decode(buf)
    if type(buf) ~= "string" or #buf < 1 then
        return false, "empty buffer", nil
    end
    if buf:sub(1, 1) ~= HEADER_VERSION then
        return false, "unsupported header version " ..
            string.format("0x%02X", buf:byte(1) or 0), nil
    end
    local topic, j, errT = decodeStringAt(buf, 2)
    if errT then return false, errT, nil end
    local payload, _, errP = decodeValue(buf, j)
    if errP then return false, errP, nil end
    return true, topic, payload
end

DragonCore._AddonChannelSerializer = Serializer
