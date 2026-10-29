#!/bin/bash
# Tests for the parts of the plugin that run outside Lightroom:
# Manifest.lua (with stubbed SDK modules), its output through
# build-journal.js, and sync.sh against a throwaway git remote.
#   test/run-tests.sh [site-repo]   (needs lua5.1, node, git)
# site-repo is a clone of jdearman-byte/Journal with npm install done;
# it defaults to ../Website/deploy-netlify next to this repo.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "${1:-$HERE/../../Website/deploy-netlify}" && pwd) || exit 1
LUA=$(command -v lua5.1 || command -v lua)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

echo "# Manifest.lua"
mkdir -p "$T/assets" "$T/content"
cp -R "$REPO/assets/img" "$T/assets/img"
"$LUA" "$HERE/manifest_test.lua" "$T" || fail=1

echo "# portfolio.yml from the plugin builds the homepage"
B="$T/build"; mkdir -p "$B"
cp -R "$REPO/index.html" "$REPO/journal.html" "$REPO/build-journal.js" "$REPO/content" "$B/"
mkdir -p "$B/assets"; cp -R "$T/assets/img" "$B/assets/img"
cp "$T/content/portfolio.yml" "$B/content/portfolio.yml"
if (cd "$B" && NODE_PATH="$REPO/node_modules" node build-journal.js >/dev/null) \
  && grep -q '<link rel="preload" as="image" href="assets/img/hero-302.jpg">' "$B/index.html" \
  && grep -q 'alt="Bride, &quot;before&quot; the ceremony"' "$B/index.html"; then
  echo "ok   build-journal.js accepts the plugin's manifest"
else
  echo "FAIL build-journal.js with the plugin's manifest"; fail=1
fi

echo "# sync.sh"
bash "$HERE/sync_test.sh" || fail=1

[ $fail = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
