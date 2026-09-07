#!/usr/bin/env bash
#
# value-presentation-boundary.sh — PLAT-2's verification gate.
#
# WHY THIS EXISTS
# ---------------
# CodeTracer-Platform.milestones.org, PLAT-2:
#
#     Verification gate: No surface formats values by a path that bypasses the
#     pipeline, enforced structurally rather than by review.
#
#     Risk: a migration that leaves two paths, so a visualiser works in some
#     surfaces.  Mitigation: the gate is a structural check over the surfaces,
#     in the shape sdk-facade-boundary.sh already uses for the SDK.
#
# So this is that check, and it is written in that shape deliberately: every
# check runs and reports, the status is decided at the end, `--root` drives it
# against synthetic trees so ci/test/value-presentation-boundary-test.sh can
# prove each rule FIRES, and the subject is stated with a floor under it.
#
# THE SUBJECT IS A CLAIM (Verification-Harness-Traps §6)
# ------------------------------------------------------
# `SURFACES` below is this gate's claim about what the population IS. A gate
# that scanned four files and reported a clean sweep of "the surfaces" would be
# answering a smaller question than it appears to — the defect §6 records three
# times over. So the list is written out, each entry is asserted to EXIST, and
# the count is asserted against `SURFACE_COUNT`. A surface that is renamed or
# deleted reddens this gate rather than silently leaving it.
#
# WHAT IS DELIBERATELY OUT OF SCOPE, BY NAME
# ------------------------------------------
# Two Rust implementations of "value -> string" survive this milestone and are
# NOT covered:
#
#   * `src/db-backend/src/value.rs::Value::text_repr`, reached by
#     `event_db.rs::convert_stop_to_program_event` — the engine's own rendering
#     of a tracepoint hit, which arrives at the desktop pre-rendered;
#   * `src/tui/src/value.rs::text_repr`, the OLD Rust TUI's, which the Nim TUI
#     replaced and which is still in the tree.
#
# A Nim import lint cannot reach either, and pretending otherwise by widening
# the file glob without widening the rules is exactly the "the number went up
# and nothing was fixed" failure §6 records. They are named here so the scope
# is narrowed EXPLICITLY rather than by omission, which is what PLAT-2's brief
# asks for when a migration is partial.
#
# THE TWO BYPASSES A NAME BLOCKLIST CANNOT CATCH, MEASURED
# --------------------------------------------------------
# Check 2 below is a BLOCKLIST OF NAMES. Eight bypasses were planted against
# this gate on 2026-09-07 by someone who had not written it. FIVE of the eight
# are caught: two the contract suite already covered, and three that were
# MISSED and are now fixed (see `value-presentation-boundary-test.sh`, which
# carries a case for each). THREE ARE NOT CAUGHT — B1 and B2 below, which this
# mechanism cannot reach at all, and a cut placed further than
# ${TRUNCATION_WINDOW} lines from its presentation, which is bounded rather
# than unreachable. They are stated here rather than left for the next person
# to plant:
#
#   B1. A SURFACE THAT KEEPS THE IMPORT AND FORMATS BY HAND UNDER A FRESH
#       NAME. `import presented_value` satisfies check 1, no banned name
#       appears, and `proc myArgText(v: Value): string = case v.kind …` sails
#       through. Checks 1 and 2 together say "the surface CAN reach the
#       pipeline and does not name a formatter it used to call"; they do not
#       and cannot say "every rendering on this surface came from the
#       pipeline". That would need a call-graph, not a grep.
#
#   B2. A FORMATTER HIDDEN ONE MODULE AWAY. `SURFACES` is a fixed, hand-written
#       list of files. A helper module that neither imports the pipeline nor is named
#       here is scanned by nothing — and this is not hypothetical: it is the
#       exact shape `src/frontend/ui/calltrace.nim` had. `safeCallArgText`
#       lived there, was reached by `ui_js.nim` and `layout.nim`, and its
#       output crossed into the SCRATCHPAD (a migrated surface) through
#       `viewmodel/views/isonim_calltrace_view.nim`. The gate reported ten
#       checks and zero failures the whole time, because `calltrace.nim` was
#       not in the list. It is now — but the BOUND is unchanged: this gate
#       covers the eleven files below and no others, and adding a surface to
#       this product means adding it here by hand.
#
# The mitigation for both is the same and it is not structural: the SUBJECT
# is written out (check 0) so the population this gate speaks about is
# reviewable, and PLAT-2's status entry says "the eleven declared surfaces"
# rather than "the surfaces".
#
# Usage:
#   ci/test/value-presentation-boundary.sh
#   ci/test/value-presentation-boundary.sh --root DIR

set -uo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
	if [ "${CT_VP_REEXECED:-0}" != "1" ]; then
		for candidate in $(type -aP bash 2>/dev/null); do
			# shellcheck disable=SC2016
			major="$("${candidate}" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)"
			case "${major}" in '' | *[!0-9]*) continue ;; esac
			if [ "${major}" -ge 4 ]; then
				export CT_VP_REEXECED=1
				exec "${candidate}" "${BASH_SOURCE[0]}" "$@"
			fi
		done
	fi
	# Said in one line with a stable token, for the reason
	# sdk-facade-boundary.sh's header gives: a caller must be able to tell
	# "I could not run" from "I found something".
	echo "NOT RUN   bash-version: this checker needs bash >= 4 and is running" \
		"under ${BASH_VERSION}. Nothing about the value-presentation" \
		"boundary has been established." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The pipeline. Every value rendering in this repository comes from here.
PIPELINE_DIR="src/common/value_presentation"

# The four modules that must be TOTALLY pure — no effectful import, no
# module-scope `var`, no `proc`, no `noSideEffect` escape. The adapters are held
# to the first two rules only: `json_adapter` walks `JsonNode`, whose accessors
# are `proc`s in `std/json`, and a `func` cannot call them.
PIPELINE_CORE=(
	"${PIPELINE_DIR}/vocabulary.nim"
	"${PIPELINE_DIR}/value_model.nim"
	"${PIPELINE_DIR}/presenter.nim"
	"${PIPELINE_DIR}/surfaces.nim"
)
PIPELINE_CORE_COUNT=4

# The adapters: one per source a value can arrive from.
PIPELINE_ADAPTERS=(
	"${PIPELINE_DIR}/json_adapter.nim"
	"src/common/common_types/utils/value_presentation_bridge.nim"
)
PIPELINE_ADAPTER_COUNT=2

# THE SUBJECT. PLAT-2's seven named surfaces, plus the files that are a
# surface's second half. Each entry is `<path>|<why it is a surface>`.
SURFACES=(
	"src/frontend/ui/state.nim|the state panel's value cell and its value-history rows"
	"src/frontend/ui/value.nim|the state panel's rich ValueComponent DOM, reused as the popup by trace, flow, editor, calltrace and scratchpad"
	"src/frontend/ui/trace.nim|tracepoint output -> ProgramEvent.content"
	"src/frontend/ui/trace_log.nim|the trace-log panel's locals column"
	"src/frontend/ui/scratchpad.nim|the scratchpad"
	"src/frontend/ui/flow.nim|omniscience and flow"
	"src/frontend/ui/step_list.nim|the step list, which is one line of a tracepoint's answer"
	"src/frontend/viewmodel/headless_session.nim|the ONLY path by which the terminal, the headless app and the Embed SDK see a value"
	"src/frontend/tui/app/views/tree_node.nim|the terminal's variables row"
	"src/frontend/tui/app/formatters/type_formatters.nim|the terminal's style table and cell measure"
	"src/frontend/ui/calltrace.nim|the call-trace row's argument chips, whose text is stored on the ViewModel and pushed into the scratchpad by 'Add value to scratchpad'"
)
SURFACE_COUNT=11

# The desktop renderer's one door to the pipeline. Every `src/frontend/ui/`
# surface reaches the pipeline through it.
DESKTOP_DOOR="src/frontend/ui/presented_value.nim"

# The name every surface must import to be on the pipeline. `presented_value`
# for the desktop, `value_presentation` for the rest.
PIPELINE_IMPORT_RE='(^|[^A-Za-z0-9_])(value_presentation|presented_value)([^A-Za-z0-9_]|$)'

# FORMATTERS THAT MUST NOT EXIST ANYWHERE OUTSIDE THE PIPELINE.
#
# Each entry is `<POSIX ERE>;<what it was>`. POSIX rather than GNU: this is
# matched with `grep -E`, and the trailing-boundary form `([^[:alnum:]_]|$)` is
# used instead of `\b` for the reason Verification-Harness-Traps §4 gives — the
# engine is part of the scanner, and a pattern that silently matches nothing
# passes every "must not contain" assertion.
#
# THE LEADING BOUNDARY DELIBERATELY ADMITS A DOT, and the first draft did not.
# It was `[^[:alnum:]_.]`, excluding `.` on the theory that a dot means field
# access — which is exactly backwards for Nim, where `value.textRepr` is the
# ORDINARY call spelling and the one every migrated surface used. Planted in a
# synthetic surface, `v.textRepr` sailed through the gate; the contract suite is
# what found it. A boundary rule that excludes the most common call syntax is a
# gate that catches only the spelling nobody writes.
BANNED_FORMATTERS=(
	'(^|[^[:alnum:]_])textRepr([^[:alnum:]_]|$);the desktop value formatter PLAT-2 deleted'
	'(^|[^[:alnum:]_])textReprDefault([^[:alnum:]_]|$);its language-neutral half'
	'(^|[^[:alnum:]_])textReprRust([^[:alnum:]_]|$);its Rust half'
	'(^|[^[:alnum:]_])readableEnum([^[:alnum:]_]|$);the enum-only formatter ui/value.nim reached for'
	'(^|[^[:alnum:]_])extractValueText([^[:alnum:]_]|$);the wire-side re-implementation headless_session carried'
	'(^|[^[:alnum:]_])classifyValue([^[:alnum:]_]|$);classification from the SHAPE of a rendered string'
	'(^|[^[:alnum:]_])truncateValue([^[:alnum:]_]|$);the terminal-only truncator, now the budget'
	'(^|[^[:alnum:]_])compactValue([^[:alnum:]_]|$);the unfocused rendering, now the budget'
	'(^|[^[:alnum:]_])focusedValue([^[:alnum:]_]|$);the focused rendering, now Budget.annotated'
	'(^|[^[:alnum:]_])compactStructSummary([^[:alnum:]_]|$);the struct summary, now builtin.record'
	'(^|[^[:alnum:]_])byteBufferOf([^[:alnum:]_]|$);byte-buffer detection from rendered members'
)

# WHAT THIS GATE DOES NOT CLAIM TO CATCH, said rather than left to be found.
#
# `common_types/utils/text_representation` still defines `$`/`text` for a
# `Value` — a multi-line DIAGNOSTIC DUMP (`"Sequence(Seq [Field; 4]):\n  100\n…"`)
# that `ui/state.valueDisplayText` reached for as a fallback before PLAT-2 and
# that no pane may show. A rule banning `$value` was written, run, and REMOVED:
# every one of its five hits in `src/frontend/ui/value.nim` was a false
# positive — `$value` over a `float` in a chart histogram, and
# `$value.typ.langType`, which is a type NAME. `$` is not lexically separable
# from `$`-on-anything-else, so this gate does not claim it.
#
# What covers it instead, and its limit: the dump is VISIBLY multi-line, so a
# surface reaching it fails that surface's own rendering assertions rather than
# this gate. That is weaker than a structural rule and is recorded as such.

# TRUNCATION APPLIED TO A PRESENTATION.
#
# The deliverable PLAT-2's brief names as most likely to be faked: "the
# presenter returns what fits, rather than each surface truncating afterwards
# ... do not leave the old truncation in place next to a new budget parameter."
#
# So a line that takes a presentation and then cuts it is a violation even
# though every identifier on it is permitted. Matched as a CO-OCCURRENCE on one
# line, which is what the faked form looks like.
TRUNCATION_CUTTERS='truncateToCells|truncateValue|cellSlice|runeSubStr'
# BRACKET CLASSES, NOT BACKSLASH ESCAPES. This is compiled by AWK, not by grep,
# and `\(` is not an escape awk understands: it warned, then died with
# `invalid regexp: Unmatched (` — and the check went on to report OK, because a
# dead scanner produces an empty set and an empty set satisfies every
# "must not contain" rule (Verification-Harness-Traps §4). The `awk-usable`
# check below exists so that cannot happen quietly again.
PRESENTATION_SOURCE='root[.]text|present[(]|presentValue|presentText'

# HOW WIDE THE WINDOW IS, AND WHY IT IS NOT ONE LINE.
#
# The faked form does not have to fit on a line, and the two-line spelling is
# the NATURAL one:
#
#     let shown = present(v).root.text
#     cellSlice(shown, 0, cells)
#
# A single-line co-occurrence rule missed exactly that, which was found by this
# gate's own contract suite rather than by review. So a cutter is a finding when
# a presentation was named on its own line or within the ${TRUNCATION_WINDOW}
# lines above it. The window is a bound, not a parser: a cut placed further away
# than this is not caught, and that is recorded rather than implied.
TRUNCATION_WINDOW=3

# Effectful stdlib modules the pipeline must not reach. A presenter that read
# any of these would not be byte-identical across runs, which is the property
# snapshot testing, cross-tier equivalence and the documentation capture
# pipeline all rest on.
FORBIDDEN_PIPELINE_IMPORTS='(^|/)(times|os|osproc|envvars|dynlib|random|httpclient|net|streams|files|dirs|paths|cmdline|monotimes|locks|typedthreads)$'

# ---------------------------------------------------------------------------

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
		;;
	*)
		echo "value-presentation-boundary.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done
cd "${root}" || exit 2

failures=0
checks_run=0

check_ok() {
	checks_run=$((checks_run + 1))
	echo "  OK        $1"
}

check_failed() {
	checks_run=$((checks_run + 1))
	failures=$((failures + 1))
	echo "  VIOLATION $1"
}

detail() { echo "              $1"; }

# code_lines FILE — the file with comment-only lines and doc-comment lines
# removed, so a rule that names a deleted formatter in PROSE does not fire.
#
# Verification-Harness-Traps §4d is the reason this exists and the reason it is
# NOT the whole answer: a scan whose pattern matches the module's own doc
# comment is satisfied by prose. Here the risk runs the other way — every one of
# these modules DOCUMENTS what it used to call — so prose is excluded and the
# `banned-formatters-detectable` check below re-reads the same files WITHOUT
# this filter to prove the patterns can still match something.
code_lines() {
	sed -e 's/#\[.*\]#//g' -e 's/[[:space:]]*#.*$//' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0. The subject exists, and it is the size this gate claims.
# ---------------------------------------------------------------------------

subject_missing=()
subject_seen=0
for entry in "${SURFACES[@]}"; do
	path="${entry%%|*}"
	if [ -f "${path}" ]; then
		subject_seen=$((subject_seen + 1))
	else
		subject_missing+=("${path}")
	fi
done
if [ "${subject_seen}" -eq "${SURFACE_COUNT}" ]; then
	check_ok "subject-complete: all ${SURFACE_COUNT} declared surfaces exist"
else
	check_failed "subject-complete: ${subject_seen} of ${SURFACE_COUNT} declared surfaces exist"
	for m in "${subject_missing[@]}"; do
		detail "missing: ${m}"
	done
	detail "A gate that scans fewer files than it claims answers a smaller question than it appears to."
fi

pipeline_seen=0
for f in "${PIPELINE_CORE[@]}"; do
	[ -f "${f}" ] && pipeline_seen=$((pipeline_seen + 1))
done
adapter_seen=0
for f in "${PIPELINE_ADAPTERS[@]}"; do
	[ -f "${f}" ] && adapter_seen=$((adapter_seen + 1))
done
if [ "${pipeline_seen}" -eq "${PIPELINE_CORE_COUNT}" ] &&
	[ "${adapter_seen}" -eq "${PIPELINE_ADAPTER_COUNT}" ]; then
	check_ok "pipeline-present: ${PIPELINE_CORE_COUNT} core module(s) + ${PIPELINE_ADAPTER_COUNT} adapter(s)"
else
	check_failed "pipeline-present: ${pipeline_seen}/${PIPELINE_CORE_COUNT} core, ${adapter_seen}/${PIPELINE_ADAPTER_COUNT} adapters"
fi

# ---------------------------------------------------------------------------
# 1. THE POSITIVE CONTROL. Every surface reaches the pipeline.
#
# This is what makes check 2's negative assertions non-vacuous
# (Verification-Harness-Traps §4). A surface that imported NOTHING would satisfy
# every "must not contain" rule below while formatting values by hand.
# ---------------------------------------------------------------------------

on_pipeline=0
off_pipeline=()
for entry in "${SURFACES[@]}"; do
	path="${entry%%|*}"
	[ -f "${path}" ] || continue
	# THE BODY IS CAPTURED BEFORE IT IS GREPPED, INTO A HERESTRING AND NOT A
	# PIPE, and the difference is a SIZE-DEPENDENT FLAKE that inverts this
	# check's answer.
	#
	# `code_lines FILE | grep -qE RE` under `set -o pipefail` reports the status
	# of the last non-zero stage. `grep -q` exits at its FIRST MATCH, which sends
	# SIGPIPE to `sed` — but `sed` only dies of it when it still had output
	# buffered, i.e. only when the file is big enough and the import sits near the
	# top. So the status was 141 for exactly the surfaces that MATCHED and were
	# LARGE, and 0 for the ones that matched and were small.
	#
	# THE NUMBER IS MEASURABLE RATHER THAN REMEMBERED — but it is NOT STABLE, and
	# that is the sharpest thing about this defect. Two earlier drafts of this
	# comment disagreed with each other ("3 of 10" in one paragraph, "nine of the
	# ten ... passed" four lines below); neither was measured, and a third
	# measurement disagreed with both. Run the reproduction below three times and
	# you will get three answers: 5, 5 and 1 on this host on 2026-09-07. It is a
	# race between `sed` finishing its write and `grep -q` exiting, so WHICH
	# surfaces flip is a property of the scheduler and not of the tree. Do not
	# quote a count here as though it were a constant; the reproducible fact is
	# that LARGE files with an early match flip and small ones do not. From the
	# repo root, under BASH — not zsh, which does not propagate the SIGPIPE
	# status the same way and reports 0 for every file:
	#
	#   bash -c 'set -o pipefail
	#     for f in <the ${SURFACES} paths>; do
	#       sed -e "s/#\[.*\]#//g" -e "s/[[:space:]]*#.*\$//" "$f" |
	#         grep -qE "(^|[^A-Za-z0-9_])(value_presentation|presented_value)([^A-Za-z0-9_]|\$)"
	#       echo "$? $f"; done'
	#
	# Measured 2026-09-07 over the eleven surfaces, five consecutive runs on one
	# idle host: 8, 8, 8, 7 and — earlier the same day, same tree — 1 file
	# returning 141. The surfaces that flip are always drawn from the LARGE ones
	# whose import sits near the top (`ui/flow.nim` at 5137 lines,
	# `ui/trace.nim` at 2350, `ui/value.nim` at 1280, `ui/calltrace.nim` at 1187,
	# `viewmodel/headless_session.nim` at 1175, `ui/state.nim` at 927); the four
	# small ones (`trace_log`, `step_list`, `tree_node`, `type_formatters`) never
	# do. So on any given run this check reported somewhere between "3 of 11" and
	# "10 of 11 surfaces reach the pipeline" on a tree where all eleven did.
	#
	# The instability is the finding. A guard whose answer depends on how big the
	# file it is reading happens to be — and on how the scheduler interleaved two
	# processes — is worse than no guard, and worse still is that its most
	# common answer was wrong in the SAFE direction only by accident.
	body="$(code_lines "${path}")"
	if grep -qE "${PIPELINE_IMPORT_RE}" <<<"${body}"; then
		on_pipeline=$((on_pipeline + 1))
	else
		off_pipeline+=("${path} — ${entry#*|}")
	fi
done
if [ "${on_pipeline}" -eq "${subject_seen}" ] && [ "${subject_seen}" -gt 0 ]; then
	check_ok "surfaces-on-pipeline: all ${on_pipeline} surface(s) reach the pipeline"
else
	check_failed "surfaces-on-pipeline: ${on_pipeline} of ${subject_seen} surface(s) reach the pipeline"
	for m in "${off_pipeline[@]}"; do
		detail "off: ${m}"
	done
fi

if [ -f "${DESKTOP_DOOR}" ]; then
	check_ok "desktop-door-present: ${DESKTOP_DOOR}"
else
	check_failed "desktop-door-present: ${DESKTOP_DOOR} is missing"
fi

# ---------------------------------------------------------------------------
# 2. No surface formats values by a path that bypasses the pipeline.
# ---------------------------------------------------------------------------

bypasses=()
for entry in "${SURFACES[@]}"; do
	path="${entry%%|*}"
	[ -f "${path}" ] || continue
	body="$(code_lines "${path}")"
	for rule in "${BANNED_FORMATTERS[@]}"; do
		pattern="${rule%%;*}"
		why="${rule#*;}"
		hits="$(grep -nE "${pattern}" <<<"${body}" || true)"
		[ -n "${hits}" ] || continue
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			bypasses+=("${path}:${hit} — ${why}")
		done <<<"${hits}"
	done
done
if [ "${#bypasses[@]}" -eq 0 ]; then
	check_ok "no-bypass: no surface names a deleted formatter"
else
	check_failed "no-bypass: ${#bypasses[@]} bypass(es)"
	for b in "${bypasses[@]}"; do
		detail "${b}"
	done
fi

# ---------------------------------------------------------------------------
# 2a. THE PATTERNS CAN STILL MATCH SOMETHING.
#
# Trap 4: a scanner that finds nothing passes every "must not contain" check.
# Check 2 is a universal quantification over matches, so it passes trivially if
# every pattern has stopped matching — a renamed symbol, a changed comment
# convention, a `code_lines` filter that ate the whole file. This re-runs the
# same patterns over the SAME files WITHOUT the comment filter, where the
# migration notes name every deleted formatter by hand, and asserts a floor.
# ---------------------------------------------------------------------------

detectable=0
for entry in "${SURFACES[@]}"; do
	path="${entry%%|*}"
	[ -f "${path}" ] || continue
	for rule in "${BANNED_FORMATTERS[@]}"; do
		pattern="${rule%%;*}"
		if grep -qE "${pattern}" "${path}"; then
			detectable=$((detectable + 1))
		fi
	done
done
if [ "${detectable}" -ge 3 ]; then
	check_ok "banned-formatters-detectable: ${detectable} raw match(es) — the scan reads the tree"
else
	check_failed "banned-formatters-detectable: only ${detectable} raw match(es)"
	detail "The banned-formatter patterns match almost nothing even WITH comments included."
	detail "Either every migration note naming them was deleted, or the patterns no longer compile"
	detail "against this grep. Check 2 above is passing vacuously until this is explained."
fi

# ---------------------------------------------------------------------------
# 3. Nobody truncates a presentation after asking for one.
# ---------------------------------------------------------------------------

post_truncations=()
awk_broken=""
AWK_ERR_LOG="$(mktemp)"
trap 'rm -f "${AWK_ERR_LOG}"' EXIT
for entry in "${SURFACES[@]}"; do
	path="${entry%%|*}"
	[ -f "${path}" ] || continue
	tbody="$(code_lines "${path}")"
	awk_errors=""
	hits="$(awk -v cutters="${TRUNCATION_CUTTERS}" -v src="${PRESENTATION_SOURCE}" \
		-v window="${TRUNCATION_WINDOW}" '
		{ lines[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) {
				if (lines[i] !~ cutters) continue
				lo = i - window; if (lo < 1) lo = 1
				for (j = lo; j <= i; j++) {
					if (lines[j] ~ src) {
						printf "%d:%s\n", i, lines[i]
						break
					}
				}
			}
		}' <<<"${tbody}" 2>"${AWK_ERR_LOG}" || true)"
	awk_errors="$(cat "${AWK_ERR_LOG}")"
	if [ -n "${awk_errors}" ]; then
		awk_broken="${awk_broken}${path}: ${awk_errors}"$'\n'
	fi
	[ -n "${hits}" ] || continue
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		post_truncations+=("${path}:${hit}")
	done <<<"${hits}"
done
# THE SCANNER RAN AT ALL. An awk that died on its own regex produces an empty
# set, and an empty set passes the rule below trivially. That happened: `\(` is
# not an awk escape, awk warned and exited, and this check printed OK.
if [ -n "${awk_broken}" ]; then
	check_failed "awk-usable: the truncation scanner could not run"
	while IFS= read -r line; do
		[ -n "${line}" ] && detail "${line}"
	done <<<"${awk_broken}"
	detail "Nothing has been established about post-presentation truncation."
else
	check_ok "awk-usable: the truncation scanner compiled and ran on every surface"
fi

if [ "${#post_truncations[@]}" -eq 0 ]; then
	check_ok "budget-not-post-filter: no surface cuts a presentation after receiving it"
else
	check_failed "budget-not-post-filter: ${#post_truncations[@]} site(s)"
	for t in "${post_truncations[@]}"; do
		detail "${t}"
	done
	detail "The presenter returns what fits. A surface that clips the answer has re-created"
	detail "the per-surface truncation PLAT-2 removed, with a budget parameter beside it."
fi

# ---------------------------------------------------------------------------
# 4. The pipeline is pure — the half a compiler cannot see.
#
# THE MECHANISM SPLIT, STATED, BECAUSE IT WAS PREVIOUSLY MISSTATED
# ----------------------------------------------------------------
# The comments in this file, in `presenter.nim`, in `vocabulary.nim` and in the
# milestone all used to say the same sentence: "a presenter that reads the
# clock, the environment or a module-level `var` does not compile". Two thirds
# of that is true and one third is not, and it was measured rather than argued:
#
#     $ cat > p.nim <<'EOF'
#     import std/envvars
#     func f*(s: string): string = s & getEnv("HOME")
#     EOF
#     $ nim check --hints:off p.nim     # ACCEPTED, silently
#
# `std/envvars.getEnv` is declared with a `{.tags: [ReadEnvEffect].}` TAG and
# NOT with a side effect, so `func` admits it. `std/times.now()` and
# `system.readFile` are both refused with "'f' can have side effects"
# (re-measured 2026-09-07); the environment is the exception.
#
# So the enforcement is split, and each half is named where it applies:
#
#   * THE CLOCK, THE FILESYSTEM AND A MODULE-LEVEL `var` — the COMPILER.
#     `value-presentation-boundary-test.sh` plants a presenter reading each of
#     the first and the third and asserts `nim check` refuses it by name.
#   * THE ENVIRONMENT — the `FORBIDDEN_PIPELINE_IMPORTS` check BELOW, and only
#     it. `envvars` is in that list; a pipeline module importing it is a
#     finding here even though the compiler would take it.
#     `value-presentation-boundary-test.sh` has an arm that plants exactly
#     that, so the claim is backed by a watched failure rather than reworded.
#
# WHAT "MODULE SCOPE" MEANS HERE, AND WHY IT IS NOT `^var`
# --------------------------------------------------------
# The previous rules were `^var`, `^proc` and `^proc[[:space:]][^=]*noSideEffect`
# — `^`-anchored, so a declaration indented by ONE SPACE was invisible to all
# three. Nim has a very ordinary way to indent a module-scope declaration:
#
#     when defined(ctRenderer):
#       var cache = 0                    # module scope. `^var` misses it.
#       proc render(v: PValue): string = # module scope. `^proc` misses it.
#
# Both were planted against this gate and both slipped through. So the scan is
# now an INDENTATION-AWARE one: a declaration is at module scope when none of
# the blocks lexically enclosing it is a ROUTINE. A `var` inside a `func` body
# is a local and is fine — `func` may have all the locals it likes; a `var`
# under a `when`, a `static:` or a `block:` is a global wearing a hat.
#
# THE BOUND: this is an indentation tracker, not a Nim parser. It does not
# understand a declaration written on one line after a `;`, a `var` produced by
# a template expansion, or the inside of a multi-line string literal. The
# COMPILER is the backstop for the first two of those (a `func` reading a
# global does not compile whatever the indentation) — this check exists for the
# third case the compiler cannot see, `envvars`, and for making the failure
# legible when it does happen.

# module_scope_decls — reads a `code_lines` body on stdin and prints one
# `LINENO:KIND:TEXT` per module-scope `var` / `let` / `proc` declaration.
module_scope_decls() {
	awk '
	function indent_of(s,   n) { match(s, /^[ \t]*/); return RLENGTH }
	{
		if ($0 ~ /^[ \t]*$/) next
		ind = indent_of($0)
		# Leave every block whose body we are no longer inside.
		while (top > 0 && stackIndent[top] >= ind) top--
		inRoutine = 0
		for (k = 1; k <= top; k++)
			if (stackKind[k] == "routine") inRoutine = 1
		body = substr($0, ind + 1)

		isRoutine = (body ~ /^(proc|func|method|iterator|converter|template|macro)([^A-Za-z0-9_]|$)/)
		isCond    = (body ~ /^(when|else|elif|static|block)([^A-Za-z0-9_]|$)/)

		if (!inRoutine) {
			if (body ~ /^proc([^A-Za-z0-9_]|$)/)
				printf "%d:proc:%s\n", NR, $0
			else if (body ~ /^var([^A-Za-z0-9_]|$)/)
				printf "%d:var:%s\n", NR, $0
			else if (body ~ /^let([^A-Za-z0-9_]|$)/)
				printf "%d:let:%s\n", NR, $0
		}

		if (isRoutine) { top++; stackIndent[top] = ind; stackKind[top] = "routine" }
		else if (isCond) { top++; stackIndent[top] = ind; stackKind[top] = "cond" }
	}'
}

impurities=()
scanned_pipeline=0
scan_broken=""
SCAN_ERR_LOG="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '${AWK_ERR_LOG}' '${SCAN_ERR_LOG}'" EXIT
for f in "${PIPELINE_CORE[@]}" "${PIPELINE_ADAPTERS[@]}"; do
	[ -f "${f}" ] || continue
	scanned_pipeline=$((scanned_pipeline + 1))
	body="$(code_lines "${f}")"

	# An effectful import. Read out of the `import` statements rather than
	# grepped for as a word, so a module whose NAME contains `os` is not a
	# finding.
	#
	# THIS IS THE ONLY THING STANDING BETWEEN THE PIPELINE AND `getEnv`. See
	# the mechanism split above: `envvars` is in `FORBIDDEN_PIPELINE_IMPORTS`
	# and `func` would not have refused it.
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		specs="${line#*import }"
		specs="${specs#*from }"
		specs="${specs//[\[\]]/ }"
		specs="${specs//,/ }"
		for spec in ${specs}; do
			case "${spec}" in std/*) spec="${spec#std/}" ;; esac
			if grep -qE "${FORBIDDEN_PIPELINE_IMPORTS}" <<<"${spec}"; then
				impurities+=("${f}: imports '${spec}' — a presentation that reads it is not byte-identical across runs")
			fi
		done
	done < <(grep -E '^[[:space:]]*(import|from)[[:space:]]' <<<"${body}" || true)

	# Module-scope declarations, at ANY indentation. See the note above.
	decls="$(module_scope_decls <<<"${body}" 2>"${SCAN_ERR_LOG}" || true)"
	scan_errors="$(cat "${SCAN_ERR_LOG}")"
	if [ -n "${scan_errors}" ]; then
		scan_broken="${scan_broken}${f}: ${scan_errors}"$'\n'
	fi
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		lineno="${hit%%:*}"
		rest="${hit#*:}"
		kind="${rest%%:*}"
		text="${rest#*:}"
		case "${kind}" in
		var)
			impurities+=("${f}:${lineno}:${text} — module-scope mutable state")
			;;
		let)
			# A module-scope `let` is not mutable, but a `let` INITIALISED FROM
			# A CALL runs that call at module load, where the effect system
			# never looks — `let started = now()` is a `func`-invisible read of
			# the clock, and it was planted against the previous `^var`-only
			# rule and slipped through. A `let` bound to a literal is fine.
			#
			# THE BOUND: `let b = Budget(name: "x")` is an object construction
			# and would be flagged too. That is deliberate — this gate cannot
			# tell a pure call from an impure one, and the pipeline binds every
			# one of its module-scope names with `const`, so the rule costs
			# nothing here and would have to be argued with rather than
			# silently widened.
			if grep -qE '=.*[A-Za-z0-9_]\(' <<<"${text}"; then
				impurities+=("${f}:${lineno}:${text} — module-scope 'let' initialised from a call; it runs at module load, where the effect system does not look. Use 'const'.")
			fi
			;;
		proc)
			case " ${PIPELINE_CORE[*]} " in
			*" ${f} "*)
				impurities+=("${f}:${lineno}:${text} -- a proc in the pure core; write it as func so the compiler checks it")
				;;
			esac
			;;
		esac
	done <<<"${decls}"

	# A `noSideEffect` ESCAPE, which is a way to lie to the effect system.
	#
	# `cast(noSideEffect)` is one. So is a `proc` DEFINITION carrying the
	# pragma: `func` is the spelling the core is required to use, and a `proc`
	# annotated to look like one is the same claim made where a reader will not
	# see it. A TYPE declaration carrying the pragma is NOT an escape and is
	# excluded — `PresentationMeasure` is `proc (s: string): int
	# {.noSideEffect, ...}`, which is the contract that keeps a front-end from
	# handing the pipeline an impure measure, i.e. the opposite of an escape.
	#
	# Not `^`-anchored, for the reason check 4's header gives.
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		impurities+=("${f}:${hit} -- a noSideEffect escape; the effect system is the check, not a pragma to silence")
	done < <(grep -nE 'cast\(noSideEffect\)|^[[:space:]]*proc[[:space:]][^=]*\{\.[^}]*noSideEffect' \
		<<<"${body}" || true)
done

# THE SCANNER RAN AT ALL, for the reason `awk-usable` gives above: an awk that
# dies on its own program produces an empty set, and an empty set satisfies
# every rule in this section.
if [ -n "${scan_broken}" ]; then
	check_failed "module-scope-scanner-usable: the module-scope scanner could not run"
	while IFS= read -r line; do
		[ -n "${line}" ] && detail "${line}"
	done <<<"${scan_broken}"
	detail "Nothing has been established about module-scope state in the pipeline."
else
	check_ok "module-scope-scanner-usable: the module-scope scanner ran on every pipeline module"
fi

if [ "${scanned_pipeline}" -eq 0 ]; then
	check_failed "pipeline-pure: scanned NO pipeline module"
	detail "Every rule in this section is a universal quantification over an empty set."
elif [ "${#impurities[@]}" -eq 0 ]; then
	check_ok "pipeline-pure: ${scanned_pipeline} module(s), no effectful import, no global, no pragma escape"
else
	check_failed "pipeline-pure: ${#impurities[@]} finding(s) over ${scanned_pipeline} module(s)"
	for i in "${impurities[@]}"; do
		detail "${i}"
	done
fi

# ---------------------------------------------------------------------------
# 5. The frontend stub is a re-export and nothing else.
# ---------------------------------------------------------------------------

stub="src/frontend/value_presentation.nim"
if [ ! -f "${stub}" ]; then
	check_failed "stub-is-a-reexport: ${stub} is missing"
	detail "It is the name \`common_types\` resolves to when \`src/frontend/types.nim\` is the includer."
else
	stub_routines="$(code_lines "${stub}" | grep -cE '^(proc|func|template|macro|iterator|method|converter)[[:space:]]' || true)"
	if [ "${stub_routines}" -eq 0 ]; then
		check_ok "stub-is-a-reexport: ${stub} declares no routine"
	else
		check_failed "stub-is-a-reexport: ${stub} declares ${stub_routines} routine(s)"
		detail "Two names for one implementation is the arrangement; two implementations is not."
	fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

echo ""
if [ "${failures}" -eq 0 ]; then
	echo "value-presentation-boundary: ${checks_run} check(s), 0 failing"
	exit 0
fi
echo "value-presentation-boundary: ${checks_run} check(s), ${failures} failing"
exit 1
