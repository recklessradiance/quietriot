#!/bin/bash
# Publishes the Cydia repo (cydia-repo/) to the gh-pages branch of the
# GitHub remote, so the deb is installable straight from Cydia.
#
# usage: tool/publish-repo.sh [repo-url]
#   repo-url defaults to `git remote get-url origin` of the main repo.
#
# After the first push, enable Pages on the repo (script prints the gh
# command if needed) and add the Pages URL as a Cydia source:
#   https://<owner>.github.io/<repo>/
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$ROOT/cydia-repo"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

URL="${1:-$(git -C "$ROOT" remote get-url origin)}"
say "publishing to gh-pages of $URL"

# rebuild repo contents from dist/*.deb
"$ROOT/tool/build-repo.sh" >/dev/null

cd "$REPO"
if [ ! -d .git ]; then
  git init -q
  git checkout -q -b gh-pages
  git remote add origin "$URL"
fi

git add -A
git commit -qm "Publish Cydia repo $(date -u +%Y-%m-%d)" 2>/dev/null || true
git push -q origin gh-pages --force

# enable GitHub Pages on first publish
if command -v gh >/dev/null 2>&1; then
  gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pages" \
    -X POST -f source[branch]=gh-pages -f source[path]=/ 2>/dev/null || true
fi

OWNER_HOST=$(echo "$URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
say "done - Cydia source URL (once Pages is live):"
echo "  https://${OWNER_HOST%%/*}.github.io/${OWNER_HOST##*/}/"
echo "Cydia -> Sources -> Add -> that URL -> install quietriot."
