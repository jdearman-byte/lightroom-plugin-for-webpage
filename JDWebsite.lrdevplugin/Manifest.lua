--[[ Manifest.lua
Builds content/portfolio.yml from what is published in the three website
collections, and works out where files live in the site repo.

The manifest is always rebuilt from scratch: every photo in a website
collection whose exported file exists in assets/img gets an entry. That
keeps it correct however Lightroom splits a publish into per-collection
calls, and photos that are queued but not yet exported simply don't appear. ]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'

local Log = require 'Log'

local Manifest = {}

Manifest.ORDER = { 'weddings', 'portraits', 'hero' }

Manifest.CATEGORIES = {
	weddings  = { title = 'Weddings',      prefix = 'portfolio-wedding-',  fallbackAlt = 'Wedding' },
	portraits = { title = 'Portraits',     prefix = 'portfolio-portrait-', fallbackAlt = 'Portrait' },
	hero      = { title = 'Homepage Hero', prefix = 'hero-',               fallbackAlt = 'Wedding photography, Adelaide' },
}

local HEADER = [[
# Homepage portfolio and hero, generated into index.html by build-journal.js.
# Written by the Lightroom publish plugin (jdearman-byte/lightroom-plugin-for-webpage)
# on every publish, so edit captions in Lightroom rather than here. Galleries
# are listed in the order they appear (the plugin writes newest first); hero
# is in slide order.
]]

-------------------------------------------------------------------------------
-- Paths (settings.repoPath is the local clone of the site repo, deploy-netlify/)

function Manifest.imageDir(settings)
	return LrPathUtils.child(LrPathUtils.child(settings.repoPath, 'assets'), 'img')
end

function Manifest.gitDir(settings)
	return settings.repoPath
end

function Manifest.manifestPath(settings)
	return LrPathUtils.child(LrPathUtils.child(settings.repoPath, 'content'), 'portfolio.yml')
end

-------------------------------------------------------------------------------
-- Collections

-- A collection belongs to a site section by its own name or by the name of
-- any set it sits inside, so "Weddings > Smith, March 2026" still counts.
function Manifest.categoryOf(collection)
	local node = collection
	while node do
		local name = string.lower(node:getName() or '')
		for _, key in ipairs(Manifest.ORDER) do
			if name == string.lower(Manifest.CATEGORIES[key].title) then return key end
		end
		node = node:getParent()
	end
	return nil
end

function Manifest.fileNameFor(category, photo)
	return Manifest.CATEGORIES[category].prefix .. tostring(photo.localIdentifier) .. '.jpg'
end

local function collectCollections(parent, out)
	for _, c in ipairs(parent:getChildCollections() or {}) do out[#out + 1] = c end
	for _, s in ipairs(parent:getChildCollectionSets() or {}) do collectCollections(s, out) end
	return out
end

function Manifest.allCollections(service)
	return collectCollections(service, {})
end

-------------------------------------------------------------------------------
-- Helpers that don't need Lightroom (covered by test/manifest_test.lua)

-- Width and height from a JPEG's SOF marker.
function Manifest.jpegSize(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('*a')
	f:close()
	if not data or data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
	local i = 3
	local len = #data
	while i + 8 <= len do
		if data:byte(i) ~= 0xFF then
			i = i + 1
		else
			local marker = data:byte(i + 1)
			if marker == 0xFF then
				i = i + 1
			elseif marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
				i = i + 2
			else
				if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
					local h = data:byte(i + 5) * 256 + data:byte(i + 6)
					local w = data:byte(i + 7) * 256 + data:byte(i + 8)
					return w, h
				end
				i = i + 2 + data:byte(i + 2) * 256 + data:byte(i + 3)
			end
		end
	end
	return nil
end

local function yamlString(s)
	s = tostring(s or '')
	s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r\n', '\n'):gsub('\n', '\\n'):gsub('\t', '\\t')
	return '"' .. s .. '"'
end

-- Fixed key order and formatting so republishing an unchanged collection
-- leaves the file byte-for-byte the same (clean git diffs).
function Manifest.toYaml(manifest)
	local lines = { HEADER }
	for _, key in ipairs(Manifest.ORDER) do
		lines[#lines + 1] = key .. ':'
		for _, item in ipairs(manifest[key] or {}) do
			lines[#lines + 1] = '  - file: ' .. item.file
			lines[#lines + 1] = '    alt: ' .. yamlString(item.alt)
			lines[#lines + 1] = '    width: ' .. tostring(item.width)
			lines[#lines + 1] = '    height: ' .. tostring(item.height)
			if item.captured then lines[#lines + 1] = '    captured: ' .. item.captured end
		end
	end
	return table.concat(lines, '\n') .. '\n'
end

-- Galleries: newest first by capture date; undated photos go last. File name
-- breaks ties so the order is stable between publishes.
function Manifest.sortGallery(items)
	table.sort(items, function(a, b)
		if a.captured and b.captured and a.captured ~= b.captured then return a.captured > b.captured end
		if (a.captured ~= nil) ~= (b.captured ~= nil) then return a.captured ~= nil end
		return a.file < b.file
	end)
	return items
end

-- Hero: the collection's manual order, as last reported by Lightroom through
-- imposeSortOrderOnPublishedCollection. Anything not in it keeps its place
-- after the ordered ones.
function Manifest.sortBySequence(items, sequence)
	local rank = {}
	for i, id in ipairs(sequence or {}) do rank[id] = i end
	for i, item in ipairs(items) do item._pos = i end
	table.sort(items, function(a, b)
		local ra, rb = rank[a.file], rank[b.file]
		if ra and rb then return ra < rb end
		if ra or rb then return ra ~= nil end
		return a._pos < b._pos
	end)
	for _, item in ipairs(items) do item._pos = nil end
	return items
end

function Manifest.emptySets(manifest)
	local empty = {}
	for _, key in ipairs(Manifest.ORDER) do
		if #(manifest[key] or {}) == 0 then empty[#empty + 1] = Manifest.CATEGORIES[key].title end
	end
	return empty
end

-------------------------------------------------------------------------------
-- Custom order storage (prefs hold strings reliably, so join the ids)

function Manifest.saveSequence(collectionId, remoteIds)
	LrPrefs.prefsForPlugin()['order_' .. tostring(collectionId)] = table.concat(remoteIds or {}, '\n')
end

function Manifest.loadSequence(collectionId)
	local raw = LrPrefs.prefsForPlugin()['order_' .. tostring(collectionId)]
	local seq = {}
	if raw and raw ~= '' then
		for id in string.gmatch(raw, '[^\n]+') do seq[#seq + 1] = id end
	end
	return seq
end

-------------------------------------------------------------------------------
-- Build and write

local function captureTime(photo)
	local t = photo:getRawMetadata('dateTimeOriginal') or photo:getRawMetadata('dateTimeDigitized')
	if not t then return nil end
	return LrDate.timeToUserFormat(t, '%Y-%m-%dT%H:%M:%S')
end

local function displayName(photo)
	local name = photo:getFormattedMetadata('fileName') or '?'
	local copy = photo:getFormattedMetadata('copyName')
	if copy and copy ~= '' then name = name .. ' (' .. copy .. ')' end
	return name
end

--[[ opts.exclude: { [collectionLocalId] = { [fileName] = true } } — photos
     being removed right now (Lightroom still lists them until the delete
     callback returns).
     opts.skipCollections: { [collectionLocalId] = true } — a collection being
     deleted.
   Returns manifest, warnings (list of strings). ]]
function Manifest.build(service, settings, opts)
	opts = opts or {}
	local exclude = opts.exclude or {}
	local skip = opts.skipCollections or {}
	local imgDir = Manifest.imageDir(settings)
	local manifest = { weddings = {}, portraits = {}, hero = {} }
	local seen = {}
	local missingCaption, notLandscape = {}, {}

	for _, collection in ipairs(Manifest.allCollections(service)) do
		local id = collection.localIdentifier
		local category = Manifest.categoryOf(collection)
		if category and not skip[id] then
			local excluded = exclude[id] or {}
			local items = {}
			for _, published in ipairs(collection:getPublishedPhotos() or {}) do
				local photo = published:getPhoto()
				local fileName = Manifest.fileNameFor(category, photo)
				local path = LrPathUtils.child(imgDir, fileName)
				if not excluded[fileName] and not seen[fileName] and LrFileUtils.exists(path) == 'file' then
					seen[fileName] = true
					local w, h = Manifest.jpegSize(path)
					local caption = photo:getFormattedMetadata('caption')
					local alt = caption
					if not alt or alt:match('^%s*$') then
						alt = Manifest.CATEGORIES[category].fallbackAlt
						missingCaption[#missingCaption + 1] = displayName(photo)
					else
						alt = alt:gsub('^%s+', ''):gsub('%s+$', '')
					end
					if category == 'hero' and w and h and w <= h then
						notLandscape[#notLandscape + 1] = displayName(photo)
					end
					items[#items + 1] = {
						file = fileName,
						alt = alt,
						width = w or 0,
						height = h or 0,
						captured = category ~= 'hero' and captureTime(photo) or nil,
					}
				end
			end
			if category == 'hero' then Manifest.sortBySequence(items, Manifest.loadSequence(id)) end
			for _, item in ipairs(items) do table.insert(manifest[category], item) end
		end
	end

	Manifest.sortGallery(manifest.weddings)
	Manifest.sortGallery(manifest.portraits)

	local warnings = {}
	local function listWarning(intro, names)
		if #names == 0 then return end
		local shown = {}
		for i = 1, math.min(#names, 15) do shown[i] = '  ' .. names[i] end
		if #names > 15 then shown[#shown + 1] = string.format('  …and %d more', #names - 15) end
		warnings[#warnings + 1] = intro .. '\n' .. table.concat(shown, '\n')
	end
	listWarning('These photos have no Caption, so they use a generic alt text. Add a Caption in the Metadata panel and republish:', missingCaption)
	listWarning('These Homepage Hero photos are not landscape and will be cropped hard on wide screens:', notLandscape)
	return manifest, warnings
end

-- Writes content/portfolio.yml. Refuses (returns false + reason) if a set
-- is empty: the site build would fail on it, so the site keeps its current
-- gallery until each set has at least one published photo.
function Manifest.write(manifest, settings)
	local empty = Manifest.emptySets(manifest)
	if #empty > 0 then
		return false, 'portfolio.yml was not updated because ' .. table.concat(empty, ' and ') ..
			(#empty > 1 and ' have' or ' has') .. ' no published photos yet. The website keeps its current gallery until every collection has at least one.'
	end
	local path = Manifest.manifestPath(settings)
	if LrFileUtils.exists(LrPathUtils.parent(path)) ~= 'directory' then
		return false, 'No content folder found in ' .. tostring(settings.repoPath) .. '. Check the site folder in the publish service settings.'
	end
	local tmp = path .. '.tmp'
	local f, err = io.open(tmp, 'wb')
	if not f then return false, 'Could not write ' .. path .. ': ' .. tostring(err) end
	f:write(Manifest.toYaml(manifest))
	f:close()
	if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
	if not os.rename(tmp, path) then return false, 'Could not replace ' .. path end
	Log:info('wrote ' .. path)
	return true
end

-- Build + write in one go. Returns written (bool), warnings (list).
function Manifest.update(service, settings, opts)
	local manifest, warnings = Manifest.build(service, settings, opts)
	local written, reason = Manifest.write(manifest, settings)
	if not written then table.insert(warnings, 1, reason) end
	Log:info(string.format('manifest: %d weddings, %d portraits, %d hero, written=%s',
		#manifest.weddings, #manifest.portraits, #manifest.hero, tostring(written)))
	return written, warnings, manifest
end

return Manifest
