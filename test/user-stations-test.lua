if not module then
	function module(name)
		local target = package.loaded[name] or {}
		package.loaded[name] = target
		local info = debug.getinfo(2, "f")
		local index = 1
		while true do
			local upname = debug.getupvalue(info.func, index)
			if not upname then break end
			if upname == "_ENV" then
				setmetatable(target, { __index = _G })
				debug.setupvalue(info.func, index, target)
				break
			end
			index = index + 1
		end
	end
end

local root = "./applet/StandaloneRadio/"
package.preload["applets.StandaloneRadio.Stations"] = function()
	assert(loadfile(root .. "Stations.lua"))("applets.StandaloneRadio.Stations")
	return package.loaded["applets.StandaloneRadio.Stations"]
end
package.preload.json = function() return { decode=function() error("decoder not supplied") end } end
package.preload["applets.StandaloneRadio.UserStations"] = function()
	assert(loadfile(root .. "UserStations.lua"))("applets.StandaloneRadio.UserStations")
	return package.loaded["applets.StandaloneRadio.UserStations"]
end

local UserStations = require("applets.StandaloneRadio.UserStations")
local documents, current = {}, "valid"
local function readFile() return current, current == nil and "missing" or nil end
local function decode(key)
	local value = documents[key]
	if value == false then error("invalid JSON") end
	return value
end
local function station(id, name, order, extra)
	local value = { id=id, name=name, streamUrl="http://example.com/" .. id,
		enabled=true, order=order }
	for key, item in pairs(extra or {}) do value[key] = item end
	return value
end

documents.valid = { schemaVersion=1, revision=1, stations={
	station("z", "Zulu", 20), station("b", "Beta", 10), station("a", "Alpha", 10),
	station("off", "Disabled", 1, { enabled=false }),
	station("duplicate", "First", 30), station("duplicate", "Second", 40),
	station("bad-url", "Bad", 50, { streamUrl="ftp://example.com/live" }),
	station("too-long", "Long", 51, { streamUrl="http://example.com/" .. string.rep("x", 8192) }),
	station("bad-utf8", "Bad\255Name", 52),
	station("unicode", "Beyonc\195\169 FM", 60, { logoUrl="https://example.com/logo.png" }),
	station("local", "Local Logo", 70, { logoFile="logo-123.png", codec="aac" }),
} }
documents.changed = { schemaVersion=1, revision=2, stations={
	station("b", "Renamed", 10, { streamUrl="https://example.com/new" }),
} }
documents.empty = { schemaVersion=1, revision=3, stations={} }
documents.unsupported = { schemaVersion=2, revision=4, stations={} }
documents.invalid = false

local loader = UserStations.new({ readFile=readFile, decoder=decode })
local list, err, changed = loader:reload()
assert(not err and changed and #list == 6)
assert(list[1].id == "a" and list[2].id == "b" and list[3].id == "z")
assert(list[5].name == "Beyonc\195\169 FM")
assert(list[6].localLogoPath == "/mnt/sbdata/config/radio/logos/logo-123.png")
assert(list[6].codec == "aac")
assert(loader:resolve("duplicate").name == "First")

local same = loader:reload()
assert(same == list)
current = "invalid"
local fallback, invalidErr = loader:reload()
assert(fallback == list and invalidErr == "invalid JSON")
current = "unsupported"
fallback, invalidErr = loader:reload()
assert(fallback == list and invalidErr == "unsupported schema version")
current = nil
fallback, invalidErr = loader:reload()
assert(fallback == list and invalidErr == "missing")

current = "changed"
local updated = loader:reload()
assert(#updated == 1 and updated[1].name == "Renamed" and updated[1].url == "https://example.com/new")
assert(loader:resolve("b").name == "Renamed")
assert(loader:resolve("z") == nil)
current = "empty"
local empty = loader:reload()
assert(#empty == 0)

local limits = UserStations.limits()
assert(limits.maxBytes == 256 * 1024 and limits.maxStations == 250)
print("User station loader tests passed")
