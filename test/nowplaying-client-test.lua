-- Host-side lifecycle tests. The target uses Lua 5.1's module(); provide the
-- small compatibility shim needed by development Lua versions.
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
package.preload["applets.StandaloneRadio.StreamMetadata"] = function()
	assert(loadfile(root .. "StreamMetadata.lua"))("applets.StandaloneRadio.StreamMetadata")
	return package.loaded["applets.StandaloneRadio.StreamMetadata"]
end
package.preload["applets.StandaloneRadio.UrlTransport"] = function()
	return assert(loadfile(root .. "UrlTransport.lua"))()
end

local decoded = {}
package.preload.json = function()
	return {
		encode = function(value) return value end,
		decode = function(value)
			if type(value) == "table" then return value end
			return decoded[value]
		end,
	}
end

package.preload["applets.StandaloneRadio.StandaloneBaseNowPlaying"] = function()
	assert(loadfile(root .. "StandaloneBaseNowPlaying.lua"))("applets.StandaloneRadio.StandaloneBaseNowPlaying")
	return package.loaded["applets.StandaloneRadio.StandaloneBaseNowPlaying"]
end

local metadata = require("applets.StandaloneRadio.StreamMetadata")
local api = require("applets.StandaloneRadio.StandaloneBaseNowPlaying")

local function equal(actual, expected)
	assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local title, artist = metadata.parse("  Dire Straits - Sultans of Swing  ")
equal(title, "Sultans of Swing")
equal(artist, "Dire Straits")
title, artist = metadata.parse("Title-only - with - hyphens")
equal(title, "with - hyphens")
equal(artist, "Title-only")
title, artist = metadata.parse("Beyonc\195\169")
equal(title, "Beyonc\195\169")
equal(artist, nil)
equal(metadata.parse("  "), nil)
local customId = api.stationId({ id="Mutable Name", name="Mutable Name", source="user",
	url="http://user:password@example.com/live" })
assert(string.match(customId, "^radio:url:%d+$"))
assert(not string.find(customId, "password", 1, true))

local pending, requests = {}, {}
local function transport(method, path, payload, callback)
	requests[#requests + 1] = { method=method, path=path, payload=payload }
	pending[#pending + 1] = callback
end
local function respond(status, value)
	local callback = table.remove(pending, 1)
	assert(callback, "no pending HTTP request")
	local key = "response-" .. tostring(#decoded + 1)
	decoded[key] = value
	callback(status, key, nil)
end
local function path(index) return requests[index].path end

local client = api.new({ request=transport, isPlaybackOwner=function() return true end })
equal(#requests, 0) -- idle never claims
local stationA = { id="radiobrowser:abc", name="Radio Paradise", url="http://user:pass@example/live",
	favicon="http://images.example/radio-paradise.png" }
client:activate(stationA)
equal(path(1), "/api/nowplaying/claim")
equal(requests[1].payload.capabilities.play, false)

-- State and rapid metadata changes coalesce while claim is in flight.
client:updateState("PLAYING")
client:updateMetadata("Old Artist - Old Song")
client:updateMetadata("Dire Straits - Sultans of Swing")
equal(#requests, 1)
respond(201, { success=true, session_id="secret-a", generation=7, active=true })
equal(path(2), "/api/nowplaying/update")
equal(requests[2].payload.state, "playing")
equal(requests[2].payload.track.id, "radio:radiobrowser:abc")
equal(requests[2].payload.track.artist, "Dire Straits")
equal(requests[2].payload.track.title, "Sultans of Swing")
equal(requests[2].payload.track.artwork_url, "http://images.example/radio-paradise.png")
assert(not string.find(tostring(requests[2].payload.track.id), "pass", 1, true))

-- A metadata update arriving in flight results in one latest-state follow-up.
client:updateMetadata("Artist 2 - Song 2")
client:updateMetadata("Artist 3 - Song 3")
respond(200, { success=true, generation=7 })
equal(path(3), "/api/nowplaying/update")
equal(requests[3].payload.track.title, "Song 3")
respond(200, { success=true, generation=7 })

-- A station change retains the session and clears old song metadata.
client:activate({ id="radiofeeds:xyz", name="Station B", url="http://b/live" })
equal(path(4), "/api/nowplaying/update")
equal(requests[4].payload.track.id, "radio:radiofeeds:xyz")
equal(requests[4].payload.track.title, "")
equal(requests[4].payload.track.artwork_url, nil)
respond(200, { success=true, generation=7 })

-- Intentional stop publishes stopped before release.
client:updateState("STOPPED")
equal(path(5), "/api/nowplaying/update")
equal(requests[5].payload.state, "stopped")
respond(200, { success=true, generation=7 })
equal(path(6), "/api/nowplaying/release")
respond(200, { success=true })
equal(client:status().hasSession, false)

-- A 409 followed by inactive status represents a server restart: reclaim and
-- republish. An active status represents takeover and must not be fought.
client:activate(stationA)
respond(201, { success=true, session_id="secret-b", generation=1, active=true })
respond(200, { success=true, generation=1 })
client:updateMetadata("Restart Test")
respond(409, { success=false, error="invalid_session" })
equal(path(10), "/api/nowplaying")
respond(200, { api_version=1, active=false })
equal(path(11), "/api/nowplaying/claim")
respond(201, { success=true, session_id="secret-c", generation=2, active=true })
equal(requests[12].payload.track.artwork_url, "http://images.example/radio-paradise.png")
respond(200, { success=true, generation=2 })
client:updateMetadata("Takeover Test")
respond(409, { success=false, error="invalid_session" })
respond(200, { api_version=1, active=true, source="spotify" })
equal(client:status().activeIntent, false)
equal(#pending, 0)

equal(api.mapState("RESOLVING"), "buffering")
equal(api.mapState("RECONNECTING"), "buffering")
equal(api.mapState("CONNECTION_LOST"), "buffering")
equal(api.mapState("FAILED"), "error")
equal(api.mapState("PLAYING"), "playing")

-- A delayed A update can complete after rapid A -> B -> C selection, but the
-- next serialized request must contain C and stale A/B metadata is rejected.
local pending2, requests2 = {}, {}
local published2 = 0
local client2 = api.new({
	request=function(method, requestPath, payload, callback)
		requests2[#requests2 + 1] = { path=requestPath, payload=payload }
		pending2[#pending2 + 1] = callback
	end,
	isPlaybackOwner=function() return true end,
	onPublished=function() published2 = published2 + 1 end,
})
local function respond2(status, value, err)
	local callback = table.remove(pending2, 1)
	assert(callback, "no pending client2 request")
	callback(status, value, err)
end
local a = { id="a", name="A", url="http://a/live", favicon="https://images.example/a.jpg?q=one%20two" }
local b = { id="b", name="B", url="http://b/live" }
local c = { id="c", name="C", url="http://c/live", favicon="http://images.example/c.png" }
client2:activate(a, 1)
respond2(201, { success=true, session_id="session-2", generation=1, active=true })
equal(requests2[2].payload.track.station, "A") -- A update remains in flight
equal(requests2[2].payload.track.artwork_url,
	"http://127.0.0.1:8765/https/images.example/a.jpg?q=one%20two")
client2:activate(b, 2)
client2:updateMetadata("Old A - Old Song", a, 1)
client2:activate(c, 3)
client2:updateMetadata("Old B - Old Song", b, 2)
respond2(200, { success=true, generation=1 })
equal(requests2[3].payload.track.station, "C")
equal(published2, 0) -- stale A completion must not restage the native player
equal(requests2[3].payload.track.title, "")
equal(requests2[3].payload.state, "buffering")
equal(requests2[3].payload.track.artwork_url, "http://images.example/c.png")
respond2(200, { success=true, generation=1 })
equal(published2, 1)
client2:updateState("PLAYING", c, 3)
equal(requests2[4].payload.state, "playing")
respond2(200, { success=true, generation=1 })
client2:updateMetadata("Current Artist - Current Song", c, 3)
equal(requests2[5].payload.track.title, "Current Song")
equal(requests2[5].payload.track.artwork_url, "http://images.example/c.png")
respond2(200, { success=true, generation=1 })
equal(published2, 1) -- state and ICY changes do not cause navigation/restaging
equal(client2:updateTrackArtwork("https://covers.example/current%20song.jpg?size=300", c, 3,
	"Current Artist - Current Song"), true)
equal(requests2[6].payload.track.artwork_url,
	"http://127.0.0.1:8765/https/covers.example/current%20song.jpg?size=300")
respond2(200, { success=true, generation=1 })
local requestCount = #requests2
equal(client2:updateTrackArtwork("https://covers.example/current%20song.jpg?size=300", c, 3,
	"Current Artist - Current Song"), true)
equal(#requests2, requestCount) -- duplicate cover does not publish
client2:updateMetadata("Next Artist - Next Song", c, 3)
equal(requests2[7].payload.track.artwork_url, "http://images.example/c.png")
respond2(200, { success=true, generation=1 })
equal(client2:updateTrackArtwork("http://covers.example/old.jpg", c, 3,
	"Current Artist - Current Song"), false)
equal(#requests2, 7)
client2:activate(b, 4)
equal(requests2[8].payload.track.station, "B")
equal(requests2[8].payload.track.title, "")
equal(requests2[8].payload.track.artwork_url, nil)
respond2(200, { success=true, generation=1 })
equal(client2:updateTrackArtwork("http://covers.example/c-delayed.jpg", c, 3,
	"Next Artist - Next Song"), false)
equal(client2:updateTrackArtwork("file:///tmp/cover.jpg", b, 4, nil), false)
equal(#requests2, 8)

-- API failure does not suppress a new selection: activation cancels the
-- pending backoff and immediately claims the latest station.
local pending3, requests3, timers3 = {}, {}, {}
local client3 = api.new({
	request=function(method, requestPath, payload, callback)
		requests3[#requests3 + 1] = { path=requestPath, payload=payload }
		pending3[#pending3 + 1] = callback
	end,
	timerFactory=function(delay, callback)
		local timer = { delay=delay, callback=callback, stopped=false }
		function timer:start() end
		function timer:stop() self.stopped=true end
		timers3[#timers3 + 1] = timer
		return timer
	end,
})
client3:activate(a, 1)
table.remove(pending3, 1)(nil, nil, "connection refused")
client3:activate(b, 2)
equal(requests3[2].path, "/api/nowplaying/claim")
equal(client3:status().stationGeneration, 2)

-- Timed metadata preserves structured artist/title, suppresses duplicates,
-- clears obsolete APIC, and rejects callbacks from previous generations.
local timed=api.new({request=function() end})
timed.station=a;timed.stationGeneration=7;timed.stationArtwork="http://logo.example/station.png"
timed._sync=function() end
equal(timed:updateTimedMetadata({title="Title - literal",artist="Artist",album="Album",
    artwork_url="http://127.0.0.1:8765/hls-meta/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/art/1"},a,7),true)
local snapshot=timed:_snapshot()
equal(snapshot.track.title,"Title - literal");equal(snapshot.track.artist,"Artist");equal(snapshot.track.album,"Album")
assert(snapshot.track.artwork_url:find("/hls%-meta/"))
local revision=timed.revision
timed:updateTimedMetadata({title="Title - literal",artist="Artist",album="Album"},a,7)
equal(timed.revision,revision)
timed:updateTimedMetadata({timestamp_90khz=90000},a,7)
equal(timed.revision,revision)
equal(timed:updateTimedMetadata({title="Stale"},a,6),false)
timed:updateTimedMetadata({title="Next"},a,7)
equal(timed:_snapshot().track.artwork_url,timed.stationArtwork)
equal(timed:_snapshot().track.album,"")

-- Declared directory quality stays separate from observed HTTP/ICY quality.
timed.station={id="directory",name="Station",codec="MP3",bitrate=192,
    homepage="https://example.org",tags="Rock",country="NL",description="Description",
    observedAudio={codec="aac",bitrate_kbps=48}}
snapshot=timed:_snapshot()
equal(snapshot.station.audio.codec,"MP3")
equal(snapshot.station.audio.bitrate_kbps,192)
equal(snapshot.track.audio.codec,"aac")
equal(snapshot.track.audio.bitrate_kbps,48)
equal(snapshot.station.description,"Description")
equal(snapshot.station.homepage,"https://example.org")
equal(snapshot.station.genre,"Rock")
print("StandaloneBase Now Playing client tests passed")

local episode={id="episode",stationuuid="episode-1",source="custom",episode=true,name="Episode name",
 episodeTitle="Episode title",podcast="Podcast title",url="https://example.org/episode.mp3?token=a%2Fb",
 duration_ms=123000,position_ms=5000,enclosureType="audio/mpeg",codec="mp3"}
local pc=api.new({request=function() end});pc.station=episode;pc.stationGeneration=1;pc._sync=function() end
pc.desiredState="playing";pc.stationArtwork="http://example.org/episode.jpg"
local snap=pc:_snapshot()
assert(snap.live==false and snap.position_ms==5000 and snap.track.duration_ms==123000)
assert(snap.track.title=="Episode title" and snap.track.artist=="Podcast title" and snap.track.album=="Podcast title")
assert(snap.track.artwork_url==pc.stationArtwork and snap.track.content_type=="audio/mpeg")
pc:updatePosition(10000,episode,1);assert(pc:_snapshot().position_ms==10000)
pc:updatePosition(20000,episode,0);assert(pc:_snapshot().position_ms==10000)
pc:updateState("PAUSED",episode,1);assert(pc:_snapshot().state=="paused")
pc:updateState("FAILED",episode,1);assert(pc.releaseRequested and not pc.activeIntent)
episode.episodeTitle=string.rep(string.char(195,169),256);episode.podcast=string.rep("BBC ",100)
snap=pc:_snapshot();assert(#snap.track.title==254 and #snap.track.artist==255 and #snap.track.album==255)
print("Podcast non-live Now Playing metadata, duration/position, artwork, pause/release and API text bounds passed")

episode.observedAudio={};episode.declaredCodec=nil;episode.codec=nil;episode.provider="custom"
snap=pc:_snapshot();assert(snap.track.audio==nil and snap.station.audio==nil,"empty tables must not encode as JSON arrays")
