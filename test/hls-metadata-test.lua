-- Deterministic Jive event-loop fixtures; no network or decoder required.
local requests, updates, timers={}, {}, {}
local reply
package.preload.json=function() return {decode=function() return reply end} end
package.preload["jive.net.RequestHttp"]=function() return function(sink,method,path,options)
    return {sink=sink,path=path,options=options,t_getResponseStatus=function() return 200 end}
end end
package.preload["jive.net.SocketHttp"]=function() return function()
    return {fetch=function(_,request) requests[#requests+1]=request end,close=function() end}
end end
package.preload["jive.ui.Timer"]=function() return function(delay,callback)
    local timer={callback=callback,delay=delay,start=function() end,stop=function(self) self.stopped=true end}
    timers[#timers+1]=timer;return timer
end end
assert(loadfile("applet/StandaloneRadio/HlsMetadata.lua"))("HlsTest")
local generation, elapsed, clockReads=1,0,0
local client=package.loaded.HlsTest.new({current=function(g) return g==generation end,
    position=function() clockReads=clockReads+1;return elapsed end, update=function(event) updates[#updates+1]=event end})
local id=string.rep("a",32)
assert(not client:start("invalid",1))
assert(client:start(id,1) and #requests==1)
local function respond(request,event)
    request.options.headersSink({["X-SB-Metadata-Wait"]="1"})
    reply=event;request.sink("{}");request.sink(nil)
end
respond(requests[1],{session=id,revision=1,position_ms=1000,title="First"})
client:tick();assert(#updates==0 and #requests==1,"download must not advance UI ahead of decoder")
elapsed=1000;client:tick();assert(#updates==1)
assert(client.retry and client.retry.delay==1)
client.retry.callback();assert(#requests==2 and requests[2].path:find("&wait=25",1,true))
respond(requests[2],{session=id,revision=1,position_ms=1000,title="Duplicate"})
client:tick();assert(#updates==1)
local old=requests[#requests]
generation=2;client:start(string.rep("b",32),2)
respond(old,{session=id,revision=2,position_ms=0,title="Stale"})
assert(#updates==1)
local current=requests[#requests]
respond(current,{session=id,revision=3,position_ms=0,title="Wrong session"})
assert(not client.pending)
client:tick();current=requests[#requests]
respond(current,{session=string.rep("b",32),revision=1,position_ms=2000,title="Second"})
elapsed=nil;client:tick();assert(#updates==1)
elapsed=2000;client:tick();assert(#updates==2)
client:stop();local count=#requests;client:tick();assert(#requests==count and not client.session)
client:start(id,2);current=requests[#requests]
current.t_getResponseStatus=function() return 404 end
current.sink(nil,"HTTP 404")
assert(not client.session,"legacy RequestHttp error sink must retire missing sessions")
generation=3;client:start(id,2);assert(not client.session,"obsolete generation cannot poll")
print("HLS metadata timing, generation, duplicate and cancellation tests passed")

-- An unchanged stream owns one long poll and no decoder-position timer.
generation=4;elapsed=0;client:start(id,4)
local idleReads=clockReads
respond(requests[#requests],{pending=true})
client.retry.callback()
local count=#requests
assert(not client.timer and client.busy and client.timeout.delay==40000)
assert(requests[#requests].path:find("wait=25",1,true))
assert(#requests==count)
assert(clockReads==idleReads,"idle transport must not sample the decoder clock")
-- Far-future events use one-shot remaining-time scheduling, not HTTP polling.
respond(requests[#requests],{session=id,revision=1,position_ms=10000,title="Future"})
assert(client.timer.delay==5000 and not client.busy and not client.retry)
local before=#updates
client.timer.callback();assert(#updates==before and client.timer.delay==5000,"stalled clock must not publish")
elapsed=9500;client.timer.callback();assert(client.timer.delay==500)
elapsed=10000;client.timer.callback();assert(#updates==before+1)
client.retry.callback()
respond(requests[#requests],{session=id,revision=2,position_ms=10000,title="Second due"})
assert(updates[#updates].title=="Second due" and client.after==2,"backlog must retain revision order")
client.retry.callback()
respond(requests[#requests],{session=id,revision=3,position_ms=11000,title="Later"})
elapsed=0;client.timer.callback();assert(not client.session,"clock reset must retire old timeline")
-- Compatibility: old Base gets non-wait requests with a slower idle fallback.
client:start(id,4);reply={pending=true}
local legacy=requests[#requests];legacy.sink("{}");legacy.sink(nil)
assert(client.retry.delay==5000 and not client.waitSupported)
client.retry.callback();assert(not requests[#requests].path:find("wait=",1,true))
client:stop()
-- Failures retry with bounded backoff, not a short fixed network poll.
client:start(id,4)
for _,delay in ipairs({2000,4000,8000,16000,30000,30000}) do
    requests[#requests].sink(nil,"transport failed")
    assert(client.retry.delay==delay)
    client.retry.callback()
end
local outstanding=requests[#requests]
client:stop();respond(outstanding,{session=id,revision=99,position_ms=0,title="Late"})
assert(not client.pending and not client.session)
local configured=package.loaded.HlsTest.new({waitSeconds=99})
assert(configured.waitSeconds==30)
print("Long-poll idle traffic, one-shot synchronization, reset and legacy fallback tests passed")
