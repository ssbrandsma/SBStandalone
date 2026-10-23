-- Exercise the real keyboard submit handler without loading Jive's UI.
local file = assert(io.open("applet/StandaloneRadio/StandaloneRadioApplet.lua", "rb"))
local source = file:read("*a")
file:close()
local code = assert(source:match("(local function urlEncode.-)function _showRadioFeedsSearch%(self,entry%)"))
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
env._showOpmlSearchInput(applet, {title="Search All Radio by Name",url=template},function(url) applet:_showRadioFeedsSearchResults(url,"Search All Radio by Name") end)
assert(submit(nil,"BBC Radio 2"))
assert(requests[1].url==template:gsub("{QUERY}",function() return "BBC%20Radio%202" end))
assert(requests[1].title=="Search All Radio by Name")
assert(submit(nil,"  Jazz & 100% + café  "))
assert(requests[2].url==template:gsub("{QUERY}",function() return "Jazz%20%26%20100%25%20%2B%20caf%C3%A9" end))
assert(submit(nil,"KINK"))
assert(requests[3].url==template:gsub("{QUERY}","KINK"))
assert(submit(nil,"   ")==false)
assert(#requests==3)


print("RadioFeeds keyboard search encoding tests passed")
