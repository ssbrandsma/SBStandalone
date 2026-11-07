local file=assert(io.open("applet/StandaloneRadio/StandaloneRadioApplet.lua","r"))
local source=file:read("*a");file:close()
EVENT_CONSUME,EVENT_UNUSED="consume","unused"
EVENT_IR_PRESS="ir_press"
local actions,calls,listeners={},{},{}
Framework={addActionListener=function(_,name,owner,callback,priority)
    actions[name]=callback
    listeners[#listeners+1]={name=name,callback=callback,priority=math.abs(priority),order=#listeners+1}
    return name
end}
local irPress
Framework.addListener=function(_,mask,callback,priority)
    assert(mask==EVENT_IR_PRESS and priority<0)
    irPress=callback;return mask
end
Framework.getAction=function(_,event) return event.action end
jiveMain={state="on",getSoftPowerState=function(self) return self.state end,
    setSoftPowerState=function(self,state) self.state=state end}
hasServerMigration=true
ServerMigration={LOCAL_UUID="local"}
local server={id="local"}
local player={isLocal=function() return true end,getSlimServer=function() return server end}
appletManager={callService=function() return player end}
_logInfo=function() end
local registration=assert(source:find("function enableStandaloneMode(self)",1,true))
assert(loadstring(source:sub(registration)))()
local stream={ownsPlayback=false}
for _,name in ipairs({"play","pause","stop"}) do stream[name]=function() calls[name]=(calls[name] or 0)+1;return true end end
local applet={streamPlayer=stream,_ensureComponents=function() return true end}
enableStandaloneMode(applet)
for _,name in ipairs({"play","pause","stop"}) do
    assert(actions[name]()==EVENT_UNUSED and not calls[name],name)
end
stream.ownsPlayback=true
for _,name in ipairs({"play","pause","stop"}) do assert(actions[name]()==EVENT_CONSUME and calls[name]==1,name) end
stream.ownsPlayback=false
assert(actions.stop()==EVENT_UNUSED and calls.stop==1)
applet.lastStation={id="last"}
applet._playStation=function(_,station) assert(station==applet.lastStation);calls.restart=(calls.restart or 0)+1 end
jiveMain.state="off"
server.id="remote"
assert(actions.play()==EVENT_UNUSED and not calls.restart and jiveMain.state=="off")
server.id="local"
assert(actions.play()==EVENT_CONSUME and calls.restart==1 and jiveMain.state=="on")
jiveMain.state="off";applet.lastStation=nil
assert(actions.play()==EVENT_UNUSED and jiveMain.state=="off")
-- Firmware sorts global listeners by absolute priority, then newest first.
-- ScreenSavers may initialize after Radio. Its -100 listener wakes the player
-- before forwarding Play, so Radio must run before it to observe standby.
listeners[#listeners+1]={name="play",priority=100,order=#listeners+1,callback=function()
    jiveMain:setSoftPowerState("on")
    return EVENT_UNUSED
end}
table.sort(listeners,function(a,b)
    if a.priority==b.priority then return a.order>b.order end
    return a.priority<b.priority
end)
applet.lastStation={id="last"}
jiveMain.state="off"
local restarted=calls.restart
for _,listener in ipairs(listeners) do
    if listener.name=="play" and listener.callback()==EVENT_CONSUME then break end
end
assert(calls.restart==restarted+1,"standby Play must resume before firmware wakes or translates the action")
jiveMain.state="on";restarted=calls.restart
assert(actions.play()==EVENT_UNUSED and calls.restart==restarted,"awake non-owner Play must pass through")
applet.lastStation=nil
-- The actual clock's ignoreAllInputExcept converts raw IR within its window
-- and translates Play into Pause, bypassing global Play action listeners.
local function physicalPress(action)
    if irPress({action=action})==EVENT_CONSUME then return EVENT_CONSUME end
    if action=="play" then
        jiveMain:setSoftPowerState("on")
        return actions.pause()
    end
    return EVENT_UNUSED
end
applet.lastStation={id="last"};jiveMain.state="off";restarted=calls.restart
assert(physicalPress("play")==EVENT_CONSUME and calls.restart==restarted+1 and jiveMain.state=="on",
    "physical standby Play must resume before clock translates IR to Pause")
jiveMain.state="off";server.id="remote"
assert(irPress({action="play"})==EVENT_UNUSED and jiveMain.state=="off")
server.id="local";applet.lastStation=nil
assert(irPress({action="play"})==EVENT_UNUSED and jiveMain.state=="off")
applet.lastStation={id="last"};jiveMain.state="on"
assert(irPress({action="play"})==EVENT_UNUSED,"awake IR must retain normal menu behavior")
jiveMain.state="off"
assert(irPress({action="create_mix"})==EVENT_UNUSED,"held Play must pass through")
assert(irPress({action="pause"})==EVENT_UNUSED,"physical Pause must pass through")
stream.ownsPlayback=true
assert(physicalPress("play")==EVENT_CONSUME and calls.play==2 and jiveMain.state=="on")

-- Missing Base must not intercept standby Play or prevent Radio from loading.
stream.ownsPlayback=false;hasServerMigration=false;jiveMain.state="off"
local resumed=calls.restart
assert(actions.play()==EVENT_UNUSED and calls.restart==resumed and jiveMain.state=="off")
local import=assert(source:match('(local hasServerMigration, ServerMigration = pcall%([^\n]+)'))
local optionalImport=assert(loadstring(import..'\nreturn hasServerMigration, ServerMigration'))
setfenv(optionalImport,{pcall=pcall,require=function() error("Base is not installed") end})
assert(optionalImport()==false,"Radio must load when optional Base is absent")
-- Preset assignment belongs to the current owner; explicit saved selection may claim it.
local assigned, selected = 0, 0
applet._assignPreset=function() assigned=assigned+1 end
applet.presetStore={getPreset=function() return nil end}
assert(actions.set_preset_1()==EVENT_UNUSED and assigned==0)
assert(actions.play_preset_1()==EVENT_UNUSED,"An unassigned preset must pass through")
stream.ownsPlayback=true
assert(actions.set_preset_1()==EVENT_CONSUME and assigned==1)
stream.ownsPlayback=false
local preset={id="preset"}
applet.presetStore.getPreset=function() return preset end
applet._playStation=function(_,station) assert(station==preset);selected=selected+1 end
assert(actions.play_preset_1()==EVENT_CONSUME and selected==1)
print("Transport ownership, standby Play and physical IR ordering passed")
