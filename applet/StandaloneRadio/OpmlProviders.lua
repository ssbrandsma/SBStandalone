local M={}
local function stationKey(url)
	local hash = 5381
	for index = 1, #url do hash = (hash * 33 + string.byte(url, index)) % 2147483647 end
	return "rf" .. tostring(hash)
end

local function stationCodec(item)
	local explicit = string.lower(tostring(item.codec or ""))
	if explicit ~= "" then return explicit end
	local title = string.lower(tostring(item.title or ""))
	if string.find(title, "(aacplus)", 1, true) or string.find(title, "(aac+)", 1, true) then return "aac+" end
	if string.find(title, "%(aac[%s%)]") then return "aac" end
	if string.find(title, "(ogg)", 1, true) then return "ogg" end
	if string.find(title, "(flac)", 1, true) then return "flac" end
	if string.find(title, "(aiff)", 1, true) or string.find(title, "(aif)", 1, true) then return "aif" end
	if string.find(title, "(pcm)", 1, true) then return "pcm" end
	return "mp3"
end


local function encode(value)
    return (tostring(value):gsub("([^A-Za-z0-9%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end))
end
function M.get(id, options)
    if id=="radiofeeds" then
        return {id=id,name="RadioFeeds",
            stationKey=function(item) return stationKey(item.url) end,
            decorateStation=function(station,item)
                local key=stationKey(item.url)
                station.id="radiofeeds:"..key;station.stationuuid=key
                station.codec=stationCodec(item);station.declaredCodec=station.codec
            end,root="http://www.radiofeeds.co.uk/MyPicks/menu.opml?username=forusewithstandalone",
            search="http://www.radiofeeds.co.uk/MyPicks/integsearchall.opml?term={QUERY}&username=forusewithstandalone&search=1&center=1"}
    end
    assert(id=="tunein","unknown OPML provider")
    -- No borrowed partner IDs, user location, account credentials or bypasses.
    local partner=options and options.partnerId
    local function prepare(url)
        if not url:match("^https?://opml%.radiotime%.com/") then return url end
        -- Preserve provider links: forcing HTTPS fails with the radio TLS stack.
        if partner and partner~="" and not url:lower():find("partnerid=",1,true) then
            url=url..(url:find("?",1,true) and "&" or "?").."partnerId="..encode(partner)
        end
        return url
    end
    return {id=id,name="TuneIn",requiresResolution=true,root=prepare("http://opml.radiotime.com/Browse.ashx"),
        search=prepare("http://opml.radiotime.com/Search.ashx?query={QUERY}"),prepareUrl=prepare,
        isResolver=function(url) return url:lower():match("^https?://opml%.radiotime%.com/tune%.ashx[?]")~=nil end}
end
return M
