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
# THE SECOND DEFECT, AND WHY THE BANNER ASSERTIONS BECAME NOTICE ASSERTIONS
# -------------------------------------------------------------------------
# Once the sentence was true it was shown in a bespoke `<div>` appended to
# `document.body` at `position:fixed; bottom:0; z-index:2147483646` — which is
# the status bar's own strip, so the product covered its own footer on every
# first visit. `NotificationKind`, `newNotification` and the toast stack in
# `ui/status.nim` already existed and already stack ABOVE the bar, so the
# sentence moved there. HOW FAR above is computed in
# `styles/components/status_bar.styl` from the bar's height plus the stack's
# own inter-toast gap. It was a bare `38px` against a 40px bar until a user
# reported the lowest toast being clipped by the footer, and this comment
# repeated the wrong number for as long as the stylesheet did — so it names
# the derivation now, and the assertions below MEASURE the clearance instead
# of restating it.
#
# The acceptance is therefore not "a notification appears" but "the status bar
# is not covered", hit-tested at three points across the bar WHILE the notice
# is on screen — with arm D putting an equivalent overlay back to prove that
# check is not vacuous.
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

# `|| exit` MATTERS HERE. This file runs under `set -uo pipefail` with no `-e`,
# so a `cd` that failed used to be ignored and everything below — the bundle
# assembly, the probe, the fixture paths — would have been resolved against
# whatever directory the caller happened to be in. That is the vacuous-pass
# shape this gate exists to rule out, arriving through its own first line.
cd "$(dirname "$0")/../.." || exit 1
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

if [ "$(jbool "${cache}/control.json" mounted)" = "1" ]; then
	ck ok "the studio mounts on /noir"
else
	ck fail "the studio did not mount; every assertion below is about a page that is not there"
fi

if [ "$(jbool "${cache}/control.json" markerBeforeReload)" = "1" ]; then
	ck ok "typing reaches the editor's model"
else
	ck fail "the typed text never reached a Monaco model"
fi

# THE MESSAGE THAT HAD NO HOST.
if [ "$(jbool "${cache}/control.json" sawNoHostForSaveFile)" = "0" ]; then
	ck ok "Ctrl+S is answered — no 'no host for CODETRACER::save-file'"
else
	ck fail "Ctrl+S still logs 'no host for CODETRACER::save-file'"
fi

if [ "$(jbool "${cache}/control.json" mountedAfterReload)" = "1" ]; then
	ck ok "the studio mounts again after a real reload"
else
	ck fail "the studio did not come back after the reload"
fi

# ---------------------------------------------------------------------------
# THE DEBUG SESSION IN BETWEEN — the leg the data-loss report needs.
#
# Reported: "when I enter a debug sesion and hit the Stop button, the contents
# of some files become empty. What's worse is that this seems to be persisted
# even after I refresh the tab."
#
# The reload assertions below were already here and were already green, because
# nothing above them ever left Edit mode. The defect needs the mode transition:
# a layout swap orphans a Monaco widget, nothing nils `tabInfo.monacoEditor`,
# and `getValue()` on a widget whose model is gone returns '' rather than
# throwing — so the next save wrote an empty file through to OPFS.
#
# THE CONTROL FIRST. If the debug leg did not run, the reload assertions are
# measuring the old, weaker sequence and must not be read as covering this.
if [ "$(jbool "${cache}/control.json" debugLegAttempted)" = "1" ]; then
	ck ok "a debug session was entered between the edit and the reload"
else
	ck fail "the Run button was not reachable, so this run did NOT exercise the reported sequence — the reload checks below prove nothing about it. The toolbar held: $(jget "${cache}/control.json" editToolbarButtons)"
fi

if [ "$(jbool "${cache}/control.json" debugLegEnteredDebug)" = "1" ] &&
	[ "$(jbool "${cache}/control.json" debugLegReturnedToEdit)" = "1" ]; then
	ck ok "and Stop returned the workspace to Edit mode"
else
	ck fail "the Run/Stop round trip did not complete: $(jget "${cache}/control.json" debugLegError)"
fi

# THE BYTES, BEFORE THE RELOAD. This separates "lost in memory" from "lost in
# storage" — the two need different fixes and a single after-reload check
# cannot tell them apart.
if [ "$(jbool "${cache}/control.json" markerAfterStop)" = "1" ]; then
	ck ok "the editor still holds the edit after Stop, before any reload ($(jget "${cache}/control.json" contentAfterStopLength) bytes)"
else
	ck fail "after Stop the editor no longer holds the edit ($(jget "${cache}/control.json" contentAfterStopLength) bytes, $(jget "${cache}/control.json" emptyModelsAfterStop) empty model(s)) — the loss is in memory, not in storage"
fi

# THE HEADLINE. Exact equality: what came back is what was saved — now across a
# Run and a Stop as well as a reload.
if [ "$(jbool "${cache}/control.json" markerAfterReload)" = "1" ]; then
	ck ok "the edit is still there after a reload that destroyed every JS value"
else
	ck fail "the edit did NOT survive the reload"
fi

if [ "$(jeq "${cache}/control.json" editedContent restoredContent)" = "1" ]; then
	ck ok "the restored bytes EQUAL the bytes that were saved"
else
	ck fail "the restored bytes differ from what was saved"
fi

# THE NEGATIVE TWIN, and the one that is red on the shipped build: the restore
# must not be the bundle.
if [ "$(jeq "${cache}/control.json" restoredContent bundledContent)" = "0" ]; then
	ck ok "the restored bytes are NOT the bundled template's"
else
	ck fail "after the reload the tab holds the BUNDLED template — the edit was lost and re-seeded"
fi

if [ "$(jeq "${cache}/control.json" editedContent bundledContent)" = "0" ]; then
	ck ok "the edit genuinely changed the file (so the check above can fail)"
else
	ck fail "the 'edit' left the file identical to the bundle; this gate would pass vacuously"
fi

# A fresh origin partition must NOT have the marker — that is what makes the
# assertions above statements about STORAGE rather than about the bundle.
if [ "$(jbool "${cache}/control.json" freshContextMarker)" = "0" ]; then
	ck ok "a browser context that never edited sees the bundled template"
else
	ck fail "a fresh context already contains the marker; the bundle carries it and nothing was proved"
fi

if [ "$(jstrlen "${cache}/control.json" bundledContent)" -gt 100 ]; then
	ck ok "the fresh context really loaded a project ($(jstrlen "${cache}/control.json" bundledContent) chars)"
else
	ck fail "the fresh context loaded nothing, so the comparison above is against an empty string"
fi

# ---------------------------------------------------------------------------
# §4.2's sentence, DELIVERED THROUGH THE NOTIFICATION SYSTEM — and the status
# bar left alone.
#
# It used to be a bespoke `<div id="codetracer-durability">` appended to
# `document.body` at `position:fixed; bottom:0; z-index:2147483646`. That is
# exactly where the status bar is, so on every load in the two degraded storage
# rows — which is every first visit, because browsers deny persistence to an
# origin a visitor has just arrived at — the product covered its own footer
# with a strip of text. The sentence was right; the surface was a second
# notification system with a worse z-index.
# ---------------------------------------------------------------------------

# THE SURFACE IS GONE. Asserted directly, because "a notification appears"
# would still be true of a build that raised the notification AND kept the
# banner, which would leave the bar just as covered.
if [ "$(jbool "${cache}/control.json" legacyBannerPresent)" = "0" ]; then
	ck ok "the bespoke bottom banner is gone from the document"
else
	ck fail "'#codetracer-durability' is still in the page — the covering surface was not removed"
fi

if [ "$(jbool "${cache}/control.json" noticeFound)" = "1" ]; then
	ck ok "the durability sentence is raised as a Notification in the status bar's stack"
else
	ck fail "no durability notification in '#active-notifications' — the sentence reaches no one"
fi

if [ "$(jbool "${cache}/control.json" noticePainted)" = "1" ]; then
	ck ok "the notification is painted and is the element at its own centre"
else
	ck fail "the notification is laid out but is not what the browser finds at its own centre"
fi

if [ "$(jget "${cache}/control.json" noticeChars)" -ge 80 ]; then
	ck ok "the sentence is $(jget "${cache}/control.json" noticeChars) painted characters"
else
	ck fail "the sentence is too short to be the announcement"
fi

# THE ACCEPTANCE. Hit-tested at three points across the bar, WHILE the notice
# is on screen.
if [ "$(jbool "${cache}/control.json" statusBarFound)" = "1" ]; then
	ck ok "the status bar is in the document, so the check below is about something"
else
	ck fail "'#status-base' is absent; the obscuring check would pass vacuously"
fi

if [ "$(jget "${cache}/control.json" statusBarProbePoints)" -eq 3 ]; then
	ck ok "all three probe points across the bar are inside the viewport"
else
	ck fail "only $(jget "${cache}/control.json" statusBarProbePoints) of 3 probe points were testable"
fi

if [ "$(jbool "${cache}/control.json" statusBarUnobscured)" = "1" ]; then
	ck ok "the status bar is unobscured while the notice is showing"
else
	ck fail "the status bar is covered by $(jget "${cache}/control.json" statusBarCoveredBy)"
fi

# ---------------------------------------------------------------------------
# ONCE, AND CLEAR OF THE BAR
# ---------------------------------------------------------------------------
#
# Both reported from the live site against the same notice, and neither was
# visible to any assertion above:
#
#   "I also see 3 duplicate notifications ... The one at the bottom is
#    partially obscured by the status bar (it needs to have the same margin
#    that is used in between the notifications, separating it from the status
#    bar)"
#
# `noticeFound` is produced by `items.find(...)` and answers "at least one",
# so three copies satisfied it. `statusBarUnobscured` asks whether a toast
# covers the BAR; this is the bar covering a TOAST, which is the state a fully
# painted bar is indistinguishable from. And `noticePainted` hit-tests the
# toast's centre, which a toast clipped at its bottom edge still owns. Three
# green checks, two live defects.
#
# THE COUNT IS A DELTA, NOT A READING. `statsBefore`/`statsAfter` bracket the
# load around `ui/status.nim`'s `notificationsDelivered`, so an arm in which
# nothing was delivered scores 0 rather than a plausible-looking 1 — a check
# that passes when nothing renders is worse than no check.
delivered_delta() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
before, after = d.get("statsBefore"), d.get("statsAfter")
if not isinstance(after, dict) or after.get("delivered") is None:
    print("nohook"); raise SystemExit
b = 0 if not isinstance(before, dict) or before.get("delivered") is None \
      else before["delivered"]
print(after["delivered"] - b)
' "$1"
}

control_delta="$(delivered_delta "${cache}/control.json")"
if [ "${control_delta}" = "nohook" ]; then
	ck fail "window.__ctStatusRenderStats().delivered is missing — the count cannot be measured"
elif [ "${control_delta}" -eq 1 ]; then
	ck ok "exactly 1 notification was delivered to the status bar for this page load"
else
	ck fail "${control_delta} notifications were delivered for one page load (want exactly 1)"
fi

if [ "$(jget "${cache}/control.json" noticeCount)" -eq 1 ]; then
	ck ok "exactly 1 durability notice is on screen"
else
	ck fail "$(jget "${cache}/control.json" noticeCount) copies of the durability notice are on screen (want 1)"
fi

# THE MARGIN, AS A RELATION BETWEEN TWO MEASURED VALUES. `noticeRowGap` is the
# stack's own inter-notification spacing as the browser computed it, and
# `noticeGapToStatusBar` is the measured distance from the lowest toast's
# bottom edge to the top of `#status-base`. Asserting they are EQUAL is the
# user's request stated exactly ("the same margin that is used in between the
# notifications"). Naming the pixel value here instead would keep passing after
# the spacing legitimately changed, and would have to be edited by the same
# commit that changed it — a test that agrees with whatever it is told.
gap_matches() {
	# shellcheck disable=SC2016 # prose about `getBoundingClientRect`, not an expansion
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
want, got = d.get("noticeRowGap"), d.get("noticeGapToStatusBar")
if want is None or got is None:
    print("unmeasured"); raise SystemExit
# A tolerance, because both numbers come from `getBoundingClientRect` on a
# fractionally scaled layout; half a pixel cannot hide a 0.5rem discrepancy.
print("same" if abs(float(want) - float(got)) <= 0.5 else "differ")
print(want); print(got)
' "$1"
}

# Read with `read`, not `mapfile`: this file runs on the macOS bash 3.2 that
# `/usr/bin/env bash` finds by default on a developer laptop, and `mapfile` is
# a bash 4 builtin. An unrecognised builtin under `set -uo pipefail` without
# `-e` fails the line and leaves the variable unset, which would report every
# gap as unmeasured — a red arm with the wrong explanation attached.
gap_verdict=""
gap_want=""
gap_got=""
{
	read -r gap_verdict
	read -r gap_want
	read -r gap_got
} < <(gap_matches "${cache}/control.json")

case "${gap_verdict}" in
same)
	ck ok "the lowest notice clears the status bar by ${gap_got}px, the same as the ${gap_want}px gap between notices"
	;;
unmeasured)
	ck fail "the notice/status-bar clearance could not be measured — nothing was on screen to measure"
	;;
*)
	ck fail "the lowest notice clears the status bar by ${gap_got}px but notices are spaced ${gap_want}px apart"
	;;
esac

# AND THE COMPLAINT ITSELF. Arithmetic that says the toast clears the bar is
# still only arithmetic; this is the pixel two above the toast's bottom edge,
# asked who owns it.
if [ "$(jbool "${cache}/control.json" noticeLowestBottomCovered)" = "0" ]; then
	ck ok "the bottom edge of the lowest notice is not covered"
else
	ck fail "the bottom of the lowest notice is covered by $(jget "${cache}/control.json" noticeLowestBottomHit)"
fi

# DISMISSIBLE, AND DISMISSED.
if [ "$(jbool "${cache}/control.json" noticeHasDismiss)" = "1" ]; then
	ck ok "the notification carries a dismiss control"
else
	ck fail "the notification cannot be dismissed — that is a banner by another name"
fi

if [ "$(jbool "${cache}/control.json" noticeDismissed)" = "1" ]; then
	ck ok "clicking dismiss actually removes it"
else
	ck fail "the dismiss control is present and does not dismiss"
fi

# THE ACTION, beside the chord.
if [ "$(jbool "${cache}/control.json" noticeHasExport)" = "1" ]; then
	ck ok "the notification offers Export as an action, not only as a chord"
else
	ck fail "the notification tells the user to export and offers no button"
fi

if python3 - "${cache}/control.json" <<'PY'; then
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "Ctrl+Shift+E" in (d.get("noticeText") or "") else 1)
PY
	ck ok "the sentence names the export gesture it tells the user to perform"
else
	ck fail "the sentence tells the user to export and does not say how"
fi

if [ "$(jget "${cache}/control.json" noticeClass)" != "null" ] &&
	python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if "warning" in (d.get("noticeClass") or "") else 1)' "${cache}/control.json"; then
	ck ok "it is raised at NotificationWarning — the level the product already has for this"
else
	ck fail "the notification is not a warning; class was $(jget "${cache}/control.json" noticeClass)"
fi

# ---------------------------------------------------------------------------
# THE WORDING. Accurate, and no longer opening on a refusal.
#
# What the message means: `navigator.storage.persist()` was denied, so the
# origin is best-effort rather than persistent. Best-effort data is REAL — it
# is in OPFS, on disk, and survives reloads, crashes and restarts — but the
# browser may clear it without prompting when the device runs low. A first
# visit is normally denied; persistence is granted on engagement. So the old
# opening clause ("This browser refused to mark your work as persistent")
# reported a normal, usually temporary condition as though it were the state of
# the user's work, to a visitor who had invested nothing.
#
# The risk is NOT softened away: both halves are asserted.
# ---------------------------------------------------------------------------
if python3 - "${cache}/control.json" <<'PY'; then
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if (d.get("noticeText") or "").startswith("Your work is saved in this browser") else 1)
PY
	ck ok "the sentence leads with what is true — the work IS saved"
else
	ck fail "the sentence does not open by saying the work is saved"
fi

if python3 - "${cache}/control.json" <<'PY'; then
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "refused" not in (d.get("noticeText") or "") else 1)
PY
	ck ok "it does not open on a browser refusal"
else
	ck fail "the sentence still reports a refusal as the headline"
fi

if python3 - "${cache}/control.json" <<'PY'; then
import json,sys
d=json.load(open(sys.argv[1]))
t=(d.get("noticeText") or "")
sys.exit(0 if ("storage" in t and "export the project" in t) else 1)
PY
	ck ok "the eviction risk and the export mitigation are both still stated"
else
	ck fail "the wording was softened into dishonesty — the real risk is no longer named"
fi

# ---------------------------------------------------------------------------
# ONCE PER BROWSER SESSION — and the twin that stops "once" from meaning
# "never again".
# ---------------------------------------------------------------------------
if [ "$(jbool "${cache}/control.json" noticeAfterReload)" = "0" ]; then
	ck ok "a reload in the same tab is not re-nagged"
else
	ck fail "the notice returns on every load; the reader already read it a moment ago"
fi

if [ "$(jbool "${cache}/control.json" noticeInFreshContext)" = "1" ]; then
	ck ok "a new browser session IS told — the message is suppressed, not lost"
else
	ck fail "a fresh context sees no notice at all; the message has been suppressed into silence"
fi

echo

# ---------------------------------------------------------------------------
# Mutation arms. Each patches the ASSEMBLED BUNDLE (never the test), verifies
# the patch changed bytes, and requires the named assertion to go red.
# ---------------------------------------------------------------------------
# THE DIRECTORY COMES BACK IN A VARIABLE, NOT ON STDOUT, AND THAT IS A FIX.
#
# `mutate` used to `echo "${dir}"` and be called as `dir="$(mutate ...)"`. Every
# `ck` it raised on a failure path therefore went into the COMMAND SUBSTITUTION
# instead of the transcript, and `checks`/`failures` were incremented in a
# subshell that then exited — so a mutation that did not apply printed nothing,
# counted nothing, and skipped its arm in silence.
#
# MEASURED: a run in which arm F's bundle had gone missing emitted six `Arm`
# headers and five verdicts. The only trace was `expect_count` reporting 39 where
# 40 were written — a discrepancy whose obvious "fix" is to lower the number,
# which would have cemented the silence. An arm that cannot report its own
# failure is the exact shape this gate exists to rule out.
mutated_dir=""

mutate() {
	# mutate ID PYTHON_EXPR — copies the bundle, rewrites the renderer, and
	# FAILS if the rewrite changed nothing. Sets `mutated_dir` on success.
	local id="$1" expr="$2"
	local dir="${cache}/mut-${id}"
	mutated_dir=""
	rm -rf "${dir}"
	if ! cp -R "${bundle}" "${dir}"; then
		# Checked, because it was not: the copy failing let the rewrite below
		# run against a path that did not exist, and the arm died in a Python
		# traceback on stderr with no assertion either way.
		ck fail "arm ${id}: the bundle could not be copied from ${bundle}, so the arm measured nothing"
		return 1
	fi
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
	mutated_dir="${dir}"
	return 0
}

arm() {
	# arm ID DESCRIPTION PATTERN REPLACEMENT TARGET PY_IS_RED
	#
	# EACH ARM NAMES THE ASSERTION IT MUST REDDEN, and is judged on THAT
	# assertion rather than on a shared one. An arm scored against a check it
	# was not written for is an arm that can pass while the check it was meant
	# to defend stays vacuous.
	local id="$1" desc="$2" pat="$3" repl="$4" target="$5" pyred="$6"
	echo "Arm ${id}: MUTATION — ${desc}"
	# NOT `$(mutate ...)`. See the note above `mutated_dir`: a command
	# substitution swallows the assertions the failure paths raise.
	mutate "${id}" "${pat}"$'\x1f'"${repl}" || return 0
	local dir="${mutated_dir}"
	if ! probe "${dir}" "${cache}/${id}.json"; then
		ck fail "arm ${id}: produced no measurement"
		return 0
	fi
	{
		printf '%s\n' 'import json,sys'
		printf '%s\n' 'd=json.load(open(sys.argv[1]))'
		printf 'sys.exit(0 if (%s) else 1)\n' "${pyred}"
	} >"${cache}/${id}.py"
	if python3 "${cache}/${id}.py" "${cache}/${id}.json"; then
		ck ok "arm ${id} reddens '${target}' — the check works"
	else
		ck fail "arm ${id} did NOT redden '${target}'; that check may be vacuous"
	fi
	echo
}

edit_is_lost='(d.get("restoredContent") or "")==(d.get("bundledContent") or "") or not d.get("markerAfterReload")'

# A — the shipped Ctrl+S defect: the save host is not registered at all, so the
#     message falls through to `newWebIpc`'s "no host" warning.
arm A "the save host is never registered" \
	'\.ipc\.respond\(\("CODETRACER::save-file"\)' \
	'.ipc.respond(("CODETRACER::save-file-NO-HOST")' \
	"the edit survives a reload" "${edit_is_lost}"

# B — the restore never reads the store, so every load re-seeds from the
#     bundle. The save still happens and the bytes are still on disk; the tab
#     simply never asks for them. This is the half of the chain that a
#     write-only test would miss entirely.
arm B "the restore never reads what the store already holds" \
	'if \(stored_[0-9]+\.ok\) \{' \
	'if (false) {' \
	"the edit survives a reload" "${edit_is_lost}"

# C — the write-through never happens: the edit reaches memory, so the tab
#     looks correct for the whole session and is empty-handed after a reload.
#     This is the arm that proves the gate is testing PERSISTENCE and not just
#     an in-page round trip.
arm C "the edit is kept in memory and never persisted" \
	'if \(\(writeThrough_[0-9]+\[0\] == null\)\) \{' \
	'if (true) {' \
	"the edit survives a reload" "${edit_is_lost}"

# D — THE DEFECT THE USER REPORTED, PUT BACK. A fixed strip pinned to the
#     bottom of the viewport above everything, exactly as the removed banner
#     was. It uses a different id on purpose: the arm must redden the HIT TEST,
#     not the id check beside it, or "the status bar is unobscured" would be
#     resting on "the old element is absent" and would not be an independent
#     assertion at all.
#
#     An interval rather than a one-shot append, so the overlay is present
#     whenever the probe looks, independently of mount timing.
arm D "a fixed bottom-0 overlay is painted over the footer again" \
	'^' \
	"(function(){var f=function(){var d=document.getElementById('ct-mut-banner');if(!d){d=document.createElement('div');d.id='ct-mut-banner';d.textContent='mutation overlay';d.setAttribute('style','position:fixed;left:0;right:0;bottom:0;height:31px;z-index:2147483646;background:rgb(74,45,18);color:rgb(255,217,160)');document.body.appendChild(d);}};setInterval(function(){try{if(document.body){f();}}catch(e){}},200);})();" \
	"the status bar is unobscured" 'not d.get("statusBarUnobscured")'

# E — the sentence is composed, and never handed to the notification system.
#     The shape of the original defect one step on: a correct value, computed
#     on every boot, that no view reads.
arm E "the notice is never raised into the status bar" \
	'awaitStatusBarThenRaise__[A-Za-z0-9_]+\(40\);' \
	'void 0;' \
	"the sentence is raised as a Notification" 'not d.get("noticeFound")'

# F — the wording reverts to opening on the browser's refusal. Everything else
#     about the delivery stays correct, which is what makes this an assertion
#     about the WORDING rather than about the plumbing.
arm F "the sentence opens on the refusal again" \
	'Your work is saved in this browser and survives reloads, crashes and restarts\. This browser has not marked it as protected yet, so it can be cleared' \
	'This browser refused to mark your work as persistent, so it can be cleared' \
	"the sentence leads with what is true" \
	'not (d.get("noticeText") or "").startswith("Your work is saved in this browser")'

# ---------------------------------------------------------------------------
# 37 before the debug-session leg; +3 for the control that says whether the leg
# ran at all, the Run/Stop round trip, and the bytes read after Stop and before
# any reload. Moved deliberately and in the same commit as the checks that moved
# it — this tally is what turns an arm that aborted, or a probe that produced no
# JSON, into a count mismatch rather than a clean summary.
#
# 40 IS THE NUMBER OF ASSERTIONS WRITTEN, NOT THE NUMBER A BROKEN RUN EMITS. A
# run whose arm cannot copy the bundle used to emit 39, and the tempting repair
# was to write 39 here. That would have made the tally agree with the breakage
# instead of detecting it, which is what the tally is for. If this line and the
# run disagree, find the assertion that did not run — do not lower the number.
expect_count 40
if [ "${failures}" -ne 0 ]; then
	printf '\nRESULT: FAILED — %d check(s), %d failure(s).\n' "${checks}" "${failures}"
	exit 1
fi
printf '\nRESULT: OK — %d check(s), 0 failures.\n' "${checks}"
printf 'What a visitor types is kept across a reload, and it is what Build compiles.\n'
