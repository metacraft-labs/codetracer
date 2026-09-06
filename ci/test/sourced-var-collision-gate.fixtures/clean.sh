#!/usr/bin/env bash
# FIXTURE — every construction here is CORRECT and the detector must stay quiet
# on all of them. This half matters as much as leaky.sh: a detector that flags
# the fix as well as the defect makes the rule unusable, and noise in the
# `lint-bash` lane skips every build artefact job behind it.
#
# NOT-A-CI-GATE: input data for sourced-var-collision-gate.sh, which SCANS this
# file as text. See leaky.sh for the same note; both counted as reachable until
# 2026-09-06 because the suite NAMES them in `expect_clean`/`expect_leak` calls,
# and both of those only ever grep the file they are handed.

# 1. Declared `local` on a PRECEDING line, then assigned. This is the single
#    most common correct form in ci/lib/*.sh, and a detector that only
#    understands `local X=` reports every one of them.
resolve() {
	local repo_root script_dir
	repo_root="$(pwd)"
	script_dir="$(dirname "$0")"
	echo "${repo_root} ${script_dir}"
}

# 2. Assigned inside a function with `local` on the same line.
inner() {
	local SCRIPT_DIR="$PWD"
	echo "$SCRIPT_DIR"
}

# 3. Default-preserving: defines the name when unset, never overwrites the
#    caller's. scripts/docs/deep-review-capture-lib.sh does this deliberately
#    so callers can override CTDR_LABEL.
ROOT_DIR="${ROOT_DIR:-/tmp/fallback}"

# 4. Inside a subshell — the assignment cannot escape.
(
	OUT_DIR="$PWD/out"
	echo "$OUT_DIR"
)

# 5. Inside a heredoc body: data, not code.
cat >/dev/null <<'EOF'
BUILD_DIR=/somewhere/else
EOF

# 6. A comment.
# DEST=/not/an/assignment

# 7. A SELF-GUARDED fallback: the long-hand form of `${X:-…}`. It supplies the
#    name only when the caller has not, so it cannot overwrite anything. This
#    is the remedy this gate prints for setup-codetracer-runtime-env.sh, so
#    flagging it would make the gate refuse its own fix.
if [[ -z ${WORKSPACE_ROOT:-} ]]; then
	WORKSPACE_ROOT="$(cd .. && pwd)"
fi

# 8. A PREFIXED name. This is what the remedy looks like, so it must never be
#    flagged, or the gate would refuse its own fix.
CT_REPO_ROOT="$(pwd)"
CT_RECORDER_ROOT="${CT_REPO_ROOT}/../codetracer-native-recorder"

echo "${ROOT_DIR} ${CT_REPO_ROOT} ${CT_RECORDER_ROOT}"
resolve
inner
