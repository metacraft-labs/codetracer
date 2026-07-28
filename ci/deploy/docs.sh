#!/usr/bin/env bash

set -euo pipefail

# Build + publish the CodeTracer documentation to the `gh-pages` branch that
# serves docs.codetracer.com. RESILIENT + migration-stopgap layout:
#
#   /       the NEW isonim-docs book (docs/book-isonim SSG). If that build fails,
#           the OLD mdBook is served at root instead, so docs.codetracer.com is
#           never left broken while the new cross-repo build is stabilised.
#   /old/   the OLD mdBook (docs/book via `mdbook build`) -- ALWAYS published as
#           the approved-content fallback until the new content + style is
#           approved.
#
# The old mdBook build is reliable (mdbook is in this repo's dev shell); the new
# isonim book builds against sibling checkouts under the isonim dev shell and is
# best-effort. DOCS_DEPLOY_DRY_RUN=1 (or --dry-run): build + stage, no push.

DRY_RUN=0
if [ "${DOCS_DEPLOY_DRY_RUN:-0}" = "1" ] || [ "${1:-}" = "--dry-run" ]; then
	DRY_RUN=1
fi

REPO_ROOT="$(pwd)"

# --- OLD mdBook (reliable) -- built twice with correct site-urls ------------
# Once rooted at "/" (for the root fallback) and once at "/old/" (for the /old
# copy), so each set of pages resolves its own assets/search correctly.
echo "docs.sh: building the old mdBook (docs/book) for / and /old ..."
pushd docs/book/ >/dev/null
MDBOOK_OUTPUT__HTML__SITE_URL="/" mdbook build -d book-root
MDBOOK_OUTPUT__HTML__SITE_URL="/old/" mdbook build -d book-old
popd >/dev/null

# --- NEW isonim-docs SSG book (best-effort) --------------------------------
# Diagnostic: show whether the isonim-docs framework sibling is resolvable from
# the consumer, so any build failure here is self-explanatory in the CI log.
echo "docs.sh: sibling layout as seen from docs/book-isonim:"
(
	cd docs/book-isonim
	echo "  cwd=$(pwd)"
	echo "  isonim-docs/src/build_site.nim -> $(ls -la ../../../isonim-docs/src/build_site.nim 2>&1)"
	echo "  ../../../ contents:"
	# shellcheck disable=SC2012  # diagnostic listing of the sibling workspace dir
	ls -1 ../../../ 2>&1 | sed 's/^/    /'
)

NEW_OK=1
if (cd docs/book-isonim && nix develop ../../../isonim -c just build); then
	echo "docs.sh: new isonim book built OK."
else
	NEW_OK=0
	echo "docs.sh: WARNING -- new isonim book build FAILED; serving the old mdBook at root as a fallback (new book absent from /). See the diagnostic above."
fi

# --- Assemble the publish tree ---------------------------------------------
PUBLISH="$(mktemp -d)"
if [ "$NEW_OK" = 1 ]; then
	cp -a docs/book-isonim/public/. "$PUBLISH/" # NEW book at root
else
	cp -a docs/book/book-root/. "$PUBLISH/" # fallback: OLD mdBook at root
fi
mkdir -p "$PUBLISH/old"
cp -a docs/book/book-old/. "$PUBLISH/old/" # OLD mdBook always at /old

echo "docs.codetracer.com" >"$PUBLISH/CNAME"
touch "$PUBLISH/.nojekyll"

# --- Publish to gh-pages (throwaway repo + force-push; no git-2.42 worktree) -
cd "$PUBLISH"
git init -q
git config user.name "Deploy from CI"
git config user.email ""
git add -A
git commit -q -m 'deploy docs (new book at /, old mdBook at /old)' --no-gpg-sign

if [ "$DRY_RUN" = "1" ]; then
	echo "docs.sh: DRY RUN -- skipping push; staged $(git ls-files | wc -l) files (root=$([ "$NEW_OK" = 1 ] && echo new-isonim-book || echo old-mdbook-fallback), plus /old)"
else
	# Prefer the workflow-provided DEPLOY_TOKEN (the job's GITHUB_TOKEN with
	# contents:write) -- the same reliable push mechanism the isonim/isonim-docs
	# docs deploys use. Fall back to the pre-configured `origin` remote otherwise.
	if [ -n "${DEPLOY_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
		REMOTE="https://x-access-token:${DEPLOY_TOKEN}@github.com/${GITHUB_REPOSITORY}"
	else
		REMOTE="$(git -C "$REPO_ROOT" remote get-url origin)"
	fi
	git push --force "$REMOTE" HEAD:gh-pages
fi
