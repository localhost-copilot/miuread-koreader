-- Exercise durable state at worker/observer boundaries, without network or UI.
package.path="miuread.koplugin/?.lua;"..package.path
package.preload["libs/libkoreader-lfs"]=function() return {} end
local U=require("miuread.util")
local noop=function() end
for _,name in ipairs({"ui/event","ui/uimanager","ffi/util","miuread.json",
    "miuread.read_report_service","miuread.protocol","miuread.legacy_adapter_worker",
    "miuread.book_integrity","miuread.precise_position","miuread.source_position",
    "miuread.digests","miuread.subprocess_hygiene"}) do
    package.preload[name]=function() return {} end
end
package.preload["logger"]=function() return {info=noop,warn=noop} end
package.preload["miuread.http"]=function() return {is_auth_error=function() return false end} end
local Sync=require("miuread.sync")
local function store()
    local s={memory={},disk={},writes=0,identity={login_session_id="login",account={vid="account"}}}
    function s:session(id) return self.memory[id] end
    function s:auth() return U.copy(self.identity) end
    function s:reload() self.memory=U.copy(self.disk) end
    function s:save_session(id,patch,flush)
        self.memory[id]=U.merge(self.memory[id] or {},patch)
        if flush~=false then self.writes=self.writes+1;self.disk=U.copy(self.memory) end
        return self.memory[id],true
    end
    return s
end
local position={progress=25,chapter_uid="chapter",offset=123,safe=true}
local function upload_case(value,options)
    local s=store()
    local record={book={book_id="book",title="Test"},path="test.epub"}
    local worker,observed
    local sync=setmetatable({store=s,host={},record_generation=1,session_uploads=0,
        async={run=function(_,_,_,done) worker=done;return true end}},Sync)
    function sync:record() return record end
    function sync:_core_map_hash() return "hash" end
    function sync:_decorate_legacy_context() end
    function sync:_save_local_snapshot(id,p) self.store:save_session(id,{snapshot=U.copy(p)}) end
    function sync:_record_report_issue(_,kind) self.issue=kind end
    function sync:_normalize_report_error_kind(kind) return kind end
    assert(sync:upload(10,function(ok)
        observed={ok=ok,disk=U.copy(s.disk.book),writes=s.writes}
    end,U.merge({position_override=position,progress_only=true,transactional_context=true},options)))
    assert(s.disk.book.snapshot.offset==123,"pre-dispatch snapshot is not durable")
    local before=s.writes
    worker({ok=true,value=U.merge({position=position,path="progress",response={succ=1},
        response_summary="result",meta={code=200,length=10},payload_public={ci="chapter"}},value)})
    return observed,s,sync,s.writes-before
end
for _,options in ipairs({{}, {progress_only=false,transactional_context=false}}) do
    local seen,s,sync,writes=upload_case({accepted=true},options)
    assert(writes==1,"confirmed worker result rewrote settings before its final state")
    assert(seen.ok and seen.disk.last_attempts==0 and seen.disk.last_http_code==200
        and seen.disk.last_stage=="兼容上传链路已确认","callback lost durable diagnostics")
    assert(seen.disk.local_percent==25 and seen.disk.last_error==false)
    if options.progress_only==false then
        assert(sync.session_uploads==1 and seen.disk.last_upload,"time-report success was lost")
        assert(seen.disk.legacy_report_context.book_id=="book")
    else assert(seen.disk.progress_upload_state=="submitted") end
end
local seen,s,sync=upload_case({accepted=false,error_kind="transport",error="failed"})
assert(not seen.ok and sync.issue=="transport" and seen.disk.last_http_code==200
    and seen.disk.last_error,"rejected result lost recovery diagnostics")
seen,s,sync=upload_case({accepted=false,uncertain=true,error_kind="unconfirmed"})
assert(seen.ok and sync.issue=="unconfirmed" and seen.disk.progress_upload_state=="unconfirmed",
    "uncertain progress result skipped cloud-readback recovery")

local f=assert(io.open("miuread.koplugin/main.lua","rb"));local source=f:read("*a");f:close()
local Plugin={}
local env=setmetatable({Plugin=Plugin,U=U,logger=require("logger")},{__index=_G})
for _,name in ipairs({"_prepare_progress_snapshot","_progress_snapshot_current",
    "_save_pending_progress","_save_progress_state","_submit_progress_snapshot"}) do
    local start=assert(source:find("function Plugin:"..name.."(",1,true))
    local finish=assert(source:find("\nfunction Plugin:",start+1,true))
    local chunk=assert(loadstring(source:sub(start,finish-1)));setfenv(chunk,env);chunk()
end
local s=store()
local upload,verify,accepted=false,false,false
local p=setmetatable({store=s,sync={upload_progress=function(_,done) upload=done;return true end}}, {__index=Plugin})
function p:_persisted_sessions() return s.memory end
function p:_normalize_exact_progress_snapshot(value) return value end
function p:_progress_write_fence() return false end
function p:_invalidate_home_sync_status() end
function p:_verify_progress_submission(_,_,_,done) verify=done;return true end
local options={nonblocking_verify=true,accepted_callback=function()
    accepted=true
    local saved=s.disk.book
    assert(saved.pending_progress.offset==123 and saved.pending_progress.submitted_at,
        "accepted observer ran before the immutable pending snapshot was durable")
    assert(saved.progress_sync_state=="submitted" and saved.progress_upload_state=="submitted"
        and saved.progress_worker_active==false
        and saved.progress_submission_phase=="submitted_unverified"
        and saved.progress_sync_message=="阅读进度已提交，等待微信确认")
end}
assert(p:_submit_progress_snapshot("book",U.copy(position),options,noop))
assert(upload and s.disk.book.pending_progress and not s.disk.book.pending_progress.submitted_at,
    "unsent position must be durable before dispatch")
local before=s.writes
upload(true,{succ=1})
assert(accepted and verify and s.writes-before==2,
    "acceptance should commit once, then commit the distinct verification state")
assert(s.disk.book.progress_sync_state=="verifying_upload")
local newer=s.disk.book.progress_latest_sequence+1
s:save_session("book",{progress_latest_sequence=newer,pending_progress={progress_sequence=newer,offset=999}})
before=s.writes
assert(not p:_save_pending_progress("book",{progress_sequence=newer-1,offset=1},"stale","submitted"))
assert(s.writes==before and s.disk.book.pending_progress.offset==999,"stale result replaced a newer pending transaction")
print("Progress persistence: confirmed result, durable observers, rejection, uncertainty and stale snapshots PASS")
