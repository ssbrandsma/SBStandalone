local ipairs, setmetatable, tonumber, tostring = ipairs, setmetatable, tonumber, tostring

local Stations = require("applets.StandaloneRadio.Stations")

module(...)


local PresetStore = {}
PresetStore.__index = PresetStore


local function clonePreset(station, preset)
	local copy = {
		id = station.id,
		stationuuid = station.stationuuid,
		name = station.name,
		nameToken = station.nameToken,
		url = station.url,
		favicon = station.favicon or station.remoteLogo,
		logo = station.logo,
		logoPath = station.logoPath,
		remoteLogo = station.remoteLogo,
		source = station.source or "builtin",
		codec = station.codec,
		bitrate = station.bitrate,
		countrycode = station.countrycode,
		preset = preset,
	}
	Stations.normalize(copy)
	return copy
end


function new(options)
	local store = setmetatable({
		applet = options.applet,
		log = options.log,
		settings = options.settings,
	}, PresetStore)
	store:_migrateDefaults()
	return store
end


function PresetStore:_migrateDefaults()
	if self.settings.presets then
		return
	end

	self.settings.presets = {}
	for _, station in ipairs(Stations.all()) do
		if station.preset then
			self.settings.presets[station.preset] = clonePreset(station, station.preset)
		end
	end
	self.applet:storeSettings()
	self.log:info("StandaloneRadio: initialized default presets")
end


function PresetStore:getPreset(number)
	local preset = self.settings.presets and (self.settings.presets[number] or self.settings.presets[tostring(number)])
	if not preset then
		return nil
	end

	preset.preset = number
	local ok = Stations.normalize(preset)
	if not ok then
		self.log:warn("StandaloneRadio: invalid saved preset ", tostring(number))
		return nil
	end
	return preset
end


function PresetStore:all()
	local presets = {}
	for i = 1, 6 do
		presets[i] = self:getPreset(i)
	end
	return presets
end


function PresetStore:assign(number, station)
	number = tonumber(number)
	if not number or number < 1 or number > 6 or not station then
		return false
	end

	local saved = clonePreset(station, number)
	self.settings.presets[number] = saved
	self.applet:storeSettings()
	self.log:info("StandaloneRadio: preset ", tostring(number), " saved")
	return saved
end


function PresetStore:updateLogo(station)
	if not station or not self.settings.presets then
		return
	end

	for i = 1, 6 do
		local preset = self.settings.presets[i] or self.settings.presets[tostring(i)]
		if preset and (
			(station.stationuuid and preset.stationuuid == station.stationuuid)
			or (station.id and preset.id == station.id)
		) then
			preset.favicon = station.favicon or station.remoteLogo or preset.favicon
			preset.remoteLogo = station.remoteLogo or station.favicon or preset.remoteLogo
			preset.logoPath = station.logoPath or preset.logoPath
			self.applet:storeSettings()
			self.log:info("StandaloneRadio: preset ", tostring(i), " logo updated")
		end
	end
end
