local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 3

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    device_fingerprint = "",
    auth = {
        vid = "",
        access_token = "",
        refresh_token = "",
    },
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    downloads = {},
    sync = {
        pull_on_open = false,
        ask_on_conflict = true,
    },
    cache = {
        download_book_images = true,
        download_underlines_and_thoughts = false,
        prefetch_annotations = false,
        auto_prefetch_next_chapter = false,
        show_prefetch_notifications = true,
        show_annotations = true,
        -- When true, taps in the left/right edge zones never open thought popups
        -- (and native #wrthought link follow is suppressed there too).
        ignore_edge_thought_taps = true,
        -- Fraction of screen width on each side treated as the page-turn edge zone.
        edge_tap_ratio = 0.20,
        max_size_mb = 1024,
    },
    thought_popup = {
        -- Thought popup height as a fraction of the screen height.
        height_ratio = 0.70,
        -- Popup font size relative to the document font size; used while
        -- font_size is unset. Zero follows the document font size exactly.
        font_size_relative = 0,
        -- Fixed absolute popup font size (unscaled px); when set it takes
        -- precedence over font_size_relative.
        font_size = nil,
        -- Popup position: "center" (TextViewer-style centered window with
        -- page buttons, default) or "bottom" (solid-line bottom bar).
        position = "center",
        -- Centered popup width as a fraction of the screen width (only used
        -- when position is "center").
        width_ratio = 0.8,
        -- Text contrast delta for the popup blocks: +9 (the default) renders
        -- every text block in pure black; lower values progressively lighten it.
        contrast = 9,
        -- Tap the left/right half of the popup to turn pages (bottom and
        -- centered positions; off by default).
        tap_to_page = false,
    },
    advanced = {
        developer_logs = false,
    },
    update = {
        auto_check = false,
        prefer_proxy = true,
        last_check = 0,
        skipped_version = "",
        snoozed_version = "",
        snooze_until = 0,
        available_version = "",
        archive_url = "",
        checksum_url = "",
        archive_size = 0,
        release_notes = "",
        release_url = "",
    },
    shelf = {
        sort_order = "time_desc",
        paginated = true,
        view_mode = "list",
    },
    download_dir = "",
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(store)
    store:saveSetting("api_key", nil)
    store:saveSetting("cookies", nil)
    store:saveSetting("auth", deepcopy(defaults.auth))
    store:saveSetting("account", deepcopy(defaults.account))
end

function Settings:new()
    local Environment = require("weread.lib.mock_environment")
    local environment = Environment.active()
    local mock_endpoint
    if environment.enabled then
        -- Invalid saved configuration must never silently select production.
        mock_endpoint = assert(Environment.endpoint(environment))
    end
    local name = mock_endpoint and "weread-mock" or "weread"
    local data_dir = DataStorage:getFullDataDir() .. "/" .. name
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/" .. name .. ".lua",
        mock_endpoint = mock_endpoint,
        collection_name = name,
    }
    obj.store = LuaSettings:open(obj.settings_file)
    if mock_endpoint then
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        obj.store:saveSetting("auth", {
            vid = "900000", access_token = "mock-only", refresh_token = "",
        })
        obj.store:saveSetting("cookies", nil)
        obj.store:saveSetting("account", { name = "Mock", user_vid = "900000", login_method = "mock" })
        -- A test must not move downloaded files into a production cache.
        obj.store:saveSetting("download_dir", "")
        obj.store:flush()
    end
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    local sync = obj.store:readSetting("sync", deepcopy(defaults.sync))
    local sync_changed = false
    for _, key in ipairs({ "upload_on_close", "upload_interval_minutes" }) do
        if sync[key] ~= nil then
            sync[key] = nil
            sync_changed = true
        end
    end
    if sync_changed then
        obj.store:saveSetting("sync", sync)
        obj.store:flush()
    end
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if cache.download_book_images == nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    if cache.download_mp_images ~= nil then
        cache.download_mp_images = nil
        cache_changed = true
    end
    if cache.book_footnotes_in_popup ~= nil then
        cache.book_footnotes_in_popup = nil
        cache_changed = true
    end
    if cache.download_underlines_and_thoughts == nil then
        cache.download_underlines_and_thoughts = false
        cache_changed = true
    end
    if cache.prefetch_annotations == nil then
        -- Annotation prefetch now stores reusable source data instead of
        -- embedding marks in downloaded EPUBs, so it starts as a new opt-in.
        cache.prefetch_annotations = false
        cache_changed = true
    end
    if cache.auto_prefetch_next_chapter == nil then
        cache.auto_prefetch_next_chapter = false
        cache_changed = true
    end
    if cache.show_prefetch_notifications == nil then
        cache.show_prefetch_notifications = true
        cache_changed = true
    end
    if cache.show_annotations == nil then
        cache.show_annotations = true
        cache_changed = true
    end
    if cache.ignore_edge_thought_taps == nil then
        cache.ignore_edge_thought_taps = true
        cache_changed = true
    end
    if cache.edge_tap_ratio == nil then
        cache.edge_tap_ratio = 0.20
        cache_changed = true
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj.store:saveSetting("cache", cache)
        obj.store:flush()
    end
    local legacy_changed = false
    for _, key in ipairs({
        "api_key",
        "wr_ticket",
        "wr_wrpa",
        "read_report",
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            if type(obj.store.delSetting) == "function" then
                obj.store:delSetting(key)
            else
                obj.store:saveSetting(key, nil)
            end
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < 1 then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj.store)
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    elseif stored_auth_version < 2 then
        -- v1 stored the APK vid/accessToken pair inside a cookie jar. Keep a
        -- valid QR login while moving it into its own native auth record.
        local cookies = obj.store:readSetting("cookies", {}) or {}
        local account = obj.store:readSetting("account", {}) or {}
        local vid = cookies.wr_vid or account.user_vid or ""
        local access_token = cookies.wr_skey or ""
        obj.store:saveSetting("auth", {
            vid = tostring(vid),
            access_token = tostring(access_token),
            refresh_token = "",
        })
        obj.store:saveSetting("cookies", nil)
        obj.store:saveSetting("auth_schema_version", 2)
        stored_auth_version = 2
        legacy_changed = true
    end
    if stored_auth_version > 0 and stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- v2 has native QR credentials but did not retain the refresh token
        -- returned by /login. Preserve the active session and add the field;
        -- it will be populated after the next QR login.
        local auth = obj.store:readSetting("auth", {}) or {}
        obj.store:saveSetting("auth", {
            vid = tostring(auth.vid or ""),
            access_token = tostring(auth.access_token or ""),
            refresh_token = tostring(auth.refresh_token or ""),
        })
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj.store:flush()
    end
    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        return self.store:readSetting(key, deepcopy(default))
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    for book_id, index in pairs(indexes or {}) do
        books[book_id] = BookStore.load(self, book_id, index)
    end
    return books
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local indexes = {}
        for book_id, book in pairs(value) do
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
        end
        value = indexes
    end
    self.store:saveSetting(key, value)
end

function Settings:delete(key)
    if type(self.store.delSetting) == "function" then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, nil)
    end
end

function Settings:has_legacy_book_records()
    local books = self.store:readSetting("books", {})
    return not BookStore.is_minimal_index(books)
end

function Settings:flush()
    self.store:flush()
end

function Settings:get_device_fingerprint()
    local fingerprint = self:get("device_fingerprint", "")
    if type(fingerprint) == "string" and #fingerprint == 32
        and fingerprint:match("^eink%d+$") then
        return fingerprint
    end

    -- The APK uses an "eink"-prefixed device ID derived from Android-only
    -- hardware values. Keep a KOReader-specific ID in the same format; it must
    -- survive logout and QR retries.
    local source = io.open("/dev/urandom", "rb")
    if not source then error("Could not generate WeRead device fingerprint") end
    local bytes = source:read(8)
    source:close()
    if not bytes or #bytes ~= 8 then
        error("Could not generate WeRead device fingerprint")
    end
    fingerprint = require("weread.lib.device_identity").make_device_id(bytes)
    self:set("device_fingerprint", fingerprint)
    self:flush()
    return fingerprint
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.auth) == "table" then
        local auth = credentials.auth
        if options.replace_auth ~= true then
            local current = self:get("auth", {}) or {}
            auth = {
                vid = auth.vid ~= nil and auth.vid or current.vid or "",
                access_token = auth.access_token ~= nil
                    and auth.access_token or current.access_token or "",
                refresh_token = auth.refresh_token ~= nil
                    and auth.refresh_token or current.refresh_token or "",
            }
        else
            auth = {
                vid = tostring(auth.vid or ""),
                access_token = tostring(auth.access_token or ""),
                refresh_token = tostring(auth.refresh_token or ""),
            }
        end
        self:set("auth", auth)
        changed = true
    end

    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

-- Pass nil or "" to reset to the default download directory.
function Settings:set_download_dir(path)
    if self.mock_endpoint then return self.cache_dir end
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    clear_auth_store(self.store)
    self:flush()
end

function Settings:is_authenticated()
    local auth = self:get("auth", {}) or {}
    local vid = auth.vid
    if type(vid) ~= "string" or vid == "" then
        vid = (self:get("account", {}) or {}).user_vid
    end
    return type(vid) == "string" and vid ~= ""
        and type(auth.access_token) == "string" and auth.access_token ~= ""
end

return Settings
