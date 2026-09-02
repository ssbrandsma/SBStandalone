local ipairs, tonumber, tostring, type = ipairs, tonumber, tostring, type

local string = require("string")

module(...)


local stations = {
	{ id = "npo1", nameToken = "STANDALONE_RADIO_NPO1", url = "http://icecast.omroep.nl/radio1-bb-mp3", logo = "images/radio.png", preset = 1 },
	{ id = "npo2", nameToken = "STANDALONE_RADIO_NPO2", url = "http://icecast.omroep.nl/radio2-bb-mp3", logo = "images/radio.png", preset = 2 },
	{ id = "radio538", nameToken = "STANDALONE_RADIO_538", url = "http://28513.live.streamtheworld.com/RADIO538.mp3", logo = "images/radio.png", preset = 3 },
	{ id = "radio10", nameToken = "STANDALONE_RADIO_10", url = "http://25683.live.streamtheworld.com/RADIO10.mp3", logo = "images/radio.png", preset = 4 },
	{ id = "veronica", nameToken = "STANDALONE_RADIO_VERONICA", url = "http://27903.live.streamtheworld.com/VERONICA.mp3", logo = "images/radio.png", preset = 5 },
	{ id = "bnr", nameToken = "STANDALONE_RADIO_BNR", url = "http://stream.bnr.nl/bnr_mp3_128_20", logo = "images/radio.png", preset = 6 },
}

local byId = {}
local byPreset = {}


local function parseUrl(station)
	local host, port, path = string.match(station.url, "^http://([^/:]+):?(%d*)(/.*)$")
	if not host then
		return nil, "URL must be an HTTP URL with a path"
	end

	station.host = host
	station.port = (port == "" and 80) or tonumber(port)
	station.path = path
	return true
end


local function stationName(station)
	if not station then
		return ""
	end
	return station.name or station.id or station.nameToken or ""
end


function normalize(station)
	if not station then
		return nil, "station required"
	end

	local parsed, err = parseUrl(station)
	if not parsed then
		return nil, err
	end

	if not station.id or station.id == "" then
		station.id = station.stationuuid or stationName(station)
	end
	if station.id then
		station.id = tostring(station.id)
	end
	if station.name then
		station.name = tostring(station.name)
	end
	return station
end


function validate(log)
	byId = {}
	byPreset = {}
	for _, station in ipairs(stations) do
		local valid = type(station.id) == "string" and station.id ~= ""
			and type(station.nameToken) == "string" and station.nameToken ~= ""
			and type(station.logo) == "string" and station.logo ~= ""
			and type(station.preset) == "number"
			and type(station.url) == "string"
		if not valid or byId[station.id] or byPreset[station.preset] then
			log:error("StandaloneRadio: invalid or duplicate station configuration")
			return false
		end

		local parsed, err = normalize(station)
		if not parsed then
			log:error("StandaloneRadio: invalid station URL for ", station.id, ": ", err)
			return false
		end

		byId[station.id] = station
		byPreset[station.preset] = station
	end

	return true
end


function all()
	return stations
end


function getById(id)
	return byId[id]
end


function getByPreset(preset)
	return byPreset[preset]
end


function displayName(station, applet)
	if station.name then
		return station.name
	end
	if station.nameToken and applet then
		return tostring(applet:string(station.nameToken))
	end
	return stationName(station)
end
