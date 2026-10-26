-- Exercise the real OPML parser and LogoCache orchestration, without network IO.
package.preload.lfs=function() return {attributes=function() return "directory" end} end
package.preload["jive.net.Process"]=function() return function() error("unexpected process") end end
package.preload["jive.net.RequestHttp"]=function() return function() error("unexpected HTTP") end end
package.preload["jive.net.SocketHttp"]=function() return function() error("unexpected socket") end end
package.preload["applets.StandaloneRadio.Resolver"]=function() return {new=function() return {} end} end
package.preload["applets.StandaloneRadio.UrlTransport"]=function() return {redact=function(url) return url end} end
local LogoCache=require("applets.StandaloneRadio.LogoCache")
local Parser=require("applets.StandaloneRadio.OpmlParser")
local now,searches,downloads,results,cacheFiles,cacheUrls,published=0,{},{},{},{},{},{}
local logo="https://cdn.example/DR-P1.png"
local function outline(name,extra)
 return '<outline type="audio" item="station" text="'..(name or 'DR P1')..'" URL="http://opml.radiotime.com/Tune.ashx?id=s1" image="'..logo..'" '..(extra or '')..'/>'
end
local function parsed(body) return assert(Parser.parse('<opml><body>'..body..'</body></opml>')) end
local directory=parsed(outline())
local searchCallback,downloadCallback,deferSearch,deferDownload,failDownload
local client={searchUrl=function() return 'http://opml.radiotime.com/Search.ashx?query={QUERY}' end,
 fetchDirectory=function(_,url,callback)
  searches[#searches+1]=url
  if deferSearch then searchCallback=callback else callback(directory,directory and nil or "lookup failed") end
 end}
local cache=LogoCache.new({log={info=function() end,warn=function() end},clock=function() return now end,logoSearchClient=client,applet={streamPlayer={stationGeneration=7},baseNowPlaying={updateStationArtwork=function(_,url,station,generation) published[#published+1]={url=url,station=station,generation=generation} end}}})
cache._knownPath=function(_,uuid) return cacheFiles[uuid] end
cache._cachedUrl=function(_,uuid) return cacheUrls[uuid] end
cache._rememberUrl=function(_,uuid,url) cacheUrls[uuid]=url end
cache._download=function(_,station,uuid,url,temp,callback)
 downloads[#downloads+1]={uuid=uuid,url=url,stream=station.url}
 local function complete()
  if failDownload or url=='http://example.org/bad.png' then callback(nil)
  else local path='/cache/'..uuid..'.png';cacheFiles[uuid]=path;callback(path) end
 end
 if deferDownload then downloadCallback=complete else complete() end
end
local function station(id,favicon)
 return {id=id,stationuuid=id,source='radiobrowser',name='DR P1',url='http://original.example/live',favicon=favicon}
end
local function ensure(s) cache:ensure(s,function(path) results[#results+1]={path=path} end) end
local original=station('dr-p1','https://dr.dk/favicon.ico?v=2#logo')
ensure(original)
assert(#searches==1 and searches[1]:find('DR%%20P1') and #downloads==1 and downloads[1].url==logo)
assert(downloads[1].uuid=='dr-p1' and original.stationuuid=='dr-p1' and original.source=='radiobrowser' and original.id=='dr-p1')
assert(original.url=='http://original.example/live' and original.favicon=='https://dr.dk/favicon.ico?v=2#logo' and not original.provider)
assert(results[1].path=='/cache/dr-p1.png')
assert(published[1].url==logo and published[1].station==original and published[1].generation==7)
ensure(original);assert(#searches==1 and #downloads==1 and published[2].url==logo) -- disk hit
cacheFiles['dr-p1']=nil;ensure(original);assert(#searches==2) -- eviction permits lookup
local s=station('missing');ensure(s);assert(s.logoPath)
s=station('invalid','not a URL');ensure(s);assert(s.logoPath)
s=station('failed','http://example.org/bad.png');local n=#downloads;ensure(s)
assert(#downloads==n+2 and downloads[n+2].url==logo and s.logoPath)
s=station('working','http://example.org/good.jpg');local q=#searches;ensure(s);assert(#searches==q and s.logoPath)
-- Case-insensitive exact matching, not prefix/fuzzy matching.
directory=parsed(outline('dr p1'));ensure(station('case'));assert(results[#results].path)
local rejected={
 outline('DR P1 Extra'),
 '<outline type="audio" item="podcast" text="DR P1" image="'..logo..'"/>',
 '<outline type="link" item="station" text="DR P1" image="'..logo..'"/>',
 '<outline type="audio" item="station" title="DR P1" image="'..logo..'"/>',
 '<outline type="audio" item="station" text="DR P1" image="https://cdn-radiotime-logos.tunein.com/s0q.png?v=2"/>',
 outline()..outline(),
 '<outline type="audio" item="station" text="DR P1"/>',
 '<outline type="audio" item="station" text="DR P1" image="https://example.org/favicon.ico?v=2"/>',
}
for i,xml in ipairs(rejected) do
 directory=parsed(xml);local d=#downloads;ensure(station('rejected-'..i));assert(not results[#results].path and #downloads==d,i)
end
-- Nested exact matches work; duplicate matches in separate categories do not.
directory=parsed('<outline text="Stations">'..outline()..'</outline>');ensure(station('nested'));assert(results[#results].path)
directory=parsed('<outline text="One">'..outline()..'</outline><outline text="Two">'..outline()..'</outline>')
ensure(station('duplicate'));assert(not results[#results].path)
-- Failure cache expires and stays bounded, including lookup/download failures.
directory=nil;q=#searches;ensure(station('negative'));ensure(station('negative'));assert(#searches==q+1)
now=3601;directory=parsed(outline());ensure(station('negative'));assert(results[#results].path and #searches==q+2)
failDownload=true;local d=#downloads;ensure(station('download-fails'));ensure(station('download-fails'));assert(#downloads==d+1 and not results[#results].path)
failDownload=false;directory=nil
for i=1,105 do ensure(station('negative-limit-'..i)) end
local count=0;for _ in pairs(cache.negative) do count=count+1 end;assert(count<=100)
-- Simultaneous ensure calls wait for one lookup AND one download.
directory=parsed(outline());deferSearch=true;deferDownload=true
local a,b,c=station('coalesced'),station('coalesced'),station('coalesced');local r=#results;q=#searches;d=#downloads
ensure(a);ensure(b);assert(#results==r and #searches==q+1)
searchCallback(directory);ensure(c);assert(#downloads==d+1 and #results==r)
downloadCallback();assert(#results==r+3 and a.logoPath==b.logoPath and b.logoPath==c.logoPath and not cache.pending.coalesced)
deferSearch=false;deferDownload=false
-- A podcast is never mistaken for a live station when its supplied image fails.
q=#searches;local episode=station('episode');episode.episode=true;ensure(episode);assert(#searches==q and not results[#results].path)
print('Logo fallback exact OPML matches, ICO queries, placeholders, ambiguity, identity, cache expiry/eviction and coalescing passed')

-- Real Jive module environments do not inherit global require after module().
package.loaded["applets.StandaloneRadio.OpmlClient"] = nil
package.loaded["applets.StandaloneRadio.OpmlProviders"] = nil
package.preload["applets.StandaloneRadio.OpmlClient"] = function() return {new=function() return client end} end
package.preload["applets.StandaloneRadio.OpmlProviders"] = function() return {get=function(id) assert(id=="tunein");return {id=id} end} end
local realModule=module
module=function(name) local exports={};package.loaded[name]=exports;setfenv(2,exports) end
assert(loadfile("applet/StandaloneRadio/LogoCache.lua"))("IsolatedLogoCache")
module=realModule
local isolated=package.loaded.IsolatedLogoCache.new({log={info=function() end,warn=function() end},clock=function() return now end})
isolated._knownPath=function() return nil end
isolated._download=cache._download
directory=parsed(outline())
isolated._rememberUrl=function() end
local value;isolated:ensure(station('isolated'),function(path) value=path end)
assert(value=='/cache/isolated.png','lazy TuneIn client must load in isolated Jive module environment')
print('Lazy logo lookup imports work in the isolated Jive Lua 5.1 environment')

-- A new cache instance can publish a URL saved alongside the persistent image.
local restarted=LogoCache.new({log={info=function() end,warn=function() end},clock=function() return now end,logoSearchClient=client,
 applet={streamPlayer={stationGeneration=9},baseNowPlaying={updateStationArtwork=function(_,url,station,generation) assert(url==logo and generation==9);published[#published+1]={url=url} end}}})
restarted._knownPath=cache._knownPath;restarted._cachedUrl=cache._cachedUrl
q=#searches;local restored;restarted:ensure(original,function(path) restored=path end)
assert(restored and #searches==q)
print('Fresh/cached/restarted logos publish to native Now Playing with captured station generation')
