--[[ Sync.lua
After a publish: show any manifest warnings, then ask "push now or on next
publish?". "Now" runs sync.sh (pull, build-journal.js, commit, push).
"Next publish" sets a flag in the plugin prefs (kept across restarts); the
next publish then syncs without asking and clears it.

Lightroom publishes each collection in a separate call, so the end-of-publish
step waits a few seconds and only runs once the last call has finished. ]]

local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local Manifest = require 'Manifest'

local Sync = {}

local active = 0        -- publish calls in progress
local generation = 0    -- bumps on every call; a newer call cancels the pending prompt
local warnings = {}     -- latest warnings from the manifest build
local manifestWritten = false
local running = false

local MESSAGES = {
	[3]  = 'Nothing has changed since the last push, so there was nothing to send.',
	[10] = 'Git is busy: deploy-netlify/.git/index.lock exists. Another git command is running (or one crashed). Wait a moment and try again; if it persists, close other git tools and delete that file.',
	[11] = 'Could not reach GitHub. Check your internet connection, then use Push now in the publish service settings (or publish again).',
	[12] = 'GitHub refused the login. Push once from Terminal in deploy-netlify/ so macOS saves your credentials (or check your SSH key), then try again.',
	[13] = 'Your local deploy-netlify/ has changes that clash with commits on GitHub (for example a journal post edited in the CMS). Nothing was pushed. Open deploy-netlify/ in Terminal, run git status, and resolve it there.',
	[14] = 'The site build (node build-journal.js) failed, so nothing was committed. The log shows why; a broken portfolio.yml or a missing image stops the build on purpose, and Node.js must be installed.',
	[15] = 'git commit failed. The log has git\'s message.',
	[16] = 'GitHub rejected the push. The log has git\'s message.',
	[17] = 'The site folder could not be found, or it is not the site repo. Check the path in the publish service settings.',
	[18] = 'deploy-netlify/ is not on the expected branch. Switch back to it in Terminal (git checkout main) and try again.',
}

local function prefs()
	return LrPrefs.prefsForPlugin()
end

function Sync.isPending()
	return prefs().pendingSync == true
end

function Sync.statusText()
	return Sync.isPending() and 'A push is waiting for the next publish.' or 'Nothing waiting to be pushed.'
end

local function logDir()
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('documents'), 'LrClassicLogs')
	LrFileUtils.createAllDirectories(dir)
	return dir
end

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function tail(path, n)
	local f = io.open(path, 'r')
	if not f then return '' end
	local lines = {}
	for line in f:lines() do
		lines[#lines + 1] = line
		if #lines > n then table.remove(lines, 1) end
	end
	f:close()
	return table.concat(lines, '\n')
end

-- Runs sync.sh and reports the outcome. Must be called from a task.
function Sync.run(settings)
	if running then return end
	running = true
	LrFunctionContext.callWithContext('JDWebsite sync', function(context)
		context:addCleanupHandler(function() running = false end)
		local progress = LrProgressScope { title = 'Updating jarraddearman.au', functionContext = context }
		progress:setCaption('Building and pushing to GitHub…')

		local script = LrPathUtils.child(_PLUGIN.path, 'sync.sh')
		local log = LrPathUtils.child(logDir(), 'JDWebsite-sync.log')
		local cmd = string.format('/bin/bash %s %s %s %s > %s 2>&1',
			shellQuote(script), shellQuote(Manifest.gitDir(settings)),
			shellQuote(settings.gitRemote or 'origin'), shellQuote(settings.gitBranch or 'main'),
			shellQuote(log))
		Log:info('sync: ' .. cmd)
		local status = LrTasks.execute(cmd)
		-- On macOS this is the raw wait status (exit code * 256).
		if status and status >= 256 then status = math.floor(status / 256) end
		Log:info('sync exit status ' .. tostring(status))
		progress:done()

		if status == 0 or status == 3 then
			prefs().pendingSync = false
			if status == 0 then
				LrDialogs.message('Website updated', 'Pushed to GitHub. Netlify usually has the site live within a couple of minutes.', 'info')
			else
				LrDialogs.message('Nothing to push', MESSAGES[3], 'info')
			end
		else
			-- Keep it queued so the next publish tries again.
			prefs().pendingSync = true
			local reason = MESSAGES[status] or ('The sync step stopped with exit code ' .. tostring(status) .. '.')
			LrDialogs.message('Website not updated', reason ..
				'\n\nThe push will be retried on the next publish.\n\nLast lines of ' .. log .. ':\n' .. tail(log, 12), 'critical')
		end
	end)
end

function Sync.addWarnings(list, written)
	warnings = list or {}
	manifestWritten = written
end

function Sync.beginPublish()
	active = active + 1
	generation = generation + 1
end

-- Called at the end of every publish callback.
function Sync.endPublish(settings)
	active = math.max(0, active - 1)
	generation = generation + 1
	local mine = generation
	LrTasks.startAsyncTask(function()
		LrTasks.sleep(3)
		if mine ~= generation or active > 0 then return end
		Sync.finish(settings)
	end)
end

function Sync.finish(settings)
	local shown = warnings
	warnings = {}
	if #shown > 0 then
		LrDialogs.message('Website publish: please check', table.concat(shown, '\n\n'), 'warning')
	end
	if not manifestWritten then
		Log:info('manifest not written; skipping push prompt')
		return
	end
	if Sync.isPending() then
		Log:info('pending push from an earlier publish; syncing now')
		Sync.run(settings)
		return
	end
	local choice = LrDialogs.confirm('Push to git now, or on next publish?',
		'The images and portfolio.yml are updated in deploy-netlify. Pushing rebuilds the pages and sends the changes to GitHub, and Netlify then publishes the site.',
		'Push now', 'Next publish')
	if choice == 'ok' then
		Sync.run(settings)
	else
		prefs().pendingSync = true
		Log:info('push deferred to next publish')
	end
end

return Sync
