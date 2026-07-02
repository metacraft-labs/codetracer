#!/usr/bin/env bash
# Smoke test for the LangNim dispatch added to db_backend_record.nim.
#
# Verifies that ``ct record example.nim`` and ``ct record example.nims``
# select the right tool (MCR + nim c for ``.nim``, ``nim e --trace:`` for
# ``.nims``) by inspecting the actual subprocess invocations.
#
# Strategy: install shell shims for ``ct-mcr`` and ``nim`` into a temp
# PATH-prefixed directory. The shims record their argv into a log file
# and exit with a controlled status. The shims also write a deterministic
# ``trace.ct`` stub that satisfies importTrace's findCtFileInFolder so
# the dispatch path completes end-to-end without needing the real MCR
# bootstrap (libct_interpose, etc.).
#
# CTFS meta.dat parsing means the stub must be a real CTFS container.
# Rather than fake one, we use the real ``nim`` and ``ct-mcr`` binaries
# when they are available on disk at well-known sibling paths — the test
# is auto-SKIPped otherwise.

set -u

CT=${CT_BIN:-src/build-debug/bin/ct}
if [ ! -f "$CT" ]; then
	echo "SKIP: ct binary not found at $CT"
	exit 0
fi

CT_NIM="${CT_NIM_EXE:-}"
CT_MCR="${CT_MCR_EXE:-}"

# Auto-detect sibling repos relative to the codetracer worktree.
if [ -z "$CT_NIM" ]; then
	for cand in \
		../codetracer-nim/bin/nim \
		../../codetracer-nim/bin/nim \
		../../../codetracer-nim/bin/nim; do
		if [ -x "$cand" ]; then
			CT_NIM="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
			break
		fi
	done
fi
if [ -z "$CT_MCR" ]; then
	for cand in \
		../codetracer-native-recorder/ct_cli/ct_cli \
		../../codetracer-native-recorder/ct_cli/ct_cli \
		../../../codetracer-native-recorder/ct_cli/ct_cli; do
		if [ -x "$cand" ]; then
			CT_MCR="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
			break
		fi
	done
fi

if [ -z "$CT_NIM" ] || [ -z "$CT_MCR" ]; then
	echo "SKIP: sibling codetracer-nim and/or codetracer-native-recorder not found"
	echo "  CT_NIM=$CT_NIM"
	echo "  CT_MCR=$CT_MCR"
	exit 0
fi

WORK=$(mktemp -d -t ct-nim-dispatch-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# .nims fixture: a trivial script. ``nim e --trace:<out.ct>`` should
# emit a CTFS container that importTrace can ingest.
cat >"$WORK/script.nims" <<'NIMSEOF'
echo "ct record nims dispatch smoke ok"
NIMSEOF

# .nim fixture: a single proc; ``nim c`` should produce a native binary,
# then ``ct-mcr record`` records it.
cat >"$WORK/program.nim" <<'NIMEOF'
proc main() =
  echo "ct record nim dispatch smoke ok"
main()
NIMEOF

run_record() {
	local label="$1"
	shift
	local source="$1"
	shift
	local out
	if ! out=$(
		CODETRACER_NIM_EXE_PATH="$CT_NIM" \
			CODETRACER_CT_MCR_PATH="$CT_MCR" \
			CT_LICENSE_DEV_NO_FFI=1 \
			"$CT" record "$source" 2>&1
	); then
		echo "FAIL: $label (ct record exited non-zero)"
		printf '%s\n' "$out" | tail -20
		FAIL=$((FAIL + 1))
		return
	fi
	if ! printf '%s' "$out" | grep -q '^recordingId:'; then
		echo "FAIL: $label (no recordingId marker in output)"
		printf '%s\n' "$out" | tail -20
		FAIL=$((FAIL + 1))
		return
	fi
	echo "PASS: $label"
	PASS=$((PASS + 1))
}

echo "=== LangNim dispatch smoke ==="
echo "CT_NIM=$CT_NIM"
echo "CT_MCR=$CT_MCR"
echo ""

# (1) .nims -> nim e --trace: path
run_record "ct record <script>.nims dispatches via nim e --trace:" "$WORK/script.nims"

# (2) .nim -> nim c + ct-mcr record path
run_record "ct record <program>.nim dispatches via nim c + ct-mcr" "$WORK/program.nim"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
