local BB = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local D = require("miuread.desktop_ui")
local Slider = require("miuread.control_slider")

local Tools = D.Page:extend{name="miuread_tools"}
function Tools:_controls_armed()
    if self._miu_closed then return false end
    for index=#(UIManager._window_stack or {}),1,-1 do
        local widget=UIManager._window_stack[index].widget
        if widget and not widget.toast then return widget==self end
    end
    return false
end
function Tools:_slider(control,w,h)
    local value_w=math.floor(w*.13)
    return Slider:new{dimen=require("ui/geometry"):new{w=w,h=h},bar_w=w-value_w-math.floor(w*.06),
        value_w=value_w,value_gap=math.floor(w*.06),min=control.min,max=control.max,
        value=control.get_value and control.get_value() or control.value,on_change=control.on_set,owner=self}
end
function Tools:_build()
    local layer,m=self:_begin("tools")
    local x,y,w=m.margin,m.body_y,m.width
    D.add(layer,x,y,D.label("工具",w,m.title_h,20,{bold=true}))
    y=y+m.title_h+m.gap
    local available=m.nav_y-m.gap-y
    local frontlight=self.opts.frontlight
    local control_count=1+(frontlight and 1 or 0)+(frontlight and frontlight.warmth and 1 or 0)
    local panel_h=math.floor(available*(control_count==3 and .34 or (control_count==2 and .27 or .18)))
    local panel_pad=m.gap*2
    local inner_w=w-panel_pad*2
    local heading_h=math.floor(panel_h*.20)
    local control_h=math.floor((panel_h-heading_h-m.gap)/control_count)
    local panel=D.layer(w-m.line*2,panel_h-m.line*2)
    D.add(panel,panel_pad,0,D.tap(inner_w,heading_h,D.label("设备控制  ›",inner_w,heading_h,11,{bold=true}),self.opts.on_device))
    local cy=heading_h
    local label_w=math.floor(inner_w*.40)
    local icon_w=math.floor(control_h*.70)
    local controls={}
    local function label(icon,text,yy,callback)
        local body=D.layer(label_w,control_h)
        D.add(body,0,0,D.icon(icon,icon_w,control_h,math.floor(control_h*.36)))
        D.add(body,icon_w,0,D.label(text,label_w-icon_w,control_h,11))
        D.add(panel,panel_pad,yy,D.tap(label_w,control_h,body,callback))
    end
    label("wifi","Wi-Fi",cy,self.opts.on_wifi)
    local wifi_w=inner_w-label_w
    local wifi=D.layer(wifi_w,control_h)
    D.add(wifi,0,0,D.label(self.opts.wifi_name or "Wi-Fi",wifi_w,math.floor(control_h*.6),9.5,{align="right"}))
    D.add(wifi,0,math.floor(control_h*.6),D.label(self.opts.wifi_status or "",wifi_w,math.floor(control_h*.4),8.2,{align="right"}))
    self._wifi_target=D.tap(wifi_w,control_h,wifi,self.opts.on_wifi)
    D.add(panel,panel_pad+label_w,cy,self._wifi_target)
    cy=cy+control_h
    if frontlight then
        D.add(panel,panel_pad,cy,D.line(inner_w,m.line,BB.COLOR_GRAY))
        label("frontlight","亮度",cy,function()
            if frontlight.on_toggle then frontlight.on_toggle(); self:updateItems() end
        end)
        controls.brightness=self:_slider(frontlight.brightness,inner_w-label_w,control_h)
        D.add(panel,panel_pad+label_w,cy,controls.brightness)
        cy=cy+control_h
        if frontlight.warmth then
            D.add(panel,panel_pad,cy,D.line(inner_w,m.line,BB.COLOR_GRAY))
            label("warmth","暖光",cy,self.opts.on_device)
            controls.warmth=self:_slider(frontlight.warmth,inner_w-label_w,control_h)
            D.add(panel,panel_pad+label_w,cy,controls.warmth)
        end
    end
    self._sliders=controls
    D.add(layer,x,y,D.frame(w,panel_h,panel,{border=m.line,radius=m.gap/2}))
    y=y+panel_h+m.gap*2
    local tile_h=math.floor(available*.13)
    local tile_w=math.floor((w-m.gap)/2)
    self._tile_targets={}
    for index,entry in ipairs({self.opts.sync,self.opts.downloads}) do
        local body=D.layer(tile_w-m.line*2,tile_h-m.line*2)
        local icon_w=math.floor(tile_w*.3)
        D.add(body,0,0,D.icon(entry.icon,icon_w,tile_h,math.floor(tile_h*.4)))
        D.add(body,icon_w,math.floor(tile_h*.12),D.label(entry.label,tile_w-icon_w-m.gap,math.floor(tile_h*.43),13,{bold=true}))
        D.add(body,icon_w,math.floor(tile_h*.55),D.label(entry.detail,tile_w-icon_w-m.gap,math.floor(tile_h*.32),8.7))
        local target=D.tap(tile_w,tile_h,D.frame(tile_w,tile_h,body,{border=m.line,radius=m.gap/2}),entry.callback,entry.hold_callback)
        self._tile_targets[index]=target
        D.add(layer,x+(index-1)*(tile_w+m.gap),y,target)
    end
    y=y+tile_h+m.gap
    local heading_h2=math.floor(available*.055)
    D.add(layer,x,y,D.label("阅读与管理",w,heading_h2,11,{bold=true}))
    y=y+heading_h2
    local rows=self.opts.rows or {}
    local row_h=math.floor((m.nav_y-m.gap-y)/math.max(1,#rows))
    self._row_targets={}
    self._row_regions={}
    for index,entry in ipairs(rows) do
        local target=D.row(entry,w,row_h,entry.callback)
        D.add(layer,x,y,target)
        self._row_targets[index]=target
        self._row_regions[index]={x=x,y=y,w=w,h=row_h}
        y=y+row_h
    end
    self:_finish(layer)
end
local M={}
function M.show(opts)
    local view=Tools:new{opts=opts or {}}
    UIManager:show(view)
    return view
end
return M
