#!/usr/bin/env bash
# =============================================================================
# Unit gate for the launcher <-> recorder driver's DECODED-TRACE reasoning.
#
#   bash ci/test/launcher-recorder-decode-test.sh
#   just test-launcher-recorder-decode
#
# WHAT THIS IS FOR
#   `ci/test/launcher-recorder-e2e.sh` needs a launcher binary, a built desktop
#   core, a recorder sibling and `ct-print` before it can make its first
#   assertion, and by design it has no skip path.  That is right for the gate
#   and wrong for the parts of it that are pure functions of a `ct-print`
#   document: the trace-shape discrimination, the empty-recording guard, the
#   named-content assertions and the routing-key check.  Those live in
#   ci/lib/launcher-recorder-decode.sh and in two named functions of the
#   driver, and this file drives THEM -- the shipped code, extracted from the
#   shipped files, never a copy -- against REAL `ct-print --full` output.
#
# WHERE THE DOCUMENTS COME FROM
#   codetracer-trace-format-nim's own checked-in goldens, which are what its
#   `ct-print` prints for each of the two trace families this gate records:
#
#     tests/goldens/ct_print_full.json          v4 (python/ruby/js/beam)
#     tests/goldens/native_replay_hello.full.json   native MCR bundle
#
#   Not hand-written stand-ins: the point of several assertions below is
#   exactly what the real decoder really emits (`counts.steps: 0` on a perfectly
#   good native recording, an always-empty `functions` array), and a fixture
#   written here could be made to say anything.  A missing sibling is a hard
#   failure with a remedy, the same rule the gate itself follows.
#
# THE FOUR PROPERTIES IT PINS
#   1. A native MCR document is EMPTY-GUARDED, and by its own count keys.  The
#      v4 predicate reports a correct native recording as "an empty recording"
#      -- asserted here against the real golden, because that false positive is
#      the reason the guard had to become shape-aware, and a future
#      simplification back to one predicate must fail this file.
#   2. The native guard is not weaker.  Zeroing either of its two liveness
#      counts, or dropping one, is rejected -- and `counts.io_events`, which is
#      0 on a correct interpose recording, is deliberately not one of them.
#   3. `expect.function` is answered from the `functions` ARRAY.  The old
#      whole-document grep could be satisfied by `metadata.program`; that exact
#      string is asserted here to be accepted by the grep and rejected by the
#      array lookup.
#   4. `noext` is a routing key the driver can express, and only for a sample
#      that really has no extension.
#
#   Plus: every recorder contract fixture checked out beside this repo must
#   still satisfy `validate_fixture`, so the schema additions cannot have
#   invalidated a green edge's fixture.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
DRIVER="$ROOT_DIR/ci/test/launcher-recorder-e2e.sh"
LIB="$ROOT_DIR/ci/lib/launcher-recorder-decode.sh"

PASSED=0
FAILED=0
FAILURES=""

t_pass() {
	PASSED=$((PASSED + 1))
	echo "  ok   $1"
}
t_fail() {
	FAILED=$((FAILED + 1))
	FAILURES="$FAILURES"$'\n'"  - $1"
	echo "  FAIL $1"
}
die() {
	echo "error: $*" >&2
	exit 1
}
check() { # <description> <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then t_pass "$desc"; else t_fail "$desc"; fi
}
check_not() { # <description> <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then t_fail "$desc"; else t_pass "$desc"; fi
}

TMP="$(mktemp -d -t ct-lrd-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The real decoder output.
# ---------------------------------------------------------------------------
GOLDENS="$WS_ROOT/codetracer-trace-format-nim/tests/goldens"
V4_DOC="$GOLDENS/ct_print_full.json"
NATIVE_DOC="$GOLDENS/native_replay_hello.full.json"
for f in "$V4_DOC" "$NATIVE_DOC"; do
	[[ -f $f ]] || die "missing $f
  This gate asserts against codetracer-trace-format-nim's real ct-print
  goldens, not against documents written here -- several of its assertions are
  about what the decoder actually emits.  Clone the sibling next to this repo.
  Deliberately NOT a skip."
done

[[ -f $LIB ]] || die "missing $LIB"
# shellcheck source=../lib/launcher-recorder-decode.sh
# shellcheck disable=SC1091  # resolved at run time from $ROOT_DIR
source "$LIB"

# ---------------------------------------------------------------------------
# Extract shipped shell functions from the driver, so the code under test is
# the code that runs in CI.  Same idiom as
# ci/test/launcher-recorder-e2e-workflow-test.sh's `extract_plan_script`.
# ---------------------------------------------------------------------------
extract_funcs() { # <source-file> <fn>...
	local src="$1" fn out
	shift
	out="$TMP/extracted.sh"
	: >"$out"
	for fn in "$@"; do
		awk -v fn="$fn" '
			index($0, fn "() {") == 1 {
				print
				# One-line form: `name() { ...; }`.
				if ($0 ~ /}[ 	]*$/) { found = 1; next }
				inside = 1
				next
			}
			inside { print }
			inside && $0 == "}" { inside = 0; found = 1 }
			END { if (!found) exit 3 }
		' "$src" >>"$out" || return 3
	done
	printf '%s' "$out"
}

EXTRACTED="$(extract_funcs "$DRIVER" \
	assert_declared_extension flatten_fixture fx_key_re fx_get fx_list \
	fx_scenario_indices fixture_error validate_fixture)" ||
	die "could not extract a function from $DRIVER -- has one been renamed?
  This gate deliberately drives the SHIPPED functions rather than a copy, so a
  rename has to be followed here.  It is not a skip."

# The driver globals those functions reach for.  `ok`/`bad` record outcomes
# instead of printing into this file's own tally, and `die` keeps the driver's
# real semantics -- it aborts -- because `fixture_error` is what makes an
# incomplete fixture a hard failure and a `return`ing stub would let
# validate_fixture run on past its own rejection and report success.
# validate_fixture is therefore called in a SUBSHELL below, so the abort ends
# the validation rather than this test.
OK_COUNT=0
BAD_COUNT=0
ok() { OK_COUNT=$((OK_COUNT + 1)); }
bad() { BAD_COUNT=$((BAD_COUNT + 1)); }
assert_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_true() {
	local d="$1"
	shift
	if "$@"; then ok "$d"; else bad "$d"; fi
}

# ---------------------------------------------------------------------------
echo
echo "1. trace-shape discrimination, against the real decoder output"
# ---------------------------------------------------------------------------
shape_v4="$(lrd_trace_shape "$V4_DOC")"
shape_native="$(lrd_trace_shape "$NATIVE_DOC")"
if [[ $shape_v4 == "v4" ]]; then
	t_pass "the v4 golden is classified 'v4'"
else
	t_fail "the v4 golden was classified '$shape_v4'"
fi
if [[ $shape_native == "native-mcr" ]]; then
	t_pass "the native golden is classified 'native-mcr'"
else
	t_fail "the native golden was classified '$shape_native'"
fi

# M1: the two markers must AGREE.  A document carrying only one of them means
# the decoder's output shape moved, and guessing which branch to take would be
# reasoning about the wrong count keys.
sed 's/"recorder": "native-mcr"/"recorder": "native-mcr-x"/' "$NATIVE_DOC" >"$TMP/m1.json"
if [[ $(lrd_trace_shape "$TMP/m1.json") == "unknown" ]]; then
	t_pass "M1: a native document whose metadata.recorder moved is 'unknown', not silently v4"
else
	t_fail "M1: a half-native document was classified '$(lrd_trace_shape "$TMP/m1.json")'"
fi

# ---------------------------------------------------------------------------
echo
echo "2. the empty-recording guard is shape-aware, and the native arm is not weaker"
# ---------------------------------------------------------------------------
check "the v4 golden is not an empty recording (v4 predicate)" \
	lrd_v4_empty_reason "$V4_DOC"

# THE DEFECT THAT MADE THIS NECESSARY, asserted against the real decoder:
# native_decoder.nim emits counts.steps and counts.calls as hard-coded 0
# because an MCR container has no step or call table, so the v4 predicate
# rejects every correct native recording.
check_not "the v4 predicate FALSELY reports the real native golden as empty (the defect)" \
	lrd_v4_empty_reason "$NATIVE_DOC"
check "the native predicate accepts the same document" \
	lrd_native_empty_reason "$NATIVE_DOC"

# M2/M4: each of the two native liveness counts is load-bearing.
sed 's/"thread_events": 3/"thread_events": 0/' "$NATIVE_DOC" >"$TMP/m2.json"
check_not "M2: counts.thread_events 0 is an empty recording" \
	lrd_native_empty_reason "$TMP/m2.json"
# counts.io_events is deliberately NOT part of the native predicate.  On a real
# interpose recording it is 0 while the program's writes are per-thread
# `evOsWrite` events -- measured 2026-09-19, see the predicate's own comment.
# Asserted here so that "helpfully" adding it back turns THIS file red instead
# of turning every correct native recording red.
sed 's/"io_events": 1/"io_events": 0/' "$NATIVE_DOC" >"$TMP/m3.json"
check "M3: counts.io_events 0 is NOT emptiness (interpose writes are thread events)" \
	lrd_native_empty_reason "$TMP/m3.json"
sed 's/"thread_streams": 2/"thread_streams": -1/' "$NATIVE_DOC" >"$TMP/m4.json"
check_not "M4: counts.thread_streams -1 (an absent stream) is an empty recording" \
	lrd_native_empty_reason "$TMP/m4.json"

# M5: the native arm is POSITIVE, so a document that dropped the key entirely
# fails instead of passing on "no zero was found" -- which is exactly how the
# v4 arm's -1 hole (audit "Hole B") came about.
grep -v '"thread_events"' "$NATIVE_DOC" >"$TMP/m5.json"
check_not "M5: a document missing counts.thread_events fails rather than passing vacuously" \
	lrd_native_empty_reason "$TMP/m5.json"

# M6: control -- the v4 arm's behaviour is unchanged, so the four green edges
# see the same predicate they passed with.
sed 's/"steps": 10/"steps": 0/' "$V4_DOC" >"$TMP/m6.json"
check_not "M6 (control): the v4 arm still rejects a 0-step v4 document" \
	lrd_v4_empty_reason "$TMP/m6.json"

# ---------------------------------------------------------------------------
echo
echo "3. expect.function is answered from the functions ARRAY, not the whole document"
# ---------------------------------------------------------------------------
check "'main' is in the v4 golden's functions array" \
	lrd_functions_contains "$V4_DOC" main
check "'compute' is in the v4 golden's functions array" \
	lrd_functions_contains "$V4_DOC" compute

# THE LATENT VACUITY, demonstrated on the real golden.  `ct_print_demo` is the
# recorded program's name in `metadata.program` and is NOT a function.  The
# driver's previous assertion was `grep -qF '"ct_print_demo"' <full>`, which
# this document satisfies; the array lookup does not.
if grep -qF '"ct_print_demo"' "$V4_DOC"; then
	t_pass "the old whole-document grep WOULD have accepted 'ct_print_demo' (metadata.program)"
else
	t_fail "the golden no longer contains the quoted metadata.program -- the vacuity demo needs updating"
fi
check_not "the functions-array lookup rejects 'ct_print_demo'" \
	lrd_functions_contains "$V4_DOC" ct_print_demo

# The same hole through a recorded path rather than the program name.
check_not "the functions-array lookup rejects a path component ('<workdir>/main.py')" \
	lrd_functions_contains "$V4_DOC" '<workdir>/main.py'

# On the native shape there is no function table at all, which is why the
# fixture schema forbids `expect.function` there rather than letting it pass by
# accident.
check_not "the native golden's functions array is empty ('main' is absent)" \
	lrd_functions_contains "$NATIVE_DOC" main

# ---------------------------------------------------------------------------
echo
echo "4. expect.event-type is matched as a key/value pair inside the events"
# ---------------------------------------------------------------------------
check "'evOsWrite' is a decoded event type in the native golden" \
	lrd_event_type_present "$NATIVE_DOC" evOsWrite
check "'evSyncLockAcquireBegin' is a decoded event type in the native golden" \
	lrd_event_type_present "$NATIVE_DOC" evSyncLockAcquireBegin
check_not "an event type the trace does not carry is rejected" \
	lrd_event_type_present "$NATIVE_DOC" evNeverRecorded

# M7: the assertion must not be satisfiable by the name appearing in a RECORDED
# PAYLOAD -- the whole reason it is a key/value match and not a bare grep.  Put
# the name in a payload's decoded text and take the real event types away.
sed 's/"text": "hi\\n"/"text": "evOsWrite"/; s/"event_type": "evOsWrite"/"event_type": "evOther"/' \
	"$NATIVE_DOC" >"$TMP/m7.json"
if grep -qF '"evOsWrite"' "$TMP/m7.json"; then
	t_pass "M7: the mutated document still contains the string 'evOsWrite' (in a payload)"
else
	t_fail "M7: the mutation did not produce the string it needs to"
fi
check_not "M7: a name that appears only in a recorded payload is NOT an event type" \
	lrd_event_type_present "$TMP/m7.json" evOsWrite

# ---------------------------------------------------------------------------
echo
echo "4b. recorded stdout is found inside DECODED event payloads"
# ---------------------------------------------------------------------------
# The gate's only proof of hop 1 is finding the ${CODETRACER_COMPONENT_DIR}
# line inside the decoded trace.  On a native recording neither of the driver's
# two older forms finds it, for two separate and measured reasons, and this
# section reproduces both exactly rather than describing them.
#
# (i) `ct-print` only renders a payload's `"text"` when the WHOLE payload is
#     printable, and an `evOsWrite` payload starts with a 16-byte binary header.
COMPONENT_LINE='launcher-recorder-e2e: component-dir=/tmp/staged/codetracer-desktop@0.1.0'
{
	printf '%s' '{'
	printf '\n  "events": [\n    {\n      "payload": {\n        "b64": "'
	# 16 binary header bytes, then the recorded line -- the real evOsWrite shape.
	{
		printf '\x6f\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x6f\x00\x00\x00'
		printf '%s\n' "$COMPONENT_LINE"
	} | base64 -w0 2>/dev/null || true
	printf '"\n      }\n    }\n  ]\n}\n'
} >"$TMP/payload.json"

check_not "a plain-text search does NOT find the line (ct-print emitted no 'text' for it)" \
	grep -qF -- "$COMPONENT_LINE" "$TMP/payload.json"

# (ii) base64 is not substring-preserving at a 16-byte offset (16 mod 3 = 1),
#      so the base64 OF THE LINE does not occur in the base64 of the payload.
NEEDLE_B64="$(printf '%s' "$COMPONENT_LINE" | base64 -w0 2>/dev/null ||
	printf '%s' "$COMPONENT_LINE" | base64 | tr -d '\n')"
check_not "the base64-of-the-needle search does NOT find it either (offset 16, 16 mod 3 = 1)" \
	grep -qF -- "$NEEDLE_B64" "$TMP/payload.json"

check "decoding the payload bytes DOES find the recorded line" \
	lrd_payload_contains "$TMP/payload.json" "$COMPONENT_LINE"

# M7b: the search must be over recorded BYTES, not over the document text, so a
# needle that is nowhere in any payload stays unfound.
check_not "M7b: a line no payload carries is not found" \
	lrd_payload_contains "$TMP/payload.json" "launcher-recorder-e2e: never-printed"

# And it works on the real golden's payloads too ("aGkK" is the recorded "hi").
check "the native golden's recorded 'hi' is found by decoding its payloads" \
	lrd_payload_contains "$NATIVE_DOC" "hi"

# ---------------------------------------------------------------------------
echo
echo "5. the 'noext' routing key, in the driver's own assert_declared_extension"
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$EXTRACTED"

run_ade() { # <declared> <sample> -> echoes ok|bad
	OK_COUNT=0
	BAD_COUNT=0
	assert_declared_extension "s" "$1" "$2"
	if [[ $BAD_COUNT -gt 0 ]]; then printf 'bad\n'; else printf 'ok\n'; fi
}

if [[ $(run_ade ".rb" "/w/cross-repo/samples/launcher_compat_sample.rb") == "ok" ]]; then
	t_pass "a declared '.rb' matching the sample is accepted (control)"
else
	t_fail "a declared '.rb' matching the sample was rejected"
fi
if [[ $(run_ade ".rb" "/w/cross-repo/samples/launcher_compat_sample.py") == "bad" ]]; then
	t_pass "a declared '.rb' on a .py sample is rejected (control)"
else
	t_fail "a mismatched extension was accepted"
fi
if [[ $(run_ade "noext" "/w/cross-repo/samples/launcher_compat_native") == "ok" ]]; then
	t_pass "'noext' is accepted for a sample with no extension"
else
	t_fail "'noext' was rejected for an extension-less sample"
fi

# M8: `noext` means the ABSENCE of an extension.  A sample that has one must
# not be able to claim it, or the fixture would misstate which routing rule the
# scenario exercises -- the very drift assert_declared_extension exists to stop.
if [[ $(run_ade "noext" "/w/cross-repo/samples/launcher_compat_native.out") == "bad" ]]; then
	t_pass "M8: 'noext' is rejected for a sample that does carry an extension"
else
	t_fail "M8: 'noext' accepted a sample with an extension"
fi

# The failing-before, stated as the computation it was: the previous
# implementation compared the declared key against `.${sample##*.}`, and for a
# dot-less path that expands to a dot followed by the WHOLE PATH.
old_form_sample="/w/cross-repo/samples/launcher_compat_native"
old_form=".${old_form_sample##*.}"
if [[ $old_form != "noext" && $old_form == ".$old_form_sample" ]]; then
	t_pass "the previous form yielded '$old_form' for that sample, which no fixture could declare"
else
	t_fail "the previous form's behaviour is not what the noext arm was added for"
fi

# ---------------------------------------------------------------------------
echo
echo "6. validate_fixture's shape rules"
# ---------------------------------------------------------------------------
FIXTURE="<under test>"
FX_DEFAULT_OUT_DIR="."

write_fixture() { # <path> <trace-shape-block> <named-content-block>
	cat >"$1" <<YAML
schema: launcher-compat/v1
recorder:
  repo: r
  lang: l
  binary: b
  version-prefix: "b "
  default-out-dir: .
build:
  sibling-key: k
  artifact: a
discovery:
  method: detect-siblings
scenarios:
  - id: rec
    kind: record
    command: record
    extension: noext
    sample: cross-repo/samples/s
    recorder-flag:
      - -o
    expect:
      exit-code: 0
      trace-glob: "*.ct"
      min-events: 3
$2
$3
      stdout-contains:
        - "x: component-dir=\${CODETRACER_COMPONENT_DIR}"
  - id: neg
    kind: negative-routing
    command: record
    extension: .rs
    sample: cross-repo/samples/u.rs
    expect:
      exit-code: nonzero
      stderr-contains:
        - "no component handles"
  - id: ver
    kind: launcher-version
    expect:
      exit-code: 0
      stdout-matches: "^ct [0-9]+"
  - id: iso
    kind: isolation
    command: record
    extension: noext
    sample: cross-repo/samples/s
    expect:
      exit-code: nonzero
      stderr-contains:
        - "no component handles"
YAML
}

# shellcheck disable=SC2034  # FIXTURE/FLAT/SCENARIO_IDX/FX_DEFAULT_OUT_DIR are
# read by the driver functions sourced from $EXTRACTED, not by this file.
run_validate() { # <fixture-path> -> 0 accepted, non-zero rejected
	FIXTURE="$1"
	FLAT="$TMP/flat.$$"
	flatten_fixture "$1" >"$FLAT" || return 1
	mapfile -t SCENARIO_IDX < <(fx_scenario_indices)
	# The one driver global validate_fixture reads that is not derived from
	# the flattened fixture inside the function itself.
	FX_DEFAULT_OUT_DIR="$(fx_get recorder.default-out-dir)"
	# A SUBSHELL, because the driver's `fixture_error` -> `die` EXITS, which is
	# the semantics under test: an incomplete fixture stops the run before
	# anything is built.  Stubbing `die` to `return` would let validate_fixture
	# carry on past its own rejection and report acceptance.
	(validate_fixture)
}

FN_BLOCK=$'      function:\n        - main'
EV_BLOCK=$'      event-type:\n        - evOsWrite'

write_fixture "$TMP/f-v4-ok.yml" "" "$FN_BLOCK"
check "a v4 fixture (no trace-shape declared) with expect.function is accepted" \
	run_validate "$TMP/f-v4-ok.yml"

write_fixture "$TMP/f-native-ok.yml" "      trace-shape: native-mcr" "$EV_BLOCK"
check "a native-mcr fixture with expect.event-type is accepted" \
	run_validate "$TMP/f-native-ok.yml"

# M9-M12: each rule rejects the fixture it exists for.
write_fixture "$TMP/f-native-fn.yml" "      trace-shape: native-mcr" "$FN_BLOCK"
check_not "M9: a native-mcr fixture declaring expect.function is REJECTED (it is unsatisfiable)" \
	run_validate "$TMP/f-native-fn.yml"

write_fixture "$TMP/f-native-none.yml" "      trace-shape: native-mcr" ""
check_not "M10: a native-mcr fixture declaring neither named-content key is REJECTED" \
	run_validate "$TMP/f-native-none.yml"

write_fixture "$TMP/f-v4-ev.yml" "" "$EV_BLOCK"
check_not "M11: a v4 fixture declaring expect.event-type is REJECTED (v4 events have no event_type)" \
	run_validate "$TMP/f-v4-ev.yml"

write_fixture "$TMP/f-bad-shape.yml" "      trace-shape: ctfs-v9" "$FN_BLOCK"
check_not "M12: an unknown expect.trace-shape is REJECTED rather than defaulted" \
	run_validate "$TMP/f-bad-shape.yml"

# M13: `recorder.version-prefix` used to be optional, which made it the one
# expectation a fixture could switch off by saying nothing.  A recorder that
# does not implement `--version` must now declare that instead of omitting it.
write_fixture "$TMP/f-noversion.yml" "" "$FN_BLOCK"
sed -i '/^  version-prefix: /d' "$TMP/f-noversion.yml"
check_not "M13: a fixture with neither version-prefix nor version-prefix-absent is REJECTED" \
	run_validate "$TMP/f-noversion.yml"
sed 's/^  version-prefix: .*/  version-prefix-absent: "this recorder has no --version"/' \
	"$TMP/f-v4-ok.yml" >"$TMP/f-absent.yml"
check "a fixture that DECLARES the missing --version is accepted" \
	run_validate "$TMP/f-absent.yml"

# ---------------------------------------------------------------------------
echo
echo "7. every recorder fixture beside this repo still validates"
# ---------------------------------------------------------------------------
# The schema additions must not have invalidated a fixture a green edge
# depends on.  This host cannot run those edges, so this is the strongest
# statement available here: their checked-in contracts are still accepted by
# the validator the gate runs first.
found_fixture=0
for d in "$WS_ROOT"/codetracer-*-recorder; do
	[[ -f "$d/cross-repo/launcher-compat.yml" ]] || continue
	found_fixture=1
	check "$(basename "$d")'s contract fixture is accepted by validate_fixture" \
		run_validate "$d/cross-repo/launcher-compat.yml"
done
if [[ $found_fixture -ne 1 ]]; then
	t_fail "no recorder contract fixture was found beside this repo -- this check proved nothing"
fi

# ---------------------------------------------------------------------------
echo
if [[ $((PASSED + FAILED)) -eq 0 ]]; then
	echo "FAIL: no assertions ran -- the harness itself is broken" >&2
	exit 1
fi
echo "assertions: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
if [[ $FAILED -ne 0 ]]; then
	echo "FAILURES:$FAILURES" >&2
	exit 1
fi
echo "PASS"
