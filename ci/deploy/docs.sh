#!/usr/bin/env bash

set -euo pipefail

# Build + publish the CodeTracer documentation to the `gh-pages` branch that
# serves docs.codetracer.com. TWO PUBLISH CHANNELS share that one branch:
#
#   /          the RELEASED book (docs/book-isonim SSG) -- built from `stable`
#   /old/      the OLD mdBook (docs/book via `mdbook build`) -- published next
#              to the released book as the approved-content archive, exactly as
#              before
#   /nightly/  the NIGHTLY book (the same SSG, built with basePath=/nightly)
#              -- built from `dev`
#
# The channel is decided by the branch, so `/` and `/nightly` are produced by
# DIFFERENT runs of this script. That is why the publish step can no longer
# force-push a freshly-built orphan tree the way it used to: whichever run
# pushed last would delete the other channel's content. Instead it FETCHES the
# current `gh-pages`, replaces ONLY the subtree this run owns, and commits on
# top of the existing tip:
#
#   * a `stable` run replaces `/` and `/old/` and leaves `/nightly/` untouched;
#   * a `dev` run replaces `/nightly/` and leaves everything else untouched.
#
# The push is a plain fast-forward push (never `--force`), so if the two
# channels ever race, the loser is rejected rather than silently clobbering the
# winner -- and this script then re-fetches and re-applies its subtree. It is
# also the safety net for a first deploy / recovery: an empty baseline can only
# be published when `gh-pages` genuinely does not exist yet, because otherwise
# the non-fast-forward push fails.
#
# NO SILENT FALLBACK. This script used to build the old mdBook a second time
# (rooted at `/`) and serve it at the root whenever the new SSG build failed,
# which produced a GREEN run publishing a site missing the new content. It now
# fails the job instead; see the `die` at the SSG build below for why that is
# now the SAFER behaviour rather than the riskier one.
#
# Local verification: `DOCS_DEPLOY_DRY_RUN=1` (or `--dry-run`) runs the whole
# build + assembly and prints the staged tree, but pushes nothing. Knobs:
#
#   DOCS_DEPLOY_CHANNEL=released|nightly  force the channel (default: from the branch)
#   DOCS_DEPLOY_BRANCH=<name>             force the branch the channel is derived from
#   DOCS_DEPLOY_BASELINE=<dir>|none       dry-run only: seed the "current gh-pages"
#                                         baseline from a local directory (or start
#                                         empty, simulating a first deploy) instead
#                                         of fetching it
#   DOCS_DEPLOY_SKIP_BUILD=1              dry-run only: reuse the already-built
#                                         docs/book-isonim/public and docs/book/book-old

DRY_RUN=0
if [ "${DOCS_DEPLOY_DRY_RUN:-0}" = "1" ] || [ "${1:-}" = "--dry-run" ]; then
	DRY_RUN=1
fi

REPO_ROOT="$(pwd)"

die() {
	echo "docs.sh: ERROR -- $*" >&2
	exit 1
}

# --- Which channel does this run publish? -----------------------------------
# docs.codetracer.com/ is the RELEASED book (`stable`); docs.codetracer.com/
# nightly is the integration book (`dev`). Anything else is refused rather than
# guessed: a wrong guess here would overwrite one of the two live channels.
BRANCH="${DOCS_DEPLOY_BRANCH:-}"
if [ -z "$BRANCH" ]; then
	if [ -n "${GITHUB_REF_NAME:-}" ]; then
		BRANCH="$GITHUB_REF_NAME"
	elif [ -n "${GITHUB_REF:-}" ]; then
		BRANCH="${GITHUB_REF#refs/heads/}"
	elif [ -n "${CI_COMMIT_REF_NAME:-}" ]; then # GitLab CI
		BRANCH="$CI_COMMIT_REF_NAME"
	else
		BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
	fi
fi

CHANNEL="${DOCS_DEPLOY_CHANNEL:-}"
if [ -z "$CHANNEL" ]; then
	case "$BRANCH" in
	stable) CHANNEL="released" ;;
	dev) CHANNEL="nightly" ;;
	*) die "branch '${BRANCH:-<unknown>}' publishes no docs channel (stable -> /, dev -> /nightly). Set DOCS_DEPLOY_CHANNEL=released|nightly to override." ;;
	esac
fi

case "$CHANNEL" in
released)
	SUBTREE="" # this run owns the root of the published tree
	BASE_PATH=""
	# Everything else at the root is replaced; these top-level entries belong
	# to the OTHER channel and must survive this run untouched.
	PRESERVE=(nightly)
	;;
nightly)
	SUBTREE="nightly" # this run owns exactly `/nightly`
	BASE_PATH="/nightly"
	PRESERVE=()
	;;
*)
	die "unknown DOCS_DEPLOY_CHANNEL='$CHANNEL' (expected 'released' or 'nightly')"
	;;
esac

echo "docs.sh: branch='$BRANCH' -> channel='$CHANNEL' (publishes '/${SUBTREE}', base path '${BASE_PATH:-/}')"

SKIP_BUILD=0
if [ "$DRY_RUN" = "1" ] && [ "${DOCS_DEPLOY_SKIP_BUILD:-0}" = "1" ]; then
	SKIP_BUILD=1
	echo "docs.sh: DRY RUN -- DOCS_DEPLOY_SKIP_BUILD=1, reusing the already-built book output."
fi

# --- OLD mdBook (released channel only) -------------------------------------
# `/old` lives under the root, so it is rebuilt and republished by the released
# channel only; a nightly run must not touch it (and the preserve-the-rest
# publish below is what keeps it in place).
#
# It is built ONCE now, with MDBOOK_OUTPUT__HTML__SITE_URL="/old/" so its pages
# resolve their own assets/search under that prefix. The second build (rooted at
# "/") that used to feed the root fallback is gone with the fallback itself.
if [ "$CHANNEL" = "released" ] && [ "$SKIP_BUILD" = "0" ]; then
	echo "docs.sh: building the old mdBook (docs/book) for /old ..."
	pushd docs/book/ >/dev/null
	MDBOOK_OUTPUT__HTML__SITE_URL="/old/" mdbook build -d book-old
	popd >/dev/null
fi

# --- NEW isonim-docs SSG book ----------------------------------------------
if [ "$SKIP_BUILD" = "0" ]; then
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

	# book-isonim/config.nims resolves its sibling `--path`s via
	# `currentSourcePath()/../../..`, which is correct locally but fails in CI with
	# "cannot open file: build_site" even though the file is present (the checkout's
	# parent dir resolves differently under nix/symlinks). Pin the sibling search
	# paths ABSOLUTELY via a generated nim.cfg (nim reads it alongside config.nims;
	# extra --paths are harmless), computed from the known clone location
	# (${REPO_ROOT}/../<repo>). Removed after the build so the tree stays clean.
	# Still required: `config.nims` is matched by the repo-wide `*.nims` line in
	# .gitignore and is therefore absent from every checkout, CI's included.
	SIBLINGS_ABS="$(cd "$REPO_ROOT/.." && pwd)"
	cat >docs/book-isonim/nim.cfg <<NIMCFG
--path:"$SIBLINGS_ABS/isonim-docs/src"
--path:"$SIBLINGS_ABS/codetracer-design-system/nim"
--path:"$SIBLINGS_ABS/isonim/src"
--path:"$SIBLINGS_ABS/nim-everywhere/src"
--path:"$SIBLINGS_ABS/nim-faststreams"
--path:"$SIBLINGS_ABS/nim-stew"
--path:"$SIBLINGS_ABS/isonim/vendor/chronicles"
--path:"$SIBLINGS_ABS/isonim/vendor/serialization"
--path:"$SIBLINGS_ABS/isonim/vendor/json_serialization"
NIMCFG

	# CT_DOCS_BASE_PATH is read by docs/book-isonim/src/build.nim: it is the URL
	# prefix the channel is served under, and the SSG rewrites every root-relative
	# link, asset, stylesheet `url(...)`, search-index route and redirect stub with
	# it. Without it a /nightly build would ask the browser for /assets/... and
	# every asset would 404.
	NEW_OK=1
	(cd docs/book-isonim && CT_DOCS_BASE_PATH="$BASE_PATH" nix develop ../../../isonim -c just build) || NEW_OK=0
	rm -f docs/book-isonim/nim.cfg

	if [ "$NEW_OK" != "1" ]; then
		# HARD FAILURE, deliberately. The previous behaviour -- publish the old
		# mdBook at the root and exit 0 -- meant a broken docs build looked green
		# while docs.codetracer.com silently lost every page the old book does not
		# have (the DeepReview guide, for one), with nothing announcing the
		# substitution.
		#
		# What replaces the fallback's protective intent ("never leave
		# docs.codetracer.com broken"): this script no longer replaces the whole
		# published branch, so aborting BEFORE the publish step leaves the last
		# successfully published site exactly where it is. Serving stale-but-good
		# content is now the default consequence of a failed build; it no longer
		# has to be manufactured by substituting different content under the same
		# URLs. The approved-content archive is still published at /old by every
		# successful released-channel run.
		die "the isonim-docs book build FAILED -- see the build log and the sibling diagnostic above. NOTHING was published; docs.codetracer.com keeps serving the last successful build."
	fi
	echo "docs.sh: new isonim book built OK."
fi

BOOK_DIR="$REPO_ROOT/docs/book-isonim/public"
[ -d "$BOOK_DIR" ] || die "$BOOK_DIR does not exist (the SSG build produced no output)"
OLD_BOOK_DIR="$REPO_ROOT/docs/book/book-old"
if [ "$CHANNEL" = "released" ]; then
	[ -d "$OLD_BOOK_DIR" ] || die "$OLD_BOOK_DIR does not exist (the mdBook build produced no output)"
fi

# --- Publish ----------------------------------------------------------------
# Prefer the workflow-provided DEPLOY_TOKEN (the job's GITHUB_TOKEN with
# contents:write) -- the same reliable push mechanism the isonim/isonim-docs
# docs deploys use. Fall back to the pre-configured `origin` remote otherwise.
if [ -n "${DEPLOY_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
	REMOTE="https://x-access-token:${DEPLOY_TOKEN}@github.com/${GITHUB_REPOSITORY}"
else
	REMOTE="$(git -C "$REPO_ROOT" remote get-url origin)"
fi

PUBLISH="$(mktemp -d)"
trap 'rm -rf "$PUBLISH"' EXIT

init_publish_repo() {
	# $PUBLISH becomes a git repo on `gh-pages`; the fetch path then resets it
	# onto the real branch tip so our commit is a fast-forward.
	git init -q -b gh-pages "$PUBLISH"
	git -C "$PUBLISH" config user.name "Deploy from CI"
	git -C "$PUBLISH" config user.email ""
}

seed_baseline() {
	# Reproduce the CURRENT state of gh-pages in $PUBLISH, as a git repo whose
	# HEAD is the branch tip. Sets BASELINE to a human description of where the
	# baseline came from.
	local seed_dir="${DOCS_DEPLOY_BASELINE:-}"
	if [ -n "$seed_dir" ]; then
		[ "$DRY_RUN" = "1" ] || die "DOCS_DEPLOY_BASELINE is a dry-run-only knob"
		if [ "$seed_dir" = "none" ]; then
			init_publish_repo
			BASELINE="empty (DOCS_DEPLOY_BASELINE=none -- simulating a first deploy)"
			return 0
		fi
		[ -d "$seed_dir" ] || die "DOCS_DEPLOY_BASELINE='$seed_dir' is not a directory"
		# Content first, then `git init` -- the seed dir may itself be a checkout,
		# and copying its `.git` over ours would make the staging repo lie.
		cp -a "$seed_dir/." "$PUBLISH/"
		rm -rf "${PUBLISH:?}/.git"
		init_publish_repo
		BASELINE="local directory $seed_dir"
		return 0
	fi

	init_publish_repo
	# Does the branch exist at all? `ls-remote --exit-code` distinguishes "no
	# such ref" (2) from a real transport/auth failure (anything else), so a
	# first deploy is handled without letting a broken fetch masquerade as one.
	local rc=0
	git ls-remote --exit-code "$REMOTE" refs/heads/gh-pages >/dev/null 2>&1 || rc=$?
	if [ "$rc" = "0" ]; then
		git -C "$PUBLISH" fetch -q --depth=1 "$REMOTE" refs/heads/gh-pages ||
			die "could not fetch the current gh-pages; refusing to publish (a run that cannot read the branch cannot preserve the channel it does not own)."
		git -C "$PUBLISH" reset -q --hard FETCH_HEAD
		BASELINE="fetched gh-pages ($(git -C "$PUBLISH" rev-parse --short HEAD))"
	elif [ "$rc" = "2" ]; then
		BASELINE="empty (gh-pages does not exist yet -- first deploy)"
	elif [ "$DRY_RUN" = "1" ]; then
		BASELINE="empty (could not reach the remote; dry run continues offline)"
		echo "docs.sh: DRY RUN -- could not list the remote; continuing with an empty baseline."
	else
		die "could not reach '$REMOTE' to read gh-pages (git ls-remote exit $rc)."
	fi
}

swap_owned_subtree() {
	# Replace ONLY the subtree this channel owns; everything else in the
	# baseline is left exactly as fetched.
	if [ -n "$SUBTREE" ]; then
		rm -rf "${PUBLISH:?}/$SUBTREE"
		mkdir -p "$PUBLISH/$SUBTREE"
		cp -a "$BOOK_DIR/." "$PUBLISH/$SUBTREE/"
	else
		# The released channel owns the whole root except the other channel's
		# subtrees (and .git). Build the `find` exclusion from $PRESERVE so the
		# list stays a single source of truth.
		local -a prune=(-name .git)
		local name
		for name in "${PRESERVE[@]}"; do
			prune+=(-o -name "$name")
		done
		find "$PUBLISH" -mindepth 1 -maxdepth 1 \( "${prune[@]}" \) -prune -o -exec rm -rf {} +
		cp -a "$BOOK_DIR/." "$PUBLISH/"
		mkdir -p "$PUBLISH/old"
		cp -a "$OLD_BOOK_DIR/." "$PUBLISH/old/"
		# Crawlers only ever read the ROOT robots.txt, so this is the only place
		# the nightly channel can be kept out of the index -- without it the
		# nightly pages compete with the released ones for the same queries.
		if [ -f "$PUBLISH/robots.txt" ] && ! grep -q '^Disallow: /nightly/' "$PUBLISH/robots.txt"; then
			printf 'Disallow: /nightly/\n' >>"$PUBLISH/robots.txt"
		fi
	fi

	# Root-level Pages configuration, correct in every case -- including a
	# nightly-first-deploy where the root is otherwise still empty.
	echo "docs.codetracer.com" >"$PUBLISH/CNAME"
	touch "$PUBLISH/.nojekyll"
}

stage_summary() {
	local staged
	staged="$(git -C "$PUBLISH" ls-files | wc -l)"
	echo "docs.sh: staged $staged files for channel '$CHANNEL' (baseline: $BASELINE)"
	echo "  top level:"
	git -C "$PUBLISH" ls-files | awk -F/ '{ print (NF > 1 ? $1 "/" : $1) }' |
		sort | uniq -c | sort -rn | sed 's/^/    /'
	if [ -n "$SUBTREE" ]; then
		echo "  owned by this run: $SUBTREE/ ($(git -C "$PUBLISH" ls-files -- "$SUBTREE" | wc -l) files)"
		echo "  preserved (root channel): $(git -C "$PUBLISH" ls-files | grep -cv "^$SUBTREE/") files, incl. $(git -C "$PUBLISH" ls-files -- old | wc -l) under old/"
	else
		echo "  owned by this run: / and old/ ($(git -C "$PUBLISH" ls-files -- old | wc -l) files under old/)"
		echo "  preserved (nightly channel): $(git -C "$PUBLISH" ls-files -- nightly | wc -l) files under nightly/"
	fi
}

assemble() {
	rm -rf "$PUBLISH"
	mkdir -p "$PUBLISH"
	seed_baseline
	swap_owned_subtree
	git -C "$PUBLISH" add -A
	if git -C "$PUBLISH" diff --cached --quiet; then
		echo "docs.sh: no content change for channel '$CHANNEL' -- nothing to commit."
		return 1
	fi
	git -C "$PUBLISH" commit -q --no-gpg-sign \
		-m "deploy docs: ${CHANNEL} channel ('/${SUBTREE}') from ${BRANCH}"
	return 0
}

# Up to three attempts: the only expected failure of a non-force push here is
# the other channel's run pushing between our fetch and our push, and the fix
# for that is to re-fetch and re-apply this run's subtree on the new tip.
attempt=1
max_attempts=3
while :; do
	if assemble; then
		if [ "$DRY_RUN" = "1" ]; then
			stage_summary
			echo "docs.sh: DRY RUN -- nothing pushed."
			break
		fi
		if git -C "$PUBLISH" push "$REMOTE" HEAD:refs/heads/gh-pages; then
			stage_summary
			echo "docs.sh: published channel '$CHANNEL' to gh-pages."
			break
		fi
		[ "$attempt" -lt "$max_attempts" ] ||
			die "could not push gh-pages after $max_attempts attempts."
		echo "docs.sh: push rejected (attempt $attempt/$max_attempts) -- re-fetching gh-pages and re-applying '/${SUBTREE}'."
		attempt=$((attempt + 1))
	else
		# Nothing to commit: the published bytes already match this build.
		stage_summary
		break
	fi
done
