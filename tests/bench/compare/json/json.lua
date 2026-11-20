-- JSON encode and decode round trip over generated records.
-- Lua has no JSON in its standard library, so this file carries a small
-- pure implementation of the usual shape.

local N = tonumber((...)) or 1000000

local state = 42
local function rand(n)
    state = (state * 48271) % 2147483647
    return state % n
end

local byte, sub, find, format, gsub = string.byte, string.sub, string.find, string.format, string.gsub
local concat = table.concat

-- Encoder

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_char(c)
    return escapes[c] or format("\\u%04x", byte(c))
end

local encode_value

local function encode_table(t, buf, n)
    if rawget(t, 1) ~= nil or next(t) == nil then
        n = n + 1
        buf[n] = "["
        for i = 1, #t do
            if i > 1 then
                n = n + 1
                buf[n] = ","
            end
            n = encode_value(t[i], buf, n)
        end
        n = n + 1
        buf[n] = "]"
    else
        n = n + 1
        buf[n] = "{"
        local first = true
        for k, v in pairs(t) do
            if type(k) ~= "string" then
                error("invalid key type: " .. type(k))
            end
            if not first then
                n = n + 1
                buf[n] = ","
            end
            first = false
            n = n + 1
            buf[n] = '"' .. gsub(k, '[%c"\\]', escape_char) .. '":'
            n = encode_value(v, buf, n)
        end
        n = n + 1
        buf[n] = "}"
    end
    return n
end

encode_value = function(v, buf, n)
    local tv = type(v)
    n = n + 1
    if tv == "string" then
        buf[n] = '"' .. gsub(v, '[%c"\\]', escape_char) .. '"'
    elseif tv == "number" then
        if v == math.floor(v) and v > -1e15 and v < 1e15 then
            buf[n] = format("%d", v)
        else
            buf[n] = format("%.17g", v)
        end
    elseif tv == "boolean" then
        buf[n] = v and "true" or "false"
    elseif tv == "nil" then
        buf[n] = "null"
    elseif tv == "table" then
        return encode_table(v, buf, n - 1)
    else
        error("cannot encode " .. tv)
    end
    return n
end

local function encode(v)
    local buf = {}
    encode_value(v, buf, 0)
    return concat(buf)
end

-- Decoder

local decode_value

local function skip(s, i)
    return find(s, "[^ \t\r\n]", i) or #s + 1
end

local unescapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decode_string(s, i)
    -- i is the position of the opening quote
    local j = find(s, '["\\]', i + 1)
    if not j then error("unterminated string at " .. i) end
    if byte(s, j) == 34 then
        return sub(s, i + 1, j - 1), j + 1
    end
    local parts, np = {}, 0
    local start = i + 1
    while true do
        j = find(s, '["\\]', start)
        if not j then error("unterminated string at " .. i) end
        np = np + 1
        parts[np] = sub(s, start, j - 1)
        if byte(s, j) == 34 then
            return concat(parts), j + 1
        end
        local e = sub(s, j + 1, j + 1)
        if e == "u" then
            local code = tonumber(sub(s, j + 2, j + 5), 16)
            np = np + 1
            if code < 128 then
                parts[np] = string.char(code)
            elseif code < 2048 then
                parts[np] = string.char(192 + math.floor(code / 64), 128 + code % 64)
            else
                parts[np] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
            end
            start = j + 6
        else
            np = np + 1
            parts[np] = unescapes[e] or error("bad escape at " .. j)
            start = j + 2
        end
    end
end

local function decode_array(s, i)
    local res, n = {}, 0
    i = skip(s, i + 1)
    if byte(s, i) == 93 then return res, i + 1 end
    while true do
        local v
        v, i = decode_value(s, i)
        n = n + 1
        res[n] = v
        i = skip(s, i)
        local c = byte(s, i)
        if c == 93 then return res, i + 1 end
        if c ~= 44 then error("expected ',' or ']' at " .. i) end
        i = skip(s, i + 1)
    end
end

local function decode_object(s, i)
    local res = {}
    i = skip(s, i + 1)
    if byte(s, i) == 125 then return res, i + 1 end
    while true do
        if byte(s, i) ~= 34 then error("expected string key at " .. i) end
        local k, v
        k, i = decode_string(s, i)
        i = skip(s, i)
        if byte(s, i) ~= 58 then error("expected ':' at " .. i) end
        v, i = decode_value(s, skip(s, i + 1))
        res[k] = v
        i = skip(s, i)
        local c = byte(s, i)
        if c == 125 then return res, i + 1 end
        if c ~= 44 then error("expected ',' or '}' at " .. i) end
        i = skip(s, i + 1)
    end
end

decode_value = function(s, i)
    local c = byte(s, i)
    if c == 123 then
        return decode_object(s, i)
    elseif c == 91 then
        return decode_array(s, i)
    elseif c == 34 then
        return decode_string(s, i)
    elseif c == 116 and sub(s, i, i + 3) == "true" then
        return true, i + 4
    elseif c == 102 and sub(s, i, i + 4) == "false" then
        return false, i + 5
    elseif c == 110 and sub(s, i, i + 3) == "null" then
        return nil, i + 4
    else
        local j = find(s, "[^%-%d%.eE%+]", i) or #s + 1
        local v = tonumber(sub(s, i, j - 1))
        if not v then error("unexpected character at " .. i) end
        return v, j
    end
end

local function decode(s)
    local v, i = decode_value(s, skip(s, 1))
    i = skip(s, i)
    if i <= #s then error("trailing data at " .. i) end
    return v
end

-- Benchmark

local records = {}
for i = 1, N do
    local name = "user" .. rand(100000)
    local age = rand(90)
    local active = rand(2) == 1
    local t1 = "t" .. rand(50)
    local t2 = "t" .. rand(50)
    local score = rand(1000000)
    records[i] = { id = i, name = name, age = age, active = active, tags = { t1, t2 }, score = score }
end

local text = encode(records)
local back = decode(text)

local active, agesum, scoresum, ntags = 0, 0, 0, 0
local seen = {}
for i = 1, #back do
    local r = back[i]
    if r.active then active = active + 1 end
    agesum = agesum + r.age
    scoresum = scoresum + r.score
    local tags = r.tags
    for j = 1, #tags do
        local tag = tags[j]
        if not seen[tag] then
            seen[tag] = true
            ntags = ntags + 1
        end
    end
end

print(format("json %d %d %d %d %d", active, agesum, scoresum % 1000000007, ntags, #text))
