local ReaderStyles = {}

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
    local parts = { ReaderStyles.image_css }
    if type(book_css) == "string" and book_css ~= "" then
        parts[#parts + 1] = book_css
    end
    parts[#parts + 1] = ReaderStyles.reader_geometry_css
    return table.concat(parts, "\n")
end

return ReaderStyles
