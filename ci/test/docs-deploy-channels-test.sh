#!/usr/bin/env bash
#
# Verification for `ci/deploy/docs.sh`'s channel model.
#
# The docs site is one `gh-pages` branch shared by several channels that are
# published by DIFFERENT runs: `/` + `/old` (from `stable`), `/nightly` (from
# `dev`) and `/pr/<N>` (one per open pull request). The whole design rests on
# one property -- a run replaces ONLY the subtree it owns and leaves every
# other channel's bytes exactly as it fetched them -- and on that property
# holding in every direction, not just the one that was interesting when the
# last channel was added.
#
# So this asserts preservation with `diff -rq` on real directory trees rather
# than by counting files: a run that dropped one page and added another would
# pass a count check.
#
# Two layers:
#
#   1. DRY-RUN layer -- `DOCS_DEPLOY_DRY_RUN=1` with `DOCS_DEPLOY_BASELINE`
#      (a fixture standing in for the current gh-pages) and
#      `DOCS_DEPLOY_STAGE_DIR` (keeps the assembled tree for diffing). Covers
#      every channel, both preservation directions, robots.txt, and every
#      input the script is supposed to refuse.
#   2. REAL-PUSH layer -- a local bare repo as the remote via
#      `DOCS_DEPLOY_REMOTE`. Covers what a dry run cannot: that the commit
#      actually fast-forwards, that a lost race is retried onto the winner's
#      tip WITHOUT dropping either side's content, and that a push that can
#      never succeed fails the script instead of looping forever.
#
# The book build itself is stubbed (`DOCS_DEPLOY_SKIP_BUILD=1` over fixture
# output directories) -- what the SSG does with a base path is pinned by
# `docs/book-isonim/tests/test_preview_channel.nim`, and re-running it here
# would make this suite a ten-minute job that tests someone else's code.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS_SH="$REPO_ROOT/ci/deploy/docs.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
CASE=""

begin() {
	CASE="$1"
	echo
	echo "== $CASE"
}

pass() { echo "   ok -- $*"; }

fail() {
	echo "   FAIL [$CASE] -- $*" >&2
	FAILURES=$((FAILURES + 1))
}

# --- fixtures ---------------------------------------------------------------

# docs.sh reads exactly two build outputs from its repo root, so a stand-in
# root with those two directories is enough to drive every publish path.
make_fake_repo() {
	local root="$1"
	rm -rf "$root"
	mkdir -p "$root/docs/book-isonim/public/assets" \
		"$root/docs/book-isonim/public/getting_started" \
		"$root/docs/book/book-old"
	echo "<html>new book home</html>" >"$root/docs/book-isonim/public/index.html"
	echo "body { color: red }" >"$root/docs/book-isonim/public/assets/style.css"
	echo "<html>python page</html>" >"$root/docs/book-isonim/public/getting_started/index.html"
	printf 'User-agent: *\nAllow: /\nSitemap: https://docs.codetracer.com/sitemap.xml\n' \
		>"$root/docs/book-isonim/public/robots.txt"
	echo "<html>old mdbook</html>" >"$root/docs/book/book-old/index.html"
}

# A stand-in for the CURRENT gh-pages: all channels populated, so every run
# has something of somebody else's to preserve. `$1` is the directory; `$2`
# selects whether the root robots.txt already carries the preview exclusion
# ("modern") or predates it ("legacy").
make_baseline() {
	local dir="$1" robots_state="${2:-modern}"
	rm -rf "$dir"
	mkdir -p "$dir/assets" "$dir/old" "$dir/nightly/assets" \
		"$dir/pr/41" "$dir/pr/99" "$dir/pr/7/deep/nested"
	echo "<html>released home</html>" >"$dir/index.html"
	echo "body { color: green }" >"$dir/assets/style.css"
	echo "docs.codetracer.com" >"$dir/CNAME"
	: >"$dir/.nojekyll"
	echo "<html>archived mdbook</html>" >"$dir/old/index.html"
	echo "<html>nightly home</html>" >"$dir/nightly/index.html"
	echo "console.log(1)" >"$dir/nightly/assets/app.js"
	echo "<html>preview 41</html>" >"$dir/pr/41/index.html"
	echo "<html>preview 99</html>" >"$dir/pr/99/index.html"
	# A deep path, so preservation is checked below the first level too.
	echo "<html>preview 7 deep</html>" >"$dir/pr/7/deep/nested/page.html"

	{
		printf 'User-agent: *\nAllow: /\nSitemap: https://docs.codetracer.com/sitemap.xml\n'
		printf 'Disallow: /nightly/\n'
		if [ "$robots_state" = "modern" ]; then printf 'Disallow: /pr/\n'; fi
	} >"$dir/robots.txt"
}

# --- assertions -------------------------------------------------------------

assert_identical() {
	# $1 expected tree, $2 actual tree, $3 label
	local out
	if out="$(diff -rq --exclude=.git "$1" "$2" 2>&1)"; then
		pass "$3: byte-identical (diff -rq clean)"
	else
		fail "$3: NOT preserved"
		printf '%s\n' "$out" | sed 's/^/        /' >&2
	fi
}

assert_missing() {
	if [ -e "$1" ]; then fail "$2: still present at $1"; else pass "$2"; fi
}

assert_grep() {
	# $1 file, $2 fixed string, $3 label
	if grep -qxF "$2" "$1"; then pass "$3"; else fail "$3 (no line '$2' in $1)"; fi
}

# Compare the ROOT of two trees while ignoring the channel subtrees that are
# published separately -- what "the released channel's bytes were preserved"
# means from a nightly or preview run's point of view.
assert_root_identical() {
	# $1 expected, $2 actual, $3 label
	local e="$TEST_ROOT/cmp-expected" a="$TEST_ROOT/cmp-actual"
	rm -rf "$e" "$a"
	cp -a "$1" "$e"
	cp -a "$2" "$a"
	rm -rf "$e/nightly" "$e/pr" "$e/.git" "$a/nightly" "$a/pr" "$a/.git"
	assert_identical "$e" "$a" "$3"
}

# Run docs.sh as a dry run against a baseline, leaving the staged tree behind.
# Echoes nothing on success; the caller inspects $STAGE.
STAGE=""
run_dry() {
	# $1 stage-dir name, then env assignments as `KEY=VALUE` arguments
	local stage_name="$1"
	shift
	STAGE="$TEST_ROOT/stage-$stage_name"
	rm -rf "$STAGE"
	local rc=0
	(
		cd "$TEST_ROOT/repo"
		env DOCS_DEPLOY_DRY_RUN=1 DOCS_DEPLOY_SKIP_BUILD=1 \
			DOCS_DEPLOY_STAGE_DIR="$STAGE" "$@" \
			bash "$DOCS_SH"
	) >"$TEST_ROOT/run.log" 2>&1 || rc=$?
	if [ "$rc" != "0" ]; then
		# Every assertion below a broken run would be about a tree that was
		# never assembled, so this is a hard stop rather than one more failure
		# in the tally.
		fail "the dry run itself failed (exit $rc)"
		sed 's/^/        /' "$TEST_ROOT/run.log" >&2
		exit 1
	fi
}

# Expect docs.sh to REFUSE: non-zero exit, and the message must name the reason.
assert_refused() {
	# $1 label, $2 expected message fragment, then env assignments
	local label="$1" expect="$2"
	shift 2
	local rc=0
	(
		cd "$TEST_ROOT/repo"
		env DOCS_DEPLOY_DRY_RUN=1 DOCS_DEPLOY_SKIP_BUILD=1 "$@" bash "$DOCS_SH"
	) >"$TEST_ROOT/refuse.log" 2>&1 || rc=$?
	if [ "$rc" = "0" ]; then
		fail "$label: docs.sh accepted it (exit 0)"
	elif ! grep -qF "$expect" "$TEST_ROOT/refuse.log"; then
		fail "$label: refused, but not for the stated reason (wanted '$expect')"
		sed 's/^/        /' "$TEST_ROOT/refuse.log" >&2
	else
		pass "$label: refused -- $(grep -oF "$expect" "$TEST_ROOT/refuse.log" | head -1)"
	fi
}

make_fake_repo "$TEST_ROOT/repo"
BOOK="$TEST_ROOT/repo/docs/book-isonim/public"
OLD_BOOK="$TEST_ROOT/repo/docs/book/book-old"

# --- 1. a preview publishes /pr/<N> and preserves everything else -----------

begin "a preview run owns /pr/42 and preserves every other channel"
make_baseline "$TEST_ROOT/base-modern" modern
run_dry preview DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_identical "$BOOK" "$STAGE/pr/42" "the preview subtree is this run's book output"
assert_identical "$TEST_ROOT/base-modern/nightly" "$STAGE/nightly" "/nightly"
assert_identical "$TEST_ROOT/base-modern/old" "$STAGE/old" "/old"
assert_identical "$TEST_ROOT/base-modern/pr/41" "$STAGE/pr/41" "another PR's preview /pr/41"
assert_identical "$TEST_ROOT/base-modern/pr/99" "$STAGE/pr/99" "another PR's preview /pr/99"
assert_identical "$TEST_ROOT/base-modern/pr/7" "$STAGE/pr/7" "another PR's preview /pr/7 (deep tree)"
assert_root_identical "$TEST_ROOT/base-modern" "$STAGE" "the released root"

# --- 2. robots.txt: the preview is excluded, additively and idempotently ----

begin "a preview adds the /pr/ exclusion to a robots.txt that predates it"
make_baseline "$TEST_ROOT/base-legacy" legacy
run_dry preview-legacy DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-legacy"
assert_grep "$STAGE/robots.txt" "Disallow: /pr/" "the preview exclusion is present"
assert_grep "$STAGE/robots.txt" "Disallow: /nightly/" "the nightly exclusion is untouched"
# The exclusion is the ONLY root-level write a preview makes, and it only adds.
added="$(diff "$TEST_ROOT/base-legacy/robots.txt" "$STAGE/robots.txt" | grep -c '^>' || true)"
removed="$(diff "$TEST_ROOT/base-legacy/robots.txt" "$STAGE/robots.txt" | grep -c '^<' || true)"
if [ "$added" = "1" ] && [ "$removed" = "0" ]; then
	pass "robots.txt gained exactly one line and lost none"
else
	fail "robots.txt changed by +$added/-$removed lines (want +1/-0)"
fi
rm -rf "$TEST_ROOT/root-legacy-expected"
cp -a "$TEST_ROOT/base-legacy" "$TEST_ROOT/root-legacy-expected"
cp "$STAGE/robots.txt" "$TEST_ROOT/root-legacy-expected/robots.txt"
assert_root_identical "$TEST_ROOT/root-legacy-expected" "$STAGE" \
	"the released root apart from that one robots.txt line"

begin "a robots.txt with no trailing newline is appended to, not corrupted"
# The released channel writes robots.txt from its own build output, which always
# ends in a newline. A PREVIEW appends to whatever is already on gh-pages --
# possibly a consumer-supplied `static/robots.txt` copied verbatim by the SSG,
# or a hand-edited one. Appending blindly would glue the rule onto the last
# line, destroying that directive AND failing to add this one:
#     Sitemap: https://docs.codetracer.com/sitemap.xmlDisallow: /pr/
make_baseline "$TEST_ROOT/base-nonewline" legacy
printf 'User-agent: *\nSitemap: https://docs.codetracer.com/sitemap.xml' \
	>"$TEST_ROOT/base-nonewline/robots.txt"
run_dry preview-nonewline DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-nonewline"
assert_grep "$STAGE/robots.txt" "Disallow: /pr/" "the exclusion is a line of its own"
assert_grep "$STAGE/robots.txt" "Sitemap: https://docs.codetracer.com/sitemap.xml" \
	"the unterminated last line survived intact"
# ... and a second pass over the repaired file must still be a no-op.
rm -rf "$TEST_ROOT/base-nonewline2"
cp -a "$TEST_ROOT/base-nonewline" "$TEST_ROOT/base-nonewline2"
cp "$STAGE/robots.txt" "$TEST_ROOT/base-nonewline2/robots.txt"
run_dry preview-nonewline2 DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-nonewline2"
if cmp -s "$TEST_ROOT/base-nonewline2/robots.txt" "$STAGE/robots.txt"; then
	pass "the repaired robots.txt is left byte-identical on the next run"
else
	fail "the repaired robots.txt was rewritten again"
	diff "$TEST_ROOT/base-nonewline2/robots.txt" "$STAGE/robots.txt" | sed 's/^/        /' >&2
fi

begin "re-running the preview against an already-excluded root changes nothing"
# Case 1 ran against a modern baseline; its staged robots.txt must equal the
# baseline's, i.e. the exclusion is idempotent rather than appended per run.
run_dry preview-idem DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
if cmp -s "$TEST_ROOT/base-modern/robots.txt" "$STAGE/robots.txt"; then
	pass "robots.txt is byte-identical to the baseline"
else
	fail "robots.txt was rewritten when it already carried the exclusion"
	diff "$TEST_ROOT/base-modern/robots.txt" "$STAGE/robots.txt" | sed 's/^/        /' >&2
fi

# --- 3. the other direction: released and nightly must preserve previews ----

begin "a released run replaces / and /old and preserves every preview"
run_dry released DOCS_DEPLOY_CHANNEL=released DOCS_DEPLOY_BRANCH=stable \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_identical "$TEST_ROOT/base-modern/pr/41" "$STAGE/pr/41" "/pr/41"
assert_identical "$TEST_ROOT/base-modern/pr/99" "$STAGE/pr/99" "/pr/99"
assert_identical "$TEST_ROOT/base-modern/pr/7" "$STAGE/pr/7" "/pr/7 (deep tree)"
assert_identical "$TEST_ROOT/base-modern/nightly" "$STAGE/nightly" "/nightly"
assert_identical "$OLD_BOOK" "$STAGE/old" "/old is this run's mdBook output"
assert_grep "$STAGE/robots.txt" "Disallow: /pr/" "the released run re-adds the preview exclusion"
assert_grep "$STAGE/robots.txt" "Disallow: /nightly/" "the released run re-adds the nightly exclusion"
# The root itself really was replaced by this run's build, not merely left.
if cmp -s "$BOOK/index.html" "$STAGE/index.html"; then
	pass "the root was replaced by this run's book output"
else
	fail "the root still carries the baseline's home page"
fi

begin "a nightly run replaces /nightly and preserves every preview"
run_dry nightly DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_identical "$BOOK" "$STAGE/nightly" "/nightly is this run's book output"
assert_identical "$TEST_ROOT/base-modern/pr/41" "$STAGE/pr/41" "/pr/41"
assert_identical "$TEST_ROOT/base-modern/pr/99" "$STAGE/pr/99" "/pr/99"
assert_identical "$TEST_ROOT/base-modern/pr/7" "$STAGE/pr/7" "/pr/7 (deep tree)"
assert_root_identical "$TEST_ROOT/base-modern" "$STAGE" "the released root"

# --- 4. cleanup -------------------------------------------------------------

begin "closing a pull request removes only its preview"
make_baseline "$TEST_ROOT/base-cleanup" modern
mkdir -p "$TEST_ROOT/base-cleanup/pr/42/assets"
echo "<html>preview 42</html>" >"$TEST_ROOT/base-cleanup/pr/42/index.html"
echo "x" >"$TEST_ROOT/base-cleanup/pr/42/assets/style.css"
run_dry cleanup DOCS_DEPLOY_CHANNEL=preview-cleanup DOCS_DEPLOY_PR=42 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-cleanup"
assert_missing "$STAGE/pr/42" "/pr/42 is gone"
assert_identical "$TEST_ROOT/base-cleanup/pr/41" "$STAGE/pr/41" "/pr/41"
assert_identical "$TEST_ROOT/base-cleanup/pr/99" "$STAGE/pr/99" "/pr/99"
assert_identical "$TEST_ROOT/base-cleanup/pr/7" "$STAGE/pr/7" "/pr/7 (deep tree)"
assert_identical "$TEST_ROOT/base-cleanup/nightly" "$STAGE/nightly" "/nightly"
assert_identical "$TEST_ROOT/base-cleanup/old" "$STAGE/old" "/old"
assert_root_identical "$TEST_ROOT/base-cleanup" "$STAGE" "the released root"

begin "a cleanup with nothing to remove commits nothing"
# The PR closed without ever publishing docs (it touched no docs, or its build
# failed). A cleanup must be a no-op then, not a commit that rewrites the root.
run_dry cleanup-noop DOCS_DEPLOY_CHANNEL=preview-cleanup DOCS_DEPLOY_PR=4242 \
	DOCS_DEPLOY_BRANCH=some-feature-branch \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
if grep -q "nothing to commit" "$TEST_ROOT/run.log"; then
	pass "reported nothing to commit"
else
	fail "expected a no-op; log said:"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
fi
assert_root_identical "$TEST_ROOT/base-modern" "$STAGE" "the released root"
assert_identical "$TEST_ROOT/base-modern/pr" "$STAGE/pr" "every preview"

begin "a cleanup builds nothing, so it works with no book output at all"
# By the time a pull request closes its branch may be gone; a cleanup that
# needed to build the book from it could never run.
rm -rf "$TEST_ROOT/repo-nobuild"
mkdir -p "$TEST_ROOT/repo-nobuild"
rc=0
(
	cd "$TEST_ROOT/repo-nobuild"
	env DOCS_DEPLOY_DRY_RUN=1 DOCS_DEPLOY_CHANNEL=preview-cleanup DOCS_DEPLOY_PR=42 \
		DOCS_DEPLOY_BRANCH=gone \
		DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-cleanup" \
		DOCS_DEPLOY_STAGE_DIR="$TEST_ROOT/stage-nobuild" \
		bash "$DOCS_SH"
) >"$TEST_ROOT/run.log" 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
	assert_missing "$TEST_ROOT/stage-nobuild/pr/42" "/pr/42 removed without any book output present"
else
	fail "a cleanup in a tree with no built book failed (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
fi

# --- 5. refusals ------------------------------------------------------------

begin "unknown channels and unusable pull-request numbers are refused"
assert_refused "an unknown branch" "publishes no docs channel" \
	DOCS_DEPLOY_BRANCH=my-topic-branch DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_refused "an unknown channel name" "unknown DOCS_DEPLOY_CHANNEL" \
	DOCS_DEPLOY_CHANNEL=staging DOCS_DEPLOY_BRANCH=dev \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_refused "a preview with no pull-request number" "needs a pull-request number" \
	DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_BRANCH=topic \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
# Each of these would otherwise become a path segment under the publish
# checkout and a URL prefix inside every built page.
# `٤٢` is Arabic-Indic for 42: a locale-collated `[0-9]` range MATCHES it,
# so this case is what pins the validation to ASCII digits.
for bad in "../../etc" "42/../../nightly" "abc" "0" "007" "4 2" "42;rm -rf /" "-1" "٤٢"; do
	assert_refused "the pull-request number '$bad'" "is not a pull-request number" \
		DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR="$bad" DOCS_DEPLOY_BRANCH=topic \
		DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
done
# The local-verification knobs must not be usable on a run that really
# publishes -- each of them makes the published bytes something other than a
# faithful build of the checkout.
assert_refused "DOCS_DEPLOY_BASELINE on a real deploy" "local-verification knob" \
	DOCS_DEPLOY_DRY_RUN=0 DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
assert_refused "DOCS_DEPLOY_STAGE_DIR on a real deploy" "local-verification knob" \
	DOCS_DEPLOY_DRY_RUN=0 DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev \
	DOCS_DEPLOY_STAGE_DIR="$TEST_ROOT/stage-nope"
assert_refused "DOCS_DEPLOY_SKIP_BUILD on a real deploy" "local-verification knob" \
	DOCS_DEPLOY_DRY_RUN=0 DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev
# A typo in the stage dir must not become `rm -rf` on a real directory.
mkdir -p "$TEST_ROOT/precious" && echo "keep me" >"$TEST_ROOT/precious/file"
assert_refused "a non-empty DOCS_DEPLOY_STAGE_DIR" "is not empty" \
	DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern" \
	DOCS_DEPLOY_STAGE_DIR="$TEST_ROOT/precious"
if [ -f "$TEST_ROOT/precious/file" ]; then
	pass "the non-empty directory was left alone"
else
	fail "the refused run deleted the directory anyway"
fi

begin "a pull_request event picks the preview channel without being told"
run_dry event-derived GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/8123/merge \
	DOCS_DEPLOY_BRANCH=8123/merge DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
if grep -q "channel='preview'" "$TEST_ROOT/run.log" && [ -d "$STAGE/pr/8123" ]; then
	pass "refs/pull/8123/merge -> the preview channel at /pr/8123"
else
	fail "the pull-request event did not select the preview channel"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
fi

begin "a stray DOCS_DEPLOY_PR cannot divert a mainline deploy"
run_dry stray-pr DOCS_DEPLOY_PR=42 DOCS_DEPLOY_BRANCH=stable \
	DOCS_DEPLOY_BASELINE="$TEST_ROOT/base-modern"
if grep -q "channel='released'" "$TEST_ROOT/run.log"; then
	pass "a stable deploy with DOCS_DEPLOY_PR set still publishes the released channel"
else
	fail "DOCS_DEPLOY_PR alone changed the channel"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
fi

# --- 6. real pushes against a local bare repo -------------------------------

BARE="$TEST_ROOT/gh-pages.git"
git init -q --bare "$BARE"
REMOTE_URL="file://$BARE"

run_real() {
	(
		cd "$TEST_ROOT/repo"
		env DOCS_DEPLOY_SKIP_BUILD=1 DOCS_DEPLOY_REMOTE="$REMOTE_URL" "$@" bash "$DOCS_SH"
	) >"$TEST_ROOT/run.log" 2>&1
}

# Materialize the pushed branch so it can be diffed like any other tree.
checkout_published() {
	local dest="$TEST_ROOT/published"
	rm -rf "$dest"
	git clone -q --branch gh-pages "$REMOTE_URL" "$dest"
	rm -rf "$dest/.git"
	echo "$dest"
}

begin "a preview really pushes, into a gh-pages that does not exist yet"
rc=0
run_real DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=42 DOCS_DEPLOY_BRANCH=topic || rc=$?
if [ "$rc" != "0" ]; then
	fail "the first preview deploy failed (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
else
	PUB="$(checkout_published)"
	assert_identical "$BOOK" "$PUB/pr/42" "the published /pr/42"
	assert_grep "$PUB/robots.txt" "Disallow: /pr/" "the published robots.txt excludes previews"
	pass "gh-pages was created by a fast-forward push"
fi

begin "a released deploy onto a branch that already carries previews"
# Seed a second preview and a nightly so the released run has both other
# channels to preserve on a REAL branch, not just in a fixture.
run_real DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=99 DOCS_DEPLOY_BRANCH=topic-2
run_real DOCS_DEPLOY_CHANNEL=nightly DOCS_DEPLOY_BRANCH=dev
BEFORE="$(checkout_published)"
cp -a "$BEFORE" "$TEST_ROOT/published-before"
rc=0
run_real DOCS_DEPLOY_CHANNEL=released DOCS_DEPLOY_BRANCH=stable || rc=$?
if [ "$rc" != "0" ]; then
	fail "the released deploy failed (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
else
	PUB="$(checkout_published)"
	assert_identical "$TEST_ROOT/published-before/pr/42" "$PUB/pr/42" "the published /pr/42"
	assert_identical "$TEST_ROOT/published-before/pr/99" "$PUB/pr/99" "the published /pr/99"
	assert_identical "$TEST_ROOT/published-before/nightly" "$PUB/nightly" "the published /nightly"
	assert_identical "$OLD_BOOK" "$PUB/old" "the published /old"
fi

begin "a lost race is retried onto the winner's tip, losing neither side"
# Model the race the fast-forward push exists to catch: another channel's run
# lands between this run's fetch and its push. A `pre-receive` hook on the bare
# repo fast-forwards gh-pages to a commit the other channel "just pushed" and
# then rejects OUR push. docs.sh must re-fetch, re-apply its own subtree on the
# new tip and push again -- with the interloper's content still there.
INTRUDER="$TEST_ROOT/intruder"
git clone -q --branch gh-pages "$REMOTE_URL" "$INTRUDER"
mkdir -p "$INTRUDER/nightly"
echo "<html>pushed by the other channel mid-race</html>" >"$INTRUDER/nightly/raced.html"
git -C "$INTRUDER" add -A
git -C "$INTRUDER" -c user.email=t@t -c user.name=t commit -qm "the other channel's deploy"
ORIG_TIP="$(git -C "$BARE" rev-parse refs/heads/gh-pages)"
git -C "$INTRUDER" push -q origin gh-pages
RACE_TIP="$(git -C "$BARE" rev-parse refs/heads/gh-pages)"
# Rewind the branch but keep the objects, so the hook can install that commit
# at exactly the moment our push arrives.
git -C "$BARE" update-ref refs/heads/gh-pages "$ORIG_TIP"

cat >"$BARE/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
# Reject the first push only, having first advanced the branch under it.
#
# The \`env -u\` is load-bearing: since git 2.11 a receiving hook runs inside an
# object QUARANTINE, and \`git update-ref\` inside it fails with "ref updates
# forbidden inside quarantine environment". Clearing the quarantine variables
# puts the hook back in the real repository, which is where the run that won
# this simulated race would have written.
if [ ! -f "$TEST_ROOT/race-fired" ]; then
	: >"$TEST_ROOT/race-fired"
	env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY \\
		-u GIT_ALTERNATE_OBJECT_DIRECTORIES \\
		git update-ref refs/heads/gh-pages "$RACE_TIP" ||
		echo "could not advance the ref; the race was not simulated" >&2
	echo "simulated race: another deploy landed first" >&2
	exit 1
fi
exit 0
HOOK
chmod +x "$BARE/hooks/pre-receive"

rc=0
run_real DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=41 DOCS_DEPLOY_BRANCH=topic-3 || rc=$?
rm -f "$BARE/hooks/pre-receive"
if [ "$rc" != "0" ]; then
	fail "the raced preview deploy never succeeded (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
else
	if grep -q "push rejected (attempt 1/5)" "$TEST_ROOT/run.log"; then
		pass "the rejection was seen and retried"
	else
		fail "expected a rejected first attempt in the log"
		sed 's/^/        /' "$TEST_ROOT/run.log" >&2
	fi
	PUB="$(checkout_published)"
	assert_identical "$BOOK" "$PUB/pr/41" "this run's /pr/41 survived the retry"
	if [ -f "$PUB/nightly/raced.html" ]; then
		pass "the racing run's content survived the retry"
	else
		fail "the retry clobbered the commit that won the race"
	fi
	assert_identical "$TEST_ROOT/published-before/pr/42" "$PUB/pr/42" "the untouched /pr/42"
fi

begin "the publish is a fast-forward push, so the loser of a race cannot clobber the winner"
# The hook-based race above proves the RETRY works. It cannot prove the push is
# a fast-forward one: its `pre-receive` rejects every push, forced or not, so
# `push --force` passes it unchanged. But not force-pushing is the property the
# whole channel model rests on -- it is what makes a lost race a rejection
# instead of a silent deletion of somebody else's channel.
#
# Reaching git's OWN non-fast-forward rejection needs the winner's push to have
# COMPLETED between this run's fetch and its push. A `git` shim on PATH opens
# exactly that window: it forwards every call to the real git and, the first
# time it sees a `push`, lands the winner's commit first. The code under test is
# untouched -- the real git still performs the real push with whatever flags
# docs.sh chose. A forced push then succeeds on attempt 1 and the winner's file
# is gone; a fast-forward push is rejected, re-applied onto the new tip, and
# both survive.
FF_INTRUDER="$TEST_ROOT/ff-intruder"
git clone -q --branch gh-pages "$REMOTE_URL" "$FF_INTRUDER"
mkdir -p "$FF_INTRUDER/nightly"
echo "<html>landed while the loser was assembling</html>" >"$FF_INTRUDER/nightly/ff-raced.html"
git -C "$FF_INTRUDER" add -A
git -C "$FF_INTRUDER" -c user.email=t@t -c user.name=t commit -qm "the winner's deploy"
FF_ORIG_TIP="$(git -C "$BARE" rev-parse refs/heads/gh-pages)"
git -C "$FF_INTRUDER" push -q origin gh-pages
FF_TIP="$(git -C "$BARE" rev-parse refs/heads/gh-pages)"
# Rewind, keeping the objects: the shim re-lands this exact commit mid-run.
git -C "$BARE" update-ref refs/heads/gh-pages "$FF_ORIG_TIP"

SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
REAL_GIT="$(command -v git)"
cat >"$SHIM_DIR/git" <<SHIM
#!/usr/bin/env bash
# Forward everything to the real git; land the winner just before the first push.
if [ ! -f "$TEST_ROOT/ff-fired" ]; then
	for a in "\$@"; do
		if [ "\$a" = "push" ]; then
			: >"$TEST_ROOT/ff-fired"
			"$REAL_GIT" -C "$BARE" update-ref refs/heads/gh-pages "$FF_TIP"
			break
		fi
	done
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$SHIM_DIR/git"

rc=0
run_real DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=8 DOCS_DEPLOY_BRANCH=topic-ff \
	PATH="$SHIM_DIR:$PATH" || rc=$?
if [ ! -f "$TEST_ROOT/ff-fired" ]; then
	fail "the shim never saw a push, so no race was simulated"
elif [ "$rc" != "0" ]; then
	fail "the raced preview deploy never succeeded (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
else
	if grep -q "push rejected (attempt 1/5)" "$TEST_ROOT/run.log"; then
		pass "git rejected the stale push as non-fast-forward"
	else
		fail "the push was NOT rejected -- it was not a fast-forward push"
		sed 's/^/        /' "$TEST_ROOT/run.log" >&2
	fi
	PUB="$(checkout_published)"
	if [ -f "$PUB/nightly/ff-raced.html" ]; then
		pass "the winner's content survived the loser's publish"
	else
		fail "the loser CLOBBERED the winner (a forced push would do exactly this)"
	fi
	assert_identical "$BOOK" "$PUB/pr/8" "this run's /pr/8 was published anyway"
fi

begin "a push that can never succeed fails the run instead of looping"
cat >"$BARE/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "this remote refuses everything" >&2
exit 1
HOOK
chmod +x "$BARE/hooks/pre-receive"
rc=0
run_real DOCS_DEPLOY_CHANNEL=preview DOCS_DEPLOY_PR=7 DOCS_DEPLOY_BRANCH=topic-4 || rc=$?
rm -f "$BARE/hooks/pre-receive"
if [ "$rc" = "0" ]; then
	fail "a permanently rejecting remote produced a green run"
elif grep -q "could not push gh-pages after 5 attempts" "$TEST_ROOT/run.log"; then
	pass "gave up after the attempt budget and failed the run"
else
	fail "failed, but not with the exhausted-attempts message"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
fi
PUB="$(checkout_published)"
assert_missing "$PUB/pr/7" "nothing was published by the failed run"

begin "a real cleanup removes the published preview and nothing else"
BEFORE="$(checkout_published)"
rm -rf "$TEST_ROOT/published-before2"
cp -a "$BEFORE" "$TEST_ROOT/published-before2"
rc=0
run_real DOCS_DEPLOY_CHANNEL=preview-cleanup DOCS_DEPLOY_PR=41 DOCS_DEPLOY_BRANCH=topic-3 || rc=$?
if [ "$rc" != "0" ]; then
	fail "the cleanup deploy failed (exit $rc)"
	sed 's/^/        /' "$TEST_ROOT/run.log" >&2
else
	PUB="$(checkout_published)"
	assert_missing "$PUB/pr/41" "the closed PR's preview is gone from gh-pages"
	assert_identical "$TEST_ROOT/published-before2/pr/42" "$PUB/pr/42" "the published /pr/42"
	assert_identical "$TEST_ROOT/published-before2/pr/99" "$PUB/pr/99" "the published /pr/99"
	assert_identical "$TEST_ROOT/published-before2/nightly" "$PUB/nightly" "the published /nightly"
	assert_identical "$TEST_ROOT/published-before2/old" "$PUB/old" "the published /old"
	assert_root_identical "$TEST_ROOT/published-before2" "$PUB" "the published root"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
	echo "docs deploy channel tests: $FAILURES failure(s)." >&2
	exit 1
fi
echo "docs deploy channel tests passed."
