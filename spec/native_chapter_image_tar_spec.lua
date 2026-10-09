package.path = "./?.lua;./?/init.lua;" .. package.path

local NativeChapter = require("weread.lib.native_chapter")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function tar_entry(name, data)
    local bytes = {}
    for index = 1, 512 do bytes[index] = "\0" end
    local function put(offset, value)
        for index = 1, #value do bytes[offset + index - 1] = value:sub(index, index) end
    end
    put(1, name)
    put(125, string.format("%011o\0", #data))
    put(157, "0")
    local padding = (512 - (#data % 512)) % 512
    return table.concat(bytes) .. data .. string.rep("\0", padding)
end

local image = "\137PNG\r\n\026\n" .. "test-image-bytes"
local tar = tar_entry("chapter-assets/figure.png", image) .. string.rep("\0", 1024)
local requested_url
local requested_headers
local captured_tar
local client = {
    native_headers = function(_self, extra)
        return {
            vid = "fixture-vid",
            accessToken = "fixture-token",
            Referer = extra.Referer,
        }
    end,
    get_binary = function(_self, url, opts)
        requested_url = url
        requested_headers = opts.headers
        return tar, 200, { ["Content-Type"] = "application/x-tar" }
    end,
}

local assets = NativeChapter.fetch_image_tar(client, {
    chapterUid = 42,
    tar = "https://res.weread.qq.com/chapter-assets.tar",
}, function(kind, chapters, data, metadata)
    captured_tar = { kind = kind, chapter = chapters[1], data = data, metadata = metadata }
end)
expect(requested_url == "https://res.weread.qq.com/chapter-assets.tar",
    "image TAR URL was not requested")
expect(requested_headers.vid == "fixture-vid"
    and requested_headers.accessToken == "fixture-token",
    "image TAR request did not use native account headers")
expect(#assets == 1 and assets[1].name == "figure.png",
    "TAR member path was not reduced to its basename")
expect(assets[1].data == image,
    "TAR image bytes were modified during extraction")
expect(captured_tar and captured_tar.kind == "images"
    and captured_tar.chapter.chapterUid == 42 and captured_tar.data == tar
    and captured_tar.metadata.content_type == "application/x-tar",
    "raw image TAR was not passed to the debug cache callback")

local before = requested_url
local ok = pcall(function()
    NativeChapter.fetch_image_tar(client, { tar = "https://example.com/image.tar" })
end)
expect(not ok and requested_url == before,
    "an off-host chapter image archive was requested")

print(("native_chapter_image_tar_spec: %d checks"):format(checks))
