-- Best-effort reproduction of the e-ink Android app's device identity.
-- The APK's exact ID depends on Android-only values (notably ANDROID_ID and
-- Build.* properties), so KOReader keeps its own stable ID while matching the
-- APK's "eink" prefix and numeric layout.
local DeviceIdentity = {}

local function nonempty(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or value:lower() == "null" then return nil end
    return value
end

local function property(android, name)
    if not android or not android.prop then return nil end
    local ok, value = pcall(function() return android.prop[name] end)
    if ok then return nonempty(value) end
end

local function device_info()
    local android
    local android_ok, android_module = pcall(require, "android")
    if android_ok then android = android_module end

    local device
    local device_ok, device_module = pcall(require, "device")
    if device_ok then device = device_module end

    local model = device and nonempty(device.model)
    local firmware = device and nonempty(tostring(device.firmware_rev or ""))
    local brand = property(android, "brand")
        or (device and nonempty(device.brand))
        or model
        or "墨水屏"

    local arch = ""
    if jit and jit.arch then arch = tostring(jit.arch) end
    local host = ""
    if os and os.getenv then host = nonempty(os.getenv("HOSTNAME")) or "" end

    return {
        brand = brand,
        -- These fields mirror the seven length digits in the APK's generated
        -- ID. Use whatever KOReader exposes; non-Android devices may omit them.
        device = property(android, "device") or model or "",
        board = property(android, "board") or model or "",
        cpu_abi = property(android, "cpu_abi") or arch,
        display = property(android, "display") or firmware or "",
        host = property(android, "host") or host,
        tags = property(android, "tags") or "release-keys",
        build_id = property(android, "id") or firmware or "",
    }
end

function DeviceIdentity.device_name()
    return "Boox"
end

local function length_digit(value)
    return tostring(#tostring(value or "") % 10)
end

function DeviceIdentity.make_device_id(random_bytes)
    if type(random_bytes) ~= "string" or #random_bytes ~= 8 then
        error("eight random bytes are required to generate the device id")
    end
    local info = device_info()
    local id_fields = {
        info.device, info.board, info.cpu_abi, info.display,
        info.host, info.tags, info.build_id,
    }
    local lengths = {}
    for _, value in ipairs(id_fields) do
        lengths[#lengths + 1] = length_digit(value)
    end

    -- The APK prefixes its 28-digit hardware hash with "33" and seven
    -- Build-field length digits, then prepends the "eink" flavor. KOReader
    -- cannot read the APK's private preference or Android ID, so use a stable
    -- per-install random tail in the same shape and persist the result.
    local digits = {}
    for index = 1, #random_bytes do
        digits[#digits + 1] = string.format("%03d", random_bytes:byte(index))
    end
    local hash_tail = table.concat(digits):sub(1, 19)
    return "eink33" .. table.concat(lengths) .. hash_tail
end

function DeviceIdentity.user_agent()
    local brand = device_info().brand:gsub("[%s\r\n]+", "_")
    return "WeRead/2.1.2 WRBrand/" .. brand .. " wr_eink Android WeRead eink"
end

return DeviceIdentity
