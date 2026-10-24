-- Incremental directory reader: RSS uses SAX; OPML retains its existing parser.
-- No full RSS body or XML tree is retained. Every input is validated to EOF.
local lxp=require("lxp")
local Opml=require("applets.StandaloneRadio.OpmlParser")
local URL=require("socket.url")
local M={MAX_BYTES=8*1024*1024,MAX_EPISODES=50,OPML_BYTES=256*1024}
local Reader={};Reader.__index=Reader
local codecs={ ["audio/mpeg"]="mp3",["audio/mp3"]="mp3",["audio/mp4"]="aac_mp4",
 ["audio/x-m4a"]="aac_mp4",["audio/aac"]="aac",["audio/aacp"]="aac+",
 ["audio/ogg"]="ogg",["application/ogg"]="ogg",["audio/flac"]="flac",["audio/x-flac"]="flac" }
local fields={author=true,managingeditor=true,title=true,description=true,pubdate=true,guid=true,language=true,link=true,["itunes:summary"]=true,["itunes:author"]=true,["dc:creator"]=true,["itunes:duration"]=true,["itunes:episode"]=true}
local ranks={mp3=1,aac=2,["aac+"]=2,aac_mp4=3,ogg=4,flac=5}
local function text(s,limit)
 s=tostring(s or ""):gsub("<[^>]*>"," "):gsub("%c"," "):gsub("%s+"," "):match("^%s*(.-)%s*$")
 s=s:sub(1,limit or 1024)
 local last=#s
 while last>0 and s:byte(last)>=128 and s:byte(last)<192 do last=last-1 end
 local lead=s:byte(last) or 0
 local width=lead>=240 and 4 or lead>=224 and 3 or lead>=192 and 2 or 1
 if #s-last+1<width then s=s:sub(1,last-1) end
 return s
end
local names,nameCount={},0
local function name(tag)
 local cached=names[tag];if cached then return cached end
 local uri,part=tag:match("^(.*)|([^|]+)$")
 local value
 if not uri then value=tag:lower()
 elseif uri:lower():find("itunes.com",1,true) then value="itunes:"..part:lower()
 elseif uri:find("purl.org/dc/",1,true) then value="dc:"..part:lower()
 else value=part:lower() end
 if nameCount<64 then names[tag]=value;nameCount=nameCount+1 end
 return value
end
local function remote(base,value)
 if type(value)~="string" or value=="" or #value>4096 or value:find("[%c%s]") then return nil end
 local u=URL.absolute(base,value)
 if not u:match("^https?://[%w%.%-]+:?%d*/") or u:find("[#\\]") then return nil end
 return u
end
function M.duration(value)
 if not value then return nil end
 local h,m,s=value:match("^(%d+):(%d%d?):(%d%d?)$")
 local three=h~=nil
 if not h then m,s=value:match("^(%d+):(%d%d?)$");h=0 end
 if s and (tonumber(s)>59 or three and tonumber(m)>59) then return nil end
 local seconds=s and tonumber(h)*3600+tonumber(m)*60+tonumber(s) or tonumber(value)
 if seconds and seconds>=0 and seconds<=31*86400 then return math.floor(seconds*1000) end
end
local months={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
function M.date(value)
 local d,mon,y,h,m,s,zone=tostring(value or ""):match("(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+([%+%-%w]+)")
 mon=months[mon];d,y,h,m,s=tonumber(d),tonumber(y),tonumber(h),tonumber(m),tonumber(s)
 if not mon or not y or y<1970 or y>2200 or d<1 or d>31 or h>23 or m>59 or s>59 then return nil end
 local offset=0
 if zone~="GMT" and zone~="UTC" and zone~="UT" then
  local sign,zh,zm=zone:match("^([%+%-])(%d%d)(%d%d)$")
  if not sign or tonumber(zh)>23 or tonumber(zm)>59 then return nil end
  offset=(tonumber(zh)*60+tonumber(zm))*60*(sign=="-" and -1 or 1)
 end
 local leap=y%4==0 and (y%100~=0 or y%400==0)
 local days={31,leap and 29 or 28,31,30,31,30,31,31,30,31,30,31}
 if d>days[mon] then return nil end
 local year=y-(mon<=2 and 1 or 0);local era=math.floor(year/400);local yo=year-era*400
 local doy=math.floor((153*(mon+(mon>2 and -3 or 9))+2)/5)+d-1
 local epoch=era*146097+yo*365+math.floor(yo/4)-math.floor(yo/100)+doy-719468
 return epoch*86400+h*3600+m*60+s-offset
end
local function newer(a,b)
 if a.timestamp and b.timestamp then return a.timestamp>b.timestamp or (a.timestamp==b.timestamp and a.order<b.order) end
 -- Undated entries follow dated ones; preserve their original relative order.
 if a.timestamp or b.timestamp then return a.timestamp~=nil end
 return a.order<b.order
end
function Reader:close()
 local p=self.parser;self.parser=nil
 if p then pcall(function() p:close() end) end
 self.raw=nil;self.item=nil;self.capture=nil;self.prefix=nil;self.scanTail=nil;self.episodes=nil;self.channel=nil
end
function Reader:_retain()
 local e=self.item
 if not e.url then self.skipped=self.skipped+1;return end
 e.pubDate=text(e.pubdate,1024);e.timestamp=M.date(e.pubDate);e.order=self.items
 if #self.episodes>=self.maxEpisodes and not newer(e,self.episodes[#self.episodes]) then return end
 e.type="audio";e.episode=true;e.title=text(e.title,512)
 if e.title=="" then e.title="Untitled episode" end
 e.description=text(e["itunes:summary"] or e.description,2048);e.guid=text(e.guid,1024)
 e.duration_ms=M.duration(text(e["itunes:duration"],64));e.episodeNumber=tonumber(e["itunes:episode"])
 e["itunes:summary"]=nil;e["itunes:duration"]=nil;e["itunes:episode"]=nil;e.pubdate=nil
 for _,old in ipairs(self.episodes) do if old.url==e.url and old.guid==e.guid then return end end
 local index=1
 while self.episodes[index] and not newer(e,self.episodes[index]) do index=index+1 end
 table.insert(self.episodes,index,e);if #self.episodes>self.maxEpisodes then table.remove(self.episodes) end
end
function M.new(options)
 options=options or {}
 local self=setmetatable({bytes=0,nodes=0,depth=0,stack={},raw={},channel={},episodes={},items=0,skipped=0,
  maxBytes=math.min(tonumber(options.maxBytes) or M.MAX_BYTES,M.MAX_BYTES),
  maxEpisodes=math.min(math.max(1,tonumber(options.maxEpisodes) or M.MAX_EPISODES),M.MAX_EPISODES)},Reader)
 local function reject(message) self.error=message;error(message) end
 local callbacks={}
 callbacks.ExternalEntityRef=function() reject("Directory external entities are not supported") end
 callbacks.StartElement=function(_,tag,attrs)
  local key=name(tag);self.depth=self.depth+1;self.nodes=self.nodes+1;self.stack[self.depth]=key
  if self.depth==1 then
   if key~="rss" and key~="opml" then reject(key=="feed" and "Atom feeds are not supported" or "Directory is neither OPML nor RSS") end
   self.kind=key
  end
  if self.depth>32 or self.nodes>(self.kind=="opml" and 1024 or 200000) then reject("Directory XML structure limit exceeded") end
  if self.kind~="rss" then return end
  local parent=self.stack[self.depth-1]
  if self.depth==2 and key=="channel" then self.hasChannel=true end
  if parent=="channel" and key=="item" and self.depth==3 then self.items=self.items+1;self.item={} end
  local target=self.item or self.channel
  if key=="enclosure" and self.item and self.depth==4 then
   local mime=(attrs.type or ""):lower():match("^%s*([^;%s]+)")
   local codec=codecs[mime]
   local url=attrs.url
   if codec and remote("https://podcast.invalid/",url) then
    if not target.codec or ranks[codec]<ranks[target.codec] then
     target.url=url;target.codec=codec;target.enclosureType=mime
     local length=tonumber(attrs.length);target.enclosureLength=length and length>=0 and length<=2^53 and length or nil
    end
   end
  elseif key=="itunes:image" and ((self.item and self.depth==4) or (not self.item and self.depth==3)) then
   target.image=type(attrs.href)=="string" and attrs.href:sub(1,4096) or nil
  elseif (self.item and self.depth==4 or not self.item and self.depth==3 and parent=="channel") and
   fields[key] then
   self.capture={key=key,target=target,depth=self.depth,value="",max=1024}
   self.capture.max=(key=="description" or key=="itunes:summary") and 2048 or 1024
  elseif not self.item and self.depth==4 and parent=="image" and key=="url" then
   self.capture={key="rssImage",target=self.channel,depth=self.depth,value="",max=4096}
  end
 end
 callbacks.CharacterData=function(_,value)
  local c=self.capture
  if c and #c.value<c.max then c.value=c.value..value:sub(1,c.max-#c.value) end
 end
 callbacks.EndElement=function(_,tag)
  local key=name(tag);local c=self.capture
  if c and c.depth==self.depth then c.target[c.key]=c.value;self.capture=nil end
  if key=="item" and self.depth==3 and self.item then self:_retain();self.item=nil end
  self.stack[self.depth]=nil;self.depth=self.depth-1
 end
 self.parser=lxp.new(callbacks,"|")
 return self
end
-- Bound unfinished XML tokens before Expat allocates a large attribute table.
-- Text is streamed; individual tags, comments, PIs and CDATA blocks cap at 64 KiB.
local openings={["<!--"]="-->",["<![CDATA["]="]]>",["<?"]="?>"}
function Reader:_guard(chunk)
 local at=1
 while at<=#chunk do
  if not self.lex then
   local found=chunk:find("<",at,true)
   local count=(found and found-at or #chunk-at+1)
   self.textBytes=(self.textBytes or 0)+count
   if self.textBytes>64*1024 then return nil end
   if not found then return true end
   self.textBytes=0
   self.lex="prefix";self.lexPrefix="<";self.lexBytes=1;at=found+1
  elseif self.lex=="prefix" then
   self.lexPrefix=self.lexPrefix..chunk:sub(at,at);self.lexBytes=self.lexBytes+1;at=at+1
   local possible=false
   for opening,ending in pairs(openings) do
    if opening:sub(1,#self.lexPrefix)==self.lexPrefix then
     possible=true
     if opening==self.lexPrefix then self.lex=ending;self.lexTail="";break end
    end
   end
   if not possible then self.lex="tag";self.lexQuote=nil end
  elseif self.lex=="tag" then
   local found=chunk:find(self.lexQuote and self.lexQuote or "[>\"']",at)
   local finish=found or #chunk
   self.lexBytes=self.lexBytes+finish-at+1
   if not found then at=#chunk+1
   else
    local char=chunk:sub(found,found);at=found+1
    if self.lexQuote then self.lexQuote=nil
    elseif char==">" then self.lex=nil
    else self.lexQuote=char end
   end
  else
   local tail=self.lexTail or "";local pending=tail..chunk:sub(at)
   local found=pending:find(self.lex,1,true)
   if found then
    local consumed=found+#self.lex-1-#tail;self.lexBytes=self.lexBytes+consumed
    at=at+consumed;self.lex=nil;self.lexTail=nil
   else
    self.lexBytes=self.lexBytes+#chunk-at+1;self.lexTail=pending:sub(-(#self.lex-1));at=#chunk+1
   end
  end
  if self.lexBytes and self.lexBytes>64*1024 then return nil end
 end
 return true
end
local function rootName(prefix)
 local rest=prefix:gsub("^"..string.char(239,187,191),"")
 while true do
  rest=rest:gsub("^%s+","")
  local ending
  if rest:sub(1,2)=="<?" then ending=rest:find("?>",3,true)
  elseif rest:sub(1,4)=="<!--" then ending=rest:find("-->",5,true);if ending then ending=ending+1 end
  else return rest:match("^<([%a_][%w_:%.%-]*)[%s/>]") end
  if not ending then return nil end
  rest=rest:sub(ending+2)
 end
end
function Reader:write(chunk)
 if not self.parser then return nil,"Directory parser is closed" end
 -- LuaExpat 1.0.2 has no DTD hook. Check before passing bytes to Expat.
 -- Reject NUL-containing UTF-16/32 so declarations cannot bypass this guard.
 local scan=((self.scanTail or "")..chunk):lower()
 if scan:find("%z") or scan:find("<!doctype",1,true) or scan:find("<!entity",1,true) then
  self:close();return nil,"Directory DTDs/entities or UTF-16/32 XML are not supported"
 end
 if not self:_guard(chunk) then self:close();return nil,"Directory XML token is too large" end
 self.scanTail=scan:sub(-10);self.bytes=self.bytes+#chunk
 if self.bytes>self.maxBytes then self:close();return nil,"Directory response is too large" end
 if self.kind=="opml" then
  if self.bytes>M.OPML_BYTES then self:close();return nil,"OPML response is too large" end
  self.raw[#self.raw+1]=chunk;return true
 end
 if not self.kind and not self.detected then
  chunk=(self.prefix or "")..chunk
  local root=rootName(chunk)
  if not root then
   if #chunk>8192 then self:close();return nil,"Directory XML preamble is too large" end
   self.prefix=chunk;return true
  end
  self.prefix=nil;self.detected=true
  if root:lower()=="opml" then
   if self.bytes>M.OPML_BYTES then self:close();return nil,"OPML response is too large" end
   self.kind="opml";self.raw={chunk};return true
  end
 end
 self.raw=nil
 local ok,result=pcall(function() return self.parser:parse(chunk) end)
 if not ok or not result then self:close();return nil,self.error or "Invalid or unsafe directory XML" end
 return true
end
function Reader:finish(base)
 if not self.parser then return nil,"Directory parser is closed" end
 if self.kind=="opml" then
  local body=table.concat(self.raw);self:close();return Opml.parse(body)
 end
 local ok,result=pcall(function() return self.parser:parse() end)
 if not ok or not result then self:close();return nil,self.error or "Incomplete or invalid directory XML" end
 if not self.hasChannel then self:close();return nil,"RSS feed has no channel" end
 local channel=self.channel
 channel.title=text(channel.title,512);channel.description=text(channel.description or channel["itunes:summary"],2048)
 channel.image=remote(base,text(channel.image,4096)) or remote(base,text(channel.rssImage,4096))
 channel.author=text(channel["itunes:author"] or channel["dc:creator"] or channel.author or channel.managingeditor,1024)
 channel.language=text(channel.language,96)
 channel.link=remote(base,text(channel.link,4096))
 local entries={}
 for _,e in ipairs(self.episodes) do
  e.url=remote(base,e.url)
  if e.url then
   e.image=remote(base,e.image) or channel.image;e.podcast=channel.title;e.author=channel.author;e.language=channel.language
   e.homepage=remote(base,text(e.link,4096)) or channel.link;entries[#entries+1]=e
  end
 end
 self:close();self.episodes=nil;self.channel=nil
 return {type="directory",format="rss",title=channel.title,channel=channel,children=entries,skipped=self.skipped,limited=self.items>#entries}
end
return M
