#!/usr/bin/env bash
# =============================================================================
# Regression test: sourcing detect-siblings.sh must EXPORT
# CODETRACER_RR_BACKEND_PATH when the native-backend sibling is checked out.
#
# Why this test exists
# --------------------
# `src/backend-manager/tests/real_recording_integration.rs` gates 48 RR-based
# integration tests on the native-backend sibling being detected, and its
# failure message instructs the operator to "Run detect-siblings.sh".  That
# instruction was false: detect-siblings.sh only ever set the derived
# `CODETRACER_RR_BACKEND_PRESENT` flag, never `_PATH`.  The only place that
# ever set `_PATH` was one GitHub Actions step, because the dev-shell path
# (`repro.nim`) keyed the variable on a sibling directory named
# `codetracer-rr-backend` — a repository that does not exist and never did in
# this workspace layout (GitHub redirects that slug to
# `codetracer-native-backend`, which is what `projects/codetracer.toml`
# actually declares).  So `just cross-test`, gated on `_PATH` alone, could
# never fire outside Actions.
#
# The property under test is deliberately END-TO-END rather than "the variable
# is non-empty".  The half-configured state that produced the original bug was
# exactly `_PRESENT=1` sitting next to an unset `_PATH`, so a test that merely
# checks a name now resolves would not have caught it.  We assert that the
# variable is set, that it points at something real and identifiable as the
# native-backend checkout, and that the `just test` gate it feeds actually
# opens.
#
# Mocking note (per the workspace policy on justified mocks): case A builds a
# synthetic workspace tree on the real filesystem — real directories, a real
# executable file, the real detect-siblings.sh sourced in a real subshell.
# Nothing is stubbed; the fixture only substitutes a cheap placeholder for the
# multi-crate ct-native-replay build, because the property under test is path
# detection, not anything the binary does.  Case B then re-runs the identical
# assertions against the genuine sibling checkout when one is present, so the
# synthetic layout can never be the only evidence.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DETECT="$REPO_ROOT/scripts/detect-siblings.sh"

failures=0
pass() { printf '  ok   — %s\n' "$1"; }
fail() {
	printf '  FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}
skip() { printf '  SKIP — %s\n' "$1" >&2; }

[ -f "$DETECT" ] || {
	echo "ERROR: detect-siblings.sh not found at $DETECT" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Run detect-siblings.sh against $1 (a codetracer repo root) in a clean
# subshell and echo the resulting values of the two variables we care about.
# Isolating this in a subshell keeps each case from leaking exports into the
# next, and keeps the harness's own environment out of the result.
# ---------------------------------------------------------------------------
probe_detect() {
	local ct_root="$1"
	# shellcheck disable=SC2016  # $1/$2 inside the single-quoted script below
	# are that inner shell's positional args (passed after the `_` argv[0]
	# placeholder); they must NOT expand here.
	env -u CODETRACER_RR_BACKEND_PATH \
		-u CODETRACER_RR_BACKEND_PRESENT \
		-u CODETRACER_REPO_ROOT_PATH \
		-u CT_CODETRACER_NATIVE_BACKEND_SIBLING \
		DETECT_SIBLINGS_QUIET=1 \
		bash -c '
			set -u
			# shellcheck disable=SC1090
			source "$1" "$2" >/dev/null 2>&1
			printf "PATH_VAL=%s\n" "${CODETRACER_RR_BACKEND_PATH:-}"
			printf "PRESENT_VAL=%s\n" "${CODETRACER_RR_BACKEND_PRESENT:-}"
		' _ "$DETECT" "$ct_root"
}

# ---------------------------------------------------------------------------
# The four-part end-to-end property, applied to one detection result.
#   $1 label, $2 PATH_VAL, $3 PRESENT_VAL, $4 expected backend dir (or "" to
#   only require that it be a real directory named codetracer-native-backend)
# ---------------------------------------------------------------------------
assert_backend_path_usable() {
	local label="$1" path_val="$2" present_val="$3" expect_dir="$4"

	# (1) The variable is set at all.  This is the assertion that was red.
	if [ -n "$path_val" ]; then
		pass "$label: CODETRACER_RR_BACKEND_PATH is exported"
	else
		fail "$label: CODETRACER_RR_BACKEND_PATH is empty/unset after sourcing detect-siblings.sh"
		return
	fi

	# (2) It points at something that exists — a name that resolves to nothing
	#     is the defect this whole test guards against.
	if [ -d "$path_val" ]; then
		pass "$label: it points at an existing directory ($path_val)"
	else
		fail "$label: CODETRACER_RR_BACKEND_PATH=$path_val is not a directory"
	fi

	# (3) It is the native-backend checkout, not the retired name.  Guards
	#     against 'fixing' this by resurrecting codetracer-rr-backend.
	if [ "$(basename "$path_val")" = "codetracer-native-backend" ]; then
		pass "$label: it names the codetracer-native-backend sibling"
	else
		fail "$label: expected basename codetracer-native-backend, got '$(basename "$path_val")'"
	fi
	if [ -n "$expect_dir" ] && [ "$path_val" != "$expect_dir" ]; then
		fail "$label: expected exactly $expect_dir, got $path_val"
	fi

	# (4) The gate it feeds actually opens.  This is the literal condition
	#     from the `test` recipe in the justfile; if that expression is ever
	#     rewritten, this test should be updated in lockstep.
	if [ -n "${path_val:-}" ]; then
		pass "$label: the 'just test' cross-test gate opens"
	else
		fail "$label: the 'just test' cross-test gate stays closed"
	fi

	# (5) The two variables answer DIFFERENT questions and must stay
	#     consistent with each other.  _PATH means "the sibling repo is
	#     checked out"; _PRESENT means "its ct-native-replay is built and on
	#     PATH".  A checkout that has not been built yet is a legitimate
	#     state (_PATH set, _PRESENT unset) — check_rr_prerequisites then
	#     passes its detection gate and hard-fails a step later in
	#     find_ct_native_replay with the accurate "build it" reason.
	#
	#     What must NEVER happen is the converse, _PRESENT=1 beside an unset
	#     _PATH: that is the half-configured state the original bug produced,
	#     where detection reported success while the variable every consumer
	#     gates on stayed empty.  That invariant is asserted globally below,
	#     since it has to hold whether or not a sibling exists.
	if [ -x "$path_val/target/debug/ct-native-replay" ]; then
		if [ "$present_val" = "1" ]; then
			pass "$label: backend is built and _PRESENT=1 accompanies _PATH"
		else
			fail "$label: ct-native-replay is built under \$_PATH but _PRESENT='$present_val'"
		fi
	else
		skip "$label: ct-native-replay is not built under $path_val, so the _PRESENT=1 pairing cannot be exercised — _PATH alone is the correct state for an unbuilt checkout, and the prerequisite gate still hard-fails on the missing binary"
	fi
}

# ---------------------------------------------------------------------------
# The invariant that the original bug violated, in whichever direction.
# ---------------------------------------------------------------------------
assert_no_half_configured() {
	local label="$1" path_val="$2" present_val="$3"
	if [ "$present_val" = "1" ] && [ -z "$path_val" ]; then
		fail "$label: CODETRACER_RR_BACKEND_PRESENT=1 with _PATH unset — the half-configured state that hid the original bug"
	else
		pass "$label: no _PRESENT-without-_PATH half-configured state"
	fi
}

# ---------------------------------------------------------------------------
# Case A — synthetic workspace.  Hermetic: runs identically on any host, in
# any CI lane, with no sibling checkout and no network.
# ---------------------------------------------------------------------------
echo "case A: synthetic workspace with a codetracer-native-backend sibling"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/ws/codetracer"
mkdir -p "$TMP/ws/codetracer-native-backend/target/debug"
cat >"$TMP/ws/codetracer-native-backend/target/debug/ct-native-replay" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/ws/codetracer-native-backend/target/debug/ct-native-replay"

eval "$(probe_detect "$TMP/ws/codetracer")"
assert_backend_path_usable "case A" "${PATH_VAL:-}" "${PRESENT_VAL:-}" \
	"$TMP/ws/codetracer-native-backend"
assert_no_half_configured "case A" "${PATH_VAL:-}" "${PRESENT_VAL:-}"

# ---------------------------------------------------------------------------
# Case A-negative — no sibling at all.  The variable must stay UNSET rather
# than be set to a stale or empty-but-present value; `check_rr_prerequisites`
# treats "set and non-empty" as proof the sibling is there, so a spurious
# export here would be worse than no export at all.
# ---------------------------------------------------------------------------
echo "case A-negative: workspace with no native-backend sibling"
mkdir -p "$TMP/bare/codetracer"
mkdir -p "$TMP/bare/codetracer-python-recorder" # a sibling, so the root resolves
eval "$(probe_detect "$TMP/bare/codetracer")"
if [ -z "${PATH_VAL:-}" ]; then
	pass "case A-negative: CODETRACER_RR_BACKEND_PATH stays unset with no sibling"
else
	fail "case A-negative: _PATH=${PATH_VAL} exported despite no native-backend sibling"
fi
assert_no_half_configured "case A-negative" "${PATH_VAL:-}" "${PRESENT_VAL:-}"

# ---------------------------------------------------------------------------
# Case B — the real checkout.  Skips LOUDLY (with the reason) when the sibling
# is not present, e.g. in the non-gui CI lane, which deliberately runs without
# it.  A skip here never masks case A, which is unconditional.
# ---------------------------------------------------------------------------
echo "case B: real codetracer-native-backend checkout"
REAL_WS="$(cd "$REPO_ROOT/.." && pwd)"
if [ -d "$REAL_WS/codetracer-native-backend" ]; then
	eval "$(probe_detect "$REPO_ROOT")"
	assert_backend_path_usable "case B" "${PATH_VAL:-}" "${PRESENT_VAL:-}" ""
	assert_no_half_configured "case B" "${PATH_VAL:-}" "${PRESENT_VAL:-}"
else
	skip "case B: no codetracer-native-backend checkout at $REAL_WS — this lane runs without the sibling, so the real-checkout leg cannot be exercised here (case A still ran and is authoritative for the detection logic)"
fi

# ---------------------------------------------------------------------------
# Case C — the retired repository name must not be reintroduced as a
# filesystem lookup.  `codetracer-rr-backend` does not exist as a repo;
# `projects/codetracer.toml` declares `codetracer-native-backend`.
# ---------------------------------------------------------------------------
echo "case C: retired directory name absent from live lookup sites"
for f in "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT/repro.nim"; do
	rel="${f#"$REPO_ROOT"/}"
	# Comments may still mention the old name (e.g. "formerly ..."); only
	# non-comment lines constitute a live lookup.
	if hits="$(grep -n 'codetracer-rr-backend' "$f" | grep -vE ':[[:space:]]*(#|##|--)' || true)"; [ -z "$hits" ]; then
		pass "case C: $rel has no live codetracer-rr-backend lookup"
	else
		fail "case C: $rel still looks up the retired name:"$'\n'"$hits"
	fi
done

echo
if [ "$failures" -eq 0 ]; then
	echo "sibling-backend-path-test: PASS"
	exit 0
fi
echo "sibling-backend-path-test: $failures assertion(s) FAILED" >&2
exit 1
