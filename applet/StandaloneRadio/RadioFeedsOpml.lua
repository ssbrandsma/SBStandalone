local lom = require("lxp.lom")
local ipairs, pcall, tonumber, type = ipairs, pcall, tonumber, type
local string, table, tostring = string, table, tostring

module(...)


-- LuaExpat decodes XML's predefined and numeric entities while converting the
-- document encoding to UTF-8. RadioFeeds also emits a small HTML entity subset,
-- which Expat correctly rejects as undeclared. Convert only user-visible text
-- fields to numeric XML references before parsing so Expat remains the sole
-- decoder. RadioFeeds also XML-escapes its HTML references (for example
-- G&amp;agrave;idheal). Unwrap that XML layer once in visible fields first.
local HTML_ENTITIES = {
	Agrave=192, Aacute=193, Acirc=194, Atilde=195, Auml=196, Aring=197, AElig=198,
	Ccedil=199, Egrave=200, Eacute=201, Ecirc=202, Euml=203,
	Igrave=204, Iacute=205, Icirc=206, Iuml=207, ETH=208, Ntilde=209,
	Ograve=210, Oacute=211, Ocirc=212, Otilde=213, Ouml=214, Oslash=216,
	Ugrave=217, Uacute=218, Ucirc=219, Uuml=220, Yacute=221, THORN=222,
	agrave=224, aacute=225, acirc=226, atilde=227, auml=228, aring=229, aelig=230,
	ccedil=231, egrave=232, eacute=233, ecirc=234, euml=235,
	igrave=236, iacute=237, icirc=238, iuml=239, eth=240, ntilde=241,
	ograve=242, oacute=243, ocirc=244, otilde=245, ouml=246, oslash=248,
	ugrave=249, uacute=250, ucirc=251, uuml=252, yacute=253, thorn=254, yuml=255,
	OElig=338, oelig=339, Scaron=352, scaron=353, Yuml=376,
	nbsp=160, iexcl=161, cent=162, pound=163, curren=164, yen=165, brvbar=166,
	sect=167, uml=168, copy=169, ordf=170, laquo=171, ["not"]=172, shy=173, reg=174,
	macr=175, deg=176, plusmn=177, sup2=178, sup3=179, acute=180, micro=181,
	para=182, middot=183, cedil=184, sup1=185, ordm=186, raquo=187,
	frac14=188, frac12=189, frac34=190, iquest=191, times=215, szlig=223, divide=247,
	ndash=8211, mdash=8212, lsquo=8216, rsquo=8217, ldquo=8220, rdquo=8221,
	bull=8226, hellip=8230, euro=8364,
}

local XML_ENTITIES = { amp=true, lt=true, gt=true, quot=true, apos=true }


-- The search endpoint declares UTF-8 but emits Latin-1 bytes in headings
-- such as RT\201. Preserve valid UTF-8 sequences; convert isolated legacy
-- bytes in visible fields to numeric references for Expat's UTF-8 decoder.
local function prepareUtf8Text(value)
	local parts, index = {}, 1
	while index <= #value do
		local byte = string.byte(value, index)
		local count = 1
		if byte >= 194 and byte <= 223 then count = 2
		elseif byte >= 224 and byte <= 239 then count = 3
		elseif byte >= 240 and byte <= 244 then count = 4 end
		local valid = byte < 128 or count > 1
		for offset = 1, count - 1 do
			local continuation = string.byte(value, index + offset)
			if not continuation or continuation < 128 or continuation > 191 then valid = false; break end
		end
		local second = string.byte(value, index + 1)
		if count == 3 and second and ((byte == 224 and second < 160) or (byte == 237 and second >= 160)) then valid = false end
		if count == 4 and second and ((byte == 240 and second < 144) or (byte == 244 and second >= 144)) then valid = false end
		if valid then
			parts[#parts + 1] = string.sub(value, index, index + count - 1)
			index = index + count
		else
			parts[#parts + 1] = "&#" .. tostring(byte) .. ";"
			index = index + 1
		end
	end
	return table.concat(parts)
end


local function validXmlCodepoint(value)
	return value == 9 or value == 10 or value == 13
		or value >= 32 and value <= 55295
		or value >= 57344 and value <= 65533
		or value >= 65536 and value <= 1114111
end


local function entityReplacement(token)
	if XML_ENTITIES[token] then return "&" .. token .. ";" end
	local decimal = token:match("^#(%d+)$")
	local hexadecimal = token:match("^#[xX]([%da-fA-F]+)$")
	if decimal or hexadecimal then
		local value = tonumber(decimal or hexadecimal, hexadecimal and 16 or 10)
		if value and validXmlCodepoint(value) then return "&" .. token .. ";" end
		return "&amp;" .. token .. ";"
	end
	local value = HTML_ENTITIES[token]
	if value then return "&#" .. tostring(value) .. ";" end
	return "&amp;" .. token .. ";"
end


local function prepareVisibleEntities(value)
	-- A single substitution never revisits its output: &amp;amp;agrave;
	-- remains &agrave; after Expat, while &amp;agrave; becomes UTF-8 à.
	value = string.gsub(value, "&amp;([%w#]+);", function(token)
		return entityReplacement(token)
	end)
	local output, position = {}, 1
	while true do
		local amp = string.find(value, "&", position, true)
		if not amp then
			output[#output + 1] = string.sub(value, position)
			break
		end
		output[#output + 1] = string.sub(value, position, amp - 1)
		local semicolon = string.find(value, ";", amp + 1, true)
		if semicolon and semicolon - amp <= 32 then
			local token = string.sub(value, amp + 1, semicolon - 1)
			if token:match("^[%w#]+$") then
				output[#output + 1] = entityReplacement(token)
				position = semicolon + 1
			else
				output[#output + 1] = "&amp;"
				position = amp + 1
			end
		else
			output[#output + 1] = "&amp;"
			position = amp + 1
		end
	end
	return table.concat(output)
end


local function prepareVisibleFields(xml)
	local declaration = xml:match("^%s*<%?xml(.-)%?>") or ""
	local encoding = declaration:match("encoding%s*=%s*['\"]([^'\"]+)['\"]")
	local utf8 = not encoding or string.lower(encoding) == "utf-8" or string.lower(encoding) == "utf8"
	local function visible(value)
		if utf8 then value = prepareUtf8Text(value) end
		return prepareVisibleEntities(value)
	end
	local function attributes(prefix, quote, value)
		local name = prefix:match("([%w_:%-]+)%s*=%s*$") or ""
		name = string.lower(name:match("([^:]+)$") or name)
		if name == "text" or name == "title" then
			value = visible(value)
		end
		return prefix .. quote .. value .. quote
	end
	xml = string.gsub(xml, "([%s][%w_:%-]+%s*=%s*)(\")(.-)%2", attributes)
	xml = string.gsub(xml, "([%s][%w_:%-]+%s*=%s*)(')(.-)%2", attributes)
	return string.gsub(xml, "(<[%w_:%-]*title[^>]*>)(.-)(</[%w_:%-]*title%s*>)",
		function(opening, value, closing)
			return opening .. visible(value) .. closing
		end)
end


local function localName(tag)
	return (tag or ""):match("([^:]+)$")
end


local function childElements(node, tag)
	local children = {}
	for _, child in ipairs(node) do
		if type(child) == "table" and (not tag or localName(child.tag) == tag) then
			children[#children + 1] = child
		end
	end
	return children
end


local function firstChild(node, tag)
	for _, child in ipairs(node) do
		if type(child) == "table" and localName(child.tag) == tag then
			return child
		end
	end
end


local function textContent(node)
	local parts = {}
	for _, child in ipairs(node or {}) do
		if type(child) == "string" then
			parts[#parts + 1] = child
		end
	end
	return table.concat(parts):match("^%s*(.-)%s*$")
end


local function convertOutline(outline)
	local attr = outline.attr or {}
	local children = childElements(outline, "outline")
	local entryType = string.lower(attr.type or "")
	local item = {
		title = attr.text or attr.title or "",
		type = (#children > 0 and entryType == "") and "directory" or entryType,
	}

	item.url = attr.URL or attr.url
	if attr.id then item.id = attr.id end
	if attr.icon then item.icon = attr.icon end
	if attr.image then item.image = attr.image end
	if attr.codec then item.codec = attr.codec end
	if attr.bitrate then item.bitrate = tonumber(attr.bitrate) end

	if #children > 0 then
		item.children = {}
		for _, child in ipairs(children) do
			item.children[#item.children + 1] = convertOutline(child)
		end
	end

	return item
end


function parse(xml)
	if type(xml) ~= "string" or xml == "" then
		return nil, "RadioFeeds OPML is empty"
	end

	local ok, tree, err = pcall(lom.parse, prepareVisibleFields(xml))
	if not ok then
		return nil, "Invalid RadioFeeds XML: " .. tostring(tree)
	end
	if not tree then
		return nil, "Invalid RadioFeeds XML: " .. tostring(err)
	end
	if localName(tree.tag) ~= "opml" then
		return nil, "RadioFeeds response root is not OPML"
	end

	local body = firstChild(tree, "body")
	if not body then
		return nil, "RadioFeeds OPML has no body"
	end

	local result = { title = "RadioFeeds", children = {} }
	local head = firstChild(tree, "head")
	local title = head and firstChild(head, "title")
	if title and textContent(title) ~= "" then
		result.title = textContent(title)
	end

	for _, outline in ipairs(childElements(body, "outline")) do
		result.children[#result.children + 1] = convertOutline(outline)
	end

	return result
end
