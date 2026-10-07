package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function widget_class()
    local class = {}
    function class:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, { __index = self })
    end
    function class:new(options) return options end
    return class
end

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0 } end
package.preload["ui/widget/container/centercontainer"] = function() return widget_class() end
package.preload["ui/widget/container/framecontainer"] = function() return widget_class() end
package.preload["ui/widget/imagewidget"] = function() return widget_class() end
package.preload["ui/widget/container/inputcontainer"] = function() return widget_class() end
package.preload["ui/geometry"] = function() return { new = function(_self, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_self, value) return value end } end
package.preload["ui/size"] = function() return { padding = { fullscreen = 4 } } end
package.preload["device"] = function()
    return {
        model = "onyx",
        input = { group = { Any = "any" } },
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return { w = 600, h = 800 } end,
        },
        hasKeys = function() return false end,
        isTouchDevice = function() return false end,
    }
end
package.preload["weread.lib.i18n"] = function() return { tr = function(text) return text end } end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return { warn = function() end, err = function() end,
        info = function() end } end }
end
package.preload["ui/widget/qrmessage"] = function() return widget_class() end
package.preload["ffi/util"] = function() return { template = function(text) return text end } end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { urlencode = function(value) return tostring(value):gsub(" ", "%%20") end }
end
package.preload["weread.lib.crypto"] = function()
    return { sha256_hex = function(value) return "signed:" .. tostring(value) end }
end

local requests, saved, login_fields = {}, nil, nil
local client = {
    get_wechat_login_ticket = function(_self, nonce)
        expect(type(nonce) == "string" and nonce ~= "", "missing nonce for /wxticket")
        return { signature = "ticket-signature", timeStamp = "12345" }
    end,
    request = function(_self, options)
        requests[#requests + 1] = options
        return "wechat-response", 200, {}
    end,
    decode_http_json = function(_self, _body, context)
        if context.url:find("connect/sdk/qrconnect", 1, true) then
            return { errcode = 0, uuid = "wechat-uuid", qrcode = { qrcodebase64 = "/9j/4AAQSkZJRgABAQ==" } }
        end
        return { wx_errcode = 405, wx_code = "wechat-auth-code" }
    end,
    login_with_wechat_code = function(_self, code, fields)
        expect(code == "wechat-auth-code", "native /login received the wrong authorization code")
        login_fields = fields
        return {
            vid = "native-vid", accessToken = "native-access",
            refreshToken = "native-refresh", user = { name = "Native account" },
        }
    end,
}
local settings = {
    data_dir = "/tmp",
    get_device_fingerprint = function() return "eink3300000001234567890123456789" end,
    update_auth = function(_self, credentials, options)
        expect(options.replace_auth, "native login should replace account credentials")
        saved = credentials
    end,
}

local QRLogin = require("weread.lib.qr_login")
local login = QRLogin:new({}, client, settings)
local session = login:_begin_protocol()
expect(session.uuid == "wechat-uuid", "native QR session did not retain WeChat UUID")
expect(session.image_path:match("%.jpg$") ~= nil,
    "JPEG QR image was not saved with a JPEG extension")
expect(requests[1].url:find("https://open.weixin.qq.com/connect/sdk/qrconnect?", 1, true) == 1,
    "QR image was not requested through WeChat DiffDev OAuth")
expect(requests[1].url:find("signature=ticket-signature", 1, true),
    "WeRead /wxticket signature was omitted from the WeChat request")
expect(requests[1].headers.Cookie == nil, "WeChat OAuth request must not carry WeRead cookies")

local poll = login:_poll_protocol(session.uuid, 0)
expect(poll.status == 405 and poll.auth_code == "wechat-auth-code",
    "WeChat QR poll did not return the authorization code")
expect(requests[2].url:find("https://long.open.weixin.qq.com/connect/l/qrconnect?", 1, true) == 1,
    "QR state was not polled through the WeChat DiffDev endpoint")

local account = login:_complete_protocol(poll.auth_code, login.generation)
expect(login_fields.deviceType == 3 and login_fields.isFromQrcode == 1
        and login_fields.deviceId == "eink3300000001234567890123456789"
        and login_fields.deviceName == "Boox"
        and login_fields.signature:find("signed:", 1, true) == 1,
    "native /login payload did not match the APK login contract")
expect(account.user_vid == "native-vid" and account.name == "Native account",
    "native login response was not mapped to the account")
expect(saved.auth.vid == "native-vid" and saved.auth.access_token == "native-access",
    "native login credentials were not persisted")
expect(saved.auth.refresh_token == "native-refresh",
    "native refresh token was not persisted")
login:_remove_qr_image()

print("qr_login_spec: " .. checks .. " checks")
