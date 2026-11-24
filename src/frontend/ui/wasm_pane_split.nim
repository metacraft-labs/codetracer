## ui/wasm_pane_split.nim — which panes the WebAssembly core draws (`-d:ctWasmPanes`).
##
## The core (`web_core/web_core.nim`) builds its own Embed SDK session, and so
## its own ViewModels, attached to the tab's engine session. A pane whose state
## the engine alone produces looks the same from there as from the shell. A
## pane whose state the renderer's shell or its host sets does not: the shell
## opens and queries its own command palette while the core would draw a
## closed one, and the core has no host to list the project's files. Measured
## on the Electron scenario lane with every panel-host pane in the core
## (2026-11-23): the command palette's and the Filesystem's scenarios failed in
## both variants. So the shell, which stays `nim js`, keeps the panes it feeds,
## and the core draws only the panes the engine feeds.
##
## `ui/panel_host.nim` routes every pane through `drawnByWasmCore`; the split is
## held by `tests/wasm_pane_split_test.nim`.

# The kinds by NAME rather than by `Content` value: the renderer's `Content`
# (`frontend/types`, which includes the shared declaration) and the shared
# one (`common/types`) are two types with the same members, and both the
# panel host and the native test ask.
const
  WasmCorePaneKinds* = ["Calltrace", "State", "EventLog", "StepList",
                        "TerminalOutput", "Repl"]
    ## Fed by the engine alone: the stop, its values, its calls, its events,
    ## its output and what it evaluates.

  ShellFedPaneKinds* = ["CommandPalette", "Filesystem", "SearchResults",
                        "Build", "BuildErrors", "Scratchpad", "PointList",
                        "TraceLog", "LowLevelCode"]
    ## Fed by the shell or its host, so drawn by the shell:
    ##   CommandPalette — the shell's keys open it and its query is the shell's;
    ##   Filesystem     — the host lists the project;
    ##   SearchResults  — the shell runs the search;
    ##   Build, BuildErrors — the host runs the build task;
    ##   Scratchpad     — the shell adds values (`InternalAddToScratchpad`);
    ##   PointList, TraceLog — the editor sets breakpoints and tracepoints;
    ##   LowLevelCode   — the shell sets the generated-code listing
    ##                    (`ui/generated_code.nim`).

  WasmPaneNames = [("Calltrace", "calltrace"), ("State", "state"),
                   ("EventLog", "event-log"), ("StepList", "step-list"),
                   ("TerminalOutput", "terminal-output"), ("Repl", "repl")]

static:
  for k in WasmCorePaneKinds:
    doAssert k notin ShellFedPaneKinds, "a pane is on both sides: " & k

proc drawnByWasmCore*[E: enum](kind: E): bool =
  ## Whether the WebAssembly core draws pane `kind` (`-d:ctWasmPanes`).
  $kind in WasmCorePaneKinds

proc wasmPaneName*[E: enum](kind: E): string =
  ## The core's name for an engine-fed pane (`ctwMountPane`); "" otherwise.
  for (k, name) in WasmPaneNames:
    if k == $kind: return name
