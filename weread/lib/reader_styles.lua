local ReaderStyles = {}

-- EPUB-safe subset of the WeRead reader defaults. KOReader remains in charge
-- of font sizing and theme colors; this stylesheet supplies layout defaults
-- and styles the image-caption classes used in WeRead chapter XHTML.
ReaderStyles.base_css = [[
h1, h2, h3, h4, h5, h6 { font-weight: bold; }
h1 { font-size: 1.5em; }
h2 { font-size: 1.4em; }
h3 { font-size: 1.3em; }
h4 { font-size: 1.2em; }
h5 { font-size: 1.1em; }
h6 { font-size: 1em; }
b, strong { font-weight: bold; }
p { margin: 0; }
p.txt-blank-gap { height: 1em; line-height: 1; }
i, em { font-style: italic; }
center { text-align: center; }
code, pre, blockquote { font-family: monospace; text-align: left; }
pre, blockquote { hyphens: none; font-size: 0.9em; }
del { text-decoration: line-through; }
a { text-decoration: underline; }
ul { list-style: disc; }
ol { list-style: decimal; }
li { margin: 0; }
hr { width: 100%; height: 1px; margin: 0.5em auto; }
u { text-decoration: underline; }
small { font-size: smaller; }
sub { font-size: 0.8em; vertical-align: sub; }
sup { font-size: 0.8em; vertical-align: super; }
img { max-width: 100%; height: auto; }
figure { margin: 1em 0; page-break-inside: avoid; text-align: center; }
]]

-- The APK's wr.css styles its own image-title class. WeRead chapter payloads
-- also use imgtitle/qrbodyPic/bodyPic, so map those classes to the same layout.
ReaderStyles.image_css = [[
figcaption,
.imgtitle,
.eepub-single-image-title {
    font-size: 0.75em;
    line-height: 1.4;
    text-align: center;
    text-indent: 0;
    margin: 0.4em 0.4em 1em;
    color: gray;
}
.qrbodyPic {
    page-break-inside: avoid;
    text-align: center;
}
.bodyPic { text-align: center; }
img[align="left"] {
    float: left;
    margin-right: 3px;
}
img[align="right"] {
    float: right;
    margin-left: 3px;
}
.bodyPic > img,
.qrbodyPic > img {
    display: block;
    max-width: 100%;
    height: auto;
    margin-left: auto;
    margin-right: auto;
}
img.h-pic {
    display: inline;
    max-width: 100%;
    height: auto;
}
]]

-- Native book CSS can carry web-reader viewport defaults that fight KOReader's
-- font, theme, and page-size settings. Keep those choices inherited at the
-- document root while leaving paragraph and image layout rules intact.
ReaderStyles.reader_preferences_css = [[
html, body {
    font-size: 1em !important;
    font-family: inherit !important;
    color: inherit !important;
    background-color: transparent !important;
    width: auto !important;
    height: auto !important;
    min-width: 0 !important;
    min-height: 0 !important;
    max-width: none !important;
    max-height: none !important;
}
]]

function ReaderStyles.compose(book_css)
    local parts = { ReaderStyles.base_css }
    if type(book_css) == "string" and book_css ~= "" then
        parts[#parts + 1] = book_css
    end
    parts[#parts + 1] = ReaderStyles.reader_preferences_css
    parts[#parts + 1] = ReaderStyles.image_css
    return table.concat(parts, "\n")
end

return ReaderStyles
