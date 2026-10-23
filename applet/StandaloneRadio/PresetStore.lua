local ipairs, setmetatable, tonumber, tostring, type = ipairs, setmetatable, tonumber, tostring, type

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
		source = station.source or "user",
		codec = station.codec,
		hls = station.hls,
		bitrate = station.bitrate,
		playlistUrl = station.playlistUrl,
		countrycode = station.countrycode,
		preset = preset,
		provider = station.provider, providerId = station.providerId,
		resolverUrl = station.resolverUrl, declaredCodec = station.declaredCodec,
		declaredFormats = station.declaredFormats, description = station.description,
		genre = station.genre, homepage = station.homepage,
	}
	if station.providerMetadata then
		copy.providerMetadata={}
		for _,key in ipairs({"guide_id","preset_id","now_playing_id","show_id","reliability","item"}) do
			local value=station.providerMetadata[key]
			if type(value)=="string" then copy.providerMetadata[key]=value:sub(1,128) end
		end
	end
	if station.resolverUrl then
		copy.url=station.resolverUrl;copy.playlistUrl=station.resolverUrl
		copy.hls=nil;copy.requiresResolution=station.provider=="tunein"
	end
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
		local changed = false
		for i = 1, 6 do
			local preset = self.settings.presets[i] or self.settings.presets[tostring(i)]
			if preset and preset.source == "builtin" then
				self.settings.presets[i] = nil
				self.settings.presets[tostring(i)] = nil
				changed = true
			end
		end
		if changed then
			self.applet:storeSettings()
			self.log:info("StandaloneRadio: removed retired built-in presets")
		end
		return
	end

	self.settings.presets = {}
	self.applet:storeSettings()
	self.log:info("StandaloneRadio: initialized empty presets")
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

-- Provider favorites share the existing applet settings store with presets.
function PresetStore:saveFavorite(station)
	if not station or not station.provider then return false end
	local favorites=self.settings.favorites or {}
	for index,item in ipairs(favorites) do
		if item.id==station.id and item.provider==station.provider then
			favorites[index]=clonePreset(station);self.settings.favorites=favorites
			self.applet:storeSettings();return true
		end
	end
	if #favorites>=100 then return false end
	favorites[#favorites+1]=clonePreset(station);self.settings.favorites=favorites
	self.applet:storeSettings();return true
end
function PresetStore:getFavorites()
	local result={}
	for index,station in ipairs(self.settings.favorites or {}) do
		if index>100 then break end
		if Stations.normalize(station) then result[#result+1]=station end
	end
	return result
end


function PresetStore:updateLogo(station)
	if not station or not self.settings.presets then
		return
	end

	local changed = false
	for i = 1, 6 do
		local preset = self.settings.presets[i] or self.settings.presets[tostring(i)]
		if preset and (
			(station.stationuuid and preset.stationuuid == station.stationuuid)
			or (station.id and preset.id == station.id)
		) then
			preset.favicon = station.favicon or station.remoteLogo or preset.favicon
			preset.remoteLogo = station.remoteLogo or station.favicon or preset.remoteLogo
			preset.logoPath = station.logoPath or preset.logoPath
			changed = true
			self.log:info("StandaloneRadio: preset ", tostring(i), " logo updated")
		end
	end
	if changed then
		self.applet:storeSettings()
	end
end
