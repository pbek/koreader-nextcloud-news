--[[--
EPUB rendering helper for the Nextcloud News plugin.

Renders a Nextcloud News item (its HTML `body`) into a single-article EPUB.
Soft-depends on the EPUB backend shipped with KOReader's built-in
`newsdownloader.koplugin` (so we don't duplicate a large, well-tested module);
if it is unavailable, callers get a clear error.

The HTML template mirrors NewsDownloader's `createFromDescription`: a header
with the title and byline, the article body, and a footer note.

@module nextcloud_news.epub
]]

local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local Epub = {}

--- Try to load the EPUB backend from the bundled newsdownloader plugin.
-- @treturn table|nil backend, or nil + error string
local function getBackend()
    local ok, backend = pcall(require, "epubdownloadbackend")
    if ok and backend then
        return backend
    end
    return nil, _("The EPUB backend from KOReader's News downloader plugin is not available. Please ensure the News downloader plugin is present.")
end

--- Whether the EPUB backend can be loaded.
-- @treturn bool
function Epub.isAvailable()
    return (getBackend()) ~= nil
end

--- Best-effort extraction of an author/byline string from an item.
-- @tparam table item Nextcloud News item
-- @treturn string
local function getByline(item)
    if type(item.author) == "string" and item.author ~= "" then
        return item.author
    end
    return ""
end

--- Build the full XHTML document for an article.
-- @tparam table item Nextcloud News item ({ title, author, body, url })
-- @treturn string html
-- @treturn string title (sanitized for display)
function Epub.buildHTML(item)
    local title = item.title and util.htmlEntitiesToUtf8(item.title) or _("Untitled")
    local byline = getByline(item)
    local body = item.body or ""
    local footer = _("Retrieved from Nextcloud News.")

    -- Rewrite root-relative and relative links to absolute, using item.url as
    -- the base, mirroring NewsDownloader's behavior so links remain usable.
    local base_url = item.url
    if base_url and base_url ~= "" then
        if not base_url:match("/$") then
            base_url = base_url .. "/"
        end
        body = body:gsub('href="(.-)"', function(link)
            if link:match("^/") then
                local domain_only = base_url:match("^(.-://[^/]+)/")
                if domain_only then
                    return 'href="' .. domain_only .. link .. '"'
                end
                return 'href="' .. link .. '"'
            end
            if not link:match("^[a-zA-Z][a-zA-Z0-9+.-]*://") then
                link = base_url .. link
            end
            return 'href="' .. link .. '"'
        end)
    end

    local html = string.format([[
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>%s</title>
</head>
<body>
<header><h1>%s</h1><p><address>%s</address></p></header>
<br>
<article>%s</article>
<br>
<footer><small>%s</small></footer>
</body>
</html>]], title, title, byline, body, footer)

    return html, title
end

--- Render an item to an EPUB file at epub_path.
-- Must be called from within a Trapper:wrap() context (the backend uses
-- Trapper for progress UI and image download interruption).
-- @tparam string epub_path destination path
-- @tparam table item Nextcloud News item
-- @tparam[opt=true] bool include_images
-- @tparam[opt] string message progress message prefix
-- @treturn bool ok
-- @treturn string|nil error message on failure
function Epub.createFromItem(epub_path, item, include_images, message)
    local backend, err = getBackend()
    if not backend then
        return false, err
    end
    if include_images == nil then
        include_images = true
    end

    local html = Epub.buildHTML(item)
    local link = item.url or ""

    local ok, result = pcall(function()
        return backend:createEpub(epub_path, html, link, include_images, message or "")
    end)
    if not ok then
        logger.err("Epub.createFromItem: createEpub raised:", result)
        return false, tostring(result)
    end
    if not result then
        return false, _("EPUB creation failed or was cancelled.")
    end
    return true
end

return Epub
