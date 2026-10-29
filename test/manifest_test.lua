--[[ Runs Manifest.lua outside Lightroom with stubbed SDK modules.
     lua5.1 test/manifest_test.lua <repo>
   <repo> must contain assets/img and content/; run-tests.sh sets one up. ]]

local root = assert(arg[1], 'usage: manifest_test.lua <repo>')
package.path = arg[0]:gsub('test/manifest_test.lua$', '') .. 'JDWebsite.lrdevplugin/?.lua;' .. package.path

local prefs = {}
local stubs = {
	LrDate = { timeToUserFormat = function(t) return t end },
	LrPathUtils = { child = function(a, b) return a .. '/' .. b end, parent = function(p) return (p:gsub('/[^/]*$', '')) end },
	LrPrefs = { prefsForPlugin = function() return prefs end },
	LrLogger = function() return { enable = function() end, info = function() end, error = function() end } end,
	LrFileUtils = {
		exists = function(p)
			if os.execute('test -d "' .. p .. '"') == 0 then return 'directory' end
			local f = io.open(p, 'rb'); if f then f:close(); return 'file' end
			return false
		end,
		delete = function(p) return os.remove(p) end,
	},
}
function import(name) return stubs[name] end

local Manifest = require 'Manifest'

local failures = 0
local function check(cond, msg)
	if cond then print('ok   ' .. msg) else print('FAIL ' .. msg); failures = failures + 1 end
end

-- fake catalogue objects
local function photo(id, fileName, caption, captured)
	return {
		localIdentifier = id,
		getFormattedMetadata = function(_, k)
			if k == 'fileName' then return fileName end
			if k == 'caption' then return caption end
			return nil
		end,
		getRawMetadata = function(_, k) if k == 'dateTimeOriginal' then return captured end end,
	}
end
local function collection(id, name, photos, parent)
	local pubs = {}
	for i, p in ipairs(photos) do pubs[i] = { getPhoto = function() return p end } end
	return {
		localIdentifier = id,
		getName = function() return name end,
		getParent = function() return parent end,
		getPublishedPhotos = function() return pubs end,
	}
end
local function set(name, children)
	local s = { getName = function() return name end, getParent = function() return nil end,
		getChildCollections = function() return children end, getChildCollectionSets = function() return {} end }
	return s
end

local img = root .. '/assets/img/'
local function cp(src, dst) os.execute('cp "' .. img .. src .. '" "' .. img .. dst .. '"') end

-- 3000x2000-ish landscape and portrait files from the existing portfolio
cp('portfolio-wedding-03.jpg', 'portfolio-wedding-101.jpg')  -- landscape
cp('portfolio-wedding-01.jpg', 'portfolio-wedding-102.jpg')  -- portrait
cp('portfolio-wedding-03.jpg', 'portfolio-wedding-103.jpg')
cp('portfolio-portrait-01.jpg', 'portfolio-portrait-201.jpg')
cp('hero-home.jpg', 'hero-301.jpg')
cp('portfolio-wedding-01.jpg', 'hero-302.jpg')               -- portrait hero → warning

local w, h = Manifest.jpegSize(img .. 'hero-home.jpg')
check(w == 1800 and h == 1012, 'jpegSize reads 1800x1012 from hero-home.jpg')
check(Manifest.jpegSize(root .. '/nope.jpg') == nil, 'jpegSize returns nil for a missing file')

local weddingSub = nil
local weddingsSet = set('Weddings', {})
weddingSub = collection(11, 'Smith, March 2026', {
	photo(102, 'DSCF0102.RAF', 'Bride, "before" the ceremony', '2026-03-01T10:00:00'),
}, weddingsSet)
local weddings = collection(10, 'Weddings', {
	photo(101, 'DSCF0101.RAF', 'First dance', '2026-09-12T14:03:00'),
	photo(103, 'DSCF0103.RAF', '   ', nil),
	photo(104, 'DSCF0104.RAF', 'not exported yet', '2026-10-01T00:00:00'),
})
local portraits = collection(20, 'portraits', { photo(201, 'GFX0201.RAF', 'Maternity portrait\nby the sea', '2026-05-05T09:00:00') })
local hero = collection(30, 'Homepage Hero', { photo(301, 'A.RAF', 'Hero one', nil), photo(302, 'B.RAF', nil, nil) })
local stray = collection(40, 'Misc', { photo(101, 'DSCF0101.RAF', 'x', nil) })

local service = {
	getChildCollections = function() return { weddings, portraits, hero, stray } end,
	getChildCollectionSets = function() return { weddingsSet } end,
}
weddingsSet.getChildCollections = function() return { weddingSub } end

check(Manifest.categoryOf(weddingSub) == 'weddings', 'collection inside the Weddings set counts as weddings')
check(Manifest.categoryOf(portraits) == 'portraits', 'collection names match case-insensitively')
check(Manifest.categoryOf(stray) == nil, 'unknown collection has no category')

local settings = { repoPath = root }
local m, warnings = Manifest.build(service, settings)
local files = {}
for _, it in ipairs(m.weddings) do files[#files + 1] = it.file end
check(table.concat(files, ',') == 'portfolio-wedding-101.jpg,portfolio-wedding-102.jpg,portfolio-wedding-103.jpg',
	'weddings newest first, undated last, unexported skipped: ' .. table.concat(files, ','))
check(m.weddings[3].alt == 'Wedding', 'blank caption falls back to "Wedding"')
check(m.hero[2].alt == 'Wedding photography, Adelaide', 'hero fallback alt')
check(m.weddings[1].width == 1800 and m.weddings[1].height == 1200, 'dimensions come from the exported file')
check(m.hero[1].captured == nil, 'hero entries carry no capture date')
check(#warnings == 2 and warnings[1]:find('DSCF0103.RAF') and warnings[1]:find('B.RAF') and warnings[2]:find('B.RAF'),
	'warnings list missing captions and the portrait hero')

Manifest.saveSequence(30, { 'hero-302.jpg', 'hero-301.jpg' })
m = Manifest.build(service, settings)
check(m.hero[1].file == 'hero-302.jpg', 'hero follows the saved manual order')

m = Manifest.build(service, settings, { exclude = { [10] = { ['portfolio-wedding-101.jpg'] = true } } })
check(#m.weddings == 2, 'excluded (being removed) photo is left out')

m = Manifest.build(service, settings, { skipCollections = { [20] = true } })
local ok, reason = Manifest.write(m, settings)
check(not ok and reason:find('Portraits has no published photos'), 'refuses to write with an empty set')

m = Manifest.build(service, settings)
check(Manifest.write(m, settings), 'writes portfolio.yml')
local f = io.open(root .. '/content/portfolio.yml'); local first = f:read('*a'); f:close()
Manifest.write(Manifest.build(service, settings), settings)
f = io.open(root .. '/content/portfolio.yml'); local second = f:read('*a'); f:close()
check(first == second, 'rewriting an unchanged manifest gives identical bytes')
check(first:find('alt: "Bride, \\"before\\" the ceremony"', 1, true) and first:find('alt: "Maternity portrait\\nby the sea"', 1, true),
	'quotes and newlines are escaped')
check(first:find('captured: 2026%-09%-12T14:03:00'), 'capture date written')

print(failures == 0 and 'all passed' or (failures .. ' failed'))
os.exit(failures == 0 and 0 or 1)
