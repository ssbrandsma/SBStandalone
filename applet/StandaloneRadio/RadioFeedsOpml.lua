local lom = require("lxp.lom")
local ipairs, pcall, tonumber, type = ipairs, pcall, tonumber, type
local string, table, tostring = string, table, tostring

module(...)


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

	local ok, tree, err = pcall(lom.parse, xml)
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
