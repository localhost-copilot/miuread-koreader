-- Exercise the real controller methods without device or network side effects.
package.path="miuread.koplugin/?.lua;"..package.path
local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=file:read("*a"); file:close()
local function method(name) return assert(source:match("function Plugin:"..name.."%b().-\nend"),name) end
local queued,stack={},{}
local home_raised=false
local ui={_window_stack=stack,nextTick=function(_,callback) queued[#queued+1]=callback end,
    isWidgetShown=function(_,widget) return not widget.closed end}
local home={is_shown=function() return true end,raise=function() home_raised=true end}
local Plugin=assert(loadstring([[
local Plugin={}
local UIManager,HomeView=...
local monotonic_wall_time=function() return 100 end
local UnifiedLibrary={canonical_source=function(book) return book.source end}
local ShelfProgress={is_finished=function(book) return book.finished==true end}
local U={file_exists=function() return false end}
]]..method("_home_navigate").."\n"..method("_home_modal_surface_active").."\n"
    ..method("_home_all_books_apply").."\n"..method("_home_all_books_state").."\n"
    ..method("show_home_all_books").."\nreturn Plugin"))(ui,home)
local function drain()
    while #queued>0 do table.remove(queued,1)() end
end
local calls={}
function Plugin:_close_miuread_transients() calls.closed=(calls.closed or 0)+1 end
function Plugin:show_home_all_books_stub() calls.library=(calls.library or 0)+1 end
function Plugin:show_bookstore() calls.bookstore=(calls.bookstore or 0)+1 end
function Plugin:show_home_menu() calls.tools=(calls.tools or 0)+1 end
function Plugin:show_miuread_home() calls.home=(calls.home or 0)+1 end
local show_library=Plugin.show_home_all_books
Plugin.show_home_all_books=Plugin.show_home_all_books_stub
for _,destination in ipairs({"library","bookstore","tools","home"}) do
    local before=calls.closed or 0
    Plugin:_home_navigate(destination)
    assert(calls.closed==before+1 and #queued==1,"Navigation must retire previous surfaces before opening the destination")
    drain()
end
assert(calls.library==1 and calls.bookstore==1 and calls.tools==1 and home_raised)
Plugin:_home_navigate("library"); Plugin:_home_navigate("tools"); drain()
assert(calls.library==1 and calls.tools==2,"Rapid navigation must open only the latest destination")
home.is_shown=function() return false end
Plugin:_home_navigate("home"); drain(); assert(calls.home==1)
Plugin.show_home_all_books=show_library

stack[1]={widget={_miuread_desktop_page=true}}
assert(Plugin:_home_modal_surface_active(),"Home may not repaint through a full-screen child page")
stack[1].widget.closed=true
assert(not Plugin:_home_modal_surface_active())
stack[1]={widget={_miuread_modal_surface=true}}
assert(Plugin:_home_modal_surface_active())
stack[1].widget._miuread_recovery_surface=true
assert(not Plugin:_home_modal_surface_active())
stack[1]=nil

local books={{title="B",source="weread",progress=3},{title="A",source="local",progress=0},
    {title="C",source="weread",progress=100,finished=true}}
function Plugin:_home_all_rows() return books end
function Plugin:_home_book_time(book) return book.title:byte() end
function Plugin:_home_show_full_shelf(_,rows,options) self.visible,self.options=rows,options; return true end
function Plugin:_home_close_full_shelf() self.shelf_closed=true end
function Plugin:_home_all_books_option_dialog(kind) self.opened_filter=kind end
function Plugin:show_home_search_dialog() self.searched=true end
Plugin._home_all_books_options={source="weread",status="all",sort="title"}
assert(Plugin:show_home_all_books())
assert(#Plugin.visible==2 and Plugin.visible[1].title=="B")
Plugin.options.on_source(); assert(Plugin.opened_filter=="source")
Plugin.options.on_sort(); assert(Plugin.opened_filter=="sort")
Plugin.options.on_left_action(); assert(Plugin.searched)
Plugin.options.status_tabs[2].callback(); drain()
assert(Plugin.shelf_closed and #Plugin.visible==1 and Plugin.visible[1].progress==3)
assert(Plugin._home_all_books_options.source=="weread" and Plugin._home_all_books_options.sort=="title")
Plugin._home_all_books_options.source="local"
assert(Plugin:show_home_all_books() and #Plugin.visible==0,"An empty filter must remain a navigable shelf")
Plugin.options.status_tabs[1].callback(); drain()
assert(#Plugin.visible==1 and Plugin.visible[1].title=="A")
print("Desktop navigation: destination ownership, background exclusion, filters, empty results and search PASS")
