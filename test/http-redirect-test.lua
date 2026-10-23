-- Exercise the applet adapter through Jive-style response-body dispatch,
-- including duplicate chunks/EOF after a redirect (the original crash path).
local URL=require("socket.url")
local fixtures,requests,timers={}, {}, {}
local held
local sockets={}
package.preload["jive.ui.Timer"]=function() return function(delay,callback)
 local t={delay=delay,callback=callback,start=function(self) self.running=true end,stop=function(self) self.running=false end}
 timers[#timers+1]=t;return t
end end
package.preload["jive.net.RequestHttp"]=function() return function(sink,method,path,options)
 return {sink=sink,path=path,options=options,
  t_getResponseStatus=function(self) return self.status,"test" end,
  t_getResponseSink=function(self) return self.sink end,
  t_setResponseBody=function(self,data)
   if self.status==301 or self.status==302 or self.status==307 then
    self.status=false;error("stock automatic redirect escaped transport")
   elseif self.status==200 then self.sink(data)
   else self.sink(nil,"HTTP "..tostring(self.status)) end
  end}
end end
package.preload["jive.net.SocketHttp"]=function() return function(_,host,port)
 local socket={close=function(self) self.closed=true end,fetch=function(self,request)
  self.request=request
  local key=host..":"..port..request.path;requests[#requests+1]=key
  local f=assert(fixtures[key],key)
  request.status=f.status or 200
  if f.err then request.sink(nil,f.err);return end
  if f.hold then held={request=request,socket=self};return end
  request.options.headersSink({Location=f.location,["Content-Type"]=f.mime or "application/vnd.apple.mpegurl",["Content-Length"]=f.length})
  request:t_setResponseBody(f.body or "")
  request:t_setResponseBody(nil)
  request:t_setResponseBody(nil)
  request.sink(nil,"late error")
 end}
 sockets[#sockets+1]=socket;return socket
end end
package.preload["applets.StandaloneRadio.Resolver"]=function() return {new=function() return {resolve=function(_,h,cb) cb(h) end} end} end
local Client=require("applets.StandaloneRadio.OpmlClient")
local Transport=require("applets.StandaloneRadio.UrlTransport")
local client=Client.new({log={info=function() end,warn=function() end}})
local function key(url) local p=assert(Transport.forRequest(url));return p.host..":"..p.port..p.path end
local function fixture(url,value) fixtures[key(url)]=value end
local hls="#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n"
local function fetch(url,expectedError)
 local calls=0;local result
 client:_fetch(url,"*/*",65536,0,function(body,err,mime,effective)
  calls=calls+1;result=effective
  if expectedError then assert(err and not body,err) else assert(body==hls and not err,tostring(err)) end
 end)
 assert(calls==1,"callback count "..calls);return result
end
for _,id in ipairs({"IDR1","IDR2"}) do
 local a="http://stream.indemandradio.com/station/"..id.."/index.m3u8"
 local b=a:gsub("^http:","https:")
 fixture(a,{status=301,location=b,length="99999999"});fixture(b,{body=hls})
 assert(fetch(a)==b);assert(requests[#requests]:find("127.0.0.1:8765/https/",1,true))
 local calls=0
 client:resolveStation({name=id,url=a,codec="auto"},function(s,e) calls=calls+1;assert(s and s.hls and s.url==b,tostring(e)) end)
 assert(calls==1)
end
for _,pair in ipairs({
 {"https://a.test/one","https://b.test/two?q=a%2Fb"},
 {"http://a.test/one","http://b.test/two"},
 {"https://a.test/one","http://b.test/two"},
 {"http://a.test/folder/one","../two?q=a%2Fb","http://a.test/two?q=a%2Fb"},
 {"http://a.test/one?q=old","?q=new","http://a.test/one?q=new"}}) do
 local a,location,b=pair[1],pair[2],pair[3] or pair[2]
 fixture(a,{status=302,location=location});fixture(b,{body=hls});assert(fetch(a)==b)
end
for _,sample in ipairs({
 {"mix.m3u","#EXTM3U\n../live.mp3?token=a%2Fb\n"},
 {"mix.pls","[playlist]\nFile1=../live.mp3?token=a%2Fb\n"}}) do
 local start="http://a.test/"..sample[1]
 local final="https://b.test/path/"..sample[1]
 fixture(start,{status=302,location=final});fixture(final,{body=sample[2],mime="text/plain"})
 for _,url in ipairs({start,final}) do
  local calls=0
  client:resolveStation({name="test",url=url,codec="mp3"},function(result,err)
   calls=calls+1;assert(result and result.url=="https://b.test/live.mp3?token=a%2Fb",tostring(err))
  end)
  assert(calls==1)
 end
end
local directory="http://a.test/menu.opml"
fixture(directory,{status=301,location="https://b.test/path/menu.opml"})
fixture("https://b.test/path/menu.opml",{body='<opml><body><outline text="Folder" type="link" xmlUrl="child.opml"/></body></opml>',mime="text/xml"})
client:fetchDirectory(directory,function(result,err)
 assert(result and result.children[1].url=="https://b.test/path/child.opml",tostring(err))
end)
local a="http://a.test/start"
for _,location in ipairs({"file:///tmp/evil",a,"http://a.test/fail",""}) do
 fixture(a,{status=301,location=location});fixture("http://a.test/fail",{err="connection failed"});fetch(a,true)
end
fixture(a,{status=307});fetch(a,true)
for i=0,6 do fixture("http://a.test/"..i,{status=302,location="/"..(i+1)}) end
fetch("http://a.test/0",true)
fixture(a,{status=302,location="/pending"});fixture("http://a.test/pending",{hold=true})
local cancel=client:_fetch(a,"*/*",65536,0,function() error("cancelled request delivered") end)
cancel();assert(held.socket.closed);held.request.sink(hls);held.request.sink(nil)
fixture(a,{hold=true});local calls=0
client:_fetch(a,"*/*",65536,0,function(_,err) assert(err:find("timed out"));calls=calls+1 end)
for _,t in ipairs(timers) do if t.running and t.delay==15000 then t.callback() end end
held.request.sink(nil,"late");assert(calls==1)
for _,t in ipairs(timers) do if t.running and t.delay==1 then t.callback() end end
for _,socket in ipairs(sockets) do
 if socket.request.status and socket.request.status>=300 and socket.request.status<400 then
  assert(socket.closed,"completed redirect socket left active")
 end
end
print("Explicit redirects: schemes, relative/query URLs, exact IDR cases, loops/limit, missing/unsafe Location, errors, cancellation, timeout and once-only completion passed")
