#!/usr/bin/env bash
#
# sourced-var-collision-gate.sh — a file this repository SOURCES may not leave
# a generic name behind in its sourcer's shell unless it says so first.
#
# THE DEFECT
# ----------
# A script assigns a common name, sources another script, and keeps using the
# name. If the sourced script assigns the same name at top level, every later
# use in the SOURCING script silently resolves to the other script's value:
#
#     SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # this repo
#     source "$SIBLING/export_build_env.sh"         # assigns its own SCRIPT_DIR
#     source "$SCRIPT_DIR/../../ci/lib/x.sh"        # the SIBLING's directory
#
# There is no error. The path resolves to somewhere that exists, the step exits
# 0, and the artefact it was supposed to produce is simply absent.
#
# TWICE, MEASURED, IN ONE NIGHT
# -----------------------------
#   * `SCRIPT_DIR` (fixed in 295f36835). `src/db-backend/build_wasm.sh` sources
#     `ct_emulator/export_build_env.sh`, which assigns its own `SCRIPT_DIR`.
#     The stamping step afterwards resolved `$SCRIPT_DIR/../../ci/lib/...` to
#     `/Users/zahary/m/dev/ci/lib/...` — one directory ABOVE BOTH repositories.
#     The build finished 0 with its freshness stamp silently unwritten.
#
#   * `REPO_ROOT` (fixed in 3c7b257ed). `ci/test/stale-artefact-guards-test.sh`
#     sources `ci/setup-rr-backend.sh`, which assigned its own `REPO_ROOT`. The
#     runtime was contained by a subshell, so this one never misbehaved — it
#     surfaced as NINE FALSE `SC2031` findings the moment `shopt -s globstar`
#     let shellcheck see both files at once, failing `lint-bash` and
#     dark-gating every build artefact job for 13 runs.
#
# One announced itself as a wrong artefact, one as a red lane, and NEITHER
# announced itself as what it was. The hazard was even written down — the
# stale-artefact suite's own header warns about `REPO_ROOT` specifically — and
# the sweep was never done.
#
# WHY THE RULE IS ON THE SOURCED SIDE
# -----------------------------------
# Measured on this tree: 91 sites assign a generic name, source something, and
# use the name afterwards. Renaming all 91 is 91 edits that close nothing — the
# next `repo_root` reintroduces it. But only SIXTEEN files are ever sourced,
# and eleven of those already leak nothing (every `ci/lib/*.sh` declares its
# locals). An invariant on the sourced side is therefore small, and — the
# decisive property — CHECKABLE: it is a fact about one file, provable without
# knowing anything about its callers. The sourcing side is not checkable that
# way; you would have to know every callee, including callees in other
# repositories.
#
# WHY DECLARE RATHER THAN FORBID
# ------------------------------
# Some sourced files exist precisely in order to leak. `non-nix-build/env.sh`
# sets `ROOT_DIR` for eleven sibling scripts and for a PowerShell file; that is
# a contract, not an accident, and "rename it" would be a cross-language change
# with no defect behind it. So the rule is not "leak nothing", it is "leak only
# what you have written down". That converts an unbounded implicit leak into a
# bounded explicit one, keeps the declaration NEXT TO THE CODE where a reviewer
# of that file sees it, and makes adding a leak a reviewable edit.
#
# The declared set is also held to an ENUMERATED BASELINE and fails in BOTH
# directions, the same way `ci/test/test-assertion-baseline.sh` holds its own —
# so a declaration cannot be added quietly, and one that gets fixed cannot be
# left behind to make the list look longer than the problem.
#
# WHAT SHELLCHECK DOES AND DOES NOT DO HERE
# -----------------------------------------
# It has no code for this. `SC2031` fired on instance 2 only by accident of the
# subshell that CONTAINED it, and every one of those nine findings was FALSE:
# it was reporting the suite's own variable, not the collision. A shape that is
# invisible when it is dangerous and noisy when it is safe is the argument for
# a rule of our own rather than a flag on someone else's.
#
# ARM B EXISTS BECAUSE ARM A CANNOT REACH EVERYTHING. `build_wasm.sh` sources a
# file in codetracer-native-recorder. No invariant this repository enforces
# applies there — that file is free to start assigning `WORKSPACE_ROOT`
# tomorrow. For a source that LEAVES this repository the only enforceable side
# is the sourcing side, so Arm B refuses a generic name USED after one.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

FIXTURE_DIR="ci/test/sourced-var-collision-gate.fixtures"

# ---------------------------------------------------------------------------
# THE GENERIC NAMES.
#
# Not "every name" — that would flag `CT_MCR_EMULATOR_WASM_BUILD_SCRIPT`, which
# is exactly the form that is SAFE, and this repository has already had a
# linter's noise turn a required lane red. These are the names that describe a
# root, a path or a label without saying whose: the ones two unrelated scripts
# both reach for. Matched case-insensitively, because `repo_root` and
# `REPO_ROOT` are the same hazard and this tree uses both.
# ---------------------------------------------------------------------------
# ONE LINE, deliberately: `awk -v` does not accept an embedded newline, and a
# multi-line value makes every invocation die with "newline in string" — at
# which case the detector finds nothing and every file looks clean. Step 0's
# leaky.sh half is what caught exactly that while this file was being written.
#
# The last two are not generic English — they are generic TO THIS TREE, which
# is the same hazard wearing a local name. `env.sh` and
# `non-nix-build/windows/setup-codetracer-runtime-env.sh` each compute
# `WINDOWS_DIR` and `NON_NIX_BUILD_DIR` for themselves, and the second is
# sourced by the first, so they were a live collision under a name no
# dictionary-based list would contain.
GENERIC_NAMES="SCRIPT_DIR SCRIPTDIR SCRIPT_ROOT REPO_ROOT REPOROOT REPO ROOT_DIR ROOTDIR ROOT BASE_DIR BASEDIR TOP TOPDIR TOP_DIR HERE DIR SRC_DIR SOURCE_DIR OUT_DIR OUTDIR OUT BUILD_DIR WORK_DIR WORKDIR BIN_DIR LIB_DIR TEST_DIR TESTS_DIR TMP_DIR TMP CACHE_DIR LOG_DIR LOGDIR CONFIG_DIR DATA_DIR DEST DEST_DIR TARGET TARGET_DIR PREFIX PROJECT_ROOT WORKSPACE_ROOT WORKSPACE RECORDER_ROOT CLONE_DIR DEPS_DIR APP_DIR PKG_DIR SYSROOT NAME LABEL SELF NON_NIX_BUILD_DIR WINDOWS_DIR"

fail_count=0
check_count=0
fail() {
	echo "FAIL: $*"
	fail_count=$((fail_count + 1))
}
ok() {
	echo "ok: $*"
}

# ---------------------------------------------------------------------------
# THE DETECTOR.
#
# leak_scan FILE -> lines "LINENO<TAB>NAME" for every assignment that would
# land in a SOURCER's shell: top level (not inside a function), not `local`,
# not inside a `( … )` subshell, not inside a heredoc body, and not
# default-preserving.
#
# `X="${X:-default}"` IS NOT A LEAK and the distinction is load-bearing rather
# than a nicety: it defines the name when unset and never overwrites a caller's
# value. `scripts/docs/deep-review-capture-lib.sh` uses exactly that for
# `CTDR_LABEL` so callers can override it, and treating that as a collision
# would flag the one construction that is already the fix.
# ---------------------------------------------------------------------------
leak_scan() {
	awk -v generic="${GENERIC_NAMES}" '
	BEGIN {
		n = split(generic, g, /[ \t\n]+/)
		for (i = 1; i <= n; i++) if (g[i] != "") deny[toupper(g[i])] = 1
		fn = 0; depth = 0; paren = 0; heredoc = ""; guard = ""
	}
	{
		line = $0

		# --- heredoc bodies are DATA, not code. A generated env file written
		# --- with `cat <<EOF ... ROOT_DIR=x ... EOF` assigns nothing here.
		if (heredoc != "") {
			t = line; sub(/^[ \t]*/, "", t)
			if (t == heredoc) heredoc = ""
			next
		}
		if (match(line, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
			tag = substr(line, RSTART, RLENGTH)
			sub(/^<<-?[ \t]*/, "", tag); gsub(/[\047"]/, "", tag)
			heredoc = tag
		}

		# --- strip a trailing comment (crude, but assignments we care about
		# --- are not written inside quoted # ).
		sub(/[ \t]#.*$/, "", line)
		if (line ~ /^[ \t]*#/) { note_nesting(line); next }

		# --- A SELF-GUARDED FALLBACK IS NOT A CLOBBER, and this is the same
		# --- judgement as `X="${X:-…}"` written the long way:
		# ---
		# ---     if [[ -z ${ROOT_DIR:-} ]]; then
		# ---         ROOT_DIR=$(…)          # supplies it only when absent
		# ---     fi
		# ---
		# --- Recognising it is not a courtesy to the code — it is the REMEDY
		# --- this gate prints for `setup-codetracer-runtime-env.sh`, whose
		# --- three fallbacks were all keyed on one sentinel and now each guard
		# --- themselves. A gate that flags its own fix is a wall.
		# ---
		# --- The guard must name the SAME variable it then assigns. That is
		# --- exactly what the old code got wrong: `if [[ -z ${ROOT_DIR:-} ]]`
		# --- around an assignment to `NON_NIX_BUILD_DIR` guards nothing, and
		# --- this detector still reports it.
		if (line ~ /^[ \t]*if[ \t].*-z[ \t]*["\047]?\$\{?[A-Za-z_][A-Za-z0-9_]*/) {
			gv = line
			sub(/^.*-z[ \t]*["\047]?\$\{?/, "", gv)
			sub(/[^A-Za-z0-9_].*$/, "", gv)
			guard = gv
			next
		}
		if (line ~ /^[ \t]*(fi|else|elif)\b/) guard = ""

		if (line ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{/ ||
		    line ~ /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\{/) {
			if (!fn) { fn = 1; fn_depth = depth }
		}

		if (!fn && !paren && line ~ /^[ \t]*(export[ \t]+|readonly[ \t]+|declare[ \t]+(-[A-Za-z]+[ \t]+)*|typeset[ \t]+)?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) {
			nm = line
			sub(/^[ \t]*/, "", nm)
			sub(/^(export|readonly|declare|typeset)[ \t]+/, "", nm)
			while (nm ~ /^-[A-Za-z]+[ \t]+/) sub(/^-[A-Za-z]+[ \t]+/, "", nm)
			val = nm
			sub(/^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/, "", val)
			sub(/(\[[^]]*\])?\+?=.*$/, "", nm)
			if (toupper(nm) in deny) {
				# default-preserving: X="${X:-…}" / "${X-…}" / "${X:=…}"
				probe = val
				gsub(/^[ \t]*"?/, "", probe)
				if (probe !~ ("^\\$\\{" nm "[ \t]*:?[-=]") && guard != nm)
					printf "%d\t%s\n", NR, nm
			}
		}
		note_nesting(line)
	}
	function note_nesting(l,   bare, i, c, q) {
		# brace depth for function bodies
		depth += gsub(/\{/, "{", l) - gsub(/\}/, "}", l)
		if (fn && depth <= fn_depth) fn = 0
		# subshell depth, ignoring $( … ) command substitution
		bare = l; gsub(/\$\(/, "", bare)
		paren += gsub(/\(/, "(", bare) - gsub(/\)/, ")", bare)
		if (paren < 0) paren = 0
	}
	' "$1"
}

# declared_leaks FILE -> the names on this file`s `ct-leaks:` line(s)
declared_leaks() {
	awk '
	/^[ \t]*#.*ct-leaks:/ {
		sub(/^.*ct-leaks:[ \t]*/, "")
		sub(/[ \t]*$/, "")
		n = split($0, a, /[ \t]+/)
		for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
	}
	' "$1"
}

# uses_after FILE LINE -> generic names referenced after LINE
uses_after() {
	awk -v start="$2" -v generic="${GENERIC_NAMES}" '
	BEGIN {
		n = split(generic, g, /[ \t\n]+/)
		for (i = 1; i <= n; i++) if (g[i] != "") deny[toupper(g[i])] = 1
	}
	NR > start {
		l = $0
		sub(/^[ \t]*#.*$/, "", l)
		while (match(l, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
			v = substr(l, RSTART, RLENGTH)
			sub(/^\$\{?/, "", v)
			if (toupper(v) in deny) print v
			l = substr(l, RSTART + RLENGTH)
		}
	}
	' "$1" | sort -u
}

# ---------------------------------------------------------------------------
# STEP 0 — the detector fires on the defect and stays quiet on every fix.
#
# Run against fixtures before it is trusted with the tree. A gate whose
# detector has silently rotted into a no-op reports a clean repository, which
# is the same output as a clean repository — the failure mode this whole file
# exists to refuse.
# ---------------------------------------------------------------------------
echo "Step 0: the detector fires on the defect and stays quiet on the fixes"

if [ ! -d "${FIXTURE_DIR}" ]; then
	echo "RESULT: FAILED — no fixture directory at ${FIXTURE_DIR}"
	exit 1
fi

# THE HAYSTACK IS MATERIALISED FIRST, and `grep -q` reads it from a HERE-STRING
# rather than from a pipe. `producer | grep -q PAT` under `set -o pipefail`
# returns a successful match AS A FAILURE: `grep -q` exits on the first match,
# the producer takes EPIPE, and the pipeline adopts its 141. See
# `ci/test/grep-q-pipefail-gate.sh`, which caught these three sites in this very
# file -- after a local run of that gate had reported the tree clean, because it
# scans `git ls-files` and these files were still UNTRACKED when it ran.
expect_leak() { # FILE NAME
	check_count=$((check_count + 1))
	local found
	found="$(leak_scan "${FIXTURE_DIR}/$1" | cut -f2)"
	if grep -qx -- "$2" <<<"${found}"; then
		ok "fixture $1: \$$2 is detected as a leak"
	else
		fail "fixture $1: \$$2 is a leak and the detector MISSED it"
	fi
}
expect_clean() { # FILE NAME WHY
	check_count=$((check_count + 1))
	local found
	found="$(leak_scan "${FIXTURE_DIR}/$1" | cut -f2)"
	if grep -qx -- "$2" <<<"${found}"; then
		fail "fixture $1: \$$2 is FLAGGED but $3"
	else
		ok "fixture $1: \$$2 is not flagged — $3"
	fi
}

expect_leak leaky.sh REPO_ROOT
expect_leak leaky.sh SCRIPT_DIR
expect_leak leaky.sh ROOT_DIR
# The one that separates a real guard from a decorative one: guarded on
# ROOT_DIR, assigns BASE_DIR. Accepting any `-z` test would miss it, and this
# is the shape that shipped.
expect_leak leaky.sh BASE_DIR

expect_clean clean.sh REPO_ROOT "it is declared 'local' on a preceding line"
expect_clean clean.sh SCRIPT_DIR "it is assigned inside a function with 'local'"
expect_clean clean.sh ROOT_DIR "the assignment is default-preserving"
expect_clean clean.sh OUT_DIR "the assignment is inside a ( … ) subshell"
expect_clean clean.sh BUILD_DIR "the assignment is inside a heredoc body"
expect_clean clean.sh DEST "the line is a comment"
expect_clean clean.sh WORKSPACE_ROOT "the assignment is guarded on its OWN name"

# The denylist must not be so wide that a namespaced name trips it: that is how
# a lint becomes noise, and noise in this lane skips every build job.
expect_clean clean.sh CT_REPO_ROOT "a prefixed name is the fix, not the defect"

if [ "${fail_count}" -ne 0 ]; then
	echo "RESULT: FAILED — the detector is broken; not reporting on the tree"
	exit 1
fi

# ---------------------------------------------------------------------------
# THE SOURCED SET.
#
# Discovered, not hand-listed, so a new library is covered the moment the first
# `source` of it is written — which is the moment the hazard begins to exist.
# Two ways in, and each is named in the output so a reader can see WHY a file
# is being held to the rule:
#
#   literal  — some script sources it by a path whose tail is literal text
#   indirect — sourced through a variable, so there is no literal tail to
#              match. These cannot be discovered textually, so they are
#              ENUMERATED below WITH their sourcing site, and the enumeration
#              is itself checked: an entry naming a file or a sourcer that no
#              longer exists fails this gate rather than quietly covering
#              nothing.
#
# NOT "every ci/lib/*.sh". That was tried and it is wrong in both directions.
# `ci/lib/run-nim-test-lane.sh` and `ci/lib/require-tools.sh` live there and are
# EXECUTED, never sourced; their top-level `repo_root` is correct and flagging
# it would be pure noise — the failure this repository has already paid for
# twice. The git mode does not separate them either: `ci/lib/nim-cache-root.sh`
# is 100755 AND is sourced by forty scripts. Being sourced is the only property
# that matters, so it is the only one used.
# ---------------------------------------------------------------------------
INDIRECTLY_SOURCED="
ci/setup-rr-backend.sh|ci/test/stale-artefact-guards-test.sh|RR_SETUP
"

sourced_set_file="$(mktemp)" || exit 2
trap 'rm -f "${sourced_set_file}"' EXIT

# literal: take every source argument, drop the ${…}/$(…) prefix, keep the
# literal tail, and match it against tracked files by path suffix.
git ls-files -- '*.sh' | while IFS= read -r f; do
	awk '
	/^[ \t]*(source|\.)[ \t]+/ {
		a = $0
		sub(/^[ \t]*(source|\.)[ \t]+/, "", a)
		sub(/[ \t;#].*$/, "", a)
		gsub(/["\047]/, "", a)
		gsub(/\$\{[^}]*\}/, "\001", a)
		gsub(/\$\([^)]*\)/, "\001", a)
		gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "\001", a)
		sub(/^.*\001/, "", a)
		sub(/^\/+/, "", a)
		# A bare basename is kept: `source "$NON_NIX_BUILD_DIR/env.sh"` leaves
		# `env.sh`, and there are two files by that name in this tree. Matching
		# both is over-inclusive in the SAFE direction — both really are
		# sourced, and a file wrongly held to the rule costs one declaration
		# while a file wrongly omitted costs the whole point of the gate.
		if (a ~ /^[A-Za-z0-9_.\/-]+$/ && a ~ /\.(sh|bash|env|pin)$/) print a
	}
	' "$f"
done | sort -u >"${sourced_set_file}.tails"

git ls-files >"${sourced_set_file}.all"
: >"${sourced_set_file}"
while IFS= read -r tail; do
	[ -n "${tail}" ] || continue
	grep -x -- "${tail}" "${sourced_set_file}.all" 2>/dev/null |
		sed 's/^/literal\t/' >>"${sourced_set_file}" || true
	grep -- "/${tail}\$" "${sourced_set_file}.all" 2>/dev/null |
		sed 's/^/literal\t/' >>"${sourced_set_file}" || true
done <"${sourced_set_file}.tails"

echo
echo "Step 1: every file sourced through a variable is still there, and still sourced that way"
while IFS='|' read -r target sourcer var; do
	[ -n "${target}" ] || continue
	check_count=$((check_count + 1))
	if [ ! -f "${target}" ]; then
		fail "indirect-source entry names '${target}', which does not exist"
		continue
	fi
	if [ ! -f "${sourcer}" ]; then
		fail "indirect-source entry says '${sourcer}' sources it; that file does not exist"
		continue
	fi
	if ! grep -q "source[ \t]*\"\${\?${var}" "${sourcer}"; then
		fail "'${sourcer}' no longer sources \$${var} — the entry for ${target} covers nothing"
		continue
	fi
	ok "${target} is sourced by ${sourcer} via \$${var}"
	printf 'indirect\t%s\n' "${target}" >>"${sourced_set_file}"
done <<<"${INDIRECTLY_SOURCED}"

sort -u -k2 "${sourced_set_file}" -o "${sourced_set_file}"

# ---------------------------------------------------------------------------
# ARM A — a sourced file leaks only what it declares.
# ---------------------------------------------------------------------------
echo
echo "Step 2 (Arm A): no sourced file leaks a generic name it has not declared"

declared_total=0
declared_inventory="$(mktemp)" || exit 2
trap 'rm -f "${sourced_set_file}" "${sourced_set_file}.tails" "${sourced_set_file}.all" "${declared_inventory}"' EXIT

while IFS=$'\t' read -r why f; do
	[ -n "${f:-}" ] || continue
	[ -f "${f}" ] || continue
	leaks="$(leak_scan "${f}")"
	[ -n "${leaks}" ] || continue
	decl="$(declared_leaks "${f}")"
	while IFS=$'\t' read -r ln nm; do
		[ -n "${nm:-}" ] || continue
		check_count=$((check_count + 1))
		if grep -qx -- "${nm}" <<<"${decl}"; then
			printf '%s\t%s\n' "${f}" "${nm}" >>"${declared_inventory}"
			declared_total=$((declared_total + 1))
		else
			fail "${f}:${ln} leaks \$${nm} into every shell that sources it (found: ${why})"
			echo "      Every later use of \$${nm} in the SOURCING script silently becomes this one."
			echo "      remedy: rename it to something that says which script owns it (RR_REPO_ROOT),"
			echo "              or, if callers really do depend on it, add it to a '# ct-leaks:' line"
			echo "              in ${f} and to EXPECTED_DECLARED_LEAKS in this gate."
		fi
	done <<<"${leaks}"
done <"${sourced_set_file}"

# ---------------------------------------------------------------------------
# THE BASELINE, enumerated and failing in both directions.
#
# Every one of these is a name that really does cross a `source` boundary. The
# number may only go DOWN by someone removing a leak; it goes up only with a
# deliberate edit here, which is the point.
# ---------------------------------------------------------------------------
# Five, in two files, and every one of them belongs to the SAME contract: the
# non-nix build environment, read by eleven scripts in `non-nix-build/` and, in
# `ROOT_DIR`'s case, by `non-nix-build/windows/ensure-tup.ps1` from the
# PowerShell side. Renaming them would be a cross-language change with no
# defect behind it; declaring them costs one line per file and makes it
# checkable.
#
#   env.sh                ROOT_DIR  WINDOWS_DIR  NON_NIX_BUILD_DIR
#   non-nix-build/env.sh  ROOT_DIR  NON_NIX_BUILD_DIR
#
# `non-nix-build/windows/setup-codetracer-runtime-env.sh` is NOT on this list
# and used to be: it computed all three, guarded on `ROOT_DIR` alone. Each of
# its fallbacks now guards on its own name, so it leaks nothing and needs no
# declaration. That is the direction this number is meant to move.
EXPECTED_DECLARED_LEAKS=5

echo
echo "Step 3: the declared-leak inventory matches its baseline exactly"
check_count=$((check_count + 1))
if [ "${declared_total}" -eq "${EXPECTED_DECLARED_LEAKS}" ]; then
	ok "${declared_total} declared leaks, as enumerated"
else
	fail "declared leaks: expected ${EXPECTED_DECLARED_LEAKS}, found ${declared_total}"
	echo "      A LOWER number means a leak was removed — delete its '# ct-leaks:' entry and"
	echo "      lower EXPECTED_DECLARED_LEAKS. A HIGHER number means a new name now crosses a"
	echo "      source boundary; that is a decision, and it belongs in a diff."
	echo "      Currently declared:"
	sort "${declared_inventory}" 2>/dev/null | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# ARM B — a source that leaves this repository.
#
# Arm A is an invariant on the sourced file. When the sourced file is in
# ANOTHER repository there is no invariant to hold it to, so the rule moves to
# the only side we control: do not USE a generic name after such a source.
#
# This is the arm that would have caught 295f36835 the day it was written.
# ---------------------------------------------------------------------------
echo
echo "Step 4 (Arm B): no generic name is used after a source that leaves this repository"

git ls-files -- '*.sh' | while IFS= read -r f; do
	awk -v file="$f" '
	/^[ \t]*(source|\.)[ \t]+/ {
		a = $0
		sub(/^[ \t]*(source|\.)[ \t]+/, "", a)
		sub(/[ \t;#].*$/, "", a)
		# A source whose argument mentions a sibling repository or an
		# explicit walk out of the tree cannot be reasoned about from here.
		if (a ~ /\.\.\/\.\.\/\.\./ || a ~ /RECORDER_ROOT/ || a ~ /EMULATOR/ ||
		    a ~ /WORKSPACE/ || a ~ /SIBLING/ || a ~ /PRIVATE_BUILD_ENV/)
			printf "%s\t%d\n", file, NR
	}
	' "$f"
done >"${sourced_set_file}.external"

while IFS=$'\t' read -r f ln; do
	[ -n "${f:-}" ] || continue
	check_count=$((check_count + 1))
	used="$(uses_after "${f}" "${ln}")"
	if [ -z "${used}" ]; then
		ok "${f}:${ln} sources outside this repo, and uses no generic name afterwards"
	else
		fail "${f}:${ln} sources outside this repository, then uses: $(echo "${used}" | tr '\n' ' ')"
		echo "      That file is in another repository's change control. It is free to start"
		echo "      assigning any of those names tomorrow, and this script would keep working"
		echo "      against the wrong directory without a word."
		echo "      remedy: resolve every path this script needs BEFORE the source, under a"
		echo "              prefixed name (CT_REPO_ROOT, CT_RECORDER_ROOT)."
	fi
done <"${sourced_set_file}.external"

# ---------------------------------------------------------------------------
echo
echo "checks: ${check_count}   failures: ${fail_count}"
if [ "${fail_count}" -ne 0 ]; then
	echo "RESULT: FAILED"
	exit 1
fi
echo "RESULT: OK"
