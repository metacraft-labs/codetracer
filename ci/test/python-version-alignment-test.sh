#!/usr/bin/env bash
#
# Contract suite for scripts/test-python-version-alignment.sh.
#
# The guard it covers asserts that every place a Python version can be OBSERVED
# still agrees with the one place it is DECLARED —
# `codetracer-python-recorder/.python-version`, in the repo that produces the
# ABI-locked artefact. Its header explains why that matters: a CPython
# extension module is ABI-locked to its interpreter's minor version, and when
# `.python-recorder-venv` was 3.13 while
# `codetracer_python_recorder.cpython-312-*.so` was 3.12, `ct record x.py`
# refused to run and the `record-python-happy-path` E2E edge went red.
#
# What THIS suite is for is the failure mode that guard is most exposed to:
# passing vacuously. Its checks are conditional on artifacts existing — a venv,
# a built `.so`, a sibling checkout — so on a bare tree it can find nothing to
# compare and still exit 0. Every case below therefore drives the real guard
# against a synthetic workspace carrying ONE seeded defect and asserts both
# that the right diagnostic appears and that the run actually failed; the
# aligned case asserts the converse. Three cases exist purely to prove the
# guard is not reading literals:
#
#   * `the declaration is the thing being followed` moves the recorder's
#     `.python-version` from 3.12 to 3.13 and asserts the verdicts INVERT — the
#     3.13 venv that failed now passes, and the cpython-312 extension and the
#     Windows YAML literal that passed now fail. A guard with "3.12" written in
#     it would pass both times.
#   * `a comment is not a defect` puts `python3 -m venv` inside a nix comment
#     and asserts the guard stays green — the shape that would otherwise make
#     the guard fire on its own documentation and get deleted.
#   * `...and the same source under a __future__ import does not raise it`
#     gives (G) the identical annotation under PEP 563 and asserts the floor is
#     unconstrained again. A guard that grepped for `|` fails that case.
#
# Two more cover the boundary the declaration cannot cross: the Windows YAML
# literal, which is compared because `setup-python` runs before the recorder is
# checked out, and `codetracer/env.ps1`, which provisions no Python today and
# must not start choosing a version of its own.
#
# The interpreters are stubs: two-line scripts that answer the guard's
# `sys.version_info` probe with a version this suite chooses, and its import
# probe with an exit code this suite chooses. That keeps the suite hermetic
# (no python3.13 needed to test the 3.13 case) and lets it seed versions that
# do not exist on the host.
#
# Pure bash. No network, no nix, no dev shell, no real Python, about a second.
#
# Run: bash ci/test/python-version-alignment-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-python-version-alignment.sh"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}

# The guard's (G) leg parses the pure recorder's AST, so it needs a real
# interpreter -- the one thing here that cannot be stubbed. Say so up front
# rather than letting four assertions fail with a confusing diagnostic, and
# say it as a FAILURE: a suite that quietly stops exercising a leg of the
# guard is the exact shape of rot this whole file exists to prevent.
command -v python3 >/dev/null 2>&1 || {
	echo "FAIL: no python3 on PATH; the (G) cases cannot be exercised." >&2
	echo "      Run this from the dev shell (ci/lint/bash.sh does)." >&2
	exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAILED=0

ok() {
	PASS=$((PASS + 1))
	echo "  ok   $1"
}

bad() {
	FAILED=$((FAILED + 1))
	echo "  FAIL $1" >&2
	if [ $# -gt 1 ]; then
		printf '%s\n' "$2" | sed 's/^/       /' >&2
	fi
}

assert_contains() { # <label> <haystack> <needle>
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "expected to find: $3
--- actual output ---
$2" ;;
	esac
}

assert_absent() { # <label> <haystack> <needle>
	case "$2" in
	*"$3"*) bad "$1" "expected NOT to find: $3
--- actual output ---
$2" ;;
	*) ok "$1" ;;
	esac
}

assert_rc() { # <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1" "expected exit $3, got $2"
	fi
}

# ---------------------------------------------------------------------------
# Synthetic tree construction
# ---------------------------------------------------------------------------

# make_tree <dir> <declared-nodot>
#
# A minimal workspace the guard can inspect: a recorder sibling that DECLARES
# the version in `.python-version` and carries honest pyprojects, and a
# codetracer repo whose nix/python.nix forwards that declaration and states
# nothing. Individual cases mutate exactly one thing afterwards.
make_tree() {
	local ws="$1" nodot="$2"
	mkdir -p "$ws/repo/nix/shells" "$ws/repo/.github/workflows" \
		"$ws/recorder/codetracer-python-recorder" \
		"$ws/recorder/codetracer-pure-python-recorder"

	# THE declaration, in the repo that owns the ABI.
	printf '3.%s\n' "$nodot" >"$ws/recorder/.python-version"

	# The consumer: a forwarder with no version of its own.
	cat >"$ws/repo/nix/python.nix" <<'EOF'
{ pkgs, inputs }:
let
  declared = inputs."codetracer-python-recorder".lib.python;
in
{
  inherit (declared) version abiTag nodot;
  package = declared.packageFor pkgs;
}
EOF

	cat >"$ws/repo/nix/shells/main.nix" <<'EOF'
{ pkgs }:
{
  shellHook = ''
    "$CODETRACER_PYTHON_CMD" -m venv --system-site-packages "$RECORDER_VENV"
  '';
}
EOF

	# The Windows lane's YAML literal, which cannot read .python-version.
	cat >"$ws/repo/.github/workflows/codetracer.yml" <<EOF
jobs:
  origin-dap-windows:
    steps:
      - name: Install Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.$nodot"
EOF

	# The native-Windows DIY environment, which provisions no Python.
	printf '# codetracer Windows dev environment\nWrite-Host "nim ready"\n' >"$ws/repo/env.ps1"

	# The recorder's multi-version support matrix.
	cat >"$ws/recorder/Justfile" <<'EOF'
PY_VERSIONS := "3.12 3.13"
EOF

	cat >"$ws/recorder/pyproject.toml" <<'EOF'
[project]
name = "codetracer-python-recorders"
requires-python = ">=3.12,<3.14"
EOF

	cat >"$ws/recorder/codetracer-python-recorder/pyproject.toml" <<'EOF'
[project]
name = "codetracer-python-recorder"
requires-python = ">=3.12,<3.14"
EOF

	# The pure recorder: no compiled part, so (F)'s closed-window rule does not
	# apply to it and (G) derives its floor from its own source instead.
	cat >"$ws/recorder/codetracer-pure-python-recorder/pyproject.toml" <<'EOF'
[project]
name = "codetracer-pure-python-recorder"
requires-python = ">=3.10"
EOF
	mkdir -p "$ws/recorder/codetracer-pure-python-recorder/src"
	cat >"$ws/recorder/codetracer-pure-python-recorder/src/trace.py" <<'EOF'
from typing import List


def main(argv: List[str] | None = None) -> None:
    pass
EOF
}

# make_extension <dir> <abi-nodot>   e.g. 312
make_extension() {
	local ws="$1" nodot="$2"
	mkdir -p "$ws/recorder/codetracer-python-recorder/codetracer_python_recorder"
	: >"$ws/recorder/codetracer-python-recorder/codetracer_python_recorder/codetracer_python_recorder.cpython-$nodot-x86_64-linux-gnu.so"
}

# make_venv <dir> <version e.g. 3.12> <can-import-recorder: yes|no>
#
# A stub interpreter, not a real venv. It answers the two probes the guard
# makes -- `-c 'import sys; print("%d.%d" % sys.version_info[:2])'` and
# `-c 'import codetracer_python_recorder'` -- and nothing else, which is
# exactly the interface the guard depends on.
make_venv() {
	local ws="$1" version="$2" importable="$3"
	local nodot="${version#3.}"
	mkdir -p "$ws/repo/.python-recorder-venv/bin"
	# The %d%d arm MUST come first: the guard's ABI probe and its version probe
	# both mention sys.version_info, and they are told apart only by the format
	# string. Getting this order wrong makes the stub answer "3.12" to a
	# question that expects "312", and every ABI assertion below would then be
	# testing the stub rather than the guard.
	cat >"$ws/repo/.python-recorder-venv/bin/python" <<EOF
#!/usr/bin/env bash
case "\$*" in
*%d%d*)                       echo "3$nodot" ;;
*version_info*)               echo "$version" ;;
*codetracer_python_recorder*) [ "$importable" = yes ] || exit 1 ;;
esac
exit 0
EOF
	chmod +x "$ws/repo/.python-recorder-venv/bin/python"
}

# run_guard <dir> [env assignments...]
run_guard() {
	local ws="$1"
	shift
	env CT_PYALIGN_ROOT="$ws/repo" \
		CT_PYALIGN_RECORDER="$ws/recorder" \
		CT_PYALIGN_NO_ENV=1 \
		"$@" bash "$GUARD" 2>&1
}

# ---------------------------------------------------------------------------

echo "an aligned tree passes, and says what it checked"

WS="$TMP/aligned"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "aligned tree exits 0" "$RC" 0
assert_contains "it read the declaration from the recorder's .python-version" "$OUT" ".python-version: 3.12"
assert_contains "it confirmed this repo states no version of its own" "$OUT" "(A3) nix/python.nix forwards the recorder's declaration and states no version of its own"
assert_contains "it checked the venv interpreter" "$OUT" "(D1) .python-recorder-venv is Python 3.12"
assert_contains "it checked the extension ABI tag" "$OUT" "(E1) every built codetracer_python_recorder extension carries the declared ABI tag (cpython-312)"
assert_contains "it checked the venv/extension edge" "$OUT" "(E2) the venv interpreter and the compiled extension agree"
assert_contains "it checked the Windows YAML literal it cannot make derive" "$OUT" "(H1) all 1 setup-python literal(s)"
assert_contains "it checked the native-Windows DIY gap" "$OUT" "(H2) env.ps1 still provisions no Python"
assert_absent "nothing failed" "$OUT" "FAIL"

echo
echo "a venv at the wrong minor version is caught, and both versions are named"

WS="$TMP/venvdrift"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.13 no
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "venv drift fails" "$RC" 1
assert_contains "the venv check accuses the venv" "$OUT" "FAIL (D1) .python-recorder-venv is the declared interpreter"
assert_contains "and names what it found and what was expected" "$OUT" "venv is Python 3.13, .python-version declares 3.12"
assert_contains "the ABI edge is reported in its own right" "$OUT" "FAIL (E2) the venv interpreter and the compiled extension agree"
assert_contains "and the diagnostic says why wiring cannot fix it" "$OUT" "no PATH or environment wiring can bridge it"
assert_absent "it does not blame the extension, which is correct" "$OUT" "FAIL (E1)"

echo
echo "a venv that cannot import the recorder is caught even when its version is right"

WS="$TMP/noimport"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 no
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unimportable recorder fails" "$RC" 1
assert_contains "the import check accuses the import" "$OUT" "FAIL (D2) .python-recorder-venv can import codetracer_python_recorder"
assert_contains "and points at the code that demands it" "$OUT" "ct record"
assert_absent "the version check still passes" "$OUT" "FAIL (D1)"

echo
echo "an extension built for another interpreter is caught"

WS="$TMP/abidrift"
make_tree "$WS" 12
make_extension "$WS" 313
make_venv "$WS" 3.12 yes
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "ABI drift fails" "$RC" 1
assert_contains "the ABI check names the tag it found" "$OUT" "cpython-313"
assert_contains "the ABI check names the tag it wanted" "$OUT" "(cpython-312)"

echo
echo "the declaration is the thing being followed -- move it and the verdicts invert"

# Same two artifacts as the 'venvdrift' case above (venv 3.13, extension
# cpython-312), but the recorder's .python-version now says 3.13. If any figure
# in the guard were a literal rather than a derivation, this case and
# 'venvdrift' could not disagree.
WS="$TMP/pinmoved"
make_tree "$WS" 13
make_extension "$WS" 312
make_venv "$WS" 3.13 yes
# Leave the Windows YAML literal where it was. It is the one figure the
# declaration cannot reach, so it is also the clearest demonstration that the
# guard's EXPECTATION moved: it passed at 3.12 in every case above and must now
# be accused, without the guard having been edited.
cat >"$WS/repo/.github/workflows/codetracer.yml" <<'EOF'
jobs:
  origin-dap-windows:
    steps:
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "moving the declaration does not make the guard green by itself" "$RC" 1
assert_contains "the guard followed the file" "$OUT" ".python-version: 3.13"
assert_absent "the 3.13 venv is now correct and is not accused" "$OUT" "FAIL (D1)"
assert_contains "the cpython-312 extension is now the defect" "$OUT" "FAIL (E1)"
assert_contains "and the expected tag moved with the declaration" "$OUT" "(cpython-313)"
assert_contains "and the Windows YAML literal moved with it too" "$OUT" "FAIL (H1)"

echo
echo "the flake input and the sibling checkout are cross-checked against each other"

# The way the mismatch comes back once the declaration is centralised:
# flake.lock pins a recorder revision declaring one interpreter while the
# sibling you are developing against declares another. Neither file is
# individually wrong; only the pair is.
WS="$TMP/lockdrift"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
OUT="$(env CT_PYALIGN_ROOT="$WS/repo" CT_PYALIGN_RECORDER="$WS/recorder" \
	CODETRACER_PYTHON_VERSION=3.13 CODETRACER_PYTHON_ABI_TAG=cpython-313 \
	CODETRACER_PYTHON_CMD="$WS/repo/.python-recorder-venv/bin/python" \
	bash "$GUARD" 2>&1)"
RC=$?
assert_rc "a lock/sibling disagreement fails" "$RC" 1
assert_contains "(A1) names both sides" "$OUT" "says 3.13"
assert_contains "(A1) says which file said what" "$OUT" ".python-version says 3.12"
assert_contains "(A1) explains what the disagreement means" "$OUT" "flake.lock pins a recorder revision that declares a different interpreter"

echo
echo "this repo may not state a version of its own"

WS="$TMP/ownopinion"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/nix/python.nix" <<'EOF'
{ pkgs, inputs }:
{
  package = pkgs.python312;
}
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a version literal in nix/python.nix fails even when it agrees" "$RC" 1
assert_contains "(A3) accuses the forwarder" "$OUT" "FAIL (A3) nix/python.nix forwards the recorder's declaration and states no version of its own"
assert_contains "(A3) quotes the line" "$OUT" "pkgs.python312"

echo
echo "...and a forwarder that forwards nothing is caught too"

WS="$TMP/notforwarding"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf '{ pkgs, inputs }:\n{\n  package = pkgs.python3;\n}\n' >"$WS/repo/nix/python.nix"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a python.nix that reads no input fails" "$RC" 1
assert_contains "(A3) says what is missing" "$OUT" "does not read inputs."

echo
echo "a second opinion about the version, anywhere else, is caught"

WS="$TMP/second"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf '{ pkgs }: { p = pkgs.python311; }\n' >"$WS/repo/nix/other.nix"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a second version pin fails" "$RC" 1
assert_contains "(B1) accuses the file that carries it" "$OUT" "nix/other.nix"
assert_contains "(B1) says where the version belongs instead" "$OUT" "codetracer-python-recorder's .python-version"

echo
echo "python3Packages -- the form that follows nixpkgs' default -- is caught too"

WS="$TMP/defaultpy"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf '{ pkgs }: { p = pkgs.python3Packages.flake8; }\n' >"$WS/repo/nix/lint.nix"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "python3Packages fails" "$RC" 1
assert_contains "and the diagnostic explains why it is a version choice" "$OUT" "default interpreter"

echo
echo "a bare 'python3 -m venv' in main.nix is caught -- the line the split entered through"

WS="$TMP/barevenv"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/nix/shells/main.nix" <<'EOF'
{ pkgs }:
{
  shellHook = ''
    python3 -m venv "$RECORDER_VENV"
  '';
}
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a bare python3 -m venv fails" "$RC" 1
assert_contains "(B2) accuses the venv construction" "$OUT" "FAIL (B2) main.nix builds the venv from the declared interpreter"
assert_contains "and quotes the offending line" "$OUT" "python3 -m venv"

echo
echo "main.nix is not the only place a venv gets built -- shell scripts are checked too"

WS="$TMP/barevenvsh"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
mkdir -p "$WS/repo/ci/test" "$WS/repo/scripts"
cat >"$WS/repo/ci/test/some-smoke.sh" <<'EOF'
#!/usr/bin/env bash
python3 -m venv "$D"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a bare python3 -m venv in a ci script fails" "$RC" 1
assert_contains "(B3) names the script" "$OUT" "ci/test/some-smoke.sh"
assert_contains "(B3) names the variable to use instead" "$OUT" "CODETRACER_PYTHON_CMD"

echo
echo "...and an absolute or variable interpreter in the same position does not"

# The three forms that are correct, and that a looser pattern would flag:
# the exported pin, a store path, and a venv-relative interpreter.
WS="$TMP/goodvenvsh"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
mkdir -p "$WS/repo/ci/test"
cat >"$WS/repo/ci/test/some-smoke.sh" <<'EOF'
#!/usr/bin/env bash
"${CODETRACER_PYTHON_CMD}" -m venv "$D"
/nix/store/aaaa-python3-3.12.13-env/bin/python3 -m venv "$E"
"$VENV/bin/python3" -m venv "$F"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "correct interpreter forms do not trip (B3)" "$RC" 0
assert_absent "(B3) stays green" "$OUT" "FAIL (B3)"

echo
echo "a comment is not a defect"

WS="$TMP/comment"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/nix/shells/main.nix" <<'EOF'
{ pkgs }:
{
  # This used to read `python3 -m venv`, which resolved from PATH.
  shellHook = ''
    "$CODETRACER_PYTHON_CMD" -m venv "$RECORDER_VENV"
  '';
}
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "prose about the bug does not trip the guard" "$RC" 0
assert_absent "(B2) stays green" "$OUT" "FAIL (B2)"

echo
echo "a requires-python window that excludes the pin is caught"

WS="$TMP/reqnarrow"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/recorder/codetracer-python-recorder/pyproject.toml" <<'EOF'
[project]
requires-python = ">=3.13,<3.14"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a window that excludes the pin fails" "$RC" 1
assert_contains "and says which bound is violated" "$OUT" "below the declared lower bound"

echo
echo "an open-ended requires-python on an ABI-locked distribution is caught"

WS="$TMP/reqopen"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/recorder/pyproject.toml" <<'EOF'
[project]
requires-python = ">=3.8"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "'>=3.8' on the workspace root fails" "$RC" 1
assert_contains "the diagnostic explains what is untrue about it" "$OUT" "an ABI-locked compiled extension supports a closed range"
assert_absent "the admits-the-pin check still passes, because 3.12 >= 3.8" "$OUT" "FAIL (F) codetracer-python-recorder workspace root: requires-python '>=3.8' admits"

echo
echo "the pure recorder's floor is derived from its own source, not from its claim"

# This is the shape that was actually wrong in the tree: a pure-Python
# distribution claiming ">=3.8" while using a PEP 604 union in an evaluated
# annotation, which raises TypeError on import under 3.9.
WS="$TMP/purefloor"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/recorder/codetracer-pure-python-recorder/pyproject.toml" <<'EOF'
[project]
requires-python = ">=3.8"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a floor below the source's real requirement fails" "$RC" 1
assert_contains "(G) names the construct that raises the floor" "$OUT" "PEP 604 unions in annotations are evaluated at def time"
assert_contains "(G) points at the file and line" "$OUT" "trace.py:4"
assert_absent "(F)'s closed-window rule is NOT applied to the pure package" "$OUT" "pure recorder: requires-python is bounded on both sides"

echo
echo "...and the same source under a __future__ import does not raise it"

# PEP 563 makes annotations strings, so the union is never evaluated and 3.8
# is a truthful claim again. A guard that grepped for '|' would fail here.
WS="$TMP/purefuture"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/recorder/codetracer-pure-python-recorder/pyproject.toml" <<'EOF'
[project]
requires-python = ">=3.8"
EOF
cat >"$WS/recorder/codetracer-pure-python-recorder/src/trace.py" <<'EOF'
from __future__ import annotations

from typing import List


def main(argv: List[str] | None = None) -> None:
    pass
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unevaluated annotation does not constrain the floor" "$RC" 0
assert_contains "(G) says why the floor is unconstrained" "$OUT" "no evaluated PEP 604 annotation"

echo
echo "the dev shell's own report of a broken venv is a test failure, not scrollback"

WS="$TMP/broken"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf 'codetracer_pure_python_recorder failed to install into /x/.python-recorder-venv\n' \
	>"$WS/repo/.python-recorder-venv/.broken"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a .broken marker fails the guard" "$RC" 1
assert_contains "(D0) reports it" "$OUT" "FAIL (D0) the dev shell reported no problem setting up .python-recorder-venv"
assert_contains "and repeats the reason the shell recorded" "$OUT" "failed to install into"

echo
echo "a .python-version that is not a CPython minor version stops the run"

# Everything downstream derives from this string -- the ABI tag, the nixpkgs
# attribute, the comparisons. Carrying on with a value like "3.12.13" or
# "pypy3.10" would produce confident, wrong verdicts, so the guard stops here
# rather than comparing against nonsense.
WS="$TMP/baddecl"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf '3.12.13\n' >"$WS/recorder/.python-version"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a malformed declaration fails" "$RC" 1
assert_contains "(A2) quotes what it got and what it wanted" "$OUT" "got '3.12.13', expected something of the form 3.N"
assert_absent "and it does not go on to compare against it" "$OUT" "(D1)"

echo
echo "the Windows YAML literal cannot derive the version, so it is compared"

WS="$TMP/wfdrift"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/.github/workflows/codetracer.yml" <<'EOF'
jobs:
  origin-dap-windows:
    steps:
      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a workflow literal that disagrees fails" "$RC" 1
assert_contains "(H1) accuses the workflow" "$OUT" "FAIL (H1) the Windows lanes' setup-python literals equal the declared 3.12"
assert_contains "(H1) explains why it is compared rather than derived" "$OUT" "setup-python runs before the recorder is"

echo
echo "the native-Windows DIY gap is a tripwire, not a silent hole"

# Today codetracer/env.ps1 provisions no Python at all, so `ct record x.py`
# there uses the developer's system interpreter. That is a gap, not a drift.
# What must not happen is someone starting to close it by choosing a version
# in env.ps1 -- which would recreate the original defect on the one lane the
# flake cannot reach.
WS="$TMP/ps1choice"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/env.ps1" <<'EOF'
$env:Path = "C:\Python313;$env:Path"
Write-Host "python ready"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "env.ps1 acquiring Python without deriving the version fails" "$RC" 1
assert_contains "(H2) accuses env.ps1" "$OUT" "FAIL (H2) env.ps1 provisions Python and derives the version from the declaration"
assert_contains "(H2) names what it should read" "$OUT" "CODETRACER_PYTHON_VERSION"

echo
echo "...and env.ps1 that DOES derive it passes"

WS="$TMP/ps1derived"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
cat >"$WS/repo/env.ps1" <<'EOF'
$v = Get-Content ..\codetracer-python-recorder\.python-version
Write-Host "python $v"
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "deriving the version in env.ps1 is accepted" "$RC" 0
assert_contains "(H2) says so" "$OUT" "(H2) env.ps1 provisions Python and derives the version from the declaration"

echo
echo "the version we build against must be one the recorder tests"

WS="$TMP/matrixgap"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
printf 'PY_VERSIONS := "3.13"\n' >"$WS/recorder/Justfile"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a declared version outside the support matrix fails" "$RC" 1
assert_contains "(H3) names the matrix and the declaration" "$OUT" "PY_VERSIONS is '3.13' but .python-version declares 3.12"
assert_contains "(H3) says why that matters" "$OUT" "is one nothing tests"

echo
echo "with no declaration at all the guard fails -- it does not exit 0 having checked nothing"

WS="$TMP/nodecl"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
rm -f "$WS/recorder/.python-version"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unresolvable declaration is a failure, not an n/a" "$RC" 1
assert_contains "it says both ways to supply one" "$OUT" "run this from the dev shell"
assert_contains "and says what the consequence is" "$OUT" "nothing below can be checked"

echo
echo "what cannot be observed is reported as n/a, and n/a is never a pass"

# The declaration is present (without it the guard hard-fails -- see the case
# above), but nothing has been BUILT: no venv, no compiled extension. Those
# checks have nothing to compare and must say so rather than pass.
WS="$TMP/bare"
make_tree "$WS" 12
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a tree with nothing built still exits 0" "$RC" 0
assert_contains "the unbuilt extension is called out by name" "$OUT" "n/a  (E) compiled extension -- the recorder sibling has not been built"
assert_contains "the absent venv is called out by name" "$OUT" "n/a  (D1/D2)"
assert_contains "and the summary counts them separately from checks" "$OUT" "n/a,"
assert_absent "an n/a is not printed as an ok" "$OUT" "ok   (E1)"

echo
echo "...and with the sibling gone entirely, that is named too"

WS="$TMP/nosibling"
make_tree "$WS" 12
make_venv "$WS" 3.12 yes
CODETRACER_PYTHON_VERSION_SAVED=3.12
rm -rf "$WS/recorder"
OUT="$(env CT_PYALIGN_ROOT="$WS/repo" CT_PYALIGN_RECORDER="$WS/recorder" \
	CODETRACER_PYTHON_VERSION="$CODETRACER_PYTHON_VERSION_SAVED" \
	CODETRACER_PYTHON_ABI_TAG=cpython-312 \
	CODETRACER_PYTHON_CMD="$WS/repo/.python-recorder-venv/bin/python" \
	bash "$GUARD" 2>&1)"
RC=$?
assert_contains "the absent sibling is named" "$OUT" "n/a  (E) compiled extension -- codetracer-python-recorder sibling absent"
assert_contains "and the declaration falls back to the flake input" "$OUT" "(A1) declared version comes from the flake input: 3.12"

echo
echo "the dev shell's derived exports are checked, not trusted"

# _ABI_TAG and _CMD are computed by ci-base.nix from what the input declares.
# A shell whose exports do not agree with each other is a broken derivation,
# and everything downstream reads those variables.
WS="$TMP/envdrift"
make_tree "$WS" 13
make_extension "$WS" 313
make_venv "$WS" 3.13 yes
OUT="$(env CT_PYALIGN_ROOT="$WS/repo" CT_PYALIGN_RECORDER="$WS/recorder" \
	CODETRACER_PYTHON_VERSION=3.13 CODETRACER_PYTHON_ABI_TAG=cpython-312 \
	CODETRACER_PYTHON_CMD=/nonexistent \
	bash "$GUARD" 2>&1)"
RC=$?
assert_rc "exports that disagree with each other fail" "$RC" 1
assert_contains "(C2) names both the export and what the version implies" "$OUT" "shell says cpython-312; the declared 3.13 gives cpython-313"
assert_contains "(C3) checks the interpreter the export points at" "$OUT" "FAIL (C3)"
assert_absent "(A1) is happy, because the two declarations do agree" "$OUT" "FAIL (A1)"

echo
echo "the first python3 on PATH is checked -- the mechanism the original bug used"

WS="$TMP/pathdrift"
make_tree "$WS" 12
make_extension "$WS" 312
make_venv "$WS" 3.12 yes
mkdir -p "$WS/fakebin"
cat >"$WS/fakebin/python3" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*version_info*) echo '3.13' ;;
esac
exit 0
EOF
chmod +x "$WS/fakebin/python3"
OUT="$(env CT_PYALIGN_ROOT="$WS/repo" CT_PYALIGN_RECORDER="$WS/recorder" \
	CODETRACER_PYTHON_VERSION=3.12 CODETRACER_PYTHON_ABI_TAG=cpython-312 \
	CODETRACER_PYTHON_CMD="$WS/repo/.python-recorder-venv/bin/python" \
	PATH="$WS/fakebin:$PATH" \
	bash "$GUARD" 2>&1)"
RC=$?
assert_rc "a different python3 ahead on PATH fails" "$RC" 1
assert_contains "(C4) accuses the PATH search" "$OUT" "FAIL (C4) the first python3 on PATH is the declared interpreter"
assert_contains "and explains how that produced the original defect" "$OUT" "propagating a different interpreter"

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
