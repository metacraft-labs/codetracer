## Emit the bytes an editing session writes to
## `~/.config/codetracer/default_edit_layout.json` on the machine that has
## never saved one — i.e. the seed fixture
## `edit-layout-without-agent-activity.json`.
##
## Run it through `regenerate-edit-layout-fixture.sh`, never by hand.
##
## WHY THIS IS A PROGRAM AND NOT A HAND-EDITED FILE
## ------------------------------------------------
## `review_layout_test.test_the_e2e_fixture_is_what_edit_mode_actually_writes`
## asserts that the checked-in fixture equals what the REAL save-side sanitiser
## produces from the REAL bundled layout. A fixture edited by hand to make that
## test go green is a fixture that agrees with production by coincidence for
## exactly as long as nobody looks: the next pane added to
## `src/config/default_layout.json` desynchronises it again, and the e2e suite
## that seeds it (`agent-activity-deepreview.spec.ts`) goes on testing a file
## no CodeTracer ever writes.
##
## It drifted for that reason once already. `Content.TestResults` (48) and
## `Content.Constraints` (49) became real panes in `ea25e49e` — declared in the
## bundled layout and deliberately absent from `editModeHiddenContentIds`, so
## an editing session shows them on both platforms — and the fixture, written
## by hand in `24153cf9` two weeks earlier, kept the two-pane layout that
## predated them.
##
## NOTHING HERE IS A SECOND IMPLEMENTATION
## ---------------------------------------
## Both halves are the production ones, imported:
##
##   * `index/layout_config_repair.sanitizeLayoutConfig` is what
##     `index/config.sanitizeEditLayoutJson` calls on save, and it is
##     importable here because that module depends on nothing but `std/jsffi`.
##   * `editModeHiddenContentIds()` is the hidden set that call passes. It
##     lives beside the `Content` enum in
##     `common/common_types/codetracer_features/frontend.nim` (moved there by
##     `42991d08`) rather than in `index/config.nim`, which imports electron
##     and cannot be reached from a `nim js` program at all. That file is
##     `include`d rather than imported, so it is reached here through
##     `common/types`, which compiles under `nim js` unchanged.
##
## So this emitter cannot disagree with the product about which panes survive a
## save. If it could, it would be one more thing to keep in step, and the
## fixture would have two ways to lie instead of one.
##
## It reads the PRODUCTION hidden set while `review_layout_test` asserts
## against its own mirrored copy of that list, and that difference is
## deliberate: a regenerated fixture that the test still rejects means the
## mirror has drifted from the product, which is a real failure and not a
## regeneration problem.
##
## The input is the bundled default layout because that is what the FIRST
## editing session on a machine is handed: CodeTracer ships no
## `default_edit_layout.json`, so `loadEditLayoutConfig` falls back to
## `default_layout.json`. Every later session re-saves what it loaded, which is
## why this shape is a fixed point rather than a one-off — the same reasoning
## `review_layout_test.savedEditLayoutFile` records.

import std/jsffi

import ../../../../../frontend/index/layout_config_repair
import ../../../../../common/types

const bundledDefaultLayoutJson =
  staticRead("../../../../../config/default_layout.json")

proc jsonParse(raw: cstring): js {.importjs: "JSON.parse(#)".}
proc jsonStringifyPretty(value: js): cstring {.
  importjs: "JSON.stringify(#, null, 4)".}

when isMainModule:
  let saved = sanitizeLayoutConfig(
    jsonParse(cstring(bundledDefaultLayoutJson)),
    ord(Content.EditorView),
    editModeHiddenContentIds())
  # `echo` supplies the trailing newline the repository's `end-of-file-fixer`
  # pre-commit hook would otherwise add, so a regeneration writes exactly the
  # committed bytes instead of a one-character diff the hook then undoes.
  echo jsonStringifyPretty(saved)
