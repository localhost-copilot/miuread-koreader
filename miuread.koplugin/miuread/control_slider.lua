-- Shared by the quick panel and full-screen device controls.
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local UiScale = require("miuread.ui_scale")
local logger = require("logger")
local function face(...) return UiScale.face(...) end

local ControlSlider = InputContainer:extend{
    dimen=nil, bar_w=1, value_w=1, value_gap=0,
    min=0, max=100, value=0, on_change=nil, owner=nil, enabled=true,
    slide_dimen=nil, value_text=nil, last_refresh=0,
}
function ControlSlider:init()
    self.dimen=self.dimen or Geom:new{w=1,h=1}
    self.min=tonumber(self.min) or 0
    self.max=tonumber(self.max) or self.min+1
    if self.max<=self.min then self.max=self.min+1 end
    self.value=math.max(self.min,math.min(self.max,tonumber(self.value) or self.min))
    self.slide_dimen=Geom:new{x=0,y=0,w=math.max(1,self.bar_w),h=self.dimen.h}
    self.ges_events={
        TapSlide={GestureRange:new{ges="tap",range=self.slide_dimen}},
        PanSlide={GestureRange:new{ges="pan",range=self.slide_dimen}},
    }
    self.value_text=TextWidget:new{
        text=tostring(math.floor(self.value+.5)),
        face=face("smallinfofont",9.4,12.8,8.2),bold=true,
        fgcolor=Blitbuffer.COLOR_BLACK,
    }
end
function ControlSlider:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function ControlSlider:_armed()
    return self.enabled~=false and self.owner and type(self.owner._controls_armed)=="function" and self.owner:_controls_armed()
end
function ControlSlider:_ratio()
    return math.max(0,math.min(1,(self.value-self.min)/math.max(1,self.max-self.min)))
end
function ControlSlider:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    self.slide_dimen.x,self.slide_dimen.y=x,y
    local track_h=math.max(UiScale.line("medium"),UiScale.dp(4,3,6))
    local marker=UiScale.dp(12,10,16)
    local bar_y=y+math.floor((self.dimen.h-track_h)/2)
    local ratio=self:_ratio()
    local fill_w=math.max(track_h,math.floor(self.bar_w*ratio))
    local marker_x=x+math.floor((self.bar_w-marker)*ratio)
    local active=self.enabled~=false
    local fill_color=active and Blitbuffer.COLOR_BLACK or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY)
    local marker_color=active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    bb:paintRect(x,bar_y,self.bar_w,track_h,Blitbuffer.COLOR_GRAY)
    bb:paintRect(x,bar_y,math.min(self.bar_w,fill_w),track_h,fill_color)
    local center_x=marker_x+math.floor(marker/2)
    local center_y=y+math.floor(self.dimen.h/2)
    bb:paintCircle(center_x,center_y,math.floor(marker/2),Blitbuffer.COLOR_WHITE)
    bb:paintCircle(center_x,center_y,math.floor(marker/2),marker_color,UiScale.line("thin"))
    local size=self.value_text:getSize()
    self.value_text:paintTo(bb,x+self.bar_w+self.value_gap+math.floor((self.value_w-size.w)/2),y+math.floor((self.dimen.h-size.h)/2))
end
function ControlSlider:_set_from_position(ges,force)
    if not self:_armed() then return true end
    local pos=ges and ges.pos
    if not pos then return false end
    local ratio=math.max(0,math.min(1,(pos.x-self.dimen.x)/math.max(1,self.bar_w)))
    local target=math.floor(self.min+ratio*(self.max-self.min)+.5)
    local actual=target
    if self.on_change then
        local ok,result=pcall(self.on_change,target,force and "commit" or "drag")
        if not ok then logger.warn("[MiuRead][QuickPanel] frontlight slider failed",tostring(result)); return true end
        if result==false then return true end
        if tonumber(result) then actual=tonumber(result) end
    end
    self.value=math.max(self.min,math.min(self.max,actual))
    self.value_text:setText(tostring(math.floor(self.value+.5)))
    local interval=Screen.low_pan_rate and .10 or .04
    if force or os.clock()-(tonumber(self.last_refresh) or 0)>=interval then
        self.last_refresh=os.clock()
        UIManager:setDirty(self.owner,function() return "ui",self.dimen end)
    end
    return true
end
function ControlSlider:onTapSlide(_,ges) return self:_set_from_position(ges,true) end
function ControlSlider:onPanSlide(_,ges)
    if not self:_armed() then return true end
    local direction=tostring(ges and ges.direction or "")
    local horizontal=direction=="east" or direction=="west"
    local relative=ges and ges.relative
    if not horizontal and relative then
        local dx=math.abs(tonumber(relative.x) or 0)
        local dy=math.abs(tonumber(relative.y) or 0)
        horizontal=dx>=UiScale.dp(8,6,12) and dx>dy*1.25
    end
    if not horizontal then return true end
    return self:_set_from_position(ges,false)
end


return ControlSlider
