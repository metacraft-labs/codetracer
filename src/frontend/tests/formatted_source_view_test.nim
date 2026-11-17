## formatted_source_view_test.nim — the desktop's toggle into a minified
## source's formatted view is a command a user can reach, and it asks the
## replay server for the view and back.
##
## LANE: `frontend-js`. Compile and run:
##   nim js -d:nodejs --path:src/frontend/viewmodel \
##     -r src/frontend/tests/formatted_source_view_test.nim
##
## Column-Aware-Navigation §M3 has the GUI send `ct/set-active-source-view` on
## a view toggle; until this command nothing in the desktop sent it (codetracer-pm
## `issues/2026-11-13-desktop-has-no-control-to-show-a-formatted-source-view.md`).
## The end-to-end path (a minified recording, its map, F10 by formatted lines)
## is the scenario `src/tests/scenarios/formatted-view/step-over.yaml`.
##
## No mocks: the shipped operation catalogue, the shipped action table and the
## shipped toggle.

import std/[strutils, unittest]

import ../ui/formatted_source_view
import ../viewmodel/keymap/[client_actions, operation_catalogue]

suite "the formatted source view's toggle":
  test "the palette's command is a catalogued operation with its own action":
    let op = operationOfClientAction("aToggleFormattedSourceView")
    check op == "view.toggle-formatted-source"
    var found = false
    for o in Catalogue:
      if o.name == op:
        found = true
        check o.label == ToggleFormattedSourceViewLabel
    check found

  test "turning the view on names the file the replay is stopped in":
    let t = toggledFormattedView(false, "/work/program.js")
    check t.on
    check t.viewPath == "/work/program.js"
    check t.notice.contains("on")

  test "turning it off sends no path, so the replay is the recorded one again":
    let t = toggledFormattedView(true, "/work/program.src.js")
    check not t.on
    check t.viewPath == ""
    check t.notice.contains("off")

  test "two toggles come back to where they started":
    let a = toggledFormattedView(false, "/work/program.js")
    let b = toggledFormattedView(a.on, "/work/program.js")
    check not b.on
    check b.viewPath == ""
