#!/usr/bin/env bash
# =============================================================================
# Contract: `build-siblings.sh` builds each sibling with the `nim` and `nimble`
# THAT SIBLING'S OWN ENVIRONMENT provides, and offers codetracer's only as a
# fallback to a sibling whose environment provides none.
#
#   bash ci/test/sibling-toolchain-precedence-test.sh
#
# WHY THIS FILE EXISTS
#   The script resolves codetracer's own `nim`/`nimble` directories once, up
#   front, so that Nim builds work in sibling dev shells that do not bundle
#   Nim (every blockchain recorder).  It then ran every sibling command as
#   `export PATH="$EXTRA_NIM_PATH:$PATH"; <cmd>` -- PREPENDING codetracer's
#   toolchain, so it replaced the compiler the sibling's own flake pins instead
#   of filling in a missing one.  The header promises the opposite: siblings
#   are built "via `repro exec <repo> -- <cmd>` so each repo's flake pins the
#   toolchain".
#
#   Observed (codetracer-pm issue 2026-10-22-build-siblings-build-ct-mcr-fails-
#   to-compile-ct-cli-against-serialization-0-5-5.md): the
#   codetracer-native-recorder entry compiled ct_cli with codetracer's Nim
#   fork (`nim-fork-2.3.1-codetracer`, whose config puts its own `dist/`
#   nim-stew 0.5.0 on the search path) rather than the recorder's pinned
#   `nim-2.2.8`, and failed with `cannot export: macros.isCaseObject` --
#   while the recorder's own dev shell, same checkout, built it fine.
#
# WHAT IT RUNS
#   The REAL scripts/build-siblings.sh, copied byte-for-byte into a throwaway
#   workspace (the script derives the workspace root from its own location, so
#   it has to be copied rather than invoked in place), against throwaway git
#   repositories for each sibling and the two trace-format repos.
#     (A) codetracer-native-recorder, whose environment provides its own `nim`
#         and `nimble`: the build must resolve THOSE.  Its ct_cli artifact path
#         is read out of the real script, so the test follows the entry if it
#         is renamed.  `--skip launcher-compat-sample` keeps the second entry
#         that `--only codetracer-native-recorder` also matches out of the run.
#     (B) codetracer-beam-recorder, whose environment provides no Nim: the
#         build must still find codetracer's, the documented reason the lookup
#         exists.  Without this arm, deleting the fallback altogether passes.
#   Every run passes `--force`, so the build stamps never skip a build.
#
# MOCKS, AND WHY THEY ARE JUSTIFIED
#   * `repro exec <dir> -- <cmd…>` is a stub that prepends a per-repo
#     directory of stub tools to PATH and then runs <cmd…> unchanged.  That is
#     the one property of a real activation this contract is about -- a dev
#     shell puts ITS toolchain ahead of the ambient PATH -- and the real
#     `repro` would provision Nix dev shells, which needs the network and
#     minutes per repo.  Which directory it prepends is chosen by the repo
#     dir, so `repro exec <codetracer>` (the up-front toolchain lookup) and
#     `repro exec <sibling>` resolve DIFFERENT `nim`s; with a single shared
#     stub, as the sibling suites use, the defect is invisible.  The build's
#     own `bash -c 'cd … && eval …'` wrapper and PATH export run for real.
#   * `nim`/`nimble` are empty stubs: only which file `command -v` resolves is
#     under test, never what the compiler does.
#   * `just` stands in for the sibling's build recipe.  It records the `nim`
#     and `nimble` that PATH resolves inside the build -- the same lookup
#     `nimble build` and `just` make -- and writes the artifact.
#   * `pkg-config` only needs to answer the up-front zstd flag lookup.
#   The ambient PATH is filtered of any directory holding a `nim` or `nimble`,
#   so a host toolchain cannot stand in for either environment's.
#
# THE MUTATION THIS PINS
#   Measured against the unfixed script at codetracer 2453a64f3 (the prepend):
#   (A)'s two contracts fail -- ct_cli resolved codetracer's stub `nim` and
#   `nimble` over the sibling's -- while (B) passes, as it must: the fallback
#   was always there.  (B) would fail only against a script that dropped
#   codetracer's toolchain entirely.
# =============================================================================
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
ok() {
	PASSED=$((PASSED + 1))
	echo "ok   $*"
}
bad() {
	FAILED=$((FAILED + 1))
	echo "FAIL $*" >&2
}
die() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- a throwaway workspace laid out the way the real script expects ---------
WS="$WORK/ws"
BIN="$WORK/stub-bin" # tools every environment sees
ENVS="$WORK/env-bin" # ENVS/<repo>: what `repro exec <repo>` puts first
mkdir -p "$WS/codetracer/scripts" "$BIN" "$ENVS"
cp "$SRC_ROOT/scripts/build-siblings.sh" "$WS/codetracer/scripts/"

# --- stubs -----------------------------------------------------------------
cat >"$BIN/repro" <<'STUB'
#!/usr/bin/env bash
# `repro exec <dir> -- <cmd…>`: activate <dir>'s stub environment, if it has
# one, ahead of the ambient PATH -- as a dev shell does -- then run <cmd…>.
if [ "${1:-}" = "exec" ]; then
  env_bin="${PRECEDENCE_ENVS:?}/$(basename "$2")"
  shift 2
  [ "${1:-}" = "--" ] && shift
  [ -d "$env_bin" ] && export PATH="$env_bin:$PATH"
  exec "$@"
fi
exit 0
STUB
cat >"$BIN/just" <<'STUB'
#!/usr/bin/env bash
# Stands in for the sibling's build recipe: records the toolchain a Nim build
# inside it would resolve, then produces the artifact.
{
  echo "nim=$(command -v nim || echo none)"
  echo "nimble=$(command -v nimble || echo none)"
} > "${PRECEDENCE_MARKER:?}"
mkdir -p "$(dirname "${PRECEDENCE_ARTIFACT:?}")" && echo built > "$PRECEDENCE_ARTIFACT"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/pkg-config"

# provide_nim <repo>: <repo>'s environment carries its own nim and nimble.
provide_nim() {
	mkdir -p "$ENVS/$1"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$ENVS/$1/nim"
	cp "$ENVS/$1/nim" "$ENVS/$1/nimble"
	chmod +x "$ENVS/$1"/*
}
provide_nim codetracer
chmod +x "$BIN"/*

# The ambient PATH, minus anything that already holds a nim or nimble.
clean_path=""
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
	[ -n "$d" ] || continue
	if [ -x "$d/nim" ] || [ -x "$d/nimble" ]; then continue; fi
	clean_path="${clean_path:+$clean_path:}$d"
done
export PATH="$BIN:$clean_path"
export PRECEDENCE_ENVS="$ENVS"
command -v nim >/dev/null && die "a nim is still on the ambient PATH: $(command -v nim)"

seed_repo() { # <repo>
	mkdir -p "$WS/$1"
	git -C "$WS/$1" init -q
	git -C "$WS/$1" config user.email t@e.invalid
	git -C "$WS/$1" config user.name T
	git -C "$WS/$1" config commit.gpgsign false
	echo one >"$WS/$1/src.txt"
	git -C "$WS/$1" add src.txt
	git -C "$WS/$1" commit -qm one
}
seed_repo codetracer-trace-format
seed_repo codetracer-trace-format-nim

# artifact_of <sibling>: the entry's artifact path, read out of the real
# script (see ci/test/sibling-artifact-freshness-test.sh for why awk).
artifact_of() {
	awk -v sib="$1" '
		/^build_sibling / {
			getline name
			gsub(/[[:space:]]|\\/, "", name)
			if (name == sib) {
				getline artifact
				gsub(/[[:space:]]|\\/, "", artifact)
				print artifact
				exit
			}
		}' "$WS/codetracer/scripts/build-siblings.sh"
}

# run_case <tag> <sibling> [extra args…]: one --force run of the real script.
run_case() {
	local tag="$1" sib="$2" art
	shift 2
	art="$(artifact_of "$sib")"
	[ -n "$art" ] || die "could not find the $sib entry's artifact in the real script"
	seed_repo "$sib"
	export PRECEDENCE_MARKER="$WORK/toolchain.$tag"
	export PRECEDENCE_ARTIFACT="$WS/$sib/$art"
	(cd "$WS/codetracer" && bash scripts/build-siblings.sh --only "$sib" --force "$@") \
		>"$WORK/out.$tag" 2>&1 || true
	[ -f "$PRECEDENCE_MARKER" ] || die "($tag) the $sib build never ran: $(tail -8 "$WORK/out.$tag" | tr '\n' ' ')"
	echo "exercised '$sib' → '$art': $(tr '\n' ' ' <"$PRECEDENCE_MARKER")"
}

# expect_tool <tag> <tool> <expected path> <description>
expect_tool() {
	local got
	got="$(sed -n "s/^$2=//p" "$WORK/toolchain.$1")"
	if [ "$got" = "$3" ]; then
		ok "$4"
	else
		bad "$4: resolved $got, expected $3"
	fi
}

# --- (A) THE DEFECT: the sibling's own toolchain wins -----------------------
provide_nim codetracer-native-recorder
run_case A codetracer-native-recorder --skip launcher-compat-sample
expect_tool A nim "$ENVS/codetracer-native-recorder/nim" \
	"(A) a sibling whose environment provides nim is built with ITS nim, not codetracer's"
expect_tool A nimble "$ENVS/codetracer-native-recorder/nimble" \
	"(A) ...and with its nimble, not codetracer's"

# --- (B) the fallback: no Nim in the sibling's environment ------------------
run_case B codetracer-beam-recorder
expect_tool B nim "$ENVS/codetracer/nim" \
	"(B) a sibling whose environment provides no nim still gets codetracer's"
expect_tool B nimble "$ENVS/codetracer/nimble" \
	"(B) ...and codetracer's nimble"

echo ""
if [ "$FAILED" -ne 0 ]; then
	echo "FAIL: $FAILED of $((PASSED + FAILED)) contracts failed" >&2
	exit 1
fi
echo "PASS: build-siblings prefers each sibling's own nim/nimble over codetracer's ($PASSED contracts)"
