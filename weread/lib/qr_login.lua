local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DeviceIdentity = require("weread.lib.device_identity")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local I18n = require("weread.lib.i18n")
local ImageWidget = require("ui/widget/imagewidget")
local logger = require("weread.lib.logger").scoped("QRLogin")
local QRMessage = require("ui/widget/qrmessage")
local Size = require("ui/size")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")
local Crypto = require("weread.lib.crypto")

local function _(text)
    return I18n.tr(text)
end

local WECHAT_QR_URL = "https://open.weixin.qq.com/connect/sdk/qrconnect"
local WECHAT_POLL_URL = "https://long.open.weixin.qq.com/connect/l/qrconnect"
local WECHAT_APP_ID = "wxab9b71ad2b90ff34"
local WECHAT_SCOPE = "snsapi_userinfo,snsapi_friend,snsapi_favorites"
local LOGIN_SESSION_TIMEOUT_SECONDS = 300
-- runOnlineTask currently executes callbacks on KOReader's UI loop. Keep the
-- DiffDev long-poll bounded so a stalled WeChat request cannot freeze the UI.
local POLL_BLOCK_TIMEOUT_SECONDS = 5
local POLL_TOTAL_TIMEOUT_SECONDS = 8

local QRImageMessage = QRMessage:extend{}

function QRImageMessage:init()
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Device.screen:getWidth(),
                    h = Device.screen:getHeight(),
                },
            },
        }
    end

    local padding = Size.padding.fullscreen
    local image_widget = ImageWidget:new{
        file = self.image_path,
        width = self.width and (self.width - 2 * padding),
        height = self.height and (self.height - 2 * padding),
        scale_factor = 0,
    }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = padding,
        image_widget,
    }
    self[1] = CenterContainer:new{
        dimen = Device.screen:getSize(),
        frame,
    }
end

local QRLogin = {}
QRLogin.__index = QRLogin

local function error_text(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 300 then return text:sub(1, 300) .. "..." end
    return text
end

local function is_timeout_error(err)
    local text = tostring(err or ""):lower()
    return text:find("timeout", 1, true) ~= nil
        or text:find("wantread", 1, true) ~= nil
end

local function base64_decode(value)
    value = tostring(value or ""):gsub("-", "+"):gsub("_", "/")
    value = value:gsub("[^%w%+/%=]", "")
    local out, accumulator, bits = {}, 0, 0
    for index = 1, #value do
        local char = value:sub(index, index)
        if char == "=" then break end
        local digit = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            :find(char, 1, true)
        if digit then
            accumulator = accumulator * 64 + digit - 1
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

function QRLogin:new(host, client, settings)
    return setmetatable({
        host = host,
        client = client,
        settings = settings,
        generation = 0,
        qr_dialog = nil,
        programmatic_close = false,
        started_at = nil,
        qr_image_path = nil,
    }, self)
end

function QRLogin:_request_wechat_json(url, timeout, stage)
    local text, code, headers, status = self.client:request({
        url = url,
        method = "GET",
        timeout = timeout,
        headers = {
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = "https://open.weixin.qq.com/",
        },
        diagnostic_api = stage,
    })
    if not code then return nil, headers, status or "request failed" end
    if code < 200 or code >= 300 then
        error(stage .. " failed: HTTP " .. tostring(code))
    end
    local data = self.client:decode_http_json(text, {
        method = "GET", url = url, code = code, headers = headers,
    })
    if type(data) ~= "table" then error("WeChat returned an invalid JSON response") end
    return data, headers
end

function QRLogin:_write_qr_image(base64)
    local image = base64_decode(base64)
    local extension
    if image:sub(1, 8) == "\137PNG\r\n\26\n" then
        extension = ".png"
    elseif image:sub(1, 3) == "\255\216\255" then
        extension = ".jpg"
    else
        error("WeChat returned an unsupported QR image format")
    end
    local suffix = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local path = self.settings.data_dir .. "/weread-login-qr-" .. suffix .. extension
    local file, open_error = io.open(path, "wb")
    if not file then error(open_error or "could not create QR image") end
    local ok, write_error = file:write(image)
    file:close()
    if not ok then
        pcall(os.remove, path)
        error(write_error or "could not save QR image")
    end
    return path
end

function QRLogin:_begin_protocol()
    local nonce = tostring(os.time()) .. tostring(math.random(100000, 999999))
    local ticket = self.client:get_wechat_login_ticket(nonce)
    if type(ticket) ~= "table" or type(ticket.signature) ~= "string"
        or ticket.signature == "" or ticket.timeStamp == nil then
        error("WeRead did not return a valid WeChat QR signature")
    end

    local params = {
        "appid=" .. WeRead.urlencode(WECHAT_APP_ID),
        "noncestr=" .. WeRead.urlencode(nonce),
        "timestamp=" .. WeRead.urlencode(ticket.timeStamp),
        "scope=" .. WeRead.urlencode(WECHAT_SCOPE),
        "signature=" .. WeRead.urlencode(ticket.signature),
    }
    local data = self:_request_wechat_json(WECHAT_QR_URL .. "?" .. table.concat(params, "&"),
        { 10, 20 }, "wechat_qrconnect")
    local uuid = type(data) == "table" and data.uuid or nil
    local qr = type(data) == "table" and type(data.qrcode) == "table" and data.qrcode or nil
    if tonumber(data.errcode) ~= 0 or type(uuid) ~= "string" or uuid == ""
        or type(qr) ~= "table" or type(qr.qrcodebase64) ~= "string" then
        error("WeChat could not create a login QR code")
    end

    return {
        uuid = uuid,
        last_status = 0,
        image_path = self:_write_qr_image(qr.qrcodebase64),
    }
end

function QRLogin:_poll_protocol(uuid, last_status)
    local url = WECHAT_POLL_URL .. "?f=json&uuid=" .. WeRead.urlencode(uuid)
    if tonumber(last_status or 0) ~= 0 then
        url = url .. "&last=" .. tostring(tonumber(last_status))
    end
    local response = { self:_request_wechat_json(url,
        { POLL_BLOCK_TIMEOUT_SECONDS, POLL_TOTAL_TIMEOUT_SECONDS }, "wechat_qr_poll") }
    local data, request_error = response[1], response[3]
    if not data then
        if is_timeout_error(request_error) or request_error == "request failed" then
            return { transport_pending = true, last_status = last_status or 0 }
        end
        error(request_error)
    end
    local status = tonumber(data.wx_errcode)
    if not status then error("WeChat returned an invalid QR login status") end
    return {
        status = status,
        auth_code = type(data.wx_code) == "string" and data.wx_code or nil,
    }
end

function QRLogin:_complete_protocol(auth_code, generation)
    if type(auth_code) ~= "string" or auth_code == "" then
        error("WeChat did not return a login authorization code")
    end
    local device_id = self.settings:get_device_fingerprint()
    local timestamp = math.floor(os.time() * 1000)
    local random = math.random(0, 999)
    local signature = Crypto.sha256_hex(tostring(timestamp) .. device_id .. tostring(random))
    local login_result = self.client:login_with_wechat_code(auth_code, {
        deviceId = device_id,
        trackId = "",
        timestamp = timestamp,
        random = random,
        signature = signature,
        isFromQrcode = 1,
        isAutoLogout = 0,
        deviceName = DeviceIdentity.device_name(),
        deviceType = 3,
    })
    if type(login_result) ~= "table" then error("WeRead returned an invalid login response") end

    local vid = tostring(login_result.vid or "")
    local access_token = tostring(login_result.accessToken or "")
    if vid == "" or access_token == "" then
        error("WeRead login response is missing account credentials")
    end
    if generation ~= self.generation then error("QR login was cancelled") end

    local user = type(login_result.user) == "table" and login_result.user or {}
    local account = {
        name = type(user.name) == "string" and user.name or "",
        user_vid = vid,
        login_method = "qr",
        login_time = os.time(),
    }
    local auth = {
        vid = vid,
        access_token = access_token,
        refresh_token = tostring(login_result.refreshToken or ""),
    }
    self.settings:update_auth({ auth = auth, account = account }, { replace_auth = true })
    if self.host.onWeReadAccountChanged then self.host:onWeReadAccountChanged() end
    return account
end

function QRLogin:_close_qr_dialog(programmatic)
    local dialog = self.qr_dialog
    if not dialog then return end
    self.qr_dialog = nil
    self.programmatic_close = programmatic == true
    UIManager:close(dialog)
    self.programmatic_close = false
end

function QRLogin:_remove_qr_image()
    if self.qr_image_path then pcall(os.remove, self.qr_image_path) end
    self.qr_image_path = nil
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    self.started_at = nil
    self:_close_qr_dialog(true)
    self:_remove_qr_image()
end

function QRLogin:start()
    if not self.host:isNetworkOnline() then
        self.host:showOffline(_("QR login"))
        return
    end

    self:cancel()
    local generation = self.generation
    self.started_at = os.time()
    self.host:showBusy(_("Getting login QR code..."))
    self.host:runOnlineTask(_("QR login"), function()
        local ok, session_or_error = pcall(function() return self:_begin_protocol() end)
        self.host:closeBusy()
        if generation ~= self.generation then
            if ok and session_or_error.image_path then pcall(os.remove, session_or_error.image_path) end
            return
        end
        if not ok then
            logger.err("get native login QR failed:", error_text(session_or_error))
            self.host:showInfo(T(_("QR login failed:\n%1"), error_text(session_or_error)))
            return
        end
        self:_show_qr(session_or_error, generation)
    end)
end

function QRLogin:_show_qr(session, generation)
    self.qr_image_path = session.image_path
    local screen_width = Device.screen:getWidth()
    local screen_height = Device.screen:getHeight()
    local qr_size = math.floor(math.min(screen_width, screen_height) * 0.72)
    local dialog
    dialog = QRImageMessage:new{
        text = "",
        image_path = session.image_path,
        width = qr_size,
        height = qr_size,
        dismiss_callback = function()
            if self.qr_dialog == dialog then self.qr_dialog = nil end
            if not self.programmatic_close and generation == self.generation then
                self:cancel()
                self.host:showTransientInfo(_("QR login cancelled."), 2)
            end
        end,
    }
    self.qr_dialog = dialog
    UIManager:show(dialog)
    self.host:refreshUI()
    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog == dialog then
            self:_poll(session, generation)
        end
    end)
end

function QRLogin:_schedule_poll(session, generation)
    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog then
            self:_poll(session, generation)
        end
    end)
end

function QRLogin:_poll(session, generation)
    if os.time() - (self.started_at or os.time()) > LOGIN_SESSION_TIMEOUT_SECONDS then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
        return
    end

    local ok, result = pcall(function()
        return self:_poll_protocol(session.uuid, session.last_status)
    end)
    if generation ~= self.generation then return end
    if not ok then
        if is_timeout_error(result) then
            self:_schedule_poll(session, generation)
            return
        end
        self:_close_qr_dialog(true)
        self:cancel()
        logger.err("native QR login polling failed:", error_text(result))
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(result)))
        return
    end
    if result.transport_pending then
        self:_schedule_poll(session, generation)
    elseif result.status == 408 or result.status == 404 then
        session.last_status = result.status
        self:_schedule_poll(session, generation)
    elseif result.status == 405 then
        self:_close_qr_dialog(true)
        self:_complete(result.auth_code, generation)
    elseif result.status == 402 then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
    elseif result.status == 403 then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showTransientInfo(_("QR login cancelled."), 2)
    else
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(T(_("QR login failed:\n%1"), "WeChat QR status " .. tostring(result.status)))
    end
end

function QRLogin:_complete(auth_code, generation)
    self.host:showBusy(_("Completing WeRead login..."))
    self.host:runOnlineTask(_("QR login"), function()
        local ok, account_or_error = pcall(function()
            return self:_complete_protocol(auth_code, generation)
        end)
        self.host:closeBusy()
        self:_remove_qr_image()
        if generation ~= self.generation then return end
        if not ok then
            logger.err("native login completion failed:", error_text(account_or_error))
            self:cancel()
            self.host:showInfo(T(_("QR login failed:\n%1"), error_text(account_or_error)))
            return
        end
        local account_name = account_or_error.name
        if type(account_name) ~= "string" or account_name == "" then
            account_name = _("Unknown account")
        end
        logger.info("native QR login completed")
        self.host:refreshLoginMenu()
        self.host:showInfo(T(
            _("WeRead login successful.\n\nAccount: %1\nAuthentication: %2"),
            account_name,
            _("configured")
        ))
    end)
end

return QRLogin
