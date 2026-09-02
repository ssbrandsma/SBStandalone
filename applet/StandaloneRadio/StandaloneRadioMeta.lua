local oo = require("loop.simple")
local lfs = require("lfs")

local AppletMeta = require("jive.AppletMeta")

local appletManager = appletManager
local jiveMain = jiveMain
local AUTOTEST_MARKER = "/tmp/standalone-radio-autotest"

module(...)
oo.class(_M, AppletMeta)


function jiveVersion(self)
	return 1, 1
end


function defaultSettings(self)
	return {}
end


function upgradeSettings(self, settings)
	return settings or {}
end


function registerApplet(meta)
	jiveMain:addItem(meta:menuItem('standaloneRadio', 'home', "STANDALONE_RADIO", function(applet, ...) applet:menu() end, 45, nil, "hm_radio"))

	-- This is a standalone radio, so its physical preset/transport controls are
	-- active immediately after boot rather than only after opening its menu.
	local applet = appletManager:loadApplet("StandaloneRadio")
	applet:enableStandaloneMode()

	if lfs.attributes(AUTOTEST_MARKER, "mode") then
		applet:scheduleStartupTest()
	end
end
