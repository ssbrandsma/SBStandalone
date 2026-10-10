local tostring = tostring
local string = require("string")

module(...)

local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

function parse(streamTitle)
	local original = trim(streamTitle)
	if original == "" then
		return nil, nil
	end

	-- Split only the conventional spaced separator. Bare hyphens commonly
	-- occur inside artist and song names and are not reliable delimiters.
	local artist, title = string.match(original, "^(.-)%s+%-%s+(.+)$")
	artist, title = trim(artist), trim(title)
	if artist ~= "" and title ~= "" then
		return title, artist
	end
	return original, nil
end

