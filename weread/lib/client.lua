local ltn12 = require("ltn12")
local logger = require("weread.lib.logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local WeRead = require("weread.lib.protocol")
local DeviceIdentity = require("weread.lib.device_identity")
local Crypto = require("weread.lib.crypto")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
-- The e-ink APK talks to the same native WeRead service used by the mobile
-- clients. Its LoginStateInterceptor sends these credentials on every call.
local NATIVE_API_BASE = "https://i.weread.qq.com"
local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function query_string(params)
    local keys = {}
    for key, value in pairs(params or {}) do
        if value ~= nil then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if type(value) == "table" then
            local values = {}
            for _, item in ipairs(value) do values[#values + 1] = WeRead.urlencode(item) end
            parts[#parts + 1] = WeRead.urlencode(key) .. "=" .. table.concat(values, ",")
        else
            parts[#parts + 1] = WeRead.urlencode(key) .. "=" .. WeRead.urlencode(value)
        end
    end
    return table.concat(parts, "&")
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deepcopy(item) end
    return out
end

local function merge_req_opts(default_opts, user_opts)
    local result = deepcopy(default_opts or {})
    if type(user_opts) ~= "table" then return result end
    for key, value in pairs(user_opts) do
        if key == "headers" and type(value) == "table" then
            result.headers = result.headers or {}
            for header, header_content in pairs(value) do
                local target = tostring(header):lower()
                for existing in pairs(result.headers) do
                    if tostring(existing):lower() == target then
                        result.headers[existing] = nil
                    end
                end
                result.headers[header] = deepcopy(header_content)
            end
        else
            result[key] = deepcopy(value)
        end
    end
    return result
end

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then return location end
    if location:sub(1, 1) == "/" then return scheme .. "://" .. host .. location end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then return nil end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

local function table_summary(value)
    if type(value) ~= "table" then return type(value) end
    local count = 0
    for _key in pairs(value) do count = count + 1 end
    return "table(" .. tostring(count) .. ")"
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then return text:sub(1, 500) .. "..." end
    return text
end

local function safe_log_url(url)
    local path, query = tostring(url or ""):match("^([^?]+)%?(.*)$")
    if not path then return tostring(url or "") end
    local parts = {}
    for part in query:gmatch("[^&]+") do
        local key = part:match("^([^=]+)") or ""
        local lower_key = key:lower()
        if lower_key == "signature" or lower_key == "uuid" or lower_key == "code"
            or lower_key == "accesstoken" or lower_key == "token" or lower_key == "ticket" then
            parts[#parts + 1] = key .. "=<redacted>"
        else
            parts[#parts + 1] = part
        end
    end
    return path .. "?" .. table.concat(parts, "&")
end

local function http_error(client, code, text, headers)
    text = text or ""
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. tostring(header_value(headers, "content-type") or "unknown"),
        "body_bytes=" .. tostring(#text),
    }
    if #text <= 65536 then
        local ok, data = pcall(function() return client:json_decode(text) end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then parts[#parts + 1] = "error_code=" .. tostring(err_code) end
            if message ~= nil then
                parts[#parts + 1] = "error_message=" .. tostring(message):gsub("[%c]+", " "):sub(1, 200)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function log_response(label, context, text)
    context = context or {}
    logger.err(
        label,
        "method=", tostring(context.method or "unknown"),
        "url=", safe_log_url(context.url or "unknown"),
        "api=", tostring(context.api_name or "unknown"),
        "status=", tostring(context.code or "unknown"),
        "content_type=", tostring(header_value(context.headers, "content-type") or "unknown"),
        "body_bytes=", tostring(#(text or ""))
    )
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
        user_agent = DeviceIdentity.user_agent(),
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:decode_http_json(text, context)
    local ok, data = pcall(self.json_decode, self, text)
    if not ok then
        log_response("HTTP JSON decode failed:", context, text)
        error(data, 0)
    end

    if type(data) == "table" then
        local err_code = data.errCode or data.errcode
        local failed_succ = data.succ ~= nil
            and data.succ ~= true
            and tonumber(data.succ) ~= 1
        if (err_code ~= nil and tonumber(err_code) ~= 0) or failed_succ then
            log_response("API response reported an error:", context, text)
        end
    end
    return data
end

function Client:request(opts)
    opts = opts or {}
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = self.user_agent or WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }
    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    if type(opts.timeout) == "table" and opts.timeout[1] then
        block_timeout = opts.timeout[1]
        total_timeout = opts.timeout[2] or block_timeout
    elseif type(opts.timeout) == "number" then
        block_timeout = opts.timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers,
    }, opts)
    -- Authentication is carried only by the APK vid/accessToken headers.
    -- Do not allow old Web Reader cookies through this generic transport.
    for key in pairs(req_opts.headers or {}) do
        if tostring(key):lower() == "cookie" then req_opts.headers[key] = nil end
    end
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false
    local diagnostic_api = req_opts.diagnostic_api
    req_opts.diagnostic_api = nil

    if self.settings.mock_endpoint then
        -- Only this plugin's requests are redirected. Never forward credentials
        -- or let an unavailable mock fall back to the original destination.
        req_opts.url = self.settings.mock_endpoint .. "/__proxy?url=" .. WeRead.urlencode(opts.url)
        local mock_headers = {}
        for key, value in pairs(req_opts.headers or {}) do
            local name = tostring(key):lower()
            if name == "content-type" or name == "content-length"
                or name == "accept" or name == "user-agent" then
                mock_headers[key] = value
            end
        end
        req_opts.headers = mock_headers
        -- LuaSocket falls back to http.PROXY for nil/false. Point this request
        -- at the mock itself so a global Internet proxy cannot intercept it.
        req_opts.proxy = self.settings.mock_endpoint
    end

    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        logger.err(
            "HTTP transport failed:",
            "method=", tostring(req_opts.method),
            "url=", safe_log_url(req_opts.url),
            "api=", tostring(diagnostic_api or "unknown"),
            "error=", tostring(results[2])
        )
        error(results[2])
    end
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    if not opts.sink then response = table.concat(response) end
    local code = tonumber(raw_code)
    if code and code >= 400 then
        log_response("HTTP response failed:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    elseif not code then
        log_response("HTTP response unavailable:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = status or raw_code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    end

    return response, code, resp_headers or {}, status
end

function Client:test_mock_connection(config)
    local endpoint, err = require("weread.lib.mock_environment").endpoint(config)
    if not endpoint then error(err) end
    local probe = Client:new({ get = function(_self, _key, default) return default end })
    local text, code = probe:request({
        url = endpoint .. "/health", proxy = endpoint, timeout = { 3, 3 },
    })
    if code ~= 200 or probe:json_decode(text).service ~= "weread-mock" then
        error("The address did not respond as a WeRead mock server")
    end
    return endpoint
end

function Client:request_follow(opts, max_redirects)
    local request_opts = deepcopy(opts or {})
    local on_redirect = request_opts.on_redirect
    request_opts.on_redirect = nil
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if on_redirect then
            on_redirect(url, next_url, code)
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
            and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    error("Too many redirects")
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        }
    })
    local text, code, resp_headers = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:native_headers(extra, allow_anonymous)
    local auth = self.settings:get("auth", {}) or {}
    local vid = auth.vid
    if type(vid) ~= "string" or vid == "" then
        vid = (self.settings:get("account", {}) or {}).user_vid
    end
    local access_token = auth.access_token
    local has_credentials = not allow_anonymous
        and type(vid) == "string" and vid ~= ""
        and type(access_token) == "string" and access_token ~= ""
    if not has_credentials and not allow_anonymous then
        error("WeRead QR credentials are not configured")
    end
    local headers = {}
    if has_credentials then
        headers.vid = vid
        headers.accessToken = access_token
    end
    for key, value in pairs(extra or {}) do headers[key] = value end
    return headers
end

local function response_error_code(client, text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, data = pcall(client.json_decode, client, text)
    if not ok or type(data) ~= "table" then return nil end
    return tonumber(data.errCode or data.errcode or data.code), data
end

function Client:refresh_native_auth(expired_access_token, ref_cgi)
    local auth = self.settings:get("auth", {}) or {}
    -- Another request may already have refreshed this session while this
    -- response was in flight. Reuse those credentials instead of rotating
    -- the same refresh token twice.
    if expired_access_token and auth.access_token ~= expired_access_token then
        return true
    end
    local refresh_token = auth.refresh_token
    if type(refresh_token) ~= "string" or refresh_token == "" then return false end
    if self._refreshing_native_auth then return false end
    self._refreshing_native_auth = true

    local ok, result = pcall(function()
        local device_id = self.settings:get_device_fingerprint()
        local timestamp = math.floor(os.time() * 1000)
        local random = math.random(0, 999)
        local payload = {
            refreshToken = refresh_token,
            deviceId = device_id,
            wxToken = 0,
            inBackground = 0,
            trackId = "",
            kickType = 1,
            refCgi = ref_cgi or "",
            timestamp = timestamp,
            random = random,
            signature = Crypto.sha256_hex(tostring(timestamp) .. device_id .. tostring(random)),
            deviceName = DeviceIdentity.device_name(),
        }
        local url = NATIVE_API_BASE .. "/login"
        local text, code, headers = self:request({
            url = url,
            method = "POST",
            body = self:json_encode(payload),
            headers = self:native_headers({
                ["Accept"] = "application/json, text/plain, */*",
                ["Content-Type"] = "application/json;charset=UTF-8",
                ["Origin"] = "https://weread.qq.com",
                ["Referer"] = "https://weread.qq.com/",
            }, true),
            timeout = 30,
            diagnostic_api = "/login (refreshToken)",
        })
        if not code or code < 200 or code >= 300 then
            error(http_error(self, code, text, headers))
        end
        local login_result = self:decode_http_json(text, {
            method = "POST", url = url, api_name = "/login (refreshToken)",
            code = code, headers = headers,
        })
        if type(login_result) ~= "table" then
            error("WeRead returned an invalid refresh response")
        end
        local vid = tostring(login_result.vid or "")
        local access_token = tostring(login_result.accessToken or "")
        if vid == "" or access_token == "" then
            error("WeRead refresh response is missing account credentials")
        end

        local account = self.settings:get("account", {}) or {}
        account.user_vid = vid
        local user = type(login_result.user) == "table" and login_result.user or {}
        if type(user.name) == "string" and user.name ~= "" then account.name = user.name end
        local new_refresh_token = login_result.refreshToken
        if type(new_refresh_token) ~= "string" or new_refresh_token == "" then
            new_refresh_token = refresh_token
        end
        self.settings:update_auth({
            auth = {
                vid = vid,
                access_token = access_token,
                refresh_token = new_refresh_token,
            },
            account = account,
        }, { replace_auth = true })
        return true
    end)

    self._refreshing_native_auth = nil
    if not ok then
        logger.err("native WeRead token refresh failed:", log_error(result))
        return false
    end
    return result == true
end

function Client:_native_request(method, path, params, data, opts, binary, retried)
    opts = opts or {}
    local query = query_string(params)
    local url = NATIVE_API_BASE .. path .. (query ~= "" and ("?" .. query) or "")
    local current_auth = self.settings:get("auth", {}) or {}
    local request_headers = merge_req_opts({
        ["Accept"] = binary and "*/*" or "application/json, text/plain, */*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }, opts.headers)
    if method == "POST" then
        request_headers = merge_req_opts({
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
        }, request_headers)
    end
    local text, code, headers = self:request({
        url = url,
        method = method,
        body = method == "POST" and self:json_encode(data) or nil,
        headers = self:native_headers(request_headers, opts.allow_anonymous),
        timeout = opts.timeout or (binary and { 30, 120 } or nil),
        diagnostic_api = path,
    })

    local error_code = response_error_code(self, text)
    if error_code == -2012 and not retried and not opts.allow_anonymous
        and self:refresh_native_auth(current_auth.access_token, url) then
        return self:_native_request(method, path, params, data, opts, binary, true)
    end
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, headers))
    end
    if binary then return text, code, headers end
    return self:decode_http_json(text, {
        method = method, url = url, api_name = path, code = code, headers = headers,
    }), code, headers
end

function Client:native_get(path, params, opts)
    return self:_native_request("GET", path, params, nil, opts, false, false)
end

-- Native download endpoints return archive bytes rather than JSON. Authentication
-- failures are JSON, so _native_request can refresh once before returning bytes.
function Client:native_get_binary(path, params, opts)
    return self:_native_request("GET", path, params, nil, opts, true, false)
end

function Client:native_post(path, data, opts)
    return self:_native_request("POST", path, nil, data, opts, false, false)
end

-- Authentication bootstrap endpoints are part of the e-ink APK login path and
-- are intentionally called without an existing vid/accessToken pair.
function Client:get_wechat_login_ticket(nonce_str)
    return self:native_get("/wxticket", { nonceStr = nonce_str }, {
        allow_anonymous = true,
    })
end

function Client:login_with_wechat_code(code, fields)
    local data = {}
    for key, value in pairs(fields or {}) do data[key] = value end
    data.code = code
    return self:native_post("/login", data, { allow_anonymous = true })
end

function Client:get_shelf()
    logger.info(
        "shelf sync request:",
        "api=/shelf/sync",
        "auth=vid+accessToken",
        "endpoint=/shelf/sync",
        "synckey=0"
    )
    local ok, result, code, headers = pcall(function()
        return self:native_get("/shelf/sync", { synckey = 0, lectureSynckey = 0 })
    end)
    if not ok then
        logger.err(
            "shelf sync failed:",
            "api=/shelf/sync",
                "error=", log_error(result)
        )
        error(result, 0)
    end

    logger.info(
        "shelf sync completed:",
        "api=/shelf/sync",
        "http_status=", tostring(code or "unknown"),
        "response=", table_summary(result),
        "books=", table_summary(type(result) == "table" and result.books or nil),
        "archive=", table_summary(type(result) == "table" and result.archive or nil),
        "albums=", table_summary(type(result) == "table" and result.albums or nil),
        "groups=", table_summary(type(result) == "table" and result.archive or nil)
    )
    return result, code, headers
end

function Client:get_book_info(book_id)
    return self:native_get("/book/info", { bookId = book_id })
end

function Client:get_book_reviews(book_id, review_list_type, count)
    return self:native_get("/review/list", {
        bookId = book_id, listType = review_list_type or 1,
        count = count or 20, synckey = 0, listMode = 0,
    })
end

function Client:get_progress(book_id)
    return self:native_get("/book/getProgress", { bookId = book_id })
end

function Client:get_chapter_infos(book_ids, sync_keys)
    return self:native_post("/book/chapterInfos", {
        bookIds = book_ids,
        synckeys = sync_keys or { 0 },
    })
end

function Client:search_books(keyword, count)
    return self:native_get("/store/search", {
        keyword = keyword,
        count = count or 20,
        maxIdx = 0,
        scope = 10,
        v = 3,
    })
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end

    local ok, result = pcall(function()
        return self:native_get("/book/underlines", {
            bookId = tostring(book_id), chapterUid = chapter_uid, synckey = 0,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" then
        return false, nil, "underlines: native API returned non-table"
    end
    return true, result
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 30
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    local ok, result = pcall(function()
        return self:native_post("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            cht2sMode = "",
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        return false, nil, "readreviews: native API returned invalid data"
    end
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

function Client:get_review_comments(review_id, count, opts)
    opts = opts or {}
    if type(review_id) ~= "string" or review_id == "" then
        return false, nil, "empty review_id"
    end

    local comments_count = count or 20
    local ok, parsed = pcall(function()
        return self:native_get("/review/single", {
            reviewId = review_id,
            commentsCount = comments_count,
            commentsDirection = opts.comments_direction or 0,
            bookReviewCount = opts.book_review_count or 0,
            likesCount = opts.likes_count or 0,
            likesDirection = opts.likes_direction or 0,
            synckey = opts.synckey or 0,
        }, {
            referer = opts.referer, timeout = opts.timeout,
        })
    end)
    if not ok then
        return false, nil, tostring(parsed)
    end
    if type(parsed) ~= "table" then
        return false, parsed, "invalid response"
    end
    return true, parsed, nil
end
return Client
