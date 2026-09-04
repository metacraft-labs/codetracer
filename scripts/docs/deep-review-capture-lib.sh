#!/usr/bin/env bash
# NOT-A-CI-GATE: a library for documentation tooling.
#
# The shared machinery behind the two DeepReview capture scripts. Its
# other consumer, tools/visual-review/capture-deepreview-views.sh, is a
# design-review harness -- also not a gate.
# Shared machinery for photographing a real `ct review` session.
#
# Two consumers, with different purposes and deliberately different fixtures:
#
#   * `scripts/docs/capture-deep-review-screenshots.sh` — the DOCUMENTATION
#     capture. Two images, published in the book next to prose that quotes the
#     fixture program line for line (`docs/book-isonim/content/usage_guide/
#     deep_review.md`). Its fixture is therefore frozen: changing a byte of it
#     silently falsifies the surrounding prose.
#
#   * `tools/visual-review/capture-deepreview-views.sh` — the DESIGN REVIEW
#     harness (UD-0). Many views, many viewport sizes, both themes, captured
#     over and over as the campaign lands. It needs a much richer corpus —
#     collapsed context regions, intra-line edits, a long line, a second
#     language — which is exactly the corpus the book must NOT get.
#
# So the two share the *machinery* and not the *fixture*: everything below is
# about getting from "a git repository exists" to "a real review dataset is on
# disk and a headless X display is up", and the repository itself is supplied
# by the caller as a function. Making them share one fixture would have meant
# either impoverishing the design corpus or rewriting the published book
# images and the prose around them on every campaign milestone.
#
# Nothing here builds CodeTracer. Every consumer photographs the build tree as
# it stands, which is why `ctdr_require_fresh_build` exists and is loud.
#
# Sourced, never executed:
#   source "${REPO_ROOT}/scripts/docs/deep-review-capture-lib.sh"

# `set -euo pipefail` is the caller's job — a library that sets shell options
# in its sourcer's shell is a library that decides how unrelated code fails.

# The label every diagnostic is prefixed with. Callers override it so a failure
# names the script the user actually ran.
CTDR_LABEL="${CTDR_LABEL:-deep-review-capture}"

ctdr_die() {
	echo "${CTDR_LABEL}: $*" >&2
	exit 1
}

ctdr_require_cmd() {
	command -v "$1" >/dev/null 2>&1 || ctdr_die "missing '$1' — $2"
}

# ctdr_resolve_ct <repo-root>
#
# Locates the `ct` binary and the build tree around it, and exports
# `CTDR_CT` / `CTDR_BUILD_ROOT` for everything downstream.
ctdr_resolve_ct() {
	local repo_root="$1"
	CTDR_CT="${CODETRACER_CT_CMD:-${repo_root}/src/build-debug/bin/ct}"
	[[ -x ${CTDR_CT} ]] || ctdr_die \
		"no ct binary at '${CTDR_CT}'. Build it with 'just build-once', or set CODETRACER_CT_CMD."
	CTDR_BUILD_ROOT="$(cd -- "$(dirname -- "${CTDR_CT}")/.." && pwd)"
	export CTDR_CT CTDR_BUILD_ROOT
}

# ctdr_require_runtime_config <repo-root>
#
# `ct` copies its bundled defaults out of `<build tree>/config/` on first run;
# without them it never finishes loading a config and no window is ever mapped,
# which would otherwise surface only as "no window appeared within 120s",
# minutes into a capture. The tup build path on Linux does NOT populate that
# directory (only the reprobuild recipe copies the two files), so check it up
# front and name the one-line remedy.
ctdr_require_runtime_config() {
	local repo_root="$1" cfg
	for cfg in default_config.yaml default_layout.json; do
		[[ -f "${CTDR_BUILD_ROOT}/config/${cfg}" ]] || ctdr_die \
			"missing '${CTDR_BUILD_ROOT}/config/${cfg}', which ct needs before it can map a window. Seed it with: mkdir -p '${CTDR_BUILD_ROOT}/config' && cp ${repo_root}/src/config/default_config.yaml ${repo_root}/src/config/default_layout.json '${CTDR_BUILD_ROOT}/config/'"
	done
}

# ctdr_require_not_stale <label> <artefact> <source-root> <pattern>
#
# A capture photographs whatever is already in the build tree; it never builds.
# So a checkout whose sources have moved on since the last `just build-once`
# produces images of an OLD CodeTracer, and nothing in the picture says so. A
# screenshot of a stale build is worse than no screenshot, because it is
# published — or reviewed and rated — next to a claim about the current one,
# and it looks authoritative.
#
# The comparison is a filesystem question (`find -newer`) rather than timestamp
# arithmetic. It is deliberately conservative: it fails on an mtime that merely
# *looks* newer — a `git checkout` that rewrites a file with identical bytes is
# enough — because the remedy is a ~15-second incremental build and the
# alternative is an unreproducible picture.
ctdr_require_not_stale() {
	local label="$1" artefact="$2" source_root="$3" pattern="$4"
	[[ -f ${artefact} ]] || ctdr_die \
		"missing ${label} at '${artefact}'. Build it with 'just build-once'."
	[[ -d ${source_root} ]] || return 0
	local newer
	newer="$(find "${source_root}" -name "${pattern}" -newer "${artefact}" -print -quit 2>/dev/null || true)"
	[[ -z ${newer} ]] || ctdr_die \
		"stale build: ${label} ('${artefact}') is older than its source '${newer}'. The capture photographs the build tree as-is, so this would produce images of an out-of-date CodeTracer. Rebuild with: just build-once"
}

# ctdr_require_trace_not_stale <label> <trace> <source...>
#
# THE SAME QUESTION AS `ctdr_require_not_stale`, ASKED OF A RECORDING.
#
# `ctdr_require_not_stale` takes `-f`, and a `.ct` trace is a DIRECTORY, so the
# capture scripts that reuse a recording could not use it and asked the cheaper
# question instead: does the path exist? `capture-readme-animations.sh` did
# exactly that — when `ct record` failed it accepted whatever
# `fibonacci-readme.ct` happened to be lying in the repository root and carried
# on, which is EXISTENCE STANDING IN FOR FRESHNESS. That trace is never deleted,
# so the fallback reliably finds one; it was recorded by some earlier `ct`, from
# some earlier `examples/fibonacci.py`, and the animations produced from it are
# published as pictures of the current product.
#
# Same comparison and the same conservatism as its sibling: a source newer than
# the recording is a refusal, `find -newer` rather than timestamp arithmetic, and
# a checkout that rewrites a file with identical bytes is enough to trip it —
# because the remedy is to re-record and the alternative is an unreproducible
# picture. `-e`, not `-f`, so it works on the directory a trace actually is.
ctdr_require_trace_not_stale() {
	local label="$1" trace="$2"
	shift 2
	[[ -e ${trace} ]] || ctdr_die \
		"missing ${label} at '${trace}'. Nothing to reuse."
	local source newer
	for source in "$@"; do
		[[ -e ${source} ]] || continue
		newer="$(find "${source}" -newer "${trace}" -print -quit 2>/dev/null || true)"
		[[ -z ${newer} ]] || ctdr_die \
			"stale recording: ${label} ('${trace}') is older than '${newer}'. The capture would publish images of an out-of-date CodeTracer, or of a program that has since changed. Re-record it, or delete '${trace}' and run this again."
	done
}

# ctdr_require_fresh_build <repo-root> [extra-stylesheet ...]
#
# The two artefacts checked are the two every picture is made of: the
# stylesheet the window loads and the renderer bundle that draws every panel.
# Callers that load a *different* stylesheet — the design harness captures the
# light theme too — name it as an extra argument, so a theme whose CSS was
# never built fails here rather than producing an unstyled window that a
# reviewer would rate as a design problem.
ctdr_require_fresh_build() {
	local repo_root="$1"
	shift
	ctdr_require_not_stale "the window's stylesheet" \
		"${CTDR_BUILD_ROOT}/frontend/styles/default_dark_theme_electron.css" \
		"${repo_root}/src/frontend/styles" '*.styl'
	local sheet
	for sheet in "$@"; do
		ctdr_require_not_stale "the '${sheet}' stylesheet" \
			"${CTDR_BUILD_ROOT}/frontend/styles/${sheet}" \
			"${repo_root}/src/frontend/styles" '*.styl'
	done
	ctdr_require_not_stale "the renderer bundle" \
		"${CTDR_BUILD_ROOT}/ui.js" \
		"${repo_root}/src/frontend" '*.nim'
}

# ctdr_require_recording_tools
#
# What it takes to turn a git repository into a review dataset. Split from the
# screenshot tools below because a consumer reusing a previously collected
# dataset needs none of this.
ctdr_require_recording_tools() {
	ctdr_require_cmd nargo "install the CodeTracer dev shell, which provides the Noir toolchain."
	ctdr_require_cmd git "install git."
}

# ctdr_require_display_tools
ctdr_require_display_tools() {
	ctdr_require_cmd Xvfb "install xorg-server / xvfb; the capture needs a headless X display."
	ctdr_require_cmd xdotool "install xdotool; it is how the script knows the window is up."
}

# ctdr_git_init <repo-dir>
#
# A repository with a fixed identity, so the reviewed commits do not inherit
# whatever `user.email` the capturing machine happens to have configured.
ctdr_git_init() {
	local repo="$1"
	git -C "${repo}" init -q
	git -C "${repo}" config user.email docs@codetracer.local
	git -C "${repo}" config user.name "CodeTracer docs"
}

# ctdr_git_commit <repo-dir> <message>
ctdr_git_commit() {
	local repo="$1" message="$2"
	git -C "${repo}" add -A
	git -C "${repo}" commit -qm "${message}"
}

# ctdr_record <repo-dir> <output-dir> <log-file>
#
# One real recording with the shipping `ct record`. Nothing in any picture
# these scripts produce is a mock-up, which is the only reason the pictures are
# worth publishing — or worth rating.
ctdr_record() {
	local repo="$1" out="$2" log="$3"
	(cd "${repo}" && "${CTDR_CT}" record -o "${out}" . >"${log}" 2>&1) ||
		ctdr_die "ct record failed; see ${log}"
}

# ctdr_collect <repo-dir> <recordings-dir> <output-dir>
#
# A real review dataset with the shipping `ct review collect`, over the
# repository's own `HEAD~..HEAD`.
ctdr_collect() {
	local repo="$1" recordings="$2" out="$3"
	(cd "${repo}" && "${CTDR_CT}" review collect \
		--repo . --diff HEAD~..HEAD \
		--recordings "${recordings}" --output "${out}") ||
		ctdr_die "ct review collect failed"
}

# ctdr_start_xvfb <display> <screen-geometry> <log-file>
#
# Starts a headless X server and exports `CTDR_XVFB_PID` so the caller's
# cleanup trap can kill it. It waits for the display to answer rather than
# sleeping a fixed interval, because a fixed sleep is either too short on a
# loaded machine or wasted on an idle one.
ctdr_start_xvfb() {
	local display="$1" screen="$2" log="$3"
	Xvfb "${display}" -screen 0 "${screen}" >"${log}" 2>&1 &
	CTDR_XVFB_PID=$!
	export CTDR_XVFB_PID
	local waited=0
	until DISPLAY="${display}" xdotool getdisplaygeometry >/dev/null 2>&1; do
		sleep 1
		waited=$((waited + 1))
		if [[ ${waited} -ge 30 ]]; then
			ctdr_die "Xvfb did not come up on ${display} within 30s; see ${log}"
		fi
		kill -0 "${CTDR_XVFB_PID}" 2>/dev/null ||
			ctdr_die "Xvfb exited immediately on ${display}; see ${log}"
	done
}
