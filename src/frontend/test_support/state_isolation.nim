## test_support/state_isolation.nim — a test process NEVER reads or writes the
## user's own per-user state.
##
## ## Why this exists
##
## The terminal and the GPUI window remember their layout (PLAT-45) in
## `nativeState.nativeStateRoot()` — `$CODETRACER_TUI_LAYOUT_DIR`, else
## `$XDG_STATE_HOME/codetracer`, else `~/.local/state/codetracer` — and write
## it on EVERY exit. `ci/lib/run-nim-test-lane.sh` gave each file its own
## `CODETRACER_TUI_LAYOUT_DIR`, but a suite compiled and run any other way (by
## hand, by a mutation harness, by a helper script) spawned the shipped binary
## with the developer's environment: it opened whatever arrangement the
## developer last left, and on exit it overwrote the developer's
## `~/.local/state/codetracer/tui-layout.json` with the suite's. Measured
## 2026-09-28 during PLAT-47's review.
##
## ## How
##
## This module is force-imported into every test program under
## `src/frontend/{tui,gpui,viewmodel}/tests/` by the `config.nims` beside those
## trees (`--import`), so no suite can forget it. At program start — before the
## suite's own top-level code, because an imported module initialises first —
## it points both variables a native host reads at a fresh directory of this
## process's own, unless they already name somewhere that is not the user's:
##
##   * `XDG_STATE_HOME` is replaced when it is unset or lies inside the
##     default `~/.local/state`;
##   * `CODETRACER_TUI_LAYOUT_DIR` is replaced when it is unset or lies inside
##     the user's state home (either spelling);
##   * `TEST_CERTIFICATES_DIR` and `TEST_CERTIFICATES_SYSTEM_DIR` — the user's
##     local certificate store (Transport.md §2.1, which `ct test` publishes
##     to and the status bar reads) — are ALWAYS replaced: an exported value
##     is by definition the user's own store, and the system root's default
##     (`/var/lib/test-certificates/<uid>`) is machine state no test should
##     read. Added 2026-10-10 (CTC-3e). A suite that needs a store sets its
##     own scratch root after start-up.
##
## A caller that already chose a private directory (the lane runner, a harness
## that inspects the document afterwards, a suite that sets one per spawn with
## `envSet`) keeps it: the rule only ever moves state AWAY from the user's.
## Children inherit the result, so every PTY launch, `startProcess` and
## `execCmd` below the test is isolated without being told.
##
## The directory is removed at exit. The guard that the user's directory is
## never touched is `tests/real_terminal/test_state_isolation.nim` (one launch
## of the shipped binary under this module, observed from outside) and the
## lane runner's before/after comparison of `~/.local/state/codetracer`.
##
## It exports nothing but the two queries the guard test reads, so an implicit
## import cannot shadow or collide with a suite's own names.

when not defined(js) and not defined(emscripten):
  import std/[os, strutils, exitprocs]

  const
    LayoutDirVar = "CODETRACER_TUI_LAYOUT_DIR"
    StateHomeVar = "XDG_STATE_HOME"

  proc userStateHome*(): string =
    ## The default XDG state home of the user running the tests — the directory
    ## no test may touch. Computed from `HOME`, not from `XDG_STATE_HOME`, which
    ## this module rewrites.
    getHomeDir() / ".local" / "state"

  proc inside(path, root: string): bool =
    if path.len == 0 or root.len == 0:
      return false
    let p = normalizedPath(absolutePath(path))
    let r = normalizedPath(absolutePath(root))
    p == r or p.startsWith(r & DirSep)

  var isolatedRoot = ""

  # The exit hook must not read `isolatedRoot`: it is a main-module global,
  # and its heap buffer is freed when the main module ends — BEFORE exit
  # procedures run (codetracer-pm issue 2026-10-10-exit-hooks-read-freed-
  # module-globals-and-may-delete-the-wrong-directory). A value array has no
  # destructor, so the hook reads the path from a copy kept here instead.
  var cleanupPath: array[4096, char]
  var cleanupPathLen = 0

  proc privateRoot(): string =
    if isolatedRoot.len == 0:
      isolatedRoot = getTempDir() / ("ct-test-state-" & $getCurrentProcessId())
      createDir(isolatedRoot)
      if isolatedRoot.len <= cleanupPath.len:
        for i, c in isolatedRoot:
          cleanupPath[i] = c
        cleanupPathLen = isolatedRoot.len
    isolatedRoot

  proc isolate() =
    putEnv("TEST_CERTIFICATES_DIR", privateRoot() / "test-certificates")
    putEnv("TEST_CERTIFICATES_SYSTEM_DIR",
           privateRoot() / "test-certificates-system")
    let home = userStateHome()
    let inheritedStateHome = getEnv(StateHomeVar)
    if inheritedStateHome.len == 0 or inheritedStateHome.inside(home):
      let dir = privateRoot() / "xdg-state"
      createDir(dir)
      putEnv(StateHomeVar, dir)
    let layout = getEnv(LayoutDirVar)
    if layout.len == 0 or layout.inside(home) or
        (inheritedStateHome.len > 0 and layout.inside(inheritedStateHome) and
         inheritedStateHome != getEnv(StateHomeVar)):
      let dir = privateRoot() / "codetracer"
      createDir(dir)
      putEnv(LayoutDirVar, dir)

  proc cleanup() =
    if cleanupPathLen > 0:
      var path = newString(cleanupPathLen)
      for i in 0 ..< cleanupPathLen:
        path[i] = cleanupPath[i]
      try:
        removeDir(path)
      except CatchableError:
        discard

  isolate()
  addExitProc(cleanup)
