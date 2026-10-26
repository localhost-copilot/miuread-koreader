-- Run from KOReader with no reader process active:
-- ./luajit <repo>/tools/kpw6_regressions/home_layout_test.lua <plugin> <output-prefix>
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("settings.reader.lua")
package.path = assert(arg[1]) .. "/?.lua;plugins/miuread.koplugin/?.lua;" .. package.path
require("gettext").changeLang("zh_CN")
require("ui/bidi").setup("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
local Font = require("ui/font")
for key, value in pairs(G_reader_settings:readSetting("fontmap", {})) do Font.fontmap[key] = value end
local Home = require("miuread.home_view")
local Layout = require("miuread.home_layout")
local BB = require("ffi/blitbuffer")
local Screen = Device.screen
local original_width, original_height = Screen.getWidth, Screen.getHeight
local output_prefix = arg[2]

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
local function assert_inside(box, bounds)
    assert(box.x >= bounds.x and box.y >= bounds.y and box.x + box.w <= bounds.x + bounds.w
        and box.y + box.h <= bounds.y + bounds.h, "Widget overflows its region")
end
local function text_values(widget, values)
    values = values or {}
    if type(widget.text) == "string" then values[#values+1] = widget.text end
    for _, child in ipairs(widget) do
        if type(child) == "table" then text_values(child, values) end
    end
    return table.concat(values, "|")
end
local cover_root = "miuread/covers/"
local covers = {"921568", "25462424", "27350700", "33381009", "695233", "603120"}
local long_title = "一本非常非常长的中文书名用于验证省略和边界 A Very Long English Book Title"
local cases = 0
for _, dimensions in ipairs({{1236,1648}, {1648,1236}, {600,800}, {800,600}}) do
    Screen.getWidth = function() return dimensions[1] end
    Screen.getHeight = function() return dimensions[2] end
    for _, display in ipairs({"compact", "standard", "large"}) do
        local clicked = {}
        local function action(name) return function() clicked[name] = (clicked[name] or 0) + 1 end end
        local books = {}
        for index = 1, Layout.PAGE_SIZE do
            books[index] = {bookId=tostring(index), title=index == 2 and long_title or "测试书籍 " .. index,
                author="测试作者", cover_path=cover_root .. covers[index] .. ".jpg", progress=index * 7}
        end
        local options = {
            clock_text="17:36", date_text="10月26日  周一", battery_text="96%",
            wifi_text="这个无线网络名称特别特别长_ABCDEFGHIJKLMNOPQRSTUVWXYZ", account_name=long_title,
            bluetooth_visible=true, bluetooth_text="蓝牙设备也有很长的名称",
            display_size=display, hero={bookId="hero", title=long_title, author=long_title, progress=1,
                cover_path=cover_root .. "921568.jpg", last_read_text="今天 14:30", on_tap=action("resume")},
            shelf_books=books, shelf_page=1, shelf_pages=8,
            weread_stats={available=true, today_seconds=480, total_seconds=480},
            local_stats={available=true, today_seconds=60, total_seconds=60},
            tabs={{title="书架",count=48,selected=true,on_tap=action("tab")},
                {title="本机",count=1,on_tap=action("local")}, {title="最近",count=1,on_tap=action("recent")}},
            on_home=action("home"), on_library=action("library"), on_bookstore=action("bookstore"), on_menu=action("tools"),
            on_open_book=function(book) assert(book.bookId); clicked.book=true end,
            on_shelf_page=action("page"), section_cache_key="shelf", section_revision="1",
        }
        local widget = assert(Home.show(options))
        assert(widget._navigation_targets[1].selected==true,"Home dock must select Home")
        for index=2,4 do assert(not widget._navigation_targets[index].selected) end
        local m = widget._metrics_cache
        local summary = widget._summary_slot
        assert(text_values(summary.parent[summary.index]):find("微信 · 今日 8分钟", 1, true),
            "Cloud and device reading time must not be counted twice")
        assert_inside(widget._hero_region, widget.content_dimen)
        assert(not overlaps(widget._hero_region, widget.section_dimen))
        local slot_count = 0
        local siblings = {}
        for _, slot in pairs(widget._section_book_slots) do
            assert_inside(slot, widget.section_dimen)
            assert(slot.y + slot.h <= m.nav_y - m.gap - m.footer_h)
            for _, other in ipairs(siblings) do assert(not overlaps(slot, other), "Book cards overlap") end
            siblings[#siblings+1] = slot
            slot_count = slot_count + 1
        end
        assert(slot_count == Layout.PAGE_SIZE, "Some paginated books are invisible")
        local buffer = BB.new(dimensions[1], dimensions[2], BB.TYPE_BB8)
        buffer:paintRect(0, 0, dimensions[1], dimensions[2], BB.COLOR_WHITE)
        widget:paintTo(buffer, 0, 0)
        if output_prefix and dimensions[1] == 1236 and display == "standard" then buffer:writePNG(output_prefix .. "-long.png") end
        buffer:free()
        for index, name in ipairs({"home", "library", "bookstore", "tools"}) do
            assert_inside(widget._navigation_targets[index].dimen, widget.dimen)
            widget._navigation_targets[index]:onTapSelect()
            assert(clicked[name] == 1, "Navigation callback unreachable: " .. name)
        end

        -- The clock, header and summary must update without recreating book widgets.
        local section, hero_layer = widget._section_layer, widget._static_body_layer
        local battery = widget._header_text_refs.battery
        assert(widget:updateHeader{wifi_text=long_title .. long_title, battery_text="100%"})
        assert(widget:updateDashboard{clock_text="18:00", date_text="10月27日  周二", local_stats={available=true,today_seconds=120,total_seconds=120}})
        assert(widget._section_layer == section and widget._static_body_layer == hero_layer)
        assert(widget._header_text_refs.battery == battery)
        assert(battery:getSize().w <= battery.max_width)
        options.hero.title = "原则"
        options.hero.author = "瑞·达利欧"
        assert(widget:updateHero(options.hero))
        assert(widget._section_layer == section, "Hero update recreated the book grid")
        assert(widget:updateBook("2"), "Individual book update failed")

        -- A sparse final page keeps its positions and clears the previous six cards.
        local first = widget._section_book_slots["1"]
        widget:updateSection{shelf_books={books[1]},section_cache_key="shelf",section_revision="last",shelf_page=8}
        local sparse = widget._section_book_slots["1"]
        assert(sparse.x == first.x and sparse.y == first.y and sparse.w == first.w and sparse.h == first.h)
        assert(not widget._section_book_slots["2"])
        widget:updateSection{shelf_books=books,section_cache_key="shelf",section_revision="1",shelf_page=1}
        assert(widget:updateBook("2"), "Returning to cached page lost book update slots")
        -- A section cleanup queued before dock navigation cannot refresh
        -- through the newly opened destination or a modal overlay.
        widget:_mark_dirty("section")
        local cleanup=assert(widget._section_clean_refresh_task)
        local UIManager=require("ui/uimanager")
        local overlay=require("miuread.desktop_ui").frame(20,20)
        UIManager:show(overlay)
        local set_dirty=UIManager.setDirty
        UIManager.setDirty=function() error("Hidden home cleanup requested a refresh") end
        cleanup()
        UIManager.setDirty=set_dirty
        UIManager:close(overlay)
        if output_prefix and dimensions[1] == 1236 and display == "standard" then
            local bb = BB.new(dimensions[1], dimensions[2], BB.TYPE_BB8)
            bb:paintRect(0,0,dimensions[1],dimensions[2],BB.COLOR_WHITE)
            widget:paintTo(bb,0,0)
            bb:writePNG(output_prefix .. ".png")
            bb:free()
        end
        options.weread_stats = {available=false}
        widget:updateDashboard{weread_stats=options.weread_stats}
        local fallback = widget._summary_slot
        assert(text_values(fallback.parent[fallback.index]):find("本机 · 今日 2分钟", 1, true),
            "Missing cloud statistics should fall back to device statistics")
        widget:update({display_size=display, shelf_books={}, tabs=options.tabs,
            clock_text="18:00", date_text="10月26日 周一", show_weread_stats=false, show_local_stats=false,
            alerts={{title="账号需要处理",detail="点击查看状态"}}}, "full")
        assert(not widget._summary_slot)
        assert(not overlaps(widget._hero_region, widget.section_dimen))
        local empty = BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
        widget:paintTo(empty,0,0)
        empty:free()
        assert(widget:updateDashboard{clock_text="18:01"})
        Home.close()
        cases = cases + 1
    end
end
Screen.getWidth, Screen.getHeight = original_width, original_height
print("HOME_RENDER_PASS", cases, "screen/display combinations; paging, navigation and partial refresh")
