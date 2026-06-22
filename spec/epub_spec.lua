--[[--
Unit tests for nextcloudnews.koplugin/epub.lua.

The EPUB backend (normally provided by KOReader's newsdownloader plugin) is
stubbed and made toggleable so we can test availability detection, HTML
building, link rewriting, and the createFromItem outcome handling — all
headlessly.
]]

local stubs = require("spec.koreader_stubs")
stubs.install()

local Epub = require("epub")

describe("Epub.isAvailable", function()
    it("is true when the backend can be required", function()
        stubs.enableBackend()
        assert.is_true(Epub.isAvailable())
    end)

    it("is false when the backend is missing", function()
        stubs.disableBackend()
        assert.is_false(Epub.isAvailable())
    end)
end)

describe("Epub.buildHTML", function()
    it("includes the title and body", function()
        local html, title = Epub.buildHTML({
            title = "Hello World",
            body = "<p>Some content</p>",
        })
        assert.are.equal("Hello World", title)
        assert.is_not_nil(html:find("Hello World", 1, true))
        assert.is_not_nil(html:find("<p>Some content</p>", 1, true))
    end)

    it("includes the author byline when present", function()
        local html = Epub.buildHTML({
            title = "T", author = "Jane Doe", body = "x",
        })
        assert.is_not_nil(html:find("Jane Doe", 1, true))
    end)

    it("falls back to a default title when missing", function()
        local _, title = Epub.buildHTML({ body = "x" })
        assert.is_not_nil(title)
        assert.is_true(#title > 0)
    end)

    it("rewrites root-relative links to absolute using item.url", function()
        local html = Epub.buildHTML({
            title = "T",
            url = "https://example.com/articles/123",
            body = '<a href="/other">link</a>',
        })
        assert.is_not_nil(html:find('href="https://example.com/other"', 1, true))
    end)

    it("rewrites relative links against the item.url base", function()
        local html = Epub.buildHTML({
            title = "T",
            url = "https://example.com/articles/123",
            body = '<a href="sub/page">link</a>',
        })
        -- base gets a trailing slash; relative path is appended.
        assert.is_not_nil(html:find("https://example.com/articles/123/sub/page", 1, true))
    end)

    it("leaves absolute links untouched", function()
        local html = Epub.buildHTML({
            title = "T",
            url = "https://example.com/a",
            body = '<a href="https://other.test/x">link</a>',
        })
        assert.is_not_nil(html:find('href="https://other.test/x"', 1, true))
    end)
end)

describe("Epub.createFromItem", function()
    before_each(function()
        stubs.enableBackend()
        stubs.backend._result = true
        stubs.backend._raise = nil
        stubs.backend.last_call = nil
    end)

    it("returns false with a message if the backend is unavailable", function()
        stubs.disableBackend()
        local ok, err = Epub.createFromItem("/tmp/x.epub", { title = "T", body = "b" })
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("calls the backend with the rendered html and url", function()
        local item = { title = "T", body = "<p>b</p>", url = "https://e.test/a" }
        local ok = Epub.createFromItem("/tmp/x.epub", item, true, "msg")
        assert.is_true(ok)
        assert.are.equal("/tmp/x.epub", stubs.backend.last_call.epub_path)
        assert.are.equal("https://e.test/a", stubs.backend.last_call.url)
        assert.is_true(stubs.backend.last_call.include_images)
        assert.is_not_nil(stubs.backend.last_call.html:find("<p>b</p>", 1, true))
    end)

    it("defaults include_images to true", function()
        Epub.createFromItem("/tmp/x.epub", { title = "T", body = "b" })
        assert.is_true(stubs.backend.last_call.include_images)
    end)

    it("returns false when the backend reports failure", function()
        stubs.backend._result = false
        local ok, err = Epub.createFromItem("/tmp/x.epub", { title = "T", body = "b" })
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("returns false (not raising) when the backend errors", function()
        stubs.backend._raise = "boom"
        local ok, err = Epub.createFromItem("/tmp/x.epub", { title = "T", body = "b" })
        assert.is_false(ok)
        assert.is_not_nil(err:find("boom", 1, true))
    end)
end)
