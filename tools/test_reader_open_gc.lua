package.path = "miuread.koplugin/?.lua;" .. package.path
local Handoff = require("miuread.reader_open_gc")
local previous_cover = package.loaded.covermenu
local tasks, collections, cleaned, opened = {}, 0, 0, 0
local ui = {_task_queue = tasks}
function ui:scheduleIn(delay, action) tasks[#tasks + 1] = {time=delay, action=action} end
function ui:unschedule(action)
    for index=#tasks,1,-1 do
        if tasks[index].action == action then table.remove(tasks,index) end
    end
end
local collect = function() collections=collections+1 end
local cover = assert(loadstring([[
local ui, collect, cleanup = ...
return {onCloseWidget=function()
    cleanup()
    ui:scheduleIn(.2, function()
        collect()
        collect()
    end)
end}
]], "@plugins/coverbrowser.koplugin/covermenu.lua"))(ui, collect, function() cleaned=cleaned+1 end)
local reader = assert(loadstring([[
local ui, collect, allocate = ...
return {showReaderCoroutine=function()
    ui:scheduleIn(0, function()
        collect()
        collect()
        allocate()
    end)
end}
]], "@frontend/apps/reader/readerui.lua"))(ui, collect, function()
    assert(collections>=2, "Native collections must finish before document allocation")
    opened=opened+1
end)
package.loaded.covermenu = cover
local function drain()
    table.sort(tasks,function(a,b) return a.time<b.time end)
    while #tasks>0 do table.remove(tasks,1).action() end
end

local finish = Handoff.prepare(ui,reader)
cover.onCloseWidget()
reader.showReaderCoroutine()
assert(finish()==1 and cleaned==1, "Teardown must remain intact while its redundant collection is coalesced")
drain()
assert(collections==2 and opened==1, "Opening must retain exactly the native collection pair")

-- A settings-archive prompt does not queue the opening coroutine yet.
finish = Handoff.prepare(ui,reader)
cover.onCloseWidget()
assert(finish()==0 and #tasks==1)
drain()
assert(collections==4 and opened==1, "Without a pending reader, menu collection must survive")

-- Earlier menu closures and unrelated scheduled work belong to their owners.
cover.onCloseWidget()
local earlier=tasks[1].action
local unrelated_ran=false
finish=Handoff.prepare(ui,reader)
cover.onCloseWidget()
ui:scheduleIn(.1,function() unrelated_ran=true end)
reader.showReaderCoroutine()
assert(finish()==1)
local retained=false
for _,task in ipairs(tasks) do if task.action==earlier then retained=true end end
assert(retained)
drain()
assert(unrelated_ran and collections==8 and opened==2)

-- Missing, wrapped or alternate implementations use the original behavior.
local native=reader.showReaderCoroutine
reader.showReaderCoroutine=function() return native() end
finish=Handoff.prepare(ui,reader)
cover.onCloseWidget();reader.showReaderCoroutine()
assert(finish()==0)
drain()
assert(collections==12 and opened==3)
package.loaded.covermenu=nil
assert(Handoff.prepare(ui,reader)()==0)
package.loaded.covermenu=previous_cover
print("Reader opening: redundant cover collection coalesced; native allocation safety, prompts and unrelated work preserved PASS")
