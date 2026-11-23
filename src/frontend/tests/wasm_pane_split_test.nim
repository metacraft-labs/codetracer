## wasm_pane_split_test.nim — the panes the WebAssembly core draws, and the
## ones the shell keeps (`ui/wasm_pane_split.nim`).
##
## With `-d:ctWasmPanes` the renderer's panel host hands a pane to the core
## only when `drawnByWasmCore` says so. A pane the shell or its host feeds
## breaks when the core draws it — the core's own ViewModels never see what
## the shell sets (the command palette and the Filesystem pane failed the
## Electron scenario lane in both variants on 2026-11-23) — so the side of
## each pane is a fact this suite holds, not a preference:
##
##   * every pane the panel host draws with an arm of its own is on exactly
##     one side;
##   * the panes known to be fed by the shell or its host are on the shell's
##     side, and Call Trace, the variables and the event log are the core's;
##   * the core can draw every pane on its side (`web_core.nim`);
##   * the panel host reaches the core only through the split.
##
## No stand-ins: the module under test is compiled as it ships, and the
## sources it is checked against are read from the tree.

import std/[os, sets, strutils, unittest]

import ../../common/types
import ../ui/wasm_pane_split

const root = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc read(rel: string): string = readFile(root / rel)

proc panelHostArms(): HashSet[string] =
  ## The `of Content.X:` arms of the panel host's render case.
  for line in read("src/frontend/ui/panel_host.nim").splitLines:
    let t = line.strip
    if t.startsWith("of Content.") and t.endsWith(":"):
      result.incl t["of Content.".len ..^ 2]

suite "the wasm pane split":
  test "every pane the panel host draws itself is on exactly one side":
    let arms = panelHostArms()
    check arms.len >= 15
    for name in arms:
      let kind = parseEnum[Content](name)
      check (name in WasmCorePaneKinds) != (name in ShellFedPaneKinds)
      check $kind == name
      if (name in WasmCorePaneKinds) == (name in ShellFedPaneKinds):
        echo "    unclassified or on both sides: ", name

  test "the panes the shell or its host feeds stay with the shell":
    for kind in [Content.CommandPalette, Content.Filesystem,
                 Content.SearchResults, Content.Build, Content.BuildErrors,
                 Content.Scratchpad, Content.PointList, Content.TraceLog,
                 Content.LowLevelCode]:
      check not drawnByWasmCore(kind)
      if drawnByWasmCore(kind): echo "    on the core's side: ", kind

  test "the engine's panes are the core's":
    for kind in [Content.Calltrace, Content.State, Content.EventLog]:
      check drawnByWasmCore(kind)

  test "the core can draw every pane on its side":
    let core = read("src/frontend/web_core/web_core.nim")
    for kindName in WasmCorePaneKinds:
      let name = wasmPaneName(parseEnum[Content](kindName))
      check name.len > 0
      check ("\"" & name & "\"") in core
      if ("\"" & name & "\"") notin core: echo "    the core has no pane ", name

  test "every shell-side pane says why it is there":
    let doc = read("src/frontend/ui/wasm_pane_split.nim")
    for kindName in ShellFedPaneKinds:
      check doc.count(kindName) >= 2  # in the list and in its reason

  test "the panel host reaches the core only through the split":
    let host = read("src/frontend/ui/panel_host.nim")
    check host.count("ctwMount(") == 2  # its declaration and its one call
    check "ctwMount(cstring(wasmPaneName(mount.kind))" in host
    check "drawnByWasmCore(mount.kind)" in host
