local pcall, setmetatable, tostring, type = pcall, setmetatable, tostring, type

local string = require("string")

local RequestHttp = require("jive.net.RequestHttp")
local SocketHttp = require("jive.net.SocketHttp")
local jnt = jnt

module(...)

local HttpsProxyStatus = {}
HttpsProxyStatus.__index = HttpsProxyStatus

local HOST = "127.0.0.1"
local PORT = 8765

function new(options)
	return setmetatable({
		log = options.log,
		onUnavailable = options.onUnavailable or function() end,
	}, HttpsProxyStatus)
end

function HttpsProxyStatus:_finish(available, err)
	self.checking = false
	self.checked = true
	self.available = available == true
	self.log:info("StandaloneRadio: HTTPS proxy health available=", tostring(self.available))
	if not self.available and not self.warned then
		self.warned = true
		self.onUnavailable(err)
	end
end

function HttpsProxyStatus:check(force)
	if self.checking or (self.checked and not force) then return end
	self.checking = true
	local done = false
	local request
	request = RequestHttp(function(body, err)
		if done or (body == nil and not err) then return end
		done = true
		local status = request:t_getResponseStatus()
		-- Stock SqueezePlay does not consistently expose the numeric response
		-- status here. The local proxy's health marker is the authoritative check.
		local healthy = type(body) == "string"
			and string.find(body, "status: OK", 1, true) ~= nil
		self.log:info("StandaloneRadio: HTTPS proxy health status=", tostring(status),
			" error=", tostring(err))
		self:_finish(healthy, err or (healthy and nil or "invalid health response"))
	end, "GET", "/health", { headers = { Host = HOST .. ":" .. tostring(PORT), Connection = "close" } })
	local socket = SocketHttp(jnt, HOST, PORT, "StandaloneRadioHttpsProxyHealth")
	self.http = socket
	local ok, fetchErr = pcall(function() socket:fetch(request) end)
	if not ok and not done then
		done = true
		self:_finish(false, fetchErr)
	end
end

function HttpsProxyStatus:transportFailed(url)
	if type(url) ~= "string" or string.lower(string.sub(url, 1, 8)) ~= "https://" then return end
	self.checked = false
	self.available = false
	self:check(true)
end
