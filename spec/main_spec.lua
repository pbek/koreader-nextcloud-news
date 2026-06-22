--[[--
Unit tests for the testable logic in nextcloudnews.koplugin/main.lua:
the offline status queue (flushStatusQueue) and the article filename scheme.

KOReader UI/runtime modules are stubbed (spec/koreader_stubs.installUI) so the
module can be required headlessly. We construct a bare instance table with the
plugin's metatable and exercise individual methods, bypassing :init().
]]

local stubs = require("spec.koreader_stubs")
stubs.installUI()

local NextcloudNews = require("main")

-- Build a minimal instance that delegates to NextcloudNews methods without
-- running :init(). onFlushSettings is a no-op here (no real settings).
local function newInstance(fields)
    local o = setmetatable({}, { __index = NextcloudNews })
    o.status_queue = {}
    o.starred_state = {}
    o.directory = "/tmp/ncnews/"
    o.onFlushSettings = function() end
    for k, v in pairs(fields or {}) do o[k] = v end
    return o
end

-- Fake API that records calls and returns programmable results per action.
local function fakeAPI(results)
    results = results or {}
    local calls = { read = {}, unread = {}, star = {}, unstar = {} }
    local function make(action)
        return function(_, ids)
            calls[action][#calls[action] + 1] = ids
            local r = results[action]
            if r == nil then return true end
            return r
        end
    end
    return {
        markRead = make("read"),
        markUnread = make("unread"),
        markStarred = make("star"),
        markUnstarred = make("unstar"),
    }, calls
end

describe("NextcloudNews:flushStatusQueue", function()
    it("returns 0 and does nothing on an empty queue", function()
        local o = newInstance()
        local api = fakeAPI()
        assert.are.equal(0, o:flushStatusQueue(api))
    end)

    it("batches ids by action and clears the queue on success", function()
        local o = newInstance({
            status_queue = {
                { id = 1, action = "read" },
                { id = 2, action = "read" },
                { id = 3, action = "star" },
            },
        })
        local api, calls = fakeAPI()
        local pushed = o:flushStatusQueue(api)
        assert.are.equal(3, pushed)
        -- read called once with both ids.
        assert.are.equal(1, #calls.read)
        assert.are.same({ 1, 2 }, calls.read[1])
        assert.are.same({ 3 }, calls.star[1])
        -- queue emptied.
        assert.are.equal(0, #o.status_queue)
    end)

    it("re-queues entries whose action failed, keeping successes out", function()
        local o = newInstance({
            status_queue = {
                { id = 1, action = "read" },
                { id = 2, action = "star" },
            },
        })
        -- star fails, read succeeds.
        local api = fakeAPI({ star = false })
        local pushed = o:flushStatusQueue(api)
        assert.are.equal(1, pushed) -- only the read
        assert.are.equal(1, #o.status_queue)
        assert.are.equal("star", o.status_queue[1].action)
        assert.are.equal(2, o.status_queue[1].id)
    end)
end)

describe("NextcloudNews:queueStatus", function()
    it("appends an entry to the queue", function()
        local o = newInstance()
        o:queueStatus(42, "read")
        assert.are.equal(1, #o.status_queue)
        assert.are.equal(42, o.status_queue[1].id)
        assert.are.equal("read", o.status_queue[1].action)
    end)
end)

describe("NextcloudNews:getArticlePath", function()
    it("embeds the item id with the nc-id prefix", function()
        local o = newInstance()
        local path = o:getArticlePath({ id = 99, title = "My Article" })
        assert.is_not_nil(path:find("[nc-id_99]", 1, true))
        assert.is_not_nil(path:find("%.epub$"))
    end)
end)

describe("NextcloudNews:getItemIdForPath", function()
    it("extracts the id from a full path", function()
        local o = newInstance()
        assert.are.equal(123,
            o:getItemIdForPath("/tmp/ncnews/[nc-id_123] Title.epub"))
    end)
    it("extracts the id from a bare filename", function()
        local o = newInstance()
        assert.are.equal(7, o:getItemIdForPath("[nc-id_7] X.epub"))
    end)
    it("returns nil for non-article paths", function()
        local o = newInstance()
        assert.is_nil(o:getItemIdForPath("/tmp/somebook.epub"))
        assert.is_nil(o:getItemIdForPath(nil))
    end)
end)

describe("NextcloudNews:getCurrentItemId", function()
    it("returns the id of the open document when it is ours", function()
        local o = newInstance({
            ui = { document = { file = "/tmp/ncnews/[nc-id_55] A.epub" } },
        })
        assert.are.equal(55, o:getCurrentItemId())
    end)
    it("returns nil when no document is open", function()
        local o = newInstance({ ui = {} })
        assert.is_nil(o:getCurrentItemId())
    end)
    it("returns nil when the open document is not an article", function()
        local o = newInstance({ ui = { document = { file = "/tmp/book.epub" } } })
        assert.is_nil(o:getCurrentItemId())
    end)
end)

describe("NextcloudNews filter (folder/feed selection)", function()
    it("defaults to the 'All articles' label", function()
        local o = newInstance()
        assert.are.equal("All articles", o:getFilterLabel())
    end)

    it("reports the cached label for a folder/feed filter", function()
        local o = newInstance({
            filter_type = 1, filter_id = 9, filter_label = "Folder: News",
        })
        assert.are.equal("Folder: News", o:getFilterLabel())
    end)

    it("setFilter stores the scope and resets the sync cursor", function()
        local o = newInstance({ last_modified = 12345 })
        o:setFilter(0, 9, "Feed: X")  -- TYPE_FEED == 0
        assert.are.equal(0, o.filter_type)
        assert.are.equal(9, o.filter_id)
        assert.are.equal("Feed: X", o.filter_label)
        -- cursor reset so the new scope is re-fetched in full.
        assert.are.equal(0, o.last_modified)
    end)

    it("setFilter(nil,...) clears the filter back to all", function()
        local o = newInstance({ filter_type = 1, filter_id = 3, last_modified = 5 })
        o:setFilter(nil, nil, nil)
        assert.is_nil(o.filter_type)
        assert.is_nil(o.filter_id)
        assert.are.equal("All articles", o:getFilterLabel())
        assert.are.equal(0, o.last_modified)
    end)
end)

describe("NextcloudNews:toggleStar", function()
    it("stars an unstarred item and queues a star action", function()
        local o = newInstance()
        local now = o:toggleStar(10)
        assert.is_true(now)
        assert.is_true(o.starred_state["10"])
        assert.are.equal(1, #o.status_queue)
        assert.are.equal("star", o.status_queue[1].action)
        assert.are.equal(10, o.status_queue[1].id)
    end)

    it("unstars a starred item and queues an unstar action", function()
        local o = newInstance({ starred_state = { ["10"] = true } })
        local now = o:toggleStar(10)
        assert.is_false(now)
        assert.is_nil(o.starred_state["10"])
        assert.are.equal("unstar", o.status_queue[1].action)
    end)

    it("round-trips back to starred on a second toggle", function()
        local o = newInstance()
        o:toggleStar(3)
        local now = o:toggleStar(3)
        assert.is_false(now)
        assert.are.equal(2, #o.status_queue)
        assert.are.equal("star", o.status_queue[1].action)
        assert.are.equal("unstar", o.status_queue[2].action)
    end)
end)
