local Crypto = require("weread.lib.crypto")
local ReaderStyles = require("weread.lib.reader_styles")
local NativeChapter = require("weread.lib.native_chapter")
local logger = require("weread.lib.logger")

local Content = {}
local native_chapter_cache = setmetatable({}, { __mode = "k" })
-- Forward declarations used by the resumable-download checkpoint helpers.
local xml_escape
local body_fragment
local native_payload

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "weread"
    end
    return value
end

-- Directory name a book is stored under (sanitized book id). Exposed so the
-- local-cache scanner can match on-disk directory names against shelf book ids.
function Content.book_dir_name(book_id)
    return basename_safe(book_id)
end

function Content.book_cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. Content.book_dir_name(book_id)
end

-- Resolve where a book's files actually live. The current settings.cache_dir may
-- differ from where a book was downloaded (the user changed it since), so prefer
-- concrete evidence of the real location: an explicit book.cache_dir (set when any
-- file — a chapter — is written), then the directory of a stored
-- cached_file/chapter path, and only as a last resort the path recomputed under
-- the current root. This keeps deletion, stats and moves on the real files instead
-- of orphaning them. Cached chapters may have no cached_file, so book.cache_dir
-- can pin their original location down.
function Content.book_resolved_dir(settings, book_id, book)
    if book and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if type(path) == "string" then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_full_book or book.cached_file)
    if not dir and book and type(book.cached_chapters) == "table" then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or Content.book_cache_dir(settings, book_id)
end

function Content.catalog_cache_path(settings, book)
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return nil
    end
    return Content.book_resolved_dir(settings, book_id, book) .. "/catalog.json"
end

function Content.save_catalog_cache(client, settings, book, chapters)
    if type(chapters) ~= "table" then
        return false, "chapter list is not a table"
    end
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return false, "missing book id"
    end
    local dir = path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p " .. string.format("%q", dir))
    local ok, encoded = pcall(function()
        return client:json_encode({
            version = 1,
            updated_at = os.time(),
            chapters = chapters,
        })
    end)
    if not ok then
        return false, encoded
    end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, err
    end
    local write_ok, write_err = file:write(encoded)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    book.cache_dir = dir
    return true, path
end

function Content.load_catalog_cache(client, settings, book)
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local encoded = file:read("*a")
    file:close()
    local ok, decoded = pcall(function()
        return client:json_decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("ignore invalid catalog cache:", path)
        return nil
    end
    local chapters = decoded.chapters
    if type(chapters) ~= "table" then
        return nil
    end
    book.chapters = chapters
    return chapters
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "weread"
    end
    return value
end

local function item_id(prefix, value)
    return prefix .. basename_safe(value):gsub("%.", "_")
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

local function media_type_for_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, nil, err end
    local head = file:read(12) or ""
    file:close()
    return media_type_for(head)
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function unique_asset_name(used, name, ext)
    local base = filename_safe(name)
    if not base:lower():match(ext:gsub("%.", "%%.") .. "$") then
        base = base .. ext
    end
    local candidate = base
    local index = 2
    while used[candidate] do
        local stem = base:gsub("%.[^%.]+$", "")
        candidate = stem .. "-" .. tostring(index) .. ext
        index = index + 1
    end
    used[candidate] = true
    return candidate
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

local function make_path(path)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        local made, err = util.makePath(path)
        if not made then error(err or ("could not create directory: " .. path)) end
        return
    end
    local result = os.execute("mkdir -p " .. string.format("%q", path))
    if result ~= true and result ~= 0 then
        error("could not create directory: " .. path)
    end
end

local function remove_tree(path)
    if type(path) ~= "string"
        or (not path:match("/%.weread%-download%-%d+%-%d+$")
            and not path:match("/%.weread%-download%-resume%-full$")
            and not path:match("/%.weread%-download%-resume%-full/rendered%-text$")) then
        return nil, "refusing to remove an invalid download workspace"
    end
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or not ffiutil or not ffiutil.purgeDir then
        return nil, "directory cleanup unavailable"
    end
    local called, removed, err = pcall(ffiutil.purgeDir, path)
    if not called then return nil, removed end
    if removed == false then return nil, err end
    return true
end

-- A full-book job is the only one that can run long enough to make a restart
-- meaningful. Keep its working files under a stable, book-local directory so
-- a failed transfer (or an OOM kill) can be resumed without putting book text
-- in the plugin settings file.
function Content.open_full_download_workspace(settings, book)
    local book_id = book.book_id or book.bookId
    local book_dir = Content.book_resolved_dir(settings, book_id, book)
    make_path(book_dir)
    book.cache_dir = book_dir
    local workspace = book_dir .. "/.weread-download-resume-full"
    local incoming_dir = workspace .. "/incoming"
    local asset_dir = workspace .. "/images"
    local text_dir = workspace .. "/text"
    local checkpoint_dir = workspace .. "/checkpoints"
    local rendered_text_dir = workspace .. "/rendered-text"
    make_path(incoming_dir)
    make_path(asset_dir)
    make_path(text_dir)
    make_path(checkpoint_dir)
    make_path(rendered_text_dir)
    return {
        path = workspace,
        incoming_dir = incoming_dir,
        asset_dir = asset_dir,
        text_dir = text_dir,
        checkpoint_dir = checkpoint_dir,
        rendered_text_dir = rendered_text_dir,
        resumable = true,
    }
end

local function workspace_chapter_name(chapter, chapter_index)
    return string.format("chapter-%03d.xhtml", tonumber(chapter_index) or 0)
end

local function workspace_chapter_marker(chapter)
    return "<!-- weread-chapter-uid: "
        .. basename_safe(chapter and chapter.chapterUid or "unknown") .. " -->"
end

function Content.full_download_chapter_path(workspace, chapter, chapter_index)
    if not workspace or not workspace.text_dir then return nil end
    return workspace.text_dir .. "/" .. workspace_chapter_name(chapter, chapter_index)
end

function Content.full_download_checkpoint_path(workspace, chapter, chapter_index)
    if not workspace or not workspace.checkpoint_dir then return nil end
    return workspace.checkpoint_dir .. "/" .. workspace_chapter_name(chapter, chapter_index) .. ".meta"
end

function Content.full_download_rendered_chapter_path(workspace, chapter, chapter_index)
    if not workspace or not workspace.rendered_text_dir then return nil end
    return workspace.rendered_text_dir .. "/" .. workspace_chapter_name(chapter, chapter_index)
end

function Content.full_download_rendered_chapter_exists(workspace, chapter, chapter_index)
    local path = Content.full_download_rendered_chapter_path(workspace, chapter, chapter_index)
    local file = path and io.open(path, "rb")
    if not file then return false end
    local xhtml = file:read("*a") or ""
    local closed = file:close()
    return closed and xhtml:find(workspace_chapter_marker(chapter), 1, true) ~= nil
end

local function read_full_download_checkpoint(path)
    local file = path and io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    local closed = file:close()
    if not closed then return nil end
    local uid = data:match("^uid=([^\n]*)\n")
    local length = tonumber(data:match("\nlength=(%d+)\n"))
    local digest = data:match("\nsha256=([0-9a-f]+)\n")
    if not uid or not length or not digest then return nil end
    return uid, length, digest
end

function Content.full_download_chapter_exists(workspace, chapter, chapter_index)
    local path = Content.full_download_chapter_path(workspace, chapter, chapter_index)
    local file = path and io.open(path, "rb")
    if not file then return false end
    local xhtml = file:read("*a") or ""
    local closed = file:close()
    if not closed or xhtml:find(workspace_chapter_marker(chapter), 1, true) == nil then
        return false
    end
    local uid, length, digest = read_full_download_checkpoint(
        Content.full_download_checkpoint_path(workspace, chapter, chapter_index))
    return uid == basename_safe(chapter and chapter.chapterUid or "unknown")
        and length == #xhtml
        and digest == Crypto.sha256_hex(xhtml)
end

function Content.load_full_download_chapter(workspace, chapter, chapter_index)
    local path = Content.full_download_chapter_path(workspace, chapter, chapter_index)
    if not path then return nil, "chapter checkpoint is missing" end
    local file, err = io.open(path, "rb")
    if not file then return nil, err or "chapter checkpoint is missing" end
    local xhtml = file:read("*a")
    file:close()
    return xhtml
end

local function atomic_write(path, data)
    local tmp_path = path .. ".part"
    local file, err = io.open(tmp_path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    local closed, close_err = file:close()
    if not ok or not closed then
        pcall(os.remove, tmp_path)
        return nil, write_err or close_err
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        pcall(os.remove, tmp_path)
        return nil, rename_err
    end
    return true
end

local function full_download_chapter_xhtml(chapter, chapter_index, xhtml)
    local title = chapter and chapter.title
        or ("Chapter " .. tostring(chapter and chapter.chapterUid or chapter_index))
    return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
]] .. workspace_chapter_marker(chapter) .. [[
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
end

function Content.save_full_download_chapter(workspace, chapter, chapter_index, xhtml)
    local path = Content.full_download_chapter_path(workspace, chapter, chapter_index)
    local checkpoint_path = Content.full_download_checkpoint_path(workspace, chapter, chapter_index)
    if not path or not checkpoint_path then return nil, "missing full-book workspace" end
    local chapter_xhtml = full_download_chapter_xhtml(chapter, chapter_index, xhtml)
    local ok, err = atomic_write(path, chapter_xhtml)
    if not ok then error(err or "could not checkpoint chapter") end
    local checkpoint = table.concat({
        "uid=" .. basename_safe(chapter and chapter.chapterUid or "unknown"),
        "length=" .. tostring(#chapter_xhtml),
        "sha256=" .. Crypto.sha256_hex(chapter_xhtml),
        "",
    }, "\n")
    ok, err = atomic_write(checkpoint_path, checkpoint)
    if not ok then error(err or "could not checkpoint chapter metadata") end
    return path
end

function Content.reset_full_download_rendered_text(workspace)
    if not workspace or not workspace.rendered_text_dir then
        error("missing full-book rendered workspace")
    end
    local ok, err = remove_tree(workspace.rendered_text_dir)
    if not ok then error(err or "could not reset rendered chapter workspace") end
    make_path(workspace.rendered_text_dir)
    return true
end

function Content.save_full_download_rendered_chapter(workspace, chapter, chapter_index, xhtml)
    local path = Content.full_download_rendered_chapter_path(workspace, chapter, chapter_index)
    if not path then error("missing full-book rendered workspace") end
    local ok, err = atomic_write(path, full_download_chapter_xhtml(chapter, chapter_index, xhtml))
    if not ok then error(err or "could not save rendered chapter") end
    return path
end

function Content.save_full_download_css(workspace, css)
    if not workspace or not workspace.path then return nil end
    local ok, err = atomic_write(workspace.path .. "/style.css", css or "")
    if not ok then error(err or "could not checkpoint stylesheet") end
    return true
end

function Content.load_full_download_css(workspace)
    local file = workspace and workspace.path
        and io.open(workspace.path .. "/style.css", "rb")
    if not file then return nil end
    local css = file:read("*a")
    file:close()
    return css
end

function Content.full_download_completed_chapters(workspace, chapters)
    local completed = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if Content.full_download_chapter_exists(workspace, chapter, chapter_index) then
            completed[chapter_index] = true
        end
    end
    return completed
end

function Content.full_download_workspace_assets(workspace)
    local assets = {}
    if not workspace or not workspace.asset_dir then return assets end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs
        or lfs.attributes(workspace.asset_dir, "mode") ~= "directory" then
        return assets
    end
    for name in lfs.dir(workspace.asset_dir) do
        if name ~= "." and name ~= ".." then
            local path = workspace.asset_dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                local _, media_type = media_type_for_file(path)
                if media_type and media_type:match("^image/") then
                    table.insert(assets, {
                        href = "images/" .. name,
                        media_type = media_type,
                        path = path,
                    })
                end
            end
        end
    end
    table.sort(assets, function(a, b) return a.href < b.href end)
    return assets
end

function Content.full_download_workspace_used_asset_names(workspace)
    local used = {}
    for _, asset in ipairs(Content.full_download_workspace_assets(workspace)) do
        local name = basename(asset.href)
        if name ~= "" then used[name] = true end
    end
    return used
end

function Content.create_download_workspace(settings, book)
    local book_id = book.book_id or book.bookId
    local book_dir = Content.book_resolved_dir(settings, book_id, book)
    make_path(book_dir)
    book.cache_dir = book_dir
    local workspace = string.format("%s/.weread-download-%d-%d",
        book_dir, os.time(), math.random(100000, 999999))
    local incoming_dir = workspace .. "/incoming"
    local asset_dir = workspace .. "/images"
    make_path(incoming_dir)
    make_path(asset_dir)
    return {
        path = workspace,
        incoming_dir = incoming_dir,
        asset_dir = asset_dir,
    }
end

function Content.cleanup_download_workspace(workspace)
    local path = type(workspace) == "table" and workspace.path or workspace
    if not path then return true end
    local ok, err = remove_tree(path)
    if not ok then
        logger.warn("download workspace cleanup failed:", tostring(err))
    end
    return ok, err
end

function Content.cleanup_stale_downloads(settings)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then return 0 end
    local dirs = {}
    for book_id, book in pairs(settings:get("books", {}) or {}) do
        local dir = Content.book_resolved_dir(settings, book_id, book)
        dirs[dir] = true
    end
    local removed = 0
    for dir in pairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name:match("^%.weread%-download%-%d+%-%d+$") then
                    local cleaned = remove_tree(dir .. "/" .. name)
                    if cleaned then removed = removed + 1 end
                elseif name:match("%.epub%.part$") then
                    if os.remove(dir .. "/" .. name) then removed = removed + 1 end
                elseif name:match("%.epub%.weread%-backup$") then
                    local backup = dir .. "/" .. name
                    local final = backup:gsub("%.weread%-backup$", "")
                    local current = io.open(final, "rb")
                    if current then
                        current:close()
                        if os.remove(backup) then removed = removed + 1 end
                    elseif os.rename(backup, final) then
                        removed = removed + 1
                    end
                end
            end
        end
    end
    return removed
end

local function commit_file(part_path, path)
    local renamed, rename_err = os.rename(part_path, path)
    if renamed then return true end
    local old = io.open(path, "rb")
    if not old then return nil, rename_err end
    old:close()
    local backup = path .. ".weread-backup"
    pcall(os.remove, backup)
    local backed_up, backup_err = os.rename(path, backup)
    if not backed_up then return nil, backup_err or rename_err end
    renamed, rename_err = os.rename(part_path, path)
    if not renamed then
        os.rename(backup, path)
        return nil, rename_err
    end
    pcall(os.remove, backup)
    return true
end

local function write_epub(path, entries)
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Writer:new{}
    local part_path = path .. ".part"
    pcall(os.remove, part_path)
    if not archive:open(part_path, "epub") then
        error("failed to open archive for writing: " .. tostring(archive.err))
    end
    local mtime = os.time()
    local ok, err = xpcall(function()
        assert(archive:setZipCompression("store"), archive.err)
        local mimetype_data = "application/epub+zip"
        for _, entry in ipairs(entries) do
            if entry.name == "mimetype" then
                mimetype_data = entry.data
                break
            end
        end
        assert(archive:addFileFromMemory("mimetype", mimetype_data, mtime), archive.err)
        assert(archive:setZipCompression("deflate"), archive.err)
        for _, entry in ipairs(entries) do
            if entry.name ~= "mimetype" then
                local added
                if entry.path then
                    added = archive:addPath(
                        entry.name, entry.path, entry.recursive == true, mtime)
                    -- KOReader's current Writer:addPath() returns false after
                    -- a successful walk because its terminal status is EOF,
                    -- while leaving err unset. A real libarchive failure sets
                    -- err, so accept only this error-free EOF case.
                    if not added and archive.err == nil then added = true end
                else
                    added = archive:addFileFromMemory(entry.name, entry.data or "", mtime)
                end
                assert(added, archive.err or ("failed to add " .. entry.name))
            end
        end
    end, debug.traceback)
    pcall(function() archive:close() end)
    if not ok then
        pcall(os.remove, part_path)
        error(err, 0)
    end
    local committed, commit_err = commit_file(part_path, path)
    if not committed then
        pcall(os.remove, part_path)
        error(commit_err or "failed to commit EPUB", 0)
    end
end

local function append_asset_entries(entries, assets)
    local disk_dir
    for _, asset in ipairs(assets or {}) do
        if asset.path then
            local parent = asset.path:match("^(.*)/[^/]+$")
            if not parent then
                error("invalid file-backed asset path: " .. tostring(asset.path))
            end
            if disk_dir and disk_dir ~= parent then
                error("file-backed EPUB assets must share one directory")
            end
            disk_dir = parent
        else
            table.insert(entries, {
                name = "OEBPS/" .. asset.href,
                data = asset.data,
                store = asset.store,
            })
        end
    end
    if disk_dir then
        -- KOReader's libarchive wrapper is reliable for a directory tree, but
        -- some Kindle builds fail when addPath is given an individual file.
        -- All disk-backed images are staged together, so stream the directory
        -- into the EPUB with one reader lifecycle.
        table.insert(entries, {
            name = "OEBPS/images",
            path = disk_dir,
            recursive = true,
        })
    end
end

xml_escape = function(value)
    value = tostring(value or "")
    -- XML 1.0 permits tabs, newlines, and carriage returns from the C0 range,
    -- but rejects the remaining control characters. Book metadata comes from
    -- remote APIs, so remove those bytes before embedding it in the OPF.
    value = value:gsub("[%z\1-\8\11\12\14-\31]", "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

-- WeRead EPUB chapters may decode to multiple concatenated XHTML documents.
-- The first <body> is often a title shell; main content lives in later bodies.
local function markup_token_end(document, start)
    if document:sub(start, start + 3) == "<!--" then
        local close = document:find("-->", start + 4, true)
        return close and close + 2 or #document
    elseif document:sub(start, start + 8) == "<![CDATA[" then
        local close = document:find("]]>", start + 9, true)
        return close and close + 2 or #document
    elseif document:sub(start, start + 1) == "<?" then
        local close = document:find("?>", start + 2, true)
        return close and close + 1 or #document
    end

    local quote
    local subset_depth = 0
    local is_doctype = document:sub(start, start + 8):upper() == "<!DOCTYPE"
    for index = start + 1, #document do
        local char = document:sub(index, index)
        if quote then
            if char == quote then quote = nil end
        elseif char == "\"" or char == "'" then
            quote = char
        elseif is_doctype and char == "[" then
            subset_depth = subset_depth + 1
        elseif is_doctype and char == "]" and subset_depth > 0 then
            subset_depth = subset_depth - 1
        elseif char == ">" and subset_depth == 0 then
            return index
        end
    end
    return #document
end

local function tag_token(document, start, finish)
    local token = document:sub(start, finish)
    local name = token:match("^<%s*/?%s*([%w:_%-]+)")
    if not name then return nil end
    return name, token:match("^<%s*/") ~= nil,
        token:match("/%s*>$") ~= nil
end

local function extract_tag_contents(document, wanted)
    local fragments = {}
    local cursor = 1
    local content_start
    while true do
        local start = document:find("<", cursor, true)
        if not start then break end
        local finish = markup_token_end(document, start)
        local name, closing, self_closing = tag_token(document, start, finish)
        if name and name:lower() == wanted then
            if closing and content_start then
                fragments[#fragments + 1] = document:sub(content_start, start - 1)
                content_start = nil
            elseif not closing and not content_start then
                if self_closing then
                    fragments[#fragments + 1] = ""
                else
                    content_start = finish + 1
                end
            end
        end
        if finish <= start then break end
        cursor = finish + 1
    end
    if content_start then
        fragments[#fragments + 1] = document:sub(content_start)
    end
    return fragments
end

local function strip_tag_elements(document, wanted)
    local chunks = {}
    local cursor = 1
    local removing_depth = 0
    while true do
        local start = document:find("<", cursor, true)
        if not start then break end
        local finish = markup_token_end(document, start)
        local name, closing, self_closing = tag_token(document, start, finish)
        if removing_depth == 0 then
            chunks[#chunks + 1] = document:sub(cursor, start - 1)
        end
        if name and name:lower() == wanted then
            if closing and removing_depth > 0 then
                removing_depth = removing_depth - 1
            elseif not closing and not self_closing then
                removing_depth = removing_depth + 1
            end
        elseif removing_depth == 0 then
            chunks[#chunks + 1] = document:sub(start, finish)
        end
        if finish <= start then break end
        cursor = finish + 1
    end
    if removing_depth == 0 then
        chunks[#chunks + 1] = document:sub(cursor)
    end
    return table.concat(chunks)
end

local xml_entity_names = { amp = true, apos = true, gt = true, lt = true, quot = true }
local html_entity_codes = {
    nbsp = "160", ndash = "8211", mdash = "8212", hellip = "8230",
    ldquo = "8220", rdquo = "8221", lsquo = "8216", rsquo = "8217",
    copy = "169", reg = "174", trade = "8482", bull = "8226",
}

local function escape_invalid_xml_entities(value)
    local out = {}
    local cursor = 1
    while cursor <= #value do
        local amp = value:find("&", cursor, true)
        if not amp then
            out[#out + 1] = value:sub(cursor)
            break
        end
        out[#out + 1] = value:sub(cursor, amp - 1)
        local entity = value:sub(amp + 1):match("^([%w#]+);")
        local is_numeric_reference = entity
            and (entity:match("^#%d+$") or entity:match("^#x%x+$"))
        if is_numeric_reference then
            local codepoint = entity:sub(2, 2) == "x"
                and tonumber(entity:sub(3), 16) or tonumber(entity:sub(2))
            local valid = codepoint and (codepoint == 9 or codepoint == 10 or codepoint == 13
                or (codepoint >= 32 and codepoint <= 0xD7FF)
                or (codepoint >= 0xE000 and codepoint <= 0xFFFD)
                or (codepoint >= 0x10000 and codepoint <= 0x10FFFF))
            out[#out + 1] = valid and ("&" .. entity .. ";") or "&#65533;"
            cursor = amp + #entity + 2
        elseif entity and xml_entity_names[entity] then
            out[#out + 1] = "&" .. entity .. ";"
            cursor = amp + #entity + 2
        elseif entity and html_entity_codes[entity] then
            out[#out + 1] = "&#" .. html_entity_codes[entity] .. ";"
            cursor = amp + #entity + 2
        else
            out[#out + 1] = "&amp;"
            cursor = amp + 1
        end
    end
    return table.concat(out)
end

local void_xhtml_tags = {
    area = true, base = true, br = true, col = true, embed = true,
    hr = true, img = true, input = true, link = true, meta = true,
    param = true, source = true, track = true, wbr = true,
}

local fixed_font_units = {
    px = true, pt = true, pc = true, inch = true, ["in"] = true,
    cm = true, mm = true, q = true,
}

local function is_fixed_font_size(value)
    value = tostring(value or ""):lower():gsub("%s*!important%s*$", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    local number, unit = value:match("^(%d+%.?%d*)%s*([%a]+)$")
    return number ~= nil and tonumber(number) > 0 and fixed_font_units[unit] == true
end

local theme_neutral_colors = {
    black = true, white = true, gray = true, grey = true, silver = true,
    dimgray = true, dimgrey = true, darkgray = true, darkgrey = true,
    lightgray = true, lightgrey = true, gainsboro = true, whitesmoke = true,
}

local function is_theme_neutral_color(value)
    value = tostring(value or ""):lower():gsub("%s*!important%s*$", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if theme_neutral_colors[value] then return true end
    local hex = value:match("^#([%da-f]+)$")
    if hex and (#hex == 3 or #hex == 6) then
        local channels
        if #hex == 3 then
            channels = { hex:sub(1, 1), hex:sub(2, 2), hex:sub(3, 3) }
        else
            channels = { hex:sub(1, 2), hex:sub(3, 4), hex:sub(5, 6) }
        end
        return channels[1] == channels[2] and channels[2] == channels[3]
    end
    local red, green, blue = value:match("^rgb%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$")
    return red ~= nil and red == green and green == blue
end

local function normalize_start_tag(token)
    local name = token:match("^<([%w:_%-]+)")
    if not name then return token end
    local was_self_closing = token:match("/%s*>$") ~= nil
    local out = { "<", name }
    local seen_attributes = {}
    local cursor = #name + 2
    while cursor <= #token do
        local char = token:sub(cursor, cursor)
        if char:match("%s") then
            local whitespace = token:sub(cursor):match("^(%s+)")
            out[#out + 1] = whitespace
            cursor = cursor + #whitespace
        elseif char == ">" then
            out[#out + 1] = was_self_closing and "/>" or ">"
            break
        elseif char == "/" and token:sub(cursor + 1, cursor + 1) == ">" then
            out[#out + 1] = "/>"
            break
        else
            local attribute = token:sub(cursor):match("^([%w:_%-]+)")
            if not attribute then
                out[#out + 1] = char
                cursor = cursor + 1
            else
                cursor = cursor + #attribute
                local spacing = token:sub(cursor):match("^(%s*)") or ""
                cursor = cursor + #spacing
                if token:sub(cursor, cursor) == "=" then
                    cursor = cursor + 1
                    local equals_spacing = token:sub(cursor):match("^(%s*)") or ""
                    cursor = cursor + #equals_spacing
                    local quote = token:sub(cursor, cursor)
                    local value
                    if quote == "\"" or quote == "'" then
                        local close = token:find(quote, cursor + 1, true)
                        if close then
                            value = token:sub(cursor + 1, close - 1)
                            cursor = close + 1
                        else
                            value = token:sub(cursor + 1):gsub("%s*>$", "")
                            cursor = #token
                        end
                    else
                        value = token:sub(cursor):match("^([^%s>]+)") or ""
                        cursor = cursor + #value
                        if value:sub(-1) == "/" and token:sub(cursor, cursor) == ">" then
                            value = value:sub(1, -2)
                        end
                    end
                    value = escape_invalid_xml_entities(value):gsub("<", "&lt;")
                    if attribute:lower() == "style" then
                        value = value:gsub("([^;]+)(;?)", function(declaration, terminator)
                            local property, style_value = declaration:match(
                                "^%s*([%w%-]+)%s*:%s*(.-)%s*$")
                            if property then
                                property = property:lower()
                                if property == "font-size" and is_fixed_font_size(style_value) then
                                    return ""
                                elseif (property == "color" or property == "background-color")
                                    and is_theme_neutral_color(style_value) then
                                    return ""
                                end
                            end
                            return declaration .. terminator
                        end)
                    end
                    local attribute_key = attribute:lower()
                    if not seen_attributes[attribute_key] then
                        out[#out + 1] = " " .. attribute .. "=\"" .. value .. "\""
                        seen_attributes[attribute_key] = true
                    end
                else
                    -- HTML-style boolean attributes need explicit XML values.
                    local attribute_key = attribute:lower()
                    if not seen_attributes[attribute_key] then
                        out[#out + 1] = " " .. attribute .. "=\"" .. attribute .. "\""
                        seen_attributes[attribute_key] = true
                    end
                end
            end
        end
    end
    return table.concat(out)
end

local function normalize_xhtml_fragment(fragment)
    fragment = tostring(fragment or ""):gsub("[%z\1-\8\11\12\14-\31]", "")
    local out, stack = {}, {}
    local cursor = 1
    while true do
        local start = fragment:find("<", cursor, true)
        if not start then break end
        out[#out + 1] = escape_invalid_xml_entities(fragment:sub(cursor, start - 1))
        local finish = markup_token_end(fragment, start)
        local token = fragment:sub(start, finish)
        local name, closing, self_closing = tag_token(fragment, start, finish)
        if name then
            token = escape_invalid_xml_entities(token)
            if closing then
                local matching
                for index = #stack, 1, -1 do
                    if stack[index] == name then matching = index; break end
                end
                if matching then
                    for index = #stack, matching + 1, -1 do
                        out[#out + 1] = "</" .. stack[index] .. ">"
                        stack[index] = nil
                    end
                    out[#out + 1] = token
                    stack[matching] = nil
                end
            elseif void_xhtml_tags[name:lower()] then
                token = normalize_start_tag(token)
                if not self_closing then
                    token = token:gsub("%s*>$", "/>" )
                end
                out[#out + 1] = token
            else
                token = normalize_start_tag(token)
                out[#out + 1] = token
                if not self_closing then stack[#stack + 1] = name end
            end
        elseif token:sub(1, 4) == "<!--"
            or token:sub(1, 9) == "<![CDATA["
            or token:sub(1, 2) == "<?" then
            out[#out + 1] = token
        elseif not token:upper():match("^<!DOCTYPE[%s>]") then
            out[#out + 1] = "&lt;"
            finish = start
        end
        cursor = finish + 1
    end
    out[#out + 1] = escape_invalid_xml_entities(fragment:sub(cursor))
    for index = #stack, 1, -1 do
        out[#out + 1] = "</" .. stack[index] .. ">"
    end
    return table.concat(out)
end

body_fragment = function(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = extract_tag_contents(xhtml, "body")
    if #bodies > 0 then
        return normalize_xhtml_fragment(table.concat(bodies, "\n"))
    end

    -- A few native payloads contain fragments or incomplete XHTML. Preserve
    -- the document content while dropping wrappers that would be nested in the
    -- EPUB's own body element.
    local html_documents = extract_tag_contents(xhtml, "html")
    if #html_documents > 0 then
        xhtml = table.concat(html_documents, "\n")
    end
    xhtml = strip_tag_elements(xhtml, "head")
    local chunks = {}
    local cursor = 1
    while true do
        local start = xhtml:find("<", cursor, true)
        if not start then break end
        local finish = markup_token_end(xhtml, start)
        local token = xhtml:sub(start, finish)
        chunks[#chunks + 1] = xhtml:sub(cursor, start - 1)
        if not token:match("^<%?xml[%s?]")
            and not token:upper():match("^<!DOCTYPE[%s>]") then
            chunks[#chunks + 1] = token
        end
        if finish <= start then break end
        cursor = finish + 1
    end
    chunks[#chunks + 1] = xhtml:sub(cursor)
    return normalize_xhtml_fragment(table.concat(chunks))
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

function Content.first_readable_chapter(chapters)
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

local function chapter_level(chapter)
    local level = tonumber(chapter and chapter.level or 1) or 1
    if level < 1 then
        level = 1
    elseif level > 6 then
        level = 6
    end
    return level
end

local function build_chapter_tree(chapters, filename_for)
    local root = { children = {} }
    local stack = { root }
    for chapter_index, chapter in ipairs(chapters or {}) do
        local level = chapter_level(chapter)
        if level > #stack then
            level = #stack
        end
        while #stack > level do
            table.remove(stack)
        end
        local parent = stack[#stack] or root
        local node = {
            title = chapter.title or ("Chapter " .. tostring(chapter.chapterUid or chapter_index)),
            href = filename_for(chapter_index, chapter),
            children = {},
        }
        table.insert(parent.children, node)
        stack[level + 1] = node
    end
    return root.children
end

local function build_nav_items(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            table.insert(out, [[<li><a href="]] .. xml_escape(node.href) .. [[">]] .. xml_escape(node.title) .. [[</a>]])
            if node.children and #node.children > 0 then
                table.insert(out, "<ol>")
                table.insert(out, render(node.children))
                table.insert(out, "</ol>")
            end
            table.insert(out, "</li>")
        end
        return table.concat(out, "\n")
    end

    return render(tree)
end

local function build_ncx_points(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local play_order = 0
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            play_order = play_order + 1
            local current_order = play_order
            table.insert(out, [[<navPoint id="navPoint-]] .. tostring(current_order) .. [[" playOrder="]] .. tostring(current_order) .. [[">]])
            table.insert(out, [[<navLabel><text>]] .. xml_escape(node.title) .. [[</text></navLabel>]])
            table.insert(out, [[<content src="]] .. xml_escape(node.href) .. [["/>]])
            if node.children and #node.children > 0 then
                table.insert(out, render(node.children))
            end
            table.insert(out, "</navPoint>")
        end
        return table.concat(out, "\n")
    end
    return render(tree), play_order
end

local function metadata_text(value)
    if type(value) ~= "string" and type(value) ~= "number" then return "" end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function opf_language(book)
    local language = metadata_text(book.language or book.lang)
    language = language:gsub("_", "-")
    if language ~= "" and language:match("^[A-Za-z][A-Za-z%-]*$") then
        return language
    end
end

local function opf_publication_date(value)
    value = metadata_text(value)
    if value:match("^%d%d%d%d$") then return value end
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then return "" end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if month < 1 or month > 12 or day < 1 then return "" end
    local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
        days_in_month[2] = 29
    end
    if day > days_in_month[month] then return "" end
    return string.format("%04d-%02d-%02d", year, month, day)
end

local function opf_metadata(book, identifier)
    local author = metadata_text(book.author)
    local publisher = metadata_text(book.publisher)
    local parts = {
        '<dc:identifier id="bookid">' .. xml_escape(identifier) .. "</dc:identifier>",
        "<dc:title>" .. xml_escape(book.title or "WeRead") .. "</dc:title>",
        '<dc:source>https://i.weread.qq.com/book/info?bookId='
            .. xml_escape(book.book_id or book.bookId or "") .. "</dc:source>",
    }
    if author ~= "" then parts[#parts + 1] = "<dc:creator>" .. xml_escape(author) .. "</dc:creator>" end
    if publisher ~= "" then
        parts[#parts + 1] = "<dc:publisher>" .. xml_escape(publisher) .. "</dc:publisher>"
    end
    local language = opf_language(book)
    if language then parts[#parts + 1] = "<dc:language>" .. xml_escape(language) .. "</dc:language>" end
    local description = metadata_text(book.intro)
    if description ~= "" then
        parts[#parts + 1] = "<dc:description>" .. xml_escape(description) .. "</dc:description>"
    end
    local translator = metadata_text(book.translator)
    if translator ~= "" then
        parts[#parts + 1] = '<dc:contributor id="translator">' .. xml_escape(translator)
            .. "</dc:contributor><meta refines=\"#translator\" property=\"role\" "
            .. 'scheme="marc:relators">trl</meta>'
    end
    local isbn = metadata_text(book.isbn)
    if isbn ~= "" then
        parts[#parts + 1] = '<dc:identifier id="isbn">' .. xml_escape(isbn) .. "</dc:identifier>"
    end
    local subject = metadata_text(book.categoryName or book.category)
    if subject ~= "" then
        parts[#parts + 1] = "<dc:subject>" .. xml_escape(subject) .. "</dc:subject>"
    end
    local date = opf_publication_date(book.publishTime or book.publicationDate)
    if date ~= "" then parts[#parts + 1] = "<dc:date>" .. date .. "</dc:date>" end
    parts[#parts + 1] = '<meta property="dcterms:modified">' .. utc_modified() .. "</meta>"
    return table.concat(parts, "\n")
end

function Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local language = opf_language(book)
    local language_attribute = language and (' lang="' .. xml_escape(language)
        .. '" xml:lang="' .. xml_escape(language) .. '"') or ""
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (chapter.title or tostring(chapter.chapterUid or "chapter"))) .. ".epub"
    local title = chapter.title or book.title or "WeRead"
    local manifest_assets = {}
    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_assets, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink"]] .. language_attribute .. [[>
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/ marc: http://id.loc.gov/vocabulary/relators/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
]] .. opf_metadata(book, "weread-" .. tostring(book_id) .. "-" .. tostring(chapter.chapterUid or "chapter")) .. [[
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="style" href="style.css" media-type="text/css"/>
<item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
]] .. table.concat(manifest_assets, "\n") .. [[
</manifest>
<spine>
<itemref idref="chapter"/>
</spine>
</package>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol><li><a href="text/chapter.xhtml">]] .. xml_escape(title) .. [[</a></li></ol>
</nav>
</body>
</html>]]
    css = ReaderStyles.compose(css or [[body { line-height: 1.7; margin: 5%; }]])
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = nav },
        { name = "OEBPS/style.css", data = css },
        { name = "OEBPS/text/chapter.xhtml", data = chapter_xhtml },
    }
    append_asset_entries(entries, assets)
    write_epub(path, entries)
    Content.register_annotation_document(book, path, { chapter })
    return path
end

function Content.save_book_epub(settings, book, chapters, chapter_bodies, suffix, assets, css, cover_data)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local language = opf_language(book)
    local language_attribute = language and (' lang="' .. xml_escape(language)
        .. '" xml:lang="' .. xml_escape(language) .. '"') or ""
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (suffix or "book")) .. ".epub"
    local manifest_items = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine_items = {}
    -- Resumable full-book jobs checkpoint ready-to-package XHTML files.  The
    -- archiver can stream that directory directly, avoiding one large Lua
    -- string table for the entire book at the final packaging step.
    local workspace_text_dir = type(chapter_bodies) == "table"
        and chapter_bodies.__workspace_text_dir or nil
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }

    local cover_meta = ""
    if cover_data and #cover_data > 0 then
        local ext, mime = media_type_for(cover_data)
        local cover_img_href = "images/cover" .. ext
        table.insert(entries, { name = "OEBPS/" .. cover_img_href, data = cover_data })
        table.insert(manifest_items, [[<item id="cover-image" href="]] .. xml_escape(cover_img_href) .. [[" media-type="]] .. xml_escape(mime) .. [[" properties="cover-image"/>]])
        table.insert(manifest_items, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="cover"/>]])
        local cover_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"]] .. language_attribute .. [[>
<head><title>Cover</title>
<style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}img{display:block;width:100%;height:100%;object-fit:contain;}</style>
</head>
<body><img src="../]] .. xml_escape(cover_img_href) .. [[" alt="Cover"/></body>
</html>]]
        table.insert(entries, { name = "OEBPS/text/cover.xhtml", data = cover_xhtml })
        cover_meta = '\n<meta name="cover" content="cover-image"/>'
    end

    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_items, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    append_asset_entries(entries, assets)

    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local filename = string.format("text/chapter-%03d.xhtml", chapter_index)
        local id = item_id("chapter_", uid)
        local title = chapter.title or ("Chapter " .. uid)
        if not workspace_text_dir then
            local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink"]] .. language_attribute .. [[>
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(chapter_bodies[uid] or "") .. [[
</body>
</html>]]
            table.insert(entries, { name = "OEBPS/" .. filename, data = chapter_xhtml })
        end
        table.insert(manifest_items, [[<item id="]] .. id .. [[" href="]] .. filename .. [[" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="]] .. id .. [["/>]])
    end

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/ marc: http://id.loc.gov/vocabulary/relators/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
]] .. opf_metadata(book, "weread-" .. tostring(book_id) .. "-" .. tostring(suffix or "book")) .. cover_meta .. [[
</metadata>
<manifest>
]] .. table.concat(manifest_items, "\n") .. [[
</manifest>
<spine toc="toc">
]] .. table.concat(spine_items, "\n") .. [[
</spine>
</package>]]
    local ncx_points = build_ncx_points(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end)
    local ncx = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [["/>
<meta name="dtb:depth" content="6"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. xml_escape(book_title) .. [[</text></docTitle>
<navMap>
]] .. ncx_points .. [[
</navMap>
</ncx>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol>
]] .. build_nav_items(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end) .. [[
</ol>
</nav>
</body>
</html>]]
    css = ReaderStyles.compose(css or [[body { line-height: 1.7; margin: 5%; }]])
    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = css })
    if workspace_text_dir then
        table.insert(entries, {
            name = "OEBPS/text",
            path = workspace_text_dir,
            recursive = true,
        })
    end
    write_epub(path, entries)
    Content.register_annotation_document(book, path, chapters)
    return path
end

local function normalize_asset_path(path)
    path = tostring(path or ""):gsub("&amp;", "&")
    path = path:match("^[^%?#]*") or ""
    path = path:gsub("\\", "/"):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

function Content.rewrite_image_sources(xhtml, src_map)
    src_map = src_map or {}
    local function replace_attribute(boundary, name, spacing, quote, src)
        if name:lower() ~= "src" then
            return boundary .. name .. spacing .. quote .. src .. quote
        end
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local path = normalize_asset_path(clean)
        local key = path:match("([^/]+)$") or path
        local href = src_map[path]
        if href == nil then href = src_map[key] end
        if type(href) == "string" and href ~= "" then
            return boundary .. name .. spacing .. quote .. href .. quote
        end
        if clean:match("^https?://") or clean:match("^//") then
            return boundary .. name .. spacing .. quote .. quote
        end
        if clean:match("^data:") then
            return boundary .. name .. spacing .. quote .. src .. quote
        end
        -- The original archive path is not present in the generated EPUB.
        -- Empty unresolved references rather than leaving a guaranteed broken
        -- link to a resource that was omitted or ambiguous.
        return boundary .. name .. spacing .. quote .. quote
    end
    xhtml = xhtml:gsub("([^%w:_%-])([%w:_%-]+)(%s*=%s*)(['\"])(.-)%4", replace_attribute)
    return xhtml
end

local function native_chapter_assets(client, book, chapter, used_names, asset_dir, source_payload)
    used_names = used_names or {}
    local chapter_uid = tostring(chapter.chapterUid or chapter.chapterId)
    local cache = native_chapter_cache[book]
    if not cache then
        cache = { payloads = {} }
        native_chapter_cache[book] = cache
    end
    cache.payloads = cache.payloads or {}
    if source_payload then cache.payloads[chapter_uid] = source_payload end
    local payload = source_payload
        or (cache and cache.payloads and cache.payloads[chapter_uid])
    if not payload then return {}, {} end
    cache.asset_cache = cache.asset_cache or {}
    local chapter_cache = cache.asset_cache[chapter_uid]
    if not chapter_cache then
        chapter_cache = {}
        cache.asset_cache[chapter_uid] = chapter_cache
    end
    local source_assets = {}
    for _, entry in ipairs(payload.assets or {}) do
        source_assets[#source_assets + 1] = {
            name = entry.name,
            data = entry.data,
            decrypt = true,
        }
    end
    if chapter.tar and chapter.tar ~= "" then
        if not chapter_cache.image_tar_assets then
            local ok, tar_assets = pcall(NativeChapter.fetch_image_tar, client, chapter)
            if ok then
                chapter_cache.image_tar_assets = tar_assets
            else
                logger.warn("chapter image archive:", tostring(tar_assets))
            end
        end
        for _, entry in ipairs(chapter_cache.image_tar_assets or {}) do
            source_assets[#source_assets + 1] = {
                name = entry.name,
                data = entry.data,
                decrypt = false,
            }
        end
    end
    local has_image = false
    for _, entry in ipairs(source_assets) do
        local data = entry.decrypt
            and NativeChapter.decrypt_asset(entry.data, book.book_id or book.bookId)
            or entry.data
        local _, media_type = media_type_for(data)
        if media_type:match("^image/") then has_image = true; break end
    end
    if not has_image then source_assets = {} end
    local assets = {}
    local src_map = {}
    local function add_source_alias(path, href)
        local normalized = normalize_asset_path(path)
        if normalized == "" then return end
        local parts = {}
        for part in normalized:gmatch("[^/]+") do parts[#parts + 1] = part end
        for first = 1, #parts do
            local alias = table.concat(parts, "/", first)
            if src_map[alias] == nil then
                src_map[alias] = href
            elseif src_map[alias] ~= href then
                -- Basename-only XHTML references cannot be resolved safely
                -- when different archive entries have the same suffix.
                src_map[alias] = false
            end
        end
    end
    for _, entry in ipairs(source_assets) do
        local data = entry.decrypt
            and NativeChapter.decrypt_asset(entry.data, book.book_id or book.bookId)
            or entry.data
        local ext, media_type = media_type_for(data)
        if media_type:match("^image/") then
            local stem = basename(entry.name)
            local filename = unique_asset_name(used_names, stem, ext)
            local href = "images/" .. filename
            local asset = {
                href = href,
                media_type = media_type,
            }
            if asset_dir then
                make_path(asset_dir)
                local output_path = asset_dir .. "/" .. filename
                write_file(output_path, data)
                asset.path = output_path
                asset.size = #data
                asset.store = true
            else
                asset.data = data
            end
            table.insert(assets, asset)
            local epub_relative = "../" .. href
            add_source_alias(entry.name, epub_relative)
            add_source_alias(filename, epub_relative)
        end
    end
    return assets, src_map
end

function Content.download_chapter_assets(client, book, chapter, used_names, source_payload)
    if not source_payload then native_payload(client, book, chapter) end
    return native_chapter_assets(client, book, chapter, used_names, nil, source_payload)
end

function Content.download_chapter_assets_to_files(client, book, chapter, used_names, workspace, source_payload)
    if not source_payload then native_payload(client, book, chapter) end
    return native_chapter_assets(client, book, chapter, used_names, workspace.asset_dir, source_payload)
end

local native_info_loaded = setmetatable({}, { __mode = "k" })

function Content.ensure_book_info(client, book)
    if native_info_loaded[book] then return book end
    book.book_id = book.book_id or book.bookId
    if not book.book_id or type(client.get_book_info) ~= "function" then
        native_info_loaded[book] = true
        return book
    end

    local ok, response = pcall(client.get_book_info, client, book.book_id)
    if not ok or type(response) ~= "table" then
        logger.warn("native book info unavailable:", tostring(response))
        return book
    end
    native_info_loaded[book] = true
    local data = response.data
    local info = response.bookInfo or response.book
        or (type(data) == "table" and (data.bookInfo or data.book))
        or data or response
    if type(info) == "table" then
        for _, key in ipairs({
            "title", "author", "cover", "coverUrl", "intro", "publisher",
            "isbn", "translator", "publishTime", "language",
        }) do
            if book[key] == nil and info[key] ~= nil then book[key] = info[key] end
        end
        book.version = info.version or info.bookVersion or book.version or book.bookVersion
        book.format = info.format or book.format
        book.bookType = info.bookType or book.bookType
        book.type = info.type or info.book_type or book.type or book.book_type
        book.category = info.category or book.category
        book.categoryName = info.categoryName or info.category or book.categoryName
    end
    return book
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local catalog = client:get_chapter_infos({ tostring(book_id) }, { 0 })
    local chapters = Content.readable_chapters(Content.normalize_chapters(catalog, book_id))
    book.chapters = chapters
    return chapters
end

native_payload = function(client, book, chapter)
    local chapter_uid = tostring(chapter and (chapter.chapterUid or chapter.chapterId) or "")
    if chapter_uid == "" then error("chapter is required") end
    Content.ensure_book_info(client, book)
    local cache = native_chapter_cache[book]
    if cache and cache.payloads and cache.payloads[chapter_uid] then
        cache.uid = chapter_uid
        cache.payload = cache.payloads[chapter_uid]
        return cache.payload
    end
    local auth = client.settings and client.settings:get("auth", {}) or {}
    local account = client.settings and client.settings:get("account", {}) or {}
    local vid = auth.vid
    if type(vid) ~= "string" or vid == "" then vid = account.user_vid end
    local payload = NativeChapter.fetch(client, book, chapter,
        function(encoded) return client:json_decode(encoded) end, vid)
    cache = cache or { payloads = {} }
    cache.payloads = cache.payloads or {}
    cache.payloads[chapter_uid] = payload
    cache.uid = chapter_uid
    cache.payload = payload
    native_chapter_cache[book] = cache
    return payload
end

function Content.chapter_download_batch_size(book)
    local format = tostring(book and (book.format or book.bookType) or ""):lower()
    local category = tostring(book and book.category or "")
    if (book and (tonumber(book.type) == 5 or tonumber(book.book_type) == 5
        or book.isComic == true or book.is_comic == true))
        or format:find("comic", 1, true)
        or format:find("manga", 1, true)
        or format:find("漫画", 1, true)
        or category:find("漫画", 1, true) then
        return 1
    end
    if format:find("epub", 1, true) then return 5 end
    return 25
end

function Content.prefetch_chapter_sources(client, book, chapters, offline)
    if type(chapters) ~= "table" or #chapters == 0 then return {} end
    Content.ensure_book_info(client, book)
    local auth = client.settings and client.settings:get("auth", {}) or {}
    local account = client.settings and client.settings:get("account", {}) or {}
    local vid = auth.vid
    if type(vid) ~= "string" or vid == "" then vid = account.user_vid end
    return NativeChapter.fetch_batch(client, book, chapters,
        function(encoded) return client:json_decode(encoded) end, vid,
        { offline = offline == true })
end

function Content.release_chapter_source(book, chapter)
    local uid = tostring(chapter and (chapter.chapterUid or chapter.chapterId) or "")
    local cache = native_chapter_cache[book]
    if not cache or not cache.payloads or uid == "" then return end
    cache.payloads[uid] = nil
    if cache.uid == uid then
        cache.uid = nil
        cache.payload = nil
    end
    if cache.asset_cache then cache.asset_cache[uid] = nil end
end

local function txt_heading(line)
    local title = line:gsub("^%s+", ""):gsub("%s+$", "")
    local after_number = title:match("^第(%d+)")
    if after_number then
        after_number = title:sub(#after_number + 4)
    elseif title:sub(1, #"第") == "第" then
        local remainder = title:sub(#"第" + 1)
        local offset = 1
        local chinese_digits = { "零", "〇", "一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "廿", "卅" }
        while offset <= #remainder do
            local matched
            for _, digit in ipairs(chinese_digits) do
                if remainder:sub(offset, offset + #digit - 1) == digit then
                    offset = offset + #digit
                    matched = true
                    break
                end
            end
            if not matched then break end
        end
        if offset > 1 then after_number = remainder:sub(offset) end
    end
    if after_number then
        for _, marker in ipairs({ "章", "节", "回", "卷", "部", "篇", "集" }) do
            if after_number:sub(1, #marker) == marker then return true end
        end
    end
    if title:match("^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%dIVXivx]+") then
        return true
    end
    for _, label in ipairs({ "序章", "楔子", "序言", "前言", "後記", "后记", "尾声", "番外", "目录", "目錄" }) do
        if title == label then return true end
    end
    return false
end

local function txt_list_item(line)
    local trimmed = line:gsub("^%s+", "")
    return trimmed:match("^[%*%+%-]%s+") ~= nil
        or trimmed:match("^%[%d+%]%s*") ~= nil
        or (trimmed:match("^%d+") ~= nil and (function()
            local digits = trimmed:match("^%d+")
            local marker = trimmed:sub(#digits + 1)
            return marker:match("^[%.%)]%s*") ~= nil
                or marker:sub(1, #"、") == "、"
                or marker:sub(1, #"）") == "）"
        end)())
        or trimmed:find("•", 1, true) == 1
        or trimmed:find("·", 1, true) == 1
end

local function txt_line_ends_sentence(line)
    local ending = line:gsub("%s+$", "")
    local closing = { "”", "’", "」", "』", "）", "】", "》", "〉", '"', "'", ")", "]" }
    local changed = true
    while changed do
        changed = false
        for _, suffix in ipairs(closing) do
            if ending:sub(-#suffix) == suffix then
                ending = ending:sub(1, -#suffix - 1)
                changed = true
                break
            end
        end
    end
    return ending:match("[。！？!?…]$") ~= nil or ending:match("%.%.%.$") ~= nil
end

local function join_txt_lines(previous, current)
    if previous:match("[A-Za-z0-9]$") and current:match("^[A-Za-z0-9]") then
        return previous .. " " .. current
    end
    return previous .. current
end

local function escape_txt_line(line)
    local leading = line:match("^(%s*)") or ""
    local content = line:sub(#leading + 1)
    local escaped_leading = leading:gsub(" ", "&#160;"):gsub("\t", "&#160;&#160;&#160;&#160;")
    return escaped_leading .. xml_escape(content)
end

function Content.txt_to_xhtml(text)
    text = tostring(text or ""):gsub("^\239\187\191", "")
        :gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    local paragraph = {}
    local pending_blank_lines = 0
    local function flush_blank_lines()
        if #parts > 0 then
            for _index = 1, pending_blank_lines do
                parts[#parts + 1] = '<p class="txt-blank-gap">&#160;</p>'
            end
        end
        pending_blank_lines = 0
    end
    local function flush_paragraph()
        if #paragraph > 0 then
            local preserve_short_lines = #paragraph >= 3
            for _, line in ipairs(paragraph) do
                if #line > 72 or txt_list_item(line) then
                    preserve_short_lines = false
                    break
                end
            end
            local function add_line(line)
                local prefix = txt_list_item(line) and '<p class="txt-list-item">' or "<p>"
                table.insert(parts, prefix .. escape_txt_line(line) .. "</p>")
            end
            if preserve_short_lines then
                for _, line in ipairs(paragraph) do add_line(line) end
            else
                local current
                local function flush_current()
                    if current then add_line(current); current = nil end
                end
                for _, line in ipairs(paragraph) do
                    if not current then
                        current = line
                    elseif current:match("^%s") or line:match("^%s")
                        or txt_list_item(current) or txt_list_item(line)
                        or txt_line_ends_sentence(current) then
                        flush_current()
                        current = line
                    else
                        current = join_txt_lines(current, line)
                    end
                end
                flush_current()
            end
            paragraph = {}
        end
    end

    for raw_line in (text .. "\n"):gmatch("(.-)\n") do
        local line = raw_line:gsub("%s+$", "")
        if line:match("^%s*$") then
            flush_paragraph()
            if #parts > 0 then pending_blank_lines = pending_blank_lines + 1 end
        elseif txt_heading(line) then
            flush_paragraph()
            flush_blank_lines()
            table.insert(parts, "<h2>" .. escape_txt_line(line:gsub("^%s+", "")) .. "</h2>")
        else
            if #paragraph == 0 then flush_blank_lines() end
            paragraph[#paragraph + 1] = line
        end
    end
    flush_paragraph()
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        .. '<body>\n' .. table.concat(parts, "\n") .. '\n</body></html>'
end

function Content.fetch_txt_as_xhtml(client, settings, book, chapter)
    local payload = native_payload(client, book, chapter)
    if payload.format ~= "txt" or type(payload.text) ~= "string" then
        error("native TXT chapter response was invalid")
    end
    local plain = payload.text:gsub("^\239\187\191", "")
    book._content_format = "txt"
    Content.cache_annotation_source(settings, book, chapter, plain, true)
    return Content.txt_to_xhtml(plain)
end

function Content.fetch_chapter_xhtml(client, settings, book, chapter)
    local payload = native_payload(client, book, chapter)
    if payload.format == "txt" then
        local plain = tostring(payload.text or ""):gsub("^\239\187\191", "")
        book._content_format = "txt"
        Content.cache_annotation_source(settings, book, chapter, plain, true)
        return Content.txt_to_xhtml(plain)
    end
    if type(payload.xhtml) ~= "string" or payload.xhtml == "" then
        error("native EPUB chapter response did not contain XHTML")
    end
    book._content_format = "epub"
    return payload.xhtml
end

-- True when the text following the literal "0" of a font-size declaration
-- (already captured by the caller's pattern) is only an optional unit plus
-- whitespace and an optional !important flag, i.e. the declared size really is
-- zero. Zero times any unit is still zero length, so an empty tail (bare 0) and
-- every letter-unit form (px/em/rem/vh/...) count; fractional sizes such as
-- 0.5rem never match because "." is not a letter.
local function is_zero_font_size(tail)
    local value = tail:lower():match("^%s*(.-)%s*$")
    if value:sub(-10) == "!important" then
        value = (value:match("^(.-)%s*!important$") or ""):match("^%s*(.-)%s*$")
    end
    return value == "" or value == "%" or value:match("^%a+$") ~= nil
end

-- Known limitations: property-name matching is case-sensitive (observed WeRead
-- shards use lowercase), CSS comments can contain text that resembles a
-- declaration, and root zero-size rules nested in @media blocks are not parsed.

-- True when the selector list names nothing but the root elements, i.e. every
-- comma-separated selector is exactly html or body (case- and
-- whitespace-insensitive). Compound selectors such as "body p" or
-- "body, .wrapper" also style other content, so they never qualify.
local function is_root_selector_list(selectors)
    local count = 0
    for selector in (selectors or ""):gmatch("[^,]+") do
        count = count + 1
        local name = selector:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "html" and name ~= "body" then return false end
    end
    return count > 0
end

-- Remove every zero `font-size` declaration from one braceless declaration
-- block. The sentinel "{" guarantees the boundary capture below always has a
-- character to inspect, even when the declaration opens the block.
local function strip_zero_font_sizes(block)
    local removed = 0
    local cleaned = ("{" .. block):gsub("([^%w%-])(%s*)font%-size%s*:%s*0([^;}]*)(;?)", function(boundary, leading, tail, _terminator)
        if not is_zero_font_size(tail) then
            return nil -- keep fractional sizes such as 0.5rem untouched
        end
        removed = removed + 1
        return boundary .. leading
    end)
    return cleaned:sub(2), removed
end

local function strip_fixed_font_sizes(block)
    local removed = 0
    local cleaned = ("{" .. block):gsub("([^%w%-])(%s*)font%-size%s*:%s*([^;}]*)(;?)",
        function(boundary, leading, tail, _terminator)
            if is_fixed_font_size(tail) then
                removed = removed + 1
                return boundary .. leading
            end
        end)
    return cleaned:sub(2), removed
end

local function strip_theme_neutral_colors(block)
    local removed = 0
    local cleaned = "{" .. block
    for _, property_pattern in ipairs({ "background%-color", "color" }) do
        cleaned = cleaned:gsub("([^%w%-])(%s*)" .. property_pattern
            .. "%s*:%s*([^;}]*)(;?)", function(boundary, leading, value, _terminator)
                if not is_theme_neutral_color(value) then return nil end
                removed = removed + 1
                return boundary .. leading
            end)
    end
    return cleaned:sub(2), removed
end

-- Remove root zero-size rules, absolute font sizes, and neutral text colors
-- from native book CSS. KOReader scales relative sizes and supplies the page's
-- black/white theme, while intentional colored formatting and layout remain.
local function sanitize_book_css_pass(css)
    local removed = 0
    -- Scan whole `selector { block }` units (balanced braces); untouched units
    -- are returned verbatim so no other declaration can be disturbed.
    local sanitized = css:gsub("([^{}]*)(%b{})", function(prelude, block)
        -- Text before the last ";" belongs to an at-rule or a previous
        -- statement, not to this block's selector list.
        local selectors = prelude:match("[^;]*$") or ""
        local declarations = block:sub(2, -2)
        local cleaned = declarations
        if is_root_selector_list(selectors) then
            local dropped
            cleaned, dropped = strip_zero_font_sizes(cleaned)
            removed = removed + dropped
        end
        local fixed_cleaned, fixed_dropped = strip_fixed_font_sizes(cleaned)
        cleaned = fixed_cleaned
        removed = removed + fixed_dropped
        if selectors:gsub("%s", "") ~= "" then
            local themed_cleaned, theme_dropped = strip_theme_neutral_colors(cleaned)
            cleaned = themed_cleaned
            removed = removed + theme_dropped
        end
        return prelude .. "{" .. cleaned .. "}"
    end)
    return sanitized, removed
end

function Content.sanitize_book_css(css)
    if type(css) ~= "string" or css == "" then
        return css, 0
    end
    -- Each pass consumes one boundary character per match, so adjacent zero
    -- declarations ("font-size:0;font-size:0") need repeated passes until the
    -- fixpoint; the cap only guards pathological input.
    local removed_total = 0
    local sanitized = css
    for _i = 1, 16 do
        local removed
        sanitized, removed = sanitize_book_css_pass(sanitized)
        removed_total = removed_total + removed
        if removed == 0 then break end
    end
    return sanitized, removed_total
end

function Content.fetch_chapter_css(client, settings, book, chapter)
    local ok, payload = pcall(native_payload, client, book, chapter)
    if not ok or type(payload) ~= "table" or type(payload.css) ~= "string" then
        return nil
    end
    local sanitized, removed = Content.sanitize_book_css(payload.css)
    if removed > 0 then
        logger.warn("removed ", removed, " reader-conflicting style declarations from book css")
    end
    return sanitized
end


-- Downloads always contain clean text. Annotation data is synchronized later.
local function apply_chapter_annotations(_client, _settings, _book, _chapter, xhtml, css)
    return xhtml, css
end

function Content.cache_annotation_source(settings, book, chapter, xhtml, raw_text)
    if book._content_format == "txt" and not raw_text then return end
    local ok, err = pcall(function()
        local Source = require("weread.lib.annotation_source")
        require("weread.lib.annotation_store"):new(settings):put(
            book.book_id or book.bookId, "original", tostring(chapter.chapterUid or chapter.chapterId),
            raw_text and Source.plain(xhtml) or Source.index(xhtml),
            tostring(chapter.chapterUid or chapter.chapterId))
    end)
    -- A cache failure must not turn a successful text download into a failure.
    if not ok then logger.warn("annotation source cache:", tostring(err)) end
end

function Content.register_annotation_document(book, path, chapters)
    local list = {}
    for _, chapter in ipairs(chapters) do
        list[#list + 1] = { chapterUid = chapter.chapterUid or chapter.chapterId,
            title = chapter.title, chapterIdx = chapter.chapterIdx }
    end
    book.annotation_documents = book.annotation_documents or {}
    book.annotation_documents[path] = { chapters = list, clean = true }
end

function Content.fetch_chapter_epub(client, settings, book, chapter)
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    Content.cache_annotation_source(settings, book, chapter, xhtml)
    local css = Content.fetch_chapter_css(client, settings, book, chapter)
    xhtml, css = apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
    local assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        local used_names = {}
        local src_map
        assets, src_map = Content.download_chapter_assets(client, book, chapter, used_names)
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
    else
        xhtml = Content.rewrite_image_sources(xhtml, {})
    end
    local path = Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    book.cached_chapters = book.cached_chapters or {}
    book.cached_chapters[tostring(chapter.chapterUid)] = path
    book.cached_file = path
    book.chapter_uid = chapter.chapterUid
    book.chapter_idx = chapter.chapterIdx
    return path, chapter
end

function Content.fetch_single_chapter_content(client, settings, book, chapter, state)
    state = state or {}
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    Content.cache_annotation_source(settings, book, chapter, xhtml)
    if not state.css then
        state.css = Content.fetch_chapter_css(client, settings, book, chapter)
    end
    xhtml, state.css = apply_chapter_annotations(client, settings, book, chapter, xhtml, state.css)
    local chapter_assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map = Content.download_chapter_assets(client, book, chapter, state.used_asset_names)
        for _, asset in ipairs(tar_assets) do
            table.insert(chapter_assets, asset)
        end
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
    else
        xhtml = Content.rewrite_image_sources(xhtml, {})
    end
    return xhtml, chapter_assets
end

-- Split chapter downloading around annotation fetching so the UI can request
-- thought batches cooperatively instead of blocking inside Thoughts.apply().
function Content.fetch_single_chapter_source(client, settings, book, chapter, state, source_payload)
    state = state or {}
    local payload = source_payload or native_payload(client, book, chapter)
    local xhtml
    if payload.format == "txt" then
        local plain = tostring(payload.text or ""):gsub("^\239\187\191", "")
        book._content_format = "txt"
        Content.cache_annotation_source(settings, book, chapter, plain, true)
        xhtml = Content.txt_to_xhtml(plain)
    else
        if type(payload.xhtml) ~= "string" or payload.xhtml == "" then
            error("native EPUB chapter response did not contain XHTML")
        end
        book._content_format = "epub"
        xhtml = payload.xhtml
        Content.cache_annotation_source(settings, book, chapter, xhtml)
    end
    if not state.css and type(payload.css) == "string" then
        local sanitized, removed = Content.sanitize_book_css(payload.css)
        if removed > 0 then
            logger.warn("removed ", removed, " reader-conflicting style declarations from book css")
        end
        state.css = sanitized
    end
    return xhtml, payload
end

function Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state, source_payload)
    state = state or {}
    local chapter_assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map
        if state.workspace then
            tar_assets, src_map = Content.download_chapter_assets_to_files(
                client, book, chapter, state.used_asset_names, state.workspace,
                source_payload)
        else
            tar_assets, src_map = Content.download_chapter_assets(
                client, book, chapter, state.used_asset_names, source_payload)
        end
        for _, asset in ipairs(tar_assets) do
            table.insert(chapter_assets, asset)
        end
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
    else
        xhtml = Content.rewrite_image_sources(xhtml, {})
    end
    return xhtml, chapter_assets
end

function Content.fetch_chapters_epub(client, settings, book, chapters, options)
    options = options or {}
    local selected = {}
    local bodies = {}
    local assets = {}
    local used_asset_names = {}
    local cache = settings:get("cache", {})
    local css
    for chapter_index, chapter in ipairs(chapters or {}) do
        if options.progress then
            options.progress(chapter_index, #chapters, chapter, "text")
        end
        local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
        Content.cache_annotation_source(settings, book, chapter, xhtml)
        if not css then
            css = Content.fetch_chapter_css(client, settings, book, chapter)
        end
        xhtml, css = apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
        if cache.download_book_images then
            if options.progress then
                options.progress(chapter_index, #chapters, chapter, "images")
            end
            local chapter_assets, src_map = Content.download_chapter_assets(client, book, chapter, used_asset_names)
            for _, asset in ipairs(chapter_assets) do
                table.insert(assets, asset)
            end
            xhtml = Content.rewrite_image_sources(xhtml, src_map)
        else
            xhtml = Content.rewrite_image_sources(xhtml, {})
        end
        local uid = tostring(chapter.chapterUid or chapter_index)
        table.insert(selected, chapter)
        bodies[uid] = xhtml
    end
    if #selected == 0 then
        error("No readable chapter found")
    end
    local path = Content.save_book_epub(settings, book, selected, bodies, options.suffix or "book", assets, css)
    book.cached_chapters = book.cached_chapters or {}
    for chapter_index, chapter in ipairs(selected) do
        book.cached_chapters[tostring(chapter.chapterUid or chapter_index)] = path
    end
    book.cached_file = path
    return path, selected
end

function Content.fetch_first_chapter(client, settings, book)
    Content.ensure_book_info(client, book)
    local chapters = book.chapters or Content.load_catalog_cache(client, settings, book)
    if not chapters then
        chapters = Content.fetch_catalog(client, book)
        Content.save_catalog_cache(client, settings, book, chapters)
    end
    local chapter = Content.first_readable_chapter(chapters)
    if not chapter then
        error("No readable chapter found")
    end
    return Content.fetch_chapter_epub(client, settings, book, chapter)
end


return Content
