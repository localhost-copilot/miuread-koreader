local UIManager=require("ui/uimanager")
local D=require("miuread.desktop_ui")

local StorePage=D.Page:extend{name="miuread_bookstore",page=1,perpage=6}
function StorePage:onBack() return self:_close(self.opts.on_back) end
function StorePage:_change_page(delta)
    local page=math.max(1,math.min(self.pages,self.page+delta))
    if page==self.page then return true end
    self.page=page
    return self:updateItems()
end
function StorePage:_build()
    local layer,m=self:_begin("bookstore")
    local x,y,w=m.margin,m.body_y,m.width
    local back_w=self.opts.on_back and math.floor(m.title_h*.7) or 0
    if back_w>0 then
        self._back_target=D.tap(back_w,m.title_h,D.icon("back",back_w,m.title_h,math.floor(m.title_h*.38)),function() self:onBack() end)
        D.add(layer,x,y,self._back_target)
    end
    local action_w=self.opts.on_refresh and m.title_h or 0
    D.add(layer,x+back_w,y,D.label(self.opts.title or "书城",w-back_w-action_w,m.title_h,20,{bold=true}))
    if action_w>0 then
        self._refresh_target=D.tap(action_w,m.title_h,D.icon("refresh",action_w,m.title_h,math.floor(m.title_h*.4)),self.opts.on_refresh)
        D.add(layer,x+w-action_w,y,self._refresh_target)
    end
    y=y+m.title_h+m.gap
    local search_h=math.floor(m.short*.065)
    local search=D.layer(w,search_h)
    D.add(search,0,0,D.icon("search",search_h,search_h,math.floor(search_h*.4)))
    D.add(search,search_h,0,D.label("搜索微信读书 · 书名、作者",w-search_h,search_h,10))
    self._search_target=D.tap(w,search_h,D.frame(w,search_h,search,{border=m.line,radius=m.gap/2}),self.opts.on_search)
    D.add(layer,x,y,self._search_target)
    y=y+search_h+m.gap*2
    local rows=self.opts.rows or {}
    self.pages=math.max(1,math.ceil(#rows/self.perpage))
    self.page=math.max(1,math.min(self.pages,self.page))
    local footer_h=math.floor(m.short*.036)
    local bottom=m.nav_y-m.gap-footer_h
    self._row_targets={};self._row_regions={}
    if self.opts.landing then
        local hero_h=math.floor((bottom-y)*.29)
        local first=rows[1]
        if first then
            local body=D.layer(w-m.line*2,hero_h-m.line*2)
            local pad=m.gap*2
            D.add(body,pad,0,D.label("发现下一本好书",w-pad*2,math.floor(hero_h*.31),10))
            D.add(body,pad,math.floor(hero_h*.30),D.label(first.text,w-pad*2,math.floor(hero_h*.35),19,{bold=true}))
            D.add(body,pad,math.floor(hero_h*.65),D.label(first.post_text,w-pad*2,math.floor(hero_h*.25),9))
            self._row_targets[1]=D.tap(w,hero_h,D.frame(w,hero_h,body,{border=m.line,radius=m.gap/2}),first.callback)
            self._row_regions[1]={x=x,y=y,w=w,h=hero_h}
            D.add(layer,x,y,self._row_targets[1])
            y=y+hero_h+m.gap*2
        end
    end
    local first=self.opts.landing and 2 or (self.page-1)*self.perpage+1
    local last=self.opts.landing and #rows or math.min(#rows,first+self.perpage-1)
    local row_h=math.floor((bottom-y)/math.max(self.opts.landing and 3 or self.perpage,last-first+1))
    for index=first,last do
        local row=rows[index]
        local target=D.row({text=row.text,detail=row.post_text,icon=row.icon or "library",enabled=row.enabled},w,row_h,row.callback)
        self._row_targets[#self._row_targets+1]=target
        self._row_regions[#self._row_regions+1]={x=x,y=y,w=w,h=row_h}
        D.add(layer,x,y,target);y=y+row_h
    end
    if #rows==0 then D.add(layer,x,y,D.label("暂时没有可用分类",w,bottom-y,11,{align="center"})) end
    if not self.opts.landing then D.pager(layer,x,bottom,w,footer_h,self.page,self.pages,function(delta) self:_change_page(delta) end) end
    self:_finish(layer)
end
local M={}
function M.show(opts)
    local view=StorePage:new{opts=opts or {}}
    UIManager:show(view)
    return view
end
return M
