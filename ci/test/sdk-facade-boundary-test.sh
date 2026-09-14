#!/usr/bin/env bash
#
# sdk-facade-boundary-test.sh — the contract suite for
# ci/test/sdk-facade-boundary.sh.
#
# WHY THIS EXISTS
# ---------------
# The same reason ci/test/test-lane-coverage-test.sh exists, and the same
# reason ci/lint/bash.sh runs scripts/resolve-sibling-rev-test.sh: a guard that
# has only ever been watched printing OK is not evidence. This file drives the
# boundary guard against synthetic trees and asserts that EACH of its checks
# fires, by name, on the violation it is supposed to catch — and, just as
# importantly, that it stays quiet on the clean version of the same tree.
#
# A boundary lint is exactly the kind of check that rots into decoration:
# nobody notices when it stops catching things, because the thing it catches is
# rare. So every rule below has a positive and a negative case.
#
# Usage:
#   bash ci/test/sdk-facade-boundary-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/sdk-facade-boundary.sh"

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	echo "  ok   $1"
}

bad() {
	fail=$((fail + 1))
	echo "  FAIL $1"
	shift
	while [ $# -gt 0 ]; do
		echo "         $1"
		shift
	done
}

work="$(mktemp -d)"
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Tree construction
#
# `make_tree NAME` builds a minimal repo-shaped tree with a facade, one SDK
# internal, and no consumers. Callers then add exactly the file whose handling
# they are testing, so each case differs from the clean baseline in one way.
# ---------------------------------------------------------------------------

make_tree() {
	local name="$1"
	local t="${work}/${name}"
	mkdir -p "${t}/src/frontend/viewmodel/store"
	cat >"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
import store/replay_data_store
export replay_data_store
const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF
	cat >"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import std/json
const StoreVersion* = 1
EOF
	# The guard enumerates through git, exactly as test-lane-coverage.sh does,
	# so a tree that is not a repo would look empty to it.
	git -C "${t}" init -q
	git -C "${t}" config user.email t@example.invalid
	git -C "${t}" config user.name t
	printf '%s' "${t}"
}

run_guard() {
	bash "${guard}" --root "$1" 2>&1
}

# assert_fires TREE CHECK-NAME DESCRIPTION [EXPECTED-SUBSTRING...]
#
# Every trailing argument is a substring the output must contain. More than
# one matters for the `ui/` rule, where the diagnosis has to name both the
# offending module AND the allowlist that is the intended remedy.
assert_fires() {
	local tree="$1" check="$2" desc="$3"
	shift 3
	local output status needle
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -eq 0 ]; then
		bad "${desc}" "guard exited 0; expected a failure" "${output}"
		return
	fi
	if ! grep -q "VIOLATION ${check}" <<<"${output}"; then
		bad "${desc}" "no 'VIOLATION ${check}' line in the output" "${output}"
		return
	fi
	for needle in "$@"; do
		[ -n "${needle}" ] || continue
		if ! grep -qF "${needle}" <<<"${output}"; then
			bad "${desc}" "output did not name '${needle}'" "${output}"
			return
		fi
	done
	ok "${desc}"
}

# assert_clean TREE DESCRIPTION
assert_clean() {
	local tree="$1" desc="$2"
	local output status
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -ne 0 ]; then
		bad "${desc}" "guard exited ${status}; expected 0" "${output}"
		return
	fi
	ok "${desc}"
}

echo "=== ci/test/sdk-facade-boundary.sh: contract suite ==="

# ---------------------------------------------------------------------------
# facade-present
# ---------------------------------------------------------------------------

t="$(make_tree missing-facade)"
rm "${t}/src/frontend/viewmodel/codetracer_embed.nim"
assert_fires "${t}" "facade-present" \
	"a missing facade module is reported, not ignored" \
	"does not exist"

t="$(make_tree renamed-constant)"
cat >"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
const SomeOtherName* = "codetracer_embed"
EOF
assert_fires "${t}" "facade-present" \
	"a facade that no longer declares its own name is reported" \
	"drifted apart"

# ---------------------------------------------------------------------------
# consumer-declared — the guard must refuse to pass vacuously
# ---------------------------------------------------------------------------

t="$(make_tree no-consumers)"
assert_fires "${t}" "consumer-declared" \
	"a tree with no declared consumer fails rather than passing vacuously" \
	"pass vacuously"

# ---------------------------------------------------------------------------
# consumer-facade-only — the rule BlockTracer M8a mirrors
# ---------------------------------------------------------------------------

t="$(make_tree consumer-clean)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a pane that behaves.
import ../src/frontend/viewmodel/codetracer_embed
echo StoreVersion
EOF
assert_clean "${t}" "a consumer importing only the facade passes"

t="$(make_tree consumer-reaches-in)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a pane that reaches past the facade.
import ../src/frontend/viewmodel/store/replay_data_store
echo StoreVersion
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a consumer reaching into an SDK internal is caught by name" \
	"That is an SDK internal"

t="$(make_tree consumer-reaches-in-bracket)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: bracket-list spelling of the same violation.
import ../src/frontend/viewmodel/[codetracer_embed, store/replay_data_store]
EOF
assert_fires "${t}" "consumer-facade-only" \
	"the bracket-list import spelling does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-reaches-in-from)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: `from x import y` spelling of the same violation.
from ../src/frontend/viewmodel/store/replay_data_store import StoreVersion
EOF
assert_fires "${t}" "consumer-facade-only" \
	"the 'from X import Y' spelling does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-reaches-in-indented)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: an import hidden inside a `when` branch.
when defined(js):
  import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"an import inside a 'when defined(js)' branch does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-dir-marker)"
mkdir -p "${t}/panes/debugger"
echo "BlockTracer's debugger panes." >"${t}/panes/.sdk-consumer"
cat >"${t}/panes/debugger/calltrace.nim" <<'EOF'
import ../../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a .sdk-consumer directory marker covers files beneath it" \
	"calltrace.nim"

t="$(make_tree undeclared-is-not-a-consumer)"
mkdir -p "${t}/consumer" "${t}/other"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: the declared one.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/other/internal_tool.nim" <<'EOF'
import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_clean "${t}" \
	"an undeclared file may still import internals (nothing is a consumer by accident)"

# ---------------------------------------------------------------------------
# facade-graph-no-rendering
# ---------------------------------------------------------------------------

t="$(make_tree render-direct)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
import karax/karaxdsl
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a rendering import in the facade itself is caught" \
	"karax"

t="$(make_tree render-transitive)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import dom
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a DOM import two hops from the facade is caught transitively" \
	"dom"

t="$(make_tree render-behind-when)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
when defined(js):
  import kdom
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a DOM import behind 'when defined(js)' is still in the graph" \
	"kdom"

t="$(make_tree process-spawn)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import std/osproc
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"an embeddable library spawning processes is caught" \
	"osproc"

# ---------------------------------------------------------------------------
# facade-graph-no-rendering, the `src/frontend/ui/` path rule
#
# The case the suite was missing, and the reason a CSS module could have
# shipped inside the SDK graph. A module under `ui/` that imports NOTHING is
# invisible to every other rule here — they all match a module spec someone
# imported — so if the path rule does not catch it, nothing does. This is the
# real shape: `ui/flow_line_styles.nim` exports `FlowLineHitClass` and
# `flowLineStyleClass()`, has zero imports, and sits in the same directory as
# `ui/flow_loop_math.nim`, which `viewmodels/flow_vm.nim` already imports — so
# in the real tree it is one `import` line away from the SDK graph. The
# synthetic trees below hang it off the store module instead, for the same
# reason every other transitive case here does: it is the one internal the
# baseline tree has.
# ---------------------------------------------------------------------------

t="$(make_tree ui-zero-import-presentation)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_line_styles.nim" <<'EOF'
## One inline CSS class per source line. No imports at all.
const
  FlowLineHitClass* = "line-flow-hit"
  FlowLineSkipClass* = "line-flow-skip"

func flowLineStyleClass*(hit: bool): string =
  if hit: FlowLineHitClass else: FlowLineSkipClass
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_line_styles
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a zero-import presentation module under ui/ reachable from the facade is caught" \
	"src/frontend/ui/flow_line_styles.nim" \
	"UI_PATH_ALLOWLIST"

t="$(make_tree ui-allowlisted-arithmetic)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_loop_math.nim" <<'EOF'
## Pure loop-iteration arithmetic. No imports at all.
proc activeIterationForTicks*(rrTicksForIterations: openArray[int];
                              locationTicks: int): int =
  result = 0
  for i, tick in rrTicksForIterations:
    if tick <= locationTicks: result = i
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_loop_math
EOF
assert_clean "${t}" \
	"the allowlisted ui/flow_loop_math.nim is exempt by exact name, not by softening the rule"

t="$(make_tree ui-allowlist-is-exact)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_loop_math_helpers.nim" <<'EOF'
## Named to look like the allowlisted module. It is not it.
const FlowLoopMarkerClass* = "loop-marker"
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_loop_math_helpers
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"the allowlist matches exact paths, so a neighbouring ui/ module does not inherit the exemption" \
	"flow_loop_math_helpers"

# ---------------------------------------------------------------------------
# facade-graph-no-chain-concept — spec §3.2's newest and most load-bearing row
# ---------------------------------------------------------------------------

t="$(make_tree chain-field)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
type TraceMeta* = object
  blockNumber*: int
EOF
assert_fires "${t}" "facade-graph-no-chain-concept" \
	"a chain field added 'just for BlockTracer' is caught" \
	"blockNumber"

t="$(make_tree chain-param)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
proc openTransactionTrace*(chainId: int; txHash: string) = discard
EOF
assert_fires "${t}" "facade-graph-no-chain-concept" \
	"a chain-aware entry point on the facade is caught" \
	"chainId"

t="$(make_tree chain-in-a-comment)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
## Resolving a chainId or a blockNumber to a trace is BlockTracer's job,
## one layer up — see Client-SDK.md. This module knows none of it.
EOF
assert_clean "${t}" \
	"citing the chain layer in a comment is allowed (a comment has no ABI)"

t="$(make_tree origin-chain-is-not-a-blockchain)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
type OriginChain* = object
  sourceGeneration*: int
  blockSourceName*: string
EOF
assert_clean "${t}" \
	"origin chains, sourceGeneration and BlockSource are not chain concepts"

# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------

assert_clean "${repo_root}" "the guard passes on this repository"

# ---------------------------------------------------------------------------
# The walk leaves this repository
#
# `--root` marks a synthetic tree, and a synthetic tree has no sibling
# packages, so the checks above never exercise the sibling walk at all. These
# three run the guard the way CI runs it — with no `--root` — and then break it
# deliberately, because "the lint now walks IsoNim" is a claim that is
# satisfied just as well by a walk that silently finds nothing.
# ---------------------------------------------------------------------------

repo_output="$(cd "${repo_root}" && bash "${guard}" 2>&1)"
repo_status=$?

if [ "${repo_status}" -eq 0 ] && grep -q "OK        graph-walks-siblings" <<<"${repo_output}"; then
	ok "run with no --root, the guard performs the sibling walk and passes"
else
	bad "run with no --root, the guard performs the sibling walk and passes" \
		"exit ${repo_status}" "${repo_output}"
fi

graph_output="$(cd "${repo_root}" && bash "${guard}" --list-graph 2>&1)"
if grep -qE '^/.*/isonim/(src/)?isonim/core/signals\.nim$' <<<"${graph_output}"; then
	ok "the printed graph contains IsoNim's own source files, not just its module specs"
else
	bad "the printed graph contains IsoNim's own source files" \
		"No absolute isonim/core/signals.nim in --list-graph output." \
		"If the resolver stops at the repo edge the walk is decorative: every" \
		"forbidden-module rule below would have nothing from IsoNim to match."
fi

# The mutation. Point ISONIM_SRC at a stand-in whose `isonim/core/signals`
# imports a renderer, and the rendering rule must fire. Without this, the two
# contracts above are satisfied by a walk that enters IsoNim and then examines
# nothing.
fake_isonim="${work}/fake-isonim"
mkdir -p "${fake_isonim}/isonim/core" "${fake_isonim}/isonim/testing"
for m in signals computation owner clock async_compat; do
	echo "const Stub${m}* = 1" >"${fake_isonim}/isonim/core/${m}.nim"
done
echo "const StubTestUtils* = 1" >"${fake_isonim}/isonim/testing/test_utils.nim"
echo "const StubViewModel* = 1" >"${fake_isonim}/isonim/viewmodel.nim"
# The one line under test.
echo "import isonim/web/dom_api" >>"${fake_isonim}/isonim/core/signals.nim"
mkdir -p "${fake_isonim}/isonim/web"
echo "const StubDom* = 1" >"${fake_isonim}/isonim/web/dom_api.nim"

mutant_output="$(cd "${repo_root}" && ISONIM_SRC="${fake_isonim}" bash "${guard}" 2>&1)"
mutant_status=$?
if [ "${mutant_status}" -ne 0 ] &&
	grep -q "VIOLATION facade-graph-no-rendering" <<<"${mutant_output}" &&
	grep -q "isonim/web/dom_api" <<<"${mutant_output}"; then
	ok "a renderer import added inside IsoNim's core is caught (red-before)"
else
	bad "a renderer import added inside IsoNim's core is caught" \
		"exit ${mutant_status}" "${mutant_output}" \
		"This is the gap BlockTracer.milestones.org M2a carried: before the" \
		"walk entered IsoNim, this mutation was invisible to the guard."
fi

# And a missing sibling must be loud rather than silently narrowing the rule.
missing_output="$(cd "${repo_root}" && ISONIM_SRC="${work}/nope" \
	NIM_EVERYWHERE_SRC="${work}/nope" bash "${guard}" 2>&1)"
missing_status=$?
if [ "${missing_status}" -ne 0 ] &&
	grep -q "VIOLATION graph-walks-siblings" <<<"${missing_output}"; then
	ok "a sibling package that cannot be located fails the guard, it does not shrink it"
else
	# The overrides only take effect when they point at a real tree, so a bad
	# ISONIM_SRC falls back to ../isonim. Accept either outcome, but say which.
	if [ "${missing_status}" -eq 0 ] &&
		grep -q "OK        graph-walks-siblings" <<<"${missing_output}"; then
		ok "a bogus override falls back to the checked-out sibling rather than disabling the walk"
	else
		bad "a missing sibling package is reported, not ignored" \
			"exit ${missing_status}" "${missing_output}"
	fi
fi

# ---------------------------------------------------------------------------
# facade-graph-no-style-payload (spec §3.2 row 1, the "any CSS" clause)
#
# WHY THESE ARMS EXIST
# --------------------
# This rule's whole claim is that it sees something the import graph cannot.
# The import rules above are blind to a module with no imports — the guard's
# own NOTE on `src/frontend/ui/` says so and names `ui/flow_line_styles.nim`
# as the worked example. So every arm below plants a payload in a module the
# import rules pass cleanly, and requires this rule to report it.
#
# The suppression arms matter as much as the detection ones. When the rule was
# drafted, a `[Cc]lass` pattern matched `classifyBackendFailure` — a real
# symbol in the real SDK — and a `Class`-anywhere pattern matched
# `FilesystemDiffClass`, a classification enum in `store/types.nim`. Both are
# planted below so the narrowing cannot be undone silently.
# ---------------------------------------------------------------------------

# make_style_tree NAME BODY [BASELINE-BODY]
#
# A tree whose store module carries BODY. The store module has exactly one
# import (`std/json`), so nothing in the import rules can fire on it: any
# failure the guard reports is this rule's doing.
make_style_tree() {
	local name="$1" body="$2" baseline="${3:-}"
	local t
	t="$(make_tree "${name}")"
	cat >"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<EOF
import std/json
const StoreVersion* = 1
${body}
EOF
	# A well-behaved declared consumer, so `consumer-declared` — which fires on
	# ANY tree that declares none, and would otherwise mask this rule's verdict
	# in the arms that expect a clean exit — is satisfied.
	mkdir -p "${t}/consumer"
	cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a pane that behaves.
import ../src/frontend/viewmodel/codetracer_embed
echo StoreVersion
EOF
	if [ -n "${baseline}" ]; then
		mkdir -p "${t}/ci/test"
		printf '%s\n' "${baseline}" >"${t}/ci/test/sdk-style-payload.baseline"
	fi
	printf '%s' "${t}"
}

t="$(make_style_tree css-class-const 'const PaneClass* = "ct-pane-body"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a CSS class name bound to a constant is reported" \
	"css-class-const" "ct-pane-body"

t="$(make_style_tree css-class-proc 'proc paneClassFor*(n: int): string =
  "ct-pane"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a routine that produces a CSS class is reported" \
	"css-class-proc" "paneClassFor"

t="$(make_style_tree hex-colour 'const Accent* = "#1e1e1e"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a colour literal is reported" "hex-colour"

t="$(make_style_tree css-dimension 'const Gutter* = "12px"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a CSS dimension literal is reported" "css-dimension"

t="$(make_style_tree css-property 'const Rule* = "background-color: red"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a CSS property name is reported" "css-property"

t="$(make_style_tree unit-identifier 'var rowHeightPx*: float = 24.0')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"an identifier carrying a CSS unit is reported" \
	"unit-identifier" "rowHeightPx"

t="$(make_style_tree stylesheet-ref 'const Sheet* = "components/flow.styl"')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a reference to a stylesheet file is reported" "stylesheet-ref"

# SUPPRESSION. The two shapes that made the first draft cry wolf, plus a
# comment citing a class. All three are real spellings from the real SDK.
# SC2016 is the point: the body is Nim source, and the backticks inside it are
# a Nim doc-comment quoting `ui/flow.styl` and `BadgeBaseClass`. That comment
# is the arm — the guard must not report a class NAMED in a comment — so the
# single quotes have to keep it verbatim.
# shellcheck disable=SC2016
t="$(make_style_tree suppression 'type FilesystemDiffClass* = enum
  fdcAdded, fdcRemoved

proc classifyBackendFailure*(msg: string): int =
  ## `ui/flow.styl` styles this with `.line-flow-hit`; see BadgeBaseClass.
  0

type FlowLineStyleKind* = enum
  flskHit, flskSkip')"
assert_clean "${t}" \
	"a classification enum, a classify* routine and a comment naming a class are not reported"

# RATCHET, upward: above the ceiling fails, and says raising it is not the fix.
t="$(make_style_tree ratchet-up 'const AClass* = "x"
const BClass* = "y"' 'src/frontend/viewmodel/store/replay_data_store.nim = 1')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a payload above its ceiling fails" \
	"ceiling 1" "only turns one way"

# RATCHET, at: exactly at the ceiling is tolerated.
t="$(make_style_tree ratchet-at 'const AClass* = "x"' \
	'src/frontend/viewmodel/store/replay_data_store.nim = 1')"
assert_clean "${t}" "a payload at its ceiling is tolerated by the ratchet"

# RATCHET, downward: a ceiling left above reality is room to regress into.
t="$(make_style_tree ratchet-down 'const AClass* = "x"' \
	'src/frontend/viewmodel/store/replay_data_store.nim = 3')"
assert_fires "${t}" "facade-graph-no-style-payload" \
	"a ceiling that has drifted above reality fails" \
	"Lower the ceiling to 1"

# DEAD CEILING: a ceiling for a module that carries nothing must be removed,
# not left standing.
t="$(make_style_tree dead-ceiling 'const Clean* = 1' \
	'src/frontend/viewmodel/store/replay_data_store.nim = 2')"
assert_fires "${t}" "style-baseline-has-no-dead-ceilings" \
	"a ceiling with nothing under it is reported as dead" \
	"Delete the line"

# ENFORCING MODE: the ratchet is ignored entirely.
t="$(make_style_tree enforce 'const AClass* = "x"' \
	'src/frontend/viewmodel/store/replay_data_store.nim = 1')"
enforce_out="$(bash "${guard}" --root "${t}" --enforce-style 2>&1)"
enforce_status=$?
if [ "${enforce_status}" -ne 0 ] &&
	grep -q "VIOLATION facade-graph-no-style-payload" <<<"${enforce_out}"; then
	ok "--enforce-style fails on a payload the ratchet tolerates"
else
	bad "--enforce-style fails on a payload the ratchet tolerates" \
		"exit ${enforce_status}" "${enforce_out}"
fi

# INSTRUMENT. The rule must not be able to pass by scanning nothing. Pointed
# at a tree whose facade resolves but whose modules are unreadable, it has to
# say so. This is the arm that would have caught the five "always green"
# checks this repo has collected.
t="$(make_style_tree instrument 'const AClass* = "x"')"
instrument_out="$(bash "${guard}" --root "${t}" 2>&1)"
if grep -qE "facade-graph-no-style-payload.*(module\(s\)|scanned 0)" <<<"${instrument_out}"; then
	ok "the style scan reports how many modules it read, so zero is visible"
else
	bad "the style scan reports how many modules it read" "" "${instrument_out}"
fi

# END TO END, over the real tree, read-only. The baseline committed in this
# repo must describe the tree as it actually is — neither above nor below.
real_out="$(cd "${repo_root}" && bash "${guard}" 2>&1)"
if grep -q "OK        facade-graph-no-style-payload" <<<"${real_out}" &&
	grep -q "OK        style-baseline-has-no-dead-ceilings" <<<"${real_out}"; then
	ok "the committed baseline matches the real SDK graph exactly"
else
	bad "the committed baseline matches the real SDK graph exactly" "" "${real_out}"
fi

# And the backlog it records must be real: in enforcing mode the real tree has
# to fail, naming the modules. A baseline describing an empty backlog would
# make every arm above vacuous.
real_enforce="$(cd "${repo_root}" && bash "${guard}" --enforce-style 2>&1)"
real_enforce_status=$?
if [ "${real_enforce_status}" -ne 0 ] &&
	grep -q "VIOLATION facade-graph-no-style-payload" <<<"${real_enforce}" &&
	grep -q "origin_chain_types.nim" <<<"${real_enforce}"; then
	ok "the recorded backlog is real: --enforce-style fails on the real tree"
else
	bad "the recorded backlog is real: --enforce-style fails on the real tree" \
		"exit ${real_enforce_status}" "${real_enforce}"
fi

echo "--- ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
