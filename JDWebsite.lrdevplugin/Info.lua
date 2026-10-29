--[[ JD Photographer Website — Lightroom Classic publish service.

Publishes three collections (Weddings, Portraits, Homepage Hero) into the
site repo's assets/img, rewrites content/portfolio.yml, and can build,
commit and push. See ../README.md. ]]

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'au.jarraddearman.website',
	LrPluginName = 'JD Photographer Website',
	LrPluginInfoUrl = 'https://www.jarraddearman.au',

	LrExportServiceProvider = {
		title = 'JD Photographer Website',
		file = 'PublishServiceProvider.lua',
	},

	VERSION = { major = 1, minor = 0, revision = 0 },
}
