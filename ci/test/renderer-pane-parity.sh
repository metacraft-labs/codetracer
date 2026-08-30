#!/usr/bin/env bash
#
# renderer-pane-parity.sh — NS2's second half, as a counting rule.
#
# `test_one_codebase_two_platforms` (Noir-Studio.milestones.org NS2) asks two
# things. "CI fails if either build breaks" is DONE — `test-host-instantiations`,
# `test-web-bundle` and `renderer-browser-build.sh` cover it. The other half is
# **"a pane added to one appears in the other"**, and until this file nothing
# asserted it.
#
# `renderer-browser-build.sh` verifies the NEGATIVE half: that
# `ui/panel_transfer.nim` and `ui/agentic_worktree_test_hooks.nim` are absent
# from the web bundle, by name, because their `{.error.}` guards say they must
# be. That is "these modules are deliberately desktop-only". It says nothing
# about the panes that are supposed to be on BOTH, which is the actual claim.
#
# ## The rule
#
# REGISTRY: the `of Content.X: data.makeYComponent(...)` arms of
# `makeComponent` in `src/frontend/utils.nim`. That proc IS the set of panes
# the product can construct — `renderer.createUIComponent` and
# `ui/layout.nim` both go through it, and a `Content` value with no arm there
# raises `ValueError` and leaves an empty tab. The list is read from the
# product rather than restated here, for the reason `web_deployment.nim`'s
# header gives about `rewritePrefixes`: a hand-written second copy cannot be
# made to agree.
#
# MEASURED IN: the two built bundles, not in the source. A pane whose arm
# exists but whose module got dropped from the web import graph is exactly the
# failure this gate is for, and source cannot see it. The marker is the
# constructor's Nim-mangled symbol (`makeEventLogComponent__utils_u207`),
# which the JS backend must emit for the proc to exist at all — never a source
# string literal, which `web-bundle-smoke.sh` learned the expensive way is not
# preserved.
#
# CLASSIFIED as one of two kinds, and the budget below records which:
#   both         constructible on BOTH arms. This is what parity means, and it
#                is what every pane should be.
#   desktoponly  constructible on the Electron arm only, with the capability
#                the web profile lacks named. There are none today, and the
#                kind exists so that adding one is a DECISION recorded here
#                rather than a silent divergence.
#
# ## Why both directions fail
#
# The same reason `renderer-host-reach-budget.sh` gives, and that gate caught
# its own author twice:
#
#   UP    a pane in `makeComponent` that the budget does not list is a new pane
#         whose parity nobody decided. It fails until someone writes down which
#         kind it is.
#   DOWN  a pane in the budget that `makeComponent` no longer dispatches is a
#         removed pane. Left unfailed, the budget would quietly describe a
#         product that no longer exists, and the next divergence would land
#         against a stale baseline.
#
# ## The number means different things and the verdict says which
#
# A parity count that drops because a pane became UNCOMPILABLE on one arm is a
# different fact from one that drops because the pane was deleted, and both
# differ from parity being achieved. `renderer-host-reach-budget.sh` records
# the same distinction — 16 of its 20 reaches are in modules a web build cannot
# compile, which is NOT the same fact as 16 having been migrated — and reports
# the kinds separately for it. So does the verdict here.
#
# ## The tautology this gate is written against
#
# The natural way to write pane parity is to compare a list against itself: take
# the panes from the web bundle, take the panes from the web bundle, assert they
# match. It passes over anything, including a bundle the tool cannot read.
#
# So there are THREE independent sources here — the registry (source), the two
# bundles (artefacts), and the budget (checked in) — and every assertion is
# between two of them. Step 2 additionally proves the marker mechanism can say
# BOTH "present" and "absent" on these exact files, using a module
# `renderer-browser-build.sh` has already established is Electron-only. Without
# that negative control, "every pane is in the web bundle" would also be
# satisfied by a grep that matches everything.
#
# Usage:  bash ci/test/renderer-pane-parity.sh
# Env:    ISONIM_SRC        isonim source tree (else the ../isonim sibling)
#         CT_NIM_CACHE_ROOT nimcache root (default /tmp/ct-nim-cache)
#         CT_RENDERER_ELECTRON_BUNDLE, CT_RENDERER_WEB_BUNDLE
#                           prebuilt bundles, to skip the two nim js runs

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-files.sh"

cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
registry_file="src/frontend/utils.nim"

checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

# ---------------------------------------------------------------------------
# THE BUDGET. One line per pane `makeComponent` can construct, with its kind.
#
# `both`        constructible on both arms — parity, and the default.
# `desktoponly` Electron arm only. MUST name the capability the web profile
#               lacks, in the same style `renderer-host-reach-budget.sh`'s
#               `webexcluded` entries do. A pane listed `desktoponly` with no
#               reason is an absence without a stated consequence, which is the
#               shape `capabilities.undeclaredDegradations` and
#               `web_deployment.undeclaredAbsences` both reject.
#
# ALL 33 ARE `both` TODAY, and that is a measured fact rather than an
# aspiration: `makeComponent` carries no `when defined` branch, and every
# module implementing a constructor compiles under `-d:ctWeb`. The kind
# `desktoponly` therefore has no members — it exists so that the first pane to
# need one cannot be added without saying so here.
# ---------------------------------------------------------------------------
kind_for() {
	case "$1" in
	Debug | Build | BuildErrors | Status | SearchResults | Menu) echo "both" ;;
	WelcomeScreen | CommandPalette | NoInfo | EditorView) echo "both" ;;
	EventLog | State | Calltrace | Timeline | Filesystem) echo "both" ;;
	Scratchpad | Repl | TraceLog | CalltraceEditor) echo "both" ;;
	TerminalOutput | Shell | StepList | LowLevelCode) echo "both" ;;
	AgentActivity | AgentWorkspace | CaptionBarProgress) echo "both" ;;
	PixelHistory | ShaderDebug | VideoPlayer) echo "both" ;;
	AgentActivityDeepReview | RequestPanel | VCS | UnifiedDiff) echo "both" ;;
	*) echo "unlisted" ;;
	esac
}

# The reason a pane is desktop-only, for the kinds that need one. Empty for a
# pane that has no entry, which step 5 turns into a failure.
reason_for() {
	case "$1" in
	*) echo "" ;;
	esac
}

echo "=== renderer pane parity (NS2: a pane added to one appears in the other) ==="
echo

# ---------------------------------------------------------------------------
echo "Step 0: the toolchain and the generated prerequisite"
#
# EXIT 2, not a failure: an absent toolchain is a gate that did not run, and
# conflating that with a red gate is how a suite comes to "pass" on a machine
# that compiled nothing. Same convention as renderer-browser-build.sh.
# ---------------------------------------------------------------------------
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

isonim_root=""
if [ -n "${ISONIM_SRC:-}" ]; then
	isonim_root="$(cd "${ISONIM_SRC}/.." 2>/dev/null && pwd || true)"
fi
for candidate in "${repo_root}/../isonim" "${repo_root}/../../isonim"; do
	[ -n "${isonim_root}" ] && break
	[ -d "${candidate}" ] && isonim_root="$(cd "${candidate}" && pwd)"
done
tailwind_json="${isonim_root:-/nonexistent}/build/tailwind-styles.json"
if [ ! -f "${tailwind_json}" ]; then
	echo "isonim's build/tailwind-styles.json is missing: ${tailwind_json}" >&2
	echo "  remedy: bash scripts/build-tailwind.sh, or seed a placeholder as" >&2
	echo "          .github/actions/setup-isonim-siblings does in CI" >&2
	exit 2
fi
note "isonim: ${isonim_root}"
echo

# ---------------------------------------------------------------------------
echo "Step 1: read the pane registry from the product"
echo "    makeComponent IS the set of panes the product can construct: a"
echo "    Content value with no arm there raises ValueError and leaves an"
echo "    empty tab. Parsing it beats restating it."
# ---------------------------------------------------------------------------
if [ ! -f "${registry_file}" ]; then
	bad "the registry file ${registry_file} is gone; this gate has no subject"
	echo
	echo "RESULT: FAILED"
	exit 1
fi

# `of Content.X:` followed by a `data.makeYComponent` on the same or the next
# line. Comment lines are dropped first, for the reason the reach budget drops
# them: this file quotes the pattern in its own prose.
registry="$(awk '
	/^proc makeComponent\*/ { inproc = 1 }
	inproc && /^[a-z]/ && !/^proc makeComponent\*/ { inproc = 0 }
	inproc { print }
' "${registry_file}" |
	grep -vE '^ *#' |
	grep -oE 'of Content\.[A-Za-z]+:[^#]*' |
	sed -E 's/of Content\.([A-Za-z]+):.*/\1/' |
	sort -u)"

pane_count="$(printf '%s\n' "${registry}" | grep -c . || true)"
if [ "${pane_count}" -ge 20 ]; then
	ok "the registry names ${pane_count} panes, so the loops below have subjects"
else
	bad "the registry parse found only ${pane_count} panes — the parse is broken, and every check below would be vacuous"
	echo
	echo "RESULT: FAILED"
	exit 1
fi

# Positive control on the PARSE, not on the bundles: a pane everyone knows is
# there. Without it a parse returning junk could still clear the count above.
if printf '%s\n' "${registry}" | grep -qx "EventLog"; then
	ok "positive control: the parse finds Content.EventLog, a pane known to be dispatched"
else
	bad "positive control FAILED: the parse does not find Content.EventLog — it is reading something other than makeComponent's arms"
fi

# And the constructor each arm dispatches to, which is the marker below.
constructor_for() {
	awk -v pane="$1" '
		$0 ~ ("of Content\\." pane ":") {
			if (match($0, /make[A-Za-z]+Component/)) {
				print substr($0, RSTART, RLENGTH); exit
			}
			getline
			if (match($0, /make[A-Za-z]+Component/)) {
				print substr($0, RSTART, RLENGTH); exit
			}
		}
	' "${registry_file}"
}
echo

# ---------------------------------------------------------------------------
echo "Step 2: build both arms"
echo "    Measured in the bundles, not the source: a pane whose arm exists but"
echo "    whose module left the web import graph is exactly what this is for."
# ---------------------------------------------------------------------------
declare -A bundle
build_arm() {
	# `key` is the array subscript and is deliberately hyphen-free: shfmt
	# parses `${bundle[renderer-electron]}` as ARITHMETIC and rewrites it to
	# `${bundle[renderer - electron]}`, which is a different (and empty) key.
	# The lane id keeps its hyphen; only the subscript is renamed.
	local lane="$1" key out_cache override
	key="$3"
	override="$2"
	if [ -n "${override}" ] && [ -f "${override}" ]; then
		bundle["${key}"]="${override}"
		ok "${lane}: using prebuilt bundle ($(wc -c <"${override}" | tr -d ' ') bytes)"
		return 0
	fi
	out_cache="${cache_root}/${lane}-parity"
	mkdir -p "${out_cache}"
	local flags
	read -r -a flags <<<"$(test_lane_extra_flags "${lane}")"
	local log rc
	log="$(nim js --hints:off --warnings:off "${flags[@]}" \
		--nimcache:"${out_cache}" -o:"${out_cache}/ui.js" \
		src/frontend/ui_js.nim 2>&1)"
	rc=$?
	if [ "${rc}" -ne 0 ] || [ ! -f "${out_cache}/ui.js" ]; then
		bad "${lane}: the renderer did not build"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi
	bundle["${key}"]="${out_cache}/ui.js"
	ok "${lane}: built ($(wc -c <"${out_cache}/ui.js" | tr -d ' ') bytes)"
	return 0
}

build_arm renderer-electron "${CT_RENDERER_ELECTRON_BUNDLE:-}" electron || true
build_arm renderer-web "${CT_RENDERER_WEB_BUNDLE:-}" web || true

if [ -z "${bundle[electron]:-}" ] || [ -z "${bundle[web]:-}" ]; then
	echo
	echo "RESULT: FAILED — both arms must build before parity means anything"
	exit 1
fi

electron_bundle="${bundle[electron]}"
web_bundle="${bundle[web]}"

# Size, for the same reason web-bundle-assets.sh size-checks: a truncated
# bundle satisfies every "is absent" check in this file.
for pair in "electron:${electron_bundle}" "web:${web_bundle}"; do
	arm="${pair%%:*}"
	path="${pair#*:}"
	size="$(wc -c <"${path}" | tr -d ' ')"
	if [ "${size}" -gt 1000000 ]; then
		ok "${arm} bundle is non-trivial (${size} bytes)"
	else
		bad "${arm} bundle is ${size} bytes — too small to be the renderer, so every check below is vacuous"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "Step 3: the marker mechanism can say BOTH present and absent"
echo "    Without the second, 'every pane is in the web bundle' is also"
echo "    satisfied by a grep that matches everything."
# ---------------------------------------------------------------------------
in_bundle() {
	# `grep -c` PRINTS 0 and EXITS 1 when there is no match, so a trailing
	# `|| echo 0` emits "0\n0" and every numeric comparison downstream breaks
	# on the two-line value. Capture, then default only if the capture is
	# genuinely empty.
	local n
	n="$(grep -c "$1" "$2" 2>/dev/null)"
	[ -n "${n}" ] || n=0
	printf '%s' "${n}"
}

control_present="$(in_bundle "makeEventLogComponent" "${web_bundle}")"
if [ "${control_present}" -ge 1 ]; then
	ok "positive control: makeEventLogComponent IS in the web bundle (${control_present} hits)"
else
	bad "positive control FAILED: a constructor known to be present is not found — the marker cannot see this file"
fi

# The negative control uses a module `renderer-browser-build.sh` has already
# established is Electron-only, so this gate is not the one deciding it.
control_absent_e="$(in_bundle "__uiZpanel95transfer_" "${electron_bundle}")"
control_absent_w="$(in_bundle "__uiZpanel95transfer_" "${web_bundle}")"
if [ "${control_absent_e}" -ge 1 ]; then
	ok "negative control: ui/panel_transfer.nim IS in the Electron bundle (${control_absent_e} hits), so the marker works"
else
	bad "negative control FAILED: the marker finds nothing in EITHER bundle, so 'absent from web' below would be meaningless"
fi
if [ "${control_absent_w}" = "0" ]; then
	ok "negative control: and it is ABSENT from the web bundle, so the grep can report a real absence"
else
	bad "negative control FAILED: panel_transfer is in the web bundle (${control_absent_w} hits) despite its {.error.} guard"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: every pane's kind is decided, in both directions"
# ---------------------------------------------------------------------------
unlisted=0
for pane in ${registry}; do
	if [ "$(kind_for "${pane}")" = "unlisted" ]; then
		bad "Content.${pane} is dispatched by makeComponent and the budget does not list it — decide whether it is \`both\` or \`desktoponly\` and say so"
		unlisted=$((unlisted + 1))
	fi
done
[ "${unlisted}" = "0" ] && ok "every pane makeComponent dispatches has a decided kind (${pane_count})"

# DOWN. A budget entry with no arm is a pane that was removed; left unfailed,
# the baseline silently describes a product that no longer exists.
stale=0
for pane in Debug Build BuildErrors Status SearchResults Menu WelcomeScreen \
	CommandPalette NoInfo EditorView EventLog State Calltrace Timeline \
	Filesystem Scratchpad Repl TraceLog CalltraceEditor TerminalOutput Shell \
	StepList LowLevelCode AgentActivity AgentWorkspace CaptionBarProgress \
	PixelHistory ShaderDebug VideoPlayer AgentActivityDeepReview RequestPanel \
	VCS UnifiedDiff; do
	if ! printf '%s\n' "${registry}" | grep -qx "${pane}"; then
		bad "the budget lists Content.${pane} and makeComponent no longer dispatches it — lower the budget in the same commit that removed the pane"
		stale=$((stale + 1))
	fi
done
[ "${stale}" = "0" ] && ok "every budget entry is still a pane the product dispatches"
echo

# ---------------------------------------------------------------------------
echo "Step 5: each pane is in the arms its kind claims"
# ---------------------------------------------------------------------------
both_count=0
desktop_count=0
missing_constructor=0

for pane in ${registry}; do
	kind="$(kind_for "${pane}")"
	[ "${kind}" = "unlisted" ] && continue
	ctor="$(constructor_for "${pane}")"
	if [ -z "${ctor}" ]; then
		bad "Content.${pane}: no make*Component constructor found on its arm, so it cannot be looked for in a bundle"
		missing_constructor=$((missing_constructor + 1))
		continue
	fi
	e_hits="$(in_bundle "${ctor}" "${electron_bundle}")"
	w_hits="$(in_bundle "${ctor}" "${web_bundle}")"

	# The Electron arm is the reference: a constructor missing THERE is a
	# broken marker, not a parity finding, and saying so keeps the two apart.
	if [ "${e_hits}" = "0" ]; then
		bad "Content.${pane}: ${ctor} is in NEITHER bundle — the marker is wrong, not the parity"
		continue
	fi

	case "${kind}" in
	both)
		if [ "${w_hits}" -ge 1 ]; then
			both_count=$((both_count + 1))
		else
			bad "Content.${pane}: \`both\`, and ${ctor} is ABSENT from the web bundle. A pane on the desktop and not in the tab is the divergence this gate exists for; either restore it or record it as \`desktoponly\` with the capability it needs"
		fi
		;;
	desktoponly)
		reason="$(reason_for "${pane}")"
		if [ -z "${reason}" ]; then
			bad "Content.${pane}: \`desktoponly\` with no stated capability — an absence without a consequence is a gap in the product, not in the docs"
		elif [ "${w_hits}" = "0" ]; then
			desktop_count=$((desktop_count + 1))
			note "Content.${pane}: desktop only — ${reason}"
		else
			bad "Content.${pane}: recorded \`desktoponly\` but ${ctor} IS in the web bundle (${w_hits} hits) — the declaration is stale"
		fi
		;;
	esac
done

if [ "${missing_constructor}" = "0" ]; then
	ok "every listed pane resolved to a constructor symbol"
fi
if [ "${both_count}" -gt 0 ]; then
	ok "${both_count} pane(s) are constructible on BOTH arms"
fi
echo

# ---------------------------------------------------------------------------
# THE VERDICT SAYS WHICH FACT THE NUMBER IS.
#
# `renderer-host-reach-budget.sh` reports its kinds separately because "16
# became unbuildable" and "16 were migrated" are different facts that a single
# total would let read alike. The same applies here in the other direction: a
# pane count that falls because a pane became desktop-only is not parity, and a
# reader who sees only a total cannot tell.
# ---------------------------------------------------------------------------
desktop_total=$((both_count + desktop_count))
echo "${checks} check(s), ${failures} failure(s)"
echo "  registry: ${pane_count} pane(s) that makeComponent can construct"
echo "  desktop:  ${desktop_total} constructible"
echo "  web:      ${both_count} constructible"
if [ "${desktop_count}" = "0" ]; then
	echo "  PARITY: every pane the desktop can construct, a tab can construct."
	echo "  No pane is recorded desktop-only, so the two numbers agreeing means"
	echo "  parity and not that a divergence went unrecorded — step 4 fails an"
	echo "  undecided pane in both directions, which is what makes that read valid."
else
	echo "  NOT PARITY: ${desktop_count} pane(s) are desktop-only by decision,"
	echo "  each naming the capability the web profile lacks. That is a smaller"
	echo "  web number because a pane is UNAVAILABLE there, which is a different"
	echo "  fact from the panes having been brought to parity."
fi

if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — the pane set agrees across the two arms"
