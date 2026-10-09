package.path = "./?.lua;./?/init.lua;" .. package.path

local function quoted(path)
    return string.format("%q", path)
end

local lfs = {}
function lfs.dir(path)
    local pipe = assert(io.popen("ls -a " .. quoted(path), "r"))
    return function()
        local name = pipe:read("*l")
        if not name then pipe:close() end
        return name
    end
end
function lfs.attributes(path)
    local directory = io.popen("test -d " .. quoted(path) .. " && echo yes", "r")
    local is_directory = directory:read("*l") == "yes"
    directory:close()
    if is_directory then return { mode = "directory" } end
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end") or 0
    file:close()
    return { mode = "file", size = size }
end
package.preload["libs/libkoreader-lfs"] = function() return lfs end

local RawArchiveCache = require("weread.lib.raw_archive_cache")
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. quoted(root)))

for chapter = 1, 18 do
    local ok, path = RawArchiveCache.save(root, "chapter-epub",
        { { chapterUid = chapter } }, "zip-payload-" .. tostring(chapter), {
            encryptkey = "fixture-encryptkey",
            content_type = "application/zip",
            accessToken = "must-not-be-written",
        })
    assert(ok and path:match("%.zip$"), "raw EPUB archive was not saved")
end

local directory = root .. "/.raw-downloads"
local count, latest_found = 0, false
for name in lfs.dir(directory) do
    if name:match("%.zip$") or name:match("%.tar$") then
        count = count + 1
        if name:find("chapter%-epub%-18") then latest_found = true end
    end
end
assert(count == 16, "raw archive cache did not enforce its per-book file bound")
assert(latest_found, "raw archive cache pruned the newest archive")
local latest_metadata
for name in lfs.dir(directory) do
    if name:match("chapter%-epub%-18.*%.zip$") then
        local file = assert(io.open(directory .. "/" .. name .. ".meta", "rb"))
        latest_metadata = file:read("*a")
        file:close()
        break
    end
end
assert(latest_metadata and latest_metadata:find("encryptkey=fixture-encryptkey", 1, true),
    "raw archive sidecar omitted the decryption header needed for debugging")
assert(not latest_metadata:find("accessToken", 1, true),
    "raw archive sidecar persisted an account credential")

local image_ok, image_path = RawArchiveCache.save(root, "images",
    { { chapterUid = 99 } }, "tar-payload")
assert(image_ok and image_path:match("%.tar$"), "raw image TAR was not saved")
local unsupported = RawArchiveCache.save(root, "unknown", {}, "payload")
assert(not unsupported, "unsupported raw archive kind was accepted")

assert(os.execute("rm -rf " .. quoted(root)))
print("raw_archive_cache_spec: bounded chapter/TAR capture passed")
