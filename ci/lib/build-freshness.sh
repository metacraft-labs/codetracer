# shellcheck shell=bash
#
# build-freshness.sh — assert that a BUILD-ONCE ARTEFACT a lane is about to
# measure through was built FROM THE SOURCES IN THIS TREE, rather than merely
# that it exists.
#
# WHY THIS EXISTS — measured, 2026-10-12
# ---------------------------------------
# PLAT-37's two capture lanes produced a cross-renderer parity reading that
# was reported as the first taken "against one build". It was not. The GPUI
# arm ran `build/bin/codetracer-gpui` dated **2026-10-07 17:51**; the Electron
# arm ran a bundle from **2026-10-12**. The two were **127 commits apart**.
#
# The whole of the GPUI lane's subject check was, at
# `ci/test/plat37-macos-window-capture.sh:187`:
#
#     [ -x "${BIN}" ] || fail "${BIN} is not built. Run \`just build-gpui\`."
#
# — an EXISTENCE check standing in for a FRESHNESS check, which is the exact
# substitution `ci/lib/wasm-engine-freshness.sh` was written for and which
# 464b8f296 catalogued for four other clusters ("Every site here asked 'does
# this artefact exist?' where it needed to ask 'is this artefact of THIS
# source?'").
#
# The cost was not abstract. Eleven findings were raised against two different
# programs and attributed to one; one of them (`PARITY-S2`) had the deficient
# side BACKWARDS — the stale GPUI binary still drew a Timeline tab that
# `740d76be2` had deliberately removed, so the finding said Electron was
# missing a panel that Electron was correct to lack. Acting on it would have
# re-added a deleted panel against a green assertion.
#
# What made it invisible rather than merely wrong: the lane's manifest recorded
# the provenance of the Rust SHIM — in both polarities, against a literal, with
# a measurement attached — and recorded NOTHING about the Nim executable. The
# one artefact nobody wrote a provenance line for is the one that was stale.
#
# > **An artefact a lane did not build is an artefact the lane must name.**
# > `Cross-Renderer-Visual-Alignment.md` §2.2 rule 4 binds reviewer->capture:
# > the two arms must be captured together. It does not bind capture->source.
# > Aligning WHEN the pixels were taken is not aligning WHAT was running.
#
# THE RULE, AND WHY IT IS NOT MTIME
# ---------------------------------
# The obvious check is "is the binary newer than the newest source?", and it
# is the one to avoid. Three failure modes, two of them FALSE GREENS:
#
#  1. **mtime is not a function of content.** `cp`, `rsync -t`, `tar -p` and a
#     restored backup all carry an mtime forward. A binary copied in from
#     another checkout can be arbitrarily old in content and arbitrarily new in
#     mtime. That is a false green, and it is the direction that costs.
#  2. **A no-op rebuild need not rewrite the output.** blocktracer 6f106f2 paid
#     for this: the gate fires on a tree that has just built correctly and the
#     remedy it prints cannot clear it. In that gate's words, *a gate whose own
#     remedy cannot clear it is not a gate, it is a wall.*
#  3. **git rewrites source mtimes.** A branch switch or a `repro ws sync`
#     stamps every touched file with the checkout time, so sources routinely
#     become "newer" than a binary that is perfectly current. False red.
#
# So this file compares CONTENT, in the shape `wasm-engine-freshness.sh`
# established: the build writes a STAMP recording the digest of the inputs it
# compiled, and a gate recomputes that digest from the tree it is standing in.
# With the same compiler, rebuilding clears a source mismatch: the stamp is
# rewritten from the current tree whether or not the emitted bytes changed.
# A different compiler on PATH is refused separately, with a dev-shell remedy.
#
# WHERE THE INPUT SET COMES FROM — the compiler, not a guess
# ----------------------------------------------------------
# The input set is NOT a hand-maintained list of directories. A hand-maintained
# list is wrong in both directions: too narrow and it misses the edit that
# matters, too wide and every unrelated `src/common/` touch becomes a wall.
#
# It is `nim`'s OWN answer. `nim c --genDeps:on --compileOnly` writes
# `<nimcache>/<entry>.deps`: one absolute path per module the semantic pass
# actually read. Measured 2026-10-12 for `src/frontend/gpui/main.nim`: 371
# lines, of which 238 are in-tree — and they span FOUR repositories
# (`codetracer`, `isonim-gpui`, `isonim`, `nim-everywhere`), which no list
# written by hand in this repo would have covered.
#
# Regenerating it costs **10 s** (measured, same date, warm). The assertion
# spends it rather than trusting the file list recorded in the stamp, and that
# is deliberate: a stamped list cannot grow. If the assertion only re-digested
# the paths the OLD build saw, a module newly pulled into the closure would be
# invisible to it. Recomputing the closure makes the gate answer the question
# it claims to answer.
#
# THE TOOLCHAIN IS COVERED, unlike in the wasm precedent
# ------------------------------------------------------
# `wasm-engine-freshness.sh` records, honestly, that it does NOT cover the
# toolchain: "A toolchain change with identical sources will not be caught
# here." Here it is covered, and for free, because a Nix store path IS a
# content hash. Store entries in the `.deps` list are digested BY PATH rather
# than by content: cheap (no I/O over a 133-file stdlib), and strictly more
# sensitive than hashing their bytes, since the path pins the whole derivation.
#
# This is not hypothetical on this host. Measured 2026-10-12, in the same
# terminal:
#
#   ambient shell (a stale .direnv profile):  nim-wrapper-2.2.4   (f3wv64sq...)
#   a real `nix develop`:                     nim-fork-2.3.1-...  (dgc3nma3...)
#
# Two different compilers, one of them not the project's fork at all. A
# source-only digest would call a binary built by the wrong one fresh.
#
# WHAT IS NOT COVERED — say it rather than imply coverage
# -------------------------------------------------------
#  * **`staticRead` / `staticExec` inputs.** Nim does not list them in
#    `.deps`. A module that `staticRead`s a JSON file changes behaviour when
#    that JSON changes while the digest holds still. Callers that know of such
#    an input pass it to `bf_digest_extra_file`.
#  * **A new file that an existing unchanged import starts resolving to.**
#    Adding `foo.nim` beside a package so that an existing `import foo` picks
#    it up instead of the stdlib's. Every OTHER way of entering the closure
#    requires editing a file already in it (you must write the `import`
#    somewhere), and that edit moves the digest.
#  * **Link-time inputs that are not Nim modules** — the `isonim-gpui` cdylib
#    above all. That one is already covered, separately and better, by the
#    windowed shim's two-polarity `font_kit` literal probe in the GPUI lane.
#
# USAGE
# -----
#   source ci/lib/build-freshness.sh
#
#   # at BUILD time, as the build's last act:
#   bf_write_stamp <stamp> <artefact> <input-digest> <kind> [<repo> ...]
#
#   # at GATE time, before anything is measured:
#   bf_assert_fresh <stamp> <artefact> <input-digest> <subject> <remedy>
#
# NOTHING HERE EXITS, for the reason `sha256.sh` and `wasm-engine-freshness.sh`
# both record: every caller owns a refusal idiom that prints its own verdict,
# and a sourced library that exited would take that sentence away.

# --------------------------------------------------------------------------
# Digest primitives. `sha256.sh` is THE digest tool resolver in this tree and
# refuses loudly when neither `sha256sum` nor `shasum` is present — which is
# the behaviour wanted here, because a silently-empty digest would make every
# comparison below compare "" against "" and pass.
# --------------------------------------------------------------------------
# shellcheck source=ci/lib/sha256.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sha256.sh"

bf__sha256_stdin() {
	ct_sha256_require || return 2
	"${CT_SHA256_CMD}" "${CT_SHA256_ARGS[@]}" | cut -d' ' -f1
}

# The sha256 of a file, or the literal `absent`. An absent input is part of the
# identity rather than a hole in it: an artefact built WITH a sibling present
# and checked WITHOUT it must not compare equal.
bf__sha256_or_absent() {
	if [ ! -f "$1" ]; then
		printf 'absent'
		return 0
	fi
	ct_sha256_file "$1" || printf 'unreadable'
}

# --------------------------------------------------------------------------
# bf_deps_input_digest <deps-file> <workspace-root>
#
# The whole input identity of a Nim artefact, as one hex digest, derived from
# the compiler's own `.deps` listing.
#
#   in-tree file  ->  <sha256>\t<path relative to the workspace root>
#   /nix/store/*  ->  store\t<the store path with the /nix/store/ prefix cut>
#
# Paths are made relative to the WORKSPACE root (not the repo root) because the
# closure spans sibling repositories; relative so that the digest does not
# depend on where the workspace is checked out.
#
# `sort` before hashing is load-bearing and not tidiness: `.deps` order follows
# the semantic pass, which is not stable under unrelated edits, and an unstable
# order would make two identical trees digest differently — a false red, which
# is the failure mode this file exists to avoid.
# --------------------------------------------------------------------------
bf_deps_input_digest() {
	local deps="$1" ws="$2" line rel
	if [ ! -f "${deps}" ]; then
		echo "build-freshness: no deps listing at ${deps}" >&2
		return 2
	fi
	{
		while IFS= read -r line; do
			[ -n "${line}" ] || continue
			case "${line}" in
			/nix/store/*)
				printf 'store\t%s\n' "${line#/nix/store/}"
				;;
			"${ws}"/*)
				rel="${line#"${ws}"/}"
				printf '%s\t%s\n' "$(bf__sha256_or_absent "${line}")" "${rel}"
				;;
			*)
				# Outside both the store and the workspace. Digest it by
				# content under its absolute path: unusual, but recording it
				# as-is beats dropping it, and dropping it is what would make
				# the digest quietly incomplete.
				printf '%s\t%s\n' "$(bf__sha256_or_absent "${line}")" "${line}"
				;;
			esac
		done <"${deps}"
	} | LC_ALL=C sort | bf__sha256_stdin
}

# bf_digest_extra_file <path> <label> — for a `staticRead` input the compiler
# does not list. Emits one digest line to stdout, to be folded into a caller's
# own `{ ... } | sort | sha256` block.
bf_digest_extra_file() {
	printf '%s\t%s\n' "$(bf__sha256_or_absent "$1")" "$2"
}

# --------------------------------------------------------------------------
# bf_write_stamp <stamp> <artefact> <input-digest> <kind> [<repo-dir> ...]
#
# Written by the BUILD as its last act. The artefact's own sha256 is recorded
# alongside the input digest so that a stamp separated from its binary — which
# is exactly what copying a `build/bin` between checkouts produces — is
# detectable as such rather than read as describing whatever is now beside it.
# --------------------------------------------------------------------------
# `BF_BUILDER` — who actually compiled the artefact, set by the caller before
# calling `bf_write_stamp`. DEFAULTS TO THE NIM ON PATH, which is right only
# when the build ran `nim` directly.
#
# IT WAS WRONG ONCE, within minutes of being written, and the error is worth
# keeping because it is this file's own subject matter. The first Electron
# stamp recorded
#
#     built_by=/nix/store/f3wv64sq...-arm64-apple-darwin-nim-wrapper-2.2.4/bin/nim
#
# because `electron-stamp` happened to be invoked from the ambient shell. That
# compiler did not build the bundle and never could have: `repro` compiles it
# with its OWN tool-store nim (measured the same evening:
# `~/Library/Caches/repro/store/tool-store/prefixes/nim_2.2.10/...`), which is
# neither the ambient 2.2.4 wrapper nor the dev shell's 2.3.1 fork. A
# provenance record that names the wrong compiler is worse than one that names
# none: it answers the question confidently and falsely, which is the shape of
# every defect this file exists to stop.
BF_BUILDER="${BF_BUILDER:-}"

bf_write_stamp() {
	local stamp="$1" artefact="$2" input_digest="$3" kind="$4"
	shift 4
	local repo

	if [ ! -e "${artefact}" ]; then
		echo "build-freshness: cannot stamp — ${artefact} does not exist" >&2
		return 1
	fi
	if [ -z "${input_digest}" ]; then
		echo "build-freshness: refusing to write an empty input digest to ${stamp}." >&2
		echo "  An empty digest compares equal to the next empty digest, so the" >&2
		echo "  stamp would assert nothing while looking like it asserted." >&2
		return 1
	fi

	mkdir -p "$(dirname "${stamp}")"
	{
		echo "# Written by the build that produced ${artefact##*/}."
		echo "# Read by ci/lib/build-freshness.sh. DO NOT EDIT BY HAND: the only"
		echo "# way to make this file true again is to rebuild the artefact."
		echo "kind=${kind}"
		echo "artefact=${artefact}"
		echo "artefact_sha256=$(bf__sha256_or_absent "${artefact}")"
		echo "artefact_bytes=$(wc -c <"${artefact}" | tr -d ' ')"
		echo "input_digest=${input_digest}"
		echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "built_by=${BF_BUILDER:-$(command -v nim 2>/dev/null || echo unknown)}"
		for repo in "$@"; do
			[ -d "${repo}/.git" ] || [ -f "${repo}/.git" ] || continue
			printf 'repo_head=%s %s %s\n' \
				"$(basename "${repo}")" \
				"$(git -C "${repo}" rev-parse HEAD 2>/dev/null || echo unknown)" \
				"$(git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
		done
	} >"${stamp}"
	echo "build-freshness: stamped ${stamp}"
	echo "  input_digest=${input_digest}"
}

bf_stamp_field() {
	[ -f "$1" ] || return 1
	sed -n "s/^$2=//p" "$1" | head -1
}

# bf_stamp_repo_heads <stamp> — the recorded `repo_head=` lines, for a manifest.
bf_stamp_repo_heads() {
	[ -f "$1" ] || return 1
	sed -n 's/^repo_head=//p' "$1"
}

# --------------------------------------------------------------------------
# bf_assert_fresh <stamp> <artefact> <input-digest> <subject> <remedy>
#
# THE GATE. Returns 0 only when the artefact on disk is the one the stamp
# describes AND the stamp was written from inputs identical to this tree's.
# Prints the reason and the remedy on stderr and returns 1 otherwise.
#
# REFUSES, NEVER WARNS. A lane that printed a warning and carried on with a
# stale binary is the defect being fixed here, not a milder form of it: the
# contaminated reading went out with its skew fully visible in two `ls -la`
# outputs that nobody had been given a reason to run.
# --------------------------------------------------------------------------
bf_assert_fresh() {
	local stamp="$1" artefact="$2" actual_inputs="$3" subject="$4" remedy="$5"

	if [ ! -e "${artefact}" ]; then
		echo "STALE ${subject}: ${artefact} does not exist." >&2
		echo "${remedy}" >&2
		return 1
	fi

	if [ ! -f "${stamp}" ]; then
		echo "STALE ${subject}: ${artefact} carries no freshness stamp." >&2
		echo "  expected a stamp at: ${stamp}" >&2
		echo "  artefact mtime:      $(date -u -r "${artefact}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" >&2
		echo "  this tree's inputs:  ${actual_inputs}" >&2
		echo >&2
		echo "  An UNSTAMPED artefact is the one that goes green against a build" >&2
		echo "  from another week, because nothing about it says which week it" >&2
		echo "  is from. On 2026-10-12 PLAT-37's two capture lanes published a" >&2
		echo "  parity reading over a GPUI binary and an Electron bundle 127" >&2
		echo "  commits apart; eleven findings were raised against the pair, and" >&2
		echo "  one (PARITY-S2) had the deficient renderer BACKWARDS. Neither" >&2
		echo "  lane could have detected it: neither artefact carried a stamp." >&2
		echo "${remedy}" >&2
		return 1
	fi

	local recorded_art actual_art
	recorded_art="$(bf_stamp_field "${stamp}" artefact_sha256)"
	actual_art="$(bf__sha256_or_absent "${artefact}")"
	if [ "${recorded_art}" != "${actual_art}" ]; then
		echo "STALE ${subject}: the stamp does not describe the artefact beside it." >&2
		echo "  stamp records: ${recorded_art}" >&2
		echo "  on disk:       ${actual_art}" >&2
		echo "  This is what copying a build directory between checkouts produces:" >&2
		echo "  the stamp travelled and the binary did not, or the reverse." >&2
		echo "${remedy}" >&2
		return 1
	fi

	local recorded_inputs
	recorded_inputs="$(bf_stamp_field "${stamp}" input_digest)"
	if [ -z "${recorded_inputs}" ] || [ -z "${actual_inputs}" ]; then
		echo "STALE ${subject}: an input digest is EMPTY, so nothing was compared." >&2
		echo "  stamp records: '${recorded_inputs}'" >&2
		echo "  this tree:     '${actual_inputs}'" >&2
		echo "  Refused rather than passed: two empty strings compare equal, and" >&2
		echo "  a comparison that cannot fail is not an assertion." >&2
		echo "${remedy}" >&2
		return 1
	fi
	if [ "${recorded_inputs}" != "${actual_inputs}" ]; then
		echo "STALE ${subject}: built from different sources than this tree has." >&2
		echo "  artefact built from inputs: ${recorded_inputs}" >&2
		echo "  this tree's inputs:         ${actual_inputs}" >&2
		echo "  artefact built at:          $(bf_stamp_field "${stamp}" built_at)" >&2
		echo "  artefact built by:          $(bf_stamp_field "${stamp}" built_by)" >&2
		bf_stamp_repo_heads "${stamp}" | while read -r line; do
			echo "  built at repo head:         ${line}" >&2
		done
		echo "  Measuring through it would grade code that is not in this tree." >&2
		echo "${remedy}" >&2
		return 1
	fi

	echo "  ${subject}: ${artefact}"
	echo "    built from THIS tree (inputs ${actual_inputs:0:12}, artefact ${actual_art:0:12})"
	echo "    built at $(bf_stamp_field "${stamp}" built_at) by $(bf_stamp_field "${stamp}" built_by)"
	return 0
}

# ==========================================================================
# The `codetracer-gpui` specialisation.
#
# ONE definition of the compile arguments, used by BOTH the build recipe and
# the gate. Verification-Harness-Traps §14: a second copy of a predicate is a
# second thing that can be wrong while its twin goes on agreeing with itself —
# and here the two copies would be a build and the check on that build, which
# is the pair with the least excuse for disagreeing.
# ==========================================================================
BF_GPUI_ENTRY="src/frontend/gpui/main.nim"
BF_GPUI_BIN="build/bin/codetracer-gpui"
BF_GPUI_STAMP="build/bin/.codetracer-gpui.build-stamp"

# The flags that define WHICH program is built. `--mm:orc -d:release` is part
# of the identity (a debug build is a different artefact), `--hints:off` is
# not, but passing the full set keeps build and gate on one string.
bf_gpui_nim_args() {
	printf '%s\n' --mm:orc -d:release --path:src/frontend/viewmodel
}

# bf_gpui_input_digest <repo-root> [<stamp>] — regenerate and digest the closure.
# Gates pass the stamp to compare compiler identities BEFORE computing inputs.
# Builders and digest-only diagnostics omit it: an older stamp must not prevent
# an intentional toolchain upgrade from producing a new build and stamp.
# Prints the digest on stdout; everything else goes to stderr so the caller can
# capture it in a `$(...)`.
bf_gpui_input_digest() {
	local root="$1" stamp="${2:-}" ws deps_cache deps rc compiler recorded_compiler
	ws="$(cd "${root}/.." && pwd)"
	deps_cache="${root}/build/nimcache/codetracer-gpui-deps"

	if ! compiler="$(command -v nim)"; then
		echo "build-freshness: nim is not on PATH, so the gpui input closure" >&2
		echo "  cannot be recomputed. Run inside the dev shell:" >&2
		echo "      cd ${root} && nix develop" >&2
		return 2
	fi

	# A closure computed by another compiler includes another standard library.
	# Comparing it with the builder's closure cannot diagnose source freshness.
	# Keep this check on the shared digest route so the capture lane (which saves
	# the digest for its manifest) and the standalone gate cannot disagree.
	if [ -n "${stamp}" ] && [ -f "${stamp}" ]; then
		recorded_compiler="$(bf_stamp_field "${stamp}" built_by)"
		if [ -z "${recorded_compiler}" ]; then
			echo "build-freshness: the GPUI stamp records no compiler identity." >&2
			echo "  Rebuild and stamp inside the dev shell:" >&2
			echo "      cd ${root} && nix develop --command just build-gpui" >&2
			return 2
		fi
		if [ "${compiler}" != "${recorded_compiler}" ]; then
			echo "build-freshness: the resolved GPUI compiler differs from the one recorded in the stamp." >&2
			echo "  artefact built by: ${recorded_compiler}" >&2
			echo "  resolved nim:      ${compiler}" >&2
			echo "  Source freshness cannot be compared across these compilers." >&2
			echo "  Please re-run inside the dev shell:" >&2
			echo "      cd ${root} && nix develop" >&2
			return 2
		fi
	fi

	rm -rf "${deps_cache}"
	mkdir -p "${deps_cache}"
	# `--compileOnly` stops before the C backend and the link, which is what
	# makes this 10 s rather than a full build. `--genDeps:on` is what writes
	# the listing. Output goes to a scratch path that is never executed.
	local args=()
	while IFS= read -r a; do args+=("${a}"); done < <(bf_gpui_nim_args)
	(
		cd "${root}" || exit 2
		"${compiler}" c --genDeps:on --compileOnly --hints:off --warnings:off \
			"${args[@]}" \
			--nimcache:"${deps_cache}" \
			-o:"${deps_cache}/unused-deps-probe" \
			"${BF_GPUI_ENTRY}"
	) >"${deps_cache}/.genDeps.log" 2>&1
	rc=$?
	deps="${deps_cache}/main.deps"
	if [ "${rc}" -ne 0 ] || [ ! -f "${deps}" ]; then
		echo "build-freshness: the gpui input closure could not be computed" >&2
		echo "  (nim c --genDeps exited ${rc}; no ${deps})." >&2
		echo "  This is a REFUSAL and not a pass: a closure that cannot be" >&2
		echo "  computed is not a closure that matched." >&2
		tail -20 "${deps_cache}/.genDeps.log" >&2 2>/dev/null
		return 2
	fi

	# The scenario set is not a Nim module and so is not in `.deps`, but it
	# selects what the lane drives. Folded in explicitly.
	{
		bf_deps_input_digest "${deps}" "${ws}" |
			while IFS= read -r d; do printf '%s\tNIM-CLOSURE\n' "${d}"; done
		bf_digest_extra_file "${root}/src/tests/visual/scenarios.json" "scenarios.json"
	} | LC_ALL=C sort | bf__sha256_stdin
}

# bf_gpui_write_stamp <repo-root> — the build's last act.
bf_gpui_write_stamp() {
	local root="$1" ws digest
	ws="$(cd "${root}/.." && pwd)"
	digest="$(bf_gpui_input_digest "${root}")" || return 1
	bf_write_stamp "${root}/${BF_GPUI_STAMP}" "${root}/${BF_GPUI_BIN}" \
		"${digest}" "codetracer-gpui" \
		"${root}" "${ws}/isonim-gpui" "${ws}/isonim" "${ws}/nim-everywhere"
}

# bf_gpui_assert_fresh <repo-root> — the gate.
bf_gpui_assert_fresh() {
	local root="$1" digest
	digest="$(bf_gpui_input_digest "${root}" "${root}/${BF_GPUI_STAMP}")" || return 1
	bf_assert_fresh "${root}/${BF_GPUI_STAMP}" "${root}/${BF_GPUI_BIN}" \
		"${digest}" "GPUI BINARY" \
		"  Rebuild it, which rewrites the stamp from this tree:
      cd ${root} && nix develop --command just build-gpui"
}

# (The direct-invocation dispatch is at the END of this file, deliberately.
# See the comment there — it has already been wrong once.)

# ==========================================================================
# The ELECTRON FRONT-END BUNDLE specialisation.
#
# WHY THIS ONE IS DIGESTED DIFFERENTLY FROM THE GPUI BINARY — and it is a
# weaker rule, so it is labelled as one rather than left to look equivalent.
#
# The GPUI binary has ONE Nim entry point and the compiler will hand over its
# exact closure for 10 s. The bundle has THREE, built by `repro` out of
# `repro.nim` with three different define sets and two different backends:
#
#   src/build-debug-repro/ui.js    <- src/frontend/ui_js.nim    (nim js,
#                                     CommonNimDefines & HmrRendererDefines)
#   src/build-debug-repro/index.js <- src/frontend/index.nim    (nim js,
#                                     CommonNimDefines & ctIndex,nodejs)
#   src/build-debug-repro/bin/ct   <- src/ct/codetracer.nim     (nim c,
#                                     NativeDefines)
#
# Reproducing those three flag sets HERE would be a second copy of
# `repro.nim`'s truth, in a file that nothing links to it — and a second copy
# of a predicate is a second thing that can be wrong while its twin goes on
# agreeing with itself (Verification-Harness-Traps §14). A define set that
# drifted would silently change `when defined(...)` imports and so change the
# closure, and the gate would be computing the closure of a program nobody
# builds.
#
# So the bundle is digested by its TRACKED SOURCE TREE instead, which needs no
# flags and cannot drift from `repro.nim`:
#
#   * `git ls-files -s` over the source roots. That prints mode + BLOB SHA-1 +
#     path for every tracked file, which IS a content digest, straight out of
#     the index. Measured 2026-10-12: 1,786 files in 64 ms, with no file read.
#   * The index alone is NOT enough, and this is the hole that would matter
#     most in practice: a file edited and not staged still shows its OLD blob.
#     So the unstaged working-tree content and the untracked files in those
#     roots are folded in on top. Without that overlay the gate would call a
#     bundle fresh against sources the author is in the middle of changing,
#     which is the single most common way a developer's capture goes stale.
#
# OVER-APPROXIMATION, DELIBERATE AND NAMED. The roots include
# `src/frontend/gpui/**`, which no Electron entry point compiles. An edit
# there therefore makes this gate demand a bundle rebuild it does not strictly
# need. That is the SAFE direction (a false red, never a false green), and for
# this campaign it is arguably the right behaviour rather than a tolerated
# cost: the whole point of PLAT-37's parity reading is that both arms are of
# ONE checkout, so "the other renderer moved" is a real reason to re-take the
# reference set. The escape hatch is the remedy itself — `just build-once` —
# and reprobuild caches the untouched edges, so the rebuild it forces is a
# cache check and a relink rather than a cold build.
#
# NOT COVERED, and weaker than the GPUI side in exactly this respect: the
# TOOLCHAIN. The GPUI digest gets it free, because the compiler's own `.deps`
# names the nim store path and a store path is a content hash. Nothing here
# sees the compiler at all, so a bundle built by a different nim with
# identical sources reads as fresh. The stamp records `built_by` so a reader
# can at least check it by eye.
# ==========================================================================
BF_ELECTRON_STAMP_NAME=".codetracer-bundle.build-stamp"

# The source roots, repo-relative. Declared ONCE and read by both the stamp
# writer and the gate.
bf_electron_roots() {
	printf '%s\n' \
		src/frontend \
		src/common \
		src/ct \
		libs \
		repro.nim \
		package.json \
		config.nims
}

# bf_electron_input_digest <repo-root>
bf_electron_input_digest() {
	local root="$1" f
	local roots=()
	while IFS= read -r r; do roots+=("${r}"); done < <(bf_electron_roots)

	if ! git -C "${root}" rev-parse --git-dir >/dev/null 2>&1; then
		echo "build-freshness: ${root} is not a git checkout, so the bundle's" >&2
		echo "  tracked-source digest cannot be computed. Refusing rather than" >&2
		echo "  returning a digest of nothing." >&2
		return 2
	fi

	{
		# Tracked content, from the index: mode, blob sha1, stage, path.
		git -C "${root}" ls-files -s -- "${roots[@]}"

		# The unstaged working-tree overlay. `git hash-object` digests what is
		# ON DISK, which is what the compiler would read.
		git -C "${root}" diff --name-only -- "${roots[@]}" |
			while IFS= read -r f; do
				[ -n "${f}" ] || continue
				printf 'worktree %s %s\n' \
					"$(git -C "${root}" hash-object -- "${root}/${f}" 2>/dev/null || echo absent)" \
					"${f}"
			done

		# Untracked, non-ignored files in the same roots. A new module dropped
		# in beside an existing one is a source change the index cannot see.
		git -C "${root}" ls-files --others --exclude-standard -- "${roots[@]}" |
			while IFS= read -r f; do
				[ -n "${f}" ] || continue
				printf 'untracked %s %s\n' \
					"$(git -C "${root}" hash-object -- "${root}/${f}" 2>/dev/null || echo absent)" \
					"${f}"
			done
	} | LC_ALL=C sort | bf__sha256_stdin
}

# bf_electron_write_stamp <repo-root> <build-dir>
bf_electron_write_stamp() {
	local root="$1" build_dir="$2" digest
	digest="$(bf_electron_input_digest "${root}")" || return 1
	# The bundle is compiled by `repro` with its OWN tool-store nim, not by the
	# nim on this PATH. Naming the ambient compiler here would be a confident
	# false answer; naming `repro` and its version is the true one.
	local BF_BUILDER
	BF_BUILDER="$(repro --version 2>/dev/null | head -1 || echo 'repro, unknown version') (compiles with its own tool-store nim, not the nim on PATH)"
	# `bin/ct` is the artefact the stamp is anchored to. The three outputs are
	# produced by one `repro build` invocation, so one of them standing for the
	# set is sound; `ui.js` and `index.js` are digested into the stamp as well
	# so that a partially-replaced bundle is still detectable.
	bf_write_stamp "${build_dir}/${BF_ELECTRON_STAMP_NAME}" \
		"${build_dir}/bin/ct" "${digest}" "codetracer-electron-bundle" \
		"${root}" || return 1
	{
		printf 'ui_js_sha256=%s\n' "$(bf__sha256_or_absent "${build_dir}/ui.js")"
		printf 'index_js_sha256=%s\n' "$(bf__sha256_or_absent "${build_dir}/index.js")"
	} >>"${build_dir}/${BF_ELECTRON_STAMP_NAME}"
}

# bf_electron_assert_fresh <repo-root> <build-dir>
bf_electron_assert_fresh() {
	local root="$1" build_dir="$2" digest stamp rc
	stamp="${build_dir}/${BF_ELECTRON_STAMP_NAME}"
	digest="$(bf_electron_input_digest "${root}")" || return 1
	bf_assert_fresh "${stamp}" "${build_dir}/bin/ct" "${digest}" \
		"ELECTRON BUNDLE" \
		"  Rebuild it, which rewrites the stamp from this tree:
      cd ${root} && nix develop --command just build-once" || return 1

	# The other two outputs of the same build. Checked AFTER the anchor so the
	# common failure reports the useful message first.
	local which recorded actual
	rc=0
	for which in ui_js index_js; do
		recorded="$(bf_stamp_field "${stamp}" "${which}_sha256")"
		case "${which}" in
		ui_js) actual="$(bf__sha256_or_absent "${build_dir}/ui.js")" ;;
		index_js) actual="$(bf__sha256_or_absent "${build_dir}/index.js")" ;;
		esac
		if [ -n "${recorded}" ] && [ "${recorded}" != "${actual}" ]; then
			echo "STALE ELECTRON BUNDLE: ${which} is not the one the stamp describes." >&2
			echo "  stamp records: ${recorded}" >&2
			echo "  on disk:       ${actual}" >&2
			echo "  The bundle has been partially replaced: bin/ct matches the" >&2
			echo "  stamp and this does not, so the three outputs are not of one" >&2
			echo "  build." >&2
			rc=1
		fi
	done
	return ${rc}
}

# ==========================================================================
# DIRECT INVOCATION — and it must stay THE LAST THING IN THIS FILE
#
#   bash ci/lib/build-freshness.sh [assert|digest|stamp|electron-assert] [root]
#
# THIS BLOCK HAS ALREADY BEEN WRONG ONCE, on 2026-10-12, in the hour it was
# written, and the way it was wrong is the one this whole file exists to stop.
#
# It originally sat in the middle of the file, because the Electron half was
# APPENDED after it. The dispatch therefore ran `bf_gpui_assert_fresh`,
# correctly got 1 back, printed the full nine-line refusal — and then the
# shell carried on reading the rest of the file. The script's exit status is
# the status of the LAST command it ran, which was a function DEFINITION, and
# a function definition succeeds. So:
#
#     STALE GPUI BINARY: built from different sources than this tree has.
#       artefact built from inputs: ae3e0bd5...
#       this tree's inputs:         b57f491f...
#       ...
#     EXIT=0
#
# A gate that prints its own refusal in full and then reports success. Every
# caller using `|| fail` would have sailed straight through it, and the
# message would have scrolled past in a log as evidence that the check was
# working.
#
# It was caught only because the falsifiability run EXECUTED the negative
# case and READ THE EXIT CODE, instead of reading the message and being
# satisfied. `Verification-Harness-Traps`: an assertion a broken state also
# satisfies is not an assertion — and the broken state here was the assertion
# itself.
#
# Two things keep it fixed: this block is last, and it `exit`s with the status
# explicitly rather than letting it fall out of the end of the file. The
# `exit` is what makes the position non-load-bearing, so adding another
# section below would be merely untidy rather than silently disarming.
# ==========================================================================
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	bf__cmd="${1:-assert}"
	bf__root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	case "${bf__cmd}" in
	assert)
		bf_gpui_assert_fresh "${bf__root}"
		exit $?
		;;
	digest)
		bf_gpui_input_digest "${bf__root}"
		exit $?
		;;
	stamp)
		bf_gpui_write_stamp "${bf__root}"
		exit $?
		;;
	electron-assert)
		bf_electron_assert_fresh "${bf__root}" \
			"${CODETRACER_BUILD_DIR:-${bf__root}/src/build-debug-repro}"
		exit $?
		;;
	electron-digest)
		bf_electron_input_digest "${bf__root}"
		exit $?
		;;
	electron-stamp)
		bf_electron_write_stamp "${bf__root}" \
			"${CODETRACER_BUILD_DIR:-${bf__root}/src/build-debug-repro}"
		exit $?
		;;
	*)
		echo "usage: $0 [assert|digest|stamp|electron-assert|electron-digest|electron-stamp] [repo-root]" >&2
		exit 2
		;;
	esac
fi
