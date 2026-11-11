## test_plat64_reachability.nim — Input-Routing-And-Keymaps.md §9 IR-2: EVERY
## OPERATION IS REACHABLE: bound in some keymap, offered by an element, or on a
## menu. The census runs over the shipped tables. An unreachable operation is
## LISTED below with the reason, not counted: a new one fails this suite by name,
## and one that became reachable fails it too, so the list only tells the truth.
##
## Set `PLAT64_CENSUS_OUT` to a path to have the census written there (the spec's
## published copy is generated this way).
##
## No mocks: the catalogue, the four bases, the click inventory, the context
## menus' table and the product menu are the shipped data.

import std/[algorithm, os, sets, strutils, unittest]

import codetracer_embed
import ../../headless_app/pane_clicks
import ../../viewmodel/keymap/[base_keymaps, client_actions, editing_keymap,
                               operation_catalogue]
import ../../viewmodel/viewmodels/product_menu
import ../../viewmodel/viewmodels/transport_icons

const
  OnlyByName = [
    # Reached by a hosted pane's row (`runPaneOperation`) or a user's row, with no
    # default chord and no element on any drawn surface yet.
    "frame-viewer.go-to-frame", "frame-viewer.next-frame",
    "frame-viewer.previous-frame", "file-tree.open", "file-tree.toggle-folder",
    "history.seek-to-tick", "variables.load-more",
  ]
    ## The operations a hosted editor binds by name.

  NoSurfaceYet = [
    # `ClientAction`s no menu, toolbar or element of the shared chrome offers, and
    # operations with no default chord: a user's row or the terminal's `:` line is
    # how they are reached today. Each is a surface to add, or a member to retire.
    "app.suspend", "build.compile", "build.run-program-in-current-tab",
    "build.run-static", "editor.toggle-macro-expansion",
    "flow.loop-level-at-position", "flow.zoom-loop-in", "flow.zoom-loop-out",
    "help.about", "help.check-key-delivery", "help.suggest-feature",
    "help.user-manual", "layout.load", "layout.new-event-log",
    "layout.new-full-calltrace", "layout.new-horizontal-group",
    "layout.new-state", "layout.new-terminal", "layout.new-vertical-group",
    "layout.save", "layout.switch-debug-wide", "layout.switch-edit-normal",
    "palette.fixed-search", "preferences.options", "search.replace-in-files",
    "session.debug", "session.load-trace", "session.new-file",
    "session.open-folder", "session.open-recent", "session.record-from-launch",
    "session.save", "session.save-all", "session.save-as",
    "session.switch-to-debug", "session.switch-to-edit", "session.trace",
    "table.resize-column", "tests.open-in-current-tab", "tests.open-in-new-tab",
    "tests.run-test", "tests.run-test-in-current-tab",
    "view.disassembly",
    "view.editor-theme-0", "view.generated-c-source", "view.next-point-in-time",
    "view.preview-multiline", "view.preview-none", "view.preview-single-line",
    "view.previous-point-in-time", "view.source-code", "view.start-window",
    "view.theme-0", "view.theme-2",
  ]

proc bound(): HashSet[string] =
  result = initHashSet[string]()
  for base in BaseKeymap:
    for b in keymapOf(base).keymap.bindings:
      result.incl b.operation

proc offered(): HashSet[string] =
  result = initHashSet[string]()
  for (_, op) in ClickOperations: result.incl op
  for a in ContextAction: result.incl ContextActionOperations[a]
  for c in TransportControls:
    result.incl splitOperation(operationOfClientAction(c.clientAction)).name

proc onMenu(): HashSet[string] =
  result = initHashSet[string]()
  for (_, it) in productMenuTree("codetracer").actionItems():
    let op = operationOfClientAction(it.action)
    if op.len > 0: result.incl splitOperation(op).name

proc census(): tuple[bound, offered, menu: int; unreachable: seq[string]] =
  let b = bound()
  let e = offered()
  let m = onMenu()
  for o in Catalogue:
    if o.name in b: inc result.bound
    elif o.name in e: inc result.offered
    elif o.name in m: inc result.menu
    elif o.name notin OnlyByName: result.unreachable.add o.name
  result.unreachable.sort()

suite "IR-2: the reachability census":
  test "every operation is reachable, or listed here":
    let c = census()
    let text = "catalogued: " & $Catalogue.len & "\nbound in a base: " & $c.bound &
      "\noffered by an element: " & $c.offered & "\non a menu: " & $c.menu &
      "\nreached by name only: " & $OnlyByName.len &
      "\nunreachable:\n  " & c.unreachable.join("\n  ") & "\n"
    checkpoint(text)
    let target = getEnv("PLAT64_CENSUS_OUT")
    if target.len > 0: writeFile(target, text)
    var known = @NoSurfaceYet
    known.sort()
    if c.unreachable != known:
      for u in c.unreachable:
        if u notin known: checkpoint("newly unreachable: " & u)
      for k in known:
        if k notin c.unreachable: checkpoint("reachable now, take it off the list: " & k)
    check c.unreachable == known
    check c.bound + c.offered + c.menu + OnlyByName.len + known.len == Catalogue.len

  test "the list of named-only operations holds no stale name":
    for name in OnlyByName:
      check isCatalogued(name)
      check name notin bound()
