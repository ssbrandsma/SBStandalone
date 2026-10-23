local Navigator=dofile("applet/StandaloneRadio/OpmlNavigator.lua")
local pending,windows,played,searchSubmit={},{}
local client={rootUrl=function() return "root" end,searchUrl=function() return "search?term={QUERY}" end,
    toStation=function(_,entry) if entry.url then return {name=entry.title,url=entry.url,source="radiofeeds",playlistUrl=entry.url} end end,
    fetchDirectory=function(_,url,callback)
        local request={url=url,callback=callback};pending[#pending+1]=request
        return function() request.cancelled=true end
    end}
local ui={text=function(key) return key end,error=function() end,
    window=function(title)
        local menu={setItems=function(self,items) self.items=items end,reLayout=function() end}
        local window={title=title,menu=menu};windows[#windows+1]=window;return window,menu
    end,
    listen=function(window,inactive,pop,active) window.inactive=inactive;window.pop=pop;window.active=active end,
    show=function() end,play=function(station) played=station end,
    search=function(_,submit) searchSubmit=submit end,
    stations=function(stations) local result={};for _,station in ipairs(stations) do result[#result+1]={text=station.name} end;return #result>0 and result or {{text="empty"}} end}
local nav=Navigator.new({client=client,ui=ui})
nav:open("root","RadioFeeds")
local root=windows[1]
assert(root.menu.items[1].text=="search")
pending[1].callback({children={{type="search",title="Provider Search",url="duplicate"},{type="link",title="Locations",url="locations"},
    {type="directory",title="Inline",children={{type="audio",title="Station",url="http://example.com/live"}}}}})
assert(#root.menu.items==3)
root.menu.items[3].callback();windows[2].menu.items[1].callback();assert(played.source=="radiofeeds")
root.menu.items[2].callback();assert(pending[2].url=="locations")
windows[3].pop();assert(pending[2].cancelled)
pending[2].callback({children={{type="text",title="late"}}});assert(#windows[3].menu.items==0)
nav:open("error","Error");pending[3].callback(nil,"network failure")
windows[4].menu.items[1].callback();assert(pending[4].url=="error")
pending[4].callback({children={}});assert(windows[4].menu.items[1].text=="empty")
nav:open("old","Old");local old=windows[5]
nav:open("new","New");assert(pending[5].cancelled)
pending[5].callback({children={}});assert(old.menu.items[1].text=="loading")
pending[6].callback({children={}})
nav:open("parent","Parent");local parent=windows[7]
parent.inactive();assert(pending[7].cancelled)
parent.active();assert(pending[8].url=="parent")
pending[8].callback({children={}})
nav:search();local stale=searchSubmit
nav:close();stale("search?term=old");assert(#pending==8)
nav:search();searchSubmit("search?term=bbc");pending[9].callback({children={{type="text",title="heading"},{type="directory",children={{type="audio",title="BBC",url="http://example.com/bbc"}}}}})
assert(windows[#windows].menu.items[1].text=="BBC")
for i=1,20 do nav:open("root","RadioFeeds");windows[#windows].pop() end
nav:close();assert(next(nav.contexts)==nil)
print("Generic navigator RadioFeeds hierarchy/search/playback, retry, cancellation, stale callbacks and repeated lifecycle tests passed")

nav:close();local errors=0;ui.error=function() errors=errors+1 end
local clock=0;nav=Navigator.new({client=client,ui=ui,clock=function() return clock end,cacheTtl=60})
local count=#pending
local w=nav:open("cycle","Cycle");pending[#pending].callback({url="cycle",children={{type="link",title="Self",url="cycle"}}})
w.menu.items[1].callback();assert(errors==1 and #pending==count+1)
w.inactive();clock=61;w.active();assert(#pending==count+2)
pending[#pending].callback({url="cycle",children={}})
nav:close()
for i=1,12 do assert(nav:open("depth-"..i,"Depth")) end
assert(nav:open("depth-13","Too deep")==nil)
nav:close()
print("OPML navigation cycles, TTL refresh and bounded traversal passed")
