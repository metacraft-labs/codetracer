#!/usr/bin/env bash

set -e

# Build the CodeTracer documentation site and publish it to the `gh-pages`
# orphan branch that serves docs.codetracer.com.
#
# The book used to be a plain mdBook (`mdbook build` -> book/). It is now an
# isonim-docs SSG consumer at docs/book-isonim/: `just build` runs
# `nim c -r src/build.nim` under the isonim dev shell and emits the static
# site (46 pages + the legacy-URL redirect stubs + _redirects + search index +
# sitemap.xml + robots.txt) into docs/book-isonim/public/.
#
# Set DOCS_DEPLOY_DRY_RUN=1 (or pass --dry-run) to build public/ and stage the
# gh-pages content WITHOUT committing or pushing. CI's build-only verification
# uses this so the real deploy is never exercised outside a `main` deploy run.

DRY_RUN=0
if [ "${DOCS_DEPLOY_DRY_RUN:-0}" = "1" ] || [ "${1:-}" = "--dry-run" ]; then
	DRY_RUN=1
fi

# --- Build the isonim-docs SSG (replaces `mdbook build`) --------------------
#
# The consumer switches `--path` to sibling checkouts (isonim, isonim-docs,
# nim-everywhere, nim-faststreams, nim-stew) laid out one level above this
# repo, and its toolchain comes from the isonim flake's dev shell -- so build
# under `nix develop <isonim flake>` rather than the global project devshell.
# From docs/book-isonim/, the sibling isonim flake is at ../../../isonim.
pushd docs/book-isonim/
nix develop ../../../isonim -c just build # build output is in ./public
popd

# --- Publish public/ to the gh-pages branch (force-push, no history kept) ---
#
# Uses a throwaway repo + force-push rather than `git worktree add --orphan`,
# which needs git 2.42+; the CI runner's git is older (a live run failed with
# "unknown option `orphan'", exit 129). Push to the token-authenticated `origin`
# the workflow already configured (git remote set-url origin
# https://x-access-token:${CODETRACER_PUSH_GITHUB_TOKEN}@github.com/...), so no
# secret needs to be threaded into this script.
ORIGIN_URL="$(git remote get-url origin)"

PUBLISH="$(mktemp -d)"
cp -a docs/book-isonim/public/. "$PUBLISH/"

# Required by github pages to keep the custom domain on the orphan branch.
echo "docs.codetracer.com" >"$PUBLISH/CNAME"
# Serve the SSG output verbatim (no Jekyll mangling of _-prefixed paths).
touch "$PUBLISH/.nojekyll"

cd "$PUBLISH"
git init -q
git config user.name "Deploy from CI"
git config user.email ""
git add -A
git commit -q -m 'deploy new book' --no-gpg-sign

if [ "$DRY_RUN" = "1" ]; then
	echo "docs.sh: DRY RUN -- skipping 'git push --force ... HEAD:gh-pages'"
	echo "docs.sh: staged $(git ls-files | wc -l) files for gh-pages (CNAME=docs.codetracer.com)"
else
	git push --force "$ORIGIN_URL" HEAD:gh-pages
fi
