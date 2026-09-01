local pcall, setmetatable, tostring = pcall, setmetatable, tostring

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


function new(applet, log)
	return setmetatable({
		applet = applet,
		log = log,
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


function NowPlaying:_setLogo(station)
	if self.logoId == station.id then
		return
	end

	self.logoId = station.id
	local surface = self.logoCache[station.logo]
	if surface == false then
		return
	end

	if not surface then
		local imagePath = "applets/StandaloneRadio/" .. station.logo
		local ok, loaded = pcall(function()
			return Surface:loadImage(imagePath)
		end)
		if not ok or not loaded then
			self.logoCache[station.logo] = false
			self.log:warn("StandaloneRadio: unable to load logo ", imagePath)
			return
		end
		surface = loaded
		self.logoCache[station.logo] = surface
	end

	self.artwork:setValue(surface)
	self.log:info("StandaloneRadio: logo=", station.logo)
end


function NowPlaying:update(station, state, show)
	self:_ensureWindow()
	if station then
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
