#!/usr/bin/env bash
# =============================================================================
# The conformance-vector walker refuses a WRONG pin (CTC-3a's negative control).
#
# The `ct-test-certificates` lane walks the test-certificate standard's vectors
# at the revision `src/ct_test/certificate_vectors.pin` names, extracted from
# the `test-certificates-spec` sibling's object store. A green lane proves the
# walker agrees with the vectors at THAT revision; it does not prove that the
# pin is what the walk was bound to. This check does, on every run, with the
# walker the lane already built:
#
#   1. control: the committed pin walks green (the harness itself works);
#   2. an earlier, real revision of the standard (the previous pin) is refused
#      -- the walker no longer matches those vectors, and the run says so;
#   3. a well-formed revision the sibling does not have is refused, naming the
#      revision and the fetch remedy, rather than skipped.
#
# The walker reads the pin file next to its own source (a compile-time path),
# so each case rewrites `src/ct_test/certificate_vectors.pin` in this checkout
# and the original is restored on every exit path; the check ends by asserting
# the file is byte-identical to what it found.
#
# Usage: bash ci/test/certificate-vectors-wrong-pin.sh [<walker binary>]
#        (or: just test-certificate-vectors-wrong-pin [<walker binary>])
# The default walker is the one `just test-ct-test-certificates` builds under
# $CT_NIM_CACHE_ROOT (ci/lib/run-nim-test-lane.sh's layout); run the lane first.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_FILE="$REPO_ROOT/src/ct_test/certificate_vectors.pin"

# The pin the lane walked before 9ebbcb3 (CTC-3c's): a real revision of the
# standard, present in any full clone of `latest`, whose vectors the current
# walker does not match (it has no `notes/` group, among other differences).
EARLIER_PIN="6f5079337739499c71fa8c44315fad13ebe6bac5"
# Well-formed, and in no repository.
ABSENT_PIN="0123456789abcdef0123456789abcdef01234567"

walker="${1:-}"
if [ -z "$walker" ]; then
	if [ -n "${CT_NIM_CACHE_ROOT:-}" ]; then
		walker="${CT_NIM_CACHE_ROOT}/ct-test-certificates-certificate_vectors_test/certificate_vectors_test"
	else
		echo "certificate-vectors-wrong-pin: name the walker binary, or set" \
			"CT_NIM_CACHE_ROOT to the root the lane built it under" >&2
		exit 2
	fi
fi
if [ ! -x "$walker" ]; then
	echo "certificate-vectors-wrong-pin: no walker at '$walker';" \
		'run just test-ct-test-certificates first' >&2
	exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ct-vectors-wrong-pin.XXXXXX")"
cp -p "$PIN_FILE" "$WORK/pin.orig"
restore() {
	cp -p "$WORK/pin.orig" "$PIN_FILE"
	rm -rf "$WORK"
}
trap restore EXIT

COMMITTED_PIN="$(tr -d '\n' <"$WORK/pin.orig")"
failures=0

# run_walker <pin> <log>: the walker's exit status, with the pin in place.
run_walker() {
	printf '%s\n' "$1" >"$PIN_FILE"
	set +e
	(cd "$REPO_ROOT" && "$walker") >"$2" 2>&1
	local status=$?
	set -e
	return "$status"
}

expect_in_log() {
	local log="$1" text="$2" label="$3"
	if grep -qF -- "$text" "$log"; then
		echo "  ok: $label"
	else
		echo "  FAIL: $label -- the walker's output does not contain '$text'" >&2
		failures=$((failures + 1))
	fi
}

echo "control: the committed pin ($COMMITTED_PIN) walks green"
if run_walker "$COMMITTED_PIN" "$WORK/control.log"; then
	echo "  ok: exit 0"
	expect_in_log "$WORK/control.log" "conformance cases walked at $COMMITTED_PIN" \
		"the walk names the committed pin"
else
	echo "  FAIL: the committed pin did not walk green; nothing below would" \
		"mean anything. The walker said:" >&2
	tail -40 "$WORK/control.log" >&2
	exit 1
fi

echo "an earlier revision of the standard ($EARLIER_PIN) is refused"
if run_walker "$EARLIER_PIN" "$WORK/earlier.log"; then
	echo "  FAIL: the walker exited 0 at a pin whose vectors it does not match" >&2
	failures=$((failures + 1))
else
	echo "  ok: exit non-zero"
	expect_in_log "$WORK/earlier.log" "walking test-certificates-spec vectors at the pin $EARLIER_PIN" \
		"the failing walk was bound to that pin"
	expect_in_log "$WORK/earlier.log" "[FAILED]" "a named case failed"
fi

echo "a revision the sibling does not have ($ABSENT_PIN) is refused, not skipped"
if run_walker "$ABSENT_PIN" "$WORK/absent.log"; then
	echo "  FAIL: the walker exited 0 at a pin no repository contains" >&2
	failures=$((failures + 1))
else
	echo "  ok: exit non-zero"
	expect_in_log "$WORK/absent.log" "$ABSENT_PIN" "the refusal names the pin"
	expect_in_log "$WORK/absent.log" "fetch" "and the fetch remedy"
fi

cp -p "$WORK/pin.orig" "$PIN_FILE"
if ! cmp -s "$WORK/pin.orig" "$PIN_FILE"; then
	echo "FAIL: the pin file was not restored" >&2
	exit 1
fi
echo "the pin file is restored"

if [ "$failures" -gt 0 ]; then
	echo "certificate-vectors-wrong-pin: $failures check(s) failed" >&2
	exit 1
fi
echo "certificate-vectors-wrong-pin: a wrong pin turns the walk red (3 cases)"
