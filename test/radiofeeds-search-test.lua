-- Exercise the real keyboard submit handler without loading Jive's UI.
local file = assert(io.open("applet/StandaloneRadio/StandaloneRadioApplet.lua", "rb"))
local source = file:read("*a")
file:close()
local code = assert(source:match("(local function urlEncode.-)function _radioFeedsItems"))
local submit
local textinput = setmetatable({textValue=function() return {} end}, {
	__call=function(_, _, _, callback) submit=callback; return {} end,
})
local window = {addWidget=function() end, focusWidget=function() end}
local env = setmetatable({
	Textinput=textinput,
	Window=function() return window end,
	Group=function() return {} end,
	Keyboard=setmetatable({backspace=function() return {} end}, {__call=function() return {} end}),
}, {__index=_G})
local chunk
if setfenv then
	chunk=assert(loadstring(code)); setfenv(chunk, env)
else
	chunk=assert(load(code, "RadioFeeds search UI", "t", env))
end
chunk()
local requests={}
local applet={
	tieAndShowWindow=function() end,
	_showRadioFeedsSearchResults=function(_, url, title) requests[#requests+1]={url=url,title=title} end,
}
local template="http://www.radiofeeds.co.uk/MyPicks/integsearchall.opml?term={QUERY}&username=forusewithstandalone&search=1&center=1"
env._showRadioFeedsSearch(applet, {title="Search All Radio by Name",url=template})
assert(submit(nil,"BBC Radio 2"))
assert(requests[1].url==template:gsub("{QUERY}",function() return "BBC%20Radio%202" end))
assert(requests[1].title=="Search All Radio by Name")
assert(submit(nil,"  Jazz & 100% + café  "))
assert(requests[2].url==template:gsub("{QUERY}",function() return "Jazz%20%26%20100%25%20%2B%20caf%C3%A9" end))
assert(submit(nil,"KINK"))
assert(requests[3].url==template:gsub("{QUERY}","KINK"))
assert(submit(nil,"   ")==false)
assert(#requests==3)

-- Run the actual results and root-menu methods against asynchronous Jive mocks.
local menus, pending = {}, {}
env.SimpleMenu=setmetatable({itemComparatorWeightAlpha=function() end}, {__call=function()
	local menu={setComparator=function() end,reLayout=function() end,
		setItems=function(self,items) self.items=items end}
	menus[#menus+1]=menu
	return menu
end})
env.log={warn=function() end}
env.Stations={displayName=function(station) return station.name end}
env._logInfo=function() end
local function loadMethod(code)
	local fn
	if setfenv then fn=assert(loadstring(code));setfenv(fn,env)
	else fn=assert(load(code,"RadioFeeds results", "t", env)) end
	fn()
end
loadMethod(assert(source:match("(function _stationItems.-)function _showStationList")))
loadMethod(assert(source:match("(function _radioFeedsItems.-)function _showCountryMenu")))
local resultsApplet={
	string=function(_,key) return key end,
	_ensureComponents=function() return true end,
	tieAndShowWindow=function() end,
	_stationItems=env._stationItems,
	_radioFeedsItems=env._radioFeedsItems,
	_showRadioFeedsSearch=env._showRadioFeedsSearch,
	_playStation=function(self,station) self.played=station end,
	radioFeeds={
		rootUrl=function() return "root" end,
		searchUrl=function() return template end,
		fetchDirectory=function(_,url,callback) pending[#pending+1]={url=url,callback=callback} end,
		toStation=function(_,item)
			if not item.url then return nil end
			return {name=item.title,url=item.url,source="radiofeeds",playlistUrl=item.url}
		end,
	},
}
resultsApplet._showRadioFeedsSearchResults=env._showRadioFeedsSearchResults
resultsApplet:_showRadioFeedsSearch()
assert(submit(nil,"BBC Radio 2"))
assert(pending[1].url:find("term=BBC%20Radio%202",1,true))
local results=menus[#menus]
assert(results.items[1].text=="STANDALONE_RADIO_LOADING")
pending[1].callback({children={
	{type="text",title="Section heading"},
	{type="audio",title="BBC Radio 2",url="http://example.invalid/bbc.m3u"},
	{type="directory",children={{type="audio",title="Nested",url="http://example.invalid/nested.pls"}}},
	{type="audio",title="Invalid"},
}})
assert(#results.items==2)
assert(results.items[1].text=="BBC Radio 2")
results.items[1].callback()
assert(resultsApplet.played.source=="radiofeeds")
assert(resultsApplet.played.playlistUrl=="http://example.invalid/bbc.m3u")
resultsApplet:_showRadioFeedsSearchResults("empty","Search")
pending[2].callback({children={{type="text",title="No matches"}}})
assert(menus[#menus].items[1].text=="STANDALONE_RADIO_NO_STATIONS")
resultsApplet:_showRadioFeedsSearchResults("error","Search")
pending[3].callback(nil,"network failure")
assert(menus[#menus].items[1].text=="STANDALONE_RADIO_RADIOFEEDS_FAILED")
resultsApplet:_showRadioFeedsSearchResults("old","Search")
local staleMenu=menus[#menus]
resultsApplet:_showRadioFeedsSearchResults("new","Search")
pending[4].callback({children={}})
assert(staleMenu.items[1].text=="STANDALONE_RADIO_LOADING")
pending[5].callback({children={}})

env.radioFeedsMenu(resultsApplet,"root","RadioFeeds")
local rootMenu=menus[#menus]
assert(rootMenu.items[1].text=="STANDALONE_RADIO_SEARCH")
pending[6].callback({children={
	{type="search",title="Provider search",url=template},
	{type="link",title="Locations",url="locations"},
}})
assert(#rootMenu.items==2)
assert(rootMenu.items[1].text=="STANDALONE_RADIO_SEARCH")
assert(rootMenu.items[2].text=="Locations")
rootMenu.items[1].callback()
assert(submit(nil,"Classic FM"))
assert(pending[7].url:find("term=Classic%20FM",1,true))

print("RadioFeeds keyboard search tests passed")
