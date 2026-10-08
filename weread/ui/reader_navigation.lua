-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")

local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

-- Dispatcher entry point used by KOReader gesture/profile actions. The quick
-- menu is a global WeRead entry point; actions that need a current WeRead book
-- explain why they are unavailable when invoked from another document.
function M:onShowWeReadQuickMenu()
    return self:showEndOfBookDialog(self:detectWeReadBook())
end

-- Dispatcher entry point for a gesture that opens the WeRead bookshelf from
-- any document currently open in KOReader.
function M:onShowWeReadBookshelf()
    self:showBookshelf()
    return true
end

function M:onShowWeReadLocalBookshelf()
    self:showWereadCollection()
    return true
end


function M:onShowWeReadSearch()
    self:showSearch()
    return true
end

function M:showEndOfBookDialog(book_id)
    local file_path = self.ui.document and self.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = book_id and (books[tostring(book_id)] or books[book_id]) or nil
    local is_regular_weread_book = book ~= nil
    local chapters = is_regular_weread_book and self:ensureChaptersLoaded(book) or nil

    local current_idx, is_full_book
    if chapters then
        local chapter_info = { self:getChapterInfoFromFile(book, file_path) }
        current_idx, is_full_book = chapter_info[1], chapter_info[3]
    end
    -- Chapter navigation is available only for a mapped single-chapter file.
    -- Full-book EPUBs have their own TOC and are left to KOReader's navigation.
    local is_single_chapter = current_idx ~= nil and not is_full_book
    local previous_chapter = is_single_chapter and chapters[current_idx - 1] or nil
    local next_chapter = current_idx and not is_full_book
        and chapters[current_idx + 1] or nil

    local function show_context_required()
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
    end

    -- Keep the reader quick menu in sync with the global display preference.
    -- Document-level matching may be incomplete while chapters are being
    -- prepared, but the user's show/hide choice is still authoritative here.
    local cache = self.settings:get("cache", {})
    local annotations_visible = cache.show_annotations ~= false
    EndOfBookDialog.show({
        show_chapter_nav = true,
        show_next_chapter = true,
        show_previous_chapter = true,
        chapter_position = is_single_chapter
            and T(_("Chapter %1 of %2"),
                tostring(current_idx), tostring(#chapters)) or nil,
        enable_chapter_list = chapters ~= nil,
        enable_previous_chapter = previous_chapter ~= nil,
        enable_next_chapter = next_chapter ~= nil,
        enable_book_details = book ~= nil,
        enable_sync_progress = is_regular_weread_book,
        annotations_visible = annotations_visible,
    }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_chapter_list = function()
            if chapters then
                self:showChapterList(book)
            else
                show_context_required()
            end
        end,
        on_next = function()
            if next_chapter then
                self:openChapter(book, next_chapter)
            elseif is_regular_weread_book then
                self:showTransientInfo(_("You have reached the last chapter."), 1)
            else
                show_context_required()
            end
        end,
        on_previous = function()
            if previous_chapter then
                self:openChapter(book, previous_chapter)
            elseif is_regular_weread_book then
                self:showTransientInfo(_("You are at the first chapter."), 1)
            else
                show_context_required()
            end
        end,
        on_book_details = function()
            if book then
                self:showCurrentBookDetails()
            else
                show_context_required()
            end
        end,
        on_sync_progress = function()
            if is_regular_weread_book then
                self:onWeReadSyncProgress()
            else
                show_context_required()
            end
        end,
        on_toggle_annotations = function()
            self:toggleAnnotationVisibility()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

return M
