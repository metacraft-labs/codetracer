#!/usr/bin/env bash
#
# calltrace-row-box-in-browser.sh — every Call Trace row is exactly its row
# box, 1.5625em, at every zoom, whatever the row shows.
#
# WHAT THIS ASSERTS
# -----------------
# In a real browser, over the REAL view (`renderCalltracePanel[WebRenderer,
# Element]`), the REAL compiled stylesheet (`default_dark_theme_electron.styl`,
# the entry point the desktop ships: the palette, then `codetracer.styl`) and
# the REAL fonts (SpaceMono and SpaceGrotesk, loaded from `libs/codetracer-
# design-system`), at root font sizes 16, 20, 13 and 12 px set on
# `documentElement.style.fontSize` as the desktop's zoom sets them:
#
#   * every row's toggle is 1.5625 x root — the row box `calltrace.styl`
#     declares (`.toggle-call` `height: 1.5625em`);
#   * every row's height equals that box, rows with a return value included;
#   * the advance from each row's top to the next row's top equals that box,
#     for every adjacent pair;
#   * in every row with a return value, the arrow and the value sit on the
#     call name's baseline;
#
# all within 1/64 px, the browser's layout unit.
#
# THE DEFECT IT PINS (codetracer-pm issue
# 2026-10-18-electron-calltrace-row-advance-exceeds-its-own-row-box.md):
# `.return` sets an arrow in SpaceGrotesk and a value in SpaceMono on one
# baseline-aligned line, and the two faces' ascents and descents disagree, so
# that line box was taller than `line-height` — and taller than the toggle.
# Every row that showed a return value grew ~0.8 px (25.796875 px at a 16 px
# root, against 25), the others did not, and the pane's mean advance came out
# ~25.28 px, varying with the data. The fix in `calltrace.styl` sets
# `.return`'s strut in SpaceMono and gives the SpaceGrotesk arrow
# `line-height: 1`, so the line holds one full-height face and stays on one
# baseline.
#
# WHY A BROWSER, THE SHIPPED STYLESHEET AND THE SHIPPED FONTS. The height is
# decided by font metrics in a layout. jsdom has no layout, a restated
# stylesheet has no `code_font.styl`, and a fallback face has other metrics.
# So the font URLs in the compiled sheet are rewritten to absolute `file://`
# paths (the sheet is compiled for a deeper directory than this page's), and
# an INSTRUMENT CONTROL refuses the reading unless both faces are LOADED and
# the two halves of a return value are set in them. A second control refuses
# a fixture that has no row with a return value, which would pass vacuously.
#
# MUTATION ARMS, each an edit of the compiled sheet, so this gate is shown to
# detect the defect it names on every run:
#   S   strips the whole fix (the stylesheet as it was): the row-box and
#       advance assertions redden for exactly the rows with a return value;
#   S1  strips only `.return`'s SpaceMono strut, and
#   S2  only the arrow's `line-height: 1`: each reddens them the same way,
#       so each declaration is needed;
#   V   replaces the fix with `vertical-align: top` on the arrow and the
#       value, which holds the height but lifts the arrow off the baseline:
#       the baseline assertion reddens for exactly those rows.
#
# Usage:  bash ci/test/calltrace-row-box-in-browser.sh [screenshot.png]
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

shot="${1:-}"
cache="$(ct_nim_cache_root "${repo_root}")/calltrace-row-box-in-browser"
rm -rf "${cache}"
mkdir -p "${cache}"

checks=0
failures=0

ck() {
	local verdict="$1"
	shift
	checks=$((checks + 1))
	if [ "${verdict}" = ok ]; then
		echo "  [OK]     $*"
	else
		echo "  [FAILED] $*"
		failures=$((failures + 1))
	fi
}
note() { echo "      $*"; }

for tool in node python3 nim; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "calltrace-row-box-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done

echo "=== every call-trace row is its row box, in a browser ==="
echo

# ---------------------------------------------------------------------------
# Build the probe — the shipped web arm's defines (see
# `watch-expressions-in-browser.sh` for why `-d:ctRenderer` is load-bearing).
# ---------------------------------------------------------------------------
if ! nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
	--hints:off --warnings:off --path:src --path:src/frontend/viewmodel \
	-o:"${cache}/probe.js" ci/test/calltrace_row_box_browser_probe.nim \
	>"${cache}/build.log" 2>&1 || [ ! -s "${cache}/probe.js" ]; then
	echo "  the probe did not build; see ${cache}/build.log" >&2
	tail -20 "${cache}/build.log" >&2
	exit 2
fi
note "built ${cache}/probe.js ($(wc -c <"${cache}/probe.js" | tr -d ' ') bytes)"

# ---------------------------------------------------------------------------
# The real stylesheet, with its fonts made loadable.
# ---------------------------------------------------------------------------
stylus="$(command -v stylus || true)"
[ -n "${stylus}" ] || stylus="$(node -e 'console.log(require.resolve("stylus/bin/stylus"))' 2>/dev/null || true)"
if [ -z "${stylus}" ]; then
	echo "  stylus is not available; run inside the dev shell (LOUD SKIP, not a pass)" >&2
	exit 2
fi
"${stylus}" --include src/frontend/styles --include src/frontend/styles/generated \
	<src/frontend/styles/default_dark_theme_electron.styl >"${cache}/compiled.css" 2>"${cache}/styl.log"
if [ ! -s "${cache}/compiled.css" ]; then
	echo "  the stylesheet did not compile; see ${cache}/styl.log" >&2
	exit 2
fi

# The compiled sheet names its fonts relative to where the build puts it
# (`../../../../libs/...`), not to this page. Rewrite those URLs to absolute
# `file://` paths, and refuse to go on unless every SpaceMono / SpaceGrotesk
# source resolves to a file that exists — a missing submodule would otherwise
# be a fallback face, and a reading about the fallback.
if ! python3 - "${cache}/compiled.css" "${cache}/codetracer.css" "${repo_root}" <<'PY'; then
import re, os, sys
src, dst, root = sys.argv[1], sys.argv[2], sys.argv[3]
css = open(src, encoding="utf-8").read()
css = css.replace('url("../../../../libs/', 'url("file://' + root + '/libs/')
css = css.replace('url("../../public/', 'url("file://' + root + '/src/public/')
faces = re.findall(r'@font-face\s*\{([^}]*)\}', css)
need = {"SpaceMono": 0, "SpaceGrotesk": 0}
for body in faces:
    fam = re.search(r'font-family:\s*["\']?([^"\';]+)', body)
    if not fam or fam.group(1).strip() not in need:
        continue
    for u in re.findall(r'url\("file://([^"]+)"\)', body):
        if not os.path.isfile(u):
            sys.exit("font source missing: " + u)
        need[fam.group(1).strip()] += 1
missing = [k for k, v in need.items() if v == 0]
if missing:
    sys.exit("no loadable @font-face source for: " + ", ".join(missing))
open(dst, "w", encoding="utf-8").write(css)
PY
	echo "  the stylesheet's fonts are not loadable from this checkout (submodule libs/codetracer-design-system?)" >&2
	exit 2
fi

cp ci/test/calltrace-row-box-probe/index.html "${cache}/index.html"
cp ci/test/calltrace-row-box-probe/run.mjs "${cache}/run.mjs"

if [ -z "${CT_CHROME:-}" ]; then
	CT_CHROME="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
		-path '*/Chromium.app/Contents/MacOS/Chromium' -type f 2>/dev/null | head -1)"
	if [ -z "${CT_CHROME}" ]; then
		CT_CHROME="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
			-name 'chrome' -type f 2>/dev/null | head -1)"
	fi
fi
if [ -z "${CT_CHROME}" ] || [ ! -x "${CT_CHROME}" ]; then
	echo "  no Chromium found; run inside the dev shell (LOUD SKIP, not a pass)" >&2
	exit 2
fi
export CT_CHROME

# ESM IGNORES NODE_PATH: `import ... from 'playwright'` resolves by walking
# `node_modules` upward from the importing FILE.
nm="$(node -e 'console.log(require.resolve("playwright").replace(/\/playwright\/index.js$/,""))' 2>/dev/null)"
if [ -z "${nm}" ] || [ ! -d "${nm}" ]; then
	echo "  playwright is not resolvable; run inside the dev shell (LOUD SKIP)" >&2
	exit 2
fi
ln -sfn "${nm}" "${cache}/node_modules"

run_probe() {
	local dir="$1" out="$2" png="${3:-}"
	node "${dir}/run.mjs" "file://${dir}/index.html" "${png}" >"${out}" 2>&1
	grep -q '^PROBE_JSON=' "${out}"
}

# One reader for the control and the arm: it prints `ok|no<TAB>message`
# lines, which `grade` turns into counted checks. `python3` rather than `jq`
# for the arithmetic over nested rows.
analyse() {
	python3 - "$1" "$2" "${3:-}" <<-'PY'
		import json, sys
		path, mode = sys.argv[1], sys.argv[2]
		blob = ""
		for line in open(path, encoding="utf-8", errors="replace"):
		    if line.startswith("PROBE_JSON="):
		        blob = line[len("PROBE_JSON="):]
		d = json.loads(blob)
		LU = 1.0 / 64.0   # Chromium's LayoutUnit
		EXPECTED_ROWS = 40
		def out(ok, msg):
		    print(("ok" if ok else "no") + "\t" + msg)
		def fmt(x):
		    return f"{x:.6f}".rstrip("0").rstrip(".")
		arm = sys.argv[3] if len(sys.argv) > 3 else ""
		def off_baseline(rs):
		    return [r for r in rs
		            if r["nameBaseline"] is None or r["arrowBaseline"] is None
		            or r["valueBaseline"] is None
		            or abs(r["arrowBaseline"] - r["nameBaseline"]) > LU
		            or abs(r["valueBaseline"] - r["nameBaseline"]) > LU]

		# ---- instrument controls ------------------------------------------
		loaded = {f["family"] for f in d["fonts"] if f["status"] == "loaded"}
		for fam in ("SpaceMono", "SpaceGrotesk"):
		    out(fam in loaded, f"instrument: the {fam} face is LOADED in the page "
		        f"(loaded: {', '.join(sorted(loaded)) or 'none'})")
		faces = d.get("returnFaces") or {}
		out(faces.get("arrow", "").startswith("SpaceGrotesk")
		    and faces.get("value", "").startswith("SpaceMono"),
		    "instrument: a return value's arrow is set in SpaceGrotesk and its "
		    f"value in SpaceMono (arrow: {faces.get('arrow')}, value: {faces.get('value')})")
		out(not d["pageErrors"], f"zero uncaught page errors ({len(d['pageErrors'])})")

		for size in d["sizes"]:
		    root, rows = size["root"], size["rows"]
		    box = 1.5625 * root
		    tag = f"{root}px root, box {fmt(box)} px"
		    ret = [r for r in rows if r["returnText"]]
		    plain = [r for r in rows if not r["returnText"]]
		    if mode == "control" or root == 16:
		        out(len(rows) == EXPECTED_ROWS and len(ret) > 0 and len(plain) > 0
		            and any(r["selected"] and r["returnText"] for r in rows)
		            and any(r["args"] and r["returnText"] for r in rows)
		            and any(not r["args"] and r["returnText"] for r in rows),
		            f"{tag}: fixture holds {len(rows)} rows, {len(ret)} with a return "
		            f"value (with and without arguments, one selected), {len(plain)} without")
		    if len(rows) < 2:
		        continue
		    heights_off = [(i, r) for i, r in enumerate(rows) if abs(r["height"] - box) > LU]
		    adv = [rows[i + 1]["top"] - rows[i]["top"] for i in range(len(rows) - 1)]
		    adv_off = [i for i, a in enumerate(adv) if abs(a - box) > LU]
		    mean_adv = (rows[-1]["top"] - rows[0]["top"]) / (len(rows) - 1)
		    if mode == "control":
		        toggles = {fmt(r["toggle"]) for r in rows}
		        out(all(abs(r["toggle"] - box) <= LU for r in rows),
		            f"{tag}: every toggle is the row box (toggle heights: {', '.join(sorted(toggles))})")
		        worst = max(rows, key=lambda r: abs(r["height"] - box))
		        out(not heights_off,
		            f"{tag}: every row's height is the box — {len(heights_off)} of {len(rows)} "
		            f"are not; worst {fmt(worst['height'])} px "
		            f"(return value {worst['returnText']!r})")
		        out(not adv_off,
		            f"{tag}: every row-to-row advance is the box — {len(adv_off)} of {len(adv)} "
		            f"are not; mean advance {fmt(mean_adv)} px")
		        base_off = off_baseline(ret)
		        out(not base_off and len(ret) > 0,
		            f"{tag}: in every row with a return value the arrow and the value sit on "
		            f"the call name's baseline — {len(base_off)} of {len(ret)} do not"
		            + (f"; e.g. name {fmt(base_off[0]['nameBaseline'])}, arrow "
		               f"{fmt(base_off[0]['arrowBaseline'])}, value "
		               f"{fmt(base_off[0]['valueBaseline'])} px" if base_off else ""))
		    elif mode == "arm-baseline" and root == 16:
		        # Arm V: the height holds, and the baseline assertion is what
		        # must redden — for exactly the rows with a return value.
		        base_off = off_baseline(ret)
		        out(not heights_off and not adv_off,
		            f"{arm}, {tag}: the rows are still the box ({len(heights_off)} are not)")
		        out(len(base_off) == len(ret) > 0,
		            f"{arm}, {tag}: the baseline assertion reddens — {len(base_off)} of "
		            f"{len(ret)} rows with a return value are off the name's baseline"
		            + (f" (arrow {fmt(base_off[0]['arrowBaseline'])} against "
		               f"{fmt(base_off[0]['nameBaseline'])} px)" if base_off else ""))
		    elif mode == "arm" and root == 16:
		        # The arm must redden the assertion for the reason the issue
		        # gives, and ONLY for it: the tall rows are exactly the rows
		        # with a return value, and the rows without one stay the box.
		        off_idx = {i for i, _ in heights_off}
		        ret_idx = {i for i, r in enumerate(rows) if r["returnText"]}
		        tall = sorted({fmt(r["height"]) for _, r in heights_off})
		        out(bool(heights_off) and off_idx == ret_idx
		            and all(r["height"] > box for _, r in heights_off),
		            f"{arm}, {tag}: the row-box assertion reddens — "
		            f"{len(heights_off)} rows taller than the box ({', '.join(tall) or 'none'} px), "
		            f"and they are exactly the {len(ret_idx)} rows with a return value")
		        out(all(abs(r["height"] - box) <= LU for r in plain),
		            f"{arm}, {tag}: the rows without a return value are still the box "
		            "(the arm edits the return value's rules, not the layout)")
		        out(bool(adv_off) and abs(mean_adv - box) > LU,
		            f"{arm}, {tag}: and the advance assertion reddens too — mean advance "
		            f"{fmt(mean_adv)} px against the {fmt(box)} px box")
	PY
}

grade() {
	local file="$1" mode="$2" arm="${3:-}" verdict msg lines
	if ! lines="$(analyse "${file}" "${mode}" "${arm}" 2>&1)"; then
		ck no "the probe's report could not be read: ${lines}"
		return
	fi
	while IFS=$'\t' read -r verdict msg; do
		[ -n "${verdict}" ] || continue
		ck "${verdict}" "${msg}"
	done <<<"${lines}"
}

# ---------------------------------------------------------------------------
echo "The control: the shipped stylesheet"
# ---------------------------------------------------------------------------
control="${cache}/control.out"
if ! run_probe "${cache}" "${control}" "${shot}"; then
	echo "  the probe did not complete; see ${control}" >&2
	tail -25 "${control}" >&2
	exit 2
fi
note "summary line: $(sed -n 's/^PROBE_JSON=.*"summary":"\([^"]*\)".*/\1/p' "${control}")"
grade "${control}" control
[ -n "${shot}" ] && note "screenshot: ${shot}"
echo

# ---------------------------------------------------------------------------
# Mutation arms: the compiled sheet with the fix edited out. Each edit must
# match exactly once, or the arm would grade the control.
# ---------------------------------------------------------------------------
run_arm() {
	local name="$1" mode="$2" what="$3" dir="${cache}/arm-$1"
	echo "Mutation arm ${name}: ${what}"
	mkdir -p "${dir}"
	cp "${cache}/index.html" "${cache}/run.mjs" "${cache}/probe.js" "${dir}/"
	ln -sfn "${nm}" "${dir}/node_modules"
	local why
	if ! why="$(
		python3 - "${name}" "${cache}/codetracer.css" "${dir}/codetracer.css" 2>&1 <<'PY'
import re, sys
arm, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
css = open(src, encoding="utf-8").read()
# The compiled form of `calltrace.styl`'s fix: the strut block and the
# arrow block, each with exactly these declarations.
STRUT = re.compile(r'\.calltrace-view \.return\s*\{\s*font-family:\s*"SpaceMono";?\s*\}')
ARROW = re.compile(r'(\.calltrace-view \.return-arrow\s*\{\s*font-family:\s*"SpaceGrotesk",\s*sans-serif;)'
                   r'\s*line-height:\s*1;?(\s*\})')
def sub(pat, repl):
    global css
    css, n = pat.subn(repl, css)
    if n != 1:
        sys.exit(f"arm {arm}: expected the fix rule /{pat.pattern[:48]}.../ exactly once, found {n}")
if arm in ("S", "S1", "V"):
    sub(STRUT, "")
if arm in ("S", "S2", "V"):
    sub(ARROW, r"\1\2")
if arm == "V":
    css += ("\n.calltrace-view .return-arrow,\n.calltrace-view .return-text {\n"
            "  vertical-align: top;\n}\n")
open(dst, "w", encoding="utf-8").write(css)
PY
	)"; then
		ck no "arm ${name}: the fix is not in the compiled stylesheet as expected: ${why}"
		echo
		return
	fi
	local out="${cache}/arm-${name}.out"
	if run_probe "${dir}" "${out}"; then
		grade "${out}" "${mode}" "arm ${name}"
	else
		ck no "arm ${name}: the probe did not complete; see ${out}"
	fi
	echo
}

run_arm S arm "the whole fix stripped (the stylesheet as it was)"
run_arm S1 arm "only .return's SpaceMono strut stripped"
run_arm S2 arm "only the arrow's line-height: 1 stripped"
run_arm V arm-baseline "vertical-align: top on the arrow and value instead of the fix"

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — every call-trace row is its 1.5625em box at every zoom, return value or not"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
