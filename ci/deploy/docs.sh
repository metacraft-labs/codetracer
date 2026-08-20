#!/usr/bin/env bash

set -euo pipefail

# Build + publish the CodeTracer documentation to the `gh-pages` branch that
# serves docs.codetracer.com. THREE PUBLISH CHANNELS share that one branch:
#
#   /          the RELEASED book (docs/book-isonim SSG) -- built from `stable`
#   /old/      the OLD mdBook (docs/book via `mdbook build`) -- published next
#              to the released book as the approved-content archive, exactly as
#              before
#   /nightly/  the NIGHTLY book (the same SSG, built with basePath=/nightly)
#              -- built from `dev`
#   /pr/<N>/   a PREVIEW of the book as pull request <N> would leave it (the
#              same SSG, built with basePath=/pr/<N>) -- built from the pull
#              request's merge commit, and DELETED again when the PR closes
#
# The channel is decided by the event and the branch, so `/`, `/nightly` and
# each `/pr/<N>` are produced by DIFFERENT runs of this script. That is why the
# publish step can no longer force-push a freshly-built orphan tree the way it
# used to: whichever run pushed last would delete the other channels' content.
# Instead it FETCHES the current `gh-pages`, replaces ONLY the subtree this run
# owns, and commits on top of the existing tip:
#
#   * a `stable` run replaces `/` and `/old/` and leaves `/nightly/` and every
#     `/pr/<N>/` untouched;
#   * a `dev` run replaces `/nightly/` and leaves everything else untouched;
#   * a preview run replaces (or, on cleanup, removes) exactly `/pr/<N>/` and
#     leaves everything else -- including every OTHER PR's preview -- untouched.
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
# build + assembly and prints the staged tree, but pushes nothing. The three
# knobs marked LOCAL below change WHAT gets published rather than merely where,
# so they are accepted ONLY on a run that cannot reach the real site: a dry run,
# or one pointed at an explicit `DOCS_DEPLOY_REMOTE`.
# `ci/test/docs-deploy-channels-test.sh` drives all of them. Knobs:
#
#   DOCS_DEPLOY_CHANNEL=released|nightly|preview|preview-cleanup
#                                         force the channel (default: from the event
#                                         and the branch)
#   DOCS_DEPLOY_PR=<N>                    the pull-request number the preview /
#                                         preview-cleanup channels own (`/pr/<N>`);
#                                         defaults to the number in GITHUB_REF
#   DOCS_DEPLOY_BRANCH=<name>             force the branch the channel is derived from
#   DOCS_DEPLOY_REMOTE=<url>              publish to this remote instead of the deduced
#                                         one -- point it at a local bare repo to
#                                         exercise real pushes, races and rejected
#                                         pushes without touching GitHub
#   DOCS_DEPLOY_BASELINE=<dir>|none       LOCAL: seed the "current gh-pages" baseline
#                                         from a local directory (or start empty,
#                                         simulating a first deploy) instead of
#                                         fetching it
#   DOCS_DEPLOY_SKIP_BUILD=1              LOCAL: reuse the already-built
#                                         docs/book-isonim/public and docs/book/book-old
#   DOCS_DEPLOY_STAGE_DIR=<dir>           LOCAL: assemble into <dir> and keep it, so the
#                                         staged tree can be diffed against the baseline
#                                         instead of only counted

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
# nightly is the integration book (`dev`); docs.codetracer.com/pr/<N> is pull
# request <N>'s preview. Anything else is refused rather than guessed: a wrong
# guess here would overwrite one of the live channels.
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
	# The EVENT decides first: on a pull request the ref is a `refs/pull/<N>/*`
	# ref, which matches no branch name, so deriving the channel from the branch
	# would land in the `die` below. Note that `DOCS_DEPLOY_PR` alone selects
	# nothing -- otherwise a stray environment variable could silently redirect
	# a `stable` deploy into `/pr/<N>`. For a local run, ask for the channel
	# explicitly: `DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=<N>`.
	if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
		CHANNEL="preview"
	else
		case "$BRANCH" in
		stable) CHANNEL="released" ;;
		dev) CHANNEL="nightly" ;;
		*) die "branch '${BRANCH:-<unknown>}' publishes no docs channel (stable -> /, dev -> /nightly, a pull request -> /pr/<N>). Set DOCS_DEPLOY_CHANNEL=released|nightly|preview|preview-cleanup to override." ;;
		esac
	fi
fi

# `preview`/`preview-cleanup` own `/pr/<N>`, so they need the pull-request
# number before the channel table can name their subtree.
resolve_pr_number() {
	local pr="${DOCS_DEPLOY_PR:-}"
	if [ -z "$pr" ] && [ -n "${GITHUB_REF:-}" ]; then
		# `refs/pull/123/merge` (what actions/checkout builds on a
		# `pull_request` event) and `refs/pull/123/head` both carry the number.
		case "$GITHUB_REF" in
		refs/pull/*/merge | refs/pull/*/head)
			pr="${GITHUB_REF#refs/pull/}"
			pr="${pr%%/*}"
			;;
		esac
	fi
	[ -n "$pr" ] || die "channel '$CHANNEL' needs a pull-request number; set DOCS_DEPLOY_PR=<N> (GITHUB_REF='${GITHUB_REF:-<unset>}' carries none)."
	# The number becomes BOTH a path segment under the publish checkout and a
	# URL prefix baked into every page of the built book, so it is validated
	# rather than trusted: anything but a plain decimal number could escape the
	# subtree this run owns (`..`, a leading `/`) or corrupt the built links.
	# The upper bound is a sanity limit, not a protocol one.
	#
	# The digits are ENUMERATED rather than written as the ranges `[1-9]`/`[0-9]`.
	# A range in a bracket expression is resolved against the current locale's
	# collation, and under a UTF-8 locale `[0-9]` also matches non-ASCII decimal
	# digits -- `٤٢` (Arabic-Indic) passes `^[1-9][0-9]{0,8}$` on a stock runner.
	# That cannot escape the subtree, but it would name a directory and a URL
	# prefix nothing else could reproduce. An enumerated set means the same
	# thing in every locale.
	if ! [[ $pr =~ ^[123456789][0123456789]{0,8}$ ]]; then
		die "DOCS_DEPLOY_PR='$pr' is not a pull-request number (expected a positive decimal integer with no leading zero)."
	fi
	PR_NUMBER="$pr"
}

# Set by the `preview-cleanup` channel: this run publishes a REMOVAL, so it
# builds no book and copies no content -- it only deletes the subtree it owns.
REMOVE_ONLY=0
PR_NUMBER=""

case "$CHANNEL" in
released)
	SUBTREE="" # this run owns the root of the published tree
	BASE_PATH=""
	# Everything else at the root is replaced; these top-level entries belong
	# to the OTHER channels and must survive this run untouched. `pr` is the
	# whole preview namespace: one entry covers every open PR's preview, so a
	# released deploy can never garbage-collect previews by accident.
	PRESERVE=(nightly pr)
	;;
nightly)
	SUBTREE="nightly" # this run owns exactly `/nightly`
	BASE_PATH="/nightly"
	PRESERVE=()
	;;
preview)
	resolve_pr_number
	SUBTREE="pr/$PR_NUMBER" # this run owns exactly `/pr/<N>`
	BASE_PATH="/pr/$PR_NUMBER"
	PRESERVE=()
	;;
preview-cleanup)
	resolve_pr_number
	SUBTREE="pr/$PR_NUMBER"
	BASE_PATH=""
	PRESERVE=()
	REMOVE_ONLY=1
	;;
*)
	die "unknown DOCS_DEPLOY_CHANNEL='$CHANNEL' (expected 'released', 'nightly', 'preview' or 'preview-cleanup')"
	;;
esac

if [ "$REMOVE_ONLY" = "1" ]; then
	echo "docs.sh: branch='$BRANCH' -> channel='$CHANNEL' (REMOVES '/${SUBTREE}')"
else
	echo "docs.sh: branch='$BRANCH' -> channel='$CHANNEL' (publishes '/${SUBTREE}', base path '${BASE_PATH:-/}')"
fi

# --- Local-verification knobs -----------------------------------------------
# Seeding the baseline, skipping the build and keeping the staged tree are all
# ways of publishing something OTHER than a faithful build of this checkout.
# They are accepted only when the run cannot reach the real site: either it is
# a dry run, or it has been pointed at an explicit remote (a local bare repo,
# for exercising real pushes). A CI deploy sets neither, so it can never
# publish a hand-seeded or stale tree no matter what leaks into its
# environment.
#
# Checked HERE, before anything is built, so a misuse costs a second rather
# than a full book build.
LOCAL_VERIFICATION=0
if [ "$DRY_RUN" = "1" ] || [ -n "${DOCS_DEPLOY_REMOTE:-}" ]; then
	LOCAL_VERIFICATION=1
fi
if [ "$LOCAL_VERIFICATION" = "0" ]; then
	[ -z "${DOCS_DEPLOY_BASELINE:-}" ] ||
		die "DOCS_DEPLOY_BASELINE is a local-verification knob (needs --dry-run or DOCS_DEPLOY_REMOTE)"
	[ -z "${DOCS_DEPLOY_STAGE_DIR:-}" ] ||
		die "DOCS_DEPLOY_STAGE_DIR is a local-verification knob (needs --dry-run or DOCS_DEPLOY_REMOTE)"
	[ "${DOCS_DEPLOY_SKIP_BUILD:-0}" != "1" ] ||
		die "DOCS_DEPLOY_SKIP_BUILD is a local-verification knob (needs --dry-run or DOCS_DEPLOY_REMOTE)"
fi
if [ -n "${DOCS_DEPLOY_STAGE_DIR:-}" ] &&
	[ -e "$DOCS_DEPLOY_STAGE_DIR" ] &&
	[ -n "$(ls -A "$DOCS_DEPLOY_STAGE_DIR" 2>/dev/null)" ]; then
	# The staging directory is wiped on every publish attempt, so it must be one
	# this script is allowed to own. Refusing a non-empty directory keeps a typo
	# from turning the knob into `rm -rf` on somebody's work.
	die "DOCS_DEPLOY_STAGE_DIR='$DOCS_DEPLOY_STAGE_DIR' is not empty; point it at a new directory."
fi

SKIP_BUILD=0
if [ "$REMOVE_ONLY" = "1" ]; then
	# A cleanup publishes a deletion. There is nothing to render, and nothing to
	# render it FROM either: the pull request's branch may already be gone by the
	# time it closes, so a cleanup run must never depend on building its content.
	SKIP_BUILD=1
	echo "docs.sh: channel '$CHANNEL' removes content only -- no book is built."
elif [ "${DOCS_DEPLOY_SKIP_BUILD:-0}" = "1" ]; then
	SKIP_BUILD=1
	echo "docs.sh: DOCS_DEPLOY_SKIP_BUILD=1, reusing the already-built book output."
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
OLD_BOOK_DIR="$REPO_ROOT/docs/book/book-old"
if [ "$REMOVE_ONLY" = "0" ]; then
	[ -d "$BOOK_DIR" ] || die "$BOOK_DIR does not exist (the SSG build produced no output)"
	if [ "$CHANNEL" = "released" ]; then
		[ -d "$OLD_BOOK_DIR" ] || die "$OLD_BOOK_DIR does not exist (the mdBook build produced no output)"
	fi
fi

# --- Publish ----------------------------------------------------------------
# Prefer the workflow-provided DEPLOY_TOKEN (the job's GITHUB_TOKEN with
# contents:write) -- the same reliable push mechanism the isonim/isonim-docs
# docs deploys use. Fall back to the pre-configured `origin` remote otherwise.
if [ -n "${DOCS_DEPLOY_REMOTE:-}" ]; then
	# Explicit override, for exercising the publish path against a local bare
	# repo: real fetches, real fast-forward pushes, real rejections and the real
	# retry loop, with no GitHub involvement.
	REMOTE="$DOCS_DEPLOY_REMOTE"
elif [ -n "${DEPLOY_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
	REMOTE="https://x-access-token:${DEPLOY_TOKEN}@github.com/${GITHUB_REPOSITORY}"
else
	REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
	if [ -z "$REMOTE" ] && [ -z "${DOCS_DEPLOY_BASELINE:-}" ]; then
		# Only a run seeded from a local baseline can get by without a remote;
		# everything else has to read gh-pages before it can preserve the
		# channels it does not own.
		die "no publish remote: set DOCS_DEPLOY_REMOTE, or DEPLOY_TOKEN + GITHUB_REPOSITORY, or run from a checkout that has an 'origin' remote."
	fi
fi

if [ -n "${DOCS_DEPLOY_STAGE_DIR:-}" ]; then
	PUBLISH="$DOCS_DEPLOY_STAGE_DIR"
	mkdir -p "$PUBLISH"
	# Deliberately NOT removed on exit: the point of this knob is to leave the
	# assembled tree behind so it can be diffed against the baseline.
else
	PUBLISH="$(mktemp -d)"
	trap 'rm -rf "$PUBLISH"' EXIT
fi

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
		# Commit the seed as the branch tip. The fetch path below resets onto a
		# real commit, so without this the seeded repo would have no HEAD and
		# `assemble`'s "nothing changed" check would report every run as a
		# change -- the one behaviour a local baseline could not otherwise
		# reproduce.
		git -C "$PUBLISH" add -A
		git -C "$PUBLISH" commit -q --no-gpg-sign --allow-empty \
			-m "baseline seeded from $seed_dir"
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

ensure_root_robots_disallow() {
	# Keep a prefixed channel out of the search index. Crawlers only ever read
	# the ROOT robots.txt, so this is the only place a channel served under a
	# prefix can be excluded -- without it the nightly and preview pages compete
	# with the released ones for the same queries, and a preview would keep
	# competing for as long as the pull request is open.
	#
	# This is the ONE root-level file a non-root channel touches, and it only
	# ever ADDS a line that is not already there, so it can neither drop nor
	# reorder anything the released channel put in the file. The released
	# channel rewrites robots.txt wholesale from the book output and re-adds
	# both rules, so the file converges no matter which channel published last.
	local rule="Disallow: $1"
	local robots="$PUBLISH/robots.txt"
	if [ ! -f "$robots" ]; then
		# No released deploy has happened yet (or it emitted none). A robots.txt
		# with no `User-agent` line is ignored wholesale by crawlers, so the
		# group header has to be written with the rule.
		printf 'User-agent: *\n' >"$robots"
	fi
	if grep -qxF "$rule" "$robots"; then
		return 0
	fi
	# Append on a LINE of its own even if the file does not end in a newline.
	# The released channel writes robots.txt from its own build output, which
	# always ends in one -- but a preview appends to whatever is already on
	# gh-pages, which may be a consumer-supplied or hand-edited file. Without
	# this the rule would be glued onto the last line, at once destroying that
	# directive (`Sitemap: ...xmlDisallow: /pr/`) and failing to add this one.
	if [ -s "$robots" ] && [ -n "$(tail -c 1 "$robots")" ]; then
		printf '\n' >>"$robots"
	fi
	printf '%s\n' "$rule" >>"$robots"
}

swap_owned_subtree() {
	# Replace ONLY the subtree this channel owns; everything else in the
	# baseline is left exactly as fetched.
	if [ "$REMOVE_ONLY" = "1" ]; then
		# A cleanup owns a REMOVAL of `$SUBTREE` and nothing else -- not even
		# the root CNAME/.nojekyll below. Writing those here would turn a
		# cleanup that has nothing to do (the preview was never published, or
		# was already removed) into a commit, and on an empty baseline it would
		# publish a root consisting of nothing but Pages configuration.
		rm -rf "${PUBLISH:?}/$SUBTREE"
		# Cosmetic only, and only in this staging checkout: git does not track
		# directories, so an emptied `pr/` never reaches the branch anyway.
		rmdir "$PUBLISH/pr" 2>/dev/null || true
		return 0
	fi

	if [ -n "$SUBTREE" ]; then
		rm -rf "${PUBLISH:?}/$SUBTREE"
		mkdir -p "$PUBLISH/$SUBTREE"
		cp -a "$BOOK_DIR/." "$PUBLISH/$SUBTREE/"
		if [ "$CHANNEL" = "preview" ]; then
			# Previews are throwaway builds of unreviewed content; they must
			# never be indexed. One rule covers the whole `/pr/` namespace, so
			# opening a pull request never needs a robots.txt edit of its own.
			ensure_root_robots_disallow "/pr/"
		fi
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
		# This run rewrote robots.txt from the freshly built book, which knows
		# nothing about the other channels -- so both exclusions are re-applied
		# here every time.
		ensure_root_robots_disallow "/nightly/"
		ensure_root_robots_disallow "/pr/"
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
	if [ "$REMOVE_ONLY" = "1" ]; then
		echo "  owned by this run: $SUBTREE/ (REMOVED -- $(git -C "$PUBLISH" ls-files -- "$SUBTREE" | wc -l) files remain under it)"
		echo "  preserved (every other channel): $(git -C "$PUBLISH" ls-files | wc -l) files, incl. $(git -C "$PUBLISH" ls-files -- nightly | wc -l) under nightly/ and $(git -C "$PUBLISH" ls-files -- pr | wc -l) under other previews"
	elif [ -n "$SUBTREE" ]; then
		echo "  owned by this run: $SUBTREE/ ($(git -C "$PUBLISH" ls-files -- "$SUBTREE" | wc -l) files)"
		echo "  preserved (every other channel): $(git -C "$PUBLISH" ls-files | grep -cv "^$SUBTREE/") files, incl. $(git -C "$PUBLISH" ls-files -- old | wc -l) under old/"
	else
		echo "  owned by this run: / and old/ ($(git -C "$PUBLISH" ls-files -- old | wc -l) files under old/)"
		echo "  preserved (nightly channel): $(git -C "$PUBLISH" ls-files -- nightly | wc -l) files under nightly/"
		echo "  preserved (pull-request previews): $(git -C "$PUBLISH" ls-files -- pr | wc -l) files under pr/"
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
	local verb="deploy"
	[ "$REMOVE_ONLY" = "0" ] || verb="remove"
	git -C "$PUBLISH" commit -q --no-gpg-sign \
		-m "${verb} docs: ${CHANNEL} channel ('/${SUBTREE}') from ${BRANCH}"
	return 0
}

# The only expected failure of a non-force push here is another channel's run
# pushing between our fetch and our push, and the fix for that is to re-fetch
# and re-apply this run's subtree on the new tip.
#
# The attempt budget was raised from 3 to 5 when pull-request previews joined:
# `stable` and `dev` push a handful of times a day between them, but every push
# to every open pull request that touches docs now also publishes, so losing
# two races in a row stopped being far-fetched. The randomized pause is there
# for the same reason -- without it, two runs that collide tend to re-fetch and
# re-push in lockstep and collide again.
attempt=1
max_attempts=5
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
		sleep "$((RANDOM % 5 + 1))"
	else
		# Nothing to commit: the published bytes already match this build.
		stage_summary
		break
	fi
done
