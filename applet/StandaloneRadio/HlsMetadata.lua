-- Long-poll transport and decoder-clock scheduling are independent. Only a
-- future metadata event owns a decoder timer; an idle stream holds one request.
local pairs, pcall, setmetatable, tonumber, type = pairs, pcall, setmetatable, tonumber, type
local string = require("string")
local table = require("table")
local math = require("math")
local json = require("json")
local RequestHttp = require("jive.net.RequestHttp")
local SocketHttp = require("jive.net.SocketHttp")
local Timer = require("jive.ui.Timer")
local jnt = jnt
module(...)
local Client = {}
Client.__index = Client

function new(options)
    options=options or {}
    local wait=tonumber(options.waitSeconds) or 25
    if wait~=wait then wait=25 end
    wait=math.floor(math.max(1,math.min(30,wait)))
    return setmetatable({options=options, serial=0, waitSeconds=wait}, Client)
end

function Client:stop()
    self.serial = self.serial + 1
    if self.timer then self.timer:stop(); self.timer=nil end
    if self.retry then self.retry:stop(); self.retry=nil end
    if self.timeout then self.timeout:stop(); self.timeout=nil end
    if self.socket and self.socket.close then pcall(function() self.socket:close() end) end
    self.socket=nil; self.session=nil; self.pending=nil; self.busy=false
    self.lastPosition=nil
end

function Client:_active()
    if not self.session then return false end
    if not self.options.current(self.generation) then self:stop(); return false end
    return true
end

function Client:start(session, generation)
    self:stop()
    if type(session)~="string" or #session~=32 or not session:match("^[0-9a-f]+$") then return false end
    self.session=session; self.generation=generation; self.after=0; self.failures=0
    self.waitSupported=false
    self:tick()
    return true
end

-- Schedule network continuation on Jive's event path, never recurse through a
-- synchronous response callback. A pre-long-poll Base gets a 5s idle fallback.
function Client:_later(delay)
    if not self:_active() then return end
    if self.retry then self.retry:stop() end
    local serial=self.serial
    self.retry=Timer(delay,function()
        self.retry=nil
        if serial==self.serial then self:tick() end
    end,true)
    self.retry:start()
end

function Client:_failed()
    self.failures=math.min((self.failures or 0)+1,5)
    self:_later(math.min(30000,1000*2^self.failures))
end

function Client:_synchronize()
    if not self:_active() or not self.pending then return end
    local position=self.options.position()
    if type(position)=="number" and (position~=position or position<0 or position==math.huge) then position=nil end
    if type(position)=="number" and self.lastPosition and position+250<self.lastPosition then
        -- The old audio timeline is no longer trustworthy. A reconnect/new
        -- decoder generation will acquire a fresh stream identity.
        self:stop()
        return
    end
    local delay=1000
    if type(position)=="number" then
        self.lastPosition=position
        local remaining=self.pending.position_ms-position
        if remaining<=0 then
            local event=self.pending
            self.pending=nil; self.after=event.revision
            self.options.update(event,self.generation)
            self:_later(1)
            return
        end
        delay=math.max(50,math.min(5000,remaining))
    end
    local serial=self.serial
    self.timer=Timer(delay,function()
        self.timer=nil
        if serial==self.serial then self:_synchronize() end
    end,true)
    self.timer:start()
end

function Client:tick()
    if not self:_active() then return end
    if self.pending then
        if self.timer then self.timer:stop(); self.timer=nil end
        self:_synchronize()
        return
    end
    if self.busy then return end
    self.busy=true
    local serial, session=self.serial,self.session
    local request, socket
    local chunks, bytes, done={},0,false
    local supportsWait=false
    local function finish()
        if done then return end
        done=true
        if serial==self.serial and self.timeout then self.timeout:stop(); self.timeout=nil end
        if socket and socket.close then pcall(function() socket:close() end) end
        if serial==self.serial then self.busy=false; self.socket=nil end
    end
    local function failure(status)
        finish()
        if status==404 then self:stop() else self:_failed() end
    end
    request=RequestHttp(function(chunk,err)
        if done or serial~=self.serial then return end
        if err then failure(request:t_getResponseStatus()); return end
        if chunk then
            bytes=bytes+#chunk
            if bytes>8192 then failure(); return end
            chunks[#chunks+1]=chunk
            if #chunks>=128 then chunks={table.concat(chunks)} end
            return
        end
        local status=request:t_getResponseStatus()
        finish()
        if status==404 then self:stop(); return end
        if status~=200 then self:_failed(); return end
        local ok, event=pcall(json.decode,table.concat(chunks))
        if not ok or type(event)~="table" then self:_failed(); return end
        self.waitSupported=supportsWait
        self.failures=0
        if event.pending then
            if event.finished then self:stop()
            else self:_later(supportsWait and 1 or 5000) end
            return
        end
        if event.session~=session or type(event.revision)~="number" or event.revision<=self.after or
           type(event.position_ms)~="number" or event.position_ms<0 then
            self:_failed(); return
        end
        self.pending=event
        self:_synchronize()
    end,"GET","/hls-meta/"..session.."?after="..self.after..(self.waitSupported and ("&wait="..self.waitSeconds) or ""),{
        stream=true, headers={Host="127.0.0.1:8765",Connection="close"},
        headersSink=function(headers)
            for name,value in pairs(headers or {}) do
                if string.lower(name)=="x-sb-metadata-wait" and value=="1" then supportsWait=true end
            end
        end})
    socket=SocketHttp(jnt,"127.0.0.1",8765,"StandaloneRadioHlsMetadata")
    self.socket=socket
    self.timeout=Timer((self.waitSeconds+15)*1000,function()
        if not done and serial==self.serial then finish(); self:_failed() end
    end,true)
    self.timeout:start()
    local ok=pcall(function() socket:fetch(request) end)
    if not ok and not done then failure() end
end
