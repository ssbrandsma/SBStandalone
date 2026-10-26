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

local loader = UserStations.new({ path=UserStations.limits().path, readFile=readFile, decoder=decode })
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

documents.directories={schemaVersion=1,revision=10,stations={
    station("legacy","Legacy",20), station("explicit","Explicit",30,{type="station"}),
    station("directory","Directory",10,{type="opml",streamUrl="https://example.org?query=one",codec="invalid",logoFile="logo-123.png"}),
    station("disabled-dir","Disabled",5,{type="opml",enabled=false}),
    station("unknown","Unknown",1,{type="invalid"}), station("badcodec","Bad Codec",1,{codec={}}),
}}
current="directories";local mixed=loader:reload()
assert(#mixed==3 and mixed[1].type=="opml" and mixed[1].url=="https://example.org/?query=one")
assert(mixed[1].localLogoPath and mixed[1].codec=="auto")
assert(mixed[2].type=="station" and mixed[3].type=="station")
print("Mixed custom station/directory schema, defaults, order, artwork and invalid-row isolation passed")

local open=io.open
local mounts={"ubi0:ubifs /mnt/storage ubifs rw 0 0"}
io.open=function(path,...)
 if path=="/proc/mounts" then
  return {lines=function() local index=0;return function() index=index+1;return mounts[index] end end,close=function() end}
 end
 return open(path,...)
end
local dynamic=UserStations.new({readFile=function(path) return path:find("/mnt/sbdata/",1,true) and "valid" or "directories" end,decoder=decode})
local function checkStorage(external)
 local list,err=dynamic:reload()
 assert(not err)
 assert(dynamic.path==(external and "/mnt/sbdata/config/radio/stations.json" or "/mnt/storage/standalonebase/radio/stations.json"))
 assert(list[external and 6 or 1].localLogoPath==(external and "/mnt/sbdata/config/radio/logos/logo-123.png" or "/mnt/storage/standalonebase/radio/logos/logo-123.png"))
end
checkStorage(false)
for _,device in ipairs({"ubi0:sbdata","/dev/ubi0_5"}) do
 for _,kind in ipairs({"sbubifs","ubifs"}) do
  mounts={"ubi0:ubifs /mnt/storage ubifs rw 0 0",device.." /mnt/sbdata "..kind.." rw 0 0"}
  checkStorage(true) -- same revision: changing storage must also replace cached data
 end
end
for _,line in ipairs({
 "ubi0:other /mnt/sbdata ubifs rw 0 0",
 "ubi0:other /mnt/sbdata sbubifs rw 0 0",
 "ubi0:sbdata /mnt/sbdata tmpfs rw 0 0",
 "ubi0:sbdata /mnt/sbdata-other ubifs rw 0 0",
 "ubi0:sbdata /usr/share/jive/applets ubifs rw 0 0",
 "malformed mount entry",
}) do
 mounts={line};checkStorage(false)
end
mounts={"ubi0:sbdata /mnt/sbdata ubifs rw 0 0"};checkStorage(true)
mounts={};checkStorage(false) -- unmounted storage returns to internal config
io.open=function(path,...) if path=="/proc/mounts" then return nil,"unavailable" end;return open(path,...) end
checkStorage(false)
io.open=open
print("Native/legacy storage identities, invalid mounts, remounts and uploaded-logo roots follow Base")
