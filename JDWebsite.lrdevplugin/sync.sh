#!/bin/bash
# Sync step for the JD Photographer Website Lightroom plugin (run by Sync.lua):
# pull, node build-journal.js, then commit and push the site repo
# (deploy-netlify/, the source of truth).
#
#   sync.sh <repo-dir> <remote> <branch>
#
# Each kind of failure exits with its own code; Sync.lua turns them into
# readable messages, so keep the two in step.
#   0 pushed            3 nothing to push     10 git busy (index.lock)
#  11 offline           12 auth failed        13 pull conflict
#  14 build failed      15 commit failed      16 push rejected
#  17 not the site repo                       18 wrong branch checked out
set -u
GIT_WORK=$1 REMOTE=$2 BRANCH=$3

# Lightroom runs this with launchd's minimal PATH; add the usual homes of
# node/npm (Homebrew, nvm).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; fi
# Never wait for a password prompt or an editor nobody can see.
export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true GIT_PAGER=cat
export GIT_SSH_COMMAND="ssh -o BatchMode=yes"

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

step() { echo; echo "== $*"; }

# Why a fetch/push failed, from git's own output.
network_failure() {
  cat "$OUT"
  if grep -qiE 'authentication failed|permission denied|terminal prompts disabled|could not read (username|password)|invalid username or password|returned error: 403' "$OUT"; then
    exit 12
  fi
  if grep -qiE 'could not resolve host|unable to access|network is unreachable|timed out|connection refused|could not read from remote' "$OUT"; then
    exit 11
  fi
  exit "$1"
}

echo "sync started $(date '+%Y-%m-%d %H:%M:%S')"
[ -d "$GIT_WORK/.git" ] || { echo "not a git repo: $GIT_WORK"; exit 17; }
[ -f "$GIT_WORK/build-journal.js" ] || { echo "no build-journal.js in $GIT_WORK"; exit 17; }
[ -e "$GIT_WORK/.git/index.lock" ] && { echo "$GIT_WORK/.git/index.lock exists"; exit 10; }

cd "$GIT_WORK" || exit 17
CURRENT=$(git symbolic-ref --short HEAD 2>/dev/null)
[ "$CURRENT" = "$BRANCH" ] || { echo "on branch '$CURRENT', expected '$BRANCH'"; exit 18; }

# Bring in anything committed elsewhere first (Sveltia CMS journal posts),
# so the build uses the latest content and the push isn't rejected.
step "git pull --rebase $REMOTE $BRANCH"
if ! git pull --rebase --autostash "$REMOTE" "$BRANCH" >"$OUT" 2>&1; then
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    cat "$OUT"; git rebase --abort >/dev/null 2>&1; exit 13
  fi
  network_failure 13
fi
cat "$OUT"
if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
  echo "local changes conflict with the pulled commits:"; git diff --name-only --diff-filter=U; exit 13
fi

# Generated pages are committed alongside their sources (see CLAUDE.md).
step "node build-journal.js"
command -v node >/dev/null || { echo "node not found on PATH ($PATH)"; exit 14; }
if [ ! -d node_modules ]; then npm install --no-fund --no-audit || exit 14; fi
node build-journal.js || exit 14

step "git commit"
git add -A || exit 15
if git diff --cached --quiet; then
  # Nothing new, but an earlier push may have failed after its commit.
  AHEAD=$(git rev-list --count "$REMOTE/$BRANCH..HEAD" 2>/dev/null || echo 0)
  if [ "$AHEAD" = "0" ]; then echo "nothing to commit"; exit 3; fi
  echo "no new changes; pushing $AHEAD earlier commit(s)"
else
  git commit -q -m "Portfolio update (Lightroom publish)" || exit 15
  git log --oneline -1
fi

step "git push $REMOTE $BRANCH"
git push "$REMOTE" "$BRANCH" >"$OUT" 2>&1 || network_failure 16
cat "$OUT"
echo "pushed $(date '+%Y-%m-%d %H:%M:%S')"
exit 0
