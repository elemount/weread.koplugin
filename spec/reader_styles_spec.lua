-- Focused checks for WeRead EPUB image conventions mapped to KOReader CSS.

package.path = "./?.lua;" .. package.path

local ReaderStyles = require("weread.lib.reader_styles")
local css = ReaderStyles.compose(".book-rule { color: red; }")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

expect(css:find(".qqreader-fullimg", 1, true) ~= nil
        and css:find('img[isfullpage="1"]', 1, true) ~= nil
        and css:find('img[isFullPage="1"]', 1, true) ~= nil,
    "APK full-page image markers are recognized")
expect(css:find('img[keepFit="1"]', 1, true) ~= nil
        and css:find('img[keepfit="1"]', 1, true) ~= nil,
    "APK keep-fit image markers are recognized")
expect(css:find(".eepub-single-image-title", 1, true) ~= nil
        and css:find("text-align: center", 1, true) ~= nil,
    "APK image captions get centered caption styling")
local h_pic_rule = css:match("img%.h%-pic%s*{([^}]*)}")
expect(h_pic_rule ~= nil and h_pic_rule:find("height: 1em", 1, true) ~= nil
        and h_pic_rule:find("width: auto", 1, true) ~= nil,
    "inline text-replacement images are sized to the text em")
expect(css:find("max-height: 90vh", 1, true) ~= nil
        and css:find("page-break-inside: avoid", 1, true) ~= nil,
    "full-page images are fitted and kept together")
expect(css:find(".book-rule { color: red; }", 1, true) ~= nil,
    "book CSS remains included")
expect(css:find(".book-rule { color: red; }", 1, true)
        > css:find(".eepub-single-image-title", 1, true),
    "book CSS keeps normal cascade priority over plugin defaults")

print(string.format(
    "reader_styles_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
