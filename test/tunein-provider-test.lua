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
local provider=Providers.get("tunein")
assert(not provider.root:find("partnerId",1,true) and not provider.root:find("country",1,true))
assert(provider.prepareUrl("http://opml.radiotime.com/Tune.ashx?id=s329637")=="http://opml.radiotime.com/Tune.ashx?id=s329637")
assert(provider.root=="http://opml.radiotime.com/Browse.ashx")
assert(provider.prepareUrl("https://opml.radiotime.com/Browse.ashx")=="https://opml.radiotime.com/Browse.ashx")
assert(Providers.get("tunein",{partnerId="my id"}).root:find("partnerId=my%20id",1,true))
local client=Client.new({log={info=function() end,warn=function() end},provider=provider})
fixtures[provider.root]={body=read("tunein-root.opml")}
local root
client:fetchDirectory(provider.root,function(result,error) assert(not error);root=result end)
assert(root and #root.children>=5)
fixtures["http://opml.radiotime.com/Browse.ashx?c=music"]={body=read("tunein-music.opml")}
client:fetchDirectory(root.children[2].url,function(result,error) assert(result and not error and #result.children>0) end)
local searchURL=provider.search:gsub("{QUERY}",function() return "1%20Vallei" end)
fixtures[searchURL]={body=read("tunein-search.opml")}
local station
client:fetchDirectory(searchURL,function(result) station=assert(client:toStation(result.children[1])) end)
assert(station.provider=="tunein" and station.providerId=="s329637" and station.source=="tunein")
assert(station.codec=="mp3" and station.declaredCodec=="mp3" and station.bitrate==192)
assert(station.programDescription=="Voor jou en mij" and not station.description)
assert(station.providerMetadata.preset_id=="s329637" and station.remoteLogo:match("s0q.png"))
fixtures[station.url]={body=read("tunein-tune.m3u"),mime="audio/x-mpegurl"}
local resolved
client:resolveStation(station,function(result,error) assert(not error);resolved=result end)
assert(resolved.url=="https://xon.luisteren.link/1vallei" and not resolved.requiresResolution)
assert(resolved.resolverUrl==station.url and resolved.providerMetadata.guide_id=="s329637")
local Store=require("applets.StandaloneRadio.PresetStore")
local settings={presets={}}
local writes=0
local store=Store.new({settings=settings,applet={storeSettings=function() writes=writes+1 end},log={info=function() end,warn=function() end}})
assert(store:saveFavorite(resolved));assert(store:saveFavorite(resolved))
assert(#store:getFavorites()==1)
assert(store:getFavorites()[1].url==station.url and store:getFavorites()[1].requiresResolution)
assert(not store:getFavorites()[1].catalogPlaying)
assert(store:assign(3,resolved));local preset=store:getPreset(3)
assert(preset.url==station.url and preset.requiresResolution and preset.providerId=="s329637")
client:resolveStation(preset,function(result,error) assert(result.url==resolved.url and not error) end)
local before=#requests
fixtures[station.url]={body='<opml><body><outline type="audio" URL="https://example.com/unsupported" formats="wma"/><outline type="link" URL="https://example.com/fail.pls"/><outline type="audio" URL="https://example.com/live.aac" formats="aac"/></body></opml>'}
fixtures["https://example.com/fail.pls"]={err="network failure"}
client:resolveStation(station,function(result,error) assert(result and not error and result.url=="https://example.com/live.aac" and result.codec=="aac" and result.declaredCodec=="mp3") end)
assert(#requests==before+2)
fixtures[station.url]={body='[playlist]\nFile1=ftp://invalid/file\nFile2=https://example.com/next.m3u\n',mime="audio/x-scpls"}
fixtures["https://example.com/next.m3u"]={body="#EXTM3U\n../live.mp3\n",mime="audio/x-mpegurl"}
client:resolveStation(station,function(result,error) assert(result and result.url=="https://example.com/live.mp3" and not error) end)
fixtures[station.url]={body='<opml><body><outline type="link" URL="'..station.url..'"/></body></opml>'}
client:resolveStation(station,function(result,error) assert(not result and error:find("loop",1,true)) end)
local redirect="https://example.com/resolver"
fixtures[station.url]={status=302,location=redirect,body="",mime="text/plain"}
fixtures[redirect]={body="https://example.com/live.mp3\n",mime="text/plain"}
client:resolveStation(station,function(result) assert(result.url=="https://example.com/live.mp3") end)
fixtures[station.url]={body="",length="262145"}
client:fetchDirectory(station.url,function(result,error) assert(not result and error:find("too large",1,true)) end)
fixtures[station.url]={hold=true}
local called=false
client:resolveStation(station,function() called=true end)
client:cancelPlaylist();held.request.sink("https://example.com/stale");held.request.sink(nil)
assert(not called and held.socket.closed)
local cancel=client:fetchDirectory(station.url,function() called=true end);cancel();held.request.sink(nil,"late error");assert(not called)
client:fetchDirectory(station.url,function(result,error) assert(not result and error:find("timed out",1,true));called=true end)
timers[#timers].callback();assert(called and held.socket.closed)
local unknown=assert(client:toStation({type="audio",url=station.url,title="Unknown"}))
assert(unknown.codec==nil and unknown.bitrate==nil and unknown.declaredCodec==nil)
fixtures[station.url]={mime="audio/mpeg",body=string.rep("x",70000)}
client:resolveStation(station,function(result,error) assert(result and not error and result.url==station.url) end)
assert(writes==3)
fixtures[station.url]={hold=true}
local baseIndex=#requests
local callbacks=0
for i=1,12 do client:resolveStation(station,function(result) assert(result);callbacks=callbacks+1 end) end
for i=baseIndex+1,#requests do requests[i].sink("https://example.com/switched.mp3");requests[i].sink(nil) end
assert(callbacks==1,"stale station switches must not duplicate playback callbacks")
local rfDefault=Client.new({log={info=function() end,warn=function() end}})
local rfProvider=Client.new({log={info=function() end,warn=function() end},provider=Providers.get("radiofeeds")})
local rfEntry={type="audio",title="BBC (AAC)",url="http://example.com/bbc.m3u",icon="http://example.com/logo.png"}
local generic,radiofeeds=rfDefault:toStation(rfEntry),rfProvider:toStation(rfEntry)
local hash=5381
for i=1,#rfEntry.url do hash=(hash*33+rfEntry.url:byte(i))%2147483647 end
assert(radiofeeds.id=="radiofeeds:rf"..hash and radiofeeds.stationuuid=="rf"..hash)
assert(radiofeeds.codec=="aac" and radiofeeds.declaredCodec=="aac" and radiofeeds.favicon==rfEntry.icon)
assert(generic.source=="opml" and generic.id:match("^opml:") and generic.codec~="aac")
assert(rfDefault:rootUrl()==nil and rfDefault:searchUrl()==nil)
assert(rfProvider:rootUrl()==Providers.get("radiofeeds").root)
assert(rfProvider:searchUrl()==Providers.get("radiofeeds").search)
assert(rfProvider:toStation({type="audio",url=rfEntry.url,title="No codec"}).codec=="mp3")
local NowPlaying=require("applets.StandaloneRadio.StandaloneBaseNowPlaying")
local now=NowPlaying.new()
now.station=resolved
now.station.catalogPlaying="Current programme without an artist/title separator"
now.station.observedAudio={codec="aac",bitrate_kbps=128}
local snapshot=now:_snapshot()
assert(snapshot.track.title==now.station.catalogPlaying and snapshot.track.artist=="")
assert(snapshot.station.audio.codec=="mp3" and snapshot.track.audio.codec=="aac")
now.metadata="Actual Artist - Actual Track"
snapshot=now:_snapshot()
assert(snapshot.track.title=="Actual Track" and snapshot.track.artist=="Actual Artist")
now.station=unknown;now.metadata=nil;snapshot=now:_snapshot()
assert(snapshot.station.audio.codec==nil and snapshot.station.audio.bitrate_kbps==nil)
local example=assert(Parser.parse(read("tunein-station.opml")))
assert(example.children[1].title=="1 Vallei 104.9" and example.children[1].reliability=="100")
print("TuneIn browse/search, station metadata, format resolution/fallback, bounds, cancellation, favorites and hardware preset replay passed")
