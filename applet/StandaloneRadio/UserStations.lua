local io, ipairs, pairs, pcall, setmetatable, tonumber, tostring, type = io, ipairs, pairs, pcall, setmetatable, tonumber, tostring, type

local string = require("string")
local table = require("table")
local json = require("json")

local Stations = require("applets.StandaloneRadio.Stations")

module(...)

local UserStations = {}
UserStations.__index = UserStations

local CONFIG_PATH = "/mnt/sbdata/config/radio/stations.json"
local LOGO_ROOT = "/mnt/sbdata/config/radio/logos/"
local MAX_BYTES = 256 * 1024
local MAX_STATIONS = 250
local CODECS = { auto=true, mp3=true, aac=true, ogg=true, flac=true }

local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function integer(value)
	return type(value) == "number" and value == value and value % 1 == 0
end

local function validUtf8(value)
	if type(value) ~= "string" then return false end
	local i, n = 1, #value
	while i <= n do
		local b = string.byte(value, i)
		if b < 0x80 then
			if b < 0x20 and b ~= 9 and b ~= 10 and b ~= 13 then return false end
			i = i + 1
		else
			local count = b >= 0xC2 and b <= 0xDF and 2
				or b >= 0xE0 and b <= 0xEF and 3
				or b >= 0xF0 and b <= 0xF4 and 4
			if not count or i + count - 1 > n then return false end
			local b2 = string.byte(value, i + 1)
			if b2 < 0x80 or b2 > 0xBF then return false end
			if count >= 3 then
				local b3 = string.byte(value, i + 2)
				if b3 < 0x80 or b3 > 0xBF then return false end
				if (b == 0xE0 and b2 < 0xA0) or (b == 0xED and b2 > 0x9F) then return false end
			end
			if count == 4 then
				local b4 = string.byte(value, i + 3)
				if b4 < 0x80 or b4 > 0xBF then return false end
				if (b == 0xF0 and b2 < 0x90) or (b == 0xF4 and b2 > 0x8F) then return false end
			end
			i = i + count
		end
	end
	return true
end

local function validString(value, maximum, required)
	return type(value) == "string" and #value <= maximum and validUtf8(value)
		and (not required or #value > 0)
end

local function safeComponent(value, maximum, allowDot)
	if not validString(value, maximum, true) or string.find(value, "..", 1, true) then return false end
	if not string.match(value, "^[%w%._%-]+$") then return false end
	return allowDot or not string.find(value, ".", 1, true)
end

local function validUrl(value, optional)
	if optional and value == "" then return true end
	return validString(value, 8192, true)
		and string.match(value, "^https?://[^/%s]+/.*") ~= nil
end

local function cacheSuffix(value)
	local hash = 5381
	for index = 1, #value do hash = (hash * 33 + string.byte(value, index)) % 2147483647 end
	return tostring(hash)
end

local function readBounded(path)
	local file, err = io.open(path, "rb")
	if not file then return nil, err or "configuration unavailable" end
	local size = file:seek("end")
	if not size or size <= 0 or size > MAX_BYTES or not file:seek("set", 0) then
		file:close()
		return nil, size and size > MAX_BYTES and "configuration exceeds 256 KiB" or "configuration is empty"
	end
	local body = file:read(size)
	file:close()
	if type(body) ~= "string" or #body ~= size then return nil, "configuration read failed" end
	return body
end

local function normalize(raw)
	if type(raw) ~= "table" then return nil, "station is not an object" end
	if not safeComponent(raw.id, 64, false) then return nil, "invalid id" end
	if not validString(raw.name, 256, true) then return nil, "invalid name" end
	if not validUrl(raw.streamUrl, false) or #raw.streamUrl > 8192 then return nil, "invalid streamUrl" end
	if type(raw.enabled) ~= "boolean" then return nil, "invalid enabled" end
	if not integer(raw.order) then return nil, "invalid order" end
	local description = raw.description == nil and "" or raw.description
	local logoUrl = raw.logoUrl == nil and "" or raw.logoUrl
	local logoFile = raw.logoFile == nil and "" or raw.logoFile
	local codec = raw.codec == nil and "auto" or string.lower(raw.codec)
	if not validString(description, 1024, false) then return nil, "invalid description" end
	if not validString(logoUrl, 4096, false) or not validUrl(logoUrl, true) then return nil, "invalid logoUrl" end
	if not validString(logoFile, 128, false)
		or (logoFile ~= "" and not safeComponent(logoFile, 128, true)) then return nil, "invalid logoFile" end
	if type(codec) ~= "string" or not CODECS[codec] then return nil, "invalid codec" end

	local station = {
		id = raw.id, stationuuid = "user-" .. raw.id .. "-" .. cacheSuffix(logoFile ~= "" and logoFile or logoUrl), name = raw.name,
		description = description, url = raw.streamUrl, streamUrl = raw.streamUrl,
		source = "user", codec = codec, order = raw.order,
		remoteLogo = logoUrl ~= "" and logoUrl or nil,
		favicon = logoUrl ~= "" and logoUrl or nil,
		logoFile = logoFile ~= "" and logoFile or nil,
		localLogoPath = logoFile ~= "" and (LOGO_ROOT .. logoFile) or nil,
	}
	local ok, err = Stations.normalize(station)
	if not ok then return nil, err end
	return station
end

local function compare(left, right)
	if left.order ~= right.order then return left.order < right.order end
	local leftName, rightName = string.lower(left.name), string.lower(right.name)
	if leftName ~= rightName then return leftName < rightName end
	return left.id < right.id
end

function new(options)
	options = options or {}
	return setmetatable({
		path = options.path or CONFIG_PATH,
		readFile = options.readFile,
		decoder = options.decoder or json.decode,
		log = options.log,
		stations = {}, byId = {},
	}, UserStations)
end

function UserStations:_log(level, ...)
	if self.log and self.log[level] then self.log[level](self.log, "StandaloneRadio UserStations: ", ...) end
end

function UserStations:_read()
	if self.readFile then return self.readFile(self.path, MAX_BYTES) end
	return readBounded(self.path)
end

function UserStations:reload()
	local body, readErr = self:_read()
	if not body then
		self:_log("warn", "configuration unavailable: ", tostring(readErr))
		return self.stations, readErr or "configuration unavailable", false
	end
	local ok, root = pcall(self.decoder, body)
	if not ok or type(root) ~= "table" then
		self:_log("warn", "invalid JSON")
		return self.stations, "invalid JSON", false
	end
	if root.schemaVersion ~= 1 then
		self:_log("warn", "unsupported schemaVersion=", tostring(root.schemaVersion))
		return self.stations, "unsupported schema version", false
	end
	local validRevision = type(root.revision) == "number" and root.revision == root.revision
		and root.revision >= 0 and root.revision % 1 == 0
	if not validRevision or type(root.stations) ~= "table" then
		self:_log("warn", "invalid root structure revisionType=", type(root.revision),
			" revision=", tostring(root.revision), " stationsType=", type(root.stations))
		return self.stations, "invalid root structure", false
	end

	local stations, byId, seen = {}, {}, {}
	for index, raw in ipairs(root.stations) do
		if index > MAX_STATIONS then
			self:_log("warn", "stations after limit skipped")
			break
		end
		local station, stationErr = normalize(raw)
		if not station then
			self:_log("warn", "invalid station skipped index=", tostring(index), " reason=", tostring(stationErr))
		elseif seen[station.id] then
			self:_log("warn", "duplicate station id skipped id=", station.id)
		else
			seen[station.id] = true
			if raw.enabled then stations[#stations + 1] = station; byId[station.id] = station end
		end
	end
	table.sort(stations, compare)
	local changed = self.revision ~= root.revision
	if changed then
		self.stations, self.byId, self.revision = stations, byId, root.revision
		self:_log("info", "revision=", tostring(root.revision), " enabled=", tostring(#stations))
	end
	return self.stations, nil, changed
end

function UserStations:resolve(id)
	local _, err = self:reload()
	if err and not self.revision then return nil, err end
	local station = self.byId[tostring(id or "")]
	if not station then return nil, "station is unavailable" end
	return station
end

function limits()
	return { maxBytes=MAX_BYTES, maxStations=MAX_STATIONS, path=CONFIG_PATH, logoRoot=LOGO_ROOT }
end
