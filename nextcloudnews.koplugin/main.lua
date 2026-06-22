--[[--
Nextcloud News plugin for KOReader.

Synchronizes articles from a Nextcloud News server (REST API v1.3) and saves
them as EPUB files, with two-way read/starred state sync.

Architecture mirrors KOReader's built-in wallabag.koplugin:
- settings stored via LuaSettings (flushed on onFlushSettings),
- network-gated sync via NetworkMgr,
- per-article EPUBs in a dedicated download folder, with the item id embedded
  in the filename for round-trip mapping,
- an offline status queue (read/unread/star/unstar) flushed on the next online
  sync,
- incremental fetch via /items/updated using a persisted lastModified cursor.

@module koplugin.nextcloud_news
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Epub = require("epub")
local NewsAPI = require("newsapi")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

-- Embed the Nextcloud News item id in the filename so we can map a local file
-- back to its server item (mirrors wallabag's "[w-id_<id>] " convention).
local id_prefix = "[nc-id_"
local id_postfix = "] "

local NextcloudNews = WidgetContainer:extend{
    name = "nextcloud_news",
    settings_file = DataStorage:getSettingsDir() .. "/nextcloud_news.lua",
    settings = nil,
    updated = nil,
}

-- ---------------------------------------------------------------------------
-- Lifecycle & settings
-- ---------------------------------------------------------------------------

function NextcloudNews.onDispatcherRegisterActions()
    Dispatcher:registerAction("nextcloud_news_sync", {
        category = "none",
        event = "SynchronizeNextcloudNews",
        title = _("Nextcloud News synchronization"),
        general = true,
    })
    Dispatcher:registerAction("nextcloud_news_toggle_star", {
        category = "none",
        event = "ToggleNextcloudNewsStar",
        title = _("Nextcloud News: toggle star"),
        reader = true,
    })
end

function NextcloudNews:init()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function NextcloudNews:loadSettings()
    if not NextcloudNews.settings then
        NextcloudNews.settings = LuaSettings:open(self.settings_file)
        if not next(NextcloudNews.settings.data) then
            NextcloudNews.settings.data = { nextcloud_news = {} }
            self.updated = true
        end
    end
    self.settings = NextcloudNews.settings
    local data = self.settings.data.nextcloud_news or {}
    self.server_url        = data.server_url
    self.username          = data.username
    self.password          = data.password
    self.directory         = self.normalizeDownloadDir(data.directory)
    self.articles_per_sync = data.articles_per_sync or 30
    self.include_images    = data.include_images
    if self.include_images == nil then self.include_images = true end
    self.mark_read_on_finished = data.mark_read_on_finished
    if self.mark_read_on_finished == nil then self.mark_read_on_finished = true end
    self.remove_read_locally = data.remove_read_locally or false
    -- Which feed/folder to sync. nil/0 type means "all". The label is cached
    -- for display so the menu needn't refetch the feed/folder list.
    self.filter_type   = data.filter_type   -- NewsAPI.TYPE_FOLDER / TYPE_FEED / nil
    self.filter_id     = data.filter_id      -- folder or feed id
    self.filter_label  = data.filter_label   -- human-readable name for the menu
    -- Persisted sync state.
    self.last_modified  = data.last_modified or 0
    self.status_queue   = data.status_queue or {}
    -- Known starred state per item id (string key -> bool), used to decide
    -- whether a device-side toggle should star or unstar, and updated from the
    -- server on each sync.
    self.starred_state  = data.starred_state or {}
end

function NextcloudNews:onFlushSettings()
    if self.updated then
        self.settings:saveSetting("nextcloud_news", {
            server_url            = self.server_url,
            username              = self.username,
            password              = self.password,
            directory             = self.directory,
            articles_per_sync     = self.articles_per_sync,
            include_images        = self.include_images,
            mark_read_on_finished = self.mark_read_on_finished,
            remove_read_locally   = self.remove_read_locally,
            filter_type           = self.filter_type,
            filter_id             = self.filter_id,
            filter_label          = self.filter_label,
            last_modified         = self.last_modified,
            status_queue          = self.status_queue,
            starred_state         = self.starred_state,
        })
        self.settings:flush()
        self.updated = nil
    end
end

--- Build an API client from the current settings.
function NextcloudNews:getAPI()
    return NewsAPI:new{
        server_url = self.server_url,
        username   = self.username,
        password   = self.password,
    }
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function NextcloudNews:addToMainMenu(menu_items)
    menu_items.nextcloud_news = {
        text = _("Nextcloud News"),
        sub_item_table = {
            {
                text = _("Synchronize"),
                callback = function()
                    self.ui:handleEvent(Event:new("SynchronizeNextcloudNews"))
                end,
            },
            {
                text_func = function()
                    return T(_("Sync from: %1"), self:getFilterLabel())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    NetworkMgr:runWhenOnline(function()
                        self:chooseFilter(touchmenu_instance)
                    end)
                end,
                separator = true,
            },
            {
                -- Only meaningful while reading one of our articles.
                text_func = function()
                    local id = self:getCurrentItemId()
                    if id and self.starred_state[tostring(id)] then
                        return _("Unstar current article")
                    end
                    return _("Star current article")
                end,
                enabled_func = function()
                    return self:getCurrentItemId() ~= nil
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:toggleStarCurrentArticle()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
            {
                text = _("Go to download folder"),
                callback = function() self:openDownloadFolder() end,
                separator = true,
            },
            {
                text = _("Test connection"),
                keep_menu_open = true,
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:testConnection() end)
                end,
            },
            {
                text = _("Configure server"),
                keep_menu_open = true,
                callback = function() self:editServerSettings() end,
            },
            {
                text_func = function()
                    local path = (not self.directory or self.directory == "")
                        and _("not set")
                        or filemanagerutil.abbreviate(self.directory)
                    return T(_("Download folder: %1"), path)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:setDownloadDirectory(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Articles per sync: %1"), self.articles_per_sync)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:setArticlesPerSync(touchmenu_instance)
                end,
            },
            {
                text = _("Include images"),
                keep_menu_open = true,
                checked_func = function() return self.include_images end,
                callback = function()
                    self.include_images = not self.include_images
                    self.updated = true
                    self:onFlushSettings()
                end,
            },
            {
                text = _("Mark read on the server when finished"),
                keep_menu_open = true,
                checked_func = function() return self.mark_read_on_finished end,
                callback = function()
                    self.mark_read_on_finished = not self.mark_read_on_finished
                    self.updated = true
                    self:onFlushSettings()
                end,
            },
            {
                text = _("Delete local files when read on the server"),
                keep_menu_open = true,
                checked_func = function() return self.remove_read_locally end,
                callback = function()
                    self.remove_read_locally = not self.remove_read_locally
                    self.updated = true
                    self:onFlushSettings()
                end,
                separator = true,
            },
            {
                text = _("Info"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[Synchronizes articles from a Nextcloud News server and saves them as EPUB files,
with two-way read/starred state sync.

Use a Nextcloud app password and an HTTPS server URL.

More details: https://github.com/nextcloud/news]]),
                    })
                end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function NextcloudNews:onSynchronizeNextcloudNews()
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:synchronize() end)
    end)
    return true
end

function NextcloudNews:onToggleNextcloudNewsStar()
    self:toggleStarCurrentArticle()
    return true
end

-- ---------------------------------------------------------------------------
-- Connection test
-- ---------------------------------------------------------------------------

function NextcloudNews.describeError(_self, result, code)
    if result == "http_error" then
        return T(_("HTTP error (%1). Check URL and credentials."), code or "?")
    elseif result == "network_error" then
        return _("Network error. Check the server URL and connectivity.")
    elseif result == "not_configured" then
        return _("Server settings are incomplete.")
    elseif result == "bad_url" then
        return _("The server URL is invalid.")
    else
        return _("Could not parse the server response.")
    end
end

function NextcloudNews:testConnection()
    local api = self:getAPI()
    if not api:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure the server settings first."),
        })
        return
    end
    local info = InfoMessage:new{ text = _("Connecting to Nextcloud News…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, result, code = api:getVersion()
    UIManager:close(info)
    if ok and result and result.version then
        UIManager:show(InfoMessage:new{
            text = T(_("Connected. Nextcloud News version: %1"), result.version),
        })
    else
        logger.err("NextcloudNews:testConnection failed:", result, code)
        UIManager:show(InfoMessage:new{
            text = T(_("Connection failed.\n%1"), self:describeError(result, code)),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Download folder helpers
-- ---------------------------------------------------------------------------

function NextcloudNews.normalizeDownloadDir(path)
    if not path or path == "" then return nil end
    return path:match("/$") and path or path .. "/"
end

function NextcloudNews:hasValidDownloadDir()
    local directory = self.normalizeDownloadDir(self.directory)
    return directory ~= nil and lfs.attributes(directory, "mode") == "directory"
end

function NextcloudNews:openDownloadFolder()
    if not self:hasValidDownloadDir() then
        UIManager:show(InfoMessage:new{ text = _("Please set a valid download folder first.") })
        return
    end
    local FileManager = require("apps/filemanager/filemanager")
    if self.ui.document then
        self.ui:onClose()
    end
    if FileManager.instance then
        FileManager.instance:reinit(self.directory)
    else
        FileManager:showFiles(self.directory)
    end
end

--- Build a list of locally present article files keyed by item id (as string).
-- @treturn table { ["<id>"] = full_path }
function NextcloudNews:getLocalArticles()
    local local_articles = {}
    if not self:hasValidDownloadDir() then
        return local_articles
    end
    for entry in lfs.dir(self.directory) do
        local id = entry:match("^%[nc%-id_(%d+)%]")
        if id then
            local_articles[id] = self.directory .. entry
        end
    end
    return local_articles
end

--- Compute the local file path for an item.
function NextcloudNews:getArticlePath(item)
    local title = util.getSafeFilename(
        item.title and util.htmlEntitiesToUtf8(item.title) or _("Untitled"),
        self.directory, 230, 0)
    return ffiUtil.joinPath(self.directory,
        id_prefix .. item.id .. id_postfix .. title .. ".epub")
end

--- Extract the Nextcloud News item id encoded in a file path/name.
-- @tparam string path a file path or bare filename
-- @treturn number|nil the item id, or nil if the name doesn't encode one
function NextcloudNews.getItemIdForPath(_self, path)
    if not path then return nil end
    local name = path:match("[^/]+$") or path
    local id = name:match("^%[nc%-id_(%d+)%]")
    return id and tonumber(id) or nil
end

--- The item id of the currently open document, if it is one of ours.
-- @treturn number|nil
function NextcloudNews:getCurrentItemId()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return nil end
    return self:getItemIdForPath(doc.file)
end

--- Toggle the starred state of an item: flip the locally-known state, persist
-- it, and queue a star/unstar change for the next sync.
-- @tparam number id item id
-- @treturn bool the new starred state
function NextcloudNews:toggleStar(id)
    local key = tostring(id)
    local now_starred = not self.starred_state[key]
    self.starred_state[key] = now_starred or nil
    self.updated = true
    self:queueStatus(id, now_starred and "star" or "unstar")
    return now_starred
end

--- Toggle the star for the currently open article (menu/gesture action).
function NextcloudNews:toggleStarCurrentArticle()
    local id = self:getCurrentItemId()
    if not id then
        UIManager:show(InfoMessage:new{
            text = _("The current document is not a Nextcloud News article."),
        })
        return
    end
    local now_starred = self:toggleStar(id)
    UIManager:show(InfoMessage:new{
        text = now_starred and _("Article starred (will sync).")
            or _("Article unstarred (will sync)."),
        timeout = 2,
    })
end

-- ---------------------------------------------------------------------------
-- Offline status queue (M4)
-- ---------------------------------------------------------------------------

--- Queue a status change for the next online sync.
-- @tparam number id item id
-- @tparam string action one of "read", "unread", "star", "unstar"
function NextcloudNews:queueStatus(id, action)
    table.insert(self.status_queue, { id = id, action = action })
    self.updated = true
    self:onFlushSettings()
end

--- Flush the offline status queue to the server in batches by action.
-- @tparam NewsAPI api
-- @treturn number number of status changes successfully pushed
function NextcloudNews:flushStatusQueue(api)
    if #self.status_queue == 0 then
        return 0
    end
    -- Group ids by action.
    local buckets = { read = {}, unread = {}, star = {}, unstar = {} }
    for i = 1, #self.status_queue do
        local entry = self.status_queue[i]
        if buckets[entry.action] then
            table.insert(buckets[entry.action], entry.id)
        end
    end

    local pushed = 0
    local remaining = {}
    local dispatch = {
        read   = function(ids) return api:markRead(ids) end,
        unread = function(ids) return api:markUnread(ids) end,
        star   = function(ids) return api:markStarred(ids) end,
        unstar = function(ids) return api:markUnstarred(ids) end,
    }
    for action, ids in pairs(buckets) do
        if #ids > 0 then
            local ok = dispatch[action](ids)
            if ok then
                pushed = pushed + #ids
            else
                -- Keep failed entries queued for the next attempt.
                for i = 1, #ids do
                    local id = ids[i]
                    table.insert(remaining, { id = id, action = action })
                end
            end
        end
    end

    self.status_queue = remaining
    self.updated = true
    self:onFlushSettings()
    return pushed
end

--- Scan locally finished articles and queue them to be marked read remotely.
-- Mirrors wallabag's status detection via DocSettings "summary.status".
function NextcloudNews:queueFinishedArticles()
    if not self.mark_read_on_finished or not self:hasValidDownloadDir() then
        return
    end
    for id, path in pairs(self:getLocalArticles()) do
        if DocSettings:hasSidecarFile(path) then
            local docinfo = DocSettings:open(path)
            local status = docinfo:readSetting("summary") and docinfo.data.summary.status
            if status == "complete" then
                self:queueStatus(tonumber(id), "read")
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main synchronization flow (M3 + M4)
-- ---------------------------------------------------------------------------

--- Query GET /status and surface server misconfiguration warnings.
-- Best-effort and non-fatal: a server too old to implement /status, or a
-- transient error, is ignored so it never blocks a sync.
function NextcloudNews.checkServerStatus(_self, api)
    local ok, result = api:getStatus()
    if not ok or type(result) ~= "table" then
        return
    end
    local warnings = result.warnings
    if type(warnings) ~= "table" then
        return
    end
    local msgs = {}
    if warnings.improperlyConfiguredCron then
        table.insert(msgs, _(
            "The News app updater is improperly configured on the server; " ..
            "feed updates may be missed."
        ))
    end
    if warnings.incorrectDbCharset then
        table.insert(msgs, _(
            "The server database charset is misconfigured; " ..
            "updates with unicode characters might fail."
        ))
    end
    if #msgs > 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Nextcloud News server warning:\n%1"), table.concat(msgs, "\n\n")),
        })
    end
end

function NextcloudNews:synchronize()
    local Trapper = require("ui/trapper")
    local api = self:getAPI()

    if not api:isConfigured() then
        Trapper:reset()
        UIManager:show(InfoMessage:new{ text = _("Please configure the server settings first.") })
        return
    end
    if not self:hasValidDownloadDir() then
        Trapper:reset()
        UIManager:show(InfoMessage:new{ text = _("Please set a valid download folder first.") })
        return
    end
    if not Epub.isAvailable() then
        Trapper:reset()
        UIManager:show(InfoMessage:new{
            text = _("The EPUB backend (from KOReader's News downloader plugin) is unavailable."),
        })
        return
    end

    -- 0. Surface server-side configuration warnings (best-effort, non-fatal).
    self:checkServerStatus(api)

    -- 1. Detect locally finished articles and push statuses.
    Trapper:info(_("Uploading reading statuses…"))
    self:queueFinishedArticles()
    local pushed = self:flushStatusQueue(api)

    -- 2. Fetch items, scoped to the selected folder/feed (or all).
    --    Incremental if we have a cursor, else an initial unread fetch.
    Trapper:info(_("Fetching article list…"))
    local qtype = self.filter_type or NewsAPI.TYPE_ALL
    local qid = self.filter_id or 0
    local ok, result, code
    if self.last_modified and self.last_modified > 0 then
        ok, result, code = api:getUpdatedItems(self.last_modified, qtype, qid)
    else
        ok, result, code = api:getItems({
            type = qtype,
            id = qid,
            getRead = false,
            batchSize = -1,
        })
    end
    if not ok then
        Trapper:reset()
        UIManager:show(InfoMessage:new{
            text = T(_("Could not fetch articles.\n%1"), self:describeError(result, code)),
        })
        return
    end

    local items = (result and result.items) or {}
    local local_articles = self:getLocalArticles()

    -- 3. Download/render new items; track latest lastModified seen.
    local download_count, skip_count, fail_count, del_count = 0, 0, 0, 0
    local newest_modified = self.last_modified or 0
    local total = #items
    local processed = 0

    for i = 1, #items do
        local item = items[i]
        processed = processed + 1
        local lm = tonumber(item.lastModified) or 0
        if lm > newest_modified then newest_modified = lm end

        local id_str = tostring(item.id)
        -- Track the server's starred state so device-side toggles know the
        -- correct direction (nil = not starred, true = starred).
        if item.starred ~= nil then
            self.starred_state[id_str] = item.starred or nil
        end
        if item.unread == false then
            -- Item is read on the server; optionally remove local file.
            if self.remove_read_locally and local_articles[id_str] then
                os.remove(local_articles[id_str])
                local_articles[id_str] = nil
                del_count = del_count + 1
            else
                skip_count = skip_count + 1
            end
        elseif local_articles[id_str] then
            -- Already downloaded.
            skip_count = skip_count + 1
        else
            if download_count >= self.articles_per_sync then
                skip_count = skip_count + 1
            else
                local msg = T(_("Downloading article %1 of %2…"), processed, total)
                Trapper:info(msg)
                local path = self:getArticlePath(item)
                local created, err = Epub.createFromItem(path, item, self.include_images, msg)
                if created then
                    download_count = download_count + 1
                    local_articles[id_str] = path
                else
                    logger.warn("NextcloudNews: failed to create EPUB for item", item.id, err)
                    fail_count = fail_count + 1
                end
            end
        end
    end

    -- 4. Persist the sync cursor.
    self.last_modified = newest_modified
    self.updated = true
    self:onFlushSettings()

    -- 5. Summary.
    Trapper:reset()
    local lines = { _("Synchronization finished.") }
    if pushed > 0 then
        table.insert(lines, T(N_("- statuses uploaded: 1", "- statuses uploaded: %1", pushed), pushed))
    end
    table.insert(lines, T(_("- downloaded: %1"), download_count))
    table.insert(lines, T(_("- skipped: %1"), skip_count))
    if del_count > 0 then
        table.insert(lines, T(_("- removed locally: %1"), del_count))
    end
    if fail_count > 0 then
        table.insert(lines, T(_("- failed: %1"), fail_count))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
    NetworkMgr:afterWifiAction()
end

-- ---------------------------------------------------------------------------
-- Settings dialogs
-- ---------------------------------------------------------------------------

function NextcloudNews:editServerSettings()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Nextcloud News server"),
        fields = {
            {
                text = self.server_url or "",
                hint = _("Server URL (e.g. https://cloud.example.com)"),
            },
            {
                text = self.username or "",
                hint = _("Username"),
            },
            {
                text = self.password or "",
                text_type = "password",
                hint = _("App password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        self.server_url = fields[1] ~= "" and fields[1] or nil
                        self.username   = fields[2] ~= "" and fields[2] or nil
                        self.password   = fields[3] ~= "" and fields[3] or nil
                        self.updated = true
                        self:onFlushSettings()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function NextcloudNews:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.directory = self.normalizeDownloadDir(path)
            self.updated = true
            self:onFlushSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir()
end

function NextcloudNews:setArticlesPerSync(touchmenu_instance)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Articles per sync"),
        value = self.articles_per_sync,
        value_min = 1,
        value_max = 500,
        value_step = 1,
        value_hold_step = 10,
        callback = function(spin)
            self.articles_per_sync = spin.value
            self.updated = true
            self:onFlushSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Folder / feed selection
-- ---------------------------------------------------------------------------

--- Human-readable description of the current filter, for menu display.
function NextcloudNews:getFilterLabel()
    if not self.filter_type or self.filter_id == nil then
        return _("All articles")
    end
    return self.filter_label or T(_("id %1"), tostring(self.filter_id))
end

--- Set the active folder/feed filter and reset the incremental cursor so the
-- next sync re-fetches for the new scope.
-- @tparam number|nil ftype NewsAPI.TYPE_FOLDER / TYPE_FEED, or nil for "all"
-- @tparam number|nil fid folder/feed id (nil for "all")
-- @tparam string|nil label cached display name
function NextcloudNews:setFilter(ftype, fid, label)
    self.filter_type = ftype
    self.filter_id = fid
    self.filter_label = label
    -- The cursor is scope-specific; reset it so we don't miss items.
    self.last_modified = 0
    self.updated = true
    self:onFlushSettings()
end

--- Fetch folders + feeds and present a chooser to scope synchronization.
-- Must be called online; gated by the caller.
function NextcloudNews:chooseFilter(touchmenu_instance)
    local api = self:getAPI()
    if not api:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Please configure the server settings first.") })
        return
    end

    local info = InfoMessage:new{ text = _("Loading folders and feeds…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok_folders, folders_res = api:getFolders()
    local ok_feeds, feeds_res = api:getFeeds()
    UIManager:close(info)

    if not ok_feeds then
        UIManager:show(InfoMessage:new{ text = _("Could not load feeds from the server.") })
        return
    end

    local folders = (ok_folders and folders_res and folders_res.folders) or {}
    local feeds = (feeds_res and feeds_res.feeds) or {}

    -- Map folderId -> folder name for grouping feed labels.
    local folder_name = {}
    for i = 1, #folders do
        local f = folders[i]
        folder_name[f.id] = f.name
    end

    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local menu
    local items = {}

    local function pick(ftype, fid, label)
        self:setFilter(ftype, fid, label)
        UIManager:close(menu)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(InfoMessage:new{
            text = T(_("Now syncing: %1"), label),
            timeout = 2,
        })
    end

    table.insert(items, {
        text = _("★ All articles"),
        callback = function() pick(nil, nil, _("All articles")) end,
    })
    for i = 1, #folders do
        local folder = folders[i]
        local fname = folder.name or _("(unnamed folder)")
        table.insert(items, {
            text = T(_("📁 %1"), fname),
            callback = function()
                pick(NewsAPI.TYPE_FOLDER, folder.id, T(_("Folder: %1"), fname))
            end,
        })
    end
    for i = 1, #feeds do
        local feed = feeds[i]
        local title = feed.title or _("(unnamed feed)")
        local parent = feed.folderId and folder_name[feed.folderId]
        local label = parent and T(_("%1 / %2"), parent, title) or title
        table.insert(items, {
            text = T(_("  %1"), label),
            callback = function()
                pick(NewsAPI.TYPE_FEED, feed.id, T(_("Feed: %1"), title))
            end,
        })
    end

    menu = Menu:new{
        title = _("Sync from folder/feed"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuClose = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return NextcloudNews
