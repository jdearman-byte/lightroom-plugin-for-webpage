--[[ Log.lua — shared logger. Writes to JDWebsite.log in Lightroom's log
folder (~/Documents/LrClassicLogs/ on recent versions of Lightroom Classic).
Send that file, plus JDWebsite-sync.log next to it, when something goes wrong. ]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('JDWebsite')
logger:enable('logfile')

return logger
