## menu_chord_lookups_dom_test.nim
##
## ONE MENU BUILD ASKS THE KEY ROUTER FOR EACH ITEM'S CHORD ONCE.
##
## ## The defect this pins
##
## `renderer.sharedDirectRedraw` rebuilds the menu's model on every
## `data.redraw()` (`ui/menu.requestMenuRender`; the render gate skips only the
## DOM work after it). The model shows each item's chord, and the chord comes
## from the key router (`ui/key_router.chordForAction`), which works out the
## focused element's scope path from the DOM on every call. `menuRecord`
## worked out a folder's column widths once per CHILD, and the widths read
## every sibling's chord, so one build asked the router about n² times per
## folder. A profile of a call-trace jump that opens a new editor, on a loaded
## host, put this at about a third of the time the renderer was busy before the
## new editor mounted (three redraws, 350-440 ms of router lookups).
##
## ## What is asserted
##
## A build of a menu with folders of a realistic size asks the router at most
## once per distinctActions action, and a second build asks again (a rebinding or a
## focus change between builds is still seen). The count is the subject; no
## timing is involved.
##
## The one stand-in, and why it is not a mock: `chord_display.chordOfAction`
## is the seam `ui/key_router` installs itself into at load. The test installs
## a counting resolver there instead of the router, because the router's
## answer is not under test and its cost is what is being counted. The menu
## component, its model build and the render it feeds are the production ones.
##
## Lane: `renderer-dom`, compiled as the renderer is (`nim js -d:ctRenderer`,
## browser target) and run by `jsdom-run.mjs`. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it and prints
## unittest's `[OK]` / `[FAILED]` lines for the lane runner to count.

import ./legacy_loop_dom_bootstrap
# The menu's search index is built with the shipped fuzzysort, which the page
# loads as a global; load the same library here.
# jsdom puts `screen` on its window only; the menu reads the global, as a page
# does (`isWindowMaximizedForMenu`).
{.emit: "if (typeof globalThis.screen === 'undefined') globalThis.screen = window.screen;".}
{.emit: "globalThis.fuzzysort = require(globalThis.ctRepoRoot + '/node_modules/fuzzysort/fuzzysort.js');".}
import std/[jsffi, sets]

import ../types
# `menu` is in an import cycle with `debug_toolbar` (through `chord_display`);
# enter it where the renderer does: at `renderer`, then `ui/layout`.
import ../renderer
import ../ui/layout
import ../ui/menu
import ../ui/chord_display
import ../utils

const ExpectedChecks = 5
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
    echo "    check failed: ", astToStr(cond)

template scenario(name: string; body: untyped) =
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

proc addMenuHost() {.importjs: """(function(){
  const host = document.createElement('div'); host.id = 'menu';
  document.body.appendChild(host); })()""".}

# A menu the size of the program menu: six folders of twelve items, and one
# nested folder, over 40 distinctActions actions (an action may appear twice, as the
# real menu's does).
proc element(name: string; action: ClientAction): MenuNode =
  MenuNode(kind: MenuElement, name: cstring(name), action: action,
           enabled: true, elements: @[])

proc folder(name: string; children: seq[MenuNode]): MenuNode =
  MenuNode(kind: MenuFolder, name: cstring(name), enabled: true,
           elements: children)

var distinctActions = initHashSet[ClientAction]()
proc buildMenu(): MenuNode =
  var folders: seq[MenuNode] = @[]
  var next = ord(low(ClientAction)) + 1
  for f in 0 ..< 6:
    var items: seq[MenuNode] = @[]
    for i in 0 ..< 12:
      let action = ClientAction((next mod (ord(high(ClientAction)) - 1)) + 1)
      next += (if i mod 5 == 4: 0 else: 1)   # every fifth repeats the last
      distinctActions.incl action
      items.add element("Item " & $f & "." & $i, action)
    if f == 2:
      var nested: seq[MenuNode] = @[]
      for i in 0 ..< 6:
        let action = ClientAction((next mod (ord(high(ClientAction)) - 1)) + 1)
        inc next
        distinctActions.incl action
        nested.add element("Nested " & $i, action)
      items.add folder("More", nested)
    folders.add folder("Folder " & $f, items)
  folder("CodeTracer", folders)

var lookups = 0
chord_display.chordOfAction = proc(action: ClientAction): cstring =
  inc lookups
  cstring"Ctrl+K"

addMenuHost()
data.ui.menuNode = buildMenu()
let component = data.makeMenuComponent()

scenario "one build asks for each action's chord at most once":
  lookups = 0
  component.requestMenuRender()
  ck lookups > 0
  ck lookups <= distinctActions.len

scenario "the next build asks again":
  let before = lookups
  component.requestMenuRender()
  ck lookups > before
  ck lookups - before <= distinctActions.len

scenario "outside a build each lookup reaches the router":
  lookups = 0
  discard displayedChord(ClientAction(1))
  discard displayedChord(ClientAction(1))
  ck lookups == 2

if checks != ExpectedChecks:
  echo "  [FAILED] expected ", ExpectedChecks, " checks, ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
