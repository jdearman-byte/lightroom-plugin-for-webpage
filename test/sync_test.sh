#!/bin/bash
# sync.sh against a throwaway bare remote, with a stand-in build-journal.js.
set -u
SYNC="$(cd "$(dirname "$0")/.." && pwd)/JDWebsite.lrdevplugin/sync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com

git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/Website/deploy-netlify" 2>/dev/null
R="$T/Website/deploy-netlify"
# stand-in build: stamps a file, or fails when told to
cat > "$R/build-journal.js" <<'B'
const fs = require('fs');
if (fs.existsSync('../FAIL_BUILD')) { console.error('content/portfolio.yml is missing'); process.exit(1); }
if (fs.existsSync('../CHANGE')) fs.writeFileSync('built.txt', String(Date.now() + Math.random()));
B
printf 'node_modules/\n' > "$R/.gitignore"; mkdir -p "$R/node_modules"
(cd "$R" && git checkout -q -b main && git add -A && git commit -qm init && git push -q origin main 2>/dev/null)

run() { bash "$SYNC" "$R" origin main >"$T/log" 2>&1; echo $?; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (exit $3, expected $2)"; cat "$T/log"; fail=1; fi
}
remote_log() { git --git-dir="$T/remote.git" log --format=%s main; }

touch "$T/Website/CHANGE"
expect "changes are built, committed and pushed" 0 "$(run)"
[ "$(remote_log | head -1)" = "Portfolio update (Lightroom publish)" ] && echo "ok   commit message on the remote" || { echo "FAIL commit message"; fail=1; }

rm "$T/Website/CHANGE"
expect "no changes: nothing to push" 3 "$(run)"

# a CMS commit lands on GitHub while a local change waits
git clone -q "$T/remote.git" "$T/cms" && (cd "$T/cms" && echo post > post.md && git add post.md && git commit -qm "CMS post" && git push -q origin main)
touch "$T/Website/CHANGE"
expect "pulls a remote commit first, then pushes" 0 "$(run)"
remote_log | grep -q "CMS post" && [ -f "$T/Website/deploy-netlify/post.md" ] && echo "ok   remote commit kept" || { echo "FAIL remote commit"; fail=1; }

# a commit whose push failed earlier is pushed on the next run
rm "$T/Website/CHANGE"
(cd "$T/Website/deploy-netlify" && echo x > local.txt && git add local.txt && git commit -qm "Portfolio update (Lightroom publish)")
expect "earlier unpushed commit is pushed" 0 "$(run)"

touch "$T/Website/deploy-netlify/.git/index.lock"
expect "index.lock: git busy" 10 "$(run)"
rm "$T/Website/deploy-netlify/.git/index.lock"

touch "$T/Website/FAIL_BUILD"
expect "build failure stops before commit" 14 "$(run)"
rm "$T/Website/FAIL_BUILD"

(cd "$T/Website/deploy-netlify" && git checkout -q -b other)
expect "wrong branch" 18 "$(run)"
(cd "$T/Website/deploy-netlify" && git checkout -q main)

(cd "$T/Website/deploy-netlify" && git remote set-url origin "file://$T/missing.git")
expect "unreachable remote reads as offline" 11 "$(run)"

expect "folder that isn't the site repo" 17 "$(bash "$SYNC" "$T/Website" origin main >"$T/log" 2>&1; echo $?)"

exit $fail
