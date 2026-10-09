package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end

local archive_calls = {}
local archive_should_fail = false
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({}, { __index = self }) end
    function Reader:open(path)
        self.path = path
        self.index = 0
        return true
    end
    function Reader:iterate()
        local entries = {
            { path = "converted/page-1.jpeg", mode = "file", size = 7 },
            { path = "converted/metadata.json", mode = "file", size = 2 },
        }
        return function()
            self.index = self.index + 1
            return entries[self.index]
        end
    end
    function Reader:extractToMemory(path)
        if path:match("[.]jpeg$") then return "\255\216\255jpeg" end
        return "{}"
    end
    function Reader:close() end
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        local file = assert(io.open(path, "wb"))
        file:write("partial archive")
        file:close()
        return true
    end
    function Writer:setZipCompression(method)
        archive_calls[#archive_calls + 1] = { kind = "compression", method = method }
        return true
    end
    function Writer:addFileFromMemory(name, data)
        archive_calls[#archive_calls + 1] = {
            kind = "memory", name = name, bytes = #data, data = data,
        }
        if archive_should_fail then
            self.err = "injected archive failure"
            return false
        end
        return true
    end
    function Writer:addPath(name, path, recursive)
        archive_calls[#archive_calls + 1] = {
            kind = "path", name = name, path = path, recursive = recursive,
        }
        if archive_should_fail then
            self.err = "injected archive failure"
            return false
        end
        -- Match KOReader's wrapper: a successful disk walk terminates at EOF
        -- and currently returns false without setting err.
        return false
    end
    function Writer:close() end
    return { Reader = Reader, Writer = Writer }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            return os.execute("rm -rf " .. string.format("%q", path))
        end,
    }
end
package.preload["lfs"] = function()
    return {
        attributes = function(path, attribute)
            local probe = io.popen("test -d " .. string.format("%q", path)
                .. " && echo directory")
            local mode = probe:read("*l")
            probe:close()
            if attribute == "mode" then return mode end
            return mode and { mode = mode } or nil
        end,
        dir = function(path)
            local listing = io.popen("ls -a " .. string.format("%q", path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local workspace = {
    path = root .. "/.weread-download-100-123456",
}
workspace.incoming_dir = workspace.path .. "/incoming"
workspace.asset_dir = workspace.path .. "/images"
assert(os.execute("mkdir -p " .. string.format("%q", workspace.incoming_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.asset_dir)))

local assets = {}

local settings = {
    cache_dir = root,
    get = function(_self, _key, default) return default end,
}
local book = {
    book_id = "book",
    title = "Disk Assets",
    intro = "简介 & <精彩> \"引号\"\n第二行\0\1",
    cache_dir = root,
}
local book_css = [[blockquote { font-family: "Book Serif"; font-size: 18px; }
.quote-text { font-family: "Book Quote"; font-size: 14pt; }]]
local quote_xhtml = [[<blockquote class="quote-text" style="font-family: 'Inline Quote'; font-size: 19px; color: #333; background-color: white">quoted text</blockquote>]]
local output = Content.save_book_epub(settings, book,
    { { chapterUid = 7, title = "Chapter" } },
    { ["7"] = quote_xhtml }, "book", assets, book_css)
local used_path = false
local path_calls = 0
for _, call in ipairs(archive_calls) do
    if call.kind == "path" then
        path_calls = path_calls + 1
        if call.name == "OEBPS/images" then
            used_path = call.path == workspace.asset_dir
                and call.recursive == true
        end
    end
end
expect(not used_path and path_calls == 0,
    "EPUB writer streamed an image directory with no native chapter assets")
expect(io.open(output .. ".part", "rb") == nil,
    "successful EPUB build left a partial archive")
local opf
for _, call in ipairs(archive_calls) do
    if call.kind == "memory" and call.name == "OEBPS/content.opf" then
        opf = call.data
    end
end
expect(opf ~= nil, "full-book EPUB did not contain an OPF package document")
expect(opf:find(
    '<dc:description>简介 &amp; &lt;精彩&gt; &quot;引号&quot;\n第二行</dc:description>',
    1, true) ~= nil,
    "book introduction was not safely embedded as dc:description")
expect(opf:find("\0", 1, true) == nil and opf:find("\1", 1, true) == nil,
    "XML-illegal control characters remained in the OPF metadata")
local saved_css, saved_chapter
for _, call in ipairs(archive_calls) do
    if call.kind == "memory" and call.name == "OEBPS/style.css" then
        saved_css = call.data
    elseif call.kind == "memory" and call.name == "OEBPS/text/chapter-001.xhtml" then
        saved_chapter = call.data
    end
end
local image_defaults = saved_css and saved_css:find("img {", 1, true)
local book_styles = saved_css and saved_css:find(
    'blockquote { font-family: "Book Serif"; font-size: 1.28571429rem; }', 1, true)
local point_size_styles = saved_css and saved_css:find(
    '.quote-text { font-family: "Book Quote"; font-size: 1.33333333rem; }', 1, true)
local reader_geometry = saved_css and saved_css:find("html, body {\n    width: auto !important;", 1, true)
expect(saved_css and book_styles and point_size_styles and image_defaults
        and image_defaults < book_styles,
    "book CSS typography must be preserved with fixed sizes converted after plugin defaults")
expect(saved_css and book_styles and reader_geometry and book_styles < reader_geometry,
    "only root viewport constraints may follow the book stylesheet")
expect(saved_css and not saved_css:find("font-size: 1em !important", 1, true)
        and not saved_css:find("font-family: inherit !important", 1, true)
        and not saved_css:find("color: inherit !important", 1, true),
    "plugin CSS must not force author typography or colors to KOReader defaults")
expect(saved_chapter and saved_chapter:find("font-family: 'Inline Quote'", 1, true)
        and saved_chapter:find("font-size: 1.35714286rem", 1, true)
        and saved_chapter:find("color: #333", 1, true)
        and saved_chapter:find("background-color: white", 1, true),
    "XHTML normalization changed inline book typography or colors")

local old = assert(io.open(output, "wb"))
old:write("known-good-old-epub")
old:close()
archive_should_fail = true
local ok = pcall(function()
    Content.save_book_epub(settings, book,
        { { chapterUid = 7, title = "Chapter" } },
        { ["7"] = "<p>body</p>" }, "book", assets, "body{}")
end)
expect(not ok, "injected archive failure was not propagated")
old = assert(io.open(output, "rb"))
expect(old:read("*a") == "known-good-old-epub",
    "failed atomic build damaged the previous EPUB")
old:close()
expect(io.open(output .. ".part", "rb") == nil,
    "failed EPUB build left a partial archive")

local stale = root .. "/.weread-download-200-654321"
assert(os.execute("mkdir -p " .. string.format("%q", stale)))
local orphan = assert(io.open(root .. "/orphan.epub.part", "wb"))
orphan:write("partial")
orphan:close()
local recovery_settings = {
    cache_dir = root,
    get = function(_self, key, default)
        if key == "books" then
            return { book = { book_id = "book", cache_dir = root } }
        end
        return default
    end,
}
local removed = Content.cleanup_stale_downloads(recovery_settings)
expect(removed == 3 and io.open(root .. "/orphan.epub.part", "rb") == nil,
    "startup recovery did not remove stale workspace and partial EPUB: "
        .. tostring(removed))

local lfs = require("lfs")
expect(lfs.attributes(workspace.path, "mode") == nil,
    "startup recovery did not remove the active-looking stale workspace")
assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("download_disk_assets_spec: %d checks"):format(checks))
