#!/usr/bin/env bash
# P7.1 smoke test: assert that the user-facing ``ct`` subcommands
# introduced for the book sweep actually exist and respond to ``--help``.
# The point of this test is documentation lock-step: the book will
# replace direct ``ct-mcr`` / ``ct_gfx_player`` invocations with the
# ``ct`` wrappers added in P7.1, so each wrapper must always be
# discoverable from ``ct --help`` and produce a non-empty help
# message of its own.
#
# These tests are deliberately self-contained: they do not require any
# trace files, recorder binaries, or network access. They only verify
# the dispatch surface — the subcommand is wired into the confutils
# parser, the help text is non-empty, and the documented flags are
# present in it. Side-effects (actually running ``ct-mcr extract-gfx``
# etc.) are exercised separately by the full e2e suite.

set -u

CT=${CT_BIN:-src/build-debug/bin/ct}
if [ ! -f "$CT" ]; then
	# SKIP-discipline: when the ct binary has not been built yet,
	# exit successfully without spuriously failing CI. Real CI runs
	# this test only after a successful build.
	echo "SKIP: ct binary not found at $CT"
	exit 0
fi

PASS=0
FAIL=0

run_help() {
	# Run "ct <args> --help" and assert exit code 0 and that the captured
	# output mentions every expected keyword.
	local name="$1"
	shift
	local args=()
	local expectations=()
	local in_expect=0
	for tok in "$@"; do
		if [ "$tok" = "--" ]; then
			in_expect=1
			continue
		fi
		if [ "$in_expect" -eq 0 ]; then
			args+=("$tok")
		else
			expectations+=("$tok")
		fi
	done

	local output
	if ! output=$("$CT" "${args[@]}" --help 2>&1); then
		echo "FAIL: $name (--help exited non-zero)"
		FAIL=$((FAIL + 1))
		return
	fi

	for needle in "${expectations[@]}"; do
		if ! printf '%s' "$output" | grep -qi -- "$needle"; then
			echo "FAIL: $name (expected to find '$needle' in --help output)"
			printf '%s\n' "$output" | head -20
			FAIL=$((FAIL + 1))
			return
		fi
	done

	echo "PASS: $name"
	PASS=$((PASS + 1))
}

# (1) ct record --help should advertise the new --use-interpose flag.
run_help "ct record exposes --use-interpose" \
	record -- "use-interpose"

# (2) ct trace --help should advertise both sub-subcommands.
run_help "ct trace exposes extract-gfx + export" \
	trace -- "extract-gfx" "export"

# (3) ct trace extract-gfx --help should mention the output dir.
run_help "ct trace extract-gfx help" \
	trace extract-gfx -- "output-dir"

# (4) ct trace export --help should mention --portable and -o.
run_help "ct trace export help" \
	trace export -- "portable" "output"

# (5) ct gfx-replay --help should mention gfx-stream + http + port.
run_help "ct gfx-replay help" \
	gfx-replay -- "gfx-stream" "http" "port"

# (6) ct doctor --help should describe the language argument.
run_help "ct doctor help" \
	doctor -- "doctorLanguage"

# (7) ct doctor python runs the probe and prints PASS or FAIL even when
# the recorder is not installed. It must not crash.
echo ""
echo "=== ct doctor python (probe behavior) ==="
DOCTOR_OUTPUT=$("$CT" doctor python 2>&1 || true)
if printf '%s' "$DOCTOR_OUTPUT" | grep -qE '^\s*(PASS|FAIL)\s+python'; then
	echo "PASS: ct doctor python reports PASS or FAIL for the python probe"
	PASS=$((PASS + 1))
else
	echo "FAIL: ct doctor python produced unexpected output"
	printf '%s\n' "$DOCTOR_OUTPUT" | head -20
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
