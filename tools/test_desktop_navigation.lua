-- Exercise the real controller methods without device or network side effects.
package.path="miuread.koplugin/?.lua;"..package.path
local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=file:read("*a"); file:close()
local function method(name) return assert(source:match("function Plugin:"..name.."%b().-\nend"),name) end
local queued,stack={},{}
local home_raised=false
local ui={_window_stack=stack,nextTick=function(_,callback) queued[#queued+1]=callback end,
    isWidgetShown=function(_,widget) return not widget.closed end}
local home={is_shown=function() return true end,raise=function() home_raised=true end,
    cancel_section_cleanup=function() end}
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
    assert((calls.closed or 0)==before and #queued==1,"Navigation must retain the old page until its replacement can paint")
    drain()
    assert(calls.closed==before+1)
end
assert(calls.library==1 and calls.bookstore==1 and calls.tools==1 and home_raised)
local closed=calls.closed
Plugin:_home_navigate("library"); Plugin:_home_navigate("tools"); drain()
assert(calls.closed==closed+1,"Superseded navigation must not expose the underlying home")
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

-- Reproduce the delayed crash after ReaderUI frees its plugin. Restoring a
-- parked Home must bind both its input callback and idle work to the desktop.
local now,tasks,interaction=0,{},nil
local desktop
local restore_ui={setDirty=function() end,scheduleIn=function(_,delay,callback)
    tasks[#tasks+1]={at=now+delay,callback=callback}
end,unschedule=function(_,callback)
    for index=#tasks,1,-1 do if tasks[index].callback==callback then table.remove(tasks,index) end end
end}
local parked={is_shown=function() return true end,current=function() return {} end,
    unpark=function(_,options) interaction=options.on_interaction end,raise=function() end}
local lifecycle=assert(loadstring([[
local Plugin={}
local UIManager,HomeView,home_owner,monotonic_wall_time=...
local READER_CLOSE={generation=1,state="document_closed",requested_clock=0}
local HOME_SESSION={}
local Config={}
local logger={info=function() end,warn=function() end}
local persist_home_session=function() end
]]..method("_complete_reader_close").."\n"..method("_home_enter_post_reader_priority_window").."\n"
    ..method("_home_resume_visible_work_after_idle").."\n"..method("_home_note_interaction").."\nreturn Plugin"))(
    restore_ui,parked,function() return desktop end,function() return now end)
desktop=setmetatable({store={},progress_runs=0},{__index=lifecycle})
local reader=setmetatable({store={}},{__index=lifecycle})
function lifecycle:_reader_close_snapshot() return {lifecycle="closed",filemanager=true} end
function lifecycle:_active_reader_ui() return nil end
function lifecycle:_home_modal_surface_active() return false end
function lifecycle:_home_background_blocked() return false end
function lifecycle:_home_ui_busy() return false end
function lifecycle:_home_schedule_progress()
    assert(self.store,"Idle progress refresh used a freed reader plugin")
    self.progress_runs=self.progress_runs+1
end
function lifecycle:_home_bump_interaction_generation() self.interactions=(self.interactions or 0)+1 end
for _,name in ipairs({"_ensure_reader_transition_guard","_close_miuread_transients","_set_foreground",
    "_home_apply_recent_snapshot_to_home","_close_reader_recovery_surface","_release_reader_transition_guard",
    "_resume_home_preferences_flush","_finish_page_transition","_resume_pending_post_reader_work",
    "_background_log_state","_clear_reader_return","_home_refresh_recent_hero_cached",
    "_home_schedule_local_metadata","_home_schedule_remote_covers","_pump_finished_status",
    "_home_schedule_cover_derivatives","_home_clear_lockscreen_visual_hold"}) do lifecycle[name]=function() end end
assert(reader:_complete_reader_close(1,"regression"))
reader.store=nil
assert(type(interaction)=="function")
interaction(true,"tap")
assert(desktop.interactions==1 and reader.interactions==nil,"Restored Home input retained the reader plugin")
for _=1,10 do
    if #tasks==0 then break end
    table.sort(tasks,function(a,b) return a.at<b.at end)
    local task=table.remove(tasks,1); now=task.at; task.callback()
end
assert(desktop.progress_runs==1 and reader.progress_runs==nil,"Idle work must survive ReaderUI teardown")
print("Reader return: parked desktop owns input and delayed progress after reader teardown PASS")

-- First-frame latency must exclude the intentional background protection wait.
local clock,paint_callback,release_callback=12,nil,nil
local transition={page_transition_generation=7,page_transition_state="opening_reader",
    page_transition_started_kind="opening_reader",page_transition_started_clock=10}
local timing_ui={tickAfterNext=function(_,callback) paint_callback=callback end,
    scheduleIn=function(_,delay,callback) assert(delay==1.2);release_callback=callback end,
    unschedule=function() end}
local timing=assert(loadstring([[
local Plugin={}
local UIManager,HOME_SESSION,monotonic_wall_time=...
local HomeView={is_shown=function() return false end}
local reader_close_active=function() return false end
local logger={info=function() end}
]]..method("_finish_page_transition").."\nreturn Plugin"))(timing_ui,transition,function() return clock end)
local samples,resumes={},0
function timing:_active_reader_ui() return true end
function timing:_record_performance(kind,elapsed) samples[#samples+1]={kind,elapsed} end
timing.download_task={resume=function() resumes=resumes+1 end}
timing:_finish_page_transition(1.2,"reader first page")
assert(#samples==0 and transition.page_transition_state=="opening_reader")
clock=12.2;paint_callback()
assert(#samples==1 and samples[1][1]=="reader_open" and samples[1][2]==2200)
assert(resumes==0,"Background protection must stay active until its original deadline")
clock=13.2;release_callback()
assert(#samples==1 and resumes==1 and transition.page_transition_state=="idle")
transition.page_transition_generation=8;transition.page_transition_state="opening_reader"
transition.page_transition_started_kind="opening_reader";transition.page_transition_started_clock=20
timing:_finish_page_transition(1.2,"reader first page")
clock=24;paint_callback()
assert(#samples==2 and samples[2][2]==4000,"Real slow first frames must still be recorded")
transition.page_transition_generation=9;transition.page_transition_started_clock=25
timing:_finish_page_transition(1.2,"reader first page")
transition.page_transition_generation=10;clock=26;paint_callback()
assert(#samples==2,"A superseded reader transition must not report latency")
print("Reader timing: first repaint excludes quiet wait, preserves background barrier and records real lag PASS")

-- Cover batches retain coalescing/generation guards while selecting the narrow
-- desktop updater; the original shelf implementation keeps its old callback.
local cover_tasks={}
local cover_ui={scheduleIn=function(_,_,callback) cover_tasks[#cover_tasks+1]=callback end}
local cover_plugin=assert(loadstring([[
local Plugin={}
local UIManager=...
local logger={warn=function() end}
]]..method("_schedule_shelf_cover_refresh").."\nreturn Plugin"))(cover_ui)
function cover_plugin:_begin_cover_guard() end
function cover_plugin:_clear_cover_guard() end
cover_plugin._cover_generation=1
local calls={narrow=0,legacy=0}
local desktop={refreshCovers=function() calls.narrow=calls.narrow+1 end,
    updateItems=function() error("Cover batch rebuilt the desktop page") end}
cover_plugin:_schedule_shelf_cover_refresh(desktop,1)
cover_plugin:_schedule_shelf_cover_refresh(desktop,1)
assert(#cover_tasks==1);table.remove(cover_tasks,1)();assert(calls.narrow==1)
cover_plugin:_schedule_shelf_cover_refresh(desktop,1)
cover_plugin._cover_generation=2
table.remove(cover_tasks,1)();assert(calls.narrow==1,"Stale cover batch updated a replacement page")
cover_plugin:_schedule_shelf_cover_refresh({updateItems=function() calls.legacy=calls.legacy+1 end},2)
table.remove(cover_tasks,1)();assert(calls.legacy==1)
print("Cover batches: bounded desktop update, coalescing, stale generation and legacy fallback PASS")
