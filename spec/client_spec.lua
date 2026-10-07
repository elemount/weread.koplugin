package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local timeout_calls = {}
local reset_count = 0
local requests = {}
local responses = {}
local logs = {}

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                return function() return value end
            end,
        },
    }
end
package.preload["logger"] = function()
    local function capture(level, ...)
        local parts = { level }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return {
        info = function(...) capture("info", ...) end,
        err = function(...) capture("error", ...) end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            requests[#requests + 1] = options
            local response = table.remove(responses, 1)
            if response.raise then error(response.raise) end
            if options.sink then options.sink(response.body or "") end
            return 1, response.code, response.headers or {}, response.status
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "WeRead client spec",
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Client = require("weread.lib.client")
local merged_cookies = {}
local settings = {
    get = function(_self, key, default)
        return default
    end,
    merge_set_cookie = function(_self, value)
        merged_cookies[#merged_cookies + 1] = value
    end,
}
local client = Client:new(settings)

local mock = Client:new({
    mock_endpoint = "http://192.168.31.111:8765",
    get = settings.get,
})
responses[#responses + 1] = { body = "mock", code = 200, headers = { ["set-cookie"] = "ignored=value" } }
mock:request({ url = "https://weread.qq.com/resource/test", headers = {
    Authorization = "Bearer sentinel", ["x-wr-ticket"] = "sentinel", ["x-wrpa-0"] = "sentinel",
    ["Content-Type"] = "application/json", Cookie = "sentinel=value", Host = "weread.qq.com",
} })
expect(requests[1].url == "http://192.168.31.111:8765/__proxy?url=https%3A%2F%2Fweread.qq.com%2Fresource%2Ftest",
    "mock did not route to the LAN endpoint")
expect(requests[1].headers.Authorization == nil and requests[1].headers.Cookie == nil
    and requests[1].headers["x-wr-ticket"] == nil and requests[1].headers["x-wrpa-0"] == nil
    and requests[1].headers.Host == nil, "credentials or original Host leaked to mock")
expect(requests[1].headers["Content-Type"] == "application/json" and requests[1].redirect == false,
    "mock changed payload type or allowed redirects")
expect(requests[1].proxy == mock.settings.mock_endpoint, "mock inherited the global HTTP proxy")
responses[#responses + 1] = { raise = "connection refused" }
local mock_ok = pcall(mock.request, mock, { url = "https://weread.qq.com/resource/test" })
expect(not mock_ok and #requests == 2 and requests[2].url:find("192.168.31.111", 1, true),
    "mock failure fell back to production")
requests, timeout_calls, reset_count = {}, {}, 0

responses[#responses + 1] = {
    body = "ok",
    code = 200,
    headers = { ["Set-Cookie"] = "wr_rt=XXX-refresh-token; Path=/" },
}
local body, code = client:request({
    url = "https://weread.qq.com/resource/test",
    timeout = { 3, 7 },
})
expect(body == "ok" and code == 200, "basic request result was wrong")
expect(requests[1].headers.Cookie == nil,
    "legacy cookie was attached to a generic request")
expect(requests[1].headers["User-Agent"]:find("wr_eink", 1, true) ~= nil
        and requests[1].headers["User-Agent"]:find("Macintosh", 1, true) == nil,
    "native request did not use the Android e-ink WeRead user agent")
expect(timeout_calls[1][1] == 3 and timeout_calls[1][2] == 7,
    "request timeout was not applied")
expect(reset_count == 1, "timeout was not reset after successful request")
expect(#merged_cookies == 0, "response cookies were persisted")

responses[#responses + 1] = { body = "public", code = 200 }
client:request({ url = "https://example.com/public" })
expect(requests[2].headers.Cookie == nil,
    "WeRead cookie leaked to a non-WeRead host")

responses[#responses + 1] = { raise = "transport failed" }
local ok, err = pcall(function()
    client:request({ url = "https://weread.qq.com/resource/fail" })
end)
expect(not ok and tostring(err):find("transport failed", 1, true),
    "transport error was not propagated")
expect(reset_count == 3, "timeout was not reset after transport error")

responses[#responses + 1] = {
    body = "",
    code = 303,
    headers = { location = "https://cdn.example.net/book" },
}
responses[#responses + 1] = { body = "book", code = 200 }
local redirected, redirected_code, _, _, final_url = client:request_follow({
    url = "https://weread.qq.com/resource/export",
    method = "POST",
    body = "{}",
    headers = {
        Authorization = "Bearer secret",
        Cookie = "manual=secret",
        Origin = "https://weread.qq.com",
        ["Content-Length"] = "2",
    },
})
expect(redirected == "book" and redirected_code == 200,
    "redirected response was not returned")
expect(final_url == "https://cdn.example.net/book",
    "final redirect URL was wrong")
local redirected_request = requests[#requests]
expect(redirected_request.method == "GET" and redirected_request.body == nil,
    "303 redirect did not switch POST to GET")
for key in pairs(redirected_request.headers) do
    local lower = tostring(key):lower()
    expect(lower ~= "authorization" and lower ~= "cookie"
        and lower ~= "origin" and lower ~= "content-length",
        "sensitive/entity header survived a cross-origin 303: " .. lower)
end

responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
ok, err = pcall(function()
    client:request_follow({ url = "https://weread.qq.com/start" }, 1)
end)
expect(not ok and tostring(err):find("Too many redirects", 1, true),
    "redirect limit was not enforced")

logs = {}
responses[#responses + 1] = {
    body = "{\"errcode\":-202,\"errmsg\":\"raw response\"}",
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok, err = pcall(function()
    client:get_binary("https://weread.qq.com/resource/failing-api")
end)
expect(not ok and tostring(err):find("HTTP 499", 1, true),
    "HTTP error details were not preserved")
local raw_response_log = table.concat(logs, "\n")
expect(not raw_response_log:find("raw response", 1, true)
    and raw_response_log:find("body_bytes=", 1, true),
    "HTTP failure should report response size without logging response contents")

logs = {}
local native_settings = {
    get = function(_self, key, default)
        if key == "auth" then
            return { vid = "native-vid", access_token = "native-access-token" }
        end
        return default
    end,
}
local native_client = Client:new(native_settings)
native_client.json_decode = function() return { bookId = "42" } end
responses[#responses + 1] = {
    body = '{"bookId":"42"}', code = 200,
    headers = { ["content-type"] = "application/json" },
}
local native_result = native_client:native_get("/book/info", { bookId = "42" })
expect(native_result.bookId == "42", "native JSON response was not returned")
local native_request = requests[#requests]
expect(native_request.url == "https://i.weread.qq.com/book/info?bookId=42",
    "native request used the wrong endpoint")
expect(native_request.headers.vid == "native-vid"
    and native_request.headers.accessToken == "native-access-token"
    and native_request.headers.Cookie == nil,
    "native request did not isolate vid/accessToken authentication")
expect(native_request.diagnostic_api == nil,
    "diagnostic API metadata leaked into HTTP request options")

local refresh_state = {
    auth = {
        vid = "expired-vid", access_token = "expired-access",
        refresh_token = "stored-refresh",
    },
    account = { name = "Reader", user_vid = "expired-vid", login_method = "qr" },
}
local refresh_settings = {
    get = function(_self, key, default)
        if refresh_state[key] ~= nil then return refresh_state[key] end
        return default
    end,
    get_device_fingerprint = function() return "eink-device-id" end,
    update_auth = function(_self, credentials, options)
        expect(options.replace_auth, "refresh should replace native credentials")
        refresh_state.auth = credentials.auth
        refresh_state.account = credentials.account
    end,
}
local refresh_client = Client:new(refresh_settings)
local refresh_payload
refresh_client.json_encode = function(_self, data)
    refresh_payload = data
    return "refresh-payload"
end
refresh_client.json_decode = function(_self, response_body)
    if response_body == "expired" then return { errcode = -2012 } end
    if response_body == "refreshed" then
        return {
            vid = "rotated-vid", accessToken = "rotated-access",
            refreshToken = "rotated-refresh", user = { name = "Reader" },
        }
    end
    return { bookId = "42" }
end
local refresh_request_start = #requests + 1
responses[#responses + 1] = { body = "expired", code = 200 }
responses[#responses + 1] = { body = "refreshed", code = 200 }
responses[#responses + 1] = { body = "book", code = 200 }
local refreshed_book = refresh_client:native_get("/book/info", { bookId = "42" })
expect(refreshed_book.bookId == "42" and #requests == refresh_request_start + 2,
    "expired native session was not refreshed and retried exactly once")
expect(refresh_payload.refreshToken == "stored-refresh"
    and refresh_payload.deviceId == "eink-device-id"
    and refresh_payload.deviceName == "Boox"
    and refresh_payload.wxToken == 0 and refresh_payload.inBackground == 0
    and refresh_payload.trackId == "" and refresh_payload.kickType == 1
    and refresh_payload.refCgi == "https://i.weread.qq.com/book/info?bookId=42"
    and type(refresh_payload.signature) == "string" and #refresh_payload.signature == 64,
    "refresh request did not match the APK /login refresh payload")
local refresh_request = requests[refresh_request_start + 1]
local retried_request = requests[refresh_request_start + 2]
expect(refresh_request.url == "https://i.weread.qq.com/login"
    and refresh_request.headers.vid == nil and refresh_request.headers.accessToken == nil
    and retried_request.headers.vid == "rotated-vid"
    and retried_request.headers.accessToken == "rotated-access"
    and refresh_state.auth.refresh_token == "rotated-refresh",
    "refresh credentials were sent or persisted incorrectly")

logs = {}
client.json_decode = function(_self, _text)
    return { errcode = -300, errmsg = "application failure" }
end
local application_result = client:decode_http_json(
    '{"errcode":-300,"errmsg":"application failure"}',
    {
        method = "POST",
        url = "https://i.weread.qq.com/book/info",
        code = 200,
        headers = { ["content-type"] = "application/json" },
    }
)
expect(application_result.errcode == -300,
    "application error response was not returned to the caller")
local application_error_log = table.concat(logs, "\n")
expect(application_error_log:find("body_bytes=", 1, true)
    and not application_error_log:find("application failure", 1, true),
    "application failure log should include response size without response contents")

logs = {}
client.json_decode = function()
    error("invalid JSON")
end
ok, err = pcall(function()
    client:decode_http_json("<not-json>", {
        method = "GET",
        url = "https://weread.qq.com/resource/invalid-json",
        code = 200,
    })
end)
expect(not ok and tostring(err):find("invalid JSON", 1, true),
    "JSON decode failure was not preserved")
local decode_failure_log = table.concat(logs, "\n")
expect(decode_failure_log:find("body_bytes=", 1, true)
    and not decode_failure_log:find("<not-json>", 1, true),
    "JSON decode failure log should include response size without response contents")

local shelf_client = Client:new(settings)
shelf_client.native_get = function(_self, path, params)
    expect(path == "/shelf/sync", "shelf helper used the wrong endpoint")
    expect(type(params) == "table" and params.synckey == 0
        and params.lectureSynckey == 0,
        "shelf helper sent the wrong sync keys")
    return {
        books = { { bookId = "private-book-id", title = "Private title" } },
        archive = {},
        albums = {},
        mp = {},
    }, 200, {}
end
local shelf = shelf_client:get_shelf()
expect(#shelf.books == 1, "shelf helper did not return the response")
local success_log = table.concat(logs, "\n")
expect(success_log:find("api=/shelf/sync", 1, true),
    "shelf diagnostics omitted the endpoint")
expect(success_log:find("books= table(1)", 1, true),
    "shelf diagnostics omitted the response shape")
expect(not success_log:find("private-book-id", 1, true)
    and not success_log:find("Private title", 1, true),
    "shelf diagnostics leaked response contents")

logs = {}
shelf_client.native_get = function(_self, path)
    expect(path == "/shelf/sync", "shelf error used the wrong endpoint")
    error("HTTP 499, error_code=-202, error_message=-202")
end
ok, err = pcall(function()
    shelf_client:get_shelf()
end)
expect(not ok and tostring(err):find("error_code=-202", 1, true),
    "shelf helper did not preserve the native API error")
local failure_log = table.concat(logs, "\n")
expect(failure_log:find("shelf sync failed", 1, true),
    "shelf failure diagnostics were not written")

local review_client = Client:new({
    get = function(_self, key, default)
        if key == "auth" then
            return { vid = "review-vid", access_token = "review-access-token" }
        end
        return default
    end,
})
local ok_review, data_review, err_review
ok_review, _, err_review = review_client:get_review_comments("")
expect(not ok_review and err_review == "empty review_id",
    "review comments rejected an empty review_id")

responses[#responses + 1] = {
    body = '{"reviewId":"r1","comments":[{"content":"hi"}],"commentsCount":1}',
    code = 200,
    headers = { ["content-type"] = "application/json" },
}
review_client.json_decode = function(_self, text)
    return { reviewId = "r1", comments = { { content = "hi" } }, commentsCount = 1, _raw = text }
end
local review_request_index = #requests + 1
ok_review, data_review, err_review = review_client:get_review_comments("r1", 60)
expect(ok_review and type(data_review) == "table"
    and data_review.commentsCount == 1 and err_review == nil,
    "review comments did not return parsed data")
local review_request = requests[review_request_index]
local review_url = review_request and review_request.url or ""
expect(review_url:find("https://i.weread.qq.com/review/single?", 1, true)
    and review_url:find("reviewId=r1", 1, true)
    and review_url:find("commentsCount=60", 1, true)
    and review_url:find("commentsDirection=0", 1, true)
    and review_url:find("likesCount=0", 1, true)
    and review_url:find("synckey=0", 1, true),
    "review comments built the wrong URL: " .. tostring(review_url))

responses[#responses + 1] = { body = "not-json", code = 200 }
review_client.json_decode = function()
    error("invalid JSON")
end
ok_review, data_review, err_review = review_client:get_review_comments("r2")
expect(not ok_review and data_review == nil and err_review:find("invalid JSON", 1, true),
    "review comments did not surface JSON decode failures")

responses[#responses + 1] = { body = "", code = 200 }
ok_review, _, err_review = review_client:get_review_comments("r3")
expect(not ok_review and type(err_review) == "string" and err_review ~= "",
    "review comments did not surface an empty-response decode failure")

print(("client_spec: %d checks"):format(checks))
