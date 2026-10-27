#!/usr/bin/env bash
# =============================================================================
# Contract: `build-siblings.sh` reuses a sibling artifact only when its BUILD
# STAMP says it was built from the inputs as they are now — not because the
# artifact exists, and not because its mtime is newer than something.
#
#   bash ci/test/sibling-artifact-freshness-test.sh
#
# WHY THIS FILE EXISTS
#   The short-circuit in `build_sibling` was `[ -e "$artifact_path" ]` alone.
#   Existence is not freshness, so a sibling built against an older dependency
#   reported `SKIP … already built` on every run, forever.  Observed: a
#   codetracer-js-recorder emitting `meta.dat` v3 while ct accepted only
#   v4/v5.  Because the recorder was skipped, every recording spec died inside
#   `importTraceFolder` naming THE TRACE — so the failure pointed at the
#   artifact's consumer and never at the stale producer.  The only workaround
#   was `--force --only <sibling>`, which requires already knowing the answer.
#
#   The first repair compared the artifact's mtime with the sibling HEAD's
#   commit time.  That still skipped the case that actually happened — the
#   recorders' own HEADs had not moved; `codetracer-trace-format`, which they
#   compile against through `../codetracer-trace-format` path dependencies,
#   had — and it skipped a stale artifact after checking out an OLDER commit,
#   because the artifact is then newer than HEAD.  Cases (C) and (D) below are
#   those two, and they are the reason this suite was rewritten.
#
# WHAT IT RUNS
#   The REAL scripts/build-siblings.sh, copied byte-for-byte into a throwaway
#   workspace (the script derives the workspace root from its own location, so
#   it has to be copied rather than invoked in place), against real throwaway
#   git repositories for the sibling and for both trace-format repos.  Every
#   run goes through `--only`, so exactly one sibling entry is exercised.
#
#   THE ENTRY IS CHOSEN DELIBERATELY: `codetracer-beam-recorder`, a recorder
#   with the default trace-format dependency set.  The previous version of this
#   suite took the FIRST `build_sibling` entry in the script, which is
#   `codetracer-trace-format` itself — the one entry for which "a trace-format
#   repo moved" is the same thing as "the sibling moved", so the dependency
#   case could not have been written against it.  Its artifact path is read
#   out of the real script, so the test follows the entry if it is renamed.
#
# MOCKS, AND WHY THEY ARE JUSTIFIED
#   `repro`, the build tools and `pkg-config` are stubs on PATH, for the same
#   reasons ci/test/sibling-build-failure-test.sh gives: `repro exec` is a
#   pass-through so the script's own `bash -c` wrapper and log redirection run
#   for real, and the others only need to resolve during the up-front
#   toolchain lookup.  The builder stub records that it was invoked by touching
#   a marker, which is how each case tells "rebuilt" from "skipped", writes the
#   artifact so a rebuild looks like a real one, and fails on request so the
#   "a failed build leaves no stamp" case needs no real compiler.
#   NOTHING about the freshness decision is stubbed — the HEADs, the
#   `git status` / `git diff` reads, the hashing and the stamp files are real.
#
# THE MUTATION THIS PINS
#   Measured against the mtime version of the script (as of fc5713b87): 19 of
#   25 contracts fail.  The ones that matter report a STALE artifact
#   "already built": (C) the older checkout, (D) both trace-format moves, (F)
#   no stamp, (G) both bad stamps, (H) the replaced artifact, (I) the run after
#   a failed build, (J) `--check`, and (K) the non-git sibling, which that
#   version never questioned at all.  (E)'s second run fails the other way —
#   a dirty tree is rebuilt forever.  (B) and (E)'s first and third runs DO
#   rebuild there, and fail only because the reason is an mtime one; the
#   stamp-written assertions in (A) and (I) fail because no stamp exists.
#   Against the `[ -e "$artifact_path" ]`-only arm (91f0c7849), (B) and (E)
#   additionally report "already built".  The control (A) skip passes against
#   both, and would fail only against a script that always rebuilds, which is
#   what it is for.
# =============================================================================
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
ok() {
	PASSED=$((PASSED + 1))
	echo "ok   $*"
}
bad() {
	FAILED=$((FAILED + 1))
	echo "FAIL $*" >&2
}
die() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- a throwaway workspace laid out the way the real script expects ---------
WS="$WORK/ws"
mkdir -p "$WS/codetracer/scripts" "$WS/stub-bin"
cp "$SRC_ROOT/scripts/build-siblings.sh" "$WS/codetracer/scripts/"
STAMP_DIR="$WS/codetracer/.tools/build-siblings-stamps"

# --- stubs -----------------------------------------------------------------
cat >"$WS/stub-bin/repro" <<'STUB'
#!/usr/bin/env bash
# `repro exec <dir> -- <cmd…>` → run <cmd…> unchanged.
if [ "${1:-}" = "exec" ]; then
  shift; shift                      # drop `exec` and the repo dir
  [ "${1:-}" = "--" ] && shift
  exec "$@"
fi
exit 0
STUB
# Every plausible builder gets the SAME stub, because which one a given entry
# uses is the real script's business and not this test's.  An earlier draft
# stubbed only `just` while the entry it picked builds with `cargo`, so the
# marker was never written and a case failed for the test's own reason rather
# than the product's — a false red that looked exactly like the defect.
for t in just cargo nimble go npm yarn make cmake; do
	cat >"$WS/stub-bin/$t" <<'STUB'
#!/usr/bin/env bash
# Stands in for the sibling's build recipe: records the invocation, then
# produces the artifact so a rebuild looks like a real one -- or fails, when
# the case asks it to, WITHOUT touching the artifact.
: > "${FRESHNESS_REBUILD_MARKER:?}"
if [ "${FRESHNESS_BUILD_FAIL:-0}" = 1 ]; then
  echo "stub build failing on request" >&2
  exit 7
fi
[ -n "${FRESHNESS_ARTIFACT:-}" ] && { mkdir -p "$(dirname "$FRESHNESS_ARTIFACT")"; echo built > "$FRESHNESS_ARTIFACT"; }
exit 0
STUB
done
for t in nim pkg-config; do printf '#!/usr/bin/env bash\nexit 0\n' >"$WS/stub-bin/$t"; done
chmod +x "$WS/stub-bin"/*
export PATH="$WS/stub-bin:$PATH"

# --- the sibling under test -------------------------------------------------
SIB=codetracer-beam-recorder
# Read with awk rather than grep+tr: the fields continue over line
# continuations, so stripping them needs a literal backslash, and a backslash
# inside a single-quoted shell word trips SC1003.  awk's own program body is
# not shell, so the same match costs no suppression.
ART="$(awk -v sib="$SIB" '
	/^build_sibling / {
		getline name
		gsub(/[[:space:]]|\\/, "", name)
		if (name == sib) {
			getline artifact
			gsub(/[[:space:]]|\\/, "", artifact)
			print artifact
			exit
		}
	}' "$WS/codetracer/scripts/build-siblings.sh")"
[ -n "$ART" ] || die "could not find the $SIB entry's artifact in the real script"
STAMP="$STAMP_DIR/$SIB.stamp"
echo "exercising sibling '$SIB', artifact '$ART'"

NOW=$(date +%s)

# commit_in <repo> <epoch> <msg>: one commit with a pinned date.  Dates are
# stated, never raced for: (C) needs the checked-out commit to be OLDER than
# the artifact, and (B) a commit made "after" the build.
commit_in() {
	echo "$3" >>"$WS/$1/src.txt"
	git -C "$WS/$1" add src.txt
	GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
		git -C "$WS/$1" commit -qm "$3"
}

seed_repo() { # <repo>
	rm -rf "${WS:?}/${1:?}"
	mkdir -p "$WS/$1"
	git -C "$WS/$1" init -q
	git -C "$WS/$1" config user.email t@e.invalid
	git -C "$WS/$1" config user.name T
	git -C "$WS/$1" config commit.gpgsign false
	commit_in "$1" "$((NOW - 7200))" first
	commit_in "$1" "$((NOW - 3600))" second
}

# run_script <tag> [extra args…]: one run of the real script.
run_script() {
	local tag="$1"
	shift
	export FRESHNESS_REBUILD_MARKER="$WORK/rebuilt.$tag"
	export FRESHNESS_ARTIFACT="$WS/$SIB/$ART"
	rm -f "$FRESHNESS_REBUILD_MARKER"
	(cd "$WS/codetracer" && bash scripts/build-siblings.sh --only "$SIB" "$@") \
		>"$WORK/out.$tag" 2>&1 || true
}
rebuilt() { [ -e "$WORK/rebuilt.$1" ]; }
out() { tail -6 "$WORK/out.$1" | tr '\n' ' '; }

# expect_rebuilt <tag> <desc> <reason fragment>: rebuilt AND said why.  A
# rebuild with no stated reason cannot be told from the short-circuit being
# ignored, so the reason is part of the contract.
expect_rebuilt() {
	if ! rebuilt "$1"; then
		bad "$2: reported already built — $(out "$1")"
	elif ! grep -qF -- "$3" "$WORK/out.$1"; then
		bad "$2: rebuilt, but without naming '$3' — $(out "$1")"
	else
		ok "$2"
	fi
}
expect_skipped() {
	if rebuilt "$1"; then
		bad "$2: rebuilt — $(out "$1")"
	elif ! grep -q "already built" "$WORK/out.$1"; then
		bad "$2: no 'already built' in the summary — $(out "$1")"
	else
		ok "$2"
	fi
}

# fresh_state: every repo re-seeded, then ONE real run of the script, so each
# case starts from an artifact and stamp the script itself produced.
fresh_state() {
	seed_repo "$SIB"
	seed_repo codetracer-trace-format
	seed_repo codetracer-trace-format-nim
	rm -rf "$STAMP_DIR"
	run_script seed
	rebuilt seed || die "the seeding build did not run: $(out seed)"
	unset FRESHNESS_BUILD_FAIL
}

# --- (A) CONTROL: built by the script, nothing changed → skipped -----------
# Without this arm every assertion below is satisfied by a script that simply
# always rebuilds.
fresh_state
if [ -f "$STAMP" ]; then ok "(A) a successful build writes a build stamp"; else bad "(A) a successful build writes no build stamp at $STAMP"; fi
run_script A
expect_skipped A "(A) control: an artifact built by the script, nothing changed since, is skipped"
if [ -z "$(find "$WS/$SIB" -name '*stamp*' -print -quit)" ]; then
	ok "(A) nothing is written into the sibling's tree but its build output"
else
	bad "(A) a stamp was written inside the sibling, where it is an untracked file in another repo"
fi

# --- (B) the sibling's HEAD moves forward → rebuilt ------------------------
fresh_state
commit_in "$SIB" "$((NOW + 3600))" third
run_script B
expect_rebuilt B "(B) a sibling HEAD that moved since the build is rebuilt" "moved since the stamped build"
run_script B2
expect_skipped B2 "(B) ...and the rebuild's stamp is current, so the next run skips"

# --- (C) the sibling is checked out to an OLDER commit → rebuilt -----------
# The artifact is now newer than HEAD's commit time, which is exactly what an
# mtime check reads as "fresh".
fresh_state
git -C "$WS/$SIB" checkout -q HEAD~1
run_script C
expect_rebuilt C "(C) a sibling checked out to an older commit is rebuilt" "moved since the stamped build"

# --- (D) THE CORE CASE: a dependency moves, the sibling does not -----------
# The recorder's own HEAD, tree and timestamps are unchanged; the trace format
# it compiles against through `../codetracer-trace-format` has moved.
fresh_state
commit_in codetracer-trace-format "$((NOW - 1800))" "meta.dat v4"
run_script D
expect_rebuilt D "(D) a codetracer-trace-format move rebuilds a recorder whose own HEAD did not move" \
	"dependency codetracer-trace-format moved"
fresh_state
commit_in codetracer-trace-format-nim "$((NOW - 1800))" "reader bump"
run_script D2
expect_rebuilt D2 "(D) ...and so does a codetracer-trace-format-nim move" \
	"dependency codetracer-trace-format-nim moved"

# --- (E) tracked modifications → rebuilt; the SAME ones again → skipped ----
fresh_state
echo dirty >>"$WS/$SIB/src.txt"
run_script E
expect_rebuilt E "(E) tracked modifications since the build are rebuilt" "different tracked modifications"
run_script E2
expect_skipped E2 "(E) ...but the same modifications, unchanged since that rebuild, are not rebuilt again"
echo dirtier >>"$WS/$SIB/src.txt"
run_script E3
expect_rebuilt E3 "(E) ...and a further edit is" "different tracked modifications"

# --- (F) an artifact with no stamp → rebuilt --------------------------------
# Every artifact built before stamps existed, by hand, or in another workspace.
fresh_state
rm -f "$STAMP"
run_script F
expect_rebuilt F "(F) an artifact with no build stamp is rebuilt" "no build stamp"

# --- (G) a corrupt or foreign stamp → rebuilt -------------------------------
fresh_state
printf 'garbage\n' >"$STAMP"
run_script G
expect_rebuilt G "(G) a stamp in an unknown format is rebuilt" "is not a 'format build-siblings-stamp/1' stamp"
fresh_state
head -n 1 "$STAMP" >"$STAMP.cut" && mv "$STAMP.cut" "$STAMP"
run_script G2
expect_rebuilt G2 "(G) a truncated stamp is rebuilt" "records no 'command'"

# --- (H) the artifact's bytes replaced after the stamp → rebuilt ------------
# Copying a build in from another worktree, or rebuilding it by hand, leaves a
# stamp that describes different bytes.
fresh_state
echo "hand-built from other inputs" >"$WS/$SIB/$ART"
run_script H
expect_rebuilt H "(H) an artifact replaced after its stamp was written is rebuilt" "not the file the stamp was written for"

# --- (I) a failed build leaves no stamp; --force rebuilds unconditionally ---
fresh_state
export FRESHNESS_BUILD_FAIL=1
run_script I --force
unset FRESHNESS_BUILD_FAIL
if rebuilt I && grep -q "FAIL" "$WORK/out.I"; then
	ok "(I) --force rebuilds a fresh-stamped artifact (here: and the build fails)"
else
	bad "(I) --force did not attempt a build, or the failure was not reported — $(out I)"
fi
if [ ! -e "$STAMP" ]; then
	ok "(I) a failed build leaves no stamp behind"
else
	bad "(I) a failed build left a stamp in place, vouching for whatever it left behind"
fi
run_script I2
expect_rebuilt I2 "(I) ...so the next run rebuilds" "no build stamp"
run_script I3 --force
if rebuilt I3 && [ -f "$STAMP" ]; then ok "(I) a successful --force build is stamped"; else bad "(I) a successful --force build was not stamped — $(out I3)"; fi

# --- (J) --check builds nothing and writes nothing --------------------------
fresh_state
rm -f "$STAMP"
run_script J --check
if rebuilt J; then bad "(J) --check invoked a build"; else ok "(J) --check builds nothing"; fi
if [ ! -e "$STAMP" ]; then ok "(J) --check writes no stamp"; else bad "(J) --check wrote a stamp"; fi
if grep -q "would build" "$WORK/out.J" && grep -q "no build stamp" "$WORK/out.J"; then
	ok "(J) --check reports an unstamped artifact as would-build, with the reason"
else
	bad "(J) --check did not report the unstamped artifact as would-build with its reason — $(out J)"
fi
fresh_state
cp "$STAMP" "$WORK/stamp.before"
run_script J2 --check
if ! rebuilt J2 && grep -q "already built" "$WORK/out.J2" && cmp -s "$STAMP" "$WORK/stamp.before"; then
	ok "(J) --check reports a current artifact as already built and leaves its stamp untouched"
else
	bad "(J) --check on a current artifact: $(out J2)"
fi

# --- (K) a sibling that is not a git checkout → always rebuilt --------------
# Its sources cannot be identified, so no stamp can ever describe them.
fresh_state
rm -rf "$WS/$SIB/.git"
run_script K
expect_rebuilt K "(K) a sibling that is not a git checkout is rebuilt" "not a git checkout"
run_script K2
expect_rebuilt K2 "(K) ...every time, since no stamp can vouch for it" "no build stamp"

echo ""
if [ "$FAILED" -ne 0 ]; then
	echo "FAIL: $FAILED of $((PASSED + FAILED)) contracts failed" >&2
	exit 1
fi
echo "PASS: build-siblings reuses an artifact only when its build stamp matches ($PASSED contracts)"
