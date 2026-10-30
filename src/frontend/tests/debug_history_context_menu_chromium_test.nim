## The production debug toolbar, rendered by WebRenderer in real Chromium.
## ctClick supplies trusted pointer events; ctPress supplies trusted Escape.
## MockBackendService replaces only the replay transport so this focused test
## can seed visited positions and inspect exact history-jump requests without
## recording a program. The view, VM, document events and compiled theme are real.
## Run in the renderer-chromium lane; build the theme before compiling this file.

import std/[asyncjs, json, os, strutils]
import isonim/core/owner
import isonim/web/[dom_api, web_renderer]
import ../viewmodel/backend/[backend_service, mock_backend]
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/debug_controls_vm
import ../viewmodel/views/isonim_debug_controls_view

const ThemeCss = staticRead(currentSourcePath().parentDir /
  "../../build-debug/frontend/styles/default_dark_theme_electron.css")

proc ctClick(selector: cstring; button: cstring = cstring"left"): Future[void]
  {.importjs: "window.ctClick(#, #)".}
proc ctPress(selector, key: cstring): Future[void]
  {.importjs: "window.ctPress(#, #)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc prepare(css: cstring) {.importjs: """
  (function(css) {
    var style = document.createElement('style'); style.textContent = css;
    document.head.appendChild(style);
    document.body.innerHTML = '<div id="menu"><div id="isonim-debug-controls"></div></div>' +
      '<button id="outside" style="position:fixed;top:500px;left:20px;z-index:9000">Outside</button>';
    document.addEventListener('contextmenu', function(e) { window.historyContextEvent = e; }, true);
  })(#)
""".}
proc toolbarHost(): Node {.importjs: "document.getElementById('isonim-debug-controls')".}
proc count(selector: cstring): int {.importjs: "document.querySelectorAll(#).length".}
proc texts(selector: cstring): seq[cstring]
  {.importjs: "Array.from(document.querySelectorAll(#), x => x.textContent)".}
proc shown(selector: cstring): bool {.importjs: """
  (function(s) { var e=document.querySelector(s); return !!e && e.getBoundingClientRect().height>0; })(#)
""".}
proc contextPrevented(): bool {.importjs:
  "(window.historyContextEvent.isTrusted && window.historyContextEvent.defaultPrevented)".}
proc anchoredBelowBack(): bool {.importjs: """
  (function() {
    var b=document.getElementById('history-back-image').getBoundingClientRect();
    var m=document.getElementById('history-list').getBoundingClientRect();
    return m.top>=b.bottom && m.left>=0 && m.right<=window.innerWidth;
  })()@
""".}
proc activeId(): cstring {.importjs: "(document.activeElement.id)@".}
proc scrollable(): bool {.importjs: """
  (function() { var e=document.querySelector('.history-list-rows');
    return e.clientHeight>0 && e.scrollHeight>e.clientHeight &&
      document.getElementById('history-list').getBoundingClientRect().bottom<=window.innerHeight;
  })()@
""".}
proc lastJump(mock: MockBackendService): int =
  for c in mock.receivedCommands:
    if c.command == "ct/history-jump": result = c.args["rrTicks"].getInt

var checks = 0
proc require(ok: bool; message: string) =
  inc checks
  if not ok: raise newException(ValueError, message)

proc main() {.async.} =
  var disposeRoot: proc()
  try:
    prepare(cstring ThemeCss)
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    var vm: DebugControlsVM
    createRoot proc(dispose: proc()) =
      disposeRoot = dispose
      vm = createDebugControlsVM(store)
      for t in 1 .. 4: store.updateDebuggerPosition(uint64(t * 10), "/src/main.py", t)
      discard appendChild(toolbarHost(), Node(
        renderDebugControlsPanel[WebRenderer, Element](WebRenderer(), vm)))
    require(count(cstring"#history-list") == 0, "history starts closed")
    require(count(cstring"#history-list-before-image, #history-list-after-image") == 0,
      "standalone Earlier/Later controls were removed")
    await ctClick(cstring"#history-back-image", cstring"right")
    require(contextPrevented(), "trusted right-click suppresses browser context menu")
    require(shown(cstring"#history-list"), "back right-click opens a visible list")
    require(anchoredBelowBack(), "popup is below its button and within the viewport")
    let older = texts(cstring".history-list-entry")
    require(older.len == 3, "all older positions are listed")
    require($older[0] == "main.py:3  tick 30" and $older[2] == "main.py:1  tick 10",
      "older positions are nearest first, with location and tick")
    await ctClick(cstring".history-list-entry:last-child")
    require(mock.lastJump() == 10 and count(cstring"#history-list") == 0,
      "selecting an older position jumps exactly there and closes")
    store.updateDebuggerPosition(10, "/src/main.py", 1)
    await ctClick(cstring"#history-forward-image", cstring"right")
    require(contextPrevented(), "forward also suppresses the native browser menu")
    let newer = texts(cstring".history-list-entry")
    require(newer.len == 3 and ($newer[0]).contains("tick 20") and
      ($newer[2]).contains("tick 40"), "all newer positions are nearest first")
    await ctClick(cstring".history-list-entry:last-child")
    require(mock.lastJump() == 40 and count(cstring"#history-list") == 0,
      "selecting a newer position jumps exactly there and closes")
    store.updateDebuggerPosition(40, "/src/main.py", 4)
    await ctClick(cstring"#history-back-image", cstring"right")
    await ctPress(cstring"", cstring"Escape")
    require(count(cstring"#history-list") == 0 and activeId() == cstring"history-back-image",
      "Escape dismisses and restores focus to the originating button")
    await ctClick(cstring"#history-back-image", cstring"right")
    await ctClick(cstring"#outside")
    require(count(cstring"#history-list") == 0, "an outside pointer click dismisses")
    await ctClick(cstring"#history-back-image", cstring"right")
    await ctClick(cstring".history-list-close")
    require(count(cstring"#history-list") == 0, "Close dismisses the menu")
    await ctClick(cstring"#history-back-image")
    require(mock.lastJump() == 30, "left-click still moves only one history position")
    store.updateDebuggerPosition(30, "/src/main.py", 3)
    # New navigation after going back branches history, then fills a long list.
    for t in 5 .. 80: store.updateDebuggerPosition(uint64(t * 10), "/src/main.py", t)
    await ctClick(cstring"#history-back-image", cstring"right")
    require(count(cstring".history-list-entry") == vm.history.val.len - 1,
      "long histories retain every destination")
    require(scrollable(), "long histories scroll and keep Close inside the viewport")
    await ctClick(cstring".history-list-entry:last-child")
    require(mock.lastJump() == 10, "the oldest destination is reachable by scrolling")
    store.updateDebuggerPosition(10, "/src/main.py", 1)
    await ctClick(cstring"#history-forward-image", cstring"right")
    disposeRoot()
    disposeRoot = nil
    vm.historyList.val = hlBefore
    await ctClick(cstring"#outside")
    require(vm.historyList.val == hlBefore, "disposing the toolbar removes document listeners")
    echo "[OK] debug history context menus, selection, dismissal and scrolling"
    echo "CHECKS: " & $checks
    ctFinish(0)
  except:
    echo "[FAILED] " & getCurrentExceptionMsg()
    if not disposeRoot.isNil: disposeRoot()
    ctFinish(1)

discard main()
