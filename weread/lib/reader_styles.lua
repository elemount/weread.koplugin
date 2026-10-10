local ReaderStyles = {}

local absolute_units_in_px = {
    px = 1,
    pt = 96 / 72,
    pc = 16,
    ["in"] = 96,
    cm = 96 / 2.54,
    mm = 96 / 25.4,
    q = 96 / 101.6,
}

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function format_rem(value)
    local formatted = string.format("%.8f", value):gsub("0+$", ""):gsub("%.$", "")
    if formatted == "" or formatted == "-0" then return "0" end
    return formatted
end

local function absolute_length_to_rem(token)
    local number, unit = token:match("^([%+%-]?[%d]*%.?[%d]+)([%a]+)$")
    if not number then
        number, unit = token:match("^([%+%-]?[%d]*%.?[%d]+[eE][%+%-]?%d+)([%a]+)$")
    end
    unit = unit and unit:lower()
    local factor = unit and absolute_units_in_px[unit]
    local amount = number and tonumber(number)
    if not factor or not amount then return nil end
    return format_rem(amount * factor / 14) .. "rem"
end

local function rewrite_font_size_expression(value, convert_top_level)
    local out, functions = {}, {}
    local cursor, quote, comment = 1, nil, false
    while cursor <= #value do
        local pair = value:sub(cursor, cursor + 1)
        local char = value:sub(cursor, cursor)
        if comment then
            if pair == "*/" then
                out[#out + 1] = pair
                comment = false
                cursor = cursor + 2
            else
                out[#out + 1] = char
                cursor = cursor + 1
            end
        elseif quote then
            out[#out + 1] = char
            if char == "\\" and cursor < #value then
                out[#out + 1] = value:sub(cursor + 1, cursor + 1)
                cursor = cursor + 2
            else
                if char == quote then quote = nil end
                cursor = cursor + 1
            end
        elseif pair == "/*" then
            out[#out + 1] = pair
            comment = true
            cursor = cursor + 2
        elseif char == "\"" or char == "'" then
            out[#out + 1] = char
            quote = char
            cursor = cursor + 1
        elseif char == "(" then
            local function_name = value:sub(1, cursor - 1):match("([%a%-]+)$")
            functions[#functions + 1] = function_name and function_name:lower() or ""
            out[#out + 1] = char
            cursor = cursor + 1
        elseif char == ")" then
            functions[#functions] = nil
            out[#out + 1] = char
            cursor = cursor + 1
        elseif char:match("[%d%.%+%-]") then
            local previous = cursor > 1 and value:sub(cursor - 1, cursor - 1) or ""
            local starts_token = cursor == 1 or not previous:match("[%w_%-]")
            local tail = value:sub(cursor)
            local number, unit = tail:match(
                "^([%+%-]?[%d]*%.?[%d]+[eE][%+%-]?%d+)([%a]+)")
            if not number then
                number, unit = tail:match("^([%+%-]?[%d]*%.?[%d]+)([%a]+)")
            end
            if starts_token and number then
                local token = number .. unit
                local following = value:sub(cursor + #token, cursor + #token)
                local bounded = following == "" or not following:match("[%w_%-]")
                local allowed_function = false
                for index = #functions, 1, -1 do
                    if functions[index] == "calc" or functions[index] == "var" then
                        allowed_function = true
                        break
                    end
                end
                local convert_here = (#functions == 0 and convert_top_level)
                    or allowed_function
                local converted = bounded and convert_here
                    and absolute_length_to_rem(token) or nil
                out[#out + 1] = converted or token
                cursor = cursor + #token
            else
                out[#out + 1] = char
                cursor = cursor + 1
            end
        else
            out[#out + 1] = char
            cursor = cursor + 1
        end
    end
    return table.concat(out)
end

local function convert_font_size_value(property, value)
    local leading = value:match("^(%s*)") or ""
    local trailing = value:match("(%s*)$") or ""
    local core = value:sub(#leading + 1, #value - #trailing)
    local important_start = core:lower():match("()%s*!important%s*$")
    local important
    if important_start then
        important = core:sub(important_start)
        core = core:sub(1, important_start - 1)
    end

    if property == "font-size" then
        local rewritten = rewrite_font_size_expression(core, true)
        if rewritten ~= core then
            return leading .. rewritten .. (important or "") .. trailing
        end
        return value
    end

    -- In the font shorthand the first absolute length is its font-size. The
    -- later length after `/` is line-height and should keep its original unit.
    local cursor, quote, comment, parens = 1, nil, false, 0
    while cursor <= #core do
        local pair = core:sub(cursor, cursor + 1)
        local char = core:sub(cursor, cursor)
        if comment then
            if pair == "*/" then comment = false; cursor = cursor + 2
            else cursor = cursor + 1 end
        elseif quote then
            if char == "\\" then cursor = cursor + 2
            elseif char == quote then quote = nil; cursor = cursor + 1
            else cursor = cursor + 1 end
        elseif pair == "/*" then
            comment = true
            cursor = cursor + 2
        elseif char == "\"" or char == "'" then
            quote = char
            cursor = cursor + 1
        elseif char == "(" then
            parens = parens + 1
            cursor = cursor + 1
        elseif char == ")" then
            parens = math.max(0, parens - 1)
            cursor = cursor + 1
        elseif parens == 0 and (char:match("[%d%.%+%-]"))
            and (cursor == 1 or core:sub(cursor - 1, cursor - 1):match("[%s/]")) then
            local token = core:sub(cursor):match("^([^%s/]+)")
            local converted = token and absolute_length_to_rem(token)
            if converted then
                local before = core:sub(1, cursor - 1)
                local after = core:sub(cursor + #token)
                return leading .. before .. converted .. after .. (important or "") .. trailing
            end
            cursor = cursor + (token and #token or 1)
        else
            cursor = cursor + 1
        end
    end
    local rewritten = rewrite_font_size_expression(core, false)
    if rewritten ~= core then
        return leading .. rewritten .. (important or "") .. trailing
    end
    return value
end

local function rewrite_declaration(segment)
    local cursor, quote, comment, parens = 1, nil, false, 0
    while cursor <= #segment do
        local pair = segment:sub(cursor, cursor + 1)
        local char = segment:sub(cursor, cursor)
        if comment then
            if pair == "*/" then comment = false; cursor = cursor + 2
            else cursor = cursor + 1 end
        elseif quote then
            if char == "\\" then cursor = cursor + 2
            elseif char == quote then quote = nil; cursor = cursor + 1
            else cursor = cursor + 1 end
        elseif pair == "/*" then
            comment = true
            cursor = cursor + 2
        elseif char == "\"" or char == "'" then
            quote = char
            cursor = cursor + 1
        elseif char == "(" then
            parens = parens + 1
            cursor = cursor + 1
        elseif char == ")" then
            parens = math.max(0, parens - 1)
            cursor = cursor + 1
        elseif char == ":" and parens == 0 then
            local property = trim(segment:sub(1, cursor - 1)
                :gsub("/%*.-%*/", "")):lower()
            if property ~= "font-size" and property ~= "font" then return segment end
            return segment:sub(1, cursor) .. convert_font_size_value(
                property, segment:sub(cursor + 1))
        else
            cursor = cursor + 1
        end
    end
    return segment
end

local function rewrite_font_size_declarations(css, inline)
    if type(css) ~= "string" or css == "" then return css end
    local out, segment_start = {}, 1
    local depth = inline and 1 or 0
    local cursor, quote, comment, parens, brackets = 1, nil, false, 0, 0
    while cursor <= #css do
        local pair = css:sub(cursor, cursor + 1)
        local char = css:sub(cursor, cursor)
        if comment then
            if pair == "*/" then comment = false; cursor = cursor + 2
            else cursor = cursor + 1 end
        elseif quote then
            if char == "\\" then cursor = cursor + 2
            elseif char == quote then quote = nil; cursor = cursor + 1
            else cursor = cursor + 1 end
        elseif pair == "/*" then
            comment = true
            cursor = cursor + 2
        elseif char == "\"" or char == "'" then
            quote = char
            cursor = cursor + 1
        elseif char == "(" then
            parens = parens + 1
            cursor = cursor + 1
        elseif char == ")" then
            parens = math.max(0, parens - 1)
            cursor = cursor + 1
        elseif char == "[" then
            brackets = brackets + 1
            cursor = cursor + 1
        elseif char == "]" then
            brackets = math.max(0, brackets - 1)
            cursor = cursor + 1
        elseif parens == 0 and brackets == 0 and char == "{" then
            out[#out + 1] = css:sub(segment_start, cursor)
            segment_start = cursor + 1
            depth = depth + 1
            cursor = cursor + 1
        elseif parens == 0 and brackets == 0 and char == "}" then
            if depth > 0 then
                out[#out + 1] = rewrite_declaration(css:sub(segment_start, cursor - 1))
            else
                out[#out + 1] = css:sub(segment_start, cursor - 1)
            end
            out[#out + 1] = char
            segment_start = cursor + 1
            depth = math.max(0, depth - 1)
            cursor = cursor + 1
        elseif parens == 0 and brackets == 0 and char == ";" and depth > 0 then
            out[#out + 1] = rewrite_declaration(css:sub(segment_start, cursor - 1)) .. char
            segment_start = cursor + 1
            cursor = cursor + 1
        else
            cursor = cursor + 1
        end
    end
    if depth > 0 then
        out[#out + 1] = rewrite_declaration(css:sub(segment_start))
    else
        out[#out + 1] = css:sub(segment_start)
    end
    return table.concat(out)
end

function ReaderStyles.scale_font_sizes(css)
    return rewrite_font_size_declarations(css, false)
end

function ReaderStyles.scale_inline_font_sizes(style)
    return rewrite_font_size_declarations(style, true)
end

-- A gentle EPUB baseline based on WeRead's wr.css/default_epub.css. The APK
-- scales absolute font sizes against its reader setting. KOReader can provide
-- the same behavior when fixed CSS sizes are expressed relative to its root
-- size, so composed book styles convert absolute lengths to 14px-based rem.
-- Existing em, %, rem and keyword sizes keep their relative relationships.
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
.qrbodyPic {
    page-break-inside: avoid;
    break-inside: avoid;
}
.qqreader-fullimg,
img[isfullpage="1"],
img[isFullPage="1"] {
    display: block;
    width: auto;
    height: auto;
    max-width: 100%;
    max-height: 90vh;
    margin: 0 auto;
    page-break-inside: avoid;
    break-inside: avoid;
}
img[keepFit="1"],
img[keepfit="1"] {
    display: block;
    width: auto;
    height: auto;
    max-width: 100%;
    max-height: 85vh;
    margin: 0 auto;
    page-break-inside: avoid;
    break-inside: avoid;
}
.eepub-single-image-title {
    font-size: 0.85em;
    line-height: 1.4;
    text-align: center;
    margin: 0.4em 0.4em 1em;
}
img.h-pic {
    display: inline;
    width: auto;
    height: 1em;
    max-width: 100%;
    vertical-align: baseline;
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
    if type(book_css) == "string" then
        -- content.lua keeps this checkpoint marker in resumable download CSS
        -- so relative image URLs are not rewritten twice across chapters.
        book_css = book_css:gsub(
            "/%* weread%-internal: relative image URLs resolved %*/", "")
        book_css = ReaderStyles.scale_font_sizes(book_css)
    end
    local parts = { ReaderStyles.typography_css, ReaderStyles.image_css }
    if type(book_css) == "string" and book_css ~= "" then
        parts[#parts + 1] = book_css
    end
    parts[#parts + 1] = ReaderStyles.reader_geometry_css
    return table.concat(parts, "\n")
end

return ReaderStyles
