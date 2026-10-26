local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local D = require("miuread.desktop_ui")
local Progress = require("miuread.shelf_progress")

local Shelf = D.Page:extend{name="miuread_full_shelf",page=1,perpage=6,view_mode="list"}

local function status(book)
    local parts={book.source_label or "微信读书"}
    if book.download_active then
        parts[#parts+1]="下载中 "..tostring(math.floor(tonumber(book.download_progress) or 0)).."%"
    elseif book.local_available or book.downloaded or book.generated then
        parts[#parts+1]="已下载"
    end
    if Progress.is_finished(book) then parts[#parts+1]="已读完"
    elseif book.progress_known==false then parts[#parts+1]="进度未知"
    elseif tonumber(book.progress) then parts[#parts+1]=math.floor(tonumber(book.progress)+.5).."%"
    elseif #parts==1 then parts[#parts+1]="未下载" end
    return table.concat(parts," · ")
end

function Shelf:_notify_page()
    local first=(self.page-1)*self.perpage+1
    if self.opts.on_page_changed then
        self.opts.on_page_changed(self.page,first,math.min(#self.opts.books,first+self.perpage-1),self)
    end
end
function Shelf:_change_page(delta)
    local page=math.max(1,math.min(self.pages,self.page+delta))
    if page==self.page then return true end
    self.page=page
    self:updateItems()
    self:_notify_page()
    return true
end
function Shelf:_set_mode(mode)
    if self.view_mode==mode then return true end
    self.view_mode=mode
    if self.opts.on_view_mode then self.opts.on_view_mode(mode) end
    self:updateItems()
    return true
end
function Shelf:_book_row(book,w,h)
    local gap=math.floor(w*.028)
    local cover_h=math.floor(h*.84)
    local cover_w=self.opts.show_covers==false and 0 or math.floor(cover_h*.68)
    local arrow_w=math.floor(w*.045)
    local tx=cover_w+gap
    local tw=w-tx-arrow_w
    local body=D.layer(w,h)
    if cover_w>0 then D.add(body,0,math.floor((h-cover_h)/2),D.cover(book,cover_w,cover_h)) end
    D.add(body,tx,math.floor(h*.08),D.label(book.title or "未命名",tw,math.floor(h*.31),11.8,{bold=true}))
    D.add(body,tx,math.floor(h*.39),D.label(book.author,tw,math.floor(h*.25),9.3))
    D.add(body,tx,math.floor(h*.64),D.label(status(book),tw,math.floor(h*.25),8.8))
    D.add(body,w-arrow_w,0,D.icon("chevron-right",arrow_w,h,math.floor(h*.22)))
    D.add(body,0,h-2,D.line(w,2,BB.COLOR_GRAY))
    return D.tap(w,h,body,function(anchor,ges) if self.opts.on_select then self.opts.on_select(book,anchor,ges) end end)
end
function Shelf:_book_card(book,w,h)
    local body=D.layer(w,h)
    local cover_h=math.floor(h*.75)
    local cover_w=math.min(math.floor(w*.78),math.floor(cover_h*.68))
    D.add(body,math.floor((w-cover_w)/2),0,D.cover(book,cover_w,cover_h,self.opts.show_covers))
    D.add(body,0,cover_h,D.label(book.title or "未命名",w,math.floor(h*.13),10.5,{bold=true,align="center"}))
    D.add(body,0,math.floor(h*.88),D.label(status(book),w,math.floor(h*.12),8,{align="center"}))
    return D.tap(w,h,body,function(anchor,ges) if self.opts.on_select then self.opts.on_select(book,anchor,ges) end end)
end
function Shelf:_build()
    self.opts.books=self.opts.books or {}
    self.page=math.max(1,math.min(tonumber(self.page) or 1,math.max(1,math.ceil(#self.opts.books/self.perpage))))
    self.pages=math.max(1,math.ceil(#self.opts.books/self.perpage))
    self.view_mode=self.opts.view_mode or self.view_mode
    self.opts.view_mode=nil
    local layer,m=self:_begin("library")
    local x,y,w=m.margin,m.body_y,m.width
    local mode_w=math.floor(w*.09)
    local count_w=math.floor(w*.17)
    local title=D.label(self.opts.title or "书架",w-mode_w*3-count_w-m.gap,m.title_h,20,{bold=true})
    D.add(layer,x,y,title)
    D.add(layer,x+title[1]:getSize().w+m.gap,y,D.label(tostring(#self.opts.books).." 本",count_w,m.title_h,10.5))
    if self.opts.on_right_action then
        D.add(layer,x+w-mode_w*3,y,D.tap(mode_w,m.title_h,D.icon("more",mode_w,m.title_h,math.floor(m.title_h*.4)),self.opts.on_right_action))
    end
    D.add(layer,x+w-mode_w*2,y,D.tap(mode_w,m.title_h,D.icon("menu",mode_w,m.title_h,math.floor(m.title_h*.4)),function() self:_set_mode("list") end))
    D.add(layer,x+w-mode_w,y,D.tap(mode_w,m.title_h,D.icon("grid",mode_w,m.title_h,math.floor(m.title_h*.4)),function() self:_set_mode("grid") end))
    local selected_x=x+w-mode_w*(self.view_mode=="list" and 2 or 1)
    D.add(layer,selected_x,y+m.title_h-m.line*2,D.line(mode_w,m.line*2))
    y=y+m.title_h+m.gap
    if self.opts.show_actions then
        local search_h=math.floor(m.short*.065)
        local search=D.layer(w,search_h)
        local icon_w=search_h
        D.add(search,0,0,D.icon("search",icon_w,search_h,math.floor(search_h*.4)))
        D.add(search,icon_w,0,D.label("搜索书名、作者",w-icon_w,search_h,10))
        self._search_target=D.tap(w,search_h,D.frame(w,search_h,search,{border=m.line,radius=m.gap/2}),self.opts.on_left_action)
        D.add(layer,x,y,self._search_target)
        y=y+search_h+m.gap
        local filter_h=math.floor(m.short*.052)
        D.add(layer,x,y,D.tap(math.floor(w/2),filter_h,D.label((self.opts.source_label or "全部来源").." ▾",math.floor(w/2),filter_h,10),self.opts.on_source or self.opts.on_right_action))
        D.add(layer,x+math.floor(w/2),y,D.tap(math.ceil(w/2),filter_h,D.label((self.opts.sort_label or "最近阅读").." ▾",math.ceil(w/2),filter_h,10,{align="right"}),self.opts.on_sort or self.opts.on_right_action))
        y=y+filter_h
        local tabs=self.opts.status_tabs or {}
        self._status_targets={}
        for index,tab in ipairs(tabs) do
            local tw=math.floor(w/#tabs)
            local body=D.layer(tw,filter_h)
            D.add(body,0,0,D.label(tab.label,tw,filter_h,10,{bold=tab.selected,align="center"}))
            if tab.selected then D.add(body,0,filter_h-m.line*2,D.line(tw,m.line*2)) end
            self._status_targets[index]=D.tap(tw,filter_h,body,tab.callback)
            D.add(layer,x+(index-1)*tw,y,self._status_targets[index])
        end
        if #tabs>0 then y=y+filter_h end
        y=y+m.gap
    end
    local footer_h=math.floor(m.short*.036)
    local bottom=m.nav_y-m.gap-footer_h
    local available=math.max(1,bottom-y)
    self._book_targets={}
    self._book_regions={}
    self.item_table={}
    local first=(self.page-1)*self.perpage+1
    for index=first,math.min(#self.opts.books,first+self.perpage-1) do
        local slot=index-first
        local bx,by,bw,bh=x,y+slot*math.floor(available/6),w,math.floor(available/6)
        if self.view_mode=="grid" then
            local cols=m.portrait and 3 or 6
            local rows=m.portrait and 2 or 1
            bw=math.floor((w-m.gap*(cols-1))/cols)
            bh=math.floor((available-m.gap*(rows-1))/rows)
            bx=x+(slot%cols)*(bw+m.gap)
            by=y+math.floor(slot/cols)*(bh+m.gap)
        end
        local book=self.opts.books[index]
        self.item_table[#self.item_table+1]={book_id=book.bookId or book.book_id,cover_path=book.cover_path}
        local card=self.view_mode=="grid" and self:_book_card(book,bw,bh) or self:_book_row(book,bw,bh)
        self._book_targets[#self._book_targets+1]=card
        self._book_regions[#self._book_regions+1]=Geom:new{x=bx,y=by,w=bw,h=bh}
        D.add(layer,bx,by,card)
    end
    if #self.opts.books==0 then
        D.add(layer,x,y,D.label("没有符合条件的书籍",w,available,11,{align="center"}))
    end
    D.pager(layer,x,bottom,w,footer_h,self.page,self.pages,function(delta) self:_change_page(delta) end)
    self:_finish(layer)
end
function Shelf:onShow()
    D.Page.onShow(self)
    self:_notify_page()
    if self.opts.on_rendered then UIManager:nextTick(function() if not self._miu_closed then self.opts.on_rendered(self) end end) end
end

local M={}
function M.show(opts)
    local view=Shelf:new{opts=opts or {},page=tonumber(opts and opts.page) or 1}
    UIManager:show(view)
    return view
end
return M
