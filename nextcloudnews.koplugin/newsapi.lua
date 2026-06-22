--[[--
Nextcloud News REST API v1.3 client.

Thin wrapper over LuaSocket/LuaSec for talking to a Nextcloud News server.
Modeled on the callAPI pattern in koreader/plugins/wallabag.koplugin, but uses
HTTP Basic authentication (recommended: a Nextcloud app password).

API reference: https://nextcloud.github.io/news/api/api-v1-3/

@module nextcloud_news.newsapi
]]

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local NewsAPI = {}
NewsAPI.__index = NewsAPI

-- Item query types (see API docs: type parameter).
NewsAPI.TYPE_FEED = 0
NewsAPI.TYPE_FOLDER = 1
NewsAPI.TYPE_STARRED = 2
NewsAPI.TYPE_ALL = 3

--- Create a new API client.
-- @tparam table opts { server_url, username, password,
--   block_timeout, total_timeout, file_block_timeout, file_total_timeout }
-- @treturn NewsAPI
function NewsAPI:new(opts)
    opts = opts or {}
    local o = {
        server_url = opts.server_url,
        username = opts.username,
        password = opts.password,
        block_timeout = opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout = opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT,
        file_block_timeout = opts.file_block_timeout or socketutil.FILE_BLOCK_TIMEOUT,
        file_total_timeout = opts.file_total_timeout or socketutil.FILE_TOTAL_TIMEOUT,
    }
    return setmetatable(o, self)
end

--- Build the API base URL from the configured server URL.
-- Accepts a server URL with or without a trailing slash and with or without
-- the /index.php prefix. Returns the v1-3 API root with a trailing slash.
-- @treturn string|nil base URL, or nil if server_url is not set
function NewsAPI:getBaseUrl()
    local url = self.server_url
    if not url or url == "" then
        return nil
    end
    -- Strip trailing slashes.
    url = url:gsub("/+$", "")
    -- If the user already pointed at the api path, normalize to its root.
    local api_root = url:match("^(.*/index%.php/apps/news/api/v1%-3)")
    if api_root then
        return api_root .. "/"
    end
    api_root = url:match("^(.*/apps/news/api/v1%-3)")
    if api_root then
        return api_root .. "/"
    end
    -- Otherwise assume a Nextcloud host root and append the standard path.
    return url .. "/index.php/apps/news/api/v1-3/"
end

--- Build the HTTP Basic Authorization header value.
-- @treturn string|nil
function NewsAPI:getAuthHeader()
    if not self.username or not self.password then
        return nil
    end
    return "Basic " .. mime.b64(self.username .. ":" .. self.password)
end

--- Whether the client has the minimum configuration to make calls.
-- @treturn bool
function NewsAPI:isConfigured()
    return self.server_url ~= nil and self.server_url ~= ""
        and self.username ~= nil and self.username ~= ""
        and self.password ~= nil and self.password ~= ""
end

--- Low-level API call.
-- @param method GET, POST, PUT, DELETE, …
-- @param route Route relative to the API base (e.g. "/feeds"), or a full URL
-- @param[opt] body Lua table to be JSON-encoded as the request body
-- @param[opt] filepath If set, response is streamed to this file instead of decoded
-- @param[opt=false] quiet Suppress non-fatal logging
-- @treturn bool ok
-- @treturn table|string result Decoded JSON table / filepath, or error type
--   ("not_configured" | "bad_url" | "network_error" | "json_error" | "http_error")
-- @treturn int|nil HTTP status code (on http_error)
function NewsAPI:callAPI(method, route, body, filepath, quiet)
    if not self:isConfigured() then
        return false, "not_configured"
    end

    local request = { method = method }

    if route:match("^https?://") then
        request.url = route
    else
        local base = self:getBaseUrl()
        if not base then
            return false, "bad_url"
        end
        -- base ends with "/"; route starts with "/": drop one slash.
        request.url = base .. route:gsub("^/", "")
    end

    local headers = {
        ["Authorization"] = self:getAuthHeader(),
        ["Accept"] = "application/json",
    }

    local body_json
    if body ~= nil then
        body_json = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
        request.source = ltn12.source.string(body_json)
    end
    request.headers = headers

    local sink = {}
    if filepath ~= nil then
        request.sink = ltn12.sink.file(io.open(filepath, "w"))
        socketutil:set_timeout(self.file_block_timeout, self.file_total_timeout)
    else
        request.sink = ltn12.sink.table(sink)
        socketutil:set_timeout(self.block_timeout, self.total_timeout)
    end

    logger.dbg("NewsAPI:callAPI:", request.method, request.url)

    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if resp_headers == nil then
        logger.err("NewsAPI:callAPI: network error", status or code)
        if filepath then
            os.remove(filepath)
        end
        return false, "network_error"
    end

    -- 2xx success.
    if type(code) == "number" and code >= 200 and code < 300 then
        if filepath then
            return true, filepath
        end
        local content = table.concat(sink)
        -- Some endpoints (mark-as-read, etc.) return an empty body.
        if content == "" then
            return true, {}
        end
        local ok, result = pcall(JSON.decode, content)
        if ok and result then
            return true, result
        end
        logger.err("NewsAPI:callAPI: invalid JSON response", content)
        return false, "json_error"
    end

    if filepath then
        os.remove(filepath)
    end
    if not quiet then
        logger.err("NewsAPI:callAPI: HTTP error", status or code, request.url)
    end
    return false, "http_error", code
end

-- ---------------------------------------------------------------------------
-- High-level endpoint helpers
-- ---------------------------------------------------------------------------

--- GET /version → { version = "x.y.z" }
function NewsAPI:getVersion()
    return self:callAPI("GET", "/version", nil, nil, true)
end

--- GET /status → { version, warnings = { improperlyConfiguredCron, incorrectDbCharset } }
function NewsAPI:getStatus()
    return self:callAPI("GET", "/status", nil, nil, true)
end

--- GET /folders → { folders = { {id, name}, … } }
function NewsAPI:getFolders()
    return self:callAPI("GET", "/folders")
end

--- GET /feeds → { feeds = {…}, starredCount, newestItemId }
function NewsAPI:getFeeds()
    return self:callAPI("GET", "/feeds")
end

--- GET /items
-- @tparam table params { type, id, getRead, batchSize, offset, oldestFirst }
-- @treturn ... ok, { items = {…} }
function NewsAPI:getItems(params)
    params = params or {}
    local q = {}
    local function add(k, v)
        if v ~= nil then
            table.insert(q, k .. "=" .. tostring(v))
        end
    end
    add("type", params.type)
    add("id", params.id)
    add("getRead", params.getRead)
    add("batchSize", params.batchSize)
    add("offset", params.offset)
    add("oldestFirst", params.oldestFirst)
    local route = "/items"
    if #q > 0 then
        route = route .. "?" .. table.concat(q, "&")
    end
    return self:callAPI("GET", route)
end

--- Convenience: all unread items (initial sync).
function NewsAPI:getUnreadItems(batchSize)
    return self:getItems({
        type = NewsAPI.TYPE_ALL,
        getRead = false,
        batchSize = batchSize or -1,
    })
end

--- Convenience: all starred items (initial sync).
function NewsAPI:getStarredItems(batchSize)
    return self:getItems({
        type = NewsAPI.TYPE_STARRED,
        getRead = true,
        batchSize = batchSize or -1,
    })
end

--- GET /items/updated — incremental sync.
-- @tparam number last_modified unix timestamp cursor
-- @tparam[opt=TYPE_ALL] number qtype
-- @tparam[opt] number id folder/feed id (use 0 for Starred/All)
function NewsAPI:getUpdatedItems(last_modified, qtype, id)
    local q = {
        "lastModified=" .. tostring(last_modified or 0),
        "type=" .. tostring(qtype or NewsAPI.TYPE_ALL),
    }
    if id ~= nil then
        table.insert(q, "id=" .. tostring(id))
    end
    return self:callAPI("GET", "/items/updated?" .. table.concat(q, "&"))
end

--- PUT /items/read/multiple { items = {ids} }
function NewsAPI:markRead(ids)
    return self:callAPI("PUT", "/items/read/multiple", { items = ids })
end

--- PUT /items/unread/multiple { items = {ids} }
function NewsAPI:markUnread(ids)
    return self:callAPI("PUT", "/items/unread/multiple", { items = ids })
end

--- PUT /items/star/multiple { itemIds = {ids} }
function NewsAPI:markStarred(ids)
    return self:callAPI("PUT", "/items/star/multiple", { itemIds = ids })
end

--- PUT /items/unstar/multiple { itemIds = {ids} }
function NewsAPI:markUnstarred(ids)
    return self:callAPI("PUT", "/items/unstar/multiple", { itemIds = ids })
end

return NewsAPI
