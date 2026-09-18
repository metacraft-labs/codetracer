# shellcheck shell=bash
# =============================================================================
# Decoded-trace predicates for the launcher <-> recorder end-to-end gate.
#
# WHY THIS IS A LIBRARY AND NOT PART OF THE DRIVER
#   `ci/test/launcher-recorder-e2e.sh` can only run when a launcher, a built
#   desktop core, a recorder sibling and `ct-print` are all present -- by
#   design, it has no skip path.  The predicates below are pure functions of a
#   `ct-print` document, so keeping them here lets
#   `ci/test/launcher-recorder-decode-test.sh` drive them against REAL
#   `ct-print --full` output (codetracer-trace-format-nim's own goldens) on a
#   host that cannot run the full gate.  The driver sources this file rather
#   than carrying a second copy, so the tested code and the shipped code are
#   the same bytes.
#
# THE TWO DOCUMENT SHAPES, AND WHY THE DRIVER HAS TO KNOW WHICH IT HAS
#   `ct-print --full` emits `pretty(root, indent = 2)` for both of the trace
#   families this gate records, and they do not share a set of count keys:
#
#     v4 (python / ruby / js / beam, and every materialized-trace recorder)
#       counts: paths functions varnames types steps calls values io_events
#       `functions` is a flat array of function NAMES.
#
#     native-mcr (codetracer-native-recorder's MCR bundle, decoded by
#     codetracer-trace-format-nim/src/native_decoder.nim)
#       counts: paths functions varnames types steps calls values io_events
#               thread_events thread_streams
#       `metadata.recorder` is the literal `native-mcr`.
#       `steps`, `calls`, `values`, `functions`, `varnames` and `types` are
#       HARD ZEROES, and honestly so: an MCR bundle is a stream of thread and
#       OS events, and step/call/function structure for a native recording is
#       reconstructed at REPLAY time from the event stream plus DWARF.  The
#       container has no such table to report, so a non-zero number there
#       would be invented rather than measured.
#
#   That is why the emptiness guard is shape-aware instead of the decoder
#   being made to report something it does not have.  The guard's PROPERTY --
#   "this recording describes something" -- is unchanged; only the count keys
#   that carry it differ, and for the native shape they are asserted
#   POSITIVELY (present, numeric, >= 1) rather than by the absence of a zero.
# =============================================================================

# --- document scalars ------------------------------------------------------

# lrd_count <full-document> <count-key>
#   Echo the integer at `counts.<count-key>`, or nothing when the key is
#   absent.  Scoped to the `counts` object: a top-level `"functions": []` and
#   `counts.functions` are different things and only the latter is a number.
lrd_count() {
	awk -v want="$2" '
		$0 == "  \"counts\": {" { inside = 1; next }
		inside && $0 ~ /^  \},?$/ { exit }
		inside {
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/,$/, "", line)
			pos = index(line, ": ")
			if (pos == 0) next
			key = substr(line, 1, pos - 1)
			val = substr(line, pos + 2)
			gsub(/"/, "", key)
			if (key == want) { print val; exit }
		}
	' "$1"
}

# lrd_top_array_items <full-document> <top-level-array-key>
#   Echo the elements of a TOP-LEVEL array, one per line, still JSON-quoted.
#   `pretty(root, indent = 2)` puts a top-level key at two spaces, its
#   elements at four, and renders an empty array inline as `[]` (which yields
#   no lines here).  A nested array with the same key name is not reachable:
#   the opening line must be exactly two spaces, the key and ` [`.
lrd_top_array_items() {
	awk -v key="$2" '
		BEGIN { open = "  \"" key "\": [" }
		!inside && $0 == open { inside = 1; next }
		inside && $0 ~ /^  \],?$/ { exit }
		inside {
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/,$/, "", line)
			print line
		}
	' "$1"
}

# --- shape -----------------------------------------------------------------

# lrd_trace_shape <full-document>
#   Echo `native-mcr`, `v4`, or `unknown`.
#
#   Two independent markers must agree, so a document is never classified on a
#   single string that some recorded payload could contain: `metadata.recorder`
#   is the literal `native-mcr`, AND `counts` carries `thread_streams`, which
#   only native_decoder.nim emits.  A document carrying exactly one of them is
#   `unknown` and the caller must fail: it means the decoder output shape moved
#   and the guard below would be reasoning about the wrong keys.
lrd_trace_shape() {
	local doc="$1" recorder_marker=0 counts_marker=0
	grep -qE '^[[:space:]]*"recorder":[[:space:]]*"native-mcr",?$' "$doc" && recorder_marker=1
	[[ -n $(lrd_count "$doc" thread_streams) ]] && counts_marker=1
	if [[ $recorder_marker -eq 1 && $counts_marker -eq 1 ]]; then
		printf 'native-mcr\n'
	elif [[ $recorder_marker -eq 0 && $counts_marker -eq 0 ]]; then
		printf 'v4\n'
	else
		printf 'unknown\n'
	fi
}

# --- emptiness -------------------------------------------------------------

# lrd_v4_empty_reason <full-document> [<meta-document>]
#   The ORIGINAL guard, unchanged in behaviour: `ct-print` prints an ABSENT
#   stream as -1 rather than 0, so zero OR negative is empty.  Echoes a reason
#   and returns 1 when the decode describes an empty recording.
lrd_v4_empty_reason() {
	local doc="$1" meta="${2:-}"
	if [[ -n $meta ]]; then
		grep -qE '"(steps|calls|events)"[[:space:]]*:[[:space:]]*(0|-[0-9]+)([,}]|$)' "$doc" "$meta" || return 0
	else
		grep -qE '"(steps|calls|events)"[[:space:]]*:[[:space:]]*(0|-[0-9]+)([,}]|$)' "$doc" || return 0
	fi
	printf 'a stream count is zero or absent (steps/calls/events)\n'
	return 1
}

# lrd_native_empty_reason <full-document>
#   The native-shaped equivalent, and deliberately not a weaker one.  The two
#   count keys that carry recorded ACTIVITY in an MCR bundle must each be
#   PRESENT, NUMERIC and >= 1:
#
#     thread_streams  at least one thread was recorded at all
#     thread_events   that thread produced at least one event record
#
#   `counts.io_events` is NOT among them, and that is a measurement rather than
#   an oversight.  On a real interpose-mode recording it is 0: the OS event LOG
#   (`event_log.dat`) is what that count reports, and interpose records the
#   program's writes as per-thread `evOsWrite` events instead.  Measured
#   2026-09-19 with codetracer-native-recorder@698832ce's `ct_cli` recording an
#   extension-less C program that writes two lines to stdout, decoded by
#   codetracer-trace-format-nim@cf132be's ct-print:
#     counts.io_events 0, counts.thread_events 19, counts.thread_streams 1,
#     and the stdout inside an `evOsWrite` thread-event payload.
#   Requiring io_events >= 1 here would reject every correct native recording,
#   which is the same mistake as reading `counts.steps: 0` as emptiness.
#
#   What keeps this from being a weak floor is the same thing that keeps the v4
#   arm from being one: the guard is the generic floor, and the SPECIFIC teeth
#   are the fixture's own `expect.min-events`, `expect.event-type` and
#   `expect.stdout-contains`, which a bundle carrying only a thread start and
#   end cannot satisfy.
#
#   Unlike the v4 arm this is POSITIVE: a document that dropped the keys
#   entirely fails, instead of passing on "no zero was found".
lrd_native_empty_reason() {
	local doc="$1" key value
	for key in thread_streams thread_events; do
		value="$(lrd_count "$doc" "$key")"
		if [[ -z $value ]]; then
			printf 'the decoded document has no counts.%s -- the native decoder output shape changed\n' "$key"
			return 1
		fi
		if [[ ! $value =~ ^-?[0-9]+$ ]]; then
			printf 'counts.%s is "%s", which is not a number\n' "$key" "$value"
			return 1
		fi
		if [[ $value -lt 1 ]]; then
			printf 'counts.%s is %s -- an empty recording\n' "$key" "$value"
			return 1
		fi
	done
	return 0
}

# --- named content ---------------------------------------------------------

# lrd_functions_contains <full-document> <function-name>
#   True when the top-level `functions` array has the name as an ELEMENT.
#
#   This used to be a grep for the quoted name over the WHOLE document, which
#   could be satisfied by `metadata.program`, a `paths[]` entry, a varname, a
#   type name or a printable recorded payload -- so a fixture could go green on
#   a function the trace never recorded.  Scoping it to the array is what makes
#   the assertion mean what its message says.
lrd_functions_contains() {
	local doc="$1" name="$2" item
	while IFS= read -r item; do
		[[ $item == "\"$name\"" ]] && return 0
	done < <(lrd_top_array_items "$doc" functions)
	return 1
}

# lrd_event_type_present <full-document> <event-type-name>
#   True when some decoded event carries `"event_type": "<name>"`.
#
#   The native shape's counterpart to a function name.  Matched as a key/value
#   PAIR, not as a bare string, so -- unlike the function grep it is modelled
#   on -- it cannot be satisfied by the name appearing in metadata, in a path
#   or inside a recorded payload.  `event_type` is emitted by
#   native_decoder.nim's thread-event records and by nothing else.
lrd_event_type_present() {
	grep -qE "^[[:space:]]*\"event_type\":[[:space:]]*\"$2\",?$" "$1"
}

# lrd_payload_contains <full-document> <needle>
#   True when the needle appears inside the RECORDED BYTES of some event
#   payload, after base64-decoding it.
#
#   WHY THE DRIVER NEEDS THIS, and why neither of its two older attempts is
#   enough.  Every `record` scenario must find a recorded stdout line naming
#   ${CODETRACER_COMPONENT_DIR} in the decoded trace -- the gate's only proof
#   of hop 1.  The driver looked for the line as plain text, then for the
#   base64 of the line.  Measured 2026-09-19 against a real native recording,
#   both miss, for two separate reasons:
#
#     * `ct-print`'s payload rendering only emits a `"text"` field when the
#       WHOLE payload is printable ASCII (native_decoder.nim `isPrintable`).
#       An `evOsWrite` payload begins with a 16-byte binary header (fd, length)
#       before the written bytes, so it is rendered as `b64` only.
#     * base64 is not substring-preserving at arbitrary offsets.  That header
#       is 16 bytes and 16 mod 3 = 1, so the text is encoded on a different
#       3-byte boundary than the same text encoded on its own, and the two
#       strings do not share the needle.
#
#   Decoding the payloads and searching the bytes is the assertion that matches
#   the property being claimed -- "the recorder captured this output" -- rather
#   than a particular rendering of it.  It cannot manufacture a pass: the only
#   thing it searches is bytes the recorder wrote into the trace.
lrd_payload_contains() {
	local doc="$1" needle="$2" decoded rc
	decoded="$(mktemp)" || return 1
	# Deliberately not `base64 -d | grep -q`: `grep -q` exits at the first
	# match, the decoder takes SIGPIPE, and under `pipefail` the pipeline then
	# reports 141 for a run that SUCCEEDED.  Decode to a file, then search it.
	grep -oE '"b64": "[A-Za-z0-9+/=]*"' "$doc" |
		sed 's/^"b64": "//; s/"$//' |
		while IFS= read -r chunk; do
			[[ -n $chunk ]] || continue
			printf '%s' "$chunk" | base64 -d 2>/dev/null
			printf '\n'
		done >"$decoded" 2>/dev/null
	if grep -qF -- "$needle" "$decoded"; then rc=0; else rc=1; fi
	rm -f "$decoded"
	return $rc
}
