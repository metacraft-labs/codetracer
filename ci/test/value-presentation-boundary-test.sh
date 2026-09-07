#!/usr/bin/env bash
#
# value-presentation-boundary-test.sh — the contract suite for
# ci/test/value-presentation-boundary.sh.
#
# WHY THIS EXISTS
# ---------------
# The same reason ci/test/sdk-facade-boundary-test.sh exists: a guard that has
# only ever been watched printing OK is not evidence. Verification-Harness-Traps
# §4 puts it more sharply — "a scanner that finds NOTHING passes every 'must not
# contain' check you write", and §10 adds the shape one level up: "an `assertX`
# whose failure arm is `discard` cannot fail". Every rule in that gate is a
# universal quantification over matches, so every one of them is satisfied by a
# tree it cannot read.
#
# So each rule is driven here against a synthetic tree carrying exactly the
# violation it exists to catch, and against the clean version of the same tree.
# `--root` is what makes that possible and is not used in CI.
#
# THE PURITY ARM IS TWO MECHANISMS, NOT ONE, AND THE SPLIT WAS MISSTATED
# ----------------------------------------------------------------------
# Most of the pipeline's purity is enforced by Nim's effect system: everything
# in the core is `func`, which is `{.noSideEffect.}`, so a presenter that reads
# the CLOCK, the FILESYSTEM or a MODULE-LEVEL `var` does not COMPILE. That is a
# stronger check than any scanner, and it is the one nobody had ever watched
# fail; the arms at the bottom of this file copy the real package, plant each,
# and assert `nim check` REFUSES it, naming the effect.
#
# THE ENVIRONMENT IS THE EXCEPTION, and every comment in this milestone used to
# claim otherwise. `std/envvars.getEnv` carries `ReadEnvEffect` as a TAG and
# not as a side effect, so it compiles inside a `func`. The arm
# `the environment is NOT refused by the compiler` below asserts that — it is a
# passing test of a NEGATIVE fact, so the day Nim changes its mind the arm goes
# red and the comments get corrected instead of quietly becoming true again for
# the wrong reason. What actually keeps `getEnv` out of the pipeline is the
# guard's `FORBIDDEN_PIPELINE_IMPORTS` list, and there is an arm for that too.
#
# Usage:
#   bash ci/test/value-presentation-boundary-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/value-presentation-boundary.sh"

pass=0
fail=0
notrun=0

ok() {
	pass=$((pass + 1))
	echo "  ok      $1"
}

bad() {
	fail=$((fail + 1))
	echo "  FAIL    $1"
	shift
	while [ $# -gt 0 ]; do
		echo "            $1"
		shift
	done
}

skip_loudly() {
	notrun=$((notrun + 1))
	echo "  NOT RUN $1"
}

work="$(mktemp -d)"
# Invoked by the trap below, which shellcheck cannot see (SC2329).
# shellcheck disable=SC2329
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Tree construction
#
# `make_tree NAME` builds a minimal tree that PASSES every rule. Each case then
# changes exactly one thing, so a failure names one rule.
# ---------------------------------------------------------------------------

make_tree() {
	local name="$1"
	local t="${work}/${name}"
	mkdir -p "${t}/src/common/value_presentation" \
		"${t}/src/common/common_types/utils" \
		"${t}/src/frontend/ui" \
		"${t}/src/frontend/viewmodel" \
		"${t}/src/frontend/tui/app/views" \
		"${t}/src/frontend/tui/app/formatters"

	local m
	for m in vocabulary value_model presenter surfaces; do
		cat >"${t}/src/common/value_presentation/${m}.nim" <<EOF
import std/strutils
func ${m}Marker*(s: string): string = s.strip()
EOF
	done
	cat >"${t}/src/common/value_presentation/json_adapter.nim" <<'EOF'
import std/json
proc toPValue*(node: JsonNode): string = node.getStr("")
EOF
	cat >"${t}/src/common/common_types/utils/value_presentation_bridge.nim" <<'EOF'
func presentValue*(v: int): int = v
EOF
	cat >"${t}/src/common/value_presentation.nim" <<'EOF'
import value_presentation/[vocabulary, value_model, presenter, surfaces]
export vocabulary, value_model, presenter, surfaces
EOF
	cat >"${t}/src/frontend/value_presentation.nim" <<'EOF'
import ../common/value_presentation/[vocabulary, value_model, presenter, surfaces]
export vocabulary, value_model, presenter, surfaces
EOF
	cat >"${t}/src/frontend/ui/presented_value.nim" <<'EOF'
import ../../common/value_presentation
func statePanelValue*(v: int): int = v
EOF
	# EVERY SYNTHETIC SURFACE CARRIES MIGRATION PROSE, because every real one
	# does: a migrated surface documents what it used to call. That prose is
	# also what `banned-formatters-detectable` reads to prove its patterns still
	# match SOMETHING — so a tree without it is a tree where `no-bypass` passes
	# vacuously, which is a case of its own (`no-prose`) rather than the
	# baseline.
	local s
	for s in state value trace trace_log scratchpad flow step_list calltrace; do
		cat >"${t}/src/frontend/ui/${s}.nim" <<'EOF'
## PLAT-2: this used to call textRepr and classifyValue, and truncateValue
## afterwards.
import ./presented_value
proc render*(v: int): int = statePanelValue(v)
EOF
	done
	cat >"${t}/src/frontend/viewmodel/headless_session.nim" <<'EOF'
import ../../common/value_presentation
proc decode*(v: int): int = v
EOF
	cat >"${t}/src/frontend/tui/app/views/tree_node.nim" <<'EOF'
import ../../../../common/value_presentation
proc row*(v: int): int = v
EOF
	cat >"${t}/src/frontend/tui/app/formatters/type_formatters.nim" <<'EOF'
import ../../../../common/value_presentation
func style*(v: int): int = v
EOF
	printf '%s' "${t}"
}

run_guard() { bash "${guard}" --root "$1" 2>&1; }

# assert_fires TREE CHECK-NAME DESCRIPTION [NEEDLE...]
assert_fires() {
	local tree="$1" check="$2" desc="$3"
	shift 3
	local output status needle
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -eq 0 ]; then
		bad "${desc}" "the guard exited 0; it should have found ${check}" \
			"${output}"
		return
	fi
	if ! grep -q "VIOLATION ${check}" <<<"${output}"; then
		bad "${desc}" "expected 'VIOLATION ${check}', got:" "${output}"
		return
	fi
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${output}"; then
			bad "${desc}" "expected the diagnosis to contain '${needle}'" \
				"${output}"
			return
		fi
	done
	ok "${desc}"
}

assert_clean() {
	local tree="$1" desc="$2"
	local output status
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -ne 0 ]; then
		bad "${desc}" "the guard exited ${status} on a clean tree:" "${output}"
		return
	fi
	# A clean tree must also have RUN the checks. A guard that reported
	# "0 check(s), 0 failing" exits 0 too, and that is trap 4 wearing the
	# guard's own uniform.
	if ! grep -qE '11 check\(s\), 0 failing' <<<"${output}"; then
		bad "${desc}" "expected all 11 checks to have run:" "${output}"
		return
	fi
	ok "${desc}"
}

echo "=== value-presentation-boundary: contract suite ==="

# ---------------------------------------------------------------------------
# The negative control for every case below.
# ---------------------------------------------------------------------------
clean="$(make_tree clean)"
assert_clean "${clean}" "a clean tree passes, and all eleven checks ran"

# ---------------------------------------------------------------------------
# subject-complete
# ---------------------------------------------------------------------------
t="$(make_tree missing-surface)"
rm "${t}/src/frontend/ui/flow.nim"
assert_fires "${t}" "subject-complete" \
	"a deleted surface reddens the gate instead of shrinking its subject" \
	"src/frontend/ui/flow.nim"

# ---------------------------------------------------------------------------
# pipeline-present
# ---------------------------------------------------------------------------
t="$(make_tree missing-pipeline)"
rm "${t}/src/common/value_presentation/presenter.nim"
assert_fires "${t}" "pipeline-present" \
	"a missing pipeline module is a finding, not a smaller scan"

# ---------------------------------------------------------------------------
# surfaces-on-pipeline — THE POSITIVE CONTROL
# ---------------------------------------------------------------------------
t="$(make_tree off-pipeline)"
cat >"${t}/src/frontend/ui/scratchpad.nim" <<'EOF'
proc render*(v: int): string =
  # Formats a value with no pipeline in sight.
  "value: " & $v
EOF
assert_fires "${t}" "surfaces-on-pipeline" \
	"a surface that reaches the pipeline through nothing is caught" \
	"src/frontend/ui/scratchpad.nim"

# THE SIZE-DEPENDENT FLAKE THIS CHECK ACTUALLY HAD. `printf … | grep -q` under
# `pipefail` returns 141 when grep exits first and the writer still had output
# buffered, so the answer depended on the FILE'S SIZE: nine small surfaces
# passed and `ui/flow.nim` (5 100 lines) was reported off the pipeline while
# carrying the import. A large clean surface is now part of the contract.
t="$(make_tree large-surface)"
{
	echo "## PLAT-2: this used to call textRepr and classifyValue, and truncateValue."
	echo "import ./presented_value"
	echo "proc render*(v: int): int ="
	for _ in $(seq 1 4000); do
		echo "  # a line of padding, so the file exceeds the pipe buffer"
	done
	echo "  statePanelValue(v)"
} >"${t}/src/frontend/ui/flow.nim"
assert_clean "${t}" "a surface larger than the pipe buffer is still seen on the pipeline"

# ---------------------------------------------------------------------------
# no-bypass — one case per banned formatter family
# ---------------------------------------------------------------------------
t="$(make_tree bypass-textrepr)"
cat >>"${t}/src/frontend/ui/state.nim" <<'EOF'
proc cell*(v: int): string = v.textRepr
EOF
assert_fires "${t}" "no-bypass" \
	"a surface calling the deleted desktop formatter is caught" \
	"textRepr"

t="$(make_tree bypass-extract)"
cat >>"${t}/src/frontend/viewmodel/headless_session.nim" <<'EOF'
proc text*(node: int): string = extractValueText(node)
EOF
assert_fires "${t}" "no-bypass" \
	"a surface calling the deleted wire-side formatter is caught" \
	"extractValueText"

t="$(make_tree bypass-classify)"
cat >>"${t}/src/frontend/tui/app/views/tree_node.nim" <<'EOF'
proc klass*(t, v: string): int = classifyValue(t, v)
EOF
assert_fires "${t}" "no-bypass" \
	"classification from a rendered string's SHAPE is caught" \
	"classifyValue"

# A COMMENT NAMING A DELETED FORMATTER IS NOT A VIOLATION.
# Verification-Harness-Traps §4d is the mirror of this: a scan satisfied by
# prose. Here the risk runs the other way — every migrated surface DOCUMENTS
# what it used to call — so a gate that read comments would be permanently red
# for the migration notes that make it reviewable.
t="$(make_tree comment-only)"
cat >>"${t}/src/frontend/ui/state.nim" <<'EOF'
# This used to call textRepr, and `classifyValue` beside it.
EOF
assert_clean "${t}" "a comment naming a deleted formatter is not a bypass"

# ---------------------------------------------------------------------------
# banned-formatters-detectable — the anti-vacuity control on the control
# ---------------------------------------------------------------------------
# `no-bypass` passes trivially if the patterns match nothing at all. Strip the
# migration prose from every surface and the patterns have nothing to match —
# which is indistinguishable, to `no-bypass`, from a perfectly migrated tree.
# This check is what tells the two apart.
t="$(make_tree no-prose)"
for f in "${t}"/src/frontend/ui/*.nim; do
	sed -i.bak '/^## PLAT-2/d;/^## afterwards/d' "${f}" && rm -f "${f}.bak"
done
assert_fires "${t}" "banned-formatters-detectable" \
	"a tree where the banned patterns match nothing at all is reported, not passed" \
	"passing vacuously"

# ---------------------------------------------------------------------------
# budget-not-post-filter — THE DELIVERABLE MOST LIKELY TO BE FAKED
# ---------------------------------------------------------------------------
t="$(make_tree post-truncate)"
cat >>"${t}/src/frontend/ui/flow.nim" <<'EOF'
proc chip*(v: int; cells: int): string =
  truncateToCells(statePanelValue(v).root.text, cells)
EOF
assert_fires "${t}" "budget-not-post-filter" \
	"clipping a presentation after receiving it is caught" \
	"src/frontend/ui/flow.nim"

t="$(make_tree post-truncate-reversed)"
cat >>"${t}/src/frontend/ui/flow.nim" <<'EOF'
proc chip*(v: int; cells: int): string =
  let shown = present(v).root.text
  cellSlice(shown, 0, cells)
EOF
assert_fires "${t}" "budget-not-post-filter" \
	"the same fake written the other way round is caught too"

# THE TRUNCATION SCANNER IS AWK, AND AWK CAN DIE ON ITS OWN REGEX.
#
# It did: `\(` is not an escape awk understands, so the scanner exited with
# `invalid regexp: Unmatched (` and `budget-not-post-filter` printed OK over an
# empty set. There is now an `awk-usable` check, and this is the case that
# proves it can say no — driven by handing the guard a surface path that is a
# DIRECTORY, which awk cannot read and which is the only way to break it from
# outside without editing the guard.
t="$(make_tree awk-unreadable)"
rm "${t}/src/frontend/ui/flow.nim"
mkdir -p "${t}/src/frontend/ui/flow.nim"
assert_fires "${t}" "subject-complete" \
	"a surface that is not a readable file is reported rather than scanned as empty"

# ---------------------------------------------------------------------------
# pipeline-pure — lexical half
# ---------------------------------------------------------------------------
t="$(make_tree impure-import)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
import std/times
func presenterMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a pipeline module importing the clock is caught" \
	"times"

t="$(make_tree impure-import-os)"
cat >"${t}/src/common/value_presentation/surfaces.nim" <<'EOF'
import std/os
func surfacesMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a pipeline module importing the filesystem is caught" \
	"os"

t="$(make_tree impure-global)"
cat >"${t}/src/common/value_presentation/value_model.nim" <<'EOF'
var cachedWidth* = 0
func valueModelMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a module-scope var in the pipeline is caught" \
	"module-scope mutable state"

t="$(make_tree impure-proc)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
proc presenterMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a proc in the pure core is caught, because a func is what the compiler checks" \
	"write it as func"

# THE FIVE BYPASSES THAT WERE PLANTED AGAINST THIS GATE AND SLIPPED THROUGH.
#
# On 2026-09-07 eight bypasses were planted against the guard by someone who
# had not written it. Six survived review as catchable; three of those six were
# NOT caught at the time, and they are the three below. All three are the same
# defect — an `^`-anchored grep, or a grep for the wrong keyword — and the fix
# was the indentation-aware `module_scope_decls` scan in the guard. A rule that
# has only ever been watched printing OK is not evidence, so each is a case.
#
# (The other two, B1 and B2, are NOT catchable by a name blocklist and are
# declared as bounds in the guard's header instead of pretended about. B1 is a
# surface that keeps the import and formats by hand under a fresh name; B2 is a
# formatter one module away, which is the shape `ui/calltrace.nim` actually had.
# Confirm they still slip with:
#   printf '\nproc chipText(v: Value): string = $v\n' >> TREE/src/frontend/ui/scratchpad.nim
# and the guard still exits 0. That is the declared bound, not a bug to file.)

t="$(make_tree impure-global-under-when)"
cat >"${t}/src/common/value_presentation/value_model.nim" <<'EOF'
when defined(ctRenderer):
  var cachedWidth* = 0
func valueModelMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a module-scope var INDENTED under a when is caught (the ^var rule missed it)" \
	"module-scope mutable state"

t="$(make_tree impure-proc-under-when)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
when defined(ctRenderer):
  proc presenterMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a proc in the pure core INDENTED under a when is caught (the ^proc rule missed it)" \
	"write it as func"

t="$(make_tree impure-let-from-call)"
cat >"${t}/src/common/value_presentation/surfaces.nim" <<'EOF'
let hostName* = readFile("/etc/hostname")
func surfacesMarker*(s: string): string = s
EOF
assert_fires "${t}" "pipeline-pure" \
	"a module-scope let initialised from an effectful call is caught (the rule's own comment claimed it read 'let'; the grep was ^var only)" \
	"module-scope 'let' initialised from a call"

# A LOCAL `var` INSIDE A `func` IS NOT A FINDING, and this is the case that
# keeps the fix above from being "flag every var". `func` may have all the
# locals it likes; what the rule is about is state that outlives a call.
t="$(make_tree local-var-is-fine)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
func presenterMarker*(s: string): string =
  var acc = ""
  for c in s:
    acc.add c
  acc
EOF
assert_clean "${t}" "a local var inside a func is not a module-scope global"

# THE ENVIRONMENT, WHICH THE COMPILER DOES NOT CATCH. See the header. This is
# the arm that makes the corrected claim ("the import check is what stops it")
# a watched fact rather than a rewording.
t="$(make_tree impure-import-envvars)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
import std/envvars
func presenterMarker*(s: string): string = s & getEnv("CT_VALUE_STYLE")
EOF
assert_fires "${t}" "pipeline-pure" \
	"a pipeline module importing the ENVIRONMENT is caught by the import rule — the compiler would not have refused it" \
	"envvars"

t="$(make_tree impure-cast)"
cat >"${t}/src/common/value_presentation/presenter.nim" <<'EOF'
import std/strutils
func presenterMarker*(s: string): string =
  {.cast(noSideEffect).}:
    result = s.strip()
EOF
assert_fires "${t}" "pipeline-pure" \
	"a cast(noSideEffect) escape is caught" \
	"noSideEffect escape"

# ---------------------------------------------------------------------------
# stub-is-a-reexport
# ---------------------------------------------------------------------------
t="$(make_tree stub-with-code)"
cat >>"${t}/src/frontend/value_presentation.nim" <<'EOF'
proc presentDifferently*(v: int): string = "the second implementation"
EOF
assert_fires "${t}" "stub-is-a-reexport" \
	"a second implementation hiding behind the frontend stub name is caught"

# ---------------------------------------------------------------------------
# THE COMPILER ARM. The purity rule the effect system enforces, watched failing.
# ---------------------------------------------------------------------------
if ! command -v nim >/dev/null 2>&1; then
	skip_loudly "purity is compiler-enforced: no \`nim\` on PATH, so the strongest of the purity checks was NOT exercised"
else
	planted="${work}/planted"
	mkdir -p "${planted}"
	cp -r "${repo_root}/src/common/value_presentation" "${planted}/"

	# THE CLEAN ARM FIRST. If the package does not compile on its own, the
	# refusal below would prove nothing — trap 7's "the passing fixture is an
	# instance of the defect", arriving as a compile error that says the wrong
	# thing.
	cat >"${planted}/probe_clean.nim" <<'EOF'
import value_presentation/[vocabulary, value_model, presenter, surfaces]
func probe*(v: PValue): string = present(v, TracepointBudget).root.text
EOF
	if nim check --hints:off --path:"${planted}" "${planted}/probe_clean.nim" >"${work}/clean.log" 2>&1; then
		ok "the pipeline compiles as pure: a func may call the presenter"
	else
		bad "the pipeline compiles as pure: a func may call the presenter" \
			"$(tail -5 "${work}/clean.log")"
	fi

	# THE PLANTED VIOLATION: a presenter that reads the clock.
	cat >"${planted}/probe_impure.nim" <<'EOF'
import std/times
import value_presentation/[vocabulary, value_model, presenter, surfaces]

func impurePresenter*(v: PValue): string =
  ## A presenter that reads the clock. This must NOT compile.
  let stamp = now()
  present(v, TracepointBudget).root.text & $stamp
EOF
	if nim check --hints:off --path:"${planted}" "${planted}/probe_impure.nim" >"${work}/impure.log" 2>&1; then
		bad "a presenter that reads the clock is refused BY THE COMPILER" \
			"nim check ACCEPTED it — the purity rule is not being enforced" \
			"$(tail -5 "${work}/impure.log")"
	elif grep -q "can have side effects" "${work}/impure.log"; then
		ok "a presenter that reads the clock is refused BY THE COMPILER, naming the effect"
	else
		bad "a presenter that reads the clock is refused BY THE COMPILER" \
			"it was refused, but not for the reason claimed — the message does not mention side effects:" \
			"$(tail -5 "${work}/impure.log")"
	fi

	# THE ENVIRONMENT, MEASURED RATHER THAN ASSUMED — AND IT IS *ACCEPTED*.
	#
	# This arm asserts a NEGATIVE fact about the compiler, which is unusual and
	# is the point: four places in this milestone claimed "a presenter reading
	# the clock, the environment or a module-level `var` does not compile", and
	# the middle third of that sentence was false. `std/envvars.getEnv` is
	# declared `{.tags: [ReadEnvEffect].}` — a TAG, not a side effect — so
	# `func` admits it.
	#
	# The property PLAT-2 needs still holds, by the OTHER mechanism: `envvars`
	# is in the guard's `FORBIDDEN_PIPELINE_IMPORTS`, and the
	# `impure-import-envvars` case above watches that fire. This arm exists so
	# that if Nim ever does start refusing it, this file goes red and someone
	# re-reads the four comments rather than leaving them accidentally correct.
	cat >"${planted}/probe_env.nim" <<'EOF'
import std/envvars
import value_presentation/[vocabulary, value_model, presenter, surfaces]

func envReadingPresenter*(v: PValue): string =
  ## Reads the ENVIRONMENT. The compiler ACCEPTS this; the import lint is what
  ## refuses it. If this ever stops compiling, correct the comments that say
  ## the compiler is the mechanism here.
  present(v, TracepointBudget).root.text & getEnv("CT_VALUE_STYLE")
EOF
	if nim check --hints:off --path:"${planted}" "${planted}/probe_env.nim" >"${work}/env.log" 2>&1; then
		ok "the environment is NOT refused by the compiler (ReadEnvEffect is a tag) — the import lint is the mechanism, and the guard has a case for it"
	else
		bad "the environment is NOT refused by the compiler" \
			"nim check REFUSED it. That is a stronger world than the one the comments now describe:" \
			"re-read ci/test/value-presentation-boundary.sh check 4, presenter.nim, vocabulary.nim and PLAT-2." \
			"$(tail -5 "${work}/env.log")"
	fi

	# THE SAME, FOR A GLOBAL. `func` cannot read a module-level `var`, which is
	# what makes `common_lang.CURRENT_LANG` — the ambient language `textRepr`
	# read — unreachable from the new pipeline by construction rather than by
	# discipline.
	cat >"${planted}/probe_global.nim" <<'EOF'
import value_presentation/[vocabulary, value_model, presenter, surfaces]

var ambientLang = plRust

func globalReadingPresenter*(v: PValue): string =
  ## Reads a module-level `var`, exactly as `textRepr` read `CURRENT_LANG`.
  ## This must NOT compile.
  present(v, TracepointBudget, ambientLang).root.text
EOF
	if nim check --hints:off --path:"${planted}" "${planted}/probe_global.nim" >"${work}/global.log" 2>&1; then
		bad "a presenter that reads a module-level var is refused BY THE COMPILER" \
			"nim check ACCEPTED it — the ambient-state rule is not being enforced"
	elif grep -q "can have side effects" "${work}/global.log"; then
		ok "a presenter that reads a module-level var is refused BY THE COMPILER"
	else
		bad "a presenter that reads a module-level var is refused BY THE COMPILER" \
			"refused for a different reason:" "$(tail -5 "${work}/global.log")"
	fi
fi

echo ""
echo "value-presentation-boundary-test: ${pass} passed, ${fail} failed, ${notrun} not run"
[ "${fail}" -eq 0 ] || exit 1
[ "${notrun}" -eq 0 ] || exit 0
exit 0
