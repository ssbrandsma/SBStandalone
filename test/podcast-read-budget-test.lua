local input,burstMax,reads,active,held="",0,0,nil,false
local timers={}
package.preload["jive.ui.Timer"]=function() return function(delay,callback)
 local t={delay=delay,callback=callback,start=function(self) self.running=true end,stop=function(self) self.running=false end}
 timers[#timers+1]=t;return t
end end
package.preload["jive.net.RequestHttp"]=function() return function(sink,method,path,options)
 return {sink=sink,options=options,t_getResponseStatus=function() return 200,"test" end}
end end
package.preload["jive.net.SocketHttp"]=function() return function()
 local socket={close=function(self) self.closed=true end,t_addRead=function(self,pump) self.pump=pump end}
 function socket:fetch(request)
  active=self;self.request=request;self.offset=1
  request.options.headersSink({["Content-Type"]="application/octet-stream"})
  self:t_addRead(function()
   reads=reads+1
   if self.offset>#input then self.done=true;request.sink(nil);return end
   local chunk=input:sub(self.offset,self.offset+2047);self.offset=self.offset+#chunk;request.sink(chunk)
  end,70)
  if not held then
   while not self.done and not self.closed do
    local before=reads;self.pump();burstMax=math.max(burstMax,reads-before)
    assert(reads-before<=16,"unbounded read callback")
   end
  end
 end
 return socket
end end
package.preload["applets.StandaloneRadio.Resolver"]=function() return {new=function() return {resolve=function(_,host,cb) cb("127.0.0.1") end} end} end
local Client=require("applets.StandaloneRadio.OpmlClient")
local client=Client.new({log={info=function() end,warn=function() end}})
local episode='<item><title>Episode</title><description>'..string.rep('x',1024)..'</description><enclosure type="audio/mpeg" url="https://example.org/a.mp3"/></item>'
input='<rss><channel>'..string.rep(episode,150)..'</channel></rss>'
local clock=os.clock;os.clock=function() return 0 end
local result
client:fetchDirectory("https://example.org/no-extension",function(value,err) assert(value,tostring(err));result=value end)
assert(result.format=="rss" and burstMax==16)
local rssDeadlines=0;for _,timer in ipairs(timers) do if timer.delay==180000 then rssDeadlines=rssDeadlines+1;assert(not timer.running) end end
assert(rssDeadlines==1,"RSS total deadline must be extended once, not per block")
input='<opml><body>'..string.rep(' ',20000)..'<outline text="Radio" URL="https://example.org/live"/></body></opml>'
burstMax=0;reads=0
client:fetchDirectory("https://example.org/ordinary.opml",function(value,err) assert(value,tostring(err)) end)
assert(burstMax==1,"OPML read scheduling must remain unchanged")
held=true;input='<rss><channel>'..string.rep(episode,100);local delivered=0
local cancel=client:fetchDirectory("https://example.org/cancel.rss",function() delivered=delivered+1 end)
active.pump();cancel();assert(active.closed and delivered==0)
os.clock=clock
print("RSS bounded read bursts, unchanged OPML scheduling, one total RSS deadline and cancellation passed")
