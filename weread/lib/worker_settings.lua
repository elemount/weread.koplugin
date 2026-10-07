local M = {}

local function auth_fingerprint(settings)
    if not settings or type(settings.get) ~= "function" then return "" end
    local auth = settings:get("auth", {}) or {}
    return table.concat({
        tostring(auth.vid or ""),
        tostring(auth.access_token or ""),
        tostring(auth.refresh_token or ""),
    }, "\0")
end

function M.capture(settings)
    local changed = false
    settings.flush = function() end
    local update_auth = settings.update_auth
    if type(update_auth) == "function" then
        settings.update_auth = function(object, credentials, options)
            changed = true
            options = options or {}
            options.flush = false
            return update_auth(object, credentials, options)
        end
    end
    return function()
        if not changed or type(settings.get) ~= "function" then return nil end
        return {
            auth = settings:get("auth", {}),
        }
    end
end

function M.fingerprint(settings)
    return auth_fingerprint(settings)
end

function M.merge(settings, expected_fingerprint, auth)
    if type(auth) ~= "table" then return false end
    if not settings or type(settings.update_auth) ~= "function" then return false end
    if auth_fingerprint(settings) ~= expected_fingerprint then return false end
    settings:update_auth(auth, { replace_auth = true })
    return true
end

return M
