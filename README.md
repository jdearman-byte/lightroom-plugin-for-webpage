# JD Photographer Website: Lightroom Classic publish service

Drag photos into three publish collections, click **Publish**, and the homepage's wedding gallery, portrait gallery and hero carousel update. Remove a photo and publish again, and it disappears from the site.

## How it fits together

Everything happens in `deploy-netlify/`, your local clone of the site repo (the source of truth).

1. **Lightroom** exports each photo as a 3000px sRGB JPEG (quality 85, copyright only in the metadata) into `assets/img/`:
   - **Weddings** → `portfolio-wedding-{id}.jpg`
   - **Portraits** → `portfolio-portrait-{id}.jpg`
   - **Homepage Hero** → `hero-{id}.jpg`

   `{id}` is the photo's Lightroom ID, so a re-edit replaces the same file.
2. It then rewrites `content/portfolio.yml`. Captions become alt text. Galleries are newest first by capture date, and the hero follows the collection's manual order.
3. `build-journal.js` builds the gallery columns and hero slides from `portfolio.yml` (between the `PORTFOLIO_*` and `HERO_*` markers in `index.html`). If the file is missing, a set is empty or an image is missing, the build stops, so a bad publish can't blank the live gallery.
4. After publishing, Lightroom asks **Push to git now, or on next publish?** If you choose "Push now", `sync.sh` runs `git pull`, `node build-journal.js`, `git commit` and `git push` in `deploy-netlify/`, and Netlify takes it from there.

## One-off setup

1. **Check git can push without a prompt.** In Terminal: `cd deploy-netlify && git pull && git push`. If it asks for a password, sign in once (use a GitHub personal access token as the password) and macOS keeps it in the keychain. Lightroom can't answer prompts, so this needs to work silently.
2. **Get the plugin.** In Terminal:
   ```
   cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Photography/JDPhotographer
   git clone https://github.com/jdearman-byte/lightroom-plugin-for-webpage.git lightroom-plugin
   ```
   Later, `git pull` in that folder updates the plugin. It's separate from `deploy-netlify`, so website pulls and plugin pulls never overlap.
3. **Install the plugin.** In Lightroom Classic choose *File → Plug-in Manager → Add*, then select `JDPhotographer/lightroom-plugin/JDWebsite.lrdevplugin` (this repo, `jdearman-byte/lightroom-plugin-for-webpage`, cloned into `JDPhotographer/lightroom-plugin`). `git pull` in `JDPhotographer/lightroom-plugin` updates the plugin; restart Lightroom or click *Reload Plug-in* afterwards.
4. **Create the service.** In the Publish Services panel, click *Set Up…* next to **JD Photographer Website**. The site folder defaults to `deploy-netlify` in your iCloud Website folder; change it if you move it. Click *Save*. Lightroom creates the **Weddings**, **Portraits** and **Homepage Hero** collections.

You can make collections inside a **Weddings** (or Portraits) set, for example one per wedding. Anything inside a set with one of those names counts. Collections elsewhere are rejected when you publish.

## Switching over from the hand-made gallery

The site currently runs on a starting `portfolio.yml` that lists today's 49 gallery images and 3 hero slides. The plugin doesn't write `portfolio.yml` until **all three** collections have at least one published photo. Until then the site keeps its current gallery, so you can build the collections up across several sessions.

Once all three collections have photos, the gallery becomes exactly what's in Lightroom. So before your first full publish, add every photo you want to keep (including the current ones) and give them Captions.

The old files (`portfolio-wedding-01.jpg` and so on) stay in `assets/img/` until you delete them; the build lists any portfolio image that's no longer used. `hero-home.jpg` is also the social-sharing image, so the build won't list it while it's in use.

## Day to day

- **Add:** drag photos into a collection and click *Publish*.
- **Edit:** develop or caption changes move the photo to *Modified Photos to Re-Publish*. Click *Publish*.
- **Remove:** remove the photo from the collection, then click *Publish*. Its file and entry are deleted.
- **Hero order:** set the Homepage Hero collection's sort to *Custom Order*, drag the slides into order, then *Publish*. The first slide is the one that loads first. Landscape works best, and you'll get a warning for anything that isn't landscape.
- **Captions:** a photo with no Caption gets "Wedding", "Portrait" or "Wedding photography, Adelaide" as its alt text, and you get a list of photos missing captions after each publish.
- **Push later:** if you choose *Next publish*, the push waits, even across Lightroom restarts, and the next publish pushes without asking. To push without publishing, open the service's settings (*Edit Settings…*) and click **Push now**.

## When something goes wrong

Errors explain what happened in plain terms: git busy, offline, GitHub login refused, a clash with a CMS edit, or a build failure. A failed push stays queued and is retried on the next publish.

Logs are in `~/Documents/LrClassicLogs/`:
- `JDWebsite.log` records what was exported, deleted and written.
- `JDWebsite-sync.log` holds the output of the last pull, build and push.

Send both if you need help.

## Manual test checklist

The plugin can't run outside Lightroom, so please run through this list once and send the logs back.

**Export (no push yet; choose "Next publish" each time):**
- [ ] The service sets up, and the three collections appear.
- [ ] Publishing 2–3 photos to Weddings writes `portfolio-wedding-{id}.jpg` files at 3000px on the long edge into `deploy-netlify/assets/img/`. `portfolio.yml` is **not** written yet, and a message explains why.
- [ ] After adding one photo each to Portraits and Homepage Hero and publishing, `deploy-netlify/content/portfolio.yml` is written. Weddings are newest first, and captions appear as `alt`.
- [ ] A photo with no caption triggers the missing-caption warning, and a portrait-orientation hero triggers the landscape warning.
- [ ] Editing a published photo and republishing replaces the same file name.
- [ ] Removing a photo and publishing deletes its file and entry.
- [ ] Reordering the hero (Custom Order) and publishing changes the order in `portfolio.yml`. If Lightroom says there's nothing to publish after a reorder, note that in your reply.
- [ ] Publishing all three collections at once shows the push question once, not three times.

**Sync:**
- [ ] Quit and reopen Lightroom, then publish. It pushes without asking (the "Next publish" flag persisted).
- [ ] "Push now" builds and pushes, and the change is live on Netlify a few minutes later.
- [ ] With Wi-Fi off, "Push now" gives the offline message and keeps the push queued.

## Developing

`test/run-tests.sh [path to the site repo]` checks the parts that run outside Lightroom: the manifest logic (with stubbed SDK modules), the site's `build-journal.js` reading the plugin's output, and `sync.sh` against a throwaway git remote. It needs `lua5.1`, `node` and `git`, plus a clone of the site repo (`jdearman-byte/Journal`, with `npm install` done). By default it looks for `../Website/deploy-netlify`.

Files:
- `Info.lua`: plugin registration.
- `PublishServiceProvider.lua`: export settings, settings dialog, publish and delete callbacks.
- `Manifest.lua`: builds and writes `portfolio.yml`.
- `Sync.lua`: the push dialog and the persisted flag, and turns `sync.sh` exit codes into readable messages.
- `sync.sh`: pull, build, commit and push.
- `Log.lua`: writes the log file.
