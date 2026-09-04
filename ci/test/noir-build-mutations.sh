#!/usr/bin/env bash
#
# noir-build-mutations.sh — every check in the Noir Build/Run path, killed on
# purpose, one at a time.
#
# WHAT THIS IS FOR
#
# `test_noir_build_marshalling.nim`, `test_noir_build_producer.nim` and
# `test_wasm_worker.nim` are green. Green over what? A suite that passes is
# evidence only if it would FAIL for the defect it claims to cover, and the
# assertions here are exactly the kind that can silently stop meaning anything:
# field-for-field mappings, where a wrong field name still yields a row and a
# wrong severity still yields a diagnostic.
#
# So each arm below breaks ONE line of the product and requires a NAMED test
# case to go red. Not "the suite failed" — a specific case, by title. A break
# that is only caught by some other check is reported as a MISS, because it
# means the check that was supposed to cover it does not.
#
# THE TRAP THIS SCRIPT IS BUILT AGAINST, and it is the one the last campaign
# hit: an arm whose PREMISE has moved. When the line an arm patches is edited,
# `sed` matches nothing, the file is unchanged, the suite passes, and the arm
# reports "could not be measured" forever while looking like coverage. So every
# arm asserts that the file actually CHANGED before it runs anything, and a
# no-op patch is a HARD FAILURE, not a skip.
#
# EVERY MATCH BELOW IS A HERE-STRING, NEVER `printf ... | grep -q`, AND THAT IS
# A CORRECTNESS FIX RATHER THAN A STYLE ONE.
#
# `grep -q` exits the instant it matches. If the haystack is bigger than a pipe
# buffer — measured at exactly 64 KiB, see ci/test/grep-q-pipefail-gate.sh — the
# producer is still writing, takes EPIPE, and dies of SIGPIPE; with the
# `set -o pipefail` below the pipeline adopts that failure and reports 141.
# A SUCCESSFUL MATCH IS THEREFORE RETURNED AS "NO MATCH".
#
# In this file that has teeth in both directions:
#
#   * The BASELINE gate on line ~94 asks "is this suite already red?". When the
#     output crosses 64 KiB the gate answers "not red", the `COMPILE-FAILED`
#     arm below it does not match either, and control falls into the `else`
#     branch, which counts `[OK]` lines with `grep -c` — a counter reads to
#     EOF, so THAT one works, finds the green cases a partly-red suite still
#     has, and prints "N case(s) green". A red baseline reported as a green
#     one, in the one check without which all 27 arms below are vacuous.
#
#   * Inside an arm the same pairing fails the other way: line ~162 was
#     `if ! ... | grep -q '\[FAILED\]'`, so EPIPE reads as "no red case" and the
#     arm reports SURVIVED against a mutation it actually killed. Line ~168 was
#     worse still — `grep -F '[FAILED]' | grep -qF "$expected"` gives the MIDDLE
#     grep the SIGPIPE, and the arm reports MISS.
#
# HOW BIG ARE THESE SUITES, ACTUALLY. Measured, because the answer decides
# whether the paragraph above describes something happening today or something
# waiting to: `test_noir_build_marshalling` prints 1,537 bytes green and 2,764
# bytes with two cases genuinely red (product mutated: `of "warning":
# ndsWarning` -> `ndsError`). That is two orders of magnitude below the
# threshold, so THIS SITE WAS LATENT, NOT LIVE, and nobody should read the
# rewrite as a fix for a failure that had already happened here.
#
# It is still the site worth fixing first, for the reason that has nothing to
# do with likelihood: of the ~130 in this repository this is the one whose
# EPIPE answer is the GREEN one, in the gate that licenses everything below it.
# The suites grow; 56 test cases across the three of them are 4 KB of output
# now, and a failure dump on a collection compare is not a bounded thing. The
# day it crosses 64 KiB this script starts reporting 27 arms of coverage over a
# broken baseline and says nothing at all. Demonstrated in that state against a
# stub `nim` whose suite fails its second case and then prints 1.6 MB: before
# the fix, three red suites reported "6 case(s) green" and the arms ran; after,
# all three report "is already red" and the script stops.
#
# A here-string has no pipe to break, so there is no EPIPE and no pipefail
# interaction. Where two greps have to compose, the intermediate result is
# captured into a variable first — a pipe whose consumer is `grep -q` is the
# defect, wherever the producer came from.
#
# Usage:  bash ci/test/noir-build-mutations.sh
# Exit:   0 every arm killed its own case, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

command -v nim >/dev/null 2>&1 || {
	echo "noir-build-mutations.sh: no 'nim' on PATH." >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-build-mutations"
mkdir -p "${cache}"

MARSHALLING="src/frontend/viewmodel/tests/unit/test_noir_build_marshalling.nim"
PRODUCER_TEST="src/frontend/viewmodel/tests/unit/test_noir_build_producer.nim"
WORKER_TEST="src/frontend/viewmodel/tests/unit/test_wasm_worker.nim"

NOIR_BUILD="src/frontend/viewmodel/platform/noir_build.nim"
PRODUCER="src/frontend/viewmodel/viewmodels/noir_build_producer.nim"
WASM_WORKER="src/frontend/viewmodel/platform/wasm_worker.nim"

failures=0
arms=0
killed=0

ok() { echo "  [OK]     $*"; }
bad() {
	echo "  [FAILED] $*"
	failures=$((failures + 1))
}

run_suite() {
	# Compile and run one suite, printing everything. Kept as two steps
	# (`nim c` then the binary) so a COMPILE failure is distinguishable from a
	# red assertion — a mutation that does not compile has not measured the
	# check either, and must be reported as its own kind of miss.
	local suite="$1" label="$2"
	local out="${cache}/${label}"
	if ! nim c --hints:off --warnings:off --path:src/frontend/viewmodel \
		--nimcache:"${cache}/nimcache-${label}" -o:"${out}" "${suite}" \
		>"${cache}/${label}.compile" 2>&1; then
		echo "COMPILE-FAILED"
		return
	fi
	"${out}" >"${cache}/${label}.run" 2>&1
	cat "${cache}/${label}.run"
}

# ---------------------------------------------------------------------------
# Baseline: every suite green before anything is broken.
#
# Without this the whole script is vacuous in the most embarrassing way — a
# suite that was already red would make every arm "pass".
# ---------------------------------------------------------------------------
echo "=== Noir Build/Run mutation arms ==="
echo
echo "Baseline: the three suites are green before anything is broken"

baseline_ok=1
for pair in "${MARSHALLING}:marshalling" "${PRODUCER_TEST}:producer" "${WORKER_TEST}:worker"; do
	suite="${pair%%:*}"
	label="${pair##*:}"
	output="$(run_suite "${suite}" "baseline-${label}")"
	if grep -q '\[FAILED\]' <<<"${output}"; then
		bad "baseline: ${suite} is already red"
		baseline_ok=0
	elif grep -q 'COMPILE-FAILED' <<<"${output}"; then
		bad "baseline: ${suite} does not compile"
		baseline_ok=0
	else
		ok_count="$(grep -c '\[OK\]' <<<"${output}" || true)"
		if [ "${ok_count}" -lt 5 ]; then
			bad "baseline: ${suite} reported ${ok_count} case(s), which is implausibly few"
			baseline_ok=0
		else
			ok "baseline: ${suite} — ${ok_count} case(s) green"
		fi
	fi
done

if [ "${baseline_ok}" -ne 1 ]; then
	echo
	echo "RESULT: FAILED — the baseline is not green, so no arm below measures anything"
	exit 1
fi

# ---------------------------------------------------------------------------
# One arm.
#
#   arm <name> <file> <suite> <label> <expected-red-case-title> <sed-expr>
#
# `<expected-red-case-title>` is a FIXED STRING matched against the `[FAILED]`
# line, so an arm names the case it covers and a kill by any other case is
# reported as a MISS.
# ---------------------------------------------------------------------------
arm() {
	local name="$1" file="$2" suite="$3" label="$4" expected="$5" expr="$6"
	arms=$((arms + 1))
	echo
	echo "Arm ${arms}: ${name}"

	local base backup
	base="$(basename "${file}")"
	backup="${cache}/${base}.${arms}.orig"
	cp "${file}" "${backup}"

	perl -0pi -e "${expr}" "${file}"

	# THE PREMISE CHECK. An arm whose patch matched nothing is not a skip and
	# must never be reported as one: it is an arm that has silently stopped
	# measuring, and that is the failure mode this whole script guards.
	if cmp -s "${file}" "${backup}"; then
		cp "${backup}" "${file}"
		bad "arm ${arms} (${name}): the patch changed NOTHING — its premise has moved."
		echo "         The line it targets in ${file} no longer exists, so this arm"
		echo "         has been measuring nothing. Re-point it or delete it; do not"
		echo "         leave it here looking like coverage."
		return
	fi

	local output
	output="$(run_suite "${suite}" "arm-${arms}")"
	cp "${backup}" "${file}"

	if grep -q 'COMPILE-FAILED' <<<"${output}"; then
		bad "arm ${arms} (${name}): the mutated product does not compile, so the"
		echo "         check was not exercised. A mutation must produce a WRONG"
		echo "         program, not an invalid one."
		return
	fi

	# The red cases are extracted ONCE, into a variable. Composing this as
	# `grep -F '[FAILED]' <<<"$output" | grep -qF "$expected"` would put the
	# defect back: the `grep -q` still terminates a pipe early, and the
	# upstream `grep -F` still dies of SIGPIPE.
	local red
	red="$(grep -F '[FAILED]' <<<"${output}" || true)"

	if [ -z "${red}" ]; then
		bad "arm ${arms} (${name}): SURVIVED — the suite is green over a broken product."
		echo "         Nothing covers: ${expected}"
		return
	fi

	if grep -qF "${expected}" <<<"${red}"; then
		local also
		also="$(grep -c . <<<"${red}" || true)"
		killed=$((killed + 1))
		ok "arm ${arms} (${name}): reddened its own case — ${expected} (${also} case(s) red in total)"
	else
		bad "arm ${arms} (${name}): MISS — something went red, but not the case this arm covers."
		echo "         expected red: ${expected}"
		echo "         actually red:"
		while IFS= read -r line; do echo "           ${line}"; done <<<"${red}"
	fi
}

# ---------------------------------------------------------------------------
# The marshaller and the decoder
# ---------------------------------------------------------------------------

arm "a warning is decoded as an error" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"severities are read, not assumed" \
	's/of "warning": ndsWarning/of "warning": ndsError/'

arm "the request key is spelled packageDir instead of package_dir" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"the bundled template marshals into the shape" \
	's/"package_dir": packageDir/"packageDir": packageDir/'

arm "the package dir stops being a path prefix" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"the package dir is a prefix, not a root" \
	's/  else: packageDir & "\/" & relative/  else: relative/'

arm "Run asks for the same mode Build does" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"build and run ask for different modes" \
	's/nbmDebug = "debug"/nbmDebug = "program"/'

arm "end_line is read from a camelCase key" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"a compile error is decoded field for field" \
	's/getIntOr\(node, "end_line"\)/getIntOr(node, "endLine")/'

arm "the secondary labels are dropped" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"a compile error is decoded field for field" \
	's/getStrSeq\(node, "secondary_messages"\)/newSeq[string]()/'

arm "anything that parses as JSON counts as a VfsResponse" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"something that is not a VfsResponse is a THIRD outcome" \
	's/if parsed\.isNil or parsed\.kind != JObject or not parsed\.hasKey\("ok"\):/if parsed.isNil:/'

arm "a refusal position is inferred from the line instead of the manifest" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"a missing manifest names a file and no line" \
	's/  response\.manifest\.len > 0\n/  response.line > 0\n/'

arm "calls stop being counted in a trace" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"a real trace is counted by tag" \
	's/      elif event\.hasKey\("Call"\): inc result\.calls\n//'

arm "a trace with no steps is not called trivial" \
	"${NOIR_BUILD}" "${MARSHALLING}" marshalling \
	"ONE-EVENT-ZERO-STEPS is reported as trivial" \
	's/not summary\.decoded or summary\.events <= 1 or summary\.steps == 0/not summary.decoded/'

arm "the template ships an empty Prover.toml" \
	"src/frontend/viewmodel/platform/noir_template.nim" "${MARSHALLING}" marshalling \
	"the bundled template ships the inputs a bin package needs" \
	's/        content: """x = "1"\ny = "2"\n"""\)/        content: "")/'

# ---------------------------------------------------------------------------
# The producer
# ---------------------------------------------------------------------------

arm "a diagnostic keeps the compiler's path spelling" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a compile error paints a row, a problem and an error, all located" \
	's/    return producer\.projectRoot & "\/" & vfsPath\[prefix\.len \.\. \^1\]/    return vfsPath/'

arm "a warning is coloured as an error in the pane" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"severities reach the pane unflattened" \
	's/  of ndsWarning: blsWarning/  of ndsWarning: blsError/'

arm "the less-than sign reaches innerHTML unescaped" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a diagnostic quoting the user's source cannot inject markup" \
	"s/    of '<': result.add \"&lt;\"/    of '<': result.add ch/"

arm "an undecodable compile response is reported as a success" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"an undecodable answer is a FAULT" \
	's/    return npvFaulted\n\n  # Warnings are painted/    return npvSucceeded\n\n  # Warnings are painted/'

# The backticks in the pattern below are LITERAL: they are part of the Nim
# source comment (`` # `process.nim` ``) that this patch has to match, not a
# command substitution that lost its double quotes.
# shellcheck disable=SC2016
arm "a stopped run is reported as a failure" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a STOP is not a failure" \
	's/  if exit\.signalled:\n    # `process\.nim`/  if false:\n    # `process.nim`/'

arm "the trace phase clears the pane too" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a trace phase does not wipe the compile's warnings" \
	's/  if phase == nbpCompile:\n    # Only the first phase/  if true:\n    # Only the first phase/'

arm "a successful compile's warnings are skipped" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a successful compile still reports its warnings" \
	's/  for warning in response\.warnings:\n    producer\.paintDiagnostic\(warning\)/  for warning in response.diagnostics:\n    producer.paintDiagnostic(warning)/'

arm "a resolve refusal paints no row" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a resolve refusal paints a row even though it has no diagnostics" \
	's/  if hasRefusalPosition\(response\):\n    let problem = producer\.manifestProblem/  if false:\n    let problem = producer.manifestProblem/'

arm "a second exit settles the phase again" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"one exit settles one phase, however many arrive" \
	's/  if producer\.settled:\n    return producer\.lastVerdict\n  producer\.settled = true\n\n  if exit\.signalled:/  if false:\n    return producer.lastVerdict\n  producer.settled = true\n\n  if exit.signalled:/'

arm "a trace with no steps is celebrated" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"ONE-EVENT-ZERO-STEPS is a fault, not a success" \
	's/    elif isTrivialTrace\(summary\):/    elif false:/'

arm "a run that never started is reported as one that failed" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"a refusal is not an exit" \
	's/  producer\.settled = true\n  producer\.note\(message\)/  producer.note(message)/'

arm "a compiler bug loses its label" \
	"${PRODUCER}" "${PRODUCER_TEST}" producer \
	"every NoirDiagnosticSeverity maps, and bug and unknown say so" \
	's/    result\.add "\[compiler bug\] "/    result.add ""/'

# ---------------------------------------------------------------------------
# The protocol
# ---------------------------------------------------------------------------

arm "a start caller loses the worker's failure text" \
	"${WASM_WORKER}" "${WORKER_TEST}" worker \
	"a failed message reaches a START caller, on stderr" \
	's/  if failure\.len > 0 and run\.settle\.isNil and not run\.onOutput\.isNil:\n    run\.onOutput\(ProcessOutputChunk\(stream: psStderr, text: failure\)\)\n//'

# ---------------------------------------------------------------------------
echo
echo "Arms: ${arms}   killed their own case: ${killed}   failures: ${failures}"

# NON-VACUITY. A run that measured nothing is not a pass, and a `for` loop over
# an empty arm list would report zero failures and exit 0.
if [ "${arms}" -lt 20 ]; then
	echo "only ${arms} arm(s) ran; this file declares more than that" >&2
	failures=$((failures + 1))
fi
if [ "${killed}" -ne "${arms}" ]; then
	echo "${arms} arm(s) ran and ${killed} killed their own case" >&2
fi

if [ "${failures}" -eq 0 ]; then
	echo
	echo "RESULT: OK — ${arms} arm(s), each reddening the case that covers it"
	exit 0
fi
echo
echo "RESULT: FAILED — ${failures} problem(s)"
exit 1
