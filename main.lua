local Event = require("ui/event")
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("weread.lib.client")
local BackgroundWorker = require("weread.lib.background_worker")
local Content = require("weread.lib.content")
local Downloader = require("weread.lib.downloader")
local ExternalAnnotationsDB = require("weread.lib.external_annotations_db")
local Integrations = require("integrations.init")
local LibraryDB = require("weread.lib.library_db")
local Mixin = require("weread.lib.mixin")
local Migrations = require("weread.lib.migrations")
local PluginUtil = require("weread.lib.plugin_util")
local ProgressSync = require("weread.lib.progress_sync")
local ProgressSyncDialog = require("weread.ui.progress_sync_dialog")
local QRLogin = require("weread.lib.qr_login")
local Settings = require("weread.lib.settings")
local Updater = require("weread.lib.updater")
local UpdaterUI = require("weread.ui.updater")

local _ = PluginUtil.tr

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "1.7.6",
}

-- Stable entry point used by third-party launchers such as SimpleUI and ZenUI.
function WeReadPlugin:openBookshelf()
    return self:showBookshelf()
end

-- Both SimpleUI and ZenUI discover conventional plugin launch methods.
function WeReadPlugin:launch()
    return self:openBookshelf()
end

function WeReadPlugin:onZenUIReady()
    Integrations.onZenUIReady(self)
    return true
end

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.external_annotations_db = ExternalAnnotationsDB:new(self.settings)
    self.library_db = LibraryDB:new(self.settings)
    local updater = Updater:new{
        settings = self.settings,
        current_version = self.version,
    }
    self.updater = UpdaterUI:new{
        updater = updater,
        settings = self.settings,
        is_connected = function()
            return self:isNetworkConnected()
        end,
        refresh_ui = function()
            self:refreshUI()
        end,
    }
    self.client = Client:new(self.settings)
    self.prefetch_worker = BackgroundWorker:new{
        temp_dir = self.settings.data_dir .. "/workers",
        -- A soft launch gate, not a reservation: fork uses copy-on-write and
        -- normally consumes far less than this on a 512 MB Kindle.
        min_available_kb = 64 * 1024,
    }
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        background_worker = self.prefetch_worker,
        show_info       = function(text) self:showInfo(text) end,
        show_transient  = function(text, timeout) self:showTransientInfo(text, timeout) end,
        refresh_ui      = function() self:refreshUI() end,
        refresh_shelf   = function() self:refreshShelfCacheIndicators() end,
        open_file       = function(path) self:openFile(path) end,
        safe_callback   = function(label, fn) return self:safeCallback(label, fn) end,
        require_login   = function(authenticated) return self:requireLogin(authenticated) end,
        run_online_task = function(label, fn)
            return self:runOnlineTask(label, fn)
        end,
        is_connected = function()
            return self:isNetworkConnected()
        end,
    }
    Migrations.run(self.settings, self.client)
    self.external_annotations_db:migrateLegacySettings()
    if self.downloader.recover then
        self.downloader:recover()
    end
    self.qr_login = QRLogin:new(self, self.client, self.settings)
    self.progress_sync = ProgressSync:new{
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_footer = function()
            return self.ui and self.ui.view and self.ui.view.footer
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        get_book = function(book_id)
            return self.settings:get("books", {})[tostring(book_id)]
        end,
        get_chapters = function(book)
            return self:ensureChaptersLoaded(book)
        end,
        refresh_catalog = function(book_id)
            local book = self.settings:get("books", {})[tostring(book_id)]
            if type(book) ~= "table" then
                return nil, "book_not_found"
            end
            local ok, chapters_or_err = pcall(function()
                Content.ensure_book_info(self.client, book)
                return Content.fetch_catalog(self.client, book)
            end)
            if not ok then
                return nil, chapters_or_err
            end
            local chapters = chapters_or_err
            if type(chapters) ~= "table" or #chapters == 0 then
                return nil, "catalog_unavailable"
            end
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    PluginUtil.log_error(cache_err))
            end
            if self.library_db then
                self.library_db:putChapters(book_id, chapters)
            end
            return chapters
        end,
        get_file_context = function(book, path)
            return self:getChapterInfoFromFile(book, path)
        end,
        run_online = function(_kind, callback, run_options)
            return self:runOnlineTask(
                _("Sync progress"), callback, nil, run_options)
        end,
        goto_fraction = function(fraction)
            local percent = math.floor(
                math.max(0, math.min(1, tonumber(fraction) or 0))
                    * 100 + 0.5)
            return pcall(function()
                if self.ui and self.ui.rolling
                    and self.ui.rolling.onGotoPercent then
                    self.ui.rolling:onGotoPercent(percent)
                elseif self.ui then
                    self.ui:handleEvent(Event:new("GotoPercent", percent))
                else
                    error("reader unavailable")
                end
            end)
        end,
        open_chapter = function(book, chapter)
            return self:openProgressTargetChapter(book, chapter)
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_choice = function(context)
            ProgressSyncDialog.show_choice(context)
        end,
        notify = function(code, data)
            ProgressSyncDialog.notify(code, data)
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.integrations = Integrations
    self.integrations.register(self)
    self._reader_session_gen = 0
    logger.info("initialized:", "version=", self.version)
    updater:cleanup_backup()
end

Mixin.apply(WeReadPlugin, {
    (require("weread.ui.common")),
    (require("weread.ui.menu")),
    (require("weread.ui.cache")),
    (require("weread.ui.library")),
    (require("weread.ui.annotations_controller")),
    (require("weread.ui.xpointer_overlay_controller")),
    (require("weread.ui.annotation_sync_controller")),
    (require("weread.ui.reader_navigation")),
    (require("weread.lib.reader_lifecycle")),
})

return WeReadPlugin
