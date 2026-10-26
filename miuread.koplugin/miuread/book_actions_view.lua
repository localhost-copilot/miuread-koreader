local BB = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local D = require("miuread.desktop_ui")
local Progress = require("miuread.shelf_progress")

local BookPage = D.Page:extend{name="miuread_book_actions",page=1}
function BookPage:_change_page(delta)
    local page=math.max(1,math.min(self.pages,self.page+delta))
    if page==self.page then return true end
    self.page=page
    return self:updateItems()
end
function BookPage:_run(action)
    if action.enabled==false then return end
    -- Reading retires the page before ReaderUI takes ownership. Other actions
    -- open their existing dialog above this page, preserving the return path.
    if action.primary then return self:_close(action.callback) end
    if action.callback then action.callback() end
end
function BookPage:_build()
    local layer,m=self:_begin("library")
    local book=self.opts.book or {}
    local primary,danger
    local rows={}
    for _,action in ipairs(self.opts.actions or {}) do
        if action.primary then primary=action
        elseif action.danger then danger=action
        else rows[#rows+1]=action end
    end
    if not primary and rows[1] then primary=table.remove(rows,1) end
    self.pages=math.max(1,math.ceil(#rows/6))
    self.page=math.max(1,math.min(self.pages,self.page))
    local x,y,w=m.margin,m.body_y,m.width
    local back_w=math.floor(m.title_h*.7)
    self._back_target=D.tap(back_w,m.title_h,D.icon("back",back_w,m.title_h,math.floor(m.title_h*.38)),function() self:_close() end)
    D.add(layer,x,y,self._back_target)
    D.add(layer,x+back_w,y,D.label("书籍操作",w-back_w,m.title_h,17,{bold=true}))
    y=y+m.title_h+m.gap
    local available=m.nav_y-m.gap-y
    local summary_h=math.floor(available*.25)
    local cover_h=summary_h-m.gap
    local cover_w=math.floor(cover_h*.68)
    D.add(layer,x,y,D.cover(book,cover_w,cover_h))
    local tx=x+cover_w+m.gap*2
    local tw=w-cover_w-m.gap*2
    local badge_h=math.floor(summary_h*.14)
    local badge_w=math.min(math.floor(tw*.4),math.floor(m.short*.16))
    D.add(layer,tx,y,D.frame(badge_w,badge_h,D.label(self.opts.source_label or "微信读书",badge_w-m.line*4,badge_h-m.line*2,8.5,{align="center"}),{border=m.line}))
    D.add(layer,tx,y+math.floor(summary_h*.17),D.label(book.title or "未命名",tw,math.floor(summary_h*.27),19,{bold=true}))
    D.add(layer,tx,y+math.floor(summary_h*.44),D.label(book.author,tw,math.floor(summary_h*.18),11))
    D.add(layer,tx,y+math.floor(summary_h*.62),D.label(self.opts.availability_text or "",tw,math.floor(summary_h*.15),9))
    local known=tonumber(book.progress) and book.progress_known~=false
    local progress=math.max(0,math.min(100,tonumber(book.progress) or 0))
    local progress_text=Progress.is_finished(book) and "已读完" or (known and "已读 "..math.floor(progress+.5).."%" or "进度未知")
    D.add(layer,tx,y+math.floor(summary_h*.77),D.label(progress_text,tw,math.floor(summary_h*.17),9))
    local track_y=y+summary_h-m.gap
    D.add(layer,tx,track_y,D.line(tw,math.max(3,m.line*2),BB.COLOR_GRAY))
    if known and progress>0 then D.add(layer,tx,track_y,D.line(math.max(1,math.floor(tw*progress/100)),math.max(3,m.line*2))) end
    y=y+summary_h+m.gap
    local button_h=math.floor(math.min(m.short*.075,available*.085))
    if primary then
        self._primary_target=D.button(primary.desktop_label or (primary.primary and "继续阅读  ›") or primary.label,w,button_h,
            primary.enabled~=false and function() self:_run(primary) end or nil,true)
        D.add(layer,x,y,self._primary_target)
        y=y+button_h+m.gap
    end
    local footer_h=self.pages>1 and math.floor(m.short*.036) or 0
    local danger_h=danger and math.floor(m.short*.062) or 0
    local caption_h=danger and math.floor(m.short*.03) or 0
    local bottom=m.nav_y-m.gap-danger_h-caption_h-footer_h
    local visible={}
    for index=(self.page-1)*6+1,math.min(#rows,self.page*6) do visible[#visible+1]=rows[index] end
    local heading_h=math.floor(m.short*.036)
    local group_count=0
    local last_group
    for _,action in ipairs(visible) do
        local group=action.group or "more"
        if group~=last_group then group_count=group_count+1; last_group=group end
    end
    local row_h=math.max(1,math.min(math.floor(m.short*.083),math.floor((bottom-y-heading_h*group_count)/math.max(1,#visible))))
    self._action_targets={}
    self._action_regions={}
    last_group=nil
    for _,action in ipairs(visible) do
        local group=action.group or "more"
        if group~=last_group then
            D.add(layer,x,y,D.label(group=="download" and "下载与本机内容" or "更多操作",w,heading_h,9.5,{bold=true}))
            y=y+heading_h; last_group=group
        end
        local display={label=action.desktop_label or action.label,detail=action.detail,icon=action.icon,enabled=action.enabled}
        local target=D.row(display,w,row_h,function() self:_run(action) end)
        D.add(layer,x,y,target)
        self._action_targets[#self._action_targets+1]=target
        self._action_regions[#self._action_regions+1]={x=x,y=y,w=w,h=row_h}
        y=y+row_h
    end
    if self.pages>1 then D.pager(layer,x,bottom,w,footer_h,self.page,self.pages,function(delta) self:_change_page(delta) end) end
    self._danger_target=nil
    if danger then
        local dy=m.nav_y-m.gap-danger_h-caption_h
        self._danger_target=D.button(danger.label,w,danger_h,function() self:_run(danger) end)
        D.add(layer,x,dy,self._danger_target)
        D.add(layer,x,dy+danger_h,D.label("保留本机文件，操作前确认",w,caption_h,8,{align="center"}))
    end
    self:_finish(layer)
end
local M={}
function M.show(opts)
    local view=BookPage:new{opts=opts or {}}
    UIManager:show(view)
    return view
end
return M
