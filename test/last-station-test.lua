local PresetStore = require("applets.StandaloneRadio.PresetStore")
local settings = {presets={},lastPreset=2}
local stores = 0
local function openStore()
    return PresetStore.new({settings=settings,
        applet={storeSettings=function() stores=stores+1 end},
        log={info=function() end,warn=function() end}})
end
local store = openStore()
assert(store:getLastStation()==nil)
local preset={id="preset",name="Preset",url="http://example.org/preset"}
settings.presets[2]=preset
assert(store:getLastStation()==preset,"Existing lastPreset settings must still work")
local station={id="last",name="Last station",url="http://example.org/live",source="user"}
store:rememberStation(station)
station.url="http://example.org/changed"
assert(settings.lastStation.url=="http://example.org/live","Remember a snapshot, not the mutable playback object")
assert(openStore():getLastStation().id=="last","A station without a hardware preset must survive reopening")
settings.lastStation={id="invalid",url="ftp://example.org/live"}
assert(store:getLastStation()==preset,"Invalid remembered station must fall back to the saved preset")
store:rememberStation({id="provider",name="Provider station",provider="tunein",
    url="http://example.org/temporary-stream",resolverUrl="http://example.org/resolve"})
local remembered=openStore():getLastStation()
assert(remembered.url=="http://example.org/resolve" and remembered.requiresResolution,
    "Remember the provider resolver rather than an expired stream URL")
assert(stores==0,"The selecting applet persists its settings once after remembering a station")
print("Last station snapshots, preset fallback and provider resolution passed")
