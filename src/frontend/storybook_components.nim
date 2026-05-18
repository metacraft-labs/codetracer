## Storybook-compatible exports for CodeTracer IsoNim surfaces.
##
## Compiled with:
##   nim js -o:storybook/dist/components.js src/frontend/storybook_components.nim

when not defined(js):
  {.error: "storybook_components.nim requires the JS backend (nim js)".}

import std/[json, options, strutils, tables]

import isonim/core/async_compat
import isonim/rxcore
import isonim/viewmodel
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer

import viewmodel/backend/mock_backend
import viewmodel/backend/backend_service
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
  frame_viewer_vm,
  pixel_history_vm,
  shader_debug_vm,
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
  visual_replay_client,
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
  isonim_frame_viewer_view,
  isonim_pixel_history_view,
  isonim_shader_debug_view,
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

proc storyCalltraceLines(): seq[CallLine] =
  result = @[
    CallLine(index: 0, name: "main", depth: 0, rrTicks: 2'u64,
             location: Location(file: "src/main.nr", line: 13, column: 3),
             hasChildren: true, isExpanded: true, callKey: "main:0"),
  ]
  var idx = 1'i64

  template addIterationBlock(prefix: string; iteration: int;
                             rrBase: uint64; statusLine: int) =
    result.add(CallLine(index: idx, name: "calculate_damage",
      depth: 2, rrTicks: rrBase,
      location: Location(file: "src/shield.nr", line: 58, column: 3,
                         callstackDepth: 2),
      hasChildren: true, isExpanded: true,
      callKey: prefix & "-damage:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_remaining_shield_pct",
      depth: 3, rrTicks: rrBase + 6,
      location: Location(file: "src/shield.nr", line: 61, column: 3,
                         callstackDepth: 3),
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-remaining:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_shield_regeneration",
      depth: 2, rrTicks: rrBase + 20,
      location: Location(file: "src/shield.nr", line: 66, column: 3,
                         callstackDepth: 2),
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-regen:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "status_report",
      depth: 1, rrTicks: rrBase + 62,
      location: Location(file: "src/main.nr", line: statusLine, column: 3,
                         callstackDepth: 1),
      hasChildren: true, isExpanded: true,
      callKey: prefix & "-status:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_remaining_shield_pct",
      location: Location(file: "src/shield.nr", line: 61, column: 3,
                         callstackDepth: 2),
      depth: 2, rrTicks: rrBase + 68,
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-status-remaining:" & $iteration))
    inc idx

  result.add(CallLine(index: idx, name: "iterate_asteroids",
    depth: 1, rrTicks: 46'u64,
    location: Location(file: "src/shield.nr", line: 54, column: 3),
    hasChildren: true, isExpanded: true,
    callKey: "iterate:positive"))
  inc idx
  for iteration in 0 .. 7:
    addIterationBlock("positive", iteration, uint64(52 + iteration * 68), 17)

  result.add(CallLine(index: idx, name: "iterate_asteroids",
    depth: 1, rrTicks: 590'u64,
    location: Location(file: "src/shield.nr", line: 54, column: 3),
    hasChildren: true, isExpanded: true,
    callKey: "iterate:negative"))
  inc idx
  for iteration in 0 .. 3:
    addIterationBlock("negative", iteration, uint64(596 + iteration * 68), 27)

proc storyCalltraceArgs(): Table[string, seq[CallArg]] =
  result = initTable[string, seq[CallArg]]()
  result["main:0"] = @[
    CallArg(name: "initial_shield", text: "10000"),
    CallArg(name: "shield_regen_percentage", text: "10"),
    CallArg(name: "asteroid_masses_positive",
            text: "@[100, 2000, 200, 100, 100, 50, 50, 14]"),
    CallArg(name: "asteroid_masses_negative",
            text: "@[2000, 300, 200, 20, 15, 20, 1, 1]"),
    CallArg(name: "__return", text: "nil"),
  ]

  template addIterateArgs(key, masses, returnValue: string) =
    result[key] = @[
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "shield_regen_percentage", text: "10"),
      CallArg(name: "masses", text: masses),
      CallArg(name: "__return", text: returnValue),
    ]

  template addBlockArgs(prefix: string; iteration: int; remainingBefore,
                        remainingAfter, damage, mass, regenerated,
                        statusRemaining, pctReturn: int) =
    result[prefix & "-damage:" & $iteration] = @[
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "remaining_shield", text: $remainingBefore),
      CallArg(name: "mass", text: $mass),
      CallArg(name: "__return", text: $damage),
    ]
    result[prefix & "-remaining:" & $iteration] = @[
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "remaining_shield", text: $remainingBefore),
      CallArg(name: "__return", text: $(remainingBefore div 100)),
    ]
    result[prefix & "-regen:" & $iteration] = @[
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "remaining_shield", text: $remainingAfter),
      CallArg(name: "shield_regen_percentage", text: "10"),
      CallArg(name: "__return", text: $regenerated),
    ]
    result[prefix & "-status:" & $iteration] = @[
      CallArg(name: "iteration", text: $iteration),
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "remaining_shield", text: $statusRemaining),
      CallArg(name: "damage", text: $damage),
      CallArg(name: "regenerated_shield", text: $regenerated),
      CallArg(name: "__return", text: "nil"),
    ]
    result[prefix & "-status-remaining:" & $iteration] = @[
      CallArg(name: "initial_shield", text: "10000"),
      CallArg(name: "remaining_shield", text: $statusRemaining),
      CallArg(name: "__return", text: $pctReturn),
    ]

  addIterateArgs("iterate:positive",
    "@[100, 2000, 200, 100, 100, 50, 50, 14]", "true")
  let positiveMasses = [100, 2000, 200, 100, 100, 50, 50, 14]
  let positiveDamage = [100, 2000, 2000, 2000, 3000, 2500, 3250, 1232]
  let positiveBefore = [10000, 10000, 9000, 8000, 7000, 5000, 3500, 1250]
  let positiveAfter = [9900, 8000, 7000, 6000, 4000, 2500, 250, 18]
  let positiveRegen = [100, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
  let positiveStatus = [10000, 9000, 8000, 7000, 5000, 3500, 1250, 1018]
  let positivePct = [100, 90, 80, 70, 50, 35, 12, 10]
  for iteration in 0 .. 7:
    addBlockArgs("positive", iteration, positiveBefore[iteration],
                 positiveAfter[iteration], positiveDamage[iteration],
                 positiveMasses[iteration], positiveRegen[iteration],
                 positiveStatus[iteration], positivePct[iteration])

  addIterateArgs("iterate:negative",
    "@[2000, 300, 200, 20, 15, 20, 1, 1]", "false")
  let negativeMasses = [2000, 300, 200, 20]
  let negativeDamage = [2000, 3000, 6000, 1600]
  let negativeBefore = [10000, 9000, 7000, 2000]
  let negativeAfter = [8000, 6000, 1000, 400]
  let negativeStatus = [9000, 7000, 2000, 1400]
  let negativePct = [90, 70, 20, 14]
  for iteration in 0 .. 3:
    addBlockArgs("negative", iteration, negativeBefore[iteration],
                 negativeAfter[iteration], negativeDamage[iteration],
                 negativeMasses[iteration], 1000, negativeStatus[iteration],
                 negativePct[iteration])

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
  result.calltrace.lines.val = storyCalltraceLines()
  result.calltrace.args.val = storyCalltraceArgs()
  result.calltrace.totalCallsCount.val = 80'u64
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

proc terminalLine(lineIndex: int; htmlText: string; rrTicks: uint64): TerminalLine =
  TerminalLine(lineIndex: lineIndex, fragments: @[
    TerminalEventFragment(
      htmlText: htmlText,
      eventIndex: lineIndex,
      rrTicks: rrTicks,
    ),
  ])

proc demoTerminalLines(): seq[TerminalLine] =
  @[
    terminalLine(
      0,
      "<span class=\"ansi-bright-green-fg\">CodeTracer</span> replay started",
      100'u64,
    ),
    TerminalLine(lineIndex: 1, fragments: @[
      TerminalEventFragment(htmlText: "running ", eventIndex: 11, rrTicks: 140'u64),
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-cyan-fg\">noir-space-ship</span>",
        eventIndex: 12,
        rrTicks: 180'u64,
      ),
    ]),
    terminalLine(
      2,
      "<span class=\"ansi-bright-yellow-fg\">warning:</span> flow loop still rendering",
      220'u64,
    ),
  ]

const noirTerminalTranscript = [
  "Positive Test Case",
  "----- iteration 0 -----",
  "Damage: 100",
  "Regenerated 100 energy",
  "Shield status 100% 10000",
  "----- iteration 1 -----",
  "Damage: 2000",
  "Regenerated 1000 energy",
  "Shield status 90% 9000",
  "----- iteration 2 -----",
  "Damage: 2000",
  "Regenerated 1000 energy",
  "Shield status 80% 8000",
  "----- iteration 3 -----",
  "Damage: 2000",
  "Regenerated 1000 energy",
  "Shield status 70% 7000",
  "----- iteration 4 -----",
  "Damage: 3000",
  "Regenerated 1000 energy",
  "Shield status 50% 5000",
  "----- iteration 5 -----",
  "Damage: 2500",
  "Regenerated 1000 energy",
  "Shield status 35% 3500",
  "----- iteration 6 -----",
  "Damage: 3250",
  "Regenerated 1000 energy",
  "Shield status 12% 1250",
  "----- iteration 7 -----",
  "Damage: 1232",
  "Regenerated 1000 energy",
  "Shield status 10% 1018",
  "shields will hold as expected",
  "------------------",
  "Negative Test Case",
  "------------------",
  "----- iteration 0 -----",
  "Damage: 2000",
  "Regenerated 1000 energy",
  "Shield status 90% 9000",
  "----- iteration 1 -----",
  "Damage: 3000",
  "Regenerated 1000 energy",
  "Shield status 70% 7000",
  "----- iteration 2 -----",
  "Damage: 6000",
  "Regenerated 1000 energy",
  "Shield status 20% 2000",
  "----- iteration 3 -----",
  "Damage: 1600",
  "Regenerated 1000 energy",
  "Shield status 14% 1400",
  "----- iteration 4 -----",
  "Damage: 1290",
  "Regenerated 1000 energy",
  "Shield status 11% 1110",
  "----- iteration 5 -----",
  "Damage: 1110",
  "Regenerated 0 energy",
  "Shield status 0% 0",
  "----- iteration 6 -----",
  "Damage: 0",
  "Regenerated 0 energy",
  "Shield status 0% 0",
  "----- iteration 7 -----",
  "Damage: 0",
  "Regenerated 0 energy",
  "Shield status 0% 0",
  "shields will not hold as expected",
]

const noirEventTicks = [
  2'u64,
  46'u64, 52'u64, 58'u64, 72'u64,
  114'u64, 120'u64, 126'u64, 140'u64,
  182'u64, 188'u64, 194'u64, 208'u64,
  250'u64, 256'u64, 262'u64, 276'u64,
  318'u64, 324'u64, 330'u64, 344'u64,
  386'u64, 392'u64, 398'u64, 412'u64,
  454'u64, 460'u64, 466'u64, 480'u64,
  522'u64, 528'u64, 534'u64, 548'u64,
  560'u64, 565'u64, 570'u64, 575'u64,
  618'u64, 624'u64, 630'u64, 644'u64,
  686'u64, 692'u64, 698'u64, 712'u64,
  754'u64, 760'u64, 766'u64, 780'u64,
  822'u64, 828'u64, 834'u64, 848'u64,
  890'u64, 896'u64, 902'u64, 916'u64,
  950'u64, 956'u64, 962'u64, 976'u64,
  1010'u64, 1016'u64, 1022'u64, 1036'u64,
  1070'u64, 1076'u64, 1082'u64, 1096'u64,
  1108'u64,
]

proc storyLines(): seq[TerminalLine] =
  result = @[]
  for lineIndex, text in noirTerminalTranscript:
    result.add(terminalLine(lineIndex, text, uint64(100 + lineIndex * 6)))

proc storyProblems(): seq[BuildProblemLine] =
  @[
    BuildProblemLine(severity: blsError, path: "src/main.nr", line: 13,
                     col: 10, message: "expected field `shield` to be u32"),
    BuildProblemLine(severity: blsWarning, path: "src/shield.nr", line: 61,
                     col: 3, message: "unused variable `debug_mode`"),
  ]

proc storyFilesystem(): FilesystemEntryNode =
  FilesystemEntryNode(
    id: "1_1",
    text: "source folders",
    path: "/workspace/source folders",
    isFolder: true,
    isExpanded: true,
    children: @[
      FilesystemEntryNode(id: "1_2", text: "codetracer-main",
                          path: "/workspace/source folders/codetracer-main",
                          isFolder: true, isExpanded: true, children: @[
        FilesystemEntryNode(id: "1_3", text: "test-programs",
                            path: "/workspace/source folders/codetracer-main/test-programs",
                            isFolder: true, isExpanded: true, children: @[
          FilesystemEntryNode(id: "1_4", text: "noir_space_ship",
                              path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship",
                              isFolder: true, isExpanded: true, children: @[
            FilesystemEntryNode(id: "1_5", text: "Nargo.toml",
                                path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship/Nargo.toml",
                                icon: "devicon-rust-original"),
            FilesystemEntryNode(id: "1_6", text: "Prover.toml",
                                path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship/Prover.toml",
                                icon: "devicon-rust-original"),
            FilesystemEntryNode(id: "1_7", text: "src",
                                path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship/src",
                                isFolder: true, isExpanded: true, children: @[
              FilesystemEntryNode(id: "1_8", text: "main.nr",
                                  path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship/src/main.nr",
                                  icon: "custom-noir-icon"),
              FilesystemEntryNode(id: "1_9", text: "shield.nr",
                                  path: "/workspace/source folders/codetracer-main/test-programs/noir_space_ship/src/shield.nr",
                                  icon: "custom-noir-icon"),
            ]),
          ]),
        ]),
      ]),
    ],
  )

proc applyBuild(vm: BuildVM; fixture: string) =
  vm.setCommand("nargo test")
  vm.setRunning(fixture == "loading")
  vm.appendLine(BuildOutputLine(htmlText: "$ nargo test --workspace noir_space_ship",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(htmlText: "Compiling noir_space_ship v0.2.0",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(htmlText: "Checking src/main.nr",
                                isStdout: true, severity: blsInfo))
  vm.appendLine(BuildOutputLine(
    htmlText: "<span class=\"ansi-bright-red-fg\">src/main.nr:13:10 error:</span> expected u32",
    isStdout: false,
    severity: blsError,
    locationPath: "src/main.nr",
    locationLine: 13,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "  let did_survive_positive = shield.iterate_asteroids(...)",
    isStdout: false,
    severity: blsError,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "         ^^^^^^^^^^^^^ expected field `shield` to be u32",
    isStdout: false,
    severity: blsError,
  ))
  vm.appendLine(BuildOutputLine(
    htmlText: "<span class=\"ansi-bright-yellow-fg\">src/shield.nr:61:3 warning:</span> unused variable `debug_mode`",
    isStdout: false,
    severity: blsWarning,
    locationPath: "src/shield.nr",
    locationLine: 61,
  ))
  for problem in storyProblems():
    vm.appendProblem(problem)
  vm.setCode(if fixture == "success": 0 else: 1)

proc applyErrors(vm: ErrorsVM) =
  vm.setProblems(storyProblems())

proc applyScratchpad(vm: ScratchpadVM) =
  vm.clearValues()
  vm.addValue(ScratchpadValueEntry(
    expression: "remaining_shield",
    valueText: "71",
    isError: false,
    isLiteral: false))
  vm.addValue(ScratchpadValueEntry(
    expression: "ship",
    valueText: "{ hull: 100, shield: 71 }",
    isError: false,
    isLiteral: false))
  vm.addValue(ScratchpadValueEntry(
    expression: "last_error",
    valueText: "division by zero",
    isError: true,
    isLiteral: false))

proc applySearchResults(vm: SearchResultsVM) =
  vm.setQuery("shield")
  vm.setResults(@[
    SearchResultLine(path: "src/main.nr", line: 13,
                     text: "let did_survive_positive = shield.iterate_asteroids(...)"),
    SearchResultLine(path: "src/shield.nr", line: 61,
                     text: "fn calculate_remaining_shield_pct(initial_shield, remaining_shield)"),
  ])
  vm.setActive(true)

proc storyEventLine(index: int; text: string): int =
  if index == 0:
    13
  elif index == 33:
    17
  elif index == 34:
    23
  elif index == 35:
    24
  elif index == 36:
    25
  elif index == 69:
    32
  elif text.startsWith("----- iteration"):
    54
  elif text.startsWith("Damage:"):
    58
  elif text.startsWith("Regenerated"):
    61
  elif text.startsWith("Shield status"):
    66
  else:
    13

proc storyEventRows(): seq[EventLogRow] =
  result = @[]
  for index, text in noirTerminalTranscript:
    let rrTicks =
      if index < noirEventTicks.len: noirEventTicks[index]
      else: uint64(40 + index * 6)
    result.add EventLogRow(
      eventId: rrTicks,
      kind: "",
      line: storyEventLine(index, text),
      value: "stdout: " & text)

proc applyEventLog(vm: EventLogVM) =
  vm.eventRows.val = storyEventRows()
  vm.totalEventCount.val = vm.eventRows.val.len
  vm.selectRow(some(0))

proc applyCalltrace(vm: CalltraceVM) =
  vm.setViewportHeight(48)
  vm.selectEntry(some(0'i64))
  vm.setSearchQuery("")
  vm.setBackendSearchResults(@[])
  vm.store.calltrace.loadingState.val = lsIdle

proc applyState(vm: StateVM) =
  vm.selectPath("ship.shield")

proc applyEmptyState(store: ReplayDataStore) =
  store.locals.codeStateLine.val = ""
  store.locals.locals.val = @[]
  store.locals.globals.val = @[]

proc htmlEscape(text: string): string =
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc storyEventPath(row: EventLogRow): string =
  if row.line in [13, 17, 23, 24, 25, 32]: "main.nr:" & $row.line
  elif row.line >= 38 and row.line <= 43: "combat.nr:" & $row.line
  else: "shield.nr:" & $row.line

proc storyEventDenseHtml(rows: seq[EventLogRow]; selected: Option[int]): string =
  result.add "<div class=\"dt-container dts DTS dt-empty-footer\">"
  result.add "<div class=\"dt-layout-row dt-layout-table\"><div class=\"dt-layout-cell dt-layout-full\">"
  result.add "<div class=\"dt-scroll\"><div class=\"dt-scroll-head\"><div class=\"dt-scroll-headInner\">"
  result.add "<table class=\"dataTable\"><thead><tr><th>direction location rr ticks</th><th>rr event id</th><th>fullpath</th><th>event-image</th><th>text</th></tr></thead></table>"
  result.add "</div></div><div class=\"dt-scroll-body\"><table class=\"dataTable\"><tbody>"
  for i, row in rows:
    let rowState =
      if selected.isSome and selected.get == i: "future event-selected"
      else: "future"
    let rrTicksPercent = formatFloat(float(row.eventId) / 1000.0, ffDecimal, 3)
    let rrTicksRemaining = formatFloat(101.0 - (float(row.eventId) / 1000.0),
                                       ffDecimal, 3)
    result.add "<tr class=\"" & rowState & "\">"
    result.add "<td class=\"direct-location-rr-ticks eventLog-cell dt-type-numeric sorting_1\">"
    result.add "<div class=\"rr-ticks-time-container\"><span class=\"rr-ticks-time\">" & $row.eventId & "</span></div>"
    result.add "<div class=\"rr-ticks-line-container\"><span class=\"rr-ticks-line event-rr-ticks-line\"></span>"
    result.add "<span class=\"rr-ticks-empty-remaining\" style=\"width:" &
               rrTicksRemaining & "%; left:" & rrTicksPercent & "%\"></span></div></td>"
    result.add "<td class=\"eventLog-index eventLog-cell dt-type-numeric\">" & $i & "</td>"
    result.add "<td class=\"eventLog-fullpath eventLog-cell\">" & htmlEscape(storyEventPath(row)) & "</td>"
    result.add "<td class=\"eventLog-event eventLog-cell\">" & htmlEscape(row.kind) & "</td>"
    result.add "<td class=\"eventLog-text eventLog-cell\">" & htmlEscape(row.value) & "</td>"
    result.add "</tr>"
  result.add "</tbody></table></div></div></div></div></div>"

proc storyEventDetailedHtml(): string =
  "<div class=\"dt-container dt-empty-footer\" style=\"display: none;\">" &
    "<div class=\"dt-layout-row dt-layout-table\"><div class=\"dt-layout-cell dt-layout-full\">" &
    "<table class=\"dataTable\"><tbody><tr><td class=\"dt-empty\">No data available in table</td></tr></tbody></table>" &
    "</div></div></div>"

proc populateStorybookEventLogTables(
    denseTableId, detailedTableId, denseHtml, detailedHtml: cstring) =
  {.emit: """
    const denseTable = document.getElementById(`denseTableId`);
    if (denseTable) {
      const denseHost = denseTable.closest('.eventLog-dense-table');
      if (denseHost) {
        denseHost.innerHTML = `denseHtml`;
        const eventLog = denseHost.closest('.eventLog');
        const rowCount = denseHost.querySelectorAll('tbody tr').length;
        const footer = eventLog && eventLog.querySelector('.data-tables-footer');
        if (footer) {
          footer.className = 'data-tables-footer 1to40';
          const startInput = footer.querySelector('input');
          const endRow = footer.querySelector('.data-tables-footer-end-row');
          const rowsCount = footer.querySelector('.data-tables-footer-rows-count');
          if (startInput) {
            const startValue = rowCount > 0 ? '1' : '0';
            startInput.value = startValue;
            startInput.setAttribute('value', startValue);
          }
          if (endRow) endRow.textContent = String(Math.min(40, rowCount));
          if (rowsCount) rowsCount.textContent = String(rowCount);
        }
      }
    }
    const detailedTable = document.getElementById(`detailedTableId`);
    if (detailedTable) {
      const detailedHost = detailedTable.closest('.eventLog-detailed-table');
      if (detailedHost) detailedHost.innerHTML = `detailedHtml`;
    }
  """.}

proc applyFilesystem(vm: FilesystemVM) =
  vm.setRoot(storyFilesystem())
  vm.expandPath("/workspace/source folders")
  vm.expandPath("/workspace/source folders/codetracer-main")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs/noir_space_ship")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs/noir_space_ship/src")
  vm.setDiffEntries(@[])

proc applyTraceLog(vm: TraceLogVM) =
  vm.setEntries(@[
    TraceLogEntry(rrTicks: 120, minRRTicks: 0, maxRRTicks: 400,
                  path: "src/main.nr", line: 13, functionName: "main",
                  localsText: "shield=10000 damage=100", eventId: 10,
                  tracepointId: 1),
    TraceLogEntry(rrTicks: 180, minRRTicks: 0, maxRRTicks: 400,
                  path: "src/shield.nr", line: 58,
                  functionName: "calculate_damage",
                  localsText: "remaining_shield=9900", eventId: 12,
                  tracepointId: 1),
  ])
  vm.selectEntry(1)

proc applyStepList(vm: StepListVM) =
  vm.setLineSteps(@[
    StepLine(kind: slkLine, delta: -1,
             location: StepLineLocation(path: "src/main.nr", line: 12,
                                        functionName: "main",
                                        rrTicks: 120),
             sourceLine: "fn main(initial_shield: Field, shield_regen_percentage: Field) {",
             values: @[StepLineFlowValue(expression: "initial_shield",
                                         value: "10000")]),
    StepLine(kind: slkLine, delta: 0,
             location: StepLineLocation(path: "src/main.nr", line: 13,
                                        functionName: "main",
                                        rrTicks: 180),
             sourceLine: "let did_survive_positive = shield.iterate_asteroids(...)",
             values: @[StepLineFlowValue(expression: "did_survive_positive",
                                         value: "true")]),
    StepLine(kind: slkCall, delta: 1,
             location: StepLineLocation(path: "src/shield.nr", line: 58,
                                        functionName: "calculate_damage",
                                        rrTicks: 220),
             sourceLine: "calculate_damage",
             values: @[StepLineFlowValue(expression: "mass", value: "100"),
                       StepLineFlowValue(expression: "damage", value: "100")]),
    StepLine(kind: slkReturn, delta: 2,
             location: StepLineLocation(path: "src/shield.nr", line: 61,
                                        functionName: "calculate_remaining_shield_pct",
                                        rrTicks: 240),
             sourceLine: "calculate_remaining_shield_pct",
             values: @[StepLineFlowValue(expression: "remaining_shield",
                                         value: "99")]),
  ])
  vm.setCurrentLocation(StepLineLocation(path: "src/main.nr", line: 13,
                                        functionName: "main",
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
                              content: "Find why the shield status drops below zero."),
    AgentActivityMessageEntry(id: "m2", role: aamrAgent,
                              content: "I found a suspicious damage path in shield.nr.",
                              diffs: @[AgentActivityDiffEntry(
                                id: 1, path: "src/shield.nr",
                                original: "remaining_shield - damage",
                                modified: "max(0, remaining_shield - damage)")]),
  ])
  vm.setTerminals(@[AgentActivityTerminalEntry(id: "terminal-1", shellId: 1)])

proc applyAgentWorkspace(vm: AgentWorkspaceVM) =
  vm.setWorkspaceMetadata("/workspace/noir_space_ship", "story-session")
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
    AgentWorkspaceFileEntry(path: "src/shield.nr", coveredLines: 68,
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
    DeepReviewFileEntry(path: "src/main.nr", diffStatus: "M",
                        linesAdded: 8, linesRemoved: 2,
                        coverageText: "90%", hasCoverage: true,
                        hasFlow: true),
    DeepReviewFileEntry(path: "src/shield.nr", diffStatus: "M",
                        linesAdded: 11, linesRemoved: 4,
                        coverageText: "81%", hasCoverage: true,
                        hasFlow: true),
  ])
  vm.setExecutionState(0, 1, "main")
  vm.setIterationState(0, 3)
  vm.setViewMode(drpvmUnified)
  vm.setUnifiedFiles([
    DeepReviewUnifiedFileEntry(fileIndex: 0, path: "src/shield.nr",
                               diffStatus: "M", linesAdded: 11,
                               linesRemoved: 4, hunks: @[
      DeepReviewHunkEntry(oldStart: 54, oldCount: 6, newStart: 54, newCount: 7,
                          lines: @[
        DeepReviewDiffLineEntry(lineType: "context",
                                content: "fn iterate_asteroids(masses) {",
                                oldLine: 54, newLine: 54),
        DeepReviewDiffLineEntry(lineType: "added",
                                content: "  let remaining_shield = calculate_damage(...);",
                                oldLine: 0, newLine: 58,
                                values: @[DeepReviewFlowValueEntry(
                                  name: "remaining_shield", value: "9900")]),
        DeepReviewDiffLineEntry(lineType: "removed",
                                content: "  return remaining_shield - damage;",
                                oldLine: 59, newLine: 0),
        DeepReviewDiffLineEntry(lineType: "added",
                                content: "  return max(0, remaining_shield - damage);",
                                oldLine: 0, newLine: 59,
                                values: @[DeepReviewFlowValueEntry(
                                  name: "damage", value: "2000")]),
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
    AgentDeepReviewFileCoverage(path: "src/shield.nr", coveredLines: 68,
                                totalLines: 84, hasFlow: true),
  ])
  vm.appendNotification(AgentDeepReviewNotification(
    kind: adrnkCoverageUpdate, label: "Coverage updated for src/shield.nr"))
  vm.appendNotification(AgentDeepReviewNotification(
    kind: adrnkTestComplete, label: "shield regression test failed",
    passed: false))

proc applyWelcome(vm: WelcomeScreenVM) =
  vm.setRecentTraces(@[
    RecentTraceRecord(id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
                      program: "zir_shields",
                      args: @[], workdir: "/workspace/noir_space_ship",
                      date: "2026/05/04 16:03:00", duration: "4.2s"),
    RecentTraceRecord(id: "01949fcc-7d93-7e9c-aaaa-bbbbbbbbbbbc",
                      program: "zir_shields",
                      args: @[], workdir: "/workspace/noir_space_ship",
                      date: "2026/05/03 12:44:00", duration: "1.1s"),
  ])
  vm.setRecentFolders(@[])
  vm.setStartOptions(@[
    WelcomeStartOptionRecord(key: "open-folder", name: "Open folder"),
    WelcomeStartOptionRecord(key: "record-new-trace", name: "Record new trace"),
    WelcomeStartOptionRecord(key: "open-local-trace", name: "Open local trace"),
    WelcomeStartOptionRecord(key: "open-online-trace", name: "Open online trace"),
    WelcomeStartOptionRecord(key: "codetracer-shell", name: "CodeTracer shell",
                             inactive: true),
  ])

proc applyCommandPalette(vm: CommandPaletteVM) =
  vm.open()
  vm.setQuery("open")
  vm.setInputPlaceholder("Open Online Trace")
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
  vm.setInput("")

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
    let denseTableId = "eventLog-story-dense-table-0"
    let detailedTableId = "eventLog-story-detailed-table-0"
    let searchInputId = "eventLog-story-search"
    mountIsoNimEventLogWithDataTables(
      container,
      vm,
      0,
      denseTableId,
      detailedTableId,
      searchInputId,
      proc() =
        populateStorybookEventLogTables(
          cstring(denseTableId),
          cstring(detailedTableId),
          cstring(storyEventDenseHtml(vm.eventRows.val, vm.selectedRow.val)),
          cstring(storyEventDetailedHtml())))
    return proc() = vm.dispose())

proc mountCalltrace(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createCalltraceVM(store)
    if fixture != "empty": vm.applyCalltrace()
    if fixture == "search-status-report":
      vm.setSearchQuery("status_report")
      vm.setBackendSearchResults(@[
        (name: "status_report", rrTicks: 43, key: "5"),
        (name: "status_report", rrTicks: 111, key: "10"),
        (name: "status_report", rrTicks: 179, key: "15"),
        (name: "status_report", rrTicks: 247, key: "20"),
      ])
    mountIsoNimCalltrace(container, vm)
    return proc() = vm.dispose())

proc mountState(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createStateVM(store)
    if fixture == "variables":
      vm.applyState()
    else:
      store.applyEmptyState()
    store.locals.loadingState.val = lsIdle
    mountIsoNimStatePanel(container, vm)
    store.locals.loadingState.val = lsIdle
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
    vm.hoverStep(some(1))
    vm.setSteps([
      FlowStepEntry(step: 0, location: "main.nr:13",
                    expression: "initial_shield", beforeValue: "10000",
                    afterValue: "10000"),
      FlowStepEntry(step: 1, location: "shield.nr:58",
                    expression: "damage", beforeValue: "100",
                    afterValue: "2000"),
      FlowStepEntry(step: 2, location: "shield.nr:61",
                    expression: "remaining_shield", beforeValue: "10000",
                    afterValue: "8000"),
      FlowStepEntry(step: 3, location: "shield.nr:66",
                    expression: "shield_status", beforeValue: "90%",
                    afterValue: "80%"),
    ])
    mountIsoNimFlow(container, vm)
    return proc() = vm.dispose())

proc storyFrameSvg(frame: int): string =
  let fill = if frame mod 2 == 0: "%232c7be5" else: "%23d9730d"
  let accent = if frame mod 2 == 0: "%23f4d35e" else: "%234ade80"
  "data:image/svg+xml;charset=utf-8," &
    "<svg xmlns='http://www.w3.org/2000/svg' width='320' height='180' viewBox='0 0 320 180'>" &
    "<rect width='320' height='180' fill='%230b1020'/>" &
    "<rect x='24' y='22' width='272' height='136' fill='" & fill & "'/>" &
    "<circle cx='" & $(92 + frame * 72) & "' cy='88' r='42' fill='" & accent & "'/>" &
    "<rect x='44' y='132' width='" & $(96 + frame * 48) & "' height='10' fill='%23ffffff' opacity='0.85'/>" &
    "</svg>"

proc storyDrawCalls(): seq[VisualReplayDrawCall] =
  @[
    VisualReplayDrawCall(index: 0, geid: 120'u64,
                         name: "glClear", pipeline: "Framebuffer clear"),
    VisualReplayDrawCall(index: 1, geid: 180'u64,
                         name: "glDrawElements", pipeline: "Mesh pass"),
    VisualReplayDrawCall(index: 2, geid: 220'u64,
                         name: "glDrawArrays", pipeline: "Overlay pass"),
  ]

proc storyFuture[T](value: T): VisualReplayFuture[T] =
  when defined(js):
    newPromise proc(resolve: proc(value: T)) =
      resolve(value)
  else:
    newCompletedFuture(value)

proc createStoryFrameViewerClient(): VisualReplayClient =
  VisualReplayClient(
    playerUrl: "http://127.0.0.1:56123",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      storyFuture(VisualReplayInfo(frameCount: 2, width: 320, height: 180)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      let frame = if geid >= 200'u64: 1 else: 0
      storyFuture(VisualReplayFrame(
        imageSrc: storyFrameSvg(frame),
        geid: some(geid),
        frame: some(frame),
        width: 320,
        height: 180,
      )),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      let normalizedFrame = max(0, min(frame, 1))
      storyFuture(VisualReplayFrame(
        imageSrc: storyFrameSvg(normalizedFrame),
        geid: some(uint64(120 + normalizedFrame * 100)),
        frame: some(normalizedFrame),
        width: 320,
        height: 180,
      )),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      let normalizedDraw = max(0, min(draw, 2))
      let geid = uint64(120 + normalizedDraw * 50)
      storyFuture(VisualReplayFrame(
        imageSrc: storyFrameSvg(normalizedDraw mod 2),
        geid: some(geid),
        frame: some(normalizedDraw mod 2),
        width: 320,
        height: 180,
      )),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      storyFuture(storyDrawCalls()),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      storyFuture(@[
        VisualReplayPixelHistoryEntry(
          geid: 210'u64,
          drawCallIndex: 1,
          fragmentIndex: 0,
          primitiveId: 4,
          preColor: VisualReplayPixelColor(r: 0.05, g: 0.07, b: 0.11, a: 1.0),
          shaderOutput: VisualReplayPixelColor(r: 0.25, g: 0.48, b: 0.90, a: 1.0),
          postColor: VisualReplayPixelColor(r: 0.25, g: 0.48, b: 0.90, a: 1.0),
          passed: true,
          testStatus: VisualReplayPixelTestStatus(
            depth: "pass", stencil: "pass", blend: "applied", cull: "pass")),
        VisualReplayPixelHistoryEntry(
          geid: 220'u64,
          drawCallIndex: 2,
          fragmentIndex: 0,
          primitiveId: 9,
          preColor: VisualReplayPixelColor(r: 0.25, g: 0.48, b: 0.90, a: 1.0),
          shaderOutput: VisualReplayPixelColor(r: 0.91, g: 0.45, b: 0.07, a: 1.0),
          postColor: VisualReplayPixelColor(r: 0.25, g: 0.48, b: 0.90, a: 1.0),
          passed: false,
          failureReason: "depth_failed",
          testStatus: VisualReplayPixelTestStatus(
            depth: "failed", stencil: "pass", blend: "unchanged", cull: "pass")),
      ]),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      storyFuture(VisualReplayShaderDebugInfo(
        shaderStage: "fragment",
        entryPoint: "main",
        source: "",
        sourceLines: @[
          "#version 450",
          "layout(location = 0) in vec2 v_uv;",
          "layout(location = 0) out vec4 out_color;",
          "void main() {",
          "  vec4 base = vec4(v_uv, 0.25, 1.0);",
          "  out_color = base;",
          "}",
        ],
        steps: @[
          VisualReplayShaderStep(
            stepIndex: 0,
            instruction: "OpLoad %v_uv",
            sourceLine: 2,
            variables: @[
              VisualReplayShaderValue(
                name: "v_uv", valueType: "vec2", value: "[0.50, 0.50]"),
            ],
            registers: @[
              VisualReplayShaderValue(
                name: "%12", valueType: "ptr", value: "input.v_uv"),
            ]),
          VisualReplayShaderStep(
            stepIndex: 1,
            instruction: "OpStore %out_color",
            sourceLine: 6,
            variables: @[
              VisualReplayShaderValue(
                name: "base", valueType: "vec4", value: "[0.50, 0.50, 0.25, 1.00]"),
              VisualReplayShaderValue(
                name: "out_color", valueType: "vec4", value: "[0.50, 0.50, 0.25, 1.00]"),
            ],
            registers: @[
              VisualReplayShaderValue(
                name: "%out", valueType: "vec4", value: "story pixel"),
            ]),
        ])),
  )

proc mountFrameViewer(container: isonim_dom.Element; fixture: string): DisposeProc =
  let client = createStoryFrameViewerClient()
  var rootDisposer: proc()
  var vm: FrameViewerVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createFrameViewerVM(client)
    vm.setVisualReplayConnection(true, client.playerUrl)
    vm.frameCount.val = 2
    vm.frameWidth.val = 320
    vm.frameHeight.val = 180
    vm.currentGeid.val = some(120'u64)
    vm.currentFrame.val = 0
    vm.frameImageSrc.val = storyFrameSvg(0)
    vm.drawCalls.val = storyDrawCalls()
    mountIsoNimFrameViewer(container, vm)
    if fixture == "geid":
      vm.loadFrameForGeid(220'u64)
      drainCallbacks()
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc mountPixelHistory(container: isonim_dom.Element; fixture: string): DisposeProc =
  let client = createStoryFrameViewerClient()
  var rootDisposer: proc()
  var vm: PixelHistoryVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createPixelHistoryVM(client)
    mountIsoNimPixelHistory(container, vm)
    if fixture != "empty":
      vm.loadPixelHistory(160, 90, 0)
      drainCallbacks()
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc mountShaderDebug(container: isonim_dom.Element; fixture: string): DisposeProc =
  let client = createStoryFrameViewerClient()
  var rootDisposer: proc()
  var vm: ShaderDebugVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createShaderDebugVM(client)
    mountIsoNimShaderDebug(container, vm)
    if fixture != "empty":
      vm.loadFromPixel(160, 90, 0, some(220'u64))
      drainCallbacks()
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

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
    if fixture == "reference": vm.setTerminals(@[])
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
  if fixture == "live-mcr":
    var rootDisposer: proc()
    var store: ReplayDataStore
    var vm: DebugControlsVM
    var commands: seq[string] = @[]
    let r = WebRenderer()
    let logNode = r.createElement("pre")
    r.setAttribute(logNode, "id", "live-mcr-command-log")
    r.setAttribute(logNode, "hidden", "true")
    r.setTextContent(logNode, "[]")

    let updateLog = proc(command: string; args: JsonNode) =
      var entry = %*{"command": command}
      entry["args"] = args
      commands.add($entry)
      r.setTextContent(logNode, "[" & commands.join(",") & "]")

    let backend = BackendService(
      sendProc: proc(command: string,
                     args: JsonNode): BackendFuture[JsonNode] =
        updateLog(command, args)
        if command == LiveMcrGetRecordingHeadCommand:
          return newPromise proc(resolve: proc(response: JsonNode)) =
            resolve(%*{"rrTicks": 400})
        return newPromise proc(resolve: proc(response: JsonNode)) =
          resolve(%*{}),
      onEventProc: proc(handler: backend_service.EventHandler) = discard,
      disconnectProc: proc() = discard,
    )

    createRoot proc(dispose: proc()) =
      rootDisposer = dispose
      store = createReplayDataStore(backend)
      store.session.val = SessionState(
        connectionStatus: csConnected,
        debugSessionMode: liveMcr,
        recordingHeadRRTicks: 400'u64,
        recordingHeadLoadingState: lsIdle,
      )
      store.timeline.val = TimelineState(
        minRRTicks: 0'u64,
        maxRRTicks: 400'u64,
        currentRRTicks: 180'u64,
      )
      store.debugger.val = DebuggerState(
        location: Location(file: "examples/noir/noir-space-ship/src/main.nr",
                           line: 42, column: 3, callstackDepth: 1),
        rrTicks: 180'u64,
        status: dsIdle,
        threadId: 1'u32,
      )
      vm = createDebugControlsVM(store)
      mountIsoNimDebugControls(container, vm)
      discard isonim_dom.appendChild(isonim_dom.Node(container),
                                     isonim_dom.Node(logNode))
      store.requestRecordingHead()

    return proc() =
      if vm != nil: vm.dispose()
      if store != nil: store.dispose()
      if rootDisposer != nil: rootDisposer()
      container.innerHTML = ""

  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createDebugControlsVM(store)
    mountIsoNimDebugControls(container, vm)
    return proc() = vm.dispose())

proc mountPointList(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createPointListVM(store)
    vm.setPoints([
      PointListEntry(kind: "trace", label: "damage after subtraction",
                     path: "src/combat.nr", line: 42, enabled: true),
      PointListEntry(kind: "break", label: "status report branch",
                     path: "src/main.nr", line: 17, enabled: true),
      PointListEntry(kind: "trace", label: "regen calculation",
                     path: "src/shield.nr", line: 61, enabled: false),
    ])
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
    if fixture != "empty":
      vm.applySearch()
      vm.setResults([
        SearchPanelResultEntry(label: "remaining_shield",
                               detail: "src/combat.nr:42",
                               shortcut: "text"),
        SearchPanelResultEntry(label: "shield_status",
                               detail: "src/shield.nr:66",
                               shortcut: "symbol"),
        SearchPanelResultEntry(label: "src/shield.nr",
                               detail: "file result",
                               shortcut: "file"),
      ])
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
    of "demo":
      vm.setLines(demoTerminalLines())
      vm.setCurrentRRTicks(180'u64)
    else:
      vm.setLines(storyLines())
      vm.setCurrentRRTicks(0'u64)
    mountIsoNimTerminalOutput(container, vm)
    return proc() = vm.dispose())

proc appendRendered(container: isonim_dom.Element; node: isonim_dom.Element) =
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(node))

proc createHost(container: isonim_dom.Element; tag, id: string): isonim_dom.Element =
  result = isonim_dom.createElement(isonim_dom.document, cstring(tag))
  isonim_dom.setAttribute(result, cstring"id", cstring(id))
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(result))

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
    let menuHost = createHost(container, "div", "menu")
    renderMenuShellInto(r, menuHost, MenuShellModel(
      showNavigation: true, active: true, searchQuery: "",
      rootNodes: @[fileNode, debugNode],
      showWindowMenu: true,
    ))
  of "status-shell":
    let footerHost = isonim_dom.createElement(isonim_dom.document, cstring"footer")
    let statusHost = createHost(footerHost, "div", "status")
    discard isonim_dom.appendChild(isonim_dom.Node(container),
                                   isonim_dom.Node(footerHost))
    renderStatusInto(r, statusHost, StatusShellModel(
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
    ))
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
        let denseTableId = "eventLog-default-dense-table-0"
        let detailedTableId = "eventLog-default-detailed-table-0"
        let searchInputId = "eventLog-default-search"
        mountIsoNimEventLogWithDataTables(
          section.content,
          vm,
          0,
          denseTableId,
          detailedTableId,
          searchInputId,
          proc() =
            populateStorybookEventLogTables(
              cstring(denseTableId),
              cstring(detailedTableId),
              cstring(storyEventDenseHtml(vm.eventRows.val, vm.selectedRow.val)),
              cstring(storyEventDetailedHtml())))
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
    of "frame-viewer": mountFrameViewer(container, f)
    of "pixel-history": mountPixelHistory(container, f)
    of "shader-debug": mountShaderDebug(container, f)
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
