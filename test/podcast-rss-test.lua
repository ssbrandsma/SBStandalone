local Parser=require("applets.StandaloneRadio.PodcastRssParser")
local function parse(xml,options)
 local reader=Parser.new(options)
 for at=1,#xml,37 do local ok,err=reader:write(xml:sub(at,at+36));if not ok then return nil,err end end
 return reader:finish("https://example.org/feed/news.rss")
end
local f=assert(io.open("test/fixtures/podcasts/bbc-style.rss","rb"));local body=f:read("*a");f:close()
local result,err=parse(body);assert(result,tostring(err));assert(result.format=="rss" and #result.children==3)
local e=result.children[1]
assert(e.title=="Latest & current" and e.podcast=="News & Stories")
assert(e.description=="World news" and e.pubDate and e.guid=="new")
assert(e.url=="https://example.org/feed/new.mp3?key=x%2Fy&b=2" and e.codec=="mp3")
assert(e.image=="https://example.org/feed/art/new.jpg" and e.duration_ms==3723000 and e.episodeNumber==42)
assert(e.enclosureLength==123456 and e.enclosureType=="audio/mpeg" and e.author=="BBC")
assert(result.children[2].title=="Older" and result.children[2].image=="https://example.org/channel.jpg")
assert(result.children[3].codec=="aac_mp4" and result.skipped==1)
assert(Parser.date("Thu, 01 Jan 1970 00:00:00 GMT")==0)
assert(Parser.date("Thu, 01 Jan 1970 02:00:00 +0200")==0)
assert(not Parser.date("Tue, 30 Feb 2026 00:00:00 GMT"))
assert(Parser.duration("03:12")==192000 and Parser.duration("123")==123000 and not Parser.duration("bad"))
for _,xml in ipairs({'<rss><channel><item></channel></rss>','<rss><channel>','<rss/>','<feed/>',
 '<!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]><rss><channel>&secret;</channel></rss>',
 '<!DOCTYPE rss [<!ENTITY a "EXPAND">]><rss><channel>&a;</channel></rss>'}) do
 local value,error=parse(xml);assert(not value and error,"unsafe/truncated XML accepted")
end
local empty=assert(parse('<rss><channel><title>Empty</title><item><enclosure type="video/mp4" url="v.mp4"/></item></channel></rss>'))
assert(#empty.children==0 and not empty.channel.image)
local channel=assert(parse('<rss><channel><title>Podcast</title><item><title>Plain</title><enclosure type="audio/aacp" url="/audio"/></item></channel></rss>'))
assert(channel.children[1].codec=="aac+" and not channel.children[1].image)
-- Feed in many chunks: no document or tree is retained, only the best 50 entries.
local reader=Parser.new();assert(reader:write('<rss><channel><title>Large</title>'))
for i=1,2000 do
 local episode='<item><title>Episode '..i..'</title><description>'..string.rep('long description ',100)..'</description><guid>'..i..'</guid><enclosure type="audio/mpeg" url="https://example.org/'..i..'.mp3"/></item>'
 assert(reader:write(episode));assert(reader.raw==nil and #reader.episodes<=50)
end
assert(reader.bytes>256*1024 and reader.bytes<Parser.MAX_BYTES)
assert(reader:write('</channel></rss>'));local large=assert(reader:finish('https://example.org/feed'))
assert(#large.children==50 and large.children[1].title=="Episode 1" and large.limited)
local small=assert(parse(body,{maxEpisodes=1}));assert(#small.children==1 and small.children[1].guid=="new")
local limited=Parser.new({maxBytes=128});assert(not limited:write(body))
local opml=assert(parse('<opml><body><outline text="RSS" type="rss" URL="https://example.org/feed.rss"/></body></opml>'))
assert(opml.children[1].type=="link")
assert(not parse('<opml><body>'..string.rep(' ',256*1024)..'</body></opml>'))
local nested='<rss><channel>'..string.rep('<x>',40)..string.rep('</x>',40)..'</channel></rss>'
assert(not parse(nested))
print('RSS SAX metadata, namespaces, entities/CDATA, dates, enclosures, ordering, artwork, limits, large feeds, unsafe/truncated XML and OPML delegation passed')

local legacy=assert(parse('<?xml version="1.0"?><!-- root comment --><opml><body><outline text="Music &nbsp; News" type="rss" xmlUrl="feed.rss" htmlUrl="https://example.org/page"/></body></opml>'))
assert(legacy.children[1].type=="link" and legacy.children[1].url=="feed.rss")
assert(legacy.children[1].title:find("Music",1,true))
local guard=Parser.new();assert(guard:write('<!DOC'));assert(not guard:write('TYPE rss><rss/>'))
local utf16=Parser.new();assert(not utf16:write(string.char(255,254,60,0,114,0)))

for _,xml in ipairs({'<rss><channel><item a="'..string.rep('>',66000)..'"/></channel></rss>',
 '<rss><channel><!--'..string.rep('x',66000)..'--></channel></rss>',
 '<rss><channel><description><![CDATA['..string.rep('x',66000)..']]></description></channel></rss>'}) do
 local value,error=parse(xml);assert(not value and error:find("token"))
end

assert(not Parser.duration("01:99") and not Parser.duration("1:70:00"))
assert(not parse("<rss><channel><description>"..string.rep("x",66000).."</description></channel></rss>"))
