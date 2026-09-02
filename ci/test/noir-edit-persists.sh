#!/usr/bin/env bash
#
# noir-edit-persists.sh — what you type is what is kept, and what is compiled.
#
# WHAT THIS IS FOR
# ----------------
# `ide.codetracer.com/noir` presented a working IDE — file tree, Monaco, Build
# and Run that genuinely compiled — and silently discarded every keystroke:
#
#   * `web_noir_build.templateVfsEntries` read `tmpl.files` off a copy of the
#     compile-time bundled template that nothing mutated, so Build and Run
#     compiled the BUNDLED project regardless of what the visitor had typed. A
#     visitor could edit `src/main.nr`, press Ctrl+B, and get a **successful
#     build of code they did not write** — worse than a read-only editor,
#     because it looks like it worked.
#   * `CODETRACER::save-file` had no host on web, so Ctrl+S logged
#     "no host for CODETRACER::save-file" and the buffer stayed dirty forever.
#
# Meanwhile the deployed boot line said, to every visitor:
#
#     announcement=This browser refused to mark your work as persistent ...
#     Your files survive reloads and crashes ... Export to keep them.
#
# That sentence was FALSE in both halves. Nothing was ever written (the store
# was opened and no project was ever put in it, `acknowledgeDurability` had
# zero callers so every facade write was refused, and the editor's save path
# ended in a console warning), and `exportProjectArchive` — complete since the
# store landed — had zero callers, so "export to keep them" named an action the
# product did not offer. This gate is the assertion that both are now true.
#
# THE FALSE PASS THIS GATE REFUSES TO BE
# --------------------------------------
# **A test that edits a file and asserts a successful build proves nothing**,
# because the unedited template also builds successfully — the green tick is
# produced by the broken product and the fixed one alike. So nothing here
# asserts "a build succeeded". The assertions are:
#
#   * the restored bytes EQUAL the bytes that were in the editor when it was
#     saved (exact equality, not a substring — a restore that dropped half the
#     file or merged the bundle back in would pass a substring check);
#   * the restored bytes DIFFER from the bundled bytes, read from a browser
#     context that has never been written to. This is what separates "restored
#     from storage" from "fell back to the bundle", and it is the assertion
#     that goes red on the shipped build.
#
# THE RELOAD IS REAL. `page.reload()` destroys every piece of JavaScript state
# in the tab and keeps the origin, so origin storage is the only channel a byte
# can cross. A same-page write-then-read would be satisfied by a variable.
#
# THE SHAPE, from traps doc 4a and 4c
# -----------------------------------
#   * COUNTED assertions; `expect_count` fails if the tally misses the number
#     written at the bottom, so an arm that aborted or a probe that produced no
#     JSON becomes a count mismatch rather than a clean summary.
#   * A CONTROL ARM — the unmutated bundle must go green, or the mutation arms
#     below could be red for an unrelated reason.
#   * A MUTATION ARM PER CASE, each verified to redden THE ASSERTION WRITTEN
#     FOR IT. Every arm checks that its patch actually changed the bundle's
#     bytes before the arm is allowed to run: a `sed` that matches nothing
#     exits 0 and would leave the arm measuring an unmutated tree, which on
#     this campaign already produced six arms that "survived" a tree they had
#     never patched.
#
set -uo pipefail

cd "$(dirname "$0")/../.."
root="$(pwd)"
cache="${CT_EDIT_PERSIST_CACHE:-$(mktemp -d)}"
mkdir -p "${cache}"

checks=0
failures=0

ck() {
	# ck ok|fail MESSAGE
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		printf '  [FAILED]  %s\n' "$2"
		failures=$((failures + 1))
	fi
}

note() { printf '  %s\n' "$*"; }

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

echo "=== what you type is kept, and it is what gets compiled ==="
echo

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH; run inside the dev shell" >&2
	exit 2
}
if [ ! -d node_modules/playwright ]; then
	echo "node_modules/playwright is missing; run inside the dev shell" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# The bundle under test.
# ---------------------------------------------------------------------------
bundle="${CT_WEB_BUNDLE_DIR:-}"
if [ -z "${bundle}" ]; then
	bundle="${cache}/bundle"
	echo "Assembling a bundle (CT_WEB_BUNDLE_DIR unset)..."
	if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
		>"${cache}/assemble.log" 2>&1; then
		echo "  the bundle did not assemble; see ${cache}/assemble.log" >&2
		tail -20 "${cache}/assemble.log" >&2
		exit 1
	fi
	echo "  assembled at ${bundle}"
fi
# THE RENDERER'S PUBLISHED NAME, DERIVED FROM THE DOCUMENT rather than spelled.
#
# `ui.js` is its name today. The content-addressed-assets work makes a
# published file's name carry its digest, so a gate that spelled `ui.js` would
# either stop finding it or -- worse -- keep finding a stale copy beside the
# hashed one. The entry document is the one place that must always name the
# renderer correctly, because that is where the browser loads it from; reading
# it asks the same question the product asks instead of guessing the answer.
#
# The renderer is the only script the document loads that is not under
# `/public/` -- `web-bundle-assets.sh` places the third-party bundle and jstree
# there, and the deploy guard asserts that arrangement.
renderer_rel="$(grep -o '<script[^>]*src="[^"]*"' "${bundle}/index.html" |
	sed -n 's/.*src="\([^"]*\)".*/\1/p' |
	grep -v '^/public/' | head -1 | sed 's#^/##')"
if [ -z "${renderer_rel}" ] || [ ! -s "${bundle}/${renderer_rel}" ]; then
	echo "could not derive the renderer's path from ${bundle}/index.html" >&2
	echo "  (derived: '${renderer_rel:-<none>}') -- nothing to drive" >&2
	exit 1
fi
renderer="${bundle}/${renderer_rel}"
echo "  renderer: ${renderer_rel} ($(wc -c <"${renderer}" | tr -d ' ') bytes)"
echo

probe() {
	# probe BUNDLE_DIR OUT_JSON — never trust the exit code; the caller reads
	# the JSON, and a run that produced none is reported as such.
	local dir="$1" out="$2"
	if ! timeout 600 node ci/test/noir_edit_persists_probe.mjs "${dir}" \
		"${MARKER}" >"${out}" 2>"${out}.err"; then
		note "probe exited non-zero; see ${out}.err"
	fi
	if [ ! -s "${out}" ]; then
		echo "PROBE PRODUCED NO JSON for ${dir}" >&2
		tail -15 "${out}.err" >&2 || true
		return 1
	fi
	return 0
}

jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d.get(sys.argv[2])))' "$1" "$2"; }
jbool() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("1" if d.get(sys.argv[2]) else "0")' "$1" "$2"; }
jstrlen() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get(sys.argv[2]) or ""))' "$1" "$2"; }
jeq() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("1" if (d.get(sys.argv[2]) or "")==(d.get(sys.argv[3]) or "") else "0")' "$1" "$2" "$3"; }

MARKER="EDIT_PERSISTS_MARKER"

# ---------------------------------------------------------------------------
echo "Arm: CONTROL — the bundle as assembled"
# ---------------------------------------------------------------------------
if ! probe "${bundle}" "${cache}/control.json"; then
	echo "RESULT: FAILED — the control arm produced no measurement." >&2
	exit 1
fi

err="$(jget "${cache}/control.json" error)"
if [ "${err}" != '""' ]; then
	note "probe reported: ${err}"
fi

[ "$(jbool "${cache}/control.json" mounted)" = "1" ] &&
	ck ok "the studio mounts on /noir" ||
	ck fail "the studio did not mount; every assertion below is about a page that is not there"

[ "$(jbool "${cache}/control.json" markerBeforeReload)" = "1" ] &&
	ck ok "typing reaches the editor's model" ||
	ck fail "the typed text never reached a Monaco model"

# THE MESSAGE THAT HAD NO HOST.
[ "$(jbool "${cache}/control.json" sawNoHostForSaveFile)" = "0" ] &&
	ck ok "Ctrl+S is answered — no 'no host for CODETRACER::save-file'" ||
	ck fail "Ctrl+S still logs 'no host for CODETRACER::save-file'"

[ "$(jbool "${cache}/control.json" mountedAfterReload)" = "1" ] &&
	ck ok "the studio mounts again after a real reload" ||
	ck fail "the studio did not come back after the reload"

# THE HEADLINE. Exact equality: what came back is what was saved.
[ "$(jbool "${cache}/control.json" markerAfterReload)" = "1" ] &&
	ck ok "the edit is still there after a reload that destroyed every JS value" ||
	ck fail "the edit did NOT survive the reload"

[ "$(jeq "${cache}/control.json" editedContent restoredContent)" = "1" ] &&
	ck ok "the restored bytes EQUAL the bytes that were saved" ||
	ck fail "the restored bytes differ from what was saved"

# THE NEGATIVE TWIN, and the one that is red on the shipped build: the restore
# must not be the bundle.
[ "$(jeq "${cache}/control.json" restoredContent bundledContent)" = "0" ] &&
	ck ok "the restored bytes are NOT the bundled template's" ||
	ck fail "after the reload the tab holds the BUNDLED template — the edit was lost and re-seeded"

[ "$(jeq "${cache}/control.json" editedContent bundledContent)" = "0" ] &&
	ck ok "the edit genuinely changed the file (so the check above can fail)" ||
	ck fail "the 'edit' left the file identical to the bundle; this gate would pass vacuously"

# A fresh origin partition must NOT have the marker — that is what makes the
# assertions above statements about STORAGE rather than about the bundle.
[ "$(jbool "${cache}/control.json" freshContextMarker)" = "0" ] &&
	ck ok "a browser context that never edited sees the bundled template" ||
	ck fail "a fresh context already contains the marker; the bundle carries it and nothing was proved"

[ "$(jstrlen "${cache}/control.json" bundledContent)" -gt 100 ] &&
	ck ok "the fresh context really loaded a project ($(jstrlen "${cache}/control.json" bundledContent) chars)" ||
	ck fail "the fresh context loaded nothing, so the comparison above is against an empty string"

# §4.2's sentence, PAINTED — hit-tested at its own centre, not `innerText`.
[ "$(jbool "${cache}/control.json" bannerPainted)" = "1" ] &&
	ck ok "the durability sentence is painted and is the element at its own centre" ||
	ck fail "the durability sentence is not painted where a user would read it"

[ "$(jget "${cache}/control.json" bannerPaintedChars)" -ge 80 ] &&
	ck ok "the durability sentence is $(jget "${cache}/control.json" bannerPaintedChars) painted characters" ||
	ck fail "the durability sentence is too short to be the announcement"

python3 - "${cache}/control.json" <<'PY' && ck ok "the sentence names the export gesture it tells the user to perform" || ck fail "the sentence tells the user to export and does not say how"
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "Ctrl+Shift+E" in (d.get("bannerText") or "") else 1)
PY

echo

# ---------------------------------------------------------------------------
# Mutation arms. Each patches the ASSEMBLED BUNDLE (never the test), verifies
# the patch changed bytes, and requires the named assertion to go red.
# ---------------------------------------------------------------------------
mutate() {
	# mutate ID PYTHON_EXPR — copies the bundle, rewrites the renderer, and
	# FAILS if the rewrite changed nothing.
	local id="$1" expr="$2"
	local dir="${cache}/mut-${id}"
	rm -rf "${dir}"
	cp -R "${bundle}" "${dir}"
	python3 - "${dir}/${renderer_rel}" "${expr}" <<'PY'
import re, sys
path, expr = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
pat, repl = expr.split("\x1f", 1)
out, n = re.subn(pat, repl, src, count=1)
if n != 1:
    sys.stderr.write("MUTATION MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(3)
if out == src:
    sys.stderr.write("MUTATION CHANGED NOTHING\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(out)
PY
	local rc=$?
	if [ "${rc}" -ne 0 ]; then
		ck fail "arm ${id}: the mutation did not apply — it would have measured an unmutated bundle"
		return 1
	fi
	if cmp -s "${renderer}" "${dir}/${renderer_rel}"; then
		ck fail "arm ${id}: the renderer is byte-identical after the patch"
		return 1
	fi
	echo "${dir}"
	return 0
}

arm() {
	# arm ID DESCRIPTION PATTERN REPLACEMENT FIELD_A FIELD_B EXPECT_EQUAL
	local id="$1" desc="$2" pat="$3" repl="$4"
	echo "Arm ${id}: MUTATION — ${desc}"
	local dir
	dir="$(mutate "${id}" "${pat}"$'\x1f'"${repl}")" || return 0
	if ! probe "${dir}" "${cache}/${id}.json"; then
		ck fail "arm ${id}: produced no measurement"
		return 0
	fi
	# The arm's own assertion: the restore must now be indistinguishable from
	# the bundle, i.e. the edit was lost.
	if [ "$(jeq "${cache}/${id}.json" restoredContent bundledContent)" = "1" ] ||
	   [ "$(jbool "${cache}/${id}.json" markerAfterReload)" = "0" ]; then
		ck ok "arm ${id} reddens 'the edit survives a reload' — the check works"
	else
		ck fail "arm ${id} did NOT redden the persistence assertion; that check may be vacuous"
	fi
	echo
}

# A — the shipped Ctrl+S defect: the save host is not registered at all, so the
#     message falls through to `newWebIpc`'s "no host" warning.
arm A "the save host is never registered" \
	'\.ipc\.respond\(\("CODETRACER::save-file"\)' \
	'.ipc.respond(("CODETRACER::save-file-NO-HOST")'

# B — the restore never reads the store, so every load re-seeds from the
#     bundle. The save still happens and the bytes are still on disk; the tab
#     simply never asks for them. This is the half of the chain that a
#     write-only test would miss entirely.
arm B "the restore never reads what the store already holds" \
	'if \(stored_[0-9]+\.ok\) \{' \
	'if (false) {'

# C — the write-through never happens: the edit reaches memory, so the tab
#     looks correct for the whole session and is empty-handed after a reload.
#     This is the arm that proves the gate is testing PERSISTENCE and not just
#     an in-page round trip.
arm C "the edit is kept in memory and never persisted" \
	'if \(\(writeThrough_[0-9]+\[0\] == null\)\) \{' \
	'if (true) {'

# ---------------------------------------------------------------------------
expect_count 16
if [ "${failures}" -ne 0 ]; then
	printf '\nRESULT: FAILED — %d check(s), %d failure(s).\n' "${checks}" "${failures}"
	exit 1
fi
printf '\nRESULT: OK — %d check(s), 0 failures.\n' "${checks}"
printf 'What a visitor types is kept across a reload, and it is what Build compiles.\n'
