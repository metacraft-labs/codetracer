#!/usr/bin/env bash
#
# noir-studio-signed-out.sh — NS7a's first verification, as a counting rule.
#
# `test_development_loop_needs_no_account` (Noir-Studio.milestones.org NS7a)
# asks that "write, compile, run, record, debug and export complete with no
# token present and no sign-in prompt". It is the same claim as
# CodeTracer-Identity.milestones.org ID3's Noir Studio deliverable, and it is
# the ONE part of NS7a that does not wait on the identity campaign: NS7a's
# other three deliverables need a token, and no token exists (ID0, the
# build-or-adopt decision that gates ID1, is unmade).
#
# ## Why this gate does not scan for identity vocabulary
#
# The obvious gate is BlockTracer's: `ci/test/client-sdk-boundary.sh` there
# scans an import closure for an `IDENTITY_TOKENS` list — cookie, bearer,
# authorization, accessToken — and fails on a hit. That works there. Measured
# here it does not, and the reason is worth writing down because it is the
# reason this file takes a different instrument.
#
# The web renderer bundle contains, today, on `dev`:
#
#     llmProvider.apiKey        an LLM provider's key, for the agent panes
#     wantsPassword             a RECORDED process's sudo prompt, replayed
#     renderPasswordPrompt      the view that draws it
#
# None of those is a CodeTracer account. All three trip a vocabulary scan.
# Deciding which of them counts as "an identity dependency" IS ID0's question —
# what a subject is, and what the product is answerable for — and a gate that
# answered it here would be legislating the identity model from a CI script
# rather than reading one. A token list is a policy, and this repository does
# not yet have the policy.
#
# ## The instrument it uses instead
#
# **Network egress**, which needs no identity model to define. ID3's rule
# ("static is free; dynamic needs an account") reduces, for a statically hosted
# product, to: *the core loop makes no request*. That is strictly stronger than
# "the core loop sends no token" — there is nothing for a token to ride on —
# and it is what makes the loop work on a plane, which is the offline
# constraint the Identity introduction calls hard.
#
# It is also the erosion this milestone names. ID3: "A static path acquiring an
# identity dependency is always locally reasonable — one personalisation, one
# counter." A counter is a `fetch`. This gate fails on it.
#
# ## The two arms are different claims and the verdict says which
#
# Noir Studio's web product is TWO bundles, and the loop spans both:
#
#   LOOP ARM     `web_main.nim` -> web.js. Carries write (project_store),
#                compile and record (noir_wasm_modules, wasm_registry), run
#                (wasm_worker) and export (download). The claim here is
#                absolute: **zero egress sites**.
#
#   RENDERER ARM `ui_js.nim` -> ui.js. Carries debug (the panes). It has
#                egress, and always will: LSP, visual replay, agentic sessions
#                and collaboration are real features. The claim here is
#                weaker and is the one that erodes: **every egress site
#                belongs to a NAMED non-loop surface, and the budget below
#                says how many each has**. A new `fetch` that is none of them
#                fails, in both directions.
#
# ## The tautology this gate is written against
#
# "The loop arm makes no requests" is satisfied by a bundle that failed to
# build, by a bundle the scanner cannot read, and by a scanner whose pattern
# cannot match — the empty-set pass of Verification-Harness-Traps.md trap 4.
# A lone negative assertion has nothing to fail.
#
# So there are THREE independent sources and every assertion crosses two:
#
#   1. THE BUDGET     checked in, below. Egress per surface; loop stages.
#   2. THE BUNDLES    both arms, BUILT, not read from source. A stage whose
#                     module dropped out of the import graph is exactly the
#                     failure this is for, and source cannot see it.
#   3. THE SOURCE     `src/frontend/ui_js.nim`, where the collab path guard is
#                     written. Step 5 asserts the guard is in the source AND
#                     in the built bundle: the guard is what keeps the collab
#                     surface off the loop, and it lives inside an `importjs`
#                     string literal that no Nim test can reach.
#
# And the controls, which are what make the zero mean something:
#
#   POSITIVE CONTROL ON THE SCANNER (step 3). The SAME egress scanner, the
#   same function, run over the renderer arm, must report exactly 13. Break
#   the scanner and this goes red immediately, which is the pairing trap 4a
#   prescribes: a "must not contain" check with a "must contain" twin through
#   the same code path is self-controlling.
#
#   POSITIVE CONTROL ON THE SUBJECT (step 2a). Before asserting the loop arm
#   has no egress, assert the loop arm CONTAINS THE LOOP — all five stage
#   markers, and the COUNT, not "at least one" (trap 4b: an existential
#   control is satisfied by one member of five). A bundle that compiled none
#   of the loop would otherwise pass step 2b for free.
#
# Both numbers below are asserted as counts and fail in both directions, for
# the reason `renderer-pane-parity.sh` and `renderer-host-reach-budget.sh`
# give: a budget that only fails upward quietly comes to describe a product
# that no longer exists.
#
# ## What this gate does NOT claim
#
# It does not claim the loop RUNS signed out — nothing here executes the loop;
# `ci/test/noir-wasm-worker-e2e.sh` is the closest thing and it needs the two
# Noir wasm modules, which no CI job delivers. It claims the shipped loop has
# no network surface for an account to be required on. Those are different
# facts and only the second is measurable today.
#
# It says nothing about the wallet. NS7a's second verification
# (`test_wallet_connection_grants_no_product_access`) has no subject on `dev`:
# there is no wallet, no web3 provider and no contract deployment anywhere in
# the repository. A check written for it would quantify over an empty set and
# pass forever — trap 4 exactly — so it is deliberately not written here.
#
# Usage:  bash ci/test/noir-studio-signed-out.sh
# Env:    ISONIM_SRC        isonim source tree (else the ../isonim sibling)
#         CT_NIM_CACHE_ROOT nimcache root (default: per-checkout, see ci/lib/nim-cache-root.sh)
#         CT_RENDERER_WEB_BUNDLE, CT_WEB_ENTRY_BUNDLE
#                           prebuilt bundles, to skip the two nim js runs

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

cache_root="$(ct_nim_cache_root "${repo_root}")"
guard_source="src/frontend/ui_js.nim"

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
# THE BUDGET.
#
# Part 1: the loop's stages, and the Nim-mangled module symbol that proves each
# one was compiled into the loop arm. The marker is the mangled symbol the JS
# backend must emit for the module to exist at all — never a source string
# literal, which `web-bundle-smoke.sh` learned the expensive way is not
# preserved through a `nim js` build.
#
# Mangling: `__` + module path with `/` -> `Z` and `_` -> `95`, `.nim` dropped,
# trailing `_`. So `viewmodel/platform/project_store.nim` becomes
# `__viewmodelZplatformZproject95store_`.
#
# Keys are alphanumeric-and-underscore ONLY, per CONTRIBUTING.md's shfmt rule:
# `shfmt` parses a hyphenated associative-array subscript as ARITHMETIC and
# rewrites `${x[visual-replay]}` into `${x[visual - replay]}`, a different and
# empty key. Where a surface's natural name has a hyphen the hyphen-free key
# is carried alongside it below, and this comment is why — do not "tidy" it.
# ---------------------------------------------------------------------------
declare -a LOOP_STAGES=(
	"write:__viewmodelZplatformZproject95store_"
	"compile:__viewmodelZplatformZnoir95wasm95modules_"
	"run:__viewmodelZplatformZwasm95worker_"
	"record:__viewmodelZplatformZwasm95registry_"
	"export:__viewmodelZplatformZdownload_"
)
LOOP_STAGES_EXPECTED=5

# The debug stage is on the OTHER arm — it is the panes. Its marker exists so
# that step 3's measurement of the renderer arm is not taken over a bundle
# that compiled nothing either.
DEBUG_STAGE_MARKER="__viewmodelZviewmodelsZdebug95controls95vm_"

# Part 2: every egress site in the renderer arm, by surface, with its count.
#
# `key` is the shfmt-safe subscript; `name` is what a human reads.
#
#   lsp             ONE `new WebSocket`, in `lsp_controller.nim`. Opt-in: it
#                   returns before connecting unless a `ws://` or `wss://` URL
#                   was configured, and a static Noir Studio deployment
#                   configures none. Editing does not need it.
#   visualreplay    FOUR `fetch` in `ui/visual_replay_client_factory.nim` —
#                   the HTTP visual-replay client. A different product
#                   feature; not a Noir compile/run/record path.
#   agentic         ONE `XMLHttpRequest` in `ui/agentic_session_launcher.nim`.
#   collab          SEVEN, all in `ui_js.nim`'s `importjs` blocks: the invite
#                   exchange, the rendezvous, invite create and revoke, and
#                   the `__ctTestCreateCollabInvite` test hook. Collaboration
#                   is a DYNAMIC surface by ID3's own rule and is entitled to
#                   need an account (ID4 says participants are identified by
#                   the shared account). What matters for NS7a is that it is
#                   gated off the development loop — step 5.
declare -a EGRESS_BUDGET=(
	"lsp:lsp:1"
	"visualreplay:visual-replay:4"
	"agentic:agentic:1"
	"collab:collab:7"
)
EGRESS_EXPECTED_TOTAL=13

# The loop arm's budget is the whole point and is not a table.
LOOP_ARM_EGRESS_EXPECTED=0

# Every credentialed request must be a collab one. `credentials: "include"`
# attaches cookies, which is the mechanism by which reading becomes
# attributable — ID3's `test_reading_is_never_attributable`.
CREDENTIALED_EXPECTED=7

# The path guard that keeps the collab surface off the loop. Present in the
# source and in the built bundle; step 5 asserts both.
COLLAB_PATH_GUARD='/collab/join/'

# ---------------------------------------------------------------------------
# THE SCANNER. One function, used on both arms, so that step 3's positive
# result and step 2b's zero are produced by the same code path.
#
# POSIX ERE only. `\b`, `\d`, `\w` and `\s` are GNU/PCRE extensions and this
# pattern is also handed to `grep -E` under a pinned GNU toolchain that would
# hide the difference — Verification-Harness-Traps.md trap 4, part 1.
# ---------------------------------------------------------------------------
EGRESS_PATTERN='(await )?fetch\(|new XMLHttpRequest|new WebSocket\(|sendBeacon\(|new EventSource\('

egress_lines() {
	# `grep -c` prints 0 AND exits 1 when there are no matches, so a `|| echo 0`
	# here would yield a two-line value. Count with `wc -l` over the line list
	# instead, as renderer-pane-parity.sh's `in_bundle` does for the same
	# reason.
	grep -naoE "${EGRESS_PATTERN}" "$1" 2>/dev/null | cut -d: -f1
}

egress_count() {
	egress_lines "$1" | grep -c . || true
}

# Classify one egress site by the surface whose marker appears near it. The
# window spans both directions because the URL argument follows `fetch(` on
# the NEXT line at four of the collab sites.
surface_of() {
	local bundle="$1" line="$2" window
	window="$(awk -v n="${line}" 'NR>=n-20 && NR<=n+8' "${bundle}")"
	case "${window}" in
	*visual_replay_client_factory*) printf 'visual-replay' ;;
	*agentic_session_launcher*) printf 'agentic' ;;
	*lsp95controller*) printf 'lsp' ;;
	*collab* | *CODETRACER_COLLAB*) printf 'collab' ;;
	*) printf 'UNCLASSIFIED' ;;
	esac
}

in_bundle() {
	# Same convention and same reason as above: a count, never an exit status.
	grep -ac "$1" "$2" 2>/dev/null || true
}

echo "=== Noir Studio signed out (NS7a test_development_loop_needs_no_account; ID3) ==="
echo

# ---------------------------------------------------------------------------
echo "Step 0: the toolchain and the generated prerequisite"
#
# EXIT 2, not a failure: an absent toolchain is a gate that did not run, and
# conflating that with a red gate is how a suite comes to "pass" on a machine
# that compiled nothing. Same convention as renderer-pane-parity.sh.
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
echo "Step 1: build both arms of the web product"
echo "    Measured in the BUILT bundles, not in the source: a stage whose"
echo "    module dropped out of the import graph is exactly the failure this"
echo "    gate is for, and source cannot see it."
# ---------------------------------------------------------------------------
build_arm() {
	local label="$1" target="$2" out="$3"
	shift 3
	local cache="${cache_root}/nsso-${label}"
	local log
	log="$(nim js --hints:off --warnings:off "$@" \
		--nimcache:"${cache}" -o:"${out}" "${target}" 2>&1)"
	local rc=$?
	if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
		echo "${label}: the arm did not build (rc ${rc})" >&2
		printf '%s\n' "${log}" | tail -25 >&2
		return 1
	fi
	return 0
}

loop_arm="${CT_WEB_ENTRY_BUNDLE:-}"
if [ -z "${loop_arm}" ]; then
	loop_arm="${cache_root}/nsso-loop/web.js"
	mkdir -p "$(dirname "${loop_arm}")"
	build_arm loop src/frontend/web_main.nim "${loop_arm}" \
		-d:nodejs -d:ctWeb --path:src/frontend/viewmodel || exit 2
fi
renderer_arm="${CT_RENDERER_WEB_BUNDLE:-}"
if [ -z "${renderer_arm}" ]; then
	renderer_arm="${cache_root}/nsso-renderer/ui.js"
	mkdir -p "$(dirname "${renderer_arm}")"
	build_arm renderer src/frontend/ui_js.nim "${renderer_arm}" \
		-d:chronicles_enabled=off -d:ctRenderer -d:ctWeb || exit 2
fi

for b in "${loop_arm}" "${renderer_arm}"; do
	if [ ! -s "${b}" ]; then
		echo "bundle is missing or empty: ${b}" >&2
		exit 2
	fi
done
note "loop arm:     ${loop_arm} ($(wc -c <"${loop_arm}" | tr -d ' ') bytes)"
note "renderer arm: ${renderer_arm} ($(wc -c <"${renderer_arm}" | tr -d ' ') bytes)"
echo

# ---------------------------------------------------------------------------
echo "Step 2a: the loop arm carries the loop"
echo "    THE POSITIVE CONTROL FOR STEP 2b. 'This bundle makes no requests' is"
echo "    also true of a bundle that compiled none of the product, so the"
echo "    count of stages present is asserted BEFORE the count of requests."
echo "    The count, not 'at least one': an existential control is satisfied"
echo "    by one member of five (trap 4b)."
# ---------------------------------------------------------------------------
stages_present=0
for entry in "${LOOP_STAGES[@]}"; do
	stage="${entry%%:*}"
	marker="${entry#*:}"
	hits="$(in_bundle "${marker}" "${loop_arm}")"
	if [ "${hits}" -gt 0 ]; then
		stages_present=$((stages_present + 1))
		note "${stage}: present (${marker})"
	else
		bad "loop stage '${stage}' is ABSENT from the loop arm (${marker}) — the arm does not compile it, and step 2b would be vacuous"
	fi
done
if [ "${stages_present}" -eq "${LOOP_STAGES_EXPECTED}" ]; then
	ok "all ${LOOP_STAGES_EXPECTED} loop stages are compiled into the loop arm"
else
	bad "the loop arm carries ${stages_present} of ${LOOP_STAGES_EXPECTED} loop stages"
fi

debug_hits="$(in_bundle "${DEBUG_STAGE_MARKER}" "${renderer_arm}")"
if [ "${debug_hits}" -gt 0 ]; then
	ok "the debug stage is compiled into the renderer arm, so step 3 has a subject too"
else
	bad "the debug stage is ABSENT from the renderer arm (${DEBUG_STAGE_MARKER})"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2b: the loop arm makes no requests"
echo "    Write, compile, run, record and export reach no network primitive."
echo "    There is no request for a token to ride on, which is what makes the"
echo "    loop work signed out AND offline."
# ---------------------------------------------------------------------------
loop_egress="$(egress_count "${loop_arm}")"
if [ "${loop_egress}" -eq "${LOOP_ARM_EGRESS_EXPECTED}" ]; then
	ok "the loop arm has ${loop_egress} egress sites"
else
	bad "the loop arm has ${loop_egress} egress site(s), expected ${LOOP_ARM_EGRESS_EXPECTED} — the development loop acquired a network dependency"
	while read -r l; do
		[ -n "${l}" ] || continue
		violation="$(awk -v n="${l}" 'NR==n' "${loop_arm}" | cut -c1-120)"
		note "  line ${l}: ${violation}"
	done < <(egress_lines "${loop_arm}")
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: the same scanner reports egress where egress exists"
echo "    THE POSITIVE CONTROL ON THE SCANNER. Step 2b's zero is only evidence"
echo "    if a non-zero was reachable by the same function. Break the pattern"
echo "    or the engine and this goes red immediately (trap 4a: the pairing IS"
echo "    the control)."
# ---------------------------------------------------------------------------
renderer_egress="$(egress_count "${renderer_arm}")"
if [ "${renderer_egress}" -eq "${EGRESS_EXPECTED_TOTAL}" ]; then
	ok "the scanner reports ${renderer_egress} egress sites on the renderer arm"
elif [ "${renderer_egress}" -eq 0 ]; then
	bad "the scanner reports 0 egress sites on the renderer arm — it cannot match, and step 2b's zero means nothing"
else
	bad "the renderer arm has ${renderer_egress} egress sites, the budget says ${EGRESS_EXPECTED_TOTAL}"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: every egress site belongs to a named non-loop surface"
echo "    Fails in BOTH directions. UP: a fetch nobody classified is a new"
echo "    network dependency whose place in the product nobody decided. DOWN:"
echo "    a surface whose sites are gone leaves the budget describing a"
echo "    product that no longer exists, and the next one lands against a"
echo "    stale baseline."
# ---------------------------------------------------------------------------
declare -A observed=()
unclassified=0
for entry in "${EGRESS_BUDGET[@]}"; do
	key="${entry%%:*}"
	observed["${key}"]=0
done

while read -r l; do
	[ -n "${l}" ] || continue
	s="$(surface_of "${renderer_arm}" "${l}")"
	if [ "${s}" = "UNCLASSIFIED" ]; then
		unclassified=$((unclassified + 1))
		snippet="$(awk -v n="${l}" 'NR==n' "${renderer_arm}" | cut -c1-120)"
		bad "egress site at line ${l} belongs to no named surface: ${snippet}"
		continue
	fi
	# Map the human name back to the shfmt-safe key.
	k=""
	for entry in "${EGRESS_BUDGET[@]}"; do
		kk="${entry%%:*}"
		rest="${entry#*:}"
		nn="${rest%%:*}"
		if [ "${nn}" = "${s}" ]; then k="${kk}"; fi
	done
	if [ -z "${k}" ]; then
		unclassified=$((unclassified + 1))
		bad "egress site at line ${l} classified '${s}', which the budget does not list"
		continue
	fi
	observed["${k}"]=$((observed["${k}"] + 1))
done < <(egress_lines "${renderer_arm}")

if [ "${unclassified}" -eq 0 ]; then
	ok "every egress site on the renderer arm resolved to a budgeted surface"
fi

classified_total=0
for entry in "${EGRESS_BUDGET[@]}"; do
	key="${entry%%:*}"
	rest="${entry#*:}"
	name="${rest%%:*}"
	want="${rest#*:}"
	got="${observed[${key}]}"
	classified_total=$((classified_total + got))
	if [ "${got}" -eq "${want}" ]; then
		ok "surface '${name}': ${got} egress site(s), as budgeted"
	else
		bad "surface '${name}': ${got} egress site(s), budget says ${want}"
	fi
done

if [ "${classified_total}" -eq "${EGRESS_EXPECTED_TOTAL}" ]; then
	ok "the per-surface counts sum to the total the budget declares (${EGRESS_EXPECTED_TOTAL})"
else
	bad "the per-surface counts sum to ${classified_total}, the budget total is ${EGRESS_EXPECTED_TOTAL}"
fi

# No surface may be a loop stage. This is what makes the renderer arm's egress
# compatible with the claim: debug is on this arm, and the four surfaces that
# do reach the network are none of the six stages.
overlap=0
for entry in "${EGRESS_BUDGET[@]}"; do
	rest="${entry#*:}"
	name="${rest%%:*}"
	for st in "${LOOP_STAGES[@]}"; do
		[ "${name}" = "${st%%:*}" ] && overlap=$((overlap + 1))
	done
	[ "${name}" = "debug" ] && overlap=$((overlap + 1))
done
if [ "${overlap}" -eq 0 ]; then
	ok "no budgeted egress surface is one of the loop's stages"
else
	bad "${overlap} budgeted egress surface(s) name a loop stage — the loop itself reaches the network"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 5: the collab surface is gated off the loop, and the guard is real"
echo "    THE GUARD IS THE PROPERTY. The collab bootstrap returns before its"
echo "    first fetch unless the location is under ${COLLAB_PATH_GUARD}, and it"
echo "    lives inside an importjs string literal that no Nim test can reach."
echo "    Asserted in the SOURCE and in the BUILT BUNDLE, which is a different"
echo "    claim from either alone: in source only, a build that dropped it"
echo "    passes; in the bundle only, the gate cannot say where it came from."
# ---------------------------------------------------------------------------
if [ ! -f "${guard_source}" ]; then
	bad "${guard_source} does not exist; this step has no subject"
else
	src_hits="$(in_bundle "${COLLAB_PATH_GUARD}" "${guard_source}")"
	if [ "${src_hits}" -gt 0 ]; then
		ok "the collab path guard '${COLLAB_PATH_GUARD}' is written in ${guard_source}"
	else
		bad "the collab path guard '${COLLAB_PATH_GUARD}' is GONE from ${guard_source} — the collab bootstrap no longer refuses a non-collab location, and it now runs on every page load including the development loop's"
	fi
fi

bundle_hits="$(in_bundle "${COLLAB_PATH_GUARD}" "${renderer_arm}")"
if [ "${bundle_hits}" -gt 0 ]; then
	ok "the guard survives into the built renderer arm"
else
	bad "the guard is absent from the built renderer arm — it is in the source but not in what ships"
fi

# Every credentialed request is a collab one. `credentials: "include"` is the
# mechanism by which a request becomes attributable to a signed-in user, and
# ID3's second verification is that reading never is.
credentialed="$(grep -oaE 'credentials: "include"' "${renderer_arm}" 2>/dev/null | grep -c . || true)"
collab_sites="${observed[collab]:-0}"
if [ "${credentialed}" -eq "${CREDENTIALED_EXPECTED}" ] &&
	[ "${credentialed}" -eq "${collab_sites}" ]; then
	ok "all ${credentialed} credentialed requests are collab sites, and there are exactly as many of each"
else
	bad "credentialed requests: ${credentialed} (budget ${CREDENTIALED_EXPECTED}), collab egress sites: ${collab_sites} — a credentialed request outside the collab surface attaches cookies to something the loop can reach"
fi

loop_credentialed="$(grep -oaE 'credentials: "include"' "${loop_arm}" 2>/dev/null | grep -c . || true)"
if [ "${loop_credentialed}" -eq 0 ]; then
	ok "the loop arm attaches credentials to nothing"
else
	bad "the loop arm has ${loop_credentialed} credentialed request(s)"
fi
echo

# ---------------------------------------------------------------------------
# THE VERDICT SAYS WHICH FACT THE NUMBER IS.
# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s)"
echo "  loop arm:     ${stages_present}/${LOOP_STAGES_EXPECTED} stages present, ${loop_egress} egress site(s)"
echo "  renderer arm: ${renderer_egress} egress site(s) across ${#EGRESS_BUDGET[@]} named surfaces"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "  The development loop reaches no network primitive, so there is no"
echo "  request for a token to ride on and nothing to prompt a sign-in for."
echo "  That is NS7a's first verification and ID3's Noir Studio deliverable."
echo "  It is NOT a claim that the loop runs — nothing here executes it — nor"
echo "  anything at all about the wallet, which does not exist to be tested."
echo "RESULT: OK — the development loop has no network surface"
