## Storybook-compatible exports for CodeTracer IsoNim surfaces.
##
## Compiled with:
##   nim js -o:storybook/dist/components.js src/frontend/storybook_components.nim

when not defined(js):
  {.error: "storybook_components.nim requires the JS backend (nim js)".}

import std/[options, tables]

import isonim/rxcore
import isonim/viewmodel
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer

import viewmodel/backend/mock_backend
import viewmodel/store/[replay_data_store, types]
import viewmodel/viewmodels/[
  agent_activity_deepreview_vm,
  agent_activity_vm,
  agent_workspace_vm,
  build_vm,
  calltrace_editor_vm,
  calltrace_vm,
  command_palette_vm,
  debug_controls_vm,
  deepreview_vm,
  editor_vm,
  errors_vm,
  event_log_vm,
  filesystem_vm,
  flow_vm,
  low_level_code_vm,
  no_source_vm,
  point_list_vm,
  repl_vm,
  request_panel_vm,
  scratchpad_vm,
  search_results_vm,
  search_vm,
  shell_vm,
  state_vm,
  step_list_vm,
  terminal_output_vm,
  timeline_vm,
  trace_log_vm,
  vcs_vm,
  welcome_screen_vm,
]
import viewmodel/views/[
  isonim_agent_activity_deepreview_view,
  isonim_agent_activity_view,
  isonim_agent_workspace_view,
  isonim_auto_hide_bottom_tabs_view,
  isonim_auto_hide_collapsed_icons_view,
  isonim_auto_hide_overlay_tabs_view,
  isonim_auto_hide_side_strip_view,
  isonim_build_view,
  isonim_calltrace_editor_view,
  isonim_calltrace_view,
  isonim_command_palette_view,
  isonim_debug_controls_view,
  isonim_debug_shell_view,
  isonim_deepreview_view,
  isonim_editor_view,
  isonim_errors_view,
  isonim_event_log_view,
  isonim_filesystem_view,
  isonim_flow_view,
  isonim_low_level_code_view,
  isonim_menu_shell_view,
  isonim_no_source_view,
  isonim_point_list_view,
  isonim_repl_view,
  isonim_request_panel_view,
  isonim_scratchpad_view,
  isonim_search_results_view,
  isonim_search_view,
  isonim_session_tabs_view,
  isonim_shell_view,
  isonim_state_view,
  isonim_status_view,
  isonim_step_list_view,
  isonim_terminal_output_view,
  isonim_timeline_view,
  isonim_trace_log_view,
  isonim_vcs_view,
  isonim_welcome_screen_view,
]
import viewmodel/app/isonim_app_shell

type
  DisposeProc = proc()
  MountBody = proc(store: ReplayDataStore): DisposeProc

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  result = createReplayDataStore(mock.toBackendService)
  result.session.val = SessionState(connectionStatus: csConnected)
  result.timeline.val = TimelineState(
    minRRTicks: 0'u64,
    maxRRTicks: 400'u64,
    currentRRTicks: 180'u64,
  )
  result.debugger.val = DebuggerState(
    location: Location(file: "examples/noir/noir-space-ship/src/main.nr",
                       line: 42, column: 3, callstackDepth: 1),
    rrTicks: 180'u64,
    status: dsIdle,
    threadId: 1'u32,
  )
  result.locals.codeStateLine.val = "42 | let remaining_shield = shield - damage;"
  result.locals.locals.val = @[
    Variable(name: "remaining_shield", value: "71", typeName: "u32"),
    Variable(name: "damage", value: "29", typeName: "u32"),
    Variable(
      name: "ship",
      value: "{ hull: 100, shield: 71 }",
      typeName: "ShipState",
      hasChildren: true,
      children: @[
        Variable(name: "hull", value: "100", typeName: "u32"),
        Variable(name: "shield", value: "71", typeName: "u32"),
      ],
    ),
  ]
  result.locals.globals.val = @[
    Variable(name: "MAX_SHIELD", value: "100", typeName: "u32"),
  ]
  result.calltrace.lines.val = @[
    CallLine(index: 0, name: "main", depth: 0, rrTicks: 100'u64,
             location: Location(file: "src/main.nr", line: 8, column: 1),
             hasChildren: true, isExpanded: true, callKey: "main:0"),
    CallLine(index: 1, name: "calculate_damage", depth: 1, rrTicks: 180'u64,
             location: Location(file: "src/combat.nr", line: 42, column: 3,
                                callstackDepth: 1),
             hasChildren: false, isExpanded: false, callKey: "damage:1"),
    CallLine(index: 2, name: "apply_shield_regeneration", depth: 1,
             rrTicks: 240'u64,
             location: Location(file: "src/combat.nr", line: 64, column: 3,
                                callstackDepth: 1),
             hasChildren: false, isExpanded: false, callKey: "regen:1"),
  ]
  var args = initTable[string, seq[CallArg]]()
  args["damage:1"] = @[
    CallArg(name: "ship", text: "ShipState(hull: 100, shield: 71)"),
    CallArg(name: "weapon", text: "laser"),
  ]
  result.calltrace.args.val = args
  result.calltrace.totalCallsCount.val = 3'u64
  result.calltrace.finished.val = true

proc mountWithStore(container: isonim_dom.Element; body: MountBody): DisposeProc =
  var rootDisposer: proc()
  var store: ReplayDataStore
  var vmDisposer: DisposeProc

  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    store = makeStore()
    vmDisposer = body(store)

  return proc() =
    if vmDisposer != nil:
      vmDisposer()
    if store != nil:
      store.dispose()
    if rootDisposer != nil:
      rootDisposer()
    container.innerHTML = ""

proc storyLines(): seq[TerminalLine] =
  @[
    TerminalLine(lineIndex: 0, fragments: @[
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-green-fg\">CodeTracer</span> replay started",
        eventIndex: 10,
        rrTicks: 100'u64,
      ),
    ]),
    TerminalLine(lineIndex: 1, fragments: @[
      TerminalEventFragment(htmlText: "running ", eventIndex: 11, rrTicks: 140'u64),
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-cyan-fg\">noir-space-ship</span>",
        eventIndex: 12,
        rrTicks: 180'u64,
      ),
    ]),
    TerminalLine(lineIndex: 2, fragments: @[
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-yellow-fg\">warning:</span> flow loop still rendering",
        eventIndex: 13,
        rrTicks: 220'u64,
      ),
    ]),
  ]

proc storyProblems(): seq[BuildProblemLine] =
  @[
    BuildProblemLine(severity: blsError, path: "src/combat.nr", line: 42,
                     col: 7, message: "expected field `shield` to be u32"),
    BuildProblemLine(severity: blsWarning, path: "src/main.nr", line: 18,
                     col: 3, message: "unused variable `debug_mode`"),
  ]

proc storyFilesystem(): FilesystemEntryNode =
  FilesystemEntryNode(
    id: "root",
    text: "noir-space-ship",
    path: "/workspace/noir-space-ship",
    isFolder: true,
    isExpanded: true,
    children: @[
      FilesystemEntryNode(id: "src", text: "src", path: "/workspace/noir-space-ship/src",
                          isFolder: true, isExpanded: true, children: @[
        FilesystemEntryNode(id: "main", text: "main.nr",
                            path: "/workspace/noir-space-ship/src/main.nr",
                            icon: "devicon-nim-plain", diffClass: fdcChanged),
        FilesystemEntryNode(id: "combat", text: "combat.nr",
                            path: "/workspace/noir-space-ship/src/combat.nr",
                            icon: "devicon-nim-plain", diffClass: fdcAdded),
      ]),
      FilesystemEntryNode(id: "readme", text: "README.md",
                          path: "/workspace/noir-space-ship/README.md"),
    ],
  )

proc applyBuild(vm: BuildVM; fixture: string) =
  vm.setCommand("nargo test")
  vm.setRunning(fixture == "loading")
  vm.appendLine(BuildOutputLine(htmlText: "$ nargo test --workspace noir-space-ship",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(htmlText: "Compiling noir-space-ship v0.2.0",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(htmlText: "Checking src/main.nr",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(
    htmlText: "<span class=\"ansi-bright-red-fg\">src/combat.nr:42:7 error:</span> expected u32",
    isStdout: false,
    severity: blsError,
    locationPath: "src/combat.nr",
    locationLine: 42,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "  let remaining_shield = shield - damage",
    isStdout: false,
    severity: blsError,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "      ^^^^^^^^^^^^^^^ expected field `shield` to be u32",
    isStdout: false,
    severity: blsError,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "<span class=\"ansi-bright-yellow-fg\">src/main.nr:18:3 warning:</span> unused variable `debug_mode`",
    isStdout: false,
    severity: blsWarning,
    locationPath: "src/main.nr",
    locationLine: 18,
  ))
  for problem in storyProblems():
    vm.appendProblem(problem)
  vm.setCode(if fixture == "success": 0 else: 1)

proc applyErrors(vm: ErrorsVM) =
  vm.setProblems(storyProblems())

proc applyScratchpad(vm: ScratchpadVM) =
  vm.addValue(ScratchpadValueEntry(expression: "remaining_shield",
                                   valueText: "71", isLiteral: true))
  vm.addValue(ScratchpadValueEntry(expression: "ship.weapon.cooldown",
                                   valueText: "Error: field missing",
                                   isError: true))

proc applySearchResults(vm: SearchResultsVM) =
  vm.setQuery("shield")
  vm.setResults(@[
    SearchResultLine(path: "src/combat.nr", line: 42,
                     text: "let remaining_shield = shield - damage"),
    SearchResultLine(path: "src/main.nr", line: 18,
                     text: "assert(final_state.shield > 0)"),
  ])
  vm.setActive(true)

proc applyEventLog(vm: EventLogVM) =
  vm.eventRows.val = @[
    EventLogRow(eventId: 10'u64, kind: "Call", line: 8, value: "main"),
    EventLogRow(eventId: 12'u64, kind: "Write", line: 42, value: "remaining_shield = 71"),
    EventLogRow(eventId: 13'u64, kind: "Return", line: 43, value: "71"),
  ]
  vm.totalEventCount.val = 3
  vm.selectRow(some(1))

proc applyCalltrace(vm: CalltraceVM) =
  vm.setViewportHeight(12)
  vm.selectEntry(some(1'i64))
  vm.setSearchQuery("damage")
  vm.setBackendSearchResults(@[(name: "calculate_damage", rrTicks: 180, key: "damage:1")])

proc applyState(vm: StateVM) =
  vm.selectPath("ship.shield")
  vm.addWatch("remaining_shield")

proc applyFilesystem(vm: FilesystemVM) =
  vm.setRoot(storyFilesystem())
  vm.setDiffEntries(@[
    FilesystemDiffEntry(path: "src/main.nr", zebra: false),
    FilesystemDiffEntry(path: "src/combat.nr", zebra: true),
  ])

proc applyTraceLog(vm: TraceLogVM) =
  vm.setEntries(@[
    TraceLogEntry(rrTicks: 120, minRRTicks: 0, maxRRTicks: 400,
                  path: "src/main.nr", line: 18, functionName: "main",
                  localsText: "shield=100 damage=29", eventId: 10,
                  tracepointId: 1),
    TraceLogEntry(rrTicks: 180, minRRTicks: 0, maxRRTicks: 400,
                  path: "src/combat.nr", line: 42,
                  functionName: "calculate_damage",
                  localsText: "remaining_shield=71", eventId: 12,
                  tracepointId: 1),
  ])
  vm.selectEntry(1)

proc applyStepList(vm: StepListVM) =
  vm.setLineSteps(@[
    StepLine(kind: slkLine, delta: -1,
             location: StepLineLocation(path: "src/combat.nr", line: 41,
                                        functionName: "calculate_damage",
                                        rrTicks: 140),
             sourceLine: "let damage = incoming_damage / armor",
             values: @[StepLineFlowValue(expression: "damage", value: "29")]),
    StepLine(kind: slkLine, delta: 0,
             location: StepLineLocation(path: "src/combat.nr", line: 42,
                                        functionName: "calculate_damage",
                                        rrTicks: 180),
             sourceLine: "let remaining_shield = shield - damage",
             values: @[StepLineFlowValue(expression: "remaining_shield",
                                         value: "71")]),
    StepLine(kind: slkReturn, delta: 1,
             location: StepLineLocation(path: "src/combat.nr", line: 43,
                                        functionName: "calculate_damage",
                                        rrTicks: 220),
             sourceLine: "return remaining_shield",
             values: @[StepLineFlowValue(expression: "result", value: "71")]),
  ])
  vm.setCurrentLocation(StepLineLocation(path: "src/combat.nr", line: 42,
                                        functionName: "calculate_damage",
                                        rrTicks: 180))

proc applyNoSource(vm: NoSourceVM) =
  vm.setMessage("No source file is available for this frame.")
  vm.setLocation(NoSourceLocationInfo(functionName: "__libc_start_main",
                                      path: "/usr/lib/libc.so", line: -1))
  vm.setHistory(NoSourceHistoryInfo(hasHistory: true,
                                    previousPath: "src/main.nr",
                                    action: "step in"))
  vm.setOriginatingAddress("0x4010af")

proc applyLowLevelCode(vm: LowLevelCodeVM) =
  vm.setAddress(0x401000)
  vm.setInstructions(@[
    LowLevelInstruction(name: "mov", args: "eax, [rbp-0x8]",
                        other: "load shield", offset: 0,
                        highLevelPath: "src/combat.nr", highLevelLine: 42),
    LowLevelInstruction(name: "sub", args: "eax, ecx",
                        other: "apply damage", offset: 4,
                        highLevelPath: "src/combat.nr", highLevelLine: 42),
    LowLevelInstruction(name: "ret", args: "", other: "", offset: 8,
                        highLevelPath: "src/combat.nr", highLevelLine: 43),
  ])
  vm.setActiveOffset(4)

proc applyRepl(vm: ReplVM) =
  vm.setReplEnabled(true)
  vm.setLangName("Noir")

proc applyRequestPanel(vm: RequestPanelVM) =
  vm.setRequests(@[
    RequestRecord(id: 1, httpMethod: "GET", url: "/api/traces",
                  statusCode: 200, durationMs: 31, responseSize: 2048,
                  startGeid: 10'i64),
    RequestRecord(id: 2, httpMethod: "POST", url: "/api/replay/step",
                  statusCode: 500, durationMs: 84, responseSize: 512,
                  startGeid: 12'i64),
  ])
  vm.selectRequest(1)

proc applyAgentActivity(vm: AgentActivityVM) =
  vm.setSessionKey("story-session")
  vm.setMessages(@[
    AgentActivityMessageEntry(id: "m1", role: aamrUser,
                              content: "Find why the shield drops below zero."),
    AgentActivityMessageEntry(id: "m2", role: aamrAgent,
                              content: "I found a suspicious subtraction in combat.nr.",
                              diffs: @[AgentActivityDiffEntry(
                                id: 1, path: "src/combat.nr",
                                original: "shield - damage",
                                modified: "max(0, shield - damage)")]),
  ])
  vm.setTerminals(@[AgentActivityTerminalEntry(id: "terminal-1", shellId: 1)])

proc applyAgentWorkspace(vm: AgentWorkspaceVM) =
  vm.setWorkspaceMetadata("/workspace/noir-space-ship", "story-session")
  vm.setSummary(AgentWorkspaceSummary(totalLinesCovered: 140,
                                      totalLinesUncovered: 24,
                                      coveragePercent: 85.4,
                                      testsRun: 18,
                                      testsPassed: 17,
                                      testsFailed: 1,
                                      functionsTraced: 12))
  vm.setFiles([
    AgentWorkspaceFileEntry(path: "src/main.nr", coveredLines: 72,
                            totalLines: 80, hasFlow: true),
    AgentWorkspaceFileEntry(path: "src/combat.nr", coveredLines: 68,
                            totalLines: 84, hasFlow: true),
  ])
  vm.setNotificationCount(3)

proc applyDeepReview(vm: DeepReviewVM) =
  vm.setHasData(true)
  vm.setHeader("noir-space-ship", "HEAD 23686aaa", "164 changed lines")
  vm.setTraceContexts([
    DeepReviewTraceContextEntry(id: 1, label: "Noir replay"),
    DeepReviewTraceContextEntry(id: 2, label: "Unit tests"),
  ])
  vm.setFiles([
    DeepReviewFileEntry(path: "src/main.nr", diffStatus: "modified",
                        linesAdded: 8, linesRemoved: 2,
                        coverageText: "90%", hasCoverage: true,
                        hasFlow: true),
    DeepReviewFileEntry(path: "src/combat.nr", diffStatus: "modified",
                        linesAdded: 11, linesRemoved: 4,
                        coverageText: "81%", hasCoverage: true,
                        hasFlow: true),
  ])
  vm.setUnifiedFiles([
    DeepReviewUnifiedFileEntry(fileIndex: 0, path: "src/combat.nr",
                               diffStatus: "modified", linesAdded: 11,
                               linesRemoved: 4, hunks: @[
      DeepReviewHunkEntry(oldStart: 38, oldCount: 6, newStart: 38, newCount: 7,
                          lines: @[
        DeepReviewDiffLineEntry(lineType: "context",
                                content: "fn calculate_damage(ship, weapon) {",
                                oldLine: 38, newLine: 38),
        DeepReviewDiffLineEntry(lineType: "added",
                                content: "  let remaining_shield = max(0, shield - damage);",
                                oldLine: 0, newLine: 42,
                                values: @[DeepReviewFlowValueEntry(
                                  name: "remaining_shield", value: "71")]),
      ]),
    ]),
  ])
  vm.setCallNodes([
    DeepReviewCallNodeEntry(name: "main", executionCount: 1, depth: 0),
    DeepReviewCallNodeEntry(name: "calculate_damage", executionCount: 12, depth: 1),
  ])

proc applyAgentActivityDeepReview(vm: AgentActivityDeepReviewVM) =
  vm.setExpanded(true)
  vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
    totalLinesCovered: 140, totalLinesUncovered: 24,
    coveragePercent: 85.4, functionsTraced: 12))
  vm.setTestResults(AgentDeepReviewTestResults(
    testsRun: 18, testsPassed: 17, testsFailed: 1, totalDurationMs: 9200))
  vm.setFileCoverage([
    AgentDeepReviewFileCoverage(path: "src/main.nr", coveredLines: 72,
                                totalLines: 80, hasFlow: true),
    AgentDeepReviewFileCoverage(path: "src/combat.nr", coveredLines: 68,
                                totalLines: 84, hasFlow: true),
  ])
  vm.appendNotification(AgentDeepReviewNotification(
    kind: adrnkCoverageUpdate, label: "Coverage updated for src/combat.nr"))
  vm.appendNotification(AgentDeepReviewNotification(
    kind: adrnkTestComplete, label: "shield regression test failed",
    passed: false))

proc applyWelcome(vm: WelcomeScreenVM) =
  vm.setRecentTraces(@[
    RecentTraceRecord(id: 1, program: "noir-space-ship",
                      args: @["test"], workdir: "/workspace/noir-space-ship",
                      date: "2026/05/04 16:03:00", duration: "4.2s"),
    RecentTraceRecord(id: 2, program: "sudoku",
                      args: @[], workdir: "/workspace/sudoku",
                      date: "2026/05/03 12:44:00", duration: "1.1s"),
  ])
  vm.setRecentFolders(@[
    RecentFolderRecord(id: 1, name: "CodeTracer", path: "/home/zahary/metacraft/codetracer"),
    RecentFolderRecord(id: 2, name: "Noir", path: "/home/zahary/metacraft/noir"),
  ])
  vm.setStartOptions(@[
    WelcomeStartOptionRecord(key: "open-folder", name: "Open folder"),
    WelcomeStartOptionRecord(key: "record-new-trace", name: "Record new trace"),
    WelcomeStartOptionRecord(key: "open-online-trace", name: "Open online trace"),
  ])

proc applyCommandPalette(vm: CommandPaletteVM) =
  vm.setQuery("open")
  vm.setResults([
    CommandPaletteResultEntry(value: "Open File", kind: cprkCommand),
    CommandPaletteResultEntry(value: "src/main.nr", kind: cprkFile,
                              file: "src/main.nr"),
    CommandPaletteResultEntry(value: "calculate_damage", kind: cprkSymbol,
                              file: "src/combat.nr", line: 38,
                              symbolKind: "function"),
  ])
  vm.setSelected(1)

proc applyVCS(vm: VCSVM) =
  vm.setHeader("Source Control")
  vm.setGitRepoState(true)
  vm.setBranchState("codetracer-viewmodel", ["main", "codetracer-viewmodel"], false)
  vm.setCommits([
    VCSCommitRow(hash: "23686aaa",
                 message: "fix(storybook): make terminal story buildable",
                 relativeTime: "today"),
    VCSCommitRow(hash: "4635f657",
                 message: "feat: scaffold terminal output storybook",
                 relativeTime: "today"),
  ], 0)
  vm.setChangedFiles([
    VCSFileRow(path: "src/frontend/storybook_components.nim", status: "modified",
               baseName: "storybook_components.nim", additions: 240,
               deletions: 20, coverageText: "story", selected: true),
    VCSFileRow(path: "storybook/stories/CodeTracerSurfaces.stories.js",
               status: "added", baseName: "CodeTracerSurfaces.stories.js",
               additions: 180, deletions: 0, coverageText: "story"),
  ])
  vm.setUnifiedDiff(true, [
    VCSDiffFileRow(path: "src/frontend/storybook_components.nim",
                   status: "modified", fileIndex: 0, additions: 240,
                   deletions: 20, hunks: @[
      VCSHunkRow(oldStart: 1, oldCount: 3, newStart: 1, newCount: 4,
                 selected: true, lines: @[
        VCSDiffLineRow(lineType: "added", oldLine: 0, newLine: 1,
                       content: "mount every IsoNim panel"),
      ]),
    ]),
  ])

proc applySearch(vm: SearchVM) =
  vm.setMode(smFindInFiles)
  vm.setQuery("shield")
  vm.selectResult(some(0))

proc applyShell(vm: ShellVM) =
  vm.inputHistory.val = @["print(remaining_shield)", "continue"]
  vm.setInput("print(ship)")

proc mountBuild(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createBuildVM(store)
    vm.applyBuild(fixture)
    mountIsoNimBuild(container, vm)
    return proc() = vm.dispose())

proc mountErrors(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createErrorsVM(store)
    if fixture != "empty": vm.applyErrors()
    mountIsoNimErrors(container, vm)
    return proc() = vm.dispose())

proc mountScratchpad(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createScratchpadVM(store)
    if fixture != "empty": vm.applyScratchpad()
    mountIsoNimScratchpadPanel(container, vm)
    return proc() = vm.dispose())

proc mountSearchResults(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createSearchResultsVM(store)
    if fixture != "empty": vm.applySearchResults()
    mountIsoNimSearchResults(container, vm)
    return proc() = vm.dispose())

proc mountEventLog(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createEventLogVM(store)
    if fixture == "loading":
      vm.loadingState.val = lsLoading
    else:
      vm.applyEventLog()
    mountIsoNimEventLog(container, vm)
    return proc() = vm.dispose())

proc mountCalltrace(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createCalltraceVM(store)
    if fixture != "empty": vm.applyCalltrace()
    mountIsoNimCalltrace(container, vm)
    return proc() = vm.dispose())

proc mountState(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createStateVM(store)
    if fixture != "empty": vm.applyState()
    mountIsoNimStatePanel(container, vm)
    return proc() = vm.dispose())

proc mountEditor(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createEditorVM(store)
    vm.setCursor(42, 3)
    discard mountIsoNimEditor(container, vm, 0, "src/combat.nr", false, 0, "storybook-editor")
    return proc() = vm.dispose())

proc mountFilesystem(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createFilesystemVM(store)
    if fixture != "empty": vm.applyFilesystem()
    mountIsoNimFilesystemPanel(container, vm)
    return proc() = vm.dispose())

proc mountFlow(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createFlowVM(store)
    vm.iterationCount.val = 12
    vm.selectIteration(5)
    mountIsoNimFlow(container, vm)
    return proc() = vm.dispose())

proc mountTraceLog(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createTraceLogVM(store)
    if fixture != "empty": vm.applyTraceLog()
    mountIsoNimTraceLogPanel(container, vm)
    return proc() = vm.dispose())

proc mountStepList(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createStepListVM(store)
    if fixture != "empty": vm.applyStepList()
    mountIsoNimStepList(container, vm)
    return proc() = vm.dispose())

proc mountNoSource(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createNoSourceVM(store)
    vm.applyNoSource()
    mountIsoNimNoSource(container, vm)
    return proc() = vm.dispose())

proc mountLowLevelCode(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createLowLevelCodeVM(store)
    if fixture == "error": vm.setErrorMessage("Unable to load assembly")
    else: vm.applyLowLevelCode()
    mountIsoNimLowLevelCode(container, vm)
    return proc() = vm.dispose())

proc mountRepl(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createReplVM(store)
    if fixture == "materialized": vm.setMaterialized(true) else: vm.applyRepl()
    mountIsoNimRepl(container, vm)
    return proc() = vm.dispose())

proc mountRequestPanel(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createRequestPanelVM(store)
    if fixture != "empty": vm.applyRequestPanel()
    mountIsoNimRequestPanel(container, vm)
    return proc() = vm.dispose())

proc mountAgentActivity(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createAgentActivityVM(store)
    if fixture != "empty": vm.applyAgentActivity()
    if fixture == "loading": vm.setLoading(true)
    mountIsoNimAgentActivityPanel(container, vm, 101, "storybook-agent-input")
    return proc() = vm.dispose())

proc mountAgentActivityDeepReview(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createAgentActivityDeepReviewVM(store)
    if fixture != "empty": vm.applyAgentActivityDeepReview()
    mountIsoNimAgentActivityDeepReviewPanel(container, vm)
    return proc() = vm.dispose())

proc mountAgentWorkspace(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createAgentWorkspaceVM(store)
    if fixture != "empty": vm.applyAgentWorkspace()
    mountIsoNimAgentWorkspacePanel(container, vm, 103)
    return proc() = vm.dispose())

proc mountDeepReview(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createDeepReviewVM(store)
    if fixture != "empty": vm.applyDeepReview()
    mountIsoNimDeepReviewPanel(container, vm, 104)
    return proc() = vm.dispose())

proc mountWelcome(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createWelcomeScreenVM(store)
    vm.applyWelcome()
    case fixture
    of "record": vm.setMode(wsmNewRecord)
    of "online": vm.setMode(wsmOnlineTrace)
    else: discard
    mountIsoNimWelcomeScreen(container, vm)
    return proc() = vm.dispose())

proc mountCommandPalette(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createCommandPaletteVM(store)
    if fixture != "empty": vm.applyCommandPalette()
    mountIsoNimCommandPalettePanel(container, vm)
    return proc() = vm.dispose())

proc mountVcs(container: isonim_dom.Element; fixture: string): DisposeProc =
  var rootDisposer: proc()
  var vm: VCSVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createVCSVM()
    if fixture != "empty": vm.applyVCS()
    mountIsoNimVCSPanel(container, vm)
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc mountDebugControls(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createDebugControlsVM(store)
    mountIsoNimDebugControls(container, vm)
    return proc() = vm.dispose())

proc mountPointList(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createPointListVM(store)
    vm.selectPoint(some(0))
    mountIsoNimPointList(container, vm)
    return proc() = vm.dispose())

proc mountTimeline(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createTimelineVM(store)
    vm.pan(0'u64, 400'u64)
    vm.hover(some(180'u64))
    mountIsoNimTimeline(container, vm)
    return proc() = vm.dispose())

proc mountSearch(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createSearchVM(store)
    if fixture != "empty": vm.applySearch()
    mountIsoNimSearch(container, vm)
    return proc() = vm.dispose())

proc mountShell(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createShellVM(store)
    if fixture != "empty": vm.applyShell()
    mountIsoNimShell(container, vm)
    return proc() = vm.dispose())

proc mountCalltraceEditor(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createCalltraceEditorVM(store)
    mountIsoNimCalltraceEditor(container, vm)
    return proc() = vm.dispose())

proc mountTerminalOutput(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createTerminalOutputVM(store)
    case fixture
    of "loading":
      vm.clearLines()
      vm.setCurrentRRTicks(0'u64)
    of "empty":
      vm.setLines(@[])
      vm.setCurrentRRTicks(0'u64)
    else:
      vm.setLines(storyLines())
      vm.setCurrentRRTicks(180'u64)
    mountIsoNimTerminalOutput(container, vm)
    return proc() = vm.dispose())

proc appendRendered(container: isonim_dom.Element; node: isonim_dom.Element) =
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(node))

proc mountStructure(container: isonim_dom.Element; name, fixture: string): DisposeProc =
  let r = WebRenderer()
  case name
  of "session-tabs":
    appendRendered(container, renderSessionTabsPanel(r, @[
      SessionTabRecord(label: "noir-space-ship"),
      SessionTabRecord(label: "sudoku"),
    ], 0))
  of "menu-shell":
    let fileNode = MenuNodeRecord(kind: MenuRecordElement, name: "Open File",
                                  shortcut: "Ctrl+P", enabled: true,
                                  nodeClass: "", path: @[0], nameWidth: 16)
    let debugNode = MenuNodeRecord(kind: MenuRecordFolder, name: "Debug",
                                   enabled: true, nodeClass: "", path: @[1],
                                   nameWidth: 16, children: @[
      MenuNodeRecord(kind: MenuRecordElement, name: "Start Debugging",
                     shortcut: "F5", enabled: true, path: @[1, 0],
                     nameWidth: 18),
    ])
    appendRendered(container, renderMenuShell(r, MenuShellModel(
      showNavigation: true, active: true, searchQuery: "",
      rootNodes: @[fileNode, debugNode],
      showWindowMenu: true,
    )))
  of "status-shell":
    appendRendered(container, renderStatusShell(r, StatusShellModel(
      activeNotifications: @[
        StatusNotificationRecord(index: 0, kindClass: "info",
                                 variantClass: "default",
                                 text: "Replay ready", dismissible: true),
      ],
      base: StatusBaseModel(language: "Noir", encoding: "UTF-8",
                            processClass: "debug-status-ready",
                            processText: "ready",
                            locationText: "src/combat.nr:42",
                            locationTitle: "src/combat.nr:42"),
      showNotifications: fixture == "history",
    )))
  of "debug-shell":
    appendRendered(container, renderDebugChromePanel(r, 3))
  of "auto-hide-bottom-tabs":
    appendRendered(container, renderAutoHideBottomTabsPanel(r, @[
      AutoHideBottomTabRecord(title: "Terminal Output"),
      AutoHideBottomTabRecord(title: "Build"),
    ]))
  of "auto-hide-collapsed-icons":
    appendRendered(container, renderAutoHideCollapsedIconsPanel(r, @[
      AutoHideCollapsedIconRecord(title: "Calltrace", icon: "C"),
      AutoHideCollapsedIconRecord(title: "State", icon: "S"),
    ]))
  of "auto-hide-overlay-tabs":
    appendRendered(container, renderAutoHideOverlayTabsPanel(r, @[
      AutoHideOverlayTabRecord(title: "Calltrace", active: true),
      AutoHideOverlayTabRecord(title: "State", active: false),
    ], true, " side-tabs-left"))
  of "auto-hide-side-strip":
    appendRendered(container, renderAutoHideSideStripPanel(r, @[
      AutoHideSideStripRecord(title: "Calltrace"),
      AutoHideSideStripRecord(title: "State"),
    ], fixture == "collapsed"))
  else:
    let node = r.createElement("div")
    r.setAttribute(node, "class", "ct-storybook-missing")
    r.setTextContent(node, "No structure story registered for " & name)
    appendRendered(container, node)
  return proc() = container.innerHTML = ""

proc mountLayout(container: isonim_dom.Element; name, fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let r = WebRenderer()
    let shell = renderIsoNimAppShell(r)
    appendRendered(container, shell.root)
    var disposers: seq[DisposeProc] = @[]
    for section in shell.sections:
      case section.panelId
      of "state":
        let vm = createStateVM(store); vm.applyState()
        mountIsoNimStatePanel(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "calltrace":
        let vm = createCalltraceVM(store); vm.applyCalltrace()
        mountIsoNimCalltrace(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "event-log":
        let vm = createEventLogVM(store); vm.applyEventLog()
        mountIsoNimEventLog(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "flow":
        let vm = createFlowVM(store); vm.iterationCount.val = 12; vm.selectIteration(5)
        mountIsoNimFlow(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "timeline":
        let vm = createTimelineVM(store); vm.pan(0'u64, 400'u64)
        mountIsoNimTimeline(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "search":
        let vm = createSearchVM(store); vm.applySearch()
        mountIsoNimSearch(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "point-list":
        let vm = createPointListVM(store); vm.selectPoint(some(0))
        mountIsoNimPointList(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "scratchpad":
        let vm = createScratchpadVM(store); vm.applyScratchpad()
        mountIsoNimScratchpadPanel(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "shell":
        let vm = createShellVM(store); vm.applyShell()
        mountIsoNimShell(section.content, vm)
        disposers.add(proc() = vm.dispose())
      else:
        discard
    return proc() =
      for dispose in disposers:
        dispose())

proc mountCodeTracerStory*(container: isonim_dom.Element;
                           kind: cstring;
                           name: cstring;
                           fixture: cstring): DisposeProc {.exportc.} =
  let k = $kind
  let n = $name
  let f = $fixture
  case k
  of "layout":
    mountLayout(container, n, f)
  of "view", "component":
    mountStructure(container, n, f)
  else:
    case n
    of "agent-activity": mountAgentActivity(container, f)
    of "agent-activity-deepreview": mountAgentActivityDeepReview(container, f)
    of "agent-workspace": mountAgentWorkspace(container, f)
    of "build": mountBuild(container, f)
    of "calltrace": mountCalltrace(container, f)
    of "calltrace-editor": mountCalltraceEditor(container, f)
    of "command-palette": mountCommandPalette(container, f)
    of "debug-controls": mountDebugControls(container, f)
    of "deepreview": mountDeepReview(container, f)
    of "editor": mountEditor(container, f)
    of "errors": mountErrors(container, f)
    of "event-log": mountEventLog(container, f)
    of "filesystem": mountFilesystem(container, f)
    of "flow": mountFlow(container, f)
    of "low-level-code": mountLowLevelCode(container, f)
    of "no-source": mountNoSource(container, f)
    of "point-list": mountPointList(container, f)
    of "repl": mountRepl(container, f)
    of "request-panel": mountRequestPanel(container, f)
    of "scratchpad": mountScratchpad(container, f)
    of "search": mountSearch(container, f)
    of "search-results": mountSearchResults(container, f)
    of "shell": mountShell(container, f)
    of "state": mountState(container, f)
    of "step-list": mountStepList(container, f)
    of "terminal-output": mountTerminalOutput(container, f)
    of "timeline": mountTimeline(container, f)
    of "trace-log": mountTraceLog(container, f)
    of "vcs": mountVcs(container, f)
    of "welcome-screen": mountWelcome(container, f)
    else: mountStructure(container, n, f)

proc mountTerminalOutputPanel*(container: isonim_dom.Element;
                               fixture: cstring): DisposeProc {.exportc.} =
  ## Backward-compatible export used by the original terminal story.
  mountTerminalOutput(container, $fixture)
