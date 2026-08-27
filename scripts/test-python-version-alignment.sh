#!/usr/bin/env bash
# =============================================================================
# Python-version alignment guard.
#
# ## The defect this exists to catch
#
# A CPython extension module is ABI-locked to the interpreter minor version it
# was compiled for. `codetracer-python-recorder` ships one:
#
#     codetracer_python_recorder.cpython-312-x86_64-linux-gnu.so
#
# so every interpreter that has to import it must be 3.12, exactly. The version
# is therefore owned by the repo that PRODUCES the artefact, and declared in
# `codetracer-python-recorder/.python-version`; this repo reads it through the
# flake input and states nothing.
#
# Before that, nine sites across four .nix files here each had an opinion.
# `ci-base.nix` pinned `pkgs.python312` three times AND called the recorder's
# `mkCodetracerPackages pkgs pkgs.python312` -- the CONSUMER asserting a
# version at the PRODUCER -- while also pulling `pkgs.python3Packages.flake8` /
# `.distutils`, which propagate nixpkgs' DEFAULT interpreter (3.13 on the
# current pin) onto the dev shell's PATH ahead of the pinned one.
# `nix/shells/main.nix` then built `.python-recorder-venv` with a bare
# `python3 -m venv`, got 3.13, and `ct record x.py` died with
#
#     error: Python module `codetracer_python_recorder` is not installed for
#            interpreter: .../.python-recorder-venv/bin/python
#
# taking the `record-python-happy-path` E2E edge with it. No path wiring can
# bridge an ABI split, and a "keep these in sync" comment had never been the
# thing keeping them in sync.
#
# ## How this guard works
#
# It never states a Python version. Every figure it compares is DERIVED:
#
#   * the declaration   <- $CODETRACER_PYTHON_VERSION (what THIS repo's
#                          flake.lock pins the recorder to) and
#                          <recorder>/.python-version (what the SIBLING
#                          CHECKOUT says) -- cross-checked, because a flake.lock
#                          pinning a recorder revision that declares a different
#                          interpreter than the sibling you develop against is a
#                          real and otherwise silent way to get the mismatch back
#   * the venv          <- `.python-recorder-venv/bin/python`'s own
#                          sys.version_info
#   * the extension     <- the `cpython-NNN` tag in the recorder sibling's
#                          built .so filename
#   * the support       <- `requires-python` in the recorder's pyproject.toml
#     window               files, and PY_VERSIONS in its Justfile
#   * the pure floor    <- the pure recorder's own AST
#
# so a bump made in `.python-version` propagates everywhere and this guard keeps
# passing, while a version chosen anywhere else fails it.
#
# ## What it CHECKS but cannot make DERIVE
#
# `.python-version` propagates by being read. Nix reads it through the flake
# input; uv reads it natively, which is what makes `just dev` and the recorder's
# own `env.ps1` follow it without either knowing the file exists. Two things
# cannot read it, and (H) exists so that "the version is specified in one place"
# is not a claim that quietly holds for the Nix lane only:
#
#   * `.github/workflows/codetracer.yml`'s `actions/setup-python` steps run
#     BEFORE the recorder is checked out, so they carry a YAML literal. (H1)
#     compares it against the declaration.
#   * `codetracer/env.ps1` -- the native-Windows DIY environment -- provisions
#     no Python at all, so `ct record x.py` there falls through
#     `src/ct/trace/record.nim:52-78` to the developer's system interpreter,
#     unpinned. (H2) is a tripwire on that gap, not a fix for it; the gap is
#     recorded with an owner in nix/python.nix and in codetracer-specs.
#
# ## Running
#
#   bash scripts/test-python-version-alignment.sh     (or: just test-python-version-alignment)
#
# Environment overrides (used by ci/test/python-version-alignment-test.sh to
# drive this guard against synthetic trees carrying seeded defects):
#
#   CT_PYALIGN_ROOT         repo root to inspect       (default: this repo)
#   CT_PYALIGN_RECORDER     recorder sibling to inspect (default: ../codetracer-python-recorder)
#   CT_PYALIGN_NO_ENV=1     ignore the ambient CODETRACER_PYTHON_* exports
# =============================================================================
set -uo pipefail

REPO_ROOT="${CT_PYALIGN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECORDER_DIR="${CT_PYALIGN_RECORDER:-$REPO_ROOT/../codetracer-python-recorder}"

checks=0
failures=0
nas=0

pass() {
	checks=$((checks + 1))
	printf '    ok   %s\n' "$1"
}

fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '    FAIL %s\n' "$1"
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/           /'
	fi
}

# Deliberately NOT called "skip". A skip reads as a pass at a glance; this
# prints its own line, is counted separately, and appears in the summary, so a
# run in which nothing could be checked cannot be mistaken for a clean one.
na() {
	nas=$((nas + 1))
	printf '    n/a  %s\n' "$1"
}

# ---------------------------------------------------------------------------
# (A) The declaration -- which lives in the OTHER repo
#
# codetracer-python-recorder produces the ABI-locked artefact, so it owns the
# version and declares it in its own `.python-version`. This repo reads that
# through the flake input and states nothing.
#
# Two independent ways to learn the declared version, and they are cross-
# checked against each other when both are available:
#
#   $CODETRACER_PYTHON_VERSION   what the FLAKE INPUT declares, exported by
#                                nix/shells/ci-base.nix. Authoritative for
#                                anything built here.
#   <recorder>/.python-version   what the SIBLING CHECKOUT declares. What `just
#                                dev` and `uv` in that checkout will actually
#                                produce.
#
# When they disagree, flake.lock pins a recorder revision that declares a
# different interpreter than the sibling you are developing against — which is
# a real and otherwise-silent way to get an ABI mismatch back.
# ---------------------------------------------------------------------------

PYTHON_NIX="$REPO_ROOT/nix/python.nix"
RECORDER_DECL="$RECORDER_DIR/.python-version"

env_version=""
if [ -z "${CT_PYALIGN_NO_ENV:-}" ]; then
	env_version="${CODETRACER_PYTHON_VERSION:-}"
fi

file_version=""
if [ -f "$RECORDER_DECL" ]; then
	# `head -n 1` and not `$(cat)`: the file carries a trailing newline (every
	# tool that writes it does) and may carry a comment line in future.
	file_version="$(head -n 1 "$RECORDER_DECL" | tr -d '[:space:]')"
fi

if [ -n "$env_version" ] && [ -n "$file_version" ]; then
	if [ "$env_version" = "$file_version" ]; then
		pass "(A1) the flake input and the recorder sibling declare the same version ($env_version)"
	else
		fail "(A1) the flake input and the recorder sibling declare the same version" \
			"the dev shell (via flake.lock's codetracer-python-recorder) says $env_version;
$RECORDER_DECL says $file_version.
flake.lock pins a recorder revision that declares a different interpreter than
the checkout you are developing against."
	fi
	PIN_VERSION="$env_version"
elif [ -n "$env_version" ]; then
	pass "(A1) declared version comes from the flake input: $env_version (no recorder sibling to cross-check)"
	PIN_VERSION="$env_version"
elif [ -n "$file_version" ]; then
	pass "(A1) declared version comes from $RECORDER_DECL: $file_version (not in the dev shell, so no flake-input cross-check)"
	PIN_VERSION="$file_version"
else
	# Deliberately a hard failure and not an `n/a`. Without the declaration
	# this guard has nothing to compare anything against, and an all-`n/a` run
	# that exits 0 is exactly the vacuous pass this file exists to prevent.
	fail "(A1) the declared Python version can be found" \
		"neither \$CODETRACER_PYTHON_VERSION (run this from the dev shell) nor
$RECORDER_DECL (check out the codetracer-python-recorder sibling) is available.
With neither, nothing below can be checked."
	printf '\n%d checks, %d n/a, %d failure(s)\n' "$checks" "$nas" "$failures"
	exit 1
fi

case "$PIN_VERSION" in
3.[0-9] | 3.[0-9][0-9]) ;;
*)
	fail "(A2) the declared version is a CPython minor version" \
		"got '$PIN_VERSION', expected something of the form 3.N"
	printf '\n%d checks, %d n/a, %d failure(s)\n' "$checks" "$nas" "$failures"
	exit 1
	;;
esac
PIN_NODOT="${PIN_VERSION#3.}"
PIN_ABI_TAG="cpython-3$PIN_NODOT"
pass "(A2) the declared version is a CPython minor version: $PIN_VERSION (ABI tag $PIN_ABI_TAG)"

# This repo must not have an opinion of its own. nix/python.nix is a FORWARDER:
# it reads `inputs."codetracer-python-recorder".lib.python` and states no
# version. A literal appearing there is the consumer asserting a version at the
# producer again, which is the inversion the whole change undoes.
if [ ! -f "$PYTHON_NIX" ]; then
	fail "(A3) nix/python.nix forwards the recorder's declaration" \
		"not found at $PYTHON_NIX"
else
	# `grep -o` over the whole file, not `grep -q` in a pipeline: this script
	# runs under `set -o pipefail`, and `grep -q` exits on its first match,
	# killing the producer with SIGPIPE so the pipeline reports 141 -- a
	# SUCCESSFUL match reading as a failure. Same trap
	# scripts/test-build-alignment.sh documents at its (J) check.
	own_opinion="$(grep -nE '\bpkgs\.python3[0-9]+\b|\bpython3[0-9]+Packages\b|\bpkgs\.python3Packages\b' "$PYTHON_NIX" |
		grep -vE '^[0-9]+:[[:space:]]*#' || true)"
	forwards="$(grep -cE 'codetracer-python-recorder"\]?\.lib\.python|inputs\."codetracer-python-recorder"' "$PYTHON_NIX" || true)"
	if [ -n "$own_opinion" ]; then
		fail "(A3) nix/python.nix forwards the recorder's declaration and states no version of its own" \
			"it names an interpreter directly:
$own_opinion"
	elif [ "$forwards" -eq 0 ]; then
		fail "(A3) nix/python.nix forwards the recorder's declaration" \
			"it does not read inputs.\"codetracer-python-recorder\" at all"
	else
		pass "(A3) nix/python.nix forwards the recorder's declaration and states no version of its own"
	fi
fi

# ---------------------------------------------------------------------------
# (B) Nothing here may choose a version
#
# This is the check with teeth. The bug was not that some file had the wrong
# version -- it is that nine sites across four .nix files each had an opinion.
# Any versioned Python attribute in this repo's nix, and any `python3Packages`
# (which follows nixpkgs' default interpreter and is how 3.13 got onto the PATH
# in the first place), is a second opinion waiting to diverge. nix/python.nix
# is checked by (A3) above rather than exempted.
# ---------------------------------------------------------------------------

second_opinions=""
while IFS= read -r nixfile; do
	[ -n "$nixfile" ] || continue
	hits="$(grep -nE '\bpython3[0-9]+(Packages)?\b|\bpython3Packages\b' "$nixfile" |
		grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' || true)"
	if [ -n "$hits" ]; then
		second_opinions="$second_opinions
${nixfile#"$REPO_ROOT/"}:
$hits"
	fi
done <<EOF
$(find "$REPO_ROOT/nix" -name '*.nix' -type f 2>/dev/null | sort)
$(ls "$REPO_ROOT"/flake.nix 2>/dev/null || true)
EOF

if [ -n "$second_opinions" ]; then
	fail "(B1) no .nix file in this repo chooses a Python version" \
		"a versioned python attribute (or python3Packages, which follows nixpkgs'
default interpreter) appears here. The version belongs to
codetracer-python-recorder's .python-version; read it through
nix/python.nix:$second_opinions"
else
	pass "(B1) no .nix file in this repo chooses a Python version"
fi

# The specific regression: a bare `python3` used to build the venv. It resolves
# from PATH, so it silently follows whatever interpreter a package happened to
# propagate. Named explicitly because it is the line the split entered through.
MAIN_NIX="$REPO_ROOT/nix/shells/main.nix"
if [ -f "$MAIN_NIX" ]; then
	# Comment lines are dropped first: this file's own prose explains what the
	# bare form was and why it went, and a guard that fires on the explanation
	# of the bug it guards against is a guard nobody can keep.
	bare="$(grep -nE '(^|[^/[:alnum:]_-])python3[[:space:]]+-m[[:space:]]+venv' "$MAIN_NIX" |
		grep -vE '^[0-9]+:[[:space:]]*#' || true)"
	if [ -n "$bare" ]; then
		fail "(B2) main.nix builds the venv from the declared interpreter, not from PATH" \
			"bare 'python3 -m venv' resolves from PATH:
$bare"
	else
		pass "(B2) main.nix builds the venv from the declared interpreter, not from PATH"
	fi
else
	fail "(B2) main.nix builds the venv from the declared interpreter, not from PATH" \
		"nix/shells/main.nix not found at $MAIN_NIX"
fi

# main.nix is not the only place a venv gets built. ci/test/
# python-recorder-smoke.sh builds two, and did so with the same bare `python3`,
# which meant the interpreter that lane tested was decided by package ordering
# in the dev shell rather than by anything written down. Same rule, same
# reason, applied to every shell script in the repo.
bare_sh=""
while IFS= read -r sh; do
	[ -n "$sh" ] || continue
	hits="$(grep -nE '(^|[^"$/[:alnum:]_}-])python3[[:space:]]+-m[[:space:]]+venv' "$sh" |
		grep -vE '^[0-9]+:[[:space:]]*#' || true)"
	if [ -n "$hits" ]; then
		bare_sh="$bare_sh
${sh#"$REPO_ROOT/"}:
$hits"
	fi
done <<EOF
$(find "$REPO_ROOT/ci" "$REPO_ROOT/scripts" -name '*.sh' -type f 2>/dev/null |
	grep -v 'test-python-version-alignment\|python-version-alignment-test' | sort)
EOF

if [ -n "$bare_sh" ]; then
	fail "(B3) no shell script builds a venv from a bare 'python3'" \
		"use \$CODETRACER_PYTHON_CMD (exported by nix/shells/ci-base.nix from the pin):$bare_sh"
else
	pass "(B3) no shell script builds a venv from a bare 'python3'"
fi

# ---------------------------------------------------------------------------
# (C) The dev shell's exports agree with the declaration
#
# ci-base.nix computes CODETRACER_PYTHON_VERSION / _ABI_TAG / _CMD from what
# the recorder's flake input declares. (A1) has already compared the version
# against the sibling checkout's `.python-version`; what is left to check here
# is that the DERIVED exports and the actual interpreters agree with it. Every
# consumer that reads these variables is believing them.
# ---------------------------------------------------------------------------

if [ -n "${CT_PYALIGN_NO_ENV:-}" ]; then
	na "(C) dev-shell exports -- suppressed by CT_PYALIGN_NO_ENV"
elif [ -z "${CODETRACER_PYTHON_VERSION:-}" ]; then
	na "(C) dev-shell exports -- not inside the dev shell (CODETRACER_PYTHON_VERSION unset)"
else
	if [ "${CODETRACER_PYTHON_ABI_TAG:-}" = "$PIN_ABI_TAG" ]; then
		pass "(C2) \$CODETRACER_PYTHON_ABI_TAG (${CODETRACER_PYTHON_ABI_TAG:-<unset>}) is derived from the declared $PIN_VERSION"
	else
		fail "(C2) \$CODETRACER_PYTHON_ABI_TAG is derived from the declared version" \
			"shell says ${CODETRACER_PYTHON_ABI_TAG:-<unset>}; the declared $PIN_VERSION gives $PIN_ABI_TAG"
	fi

	if [ -x "${CODETRACER_PYTHON_CMD:-}" ]; then
		cmd_v="$("$CODETRACER_PYTHON_CMD" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
		if [ "$cmd_v" = "$PIN_VERSION" ]; then
			pass "(C3) \$CODETRACER_PYTHON_CMD is Python $cmd_v"
		else
			fail "(C3) \$CODETRACER_PYTHON_CMD is the declared interpreter" \
				"$CODETRACER_PYTHON_CMD is Python ${cmd_v:-<unreadable>}, declared is $PIN_VERSION"
		fi
	else
		fail "(C3) \$CODETRACER_PYTHON_CMD is the declared interpreter" \
			"CODETRACER_PYTHON_CMD=${CODETRACER_PYTHON_CMD:-<unset>} is not executable"
	fi

	# The PATH check. This is the one that would have caught the original bug
	# at its source: `python3Packages.flake8` propagated a 3.13 interpreter and
	# it won the PATH search, ahead of the pinned 3.12 env. A future package
	# added to ci-base.nix can do exactly that again, and nothing else notices
	# until an extension refuses to load.
	#
	# The venv is prepended to PATH by main.nix and is itself built from the
	# pin, so whichever of the two comes first must report the pinned version.
	path_py="$(command -v python3 2>/dev/null || true)"
	if [ -n "$path_py" ]; then
		path_v="$("$path_py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
		if [ "$path_v" = "$PIN_VERSION" ]; then
			pass "(C4) the first python3 on PATH is Python $path_v ($path_py)"
		else
			fail "(C4) the first python3 on PATH is the declared interpreter" \
				"$path_py is Python ${path_v:-<unreadable>}, declared is $PIN_VERSION
a package in nix/shells/ci-base.nix is propagating a different interpreter
ahead of the pinned one -- that is exactly how .python-recorder-venv came to
be built at the wrong minor version."
		fi
	else
		fail "(C4) the first python3 on PATH is the declared interpreter" \
			"no python3 on PATH inside the dev shell"
	fi
fi

# ---------------------------------------------------------------------------
# (D) The venv
# ---------------------------------------------------------------------------

RECORDER_VENV="$REPO_ROOT/.python-recorder-venv"

if [ -e "$RECORDER_VENV/.broken" ]; then
	fail "(D0) the dev shell reported no problem setting up .python-recorder-venv" \
		"$RECORDER_VENV/.broken says:
$(cat "$RECORDER_VENV/.broken" 2>/dev/null)"
elif [ -d "$RECORDER_VENV" ]; then
	pass "(D0) the dev shell reported no problem setting up .python-recorder-venv"
else
	na "(D0) .python-recorder-venv health -- venv not created (dev shell not entered here)"
fi

if [ -x "$RECORDER_VENV/bin/python" ]; then
	venv_v="$("$RECORDER_VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
	if [ "$venv_v" = "$PIN_VERSION" ]; then
		pass "(D1) .python-recorder-venv is Python $venv_v"
	else
		fail "(D1) .python-recorder-venv is the declared interpreter" \
			"venv is Python ${venv_v:-<unreadable>}, .python-version declares $PIN_VERSION"
	fi

	# What `src/ct/trace/record.nim` actually demands of
	# CODETRACER_PYTHON_INTERPRETER before it will record anything.
	if "$RECORDER_VENV/bin/python" -c 'import codetracer_python_recorder' 2>/dev/null; then
		pass "(D2) .python-recorder-venv can import codetracer_python_recorder"
	else
		fail "(D2) .python-recorder-venv can import codetracer_python_recorder" \
			"this is the exact import 'ct record <file>.py' checks before recording;
without it the launcher<->recorder E2E edge fails at scenario 1."
	fi
else
	na "(D1/D2) .python-recorder-venv interpreter -- venv not created (dev shell not entered here)"
fi

if [ -n "${CT_PYALIGN_NO_ENV:-}" ] || [ -z "${CODETRACER_PYTHON_INTERPRETER:-}" ]; then
	na "(D3) \$CODETRACER_PYTHON_INTERPRETER -- unset"
else
	interp_v="$("$CODETRACER_PYTHON_INTERPRETER" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
	if [ "$interp_v" = "$PIN_VERSION" ]; then
		pass "(D3) \$CODETRACER_PYTHON_INTERPRETER is Python $interp_v"
	else
		fail "(D3) \$CODETRACER_PYTHON_INTERPRETER is the declared interpreter" \
			"$CODETRACER_PYTHON_INTERPRETER is Python ${interp_v:-<unreadable>}, declared is $PIN_VERSION"
	fi
fi

# ---------------------------------------------------------------------------
# (E) The compiled extension -- the ABI edge itself
# ---------------------------------------------------------------------------

if [ ! -d "$RECORDER_DIR" ]; then
	na "(E) compiled extension -- codetracer-python-recorder sibling absent at $RECORDER_DIR"
else
	sos="$(find "$RECORDER_DIR" -name 'codetracer_python_recorder.cpython-*.so' \
		-not -path '*/target/*' 2>/dev/null | sort || true)"
	if [ -z "$sos" ]; then
		na "(E) compiled extension -- the recorder sibling has not been built (no cpython-*.so)"
	else
		bad=""
		while IFS= read -r so; do
			[ -n "$so" ] || continue
			tag="$(basename "$so" | sed -E 's/^codetracer_python_recorder\.(cpython-[0-9]+)-.*/\1/')"
			if [ "$tag" != "$PIN_ABI_TAG" ]; then
				bad="$bad
  $tag  $so"
			fi
		done <<EOF
$sos
EOF
		if [ -n "$bad" ]; then
			fail "(E1) every built codetracer_python_recorder extension carries the declared ABI tag ($PIN_ABI_TAG)" \
				"a CPython extension only loads into the minor version it was compiled
for. These do not match the pin:$bad"
		else
			pass "(E1) every built codetracer_python_recorder extension carries the declared ABI tag ($PIN_ABI_TAG)"
		fi

		# Stated separately from (D1)+(E1) on purpose: this is THE failing edge.
		# Both sides are read from artifacts, so it stays true if the pin moves
		# and both sides move with it.
		if [ -x "$RECORDER_VENV/bin/python" ]; then
			venv_tag="cpython-$("$RECORDER_VENV/bin/python" -c 'import sys; print("%d%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
			first_so_tag="$(basename "$(printf '%s\n' "$sos" | head -n 1)" |
				sed -E 's/^codetracer_python_recorder\.(cpython-[0-9]+)-.*/\1/')"
			if [ "$venv_tag" = "$first_so_tag" ]; then
				pass "(E2) the venv interpreter and the compiled extension agree ($venv_tag)"
			else
				fail "(E2) the venv interpreter and the compiled extension agree" \
					"venv wants $venv_tag, the built extension is $first_so_tag --
this is an ABI split; no PATH or environment wiring can bridge it."
			fi
		else
			na "(E2) venv/extension ABI agreement -- venv not created"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# (F) requires-python must admit the pin
#
# `requires-python` is a claim about which interpreters a distribution
# supports. For an ABI-locked compiled extension it is not a preference, it is
# a fact, and a window that does not contain the interpreter the whole
# workspace is pinned to is a lie that `pip`/`uv` will act on.
# ---------------------------------------------------------------------------

# Compare two "3.N" strings numerically. Pure shell, no sort -V (whose
# behaviour on 3.9 vs 3.10 differs between coreutils versions).
ver_ge() { # ver_ge A B  -> A >= B
	[ "${1#3.}" -ge "${2#3.}" ]
}
ver_lt() { # ver_lt A B  -> A <  B
	[ "${1#3.}" -lt "${2#3.}" ]
}

check_requires_python() { # <label> <pyproject> <must-admit-pin: yes|no>
	local label="$1" toml="$2" must_admit="$3"
	if [ ! -f "$toml" ]; then
		na "(F) $label -- $toml not found"
		return
	fi
	local spec
	spec="$(grep -m1 -E '^[[:space:]]*requires-python[[:space:]]*=' "$toml" |
		sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
	if [ -z "$spec" ]; then
		fail "(F) $label declares requires-python" "no requires-python in $toml"
		return
	fi

	local lower upper ok reason
	lower="$(printf '%s' "$spec" | grep -oE '>=[[:space:]]*3\.[0-9]+' | sed -E 's/>=[[:space:]]*//' || true)"
	upper="$(printf '%s' "$spec" | grep -oE '<[[:space:]]*3\.[0-9]+' | sed -E 's/<[[:space:]]*//' || true)"

	ok=1
	reason=""
	if [ -n "$lower" ] && ! ver_ge "$PIN_VERSION" "$lower"; then
		ok=0
		reason="pin $PIN_VERSION is below the declared lower bound >=$lower"
	fi
	if [ -n "$upper" ] && ! ver_lt "$PIN_VERSION" "$upper"; then
		ok=0
		reason="pin $PIN_VERSION is not below the declared upper bound <$upper"
	fi

	if [ "$must_admit" = "yes" ] && [ "$ok" -eq 0 ]; then
		fail "(F) $label: requires-python '$spec' admits the declared $PIN_VERSION" "$reason"
		return
	fi
	if [ "$must_admit" = "yes" ]; then
		pass "(F) $label: requires-python '$spec' admits the declared $PIN_VERSION"
	fi

	# An ABI-locked compiled extension cannot honestly declare an open-ended
	# lower bound: it does not run on any interpreter older than the one it was
	# built for, and `>=3.8` invites pip to install it into a 3.8 environment
	# where the import fails. Require BOTH bounds, and require the window to be
	# narrow enough to be a real claim rather than a wish.
	if [ "$must_admit" = "yes" ]; then
		if [ -n "$lower" ] && [ -n "$upper" ]; then
			pass "(F) $label: requires-python is bounded on both sides ('$spec')"
		else
			fail "(F) $label: requires-python is bounded on both sides" \
				"'$spec' -- an ABI-locked compiled extension supports a closed range of
interpreter minor versions; an open bound is not true of it."
		fi
	fi
}

check_requires_python "codetracer-python-recorder (compiled)" \
	"$RECORDER_DIR/codetracer-python-recorder/pyproject.toml" yes
check_requires_python "codetracer-python-recorder workspace root" \
	"$RECORDER_DIR/pyproject.toml" yes

# ---------------------------------------------------------------------------
# (G) The pure-Python recorder's floor must be true of its own source
#
# codetracer-pure-python-recorder has no compiled part, so it is NOT ABI-locked
# and (F)'s closed-window rule does not apply to it -- it legitimately supports
# more interpreters than the workspace as a whole. But it claimed ">=3.8" while
# src/trace.py:238 reads
#
#     def main(argv: List[str] | None = None) -> None:
#
# a PEP 604 union over a typing generic in a module with no
# `from __future__ import annotations`. Annotations on a `def` are evaluated at
# definition time and `_GenericAlias.__or__` arrived in 3.10, so on 3.8 and 3.9
# the module does not import at all:
#
#     Python 3.9.20  -> TypeError: unsupported operand type(s) for |:
#                       '_GenericAlias' and 'NoneType'
#     Python 3.10.15 -> ok
#
# The floor is therefore DERIVED from the source rather than asserted: the AST
# is parsed for a union operator inside an annotation, and if one is found in a
# module without the __future__ import, the declared lower bound must be at
# least 3.10. Nothing here has to be updated when the source changes -- adding
# such an annotation to a module raises the required floor automatically, and
# removing every one of them lowers it again.
# ---------------------------------------------------------------------------

PURE_DIR="$RECORDER_DIR/codetracer-pure-python-recorder"
pure_toml="$PURE_DIR/pyproject.toml"
pure_probe="${CODETRACER_PYTHON_CMD:-$(command -v python3 || true)}"

if [ ! -f "$pure_toml" ]; then
	na "(G) pure recorder floor -- $pure_toml not found"
elif [ ! -x "$pure_probe" ]; then
	na "(G) pure recorder floor -- no python3 available to parse the source with"
else
	pep604_files="$("$pure_probe" - "$PURE_DIR" <<'PY' 2>/dev/null || true
import ast, pathlib, sys

root = pathlib.Path(sys.argv[1])
hits = []
for path in sorted(root.rglob("*.py")):
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (SyntaxError, UnicodeDecodeError):
        continue
    # PEP 563: with this import, annotations are strings and are never
    # evaluated, so a union in one costs nothing at runtime.
    if any(
        isinstance(n, ast.ImportFrom)
        and n.module == "__future__"
        and any(a.name == "annotations" for a in n.names)
        for n in ast.walk(tree)
    ):
        continue
    for node in ast.walk(tree):
        anns = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            anns = [a.annotation for a in node.args.args if a.annotation]
            anns += [a.annotation for a in node.args.kwonlyargs if a.annotation]
            if node.returns:
                anns.append(node.returns)
        elif isinstance(node, ast.AnnAssign) and node.annotation:
            anns = [node.annotation]
        for ann in anns:
            for sub in ast.walk(ann):
                if isinstance(sub, ast.BinOp) and isinstance(sub.op, ast.BitOr):
                    hits.append("%s:%d" % (path, getattr(node, "lineno", 0)))
                    break
print("\n".join(sorted(set(hits))))
PY
	)"

	pure_spec="$(grep -m1 -E '^[[:space:]]*requires-python[[:space:]]*=' "$pure_toml" |
		sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
	pure_lower="$(printf '%s' "$pure_spec" | grep -oE '>=[[:space:]]*3\.[0-9]+' | sed -E 's/>=[[:space:]]*//' || true)"

	if [ -z "$pep604_files" ]; then
		pass "(G) pure recorder: no evaluated PEP 604 annotation, so its floor is unconstrained by this rule ('$pure_spec')"
	elif [ -z "$pure_lower" ]; then
		fail "(G) pure recorder: requires-python declares a lower bound" \
			"'$pure_spec' has none, but the source uses PEP 604 unions in evaluated annotations:
$pep604_files"
	elif ver_ge "$pure_lower" "3.10"; then
		pass "(G) pure recorder: floor >=$pure_lower covers its evaluated PEP 604 annotations"
	else
		fail "(G) pure recorder: floor >=$pure_lower covers its evaluated PEP 604 annotations" \
			"PEP 604 unions in annotations are evaluated at def time and require 3.10+.
On 3.9 the module raises TypeError on import. Found at:
$pep604_files"
	fi
fi

# ---------------------------------------------------------------------------
# (H) The lanes the declaration cannot REACH, only be compared against
#
# `.python-version` propagates by being read: nix reads it through the flake
# input, uv reads it natively (so `just dev` and, through `.venv/pyvenv.cfg`,
# the recorder's own env.ps1 follow it without knowing it exists). Two places
# in this repo cannot read it, and saying "the version is specified in one
# place" without saying so would make the claim true of the Nix lane and false
# of the product -- the same class of defect as the one being fixed.
#
#   H1  .github/workflows/codetracer.yml's `actions/setup-python@v5` steps.
#       `setup-python` runs BEFORE the recorder is checked out in those jobs,
#       so it has no file to read. The literal is therefore CHECKED here rather
#       than derived, and this is the check.
#   H2  codetracer/env.ps1 -- the native-Windows DIY environment. It provisions
#       no Python at all today, so `ct record x.py` there falls through
#       src/ct/trace/record.nim:52-78 to the developer's system interpreter,
#       unpinned. That is a gap, not a drift, and closing it is separate work.
#       What this check does is make the gap noisy the moment someone starts
#       closing it without wiring it to the declaration.
#   H3  the recorder's own multi-version support matrix must contain the
#       declared version, or the version we build against is one nobody tests.
# ---------------------------------------------------------------------------

WORKFLOW="$REPO_ROOT/.github/workflows/codetracer.yml"
if [ ! -f "$WORKFLOW" ]; then
	na "(H1) Windows setup-python literals -- $WORKFLOW not found"
else
	# `python-version: "3.12"` under an `actions/setup-python` step. Read as
	# text, because the whole point is that this file cannot read the
	# declaration and the two must be compared.
	wf_versions="$(grep -nE '^[[:space:]]*python-version:[[:space:]]*"?[0-9]+\.[0-9]+"?[[:space:]]*$' "$WORKFLOW" || true)"
	if [ -z "$wf_versions" ]; then
		na "(H1) Windows setup-python literals -- none found in $(basename "$WORKFLOW")"
	else
		wf_bad=""
		wf_count=0
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			wf_count=$((wf_count + 1))
			v="$(printf '%s' "$line" | sed -E 's/.*python-version:[[:space:]]*"?([0-9]+\.[0-9]+)"?.*/\1/')"
			[ "$v" = "$PIN_VERSION" ] || wf_bad="$wf_bad
  $line"
		done <<EOF
$wf_versions
EOF
		if [ -n "$wf_bad" ]; then
			fail "(H1) the Windows lanes' setup-python literals equal the declared $PIN_VERSION" \
				"these cannot read .python-version (setup-python runs before the recorder is
checked out), so they are compared instead -- and they disagree:$wf_bad"
		else
			pass "(H1) all $wf_count setup-python literal(s) in $(basename "$WORKFLOW") equal the declared $PIN_VERSION"
		fi
	fi
fi

ENV_PS1="$REPO_ROOT/env.ps1"
if [ ! -f "$ENV_PS1" ]; then
	na "(H2) native-Windows DIY Python provisioning -- env.ps1 not found"
else
	ps_python="$(grep -icE 'python' "$ENV_PS1" || true)"
	if [ "$ps_python" -eq 0 ]; then
		pass "(H2) env.ps1 still provisions no Python, so the DIY-Windows gap is where it is recorded (see nix/python.nix)"
	else
		ps_derived="$(grep -cE 'CODETRACER_PYTHON_(VERSION|CMD|ABI_TAG)|\.python-version' "$ENV_PS1" || true)"
		if [ "$ps_derived" -gt 0 ]; then
			pass "(H2) env.ps1 provisions Python and derives the version from the declaration"
		else
			fail "(H2) env.ps1 provisions Python and derives the version from the declaration" \
				"env.ps1 has $ps_python reference(s) to Python but names neither
codetracer-python-recorder's .python-version nor CODETRACER_PYTHON_VERSION /
_CMD / _ABI_TAG. The native-Windows DIY lane had NO Python provisioning when
this guard was written, and that gap is recorded in nix/python.nix. Starting
to close it means deriving the version, not choosing one here."
		fi
	fi
fi

RECORDER_JUSTFILE="$RECORDER_DIR/Justfile"
if [ ! -f "$RECORDER_JUSTFILE" ]; then
	na "(H3) the recorder's support matrix contains the declared version -- $RECORDER_JUSTFILE not found"
else
	matrix="$(grep -m1 -E '^[[:space:]]*PY_VERSIONS[[:space:]]*:=' "$RECORDER_JUSTFILE" |
		sed -E 's/.*:=[[:space:]]*"([^"]*)".*/\1/' || true)"
	if [ -z "$matrix" ]; then
		fail "(H3) the recorder declares a multi-version support matrix" \
			"no PY_VERSIONS in $RECORDER_JUSTFILE"
	else
		# Membership by `case`, not `grep -q` in a pipeline: `set -o pipefail`
		# plus `grep -q`'s early exit gives the producer SIGPIPE and the
		# pipeline 141, so a SUCCESSFUL match reads as a failure.
		case " $matrix " in
		*" $PIN_VERSION "*)
			pass "(H3) the recorder's support matrix ($matrix) contains the declared $PIN_VERSION"
			;;
		*)
			fail "(H3) the recorder's support matrix contains the declared version" \
				"PY_VERSIONS is '$matrix' but .python-version declares $PIN_VERSION --
the version everything is built against is one nothing tests."
			;;
		esac
	fi
fi

# ---------------------------------------------------------------------------

printf '\n%d checks, %d n/a, %d failure(s)\n' "$checks" "$nas" "$failures"
if [ "$failures" -ne 0 ]; then
	exit 1
fi
