#!/usr/bin/env bash
# =============================================================================
# readonly-leftovers-sweep-test.sh — contract suite for the pre-checkout sweep
# that restores owner-write over a persistent runner's work directory.
#
# ## Why this suite exists at all
#
# The sweep has to run BEFORE `actions/checkout`, so it cannot be a script the
# repository provides (the repository is not on disk yet) and it cannot be a
# local composite action (same reason). It is an inline `run:` block, pasted
# into seven jobs. An inline block has no other way to be executed outside CI,
# and "we will see it in the log" is exactly the standard that let a `grep`
# exit 127, get swallowed by `|| true`, and print an EMPTY count as a pass on
# this same runner class.
#
# So: ci/runner/sweep-readonly-leftovers.sh holds the canonical body, this
# suite asserts the seven pasted copies are byte-identical to it, and this
# suite RUNS it against fixtures.
#
# ## What it asserts
#
#   - the body is present in exactly the jobs that need it, and nowhere else
#   - every pasted copy is byte-identical to the canonical one
#   - the body invokes no `grep`, `sed`, `awk` or `find` — none of which are on
#     PATH in a raw `run:` step on the nix-darwin m3 runners
#   - on a POISONED fixture, run under `env -i PATH=<bash+git only>` with
#     `bash -e`: the before-count is NON-ZERO, the after-count is zero, the
#     directories really are writable afterwards, and the exit status is 0
#   - on a CLEAN fixture: the count is zero and the log SAYS SO, rather than
#     printing an empty number
#   - a 0444 FILE alone is not counted — read-only files are ordinary (git's
#     own pack files are 0444) and do not block unlink
#   - with no `chmod` reachable, the body FAILS LOUDLY instead of reporting a
#     clean sweep it never performed
#
# Pure bash + git + python3 over mktemp fixtures; no nix, no network, no CI.
# =============================================================================

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$(pwd)"

CANON="ci/runner/sweep-readonly-leftovers.sh"
WORKFLOW=".github/workflows/codetracer.yml"

PASS=0
FAIL=0
FIX=""

cleanup() {
	if [ -n "${FIX}" ] && [ -d "${FIX}" ]; then
		chmod -R u+w "${FIX}" 2>/dev/null || true
		rm -rf "${FIX}"
	fi
}
trap cleanup EXIT

pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | while IFS= read -r line; do
			printf '       %s\n' "${line}"
		done
	fi
}

echo "=== read-only leftovers sweep contract suite"
echo

# -----------------------------------------------------------------------------
echo "--- the canonical body and its pasted copies"
# -----------------------------------------------------------------------------
FIX="$(mktemp -d)"
BODY="${FIX}/body.sh"

python3 - "${REPO_ROOT}/${CANON}" "${BODY}" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
begin = "# --- BEGIN INLINE BODY"
end = "# --- END INLINE BODY"
if begin not in text or end not in text:
    sys.exit(f"{src}: the INLINE BODY markers are gone; nothing can be kept in sync")
body = text.split(begin, 1)[1].split("\n", 1)[1].split(end, 1)[0]
open(dst, "w", encoding="utf-8").write(body)
PY
if [ -s "${BODY}" ]; then
	pass "the canonical body is delimited and non-empty ($(wc -l <"${BODY}" | tr -d ' ') lines)"
else
	fail "the canonical body is delimited and non-empty" "extraction produced nothing"
fi

# The helper is written to a file and then invoked, rather than fed to
# `python3 -` inside a command substitution: bash scans a `$( … )` for its
# matching paren BEFORE it honours the heredoc inside, so a python program with
# an unbalanced-looking token in it turns into "unexpected EOF" at the opening
# paren. Cost an hour once; not again.
cat >"${FIX}/sync.py" <<'PY'
import re
import sys

# Stdlib only, deliberately: devShells.lint provides python3 but makes no
# promise about PyYAML, and a contract suite that skips itself on ImportError
# is the thing this campaign keeps being burned by. The two shapes read here
# are both unambiguous at the line level -- a job key at two spaces, and a
# block scalar under a known step name.
workflow, body_path, canon = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(body_path, encoding="utf-8").read()
lines = open(workflow, encoding="utf-8").read().splitlines(keepends=True)

job_key = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")

jobs = []          # (name, first line index)
for i, line in enumerate(lines):
    m = job_key.match(line)
    if m:
        jobs.append((m.group(1), i))


def job_at(index):
    name = None
    for jobname, start in jobs:
        if start <= index:
            name = jobname
        else:
            break
    return name


# The jobs that MUST carry it: every job pinned to the persistent self-hosted
# macOS class. Derived from runs-on, not from a hand-kept list, so a new
# aarch64-darwin job cannot appear without either the sweep or a deliberate
# change here. test-non-gui / test-ui-tests reach that class through a
# matrix, so they are named.
expected = {"test-non-gui", "test-ui-tests"}
for i, line in enumerate(lines):
    if line.strip().startswith("runs-on:") and "aarch64-darwin" in line:
        expected.add(job_at(i))

found = {}
for i, line in enumerate(lines):
    if line.strip() != "- name: Sweep read-only leftovers from the persistent work directory":
        continue
    # The run: | block scalar that follows: everything more-indented than the
    # run: key itself, de-indented by the block's own indent.
    j = i + 1
    while j < len(lines) and lines[j].strip() != "run: |":
        j += 1
    indent = len(lines[j]) - len(lines[j].lstrip()) + 2
    j += 1
    collected = []
    while j < len(lines):
        current = lines[j]
        if current.strip() and not current.startswith(" " * indent):
            break
        collected.append(current[indent:] if current.strip() else "\n")
        j += 1
    while collected and collected[-1] == "\n":
        collected.pop()
    found[job_at(i)] = "".join(collected)

print(f"jobs on aarch64-darwin (incl. matrix): {len(expected)}")
print(f"jobs carrying the sweep step        : {len(found)}")

problems = []
missing = sorted(expected - set(found))
extra = sorted(set(found) - expected)
if missing:
    problems.append(f"jobs on the persistent macOS class WITHOUT the sweep: {missing}")
if extra:
    problems.append(f"jobs carrying the sweep that are not on that class: {extra}")
if not found:
    problems.append("no job carries the sweep step at all")

for name in sorted(found):
    if found[name] != body:
        problems.append(f"{name}: the pasted body has DIVERGED from {canon}")

for line in problems:
    print(f"    ! {line}")
sys.exit(1 if problems else 0)
PY
SYNC_OUT="$(python3 "${FIX}/sync.py" "${REPO_ROOT}/${WORKFLOW}" "${BODY}" "${CANON}" 2>&1)"
SYNC_RC=$?
printf '%s\n' "${SYNC_OUT}" | while IFS= read -r line; do printf '  %s\n' "${line}"; done
if [ "${SYNC_RC}" -eq 0 ]; then
	pass "every aarch64-darwin job carries the sweep, byte-identical to ${CANON}"
else
	fail "every aarch64-darwin job carries the sweep, byte-identical to ${CANON}" ""
fi

# -----------------------------------------------------------------------------
echo
echo "--- the body uses no tool the m3 runners lack"
# -----------------------------------------------------------------------------
# `grep`, `sed`, `awk` and `find` are absent from a raw `run:` step's PATH on
# the nix-darwin runners: that PATH is the nix profile built from
# `extraPackages` in metacraft-labs/infra (coreutils-full, git, curl, jq, gh,
# gnupg, openssh, direnv) and does NOT include /usr/bin. A `grep` there exits
# 127; with `|| true` beside it, the step prints an empty count and reads like
# a pass. That has already happened once in this campaign.
cat >"${FIX}/banned.py" <<'PY'
import re
import sys

body = open(sys.argv[1], encoding="utf-8").read()
hits = []
for lineno, line in enumerate(body.splitlines(), 1):
    code = line.split("#", 1)[0]
    for tool in ("grep", "sed", "awk", "find", "xargs", "python", "perl"):
        if re.search(rf"(?:^|[^A-Za-z0-9_./-]){tool}\b", code):
            hits.append(f"line {lineno}: {tool}: {line.strip()}")
for hit in hits:
    print(hit)
PY
banned_hits="$(python3 "${FIX}/banned.py" "${BODY}" 2>&1)"
if [ -z "${banned_hits}" ]; then
	pass "the body invokes no grep/sed/awk/find/xargs/python/perl"
else
	fail "the body invokes no grep/sed/awk/find/xargs/python/perl" "${banned_hits}"
fi

# -----------------------------------------------------------------------------
echo
echo "--- executing it: a POISONED work directory"
# -----------------------------------------------------------------------------
# The tree m3-mcl-003 was left holding: a gitignored `.app` whose staged
# `node_modules` carries the Nix store's 0555 on every directory.
poison() {
	local ws="$1" nm
	nm="${ws}/codetracer/non-nix-build/CodeTracer.app/Contents/MacOS/node_modules"
	mkdir -p "${nm}/abbrev/lib" "${nm}/monaco-editor/min/vs" "${nm}/xterm/lib"
	echo x >"${nm}/abbrev/LICENSE"
	echo x >"${nm}/monaco-editor/min/vs/loader.js"
	echo x >"${nm}/xterm/lib/xterm.js"
	# git's own 0444 files, which must NOT be counted.
	mkdir -p "${ws}/codetracer/.git/objects/pack"
	echo p >"${ws}/codetracer/.git/objects/pack/pack-deadbeef.pack"
	chmod 0444 "${ws}/codetracer/.git/objects/pack/pack-deadbeef.pack"
	# A symlink to a read-only tree OUTSIDE the work directory -- the shape of
	# the /nix/store links these checkouts carry. The sweep must not follow it:
	# a store path is not the runner's to chmod, and chasing it would leave the
	# work directory entirely.
	mkdir -p "${FIX}/fake-store/ro"
	chmod 0555 "${FIX}/fake-store/ro"
	ln -s "${FIX}/fake-store/ro" "${ws}/codetracer/store-link"
	chmod -R a-w "${nm}"
}

# `env -i` with a PATH holding ONLY the directories of bash and git: the
# nix-darwin runners' raw-`run:` PATH is not much bigger than this, and running
# the body under a fat developer PATH would prove nothing about them. `bash -e`
# because that is the shell GitHub actually uses for a `run:` block, and a bare
# `A && B` list that evaluates false is fatal there.
BASH_BIN="$(command -v bash)"
GIT_BIN="$(command -v git)"
MINPATH="$(dirname "${BASH_BIN}"):$(dirname "${GIT_BIN}")"

run_body() {
	# run_body <workspace> [extra PATH entries]
	OUT="$(env -i \
		PATH="${2:-${MINPATH}}" \
		HOME="${FIX}/home" \
		RUNNER_WORKSPACE="$1" \
		RUNNER_NAME="fixture-runner" \
		"${BASH_BIN}" -e "${BODY}" 2>&1)"
	RC=$?
}

expect_line() {
	if printf '%s' "${OUT}" | grep -qF "$1"; then
		pass "$2"
	else
		fail "$2" "${OUT}"
	fi
}

WS="${FIX}/ws-poisoned"
mkdir -p "${WS}" "${FIX}/home"
poison "${WS}"

# The fixture must actually be poisoned, or every assertion below is vacuous.
planted="$(find "${WS}" -type d ! -perm -u+w | wc -l | tr -d ' ')"
if [ "${planted}" -gt 0 ]; then
	pass "fixture precondition: ${planted} unwritable directory(ies) planted"
else
	fail "fixture precondition: unwritable directories planted" "found 0"
fi

run_body "${WS}"
if [ "${RC}" -eq 0 ]; then
	pass "the sweep exits 0 on a poisoned work directory"
else
	fail "the sweep exits 0 on a poisoned work directory" "rc=${RC}
${OUT}"
fi
expect_line "found ${planted} unwritable directory(ies)" \
	"it reports the count it FOUND, and the count matches what was planted"
expect_line "after chmod -R u+w: 0 unwritable directory(ies) remain" \
	"it reports zero remaining AFTER the chmod"
expect_line "RESTORED owner-write on ${planted} directory(ies)" \
	"it reports how many directories it actually fixed"
expect_line "unwritable ${WS}/codetracer/non-nix-build/CodeTracer.app" \
	"it names the offending paths rather than only counting them"

# Measured on the tree, not on what the log claimed.
left="$(find "${WS}" -type d ! -perm -u+w | wc -l | tr -d ' ')"
if [ "${left}" -eq 0 ]; then
	pass "the work directory really is writable afterwards"
else
	fail "the work directory really is writable afterwards" "${left} still unwritable"
fi

# The 0444 pack file must be untouched-as-a-count and the store symlink
# untouched-as-a-target: chasing it would chmod something that is not ours.
if [ ! -w "${FIX}/fake-store/ro" ]; then
	pass "it did not follow the store symlink out of the work directory"
else
	fail "it did not follow the store symlink out of the work directory" \
		"${FIX}/fake-store/ro became writable"
fi

# -----------------------------------------------------------------------------
echo
echo "--- executing it: a CLEAN work directory"
# -----------------------------------------------------------------------------
# The case that must NOT read like a success it did not earn. A sweep over a
# clean host has to say it found nothing, in those words, so a reader can tell
# it apart from a sweep that never ran.
WS_CLEAN="${FIX}/ws-clean"
mkdir -p "${WS_CLEAN}/codetracer/src/lib" "${WS_CLEAN}/codetracer/.git/objects/pack"
echo x >"${WS_CLEAN}/codetracer/src/lib/main.nim"
echo p >"${WS_CLEAN}/codetracer/.git/objects/pack/pack-cafe.pack"
chmod 0444 "${WS_CLEAN}/codetracer/.git/objects/pack/pack-cafe.pack"

run_body "${WS_CLEAN}"
if [ "${RC}" -eq 0 ]; then
	pass "the sweep exits 0 on a clean work directory"
else
	fail "the sweep exits 0 on a clean work directory" "rc=${RC}
${OUT}"
fi
expect_line "found 0 unwritable directory(ies)" "it prints a zero, not an empty count"
expect_line "NOTHING FOUND - this host was already clean" \
	"a clean host is reported as a clean host, not as a successful sweep"
if [ ! -w "${WS_CLEAN}/codetracer/.git/objects/pack/pack-cafe.pack" ]; then
	pass "a 0444 file alone is not treated as a leftover (git's packs are 0444)"
else
	fail "a 0444 file alone is not treated as a leftover" "the pack file was chmodded"
fi

# -----------------------------------------------------------------------------
echo
echo "--- executing it: no work directory at all (a fresh runner)"
# -----------------------------------------------------------------------------
run_body "${FIX}/does-not-exist"
if [ "${RC}" -eq 0 ]; then
	pass "an absent work directory is not an error"
else
	fail "an absent work directory is not an error" "rc=${RC}
${OUT}"
fi
expect_line "work dir absent - fresh runner" "an absent work directory says so"

# -----------------------------------------------------------------------------
echo
echo "--- arm: no chmod reachable"
# -----------------------------------------------------------------------------
# THE FAILURE THIS SUITE EXISTS FOR. `chmod` comes from coreutils-full in the
# runner's nix profile, so it is there today; if it ever is not, the sweep must
# say it could not fix what it found, NOT print a tidy summary of work it never
# did. Tested by rewriting the body's fallback candidates to paths that cannot
# exist, because /bin/chmod cannot be hidden from a test.
NOCHMOD="${FIX}/body-nochmod.sh"
python3 - "${BODY}" "${NOCHMOD}" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "for candidate in /bin/chmod /usr/bin/chmod /run/current-system/sw/bin/chmod; do"
if needle not in text:
    sys.exit("the arm cannot neuter what it cannot find: the chmod fallback list moved")
open(dst, "w", encoding="utf-8").write(
    text.replace(needle, "for candidate in /nonexistent/chmod; do")
)
PY

WS_NC="${FIX}/ws-nochmod"
mkdir -p "${WS_NC}" "${FIX}/home"
poison "${WS_NC}"
mkdir -p "${FIX}/emptybin"
OUT="$(env -i PATH="${FIX}/emptybin" HOME="${FIX}/home" \
	RUNNER_WORKSPACE="${WS_NC}" RUNNER_NAME="fixture-runner" \
	"${BASH_BIN}" -e "${NOCHMOD}" 2>&1)"
RC=$?
if [ "${RC}" -ne 0 ]; then
	pass "with no chmod reachable the sweep FAILS"
else
	fail "with no chmod reachable the sweep FAILS" "rc=0
${OUT}"
fi
expect_line "FATAL no chmod on PATH" "it says why it could not fix what it found"
expect_line "CANNOT be fixed" "it does not claim to have fixed anything"
chmod -R u+w "${WS_NC}"

# -----------------------------------------------------------------------------
echo
echo "=== summary"
echo "  passed: ${PASS}"
echo "  failed: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
	echo
	echo "RESULT: FAILED (${FAIL} of $((PASS + FAIL)))"
	exit 1
fi
echo
echo "RESULT: PASSED (${PASS}/${PASS})"
