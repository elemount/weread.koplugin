package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end

local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")

local original = "\xef\xbb\xbf<p>你好世界</p>"
local processed = Annotations.injectUnderlines(original, {
    { range = "3-7" },
}, nil, "chapter", "book")
expect(processed:sub(1, 3) ~= "\xef\xbb\xbf",
    "leading BOM was not removed")
expect(processed:find('<span class="wr%-underline">你好世界</span>') ~= nil,
    "UTF-8 underline range was not injected correctly")
expect(processed:find("<p>", 1, true) and processed:find("</p>", 1, true),
    "underline injection corrupted surrounding HTML")

local thought_html = Annotations.injectUnderlines("<p>hello</p>", {
    { range = "3-8" },
}, { ["3-8"] = true }, "chapter/1", 'book"2')
expect(thought_html:find("wr%-thought%-link") ~= nil
    and thought_html:find("wr%-star") == nil,
    "thought link was not generated without a trailing star")
expect(thought_html:find('id="wrthought%-book_2%-chapter_1%-3%-8"') ~= nil,
    "thought anchor id was not sanitized")

local trailing_whitespace = Annotations.injectUnderlines("<p>abc</p>\n  ", {
    { range = "3-12" },
}, { ["3-12"] = true }, "chapter/11", "book")
expect(trailing_whitespace:find(
        '<a id="wrthought%-book%-chapter_11%-3%-12" class="wr%-thought%-link" href="#wrthought%-book%-chapter_11%-3%-12"><span class="wr%-underline">abc</span></a>',
        1) ~= nil,
    "thought link stays attached to underlined text when the range ends with whitespace")

local unchanged = Annotations.injectUnderlines("<p>safe</p>", {
    { range = "bad" },
    { range = "999-1000" },
}, nil, "chapter", "book")
expect(unchanged == "<p>safe</p>", "invalid ranges changed the document")

local annotated, css = Annotations.process("<p>hello</p>", {
    chapterUid = "chapter",
    underlines = { { range = "3-8" } },
}, {
    { range = "3-8", pageReviews = { { review = { content = "idea" } } } },
}, "book")
expect(annotated ~= "<p>hello</p>", "annotation process did not change HTML")
expect(css:find(".wr%-underline") and css:find(".wr%-thought%-link"),
    "annotation CSS did not include underline and thought styles")
expect(css:find("wr%-star") == nil,
    "annotation CSS still included obsolete thought star styles")

local xhtml = Content.txt_to_xhtml("first & <tag>\r\n\r\nsecond")
expect(xhtml:find("<p>first &amp; &lt;tag&gt;</p>", 1, true),
    "plain text was not XML-escaped")
expect(xhtml:find("<p>second</p>", 1, true),
    "plain text paragraph conversion lost content")

local rewritten = Content.rewrite_image_sources(
    '<img src="a.jpg"/><image xlink:href="b.png"/>',
    { ["a.jpg"] = "../images/a.jpg", ["b.png"] = "../images/b.png" })
expect(rewritten:find('src="../images/a.jpg"', 1, true),
    "image source was not rewritten")
expect(rewritten:find('xlink:href="b.png"', 1, true),
    "non-src image attribute should be left unchanged")

print(("content_annotations_spec: %d checks"):format(checks))
