#!/usr/bin/env bash
# shellcheck disable=SC2016
# The diagnostics below quote shell commands, environment variables and paths
# in backticks for the reader. They are prose, not command substitutions, so
# the single quotes are deliberate and SC2016 does not apply.
# =============================================================================
# toolchain-pins.sh — say WHICH COMPILER ANSWERED, and refuse when the answer
# cannot be attributed to a commit.
#
# ## The defect this exists to close
#
# `scripts/sibling-pins.sh` pins three REPOSITORIES and says so on its own
# `RESULT: PASSED` line: "SCOPE: N repositories, not the toolchain. This is NOT
# a claim that the build is reproducible." That honesty is why the gap below is
# known rather than suspected. This file is the other half.
#
# A toolchain that resolves to mutable state makes a measurement right about a
# compiler nobody ships. Three confirmed shapes of it, each measured on this
# workstation:
#
#   1. THE AMBIENT COMPILER. `nim` outside the dev shell is 2.2.4 from
#      `~/.nix-profile/bin/nim`; inside it is 2.2.8 from
#      `/nix/store/…-nim-2.2.8/bin/nim`. Note that BOTH are `/nix/store` paths
#      after symlink resolution — `~/.nix-profile/bin/nim` is a symlink into
#      the store — so "is this binary from the Nix store?" does not separate
#      them and a check built on that question passes over the defect. The
#      classification below therefore reads the UNRESOLVED `command -v` path,
#      and resolves symlinks only afterwards, to name the store path.
#
#      The mechanism is mundane and hits every agent: a fresh `git worktree`
#      has an `.envrc` that `direnv` has never been allowed to run, so
#      `direnv exec <worktree> …` fails with "is blocked. Run `direnv allow`",
#      and a caller that proceeds anyway gets the profile's compiler. That was
#      measured in the worktree this file was written in, before `direnv allow`
#      was run there.
#
#   2. THE STALE BINARY. `nargo` in a workspace dev shell is not the flake's
#      nargo. `scripts/detect-siblings.sh` prepends `../noir/target/release` to
#      PATH when that binary exists, so what answers is a RELEASE BUILD OF A
#      SIBLING WORKING COPY. When this file was written, that binary reported
#      `git version hash: 906af2f4…` while the checkout it came from had moved
#      five commits on to 61960c8e — so the compiler answering was not any
#      commit of the tree the developer was looking at.
#
#   3. THE DIVERGED CHECKOUT. The same sibling is 3,694 commits ahead of and
#      568 commits behind the `noir` revision `flake.lock` pins (beta.26
#      against beta.2, ~251k insertions apart, in the ACIR-generating paths).
#      `ci/deploy/noir-wasm.pin` states outright that the flake's noir pin "is
#      NOT this one".
#
# What this cost: a constant shipped to users that no user's engine computes,
# a spec argument built on that constant, a nine-hour investigation into a
# renderer "build break" that was one machine's compiler, and a near-miss where
# a correct fix was almost reverted.
#
# ## The rule, and where it is enforced
#
#   ANY SCRIPT WHOSE NUMBER LANDS IN SOURCE OR IN A SPEC MUST PRINT THE
#   TOOLCHAIN REVISION BESIDE IT, AND MUST REFUSE WHEN THE RESOLVED TOOLCHAIN
#   IS A DIRTY OR DIVERGED WORKING COPY.
#
# `--require <tool>…` is that rule as one command: it verifies STRICTLY and
# then prints the one-line stamp, and there is no way to obtain the stamp
# without having passed the refusal. A measurement script calls it, and puts
# the line it prints next to the number.
#
# The first caller is `ci/deploy/build-noir-wasm.sh`, WHICH EXISTS ONLY ON THE
# `cloud` MAINLINE — said here explicitly because this file is identical on both
# and a reader on `dev` would otherwise go looking for a path that is not there.
# Its `EXPECT_COMPILER_BYTES` / `EXPECT_TRACER_BYTES` land in a tracked file, and
# its own pin file already records that "a rustc bump moves them further", which
# is the toolchain reaching a committed number. There is no such caller on `dev`
# yet; the rule is stated here and enforced wherever it is invoked, not assumed
# to be in force everywhere.
#
# ## What is pinned, what is verified, and why the split is drawn here
#
# PINNED — by `flake.lock`, already, per-commit, before this file existed. The
# Nim compiler is `codetracer-toolchains`' `nim-2_2` (`nix/packages/default.nix`
# wraps it as `nim-codetracer`); `rustc`/`cargo` are `fenix`'s stable toolchain
# combined in `nix/shells/ci-base.nix`. Both are root inputs with 40-hex locked
# revs. There was never a missing pin here. What was missing was any statement
# of WHICH COMPILER THE COMMIT EXPECTS that a build could be held to without
# evaluating the flake — so `ci/toolchain.pin` adds that, as a redundant
# restatement whose only job is to make drift a DIFF, cross-checked against
# `flake.lock` on every run so it cannot silently lag.
#
# VERIFIED — that the compiler which actually answered is that one. This is
# the arm that is not circular, exactly as in `sibling-pins.sh`: resolving a
# pin out of `flake.lock` and comparing it to `flake.lock` proves nothing.
#
# REFUSED — ambient compilers, stale sibling binaries, dirty sibling trees, a
# shell that is not this repository's dev shell, and a rotted `ci/toolchain.pin`.
#
# REPORTED BUT NOT REFUSED, in `--verify` — a sibling checkout that has
# diverged from the flake pin. In this workspace that divergence is DELIBERATE:
# `.envrc` sets `NIX_FLAKE_OVERRIDE_AUTO=1`, which overrides every flake input
# that has a same-named sibling directory, and `detect-siblings.sh` puts the
# sibling's own build on PATH ahead of it. Failing on that would fail every
# developer every day for a condition the workspace is designed to produce, and
# the first person to meet it would delete the check. `--require` DOES refuse
# on it, because a number that lands in a tracked file must be attributable to
# a revision and "some working copy, somewhere ahead of the pin" is not one.
#
# ## What this does NOT cover — read this before quoting the PASSED line
#
#   * A VERSION STRING IS NOT AN IDENTITY. `--verify` compares
#     `nim --version` against `ci/toolchain.pin`. Two Nim 2.2.8 builds from
#     different sources report the same string. `--strict` closes this by
#     comparing the resolved store path against `nix eval` of this flake's
#     `nim-codetracer`, and needs a working `nix` and a flake evaluation.
#     Plain `--verify` does not, and says so on its passing line.
#
#   * NIM SELF-REPORTS NO REVISION. `nargo` prints its build commit and
#     `rustc` prints its upstream commit, so both can be held to one. A Nim
#     built from a release tarball has no git hash to print, so for Nim the
#     strongest per-binary evidence available without nix is the version string
#     plus the store path. Named here and on the passing line.
#
#   * THE FORK QUESTION IS ANSWERED, NOT ASSUMED. `flake.lock` carries a
#     `nim-fork-src` node (`metacraft-labs/nim`, ref `codetracer`) and the
#     obvious reading is that it is the compiler. It is not: it is an input of
#     `reprobuild` and of nothing else, and the dev shell's `nim` derives from
#     `https://nim-lang.org/download/nim-2.2.8.tar.xz`. That was measured
#     through `nix-store -q --deriver` and `nix derivation show`. The
#     REACHABILITY half is re-checked on every run below (`nim-fork-src` must
#     not become reachable from `codetracer-toolchains`); the derivation half
#     is a one-time measurement recorded in `ci/toolchain.pin`, and its staleness
#     is bounded by the `LOCK_CODETRACER_TOOLCHAINS` cross-check.
#
#   * IT COVERS THE TOOLS IT NAMES. `TOOLS` below is a list. C/C++ (`CT_TEST_CC`
#     is a clang-wrapper store path), Go, the recorder toolchains and the Nim
#     package set are not in it. A pass here is not "the build is reproducible".
#
# ## Modes
#
#   toolchain-pins.sh                    -> the stamp, as a readable block
#   toolchain-pins.sh --line             -> the stamp, as one line
#   toolchain-pins.sh --verify           -> refuse if the answer is unattributable
#   toolchain-pins.sh --strict           -> --verify plus the nix store-path check
#   toolchain-pins.sh --require [tool…]  -> strict verify, then --line. THE RULE.
#   toolchain-pins.sh --devshell-init    -> did the dev shell ever run HERE?
#
# Run: bash scripts/toolchain-pins.sh --verify
# Contract suite: ci/test/toolchain-pins-test.sh
# Sibling guard:  scripts/sibling-pins.sh (repositories; disjoint from this)
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/flake.lock"
PIN="$REPO_ROOT/ci/toolchain.pin"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." 2>/dev/null && pwd || echo "")"

# The one seam, and the reason it is safe to have.
#
# `ci/test/toolchain-pins-test.sh` has to exercise the STORE branch of the
# classifier, and it cannot write into `/nix/store`. Everything else the suite
# needs is already environment (HOME for the ambient prefixes, a temp git repo
# for the worktree class), so this is the single override.
#
# It is not a bypass, for two reasons that are both enforced below: setting it
# does not make any check pass that would otherwise fail — it only moves where
# "the store" is — and a non-default value is PRINTED on the RESULT line, so a
# run that quietly redefined the store cannot report a clean pass that reads
# like a normal one.
STORE_PREFIX="${TOOLCHAIN_PINS_STORE_PREFIX:-/nix/store}"

# The tools this guard covers.
#
#   <tool>|<required|optional>|<flake root input, or empty>
#
# `required` means "absent is a FAILURE". An absent tool that reads as a skip
# is how an unchecked build passes a toolchain check — the same failure mode
# `sibling-pins.sh` calls out for an absent sibling directory, and it is the
# single most likely real-world state when the dev shell did not load.
#
# `nargo` is optional-when-absent (the noir sibling is a runtime sibling; see
# `scripts/detect-siblings.sh`, which treats it as advisory) but is NEVER
# skippable when present: a present-and-stale nargo is defect shape 2 above.
TOOLS=(
	"nim|required|"
	"rustc|required|"
	"cargo|required|"
	"nargo|optional|noir"
)

# Prefixes that mean "this binary did not come from a dev shell of this
# repository". Matched against the UNRESOLVED `command -v` answer, because
# every one of these is a symlink farm into `/nix/store` and resolving first
# would erase the distinction that matters.
AMBIENT_PREFIXES=(
	"$HOME/.nix-profile/"
	"$HOME/.local/state/nix/profiles/"
	"$HOME/.cargo/"
	"$HOME/.rustup/"
	"/nix/var/nix/profiles/"
	"/run/current-system/"
	"/etc/profiles/per-user/"
	"/usr/bin/"
	"/usr/local/"
	"/opt/homebrew/"
	"/bin/"
	"/sbin/"
)

die() {
	printf 'toolchain-pins: %s\n' "$1" >&2
	exit 2
}

# Exit 2 is reserved for "this guard could not run" (missing python3, missing
# flake.lock, bad arguments) and exit 1 for "the toolchain is unattributable".
# Collapsing the two is how a tooling failure gets read as a verdict about a
# compiler, and sends the reader to edit the pin that was protecting them.

# --- reading ci/toolchain.pin ------------------------------------------------
#
# Read with a line-shaped parser rather than `source`, because this file is
# consulted by a guard: `source` would execute whatever a mistyped or
# maliciously-edited line happened to be, inside the very script whose job is
# to refuse things.
PIN_NIM_VERSION=""
PIN_NIM_SOURCE=""
PIN_RUSTC_VERSION=""
PIN_RUSTC_COMMIT=""
PIN_LOCK_TOOLCHAINS=""
PIN_LOCK_FENIX=""
PIN_LOCK_NOIR=""
PIN_HOST=""

read_pin() {
	[ -f "$PIN" ] || die "the toolchain declaration is missing at $PIN.
  Without it there is nothing to hold a compiler to, and this guard will not
  invent an expectation — a check with no expected value passes over every
  compiler equally."
	local line key value
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'#'* | '') continue ;;
		esac
		key="${line%%=*}"
		value="${line#*=}"
		case "$key" in
		EXPECT_NIM_VERSION) PIN_NIM_VERSION="$value" ;;
		EXPECT_NIM_SOURCE) PIN_NIM_SOURCE="$value" ;;
		EXPECT_RUSTC_VERSION) PIN_RUSTC_VERSION="$value" ;;
		EXPECT_RUSTC_COMMIT) PIN_RUSTC_COMMIT="$value" ;;
		LOCK_CODETRACER_TOOLCHAINS) PIN_LOCK_TOOLCHAINS="$value" ;;
		LOCK_FENIX) PIN_LOCK_FENIX="$value" ;;
		LOCK_NOIR) PIN_LOCK_NOIR="$value" ;;
		TOOLCHAIN_HOST_MEASURED) PIN_HOST="$value" ;;
		esac
	done <"$PIN"

	local missing=""
	[ -n "$PIN_NIM_VERSION" ] || missing="$missing EXPECT_NIM_VERSION"
	[ -n "$PIN_RUSTC_VERSION" ] || missing="$missing EXPECT_RUSTC_VERSION"
	[ -n "$PIN_LOCK_TOOLCHAINS" ] || missing="$missing LOCK_CODETRACER_TOOLCHAINS"
	[ -n "$PIN_LOCK_FENIX" ] || missing="$missing LOCK_FENIX"
	[ -n "$PIN_LOCK_NOIR" ] || missing="$missing LOCK_NOIR"
	[ -z "$missing" ] || die "$PIN is missing:$missing
  Every one of these is load-bearing. A pin file that declares only some of
  what it is asked about would let this guard report a pass having compared
  the rest against nothing."
}

# --- reading flake.lock ------------------------------------------------------
#
# Three root-input revisions, plus the answer to "is nim-fork-src reachable
# from codetracer-toolchains?". As in `sibling-pins.sh`, the lookup goes
# through the ROOT INPUT NAME and not the node key: nix disambiguates
# same-named nodes with a numeric suffix, so `nodes["fenix"]` is a DIFFERENT
# input's copy and the wrong rev it returns is indistinguishable from a right
# one. Always root.inputs[name] -> node.
LOCK_TOOLCHAINS=""
LOCK_FENIX=""
LOCK_NOIR=""
LOCK_NIM_FORK=""
LOCK_NIM_FORK_OWNERS=""

read_lock() {
	[ -f "$LOCK" ] || die "flake.lock is missing at $LOCK; the revisions this
  guard checks the declaration against are not available."
	local out rc
	out="$(python3 -c '
import json, sys

path = sys.argv[1]
try:
    with open(path) as handle:
        data = json.load(handle)
    nodes = data["nodes"]
    root_key = data["root"]
    root = nodes[root_key]["inputs"]
except Exception as exc:  # noqa: BLE001 - reported verbatim by the caller
    print("PARSE-ERROR %s" % exc)
    raise SystemExit(0)


def deref(key):
    return key[0] if isinstance(key, list) else key


for name in ("codetracer-toolchains", "fenix", "noir"):
    key = root.get(name)
    if key is None:
        print("MISSING %s not-a-root-input" % name)
        continue
    rev = nodes.get(deref(key), {}).get("locked", {}).get("rev", "")
    if not rev:
        print("MISSING %s no-locked-rev" % name)
        continue
    print("REV %s %s" % (name, rev))

# The fork question, re-asked on every run. `nim-fork-src` is a node in this
# lock; what matters is WHICH ROOT INPUTS CAN REACH IT. If it is reachable
# only from `reprobuild` it builds `repro`. If it ever becomes reachable from
# `codetracer-toolchains`, the compiler that builds CodeTracer may be the
# fork, and ci/toolchain.pin EXPECT_NIM_SOURCE=upstream would be a false
# statement -- so the guard must fail rather than keep asserting it.
fork = nodes.get("nim-fork-src")
if fork is None:
    print("FORK absent")
else:
    print("FORK %s" % (fork.get("locked", {}).get("rev", "?"),))
    owners = []
    for name, key in root.items():
        seen = set()
        stack = [deref(key)]
        hit = False
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            if cur == "nim-fork-src":
                hit = True
                break
            for child in nodes.get(cur, {}).get("inputs", {}).values():
                stack.append(deref(child))
        if hit:
            owners.append(name)
    print("FORK-OWNERS %s" % (",".join(sorted(owners)) or "none"))
' "$LOCK" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || die "could not run python3 over '$LOCK' (exit $rc). This is a
  parse/tooling failure, NOT a statement about any toolchain — do not read it
  as 'the compiler is unpinned'. Parser output:
$out"

	case "$out" in
	PARSE-ERROR*) die "flake.lock at $LOCK did not parse as JSON: ${out#PARSE-ERROR }" ;;
	esac

	local line problems=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
		"REV codetracer-toolchains "*) LOCK_TOOLCHAINS="${line##* }" ;;
		"REV fenix "*) LOCK_FENIX="${line##* }" ;;
		"REV noir "*) LOCK_NOIR="${line##* }" ;;
		"FORK-OWNERS "*) LOCK_NIM_FORK_OWNERS="${line#FORK-OWNERS }" ;;
		"FORK "*) LOCK_NIM_FORK="${line#FORK }" ;;
		"MISSING "*) problems="$problems
  - ${line#MISSING }" ;;
		*) problems="$problems
  - unrecognised resolver output: $line" ;;
		esac
	done <<<"$out"

	[ -z "$problems" ] || die "flake.lock does not pin every toolchain-determining
  root input:$problems

  These are the inputs that DETERMINE the compilers: 'codetracer-toolchains'
  supplies nim-2_2 and 'fenix' supplies rustc/cargo. If one was renamed in
  flake.nix, update this script and ci/toolchain.pin together — leaving them
  disagreeing makes the guard check a compiler nothing builds with."
}

# --- resolving one tool ------------------------------------------------------
#
# Filled by `probe_tool`, read by every caller. Bash 3.2 (the macOS default)
# has no associative arrays, so these are plain parallel scalars reset per
# tool rather than a map.
T_NAME=""
T_WHERE=""    # the unresolved `command -v` answer
T_REAL=""     # symlinks resolved
T_STORE=""    # the /nix/store/<hash>-<name> component, when there is one
T_CLASS=""    # absent | ambient | store | worktree | unknown
T_VERSION=""  # the version string the binary reports
T_SELFREV=""  # the build revision the binary self-reports, when it does
T_DIRTYBIT="" # the dirty flag the binary self-reports, when it does
T_REPO=""     # the git checkout containing the binary, for class=worktree
T_HEAD=""
T_DIRTY=""

realpath_of() {
	python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

classify_path() {
	local where="$1" prefix
	case "$where" in
	"$STORE_PREFIX"/*) T_CLASS=store ;;
	*)
		T_CLASS=unknown
		for prefix in "${AMBIENT_PREFIXES[@]}"; do
			[ -n "$prefix" ] || continue
			case "$where" in
			"$prefix"*)
				T_CLASS=ambient
				return
				;;
			esac
		done
		# Inside the workspace, and inside a git checkout => a working-copy
		# build. This is the `../noir/target/release/nargo` shape.
		if [ -n "$WORKSPACE_ROOT" ]; then
			case "$where" in
			"$WORKSPACE_ROOT"/*)
				local top
				top="$(git -C "$(dirname "$where")" rev-parse --show-toplevel 2>/dev/null)"
				if [ -n "$top" ]; then
					T_CLASS=worktree
					T_REPO="$top"
					T_HEAD="$(git -C "$top" rev-parse HEAD 2>/dev/null)"
					T_DIRTY="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
				fi
				;;
			esac
		fi
		;;
	esac
}

probe_tool() {
	T_NAME="$1"
	T_WHERE=""
	T_REAL=""
	T_STORE=""
	T_CLASS=absent
	T_VERSION=""
	T_SELFREV=""
	T_DIRTYBIT=""
	T_REPO=""
	T_HEAD=""
	T_DIRTY=""

	T_WHERE="$(command -v "$T_NAME" 2>/dev/null)"
	[ -n "$T_WHERE" ] || return 0

	classify_path "$T_WHERE"
	T_REAL="$(realpath_of "$T_WHERE")"
	case "$T_REAL" in
	"$STORE_PREFIX"/*)
		# <store>/<hash>-<name>/…  -> keep the store prefix plus one component.
		T_STORE="$STORE_PREFIX/$(printf '%s' "${T_REAL#"$STORE_PREFIX"/}" | cut -d/ -f1)"
		;;
	esac

	local raw
	case "$T_NAME" in
	nim)
		raw="$("$T_WHERE" --version 2>/dev/null)"
		# "Nim Compiler Version 2.2.8 [MacOSX: arm64]"
		T_VERSION="$(printf '%s\n' "$raw" | sed -n '1s/.*Version \([^ ]*\).*/\1/p')"
		# A git build prints "git hash: <sha>"; a release tarball does not.
		T_SELFREV="$(printf '%s\n' "$raw" | sed -n 's/.*git hash: \([0-9a-f]\{7,40\}\).*/\1/p' | head -1)"
		;;
	rustc | cargo)
		raw="$("$T_WHERE" --version 2>/dev/null)"
		# "rustc 1.96.0 (ac68faa20 2026-05-25)"
		T_VERSION="$(printf '%s\n' "$raw" | awk '{print $2}')"
		T_SELFREV="$(printf '%s\n' "$raw" | sed -n 's/.*(\([0-9a-f]\{7,40\}\).*/\1/p' | head -1)"
		;;
	nargo)
		raw="$("$T_WHERE" --version 2>/dev/null)"
		# "nargo version = 1.0.0-beta.26"
		# "(git version hash: 906af2f4…, is dirty: false)"
		T_VERSION="$(printf '%s\n' "$raw" | sed -n 's/^nargo version = \(.*\)$/\1/p' | head -1)"
		T_SELFREV="$(printf '%s\n' "$raw" | sed -n 's/.*git version hash: \([0-9a-f]\{7,40\}\).*/\1/p' | head -1)"
		T_DIRTYBIT="$(printf '%s\n' "$raw" | sed -n 's/.*is dirty: \([a-z]*\).*/\1/p' | head -1)"
		;;
	*)
		raw="$("$T_WHERE" --version 2>/dev/null)"
		T_VERSION="$(printf '%s\n' "$raw" | head -1)"
		;;
	esac
	[ -n "$T_VERSION" ] || T_VERSION="unreadable"
}

tool_field() {
	local entry="$1" index="$2"
	printf '%s' "$entry" | cut -d'|' -f"$index"
}

# --- the stamp ---------------------------------------------------------------

short() { printf '%s' "${1:0:8}"; }

stamp_block() {
	read_pin
	read_lock
	printf 'toolchain stamp — the compilers that answered here\n'
	printf '  host:        %s\n' "$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"
	printf '  repo:        %s\n' "$REPO_ROOT"
	printf '  dev shell:   IN_NIX_SHELL=%s DIRENV_FILE=%s\n' \
		"${IN_NIX_SHELL:-<unset>}" "${DIRENV_FILE:-<unset>}"
	local entry name
	for entry in "${TOOLS[@]}"; do
		name="$(tool_field "$entry" 1)"
		probe_tool "$name"
		if [ "$T_CLASS" = absent ]; then
			printf '  %-10s ABSENT (not on PATH)\n' "$name:"
			continue
		fi
		printf '  %-10s %s\n' "$name:" "$T_VERSION"
		printf '    from     %s  [%s]\n' "$T_WHERE" "$T_CLASS"
		[ -n "$T_STORE" ] && printf '    store    %s\n' "$T_STORE"
		[ -n "$T_SELFREV" ] && printf '    self-rev %s%s\n' "$T_SELFREV" \
			"$([ -n "$T_DIRTYBIT" ] && printf ' (dirty: %s)' "$T_DIRTYBIT")"
		if [ "$T_CLASS" = worktree ]; then
			printf '    checkout %s HEAD=%s dirty=%s\n' "$T_REPO" "$T_HEAD" "$T_DIRTY"
		fi
	done
	printf '  flake.lock:  codetracer-toolchains=%s fenix=%s noir=%s\n' \
		"$LOCK_TOOLCHAINS" "$LOCK_FENIX" "$LOCK_NOIR"
	printf '  nim-fork-src: %s (reachable from: %s)\n' \
		"${LOCK_NIM_FORK:-absent}" "${LOCK_NIM_FORK_OWNERS:-none}"
	printf '  declaration: %s (measured on %s)\n' "$PIN" "${PIN_HOST:-?}"
}

# The one-line stamp — the thing that goes next to a number.
#
# Takes the tools that were VERIFIED, when it is called after a scoped
# `--require`. Tools outside that scope are still printed (the reader wants
# the whole environment) but are listed separately under `not-verified:`,
# because a stamp that lists a compiler is read as vouching for it. Printing
# `nargo=…` beside `rustc=…` after a run that only held rustc to anything
# would be this guard committing the overstatement it exists to prevent.
stamp_line() {
	read_pin
	read_lock
	local scoped=("$@")
	local out="" unverified="" entry name sep="" desc in_scope want storename
	for entry in "${TOOLS[@]}"; do
		name="$(tool_field "$entry" 1)"
		probe_tool "$name"
		storename="${T_STORE##*/}"
		if [ "$T_CLASS" = absent ]; then
			desc="$name=absent"
		elif [ "$T_CLASS" = worktree ]; then
			desc="$name=$T_VERSION@$(short "${T_SELFREV:-unknown}")[worktree $(basename "$T_REPO")@$(short "$T_HEAD")]"
		else
			desc="$name=${T_VERSION}[$storename]"
		fi
		in_scope=1
		if [ "${#scoped[@]}" -gt 0 ]; then
			in_scope=0
			for want in "${scoped[@]}"; do
				[ "$want" = "$name" ] && in_scope=1
			done
		fi
		if [ "$in_scope" -eq 1 ]; then
			out="$out${sep}$desc"
			sep=" "
		else
			unverified="$unverified $desc"
		fi
	done
	printf 'TOOLCHAIN: %s | lock: toolchains=%s fenix=%s noir=%s | host %s-%s%s\n' \
		"$out" "$(short "$LOCK_TOOLCHAINS")" "$(short "$LOCK_FENIX")" "$(short "$LOCK_NOIR")" \
		"$(uname -m)" "$(uname -s | tr '[:upper:]' '[:lower:]')" \
		"${unverified:+ | not-verified:$unverified}"
}

# --- verification ------------------------------------------------------------

FAILED=0
CHECKED=0
NOTES=0

fail() {
	FAILED=$((FAILED + 1))
	printf '  FAIL  %s\n' "$1" >&2
	shift
	local extra
	for extra in "$@"; do printf '        %s\n' "$extra" >&2; done
}

note() {
	NOTES=$((NOTES + 1))
	printf '  NOTE  %s\n' "$1"
	shift
	local extra
	for extra in "$@"; do printf '        %s\n' "$extra"; done
}

ok() { printf '  ok    %s\n' "$1"; }

# The declaration must still describe the lock it was measured against.
verify_declaration() {
	CHECKED=$((CHECKED + 1))
	local drift=0
	[ "$PIN_LOCK_TOOLCHAINS" = "$LOCK_TOOLCHAINS" ] || {
		drift=1
		fail "ci/toolchain.pin records codetracer-toolchains=$PIN_LOCK_TOOLCHAINS" \
			"but flake.lock now says $LOCK_TOOLCHAINS."
	}
	[ "$PIN_LOCK_FENIX" = "$LOCK_FENIX" ] || {
		drift=1
		fail "ci/toolchain.pin records fenix=$PIN_LOCK_FENIX" \
			"but flake.lock now says $LOCK_FENIX."
	}
	[ "$PIN_LOCK_NOIR" = "$LOCK_NOIR" ] || {
		drift=1
		fail "ci/toolchain.pin records noir=$PIN_LOCK_NOIR" \
			"but flake.lock now says $LOCK_NOIR."
	}
	if [ "$drift" -ne 0 ]; then
		printf '        The declaration is a restatement of what flake.lock implies, and it\n' >&2
		printf '        has lagged it. Re-measure rather than editing the LOCK_ lines alone:\n' >&2
		printf '          nix develop -c bash scripts/toolchain-pins.sh --stamp\n' >&2
		printf '        and copy BOTH the versions and the revisions into ci/toolchain.pin.\n' >&2
		printf '        Editing only the revisions turns the file into a claim that the\n' >&2
		printf '        recorded versions were observed at revisions nobody observed them at.\n' >&2
		return
	fi
	ok "ci/toolchain.pin still describes flake.lock (toolchains=$(short "$LOCK_TOOLCHAINS") fenix=$(short "$LOCK_FENIX") noir=$(short "$LOCK_NOIR"))"
}

# The fork question, as a live assertion rather than a remembered conclusion.
verify_fork_reachability() {
	CHECKED=$((CHECKED + 1))
	if [ -z "$LOCK_NIM_FORK" ] || [ "$LOCK_NIM_FORK" = absent ]; then
		ok "flake.lock has no nim-fork-src node; EXPECT_NIM_SOURCE has nothing to contradict it"
		return
	fi
	case ",$LOCK_NIM_FORK_OWNERS," in
	*,codetracer-toolchains,*)
		if [ "$PIN_NIM_SOURCE" = upstream ]; then
			fail "nim-fork-src ($LOCK_NIM_FORK) is now reachable from codetracer-toolchains," \
				"which is the input that supplies this repo's Nim — but ci/toolchain.pin" \
				"declares EXPECT_NIM_SOURCE=upstream." \
				"" \
				"One of the two is wrong and this guard cannot tell which, so it refuses" \
				"rather than keep asserting a source it can no longer support. Re-measure:" \
				'  nix-store -q --deriver "$(command -v nim)"' \
				"  nix derivation show <that .drv> | python3 -c 'import json,sys; …'" \
				"and set EXPECT_NIM_SOURCE to what the src actually is."
		else
			ok "nim-fork-src is reachable from codetracer-toolchains, and EXPECT_NIM_SOURCE=$PIN_NIM_SOURCE agrees"
		fi
		;;
	*)
		ok "nim-fork-src ($(short "$LOCK_NIM_FORK")) is reachable only from: ${LOCK_NIM_FORK_OWNERS:-none} — not from the input that supplies Nim"
		;;
	esac
}

# The dev shell itself. This is the check that would have closed the renderer
# investigation in one command.
verify_shell() {
	CHECKED=$((CHECKED + 1))
	if [ -z "${IN_NIX_SHELL:-}" ]; then
		fail "IN_NIX_SHELL is unset: this is not a Nix dev shell." \
			'Whatever answers `nim` and `cargo` here is the ambient environment,' \
			'not the one this commit specifies. In a fresh `git worktree` the usual' \
			'cause is that direnv has never been allowed HERE — `.envrc` is blocked' \
			"per-directory, and a caller that ignores that failure silently gets the" \
			"profile's compiler." \
			"  remedy: cd $REPO_ROOT && direnv allow" \
			"      or: nix develop '$REPO_ROOT?submodules=1' --command <cmd>"
		return
	fi
	# A shell can be a dev shell and be somebody else's. `build.rs` shells out
	# to `direnv exec <recorder-root>`, and CI has run `nix develop <sibling>`;
	# see ci/test/direnv-provenance-test.sh for the run that died that way.
	if [ -n "${DIRENV_FILE:-}" ] && [ "${DIRENV_FILE}" != "$REPO_ROOT/.envrc" ]; then
		fail "DIRENV_FILE=$DIRENV_FILE, which is not $REPO_ROOT/.envrc." \
			"This is a dev shell, but it belongs to a different checkout, so the" \
			"compilers on PATH are that checkout's and are not determined by this" \
			"commit's flake.lock."
		return
	fi
	ok "dev shell: IN_NIX_SHELL=$IN_NIX_SHELL, DIRENV_FILE=${DIRENV_FILE:-<unset, non-direnv lane>}"
}

# One tool.
verify_tool() {
	local entry="$1" strict="$2"
	local name required flake_input
	name="$(tool_field "$entry" 1)"
	required="$(tool_field "$entry" 2)"
	flake_input="$(tool_field "$entry" 3)"

	probe_tool "$name"
	CHECKED=$((CHECKED + 1))

	if [ "$T_CLASS" = absent ]; then
		if [ "$required" = required ]; then
			fail "$name is not on PATH at all." \
				"An absent compiler is not a skip. A guard that reads it as one is how a" \
				"build with no toolchain passes a toolchain check."
		else
			ok "$name is absent (declared optional; it is a runtime sibling, see scripts/detect-siblings.sh)"
		fi
		return
	fi

	case "$T_CLASS" in
	ambient)
		# The second line is written from what was MEASURED for this binary, not
		# from a template. `~/.nix-profile/bin/nim` really does resolve into the
		# store and that is the whole point of saying so; `~/.cargo/bin/rustc`
		# does not, and printing "RESOLVES INTO /nix/store ()" there would be a
		# guard asserting something it did not observe.
		if [ -n "$T_STORE" ]; then
			fail "$name resolves to $T_WHERE — an ambient install, not this repo's dev shell." \
				"It reports $T_VERSION. Note that this path RESOLVES INTO the store" \
				"($T_STORE), so a check asking only 'is it from the store?' would have" \
				"passed over it. This is the 2.2.4-against-2.2.8 shape." \
				"  remedy: run inside the dev shell — direnv allow, or nix develop."
		else
			fail "$name resolves to $T_WHERE — an ambient install, not this repo's dev shell." \
				"It reports $T_VERSION, and resolves to $T_REAL, outside $STORE_PREFIX entirely." \
				"  remedy: run inside the dev shell — direnv allow, or nix develop."
		fi
		return
		;;
	unknown)
		fail "$name resolves to $T_WHERE, which this guard cannot attribute." \
			"It is neither a $STORE_PREFIX path nor a build inside a git checkout under" \
			"$WORKSPACE_ROOT, so nothing here can say which commit produced it."
		return
		;;
	worktree)
		# A build of a sibling working copy. This is legitimate in a workspace
		# dev shell — detect-siblings.sh puts it there on purpose — but it is
		# only attributable while the binary and its checkout agree.
		local bad=0
		if [ "$T_DIRTY" != "0" ]; then
			bad=1
			fail "$name is a build of $T_REPO, which has $T_DIRTY uncommitted change(s)." \
				"A dirty tree is not any commit, so no revision describes the compiler" \
				"that answered."
		fi
		if [ "$T_DIRTYBIT" = "true" ]; then
			bad=1
			fail "$name self-reports \`is dirty: true\`: it was built from a modified tree." \
				"The revision it prints ($T_SELFREV) does not describe its own sources."
		fi
		if [ -n "$T_SELFREV" ] && [ -n "$T_HEAD" ]; then
			case "$T_HEAD" in
			"$T_SELFREV"*)
				: # the binary is the checkout
				;;
			*)
				bad=1
				local ahead=""
				ahead="$(git -C "$T_REPO" rev-list --count "$T_SELFREV..HEAD" 2>/dev/null)"
				fail "$name is STALE: the binary was built from $T_SELFREV, but $T_REPO is at $T_HEAD${ahead:+ ($ahead commit(s) later)}." \
					"The compiler answering is not any commit of the tree you are reading." \
					"  remedy: rebuild it, or delete it so the flake's own build is used."
				;;
			esac
		elif [ -z "$T_SELFREV" ]; then
			bad=1
			fail "$name is a working-copy build that reports no revision of its own." \
				"There is no evidence available here that it corresponds to $T_HEAD."
		fi
		# Divergence from the flake pin: reported in --verify, refused in --strict.
		local pin_compared=0
		if [ -n "$flake_input" ] && [ -n "$T_HEAD" ]; then
			local pin=""
			case "$flake_input" in
			noir) pin="$LOCK_NOIR" ;;
			esac
			if [ -n "$pin" ]; then
				pin_compared=1
				if git -C "$T_REPO" merge-base --is-ancestor "$pin" "$T_HEAD" 2>/dev/null; then
					ok "$name at $T_VERSION from $T_REPO@$(short "$T_HEAD"), a descendant of the flake '$flake_input' pin $(short "$pin")"
				else
					local ahead behind
					ahead="$(git -C "$T_REPO" rev-list --count "$pin..$T_HEAD" 2>/dev/null)"
					behind="$(git -C "$T_REPO" rev-list --count "$T_HEAD..$pin" 2>/dev/null)"
					if [ "$strict" = strict ]; then
						bad=1
						fail "$name comes from $T_REPO@$(short "$T_HEAD"), which has DIVERGED from the flake '$flake_input' pin $(short "$pin") (${ahead:-?} ahead, ${behind:-?} behind)." \
							"--require refuses this because a number produced by it is attributable" \
							"to a working copy and not to any revision this commit names." \
							"  remedy: measure from a checkout at the pin, or record the divergent" \
							"          revision in the file the number lands in — ci/deploy/noir-wasm.pin" \
							"          does exactly that, and says outright that the flake's noir pin" \
							"          'is NOT this one'."
					else
						note "$name comes from $T_REPO@$(short "$T_HEAD"), which has DIVERGED from the flake '$flake_input' pin $(short "$pin") (${ahead:-?} ahead, ${behind:-?} behind)." \
							"REPORTED, NOT REFUSED: .envrc sets NIX_FLAKE_OVERRIDE_AUTO=1 and" \
							"detect-siblings.sh puts the sibling build on PATH, so this is what the" \
							"workspace is designed to produce. --require (the measurement arm) does" \
							"refuse it."
					fi
				fi
			fi
		fi
		# One line per tool, always. The pin comparison above prints its own `ok`
		# when it ran; this covers the cases where it did not — no flake input is
		# declared for the tool, or one is but its pin could not be resolved. A
		# tool that passes SILENTLY is indistinguishable from one that was never
		# looked at, and the whole subject of this file is telling those apart.
		if [ "$bad" -eq 0 ] && [ "$pin_compared" -eq 0 ]; then
			ok "$name at $T_VERSION from $T_REPO@$(short "$T_HEAD") (clean, binary matches HEAD; no flake pin to compare against)"
		fi
		return
		;;
	esac

	# class = store. Hold it to the declaration.
	case "$name" in
	nim)
		if [ "$T_VERSION" != "$PIN_NIM_VERSION" ]; then
			fail "nim is $T_VERSION, but ci/toolchain.pin expects $PIN_NIM_VERSION." \
				"  from: $T_WHERE" \
				"If the compiler was bumped on purpose, bump ci/toolchain.pin in the same" \
				"commit — that is the whole point of the file being tracked."
		else
			ok "nim $T_VERSION [${T_STORE##*/}] matches ci/toolchain.pin"
		fi
		;;
	rustc)
		if [ "$T_VERSION" != "$PIN_RUSTC_VERSION" ]; then
			fail "rustc is $T_VERSION, but ci/toolchain.pin expects $PIN_RUSTC_VERSION." \
				"  from: $T_WHERE"
		elif [ -n "$PIN_RUSTC_COMMIT" ] && [ -n "$T_SELFREV" ] && [ "$T_SELFREV" != "$PIN_RUSTC_COMMIT" ]; then
			fail "rustc reports upstream commit $T_SELFREV, but ci/toolchain.pin expects $PIN_RUSTC_COMMIT." \
				"Same version string, different build. This is exactly the case a version" \
				"comparison alone would have passed over."
		else
			ok "rustc $T_VERSION ($T_SELFREV) [${T_STORE##*/}] matches ci/toolchain.pin"
		fi
		;;
	cargo)
		if [ "$T_VERSION" != "$PIN_RUSTC_VERSION" ]; then
			fail "cargo is $T_VERSION, but ci/toolchain.pin expects $PIN_RUSTC_VERSION (cargo and rustc come from one fenix toolchain and must agree)." \
				"  from: $T_WHERE"
		else
			ok "cargo $T_VERSION [${T_STORE##*/}] matches ci/toolchain.pin"
		fi
		;;
	*)
		ok "$name $T_VERSION [${T_STORE##*/}]"
		;;
	esac
}

# The optional exact arm: ask nix what THIS flake's Nim is, and compare store
# paths. Kept behind --strict because it evaluates the flake (slow, and needs a
# working nix), and because a guard that cannot run without nix would not run
# in the lanes that need it most.
STRICT_STORE_NOTE="not attempted"
verify_store_paths() {
	CHECKED=$((CHECKED + 1))
	if ! command -v nix >/dev/null 2>&1; then
		STRICT_STORE_NOTE="skipped: nix is not on PATH"
		note "the store-path comparison was skipped: nix is not on PATH." \
			"The version comparison above stands, and a version string is not an" \
			"identity. This gap is named on the RESULT line."
		return
	fi
	local sys expected
	sys="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null)"
	if [ -z "$sys" ]; then
		STRICT_STORE_NOTE="skipped: nix could not report currentSystem"
		note 'the store-path comparison was skipped: `nix eval` could not report the current system.'
		return
	fi
	expected="$(nix eval --raw "$REPO_ROOT#packages.$sys.nim-codetracer" 2>/dev/null)"
	if [ -z "$expected" ]; then
		STRICT_STORE_NOTE="skipped: the flake did not evaluate"
		note "the store-path comparison was skipped: \`nix eval .#packages.$sys.nim-codetracer\` produced nothing." \
			"Reported as a TOOLING failure, not as a verdict about the compiler."
		return
	fi
	probe_tool nim
	if [ "$T_STORE" = "$expected" ]; then
		STRICT_STORE_NOTE="checked: nim is this flake's nim-codetracer"
		ok "nim's store path IS this flake's nim-codetracer ($expected)"
	else
		STRICT_STORE_NOTE="checked: MISMATCH"
		fail "nim resolves to $T_STORE, but this flake's nim-codetracer is $expected." \
			"Same version string is not the same compiler; this is the check that" \
			"separates them."
	fi
}

verify() {
	local strict="$1"
	shift
	local wanted=("$@")

	read_pin
	read_lock

	printf 'toolchain-pins: verifying the compilers that answered in %s\n' "$REPO_ROOT"

	# The vacuity guard, FIRST. Every loop below is a universal quantification,
	# and a universal quantification over an empty set is TRUE — so an emptied
	# TOOLS list would let the environment checks pass and the RESULT line read
	# as a statement about compilers that were never looked at. Checked before
	# anything else so the diagnostic is the accurate one rather than whatever
	# a later expansion happens to trip over.
	if [ "${#TOOLS[@]}" -eq 0 ]; then
		printf 'RESULT: FAILED — 0 tools were verified; the check asserted nothing about any compiler.\n' >&2
		printf '        TOOLS is empty. A toolchain guard that names no tools is not a lenient\n' >&2
		printf '        guard, it is an absent one.\n' >&2
		exit 1
	fi

	verify_shell
	verify_declaration
	verify_fork_reachability

	local entry name selected=0
	for entry in "${TOOLS[@]}"; do
		name="$(tool_field "$entry" 1)"
		if [ "${#wanted[@]}" -gt 0 ]; then
			local want match=0
			for want in "${wanted[@]}"; do
				[ "$want" = "$name" ] && match=1
			done
			[ "$match" -eq 1 ] || continue
		fi
		selected=$((selected + 1))
		verify_tool "$entry" "$strict"
	done

	# The vacuity guard, in two places. A named tool that matches nothing must
	# not silently reduce the run to the environment checks and then pass: that
	# is a guard reporting success over an unchecked input, which is the exact
	# failure this file was written after.
	if [ "${#wanted[@]}" -gt 0 ] && [ "$selected" -ne "${#wanted[@]}" ]; then
		printf 'RESULT: FAILED — %d tool(s) were named but %d matched the declared set.\n' \
			"${#wanted[@]}" "$selected" >&2
		printf '        Declared: %s\n' "$(for entry in "${TOOLS[@]}"; do printf '%s ' "$(tool_field "$entry" 1)"; done)" >&2
		exit 1
	fi
	if [ "$selected" -eq 0 ]; then
		printf 'RESULT: FAILED — 0 tools were verified; the check asserted nothing about any compiler.\n' >&2
		exit 1
	fi

	# The exact arm is about NIM specifically (it is the one tool that
	# self-reports no revision, so a store-path comparison is the only identity
	# available for it). It therefore has to respect the scope: a
	# `--require rustc cargo` run must not fail on nim, or a caller that never
	# invokes nim is refused for a compiler it did not use — which is a guard
	# reporting on an input outside its own stated scope, the mirror image of
	# reporting success over one inside it.
	if [ "$strict" = strict ]; then
		local nim_in_scope=1 want
		if [ "${#wanted[@]}" -gt 0 ]; then
			nim_in_scope=0
			for want in "${wanted[@]}"; do
				[ "$want" = nim ] && nim_in_scope=1
			done
		fi
		if [ "$nim_in_scope" -eq 1 ]; then
			verify_store_paths
		else
			STRICT_STORE_NOTE="not applicable: nim is outside this run's scope"
		fi
	fi

	if [ "$FAILED" -ne 0 ]; then
		printf 'RESULT: FAILED — %d of %d check(s) could not attribute the toolchain to this commit.\n' \
			"$FAILED" "$CHECKED" >&2
		exit 1
	fi

	printf 'RESULT: PASSED — %d check(s) over %d tool(s): the compilers that answered are the ones this commit declares.\n' \
		"$CHECKED" "$selected"
	# The scope, printed on every pass, for the same reason sibling-pins.sh
	# prints its own: the failure mode of a scoped guard is that its scope is
	# forgotten and its green tick is read as a reproducibility claim.
	printf '        SCOPE, and what is NOT covered:\n'
	# The tools THIS RUN verified, not the declared list. A scoped run that
	# printed the declared list here would name compilers it never looked at on
	# the same line as the word PASSED, which is the overstatement this whole
	# block exists to prevent — and it is not hypothetical: `--require nim rustc
	# cargo` said "4 tools (nim rustc cargo nargo)" having checked three.
	local verified_names="" skipped_names="" entry2 name2 want2 hit2
	for entry2 in "${TOOLS[@]}"; do
		name2="$(tool_field "$entry2" 1)"
		hit2=1
		if [ "${#wanted[@]}" -gt 0 ]; then
			hit2=0
			for want2 in "${wanted[@]}"; do
				[ "$want2" = "$name2" ] && hit2=1
			done
		fi
		if [ "$hit2" -eq 1 ]; then
			verified_names="$verified_names $name2"
		else
			skipped_names="$skipped_names $name2"
		fi
	done
	printf '        - %d tool(s) verified:%s. C/C++, Go, the recorder toolchains and\n' \
		"$selected" "$verified_names"
	printf '          the Nim package set are NOT checked. This is not a claim that the\n'
	printf '          build is reproducible; it is a claim about the compilers just named.\n'
	if [ -n "$skipped_names" ]; then
		printf '        - DECLARED BUT NOT VERIFIED BY THIS RUN:%s. They were not held to\n' "$skipped_names"
		printf '          anything here, and the stamp lists them under `not-verified:` for\n'
		printf '          the same reason.\n'
	fi
	if [ "$strict" = strict ]; then
		printf '        - store paths: %s.\n' "$STRICT_STORE_NOTE"
	else
		printf '        - A VERSION STRING IS NOT AN IDENTITY. nim and cargo were compared by\n'
		printf '          version, not by store path; two builds from different sources report\n'
		printf '          the same string. `--strict` compares store paths and needs nix.\n'
	fi
	printf '        - NIM SELF-REPORTS NO REVISION (release tarball, no git hash), so for\n'
	printf '          Nim the evidence here is the version plus the store path — weaker than\n'
	printf '          for rustc and nargo, which both print a commit.\n'
	if [ "$STORE_PREFIX" != "/nix/store" ]; then
		printf '        - THE STORE WAS REDEFINED for this run: TOOLCHAIN_PINS_STORE_PREFIX=%s.\n' "$STORE_PREFIX"
		printf '          Read every "store" verdict above as being about that directory. This\n'
		printf '          exists for ci/test/toolchain-pins-test.sh and has no other caller.\n'
	fi
	if [ "$NOTES" -ne 0 ]; then
		printf '        - %d divergence(s) were REPORTED and not refused; see NOTE above. Run\n' "$NOTES"
		printf '          --require (or --strict) to make them failures.\n'
	fi
}

# --- did the dev shell ever run HERE? ---------------------------------------
#
# A fresh `git worktree` has no `.pre-commit-config.yaml` (it is a
# devshell-GENERATED SYMLINK into /nix/store, not a tracked file), no
# initialised submodules and no generated parser, because `.envrc` is what
# creates all three — and `.envrc` is blocked in a new directory until
# `direnv allow` is run there. Every agent is instructed to work in a fresh
# worktree, so this hits all of them, and the symptom is a build failure that
# names a missing Nim module rather than a missing environment.
#
# MEASURED in the worktree this file was written in: before `direnv allow`,
# `.pre-commit-config.yaml` was absent and `git submodule status` prefixed
# every entry with `-`. After it, the symlink existed and libs/nim-stew had
# nine entries.
devshell_init() {
	local problems=0
	printf 'toolchain-pins: has the dev shell ever initialised %s?\n' "$REPO_ROOT"

	if [ -e "$REPO_ROOT/.envrc" ]; then
		if [ -L "$REPO_ROOT/.pre-commit-config.yaml" ] || [ -f "$REPO_ROOT/.pre-commit-config.yaml" ]; then
			ok ".pre-commit-config.yaml exists (the dev shell generated it here)"
		else
			problems=$((problems + 1))
			printf '  MISSING  .pre-commit-config.yaml\n'
			printf '           It is a devshell-generated symlink into /nix/store, not a tracked\n'
			printf '           file, so a fresh worktree does not have one and `git commit` will\n'
			printf '           behave differently here than in the main checkout.\n'
		fi
	fi

	local uninit=0
	if command -v git >/dev/null 2>&1; then
		uninit="$(git -C "$REPO_ROOT" submodule status 2>/dev/null | grep -c '^-' | tr -d ' ')"
		if [ "${uninit:-0}" -gt 0 ]; then
			problems=$((problems + 1))
			printf '  MISSING  %s uninitialised submodule(s)\n' "$uninit"
			printf '           `.envrc` runs `git submodule update --init --recursive`; a worktree\n'
			printf '           it has never run in has none of them, and the build fails later on\n'
			printf '           `cannot open file: <module>` naming the module, not the cause.\n'
		else
			ok "all submodules are initialised"
		fi
	fi

	# The generated parser. `nix/shells/ci-base.nix`'s shellHook — the one
	# BOTH `devShells.default` and `devShells.ci` compose — runs
	# `non-nix-build/ensure_tree_sitter_nim_parser.sh`, producing a 42 MB
	# UNTRACKED `src/parser.c`. Checked separately from the submodule state
	# because the two can disagree: a submodule can be initialised and the
	# parser still never generated, and the failure that follows names a C
	# file and nothing else.
	#
	# Guarded on the DIRECTORY EXISTING. Note what that does and does not say:
	# a lane that checks out with `submodules: false` still gets an EMPTY
	# `libs/tree-sitter-nim/` mount point, so this guard PASSES there and the
	# report below fires for a file that lane is designed not to have. That is
	# tolerable here because this is a diagnostic that only prints — but it is
	# exactly why the regen call site in ci-base.nix guards on `grammar.js`
	# instead, where a false positive would abort every such lane at shell
	# entry.
	#
	# The regen used to live in `main.nix`'s dev-only shellHook tail under the
	# claim that "CI clones with submodules: false and skips the regen
	# deliberately". That was not true of every lane: `launcher-recorder-e2e`
	# checks this repo out WITH submodules and builds in `devShells.ci`, which
	# never ran that tail — so it hit precisely the missing-C-file failure this
	# check was written to explain, while this check printed the explanation
	# and let the build continue.
	if [ -d "$REPO_ROOT/libs/tree-sitter-nim" ]; then
		if [ -f "$REPO_ROOT/libs/tree-sitter-nim/src/parser.c" ]; then
			ok "libs/tree-sitter-nim/src/parser.c has been generated"
		else
			problems=$((problems + 1))
			printf '  MISSING  libs/tree-sitter-nim/src/parser.c\n'
			printf '           It is generated by non-nix-build/ensure_tree_sitter_nim_parser.sh\n'
			printf '           from the dev shell hook and is not tracked, so a checkout the shell\n'
			printf '           never ran in does not have it. src/db-backend compiles it via the\n'
			printf '           tree-sitter-nim path dependency; without it cargo fails with\n'
			printf '           "clang: error: no input files" and names no cause.\n'
		fi
	fi

	if [ "$problems" -eq 0 ]; then
		printf 'RESULT: PASSED — the dev shell has initialised this checkout.\n'
		printf '        SCOPE: this says the SIDE EFFECTS of entering the shell are present.\n'
		printf '        It does not say the shell is entered NOW, nor which compiler is on\n'
		printf '        PATH — that is `--verify`, and the two are different questions.\n'
		return 0
	fi
	printf 'RESULT: FAILED — %d marker(s) of dev-shell initialisation are absent here.\n' "$problems" >&2
	printf '        This is almost always a fresh `git worktree` in which direnv has never\n' >&2
	printf '        been allowed. `.envrc` is blocked per-directory, and a caller that\n' >&2
	printf '        proceeds past that failure gets the ambient compiler.\n' >&2
	printf '          remedy: cd %s && direnv allow\n' "$REPO_ROOT" >&2
	return 1
}

# --- entry point ------------------------------------------------------------

MODE=stamp
STRICT=lenient
REQUIRE_TOOLS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--stamp)
		MODE=stamp
		shift
		;;
	--line)
		MODE=line
		shift
		;;
	--verify)
		MODE=verify
		shift
		;;
	--strict)
		MODE=verify
		STRICT=strict
		shift
		;;
	--require)
		MODE=require
		STRICT=strict
		shift
		while [ $# -gt 0 ]; do
			case "$1" in
			-*) break ;;
			*)
				REQUIRE_TOOLS+=("$1")
				shift
				;;
			esac
		done
		;;
	--devshell-init)
		MODE=devshell
		shift
		;;
	--list)
		MODE=list
		shift
		;;
	-h | --help)
		sed -n '6,140p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		die "unknown argument '$1'. Usage: toolchain-pins.sh [--stamp | --line | --verify | --strict | --require [tool…] | --devshell-init | --list]"
		;;
	esac
done

case "$MODE" in
list)
	for entry in "${TOOLS[@]}"; do printf '%s\n' "$(tool_field "$entry" 1)"; done
	;;
stamp)
	stamp_block
	;;
line)
	stamp_line
	;;
verify)
	verify "$STRICT"
	;;
require)
	# THE RULE, as one command. The stamp is printed only on the far side of a
	# strict verification, so a number produced by a caller of this cannot come
	# from an unattributable compiler: there is no path to the line without the
	# refusal. Verification output goes to stderr's usual place; the stamp goes
	# to stdout so a caller can capture just that.
	verify "$STRICT" "${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"}" >&2 || exit 1
	stamp_line "${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"}"
	;;
devshell)
	devshell_init
	;;
esac
