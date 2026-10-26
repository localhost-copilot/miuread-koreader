-- Fixed-capacity pagination must never skip books when orientation changes.
package.path = "miuread.koplugin/?.lua;" .. package.path
local Layout = require("miuread.home_layout")
local file = assert(io.open("miuread.koplugin/main.lua", "rb"))
local source = file:read("*a"); file:close()
local function method(name)
    return assert(source:match("function Plugin:" .. name .. "%b().-\nend"), name)
end
local Plugin = assert(loadstring("local HomeLayout = require('miuread.home_layout'); local Plugin = {}\n"
    .. method("_home_page_limit") .. "\n" .. method("_home_preview_page") .. "\nreturn Plugin"))()
function Plugin:_home_book_key(book) return book.bookId or book.file end

for _, dimensions in ipairs({{600,800}, {758,1024}, {1236,1648}, {1648,1236}, {800,600}, {1440,1920}}) do
    local m = Layout.metrics(dimensions[1], dimensions[2])
    local columns, rows, cg, rg, cw, ch = Layout.grid(m, m.content_w, math.floor(m.sh * .4))
    assert(columns * rows == Plugin:_home_page_limit(), "Rendered capacity and pagination disagree")
    assert(columns * cw + (columns - 1) * cg <= m.content_w, "Grid exceeds available width")
    assert(cw > 0 and ch > 0 and rg > 0)
    assert(m.nav_y + m.nav_h == m.sh and m.body_y + m.body_h < m.nav_y)
end

for _, count in ipairs({0, 1, 5, 6, 7, 12, 13, 48, 49}) do
    local books = {}
    for index = 1, count do books[index] = {bookId = tostring(index)} end
    if count > 0 then books[#books + 1] = books[1] end
    local observed, last_size = {}, nil
    local _, _, pages = Plugin:_home_preview_page(books, nil, 1)
    for page = 1, pages do
        local items, current, total, unique = Plugin:_home_preview_page(books, nil, page)
        assert(current == page and total == pages and unique == count)
        assert(#items <= Layout.PAGE_SIZE)
        if page < pages then assert(#items == Layout.PAGE_SIZE) end
        for _, book in ipairs(items) do
            assert(not observed[book.bookId], "Book appears on multiple pages")
            observed[book.bookId] = true
        end
        last_size = #items
    end
    for index = 1, count do assert(observed[tostring(index)], "Book disappeared during pagination") end
    local _, clamped = Plugin:_home_preview_page(books, nil, 999)
    assert(clamped == pages)
end

-- The Tools menu retains user-selected actions after removing the shortcut row.
local tools = assert(loadstring("local Plugin = {}\n" .. method("show_home_menu") .. "\nreturn Plugin"))()
local clicked = {}
function tools:_home_enabled() return true end
function tools:_home_action_entries()
    return {
        {label="刷新", callback=function() clicked.refresh=true end},
        {label="同步", badge="2", callback=function() clicked.sync=true end},
        {label="下载", callback=function() clicked.download=true end},
    }
end
function tools:tools_menu() return {{text="全部书籍", callback=function() clicked.library=true end}} end
function tools:_show_home_settings_center() clicked.settings = true end
function tools:_show_standalone_menu(title, rows)
    assert(title == "工具")
    for _, row in ipairs(rows) do row.callback() end
end
tools:show_home_menu()
for _, action in ipairs({"refresh", "sync", "download", "library", "settings"}) do assert(clicked[action], action .. " inaccessible") end
print("Home layout: pagination boundaries, orientation capacity and Tools actions PASS")
