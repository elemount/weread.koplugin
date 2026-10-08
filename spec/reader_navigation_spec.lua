-- Focused checks for previous/next chapter navigation and chapter position.

package.path = "./?.lua;" .. package.path

local dialog_options
local dialog_callbacks
package.preload["weread.ui.end_of_book_dialog"] = function()
    return {
        show = function(options, callbacks)
            dialog_options = options
            dialog_callbacks = callbacks
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local Navigation = require("weread.ui.reader_navigation")
local chapters = {
    { chapterUid = "1", title = "One" },
    { chapterUid = "2", title = "Two" },
    { chapterUid = "3", title = "Three" },
}
local opened
local host = {
    ui = { document = { file = "/cache/two.epub" } },
    settings = {
        get = function(_self, key)
            if key == "books" then return { book = { chapters = chapters } } end
            if key == "cache" then return {} end
        end,
    },
    ensureChaptersLoaded = function() return chapters end,
    getChapterInfoFromFile = function(_self, _book, _path)
        return 2, chapters[2], false
    end,
    detectWeReadBook = function() return "book" end,
    openChapter = function(_self, _book, chapter) opened = chapter end,
    showTransientInfo = function() end,
}
for key, value in pairs(Navigation) do host[key] = value end

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

host:showEndOfBookDialog("book")
expect(dialog_options.chapter_position == "Chapter 2 of 3",
    "quick menu includes the current chapter position")
expect(dialog_options.enable_previous_chapter
        and dialog_options.enable_next_chapter,
    "both adjacent chapters are enabled when available")
dialog_callbacks.on_previous()
expect(opened == chapters[1], "previous chapter opens the preceding chapter")
dialog_callbacks.on_next()
expect(opened == chapters[3], "next chapter opens the following chapter")

host.getChapterInfoFromFile = function() return 1, chapters[1], false end
host:showEndOfBookDialog("book")
expect(dialog_options.enable_previous_chapter == false,
    "previous chapter is disabled at the start of the book")

print(string.format(
    "reader_navigation_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
