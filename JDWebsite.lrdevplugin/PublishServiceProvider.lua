--[[ PublishServiceProvider.lua
"JD Photographer Website" publish service.

Collections: Weddings, Portraits, Homepage Hero (created with the service).
A collection inside a set with one of those names counts too. Each photo is
exported once per section as portfolio-wedding-{id}.jpg,
portfolio-portrait-{id}.jpg or hero-{id}.jpg in assets/img, where {id}
is the photo's Lightroom local ID, so a re-edit replaces the same file.
Everything is written straight into the local clone of the site repo
(deploy-netlify/), which is the source of truth. ]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Log = require 'Log'
local Manifest = require 'Manifest'
local Sync = require 'Sync'

local DEFAULT_REPO = LrPathUtils.getStandardFilePath('home') ..
	'/Library/Mobile Documents/com~apple~CloudDocs/Photography/JDPhotographer/Website/deploy-netlify'

local provider = {}

provider.supportsIncrementalPublish = 'only'
provider.supportsCustomSortOrder = true
provider.canExportVideo = false

-- The export settings are fixed by the site (see updateExportSettings);
-- only sharpening and watermarking stay visible.
provider.hideSections = { 'exportLocation', 'fileNaming', 'fileSettings', 'imageSettings', 'metadata', 'video' }
provider.allowFileFormats = { 'JPEG' }
provider.allowColorSpaces = { 'sRGB' }
provider.hidePrintResolution = true

provider.exportPresetFields = {
	{ key = 'repoPath', default = DEFAULT_REPO },
	{ key = 'gitRemote', default = 'origin' },
	{ key = 'gitBranch', default = 'main' },
}

-- JPEG, 3000px long edge, sRGB, quality 85. Embedded metadata is limited to
-- copyright: Lightroom has no "copyright + caption" option, and the caption
-- reaches the site as alt text through portfolio.yml anyway.
function provider.updateExportSettings(settings)
	settings.LR_format = 'JPEG'
	settings.LR_jpeg_quality = 0.85
	settings.LR_jpeg_useLimitSize = false
	settings.LR_export_colorSpace = 'sRGB'
	settings.LR_size_doConstrain = true
	settings.LR_size_doNotEnlarge = true
	settings.LR_size_resizeType = 'longEdge'
	settings.LR_size_maxWidth = 3000
	settings.LR_size_maxHeight = 3000
	settings.LR_size_units = 'pixels'
	settings.LR_embeddedMetadataOption = 'copyrightOnly'
	settings.LR_removeLocationMetadata = true
	settings.LR_removeFaceMetadata = true
	settings.LR_includeVideoFiles = false
end

-- Editing the caption (alt text) or capture time (gallery order) marks a
-- photo for republish; develop edits do so automatically.
function provider.metadataThatTriggersRepublish(publishSettings)
	return { default = false, caption = true, dateCreated = true }
end

function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = Manifest.CATEGORIES.weddings.title,
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
		maxCollectionSetDepth = 1,
	}
end

function provider.didCreateNewPublishService(publishSettings, info)
	LrTasks.startAsyncTask(function()
		LrApplication.activeCatalog():withWriteAccessDo('Create website collections', function()
			for _, key in ipairs(Manifest.ORDER) do
				-- true: return the existing collection rather than make a duplicate
				info.publishService:createPublishedCollection(Manifest.CATEGORIES[key].title, nil, true)
			end
		end)
	end)
end

-------------------------------------------------------------------------------
-- Settings dialog

function provider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share
	propertyTable.syncStatus = Sync.statusText()

	local function label(title)
		return f:static_text { title = title, alignment = 'right', width = share 'labelWidth' }
	end

	return {
		{
			title = 'Website',
			synopsis = bind 'repoPath',

			f:row {
				label 'Site folder:',
				f:edit_field { value = bind 'repoPath', width_in_chars = 42, immediate = true },
				f:push_button {
					title = 'Choose…',
					action = function()
						local chosen = LrDialogs.runOpenPanel {
							title = 'Choose the site repo folder (deploy-netlify)',
							canChooseFiles = false, canChooseDirectories = true, allowsMultipleSelection = false,
						}
						if chosen then propertyTable.repoPath = chosen[1] end
					end,
				},
			},
			f:row {
				label 'Git remote:',
				f:edit_field { value = bind 'gitRemote', width_in_chars = 10 },
				f:static_text { title = 'Branch:' },
				f:edit_field { value = bind 'gitBranch', width_in_chars = 10 },
			},
			f:row {
				label '',
				f:static_text { title = bind 'syncStatus', width_in_chars = 34 },
				f:push_button {
					title = 'Push now',
					action = function()
						LrTasks.startAsyncTask(function()
							Sync.run(propertyTable)
							propertyTable.syncStatus = Sync.statusText()
						end)
					end,
				},
			},
			f:row {
				label '',
				f:static_text {
					title = 'Images go to assets/img and the list to content/portfolio.yml. Logs: ~/Documents/LrClassicLogs/JDWebsite*.log',
					width_in_chars = 50, height_in_lines = 2,
				},
			},
		},
	}
end

-------------------------------------------------------------------------------
-- Publishing

local function rebuild(service, settings, opts)
	local written, warnings = Manifest.update(service, settings, opts)
	Sync.addWarnings(warnings, written)
end

function provider.processRenderedPhotos(functionContext, exportContext)
	local settings = exportContext.propertyTable
	local collection = exportContext.publishedCollection
	local category = Manifest.categoryOf(collection)
	local imgDir = Manifest.imageDir(settings)
	local nPhotos = exportContext.exportSession:countRenditions()

	Sync.beginPublish()
	Log:info(string.format('publish %d photo(s) to %s (%s)', nPhotos, collection:getName(), tostring(category)))

	exportContext:configureProgress {
		title = nPhotos > 1 and string.format('Publishing %d photos to the website', nPhotos) or 'Publishing one photo to the website',
	}

	local ok, err = LrTasks.pcall(function()
		if category and LrFileUtils.exists(imgDir) ~= 'directory' then
			error('Image folder not found: ' .. imgDir .. '. Check the site folder in the publish service settings.')
		end
		for _, rendition in exportContext:renditions { stopIfCanceled = true } do
			if not category then
				rendition:skipRender()
				rendition:uploadFailed('Move "' .. collection:getName() .. '" inside Weddings, Portraits or Homepage Hero.')
			else
				local success, pathOrMessage = rendition:waitForRender()
				if success then
					local fileName = Manifest.fileNameFor(category, rendition.photo)
					local dest = LrPathUtils.child(imgDir, fileName)
					if LrFileUtils.exists(dest) then LrFileUtils.delete(dest) end
					if LrFileUtils.copy(pathOrMessage, dest) then
						LrFileUtils.delete(pathOrMessage)
						rendition:recordPublishedPhotoId(fileName)
						Log:info('exported ' .. fileName)
					else
						rendition:uploadFailed('Could not copy the export to ' .. dest)
					end
				else
					rendition:uploadFailed(pathOrMessage)
				end
			end
		end
	end)
	if not ok then
		Log:error('publish failed: ' .. tostring(err))
		LrDialogs.message('Website publish failed', tostring(err), 'critical')
	end

	if category then rebuild(collection:getService(), settings) end
	Sync.endPublish(settings)
end

-- Removing photos from a collection and publishing: delete their files
-- (unless another collection of the same section still shows the photo)
-- and drop them from the manifest.
function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
	local collection = LrApplication.activeCatalog():getPublishedCollectionByLocalIdentifier(localCollectionId)
	Sync.beginPublish()
	local removing = {}
	for _, id in ipairs(arrayOfPhotoIds) do removing[id] = true end

	local stillUsed = {}
	local service = collection and collection:getService()
	if service then
		local manifest = Manifest.build(service, publishSettings, { exclude = { [localCollectionId] = removing } })
		for _, key in ipairs(Manifest.ORDER) do
			for _, item in ipairs(manifest[key]) do stillUsed[item.file] = true end
		end
	end

	local imgDir = Manifest.imageDir(publishSettings)
	for _, id in ipairs(arrayOfPhotoIds) do
		local path = LrPathUtils.child(imgDir, id)
		if not stillUsed[id] and LrFileUtils.exists(path) then
			LrFileUtils.delete(path)
			Log:info('deleted ' .. id)
		end
		deletedCallback(id)
	end

	if service then rebuild(service, publishSettings, { exclude = { [localCollectionId] = removing } }) end
	Sync.endPublish(publishSettings)
end

-- Deleting a whole collection removes its photos from the site too.
function provider.deletePublishedCollection(publishSettings, info)
	local collection = info.publishedCollection
	local service = info.publishService or collection:getService()
	local skip = { [collection.localIdentifier] = true }
	local manifest = Manifest.build(service, publishSettings, { skipCollections = skip })
	local stillUsed = {}
	for _, key in ipairs(Manifest.ORDER) do
		for _, item in ipairs(manifest[key]) do stillUsed[item.file] = true end
	end
	local imgDir = Manifest.imageDir(publishSettings)
	for _, published in ipairs(collection:getPublishedPhotos() or {}) do
		local id = published:getRemoteId()
		if id and not stillUsed[id] then
			local path = LrPathUtils.child(imgDir, id)
			if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
		end
	end
	Sync.beginPublish()
	rebuild(service, publishSettings, { skipCollections = skip })
	Sync.endPublish(publishSettings)
end

-- Lightroom reports the collection's manual order after a publish; the hero
-- uses it for slide order (the first slide is the preloaded one).
function provider.imposeSortOrderOnPublishedCollection(publishSettings, info, remoteIdSequence)
	local collection = info.publishedCollection
	if not collection then return end
	Manifest.saveSequence(collection.localIdentifier, remoteIdSequence)
	if Manifest.categoryOf(collection) == 'hero' then
		Sync.beginPublish()
		rebuild(collection:getService(), publishSettings)
		Sync.endPublish(publishSettings)
	end
end

return provider
