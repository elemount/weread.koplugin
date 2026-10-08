local ReaderStyles = {}

-- A gentle EPUB baseline based on WeRead's wr.css/default_epub.css. The APK
-- applies its global font defaults through a custom CSS engine that also
-- filters font sizes against the reader's font-size setting. In an EPUB those
-- global overrides would hide book styling and interfere with KOReader's own
-- font controls, so only supply structural typography defaults here. The
-- book's stylesheet is appended afterward and keeps normal cascade priority.
ReaderStyles.typography_css = [[
body {
    line-height: 1.55;
    text-align: justify;
}
h1, h2, h3, h4, h5, h6 {
    font-weight: bold;
}
h1 { font-size: 1.5em; }
h2 { font-size: 1.4em; }
h3 { font-size: 1.3em; }
h4 { font-size: 1.2em; }
h5 { font-size: 1.1em; }
h6 { font-size: 1em; }
p { margin: 0; }
i, em { font-style: italic; }
b, strong { font-weight: bold; }
pre, blockquote {
    hyphens: none;
    font-size: 0.9em;
}
blockquote { text-align: left; }
hr {
    width: 100%;
    height: 1px;
    margin: 0.5em auto;
}
]]

-- Keep plugin-owned styling narrowly scoped to WeRead image layout. Book CSS
-- is preserved and appended after these defaults so its declarations win.
ReaderStyles.image_css = [[
img {
    max-width: 100%;
    height: auto;
}
.qrbodyPic,
.bodyPic {
    text-align: center;
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

-- WeRead's web stylesheet can set a viewport-sized canvas that does not fit
-- KOReader's reflowable document. Constrain only root geometry; font, color,
-- background and every other author style stay under the normal EPUB cascade.
ReaderStyles.reader_geometry_css = [[
html, body {
    width: auto !important;
    height: auto !important;
    min-width: 0 !important;
    min-height: 0 !important;
    max-width: none !important;
    max-height: none !important;
}
]]

function ReaderStyles.compose(book_css)
    local parts = { ReaderStyles.typography_css, ReaderStyles.image_css }
    if type(book_css) == "string" and book_css ~= "" then
        parts[#parts + 1] = book_css
    end
    parts[#parts + 1] = ReaderStyles.reader_geometry_css
    return table.concat(parts, "\n")
end

return ReaderStyles
