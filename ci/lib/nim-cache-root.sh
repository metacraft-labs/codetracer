#!/usr/bin/env bash
# shellcheck shell=bash
#
# nim-cache-root.sh — the nimcache root for THIS checkout, not for whoever
# compiled here last.
#
# Sourceable AND executable, because the callers are not all shell scripts:
# `justfile` one-line recipes run under `sh` and cannot source a bash library,
# so they take the answer from `$(ci/lib/nim-cache-root.sh)` instead.
#
# WHY THIS EXISTS
# ---------------
# Thirty-six gates spelled their compiler cache as
#
#     cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/<gate-name>"
#
# The key names the CONSUMER and nothing names the TREE. That is enough to keep
# two different gates apart and useless for keeping two checkouts of the same
# gate apart, which is the collision that actually happens here: this
# workstation carries ~35 worktrees of one repository, every one of them able to
# run `ci/test/web-bundle-smoke.sh`, and every one of them compiling into
# `/tmp/ct-nim-cache/web-bundle`.
#
# MEASURED, not predicted. At the time this file was written `/tmp/ct-nim-cache`
# held 34 directories and 1.9 GB. Exactly four carried a checkout key
# (`codetracer-m0b-2320560076`, `ct-eventlog-static-4235288490`,
# `ct-gatewire-385020743`, `ct-watch-3498879361`) — those are the ones
# `ci/lib/run-nim-test-lane.sh` writes since it fixed this same defect for
# itself on 2026-09-03. The other thirty were bare consumer names, each one
# shared by every worktree that had ever run that gate.
#
# THE FAILURE IS SILENT AND POINTS THE WRONG WAY, which is why it survived so
# long. Nim reuses a cached artefact when it believes the inputs are unchanged,
# so the loser of a race links objects built from a DIFFERENT TREE and still
# reports a clean pass. The loud outcome is a confusing compile error. The quiet
# one is a green gate that measured someone else's source — or a mutation arm
# reporting SURVIVED because the mutation it planted was never in the bytes it
# graded. That reads as "this assertion does not detect this defect" and sends
# the next person to strengthen a test that was already fine. This campaign has
# already lost time to exactly that.
#
# This is the same existence-checked-as-freshness mistake as everywhere else in
# the sweep, wearing a directory name: the cache path answers "is there a build
# for a gate called `web-bundle`?" where the question was "is there a build for
# a gate called `web-bundle` FROM THIS SOURCE TREE?".
#
# WHY THE ABSOLUTE PATH AND NOT THE BASENAME
# ------------------------------------------
# Keyed on a checksum of the checkout's absolute path. Worktrees are siblings
# with distinct basenames today, but a name is not an identity, and two clones
# of the same repository under different parents would collide again. The
# basename is kept in the directory name only so that a human reading `ls
# /tmp/ct-nim-cache` can tell the directories apart.
#
# `cksum` because it is POSIX, unlike `shasum`/`sha1sum`, which differ across
# macOS and Linux — these gates run on both. It is not a security boundary and
# does not need to be one; it needs to differ when the path differs.
#
# WHY AN EXPLICIT CT_NIM_CACHE_ROOT IS STILL HONOURED VERBATIM
# ------------------------------------------------------------
# A caller that sets it has said which directory it wants, usually because it is
# handing a scratch directory to a child process it is about to grade (see
# `ci/test/build-error-nav-mutations.sh`). Second-guessing that would break the
# one caller that is being deliberate. `ci/lib/run-nim-test-lane.sh` made the
# same choice; this file matches it so the two cannot drift.
#
# Usage:
#   source ci/lib/nim-cache-root.sh
#   cache="$(ct_nim_cache_root "${repo_root}")/web-bundle"
#
# The argument is optional. Pass the checkout root when the caller already
# knows it — every gate here computes `repo_root` from `BASH_SOURCE` before it
# does anything else, and that is a more dependable answer than asking git,
# which fails in a tarball export and in a container that mounts the source
# without `.git`.

# Print the nimcache root for a checkout. Never fails: the fallback chain ends
# at `pwd`, which is always something, because a cache root that errors out
# would turn a compile step into a hard stop for no safety gain.
ct_nim_cache_root() {
	if [ -n "${CT_NIM_CACHE_ROOT:-}" ]; then
		printf '%s' "${CT_NIM_CACHE_ROOT}"
		return 0
	fi

	local checkout tag
	checkout="${1:-}"
	if [ -z "${checkout}" ]; then
		checkout="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	fi
	[ -n "${checkout}" ] || checkout="$(pwd)"

	tag="$(printf '%s' "${checkout}" | cksum | awk '{print $1}')"
	printf '%s' "/tmp/ct-nim-cache/$(basename "${checkout}")-${tag}"
}

# The nimcache root for the TUP build of a checkout (`src/Tuprules.tup`).
#
# The same per-checkout directory as `ct_nim_cache_root`, with one difference:
# an explicit CT_NIM_CACHE_ROOT is NOT honoured. Three reasons, all specific
# to tup:
#
#   * On Windows tup flags every write a command makes outside its declared
#     outputs, so the Nim rules carry a STATIC exclusion regex for the cache
#     (`NIM_SIDE_OUTPUTS_IGNORE`, `[/\\]tmp[/\\]ct-nim-cache[/\\].*`). A scratch
#     override elsewhere would fail the Windows build with undeclared outputs;
#     tup cannot escape an arbitrary path into a regex at parse time.
#   * The root is part of every Nim rule's command string, and tup re-runs
#     every command whose string changes. A per-caller override would turn a
#     child process's scratch directory into a full Nim rebuild of the
#     checkout, and another one when the next plain build runs.
#   * The callers that set CT_NIM_CACHE_ROOT (the mutation graders) hand it to
#     a single `nim` invocation, never to a tup build.
#
# The callers (`scripts/build-once.sh`, `scripts/build.sh`, `ci/build/dev.sh`,
# the dev shell and the non-Nix environment scripts) export the answer as
# CT_TUP_NIM_CACHE_ROOT, which `src/Tuprules.tup` imports.
#
# The checkout is normalised to its physical path first. The checksum is of
# the path STRING, and these callers spell one tree differently (build-once.sh
# `cd .. && pwd`, the dev shell `git rev-parse --show-toplevel`, which resolves
# symlinks, non-nix-build/env.sh `.../non-nix-build/..`). Disagreeing would not
# collide, but it would make every switch between `just build-once` and a plain
# `tup` rebuild all Nim targets.
ct_tup_nim_cache_root() {
	local CT_NIM_CACHE_ROOT=""
	local checkout="${1:-}"
	if [ -n "${checkout}" ] && [ -d "${checkout}" ]; then
		checkout="$(cd "${checkout}" && pwd -P)"
	fi
	ct_nim_cache_root "${checkout}"
}

# Run directly rather than sourced: print the root and exit. `${BASH_SOURCE[0]}`
# differs from `$0` exactly when this file was sourced, which is the discrimination
# needed — a version check or a `return` probe would both be less direct.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	# Executed from a checkout, so `git rev-parse` is the right question to ask;
	# the caller has no `repo_root` variable to hand us.
	#
	# `--tup` selects the tup build's root (see `ct_tup_nim_cache_root`), so the
	# environment scripts that are not bash libraries can ask for it too.
	if [ "${1:-}" = "--tup" ]; then
		shift
		ct_tup_nim_cache_root "$@"
	else
		ct_nim_cache_root "$@"
	fi
	printf '\n'
fi
