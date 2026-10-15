#!/usr/bin/env bash
# =============================================================================
# Contract: `build-siblings.sh` decides "already built" by FRESHNESS, not by
# the artifact merely existing.
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
#   The same class of trap had already cost a full false-defect investigation
#   elsewhere in this repo: a stale renderer bundle reported as built, with an
#   agent testing its own reverted mutation for a session.  A build step that
#   claims work it did not do is the defect, not the staleness underneath it.
#
# WHAT IT RUNS
#   The REAL scripts/build-siblings.sh, copied byte-for-byte into a throwaway
#   workspace (the script derives the workspace root from its own location, so
#   it has to be copied rather than invoked in place).  The three cases drive
#   it through `--only`, so exactly one sibling entry is exercised per run.
#
# MOCKS, AND WHY THEY ARE JUSTIFIED
#   `repro`, `just`, `nim`, `nimble` and `pkg-config` are stubs on PATH, for
#   the same reasons ci/test/sibling-build-failure-test.sh gives: `repro exec`
#   is a pass-through so the script's own `bash -c` wrapper and log redirection
#   run for real, and the others only need to resolve during the up-front
#   toolchain lookup.  `just` records that it was invoked by touching a marker,
#   which is how each case tells "rebuilt" from "skipped".
#   NOTHING about the freshness decision is stubbed — the git timestamps and
#   the `status --porcelain` read are real, against real throwaway repos.
#
# THE MUTATION THIS PINS
#   Restoring the arm to `[ -e "$artifact_path" ]` alone makes cases (B) and
#   (C) FAIL and leaves (A) passing.  (A) alone would therefore pass against
#   the defect, which is why it is a control and not the test.
# =============================================================================
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- a throwaway workspace laid out the way the real script expects ---------
WS="$WORK/ws"
mkdir -p "$WS/codetracer/scripts" "$WS/codetracer/ci/lib" "$WS/stub-bin"
cp "$SRC_ROOT/scripts/build-siblings.sh" "$WS/codetracer/scripts/"
for f in "$SRC_ROOT"/ci/lib/*.sh; do [ -e "$f" ] && cp "$f" "$WS/codetracer/ci/lib/"; done

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
# uses is the real script's business and not this test's.  The first draft
# stubbed only `just` and the entry it picked builds with `cargo`, so the
# marker was never written and case (B) failed for the test's own reason
# rather than the product's — a false red that looked exactly like the defect.
for t in just cargo nimble go npm yarn make cmake; do
	cat >"$WS/stub-bin/$t" <<'STUB'
#!/usr/bin/env bash
# Stands in for the sibling's build recipe: records the invocation, then
# produces the artifact so a rebuild looks like a real one.
: > "${FRESHNESS_REBUILD_MARKER:?}"
[ -n "${FRESHNESS_ARTIFACT:-}" ] && { mkdir -p "$(dirname "$FRESHNESS_ARTIFACT")"; : > "$FRESHNESS_ARTIFACT"; }
exit 0
STUB
done
for t in nim pkg-config; do printf '#!/usr/bin/env bash\nexit 0\n' >"$WS/stub-bin/$t"; done
chmod +x "$WS/stub-bin"/*
export PATH="$WS/stub-bin:$PATH"

# --- the sibling under test -------------------------------------------------
# Picked by reading the real script's own entries, so the test exercises a
# real `build_sibling` call rather than one invented here.
#   Read with awk rather than grep+tr: the fields continue over line
#   continuations, so stripping them needs a literal backslash, and a
#   backslash inside a single-quoted shell word trips SC1003. awk's own
#   program body is not shell, so the same match costs no suppression.
read -r SIB ART < <(awk '
	/^build_sibling / {
		getline name; getline artifact
		gsub(/[[:space:]]|\\/, "", name)
		gsub(/[[:space:]]|\\/, "", artifact)
		print name, artifact
		exit
	}' "$WS/codetracer/scripts/build-siblings.sh")
[ -n "$SIB" ] || fail "could not read a sibling name out of the real script"
[ -n "$ART" ] || fail "could not read $SIB's artifact path out of the real script"
echo "exercising sibling '$SIB', artifact '$ART'"

seed_repo() { # $1 = commit epoch for HEAD
	rm -rf "${WS:?}/${SIB:?}"
	mkdir -p "$WS/$SIB"
	git -C "$WS/$SIB" init -q
	git -C "$WS/$SIB" config user.email t@e.invalid
	git -C "$WS/$SIB" config user.name T
	echo src >"$WS/$SIB/src.txt"
	git -C "$WS/$SIB" add src.txt
	GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" \
		git -C "$WS/$SIB" commit -qm seed
}

run_script() {
	export FRESHNESS_REBUILD_MARKER="$WORK/rebuilt.$1"
	export FRESHNESS_ARTIFACT="$WS/$SIB/$ART"
	rm -f "$FRESHNESS_REBUILD_MARKER"
	(cd "$WS/codetracer" && bash scripts/build-siblings.sh --only "$SIB") \
		>"$WORK/out.$1" 2>&1 || true
}
rebuilt() { [ -e "$WORK/rebuilt.$1" ]; }

NOW=$(date +%s)

# --- (A) CONTROL: artifact newer than HEAD, clean tree → skipped ------------
# Without this arm every assertion below is satisfied by a script that simply
# always rebuilds, which would pass the other two cases and be useless.
seed_repo "$((NOW - 600))"
mkdir -p "$(dirname "$WS/$SIB/$ART")"
: >"$WS/$SIB/$ART"
touch -d "@$NOW" "$WS/$SIB/$ART"
run_script A
rebuilt A && fail "(A) a fresh artifact on a clean tree was rebuilt — the short-circuit is gone entirely"
grep -q "already built" "$WORK/out.A" || fail "(A) expected 'already built' in the summary; got: $(tail -3 "$WORK/out.A")"
echo "ok (A) fresh artifact, clean tree -> skipped"

# --- (B) artifact OLDER than HEAD → rebuilt --------------------------------
# This is the js-recorder case: the sibling moved forward, the artifact did not.
seed_repo "$NOW"
mkdir -p "$(dirname "$WS/$SIB/$ART")"
: >"$WS/$SIB/$ART"
touch -d "@$((NOW - 7200))" "$WS/$SIB/$ART"
run_script B
rebuilt B || fail "(B) an artifact two hours older than HEAD was reported already built — existence was treated as freshness"
grep -q "predates HEAD" "$WORK/out.B" || fail "(B) rebuilt without saying why; a rebuild with no stated reason cannot be told from the short-circuit being ignored"
echo "ok (B) artifact older than HEAD -> rebuilt, with a reason"

# --- (C) uncommitted changes → rebuilt ------------------------------------
seed_repo "$((NOW - 600))"
mkdir -p "$(dirname "$WS/$SIB/$ART")"
: >"$WS/$SIB/$ART"
touch -d "@$NOW" "$WS/$SIB/$ART"
echo dirty >>"$WS/$SIB/src.txt"
run_script C
rebuilt C || fail "(C) a dirty tree was reported already built — an artifact built from uncommitted source is not known to be current"
grep -q "uncommitted changes" "$WORK/out.C" || fail "(C) rebuilt without naming the dirty tree as the reason"
echo "ok (C) uncommitted changes -> rebuilt, with a reason"

echo "PASS: build-siblings decides already-built by freshness, not existence (3 cases)"
