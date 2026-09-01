local os, pcall, setmetatable, tostring = os, pcall, setmetatable, tostring

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


function new(applet, log, callbacks)
	return setmetatable({
		applet = applet,
		log = log,
		callbacks = callbacks or {},
		logoCache = {},
	}, NowPlaying)
end


function NowPlaying:_ensureWindow()
	if self.window then
		return
	end

	local window = Window("linein")
	self.stationLabel = Label("text", "")
	self.statusLabel = Label("nptrack", "")
	self.artwork = Icon("icon_linein")

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

	self.artwork:setValue(surface)
	self.log:info("StandaloneRadio: logo=", imagePath)
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
