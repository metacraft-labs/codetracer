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

# --- Publish public/ to the gh-pages orphan branch (mechanics unchanged) ----

# Prune any stale worktrees that no longer exist on disk
git worktree prune

# If the worktree directory still exists, remove it.
# This handles the case where a previous run failed after creating the worktree.
if [ -d "gh-pages" ]; then
	git worktree remove --force gh-pages
fi

# If the gh-pages branch already exists, delete it first
if git show-ref --verify --quiet refs/heads/gh-pages; then
	git branch -D gh-pages
fi

# Create a new orphan branch (this will overwrite any existing remote branch)
# so that the history is not kept, which can be very expensive.
git worktree add --orphan -B gh-pages gh-pages
cp -a docs/book-isonim/public/. gh-pages

# Required by github pages to set up a custom domain
echo "docs.codetracer.com" >gh-pages/CNAME

git config user.name "Deploy from CI"
git config user.email ""
cd gh-pages
git add -A
git commit -m 'deploy new book' --no-gpg-sign

if [ "$DRY_RUN" = "1" ]; then
	echo "docs.sh: DRY RUN -- skipping 'git push origin +gh-pages'"
	echo "docs.sh: staged $(git ls-files | wc -l) files for gh-pages (CNAME=docs.codetracer.com)"
else
	git push origin +gh-pages
fi
cd ..

# Clean the environment
git worktree remove --force gh-pages
# Drop the local gh-pages branch too, so a dry run leaves no lingering ref
# that could later be pushed by accident (real runs already published it).
if git show-ref --verify --quiet refs/heads/gh-pages; then
	git branch -D gh-pages
fi
