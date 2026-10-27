-- Shared chrome for the reading desktop and its full-screen pages.
local BB = require("ffi/blitbuffer")
local Center = require("ui/widget/container/centercontainer")
local Device = require("device")
local Frame = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Image = require("ui/widget/imagewidget")
local Input = require("ui/widget/container/inputcontainer")
local Overlap = require("ui/widget/overlapgroup")
local Text = require("ui/widget/textwidget")
local Container = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Scale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local D = {}
local Offset = Container:extend{x_off=0,y_off=0}
function Offset:getSize() return self[1]:getSize() end
function Offset:paintTo(bb,x,y) self[1]:paintTo(bb,x+self.x_off,y+self.y_off) end
function D.add(group,x,y,child)
    group[#group+1]=Offset:new{x_off=x,y_off=y,child}
    return child
end
function D.layer(w,h) return Overlap:new{dimen=Geom:new{w=w,h=h},allow_mirroring=false} end
function D.frame(w,h,child,options)
    options=options or {}
    local border=options.border or 0
    return Frame:new{margin=0,padding=0,bordersize=border,radius=options.radius or 0,
        background=options.background or BB.COLOR_WHITE,color=options.color or BB.COLOR_BLACK,
        Center:new{dimen=Geom:new{w=math.max(1,w-2*border),h=math.max(1,h-2*border)},child or D.layer(1,1)}}
end
function D.label(text,w,h,size,options)
    options=options or {}
    return Ui.align(Text:new{text=tostring(text or ""),face=Scale.face("cfont",size or 11,(size or 11)*1.4),
        bold=options.bold==true,fgcolor=options.color or BB.COLOR_BLACK,
        max_width=math.max(1,w),truncate_with_ellipsis=true},w,h,options.align or "left")
end
function D.line(w,h,color) return D.frame(w,h,nil,{background=color or BB.COLOR_BLACK}) end

local Tap = Input:extend{}
function Tap:init()
    self.ges_events={TapSelect={GestureRange:new{ges="tap",range=self.dimen}}}
    if self.hold_callback then
        self.ges_events.HoldSelect={GestureRange:new{ges="hold",range=self.dimen}}
        self.ges_events.HoldRelease={GestureRange:new{ges="hold_release",range=self.dimen}}
    end
end
function Tap:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function Tap:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    if self[1] then self[1]:paintTo(bb,x,y) end
end
function Tap:onTapSelect(_,ges)
    if self._held then self._held=false; return true end
    if os.clock()<(self._blocked_until or 0) then return true end
    self._blocked_until=os.clock()+.2
    if self.callback then self.callback(self.dimen:copy(),ges) end
    return true
end
function Tap:onHoldSelect()
    self._held=true
    if self.hold_callback then self.hold_callback(self.dimen:copy()) end
    return true
end
function Tap:onHoldRelease() self._held=false; self._blocked_until=os.clock()+.2; return true end
function D.tap(w,h,child,callback,hold_callback)
    return Tap:new{dimen=Geom:new{w=w,h=h},callback=callback,hold_callback=hold_callback,
        Center:new{dimen=Geom:new{w=w,h=h},child}}
end
function D.icon(key,w,h,size) return Ui.icon(key,w,h,size or math.floor(h*.55)) end
function D.button(text,w,h,callback,primary)
    local border=Scale.line("thin")
    return D.tap(w,h,D.frame(w,h,D.label(text,w-border*4,h-border*2,12,
        {bold=true,align="center",color=primary and BB.COLOR_WHITE or BB.COLOR_BLACK}),
        {border=primary and 0 or border,radius=Scale.radius(4,3,6),background=primary and BB.COLOR_BLACK or BB.COLOR_WHITE}),callback)
end
function D.cover(book,w,h,show)
    local path=book.home_cover_path or book.cover_path
    if show~=false and path and path~="" then
        local ok,widget=pcall(function()
            local image=Image:new{file=path,width=w,height=h,file_do_cache=true,use_legacy_image_scaling=false}
            image:getSize()
            return image
        end)
        if ok then return widget end
    end
    return D.frame(w,h,D.label(book.title or "未命名",w-8,h,9,{bold=true,align="center"}),{border=Scale.line("thin")})
end
function D.metrics()
    local w,h=Device.screen:getWidth(),Device.screen:getHeight()
    local short=math.min(w,h)
    local margin=math.floor(short*.038+.5)
    local gap=math.max(4,math.floor(short*.012+.5))
    local nav_h=math.floor(short*.078+.5)
    local status_h=math.floor(short*.043+.5)
    return {sw=w,sh=h,short=short,portrait=w<h,margin=margin,gap=gap,width=w-margin*2,
        status_h=status_h,body_y=status_h+gap,title_h=math.floor(short*.08+.5),
        nav_h=nav_h,nav_y=h-nav_h,line=Scale.line("thin")}
end
function D.status(group,m,opts)
    D.add(group,m.margin,0,D.label("觅阅",m.width*.35,m.status_h,10,{bold=true}))
    local battery_w=math.floor(m.width*.17)
    local icon_w=m.status_h
    local clock_w=math.floor(m.width*.15)
    local x=m.sw-m.margin-battery_w-icon_w-clock_w
    local clock=D.label(opts.clock_text or os.date("%H:%M"),clock_w,m.status_h,9.5,{align="right"})
    D.add(group,x,0,clock)
    D.add(group,x+clock_w,0,D.tap(icon_w,m.status_h,D.icon("wifi",icon_w,m.status_h),opts.on_device))
    local battery=D.layer(battery_w,m.status_h)
    D.add(battery,0,0,D.icon("battery",icon_w,m.status_h))
    local percent=D.label(opts.battery_text or "--%",battery_w-icon_w,m.status_h,9.5,{align="right"})
    D.add(battery,icon_w,0,percent)
    D.add(group,m.sw-m.margin-battery_w,0,D.tap(battery_w,m.status_h,battery,opts.on_device))
    D.add(group,0,m.status_h,D.line(m.sw,m.line))
    return {clock=clock[1],battery=percent[1]}
end

function D.dock(group,m,selected,on_navigate)
    local entries={{"home","首页","home"},{"book","书架","library"},{"library","书城","bookstore"},{"settings","工具","tools"}}
    local targets={}
    D.add(group,0,m.nav_y,D.line(m.sw,m.line))
    local width=math.floor(m.sw/#entries)
    for index,entry in ipairs(entries) do
        local active=selected==entry[3]
        local body=D.layer(width,m.nav_h-m.line)
        local icon_h=math.floor(m.nav_h*.52)
        D.add(body,0,0,D.icon(entry[1]..(active and "-selected" or ""),width,icon_h,math.floor(m.nav_h*.44)))
        D.add(body,0,icon_h,D.label(entry[2],width,math.floor(m.nav_h*.32),9.5,{bold=active,align="center"}))
        if active then
            local underline_w=math.floor(width*.42)
            D.add(body,math.floor((width-underline_w)/2),m.nav_h-m.line*3,D.line(underline_w,m.line*2))
        end
        local target=D.tap(width,m.nav_h-m.line,body,function() if on_navigate then on_navigate(entry[3]) end end)
        target.selected=active
        target.destination=entry[3]
        D.add(group,(index-1)*width,m.nav_y+m.line,target)
        targets[index]=target
    end
    return targets
end

function D.row(entry,w,h,callback)
    local body=D.layer(w,h)
    local icon_w=math.floor(h*.8)
    local arrow_w=math.floor(h*.5)
    D.add(body,0,0,D.icon(entry.icon_key or entry.icon or "more",icon_w,h,math.floor(h*.42)))
    local detail=entry.detail and entry.detail~=""
    local label_h=detail and math.floor(h*.59) or h
    local text_w=math.max(1,w-icon_w-arrow_w)
    D.add(body,icon_w,0,D.label(entry.label or entry.text,text_w,label_h,11,{bold=entry.primary,color=entry.enabled==false and BB.COLOR_GRAY or nil}))
    if detail then D.add(body,icon_w,label_h,D.label(entry.detail,text_w,h-label_h,8.2)) end
    D.add(body,w-arrow_w,0,D.icon("chevron-right",arrow_w,h,math.floor(h*.28)))
    D.add(body,0,h-Scale.line("thin"),D.line(w,Scale.line("thin"),BB.COLOR_GRAY))
    return D.tap(w,h,body,entry.enabled~=false and callback or nil,entry.hold_callback)
end
function D.pager(group,x,y,w,h,page,pages,on_page)
    local arrow_w=math.floor(w*.23)
    D.add(group,x,y,D.tap(arrow_w,h,D.icon("back",arrow_w,h,math.floor(h*.48)),
        page>1 and function() on_page(-1) end or nil))
    D.add(group,x+arrow_w,y,D.label(page.." / "..pages,w-arrow_w*2,h,9,{align="center"}))
    D.add(group,x+w-arrow_w,y,D.tap(arrow_w,h,D.icon("chevron-right",arrow_w,h,math.floor(h*.48)),
        page<pages and function() on_page(1) end or nil))
end

-- Full-screen child pages pause Home background paints, but are not modal
-- bubbles: opening a filter or confirmation must leave its parent page alive.
D.Page=Input:extend{_miuread_transient=true,_miuread_desktop_page=true,covers_fullscreen=true,stop_events_propagation=true}
function D.Page:init()
    self.opts=self.opts or {}
    self.key_events={Back={{Device.input.group.Back}}}
    self:_build()
end
function D.Page:_begin(selected)
    local m=D.metrics()
    self._metrics_cache=m
    self.dimen=Geom:new{x=0,y=0,w=m.sw,h=m.sh}
    local top_h=math.min(math.floor(m.sh*.14),math.max(m.body_y+m.title_h,math.floor(m.sh*.10)))
    self._top_swipe_dimen=Geom:new{x=0,y=0,w=m.sw,h=top_h}
    self.ges_events={PageSwipe={GestureRange:new{ges="swipe",range=self.dimen}}}
    local layer=D.layer(m.sw,m.sh)
    D.add(layer,0,0,D.frame(m.sw,m.sh))
    if self.opts.get_status then
        for key,value in pairs(self.opts.get_status()) do self.opts[key]=value end
    end
    self._status_refs=D.status(layer,m,self.opts)
    self._navigation_targets=D.dock(layer,m,selected,function(destination)
        if self.opts.on_navigate then self.opts.on_navigate(destination) end
    end)
    self._regions={}
    return layer,m
end
function D.Page:_finish(layer)
    local old=self[1]
    self[1]=layer
    if old and old.free then old:free() end
end
function D.Page:_close(action)
    if self._miu_closed then return true end
    self._pending_action=action
    self._restore_parent=action==nil
    UIManager:close(self)
    return true
end
function D.Page:onBack() return self:_close() end
function D.Page:_open_quick_panel_from_gesture(ges)
    if not ges or (ges.ges~="swipe" and ges.ges~="pan_release") or ges.direction~="south" then return false end
    local start=ges.start_pos or ges.pos
    if not start or not self._top_swipe_dimen or not self._top_swipe_dimen:contains(start)
        or not self.opts.on_device or not self:isTopPage() then return false end
    if self._quick_panel_pending then return true end
    self._quick_panel_pending=true
    -- Finish dispatch before showing controls, and discard a queued pull if
    -- navigation or a modal has since covered the originating page.
    UIManager:nextTick(function()
        self._quick_panel_pending=false
        if self:isTopPage() then self.opts.on_device() end
    end)
    return true
end
function D.Page:handleEvent(event)
    if event and event.handler=="onGesture"
        and self:_open_quick_panel_from_gesture(event.args and event.args[1]) then return true end
    return Input.handleEvent(self,event)
end
function D.Page:onPageSwipe(_,ges)
    if not self._change_page then return false end
    if ges.direction=="west" then return self:_change_page(1) end
    if ges.direction=="east" then return self:_change_page(-1) end
    return false
end
function D.Page:isTopPage()
    if self._miu_closed then return false end
    for index=#(UIManager._window_stack or {}),1,-1 do
        local widget=UIManager._window_stack[index].widget
        if widget and not widget.toast then return widget==self end
    end
    return false
end
function D.Page:_status_tick()
    if self._miu_closed then return end
    if self:isTopPage() and self.opts.get_status then
        local status=self.opts.get_status()
        self._status_refs.clock:setText(status.clock_text or "--:--")
        self._status_refs.battery:setText(status.battery_text or "--%")
        local m=self._metrics_cache
        UIManager:setDirty(self,function() return "ui",Geom:new{x=0,y=0,w=m.sw,h=m.status_h} end)
    end
    UIManager:scheduleIn(math.max(10,60-os.time()%60),self._status_task)
end
function D.Page:onShow()
    -- A destination replaces most of the viewport, but does not need a
    -- flashing waveform. The new page paints its dock selection in this frame.
    UIManager:setDirty(self,"ui",self.dimen)
    self._status_task=function() self:_status_tick() end
    if self.opts.get_status then UIManager:scheduleIn(math.max(10,60-os.time()%60),self._status_task) end
end
function D.Page:onCloseWidget()
    self._miu_closed=true
    if self._status_task then UIManager:unschedule(self._status_task); self._status_task=nil end
    if self.opts.on_close then self.opts.on_close(self) end
    local action=self._pending_action
    local restore_parent=self._restore_parent
    UIManager:nextTick(function()
        -- UIManager already dirties the exposed surface on close. Only an
        -- explicit Back needs a forced clearing refresh; navigation and opening
        -- a reader paint their destination and must not flash hidden pages.
        if restore_parent then UIManager:setDirty("all","full") end
        if action then action() end
    end)
end
function D.Page:updateItems()
    if self._miu_closed then return false end
    self:_build()
    if self:isTopPage() then
        local m=self._metrics_cache
        UIManager:setDirty(self,"ui",Geom:new{x=0,y=m.body_y,w=m.sw,h=m.nav_y-m.body_y})
    end
    return true
end
function D.Page:onSetDimensions()
    if self._miu_closed then return false end
    self:_build(); UIManager:setDirty(self,"full")
    return true
end
function D.Page:onScreenResize() return self:onSetDimensions() end
function D.Page:onRotation() return self:onSetDimensions() end

return D
