#!/usr/bin/env bash
# Regenerate `edit-layout-without-agent-activity.json` — the seed fixture the
# Playwright review suite installs as `default_edit_layout.json`
# (`editLayoutPath` in `lib/fixtures.ts`, seeded by `lib/layout-reset.ts`), so
# a review can be launched over a layout a PREVIOUS edit-mode session left
# behind.  Its consumer is
# `agent-activity-deepreview.spec.ts`, "the third pillar survives a persisted
# edit layout".
#
# The fixture is a GOLDEN FILE, not a scenario document: it must equal, byte
# for byte after canonicalisation, what `index/window.onSaveConfig` writes when
# an editing session ends.  That claim is asserted by
# `test_the_e2e_fixture_is_what_edit_mode_actually_writes` in
# `src/tests/gui/tests/layout/review_layout_test.nim`, and it is the reason
# this file exists: a golden brought back into line BY HAND is a golden that
# lies the next time, because the hand-edit records today's answer instead of
# re-deriving it.
#
# The sibling `edit-layout-agent-activity-buried.json` is deliberately NOT
# regenerated here.  It is a hand-built scenario — the Agent Activity panel
# behind FILES in a shared stack — that no save path produces, and nothing
# asserts it matches one.
#
# WHAT IT DERIVES FROM
#     src/config/default_layout.json                       (the input)
#     index/layout_config_repair.sanitizeLayoutConfig      (the save-side rule)
#     editModeHiddenContentIds()                           (the hidden set)
# all three imported by `emit_edit_layout_fixture.nim` rather than restated, so
# the emitter cannot drift from the product the way the fixture did.
#
# Usage, from anywhere, inside the dev shell:
#     bash src/tests/gui/tests/deepreview/fixtures/regenerate-edit-layout-fixture.sh
#
# Re-run it whenever `src/config/default_layout.json` gains or loses a pane, or
# `editModeHiddenContentIds()` changes.  Those are exactly the two edits that
# desynchronised it before: `Content.TestResults` and `Content.Constraints`
# became panes of the bundled layout and the fixture kept the layout that
# predated them.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../../.." && pwd)"
emitter="$here/emit_edit_layout_fixture.nim"
target="$here/edit-layout-without-agent-activity.json"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v nim >/dev/null || {
	echo "nim is required; run this inside the dev shell" >&2
	exit 1
}
command -v node >/dev/null || {
	echo "node is required; run this inside the dev shell" >&2
	exit 1
}

# `nim js` has been observed to exit 0 having produced nothing, so the
# artifact's existence is checked rather than the status — the same reason
# ci/lib/run-nim-test-lane.sh separates compiling from running.
(cd "$repo_root" && nim js -d:nodejs --hints:off --warnings:off \
	--nimcache:"$work/cache" -o:"$work/emit.js" "$emitter") || true
[ -s "$work/emit.js" ] || {
	echo "the emitter did not compile: no artifact at $work/emit.js" >&2
	exit 1
}

node "$work/emit.js" >"$work/out.json" || true
[ -s "$work/out.json" ] || {
	echo "the emitter produced no output" >&2
	exit 1
}

# It must be a layout, not merely non-empty: an emitter that printed a
# diagnostic would otherwise be committed as the fixture.  `9` is
# `Content.Filesystem`, which `index/config.isValidLayoutConfig` requires of
# any layout at all, and `41` is `Content.VCS`, the review's second pillar and
# the panel the consuming e2e test asserts stays visible.
node -e '
  const fs = require("fs");
  const text = fs.readFileSync(process.argv[1], "utf8");
  const layout = JSON.parse(text);
  const ids = [];
  const walk = (node) => {
    if (!node) return;
    if (node.type === "component") ids.push(node.componentState.content);
    for (const child of node.content || []) walk(child);
  };
  walk(layout.root);
  for (const [id, name] of [[9, "Filesystem"], [41, "VCS"]]) {
    if (!ids.includes(id)) {
      console.error("emitted layout has no " + name + " panel, content " + id);
      process.exit(1);
    }
  }
' "$work/out.json"

cp "$work/out.json" "$target"
echo "wrote $target"
