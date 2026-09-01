local setmetatable, tonumber, tostring, type = setmetatable, tonumber, tostring, type

local string = require("string")

local Process = require("jive.net.Process")

local jnt = jnt

module(...)


local Resolver = {}
Resolver.__index = Resolver


local function isValidHost(host)
	return type(host) == "string"
		and string.match(host, "^[%w%.%-]+$")
		and not string.match(host, "^%.")
		and not string.match(host, "^%-")
		and not string.match(host, "%.$")
		and not string.match(host, "%.%.")
end


local function isIpv4(address)
	if type(address) ~= "string" then
		return false
	end

	local a, b, c, d = string.match(address, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	return a and b and c and d
		and a >= 0 and a <= 255
		and b >= 0 and b <= 255
		and c >= 0 and c <= 255
		and d >= 0 and d <= 255
end


local function firstNslookupAddress(output)
	local answer = string.match(output, "Name:[%s%S]*")
	if not answer then
		return nil
	end

	for ip in string.gmatch(answer, "Address%s*%d*:%s*(%d+%.%d+%.%d+%.%d+)") do
		if isIpv4(ip) then
			return ip
		end
	end

	return nil
end


function new(options)
	return setmetatable({
		log = options.log,
	}, Resolver)
end


function Resolver:_resolveWithNslookup(host, nativeErr, callback)
	local output = ""
	local process = Process(jnt, "nslookup " .. host .. " 2>&1")

	process:read(function(chunk, err)
		if chunk then
			output = output .. chunk
			return
		end

		local ip = firstNslookupAddress(output)
		if ip then
			self.log:info("StandaloneRadio: nslookup DNS resolved ", host, " to ", ip)
			callback(ip, "nslookup")
		else
			self.log:warn("StandaloneRadio: nslookup DNS failed for ", host, ": ", tostring(err or output))
			callback(nil, "nslookup", err or nativeErr)
		end
	end)
end


function Resolver:resolve(host, callback)
	if not isValidHost(host) then
		self.log:warn("StandaloneRadio: invalid DNS host ", tostring(host))
		callback(nil, "invalid-host", "invalid host")
		return
	end

	self:_resolveWithNslookup(host, "nslookup", callback)
end
