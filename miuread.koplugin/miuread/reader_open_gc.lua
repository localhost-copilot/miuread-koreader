-- CoverBrowser and DocumentRegistry both schedule a pair of full collections
-- during the same FileManager -> Reader transition. Keep DocumentRegistry's
-- collections, which run after teardown and immediately before allocation.
local ReaderOpenGC = {}

local function definition(callback, suffix)
    if type(callback) ~= "function" or not (debug and debug.getinfo) then return nil end
    local info = debug.getinfo(callback, "S")
    if not info or info.what ~= "Lua" or info.linedefined <= 0
        or not info.source:match(suffix) then return nil end
    return info
end

local function defined_inside(callback, parent)
    if type(callback) ~= "function" then return false end
    local info = debug.getinfo(callback, "S")
    return info and info.what == "Lua" and info.source == parent.source
        and info.linedefined > parent.linedefined
        and info.lastlinedefined < parent.lastlinedefined
end

--- Capture this handoff before calling ReaderUI:showReader(). The returned
-- callback only removes newly queued CoverMenu close callbacks if the native
-- reader-opening coroutine has actually been queued. Archive confirmations,
-- other menus and unknown/wrapped native implementations retain their tasks.
function ReaderOpenGC.prepare(ui, reader)
    local cover = package.loaded.covermenu
    local close = type(cover) == "table" and definition(cover.onCloseWidget,
        "/coverbrowser%.koplugin/covermenu%.lua$")
    local opening = reader and definition(reader.showReaderCoroutine, "/apps/reader/readerui%.lua$")
    if not close or not opening or type(ui._task_queue) ~= "table"
        or type(ui.unschedule) ~= "function" then return function() return 0 end end

    local previous = {}
    for _, task in ipairs(ui._task_queue) do previous[task.action] = true end
    return function()
        local reader_queued = false
        local redundant = {}
        for _, task in ipairs(ui._task_queue or {}) do
            if not previous[task.action] then
                if defined_inside(task.action, opening) then reader_queued = true end
                if defined_inside(task.action, close) then redundant[#redundant + 1] = task.action end
            end
        end
        if not reader_queued then return 0 end
        for _, callback in ipairs(redundant) do ui:unschedule(callback) end
        return #redundant
    end
end

return ReaderOpenGC
