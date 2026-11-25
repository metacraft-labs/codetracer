## The state every CodeTracer story stands on: the stand-in backend, the
## replay data store stopped at `src/shield.nr:7` in the story program
## (test-programs/noir_space_ship), and the ViewModel fixtures each story
## applies (`apply*`).
##
## Plain Nim: compiled to JavaScript for StoryBook and the IsoNim Editor
## (`storybook_components.nim`), and natively for the story hosts of the
## native renderers, so every renderer draws a story from the same state.
## The backend is `MockBackendService` (auto-responding), the stand-in the
## ViewModel testing architecture names for stories; nothing else is
## substituted.

import std/[json, options, strutils, tables]

import isonim/rxcore
import isonim/viewmodel

import ../viewmodel/backend/mock_backend
import ../viewmodel/backend/backend_service
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/[
  agent_activity_vm, agent_workspace_vm, build_vm, calltrace_vm,
  command_palette_vm, errors_vm, event_log_vm, filesystem_vm, flow_vm,
  low_level_code_vm, no_source_vm, point_list_vm, repl_vm, request_panel_vm,
  scratchpad_vm, search_results_vm, search_vm, shell_vm, state_vm,
  step_list_vm, terminal_output_vm, trace_log_vm, vcs_vm, welcome_screen_vm]

const
  StoryStopPath* = "src/shield.nr"
  StoryStopLine* = 7
    ## Where every story's replay is stopped: `remaining_shield -= damage;` in
    ## `iterate_asteroids`, test-programs/noir_space_ship. The fixtures below
    ## (calltrace, state, editor, status bar, trace log, points) all describe
    ## that program, so a story names only files and lines it really has.
  StoryProgramSources* = [
    ("src/main.nr", staticRead("../../../test-programs/noir_space_ship/src/main.nr")),
    ("src/shield.nr", staticRead("../../../test-programs/noir_space_ship/src/shield.nr")),
  ]
    ## The program's sources, read at compile time: what the editor story
    ## shows.

proc storyProgramSource*(path: string): string =
  for (sourcePath, text) in StoryProgramSources:
    if sourcePath == path: return text
  raise newException(KeyError, "the story program has no file " & path)


proc storyCalltraceLines*(): seq[CallLine] =
  result = @[
    CallLine(index: 0, name: "main", depth: 0, rrTicks: 2'u64,
             location: Location(file: "src/main.nr", line: 12, column: 1),
             hasChildren: true, isExpanded: true, callKey: "main:0"),
  ]
  var idx = 1'i64

  template addIterationBlock(prefix: string; iteration: int;
                             rrBase: uint64) =
    result.add(CallLine(index: idx, name: "calculate_damage",
      depth: 2, rrTicks: rrBase,
      location: Location(file: "src/shield.nr", line: 22, column: 1,
                         callstackDepth: 2),
      hasChildren: true, isExpanded: true,
      callKey: prefix & "-damage:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_remaining_shield_pct",
      depth: 3, rrTicks: rrBase + 6,
      location: Location(file: "src/shield.nr", line: 48, column: 1,
                         callstackDepth: 3),
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-remaining:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_shield_regeneration",
      depth: 2, rrTicks: rrBase + 20,
      location: Location(file: "src/shield.nr", line: 40, column: 1,
                         callstackDepth: 2),
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-regen:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "status_report",
      depth: 2, rrTicks: rrBase + 62,
      location: Location(file: "src/shield.nr", line: 53, column: 1,
                         callstackDepth: 2),
      hasChildren: true, isExpanded: true,
      callKey: prefix & "-status:" & $iteration))
    inc idx
    result.add(CallLine(index: idx, name: "calculate_remaining_shield_pct",
      location: Location(file: "src/shield.nr", line: 48, column: 1,
                         callstackDepth: 3),
      depth: 3, rrTicks: rrBase + 68,
      hasChildren: false, isExpanded: false,
      callKey: prefix & "-status-remaining:" & $iteration))
    inc idx

  result.add(CallLine(index: idx, name: "iterate_asteroids",
    depth: 1, rrTicks: 46'u64,
    location: Location(file: "src/shield.nr", line: 1, column: 1, callstackDepth: 1),
    hasChildren: true, isExpanded: true,
    callKey: "iterate:positive"))
  inc idx
  for iteration in 0 .. 7:
    addIterationBlock("positive", iteration, uint64(52 + iteration * 68))

  result.add(CallLine(index: idx, name: "iterate_asteroids",
    depth: 1, rrTicks: 590'u64,
    location: Location(file: "src/shield.nr", line: 1, column: 1, callstackDepth: 1),
    hasChildren: true, isExpanded: true,
    callKey: "iterate:negative"))
  inc idx
  for iteration in 0 .. 3:
    addIterationBlock("negative", iteration, uint64(596 + iteration * 68))

proc storyCalltraceArgs*(): Table[string, seq[CallArg]] =
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

var lastStoryMock*: MockBackendService
  ## The backend behind the most recently mounted story.
  ##
  ## Held so a browser-driven check can read back WHAT A REAL CLICK ASKED
  ## THE BACKEND FOR. The headless suites drive `renderInstructionRowMock`
  ## / the MockRenderer arm; the shipped web bundle renders through
  ## `renderInstructionRowWeb` and binds with `addEventListener`. Those are
  ## two different procs, so a suite that only exercises the mock arm can
  ## be green against a binding no user ever reaches. This var is what lets
  ## a real Chromium click on the real DOM arm be asserted on.

proc makeStore*(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  lastStoryMock = mock
  result = createReplayDataStore(mock.toBackendService)
  result.session.val = SessionState(connectionStatus: csConnected)
  result.timeline.val = TimelineState(
    minRRTicks: 0'u64,
    maxRRTicks: 400'u64,
    currentRRTicks: 180'u64,
  )
  # Stopped in `iterate_asteroids` (test-programs/noir_space_ship), in the
  # third pass of the positive case, before the hit is subtracted: the same
  # moment the calltrace, the editor and the status bar show.
  result.debugger.val = DebuggerState(
    location: Location(file: StoryStopPath, line: StoryStopLine, column: 9,
                       callstackDepth: 1),
    rrTicks: 180'u64,
    status: dsIdle,
    threadId: 1'u32,
  )
  result.locals.codeStateLine.val = $StoryStopLine & " | remaining_shield -= damage;"
  result.locals.locals.val = @[
    Variable(name: "i", value: "2", typeName: "u32"),
    Variable(name: "mass", value: "200", typeName: "Field"),
    Variable(name: "damage", value: "2000", typeName: "Field"),
    Variable(name: "remaining_shield", value: "9000", typeName: "Field"),
    Variable(name: "initial_shield", value: "10000", typeName: "Field"),
    Variable(name: "shield_regen_percentage", value: "10", typeName: "Field"),
    Variable(
      name: "masses",
      value: "[100, 2000, 200, 100, 100, 50, 50, 14]",
      typeName: "[Field; 8]",
      hasChildren: true,
      children: @[
        Variable(name: "[0]", value: "100", typeName: "Field"),
        Variable(name: "[1]", value: "2000", typeName: "Field"),
        Variable(name: "[2]", value: "200", typeName: "Field"),
        Variable(name: "[3]", value: "100", typeName: "Field"),
        Variable(name: "[4]", value: "100", typeName: "Field"),
        Variable(name: "[5]", value: "50", typeName: "Field"),
        Variable(name: "[6]", value: "50", typeName: "Field"),
        Variable(name: "[7]", value: "14", typeName: "Field"),
      ],
    ),
  ]
  result.locals.globals.val = @[]
  result.calltrace.lines.val = storyCalltraceLines()
  result.calltrace.args.val = storyCalltraceArgs()
  result.calltrace.totalCallsCount.val = 80'u64
  result.calltrace.finished.val = true


proc terminalLine*(lineIndex: int; text: string; rrTicks: uint64): TerminalLine =
  TerminalLine(lineIndex: lineIndex, fragments: @[
    TerminalEventFragment(
      text: text,
      eventIndex: lineIndex,
      rrTicks: rrTicks,
    ),
  ])

proc demoTerminalEvents*(): seq[TerminalOutputEvent] =
  ## Coloured output, written as a program writes it (ANSI SGR), so the
  ## story renders through the same shared model the product does.
  @[
    TerminalOutputEvent(content: "\e[92mCodeTracer\e[0m replay started\n",
                        rrTicks: 100'u64, eventIndex: 0),
    TerminalOutputEvent(content: "running ", rrTicks: 140'u64, eventIndex: 1),
    TerminalOutputEvent(content: "\e[96mnoir-space-ship\e[0m\n",
                        rrTicks: 180'u64, eventIndex: 2),
    TerminalOutputEvent(content: "\e[93mwarning:\e[0m flow loop still rendering\n",
                        rrTicks: 220'u64, eventIndex: 3),
  ]

const noirTerminalTranscript* = [
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

const noirEventTicks* = [
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

proc storyLines*(): seq[TerminalLine] =
  result = @[]
  for lineIndex, text in noirTerminalTranscript:
    result.add(terminalLine(lineIndex, text, uint64(100 + lineIndex * 6)))

proc storyProblems*(): seq[BuildProblemLine] =
  @[
    BuildProblemLine(severity: blsError, path: "src/main.nr", line: 13,
                     col: 10, message: "expected field `shield` to be u32"),
    BuildProblemLine(severity: blsWarning, path: "src/shield.nr", line: 61,
                     col: 3, message: "unused variable `debug_mode`"),
  ]

proc storyFilesystem*(): FilesystemEntryNode =
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

proc storyLine*(raw: string; isStdout: bool; severity = blsNone;
               path = ""; line = 0): BuildOutputLine =
  ## A line as a compiler wrote it, ANSI included, decoded by the pane's own
  ## reader (PLAT-56: text and styled runs).
  var reader: BuildLineReader
  let (text, runs) = reader.decode(raw)
  BuildOutputLine(text: text, runs: runs, isStdout: isStdout,
                  severity: severity, locationPath: path, locationLine: line)

proc applyBuild*(vm: BuildVM; fixture: string) =
  vm.setCommand("nargo test")
  vm.setRunning(fixture == "running")
  vm.appendLine(storyLine("$ nargo test --workspace noir_space_ship", true,
                          blsInfo))
  vm.appendLine(storyLine("Compiling noir_space_ship v0.2.0", true, blsInfo))
  vm.appendLine(storyLine("Checking src/main.nr", true, blsInfo))
  vm.appendLine(storyLine(
    "\e[91msrc/main.nr:13:10 error:\e[0m expected u32", false, blsError,
    "src/main.nr", 13))
  vm.appendLine(storyLine(
    "  let did_survive_positive = shield.iterate_asteroids(...)", false,
    blsError))
  vm.appendLine(storyLine(
    "         ^^^^^^^^^^^^^ expected field `shield` to be u32", false,
    blsError))
  vm.appendLine(storyLine(
    "\e[93msrc/shield.nr:61:3 warning:\e[0m unused variable `debug_mode`",
    false, blsWarning, "src/shield.nr", 61))
  for problem in storyProblems():
    vm.appendProblem(problem)
  vm.setCode(if fixture == "success": 0 else: 1)

proc applyErrors*(vm: ErrorsVM) =
  vm.setProblems(storyProblems())

proc applyScratchpad*(vm: ScratchpadVM) =
  vm.clearValues()
  vm.addValue(ScratchpadValueEntry(
    expression: "remaining_shield",
    valueText: "9000",
    isError: false,
    isLiteral: false))
  vm.addValue(ScratchpadValueEntry(
    expression: "calculate_remaining_shield_pct(initial_shield, remaining_shield)",
    valueText: "90",
    isError: false,
    isLiteral: false))
  vm.addValue(ScratchpadValueEntry(
    expression: "masses[8]",
    valueText: "index out of bounds: the length is 8 but the index is 8",
    isError: true,
    isLiteral: false))

proc applySearchResults*(vm: SearchResultsVM) =
  vm.setQuery("shield")
  vm.setResults(@[
    SearchResultLine(path: "src/main.nr", line: 15,
                     text: "let did_survive_positive = shield::iterate_asteroids(initial_shield, shield_regen_percentage , asteroid_masses_positive);"),
    SearchResultLine(path: "src/shield.nr", line: 48,
                     text: "fn calculate_remaining_shield_pct(initial_shield: Field, remaining_shield: Field) -> Field {"),
  ])
  vm.setActive(true)

proc storyEventLine*(index: int; text: string): int =
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

proc storyEventRows*(): seq[EventLogRow] =
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

proc applyEventLog*(vm: EventLogVM) =
  vm.eventRows.val = storyEventRows()
  vm.totalEventCount.val = vm.eventRows.val.len
  vm.selectRow(some(0))

proc applyCalltrace*(vm: CalltraceVM) =
  vm.setViewport(Viewport(rows: 48))
  vm.selectEntry(some(0'i64))
  vm.setSearchQuery("")
  vm.setBackendSearchResults(@[])
  vm.store.calltrace.loadingState.val = lsIdle

proc applyState*(vm: StateVM) =
  vm.selectPath("remaining_shield")

proc applyEmptyState*(store: ReplayDataStore) =
  store.locals.codeStateLine.val = ""
  store.locals.locals.val = @[]
  store.locals.globals.val = @[]

proc applyFilesystem*(vm: FilesystemVM) =
  vm.setRoot(storyFilesystem())
  vm.expandPath("/workspace/source folders")
  vm.expandPath("/workspace/source folders/codetracer-main")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs/noir_space_ship")
  vm.expandPath("/workspace/source folders/codetracer-main/test-programs/noir_space_ship/src")
  vm.setDiffEntries(@[])

proc applyTraceLog*(vm: TraceLogVM) =
  vm.setEntries(@[
    TraceLogEntry(rrTicks: 58, minRRTicks: 0, maxRRTicks: 400,
                  path: StoryStopPath, line: StoryStopLine,
                  functionName: "iterate_asteroids",
                  localsText: "i=0 remaining_shield=10000 damage=100",
                  eventId: 10, tracepointId: 1),
    TraceLogEntry(rrTicks: 126, minRRTicks: 0, maxRRTicks: 400,
                  path: StoryStopPath, line: StoryStopLine,
                  functionName: "iterate_asteroids",
                  localsText: "i=1 remaining_shield=10000 damage=2000",
                  eventId: 12, tracepointId: 1),
  ])
  vm.selectEntry(1)

proc applyStepList*(vm: StepListVM) =
  vm.setLineSteps(@[
    StepLine(kind: slkLine, delta: -1,
             location: StepLineLocation(path: "src/main.nr", line: 12,
                                        functionName: "main",
                                        rrTicks: 120),
             sourceLine: "fn main(initial_shield: Field, shield_regen_percentage: Field, asteroid_masses_positive: pub [Field; 8], asteroid_masses_negative: pub [Field; 8]) -> pub bool {",
             values: @[StepLineFlowValue(expression: "initial_shield",
                                         value: "10000")]),
    StepLine(kind: slkLine, delta: 0,
             location: StepLineLocation(path: "src/main.nr", line: 15,
                                        functionName: "main",
                                        rrTicks: 180),
             sourceLine: "let did_survive_positive = shield::iterate_asteroids(initial_shield, shield_regen_percentage , asteroid_masses_positive);",
             values: @[StepLineFlowValue(expression: "did_survive_positive",
                                         value: "true")]),
    StepLine(kind: slkCall, delta: 1,
             location: StepLineLocation(path: "src/shield.nr", line: 22,
                                        functionName: "calculate_damage",
                                        rrTicks: 220),
             sourceLine: "calculate_damage",
             values: @[StepLineFlowValue(expression: "mass", value: "100"),
                       StepLineFlowValue(expression: "damage", value: "100")]),
    StepLine(kind: slkReturn, delta: 2,
             location: StepLineLocation(path: "src/shield.nr", line: 48,
                                        functionName: "calculate_remaining_shield_pct",
                                        rrTicks: 240),
             sourceLine: "calculate_remaining_shield_pct",
             values: @[StepLineFlowValue(expression: "remaining_shield",
                                         value: "99")]),
  ])
  vm.setCurrentLocation(StepLineLocation(path: "src/main.nr", line: 15,
                                        functionName: "main",
                                        rrTicks: 180))

proc applyNoSource*(vm: NoSourceVM) =
  vm.setMessage("No source file is available for this frame.")
  vm.setLocation(NoSourceLocationInfo(functionName: "__libc_start_main",
                                      path: "/usr/lib/libc.so", line: -1))
  vm.setHistory(NoSourceHistoryInfo(hasHistory: true,
                                    previousPath: "src/main.nr",
                                    action: "step in",
                                    previousLine: 12,
                                    previousRRTicks: 4200))
  vm.setOriginatingAddress("0x4010af")

proc applyLowLevelCode*(vm: LowLevelCodeVM) =
  vm.setAddress(0x401000)
  vm.setInstructions(@[
    LowLevelInstruction(name: "mov", args: "eax, [rbp-0x8]",
                        other: "load remaining_shield", offset: 0,
                        highLevelPath: StoryStopPath, highLevelLine: StoryStopLine),
    LowLevelInstruction(name: "sub", args: "eax, ecx",
                        other: "apply damage", offset: 4,
                        highLevelPath: StoryStopPath, highLevelLine: StoryStopLine),
    LowLevelInstruction(name: "ret", args: "", other: "", offset: 8,
                        highLevelPath: StoryStopPath, highLevelLine: StoryStopLine + 2),
  ])
  vm.setActiveOffset(4)

proc applyRepl*(vm: ReplVM) =
  vm.setReplEnabled(true)
  vm.setLangName("Noir")
  # Expressions evaluated at the stopped line, each sent and answered the way
  # the pane sends them and the debugger's answer arrives.
  for (expression, kind, answer) in [
      ("remaining_shield", rokResult, "9000"),
      ("damage * 100 / initial_shield", rokResult, "20"),
      ("masses[8]", rokError,
       "index out of bounds: the length is 8 but the index is 8")]:
    vm.submitInput(expression)
    vm.onDebugOutput(ReplOutput(kind: kind, output: answer))

proc applyRequestPanel*(vm: RequestPanelVM) =
  vm.setRequests(@[
    RequestRecord(id: 1, httpMethod: "GET", url: "/api/traces",
                  statusCode: 200, durationMs: 31, responseSize: 2048,
                  startGeid: 10'i64),
    RequestRecord(id: 2, httpMethod: "POST", url: "/api/replay/step",
                  statusCode: 500, durationMs: 84, responseSize: 512,
                  startGeid: 12'i64),
  ])
  vm.selectRequest(1)

proc applyAgentActivity*(vm: AgentActivityVM) =
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

proc applyAgentWorkspace*(vm: AgentWorkspaceVM) =
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

proc applyWelcome*(vm: WelcomeScreenVM) =
  # M-REC-3: ``RecentTraceRecord.recordingId`` is a UUIDv7 string; the
  # fixture ids are well-known constants chosen for storybook
  # readability.
  vm.setRecentTraces(@[
    RecentTraceRecord(recordingId: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
                      program: "noir_space_ship",
                      args: @[], workdir: "/workspace/noir_space_ship",
                      date: "2026/05/04 16:03:00", duration: "4.2s"),
    RecentTraceRecord(recordingId: "01949fcc-7d92-7e9c-aaaa-cccccccccccc",
                      program: "noir_space_ship",
                      args: @[], workdir: "/workspace/noir_space_ship",
                      date: "2026/05/03 12:44:00", duration: "1.1s"),
  ])
  vm.setRecentFolders(@[
    RecentFolderRecord(id: 1, name: "noir_space_ship",
                       path: "/workspace/noir_space_ship"),
    RecentFolderRecord(id: 2, name: "codetracer",
                       path: "/workspace/codetracer"),
  ])
  # The DESKTOP arm's real strip, from the same builder the product calls, so
  # this catalogue entry shows what ships — including the refused "CodeTracer
  # shell" row and the `title` that says why it is refused (issue #734). It
  # used to be five hand-written records here, which is how the two production
  # copies drifted in the first place.
  vm.setStartOptions(desktopWelcomeStartOptions(showTraceSharing = true))
  vm.setStartOptionsNote("")

proc applyCommandPalette*(vm: CommandPaletteVM) =
  vm.open()
  vm.setQuery("open")
  vm.setInputPlaceholder("Open Online Trace")
  vm.setResults([
    CommandPaletteResultEntry(value: "Open File", kind: cprkCommand),
    CommandPaletteResultEntry(value: "src/main.nr", kind: cprkFile,
                              file: "src/main.nr"),
    CommandPaletteResultEntry(value: "calculate_damage", kind: cprkSymbol,
                              file: "src/shield.nr", line: 22,
                              symbolKind: "function"),
  ])
  vm.setSelected(1)

proc applyVCS*(vm: VCSVM) =
  ## The story program's repository mid-change: the latest commit opened on
  ## its files, and the working tree carrying the edit not yet committed.
  vm.setHeader("Source Control")
  vm.setGitRepoState(true)
  vm.setBranchState("clamp-shield", ["main", "clamp-shield"], false)
  vm.setCommits([
    VCSCommitRow(hash: "4f2c9e1b",
                 message: "fix(shield): clamp the shield at zero after a hit",
                 relativeTime: "12 minutes ago", date: "2026-11-05",
                 author: "Ada Example",
                 fullHash: "4f2c9e1b7a3d5c8e0f1a2b3c4d5e6f708192a3b4"),
    VCSCommitRow(hash: "9b81d02c",
                 message: "test: an asteroid field that drains the shield",
                 relativeTime: "1 hour ago", date: "2026-11-05",
                 author: "Ada Example",
                 fullHash: "9b81d02c3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b"),
  ], [0], 0)
  vm.setCommitFiles(0, [
    VCSFileRow(path: "src/shield.nr", status: "modified", baseName: "shield.nr",
               additions: 4, deletions: 1),
    VCSFileRow(path: "src/main.nr", status: "modified", baseName: "main.nr",
               additions: 1, deletions: 1),
  ])
  vm.setWorkingTreeFiles([
    VCSFileRow(path: "Prover.toml", status: "modified", baseName: "Prover.toml",
               additions: 2, deletions: 2, selected: true),
  ])
  # No diff is staged into this story: the VCS panel is not a diff surface.
  # A unified diff is an editor-area Monaco document of its own
  # (`ui/unified_diff.nim`), which a storybook mount cannot host.

proc applySearch*(vm: SearchVM) =
  vm.setMode(smFindInFiles)
  vm.setQuery("shield")
  vm.selectResult(some(0))

proc applyShell*(vm: ShellVM) =
  ## A session as the pane shows one: a build's output and the recording it
  ## made, fed through the model's own entry points (the story has no shell
  ## process behind it).
  ##
  ## The session is started as a front-end starts one (`startShell`), over a
  ## host whose process side accepts the start and drops what it is sent:
  ## the pane's header then reads the running session's state, as the app's
  ## does over a live shell, not "not started" above its output.
  vm.host = ShellHost(
    start: proc(cols, rows: int): string = "",
    input: proc(data: string) = discard)
  vm.startShell(60, 8)
  # The recording every other story replays: the noir_space_ship program,
  # whose positive case prints the two lines below. The stream is what the
  # pane's terminal receives from a real shell, in its order: the shell
  # echoes each command line after its prompt (`$ ct record .`) before the
  # command runs, so the line precedes the recording's start event; the
  # program's output is the recording's range; and `ct record` prints the
  # recording's id as it exits, after the range closes, as the desktop's
  # captured session shows (`src/tests/visual/answers/plat61-shell.electron.json`:
  # the program's rows marked `start` / `range`, then `recordingId:<id>`
  # unmarked).
  const recordingId = "0191abcd-0000-7000-8000-000000000001"
  vm.receiveOutput("$ cd test-programs/noir_space_ship && nargo compile\r\n")
  vm.receiveOutput("$ ct record .\r\n")
  vm.receiveEvent(%*{"kind": "RecordingCommand", "status": "WorkingStatus",
                     "actionId": 1, "command": "ct record ."})
  vm.receiveOutput("Positive Test Case\r\n\e[32mshields will hold as expected\e[0m\r\n")
  vm.receiveEvent(%*{"kind": "RecordingCommand", "status": "OkStatus",
                     "actionId": 1, "command": "ct record .",
                     "trace": {"recordingId": recordingId,
                               "outputFolder": "/tmp/noir_space_ship"}})
  vm.receiveOutput("recordingId:" & recordingId & "\r\n")
  vm.receiveOutput("$ ")
