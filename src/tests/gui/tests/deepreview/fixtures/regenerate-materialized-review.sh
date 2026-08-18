#!/usr/bin/env bash
# Regenerate `materialized-review.json` — the committed output of the
# MATERIALIZED DeepReview collector (RV-4), used by
# `materialized_review_dataset_test.nim` and by the Playwright review suite.
#
# The fixture is a real collection, not a hand-written document: a real Noir
# program, recorded by the real recorder (`nargo trace`), diffed by real git,
# and collected by `replay-server review-collect`.  That is the point — the
# test's claim is that what the collector actually writes is what the GUI
# reader accepts, and a hand-written fixture could not fail that way.
#
# Noir is the fixture language because it is the materialized recorder the
# CodeTracer dev shell provides: `codetracer_python_recorder` is not installed
# for the shell's interpreter, and the JavaScript and Ruby recorders are
# sibling repos that must be built first.  The collector reads a trace, not a
# language.
#
# `nargo trace` writes the LEGACY materialized layout (a runtime_tracing
# `trace.json`, not a `.ct` container), which is also the shape a Python
# recording has — so the fixture exercises `materialized_source`'s legacy arm
# as well.
#
# Two fields are re-generated on every run and are therefore not asserted by
# the tests: `commitSha` / `baseCommitSha` (a fresh `git init` each time) and
# `collectionTimeMs`.
#
# Usage, from the codetracer repo root, inside the dev shell:
#     src/db-backend/target/debug/replay-server must exist (cargo build)
#     bash src/tests/gui/tests/deepreview/fixtures/regenerate-materialized-review.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../../../.." && pwd)"
collector="${CODETRACER_REPLAY_SERVER_PATH:-$repo_root/src/db-backend/target/debug/replay-server}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v nargo >/dev/null || {
	echo "nargo is required to record the fixture" >&2
	exit 1
}
[ -x "$collector" ] || {
	echo "no collector at $collector; run cargo build in src/db-backend" >&2
	exit 1
}

mkdir -p "$work/repo/src" "$work/recordings/run-1" "$work/recordings/run-2"
cp "$repo_root/src/db-backend/test-programs/noir_loop/Nargo.toml" "$work/repo/"
cp "$repo_root/src/db-backend/test-programs/noir_loop/Prover.toml" "$work/repo/"

# The BASE revision: the loop adds `x` directly.
cat >"$work/repo/src/main.nr" <<'EOF'
fn scale(i: Field, x: Field) -> Field {
    let scaled = i * x;
    scaled
}

fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        sum = sum + x;
    }
    assert(sum == 20);
}
EOF
git -C "$work/repo" init -q
git -C "$work/repo" config user.email rv4@fixture
git -C "$work/repo" config user.name rv4
git -C "$work/repo" add -A
git -C "$work/repo" commit -qm base

# The REVIEWED revision: the loop scales by the index through a helper.
cat >"$work/repo/src/main.nr" <<'EOF'
fn scale(i: Field, x: Field) -> Field {
    let scaled = i * x;
    scaled
}

fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        let contribution = scale(i as Field, x);
        sum = sum + contribution;
    }
    assert(sum == 30);
}
EOF
git -C "$work/repo" add -A
git -C "$work/repo" commit -qm change

# TWO recordings of the same revision.  Two, not one, because a review of a
# change is normally a review of several runs of it, and because the
# single-recording case cannot exercise anything the merge does: the
# trace-context selector is only offered when there is a choice
# (`vcs_vm.hasTraceContextChoice`), and the per-line `partial` flag is only
# meaningful across recordings.  Both runs are of the same revision with the
# same input, so every line is covered by both and nothing is partial — which
# is itself the assertion: a merge must not mark a line partial just because
# more than one recording exists.
(cd "$work/repo" && nargo trace --out-dir "$work/recordings/run-1" >/dev/null)
(cd "$work/repo" && nargo trace --out-dir "$work/recordings/run-2" >/dev/null)

"$collector" review-collect \
	--repo "$work/repo" \
	--diff 'HEAD~..HEAD' \
	--recordings "$work/recordings" \
	--output "$work/out"

# Copied with a trailing newline appended: `serde_json::to_string_pretty` does
# not write one, and the repository's `end-of-file-fixer` pre-commit hook adds
# it. Doing it here means a regeneration produces exactly the committed bytes
# instead of a one-character diff the hook then undoes.
{
	cat "$work/out/review.json"
	echo
} >"$here/materialized-review.json"
echo "wrote $here/materialized-review.json"
