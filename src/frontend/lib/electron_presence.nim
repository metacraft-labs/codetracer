## Is this page running inside an Electron renderer? — asked of the RUNTIME,
## so the question survives a build that has no Electron to ask about.
##
## ## Why this module exists at all
##
## `renderer.nim` and `ui_js.nim` between them take four decisions on this
## fact: which IPC transport to install (Electron's `ipcRenderer` or a
## socket.io connection to the browsersync dev server), and whether to save the
## layout on `beforeunload`. Until now all four read `electron_lib.inElectron`.
##
## That is a fine answer on the desktop and an impossible one on the web,
## because `lib/electron_lib.nim` is `{.error.}` under `-d:ctWeb` — by design,
## and its guard says why: it *is* the host binding layer, so a web build must
## not import it even to ask a yes/no question. Reading one bool from it put
## the whole of Electron's `fs` / `child_process` / `path` surface into the
## renderer's import graph, which is what kept the renderer un-buildable for
## the web.
##
## So the fact moves here, into a module that imports nothing and touches no
## node module, and `electron_lib` leaves the renderer's graph entirely.
##
## ## Why a runtime probe rather than the page global
##
## `electron_lib` declared `var inElectron* {.importc.}: bool` — the global an
## inline `<script>` in `index.html` and `subwindow.html` assigns. That is *a
## promise about the page*, not a fact about the runtime, and it has two
## defects a web build makes fatal rather than theoretical:
##
## 1. **A page that does not set it throws.** Reading an undeclared global is a
##    `ReferenceError` in JavaScript, not `undefined`. `electron_lib` already
##    carries a comment about exactly this biting the VS Code extension
##    context, which is why it has a second, plain-`var` arm. A browser tab
##    serving the web bundle is that same case, and it must not depend on
##    remembering to ship a stub script.
## 2. **It can disagree with the runtime.** `index.html` sets it beside
##    `window.electron = require('electron')`, so the two are only ever both
##    true — which is precisely the argument for asking the thing that
##    actually decides.
##
## `viewmodel/host/desktop_electron.nim` already reached this conclusion for
## the same fact and wrote it down at `electronAvailable()`:
##
##   "Checked by trying it rather than by reading a global the page set: the
##   renderer's `inElectron` is injected by an inline `<script>` in index.html,
##   which is a promise about the page rather than about the runtime, and a
##   StoryBook or dev-server page that forgot the script would claim the wrong
##   platform. This asks the runtime."
##
## This module is that probe, hoisted to where the renderer can reach it
## without importing a host module. `desktop_electron` keeps its own copy
## deliberately: it is a host instantiation and must not depend on renderer
## modules, and the two are read by different layers.
##
## ## Why it probes `ipcRenderer` specifically
##
## Because that is the capability all four call sites go on to use. Probing
## `require('electron')` alone would be true in the Electron MAIN process too,
## where `ipcRenderer` does not exist — and `index.nim`, which runs there, is a
## different build that must never take the renderer's branch.
##
## ## Backend
##
## `{.emit.}` rather than `importjs` because the guard is a `try`/`catch`
## statement, not an expression, and because `typeof require === 'function'`
## must be evaluated BEFORE `require` is named — a bare `importjs: "require(#)"`
## would throw in a browser at the point of the call rather than yield false.

when not defined(js):
  {.error: "lib/electron_presence.nim answers a question about a JavaScript " &
           "runtime and is meaningless on the C backend. A native build is " &
           "never inside an Electron renderer; if you need the fact there, " &
           "the answer is a constant `false` and belongs at your call site.".}

proc detectElectronRenderer(): bool =
  ## Probe once, at module initialisation. See the module header for why this
  ## asks the runtime rather than reading the page's `inElectron` global.
  ##
  ## Every failure mode collapses to `false`, which is the safe direction: a
  ## build that wrongly believes it is NOT in Electron installs the socket.io
  ## transport and fails visibly at connect time, whereas one that wrongly
  ## believes it IS reaches for `ipcRenderer` on `undefined` and dies during
  ## module init, before anything can report it.
  var available = false
  {.emit: """
  try {
    `available` = (typeof require === 'function') &&
                  !!require('electron').ipcRenderer;
  } catch (e) {
    `available` = false;
  }
  """.}
  available

let inElectron* = detectElectronRenderer()
  ## True exactly when this bundle is running in an Electron renderer process.
  ##
  ## A `let` evaluated at module init, matching the shape the four call sites
  ## already expect from `electron_lib.inElectron` (they read it at module
  ## scope, so a `proc` would change when the decision is taken). The probe is
  ## pure and cheap, and the answer cannot change during a page's lifetime.
