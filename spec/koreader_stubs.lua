--[[--
Test helper: stubs the KOReader runtime modules that `newsapi.lua` requires at
load time, so the plugin can be exercised headlessly under plain Lua/busted.

Returns a table with handles to the mutable stubs (notably the HTTP mock) so
individual tests can control responses.

Usage in a spec file:

    local stubs = require("spec.koreader_stubs")
    stubs.install()
    local NewsAPI = require("newsapi")   -- now loadable

The HTTP mock is controlled via `stubs.http.set_response{...}`.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Minimal JSON (encode/decode) sufficient for the API client's needs.
-- We avoid pulling a rock so tests stay dependency-light; this only needs to
-- round-trip the simple structures the client uses.
-- ---------------------------------------------------------------------------
local json = {}

local function json_encode(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return tostring(v)
    elseif t == "string" then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        -- Decide array vs object.
        local n = 0
        local is_array = true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" then is_array = false end
        end
        if is_array and n == #v then
            local parts = {}
            for _, item in ipairs(v) do
                parts[#parts + 1] = json_encode(item)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("cannot encode type " .. t)
end

-- A tiny recursive-descent JSON parser (enough for test payloads).
local function json_decode(str)
    local pos = 1
    local function skip_ws()
        local _, e = str:find("^[ \t\r\n]+", pos)
        if e then pos = e + 1 end
    end
    local parse_value

    local function parse_string()
        pos = pos + 1 -- opening quote
        local buf = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r" }
                buf[#buf + 1] = map[n] or n
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parse_number()
        local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        local num = tonumber(str:sub(s, e))
        pos = e + 1
        return num
    end

    local function parse_object()
        pos = pos + 1 -- {
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1 -- :
            obj[key] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "}" then break end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1 -- [
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "]" then break end
        end
        return arr
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == '"' then return parse_string()
        elseif c == "t" then pos = pos + 4; return true
        elseif c == "f" then pos = pos + 5; return false
        elseif c == "n" then pos = pos + 4; return nil
        else return parse_number() end
    end

    return parse_value()
end

json.encode = json_encode
json.decode = json_decode

-- ---------------------------------------------------------------------------
-- HTTP mock. `request{...}` returns the values that `socket.skip(1, ...)`
-- reduces to (code, headers, status). Tests set the next response.
-- ---------------------------------------------------------------------------
local http = {
    last_request = nil,
    _response = { code = 200, headers = {}, status = "OK", body = "" },
}

function http.set_response(resp)
    -- Pass network_error=true to simulate a transport failure (no headers).
    -- NB: avoid the `cond and nil or x` pitfall (always yields x); branch explicitly.
    local headers
    if not resp.network_error then
        headers = resp.headers or {}
    end
    http._response = {
        code = resp.code,
        headers = headers,
        status = resp.status or "",
        body = resp.body or "",
    }
end

function http.request(req)
    http.last_request = req
    local r = http._response
    -- Feed the body into the sink the client provided (table sink).
    if req.sink and r.body and r.body ~= "" then
        req.sink(r.body)
    end
    if r.headers == nil then
        -- Simulate a network error: real http.request returns (nil, errstring),
        -- so after socket.skip(1, ...) the client sees (errstring, nil) for
        -- (code, resp_headers) -> resp_headers == nil triggers network_error.
        return nil, r.status or "network error"
    end
    -- http.request returns (1, code, headers, status); socket.skip(1, ...)
    -- drops the leading 1, yielding (code, headers, status).
    return 1, r.code, r.headers, r.status
end

-- ---------------------------------------------------------------------------
-- Other trivial stubs.
-- ---------------------------------------------------------------------------
local socket = {
    -- Mirror LuaSocket's socket.skip(d, ...): drop the first `d` varargs and
    -- return the rest, preserving arity (including trailing nils).
    skip = function(d, ...)
        local n = select("#", ...)
        local out = {}
        for i = d + 1, n do
            out[i - d] = select(i, ...)
        end
        return (table.unpack or unpack)(out, 1, n - d)
    end,
}

local socketutil = {
    LARGE_BLOCK_TIMEOUT = 10,
    LARGE_TOTAL_TIMEOUT = 30,
    FILE_BLOCK_TIMEOUT = 30,
    FILE_TOTAL_TIMEOUT = 60,
    set_timeout = function() end,
    reset_timeout = function() end,
}

local ltn12 = {
    source = { string = function(s) return s end },
    sink = {
        table = function(t)
            return function(chunk)
                if chunk then t[#t + 1] = chunk end
                return true
            end
        end,
        file = function() return function() return true end end,
    },
}

-- Base64 implementation for the auth header.
local mime = {}
do
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    function mime.b64(data)
        return ((data:gsub(".", function(x)
            local r, byte = "", x:byte()
            for i = 8, 1, -1 do r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0") end
            return r
        end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
            if #x < 6 then return "" end
            local c = 0
            for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
            return b:sub(c + 1, c + 1)
        end) .. ({ "", "==", "=" })[#data % 3 + 1])
    end
end

local logger = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
    err = function() end,
}

-- gettext stub: identity function with .ngettext.
local gettext = setmetatable({
    ngettext = function(singular, plural, n)
        return n == 1 and singular or plural
    end,
}, {
    __call = function(_, s) return s end,
})

-- util stub: just the helpers epub.lua/main.lua use.
local util = {
    htmlEntitiesToUtf8 = function(s) return s end,
    getSafeFilename = function(name) return (name:gsub("[/\\]", "_")) end,
}

-- ---------------------------------------------------------------------------
-- Controllable EPUB backend stub (the real one lives in newsdownloader).
-- Tests can toggle availability and the createEpub outcome.
-- ---------------------------------------------------------------------------
local backend = {
    last_call = nil,
    _result = true,   -- return value of createEpub
    _raise = nil,     -- if set, createEpub errors with this message
}

function backend.createEpub(_self, epub_path, html, url, include_images, message)
    backend.last_call = {
        epub_path = epub_path, html = html, url = url,
        include_images = include_images, message = message,
    }
    if backend._raise then error(backend._raise) end
    return backend._result
end

-- ---------------------------------------------------------------------------
-- Install stubs into package.preload and make the plugin findable.
-- ---------------------------------------------------------------------------
function M.install()
    package.preload["json"] = function() return json end
    package.preload["socket.http"] = function() return http end
    package.preload["socket"] = function() return socket end
    package.preload["socketutil"] = function() return socketutil end
    package.preload["ltn12"] = function() return ltn12 end
    package.preload["mime"] = function() return mime end
    package.preload["logger"] = function() return logger end
    package.preload["gettext"] = function() return gettext end
    package.preload["util"] = function() return util end

    -- Allow `require("newsapi")` / `require("epub")` to resolve the plugin dir.
    package.path = "nextcloudnews.koplugin/?.lua;" .. package.path
end

--- Make the EPUB backend available (require("epubdownloadbackend") succeeds).
function M.enableBackend()
    package.preload["epubdownloadbackend"] = function() return backend end
    package.loaded["epubdownloadbackend"] = nil
end

--- Make the EPUB backend unavailable (require fails), for isAvailable tests.
function M.disableBackend()
    package.preload["epubdownloadbackend"] = nil
    package.loaded["epubdownloadbackend"] = nil
end

-- ---------------------------------------------------------------------------
-- Heavier UI/runtime stubs, only needed to `require("main")`. Installed by
-- M.installUI(); kept separate so the lighter newsapi/epub specs stay minimal.
-- ---------------------------------------------------------------------------
function M.installUI()
    M.install()

    -- WidgetContainer with a minimal :extend / :new supporting OO.
    local WidgetContainer = {}
    WidgetContainer.__index = WidgetContainer
    function WidgetContainer:extend(tbl)
        tbl = tbl or {}
        tbl.__index = tbl
        return setmetatable(tbl, { __index = self })
    end
    function WidgetContainer:new(tbl)
        tbl = tbl or {}
        return setmetatable(tbl, { __index = self })
    end

    local function noop() end
    local function tbl_with(extra)
        return setmetatable(extra or {}, { __index = function() return noop end })
    end

    local presets = {
        ["datastorage"] = { getSettingsDir = function() return "/tmp" end,
                            getDataDir = function() return "/tmp" end,
                            getFullDataDir = function() return "/tmp" end },
        ["dispatcher"] = tbl_with{ registerAction = noop },
        ["docsettings"] = tbl_with{
            hasSidecarFile = function() return false end,
            open = function() return { readSetting = function() return nil end, data = {} } end,
        },
        ["ui/event"] = tbl_with{ new = function(_, name, arg) return { name = name, arg = arg } end },
        ["ui/widget/infomessage"] = tbl_with{ new = function(_, t) return t end },
        ["luasettings"] = tbl_with{
            open = function() return {
                data = {}, readSetting = function() return nil end,
                saveSetting = noop, flush = noop, has = function() return false end,
            } end,
        },
        ["ui/widget/multiinputdialog"] = tbl_with{},
        ["ui/network/manager"] = tbl_with{
            runWhenOnline = function(_, fn) fn() end, afterWifiAction = noop,
        },
        ["ui/uimanager"] = tbl_with{ show = noop, close = noop, forceRePaint = noop },
        ["ui/widget/container/widgetcontainer"] = WidgetContainer,
        ["ffi/util"] = tbl_with{
            template = function(s, ...)
                local args = { ... }
                return (s:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)]) end))
            end,
            joinPath = function(a, b) return a .. b end,
        },
        ["apps/filemanager/filemanagerutil"] = tbl_with{ abbreviate = function(p) return p end },
        ["libs/libkoreader-lfs"] = tbl_with{
            attributes = function() return nil end, dir = function() return function() return nil end end,
        },
        ["ui/trapper"] = tbl_with{ info = noop, reset = noop, wrap = function(_, fn) fn() end },
    }
    for name, mod in pairs(presets) do
        package.preload[name] = function() return mod end
        package.loaded[name] = nil
    end

    M.enableBackend()
end

M.http = http
M.json = json
M.logger = logger
M.util = util
M.backend = backend

return M
