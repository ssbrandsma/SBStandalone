-- Exercise the real applet UI adapter with simulated Jive windows/events.
local f=assert(io.open("applet/StandaloneRadio/StandaloneRadioApplet.lua","rb"));local source=f:read("*a");f:close()
OpmlNavigator=dofile("applet/StandaloneRadio/OpmlNavigator.lua")
EVENT_WINDOW_INACTIVE,EVENT_WINDOW_POP,EVENT_WINDOW_ACTIVE=1,2,3
local windows,pending={},{}
Window=function(_,title)
    local window={title=title,listeners={},addWidget=function(self,menu) self.menu=menu end,
        addListener=function(self,event,callback) self.listeners[event]=callback end}
    windows[#windows+1]=window;return window
end
SimpleMenu=setmetatable({itemComparatorWeightAlpha=function() end},{__call=function()
    return {setComparator=function() end,setItems=function(self,items) self.items=items end,reLayout=function() end}
end})
log={warn=function() end}
local function client(id)
    return {rootUrl=function() return id.."-root" end,searchUrl=function() return id.."-search?query={QUERY}" end,
        toStation=function(_,entry) return {name=entry.title,url=entry.url,provider=id,source=id} end,
        fetchDirectory=function(_,url,callback)
            local request={url=url,callback=callback};pending[#pending+1]=request
            return function() request.cancelled=true end
        end}
end
local rf,tune=client("radiofeeds"),client("tunein")
local applet={radioFeeds=rf,opmlClients={radiofeeds=rf,tunein=tune},
    string=function(_,token) return token end,
    _playStation=function(self,station) self.played=station end,
    _showOpmlStationActions=function(self,station) self.actions=station end,
    _showPopup=function() error("unexpected popup") end,
    _stationItems=function(self,stations)
        local items={};for _,station in ipairs(stations) do local selected=station;items[#items+1]={text=selected.name,callback=function() self:_playStation(selected) end} end;return items
    end,
    tieAndShowWindow=function(self,window)
        if self.current then self.current.listeners[EVENT_WINDOW_INACTIVE]() end
        self.current=window;window.listeners[EVENT_WINDOW_ACTIVE]()
    end,
    _showOpmlSearchInput=function(self,entry,submit,cancel)
        if self.current then self.current.listeners[EVENT_WINDOW_INACTIVE]() end
        self.searchSubmit=submit;self.searchCancel=cancel
    end}
assert((loadstring or load)(assert(source:match("(function _getOpmlNavigator.-)function _showOpmlSearchInput"))))()
applet._getOpmlNavigator=_getOpmlNavigator
local nav=applet:_getOpmlNavigator("tunein")
nav:open(tune:rootUrl(),"TuneIn")
pending[1].callback({children={{type="audio",title="1 Vallei",url="https://example.com/resolver"}}})
local row=windows[1].menu.items[2]
row.cmCallback();assert(applet.actions.provider=="tunein")
row.callback();assert(applet.played.name=="1 Vallei")
windows[1].menu.items[1].callback()
applet.searchSubmit("tunein-search?query=Vallei")
assert(pending[2].url=="tunein-search?query=Vallei")
pending[2].callback({children={{type="audio",title="Found",url="https://example.com/found"}}})
windows[2].menu.items[1].callback();assert(applet.played.name=="Found")
nav:search();local stale=applet.searchSubmit;applet.searchCancel();stale("late");assert(#pending==2)
nav:open("slow","Slow")
applet:_getOpmlNavigator("radiofeeds")
assert(pending[3].cancelled and next(nav.contexts)==nil)
pending[3].callback({children={{type="audio",title="Stale",url="https://example.com/stale"}}})
assert(applet.played.name=="Found")
print("Applet OPML UI adapter: search keyboard lifetime, station actions/playback and provider switching passed")
