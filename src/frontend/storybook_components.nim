## Storybook-compatible exports for CodeTracer IsoNim surfaces.
##
## `mountCodeTracerStory` mounts one story: the viewmodel its fixture names,
## under the production IsoNim view. Which stories exist is declared once, in
## `stories/codetracer_stories.nim`; StoryBook (its generated story files) and
## the IsoNim Editor instance (`isonim_editor_codetracer.nim`, which compiles
## this module into its bundle) both mount through this proc.
##
## Compiled with:
##   nim js -o:storybook/dist/components.js src/frontend/storybook_components.nim

when not defined(js):
  {.error: "storybook_components.nim requires the JS backend (nim js)".}

import std/[json, jsconsole, jsffi, options, strutils, tables]

import isonim/core/async_compat
import isonim/rxcore
import isonim/viewmodel
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer

import viewmodel/backend/mock_backend
import viewmodel/backend/backend_service
import viewmodel/store/[replay_data_store, types]
import viewmodel/viewmodels/[
  agent_activity_vm,
  agent_workspace_vm,
  build_vm,
  calltrace_vm,
  command_palette_vm,
  debug_controls_vm,
  editor_vm,
  errors_vm,
  event_log_vm,
  filesystem_vm,
  flow_vm,
  frame_viewer_vm,
  pixel_history_vm,
  review_entry,
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
  test_results_vm,
  trace_log_vm,
  visual_replay_client,
  vcs_vm,
  welcome_screen_vm,
]
import viewmodel/views/[
  isonim_agent_activity_view,
  isonim_agent_workspace_view,
  isonim_auto_hide_bottom_strip_view,
  isonim_auto_hide_collapsed_icons_view,
  isonim_auto_hide_overlay_tabs_view,
  isonim_auto_hide_side_strip_view,
  isonim_build_view,
  isonim_calltrace_view,
  isonim_command_palette_view,
  isonim_debug_controls_view,
  debug_control_marks,
  isonim_debug_shell_view,
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
  isonim_test_results_view,
  isonim_trace_log_view,
  isonim_vcs_view,
  isonim_welcome_screen_view,
]
import viewmodel/app/isonim_app_shell
import lib/monaco_appearance
from ../common/types as ct import nil
import ui/[review_diff_editor, review_flow_selection]
import viewmodel/viewmodels/[diff_document, context_expansion, review_flow_overlay]
import viewmodel/views/isonim_unified_diff_view
import stories/review_story_data
from viewmodel/viewmodels/editor_gutter_lanes import lineDecorationsWidthPx
# Agent Harbor front-end prototypes: the viewmodels and their fixture data
# source come from nim-agents-isonim-viewmodels; only the views are here.
import nim_agents_isonim_viewmodels/agent_harbor/[fixture_source, fleet_vm]
import stories/agent_harbor_stories
import viewmodel/views/isonim_agent_harbor_fleet_view
import viewmodel/views/[isonim_agent_harbor_session_tabs_view,
                        isonim_agent_harbor_initiatives_view,
                        isonim_agent_harbor_initiative_tabs_view]
import ../ct_test/contracts as ct_test_contracts

type
  DisposeProc = proc()
  MountBody = proc(store: ReplayDataStore): DisposeProc

const
  StoryStopPath = "src/shield.nr"
  StoryStopLine = 7
    ## Where every story's replay is stopped: `remaining_shield -= damage;` in
    ## `iterate_asteroids`, test-programs/noir_space_ship. The fixtures below
    ## (calltrace, state, editor, status bar, trace log, points) all describe
    ## that program, so a story names only files and lines it really has.
  StoryProgramSources = [
    ("src/main.nr", staticRead("../../test-programs/noir_space_ship/src/main.nr")),
    ("src/shield.nr", staticRead("../../test-programs/noir_space_ship/src/shield.nr")),
  ]
    ## The program's sources, read at compile time: what the editor story
    ## shows.

proc storyProgramSource(path: string): string =
  for (sourcePath, text) in StoryProgramSources:
    if sourcePath == path: return text
  raise newException(KeyError, "the story program has no file " & path)

proc appendRendered(container: isonim_dom.Element; node: isonim_dom.Element) =
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(node))

proc createHost(container: isonim_dom.Element; tag, id: string): isonim_dom.Element =
  result = isonim_dom.createElement(isonim_dom.document, cstring(tag))
  isonim_dom.setAttribute(result, cstring"id", cstring(id))
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(result))

proc storyCalltraceLines(): seq[CallLine] =
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

var lastStoryMock: MockBackendService
  ## The backend behind the most recently mounted story.
  ##
  ## Held so a browser-driven check can read back WHAT A REAL CLICK ASKED
  ## THE BACKEND FOR. The headless suites drive `renderInstructionRowMock`
  ## / the MockRenderer arm; the shipped web bundle renders through
  ## `renderInstructionRowWeb` and binds with `addEventListener`. Those are
  ## two different procs, so a suite that only exercises the mock arm can
  ## be green against a binding no user ever reaches. This var is what lets
  ## a real Chromium click on the real DOM arm be asserted on.

proc makeStore(): ReplayDataStore =
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

proc terminalLine(lineIndex: int; text: string; rrTicks: uint64): TerminalLine =
  TerminalLine(lineIndex: lineIndex, fragments: @[
    TerminalEventFragment(
      text: text,
      eventIndex: lineIndex,
      rrTicks: rrTicks,
    ),
  ])

proc demoTerminalEvents(): seq[TerminalOutputEvent] =
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

proc storyLine(raw: string; isStdout: bool; severity = blsNone;
               path = ""; line = 0): BuildOutputLine =
  ## A line as a compiler wrote it, ANSI included, decoded by the pane's own
  ## reader (PLAT-56: text and styled runs).
  var reader: BuildLineReader
  let (text, runs) = reader.decode(raw)
  BuildOutputLine(text: text, runs: runs, isStdout: isStdout,
                  severity: severity, locationPath: path, locationLine: line)

proc applyBuild(vm: BuildVM; fixture: string) =
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

proc applyErrors(vm: ErrorsVM) =
  vm.setProblems(storyProblems())

proc applyScratchpad(vm: ScratchpadVM) =
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

proc applySearchResults(vm: SearchResultsVM) =
  vm.setQuery("shield")
  vm.setResults(@[
    SearchResultLine(path: "src/main.nr", line: 15,
                     text: "let did_survive_positive = shield::iterate_asteroids(initial_shield, shield_regen_percentage , asteroid_masses_positive);"),
    SearchResultLine(path: "src/shield.nr", line: 48,
                     text: "fn calculate_remaining_shield_pct(initial_shield: Field, remaining_shield: Field) -> Field {"),
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
  vm.setViewport(Viewport(rows: 48))
  vm.selectEntry(some(0'i64))
  vm.setSearchQuery("")
  vm.setBackendSearchResults(@[])
  vm.store.calltrace.loadingState.val = lsIdle

proc applyState(vm: StateVM) =
  vm.selectPath("remaining_shield")

proc applyEmptyState(store: ReplayDataStore) =
  store.locals.codeStateLine.val = ""
  store.locals.locals.val = @[]
  store.locals.globals.val = @[]

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

proc applyStepList(vm: StepListVM) =
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

proc applyNoSource(vm: NoSourceVM) =
  vm.setMessage("No source file is available for this frame.")
  vm.setLocation(NoSourceLocationInfo(functionName: "__libc_start_main",
                                      path: "/usr/lib/libc.so", line: -1))
  vm.setHistory(NoSourceHistoryInfo(hasHistory: true,
                                    previousPath: "src/main.nr",
                                    action: "step in",
                                    previousLine: 12,
                                    previousRRTicks: 4200))
  vm.setOriginatingAddress("0x4010af")

proc applyLowLevelCode(vm: LowLevelCodeVM) =
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

proc applyRepl(vm: ReplVM) =
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

proc applyWelcome(vm: WelcomeScreenVM) =
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

proc applyCommandPalette(vm: CommandPaletteVM) =
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

proc applyVCS(vm: VCSVM) =
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

proc applySearch(vm: SearchVM) =
  vm.setMode(smFindInFiles)
  vm.setQuery("shield")
  vm.selectResult(some(0))

proc applyShell(vm: ShellVM) =
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

proc mountBuild(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createBuildVM(store)
    vm.applyBuild(fixture)
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderBuildPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountErrors(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createErrorsVM(store)
    if fixture != "empty": vm.applyErrors()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderErrorsPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountScratchpad(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createScratchpadVM(store)
    if fixture != "empty": vm.applyScratchpad()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderScratchpadPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountSearchResults(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createSearchResultsVM(store)
    if fixture != "empty": vm.applySearchResults()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderSearchResultsPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountEventLog(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createEventLogVM(store)
    if fixture == "loading":
      vm.loadingState.val = lsLoading
    else:
      vm.applyEventLog()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderEventLogPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountCalltrace(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createCalltraceVM(store)
    if fixture != "empty": vm.applyCalltrace()
    if fixture == "search-status-report":
      vm.setSearchQuery("status_report")
      # Each match carries its frame's location, as `registerSearchRes`
      # gives a real one, so a click in the story jumps the way the app does.
      var matches: seq[CalltraceSearchResult] = @[]
      for (rrTicks, key) in [(43'u64, "5"), (111'u64, "10"), (179'u64, "15"),
                             (247'u64, "20")]:
        matches.add CalltraceSearchResult(
          name: "status_report", key: key, rrTicks: rrTicks,
          location: Location(file: StoryStopPath, line: 53, column: 1,
                             callstackDepth: 2))
      vm.setBackendSearchResults(matches)
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderCalltracePanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountState(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createStateVM(store)
    if fixture == "empty":
      store.applyEmptyState()
    else:
      vm.applyState()
    store.locals.loadingState.val = lsIdle
    mountIsoNimStatePanel(container, vm)
    store.locals.loadingState.val = lsIdle
    return proc() = vm.dispose())

# The editor's body is Monaco, as in the app: the IsoNim view renders only the
# container Monaco attaches to (`isonim_editor_view.nim`). The page loads the
# vendored Monaco (`src/public/third_party/monaco-editor/min`, served at
# `/public` by StoryBook and the IsoNim Editor instance alike) on first use.
proc whenStoryMonacoLoaded(onReady: proc()) {.importjs: """
  (function (onReady) {
    if (window.monaco && window.monaco.editor) { onReady(); return; }
    var base = "/public/third_party/monaco-editor/min/vs";
    if (!document.querySelector("link[data-ct-story-monaco]")) {
      var css = document.createElement("link");
      css.rel = "stylesheet";
      css.href = base + "/editor/editor.main.css";
      css.dataset.ctStoryMonaco = "true";
      document.head.appendChild(css);
    }
    var waiting = window.__ctStoryMonacoWaiting = window.__ctStoryMonacoWaiting || [];
    waiting.push(onReady);
    if (waiting.length > 1) return;
    var start = function () {
      window.require.config({ paths: { vs: base } });
      window.require(["vs/editor/editor.main"], function () {
        var ready = window.__ctStoryMonacoWaiting.splice(0);
        for (var i = 0; i < ready.length; i++) ready[i]();
      });
    };
    var loader = document.createElement("script");
    loader.src = base + "/loader.js";
    loader.onload = start;
    loader.onerror = function () { console.error("the editor story could not load Monaco from " + base); };
    document.head.appendChild(loader);
  })(#)
""".}

proc storyAppTheme(): string =
  ## The CodeTracer theme the story is shown in (StoryBook's `theme` global,
  ## which `storybook/.storybook/appStyles.js` writes onto the document).
  var key: cstring
  {.emit: "`key` = document.documentElement.dataset.codetracerTheme || 'dark';".}
  if key == cstring"light": "default_white" else: "default_dark"

proc createStoryMonacoEditor(host: isonim_dom.Element; source, language,
                             theme, fontFamily: cstring; fontSize,
                             decorationsWidth, line, column: int;
                             gutter: proc(line: int): cstring) {.importjs: """
  (function (host, source, language, theme, fontFamily, fontSize, decorationsWidth, line, column, gutter) {
    // The options `ui/editor.nim` `initMonacoForEditor` gives a replay tab.
    // The app builds them as a Nim object, whose unset fields reach Monaco
    // as their zero values: `glyphMargin` and the scroll options are off
    // there, so they are off here (Monaco's own default draws a glyph
    // margin the app does not have). The line numbers are the app's custom
    // gutter (`gutter`), with the execution-pointer arrow on the stopped
    // line.
    var overflow = document.createElement("div");
    overflow.className = "monaco-editor";
    document.body.appendChild(overflow);
    host.__ctStoryMonacoOverflow = overflow;
    var editor = monaco.editor.create(host, {
      value: source, language: language, readOnly: true, theme: theme,
      automaticLayout: true, folding: true, fontSize: fontSize,
      fontFamily: fontFamily, fontLigatures: true, minimap: { enabled: false },
      renderIndentGuides: true, find: { addExtraSpaceOnTop: false },
      renderLineHighlight: "", glyphMargin: false,
      scrollBeyondLastLine: false, smoothScrolling: false,
      renderOverviewRuler: false,
      lineNumbers: gutter,
      lineNumbersMinChars: Math.max(4, String(source.split("\n").length).length + 2),
      lineDecorationsWidth: decorationsWidth, showFoldingControls: "always",
      scrollBeyondLastColumn: 0, contextmenu: false,
      overflowWidgetsDomNode: overflow, fixedOverflowWidgets: true
    });
    // The stopped line, decorated as the app does (`styleLines`: a whole-line
    // `on on-<line>` decoration), with the cursor on it.
    editor.createDecorationsCollection([{
      range: new monaco.Range(line, 1, line, 1),
      options: { isWholeLine: true, className: "on on-" + line }
    }]);
    editor.setPosition({ lineNumber: line, column: column });
    editor.revealLineInCenter(line);
    host.__ctStoryMonaco = editor;
  })(#, #, #, #, #, #, #, #, #, #)
""".}

proc disposeStoryMonacoEditor(host: isonim_dom.Element) {.importjs:
  "(function (h) { if (h.__ctStoryMonaco) h.__ctStoryMonaco.dispose(); if (h.__ctStoryMonacoOverflow) h.__ctStoryMonacoOverflow.remove(); })(#)".}

proc mountEditor(container: isonim_dom.Element; fixture: string): DisposeProc =
  ## The editor tab of the file the replay is stopped in, at the stopped
  ## line: the IsoNim container (`mountIsoNimEditor`) with Monaco in it over
  ## the program's real source.
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createEditorVM(store)
    vm.setCursor(StoryStopLine, 9)
    let host = mountIsoNimEditor(container, vm, 0, StoryStopPath, false, 0)
    var disposed = false
    # Pending until Monaco is in: the render check waits for no
    # `[data-story-pending]` before judging what a story shows.
    isonim_dom.setAttribute(host, cstring"data-story-pending", cstring"monaco")
    whenStoryMonacoLoaded(proc() =
      if disposed: return
      try:
        defineCodeTracerMonacoThemes()
      except:
        console.error(cstring("the editor story could not define CodeTracer's Monaco themes: " &
                              getCurrentExceptionMsg()))
      createStoryMonacoEditor(host, cstring(storyProgramSource(StoryStopPath)),
        cstring(editorLanguageForPath(StoryStopPath, "rust")),
        cstring(monacoThemeFor(storyAppTheme())), cstring(CodeFontFamily),
        DefaultEditorFontSize, lineDecorationsWidthPx(DefaultEditorFontSize),
        StoryStopLine, 9,
        proc(line: int): cstring =
          # The app's gutter for a replay tab (`editorLineNumber`): no
          # tracepoints or breakpoints in this story, the arrow on the
          # line the replay is stopped on.
          editorGutterLineHtml(cstring($line), executionLine = line == StoryStopLine))
      isonim_dom.removeAttribute(host, cstring"data-story-pending"))
    return proc() =
      disposed = true
      disposeStoryMonacoEditor(host)
      vm.dispose())

proc mountFilesystem(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createFilesystemVM(store)
    if fixture != "empty": vm.applyFilesystem()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderFilesystemPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc applyFlow(vm: FlowVM) =
  ## The loop of `iterate_asteroids` at the stopped pass (i = 2 of 8): the
  ## lines it runs and what each changes.
  vm.iterationCount.val = 8
  vm.selectIteration(2)
  vm.hoverStep(some(1))
  vm.setSteps([
    FlowStepEntry(step: 0, location: "shield.nr:5",
                  expression: "mass", beforeValue: "2000",
                  afterValue: "200"),
    FlowStepEntry(step: 1, location: "shield.nr:6",
                  expression: "damage", beforeValue: "2000",
                  afterValue: "2000"),
    FlowStepEntry(step: 2, location: "shield.nr:7",
                  expression: "remaining_shield", beforeValue: "9000",
                  afterValue: "7000"),
    FlowStepEntry(step: 3, location: "shield.nr:12",
                  expression: "remaining_shield", beforeValue: "7000",
                  afterValue: "8000"),
  ])

proc applyPointList(vm: PointListVM) =
  vm.setPoints([
    PointListEntry(kind: "trace", label: "damage after subtraction",
                   path: StoryStopPath, line: StoryStopLine, enabled: true),
    PointListEntry(kind: "break", label: "status report",
                   path: "src/shield.nr", line: 14, enabled: true),
    PointListEntry(kind: "trace", label: "regen calculation",
                   path: "src/shield.nr", line: 42, enabled: false),
  ])
  vm.selectPoint(some(0))

proc mountFlow(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createFlowVM(store)
    vm.applyFlow()
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
    getDrawCallsProc: proc(frame: int): VisualReplayFuture[seq[VisualReplayDrawCall]] =
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
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderFrameViewerPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
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
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderPixelHistoryPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
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
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderShaderDebugPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
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
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderTraceLogPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountStepList(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createStepListVM(store)
    if fixture != "empty": vm.applyStepList()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderStepListPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
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
    elif fixture == "no-source-ref":
      # Asm generated from a function with no debug info: the row renders,
      # but carries no back-pointer to jump to. Clicking it must report
      # rather than silently do nothing — and that report is DOM-visible,
      # so a real browser click can be asserted on without reaching into
      # the backend.
      vm.setAddress(0x401000)
      vm.setInstructions(@[
        LowLevelInstruction(name: "nop", args: "", other: "no debug info",
                            offset: 0, highLevelPath: "", highLevelLine: 0),
      ])
    else: vm.applyLowLevelCode()
    mountIsoNimLowLevelCode(container, vm)
    return proc() = vm.dispose())

proc mountRepl(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createReplVM(store)
    if fixture == "materialized": vm.setMaterialized(true) else: vm.applyRepl()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderReplPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountRequestPanel(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createRequestPanelVM(store)
    if fixture != "empty": vm.applyRequestPanel()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderRequestPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountAgentActivity(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createAgentActivityVM(store)
    if fixture != "empty": vm.applyAgentActivity()
    if fixture == "reference": vm.setTerminals(@[])
    if fixture == "loading": vm.setLoading(true)
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentActivityPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm, 101,
        "storybook-agent-input")))
    return proc() = vm.dispose())

proc mountAgentWorkspace(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createAgentWorkspaceVM(store)
    if fixture != "empty": vm.applyAgentWorkspace()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentWorkspacePanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm, 103)))
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
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderVCSPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc debugControlsHost(container: isonim_dom.Element): isonim_dom.Element =
  ## The toolbar's host where the app has it: `#isonim-debug-controls` in
  ## the caption bar (`#menu`, `isonim_menu_shell_view`), which
  ## `ui/debug_toolbar.nim` renders the topbar into. Its styles are scoped to
  ## that bar (`menu_bar.styl`), so a toolbar mounted anywhere else -- in a
  ## panel, as this story once did -- draws its buttons loose in the middle
  ## of an empty pane.
  createHost(createHost(container, "div", "menu"), "div", DebugControlsHostId)

proc storyReviewDataset(shield: ct.DeepReviewFileData): ReviewDataset =
  ## A review of an agent's change to the story program: a hit could take the
  ## shield below zero, and the change clamps it. Two recordings back it, the
  ## program's own run and the test the agent added.
  ReviewDataset(
    title: "Clamp the shield at zero after a hit",
    commit: abbreviatedCommit("4f2c9e1b7a3d5c8e0f1a2b3c4d5e6f708192a3b4"),
    files: @[
      ReviewFile(path: "src/shield.nr", baseName: "shield.nr", status: "M",
                 additions: shield.diff.linesAdded,
                 deletions: shield.diff.linesRemoved,
                 coveredLines: 58, totalLines: 67,
                 hasFlow: true),
      ReviewFile(path: "src/main.nr", baseName: "main.nr", status: "M",
                 additions: 1, deletions: 1, coveredLines: 34, totalLines: 38,
                 hasFlow: true),
      ReviewFile(path: "Prover.toml", baseName: "Prover.toml", status: "M",
                 additions: 2, deletions: 2),
    ],
    traceContexts: @[
      VCSTraceContextRow(id: 0, label: "nargo execute: both asteroid fields"),
      VCSTraceContextRow(id: 1, label: "nargo test: shield_never_negative"),
    ],
    functionsTraced: 6)

proc storyPanelStack(parent: isonim_dom.Element; title, flex: string;
                     active = true): isonim_dom.Element =
  ## One GoldenLayout stack holding one tab, as the app draws a panel
  ## (`storybook/stories/lib/surfaces.js` `createGoldenPanelHost`: the
  ## GoldenLayout elements, the tab's pin and close, an empty control bar),
  ## sized by `flex` in a row or column of stacks. Answers the element the
  ## panel mounts into.
  proc el(parent: isonim_dom.Element; tag, class: string): isonim_dom.Element =
    result = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    isonim_dom.setAttribute(result, cstring"class", cstring(class))
    discard isonim_dom.appendChild(isonim_dom.Node(parent), isonim_dom.Node(result))
  let layout = el(parent, "div", "lm_goldenlayout lm_item lm_root ct-storybook-golden-panel")
  isonim_dom.setStyleProperty(layout, cstring"flex", cstring(flex))
  isonim_dom.setStyleProperty(layout, cstring"minWidth", cstring"0")
  let stack = el(layout, "div", "lm_item lm_stack")
  let header = el(stack, "div", "lm_header")
  let tabs = el(header, "section", "lm_tabs")
  let tab = el(tabs, "div", if active: "lm_tab lm_active" else: "lm_tab")
  isonim_dom.setAttribute(tab, cstring"title", cstring(title))
  let tabTitle = el(tab, "span", "lm_title")
  discard isonim_dom.appendChild(isonim_dom.Node(tabTitle),
    isonim_dom.createTextNode(isonim_dom.document, cstring(title)))
  isonim_dom.setAttribute(el(tab, "div", "lm_pin_tab"), cstring"title", cstring"Pin to the sidebar")
  isonim_dom.setAttribute(el(tab, "div", "lm_close_tab"), cstring"title", cstring"Close panel")
  discard el(header, "div", "lm_controls")
  let items = el(stack, "div", "lm_items")
  let content = el(items, "div", "lm_item lm_content")
  result = el(content, "div", "ct-storybook-panel-content")

proc storyStackRow(parent: isonim_dom.Element; column = false): isonim_dom.Element =
  ## A row (or a column) of panel stacks filling `parent`.
  result = isonim_dom.createElement(isonim_dom.document, cstring"div")
  isonim_dom.setAttribute(result, cstring"class",
    cstring(if column: "ct-storybook-stack-column" else: "ct-storybook-stack-row"))
  isonim_dom.setAttribute(result, cstring"style", cstring(
    "display: flex; flex-direction: " & (if column: "column" else: "row") &
    "; flex: 1 1 0; width: 100%; height: 100%; min-width: 0; min-height: 0; gap: 2px"))
  discard isonim_dom.appendChild(isonim_dom.Node(parent), isonim_dom.Node(result))

proc storySetTimeout(callback: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

const DeepReviewDiffHostId = "unifiedDiffEditor-story"
  ## The diff tab's editor host (`ui/unified_diff.editorHostId` names the
  ## app's by the tab's component id).

proc storyReviewDiffEditor(vm: VCSVM; file: ct.DeepReviewFileData;
                           fontSize: int): proc() =
  ## The review's diff editor over `file`, as `ui/unified_diff.initEditor`
  ## creates it, through the same module: the options, the gutter, the diff
  ## decorations, the flow classes and the value bands. Answers its dispose.
  let pair = diffPairFor(vm)
  let doc = pair.modified
  let diffEditor = udCreateDiffEditor(cstring(DeepReviewDiffHostId),
    reviewDiffEditorOptions(cstring(monacoThemeFor(storyAppTheme())),
                            diffContextLineCount(pair), fontSize,
                            cstring(CodeFontFamily)))
  let language = cstring(pair.language)
  let originalModel = udCreateModel(cstring(documentText(pair.original)), language)
  let modifiedModel = udCreateModel(cstring(documentText(pair.modified)), language)
  originalModel.udForceTokenization(DiffTokenizeLineLimit)
  diffEditor.udSetDiffModel(originalModel, modifiedModel)
  let editor = diffEditor.udDiffModifiedEditor()
  let originalEditor = diffEditor.udDiffOriginalEditor()
  let (labels, originalLabels) = reviewDiffLineLabels(pair)
  applyReviewDiffGutterOptions(editor, originalEditor, labels, originalLabels,
                               lineNumberColumnWidth(pair))
  discard editor.udCreateDecorationsCollection(
    monacoDecorations(pair.modified, []).toJs)
  discard originalEditor.udCreateDecorationsCollection(
    monacoDecorations(pair.original, []).toJs)
  discard editor.udCreateDecorationsCollection(monacoFlowDecorations(
    storyShieldFlowDecorations(file, doc)).toJs)
  # The values are placed once the editor has laid itself out: where a band
  # goes (beside the code or on its own row) is measured against the pane.
  var widgets: seq[js]
  var disposed = false
  storySetTimeout(proc() =
    if disposed: return
    placeReviewValueBands(
      editor, doc, storyShieldValueAnnotations(file, doc), 0, fontSize,
      ReviewValueBandSink(
        bandLeft: proc(px: int) = discard,
        widget: proc(widget: js) = widgets.add(widget),
        # A view zone lives in the editor and goes with it.
        zone: proc(zoneId: int) = discard)), 0)
  # Nothing once the story is disposed: the retries outlive a quick story
  # switch, and the models are disposed with the editor.
  scheduleReviewDeletedLineTokens(
    proc(): ReviewDiffEditorRefs =
      if not disposed: result = (diffEditor, originalModel),
    cstring(DeepReviewDiffHostId), 0)
  return proc() =
    disposed = true
    for widget in widgets: editor.udRemoveContentWidget(widget)
    udDisposeDiffEditor(diffEditor)
    udDisposeModel(originalModel)
    udDisposeModel(modifiedModel)

proc mountDeepReview(container: isonim_dom.Element; fixture: string): DisposeProc =
  ## A review as the app shows one, with `src/shield.nr` selected. DeepReview
  ## is a mode of the debugger window, not a pane: the VCS panel switched
  ## into DeepReview mode lists the change (title, commit, stats, trace
  ## contexts, the changed files), populated through the routine every review
  ## launch path calls (`review_entry.applyReviewDataset`), and the selected
  ## file opens as a diff tab in the editor area (`ui/vcs.openUnifiedDiffTab`):
  ## Monaco's inline diff with the values the recording holds beside the
  ## changed lines, drawn by `ui/review_diff_editor` as the app's tab draws
  ## them.
  ##
  ## The diff shows the call of `calculate_damage` and the pass of
  ## `iterate_asteroids`' loop the other stories are stopped in
  ## (`review_story_data`): the in-editor selectors that choose them in the
  ## app (`ui/unified_diff.rebuildInvocationZones`) are drawn by the tab's
  ## Karax code and are not part of this story.
  let file = storyShieldReviewFile()
  clearReviewFlowSelections()
  setReviewInvocationOrdinal(ShieldPath, "calculate_damage", StoryCalculateDamageCall)
  setReviewLoopIteration(ShieldPath, "iterate_asteroids", 1, StoryIterateAsteroidsPass)
  let row = storyStackRow(container)
  let vcsMount = storyPanelStack(row, "VCS", "0 0 26rem")
  let diffMount = storyPanelStack(row, "Diff: shield.nr", "1 1 0")
  var rootDisposer: proc()
  var vm, diffVm: VCSVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createVCSVM()
    discard vm.applyReviewDataset(storyReviewDataset(file), 0)
    discard isonim_dom.appendChild(isonim_dom.Node(vcsMount), isonim_dom.Node(
      renderVCSPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    diffVm = createVCSVM()
    diffVm.setUnifiedDiff(true, [reviewDiffFileRow(
      file, 0, sourceTextLines(file.sourceContent))])
    discard isonim_dom.appendChild(isonim_dom.Node(diffMount), isonim_dom.Node(
      renderUnifiedDiffTab[WebRenderer, isonim_dom.Element](
        WebRenderer(), diffVm, DeepReviewDiffHostId)))
  var disposeEditor: proc()
  var disposed = false
  # Pending until Monaco is in: the render check waits for no
  # `[data-story-pending]` before judging what a story shows.
  isonim_dom.setAttribute(diffMount, cstring"data-story-pending", cstring"monaco")
  whenStoryMonacoLoaded(proc() =
    if disposed: return
    try:
      defineCodeTracerMonacoThemes()
      disposeEditor = storyReviewDiffEditor(diffVm, file, DefaultEditorFontSize)
    except:
      console.error(cstring("the Deep Review story could not create its diff editor: " &
                            getCurrentExceptionMsg()))
    isonim_dom.removeAttribute(diffMount, cstring"data-story-pending"))
  return proc() =
    disposed = true
    if disposeEditor != nil: disposeEditor()
    if vm != nil: vm.dispose()
    if diffVm != nil: diffVm.dispose()
    if rootDisposer != nil: rootDisposer()
    clearReviewFlowSelections()
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
      renderTopbar[WebRenderer, isonim_dom.Element](WebRenderer(),
        debugControlsHost(container), vm)
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
    renderTopbar[WebRenderer, isonim_dom.Element](WebRenderer(),
      debugControlsHost(container), vm)
    return proc() = vm.dispose())

proc mountPointList(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createPointListVM(store)
    vm.applyPointList()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderPointListPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountSearch(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createSearchVM(store)
    if fixture != "empty":
      vm.applySearch()
      vm.setResults([
        SearchPanelResultEntry(label: "remaining_shield",
                               detail: "src/shield.nr:7",
                               shortcut: "text"),
        SearchPanelResultEntry(label: "calculate_remaining_shield_pct",
                               detail: "src/shield.nr:48",
                               shortcut: "symbol"),
        SearchPanelResultEntry(label: "src/shield.nr",
                               detail: "file result",
                               shortcut: "file"),
      ])
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderSearchPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    return proc() = vm.dispose())

proc mountShell(container: isonim_dom.Element; fixture: string): DisposeProc =
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let vm = createShellVM(store)
    if fixture != "empty": vm.applyShell()
    mountIsoNimShell(container, vm)
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
      vm.setEvents(demoTerminalEvents())
      vm.setCurrentRRTicks(180'u64)
    else:
      vm.setLines(storyLines())
      vm.setCurrentRRTicks(0'u64)
    mountIsoNimTerminalOutput(container, vm)
    return proc() = vm.dispose())

# ---------------------------------------------------------------------------
# Agent Harbor
# ---------------------------------------------------------------------------

proc mountAgentHarborFleet(container: isonim_dom.Element;
                           fixture: string): DisposeProc =
  ## The fleet panel over the viewmodel `createFleetStoryVM` builds for the
  ## story's fixture (`stories/agent_harbor_stories.nim` names them).
  var rootDisposer: proc()
  var vm: FleetSnapshotVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createFleetStoryVM(fixture)
    mountAgentHarborFleetPanel(container, vm)
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc mountAgentHarborVM[T](container: isonim_dom.Element;
                           build: proc(): T;
                           mount: proc(container: isonim_dom.Element; vm: T)): DisposeProc =
  ## Builds a story's viewmodel in a reactive root and mounts its view; the
  ## dispose proc tears both down.
  var rootDisposer: proc()
  var vm: T
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = build()
    mount(container, vm)
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc mountAgentHarborSessionTabs(container: isonim_dom.Element;
                                 fixture: string): DisposeProc =
  ## The strip as CodeTracer draws it: in the caption bar (`#menu`), above an
  ## empty working area. Several lines let the bar grow.
  let caption = isonim_dom.createElement(isonim_dom.document, cstring"div")
  isonim_dom.setAttribute(caption, cstring"id", cstring"menu")
  isonim_dom.setAttribute(caption, cstring"class", cstring(
    "ah-tab-caption" & (if fixture.startsWith("multi-line") or fixture == "focused-initiative":
                          " ah-tab-caption-multiline" else: "")))
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(caption))
  mountAgentHarborVM(caption,
    proc(): SessionTabStripVM = createSessionTabsStoryVM(fixture),
    proc(host: isonim_dom.Element; vm: SessionTabStripVM) =
      mountAgentHarborTabStrip(host, vm))

proc mountAgentHarborInitiativeTabs(container: isonim_dom.Element;
                                    fixture: string): DisposeProc =
  ## The tab bar with initiatives as tabs, in the caption bar; with a panel
  ## under the bar where the story asks for one (`hasPanelUnderCaption`):
  ## the caption is fixed at the window's top, so the panel fills the
  ## window behind it (`.ah-story-panel-under`) and shows below it.
  if hasPanelUnderCaption("agent-harbor-initiative-tabs", fixture):
    let panel = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(panel, cstring"class", cstring"ah-story-panel-under")
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
  let caption = isonim_dom.createElement(isonim_dom.document, cstring"div")
  isonim_dom.setAttribute(caption, cstring"id", cstring"menu")
  isonim_dom.setAttribute(caption, cstring"class", cstring"ah-tab-caption")
  discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(caption))
  mountAgentHarborVM(caption,
    proc(): InitiativeTabStripVM = createInitiativeTabsStoryVM(fixture),
    proc(host: isonim_dom.Element; vm: InitiativeTabStripVM) =
      mountAgentHarborInitiativeTabBar(host, vm))

proc mountAgentHarborSessionList(container: isonim_dom.Element;
                                 fixture: string): DisposeProc =
  mountAgentHarborVM(container,
    proc(): SessionTabStripVM = createSessionListStoryVM(fixture),
    proc(host: isonim_dom.Element; vm: SessionTabStripVM) =
      mountAgentHarborSessionList(host, vm))

proc mountAgentHarborInitiatives(container: isonim_dom.Element;
                                 fixture: string): DisposeProc =
  mountAgentHarborVM(container,
    proc(): InitiativesVM = createInitiativesStoryVM(fixture),
    proc(host: isonim_dom.Element; vm: InitiativesVM) =
      mountAgentHarborInitiativesPanel(host, vm))

proc mountAgentHarborProgress(container: isonim_dom.Element;
                              fixture: string): DisposeProc =
  mountAgentHarborVM(container,
    proc(): InitiativeProgressVM = createProgressStoryVM(fixture),
    proc(host: isonim_dom.Element; vm: InitiativeProgressVM) =
      mountAgentHarborProgressPanel(host, vm))

proc mountTestResults(container: isonim_dom.Element; fixture: string): DisposeProc =
  ## The Test Results pane over a real `ct test run --events` capture (the
  ## Agent Harbor fixture set's first test run), folded through the pane's
  ## own `ingestEvent`, as the desktop host folds a finished suite run.
  var rootDisposer: proc()
  var vm: TestResultsVM
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    vm = createTestResultsVM()
    if fixture != "empty":
      var runs: DataResult[seq[TestRunCapture]]
      newFixtureDataSource().loadTestRuns(
        proc(answer: DataResult[seq[TestRunCapture]]) = runs = answer)
      if runs.ok and runs.value.len > 0:
        vm.beginRun()
        for line in runs.value[0].runnerEventsJsonl.splitLines:
          if line.strip.len == 0: continue
          try:
            vm.ingestEvent(ct_test_contracts.eventFromJsonLine(line))
          except CatchableError:
            discard
        vm.endRun()
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderTestResultsPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
  return proc() =
    if vm != nil: vm.dispose()
    if rootDisposer != nil: rootDisposer()
    container.innerHTML = ""

proc renderStoryStatusBar(r: WebRenderer; container: isonim_dom.Element;
                          showNotifications: bool;
                          replayReadyToast = true): isonim_dom.Element =
  ## The status bar as the app has it (`footer > #status`, `renderStatusInto`),
  ## at the story's stopped location; answers `#status`. The bottom strip and
  ## the collapsed-icon zone are hosts inside it.
  let footerHost = isonim_dom.createElement(isonim_dom.document, cstring"footer")
  result = createHost(footerHost, "div", "status")
  discard isonim_dom.appendChild(isonim_dom.Node(container),
                                 isonim_dom.Node(footerHost))
  renderStatusInto(r, result, StatusShellModel(
    activeNotifications: (if replayReadyToast: @[
      StatusNotificationRecord(index: 0, kindClass: "info",
                               variantClass: "default",
                               text: "Replay ready", dismissible: true),
    ] else: @[]),
    base: StatusBaseModel(language: "Noir", encoding: "UTF-8",
                          processClass: "debug-status-ready",
                          processText: "ready",
                          locationText: StoryStopPath & ":" & $StoryStopLine,
                          locationTitle: StoryStopPath & ":" & $StoryStopLine),
    showNotifications: showNotifications,
  ))

proc statusBarHost(container: isonim_dom.Element; id: string): isonim_dom.Element =
  ## A host the status bar rendered (the bottom strip, the collapsed-icon zone).
  result = isonim_dom.getElementById(isonim_dom.document, cstring(id))
  doAssert not isonim_dom.isNodeNil(isonim_dom.Node(result)),
    "the status bar has no #" & id

proc storyMenuShellModel(active: bool): MenuShellModel =
  ## The caption bar's menu: "Open File" and a Debug menu, open (`active`)
  ## or closed, with the window controls.
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
  MenuShellModel(showNavigation: true, active: active, searchQuery: "",
                 rootNodes: @[fileNode, debugNode], showWindowMenu: true)

proc mountDebugShell(container: isonim_dom.Element; fixture: string): DisposeProc =
  ## The debugger window's shell as the app composes it (`index.html`,
  ## `ui/menu.nim`), around a replay stopped at `src/shield.nr:7`:
  ##
  ## - the caption bar `#menu`, built by the menu shell
  ##   (`renderMenuShellInto`) with its children in the app's order: the
  ##   navigation menu, the debug toolbar's host, the debug shell `#debug`
  ##   and the session tabs. The omnibox is centred because the toolbar and
  ##   the tabs share the bar's free space either side of it
  ##   (`menu_bar.styl`), so all three are filled as the app fills them: the
  ##   toolbar (`ui/debug_toolbar.ensureDebugToolbar` -> `renderTopbar`), the
  ##   debug shell's chrome and its command palette, closed: the omnibox
  ##   field (`requestDebugShellRender` -> `renderDebugChromeInto`, then the
  ##   palette mounted into the host it made), and the session tabs
  ##   (`renderSessionTabsInto`);
  ## - the panels area `#root-container > #auto-hide-layout-row > #ROOT >
  ##   #session-container-0`, beside its empty `#main`, with the editor on
  ##   the stopped line beside Variables and the call trace;
  ## - the status bar, `footer > #status`, in `#root-container` as the app
  ##   has it.
  let r = WebRenderer()
  var disposers: seq[DisposeProc] = @[]
  let menuHost = createHost(container, "div", "menu")
  isonim_dom.setAttribute(menuHost, cstring"class", cstring"menu")
  renderMenuShellInto[WebRenderer, isonim_dom.Element](r, menuHost,
    storyMenuShellModel(active = false))
  disposers.add mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    const paletteId = 3
    let toolbarVm = createDebugControlsVM(store)
    renderTopbar[WebRenderer, isonim_dom.Element](r,
      isonim_dom.getElementById(isonim_dom.document, cstring(DebugControlsHostId)),
      toolbarVm)
    renderDebugChromeInto(r,
      isonim_dom.getElementById(isonim_dom.document, cstring(DebugShellId)), paletteId)
    let paletteVm = createCommandPaletteVM(store)
    mountIsoNimCommandPalettePanel(isonim_dom.getElementById(isonim_dom.document,
      cstring(commandPaletteHostId(paletteId))), paletteVm)
    return proc() =
      paletteVm.dispose()
      toolbarVm.dispose())
  renderSessionTabsInto(r,
    isonim_dom.getElementById(isonim_dom.document, cstring"session-tab-bar"), @[
      SessionTabRecord(label: "noir-space-ship"),
      SessionTabRecord(label: "sudoku"),
    ], 0)

  let rootContainer = createHost(container, "div", "root-container")
  let layoutRow = createHost(rootContainer, "div", "auto-hide-layout-row")
  discard createHost(layoutRow, "div", "auto-hide-strip-left")
  let root = createHost(layoutRow, "div", "ROOT")
  let session = createHost(root, "div", "session-container-0")
  isonim_dom.setAttribute(session, cstring"class", cstring"session-container")
  # As `index.html` has it: an empty `section#main` in the session container,
  # with GoldenLayout's root its next child (`ui/layout.initLayout`). The
  # panels go beside `#main`, not into it: `#main` sets 1.25rem
  # (`shared_widgets.styl`), which in the app applies to nothing.
  discard createHost(session, "section", "main")
  discard createHost(layoutRow, "div", "auto-hide-strip-right")
  # GoldenLayout sizes these from the window in the app (`ui/layout.nim`);
  # here they fill the panels area with flex boxes instead. The session
  # container stays a block, as in the app, so the empty `#main` takes no
  # room beside the panels.
  isonim_dom.setAttribute(root, cstring"style", cstring(
    "display: flex; flex: 1 1 auto; width: 100%; height: 100%; " &
    "min-width: 0; min-height: 0"))
  isonim_dom.setAttribute(session, cstring"style", cstring(
    "flex: 1 1 auto; width: 100%; height: 100%; min-width: 0; min-height: 0"))
  let panels = storyStackRow(session)
  disposers.add mountEditor(storyPanelStack(panels, StoryStopPath, "1 1 0"), "populated")
  let side = storyStackRow(panels, column = true)
  isonim_dom.setStyleProperty(side, cstring"flex", cstring"0 0 34%")
  disposers.add mountState(storyPanelStack(side, "VARIABLES", "1 1 0"), "populated")
  disposers.add mountCalltrace(storyPanelStack(side, "CALLTRACE", "1 1 0"), "populated")
  # Without the "Replay ready" toast the status bar shows when a replay
  # opens: the window is past that moment.
  discard renderStoryStatusBar(r, rootContainer, false, replayReadyToast = false)
  return proc() =
    for dispose in disposers: dispose()
    container.innerHTML = ""

proc mountStructure(container: isonim_dom.Element; name, fixture: string): DisposeProc =
  let r = WebRenderer()
  case name
  of "session-tabs":
    # In the caption bar (`#menu`), where the application draws it: the
    # "+" takes its filled-disc treatment only there (session_tabs.styl
    # `#menu .session-tab-add`), and outside it drew as an outlined square.
    let captionHost = createHost(container, "div", "menu")
    appendRendered(captionHost, renderSessionTabsPanel[WebRenderer, isonim_dom.Element](r, @[
      SessionTabRecord(label: "noir-space-ship"),
      SessionTabRecord(label: "sudoku"),
    ], 0))
  of "menu-shell":
    let menuHost = createHost(container, "div", "menu")
    renderMenuShellInto[WebRenderer, isonim_dom.Element](r, menuHost,
      storyMenuShellModel(active = true))
  of "status-shell":
    discard renderStoryStatusBar(r, container, fixture == "history")
  of "auto-hide-bottom-strip":
    # The fixture renders the *live* bottom-strip view. It used to render
    # `isonim_auto_hide_bottom_tabs_view`, a second bottom-tabs renderer that
    # nothing but storybook imported — so storybook was showing a component
    # the app had stopped emitting, which is how ~48 spec locators against
    # its wrapper class stayed plausible while matching nothing. That module
    # has been retired (Value-Origin-Tracking milestone M47).
    #
    # Mounted through `renderAutoHideBottomStripInto` on a host carrying the
    # real `#auto-hide-bottom-strip` id, exactly as `ui/auto_hide.nim` does
    # it in the app — NOT by appending the bare panel. Every bottom-specific
    # rule in `styles/components/auto_hide.styl` is id-scoped
    # (`#auto-hide-bottom-strip .auto-hide-strip-tab`, `… -label`,
    # `… .active:first-child::before`), so a panel rendered without the id
    # inherits only the vertical side-strip styles and the story would show
    # something users never see — the same class of drift that made this
    # fixture worth fixing in the first place.
    #
    # And in the status bar, where the host lives in the app (`isonim_status_view`
    # renders it inside `#status-base`): the strip is centred across the bar,
    # positioned against it, so outside one it stood alone mid-frame.
    discard renderStoryStatusBar(r, container, false)
    renderAutoHideBottomStripInto(r, statusBarHost(container, BottomStripHostId), @[
      AutoHideBottomStripRecord(title: "Terminal Output", active: true),
      AutoHideBottomStripRecord(title: "Build", active: false),
    ])
  of "auto-hide-collapsed-icons":
    # In the status bar's collapsed-icon zone, as `ui/auto_hide.nim`
    # `requestCollapsedIconZoneRender` fills it.
    discard renderStoryStatusBar(r, container, false)
    renderAutoHideCollapsedIconsInto(r, statusBarHost(container, CollapsedIconZoneHostId), @[
      AutoHideCollapsedIconRecord(title: "Calltrace", icon: "C"),
      AutoHideCollapsedIconRecord(title: "Variables", icon: "V"),
    ])
  of "auto-hide-overlay-tabs":
    # Inside the overlay's body (`index.html` `#auto-hide-overlay-body`), between
    # the screen edge and the overlay's content, as `ui/auto_hide.nim`
    # `requestOverlaySideEdgeTabsRender` draws them; the content is the active
    # tab's panel.
    let body = createHost(container, "div", "auto-hide-overlay-body")
    isonim_dom.setAttribute(body, cstring"style",
      cstring"display:flex; flex:1; min-height:0; overflow:hidden; height:100%")
    let tabsHost = createHost(body, "div", "auto-hide-overlay-side-tabs")
    let contentHost = createHost(body, "div", "auto-hide-overlay-content")
    renderAutoHideOverlayTabsInto(r, tabsHost, @[
      AutoHideOverlayTabRecord(title: "Calltrace", active: true),
      AutoHideOverlayTabRecord(title: "Variables", active: false),
    ], true, " side-tabs-left")
    return mountCalltrace(contentHost, "populated")
  of "auto-hide-side-strip":
    # The left strip in the layout row beside `#ROOT`, as `ui/auto_hide.nim`
    # `requestAutoHideSideStripRender` fills `#auto-hide-strip-left`: its
    # rules (and the room `#ROOT` gives it) are written against that row.
    # The window's column: the row over the status bar. Collapsed, the strip
    # is a line and its panels are the status bar's collapsed icons, which is
    # how the app shows a collapsed edge (`requestCollapsedIconZoneRender`).
    let window = createHost(container, "div", "ct-story-window")
    isonim_dom.setAttribute(window, cstring"style",
      cstring"display:flex; flex-direction:column; height:100vh")
    let row = createHost(window, "div", "auto-hide-layout-row")
    let stripHost = createHost(row, "div", "auto-hide-strip-left")
    discard createHost(row, "div", "ROOT")
    let collapsed = fixture == "collapsed"
    renderAutoHideSideStripInto(r, stripHost, @[
      AutoHideSideStripRecord(title: "Calltrace", key: "calltrace", active: not collapsed),
      AutoHideSideStripRecord(title: "Variables", key: "state"),
    ], collapsed)
    discard renderStoryStatusBar(r, window, false)
    if collapsed:
      renderAutoHideCollapsedIconsInto(r, statusBarHost(window, CollapsedIconZoneHostId), @[
        AutoHideCollapsedIconRecord(title: "Calltrace", icon: "C"),
        AutoHideCollapsedIconRecord(title: "Variables", icon: "V"),
      ])
  else:
    let node = r.createElement("div")
    r.setAttribute(node, "class", "ct-storybook-missing")
    r.setTextContent(node, "No structure story registered for " & name)
    appendRendered(container, node)
  return proc() = container.innerHTML = ""

proc mountLayout(container: isonim_dom.Element; name, fixture: string): DisposeProc =
  if name == "deepreview":
    # The VCS panel and the diff tab side by side, as a review opens them.
    return mountDeepReview(container, fixture)
  mountWithStore(container, proc(store: ReplayDataStore): DisposeProc =
    let r = WebRenderer()
    let shell = renderIsoNimAppShell(r)
    appendRendered(container, shell.root)
    var disposers: seq[DisposeProc] = @[]
    for section in shell.sections:
      case section.panelId
      of "state":
        let vm = createStateVM(store); vm.applyState()
        # Loaded, as in the State panel story: the store starts out loading.
        store.locals.loadingState.val = lsIdle
        mountIsoNimStatePanel(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "calltrace":
        let vm = createCalltraceVM(store); vm.applyCalltrace()
        discard isonim_dom.appendChild(isonim_dom.Node(section.content), isonim_dom.Node(
          renderCalltracePanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
        disposers.add(proc() = vm.dispose())
      of "event-log":
        let vm = createEventLogVM(store); vm.applyEventLog()
        discard isonim_dom.appendChild(isonim_dom.Node(section.content), isonim_dom.Node(
          renderEventLogPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
        disposers.add(proc() = vm.dispose())
      of "flow":
        let vm = createFlowVM(store); vm.applyFlow()
        mountIsoNimFlow(section.content, vm)
        disposers.add(proc() = vm.dispose())
      of "search":
        let vm = createSearchVM(store); vm.applySearch()
        discard isonim_dom.appendChild(isonim_dom.Node(section.content), isonim_dom.Node(
          renderSearchPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
        disposers.add(proc() = vm.dispose())
      of "point-list":
        let vm = createPointListVM(store); vm.applyPointList()
        discard isonim_dom.appendChild(isonim_dom.Node(section.content), isonim_dom.Node(
          renderPointListPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
        disposers.add(proc() = vm.dispose())
      of "scratchpad":
        let vm = createScratchpadVM(store); vm.applyScratchpad()
        discard isonim_dom.appendChild(isonim_dom.Node(section.content), isonim_dom.Node(
          renderScratchpadPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
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

proc storyBackendCommands*(): cstring {.exportc.} =
  ## The commands the mounted story's backend received, as a JSON array of
  ## ``{"command": ..., "args": ...}``.
  ##
  ## Exists so a browser check can assert what a REAL click asked for, on
  ## the real-DOM render arm. Returns ``[]`` before any story is mounted.
  if lastStoryMock.isNil:
    return cstring"[]"
  var arr = newJArray()
  for rc in lastStoryMock.receivedCommands:
    arr.add(%*{"command": rc.command, "args": rc.args})
  cstring($arr)

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
    case n
    of "agent-harbor-session-tabs": mountAgentHarborSessionTabs(container, f)
    of "agent-harbor-initiative-tabs": mountAgentHarborInitiativeTabs(container, f)
    of "agent-harbor-session-list": mountAgentHarborSessionList(container, f)
    of "debug-shell": mountDebugShell(container, f)
    of "debug-controls": mountDebugControls(container, f)
    else: mountStructure(container, n, f)
  else:
    case n
    of "agent-activity": mountAgentActivity(container, f)
    of "agent-workspace": mountAgentWorkspace(container, f)
    of "agent-harbor-fleet": mountAgentHarborFleet(container, f)
    of "agent-harbor-session-list": mountAgentHarborSessionList(container, f)
    of "agent-harbor-initiatives": mountAgentHarborInitiatives(container, f)
    of "agent-harbor-initiative-progress": mountAgentHarborProgress(container, f)
    of "test-results": mountTestResults(container, f)
    of "build": mountBuild(container, f)
    of "calltrace": mountCalltrace(container, f)
    of "command-palette": mountCommandPalette(container, f)
    of "debug-controls": mountDebugControls(container, f)
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
    of "trace-log": mountTraceLog(container, f)
    of "vcs": mountVcs(container, f)
    of "welcome-screen": mountWelcome(container, f)
    else: mountStructure(container, n, f)

proc mountTerminalOutputPanel*(container: isonim_dom.Element;
                               fixture: cstring): DisposeProc {.exportc.} =
  ## Backward-compatible export used by the original terminal story.
  mountTerminalOutput(container, $fixture)

proc ctAttachDebugControlMarks*(container: isonim_dom.Element): int
    {.exportc, discardable.} =
  ## Put the debugger strip's marks on a toolbar that some OTHER producer
  ## built, and answer how many were placed.
  ##
  ## `storybook/stories/lib/surfaces.js` hand-builds a reference shell whose
  ## header is a row of empty `#{action}-image` buttons. It used to be filled
  ## in by `button.styl`'s `background-image` rules, and when those went away
  ## — the marks are inline SVG now, so that a theme can colour them — that
  ## replica would have started drawing a bar of blank buttons.
  ##
  ## Exporting the real attachment is the fix, rather than transcribing
  ## twelve paths into the story: a transcription is a second copy of the
  ## geometry that nothing compares against, which is exactly the failure
  ## mode `ControlMarks` exists to prevent.
  attachControlMarks(container)
