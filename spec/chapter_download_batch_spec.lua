-- Coverage for format-specific native chapter batching and TXT batch payloads.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local Content = require("weread.lib.content")
local NativeChapter = require("weread.lib.native_chapter")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

expect(Content.chapter_download_batch_size({ format = "epub" }) == 5,
    "EPUB requests should batch five chapters")
expect(Content.chapter_download_batch_size({ format = "EPUB" }) == 5,
    "EPUB batch detection should ignore case")
expect(Content.chapter_download_batch_size({ format = "epub", type = 5 }) == 1,
    "WeRead comic type should request one chapter at a time")
expect(Content.chapter_download_batch_size({ book_type = 5 }) == 1,
    "legacy comic type field should request one chapter at a time")
expect(Content.chapter_download_batch_size({ isComic = true }) == 1,
    "comic flag should request one chapter at a time")
expect(Content.chapter_download_batch_size({ format = "manga" }) == 1,
    "manga format should request one chapter at a time")
expect(Content.chapter_download_batch_size({ category = "漫画" }) == 1,
    "Chinese comic category should request one chapter at a time")
expect(Content.chapter_download_batch_size({ format = "txt" }) == 25,
    "TXT requests should batch twenty-five chapters")
expect(Content.chapter_download_batch_size({ format = "pdf" }) == 25,
    "other formats should batch twenty-five chapters")

local function tar_entry(name, data)
    local header = string.rep("\0", 512)
    header = name .. header:sub(#name + 1)
    local size = string.format("%011o\0", #data)
    header = header:sub(1, 124) .. size .. header:sub(137)
    header = header:sub(1, 156) .. "0" .. header:sub(158)
    local padding = (512 - (#data % 512)) % 512
    return header .. data .. string.rep("\0", padding)
end

local requested
local client = {
    native_get_binary = function(_self, path, params, options)
        requested = { path = path, params = params, options = options }
        return table.concat({
            tar_entry("42_10", "chapter ten"),
            tar_entry("42_11", "chapter eleven"),
            tar_entry("42_12", "chapter twelve"),
            string.rep("\0", 1024),
        })
    end,
}
local chapters = {
    { chapterUid = 12 },
    { chapterUid = 10 },
    { chapterUid = 11 },
}
local payloads = NativeChapter.fetch_batch(client, {
    book_id = "42",
    format = "txt",
}, chapters, nil, "fixture-vid", { offline = true })

expect(requested and requested.path == "/book/chapterdownload",
    "native batch request did not use chapterdownload")
expect(requested.params.chapters == "10-12",
    "adjacent chapter UIDs were not compacted into a server range")
expect(requested.params.offline == 1,
    "offline batch flag was not sent to the native API")
expect(payloads["10"].text == "chapter ten"
        and payloads["11"].text == "chapter eleven"
        and payloads["12"].text == "chapter twelve",
    "TXT batch archive did not return each requested chapter")

print(("chapter_download_batch_spec: %d checks"):format(checks))
