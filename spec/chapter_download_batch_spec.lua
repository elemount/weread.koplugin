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

local body_css = "body { line-height: 1.5; }"
local quote_css = ".quotation { font-family: 'FangSong'; font-size: 16px; }"
local merged_css = NativeChapter.extract_stylesheets({
    ["book.css"] = body_css,
    ["quotation.css"] = quote_css,
}, { "book.css", "quotation.css" }, "42")
expect(merged_css == body_css .. "\n" .. quote_css,
    "chapter archive stylesheet extraction dropped or reordered a CSS entry")

local function xor_byte(left, right)
    local result, place = 0, 1
    while left > 0 or right > 0 do
        if left % 2 ~= right % 2 then result = result + place end
        left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
    end
    return result
end

local function xor_book_bytes(data, key)
    local output = {}
    for offset = 0, #data - 1 do
        local key_index = (offset + math.floor(offset / #key)) % #key + 1
        output[#output + 1] = string.char(
            xor_byte(data:byte(offset + 1), key:byte(key_index)))
    end
    return table.concat(output)
end

local comment_bytes = {}
for index = 1, 256 do
    comment_bytes[index] = string.char(32 + ((index * 37) % 95))
end
local encrypted_source_css = quote_css .. " /*" .. table.concat(comment_bytes) .. "*/"
local encrypted_css, encrypted_book_id
for candidate = 1, 1000 do
    local candidate_id = tostring(candidate)
    local ciphertext = xor_book_bytes(encrypted_source_css, candidate_id)
    if ciphertext:find("{", 1, true) and ciphertext:find("}", 1, true) then
        encrypted_css, encrypted_book_id = ciphertext, candidate_id
        break
    end
end
expect(encrypted_css ~= nil, "failed to build an encrypted CSS fixture with brace bytes")
expect(NativeChapter.extract_stylesheets({ ["quotation.css"] = encrypted_css },
        { "quotation.css" }, encrypted_book_id) == encrypted_source_css,
    "encrypted CSS containing incidental brace bytes was not decrypted")

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
local captured_archive
local client = {
    native_get_binary = function(_self, path, params, options)
        requested = { path = path, params = params, options = options }
        return table.concat({
            tar_entry("42_10", "chapter ten"),
            tar_entry("42_11", "chapter eleven"),
            tar_entry("42_12", "chapter twelve"),
            string.rep("\0", 1024),
        }), 200, { ["Content-Type"] = "application/x-tar" }
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
}, chapters, nil, "fixture-vid", {
    offline = true,
    capture_raw = function(kind, captured_chapters, bytes, metadata)
        captured_archive = {
            kind = kind, chapters = captured_chapters, bytes = bytes, metadata = metadata,
        }
    end,
})

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
expect(captured_archive and captured_archive.kind == "chapter-txt"
        and captured_archive.bytes:find("42_10", 1, true)
        and captured_archive.metadata.content_type == "application/x-tar"
        and #captured_archive.chapters == 3,
    "original chapter archive was not passed to the debug cache callback")

print(("chapter_download_batch_spec: %d checks"):format(checks))
