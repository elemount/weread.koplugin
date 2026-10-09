-- Opt-in, bounded cache of raw native chapter/image archive responses for debugging.
local lfs = require("libs/libkoreader-lfs")

local RawArchiveCache = {}

local MAX_ARCHIVES_PER_BOOK = 16
local MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
local MAX_BOOK_CACHE_BYTES = 128 * 1024 * 1024
local sequence = 0

local EXTENSIONS = {
    ["chapter-epub"] = "zip",
    ["chapter-txt"] = "tar",
    images = "tar",
}

local function safe_component(value)
    local result = tostring(value or ""):gsub("[^%w%._-]", "_")
    return result ~= "" and result or "unknown"
end

local function chapter_label(chapters)
    local ids = {}
    for _i, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local uid = chapter and (chapter.chapterUid or chapter.chapterId)
        if uid ~= nil then ids[#ids + 1] = safe_component(uid) end
    end
    table.sort(ids)
    local label = #ids > 0 and table.concat(ids, "-") or "unknown"
    if #label > 80 then label = label:sub(1, 80) end
    return label
end

local function list_archives(directory)
    local files, total_bytes = {}, 0
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".."
            and (name:match("%.zip$") or name:match("%.tar$")) then
            local path = directory .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                local size = tonumber(attr.size) or 0
                local metadata = lfs.attributes(path .. ".meta")
                if metadata and metadata.mode == "file" then
                    size = size + (tonumber(metadata.size) or 0)
                end
                files[#files + 1] = { path = path, name = name, size = size }
                total_bytes = total_bytes + size
            end
        end
    end
    table.sort(files, function(left, right) return left.name < right.name end)
    return files, total_bytes
end

local function write_atomic(path, data)
    local temporary = path .. ".part"
    local file, err = io.open(temporary, "wb")
    if not file then return false, err end
    local written, write_error = file:write(data)
    local closed, close_error = file:close()
    if not written or not closed then
        os.remove(temporary)
        return false, write_error or close_error
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then os.remove(temporary) end
    return renamed, rename_error
end

local function metadata_text(kind, chapters, metadata)
    local values = { "kind=" .. safe_component(kind) }
    local ids = chapter_label(chapters)
    values[#values + 1] = "chapters=" .. ids
    for _, key in ipairs({ "content_type", "encryptkey" }) do
        local value = type(metadata) == "table" and metadata[key] or nil
        if type(value) == "string" and value ~= "" then
            value = value:gsub("[%z\r\n]", ""):sub(1, 2048)
            values[#values + 1] = key .. "=" .. value
        end
    end
    return table.concat(values, "\n") .. "\n"
end

local function prune(directory)
    local files, total_bytes = list_archives(directory)
    while #files > MAX_ARCHIVES_PER_BOOK or total_bytes > MAX_BOOK_CACHE_BYTES do
        local oldest = table.remove(files, 1)
        if not oldest then break end
        if os.remove(oldest.path) then
            os.remove(oldest.path .. ".meta")
            total_bytes = total_bytes - oldest.size
        end
    end
end

function RawArchiveCache.save(book_dir, kind, chapters, data, metadata)
    if type(book_dir) ~= "string" or book_dir == ""
        or type(data) ~= "string" then
        return false, "invalid_archive"
    end
    local extension = EXTENSIONS[kind]
    if not extension then return false, "unsupported_archive_kind" end
    if #data == 0 or #data > MAX_ARCHIVE_BYTES then
        return false, "archive_size_limit"
    end

    local directory = book_dir .. "/.raw-downloads"
    local status = os.execute("mkdir -p " .. string.format("%q", directory))
    if status ~= true and status ~= 0 then
        return false, "cache_directory_unavailable"
    end

    sequence = sequence + 1
    local filename = table.concat({
        os.date("%Y%m%d-%H%M%S"),
        string.format("%06d", sequence % 1000000),
        tostring(math.random(100000, 999999)),
        safe_component(kind),
        chapter_label(chapters),
    }, "-") .. "." .. extension
    local path = directory .. "/" .. filename
    local written, write_error = write_atomic(path, data)
    if not written then return false, write_error or "cache_write_failed" end
    local metadata_written, metadata_error = write_atomic(
        path .. ".meta", metadata_text(kind, chapters, metadata))
    if not metadata_written then
        os.remove(path)
        return false, metadata_error or "cache_metadata_write_failed"
    end
    prune(directory)
    return true, path
end

return RawArchiveCache
