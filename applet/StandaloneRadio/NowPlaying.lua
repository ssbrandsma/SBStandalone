local os, pcall, setmetatable, tostring = os, pcall, setmetatable, tostring

local io = require("io")
local math = require("math")

local Framework = require("jive.ui.Framework")
local Group = require("jive.ui.Group")
local Icon = require("jive.ui.Icon")
local Label = require("jive.ui.Label")
local Surface = require("jive.ui.Surface")
local Window = require("jive.ui.Window")

local Stations = require("applets.StandaloneRadio.Stations")

local EVENT_WINDOW_POP = jive.ui.EVENT_WINDOW_POP

module(...)


local NowPlaying = {}
NowPlaying.__index = NowPlaying
local GENERIC_LOGO = "images/radio.png"
local TRACK_ARTWORK_SIZE = 143


local function loadTrackArtwork(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	local data = file:read("*a")
	file:close()
	if not data or data == "" then
		return nil
	end
	-- Decode the bytes now. Surface:loadImage creates a lazy tile that would
	-- try to reopen the transient file during a later screen redraw.
	return Surface:loadImageData(data, #data)
end


function new(applet, log, callbacks)
	return setmetatable({
		applet = applet,
		log = log,
		callbacks = callbacks or {},
		logoCache = {},
		backgroundCache = {},
	}, NowPlaying)
end


function NowPlaying:_ensureWindow()
	if self.window then
		return
	end

	local window = Window("linein")
	self.stationLabel = Label("text", "")
	self.statusLabel = Label("nptrack", "")
	-- icon_linein reserves the artwork area in the stock line-in window.
	-- setValue below replaces its 3.5 mm jack surface with track art.
	self.artwork = Icon("icon_linein")
	-- Keep the stock artwork area, but make it transparent until track artwork
	-- is available. The station logo remains visible in the background.
	self.emptyArtwork = Surface:newRGBA(TRACK_ARTWORK_SIZE, TRACK_ARTWORK_SIZE)

	window:addWidget(Group("title", {
		lbutton = window:createDefaultLeftButton(),
		text = self.stationLabel,
		rbutton = nil,
	}))
	window:addWidget(Group("nptitle", {
		nptrack = self.statusLabel,
		xofy = nil,
	}))
	window:addWidget(Group("npartwork", {
		artwork = self.artwork,
	}))
	window:addListener(EVENT_WINDOW_POP, function()
		self.visible = false
		if self.callbacks.onClose then
			self.callbacks.onClose()
		end
	end)

	self.window = window
end


local function fullscreenSurface(surface)
	local width, height = surface:getSize()
	local screenWidth, screenHeight = Framework:getScreenSize()
	if not width or not height or width <= 0 or height <= 0 then
		return nil
	end
	-- Cover the display while preserving the logo's aspect ratio. A square logo
	-- should fill the shorter screen dimension instead of remaining letterboxed.
	local scale = math.max(screenWidth / width, screenHeight / height)
	return surface:zoom(scale, scale, 1)
end


function NowPlaying:_setLabel(label, field, value)
	if self[field] == value then
		return
	end
	self[field] = value
	label:setValue(value)
end


local function logoSource(station)
	if station.logoPath then
		return station.logoPath, station.logoPath
	end
	if station.logo then
		return "applets/StandaloneRadio/" .. station.logo, station.logo
	end
	return "applets/StandaloneRadio/" .. GENERIC_LOGO, GENERIC_LOGO
end


function NowPlaying:_setLogo(station)
	if self.trackArtworkKey then
		return
	end

	local imagePath, cacheKey = logoSource(station)
	local logoId = tostring(station.id) .. ":" .. tostring(cacheKey)
	if self.logoId == logoId then
		return
	end

	self.logoId = logoId
	local surface = self.logoCache[cacheKey]
	if surface == false then
		if cacheKey ~= GENERIC_LOGO then
			self:_setFallbackLogo(station)
		end
		return
	end

	if not surface then
		local ok, loaded = pcall(function()
			return Surface:loadImage(imagePath)
		end)
		if not ok or not loaded then
			self.logoCache[cacheKey] = false
			self.log:warn("StandaloneRadio: unable to load logo ", imagePath)
			if station.logoPath and cacheKey == station.logoPath then
				os.remove(imagePath)
				station.logoPath = nil
			end
			if cacheKey ~= GENERIC_LOGO then
				self:_setFallbackLogo(station)
			end
			return
		end
		surface = loaded
		self.logoCache[cacheKey] = surface
	end

	-- Framework's background is drawn below the now-playing window. Keep the
	-- active background surface alive for the lifetime of this UI object: the
	-- Radio can otherwise freeze if a surface still owned by the renderer is
	-- released while changing stations.
	local background = self.backgroundCache[cacheKey]
	if not background then
		background = fullscreenSurface(surface)
		if background then
			self.backgroundCache[cacheKey] = background
		end
	end
	if background then
		Framework:setBackground(background)
	end

	self.artwork:setValue(self.emptyArtwork)
	self.artwork:reLayout()
	self.artwork:reDraw()
	self.log:info("StandaloneRadio: logo=", imagePath)
end


function NowPlaying:_setDefaultBackground()
	local surface = self.logoCache[GENERIC_LOGO]
	if not surface then
		local ok, loaded = pcall(function()
			return Surface:loadImage("applets/StandaloneRadio/" .. GENERIC_LOGO)
		end)
		if not ok or not loaded then
			ok, loaded = pcall(function()
				return Surface:loadImage("applets/StandaloneRadio/images\\radio.png")
			end)
		end
		if not ok or not loaded then
			self.log:warn("StandaloneRadio: unable to load default background logo")
			return
		end
		surface = loaded
		self.logoCache[GENERIC_LOGO] = surface
	end

	local background = self.backgroundCache[GENERIC_LOGO]
	if not background then
		background = fullscreenSurface(surface)
		if background then
			self.backgroundCache[GENERIC_LOGO] = background
		end
	end
	if background then
		Framework:setBackground(background)
	end
	self.log:info("StandaloneRadio: default background logo shown")
end


function NowPlaying:selectStation(station)
	if not station then
		return
	end
	self:_ensureWindow()
	self.trackArtworkKey = nil
	self.trackArtworkSurface = nil
	self.logoId = nil
	self:_setDefaultBackground()
	self.log:info("StandaloneRadio: station selected; previous background cleared station=", tostring(station.id))
end


function NowPlaying:clearTrackArtwork(station)
	self.trackArtworkKey = nil
	self.trackArtworkSurface = nil
	self.logoId = nil
	if station and self.currentStationId == station.id then
		self:_setLogo(station)
	end
end


function NowPlaying:beginTrackArtwork(station, key)
	self:clearTrackArtwork(station)
	if not station or self.currentStationId ~= station.id then
		return false
	end
	self.trackArtworkKey = key
	return true
end


function NowPlaying:setTrackArtwork(station, key, imagePath)
	if not station or self.currentStationId ~= station.id or self.trackArtworkKey ~= key then
		return false
	end

	local ok, surface = pcall(loadTrackArtwork, imagePath)
	if not ok or not surface then
		self.log:warn("StandaloneRadio: unable to load track artwork ", imagePath)
		return false
	end
	local width, height = surface:getSize()
	local scale = math.min(TRACK_ARTWORK_SIZE / width, TRACK_ARTWORK_SIZE / height)
	if scale < 1 then
		local scaled = surface:zoom(scale, scale, 1)
		surface:release()
		if not scaled then
			self.log:warn("StandaloneRadio: unable to resize track artwork")
			return false
		end
		surface = scaled
	end

	self.trackArtworkSurface = surface
	self.artwork:setValue(surface)
	-- Icon:setValue does not invalidate an already visible stock skin widget.
	self.artwork:reLayout()
	self.artwork:reDraw()
	self.log:info("StandaloneRadio: track artwork loaded")
	return true
end


function NowPlaying:_setFallbackLogo(station)
	local fallback = {
		id = station.id,
		logo = GENERIC_LOGO,
	}
	self:_setLogo(fallback)
end


function NowPlaying:updateLogo(station)
	if station and self.currentStationId == station.id then
		self:_setLogo(station)
		self.log:info("StandaloneRadio: Now Playing logo updated for ", Stations.displayName(station, self.applet))
	end
end


function NowPlaying:update(station, state, show)
	self:_ensureWindow()
	if station then
		if self.currentStationId ~= station.id then
			self.trackArtworkKey = nil
			self.trackArtworkSurface = nil
			self.logoId = nil
			self:_setDefaultBackground()
		end
		self.currentStationId = station.id
		self:_setLabel(self.stationLabel, "stationText", Stations.displayName(station, self.applet))
		self:_setLogo(station)
	end

	self:_setLabel(self.statusLabel, "statusText", tostring(self.applet:string("STANDALONE_RADIO_STATE_" .. state)))
	if show then
		if Framework:isWindowInStack(self.window) then
			self.window:moveToTop()
		else
			self.window:show()
		end
		self.visible = true
	end
end


function NowPlaying:setMetadata(title)
	self:_ensureWindow()
	self:_setLabel(self.statusLabel, "statusText", title)
end
