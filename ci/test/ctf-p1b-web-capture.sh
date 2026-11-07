#!/usr/bin/env bash
# ctf-p1b-web-capture.sh [--no-build] — CTF-P1b's WEB arm of the GPUI/web
# layout comparison: every Agent Harbor story in StoryBook, both themes, at
# the laptop and sidebar sizes, shot by `tools/visual-review/capture-storybook.mjs
# --regions` into `build/ctf-p1b/web/` (`CTF_P1B_WEB_OUT` overrides), and the
# regions the browser laid out merged into the COMMITTED record
# `src/tests/visual/agent-harbor-web-regions.json`.
#
# The record is committed for the reason PLAT-35 commits its Electron arm: the
# GPUI arm is re-taken wherever a compositor can open the window (the
# `gpui-window-captures` CI job), which has no browser, and the layout test
# (`test_ctf_p1b_gpui_capture_matches_web_layout.nim`) compares that fresh
# GPUI capture with this record. Re-run this after changing a web view, a
# story or the region declaration, and commit the record it rewrites. It holds
# rectangles only, of stories over the committed synthetic fixture set (this
# script refuses a StoryBook built over any other set), so it carries nothing
# private.
#
# The images stay in the git-ignored build tree; the side-by-side pairs are
# `tools/visual-review/parity-pairs.sh --agent-harbor`.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
OUT="${CTF_P1B_WEB_OUT:-${root}/build/ctf-p1b/web}"
RECORD="${root}/src/tests/visual/agent-harbor-web-regions.json"
DECL="${root}/src/tests/visual/agent-harbor-regions.json"
build=1
[ "${1:-}" = "--no-build" ] && build=0
if [ "${build}" = 1 ]; then
	just storybook-build
fi
# The fixture set the StoryBook components embed (`fixture_source.nim` picks the
# private set when it is checked out beside the workspace): the record is
# public, so it is taken over the synthetic set only, the set CI embeds.
grep -q '"fixtureSet\\": \\"synthetic\\"' storybook/dist/components.js || {
	echo "FAIL: storybook/dist/components.js does not embed the synthetic fixture set;" \
		"rebuild with AGENT_HARBOR_FIXTURES=synthetic" >&2
	exit 1
}
mkdir -p "${OUT}"
for size in laptop sidebar; do
	node tools/visual-review/capture-storybook.mjs --no-build \
		--view agent-harbor-session-tabs --view agent-harbor-fleet \
		--size "${size}" --theme dark --theme light \
		--out "${OUT}" --regions "${DECL}"
done
node - "${OUT}" "${RECORD}" <<'EOF'
// Merge every `<capture id>.regions.json` into the committed record, sorted
// by id so a re-take that changes nothing changes no byte.
const { readdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [outDir, record] = process.argv.slice(2);
const captures = {};
let fixtureSet = null;
for (const name of readdirSync(outDir).filter((n) => n.endsWith(".regions.json")).sort()) {
  const doc = JSON.parse(readFileSync(join(outDir, name), "utf8"));
  if (doc.renderer !== "web") throw new Error(`${name}: not a web capture`);
  captures[name.slice(0, -".regions.json".length)] = { viewport: doc.viewport, regions: doc.regions };
}
if (Object.keys(captures).length === 0) throw new Error(`no web regions in ${outDir}`);
writeFileSync(record, `${JSON.stringify({
  _comment: [
    "CTF-P1b: where the browser laid out each region of each Agent Harbor story",
    "(src/tests/visual/agent-harbor-regions.json), in CSS pixels of the capture's",
    "viewport. WRITTEN by ci/test/ctf-p1b-web-capture.sh from StoryBook over the",
    "synthetic fixture set; read by test_ctf_p1b_gpui_capture_matches_web_layout.nim.",
    "Do not edit by hand: re-take it.",
  ],
  schemaVersion: 1,
  captures,
}, null, 2)}\n`);
console.log(`ctf-p1b-web-capture: ${Object.keys(captures).length} captures recorded in ${record}`);
EOF
