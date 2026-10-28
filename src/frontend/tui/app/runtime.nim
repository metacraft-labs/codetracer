## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/runtime.nim — CTUI-11. What one input token DOES to a running
## debugger, as a function of a value.
##
## ## Why this is not in `main.nim`, and not in `host/`
##
## `main.nim` says of itself that it "wires `host/` to `app/` and nothing else"
## and that "the moment a decision here needs state it belongs in `app/`". An
## input loop is nothing but state: a modal mode, a pending chord prefix, a pane
## focus, a prompt buffer, a notification. All of it is here, and `main.nim` is
## the four lines that read a token off a terminal and hand it over.
##
## `host/` is wrong for the same reason from the other side: none of this needs
## a file descriptor. `handleToken` is a pure function of
## `(runtime, token, nowMs)` — the clock is passed in exactly as
## `keymap.resolve` takes it, so a bounded chord timeout is drivable without a
## sleep — and everything it can decide is reported in the returned
## `RuntimeOutcome` rather than done.
##
## ## THE HOST STILL OWNS THE BACKEND, AND THAT SPLIT IS LOAD-BEARING
##
## CTUI-10's `app/commands/interpreter.dispatchAction` is "THE ONE DISPATCH":
## every §4.2 binding and every §4.3 command reaches the debugger through it,
## and it is the only proc under `app/` that names a `DebugControlsVM` action.
## Calling it SENDS a DAP request through the store's injected `BackendService`.
## It does not, and cannot, wait for the answer — `ct/complete-move` arrives on
## an event and the blocking pump for it is `viewmodel/headless_session`, which
## `app/` may not import.
##
## So `RuntimeOutcome.awaitsMove` is how this layer says "a navigation command
## is in flight; pump it". CTUI-5 measured the consequence of getting this
## wrong and recorded it: with nothing pumping the event, a step is sent, the
## engine moves, and every pane keeps reporting the old position forever.

import std/[options, os, strutils, tables]

import codetracer_embed   # PLAT-43: `BaseKeymap`, `selectKeymap`
import headless_app/auto_hide_hover
import headless_app/file_tree_menu   # K19: the Files pane's menu

import ./commands/interpreter
import ./edit_binding
import ./input/keymap
import ./input/motions
import ./input/operation_dispatch
import ./input/key_check
import ./clipboard_read
import ./layout/persistence
import ./layout/project
import ./theme/degradation
import ./tui_app
import ./views/command_line
import ./views/shell
import ./views/welcome_view
import headless_app/welcome_tabs
import ./views/event_log
import ./views/vcs_pane
import ./views/search_results_pane
import ./views/terminal_info
import ./theme/terminal_report
import ./views/test_results_pane
import ./views/agent_activity_pane
import ./views/problems_pane
import ./views/requests_pane   # PLAT-58

export interpreter, keymap, motions, command_line, tui_app, degradation
export persistence

type
  EditReadResult* = object
    ## What a host's file reader answered.
    ##
    ## AN OBJECT AND NOT A TUPLE, and the reason is measured rather than
    ## stylistic: Nim 2.2.8 miscompiles a CLOSURE FIELD whose return type is a
    ## tuple — the generated call passes the first argument where the hidden
    ## result pointer belongs, and gcc rejects it
    ## (`expected 'tyTuple…*' but argument is of type 'NimStringV2'`). The
    ## whole `tui` lane went red on it. A named object also makes the call
    ## sites read as `answer.message` rather than `answer[2]`.
    ok*: bool
    text*: string
    message*: string
      ## What the user is shown on failure, so a refusal names the file and the
      ## reason rather than being a bare false.

  EditWriteResult* = object
    ok*: bool
    message*: string

  BuildStartResult* = object
    ok*: bool
    message*: string

  EditListResult* = object
    ## What a host's project walk found. Mirrors
    ## `host/edit_host.ProjectListing`, spelled here because `app/` may not
    ## import `host/`.
    files*: seq[string]
    truncated*: bool
      ## Whether the walk hit its cap. REPORTED rather than silent, for
      ## `edit_host.listProjectFiles`' own reason: a file tree missing files
      ## without saying so is a file tree a user concludes does not contain
      ## them.

  EditServices* = object
    ## PLAT-16's host seam. See `TuiRuntime.editServices`.
    readFile*: proc(relative: string): EditReadResult {.closure.}
    writeFile*: proc(relative, text: string): EditWriteResult {.closure.}
    listFiles*: proc(): EditListResult {.closure.}
      ## The project's files, for the file tree and for the buffer Edit mode
      ## opens on arrival.
      ##
      ## A CLOSURE AND NOT A VALUE, because the two loops that enter Edit mode
      ## learn the listing at different times. `main.editInteractive` takes it
      ## BEFORE the terminal is claimed — an unbounded walk behind a claimed
      ## alternate screen is what `host/edit_host.nim`'s header is written
      ## against — and hands back a closure over the value it already has.
      ## `main.interactive` cannot: a replay session may never press `Ctrl+F5`,
      ## and walking a project on every `ct replay` would put a filesystem walk
      ## inside CTUI-11's cold-start budget for a feature the session does not
      ## use. So its closure walks LAZILY, on the first switch. One consumer
      ## (`ensureEditWorkspace`), two suppliers, no branch in the consumer.
    startBuild*: proc(kind: BuildKind; command: string): BuildStartResult
      {.closure.}
    submitFileJob*: proc(job: FileJob) {.closure.}
      ## PLAT-29. Hand a read (`:e!`) or a write (`:w`) to the host's file
      ## worker (`host/file_worker`), which answers through `deliverFileJob`.
      ## Nil in a session with no host thread: the job then runs inline
      ## through `readFile` / `writeFile` and is delivered at once, down the
      ## same reconciliation.
    requestHighlight*: proc(req: HighlightRequest) {.closure.}
      ## PLAT-29. Hand a parse to the host's worker thread
      ## (`host/highlight_worker`), which answers through `deliverHighlight`.
      ## Nil in a session with no host thread — the suites — where the SAME
      ## `computeHighlight` runs inline, so both routes classify identically.
    readConfig*: proc(spelled: string): EditReadResult {.closure.}
      ## PLAT-36. Read a user's Vim configuration for `:source`: `~`
      ## expanded, relative paths against the project. Unlike `readFile` it
      ## may reach outside the project — see `host/edit_host
      ## .readUserConfigFile`. Nil in a session with no host filesystem.
    saveKeymap*: proc(model: BaseKeymap): string {.closure.}
      ## PLAT-43. Remember the chosen keymap model for the next session; ""
      ## on success, else a one-line message naming the path. Nil in a session
      ## whose host keeps no state — the choice then holds for this session
      ## only, and `:keymap` says so.
      ## Starts a build and takes ownership of the process. The SESSION it
      ## reports into is `TuiApp.build`, which the host fills, because the poll
      ## loop that advances it is the host's too.
    readSource*: proc(path: string): EditReadResult {.closure.}
      ## PLAT-68: the whole text of a file of the RECORDING (the source
      ## provider's, generation 0 — what the Debug-mode editor shows), for
      ## the read-only document the Debug-mode editor's keys act on
      ## (selection, copy, find, the tracepoint line). Nil in a session with
      ## no recording; the editor then has no document and its facts are
      ## `sourceViewFacts`.
    reloadKeybindings*: proc(): string {.closure.}
      ## PLAT-68: re-read the user's `keybindings.json` and lay it over the
      ## base (`:keys reload`); answers the load summary. Nil in a host that
      ## keeps no configuration.
    wireFileTree*: proc(vm: FilesystemVM; openedFolder: proc(): string;
                        done: proc(r: FileTreeOperationResult)) {.closure.}
      ## K19: make Edit mode's Files model (`TuiApp.editFilesVM`) act on the
      ## disk — the host's `native_file_tree.wireNativeFileOperations`, which
      ## `app/` may not import. Nil in a session with no host filesystem: the
      ## menu then disables Create, Rename and Delete ("This front end cannot
      ## change files").

  PaneClickKind* = enum
    ## PLAT-50: what a click in a pane asks the HOST to do — the operations
    ## that need the session (`headless_app/pane_clicks`' shared ops). The
    ## ones the runtime can do on its own models (a variable expanded, a
    ## menu opened, a point selected) never reach the host.
    pcNone
    pcOpenFile
      ## Files: a file — show it in the editor (`path`).
    pcToggleFolder
      ## Files: a folder — expand or collapse it (`path`).
    pcToggleBreakpoint
      ## The editor's gutter: a breakpoint on `path:line`, or none.
    pcSetBreakpointEnabled
      ## The editor's gutter, right-click: `enabled` for `path:line`'s.
    pcLineJump
      ## The editor's text, Ctrl / middle click or the menu: go to
      ## `path:line` (`behaviour`: smart, forward, backward).
    pcEventJump
      ## The event log: go to the event whose log index is `index`.
    pcSeek
      ## A seek: go to `tick`.
    pcDeleteBreakpoints
      ## The editor's menu: delete every breakpoint of `path` ("Delete
      ## breakpoints in file"), or of every file when `path` is "" ("Delete
      ## ALL breakpoints").
    pcColumnBreakpoint
      ## The editor's text, Alt+click: a breakpoint on `path:line` anchored
      ## at `column`.
    pcCallJump
      ## Ctrl+Alt+click on a call, or the menu's call jumps: go to the call
      ## of `text` (the word) on `path:line` (`behaviour`).
    pcEventOrder
      ## The event log's header: order the log by `order`.
    pcScratchpadAdd
      ## Pin `values` to the scratchpad.
    pcScratchpadRemove
      ## The scratchpad's close button: remove the value at `index`.
    pcValueHistory
      ## The Variables menu's "Toggle value history" on the variable at
      ## `path`.
    pcValueOrigin
      ## The Variables menu's "Show value origin" on the variable at `path`.
    pcWatch
      ## PLAT-51: a watch expression edited — `text` added (`behaviour` ""),
      ## `path` removed (`behaviour` "remove"), or `path` replaced by `text`
      ## (`behaviour` "edit").
    pcVcsDiff
      ## The VCS pane: show the diff of `path` (`text` its state letter) —
      ## the working tree's, or commit `behaviour`'s when it names one.
    pcVcsCommit
      ## The VCS pane: open or close commit `index`.
    pcTerminalView
      ## PLAT-52: the Terminal Output pane's toggle — show the view named by
      ## `text` (`lines` / `screen`), remembered for this recording.
    pcSearchResult
      ## PLAT-57 (K35): Find in Files' result `index` — selected and opened
      ## in the editor at its line, the match selected; the recording
      ## position does not move.
    pcSearchOption
      ## PLAT-57: Find in Files' toggle whose operation is `text`
      ## (`search.toggle-case` / `-whole-word` / `-regex`) flipped, and the
      ## search run again.
    pcTestsRun
      ## PLAT-53: the Test Results pane's ▶ — the project's suite run
      ## (`TestResultsVM.startRun`).
    pcTestsRefresh
      ## PLAT-53: a Test Results row's `⟳` on the test `text` names (its
      ## id): record it again and stay (`TestResultsVM.triggerRefresh`).
    pcTestsOpen
      ## PLAT-53: a Test Results row's `⏵` on the test `text` names: open its
      ## recording where Test-Results-Pane.md §9 places it, recording it first
      ## when it has none (`TestResultsVM.triggerOpen`); `behaviour`
      ## `TestsRedirectBehaviour` when the press carried Ctrl (§9.3: the
      ## destination inverted for that press).
    pcTestsOpenIn
      ## §9.3: the palette's **Tests: Open Recordings in …** — the project's
      ## `replay-open-in` set to the policy `text` names.
    pcFrameSeek
      ## PLAT-51: the frame viewer's own scrubber — show frame `index`
      ## (`behaviour` "drag" while held, "release" where it is let go:
      ## Visual-Replay.md's Scrub Slider, whose release settles there).
    pcPointMenu
      ## M76: the program menu's breakpoint or tracepoint item whose
      ## `ClientAction` is `text` (`point_menu_ops`), at `path:line` — the
      ## editor caret's line (the desktop's `pointsOperationsSetup`).

  PaneClickRequest* = object
    kind*: PaneClickKind
    path*: string
    line*: int
    column*: int
    index*: int64
    tick*: uint64
    enabled*: bool
    behaviour*: string
    text*: string
      ## An event's content (`pcEventJump`), the word a call jump names.
    values*: seq[NamedValue]
      ## The (expression, value) pairs `pcScratchpadAdd` pins.
    order*: EventLogOrder
      ## `pcEventOrder`'s order.

  SourceScrollKind* = enum
    ## M73 (#840): what the user asked the Debug-mode source pane's WINDOW to
    ## do. The pane draws `SourceVM`'s window, which the HOST owns
    ## (`host/tui_session`), so this layer says what was asked and the host
    ## moves the window and serves the lines it then lacks — the same split as
    ## `awaitsMove`. Until M73 nothing the user did reached that window: only
    ## a stop's `followExecutionPointer` moved it.
    sskNone
    sskBy
      ## Scroll by `delta` lines, down positive: the wheel over the editor
      ## (CodeTracer-TUI.md §4.4), `j` / `k` and `Ctrl+d` / `Ctrl+u` while it
      ## is focused (§4.2 Source Navigation). The execution pointer and the
      ## caret stay where they are.
    sskTo
      ## Put line `top` at the top: the vertical bar's track or thumb
      ## (Scrollbar-Scrubbers.md §3.2, §3.3).
    sskCentreOnPointer
      ## `.`: "Reset source scroll so the current execution pointer is
      ## centered" (§4.2).
    sskFollowCaret
      ## The read-only caret moved to `line`:`column`: the smallest scroll
      ## that keeps it on screen (Editor-Pane.md § The caret in a read-only
      ## editor).

  SourceScroll* = object
    ## M73 (#840): one request for the source window. See `SourceScrollKind`.
    kind*: SourceScrollKind
    delta*: int
    top*: int
      ## 1-based.
    line*: int
    column*: int
      ## 1-based, both.

  RuntimeOutcome* = object
    ## Everything one token decided, as a value the host acts on.
    ##
    ## A VALUE RATHER THAN FOUR CALLBACKS, and the reason is the same one
    ## `app/cli.nim` gives for `TuiCommand`: the whole dispatch becomes
    ## assertable without a terminal, a process or a backend.
    repaint*: bool
      ## Whether anything the user can see changed.
    quit*: bool
      ## §4.2's `q` / `Ctrl+c`.
    awaitsMove*: bool
      ## A navigation command was SENT and the host must consume the
      ## `stopped` + `ct/complete-move` pair it will produce. See the module
      ## header.
    awaitsOrigin*: bool
      ## `o` / `:origin` ASKED for a chain (`ct/originChain`) rather than
      ## moving: no `stopped` comes, so the host must not pump a move. It
      ## takes the `ct/updated-origin-chain` answer into the Origin ViewModel
      ## and runs the action again (`retryOrigin`), which then walks the
      ## chain — `interpreter.dispatchOrigin`'s arm 2. Until this, the host
      ## pumped a move here and the terminal froze waiting for one.
    originRetry*: string
      ## The command line to run again (`:origin X`), or "" for the key.
    refreshesSession*: bool
      ## The engine's state changed WITHOUT a move — a breakpoint was set or
      ## cleared — so the host rebuilds the panes from the session, but must
      ## not pump for a `stopped` event that is not coming.
    pagesCallTrace*: bool
    jumpsToCall*: bool
      ## PLAT-49 part B: a click on a call-trace row — the host goes to that
      ## call (`ct/calltrace-jump`, the desktop's click) and refreshes.
    togglesCall*: bool
      ## PLAT-49 part B: a click on a row's toggle — the host expands or
      ## collapses that call's children (`ct/expand-calls` /
      ## `ct/collapse-calls`) and reloads the section.
    callIndex*: int64
      ## The trace index `jumpsToCall` / `togglesCall` act on.
    stopsSession*: bool
      ## M76: *Stop* (the Debug menu, CUA's `Shift+F5`): the workspace is in
      ## Edit mode already (`stopDebugging`), and the host ends the session
      ## behind the tab — its replay backend terminated — and makes the
      ## runtime forget it (`tui_session.stop`).
    paneClick*: PaneClickRequest
      ## PLAT-50: a click in a pane that the host carries out.
      ## PLAT-47. The reader scrolled the call trace: the host loads the
      ## section of the trace the pane now shows, if it does not hold it
      ## (`tui_session.pageCallTrace`), and nothing else — no pump, no
      ## rebuild of the other panes.
    sourceScroll*: SourceScroll
      ## M73 (#840): the source window moved by the user — the host applies
      ## it to `SourceVM` and serves the lines it then lacks
      ## (`tui_session.scrollSource`). `sskNone` for every other token.
    action*: KeyAction
      ## What fired, for the status line and for a test that wants to assert
      ## the binding rather than its effect.
    detail*: string
      ## The dispatch's own message. Copied into the notification, and kept
      ## here too so a caller can tell "nothing happened" from "the engine
      ## refused".

  BarGrab* = object
    ## PLAT-70 Part H: a thumb held (§7.4) — the bar, and the point of the
    ## thumb the pointer took (`scrollbar_interaction.grabOffset`).
    active*: bool
    pane*: PaneKind
    axis*: BarAxis
    offset*: float

  BarHold* = object
    ## A paging press held on a track: the bar, and when it pages again.
    pane*: PaneKind
    axis*: BarAxis
    hold*: TrackHold

  ScrollbarRuntime* = object
    ## PLAT-70 Part H (Scrollbar-Scrubbers.md §7): the scrollbars' medium
    ## state — the options, what the pointer is doing to which bar, the held
    ## thumb or paging press, each pane's fade, and what each bar showed the
    ## last time a frame was painted (a scroll wakes its pane's bars).
    options*: ScrollbarOptions
    pointer*: BarPointer
    grab*: BarGrab
    paging*: BarHold
    fades*: array[PaneKind, FadeState]
    started*: bool
      ## The fades were given the clock (the first tick).
    pointerPane*: tuple[found: bool, pane: PaneKind]
      ## The pane the pointer was last in: entering one wakes its bars.
    shownTops*: array[PaneKind, array[BarAxis, int]]
      ## Each bar's first visible row / column as last painted, -1 for none.
    present*: array[PaneKind, array[BarAxis, bool]]
      ## Which bars the last frame painted: a table pane's horizontal bar
      ## that APPEARS (its columns grew past the pane) wakes its pane.
    painted*: seq[BarSpot]
      ## The bars of the last frame painted — what a passing pointer is
      ## hit-tested against (a press reads the bars afresh).
    paintedValid*: bool
    clockMs*: int64
      ## The latest time the runtime was told (a token, a tick).

  TerminalService* = ref object
    ## PLAT-71 (Terminal-Adaptation §5, §10): what only the host can do
    ## about the terminal — it holds the start-up negotiation.
    setChoice*: proc(which: LayoutSetting; value: string): string {.closure.}
      ## `:set <terminal setting> <value>` (rank 1): re-resolve the profile
      ## with it, adopt it, remember it. Answers the status line's text.
    setForThisTerminal*: proc(which: LayoutSetting;
                              value: string): string {.closure.}
      ## The glyph test card's `y` / `n`: the setting for THIS terminal only
      ## (a `[terminal "<name>"]` section, OQ-T6).
    rerun*: proc(): string {.closure.}
      ## Ask the terminal again (`:terminal-info`'s `r`).
    dismissHints*: proc(): string {.closure.}
      ## `:terminal-info dismiss`: no start-up hint ever again (§10.2).

  TuiRuntime* = ref object
    ## The running front-end's state, minus the terminal and minus the process.
    app*: TuiApp
    dockKeys*: PaneKind
    hasDockKeys*: bool
      ## PLAT-55: the docked pane a left press last landed in while it was
      ## shown (docked open, or revealed). The focus ring holds only the
      ## arrangement's regions, so a docked pane never has the focus; this is
      ## how a press on the docked Problems pane gives it the list keys (Build-
      ## Output-Pane.md §3.3: arrow keys move, Enter jumps), as a click on the
      ## desktop's docked panel does. Cleared by a press anywhere else, and
      ## when a row opens the editor.
    scrollbars*: ScrollbarRuntime
      ## PLAT-70 Part H: the scrollbars' options, pointer, grab, paging and
      ## fades (§7).
    terminalInfo*: TerminalInfoView
      ## PLAT-71: `:terminal-info` — the live report and the glyph test card.
    caps*: TerminalCapabilities
      ## Handed in by `host/capabilities.negotiateCapabilities` before this
      ## object exists, for CTUI-11's "resolved before first paint".
    router*: KeymapRouter
      ## PLAT-68: THE ONE ROUTE FROM A KEY TO AN OPERATION — the active base,
      ## the user's `keybindings.json` over it, the pushed layers and the
      ## pending prefix (`viewmodel/keymap/keymap_router`, shared with GPUI
      ## and the desktop). This runtime supplies the scope path
      ## (`scopePath`), the ViewModels' facts (`sessionFacts`) and the
      ## dispatch (`runResolution`).
    modal*: ModalState
    focus*: PaneFocus
    maximize*: MaximizeState
    prompt*: CommandLineModel
      ## §3.3.6's `:` / `/` / `?` line. One model rather than three, and the
      ## kind on it says which sigil is showing — `command_line.open` is what
      ## resets the buffer between kinds.
    dispatcher*: Dispatcher
      ## CTUI-10's ViewModel bundle. Filled by the host, because every field is
      ## a ViewModel constructed over a store the host owns.
    context*: CommandContext
      ## Where the debugger IS, refreshed by the host after every move.
    lastToken*: string
    lastKey*: string
      ## For the status line and for a failure message: the exact bytes that
      ## arrived and the canonical name they resolved to.
    width*: int
    height*: int
    layoutDocument*: string
      ## PLAT-6's persistence: where THIS session's rearranged layout is saved.
      ##
      ## **`""` WHENEVER PERSISTENCE IS OFF, which is every session without
      ## `--layout-binding` and every host that never named a document.** The
      ## path is held here rather than recomputed at exit because the two ends
      ## of a save must be the same file: a session that restored from one path
      ## and wrote to another would silently keep two arrangements for one
      ## recording. `host/layout_store.nim` is what fills it, and it is the only
      ## thing in this front-end that touches a file for this purpose.
    eraseByte*: char
      ## PLAT-68. The byte this terminal sends for Backspace (termios
      ## `VERASE`, read by the host's driver); the other of `0x7f` / `0x08` is
      ## Ctrl+Backspace. Every token is named through `keyOf`, which reads it.
    tabMovesFocus*: bool
      ## PLAT-68: VS Code's `Ctrl+M` mode (`editor.toggle-tab-moves-focus`):
      ## while on, `Tab` in a buffer is not indentation. The `tabMovesFocus`
      ## context key reads it.
    keyCheck*: KeyCheck
      ## PLAT-68: `:keys check` (Help: Check Key Delivery) while it runs.
    clipboardRead*: ClipboardRead
      ## PLAT-68: a paste asks the terminal for its clipboard (OSC 52) and is
      ## held for the answer; `clipboard_read` has the conversation.
    keymapNotice*: string
      ## PLAT-43. A stored keymap preference the host REFUSED, by name, to be
      ## shown when Edit mode is furnished — where it wins the status line over
      ## `editing … — N file(s)`, which would otherwise overwrite it within the
      ## same frame (measured by the pty suite's first run). Shown once.
    editServices*: EditServices
    filesReprompt*: string
      ## K19: the command line to open again after the one just submitted —
      ## a Files name the model refused (`commitNameEdit`), whose field stays
      ## open with its reason.
      ## PLAT-16. The HOST's three filesystem/process capabilities, injected.
      ##
      ## THE SAME CATEGORY AS CTUI-8's `EventPages` SEAM AND CTUI-10's
      ## `CommandServices`, and not a mock: `app/` may not open a file or spawn
      ## a process, so the only way `:w` can write is for the host to hand in
      ## the writer. In a shipped binary these are `host/edit_host.nim` and
      ## `host/build_runner.nim`; in a Tier-1 suite they are the suite, and what
      ## is asserted is what the runtime ASKED FOR rather than what a fake
      ## returned.
      ##
      ## A nil field is a reportable state and not a crash: `:w` in a session
      ## with no writer says so, which is the state a Debug-only session is in.
    themeService*: proc(name: string): bool {.closure.}
      ## The HOST's live mode switch behind §4.3's `:theme <dark|light>`: it
      ## re-resolves the terminal capabilities with the named design-system
      ## mode pinned, adopts them on the driver (so the next frame is a full
      ## repaint) and updates `caps`. Nil in a host that cannot repaint, where
      ## `:theme` answers `unsupported` by name. The host installs it into
      ## `dispatcher.services.setTheme` wherever it builds the dispatcher.
    layoutCommitted*: proc(rt: TuiRuntime) {.closure.}
      ## PLAT-45 deliverable 8: the HOST's write-through, called after every
      ## layout command or gesture that COMMITTED a change (`lasApplied`), so
      ## a crash loses nothing. `host/layout_store.nim` is what it runs in a
      ## shipped binary; nil in a host that does not persist, where nothing
      ## happens. A hook rather than a call, because `app/` may not open a
      ## file.
    layoutCommits*: int
      ## PLAT-51: how many layout changes have committed. The host compares
      ## it across a token to know a committed arrangement may have resized
      ## a pane — the ONE moment a pane fetches for its new size (Layout-
      ## ViewModel §4.3a: never mid-drag).
    savePreference*: proc(name, value: string): string {.closure.}
      ## PLAT-51: the HOST's write of a layout preference (`:set
      ## focus-highlight off`, `:set scrollbar-thickness thin`), "" on
      ## success, else why not. Nil in a host that keeps no state.
    terminalService*: TerminalService
      ## PLAT-71: the HOST's half of the terminal settings and the report —
      ## re-resolving the capability profile when `:set` changes one (rank 1
      ## of Terminal-Adaptation §5.2), the scoped `y` / `n` of the glyph test
      ## card, and `:terminal-info`'s report. Nil in a host with no terminal.
    saveIcons*: proc(mode: IconsMode): string {.closure.}
      ## PLAT-48: the HOST's write of the `icons` setting (`:icons`), "" on
      ## success. Nil in a host that keeps no state.
    saveColumnWidths*: proc(table: string;
                            entries: seq[ColumnWidthEntry]): string {.closure.}
      ## PLAT-70 Part B: the HOST's write of a table's column widths
      ## (`host/table_column_widths`, the one document every front-end reads),
      ## "" on success. Nil in a host that keeps no state.
    autoHide*: AutoHideHover
      ## PLAT-49 part B (finding 9): the pointer's timing over the auto-hide
      ## labels — the desktop's hover preview and leave dismissal
      ## (`headless_app/auto_hide_hover`). Medium state, held here, never in
      ## the layout.
    topBarPressConsumed*: bool
      ## PLAT-48: the top bar (or an open menu / omnibar) took the last
      ## press, so its release is not a layout gesture.
    layoutDocumentQuarantined*: bool
      ## Whether this session started from a document it could NOT read.
      ##
      ## Carried across the whole session for one reason, and it is the
      ## expensive case the schema chain exists for: a document written by a
      ## NEWER build decodes as `ldeUnknownVersion` here, and a build that
      ## answered by overwriting it on exit would destroy a user's arrangement
      ## because they opened an older binary once. See
      ## `app/layout/persistence.LayoutPersistIntent`.
    hostedRows*: Table[PaneKind, int]
      ## HSF-E1: THE PANE SERVER'S PANES, each sized by the editor window it
      ## is shown in (Editor-Hosted-Front-Ends §E5). Empty in the terminal.
      ## When any pane is hosted, a pane's content rows are its window's
      ## (`paneBodyRows`, `sourcePaneRows`) and not a rectangle of this
      ## runtime's own screen — so every viewport the session sets from them
      ## follows the editor's windows, and a pane the editor does not show
      ## has none.
    hostedCols*: Table[PaneKind, int]
      ## HSF-V2: the same windows' widths, in cells (`paneBodyCols`).

const
  QuitDetail* = "quit"

proc sourcePaneRows*(rt: TuiRuntime): int
  ## FORWARD-DECLARED. `runPromptLine`'s `:e` arm and `routeTokenToEditor` both
  ## need the editor rectangle's height — the first to size a new buffer's
  ## viewport, the second to follow the caret — and the definition sits with
  ## the other screen readers at the end of this module, where every reader of
  ## the projection is together.

proc paneBodyRows*(rt: TuiRuntime; pane: PaneKind): int
  ## FORWARD-DECLARED for the call trace's scroll keys; defined beside
  ## `sourcePaneRows`.

proc showPane(rt: TuiRuntime; pane: PaneKind; outcome: var RuntimeOutcome)
proc openOmnibar*(rt: TuiRuntime; query = "")
  ## PLAT-54: FORWARD-DECLARED for Agent Activity's prompt row and `/ai`.
proc openFindInFiles(rt: TuiRuntime; outcome: var RuntimeOutcome)
proc runFindInFiles(rt: TuiRuntime; pattern: string;
                    outcome: var RuntimeOutcome)
proc stepFindInFiles(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome)
  ## PLAT-57: FORWARD-DECLARED for the command line's `:grep`, `:cnext` and
  ## `:cprev`; defined beside `showPane`, whose rule they use.
proc openRequestsField(rt: TuiRuntime; outcome: var RuntimeOutcome)
proc actOnRequests*(rt: TuiRuntime; act: RequestsAct;
                    outcome: var RuntimeOutcome): RequestsActResult
  ## PLAT-58: FORWARD-DECLARED for the command line's `:requests`; defined
  ## beside the Requests pane's other helpers.

proc runFileJob(rt: TuiRuntime; job: FileJob)
proc writeBuffers(rt: TuiRuntime; verb: string; all = false)
proc sessionFacts*(rt: TuiRuntime): SessionFacts
proc debugBuffer*(rt: TuiRuntime): EditBuffer
proc editorBuffer(rt: TuiRuntime): EditBuffer
  ## Forward-declared for PLAT-70's horizontal views; defined below.
proc openFindSession(rt: TuiRuntime; backward: bool; symbol: bool;
                     outcome: var RuntimeOutcome)
  ## Forward-declared for `applyLocalAction`'s `/` / `?` (PLAT-70 Part C);
  ## defined with the find session's section.
proc cancelFind(rt: TuiRuntime; outcome: var RuntimeOutcome)
  ## Forward-declared for the palette's **Find: Cancel and Return**.
proc revealFind(rt: TuiRuntime; buf: EditBuffer; reveal: FindReveal;
                outcome: var RuntimeOutcome)
  ## Forward-declared for `runPromptLine`'s committed find field.
proc syncCaretFrom(rt: TuiRuntime; buf: EditBuffer)
proc scopePath*(rt: TuiRuntime): ScopePath
proc navMode(rt: TuiRuntime): NavigationMode
proc unmountGoneOwners(rt: TuiRuntime)
proc showShortcutReference(rt: TuiRuntime; outcome: var RuntimeOutcome)
  ## FORWARD-DECLARED (PLAT-68) for `:keys reference`; defined beside
  ## `syncOverlayLayers`, whose stack it reads.
  ## FORWARD-DECLARED (PLAT-68) for the chord displays and the focus ring;
  ## defined with the router's section beside `handleToken`.
  ## FORWARD-DECLARED for the `:w` and `:e!` arms of `runPromptLine`; defined
  ## beside `deliverFileJob`, the answer it hands a job to.

proc initScrollbarRuntime*(options = DefaultScrollbarOptions):
    ScrollbarRuntime =
  ## Every bar drawn and resting; the fades take the clock at the first tick.
  result = ScrollbarRuntime(options: options)
  for pane in PaneKind:
    result.fades[pane] = initFade(0)
    for axis in BarAxis:
      result.shownTops[pane][axis] = -1

proc newTuiRuntime*(app: TuiApp; caps: TerminalCapabilities;
                    width, height: int): TuiRuntime =
  ## A runtime over an application and a negotiated terminal.
  ##
  ## The FOCUS is seeded from the layout's own projection at this size rather
  ## than from a constant, so `Tab` cycles the panes that are actually on
  ## screen — CTUI-9's `newPaneFocus` takes a `Projection` for exactly that
  ## reason, and a Compact profile has fewer panes than an Ultra-wide one.
  let model = app.shellModel(width, height)
  let projection = projectLayout(model.layout, bodyArea(width, height))
  result = TuiRuntime(
    app: app, caps: caps,
    # The base an edit session was opened under, else the product default
    # until the host's `selectBase` (the flag, the stored preference).
    router: initKeymapRouter(
      (if app.editSession.isNil: bkCua else: app.editSession.model),
      KeyDelivery(frontEnd: feTerminal, platform: hostPlatform(),
                  keyProtocol: caps.keyProtocol)),
    modal: initModalState(),
    focus: newPaneFocus(projection),
    maximize: initMaximizeState(),
    prompt: initCommandLineModel(),
    dispatcher: Dispatcher(),
    context: CommandContext(),
    lastToken: "", lastKey: "",
    width: width, height: height,
    autoHide: initAutoHideHover(),
    scrollbars: initScrollbarRuntime(),
    eraseByte: '\x7f')
  # PLAT-71: the options the profile owns (`adoptProfileOptions`).
  result.scrollbars.options.modernUnicode = caps.modernUnicode
  result.scrollbars.options.reduceMotion = caps.reduceMotion

proc keyOf*(rt: TuiRuntime; token: string): string =
  ## The canonical name of an input token on THIS terminal — `keyName` with the
  ## terminal's own erase byte. Every token the runtime names goes through it.
  keyName(token, rt.eraseByte)

proc keyDelivery*(rt: TuiRuntime): KeyDelivery =
  ## Base-Keymaps-And-Layer-Stack.md §4.2's three keys this front-end
  ## supplies: the terminal, the host's platform, and the key protocol the
  ## driver negotiated. Derived from `caps` — never stored beside it.
  KeyDelivery(frontEnd: feTerminal, platform: hostPlatform(),
              keyProtocol: rt.caps.keyProtocol)

proc openTerminalInfo*(rt: TuiRuntime) =
  ## PLAT-71: `:terminal-info` / **Terminal: Show Capabilities**.
  rt.terminalInfo = TerminalInfoView(open: true)

proc adoptProfileOptions(rt: TuiRuntime) =
  ## PLAT-71: the scrollbar options the terminal's profile owns —
  ## `modern-unicode` for all chrome (OQ-T9) and `reduce-motion` (or a
  ## conservative link, §4.6), which makes the fade jump to its end state.
  rt.scrollbars.options.modernUnicode = rt.caps.modernUnicode
  rt.scrollbars.options.reduceMotion = rt.caps.reduceMotion

proc adoptCaps*(rt: TuiRuntime; caps: TerminalCapabilities) =
  ## The host re-negotiated (a late reply, `:theme`): take the new
  ## capabilities, and hand an open edit session the key protocol they carry.
  rt.caps = caps
  rt.adoptProfileOptions()
  if not rt.app.editSession.isNil:
    rt.app.editSession.adoptDelivery(rt.keyDelivery)
  # The user's rows are judged again: a chord a legacy terminal could not
  # deliver loads once the Kitty protocol is on (§7.4).
  rt.router.delivery = rt.keyDelivery
  rt.router.applyUserKeymap(rt.router.userKeymap)

proc keymapModel*(rt: TuiRuntime): BaseKeymap =
  ## The active base keymap (Base-Keymaps-And-Layer-Stack.md §3.1).
  rt.router.base

proc selectBase*(rt: TuiRuntime; base: BaseKeymap; source: BaseSource) =
  ## Make `base` the active base, for the router and for every open buffer
  ## (`--keymap`, the stored preference, `:keymap`, the palette's Select
  ## Base Keymap all arrive here).
  rt.router.switchBase(base, source)
  if not rt.app.editSession.isNil:
    rt.app.editSession.selectModel(base)

proc applyUserKeymap*(rt: TuiRuntime; uk: UserKeymap): string =
  ## Lay the user's `keybindings.json` over the base; answers the load
  ## summary for the status line (`keymap_router.loadSummary`).
  rt.router.applyUserKeymap(uk)
  rt.router.loadSummary

proc layoutBindingEnabled*(rt: TuiRuntime): bool =
  ## Whether PLAT-6's layout binding is driving this runtime's arrangement.
  ##
  ## **OFF BY DEFAULT, AND EVERYTHING BELOW IS GUARDED BY IT.** With no binding
  ## the model `tui_app.shellModel` builds is the one CTUI-3 built — the
  ## session's own `LayoutNode`, an empty `docked`, no `Interaction` — so the
  ## screen is byte-identical and `:move-tab` is the unknown command it has
  ## always been. That is not a temporary state: see `enableLayoutBinding` for
  ## what would have to change before the default could flip.
  not rt.isNil and not rt.app.isNil and not rt.app.layoutBinding.isNil

proc layoutGeometry*(rt: TuiRuntime): LayoutGeometry

proc rebuildFocus(rt: TuiRuntime) =
  ## Re-derive the focus ring from the layout that will be painted next,
  ## carrying the focused pane if it is still on screen.
  ##
  ## Called after a resize AND after a layout command, because both can change
  ## which panes have a rectangle: `:dock left` takes one off the screen
  ## entirely, and a focus ring built before it would hand `Tab` a pane that is
  ## no longer projected.
  let (had, focused) = rt.focus.focusedPane()
  let model = rt.app.shellModel(rt.width, rt.height)
  let projection = projectLayout(model.layout, bodyArea(rt.width, rt.height))
  var docked: seq[PaneRegion] = @[]
  if rt.layoutBindingEnabled():
    let geometry = rt.layoutGeometry()
    if not geometry.openDock.isEmptyArea:
      docked.add PaneRegion(pane: geometry.openDockPane,
                            area: geometry.openDock, activeTab: -1)
  rt.focus = newPaneFocus(projection,
                         tabId = "tab:" & $(rt.app.shell.activeTabIndex() + 1),
                         docked = docked)
  if had:
    discard rt.focus.focusPaneKind(focused)
  # PLAT-68: a pane gone from the screen takes its pushed layers with it.
  rt.unmountGoneOwners()

proc layoutGeometry*(rt: TuiRuntime): LayoutGeometry =
  ## The binding's geometry at this terminal size — the dock strips, the inner
  ## area and the pane-to-path resolution the next frame will be painted from.
  ##
  ## An empty geometry when no binding is enabled, so a caller cannot use this
  ## to conjure one.
  if not rt.layoutBindingEnabled():
    return LayoutGeometry()
  rt.app.layoutBinding.geometry(bodyArea(rt.width, rt.height))

proc paintedGeometry*(rt: TuiRuntime): LayoutGeometry =
  ## THE ARRANGEMENT ON SCREEN, which is what a press is hit-tested against
  ## (CodeTracer-TUI.md §4.4). The binding's own geometry, except while a
  ## pane is maximized (`z`): the frame then paints the one-pane tree
  ## `maximize.layoutFor` builds, beside the same docked panes, and a press
  ## read against the binding's tree landed on whichever pane holds that
  ## cell in the UN-maximized arrangement (codetracer-pm issue
  ## 2026-10-24-tui-maximized-pane-receives-no-pane-clicks). Composed exactly
  ## as `shell.shellScreen` composes the frame.
  if not rt.maximize.active or not rt.layoutBindingEnabled():
    return rt.layoutGeometry()
  let model = rt.app.shellModel(rt.width, rt.height)
  geometryOf(initLayout(rt.maximize.layoutFor(model.profile), model.docked),
             bodyArea(rt.width, rt.height), model.interaction,
             DefaultProjectionPolicy, footerLeadCells(model.fileInfo))

proc enableLayoutBinding*(rt: TuiRuntime): LayoutBinding =
  ## **THE OPT-IN.** Give this running front-end a layout the user can
  ## rearrange, and route `:`'s layout verbs into it (PLAT-6).
  ##
  ## OPT-IN RATHER THAN THE DEFAULT, and the reason is one level below this
  ## module. `headless_app.HeadlessSessionSlot.layout` is a `LayoutNode`;
  ## a `LayoutBinding` holds a `Layout` whose tree is a CLONE
  ## (`newLayoutHistory` copies), so with a binding enabled the terminal draws
  ## the binding's tree and the session's own node is no longer what is on
  ## screen. Today nothing performs the operation that would make that visible —
  ## `headless_app.activatePane` has no production caller in this repository,
  ## its five call sites are all in `test_headless_app_entrypoint.nim`, and no
  ## key handler here reaches it — so the divergence is LATENT rather than
  ## current, which is exactly what makes an opt-in the right shape: it buys the
  ## gesture surface without creating the second authority for anybody who did
  ## not ask.
  ##
  ## **What would have to be true to flip the default:** `HeadlessSessionSlot`
  ## would have to hold a `Layout` rather than a `LayoutNode`, so that the
  ## session's arrangement and the binding's are one value and `activate` and a
  ## gesture cannot disagree. That is a change to the shared shell model — the
  ## one the desktop persists — and it is PLAT-4-level work rather than a
  ## binding's to make.
  ##
  ## The binding is seeded from the ACTIVE SESSION's own tree in Debug mode,
  ## and from the current product mode's default otherwise (an Edit-mode
  ## runtime — `ct edit` — has no session), so the first frame after this call
  ## is the frame that would have been painted without it.
  result = rt.app.enableLayoutBinding(rt.width, rt.height)
  # THE FOCUSED PANE IS THE RUNTIME'S, not a second one. `LayoutBinding.focus`
  # is what `:dock`, `:move-tab` and `:resize` act on, and `Tab` / `Ctrl+w` are
  # what a user moves it with — so the two are synchronised here and again
  # before every layout command.
  let (had, focused) = rt.focus.focusedPane()
  if had:
    result.focus = focused

# ---------------------------------------------------------------------------
# PLAT-6's persistence. THE DECISIONS ARE `app/layout/persistence.nim`'s and
# the file itself is `host/layout_store.nim`'s; what is here is the SESSION —
# which document this runtime is bound to, and what adopting one does to the
# rest of the runtime's state.
# ---------------------------------------------------------------------------

proc layoutPersistenceEnabled*(rt: TuiRuntime): bool =
  ## Whether this session saves and restores its arrangement.
  ##
  ## **BOTH HALVES ARE REQUIRED**, and the first is the one that matters: with
  ## no binding there is no arrangement to save, so `--layout-binding` gates
  ## persistence exactly as it gates the gestures. A host that enabled the
  ## binding and named no document gets the behaviour PLAT-6 shipped — a
  ## rearrangeable session that forgets.
  rt.layoutBindingEnabled() and rt.layoutDocument.len > 0

proc bindLayoutDocument*(rt: TuiRuntime; path: string) =
  ## Name the file this session's arrangement is saved to and restored from.
  ##
  ## Naming it does not read it: `host/layout_store.nim` does that and hands
  ## the bytes to `adoptLayoutDocument` below, which is the split
  ## `host/capabilities` -> `app/theme/capabilities` already uses.
  rt.layoutDocument = path
  rt.layoutDocumentQuarantined = false

proc adoptLayoutDocument*(rt: TuiRuntime; path, text: string):
    LayoutRestoreReport =
  ## Adopt one saved document into THIS session, and put the runtime back into
  ## a consistent state around it.
  ##
  ## Three things happen here that `persistence.adoptLayoutDocument` cannot do
  ## from where it sits, and each of them is a defect if it is left out:
  ##
  ##   * **the focus ring is rebuilt**, because a restored arrangement may have
  ##     docked away the pane the ring was seeded with — the same reason
  ##     `runPromptLine` and `routeMouseReport` rebuild it after a gesture. A
  ##     ring built from the profile default would hand `Tab` a pane that is
  ##     not on screen;
  ##   * **the binding's focus is synchronised to the ring**, so the first
  ##     typed verb of the session acts on the pane the user can see is
  ##     focused;
  ##   * **an unreadable document is remembered**, so exiting leaves it alone.
  result = rt.app.layoutBinding.adoptLayoutDocument(path, text)
  rt.layoutDocumentQuarantined = result.status == lrsUnreadable
  if result.status != lrsRestored:
    return
  rt.rebuildFocus()
  let (had, focused) = rt.focus.focusedPane()
  if had:
    rt.app.layoutBinding.focus = focused

proc markLayoutDocumentUnreadable*(rt: TuiRuntime) =
  ## Record a failure that happened BEFORE the bytes reached the decoder — a
  ## file that could not be opened at all. `host/layout_store.nim` is the only
  ## caller, because only it can meet that failure, and the consequence is the
  ## same one `adoptLayoutDocument` sets: the document is left alone on the way
  ## out.
  rt.layoutDocumentQuarantined = true

proc layoutPersistPlanOf*(rt: TuiRuntime): LayoutPersistPlan =
  ## What exiting should do with this session's document.
  ##
  ## `lpiQuarantine` for a session with persistence switched off as well as for
  ## one that started from an unreadable document, and that is deliberate
  ## rather than a coincidence of spelling: **quarantine is the intent that
  ## touches nothing**, which is exactly the answer "the flag is off" needs. A
  ## host that called this without checking would still write no file.
  ##
  ## **THE DOCUMENT IS THE DEBUG ARRANGEMENT**, in whichever mode the session
  ## exits. The terminal keeps ONE document and it is not keyed by mode
  ## (Mode-Transitions.md §4.6, "the terminal's `ct edit` arrangement lives in
  ## the register only"), and the replay loop restores it into Debug mode. So
  ## while the binding holds Edit mode's arrangement the plan is made from the
  ## Debug arrangement the mode register holds (`shell.switchBound`): a user
  ## who rearranged Debug mode and quit from Edit mode keeps that arrangement,
  ## one who never touched Debug mode gets the untouched answer (remove), and
  ## Edit's arrangement is never written. A register with no Debug cell —
  ## unreachable, since a bound runtime with a document starts in Debug mode —
  ## answers the intent that touches nothing.
  if not rt.layoutPersistenceEnabled():
    return LayoutPersistPlan(intent: lpiQuarantine, text: "")
  let b = rt.app.layoutBinding
  if b.product == pmDebug:
    return layoutPersistPlan(b, rt.layoutDocumentQuarantined)
  let debug = rt.app.modes.bound[pmDebug]
  if not debug.stored:
    return LayoutPersistPlan(intent: lpiQuarantine, text: "")
  layoutPersistPlan(debug.layout, debug.userModified,
                    rt.layoutDocumentQuarantined)

proc debugArrangementOf*(rt: TuiRuntime): Layout =
  ## The DEBUG arrangement of a bound runtime, in whichever mode is on screen:
  ## the binding's own while it holds Debug mode, the mode register's Debug
  ## cell while it holds Edit mode (`toggleBoundArrangement`). This is what a
  ## host writes onto a replay session's slot — when it leaves a tab, when it
  ## opens a new one — because a slot's `Layout` is a REPLAY arrangement
  ## (`HeadlessApp` has no edit slot), so writing the binding there while it
  ## holds Edit mode's panes would put them into the session's replay
  ## arrangement. A Debug cell never stored — Edit mode entered without ever
  ## leaving Debug mode, which the replay loop cannot do — answers Debug
  ## mode's default at the current size. Precondition: the binding is enabled.
  let b = rt.app.layoutBinding
  if b.product == pmDebug:
    return b.layout
  let debug = rt.app.modes.bound[pmDebug]
  if debug.stored: debug.layout
  else: layoutValueForMode(pmDebug, selectProfile(rt.width, rt.height))

proc afterLayoutCommit(rt: TuiRuntime) =
  ## A layout command or gesture committed a change. Two consequences, both
  ## PLAT-45 deliverable 8 (and the half PLAT-4 handed forward):
  ##
  ##   * **the session's own slot is told**, when there is one, so the
  ##     arrangement a `HeadlessApp.saveLayouts` would write is the one on
  ##     screen — the binding and the session no longer diverge after the
  ##     first gesture;
  ##   * **the host writes it through** (`layoutCommitted`), so the terminal's
  ##     remembered arrangement is current after every change rather than only
  ##     after a clean exit.
  ##
  ## **BOTH ARE DEBUG MODE'S, AND ONLY DEBUG MODE'S COMMITS REACH THEM.** The
  ## slot's `Layout` is the session's REPLAY arrangement (`HeadlessApp` has no
  ## edit slot) and the document is the Debug arrangement
  ## (`layoutPersistPlanOf`). A commit made while the binding holds Edit
  ## mode's arrangement — a VCS tab clicked in a replay toggled into Edit mode
  ## — is that arrangement's alone: it is kept in the binding, and in the mode
  ## register across a switch, and written onto neither. Writing it to the
  ## slot would put Edit's panes into the session's replay arrangement, and
  ## writing it through would overwrite the user's remembered Debug
  ## arrangement with an Edit one. The commit is still COUNTED: the host's
  ## `layoutCommits` watch re-measures the source pane after any arrangement
  ## change, in either mode.
  if not rt.layoutBindingEnabled():
    return
  inc rt.layoutCommits
  if rt.app.layoutBinding.product != pmDebug:
    return
  let slot = rt.app.shell.activeSlot()
  if not slot.isNil:
    slot.layout = rt.app.layoutBinding.layout.clone()
  if not rt.layoutCommitted.isNil:
    rt.layoutCommitted(rt)

proc toggleBoundArrangement(rt: TuiRuntime; profile: LayoutProfile): bool =
  ## `Ctrl+F5` WITH A LAYOUT BINDING: swap the binding's arrangement with the
  ## mode register's cell for the entering mode (Mode-Transitions.md §4.6, "a
  ## switch carries the gestures with it"). Returns whether the mode changed.
  ##
  ## The binding is the only arrangement a bound runtime draws and the one a
  ## click is hit-tested against, so it must hold the CURRENT mode's
  ## arrangement in both modes. Before codetracer-pm issue 2026-10-21's fix the
  ## toggle moved only the register's trees and `shellModel` drew those over
  ## the binding: the replay loop toggled into Edit mode drew Edit's tree and
  ## hit-tested Debug's, and after one round trip in either loop the frame
  ## drew a snapshot while every gesture moved only the hit-test.
  ##
  ##   * the LEAVING arrangement is stored whole — tree, docked panes, whether
  ##     it is the user's, the size it was left at — in its mode's cell (§4
  ##     requirement 2);
  ##   * the ENTERING mode's cell is loaded into the binding, or the mode's
  ##     default on a first visit (§4 requirement 1, §4c obligation 3: a first
  ##     visit is not a degradation and says nothing);
  ##   * mode and arrangement change in one call (§4 requirement 4);
  ##   * the entering arrangement starts a NEW undo history
  ##     (`binding.adoptModeArrangement`): an undo never crosses a switch.
  ##
  ## Debug mode's cell keeps the session slot's relationship: every Debug
  ## commit is written onto the slot (`afterLayoutCommit`), so the cell stored
  ## on the way out is the slot's arrangement, and nothing written in Edit mode
  ## reaches the slot.
  let b = rt.app.layoutBinding
  let target = toggled(rt.app.modes.product)
  let leaving = BoundCell(stored: true, layout: b.layout.clone(),
                          userModified: b.userModified, profile: b.profile)
  let (changed, entering) = rt.app.modes.switchBound(leaving, target)
  if not changed:
    return false
  if entering.stored:
    b.adoptModeArrangement(entering.layout, target, entering.profile,
                           entering.userModified, rt.width, rt.height)
  else:
    b.adoptModeArrangement(layoutValueForMode(target, profile), target,
                           profile, false, rt.width, rt.height)
  true

proc resize*(rt: TuiRuntime; width, height: int) =
  ## Adopt a new terminal geometry, re-deriving the focus ring from the layout
  ## the new size projects to.
  ##
  ## The focus ring is REBUILT and the focused pane is CARRIED, which is the
  ## same guard `shell.reprofile` states for the active tab: a resize inside one
  ## profile's band must not silently move the user's focus, and a resize that
  ## crosses a band may legitimately remove the pane they were on.
  rt.width = width
  rt.height = height
  # PLAT-6's responsive-profile decision, when a binding is enabled: the
  # profile always tracks the size, and the TREE is re-flowed only while the
  # user has not modified it. Before the model is read, so the focus ring below
  # is built from the arrangement the next frame will paint.
  if rt.layoutBindingEnabled():
    discard rt.app.layoutBinding.resize(width, height)
  rt.rebuildFocus()

proc note(rt: TuiRuntime; message: string) =
  rt.app.notification = message

proc promptCandidates(rt: TuiRuntime): seq[string] =
  ## What `Tab` completes at the open prompt. §4.3's command names at `:`, and
  ## nothing at `/` or `?` — a search pattern is not drawn from a vocabulary.
  if rt.prompt.kind == pkCommand: commandNames() else: @[]

proc openPrompt(rt: TuiRuntime; kind: PromptKind): bool =
  discard rt.prompt.open(kind)
  true

proc changesSessionState*(action: KeyAction): bool =
  ## Whether a `drDone` for `action` changed what the session holds without
  ## moving it — the host refreshes the panes but pumps nothing.
  action == kaToggleBreakpoint

proc movesTheDebugger*(action: KeyAction): bool =
  ## Whether firing `action` sends a navigation command the host must pump.
  ##
  ## Enumerated rather than inferred from the dispatch result, because
  ## `drDone` is also what a purely local action answers: `kaMaximizePane`
  ## reports `drDone` and sends nothing, and a host that pumped after it would
  ## block on an event no engine is going to send. `waitForEvent` reads the
  ## pipe until its message budget runs out, so getting this wrong is a hang
  ## rather than a wrong screen.
  case action
  of kaStepOver, kaReverseStepOver, kaStepInto, kaReverseStepInto,
     kaStepOut, kaReverseStepOut, kaContinue, kaReverseContinue,
     kaPrevCall, kaNextCall, kaPrevMutation, kaNextMutation,
     kaJumpToStart, kaJumpToEnd, kaSeekToTick, kaHistoryBack, kaHistoryForward,
     kaValueOrigin, kaReverseOrigin: true
  else: false

proc refreshMenuForKeymap*(rt: TuiRuntime)
  ## FORWARD-DECLARED for `:keys`; defined with the top bar below.

const EventLogColumnVerbs* = ["columns", "column-show", "column-hide",
                              "column-left", "column-right", ColumnWidthVerb]
const WatchVerbs* = ["watch", "unwatch", "watch-edit"]
  ## PLAT-51: the watch verbs (`runPromptLine`).
  ## PLAT-49 part B: the event log's column verbs (`runColumnVerb`).

proc describeColumns(c: EventLogColumns): string =
  var parts: seq[string] = @[]
  for col in c.order:
    parts.add (if c.isVisible(col): "" else: "(") & eventLogColumnTitle(col) &
              (if c.isVisible(col): "" else: ")")
  "event log columns: " & parts.join(" ") & " — hidden in parentheses"

proc rememberEventLogWidths(rt: TuiRuntime): string =
  ## PLAT-70 Part B: the Event Log's widths into the remembered document
  ## (Horizontal-Overflow.md §5.2, HO-9); "" when written or not kept.
  if rt.saveColumnWidths.isNil: ""
  else: rt.saveColumnWidths(EventLogTableName,
                            rt.app.eventLog.columns.columnWidthEntries)

proc describeWidth(rt: TuiRuntime; col: EventLogColumn): string =
  let failure = rt.rememberEventLogWidths()
  "event log column " & eventLogColumnTitle(col) & ": " &
    $rt.app.eventLog.columns.widths[col] & " cells" &
    (if failure.len > 0: " (" & failure & ")" else: "")

proc runColumnVerb*(rt: TuiRuntime; verb, arg: string): string =
  ## One column verb against the event log's `EventLogColumns`; answers the
  ## status line's text (every verb says what it did, or why it did nothing).
  if verb == "columns":
    return describeColumns(rt.app.eventLog.columns)
  if verb == ColumnWidthVerb:
    # PLAT-70 Part B (Horizontal-Overflow.md §5.2): `:column-width <title>
    # <cells>`, never narrower than `MinColumnCells`.
    let parsed = parseColumnWidthLine(@[verb] & arg.splitWhitespace)
    if not parsed.ok:
      return parsed.message
    discard rt.app.eventLog.columns.setColumnWidth(parsed.column, parsed.cells)
    return rt.describeWidth(parsed.column)
  if arg.len == 0:
    return ":" & verb & " needs a column: tick, #, location, kind or output"
  let (ok, col) = parseEventLogColumn(arg)
  if not ok:
    return "no event log column '" & arg &
           "'; the columns are tick, #, location, kind and output"
  var c = rt.app.eventLog.columns
  let changed =
    case verb
    of "column-show": c.showColumn(col)
    of "column-hide": c.hideColumn(col)
    of "column-left": c.moveColumn(col, -1)
    else: c.moveColumn(col, 1)
  if not changed:
    return "event log column " & eventLogColumnTitle(col) & ": " &
      (case verb
       of "column-show": "already shown"
       of "column-hide":
         (if not c.isVisible(col): "already hidden"
          else: "the last visible column stays")
       else: (if not c.isVisible(col): "hidden; show it first"
              else: "already at that end"))
  rt.app.eventLog.columns = c
  describeColumns(c)

proc applyLayoutSetting*(rt: TuiRuntime; which: LayoutSetting; value: string;
                         remember = true): string =
  ## PLAT-51 deliverables 9 and 11, PLAT-70 Part H: set one layout setting —
  ## the focus highlight, live resize, the overflow markers, a scrollbar
  ## option — for this session and, from a command rather than a CLI flag,
  ## REMEMBER it (`savePreference`, beside the remembered layout). `value` is
  ## the setting's word (`on`, `thick` …). Answers the status line's text.
  var current = LayoutSettings(scrollbars: rt.scrollbars.options)
  if not current.assignValue(which, value):
    return "'" & value & "' is not a value of " & $which
  let on = value == "on"
  if which.isTerminalSetting:
    # PLAT-71: a TERMINAL setting is a rank of the capability profile
    # (Terminal-Adaptation §5.2): the host re-resolves, and the screen is
    # repainted from the new profile. `modern-unicode` among them (OQ-T9).
    if rt.terminalService.isNil or rt.terminalService.setChoice.isNil:
      return describe(which, value) & " (no terminal to apply it to)"
    result = rt.terminalService.setChoice(which, value)
    for pane in PaneKind:
      rt.scrollbars.fades[pane].wake(rt.scrollbars.clockMs)
    if remember:
      let saved =
        if rt.savePreference.isNil: "not remembered: this session keeps no state"
        else: rt.savePreference($which, value)
      if saved.len > 0:
        result.add " (" & saved & ")"
    return
  case which
  of lsFocusHighlight:
    rt.app.focusHighlightOff = not on
  of lsLiveResize:
    if not rt.app.layoutBinding.isNil:
      rt.app.layoutBinding.liveResize = on
  of lsOverflowMarkers:
    rt.app.overflowMarkersOff = not on
  of lsModernUnicode, lsGlyphs, lsAmbiguousWidth, lsColors,
     lsTerminalProbe, lsReduceMotion, lsTerminalHints:
    discard
  of lsScrollbarThickness, lsScrollbarFade, lsScrollbarTrack,
     lsScrollbarClick:
    rt.scrollbars.options = current.scrollbars
    # A changed option shows on every bar at once.
    for pane in PaneKind:
      rt.scrollbars.fades[pane].wake(rt.scrollbars.clockMs)
  result = describe(which, value)
  if remember:
    let saved =
      if rt.savePreference.isNil: "not remembered: this session keeps no state"
      else: rt.savePreference($which, value)
    if saved.len > 0:
      result.add " (" & saved & ")"

proc applyLayoutSetting*(rt: TuiRuntime; which: LayoutSetting; on: bool;
                         remember = true): string =
  ## An on / off setting.
  rt.applyLayoutSetting(which, (if on: "on" else: "off"), remember)

proc chooseKeymap*(rt: TuiRuntime; name: string) =
  ## PLAT-43 / PLAT-68: the base-keymap selector — `:keymap <name>` and the
  ## palette's **Preferences: Select Base Keymap** both land here. The NAME is
  ## decided by `keymap_selection.selectKeymap` and nowhere else — the same
  ## function the stored preference and `--keymap` go through — so an unknown
  ## base (including the retired `default`) is refused by name with the
  ## accepted set rather than silently defaulted. With no name it says which
  ## base is active and why.
  let current = rt.keymapModel
  if name.len == 0:
    let sourced =
      if rt.app.editSession.isNil or rt.app.editSession.imported.isNil: ""
      else: " with " & rt.app.editSession.imported.source & " sourced"
    rt.note("keymap " & $current & " (" & $rt.router.baseSource & ")" &
            sourced & "; the accepted values are " &
            acceptedKeymapNamesText())
    return
  let selection = selectKeymap(name)
  if not selection.ok:
    rt.note(selection.refusal)
    return
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(selection.model, rt.keyDelivery)
  rt.selectBase(selection.model, ksCommand)
  let saved =
    if rt.editServices.saveKeymap.isNil:
      "not remembered: this session keeps no state"
    else: rt.editServices.saveKeymap(selection.model)
  rt.note("keymap " & $selection.model &
          (if saved.len == 0: "" else: " (" & saved & ")"))

# ---------------------------------------------------------------------------
# K19: THE FILES PANE'S MENU — Create, Rename, Delete, Edit
# (codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu")
# ---------------------------------------------------------------------------
#
# The entries, their order and their disabled reasons are the shared Files
# model's (`FilesystemVM.fileTreeMenu`, read as a native menu by
# `headless_app/file_tree_menu`): the replay's tree is the session's model,
# Edit mode's is `TuiApp.editFilesVM` over the opened folder. This terminal
# has no inline name field, so Create and Rename open the command line with
# `create ` / `rename <name>` typed, and Delete — which asks first here — with
# `trash <path>`; Enter answers, Escape cancels. Those three words are read
# ONLY while the model has that field or question open: they are not
# commands (§4.3's table is unchanged), and with nothing open they fall
# through to the interpreter as before.

const
  CreateVerb = "create"
  RenameVerb = "rename"
  TrashVerb = "trash"

proc openContextMenu(rt: TuiRuntime; menu: ContextMenuModel; row, col: int;
                     outcome: var RuntimeOutcome)
  ## Forward-declared: defined with the other click routes below.

proc editTreeRoot*(rt: TuiRuntime): string =
  ## The opened folder Edit mode's Files tree is rooted at, absolute and
  ## without a trailing separator (`projectTreeOf`'s spelling of its row).
  let root = if rt.app.projectRoot.len > 0: rt.app.projectRoot
             else: getCurrentDir()
  result = absolutePath(root).normalizedPath
  while result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc filesMenuVM(rt: TuiRuntime): FilesystemVM =
  ## The Files model the pane's rows belong to: a replay's tree (the
  ## session's), or Edit mode's opened folder.
  if rt.app.fileTree.entries.len > 0: rt.app.filesVM
  else: rt.app.editFilesVM

proc filesRowPath(rt: TuiRuntime; i: int): string =
  ## The Files model's path of row `i` of the pane.
  let t = rt.app.fileTree
  if t.entries.len > 0:
    if i >= 0 and i < t.entries.len: t.entries[i].path else: ""
  elif i >= 0 and i < t.files.len:
    joinTreePath(rt.editTreeRoot(), t.files[i])
  else: ""

proc fileTreeOperationDone*(rt: TuiRuntime; r: FileTreeOperationResult)

proc installProjectListing*(rt: TuiRuntime; listing: EditListResult) =
  ## Edit mode's Files pane over `listing` (the project walk): the rows, and
  ## the Files model the menu decides on. The open file, the selection and
  ## the reader's place are kept where the rows still hold them.
  let old = rt.app.fileTree
  var tree = initFileTreeModel(files = listing.files,
                               selected = (if listing.files.len > 0: 0
                                           else: -1),
                               truncated = listing.truncated)
  tree.openPath = old.openPath
  tree.scrollTop = old.scrollTop
  if old.selected >= 0 and old.selected < old.files.len:
    let at = listing.files.find(old.files[old.selected])
    if at >= 0: tree.selected = at
  rt.app.fileTree = tree
  if rt.app.editFilesVM.isNil:
    let vm = createFilesystemVM(nil)
    # With no host to act on the disk, the opened folder is still the tree,
    # and the menu says nothing carries the operations out.
    let root = proc(): string = rt.editTreeRoot()
    vm.hostFacts = proc(): FileTreeHostFacts =
      FileTreeHostFacts(layout: ToolbarMode.EditMode, openedFolder: root(),
                        hasIndexProcess: false, canTrash: false)
    if not rt.editServices.wireFileTree.isNil:
      rt.editServices.wireFileTree(vm, root,
        proc(r: FileTreeOperationResult) = rt.fileTreeOperationDone(r))
    rt.app.editFilesVM = vm
  rt.app.editFilesVM.setRoot(projectTreeOf(rt.editTreeRoot(), listing.files))

proc openProjectFile(rt: TuiRuntime; relative: string): bool =
  ## Edit mode's K17 (and the Files menu's Edit): the project file in the
  ## editor, as `:e <relative>` opens it.
  if rt.editServices.readFile.isNil:
    rt.note("this session has no reader for " & relative)
    return false
  let opened = rt.editServices.readFile(relative)
  if not opened.ok:
    rt.note(opened.message)
    return false
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(rt.keymapModel, rt.keyDelivery)
  discard rt.app.editSession.openFile(relative, opened.text,
                                      max(1, rt.sourcePaneRows()))
  rt.app.fileTree.openPath = relative
  rt.note("editing " & relative)
  true

proc fileTreeOperationDone*(rt: TuiRuntime; r: FileTreeOperationResult) =
  ## The host's answer to a Create, Rename or Delete: the folder is listed
  ## again (the pane follows the disk), the status line says what changed or
  ## why not, and a new file opens in the editor (Filesystem-Pane.md, "Create
  ## makes an empty file and opens it in the editor"). Open editor tabs are
  ## left alone.
  let root = rt.editTreeRoot()
  if r.error.len == 0 and not rt.editServices.listFiles.isNil:
    rt.installProjectListing(rt.editServices.listFiles())
    let rel = relativeToRoot(root, r.path)
    let at = rt.app.fileTree.files.find(rel)
    if at >= 0 and r.operation != ftaDelete:
      rt.app.fileTree.selected = at
    if r.operation == ftaCreate and rel.len > 0:
      discard rt.openProjectFile(rel)
  rt.note(describeFileTreeOperation(r, root))

proc filesFieldOpen(rt: TuiRuntime): bool =
  ## Whether the Files model has a name field or a Delete question open.
  let vm = rt.filesMenuVM()
  not vm.isNil and (vm.nameEdit.val.kind != fneNone or
                    vm.pendingDelete.len > 0)

proc cancelFilesField(rt: TuiRuntime): string =
  ## Close an open name field or Delete question without acting; what to say.
  let vm = rt.filesMenuVM()
  if vm.isNil:
    return ""
  if vm.pendingDelete.len > 0:
    let kept = entryNameOf(vm.pendingDelete)
    vm.cancelDelete()
    return "kept " & kept
  if vm.nameEdit.val.kind != fneNone:
    let what = nameEditPrompt(vm.nameEdit.val)
    vm.cancelNameEdit()
    return what & ": cancelled"
  ""

proc askOnPrompt(rt: TuiRuntime; question: string) =
  ## Say `question` where it is read while the command line is open: after
  ## the line (`CommandLineModel.message`, which the next edit clears), and
  ## on the status line once it closes.
  rt.prompt.message = question
  rt.note(question)

proc promptForFilesField(rt: TuiRuntime) =
  ## The model opened a name field or asked about Delete: the command line,
  ## with the answer's word typed, and what Enter and Escape do.
  let vm = rt.filesMenuVM()
  if vm.isNil:
    return
  let root = rt.editTreeRoot()
  if vm.pendingDelete.len > 0:
    let rel = relativeToRoot(root, vm.pendingDelete)
    discard rt.openPrompt(pkCommand)
    discard rt.prompt.insert(TrashVerb & " " &
                             (if rel.len > 0: rel else: vm.pendingDelete))
    rt.askOnPrompt(deletePrompt(vm.pendingDelete) &
                   " Enter moves it to the trash, Escape keeps it")
    return
  let edit = vm.nameEdit.val
  case edit.kind
  of fneCreate:
    discard rt.openPrompt(pkCommand)
    discard rt.prompt.insert(CreateVerb & " ")
    rt.askOnPrompt(nameEditPrompt(edit) &
                   " — type its name; Enter creates it, Escape cancels")
  of fneRename:
    discard rt.openPrompt(pkCommand)
    discard rt.prompt.insert(RenameVerb & " " & edit.name)
    rt.askOnPrompt(nameEditPrompt(edit) &
                   " — edit the name; Enter renames it, Escape cancels")
  of fneNone:
    discard

proc runFilesFieldLine(rt: TuiRuntime; text: string): bool =
  ## A submitted command line while the Files model has a field or a
  ## question open: its answer, when the line is one (`create <name>`,
  ## `rename <name>`, `trash …`). Any other line closes the field first and
  ## is run as itself (false).
  if not rt.filesFieldOpen():
    return false
  let vm = rt.filesMenuVM()
  let words = text.splitWhitespace()
  let verb = if words.len > 0: words[0] else: ""
  let rest = if words.len > 0: text.strip()[verb.len .. ^1].strip() else: ""
  if vm.pendingDelete.len > 0 and verb == TrashVerb:
    let asked = vm.pendingDelete
    if vm.confirmDelete():
      if rt.app.notification.len == 0:
        rt.note("moved " & entryNameOf(asked) & " to the trash")
    return true
  let edit = vm.nameEdit.val
  if (edit.kind == fneCreate and verb == CreateVerb) or
     (edit.kind == fneRename and verb == RenameVerb):
    rt.app.notification = ""
    if vm.commitNameEdit(rest):
      if edit.kind == fneRename and rest == edit.name:
        rt.note("the name is unchanged")
    else:
      # The field stays open with its reason (the spec's refused name).
      rt.filesReprompt = verb & " " & rest
      rt.note(vm.nameEdit.val.error)
    return true
  discard rt.cancelFilesField()
  false

proc openFilesMenu(rt: TuiRuntime; i, row, col: int;
                   outcome: var RuntimeOutcome) =
  ## K19: row `i`'s menu, at the cell (`row`, `col`), the row selected.
  let vm = rt.filesMenuVM()
  let path = rt.filesRowPath(i)
  if vm.isNil or (path.len == 0 and rt.app.fileTree.entries.len == 0):
    rt.note("the Files pane has no menu here")
    outcome.repaint = true
    return
  rt.app.fileTree.selected = i
  rt.openContextMenu(vm.fileTreeContextMenuOf(path), row, col, outcome)

proc activateFilesRow(rt: TuiRuntime; i: int; outcome: var RuntimeOutcome) =
  ## K17 / K18 from the keyboard or a press: a file opens, a folder opens or
  ## closes.
  let t = rt.app.fileTree
  rt.app.fileTree.selected = i
  outcome.repaint = true
  if t.entries.len > 0:
    if i < 0 or i >= t.entries.len:
      return
    let e = t.entries[i]
    outcome.paneClick = PaneClickRequest(
      kind: (if e.isFolder: pcToggleFolder else: pcOpenFile), path: e.path)
  elif i >= 0 and i < t.files.len:
    discard rt.openProjectFile(t.files[i])

proc runFilesMenuAction(rt: TuiRuntime; action: ContextAction;
                        target: ContextTarget; outcome: var RuntimeOutcome) =
  ## A chosen Files entry, as the model decides it now.
  let vm = rt.filesMenuVM()
  outcome.repaint = true
  if action == caFileEdit:
    # Opening a file is this front-end's editor: the model is asked only
    # whether the entry acts here.
    let why = vm.fileTreeEntryReason(target.path, action)
    if why.len > 0:
      rt.note(why)
    elif rt.app.fileTree.entries.len > 0:
      outcome.paneClick = PaneClickRequest(kind: pcOpenFile, path: target.path)
    else:
      discard rt.openProjectFile(relativeToRoot(rt.editTreeRoot(),
                                                target.path))
    return
  let why = vm.runFileTreeAction(target.path, action)
  if why.len > 0:
    rt.note(why)
    return
  rt.promptForFilesField()

proc runCommandLine(rt: TuiRuntime; line: string; outcome: var RuntimeOutcome;
                    unknownFallsThrough = false): bool =
  ## One command line, through CTUI-10's interpreter and the verbs beside it —
  ## from the command prompt (`runPromptLine`) or typed into the omnibar after
  ## its `:` (`acceptOmnibar`). Answers whether the line was run: always,
  ## unless `unknownFallsThrough` is set and its verb is no command at all, in
  ## which case NOTHING has happened and the caller decides (the omnibar then
  ## takes its chosen palette entry instead).
  result = true
  if line.strip().len == 0:
    discard rt.cancelFilesField()
    rt.note("")
    return

  # K19: the answer to an open Files name field or Delete question.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    if rt.runFilesFieldLine(text):
      outcome.repaint = true
      outcome.detail = rt.app.notification
      return

  # PLAT-51: `:set focus-highlight on|off`, `:set live-resize on|off` — the
  # two layout preferences (`layout_settings.parseSetLine`), remembered. A
  # separate surface from §4.3 for the reason the layout verbs below give.
  block:
    let sl = parseSetLine(line)
    if sl.isSet:
      outcome.repaint = true
      if not sl.ok:
        rt.note(sl.message)
      else:
        rt.note(rt.applyLayoutSetting(sl.setting, sl.value))
      outcome.detail = rt.app.notification
      return

  # PLAT-71: `:terminal-info` (Terminal-Adaptation §10.1) — the live report
  # and the glyph test card — and `:terminal-info dismiss`, which turns the
  # start-up hint off for good (§10.2).
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and words[0] == "terminal-info":
      outcome.repaint = true
      if words.len > 1 and words[1] == "dismiss":
        rt.note(if rt.terminalService.isNil or
                   rt.terminalService.dismissHints.isNil:
                  "no terminal hints to dismiss in this session"
                else: rt.terminalService.dismissHints())
      elif words.len > 1:
        rt.note(":terminal-info takes nothing or `dismiss`")
      else:
        rt.openTerminalInfo()
      outcome.detail = rt.app.notification
      return

  # PLAT-48's TWO TOP-BAR VERBS, `:icons` and `:keys`. A separate surface
  # from §4.3 for the reason the layout verbs below give (its sixteen
  # commands are a published table), and routed in every product mode.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    # PLAT-57 (CodeTracer-TUI.md §4.3): `:grep <pattern>` searches the
    # recording's sources into Find in Files — nothing opens — and `:grep`
    # alone opens its field; `:cnext` / `:cprev` (`:cn` / `:cp`) open the
    # next / previous result.
    if words.len > 0 and words[0] == "grep":
      if words.len == 1: rt.openFindInFiles(outcome)
      else: rt.runFindInFiles(text[4 .. ^1].strip(), outcome)
      outcome.detail = rt.app.notification
      return
    # PLAT-58 (Request-Panel.md § N.4): `:requests <text>` sets the Requests
    # pane's URL search; `:requests` alone opens its field, and submitted
    # with nothing after the verb (`:requests `) clears the search.
    let requests = requestsCommandOf(line)
    if requests.isRequests:
      # `:requests` alone with a search on CLEARS it (the field opens
      # holding the search; emptied and submitted, it arrives as the bare
      # verb); with none it opens the field.
      if requests.openField and rt.app.requests.search.len == 0:
        rt.openRequestsField(outcome)
      else:
        rt.showPane(paneRequests, outcome)
        discard rt.actOnRequests(RequestsAct(kind: rakSearch,
                                             text: requests.search), outcome)
      outcome.detail = rt.app.notification
      return
    if words.len == 1 and words[0] in ["cnext", "cn", "cprev", "cp"]:
      rt.stepFindInFiles((if words[0] in ["cnext", "cn"]: 1 else: -1),
                         outcome)
      outcome.detail = rt.app.notification
      return
    if words.len > 0 and words[0] in ["icons", "keys"]:
      let arg = if words.len > 1: words[1] else: ""
      if words[0] == "icons":
        if arg.len == 0:
          rt.note("icons " & $rt.app.icons & "; the accepted values are " &
                  iconsModeNames())
        else:
          let (ok, mode) = parseIconsMode(arg)
          if not ok:
            rt.note("unknown icons value '" & arg &
                    "'; the accepted values are " & iconsModeNames())
          else:
            rt.app.icons = mode
            rt.app.iconsChosen = true
            let saved =
              if rt.saveIcons.isNil: "not remembered: this session keeps " &
                                     "no state"
              else: rt.saveIcons(mode)
            var msg = "icons " & $mode
            if mode == imGraphics and not rt.app.graphicsDrawn:
              msg.add " — this terminal did not answer the graphics query, " &
                      "so the controls are drawn as unicode"
            if saved.len > 0:
              msg.add " (" & saved & ")"
            rt.note(msg)
      else:
        # PLAT-68: `keybindings.json` is the one user keymap
        # (Base-Keymaps-And-Layer-Stack.md §3.5), so `:keys` reports it:
        # `:keys` its load summary, `:keys reload` reads it again, and
        # `:keys check` is Help: Check Key Delivery (§7.3). The menu's
        # shortcuts and the controls' tooltips follow a reload at once —
        # they are resolved from the router, never written beside it.
        case arg
        of "":
          rt.note(rt.router.loadSummary)
        of "reload":
          rt.note(if rt.editServices.reloadKeybindings.isNil:
                    "keys: this session keeps no configuration"
                  else: rt.editServices.reloadKeybindings())
        of "check":
          rt.keyCheck = startCheck()
          rt.note("keys check: press keys to see how they arrive; " &
                  "Esc ends the check")
        of "reference":
          rt.showShortcutReference(outcome)
        else:
          rt.note("keys: '" & arg & "' is not a keys verb " &
                  "(reload, check, reference)")
        rt.refreshMenuForKeymap()
      outcome.detail = rt.app.notification
      return

  # PLAT-49 part B (finding 14): THE EVENT LOG'S COLUMN VERBS — the desktop's
  # show / hide / reorder capability, over the Event Log ViewModel's column
  # model (`EventLogColumns`). `:columns` lists them; `:column-show NAME`,
  # `:column-hide NAME`, `:column-left NAME`, `:column-right NAME`.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and words[0] in EventLogColumnVerbs:
      rt.note(rt.runColumnVerb(words[0],
                               (if words.len > 1: words[1 .. ^1].join(" ")
                                else: "")))
      outcome.detail = rt.app.notification
      outcome.repaint = true
      return

  # PLAT-51: THE WATCH VERBS — the desktop's watch field and row controls
  # (Variable-State-Pane.md: watch expressions "add, edit, remove"):
  # `:watch EXPR`, `:unwatch EXPR`, `:watch-edit OLD -> NEW`. Outside §4.3's
  # published table, for the reason the layout verbs below give.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let sp = text.find(' ')
    let verb = if sp < 0: text else: text[0 ..< sp]
    let arg = if sp < 0: "" else: text[sp + 1 .. ^1].strip()
    if verb in WatchVerbs:
      outcome.repaint = true
      if arg.len == 0:
        rt.note(":" & verb & " needs an expression")
      elif verb == "watch":
        outcome.paneClick = (PaneClickRequest(kind: pcWatch, text: arg))
        rt.note("watching " & arg)
      elif verb == "unwatch":
        outcome.paneClick = (PaneClickRequest(kind: pcWatch, path: arg,
                                              behaviour: "remove"))
        rt.note("no longer watching " & arg)
      else:
        let at = arg.find("->")
        if at < 0:
          rt.note(":watch-edit needs OLD -> NEW")
        else:
          let old = arg[0 ..< at].strip()
          let now = arg[at + 2 .. ^1].strip()
          outcome.paneClick = (PaneClickRequest(kind: pcWatch, path: old,
                                                text: now, behaviour: "edit"))
          rt.note("watching " & now & " instead of " & old)
      outcome.detail = rt.app.notification
      return

  # PLAT-6's TWELVE LAYOUT VERBS, ROUTED HERE AND ONLY WHEN A BINDING IS
  # ENABLED. This is the line that makes a layout gesture reachable from the
  # product's own input path rather than from a test that constructs a
  # `LayoutBinding` directly, and it is what a Tier-2 case can drive through a
  # real pty.
  #
  # A SEPARATE SURFACE FROM §4.3, deliberately and structurally — see
  # `binding.LayoutVerb`: §4.3's sixteen commands are a published table
  # `app/tests/test_gdb_command_surface.nim` parses out of `CodeTracer-TUI.md`
  # and compares row by row, so a seventeenth value in that enum is a failing
  # test by construction. The routing is therefore a PREFIX on this path rather
  # than an entry in that table.
  #
  # WITH NO BINDING NOTHING CHANGES: `:move-tab` falls through to `runCommand`
  # and is reported as the unknown command it has always been, which is the
  # behaviour every existing suite asserts.
  if rt.layoutBindingEnabled():
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and parseLayoutVerb(words[0])[0]:
      # The pane a layout verb acts on is THE ONE `Tab` AND `Ctrl+w` MOVED TO.
      # Synchronised here rather than kept in step by convention, so `:dock
      # bottom` cannot dock a pane other than the focused one.
      let (had, focused) = rt.focus.focusedPane()
      if had:
        rt.app.layoutBinding.focus = focused
      let acted = rt.app.layoutBinding.runLayoutCommand(rt.layoutGeometry(),
                                                        line)
      outcome.detail = acted.message
      rt.note(acted.message)
      if acted.status == lasApplied:
        rt.afterLayoutCommit()
      # A layout command can take a pane off the screen (`:dock`) or put one
      # back (`:undock`), so the focus ring is re-derived from the arrangement
      # the next frame will paint rather than from the one before the command.
      rt.rebuildFocus()
      return

  # PLAT-16's FIVE EDIT VERBS, ROUTED HERE AND ONLY IN EDIT MODE.
  #
  # A SEPARATE SURFACE FROM §4.3, on exactly the argument PLAT-6's block above
  # makes and for exactly the same structural reason: §4.3's sixteen commands
  # are a published table `app/tests/test_gdb_command_surface.nim` parses out of
  # `CodeTracer-TUI.md` and compares row by row, so a seventeenth entry there is
  # a failing test by construction. `:build`, `:run`, `:cancel`, `:w` and `:e`
  # come from CodeTracer-TUI-Edit-Mode.md §5 instead, and they are a PREFIX on
  # this path.
  #
  # IN DEBUG MODE NOTHING CHANGES: they fall through to `runCommand` and are
  # reported as the unknown commands they have always been.
  if rt.app.modes.product == pmEdit:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    let verb = if words.len > 0: words[0] else: ""
    let rest = if words.len > 1: text[text.find(words[1]) .. ^1] else: ""
    case verb
    of "keymap":
      rt.chooseKeymap(rest)
      outcome.detail = rt.app.notification
      return
    of "break", "b":
      # §4.3's `:break`, in Edit mode: the same toggle `F9` makes, at the
      # caret or at the line given. A function name — which Debug mode
      # resolves against the recording — has nothing to resolve against here,
      # and is refused by name rather than guessed.
      let buf = if rt.app.editSession.isNil: nil
                else: rt.app.editSession.activeBuffer()
      if buf.isNil:
        rt.note("no file is open to place a breakpoint in")
      else:
        var line = buf.caretLine
        var ok = true
        if rest.len > 0:
          try:
            line = parseInt(rest)
          except ValueError:
            ok = false
            rt.note("`" & rest & "` is not a line number; in Edit mode " &
                    ":break takes a line of " & buf.path)
        if ok and (line < 1 or line > buf.lineCount):
          ok = false
          rt.note(buf.path & " has no line " & $line)
        if ok:
          let placed = rt.app.editSession.togglePointAt(buf.path, line)
          rt.note((if placed: "breakpoint at " else: "removed the breakpoint at ") &
                  buf.path & ":" & $line)
      outcome.detail = rt.app.notification
      return
    of "source", "so":
      # PLAT-36. A user's Vim configuration, imported on top of the Vim
      # keymap and installed for THIS SESSION. Not remembered: the stored
      # preference names a model, and an import is a model plus a file whose
      # contents may change — re-reading it silently at start-up would make
      # a key's meaning depend on a file the user did not name that day.
      # The status line carries §6.3's count and the first untranslated line.
      if rest.len == 0:
        rt.note(":source needs a file, e.g. ':source ~/.vimrc'")
      elif rt.editServices.readConfig.isNil:
        rt.note(":source has no reader in this session")
      else:
        let read = rt.editServices.readConfig(rest)
        if not read.ok:
          rt.note(read.message)
        else:
          let sourced = sourceVimConfig(rest, read.text)
          if rt.app.editSession.isNil:
            rt.app.editSession = newEditSession(bkVim, rt.keyDelivery)
          rt.app.editSession.installImported(sourced.imported)
          rt.router.switchBase(bkVim, ksCommand)
          rt.router.importedEditor = sourced.imported.keymap
          rt.router.hasImported = true
          rt.note(sourcedSummary(sourced))
      outcome.detail = rt.app.notification
      return
    of "w", "write":
      rt.writeBuffers(":w")
      outcome.detail = rt.app.notification
      return
    of "e!", "edit!":
      # PLAT-29. Vim's `:e!`: reload the open file from disk. The read is a
      # producer — see `file_io_producer` — so a reload the user typed past
      # while it was in flight is discarded and SAID so, never installed
      # over the typing; one that lands on an unmoved buffer replaces its text
      # through the editing core, where it can be undone.
      let buf = if rt.app.editSession.isNil: nil
                else: rt.app.editSession.activeBuffer()
      if buf.isNil:
        rt.note(":e! needs an open file")
      else:
        rt.note("reloading " & buf.path & "…")
        rt.runFileJob(fileJobFor(fjRead, buf.doc, buf.path, buf.serial))
      outcome.detail = rt.app.notification
      return
    of "e", "edit":
      if rest.len == 0:
        rt.note(":e needs a project-relative path")
      elif rt.editServices.readFile.isNil:
        rt.note(":e has no reader in this session")
      else:
        let opened = rt.editServices.readFile(rest)
        if opened.ok:
          if rt.app.editSession.isNil:
            rt.app.editSession = newEditSession(rt.keymapModel, rt.keyDelivery)
          discard rt.app.editSession.openFile(
            rest, opened.text, max(1, rt.sourcePaneRows()))
          rt.app.fileTree.openPath = rest
          rt.note("editing " & rest)
        else:
          rt.note(opened.message)
      outcome.detail = rt.app.notification
      return
    of "build", "run":
      if rest.len == 0:
        rt.note(":" & verb & " needs a command, e.g. ':" & verb &
                " just build'")
      elif rt.editServices.startBuild.isNil:
        rt.note(":" & verb & " has no runner in this session")
      elif not rt.app.build.isNil and rt.app.build.verdict == bvRunning:
        # ONE AT A TIME, and refused rather than queued: two compilers writing
        # into one pane produce interleaved output that belongs to neither, and
        # the verdict would be whichever finished last.
        rt.note("a " & $rt.app.build.kind & " is already running; :cancel it" &
                " first")
      else:
        let kind = if verb == "build": bkBuild else: bkRun
        let started = rt.editServices.startBuild(kind, rest)
        rt.note(started.message)
      outcome.detail = rt.app.notification
      return
    of "cancel":
      if rt.app.build.isNil or rt.app.build.verdict != bvRunning:
        rt.note("nothing is running")
      else:
        # THE FLAG, NOT A KILL. `app/` does not own the process; the host's
        # poll loop reads this on its next tick and terminates it, which is
        # what keeps the cancellation inside the same loop that reads the
        # keyboard. See `host/build_runner.pollBuild`.
        rt.app.build.requestCancel()
        rt.note("cancelling " & $rt.app.build.kind & " …")
      outcome.detail = rt.app.notification
      return
    else:
      discard

  if unknownFallsThrough and parseCommand(line).status == csUnknown:
    return false

  # PLAT-50: "Add tracepoint" on an editor line chose WHERE the next
  # `:tracepoint` goes (the desktop's tracepoint editor opens on that line);
  # any other command forgets it.
  var context = rt.context
  if rt.app.tracepointAt.path.len > 0:
    let verb = line.strip().strip(chars = {':'}).splitWhitespace()
    if verb.len > 0 and verb[0] == "tracepoint":
      context.file = rt.app.tracepointAt.path
      context.line = rt.app.tracepointAt.line
    rt.app.tracepointAt = ("", 0)
  let ran = runCommand(rt.dispatcher, context, line)
  outcome.detail = ran.message
  var text = describeOutcome(ran)
  if text.len == 0:
    text = ran.message
  for extra in ran.lines:
    text.add "  |  " & extra
  rt.note(text)
  # THE ACTION THE COMMAND RESOLVED TO IS CARRIED OUT, so `handleToken` can
  # route it exactly as it routes the same action arriving as a KEY.
  #
  # CTUI-14 found the defect this closes, and `tests/real_terminal/
  # test_real_pty_lifecycle.nim` is what found it: §4.3 publishes `quit` (alias
  # `q`), `interpreter.dispatchAction` answered `drDone` for it, the status bar
  # said `quit` — and the session carried on, because ENDING THE LOOP IS NOT
  # SOMETHING THE DISPATCHER CAN DO. `kaQuit` is a local action; the loop that
  # stops is `main.nim`'s, and only `applyLocalAction` reaches it. The key path
  # (`q`, `Ctrl+c`) always went through there and always worked, which is why a
  # published command was broken behind two working keys.
  outcome.action = ran.dispatch.action
  # ONLY A NAVIGATION IS PUMPED. This said `drDone` alone until 2026-09-23,
  # which was harmless while every command that answered `drDone` moved the
  # debugger; `:break` answering `drDone` (its service is now wired) would have
  # blocked the loop on a `stopped` event no engine sends — see
  # `movesTheDebugger` on why that is a hang rather than a wrong screen.
  if ran.dispatch.status == drDone:
    outcome.awaitsMove = movesTheDebugger(outcome.action)
    outcome.refreshesSession = changesSessionState(outcome.action)
    # PLAT-50: an origin query is not a move (`awaitsOrigin`).
    if outcome.action == kaValueOrigin and
       ran.message.startsWith(OriginPendingText):
      outcome.awaitsMove = false
      outcome.awaitsOrigin = true
      outcome.originRetry = line

proc runPromptLine(rt: TuiRuntime; line: string;
                   outcome: var RuntimeOutcome) =
  ## A committed prompt line.
  ##
  ## Search prompts do not reach the interpreter: `/pattern` is not a §4.3
  ## command, and handing it to `parseCommand` would report "unknown command
  ## pattern" for a perfectly good search. It is reported as an unbuilt seam
  ## instead, by name — CTUI-10 built the incremental search MODEL
  ## (`app/views/search.nim`) and no pane in the shell binds it yet.
  if rt.prompt.kind != pkCommand:
    # PLAT-70 Part C: the field committed is the session accepted (the
    # prompt itself already closed).
    let buf = rt.editorBuffer()
    if not buf.isNil and rt.app.find.open:
      let reveal = rt.app.find.accept(buf.doc)
      rt.revealFind(buf, reveal, outcome)
    return
  discard rt.runCommandLine(line, outcome)

const CallTraceWheelRows* = 3
  ## Rows one wheel notch scrolls the call trace — the common terminal
  ## default (xterm, VTE and tmux all scroll three lines a notch).

proc scrollCallTrace(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-47: scroll the call trace by `delta` rows (down is positive), from
  ## where it is drawn now, and stop following the current call. The host
  ## loads the section the pane then shows (`RuntimeOutcome.pagesCallTrace`),
  ## as the desktop's calltrace pane loads a section when it is scrolled.
  let body = max(1, rt.paneBodyRows(paneCalltrace))
  let m = rt.app.callTrace
  let top = m.clampTop(m.visibleTop(body) + delta, body)
  rt.app.callTrace.scrollTop = top
  rt.app.callTraceAtEnd = false
  rt.app.callTrace.follow = false
  rt.app.callTraceScrolled = true
  outcome.pagesCallTrace = true
  outcome.repaint = true
  rt.note("call trace " & $(top + 1) & "-" & $min(m.total, top + body) &
          " of " & $m.total)

const GestureInteractions = {ikDraggingTab, ikResizingSplit}
  ## A drag or a resize: gestures whose progress the status line narrates.
const MouseNoteStatuses* = {lasRefused, lasBadArgument, lasUnknownCommand}
  ## PLAT-49 part B: the outcomes of a MOUSE gesture the status line reports —
  ## the ones whose result is not on the screen. A click, a drag, a drop, a
  ## resize or a reveal that worked is visible and says nothing.

# ---------------------------------------------------------------------------
# PLAT-50: CLICKS IN PANES — the desktop's click behaviours
# (`headless_app/pane_clicks.ClickInventory`)
# ---------------------------------------------------------------------------

proc applyLocalAction(rt: TuiRuntime; action: KeyAction;
                      outcome: var RuntimeOutcome): bool
  ## Forward-declared for the tab menu's "Maximise container".

proc shellScreenOf*(rt: TuiRuntime): ShellScreen
  ## FORWARD-DECLARED for the top bar's and the panes' hit-testing, which
  ## read the cells the next frame is painted with; defined with the other
  ## screen readers.

proc paneUnderStrip(geometry: LayoutGeometry; idx: int): CellArea =
  ## The rectangle a pane's painter is handed (`shell.paintPane`'s `under`):
  ## from its strip's row, its box's width and height. Its first row is the
  ## painter's heading, which the strip covers; its content starts below.
  let region = geometry.projection.regions[idx]
  let frame = paneFrame(region.area, geometry.body)
  CellArea(col: region.area.col, row: region.area.row,
           width: frame.box.width, height: frame.box.height)

proc openContextMenu(rt: TuiRuntime; menu: ContextMenuModel; row, col: int;
                     outcome: var RuntimeOutcome) =
  ## A right-click's menu, at the cell pressed.
  rt.app.contextMenu.openAt(menu, row, col)
  rt.app.menu.close()
  outcome.repaint = true

proc requestClick(outcome: var RuntimeOutcome; request: PaneClickRequest) =
  outcome.paneClick = request
  outcome.repaint = true

# ---------------------------------------------------------------------------
# PLAT-52: the Terminal Output pane — K32 and its scrubbers
# ---------------------------------------------------------------------------

const TerminalWheelRows* = 3

proc terminalOutputArea(rt: TuiRuntime; geometry: LayoutGeometry): CellArea =
  ## The rectangle the Terminal Output pane is painted into (its strip row
  ## first), or an empty one when it is not on the screen.
  for i, region in geometry.projection.regions:
    if region.pane == paneTerminalOutput:
      return paneUnderStrip(geometry, i)
  CellArea()

proc terminalOutputRows*(rt: TuiRuntime): int =
  ## How many lines the Terminal Output's line view shows on the current
  ## screen — what its viewport reports (Viewport-Driven-Loading Q3); 0 when
  ## the pane is not on the screen.
  let area = rt.terminalOutputArea(rt.paintedGeometry())
  if area.width <= 0:
    return 0
  terminalPaneGeometry(rt.app.terminalOutput, area).contentRows

proc terminalWriteJump(rt: TuiRuntime; write: int;
                       outcome: var RuntimeOutcome): bool =
  ## Go to the moment write `write` was produced: the host's `ct/event-jump`
  ## (`pcEventJump`), the desktop's fragment click (K32).
  let m = rt.app.terminalOutput
  var ev: TerminalOutputEvent
  if not m.screen.isNil and write >= 0 and write < m.screen.writes.len:
    ev = m.screen.writes[write]
  elif not m.writeOf.isNil:
    # The line view's writes are not loaded: the held lines name them.
    ev = m.writeOf(write)
    if ev.eventIndex < 0:
      return false
  else:
    return false
  outcome.requestClick(PaneClickRequest(
    kind: pcEventJump, index: ev.logIndex, tick: ev.rrTicks, path: ev.path,
    line: ev.line))
  true

proc scrollTerminalOutput(rt: TuiRuntime; delta: int;
                          outcome: var RuntimeOutcome) =
  ## Scroll the line view by `delta` rows (wheel, keys), leaving follow.
  let area = rt.terminalOutputArea(rt.paintedGeometry())
  let geo = terminalPaneGeometry(rt.app.terminalOutput, area)
  let rows = max(1, geo.contentRows)
  let m = rt.app.terminalOutput
  let top = max(0, min(max(0, m.lineCount - rows), m.visibleTop(rows) + delta))
  rt.app.terminalOutput.scrollTop = top
  rt.app.terminalOutput.follow = false
  rt.app.terminalOutput.ensureShown(rows)
  outcome.repaint = true

proc scrubTerminalScreen(rt: TuiRuntime; area: CellArea; col: int;
                         outcome: var RuntimeOutcome) =
  ## The screen's built-in scrubber held at column `col`. REAL-TIME (the
  ## user, 2026-10-06; Terminal-Output-Pane.md §3): the debugger moves to the
  ## write under the pointer as it is dragged — one jump per write crossed —
  ## and the screen shows that write while the move is made.
  let m = rt.app.terminalOutput
  if m.screen.isNil:
    return
  let geo = terminalPaneGeometry(m, area)
  let f = fractionAt(col - geo.screenTrackCol, geo.screenTrackWidth)
  let w = writeAtFraction(m.screen.writeCount, f)
  if w < 0:
    return
  rt.app.terminalOutput.shownWrite = w
  rt.app.terminalOutput.previewing = true
  if w != m.scrubSent:
    rt.app.terminalOutput.scrubSent = w
    discard rt.terminalWriteJump(w, outcome)
  outcome.repaint = true

proc endTerminalScrub(rt: TuiRuntime) =
  rt.app.terminalOutput.previewing = false
  rt.app.terminalOutput.scrubSent = -1

proc pointerCellX(event: MouseEvent; fallback = -1.0): float =
  ## PLAT-70: the pointer's column in fractional cells when the terminal
  ## reports pixels (SGR-pixel, DECSET 1016), else `fallback`.
  if event.pixel: event.px / mouseMetrics().cellW else: fallback

proc routeTerminalOutputClick(rt: TuiRuntime; area: CellArea;
                              event: MouseEvent;
                              outcome: var RuntimeOutcome): bool =
  ## A press in the Terminal Output pane: the toggle, a fragment (K32), the
  ## line view's scrubber, the screen's scrubber. The desktop has no menu on
  ## the pane, so a right press is not taken.
  if event.button != mbLeft or not rt.app.terminalOutput.loaded:
    return false
  let hit = rt.app.terminalOutput.terminalOutputHitAt(
    area, event.row, event.col, event.pointerCellX)
  case hit.kind
  of thNone, thScreen:
    return false
  of thCorner:
    # PLAT-70 (HO-7): the cell between the two tracks belongs to neither.
    discard
  of thHBarTrack, thHBarThumb, thLineTrack, thLineThumb:
    # PLAT-70 Part H: the line view's two scrollbars are every bar's
    # (`routeScrollbars` took the press before the pane saw it).
    discard
  of thViewLines:
    outcome.requestClick(PaneClickRequest(kind: pcTerminalView,
                                          text: $tvLines))
  of thViewScreen:
    outcome.requestClick(PaneClickRequest(kind: pcTerminalView,
                                          text: $tvScreen))
  of thFragment:
    return rt.terminalWriteJump(hit.eventIndex, outcome)
  of thScreenTrack:
    rt.app.terminalDrag = tdScreen
    rt.app.terminalOutput.scrubSent = -1
    rt.scrubTerminalScreen(area, event.col, outcome)
  true

proc routeTerminalDrag(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## A press held on one of the pane's scrubbers owns the pointer until it is
  ## released: the line view's thumb follows it (the view, never the
  ## debugger); the screen's scrubber moves the debugger LIVE to the write
  ## under it (§3, real-time), and the release ends the drag there.
  if rt.app.terminalDrag == tdNone:
    return false
  let kind = rt.app.terminalDrag
  if event.kind == mekPress:
    rt.app.terminalDrag = tdNone
    if kind == tdScreen:
      rt.endTerminalScrub()
    return false
  let area = rt.terminalOutputArea(rt.paintedGeometry())
  if event.kind == mekMotion:
    case kind
    of tdScreen: rt.scrubTerminalScreen(area, event.col, outcome)
    of tdNone: discard
    return true
  # The release: the screen's drag ends on the write under the pointer.
  rt.app.terminalDrag = tdNone
  if kind == tdScreen:
    rt.scrubTerminalScreen(area, event.col, outcome)
    rt.endTerminalScrub()
  outcome.repaint = true
  true

proc scrubFrameViewer(rt: TuiRuntime; col: int; behaviour: string;
                      outcome: var RuntimeOutcome) =
  ## The frame viewer's scrubber at column `col`: the pane shows the frame
  ## under the pointer at once, and the host is asked for it — once per
  ## frame crossed while held, and once more where it is released.
  let geometry = rt.layoutGeometry()
  let area = frameViewerOverlayArea(geometry.body)
  let f = rt.app.frameViewer.frameAtColumn(area, col)
  if f < 0:
    return
  let moved = f != rt.app.frameViewer.frameIndex
  rt.app.frameViewer.frameIndex = f
  if moved or behaviour == "release":
    outcome.requestClick(PaneClickRequest(kind: pcFrameSeek, index: f,
                                          behaviour: behaviour))
  outcome.repaint = true

proc routeFrameViewerMouse(rt: TuiRuntime; event: MouseEvent;
                           outcome: var RuntimeOutcome): bool =
  ## PLAT-51 (CodeTracer-TUI-Graphics.md §4): the open frame viewer's OWN
  ## scrubber, along its bottom row. A press on it jumps there and holds
  ## the scrubber; motion while held follows the pointer; the release
  ## settles on the frame under it.
  if not rt.app.frameViewer.open:
    return false
  if rt.app.frameViewer.scrubbing:
    case event.kind
    of mekMotion:
      rt.scrubFrameViewer(event.col, "drag", outcome)
    of mekRelease:
      rt.app.frameViewer.scrubbing = false
      rt.scrubFrameViewer(event.col, "release", outcome)
    else:
      rt.app.frameViewer.scrubbing = false
      return false
    return true
  if event.kind != mekPress or event.button != mbLeft:
    return false
  let area = frameViewerOverlayArea(rt.layoutGeometry().body)
  let row = rt.app.frameViewer.frameScrubberRow(area)
  if row < 0 or event.row != row or event.col < area.col or
     event.col >= area.col + area.width:
    return false
  rt.app.frameViewer.scrubbing = true
  rt.scrubFrameViewer(event.col, "drag", outcome)
  true

proc terminalOutputOwnsToken*(rt: TuiRuntime; token: string): bool =
  ## The pane's own keys while it is focused: in the SCREEN view Left / Right
  ## step a write back / forward (Terminal-Output-Pane.md §3's "step-by-write
  ## keys ... scoped to the pane", the desktop's screen keys); `v` toggles
  ## lines / screen. In the LINE view the arrows are the view's
  ## (Horizontal-Overflow.md §4.4: the pane has no caret, so `Left` / `Right`
  ## scroll it sideways — `view.scroll-left` / `-right`, through the router).
  let (had, focused) = rt.focus.focusedPane()
  if not had or focused != paneTerminalOutput or
     not rt.app.terminalOutput.loaded:
    return false
  let key = rt.keyOf(token)
  key == "v" or
    (key in ["Left", "Right"] and rt.app.terminalOutput.screenShown)

proc routeTokenToTerminalOutput(rt: TuiRuntime; token: string;
                                outcome: var RuntimeOutcome) =
  let m = rt.app.terminalOutput
  case rt.keyOf(token)
  of "v":
    outcome.requestClick(PaneClickRequest(
      kind: pcTerminalView,
      text: (if m.view == tvScreen: $tvLines else: $tvScreen)))
  of "Left", "Right":
    let n = if m.screen.isNil: 0 else: m.screen.writeCount
    let delta = if rt.keyOf(token) == "Left": -1 else: 1
    let at = m.shownWrite
    let target = if at < 0 and delta > 0: 0 else: at + delta
    if n == 0 or target < 0 or target >= n:
      rt.note(if delta < 0: "no earlier write" else: "no later write")
      outcome.repaint = true
      return
    discard rt.terminalWriteJump(target, outcome)
  else: discard

proc showContent(rt: TuiRuntime; title, text: string; diff = false;
                 outcome: var RuntimeOutcome) =
  ## A text over the body (`views/context_menu.ContentOverlay`).
  rt.app.content = ContentOverlay(open: true, title: title, text: text,
                                  diff: diff)
  outcome.repaint = true

proc copyToClipboard(rt: TuiRuntime; text, what: string) =
  ## PLAT-50: hand `text` to the terminal's clipboard (OSC 52, written by the
  ## next frame) and say what was copied, as the desktop's copy does.
  rt.app.clipboard = text
  rt.app.pasteBuffer = text
  # PLAT-71 (Terminal-Adaptation §8): where the profile found no way to the
  # system clipboard — no identity that takes OSC 52, no tmux passing it
  # on — the copy is said to be CodeTracer's own, and where to look.
  if rt.caps.clipboard == ClipboardInAppOnly:
    rt.note("copied " & what & " " & InAppOnlyCopyNote)
  else:
    rt.note("copied " & what)

proc terminalInfoBody*(rt: TuiRuntime): seq[StyledRow] =
  ## What `:terminal-info` shows under its live lines: the report
  ## (`terminal_report.profileReport`, the one renderer `--capabilities`
  ## and `ct doctor terminal` share) and the glyph test card.
  for line in profileReport(rt.caps):
    result.add @[StyledSpan(text: line)]
  result.add @[StyledSpan(text: "")]
  result.add glyphTestCard(rt.caps)

proc handleTerminalInfoToken(rt: TuiRuntime; token: string;
                             outcome: var RuntimeOutcome) =
  ## Every token while `:terminal-info` is open is its own: a key is shown
  ## decoded (the interactive half of the report), a pointer report is shown
  ## as the cell it is over, and the view's few keys act.
  outcome.repaint = true
  let (isMouse, event) = decodeMouse(token)
  if isMouse:
    rt.terminalInfo.pointer = "cell " & $event.col & "," & $event.row &
      (if event.kind == mekPress: " pressed " & $event.button else: "")
    return
  let name = rt.keyOf(token)
  rt.terminalInfo.lastKey = name
  let service = rt.terminalService
  case name
  of "Esc", "q":
    rt.terminalInfo.open = false
  of "Up":
    rt.terminalInfo.scroll = max(0, rt.terminalInfo.scroll - 1)
  of "Down":
    rt.terminalInfo.scroll = min(max(0, rt.terminalInfoBody().len - 1),
                                 rt.terminalInfo.scroll + 1)
  of "r":
    rt.terminalInfo.note =
      if service.isNil or service.rerun.isNil: "no terminal to ask"
      else: service.rerun()
  of "y", "n":
    # §10.3: the answer to "do the Legacy Computing glyphs look right?"
    # sets modern-unicode for THIS terminal only (OQ-T6).
    let value = if name == "y": "on" else: "off"
    rt.terminalInfo.note =
      if service.isNil or service.setForThisTerminal.isNil:
        "this session keeps no state"
      else: service.setForThisTerminal(lsModernUnicode, value)
  of "c":
    rt.copyToClipboard(TerminalInfoCopyText, "an OSC 52 test string")
    rt.terminalInfo.note = "copied '" & TerminalInfoCopyText &
      "' (" & rt.caps.clipboard & "): paste it to check"
  else:
    discard

proc eventRowAt(model: EventLogModel; area: CellArea;
                row: int): (bool, event_log.EventLogRow, EventLogScreen) =
  ## The row painted on `row` when the log is painted into `area` (the
  ## pane's painter, re-run on a scratch grid so the hit is the paint's), and
  ## that screen (its header, for a header press).
  var g = newStyledGrid(area.col + area.width, area.row + area.height)
  let screen = paintEventLog(g, area, model)
  let (ok, hit) = screen.eventRowAtScreen(row)
  (ok, hit, screen)

proc paneAt(geometry: LayoutGeometry; row, col: int):
    tuple[found: bool, region: PaneRegion, under: CellArea] =
  ## The pane painted at `(row, col)` and the rectangle its painter was
  ## handed: a pane of the tiled arrangement, or — PLAT-57 — a docked pane
  ## shown open in its band or revealed over the body, which `shell` paints
  ## through the same `paintPane` (so its box is its whole area).
  # The revealed overlay is painted OVER the arrangement, so it is asked
  # first.
  if geometry.revealing and geometry.reveal.contains(row, col):
    return (true, PaneRegion(pane: geometry.revealPane, area: geometry.reveal,
                             activeTab: -1),
            geometry.reveal)
  let idx = geometry.regionIndexAt(row, col)
  if idx >= 0:
    return (true, geometry.projection.regions[idx],
            paneUnderStrip(geometry, idx))
  if not geometry.openDock.isEmptyArea and geometry.openDock.contains(row, col):
    return (true, PaneRegion(pane: geometry.openDockPane,
                             area: geometry.openDock, activeTab: -1),
            geometry.openDock)

proc paneAreaOf(rt: TuiRuntime; kind: PaneKind): CellArea =
  ## The rectangle pane `kind` is painted into (its strip row first), or an
  ## empty one when it is not on the screen — PLAT-57: a docked pane shown
  ## open or revealed included; a maximized pane's (`paintedGeometry`).
  let geometry = rt.paintedGeometry()
  for i, region in geometry.projection.regions:
    if region.pane == kind:
      return paneUnderStrip(geometry, i)
  if geometry.revealing and geometry.revealPane == kind:
    return geometry.reveal
  if not geometry.openDock.isEmptyArea and geometry.openDockPane == kind:
    return geometry.openDock
  CellArea()

# ---------------------------------------------------------------------------
# PLAT-70: the text panes' horizontal views (Horizontal-Overflow.md §4) — the
# editor (both modes), the Terminal Output line view and Build Output. The
# model is `codetracer_embed.horizontal_scroll` (and the editor's
# `editing_core.followView`); this section only finds where each pane is
# painted, feeds it its width, and routes the wheel, the bar and the keys.
# ---------------------------------------------------------------------------

proc paintedAreaOf(rt: TuiRuntime; kind: PaneKind): CellArea =
  ## The rectangle pane `kind`'s painter is handed this frame (its strip row
  ## first): the maximized pane's under `z`, else `paneAreaOf`'s (a tiled
  ## pane, or a docked one shown open or revealed).
  if rt.maximize.active:
    let body = bodyArea(rt.width, rt.height)
    let projection = projectLayout(
      rt.maximize.layoutFor(selectProfile(rt.width, rt.height)), body)
    for region in projection.regions:
      if region.pane == kind:
        let frame = paneFrame(region.area, body)
        return CellArea(col: region.area.col, row: region.area.row,
                        width: frame.box.width, height: frame.box.height)
    return CellArea()
  rt.paneAreaOf(kind)

proc editorPaneModel(rt: TuiRuntime; model: var ShellModel; follow: bool) =
  ## The editor's part of a frame's model: PLAT-68's Debug-mode document (its
  ## selection over the recording's source while read-only; the Edit pane
  ## once writable) and PLAT-70's horizontal view — the content width and the
  ## pane's code width brought up to date and, when `follow`, the caret
  ## followed (§4.5) — before the frame is painted from it.
  if rt.app.modes.product == pmDebug and not rt.app.editSession.isNil:
    let at = rt.app.editSession.indexOfPath(rt.app.source.path)
    if at >= 0:
      let buf = rt.app.editSession.buffers[at]
      if buf.doc.isReadOnly:
        model.source.selected = selectedCells(buf)
      else:
        model.editorWritable = true
        model.edit = editPaneModelFor(rt.app.editSession, buf)
  let buf = rt.editorBuffer()
  if buf.isNil:
    return
  let editShown = model.product == pmEdit or model.editorWritable
  if not editShown and model.source.path != buf.path:
    return
  let area = rt.paintedAreaOf(paneEditor)
  # M73: the read-only pane's code columns are the painter's own
  # (`sourceCodeWidth`), one fewer while its vertical bar is shown — so the
  # view is measured against the cells the code is really drawn in.
  var probe = model.source
  probe.hview = buf.hview
  let cols = if area.width <= 0: buf.hview.viewportCols
             elif editShown: max(0, area.width - paneGutterWidth(model.edit))
             else: probe.sourceCodeWidth(area)
  if follow:
    # The first frame that knows the pane's width follows the caret where
    # it already is; after that only a caret move does (§4.5).
    if buf.hview.viewportCols == 0 and cols > 0:
      buf.follow.armed = false
    discard buf.doc.followView(buf.hview, buf.follow, cols)
  let markers = not rt.app.overflowMarkersOff
  # PLAT-70 Part C (Find-And-Incremental-Search.md §3.3 step 4): the find
  # session's highlights on the lines this frame draws, from the shared
  # session — the editor's own surface, not an overlay.
  let rows = max(1, area.height)
  let first = if editShown: max(1, buf.viewportTop)
              else: max(1, rt.app.source.viewportTop)
  var marks: seq[tuple[line, fromColumn, toColumn: int; current: bool]] = @[]
  for m in rt.app.find.marksInWindow(buf.doc, first, rows):
    marks.add (m.line, m.fromColumn, m.toColumn, m.current)
  if editShown:
    model.edit.hview = buf.hview
    model.edit.caretViewColumn = buf.doc.caretViewColumn
    model.edit.overflowMarkers = markers
    model.edit.selected = selectedCells(buf)
    model.edit.findMarks = marks
  else:
    model.source.hview = buf.hview
    model.source.caretViewColumn = buf.doc.caretViewColumn
    model.source.overflowMarkers = markers
    model.source.findMarks = marks

proc syncOutputViews(rt: TuiRuntime) =
  ## The output panes' widths, before a frame: Build Output's content (the
  ## widest line measured so far of this build) and both panes' text widths
  ## where they are painted. A pane not on the screen keeps its last width.
  rt.app.buildView.measureContent(rt.app.currentBuildPane())
  let b = rt.paintedAreaOf(paneBuildOutput)
  if b.width > 0:
    rt.app.buildView.hview.setViewport(b.width)
  let t = rt.paintedAreaOf(paneTerminalOutput)
  if t.width > 0:
    let geo = terminalPaneGeometry(rt.app.terminalOutput, t)
    rt.app.terminalOutput.hview.setViewport(geo.textWidth)

const TableViewPanes = {paneEventLog, paneCalltrace, paneState}
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5): the table panes, whose
  ## columns scroll sideways when their floors do not fit.

proc tableViewOf(rt: TuiRuntime; pane: PaneKind):
    tuple[shown: bool; row, left, cols: int; view: HorizontalView] =
  ## A table pane's horizontal view this frame, settled over its fit, and
  ## where its bar is — the painters' own geometry functions, so the wheel,
  ## the bar and the drawing read one decision.
  let area = rt.paintedAreaOf(pane)
  if area.width <= 0 or area.height <= 0:
    return
  case pane
  of paneEventLog:
    if not rt.app.eventLog.hasContent: return
    let geo = rt.app.eventLog.eventLogGeometry(area)
    (geo.barRow >= 0, geo.barRow, area.col, geo.width, geo.view)
  of paneCalltrace:
    if rt.app.callTrace.isEmpty: return
    let geo = rt.app.callTrace.callTraceGeometry(area)
    (geo.barRow >= 0, geo.barRow, area.col, geo.rowWidth, geo.view)
  of paneState:
    if rt.app.variables.isEmpty: return
    let geo = rt.app.variables.variablesGeometry(area)
    (geo.barRow >= 0, geo.barRow, area.col, geo.width, geo.view)
  else: (false, -1, 0, 0, HorizontalView())

proc storeTableView(rt: TuiRuntime; pane: PaneKind; v: HorizontalView) =
  case pane
  of paneEventLog: rt.app.eventLog.hview = v
  of paneCalltrace: rt.app.callTrace.hview = v
  of paneState: rt.app.variables.hview = v
  else: discard

proc syncTableViews(rt: TuiRuntime) =
  ## PLAT-70 Part I: each table pane's view settled over this frame's fit
  ## before the frame is painted — so a pane widened until its columns fit
  ## comes back at column 0, and is there when its bar next appears (§4.1).
  for pane in TableViewPanes:
    let area = rt.paintedAreaOf(pane)
    if area.width <= 0:
      continue
    let t = rt.tableViewOf(pane)
    if t.cols > 0:
      rt.storeTableView(pane, t.view)

proc horizontalViewPane(rt: TuiRuntime; pane: PaneKind): bool =
  ## Whether `pane` is a text pane with a horizontal view now (§4.1): the
  ## editor with a document, the Terminal Output's LINE view (the screen
  ## view has no bar, OQ-H3), Build Output.
  case pane
  of paneEditor: not rt.editorBuffer().isNil
  of paneTerminalOutput: rt.app.terminalOutput.loaded and
                         not rt.app.terminalOutput.screenShown
  of paneBuildOutput: true
  of paneEventLog, paneCalltrace, paneState: rt.tableViewOf(pane).view.overflows
  else: false

proc scrollPaneView(rt: TuiRuntime; pane: PaneKind;
                    step: proc(v: var HorizontalView): bool): bool =
  ## Apply one view step to `pane`'s horizontal view; answers whether it
  ## moved. The caret, the selection and the debugger are not touched
  ## (HO-4): only the view is handed over.
  case pane
  of paneEditor:
    let buf = rt.editorBuffer()
    if buf.isNil: return false
    step(buf.hview)
  of paneTerminalOutput: step(rt.app.terminalOutput.hview)
  of paneBuildOutput: step(rt.app.buildView.hview)
  of paneEventLog, paneCalltrace, paneState:
    # PLAT-70 Part I: the view as this frame settled it, stepped, kept.
    var v = rt.tableViewOf(pane).view
    let moved = step(v)
    rt.storeTableView(pane, v)
    moved
  else: false

proc routeHorizontalWheel(rt: TuiRuntime; event: MouseEvent;
                          outcome: var RuntimeOutcome): bool =
  ## §4.3: a horizontal wheel notch (SGR 66 / 67, or a delivered Shift +
  ## wheel) over a text pane moves its view `WheelColumns` columns — the pane
  ## under the pointer, focused or not, as the vertical wheel does. Never
  ## the rows (HO-6).
  if event.kind != mekPress or event.button notin {mbWheelLeft, mbWheelRight}:
    return false
  let at = rt.layoutGeometry().paneAt(event.row, event.col)
  var pane = if at.found: at.region.pane else: paneEditor
  if rt.maximize.active:
    for kind in [paneEditor, paneTerminalOutput, paneBuildOutput,
                 paneEventLog, paneCalltrace, paneState]:
      if rt.paintedAreaOf(kind).contains(event.row, event.col):
        pane = kind
  elif not at.found:
    return false
  if not rt.horizontalViewPane(pane):
    return false
  let cols = if event.button == mbWheelRight: WheelColumns else: -WheelColumns
  if rt.scrollPaneView(pane, proc(v: var HorizontalView): bool =
                         v.scrollBy(cols)):
    outcome.repaint = true
  true

proc runViewOperation(rt: TuiRuntime; operation: string;
                      outcome: var RuntimeOutcome): bool =
  ## §4.4's `view.*` operations on the focused output pane: by `WheelColumns`
  ## (`view.scroll-left` / `-right`), by half the view, back to column 0.
  let (had, focused) = rt.focus.focusedPane()
  let pane = if had: focused else: paneEditor
  if pane notin {paneTerminalOutput, paneBuildOutput} + TableViewPanes or
     not rt.horizontalViewPane(pane):
    rt.note("`" & operation & "` scrolls a pane wider than its content " &
            "area: Terminal Output, Build Output, or a table pane whose " &
            "columns do not fit")
    outcome.repaint = true
    return true
  discard rt.scrollPaneView(pane, proc(v: var HorizontalView): bool =
    case operation
    of "view.scroll-left": v.scrollBy(-WheelColumns)
    of "view.scroll-right": v.scrollBy(WheelColumns)
    of "view.scroll-left-half": v.scrollHalf(right = false)
    of "view.scroll-right-half": v.scrollHalf(right = true)
    of "view.scroll-to-line-start": v.scrollToLineStart()
    else: false)
  outcome.repaint = true
  true

proc searchPaneScreen(rt: TuiRuntime): tuple[area: CellArea,
                                             screen: SearchPaneScreen] =
  ## PLAT-57: Find in Files' rows below its strip, and where the painter put
  ## its parts — the arithmetic a press is read back with.
  let under = rt.paneAreaOf(paneSearch)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintSearchResults(g, result.area, rt.app.search)

proc agentPaneScreen*(rt: TuiRuntime): tuple[area: CellArea,
                                           screen: AgentPaneScreen] =
  ## PLAT-54: Agent Activity's rows below its strip and where the painter put
  ## them — the arithmetic a press, the wheel and the scrollbar read back.
  let under = rt.paneAreaOf(paneAgentActivity)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintAgentActivity(g, result.area, rt.app.agent)

proc scrollAgentTo*(rt: TuiRuntime; top: int) =
  ## PLAT-54: the reader moved the view — held on this line, following the
  ## end again only at the end (`FeedScroll.scrollTo`).
  let (_, screen) = rt.agentPaneScreen()
  rt.app.agent.scroll.scrollTo(top, markedRows(rt.app.agent.rows),
                               screen.lines, screen.listRows)

proc scrollAgent(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-54: the wheel over Agent Activity scrolls its lines.
  let (_, screen) = rt.agentPaneScreen()
  rt.scrollAgentTo(screen.top + delta)
  outcome.repaint = true

proc runAgentPrompt*(rt: TuiRuntime; text: string;
                     outcome: var RuntimeOutcome) =
  ## PLAT-54: `/ai <text>` — the desktop's agent query: Agent Activity shown
  ## and the prompt sent to the agent.
  outcome.repaint = true
  rt.showPane(paneAgentActivity, outcome)
  if rt.app.agentPrompt.isNil:
    rt.note("this session has no agent to send a prompt to")
    return
  let why = rt.app.agentPrompt(text)
  rt.note(if why.len > 0: why else: "sent to the agent: " & text)

proc agentEditorSelection(rt: TuiRuntime): string =
  ## What the "add context" menu's *Editor selection* attaches: the editor's
  ## file and the lines its selection covers (the caret's line when nothing
  ## is selected); "" when no file is shown.
  let buf = rt.editorBuffer()
  if buf.isNil or buf.path.len == 0:
    return ""
  let (first, last) = buf.doc.selectedLines
  editorSelectionContext(buf.path, first, last)

proc attachAgentContext(rt: TuiRuntime; context: string;
                        outcome: var RuntimeOutcome; mustExist = true) =
  ## PLAT-54 (§2.2.7): attach `context` to the agent's next prompt and show
  ## Agent Activity, where it is listed above the prompt.
  outcome.repaint = true
  if rt.app.agentAttach.isNil:
    rt.note("this session has no agent to attach context for")
    return
  rt.showPane(paneAgentActivity, outcome)
  let words = rt.app.agentAttach(context, mustExist)
  if words.len > 0:
    rt.note(words)

proc scrollSearch(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-57: the wheel over Find in Files scrolls its rows.
  let (_, screen) = rt.searchPaneScreen()
  rt.app.search.scrollTop = rt.app.search.clampScrollTop(
    rt.app.search.scrollTop + delta, screen.listRows)
  outcome.repaint = true

proc testsPaneScreen*(rt: TuiRuntime): tuple[area: CellArea,
                                            screen: TestsPaneScreen] =
  ## PLAT-53: Test Results' rows below its strip, and where the painter put
  ## its parts — the arithmetic a press is read back with.
  let under = rt.paneAreaOf(paneTestResults)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintTestResults(g, result.area, rt.app.tests)

proc testsControlTitleAt(rt: TuiRuntime; row, col: int): string =
  ## Test-Results-Pane.md §9.6: the title of the Test Results control drawn at
  ## `(row, col)` — the ▶, a `⟳` or a `⏵`, the desktop's tooltip words — or
  ## "" when the cell holds none.
  if not rt.app.tests.loaded:
    return ""
  let (area, screen) = rt.testsPaneScreen()
  if area.width <= 0:
    return ""
  let t = rt.app.tests.testsTargetAt(screen, area, row, col)
  case t.kind
  of tpRun: rt.app.tests.run.title
  of tpRefresh: rt.app.tests.rows[t.row].refresh.title
  of tpOpen: rt.app.tests.rows[t.row].open.title
  else: ""

proc testsHoverPointer(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome) =
  ## §9.6: the pointer passing over the screen (`?1003` motion, no button)
  ## puts the hovered control's title on the status line, and leaving it
  ## gives the line back (`shellScreenOf` shows the hover over the
  ## notification, which it does not replace).
  let title = rt.testsControlTitleAt(event.row, event.col)
  if title != rt.app.testsHover:
    rt.app.testsHover = title
    outcome.repaint = true

proc scrollTests(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-53: the wheel over Test Results scrolls its list.
  let (_, screen) = rt.testsPaneScreen()
  rt.app.tests.scrollTop = clampTestsTop(screen.wrapped.len,
    rt.app.tests.scrollTop + delta, screen.listRows)
  outcome.repaint = true

proc selectTestRow(rt: TuiRuntime; row: int) =
  ## PLAT-53: select Test Results row `row`, kept in view.
  if row < 0 or row >= rt.app.tests.rows.len:
    return
  rt.app.tests.selected = row
  let (_, screen) = rt.testsPaneScreen()
  rt.app.tests.scrollTop = rt.app.tests.revealRow(screen, row)

proc pressTestsControl(rt: TuiRuntime; control: TestsPaneControl;
                       request: PaneClickRequest;
                       outcome: var RuntimeOutcome) =
  ## PLAT-53: the ▶, a `⟳` or a `⏵`, pressed. An enabled control is the
  ## host's (`test_results_source.applyClick`); a disabled one says why on
  ## the status line — its title, the ViewModel's (§8.4) — and does nothing.
  outcome.repaint = true
  if control.enabled:
    outcome.requestClick(request)
  else:
    rt.note(control.title)

proc buildPaneScreen*(rt: TuiRuntime): tuple[area: CellArea,
                                            model: BuildPaneModel,
                                            screen: BuildPaneScreen] =
  ## PLAT-56: Build Output below its strip, its value as painted, and where
  ## the painter put its parts — the arithmetic a press is read back with.
  let under = rt.paneAreaOf(paneBuildOutput)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  result.model = rt.app.currentBuildPane()
  result.model.hview = rt.app.buildView.hview
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintBuildOutput(g, result.area, result.model)

proc scrollBuild(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-56: the wheel over Build Output scrolls its lines.
  let (_, model, screen) = rt.buildPaneScreen()
  rt.app.buildPane.scrollTop = clampBuildTop(model.output.len,
    screen.first + delta, screen.listRows)
  outcome.repaint = true

proc buildCommand(rt: TuiRuntime; kind: BuildPaneCommandKind; index: int;
                  outcome: var RuntimeOutcome) =
  ## PLAT-56: ask the host (`build_output_source`) — run again, stop, clear,
  ## auto-scroll, the history picker, a located line opened — and say what it
  ## said. An open focuses the editor, as a Problems row's does.
  outcome.repaint = true
  if rt.app.buildCommand.isNil:
    rt.note("this window has no Build Output pane host")
    return
  let said = rt.app.buildCommand(kind, index)
  if said.len > 0:
    rt.note(said)

proc revealBuildPane*(rt: TuiRuntime) =
  ## PLAT-56 (§3.10): the status line's build indicator pressed — the Build
  ## Output pane brought on screen: its tab activated where the arrangement
  ## places it, revealed from its edge where it is docked.
  if not rt.layoutBindingEnabled():
    return
  let b = rt.app.layoutBinding
  let at = b.layout.dockedIndex(paneBuildOutput)
  if at >= 0:
    if not b.layout.docked[at].open and b.interaction.kind != ikRevealingDock:
      discard b.beginRevealDock(paneBuildOutput)
  elif b.layout.tree.contains(paneBuildOutput):
    let acted = b.dispatch(cmdActivateTab(paneBuildOutput))
    if acted.status == lasApplied:
      rt.afterLayoutCommit()

proc problemsPaneScreen*(rt: TuiRuntime): tuple[area: CellArea,
                                               screen: ProblemsPaneScreen] =
  ## PLAT-55: Problems below its strip, and where the painter put its parts —
  ## the arithmetic a press is read back with.
  let under = rt.paneAreaOf(paneProblems)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintProblems(g, result.area, rt.app.problems)

proc scrollProblems(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-55: the wheel over Problems scrolls its list.
  let (_, screen) = rt.problemsPaneScreen()
  rt.app.problems.scrollTop = clampProblemsTop(rt.app.problems.lines.len,
    rt.app.problems.scrollTop + delta, screen.listRows)
  outcome.repaint = true

proc revealProblem*(rt: TuiRuntime; index: int) =
  ## PLAT-55: keep diagnostic `index` (master) in Problems' view.
  let (_, screen) = rt.problemsPaneScreen()
  rt.app.problems.scrollTop = rt.app.problems.revealIndex(screen.listRows,
                                                          index)

proc problemsCommand(rt: TuiRuntime; kind: ProblemsCommandKind; index: int;
                     outcome: var RuntimeOutcome) =
  ## PLAT-55: ask the host (`problems_source`) — a selection, an open, a step,
  ## a filter, the grouping — and say what it said. A step reveals the pane
  ## (EMT-D22.4: navigation works with the pane hidden, and brings it up)
  ## without focusing it; an open focuses the editor (EMT-D21).
  outcome.repaint = true
  if rt.app.problemsCommand.isNil:
    rt.note("this window has no Problems pane host")
    return
  let said = rt.app.problemsCommand(kind, index)
  if said.len > 0:
    rt.note(said)
  if kind in {pcmOpen, pcmNext, pcmPrevious}:
    # The editor has the keyboard now (EMT-D21's table).
    rt.hasDockKeys = false
  if kind in {pcmNext, pcmPrevious} and rt.app.problems.selected >= 0:
    let b = rt.app.layoutBinding
    let at = if rt.layoutBindingEnabled(): b.layout.dockedIndex(paneProblems)
             else: -1
    if at >= 0:
      # Docked (the shared default's footer): revealed unless it is shown
      # open or already revealed.
      if not b.layout.docked[at].open and
         b.interaction.kind != ikRevealingDock:
        discard b.beginRevealDock(paneProblems)
    elif rt.layoutBindingEnabled() and b.layout.tree.contains(paneProblems):
      let acted = b.dispatch(cmdActivateTab(paneProblems))
      if acted.status == lasApplied:
        rt.afterLayoutCommit()
  if rt.app.problems.selected >= 0:
    rt.revealProblem(rt.app.problems.selected)

proc openWorkingFileAt*(rt: TuiRuntime; path: string; line, col: int): string =
  ## PLAT-55 (K35): a working-tree file opened in Edit mode's editor — the
  ## `:e` route (`editServices.readFile`, `EditSession.openFile`) — with the
  ## caret at `line:col` (1-based; `col` <= 0 for none), kept in view, and
  ## the editor focused. "" when it opened, else why not. `path` is
  ## absolute; it must lie inside the project the services read.
  let root = rt.app.projectRoot
  var rel = path
  if root.len > 0:
    let prefix = if root.endsWith("/"): root else: root & "/"
    if path.startsWith(prefix):
      rel = path[prefix.len .. ^1]
    elif path.startsWith("/"):
      return path & " is outside the project (" & root & ")"
  if rt.editServices.readFile.isNil:
    return "this session cannot read " & rel
  let opened = rt.editServices.readFile(rel)
  if not opened.ok:
    return opened.message
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(rt.keymapModel, rt.keyDelivery)
  let rows = max(1, rt.sourcePaneRows())
  discard rt.app.editSession.openFile(rel, opened.text, rows)
  let buf = rt.app.editSession.activeBuffer()
  if not buf.isNil:
    buf.moveCaretTo(max(1, line) - 1, max(1, col) - 1)
    buf.followCaret(rows)
  rt.app.fileTree.openPath = rel
  discard rt.focus.focusPaneKind(paneEditor)
  ""

proc requestsPaneScreen*(rt: TuiRuntime): tuple[area: CellArea,
                                               screen: RequestsPaneScreen] =
  ## PLAT-58: the Requests pane's rows below its strip, and where the painter
  ## put its parts — the arithmetic a press is read back with.
  let under = rt.paneAreaOf(paneRequests)
  result.area = CellArea(col: under.col, row: under.row + 1,
                         width: under.width, height: max(0, under.height - 1))
  if result.area.width <= 0:
    return
  var g = newStyledGrid(result.area.col + result.area.width,
                        result.area.row + result.area.height)
  result.screen = paintRequests(g, result.area, rt.app.requests)

proc actOnRequests*(rt: TuiRuntime; act: RequestsAct;
                    outcome: var RuntimeOutcome): RequestsActResult =
  ## PLAT-58: hand `act` to the host (`TuiApp.requestsAct`), which does it
  ## through the session's `RequestPanelVM` and refreshes the pane (every pane,
  ## when the debugger moved); its words go to the status line and a copied
  ## URL to the clipboard.
  outcome.repaint = true
  if rt.app.requestsAct.isNil:
    rt.note("this session has no Requests pane")
    return
  result = rt.app.requestsAct(act)
  if result.copied.len > 0:
    rt.copyToClipboard(result.copied, "the URL")
  if result.note.len > 0:
    rt.note(result.note)

proc showRequestsWindow(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## PLAT-58: the list's rows moved (the wheel, the scrollbar, a kept
  ## selection): the host reports them to the ViewModel, which asks the
  ## engine for that window of a completed recording.
  let (_, screen) = rt.requestsPaneScreen()
  rt.app.requests.scrollTop = clampRequestsTop(rt.app.requests.total,
    rt.app.requests.scrollTop, screen.listRows)
  if not rt.app.requestsAct.isNil and screen.listRows > 0:
    discard rt.app.requestsAct(RequestsAct(kind: rakShow,
      position: rt.app.requests.scrollTop, rows: screen.listRows))
  outcome.repaint = true

proc scrollRequests(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-58: the wheel over the Requests pane scrolls its list.
  rt.app.requests.scrollTop = rt.app.requests.scrollTop + delta
  rt.showRequestsWindow(outcome)

proc keepRequestSelected(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## PLAT-58: the selected request kept in view.
  let (_, screen) = rt.requestsPaneScreen()
  let m = rt.app.requests
  let top = m.revealPosition(screen.listRows, m.selected)
  if top != clampRequestsTop(m.total, m.scrollTop, screen.listRows):
    rt.app.requests.scrollTop = top
    rt.showRequestsWindow(outcome)

proc revealRequestsPane*(rt: TuiRuntime): bool =
  ## PLAT-58 (Request-Panel.md § N.2, RS-M4): a recording that serves
  ## requests brings the pane on screen once — the docked REQUESTS pane opened
  ## at its edge (`cmdOpenDocked`, as the desktop docks it), its tab brought
  ## forward when the arrangement places it. Whether the layout changed.
  if not rt.layoutBindingEnabled():
    return false
  let b = rt.app.layoutBinding
  let at = b.layout.dockedIndex(paneRequests)
  let acted =
    if at >= 0:
      if b.layout.docked[at].open: return false
      b.dispatch(cmdOpenDocked(paneRequests))
    elif b.layout.tree.contains(paneRequests):
      b.dispatch(cmdActivateTab(paneRequests))
    else:
      return false
  if acted.status == lasApplied:
    rt.afterLayoutCommit()
    rt.rebuildFocus()
    return true
  false

proc openRequestsField(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## PLAT-58: the URL field — `:requests` alone, a press on the field,
  ## `list.filter` with the pane focused: the pane shown and the omnibox
  ## opened on `:requests <the current search>` (Request-Panel.md § N.4).
  rt.showPane(paneRequests, outcome)
  rt.openOmnibar(":requests " & rt.app.requests.search)
  outcome.repaint = true

# ---------------------------------------------------------------------------
# M71 (#838): the panes whose whole content is in hand — State, Files, VCS —
# keep an ORDINARY scrollbar (Scrollbar-Scrubbers.md §2), drawn by their
# painters in their last column while they overflow (§4), pressed by the
# same §3 rule as every list pane's (a press centres the row at its
# fraction, the held thumb drags), and scrolled by the wheel without focus
# (CodeTracer-TUI.md §4.4). Each is read back from its own painter, re-run on
# a scratch grid, so a press and the drawing cannot disagree.
# ---------------------------------------------------------------------------

const InHandPanes = {paneState, paneFileTree, paneVcs}

const NearBarCells = 3
  ## PLAT-70 Part H (§7.5): how close to a vertical bar the pointer wakes it.

type InHandTrack = object
  ## An in-hand pane's scrollbar as its painter drew it.
  model: ScrubberModel
    ## Every row the pane lists, the view's top and height.
  col, top, rows: int
    ## The track's column and its rows; `col` is -1 while the rows fit.

proc inHandTrack(rt: TuiRuntime; pane: PaneKind; under: CellArea):
    InHandTrack =
  ## Pane `pane`'s scrollbar, for the pane painted in `under` (its strip row
  ## first, as `shell.paintPane` hands it out).
  result = InHandTrack(col: -1)
  if under.width <= 0 or under.height <= 1:
    return
  var g = newStyledGrid(under.col + under.width, under.row + under.height)
  case pane
  of paneState:
    let s = paintVariables(g, under, rt.app.variables)
    result = InHandTrack(model: s.scrubberOf, col: s.trackCol,
                         top: under.row + 1, rows: s.bodyHeight)
  of paneFileTree:
    let s = paintFileTree(g, under, rt.app.fileTree)
    result = InHandTrack(model: s.scrubberOf, col: s.trackCol,
                         top: under.row + 1, rows: s.bodyRows)
  of paneVcs:
    # The VCS pane has no heading of its own: it is painted BELOW the strip
    # (`shell`'s `belowStrip`).
    let content = CellArea(col: under.col, row: under.row + 1,
                           width: under.width, height: under.height - 1)
    let s = paintVcsPane(g, content, rt.app.vcs)
    result = InHandTrack(model: s.scrubberOf, col: s.trackCol,
                         top: content.row, rows: content.height)
  else: discard

proc setInHandTop(rt: TuiRuntime; pane: PaneKind; top: int) =
  case pane
  of paneState: rt.app.variables.scrollTop = top
  of paneFileTree: rt.app.fileTree.scrollTop = top
  of paneVcs: rt.app.vcs.scrollTop = top
  else: discard

proc inHandLoaded(rt: TuiRuntime; pane: PaneKind): bool =
  ## Whether the pane draws its rows (else the shell left its rectangle to
  ## something else, and a gesture there is not the pane's).
  case pane
  of paneState: not rt.app.variables.isEmpty
  of paneFileTree: not rt.app.fileTree.isEmpty
  of paneVcs: rt.app.vcs.loaded
  else: false

proc vcsHistoryWindow*(rt: TuiRuntime): VcsHistoryWindow =
  ## The VCS pane's history window on the current screen — what the host
  ## reports as the history list's viewport (Viewport-Driven-Loading V6, the
  ## terminal's reporter is the layout projection): the rows of the pane's
  ## rectangle below its tab strip, as `inHandTrack` paints it, and the
  ## commits its scroll position has passed. `rows` 0 when the pane is not
  ## on screen (another tab of its stack shown, or closed), so the host keeps
  ## the viewport it last reported instead of reporting an unmeasured one.
  let under = rt.paneAreaOf(paneVcs)
  if under.width <= 0 or under.height <= 1:
    return
  vcsHistoryWindow(CellArea(col: under.col, row: under.row + 1,
                            width: under.width, height: under.height - 1),
                   rt.app.vcs)

proc scrollInHand(rt: TuiRuntime; pane: PaneKind; under: CellArea;
                  delta: int; outcome: var RuntimeOutcome) =
  ## The wheel over the pane: rows, as a scroll does (§3.4 — only the track
  ## and the thumb are scrubber gestures), kept inside the pane's rows.
  let t = rt.inHandTrack(pane, under)
  rt.setInHandTop(pane, clamp(t.model.firstVisible + delta, 0,
                              t.model.maxFirstVisible))
  outcome.repaint = true

proc routeVariablesResize(rt: TuiRuntime; event: MouseEvent;
                          outcome: var RuntimeOutcome): bool =
  ## PLAT-51: the Variables pane's name / value separator held — each motion
  ## puts the separator under the pointer (the name column's width), the
  ## release ends it (the desktop's column resize).
  if not rt.app.variablesResize.active:
    return false
  if event.kind == mekPress:
    rt.app.variablesResize.active = false
    return false
  let area = rt.app.variablesResize.area
  let cells = max(1, event.col - area.col - nameFieldColumn())
  rt.app.variablesNameCells = cells
  rt.app.variables.nameCells = cells
  if event.kind != mekMotion:
    rt.app.variablesResize.active = false
  outcome.repaint = true
  true

# ---------------------------------------------------------------------------
# PLAT-70 Part B — the table panes' cut cells, their full text, and the Event
# Log's column widths (Horizontal-Overflow.md §5)
# ---------------------------------------------------------------------------

const TablePanes = {paneState, paneEventLog, paneCalltrace}
  ## The panes whose cells truncate with `…` (§5).

proc tablePaneName(pane: PaneKind): string =
  ## A pane's name in a `DetailToggle` / a hover: the names the panes' own
  ## modules use.
  case pane
  of paneState: DetailPaneName
  of paneEventLog: EventLogTableName
  of paneCalltrace: CallTracePaneName
  else: ""

proc chordOfOperation(rt: TuiRuntime; name: string): string =
  ## The chord that runs operation `name` where the focus is now (KL-8).
  rt.router.chordFor(name, rt.sessionFacts, rt.scopePath, rt.navMode, "")

type TableCellHit = object
  found: bool
  pane: PaneKind
  cut: CutCell
  bodyRows: int

proc tableCellAt(rt: TuiRuntime; row, col: int): TableCellHit =
  ## The cut cell drawn at `(row, col)` in a table pane, as that pane's
  ## painter drew it (re-run on a scratch grid, so the hit is the paint's).
  let geometry = rt.paintedGeometry()
  let (onPane, region, under) = geometry.paneAt(row, col)
  if not onPane or region.pane notin TablePanes or
     not under.contains(row, col):
    return
  var g = newStyledGrid(under.col + under.width, under.row + under.height)
  var cuts: seq[CutCell] = @[]
  var body = 0
  case region.pane
  of paneState:
    if rt.app.variables.isEmpty: return
    let screen = paintVariables(g, under, rt.app.variables)
    cuts = screen.cuts
    body = screen.bodyHeight
  of paneEventLog:
    if not rt.app.eventLog.hasContent: return
    let screen = paintEventLog(g, under, rt.app.eventLog)
    cuts = screen.cuts
    body = screen.bodyHeight
  of paneCalltrace:
    if rt.app.callTrace.isEmpty: return
    cuts = paintCallTraceScreen(g, under, rt.app.callTrace).cuts
    body = rt.app.callTrace.callTraceBodyRows(under)
  else: return
  let i = cuts.cutCellAt(row, col)
  if i < 0:
    return
  TableCellHit(found: true, pane: region.pane, cut: cuts[i], bodyRows: body)

proc cellHoverPointer(rt: TuiRuntime; event: MouseEvent; nowMs: int64;
                      outcome: var RuntimeOutcome) =
  ## §5.3: the pointer passing over the screen (`?1003` motion, no button) —
  ## a truncated cell under it starts the 500 ms clock; anywhere else hides
  ## a shown tooltip.
  let hit = rt.tableCellAt(event.row, event.col)
  let changed =
    if hit.found:
      rt.app.cellHoverAnchor = (hit.cut.row, hit.cut.col, hit.bodyRows)
      rt.app.cellHover.pointerOver(tablePaneName(hit.pane), hit.cut.key,
                                   hit.cut.column, hit.cut.full, true, nowMs)
    else:
      rt.app.cellHover.pointerOver("", "", "", "", false, nowMs)
  if changed:
    rt.app.cellTooltip = CellTooltip()
    outcome.repaint = true

proc tickCellHover*(rt: TuiRuntime; nowMs: int64): bool =
  ## The hover's clock: the tooltip shows once the pointer has rested
  ## `HoverDelayMs` on a truncated cell. True when the screen changed.
  if not rt.app.cellHover.tick(nowMs):
    return false
  let a = rt.app.cellHoverAnchor
  let view = tooltipView(rt.app.cellHover.full, rt.width, a.bodyRows,
                         rt.chordOfOperation("list.copy"), terminalMeasure)
  rt.app.cellTooltip = CellTooltip(lines: view.lines, row: a.row, col: a.col)
  true

proc cellHoverDueMs*(rt: TuiRuntime): int64 =
  ## When `tickCellHover` next has something to do, -1 for never.
  rt.app.cellHover.dueMs

proc dismissCellHover(rt: TuiRuntime): bool =
  ## A key or a press: the tooltip goes (§5.3).
  result = rt.app.cellHover.dismiss()
  rt.app.cellTooltip = CellTooltip()

proc openDetail(rt: TuiRuntime; pane: PaneKind; key, column: string): bool =
  ## §5.3: the row's full text under it — again closes it; one row at a time
  ## (opening one closes any other pane's). True when it is now open.
  let name = tablePaneName(pane)
  var toggle = case pane
               of paneState: rt.app.variables.detail
               of paneEventLog: rt.app.eventLog.detail
               else: rt.app.callTrace.detail
  result = toggle.toggleDetail(name, key, column)
  rt.app.variables.detail = DetailToggle()
  rt.app.eventLog.detail = DetailToggle()
  rt.app.callTrace.detail = DetailToggle()
  let chord = rt.chordOfOperation("list.copy")
  case pane
  of paneState:
    rt.app.variables.detail = toggle
    rt.app.variables.copyChord = chord
  of paneEventLog:
    rt.app.eventLog.detail = toggle
    rt.app.eventLog.copyChord = chord
  else:
    rt.app.callTrace.detail = toggle
    rt.app.callTrace.copyChord = chord

proc routeEllipsisClick(rt: TuiRuntime; event: MouseEvent;
                        outcome: var RuntimeOutcome): bool =
  ## §5.3: a left press on a cut cell's `…` opens (or closes) its row's
  ## detail. A press anywhere else in the cell is the row's ordinary click.
  if event.kind != mekPress or event.button != mbLeft:
    return false
  let hit = rt.tableCellAt(event.row, event.col)
  if not hit.found or [hit.cut].ellipsisAt(event.row, event.col) < 0:
    return false
  discard rt.openDetail(hit.pane, hit.cut.key, hit.cut.column)
  outcome.repaint = true
  true

proc showDetail(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `list.show-detail`: the FOCUSED row's full text, under it (§5.3) — the
  ## variable under the cursor, the selected event, the call the debugger is
  ## in.
  outcome.repaint = true
  let (had, focused) = rt.focus.focusedPane()
  if not had or focused notin TablePanes:
    rt.note("Show Detail works in the Variables, Event Log and Call Trace panes")
    return
  var key = ""
  case focused
  of paneState:
    key = rt.app.variables.focused
    if key.len == 0: key = rt.app.variables.selected
  of paneEventLog:
    let (ok, ev) = rt.app.eventLog.rowAt(rt.app.eventLog.selected)
    if ok: key = $ev.index
  else:
    let at = rt.app.callTrace.currentTraceIndex
    if at >= 0: key = $at
  if key.len == 0:
    rt.note("no row is selected here to show")
    return
  discard rt.openDetail(focused, key, "")

proc eventLogArea(rt: TuiRuntime): CellArea =
  rt.paneAreaOf(paneEventLog)

proc resizeEventLogColumn(rt: TuiRuntime; arg: string;
                          outcome: var RuntimeOutcome) =
  ## `table.resize-column([column,]delta)` on the Event Log (§5.2): the named
  ## column, else the focused one, by `delta` cells from the width it is
  ## drawn at.
  outcome.repaint = true
  let target = rt.app.eventLog.columns.columnResizeTarget(arg)
  if not target.ok:
    rt.note(target.message)
    return
  let area = rt.paintedAreaOf(paneEventLog)
  var current = 0
  # PLAT-70 Part I: the width the column is DRAWN at (the fit's).
  var g = newStyledGrid(area.col + max(1, area.width), area.row + max(1, area.height))
  for (c, _, w) in paintEventLog(g, area, rt.app.eventLog).columnCells:
    if c == target.col: current = w
  discard rt.app.eventLog.columns.resizeColumn(target.col, target.delta, current)
  rt.note(rt.describeWidth(target.col))

proc routeEventLogResize(rt: TuiRuntime; event: MouseEvent;
                         outcome: var RuntimeOutcome): bool =
  ## §5.2: an Event Log column separator held — each motion puts the
  ## separator under the pointer (the column's width, never under
  ## `MinColumnCells`), the release ends it and remembers the widths.
  if not rt.app.eventLogResize.active:
    return false
  if event.kind == mekPress:
    rt.app.eventLogResize.active = false
    return false
  let r = rt.app.eventLogResize
  discard rt.app.eventLog.columns.setColumnWidth(r.column, event.col - r.startCol)
  if event.kind != mekMotion:
    rt.app.eventLogResize.active = false
    rt.note(rt.describeWidth(r.column))
  outcome.repaint = true
  true

proc scrollEventLog(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## The wheel over the Event Log: rows, as a scroll does (Scrollbar-
  ## Scrubbers.md §3.4 — only the track and the thumb are scrubber gestures).
  let area = rt.paneAreaOf(paneEventLog)
  var g = newStyledGrid(area.col + area.width, area.row + area.height)
  let screen = paintEventLog(g, area, rt.app.eventLog)
  let body = max(1, screen.bodyHeight)
  let top = event_log.clampScrollTop(rt.app.eventLog.scrollTop + delta,
                           rt.app.eventLog.knownTotal, body)
  rt.app.eventLog.scrollTop = top
  rt.app.eventLog.ensureWindow(top, body)
  rt.app.eventLog.releaseOutside(top, body)
  outcome.repaint = true

proc routeEventLogClick(rt: TuiRuntime; area: CellArea; event: MouseEvent;
                        outcome: var RuntimeOutcome): bool =
  ## K24 / K25 / K26: a left click on an event goes to it (`eventJump`, the
  ## desktop's row click); a right click shows its whole content (the desktop
  ## opens it in a read-only editor view); a left click on a column's header
  ## orders the log by it, again to reverse (the desktop's DataTables order).
  ## (A press on its scrollbar is the bar's — `routeScrollbars`, PLAT-70
  ## Part H.)
  let (ok, row, screen) = eventRowAt(rt.app.eventLog, area, event.row)
  if not ok:
    # PLAT-70 Part B (Horizontal-Overflow.md §5.2): a press on a separator
    # holds it — the motion that follows resizes the column to its left.
    let (onSeparator, sepColumn) = screen.separatorAt(event.row, event.col)
    if onSeparator and event.button == mbLeft:
      var startCol = 0
      for (c, at, _) in screen.columnCells:
        if c == sepColumn: startCol = at
      rt.app.eventLogResize = (active: true, column: sepColumn,
                               startCol: startCol)
      outcome.repaint = true
      return true
    let (onHeader, column) = screen.headerColumnAt(event.row, event.col)
    if onHeader and event.button == mbLeft:
      outcome.requestClick(PaneClickRequest(
        kind: pcEventOrder,
        order: rt.app.eventLog.order.clickedHeader(column)))
      return true
    return false
  let ev = row.event
  rt.app.eventLog.selected = row.index
  if event.button == mbRight:
    rt.showContent("event #" & $ev.index & " at tick " & $ev.tick &
                     (if ev.file.len > 0: "  " & ev.file & ":" & $ev.line
                      else: ""),
                   ev.content, outcome = outcome)
    return true
  outcome.requestClick(PaneClickRequest(kind: pcEventJump, index: ev.index,
                                        tick: ev.tick, path: ev.file,
                                        line: ev.line, text: ev.content))
  true

proc editorTextMenu(rt: TuiRuntime; target: SourceClickTarget):
    ContextMenuModel =
  ## The editor menu on `target`'s line, with the line's breakpoint state and
  ## the word under the pointer (`callTokenAt`).
  let src = rt.app.source
  let mark = src.markFor(target.line)
  var inFile, any = false
  for p in rt.app.points.rows:
    if p.kind == PointKindBreakpoint:
      any = true
      if p.path == src.path: inFile = true
  let onLine: LineBreakpoint =
    case mark
    of gmBreakpoint: lbEnabled
    of gmBreakpointDisabled: lbDisabled
    else: lbNone
  let (token, tokenError) = callTokenAt(target.lineText, target.column,
                                        rust = src.path.endsWith(".rs"))
  editorTextContextMenu(src.path, target.line, lineText = target.lineText,
                        column = target.column, token = token,
                        tokenError = tokenError, breakpoint = onLine,
                        fileHasBreakpoints = inFile, anyBreakpoints = any)

proc lineValues(target: SourceClickTarget): seq[NamedValue] =
  for v in target.values:
    result.add (v.name, v.value)

proc sourceWithView(rt: TuiRuntime): SourcePaneModel =
  ## The source pane's model with its document's horizontal view (PLAT-70),
  ## so a press is read back at the column it was painted at.
  result = rt.app.source
  let buf = rt.debugBuffer()
  if not buf.isNil and buf.path == result.path:
    result.hview = buf.hview

proc placeCaret(rt: TuiRuntime; path: string; line, column: int) =
  ## The read-only editor's caret onto `line:column` (1-based) of `path`:
  ## the caret of the file's document (`debugBuffer`), so the keys move it
  ## from there and a drag selects from there.
  let buf = rt.debugBuffer()
  if not buf.isNil and buf.path == path:
    buf.moveCaretTo(line - 1, column - 1)
    rt.syncCaretFrom(buf)
  else:
    rt.app.caret = (path, line, column)

# ---------------------------------------------------------------------------
# M73 (#840): THE DEBUG-MODE SOURCE PANE'S WINDOW, MOVED BY THE USER
#
# The pane draws `SourceVM`'s window (`source_binding`: `viewportTop =
# vm.visibleFirstLine`), and until M73 only a stop moved it
# (`editor_surface.followAndRequest`). The wheel was routed to four other
# panes, the scroll keys answered for two, the caret scrolled a document
# window this pane does not draw, and there was no vertical bar. Each input
# below says what it asks for (`SourceScroll`); the host moves `SourceVM` and
# serves the lines the window then lacks (`tui_session.scrollSource`), as it
# serves a stop's. The execution pointer is never moved by any of it.
# ---------------------------------------------------------------------------

const SourceWheelRows* = 3
  ## Lines one wheel notch scrolls the source — the call trace's, the event
  ## log's and the terminal output's (`CallTraceWheelRows`,
  ## `TerminalWheelRows`): the common terminal default.

proc sourceWindowShown(rt: TuiRuntime): bool =
  ## Whether the editor pane draws the recording's source READ-ONLY now:
  ## Debug mode, a file on it, and its document not made writable — `Ctrl+E`
  ## hands the pane to the edit pane (`editorPaneModel`), which draws its
  ## document's own window and is not this milestone's (the issue's "Edit
  ## mode is not part of this report").
  if rt.app.modes.product != pmDebug or rt.app.source.isEmpty:
    return false
  if not rt.app.editSession.isNil:
    let at = rt.app.editSession.indexOfPath(rt.app.source.path)
    if at >= 0 and not rt.app.editSession.buffers[at].doc.isReadOnly:
      return false
  true

proc requestSourceScroll(rt: TuiRuntime; scroll: SourceScroll;
                         outcome: var RuntimeOutcome) =
  outcome.sourceScroll = scroll
  outcome.repaint = true

# ---------------------------------------------------------------------------
# PLAT-70 Part H (Scrollbar-Scrubbers.md §7): EVERY scrollbar of every pane,
# one implementation. The panes' painters record each bar they draw
# (`scrollbar_styles.paintBar` → `ShellScreen.bars`); the pointer is
# hit-tested against those, so the hover states, the grab (its offset kept),
# the track's two rules, the held page's repeat and the fade's wake are the
# same code for the Event Log, the editor, Find in Files and the rest. A pane
# contributes only `applyBarTop` — how its view moves to a first visible row
# (or column) — because that is the one thing that differs: the Event Log
# fetches the window it lands on, the editor asks the session to scroll, the
# Call Trace pages its section in.
# ---------------------------------------------------------------------------

proc scrollbarFrame*(rt: TuiRuntime): ScrollbarFrame =
  ## What this frame's bars are drawn with: the options, the pointer's
  ## state, and each pane's fade.
  let s = rt.scrollbars
  result = ScrollbarFrame(options: s.options, pointer: s.pointer)
  for pane in PaneKind:
    result.faded[pane] = float32(1.0 - s.fades[pane].visibility(s.options))

proc barScreen(rt: TuiRuntime): ShellScreen =
  ## The screen as the last frame drew it, for reading bars back: the
  ## frame's model (`shellScreenOf`) without its side effects — no caret
  ## follow, no highlight scheduling — so a mouse report never moves
  ## anything by being hit-tested.
  var model = rt.app.shellModel(rt.width, rt.height)
  rt.editorPaneModel(model, follow = false)
  if rt.maximize.active:
    model.layout = rt.maximize.layoutFor(model.profile)
  let (hasFocus, focused) = rt.focus.focusedPane()
  model.hasFocus = hasFocus
  model.focused = focused
  model.scrollbars = rt.scrollbarFrame()
  model.glyphs = glyphProfileOf(rt.caps)
  model.ambiguous = ambiguousPolicyOf(rt.caps)
  model.topBar.glyphs = model.glyphs
  shellScreen(model, rt.width, rt.height)

proc applyBarTop(rt: TuiRuntime; bar: BarSpot; top: int;
                 outcome: var RuntimeOutcome) =
  ## Move pane `bar.pane`'s view so its first visible row (vertical) or
  ## column (horizontal) is `top`. The VIEW only (§3.5, HO-4).
  let rows = bar.model.visible
  case bar.axis
  of axVertical:
    case bar.pane
    of paneEventLog:
      let before = rt.app.eventLog.fetchCount
      rt.app.eventLog.scrollTop = top
      rt.app.eventLog.ensureWindow(top, rows)
      rt.app.eventLog.releaseOutside(top, rows)
      rt.app.listScrubFetches += rt.app.eventLog.fetchCount - before
    of paneCalltrace:
      rt.app.callTrace.scrollTop = top
      rt.app.callTraceAtEnd = top >= bar.model.maxFirstVisible
      rt.app.callTrace.follow = false
      rt.app.callTraceScrolled = true
      outcome.pagesCallTrace = true
    of paneSearch:
      rt.app.search.scrollTop = top
    of paneTestResults:
      rt.app.tests.scrollTop = top
    of paneRequests:
      # PLAT-58: the view moves; the host reports the rows it now shows.
      rt.app.requests.scrollTop = top
      rt.showRequestsWindow(outcome)
    of paneAgentActivity:
      rt.scrollAgentTo(top)
    of paneProblems:
      rt.app.problems.scrollTop = top
    of paneBuildOutput:
      rt.app.buildPane.scrollTop = top
    of paneEditor:
      rt.requestSourceScroll(SourceScroll(kind: sskTo, top: top + 1), outcome)
    of InHandPanes:
      rt.setInHandTop(bar.pane, top)
    of paneTerminalOutput:
      rt.app.terminalOutput.scrollTop = top
      rt.app.terminalOutput.follow = false
      rt.app.terminalOutput.ensureShown(rows)
    else: discard
  of axHorizontal:
    discard rt.scrollPaneView(bar.pane, proc(v: var HorizontalView): bool =
      v.setViewport(bar.cells)
      v.scrollBy(top - v.leftCol))
  outcome.repaint = true

proc barFraction(bar: BarSpot; event: MouseEvent): float =
  ## The pointer along `bar` as the scrubber model's track fraction — to the
  ## pixel where the terminal reports pixels (DECSET 1016).
  if event.pixel:
    let m = mouseMetrics()
    let units = bar.cells * 8
    let pos =
      if bar.axis == axVertical: (event.py / m.cellH - float(bar.at)) * 8.0
      else: (event.px / m.cellW - float(bar.at)) * 8.0
    trackFractionAt(clamp(int(pos), 0, units - 1), units)
  else:
    trackFractionAt(bar.cellAlong(event.row, event.col), bar.cells)

proc findBar(bars: seq[BarSpot]; pane: PaneKind; axis: BarAxis):
    tuple[found: bool, bar: BarSpot] =
  for b in bars:
    if b.pane == pane and b.axis == axis:
      return (true, b)

proc nearBar(bar: BarSpot; row, col: int): bool =
  ## The pointer is approaching `bar` (§7.5): within `NearBarCells` cells of
  ## it, level with it.
  case bar.axis
  of axVertical:
    row >= bar.at and row < bar.at + bar.cells and
      col >= bar.origin - NearBarCells and col <= bar.origin
  of axHorizontal:
    col >= bar.at and col < bar.at + bar.cells and
      row >= bar.origin - 1 and row <= bar.origin

proc noteBarsPainted*(rt: TuiRuntime; bars: seq[BarSpot]) =
  ## After a frame: a bar whose view moved since the last frame — a wheel, a
  ## key, a find, a jump — wakes its pane's bars (§7.5: they fade in when the
  ## pane scrolls, by any means).
  var present: array[PaneKind, array[BarAxis, bool]]
  for b in bars:
    present[b.pane][b.axis] = true
    let top = b.model.firstVisible
    let shown = rt.scrollbars.shownTops[b.pane][b.axis]
    if shown >= 0 and shown != top:
      rt.scrollbars.fades[b.pane].wake(rt.scrollbars.clockMs)
    # PLAT-70 Part I (Horizontal-Overflow.md §5.5, Scrollbar-Scrubbers §7.5):
    # a table pane's sideways bar that was not in the last frame appeared
    # because the columns no longer fit — it fades in, as a scroll's would.
    if rt.scrollbars.paintedValid and b.axis == axHorizontal and
       b.pane in TableViewPanes and not rt.scrollbars.present[b.pane][b.axis]:
      rt.scrollbars.fades[b.pane].wake(rt.scrollbars.clockMs)
    rt.scrollbars.shownTops[b.pane][b.axis] = top
  rt.scrollbars.present = present
  rt.scrollbars.painted = bars
  rt.scrollbars.paintedValid = true

proc setBarPointer(rt: TuiRuntime; p: BarPointer;
                   outcome: var RuntimeOutcome) =
  if p != rt.scrollbars.pointer:
    rt.scrollbars.pointer = p
    outcome.repaint = true

proc pressBar(rt: TuiRuntime; bar: BarSpot; event: MouseEvent; nowMs: int64;
              outcome: var RuntimeOutcome) =
  ## A press on `bar` (§7.4). On the thumb (either button) the thumb is
  ## grabbed where it was taken; on the track the left button follows
  ## `scrollbar-click` and the middle button the other rule: the jump (the
  ## press then holds the thumb by its middle) or a page toward the pointer,
  ## repeated while held.
  let o = rt.scrollbars.options
  let f = bar.barFraction(event)
  let cell = bar.cellAlong(event.row, event.col)
  rt.scrollbars.fades[bar.pane].wake(nowMs)
  if o.onThumb(bar, cell):
    rt.scrollbars.grab = BarGrab(active: true, pane: bar.pane, axis: bar.axis,
                                 offset: bar.model.grabOffset(f))
  else:
    let rule = if event.button == mbLeft: o.click else: o.click.otherRule
    case rule
    of tcJump:
      rt.applyBarTop(bar, bar.model.clickAt(f), outcome)
      rt.scrollbars.grab = BarGrab(active: true, pane: bar.pane,
                                   axis: bar.axis,
                                   offset: bar.model.jumpGrabOffset)
    of tcPage:
      let dir = bar.model.pageDirection(f)
      let top = bar.model.pageToward(f, dir)
      if top >= 0:
        rt.applyBarTop(bar, top, outcome)
      rt.scrollbars.paging = BarHold(pane: bar.pane, axis: bar.axis)
      rt.scrollbars.paging.hold.start(f, dir, nowMs)
  let state = if rt.scrollbars.grab.active: bsHeld else: bsHoverTrack
  rt.setBarPointer(BarPointer(active: true, pane: bar.pane, axis: bar.axis,
                              state: state), outcome)
  outcome.repaint = true

proc routeScrollbars(rt: TuiRuntime; event: MouseEvent; nowMs: int64;
                     outcome: var RuntimeOutcome): bool =
  ## Every mouse report, before the panes see it: a held thumb or paging
  ## press owns the pointer until released; otherwise the bar under the
  ## pointer takes a press, and any motion updates the hover state and wakes
  ## the bars it comes near. True when the report was a scrollbar's.
  rt.scrollbars.clockMs = max(rt.scrollbars.clockMs, nowMs)
  if rt.app.menu.isOpen or rt.app.omnibar.isOpen or rt.prompt.open:
    return false
  # Another gesture in flight owns the pointer (a pane dragged, a divider
  # held, a selection or a column being drawn): no bar is read back, which
  # also keeps a live drag's frames as cheap as they were.
  if not rt.scrollbars.grab.active and not rt.scrollbars.paging.hold.active:
    let b = rt.app.layoutBinding
    if rt.app.textDrag or rt.app.variablesResize.active or
       rt.app.eventLogResize.active or
       (not b.isNil and b.interaction.kind in GestureInteractions):
      return false
  # A passing pointer (most reports, under any-motion tracking) is read
  # against the bars of the frame on screen; a press, a held thumb and a held
  # paging press against the bars as they are now.
  let passing = event.kind == mekMotion and event.button != mbLeft and
                not rt.scrollbars.grab.active and
                not rt.scrollbars.paging.hold.active
  let bars = if passing and rt.scrollbars.paintedValid: rt.scrollbars.painted
             else: rt.barScreen().bars
  # A HELD THUMB follows the pointer wherever it goes, until released.
  if rt.scrollbars.grab.active:
    let g = rt.scrollbars.grab
    let (found, bar) = bars.findBar(g.pane, g.axis)
    case event.kind
    of mekMotion:
      if found:
        rt.applyBarTop(bar, bar.model.grabbedTop(bar.barFraction(event),
                                                 g.offset), outcome)
    of mekRelease:
      rt.scrollbars.grab.active = false
      let over = found and bar.contains(event.row, event.col)
      rt.setBarPointer(
        if over: BarPointer(active: true, pane: g.pane, axis: g.axis,
                            state: (if rt.scrollbars.options.onThumb(
                                      bar, bar.cellAlong(event.row,
                                                         event.col)):
                                      bsHoverThumb else: bsHoverTrack))
        else: BarPointer(), outcome)
    of mekPress:
      rt.scrollbars.grab.active = false
      rt.setBarPointer(BarPointer(), outcome)
      return false
    rt.scrollbars.fades[g.pane].wake(nowMs)
    outcome.repaint = true
    return true
  # A HELD PAGING PRESS: the pointer may move along the track; the release
  # ends it. The repeat itself is the tick's (`tickScrollbars`).
  if rt.scrollbars.paging.hold.active:
    let h = rt.scrollbars.paging
    let (found, bar) = bars.findBar(h.pane, h.axis)
    case event.kind
    of mekMotion:
      if found:
        rt.scrollbars.paging.hold.fraction = bar.barFraction(event)
    of mekRelease, mekPress:
      rt.scrollbars.paging.hold.active = false
    return true
  # The pointer's bar, if any; entering a pane or nearing a bar wakes it.
  var under = (found: false, bar: BarSpot())
  for b in bars:
    if b.contains(event.row, event.col):
      under = (true, b)
    elif b.nearBar(event.row, event.col):
      rt.scrollbars.fades[b.pane].wake(nowMs)
  var inPane = false
  for b in bars:
    if rt.paintedAreaOf(b.pane).contains(event.row, event.col):
      if not rt.scrollbars.pointerPane.found or
         rt.scrollbars.pointerPane.pane != b.pane:
        rt.scrollbars.fades[b.pane].wake(nowMs)
        outcome.repaint = true
      rt.scrollbars.pointerPane = (true, b.pane)
      inPane = true
      break
  if not inPane:
    # Left every pane with a bar: coming back into one wakes it again.
    rt.scrollbars.pointerPane.found = false
  if not under.found:
    rt.setBarPointer(BarPointer(), outcome)
    return false
  let bar = under.bar
  rt.scrollbars.fades[bar.pane].wake(nowMs)
  let thumb = rt.scrollbars.options.onThumb(
    bar, bar.cellAlong(event.row, event.col))
  rt.setBarPointer(BarPointer(active: true, pane: bar.pane, axis: bar.axis,
                              state: (if thumb: bsHoverThumb
                                      else: bsHoverTrack)), outcome)
  if event.kind != mekPress:
    return false
  if event.button in {mbLeft, mbMiddle}:
    rt.pressBar(bar, event, nowMs, outcome)
  # Any other button on a bar is the bar's, and does nothing.
  true

proc tickScrollbars*(rt: TuiRuntime; nowMs: int64): RuntimeOutcome =
  ## The loop's clock for the scrollbars: a held paging press pages again
  ## when due; every pane's fade moves toward where it is going. `repaint`
  ## when the screen changed; the host applies the outcome as a token's (a
  ## page of the editor is a source scroll the session makes).
  rt.scrollbars.clockMs = max(rt.scrollbars.clockMs, nowMs)
  if not rt.scrollbars.started:
    rt.scrollbars.started = true
    for pane in PaneKind:
      rt.scrollbars.fades[pane] = initFade(nowMs)
  let o = rt.scrollbars.options
  if rt.scrollbars.paging.hold.due(nowMs):
    let h = rt.scrollbars.paging
    let (found, bar) = rt.barScreen().bars.findBar(h.pane, h.axis)
    let top = if found: bar.model.pageToward(h.hold.fraction, h.hold.dir)
              else: -1
    if top < 0:
      rt.scrollbars.paging.hold.active = false
    else:
      rt.applyBarTop(bar, top, result)
      rt.scrollbars.paging.hold.repeated(nowMs)
      rt.scrollbars.fades[h.pane].wake(nowMs)
  for pane in PaneKind:
    let held = (rt.scrollbars.pointer.active and
                rt.scrollbars.pointer.pane == pane) or
               (rt.scrollbars.grab.active and rt.scrollbars.grab.pane == pane)
    let before = rt.scrollbars.fades[pane].level
    discard rt.scrollbars.fades[pane].stepFade(o, nowMs, held)
    if rt.scrollbars.fades[pane].level != before:
      result.repaint = true

proc scrollbarDueMs*(rt: TuiRuntime): int64 =
  ## When `tickScrollbars` next has something to do, -1 for never: a frame
  ## from now while a fade moves or a paging press is held, else when the
  ## first resting bar starts fading out.
  let s = rt.scrollbars
  let now = s.clockMs
  if s.paging.hold.active:
    return min(s.paging.hold.dueMs, now + FadeFrameMs)
  result = -1
  for pane in PaneKind:
    let f = s.fades[pane]
    let held = (s.pointer.active and s.pointer.pane == pane) or
               (s.grab.active and s.grab.pane == pane)
    let target = f.fadeTarget(s.options, now, held)
    let due =
      if f.level != target: now + FadeFrameMs
      else: f.nextFadeMs(s.options)
    if due >= 0 and (result < 0 or due < result):
      result = due

proc followCaretInSource(rt: TuiRuntime; buf: EditBuffer;
                         before: (int, int); outcome: var RuntimeOutcome) =
  ## The read-only caret moved (a key, a find): the drawn window follows it
  ## by the least amount (`SourceVM.followCursor`), so it cannot leave the
  ## screen. `buf.followCaret` scrolls the DOCUMENT's own window, which the
  ## Debug-mode pane does not draw; that was the gap. A key that did not move
  ## the caret (a copy, a refused edit) does not scroll: after a wheel the
  ## user's window is theirs until the caret moves (Monaco's rule too).
  if buf.isNil or not buf.doc.isReadOnly or buf.path != rt.app.source.path or
     not rt.sourceWindowShown:
    return
  if (buf.caretLine, buf.caretColumn) == before:
    return
  rt.requestSourceScroll(SourceScroll(kind: sskFollowCaret,
                                      line: buf.caretLine,
                                      column: buf.caretColumn + 1), outcome)

proc routeTextDrag(rt: TuiRuntime; event: MouseEvent;
                   outcome: var RuntimeOutcome): bool =
  ## PLAT-68: a press held on the editor's text owns the pointer until it is
  ## released: each motion extends the document's selection to the cell
  ## under the pointer (`extendSelectionTo`, every front-end's drag).
  if not rt.app.textDrag:
    return false
  if event.kind == mekPress:
    rt.app.textDrag = false
    return false
  if event.kind == mekRelease:
    rt.app.textDrag = false
  let buf = rt.debugBuffer()
  let geometry = rt.paintedGeometry()
  var area = CellArea()
  for i, region in geometry.projection.regions:
    if region.pane == paneEditor: area = paneUnderStrip(geometry, i)
  if buf.isNil or area.width <= 0:
    return true
  let row = clamp(event.row, area.row, area.row + area.height - 1)
  let col = clamp(event.col, area.col, area.col + area.width - 1)
  let target = rt.sourceWithView().sourceClickTargetAt(area, row, col)
  if target.line >= 1:
    buf.doc.extendSelectionTo(target.line - 1, max(1, target.column) - 1)
    rt.syncCaretFrom(buf)
  outcome.repaint = true
  true

proc routeEditorClick(rt: TuiRuntime; under: CellArea; event: MouseEvent;
                      outcome: var RuntimeOutcome): bool =
  ## K10-K15 and K36 on the recording's source in Debug: the gutter's toggle
  ## and enable / disable, the text's line and call jumps, a column
  ## breakpoint, the editor menu, and an inline value's click, Ctrl+click and
  ## menu — `ui/editor`'s and `ui/flow`'s mouse handlers.
  if rt.app.modes.product == pmEdit or rt.app.source.isEmpty:
    return false
  let src = rt.sourceWithView()
  let target = src.sourceClickTargetAt(under, event.row, event.col)
  if target.line < 1:
    return false
  let line = target.line
  if target.onGutter:
    if event.button == mbLeft:
      outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,
                                            path: src.path, line: line))
      return true
    if event.button == mbRight:
      # The desktop's gutter right-click enables / disables a breakpoint
      # that is there, and does nothing on a line without one.
      let mark = src.markFor(line)
      if mark in {gmBreakpoint, gmBreakpointDisabled}:
        outcome.requestClick(PaneClickRequest(
          kind: pcSetBreakpointEnabled, path: src.path, line: line,
          enabled: mark == gmBreakpointDisabled))
        return true
    return false
  # K36: AN INLINE VALUE — `ui/flow`'s value: a click goes to the step the
  # line ran at, Ctrl+click pins it, a right click opens its menu.
  if target.value >= 0:
    let v = target.values[target.value]
    case event.button
    of mbRight:
      rt.openContextMenu(flowValueContextMenu(src.path, line, v.name, v.value,
                                              lineValues(target)),
                         event.row, event.col, outcome)
    of mbLeft:
      if event.ctrl:
        outcome.requestClick(PaneClickRequest(kind: pcScratchpadAdd,
                                              values: @[(v.name, v.value)]))
      else:
        # The note GPUI's window gives for the same click (`gpui/main.nim`'s
        # inline-value press) — the line's value as the flow recorded it.
        rt.note(v.name & " = " & v.value & " is the value at this step")
        outcome.repaint = true
    else:
      return false
    return true
  # K47 (PLAT-51): A PRESS ON THE TEXT PLACES THE CARET, as Monaco's does in
  # a read-only model — a plain left press, and a right press before its menu.
  if event.button == mbRight or
     (event.button == mbLeft and not event.ctrl and not event.alt):
    rt.placeCaret(src.path, line, max(1, target.column))
    # PLAT-68: a held left press SELECTS as the pointer moves.
    rt.app.textDrag = event.button == mbLeft
    outcome.repaint = true
  case event.button
  of mbRight:
    rt.openContextMenu(rt.editorTextMenu(target), event.row, event.col,
                       outcome)
    true
  of mbMiddle:
    outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,
                                          line: line, behaviour: "smart"))
    true
  of mbLeft:
    if event.ctrl and event.alt:
      # K15: the desktop's Ctrl+Alt+click on a function's name.
      let (token, err) = callTokenAt(target.lineText, target.column,
                                     rust = src.path.endsWith(".rs"))
      if token.len == 0:
        rt.note(if err.len > 0: err & " on line " & $line & "."
                else: NoWordSelected)
        outcome.repaint = true
      else:
        outcome.requestClick(PaneClickRequest(kind: pcCallJump,
                                              path: src.path, line: line,
                                              text: token,
                                              behaviour: "smart"))
      true
    elif event.alt:
      # K14: the desktop's Alt+click — a breakpoint anchored at the column
      # (`column_click_resolver`: the text's column, clamped to the line).
      let width = max(1, cellWidthOf(target.lineText))
      outcome.requestClick(PaneClickRequest(
        kind: pcColumnBreakpoint, path: src.path, line: line,
        column: max(1, min(target.column, width))))
      true
    elif event.ctrl:
      outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,
                                            line: line, behaviour: "smart"))
      true
    else:
      # The caret was placed above.
      true
  else:
    false

proc openTracepointEditorAt(rt: TuiRuntime; path: string; line: int) =
  ## PLAT-51 (and K13's "Add tracepoint"): the tracepoint editor on `line` —
  ## the prompt with `:tracepoint ` typed, placed on that line (PLAT-50's
  ## route); Enter runs the sweep and its hits are listed as the desktop's
  ## editor lists them under the line.
  rt.app.tracepointAt = (path, line)
  discard rt.openPrompt(pkCommand)
  discard rt.prompt.insert("tracepoint ")
  rt.note("a tracepoint at " & path.extractFilename & ":" & $line &
          " — type its expression and press Enter")

proc routeDockLabelClick(rt: TuiRuntime; geometry: LayoutGeometry;
                         event: MouseEvent;
                         outcome: var RuntimeOutcome): bool =
  ## K42: a right-click on a docked pane's label opens the desktop's strip
  ## menu (`ui/auto_hide`'s `onContextMenu`).
  if event.kind != mekPress or event.button != mbRight:
    return false
  let s = geometry.stripIndexAt(event.row, event.col)
  if s < 0:
    return false
  let strip = geometry.strips[s]
  let i = strip.slotAt(event.row, event.col)
  if i < 0:
    return false
  rt.openContextMenu(dockLabelContextMenu(strip.slots[i].pane, strip.edge),
                     event.row, event.col, outcome)
  true

proc routePaneClick(rt: TuiRuntime; geometry: LayoutGeometry;
                    event: MouseEvent; outcome: var RuntimeOutcome): bool =
  ## A press the layout did not act on (`lasNoGesture`), on a pane's strip or
  ## body, or a dock label: what the desktop does there. Answers whether it
  ## was taken.
  if event.kind != mekPress or
     event.button notin {mbLeft, mbRight, mbMiddle}:
    return false
  if rt.routeDockLabelClick(geometry, event, outcome):
    return true
  # K37: the status line (the desktop's status bar location and its copy
  # button) — a click on it copies the current file's path, as the
  # desktop's copy control does (measured: the path, without the line). The
  # bottom dock labels in that row are the layout's, handled before this.
  if event.row == rt.height - 1 and event.button == mbLeft:
    # PLAT-56 (§3.10): a press on the build indicator reveals Build Output.
    if rt.app.buildStatus.len > 0:
      let frame = rt.shellScreenOf()
      if frame.rows.len > 0:
        let statusRow = frame.rows[^1]
        let at = statusRow.find(rt.app.buildStatus)
        if at >= 0:
          let startCol = textCells(statusRow[0 ..< at])
          if event.col >= startCol and
             event.col < startCol + textCells(rt.app.buildStatus):
            rt.revealBuildPane()
            outcome.repaint = true
            return true
    let colon = rt.app.location.rfind(':')
    if colon <= 0:
      return false
    let path = rt.app.location[0 ..< colon]
    rt.copyToClipboard(path, "the path " & path)
    outcome.repaint = true
    return true
  let (onPane, region, under) = geometry.paneAt(event.row, event.col)
  if not onPane:
    return false
  # K7: a right-click on a TAB opens the tab's menu.
  if event.row == region.area.row:
    if event.button != mbRight:
      return false
    let pane = rt.app.layoutBinding.stripPaneAt(geometry, event.row,
                                                event.col)
    if pane.isNone:
      return false
    rt.openContextMenu(tabContextMenu(pane.get, rt.maximize.active),
                       event.row, event.col, outcome)
    return true
  if not under.contains(event.row, event.col):
    return false   # the divider
  case region.pane
  of paneFileTree:
    # K17 / K18, and K19: a right-click opens the Files pane's menu.
    if event.button notin {mbLeft, mbRight}:
      return false
    let tree = rt.app.fileTree
    if tree.isEmpty:
      return false
    # The row under the press, by the top the painter drew from (M71: the
    # pane scrolls, and `scrollTop` is clamped there).
    var g = newStyledGrid(under.col + under.width, under.row + under.height)
    let i = paintFileTree(g, under, tree).entryIndexAt(event.row)
    if i < 0 or i >= tree.rowCount:
      return false
    if event.button == mbRight:
      rt.openFilesMenu(i, event.row, event.col, outcome)
      return true
    rt.activateFilesRow(i, outcome)
    return true
  of paneEditor:
    return rt.routeEditorClick(under, event, outcome)
  of paneCalltrace:
    # K22 / K23 (K20 / K21 are the left press in `routeMouseReport`).
    if event.button != mbRight or rt.app.callTrace.isEmpty:
      return false
    let hit = rt.app.callTrace.callTraceHitAt(under, event.row, event.col)
    if hit.kind == cthNone:
      return false
    let local = int(hit.index - rt.app.callTrace.firstIndex)
    if local < 0 or local >= rt.app.callTrace.rows.len:
      return false
    let call = rt.app.callTrace.rows[local].callOf
    if hit.arg >= 0 and hit.arg < call.args.len:
      let a = call.args[hit.arg]
      rt.openContextMenu(callArgumentContextMenu(hit.index, a.name, a.value),
                         event.row, event.col, outcome)
      return true
    rt.openContextMenu(callTraceContextMenu(hit.index, call.toggle != crtLeaf,
                                            call.toggle == crtExpanded),
                       event.row, event.col, outcome)
    return true
  of paneEventLog:
    if event.button notin {mbLeft, mbRight}:
      return false
    return rt.routeEventLogClick(under, event, outcome)
  of paneState:
    # K27 / K28.
    if rt.app.variables.isEmpty:
      return false
    var g = newStyledGrid(under.col + under.width, under.row + under.height)
    let screen = paintVariables(g, under, rt.app.variables)
    # PLAT-51: EVERY DESKTOP VALUE FEATURE HERE TOO (Variable-State-Pane.md,
    # "Every front-end has every value feature").
    let (anyRow, prow) = screen.rowAtScreenRow(event.row)
    if anyRow:
      case prow.kind
      of vrkHistory:
        # A history entry is a NAVIGATION ROW: a click goes to that moment;
        # its menu is the desktop's history row menu.
        if event.button == mbLeft:
          outcome.requestClick(PaneClickRequest(kind: pcSeek,
                                                tick: prow.ticks))
          return true
        if event.button == mbRight:
          rt.openContextMenu(valueHistoryEntryContextMenu(
                               variablePathOf(prow.node.path), prow.note,
                               prow.ticks, path = prow.node.path),
                             event.row, event.col, outcome)
          return true
        return false
      of vrkAddWatch:
        if event.button != mbLeft:
          return false
        discard rt.openPrompt(pkCommand)
        discard rt.prompt.insert("watch ")
        rt.note("type the expression to watch and press Enter")
        outcome.repaint = true
        return true
      of vrkMore:
        if event.button != mbLeft:
          return false
        # The desktop's load-more row: the next chunk of the members.
        discard rt.app.variables.expandMore(prow.node.path)
        outcome.repaint = true
        return true
      of vrkVariable:
        if event.button == mbLeft:
          case screen.controlAt(rt.app.variables, event.row, event.col)
          of vcHistory:
            outcome.requestClick(PaneClickRequest(kind: pcValueHistory,
                                                  path: prow.node.path))
            return true
          of vcOrigin:
            outcome.requestClick(PaneClickRequest(kind: pcValueOrigin,
                                                  path: prow.node.path))
            return true
          of vcRemoveWatch:
            outcome.requestClick(PaneClickRequest(
              kind: pcWatch, path: prow.node.name, behaviour: "remove"))
            return true
          of vcNameSeparator:
            # The desktop's column resize: the separator is held, and the
            # name column follows the pointer until the release.
            rt.app.variablesResize = (active: true, area: under)
            return true
          of vcNone: discard
      else: discard
    let path = screen.pathAtScreenRow(event.row)
    if path.len == 0:
      return false
    rt.app.variables.selected = path
    rt.app.variables.focused = path
    # `o` acts on the selected variable (`CommandContext.selectedVariable`).
    rt.context.selectedVariable = variablePathOf(path)
    if event.button == mbRight:
      rt.openContextMenu(variablesContextMenu(path), event.row, event.col,
                         outcome)
      return true
    if event.button == mbLeft:
      discard rt.app.variables.toggleNode(path)
      outcome.repaint = true
      return true
    return false
  of panePointList:
    # K31: the desktop's click selects the point.
    if event.button != mbLeft or not rt.app.points.loaded:
      return false
    let i = event.row - under.row - 1
    if i < 0 or i >= rt.app.points.rows.len:
      return false
    rt.app.points.selected = i
    outcome.repaint = true
    return true
  of paneScratchpad:
    # K33: the close button removes the value.
    if event.button != mbLeft or not rt.app.scratchpad.loaded:
      return false
    let hit = rt.app.scratchpad.scratchpadHitAt(under, event.row, event.col)
    if hit.row < 0 or not hit.close:
      return false
    outcome.requestClick(PaneClickRequest(kind: pcScratchpadRemove,
                                          index: hit.row))
    return true
  of paneAgentActivity:
    # PLAT-54: a row runs its action (a turn, a run, a test, a tool group
    # opened or closed), a `[button]` its button's (a recording opened, in
    # this tab or a new one; a review entered; an attachment removed); the
    # prompt row opens the omnibox on `/ai `; its `[+]` opens the desktop's
    # "add context" menu (DeepReview-GUI.md §2.2.7); Send / Stop as the
    # desktop's; the scrollbar column is the scrollbar's (`routeScrollbars`).
    # The desktop's panel has no context menu of its own, so a right press
    # opens nothing.
    if event.button != mbLeft or not rt.app.agent.loaded:
      return false
    let (area, screen) = rt.agentPaneScreen()
    let t = rt.app.agent.agentTargetAt(screen, area, event.row, event.col)
    case t.kind
    of atRow, atButton:
      if rt.app.agentPress.isNil:
        return false
      let words = rt.app.agentPress(t.row,
                                    (if t.kind == atButton: t.button else: -1))
      if words.len > 0:
        rt.note(words)
      outcome.repaint = true
      return true
    of atPrompt, atSend:
      rt.openOmnibar(AgentOmnibarPrefix)
      outcome.repaint = true
      return true
    of atAddContext:
      rt.openContextMenu(agentAddContextMenu(rt.agentEditorSelection()),
                         event.row, event.col, outcome)
      return true
    of atStop:
      if not rt.app.agentStop.isNil:
        let words = rt.app.agentStop()
        if words.len > 0:
          rt.note(words)
      outcome.repaint = true
      return true
    of atTrack:
      return true
    of atNone:
      return false
  of paneSearch:
    # PLAT-57 (K35): a result opens at its line; a toggle flips and the
    # search runs again; the field opens the omnibox on `:grep <query>`;
    # the scrubber column moves the view.
    if event.button != mbLeft or not rt.app.search.loaded:
      return false
    let (area, screen) = rt.searchPaneScreen()
    let t = rt.app.search.searchTargetAt(screen, area, event.row, event.col)
    case t.kind
    of stMatch:
      outcome.requestClick(PaneClickRequest(kind: pcSearchResult,
                                            index: t.index, path: t.path))
      return true
    of stOption:
      outcome.requestClick(PaneClickRequest(kind: pcSearchOption,
                                            text: t.option))
      return true
    of stQuery:
      rt.openFindInFiles(outcome)
      return true
    of stTrack:
      # PLAT-70 Part H: the scrollbar's (`routeScrollbars`).
      return true
    of stFile, stNone:
      return false
  of paneBuildOutput:
    # PLAT-56 (K35): a line that names a location opens its file at its line
    # and column; the header's controls act; a history entry is shown; the
    # scrollbar is the scrollbars' (`routeScrollbars`). The desktop opens no
    # menu on a line, so a right press does nothing here.
    if event.button != mbLeft or not rt.app.buildPane.loaded:
      return false
    let (area, model, screen) = rt.buildPaneScreen()
    let t = model.buildTargetAt(screen, area, event.row, event.col)
    case t.kind
    of btControl:
      rt.buildCommand((case t.control
                       of bcHistory: bpcHistory
                       of bcRun: bpcRun
                       of bcStop: bpcStop
                       of bcClear: bpcClear
                       of bcFollow: bpcFollow), -1, outcome)
      return true
    of btHistoryItem:
      rt.buildCommand(bpcShow, t.index, outcome)
      return true
    of btLine:
      rt.buildCommand(bpcOpen, t.index, outcome)
      return true
    of btTrack:
      return true
    of btText, btNone:
      return false
  of paneProblems:
    # PLAT-55 (K35): a diagnostic opens its file at its line and is selected
    # (the cursor `next error` continues from); a filter button or Group by
    # File acts on the list; the scrollbar is the scrollbars'
    # (`routeScrollbars`). The desktop opens no menu on a row, so a right
    # press does nothing here.
    if event.button != mbLeft or not rt.app.problems.loaded:
      return false
    let (area, screen) = rt.problemsPaneScreen()
    let t = rt.app.problems.problemsTargetAt(screen, area, event.row,
                                             event.col)
    case t.kind
    of pbRow:
      rt.problemsCommand(pcmOpen, t.index, outcome)
      return true
    of pbFilter:
      rt.problemsCommand(pcmFilter, t.index, outcome)
      return true
    of pbGroup:
      rt.problemsCommand(pcmGroup, -1, outcome)
      return true
    of pbTrack:
      return true
    of pbHeader, pbText, pbNone:
      return false
  of paneTestResults:
    # PLAT-53: the ▶ runs the suite; a row's `⟳` records it again and `⏵`
    # opens its recording in a new tab; a press elsewhere on a row (or its
    # message) selects it; the scrollbar is the scrollbars' (`routeScrollbars`).
    # The desktop opens no menu on a row, so a right press does nothing here.
    if event.button != mbLeft or not rt.app.tests.loaded:
      return false
    let (area, screen) = rt.testsPaneScreen()
    let t = rt.app.tests.testsTargetAt(screen, area, event.row, event.col)
    case t.kind
    of tpRun:
      rt.pressTestsControl(rt.app.tests.run,
                           PaneClickRequest(kind: pcTestsRun), outcome)
      return true
    of tpRefresh, tpOpen:
      let r = rt.app.tests.rows[t.row]
      rt.app.tests.selected = t.row
      if t.kind == tpRefresh:
        rt.pressTestsControl(r.refresh, PaneClickRequest(kind: pcTestsRefresh,
                             text: r.testId), outcome)
      else:
        # §9.3: Ctrl on the press inverts the destination for this press.
        rt.pressTestsControl(r.open, PaneClickRequest(kind: pcTestsOpen,
                             text: r.testId,
                             behaviour: (if event.ctrl: TestsRedirectBehaviour
                                         else: "")), outcome)
      return true
    of tpRow:
      rt.selectTestRow(t.row)
      outcome.repaint = true
      return true
    of tpTrack:
      return true
    of tpText, tpNone:
      return false
  of paneRequests:
    # PLAT-58 (K58 – K60): a press selects a request and a double press goes
    # to its handler (the ViewModel counts it); a right press opens the row's
    # menu; a picker opens its options; the field opens the omnibox on
    # `:requests`; `Handler ›` goes to the selected request's handler; the
    # scrollbar is the scrollbars' (`routeScrollbars`).
    if event.button notin {mbLeft, mbRight} or not rt.app.requests.loaded:
      return false
    # A press on the pane focuses it — docked open at its edge included, which
    # the layout binding's own press does not focus — so its keys follow.
    rt.app.layoutBinding.focus = paneRequests
    let (area, screen) = rt.requestsPaneScreen()
    let t = rt.app.requests.requestsTargetAt(screen, area, event.row,
                                             event.col)
    if event.button == mbRight:
      if t.kind != rqRow or not t.held:
        return t.kind != rqNone
      let r = rt.actOnRequests(RequestsAct(kind: rakRowMenu,
                                           position: t.position), outcome)
      if r.menu.entries.len > 0:
        rt.openContextMenu(r.menu, event.row, event.col, outcome)
      return true
    case t.kind
    of rqRow:
      if t.held:
        discard rt.actOnRequests(RequestsAct(kind: rakPress,
          position: t.position, nowMs: rt.scrollbars.clockMs), outcome)
        rt.keepRequestSelected(outcome)
      return true
    of rqMethod, rqStatus:
      let r = rt.actOnRequests(RequestsAct(kind: rakPickerMenu,
        text: (if t.kind == rqStatus: "status" else: "method")), outcome)
      if r.menu.entries.len > 0:
        rt.openContextMenu(r.menu, event.row + 1, event.col, outcome)
      return true
    of rqField:
      rt.openRequestsField(outcome)
      return true
    of rqHandler:
      discard rt.actOnRequests(RequestsAct(kind: rakGoToHandler), outcome)
      return true
    of rqTrack, rqHeader, rqDetail, rqMessage:
      return true
    of rqNone:
      return false
  of paneVcs:
    # K34 / K53: a changed file opens its diff; a commit opens (lists the
    # files it changed) or closes; a commit's file opens that change.
    if event.button != mbLeft or not rt.app.vcs.loaded:
      return false
    var g = newStyledGrid(under.col + under.width, under.row + under.height)
    let content = CellArea(col: under.col, row: under.row + 1,
                           width: under.width,
                           height: max(0, under.height - 1))
    let screen = paintVcsPane(g, content, rt.app.vcs)
    let t = screen.vcsTargetAt(event.row)
    case t.kind
    of vrNone:
      return false
    of vrFile, vrCommitFile:
      outcome.requestClick(PaneClickRequest(kind: pcVcsDiff, path: t.path,
                                            text: t.status,
                                            behaviour: t.hash))
    of vrCommit:
      outcome.requestClick(PaneClickRequest(kind: pcVcsCommit,
                                            index: t.index))
    return true
  of paneTerminalOutput:
    # PLAT-52 (K32): a fragment goes to the write that produced it; the
    # toggle and the two scrubbers.
    return rt.routeTerminalOutputClick(under, event, outcome)
  else:
    return false

proc runContextAction(rt: TuiRuntime; action: ContextAction;
                      target: ContextTarget; outcome: var RuntimeOutcome) =
  ## A context-menu entry was chosen: route its action to the operation the
  ## desktop's entry runs.
  outcome.repaint = true
  let binding = rt.app.layoutBinding
  proc layout(rt: TuiRuntime; cmd: LayoutCommand) =
    if binding.isNil:
      return
    let acted = binding.dispatch(cmd)
    if acted.status == lasApplied:
      rt.afterLayoutCommit()
      rt.rebuildFocus()
    elif acted.status in MouseNoteStatuses:
      rt.note(acted.message)
  case action
  of caNone: discard
  of caPinLeft: rt.layout(cmdDock(target.pane, leLeft))
  of caPinBottom: rt.layout(cmdDock(target.pane, leBottom))
  of caPinRight: rt.layout(cmdDock(target.pane, leRight))
  of caPinTop: rt.layout(cmdDock(target.pane, leTop))
  of caUnpin: rt.layout(cmdRestoreDocked(target.pane))
  of caClosePane: rt.layout(cmdRemovePane(target.pane))
  of caMaximise:
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(target.pane)
    discard rt.applyLocalAction(kaMaximizePane, outcome)
  of caCopy:
    # Monaco's Copy with nothing selected copies the caret's line, and the
    # right-click put the caret on it.
    rt.copyToClipboard(target.text & "\n", "line " & $target.line)
  of caFind:
    # The desktop's Find (Monaco's find widget): this front-end's search.
    discard rt.applyLocalAction(kaSearchForward, outcome)
  of caAddBreakpoint, caDeleteBreakpoint:
    outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,
                                          path: target.path,
                                          line: target.line))
  of caEnableBreakpoint, caDisableBreakpoint:
    outcome.requestClick(PaneClickRequest(
      kind: pcSetBreakpointEnabled, path: target.path, line: target.line,
      enabled: action == caEnableBreakpoint))
  of caDeleteBreakpointsInFile:
    outcome.requestClick(PaneClickRequest(kind: pcDeleteBreakpoints,
                                          path: target.path))
  of caDeleteAllBreakpoints:
    outcome.requestClick(PaneClickRequest(kind: pcDeleteBreakpoints))
  of caJumpToLine, caRunToCursor, caJumpBackwardToLine:
    outcome.requestClick(PaneClickRequest(
      kind: pcLineJump, path: target.path, line: target.line,
      behaviour: (case action
                  of caRunToCursor: "forward"
                  of caJumpBackwardToLine: "backward"
                  else: "smart")))
  of caJumpToCall, caJumpForwardToCall, caJumpBackwardToCall:
    if target.token.len == 0:
      rt.note(if target.tokenError.len > 0:
                target.tokenError & " on line " & $target.line & "."
              else: NoWordSelected)
    else:
      outcome.requestClick(PaneClickRequest(
        kind: pcCallJump, path: target.path, line: target.line,
        text: target.token,
        behaviour: (case action
                    of caJumpForwardToCall: "forward"
                    of caJumpBackwardToCall: "backward"
                    else: "smart")))
  of caAddTracepoint:
    # The desktop opens its tracepoint editor on the line.
    rt.openTracepointEditorAt(target.path, target.line)
  of caToggleCallChildren:
    outcome.togglesCall = true
    outcome.callIndex = target.index
  of caToggleValueHistory:
    outcome.requestClick(PaneClickRequest(kind: pcValueHistory,
                                          path: target.path))
  of caShowValueOrigin:
    # The desktop's entry SHOWS the chain (its origin panel); `o` / `:origin`
    # walk it, which is a different act.
    outcome.requestClick(PaneClickRequest(kind: pcValueOrigin,
                                          path: target.path))
  of caAddValueToScratchpad, caAddAllValuesToScratchpad:
    outcome.requestClick(PaneClickRequest(
      kind: pcScratchpadAdd, values: target.scratchpadSamplesOf(action)))
  of caJumpToValue:
    rt.note(target.expression & " = " & target.text &
            " is the value at this step")
  of caFileCreate, caFileRename, caFileDelete, caFileEdit:
    # K19: the Files pane's entries, as the shared Files model decides them.
    rt.runFilesMenuAction(action, target, outcome)
  of caAgentAttachUpload, caAgentAttachFilesFolders:
    # PLAT-54 (§2.2.7): no system file dialog here — the omnibox, on a file
    # or folder to attach.
    rt.openOmnibar(AttachQuery)
  of caAgentAttachRecording:
    rt.openOmnibar(AttachRecordingQuery)
  of caAgentAttachEditorSelection:
    rt.attachAgentContext(target.path, outcome, mustExist = false)
  of caRequestGoToHandler, caRequestCopyUrl, caRequestFilterMethod,
     caRequestFilterStatus, caRequestClearFilters:
    # PLAT-58 (K59, K60): a Requests row's entry or a picker's option, as the
    # shared Requests model decides it now.
    discard rt.actOnRequests(RequestsAct(kind: rakMenuChoice, action: action,
                                         target: target), outcome)

proc routeOverlayMouse(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## PLAT-50: an open context menu or content overlay owns the mouse: the
  ## pointer over an entry selects it, a press on an entry chooses it, a press
  ## anywhere else closes the menu (or the overlay) and does nothing else; the
  ## wheel scrolls the overlay's text.
  if rt.app.contextMenu.open:
    let screen = shellScreenOf(rt)
    let (inside, index) = rt.app.contextMenu.contextMenuHitAt(
      screen.contextMenuArea, event.row, event.col)
    case event.kind
    of mekMotion:
      if inside and index >= 0 and index != rt.app.contextMenu.selected:
        rt.app.contextMenu.hover(index)
        outcome.repaint = true
      return true
    of mekRelease:
      return true
    of mekPress:
      outcome.repaint = true
      if inside:
        if index >= 0 and event.button == mbLeft:
          let chosen = rt.app.contextMenu.choose(index)
          if chosen.chosen:
            rt.runContextAction(chosen.action, chosen.target, outcome)
          elif rt.app.contextMenu.open:
            rt.note(rt.app.contextMenu.menu.entries[index].label & ": " &
                    rt.app.contextMenu.menu.entries[index].reason)
        return true
      rt.app.contextMenu.close()
      return true
  if rt.app.content.open:
    if event.kind == mekPress:
      if event.button in {mbWheelUp, mbWheelDown}:
        rt.app.content.scroll(if event.button == mbWheelDown: 3 else: -3)
      elif event.button in {mbWheelLeft, mbWheelRight}:
        # PLAT-70: a sideways swipe is not a press; the overlay stays.
        discard
      else:
        rt.app.content = ContentOverlay()
      outcome.repaint = true
    return event.kind != mekMotion
  false

proc routeMouseReport(rt: TuiRuntime; event: MouseEvent;
                      outcome: var RuntimeOutcome) =
  ## **PLAT-6's MOUSE HALF.** One decoded SGR-1006 report, as a layout gesture.
  ##
  ## This is the twin of `runPromptLine`'s layout-verb prefix and it closes the
  ## same kind of gap: `binding.onMouse`, `beginDrag`, `hoverAt` and `dropDrag`
  ## were reachable only from a test that constructed a `LayoutBinding`, so with
  ## `--layout-binding` on a typed `:dock bottom` rearranged a real terminal and
  ## a mouse drag did nothing. `host/terminal_driver` already enables SGR-1006
  ## when the capability was negotiated, already frames a whole report into one
  ## token, and `app/input/mouse.decodeMouse` already parses it; the only thing
  ## missing was this call.
  ##
  ## ## PRECEDENCE, WHICH IS THE PART THAT IS A DECISION RATHER THAN A WIRING
  ##
  ## (PLAT-47: the call trace now takes the wheel over its body, through the
  ## `lasNoGesture` seam described below.)
  ##
  ## **Nothing else in this front-end consumed a mouse report then**, and that
  ## is measured rather than assumed. CTUI-6's `input/call_stack_keys.applyMouse`
  ## and CTUI-8's `input/timeline_keys.applyMouse` exist and are asserted, and
  ## each is reached from exactly one place: its own module's `applyKey` /
  ## `applyToken`, which in turn is called only from `tests/apps/
  ## app_call_stack.nim` and `tests/apps/app_timeline.nim`. No path from this
  ## module reaches either. So there is no contest to resolve, and the rule
  ## below is written for when there is one:
  ##
  ##   * **The layout binding is offered the report first, and consumes it.**
  ##     Every cell of the body belongs to the layout — a dock strip, a tab
  ##     strip, a pane's title row, or a pane's body — and `onMouse` already
  ##     distinguishes them. In the last case what it does is FOCUS that pane,
  ##     which is what a pane-level consumer would need to have happened first
  ##     in any case.
  ##   * **`lasNoGesture` is the seam.** It is the value that means "the layout
  ##     did not act on this", and it is where a pane router belongs when a pane
  ##     grows a mouse contract — a wheel over a pane body already answers it by
  ##     name, precisely so scrolling can be handed on rather than stolen.
  ##
  ## ## THE TWO FOCUS NOTIONS ARE SYNCHRONISED IN BOTH DIRECTIONS
  ##
  ## `LayoutBinding.focus` is what a drop acts on and `PaneFocus` is what `Tab`
  ## and `Ctrl+w` move, exactly as in `runPromptLine` — so the binding is told
  ## where the keyboard's focus is BEFORE the gesture. Unlike a typed verb, a
  ## mouse press also MOVES the binding's focus (pressing in a pane's body is
  ## how a user focuses it with a pointer), so the answer is carried BACK
  ## afterwards. Without the return leg, clicking a pane and then pressing `Tab`
  ## would continue the ring from wherever the keyboard had left it and the
  ## status bar would name a pane the user is not on.
  let binding = rt.app.layoutBinding
  let (had, focused) = rt.focus.focusedPane()
  if had:
    binding.focus = focused
  # THE PRESS IS READ AGAINST THE SCREEN (`paintedGeometry`): while a pane
  # is maximized its one rectangle, not the arrangement under it. The
  # binding is still offered what is its own on that screen — the dock
  # strips and a docked pane shown open, which a maximize leaves where they
  # were — and nothing else: a tab drag or a divider has no meaning inside
  # a maximized pane, whose tab menu (`routePaneClick`) restores it.
  let geometry = rt.paintedGeometry()
  # PLAT-55: a left press on a shown docked pane gives it the list keys.
  if event.kind == mekPress and event.button == mbLeft:
    let r = event.row
    let c = event.col
    if geometry.revealing and geometry.reveal.contains(r, c):
      rt.dockKeys = geometry.revealPane
      rt.hasDockKeys = true
    elif not geometry.openDock.isEmptyArea and geometry.openDock.contains(r, c):
      rt.dockKeys = geometry.openDockPane
      rt.hasDockKeys = true
    else:
      rt.hasDockKeys = false
  let before = binding.interaction.kind
  let bindingsOwn = not rt.maximize.active or
    geometry.stripIndexAt(event.row, event.col) >= 0 or
    (not geometry.openDock.isEmptyArea and
     geometry.openDock.contains(event.row, event.col)) or
    before in GestureInteractions
  let acted =
    if bindingsOwn: binding.onMouse(rt.layoutGeometry(), event)
    else: LayoutAction(status: lasNoGesture,
                       message: "a maximized pane's own press")
  # PLAT-49 part B: a click on a label docked its pane open (or closed it)
  # — the preview and its timers end; an overlay closed any other way (an
  # outside press) is no longer the hover machine's either.
  if acted.command.isSome and acted.command.get.kind == lcSetAutoHide and
     acted.command.get.autoHideDirection in {ahOpen, ahClose}:
    rt.autoHide.clicked()
  elif binding.interaction.kind != ikRevealingDock:
    rt.autoHide.overlayClosed()
  let inGesture = before in GestureInteractions or
                  binding.interaction.kind in GestureInteractions
  outcome.detail = acted.message
  # PLAT-49 (the user, 2026-10-01): A PLAIN CLICK SAYS NOTHING. What the
  # layout did — a drag's progress, a drop, a resize, a reveal — goes on the
  # status line; a report that did nothing to the layout (`lasNoGesture`: a
  # click that only focused a pane, a press that marked a tab, a release
  # with no drag) does not, so clicking around a pane never shows drag
  # messages like "release with no drag in flight".
  #
  # PLAT-49 part B (the user's finding 2, followed through): A CLICK THAT
  # WORKED SAYS NOTHING EITHER. A tab click used to print the layout command
  # it ran ("activateTab(vcs) applied"), a dock label's click "revealing …" —
  # an echo of a click whose result is on the screen. Only a refusal and why
  # is written for a click (`MouseNoteStatuses`). A DRAG or a RESIZE keeps
  # its running commentary (where the drop would land, what it did): that is
  # a gesture's feedback, not a click's echo.
  if acted.status in MouseNoteStatuses or
     (inGesture and acted.status != lasNoGesture):
    rt.note(acted.message)
  # PLAT-47: A WHEEL OVER THE CALL TRACE'S BODY SCROLLS IT — the hand-off
  # `lasNoGesture` exists for (the binding takes a wheel only over a tab
  # strip).
  # PLAT-49 part B: A CLICK ON THE CALL TRACE — on a row, go to that call;
  # on its toggle, expand or collapse it — as the desktop's row does
  # (`isonim_calltrace_view.rowHandlers`).
  # PLAT-70 Part B (Horizontal-Overflow.md §5.3): a press on a cut cell's
  # `…` opens its row's detail, in every table pane.
  if acted.status == lasNoGesture and not inGesture and
     rt.routeEllipsisClick(event, outcome):
    return
  if acted.status == lasNoGesture and event.kind == mekPress and
     event.button == mbLeft and not rt.app.callTrace.isEmpty:
    let idx = geometry.regionIndexAt(event.row, event.col)
    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace:
      let region = geometry.projection.regions[idx]
      let frame = paneFrame(region.area, geometry.body)
      let area = CellArea(col: region.area.col, row: region.area.row,
                          width: frame.box.width, height: frame.box.height)
      let hit = rt.app.callTrace.callTraceHitAt(area, event.row, event.col)
      case hit.kind
      of cthRow:
        outcome.jumpsToCall = true
        outcome.callIndex = hit.index
        outcome.repaint = true
        rt.rebuildFocus()
        discard rt.focus.focusPaneKind(paneCalltrace)
        return
      of cthToggle:
        outcome.togglesCall = true
        outcome.callIndex = hit.index
        outcome.repaint = true
        return
      of cthTrack, cthThumb:
        # PLAT-70 Part H: the scrollbar's (`routeScrollbars`).
        return
      of cthNone:
        discard
  # PLAT-70: a horizontal wheel over a text pane moves its view sideways
  # (Horizontal-Overflow.md §4.3). (A press on any pane's scrollbar is the
  # bar's — `routeScrollbars`, before the panes.)
  if acted.status == lasNoGesture and rt.routeHorizontalWheel(event, outcome):
    return
  if acted.status == lasNoGesture and event.kind == mekPress and
     event.button in {mbWheelUp, mbWheelDown}:
    let idx = geometry.regionIndexAt(event.row, event.col)
    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace and
       not rt.app.callTrace.isEmpty:
      rt.scrollCallTrace(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-51: the wheel scrolls the Event Log by rows (it did not scroll).
    if idx >= 0 and geometry.projection.regions[idx].pane == paneEventLog and
       rt.app.eventLog.hasContent:
      rt.scrollEventLog(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-57: the wheel scrolls Find in Files' rows (a docked one shown
    # open or revealed included).
    let at = geometry.paneAt(event.row, event.col)
    if at.found and at.region.pane == paneSearch and rt.app.search.loaded:
      rt.scrollSearch(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-56: the wheel scrolls Build Output's lines.
    if at.found and at.region.pane == paneBuildOutput and
       rt.app.buildPane.loaded:
      rt.scrollBuild(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-55: the wheel scrolls Problems' list.
    if at.found and at.region.pane == paneProblems and rt.app.problems.loaded:
      rt.scrollProblems(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-58: the wheel scrolls the Requests pane's list.
    if at.found and at.region.pane == paneRequests and
       rt.app.requests.loaded:
      rt.scrollRequests(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-53: the wheel scrolls Test Results' list.
    if at.found and at.region.pane == paneTestResults and rt.app.tests.loaded:
      rt.scrollTests(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-54: the wheel scrolls Agent Activity's lines.
    if at.found and at.region.pane == paneAgentActivity and
       rt.app.agent.loaded:
      rt.scrollAgent(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # M71 (#838): the wheel scrolls the State, Files and VCS panes — the pane
    # beneath the pointer, focused or not (CodeTracer-TUI.md §4.4).
    if at.found and at.region.pane in InHandPanes and
       rt.inHandLoaded(at.region.pane):
      rt.scrollInHand(at.region.pane, at.under,
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-52: the wheel scrolls the Terminal Output's line view.
    if idx >= 0 and
       geometry.projection.regions[idx].pane == paneTerminalOutput and
       rt.app.terminalOutput.loaded and not rt.app.terminalOutput.screenShown:
      rt.scrollTerminalOutput(
        (if event.button == mbWheelDown: TerminalWheelRows
         else: -TerminalWheelRows), outcome)
      return
    # M73 (#840): THE WHEEL OVER THE EDITOR scrolls the recording's source —
    # CodeTracer-TUI.md §4.4, "the pane beneath the pointer ... without
    # requiring pane focus" (nor taking it). The rectangle is the one the
    # editor is PAINTED into (`paintedAreaOf`), so a maximized editor takes
    # it too. The pointer and the caret stay where they are.
    if rt.sourceWindowShown and
       rt.paintedAreaOf(paneEditor).contains(event.row, event.col):
      rt.requestSourceScroll(SourceScroll(
        kind: sskBy,
        delta: (if event.button == mbWheelDown: SourceWheelRows
                else: -SourceWheelRows)), outcome)
      return
  # PLAT-50: every other press the layout did not act on is the pane's —
  # the desktop's click behaviour there (`routePaneClick`).
  if acted.status == lasNoGesture and not inGesture and
     rt.routePaneClick(geometry, event, outcome):
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(binding.focus)
    return
  if acted.status == lasApplied:
    rt.afterLayoutCommit()
  # A gesture can take a pane off the screen (a drop on a dock strip) or put one
  # back, so the ring is re-derived from the arrangement the NEXT frame will
  # paint — the same reason `runPromptLine` rebuilds it after a layout command —
  # and only then is the gesture's own pane carried into it.
  rt.rebuildFocus()
  discard rt.focus.focusPaneKind(binding.focus)
  # EVERY REPORT THE BINDING WAS OFFERED REPAINTS: a click moves focus (and
  # the focus outline with it), a gesture moves a tint or a ghost.
  # `main.nim`'s write coalescing is what keeps a dragged pointer from
  # costing a frame per report.
  outcome.repaint = true


proc writeBuffers(rt: TuiRuntime; verb: string; all = false) =
  ## Write the open buffer — or, `all`, every buffer with unsaved changes —
  ## through the host's file worker: `:w`, and the `save` / `save-all` a base
  ## binds (`Ctrl+S` under CUA, `C-x C-s` under Emacs). ONE writer, whichever
  ## asked.
  let active = if rt.app.editSession.isNil: nil
               else: rt.app.editSession.activeBuffer()
  if active.isNil:
    rt.note(verb & " needs an open file")
    return
  if rt.editServices.writeFile.isNil and rt.editServices.submitFileJob.isNil:
    rt.note(verb & " has no writer in this session")
    return
  # PLAT-29: a WRITE IS A PRODUCER. The bytes of this version go to the
  # host's file worker; its acknowledgement arrives through `deliverFileJob`,
  # which marks the buffer saved as of exactly those bytes and says
  # "wrote …". A session with no worker runs it inline, down the same path.
  for buf in rt.app.editSession.buffers:
    if buf == active or (all and buf.isDirty):
      rt.note("writing " & buf.path & "…")
      rt.runFileJob(fileJobFor(fjWrite, buf.doc, buf.path, buf.serial))

proc ensureEditWorkspace*(rt: TuiRuntime): string =
  ## Give this session an Edit-mode workspace if it has not got one: the file
  ## tree, and the first file open in a buffer. Returns the line to put on the
  ## status bar, or "" when there was nothing to do.
  ##
  ## ## WHY THIS EXISTS, AND WHAT IT CLOSES
  ##
  ## PLAT-16's landing pass found that **no shipped route had both a recording
  ## and an editable buffer**, so §2.1's stale-trace notice could not fire in
  ## the product at all:
  ##
  ##   * `ct edit --ui=tui <project>` (`main.editInteractive`) opens buffers and
  ##     has **no recording** — `app.traceName` is "" and `assessTrace` answers
  ##     `stvNoTrace`, correctly, because there is nothing for an edit to be
  ##     stale against. That is not a defect to fix; it is what `ct edit` IS.
  ##   * `ct replay --ui=tui <trace>` (`main.interactive`) has the recording and
  ##     used to reach `Ctrl+F5` with **no `EditServices` at all**, so the Edit
  ##     mode it switched into held an empty session, `activeBuffer()` was nil
  ##     and `:e` answered *"`:e` has no reader in this session"*.
  ##
  ## CodeTracer-TUI-Edit-Mode.md §6 is unambiguous about which of those two is
  ## wrong: *"`ct replay --ui=tui <trace>` opens in Debug mode. **The toggle
  ## moves between them within one session, as on the desktop.**"* So the
  ## notice belongs to the replay loop, and this is the function that gives
  ## that loop something to edit.
  ##
  ## ## IT IS CALLED FROM BOTH LOOPS, WHICH IS THE POINT (§14)
  ##
  ## One function, two callers: the toggle's `pmEdit` arm below, and
  ## `main.editInteractive` on startup. A second copy of "open the first file
  ## and fill the tree" in the entrypoint is exactly the duplicated predicate
  ## §14 is written about — and it is the copy nobody would mutate, because the
  ## entrypoint is not in any suite's module graph.
  ##
  ## ## IT RUNS ONCE PER SESSION
  ##
  ## `EditSession.furnished`, not `buffers.len > 0`: see that field. A second
  ## walk would also be a second chance to REPLACE an unsaved buffer, which
  ## Mode-Transitions.md §5 calls data loss by name.
  if rt.isNil or rt.app.isNil:
    return ""
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(rt.keymapModel, rt.keyDelivery)
  if rt.app.editSession.furnished or rt.editServices.listFiles.isNil:
    return ""
  rt.app.editSession.furnished = true
  let listing = rt.editServices.listFiles()
  rt.app.fileTree = FileTreeModel()
  rt.installProjectListing(listing)
  let where = if rt.app.projectRoot.len > 0: rt.app.projectRoot else: "."
  result = "editing " & where & " — " & $listing.files.len & " file(s)" &
    (if listing.truncated: " (truncated)" else: "")
  # If the project has a file, open the first one, so arriving in Edit mode
  # means arriving at something rather than at an empty pane. §7: "The editor
  # is never empty."
  if listing.files.len == 0 or rt.editServices.readFile.isNil:
    return
  let first = rt.editServices.readFile(listing.files[0])
  if first.ok:
    discard rt.app.editSession.openFile(listing.files[0], first.text,
                                        max(1, rt.sourcePaneRows()))
    rt.app.fileTree.openPath = listing.files[0]
    # A REFUSED KEYMAP PREFERENCE WINS TOO, on the same rule: the session is
    # running a model the user did not choose, and "editing …" reads as if
    # it were.
    if rt.keymapNotice.len > 0:
      result = rt.keymapNotice
      rt.keymapNotice = ""
  else:
    # THE REFUSAL WINS THE STATUS LINE. A user who arrived in Edit mode and got
    # an empty pane must be told why; "editing … — 12 file(s)" over an empty
    # editor is the message that reads as success.
    result = first.message

proc applyLocalAction(rt: TuiRuntime; action: KeyAction;
                      outcome: var RuntimeOutcome): bool =
  ## The actions this layer answers WITHOUT the backend: focus, maximize, the
  ## three prompt keys. Returns whether it handled `action`.
  ##
  ## Handled here rather than in `dispatchAction` because none of them is a
  ## debugger command — CTUI-10's dispatcher is about the ENGINE, and focus is
  ## about this screen.
  case action
  of kaFocusNextPane:
    let (moved, pane) = rt.focus.focusNextPane()
    if moved: rt.note("focus " & $pane)
    outcome.repaint = moved
    true
  of kaFocusPrevPane:
    let (moved, pane) = rt.focus.focusPrevPane()
    if moved: rt.note("focus " & $pane)
    outcome.repaint = moved
    true
  of kaFocusLeft, kaFocusDown, kaFocusUp, kaFocusRight:
    let (known, dir) = directionFor(action)
    if not known:
      return false
    let (moved, pane) = rt.focus.focusDirection(dir)
    if moved:
      rt.note("focus " & $pane)
    else:
      rt.note("no pane " & $dir & " of the focused one")
    outcome.repaint = true
    true
  of kaSelectCallStack, kaSelectSource, kaSelectVariables, kaSelectEventLog:
    let (known, pane) = directSelectPane(action)
    if not known:
      return false
    let moved = rt.focus.focusPaneKind(pane)
    rt.note(if moved: "focus " & $pane else: $pane & " is not on this screen")
    outcome.repaint = true
    true
  of kaMaximizePane:
    let (had, focused) = rt.focus.focusedPane()
    if not had:
      rt.note("nothing is focused, so nothing can be maximized")
      outcome.repaint = true
      return true
    discard rt.maximize.toggleMaximize(focused)
    rt.note(if rt.maximize.active: "maximized " & $focused
            else: "restored the layout")
    outcome.repaint = true
    true
  of kaOpenCommandPrompt:
    outcome.repaint = rt.openPrompt(pkCommand)
    true
  of kaSearchForward, kaSearchBackward:
    # PLAT-70 Part C: the find session, its field the status line's prompt.
    rt.openFindSession(backward = action == kaSearchBackward, symbol = false,
                       outcome)
    true
  of kaToggleBreakpoint:
    # EDIT MODE ANSWERS IT HERE; DEBUG MODE SENDS IT TO THE ENGINE. An edit
    # session has no engine — `ct edit` starts none — so `dispatchAction`'s
    # breakpoint service is absent and the key answered "unavailable" on the
    # one mode §3 of CodeTracer-TUI-Edit-Mode.md says it must work in. The
    # point goes on the edit session, at the caret of the file being edited,
    # and moves with that file's text (`edit_binding.applyEditKeyIn`).
    if rt.app.modes.product != pmEdit:
      return false
    let buf = if rt.app.editSession.isNil: nil
              else: rt.app.editSession.activeBuffer()
    if buf.isNil:
      rt.note("no file is open to place a breakpoint in")
    else:
      let line = buf.caretLine
      let placed = rt.app.editSession.togglePointAt(buf.path, line)
      rt.note((if placed: "breakpoint at " else: "removed the breakpoint at ") &
              buf.path & ":" & $line)
    outcome.detail = rt.app.notification
    outcome.repaint = true
    true
  of kaScrollLineDown, kaScrollLineUp, kaHalfPageDown, kaHalfPageUp,
     kaCenterOnPointer:
    # PLAT-47: THE CALL TRACE SCROLLS, and loads as it scrolls. These are
    # pane-local actions (`interpreter.paneLocal`); the call trace is the
    # pane that answers them here. Any other focused pane leaves them to the
    # dispatcher, exactly as before.
    let (had, focused) = rt.focus.focusedPane()
    # PLAT-52: the Terminal Output's line view scrolls the same way; `.`
    # follows the current position again.
    if had and focused == paneTerminalOutput and
       rt.app.terminalOutput.loaded and not rt.app.terminalOutput.screenShown:
      if action == kaCenterOnPointer:
        rt.app.terminalOutput.follow = true
        rt.app.terminalOutput.ensureShown(terminalPaneGeometry(
          rt.app.terminalOutput,
          rt.terminalOutputArea(rt.layoutGeometry())).contentRows)
        rt.note("terminal output follows the current position")
        outcome.repaint = true
        return true
      let area = rt.terminalOutputArea(rt.layoutGeometry())
      let rows = max(1, terminalPaneGeometry(rt.app.terminalOutput,
                                             area).contentRows)
      let (_, delta) = scrollDelta(action, rows)
      rt.scrollTerminalOutput(delta, outcome)
      return true
    # M73 (#840): THE FOCUSED EDITOR'S SOURCE SCROLLS — §4.2 Source
    # Navigation: `j` / `k` (and `Down` / `Up`, CUA's `Ctrl+Down` /
    # `Ctrl+Up`) a line, `Ctrl+d` / `Ctrl+u` half the pane, "without moving
    # execution pointer"; `.` "Reset source scroll so the current execution
    # pointer is centered". Before M73 these keys reached the dispatcher here,
    # which has no source window to move.
    if had and focused == paneEditor and rt.sourceWindowShown:
      if action == kaCenterOnPointer:
        rt.requestSourceScroll(SourceScroll(kind: sskCentreOnPointer), outcome)
      else:
        let (_, delta) = scrollDelta(action, max(1, rt.sourcePaneRows()))
        rt.requestSourceScroll(SourceScroll(kind: sskBy, delta: delta), outcome)
      return true
    if not had or focused != paneCalltrace or rt.app.callTrace.isEmpty:
      return false
    if action == kaCenterOnPointer:
      # `.`: follow the current call again.
      rt.app.callTraceScrolled = false
      rt.app.callTrace.follow = true
      outcome.pagesCallTrace = true
      outcome.repaint = true
      rt.note("call trace follows the current call")
      return true
    let (_, delta) = scrollDelta(action,
                                 max(1, rt.paneBodyRows(paneCalltrace)))
    rt.scrollCallTrace(delta, outcome)
    true
  of kaQuit:
    outcome.quit = true
    outcome.detail = QuitDetail
    true
  of kaNextSessionTab, kaPrevSessionTab:
    # CodeTracer-TUI.md §3.3.1: `g t` / `g T` (and `Ctrl+Tab` /
    # `Ctrl+Shift+Tab` where the terminal reports them) step the session
    # tabs, wrapping. With one session there is no other tab, and the status
    # line says so rather than the key doing nothing silently.
    let delta = if action == kaNextSessionTab: 1 else: -1
    if rt.app.shell.stepTab(delta):
      let tabs = rt.app.shell.tabsOf()
      let at = rt.app.shell.activeTabIndex()
      rt.note("session " & $(at + 1) & " of " & $tabs.len & ": " &
              tabs[at].title)
    else:
      rt.note("only one session is open; there is no other tab to switch to")
    outcome.detail = rt.app.notification
    outcome.repaint = true
    true
  of kaToggleProductMode:
    # PLAT-16 / Mode-Transitions.md. `Ctrl+F5`.
    #
    # HANDLED LOCALLY AND NOT BY `dispatchAction`, on exactly the rule this
    # procedure's docstring states: CTUI-10's dispatcher is about the ENGINE,
    # and a product-mode switch is about this session's workspace. It sends
    # nothing to a backend — §1 of Mode-Transitions.md: the transition proper
    # "is instant in both directions, because both modes' state is already in
    # memory".
    let profile = selectProfile(rt.width, rt.height)
    let changed =
      if rt.layoutBindingEnabled(): rt.toggleBoundArrangement(profile)
      else: rt.app.modes.toggle(rt.app.shellModel(rt.width, rt.height).layout,
                                profile)
    if not changed:
      # Unreachable through `toggled`, which never answers the current mode.
      # Reported rather than dropped so a future caller of `switchTo` with an
      # explicit target cannot make an idempotent switch look like a working
      # one.
      rt.note("already in " & $rt.app.modes.product & " mode")
      outcome.repaint = true
      return true
    # THE NOTICE IS THE DELIVERABLE, not the switch. §2.1 consequence 3: a user
    # who edits and then toggles back onto an EXISTING trace is looking at a
    # recording their own edits have outrun, and must be told once, plainly.
    # `rt.app.traceName` is what says a recording is open at all — the toggle
    # onto no trace has nothing to be stale about, which is `stvNoTrace`.
    var message = "switched to " & $rt.app.modes.product & " mode"
    if rt.app.modes.product == pmEdit:
      # ARRIVING IN EDIT MODE MEANS ARRIVING AT SOMETHING. Until PLAT-16's
      # landing pass this arm only allocated an empty `EditSession`, so a
      # `ct replay` session that pressed `Ctrl+F5` reached an editor with no
      # buffer, no file tree and no reader — and therefore no route on which
      # the notice below could ever be produced. See `ensureEditWorkspace`.
      let furnished = rt.ensureEditWorkspace()
      if furnished.len > 0:
        message = furnished
    elif not rt.app.editSession.isNil:
      let notice = rt.app.editSession.noticeForSwitchToDebug(
        rt.app.traceName.len > 0)
      if notice.len > 0:
        message = notice
    rt.note(message)
    outcome.detail = message
    rt.rebuildFocus()
    # THE EDITOR TAKES THE FOCUS ON ARRIVAL, and it has to: a typed byte is
    # text only while the editor is on the scope path the router resolves
    # with, so a user who toggled into Edit mode and started typing would
    # otherwise be issuing keybindings at their own source. `rebuildFocus`
    # above re-derives the ring from the arrangement the next frame paints —
    # Edit mode's panes are not Debug's — and this names which of them wins.
    # Only when there is a buffer to type into: on an empty project the ring's
    # own answer is the honest one.
    if rt.app.modes.product == pmEdit and not rt.app.editSession.isNil and
       not rt.app.editSession.activeBuffer().isNil:
      discard rt.focus.focusPaneKind(paneEditor)
    outcome.repaint = true
    true
  else:
    false

# ---------------------------------------------------------------------------
# PLAT-48 — the top bar: the menu, the debugger controls, the omnibar, the
# session tabs, and the auto-hide strips' key
# ---------------------------------------------------------------------------

const
  MenuOperations = ["menu.open", "menu.toggle", "menu.open-folder"]
    ## The keymap's menu keys (CUA-Keymap.md §3.8: `` Alt+` ``,
    ## `Alt+<mnemonic>`, `F10` in Edit mode; Vim's `F12`). The menu is also a
    ## click on `≡` or a folder title.

proc probeKey*(rt: TuiRuntime; name: string): EditingResolution
proc refreshMenuAvailability*(rt: TuiRuntime)
  ## Forward-declared; defined beside the menu's action table below.

proc runMenuOperation(rt: TuiRuntime; operation, argument: string) =
  ## A menu key, whether the menu is open or not: `menu.open-folder(x)`
  ## opens folder x; `menu.open` and `menu.toggle` open the menu when it is
  ## closed and close it when it is open (VS Code's Alt and F10 both toggle).
  let vm = rt.app.menu
  # What is enabled is read for the state the menu opens in (codetracer#841).
  if not vm.isOpen or operation == "menu.open-folder":
    rt.refreshMenuAvailability()
  if operation == "menu.open-folder":
    let i = vm.folderIndexOf(argument)
    if i < 0:
      rt.note("menu: no " & argument & " folder")
      return
    vm.openFolder(i)
  elif vm.isOpen:
    vm.close()
    return
  else:
    vm.open(keyboard = true)
  rt.note("menu: arrows to move, Enter to choose, Esc to close")

proc transportKeyAction*(id: string): KeyAction =
  ## The terminal's action for a debugger control (`TransportControls` id).
  case id
  of "reverse-next": kaReverseStepOver
  of "next": kaStepOver
  of "reverse-step-in": kaReverseStepInto
  of "step-in": kaStepInto
  of "reverse-step-out": kaReverseStepOut
  of "step-out": kaStepOut
  of "reverse-continue": kaReverseContinue
  of "continue": kaContinue
  of "run-to-entry": kaJumpToStart
  else: kaNone

proc menuKeyAction*(action: string): KeyAction =
  ## The terminal's key action for a menu item's `ClientAction`, or `kaNone`.
  case action
  of "forwardContinue": kaContinue
  of "reverseContinue": kaReverseContinue
  of "forwardNext": kaStepOver
  of "reverseNext": kaReverseStepOver
  of "forwardStep": kaStepInto
  of "reverseStep": kaReverseStepInto
  of "forwardStepOut": kaStepOut
  of "reverseStepOut": kaReverseStepOut
  of "aBreakpoint": kaToggleBreakpoint
  of "aExit": kaQuit
  else: kaNone

proc menuPaneOf*(action: string): (bool, PaneKind) =
  ## The pane a View-menu item shows.
  case action
  of "aFilesystem": (true, paneFileTree)
  of "aFullCalltrace": (true, paneCalltrace)
  of "aState": (true, paneState)
  of "aEventLog": (true, paneEventLog)
  of "aTerminal": (true, paneTerminalOutput)
  of "aScratchpad": (true, paneScratchpad)
  of "aPointList": (true, panePointList)
  of "aAgentActivity": (true, paneAgentActivity)
  else: (false, paneEditor)

proc menuPromptLine*(action: string): string =
  ## The `:` line a menu item is, for the items that are one.
  case action
  of "aResetLayout": ":reset-layout"
  of "aTheme3": ":theme dark"
  of "aTheme1": ":theme light"
  else: ""

proc menuOmnibarQuery*(action: string): (bool, string) =
  case action
  of "findSymbol": (true, ":sym ")
  of "findInFiles": (true, ":grep ")
  else: (false, "")

type
  MenuRouteKind* = enum
    ## How the terminal performs a menu item (`menuRouteOf`).
    mrNone
      ## Not something the terminal does.
    mrKey
      ## A key action (`menuKeyAction`), through `performAction`.
    mrPane
      ## A View-menu pane brought forward (`menuPaneOf`).
    mrPromptLine
      ## A `:` line (`menuPromptLine`).
    mrFindInFiles
      ## Find in Files shown, its field open.
    mrOmnibar
      ## The omnibar opened on a query (`menuOmnibarQuery`).
    mrNewTab
      ## File › New Trace Tab: the strip's "+".
    mrWelcomeOption
      ## File › Open Trace… / Open Trace in New Tab… / Record New Trace…: a
      ## welcome tab's start option (`option`), in a new tab or the shown one.
    mrBuffer
      ## File › Close / Reopen / Next / Previous / Switch File: Edit mode's
      ## open buffers (`buffer`).
    mrStop
      ## M76 (codetracer#843): Debug › Stop — `stopDebugging`, the chord's and
      ## the toolbar control's performer too.
    mrPoint
      ## M76: a Debug-menu breakpoint or tracepoint item (`point`, the shared
      ## `point_menu_ops` table GPUI's menu reads too), at the editor caret.

  MenuBufferOp* = enum
    mboClose, mboReopen, mboNext, mboPrevious, mboSwitch

  MenuRoute* = object
    ## THE TERMINAL'S ANSWER FOR ONE MENU ITEM, NOW: how it is performed and,
    ## when it cannot be performed in the current state, why not.
    kind*: MenuRouteKind
    key*: KeyAction
    pane*: PaneKind
    line*: string
      ## `mrPromptLine`'s line; `mrOmnibar`'s query.
    option*: WelcomeStartOptionKind
    newTab*: bool
      ## `mrWelcomeOption`: always a new welcome tab (Open Trace in New Tab…),
      ## or the shown welcome tab when there is one.
    buffer*: MenuBufferOp
    point*: PointMenuOp
      ## `mrPoint`'s operation.
    reason*: string
      ## Non-empty when the item cannot run now — what the menu shows it
      ## disabled with and says when it is chosen (EMT-D14).

const
  NoMenuHostReason* =
    "this terminal has no host to open a recording or record a program in"
    ## The trace and tab items in a runtime no host has given a welcome flow
    ## (an in-process caller with no engine to spawn).
  BufferItemsInDebugReason* =
    "in Debug mode the editor shows the file the recording is at; the open " &
    "files are Edit mode's"
  NoFileOpenReason* = "no file is open"
  OneFileOpenReason* = "only one file is open"
  NoOtherFileShownReason* = "no other open file has been shown"
  NoClosedFileReason* = "no file has been closed"
  NoFileReaderReason* = "this session has no file reader to reopen it with"
  NoDebugSessionReason* = "there is no debugging session to stop"
    ## M76: Stop with no replay behind the runtime (`ct edit`, or after Stop).
  PointsNeedReplayReason* =
    "the breakpoint and tracepoint items act on a replay: open a recording " &
    "to debug it"
  PointsInEditModeReason* =
    "in Edit mode the breakpoint and tracepoint items act on the replay; " &
    "Ctrl+F5 switches to Debug mode"
  NoRecordingFileReason* = "the editor shows no file of the recording"

proc pointMenuReason(rt: TuiRuntime): string =
  ## M76: why a Debug-menu point item cannot run now, or "" when it can — it
  ## acts on the replay, at the caret of the recording file the editor shows.
  if not rt.app.hasDebugSession: PointsNeedReplayReason
  elif rt.app.modes.product != pmDebug: PointsInEditModeReason
  elif rt.app.source.path.len == 0: NoRecordingFileReason
  else: ""

func unsavedCloseReason(path: string): string =
  ## Close Current File on a buffer with unsaved changes. The desktop asks in a
  ## save dialog (`closeActiveTab`); the terminal has none, and closing would
  ## discard the changes — Mode-Transitions.md §5's data loss by name — so the
  ## item is refused, and says how to make it run.
  path & " has unsaved changes: write it (:w) or reload it (:e!) first"

proc menuBufferReason(rt: TuiRuntime; op: MenuBufferOp): string =
  ## Why buffer item `op` cannot run now, or "" when it can.
  if rt.app.modes.product != pmEdit:
    return BufferItemsInDebugReason
  let s = rt.app.editSession
  if op == mboReopen:
    if s.reopenCandidate().len == 0: return NoClosedFileReason
    if rt.editServices.readFile.isNil: return NoFileReaderReason
    return ""
  if s.isNil or s.activeBuffer().isNil:
    return NoFileOpenReason
  case op
  of mboClose:
    if s.activeBuffer().isDirty:
      return unsavedCloseReason(s.activeBuffer().path)
  of mboNext, mboPrevious:
    if s.buffers.len < 2: return OneFileOpenReason
  of mboSwitch:
    if s.previouslyShownBuffer() == NoBuffer: return NoOtherFileShownReason
  of mboReopen:
    discard
  ""

proc menuRouteOf*(rt: TuiRuntime; action: string): MenuRoute =
  ## THE ONE TABLE from a menu item's `ClientAction` to what the terminal does
  ## with it, read by BOTH `menuAvailability` (what the menu shows enabled)
  ## and `runMenuAction` (what choosing it does), so "enabled" and "can run"
  ## are one answer and cannot drift (codetracer#841: the enabled set was a
  ## second, static copy that had stopped listing what the terminal performs).
  ##
  ## STATE-AWARE: an item that depends on the session's state — a host to open
  ## a recording with, the files open in Edit mode — carries the reason it
  ## cannot run now, and the menu re-reads this whenever it opens.
  let ka = menuKeyAction(action)
  if ka != kaNone:
    return MenuRoute(kind: mrKey, key: ka)
  let (isPane, pane) = menuPaneOf(action)
  if isPane:
    return MenuRoute(kind: mrPane, pane: pane)
  let line = menuPromptLine(action)
  if line.len > 0:
    return MenuRoute(kind: mrPromptLine, line: line)
  if action == "findInFiles":
    return MenuRoute(kind: mrFindInFiles)
  let (isOmni, query) = menuOmnibarQuery(action)
  if isOmni:
    return MenuRoute(kind: mrOmnibar, line: query)
  # File. The trace and tab items are the Welcome Screen's own flows
  # (Multi-Window-Tab-Management.md rule 3, Welcome-Screen.md § The native
  # front-ends): a new tab showing it, or one of its start options' forms —
  # the terminal's dialog — whose choice the host performs. A recording opens
  # in the welcome tab's place, so in a new session tab: the spec's default
  # (§ Which tab a replay opens in), never an automatic replacement.
  case action
  of "aNewTraceTab":
    # The "+" (`thTabAdd`): the welcome flow, or the `:open ` omnibar of a
    # host that opens recordings but has no welcome flow.
    result = MenuRoute(kind: mrNewTab)
    if rt.app.welcomeHost.isNil and rt.app.recordingOpener.isNil:
      result.reason = NoMenuHostReason
  of "aOpenTrace", "aOpenTraceInNewTab", "aRecordNewTrace":
    result = MenuRoute(kind: mrWelcomeOption,
                       option: (if action == "aRecordNewTrace": wsoRecordNewTrace
                                else: wsoOpenLocalTrace),
                       newTab: action == "aOpenTraceInNewTab")
    if rt.app.welcomeHost.isNil:
      result.reason = NoMenuHostReason
  of "closeTab", "reopenTab", "switchTabRight", "switchTabLeft",
     "switchTabHistory":
    let op = case action
             of "closeTab": mboClose
             of "reopenTab": mboReopen
             of "switchTabRight": mboNext
             of "switchTabLeft": mboPrevious
             else: mboSwitch
    result = MenuRoute(kind: mrBuffer, buffer: op)
    result.reason = rt.menuBufferReason(op)
  of StopMenuAction:
    # M76: Stop ends the session behind the tab; with none, it is disabled
    # and says so.
    result = MenuRoute(kind: mrStop)
    if not rt.app.hasDebugSession:
      result.reason = NoDebugSessionReason
  else:
    let op = pointMenuOpOf(action)
    if op != pmoNone:
      result = MenuRoute(kind: mrPoint, point: op, reason: rt.pointMenuReason())
    else:
      result = MenuRoute(kind: mrNone, reason: "not available in the terminal")

proc menuAvailability*(rt: TuiRuntime; action: string): MenuAvailability =
  ## Whether the terminal can perform menu item `action` now, and why not.
  let route = rt.menuRouteOf(action)
  if route.reason.len > 0: unavailable(route.reason) else: availableNow()

proc refreshMenuAvailability*(rt: TuiRuntime) =
  ## Mark the menu's items from `menuRouteOf` for the CURRENT state. Run
  ## whenever the menu is about to be shown or listed — it opens, the omnibar
  ## lists its commands — so what is enabled follows what the terminal can do
  ## now, not what it could do at start-up. The rest are drawn DISABLED, not
  ## dropped, so every front-end shows the same menu.
  if rt.isNil or rt.app.isNil or rt.app.menu.isNil:
    return
  rt.app.menu.setAvailability(proc(action: string): MenuAvailability =
    rt.menuAvailability(action))

proc chordOf*(rt: TuiRuntime; action: KeyAction): string =
  ## The chord that RUNS `action` where the focus is now — what the menu
  ## and a control's tooltip display (KL-8): resolved by the router from
  ## the active base and the user's `keybindings.json`, so a rebinding is
  ## shown the moment it loads and a shadowed row is never shown.
  let op = operationOfAction(action)
  if op.len == 0:
    return ""
  let (name, arg) = splitOperation(op)
  let path = rt.scopePath
  rt.router.chordFor(name, rt.sessionFacts, path, rt.navMode, arg)

proc refreshMenuForKeymap*(rt: TuiRuntime) =
  ## Enable the items the terminal performs and show the ACTIVE keymap's
  ## chords beside them. Run at start-up and after every keymap switch; what
  ## is enabled is read again whenever the menu opens
  ## (`refreshMenuAvailability`).
  var chords = initTable[string, string]()
  for (_, it) in rt.app.menu.root.actionItems():
    let chord = rt.chordOf(menuKeyAction(it.action))
    if chord.len > 0:
      chords[it.action] = chord
  let (hasPalette, _) = menuOmnibarQuery("findSymbol")
  if hasPalette:
    let chord = rt.chordOf(kaCommandPalette)
    if chord.len > 0:
      chords["findSymbol"] = chord
  # M76: Stop is an operation the router resolves (`debugger.stop`), not a
  # `KeyAction`; its chord is asked for by the operation's name.
  let stopChord = rt.router.chordFor("debugger.stop", rt.sessionFacts,
                                     rt.scopePath, rt.navMode, "")
  if stopChord.len > 0:
    chords[StopMenuAction] = stopChord
  rt.refreshMenuAvailability()
  rt.app.menu.setShortcuts(chords)
  rt.app.refreshOmnibarIndex()

proc performAction(rt: TuiRuntime; action: KeyAction;
                   outcome: var RuntimeOutcome) =
  ## One resolved action, end to end: its product-mode scope, its modal
  ## transition, a local answer, or the dispatcher — the path a key takes
  ## once `keymap.resolve` named its action, shared by the menu, the
  ## debugger controls and the omnibar so a click and a key cannot differ.
  outcome.action = action
  if not appliesIn(action, rt.app.modes.product):
    outcome.detail = inertReason(action, rt.app.modes.product)
    rt.note(outcome.detail)
    outcome.repaint = true
    return
  let (known, ev) = modalEventFor(action)
  if known:
    let transition = rt.modal.applyModalEvent(ev)
    if not transition.accepted:
      rt.note(describeTransition(transition))
      outcome.repaint = true
      return
  if rt.applyLocalAction(action, outcome):
    return
  let dispatch = dispatchAction(rt.dispatcher, rt.context, action)
  outcome.detail = dispatch.detail
  rt.note(dispatch.detail)
  outcome.repaint = true
  if dispatch.status == drDone and movesTheDebugger(action):
    if action == kaValueOrigin and dispatch.detail.startsWith(OriginPendingText):
      outcome.awaitsOrigin = true
    else:
      outcome.awaitsMove = true
  if dispatch.status == drDone and changesSessionState(action):
    outcome.refreshesSession = true

proc omnibarHit(rt: TuiRuntime; screen: ShellScreen;
                event: MouseEvent): (bool, int) =
  var bar = rt.app.shellModel(rt.width, rt.height).topBar
  bar.header = rt.app.shellModel(rt.width, rt.height).header
  omnibarHitAt(bar, screen.topBarLayout, rt.width, rt.height, event.row,
               event.col)

proc welcomeFolderDefault(rt: TuiRuntime): string =
  ## What "Open folder" offers first: this process's project root.
  if rt.app.projectRoot.len > 0: rt.app.projectRoot else: "."

proc runWelcomeIntent*(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## PLAT-51 deliverable 8: the shown welcome tab's choice, handed to the
  ## host (`welcomeHost`) — which turns the tab into the session it starts.
  ## A refusal stays on the screen, in its message line.
  let w = rt.app.shownWelcome()
  if w.isNil:
    return
  let intent = w.takeIntent()
  if intent.kind == niNone:
    return
  outcome.repaint = true
  if rt.app.welcomeHost.isNil:
    w.message = "this terminal cannot " & $intent.kind
    return
  let why = rt.app.welcomeHost(rt.app.welcomeTabs.active, intent)
  if why.len > 0:
    w.message = why

proc setProductMode(rt: TuiRuntime; product: ProductMode;
                    outcome: var RuntimeOutcome) =
  ## Bring the session to `product` (Debug or Edit) through the same toggle
  ## `Ctrl+F5` performs, when it is not there already.
  if rt.app.modes.product != product:
    discard rt.applyLocalAction(kaToggleProductMode, outcome)

proc enterProductMode*(rt: TuiRuntime; product: ProductMode) =
  ## The host's door to `setProductMode` (a welcome tab that became a
  ## folder arrives in Edit mode); the arrival's own furnishing runs.
  var o = RuntimeOutcome()
  if rt.app.modes.product != product:
    rt.setProductMode(product, o)
  elif product == pmEdit:
    discard rt.ensureEditWorkspace()

proc hasDebugSession*(rt: TuiRuntime): bool =
  ## Whether a replay session is behind this runtime — the host pointed the
  ## panes at one (`tui_session.refresh` installs its store) and *Stop* has
  ## not made the runtime forget it (`forgetSession`).
  not rt.app.store.isNil

proc forgetSession*(rt: TuiRuntime) =
  ## M76: the runtime's half of *Stop* ending a session — every handle the
  ## host gave it onto that session dropped, so the tab is an edit tab that
  ## is "indistinguishable from one that was never run" (Debugger-Controls.md
  ## § "Ending a session from inside it", requirement 3): no recording name
  ## (so a later `Ctrl+F5` onto the debugger is the empty debugger, with no
  ## stale-trace notice about a recording that is no longer open), no engine
  ## behind the dispatcher (a step answers "unavailable" instead of writing to
  ## a closed pipe), and the debugger's panes back to what a runtime with no
  ## session shows. The Edit-mode workspace — its buffers, the project's file
  ## tree — is the user's and is kept.
  # The panes' values with no session are READ from the one constructor that
  # defines them (`newTuiApp`), not restated here, so "what the empty
  # debugger shows" has one definition. Creating it opens nothing.
  let blank = newTuiApp()
  rt.app.store = nil
  rt.app.controls = nil
  rt.app.filesVM = nil
  rt.app.traceName = ""
  rt.app.tick = 0
  rt.app.totalTicks = 0
  rt.app.location = ""
  rt.app.viewedFile = ""
  rt.app.source = blank.source
  rt.app.callStack = blank.callStack
  rt.app.callTrace = blank.callTrace
  rt.app.callTraceLoaded = false
  rt.app.callTraceScrolled = false
  rt.app.callTraceAtEnd = false
  rt.app.variables = blank.variables
  rt.app.eventLog = blank.eventLog
  rt.app.points = blank.points
  rt.app.scratchpad = blank.scratchpad
  rt.app.terminalOutput = blank.terminalOutput
  rt.app.search = blank.search
  rt.app.openHistories.clear()
  rt.app.openOrigins = @[]
  rt.app.tracepointAt = ("", 0)
  rt.app.content = ContentOverlay()
  rt.editServices.readSource = nil
  rt.dispatcher = Dispatcher(services: CommandServices(
    setTheme: rt.themeService))
  rt.context = CommandContext()
  rt.app.refreshOmnibarIndex()

proc showWelcomeTab*(rt: TuiRuntime; index: int; outcome: var RuntimeOutcome) =
  ## Show welcome tab `index`: its Welcome Screen, or — a tab that became an
  ## Edit-mode session over a folder — Edit mode at that folder (the host
  ## re-roots the workspace when another folder was shown).
  if index < 0 or index >= rt.app.welcomeTabs.tabs.len:
    return
  rt.app.welcomeTabs.active = index
  outcome.repaint = true
  let tab = rt.app.welcomeTabs.tabs[index]
  if tab.kind == wtkFolder and not rt.app.welcomeHost.isNil:
    let why = rt.app.welcomeHost(index, NativeWelcomeIntent(kind: niOpenFolder,
                                                            path: tab.folder))
    if why.len > 0:
      rt.note(why)
    rt.setProductMode(pmEdit, outcome)

proc showSessionTab*(rt: TuiRuntime; index: int; outcome: var RuntimeOutcome) =
  ## Show session tab `index` — the welcome tabs step back, and a session is
  ## a replay: Debug mode.
  let wasFolder = rt.app.welcomeTabs.welcomeShown and
                  rt.app.welcomeTabs.shownTab.kind == wtkFolder
  rt.app.welcomeTabs.active = -1
  discard rt.app.shell.activateTab(index)
  if wasFolder:
    rt.setProductMode(pmDebug, outcome)
  outcome.repaint = true

proc openWelcomeTab*(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## The strip's "+" (Multi-Window-Tab-Management.md rule 3): a new tab
  ## showing the Welcome Screen, from the shared model, with the folders and
  ## recordings this process knows.
  var traces: seq[string] = @[]
  for e in rt.app.recordings:
    traces.add e.target
  let wasFolder = rt.app.welcomeTabs.welcomeShown and
                  rt.app.welcomeTabs.shownTab.kind == wtkFolder
  discard rt.app.welcomeTabs.addWelcomeTab()
  rt.app.welcomes.add newNativeWelcome(rt.app.recentFolders, traces)
  if wasFolder:
    rt.setProductMode(pmDebug, outcome)
  rt.note("new tab: open a folder, record a program or open a recording")
  outcome.repaint = true

proc closeWelcomeTabAt*(rt: TuiRuntime; index: int;
                        outcome: var RuntimeOutcome) =
  if index < 0 or index >= rt.app.welcomeTabs.tabs.len:
    return
  let wasShownFolder = rt.app.welcomeTabs.active == index and
                       rt.app.welcomeTabs.tabs[index].kind == wtkFolder
  rt.app.welcomeTabs.closeWelcomeTab(index)
  if index < rt.app.welcomes.len:
    rt.app.welcomes.delete(index)
  if wasShownFolder:
    rt.setProductMode(pmDebug, outcome)
  outcome.repaint = true

proc routeWelcomeKey(rt: TuiRuntime; token: string;
                     outcome: var RuntimeOutcome): bool =
  ## PLAT-51: a key while a Welcome Screen is shown. Its form takes every
  ## printable key; the screen takes the arrows, Tab and Enter; anything else
  ## (`q`, `:`, the chords) is the terminal's as everywhere.
  let w = rt.app.shownWelcome()
  if w.isNil or rt.app.menu.isOpen or rt.app.omnibar.isOpen or rt.prompt.open:
    return false
  let name = rt.keyOf(token)
  var key = name
  if isTextKey(name):
    key = keyCharacter(name)
  if w.form == nwfNone and key.len == 1 and key notin [" "]:
    return false
  if not w.applyKey(key, rt.welcomeFolderDefault()):
    return false
  outcome.repaint = true
  rt.runWelcomeIntent(outcome)
  true

proc routeWelcomeMouse(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## PLAT-51: a press on the Welcome Screen's rows — a recent entry opens, an
  ## option opens its form (or says why it is refused). The body is the
  ## screen's; nothing under it is a layout gesture.
  let w = rt.app.shownWelcome()
  if w.isNil or event.row == 0 or event.row >= rt.height - 1:
    return false
  if event.kind != mekPress or event.button != mbLeft:
    return event.kind != mekMotion
  let screen = rt.shellScreenOf()
  let at = screen.welcomeLayout.welcomeRowAt(event.row, event.col)
  if at >= 0:
    w.activate(at, rt.welcomeFolderDefault())
    rt.runWelcomeIntent(outcome)
  outcome.repaint = true
  true

proc openOmnibar*(rt: TuiRuntime; query = "") =
  if rt.app.menu.isOpen:
    rt.app.menu.close()
  # The omnibar lists the menu's ENABLED commands: read them for now.
  rt.refreshMenuAvailability()
  rt.app.refreshOmnibarIndex()
  rt.app.omnibar.open(query)
  if query == OpenRecordingQuery:
    rt.note("new tab: choose a recording, or type its folder")
  elif query == AttachQuery:
    rt.note("attach to the agent's next prompt: choose a file or folder, " &
            "or type its path")
  elif query == AttachRecordingQuery:
    rt.note("attach to the agent's next prompt: choose a recording, or " &
            "type its folder")
  else:
    rt.note("omnibar: type a file, :sym <function>, :<command> or #<tick>")

proc addTab*(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## The strip's "+" and *File › New Trace Tab*, one performer
  ## (Multi-Window-Tab-Management.md rule 3: "The "+" button (and File › New
  ## Trace Tab) opens a new tab showing the Welcome Screen"). PLAT-49 part B
  ## opened the omnibar on `:open ` instead; a host with no welcome flow still
  ## does.
  if not rt.app.welcomeHost.isNil:
    rt.openWelcomeTab(outcome)
  else:
    rt.openOmnibar(OpenRecordingQuery)
    outcome.repaint = true

proc openWelcomeOption(rt: TuiRuntime; option: WelcomeStartOptionKind;
                       newTab: bool; outcome: var RuntimeOutcome) =
  ## *File › Open Trace…* / *Open Trace in New Tab…* / *Record New Trace…*:
  ## the Welcome Screen's start option `option`, chosen — its form opened, the
  ## terminal's dialog, whose choice the host performs (`runWelcomeIntent`).
  ## In the shown welcome tab unless `newTab` or none is shown, the desktop's
  ## *Open Trace in New Tab…* being a new tab and then the dialog.
  ##
  ## M76: chosen without `newTab` on a session tab whose session *Stop*
  ## ended, the welcome tab this opens stands in for THAT tab: what it opens
  ## starts its session in the stopped tab (`TuiApp.stoppedTabWelcome`,
  ## which the host reads). Debugger-Controls.md § "Ending a session from
  ## inside it", requirement 3.
  let fromStoppedTab = not newTab and not rt.app.welcomeTabs.welcomeShown and
                       not rt.app.shell.activeSlot().isNil and
                       not rt.hasDebugSession
  if newTab or rt.app.shownWelcome().isNil:
    rt.openWelcomeTab(outcome)
    if fromStoppedTab:
      let tabs = rt.app.welcomeTabs
      if tabs.active >= 0 and tabs.active < tabs.tabs.len:
        rt.app.stoppedTabWelcome = tabs.tabs[tabs.active].serial
  let w = rt.app.shownWelcome()
  if w.isNil:
    rt.note("there is no welcome tab to open the form in")
    outcome.repaint = true
    return
  w.chooseOption(option, rt.welcomeFolderDefault())
  rt.note(if w.form != nwfNone: formPrompt(w.form) & "type it, Enter to " &
            "choose, Esc to close"
          else: w.message)
  outcome.repaint = true

proc runBufferOp(rt: TuiRuntime; op: MenuBufferOp;
                 outcome: var RuntimeOutcome) =
  ## *File › Close / Reopen / Next / Previous / Switch File* over Edit mode's
  ## buffers (the session's `EditSession`). `menuRouteOf` has already said the
  ## operation can run; what it cannot know in advance — a reopened file that
  ## is no longer readable — is said here.
  let s = rt.app.editSession
  outcome.repaint = true
  case op
  of mboNext, mboPrevious:
    discard s.stepBuffer(if op == mboNext: 1 else: -1)
  of mboSwitch:
    s.activateBuffer(s.previouslyShownBuffer())
  of mboClose:
    let closed = s.closeActiveBuffer()
    rt.note("closed " & closed)
  of mboReopen:
    let path = s.reopenCandidate()
    let read = rt.editServices.readFile(path)
    if not read.ok:
      rt.note(read.message)
      return
    discard s.openFile(path, read.text, max(1, rt.sourcePaneRows()))
  let buf = s.activeBuffer()
  if not buf.isNil:
    rt.app.fileTree.openPath = buf.path
    if op != mboClose:
      rt.note("editing " & buf.path)
    discard rt.focus.focusPaneKind(paneEditor)

proc showPane(rt: TuiRuntime; pane: PaneKind; outcome: var RuntimeOutcome) =
  ## A View-menu item: bring `pane` forward — reveal it when it is docked,
  ## activate its tab and focus it when it is placed.
  if not rt.layoutBindingEnabled():
    rt.note($pane & ": the layout is not rearrangeable in this session")
    return
  let b = rt.app.layoutBinding
  let at = b.layout.dockedIndex(pane)
  if at >= 0 and b.layout.docked[at].open:
    # PLAT-58: DOCKED AND ALREADY OPEN at its edge — it is on screen, so it
    # is focused, not revealed again as a hover overlay over itself (a reveal
    # left a dock gesture live that took the next Esc).
    b.focus = pane
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(pane)
    rt.note("focus " & $pane)
  elif at >= 0:
    let acted = b.beginRevealDock(pane)
    rt.note(acted.message)
  elif b.layout.tree.contains(pane):
    let acted = b.dispatch(cmdActivateTab(pane))
    if acted.status == lasApplied:
      rt.afterLayoutCommit()
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(pane)
    b.focus = pane
    rt.note("focus " & $pane)
  else:
    # PLAT-50: A PANE THE ARRANGEMENT DOES NOT PLACE IS OPENED, as the
    # desktop's View menu opens its panel — a tab beside the event log
    # (the event stack), else at the root.
    let anchor = if b.layout.tree.contains(paneEventLog): some(paneEventLog)
                 else: none(PaneKind)
    let added = b.dispatch(cmdAddPane(pane, after = anchor))
    if added.status == lasApplied:
      rt.afterLayoutCommit()
      rt.rebuildFocus()
      discard rt.focus.focusPaneKind(pane)
      b.focus = pane
      rt.note("opened " & $pane)
    else:
      rt.note($pane & ": " & added.message)
  outcome.repaint = true

proc openFindInFiles(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `search.find-in-files` with no pattern — `Ctrl+Shift+F` under CUA, the
  ## Edit menu's Find in Files, `:grep` alone, a press on the pane's field:
  ## Find in Files shown (`showPane`'s rule) and its field opened. The
  ## terminal's field is the omnibox's `:grep` line, holding the pane's
  ## current query (Find-And-Incremental-Search.md §5.2).
  rt.showPane(paneSearch, outcome)
  rt.openOmnibar(":grep " & rt.app.search.query)
  outcome.repaint = true

proc runFindInFiles(rt: TuiRuntime; pattern: string;
                    outcome: var RuntimeOutcome) =
  ## `:grep <pattern>` (§5.1): the host's search of the recording's sources
  ## into Find in Files, which is shown (`showPane`'s rule). Nothing opens:
  ## the user's OQ-F2, *"Only open the results panel"*.
  outcome.repaint = true
  if rt.app.findInFiles.isNil:
    rt.note("Find in Files needs a recording or a project to search")
    return
  let why = rt.app.findInFiles(pattern)
  rt.showPane(paneSearch, outcome)
  rt.note(if why.len > 0: why
          else: "searching the sources for \"" & pattern & "\"")

proc stepFindInFiles(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## `search.next-result` / `search.previous-result`: the host selects the
  ## next / previous result and opens it at its line (§5.3).
  outcome.repaint = true
  if rt.app.stepSearchResult.isNil:
    rt.note("there are no search results")
    return
  let why = rt.app.stepSearchResult(delta)
  if why.len > 0:
    rt.note(why)

proc stopDebugging(rt: TuiRuntime; outcome: var RuntimeOutcome)
proc runPointMenuItem(rt: TuiRuntime; op: PointMenuOp; action: string;
                      outcome: var RuntimeOutcome)

proc runMenuAction*(rt: TuiRuntime; action: string;
                    outcome: var RuntimeOutcome) =
  ## A chosen menu item (or omnibar command), in the terminal's terms.
  # PLAT-71: **Terminal: Show Capabilities** (`:terminal-info`).
  if action == TerminalInfoCommandTarget:
    rt.openTerminalInfo()
    outcome.repaint = true
    return
  # PLAT-51: the omnibox's layout-setting commands (`:set …` without the
  # prompt, `omnibar_sources.layoutSettingCommands`).
  let setting = parseSettingCommandTarget(action)
  if setting.ok:
    rt.note(rt.applyLayoutSetting(setting.setting, setting.value))
    outcome.repaint = true
    return
  # PLAT-70: **View: Toggle Overflow Markers** flips the markers.
  let toggle = parseSettingToggleTarget(action)
  if toggle.ok and toggle.setting == lsOverflowMarkers:
    rt.note(rt.applyLayoutSetting(lsOverflowMarkers,
                                  rt.app.overflowMarkersOff))
    outcome.repaint = true
    return
  # PLAT-49 part B: the omnibar's event-log column commands
  # (`omnibar_sources.eventLogColumnCommands`), the `:column-*` verbs.
  let col = parseEventLogColumnCommand(action)
  if col.ok:
    let verb = case col.verb
               of "left": "column-left"
               of "right": "column-right"
               else: (if rt.app.eventLog.columns.isVisible(col.column):
                        "column-hide" else: "column-show")
    rt.note(rt.runColumnVerb(verb, eventLogColumnTitle(col.column)))
    outcome.repaint = true
    return
  # PLAT-70 Part B: the palette's operation entries (**Show Detail**,
  # **Widen Column**, **Narrow Column** — `omnibar_sources.tableCommands`).
  let operation = parseOperationCommand(action)
  if operation.ok:
    let (name, arg) = splitOperation(operation.operation)
    case name
    of "list.show-detail": rt.showDetail(outcome)
    of "table.resize-column": rt.resizeEventLogColumn(arg, outcome)
    of "view.scroll-left", "view.scroll-right":
      # PLAT-70 Part I: the focused output or table pane's view.
      discard rt.runViewOperation(name, outcome)
    of "find.cancel":
      # PLAT-70 Part C: **Find: Cancel and Return**.
      if rt.app.find.open: rt.cancelFind(outcome)
      else: rt.note("find: there is no find to cancel")
    else: rt.note(operation.operation & " is not available in the terminal")
    outcome.repaint = true
    return
  # Test-Results-Pane.md §9.3: **Tests: Open Recordings in …** — the
  # project's `replay-open-in`, written by the host.
  let openIn = parseReplayOpenCommandTarget(action)
  if openIn.ok:
    outcome.requestClick(PaneClickRequest(kind: pcTestsOpenIn,
                                          text: $openIn.policy))
    outcome.repaint = true
    return
  # PLAT-68: the palette's base-keymap commands
  # (`keymap_selection.baseKeymapCommandTargets`).
  let base = parseBaseKeymapCommand(action)
  if base.ok:
    rt.chooseKeymap($base.model)
    outcome.repaint = true
    return
  # THE SAME TABLE THE MENU WAS ENABLED FROM (`menuRouteOf`), read again for
  # now: a command the omnibar listed, or an item chosen after the state
  # moved, is refused with the reason the menu would show it disabled with.
  let route = rt.menuRouteOf(action)
  outcome.repaint = true
  if route.reason.len > 0:
    let at = rt.app.menu.pathOfAction(action)
    let label = if at.len > 0: rt.app.menu.itemAt(at).label else: action
    rt.note(label & ": " & route.reason)
    outcome.detail = rt.app.notification
    return
  case route.kind
  of mrKey:
    rt.performAction(route.key, outcome)
  of mrStop:
    rt.stopDebugging(outcome)
  of mrPoint:
    rt.runPointMenuItem(route.point, action, outcome)
  of mrPane:
    rt.showPane(route.pane, outcome)
  of mrPromptLine:
    rt.runPromptLine(route.line, outcome)
    if outcome.action != kaNone:
      discard rt.applyLocalAction(outcome.action, outcome)
    outcome.repaint = true
  of mrFindInFiles:
    rt.openFindInFiles(outcome)
  of mrOmnibar:
    rt.openOmnibar(route.line)
  of mrNewTab:
    rt.addTab(outcome)
  of mrWelcomeOption:
    rt.openWelcomeOption(route.option, route.newTab, outcome)
  of mrBuffer:
    rt.runBufferOp(route.buffer, outcome)
  of mrNone:
    # Unreachable: `menuRouteOf` gives `mrNone` a reason.
    rt.note(action & " is not available in the terminal")

proc acceptOmnibar(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `Enter` in the omnibar: act on the chosen entry. A tick and a symbol go
  ## to that point in time (`:goto`), a command runs its menu item, a file is
  ## selected in the Files pane (the debugger's source pane shows where the
  ## recording is; in Edit mode it is opened).
  ##
  ## A `:` QUERY IS A COMMAND LINE FIRST ("run a :command", the omnibar's own
  ## placeholder): under CUA and Emacs the palette is how the command line is
  ## reached (CodeTracer-TUI.md §4 — `Ctrl+Shift+P` / `F1`), so `:w`, `:q`,
  ## `:keymap` and `:break 12` run as typed. Only a line whose verb is no
  ## command takes the chosen palette entry, which is what fuzzy-picks one.
  let (mode, needle) = classifyOmnibarQuery(rt.app.omnibar.query)
  # PLAT-54: `/ai <text>` is the agent query — the desktop's: the omnibar
  # closes, Agent Activity is shown and the prompt goes to the agent.
  if mode == omAgent:
    rt.app.omnibar.close()
    if needle.len == 0:
      rt.showPane(paneAgentActivity, outcome)
      rt.note("type a prompt for the agent after /ai")
    else:
      rt.runAgentPrompt(needle, outcome)
    return
  # PLAT-54 (§2.2.7): `:attach …` / `:attach-recording …` — the prompt's
  # "add context" items: the chosen file, folder or recording is attached to
  # the agent's next prompt.
  if mode in {omAttach, omAttachRecording}:
    let (ok, entry) = rt.app.omnibar.accept()
    outcome.repaint = true
    if not ok:
      rt.note("nothing matches: type the path to attach")
      return
    rt.attachAgentContext(entry.target, outcome)
    return
  # PLAT-57: `:grep <text>` is Find in Files (§5.1): the omnibar closes and
  # the search runs into the pane; `:grep` alone keeps the field open.
  if mode == omProgram:
    if needle.len == 0:
      rt.openFindInFiles(outcome)
    else:
      rt.app.omnibar.close()
      rt.runFindInFiles(needle, outcome)
    return
  if mode == omCommand and
     rt.runCommandLine(":" & needle, outcome,
                       unknownFallsThrough = true):
    rt.app.omnibar.close()
    outcome.repaint = true
    return
  let (ok, entry) = rt.app.omnibar.accept()
  outcome.repaint = true
  if not ok:
    rt.note("nothing matches")
    return
  case entry.kind
  of omTick, omSymbol:
    if entry.target.len == 0:
      rt.note(entry.label & " has no tick to go to")
      return
    rt.runPromptLine(":goto " & entry.target, outcome)
  of omCommand:
    rt.runMenuAction(entry.target, outcome)
  of omFile:
    if rt.app.modes.product == pmEdit:
      rt.runPromptLine(":e " & entry.target, outcome)
    else:
      rt.app.fileTree.openPath = entry.target
      rt.note("file " & entry.target)
  of omRecording:
    # PLAT-49 part B: open it in a new session tab — the host's to do.
    if rt.app.recordingOpener.isNil:
      rt.note("this terminal cannot open another recording")
    else:
      let why = rt.app.recordingOpener(entry.target)
      if why.len > 0:
        rt.note(why)
  else:
    rt.note(entry.label)

proc sayRefusal(rt: TuiRuntime; chosen: MenuItem) =
  ## A DISABLED item was chosen: it does nothing (the menu stays open), and
  ## the status line says why — `"<label>: <reason>"` (EMT-D14: a disabled
  ## state carries a reason, and a choice that does nothing says so rather
  ## than nothing). Silent for a folder, which opened.
  let refusal = refusalOf(chosen)
  if refusal.len > 0:
    rt.note(refusal)

proc handleMenuKey(rt: TuiRuntime; token: string; nowMs: int64;
                   outcome: var RuntimeOutcome) =
  ## Every key while the menu is open belongs to it. The menu is the
  ## desktop's cascade (PLAT-49): `Up`/`Down` move within the open level,
  ## `Right` (or `Enter`) on a folder opens its submenu beside it, `Left`
  ## backs out of a submenu, `Esc` backs out and closes at the first level.
  let vm = rt.app.menu
  let name = rt.keyOf(token)
  outcome.repaint = true
  # The keymap's own menu keys keep their meaning inside it: another
  # mnemonic switches folder, `` Alt+` `` / `F10` close it.
  let res = rt.probeKey(name)
  if res.kind == erOperation and res.operation in MenuOperations:
    rt.runMenuOperation(res.operation, res.argument)
    return
  case name
  of "Esc": vm.escape()
  of "Enter":
    let chosen = vm.highlightedItem()
    let act = vm.activate()
    if act.ran:
      rt.runMenuAction(act.action, outcome)
    else:
      rt.sayRefusal(chosen)
  of "Up": vm.moveHighlight(-1)
  of "Down": vm.moveHighlight(1)
  of "Right": discard vm.enterFolder()
  of "Left": discard vm.leaveFolder()
  else:
    if isTextKey(name):
      vm.typeToSelect(keyCharacter(name), nowMs)
    else:
      outcome.repaint = false
  if not vm.isOpen:
    rt.note(if outcome.detail.len > 0: outcome.detail else: rt.app.notification)

proc cycleReveal(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `Ctrl+o`: reveal the first docked pane, then the next; after the last,
  ## hide. The strips' key.
  outcome.repaint = true
  if not rt.layoutBindingEnabled():
    rt.note("no pane is docked")
    return
  let b = rt.app.layoutBinding
  let docked = b.layout.docked
  if docked.len == 0:
    rt.note("no pane is docked")
    return
  var next = 0
  if b.interaction.kind == ikRevealingDock:
    for i, d in docked:
      if d.pane == b.interaction.pane:
        next = i + 1
  if next >= docked.len:
    discard b.cancelGesture()
    rt.note("hid the auto-hide pane")
    return
  rt.note(b.beginRevealDock(docked[next].pane).message)

proc applyAutoHideReply(rt: TuiRuntime; reply: AutoHideReply): bool =
  ## Carry out what the hover machine said: open the preview overlay (the
  ## binding's `ikRevealingDock`) or close it. True when the screen changed.
  let b = rt.app.layoutBinding
  case reply.cue
  of ahcNone: false
  of ahcPreview:
    if b.interaction.kind in {ikDraggingTab, ikResizingSplit}:
      return false
    b.beginRevealDock(reply.pane).status == lasPending
  of ahcDismiss:
    if b.interaction.kind == ikRevealingDock and
       b.interaction.pane == reply.pane:
      b.interaction = b.interaction.cancel()
      return true
    false

proc autoHidePointer(rt: TuiRuntime; event: MouseEvent; nowMs: int64;
                     outcome: var RuntimeOutcome) =
  ## PLAT-49 part B (finding 9): the pointer over the screen, for the
  ## auto-hide labels — the desktop's hover: after a moment over a label its
  ## pane is previewed as an overlay; leaving the label and the overlay closes
  ## the preview a moment later (`auto_hide_hover`).
  let b = rt.app.layoutBinding
  let geom = rt.layoutGeometry()
  var label = none(PaneKind)
  var open = false
  let strip = geom.stripIndexAt(event.row, event.col)
  if strip >= 0:
    let slot = geom.strips[strip].slotAt(event.row, event.col)
    if slot >= 0:
      let pane = geom.strips[strip].slots[slot].pane
      label = some(pane)
      let at = b.layout.dockedIndex(pane)
      open = at >= 0 and b.layout.docked[at].open
  let inOverlay = b.interaction.kind == ikRevealingDock and
                  geom.reveal.contains(event.row, event.col)
  if rt.applyAutoHideReply(rt.autoHide.pointerAt(label, inOverlay, open,
                                                 nowMs)):
    outcome.repaint = true

proc tickAutoHide*(rt: TuiRuntime; nowMs: int64): bool =
  ## The loop's clock for the auto-hide hover (a preview due, a dismissal
  ## due). True when the screen changed and must be painted.
  if not rt.layoutBindingEnabled():
    return false
  rt.applyAutoHideReply(rt.autoHide.tick(nowMs))

proc autoHideDueMs*(rt: TuiRuntime): int64 =
  ## When `tickAutoHide` next has something to do, -1 for never.
  rt.autoHide.nextDueMs

proc routeTopBarMouse(rt: TuiRuntime; event: MouseEvent;
                      outcome: var RuntimeOutcome): bool =
  ## PLAT-48: a mouse report the top bar, an open menu or an open omnibar
  ## takes. Answers whether it was taken (the layout binding never sees it).
  ##
  ##   * the pointer passing over the row (no button, `?1003`): the control
  ##     under it shows its tooltip and key on the status line;
  ##   * with the menu open, a press in a dropdown clicks the item (a folder
  ##     opens, an item runs); a press outside the menu closes it;
  ##   * with the omnibar open, a press on a result chooses it; outside, it
  ##     closes;
  ##   * a press on the row: `≡` / a folder title opens the menu, a control
  ##     runs its action, the omnibar opens, a tab is activated.
  let vm = rt.app.menu
  if event.kind == mekRelease:
    if rt.topBarPressConsumed:
      rt.topBarPressConsumed = false
      return true
    return false
  if event.kind == mekMotion and event.button == mbLeft:
    # A drag: the binding's. Decided BEFORE the frame is built (PLAT-51): a
    # live divider drag reports every motion, and a whole screen per report
    # just to answer "not mine" doubled the cost of each reflowed frame.
    return false
  let screen = shellScreenOf(rt)
  let lay = screen.topBarLayout
  if event.kind == mekMotion:
    if event.button == mbLeft:
      return false   # a drag: the binding's
    # Hover: the row's controls, and the open menu's items.
    var hovered = -1
    var hoveredTab = -1
    var hoveredStop = false
    var hoveredAdd = false
    if event.row == 0:
      let hit = lay.topBarHitAt(event.col)
      if hit.kind == thControl:
        hovered = hit.index
      elif hit.kind == thStop:
        hoveredStop = true
      elif hit.kind == thTab:
        hoveredTab = hit.index
      elif hit.kind == thTabAdd:
        hoveredAdd = true
    # PLAT-49 part B: a session tab's tooltip (its title; with an agent in
    # the session, the task, its state and progress) under it while hovered;
    # the "+"'s ("New tab") under it.
    if hoveredTab != rt.app.hoveredTab:
      rt.app.hoveredTab = hoveredTab
      outcome.repaint = true
    if hoveredAdd != rt.app.hoveredTabAdd:
      rt.app.hoveredTabAdd = hoveredAdd
      outcome.repaint = true
    if vm.isOpen:
      let (inside, path) = menuHitAt(screen.menuDropdowns, event.row,
                                     event.col)
      if inside and path.len > 0:
        let before = vm.revision
        vm.hoverPath(path)
        if vm.revision != before:
          outcome.repaint = true
    if hoveredStop != rt.app.hoveredStop:
      # M76: Stop's tooltip — the desktop's words and the chord that runs
      # `debugger.stop` here (CUA's `Shift+F5`), as a transport's is.
      rt.app.hoveredStop = hoveredStop
      if hoveredStop:
        rt.app.hoveredTooltip = tooltipText(StopControl.label,
          rt.router.chordFor("debugger.stop", rt.sessionFacts, rt.scopePath,
                             rt.navMode, ""))
        rt.note(rt.app.hoveredTooltip)
      elif hovered < 0:
        rt.app.hoveredTooltip = ""
      outcome.repaint = true
    if hovered != rt.app.hoveredControl:
      rt.app.hoveredControl = hovered
      # PLAT-49: the tooltip is the ViewModel's (`transportTooltip`: label
      # and key), drawn as a label under the control and said on the status
      # line.
      if hovered >= 0:
        let c = TransportControls[hovered]
        rt.app.hoveredTooltip = transportTooltip(
          c.id, rt.chordOf(transportKeyAction(c.id)))
        rt.note(rt.app.hoveredTooltip)
      elif not hoveredStop:
        rt.app.hoveredTooltip = ""
      outcome.repaint = true
    return true
  if event.kind != mekPress or event.button != mbLeft:
    return vm.isOpen or rt.app.omnibar.isOpen or event.row == 0
  # A left press.
  if vm.isOpen:
    let (inside, path) = menuHitAt(screen.menuDropdowns, event.row, event.col)
    if inside:
      rt.topBarPressConsumed = true
      outcome.repaint = true
      if path.len > 0:
        let chosen = vm.itemAt(path)
        let act = vm.clickPath(path)
        if act.ran:
          rt.runMenuAction(act.action, outcome)
        else:
          rt.sayRefusal(chosen)
      return true
    if event.row != 0:
      vm.close()
      rt.topBarPressConsumed = true
      outcome.repaint = true
      return true
  if rt.app.omnibar.isOpen:
    let (inside, index) = rt.omnibarHit(screen, event)
    if inside:
      rt.topBarPressConsumed = true
      outcome.repaint = true
      if index >= 0:
        rt.app.omnibar.select(index)
        rt.acceptOmnibar(outcome)
      return true
    if event.row != 0 or lay.topBarHitAt(event.col).kind != thOmnibar:
      rt.app.omnibar.close()
      if event.row != 0:
        rt.topBarPressConsumed = true
        outcome.repaint = true
        return true
  if event.row != 0:
    return false
  rt.topBarPressConsumed = true
  outcome.repaint = true
  let hit = lay.topBarHitAt(event.col, rt.app.shell.stripTabsOf(
    rt.app.welcomeTabs))
  case hit.kind
  of thMenuButton:
    if vm.isOpen:
      vm.close()
    else:
      rt.refreshMenuAvailability()
      vm.open(keyboard = false)
  of thControl:
    let c = TransportControls[hit.index]
    let ka = transportKeyAction(c.id)
    let enabled = hit.index < rt.app.controlsEnabledOf().len and
                  rt.app.controlsEnabledOf()[hit.index]
    if not enabled:
      rt.note(c.label & " is not available here")
    else:
      rt.performAction(ka, outcome)
  of thOmnibar:
    if not rt.app.omnibar.isOpen:
      rt.openOmnibar()
  of thStop:
    # M76: the toolbar's Stop — the same proc the menu item and the chord
    # run (`stopDebugging`); with no session it answers so.
    rt.app.hoveredStop = false
    if not rt.hasDebugSession:
      rt.note("Stop: " & NoDebugSessionReason)
    else:
      rt.stopDebugging(outcome)
  of thTab:
    # A click on a session tab switches to it; the switch is on the screen,
    # so nothing is echoed (PLAT-49 part B). PLAT-51: a welcome tab (or a
    # folder it became) is shown the same way.
    let at = rt.app.shell.stripTabAt(rt.app.welcomeTabs, hit.index)
    if at.isWelcome: rt.showWelcomeTab(at.welcomeIndex, outcome)
    else: rt.showSessionTab(at.sessionIndex, outcome)
  of thTabClose:
    # PLAT-49 part B: the tab's close control — the desktop's
    # `.session-tab-close` (Multi-Window-Tab-Management.md, rule 4: "Closing
    # a tab stops its backend and removes it"). The HOST closes a session it
    # opened — its engine with it (`sessionCloser`).
    let at = rt.app.shell.stripTabAt(rt.app.welcomeTabs, hit.index)
    if at.isWelcome:
      rt.closeWelcomeTabAt(at.welcomeIndex, outcome)
      rt.app.hoveredTab = -1
    else:
      let closed =
        if not rt.app.sessionCloser.isNil: rt.app.sessionCloser(at.sessionIndex)
        else: rt.app.shell.closeTab(at.sessionIndex)
      if closed:
        rt.app.hoveredTab = -1
  of thTabAdd:
    # PLAT-51 deliverable 8 (Multi-Window-Tab-Management.md rule 3): the
    # strip's "+" opens a new tab showing the WELCOME SCREEN, as the
    # desktop's does — the performer File › New Trace Tab shares.
    rt.app.hoveredTabAdd = false
    rt.addTab(outcome)
  of thTabMore:
    rt.app.tabScroll = max(0, rt.app.tabScroll + hit.index)
  of thNone:
    discard
  true

# ---------------------------------------------------------------------------
# PLAT-68 — KEYS THROUGH THE ROUTER (Base-Keymaps-And-Layer-Stack.md §6)
#
# The terminal's half of the front-end contract: its SCOPE PATH (read off the
# focus tree, `motions.scopePathOf`: a node per pane and per overlay), the
# ViewModels' FACTS for `contextKeysOf`, and the DISPATCH of what the shared
# router resolved. What a key MEANS is the router's; nothing below has a
# `case` over key names.
# ---------------------------------------------------------------------------

proc navMode(rt: TuiRuntime): NavigationMode =
  ## The navigation mode the derived layers read (§5.5): an open prompt's —
  ## the command line's or the search field's, decided by what is OPEN, the
  ## fact the scope path is built from too, so the two cannot disagree —
  ## else the modal machine's.
  if rt.prompt.open:
    return if rt.prompt.kind == pkCommand: nmCommand else: nmSearch
  case rt.modal.mode
  of mmNormal, mmCommand: nmNormal
  of mmSearch:
    # PLAT-70 Part C: a COMMITTED search (`/foo Enter`) is §4.2's SEARCH
    # mode, browsing — `n` / `N` walk the matches until `Escape` returns to
    # NORMAL (where `n` steps). Before Part C nothing committed a search, so
    # the phase was never reached with a pattern to walk.
    if rt.modal.phase == spBrowsing and rt.router.base.isModal: nmSearch
    else: nmNormal
  of mmInspect: nmInspect

proc syncCaretFrom(rt: TuiRuntime; buf: EditBuffer) =
  ## The read-only editor's displayed caret IS its document's (PLAT-51's
  ## caret, now the head of a real selection).
  if buf.isNil: return
  rt.app.caret = (buf.path, buf.caretLine, buf.caretColumn + 1)

proc debugBuffer*(rt: TuiRuntime): EditBuffer =
  ## THE DEBUG-MODE EDITOR'S DOCUMENT: the file the source pane shows, opened
  ## from the recording (`EditServices.readSource`) as an `EditingDocument`
  ## with PLAT-33's read-only filter — so selection, the caret, copy and find
  ## act on a real document, edits are refused, and `editor.toggle-read-only`
  ## (`Ctrl+E`, the desktop's) makes the same document writable. Nil when
  ## there is no recording file to open.
  if rt.app.modes.product == pmEdit or rt.app.source.path.len == 0:
    return nil
  let path = rt.app.source.path
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(rt.keymapModel, rt.keyDelivery)
  let at = rt.app.editSession.indexOfPath(path)
  if at >= 0:
    return rt.app.editSession.buffers[at]
  if rt.editServices.readSource.isNil:
    return nil
  let read = rt.editServices.readSource(path)
  if not read.ok:
    return nil
  let keep = rt.app.editSession.active
  discard rt.app.editSession.openFile(path, read.text,
                                      max(1, rt.sourcePaneRows()))
  result = rt.app.editSession.buffers[^1]
  if keep >= 0: rt.app.editSession.active = keep
  result.doc.setReadOnly(true)
  # The caret starts where the user placed it, else on the execution line —
  # where Monaco's cursor is when a replay stops.
  let line = if rt.app.caret.line > 0 and rt.app.caret.path == path:
               rt.app.caret.line
             else: max(1, rt.app.source.executionLine)
  let column = if rt.app.caret.line > 0 and rt.app.caret.path == path:
                 rt.app.caret.column
               else: 1
  result.moveCaretTo(line - 1, column - 1)

proc editorBuffer(rt: TuiRuntime): EditBuffer =
  ## The document behind the `editor` pane: Edit mode's active buffer, or
  ## Debug mode's document of the shown file.
  if rt.app.modes.product == pmEdit:
    if rt.app.editSession.isNil: nil else: rt.app.editSession.activeBuffer()
  else: rt.debugBuffer()

proc editorCaretLine(rt: TuiRuntime): int =
  ## The line the editor's caret is on — the line the desktop's Debug-menu
  ## point items act at (Monaco's cursor, `pointsOperationsSetup`) and
  ## `editor.toggle-tracepoint`'s line: the document's caret, else the last
  ## caret placed, else the execution line.
  let buf = rt.editorBuffer()
  result = if not buf.isNil: buf.caretLine
           elif rt.app.caret.line > 0: rt.app.caret.line
           else: rt.app.source.executionLine
  result = max(1, result)

proc stopDebugging(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## M76 (codetracer#843): *Stop* — the Debug menu's item and the keymap's
  ## `debugger.stop` (CUA's `Shift+F5`). Debugger-Controls.md § "Ending a
  ## session from inside it": the workspace returns to Edit mode, the replay
  ## backend for the session is terminated, and the tab survives as an edit
  ## tab. The mode switch is this layer's and is made here, through the same
  ## transition `Ctrl+F5` makes (Mode-Transitions.md §1: Debug → Edit "cannot
  ## fail"); ending the backend is the host's, so the outcome asks for it
  ## (`stopsSession`) and `tui_session.stop` performs it.
  ##
  ## With no session behind the runtime — `ct edit`, or a second Stop — there
  ## is nothing to end, and the status line says so: not an error, the
  ## desktop's `stopAlreadyInEditMode`.
  outcome.repaint = true
  if not rt.hasDebugSession:
    rt.note(NoDebugSessionReason)
    outcome.detail = rt.app.notification
    return
  rt.setProductMode(pmEdit, outcome)
  outcome.stopsSession = true
  rt.note("stopping the debugging session")
  outcome.detail = rt.app.notification

proc runPointMenuItem(rt: TuiRuntime; op: PointMenuOp; action: string;
                      outcome: var RuntimeOutcome) =
  ## M76 (codetracer#843): a Debug-menu breakpoint or tracepoint item. The
  ## ones that name one point act at the editor caret's line in the file the
  ## editor shows — the desktop's semantics. "Add a Tracepoint" opens this
  ## terminal's tracepoint editor there (the command line, `:tracepoint `
  ## typed, as K13's "Add tracepoint" does); every other item is the host's,
  ## over the session (`PaneClickRequest(kind: pcPointMenu)` →
  ## `session_driver.performPointMenuOp`). Reached only through
  ## `menuRouteOf`, whose `pointMenuReason` refused it first when there is no
  ## replay, the workspace is in Edit mode or the editor shows no file of it.
  outcome.repaint = true
  let path = rt.app.source.path
  let line = rt.editorCaretLine()
  if op == pmoAddTracepoint:
    rt.openTracepointEditorAt(path, line)
    return
  outcome.requestClick(PaneClickRequest(kind: pcPointMenu, path: path,
                                        line: line, text: action))

proc editorFocused(rt: TuiRuntime): bool =
  let (had, focused) = rt.focus.focusedPane()
  had and focused == paneEditor

proc sessionFacts*(rt: TuiRuntime): SessionFacts =
  ## The ViewModels' facts `contextKeysOf` derives the context keys from —
  ## each the owning model's own answer (`editorFactsOf` of the document, the
  ## overlays' `open`), never a key spelled here.
  let buf = if rt.editorFocused: rt.editorBuffer() else: nil
  let editor =
    if not buf.isNil: editorFactsOf(buf.doc.state, rt.tabMovesFocus)
    elif rt.app.modes.product == pmDebug: sourceViewFacts()
    else: EditorFacts()
  let drag = rt.layoutBindingEnabled() and
             rt.app.layoutBinding.interaction.kind in {ikDraggingTab,
                                                       ikResizingSplit,
                                                       ikRevealingDock}
  SessionFacts(product: rt.app.modes.product,
               replayLoaded: rt.app.traceName.len > 0,
               editor: editor,
               findWidgetVisible: rt.prompt.open and rt.prompt.kind != pkCommand,
               paletteVisible: rt.app.omnibar.isOpen,
               contextMenuVisible: rt.app.contextMenu.open,
               dragActive: drag)

proc editorElementId(rt: TuiRuntime): string =
  ## The editor element the `editor` pane holds — always one: in Debug mode
  ## it is the read-only source view even when no document could be opened
  ## for it (no recording yet, an unreadable file), so the read-only editor's
  ## keys (§4's letters, `:`) are its keys there too.
  let buf = rt.editorBuffer()
  let path = if not buf.isNil: buf.path else: rt.app.source.path
  "editor:" & path

proc scopePath*(rt: TuiRuntime): ScopePath =
  ## **THE TERMINAL'S SCOPE PATH**: window, session tab and focused pane
  ## from the focus tree, then what holds the focus inside — the editor and
  ## an open find widget's field, or a window-owned overlay (the palette,
  ## the command line, a context menu).
  rt.focus.dropInner()
  if rt.app.omnibar.isOpen:
    return rt.focus.scopePathOf([element(ekOverlay, "palette"),
                                 paletteFieldOf(rt.app.omnibar.query)],
                                atWindow = true)
  if rt.app.contextMenu.open:
    return rt.focus.scopePathOf([element(ekOverlay, "context-menu")],
                                atWindow = true)
  if rt.prompt.open and rt.prompt.kind == pkCommand:
    return rt.focus.scopePathOf([element(ekOverlay, "command-line"),
                                 element(ekInput, "prompt")],
                                atWindow = true)
  # PLAT-55: a docked Problems pane a press gave the keys (`dockKeys`) is the
  # scope the keys resolve in — a list pane, so the shared list table.
  if rt.hasDockKeys and rt.dockKeys == paneProblems and not rt.prompt.open and
     rt.paneAreaOf(paneProblems).width > 0:
    return rt.focus.scopePathOf([element(ekPane, $paneProblems)],
                                atWindow = true)
  var inner: seq[ScopeElement] = @[]
  var focusOwner = "window"
  if rt.editorFocused:
    let id = rt.editorElementId()
    if id.len > 0:
      inner.add element(ekEditor, id)
      focusOwner = id
  else:
    let (had, focused) = rt.focus.focusedPane()
    if had: focusOwner = $focused
  # §5.3 / §5.4: the find field is ITS OWNER'S — on the path while the focus
  # is on the element that opened it (the editor, or the pane `/` was typed
  # in), not on whatever pane the focus moved to while it stayed open. So
  # `Escape` in another pane is that pane's, and find stays open.
  let owner = rt.app.findOwner
  if rt.prompt.open and (owner.len == 0 or owner == "window" or
                         owner == focusOwner):
    inner.add element(ekOverlay, "find")
    inner.add element(ekInput, "find-query")
  rt.focus.scopePathOf(inner)

proc focusOwnerId(rt: TuiRuntime): string =
  ## The element a mode opened now is owned by: the editor when it has the
  ## focus, else the focused pane.
  if rt.editorFocused and rt.editorElementId().len > 0:
    return rt.editorElementId()
  let (had, focused) = rt.focus.focusedPane()
  if had: $focused else: "window"

proc syncOverlayLayers(rt: TuiRuntime) =
  ## THE PUSHED LAYERS MIRROR THE OVERLAYS (§5.3). An overlay is opened by an
  ## operation or by a click, and closed by one or by a click elsewhere; the
  ## layer its mode pushes follows it here, by token, so the stack is never
  ## a second, disagreeing record of which mode is open.
  proc want(rt: TuiRuntime; table, owner, label: string; open: bool) =
    let at = rt.router.stack.indexOfLayer(table, owner)
    if open and at < 0:
      discard rt.router.pushLayer(table, owner, label)
    elif not open and at >= 0:
      discard rt.router.popLayer(rt.router.stack.layers[at].token)
  # Popped newest-first, so a pop is always of the top.
  let promptCommand = rt.prompt.open and rt.prompt.kind == pkCommand
  let promptFind = rt.prompt.open and rt.prompt.kind != pkCommand
  if not rt.app.contextMenu.open:
    rt.want(ContextMenuTable, "window", "MENU", false)
  if not rt.app.omnibar.isOpen:
    rt.want(PaletteTable, "window", "PALETTE", false)
  if not promptCommand:
    rt.want(CommandLineTable, "window", "COMMAND", false)
  if not promptFind:
    for l in rt.router.stack.layers:
      if l.table == FindTable:
        rt.want(FindTable, l.owner, "FIND", false)
        break
  if promptFind and rt.router.stack.indexOfLayer(FindTable, rt.app.findOwner) < 0:
    rt.want(FindTable, rt.app.findOwner, "FIND", true)
  rt.want(CommandLineTable, "window", "COMMAND", promptCommand)
  rt.want(PaletteTable, "window", "PALETTE", rt.app.omnibar.isOpen)
  rt.want(ContextMenuTable, "window", "MENU", rt.app.contextMenu.open)

proc pendingPrefixDueMs*(rt: TuiRuntime): int64 =
  ## When the pending chord prefix times out under this base (Vim and
  ## Kakoune: 1000 ms, §3.7), or -1 — so the loop wakes for it.
  rt.router.pendingDueMs

proc tickPendingPrefix*(rt: TuiRuntime; nowMs: int64): bool =
  ## PLAT-68 (§3.7): a prefix whose timeout passed ENDS THEN, on the clock —
  ## its `g…` leaves the status line at the timeout, not at the next key.
  ## Answers whether the frame changed.
  if rt.router.expirePending(nowMs):
    rt.note("")
    return true
  false

proc showShortcutReference(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## PLAT-68 (Base-Keymaps-And-Layer-Stack.md §5.4, §5.6): THE SHORTCUT
  ## REFERENCE for where the focus is — every live binding, layer by layer in
  ## the order a key is asked of them (an open pushed layer first), each base
  ## row marked with the user row that shadows it — over the body, scrolled
  ## like any text there. The lines are `keymap_router.referenceLines` of
  ## `shortcutReference`, the one function every front-end shows.
  rt.syncOverlayLayers()
  let path = rt.scopePath
  let lines = referenceLines(rt.router.shortcutReference(
    rt.sessionFacts, path, rt.navMode))
  rt.showContent("Keyboard shortcuts — " & ($rt.router.base).toUpperAscii &
                 " at " & $path, lines.join("\n"), outcome = outcome)

proc unmountGoneOwners(rt: TuiRuntime) =
  ## §5.4: a layer's lifetime is bounded by its owner. After the panes are
  ## re-derived, a layer whose owner is no longer on screen is popped, and
  ## its mode told: the find widget closes.
  var present = @["window"]
  for r in rt.focus.regions: present.add $r.pane
  let editorId = rt.editorElementId()
  if editorId.len > 0 and paneEditor in rt.focus.focusOrder:
    present.add editorId
  var gone: seq[string] = @[]
  for l in rt.router.stack.layers:
    if l.owner notin present and l.owner notin gone: gone.add l.owner
  for owner in gone:
    for popped in rt.router.unmountOwner(owner):
      if popped.table == FindTable and rt.prompt.open and
         rt.prompt.kind != pkCommand:
        discard rt.prompt.cancel()
        discard rt.modal.applyModalEvent(meCancel)
      if popped.table == FindTable:
        # PLAT-70 Part C: the session ends with its owner; the pattern
        # stays the document's (`EditorState.search`).
        rt.app.find = FindVM()

proc routeKey*(rt: TuiRuntime; name: string; nowMs: int64): EditingResolution =
  ## One canonical key through the shared router, for THIS terminal's scope
  ## path and facts. The router keeps the pending prefix.
  rt.syncOverlayLayers()
  # The PATH FIRST: building it re-hangs the focus tree for what is open
  # now (a closed overlay's nodes come down), and the facts read that tree.
  let path = rt.scopePath
  rt.router.route(rt.sessionFacts, path, rt.navMode, name, nowMs)

proc probeKey*(rt: TuiRuntime; name: string): EditingResolution =
  ## What `name` WOULD resolve to now, with no effect on the router.
  rt.syncOverlayLayers()
  let path = rt.scopePath
  var probe = rt.router
  probe.route(rt.sessionFacts, path, rt.navMode, name, 0)

proc offerClipboardTo(rt: TuiRuntime; buf: EditBuffer) =
  ## Paste reads the INTERNAL clipboard (what this session copied, or what
  ## the terminal answered to an OSC 52 read): the core performs no I/O
  ## (Editing-Operations §5.2), so the host hands the text in first.
  if rt.app.pasteBuffer.len > 0:
    buf.doc.offerClipboard(rt.app.pasteBuffer)

proc holdPaste(rt: TuiRuntime; target: PasteTarget;
               res: EditingResolution): bool =
  ## Hold a paste while the terminal is asked for its clipboard (OSC 52,
  ## written with the next frame), unless it is known not to answer or a
  ## paste is already held. Answers whether it was held.
  if not rt.caps.clipboardRead or not rt.clipboardRead.asks or
     rt.clipboardRead.pending.active:
    return false
  rt.clipboardRead.pending = PendingPaste(active: true, target: target,
                                          resolution: res)
  rt.clipboardRead.requested = true
  true

proc runEditorOperation(rt: TuiRuntime; buf: EditBuffer;
                        res: EditingResolution; nowMs: int64;
                        outcome: var RuntimeOutcome; askTerminal = true) =
  ## A vocabulary operation (or a character) on the editor's document,
  ## with the session's bookkeeping: an edit is recorded, the pane follows
  ## the caret, a copy reaches the clipboard, a save is written. A paste
  ## first asks the terminal for its clipboard (`holdPaste`), and is run
  ## again by `completePaste` once the answer — or the silence — is in.
  if res.operation == "clipboard-paste":
    if askTerminal and not buf.doc.isReadOnly and
       rt.holdPaste(ptEditor, res):
      outcome.repaint = true
      return
    rt.offerClipboardTo(buf)
  let caretBefore = (buf.caretLine, buf.caretColumn)
  let applied = rt.app.editSession.applyResolvedIn(buf, res, nowMs)
  if applied.outcome == eoChanged:
    rt.app.editSession.recordEdit(buf.path)
    rt.app.editSession.refreshEditedPaths()
  if res.operation in ["clipboard-copy", "clipboard-cut"]:
    let copied = buf.doc.clipboardText
    if copied.len > 0:
      rt.copyToClipboard(copied, $copied.countLines & " line(s)")
  buf.followCaret(max(1, rt.sourcePaneRows()))
  if rt.app.modes.product == pmDebug:
    rt.syncCaretFrom(buf)
    # M73 (#840): and the window the Debug pane DRAWS follows the caret too.
    rt.followCaretInSource(buf, caretBefore, outcome)
  if "save" in applied.operations or "save-all" in applied.operations:
    rt.writeBuffers(res.spelling, all = "save-all" in applied.operations)
  elif "save-as" in applied.operations:
    rt.note("Save As takes a path: `:w` writes " & buf.path)
  if applied.outcome == eoIgnored and res.kind == erOperation and
     buf.doc.isReadOnly:
    rt.note("the editor is read-only — Ctrl+E makes it writable")
  outcome.repaint = true

proc pasteIntoField(rt: TuiRuntime; target: PasteTarget) =
  ## The internal clipboard into the open palette's or prompt's field, as
  ## typed text (a field is one line: the first line of a multi-line copy).
  let text = rt.app.pasteBuffer.splitLines()
  if text.len == 0 or text[0].len == 0:
    rt.note("the clipboard is empty")
    return
  case target
  of ptPalette:
    if rt.app.omnibar.isOpen: rt.app.omnibar.typeText(text[0])
  of ptPrompt:
    if rt.prompt.open: discard rt.prompt.insert(text[0])
  of ptEditor: discard

proc completePaste*(rt: TuiRuntime; answered: bool; text: string;
                    nowMs: int64): bool =
  ## The terminal's answer to the clipboard read (`answered`, its `text`),
  ## or the wait ran out: the answer becomes the internal clipboard, a
  ## terminal that stayed silent is not asked again, and the held paste is
  ## run. Answers whether there was one to run.
  rt.clipboardRead.open = false
  rt.clipboardRead.requested = false
  if answered:
    rt.clipboardRead.support = crsAnswers
    if text.len > 0: rt.app.pasteBuffer = text
  elif rt.clipboardRead.support == crsUnknown:
    rt.clipboardRead.support = crsSilent
  let held = rt.clipboardRead.pending
  rt.clipboardRead.pending = PendingPaste()
  if not held.active:
    return false
  case held.target
  of ptEditor:
    let buf = rt.editorBuffer()
    if not buf.isNil:
      var outcome = RuntimeOutcome()
      rt.runEditorOperation(buf, held.resolution, nowMs, outcome,
                            askTerminal = false)
  of ptPrompt, ptPalette:
    rt.pasteIntoField(held.target)
  true

proc focusedRowText(rt: TuiRuntime): (string, string) =
  ## What `list.copy` copies from the focused list: the row (or value) it
  ## has selected, and how to name it. Empty when the pane holds no
  ## selection.
  let (had, focused) = rt.focus.focusedPane()
  if not had: return ("", "")
  case focused
  of paneFileTree:
    let t = rt.app.fileTree
    if t.selected >= 0 and t.selected < t.files.len:
      return (t.files[t.selected], "the path")
  of paneState:
    # PLAT-70 Part B (Horizontal-Overflow.md §5.3): the variable's WHOLE
    # value, untruncated — what its detail and its tooltip show.
    let path = rt.app.variables.selected
    if path.len > 0:
      for r in rt.app.variables.paneRows():
        if r.kind == vrkVariable and r.node.path == path:
          return (rt.app.variables.fullValueOf(r.node),
                  "the value of " & r.node.name)
      return (path, "the variable")
  of paneEventLog:
    let (ok, ev) = rt.app.eventLog.rowAt(rt.app.eventLog.selected)
    if ok:
      return (ev.content, "event #" & $ev.index)
  of paneCalltrace:
    let (ok, r) = rt.app.callTrace.rowAt(rt.app.callTrace.currentTraceIndex)
    if ok:
      return (callRowText(r.callOf), "the call")
  else: discard
  ("", "")

# ---------------------------------------------------------------------------
# PLAT-70 Part C: THE FIND SESSION (Find-And-Incremental-Search.md §3, §4).
# The session is the shared `find_vm.FindVM` (`rt.app.find`), over the
# editor's document; its field is the status line's `/` / `?` prompt. This
# section only moves the pane's view where the session asks (`FindReveal`)
# and restores it on a cancel: what a match is, which one is current and what
# the count reads are the ViewModel's.
# ---------------------------------------------------------------------------

proc findPromptOpen(rt: TuiRuntime): bool =
  rt.prompt.open and rt.prompt.kind != pkCommand

proc findView(rt: TuiRuntime; buf: EditBuffer): tuple[top, leftCol: int] =
  ## Where the editor's view is now: the Debug-mode window's top while the
  ## read-only source is drawn, else the document's own; the horizontal
  ## view's left column.
  let top = if rt.sourceWindowShown and buf.path == rt.app.source.path:
              rt.app.source.viewportTop
            else: buf.viewportTop
  (max(1, top), buf.hview.leftCol)

proc setFindView(rt: TuiRuntime; buf: EditBuffer; top, leftCol: int;
                 outcome: var RuntimeOutcome) =
  ## Put the editor's view at `top` / `leftCol` EXACTLY (a cancel, §3.5):
  ## and record the caret as followed, so the next frame's caret-follow
  ## (§4.5: only a caret move moves the view) does not move it again.
  if rt.sourceWindowShown and buf.path == rt.app.source.path:
    rt.requestSourceScroll(SourceScroll(kind: sskTo, top: top), outcome)
  else:
    buf.viewportTop = top
  discard buf.hview.scrollBy(leftCol - buf.hview.leftCol)
  buf.follow = buf.doc.caretFollowOf

proc revealFind(rt: TuiRuntime; buf: EditBuffer; reveal: FindReveal;
                outcome: var RuntimeOutcome) =
  ## §3.3 step 3: the current match revealed — vertically centred when it
  ## was off-screen; horizontally by the caret-follow the next frame runs.
  rt.syncCaretFrom(buf)
  if reveal.line <= 0:
    return
  let rows = max(1, rt.sourcePaneRows())
  let (top, _) = rt.findView(buf)
  let want = revealTop(top, rows, reveal.line)
  if want == top:
    return
  if rt.sourceWindowShown and buf.path == rt.app.source.path:
    rt.requestSourceScroll(SourceScroll(kind: sskTo, top: want), outcome)
  else:
    buf.viewportTop = want

proc showFindStatus(rt: TuiRuntime; buf: EditBuffer) =
  ## §3.3 step 5 on the terminal: the count in the status line, beside the
  ## field (the prompt's message), or as a note once the field is closed.
  let text = rt.app.find.statusText(buf.doc)
  if rt.findPromptOpen:
    rt.prompt.message = text
  else:
    rt.note(if text.len > 0: "find: " & text else: "")

proc fillFieldWith(rt: TuiRuntime; text: string) =
  ## The prompt's text replaced by `text`, its caret at the end.
  discard rt.prompt.moveCursor(KeyEnd)
  while rt.prompt.buffer.len > 0:
    discard rt.prompt.backspace()
  if text.len > 0:
    discard rt.prompt.insert(text)

proc fillFindField(rt: TuiRuntime) =
  ## The prompt's text set to the session's field (a seed, a pulled word).
  rt.fillFieldWith(rt.app.find.field)

proc openFindSession(rt: TuiRuntime; backward: bool; symbol: bool;
                     outcome: var RuntimeOutcome) =
  ## `find.open` / `find.open-backward` / `find.open-symbol-at-caret`: the
  ## field opened in the status line and the session over the editor's
  ## document (§3.6: Vim's and Kakoune's `/` in a list pane searches the
  ## editor too). CUA seeds from the selection or the word (§4.1); Vim's,
  ## Kakoune's and Emacs's prompts open empty.
  outcome.repaint = true
  let buf = rt.editorBuffer()
  if buf.isNil:
    rt.note("find: there is no document in the editor to search")
    return
  discard rt.prompt.open(if backward: pkSearchBackward else: pkSearchForward)
  rt.app.findOwner = rt.focusOwnerId()
  let (top, leftCol) = rt.findView(buf)
  let base = rt.router.base
  let reveal =
    if symbol:
      rt.app.find.openSymbolAtCaret(buf.doc, base, rt.app.findOwner, top,
                                    leftCol)
    else:
      rt.app.find.openFind(buf.doc, base, rt.app.findOwner, backward,
                           (if base == bkCua: fsSelectionOrWord else: fsNone),
                           top, leftCol)
  rt.fillFindField()
  rt.revealFind(buf, reveal, outcome)
  rt.showFindStatus(buf)

proc closeFindField(rt: TuiRuntime; event: ModalEvent) =
  if rt.findPromptOpen:
    discard rt.prompt.cancel()
    discard rt.modal.applyModalEvent(event)

proc acceptFind(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `find.accept` / CUA's `find.close`: closed, the current match kept
  ## selected (FS-5); the pattern stays the editor's.
  outcome.repaint = true
  let buf = rt.editorBuffer()
  # A modal base's committed search is SEARCH mode, browsing (`n` walks);
  # the others go back to their one mode.
  rt.closeFindField(if rt.router.base.isModal: meCommit else: meCancel)
  if buf.isNil or not rt.app.find.open:
    return
  let wasField = rt.app.find.field
  let reveal = rt.app.find.accept(buf.doc)
  rt.revealFind(buf, reveal, outcome)
  rt.note(if wasField.len == 0 and buf.doc.state.search.pattern.len == 0:
            "find: " & NoPreviousPatternText
          else: "")

proc cancelFind(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `find.cancel`: closed, the selection and both scroll offsets put back
  ## exactly (FS-4).
  outcome.repaint = true
  let buf = rt.editorBuffer()
  rt.closeFindField(meCancel)
  if buf.isNil or not rt.app.find.open:
    return
  let (top, leftCol) = rt.app.find.cancel(buf.doc)
  rt.syncCaretFrom(buf)
  rt.setFindView(buf, top, leftCol, outcome)
  rt.note("")

proc walkFind(rt: TuiRuntime; next: bool; outcome: var RuntimeOutcome) =
  ## `find.next` / `find.previous` (§3.4): the open session's walk, or —
  ## closed — the last pattern from the caret (`F3`, `n`).
  outcome.repaint = true
  let buf = rt.editorBuffer()
  if buf.isNil:
    rt.note("find: there is no document in the editor to search")
    return
  if rt.app.find.open:
    let reveal = rt.app.find.step(buf.doc, next)
    rt.revealFind(buf, reveal, outcome)
    rt.showFindStatus(buf)
    return
  let walked = walkClosed(buf.doc, rt.router.base, next)
  rt.revealFind(buf, walked.reveal, outcome)
  if walked.message.len > 0:
    rt.note("find: " & walked.message)
  else:
    rt.note("find: `" & buf.doc.state.search.pattern & "` at line " &
            $buf.caretLine)

proc findSelectionMatch(rt: TuiRuntime; backward: bool; nowMs: int64;
                        outcome: var RuntimeOutcome) =
  ## CUA's `Ctrl+F3` / `Ctrl+Shift+F3` (§4.2): the word at the caret (or the
  ## selection) as the pattern, its next occurrence selected; the find
  ## widget stays closed.
  outcome.repaint = true
  let buf = rt.editorBuffer()
  if buf.isNil:
    rt.note("find: there is no document in the editor to search")
    return
  let ran = nextSelectionMatch(buf.doc, backward, nowMs)
  rt.revealFind(buf, ran.reveal, outcome)
  rt.note(if ran.message.len > 0: ran.message
          else: "find: `" & buf.doc.state.search.pattern & "` at line " &
                $buf.caretLine)

proc changeFind(rt: TuiRuntime; op: string; outcome: var RuntimeOutcome) =
  ## The open session's toggles and Emacs's `C-w`.
  outcome.repaint = true
  let buf = rt.editorBuffer()
  if buf.isNil or not rt.app.find.open:
    rt.note("find: open the find field first")
    return
  let reveal = case op
               of "find.toggle-case": rt.app.find.toggleCase(buf.doc)
               of "find.toggle-whole-word": rt.app.find.toggleWholeWord(buf.doc)
               else: rt.app.find.yankWord(buf.doc)
  if op == "find.yank-word":
    rt.fillFindField()
  rt.revealFind(buf, reveal, outcome)
  rt.showFindStatus(buf)

proc findFieldEdited(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## The field's text changed (typed, deleted, pasted): §3.3 — the store
  ## written, the matches recomputed, the first at or after the origin
  ## selected and revealed.
  let buf = rt.editorBuffer()
  if buf.isNil or not rt.app.find.open:
    return
  let reveal = rt.app.find.setQuery(buf.doc, rt.prompt.buffer,
                                    rt.prompt.cursor)
  rt.revealFind(buf, reveal, outcome)
  rt.showFindStatus(buf)

proc runPromptKey(rt: TuiRuntime; key: string;
                  outcome: var RuntimeOutcome)
  ## The command line's own editing step, for the `input.*` operations the
  ## router resolved on it; defined beside `handleToken`.

proc filesPaneArea(rt: TuiRuntime): CellArea =
  ## The rectangle the Files pane is painted into (its strip row first), or
  ## an empty one when it is not on the screen.
  let geometry = rt.paintedGeometry()
  for i, region in geometry.projection.regions:
    if region.pane == paneFileTree:
      return paneUnderStrip(geometry, i)
  CellArea()

proc runFilesKeyOperation(rt: TuiRuntime; operation: string;
                          outcome: var RuntimeOutcome): bool =
  ## K17 / K18 / K19 FROM THE KEYBOARD, while the Files pane has the focus:
  ## Up / Down (and the modal bases' `j` / `k`) move the selected row, Home /
  ## End go to the ends, Enter opens the file or opens or closes the folder,
  ## and `context-menu.open` (CUA's `Shift+F10` in Edit mode; the palette's
  ## "Show Context Menu" everywhere) opens the selected row's menu beside it.
  ## Answers whether `operation` was the pane's.
  let n = rt.app.fileTree.rowCount
  let sel = rt.app.fileTree.selected
  proc select(rt: TuiRuntime; i: int) =
    rt.app.fileTree.selected = i
    # Keep the selected row in view (the pane scrolls, M71).
    let body = max(1, rt.paneBodyRows(paneFileTree))
    var top = rt.app.fileTree.clampScrollTop(rt.app.fileTree.scrollTop, body)
    if i < top: top = i
    elif i >= top + body: top = i - body + 1
    rt.app.fileTree.scrollTop = top
  case operation
  of "list.focus-next", "list.focus-previous", "editor.scroll-line-down",
     "editor.scroll-line-up", "list.focus-first", "list.focus-last",
     "list.focus-page-down", "list.focus-page-up":
    outcome.repaint = true
    if n == 0:
      rt.note("the Files pane lists nothing")
      return true
    let page = max(1, rt.paneBodyRows(paneFileTree) - 1)
    let next =
      case operation
      of "list.focus-first": 0
      of "list.focus-last": n - 1
      of "list.focus-page-down": (if sel < 0: 0 else: sel + page)
      of "list.focus-page-up": (if sel < 0: 0 else: sel - page)
      of "list.focus-next", "editor.scroll-line-down":
        (if sel < 0: 0 else: sel + 1)
      else: (if sel < 0: n - 1 else: sel - 1)
    rt.select(clamp(next, 0, n - 1))
    true
  of "list.activate", "list.expand", "list.toggle-expand":
    if sel < 0 or sel >= n:
      rt.note("no row of the Files pane is selected")
      outcome.repaint = true
      return true
    rt.activateFilesRow(sel, outcome)
    true
  of "context-menu.open":
    if sel < 0 or sel >= n:
      rt.note("no row of the Files pane is selected")
      outcome.repaint = true
      return true
    let area = rt.filesPaneArea()
    let top = rt.app.fileTree.clampScrollTop(rt.app.fileTree.scrollTop,
                                             max(1, area.height - 1))
    let row = if area.width > 0: area.row + 1 + (sel - top) else: 1
    let col = if area.width > 0: area.col + 2 else: 0
    rt.openFilesMenu(sel, row, col, outcome)
    true
  else: false

proc runRequestsKeyOperation(rt: TuiRuntime; operation: string;
                             outcome: var RuntimeOutcome): bool =
  ## PLAT-58 FROM THE KEYBOARD, while the Requests pane has the focus
  ## (Request-Panel.md § N.4): the `list.*` moves select a request (kept in
  ## view), `list.activate` goes to its handler, `list.filter` opens the URL
  ## field, `list.copy` copies its URL, `list.clear-selection` clears it.
  ## Answers whether `operation` was the pane's.
  case operation
  of "list.focus-next", "list.focus-previous", "list.focus-first",
     "list.focus-last", "list.focus-page-down", "list.focus-page-up",
     "editor.scroll-line-down", "editor.scroll-line-up":
    let op = case operation
             of "editor.scroll-line-down": "list.focus-next"
             of "editor.scroll-line-up": "list.focus-previous"
             else: operation
    discard rt.actOnRequests(RequestsAct(kind: rakKey, operation: op,
      page: max(1, rt.paneBodyRows(paneRequests) - 4)), outcome)
    rt.keepRequestSelected(outcome)
    true
  of "list.activate":
    discard rt.actOnRequests(RequestsAct(kind: rakGoToHandler), outcome)
    true
  of "list.filter":
    rt.openRequestsField(outcome)
    true
  of "list.copy":
    discard rt.actOnRequests(RequestsAct(kind: rakCopy), outcome)
    true
  of "list.clear-selection":
    discard rt.actOnRequests(RequestsAct(kind: rakClearSelection), outcome)
    true
  else: false

proc runTestsKeyOperation(rt: TuiRuntime; operation: string;
                          outcome: var RuntimeOutcome): bool =
  ## PLAT-53 FROM THE KEYBOARD, while Test Results has the focus (§8.4): Up /
  ## Down (and the modal bases' `j` / `k`), Home / End and the pages move the
  ## selected row; Enter is its `⏵`. Answers whether `operation` was the
  ## pane's.
  let n = rt.app.tests.rows.len
  let sel = rt.app.tests.selected
  case operation
  of "list.focus-next", "list.focus-previous", "editor.scroll-line-down",
     "editor.scroll-line-up", "list.focus-first", "list.focus-last",
     "list.focus-page-down", "list.focus-page-up":
    outcome.repaint = true
    if n == 0:
      rt.note("the Test Results pane lists no test")
      return true
    let page = max(1, rt.paneBodyRows(paneTestResults) - 2)
    let next =
      case operation
      of "list.focus-first": 0
      of "list.focus-last": n - 1
      of "list.focus-page-down": (if sel < 0: 0 else: sel + page)
      of "list.focus-page-up": (if sel < 0: 0 else: sel - page)
      of "list.focus-next", "editor.scroll-line-down":
        (if sel < 0: 0 else: sel + 1)
      else: (if sel < 0: n - 1 else: sel - 1)
    rt.selectTestRow(clamp(next, 0, n - 1))
    true
  of "list.activate":
    if sel < 0 or sel >= n:
      rt.note("no test of the Test Results pane is selected")
      outcome.repaint = true
      return true
    let r = rt.app.tests.rows[sel]
    rt.pressTestsControl(r.open, PaneClickRequest(kind: pcTestsOpen,
                         text: r.testId), outcome)
    true
  else: false

proc runProblemsKeyOperation(rt: TuiRuntime; operation: string;
                             outcome: var RuntimeOutcome): bool =
  ## PLAT-55 FROM THE KEYBOARD, while Problems has the focus (Build-Output-
  ## Pane.md §3.3: "Arrow key navigation with Enter to jump"): Up / Down (and
  ## the modal bases' `j` / `k`), Home / End and the pages move the selected
  ## diagnostic; Enter opens it. Answers whether `operation` was the pane's.
  let order = rt.app.problems.listedIndices()
  let n = order.len
  let at = order.find(rt.app.problems.selected)
  case operation
  of "list.focus-next", "list.focus-previous", "editor.scroll-line-down",
     "editor.scroll-line-up", "list.focus-first", "list.focus-last",
     "list.focus-page-down", "list.focus-page-up":
    outcome.repaint = true
    if n == 0:
      rt.note("the Problems pane lists no problem")
      return true
    let page = max(1, rt.paneBodyRows(paneProblems) - 2)
    let next =
      case operation
      of "list.focus-first": 0
      of "list.focus-last": n - 1
      of "list.focus-page-down": (if at < 0: 0 else: at + page)
      of "list.focus-page-up": (if at < 0: 0 else: at - page)
      of "list.focus-next", "editor.scroll-line-down":
        (if at < 0: 0 else: at + 1)
      else: (if at < 0: n - 1 else: at - 1)
    rt.problemsCommand(pcmSelect, order[clamp(next, 0, n - 1)], outcome)
    true
  of "list.activate":
    if at < 0:
      rt.note("no problem of the Problems pane is selected")
      outcome.repaint = true
      return true
    rt.problemsCommand(pcmOpen, order[at], outcome)
    true
  else: false

proc runOperation(rt: TuiRuntime; res: EditingResolution; nowMs: int64;
                  outcome: var RuntimeOutcome) =
  ## **THE TERMINAL'S DISPATCH** of a resolved operation onto its ViewModels:
  ## the editing vocabulary onto the editor's document, the overlays' and
  ## inputs' operations onto the overlay that is open, everything the
  ## terminal's action vocabulary has onto `performAction`. An operation the
  ## terminal does not perform is INERT AND SAYS SO (Input-Routing IR-6).
  let op = if res.argument.len > 0: res.operation & "(" & res.argument & ")"
           else: res.operation
  outcome.repaint = true
  if '.' notin res.operation:
    let buf = rt.editorBuffer()
    if buf.isNil:
      rt.note("`" & res.operation & "` needs a document in the editor")
    else:
      rt.runEditorOperation(buf, res, nowMs, outcome)
    return
  # The overlays and inputs.
  if res.operation.startsWith("palette.") and rt.app.omnibar.isOpen:
    case res.operation
    of "palette.focus-previous": rt.app.omnibar.moveSelection(-1)
    of "palette.focus-next": rt.app.omnibar.moveSelection(1)
    of "palette.focus-page-up": rt.app.omnibar.moveSelection(-10)
    of "palette.focus-page-down": rt.app.omnibar.moveSelection(10)
    of "palette.accept": rt.acceptOmnibar(outcome)
    of "palette.close":
      rt.app.omnibar.close()
      rt.note("")
    else: discard
    return
  if res.operation.startsWith("input.") and rt.app.omnibar.isOpen:
    case res.operation
    of "input.move-left": rt.app.omnibar.moveCursor(-1)
    of "input.move-right": rt.app.omnibar.moveCursor(1)
    of "input.move-start": rt.app.omnibar.cursorHome()
    of "input.move-end": rt.app.omnibar.cursorEnd()
    of "input.delete-backward": rt.app.omnibar.backspace()
    of "input.delete-forward": rt.app.omnibar.deleteForward()
    of "input.toggle-overwrite": rt.app.omnibar.toggleOverwrite()
    of "input.copy", "input.cut":
      # A field holds no selection: the whole of it is what is copied.
      if rt.app.omnibar.query.len > 0:
        rt.copyToClipboard(rt.app.omnibar.query, "the query")
        if res.operation == "input.cut": rt.app.omnibar.setQuery("")
    of "input.paste":
      if not rt.holdPaste(ptPalette, res): rt.pasteIntoField(ptPalette)
    of "input.commit": rt.acceptOmnibar(outcome)
    of "input.cancel":
      rt.app.omnibar.close()
      rt.note("")
    else: rt.note("`" & op & "` is not available in the palette")
    return
  if res.operation.startsWith("context-menu.") and rt.app.contextMenu.open:
    case res.operation
    of "context-menu.focus-previous": rt.app.contextMenu.move(-1)
    of "context-menu.focus-next": rt.app.contextMenu.move(1)
    of "context-menu.focus-first": rt.app.contextMenu.moveToEnd(last = false)
    of "context-menu.focus-last": rt.app.contextMenu.moveToEnd(last = true)
    of "context-menu.accept":
      let chosen = rt.app.contextMenu.choose(-1)
      if chosen.chosen:
        rt.runContextAction(chosen.action, chosen.target, outcome)
    of "context-menu.close": rt.app.contextMenu.close()
    else: discard
    return
  # K17 / K18 / K19 from the keyboard, on the focused Files pane.
  if not rt.prompt.open:
    let (had, focused) = rt.focus.focusedPane()
    if had and focused == paneFileTree and
       rt.runFilesKeyOperation(res.operation, outcome):
      return
    if had and focused == paneTestResults and rt.app.tests.loaded and
       rt.runTestsKeyOperation(res.operation, outcome):
      return
    if had and focused == paneProblems and rt.app.problems.loaded and
       rt.runProblemsKeyOperation(res.operation, outcome):
      return
    if had and focused == paneRequests and rt.app.requests.loaded and
       rt.runRequestsKeyOperation(res.operation, outcome):
      return
  # PLAT-55: the docked Problems pane, pressed while shown, takes the list
  # keys too (`dockKeys`).
  if not rt.prompt.open and rt.hasDockKeys and rt.dockKeys == paneProblems and
     rt.app.problems.loaded and rt.paneAreaOf(paneProblems).width > 0 and
     rt.runProblemsKeyOperation(res.operation, outcome):
    return
  if res.operation.startsWith("input.") and rt.prompt.open:
    case res.operation
    of "input.copy", "input.cut":
      if rt.prompt.buffer.len > 0:
        rt.copyToClipboard(rt.prompt.buffer, "the command line")
        if res.operation == "input.cut":
          discard rt.prompt.moveCursor(KeyEnd)
          while rt.prompt.buffer.len > 0:
            discard rt.prompt.backspace()
      return
    of "input.paste":
      if not rt.holdPaste(ptPrompt, res): rt.pasteIntoField(ptPrompt)
      return
    else: discard
    let key = case res.operation
              of "input.commit": "Enter"
              of "input.cancel": "Esc"
              of "input.delete-backward": "Backspace"
              of "input.delete-forward": "Delete"
              of "input.move-left": "Left"
              of "input.move-right": "Right"
              of "input.move-start": "Home"
              of "input.move-end": "End"
              of "input.history-previous": "Up"
              of "input.history-next": "Down"
              of "input.complete": "Tab"
              else: ""
    if key.len == 0:
      rt.note("`" & op & "` is not available in the command line")
    else:
      rt.runPromptKey(key, outcome)
    return
  case res.operation
  # PLAT-70 Part C (Find-And-Incremental-Search.md §3, §4): the find
  # session's operations, onto the shared `FindVM`.
  of "find.next", "find.previous":
    rt.walkFind(res.operation == "find.next", outcome)
    return
  of "find.close", "find.accept":
    rt.acceptFind(outcome)
    return
  of "find.cancel":
    rt.cancelFind(outcome)
    return
  of "find.open", "find.open-backward", "find.open-symbol-at-caret":
    if res.operation == "find.open-symbol-at-caret":
      rt.openFindSession(backward = false, symbol = true, outcome)
      return
    # Through the local action, which the modal machine's transition and the
    # context menu's Find share (`applyLocalAction`).
  of "find.next-selection-match", "find.previous-selection-match":
    rt.findSelectionMatch(res.operation == "find.previous-selection-match",
                          nowMs, outcome)
    return
  of "find.toggle-case", "find.toggle-whole-word", "find.yank-word":
    rt.changeFind(res.operation, outcome)
    return
  of "editor.toggle-read-only":
    let buf = rt.editorBuffer()
    if buf.isNil:
      rt.note("there is no document in the editor to make writable")
    else:
      buf.doc.setReadOnly(not buf.doc.isReadOnly)
      rt.note(if buf.doc.isReadOnly: "the editor is read-only"
              else: "the editor is writable — Ctrl+E makes it read-only again")
    return
  of "editor.toggle-tracepoint":
    rt.openTracepointEditorAt(rt.app.source.path, rt.editorCaretLine())
    return
  of "debugger.stop":
    # M76: the keymap's Stop (CUA's `Shift+F5`) — the menu item's proc.
    rt.stopDebugging(outcome)
    return
  of "editor.toggle-tab-moves-focus":
    rt.tabMovesFocus = not rt.tabMovesFocus
    rt.note(if rt.tabMovesFocus: "Tab moves the focus (Ctrl+M again to indent)"
            else: "Tab indents")
    return
  of "list.show-detail":
    # PLAT-70 Part B (Horizontal-Overflow.md §5.3).
    rt.showDetail(outcome)
    return
  of "table.resize-column":
    # PLAT-70 Part B (§5.2): the Event Log is the table whose columns resize.
    rt.resizeEventLogColumn(res.argument, outcome)
    return
  of "list.copy":
    let (text, what) = rt.focusedRowText()
    if text.len == 0: rt.note("nothing is selected here to copy")
    else: rt.copyToClipboard(text, what)
    return
  of "list.focus-previous": rt.performAction(kaScrollLineUp, outcome); return
  of "list.focus-next": rt.performAction(kaScrollLineDown, outcome); return
  of "list.focus-page-up": rt.performAction(kaHalfPageUp, outcome); return
  of "list.focus-page-down": rt.performAction(kaHalfPageDown, outcome); return
  of "view.scroll-left", "view.scroll-right", "view.scroll-left-half",
     "view.scroll-right-half", "view.scroll-to-line-start":
    # PLAT-70 (Horizontal-Overflow.md §4.4): the output panes' view.
    discard rt.runViewOperation(res.operation, outcome)
    return
  of "help.keyboard-shortcuts":
    rt.showShortcutReference(outcome)
    return
  of "help.check-key-delivery":
    rt.keyCheck = startCheck()
    rt.note("keys check: press keys to see how they arrive; Esc ends the check")
    return
  of "menu.open", "menu.toggle", "menu.open-folder":
    rt.runMenuOperation(res.operation, res.argument)
    outcome.repaint = true
    return
  of "layout.reveal-next-docked":
    rt.cycleReveal(outcome)
    return
  of "search.find-in-files":
    # PLAT-57: `search.find-in-files(query?)` — with a pattern, the search;
    # without, the pane and its field (`Ctrl+Shift+F`).
    if res.argument.len > 0: rt.runFindInFiles(res.argument, outcome)
    else: rt.openFindInFiles(outcome)
    return
  of "problems.next", "problems.previous":
    # PLAT-55 (EMT-D22): `F8` / `Shift+F8` in Edit mode, `Ctrl+Alt+N` /
    # `Ctrl+Alt+P` — the desktop's `aGotoNextError` / `aGotoPreviousError`.
    rt.problemsCommand((if res.operation == "problems.next": pcmNext
                        else: pcmPrevious), -1, outcome)
    return
  of "search.next-result", "search.previous-result":
    # PLAT-57 (§5.3): `F4` / `Shift+F4`, `Alt+G N` / `Alt+G P`.
    rt.stepFindInFiles((if res.operation == "search.next-result": 1 else: -1),
                       outcome)
    return
  of "search.toggle-case", "search.toggle-whole-word", "search.toggle-regex":
    # PLAT-57: `Alt+C` / `Alt+W` / `Alt+R` in Find in Files' field (the
    # omnibox on `:grep`, `searchInputFocus`) — the toggle flips and a search
    # that ran runs again.
    rt.note(if rt.app.toggleSearchOption.isNil:
              "Find in Files needs a recording or a project to search"
            else: rt.app.toggleSearchOption(res.operation))
    return
  else: discard
  let palette = paletteQueryOf(res.operation)
  if palette.ok:
    outcome.action = kaCommandPalette
    rt.openOmnibar(palette.query)
    return
  let action = actionOfOperation(op)
  if action == kaNone:
    rt.note("`" & op & "` (" & operationLabelOf(res.operation) &
            ") is not available in the terminal")
    return
  rt.performAction(action, outcome)

proc runResolution(rt: TuiRuntime; res: EditingResolution; nowMs: int64;
                   outcome: var RuntimeOutcome) =
  ## What a resolution does on this terminal: an operation is dispatched, a
  ## character goes into the focused text element, a pending prefix and the
  ## reason for nothing are shown (§6.1 step 5).
  case res.kind
  of erPending:
    rt.note(rt.router.pendingLabel)
    outcome.repaint = true
  of erNothing:
    case res.reason
    of nrPrefixAbandoned:
      rt.note("")
      outcome.repaint = true
    of nrPrefixTimedOut:
      rt.note("")
      outcome.repaint = true
    of nrDisabled:
      # Mode-Transitions §8.1: inert in this product mode, and SAID — the
      # operation, the mode it needs, the chord that switches.
      rt.note(rt.router.inertNote(res, rt.sessionFacts, rt.scopePath,
                                  rt.navMode))
      outcome.repaint = true
    else: discard
  of erCharacter:
    outcome.repaint = true
    if rt.app.omnibar.isOpen:
      rt.app.omnibar.typeText(res.character)
    elif rt.prompt.open:
      rt.runPromptKey(res.character, outcome)
    else:
      let buf = rt.editorBuffer()
      if not buf.isNil and rt.editorFocused:
        rt.runEditorOperation(buf, res, nowMs, outcome)
  of erOperation:
    rt.runOperation(res, nowMs, outcome)

proc runPromptKey(rt: TuiRuntime; key: string;
                  outcome: var RuntimeOutcome) =
  ## One editing step of the open command line or find field: `key` is a
  ## canonical name of one of the keys `command_line.applyKey` reads
  ## (`Enter`, `Esc`, `Backspace`, the arrows, `Tab`) or a character. The
  ## router decided the key is this; the prompt's model performs it.
  let before = rt.prompt.buffer
  let cursorBefore = rt.prompt.cursor
  let findField = rt.findPromptOpen and rt.app.find.open
  if findField and rt.app.find.fieldSelected:
    # §3.2: a seed is selected in the field, so the first typed character
    # replaces it (and a delete removes it).
    if key in ["Backspace", "Delete", "\x7f", "\b"]:
      rt.fillFieldWith("")
      rt.findFieldEdited(outcome)
      outcome.repaint = true
      return
    if key.len > 0 and key notin ["Enter", "Esc", "\r", "\n", "\x1b",
                                  "Tab", "\t", "Left", "Right", "Up", "Down",
                                  "Home", "End"]:
      rt.fillFieldWith("")
    rt.app.find.fieldSelected = false
  let line = if key == "Enter": rt.prompt.buffer else: ""
  let cla = rt.prompt.applyKey(key, rt.promptCandidates())
  outcome.repaint = true
  if findField and rt.prompt.open and
     (rt.prompt.buffer != before or rt.prompt.cursor != cursorBefore):
    rt.findFieldEdited(outcome)
  case cla
  of claUnhandled:
    discard
  of claSubmitted:
    rt.runPromptLine(line, outcome)
    # A §4.3 COMMAND MAY RESOLVE TO A LOCAL ACTION, and `quit` does. Routed
    # through the SAME `applyLocalAction` the key path uses rather than
    # answered here, so `:quit` and `Ctrl+Q` cannot end a session
    # differently.
    if outcome.action != kaNone:
      discard rt.applyLocalAction(outcome.action, outcome)
    discard rt.modal.applyModalEvent(meCommit)
    # K19: a refused Files name keeps its field open, with the name typed.
    if rt.filesReprompt.len > 0:
      discard rt.openPrompt(pkCommand)
      discard rt.prompt.insert(rt.filesReprompt)
      rt.prompt.message = rt.app.notification
      rt.filesReprompt = ""
  of claCancelled:
    discard rt.modal.applyModalEvent(meCancel)
    # K19: Escape on a Files name field or Delete question cancels it.
    rt.note(rt.cancelFilesField())
    if findField:
      # The field's own `Esc`: each base's native exit (§3.5) — CUA's keeps
      # the match (OQ-F1), the others restore.
      let buf = rt.editorBuffer()
      if not buf.isNil:
        if rt.router.base == bkCua:
          rt.revealFind(buf, rt.app.find.accept(buf.doc), outcome)
        else:
          let (top, leftCol) = rt.app.find.cancel(buf.doc)
          rt.syncCaretFrom(buf)
          rt.setFindView(buf, top, leftCol, outcome)
  else:
    discard before

proc handleToken*(rt: TuiRuntime; token: string; nowMs: int64): RuntimeOutcome =
  ## ONE input token, end to end.
  ##
  ## The order is the §4.1/§4.2 order and each step is here because leaving it
  ## out changes an observable behaviour:
  ##
  ##   0. **A mouse report is not a key, and it goes to the layout binding.**
  ##      PLAT-6, and only when a binding is enabled — see `routeMouseReport`
  ##      for the precedence rule and `enableLayoutBinding` for the opt-in.
  ##      Ahead of the keys because a report is not one: `keyName` answers ""
  ##      for it, so taking it here removes nothing from the router or from an
  ##      open prompt.
  ##   1. **The terminal's own widgets, outside the keymap**: a gesture in
  ##      flight takes `Esc` (PLAT-47), a new tab's Welcome Screen its form
  ##      (PLAT-51), an event's content overlay and the program menu every key
  ##      while open (PLAT-48/49/50), the focused terminal output its few keys
  ##      (PLAT-52), and `:keys check` reports keys instead of running them.
  ##   2. **Every other key goes through the router** (PLAT-68, Base-Keymaps
  ##      §6.1): `routeKey` resolves the key's canonical name against this
  ##      terminal's scope path (`scopePath`, read off the `isonim-tui` focus
  ##      tree) and facts, and `runResolution` runs the answer. An open prompt
  ##      is a pushed layer of that same router, so its keys — `Esc`, `Enter`,
  ##      `Backspace`, the arrows, every printable character (CTUI-10: `Space`
  ##      included, or `:goto 4500` lost its spaces) — resolve to the prompt's
  ##      operations or to characters typed into it, and the router owns the
  ##      pending-chord timeout.
  result = RuntimeOutcome(repaint: false, quit: false, awaitsMove: false,
                          action: kaNone, detail: "")
  rt.lastToken = token
  rt.lastKey = rt.keyOf(token)
  # PLAT-51: ALT + A KEY arrives as ONE `ESC <byte>` token (the framer,
  # `host/terminal_driver.feed`). An Alt chord the router resolves to
  # something here (the desktop's `Alt+T`, Emacs's `M-f`, CUA's `Alt+Up`, a
  # user's row) is taken as the chord; any other is the key alone, which is
  # what the framer delivered before it framed Alt.
  if token.len == 2 and token[0] == '\x1b' and token[1] != '\x1b' and
     not rt.app.menu.isOpen and not rt.app.content.open and
     not rt.terminalInfo.open and
     rt.probeKey(rt.lastKey).kind == erNothing:
    return rt.handleToken(token[1 .. 1], nowMs)
  # PLAT-71: `:terminal-info` takes every token while it is open.
  if rt.terminalInfo.open:
    rt.handleTerminalInfoToken(token, result)
    return

  # PLAT-6's MOUSE HALF, ROUTED HERE AND ONLY WHEN A BINDING IS ENABLED. The
  # decoder is not even CALLED without one, so with the flag off this is one
  # predicate on a nil field and the token takes exactly the path it has always
  # taken: `keyName` answers "" for a mouse report and `keymap.resolve` reports
  # `krNone`, which is why a mouse has been inert in this front-end until now.
  # PLAT-48: THE TOP BAR, AN OPEN MENU AND AN OPEN OMNIBAR TAKE THE MOUSE
  # FIRST — a press on row 0 or in a dropdown is never a layout gesture —
  # and the pointer merely passing over the screen (`?1003` motion, no
  # button) is theirs or nobody's: it never repaints a frame for nothing.
  block:
    let (isMouse, event) = decodeMouse(token)
    # PLAT-51 (Native-Front-End-Parity.md §1, CodeTracer-TUI.md §4.4): SHIFT
    # IS THE TERMINAL'S. Most terminals bypass mouse reporting while Shift is
    # held, so their own selection and menu work; one that DELIVERS a
    # Shift-modified report finds the TUI standing down exactly as the
    # browser build's handlers do on Shift — no menu, no drag, no focus, no
    # repaint. (`--no-mouse` stays the whole-session escape.)
    #
    # THE ONE EXCEPTION IS THE WHEEL (Horizontal-Overflow.md §4.3): a
    # delivered Shift + vertical wheel scrolls sideways, as it does on the
    # desktop and GPUI — best effort, because many terminals keep that
    # gesture for their own scrollback and never report it.
    if isMouse and event.shift:
      if event.kind == mekPress and event.button in {mbWheelUp, mbWheelDown}:
        var sideways = event
        sideways.shift = false
        sideways.button = if event.button == mbWheelUp: mbWheelLeft
                          else: mbWheelRight
        if rt.routeHorizontalWheel(sideways, result):
          return
      rt.lastToken = token
      return
    if isMouse:
      # PLAT-49 part B: the pointer's passing is the auto-hide hover's too.
      if event.kind == mekMotion and event.button != mbLeft and
         rt.layoutBindingEnabled():
        rt.autoHidePointer(event, nowMs, result)
      # PLAT-70 Part B (Horizontal-Overflow.md §5.3): and a truncated table
      # cell's tooltip clock; a press hides a shown tooltip.
      if event.kind == mekMotion and event.button != mbLeft:
        rt.cellHoverPointer(event, nowMs, result)
      elif event.kind == mekPress and rt.dismissCellHover():
        result.repaint = true
      # Test-Results-Pane.md §9.6: a Test Results control's title on the
      # status line while the pointer is over it; a press ends the hover.
      if event.kind == mekMotion and event.button != mbLeft:
        rt.testsHoverPointer(event, result)
      elif event.kind == mekPress and rt.app.testsHover.len > 0:
        rt.app.testsHover = ""
        result.repaint = true
      # PLAT-50: an open right-click menu or content overlay first — it is
      # over everything, the top bar included.
      if rt.routeOverlayMouse(event, result):
        return
      # PLAT-52: a press held on a Terminal Output scrubber, likewise.
      if rt.routeTerminalDrag(event, result):
        return
      # PLAT-51: the open frame viewer's own scrubber (it is over the panes).
      if rt.routeFrameViewerMouse(event, result):
        return
      # PLAT-70 Part H: every pane's scrollbars — a held thumb or paging
      # press, a press on a bar, and the hover states and fade wakes of any
      # motion (Scrollbar-Scrubbers.md §7.4).
      if rt.layoutBindingEnabled() and
         rt.routeScrollbars(event, nowMs, result):
        return
      # PLAT-51: and on the Variables pane's column separator.
      if rt.routeVariablesResize(event, result):
        return
      # PLAT-70 Part B: and on an Event Log column separator.
      if rt.routeEventLogResize(event, result):
        return
      if rt.routeTextDrag(event, result):
        return
      if rt.routeTopBarMouse(event, result):
        return
      # PLAT-51: a new tab's Welcome Screen owns the body.
      if rt.routeWelcomeMouse(event, result):
        return
      if event.kind == mekMotion and event.button != mbLeft:
        return
    elif rt.dismissCellHover():
      # PLAT-70 Part B (Horizontal-Overflow.md §5.3): a key hides a shown
      # tooltip.
      result.repaint = true
  if rt.layoutBindingEnabled():
    let (isMouse, event) = decodeMouse(token)
    if isMouse:
      rt.routeMouseReport(event, result)
      return
    # PLAT-47: `Esc` CANCELS A GESTURE IN FLIGHT — a drag's drop tint and
    # ghost go, a held divider snaps back, and nothing is committed (`cancel`
    # takes no layout). Only when one is in flight: otherwise `Esc` is the
    # mode key it has always been.
    if rt.keyOf(token) == "Esc" and not rt.app.menu.isOpen and
        not rt.app.omnibar.isOpen and
        rt.app.layoutBinding.interaction.kind in {ikDraggingTab,
                                                  ikResizingSplit,
                                                  ikRevealingDock}:
      let cancelled = rt.app.layoutBinding.cancelGesture()
      rt.note(cancelled.message)
      result.detail = cancelled.message
      result.repaint = true
      return

  # PLAT-51: a new tab's Welcome Screen takes its keys (its form, the
  # arrows, Enter); everything else falls through.
  if rt.routeWelcomeKey(token, result):
    return

  # PLAT-50: an event's content overlay closes on Esc / q / Enter and
  # scrolls; the program menu (PLAT-48/49) owns every key while open, with
  # its type-to-select. Both are the terminal's own widgets over their
  # ViewModels (`ContentOverlay`, `MenuVM`), outside the keymap.
  if rt.app.content.open:
    case rt.keyOf(token)
    of "Escape", "Esc", "Enter", "q":
      rt.app.content = ContentOverlay()
      result.repaint = true
      return
    of "Up", "k": rt.app.content.scroll(-1); result.repaint = true; return
    of "Down", "j": rt.app.content.scroll(1); result.repaint = true; return
    of "PageUp": rt.app.content.scroll(-10); result.repaint = true; return
    of "PageDown", "Space":
      rt.app.content.scroll(10); result.repaint = true; return
    else: discard
  if rt.app.menu.isOpen:
    rt.handleMenuKey(token, nowMs, result)
    return

  # PLAT-52: THE TERMINAL OUTPUT'S OWN KEYS while it is focused — the
  # previous / next write and the view toggle, keys no global binding uses.
  if rt.terminalOutputOwnsToken(token):
    rt.routeTokenToTerminalOutput(token, result)
    return

  # PLAT-68: `:keys check` — every key is reported, none is run, until Esc.
  let name = rt.keyOf(token)
  if rt.keyCheck.active:
    if name == "Esc":
      var bound: seq[string] = @[]
      for b in rt.router.effective.bindings & rt.router.user.bindings:
        if b.chords.len == 1: bound.add b.chords[0]
      rt.note(rt.keyCheck.report(bound))
      rt.keyCheck = KeyCheck()
    elif name.len > 0:
      rt.keyCheck.note(name)
      let res = rt.probeKey(name)
      rt.note(arrivalLine(name, case res.kind
        of erOperation: (if res.argument.len > 0:
                           res.operation & "(" & res.argument & ")"
                         else: res.operation)
        of erCharacter: "types `" & res.character & "`"
        of erPending: "starts " & res.spelling & "…"
        of erNothing: ""))
    result.repaint = true
    return

  # EVERY OTHER KEY GOES THROUGH THE ROUTER (Base-Keymaps §6.1): the
  # canonical name, this terminal's scope path and facts, the shared
  # resolver; the answer is dispatched by `runResolution`.
  rt.runResolution(rt.routeKey(name, nowMs), nowMs, result)

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

proc scheduleHighlights*(rt: TuiRuntime) =
  ## Before a frame: bring the active buffer's held spans up to its current
  ## version, and ask for a parse of that version if none is current or in
  ## flight. Never waits — §11's third rule — so the frame draws whatever is
  ## known, and the answer arrives through `deliverHighlight`.
  if rt.app.modes.product != pmEdit or rt.app.editSession.isNil:
    return
  let buf = rt.app.editSession.activeBuffer()
  if buf.isNil:
    return
  # The buffer's own viewport height, not `sourcePaneRows`: that one builds
  # the whole shell model to find a rectangle, and this runs every frame.
  let rows = buf.doc.viewportRows + HighlightWindowSlack
  buf.highlights.refreshHeld(buf.doc, buf.viewportTop, rows)
  if buf.highlights.needsRequest(buf.doc):
    let req = highlightRequestFor(buf.doc, buf.serial)
    buf.highlights.noteRequested(req)
    if rt.editServices.requestHighlight.isNil:
      buf.highlights.installHighlight(buf.doc, computeHighlight(req),
                                      buf.viewportTop, rows)
    else:
      rt.editServices.requestHighlight(req)

proc deliverFileJob*(rt: TuiRuntime; res: FileJobResult): bool =
  ## A file answer arrived. Reconciled against the buffer it was made for
  ## (`file_io_producer.answerFor`); a read the buffer's edits made stale is
  ## discarded rather than installed over them, and a write marks the buffer
  ## saved as of the bytes that were written. `true` when a frame should be
  ## drawn.
  if rt.app.editSession.isNil:
    return false
  for buf in rt.app.editSession.buffers:
    if buf.path == res.job.path and buf.serial == res.job.bufferSerial:
      if buf.doc.version < res.job.version:
        return false
      let answer = buf.doc.answerFor(res, buf.fileReport)
      if answer.install:
        discard buf.doc.applyChangeSet(answer.change, 0)
      if answer.saved:
        # `loadedText` is "the bytes on disk" — the ones this answer is
        # about, never the buffer's current text, which may have moved while
        # the write ran. See `markSaved`.
        #
        # THE BUFFER STOPS BEING DIRTY AND GOES ON OUTRUNNING THE RECORDING,
        # and those are two predicates rather than one: `recordedText` is NOT
        # touched, because §2.1's staleness is about whether the bytes differ
        # from what was RECORDED, and a save makes a recording MORE stale.
        # Asserted in `test_edit_mode_source.nim` ("a saved edit is still an
        # edit the recording predates") and through the shipped binary in
        # `tests/real_terminal/test_real_edit_mode.nim`.
        buf.markSaved(answer.savedText)
      if answer.install:
        rt.app.editSession.refreshEditedPaths()
      rt.note(answer.note)
      return true
  false

proc runFileJob(rt: TuiRuntime; job: FileJob) =
  ## Submit to the host's worker, or — with none — do the job inline and
  ## deliver it, down the same path.
  if not rt.editServices.submitFileJob.isNil:
    rt.editServices.submitFileJob(job)
    return
  var res = FileJobResult(job: job)
  case job.kind
  of fjRead:
    if rt.editServices.readFile.isNil:
      res.message = ":e! has no reader in this session"
    else:
      let r = rt.editServices.readFile(job.path)
      res.ok = r.ok
      res.text = r.text
      res.message = r.message
  of fjWrite:
    if rt.editServices.writeFile.isNil:
      res.message = ":w has no writer in this session"
    else:
      let w = rt.editServices.writeFile(job.path, job.text)
      res.ok = w.ok
      res.message = w.message
  discard rt.deliverFileJob(res)

proc deliverHighlight*(rt: TuiRuntime; res: HighlightResult): bool =
  ## A parse arrived from the host's worker. Installed into the buffer it
  ## was asked for — reconciled against that buffer's timeline when the
  ## document moved while it was in flight — and `true` when a frame should
  ## be drawn. A result for a buffer that is gone, or for an earlier opening
  ## of the same file, is refused: it names a timeline this session no longer
  ## has.
  if rt.app.editSession.isNil:
    return false
  for buf in rt.app.editSession.buffers:
    if buf.path == res.request.path and buf.serial == res.request.bufferSerial:
      if buf.doc.version < res.request.version:
        return false
      buf.highlights.installHighlight(buf.doc, res, buf.viewportTop,
                                      buf.doc.viewportRows +
                                        HighlightWindowSlack)
      return true
  false

proc shellScreenOf*(rt: TuiRuntime): ShellScreen =
  ## The whole frame for this runtime, at its current size.
  ##
  ## The MODE reaches the status bar through `modal_state.statusMode`, and the
  ## LAYOUT through `motions.layoutFor` — so `z` really replaces the tree with a
  ## single-pane one rather than merely noting that it was pressed.
  rt.scheduleHighlights()
  # PLAT-70: the output panes' widths before the model is taken from them.
  rt.syncOutputViews()
  # PLAT-70 Part I: the table panes' views over this frame's fit.
  rt.syncTableViews()
  var model = rt.app.shellModel(rt.width, rt.height)
  model.status.mode = statusMode(rt.modal.mode)
  # PLAT-68: the indicator's text is the router's (a pending prefix, a
  # pushed mode, the modal mode under Vim / Kakoune, else the base).
  rt.syncOverlayLayers()
  model.status.label = rt.router.statusLabel(rt.scopePath, rt.navMode)
  # PLAT-68: the Debug-mode editor's document — painted as the Edit pane
  # once writable, and its selection over the recording's source while not;
  # PLAT-70: its horizontal view, the caret followed.
  rt.editorPaneModel(model, follow = true)
  if rt.maximize.active:
    # `z`. `motions.layoutFor` builds a one-pane `LayoutNode` of the SAME type
    # the profiles build, so `projectLayout`'s totality checks apply to the
    # maximized screen unchanged.
    model.layout = rt.maximize.layoutFor(model.profile)
  if rt.app.notification.len > 0:
    model.status.notification = rt.app.notification
  # Test-Results-Pane.md §9.6: the hovered control's title, over the
  # notification while the pointer is on the control (the notification is
  # kept, and is what the line says again when it leaves).
  if rt.app.testsHover.len > 0:
    model.status.notification = rt.app.testsHover
  # PLAT-46: the focused pane gets the focused border role.
  let (hasFocus, focused) = rt.focus.focusedPane()
  model.hasFocus = hasFocus
  model.focused = focused
  model.scrollbars = rt.scrollbarFrame()
  model.glyphs = glyphProfileOf(rt.caps)
  model.ambiguous = ambiguousPolicyOf(rt.caps)
  model.topBar.glyphs = model.glyphs
  result = shellScreen(model, rt.width, rt.height)
  rt.noteBarsPainted(result.bars)
  if rt.terminalInfo.open and result.styledRows.len == rt.height:
    # PLAT-71: `:terminal-info` over the body, top bar and status kept.
    var g = newStyledGrid(rt.width, rt.height)
    g.glyphs = model.glyphs
    g.ambiguous = model.ambiguous
    let area = terminalInfoArea(rt.width, rt.height)
    paintTerminalInfo(g, area, rt.terminalInfo, rt.terminalInfoBody())
    for r in area.row ..< area.row + area.height:
      result.styledRows[r] = g.rowSpans(r)
      result.rows[r] = g.rowText(r)
  if rt.prompt.open and result.rows.len > 0:
    # §3.3.6's prompt replaces the status row while it is open. Painted over the
    # finished screen rather than folded into `ShellModel`, because
    # `app/views/shell.nim` is CTUI-3's and knows nothing about a prompt; the
    # row is the one the status bar occupies, so nothing else moves.
    let last = result.rows.len - 1
    let text = promptText(rt.prompt, rt.width)
    result.rows[last] = text
    result.styledRows[last] = @[StyledSpan(text: text, style: PromptStyle)]

proc paneBodyRows*(rt: TuiRuntime; pane: PaneKind): int =
  ## How many rows `pane` has for its content on the CURRENT screen, under
  ## its tab strip (every pane has one since PLAT-49, and no title row
  ## below it): the rectangle `shell.paintPane` hands its painter, less the
  ## divider row a pane with a neighbour below gives up (`shell.paneFrame`).
  ## Zero when the pane is not on the screen.
  if rt.hostedRows.len > 0:
    return rt.hostedRows.getOrDefault(pane)
  let model = rt.app.shellModel(rt.width, rt.height)
  let layout = if rt.maximize.active: rt.maximize.layoutFor(model.profile)
               else: model.layout
  let body = bodyArea(rt.width, rt.height)
  let projection = projectLayout(layout, body)
  for region in projection.regions:
    if region.pane == pane:
      let frame = paneFrame(region.area, body)
      return max(0, frame.box.height - 1)
  0

proc paneBodyCols*(rt: TuiRuntime; pane: PaneKind): int =
  ## How many columns `pane` has for its content on the CURRENT screen: the
  ## rectangle `shell.paintPane` hands its painter, less a right divider
  ## (`shell.paneFrame`). Zero when the pane is not on the screen. With the
  ## pane server, the editor window's width (`hostedCols`).
  if rt.hostedRows.len > 0:
    return rt.hostedCols.getOrDefault(pane)
  let model = rt.app.shellModel(rt.width, rt.height)
  let layout = if rt.maximize.active: rt.maximize.layoutFor(model.profile)
               else: model.layout
  let body = bodyArea(rt.width, rt.height)
  let projection = projectLayout(layout, body)
  for region in projection.regions:
    if region.pane == pane:
      return max(0, paneFrame(region.area, body).box.width)
  0

proc editorBarShown*(rt: TuiRuntime): bool =
  ## PLAT-70: whether the editor's document is wider than its pane, so its
  ## horizontal bar takes the last row. The buffer is looked up, never
  ## opened: opening one asks `sourcePaneRows` for its height.
  if rt.app.editSession.isNil:
    return false
  let at = if rt.app.modes.product == pmEdit: rt.app.editSession.active
           else: rt.app.editSession.indexOfPath(rt.app.source.path)
  at >= 0 and at < rt.app.editSession.buffers.len and
    rt.app.editSession.buffers[at].hview.overflows

proc sourcePaneRows*(rt: TuiRuntime): int =
  ## How many rows the `editor` rectangle has on the CURRENT screen, minus its
  ## own title row.
  ##
  ## THE NUMBER `SourceVM.setViewport` HAS TO BE GIVEN, and it is a property of
  ## the projection rather than of the terminal.
  ## `SourceVM.followExecutionPointer` scrolls the window it was TOLD about, so
  ## a viewport taller than the pane's rectangle puts the execution line on a row
  ## the pane never draws. Measured on `calc` at 120x40 with the viewport taken
  ## from the terminal's height: the engine was on line 55 and the pane was
  ## showing lines 23-51, with no pointer anywhere on the screen.
  ##
  ## Zero when no profile gives the editor a rectangle, which the caller must
  ## clamp — `setViewport(0)` would hold no lines at all.
  if rt.hostedRows.len > 0:
    return rt.hostedRows.getOrDefault(paneEditor)
  let model = rt.app.shellModel(rt.width, rt.height)
  let layout = if rt.maximize.active: rt.maximize.layoutFor(model.profile)
               else: model.layout
  let projection = projectLayout(layout, bodyArea(rt.width, rt.height))
  # PLAT-70: the horizontal bar takes the pane's last row while the
  # document is wider than the pane (Horizontal-Overflow.md §4.7) — a window
  # one row taller would put the execution line under it.
  let bar = rt.editorBarShown()
  for region in projection.regions:
    if region.pane == paneEditor:
      let rows = max(0, region.area.height - 1)
      return if bar and rows >= 2: rows - 1 else: rows
  0

proc promptCursor*(rt: TuiRuntime): (bool, int, int) =
  ## Where the terminal should park its cursor: `(visible, row, col)`, 0-based.
  ##
  ## `(false, …)` when no prompt is open, in which case the driver leaves the
  ## cursor on the frame barrier — `docs/tui-testing.md` records why an app that
  ## moves it needs `waitForCursorAt` instead of `waitForCompleteFrame`, and a
  ## front-end with no prompt open should not pay that.
  if not rt.prompt.open:
    return (false, 0, 0)
  (true, max(0, rt.height - 1), cursorColumn(rt.prompt))

proc describe*(rt: TuiRuntime): string =
  ## One line for a diagnostic: mode, focus, size, negotiated capabilities.
  let (had, pane) = rt.focus.focusedPane()
  "mode=" & $rt.modal.mode &
    " focus=" & (if had: $pane else: "-") &
    " size=" & $rt.width & "x" & $rt.height &
    " " & describe(rt.caps)

proc retryOrigin*(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## PLAT-50: run `o` (`line` "") or `:origin X` again, now that the host
  ## put the chain it asked for into the Origin ViewModel — the walk then
  ## moves (`awaitsMove`), or says why it cannot.
  if line.len > 0:
    rt.runPromptLine(line, result)
  else:
    rt.performAction(kaValueOrigin, result)
  result.repaint = true

# ---------------------------------------------------------------------------
# HSF-E1: a pane hosted by an editor (Editor-Hosted-Front-Ends §E5, §E6)
# ---------------------------------------------------------------------------
#
# The pane server shows each pane in an editor window of the editor's size.
# A pane's content is the terminal's own painting of that pane MAXIMIZED at
# that size (`z`'s one-pane layout), less the header, the pane's tab strip and
# the status row — the window's own frame names the pane. So the editor gets
# exactly the rows the terminal would draw at that size, from the same
# painters, and a click is read against the same rectangle the rows were
# painted into.

type
  PaneOpArgs* = object
    ## The arguments of a pane operation (`runPaneOperation`): whichever of
    ## them the operation names.
    index*: int64
    tick*: uint64
    path*: string
    line*: int
    text*: string

  PaneHotspot* = object
    ## A cell range of a hosted pane's row that does something when clicked
    ## (§E6): `[startCol, endCol)` in cells, the pane operation and its
    ## arguments.
    startCol*, endCol*: int
    operation*: string
    args*: PaneOpArgs

const
  PaneOperations* = [
    ("calltrace.go-to-call", "Go to this call"),
    ("calltrace.toggle-call", "Expand or collapse this call"),
    ("event-log.jump", "Go to this event"),
    ("variables.toggle-expand", "Expand or collapse this value"),
    ("variables.value-history", "Show this value's history"),
    ("variables.value-origin", "Show this value's origin"),
    ("variables.load-more", "Load more members"),
    ("history.seek-to-tick", "Go to this moment"),
    ("file-tree.open", "Open this file"),
    ("file-tree.toggle-folder", "Expand or collapse this folder")]
    ## The operations a hosted pane's rows offer: what a click on the same
    ## cells of the terminal's pane does (`routeMouseReport`,
    ## `routePaneClick`), named so an editor can bind them.

proc hostedArea(height, width: int): CellArea =
  ## The rectangle a hosted pane's painter is handed: its heading row (row 0,
  ## which the terminal's tab strip covers and the editor does not show) and
  ## the `height` content rows under it.
  CellArea(col: 0, row: 0, width: width, height: height + 1)

proc hostedPaneRows*(rt: TuiRuntime; pane: PaneKind;
                     width, height: int): seq[StyledRow] =
  ## The `height` content rows of `pane` at `width` cells: the terminal's own
  ## screen with that pane maximized, without the header, the pane's strip
  ## and the status row.
  if width <= 0 or height <= 0:
    return @[]
  let savedMaximize = rt.maximize
  let savedWidth = rt.width
  let savedHeight = rt.height
  rt.maximize = MaximizeState(active: true, pane: pane)
  rt.width = width
  rt.height = height + ChromeRows + 1
  try:
    let screen = rt.shellScreenOf()
    for r in HeaderRows + 1 .. HeaderRows + height:
      result.add (if r < screen.styledRows.len: screen.styledRows[r] else: @[])
  finally:
    rt.maximize = savedMaximize
    rt.width = savedWidth
    rt.height = savedHeight

proc addRun(spots: var seq[PaneHotspot]; col: int; operation: string;
            args: PaneOpArgs) =
  ## Extend the hotspot ending at `col` when it is the same operation on the
  ## same target, else start one.
  if spots.len > 0 and spots[^1].endCol == col and
     spots[^1].operation == operation and spots[^1].args == args:
    spots[^1].endCol = col + 1
  else:
    spots.add PaneHotspot(startCol: col, endCol: col + 1,
                          operation: operation, args: args)

proc hostedHotspots*(rt: TuiRuntime; pane: PaneKind;
                     width, height: int): seq[seq[PaneHotspot]] =
  ## What a click on each cell of `pane`'s `height` content rows does, as
  ## hotspots per row — read off the same hit tests the terminal's mouse
  ## uses, against the rectangle `hostedPaneRows` painted.
  result = newSeq[seq[PaneHotspot]](max(0, height))
  if width <= 0 or height <= 0:
    return
  let area = hostedArea(height, width)
  case pane
  of paneFileTree:
    # K17 / K18: a row opens its file or opens or closes its folder, as a
    # press on the terminal's row does (`routePaneClick`).
    let tree = rt.app.fileTree
    if tree.entries.len == 0:
      return
    var g = newStyledGrid(area.col + area.width, area.row + area.height)
    let screen = paintFileTree(g, area, tree)
    for r in 0 ..< height:
      let i = screen.entryIndexAt(r + 1)
      if i < 0 or i >= tree.entries.len:
        continue
      let e = tree.entries[i]
      result[r].add PaneHotspot(startCol: 0, endCol: width,
        operation: (if e.isFolder: "file-tree.toggle-folder" else: "file-tree.open"),
        args: PaneOpArgs(path: e.path))
  of paneCalltrace:
    if rt.app.callTrace.isEmpty:
      return
    for r in 0 ..< height:
      for c in 0 ..< width:
        let hit = rt.app.callTrace.callTraceHitAt(area, r + 1, c)
        case hit.kind
        of cthRow:
          result[r].addRun(c, "calltrace.go-to-call", PaneOpArgs(index: hit.index))
        of cthToggle:
          result[r].addRun(c, "calltrace.toggle-call", PaneOpArgs(index: hit.index))
        else: discard
  of paneEventLog:
    if not rt.app.eventLog.hasContent:
      return
    for r in 0 ..< height:
      let (ok, row, _) = eventRowAt(rt.app.eventLog, area, r + 1)
      if ok:
        let ev = row.event
        result[r].add PaneHotspot(startCol: 0, endCol: width,
          operation: "event-log.jump",
          args: PaneOpArgs(index: int64(ev.index), tick: ev.tick,
                           path: ev.file, line: ev.line, text: ev.content))
  of paneState:
    if rt.app.variables.isEmpty:
      return
    var g = newStyledGrid(width, height + 1)
    let screen = paintVariables(g, area, rt.app.variables)
    for r in 0 ..< height:
      let (anyRow, prow) = screen.rowAtScreenRow(r + 1)
      if not anyRow:
        continue
      case prow.kind
      of vrkHistory:
        result[r].add PaneHotspot(startCol: 0, endCol: width,
          operation: "history.seek-to-tick", args: PaneOpArgs(tick: prow.ticks))
      of vrkMore:
        result[r].add PaneHotspot(startCol: 0, endCol: width,
          operation: "variables.load-more", args: PaneOpArgs(path: prow.node.path))
      of vrkVariable:
        for c in 0 ..< width:
          case screen.controlAt(rt.app.variables, r + 1, c)
          of vcHistory:
            result[r].addRun(c, "variables.value-history",
                             PaneOpArgs(path: prow.node.path))
          of vcOrigin:
            result[r].addRun(c, "variables.value-origin",
                             PaneOpArgs(path: prow.node.path))
          of vcNone:
            if prow.expandable:
              result[r].addRun(c, "variables.toggle-expand",
                               PaneOpArgs(path: prow.node.path))
          else: discard
      else: discard
  else:
    discard

proc runPaneOperation*(rt: TuiRuntime; operation: string; args: PaneOpArgs;
                       outcome: var RuntimeOutcome): bool =
  ## A hosted pane's operation (`PaneOperations`), as the outcome the same
  ## click on the terminal's pane produces; the host applies it as it applies
  ## a click's (`tui_session.applyOutcome`). False for an unknown operation.
  outcome.repaint = true
  case operation
  of "calltrace.go-to-call":
    outcome.jumpsToCall = true
    outcome.callIndex = args.index
  of "calltrace.toggle-call":
    outcome.togglesCall = true
    outcome.callIndex = args.index
  of "event-log.jump":
    outcome.requestClick(PaneClickRequest(kind: pcEventJump, index: args.index,
                                          tick: args.tick, path: args.path,
                                          line: args.line, text: args.text))
  of "variables.toggle-expand":
    discard rt.app.variables.toggleNode(args.path)
  of "variables.value-history":
    outcome.requestClick(PaneClickRequest(kind: pcValueHistory, path: args.path))
  of "variables.value-origin":
    outcome.requestClick(PaneClickRequest(kind: pcValueOrigin, path: args.path))
  of "variables.load-more":
    discard rt.app.variables.expandMore(args.path)
  of "history.seek-to-tick":
    outcome.requestClick(PaneClickRequest(kind: pcSeek, tick: args.tick))
  of "file-tree.open":
    outcome.requestClick(PaneClickRequest(kind: pcOpenFile, path: args.path))
  of "file-tree.toggle-folder":
    outcome.requestClick(PaneClickRequest(kind: pcToggleFolder, path: args.path))
  else:
    outcome.repaint = false
    return false
  true

proc runNamedOperation*(rt: TuiRuntime; operation, argument: string;
                        nowMs: int64): RuntimeOutcome =
  ## A catalogued operation (`operation_catalogue`) by name — what a key bound
  ## to it runs, through the same dispatch (`runOperation`).
  result = RuntimeOutcome(action: kaNone)
  rt.runOperation(EditingResolution(kind: erOperation, operation: operation,
                                    argument: argument), nowMs, result)

proc focusHostedPane*(rt: TuiRuntime; pane: PaneKind): bool =
  ## Give `pane` the keyboard focus, as a click in it does: the operations
  ## that act on the focused pane then act on it.
  rt.rebuildFocus()
  rt.focus.focusPaneKind(pane)

proc paneShortcutReference*(rt: TuiRuntime; pane: PaneKind): seq[ReferenceEntry] =
  ## Every binding live while `pane` has the focus (the router's shortcut
  ## reference at that scope path): the bindings an editor installs in the
  ## pane's buffer (§E6). The focus is put back afterwards.
  let saved = rt.focus
  discard rt.focusHostedPane(pane)
  result = rt.router.shortcutReference(rt.sessionFacts, rt.scopePath, rt.navMode)
  rt.focus = saved
