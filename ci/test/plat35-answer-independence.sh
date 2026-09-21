#!/usr/bin/env bash
#
# plat35-answer-independence.sh — PLAT-35's §30a arm.
#
# Verification-Harness-Traps §30a: **if one side's answer is derived from the
# other's, all questions agree and nothing is compared.** A cross-renderer
# comparison whose two producers share a reader is a comparison of one reading
# with itself, and it passes perfectly while the two front-ends draw two
# different screens.
#
# THE SCAN IS AIMED AT THE BODIES, NEVER AT THE FILES
# ===================================================
# Both producers' HEADERS name each other on purpose — a reader arriving at one
# needs to be told where the other is, and told why they are apart. A scan over
# whole files would therefore be red on the tree it is written for, and the
# only way to make it green would be to delete the explanation. So every comment
# is stripped first: `##` and `#` for Nim, `/** … */` and `//` for TypeScript.
#
# WHAT IT REFUSES
# ===============
#   * the GPUI producer naming the Electron one, its medium, or its artefacts;
#   * the Electron extractor naming the GPUI one, its medium, or its FFI;
#   * the SHARED vocabulary module holding a READER of either medium — which is
#     the subtler half: two producers that both call one `readAnswer` are two
#     copies of one answer no matter how far apart their files are.
#
# THE POSITIVE CONTROL, AND WHY IT IS A STRING RATHER THAN A PLANTED FILE
# =======================================================================
# Verification-Harness-Traps §4: an absence grep with no positive control is a
# scanner that finds nothing and therefore satisfies every "must not contain"
# check written over it. So the predicate is run once over a string that DOES
# contain a forbidden mention, and must find it.
#
# It is a string const here rather than a planted FILE for the reason §35a
# establishes: Nim skips re-running its frontend when the named output exists
# and no tracked source's CONTENT changed, so a file-adding plant can be
# invisible to a build-time scan — and a positive control that is sometimes not
# run is a control nobody can rely on. This scan is shell and has no such cache,
# but the rule is kept so the two controls in this campaign have one shape.
#
# ONE PREDICATE (§30's own remedy): `forbidden_mentions_in` is called by the
# rule AND by the control, so an edit that weakens it reddens both at once.
#
# THE SUBJECT SET IS THE DIRECTORY, NOT A LIST (§35)
# ==================================================
# **This scan was defeated by directory outgrowth, and this is the repair.**
#
# Its first spelling named three hard-coded paths. A verification pass added
# `src/frontend/view_vocabulary/gpui_layout_answers_ext.nim` — a SECOND GPUI
# producer, in the same directory as the first, which `readFile`s
# `src/tests/visual/answers/<id>.electron.json` and republishes it as GPUI
# answers. That is §30a exactly: one side's answer derived from the other's, so
# all eight questions would agree and nothing would be compared. The scan
# printed *"OK: PLAT-35's two producers read their own artefacts and nothing
# else"* and exited 0, because the new file was not one of its three paths.
#
# It was the THIRD such defeat in this campaign, which is why the repair is the
# one PLAT-33's §35 widening already established in
# `ci/test/editor-import-closure.sh`: derive the subjects from the DIRECTORY
# and grade whatever is in it.
#
#   * the GPUI answer producers   every *.nim in src/frontend/view_vocabulary/
#   * the Electron answer producers  every *.ts in src/tests/gui/tools/
#   * the shared vocabulary       every *.nim in src/common/view_vocabulary/
#
# `\( -type f -o -type l \)`, NOT `-type f`. PLAT-29's verification pass
# measured that `-type f` is false for a symlink, so a module symlinked in from
# outside the tree would be in no subject set at all — reproduced there against
# a synthetic tree, and there is no reason for this scan to re-learn it.
#
# AND A REPO-WIDE OUTGROWTH GUARD, because a directory rule only covers its own
# directory. A plant one directory over would be in no subject set either, so
# every file under `src/` that traffics in `LayoutAnswerSet` must be either a
# derived subject or a file the MUTATION HARNESS grades.
#
# THE FOURTH DEFEAT, AND WHY THE EXEMPTION IS NOW DERIVED
# =======================================================
# **This guard was itself defeated, and the exemption below is the repair.**
#
# It used to exempt `*/tests/*`, on the stated ground that *"a test is a
# consumer of answer sets and is graded by the mutation harness rather than by
# an absence grep"*. The first half is true of the gate suite. The second half
# was never checked against the harness, and is false of the directory: the
# mutation harness's subject list names exactly one file under any `tests/`
# path. So the same §30a-violating producer that defeated the previous spelling
# — one that `readFile`s the Electron arm's answers and republishes them as
# GPUI answers — parked at `src/frontend/tests/gpui_layout_answers_ext.nim`
# exited 0 again, because `*/tests/*` matched it and nothing asked whether any
# harness was actually looking at it.
#
# A path pattern cannot express "graded elsewhere". Only the grader can. So the
# exemption is now READ OUT OF `run-plat35-visual-mutations.py`'s own `TOUCHED`
# list, by resolving the constant names it holds against the constant
# definitions above it. A file is exempt when, and only when, the harness names
# it. Moving the harness's subject list, or dropping a file from it, moves this
# exemption in the same commit — which is what makes the two agree by
# construction rather than by a comment.
#
# It fails loudly on a derivation that yields nothing or that cannot resolve a
# name (§4), and it carries its own POSITIVE CONTROL: a path the harness does
# not name must be reported as not exempt by the same predicate the rule uses.
#
# THE SIXTH DEFEAT: A NEEDLE OVER TYPES CANNOT SEE A RELAY OVER ARTEFACTS
# ======================================================================
# **Measured 2026-09-21, by trying the three known routes and a fourth.** Routes
# one (the producer's own directory), two (one directory over) and three
# (`src/frontend/tests/`, the old `*/tests/*` exemption hole) were re-attempted
# and all three reddened. The fourth exited 0.
#
# It was the same §30a violation as route two — `readFile` the Electron arm's
# `<id>.electron.json`, `writeFile` it back as `<id>.gpui.json` — with the type
# name taken out. No `LayoutAnswer`, no `LayoutAnswerSet`, no `LayoutQuestion`,
# and the guard's whole needle was those three names, so the sweep did not
# return the file and no rule looked at it. One side's answer was the other's
# byte for byte and all eight questions would have agreed.
#
# What that says about the previous repair is worth more than the plant: the
# needle was aimed at the vocabulary a producer HAPPENS to use, and §30a is
# about where an answer CAME FROM. A relay does not need the type. It needs the
# artefact. So the artefact directory is now a SECOND needle, derived from the
# gate suite's own `AnswerDir` constant, and the sweep's extension set gained
# `*.py` — the relay would have been a four-line Python script just as easily.
# Both needles carry a control, in both directions.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

GPUI_DIR="src/frontend/view_vocabulary"
ELECTRON_DIR="src/tests/gui/tools"
# THE CAPTURE HARNESS IS AN ELECTRON-SIDE SUBJECT TOO. It is the thing that
# drives the Electron front-end and writes the arm's artefact, so §30a is about
# it as directly as it is about the extractor it calls: a capture spec that
# read the GPUI arm and wrote it out as Electron answers would be the same
# violation one file up. It sits in its own directory because Playwright
# collects specs by directory, not because it is a different kind of thing.
ELECTRON_SPEC_DIR="src/tests/gui/tests/visual"
SHARED_DIR="src/common/view_vocabulary"

# The canonical member of each set. It is asserted PRESENT rather than used as
# the set: a rename that emptied a directory would otherwise turn this scan
# into one that grades nothing and passes (§4).
GPUI_PRODUCER="${GPUI_DIR}/gpui_layout_answers.nim"
ELECTRON_PRODUCER="${ELECTRON_DIR}/layout-answers.ts"
SHARED_VOCABULARY="${SHARED_DIR}/layout_questions.nim"

for f in "${GPUI_PRODUCER}" "${ELECTRON_PRODUCER}" "${SHARED_VOCABULARY}"; do
	if [ ! -f "${f}" ]; then
		echo "FAIL: ${f} is not in the tree."
		echo "      A scan whose subject is absent reports nothing and passes"
		echo "      every check written over it (§4)."
		exit 1
	fi
done

subjects_in() {
	# $1 directory, $2 name glob
	find "$1" -maxdepth 1 \( -type f -o -type l \) -name "$2" 2>/dev/null | sort
}

mapfile -t GPUI_SUBJECTS < <(subjects_in "${GPUI_DIR}" '*.nim')
mapfile -t ELECTRON_SUBJECTS < <(
	subjects_in "${ELECTRON_DIR}" '*.ts'
	subjects_in "${ELECTRON_SPEC_DIR}" '*.ts'
)
mapfile -t SHARED_SUBJECTS < <(subjects_in "${SHARED_DIR}" '*.nim')

for pair in "GPUI_SUBJECTS ${GPUI_DIR}" "ELECTRON_SUBJECTS ${ELECTRON_DIR}" \
	"SHARED_SUBJECTS ${SHARED_DIR}"; do
	# PARAMETER EXPANSION RATHER THAN `set -- ${pair}`. The unquoted form relied
	# on word splitting to cut "NAME DIR" in two, which is SC2086; quoting it
	# would pass one argument and silently give `dir` the empty string, so the
	# "yielded no subject" message below would name nothing. Splitting on the
	# first space says what is meant without depending on IFS at all.
	name="${pair%% *}"
	dir="${pair#* }"
	declare -n arr="${name}"
	if [ "${#arr[@]}" -eq 0 ]; then
		echo "FAIL: ${dir} yielded no subject at all."
		echo "      A directory-derived subject set that is empty grades nothing"
		echo "      and passes every rule written over it (§4)."
		exit 1
	fi
done

# Strip comments. Nim: a line whose first non-space characters are `#`.
# TypeScript: `//` lines and `/* … */` blocks.
strip_nim_comments() {
	sed -E 's/[[:space:]]*##?[^"]*$//' | grep -vE '^[[:space:]]*#'
}

strip_ts_comments() {
	awk '
		/\/\*/ { inblock = 1 }
		inblock { if ($0 ~ /\*\//) inblock = 0; next }
		{ sub(/[[:space:]]*\/\/.*$/, ""); print }
	'
}

# THE ONE PREDICATE. Echoes every forbidden term the text contains, one per
# line; silence means clean.
#
# `-E`, not `-F`: one term has to be an IMPORT EDGE rather than a name. The
# shared vocabulary's `gpui_gaps.nim` quotes the path `src/isonim_gpui/
# window.nim` inside a gap's measurement string, which a bare-name rule reads
# as a violation and which is not one — a sentence about a file is not a reader
# of it. What the rule is actually about is the shared module IMPORTING a
# renderer, so that is what it matches.
forbidden_mentions_in() {
	local text="$1"
	shift
	local term
	for term in "$@"; do
		if grep -qiE -- "${term}" <<<"${text}"; then
			echo "${term}"
		fi
	done
}

GPUI_MUST_NOT_MENTION=(
	"layout-answers.ts"
	"electron"
	"querySelector"
	"getComputedStyle"
	"getBoundingClientRect"
	"src/tests/visual/answers"
)

ELECTRON_MUST_NOT_MENTION=(
	"gpui_layout_answers"
	"gpui_get_attribute"
	"gpui_tree_node_count"
	"projectDock"
	"shadow tree"
)

SHARED_MUST_NOT_MENTION=(
	"gpui_get_attribute"
	"querySelector"
	"getComputedStyle"
	# THE IMPORT EDGE, not the name — see `forbidden_mentions_in`.
	'(import|include|from)[^"]*isonim_gpui'
	"readFile"
)

failed=0

check_one() {
	local label="$1" file="$2" stripper="$3"
	shift 3
	local body
	body="$(${stripper} <"${file}")"
	local hits
	hits="$(forbidden_mentions_in "${body}" "$@")"
	if [ -n "${hits}" ]; then
		echo "FAIL: ${label} (${file}) mentions, in its BODY:"
		# A LOOP RATHER THAN AN UNQUOTED EXPANSION. `printf '%s\n' ${hits}`
		# relies on word splitting to print one hit per line, which is the
		# subject of SC2086; quoting it would print them all on one line, and
		# losing the report's shape to silence a warning is the wrong trade.
		# `nix/pre-commit.nix`'s convention is to accept the checker's form
		# rather than widen an exclusion, so the intent is expressed directly.
		#
		# (The word `shellcheck` is deliberately absent from the start of
		# every line here: a comment whose first word is that one is parsed as
		# a DIRECTIVE, and the first spelling of this note produced SC1072 and
		# SC1073 errors in a file that was otherwise clean.)
		while IFS= read -r hit; do
			[ -n "${hit}" ] && echo "        ${hit}"
		done <<<"${hits}"
		echo "      §30a: if one side's answer is derived from the other's, all"
		echo "      questions agree and nothing is compared."
		failed=1
	else
		# THE FILE IS NAMED ON THE GREEN LINE TOO. The subject set is derived
		# from a directory now, so "how many and which" is the thing a reader
		# has to be able to check — a scan that says only "OK" cannot be told
		# apart from a scan whose subject list quietly shrank to nothing.
		echo "OK: ${label} ${file} names nothing from the other side."
	fi
}

for f in "${GPUI_SUBJECTS[@]}"; do
	check_one "a GPUI-side answer module" "${f}" strip_nim_comments \
		"${GPUI_MUST_NOT_MENTION[@]}"
done
for f in "${ELECTRON_SUBJECTS[@]}"; do
	check_one "an Electron-side answer module" "${f}" strip_ts_comments \
		"${ELECTRON_MUST_NOT_MENTION[@]}"
done
for f in "${SHARED_SUBJECTS[@]}"; do
	check_one "a shared-vocabulary module" "${f}" strip_nim_comments \
		"${SHARED_MUST_NOT_MENTION[@]}"
done

echo "scan graded ${#GPUI_SUBJECTS[@]} GPUI-side, ${#ELECTRON_SUBJECTS[@]} Electron-side" \
	"and ${#SHARED_SUBJECTS[@]} shared module(s), derived from the directories."

# -----------------------------------------------------------------------
# THE OUTGROWTH GUARD — a producer OUTSIDE the three directories
# -----------------------------------------------------------------------
# The directory rule covers its directory. This covers the rest of `src/`: a
# file that traffics in `LayoutAnswerSet` and is neither a derived subject nor
# a test is a producer no rule above can see.
in_subject_set() {
	local needle="$1" s
	for s in "${GPUI_SUBJECTS[@]}" "${ELECTRON_SUBJECTS[@]}" "${SHARED_SUBJECTS[@]}"; do
		[ "${s}" = "${needle}" ] && return 0
	done
	return 1
}

# THE NEEDLE, DERIVED FROM THE VOCABULARY RATHER THAN HARD-CODED.
#
# **THE FIFTH DEFEAT, FOUND BY TRYING IT.** With the exemption repaired, a
# planted producer at `src/frontend/gpui/app/gpui_layout_answers_alt.nim` that
# `readFile`s the Electron arm's JSON and returns `seq[LayoutAnswer]` — never
# once spelling `LayoutAnswerSet` — was scanned and the guard exited 0. The
# needle was one literal type name, and a producer only has to return the ROW
# type to avoid it.
#
# So the needle is now read out of the shared vocabulary's own type section:
# every exported type whose name begins with `Layout`. A producer has to name
# one of them to build an answer at all, and a type added to the vocabulary
# widens this guard in the same commit rather than leaving a hole for the next
# pass to find. The derivation fails loudly if it yields nothing (§4).
mapfile -t ANSWER_TYPES < <(
	sed -nE 's/^[[:space:]]+(Layout[A-Za-z0-9_]*)\*[[:space:]]*=[[:space:]]*(enum|object|ref object|distinct).*$/\1/p' \
		"${SHARED_VOCABULARY}" | sort -u
)
if [ "${#ANSWER_TYPES[@]}" -eq 0 ]; then
	echo "FAIL: no exported 'Layout*' type could be read out of ${SHARED_VOCABULARY}."
	echo "      The outgrowth guard's needle is derived from them; an empty"
	echo "      needle matches nothing and the guard then certifies a tree it"
	echo "      never looked at (§4)."
	exit 1
fi
ANSWER_NEEDLE="$(printf '%s|' "${ANSWER_TYPES[@]}")"
ANSWER_NEEDLE="${ANSWER_NEEDLE%|}"
echo "the outgrowth guard's needle is derived from ${SHARED_VOCABULARY}:" \
	"${ANSWER_NEEDLE}"

# THE SIXTH DEFEAT, AND THE SECOND NEEDLE THAT CLOSES IT.
#
# **A TYPE NEEDLE CANNOT SEE A RELAY THAT NAMES NO TYPE.** With the needle above
# derived from the vocabulary, a planted producer at
# `src/frontend/gpui/app/answer_relay.nim` that `readFile`s
# `src/tests/visual/answers/<id>.electron.json` and `writeFile`s it back as
# `<id>.gpui.json` — moving the bytes through the ARTEFACT and never once
# spelling `LayoutAnswer`, `LayoutAnswerSet` or `LayoutQuestion` — was scanned
# and this guard exited 0. It is §30a in its purest form: one side's answer IS
# the other's, byte for byte, and every question would agree.
#
# The lesson is that the needle was aimed at the vocabulary a producer HAPPENS
# to use rather than at the thing §30a is actually about, which is where an
# answer CAME FROM. A relay does not need the type; it needs the artefact. So
# the artefact directory is a second needle, and the two are OR-ed.
#
# It is DERIVED from the gate suite's own `AnswerDir` constant rather than
# typed, for the reason the exemption is derived from `TOUCHED`: moving the
# artefact directory then moves this needle in the same commit. It fails loudly
# if the constant cannot be read (§4) — a needle that silently became the empty
# string would match every line of every file and bury the real rule in noise,
# which is the failure direction a `grep -E ''` takes.
ANSWER_DIR_SOURCE="src/frontend/gpui/tests/test_cross_renderer_visual_alignment.nim"
ARTEFACT_DIR="$(sed -nE 's/^[[:space:]]*AnswerDir[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' \
	"${ANSWER_DIR_SOURCE}" | head -n 1)"
if [ -z "${ARTEFACT_DIR}" ]; then
	echo "FAIL: no 'AnswerDir = \"<path>\"' constant could be read out of"
	echo "      ${ANSWER_DIR_SOURCE}."
	echo "      The outgrowth guard's second needle is derived from it; an empty"
	echo "      needle would match every line rather than none, and the guard"
	echo "      would drown the rule it exists to state (§4)."
	exit 1
fi
OUTGROWTH_NEEDLE="${ANSWER_NEEDLE}|${ARTEFACT_DIR}"
echo "the outgrowth guard's second needle is derived from ${ANSWER_DIR_SOURCE}'s" \
	"AnswerDir: ${ARTEFACT_DIR}"

# THE EXEMPTION, DERIVED FROM THE GRADER RATHER THAN FROM A PATH PATTERN.
#
# `run-plat35-visual-mutations.py` declares its subjects as `NAME = "path"`
# constants and then lists the names in `TOUCHED = [...]`. Both halves are read:
# the list says which names count, the constants say what they resolve to, and a
# name in the list that resolves to nothing is a FAILURE rather than a silently
# shorter exemption set.
MUTATION_HARNESS="src/frontend/gpui/tests/run-plat35-visual-mutations.py"
if [ ! -f "${MUTATION_HARNESS}" ]; then
	echo "FAIL: ${MUTATION_HARNESS} is not in the tree."
	echo "      The outgrowth guard's exemption is DERIVED from that harness's"
	echo "      subject list. Without it there is no set to derive, and a guard"
	echo "      that exempts by a path pattern instead is how this was defeated"
	echo "      a fourth time."
	exit 1
fi

graded_names="$(sed -n 's/^TOUCHED[[:space:]]*=[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' \
	"${MUTATION_HARNESS}" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' || true)"
if [ -z "${graded_names}" ]; then
	echo "FAIL: could not read a TOUCHED list out of ${MUTATION_HARNESS}."
	echo "      An exemption set derived from nothing exempts nothing and"
	echo "      therefore grades everything, or — worse, if the polarity ever"
	echo "      flips — exempts everything (§4)."
	exit 1
fi

GRADED_FILES=()
while IFS= read -r name; do
	[ -z "${name}" ] && continue
	value="$(sed -n "s/^${name}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*\$/\\1/p" \
		"${MUTATION_HARNESS}" | head -n 1)"
	if [ -z "${value}" ]; then
		echo "FAIL: ${MUTATION_HARNESS} lists '${name}' in TOUCHED and defines no"
		echo "      '${name} = \"<path>\"' constant this scan can resolve."
		echo "      A name that resolves to nothing would quietly shrink the"
		echo "      exemption set rather than fail (§4)."
		exit 1
	fi
	GRADED_FILES+=("${value}")
done <<<"${graded_names}"

# THE ONE PREDICATE for "is this file graded elsewhere", called by the rule AND
# by the control below.
is_graded_by_mutation_harness() {
	local needle="$1" g
	for g in "${GRADED_FILES[@]}"; do
		[ "${g}" = "${needle}" ] && return 0
	done
	return 1
}

echo "the outgrowth guard's exemption set is ${#GRADED_FILES[@]} file(s), read from" \
	"${MUTATION_HARNESS}'s TOUCHED list:"
for g in "${GRADED_FILES[@]}"; do echo "    ${g}"; done

# THE CONTROL FOR THE EXEMPTION. A path the harness does not name must NOT be
# exempt. Without it, a derivation that resolved every name to the empty string
# — or a predicate that started returning 0 unconditionally — would exempt the
# whole tree and this scan would print OK over any number of planted producers.
CONTROL_UNGRADED="src/frontend/tests/gpui_layout_answers_ext.nim"
if is_graded_by_mutation_harness "${CONTROL_UNGRADED}"; then
	echo "FAIL: the exemption predicate reports '${CONTROL_UNGRADED}' as graded by"
	echo "      the mutation harness. It is not in its TOUCHED list; a predicate"
	echo "      that says otherwise exempts every plant put there, which is"
	echo "      exactly the defeat this replaced."
	exit 1
fi
# And a path it DOES name must be exempt, so the control pins both polarities.
CONTROL_GRADED="${GRADED_FILES[0]}"
if ! is_graded_by_mutation_harness "${CONTROL_GRADED}"; then
	echo "FAIL: the exemption predicate does not recognise '${CONTROL_GRADED}',"
	echo "      which it read out of the harness's own TOUCHED list."
	exit 1
fi
echo "OK: the exemption predicate answers both polarities; it can exempt and refuse."

outgrowth=0
HARNESS_EXEMPTIONS=0
while IFS= read -r f; do
	[ -z "${f}" ] && continue
	# A CONSUMER THE MUTATION HARNESS GRADES. The gate suite reads both arms on
	# purpose and is a subject of `run-plat35-visual-mutations.py`, so an
	# absence grep is not what keeps it honest — nine killed arms are. Nothing
	# else is exempt, whatever directory it sits in.
	if is_graded_by_mutation_harness "${f}"; then
		continue
	fi
	# THE GRADER ITSELF, exempt by IDENTITY rather than by a path pattern. The
	# extension set below now includes `*.py`, which brings the mutation harness
	# into the sweep: it names the answer types in its arm needles, and it is
	# correctly absent from its own `TOUCHED` list because an arm cannot mutate
	# its own runner. It is not a producer — it publishes no answer — and the
	# comparison is against `${MUTATION_HARNESS}`, the same variable the
	# exemption set was read out of, so moving the harness moves this with it.
	# `HARNESS_EXEMPTIONS` counts it, and the count is asserted below (§4b).
	if [ "${f}" = "${MUTATION_HARNESS}" ]; then
		HARNESS_EXEMPTIONS=$((HARNESS_EXEMPTIONS + 1))
		continue
	fi
	if ! in_subject_set "${f}"; then
		echo "FAIL: ${f} names the answer vocabulary or the answer artefact"
		echo "      (${OUTGROWTH_NEEDLE})"
		echo "      and is in no subject set,"
		echo "      and the mutation harness does not grade it either."
		echo "      It is a fourth answer producer that no rule above grades."
		echo "      Move it beside its front-end's producer, widen the subject"
		echo "      directories at the top of this scan, or — if it really is a"
		echo "      consumer — add it to ${MUTATION_HARNESS}'s TOUCHED list so"
		echo "      something actually grades it. Sitting under a 'tests/'"
		echo "      directory is NOT what makes a file graded."
		outgrowth=1
	fi
done < <(
	# SOURCE ONLY, and the build trees pruned by name. `src/build-debug/ui.js`
	# is a 26 MB generated bundle and `src/db-backend/target` and
	# `src/tests/gui/node_modules` are larger still; a `grep -r` over all of
	# them does not finish in a gate's budget. Pruning them is not narrowing
	# the rule — a generated artefact is not a producer anybody wrote — but it
	# IS the kind of exclusion that silently shrinks a scan, so the extensions
	# are named positively rather than the tree being filtered negatively.
	# SOURCE ONLY, and `*.py` is in the list because the grader is written in
	# it: an extension set that omits a language the repo actually uses is a
	# sweep with a hole the size of that language, and the relay plant above
	# would have been a four-line Python script just as easily as a Nim one.
	grep -rlE "${OUTGROWTH_NEEDLE}" src/ \
		--include='*.nim' --include='*.ts' --include='*.js' --include='*.rs' \
		--include='*.py' \
		--exclude-dir=node_modules --exclude-dir=target \
		--exclude-dir=build-debug --exclude-dir=build-release \
		2>/dev/null | sort
)

# THE COUNT OF IDENTITY EXEMPTIONS IS ASSERTED, not merely applied. Exactly one
# file is exempt this way — the grader — and the sweep must have REACHED it. A
# zero here means the `*.py` include stopped working or the harness moved, and
# the exemption would then be covering nothing while reading as though it
# covered something; anything above one means a second path acquired the
# grader's exemption without acquiring its reason.
if [ "${HARNESS_EXEMPTIONS}" -ne 1 ]; then
	echo "FAIL: the outgrowth sweep exempted ${HARNESS_EXEMPTIONS} file(s) by"
	echo "      identity with ${MUTATION_HARNESS}; expected exactly 1."
	echo "      Zero means the sweep never reached the grader, so the extension"
	echo "      set or the harness path has moved and this exemption is inert."
	exit 1
fi

if [ "${outgrowth}" -ne 0 ]; then
	failed=1
else
	echo "OK: every file under src/ that traffics in answer sets or in" \
		"${ARTEFACT_DIR} is either a graded subject of this scan or a subject" \
		"of the mutation harness."
fi

# -----------------------------------------------------------------------
# THE POSITIVE CONTROL — the same predicate, over a text that DOES offend
# -----------------------------------------------------------------------
PLANT='proc gpuiPaneRectangles(): string =
  let dom = electron.querySelector("#editorComponent-0")
  dom.getBoundingClientRect()'

control_hits="$(forbidden_mentions_in "${PLANT}" "${GPUI_MUST_NOT_MENTION[@]}")"
control_count="$(grep -c . <<<"${control_hits}" || true)"
# THREE, EXACTLY: `electron`, `querySelector`, `getBoundingClientRect`. An
# "at least one" control passes on a predicate that has silently stopped
# checking two of the three terms (§4b: when the membership is knowable,
# assert the COUNT).
if [ "${control_count}" -ne 3 ]; then
	echo "FAIL: the positive control found ${control_count} forbidden mention(s), expected 3."
	echo "      The rule above and this control call ONE predicate; a control"
	echo "      that cannot find a planted violation certifies nothing."
	while IFS= read -r hit; do
		[ -n "${hit}" ] && echo "      found: ${hit}"
	done <<<"${control_hits}"
	exit 1
fi
echo "OK: the positive control found all 3 planted mentions; the scan can fail."

# -----------------------------------------------------------------------
# THE SECOND POSITIVE CONTROL — the OUTGROWTH needle, over the relay that
# defeated it
# -----------------------------------------------------------------------
# The needle derivation above fails loudly when it reads nothing, which covers
# the empty case but not the WRONG case: a needle that resolves to a live string
# matching nothing a relay would write is a guard that sweeps the tree and
# certifies it. So the needle is run over the exact plant that defeated the
# previous spelling, and over a benign body that must NOT match, because a
# needle that matches everything is the other way to certify a tree.
RELAY_PLANT='proc republish*(scenario: string): string =
  let raw = readFile("'"${ARTEFACT_DIR}"'/" & scenario & ".electron.json")
  writeFile("'"${ARTEFACT_DIR}"'/" & scenario & ".gpui.json", raw)
  raw'
BENIGN_BODY='proc paneCount*(tree: ShadowTree): int =
  for node in tree.nodes: inc result'

if ! grep -qE -- "${OUTGROWTH_NEEDLE}" <<<"${RELAY_PLANT}"; then
	echo "FAIL: the outgrowth needle (${OUTGROWTH_NEEDLE}) does not match a"
	echo "      relay that republishes the Electron arm's artefact as the GPUI"
	echo "      arm's. That plant is what defeated this guard's previous"
	echo "      spelling; a needle that cannot see it certifies the tree."
	exit 1
fi
if grep -qE -- "${OUTGROWTH_NEEDLE}" <<<"${BENIGN_BODY}"; then
	echo "FAIL: the outgrowth needle (${OUTGROWTH_NEEDLE}) matches a body that"
	echo "      names neither the vocabulary nor the artefact. A needle that"
	echo "      matches everything reports every file and states nothing."
	exit 1
fi
echo "OK: the outgrowth needle sees the artefact relay and not a benign body."

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
echo "OK: PLAT-35's two producers read their own artefacts and nothing else."
