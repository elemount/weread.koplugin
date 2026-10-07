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
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
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
body_fragment = function(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = {}
    local remaining = xhtml
    while remaining ~= "" do
        local body_start = remaining:find("<body", 1, true)
        if not body_start then
            break
        end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then
            break
        end
        local body_close = remaining:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end
    if #bodies > 0 then
        return table.concat(bodies, "\n")
    end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    return xhtml
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

function Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))
    book.cache_dir = dir
    local book_title = book.title or "WeRead"
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (chapter.title or tostring(chapter.chapterUid or "chapter"))) .. ".epub"
    local title = chapter.title or book.title or "WeRead"
    local author = book.author or "WeRead"
    local manifest_assets = {}
    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_assets, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(chapter.chapterUid or "chapter") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. "https://i.weread.qq.com/book/info?bookId=" .. xml_escape(book_id) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>
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
    local path = dir .. "/" .. filename_safe(book_title .. " - " .. (suffix or "book")) .. ".epub"
    local author = book.author or "WeRead"
    local description_meta = ""
    local description = xml_escape(book.intro)
    if description ~= "" then
        description_meta = "\n<dc:description>" .. description .. "</dc:description>"
    end
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
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
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
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
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
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>]] .. description_meta .. [[
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. "https://i.weread.qq.com/book/info?bookId=" .. xml_escape(book_id) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
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

function Content.rewrite_image_sources(xhtml, src_map)
    src_map = src_map or {}
    local function replace_src(quote, src)
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local key = basename(clean:match("^[^%?#]+") or clean)
        local href = src_map[key]
        if href then
            return "src=" .. quote .. href .. quote
        end
        if clean:match("^https?://") or clean:match("^//") then
            return "src=" .. quote .. "" .. quote
        end
        return "src=" .. quote .. src .. quote
    end
    xhtml = xhtml:gsub("src=(['\"])(.-)%1", replace_src)
    return xhtml
end

local function native_chapter_assets(client, book, chapter, used_names, asset_dir)
    used_names = used_names or {}
    local cache = native_chapter_cache[book]
    local payload = cache and cache.uid == tostring(chapter.chapterUid or chapter.chapterId)
        and cache.payload or nil
    if not payload then return {}, {} end
    local source_assets = {}
    for _, entry in ipairs(payload.assets or {}) do
        source_assets[#source_assets + 1] = {
            name = entry.name,
            data = entry.data,
            decrypt = true,
        }
    end
    if chapter.tar and chapter.tar ~= "" then
        if not cache.image_tar_assets then
            local ok, tar_assets = pcall(NativeChapter.fetch_image_tar, client, chapter)
            if ok then
                cache.image_tar_assets = tar_assets
            else
                logger.warn("chapter image archive:", tostring(tar_assets))
            end
        end
        for _, entry in ipairs(cache.image_tar_assets or {}) do
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
            src_map[stem] = epub_relative
            src_map[filename] = epub_relative
        end
    end
    return assets, src_map
end

function Content.download_chapter_assets(client, book, chapter, used_names)
    native_payload(client, book, chapter)
    return native_chapter_assets(client, book, chapter, used_names)
end

function Content.download_chapter_assets_to_files(client, book, chapter, used_names, workspace)
    native_payload(client, book, chapter)
    return native_chapter_assets(client, book, chapter, used_names, workspace.asset_dir)
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
        for _, key in ipairs({ "title", "author", "cover", "coverUrl" }) do
            if book[key] == nil and info[key] ~= nil then book[key] = info[key] end
        end
        book.version = info.version or info.bookVersion or book.version or book.bookVersion
        book.format = info.format or book.format
        book.bookType = info.bookType or book.bookType
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
    if cache and cache.uid == chapter_uid then return cache.payload end
    local auth = client.settings and client.settings:get("auth", {}) or {}
    local account = client.settings and client.settings:get("account", {}) or {}
    local vid = auth.vid
    if type(vid) ~= "string" or vid == "" then vid = account.user_vid end
    local payload = NativeChapter.fetch(client, book, chapter,
        function(encoded) return client:json_decode(encoded) end, vid)
    native_chapter_cache[book] = { uid = chapter_uid, payload = payload }
    return payload
end

function Content.txt_to_xhtml(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            table.insert(parts, "<p>" .. xml_escape(line) .. "</p>")
        end
    end
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

-- Known limitations: property-name matching is case-sensitive (all observed
-- WeRead shards are lowercase), a CSS comment containing exactly
-- "font-size: 0" may have its interior rewritten without structural harm, and
-- only top-level rules naming exactly html/body are touched (:root,
-- descendant selectors and @media-wrapped rules are left as-is).

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

-- Strip hostile `font-size: 0` declarations from server-provided book css, but
-- only inside rules whose selector list is exactly `html` and/or `body`.
-- WeRead shards occasionally ship `html, body { ... font-size: 0; }`; WeRead's
-- own apps ignore root-element sizing but crengine honors it, collapsing the
-- whole book to a near-zero font size on device. Elsewhere `font-size: 0` can
-- be intentional (e.g. hiding whitespace between inline-block items), so every
-- other rule passes through verbatim.
local function sanitize_book_css_pass(css)
    local removed = 0
    -- Scan whole `selector { block }` units (balanced braces); untouched units
    -- are returned verbatim so no other declaration can be disturbed.
    local sanitized = css:gsub("([^{}]*)(%b{})", function(prelude, block)
        -- Text before the last ";" belongs to an at-rule or a previous
        -- statement, not to this block's selector list.
        local selectors = prelude:match("[^;]*$") or ""
        if not is_root_selector_list(selectors) then
            return prelude .. block
        end
        local cleaned, dropped = strip_zero_font_sizes(block:sub(2, -2))
        removed = removed + dropped
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
        logger.warn("removed ", removed, " hostile font-size:0 declarations from book css")
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
    local book_id = book.book_id or book.bookId
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
function Content.fetch_single_chapter_source(client, settings, book, chapter, state)
    state = state or {}
    local xhtml = Content.fetch_chapter_xhtml(client, settings, book, chapter)
    Content.cache_annotation_source(settings, book, chapter, xhtml)
    if not state.css then
        state.css = Content.fetch_chapter_css(client, settings, book, chapter)
    end
    return xhtml
end

function Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state)
    state = state or {}
    local chapter_assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map
        if state.workspace then
            tar_assets, src_map = Content.download_chapter_assets_to_files(
                client, book, chapter, state.used_asset_names, state.workspace)
        else
            tar_assets, src_map = Content.download_chapter_assets(
                client, book, chapter, state.used_asset_names)
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
