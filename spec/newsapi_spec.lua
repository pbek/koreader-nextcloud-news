--[[--
Unit tests for nextcloudnews.koplugin/newsapi.lua.

Runs headlessly: KOReader runtime modules are stubbed via package.preload
(see spec/koreader_stubs.lua), and the HTTP layer is mocked so we can assert on
the requests the client builds and the responses it parses.
]]

local stubs = require("spec.koreader_stubs")
stubs.install()

local http = stubs.http
local NewsAPI = require("newsapi")

local function newClient(overrides)
    local opts = {
        server_url = "https://cloud.example.com",
        username = "alice",
        password = "secret",
    }
    for k, v in pairs(overrides or {}) do opts[k] = v end
    return NewsAPI:new(opts)
end

describe("NewsAPI:getBaseUrl", function()
    it("appends the standard API path to a bare host", function()
        local api = newClient()
        assert.are.equal(
            "https://cloud.example.com/index.php/apps/news/api/v1-3/",
            api:getBaseUrl())
    end)

    it("strips trailing slashes before appending", function()
        local api = newClient({ server_url = "https://cloud.example.com///" })
        assert.are.equal(
            "https://cloud.example.com/index.php/apps/news/api/v1-3/",
            api:getBaseUrl())
    end)

    it("accepts a full API URL (with index.php) and normalizes it", function()
        local api = newClient({
            server_url = "https://cloud.example.com/index.php/apps/news/api/v1-3",
        })
        assert.are.equal(
            "https://cloud.example.com/index.php/apps/news/api/v1-3/",
            api:getBaseUrl())
    end)

    it("accepts a full API URL without index.php", function()
        local api = newClient({
            server_url = "https://cloud.example.com/apps/news/api/v1-3/",
        })
        assert.are.equal(
            "https://cloud.example.com/apps/news/api/v1-3/",
            api:getBaseUrl())
    end)

    it("returns nil when no server_url is set", function()
        local api = NewsAPI:new({ username = "alice", password = "secret" })
        assert.is_nil(api:getBaseUrl())
    end)
end)

describe("NewsAPI:getAuthHeader", function()
    it("builds an HTTP Basic header", function()
        local api = newClient({ username = "alice", password = "secret" })
        -- base64("alice:secret") == "YWxpY2U6c2VjcmV0"
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", api:getAuthHeader())
    end)

    it("returns nil without credentials", function()
        local api = NewsAPI:new({ server_url = "https://cloud.example.com" })
        assert.is_nil(api:getAuthHeader())
    end)
end)

describe("NewsAPI:isConfigured", function()
    it("is true with url + username + password", function()
        assert.is_true(newClient():isConfigured())
    end)
    it("is false when a field is missing", function()
        assert.is_false(newClient({ password = "" }):isConfigured())
        assert.is_false(newClient({ username = "" }):isConfigured())
        assert.is_false(newClient({ server_url = "" }):isConfigured())
    end)
end)

describe("NewsAPI:callAPI", function()
    it("returns not_configured when unconfigured", function()
        local api = newClient({ password = "" })
        local ok, err = api:callAPI("GET", "/version")
        assert.is_false(ok)
        assert.are.equal("not_configured", err)
    end)

    it("builds the correct URL, method and auth header", function()
        local api = newClient()
        http.set_response{ code = 200, headers = {}, body = '{"version":"25.0.0"}' }
        api:callAPI("GET", "/version")
        assert.are.equal("GET", http.last_request.method)
        assert.are.equal(
            "https://cloud.example.com/index.php/apps/news/api/v1-3/version",
            http.last_request.url)
        assert.are.equal("Basic YWxpY2U6c2VjcmV0",
            http.last_request.headers["Authorization"])
    end)

    it("decodes a JSON response on 2xx", function()
        local api = newClient()
        http.set_response{ code = 200, headers = {}, body = '{"version":"25.0.0"}' }
        local ok, result = api:callAPI("GET", "/version")
        assert.is_true(ok)
        assert.are.equal("25.0.0", result.version)
    end)

    it("treats an empty 2xx body as an empty table", function()
        local api = newClient()
        http.set_response{ code = 200, headers = {}, body = "" }
        local ok, result = api:callAPI("PUT", "/items/read/multiple", { items = { 1 } })
        assert.is_true(ok)
        assert.are.same({}, result)
    end)

    it("encodes a JSON request body and sets headers", function()
        local api = newClient()
        http.set_response{ code = 200, headers = {}, body = "" }
        api:callAPI("PUT", "/items/read/multiple", { items = { 1, 2, 3 } })
        assert.are.equal("application/json",
            http.last_request.headers["Content-Type"])
        assert.is_not_nil(http.last_request.headers["Content-Length"])
        assert.is_not_nil(http.last_request.source)
    end)

    it("returns http_error + code on non-2xx", function()
        local api = newClient()
        http.set_response{ code = 401, headers = {}, status = "Unauthorized", body = "" }
        local ok, err, code = api:callAPI("GET", "/feeds", nil, nil, true)
        assert.is_false(ok)
        assert.are.equal("http_error", err)
        assert.are.equal(401, code)
    end)

    it("returns network_error when there are no response headers", function()
        local api = newClient()
        http.set_response{ network_error = true, status = "closed" }
        local ok, err = api:callAPI("GET", "/feeds", nil, nil, true)
        assert.is_false(ok)
        assert.are.equal("network_error", err)
    end)

    it("returns json_error on invalid JSON", function()
        local api = newClient()
        http.set_response{ code = 200, headers = {}, body = "not json <<<" }
        local ok, err = api:callAPI("GET", "/feeds")
        assert.is_false(ok)
        assert.are.equal("json_error", err)
    end)
end)

describe("NewsAPI item routes", function()
    before_each(function()
        http.set_response{ code = 200, headers = {}, body = '{"items":[]}' }
    end)

    it("getUnreadItems queries type=3, getRead=false, batchSize=-1", function()
        newClient():getUnreadItems(-1)
        local url = http.last_request.url
        assert.is_not_nil(url:find("type=3", 1, true))
        assert.is_not_nil(url:find("getRead=false", 1, true))
        assert.is_not_nil(url:find("batchSize=-1", 1, true))
    end)

    it("getStarredItems queries type=2", function()
        newClient():getStarredItems(-1)
        assert.is_not_nil(http.last_request.url:find("type=2", 1, true))
    end)

    it("getUpdatedItems includes lastModified and type", function()
        newClient():getUpdatedItems(12345, NewsAPI.TYPE_ALL)
        local url = http.last_request.url
        assert.is_not_nil(url:find("lastModified=12345", 1, true))
        assert.is_not_nil(url:find("type=3", 1, true))
    end)
end)

describe("NewsAPI mark-status routes", function()
    before_each(function()
        http.set_response{ code = 200, headers = {}, body = "" }
    end)

    it("markRead PUTs to /items/read/multiple", function()
        newClient():markRead({ 1, 2 })
        assert.are.equal("PUT", http.last_request.method)
        assert.is_not_nil(http.last_request.url:find("/items/read/multiple", 1, true))
    end)

    it("markStarred PUTs to /items/star/multiple", function()
        newClient():markStarred({ 7 })
        assert.is_not_nil(http.last_request.url:find("/items/star/multiple", 1, true))
    end)
end)
