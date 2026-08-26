#!/usr/bin/env bash
#
# nimsuggest-check.sh — "does nimsuggest still start on src/lsp.nim?", with the
# one distinction the bare check could never make.
#
# WHAT THE ORIGINAL CHECK WAS FOR
# -------------------------------
# `echo quit | nimsuggest --v4 src/lsp.nim` is a cheap canary for a specific,
# recurring CodeTracer regression: chronicles log statements over distinct
# types, or over objects containing them, compile fine but make nimsuggest fall
# over, and every editor in the project goes dark. That check is worth keeping.
#
# WHY IT IS QUARANTINED TODAY
# ---------------------------
# On the pinned toolchain (Nim 2.2.8, nimsuggest from the same store path) the
# check is red for a reason that has nothing to do with CodeTracer's sources:
#
#   * A one-line `echo "hi"` file placed in the repo root crashes nimsuggest
#     exactly as src/lsp.nim does. The project's own code is not involved.
#   * `nim check` on that same file, under the same config, is clean — so the
#     compiler front end is fine and only the nimsuggest driver is affected.
#   * The trigger is this repo's NimScript `config.nims`: `--skipProjCfg` makes
#     the crash disappear, and copying config.nims alone into an empty
#     directory reproduces it.
#   * It is memory corruption, not a deterministic error. The same input yields
#     either SIGSEGV or `AssertionDefect: the length of the seq changed while
#     iterating over it`, and which one you get depends on how many unrelated
#     lines of config.nims precede it — non-monotonically. Truncating the
#     config at line 102 passes, at line 110 asserts, at 125 asserts, at 129
#     segfaults; a shorter prefix plus the same trailing block passes again.
#     Nothing about that is a property of what the config asks for.
#   * All four nimsuggest protocol flavours (--v1/--v2/--v3/--v4) crash
#     identically, so it is not the suggest protocol either.
#
# Deleting a config.nims block does make it go away today, but only by moving
# the heap around; the defect is upstream and latent, and the blocks in
# question (results-0.5 discovery, the reprobuild paths bootstrap) are
# load-bearing for the build. So: quarantine, and make the quarantine narrow
# enough to retire itself.
#
# HOW THE QUARANTINE RETIRES ITSELF
# ---------------------------------
# When src/lsp.nim fails, this script asks a second question: does a file THIS
# REPO DID NOT WRITE — one generated line of Nim, in the same directory, under
# the same config — fail too?
#
#   probe fails too   -> the toolchain is broken for this project. Exit 78,
#                        which ci/lib/lint-steps.sh reports as QUARANTINED:
#                        visible, counted, not fatal.
#   probe is clean    -> nimsuggest works here and src/lsp.nim specifically
#                        broke it. That is the regression the check has always
#                        existed to catch. Exit 1, and the job goes red.
#
# So this becomes a real gate again, with no edit to any file, on the day the
# pinned nimsuggest stops crashing on the probe — whether that is a toolchain
# bump or a change to config.nims. Nothing needs to remember to un-quarantine
# it.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 1

# The exit status ci/lib/lint-steps.sh reads as QUARANTINED. Kept as a literal
# here so this script stays runnable on its own, without sourcing the library.
QUARANTINE_RC=78

# nimsuggest has no timeout of its own and a wedged one would hang the job.
# `timeout` is coreutils and present in every shell this runs in; if it is not,
# fall back rather than refuse to check anything.
run_nimsuggest() {
	local target="$1"
	if command -v timeout >/dev/null 2>&1; then
		echo quit | timeout 600 nimsuggest --v4 "${target}" 2>&1
	else
		echo quit | nimsuggest --v4 "${target}" 2>&1
	fi
}

if ! command -v nimsuggest >/dev/null 2>&1; then
	echo "ERROR: nimsuggest is not on PATH — this check needs the dev shell." >&2
	exit 1
fi

target="src/lsp.nim"

out="$(run_nimsuggest "${target}")"
rc=$?

if [ "${rc}" -eq 0 ]; then
	echo "OK: nimsuggest starts without an error for ${target}"
	exit 0
fi

echo "nimsuggest failed for ${target} (exit ${rc}). Output:"
printf '%s\n' "${out}" | sed 's/^/    /'
echo

# ---------------------------------------------------------------------------
# The discriminating probe: one generated line of Nim, in the repo root so that
# it is compiled under exactly the same config.nims, and written by this script
# rather than by the project.
# ---------------------------------------------------------------------------
probe="ct_nimsuggest_probe_$$.nim"
trap 'rm -f "${repo_root:?}/${probe}"' EXIT
printf 'echo "nimsuggest toolchain probe"\n' >"${probe}"

probe_out="$(run_nimsuggest "${probe}")"
probe_rc=$?

if [ "${probe_rc}" -ne 0 ]; then
	echo "###############################################################################"
	echo "QUARANTINED: nimsuggest is broken for this project, independently of its code"
	echo "###############################################################################"
	echo "The same nimsuggest also fails (exit ${probe_rc}) on ${probe}, a single"
	echo "generated line of Nim that CodeTracer did not write:"
	printf '%s\n' "${probe_out}" | sed 's/^/    /'
	echo
	echo "That is an upstream nimsuggest defect triggered by this repo's config.nims,"
	echo "not a regression in src/lsp.nim. See the header of ci/test/nimsuggest-check.sh"
	echo "for the evidence (nim check is clean on the same file; --skipProjCfg makes it"
	echo "go away; the failure mode alternates between SIGSEGV and an AssertionDefect"
	echo "depending on unrelated config length)."
	echo
	echo "WHAT MAKES THIS FATAL AGAIN: nothing to edit. The moment the probe above"
	echo "passes — a toolchain bump, or a config.nims that no longer trips it — this"
	echo "script starts failing the job again for any nimsuggest breakage in"
	echo "${target}."
	exit "${QUARANTINE_RC}"
fi

echo "###############################################################################"
echo "REGRESSION: nimsuggest works here, but not on ${target}"
echo "###############################################################################"
echo "The probe file ${probe} started nimsuggest cleanly under the same config, so"
echo "the toolchain is fine and ${target} is what broke it."
echo

# A quoted heredoc rather than a run of `echo`s: the text is full of backticks
# and both kinds of quote, and escaping it per-line made the formatter and the
# linter disagree with each other — shfmt rewrites the escapes to single quotes,
# and SC2016 then reads the backticks inside them as an expansion someone meant
# to interpolate. <<'EOF' expands nothing, so the block is literal and neither
# tool has an opinion about it.
cat <<'EOF'
  suggestion: often this is because of adding chronicles log statements
    with distinct types, or maybe object containing distinct types
      like `debug "message", taskId`
    or other kinds of problems with args
    --
    changing to `taskId=taskId.string` seems to be a workaround
    if it's an object, changing to `obj=obj.repr` seems to maybe help
EOF
exit 1
