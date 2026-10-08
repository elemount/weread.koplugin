-- Bookshelf, book, chapter, and search UI flows.
local BookReviews = require("weread.lib.book_reviews")
local BookReviewsView = require("weread.ui.book_reviews_view")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local External = require("weread.lib.external_annotations")
local ShelfGroups = require("weread.lib.shelf_groups")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weread.lib.logger")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}
local sortBooks

local function cover_subprocess_runner()
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or type(ffiutil.runInSubProcess) ~= "function" then return nil end
    return {
        run = function(callback) return ffiutil.runInSubProcess(callback, true) end,
        write_all = function(fd, data) return ffiutil.writeToFD(fd, data, true) end,
        is_done = function(pid) return ffiutil.isSubProcessDone(pid) end,
        terminate = function(pid) return ffiutil.terminateSubProcess(pid) end,
        read_all = function(fd) return ffiutil.readAllFromFD(fd) end,
    }
end

local local_cache_fields = {
    cache_dir = true,
    cached_file = true,
    cached_full_book = true,
    cached_chapters = true,
}

local function keep_local_cache(record)
    local local_record = {}
    for key, value in pairs(record or {}) do
        if local_cache_fields[key] then local_record[key] = value end
    end
    return local_record
end

local function has_book_details(book)
    if type(book) ~= "table" then return false end
    if tonumber(book.detail_updated_at or 0) > 0 then return true end
    for _, key in ipairs({
        "intro", "publisher", "isbn", "wordCount", "newRating",
        "translator", "categoryName", "publishTime",
    }) do
        if book[key] ~= nil and book[key] ~= "" then return true end
    end
    return false
end

local function list_items_per_page()
    local perpage = 14
    if G_reader_settings and G_reader_settings.readSetting then
        perpage = tonumber(G_reader_settings:readSetting("items_per_page")) or perpage
    end
    return math.max(4, perpage)
end

function M:showBookshelf()
    local cached = self.library_db and self.library_db:getShelf() or nil
    local archives = self.library_db and self.library_db:getShelfArchives() or nil
    if cached and (#cached > 0 or archives ~= nil) then
        self:applyShelfSnapshot(cached, archives)
        self:showShelfView("books")
        local shelf = self.settings:get("shelf")
        -- Only old caches lack archive metadata; an empty archive is current.
        if archives == nil and not shelf.groups_refresh_hint_shown then
            local view = self.shelf_view
            local hint = ConfirmBox:new{
                text = _("Get the latest bookshelf to show your WeRead book groups.\n\nYou can also do this later with the refresh button in the top bar."),
                ok_text = _("Get latest"), cancel_text = _("Later"),
                ok_callback = function()
                    UIManager:nextTick(function()
                        if self.shelf_view == view then view.on_refresh() end
                    end)
                end,
            }
            hint.movable[1].radius = 0
            UIManager:show(hint)
            shelf.groups_refresh_hint_shown = true
            self.settings:set("shelf", shelf)
            self.settings:flush()
        end
        return
    end
    self:refreshBookshelf()
end

function M:closeWeReadUI()
    -- Close from the topmost view down so no full-screen WeRead widget remains
    -- in UIManager's window stack after a document is opened.
    local seen = {}
    for _, field in ipairs({
        "_chapter_list_view",
        "_book_detail_view",
        "shelf_view",
    }) do
        local view = self[field]
        self[field] = nil
        if view and not seen[view] then
            seen[view] = true
            UIManager:close(view)
        end
    end
end

function M:onWeReadAccountChanged()
    self:closeWeReadUI()
    self.shelf_regular = nil
    self.shelf_books = nil
    self.shelf_groups = nil
    self.shelf_group_key = nil
    self.shelf_search_keyword = nil
    self.shelf_view_pages = nil
end

function M:applyShelfSnapshot(all_books, archives)
    local shelf = self.settings:get("shelf")
    self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
    self.shelf_regular = all_books or {}
    self.shelf_books = self.shelf_regular
    self.shelf_groups = ShelfGroups.list(archives, self.shelf_regular, _("Unnamed group"), _("Uncategorized"))
    if self.shelf_group_key and not ShelfGroups.find(self.shelf_groups, self.shelf_group_key) then
        self.shelf_group_key = nil
        if self.shelf_view_pages then self.shelf_view_pages.books = 1 end
    end
end

function M:refreshBookshelf(old_view, view_options)
    if self.shelf_refreshing or not self:requireLogin(true) then return end
    self.shelf_refreshing = true
    -- A finishing thumbnail batch must not replace the view being refreshed.
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    self.shelf_cover_pending = nil
    if old_view then old_view:setRefreshing(true) end
    local function done()
        self.shelf_refreshing = nil
        if old_view then old_view:setRefreshing(false) end
        self:closeBusy()
    end
    self:showBusy(_("Loading bookshelf..."))
    local started = self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:get_shelf()
        end)
        done()
        if not ok then
            logger.err("load bookshelf failed:", log_error(result))
            self:showInfo(T(
                _("Load bookshelf failed:\n%1\n\nIf other account features still work, use Search to find and download books."),
                display_error(result)
            ))
            return
        end
        local all_books = type(result) == "table"
            and type(result.books) == "table"
            and result.books
            or {}
        local archives = type(result) == "table" and type(result.archive) == "table" and result.archive or {}
        if self.library_db then self.library_db:cacheShelf(all_books, archives) end
        local old_group_key = self.shelf_group_key
        self:applyShelfSnapshot(all_books, archives)
        local next_options = {}
        for key, value in pairs(view_options or {}) do next_options[key] = value end
        next_options.prepared_shelf = nil
        if old_group_key ~= self.shelf_group_key then
            next_options.page, next_options.scroll_offset = 1, nil
        end
        if old_view then UIManager:close(old_view) end
        self:showShelfView(
            view_options and view_options.mode or self.shelf_view_mode or "books",
            view_options and view_options.keyword or nil,
            nil,
            next_options
        )
    end)
    if started == false then done() end
end

local function shelf_search_match(book, keyword)
    if not keyword or keyword == "" then return true end
    local needle = string.lower(keyword)
    for _, value in ipairs({ book.title, book.author, book.bookId, book.book_id }) do
        if type(value) == "string" and string.find(string.lower(value), needle, 1, true) then
            return true
        end
    end
    return false
end

local function shelf_page_items(items, page, page_size)
    items = type(items) == "table" and items or {}
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    local page_count = math.max(1, math.ceil(#items / page_size))
    page = math.max(1, math.min(math.floor(tonumber(page) or 1), page_count))
    local first = (page - 1) * page_size + 1
    local last = math.min(#items, first + page_size - 1)
    local result = {}
    for index = first, last do result[#result + 1] = items[index] end
    return result, page
end

-- The APK bookshelf publishes regular book covers as HTTPS resource URLs.
local function shelf_cover_url(book)
    local cover = type(book) == "table" and book.cover or nil
    if type(cover) ~= "string" then return nil end
    if cover:match("^https://wx%.qlogo%.") then return nil end
    if cover:match("^https://") then return cover end
    return nil
end

function M:getShelfCoverCache()
    if not self.shelf_cover_cache then
        local CoverCache = require("weread.lib.cover_cache")
        self.shelf_cover_cache = CoverCache:new(self.settings)
    end
    return self.shelf_cover_cache
end

function M:fetchVisibleShelfCovers(view, items, options)
    if not view or not items or #items == 0 then return end
    options = options or {}
    local cache = self:getShelfCoverCache()
    local visible = shelf_page_items(items, view.page, view.page_size or 6)
    local missing = {}
    local online = self:isNetworkOnline()
    for _, book in ipairs(visible) do
        if shelf_cover_url(book)
            and not cache:pathFor(book) then
            -- Legacy full-resolution cache entries can be converted while
            -- offline. A network request is only needed when no source exists.
            if online or cache:sourcePathFor(book) then
                missing[#missing + 1] = book
            end
        end
    end
    if #missing == 0 then return end

    if self.shelf_cover_job then
        -- Keep only the newest visible page while the current child exits.
        self.shelf_cover_pending = { view = view, items = items, options = options }
        return
    end

    local runner = self.shelf_cover_subprocess
    if runner == nil then
        runner = cover_subprocess_runner() or false
        self.shelf_cover_subprocess = runner
    end
    if not runner then
        logger.warn("bookshelf cover background worker is unavailable")
        return
    end

    local generation = self.shelf_cover_generation
    local index, changed = 1, false
    local function finish_batch()
        self.shelf_cover_job = nil
        if changed and generation == self.shelf_cover_generation and self.shelf_view == view then
            local pruned = pcall(cache.prune, cache)
            if not pruned then logger.warn("bookshelf cover cache pruning failed") end
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = {
                books = options.prepared_books or self.shelf_regular or {},
                    }
            next_options.page = view.page
            next_options.skip_cover_fetch_once = true
            self:showShelfView(options.mode or "books", options.keyword, view, next_options)
        end
        local pending = self.shelf_cover_pending
        self.shelf_cover_pending = nil
        if pending then
            self:fetchVisibleShelfCovers(pending.view, pending.items, pending.options)
        end
    end

    local function fetch_next()
        if generation ~= self.shelf_cover_generation or self.shelf_view ~= view then
            finish_batch()
            return
        end
        local book = missing[index]
        if not book then
            finish_batch()
            return
        end

        local pid, read_fd = runner.run(function(_pid, child_write_fd)
            local ok, path = pcall(cache.thumbnailFromCached, cache, book)
            if not (ok and path) and online then
                local downloaded, data = pcall(function()
                    return self.client:get_binary(shelf_cover_url(book), {
                        timeout = { 8, 12 },
                    })
                end)
                if downloaded then ok, path = pcall(cache.store, cache, book, data) end
            end
            runner.write_all(child_write_fd, ok and path and "ok" or "error")
        end)
        if not pid then
            logger.warn("bookshelf cover background worker failed to start")
            index = index + 1
            UIManager:scheduleIn(0.1, fetch_next)
            return
        end

        local job = { pid = pid, read_fd = read_fd, started_at = os.time() }
        self.shelf_cover_job = job
        local poll
        poll = function()
            if self.shelf_cover_job ~= job then return end
            if not runner.is_done(job.pid) then
                if os.time() - job.started_at > 30 then
                    runner.terminate(job.pid)
                end
                UIManager:scheduleIn(0.15, poll)
                return
            end
            local result = job.read_fd and runner.read_all(job.read_fd) or nil
            job.read_fd = nil
            self.shelf_cover_job = nil
            if result == "ok" and cache:pathFor(book) then
                changed = true
            else
                logger.warn("bookshelf cover background task failed")
            end
            index = index + 1
            fetch_next()
        end
        UIManager:scheduleIn(0.15, poll)
    end
    fetch_next()
end


function M:showShelfView(_mode, keyword, old_view, options)
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    local mode = "books"
    options.mode = mode
    options.keyword = keyword
    local skip_cover_fetch_once = options.skip_cover_fetch_once == true
    options.skip_cover_fetch_once = nil
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    self.shelf_view_mode = mode
    self.shelf_search_keyword = keyword
    self.shelf_view_pages = self.shelf_view_pages or { books = 1 }
    local saved_books = self.settings:get("books", {})
    local downloaded_cache = {}
    local function filtered(source, with_download_state)
        local result = {}
        local sorted = sortBooks(source or {}, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            local matches_filters = not with_download_state
                or self:bookMatchesFilters(book, saved_books, downloaded_cache)
            if matches_filters and shelf_search_match(book, keyword) then
                if with_download_state then
                    book._cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                end
                result[#result + 1] = book
            end
        end
        return result
    end
    local group = ShelfGroups.find(self.shelf_groups, self.shelf_group_key)
    local prepared = options.prepared_shelf
    local books = prepared and prepared.books or filtered(group and group.books or self.shelf_regular, true)
    local shelf_settings = self.settings:get("shelf")
    local cover_mode = shelf_settings.view_mode == "cover"
    local paged = cover_mode or shelf_settings.paginated ~= false
    local page = paged and (options.page or self.shelf_view_pages[mode] or 1) or 1
    local source = books
    local layout = LibraryView.getLayout(cover_mode, #source, mode)
    local cover_layout = cover_mode and layout or nil
    local page_size = layout.page_size
    local cover_paths, cover_loading
    if cover_mode then
        cover_paths = {}
        cover_loading = {}
        local cache = self:getShelfCoverCache()
        local online = self:isNetworkOnline()
        local visible, clamped_page = shelf_page_items(source, page, page_size)
        page = clamped_page
        for _, book in ipairs(visible) do
            local path = cache:pathFor(book)
            cover_paths[book] = path
            if not path and shelf_cover_url(book) then
                cover_loading[book] = online or cache:sourcePathFor(book) ~= nil
            end
        end
    end
    if old_view then UIManager:close(old_view) end
    local view
    view = LibraryView.show({
        mode = mode,
        title = options.title,
        books = books,
        groups = self.shelf_groups,
        group_key = self.shelf_group_key,
        group_label = group and group.label,
        total_books = #(self.shelf_regular or {}),
        scroll_offset = options.scroll_offset,
        keyword = keyword,
        sort_label = self:shelfSortSummary(),
        filter_label = self:shelfFilterSummary(),
        paged = paged,
        page = page,
        page_size = page_size,
        cover_mode = cover_mode,
        cover_columns = cover_layout and cover_layout.columns,
        cover_rows = cover_layout and cover_layout.rows,
        cover_cell_height = cover_layout and cover_layout.cell_height,
        cover_paths = cover_paths,
        cover_loading = cover_loading,
    }, {
        on_switch = function(new_mode)
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books }
            next_options.page = self.shelf_view_pages.books or 1
            next_options.scroll_offset = nil
            self:showShelfView(new_mode, keyword, view, next_options)
        end,
        on_select_group = function(key)
            if key and not ShelfGroups.find(self.shelf_groups, key) then return end
            self.shelf_group_key = key
            local next_options = {}
            for name, value in pairs(options) do next_options[name] = value end
            next_options.prepared_shelf, next_options.scroll_offset = nil, nil
            next_options.page = 1
            self:showShelfView("books", keyword, view, next_options)
        end,
        on_display_change = function(key, value)
            local shelf = self.settings:get("shelf")
            shelf[key] = value
            self.settings:set("shelf", shelf)
            self.settings:flush()
            options.page, options.scroll_offset = 1, nil
            self:showShelfView(mode, keyword, view, options)
        end,
        on_search = function()
            self:showShelfSearchDialog(view, mode, keyword, options)
        end,
        on_refresh = function()
            local refresh_options = {}
            for key, value in pairs(options) do refresh_options[key] = value end
            refresh_options.prepared_shelf = nil
            refresh_options.page = view.page
            refresh_options.scroll_offset = view:getScrollOffset()
            self:refreshBookshelf(view, refresh_options)
        end,
        on_sort = function()
            self:showShelfSortOptions(function()
                self.shelf_view_pages = { books = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_filter = function()
            self:showShelfFilterOptions(function()
                self.shelf_view_pages = { books = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_select = function(book, selected_mode)
            if options.on_select then
                options.on_select(book, selected_mode, view)
            else
                self:showBookRecord(book)
            end
        end,
        on_page_changed = function(new_page)
            self.shelf_view_pages[mode] = new_page
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books }
            next_options.page = new_page
            self:showShelfView(mode, keyword, view, next_options)
        end,
    })
    if paged then self.shelf_view_pages[mode] = view.page end
    self.shelf_view = view
    if cover_mode and not skip_cover_fetch_once then
        local fetch_options = {}
        for key, value in pairs(options) do fetch_options[key] = value end
        fetch_options.prepared_books = books
        self:fetchVisibleShelfCovers(view, source, fetch_options)
    end
end

function M:showShelfSearchDialog(view, mode, keyword, options)
    local dialog
    dialog = InputDialog:new{
        title = _("Search shelf"),
        input = keyword or "",
        input_type = "text",
        buttons = {{
            {
                text = _("Clear"),
                callback = self:safeCallback(_("Clear"), function()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1 }
                    options.prepared_shelf = nil
                    options.page, options.scroll_offset = 1, nil
                    self:showShelfView(mode, nil, view, options)
                end),
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = self:safeCallback(_("Search"), function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1 }
                    options.prepared_shelf = nil
                    options.page = 1
                    self:showShelfView(
                        mode, value ~= "" and value or nil, view, options
                    )
                end),
            },
        }},
    }
    self:showInputDialog(dialog)
end

sortBooks = function(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

function M:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    local function refresh()
        menu:switchItemTable(nil, buildItems())
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        local saved_books = self.settings:get("books", {})
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            if self:bookMatchesFilters(book, saved_books, downloaded_cache) then
                local book_id = book.book_id or book.bookId
                local is_cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                local right_text
                if book.readUpdateTime and book.readUpdateTime > 0 then
                    right_text = os.date("%Y-%m-%d", book.readUpdateTime)
                elseif book.finishReading == 1 then
                    right_text = _("Done")
                else
                    right_text = ""
                end
                local function rightStatus(cached)
                    if cached then
                        return right_text ~= "" and "✓  " .. right_text or "✓"
                    end
                    return right_text
                end
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    mandatory = rightStatus(is_cached),
                    mandatory_func = function()
                        local current = self._shelf_saved_books and self._shelf_saved_books[book_id]
                        return rightStatus(self:bookRecordHasDownload(current))
                    end,
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        return items
    end
    menu = self:showList(_("WeRead Bookshelf"), buildItems(), _("Your WeRead shelf is empty."))
    self.shelf_menu = menu
    self._shelf_refresh = refresh
end

function M:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn("refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function M:showBookRecord(book)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if not book_id then return end

    local account_key = self.library_db and self.library_db:accountKey() or nil
    local saved = books[book_id] or {}
    if account_key and saved._library_account_key
        and saved._library_account_key ~= account_key then
        saved = keep_local_cache(saved)
    end
    local cached = self.library_db and self.library_db:getBook(book_id) or nil
    for key, value in pairs(cached or {}) do
        if saved[key] == nil then saved[key] = value end
    end
    for key, value in pairs(book) do
        if value ~= nil and key ~= "_cached" then saved[key] = value end
    end
    saved.book_id = book_id
    saved._library_account_key = account_key
    saved.updated_at = saved.updated_at or os.time()
    books[book_id] = saved
    self.settings:set("books", books)
    self.settings:flush()
    if self.library_db then self.library_db:putBook(saved) end
    if type(saved.chapters) ~= "table" and self.library_db then
        saved.chapters = self.library_db:getChapters(book_id)
    end
    if not has_book_details(cached) then
        self:refreshBookRecord(saved, nil, { automatic = true })
    else
        self:showBookMenu(saved)
    end
end

function M:refreshBookRecord(book, old_view, options)
    options = options or {}
    if not self:requireLogin(true) then
        if options.automatic then self:showBookMenu(book) end
        return
    end
    local book_id = book.book_id or book.bookId
    if not self:isNetworkOnline() then
        if options.automatic then self:showBookMenu(book) end
        self:showOffline(_("Book info"))
        return
    end
    self:showBusy(_("Loading book info..."))
    local started = self:runOnlineTask(_("Book info"), function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                for key, value in pairs(info) do
                    if value ~= nil then book[key] = value end
                end
                book.categoryName = info.categoryName or info.category or book.categoryName
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                local remote = progress_result.book
                book.progress = remote.progress or book.progress or 0
                book.chapter_uid = remote.chapterUid or remote.chapterId
                    or remote.chapter_uid or book.chapter_uid
                book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex
                    or remote.chapter_idx) or tonumber(book.chapter_idx)
                book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos
                    or remote.offset) or tonumber(book.chapter_offset) or 0
            end
            book.book_id = book_id
            book._library_account_key = self.library_db
                and self.library_db:accountKey() or nil
            book.detail_updated_at = os.time()
            local books = self.settings:get("books", {})
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
            if self.library_db then self.library_db:putBook(book) end
        end)
        self:closeBusy()
        if not ok then
            logger.err("load book info failed:", log_error(err))
            if options.automatic then self:showBookMenu(book) end
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), display_error(err)))
            return
        end
        if old_view then UIManager:close(old_view) end
        self:showBookMenu(book)
        self:showTransientInfo(_("Book information updated."), 2)
    end)
    if started == false and options.automatic then self:showBookMenu(book) end
end

function M:showBookMenu(book)
    local BookDetailView = require("weread.ui.book_detail_view")
    local book_id = book.book_id or book.bookId
    if type(book.chapters) ~= "table" then
        book.chapters = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(book.chapters) ~= "table" then
            local legacy_catalog = Content.load_catalog_cache(self.client, self.settings, book)
            if legacy_catalog and self.library_db then
                self.library_db:putChapters(book_id, legacy_catalog)
            end
        end
    end
    local saved = self.settings:get("books", {})[book_id] or book
    local cached_path = self:getFullBookCachePath(saved)
    local is_full_cached = file_exists(cached_path)
    local has_cache = self:bookRecordHasDownload(saved)
    book.cached_full_book = is_full_cached and cached_path or nil
    local cached_chapter_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if file_exists(path) then cached_chapter_count = cached_chapter_count + 1 end
    end
    local total_chapters = type(book.chapters) == "table" and #book.chapters or nil
    if is_full_cached and cached_chapter_count == 0 and total_chapters then
        cached_chapter_count = total_chapters
    end
    local chapter_status = total_chapters
        and T(_("Cached %1/%2 chapters"), tostring(cached_chapter_count), tostring(total_chapters))
        or T(_("%1 chapters cached"), tostring(cached_chapter_count))

    local author_parts = {}
    if book.author and book.author ~= "" then author_parts[#author_parts + 1] = book.author end
    if book.translator and book.translator ~= "" then
        author_parts[#author_parts + 1] = T(_("Translated by %1"), book.translator)
    end
    local statuses = {}
    if book.progress and book.progress > 0 then
        statuses[#statuses + 1] = T(_("Progress %1%"), tostring(book.progress))
    end
    statuses[#statuses + 1] = chapter_status

    local metadata = {}
    local function format_field(label, value)
        if value == nil or value == "" then return nil end
        return T(_("%1: %2"), tostring(label), tostring(value))
    end
    local function add_row(left_label, left_value, right_label, right_value)
        local left = format_field(left_label, left_value)
        local right = format_field(right_label, right_value)
        if left or right then metadata[#metadata + 1] = { left = left, right = right } end
    end
    local word_count
    if book.wordCount and book.wordCount > 0 then
        word_count = book.wordCount >= 10000
            and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
            or tostring(book.wordCount)
    end
    local rating
    if book.newRating and book.newRating > 0 then
        local score = string.format("%.1f", book.newRating / 100)
        rating = T(_("%1 (%2 ratings)"), score, tostring(book.newRatingCount or 0))
    end
    add_row(_("Publisher"), book.publisher,
        _("Publication date"), BookReviews.format_date(book.publishTime))
    local category = format_field(_("Category"), book.categoryName)
    if category then metadata[#metadata + 1] = { text = category } end
    local words = format_field(_("Word count"), word_count)
    if words then metadata[#metadata + 1] = { text = words } end
    add_row("ISBN", book.isbn, _("Rating"), rating)

    local view
    local open_chapter_list = self:safeCallback(_("Chapter list"), function()
        self:showChapterList(book, function()
            local latest = self.settings:get("books", {})[book_id] or book
            if view then UIManager:close(view) end
            self:showBookMenu(latest)
        end)
    end)
    local review_action = {
        text = _("Recommended / Latest"),
        callback = self:safeCallback(_("Book reviews"), function()
            self:showBookReviews(book)
        end),
    }
    local actions = {}
    if has_cache then
        actions[#actions + 1] = {
            text = _("Clear book cache"),
            callback = self:safeCallback(_("Clear book cache"), function()
                self:confirmClearBookCache(book_id, book.title or book_id, function()
                    book.cached_file = nil
                    book.cached_full_book = nil
                    book.cached_chapters = nil
                    book.cache_dir = nil
                    if view then UIManager:close(view) end
                    self:showBookMenu(book)
                end)
            end),
        }
    end
    local updated = book.detail_updated_at
        and os.date("%Y-%m-%d %H:%M", book.detail_updated_at) or _("Never updated")
    local bottom_actions = {
        {
            text = _("⇩ Download full book"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        },
        {
            text = _("☷ Chapter list"),
            callback = open_chapter_list,
        },
        {
            text = _("▤ Read"),
            callback = self:safeCallback(_("Read"), function()
                self:openBookForReading(book)
            end),
        },
    }
    view = BookDetailView.show({
        title = book.title or _("Book details"),
        author_line = table.concat(author_parts, "  ·  "),
        status_line = table.concat(statuses, "  ·  "),
        refresh_label = _("↻ Get latest information"),
        refresh_date = updated,
        metadata = metadata,
        intro = book.intro,
        review_action = review_action,
        actions = actions,
        bottom_actions = bottom_actions,
    }, {
        on_refresh = self:safeCallback(_("Get latest information"), function()
            self:refreshBookRecord(book, view)
        end),
    })
    self._book_detail_view = view
    return view
end

function M:showBookReviewDetail(book, review, mode)
    local author = review.author ~= "" and review.author or _("Anonymous")
    local metadata = {}
    if review.rating > 0 then
        metadata[#metadata + 1] = T(
            _("Score %1"), BookReviews.format_rating(review.rating)
        )
    end
    local review_date = BookReviews.format_date(review.create_time)
    if review_date ~= "" then
        metadata[#metadata + 1] = review_date
    end
    if review.is_finish then
        metadata[#metadata + 1] = _("Finished")
    end

    local text = {}
    text[#text + 1] = "《" .. tostring(book.title or _("Untitled")) .. "》"
    text[#text + 1] = author
    if #metadata > 0 then
        text[#text + 1] = table.concat(metadata, " · ")
    end
    text[#text + 1] = ""
    text[#text + 1] = review.content ~= "" and review.content or _("No review content.")

    UIManager:show(TextViewer:new{
        title = mode == "latest" and _("Latest review") or _("Recommended review"),
        text = table.concat(text, "\n"),
        text_type = "general",
        auto_para_direction = true,
    })
end

function M:showBookReviews(book)
    if not self:requireLogin(true) then
        return
    end
    local book_id = book.book_id or book.bookId
    local session = {
        cache = {},
    }

    local loadReviews
    loadReviews = function(mode, old_view)
        local function showResult(result)
            if old_view then
                UIManager:close(old_view)
            end
            local view
            view = BookReviewsView.show({
                book_title = book.title or _("Untitled"),
                mode = mode,
                result = result,
            }, {
                on_switch = function(new_mode)
                    loadReviews(new_mode, view)
                end,
                on_select = function(review, selected_mode)
                    self:showBookReviewDetail(book, review, selected_mode)
                end,
            })
        end

        if session.cache[mode] then
            showResult(session.cache[mode])
            return
        end
        self:showBusy(_("Loading book reviews..."))
        self:runOnlineTask(_("Book reviews"), function()
            local ok, result = pcall(function()
                local list_type = mode == "latest" and 3 or 1
                return BookReviews.normalize_list(
                    self.client:get_book_reviews(book_id, list_type, 20)
                )
            end)
            self:closeBusy()
            if not ok then
                logger.err("load book reviews failed:", log_error(result))
                self:showInfo(T(_("%1 failed:\n%2"), _("Book reviews"), display_error(result)))
                return
            end
            session.cache[mode] = result
            showResult(result)
        end)
    end

    loadReviews("recommended", nil)
end

function M:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            local book_id = book.book_id or book.bookId
            if self.library_db and book_id then
                self.library_db:putChapters(book_id, book.chapters)
            end
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, book.chapters)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
            callback(book.chapters)
            return
        end
        local book_id = book.book_id or book.bookId
        local cached = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(cached) == "table" and #cached > 0 then
            book.chapters = cached
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, cached)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
        else
            cached = Content.load_catalog_cache(self.client, self.settings, book)
            if type(cached) == "table" and #cached > 0 and self.library_db then
                self.library_db:putChapters(book_id, cached)
            end
        end
        if type(cached) == "table" and #cached > 0 then
            callback(cached)
            return
        end
    end
    if not self:requireLogin(true) then
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_book_info(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err("load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            if self.library_db then
                self.library_db:putChapters(book_id, chapters_or_err)
                self.library_db:putBook(book)
            end
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function M:showChapterList(book, on_close)
    local ChapterListView = require("weread.ui.chapter_list_view")
    local function reloadBookCache()
        if not self.settings then return end
        local book_id = book.book_id or book.bookId
        local latest = book_id and self.settings:get("books", {})[book_id]
        if type(latest) ~= "table" then return end
        for field in pairs(local_cache_fields) do
            if latest[field] ~= nil then book[field] = latest[field] end
        end
        if self.library_db then self.library_db:putBook(latest) end
    end
    local showCatalog
    showCatalog = function(chapters, old_view)
        -- Downloads persist their cache paths before invoking on_complete.
        -- Always rebuild from that persisted record instead of the snapshot
        -- captured when the chapter list was first opened.
        reloadBookCache()
        local rows = {}
        local book_key = tostring(book.book_id or book.bookId or "")
        local failed_prefetches = self._prefetch_failures
            and self._prefetch_failures[book_key] or {}
        for _i, chapter in ipairs(chapters) do
            local chapter_uid = chapter.chapterUid or chapter.chapterId
            local chapter_key = tostring(chapter_uid or "")
            local cached = book.cached_chapters
                and book.cached_chapters[chapter_key]
            if cached and not file_exists(cached) then
                book.cached_chapters[chapter_key] = nil
                cached = nil
            end
            local prefetching = self.downloader
                and self.downloader:isPrefetching(book, chapter)
            rows[#rows + 1] = {
                title = chapter.title or T(_("Chapter %1"), tostring(chapter_uid)),
                status = cached and _("Cached")
                    or prefetching and _("Prefetching")
                    or failed_prefetches[chapter_key]
                        and _("Prefetch failed")
                    or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                source = chapter,
            }
        end
        if old_view then
            UIManager:close(old_view)
            if self._chapter_list_view == old_view then
                self._chapter_list_view = nil
            end
        end
        local view
        view = ChapterListView.show({
            title = book.title or _("Chapter list"),
            chapters = rows,
        }, {
            on_refresh = self:safeCallback(_("Refresh chapter list"), function()
                self:loadChapters(book, function(refreshed_chapters)
                    showCatalog(refreshed_chapters, view)
                    self:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                        tostring(#refreshed_chapters)), 2)
                end, true)
            end),
            on_select_download = self:safeCallback(_("Select chapters to download"), function()
                self:showChapterDownloadSelection(book, chapters, function()
                    showCatalog(chapters, view)
                end)
            end),
            on_select = function(chapter)
                self:openChapter(book, chapter, function()
                    -- The downloader has persisted the new chapter path before
                    -- this callback runs. Rebuild beneath the completion dialog
                    -- so either "Read now" or "Close" leaves current cache state.
                    UIManager:scheduleIn(0.1, function()
                        showCatalog(chapters, view)
                    end)
                end)
            end,
            on_close = function()
                if self._chapter_list_view == view then
                    self._chapter_list_view = nil
                end
                if on_close then on_close() end
            end,
        })
        self._chapter_list_view = view
    end
    self:loadChapters(book, function(chapters)
        showCatalog(chapters)
    end)
end

function M:showChapterDownloadSelection(book, chapters, on_downloaded)
    local selected = {}
    local menu
    local function selectedChapters()
        local result = {}
        for _i, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or _i)
            if selected[uid] then
                result[#result + 1] = chapter
            end
        end
        return result
    end
    local function selectedCount()
        local count = 0
        for _uid in pairs(selected) do count = count + 1 end
        return count
    end

    local items = {}
    local perpage = list_items_per_page()
    local chapters_per_page = math.max(1, perpage - 1)
    local function appendDownloadAction()
        items[#items + 1] = {
            text_func = function()
                return T(_("[Download] Selected chapters (%1)"),
                    tostring(selectedCount()))
            end,
            bold = true,
            select_enabled_func = function() return selectedCount() > 0 end,
            separator = true,
            callback = self:safeCallback(_("Download selected chapters"), function()
                local targets = selectedChapters()
                if #targets == 0 then return end
                self:confirmAndDownloadChapters(book, targets, "chapters", {
                    separate_chapters = true,
                    on_complete = function(ok)
                        if not ok then return end
                        UIManager:scheduleIn(0.1, function()
                            if menu then UIManager:close(menu) end
                            if on_downloaded then on_downloaded() end
                        end)
                    end,
                })
            end),
        }
    end
    for page_start = 1, #chapters, chapters_per_page do
        appendDownloadAction()
        local page_end = math.min(#chapters, page_start + chapters_per_page - 1)
        for chapter_index = page_start, page_end do
            local chapter = chapters[chapter_index]
            local uid = tostring(chapter.chapterUid or chapter.chapterId or chapter_index)
            local cached = book.cached_chapters and book.cached_chapters[uid]
            local is_cached = file_exists(cached)
            items[#items + 1] = {
                text_func = function()
                    local marker = selected[uid] and "[✓] " or "[  ] "
                    return marker .. (chapter.title or T(_("Chapter %1"), uid))
                end,
                mandatory_func = function()
                    if selected[uid] then return _("Selected") end
                    return is_cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0))
                end,
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if selected[uid] then
                        selected[uid] = nil
                    else
                        selected[uid] = true
                    end
                    if menu then menu:updateItems() end
                end),
            }
        end
    end
    menu = self:showList(_("Select chapters to download"), items,
        _("No chapters."), { items_per_page = perpage })
end

function M:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    self:closeWeReadUI()
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function M:openCachedBook(book)
    self:openFile(self:getFullBookCachePath(book))
end

-- Open the book for reading. A complete EPUB wins; otherwise resume at the
-- chapter recorded in KOReader's local reading position, downloading it on
-- demand when it is not cached yet. A new book starts at chapter one.
function M:openBookForReading(book)
    local full_path = self:getFullBookCachePath(book)
    if file_exists(full_path) then
        self:openFile(full_path)
        return true
    end

    local book_id = book.book_id or book.bookId
    local chapters = book.chapters
    if type(chapters) ~= "table" and self.library_db then
        chapters = self.library_db:getChapters(book_id)
        if chapters then book.chapters = chapters end
    end
    if type(chapters) ~= "table" then
        chapters = Content.load_catalog_cache(self.client, self.settings, book)
    end
    if type(chapters) == "table" and #chapters > 0 then
        local local_position = book.last_local_position
        local local_uid = type(local_position) == "table"
            and (local_position.current_chapter_uid or local_position.chapter_uid)
        local local_chapter_idx = type(local_position) == "table"
            and tonumber(local_position.chapter_idx) or nil
        local function index_for_chapter(uid, chapter_idx)
            for index, chapter in ipairs(chapters) do
                local chapter_uid = chapter.chapterUid or chapter.chapterId
                if uid ~= nil and tostring(chapter_uid or "") == tostring(uid) then
                    return index
                end
            end
            for index, chapter in ipairs(chapters) do
                local catalog_idx = tonumber(chapter.chapterIdx or chapter.chapterIndex)
                if chapter_idx and catalog_idx == chapter_idx then
                    return index
                end
            end
            return nil
        end

        local function index_for_percent(percent)
            if not tonumber(percent) then return nil end
            local fraction = math.max(0, math.min(100, tonumber(percent))) / 100
            local total_words = 0
            for _index, chapter in ipairs(chapters) do
                total_words = total_words + math.max(0,
                    tonumber(chapter.wordCount or chapter.word_count) or 0)
            end
            if total_words > 0 then
                local target_words = fraction * total_words
                local seen_words = 0
                for index, chapter in ipairs(chapters) do
                    seen_words = seen_words + math.max(0,
                        tonumber(chapter.wordCount or chapter.word_count) or 0)
                    if target_words < seen_words or index == #chapters then
                        return index
                    end
                end
            else
                return math.floor(fraction * (#chapters - 1)) + 1
            end
            return nil
        end

        -- Resume from KOReader's saved chapter first. If there is no usable
        -- local position, use WeRead's saved cloud chapter/progress; a new
        -- book with neither position starts at the first chapter.
        local target_index = index_for_chapter(local_uid, local_chapter_idx)
            or index_for_percent(type(local_position) == "table"
                and local_position.percent)
        if not target_index then
            target_index = index_for_chapter(book.chapter_uid, book.chapter_idx)
                or index_for_percent(book.progress)
        end

        self:openChapter(book, chapters[target_index or 1])
        return true
    end
    self:loadChapters(book, function(loaded_chapters)
        if type(loaded_chapters) == "table" and #loaded_chapters > 0 then
            self:openBookForReading(book)
        else
            self:showInfo(_("No readable chapter found"))
        end
    end)
    return true
end

-- Open a chapter, preferring its cached file and falling back to a download.
function M:openChapter(book, chapter, on_downloaded)
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
    elseif self.downloader:promotePrefetch(book, chapter) then
        -- The downloader promotes the background task to a visible progress
        -- dialog and opens the chapter as soon as the same task completes.
        return
    else
        local book_key = tostring(book.book_id or book.bookId or "")
        if self._prefetch_failures and self._prefetch_failures[book_key] then
            self._prefetch_failures[book_key][tostring(chapter_uid)] = nil
        end
        self:downloadChapterAndRead(book, chapter, on_downloaded)
    end
end

-- Open a chapter selected by cloud-progress resolution. Unlike ordinary
-- chapter navigation, a missing target must be confirmed explicitly and then
-- opened automatically so ProgressSync can apply its pending in-chapter jump
-- in the next onReaderReady event.
function M:openProgressTargetChapter(book, chapter)
    if type(book) ~= "table" or type(chapter) ~= "table" then
        return false, "target_chapter_unavailable"
    end
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = chapter_uid and book.cached_chapters
        and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
        return true
    end

    local title = chapter.title
        or T(_("Chapter %1"), tostring(chapter_uid or ""))
    local confirm
    confirm = ConfirmBox:new{
        text = T(_(
            "Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\n"
            .. "Download and open it now?"
        ), title),
        ok_text = _("Download target chapter"),
        ok_callback = self:safeCallback(_("Download target chapter"), function()
            UIManager:close(confirm)
            self.downloader:start(book, { chapter }, "chapter", {
                single_chapter = true,
                open_on_complete = true,
                on_complete = function(ok, reason)
                    if not ok and self.progress_sync then
                        self.progress_sync:cancel_pending_jump(reason)
                    end
                end,
            })
        end),
        cancel_text = _("Cancel"),
        cancel_callback = function()
            if self.progress_sync then
                self.progress_sync:cancel_pending_jump(
                    "target_chapter_download_cancelled")
            end
        end,
    }
    UIManager:show(confirm)
    return true
end

function M:downloadChapterAndRead(book, chapter, on_downloaded)
    -- Selecting a chapter to read (including the next-chapter action at the
    -- end of a document) is already an explicit request to open it. Download
    -- just this chapter and hand it straight to KOReader when it is ready;
    -- keep confirmation for download-only actions and full-book downloads.
    self.downloader:start(book, { chapter }, "chapter", {
        single_chapter = true,
        open_on_complete = true,
        on_complete = function(ok, path)
            if ok and on_downloaded then on_downloaded(path) end
        end,
    })
end

function M:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- Annotation matching is a reading action, shared by all download forms.
function M:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local text = options.confirmation_text
        or T(_("Download %1 selected chapter(s)?"), tostring(#chapters))
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Download"), cancel_text = _("Cancel"),
        ok_callback = self:safeCallback(_("Download"), function()
            self.downloader:start(book, chapters, suffix, options)
        end),
    })
end

function M:pullProgressWithUI(book_id)
    if not self:requireLogin(true) then
        return
    end
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function M:showSearch()
    if not self:requireLogin(true) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function M:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:search_books(keyword, 10)
        end)
        if not ok then
            logger.err("search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for _i, match in ipairs(External.normalize_search(result)) do
            local book = match.source
            table.insert(items, {
                text = match.title ~= "" and match.title or match.book_id,
                post_text = match.author,
                mandatory = book.category or book.categoryName or "",
                callback = self:safeCallback(match.title ~= "" and match.title or match.book_id, function()
                    self:showBookRecord(book)
                end),
            })
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function M:showCurrentBookDetails()
    local book_id = self:detectWeReadBook()
    local book = book_id and self.settings:get("books", {})[book_id] or nil
    if not book then
        self:showInfo(_("The current document is not a WeRead cached book."))
        return
    end
    book.book_id = book.book_id or book_id
    self:showBookRecord(book)
end

return M
