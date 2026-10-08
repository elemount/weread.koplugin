local I18n = require("weread.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    fullname = _("WeRead"),
    description = _([[Read and cache WeRead books in KOReader, pull reading progress, and browse reviews and annotations.]]),
    version = "1.7.4",
}
