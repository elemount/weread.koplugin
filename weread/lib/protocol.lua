local WeRead = {}

WeRead.USER_AGENT = "WeRead/2.1.2 WRBrand/unknown wr_eink Android WeRead eink"

function WeRead.urlencode(value)
    if value == true then value = "true"
    elseif value == false then value = "false"
    elseif value == nil then value = "null" end
    value = tostring(value)
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

function WeRead.normalize_cover_url(url)
    if type(url) ~= "string" or url == "" then
        return url
    end
    return (url:gsub("/t%d+_", "/t9_"):gsub("/s_", "/t9_"))
end

return WeRead
