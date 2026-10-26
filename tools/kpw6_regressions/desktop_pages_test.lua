-- Run from the KOReader directory while the reader app is stopped.
-- ./luajit <this-script> <plugin-directory> [output-prefix]
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("settings.reader.lua")
package.path=assert(arg[1]).."/?.lua;"..package.path
require("gettext").changeLang("zh_CN")
require("ui/bidi").setup("zh_CN")
local Device=require("device")
require("document/canvascontext"):init(Device)
local Font=require("ui/font")
for key,value in pairs(G_reader_settings:readSetting("fontmap",{})) do Font.fontmap[key]=value end
local UIManager=require("ui/uimanager")
local BB=require("ffi/blitbuffer")
local Scale=require("miuread.ui_scale")
local Shelf=require("miuread.full_shelf_view")
local Book=require("miuread.book_actions_view")
local Tools=require("miuread.tools_view")
local Store=require("miuread.bookstore_view")
local Guard=require("miuread.transient_guard")
local Screen=Device.screen
local width,height=Screen.getWidth,Screen.getHeight
local cases=0
local function text_values(widget,result)
    result=result or {}
    if type(widget.text)=="string" then result[#result+1]=widget.text end
    for _,child in ipairs(widget) do if type(child)=="table" then text_values(child,result) end end
    return table.concat(result,"|")
end
local function render(widget,name)
    local m=widget._metrics_cache
    local bb=BB.new(m.sw,m.sh,BB.TYPE_BB8)
    widget:paintTo(bb,0,0)
    if arg[2] and m.sw==1236 and m.sh==1648 and Scale.getDisplayMode()=="standard" then bb:writePNG(arg[2].."-"..name..".png") end
    bb:free()
end
local function dock(widget,selected)
    local active=0
    for _,target in ipairs(widget._navigation_targets) do
        if target.selected then active=active+1; assert(target.destination==selected) end
    end
    assert(active==1,"Exactly one dock destination must be visibly selected")
end
local function regions(widget,items)
    local m=widget._metrics_cache
    local last_bottom=0
    for _,box in ipairs(items) do
        assert(box.x>=0 and box.y>=0 and box.w>0 and box.h>0)
        assert(box.x+box.w<=m.sw and box.y+box.h<=m.nav_y,"Content overlaps dock")
        if #items==6 and widget.view_mode=="list" then assert(box.y>=last_bottom);last_bottom=box.y+box.h end
    end
end
local function close(widget)
    widget:_close()
    assert(widget._miu_closed and not UIManager:isWidgetShown(widget))
end
for _,dimensions in ipairs({{1236,1648},{1648,1236},{600,800},{800,600}}) do
    Screen.getWidth=function() return dimensions[1] end
    Screen.getHeight=function() return dimensions[2] end
    for _,display in ipairs({"compact","standard","large"}) do
        Scale.setDisplayMode(display)
        local clicked={}
        local function action(name) return function() clicked[name]=(clicked[name] or 0)+1 end end
        local books={}
        local covers={"921568","25462424","27350700","33381009","695233","603120"}
        for index=1,13 do books[index]={bookId=tostring(index),title=index==1 and "原则" or "长书名用于验证边界 A Very Long Book Title "..index,
            author="一位姓名很长的作者 Long Author Name",source_label="微信读书",progress=1,local_available=index==1,
            cover_path="miuread/covers/"..covers[(index-1)%6+1]..".jpg"} end
        local library=Shelf.show{title="书架",books=books,show_actions=true,show_covers=true,
            on_left_action=action("search"),on_right_action=action("filter"),on_navigate=action("navigate"),
            on_select=function(book) clicked.book=book.bookId end,
            status_tabs={{label="全部",selected=true,callback=action("all")},{label="阅读中",callback=action("reading")},{label="已读完",callback=action("finished")}}}
        dock(library,"library"); render(library,"library"); regions(library,library._book_regions)
        local unchanged=library[1]
        library:_set_mode("list"); assert(library[1]==unchanged,"Selecting the current view must not rebuild or flash")
        library._book_targets[1]:onTapSelect(); assert(clicked.book=="1")
        library._search_target:onTapSelect(); assert(clicked.search==1)
        library._status_targets[2]:onTapSelect(); assert(clicked.reading==1)
        library:_change_page(1); assert(#library._book_targets==6 and library.page==2)
        library:_set_mode("grid"); assert(library.page==2); regions(library,library._book_regions); render(library,"grid")
        library:_change_page(1); assert(#library._book_targets==1 and library.page==3)
        library:_set_mode("list"); assert(library.page==3)
        library._book_targets[1]:onTapSelect(); assert(clicked.book=="13")
        local actions={{label="阅读",icon="book",primary=true,callback=action("read")}}
        for index=1,8 do actions[#actions+1]={label="测试操作 "..index,detail="具有边界限制的说明文字",group=index<5 and "download" or "more",icon="download",callback=action("secondary"..index)} end
        actions[#actions+1]={label="从微信书架移除",danger=true,callback=action("remove")}
        local book=Book.show{book=books[1],source_label="微信读书",actions=actions,on_navigate=action("navigate")}
        dock(book,"library"); regions(book,book._action_regions); render(book,"book")
        unchanged=book[1]
        book:_change_page(-1); assert(book[1]==unchanged,"A swipe beyond the first page must not rebuild or flash")
        assert(UIManager:isWidgetShown(library),"Opening book actions must retain the shelf")
        book._action_targets[1]:onTapSelect(); assert(clicked.secondary1==1 and UIManager:isWidgetShown(book))
        book:_change_page(1); assert(#book._action_targets==2); regions(book,book._action_regions)
        book._action_targets[2]:onTapSelect(); assert(clicked.secondary8==1)
        -- A confirmation/menu may retire bubbles, but cannot retire its page.
        Guard.close_all(); assert(UIManager:isWidgetShown(book) and UIManager:isWidgetShown(library))
        close(book); assert(library.page==3 and UIManager:isWidgetShown(library))
        library.opts.books={}; library:updateItems(); assert(#library._book_targets==0 and library.pages==1)
        render(library,"empty"); close(library)
        local brightness,warmth=12,6
        local rows={}
        for index=1,6 do rows[index]={label=({"阅读历史","文件管理","插件与扩展","觅阅设置","KOReader 设置","更多工具"})[index],icon="settings",callback=action("tool"..index)} end
        local tools=Tools.show{wifi_name="ASUS_Reading_Room_ABCDEFGHIJKLMNOPQRSTUVWXYZ_超长网络名称",wifi_status="已连接",
            on_wifi=action("wifi"),on_navigate=action("navigate"),
            frontlight={brightness={min=0,max=24,value=12,on_set=function(value) brightness=value;return value end},
                warmth={min=0,max=24,value=6,on_set=function(value) warmth=value;return value end}},
            sync={icon="refresh",label="同步",detail="已同步",callback=action("sync")},
            downloads={icon="download",label="下载",detail="无进行中任务",callback=action("download")},rows=rows}
        dock(tools,"tools"); regions(tools,tools._row_regions); render(tools,"tools")
        tools._wifi_target:onTapSelect(); assert(clicked.wifi==1)
        tools._tile_targets[1]:onTapSelect(); tools._tile_targets[2]:onTapSelect(); assert(clicked.sync==1 and clicked.download==1)
        tools._row_targets[6]:onTapSelect(); assert(clicked.tool6==1)
        local slider=tools._sliders.brightness
        slider:onTapSlide(nil,{pos={x=slider.dimen.x+slider.bar_w,y=slider.dimen.y}}); assert(brightness==24)
        local overlay=require("miuread.desktop_ui").frame(20,20)
        UIManager:show(overlay)
        slider:onTapSlide(nil,{pos={x=slider.dimen.x,y=slider.dimen.y}}); assert(brightness==24,"Overlay must block underlying controls")
        UIManager:close(overlay)
        slider:onTapSlide(nil,{pos={x=slider.dimen.x-100,y=slider.dimen.y}}); assert(brightness==0)
        assert(warmth==6,"Brightness must not modify warmth")
        close(tools)
        local no_light=Tools.show{wifi_name="无线网络已关闭",wifi_status="已关闭",sync={icon="sync",label="同步"},downloads={icon="download",label="下载"},rows=rows}
        assert(not next(no_light._sliders)); regions(no_light,no_light._row_regions); render(no_light,"no-frontlight");close(no_light)
        local store_rows={
            {text="为你推荐",post_text="根据阅读记录发现可能喜欢的书",callback=action("recommend")},
            {text="排行榜",post_text="总榜 · 飙升 · 新书 · 热门",callback=action("ranks")},
            {text="分类浏览",post_text="按主题与子分类浏览",callback=action("categories")},
            {text="微信书架",post_text="查看已加入的图书",callback=action("shelf")},
        }
        local store=Store.show{landing=true,title="书城",rows=store_rows,on_search=action("store-search")}
        dock(store,"bookstore");regions(store,store._row_regions);render(store,"bookstore")
        store._row_targets[1]:onTapSelect();store._search_target:onTapSelect()
        assert(clicked.recommend==1 and clicked["store-search"]==1);close(store)
        local category_rows={}
        for index=1,19 do category_rows[index]={text="计算机与互联网 / 很长的分类名称 "..index,callback=action("category"..index)} end
        store=Store.show{title="分类浏览",rows=category_rows,on_back=action("store-back"),on_refresh=action("store-refresh")}
        dock(store,"bookstore");regions(store,store._row_regions);render(store,"store-categories")
        store:_change_page(1);store:_change_page(1);store:_change_page(1)
        assert(#store._row_targets==1 and store.page==4);store._row_targets[1]:onTapSelect();assert(clicked.category19==1)
        unchanged=store[1];store:_change_page(1);assert(store[1]==unchanged)
        store._back_target:onTapSelect();assert(store._miu_closed)
        local discovery=Shelf.show{title="为你推荐",dock_section="bookstore",discovery=true,books=books,
            show_actions=true,on_back=action("store-back"),on_right_action=action("store-refresh"),
            browse_actions={{label="上一批",enabled=false},{label="第 1 批",enabled=false},{label="下一批",callback=action("next-batch")}}}
        dock(discovery,"bookstore");regions(discovery,discovery._book_regions);render(discovery,"store-results")
        discovery._browse_targets[3]:onTapSelect();assert(clicked["next-batch"]==1)
        discovery.opts.books={};discovery:updateItems();render(discovery,"store-empty");close(discovery)
        cases=cases+1
    end
end
Screen.getWidth,Screen.getHeight=width,height
print("DESKTOP_PAGES_PASS",cases,"screen/display combinations: shelf, book actions, tools, dock, filtering, return path and slider isolation")
