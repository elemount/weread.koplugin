local NativeChapter = {}
local ok_bit, bit_ops = pcall(require, "bit")

local MAX_ARCHIVE_ENTRY_BYTES = 512 * 1024 * 1024

local function base64_decode(value)
    value = tostring(value or ""):gsub("-", "+"):gsub("_", "/")
    value = value:gsub("[^%w%+/%=]", "")
    local out, accumulator, bits = {}, 0, 0
    for i = 1, #value do
        local char = value:sub(i, i)
        if char == "=" then break end
        local index = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):find(char, 1, true)
        if index then
            accumulator = accumulator * 64 + index - 1
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(math.floor(accumulator / (2 ^ bits)) % 256)
                accumulator = accumulator % (2 ^ bits)
            end
        end
    end
    return table.concat(out)
end

local function repeated_vid_key(vid)
    local bytes = tostring(vid or "")
    if bytes == "" then error("missing vid for chapter key decryption") end
    while #bytes < 32 do bytes = bytes .. bytes end
    bytes = bytes:sub(1, 32)
    return bytes:sub(1, 16), bytes:sub(17, 32)
end

local openssl
local function load_openssl()
    if openssl then return openssl end
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        typedef struct wr_evp_cipher_ctx_st EVP_CIPHER_CTX;
        typedef struct wr_evp_cipher_st EVP_CIPHER;
        EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
        void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
        const EVP_CIPHER *EVP_aes_128_cbc(void);
        int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
            void *impl, const unsigned char *key, const unsigned char *iv);
        int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
            const unsigned char *in, int inl);
        int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
    ]])
    -- KOReader ships a pinned LibreSSL build and provides ffi.loadlib to find
    -- that copy. On macOS, ffi.load("crypto") can instead pick up a Homebrew
    -- OpenSSL through KOReader's search path; hardened runtime builds may
    -- abort when that external library is loaded.
    if type(ffi.loadlib) == "function" then
        local ok, lib = pcall(ffi.loadlib, "crypto", "57")
        if ok then openssl = { ffi = ffi, lib = lib }; return openssl end
    end
    for _, name in ipairs({ "libcrypto.so", "libcrypto.so.3", "libcrypto.1.1.dylib" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok then openssl = { ffi = ffi, lib = lib }; return openssl end
    end
    local global_ok = pcall(function() return ffi.C.EVP_CIPHER_CTX_new end)
    if global_ok then openssl = { ffi = ffi, lib = ffi.C }; return openssl end
    return nil
end

local commoncrypto
local function load_commoncrypto()
    if commoncrypto then return commoncrypto end
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        int CCCrypt(int op, int alg, int options, const void *key,
            unsigned long keyLength, const void *iv, const void *dataIn,
            unsigned long dataInLength, void *dataOut, unsigned long dataOutAvailable,
            unsigned long *dataOutMoved);
    ]])
    for _, name in ipairs({ "CommonCrypto", "/System/Library/Frameworks/CommonCrypto.framework/CommonCrypto" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok then commoncrypto = { ffi = ffi, lib = lib }; return commoncrypto end
    end
    return nil
end

local function aes_cbc_decrypt(ciphertext, key, iv)
    if #ciphertext == 0 or #ciphertext % 16 ~= 0 then
        error("invalid encrypted chapter key length")
    end
    local provider = load_openssl()
    if provider then
        local ffi, lib = provider.ffi, provider.lib
        local ctx = lib.EVP_CIPHER_CTX_new()
        if ctx == nil then error("could not allocate AES context") end
        local out = ffi.new("unsigned char[?]", #ciphertext + 16)
        local first_len, final_len = ffi.new("int[1]"), ffi.new("int[1]")
        local ok, err = pcall(function()
            if lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_128_cbc(), nil,
                ffi.cast("const unsigned char *", key), ffi.cast("const unsigned char *", iv)) ~= 1 then
                error("AES initialization failed")
            end
            if lib.EVP_DecryptUpdate(ctx, out, first_len,
                ffi.cast("const unsigned char *", ciphertext), #ciphertext) ~= 1 then
                error("AES decryption failed")
            end
            if lib.EVP_DecryptFinal_ex(ctx, out + first_len[0], final_len) ~= 1 then
                error("chapter key padding check failed")
            end
        end)
        lib.EVP_CIPHER_CTX_free(ctx)
        if not ok then error(err, 0) end
        return ffi.string(out, first_len[0] + final_len[0])
    end

    provider = load_commoncrypto()
    if provider then
        local ffi, lib = provider.ffi, provider.lib
        local key_buf, iv_buf, input_buf = ffi.new("uint8_t[16]"), ffi.new("uint8_t[16]"), ffi.new("uint8_t[?]", #ciphertext)
        ffi.copy(key_buf, key, 16)
        ffi.copy(iv_buf, iv, 16)
        ffi.copy(input_buf, ciphertext, #ciphertext)
        local out = ffi.new("unsigned char[?]", #ciphertext + 16)
        local moved = ffi.new("unsigned long[1]")
        local status = lib.CCCrypt(1, 0, 1, key_buf, 16, iv_buf,
            input_buf, #ciphertext, out, #ciphertext + 16, moved)
        if status ~= 0 then error("chapter key AES-CBC decryption failed: " .. tostring(status)) end
        return ffi.string(out, moved[0])
    end
    error("AES-CBC support is unavailable in this KOReader build")
end

local archive_lib
local function load_archive()
    if archive_lib then return archive_lib end
    -- Load KOReader's wrapper first so any bundled libarchive dependency is
    -- present in the process before resolving the C API.
    pcall(require, "ffi/archiver")
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        struct archive;
        struct archive_entry;
        struct archive *archive_read_new(void);
        int archive_read_support_filter_all(struct archive *);
        int archive_read_support_format_zip(struct archive *);
        int archive_read_add_passphrase(struct archive *, const char *);
        int archive_read_open_memory(struct archive *, const void *, size_t);
        int archive_read_next_header(struct archive *, struct archive_entry **);
        const char *archive_entry_pathname(struct archive_entry *);
        long archive_read_data(struct archive *, void *, size_t);
        const char *archive_error_string(struct archive *);
        int archive_read_free(struct archive *);
    ]])
    -- Prefer KOReader's loadlib helper so Kindle resolves the bundled
    -- libs/libarchive.so.13 instead of the system /usr/lib/libarchive.so,
    -- whose ABI can be incomplete for the reader APIs we need.
    local function usable_library(lib)
        return pcall(function() return lib.archive_read_new end)
    end
    if type(ffi.loadlib) == "function" then
        local ok, lib = pcall(ffi.loadlib, "archive", "13")
        if ok and usable_library(lib) then
            archive_lib = { ffi = ffi, lib = lib }
            return archive_lib
        end
    end
    -- Only try explicit versioned/bundled names here. An unversioned
    -- `ffi.load("archive")` may resolve to Kindle's /usr/lib/libarchive.so,
    -- which can load successfully but lack the reader API.
    for _, name in ipairs({ "libs/libarchive.so.13", "libarchive.so.13", "libarchive.13.dylib" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok and usable_library(lib) then
            archive_lib = { ffi = ffi, lib = lib }
            return archive_lib
        end
    end
    local global_ok = pcall(function() return ffi.C.archive_read_new end)
    if global_ok then archive_lib = { ffi = ffi, lib = ffi.C }; return archive_lib end
    return nil
end

local function extract_zip(data, password)
    if #data == 0 or #data > MAX_ARCHIVE_ENTRY_BYTES then
        error("chapter ZIP exceeds the supported size")
    end
    local provider = load_archive()
    if not provider then error("libarchive is unavailable in this KOReader build") end
    if password:find("%z") then error("chapter ZIP key contains a zero byte") end
    local ffi, lib = provider.ffi, provider.lib
    local archive = lib.archive_read_new()
    if archive == nil then error("could not allocate ZIP reader") end
    local input = ffi.new("uint8_t[?]", #data)
    ffi.copy(input, data, #data)
    local entries, entry_order, total = {}, {}, 0
    local ok, err = pcall(function()
        lib.archive_read_support_filter_all(archive)
        if lib.archive_read_support_format_zip(archive) < 0 then error("ZIP support initialization failed") end
        if lib.archive_read_add_passphrase(archive, password) < 0 then error("ZIP password setup failed") end
        if lib.archive_read_open_memory(archive, input, #data) ~= 0 then
            local message = lib.archive_error_string(archive)
            error(message ~= nil and ffi.string(message) or "could not open chapter ZIP")
        end
        local entry_out = ffi.new("struct archive_entry *[1]")
        local chunk = ffi.new("uint8_t[32768]")
        while true do
            local status = lib.archive_read_next_header(archive, entry_out)
            if status == 1 then break end
            if status ~= 0 then
                local message = lib.archive_error_string(archive)
                error(message ~= nil and ffi.string(message) or "could not read chapter ZIP entry")
            end
            local path_ptr = lib.archive_entry_pathname(entry_out[0])
            local path = path_ptr ~= nil and ffi.string(path_ptr) or ""
            local chunks, length = {}, 0
            while true do
                local count = tonumber(lib.archive_read_data(archive, chunk, 32768))
                if count == 0 then break end
                if count < 0 then
                    local message = lib.archive_error_string(archive)
                    error(message ~= nil and ffi.string(message) or "could not decrypt chapter ZIP entry")
                end
                length = length + count
                total = total + count
                if length > MAX_ARCHIVE_ENTRY_BYTES or total > MAX_ARCHIVE_ENTRY_BYTES then
                    error("chapter archive exceeds the supported size")
                end
                chunks[#chunks + 1] = ffi.string(chunk, count)
            end
            if path ~= "" then
                entries[path] = table.concat(chunks)
                entry_order[#entry_order + 1] = path
            end
        end
    end)
    lib.archive_read_free(archive)
    if not ok then error(err, 0) end
    return entries, entry_order
end

local function extract_tar(data)
    if #data > MAX_ARCHIVE_ENTRY_BYTES then
        error("TAR archive exceeds the supported size")
    end
    local entries, offset = {}, 1
    while offset + 511 <= #data do
        local header = data:sub(offset, offset + 511)
        if header:match("^%z+$") then break end
        local name = header:sub(1, 100):gsub("%z.*$", "")
        local size_text = header:sub(125, 136):gsub("%z.*$", ""):gsub("%s", "")
        local size = tonumber(size_text, 8) or 0
        local typeflag = header:sub(157, 157)
        local start = offset + 512
        if size < 0 or size > MAX_ARCHIVE_ENTRY_BYTES or start + size - 1 > #data then
            error("invalid TAR archive entry")
        end
        if name ~= "" and size > 0 and (typeflag == "0" or typeflag == "\0" or typeflag == " ") then
            entries[name] = data:sub(start, start + size - 1)
        end
        offset = start + math.ceil(size / 512) * 512
    end
    return entries
end

function NativeChapter.fetch_image_tar(client, chapter, capture_raw)
    local url = tostring(chapter and chapter.tar or "")
    if url == "" then return {} end
    -- Chapter.tar is supplied by WeRead's chapter catalog. Keep the image
    -- download on the same resource host used by the e-ink APK.
    if not url:match("^https://res%.weread%.qq%.com/") then
        error("chapter image archive URL is not a WeRead resource URL")
    end
    if type(client.get_binary) ~= "function" or type(client.native_headers) ~= "function" then
        error("authenticated binary download is unavailable for chapter images")
    end
    local headers = client:native_headers({
        Referer = "https://weread.qq.com/",
    })
    local data, _, response_headers = client:get_binary(url, {
        headers = headers,
        referer = "https://weread.qq.com/",
    })
    if type(capture_raw) == "function" then
        local metadata = {}
        for name, value in pairs(response_headers or {}) do
            if tostring(name):lower() == "content-type" then
                metadata.content_type = value
            end
        end
        pcall(capture_raw, "images", { chapter }, data, metadata)
    end
    local entries = extract_tar(data)
    if #data > 0 and next(entries) == nil then
        error("chapter image TAR did not contain readable files")
    end
    local assets = {}
    for name, value in pairs(entries) do
        assets[#assets + 1] = {
            name = name:match("([^/]+)$") or name,
            data = value,
        }
    end
    table.sort(assets, function(left, right) return left.name < right.name end)
    return assets
end

local function same_uid(left, right)
    return left ~= nil and tostring(left) == tostring(right)
end

local decrypt_file_if_needed

local function chapter_file(entries, chapter_uid, json_decode, book_id, allow_fallback)
    local info = entries["info.txt"]
    if info and json_decode then
        local decode_ok, decoded = pcall(json_decode, info)
        local records = decode_ok and type(decoded) == "table"
            and (decoded.data or decoded.chapters) or nil
        if type(records) == "table" then
            for _, record in ipairs(records) do
                if same_uid(record.chapterUid or record.uid, chapter_uid)
                    and type(record.files) == "table" and #record.files > 0 then
                    local chunks, names = {}, {}
                    for _, file_name in ipairs(record.files) do
                        local name = tostring(file_name)
                        local body = entries[name]
                        if not body then
                            local leaf = name:match("([^/]+)$")
                            if leaf then name, body = leaf, entries[leaf] end
                        end
                        if not body then
                            error("chapter archive omitted file " .. tostring(file_name)
                                .. " for chapter " .. tostring(chapter_uid))
                        end
                        names[#names + 1] = name
                        chunks[#chunks + 1] = decrypt_file_if_needed(body, book_id)
                    end
                    return table.concat(chunks), names
                end
            end
        end
    end
    local matches = {}
    for name, body in pairs(entries) do
        if name:lower():match("%.x?html?$") and name:find(tostring(chapter_uid), 1, true) then
            matches[#matches + 1] = { name = name, body = body }
        end
    end
    table.sort(matches, function(a, b) return a.name < b.name end)
    if #matches > 0 then
        return decrypt_file_if_needed(matches[1].body, book_id), { matches[1].name }
    end
    if allow_fallback == false then return nil end
    for name, body in pairs(entries) do
        if name:lower():match("%.xhtml$") or name:lower():match("%.html$") then
            return decrypt_file_if_needed(body, book_id), { name }
        end
    end
    return nil
end

local function text_chapter_file(entries, book_id, chapter_uid)
    local prefix = tostring(book_id) .. "_" .. tostring(chapter_uid)
    for name, body in pairs(entries) do
        if name == prefix or name:sub(1, #prefix + 1) == prefix .. "_" then
            return body
        end
    end
    return nil
end

local function xor_book_bytes(data, book_id)
    local key = tostring(book_id or "")
    if key == "" then return data end
    local out, key_len = {}, #key
    local xor_byte = ok_bit and bit_ops.bxor or function(a, b)
        local result, place = 0, 1
        while a > 0 or b > 0 do
            if a % 2 ~= b % 2 then result = result + place end
            a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
        end
        return result
    end
    for offset = 0, #data - 1 do
        local key_index = (offset + math.floor(offset / key_len)) % key_len + 1
        out[#out + 1] = string.char(xor_byte(data:byte(offset + 1), key:byte(key_index)))
    end
    return table.concat(out)
end

local function looks_like_markup(value)
    if not value then return false end
    local prefix = value:gsub("^\239\187\191", "")
    return prefix:match("^%s*<[%w!?/]") ~= nil
end

local function looks_like_stylesheet(value)
    if type(value) ~= "string" or not value:find("{", 1, true)
        or not value:find("}", 1, true) or not value:find(":", 1, true) then
        return false
    end
    local printable = 0
    for index = 1, #value do
        local byte = value:byte(index)
        if byte >= 32 or byte == 9 or byte == 10 or byte == 13 then
            printable = printable + 1
        end
    end
    return #value > 0 and printable / #value >= 0.9
end

decrypt_file_if_needed = function(data, book_id)
    if looks_like_markup(data) or looks_like_stylesheet(data) then return data end
    local decoded = xor_book_bytes(data, book_id)
    if looks_like_markup(decoded) or looks_like_stylesheet(decoded) then return decoded end
    return data
end

function NativeChapter.extract_stylesheets(entries, entry_order, book_id)
    if type(entries) ~= "table" then return nil end
    local names, seen = {}, {}
    local function add_name(name)
        if type(name) ~= "string" or not name:lower():match("%.css$")
            or seen[name] or type(entries[name]) ~= "string" then
            return
        end
        seen[name] = true
        names[#names + 1] = name
    end
    for _, name in ipairs(type(entry_order) == "table" and entry_order or {}) do
        add_name(name)
    end
    if #names == 0 then
        for name in pairs(entries) do add_name(name) end
        table.sort(names, function(left, right)
            return left:lower() < right:lower()
        end)
    end
    if #names == 0 then return nil end
    local stylesheets = {}
    for _, name in ipairs(names) do
        stylesheets[#stylesheets + 1] = decrypt_file_if_needed(entries[name], book_id)
    end
    return table.concat(stylesheets, "\n")
end

function NativeChapter.decrypt_asset(data, book_id)
    local function image_signature(value)
        return value:sub(1, 8) == "\137PNG\r\n\026\n"
            or value:sub(1, 3) == "\255\216\255"
            or value:sub(1, 6) == "GIF87a"
            or value:sub(1, 6) == "GIF89a"
            or (value:sub(1, 4) == "RIFF" and value:sub(9, 12) == "WEBP")
    end
    if image_signature(data) then return data end
    local decoded = xor_book_bytes(data, book_id)
    return image_signature(decoded) and decoded or data
end

local function build_chapter_ids(chapters)
    local ids = {}
    for _, chapter in ipairs(chapters or {}) do
        local uid = tonumber(chapter and (chapter.chapterUid or chapter.chapterId))
        if not uid then error("chapter uid must be numeric") end
        ids[#ids + 1] = uid
    end
    table.sort(ids)
    local ranges, first, last = {}, nil, nil
    for _, uid in ipairs(ids) do
        if first == nil then
            first, last = uid, uid
        elseif uid > last then
            if uid == last + 1 then
                last = uid
            else
                ranges[#ranges + 1] = first == last
                    and tostring(first) or (tostring(first) .. "-" .. tostring(last))
                first, last = uid, uid
            end
        end
    end
    if first ~= nil then
        ranges[#ranges + 1] = first == last
            and tostring(first) or (tostring(first) .. "-" .. tostring(last))
    end
    if #ranges == 0 then error("at least one chapter is required") end
    return table.concat(ranges, ",")
end

function NativeChapter.request_chapters_with_stylesheet(chapters, include_stylesheet)
    local requested = {}
    if include_stylesheet then
        -- The e-ink APK prepends UID 0 to the first EPUB request. It carries
        -- shared EPUB resources such as Styles/stylesheets.css, not a catalog
        -- chapter and must not be added to the generated book spine.
        requested[#requested + 1] = { chapterUid = 0 }
    end
    for _i, chapter in ipairs(chapters or {}) do
        requested[#requested + 1] = chapter
    end
    return requested, build_chapter_ids(requested)
end

function NativeChapter.fetch_batch(client, book, chapters, json_decode, vid, options)
    options = options or {}
    local book_id = tostring(book.book_id or book.bookId or "")
    if book_id == "" or type(chapters) ~= "table" or #chapters == 0 then
        error("book id and chapters are required")
    end
    local format = tostring(book.format or book.bookType or chapters[1].format or "epub"):lower()
    local book_type = format:find("txt", 1, true) and "txt" or "epub"
    local request_chapters, chapter_ids = NativeChapter.request_chapters_with_stylesheet(
        chapters, book_type == "epub" and options.include_stylesheet == true)
    local params = {
        bookId = book_id,
        chapters = chapter_ids,
        pf = "wechat_wx-2001-android-100-weread",
        pfkey = "pfKey",
        zoneId = "1",
        bookVersion = tonumber(book.version or book.bookVersion) or 0,
        bookType = book_type,
        quote = "",
        release = 1,
        stopAutoPayWhenBNE = 1,
        preload = 0,
        preview = 0,
        offline = options.offline and 1 or 0,
    }
    local body, _, headers = client:native_get_binary("/book/chapterdownload", params, {
        referer = "https://weread.qq.com/",
    })
    local encryptkey, content_type
    for name, value in pairs(headers or {}) do
        local lower_name = tostring(name):lower()
        if lower_name == "encryptkey" then
            encryptkey = value
        elseif lower_name == "content-type" then
            content_type = value
        end
    end
    if type(options.capture_raw) == "function" then
        pcall(options.capture_raw, "chapter-" .. book_type, request_chapters, body, {
            encryptkey = encryptkey,
            content_type = content_type,
        })
    end
    if book_type == "txt" then
        local entries = extract_tar(body)
        local payloads = {}
        for _, chapter in ipairs(chapters) do
            local uid = chapter.chapterUid or chapter.chapterId
            local text = text_chapter_file(entries, book_id, uid)
            if not text then
                error("TXT chapter archive did not contain chapter " .. tostring(uid))
            end
            payloads[tostring(uid)] = { text = text, format = "txt" }
        end
        return payloads
    end
    if type(encryptkey) ~= "string" or encryptkey == "" then
        error("chapter response is missing encryptkey header")
    end
    local aes_key, aes_iv = repeated_vid_key(vid)
    local zip_password = aes_cbc_decrypt(base64_decode(encryptkey), aes_key, aes_iv)
    local entries, entry_order = extract_zip(body, zip_password)
    local chapters_by_uid, chapter_files = {}, {}
    for _, chapter in ipairs(chapters) do
        local uid = chapter.chapterUid or chapter.chapterId
        local xhtml, xhtml_names = chapter_file(
            entries, uid, json_decode, book_id, #chapters == 1)
        if not xhtml then
            error("chapter archive did not contain chapter " .. tostring(uid))
        end
        chapters_by_uid[tostring(uid)] = {
            xhtml = xhtml,
            format = "epub",
        }
        for _, name in ipairs(xhtml_names) do chapter_files[name] = true end
    end
    if options.include_stylesheet then
        local _stylesheet, shared_files = chapter_file(
            entries, 0, json_decode, book_id, false)
        for _, name in ipairs(shared_files or {}) do chapter_files[name] = true end
    end
    local css = NativeChapter.extract_stylesheets(entries, entry_order, book_id)
    local assets = {}
    for name, value in pairs(entries) do
        if not chapter_files[name] and name ~= "info.txt"
            and not name:lower():match("%.css$") then
            assets[#assets + 1] = { name = name:match("([^/]+)$") or name, data = value }
        end
    end
    for _, payload in pairs(chapters_by_uid) do
        payload.css = css
        local chapter_assets = {}
        for _, asset in ipairs(assets) do
            local leaf = tostring(asset.name or ""):match("([^/]+)$")
            if leaf and leaf ~= "" and payload.xhtml:find(leaf, 1, true) then
                chapter_assets[#chapter_assets + 1] = asset
            end
        end
        payload.assets = #chapter_assets > 0 and chapter_assets or assets
    end
    return chapters_by_uid
end

function NativeChapter.fetch(client, book, chapter, json_decode, vid, options)
    local uid = chapter and (chapter.chapterUid or chapter.chapterId)
    if uid == nil then error("book id and chapter uid are required") end
    local payloads = NativeChapter.fetch_batch(client, book, { chapter },
        json_decode, vid, options)
    local payload = payloads[tostring(uid)]
    if not payload then error("chapter archive did not contain the requested chapter") end
    return payload
end

return NativeChapter
