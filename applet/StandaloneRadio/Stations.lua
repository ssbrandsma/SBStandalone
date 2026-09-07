local tonumber, tostring = tonumber, tostring

local string = require("string")

module(...)

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


function displayName(station, applet)
	if station.name then
		return station.name
	end
	if station.nameToken and applet then
		return tostring(applet:string(station.nameToken))
	end
	return stationName(station)
end
