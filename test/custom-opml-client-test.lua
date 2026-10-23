local URL=require("socket.url")
local fixtures,requests,timers,held={}, {}, {}, nil
package.preload["jive.ui.Timer"]=function() return function(delay,callback)
    local timer={delay=delay,callback=callback,start=function(self) self.running=true end,stop=function(self) self.running=false end}
    timers[#timers+1]=timer;return timer
end end
package.preload["jive.net.RequestHttp"]=function() return function(sink,method,path,options)
    return {sink=sink,method=method,path=path,options=options,
        t_getResponseStatus=function(self) return self.status or 200,"test" end,
        getURI=function() return URL.parse(path) end}
end end
package.preload["jive.net.SocketHttp"]=function() return function()
    return {close=function(self) self.closed=true end,fetch=function(self,request)
        requests[#requests+1]=request
        local fixture=assert(fixtures[request.path],"unexpected URL "..request.path)
        if fixture.hold then held={request=request,socket=self};return end
        request.status=fixture.status or 200
        if fixture.err then request.sink(nil,fixture.err);return end
        request.options.headersSink({["Content-Type"]=fixture.mime or "text/xml",["Content-Length"]=fixture.length,Location=fixture.location})
        if fixture.body then request.sink(fixture.body) end
        request.sink(nil)
    end}
end end
package.preload["applets.StandaloneRadio.Resolver"]=function() return {new=function() return {resolve=function(_,host,callback)
    callback(host=="bad.invalid" and nil or "203.0.113.1")
end} end} end
package.preload["applets.StandaloneRadio.UrlTransport"]=function() return {redact=function(value) return value end,
    forRequest=function(url) local p=URL.parse(url);return {host=p.host,hostHeader=p.host,port=80,path=url} end} end
local Providers=require("applets.StandaloneRadio.OpmlProviders")
local Client=require("applets.StandaloneRadio.OpmlClient")
local Parser=require("applets.StandaloneRadio.OpmlParser")
local function read(name) local f=assert(io.open("test/fixtures/opml/"..name,"rb"));local body=f:read("*a");f:close();return body end

local provider=Providers.get("custom")
local client=Client.new({log={info=function() end,warn=function() end},provider=provider})
local clock=100;local oldTime=os.time;os.time=function() return clock end
local url="https://example.org/start.opml"
local effective="https://example.org/catalog/root.opml"
fixtures[url]={status=302,location=effective}
fixtures[effective]={body=read("custom-directory.opml")}
local root
client:fetchDirectory(url,function(result,err) assert(not err);root=result end)
assert(root.url==effective and #root.children==5)
assert(root.children[1].children[1].url=="https://example.org/catalog/streams/one.mp3")
assert(root.children[1].children[1].image=="https://example.org/catalog/logos/one.png")
assert(root.children[1].children[1].homepage=="https://example.org/radio-one")
assert(root.children[2].url=="https://example.org/catalog/jazz.opml?lang=en")
assert(root.children[3].type=="directory" and root.children[3].url)
assert(not root.children[4].url and root.children[4].homepage)
assert(client:toStation(root.children[5])==nil)
assert(client:toStation(root.children[1].children[1]).provider=="custom")
local before=#requests
client:fetchDirectory(effective,function(result) assert(result==root) end)
client:fetchDirectory(url,function(result) assert(result==root) end)
assert(#requests==before,"cache must share requested/effective URLs")
clock=161
client:fetchDirectory(url,function(result) assert(result) end);assert(#requests>before)
local slow="https://example.org/slow.opml";fixtures[slow]={hold=true}
local callbacks=0
local cancel=client:fetchDirectory(slow,function() callbacks=callbacks+1 end)
local cancel2=client:fetchDirectory(slow,function(result) assert(result);callbacks=callbacks+1 end)
before=#requests;cancel();assert(not held.socket.closed)
client:fetchDirectory("https://example.org/other",function(result,err) assert(not result and err:find("busy")) end)
held.request.options.headersSink({["Content-Type"]="text/xml"})
held.request.sink(read("custom-directory.opml"));held.request.sink(nil)
assert(callbacks==1 and #requests==before)
for i=1,3 do
 local u="https://example.org/"..i..".opml";fixtures[u]={body="<opml><body/></opml>"}
 client:fetchDirectory(u,function(result) assert(result) end)
end
assert(#client.directoryCache==2)
local bad="https://example.org/missing.opml";fixtures[bad]={status=404,body="missing"}
before=#requests
for i=1,2 do client:fetchDirectory(bad,function(result,err) assert(not result and err) end) end
assert(#requests==before+2,"failures must not become permanent cache entries")
fixtures[slow]={hold=true}
cancel=client:fetchDirectory(slow,function() error("cancelled callback") end)
cancel2=client:fetchDirectory(slow,function() error("cancelled callback") end)
cancel();cancel2();assert(held.socket.closed and not client.directoryPending)
os.time=oldTime
print("Custom OPML real XML, relative/redirected links, station mapping, two-page TTL cache, coalescing, errors and cancellation passed")
